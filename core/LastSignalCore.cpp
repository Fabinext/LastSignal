// LastSignalCore: nativer "Spieler 0"-Hook fuer SurrounDead-Koop.
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
// Ausserdem die Serverliste (Tab "Server Liste" im Journal), siehe ListWorker unten.
// Bauen: x86_64-w64-mingw32-clang++ -std=c++17 -O2 -D_WIN32_WINNT=0x0A00 -shared -static -s -o LastSignalCore.dll LastSignalCore.cpp
//        -lpsapi -lwinhttp -liphlpapi -lws2_32   (llvm-mingw)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <psapi.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
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
    uint32_t OffActorOwner = 0, OffPawnController = 0, OffControllerPawn = 0, OffCameraManager = 0;
    uintptr_t ObjectArray = 0;  // GUObjectArray (aus dem UE4SS-Log), 0 = Parameter-Suche aus
};

enum Kind { GetPC = 0, GetPawn = 1, GetCharacter = 2, GetCamera = 3 };

Config Cfg;
NativeFunc Original[4] = {};
std::atomic<bool> Enabled{false};
std::atomic<uint64_t> Redirects{0};
uintptr_t ImageBase = 0, ImageEnd = 0;
std::wstring ModDir;

template <typename T> T Read(uintptr_t Address) { return *reinterpret_cast<T*>(Address); }

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

bool IsReadable(uintptr_t Address, size_t Size) {
    MEMORY_BASIC_INFORMATION Info;
    if (!VirtualQuery(reinterpret_cast<void*>(Address), &Info, sizeof(Info))) return false;
    const DWORD Readable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                           PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (Info.State != MEM_COMMIT || !(Info.Protect & Readable) || (Info.Protect & (PAGE_GUARD | PAGE_NOACCESS)))
        return false;
    return Address + Size <= reinterpret_cast<uintptr_t>(Info.BaseAddress) + Info.RegionSize;
}

