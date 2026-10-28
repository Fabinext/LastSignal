// NetTestCore: nativer "Spieler 0"-Hook fuer SurrounDead-Koop.
//
// Die Blueprints holen sich ihren Spieler ueber UGameplayStatics::GetPlayerController(0) usw.
// Auf dem Host ist das immer der Host, darum landen Tod und Effekte des Mitspielers beim Host.
// Diese DLL ersetzt die nativen Thunks (UFunction::Func) dieser vier Funktionen. Nach dem
// Original-Aufruf wird geschaut, welches Objekt den Blueprint-Code gerade ausfuehrt
// (FFrame::Object), und dessen PlayerController/Figur/Kamera zurueckgegeben.
//
// Ohne UE-Header: Der Lua-Mod schreibt Adressen und Offsets in netcore.cfg neben die DLL und
// schaltet ueber netcore_enabled.txt ein/aus. Laden per package.loadlib(dll, "*") aus Lua.
//
// Ausserdem: Bytecode-Patches (netcore_patch.txt, angewendet im Spielthread), KDump (Kismet-
// Disassembler, netcore_kdump_req.txt) und die Serverliste (Tab "Server Liste" im Journal,
// siehe ListWorker unten).
// Runde 5: N4b Aufruf-Beobachter ueber GNatives (netcore_watch.txt -> netcore_events.txt), N6 naechster Gast
// fuer KI-Aufrufe von GetPlayerX auf dem Host (netcore_players.txt, Whitelist), Optionen in netcore_opts.txt.
// Runde 7: Sperrliste beim Eintritt (netcore_deny.txt, nur Host), ff mit Clan-Pruefung bei pvp=1 (netcore_allies.txt).
// Runde 9: N6-Funktions-Eintraege "+ Klasse.Funktion" (Status n6fn=1), Standardliste = sichere Liste, 6 Argumente je
// Ereignis (maxargs=6), Watch-Option remote=1 (feat_remote=1), Option drop_outer=1 (INV-15), Ereignisfenster je Tag,
// Identitaetspruefung vor suppress/ff/sd/Sperre, MOVEFILE_WRITE_THROUGH nur noch fuer dauerhafte Dateien.
// Doku: _NetTest\analysis\API_NATIVE.md
// Rohe Speicherzugriffe laufen nur ueber die __try-Helfer (SafeCopy/SafeWrite), nie direkt.
// Bauen: build_msvc.cmd (MSVC, /EHa /MT) -> out\LastSignalCore.dll
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <psapi.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <iterator>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

using NativeFunc = void (*)(void* Context, void* Stack, void* Result);

struct Config {
    uintptr_t Func[4] = {};          // UFunction* GetPlayerController, -Pawn, -Character, -CameraManager
    uintptr_t ClsPawn = 0, ClsCharacter = 0, ClsPlayerController = 0;
    uintptr_t ClsActorComponent = 0, ClsActor = 0, ClsAnimInstance = 0, ClsFunction = 0;
    uint32_t OffFunc = 0xD8, OffClass = 0x10, OffOuter = 0x20, OffSuper = 0x40, OffFrameObject = 0x18;
    uint32_t OffFrameNode = 0x10, OffFramePrevious = 0x78;  // FFrame (UE 5.3): Node, PreviousFrame
    uint32_t OffFrameLocals = 0x28, OffParmsSize = 0xB6, OffObjectIndex = 0x0C, OffScript = 0x60;
    uint32_t OffFrameCode = 0x20;                           // FFrame::Code
    uint32_t OffFunctionFlags = 0xB0, OffNumParms = 0xB4, OffReturnValue = 0xB8;  // UFunction
    uint32_t OffActorOwner = 0, OffPawnController = 0, OffControllerPawn = 0, OffCameraManager = 0;
    uint32_t IndexFilter = 1;   // 1 = nur PlayerIndex 0 (oder unbekannt) umleiten, 0 = immer
    uintptr_t ObjectArray = 0;  // GUObjectArray (aus dem UE4SS-Log), 0 = Parameter-Suche aus
};

// Feste UE-5.3-Offsets (KDump/Patcher), nicht in netcore.cfg
constexpr uint32_t OffObjectName = 0x18, OffFieldNext = 0x28, OffChildren = 0x48;
// UE 5.3 (laut UE4SS.log): FFieldVariant ist ein 8-Byte-Zeiger mit Markierungsbit, Next 0x18, NamePrivate 0x20
constexpr uint32_t OffFFieldClass = 0x08, OffFFieldOwner = 0x10, OffFFieldName = 0x20;
// GUObjectArray: ObjObjects bei +0x10 { FUObjectItem** Objects, PreAllocated, Max, Num, ... },
// 64k Eintraege pro Chunk, FUObjectItem 0x18 Bytes mit dem UObject* vorne
constexpr uintptr_t OffObjObjects = 0x10, OffObjNum = 0x14, ObjItemSize = 0x18;
constexpr int32_t ObjChunkSize = 65536;

enum Kind { GetPC = 0, GetPawn = 1, GetCharacter = 2, GetCamera = 3 };

Config Cfg;
NativeFunc Original[4] = {};
std::atomic<bool> Enabled{false};
std::atomic<uint64_t> Redirects{0};
std::atomic<uint64_t> SkippedRedirects{0};  // PlayerIndex != 0, nicht umgeleitet
std::atomic<uintptr_t> LogObjectArray{0};    // GUObjectArray aus dem UE4SS-Log (Rueckfall fuer Patcher/KDump)
uintptr_t NameToStringFn = 0;                // FName::ToString aus dem UE4SS-Log (nur Worker-Thread)
uintptr_t GNativesAddr = 0;                  // GNatives[256] aus dem UE4SS-Log (N4b-Beobachter)
uintptr_t ImageBase = 0, ImageEnd = 0;
std::wstring ModDir;

void Log(const char* Text) {
    FILE* File = _wfopen((ModDir + L"netcore.log").c_str(), L"a");
    if (!File) return;
    SYSTEMTIME T;
    GetLocalTime(&T);
    fprintf(File, "[%02d:%02d:%02d] %s\n", T.wHour, T.wMinute, T.wSecond, Text);
    fclose(File);
}

void LogF(const char* Format, ...) {
    char Message[512];
    va_list Args;
    va_start(Args, Format);
    vsnprintf(Message, sizeof(Message), Format, Args);
    va_end(Args);
    Log(Message);
}

// ---------------------------------------------------------------------------------------------------------
// Rohzugriffe. __try geht nur in Funktionen ohne C++-Objekte (/EHa), darum kleine POD-Helfer.
int FaultFilter(DWORD Code) {
    return Code == EXCEPTION_ACCESS_VIOLATION || Code == EXCEPTION_IN_PAGE_ERROR ||
           Code == EXCEPTION_DATATYPE_MISALIGNMENT ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH;
}

bool SafeCopy(void* Destination, uintptr_t Source, size_t Size) {
    __try {
        memcpy(Destination, reinterpret_cast<const void*>(Source), Size);
        return true;
    } __except (FaultFilter(GetExceptionCode())) {
        return false;
    }
}

bool SafeWrite(uintptr_t Destination, const void* Source, size_t Size) {
    __try {
        memcpy(reinterpret_cast<void*>(Destination), Source, Size);
        return true;
    } __except (FaultFilter(GetExceptionCode())) {
        return false;
    }
}

template <typename T> bool TryRead(uintptr_t Address, T& Out) { return SafeCopy(&Out, Address, sizeof(T)); }

// Liest 0, wenn die Adresse nicht lesbar ist
template <typename T> T Read(uintptr_t Address) {
    T Value{};
    return TryRead(Address, Value) ? Value : T{};
}

bool LooksLikePointer(uintptr_t P) { return P > 0x10000 && (P & 7) == 0 && P < 0x7FFFFFFFFFFF; }

bool IsA(uintptr_t Object, uintptr_t TargetClass) {
    if (!LooksLikePointer(Object) || !TargetClass) return false;
    uintptr_t Class = Read<uintptr_t>(Object + Cfg.OffClass);
    for (int Depth = 0; Depth < 64 && LooksLikePointer(Class); ++Depth) {
        if (Class == TargetClass) return true;
        Class = Read<uintptr_t>(Class + Cfg.OffSuper);
    }
    return false;
}

// PlayerController, dem das ausfuehrende Objekt gehoert (Figur, Komponente, Waffe, Animation).
uintptr_t ResolvePlayerController(uintptr_t Object) {
    for (int Step = 0; Step < 6 && LooksLikePointer(Object); ++Step) {
        if (IsA(Object, Cfg.ClsPlayerController)) return Object;
        if (IsA(Object, Cfg.ClsPawn)) {
            uintptr_t Controller = Read<uintptr_t>(Object + Cfg.OffPawnController);
            return IsA(Controller, Cfg.ClsPlayerController) ? Controller : 0;
        }
        if (IsA(Object, Cfg.ClsActorComponent) || IsA(Object, Cfg.ClsAnimInstance)) {
            Object = Read<uintptr_t>(Object + Cfg.OffOuter);  // Komponente -> Actor, AnimInstance -> Mesh
            continue;
        }
        if (IsA(Object, Cfg.ClsActor)) {
            Object = Read<uintptr_t>(Object + Cfg.OffActorOwner);  // Waffe/Projektil -> Besitzer
            continue;
        }
        return 0;
    }
    return 0;
}

// FFrame liegt immer auf dem Stack des Spielthreads. Nur Zeiger in diesen Bereich als Frame
// akzeptieren, sonst koennte ein falscher Offset beliebigen Speicher lesen.
bool IsOnThisStack(uintptr_t Address) {
    ULONG_PTR Low = 0, High = 0;
    GetCurrentThreadStackLimits(&Low, &High);
    return Address >= Low && Address + 0x100 <= High;
}

// Die Hilfsfunktionen der Blueprint-Funktionsbibliothek (CastToController, GetGameHUD, ...) laufen
// im Kontext der Bibliothek, nicht des Spielers. Darum die Aufrufkette hochlaufen, bis ein Objekt
// zu einem Spieler gehoert (z. B. Respawn-Knopf -> GameInstance -> CastToController).
uintptr_t ResolveFromObjects(uintptr_t Frame) {
    for (int Depth = 0; Depth < 8 && IsOnThisStack(Frame); ++Depth) {
        if (!IsA(Read<uintptr_t>(Frame + Cfg.OffFrameNode), Cfg.ClsFunction)) return 0;
        uintptr_t PC = ResolvePlayerController(Read<uintptr_t>(Frame + Cfg.OffFrameObject));
        if (PC) return PC;
        if (!Cfg.OffFramePrevious) return 0;  // Aufrufkette abgeschaltet (coop.txt: frame_walk=0)
        Frame = Read<uintptr_t>(Frame + Cfg.OffFramePrevious);
    }
    return 0;
}

// Kleiner Zwischenspeicher bestaetigter Bereiche (pro Thread, max. 250 ms alt): IsLiveObject laeuft in Hook<K>
// fuer jeden Parameter-Slot der Aufrufkette, VirtualQuery ist ein Systemaufruf (Wine: NtQueryVirtualMemory).
// Die Lesezugriffe selbst sind per __try geschuetzt; VirtualQuery bleibt, damit keine Guard-Page (Stack eines
// anderen Threads) beruehrt wird - die loest STATUS_GUARD_PAGE_VIOLATION aus, die FaultFilter nicht faengt.
struct ReadableRegion {
    uintptr_t Base, End;
};
thread_local ReadableRegion RegionCache[8];
thread_local uint32_t RegionNext;
thread_local ULONGLONG RegionStamp;

bool IsReadable(uintptr_t Address, size_t Size) {
    const ULONGLONG Now = GetTickCount64();
    if (Now - RegionStamp > 250) {
        for (ReadableRegion& Region : RegionCache) Region.Base = Region.End = 0;
        RegionStamp = Now;
    }
    for (const ReadableRegion& Region : RegionCache)
        if (Address >= Region.Base && Address + Size <= Region.End) return true;
    MEMORY_BASIC_INFORMATION Info;
    if (!VirtualQuery(reinterpret_cast<void*>(Address), &Info, sizeof(Info))) return false;
    const DWORD Readable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                           PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (Info.State != MEM_COMMIT || !(Info.Protect & Readable) || (Info.Protect & (PAGE_GUARD | PAGE_NOACCESS)))
        return false;
    const uintptr_t Base = reinterpret_cast<uintptr_t>(Info.BaseAddress);
    RegionCache[RegionNext++ & 7] = {Base, Base + Info.RegionSize};
    return Address + Size <= Base + Info.RegionSize;
}

// GUObjectArray aus netcore.cfg, sonst aus dem UE4SS-Log
uintptr_t ObjectArray() { return Cfg.ObjectArray ? Cfg.ObjectArray : LogObjectArray.load(std::memory_order_relaxed); }

int32_t ObjectCount(uintptr_t Array) { return Read<int32_t>(Array + OffObjObjects + OffObjNum); }

uintptr_t ObjectAtIndex(uintptr_t Array, int32_t Index) {
    uintptr_t Chunks = Read<uintptr_t>(Array + OffObjObjects);  // FUObjectItem**
    if (!LooksLikePointer(Chunks) || Index < 0) return 0;
    uintptr_t Chunk = Read<uintptr_t>(Chunks + static_cast<uintptr_t>(Index / ObjChunkSize) * 8);
    if (!LooksLikePointer(Chunk)) return 0;
    return Read<uintptr_t>(Chunk + static_cast<uintptr_t>(Index % ObjChunkSize) * ObjItemSize);  // FUObjectItem::Object
}

// Ein Parameter-Slot kann auch eine Zahl oder ein Struct sein. Nur Werte akzeptieren, die genau an
// ihrem eigenen Index in GUObjectArray stehen - dann ist es sicher ein lebendes UObject.
bool IsLiveObject(uintptr_t Candidate) {
    uintptr_t Array = ObjectArray();
    if (!Array || !LooksLikePointer(Candidate) || !IsReadable(Candidate, 0x28)) return false;
    int32_t Index = Read<int32_t>(Candidate + Cfg.OffObjectIndex);
    if (Index < 0 || Index >= ObjectCount(Array)) return false;
    return ObjectAtIndex(Array, Index) == Candidate;
}

// Rueckfall, wenn kein ausfuehrendes Objekt einem Spieler gehoert: die Parameter der Funktionen in
// der Aufrufkette pruefen. Beispiel Zombie-Tod: Death(Actor Killer) -> CastToController -> Spieler 0.
// Die Kette reisst am Schadenssystem der Engine ab, aber der Killer steht als Parameter drin.
uintptr_t ResolveFromParameters(uintptr_t Frame) {
    if (!Cfg.ObjectArray) return 0;
    for (int Depth = 0; Depth < 8 && IsOnThisStack(Frame); ++Depth) {
        uintptr_t Node = Read<uintptr_t>(Frame + Cfg.OffFrameNode);
        if (!IsA(Node, Cfg.ClsFunction)) return 0;
        uintptr_t Locals = Read<uintptr_t>(Frame + Cfg.OffFrameLocals);
        uint32_t ParmsSize = Read<uint16_t>(Node + Cfg.OffParmsSize);
        if (ParmsSize > 0x60) ParmsSize = 0x60;
        if (LooksLikePointer(Locals) && IsReadable(Locals, ParmsSize)) {
            for (uint32_t Offset = 0; Offset + 8 <= ParmsSize; Offset += 8) {
                uintptr_t Candidate = Read<uintptr_t>(Locals + Offset);
                if (!IsLiveObject(Candidate)) continue;
                uintptr_t PC = ResolvePlayerController(Candidate);
                if (PC) return PC;
            }
        }
        if (!Cfg.OffFramePrevious) return 0;
        Frame = Read<uintptr_t>(Frame + Cfg.OffFramePrevious);
    }
    return 0;
}

uintptr_t ResolveFromFrames(uintptr_t Frame) {
    uintptr_t PC = ResolveFromObjects(Frame);
    return PC ? PC : ResolveFromParameters(Frame);
}

// Runde 9 (INV-15, drop_outer): Spieler der AEUSSERSTEN Ebene der Aufrufkette ab Frame 1. Beim Ablegen aus einer
// fremden Kiste: Frame 0 = Kiste.JigMP_OnRequestDropItem, Frame 1 = HandleServerDropRequest auf der Komponente der
// Kiste (beide -> Besitzer der Kiste, z. B. der Tote), ganz aussen SERVER_RequestDropItem auf der Jig-Komponente des
// anfragenden Spielers. 0 = keine aeussere Ebene gehoert einem Spieler (dann bisheriger Weg).
uintptr_t ResolveOutermost(uintptr_t Frame) {
    if (!Cfg.OffFramePrevious || !IsOnThisStack(Frame)) return 0;
    uintptr_t Found = 0;
    Frame = Read<uintptr_t>(Frame + Cfg.OffFramePrevious);
    for (int Depth = 1; Depth < 8 && IsOnThisStack(Frame); ++Depth) {
        if (!IsA(Read<uintptr_t>(Frame + Cfg.OffFrameNode), Cfg.ClsFunction)) break;
        const uintptr_t PC = ResolvePlayerController(Read<uintptr_t>(Frame + Cfg.OffFrameObject));
        if (PC) Found = PC;
        Frame = Read<uintptr_t>(Frame + Cfg.OffFramePrevious);
    }
    return Found;
}

// ---------------------------------------------------------------------------------------------------------
// Namen ueber FName::ToString des Spiels (Adresse aus dem UE4SS-Log). Nur im Worker-Thread (KDump).
// ABI: void(const FName* This, FString* Out). Der FString-Speicher bleibt liegen (nur Dump), darum Cache.
struct FStringPod {
    wchar_t* Data;
    int32_t Num;  // inkl. Nullzeichen
    int32_t Max;
};
using NameToStringFunc = void (*)(const uint64_t* Name, FStringPod* Out);