// Ein Parameter-Slot kann auch eine Zahl oder ein Struct sein. Nur Werte akzeptieren, die genau an
// ihrem eigenen Index in GUObjectArray stehen - dann ist es sicher ein lebendes UObject.
bool IsLiveObject(uintptr_t Candidate) {
    if (!Cfg.ObjectArray || !LooksLikePointer(Candidate) || !IsReadable(Candidate, 0x28)) return false;
    int32_t Index = Read<int32_t>(Candidate + Cfg.OffObjectIndex);
    uintptr_t Objects = Cfg.ObjectArray + 0x10;  // FUObjectArray::ObjObjects (TUObjectArray)
    int32_t Count = Read<int32_t>(Objects + 0x14);  // TUObjectArray::NumElements
    if (Index < 0 || Index >= Count) return false;
    uintptr_t Chunks = Read<uintptr_t>(Objects);  // FUObjectItem** (64k Eintraege pro Chunk)
    uintptr_t Chunk = Read<uintptr_t>(Chunks + static_cast<uintptr_t>(Index / 65536) * 8);
    if (!LooksLikePointer(Chunk)) return false;
    return Read<uintptr_t>(Chunk + static_cast<uintptr_t>(Index % 65536) * 0x18) == Candidate;  // FUObjectItem::Object
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

template <Kind K> void Hook(void* Context, void* Stack, void* Result) {
    Original[K](Context, Stack, Result);
    if (!Enabled.load(std::memory_order_relaxed) || !Stack || !Result) return;

    uintptr_t PC = ResolveFromFrames(reinterpret_cast<uintptr_t>(Stack));
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
        Redirects.fetch_add(1, std::memory_order_relaxed);
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

void Log(const char* Text) {
    FILE* File = _wfopen((ModDir + L"netcore.log").c_str(), L"a");
    if (!File) return;
    SYSTEMTIME T;
    GetLocalTime(&T);
    fprintf(File, "[%02d:%02d:%02d] %s\n", T.wHour, T.wMinute, T.wSecond, Text);
    fclose(File);
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
            {"off_script", &Cfg.OffScript},
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
    char Message[256];
    for (int I = 0; I < 4; ++I) {
        void** Slot = reinterpret_cast<void**>(Cfg.Func[I] + Cfg.OffFunc);
        uintptr_t Current = reinterpret_cast<uintptr_t>(*Slot);
        // Der Thunk muss im Spiel-Image liegen, sonst stimmt Adresse/Offset nicht (oder jemand
        // anderes hat die Funktion schon umgebogen) - dann lieber gar nichts anfassen.
        if (Current < ImageBase || Current >= ImageEnd) {
            snprintf(Message, sizeof(Message), "Funktion %d: Thunk %llx nicht im Spiel-Image, uebersprungen", I,
                     static_cast<unsigned long long>(Current));
            Log(Message);
            continue;
        }
        Original[I] = reinterpret_cast<NativeFunc>(Current);
        InterlockedExchangePointer(Slot, reinterpret_cast<void*>(HookFor(I)));
        snprintf(Message, sizeof(Message), "Funktion %d gehookt (Original %llx)", I,
                 static_cast<unsigned long long>(Current));
        Log(Message);
    }
}

// Bytecode-Patches fuer Blueprint-Funktionen, nur beim Mitspieler (Lua schreibt netcore_patch.txt).
// Zeile: <name> <UFunction hex> <offset dez> <erwartet hex> <neu hex> <1=an|0=aus>
// Geschrieben wird nur, wenn an der Stelle genau "erwartet" (bzw. beim Ausschalten "neu") steht -
// sonst passt die Spielversion nicht und es bleibt alles unveraendert. Script liegt in UStruct
// als TArray<uint8> bei off_script (UE 5.3: 0x60).
std::string LastPatchFile;

struct Bytes {
    uint8_t Data[64];
    size_t Size = 0;
};

bool ParseHex(const char* Text, Bytes& Out) {
    Out.Size = 0;
    for (size_t I = 0; Text[I] && Text[I + 1]; I += 2) {
        unsigned Byte;
        if (Out.Size >= sizeof(Out.Data) || sscanf(Text + I, "%2x", &Byte) != 1) return false;
        Out.Data[Out.Size++] = static_cast<uint8_t>(Byte);
    }
    return Out.Size > 0;
}

void ApplyPatchLine(const char* Line) {
    char Name[64], ExpectHex[128], NewHex[128], Message[320];
    unsigned long long Func;
    unsigned Offset;
    int Want;
    if (sscanf(Line, "%63s %llx %u %127s %127s %d", Name, &Func, &Offset, ExpectHex, NewHex, &Want) != 6) return;
    Bytes Expect, New;
    if (!ParseHex(ExpectHex, Expect) || !ParseHex(NewHex, New) || Expect.Size != New.Size) {
        snprintf(Message, sizeof(Message), "Patch %s: ungueltige Zeile", Name);
        Log(Message);
        return;
    }
    uintptr_t ScriptArray = static_cast<uintptr_t>(Func) + (Cfg.OffScript ? Cfg.OffScript : 0x60);
    if (!LooksLikePointer(static_cast<uintptr_t>(Func)) || !IsReadable(ScriptArray, 16)) {
        snprintf(Message, sizeof(Message), "Patch %s: Funktion %llx nicht lesbar", Name, Func);
        Log(Message);
        return;
    }
    uint8_t* Data = *reinterpret_cast<uint8_t**>(ScriptArray);
    int32_t Num = *reinterpret_cast<int32_t*>(ScriptArray + 8);
    if (!LooksLikePointer(reinterpret_cast<uintptr_t>(Data)) || Num < 0 ||
        static_cast<size_t>(Num) < Offset + Expect.Size || Num > (16 << 20) ||
        !IsReadable(reinterpret_cast<uintptr_t>(Data) + Offset, Expect.Size)) {
        snprintf(Message, sizeof(Message), "Patch %s: Script nicht gefunden (Num=%d)", Name, Num);
        Log(Message);
        return;
    }
    uint8_t* At = Data + Offset;
    const Bytes& From = Want ? Expect : New;
    const Bytes& To = Want ? New : Expect;
    if (!memcmp(At, To.Data, To.Size)) {
        snprintf(Message, sizeof(Message), "Patch %s: schon %s", Name, Want ? "aktiv" : "aus");
    } else if (!memcmp(At, From.Data, From.Size)) {
        DWORD Old;
        VirtualProtect(At, To.Size, PAGE_READWRITE, &Old);
        for (size_t I = 0; I < To.Size; ++I) if (At[I] != To.Data[I]) At[I] = To.Data[I];
        VirtualProtect(At, To.Size, Old, &Old);
        snprintf(Message, sizeof(Message), "Patch %s: %s (Script %d Bytes)", Name, Want ? "aktiviert" : "zurueckgenommen", Num);
    } else {
        snprintf(Message, sizeof(Message), "Patch %s: Bytes passen nicht zur erwarteten Spielversion, nichts geaendert", Name);
    }
    Log(Message);
}

void ProcessPatchFile() {
    FILE* File = _wfopen((ModDir + L"netcore_patch.txt").c_str(), L"r");
    if (!File) return;
    std::string Content;
    char Buffer[512];
    while (fgets(Buffer, sizeof(Buffer), File)) Content += Buffer;
    fclose(File);
    if (Content == LastPatchFile) return;
    LastPatchFile = Content;
    size_t Start = 0;
    while (Start < Content.size()) {
        size_t End = Content.find('\n', Start);
        if (End == std::string::npos) End = Content.size();
        ApplyPatchLine(Content.substr(Start, End - Start).c_str());
        Start = End + 1;
    }
}

bool ReadEnabledFlag() {
    FILE* File = _wfopen((ModDir + L"netcore_enabled.txt").c_str(), L"r");
    if (!File) return false;
    int C = fgetc(File);
    fclose(File);
    return C == '1';
}

DWORD WINAPI Worker(LPVOID) {
    // Warten, bis der Lua-Mod die Adressen geschrieben hat.
    for (int Tries = 0; Tries < 600; ++Tries) {
        if (ParseConfig() && ConfigComplete()) break;
        Sleep(500);
    }
    if (!ConfigComplete()) {
        Log("netcore.cfg unvollstaendig, Hook nicht aktiv");
        return 0;
    }
    InstallHooks();
    Log("bereit");

    uint64_t LastReported = 0;
    for (int Tick = 0;; ++Tick) {
        ProcessPatchFile();
        bool Want = ReadEnabledFlag();
        if (Want != Enabled.load()) {
            Enabled.store(Want);
            Log(Want ? "aktiv (Multiplayer)" : "inaktiv (Einzelspieler)");
        }
        if (Tick % 20 == 0) {
            uint64_t Count = Redirects.load();
            if (Count != LastReported) {
                char Message[96];
                snprintf(Message, sizeof(Message), "%llu Aufrufe umgeleitet", static_cast<unsigned long long>(Count));
                Log(Message);
                LastReported = Count;
            }
        }
        Sleep(500);
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

// Erst in eine .tmp-Datei, dann umbenennen: Lua liest nie eine halbe Datei
void WriteText(const std::wstring& Path, const std::string& Text) {
    std::wstring Tmp = Path + L".tmp";
    FILE* File = _wfopen(Tmp.c_str(), L"wb");
    if (!File) return;
    fwrite(Text.data(), 1, Text.size(), File);
    fclose(File);
    MoveFileExW(Tmp.c_str(), Path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

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
        DWORD Read = 0;
        while (Body.size() < 512 * 1024 && WinHttpReadData(Request, Buffer, sizeof(Buffer), &Read) && Read > 0)
            Body.append(Buffer, Read);
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

struct PingJob {
    std::string Id, Host;
    int Ms = -1;
};

// Bester von zwei ICMP-Pings (1 s Wartezeit je Ping)
DWORD WINAPI PingThread(LPVOID Param) {
    auto* Job = static_cast<PingJob*>(Param);
    addrinfo Hints{};
    Hints.ai_family = AF_INET;
    addrinfo* Found = nullptr;
    if (getaddrinfo(Job->Host.c_str(), nullptr, &Hints, &Found) != 0 || !Found) return 0;
    IPAddr Ip = reinterpret_cast<sockaddr_in*>(Found->ai_addr)->sin_addr.S_un.S_addr;
    freeaddrinfo(Found);
    HANDLE Icmp = IcmpCreateFile();
    if (Icmp == INVALID_HANDLE_VALUE) return 0;
    char Data[8] = "lsping";
    char Reply[sizeof(ICMP_ECHO_REPLY) + sizeof(Data) + 16];
    for (int Try = 0; Try < 2; ++Try) {
        if (IcmpSendEcho(Icmp, Ip, Data, sizeof(Data), nullptr, Reply, sizeof(Reply), 1000) > 0) {
            auto* Echo = reinterpret_cast<PICMP_ECHO_REPLY>(Reply);
            if (Echo->Status == IP_SUCCESS) {
                int Ms = static_cast<int>(Echo->RoundTripTime);
                if (Job->Ms < 0 || Ms < Job->Ms) Job->Ms = Ms;
            }
        }
    }
    IcmpCloseHandle(Icmp);
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
    char Message[96];
    snprintf(Message, sizeof(Message), "Serverliste geholt: Status %d, %u Bytes", Status, static_cast<unsigned>(Body.size()));
    Log(Message);
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
    }
    for (HANDLE Thread : Threads) {
        WaitForSingleObject(Thread, 5000);
        CloseHandle(Thread);
    }
    std::string Out;
    for (PingJob* Job : Jobs) {
        Out += Job->Id + "|" + std::to_string(Job->Ms) + "\n";
        delete Job;
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
        WriteText(ModDir + L"netcore_steamid.txt", std::to_string(Id) + "\n");
        Log("Steam-ID gelesen");
        return true;
    }
    return false;
}

DWORD WINAPI ListWorker(LPVOID) {
    WSADATA Wsa;
    WSAStartup(MAKEWORD(2, 2), &Wsa);
    bool HaveSteamId = false;
    for (int Tick = 0;; ++Tick) {
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

    CloseHandle(CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr));
    CloseHandle(CreateThread(nullptr, 0, ListWorker, nullptr, 0, nullptr));
    return TRUE;
}