bool CallNameToString(uintptr_t Function, const uint64_t* Name, FStringPod* Out) {
    __try {
        reinterpret_cast<NameToStringFunc>(Function)(Name, Out);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

std::string ToUtf8(const wchar_t* Text, size_t Length) {
    if (!Length) return std::string();
    int Size = WideCharToMultiByte(CP_UTF8, 0, Text, static_cast<int>(Length), nullptr, 0, nullptr, nullptr);
    if (Size <= 0) return std::string();
    std::string Out(static_cast<size_t>(Size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, Text, static_cast<int>(Length), &Out[0], Size, nullptr, nullptr);
    return Out;
}

std::wstring FromUtf8(const std::string& Text) {
    if (Text.empty()) return std::wstring();
    int Size = MultiByteToWideChar(CP_UTF8, 0, Text.data(), static_cast<int>(Text.size()), nullptr, 0);
    if (Size <= 0) return std::wstring();
    std::wstring Out(static_cast<size_t>(Size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, Text.data(), static_cast<int>(Text.size()), &Out[0], Size);
    return Out;
}

std::unordered_map<uint64_t, std::string> NameCache;  // (ComparisonIndex, Number) -> Text

bool NameText(uint64_t Name, std::string& Out) {
    auto Found = NameCache.find(Name);
    if (Found != NameCache.end()) {
        Out = Found->second;
        return true;
    }
    // FNamePool hat hoechstens 8192 Bloecke, sonst ist der Index Unsinn
    if (!NameToStringFn || (static_cast<uint32_t>(Name) >> 16) >= 8192) return false;
    FStringPod Text{};
    if (!CallNameToString(NameToStringFn, &Name, &Text)) return false;
    Out.clear();
    if (Text.Data && Text.Num > 0) {
        if (Text.Num > 4096) return false;
        std::vector<wchar_t> Buffer(static_cast<size_t>(Text.Num));
        if (!SafeCopy(Buffer.data(), reinterpret_cast<uintptr_t>(Text.Data), Buffer.size() * sizeof(wchar_t))) return false;
        Out = ToUtf8(Buffer.data(), wcsnlen(Buffer.data(), Buffer.size()));
    }
    NameCache.emplace(Name, Out);
    return true;
}

bool ObjectName(uintptr_t Object, std::string& Out) {
    uint64_t Name = 0;
    return LooksLikePointer(Object) && TryRead(Object + OffObjectName, Name) && NameText(Name, Out);
}

// Voller Pfad wie UObject::GetPathName: Paket "." Objekt, Unterobjekt eines Paket-Objekts mit ":"
bool ObjectPath(uintptr_t Object, std::string& Out) {
    uintptr_t Chain[32];
    int Count = 0;
    for (uintptr_t Current = Object; Current; ) {
        if (Count == 32 || !LooksLikePointer(Current)) return false;
        Chain[Count++] = Current;
        if (!TryRead(Current + Cfg.OffOuter, Current)) return false;
    }
    std::string Name;
    if (!ObjectName(Chain[Count - 1], Out)) return false;
    for (int I = Count - 2; I >= 0; --I) {
        if (!ObjectName(Chain[I], Name)) return false;
        Out += (I == Count - 3) ? ':' : '.';
        Out += Name;
    }
    return true;
}

// FProperty -> "prop:<Owner>.<Name>:<FFieldClass>"
bool PropertyText(uintptr_t Field, std::string& Out) {
    uintptr_t FieldClass = 0, Owner = 0;
    uint64_t ClassName = 0, FieldName = 0, OwnerName = 0;
    uint8_t OwnerIsObject = 0;
    if (!LooksLikePointer(Field) || !TryRead(Field + OffFFieldClass, FieldClass) || !TryRead(FieldClass, ClassName) ||
        !TryRead(Field + OffFFieldOwner, Owner) || !TryRead(Field + OffFFieldName, FieldName))
        return false;
    // Markierungsbit entfernen; ob der Besitzer ein UObject ist, entscheidet die Objektliste
    Owner &= ~static_cast<uintptr_t>(7);
    OwnerIsObject = IsLiveObject(Owner) ? 1 : 0;
    std::string Text;
    Out = "prop:";
    if (!Owner) {
        Out += "-";
    } else {
        // Besitzername: erst passend zur Art, sonst die andere Lage probieren, sonst "?"
        if ((TryRead(Owner + (OwnerIsObject ? OffObjectName : OffFFieldName), OwnerName) && NameText(OwnerName, Text)) ||
            (TryRead(Owner + (OwnerIsObject ? OffFFieldName : OffObjectName), OwnerName) && NameText(OwnerName, Text)))
            Out += Text;
        else
            Out += "?";
    }
    if (!NameText(FieldName, Text)) return false;
    Out += "." + Text + ":";
    if (!NameText(ClassName, Text)) return false;
    Out += Text;
    return true;
}

// UFunction (oder Unterklasse wie DelegateFunction)
bool IsFunctionObject(uintptr_t Object) {
    if (Cfg.ClsFunction) return IsA(Object, Cfg.ClsFunction);
    if (!LooksLikePointer(Object)) return false;
    uintptr_t Class = Read<uintptr_t>(Object + Cfg.OffClass);
    std::string Name;
    for (int Depth = 0; Depth < 16 && LooksLikePointer(Class); ++Depth) {
        if (ObjectName(Class, Name) && Name == "Function") return true;
        Class = Read<uintptr_t>(Class + Cfg.OffSuper);
    }
    return false;
}

// ---------------------------------------------------------------------------------------------------------
// Kismet-Bytecode (UE 5.3, Speicherformat im Spiel): Objekt/Funktion/Klasse = UObject*, Property = FField*,
// Skript-Name = 8 Bytes, Sprungziele u32, Vektoren = 3 double. Ohne Ausgabe misst der Walker nur Laengen
// (auch im Spielthread fuer den PlayerIndex), mit Ausgabe erzeugt er die .kdis-Zeilen.
constexpr size_t BadPos = static_cast<size_t>(-1);

const char* OpName(uint8_t Op) {
    switch (Op) {
    case 0x00: return "LocalVariable";
    case 0x01: return "InstanceVariable";
    case 0x02: return "DefaultVariable";
    case 0x04: return "Return";
    case 0x06: return "Jump";
    case 0x07: return "JumpIfNot";
    case 0x09: return "Assert";
    case 0x0B: return "Nothing";
    case 0x0C: return "NothingInt32";
    case 0x0F: return "Let";
    case 0x11: return "BitFieldConst";
    case 0x12: return "ClassContext";
    case 0x13: return "MetaCast";
    case 0x14: return "LetBool";
    case 0x15: return "EndParmValue";
    case 0x16: return "EndFunctionParms";
    case 0x17: return "Self";
    case 0x18: return "Skip";
    case 0x19: return "Context";
    case 0x1A: return "Context_FailSilent";
    case 0x1B: return "VirtualFunction";
    case 0x1C: return "FinalFunction";
    case 0x1D: return "IntConst";
    case 0x1E: return "FloatConst";
    case 0x1F: return "StringConst";
    case 0x20: return "ObjectConst";
    case 0x21: return "NameConst";
    case 0x22: return "RotationConst";
    case 0x23: return "VectorConst";
    case 0x24: return "ByteConst";
    case 0x25: return "IntZero";
    case 0x26: return "IntOne";
    case 0x27: return "True";
    case 0x28: return "False";
    case 0x29: return "TextConst";
    case 0x2A: return "NoObject";
    case 0x2B: return "TransformConst";
    case 0x2C: return "IntConstByte";
    case 0x2D: return "NoInterface";
    case 0x2E: return "DynamicCast";
    case 0x2F: return "StructConst";
    case 0x30: return "EndStructConst";
    case 0x31: return "SetArray";
    case 0x32: return "EndArray";
    case 0x33: return "PropertyConst";
    case 0x34: return "UnicodeStringConst";
    case 0x35: return "Int64Const";
    case 0x36: return "UInt64Const";
    case 0x37: return "DoubleConst";
    case 0x38: return "Cast";
    case 0x39: return "SetSet";
    case 0x3A: return "EndSet";
    case 0x3B: return "SetMap";
    case 0x3C: return "EndMap";
    case 0x3D: return "SetConst";
    case 0x3E: return "EndSetConst";
    case 0x3F: return "MapConst";
    case 0x40: return "EndMapConst";
    case 0x41: return "Vector3fConst";
    case 0x42: return "StructMemberContext";
    case 0x43: return "LetMulticastDelegate";
    case 0x44: return "LetDelegate";
    case 0x45: return "LocalVirtualFunction";
    case 0x46: return "LocalFinalFunction";
    case 0x48: return "LocalOutVariable";
    case 0x4A: return "DeprecatedOp4A";
    case 0x4B: return "InstanceDelegate";
    case 0x4C: return "PushExecutionFlow";
    case 0x4D: return "PopExecutionFlow";
    case 0x4E: return "ComputedJump";
    case 0x4F: return "PopExecutionFlowIfNot";
    case 0x50: return "Breakpoint";
    case 0x51: return "InterfaceContext";
    case 0x52: return "ObjToInterfaceCast";
    case 0x53: return "EndOfScript";
    case 0x54: return "CrossInterfaceCast";
    case 0x55: return "InterfaceToObjCast";
    case 0x5A: return "WireTracepoint";
    case 0x5B: return "SkipOffsetConst";
    case 0x5C: return "AddMulticastDelegate";
    case 0x5D: return "ClearMulticastDelegate";
    case 0x5E: return "Tracepoint";
    case 0x5F: return "LetObj";
    case 0x60: return "LetWeakObjPtr";
    case 0x61: return "BindDelegate";
    case 0x62: return "RemoveMulticastDelegate";
    case 0x63: return "CallMulticastDelegate";
    case 0x64: return "LetValueOnPersistentFrame";
    case 0x65: return "ArrayConst";
    case 0x66: return "EndArrayConst";
    case 0x67: return "SoftObjectConst";
    case 0x68: return "CallMath";
    case 0x69: return "SwitchValue";
    case 0x6A: return "InstrumentationEvent";
    case 0x6B: return "ArrayGetByRef";
    case 0x6C: return "ClassSparseDataVariable";
    case 0x6D: return "FieldPathConst";
    default: return nullptr;  // auch 0x70-0x72 (AutoRTFM): unbekannt -> Abbruch (UE-5.6-Dump: 0 Abbrueche)
    }
}

// Zeichenkette in Anfuehrungszeichen, \ " und Zeilenumbrueche escaped
std::string Quote(const std::string& Text) {
    std::string Out = "\"";
    for (char C : Text) {
        switch (C) {
        case '\\': Out += "\\\\"; break;
        case '"': Out += "\\\""; break;
        case '\n': Out += "\\n"; break;
        case '\r': Out += "\\r"; break;
        case '\t': Out += "\\t"; break;
        default: Out += C;
        }
    }
    return Out + "\"";
}

struct KismetWalker {
    const uint8_t* Code;
    size_t Size;
    std::vector<std::string>* Lines;  // nullptr = nur Laenge messen
    bool Fault = false;               // Name/Pfad eines Operanden nicht lesbar

    bool Has(size_t Pos, size_t Count) const { return Pos != BadPos && Pos <= Size && Count <= Size - Pos; }

    template <typename T> size_t Get(size_t Pos, T& Value) const {
        if (!Has(Pos, sizeof(T))) return BadPos;
        memcpy(&Value, Code + Pos, sizeof(T));
        return Pos + sizeof(T);
    }

    void Add(size_t Line, const std::string& Text) {
        if (!Lines) return;
        (*Lines)[Line] += ' ';
        (*Lines)[Line] += Text;
    }

    void AddTarget(size_t Line, size_t Target) {
        if (!Lines) return;
        char Text[32];
        snprintf(Text, sizeof(Text), "->0x%04llx", static_cast<unsigned long long>(Target));
        Add(Line, Text);
    }

    template <typename T> size_t Num(size_t Pos, size_t Line) {
        T Value{};
        Pos = Get(Pos, Value);
        if (Pos == BadPos || !Lines) return Pos;
        char Text[64];
        if constexpr (std::is_same_v<T, float>) snprintf(Text, sizeof(Text), "%.9g", static_cast<double>(Value));
        else if constexpr (std::is_same_v<T, double>) snprintf(Text, sizeof(Text), "%.17g", Value);
        else if constexpr (std::is_signed_v<T>) snprintf(Text, sizeof(Text), "%lld", static_cast<long long>(Value));
        else snprintf(Text, sizeof(Text), "%llu", static_cast<unsigned long long>(Value));
        Add(Line, Text);
        return Pos;
    }

    size_t Target(size_t Pos, size_t Line) {
        uint32_t To = 0;
        Pos = Get(Pos, To);
        if (Pos != BadPos) AddTarget(Line, To);
        return Pos;
    }

    size_t Object(size_t Pos, size_t Line) {
        uint64_t Pointer = 0;
        Pos = Get(Pos, Pointer);
        if (Pos == BadPos || !Lines) return Pos;
        std::string Text = "null";
        if (Pointer && !ObjectPath(static_cast<uintptr_t>(Pointer), Text)) {
            char Raw[40];
            snprintf(Raw, sizeof(Raw), "obj?0x%llX", static_cast<unsigned long long>(Pointer));
            Text = Raw;  // Groesse ist bekannt: weiterlesen statt abbrechen
        }
        Add(Line, Text);
        return Pos;
    }

    size_t Property(size_t Pos, size_t Line) {
        uint64_t Pointer = 0;
        Pos = Get(Pos, Pointer);
        if (Pos == BadPos || !Lines) return Pos;
        std::string Text = "null";
        if (Pointer && !PropertyText(static_cast<uintptr_t>(Pointer), Text)) {
            char Raw[40];
            snprintf(Raw, sizeof(Raw), "prop?0x%llX", static_cast<unsigned long long>(Pointer));
            Text = Raw;
        }
        Add(Line, Text);
        return Pos;
    }

    // FScriptName im Bytecode: ComparisonIndex, DisplayIndex, Number (immer 12 Bytes)
    size_t ScriptName(size_t Pos, size_t Line) {
        uint32_t Index = 0, Display = 0, Number = 0;
        Pos = Get(Get(Get(Pos, Index), Display), Number);
        if (Pos == BadPos || !Lines) return Pos;
        const uint64_t Name = static_cast<uint64_t>(Index) | (static_cast<uint64_t>(Number) << 32);
        std::string Text;
        if (!NameText(Name, Text)) {
            char Raw[40];
            snprintf(Raw, sizeof(Raw), "?%llX", static_cast<unsigned long long>(Name));
            Text = Raw;
        }
        Add(Line, "name:" + Text);
        return Pos;
    }

    // ANSI (Latin-1), nullterminiert
    size_t AnsiString(size_t Pos, size_t Line) {
        const size_t Start = Pos;
        while (Has(Pos, 1) && Code[Pos]) ++Pos;
        if (!Has(Pos, 1)) return BadPos;
        if (Lines) {
            std::string Text;
            for (size_t I = Start; I < Pos; ++I) {
                uint8_t C = Code[I];
                if (C < 0x80) {
                    Text += static_cast<char>(C);
                } else {
                    Text += static_cast<char>(0xC0 | (C >> 6));
                    Text += static_cast<char>(0x80 | (C & 0x3F));
                }
            }
            Add(Line, Quote(Text));
        }
        return Pos + 1;
    }

    // UTF-16, nullterminiert
    size_t WideString(size_t Pos, size_t Line) {
        std::wstring Text;
        for (;;) {
            uint16_t C = 0;
            Pos = Get(Pos, C);
            if (Pos == BadPos) return BadPos;
            if (!C) break;
            if (Lines) Text.push_back(static_cast<wchar_t>(C));
        }
        if (Lines) Add(Line, Quote(ToUtf8(Text.data(), Text.size())));
        return Pos;
    }

    // Ausdruecke bis zum End-Token (das selbst keine eigene Zeile bekommt)
    size_t Until(size_t Pos, int Depth, uint8_t End) {
        while (Has(Pos, 1) && Code[Pos] != End) Pos = Expr(Pos, Depth);
        return Has(Pos, 1) ? Pos + 1 : BadPos;
    }

    size_t TextConst(size_t Pos, size_t Line, int Sub) {
        uint8_t Type = Has(Pos, 1) ? Code[Pos] : 0xFF;
        Pos = Num<uint8_t>(Pos, Line);
        switch (Type) {
        case 0: return Pos;                                               // leer
        case 1: return Expr(Expr(Expr(Pos, Sub), Sub), Sub);              // lokalisiert: Quelle, Key, Namespace
        case 2: case 3: return Expr(Pos, Sub);                            // invariant / Literal
        case 4: return Expr(Expr(Object(Pos, Line), Sub), Sub);           // String-Table: Tabelle, Key, ...
        default: return BadPos;
        }
    }

    size_t SwitchValue(size_t Pos, size_t Line, int Sub) {
        uint16_t Cases = 0;
        Pos = Get(Pos, Cases);
        if (Pos != BadPos && Lines) Add(Line, std::to_string(Cases));
        Pos = Target(Pos, Line);   // Ende
        Pos = Expr(Pos, Sub);      // Index
        for (uint16_t I = 0; I < Cases && Pos != BadPos; ++I) {
            Pos = Expr(Pos, Sub);      // Fallwert
            Pos = Target(Pos, Line);   // naechster Fall
            Pos = Expr(Pos, Sub);      // Ergebnis
        }
        return Expr(Pos, Sub);         // Default
    }

    // Ein Ausdruck ab Pos, liefert die Position danach oder BadPos (unbekannter Opcode, Pufferende, Fehler)
    size_t Expr(size_t Pos, int Depth) {
        if (!Has(Pos, 1) || Depth > 64) return BadPos;
        const size_t At = Pos;
        const uint8_t Op = Code[Pos++];
        const char* Name = OpName(Op);
        size_t Line = 0;
        if (Lines) {
            char Head[64];
            if (Name) snprintf(Head, sizeof(Head), "  %04llx %d %s", static_cast<unsigned long long>(At), Depth, Name);
            else snprintf(Head, sizeof(Head), "  %04llx %d ?? 0x%02x", static_cast<unsigned long long>(At), Depth, Op);
            Line = Lines->size();
            Lines->push_back(Head);
        }
        if (!Name) return BadPos;
        const int Sub = Depth + 1;
        switch (Op) {
        case 0x00: case 0x01: case 0x02: case 0x33: case 0x48: case 0x6C:
            Pos = Property(Pos, Line);
            break;
        case 0x04: case 0x4E: case 0x4F: case 0x51: case 0x5D: case 0x67: case 0x6D:
            Pos = Expr(Pos, Sub);
            break;
        case 0x06: case 0x4C: case 0x5B:
            Pos = Target(Pos, Line);
            break;
        case 0x07:
            Pos = Expr(Target(Pos, Line), Sub);
            break;
        case 0x09:  // Zeile, Debug-Flag, Ausdruck
            Pos = Expr(Num<uint8_t>(Num<uint16_t>(Pos, Line), Line), Sub);
            break;
        case 0x0C: case 0x1D:
            Pos = Num<int32_t>(Pos, Line);
            break;
        case 0x0F:
            Pos = Expr(Expr(Property(Pos, Line), Sub), Sub);
            break;
        case 0x11:
            Pos = Num<uint8_t>(Property(Pos, Line), Line);
            break;
        case 0x12: case 0x19: case 0x1A: {  // Objekt, Skip (ab hinter der Property), RValue-Property, Ausdruck
            uint32_t Skip = 0;
            Pos = Get(Expr(Pos, Sub), Skip);
            if (Pos != BadPos) AddTarget(Line, Pos + 8 + Skip);
            Pos = Expr(Property(Pos, Line), Sub);
            break;
        }
        case 0x13: case 0x2E: case 0x52: case 0x54: case 0x55:
            Pos = Expr(Object(Pos, Line), Sub);
            break;
        case 0x14: case 0x43: case 0x44: case 0x5C: case 0x5F: case 0x60: case 0x62: case 0x6B:
            Pos = Expr(Expr(Pos, Sub), Sub);
            break;
        case 0x18: {
            uint32_t Skip = 0;
            Pos = Get(Pos, Skip);
            if (Pos != BadPos) AddTarget(Line, Pos + Skip);
            Pos = Expr(Pos, Sub);
            break;
        }
        case 0x1B: case 0x45:
            Pos = Until(ScriptName(Pos, Line), Sub, 0x16);
            break;
        case 0x1C: case 0x46: case 0x63: case 0x68:  // bei 0x63 ist der Delegat der erste Ausdruck der Liste
            Pos = Until(Object(Pos, Line), Sub, 0x16);
            break;
        case 0x1E: Pos = Num<float>(Pos, Line); break;
        case 0x1F: Pos = AnsiString(Pos, Line); break;
        case 0x20: Pos = Object(Pos, Line); break;
        case 0x21: case 0x4B: Pos = ScriptName(Pos, Line); break;
        case 0x22: case 0x23:
            for (int I = 0; I < 3; ++I) Pos = Num<double>(Pos, Line);
            break;
        case 0x24: case 0x2C: Pos = Num<uint8_t>(Pos, Line); break;
        case 0x29: Pos = TextConst(Pos, Line, Sub); break;
        case 0x2B:  // Quaternion xyzw, Translation xyz, Skalierung xyz
            for (int I = 0; I < 10; ++I) Pos = Num<double>(Pos, Line);
            break;
        case 0x2F: Pos = Until(Num<int32_t>(Object(Pos, Line), Line), Sub, 0x30); break;
        case 0x31: Pos = Until(Expr(Pos, Sub), Sub, 0x32); break;
        case 0x34: Pos = WideString(Pos, Line); break;
        case 0x35: Pos = Num<int64_t>(Pos, Line); break;
        case 0x36: Pos = Num<uint64_t>(Pos, Line); break;
        case 0x37: Pos = Num<double>(Pos, Line); break;
        case 0x38: Pos = Expr(Num<uint8_t>(Pos, Line), Sub); break;
        case 0x39: Pos = Until(Num<int32_t>(Expr(Pos, Sub), Line), Sub, 0x3A); break;
        case 0x3B: Pos = Until(Num<int32_t>(Expr(Pos, Sub), Line), Sub, 0x3C); break;
        case 0x3D: Pos = Until(Num<int32_t>(Property(Pos, Line), Line), Sub, 0x3E); break;
        case 0x3F: Pos = Until(Num<int32_t>(Property(Property(Pos, Line), Line), Line), Sub, 0x40); break;
        case 0x41:
            for (int I = 0; I < 3; ++I) Pos = Num<float>(Pos, Line);
            break;
        case 0x42: case 0x64: Pos = Expr(Property(Pos, Line), Sub); break;
        case 0x61: Pos = Expr(Expr(ScriptName(Pos, Line), Sub), Sub); break;
        case 0x65: Pos = Until(Num<int32_t>(Property(Pos, Line), Line), Sub, 0x66); break;
        case 0x69: Pos = SwitchValue(Pos, Line, Sub); break;
        case 0x6A: {  // Typ 4 (InlineEvent) hat noch einen Namen
            uint8_t Type = Has(Pos, 1) ? Code[Pos] : 0;
            Pos = Num<uint8_t>(Pos, Line);
            if (Type == 4) Pos = ScriptName(Pos, Line);
            break;
        }
        default: break;  // ohne Operanden
        }
        return Pos;
    }
};

// Laenge eines Ausdrucks in Bytes, -1 = unbekannter Opcode oder Pufferende
int KismetExprLength(const uint8_t* Code, size_t Size, size_t Offset) {
    KismetWalker Walker{Code, Size, nullptr};
    size_t End = Walker.Expr(Offset, 0);
    return End == BadPos ? -1 : static_cast<int>(End - Offset);
}

// ---------------------------------------------------------------------------------------------------------
// PlayerIndex-Argument von GetPlayerController & Co. (WorldContextObject, int32 PlayerIndex), vor dem
// Original lesen. Aus dem Blueprint (Code != null): erstes Argument ueberspringen, dann die Konstante
// lesen. Aus ProcessEvent (Code == null): Parameter liegen in Locals. false = unbekannt.
bool ReadPlayerIndex(uintptr_t Frame, int32_t& Index) {
    if (!IsOnThisStack(Frame)) return false;
    uintptr_t Code = Read<uintptr_t>(Frame + Cfg.OffFrameCode);
    if (!Code) {
        uintptr_t Locals = Read<uintptr_t>(Frame + Cfg.OffFrameLocals);
        return LooksLikePointer(Locals) && TryRead(Locals + 8, Index);
    }
    if (Code < 0x10000 || Code >= 0x7FFFFFFFFFFF) return false;
    uint8_t Buffer[256];
    size_t Size = sizeof(Buffer);
    if (!SafeCopy(Buffer, Code, Size)) {
        Size = 0x1000 - (Code & 0xFFF);  // nur bis zum Seitenende
        if (Size >= sizeof(Buffer) || !SafeCopy(Buffer, Code, Size)) return false;
    }
    int Length = KismetExprLength(Buffer, Size, 0);
    if (Length <= 0 || static_cast<size_t>(Length) >= Size) return false;
    const uint8_t* Arg = Buffer + Length;
    const size_t Left = Size - static_cast<size_t>(Length);
    switch (Arg[0]) {
    case 0x25: Index = 0; return true;   // IntZero
    case 0x26: Index = 1; return true;   // IntOne
    case 0x1D:                           // IntConst
        if (Left < 5) return false;
        memcpy(&Index, Arg + 1, 4);
        return true;
    case 0x24: case 0x2C:                // ByteConst, IntConstByte
        if (Left < 2) return false;
        Index = Arg[1];
        return true;
    default: return false;
    }
}

bool WantsPlayerZero(uintptr_t Frame) {
    int32_t Index = 0;
    return !ReadPlayerIndex(Frame, Index) || Index == 0;
}

// ---------------------------------------------------------------------------------------------------------
// Optionen aus netcore_opts.txt (schreibt ls_native.lua, Worker liest alle 500 ms)
std::atomic<int> AiNearest{2};                 // N6: 0 aus, 1 umleiten, 2 diag (nur zaehlen, Standard)
std::atomic<bool> ObserverWanted{true};        // N4b: observer=0 schaltet den Beobachter ab
std::atomic<uint32_t> OffRootComponent{0};     // Actor.RootComponent
std::atomic<uint32_t> OffRelLocation{0};       // SceneComponent.RelativeLocation (3 double)
std::atomic<uintptr_t> LocalPC{0};             // local_pc=<hex>: lokaler PlayerController (nur Vergleich, nie gelesen)
std::atomic<bool> PvpMode{false};              // pvp=1: ff blockt nur zwischen Clan-Verbuendeten (netcore_allies.txt)
enum NetModeValue { NetUnknown = 0, NetHost = 1, NetClient = 2, NetSolo = 3 };
std::atomic<int> NetModeOpt{NetUnknown};       // netmode=host|client|solo (Sperrliste nur, wenn bekannt und nicht client)
// Runde 9 (INV-15): drop_outer=1 -> in JigMP_OnRequestDropItem zaehlt der anfragende Spieler (aeusserster Rahmen), nicht
// der Besitzer der Kiste. Fehlt die Zeile (alte Lua): aus = bisheriges Verhalten.
std::atomic<bool> DropOuterOpt{false};
std::atomic<uint64_t> DropFName{0};            // FName "JigMP_OnRequestDropItem" (Worker loest auf, 0 = noch unbekannt)
std::atomic<uint64_t> DropRedirects{0};
// Runde 9 (WORLD-7): APawn::PlayerState per Reflexion (Worker). remote=1 zaehlt nur Spielerfiguren (mit PlayerState) als
// fremd; KI-Figuren haben beim Gast ebenfalls keinen Controller und blieben sonst faelschlich "fremd". 0 = unbekannt.
std::atomic<uint32_t> OffPawnPlayerState{0};

// ---------------------------------------------------------------------------------------------------------
// N6: naechster Gast fuer Spieler-0-Aufrufe von KI, Tieren, Spawnern (nur Host). Greift nur, wenn die
// Frame-Aufloesung keinen PlayerController findet und ein Objekt der Aufrufkette auf der Whitelist steht
// (n6_whitelist.txt; "-"-Klassen sperren). Gaeste kommen aus netcore_players.txt (Lua, 1 s).
struct GuestInfo {
    uintptr_t PC, Pawn, Character, Camera;
    double X, Y, Z;
};
constexpr int MaxGuests = 16;
struct GuestSnapshot {
    int32_t Count;
    GuestInfo Guests[MaxGuests];
};
GuestSnapshot SharedGuests{};          // Seqlock: nur der Worker schreibt
std::atomic<uint32_t> GuestsSeq{0};

void PublishGuests(const GuestSnapshot& Snapshot) {
    const uint32_t Seq = GuestsSeq.load(std::memory_order_relaxed);
    GuestsSeq.store(Seq + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    memcpy(&SharedGuests, &Snapshot, sizeof(Snapshot));
    std::atomic_thread_fence(std::memory_order_release);
    GuestsSeq.store(Seq + 2, std::memory_order_release);
}

bool ReadGuests(GuestSnapshot& Out) {
    for (int Try = 0; Try < 4; ++Try) {
        const uint32_t Before = GuestsSeq.load(std::memory_order_acquire);
        if (Before & 1) continue;
        memcpy(&Out, &SharedGuests, sizeof(Out));
        std::atomic_thread_fence(std::memory_order_acquire);
        if (GuestsSeq.load(std::memory_order_relaxed) == Before) return Out.Count > 0 && Out.Count <= MaxGuests;
    }
    return false;
}

constexpr int MaxListed = 64;
constexpr int MaxListedFuncs = 32;
struct ClassLists {
    int32_t White = 0, Black = 0;
    uintptr_t WhiteClass[MaxListed] = {}, BlackClass[MaxListed] = {};
    // Runde 9: Funktions-Eintraege "+/- Klasse.Funktion" als UFunction-Zeiger (Vergleich mit Stack.Node je Frame)
    int32_t WhiteFuncs = 0, BlackFuncs = 0;
    uintptr_t WhiteFunc[MaxListedFuncs] = {}, BlackFunc[MaxListedFuncs] = {};
};
std::atomic<const ClassLists*> ActiveLists{nullptr};

// Urteil je Klasse (Klasse | Urteil in den unteren 3 Bits), lock-frei, Worker leert bei neuen Listen.
// VerdictFunc/VerdictFuncNoLoc nur als Ergebnis der Kette (Diag), nie im Cache.
enum Verdict { VerdictWhite = 1, VerdictBlack = 2, VerdictNone = 3, VerdictFunc = 4, VerdictFuncNoLoc = 5 };
constexpr size_t VerdictSlots = 1024;
std::atomic<uint64_t> VerdictCache[VerdictSlots];

int ClassVerdict(uintptr_t Class) {
    const ClassLists* Lists = ActiveLists.load(std::memory_order_acquire);
    if (!Lists || !LooksLikePointer(Class)) return VerdictNone;
    std::atomic<uint64_t>& Slot = VerdictCache[(static_cast<uint64_t>(Class) * 0x9E3779B97F4A7C15ull) >> 54];
    const uint64_t Cached = Slot.load(std::memory_order_relaxed);
    if ((Cached & ~uint64_t(7)) == Class) return static_cast<int>(Cached & 7);
    bool White = false, Black = false;
    uintptr_t Current = Class;
    for (int Depth = 0; Depth < 64 && LooksLikePointer(Current) && !Black; ++Depth) {
        for (int I = 0; I < Lists->Black; ++I) if (Lists->BlackClass[I] == Current) Black = true;
        for (int I = 0; I < Lists->White; ++I) if (Lists->WhiteClass[I] == Current) White = true;
        Current = Read<uintptr_t>(Current + Cfg.OffSuper);
    }
    const int Result = Black ? VerdictBlack : White ? VerdictWhite : VerdictNone;
    Slot.store(static_cast<uint64_t>(Class) | static_cast<uint64_t>(Result), std::memory_order_relaxed);
    return Result;
}

// Diag: unaufgeloeste Aufrufer (Klasse des innersten Objekts + Funktion) zaehlen, Worker loggt alle 10 s
struct DiagSlot {
    std::atomic<uint64_t> Key;
    std::atomic<uintptr_t> Class, Func;
    std::atomic<uint32_t> Count;
    std::atomic<int32_t> Verdict;
};
DiagSlot DiagTable[256];
std::atomic<uint64_t> DiagOverflow{0};
std::atomic<uint64_t> NearestRedirects{0};

void DiagCount(uintptr_t Class, uintptr_t Func, int Verdict) {
    uint64_t Key = (static_cast<uint64_t>(Class) * 31) ^ static_cast<uint64_t>(Func);
    if (!Key) Key = 1;
    const size_t Start = static_cast<size_t>((Key * 0x9E3779B97F4A7C15ull) >> 56);
    for (size_t Probe = 0; Probe < 8; ++Probe) {
        DiagSlot& Slot = DiagTable[(Start + Probe) & 255];
        uint64_t Current = Slot.Key.load(std::memory_order_relaxed);
        if (!Current) {
            uint64_t Expected = 0;
            if (Slot.Key.compare_exchange_strong(Expected, Key)) {
                Slot.Class.store(Class, std::memory_order_relaxed);
                Slot.Func.store(Func, std::memory_order_relaxed);
                Slot.Verdict.store(Verdict, std::memory_order_relaxed);
                Slot.Count.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            Current = Expected;
        }
        if (Current == Key) {
            Slot.Count.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }
    DiagOverflow.fetch_add(1, std::memory_order_relaxed);
}

// Weltposition des ausfuehrenden Objekts: Komponente/AnimInstance -> Actor -> RootComponent.RelativeLocation
// (bei nicht angehaengten Wurzeln wie KI, Tieren, Spawnern = Weltposition)
bool ObjectLocation(uintptr_t Object, double& X, double& Y, double& Z) {
    const uint32_t OffRoot = OffRootComponent.load(std::memory_order_relaxed);
    const uint32_t OffRel = OffRelLocation.load(std::memory_order_relaxed);
    if (!OffRoot || !OffRel) return false;
    for (int Step = 0; Step < 4 && LooksLikePointer(Object); ++Step) {
        if (IsA(Object, Cfg.ClsActor)) {
            const uintptr_t Root = Read<uintptr_t>(Object + OffRoot);
            double Value[3];
            if (!LooksLikePointer(Root) || !SafeCopy(Value, Root + OffRel, sizeof(Value))) return false;
            for (double D : Value) if (!(D > -1e8 && D < 1e8)) return false;  // NaN faellt hier auch raus
            X = Value[0];
            Y = Value[1];
            Z = Value[2];
            return true;
        }
        if (!IsA(Object, Cfg.ClsActorComponent) && !IsA(Object, Cfg.ClsAnimInstance)) return false;
        Object = Read<uintptr_t>(Object + Cfg.OffOuter);
    }
    return false;
}

// Runde 9: Anker fuer Funktions-Eintraege braucht eine echte Weltposition (kein CDO/Archetyp: deren RootComponent
// steht auf 0,0,0 - z. B. Default__GameFunctionLibrary_C der statischen Skalierungsfunktionen)
bool AnchorLocation(uintptr_t Object, double& X, double& Y, double& Z) {
    uint32_t ObjectFlags = 0;
    if (!LooksLikePointer(Object) || !TryRead(Object + 0x08, ObjectFlags) || (ObjectFlags & 0x30))  // RF_ClassDefaultObject|RF_ArchetypeObject
        return false;
    return ObjectLocation(Object, X, Y, Z);
}

// Funktions-Eintrag fuer diesen Frame (Stack.Node): VerdictBlack, VerdictWhite oder VerdictNone
int FuncVerdict(const ClassLists* Lists, uintptr_t Node) {
    if (!Lists) return VerdictNone;
    for (int I = 0; I < Lists->BlackFuncs && I < MaxListedFuncs; ++I)
        if (Lists->BlackFunc[I] == Node) return VerdictBlack;
    for (int I = 0; I < Lists->WhiteFuncs && I < MaxListedFuncs; ++I)
        if (Lists->WhiteFunc[I] == Node) return VerdictWhite;
    return VerdictNone;
}

// PlayerController des naechsten Gasts oder 0. Im Diag-Modus nur zaehlen.
// Klassen-Eintrag: erstes erlaubtes Objekt der Kette ist der Anker (ohne Position: erster lebender Gast).
// Runde 9, Funktions-Eintrag "+ Klasse.Funktion": greift, wenn diese UFunction in einem Frame (Tiefe < 8) laeuft; Anker =
// erstes Objekt ab dieser Tiefe nach aussen mit Weltposition (statische Bibliothek -> Zombie/Spawner), ohne Position
// keine Umleitung. Gesperrte Klassen/Funktionen ("-") in der Kette verhindern die Umleitung immer.
uintptr_t NearestGuestPC(uintptr_t Frame) {
    const int Mode = AiNearest.load(std::memory_order_relaxed);
    if (!Mode || SharedGuests.Count <= 0) return 0;  // Hinweis ohne Seqlock: keine Gaeste = Client/Einzelspieler
    const ClassLists* Lists = ActiveLists.load(std::memory_order_acquire);
    const bool HaveFuncs = Lists && (Lists->WhiteFuncs > 0 || Lists->BlackFuncs > 0);
    uintptr_t Anchor = 0, FirstObject = 0, FirstFunc = 0, FuncAnchor = 0;
    bool Black = false, FuncHit = false;
    double FX = 0, FY = 0, FZ = 0;
    uintptr_t Current = Frame;
    for (int Depth = 0; Depth < 8 && IsOnThisStack(Current); ++Depth) {
        const uintptr_t Node = Read<uintptr_t>(Current + Cfg.OffFrameNode);
        if (!IsA(Node, Cfg.ClsFunction)) break;
        const uintptr_t Object = Read<uintptr_t>(Current + Cfg.OffFrameObject);
        if (!Depth) {
            FirstObject = Object;
            FirstFunc = Node;
        }
        const int V = ClassVerdict(Read<uintptr_t>(Object + Cfg.OffClass));
        const int FV = HaveFuncs ? FuncVerdict(Lists, Node) : VerdictNone;
        if (V == VerdictBlack || FV == VerdictBlack) {
            Black = true;
            break;
        }
        if (V == VerdictWhite && !Anchor) Anchor = Object;
        if (FV == VerdictWhite) FuncHit = true;
        if (FuncHit && !FuncAnchor && AnchorLocation(Object, FX, FY, FZ)) FuncAnchor = Object;
        if (!Cfg.OffFramePrevious) break;
        Current = Read<uintptr_t>(Current + Cfg.OffFramePrevious);
    }
    const int Result = Black ? VerdictBlack
                     : FuncAnchor ? VerdictFunc
                     : Anchor ? VerdictWhite
                     : FuncHit ? VerdictFuncNoLoc
                               : VerdictNone;
    if (Mode == 2 && FirstObject) DiagCount(Read<uintptr_t>(FirstObject + Cfg.OffClass), FirstFunc, Result);
    if (Mode != 1 || (Result != VerdictWhite && Result != VerdictFunc)) return 0;
    GuestSnapshot Snapshot;
    if (!ReadGuests(Snapshot)) return 0;
    double X = FX, Y = FY, Z = FZ;
    const bool HavePosition = Result == VerdictFunc || ObjectLocation(Anchor, X, Y, Z);
    uintptr_t Best = 0;
    double BestDistance = 0;
    for (int I = 0; I < Snapshot.Count; ++I) {
        const GuestInfo& Guest = Snapshot.Guests[I];
        if (!IsLiveObject(Guest.PC) || !IsA(Guest.PC, Cfg.ClsPlayerController)) continue;
        const double Distance = HavePosition ? (Guest.X - X) * (Guest.X - X) + (Guest.Y - Y) * (Guest.Y - Y) +
                                                   (Guest.Z - Z) * (Guest.Z - Z)
                                             : 0.0;
        if (!Best || Distance < BestDistance) {
            Best = Guest.PC;
            BestDistance = Distance;
        }
        if (!HavePosition) break;  // ohne Position: erster lebender Gast
    }
    return Best;
}

// ---------------------------------------------------------------------------------------------------------
// N4b: Beobachter fuer Blueprint-Aufrufe. Die Handler fuer EX_FinalFunction (0x1C), EX_LocalFinalFunction
// (0x46), EX_VirtualFunction (0x1B), EX_LocalVirtualFunction (0x45) und EX_CallMath (0x68) in GNatives
// werden durch ObserveHook<Op> ersetzt. Beim Eintritt steht Stack.Code hinter dem Opcode (UFunction* bzw.
// FScriptName). Ziele aus netcore_watch.txt ("<UFunction hex> <tag> observe|suppress [force]") erzeugen ein
// Ereignis im Ring (Kontext, Aufrufer, die ersten MaxArgs Argumente, wenn Konstante oder Lokale/Instanzvariable).
// suppress: Stack.Code ueber die Argumente bis hinter EX_EndFunctionParms setzen, Rueckgabewert nullen.
// Die Wrapper laufen auf dem Spielthread und auf Anim-Worker-Threads: nur lesen, Ring ist Multi-Producer.
// Runde 5b: zusaetzlich "Eintritt" (at=entry) fuer Blueprint-Funktionen: Erkennung am ersten Opcode ihres eigenen
// Scripts (Stack.Node == Funktion, Stack.Code - 1 == Script.GetData()). Das sieht auch ProcessEvent-Aufrufe
// (RPC-Ankunft, Multicast, BeginPlay, Timer), die Parameter liegen dann vollstaendig in Stack.Locals. Dafuer wird
// zusaetzlich EX_LetValueOnPersistentFrame (0x64, erster Opcode jedes Event-Stubs mit Parametern) umgelenkt.
// Vor-Aktionen beim Eintritt: ff (erstes Objekt-Argument auf null, wenn es ein Spieler ist) und sd (float-
// Eigenschaft des Kontexts = Abstand Besitzer -> erstes Objekt-Argument), beides vor dem Kopieren in den Ubergraph.
// Runde 9: 6 statt 4 (CORE-18: AISense_Hearing:ReportNoiseEvent braucht MaxRange und Tag; Status maxargs=6)
constexpr int MaxArgs = 6;
constexpr int MaxWatches = 128;
constexpr size_t WatchSlots = 512;  // Zweierpotenz, > 2 * MaxWatches

struct ParamDesc {
    uint8_t Type;    // 'o' 'i' 'f' 'd' 'b' 's' 'n' 'v' (FVector) 'r' (FRotator) 'c' (FLinearColor) '?'
    uint8_t Out;     // Out-Parameter (Wert vor dem Aufruf sinnlos)
    uint16_t Size;   // ElementSize
    int32_t Offset;  // Offset_Internal (Lage in Stack.Locals beim Eintritt)
};

struct WatchEntry {
    uintptr_t Func;
    uint64_t Name;      // FName der Funktion (Virtual-Aufrufe kommen per Name)
    uintptr_t Owner;    // Klasse der Funktion
    char Tag[32];
    uint8_t Suppress;
    uint8_t NumArgs;
    uint16_t RetSize;   // Bytes des Rueckgabewerts (0 = keiner)
    ParamDesc Params[MaxArgs];
    uint8_t AtEntry;    // 1 = beim Eintritt in die (Blueprint-)Funktion, 0 = an der Aufrufstelle
    uint8_t LocalOnly;  // local=1: nur Kontexte, die dem lokalen PC gehoeren
    uint8_t RemoteOnly; // remote=1 (Runde 9): nur Kontexte fremder Spielerfiguren (IsRemoteContext)
    uint8_t FfMode;     // 0 aus, 1 = IsA(FfClass), 2 = Figur mit PlayerController
    int8_t TargetArg;   // Index des ersten Objekt-Arguments unter Params (-1 = nicht aufgezeichnet)
    int32_t TargetOffset;  // Offset_Internal des ersten Objekt-Parameters (-1 = keiner)
    uintptr_t FfClass;
    uint32_t SdOffset;  // sd=<hex>: float-Eigenschaft des Kontexts (0 = aus)
    uintptr_t ScriptData;  // Script.GetData() beim Aufbau (Eintritt)
    int32_t SkipTo;     // Eintritt + suppress: Offset des abschliessenden EX_Return (0 = nicht moeglich)
    uint8_t RetUnsafe;  // Rueckgabewert kein POD (FText/FString/TArray...): an der Aufrufstelle nie nullen/ueberspringen
    // pvp=1: Verursacher fuer ff (Objekt-Parameter "*Causer*" bzw. "*Instigator*", -1 = keiner)
    int8_t CauserArg, InstigatorArg;     // Index unter Params (Aufrufstelle)
    int32_t CauserOffset, InstigatorOffset;  // Offset_Internal (Eintritt)
    uint64_t OwnerName;  // FName der Klasse beim Aufbau (Identitaet beim Neuaufbau aus demselben Text)
};

struct WatchTable {
    int32_t Count = 0;
    int32_t Suppressing = 0;
    int32_t CallCount = 0, EntryCount = 0;
    WatchEntry Entries[MaxWatches] = {};
    int16_t ByFunc[WatchSlots];
    int16_t ByName[WatchSlots];
    int16_t ByEntry[WatchSlots];
    WatchTable() {
        for (size_t I = 0; I < WatchSlots; ++I) ByFunc[I] = ByName[I] = ByEntry[I] = -1;
    }
};
std::atomic<const WatchTable*> ActiveWatch{nullptr};

size_t WatchSlot(uint64_t Key) { return static_cast<size_t>((Key * 0x9E3779B97F4A7C15ull) >> 55); }  // 9 Bit

const WatchEntry* FindWatchByFunc(const WatchTable* Table, uint64_t Func) {
    for (size_t I = WatchSlot(Func), Probe = 0; Probe < WatchSlots; ++Probe, I = (I + 1) & (WatchSlots - 1)) {
        const int16_t Index = Table->ByFunc[I];
        if (Index < 0) return nullptr;
        if (Table->Entries[Index].Func == Func) return &Table->Entries[Index];
    }
    return nullptr;
}

const WatchEntry* FindWatchByEntry(const WatchTable* Table, uint64_t Func) {
    for (size_t I = WatchSlot(Func), Probe = 0; Probe < WatchSlots; ++Probe, I = (I + 1) & (WatchSlots - 1)) {
        const int16_t Index = Table->ByEntry[I];
        if (Index < 0) return nullptr;
        if (Table->Entries[Index].Func == Func) return &Table->Entries[Index];
    }
    return nullptr;
}

const WatchEntry* FindWatchByName(const WatchTable* Table, uint64_t Name, uintptr_t Context) {
    for (size_t I = WatchSlot(Name), Probe = 0; Probe < WatchSlots; ++Probe, I = (I + 1) & (WatchSlots - 1)) {
        const int16_t Index = Table->ByName[I];
        if (Index < 0) return nullptr;
        const WatchEntry& Entry = Table->Entries[Index];
        if (Entry.Name == Name && IsA(Context, Entry.Owner)) return &Entry;
    }
    return nullptr;
}

struct EventArg {
    uint8_t Type;   // wie ParamDesc, dazu '^' (Out-Parameter), 0 = nicht gelesen
    uint8_t Len;    // Zeichen in Text (bei v/r/c: Bytes des Structs in Text)
    uint64_t Raw;   // Zahl, Bits von float/double, UObject*, FName
    uint16_t Text[40];
};

// EventRec::Flags (Spalte 3 der Ereigniszeile hinter o/s)
enum EventFlag : uint8_t {
    EvRemote = 1,     // R: Kontext gehoert nicht dem lokalen PC (nur wenn local_pc bekannt)
    EvLocal = 2,      // L: Kontext gehoert dem lokalen PC
    EvBlocked = 4,    // F: ff hat das Ziel auf null gesetzt bzw. den Aufruf uebersprungen
    EvEntry = 8,      // E: beim Eintritt aufgezeichnet (Parameter aus Locals)
    EvDistance = 16,  // D: sd hat den Abstand geschrieben
};

struct EventRec {
    char Tag[32];
    uintptr_t Func, Context, Caller;
    uint64_t TimeMs;
    uint8_t Suppressed, NumArgs, Flags;
    EventArg Args[MaxArgs];
};

// Begrenzter MPMC-Ring nach Vyukov (hier ein Verbraucher: der Worker)
constexpr size_t RingSize = 4096;
struct RingCell {
    std::atomic<uint64_t> Seq;
    EventRec Rec;
};
RingCell Ring[RingSize];
std::atomic<uint64_t> RingHead{0};
uint64_t RingTail = 0;  // nur Worker

void InitRing() {
    for (size_t I = 0; I < RingSize; ++I) Ring[I].Seq.store(I, std::memory_order_relaxed);
}

bool RingPush(const EventRec& Rec) {
    uint64_t Pos = RingHead.load(std::memory_order_relaxed);
    for (;;) {
        RingCell& Cell = Ring[Pos & (RingSize - 1)];
        const uint64_t Seq = Cell.Seq.load(std::memory_order_acquire);
        const int64_t Diff = static_cast<int64_t>(Seq) - static_cast<int64_t>(Pos);
        if (Diff == 0) {
            if (RingHead.compare_exchange_weak(Pos, Pos + 1, std::memory_order_relaxed)) {
                Cell.Rec = Rec;
                Cell.Seq.store(Pos + 1, std::memory_order_release);
                return true;
            }
        } else if (Diff < 0) {
            return false;  // voll
        } else {
            Pos = RingHead.load(std::memory_order_relaxed);
        }
    }
}

bool RingPop(EventRec& Out) {
    RingCell& Cell = Ring[RingTail & (RingSize - 1)];
    const uint64_t Seq = Cell.Seq.load(std::memory_order_acquire);
    if (static_cast<int64_t>(Seq) - static_cast<int64_t>(RingTail + 1) != 0) return false;
    Out = Cell.Rec;
    Cell.Seq.store(RingTail + RingSize, std::memory_order_release);
    ++RingTail;
    return true;
}

NativeFunc ObsOriginal[256] = {};
std::atomic<bool> ObserverOn{false};
std::atomic<int> ObserverFaults{0};
std::atomic<uint64_t> ObsEvents{0}, ObsDropped{0}, ObsSuppressed{0}, ObsSkipFailed{0};
std::atomic<uint64_t> ObsEntryEvents{0}, ObsFfBlocked{0}, ObsDistances{0}, ObsFfPvpPassed{0};

// Wert eines Parameters im Speicher (Lokale/Instanzvariable an der Aufrufstelle, Locals beim Eintritt)
void ReadValueAt(const ParamDesc& Param, uintptr_t At, EventArg& Out) {
    switch (Param.Type) {
    case 'o': case 'n':
        if (TryRead(At, Out.Raw)) Out.Type = Param.Type;
        return;
    case 'i': {
        if (Param.Size == 1) Out.Raw = Read<uint8_t>(At);
        else if (Param.Size == 2) Out.Raw = static_cast<uint64_t>(static_cast<int64_t>(Read<int16_t>(At)));
        else if (Param.Size == 4) Out.Raw = static_cast<uint64_t>(static_cast<int64_t>(Read<int32_t>(At)));
        else if (Param.Size == 8) Out.Raw = Read<uint64_t>(At);
        else return;
        Out.Type = 'i';
        return;
    }
    case 'f': Out.Raw = Read<uint32_t>(At); Out.Type = 'f'; return;
    case 'd': Out.Raw = Read<uint64_t>(At); Out.Type = 'd'; return;
    case 'b': Out.Raw = Read<uint8_t>(At) ? 1 : 0; Out.Type = 'b'; return;
    case 's': {  // FString { TCHAR* Data, int32 Num (inkl. 0), int32 Max }
        const uintptr_t Data = Read<uintptr_t>(At);
        const int32_t Num = Read<int32_t>(At + 8);
        Out.Type = 's';
        Out.Len = 0;
        if (!Data || Num <= 1) return;
        const int32_t Count = Num - 1 < 40 ? Num - 1 : 40;
        if (SafeCopy(Out.Text, Data, static_cast<size_t>(Count) * 2)) Out.Len = static_cast<uint8_t>(Count);
        return;
    }
    case 'v': case 'r':  // FVector / FRotator: 3 double
        if (SafeCopy(Out.Text, At, 24)) {
            Out.Type = Param.Type;
            Out.Len = 24;
        }
        return;
    case 'c':  // FLinearColor: 4 float
        if (SafeCopy(Out.Text, At, 16)) {
            Out.Type = 'c';
            Out.Len = 16;
        }
        return;
    default: return;
    }
}

// Wert eines Arguments aus Konstante (im Bytecode) oder Lokaler/Instanzvariable (im Speicher)
void ReadArgument(const ParamDesc& Param, const uint8_t* Expr, size_t Length, uintptr_t Stack, EventArg& Out) {
    Out.Type = '?';
    if (Param.Out) {
        Out.Type = '^';
        return;
    }
    if (!Length) return;
    switch (Expr[0]) {
    case 0x00: case 0x01: {  // LocalVariable / InstanceVariable: FProperty*, Wert bei Basis + Offset_Internal
        if (Length < 9) return;
        uint64_t Property = 0;
        memcpy(&Property, Expr + 1, 8);
        const int32_t Offset = Read<int32_t>(static_cast<uintptr_t>(Property) + 0x44);
        const uintptr_t Base = Read<uintptr_t>(Stack + (Expr[0] == 0x00 ? Cfg.OffFrameLocals : Cfg.OffFrameObject));
        if (!LooksLikePointer(Base) || Offset < 0 || Offset > 0x100000) return;
        ReadValueAt(Param, Base + static_cast<uint32_t>(Offset), Out);
        return;
    }
    case 0x22: case 0x23:  // RotationConst / VectorConst: 3 double
        if (Length >= 25 && Param.Type == (Expr[0] == 0x23 ? 'v' : 'r')) {
            memcpy(Out.Text, Expr + 1, 24);
            Out.Type = Param.Type;
            Out.Len = 24;
        }
        return;
    case 0x1D: if (Length >= 5) { int32_t V; memcpy(&V, Expr + 1, 4); Out.Raw = static_cast<uint64_t>(static_cast<int64_t>(V)); Out.Type = 'i'; } return;
    case 0x25: Out.Raw = 0; Out.Type = 'i'; return;
    case 0x26: Out.Raw = 1; Out.Type = 'i'; return;
    case 0x24: case 0x2C: if (Length >= 2) { Out.Raw = Expr[1]; Out.Type = 'i'; } return;
    case 0x35: case 0x36: if (Length >= 9) { memcpy(&Out.Raw, Expr + 1, 8); Out.Type = 'i'; } return;
    case 0x27: Out.Raw = 1; Out.Type = 'b'; return;
    case 0x28: Out.Raw = 0; Out.Type = 'b'; return;
    case 0x1E: if (Length >= 5) { uint32_t V; memcpy(&V, Expr + 1, 4); Out.Raw = V; Out.Type = 'f'; } return;
    case 0x37: if (Length >= 9) { memcpy(&Out.Raw, Expr + 1, 8); Out.Type = 'd'; } return;
    case 0x20: if (Length >= 9) { memcpy(&Out.Raw, Expr + 1, 8); Out.Type = 'o'; } return;
    case 0x2A: Out.Raw = 0; Out.Type = 'o'; return;
    case 0x17: Out.Raw = Read<uintptr_t>(Stack + Cfg.OffFrameObject); Out.Type = 'o'; return;
    case 0x21: if (Length >= 13) {  // FScriptName: ComparisonIndex, DisplayIndex, Number
        uint32_t Index, Number;
        memcpy(&Index, Expr + 1, 4);
        memcpy(&Number, Expr + 9, 4);
        Out.Raw = static_cast<uint64_t>(Index) | (static_cast<uint64_t>(Number) << 32);
        Out.Type = 'n';
    } return;
    case 0x1F: {  // ANSI (Latin-1)
        Out.Type = 's';
        Out.Len = 0;
        for (size_t I = 1; I < Length && Expr[I] && Out.Len < 40; ++I) Out.Text[Out.Len++] = Expr[I];
        return;
    }
    case 0x34: {  // UTF-16
        Out.Type = 's';
        Out.Len = 0;
        for (size_t I = 1; I + 1 < Length && Out.Len < 40; I += 2) {
            uint16_t C;
            memcpy(&C, Expr + I, 2);
            if (!C) break;
            Out.Text[Out.Len++] = C;
        }
        return;
    }
    default: return;
    }
}

// R/L: gehoert der Kontext (Waffe -> Besitzer -> Controller) dem lokalen PC? Ohne local_pc: keine Angabe.
// Statische Bibliotheksaufrufe (EX_Context auf das CDO, z. B. GameplayStatics:ApplyDamage) laufen im CDO,
// das niemandem gehoert: dann zaehlt der Aufrufer (Stack.Object bzw. Objekt des vorigen Frames).
uint8_t OwnerFlags(uintptr_t Context, uintptr_t Caller) {
    const uintptr_t Local = LocalPC.load(std::memory_order_relaxed);
    if (!Local) return 0;
    uint32_t ObjectFlags = 0;
    if (LooksLikePointer(Context) && LooksLikePointer(Caller) && TryRead(Context + 0x08, ObjectFlags) &&
        (ObjectFlags & 0x10))  // RF_ClassDefaultObject
        Context = Caller;
    return ResolvePlayerController(Context) == Local ? EvLocal : EvRemote;
}

// ff: Ziel ist ein Spieler (Klasse aus ff=<hex>, sonst eine Figur, deren Controller ein PlayerController ist)
bool IsFfTarget(const WatchEntry& Entry, uintptr_t Target) {
    if (!LooksLikePointer(Target)) return false;
    if (Entry.FfMode == 1) return IsA(Target, Entry.FfClass);
    if (Entry.FfMode == 2)
        return IsA(Target, Cfg.ClsPawn) && IsA(Read<uintptr_t>(Target + Cfg.OffPawnController), Cfg.ClsPlayerController);
    return false;
}

bool IsCdo(uintptr_t Object) {
    uint32_t ObjectFlags = 0;
    return LooksLikePointer(Object) && TryRead(Object + 0x08, ObjectFlags) && (ObjectFlags & 0x10);  // RF_ClassDefaultObject
}

// remote=1 (Runde 9, WORLD-7): gehoert der Kontext einer FREMDEN Spielerfigur? Besitzerkette (Komponente/AnimInstance ->
// Outer, Actor -> Owner, hoechstens 8 Schritte) bis zur ersten Figur: fremd, wenn sie eine Spielerfigur ist (PlayerState
// gesetzt) und ihr Controller nicht local_pc ist (beim Gast haben fremde Figuren keinen Controller). Ein PlayerController
// in der Kette zaehlt ueber seine Figur. KI-Figuren, Kontexte ohne Figur, unbekanntes local_pc (ausser Gast) oder
// unbekannter PlayerState-Offset: nie fremd (nichts unterdruecken). CDO-Kontext (statische Bibliothek, z. B.
// Default__GameFunctionLibrary_C->CreateNotificationUI): der Aufrufer zaehlt, ist auch der ein CDO, die Objekte der
// vorigen Frames (bis 8). CallerFrame = Frame, dessen Objekt der Aufrufer ist (Aufrufstelle: Stack, Eintritt: voriger).
// Gast (netmode=client): dort existiert nur der eigene PC, fremde Spielerfiguren haben keinen Controller -> fremd heisst
// "kein Controller"; so zaehlt die eigene Figur auch mit veraltetem local_pc (kurz nach dem Weltwechsel) nie als fremd.
bool IsRemoteContext(uintptr_t Context, uintptr_t Caller, uintptr_t CallerFrame) {
    const uintptr_t Local = LocalPC.load(std::memory_order_relaxed);
    const uint32_t OffPlayerState = OffPawnPlayerState.load(std::memory_order_relaxed);
    const bool Client = NetModeOpt.load(std::memory_order_relaxed) == NetClient;
    if (!OffPlayerState || (!Local && !Client)) return false;
    uintptr_t Object = Context;
    if (IsCdo(Object)) {
        Object = Caller;
        uintptr_t Frame = CallerFrame;
        for (int Depth = 0; Depth < 8 && IsCdo(Object) && Cfg.OffFramePrevious && IsOnThisStack(Frame); ++Depth) {
            Frame = Read<uintptr_t>(Frame + Cfg.OffFramePrevious);
            Object = IsOnThisStack(Frame) ? Read<uintptr_t>(Frame + Cfg.OffFrameObject) : 0;
        }
    }
    for (int Step = 0; Step < 8 && LooksLikePointer(Object) && !IsCdo(Object); ++Step) {
        if (IsA(Object, Cfg.ClsPawn)) {
            if (!LooksLikePointer(Read<uintptr_t>(Object + OffPlayerState))) return false;  // KI oder tote/abgegebene Figur
            const uintptr_t Controller = Read<uintptr_t>(Object + Cfg.OffPawnController);
            return Client ? !Controller : Controller != Local;
        }
        if (IsA(Object, Cfg.ClsPlayerController)) {  // PC -> seine Figur (ohne Figur: nie fremd)
            if (!Cfg.OffControllerPawn) return false;
            Object = Read<uintptr_t>(Object + Cfg.OffControllerPawn);
        } else if (IsA(Object, Cfg.ClsActorComponent) || IsA(Object, Cfg.ClsAnimInstance)) {
            Object = Read<uintptr_t>(Object + Cfg.OffOuter);
        } else if (IsA(Object, Cfg.ClsActor) && Cfg.OffActorOwner) {
            Object = Read<uintptr_t>(Object + Cfg.OffActorOwner);
        } else {
            return false;
        }
    }
    return false;
}

// Clan-Verbuendete (netcore_allies.txt, Lua: Native.SetAllies): Figur -> Clan-Index (> 0). Nur der Worker baut,
// Leser holen den Zeiger einmal (alte Tabellen werden erst 30 s nach dem Tausch freigegeben).
constexpr int MaxAllies = 64;
struct AlliesTable {
    int32_t Count = 0;
    uintptr_t Pawn[MaxAllies] = {};
    int32_t Clan[MaxAllies] = {};
    uintptr_t Class[MaxAllies] = {};   // Pruefung im Worker (Figur gestorben, Adresse neu vergeben)
    int32_t ObjIndex[MaxAllies] = {};
};
std::atomic<const AlliesTable*> ActiveAllies{nullptr};

int ClanIndexOf(const AlliesTable* Allies, uintptr_t Pawn) {
    if (!Allies || !Pawn) return 0;
    for (int I = 0; I < Allies->Count && I < MaxAllies; ++I)
        if (Allies->Pawn[I] == Pawn) return Allies->Clan[I];
    return 0;
}

// Figur hinter einem Verursacher: Figur selbst, PlayerController -> Pawn, Komponente -> Actor,
// Waffe/Projektil -> Owner (hoechstens 4 Schritte)
uintptr_t PawnOfObject(uintptr_t Object) {
    for (int Step = 0; Step < 5 && LooksLikePointer(Object); ++Step) {
        if (IsA(Object, Cfg.ClsPawn)) return Object;
        if (IsA(Object, Cfg.ClsPlayerController)) {
            if (!Cfg.OffControllerPawn) return 0;
            Object = Read<uintptr_t>(Object + Cfg.OffControllerPawn);
        } else if (IsA(Object, Cfg.ClsActorComponent) || IsA(Object, Cfg.ClsAnimInstance)) {
            Object = Read<uintptr_t>(Object + Cfg.OffOuter);
        } else if (IsA(Object, Cfg.ClsActor) && Cfg.OffActorOwner) {
            Object = Read<uintptr_t>(Object + Cfg.OffActorOwner);
        } else {
            return 0;
        }
    }
    return 0;
}

// ff-Entscheidung. pvp=0: jedes Spielerziel (bisheriges Verhalten). pvp=1: nur, wenn Ziel und Figur des
// Verursachers (Kandidaten der Reihe nach: Causer-Parameter, Instigator-Parameter, Kontext bzw. Aufrufer bei CDO)
// denselben Clan-Index > 0 haben. Eigenschaden (Verursacher-Figur == Ziel) bleibt immer erlaubt.
bool FfBlocks(const WatchEntry& Entry, uintptr_t Target, uintptr_t Cand1, uintptr_t Cand2, uintptr_t Cand3) {
    if (!IsFfTarget(Entry, Target)) return false;
    if (!PvpMode.load(std::memory_order_relaxed)) return true;
    const AlliesTable* Allies = ActiveAllies.load(std::memory_order_acquire);
    const int TargetClan = ClanIndexOf(Allies, Target);
    uintptr_t CauserPawn = PawnOfObject(Cand1);
    if (!CauserPawn) CauserPawn = PawnOfObject(Cand2);
    if (!CauserPawn) CauserPawn = PawnOfObject(Cand3);
    // Verbuendet nur als Spielerfigur (PlayerController): eine neu vergebene Adresse (z. B. Zombie) zaehlt nie
    const bool Block = TargetClan > 0 && CauserPawn && CauserPawn != Target && ClanIndexOf(Allies, CauserPawn) == TargetClan &&
                       IsA(Read<uintptr_t>(CauserPawn + Cfg.OffPawnController), Cfg.ClsPlayerController);
    if (!Block) ObsFfPvpPassed.fetch_add(1, std::memory_order_relaxed);
    return Block;
}

uintptr_t ArgObject(const EventRec& Rec, int8_t Index) {
    if (Index < 0 || Index >= Rec.NumArgs || Rec.Args[Index].Type != 'o') return 0;
    return static_cast<uintptr_t>(Rec.Args[Index].Raw);
}

// sd: Kontext.<float bei SdOffset> = Abstand (cm) Besitzer des Kontexts -> Ziel, beide ueber RootComponent
bool WriteShotDistance(const WatchEntry& Entry, uintptr_t Context, uintptr_t Target) {
    if (!Cfg.OffActorOwner || !LooksLikePointer(Context)) return false;
    const uintptr_t Owner = Read<uintptr_t>(Context + Cfg.OffActorOwner);
    double X1, Y1, Z1, X2, Y2, Z2;
    if (!LooksLikePointer(Owner) || !ObjectLocation(Owner, X1, Y1, Z1) || !ObjectLocation(Target, X2, Y2, Z2)) return false;
    const double D = sqrt((X1 - X2) * (X1 - X2) + (Y1 - Y2) * (Y1 - Y2) + (Z1 - Z2) * (Z1 - Z2));
    if (!(D >= 0 && D < 1e7)) return false;
    const float Value = static_cast<float>(D);
    if (!SafeWrite(Context + Entry.SdOffset, &Value, sizeof(Value))) return false;
    ObsDistances.fetch_add(1, std::memory_order_relaxed);
    return true;
}

// CORE-25 (b): Watch-Zeilen prueft der Worker nur jede Sekunde. Eine in dieser Zeit neu vergebene Adresse darf keine
// andere Funktion beobachten, unterdruecken oder per ff/sd veraendern: FName und Klasse wie beim Aufbau (zwei geschuetzte
// Lesezugriffe, laeuft fuer jeden Treffer vor allem anderen).
bool WatchIdentityOk(const WatchEntry& Entry) {
    return Read<uint64_t>(Entry.Func + OffObjectName) == Entry.Name &&
           Read<uintptr_t>(Entry.Func + Cfg.OffOuter) == Entry.Owner;
}

// true = Aufruf unterdrueckt (Stack.Code steht schon hinter EX_EndFunctionParms)
bool ObserveCallInner(uint8_t Op, const WatchTable* Table, uintptr_t Context, uintptr_t Stack, void* Result) {
    const uintptr_t Code = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameCode);
    if (Code < 0x10000) return false;
    const bool Virtual = Op == 0x1B || Op == 0x45;
    const WatchEntry* Entry;
    if (Virtual) {
        uint32_t Index = 0, Number = 0;
        memcpy(&Index, reinterpret_cast<const void*>(Code), 4);
        memcpy(&Number, reinterpret_cast<const void*>(Code + 8), 4);
        Entry = FindWatchByName(Table, static_cast<uint64_t>(Index) | (static_cast<uint64_t>(Number) << 32), Context);
    } else {
        uint64_t Func = 0;
        memcpy(&Func, reinterpret_cast<const void*>(Code), 8);
        Entry = FindWatchByFunc(Table, Func);
    }
    if (!Entry || !WatchIdentityOk(*Entry)) return false;
    const uintptr_t Caller = Read<uintptr_t>(Stack + Cfg.OffFrameObject);
    // remote=1: nur Kontexte fremder Spielerfiguren (vor dem Lesen der Argumente, die meisten Aufrufe sind eigene)
    if (Entry->RemoteOnly && !IsRemoteContext(Context, Caller, Stack)) return false;

    // Ab dem Opcode kopieren (Puffer[0] = Op), notfalls nur bis zum Seitenende
    uint8_t Buffer[1024];
    const uintptr_t From = Code - 1;
    size_t Size = sizeof(Buffer);
    if (!SafeCopy(Buffer, From, Size)) {
        Size = 0x1000 - (From & 0xFFF);
        if (Size >= sizeof(Buffer) || !SafeCopy(Buffer, From, Size)) Size = 0;
    }
    EventRec Rec;
    memset(&Rec, 0, sizeof(Rec));
    memcpy(Rec.Tag, Entry->Tag, sizeof(Rec.Tag));
    Rec.Func = Entry->Func;
    Rec.Context = Context;
    Rec.Caller = Caller;
    Rec.TimeMs = GetTickCount64();
    size_t End = BadPos;
    if (Size) {
        KismetWalker Walker{Buffer, Size, nullptr};
        size_t Pos = 1 + (Virtual ? 12 : 8);
        for (int Arg = 0; Arg < 32 && Walker.Has(Pos, 1); ++Arg) {
            if (Buffer[Pos] == 0x16) {  // EX_EndFunctionParms
                End = Pos + 1;
                break;
            }
            const size_t Next = Walker.Expr(Pos, 1);
            if (Next == BadPos) break;
            if (Arg < Entry->NumArgs && Arg < MaxArgs) {
                ReadArgument(Entry->Params[Arg], Buffer + Pos, Next - Pos, Stack, Rec.Args[Arg]);
                Rec.NumArgs = static_cast<uint8_t>(Arg + 1);
            }
            Pos = Next;
        }
    }
    Rec.Flags = OwnerFlags(Context, Rec.Caller);
    if (Entry->LocalOnly && (Rec.Flags & EvRemote)) return false;
    // Vor-Aktionen an der Aufrufstelle: Ziel nur bekannt, wenn das Argument lesbar war (Lokale/Instanzvariable)
    const uintptr_t Target = Entry->TargetArg >= 0 && Entry->TargetArg < Rec.NumArgs &&
                                     Rec.Args[Entry->TargetArg].Type == 'o'
                                 ? static_cast<uintptr_t>(Rec.Args[Entry->TargetArg].Raw)
                                 : 0;
    const bool Blocked = Entry->FfMode && FfBlocks(*Entry, Target, ArgObject(Rec, Entry->CauserArg),
                                                   ArgObject(Rec, Entry->InstigatorArg),
                                                   IsCdo(Context) ? Rec.Caller : Context);
    // sd nicht fuer eigene Waffen (L): deren Wert stammt exakt aus dem FireTrace des Spiels
    if (!Blocked && Entry->SdOffset && Target && !(Rec.Flags & EvLocal) && WriteShotDistance(*Entry, Context, Target))
        Rec.Flags |= EvDistance;
    bool Suppress = false;
    if (Entry->Suppress || Blocked) {
        if (End != BadPos && !(Result && Entry->RetSize && Entry->RetUnsafe)) {
            *reinterpret_cast<uintptr_t*>(Stack + Cfg.OffFrameCode) = From + End;
            if (Result && Entry->RetSize) memset(Result, 0, Entry->RetSize);
            Suppress = true;
            if (Blocked) {
                Rec.Flags |= EvBlocked;
                ObsFfBlocked.fetch_add(1, std::memory_order_relaxed);
            } else {
                ObsSuppressed.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            ObsSkipFailed.fetch_add(1, std::memory_order_relaxed);
        }
    }
    Rec.Suppressed = Suppress ? 1 : 0;
    if (RingPush(Rec)) ObsEvents.fetch_add(1, std::memory_order_relaxed);
    else ObsDropped.fetch_add(1, std::memory_order_relaxed);
    return Suppress;
}

bool ObserveCall(uint8_t Op, const WatchTable* Table, uintptr_t Context, uintptr_t Stack, void* Result) {
    __try {
        return ObserveCallInner(Op, Table, Context, Stack, Result);
    } __except (FaultFilter(GetExceptionCode())) {
        if (ObserverFaults.fetch_add(1) + 1 >= 3) ObserverOn.store(false);
        return false;
    }
}

// Eintritt in eine beobachtete Blueprint-Funktion: der aktuelle Frame IST die Funktion (Stack.Node), und der
// gerade ausgefuehrte Opcode ist der erste ihres Scripts. Parameter liegen vollstaendig in Stack.Locals.
// true = unterdrueckt (Stack.Code steht auf dem abschliessenden EX_Return, Original nicht aufrufen)
bool ObserveEntryInner(const WatchTable* Table, uintptr_t Stack) {
    const uintptr_t Node = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameNode);
    const WatchEntry* Entry = FindWatchByEntry(Table, Node);
    if (!Entry) return false;
    const uintptr_t Code = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameCode);
    if (Code - 1 != Entry->ScriptData) return false;  // nicht der erste Opcode (z. B. spaeterer Aufruf im Rumpf)
    if (!WatchIdentityOk(*Entry)) return false;       // CORE-25 (b): Adresse inzwischen eine andere Funktion
    const uintptr_t Context = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameObject);
    const uintptr_t Locals = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameLocals);
    EventRec Rec;
    memset(&Rec, 0, sizeof(Rec));
    const uint32_t OffPrevious = Cfg.OffFramePrevious ? Cfg.OffFramePrevious : 0x78;
    const uintptr_t Previous = Read<uintptr_t>(Stack + OffPrevious);
    const bool HavePrevious = IsOnThisStack(Previous);
    Rec.Caller = HavePrevious ? Read<uintptr_t>(Previous + Cfg.OffFrameObject) : 0;
    Rec.Flags = static_cast<uint8_t>(OwnerFlags(Context, Rec.Caller) | EvEntry);
    if (Entry->LocalOnly && (Rec.Flags & EvRemote)) return false;
    // remote=1 (Runde 9): nur Kontexte fremder Spielerfiguren; Aufrufer = Objekt des vorigen Frames
    if (Entry->RemoteOnly && !IsRemoteContext(Context, Rec.Caller, HavePrevious ? Previous : 0)) return false;
    memcpy(Rec.Tag, Entry->Tag, sizeof(Rec.Tag));
    Rec.Func = Entry->Func;
    Rec.Context = Context;
    Rec.TimeMs = GetTickCount64();
    const bool HaveLocals = LooksLikePointer(Locals);
    // Vor-Aktionen: vor dem ersten Opcode, also bevor der Stub die Parameter in den Ubergraph kopiert
    if (HaveLocals && Entry->TargetOffset >= 0) {
        const uintptr_t Slot = Locals + static_cast<uint32_t>(Entry->TargetOffset);
        const uintptr_t Target = Read<uintptr_t>(Slot);
        const uintptr_t Causer = Entry->CauserOffset >= 0 ? Read<uintptr_t>(Locals + static_cast<uint32_t>(Entry->CauserOffset)) : 0;
        const uintptr_t Instigator =
            Entry->InstigatorOffset >= 0 ? Read<uintptr_t>(Locals + static_cast<uint32_t>(Entry->InstigatorOffset)) : 0;
        if (Entry->FfMode && FfBlocks(*Entry, Target, Causer, Instigator, IsCdo(Context) ? Rec.Caller : Context)) {
            const uintptr_t Null = 0;
            if (SafeWrite(Slot, &Null, sizeof(Null))) {
                Rec.Flags |= EvBlocked;
                ObsFfBlocked.fetch_add(1, std::memory_order_relaxed);
            }
        } else if (Entry->SdOffset && Target && !(Rec.Flags & EvLocal) && WriteShotDistance(*Entry, Context, Target)) {
            Rec.Flags |= EvDistance;
        }
    }
    for (int I = 0; I < Entry->NumArgs && I < MaxArgs; ++I) {
        EventArg& Arg = Rec.Args[I];
        Arg.Type = '?';
        if (Entry->Params[I].Out) Arg.Type = '^';
        else if (HaveLocals && Entry->Params[I].Offset >= 0)
            ReadValueAt(Entry->Params[I], Locals + static_cast<uint32_t>(Entry->Params[I].Offset), Arg);
        Rec.NumArgs = static_cast<uint8_t>(I + 1);
    }
    // Den Wert vor ff aufzeichnen waere irrefuehrend: das Ereignis zeigt das Ziel, das ff genullt hat, trotzdem an
    if ((Rec.Flags & EvBlocked) && Entry->TargetArg >= 0 && Entry->TargetArg < Rec.NumArgs) {
        Rec.Args[Entry->TargetArg].Type = 'o';
        Rec.Args[Entry->TargetArg].Raw = 0;
    }
    bool Suppress = false;
    if (Entry->Suppress && Entry->SkipTo > 0) {
        *reinterpret_cast<uintptr_t*>(Stack + Cfg.OffFrameCode) = Entry->ScriptData + static_cast<uint32_t>(Entry->SkipTo);
        Suppress = true;
        ObsSuppressed.fetch_add(1, std::memory_order_relaxed);
    }
    Rec.Suppressed = Suppress ? 1 : 0;
    ObsEntryEvents.fetch_add(1, std::memory_order_relaxed);
    if (RingPush(Rec)) ObsEvents.fetch_add(1, std::memory_order_relaxed);
    else ObsDropped.fetch_add(1, std::memory_order_relaxed);
    return Suppress;
}

bool ObserveEntry(const WatchTable* Table, uintptr_t Stack) {
    __try {
        return ObserveEntryInner(Table, Stack);
    } __except (FaultFilter(GetExceptionCode())) {
        if (ObserverFaults.fetch_add(1) + 1 >= 3) ObserverOn.store(false);
        return false;
    }
}

// ---------------------------------------------------------------------------------------------------------
// Sperrliste (Runde 7, netcore_deny.txt, Lua: Native.SetDeny, nur Host): ein Aufruf einer Blueprint-Funktion wird
// beim EINTRITT verworfen, wenn der Kontext (Stack.Object) und der Wert eines benannten Objekt-Parameters (in
// Stack.Locals) passen. Erkennung wie beim Eintritts-Beobachter (Stack.Node == Funktion, erster Opcode ihres Scripts,
// 0x64 bei Event-Stubs mit Parametern - auch bei RPC-Ankunft ueber ProcessEvent); Stack.Code springt auf das
// abschliessende EX_Return, der Stub kopiert nichts in den Ubergraph und ruft ihn nicht auf.
constexpr int MaxDeny = 256;
constexpr size_t DenySlots = 1024;  // Zweierpotenz, > 2 * MaxDeny

struct DenyEntry {
    uintptr_t Func, Context, Value;   // Value 0 = Parameter muss null sein
    uint64_t FuncName;
    uintptr_t FuncOwner, ScriptData;
    int32_t SkipTo;                   // Offset des abschliessenden EX_Return
    int32_t ParamOffset;              // -1 = jeder Aufruf mit diesem Kontext
    uintptr_t CtxClass, ValueClass;
    int32_t CtxIndex, ValueIndex;     // InternalIndex (GUObjectArray) beim Aufbau
    char Tag[32];
    char Key[96];                     // Zeile ohne Tag (erstes Log je Eintrag)
};

struct DenyTable {
    int32_t Count = 0;
    DenyEntry Entries[MaxDeny] = {};
    int16_t Slots[DenySlots];
    mutable std::atomic<uint32_t> Hits[MaxDeny];
    DenyTable() {
        for (size_t I = 0; I < DenySlots; ++I) Slots[I] = -1;
        for (int I = 0; I < MaxDeny; ++I) Hits[I].store(0, std::memory_order_relaxed);
    }
};
std::atomic<const DenyTable*> ActiveDeny{nullptr};
std::atomic<bool> DenyOn{false};          // Worker: Tabelle nicht leer, Beobachter installiert, netmode != client
std::atomic<int> DenyFaults{0};
std::atomic<uint64_t> DenyBlocked{0};

size_t DenySlot(uintptr_t Func, uintptr_t Context) {
    return static_cast<size_t>(((static_cast<uint64_t>(Func) * 31u ^ static_cast<uint64_t>(Context)) * 0x9E3779B97F4A7C15ull) >> 54);
}

// true = Aufruf verworfen (Stack.Code steht auf EX_Return, Original nicht aufrufen)
bool DenyCheckInner(const DenyTable* Table, uintptr_t Stack) {
    const uintptr_t Node = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameNode);
    const uintptr_t Context = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameObject);
    for (size_t I = DenySlot(Node, Context), Probe = 0; Probe < DenySlots; ++Probe, I = (I + 1) & (DenySlots - 1)) {
        const int16_t Index = Table->Slots[I];
        if (Index < 0) return false;
        const DenyEntry& Entry = Table->Entries[Index];
        if (Entry.Func != Node || Entry.Context != Context) continue;
        const uintptr_t Code = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameCode);
        if (Code - 1 != Entry.ScriptData) return false;  // nicht der erste Opcode der Funktion
        // CORE-25 (b): Pruefung im Worker nur jede Sekunde - in der Zwischenzeit neu vergebene Adressen (andere Funktion,
        // anderes Objekt am selben Platz) nie sperren: FName der Funktion und InternalIndex des Kontexts wie beim Aufbau
        if (Read<uint64_t>(Node + OffObjectName) != Entry.FuncName ||
            Read<int32_t>(Context + Cfg.OffObjectIndex) != Entry.CtxIndex)
            continue;
        if (Entry.ParamOffset >= 0) {
            const uintptr_t Locals = *reinterpret_cast<const uintptr_t*>(Stack + Cfg.OffFrameLocals);
            if (!LooksLikePointer(Locals)) continue;
            uintptr_t Value = 0;
            if (!TryRead(Locals + static_cast<uint32_t>(Entry.ParamOffset), Value) || Value != Entry.Value) continue;
            if (Value && Read<int32_t>(Value + Cfg.OffObjectIndex) != Entry.ValueIndex) continue;  // Wert neu vergeben
        }
        *reinterpret_cast<uintptr_t*>(Stack + Cfg.OffFrameCode) = Entry.ScriptData + static_cast<uint32_t>(Entry.SkipTo);
        Table->Hits[Index].fetch_add(1, std::memory_order_relaxed);
        DenyBlocked.fetch_add(1, std::memory_order_relaxed);
        EventRec Rec;
        memset(&Rec, 0, sizeof(Rec));
        memcpy(Rec.Tag, Entry.Tag, sizeof(Rec.Tag));
        Rec.Func = Entry.Func;
        Rec.Context = Context;
        const uint32_t OffPrevious = Cfg.OffFramePrevious ? Cfg.OffFramePrevious : 0x78;
        const uintptr_t Previous = Read<uintptr_t>(Stack + OffPrevious);
        Rec.Caller = IsOnThisStack(Previous) ? Read<uintptr_t>(Previous + Cfg.OffFrameObject) : 0;
        Rec.TimeMs = GetTickCount64();
        Rec.Suppressed = 1;
        Rec.Flags = EvEntry;
        if (Entry.ParamOffset >= 0) {
            Rec.NumArgs = 1;
            Rec.Args[0].Type = 'o';
            Rec.Args[0].Raw = Entry.Value;
        }
        if (RingPush(Rec)) ObsEvents.fetch_add(1, std::memory_order_relaxed);
        else ObsDropped.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

bool DenyCheck(const DenyTable* Table, uintptr_t Stack) {
    __try {
        return DenyCheckInner(Table, Stack);
    } __except (FaultFilter(GetExceptionCode())) {
        if (DenyFaults.fetch_add(1) + 1 >= 3) DenyOn.store(false);
        return false;
    }
}

template <uint8_t Op> void ObserveHook(void* Context, void* Stack, void* Result) {
    if (ObserverOn.load(std::memory_order_relaxed) && Stack) {
        if (DenyOn.load(std::memory_order_relaxed)) {
            const DenyTable* Deny = ActiveDeny.load(std::memory_order_acquire);
            if (Deny && Deny->Count && DenyCheck(Deny, reinterpret_cast<uintptr_t>(Stack))) return;
        }
        const WatchTable* Table = ActiveWatch.load(std::memory_order_acquire);
        if (Table && Table->Count) {
            if (Table->EntryCount && ObserveEntry(Table, reinterpret_cast<uintptr_t>(Stack))) return;
            // 0x64 (LetValueOnPersistentFrame) ist kein Aufruf, nur fuer den Eintritt umgelenkt
            if (Op != 0x64 && Table->CallCount &&
                ObserveCall(Op, Table, reinterpret_cast<uintptr_t>(Context), reinterpret_cast<uintptr_t>(Stack), Result))
                return;
        }
    }
    ObsOriginal[Op](Context, Stack, Result);
}

// ---------------------------------------------------------------------------------------------------------
// Bytecode-Patches fuer Blueprint-Funktionen, nur beim Mitspieler (Lua schreibt netcore_patch.txt).
// Zeile alt:  <name> <UFunction hex> <offset dez> <erwartet hex> <neu hex> <1=an|0=aus>   (= Typ bytes)
// Zeile neu:  <name> <typ> <UFunction hex> <offset dez> <erwartet hex> <neu hex> <1|0> [force]
//   bytes      beliebige Bytes
//   ret_early  "040B" (Return Nothing) bei Offset 0, nur ohne Rueckgabewert (ReturnValueOffset 0xFFFF) oder mit force
//   ptr_swap   8-Byte-Funktionszeiger eines Aufrufs, erwartet/neu als 16 Hex-Ziffern in Speicherreihenfolge
//              (little-endian); beide Funktionen muessen leben und dieselbe Signatur haben
// Geschrieben wird nur, wenn an der Stelle genau "erwartet" (bzw. beim Ausschalten "neu") steht -
// sonst passt die Spielversion nicht und es bleibt alles unveraendert. Script liegt in UStruct
// als TArray<uint8> bei off_script (UE 5.3: 0x60). Der Worker parst nur, geschrieben wird im
// Spielthread (oben in Hook<K>), dort laeuft garantiert kein anderer Blueprint-Code parallel.
struct Bytes {
    uint8_t Data[64];
    size_t Size = 0;
};

bool ParseHex(const char* Text, Bytes& Out) {
    Out.Size = 0;
    if (strlen(Text) % 2) return false;
    for (size_t I = 0; Text[I] && Text[I + 1]; I += 2) {
        unsigned Byte;
        if (Out.Size >= sizeof(Out.Data) || sscanf(Text + I, "%2x", &Byte) != 1) return false;
        Out.Data[Out.Size++] = static_cast<uint8_t>(Byte);
    }
    return Out.Size > 0;
}

enum PatchType { PatchBytes = 0, PatchRetEarly = 1, PatchPtrSwap = 2 };
const char* const PatchTypeNames[] = {"bytes", "ret_early", "ptr_swap"};

struct PatchRequest {
    char Name[64] = {};
    PatchType Type = PatchBytes;
    uintptr_t Func = 0;
    uint32_t Offset = 0;
    Bytes Expect, New;
    bool Want = false, Force = false;
};

// Script-Zeiger beim ersten Anwenden, spaeter muss er gleich sein (sonst Weltwechsel/GC)
struct PatchRecord {
    std::string Name;
    uintptr_t Func;
    uint32_t Offset;
    uintptr_t Script;
    uintptr_t SavedEventGraph;  // ret_early: genullter UFunction::EventGraphFunction (0 = nichts genullt)
};

SRWLOCK PatchLock = SRWLOCK_INIT;
std::vector<PatchRequest> PendingPatches;   // unter PatchLock
std::atomic<bool> PatchPending{false};
std::vector<PatchRecord> PatchRecords;      // nur Spielthread
std::string LastPatchFile;                  // nur Worker

// Patch-Zustaende fuer netcore_status.txt ("patch_<Name>=1|0|-1"): 1 = angewendet, 0 = verweigert/Abweichung,
// -1 = angefordert, noch nicht verarbeitet. Nur Anforderungen mit Want=1 setzen den Wert; "aus" laesst ihn stehen,
// damit Lua den Nachlauf eines Fensters nicht als verweigert liest. On = zuletzt erfolgreich eingeschaltet.
struct PatchStateEntry {
    std::string Name;
    int State;
    bool On;
};
SRWLOCK PatchStateLock = SRWLOCK_INIT;
std::vector<PatchStateEntry> PatchStates;   // unter PatchStateLock, Reihenfolge stabil (Status-Vergleich)

PatchStateEntry& PatchStateFor(const char* Name) {  // nur unter PatchStateLock
    for (PatchStateEntry& E : PatchStates)
        if (E.Name == Name) return E;
    PatchStates.push_back({Name, -1, false});
    return PatchStates.back();
}

void SetPatchState(const PatchRequest& R, bool Applied) {
    int Old = 0, New = 0;
    AcquireSRWLockExclusive(&PatchStateLock);
    if (R.Want) {
        PatchStateEntry& E = PatchStateFor(R.Name);
        Old = E.State;
        E.State = Applied ? 1 : 0;
        E.On = Applied;
        New = E.State;
    } else if (Applied) {
        for (PatchStateEntry& E : PatchStates)  // "aus": keinen Eintrag anlegen, Wert stehen lassen
            if (E.Name == R.Name) E.On = false;
    }
    ReleaseSRWLockExclusive(&PatchStateLock);
    if (R.Want && Old != New) LogF("Patch %s: Status %d an Lua gemeldet", R.Name, New);
}

PatchRecord* FindPatchRecord(const PatchRequest& R) {
    for (PatchRecord& Record : PatchRecords)
        if (Record.Func == R.Func && Record.Offset == R.Offset && Record.Name == R.Name) return &Record;
    return nullptr;
}

void DropPatchRecord(const PatchRequest& R) {
    for (size_t I = 0; I < PatchRecords.size(); ++I) {
        PatchRecord& Record = PatchRecords[I];
        if (Record.Func == R.Func && Record.Offset == R.Offset && Record.Name == R.Name) {
            PatchRecords.erase(PatchRecords.begin() + static_cast<std::ptrdiff_t>(I));
            return;
        }
    }
}

// Signatur und Lebenszeichen beider Funktionen fuer ptr_swap
bool CheckPtrSwap(const PatchRequest& R, uintptr_t Script, char* Why, size_t WhySize) {
    uint8_t Opcode = 0;
    if (!R.Offset || !TryRead(Script + R.Offset - 1, Opcode) || (Opcode != 0x1C && Opcode != 0x46 && Opcode != 0x68)) {
        snprintf(Why, WhySize, "kein Funktionsaufruf vor dem Operanden (Opcode 0x%02x)", Opcode);
        return false;
    }
    uint64_t Old = 0, New = 0;
    memcpy(&Old, R.Expect.Data, 8);
    memcpy(&New, R.New.Data, 8);
    const uintptr_t Functions[2] = {static_cast<uintptr_t>(Old), static_cast<uintptr_t>(New)};
    for (uintptr_t F : Functions) {
        if (!IsLiveObject(F) || !IsA(F, Cfg.ClsFunction)) {
            snprintf(Why, WhySize, "Funktion %llx lebt nicht", static_cast<unsigned long long>(F));
            return false;
        }
    }
    if (Read<uint16_t>(Functions[0] + Cfg.OffParmsSize) != Read<uint16_t>(Functions[1] + Cfg.OffParmsSize) ||
        Read<uint8_t>(Functions[0] + Cfg.OffNumParms) != Read<uint8_t>(Functions[1] + Cfg.OffNumParms) ||
        Read<uint16_t>(Functions[0] + Cfg.OffReturnValue) != Read<uint16_t>(Functions[1] + Cfg.OffReturnValue)) {
        snprintf(Why, WhySize, "Signatur verschieden (ParmsSize/NumParms/ReturnValueOffset)");
        return false;
    }
    // Kontext (this) bleibt der des alten Aufrufs: nicht statische Funktionen muessen zur Klasse der alten
    // Funktion oder einer ihrer Oberklassen gehoeren, sonst greift der Rumpf mit fremden Offsets auf das Objekt zu
    const bool StaticOld = (Read<uint32_t>(Functions[0] + Cfg.OffFunctionFlags) & 0x2000) != 0;  // FUNC_Static
    const bool StaticNew = (Read<uint32_t>(Functions[1] + Cfg.OffFunctionFlags) & 0x2000) != 0;
    if (StaticOld != StaticNew || (Opcode == 0x68 && !StaticNew)) {
        snprintf(Why, WhySize, "statisch/nicht statisch passt nicht (alt %d, neu %d, Opcode 0x%02x)", StaticOld, StaticNew,
                 Opcode);
        return false;
    }
    if (!StaticNew) {
        const uintptr_t NewOwner = Read<uintptr_t>(Functions[1] + Cfg.OffOuter);
        bool Related = false;
        uintptr_t Class = Read<uintptr_t>(Functions[0] + Cfg.OffOuter);
        for (int Depth = 0; Depth < 64 && LooksLikePointer(Class) && !Related; ++Depth) {
            Related = Class == NewOwner;
            Class = Read<uintptr_t>(Class + Cfg.OffSuper);
        }
        if (!Related) {
            snprintf(Why, WhySize, "neue Funktion gehoert nicht zur Klasse der alten oder einer Oberklasse");
            return false;
        }
    }
    // Parameter paarweise: FFieldClass (Typ), ElementSize, Offset_Internal, Parm/Out/Return/Reference-Flags
    const uint64_t ParmMask = 0x80 | 0x100 | 0x400 | 0x8000000;
    uintptr_t A = Read<uintptr_t>(Functions[0] + 0x50), B = Read<uintptr_t>(Functions[1] + 0x50);  // ChildProperties
    for (int Index = 0, Steps = 0; Steps < 128; ++Steps) {
        while (LooksLikePointer(A) && !(Read<uint64_t>(A + 0x38) & 0x80) && Steps++ < 128) A = Read<uintptr_t>(A + 0x18);
        while (LooksLikePointer(B) && !(Read<uint64_t>(B + 0x38) & 0x80) && Steps++ < 128) B = Read<uintptr_t>(B + 0x18);
        const bool HaveA = LooksLikePointer(A), HaveB = LooksLikePointer(B);
        if (!HaveA || !HaveB) {
            if (HaveA != HaveB) {
                snprintf(Why, WhySize, "Parameterliste verschieden lang (ab Parameter %d)", Index);
                return false;
            }
            break;
        }
        if (Read<uintptr_t>(A + OffFFieldClass) != Read<uintptr_t>(B + OffFFieldClass) ||
            Read<int32_t>(A + 0x34) != Read<int32_t>(B + 0x34) || Read<int32_t>(A + 0x44) != Read<int32_t>(B + 0x44) ||
            ((Read<uint64_t>(A + 0x38) ^ Read<uint64_t>(B + 0x38)) & ParmMask)) {
            snprintf(Why, WhySize, "Parameter %d verschieden (Typ/Groesse/Lage/Flags)", Index);
            return false;
        }
        A = Read<uintptr_t>(A + 0x18);
        B = Read<uintptr_t>(B + 0x18);
        ++Index;
    }
    return true;
}

// UE_BLUEPRINT_EVENTGRAPH_FASTCALLS (Func bei 0xD8 => EventGraphFunction 0x10 davor): ProcessEvent (Timer,
// Delegates, RPC, Lua) springt bei einfachen Event-Stubs ohne Parameter direkt in den Ubergraph und ueberspringt
// den Stub samt ret_early. Solange der Patch aktiv ist, den Zeiger nullen - der Stub ruft den Ubergraph sonst
// genauso auf. Nur im Spielthread (ProcessEvent liest den Zeiger dort).
void ToggleEventGraphFastCall(const PatchRequest& R, PatchRecord& Record, uintptr_t Data) {
    if (Cfg.OffFunc < 0xD8) return;  // Layout ohne Fast-Call-Felder
    const uintptr_t Slot = R.Func + Cfg.OffFunc - 0x10;
    uintptr_t Current = 0;
    if (!TryRead(Slot, Current)) return;
    if (!R.Want) {
        if (!Record.SavedEventGraph) return;
        if (!Current && IsLiveObject(Record.SavedEventGraph) &&
            SafeWrite(Slot, &Record.SavedEventGraph, sizeof(Record.SavedEventGraph)))
            LogF("Patch %s: Ubergraph-Direktaufruf wiederhergestellt", R.Name);
        Record.SavedEventGraph = 0;
        return;
    }
    if (!Current) return;  // kein Direktaufruf (Stub mit Parametern) oder schon genullt
    bool Plausible = IsLiveObject(Current) && IsA(Current, Cfg.ClsFunction) &&
                     Read<uintptr_t>(Current + Cfg.OffOuter) == Read<uintptr_t>(R.Func + Cfg.OffOuter);
    // Gegenprobe bei "46XX": der Stub rief EX_LocalFinalFunction <Ubergraph>, XX = unterstes Byte des Zeigers
    uintptr_t Called = 0;
    if (Plausible && R.Offset == 0 && R.Expect.Size >= 2 && R.Expect.Data[0] == 0x46 && SafeCopy(&Called, Data + 1, 8))
        Plausible = ((Called & ~uintptr_t(0xFF)) | R.Expect.Data[1]) == Current;
    if (!Plausible) {
        LogF("Patch %s: EventGraphFunction %llx unplausibel, Direktaufruf bleibt (ret_early greift nur bei "
             "Blueprint-Aufrufen)", R.Name, static_cast<unsigned long long>(Current));
        return;
    }
    const uintptr_t Null = 0;
    if (SafeWrite(Slot, &Null, sizeof(Null))) {
        Record.SavedEventGraph = Current;
        LogF("Patch %s: Ubergraph-Direktaufruf abgeschaltet (ProcessEvent laeuft jetzt durch den Stub)", R.Name);
    }
}

// true = Zielzustand erreicht (Want=1: aktiv, Want=0: aus), false = verweigert/Abweichung
bool ApplyPatchBytes(const PatchRequest& R) {
    const char* Name = R.Name;
    const char* TypeName = PatchTypeNames[R.Type];
    if (!IsLiveObject(R.Func)) {
        LogF("Patch %s: Funktion %llx lebt nicht (mehr), verworfen", Name, static_cast<unsigned long long>(R.Func));
        DropPatchRecord(R);
        return false;
    }
    // CORE-25 (a): lebendes Objekt, aber keine UFunction (Adresse neu vergeben) -> nie in fremdes "Script" schreiben.
    // Spielthread: nur IsA (Cfg.ClsFunction ist gesetzt, sonst gaebe es Hook<K> nicht), kein NameText.
    if (!Cfg.ClsFunction || !IsA(R.Func, Cfg.ClsFunction)) {
        LogF("Patch %s: %llx ist keine Funktion, verworfen", Name, static_cast<unsigned long long>(R.Func));
        DropPatchRecord(R);
        return false;
    }
    uintptr_t ScriptArray = R.Func + (Cfg.OffScript ? Cfg.OffScript : 0x60);
    uintptr_t Data = 0;
    int32_t Num = 0;
    if (!TryRead(ScriptArray, Data) || !TryRead(ScriptArray + 8, Num) || !LooksLikePointer(Data & ~uintptr_t(7)) ||
        Num < 0 || Num > (16 << 20) || static_cast<size_t>(Num) < R.Offset + R.Expect.Size) {
        LogF("Patch %s: Script nicht gefunden (Num=%d)", Name, Num);
        return false;
    }
    PatchRecord* Record = FindPatchRecord(R);
    if (Record && Record->Script != Data) {
        LogF("Patch %s: Script-Zeiger geaendert (Weltwechsel/GC), verworfen", Name);
        DropPatchRecord(R);
        return false;
    }
    if (R.Type == PatchRetEarly && R.Want) {
        uint16_t ReturnOffset = Read<uint16_t>(R.Func + Cfg.OffReturnValue);
        if (ReturnOffset != 0xFFFF && !R.Force) {
            LogF("Patch %s: ret_early verweigert, Funktion hat Rueckgabewert (Offset 0x%x), 'force' anhaengen",
                 Name, ReturnOffset);
            return false;
        }
        if (Read<uint32_t>(R.Func + Cfg.OffFunctionFlags) & 0x400000)
            LogF("Patch %s: Hinweis, Funktion hat Out-Parameter (liefern dann 0)", Name);
    }
    if (R.Type == PatchPtrSwap) {
        char Why[160];
        if (!CheckPtrSwap(R, Data, Why, sizeof(Why))) {
            LogF("Patch %s: ptr_swap verweigert, %s", Name, Why);
            return false;
        }
    }
    uint8_t Current[64];
    if (!SafeCopy(Current, Data + R.Offset, R.Expect.Size)) {
        LogF("Patch %s: Script nicht lesbar", Name);
        return false;
    }
    const Bytes& From = R.Want ? R.Expect : R.New;
    const Bytes& To = R.Want ? R.New : R.Expect;
    bool Matches = true;
    if (!memcmp(Current, To.Data, To.Size)) {
        LogF("Patch %s (%s): schon %s", Name, TypeName, R.Want ? "aktiv" : "aus");
    } else if (!memcmp(Current, From.Data, From.Size)) {
        DWORD Old = 0;
        uint8_t* At = reinterpret_cast<uint8_t*>(Data + R.Offset);
        BOOL Unprotected = VirtualProtect(At, To.Size, PAGE_READWRITE, &Old);
        bool Written = SafeWrite(Data + R.Offset, To.Data, To.Size);
        if (Unprotected) VirtualProtect(At, To.Size, Old, &Old);
        if (Written)
            LogF("Patch %s (%s): %s (Script %d Bytes)", Name, TypeName, R.Want ? "aktiviert" : "zurueckgenommen", Num);
        else
            LogF("Patch %s: Schreiben fehlgeschlagen", Name);
        Matches = Written;
    } else {
        LogF("Patch %s: Bytes passen nicht zur erwarteten Spielversion, nichts geaendert", Name);
        Matches = false;
    }
    if (Matches && !Record) {
        PatchRecords.push_back({R.Name, R.Func, R.Offset, Data, 0});
        Record = &PatchRecords.back();
    }
    if (Matches && R.Type == PatchRetEarly) ToggleEventGraphFastCall(R, *Record, Data);
    return Matches;
}

void ApplyPatch(const PatchRequest& R) { SetPatchState(R, ApplyPatchBytes(R)); }

// Spielthread: offene Patches uebernehmen (blockiert nie, der Worker haelt das Lock nur kurz)
__declspec(noinline) void ApplyPendingPatches() {
    if (!TryAcquireSRWLockExclusive(&PatchLock)) return;
    std::vector<PatchRequest> Work;
    Work.swap(PendingPatches);
    PatchPending.store(false, std::memory_order_release);
    ReleaseSRWLockExclusive(&PatchLock);
    for (const PatchRequest& R : Work) ApplyPatch(R);
}

template <Kind K> void Hook(void* Context, void* Stack, void* Result) {
    if (PatchPending.load(std::memory_order_acquire)) ApplyPendingPatches();
    bool Redirect = Enabled.load(std::memory_order_relaxed) && Stack && Result;
    // PlayerIndex vor dem Original lesen, das Original laeuft ueber die Argumente hinweg
    if (Redirect && Cfg.IndexFilter && !WantsPlayerZero(reinterpret_cast<uintptr_t>(Stack))) {
        SkippedRedirects.fetch_add(1, std::memory_order_relaxed);
        Redirect = false;
    }
    Original[K](Context, Stack, Result);
    if (!Redirect) return;

    uintptr_t PC = 0;
    // INV-15 (drop_outer=1): in JigMP_OnRequestDropItem (Frame 0, Vergleich per FName) zaehlt der anfragende Spieler
    // (aeusserster Rahmen), nicht der Besitzer der Kiste/des Autos; ohne Spieler aussen der bisherige Weg
    const uint64_t DropName = DropOuterOpt.load(std::memory_order_relaxed) ? DropFName.load(std::memory_order_relaxed) : 0;
    if (DropName &&
        Read<uint64_t>(Read<uintptr_t>(reinterpret_cast<uintptr_t>(Stack) + Cfg.OffFrameNode) + OffObjectName) == DropName) {
        PC = ResolveOutermost(reinterpret_cast<uintptr_t>(Stack));
        if (PC) DropRedirects.fetch_add(1, std::memory_order_relaxed);
    }
    if (!PC) PC = ResolveFromFrames(reinterpret_cast<uintptr_t>(Stack));
    bool Nearest = false;
    if (!PC) {  // N6: KI/Spawner ohne Spielerbezug -> naechster Gast (nur Host mit Gaesten, Whitelist)
        PC = NearestGuestPC(reinterpret_cast<uintptr_t>(Stack));
        Nearest = PC != 0;
    }
    if (!PC) return;

    uintptr_t Value = 0;
    switch (K) {
    case GetPC: Value = PC; break;
    case GetPawn: Value = Read<uintptr_t>(PC + Cfg.OffControllerPawn); break;
    case GetCharacter: {
        uintptr_t Pawn = Read<uintptr_t>(PC + Cfg.OffControllerPawn);
        Value = IsA(Pawn, Cfg.ClsCharacter) ? Pawn : 0;
        break;
    }
    case GetCamera: Value = Read<uintptr_t>(PC + Cfg.OffCameraManager); break;
    }
    if (!Value) return;

    uintptr_t* Out = static_cast<uintptr_t*>(Result);
    if (*Out != Value) {
        *Out = Value;
        (Nearest ? NearestRedirects : Redirects).fetch_add(1, std::memory_order_relaxed);
    }
}

NativeFunc HookFor(int Index) {
    switch (Index) {
    case GetPC: return &Hook<GetPC>;
    case GetPawn: return &Hook<GetPawn>;
    case GetCharacter: return &Hook<GetCharacter>;
    default: return &Hook<GetCamera>;
    }
}

bool ParseConfig() {
    FILE* File = _wfopen((ModDir + L"netcore.cfg").c_str(), L"r");
    if (!File) return false;
    char Line[256];
    int Values = 0;
    while (fgets(Line, sizeof(Line), File)) {
        char Key[64];
        unsigned long long Value;
        if (sscanf(Line, "%63[^=]=%llx", Key, &Value) != 2) continue;
        ++Values;
        struct { const char* Name; uintptr_t* Ptr; } Pointers[] = {
            {"func_gpc", &Cfg.Func[GetPC]}, {"func_gpp", &Cfg.Func[GetPawn]},
            {"func_gpchar", &Cfg.Func[GetCharacter]}, {"func_gpcm", &Cfg.Func[GetCamera]},
            {"cls_pawn", &Cfg.ClsPawn}, {"cls_character", &Cfg.ClsCharacter},
            {"cls_pc", &Cfg.ClsPlayerController}, {"cls_actorcomp", &Cfg.ClsActorComponent},
            {"cls_actor", &Cfg.ClsActor}, {"cls_anim", &Cfg.ClsAnimInstance},
            {"cls_function", &Cfg.ClsFunction}, {"guobjectarray", &Cfg.ObjectArray},
        };
        struct { const char* Name; uint32_t* Ptr; } Offsets[] = {
            {"off_func", &Cfg.OffFunc}, {"off_class", &Cfg.OffClass}, {"off_outer", &Cfg.OffOuter},
            {"off_super", &Cfg.OffSuper}, {"off_frame_object", &Cfg.OffFrameObject},
            {"off_actor_owner", &Cfg.OffActorOwner}, {"off_pawn_controller", &Cfg.OffPawnController},
            {"off_controller_pawn", &Cfg.OffControllerPawn}, {"off_camera_manager", &Cfg.OffCameraManager},
            {"off_frame_node", &Cfg.OffFrameNode}, {"off_frame_previous", &Cfg.OffFramePrevious},
            {"off_script", &Cfg.OffScript}, {"off_frame_code", &Cfg.OffFrameCode},
            {"index_filter", &Cfg.IndexFilter},
        };
        for (auto& P : Pointers) if (!strcmp(Key, P.Name)) *P.Ptr = static_cast<uintptr_t>(Value);
        for (auto& O : Offsets) if (!strcmp(Key, O.Name)) *O.Ptr = static_cast<uint32_t>(Value);
    }
    fclose(File);
    return Values > 0;
}

bool ConfigComplete() {
    for (uintptr_t F : Cfg.Func) if (!F) return false;
    return Cfg.ClsPawn && Cfg.ClsCharacter && Cfg.ClsPlayerController && Cfg.ClsActorComponent &&
           Cfg.ClsActor && Cfg.ClsAnimInstance && Cfg.ClsFunction && Cfg.OffActorOwner && Cfg.OffPawnController &&
           Cfg.OffControllerPawn && Cfg.OffCameraManager;
}

void InstallHooks() {
    for (int I = 0; I < 4; ++I) {
        uintptr_t SlotAddress = Cfg.Func[I] + Cfg.OffFunc;
        uintptr_t Current = 0;
        // Der Thunk muss im Spiel-Image liegen, sonst stimmt Adresse/Offset nicht (oder jemand
        // anderes hat die Funktion schon umgebogen) - dann lieber gar nichts anfassen.
        if (!TryRead(SlotAddress, Current) || Current < ImageBase || Current >= ImageEnd) {
            LogF("Funktion %d: Thunk %llx nicht im Spiel-Image, uebersprungen", I, static_cast<unsigned long long>(Current));
            continue;
        }
        Original[I] = reinterpret_cast<NativeFunc>(Current);
        InterlockedExchangePointer(reinterpret_cast<void**>(SlotAddress), reinterpret_cast<void*>(HookFor(I)));
        LogF("Funktion %d gehookt (Original %llx)", I, static_cast<unsigned long long>(Current));
    }
}

// Worker: eine Zeile von netcore_patch.txt pruefen und zerlegen
bool ParsePatchLine(const char* Line, PatchRequest& Out) {
    char Tokens[8][160] = {};
    int Count = sscanf(Line, "%159s %159s %159s %159s %159s %159s %159s %159s", Tokens[0], Tokens[1], Tokens[2],
                       Tokens[3], Tokens[4], Tokens[5], Tokens[6], Tokens[7]);
    if (Count <= 0) return false;
    int Type = -1;
    for (int T = 0; T < 3; ++T) if (!strcmp(Tokens[1], PatchTypeNames[T])) Type = T;
    const int First = Type < 0 ? 1 : 2;  // Position der UFunction
    snprintf(Out.Name, sizeof(Out.Name), "%s", Tokens[0]);
    Out.Type = Type < 0 ? PatchBytes : static_cast<PatchType>(Type);
    char* End = nullptr;
    bool Valid = Count >= First + 5;
    if (Valid) {
        Out.Func = static_cast<uintptr_t>(strtoull(Tokens[First], &End, 16));
        Valid = *End == 0 && LooksLikePointer(Out.Func);
    }
    if (Valid) {
        Out.Offset = static_cast<uint32_t>(strtoul(Tokens[First + 1], &End, 10));
        Valid = *End == 0;
    }
    Valid = Valid && ParseHex(Tokens[First + 2], Out.Expect) && ParseHex(Tokens[First + 3], Out.New) &&
            Out.Expect.Size == Out.New.Size && (!strcmp(Tokens[First + 4], "1") || !strcmp(Tokens[First + 4], "0"));
    if (!Valid) {
        LogF("Patch %s: ungueltige Zeile", Out.Name);
        return false;
    }
    Out.Want = Tokens[First + 4][0] == '1';
    Out.Force = Count > First + 5 && !strcmp(Tokens[First + 5], "force");
    if (Out.Type == PatchRetEarly &&
        (Out.Offset != 0 || Out.New.Size != 2 || Out.New.Data[0] != 0x04 || Out.New.Data[1] != 0x0B)) {
        LogF("Patch %s: ret_early braucht neu=040B bei Offset 0", Out.Name);
        return false;
    }
    if (Out.Type == PatchPtrSwap && Out.New.Size != 8) {
        LogF("Patch %s: ptr_swap braucht 16 Hex-Ziffern", Out.Name);
        return false;
    }
    return true;
}

// Worker: Datei nur zerlegen, die Liste ersetzt die noch offenen Anforderungen (Lua schreibt immer alles)
void ProcessPatchFile() {
    FILE* File = _wfopen((ModDir + L"netcore_patch.txt").c_str(), L"r");
    if (!File) return;
    std::string Content;
    char Buffer[512];
    while (fgets(Buffer, sizeof(Buffer), File)) Content += Buffer;
    fclose(File);
    if (Content == LastPatchFile) return;
    LastPatchFile = Content;
    std::vector<PatchRequest> Parsed;
    size_t Start = 0;
    while (Start < Content.size()) {
        size_t End = Content.find('\n', Start);
        if (End == std::string::npos) End = Content.size();
        PatchRequest Request;
        if (ParsePatchLine(Content.substr(Start, End - Start).c_str(), Request)) Parsed.push_back(Request);
        Start = End + 1;
    }
    // Neu eingeschaltete Patches als "angefordert" (-1) melden, bis der Spielthread sie verarbeitet hat: ein alter
    // Wert 1 aus dem letzten Fenster wuerde sonst eine noch offene (evtl. verweigerte) Anwendung bestaetigen
    AcquireSRWLockExclusive(&PatchStateLock);
    for (const PatchRequest& R : Parsed) {
        if (!R.Want) continue;
        PatchStateEntry& E = PatchStateFor(R.Name);
        if (!(E.State == 1 && E.On)) E.State = -1;
    }
    ReleaseSRWLockExclusive(&PatchStateLock);
    AcquireSRWLockExclusive(&PatchLock);
    PendingPatches.swap(Parsed);
    PatchPending.store(true, std::memory_order_release);
    ReleaseSRWLockExclusive(&PatchLock);
}

bool ReadEnabledFlag() {
    FILE* File = _wfopen((ModDir + L"netcore_enabled.txt").c_str(), L"r");
    if (!File) return false;
    int C = fgetc(File);
    fclose(File);
    return C == '1';
}

std::string ReadText(const std::wstring& Path) {
    FILE* File = _wfopen(Path.c_str(), L"rb");
    if (!File) return "";
    std::string Text;
    char Buffer[4096];
    size_t N;
    while ((N = fread(Buffer, 1, sizeof(Buffer), File)) > 0) Text.append(Buffer, N);
    fclose(File);
    return Text;
}

// Erst in eine .tmp-Datei, dann umbenennen: Lua liest nie eine halbe Datei.
// Lua (fopen ohne FILE_SHARE_DELETE) oder der Virenscanner halten die Datei kurz offen, darum Wiederholungen.
// CORE-25 (c): MOVEFILE_WRITE_THROUGH (Platte sofort leeren) nur fuer dauerhafte Dateien (Durable: KDump, Steam-ID,
// Ergebnis-Dateien); Austauschdateien (Ereignisse bis 10x/s, Status, watchinfo, Liste/Ping) ohne.
bool WriteText(const std::wstring& Path, const std::string& Text, bool Durable = false) {
    std::wstring Tmp = Path + L".tmp";
    FILE* File = _wfopen(Tmp.c_str(), L"wb");
    if (!File) {
        LogF("Datei %ls nicht schreibbar (errno %d)", Tmp.c_str(), errno);
        return false;
    }
    bool Written = fwrite(Text.data(), 1, Text.size(), File) == Text.size();
    if (fclose(File) != 0) Written = false;
    if (!Written) {
        LogF("Datei %ls unvollstaendig geschrieben", Tmp.c_str());
        DeleteFileW(Tmp.c_str());
        return false;
    }
    DWORD Error = 0;
    for (int Try = 0; Try < 20; ++Try) {
        if (MoveFileExW(Tmp.c_str(), Path.c_str(), MOVEFILE_REPLACE_EXISTING | (Durable ? MOVEFILE_WRITE_THROUGH : 0)))
            return true;
        Error = GetLastError();
        Sleep(50);
    }
    LogF("Datei %ls nicht ersetzt (Fehler %lu)", Path.c_str(), static_cast<unsigned long>(Error));
    DeleteFileW(Tmp.c_str());
    return false;
}

// ---------------------------------------------------------------------------------------------------------
// Worker-Seite von N4b/N6: Dateien von Lua lesen, Tabellen bauen und tauschen, Ereignisse schreiben.
// Alte Tabellen werden erst 30 s nach dem Tausch freigegeben (ein Wrapper kann sie noch kurz benutzen).
FILETIME ProcessStart{};  // Dateien aelter als der Spielstart stammen aus einer frueheren Sitzung
uint64_t SessionStamp = 0;

struct RetiredTable {
    const WatchTable* Watch;
    const ClassLists* Lists;
    uint64_t At;
    const DenyTable* Deny = nullptr;
    const AlliesTable* Allies = nullptr;
};
std::vector<RetiredTable> Retired;

void FreeRetired(bool All) {
    const uint64_t Now = GetTickCount64();
    for (size_t I = 0; I < Retired.size();) {
        if (All || Now - Retired[I].At > 30000) {
            delete Retired[I].Watch;
            delete Retired[I].Lists;
            delete Retired[I].Deny;
            delete Retired[I].Allies;
            Retired.erase(Retired.begin() + static_cast<std::ptrdiff_t>(I));
        } else {
            ++I;
        }
    }
}

bool FileIsCurrent(const std::wstring& Path) {
    WIN32_FILE_ATTRIBUTE_DATA Data;
    if (!GetFileAttributesExW(Path.c_str(), GetFileExInfoStandard, &Data)) return false;
    return CompareFileTime(&Data.ftLastWriteTime, &ProcessStart) >= 0;
}

// Steuerdatei von Lua lesen (nur Worker-Thread). Core.WriteAtomic loescht das Ziel kurz vor dem Umbenennen,
// Virenscanner halten Dateien kurz offen: fehlt die Datei bzw. ist sie nicht lesbar, bis zu 2 s den letzten
// Text behalten (sonst waeren Sperren/ff/pvp fuer einen Durchlauf aus). Erst danach gilt sie als geloescht
// (Native.Init loescht sie bewusst). RequireCurrent: Datei einer frueheren Sitzung gilt als leer.
struct ControlFileState {
    ULONGLONG MissingSince = 0;
    ULONGLONG LastLog = 0;
};

std::string ReadControlFile(const std::wstring& Path, bool RequireCurrent, const std::string& LastText, ControlFileState& State) {
    std::string Text;
    bool Ok = false;
    WIN32_FILE_ATTRIBUTE_DATA Data;
    if (GetFileAttributesExW(Path.c_str(), GetFileExInfoStandard, &Data)) {
        if (RequireCurrent && CompareFileTime(&Data.ftLastWriteTime, &ProcessStart) < 0) {
            Ok = true;
        } else if (FILE* File = _wfopen(Path.c_str(), L"rb")) {
            char Buffer[4096];
            size_t N;
            while ((N = fread(Buffer, 1, sizeof(Buffer), File)) > 0) Text.append(Buffer, N);
            fclose(File);
            Ok = true;
        }
    }
    if (Ok || LastText.empty()) {
        State.MissingSince = 0;
        return Text;
    }
    const ULONGLONG Now = GetTickCount64();
    if (!State.MissingSince) State.MissingSince = Now;
    if (Now - State.MissingSince < 2000) {
        if (!State.LastLog || Now - State.LastLog >= 60000) {
            State.LastLog = Now;
            LogF("%ls fehlt kurz (Ersetzen durch Lua) - Liste unveraendert", Path.c_str());
        }
        return LastText;
    }
    State.MissingSince = 0;
    LogF("%ls fehlt seit 2 s - als geloescht behandelt", Path.c_str());
    return Text;
}

std::vector<std::string> SplitLines(const std::string& Text) {
    std::vector<std::string> Lines;
    for (size_t Start = 0; Start < Text.size();) {
        size_t End = Text.find('\n', Start);
        if (End == std::string::npos) End = Text.size();
        std::string Line = Text.substr(Start, End - Start);
        while (!Line.empty() && (Line.back() == '\r' || Line.back() == ' ' || Line.back() == '\t')) Line.pop_back();
        size_t First = Line.find_first_not_of(" \t");
        Lines.push_back(First == std::string::npos ? std::string() : Line.substr(First));
        Start = End + 1;
    }
    return Lines;
}

// netcore_opts.txt: ai_nearest=diag|0|1, observer=0|1, off_root_component=<hex>, off_rel_location=<hex>, local_pc=<hex>,
// pvp=0|1, netmode=host|client|solo, Runde 9: drop_outer=0|1 (fehlt = 0)
std::string LastOptsText;

void ProcessOptsFile() {
    static ControlFileState State;
    std::string Text = ReadControlFile(ModDir + L"netcore_opts.txt", false, LastOptsText, State);
    if (Text == LastOptsText) return;
    LastOptsText = Text;
    int Nearest = 2;
    bool Observer = true;
    uint32_t Root = 0, Rel = 0;
    unsigned long long Local = 0;
    bool Pvp = false, DropOuter = false;
    int NetMode = NetUnknown;
    for (const std::string& Line : SplitLines(Text)) {
        size_t Eq = Line.find('=');
        if (Line.empty() || Line[0] == '#' || Eq == std::string::npos) continue;
        std::string Key = Line.substr(0, Eq), Value = Line.substr(Eq + 1);
        while (!Key.empty() && Key.back() == ' ') Key.pop_back();
        while (!Value.empty() && Value[0] == ' ') Value.erase(0, 1);
        if (Key == "ai_nearest") Nearest = Value == "diag" ? 2 : (Value == "1" || Value == "on" || Value == "true") ? 1 : 0;
        else if (Key == "observer") Observer = Value != "0" && Value != "off" && Value != "false";
        else if (Key == "off_root_component") Root = static_cast<uint32_t>(strtoul(Value.c_str(), nullptr, 16));
        else if (Key == "off_rel_location") Rel = static_cast<uint32_t>(strtoul(Value.c_str(), nullptr, 16));
        else if (Key == "local_pc") Local = strtoull(Value.c_str(), nullptr, 16);
        else if (Key == "pvp") Pvp = Value == "1" || Value == "on" || Value == "true";
        else if (Key == "netmode") NetMode = Value == "host" ? NetHost : Value == "client" ? NetClient : Value == "solo" ? NetSolo : NetUnknown;
        else if (Key == "drop_outer") DropOuter = Value == "1" || Value == "on" || Value == "true";
    }
    PvpMode.store(Pvp);
    NetModeOpt.store(NetMode);
    DropOuterOpt.store(DropOuter);
    AiNearest.store(Nearest);
    ObserverWanted.store(Observer);
    OffRootComponent.store(Root < 0x2000 ? Root : 0);
    OffRelLocation.store(Rel < 0x2000 ? Rel : 0);
    // Nur Vergleichswert (R/L-Markierung, local=1); muss ein lebender PlayerController sein
    const uintptr_t LocalValue = static_cast<uintptr_t>(Local);
    LocalPC.store(IsLiveObject(LocalValue) && IsA(LocalValue, Cfg.ClsPlayerController) ? LocalValue : 0);
    static const char* const NetModeNames[] = {"?", "host", "client", "solo"};
    LogF("Optionen: ai_nearest=%s observer=%d root=0x%X rel=0x%X local_pc=%s pvp=%d netmode=%s drop_outer=%d",
         Nearest == 2 ? "diag" : Nearest ? "1" : "0", Observer ? 1 : 0, Root, Rel, LocalPC.load() ? "ok" : "-", Pvp ? 1 : 0,
         NetModeNames[NetMode & 3], DropOuter ? 1 : 0);
}

// netcore_players.txt (Host, Lua jede Sekunde und sofort beim Trennen):
// "<PC hex> <Pawn hex> <Character hex> <CameraManager hex> <X> <Y> <Z>", nur echte Gaeste, nie der Geist
std::string LastPlayersText;

void ProcessPlayersFile() {
    const std::wstring Path = ModDir + L"netcore_players.txt";
    std::string Text = FileIsCurrent(Path) ? ReadText(Path) : std::string();
    if (Text == LastPlayersText) return;
    LastPlayersText = Text;
    GuestSnapshot Snapshot{};
    for (const std::string& Line : SplitLines(Text)) {
        if (Line.empty() || Line[0] == '#' || Snapshot.Count >= MaxGuests) continue;
        unsigned long long PC = 0, Pawn = 0, Character = 0, Camera = 0;
        double X = 0, Y = 0, Z = 0;
        if (sscanf(Line.c_str(), "%llx %llx %llx %llx %lf %lf %lf", &PC, &Pawn, &Character, &Camera, &X, &Y, &Z) != 7 ||
            !LooksLikePointer(static_cast<uintptr_t>(PC)))
            continue;
        Snapshot.Guests[Snapshot.Count++] = {static_cast<uintptr_t>(PC), static_cast<uintptr_t>(Pawn),
                                             static_cast<uintptr_t>(Character), static_cast<uintptr_t>(Camera), X, Y, Z};
    }
    if (Snapshot.Count != SharedGuests.Count) LogF("N6: %d Gaeste", Snapshot.Count);
    PublishGuests(Snapshot);
}

// Typ eines Parameters aus dem Namen seiner FFieldClass
uint8_t ParamType(uintptr_t Field) {
    uintptr_t FieldClass = 0;
    uint64_t Name = 0;
    std::string Text;
    if (!TryRead(Field + OffFFieldClass, FieldClass) || !LooksLikePointer(FieldClass) || !TryRead(FieldClass, Name) ||
        !NameText(Name, Text))
        return '?';
    if (Text == "ObjectProperty" || Text == "ClassProperty" || Text == "InterfaceProperty") return 'o';
    if (Text == "IntProperty" || Text == "Int8Property" || Text == "Int16Property" || Text == "Int64Property" ||
        Text == "UInt16Property" || Text == "UInt32Property" || Text == "UInt64Property" || Text == "ByteProperty" ||
        Text == "EnumProperty")
        return 'i';
    if (Text == "FloatProperty") return 'f';
    if (Text == "DoubleProperty") return 'd';
    if (Text == "BoolProperty") return 'b';
    if (Text == "StrProperty") return 's';
    if (Text == "NameProperty") return 'n';
    if (Text == "StructProperty") return 'S';  // genauer in StructParamType
    return '?';
}

// StructProperty: FVector/FRotator (3 double) bzw. FLinearColor (4 float). FStructProperty::Struct liegt hinter
// FProperty (UE 5.3: 0x70; 0x78 als Rueckfall), geprueft ueber Objektliste, Name und ElementSize.
uint8_t StructParamType(uintptr_t Field, int32_t Size) {
    const uint32_t Offsets[] = {0x70, 0x78};
    for (uint32_t Offset : Offsets) {
        const uintptr_t Struct = Read<uintptr_t>(Field + Offset);
        std::string Name;
        if (!IsLiveObject(Struct) || !ObjectName(Struct, Name)) continue;
        if (Name == "Vector" && Size == 24) return 'v';
        if (Name == "Rotator" && Size == 24) return 'r';
        if (Name == "LinearColor" && Size == 16) return 'c';
        return '?';
    }
    return '?';
}

// Offset einer Objekt-Eigenschaft der Klasse selbst (ChildProperties, ohne Oberklassen), 0 = nicht gefunden. Nur Worker.
uint32_t ClassObjectPropertyOffset(uintptr_t Class, const char* Wanted) {
    std::string Name;
    uintptr_t Field = Read<uintptr_t>(Class + 0x50);  // UStruct::ChildProperties
    for (int Index = 0; Index < 512 && LooksLikePointer(Field); ++Index) {
        if (NameText(Read<uint64_t>(Field + OffFFieldName), Name) && Name == Wanted) {
            const int32_t Offset = Read<int32_t>(Field + 0x44);  // FProperty::Offset_Internal
            return ParamType(Field) == 'o' && Offset >= 0x28 && Offset < 0x4000 ? static_cast<uint32_t>(Offset) : 0;
        }
        Field = Read<uintptr_t>(Field + 0x18);  // FField::Next
    }
    return 0;
}

// remote=1 (WORLD-7): APawn::PlayerState per Reflexion, sobald Pawn-Klasse (netcore.cfg) und FName::ToString bekannt
// sind. Bis dahin bzw. ohne Fund meldet der Status feat_remote=0 und ls_native schreibt keine remote=1-Zeilen.
int PawnPlayerStateTries = 0;

void ResolvePawnPlayerState() {
    if (OffPawnPlayerState.load() || !NameToStringFn || !Cfg.ClsPawn || PawnPlayerStateTries >= 20) return;
    if (!(ObjectArray() ? IsLiveObject(Cfg.ClsPawn) : LooksLikePointer(Cfg.ClsPawn) && IsReadable(Cfg.ClsPawn, 0x58))) return;
    const uint32_t Offset = ClassObjectPropertyOffset(Cfg.ClsPawn, "PlayerState");
    if (Offset) {
        OffPawnPlayerState.store(Offset);
        LogF("remote=1: Pawn.PlayerState bei 0x%X (feat_remote=1)", Offset);
    } else if (++PawnPlayerStateTries == 20) {
        Log("remote=1: Pawn.PlayerState nicht gefunden - remote=1 bleibt aus (feat_remote=0)");
    }
}

// Opcodes, deren GNatives-Eintrag der Beobachter umlenkt (0x64 nur fuer den Eintritt)
const uint8_t ObservedOps[] = {0x1B, 0x1C, 0x45, 0x46, 0x68, 0x64};

bool IsObservedOp(uint8_t Op) {
    for (uint8_t O : ObservedOps) if (O == Op) return true;
    return false;
}

std::vector<std::string> SplitWords(const std::string& Line) {
    std::vector<std::string> Words;
    for (size_t Start = 0; Start < Line.size();) {
        size_t First = Line.find_first_not_of(" \t", Start);
        if (First == std::string::npos) break;
        size_t End = Line.find_first_of(" \t", First);
        if (End == std::string::npos) End = Line.size();
        Words.push_back(Line.substr(First, End - First));
        Start = End;
    }
    return Words;
}

// Eine Zeile "<UFunction hex> <tag> observe|suppress [force] [at=entry|call] [local=1] [remote=1] [ff=<UClass hex>|pc]
// [sd=<Offset hex>]" pruefen und den Eintrag fuellen. Info = Zeile fuer netcore_watchinfo.txt.
// Runde 9 (WORLD-7): remote=1 = nur Kontexte fremder Spielerfiguren (IsRemoteContext), Gegenstueck zu local=1.
bool BuildWatchEntry(const std::string& Line, WatchEntry& Entry, std::string& Info) {
    const std::vector<std::string> Words = SplitWords(Line);
    if (Words.size() < 3 || (Words[2] != "observe" && Words[2] != "suppress")) {
        LogF("Watch: ungueltige Zeile '%s'", Line.c_str());
        return false;
    }
    const char* Tag = Words[1].c_str();
    char* End = nullptr;
    const unsigned long long Func = strtoull(Words[0].c_str(), &End, 16);
    const uintptr_t F = static_cast<uintptr_t>(Func);
    if (*End || !IsLiveObject(F) || !IsFunctionObject(F)) {
        LogF("Watch %s: Funktion %s lebt nicht", Tag, Words[0].c_str());
        return false;
    }
    bool Force = false, Local = false, Remote = false;
    int At = 0;  // 0 automatisch, 1 Eintritt, 2 Aufrufstelle
    uint32_t Sd = 0;
    uintptr_t FfClass = 0;
    int FfMode = 0;
    for (size_t I = 3; I < Words.size(); ++I) {
        const std::string& W = Words[I];
        if (W == "force") Force = true;
        else if (W == "at=entry") At = 1;
        else if (W == "at=call") At = 2;
        else if (W == "local=1") Local = true;
        else if (W == "remote=1") Remote = true;
        else if (W == "remote=0") Remote = false;
        else if (W == "ff=pc") FfMode = 2;
        else if (!W.compare(0, 3, "ff=")) {
            FfClass = static_cast<uintptr_t>(strtoull(W.c_str() + 3, nullptr, 16));
            FfMode = 1;
            if (!IsLiveObject(FfClass)) {
                LogF("Watch %s: ff-Klasse %s lebt nicht, nehme Figur mit PlayerController", Tag, W.c_str() + 3);
                FfClass = 0;
                FfMode = 2;
            }
        } else if (!W.compare(0, 3, "sd=")) {
            Sd = static_cast<uint32_t>(strtoul(W.c_str() + 3, nullptr, 16));
            if (Sd < 0x28 || Sd > 0x10000) {
                LogF("Watch %s: sd-Offset 0x%X unplausibel, aus", Tag, Sd);
                Sd = 0;
            }
        } else {
            LogF("Watch %s: unbekannte Option '%s' ignoriert", Tag, W.c_str());
        }
    }
    memset(&Entry, 0, sizeof(Entry));
    Entry.Func = F;
    Entry.Name = Read<uint64_t>(F + OffObjectName);
    Entry.Owner = Read<uintptr_t>(F + Cfg.OffOuter);
    Entry.OwnerName = IsLiveObject(Entry.Owner) ? Read<uint64_t>(Entry.Owner + OffObjectName) : 0;
    Entry.TargetArg = -1;
    Entry.TargetOffset = -1;
    Entry.CauserArg = Entry.InstigatorArg = -1;
    Entry.CauserOffset = Entry.InstigatorOffset = -1;
    snprintf(Entry.Tag, sizeof(Entry.Tag), "%s", Tag);
    bool ReturnTooBig = false;
    std::string Params, Name;
    int ParamIndex = 0;
    uintptr_t Field = Read<uintptr_t>(F + 0x50);  // UStruct::ChildProperties
    for (int Index = 0; Index < 64 && LooksLikePointer(Field); ++Index) {
        const uint64_t Flags = Read<uint64_t>(Field + 0x38);
        if (Flags & 0x80) {  // CPF_Parm
            const int32_t Size = Read<int32_t>(Field + 0x34);
            const int32_t Offset = Read<int32_t>(Field + 0x44);
            if (Flags & 0x400) {  // CPF_ReturnParm
                if (Size > 0 && Size <= 256) Entry.RetSize = static_cast<uint16_t>(Size);
                else ReturnTooBig = true;
                // Nullen per memset nur fuer POD-Typen (FText waere danach ein leerer TSharedRef -> Absturz)
                uint8_t RetType = ParamType(Field);
                if (RetType == 'S') RetType = StructParamType(Field, Size);
                Entry.RetUnsafe = (RetType == '?' || RetType == 's') ? 1 : 0;
            } else {
                uint8_t Type = ParamType(Field);
                if (Type == 'S') Type = StructParamType(Field, Size);
                const bool Out = (Flags & 0x100) && !(Flags & 0x2);  // CPF_OutParm ohne CPF_ConstParm
                if (!NameText(Read<uint64_t>(Field + OffFFieldName), Name) || Name.empty()) Name = "?";
                if (Type == 'o' && !Out && Entry.TargetOffset < 0 && Offset >= 0 && Offset < 0x10000) {
                    Entry.TargetOffset = Offset;
                    Entry.TargetArg = static_cast<int8_t>(Entry.NumArgs < MaxArgs ? ParamIndex : -1);
                } else if (Type == 'o' && !Out && Offset >= 0 && Offset < 0x10000) {
                    // pvp: Verursacher (DamageCauser) bzw. Ausloeser (EventInstigator) fuer die Clan-Pruefung
                    const bool IsCauser = Name.find("Causer") != std::string::npos;
                    const bool IsInstigator = Name.find("Instigator") != std::string::npos;
                    if (IsCauser && Entry.CauserOffset < 0) {
                        Entry.CauserOffset = Offset;
                        Entry.CauserArg = static_cast<int8_t>(Entry.NumArgs < MaxArgs ? ParamIndex : -1);
                    } else if (IsInstigator && Entry.InstigatorOffset < 0) {
                        Entry.InstigatorOffset = Offset;
                        Entry.InstigatorArg = static_cast<int8_t>(Entry.NumArgs < MaxArgs ? ParamIndex : -1);
                    }
                }
                if (Entry.NumArgs < MaxArgs) {
                    ParamDesc& Param = Entry.Params[Entry.NumArgs++];
                    Param.Type = Type;
                    Param.Size = static_cast<uint16_t>(Size > 0 && Size < 0x10000 ? Size : 0);
                    Param.Out = Out ? 1 : 0;
                    Param.Offset = Offset >= 0 && Offset < 0x10000 ? Offset : -1;
                }
                Params += (ParamIndex ? "," : "") + Name + ":" + static_cast<char>(Out ? '^' : Type);
                ++ParamIndex;
            }
        }
        Field = Read<uintptr_t>(Field + 0x18);
    }
    Entry.Suppress = Words[2] == "suppress" ? 1 : 0;
    const uint32_t FunctionFlags = Read<uint32_t>(F + Cfg.OffFunctionFlags);
    if (Entry.Suppress && (FunctionFlags & 0x400000) && !Force) {
        LogF("Watch %s: suppress verweigert (Out-Parameter), 'force' anhaengen; beobachte nur", Entry.Tag);
        Entry.Suppress = 0;
    }
    if (Entry.Suppress && ReturnTooBig) {
        LogF("Watch %s: suppress verweigert (Rueckgabewert zu gross); beobachte nur", Entry.Tag);
        Entry.Suppress = 0;
    }
    if (Entry.Suppress && Entry.RetUnsafe) {
        LogF("Watch %s: suppress verweigert (Rueckgabewert kein einfacher Typ, z. B. FText/FString); beobachte nur",
             Entry.Tag);
        Entry.Suppress = 0;
    }

    // Eintritt nur fuer Blueprint-Funktionen, deren erster Opcode umgelenkt ist (Event-Stubs: 0x64 oder 0x46)
    const uintptr_t ScriptArray = F + (Cfg.OffScript ? Cfg.OffScript : 0x60);
    const uintptr_t Data = Read<uintptr_t>(ScriptArray);
    const int32_t Num = Read<int32_t>(ScriptArray + 8);
    const bool Native = (FunctionFlags & 0x400) != 0;
    uint8_t First = 0;
    const bool EntryPossible = !Native && Num > 0 && Num < (16 << 20) && LooksLikePointer(Data & ~uintptr_t(7)) &&
                               TryRead(Data, First) &&
                               IsObservedOp(First);
    const bool WantEntry = At == 1 || (At == 0 && !Entry.Suppress && (FfMode || Sd || EntryPossible));
    if (!EntryPossible && (At == 1 || FfMode || Sd || (At == 0 && !Native && Num > 0 && !Entry.Suppress))) {
        // Blueprint-Funktion ohne passenden ersten Opcode: nur Aufrufe aus Blueprint-Code sind sichtbar
        LogF("Watch %s: Eintritt nicht moeglich (%s, erster Opcode 0x%02X), beobachte an der Aufrufstelle", Entry.Tag,
             Native ? "native Funktion" : Num <= 0 ? "kein Script" : "Opcode nicht umgelenkt", First);
    } else if (WantEntry && EntryPossible) {
        Entry.AtEntry = 1;
        Entry.ScriptData = Data;
        // UE_BLUEPRINT_EVENTGRAPH_FASTCALLS: ProcessEvent springt am Stub vorbei direkt in den Ubergraph
        if (Cfg.OffFunc >= 0xD8 && Read<uintptr_t>(F + Cfg.OffFunc - 0x10))
            LogF("Watch %s: Hinweis, Stub mit Ubergraph-Direktaufruf - Eintritt sieht nur Blueprint-Aufrufe, nicht "
                 "Timer/Delegates/RPC/ProcessEvent", Entry.Tag);
        if (Entry.Suppress) {
            uint8_t Tail[3] = {};
            // Nur Stubs ohne Rueckgabewert mit "EX_Return EX_Nothing EX_EndOfScript" am Ende
            if (!Entry.RetSize && Num >= 3 && SafeCopy(Tail, Data + static_cast<uint32_t>(Num) - 3, 3) && Tail[0] == 0x04 &&
                Tail[1] == 0x0B && Tail[2] == 0x53) {
                Entry.SkipTo = Num - 3;
            } else {
                LogF("Watch %s: suppress beim Eintritt nicht moeglich (Script-Ende/Rueckgabewert); beobachte nur", Entry.Tag);
                Entry.Suppress = 0;
            }
        }
    }
    if (Local && Remote) {
        LogF("Watch %s: local=1 und remote=1 zusammen, es gilt remote=1", Entry.Tag);
        Local = false;
    }
    Entry.LocalOnly = Local ? 1 : 0;
    Entry.RemoteOnly = Remote ? 1 : 0;
    if ((FfMode || Sd) && Entry.TargetOffset < 0) {
        LogF("Watch %s: ff/sd ohne Objekt-Parameter, aus", Entry.Tag);
        FfMode = 0;
        Sd = 0;
    }
    if ((FfMode || Sd) && !Entry.AtEntry && Entry.TargetArg < 0) {
        LogF("Watch %s: ff/sd an der Aufrufstelle braucht das Ziel unter den ersten %d Argumenten, aus", Entry.Tag, MaxArgs);
        FfMode = 0;
        Sd = 0;
    }
    if (FfMode && !Entry.AtEntry && (FunctionFlags & 0x400000) && !Force) {
        LogF("Watch %s: ff an der Aufrufstelle verweigert (Out-Parameter), 'force' anhaengen", Entry.Tag);
        FfMode = 0;
    }
    if (FfMode && !Entry.AtEntry && Entry.RetSize && Entry.RetUnsafe) {
        LogF("Watch %s: ff an der Aufrufstelle verweigert (Rueckgabewert kein einfacher Typ)", Entry.Tag);
        FfMode = 0;
    }
    Entry.FfMode = static_cast<uint8_t>(FfMode);
    Entry.FfClass = FfClass;
    Entry.SdOffset = Sd;
    char Head[160];
    snprintf(Head, sizeof(Head), "%s\t%llX\t%s\t%s%s%s%s%s\t", Entry.Tag, Func, Entry.AtEntry ? "entry" : "call",
             Entry.Suppress ? "suppress" : "observe", Entry.FfMode ? ",ff" : "", Entry.SdOffset ? ",sd" : "",
             Entry.LocalOnly ? ",local" : "", Entry.RemoteOnly ? ",remote" : "");
    Info = Head + Params;
    return true;
}

bool WatchStillValid(const WatchEntry& Entry) {
    if (!IsLiveObject(Entry.Func) || Read<uint64_t>(Entry.Func + OffObjectName) != Entry.Name ||
        Read<uintptr_t>(Entry.Func + Cfg.OffOuter) != Entry.Owner)
        return false;
    // Eintritt: Script-Speicher darf nicht umgezogen sein (Recompile/Neuladen)
    return !Entry.AtEntry || Read<uintptr_t>(Entry.Func + (Cfg.OffScript ? Cfg.OffScript : 0x60)) == Entry.ScriptData;
}

bool ObserverInstalled = false, ObserverBroken = false;

NativeFunc ObserverWrapper(uint8_t Op) {
    switch (Op) {
    case 0x1B: return &ObserveHook<0x1B>;
    case 0x1C: return &ObserveHook<0x1C>;
    case 0x45: return &ObserveHook<0x45>;
    case 0x46: return &ObserveHook<0x46>;
    case 0x64: return &ObserveHook<0x64>;
    default: return &ObserveHook<0x68>;
    }
}

void InstallObserver() {
    if (ObserverInstalled || ObserverBroken) return;
    if (!GNativesAddr) {
        Log("Beobachter: GNatives unbekannt (UE4SS.log), aus");
        ObserverBroken = true;
        return;
    }
    for (uint8_t Op : ObservedOps) {
        uintptr_t Current = 0;
        if (!TryRead(GNativesAddr + Op * sizeof(void*), Current) || Current < 0x10000) {
            LogF("Beobachter: GNatives[0x%02X] nicht lesbar, aus", Op);
            ObserverBroken = true;
            return;
        }
        if (Current < ImageBase || Current >= ImageEnd)
            LogF("Beobachter: GNatives[0x%02X] zeigt nicht ins Spiel-Image (%llx), wird verkettet", Op,
                 static_cast<unsigned long long>(Current));
        ObsOriginal[Op] = reinterpret_cast<NativeFunc>(Current);
    }
    for (uint8_t Op : ObservedOps)
        InterlockedExchangePointer(reinterpret_cast<void**>(GNativesAddr + Op * sizeof(void*)),
                                   reinterpret_cast<void*>(ObserverWrapper(Op)));
    ObserverInstalled = true;
    LogF("Beobachter installiert (GNatives %llx)", static_cast<unsigned long long>(GNativesAddr));
}

void RestoreObserver() {
    if (!ObserverInstalled) return;
    for (uint8_t Op : ObservedOps)
        InterlockedCompareExchangePointer(reinterpret_cast<void**>(GNativesAddr + Op * sizeof(void*)),
                                          reinterpret_cast<void*>(ObsOriginal[Op]),
                                          reinterpret_cast<void*>(ObserverWrapper(Op)));
    ObserverInstalled = false;
}

// Sperrliste nur auf Host/Einzelspieler (netmode aus netcore_opts.txt; unbekannt = aus)
bool DenyModeAllowed() {
    const int Mode = NetModeOpt.load();
    return Mode == NetHost || Mode == NetSolo;
}

void UpdateObserverState() {
    const WatchTable* Table = ActiveWatch.load();
    const DenyTable* Deny = ActiveDeny.load();
    const bool DenyWanted = Deny && Deny->Count > 0 && DenyModeAllowed() && DenyFaults.load() < 3;
    const bool Want = ((Table && Table->Count > 0) || DenyWanted) && ObserverWanted.load() && !ObserverBroken;
    if (Want) InstallObserver();
    const bool On = Want && ObserverInstalled && ObserverFaults.load() < 3;
    ObserverOn.store(On);
    DenyOn.store(On && DenyWanted);
}

void CheckObserverFaults() {
    if (!ObserverInstalled || ObserverFaults.load() < 3) return;
    ObserverOn.store(false);
    RestoreObserver();
    ObserverBroken = true;
    Log("Beobachter nach 3 Ausnahmen abgeschaltet, GNatives zurueckgesetzt");
}

// netcore_watch.txt (Lua): Liste ersetzen, wenn sich der Text aendert; jede Sekunde pruefen, ob die
// Funktionen noch leben (Weltwechsel/GC: Adresse koennte sonst eine andere Funktion treffen)
std::string LastWatchText;
// netcore_watchinfo.txt (DLL -> Lua): je Eintrag "<tag>\t<func hex>\t<entry|call>\t<modus[,ff][,sd][,local][,remote]>\t
// <name:typ>,..." (alle Parameter ohne Rueckgabe, Typ wie ParamDesc, '^' = Out). ls_native ordnet damit Felder zu.
std::string WatchInfoText;
bool WatchInfoWritten = false;

// Neuaufbau aus unveraendertem Text: Adresse koennte inzwischen eine andere Funktion sein (GC/Weltwechsel).
// Nur uebernehmen, wenn der bisherige Eintrag dieselbe Funktion (FName + Klasse bzw. Klassenname) beschrieb.
bool WatchSameIdentity(const WatchTable* Previous, const WatchEntry& Entry) {
    if (!Previous) return false;
    for (int I = 0; I < Previous->Count; ++I) {
        const WatchEntry& Old = Previous->Entries[I];
        if (Old.Func != Entry.Func) continue;
        return Old.Name == Entry.Name &&
               (Old.Owner == Entry.Owner || (Old.OwnerName && Old.OwnerName == Entry.OwnerName));
    }
    return false;  // vorher nicht aktiv (z. B. tot): erst mit neuem Text von Lua
}

void ProcessWatchFile(bool Revalidate) {
    const std::wstring Path = ModDir + L"netcore_watch.txt";
    static ControlFileState State;
    std::string Text = ReadControlFile(Path, true, LastWatchText, State);
    const bool Changed = Text != LastWatchText;
    const WatchTable* Previous = nullptr;
    if (!Changed) {
        const WatchTable* Current = ActiveWatch.load();
        if (!Revalidate || !Current || !Current->Count) return;
        bool Valid = true;
        for (int I = 0; I < Current->Count; ++I) Valid = Valid && WatchStillValid(Current->Entries[I]);
        if (Valid) return;
        Log("Watch: Funktion entladen oder ersetzt, Liste neu aufgebaut");
        Previous = Current;
    }
    LastWatchText = Text;
    auto* Table = new WatchTable();
    std::string Info;
    for (const std::string& Line : SplitLines(Text)) {
        if (Line.empty() || Line[0] == '#') continue;
        if (Table->Count >= MaxWatches) {
            LogF("Watch: mehr als %d Eintraege, Rest ignoriert", MaxWatches);
            break;
        }
        WatchEntry& Entry = Table->Entries[Table->Count];
        std::string EntryInfo;
        if (!BuildWatchEntry(Line, Entry, EntryInfo)) continue;
        if (Previous && !WatchSameIdentity(Previous, Entry)) {
            LogF("Watch %s: Adresse %llX gehoert jetzt einer anderen Funktion, ausgelassen bis Lua neu schreibt",
                 Entry.Tag, static_cast<unsigned long long>(Entry.Func));
            continue;
        }
        bool Duplicate = false;
        for (int I = 0; I < Table->Count; ++I) Duplicate = Duplicate || Table->Entries[I].Func == Entry.Func;
        if (Duplicate) continue;
        const int16_t Index = static_cast<int16_t>(Table->Count++);
        if (Entry.AtEntry) {
            size_t Slot = WatchSlot(Entry.Func);
            while (Table->ByEntry[Slot] >= 0) Slot = (Slot + 1) & (WatchSlots - 1);
            Table->ByEntry[Slot] = Index;
            ++Table->EntryCount;
        } else {
            size_t Slot = WatchSlot(Entry.Func);
            while (Table->ByFunc[Slot] >= 0) Slot = (Slot + 1) & (WatchSlots - 1);
            Table->ByFunc[Slot] = Index;
            Slot = WatchSlot(Entry.Name);
            while (Table->ByName[Slot] >= 0) Slot = (Slot + 1) & (WatchSlots - 1);
            Table->ByName[Slot] = Index;
            ++Table->CallCount;
        }
        if (Entry.Suppress) ++Table->Suppressing;
        Info += EntryInfo + "\n";
    }
    const WatchTable* Old = ActiveWatch.exchange(Table);
    if (Old) Retired.push_back({Old, nullptr, GetTickCount64()});
    LogF("Beobachter: %d Funktionen (%d beim Eintritt, %d an der Aufrufstelle, %d unterdrueckt)", Table->Count,
         Table->EntryCount, Table->CallCount, Table->Suppressing);
    WatchInfoText = Info;
    if (WriteText(ModDir + L"netcore_watchinfo.txt", Info)) WatchInfoWritten = true;
    UpdateObserverState();
}

// Lua loescht seine Dateien beim Start; fehlt watchinfo, wird sie neu geschrieben
void KeepWatchInfo() {
    if (!WatchInfoWritten || GetFileAttributesW((ModDir + L"netcore_watchinfo.txt").c_str()) != INVALID_FILE_ATTRIBUTES)
        return;
    WriteText(ModDir + L"netcore_watchinfo.txt", WatchInfoText);
}

// ---------------------------------------------------------------------------------------------------------
// Sperrliste (netcore_deny.txt, Lua -> DLL, nur Host): je Zeile
//   <UFunction hex> <Kontext hex> <Parametername|-> <Wert hex|0> [<tag>]
// "-" = jeder Aufruf mit diesem Kontext, Wert 0 = Parameter null. Alle 200 ms gelesen (nur bei neuem Text neu
// gebaut, atomarer Zeigertausch), jede Sekunde auf entladene/ersetzte Objekte geprueft.
std::string LastDenyText;
std::unordered_set<std::string> DenyLogged;              // Eintraege, deren erster Block schon im Log steht
std::unordered_set<std::string> DenyDead;                // bei der Pruefung ungueltig, bis Lua neuen Text schreibt
std::unordered_map<std::string, int32_t> ParamOffsetCache;  // "<func>|<fname>|<name>" -> Offset (< 0: ungeeignet)
bool DenyFaultLogged = false;

// Offset eines Objekt-Parameters (Name ohne Gross/Klein) in Stack.Locals; < 0 = nicht gefunden / ungeeignet
int32_t ResolveParamOffset(uintptr_t Func, const std::string& Wanted, const char*& Why) {
    char Key[160];
    snprintf(Key, sizeof(Key), "%llX|%llX|%s", static_cast<unsigned long long>(Func),
             static_cast<unsigned long long>(Read<uint64_t>(Func + OffObjectName)), Wanted.c_str());
    auto Found = ParamOffsetCache.find(Key);
    int32_t Result = -1;
    if (Found != ParamOffsetCache.end()) {
        Result = Found->second;
    } else {
        std::string Name;
        uintptr_t Field = Read<uintptr_t>(Func + 0x50);  // UStruct::ChildProperties
        for (int Index = 0; Index < 64 && LooksLikePointer(Field); ++Index) {
            const uint64_t Flags = Read<uint64_t>(Field + 0x38);
            if ((Flags & 0x80) && !(Flags & 0x400) && NameText(Read<uint64_t>(Field + OffFFieldName), Name) &&
                !_stricmp(Name.c_str(), Wanted.c_str())) {
                const int32_t Offset = Read<int32_t>(Field + 0x44);
                const bool Out = (Flags & 0x100) && !(Flags & 0x2);
                Result = Out ? -3 : ParamType(Field) != 'o' ? -2 : (Offset >= 0 && Offset < 0x10000) ? Offset : -4;
                break;
            }
            Field = Read<uintptr_t>(Field + 0x18);
        }
        ParamOffsetCache.emplace(Key, Result);
    }
    Why = Result == -1 ? "Parameter nicht gefunden" : Result == -2 ? "Parameter ist kein Objekt"
        : Result == -3 ? "Out-Parameter" : Result < 0 ? "Offset unplausibel" : "";
    return Result;
}

bool BuildDenyEntry(const std::string& Line, DenyEntry& Entry, const char*& Why) {
    const std::vector<std::string> Words = SplitWords(Line);
    Why = "Format";
    if (Words.size() < 4) return false;
    char* End = nullptr;
    const uintptr_t F = static_cast<uintptr_t>(strtoull(Words[0].c_str(), &End, 16));
    if (*End) return false;
    const uintptr_t Ctx = static_cast<uintptr_t>(strtoull(Words[1].c_str(), &End, 16));
    if (*End) return false;
    const uintptr_t Value = static_cast<uintptr_t>(strtoull(Words[3].c_str(), &End, 16));
    if (*End) return false;
    memset(&Entry, 0, sizeof(Entry));
    Why = "Funktion lebt nicht";
    if (!IsLiveObject(F) || !IsFunctionObject(F)) return false;
    const uint32_t FunctionFlags = Read<uint32_t>(F + Cfg.OffFunctionFlags);
    Why = "native Funktion (kein Eintritt)";
    if (FunctionFlags & 0x400) return false;
    Why = "Rueckgabewert";
    if (Read<uint16_t>(F + Cfg.OffReturnValue) != 0xFFFF) return false;
    const uintptr_t ScriptArray = F + (Cfg.OffScript ? Cfg.OffScript : 0x60);
    const uintptr_t Data = Read<uintptr_t>(ScriptArray);
    const int32_t Num = Read<int32_t>(ScriptArray + 8);
    uint8_t First = 0, Tail[3] = {};
    Why = "kein Script";
    if (Num < 4 || Num >= (16 << 20) || !LooksLikePointer(Data & ~uintptr_t(7)) || !TryRead(Data, First)) return false;
    Why = "erster Opcode nicht umgelenkt";
    if (!IsObservedOp(First)) return false;
    Why = "Script-Ende nicht EX_Return EX_Nothing EX_EndOfScript";
    if (!SafeCopy(Tail, Data + static_cast<uint32_t>(Num) - 3, 3) || Tail[0] != 0x04 || Tail[1] != 0x0B || Tail[2] != 0x53)
        return false;
    Entry.Func = F;
    Entry.FuncName = Read<uint64_t>(F + OffObjectName);
    Entry.FuncOwner = Read<uintptr_t>(F + Cfg.OffOuter);
    Entry.ScriptData = Data;
    Entry.SkipTo = Num - 3;
    Why = "Kontext lebt nicht oder passt nicht zur Klasse der Funktion";
    if (!IsLiveObject(Ctx) || !IsA(Ctx, Entry.FuncOwner)) return false;
    Entry.Context = Ctx;
    Entry.CtxClass = Read<uintptr_t>(Ctx + Cfg.OffClass);
    Entry.CtxIndex = Read<int32_t>(Ctx + Cfg.OffObjectIndex);
    Entry.ParamOffset = -1;
    if (Words[2] != "-") {
        Entry.ParamOffset = ResolveParamOffset(F, Words[2], Why);
        if (Entry.ParamOffset < 0) return false;
        Why = "Wert lebt nicht";
        if (Value && !IsLiveObject(Value)) return false;
        Entry.Value = Value;
        Entry.ValueClass = Value ? Read<uintptr_t>(Value + Cfg.OffClass) : 0;
        Entry.ValueIndex = Value ? Read<int32_t>(Value + Cfg.OffObjectIndex) : -1;
    }
    snprintf(Entry.Tag, sizeof(Entry.Tag), "%s", Words.size() > 4 ? Words[4].c_str() : "deny");
    for (char* C = Entry.Tag; *C; ++C)
        if (!isalnum(static_cast<unsigned char>(*C)) && *C != '_') *C = '_';
    snprintf(Entry.Key, sizeof(Entry.Key), "%llX %llX %s %llX", static_cast<unsigned long long>(F),
             static_cast<unsigned long long>(Ctx), Words[2].c_str(), static_cast<unsigned long long>(Entry.Value));
    // UE_BLUEPRINT_EVENTGRAPH_FASTCALLS: Stubs ohne Parameter ueberspringt ProcessEvent (RPC/Timer) ganz
    if (Cfg.OffFunc >= 0xD8 && Read<uintptr_t>(F + Cfg.OffFunc - 0x10))
        LogF("Sperre %s: Hinweis, Stub mit Ubergraph-Direktaufruf - greift nur bei Blueprint-Aufrufen, nicht bei RPC",
             Entry.Tag);
    Why = "";
    return true;
}

bool DenyStillValid(const DenyEntry& Entry) {
    if (!IsLiveObject(Entry.Func) || Read<uint64_t>(Entry.Func + OffObjectName) != Entry.FuncName ||
        Read<uintptr_t>(Entry.Func + Cfg.OffOuter) != Entry.FuncOwner ||
        Read<uintptr_t>(Entry.Func + (Cfg.OffScript ? Cfg.OffScript : 0x60)) != Entry.ScriptData)
        return false;
    if (!IsLiveObject(Entry.Context) || Read<uintptr_t>(Entry.Context + Cfg.OffClass) != Entry.CtxClass ||
        Read<int32_t>(Entry.Context + Cfg.OffObjectIndex) != Entry.CtxIndex)
        return false;
    return !Entry.Value || (IsLiveObject(Entry.Value) && Read<uintptr_t>(Entry.Value + Cfg.OffClass) == Entry.ValueClass &&
                            Read<int32_t>(Entry.Value + Cfg.OffObjectIndex) == Entry.ValueIndex);
}

void ProcessDenyFile(bool Revalidate) {
    const std::wstring Path = ModDir + L"netcore_deny.txt";
    static ControlFileState State;
    std::string Text = ReadControlFile(Path, true, LastDenyText, State);
    const bool Changed = Text != LastDenyText;
    if (Changed) {
        DenyDead.clear();
    } else {
        const DenyTable* Current = ActiveDeny.load();
        if (!Revalidate || !Current || !Current->Count) return;
        bool Valid = true;
        for (int I = 0; I < Current->Count; ++I) {
            if (DenyStillValid(Current->Entries[I])) continue;
            Valid = false;
            DenyDead.insert(Current->Entries[I].Key);  // gleiche Adresse spaeter neu vergeben: nicht wieder sperren
        }
        if (Valid) return;
        Log("Sperrliste: Objekt entladen oder ersetzt, Liste neu aufgebaut");
    }
    LastDenyText = Text;
    auto* Table = new DenyTable();
    int Rejected = 0;
    std::unordered_set<std::string> Keys;
    for (const std::string& Line : SplitLines(Text)) {
        if (Line.empty() || Line[0] == '#') continue;
        if (Table->Count >= MaxDeny) {
            LogF("Sperrliste: mehr als %d Eintraege, Rest ignoriert", MaxDeny);
            break;
        }
        DenyEntry& Entry = Table->Entries[Table->Count];
        const char* Why = "";
        if (!BuildDenyEntry(Line, Entry, Why)) {
            ++Rejected;
            if (Changed) LogF("Sperre verworfen (%s): %s", Why, Line.c_str());
            continue;
        }
        if (DenyDead.count(Entry.Key)) {
            ++Rejected;
            continue;
        }
        if (!Keys.insert(Entry.Key).second) continue;  // doppelt
        size_t Slot = DenySlot(Entry.Func, Entry.Context);
        while (Table->Slots[Slot] >= 0) Slot = (Slot + 1) & (DenySlots - 1);
        Table->Slots[Slot] = static_cast<int16_t>(Table->Count++);
    }
    for (auto It = DenyLogged.begin(); It != DenyLogged.end();) It = Keys.count(*It) ? std::next(It) : DenyLogged.erase(It);
    const DenyTable* Old = ActiveDeny.exchange(Table);
    if (Old) {
        RetiredTable R{nullptr, nullptr, GetTickCount64()};
        R.Deny = Old;
        Retired.push_back(R);
    }
    if (Changed || Rejected)
        LogF("Sperrliste: %d Eintraege aktiv, %d verworfen (netmode %s)", Table->Count, Rejected,
             DenyModeAllowed() ? "ok" : "nicht Host - aus");
    UpdateObserverState();
}

// Erster Block je Eintrag ins Log; Abschalten nach 3 Ausnahmen melden
void LogDenyHits() {
    if (DenyFaults.load() >= 3 && !DenyFaultLogged) {
        DenyFaultLogged = true;
        DenyOn.store(false);
        Log("Sperrliste nach 3 Ausnahmen abgeschaltet");
    }
    const DenyTable* Table = ActiveDeny.load();
    if (!Table) return;
    for (int I = 0; I < Table->Count; ++I) {
        if (!Table->Hits[I].load(std::memory_order_relaxed)) continue;
        const DenyEntry& Entry = Table->Entries[I];
        if (!DenyLogged.insert(Entry.Key).second) continue;
        std::string Func = "?", Ctx = "?";
        if (IsLiveObject(Entry.Func)) ObjectName(Entry.Func, Func);
        if (IsLiveObject(Entry.Context)) ObjectName(Entry.Context, Ctx);
        LogF("Sperre %s: erster Block %s auf %s (%s)", Entry.Tag, Func.c_str(), Ctx.c_str(), Entry.Key);
    }
}

// Clan-Verbuendete (netcore_allies.txt, Lua -> DLL): "<Pawn hex> <Clan-Index>", Index > 0, hoechstens 64 Zeilen.
// Neu gebaut bei neuem Text oder (jede Sekunde geprueft) wenn eine Figur nicht mehr lebt bzw. ersetzt wurde.
std::string LastAlliesText;
std::unordered_set<uintptr_t> AlliesDead;  // bei der Pruefung ungueltig, bis Lua neuen Text schreibt

void ProcessAlliesFile(bool Revalidate) {
    const std::wstring Path = ModDir + L"netcore_allies.txt";
    static ControlFileState State;
    std::string Text = ReadControlFile(Path, true, LastAlliesText, State);
    const bool Changed = Text != LastAlliesText;
    if (Changed) {
        AlliesDead.clear();
    } else {
        const AlliesTable* Current = ActiveAllies.load();
        if (!Revalidate || !Current || !Current->Count) return;
        bool Valid = true;
        for (int I = 0; I < Current->Count; ++I) {
            const uintptr_t P = Current->Pawn[I];
            if (IsLiveObject(P) && Read<uintptr_t>(P + Cfg.OffClass) == Current->Class[I] &&
                Read<int32_t>(P + Cfg.OffObjectIndex) == Current->ObjIndex[I])
                continue;
            Valid = false;
            AlliesDead.insert(P);
        }
        if (Valid) return;
    }
    LastAlliesText = Text;
    auto* Table = new AlliesTable();
    int Rejected = 0;
    for (const std::string& Line : SplitLines(Text)) {
        if (Line.empty() || Line[0] == '#' || Table->Count >= MaxAllies) continue;
        unsigned long long Pawn = 0;
        int Clan = 0;
        const uintptr_t P = sscanf(Line.c_str(), "%llx %d", &Pawn, &Clan) == 2 ? static_cast<uintptr_t>(Pawn) : 0;
        if (!P || Clan <= 0 || AlliesDead.count(P) || !IsLiveObject(P) || !IsA(P, Cfg.ClsPawn)) {
            ++Rejected;
            continue;
        }
        const int I = Table->Count++;
        Table->Pawn[I] = P;
        Table->Clan[I] = Clan;
        Table->Class[I] = Read<uintptr_t>(P + Cfg.OffClass);
        Table->ObjIndex[I] = Read<int32_t>(P + Cfg.OffObjectIndex);
    }
    const AlliesTable* Old = ActiveAllies.exchange(Table);
    if (Old) {
        RetiredTable R{nullptr, nullptr, GetTickCount64()};
        R.Allies = Old;
        Retired.push_back(R);
    }
    LogF("Clan-Verbuendete: %d Figuren%s (pvp=%d)", Table->Count,
         Rejected ? ", ungueltige Zeilen verworfen" : "", PvpMode.load() ? 1 : 0);
}

// netcore_status.txt: kann der Beobachter arbeiten? (ls_native.Available, Feature-Erkennung der Module)
std::string LastStatusText;

void WriteStatus() {
    const WatchTable* Table = ActiveWatch.load();
    const bool Capable = GNativesAddr && !ObserverBroken && ObserverWanted.load() && ObserverFaults.load() < 3;
    const DenyTable* Deny = ActiveDeny.load();
    const AlliesTable* Allies = ActiveAllies.load();
    char Text[512];
    snprintf(Text, sizeof(Text),
             "capable=%d\ninstalled=%d\nbroken=%d\nfaults=%d\nentry=%d\ncall=%d\nsession=%llX\n"
             "deny=%d\ndenyon=%d\ndenied=%llu\ndenyfaults=%d\nallies=%d\npvp=%d\n",
             Capable ? 1 : 0, ObserverInstalled ? 1 : 0, ObserverBroken ? 1 : 0, ObserverFaults.load(),
             Table ? Table->EntryCount : 0, Table ? Table->CallCount : 0, static_cast<unsigned long long>(SessionStamp),
             Deny ? Deny->Count : 0, DenyOn.load() ? 1 : 0, static_cast<unsigned long long>(DenyBlocked.load()),
             DenyFaults.load(), Allies ? Allies->Count : 0, PvpMode.load() ? 1 : 0);
    std::string Full = Text;
    // Runde 9: Faehigkeiten dieser DLL (ls_native/main/world entscheiden damit ueber die neuen Wege)
    // n6fn: N6-Funktions-Eintraege "+ Klasse.Funktion"; maxargs: Argumente je Ereignis; feat_remote: Watch-Option
    // remote=1 wirkt (Pawn.PlayerState gefunden, sonst 0 -> ls_native laesst solche Zeilen weg)
    // drop_outer: die DLL kennt die opts-Zeile drop_outer (INV-15); ob sie an ist, steht im Log "Optionen: ..."
    snprintf(Text, sizeof(Text), "n6fn=1\nmaxargs=%d\nfeat_remote=%d\ndrop_outer=1\n", MaxArgs,
             OffPawnPlayerState.load() ? 1 : 0);
    Full += Text;
    // Patch-Zustaende (ls_world W.RwPatchOk): nur Namen aus [A-Za-z0-9_], sonst liest Lua die Zeile nicht
    AcquireSRWLockShared(&PatchStateLock);
    for (const PatchStateEntry& E : PatchStates) {
        bool Clean = !E.Name.empty() && E.Name.size() < 64;
        for (char C : E.Name) Clean = Clean && (isalnum(static_cast<unsigned char>(C)) || C == '_');
        if (!Clean) continue;
        char Line[96];
        snprintf(Line, sizeof(Line), "patch_%s=%d\n", E.Name.c_str(), E.State);
        Full += Line;
    }
    ReleaseSRWLockShared(&PatchStateLock);
    const std::wstring Path = ModDir + L"netcore_status.txt";
    if (Full == LastStatusText && GetFileAttributesW(Path.c_str()) != INVALID_FILE_ATTRIBUTES) return;
    if (WriteText(Path, Full)) LastStatusText = Full;
}

// netcore_events.txt: Kopfzeile "#E <sitzung> <letzte seq> <verworfen> <unterdrueckt> <fehler>[ lost=...]", dann je
// Ereignis "<seq>\t<tag>\t<o|s>\t<kontext>\t<aufrufer>\t<ms>\t<arg1>..." (hoechstens 256 Zeilen, <= 10 s alt).
// Werte: o:<Klasse Pfad> | o:- | o:0x<hex> (tot) | i:<int> | f:<zahl> | b:0/1 | s:<text> | n:<name> | ^ | ?
// In Texten sind % TAB CR LF als %XX maskiert.
// CORE-25 (d): Fenster je Tag (die letzten 64), zusammen hoechstens 256 Zeilen - darueber faellt das aelteste Ereignis
// des Tags mit den meisten Zeilen heraus. Ein Massen-Tag (cb_dmg, trd_note) verdraengt so keine seltenen (n8_task).
// Zeilen nach seq sortiert. Kopfzeile hinten optional " lost=<tag>:<n>,..." = je Tag vor Ablauf der 10 s aus dem
// Fenster gefallene Ereignisse (Summe der Sitzung, die 16 groessten). ls_native liest nur "#E <s> <seq> <verworfen>".
struct OutEvent {
    uint64_t Seq, Ms;
    std::string Line;
};
constexpr size_t TagWindowMax = 64, EventWindowMax = 256;
std::unordered_map<std::string, std::deque<OutEvent>> TagWindows;
std::unordered_map<std::string, uint64_t> TagLost;
size_t EventWindowSize = 0;
uint64_t EventSeq = 0, WrittenDropped = 0;

std::string EscapeField(const std::string& Text) {
    std::string Out;
    for (char C : Text) {
        switch (C) {
        case '%': Out += "%25"; break;
        case '\t': Out += "%09"; break;
        case '\n': Out += "%0A"; break;
        case '\r': Out += "%0D"; break;
        default: Out += C;
        }
    }
    return Out;
}

std::string FormatObject(uintptr_t Object) {
    if (!Object) return "o:-";
    std::string Class, Path;
    if (IsLiveObject(Object) && ObjectName(Read<uintptr_t>(Object + Cfg.OffClass), Class) && ObjectPath(Object, Path))
        return "o:" + EscapeField(Class + " " + Path);
    char Raw[40];
    snprintf(Raw, sizeof(Raw), "o:0x%llX", static_cast<unsigned long long>(Object));
    return Raw;
}

std::string FormatArgument(const EventArg& Arg) {
    char Text[64];
    switch (Arg.Type) {
    case 'o': return FormatObject(static_cast<uintptr_t>(Arg.Raw));
    case 'i': snprintf(Text, sizeof(Text), "i:%lld", static_cast<long long>(Arg.Raw)); return Text;
    case 'f': {
        float V;
        const uint32_t Bits = static_cast<uint32_t>(Arg.Raw);
        memcpy(&V, &Bits, 4);
        snprintf(Text, sizeof(Text), "f:%.9g", static_cast<double>(V));
        return Text;
    }
    case 'd': {
        double V;
        memcpy(&V, &Arg.Raw, 8);
        snprintf(Text, sizeof(Text), "f:%.17g", V);
        return Text;
    }
    case 'b': return Arg.Raw ? "b:1" : "b:0";
    case 's': {
        wchar_t Wide[41];
        for (int I = 0; I < Arg.Len && I < 40; ++I) Wide[I] = static_cast<wchar_t>(Arg.Text[I]);
        return "s:" + EscapeField(ToUtf8(Wide, Arg.Len < 40 ? Arg.Len : 40));
    }
    case 'n': {
        std::string Name;
        return NameText(Arg.Raw, Name) ? "n:" + EscapeField(Name) : std::string("n:?");
    }
    case 'v': case 'r': {
        if (Arg.Len != 24) return "?";
        double V[3];
        memcpy(V, Arg.Text, sizeof(V));
        for (double D : V) if (!(D > -1e12 && D < 1e12)) return "?";
        char Long[128];
        snprintf(Long, sizeof(Long), "%c:%.3f,%.3f,%.3f", Arg.Type, V[0], V[1], V[2]);
        return Long;
    }
    case 'c': {
        if (Arg.Len != 16) return "?";
        float C[4];
        memcpy(C, Arg.Text, sizeof(C));
        for (float F : C) if (!(F > -1e9f && F < 1e9f)) return "?";
        char Long[128];
        snprintf(Long, sizeof(Long), "c:%.5g,%.5g,%.5g,%.5g", static_cast<double>(C[0]), static_cast<double>(C[1]),
                 static_cast<double>(C[2]), static_cast<double>(C[3]));
        return Long;
    }
    case '^': return "^";
    default: return "?";
    }
}

void FlushEvents() {
    EventRec Rec;
    int Count = 0;
    while (Count < 4096 && RingPop(Rec)) {
        ++Count;
        std::string Line = std::to_string(++EventSeq);
        Rec.Tag[sizeof(Rec.Tag) - 1] = 0;
        Line += '\t';
        Line += Rec.Tag;
        Line += Rec.Suppressed ? "\ts" : "\to";
        if (Rec.Flags & EvRemote) Line += 'R';
        if (Rec.Flags & EvLocal) Line += 'L';
        if (Rec.Flags & EvBlocked) Line += 'F';
        if (Rec.Flags & EvEntry) Line += 'E';
        if (Rec.Flags & EvDistance) Line += 'D';
        Line += '\t';
        Line += FormatObject(Rec.Context) + "\t" + FormatObject(Rec.Caller) + "\t" + std::to_string(Rec.TimeMs);
        for (int I = 0; I < Rec.NumArgs && I < MaxArgs; ++I) Line += "\t" + FormatArgument(Rec.Args[I]);
        const std::string Tag = Rec.Tag;
        std::deque<OutEvent>& Window = TagWindows[Tag];
        Window.push_back({EventSeq, Rec.TimeMs, std::move(Line)});
        ++EventWindowSize;
        if (Window.size() > TagWindowMax) {  // je Tag nur die letzten 64
            Window.pop_front();
            --EventWindowSize;
            ++TagLost[Tag];
        }
    }
    const uint64_t Now = GetTickCount64();
    bool Trimmed = false;
    // Aelter als 10 s: vorne abschneiden (kein Verlust, ein neuer Leser bekommt ohnehin nur das Fenster)
    for (auto It = TagWindows.begin(); It != TagWindows.end();) {
        std::deque<OutEvent>& Window = It->second;
        while (!Window.empty() && Now - Window.front().Ms > 10000) {
            Window.pop_front();
            --EventWindowSize;
            Trimmed = true;
        }
        It = Window.empty() ? TagWindows.erase(It) : std::next(It);
    }
    // Gesamtgrenze: das aelteste Ereignis des groessten Fensters faellt heraus
    while (EventWindowSize > EventWindowMax && !TagWindows.empty()) {
        auto Biggest = TagWindows.begin();
        for (auto It = std::next(TagWindows.begin()); It != TagWindows.end(); ++It)
            if (It->second.size() > Biggest->second.size() ||
                (It->second.size() == Biggest->second.size() && It->second.front().Seq < Biggest->second.front().Seq))
                Biggest = It;
        ++TagLost[Biggest->first];
        Biggest->second.pop_front();
        --EventWindowSize;
        Trimmed = true;
        if (Biggest->second.empty()) TagWindows.erase(Biggest);
    }
    const uint64_t Dropped = ObsDropped.load();
    if (!Count && !Trimmed && Dropped == WrittenDropped) return;
    if (!EventSeq && !Dropped) return;
    char Head[160];
    snprintf(Head, sizeof(Head), "#E %llX %llu %llu %llu %d", static_cast<unsigned long long>(SessionStamp),
             static_cast<unsigned long long>(EventSeq), static_cast<unsigned long long>(Dropped),
             static_cast<unsigned long long>(ObsSuppressed.load()), ObserverFaults.load());
    std::string Text = Head;
    if (!TagLost.empty()) {
        std::vector<std::pair<uint64_t, const std::string*>> Lost;
        for (const auto& Entry : TagLost) Lost.push_back({Entry.second, &Entry.first});
        std::sort(Lost.begin(), Lost.end(), [](const std::pair<uint64_t, const std::string*>& A,
                                               const std::pair<uint64_t, const std::string*>& B) {
            return A.first != B.first ? A.first > B.first : *A.second < *B.second;
        });
        Text += " lost=";
        for (size_t I = 0; I < Lost.size() && I < 16; ++I) {
            if (I) Text += ',';
            Text += *Lost[I].second + ":" + std::to_string(Lost[I].first);
        }
    }
    Text += '\n';
    std::vector<const OutEvent*> Ordered;
    Ordered.reserve(EventWindowSize);
    for (const auto& Window : TagWindows)
        for (const OutEvent& Event : Window.second) Ordered.push_back(&Event);
    std::sort(Ordered.begin(), Ordered.end(), [](const OutEvent* A, const OutEvent* B) { return A->Seq < B->Seq; });
    for (const OutEvent* Event : Ordered) {
        Text += Event->Line;
        Text += '\n';
    }
    if (WriteText(ModDir + L"netcore_events.txt", Text)) WrittenDropped = Dropped;
}

// N6-Liste: eingebaute Standardliste, netcore_n6.txt im Mod-Ordner ersetzt sie (ls_native schreibt sie immer).
// Runde 9 (AI-4/AI-5/WORLD-25): Standard = sichere Liste (wie ls_native ai_n6_list=safe): nur Spawner-/Wellen-Kontexte
// und der POI-Manager, dazu Funktions-Eintraege "+ Klasse.Funktion" (Skalierung nach Stufe/Tagen, Umgebungspruefung der
// Prefab-Spawner). Zombies/Tiere/Banditen/Ernte bewusst nicht: deren Tod-Pfade gaeben Kill/XP sonst nativ dem naechsten
// Gast. Die alte volle Liste (bis Runde 8) schreibt ls_native mit ai_n6_list=full.
// UE 5.6: BP_MasterMilitary_C -> BP_MasterCoyoteSoldier_C, BP_LaptopEventManager_C -> BP_BountyQuestManager_C,
// BP_AISpawningVolume_HumanQuest_C (entfernt) -> BP_Quest_Spawner_AI_C (neues Quest-KI-Spawnsystem)
const char DefaultN6List[] =
    "+ BP_AISpawner_Master_C\n+ BP_AISpawningVolume_Prefab_C\n+ BP_AISpawningVolume_RandomChanceToSpawn_C\n"
    "+ BP_Quest_Spawner_AI_C\n+ Buildable_HordeBeacon_C\n+ BP_Infestation_C\n+ BP_POIManager_C\n"
    "+ GameFunctionLibrary_C.ScalingDamageMultiplier\n+ GameFunctionLibrary_C.ScalingHealthMultiplier\n"
    "+ BP_PrefabSpawner_C.CheckSurroundingArea\n"
    "- UserWidget\n- HUD\n- PlayerCameraManager\n- AnimInstance\n- GameInstance\n- BP_Audio_Manager_C\n"
    "- BP_Audio_Area_C\n- UDS_PlayerOcclusion_C\n- Ultra_Dynamic_Sky_C\n- Ultra_Dynamic_Weather_C\n";

struct ListedClass {
    std::string Name;         // Klassenname
    std::string Func;         // Runde 9: Funktionsname bei "Klasse.Funktion", sonst leer (Klassen-Eintrag)
    bool White = false;
    uintptr_t Class = 0;      // UClass* (0 = noch nicht gefunden)
    uintptr_t Function = 0;   // UFunction* der Funktions-Eintraege (0 = noch nicht gefunden)
    bool NoFunc = false;      // Klasse da, Funktion nicht (einmal geloggt, loest keine Neusuche aus)
};
std::vector<ListedClass> Listed;
std::string ListedSource;
uint64_t LastClassScan = 0;

void PublishClassLists() {
    auto* Lists = new ClassLists();
    for (const ListedClass& Entry : Listed) {
        if (!Entry.Func.empty()) {
            if (!Entry.Function) continue;
            if (Entry.White && Lists->WhiteFuncs < MaxListedFuncs) Lists->WhiteFunc[Lists->WhiteFuncs++] = Entry.Function;
            if (!Entry.White && Lists->BlackFuncs < MaxListedFuncs) Lists->BlackFunc[Lists->BlackFuncs++] = Entry.Function;
            continue;
        }
        if (!Entry.Class) continue;
        if (Entry.White && Lists->White < MaxListed) Lists->WhiteClass[Lists->White++] = Entry.Class;
        if (!Entry.White && Lists->Black < MaxListed) Lists->BlackClass[Lists->Black++] = Entry.Class;
    }
    const ClassLists* Old = ActiveLists.exchange(Lists);
    if (Old) Retired.push_back({nullptr, Old, GetTickCount64()});
    for (auto& Slot : VerdictCache) Slot.store(0, std::memory_order_relaxed);
    LogF("N6: Whitelist %d Klassen + %d Funktionen, Sperren %d Klassen + %d Funktionen geladen (von %u)", Lists->White,
         Lists->WhiteFuncs, Lists->Black, Lists->BlackFuncs, static_cast<unsigned>(Listed.size()));
}

// Klassennamen -> UClass*: Outer aller UFunctions in GUObjectArray (BP-Klassen laden erst mit der Welt). Wanted:
// Name -> Klasse (0 = gesucht), Gefundene werden eingetragen. Nur Worker (NameText). Rueckgabe: neu gefunden.
int ScanClassesByName(std::unordered_map<std::string, uintptr_t>& Wanted) {
    const uintptr_t Array = ObjectArray();
    const int32_t Count = Array ? ObjectCount(Array) : 0;
    if (Count <= 0 || Count >= (64 << 20)) return 0;
    size_t Open = 0;
    for (const auto& W : Wanted) Open += W.second ? 0 : 1;
    int Found = 0;
    std::unordered_set<uintptr_t> Seen;
    std::string Name;
    for (int32_t I = 0; I < Count && Open; ++I) {
        const uintptr_t Object = ObjectAtIndex(Array, I);
        if (!LooksLikePointer(Object) || !IsFunctionObject(Object)) continue;
        const uintptr_t Outer = Read<uintptr_t>(Object + Cfg.OffOuter);
        if (!LooksLikePointer(Outer) || !Seen.insert(Outer).second || !ObjectName(Outer, Name)) continue;
        auto It = Wanted.find(Name);
        if (It == Wanted.end() || It->second) continue;
        It->second = Outer;
        --Open;
        ++Found;
    }
    return Found;
}

// UFunction "Wanted" der Klasse (eigene Children, sonst die der Oberklassen), 0 = nicht gefunden. Nur Worker.
uintptr_t FindClassFunction(uintptr_t Class, const std::string& Wanted) {
    std::string Name;
    for (int Depth = 0; Depth < 16 && LooksLikePointer(Class); ++Depth) {
        uintptr_t Child = Read<uintptr_t>(Class + OffChildren);
        for (int Count = 0; Count < 20000 && LooksLikePointer(Child); ++Count) {
            if (IsFunctionObject(Child) && ObjectName(Child, Name) && Name == Wanted) return Child;
            Child = Read<uintptr_t>(Child + OffFieldNext);
        }
        Class = Read<uintptr_t>(Class + Cfg.OffSuper);
    }
    return 0;
}

// Liste lesen und aufloesen (BP-Klassen laden erst mit der Welt, darum Neusuche alle 30 s, solange etwas fehlt;
// geladene alle 10 s gegen Entladen pruefen). Zeilen "+ Klasse", "- Klasse", Runde 9 auch "+/- Klasse.Funktion".
void ResolveN6Classes() {
    std::string Text = ReadText(ModDir + L"netcore_n6.txt");
    if (Text.empty()) Text = DefaultN6List;
    bool Changed = false;
    if (Text != ListedSource) {
        ListedSource = Text;
        Listed.clear();
        for (const std::string& Line : SplitLines(Text)) {
            if (Line.size() < 3 || (Line[0] != '+' && Line[0] != '-')) continue;
            char Name[128] = {};
            if (sscanf(Line.c_str() + 1, "%127s", Name) != 1) continue;
            ListedClass Entry;
            Entry.White = Line[0] == '+';
            const std::string Full = Name;
            const size_t Dot = Full.find('.');
            if (Dot == std::string::npos) {
                Entry.Name = Full;
            } else if (Dot && Dot + 1 < Full.size() && Full.find('.', Dot + 1) == std::string::npos) {
                Entry.Name = Full.substr(0, Dot);
                Entry.Func = Full.substr(Dot + 1);
            } else {
                LogF("N6: Eintrag '%s' ungueltig (Klasse oder Klasse.Funktion erwartet), ignoriert", Name);
                continue;
            }
            Listed.push_back(Entry);
        }
        LastClassScan = 0;
        Changed = true;
    }
    bool Missing = false;
    std::string Name;
    for (ListedClass& Entry : Listed) {
        if (Entry.Class && (!IsLiveObject(Entry.Class) || !ObjectName(Entry.Class, Name) || Name != Entry.Name)) {
            Entry.Class = Entry.Function = 0;
            Entry.NoFunc = false;
            Changed = true;
        }
        if (Entry.Function && (!IsLiveObject(Entry.Function) || !ObjectName(Entry.Function, Name) || Name != Entry.Func)) {
            Entry.Function = 0;
            Changed = true;
        }
        if (!Entry.Class) Missing = true;
    }
    const uint64_t Now = GetTickCount64();
    const uintptr_t Array = ObjectArray();
    const int32_t Count = Array ? ObjectCount(Array) : 0;
    if (Missing && Count > 0 && Count < (64 << 20) && (!LastClassScan || Now - LastClassScan >= 30000)) {
        LastClassScan = Now;
        std::unordered_map<std::string, uintptr_t> Wanted;
        for (const ListedClass& Entry : Listed) if (!Entry.Class) Wanted[Entry.Name] = 0;
        if (ScanClassesByName(Wanted) > 0) {
            for (ListedClass& Entry : Listed) {
                auto It = Entry.Class ? Wanted.end() : Wanted.find(Entry.Name);
                if (It == Wanted.end() || !It->second) continue;
                Entry.Class = It->second;
                Changed = true;
            }
        }
    }
    // Funktions-Eintraege: die UFunction in der gefundenen Klasse (oder einer Oberklasse) per Namen
    for (ListedClass& Entry : Listed) {
        if (Entry.Func.empty() || !Entry.Class || Entry.Function || Entry.NoFunc) continue;
        Entry.Function = FindClassFunction(Entry.Class, Entry.Func);
        if (Entry.Function) {
            Changed = true;
        } else {
            Entry.NoFunc = true;
            LogF("N6: Funktion %s.%s nicht gefunden, Eintrag wirkungslos", Entry.Name.c_str(), Entry.Func.c_str());
        }
    }
    if (Changed || !ActiveLists.load()) PublishClassLists();
}

// INV-15 (drop_outer): FName von JigMP_OnRequestDropItem einmal suchen. Alle Kisten/Figuren/Autos implementieren die
// Schnittstelle BP_JigMPComponentInterface_C unter demselben Namen; Rueckfall: zwei Kistenklassen. Nur Host mit
// drop_outer=1, Neusuche alle 30 s bis gefunden (FNames bleiben fuer die ganze Sitzung gueltig).
uint64_t LastDropScan = 0;

void ResolveDropName() {
    if (DropFName.load() || !DropOuterOpt.load() || NetModeOpt.load() != NetHost) return;
    const uint64_t Now = GetTickCount64();
    if (LastDropScan && Now - LastDropScan < 30000) return;
    LastDropScan = Now;
    static const char* const Classes[] = {"BP_JigMPComponentInterface_C", "Container_DeadPlayerLoot_C", "BP_LootContainer_C"};
    std::unordered_map<std::string, uintptr_t> Wanted;
    for (const char* Name : Classes) Wanted[Name] = 0;
    ScanClassesByName(Wanted);
    for (const char* Name : Classes) {
        const uintptr_t Func = FindClassFunction(Wanted[Name], "JigMP_OnRequestDropItem");
        const uint64_t FName = Func ? Read<uint64_t>(Func + OffObjectName) : 0;
        if (!FName) continue;
        DropFName.store(FName);
        LogF("drop_outer: JigMP_OnRequestDropItem gefunden (%s), Ablegen aus fremden Kisten geht an den anfragenden Spieler",
             Name);
        return;
    }
    static bool Logged = false;
    if (!Logged) Log("drop_outer: JigMP_OnRequestDropItem noch nicht gefunden (Klassen laden mit der Welt), Neusuche alle 30 s");
    Logged = true;
}

const char* VerdictText(int Value) {
    switch (Value) {
    case VerdictWhite: return "weiss";
    case VerdictBlack: return "gesperrt";
    case VerdictFunc: return "Funktion";
    case VerdictFuncNoLoc: return "Funktion ohne Ort";
    default: return "-";
    }
}

void LogN6Diag() {
    struct Row {
        uint32_t Count;
        uintptr_t Class, Func;
        int Verdict;
    };
    std::vector<Row> Rows;
    for (DiagSlot& Slot : DiagTable) {
        const uint32_t Count = Slot.Count.exchange(0);
        const uintptr_t Class = Slot.Class.load();
        if (Count && Class) Rows.push_back({Count, Class, Slot.Func.load(), Slot.Verdict.load()});
        Slot.Class.store(0);
        Slot.Func.store(0);
        Slot.Key.store(0);
    }
    if (Rows.empty()) return;
    std::sort(Rows.begin(), Rows.end(), [](const Row& A, const Row& B) { return A.Count > B.Count; });
    uint64_t Total = 0;
    for (const Row& R : Rows) Total += R.Count;
    LogF("N6 diag: %llu unaufgeloeste Spieler-0-Aufrufe in 10 s, %u Aufrufer (Ueberlauf %llu)",
         static_cast<unsigned long long>(Total), static_cast<unsigned>(Rows.size()),
         static_cast<unsigned long long>(DiagOverflow.exchange(0)));
    std::string Class, Func;
    for (size_t I = 0; I < Rows.size() && I < 8; ++I) {
        if (!IsLiveObject(Rows[I].Class) || !ObjectName(Rows[I].Class, Class)) Class = "?";
        if (!IsLiveObject(Rows[I].Func) || !ObjectName(Rows[I].Func, Func)) Func = "?";
        LogF("N6 diag:   %u x %s.%s (%s)", Rows[I].Count, Class.c_str(), Func.c_str(), VerdictText(Rows[I].Verdict));
    }
}

// ---------------------------------------------------------------------------------------------------------
// KDump: Lua schreibt netcore_kdump_req.txt ("KDUMP <seq> <ordner>", dann "C <klasse hex> <pfad>" oder
// "ALL <paket-praefix>"), hier entsteht pro Klasse <ordner>\<Klasse>.kdis, dazu netflags.tsv und index.tsv,
// am Ende netcore_kdump_done.txt "DONE <seq> classes= funcs= bytes= errors=".

// Adresse hinter "<Schluessel> ... 0x" aus der letzten passenden Zeile des UE4SS-Logs
uintptr_t FindLogAddress(const std::string& Text, const char* Key) {
    size_t At = Text.rfind(Key);
    if (At == std::string::npos) return 0;
    size_t LineEnd = Text.find('\n', At);
    size_t Hex = Text.find("0x", At);
    if (Hex == std::string::npos || (LineEnd != std::string::npos && Hex > LineEnd)) return 0;
    return static_cast<uintptr_t>(strtoull(Text.c_str() + Hex + 2, nullptr, 16));
}

// FName::ToString und GUObjectArray aus dem UE4SS-Log dieser Sitzung
bool LoadUe4ssLog() {
    if (NameToStringFn) return true;
    std::string Text = ReadText(ModDir + L"..\\..\\UE4SS.log");
    if (Text.empty()) {
        Log("UE4SS.log nicht lesbar");
        return false;
    }
    uintptr_t Array = FindLogAddress(Text, "Found GUObjectArray");
    if (LooksLikePointer(Array) && !LogObjectArray.load()) LogObjectArray.store(Array);
    uintptr_t Natives = FindLogAddress(Text, "Found GNatives");
    if (!GNativesAddr && Natives >= ImageBase && Natives < ImageEnd && !(Natives & 7)) GNativesAddr = Natives;
    uintptr_t ToString = FindLogAddress(Text, "Found FName::ToString");
    if (ToString < ImageBase || ToString >= ImageEnd) {
        LogF("FName::ToString %llx nicht im Spiel-Image (UE4SS.log)", static_cast<unsigned long long>(ToString));
        return false;
    }
    NameToStringFn = ToString;
    LogF("UE4SS.log: FName::ToString %llx, GUObjectArray %llx", static_cast<unsigned long long>(ToString),
         static_cast<unsigned long long>(Array));
    return true;
}

void CreateDirectories(const std::wstring& Dir) {
    for (size_t I = 3; I <= Dir.size(); ++I) {
        if (I == Dir.size() || Dir[I] == L'\\' || Dir[I] == L'/') CreateDirectoryW(Dir.substr(0, I).c_str(), nullptr);
    }
}

std::string FunctionFlagNames(uint32_t Flags) {
    static const struct { uint32_t Bit; const char* Name; } Names[] = {
        {0x1, "Final"}, {0x2, "RequiredAPI"}, {0x4, "BlueprintAuthorityOnly"}, {0x8, "BlueprintCosmetic"},
        {0x40, "Net"}, {0x80, "NetReliable"}, {0x100, "NetRequest"}, {0x200, "Exec"}, {0x400, "Native"},
        {0x800, "Event"}, {0x1000, "NetResponse"}, {0x2000, "Static"}, {0x4000, "NetMulticast"},
        {0x8000, "UbergraphFunction"}, {0x10000, "MulticastDelegate"}, {0x20000, "Public"}, {0x40000, "Private"},
        {0x80000, "Protected"}, {0x100000, "Delegate"}, {0x200000, "NetServer"}, {0x400000, "HasOutParms"},
        {0x800000, "HasDefaults"}, {0x1000000, "NetClient"}, {0x2000000, "DLLImport"},
        {0x4000000, "BlueprintCallable"}, {0x8000000, "BlueprintEvent"}, {0x10000000, "BlueprintPure"},
        {0x20000000, "EditorOnly"}, {0x40000000, "Const"}, {0x80000000u, "NetValidate"},
    };
    std::string Out;
    for (const auto& N : Names) {
        if (!(Flags & N.Bit)) continue;
        if (!Out.empty()) Out += ',';
        Out += N.Name;
    }
    return Out;
}

struct KDumpJob {
    std::wstring OutDir;  // mit abschliessendem '\'
    FILE* Flags = nullptr;
    FILE* Index = nullptr;
    FILE* Props = nullptr;  // props.tsv: Klasse, Variable, Typ, PropertyFlags, Offset, RepNotify
    int Classes = 0, Funcs = 0, Errors = 0;
    unsigned long long Bytes = 0;
    // Kalibrierung: BP_JigComponent_C:GetDurability (UE 5.6; in 5.3 BP_JigMultiplayer_C, Bytecode identisch:
    // 921 Bytes, bei 674 EX_DoubleConst)
    bool CalibSeen = false, CalibBoundary = false;
    int CalibSize = -1, CalibByte = -1;
};

void DumpFunction(uintptr_t Func, const std::string& ClassShort, std::string& Out, KDumpJob& Job) {
    std::string Name;
    uint32_t Flags = 0;
    uint8_t NumParms = 0;
    uint16_t ParmsSize = 0, ReturnOffset = 0;
    uintptr_t Data = 0;
    int32_t Num = 0;
    const uintptr_t ScriptArray = Func + (Cfg.OffScript ? Cfg.OffScript : 0x60);
    bool Readable = ObjectName(Func, Name) && TryRead(Func + Cfg.OffFunctionFlags, Flags) &&
                    TryRead(Func + Cfg.OffNumParms, NumParms) && TryRead(Func + Cfg.OffParmsSize, ParmsSize) &&
                    TryRead(Func + Cfg.OffReturnValue, ReturnOffset) && TryRead(ScriptArray, Data) &&
                    TryRead(ScriptArray + 8, Num) && Num >= 0 && Num <= (16 << 20) && (Num == 0 || Data);
    std::vector<uint8_t> Script;
    if (Readable && Num > 0) {
        Script.resize(static_cast<size_t>(Num));
        Readable = SafeCopy(Script.data(), Data, Script.size());
    }
    if (Name.empty()) Name = "?";
    char Head[256];
    snprintf(Head, sizeof(Head), "FUNC %s FLAGS 0x%08x PARMS %u SIZE %u RET %u SCRIPT %d\n", Name.c_str(), Flags,
             NumParms, ParmsSize, ReturnOffset, Readable ? Num : 0);
    Out += Head;
    bool Abort = !Readable;
    if (Readable) {
        std::vector<std::string> Lines;
        KismetWalker Walker{Script.data(), Script.size(), &Lines};
        for (size_t Pos = 0; Pos < Script.size(); ) {
            Pos = Walker.Expr(Pos, 0);
            if (Pos == BadPos) {
                Abort = true;
                break;
            }
        }
        bool Boundary = false;
        for (const std::string& Line : Lines) {
            Out += Line;
            Out += '\n';
            if (!Line.compare(0, 7, "  02a2 ")) Boundary = true;
        }
        if ((ClassShort == "BP_JigComponent_C" || ClassShort == "BP_JigMultiplayer_C") && Name == "GetDurability") {
            Job.CalibSeen = true;
            Job.CalibSize = Num;
            Job.CalibByte = Script.size() > 674 ? Script[674] : -1;
            Job.CalibBoundary = Boundary && !Abort;
        }
    }
    if (Abort) {
        Out += "!ABORT\n";
        ++Job.Errors;
    }
    Out += "ENDFUNC\n";
    ++Job.Funcs;
    if (Readable) Job.Bytes += static_cast<unsigned long long>(Num);
    if (Job.Flags)
        fprintf(Job.Flags, "%s\t%s\t0x%08x\t%s\n", ClassShort.c_str(), Name.c_str(), Flags, FunctionFlagNames(Flags).c_str());
    if (Job.Index) fprintf(Job.Index, "%s\t%s\t%d\t%u\n", ClassShort.c_str(), Name.c_str(), Readable ? Num : 0, ParmsSize);
}

// Eigene Variablen der Klasse (ChildProperties, FField-Kette): Name, Typ, Flags (CPF_Net = 0x20), Offset, RepNotify.
// UE 5.3 laut UE4SS.log: FField::Next 0x18, NamePrivate 0x20, FProperty::ElementSize 0x34, PropertyFlags 0x38,
// Offset_Internal 0x44, RepNotifyFunc 0x68.
void DumpProperties(uintptr_t Struct, const std::string& ClassShort, std::string& Out, KDumpJob& Job) {
    uintptr_t Field = 0;
    if (!TryRead(Struct + 0x50, Field)) return;
    for (int Count = 0; Count < 5000 && LooksLikePointer(Field); ++Count) {
        uintptr_t FieldClass = 0;
        uint64_t Name = 0, TypeName = 0, Flags = 0, RepNotify = 0;
        int32_t Offset = 0, Size = 0;
        std::string PropName, TypeText = "?", RepText = "-";
        if (!TryRead(Field + 0x20, Name) || !NameText(Name, PropName)) break;
        if (TryRead(Field + 0x08, FieldClass) && LooksLikePointer(FieldClass) && TryRead(FieldClass, TypeName))
            NameText(TypeName, TypeText);
        TryRead(Field + 0x38, Flags);
        TryRead(Field + 0x44, Offset);
        TryRead(Field + 0x34, Size);
        if (TryRead(Field + 0x68, RepNotify) && static_cast<uint32_t>(RepNotify) && !NameText(RepNotify, RepText)) RepText = "?";
        if (RepText.empty() || RepText == "None") RepText = "-";
        char Line[160];
        snprintf(Line, sizeof(Line), " FLAGS 0x%016llX OFF 0x%X SIZE %d REP ", static_cast<unsigned long long>(Flags), Offset, Size);
        Out += "PROP " + PropName + " " + TypeText + Line + RepText + "\n";
        if (Job.Props)
            fprintf(Job.Props, "%s\t%s\t%s\t0x%016llX\t0x%X\t%s\n", ClassShort.c_str(), PropName.c_str(), TypeText.c_str(),
                    static_cast<unsigned long long>(Flags), Offset, RepText.c_str());
        if (!TryRead(Field + 0x18, Field)) break;
    }
}

void DumpClass(uintptr_t Class, KDumpJob& Job) {
    std::string Path, Short, Super = "-";
    uintptr_t SuperClass = 0;
    if (!ObjectPath(Class, Path) || !ObjectName(Class, Short) || !TryRead(Class + Cfg.OffSuper, SuperClass) ||
        (SuperClass && !ObjectPath(SuperClass, Super))) {
        LogF("KDump: Klasse %llx nicht lesbar", static_cast<unsigned long long>(Class));
        ++Job.Errors;
        return;
    }
    std::string Out = "#KDUMP 1\nCLASS " + Path + " SUPER " + Super + "\n";
    DumpProperties(Class, Short, Out, Job);
    uintptr_t Child = Read<uintptr_t>(Class + OffChildren);
    for (int Count = 0; Count < 20000 && LooksLikePointer(Child); ++Count) {
        if (IsFunctionObject(Child)) DumpFunction(Child, Short, Out, Job);
        Child = Read<uintptr_t>(Child + OffFieldNext);
    }
    std::string File = Short;
    for (char& C : File) if (strchr("\\/:*?\"<>|", C) || static_cast<unsigned char>(C) < 0x20) C = '_';
    if (!WriteText(Job.OutDir + FromUtf8(File) + L".kdis", Out, true)) ++Job.Errors;
    ++Job.Classes;
}

// "C <hex> <pfad>": Adresse muss leben und der Name zum Pfad passen
void DumpRequestedClass(const std::string& Line, KDumpJob& Job) {
    char* End = nullptr;
    uintptr_t Class = static_cast<uintptr_t>(strtoull(Line.c_str() + 2, &End, 16));
    std::string Path = End ? End : "";
    while (!Path.empty() && Path[0] == ' ') Path.erase(0, 1);
    bool Alive = ObjectArray() ? IsLiveObject(Class) : LooksLikePointer(Class) && IsReadable(Class, 0x50);
    std::string Short;
    if (!Alive || !ObjectName(Class, Short)) {
        LogF("KDump: Klasse %s (%llx) lebt nicht", Path.c_str(), static_cast<unsigned long long>(Class));
        ++Job.Errors;
        return;
    }
    size_t Dot = Path.find_last_of(".:");
    std::string Expected = Dot == std::string::npos ? Path : Path.substr(Dot + 1);
    if (!Expected.empty() && Expected != Short) {
        LogF("KDump: %llx ist %s, nicht %s", static_cast<unsigned long long>(Class), Short.c_str(), Path.c_str());
        ++Job.Errors;
        return;
    }
    DumpClass(Class, Job);
}

// "ALL <praefix>": alle UFunctions in GUObjectArray, deren Paket mit dem Praefix beginnt, nach Klasse
void DumpAllWithPrefix(const std::string& Prefix, KDumpJob& Job) {
    uintptr_t Array = ObjectArray();
    int32_t Count = Array ? ObjectCount(Array) : 0;
    if (Count <= 0 || Count > (64 << 20)) {
        Log("KDump: GUObjectArray fehlt");
        ++Job.Errors;
        return;
    }
    std::vector<uintptr_t> Classes;
    std::unordered_set<uintptr_t> Decided;               // schon gepruefte Outer
    std::unordered_map<uintptr_t, bool> PackageMatches;
    std::string Name;
    for (int32_t I = 0; I < Count; ++I) {
        uintptr_t Object = ObjectAtIndex(Array, I);
        if (!LooksLikePointer(Object) || !IsFunctionObject(Object)) continue;
        uintptr_t Outer = Read<uintptr_t>(Object + Cfg.OffOuter);
        if (!LooksLikePointer(Outer) || !Decided.insert(Outer).second) continue;
        if (!Read<uintptr_t>(Outer + Cfg.OffOuter)) continue;  // Delegat-Signatur direkt im Paket
        uintptr_t Package = Outer;
        for (int Depth = 0; Depth < 32; ++Depth) {
            uintptr_t Next = Read<uintptr_t>(Package + Cfg.OffOuter);
            if (!LooksLikePointer(Next)) break;
            Package = Next;
        }
        auto Found = PackageMatches.find(Package);
        bool Match;
        if (Found != PackageMatches.end()) {
            Match = Found->second;
        } else {
            Match = ObjectName(Package, Name) && !Name.compare(0, Prefix.size(), Prefix);
            PackageMatches.emplace(Package, Match);
        }
        if (Match) Classes.push_back(Outer);
    }
    LogF("KDump: %u Klassen unter %s", static_cast<unsigned>(Classes.size()), Prefix.c_str());
    for (uintptr_t Class : Classes) DumpClass(Class, Job);
}

void HandleKDumpRequest() {
    const std::wstring Req = ModDir + L"netcore_kdump_req.txt";
    std::string Text = ReadText(Req);
    if (Text.empty()) return;
    DeleteFileW(Req.c_str());
    std::vector<std::string> Lines;
    for (size_t Start = 0; Start < Text.size(); ) {
        size_t End = Text.find('\n', Start);
        if (End == std::string::npos) End = Text.size();
        std::string Line = Text.substr(Start, End - Start);
        while (!Line.empty() && (Line.back() == '\r' || Line.back() == ' ' || Line.back() == '\t')) Line.pop_back();
        Lines.push_back(Line);
        Start = End + 1;
    }
    long long Seq = 0;
    int Used = 0;
    if (Lines.empty() || sscanf(Lines[0].c_str(), "KDUMP %lld %n", &Seq, &Used) != 1 || !Used) {
        Log("KDump: ungueltige Anforderung");
        return;
    }
    std::string OutDirText = Lines[0].substr(static_cast<size_t>(Used));  // Rest der Zeile, darf Leerzeichen enthalten
    KDumpJob Job;
    if (!OutDirText.empty() && LoadUe4ssLog()) {
        Job.OutDir = FromUtf8(OutDirText);
        bool Absolute = Job.OutDir.size() > 2 && (Job.OutDir[1] == L':' || (Job.OutDir[0] == L'\\' && Job.OutDir[1] == L'\\'));
        if (!Absolute) Job.OutDir = ModDir + Job.OutDir;
        if (Job.OutDir.back() != L'\\' && Job.OutDir.back() != L'/') Job.OutDir += L'\\';
        CreateDirectories(Job.OutDir);
        Job.Flags = _wfopen((Job.OutDir + L"netflags.tsv").c_str(), L"ab");
        Job.Index = _wfopen((Job.OutDir + L"index.tsv").c_str(), L"ab");
        Job.Props = _wfopen((Job.OutDir + L"props.tsv").c_str(), L"ab");
        for (size_t I = 1; I < Lines.size(); ++I) {
            const std::string& Line = Lines[I];
            if (!Line.compare(0, 2, "C ")) {
                DumpRequestedClass(Line, Job);
            } else if (!Line.compare(0, 4, "ALL ")) {
                std::string Prefix = Line.substr(4);
                while (!Prefix.empty() && Prefix[0] == ' ') Prefix.erase(0, 1);
                DumpAllWithPrefix(Prefix, Job);
            } else if (!Line.empty()) {
                LogF("KDump: unbekannte Zeile '%s'", Line.c_str());
                ++Job.Errors;
            }
        }
        if (Job.Flags) fclose(Job.Flags);
        if (Job.Index) fclose(Job.Index);
        if (Job.Props) fclose(Job.Props);
    } else {
        Log(OutDirText.empty() ? "KDump: Ausgabeordner fehlt" : "KDump: FName::ToString unbekannt, kein Dump");
        ++Job.Errors;
    }
    if (Text.find("BP_JigComponent_C") != std::string::npos || Text.find("BP_JigMultiplayer_C") != std::string::npos ||
        Job.CalibSeen) {
        if (!Job.CalibSeen)
            Log("KDump Kalibrierung FEHLER (GetDurability nicht gefunden)");
        else if (Job.CalibSize == 921 && Job.CalibByte == 0x37 && Job.CalibBoundary)
            Log("KDump Kalibrierung OK");
        else
            LogF("KDump Kalibrierung FEHLER (Script %d Bytes, Byte 674 = 0x%02x, Ausdruck bei 674: %s)", Job.CalibSize,
                 Job.CalibByte & 0xFF, Job.CalibBoundary ? "ja" : "nein");
    }
    char Done[160];
    snprintf(Done, sizeof(Done), "DONE %lld classes=%d funcs=%d bytes=%llu errors=%d\n", Seq, Job.Classes, Job.Funcs,
             Job.Bytes, Job.Errors);
    WriteText(ModDir + L"netcore_kdump_done.txt", Done, true);
    Done[strlen(Done) - 1] = 0;
    LogF("KDump %s", Done);
}

DWORD WINAPI Worker(LPVOID) {
    DeleteFileW((ModDir + L"netcore_events.txt").c_str());  // Ereignisse einer frueheren Sitzung nie liefern
    DeleteFileW((ModDir + L"netcore_status.txt").c_str());
    DeleteFileW((ModDir + L"netcore_watchinfo.txt").c_str());
    // Warten, bis der Lua-Mod die Adressen geschrieben hat.
    for (int Tries = 0; Tries < 600; ++Tries) {
        if (ParseConfig() && ConfigComplete()) break;
        Sleep(500);
    }
    LoadUe4ssLog();
    const bool Hooked = ConfigComplete();
    if (Hooked) {
        InstallHooks();
        Log("bereit");
    } else {
        Log("netcore.cfg unvollstaendig, Hook nicht aktiv (KDump laeuft)");
    }

    // Takt 100 ms: Ereignisse (N4b) jeden Takt, Dateien alle 500 ms, Statistik/N6-Klassen alle 10 s.
    // KDump laeuft im selben Thread (FName-Cache nur hier); waehrenddessen puffert der Ring (4096).
    uint64_t LastReported = 0, LastSkipped = 0, LastNearest = 0, LastEvents = 0, LastDenied = 0, LastPvpPassed = 0;
    uint64_t LastDrops = 0;
    for (uint64_t Tick = 0;; ++Tick) {
        FlushEvents();
        CheckObserverFaults();
        if (Tick % 2 == 0) {  // Sperrliste alle 200 ms, Pruefung auf entladene Objekte jede Sekunde
            ProcessDenyFile(Tick % 10 == 0);
            LogDenyHits();
        }
        if (Tick % 5 == 0) {
            ProcessOptsFile();
            ResolvePawnPlayerState();  // remote=1 (einmalig, vor WriteStatus: feat_remote)
            ProcessAlliesFile(Tick % 10 == 0);
            ProcessWatchFile(Tick % 10 == 0);
            ProcessPlayersFile();
            UpdateObserverState();
            KeepWatchInfo();
            WriteStatus();
            if (Hooked) {
                ProcessPatchFile();
                WriteStatus();  // Patch-Zustand "-1" sofort melden (schreibt nur bei Aenderung)
                bool Want = ReadEnabledFlag();
                if (Want != Enabled.load()) {
                    Enabled.store(Want);
                    Log(Want ? "aktiv (Multiplayer)" : "inaktiv (Einzelspieler)");
                }
            }
            HandleKDumpRequest();
        }
        if (Tick % 100 == 0) {
            if (Hooked) {
                uint64_t Count = Redirects.load();
                if (Count != LastReported) {
                    LogF("%llu Aufrufe umgeleitet", static_cast<unsigned long long>(Count));
                    LastReported = Count;
                }
                uint64_t Nearest = NearestRedirects.load();
                if (Nearest != LastNearest) {
                    LogF("N6: %llu Aufrufe auf den naechsten Gast umgeleitet", static_cast<unsigned long long>(Nearest));
                    LastNearest = Nearest;
                }
                if (AiNearest.load() && Enabled.load() && SharedGuests.Count > 0) {
                    ResolveN6Classes();
                    if (AiNearest.load() == 2) LogN6Diag();
                }
                if (Enabled.load()) ResolveDropName();  // INV-15, nur Host mit drop_outer=1
                const uint64_t Drops = DropRedirects.load();
                if (Drops != LastDrops) {
                    LogF("drop_outer: %llu Ablagen dem anfragenden Spieler zugeordnet", static_cast<unsigned long long>(Drops));
                    LastDrops = Drops;
                }
            }
            uint64_t Events = ObsEvents.load();
            if (Events != LastEvents) {
                LogF("Beobachter: %llu Ereignisse (%llu beim Eintritt), %llu verworfen, %llu unterdrueckt, %llu nicht "
                     "uebersprungen, ff %llu, sd %llu",
                     static_cast<unsigned long long>(Events), static_cast<unsigned long long>(ObsEntryEvents.load()),
                     static_cast<unsigned long long>(ObsDropped.load()),
                     static_cast<unsigned long long>(ObsSuppressed.load()),
                     static_cast<unsigned long long>(ObsSkipFailed.load()),
                     static_cast<unsigned long long>(ObsFfBlocked.load()),
                     static_cast<unsigned long long>(ObsDistances.load()));
                LastEvents = Events;
            }
            const uint64_t Denied = DenyBlocked.load(), PvpPassed = ObsFfPvpPassed.load();
            if (Denied != LastDenied || PvpPassed != LastPvpPassed) {
                LogF("Sperrliste: %llu Aufrufe verworfen; pvp: %llu Spielertreffer durchgelassen (kein gemeinsamer Clan)",
                     static_cast<unsigned long long>(Denied), static_cast<unsigned long long>(PvpPassed));
                LastDenied = Denied;
                LastPvpPassed = PvpPassed;
            }
            FreeRetired(false);
        }
        if (Hooked && Tick % 600 == 0) {  // hoechstens einmal pro Minute
            uint64_t Skipped = SkippedRedirects.load();
            if (Skipped != LastSkipped) {
                LogF("%llu Aufrufe mit PlayerIndex != 0 nicht umgeleitet (index_filter)",
                     static_cast<unsigned long long>(Skipped - LastSkipped));
                LastSkipped = Skipped;
            }
        }
        Sleep(100);
    }
}

// ---------------------------------------------------------------------------------------------------------
// Serverliste: Der Lua-Mod schreibt Auftraege als Dateien neben die DLL, dieser Thread erledigt sie (ohne
// Konsolenfenster, anders als curl/ping per io.popen):
//   netcore_list_req.txt  URL der Master-Liste      -> netcore_list.txt  "STATUS <code>" + Antwort
//   netcore_ping_req.txt  Zeilen "id|adresse"       -> netcore_ping.txt  Zeilen "id|ms" (-1 = keine Antwort)
// Die Adressen kommen verschleiert (Base64 von "host:port" XOR ADDRESS_CODE, wie die Master-Liste) und werden
// nur hier im Speicher entschluesselt: Im Klartext stehen sie in keiner Datei und keinem Log.
const char ADDRESS_CODE[] = "LastSignal-1";

std::string HttpGet(const std::string& Url, int& Status) {
    Status = 0;
    std::wstring WUrl(Url.begin(), Url.end());
    wchar_t Host[256] = {}, Path[2048] = {};
    URL_COMPONENTS Parts{};
    Parts.dwStructSize = sizeof(Parts);
    Parts.lpszHostName = Host;
    Parts.dwHostNameLength = 255;
    Parts.lpszUrlPath = Path;
    Parts.dwUrlPathLength = 2047;
    if (!WinHttpCrackUrl(WUrl.c_str(), 0, 0, &Parts)) return "";
    std::string Body;
    HINTERNET Session = WinHttpOpen(L"LastSignal/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
    if (!Session) return "";
    WinHttpSetTimeouts(Session, 3000, 3000, 5000, 5000);
    HINTERNET Connection = WinHttpConnect(Session, Host, Parts.nPort, 0);
    HINTERNET Request = Connection ? WinHttpOpenRequest(Connection, L"GET", Path, nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, Parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0) : nullptr;
    if (Request && WinHttpSendRequest(Request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
        && WinHttpReceiveResponse(Request, nullptr)) {
        DWORD Code = 0, Size = sizeof(Code);
        WinHttpQueryHeaders(Request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                            &Code, &Size, WINHTTP_NO_HEADER_INDEX);
        Status = static_cast<int>(Code);
        char Buffer[8192];
        DWORD Received = 0;
        while (Body.size() < 512 * 1024 && WinHttpReadData(Request, Buffer, sizeof(Buffer), &Received) && Received > 0)
            Body.append(Buffer, Received);
    }
    if (Request) WinHttpCloseHandle(Request);
    if (Connection) WinHttpCloseHandle(Connection);
    WinHttpCloseHandle(Session);
    return Body;
}

std::string DecodeAddress(const std::string& Encoded) {
    static const std::string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string Bytes;
    int Bits = 0, Value = 0;
    for (char C : Encoded) {
        size_t Index = Alphabet.find(C);
        if (Index == std::string::npos) continue;   // '=' und Zeilenenden
        Value = (Value << 6) | static_cast<int>(Index);
        Bits += 6;
        if (Bits >= 8) {
            Bits -= 8;
            Bytes.push_back(static_cast<char>((Value >> Bits) & 0xFF));
        }
    }
    const size_t CodeLength = sizeof(ADDRESS_CODE) - 1;
    for (size_t I = 0; I < Bytes.size(); ++I) Bytes[I] = static_cast<char>(Bytes[I] ^ ADDRESS_CODE[I % CodeLength]);
    return Bytes;
}

// Gehoert Thread und Aufrufer gemeinsam (Refs = 2): wer zuletzt freigibt, loescht. getaddrinfo kann laenger
// als die 5 s Wartezeit blockieren - der Thread darf danach nicht in freigegebenen Speicher schreiben.
struct PingJob {
    std::string Id, Host;
    std::atomic<int> Ms{-1};
    std::atomic<int> Refs{2};
};

void ReleasePingJob(PingJob* Job) {
    if (Job->Refs.fetch_sub(1) == 1) delete Job;
}

// Bester von zwei ICMP-Pings (1 s Wartezeit je Ping)
void PingWork(PingJob* Job) {
    addrinfo Hints{};
    Hints.ai_family = AF_INET;
    addrinfo* Found = nullptr;
    if (getaddrinfo(Job->Host.c_str(), nullptr, &Hints, &Found) != 0 || !Found) return;
    IPAddr Ip = reinterpret_cast<sockaddr_in*>(Found->ai_addr)->sin_addr.S_un.S_addr;
    freeaddrinfo(Found);
    HANDLE Icmp = IcmpCreateFile();
    if (Icmp == INVALID_HANDLE_VALUE) return;
    char Data[8] = "lsping";
    char Reply[sizeof(ICMP_ECHO_REPLY) + sizeof(Data) + 16];
    for (int Try = 0; Try < 2; ++Try) {
        if (IcmpSendEcho(Icmp, Ip, Data, sizeof(Data), nullptr, Reply, sizeof(Reply), 1000) > 0) {
            auto* Echo = reinterpret_cast<PICMP_ECHO_REPLY>(Reply);
            if (Echo->Status == IP_SUCCESS) {
                int Ms = static_cast<int>(Echo->RoundTripTime);
                const int Old = Job->Ms.load();
                if (Old < 0 || Ms < Old) Job->Ms.store(Ms);
            }
        }
    }
    IcmpCloseHandle(Icmp);
}

DWORD WINAPI PingThread(LPVOID Param) {
    auto* Job = static_cast<PingJob*>(Param);
    PingWork(Job);
    ReleasePingJob(Job);
    return 0;
}

void HandleListRequest() {
    std::wstring Req = ModDir + L"netcore_list_req.txt";
    std::string Url = ReadText(Req);
    if (Url.empty()) return;
    DeleteFileW(Req.c_str());
    while (!Url.empty() && (Url.back() == '\r' || Url.back() == '\n' || Url.back() == ' ')) Url.pop_back();
    int Status = 0;
    std::string Body = HttpGet(Url + "/api/servers.txt", Status);
    WriteText(ModDir + L"netcore_list.txt", "STATUS " + std::to_string(Status) + "\n" + Body);
    LogF("Serverliste geholt: Status %d, %u Bytes", Status, static_cast<unsigned>(Body.size()));
}

void HandlePingRequest() {
    std::wstring Req = ModDir + L"netcore_ping_req.txt";
    std::string Text = ReadText(Req);
    if (Text.empty()) return;
    DeleteFileW(Req.c_str());
    std::vector<PingJob*> Jobs;
    size_t Start = 0;
    while (Start < Text.size() && Jobs.size() < 64) {
        size_t End = Text.find('\n', Start);
        if (End == std::string::npos) End = Text.size();
        std::string Line = Text.substr(Start, End - Start);
        Start = End + 1;
        size_t Bar = Line.find('|');
        if (Bar == std::string::npos) continue;
        std::string Address = DecodeAddress(Line.substr(Bar + 1));
        size_t Colon = Address.rfind(':');
        auto* Job = new PingJob();
        Job->Id = Line.substr(0, Bar);
        Job->Host = Colon == std::string::npos ? Address : Address.substr(0, Colon);
        Jobs.push_back(Job);
    }
    std::vector<HANDLE> Threads;
    for (PingJob* Job : Jobs) {
        HANDLE Thread = CreateThread(nullptr, 0, PingThread, Job, 0, nullptr);
        if (Thread) Threads.push_back(Thread);
        else Job->Refs.fetch_sub(1);  // kein Thread: nur der Aufrufer haelt den Auftrag
    }
    // Gemeinsame Frist 5 s fuer alle (nicht 5 s je Thread)
    const ULONGLONG Deadline = GetTickCount64() + 5000;
    int Late = 0;
    for (HANDLE Thread : Threads) {
        const ULONGLONG Now = GetTickCount64();
        if (WaitForSingleObject(Thread, Now < Deadline ? static_cast<DWORD>(Deadline - Now) : 0) != WAIT_OBJECT_0) ++Late;
        CloseHandle(Thread);
    }
    if (Late) LogF("Ping: %d Thread(s) nach 5 s noch aktiv - Auftraege werden vom Thread selbst freigegeben", Late);
    std::string Out;
    for (PingJob* Job : Jobs) {
        Out += Job->Id + "|" + std::to_string(Job->Ms.load()) + "\n";
        ReleasePingJob(Job);
    }
    WriteText(ModDir + L"netcore_ping.txt", Out);
}

// Steam-ID des Spielers (fuer Bans auf Servern) aus der steam_api64.dll des Spiels -> netcore_steamid.txt.
// Nur wenn das Spiel mit Steam laeuft (auf dem Server unter Wine mit -nosteam gibt es sie nicht).
bool WriteSteamId() {
    HMODULE Steam = GetModuleHandleW(L"steam_api64.dll");
    if (!Steam) return false;
    using UserFn = void* (*)();
    using IdFn = uint64_t (*)(void*);
    auto GetId = reinterpret_cast<IdFn>(GetProcAddress(Steam, "SteamAPI_ISteamUser_GetSteamID"));
    if (!GetId) return false;
    const char* Accessors[] = { "SteamAPI_SteamUser_v023", "SteamAPI_SteamUser_v022", "SteamAPI_SteamUser_v021",
                                "SteamAPI_SteamUser_v020", "SteamAPI_SteamUser_v019" };
    for (const char* Name : Accessors) {
        auto GetUser = reinterpret_cast<UserFn>(GetProcAddress(Steam, Name));
        if (!GetUser) continue;
        void* User = GetUser();
        uint64_t Id = User ? GetId(User) : 0;
        if (!Id) return false;
        WriteText(ModDir + L"netcore_steamid.txt", std::to_string(Id) + "\n", true);
        Log("Steam-ID gelesen");
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------------------
// Dienst "backup" (ls_player, guest_backup): Lua schreibt netcore_backup_req.txt mit Zeilen "seq=", "src=",
// "dst=", "keep=". Kopiert src (Ordner, sonst Datei bzw. <src>.sav) nach dst und behaelt je Slot nur die neuesten
// keep Sicherungen "<Slot>_JJJJMMTT_hhmmss". Erlaubt nur unter %LOCALAPPDATA%\SurrounDead\Saved\SaveGames\:
// src ausserhalb von LS_Backup, dst direkt in LS_Backup. Antwort netcore_backup_done.txt:
// "DONE <seq> status=ok|denied|nosrc|copyfail|toolarge|badreq files=<n> bytes=<n> removed=<n>".
// Laeuft im ListWorker-Thread (Datei-I/O, nie im Spielthread).

// Lua-Text -> UTF-16: UTF-8, sonst ANSI-Codepage (os.getenv liefert unter Windows ANSI)
std::wstring WidePath(const std::string& Text) {
    if (Text.empty()) return std::wstring();
    UINT Page = CP_UTF8;
    DWORD Flags = MB_ERR_INVALID_CHARS;
    int Size = MultiByteToWideChar(Page, Flags, Text.data(), static_cast<int>(Text.size()), nullptr, 0);
    if (Size <= 0) {
        Page = CP_ACP;
        Flags = 0;
        Size = MultiByteToWideChar(Page, Flags, Text.data(), static_cast<int>(Text.size()), nullptr, 0);
    }
    if (Size <= 0) return std::wstring();
    std::wstring Out(static_cast<size_t>(Size), L'\0');
    MultiByteToWideChar(Page, Flags, Text.data(), static_cast<int>(Text.size()), &Out[0], Size);
    return Out;
}

// Absoluter, normalisierter Pfad ohne ".."/"." und ohne abschliessenden Trenner
bool NormalPath(const std::wstring& In, std::wstring& Out) {
    if (In.empty() || In.find(L'\0') != std::wstring::npos) return false;
    wchar_t Buffer[1024];
    const DWORD N = GetFullPathNameW(In.c_str(), 1024, Buffer, nullptr);
    if (!N || N >= 1024) return false;
    Out.assign(Buffer, N);
    while (Out.size() > 3 && (Out.back() == L'\\' || Out.back() == L'/')) Out.pop_back();
    for (wchar_t& C : Out) if (C == L'/') C = L'\\';
    return true;
}

bool StartsWithNoCase(const std::wstring& Text, const std::wstring& Prefix) {
    return Text.size() >= Prefix.size() &&
           CompareStringOrdinal(Text.c_str(), static_cast<int>(Prefix.size()), Prefix.c_str(),
                                static_cast<int>(Prefix.size()), TRUE) == CSTR_EQUAL;
}

bool EqualNoCase(const std::wstring& A, const std::wstring& B) {
    return A.size() == B.size() && StartsWithNoCase(A, B);
}

struct CopyStats {
    int Files = 0;
    unsigned long long Bytes = 0;
    bool Failed = false, TooLarge = false;
};

constexpr int BackupMaxFiles = 4096;
constexpr unsigned long long BackupMaxBytes = 1ull << 30;

bool CopyOneFile(const std::wstring& From, const std::wstring& To, unsigned long long Size, CopyStats& Stats) {
    if (Stats.Files >= BackupMaxFiles || Stats.Bytes + Size > BackupMaxBytes) {
        Stats.TooLarge = true;
        return false;
    }
    if (!CopyFileW(From.c_str(), To.c_str(), FALSE)) {
        LogF("Backup: Kopieren fehlgeschlagen (%ls, Fehler %lu)", From.c_str(), static_cast<unsigned long>(GetLastError()));
        Stats.Failed = true;
        return false;
    }
    ++Stats.Files;
    Stats.Bytes += Size;
    return true;
}

// Ordner rekursiv kopieren (Verknuepfungen/Junctions werden uebersprungen, Tiefe <= 8)
void CopyTree(const std::wstring& From, const std::wstring& To, int Depth, CopyStats& Stats) {
    if (Depth > 8 || Stats.Failed || Stats.TooLarge) return;
    if (!CreateDirectoryW(To.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        LogF("Backup: Ordner %ls nicht anlegbar (Fehler %lu)", To.c_str(), static_cast<unsigned long>(GetLastError()));
        Stats.Failed = true;
        return;
    }
    WIN32_FIND_DATAW Data;
    HANDLE Find = FindFirstFileW((From + L"\\*").c_str(), &Data);
    if (Find == INVALID_HANDLE_VALUE) return;
    do {
        const std::wstring Name = Data.cFileName;
        if (Name == L"." || Name == L".." || (Data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        if (Data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            CopyTree(From + L"\\" + Name, To + L"\\" + Name, Depth + 1, Stats);
        } else {
            const unsigned long long Size = (static_cast<unsigned long long>(Data.nFileSizeHigh) << 32) | Data.nFileSizeLow;
            CopyOneFile(From + L"\\" + Name, To + L"\\" + Name, Size, Stats);
        }
    } while (!Stats.Failed && !Stats.TooLarge && FindNextFileW(Find, &Data));
    FindClose(Find);
}

// Nur innerhalb von LS_Backup aufgerufen; Junctions werden als Verknuepfung entfernt, nie durchlaufen
void DeleteTree(const std::wstring& Dir, int Depth) {
    if (Depth > 8) return;
    WIN32_FIND_DATAW Data;
    HANDLE Find = FindFirstFileW((Dir + L"\\*").c_str(), &Data);
    if (Find != INVALID_HANDLE_VALUE) {
        do {
            const std::wstring Name = Data.cFileName;
            if (Name == L"." || Name == L"..") continue;
            const std::wstring Path = Dir + L"\\" + Name;
            if ((Data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(Data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                DeleteTree(Path, Depth + 1);
            } else if (Data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                RemoveDirectoryW(Path.c_str());
            } else {
                SetFileAttributesW(Path.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(Path.c_str());
            }
        } while (FindNextFileW(Find, &Data));
        FindClose(Find);
    }
    RemoveDirectoryW(Dir.c_str());
}

// "_JJJJMMTT_hhmmss" am Ende (16 Zeichen)
bool HasStampSuffix(const std::wstring& Name) {
    if (Name.size() <= 16) return false;
    const std::wstring S = Name.substr(Name.size() - 16);
    for (size_t I = 0; I < 16; ++I) {
        const bool Sep = I == 0 || I == 9;
        if (Sep ? S[I] != L'_' : (S[I] < L'0' || S[I] > L'9')) return false;
    }
    return true;
}

// Aeltere Sicherungen desselben Slots loeschen (Namen sortieren = Zeitstempel sortieren), dst bleibt immer
int PruneBackups(const std::wstring& BackupDir, const std::wstring& DstName, int Keep) {
    if (!HasStampSuffix(DstName)) return 0;
    const std::wstring Prefix = DstName.substr(0, DstName.size() - 16);
    std::vector<std::wstring> Names;
    WIN32_FIND_DATAW Data;
    HANDLE Find = FindFirstFileW((BackupDir + L"\\*").c_str(), &Data);
    if (Find == INVALID_HANDLE_VALUE) return 0;
    do {
        const std::wstring Name = Data.cFileName;
        if (!(Data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (Data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
            continue;
        if (Name.size() == Prefix.size() + 16 && HasStampSuffix(Name) && StartsWithNoCase(Name, Prefix) &&
            !EqualNoCase(Name, DstName))
            Names.push_back(Name);
    } while (FindNextFileW(Find, &Data));
    FindClose(Find);
    std::sort(Names.begin(), Names.end(), [](const std::wstring& A, const std::wstring& B) { return A > B; });
    int Removed = 0;
    // dst zaehlt als eine der Keep Sicherungen
    for (size_t I = static_cast<size_t>(Keep > 1 ? Keep - 1 : 0); I < Names.size(); ++I) {
        DeleteTree(BackupDir + L"\\" + Names[I], 0);
        ++Removed;
    }
    return Removed;
}

void HandleBackupRequest() {
    const std::wstring Req = ModDir + L"netcore_backup_req.txt";
    if (GetFileAttributesW(Req.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    const bool Current = FileIsCurrent(Req);
    const std::string Text = ReadText(Req);
    DeleteFileW(Req.c_str());
    if (!Current) {
        Log("Backup: Anfrage aus einer frueheren Sitzung verworfen");
        return;
    }
    long long Seq = -1;
    int Keep = 5;
    std::string SrcText, DstText;
    for (const std::string& Line : SplitLines(Text)) {
        const size_t Eq = Line.find('=');
        if (Eq == std::string::npos) continue;
        const std::string Key = Line.substr(0, Eq), Value = Line.substr(Eq + 1);
        if (Key == "seq") Seq = strtoll(Value.c_str(), nullptr, 10);
        else if (Key == "src") SrcText = Value;
        else if (Key == "dst") DstText = Value;
        else if (Key == "keep") Keep = atoi(Value.c_str());
    }
    if (Keep < 1 || Keep > 50) Keep = 5;
    auto Finish = [&](const char* Status, const CopyStats& Stats, int Removed) {
        char Done[200];
        snprintf(Done, sizeof(Done), "DONE %lld status=%s files=%d bytes=%llu removed=%d\n", Seq, Status, Stats.Files,
                 Stats.Bytes, Removed);
        WriteText(ModDir + L"netcore_backup_done.txt", Done, true);
        Done[strlen(Done) - 1] = 0;
        LogF("Backup %s", Done);
    };
    CopyStats Stats;
    if (Seq < 0 || SrcText.empty() || DstText.empty()) {
        Finish("badreq", Stats, 0);
        return;
    }
    wchar_t Env[512];
    const DWORD EnvLength = GetEnvironmentVariableW(L"LOCALAPPDATA", Env, 512);
    std::wstring Root, BackupDir, Src, Dst;
    if (!EnvLength || EnvLength >= 512 || !NormalPath(std::wstring(Env, EnvLength) + L"\\SurrounDead\\Saved\\SaveGames", Root) ||
        !NormalPath(WidePath(SrcText), Src) || !NormalPath(WidePath(DstText), Dst)) {
        Finish("denied", Stats, 0);
        return;
    }
    BackupDir = Root + L"\\LS_Backup";
    const size_t Slash = Dst.find_last_of(L'\\');
    const std::wstring DstParent = Slash == std::wstring::npos ? std::wstring() : Dst.substr(0, Slash);
    const std::wstring DstName = Slash == std::wstring::npos ? std::wstring() : Dst.substr(Slash + 1);
    const bool SrcOk = StartsWithNoCase(Src, Root + L"\\") && !EqualNoCase(Src, BackupDir) &&
                       !StartsWithNoCase(Src, BackupDir + L"\\");
    const bool DstOk = EqualNoCase(DstParent, BackupDir) && !DstName.empty() && DstName != L"." && DstName != L"..";
    if (!SrcOk || !DstOk) {
        LogF("Backup: Pfad ausserhalb von SaveGames bzw. LS_Backup verweigert (src %s, dst %s)", SrcOk ? "ok" : "falsch",
             DstOk ? "ok" : "falsch");
        Finish("denied", Stats, 0);
        return;
    }
    std::wstring From = Src;
    DWORD Attributes = GetFileAttributesW(From.c_str());
    if (Attributes == INVALID_FILE_ATTRIBUTES) {
        From = Src + L".sav";
        Attributes = GetFileAttributesW(From.c_str());
    }
    if (Attributes == INVALID_FILE_ATTRIBUTES || (Attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        Finish("nosrc", Stats, 0);
        return;
    }
    CreateDirectoryW(BackupDir.c_str(), nullptr);
    if (Attributes & FILE_ATTRIBUTE_DIRECTORY) {
        CopyTree(From, Dst, 0, Stats);
    } else if (CreateDirectoryW(Dst.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS) {
        WIN32_FILE_ATTRIBUTE_DATA Data;
        const unsigned long long Size = GetFileAttributesExW(From.c_str(), GetFileExInfoStandard, &Data)
                                            ? (static_cast<unsigned long long>(Data.nFileSizeHigh) << 32) | Data.nFileSizeLow
                                            : 0;
        CopyOneFile(From, Dst + From.substr(From.find_last_of(L'\\')), Size, Stats);
    } else {
        Stats.Failed = true;
    }
    if (Stats.Failed || Stats.TooLarge) {
        Finish(Stats.TooLarge ? "toolarge" : "copyfail", Stats, 0);
        return;
    }
    Finish("ok", Stats, PruneBackups(BackupDir, DstName, Keep));
}

DWORD WINAPI ListWorker(LPVOID) {
    WSADATA Wsa;
    WSAStartup(MAKEWORD(2, 2), &Wsa);
    bool HaveSteamId = false;
    for (int Tick = 0;; ++Tick) {
        HandleBackupRequest();
        HandleListRequest();
        HandlePingRequest();
        // Steam startet erst nach der DLL: alle 3 s nachsehen, hoechstens 5 Minuten
        if (!HaveSteamId && Tick % 10 == 0 && Tick < 1000) HaveSteamId = WriteSteamId();
        Sleep(300);
    }
}

}  // namespace

BOOL WINAPI DllMain(HINSTANCE Instance, DWORD Reason, LPVOID) {
    if (Reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(Instance);

    // Nie wieder entladen: die Thunks zeigen in diese DLL.
    HMODULE Self;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&DllMain), &Self);

    wchar_t Path[MAX_PATH];
    GetModuleFileNameW(Instance, Path, MAX_PATH);
    ModDir = Path;
    ModDir = ModDir.substr(0, ModDir.find_last_of(L"\\/") + 1);

    MODULEINFO Info{};
    GetModuleInformation(GetCurrentProcess(), GetModuleHandleW(nullptr), &Info, sizeof(Info));
    ImageBase = reinterpret_cast<uintptr_t>(Info.lpBaseOfDll);
    ImageEnd = ImageBase + Info.SizeOfImage;

    InitRing();
    for (auto& Slot : VerdictCache) Slot.store(0, std::memory_order_relaxed);
    FILETIME Exit, Kernel, User;
    if (!GetProcessTimes(GetCurrentProcess(), &ProcessStart, &Exit, &Kernel, &User)) GetSystemTimeAsFileTime(&ProcessStart);
    SessionStamp = (static_cast<uint64_t>(GetCurrentProcessId()) << 32) ^ GetTickCount64();

    CloseHandle(CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr));
    CloseHandle(CreateThread(nullptr, 0, ListWorker, nullptr, 0, nullptr));
    return TRUE;
}
