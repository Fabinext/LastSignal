-- Last Signal, Runde 5: Bauen v2 (WP11). Vertrag: _NetTest\analysis\API.md, Befund: _NetTest\analysis\findings\build.md
--   Platzieren: Gast spiegelt seinen Baumodus (b_mode) auf die Host-Kopie seiner BuildingComponent, damit der
--               spieleigene Svr_SpawnBuild beim Host die richtige Klasse spawnt. Der Host verbraucht das Item
--               (das Spiel tut es nur bei IsLocallyControlled) und antwortet b_ok.
--   Zustaende:  Tueren/Tore/Licht/Turrets/Keypad/Schloesser/Kistenname/Beacon (b_st) und Gebaeude-HP (b_hp)
--               als Keyed-State, Spaetjoiner bekommen alles mit der Vollauffrischung von ls_net.
--   Host-UI:    Umbenennen, Keypad, Kiste mit Inhalt aufheben laufen im Spiel beim Host-HUD -> b_ui an den Gast.
--   Owner:      Generator/Dusche/Brunnen setzen in SP den Owner beim Anschauen (OnBeginInteract) -> b_foc.
--               build_ownall: ALLE Buildable_MASTER_C-Kinder bekommen beim Host Owner = Gastfigur (b_foc beim Anschauen,
--               exakt im SERVER_ForwardInteract-Pre-Hook) -> Abbau/Svr_Spawn @0553 GetPlayerCharacter(0) loest ueber die
--               Owner-Kette auf den Gast auf (DLL-Umleitung) statt auf den Geist. build_ghostfix: Rueckfall, falls das Item
--               trotzdem beim Geist landet (Zaehler-Schnappschuss beim Anschauen, Vergleich nach dem Abbau).
--               build_dropown: Owner = Gast vor DropAll (Kiste/Zelt mit Inhalt) -> Inhalt faellt beim Gast.
--   Schloss:    Knacken ist lokal -> b_unlock. Bett: Spawnpunkt speichert ls_player (bed_v2), hier nur der Hinweis.
-- Runde 7 (Host, Abschnitt "Besitz, Claims, Schloesser, Raids"): Besitzer je Bau (owners.txt), Basis-Marker-Claims
--   (claim_on, claim_radius_m), Code-Schloesser (/lock /unlock /code, locks_on) ueber die DLL-Sperrliste
--   (Native.SetDeny), Raids ueber ApplyDamage-Ereignisse (raid_on, raid_mult_*), Chat /claim /unclaim /owner.
--   Exporte: Coop.Build.Chat(G, Text), Coop.Build.OwnerOf(Actor), Coop.Build.CanUse(GuestId, Actor).
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local Native = require("ls_native")
local A

local FLAG = "build_v2"
local CAP, CAP_HOOK = "build2", "build2h"
local MASTER = "Buildable_MASTER_C"
local MATCH_DIST = 40          -- uu: Schluessel -> Actor (Bauten bewegen sich nicht)
local USE_DIST = 800           -- uu: Interaktion Gast <-> Objekt (Host-Pruefung)
local BUILD_DIST = 2500        -- uu: Platzieren Gast <-> Transform (Host-Pruefung)

local P = {
    COMP = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C",
    -- UE 5.6: BP_JigMultiplayer_C -> BP_JigComponent_C (Figur-Eigenschaft heisst weiter BP_JigMultiplayer)
    JIGMP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C",
    TURRET = "/Game/SmartAI/Blueprints/AI/Components/BP_BuildableTurretAIComponent.BP_BuildableTurretAIComponent_C",
    KEYPADUI = "/Game/UI/Widgets/Other/KeypadUI.KeypadUI_C",
    LOCK = "/Game/Blueprints/MasterObjects/BP_LockPickObject.BP_LockPickObject_C",
    CONTAINER = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C",
    TENT = "/Game/Blueprints/BuildingSystem/Actors/Tents/BuildableMaster_Tent.BuildableMaster_Tent_C",
    MASTER = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C",
    GEN = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C",
    SHOWER = "/Game/Blueprints/BuildingSystem/Actors/Other/Buildable_DecontaminationShower.Buildable_DecontaminationShower_C",
    WELL = "/Game/Blueprints/BuildingSystem/Actors/Other/Buildable_WaterWell.Buildable_WaterWell_C",
    WBL = "/Script/UMG.Default__WidgetBlueprintLibrary",
    BUILDPICK = "/Game/Inventory/Items/Pickups/Buildable/BP_BuildablePickup.BP_BuildablePickup_C",
    BED = "/Game/Blueprints/BuildingSystem/Actors/Furniture/Buildable_Bed.Buildable_Bed_C",
    BAG = "/Game/Blueprints/BuildingSystem/Actors/Furniture/Buildable_SleepingBag.Buildable_SleepingBag_C",
    LOCKPICK = "/Game/Inventory/Items/DataAssets/Other/DA_Lockpick.DA_Lockpick",
    -- Minispiel-Tick @028b: JumpIfNot(GetLockpickAmount != 0) -> L_0c9a; GetLockpickAmount liest MainJigContainers
    -- (beim Gast leer) -> Gast-Patch: Sprung auf 0x0299 (Host prueft/verbraucht die echten Dietriche)
    -- UE 5.6 geprueft (bp\LockpickUI_C.kdis): @028b JumpIfNot ->0x0c9a, @0299 LetObj, L_0c9a unveraendert
    LPUBER = "/Game/UI/Lockpick/LockpickUI.LockpickUI_C:ExecuteUbergraph_LockpickUI",
    -- Runde 8
    GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
    CU = "/Script/AutoSettings.Default__ConsoleUtils",
    ALLKC = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard",
    CROWBAR = "/Game/Inventory/Items/DataAssets/Weapons/Melee/2Handed/DA_Crowbar.DA_Crowbar",
    WATER = { "/Game/Inventory/Items/DataAssets/Consumables/Thirst/DA_DirtyWaterJug.DA_DirtyWaterJug",
        "/Game/Inventory/Items/DataAssets/Consumables/Thirst/DA_DirtyWaterCanteen.DA_DirtyWaterCanteen",
        "/Game/Inventory/Items/DataAssets/Consumables/Thirst/DA_DirtyWaterBottle.DA_DirtyWaterBottle" },
    LDOOR = "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C",
    HANGUB = "/Game/Blueprints/Other/Doors/BP_HangarDoor.BP_HangarDoor_C:ExecuteUbergraph_BP_HangarDoor",
    KCUB = "/Game/Blueprints/Other/Doors/BP_KeycardDoor.BP_KeycardDoor_C:ExecuteUbergraph_BP_KeycardDoor",
    DISUI = "/Game/Inventory/Widgets/Crafting/W_DisassemblyWorkbenchUI.W_DisassemblyWorkbenchUI_C",
    BEACON = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C",
    DISBENCH = "/Game/Blueprints/BuildingSystem/Actors/Benches/Buildable_DisassemblyWorkbench.Buildable_DisassemblyWorkbench_C",
    CONBENCH = "/Game/Blueprints/BuildingSystem/Actors/Benches/Buildable_ConstructionBench.Buildable_ConstructionBench_C",
    -- Runde 9 (build_bunker): Scanner-Material wie MC_CallInteract @0625/@0638
    BK_GREEN = "/Game/Meshes/Materials/M_EmissiveColour_Green.M_EmissiveColour_Green",
    BK_RED = "/Game/Meshes/Materials/M_EmissiveColour_Red.M_EmissiveColour_Red",
    MELEE = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C",   -- raid_melee
    -- Runde 9 (build-2): Vitrine (build_display), Bau-Ton SpawnBuild @028b und Ja-Knopf der Ja/Nein-Abfrage (build_polish)
    DISPLAY = "/Game/Blueprints/BuildingSystem/Actors/Display/BuildableMaster_Display.BuildableMaster_Display_C",
    BUILDCUE = "/Game/Audio/Sounds/Cue/S_Build_Cue.S_Build_Cue",
    YNYES = "/Game/UI/Widgets/Other/ModularYesNoUI.ModularYesNoUI_C:"
        .. "BndEvt__ModularYesNoUI_YES_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
}
-- Radio/Jukebox: MC_OnInteractBuildable (Multicast) oeffnet RadioUI bei JEDEM Client (ToggleRadioUI @00bd)
local RADIO = { Buildable_Radio_C = true, Buildable_Jukebox_C = true }

-- Zustands-Klassen: T = Typ, P = Eigenschaft, Inv = Eigenschaft heisst "zu", Fn = lokales Umschalten beim Gast,
-- Arg = Fn bekommt die eigene Figur, Busy = waehrend der Animation nicht anfassen
-- Runde 8: Dot = Richtung (DotProduct, build_doordir) im b_st-Wert, Xp = XPGiven? im b_st-Wert (build_kcard),
-- Pow = Garagentor ohne Strom-Hinweis umschalten (build_garagepow), OldFn/OldArg = alter Weg ohne build_wdoorfix
local DOOR = { T = "d", P = "IsClosed", Inv = true, Fn = "OnInteractBuildable", Arg = true, Dot = true }
local LIGHT = { T = "d", P = "LightOn", Fn = "OnInteractBuildable", Arg = true }
-- build_wdoorfix: MC_OpenDoor(eigene Figur) spielt zusaetzlich BPI_Player.PlayMontage(Loot_MidShelf_GrabItem) auf der
-- Figur (BarrierGate @03d0/@042d, ContainerDoors @02b9/@0316) -> Event_Door ohne Figur (@059c/@0718) schaltet nur um
local WDOOR = { T = "d", P = "Open?", Fn = "Event_Door", OldFn = "MC_OpenDoor", OldArg = true }
-- Karten-/Tastenfeld-Tueren: MC_OpenDoor(eigene Figur) wuerde beim Gast dessen Schluesselkarte verbrauchen bzw. XP und
-- Erfolg vergeben. Oeffnen = nur die Tuer-Timeline (wie das Spiel nach der Pruefung), Schliessen = Event_CloseDoor.
-- TL = Timeline-Komponente, Close = Schliess-Event, CloseNil = Event hat einen Actor-Parameter (nil uebergeben)
local KDOOR = { T = "d", P = "Open?", TL = "Timeline_OpenDoor", Close = "Event_CloseDoor", CloseNil = true, Xp = true }
local SPEC = {
    Buildable_WoodenDoor_C = DOOR, Buildable_WoodenDoor2_C = DOOR, Buildable_BunkerDoor_C = DOOR,
    Buildable_BarricadedMetalDoor_C = DOOR,
    Buildable_WoodenGate_C = { T = "d", P = "IsClosed", Inv = true, Fn = "OnInteractBuildable", Arg = true, Dot = true },
    Buildable_GarageDoor_C = { T = "d", P = "Opened?", Fn = "OnInteractBuildable", Arg = true, Busy = "DoorOpening?",
        Pow = true },
    Buildable_Lamp_C = LIGHT, Buildable_CeilingLight_C = LIGHT, Buildable_CeilingLight2_C = LIGHT,
    Buildable_WallLight_C = LIGHT, Buildable_CampingLamp_C = LIGHT,
    Buildable_ConstructionLight_C = { T = "d", P = "LightOn", Fn = "OnInteractBuildable", Arg = true },
    Buildable_Turret_C = { T = "t" }, Buildable_SmallTurret_C = { T = "t" },
    Buildable_HordeBeacon_C = { T = "h" },
    BP_KeypadDoor_C = { T = "k", P = "Open?", TL = "Timeline_OpenDoor", Close = "Event_CloseDoor", CloseNil = true },
    BP_KeycardDoor_C = KDOOR,
    BP_HangarDoor_C = { T = "d", P = "Open?", TL = "Timeline_OpenDoor", Close = "Event_CloseDoor", Xp = true },
    BP_BarrierGate_C = WDOOR, BP_ContainerDoors_C = WDOOR,
    -- MC_OpenDoor @01c0 ruft nur Event_OpenDoor (L_01b1); DoorOpening?-Sperre @01c5
    BP_PoliceStationGarageDoor_C = { T = "d", P = "Open?", Fn = "Event_OpenDoor", Busy = "DoorOpening?",
        OldFn = "MC_OpenDoor", OldArg = true },
    BP_WarehouseDoors_C = { T = "d", P = "IsClosed", Inv = true, Fn = "Event_Door", OldFn = "MC_OpenDoor", OldArg = true },
    BP_LockedDoor_C = { T = "dl", P = "Closed?", Inv = true, Fn = "Event_Door" },
    -- Runde 9 (build_bunker, UE 5.6 neu): Bunkertueren schaltet CallInteractOnObject (@0295/@0282: Ton, Timeline
    -- Play/Reverse; Open? ist nicht repliziert), Scanner-Zustand "bs" (Unlocked?/KeycardRequired?). Bk = Schalter
    BP_DoubleBunkerDoor_C = { T = "d", P = "Open?", Fn = "CallInteractOnObject", Bk = true },
    BP_LargeBunkerEntrance_C = { T = "d", P = "Open?", Fn = "CallInteractOnObject", Bk = true },
    BP_LargeBunkerEntrance_Small_C = { T = "d", P = "Open?", Fn = "CallInteractOnObject", Bk = true },
    BP_BunkerScanner_C = { T = "bs", Bk = true },
}
-- FindAllOf-Gruppen (je Sekunde genau eine): Bauten jede 2. Sekunde, Welttueren reihum dazwischen
-- (BP_LargeBunkerEntrance_C nimmt die Unterklasse _Small mit)
local WORLD = { "BP_KeypadDoor_C", "BP_KeycardDoor_C", "BP_BarrierGate_C", "BP_HangarDoor_C", "BP_ContainerDoors_C",
    "BP_WarehouseDoors_C", "BP_PoliceStationGarageDoor_C", "BP_LockPickObject_C",
    "BP_DoubleBunkerDoor_C", "BP_LargeBunkerEntrance_C", "BP_BunkerScanner_C" }

local B = {
    Gen = -1, Step = 0, Seq = 0,
    H = { ByName = {}, ByKey = {}, ByCls = {} },   -- Index (Host und Gast, je nach Seite)
    Mode = {},        -- Host: [GuestKey] = { DA, DAPath, Cls, Rep, RepPath, Pick, PickPath, Comp }
    HQ = {},          -- Host: Svr_SpawnBuild (Hook-Body schreibt nur hierher)
    HQOver = {},      -- Host: [GuestKey] = { N, At, Cls = {[Klasse]=true}, Cells, NC, Wide } HQ-Ueberlauf (build_spawncap)
    BeaconBy = {},    -- Host: [Beacon-Pfad] = { Key, Pawn = Figur-Pfad, At } Starter der Horde (build_beacondeath)
    IQ = {},          -- Host: SERVER_ForwardInteract (Hook-Body schreibt nur hierher)
    Later = {},       -- Host: { At, Fn }
    Verify = {},      -- Host: { Cls, X, Y, Z, Kill, At, G, Md, Multi }
    Claimed = {},     -- Host: [Actor-Name] = true (von einer Kontrolle verbraucht/entfernt)
    OwnHook = false,  -- Host: Owner im SERVER_ForwardInteract-Hook setzen (build_owner + build_ownhook)
    MaxHp = {}, HpPos = 0, Rate = {},
    Beds = nil, BedSeen = {},
    Hooks = {},       -- Host: [Pfad] = true (registriert)
    HookTry = 0,
    -- Gast
    Want = {}, Hp = {}, Tries = {}, Next = {}, TurretOff = {}, Wave = {},
    LastMode = nil, LastFoc = nil, ClickDown = false, Pick = nil, Kp = nil, Ren = nil, Yn = nil,
    GhostAt = nil, GhostRuns = 0, ApplyAt = 0, ApplyAll = 0,
    Cls = {},         -- Klassen-Objekte (pro Welt)
    FocQ = {},        -- Host: [GuestKey] = { G, Key } letzter b_foc je Gast (Fast verarbeitet)
    Snap = {},        -- Host: [GuestKey] = Geist-Zaehler-Schnappschuss beim Anschauen (build_ghostfix)
    Logged = {},      -- Host: [Text] = true (einmal loggen)
    -- Runde 7 (Host)
    Codes = {},       -- [GuestId] = { [Besitz-Schluessel] = { Until = os.time() bis, Code = Schloss-Code } } (/code)
    CodeFail = {},    -- [GuestId] bzw. ["k:" .. Schloss-Schluessel] = { N, T } falsche Codes
    OwnT = {},        -- [Actor-FullName] = { Key = GuestKey, Gid } Owner-Trick gesetzt (OW.OwnSweep)
    Foc = {},         -- [GuestKey] = { Key, At } letzter Fokus (auch leer) fuer /lock /code /owner
    Deny = {},        -- [GuestKey] = { [Actor-FullName] = true } aktuell gesperrt
    DenySig = nil, DenyAt = 0, DenyN = 0,
    Ally = {},        -- Cache Allied je Durchlauf
    WarnAt = {},      -- [GuestId] = os.clock() letzte Raid-Warnung
    NameDone = {}, NameTry = {}, JoinQ = {},
    KindByCls = {}, BuildCls = {}, TagCls = {},
    RaidN = 0, RaidKills = 0, HookNull = false,
    PickStart = {},   -- Host: [GuestKey] = { Key, At } Minispiel-Start (b_lpq) fuer b_unlock
    LpN = nil, LpD = nil, LpPatchOn = false, LpPatchLine = nil,   -- Gast: Dietriche laut Host, Haltbarkeit, Patch
    RadioFoc = nil, RadioOpen = {},   -- Gast: zuletzt angeschautes Radio, [Key] = eigenes offenes Radio-Fenster
    HostSlp = nil,    -- Host: { Path, At } letzte EIGENE Bett/Schlafsack/Zelt-Interaktion (Schutz eigenes Schlaf-Fenster)
    -- Runde 8 (Host): Anfragen je Gast (OW.Pre), Stationsfenster (build_stationlock), Werkbank-Tabellen (build_bench)
    GRate = {}, GLast = {}, StationOpen = {}, Bench = {},
    -- Runde 8 (Gast): Kc = { Key, All, Card, At } (b_ui kc), KcFoc/KcLeft Fokus der Kartentuer, KcLine/PLine
    -- Patchzeilen, LdQ/DisQ Hook-Warteschlangen, DotFix[Key] = { S, Until }, StOpen[Key] = { D0 } offene Stationen
    KcLine = {}, PLine = {}, LdQ = {}, DisQ = {}, DotFix = {}, StOpen = {},
    -- Runde 9 (build-2): Klassen-Caches (nur Namen/Zahlen, keine UObjects), Host: Beitrittszeit (Bett-Hinweis),
    -- gesendete Claim-Kreise je Gast; Gast: Sollwerte b_mk/b_clm/b_rd, Vitrinen, Kisten-Zahl (b_st n)
    SpecCls = {}, HpCls = {}, ModCls = {}, BedJoin = {}, ClmSent = {},
    Clm = {}, MkWant = {}, RdWant = {}, RdSeen = {}, RdMine = {}, Disp = {}, DispComp = {}, BoxN = {},
}
M.B = B
-- Besitz-Daten (Host, ueberleben Weltwechsel): siehe Abschnitt "Besitz, Claims, Schloesser, Raids"
local O = { Own = {}, Lock = {}, Claim = {}, Names = {}, Warn = {}, Pos = {}, ByCls = {}, Claims = {},
    Gen = 1, IdxGen = 0, Loaded = false, Dirty = false, SavedAt = 0, Doubt = {} }
B.O = O
local OW = {}     -- Runde-7-Funktionen (Tabelle: Aufrufreihenfolge egal, wenige Haupt-Locals)

local function Log(fmt, ...) A.Log("[Bau] " .. fmt, ...) end
local function On(Name) return Core.Flag(FLAG, true) and (Name == nil or Core.Flag(Name, true)) end
local function R(V) return math.floor((tonumber(V) or 0) + 0.5) end
local function Enc(V) return Net.Enc(tostring(V or "")) end
local function Dec(V) return Net.Dec(V or "") end
local function Num(V) return tonumber(V) end

local function PathOf(FullName) return FullName and FullName:match("^%S+%s+(.+)$") end

local function ClassObj(Path)
    -- Runde 9 (CORE-19, world_hygiene): Klassen-Cache je Welt auch ohne CheckWorld (Aufrufe aus anderen Modulen/Hook)
    if B.HygOn ~= false and A.WorldGen and A.WorldGen.N ~= B.ClsGen then B.ClsGen, B.Cls = A.WorldGen.N, {} end
    local C = B.Cls[Path]
    if C and A.IsAlive(C) then return C end
    C = StaticFindObject(Path)
    if not A.IsAlive(C) then return nil end
    B.Cls[Path] = C
    return C
end

local function IsA(Obj, Path)
    local C = ClassObj(Path)
    return C ~= nil and A.Safe(function() return Obj:IsA(C) end, false) == true
end

local function ClsName(Obj) return A.Safe(function() return Obj:GetClass():GetFName():ToString() end) end

local function Loc(Obj)
    local L = A.Safe(function() return Obj:K2_GetActorLocation() end)
    if not L then return nil end
    return L.X, L.Y, L.Z
end

local function KeyOf(Obj)
    if not A.IsAlive(Obj) then return nil end
    local Cls = ClsName(Obj)
    local X, Y, Z = Loc(Obj)
    if not (Cls and X) then return nil end
    return string.format("%s@%d,%d,%d", Cls, R(X), R(Y), R(Z)), Cls, X, Y, Z
end

local function ParseKey(Key)
    local Cls, X, Y, Z = (Key or ""):match("^([%w_]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not Cls then return nil end
    return Cls, tonumber(X), tonumber(Y), tonumber(Z)
end

local function Dist(AX, AY, AZ, BX, BY, BZ)
    local DX, DY, DZ = AX - BX, AY - BY, AZ - BZ
    return math.sqrt(DX * DX + DY * DY + DZ * DZ)
end

-- Figur des Gasts frisch (Host)
local function GuestPawn(G)
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    return A.IsAlive(Pawn) and Pawn or nil, PC
end

-- Komponente/Objekt -> Gast ueber den Figur-Namen im Pfad (".../BP_PlayerCharacter_C_123.BuildingComponent")
local function GuestOfComp(FullName)
    local Path = PathOf(FullName)
    local Pawn = Path and Path:match("([^%.:]+)[%.:][^%.:]+$")
    return Pawn and Net.GuestByPawnName(Pawn) or nil
end

local function Throttle(Key, Sec)
    local Now = os.clock()
    if B.Rate[Key] and Now - B.Rate[Key] < Sec then return false end
    B.Rate[Key] = Now
    return true
end

local function AnyGuest()
    for _, G in pairs(Net.Guests) do
        if G.Epoch and Net.Has(CAP, G) then return true end
    end
    return false
end

-- ---------------------------------------------------------------- Index (Klasse + Position -> Objektpfad)
local function SpecFor(Obj, Cls)
    local S = SPEC[Cls]
    if S then
        -- Runde 9 (build_perf, BUILD-23): reine Strom-Lichter haben kein OnInteractBuildable, LightOn bleibt fest
        if OW.SPEC_POWER[Cls] and On("build_perf") then return nil end
        return S
    end
    -- build_perf: IsA-Ergebnis je Klasse merken (Klassenname -> Spec-Tabelle oder false)
    local Perf = On("build_perf")
    -- Cache nur bei build_perf lesen: sonst waere C0 = false (~= nil) und Kisten/Schloesser/Vitrinen bekaemen kein Spec
    if Perf then
        local C0 = B.SpecCls[Cls]
        if C0 ~= nil then return C0 or nil end   -- false = gemerkt "kein Spec" (Negativ-Cache)
    end
    local Disp = On("build_display")
    if IsA(Obj, P.CONTAINER) then S = OW.SPEC_N
    elseif IsA(Obj, P.LOCK) then S = OW.SPEC_L
    elseif Disp and IsA(Obj, P.DISPLAY) then S = OW.SPEC_V end   -- Runde 9 (build_display, BUILD-19): Vitrine
    if Perf and (S or Disp) then B.SpecCls[Cls] = S or false end
    return S
end

local function IndexAdd(Obj, Name, Grp)
    local Key, Cls, X, Y, Z = KeyOf(Obj)
    if not Key then return nil end
    local E = { Name = Name, Path = PathOf(Name), Key = Key, Cls = Cls, X = X, Y = Y, Z = Z, Grp = Grp,
        Spec = SpecFor(Obj, Cls), At = os.clock() }
    -- Runde 9 (claim_ownpick, BUILD-7): veraendernde Interaktions-Optionen der Klasse (Host, ausserhalb des Hooks)
    if Grp == MASTER and Net.Side == "host" then E.Mod = OW.ModOpts(Obj, Cls) end
    B.H.ByName[Name] = E
    B.H.ByKey[Key] = E
    B.HpList = nil   -- build_perf: HP-Reihenfolge neu aufbauen
    return E
end

local function IndexDrop(E)
    B.H.ByName[E.Name] = nil
    if B.H.ByKey[E.Key] == E then B.H.ByKey[E.Key] = nil end
    B.HpList = nil
    if Net.Side == "host" then
        Net.State("b_st", E.Key, nil)
        Net.State("b_hp", E.Key, nil)
        if RADIO[E.Cls] then Net.State("b_rd", E.Key, nil) end   -- build_radiosync
        if E.Cls == "Buildable_BaseMarker_C" then OW.MarkDrop(E.Key) end   -- claim_hidemarker
        B.MaxHp[E.Key] = nil
        -- Bau verschwunden: Besitz-Eintrag erst nach 60 s ohne Nachfolger am Ort loeschen (OW.Prune)
        if E.Grp == MASTER then
            local ok, K = pcall(OW.EKey, E)
            if ok and K then O.Doubt[K] = os.clock() end
        end
    end
end

local function RebuildByCls()
    local ByCls = {}
    for _, E in pairs(B.H.ByName) do
        local L = ByCls[E.Cls]
        if not L then L = {} ByCls[E.Cls] = L end
        L[#L + 1] = E
    end
    B.H.ByCls = ByCls
end

-- Full (build_idxfull, Host): ohne Budget (ganze Welt in einem Durchlauf). Rueckgabe: neu aufgenommene Eintraege
local function ScanGroup(Grp, Full)
    local List = A.Safe(function() return FindAllOf(Grp) end) or {}
    local Seen, Budget, Added = {}, Full and 100000 or 150, 0
    for _, Obj in ipairs(List) do
        if A.IsAlive(Obj) then
            local Name = A.Safe(function() return Obj:GetFullName() end)
            if Name then
                local E = B.H.ByName[Name]
                if not E and Budget > 0 then
                    Budget = Budget - 1
                    E = IndexAdd(Obj, Name, Grp)
                    if E then Added = Added + 1 end
                end
                Seen[Name] = true
            end
        end
    end
    for Name, E in pairs(B.H.ByName) do
        if E.Grp == Grp and not Seen[Name] then IndexDrop(E) end
    end
    RebuildByCls()
    return Added
end

local function Fresh(E)
    local Obj = E and E.Path and StaticFindObject(E.Path)
    return A.IsAlive(Obj) and Obj or nil
end

-- Schluessel -> lebendes Objekt (genau, sonst naechstes derselben Klasse <= MATCH_DIST)
local function Resolve(Key)
    local E = B.H.ByKey[Key]
    local Obj = Fresh(E)
    if Obj then return Obj, E end
    local Cls, X, Y, Z = ParseKey(Key)
    if not Cls then return nil end
    local Best, BestD
    for _, C in ipairs(B.H.ByCls[Cls] or {}) do
        local D = Dist(C.X, C.Y, C.Z, X, Y, Z)
        if D <= MATCH_DIST and (not BestD or D < BestD) then Best, BestD = C, D end
    end
    Obj = Fresh(Best)
    if Obj then return Obj, Best end
    return nil
end

-- Selten gebrauchte Klassen ausserhalb des Index (Boden-Pickups): FindAllOf hoechstens 1/s.
-- Base (Host, Gast-Schluessel): FESTE Basisklasse scannen (FindAllOf nimmt Unterklassen mit), Klassenname nur
-- vergleichen - sonst koennte ein Gast mit "Object@0,0,0" das ganze Objekt-Array durchlaufen lassen
local function ResolveScan(Key, Base)
    local Obj = Resolve(Key)
    if Obj then return Obj end
    local Cls, X, Y, Z = ParseKey(Key)
    if not Cls or #Cls > 96 or not Throttle("scan_" .. (Base or Cls), 1.0) then return nil end
    local Best, BestD
    for _, C in ipairs(A.Safe(function() return FindAllOf(Base or Cls) end) or {}) do
        if A.IsAlive(C) then
            local CX, CY, CZ = Loc(C)
            local D = CX and Dist(CX, CY, CZ, X, Y, Z)
            if D and D <= MATCH_DIST * 2 and (not BestD or D < BestD) and (not Base or ClsName(C) == Cls) then
                Best, BestD = C, D
            end
        end
    end
    return Best
end

local function ResetWorld()
    B.H = { ByName = {}, ByKey = {}, ByCls = {} }
    B.Mode, B.HQ, B.IQ, B.Later, B.Verify, B.MaxHp, B.Claimed = {}, {}, {}, {}, {}, {}, {}
    B.HQOver, B.PPos, B.BeaconBy = {}, {}, {}
    -- build_idxfull: Weltstart -> Index ohne Budget bis stabil (OW.IdxFullPass), danach IdxReady (claim_reconcile)
    B.IdxFull, B.IdxN, B.IdxSame, B.IdxTry, B.IdxReady, B.RecDone = true, 0, 0, nil, nil, nil
    B.BkSeen = {}     -- Gast: [Scanner-Schluessel] = zuletzt angewandtes Unlocked? (build_bunker, Ton nur bei Flanke)
    B.Want, B.Hp, B.Tries, B.Next, B.TurretOff, B.Wave = {}, {}, {}, {}, {}, {}
    B.LastMode, B.LastFoc, B.Pick, B.Kp, B.Ren, B.Yn = nil, nil, nil, nil, nil, nil
    B.GhostAt, B.GhostRuns, B.Cls = nil, 0, {}
    B.FocQ, B.Snap = {}, {}
    B.Foc, B.Deny, B.DenySig, B.KindByCls, B.BuildCls, B.TagCls = {}, {}, nil, {}, {}, {}
    B.OwnT = {}
    B.PickStart, B.RadioOpen, B.RadioFoc, B.LpD = {}, {}, nil, nil
    B.StationOpen, B.Bench, B.LdQ, B.DisQ, B.DotFix, B.StOpen = {}, {}, {}, {}, {}, {}
    B.Kc, B.KcFoc, B.KcLeft, B.BenchSent, B.BenchPath = nil, nil, nil, nil, nil
    -- Runde 9 (build-2): Welt-Daten (Host: Claim-Kreise je Gast, Bauverbotszonen, Raid-Beute; Gast: Sollwerte)
    B.ClmSent, B.ClmPub, B.MkPub, B.NoBuild, B.LootQ, B.LootAt, B.HpList = {}, nil, nil, nil, {}, nil, nil
    B.Clm, B.MkWant, B.RdWant, B.RdSeen, B.RdMine, B.Disp, B.DispComp, B.BoxN = {}, {}, {}, {}, {}, {}, {}, {}
    B.NFoc, B.ClmBlock, B.YnYes = nil, nil, nil
    O.Doubt = {}
end

local function LogOnce(Tag, fmt, ...)
    if B.Logged[Tag] then return end
    B.Logged[Tag] = true
    Log(fmt, ...)
end

-- Owner-Relay-Ziel: build_ownall = jedes Buildable_MASTER_C-Kind, sonst nur Generator/Dusche/Brunnen (alt)
local function OwnTarget(Obj)
    if On("build_ownall") then return IsA(Obj, P.MASTER) end
    return IsA(Obj, P.GEN) or IsA(Obj, P.SHOWER) or IsA(Obj, P.WELL)
end

local function CheckWorld()
    local N = A.WorldGen and A.WorldGen.N or 0
    if N ~= B.Gen then
        B.Gen = N
        ResetWorld()
    end
    local W = A.WorldGen
    return not (W and W.Loading and os.clock() - (W.LoadingAt or 0) < 60)
end

-- ---------------------------------------------------------------- Hooks (Host, seltene Ereignisse, nur Lua-Tabellen)
local function HookSpawn(Ctx, T)
    if #B.HQ > 40 then
        -- build_spawncap: Ueberlauf je Gast merken statt still verwerfen (nur Lua-Tabellen); HostPlace beendet den
        -- Baumodus, warnt und raeumt die ungeprueften Bauten ab (OW.SpawnFlood/OW.Sweep)
        if On("build_spawncap") then pcall(OW.HookOver, Ctx, T) end
        return
    end
    local Ev = { At = os.clock() }
    pcall(function() Ev.Comp = Ctx:get():GetFullName() end)
    pcall(function()
        local L = T:get().Translation
        Ev.X, Ev.Y, Ev.Z = L.X, L.Y, L.Z
    end)
    -- Baumodus zum Spawn-Zeitpunkt festhalten (nur Lua-Tabellen): ein spaeter angewandtes b_mode darf nicht zaehlen
    pcall(function()
        local G = Ev.Comp and GuestOfComp(Ev.Comp)
        Ev.Md = G and B.Mode[G.Key] or false
    end)
    B.HQ[#B.HQ + 1] = Ev
end

-- Generator/Dusche/Brunnen verbrauchen beim Host ueber GetOwner() (Tanken = Option2), jeder Bau gibt beim Abbau
-- (Svr_Spawn @0553) an GetPlayerCharacter(0). Der Owner aus b_foc ist der zuletzt hinschauende Gast -> hier, direkt
-- vor OnServerExecuteInteract, auf den interagierenden Gast setzen (SetOwner auf denselben Owner ist im Engine ein No-op).
-- Einziger UFunction-Aufruf im Hook (SetOwner, nativ, nicht gehookt); Schalter build_ownhook / build_ownall.
local function OwnerAtInteract(Ctx, Actor, CompName, ActName)
    if not (B.OwnHook and CompName) then return end
    local G = GuestOfComp(CompName)
    if not G then return end
    -- gesperrtes Objekt (Sperrliste): Owner nicht auf den Fremden umbiegen
    if ActName and B.Deny[G.Key] and B.Deny[G.Key][ActName] then return end
    -- Runde 9 (claim_ownpick): reines fremdes Bauteil (Wand, Fundament ...) bekommt keinen Owner-Trick (nur Lua)
    if ActName and OW.ModNoOwner(G, ActName) then return end
    local Obj = Actor:get()
    if not A.IsAlive(Obj) or not OwnTarget(Obj) then return end
    -- build_stationlock: Station mit offenem Fenster eines anderen Gasts nicht umhaengen (wie HostFocus)
    local Pawn
    if Core.Flag("locks_hookfirst", true) then
        -- CORE-18: einzige UFunction im Hook ist SetOwner. Stationshalten nur aus Lua-Tabellen (Index-Position,
        -- Gast-Positionen des 0,5-s-Sperrdurchlaufs), Figur = Outer der Jig-Komponente (nativ, kein GetOwner-Aufruf)
        if OW.StationHeldLua(ActName, G) then return end
        Pawn = Ctx:get():GetOuter()
    else
        if OW.StationHeld(Obj, G) then return end
        Pawn = Ctx:get():GetOwner()
    end
    if A.IsAlive(Pawn) then
        Obj:SetOwner(Pawn)
        if ActName then B.OwnT[ActName] = { Key = G.Key, Gid = G.GuestId } end
    end
end

local function HookInteract(Ctx, Actor, Option)
    -- locks_hookfirst (BUILD-8): volle Warteschlange ueberspringt nur Einreihen und Owner-Trick, nie die Sperr-Pruefung
    local Full = #B.IQ > 40
    if Full and not Core.Flag("locks_hookfirst", true) then return end
    local Ev = { At = os.clock() }
    pcall(function() Ev.Comp = Ctx:get():GetFullName() end)
    pcall(function()
        local Act = Actor:get()
        if A.IsAlive(Act) then Ev.Act = Act:GetFullName() end
    end)
    pcall(function() Ev.Opt = Option:get().TagName:ToString() end)
    -- Runde 8 (build_kcard): Karten-/Hangartuer eines Gasts. Das Spiel (Event_OpenDoor @0940/@0ab6) prueft die
    -- Allzugangskarte beim Host per FindJigItemByDA = immer false -> Actor leeren (OnServerExecuteInteract @0246/@01ca
    -- scheitert an IsValid(ByActor)), HostInteract (OW.KcSplit) fuehrt die Tuer selbst aus. Nur Tabellen, kein Owner.
    if Ev.Comp and Ev.Act and On("build_kcard") and pcall(OW.KcEv, Ev) and Ev.Kc then
        pcall(function() Actor:set(nil) end)
        if not Full then B.IQ[#B.IQ + 1] = Ev end
        return
    end
    -- Runde 9 (build_bunker): Bunker-Scanner eines Gasts. MC_CallInteract (@038c) liefe auf JEDER Maschine (FindKeycard
    -- mit leerem Gast-Inventar -> "No Keycard Available", Tueren nur lokal) -> Actor leeren (OnServerExecuteInteract
    -- @02ab scheitert an IsValid(ByActor)), HostInteract (OW.KcSplit -> OW.BunkerHost) fuehrt ihn beim Host aus
    if Ev.Comp and Ev.Act and Ev.Act:match("^BP_BunkerScanner_C ") and On("build_bunker") and GuestOfComp(Ev.Comp) then
        pcall(function() Actor:set(nil) end)
        Ev.Bunk = true
        if not Full then B.IQ[#B.IQ + 1] = Ev end
        return
    end
    -- Gesperrt? Lua-Sperrliste (auch Objekte ohne DLL-Zeile: Budget voll) oder - jenseits DENY_MAX/Reichweite -
    -- reine Lua-Pruefung am Index (OW.Access, keine UFunction). Dann Actor-Parameter leeren und KEIN Owner-Trick.
    -- locks_hooknull=1 / DLL inaktiv: wie bisher; locks_luanull=0: alter Stand (nur mit HookNull)
    if Ev.Comp and Ev.Act and (B.HookNull or Core.Flag("locks_luanull", true)) then
        pcall(function()
            local G = GuestOfComp(Ev.Comp)
            if not G then return end
            local Deny = B.Deny[G.Key] and B.Deny[G.Key][Ev.Act]
            if not Deny and (On("claim_on") or On("locks_on")) then
                local E = B.H.ByName[Ev.Act]
                if E and E.Grp == MASTER and E.X and not OW.Access(G.GuestId, E.X, E.Y, OW.EKey(E)) then
                    Deny = true
                elseif not E and B.IdxFull and On("build_idxfull") then
                    -- build_idxfull: Index nach Weltstart noch unvollstaendig - Klasse mit Besitz-Eintraegen sperren,
                    -- HostInteract nimmt das Objekt sofort auf (OW.IdxLate), der Gast versucht es gleich nochmal
                    local Cls = Ev.Act:match("^(%S+) ")
                    if Cls and O.ByCls[Cls] then
                        Deny = true
                        Ev.IdxQ = true
                    end
                end
            end
            if Deny then
                Ev.Denied = true
                Actor:set(nil)
            end
        end)
    end
    -- Runde 9 (claim_ownpick, BUILD-7): Ersetzen/Aufheben eines fremden Bauteils (Besitzer nicht im Clan) auch
    -- ausserhalb von Claims sperren. Nur Lua-Tabellen (Index E.Mod, owners), keine UFunction
    if Ev.Comp and Ev.Act and not Ev.Denied and On("claim_ownpick") and On("claim_on") then
        local okM, No = pcall(OW.ModDeny, Ev)
        if not okM then
            Ev.ModErr = No   -- Core.Fail erst in HostInteract (Hook-Koerper nur Tabellen)
        elseif No then
            Ev.Denied, Ev.ModNo = true, true
            pcall(function() Actor:set(nil) end)
        end
    end
    if Full then return end
    if not Ev.Denied then pcall(OwnerAtInteract, Ctx, Actor, Ev.Comp, Ev.Act) end
    B.IQ[#B.IQ + 1] = Ev
end

local function TryHooks()
    if B.HookTry > 0 and os.clock() - B.HookTry < 10 then return end
    B.HookTry = os.clock()
    if On("build_hook") and not B.Hooks.spawn and ClassObj(P.COMP) then
        if A.TryHook(P.COMP .. ":Svr_SpawnBuild", HookSpawn) then
            B.Hooks.spawn = true
            Log("Hook Svr_SpawnBuild aktiv")
            Net.Cap(CAP_HOOK, true)
        end
    end
    if On("build_ihook") and not B.Hooks.inter and ClassObj(P.JIGMP) then
        if A.TryHook(P.JIGMP .. ":SERVER_ForwardInteract", HookInteract) then
            B.Hooks.inter = true
            Log("Hook SERVER_ForwardInteract aktiv")
        end
    end
end

-- ---------------------------------------------------------------- Host: Platzieren
local function FindAsset(Path)
    if not Path or Path == "" then return nil end
    local Obj = StaticFindObject(Path)
    if not A.IsAlive(Obj) then Obj = A.Safe(function() return LoadAsset(Path) end) end
    return A.IsAlive(Obj) and Obj or nil
end

local function StopHostMode(G)
    local Pawn = GuestPawn(G)
    local Comp = Pawn and A.Safe(function() return Pawn.BuildingComponent end)
    if A.IsAlive(Comp) and A.Safe(function() return Comp["BuildModeOn?"] end, false) then
        pcall(function() Comp:Event_StopBuildMode() end)
    end
    B.Mode[G.Key] = nil
end

local function OnMode(Data, G)
    if Net.Side ~= "host" or not On("build_place") then return end
    local Pawn = GuestPawn(G)
    if not Pawn then return end
    if Data == "0" or Data == "" then StopHostMode(G) return end
    if B.Mode[G.Key] and B.Mode[G.Key].Data == Data then return end   -- Wiederholung (Gast sendet alle 3 s)
    -- ohne build2-Cap keine Nachkontrolle (HostPlace); ohne Spawn-Hook nur Klick-Meldung des Gasts -> kein Baumodus
    if not Net.Has(CAP, G) then return end
    if not B.Hooks.spawn and not Core.Flag("build_trustclick", false) then
        LogOnce("nospawnhook", "b_mode abgelehnt: Hook Svr_SpawnBuild fehlt (build_trustclick=1 erlaubt Klick-Rueckfall)")
        return
    end
    local DAPath, Rep, Pick = Data:match("^1|([^|]*)|([^|]*)|([^|]*)$")
    if not DAPath then return Net.SecWarn(G, G.Key, "b_mode") end
    DAPath, Rep, Pick = Dec(DAPath), Dec(Rep), Dec(Pick)
    -- Nur Spiel-Assets (keine Karten); Nachladen von Platte hoechstens 1/s je Gast (der Gast wiederholt alle 3 s)
    if #DAPath > 256 or not DAPath:match("^/Game/[%w_/%.%- ]+$") or DAPath:match("^/Game/Maps/") then
        return Net.SecWarn(G, G.Key, "b_mode_path")
    end
    local DA = StaticFindObject(DAPath)
    if not A.IsAlive(DA) then
        if not Throttle("load" .. G.Key, 1.0) then return end
        DA = FindAsset(DAPath)
    end
    local Cls = DA and A.Safe(function()
        local BC = DA.BuildActorClass
        return A.IsAlive(BC) and BC:GetFName():ToString() or nil
    end)
    if not Cls then Log("b_mode: Asset unbekannt %s", DAPath) return end
    local Comp = A.Safe(function() return Pawn.BuildingComponent end)
    if not A.IsAlive(Comp) then return end
    if B.Mode[G.Key] then
        pcall(function() Comp:Event_StopBuildMode() end)
        B.Mode[G.Key] = nil
    end
    local RepObj = Rep ~= "" and Resolve(Rep) or nil
    local PickObj = Pick ~= "" and ResolveScan(Pick, "BP_BuildablePickup_C") or nil
    -- Ziel nicht gefunden: keinen Modus setzen (sonst Spawn ohne passenden Verbrauch); der Gast meldet sich erneut
    if (Rep ~= "" and not RepObj) or (Pick ~= "" and not PickObj) then
        Log("b_mode: Ziel fehlt beim Host (%s / %s)", Rep, Pick)
        return
    end
    -- Boden-Pickup: muss ein BP_BuildablePickup_C mit GENAU diesem Bau-Item sein. SpawnBuild @00ac spawnt
    -- DARef->BuildActorClass, verbraucht wird nur der Pickup (BP_StaticMeshPickup_C.PickupBuildFromGround ist leer)
    if PickObj then
        local PDA = IsA(PickObj, P.BUILDPICK) and A.Safe(function()
            -- Runde 9 (CORE-20): Komponente vor dem Lesen pruefen (ungueltiger Wrapper stuerzt nativ ab)
            local PC0 = PickObj.BP_JigPickupComponent
            local PDA0 = A.IsAlive(PC0) and PC0.ItemDataAsset or nil
            return A.IsAlive(PDA0) and PathOf(PDA0:GetFullName()) or nil
        end)
        if not PDA or PDA ~= PathOf(A.Safe(function() return DA:GetFullName() end)) then
            Log("b_mode: Boden-Item %s passt nicht zu %s - abgelehnt", tostring(PDA or Pick), tostring(DAPath))
            return Net.SecWarn(G, G.Key, "b_mode_pick")
        end
    end
    -- Ersetzen/Boden-Pickup nur in Reichweite des Gasts (sonst verschiebt er fremde Bauten von ueberall)
    local PX, PY, PZ = Loc(Pawn)
    for _, Obj in ipairs({ RepObj or false, PickObj or false }) do
        if Obj then
            local X, Y, Z = Loc(Obj)
            if not (PX and X) or Dist(PX, PY, PZ, X, Y, Z) > USE_DIST then
                return Net.SecWarn(G, G.Key, "b_mode_dist")
            end
        end
    end
    -- Runde 7: fremde Bauteile (Besitzer nicht im Clan / fremder Claim) nicht ersetzen
    if RepObj then
        local okM, Mine = pcall(OW.CanModify, G.GuestId, RepObj)
        if not okM then
            Core.Fail("claim_on", Mine)
        elseif not Mine then
            if Throttle("repno" .. G.Key, 5) then OW.Note(G, "Nicht dein Bauteil - Ersetzen nicht erlaubt", true) end
            return
        end
    end
    local ok, err = pcall(function()
        Comp.DARef = DA
        Comp["BuildModeOn?"] = true
        Comp["ReplacingObject?"] = RepObj ~= nil
        if RepObj then Comp.ReplacingActor = RepObj end
        if PickObj then Comp.PickupRef = PickObj end
    end)
    if not ok then
        Core.Fail("build_place", err)
        return
    end
    B.Mode[G.Key] = { Data = Data, DA = DAPath, Cls = Cls, Rep = RepObj and Rep or nil,
        RepPath = RepObj and PathOf(A.Safe(function() return RepObj:GetFullName() end)) or nil,
        PickPath = PickObj and PathOf(A.Safe(function() return PickObj:GetFullName() end)) or nil,
        Comp = A.Safe(function() return Comp:GetFullName() end), At = os.clock() }
end

local function Reply(G, Text) Net.Send("b_ok", Text, G, 0) end

-- Ersetzen: das Spiel hat den Host-Actor schon verschoben und den Baumodus der Host-Kopie beendet
local function ReplaceDone(G, Md)
    local Obj = Md.RepPath and StaticFindObject(Md.RepPath)
    local X, Y, Z
    if A.IsAlive(Obj) then X, Y, Z = Loc(Obj) end
    local Name = X and A.Safe(function() return Obj:GetFullName() end) or ""
    local E = X and (B.H.ByName[Name] or B.H.ByKey[Md.Rep]) or nil
    local Back = false
    -- Runde 7: neuer Ort im fremden Claim / Marker-Ueberlappung -> zurueck an den alten Ort (sonst entfernen)
    if X then
        local okB, Ok, Why = pcall(OW.BuildAllowed, G.GuestId, ClsName(Obj) or Md.Cls, X, Y)
        if not okB then
            Core.Fail("claim_on", Ok)
        elseif not Ok then
            Back = true
            Log("Ersetzen von %s abgelehnt: %s", tostring(G.PawnName), tostring(Why))
            OW.Note(G, ((Why or "Hier nicht erlaubt"):gsub(" %(Item bleibt bei dir%)", "")), true)
            if E and E.X then
                pcall(function() Obj:K2_SetActorLocation({ X = E.X, Y = E.Y, Z = E.Z }, false, {}, true) end)
                X, Y, Z = Loc(Obj)
            else
                pcall(function() Obj:K2_DestroyActor() end)
                X = nil
            end
        end
    end
    local Rot = X and A.IsAlive(Obj) and A.Safe(function() return Obj:K2_GetActorRotation() end)
    if Obj and X and Rot then
        -- Runde 9 (build_replflush, BUILD-10): Bauten sind ruhend (Dormancy) - neue Lage sofort an alle Gaeste
        if On("build_replflush") then
            local okF, errF = pcall(OW.ReplFlush, Obj)
            if not okF then Core.Fail("build_replflush", errF) end
        end
        local OldK = E and A.Safe(function() return OW.EKey(E) end)
        if E then IndexDrop(E) end
        local NE = IndexAdd(Obj, Name, MASTER)
        RebuildByCls()
        if NE then
            local okR, errR = pcall(OW.Replaced, G, OldK, NE.Key)
            if not okR then Core.Fail("claim_on", errR) end
        end
        Reply(G, string.format("r|%s|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f", Enc(Md.Rep), X, Y, Z,
            Rot.Pitch, Rot.Yaw, Rot.Roll))
        if not Back then OW.BuildSnd(G, X, Y, Z) end   -- build_polish: Bau-Ton wie SpawnBuild @028b beim Gast
    else
        Reply(G, "n|0")
    end
    if B.Mode[G.Key] == Md then B.Mode[G.Key] = nil end
end

-- Verbrauch fuer genau einen gefundenen Bau (Rueckgabe Used, Left)
local function Consume(G, Md)
    local Pawn = GuestPawn(G)
    local Inv = Pawn and A.Safe(function() return Pawn.BP_JigMultiplayer end)
    local Left, Used = 0, false
    if Md.PickPath then
        local Pick = StaticFindObject(Md.PickPath)
        if A.IsAlive(Pick) then
            Used = pcall(function() Pick:PickupBuildFromGround() end)
            Left = A.IsAlive(Pick) and 1 or 0
        end
    else
        local DA = FindAsset(Md.DA)
        if DA and A.IsAlive(Inv) then
            local Out = {}
            local Res = A.Safe(function() return Inv:ServerFindThenConsumeByItemID(DA, 1, Out) end)
            Used = Res == true or Out.Result == true
            local Cnt = {}
            pcall(function() Inv:GetTotalCountOfItem(DA, Cnt) end)
            Left = tonumber(Cnt.TotalCount) or 0
        end
    end
    return Used, Left
end

local function AddVerify(V)
    -- Sweeps (build_spawncap) duerfen ueber die Grenze: die Flut selbst fuellt die Liste
    if #B.Verify >= (V.Sweep and 240 or 200) then return end
    B.Verify[#B.Verify + 1] = V
end

local function HostPlace(Now)
    local Q = B.HQ
    if #Q == 0 and next(B.HQOver) == nil then return end
    B.HQ = {}
    -- build_spawncap: hoechstens OW.SPAWN_CAP Spawns je Gast und Takt (100 ms) pruefen, der Rest wird entfernt
    local Cap, PerG = On("build_spawncap"), {}
    for _, Ev in ipairs(Q) do
        local G = Ev.Comp and GuestOfComp(Ev.Comp)
        -- Modus zum Spawn-/Klickzeitpunkt (nicht der jetzige): Spawn vor b_mode = nichts gebaut, nichts verbraucht
        local Md = G and Ev.Md
        local Over = false
        if Md and Cap then
            PerG[G.Key] = (PerG[G.Key] or 0) + 1
            Over = PerG[G.Key] > OW.SPAWN_CAP
        end
        if Md and (Over or not Net.Has(CAP, G)) then
            -- ohne build2 keine Pruefung moeglich bzw. Spawn-Flut: Bau entfernen statt ungeprueft behalten
            AddVerify({ Cls = Md.Cls, X = Ev.X, Y = Ev.Y, Z = Ev.Z, Kill = true, Multi = Ev.Multi, At = Now })
        elseif Md then
            local Pawn = GuestPawn(G)
            if Pawn then
                local PX, PY, PZ = Loc(Pawn)
                if Ev.X and PX and Dist(PX, PY, PZ, Ev.X, Ev.Y, Ev.Z) > BUILD_DIST then
                    Net.SecWarn(G, G.Key, "b_dist")
                    AddVerify({ Cls = Md.Cls, X = Ev.X, Y = Ev.Y, Z = Ev.Z, Kill = true, Multi = Ev.Multi, At = Now })
                elseif Md.Rep then
                    local ok, err = pcall(ReplaceDone, G, Md)
                    if not ok then Core.Fail("build_place", err) end
                else
                    -- Verbrauch erst, wenn VerifyOne den neuen Bau wirklich findet: je gefundenem Bau ein Item
                    AddVerify({ Cls = Md.Cls, X = Ev.X, Y = Ev.Y, Z = Ev.Z, G = G, Md = Md, Multi = Ev.Multi, At = Now })
                end
            end
        end
    end
    if Cap then
        local ok, err = pcall(OW.SpawnFloods, PerG, Now)
        if not ok then Core.Fail("build_spawncap", err) end
    end
    B.HQOver = {}
end

-- Rueckfall ohne Hook: der Gast meldet seinen Klick (Transform aus seiner BuildingComponent).
-- Mehrere Klicks in einem Abfrage-Takt kommen als einer an -> Multi: VerifyOne zaehlt alle neuen Bauten am Ort.
local function OnClick(Data, G)
    if Net.Side ~= "host" or B.Hooks.spawn or not On("build_place") then return end
    if #B.HQ > 40 or not Throttle("click" .. G.Key, 0.15) then return end
    local Md = B.Mode[G.Key]
    if not Md then return end
    local X, Y, Z = Data:match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)$")
    B.HQ[#B.HQ + 1] = { At = os.clock(), Comp = Md.Comp, Md = Md, Multi = true, X = Num(X), Y = Num(Y), Z = Num(Z) }
end

-- Eine Kontrolle gegen die Kandidatenliste: verbrauchen + replizieren, sonst (kein Item / Kill) entfernen
local function VerifyEntry(E, List)
    if E.Sweep then return OW.Sweep(E, List) end   -- build_spawncap
    if not E.X then
        if E.Md then Log("Bau ohne Position (%s) - kein Verbrauch", tostring(E.Md.Cls)) end
        return
    end
    local Found = {}
    for _, C in ipairs(List) do
        -- frei und nicht Bestand (lange vor dem Spawn im Index)
        if not B.Claimed[C.Name] and not (C.Seen and C.Seen < E.At - 1) then
            local D = Dist(C.X, C.Y, C.Z, E.X, E.Y, E.Z)
            if D <= MATCH_DIST then Found[#Found + 1] = { C = C, D = D } end
        end
    end
    if #Found == 0 then
        if E.Md and not E.Kill then Log("Bau nicht gefunden (%s) - kein Verbrauch", tostring(E.Md.Cls)) end
        return
    end
    table.sort(Found, function(P1, P2) return P1.D < P2.D end)
    local Left, Denied = nil, nil
    for I = 1, math.min(E.Multi and 3 or 1, #Found) do
        local C = Found[I].C
        local Obj = C.Obj
        B.Claimed[C.Name] = os.clock()
        local Keep = false
        if not E.Kill and E.G and E.Md then
            -- Runde 7: im fremden Claim / ueberlappender Claim -> entfernen OHNE Verbrauch (Item bleibt beim Gast)
            local Allowed, Why = true, nil
            local okA, R1, R2 = pcall(OW.BuildAllowed, E.G.GuestId, E.Md.Cls, C.X, C.Y)
            if okA then Allowed, Why = R1, R2 else Core.Fail("claim_on", R1) end
            -- Runde 9 (build_nobuild/build_block_m, BUILD-29): Bauverbotszone des Spiels, Abstand zu fremden Bauten
            if Allowed then
                local okN, N1, N2 = pcall(OW.PlaceCheck, E.G, E.Md, C.X, C.Y, C.Z)
                if not okN then Core.Fail("build_nobuild", N1) elseif N1 == false then Allowed, Why = false, N2 end
            end
            if not Allowed then
                Denied = Why or "Bauen hier nicht erlaubt"
                Log("Bau von %s (%s) abgelehnt: %s", tostring(E.G.PawnName), tostring(E.Md.Cls), Denied)
            else
                local Used, L = false, 0
                if GuestPawn(E.G) then Used, L = Consume(E.G, E.Md) end
                Left = L
                if Used then
                    Keep = true
                else
                    Log("Bau ohne Item von %s (%s) - wird entfernt", tostring(E.G.PawnName), tostring(E.Md.Cls))
                end
            end
        end
        if not A.IsAlive(Obj) then
            Keep = false   -- Bau inzwischen weg: nichts mehr anfassen
        elseif not Keep then
            pcall(function() Obj:K2_DestroyActor() end)
        else
            if On("build_repl") and A.Safe(function() return Obj.bReplicates end, true) == false then
                pcall(function() Obj:SetReplicates(true) end)
                if not B.ReplLogged then B.ReplLogged = true Log("Bauten replizierten nicht - SetReplicates(true) eingeschaltet") end
            end
            pcall(function() Obj:ForceNetUpdate() end)
            if not B.H.ByName[C.Name] then
                IndexAdd(Obj, C.Name, MASTER)
                RebuildByCls()
            end
            if E.G then
                local okP, errP = pcall(OW.Placed, E.G, Obj)
                if not okP then Core.Fail("claim_on", errP) end
                OW.BuildSnd(E.G, C.X, C.Y, C.Z)   -- build_polish: Bau-Ton beim Gast (SpawnBuild @028b nur beim Host)
            end
        end
    end
    if Denied and E.G and E.Md then
        OW.Note(E.G, Denied, true)
        if not Left then Left = A.Safe(function() return OW.HaveCount(E.G, E.Md) end) end
    end
    if Left and E.G and E.Md then
        if Left <= 0 and B.Mode[E.G.Key] == E.Md then StopHostMode(E.G) end
        Reply(E.G, "n|" .. tostring(Left))
    end
end

-- Nachkontrolle der Spawns (ein FindAllOf je Sekunde, alle faelligen Kontrollen derselben Klasse auf einmal)
local function VerifyOne(Now)
    local V = B.Verify[1]
    if not V then return false end
    if Now - V.At < 0.3 then return true end
    local Batch, Rest = {}, {}
    for _, E in ipairs(B.Verify) do
        if E.Cls == V.Cls and Now - E.At >= 0.3 then Batch[#Batch + 1] = E else Rest[#Rest + 1] = E end
    end
    B.Verify = Rest
    local List = {}
    for _, Obj in ipairs(A.Safe(function() return FindAllOf(V.Cls) end) or {}) do
        if A.IsAlive(Obj) then
            local X, Y, Z = Loc(Obj)
            local Near = false
            if X then
                for _, E in ipairs(Batch) do
                    if E.Sweep then
                        if OW.InSweep(E, X, Y, Z) then Near = true break end
                    elseif E.X and Dist(X, Y, Z, E.X, E.Y, E.Z) <= MATCH_DIST then Near = true break end
                end
            end
            local Name = Near and A.Safe(function() return Obj:GetFullName() end)
            if Name then
                local Old = B.H.ByName[Name]
                List[#List + 1] = { Obj = Obj, Name = Name, X = X, Y = Y, Z = Z, Seen = Old and Old.At }
            end
        end
    end
    -- Sweeps (build_spawncap) zuletzt: echte Kontrollen beanspruchen ihre Bauten vorher (B.Claimed)
    for Pass = 1, 2 do
        for _, E in ipairs(Batch) do
            if (E.Sweep == true) == (Pass == 2) then
                local ok, err = pcall(VerifyEntry, E, List)
                if not ok then Core.Fail(E.Sweep and "build_spawncap" or "build_place", err) end
            end
        end
    end
    return true
end

-- ---- build_spawncap (Host): Svr_SpawnBuild-Flut. EVT_Svr_SpawnBuild @0374-@03bc spawnt bei Authority ohne Item-/
-- Ratenpruefung (SpawnBuild @00ac DARef->BuildActorClass); alle RPCs eines Pakets laufen in einem Server-Frame
OW.SPAWN_CAP = 6     -- Spawns je Gast und 100-ms-Takt (Klicken bleibt weit darunter)

-- Hook-Koerper bei vollem B.HQ (nur Lua-Tabellen): Zaehler, Baumodus-Klasse und Flut-Zellen (200 uu) je Gast
function OW.HookOver(Ctx, T)
    local G = GuestOfComp(Ctx:get():GetFullName())
    if not G then return end
    local Ov = B.HQOver[G.Key]
    if not Ov then
        Ov = { N = 0, At = os.clock(), Cls = {}, Cells = {}, NC = 0 }
        B.HQOver[G.Key] = Ov
    end
    Ov.N = Ov.N + 1
    local Md = B.Mode[G.Key]
    if Md and Md.Cls then Ov.Cls[Md.Cls] = true end
    if Ov.Wide then return end
    local L = T:get().Translation
    local C = math.floor(L.X / 200) .. "," .. math.floor(L.Y / 200)
    if not Ov.Cells[C] then
        Ov.Cells[C], Ov.NC = true, Ov.NC + 1
        if Ov.NC > 512 then Ov.Wide = true end   -- weit verstreut: Sweep ueber die ganze Klasse (nur Alters-Filter)
    end
end

-- HQ-Ueberlauf oder > SPAWN_CAP je Takt: Baumodus beim Host beenden (Event_StopBuildMode -> DARef = null, weitere
-- Svr_SpawnBuild spawnen nichts; der Gast meldet b_mode nach 3 s neu), warnen, ungepruefte Bauten abraeumen
function OW.SpawnFloods(PerG, Now)
    local Hit = {}
    for Key, N in pairs(PerG) do
        if N > OW.SPAWN_CAP then Hit[Key] = N end
    end
    for Key, Ov in pairs(B.HQOver) do Hit[Key] = (Hit[Key] or 0) + Ov.N end
    for Key, N in pairs(Hit) do
        local G, Ov = Net.Guests[Key], B.HQOver[Key]
        if G then
            StopHostMode(G)
            Net.SecWarn(G, G.Key, "b_spawnflood")
            if Throttle("flood" .. Key, 10) then
                Log("Spawn-Flut von %s: %d Svr_SpawnBuild in einem Takt - Baumodus beendet%s", tostring(G.PawnName), N,
                    Ov and ", ungepruefte Bauten werden entfernt" or "")
            end
            local PX, PY, PZ
            local Pawn = Ov and GuestPawn(G)
            if Pawn then PX, PY, PZ = Loc(Pawn) end
            for Cls in pairs(Ov and Ov.Cls or {}) do
                AddVerify({ Sweep = true, Cls = Cls, G = G, At = Now, From = Ov.At - 2, Cells = Ov.Cells, Wide = Ov.Wide,
                    PX = PX, PY = PY, PZ = PZ })
            end
        end
    end
end

-- Ort im Flut-Gebiet: <= BUILD_DIST um die Figur oder in/neben einer gemerkten Flut-Zelle (bzw. ueberall bei Wide)
function OW.InSweep(E, X, Y, Z)
    if E.Wide then return true end
    if E.PX and Dist(X, Y, Z, E.PX, E.PY, E.PZ) <= BUILD_DIST then return true end
    local CX, CY = math.floor(X / 200), math.floor(Y / 200)
    for DX = -1, 1 do
        for DY = -1, 1 do
            if E.Cells and E.Cells[(CX + DX) .. "," .. (CY + DY)] then return true end
        end
    end
    return false
end

-- Neue, ungepruefte Bauten der Flut-Klasse ohne Verbrauch entfernen: nicht von einer Kontrolle verbraucht (B.Claimed),
-- Index-Zeit und Lebensdauer (GetGameTimeSinceCreation) juenger als der Flut-Beginn; kein OW.Placed
function OW.Sweep(E, List)
    local Now, N, Drop = os.clock(), 0, false
    for _, C in ipairs(List) do
        if not B.Claimed[C.Name] and (C.Seen == nil or C.Seen >= E.From) and A.IsAlive(C.Obj)
            and OW.InSweep(E, C.X, C.Y, C.Z) then
            local Age = tonumber(A.Safe(function() return C.Obj:GetGameTimeSinceCreation() end))
            if Age and Age <= Now - E.From + 1 then
                B.Claimed[C.Name] = os.clock()
                pcall(function() C.Obj:K2_DestroyActor() end)
                local IE = B.H.ByName[C.Name]
                if IE then
                    IndexDrop(IE)
                    Drop = true
                end
                N = N + 1
            end
        end
    end
    if Drop then RebuildByCls() end
    Log("Spawn-Flut von %s: %d ungepruefte %s entfernt", tostring(E.G and E.G.PawnName), N, tostring(E.Cls))
end

-- ---------------------------------------------------------------- Host: Interaktionen (Hook-Warteschlange)
local function Later(Sec, Fn) B.Later[#B.Later + 1] = { At = os.clock() + Sec, Fn = Fn } end

local function UiSend(G, Text) if Net.Has(CAP, G) then Net.Send("b_ui", Text, G, 0) end end

-- ---------------------------------------------------------------- Host: Geist-Rueckfall beim Abbau (build_ghostfix)
local function JigOf(Pawn)
    local J = A.IsAlive(Pawn) and A.Safe(function() return Pawn.BP_JigMultiplayer end)
    return A.IsAlive(J) and J or nil
end

local function CountOf(Inv, DA)
    local Out = {}
    if not pcall(function() Inv:GetTotalCountOfItem(DA, Out) end) then return nil end
    return tonumber(Out.TotalCount) or 0
end

-- Inventar des Geists (Spieler 0 beim Host), nie das des Gasts
local function GhostInv(G)
    -- Nur dedizierter Host (Spieler 0 = Geist ohne eigenes Sammeln). Listen-Host: Spieler 0 ist ein echter Spieler,
    -- sein eigener Zuwachs desselben Items wuerde ihm weggenommen und dem Gast gegeben (Fehlerklasse C).
    if not (type(A.Settings and A.Settings.server) == "table" or (A.Coop and A.Coop.Server ~= nil)) then
        LogOnce("gf_listen", "Abbau-Geist-Rueckfall aus: Host ist Spieler (kein dedizierter Geist)")
        return nil
    end
    local Ghost = A.OwnPawn and A.Safe(A.OwnPawn)
    local Pawn = GuestPawn(G)
    if not (A.IsAlive(Ghost) and Pawn) then return nil end
    if A.Safe(function() return Ghost:GetAddress() == Pawn:GetAddress() end, true) then return nil end
    return JigOf(Ghost)
end

-- Beim Anschauen: Geist-Bestand (build_ghostfix) und Gast-Bestand (build_pickinv) des Abbau-Items merken
local function GhostSnap(G, Obj)
    B.Snap[G.Key] = nil
    local Gf, Pi = On("build_ghostfix"), On("build_pickinv")
    if not (Gf or Pi) then return end
    local DA = A.Safe(function() return Obj.PickupDataAsset end)
    if not A.IsAlive(DA) then return end
    local Inv = Gf and GhostInv(G)
    local Cnt = Inv and CountOf(Inv, DA) or nil
    local GCnt = Pi and CountOf(JigOf(GuestPawn(G)), DA) or nil
    if Cnt == nil and GCnt == nil then return end
    local Path = PathOf(A.Safe(function() return Obj:GetFullName() end))
    local DAPath = Path and PathOf(A.Safe(function() return DA:GetFullName() end))
    if DAPath then
        B.Snap[G.Key] = { Path = Path, DA = DAPath, Cnt = Cnt, GCnt = GCnt, At = os.clock(), Cls = ClsName(Obj) or "?" }
    end
end

-- Nach der Interaktion: Bau weg und Geist hat mehr als vorher -> 1 Stueck an den Gast. Rueckgabe "wait" = Bau lebt noch.
-- build_pickinv: Geist bekam nichts und der Gast auch nicht -> JigTryAddItemSomewhere (MASTER Svr_Spawn @0553/@05a0)
-- hat das Item beim Host vor die Fuesse geworfen (Vertrag A5) -> Bodenobjekt ins Inventar (OW.GroundToInv)
local function GhostCheck(G, S)
    if Fresh({ Path = S.Path }) then return "wait" end
    local DA = FindAsset(S.DA)
    local Mine = JigOf(GuestPawn(G))
    if not (DA and Mine) then return end
    local Inv = S.Cnt and On("build_ghostfix") and GhostInv(G)
    local Now = Inv and CountOf(Inv, DA)
    if Now and Now > S.Cnt then
        local Out = {}
        local Res = A.Safe(function() return Inv:ServerFindThenConsumeByItemID(DA, 1, Out) end)
        if not (Res == true or Out.Result == true) then return end
        local ok, err = pcall(OW.AddItem, Mine, DA, 1, true)
        if not ok then return Core.Fail("build_ghostfix", err) end
        LogOnce("gf" .. S.Cls, "Abbau %s: Item lag beim Geist - an %s verschoben", S.Cls, tostring(G.PawnName))
        return
    end
    if Inv then
        LogOnce("ok" .. S.Cls, "Abbau %s durch %s: Geist bekam nichts (Owner-Umleitung greift)", S.Cls, tostring(G.PawnName))
    end
    if S.GCnt and On("build_pickinv") then
        local Have = CountOf(Mine, DA)
        -- nur Bodenobjekte, die seit dieser Interaktion entstanden sind (wie Brunnen): keine alten/fremden Stapel
        local IAt = S.IAt or os.clock()
        if Have and Have <= S.GCnt and OW.GroundToInv(G, DA, 1, "Abbau " .. S.Cls, os.clock() - IAt + 0.5) == 0 then
            -- Bodenobjekt evtl. erst einen Takt spaeter da: einmal nachsehen (Item frisch holen, nie ueber Ticks halten)
            Later(1.2, function()
                local DA2 = FindAsset(S.DA)
                if DA2 then OW.GroundToInv(G, DA2, 1, "Abbau " .. S.Cls, os.clock() - IAt + 0.5) end
            end)
        end
    end
end

local function GhostStep(G, S)
    local ok, R = pcall(GhostCheck, G, S)
    if not ok then
        S.Busy = false
        return Core.Fail("build_ghostfix", R)
    end
    if R == "wait" and os.clock() < S.Until then
        Later(0.5, function() GhostStep(G, S) end)   -- Abbau mit Haltezeit (Pickup(false)) laeuft noch
        return
    end
    S.Busy = false
    if R ~= "wait" and B.Snap[G.Key] == S then B.Snap[G.Key] = nil end
end

local function GhostQueue(G, Path)
    local S = B.Snap[G.Key]
    -- Schnappschuss hoechstens 60 s alt (vorher 300 s: fremde Zugaenge beim Geist wurden diesem Gast zugeschrieben)
    if not S or S.Busy or S.Path ~= Path or os.clock() - S.At > 60 then return end
    if not (On("build_ghostfix") or On("build_pickinv")) then return end
    S.Busy, S.Until, S.IAt = true, os.clock() + 8, os.clock()
    Later(0.5, function() GhostStep(G, S) end)
end

local function HostInteract()
    local Q = B.IQ
    if #Q == 0 then return end
    B.IQ = {}
    Q = OW.KcSplit(Q)   -- Runde 8: Karten-/Hangartueren (Ev.Kc) vorab, auch ohne build2-Cap des Gasts
    for _, Ev in ipairs(Q) do
        local G = Ev.Comp and GuestOfComp(Ev.Comp)
        local Path = PathOf(Ev.Act)
        if Ev.IdxQ and Path then
            local okQ, errQ = pcall(OW.IdxLate, G, Ev.Act, Path)
            if not okQ then Core.Fail("build_idxfull", errQ) end
        elseif Ev.Denied and G and Path then
            LogOnce("hn" .. Path, "Interaktion mit fremdem Bau gesperrt (Lua): %s durch %s", Path, tostring(G.PawnName))
        end
        -- Runde 9 (claim_ownpick): Fehler aus dem Hook hier melden, Hinweis an den Gast (gedrosselt)
        if Ev.ModErr then Core.Fail("claim_ownpick", Ev.ModErr) end
        if Ev.ModNo and G and Throttle("modno" .. G.Key, 3) then
            OW.Note(G, "Nicht dein Bauteil - Aufheben/Ersetzen nicht erlaubt", true)
        end
        if G and Path and not Ev.Denied then GhostQueue(G, Path) end
        -- eigene Interaktion des Hosts (kein Gast-Komponente) mit Schlaf-Option merken -> OW.HostSleepCleanup laesst sie
        if not G and Path and Ev.Comp and (Ev.Opt or ""):match("Option[13]$") then B.HostSlp = { Path = Path, At = Ev.At } end
        local Obj = G and Path and StaticFindObject(Path)
        if G and A.IsAlive(Obj) and Net.Has(CAP, G) then
            local Key, Cls = KeyOf(Obj)
            local Opt = Ev.Opt or ""
            -- Runde 7: gesperrte Kiste/Zelt (Schloss, fremder Claim) -> keine Umbenennen-/Aufheben-Fenster
            local Allowed = Ev.Denied ~= true and A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) ~= false
            if Key and Cls == "BP_KeypadDoor_C" and On("build_keypad") then
                -- Das Spiel baut das Tastenfeld beim Host (CreateWidget, Distanz < 500) -> beim Gast oeffnen
                local Open = A.Safe(function() return Obj["Open?"] or Obj["OpenedInThisInstance?"] end, true)
                local Pawn = GuestPawn(G)
                local PX, PY, PZ
                if Pawn then PX, PY, PZ = Loc(Pawn) end
                local X, Y, Z = Loc(Obj)
                if not Open and PX and X and Dist(PX, PY, PZ, X, Y, Z) < 500 then
                    -- Runde 9 (BUILD-25): echter Code (b_st "k" verteilt ihn ohnehin an alle; Welt-Codes findet man
                    -- im Spiel auf Zetteln) - der Platzhalter (KpMask) ist entfernt. Der Host prueft b_code weiter
                    local Real = A.Safe(function() return Obj.Code end, 0)
                    UiSend(G, "kp|" .. Enc(Key) .. "|" .. tostring(Real))
                    -- Runde 8 (build_kpclean): OnServerExecuteInteract @026e-@0465 baut das KeypadUI auch beim Host
                    -- (AddToViewport, DisableInput/Mauszeiger ueber GetPlayerController(0)) -> dort wieder schliessen
                    if On("build_kpclean") then Later(0.3, function() OW.KpClean(Path, G.PawnName) end) end
                end
            elseif Key and Allowed and On("build_sleep") and ((Opt:match("Option1$") and (IsA(Obj, P.BED)
                or IsA(Obj, P.BAG))) or (Opt:match("Option3$") and IsA(Obj, P.TENT))) then
                -- UE 5.6: Bett/Schlafsack @019e -> BedComponent->GoToBed(1930, 630) (Uhrzeit, dann GetGameHUD(self)->
                -- ShowSleepWidget), Zelt @0bf1 -> GetGameHUD->ShowSleepWidget: alles beim Host-HUD -> beim Gast oeffnen
                -- (OW.GuestSleep; ls_world meldet w_sleep)
                UiSend(G, "slp|" .. Enc(Key))
                Log("Schlaf-Fenster an %s geschickt (%s)", tostring(G.PawnName), tostring(Cls))
                -- 5.3-Bett (ohne BedComponent): Create(self, SleepingUI_C) in Obj.SleepUI -> eigener Aufraeumweg.
                -- 5.6 hat kein Buildable_Bed_C.SleepUI mehr: Bett laeuft wie Schlafsack/Zelt ueber HUD.SleepUI
                local IsBed = IsA(Obj, P.BED) and not A.IsAlive(A.Safe(function() return Obj.BedComponent end))
                Later(0.3, function() OW.HostSleepCleanup(Path, IsBed, Key, G.PawnName) end)
            elseif Key and Allowed and (IsA(Obj, P.CONTAINER) or (On("build_tent") and IsA(Obj, P.TENT))) then
                -- Zelt: kein Umbenennen (Option2 ist dort etwas anderes), nur Aufheben mit Inhalt (Option4)
                if Opt:match("Option2$") and On("build_rename") and IsA(Obj, P.CONTAINER) then
                    UiSend(G, "ren|" .. Enc(Key))
                elseif Opt:match("Option4$") and On("build_crate") then
                    -- Leer: das Spiel hebt selbst auf. Mit Inhalt: Ja/Nein-Fenster beim Host -> beim Gast fragen
                    Later(0.4, function()
                        if Fresh({ Path = Path }) then UiSend(G, "yn|" .. Enc(Key)) end
                    end)
                    -- Runde 9 (build_polish): @0d0b YesAndNoUI liegt unsichtbar im Viewport des Geists -> schliessen
                    if On("build_polish") then Later(0.6, function() OW.YnClean(G.PawnName) end) end
                end
            end
            -- Runde 9 (build_polish, BUILD-28): Generator Option3 @0e9e schaltet die Reichweiten-Kugel nur beim Host
            if Key and Allowed and Opt:match("Option3$") and On("build_polish") and IsA(Obj, P.GEN) then
                UiSend(G, "gsph|" .. Enc(Key))
            end
            -- Runde 8: Stationsfenster merken (build_stationlock), Brunnen-Befuellung ins Inventar (build_pickinv)
            -- nur fuer erlaubte Interaktionen (gesperrter fremder Bau: kein Stationshalten, kein Brunnen-Einsammeln)
            if Allowed then
                local okR, errR = pcall(OW.HostInteractR8, G, Obj, Opt, Ev)
                if not okR then Core.Fail("build_pickinv", errR) end
            end
        end
    end
end

local function RunLater(Now)
    if #B.Later == 0 then return end
    local Keep = {}
    for _, L in ipairs(B.Later) do
        if Now >= L.At then
            local ok, err = pcall(L.Fn)
            if not ok then Log("Nachlauf: %s", tostring(err)) end
        else
            Keep[#Keep + 1] = L
        end
    end
    B.Later = Keep
end

-- Gast-Anfrage: Objekt in Reichweite? (Rueckgabe Obj, Pawn)
local function NearObj(G, Key, Kind, Free)
    if not Free and not Throttle(Kind .. G.Key, 0.2) then return nil end
    local Pawn = GuestPawn(G)
    local Obj = Pawn and Resolve(Key)
    if not Obj then return nil end
    local PX, PY, PZ = Loc(Pawn)
    local X, Y, Z = Loc(Obj)
    if not (PX and X) or Dist(PX, PY, PZ, X, Y, Z) > USE_DIST then
        Net.SecWarn(G, G.Key, Kind .. "_dist")
        return nil
    end
    return Obj, Pawn
end

-- b_foc: nur den letzten Fokus je Gast merken (mehrere in einem Takt duerfen den letzten nicht wegdrosseln)
local function OnFocus(Data, G)
    if Net.Side ~= "host" then return end
    B.Foc[G.Key] = { Key = Dec(Data), At = os.clock() }   -- Runde 7: Ziel fuer /lock /code /owner
    if not On("build_owner") or Data == "" then return end
    B.FocQ[G.Key] = { G = G, Key = Dec(Data) }
end

-- Fast-Takt (100 ms): hoechstens ein Fokus je Gast
local function HostFocus()
    if next(B.FocQ) == nil then return end
    local Q = B.FocQ
    B.FocQ = {}
    for _, F in pairs(Q) do
        local Obj, Pawn = NearObj(F.G, F.Key, "b_foc", true)
        -- Runde 7: kein Owner fuer Fremde (Owner = Netz-Besitzer -> Svr_Spawn-RPC des Baus waere fuer ihn offen)
        if Obj and A.Safe(function() return OW.ObjAccess(F.G.GuestId, Obj) end, true) == false then
            OW.DropOwner(Obj, Pawn)
            Obj = nil
        end
        -- Runde 9 (claim_ownpick, BUILD-7): reines Bauteil (Wand, Fundament ...) eines Fremden - kein Owner-Trick
        -- (Owner = Netz-Besitzer -> Svr_Spawn/Ersetzen-RPC des Baus offen); Tueren/Stationen behalten ihn (Benutzung)
        if Obj and A.Safe(function() return OW.ModNoOwner(F.G, Obj:GetFullName()) end, false) == true then
            OW.DropOwner(Obj, Pawn)
            Obj = nil
        end
        -- Runde 8 (build_stationlock): Station mit offenem Fenster eines anderen Gasts (<= 120 s, <= 400 uu) nicht
        -- umhaengen - sonst verwirft der Host dessen SERVER_RequestConsumeItem (Muelleimer @00a6, Fehlerklasse B)
        if Obj and A.Safe(function() return OW.StationHeld(Obj, F.G) end, false) == true then Obj = nil end
        if Obj and OwnTarget(Obj) then
            -- wie OnBeginInteract in SP: SetOwner(InteractingActor); fuer alle Bauten, damit Abbau/Verbrauch beim
            -- Host ueber die Owner-Kette den Gast trifft (GetPlayerCharacter(0)-Umleitung der DLL)
            local ok, err = pcall(function() Obj:SetOwner(Pawn) end)
            if not ok then
                Core.Fail("build_ownall", err)
            else
                local Nm = A.Safe(function() return Obj:GetFullName() end)
                if Nm then B.OwnT[Nm] = { Key = F.G.Key, Gid = F.G.GuestId } end
                local Cls = ClsName(Obj) or "?"
                LogOnce("own" .. Cls, "Owner %s -> %s (Anschauen)", Cls, tostring(F.G.PawnName))
                local ok2, err2 = pcall(GhostSnap, F.G, Obj)
                if not ok2 then Core.Fail("build_ghostfix", err2) end
            end
        end
    end
end

-- Dietriche des Gasts im Server-Inventar (MainJigContainers der Host-Kopie; beim Gast ist es leer). nil = unlesbar
function OW.Lockpicks(Pawn)
    local DA, Inv = FindAsset(P.LOCKPICK), JigOf(Pawn)
    if not (DA and Inv) then return nil end
    return CountOf(Inv, DA), Inv, DA
end

-- b_lpq: Gast startet das Minispiel -> Start merken (Mindestdauer fuer b_unlock), Dietrich-Zahl zurueck (Gast-Patch)
local function OnLpq(Data, G)
    if Net.Side ~= "host" or not On("build_lock") then return end
    local Key = Dec(Data)
    local Obj, Pawn = NearObj(G, Key, "b_lpq")
    if not Obj then return end
    B.PickStart[G.Key] = { Key = Key, At = os.clock() }
    local N = OW.Lockpicks(Pawn)
    UiSend(G, "lp|" .. Enc(Key) .. "|" .. tostring(N or 0))
end

-- b_lpk: Dietrich beim Gast zerbrochen (BreakLockpick @026d verbraucht nur lokal auf leerem MainJigContainers)
local function OnLpk(Data, G)
    if Net.Side ~= "host" or not On("build_lock") then return end
    local Key = Dec(Data)
    local Obj, Pawn = NearObj(G, Key, "b_lpk")
    if not Obj then return end
    if not Throttle("lpk" .. G.Key, 1.0) then return Net.SecWarn(G, G.Key, "b_lpk_rate") end
    local N, Inv, DA = OW.Lockpicks(Pawn)
    if N and N > 0 then
        local Out = {}
        local Res = A.Safe(function() return Inv:ServerFindThenConsumeByItemID(DA, 1, Out) end)
        Log("Dietrich von %s zerbrochen - verbraucht (%s)", tostring(G.PawnName),
            (Res == true or Out.Result == true) and "ok" or "Fehler")
        N = OW.Lockpicks(Pawn)
    end
    UiSend(G, "lp|" .. Enc(Key) .. "|" .. tostring(N or 0))
end

local function OnUnlock(Data, G)
    if Net.Side ~= "host" or not On("build_lock") then return end
    local Key = Dec(Data)
    local Obj, Pawn = NearObj(G, Key, "b_unlock")
    if not Obj or not A.Safe(function() return Obj["IsLocked?"] end, false) then return end
    -- Das Minispiel laeuft nur beim Gast: Start (b_lpq) >= 1,5 s vorher (Erfolg hat im Spiel 2 s Delay), hoechstens
    -- 1 Entsperrung je 5 s, mindestens 1 Dietrich im Server-Inventar (locks_pickcheck=0: alter Stand)
    if Core.Flag("locks_pickcheck", true) then
        local S, Now = B.PickStart[G.Key], os.clock()
        if not (S and S.Key == Key and Now - S.At >= 1.5 and Now - S.At <= 600) then
            Log("Schloss-Knacken von %s abgelehnt (kein Minispiel-Start / zu schnell)", tostring(G.PawnName))
            return Net.SecWarn(G, G.Key, "b_unlock")
        end
        if not Throttle("unlk" .. G.Key, 5) then
            Log("Schloss-Knacken von %s abgelehnt (zu schnell hintereinander)", tostring(G.PawnName))
            return Net.SecWarn(G, G.Key, "b_unlock_rate")
        end
        local N = OW.Lockpicks(Pawn)
        if N == nil then
            LogOnce("lpcnt", "Dietrich-Zaehlung beim Host nicht moeglich - Pruefung uebersprungen")
        elseif N < 1 then
            Log("b_unlock ohne Dietrich von %s abgelehnt", tostring(G.PawnName))
            return OW.Note(G, "Kein Dietrich", true)
        end
        B.PickStart[G.Key] = nil
    end
    if ClsName(Obj) == "BP_LockedDoor_C" then
        -- Tuer oeffnet sich wie beim Gast; Owner = Gast, damit die Spieler-0-Umleitung ihn trifft
        pcall(function() Obj:SetOwner(Pawn) end)
        pcall(function() Obj:LockpickSuccessful() end)
    else
        pcall(function() Obj["IsLocked?"] = false end)
        -- Kiste (BP_MASTER_PicklockContainer_C.LockpickSuccessful @02a3-0466): SetInspected, StartRefillTimer und
        -- AddXP_Scavenging(4-6)/AddXP_Thief(40-60) liefen nur beim Gast (vom Host-Spiegel ueberschrieben). Nicht die
        -- ganze Funktion: OpenContainer @0494 baut das Kisten-Fenster beim Host -> Teile einzeln auf der Host-Kopie,
        -- XP direkt auf die PassiveSkills des Gast-PCs (wie ls_world Angeln)
        local CJ = Core.Flag("build_lpxp", true) and A.Safe(function() return Obj.BP_JigMultiplayer end) or nil
        if A.IsAlive(CJ) then
            pcall(function() Obj:SetInspected(true) end)
            pcall(function() CJ:StartRefillTimer(false) end)
            local PC = Net.PC(G)
            local PS = PC and A.Safe(function() return PC.PassiveSkillsComponent end)
            if A.IsAlive(PS) then
                local S1, S2 = 4 + math.random() * 2, 40 + math.random() * 20
                local ok, err = pcall(function()
                    PS:AddXP_Scavenging(S1)
                    PS:AddXP_Thief(S2)
                end)
                if ok then
                    Log("Schloss-XP fuer %s: Pluendern +%.0f, Dieb +%.0f", tostring(G.PawnName), S1, S2)
                else
                    Core.Fail("build_lpxp", err)
                end
            end
        end
    end
    Log("Schloss geknackt von %s", tostring(G.PawnName))
end

local function OnCode(Data, G)
    if Net.Side ~= "host" or not On("build_keypad") then return end
    local Key, Code = Data:match("^([^|]*)|(%d+)$")
    if not Key then return Net.SecWarn(G, G.Key, "b_code") end
    local Obj, Pawn = NearObj(G, Dec(Key), "b_code")
    if not Obj then return end
    -- Runde 7: Fehlversuche je Spieler und je Tuer begrenzen (Besitzer/Clan nur je Spieler)
    local Gid = OW.GidOk(G.GuestId) and G.GuestId or ("g" .. tostring(G.Key))
    local K, Cls, X, Y, Z = KeyOf(Obj)
    local OK = K and OW.Find(Cls, X, Y, Z, K)
    local Owner = OK and O.Own[OK]
    local LockK = not (Owner and OW.Allied(Gid, Owner)) and K or nil
    local Why = OW.CodeBlocked(Gid, LockK)
    if Why then return OW.Note(G, Why, true) end
    if tonumber(Code) == A.Safe(function() return Obj.Code end) then
        -- Owner = Gast: CorrectCode -> Event_OpenDoor @0d22 GetLevellingComponent(self) (Spieler-0-Umleitung ueber
        -- die Owner-Kette) gibt die Stufe*200-XP sonst dem Geist (wie BP_LockedDoor_C in OnUnlock)
        if Core.Flag("build_kpown", true) then pcall(function() Obj:SetOwner(Pawn) end) end
        pcall(function()
            Obj.CurrentActor = Pawn
            Obj:CorrectCode()
        end)
    else
        OW.CodeBad(Gid, LockK, Owner)
        pcall(function() Obj:IncorrectCode() end)
    end
end

local function OnName(Data, G)
    if Net.Side ~= "host" or not On("build_rename") then return end
    local Key, Name = Data:match("^([^|]*)|(.*)$")
    if not Key then return Net.SecWarn(G, G.Key, "b_name") end
    Name = Dec(Name):gsub("[%c]", ""):sub(1, 40)
    local Obj = NearObj(G, Dec(Key), "b_name")
    if not Obj or not IsA(Obj, P.CONTAINER) then return end
    if A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) == false then
        return OW.Note(G, "Kein Zugriff - fremde Kiste", true)
    end
    if Name == "" then Name = "Container" end
    pcall(function() Obj:OverrideBuildName(FText(Name)) end)
end

-- Kiste mit Inhalt aufheben (nach Ja beim Gast): wie PickupContainer, aber ohne Spieler-0-Weg
local function OnPick(Data, G)
    if Net.Side ~= "host" or not On("build_crate") then return end
    local Obj, Pawn = NearObj(G, Dec(Data), "b_pick")
    if not Obj or not (IsA(Obj, P.CONTAINER) or (On("build_tent") and IsA(Obj, P.TENT))) then return end
    if A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) == false then
        return OW.Note(G, "Kein Zugriff - fremde Kiste", true)
    end
    -- Aufheben = Abbauen: wie Ersetzen nur Besitzer/Clan (bzw. herrenlos ausserhalb fremder Claims)
    if A.Safe(function() return OW.CanModify(G.GuestId, Obj) end, true) == false then
        Log("Kiste aufheben von %s verweigert (fremdes Eigentum)", tostring(G.PawnName))
        return OW.Note(G, "Nicht deine Kiste - Aufheben nicht erlaubt", true)
    end
    local DA = A.Safe(function() return Obj.PickupDataAsset end)
    local Inv = A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not (A.IsAlive(DA) and A.IsAlive(Inv)) then return end
    -- DropAllItems -> JigMP_OnRequestDropItem (Buildable_MASTER_C @000a/@0162) spawnt den Inhalt an
    -- GetPlayerCharacter(0): Owner = Gast -> Umleitung auf den Gast
    if On("build_dropown") then
        local ok, err = pcall(function() Obj:SetOwner(Pawn) end)
        if not ok then Core.Fail("build_dropown", err) end
    end
    OW.DropAll(Obj)
    local ok = pcall(OW.AddItem, Inv, DA, 1, true)
    if ok then pcall(function() Obj:K2_DestroyActor() end) end
    Log("Kiste aufgehoben von %s (%s)", tostring(G.PawnName), ok and "ok" or "Fehler")
end

-- ---------------------------------------------------------------- Host: Zustaende veroeffentlichen
local function ReadState(Obj, Spec, Key)
    local T = Spec.T
    if Spec.Bk and not On("build_bunker") then return nil end
    if T == "bs" then
        -- Runde 9 (build_bunker): Scanner Unlocked?/KeycardRequired? (MC_CallInteract @060f/@061a laeuft nur beim Host)
        return string.format("bs;%d;%d", Obj["Unlocked?"] == true and 1 or 0, Obj["KeycardRequired?"] == true and 1 or 0)
    elseif T == "d" then
        local V = Obj[Spec.P] == true
        if Spec.Inv then V = not V end
        -- Runde 8: 3. Feld = XPGiven? (Karten-/Hangartuer, build_kcard) bzw. Richtung DotProduct >= 0 (build_doordir);
        -- alte Gaeste lesen nur das 2. Feld
        if Spec.Xp and On("build_kcard") then
            return string.format("d;%d;%d", V and 1 or 0, Obj["XPGiven?"] == true and 1 or 0)
        elseif Spec.Dot and On("build_doordir") then
            return string.format("d;%d;%d", V and 1 or 0, (tonumber(Obj.DotProduct) or 0) >= 0 and 1 or 0)
        end
        return "d;" .. (V and 1 or 0)
    elseif T == "dl" then
        local Open = not (Obj[Spec.P] == true)
        return string.format("dl;%d;%d", Open and 1 or 0, Obj["IsLocked?"] == true and 1 or 0)
    elseif T == "k" then
        local S = string.format("k;%d;%d", Obj["Open?"] == true and 1 or 0, tonumber(Obj.Code) or 0)
        -- Runde 8 (build_kcard): 4. Feld XPGiven? (BP_KeypadDoor_C 0x329)
        if On("build_kcard") then S = S .. ";" .. (Obj["XPGiven?"] == true and 1 or 0) end
        return S
    elseif T == "l" then
        return "l;" .. (Obj["IsLocked?"] == true and 1 or 0)
    elseif T == "n" then
        -- Runde 9: ";" im Namen wird "," (Feldtrenner; das 3. Feld ist die Gegenstands-Zahl)
        local S = "n;" .. (tostring(Obj.ContainerName:ToString()):gsub(";", ","))
        -- Runde 9 (build_polish, BUILD-28): 3. Feld = Zahl der Gegenstaende (UpdateStorageStat @06d0 zaehlt beim Gast
        -- die leere lokale Kopie); nur wenn alle Gaeste es lesen koennen (Cap bcnt, sonst stuende es im Namen) und
        -- nur fuer Kisten, die gerade ein Gast anschaut (b_foc) - kein GetContainerItems je Kiste und Sekunde
        if B.CntOk and Key and B.CntKeys and B.CntKeys[Key] then
            local N = OW.BoxCount(Obj)
            if N then S = S .. ";" .. N end
        end
        return S
    elseif T == "v" then
        return OW.DisplayState(Obj)   -- Runde 9 (build_display, BUILD-19): Vitrine
    elseif T == "h" then
        return string.format("h;%d;%d", Obj["HordeStarted?"] == true and 1 or 0, tonumber(Obj.CurrentWave) or 0)
    elseif T == "t" then
        local Cls = ClassObj(P.TURRET)
        local C = Cls and Obj:GetComponentByClass(Cls)
        if not A.IsAlive(C) then return nil end
        return string.format("t;%d;%d;%d", tonumber(C["Current Ammo"]) or 0, tonumber(C["Current Health"]) or 0,
            C.Dead == true and 1 or 0)
    end
    return nil
end

local function HostStates()
    if not On("build_state") then return end
    -- Runde 9 (build_perf, BUILD-23): jeder 2. Durchlauf ueberspringt Eintraege, die sich 30 s nicht geaendert haben
    local Perf, Now = On("build_perf"), os.clock()
    B.StPass = (B.StPass or 0) + 1
    local Skip = Perf and B.StPass % 2 == 0
    B.CntOk = On("build_polish") and Net.Has("bcnt")
    if B.CntOk then
        -- build_polish: Kisten, die ein Gast gerade anschaut (letzter b_foc; Wegschauen schickt "")
        local Ks = {}
        for _, F in pairs(B.Foc) do
            if F.Key and F.Key ~= "" and Now - (F.At or 0) < 600 then
                Ks[F.Key] = true   -- Roh-Schluessel behalten (Kiste evtl. noch nicht im Index)
                if not B.H.ByKey[F.Key] then
                    -- Gast-Schluessel kann je Achse um 1 abweichen (Spawn-Position auf 0,1 gerundet repliziert):
                    -- naechster Index-Eintrag derselben Klasse <= 3 uu (nur Lua, kein UObject-Zugriff)
                    local Cls, X, Y, Z = ParseKey(F.Key)
                    local HK, BestD
                    for _, C in ipairs(Cls and B.H.ByCls[Cls] or {}) do
                        local D = Dist(C.X, C.Y, C.Z, X, Y, Z)
                        if D <= 3 and (not BestD or D < BestD) then HK, BestD = C.Key, D end
                    end
                    if HK then Ks[HK] = true end
                end
            end
        end
        B.CntKeys = Ks
    end
    for _, E in pairs(B.H.ByName) do
        if E.Spec and not (Skip and E.StAt and Now - E.StAt > 30 and not (B.CntOk and B.CntKeys[E.Key])) then
            local Obj = Fresh(E)
            if Obj then
                local ok, V = pcall(ReadState, Obj, E.Spec, E.Key)
                if ok and V then
                    if V ~= E.StV then E.StV, E.StAt = V, Now end
                    Net.State("b_st", E.Key, V, 1)
                end
            end
        end
    end
end

-- Gebaeude-HP: reihum 60 Bauten je Sekunde, gemeldet wird nur, was unter dem Hoechstwert liegt (OW.MaxHp)
local function HostHp()
    if not On("build_hp") then return end
    -- build_perf: sortierte Liste nur neu, wenn IndexAdd/IndexDrop sie verworfen haben (B.HpList = nil)
    local List = On("build_perf") and B.HpList or nil
    if not List then
        List = {}
        for _, E in pairs(B.H.ByName) do if E.Grp == MASTER then List[#List + 1] = E end end
        table.sort(List, function(X, Y) return X.Key < Y.Key end)
        B.HpList = List
    end
    local N = #List
    if N == 0 then return end
    for I = 1, math.min(60, N) do
        B.HpPos = B.HpPos % N + 1
        local E = List[B.HpPos]
        local Obj = Fresh(E)
        local Hp = Obj and A.Safe(function() return tonumber(Obj.Health) end)
        if Hp then
            local Max = OW.MaxHp(E, Obj, Hp)
            Net.State("b_hp", E.Key, Hp < Max - 0.5 and string.format("%.0f;%.0f", Hp, Max) or nil, 2)
        end
    end
end

-- ---------------------------------------------------------------- Host: Bett / Spawnpunkt
-- Runde 9 (BUILD-24): Speichern/Wiederherstellen des Spawnpunkts gehoert ls_player (bed_v2, <Id>.spawn.txt);
-- ls_build_beds.txt, b_bed und Coop.Build.BedFor sind entfernt. Hier bleibt nur der Hinweis "Spawn point set"
-- (SP: Hinweis am Host-HUD, BUILD-13), wenn sich RespawnLoc aendert - nicht in den ersten 30 s nach dem Beitritt
-- (ls_player stellt den gespeicherten Punkt wieder her) und nicht bei der ersten Beobachtung
local function HostBeds()
    if not On("build_bed") then return end
    local Now = os.clock()
    Net.ForEachGuest(function(G)
        local PC = Net.PC(G)
        if not PC then return end
        local V = ""
        if A.Safe(function() return PC.RespawnPointEnabled end, false) then
            V = A.Safe(function()
                local T = PC.RespawnLoc.Translation
                return string.format("%.0f;%.0f;%.0f", T.X, T.Y, T.Z)
            end) or ""
            if V == "0;0;0" then V = "" end
        end
        local Old = B.BedSeen[G.Key]
        B.BedSeen[G.Key] = V
        if Old == nil or Old == V or V == "" or Now - (B.BedJoin[G.Key] or 0) < 30 then return end
        if Net.Has(CAP, G) then
            Net.Send("b_note", "Spawn point set", G, 1)
            Log("Spawnpunkt %s: %s", tostring(G.PawnName), V)
        end
    end)
end

-- ---------------------------------------------------------------- Runde 7: Besitz, Claims, Schloesser, Raids (Host)
-- owners.txt (A.ModDir, atomar): "O|<Schluessel>|<GuestId>" Besitzer, "L|<Schluessel>|<Code>" Schloss,
-- "C|<Schluessel>|<GuestId>" Claim (Basis-Marker), "N|<GuestId>|<Name>", "W|<GuestId>|<n>" Raid-Warnungen (offline).
-- Schluessel = Klasse@X,Y,Z (KeyOf, gerundet); nach dem Laden der Welt per Klasse + Abstand <= MATCH_DIST (OW.Find).
-- Rechte (OW.Access): Besitzer/Clan (Coop.Clan.Allied) und eigener/Clan-Claim immer; Schloss oder fremder Claim ->
-- nur mit /code (10 min). Durchsetzung: DLL-Sperrliste (Native.SetDeny, 0,5 s) fuer SERVER_ForwardInteract (Actor),
-- Kisten-RPCs (OW.BOX_RPC: RequestData, MoveItem From/To, Split/Stack/Drop/Remove). Bauen im fremden Claim:
-- VerifyEntry entfernt den Bau ohne Verbrauch. Raids: ApplyDamage-Ereignisse (cb_dmg aus ls_combat, sonst own_dmg).
local MARKER = "Buildable_BaseMarker_C"
local DENY_R, DENY_MAX = 1500, 96          -- uu / Objekte je Gast
local DMG_FUNC = "/Script/Engine.GameplayStatics:ApplyDamage"
local RAID_DEF = { explosive = 1.0, melee = 0.1, firearm = 0, fire = 0.2 }
local KIND_CLS = {
    { "explosive", "/Game/Blueprints/Throwables/BP_MasterThrowable.BP_MasterThrowable_C" },
    { "explosive", "/Game/Inventory/Items/Other/ItemProjectiles/BP_ProjectileMaster.BP_ProjectileMaster_C" },
    { "melee", "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C" },
    { "firearm", "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C" },
}
local LOCK_CMDS = { lock = true, unlock = true, code = true, claim = true, unclaim = true, owner = true }

function OW.GidOk(V) return type(V) == "string" and #V <= 64 and V:match("^[%w_%-]+$") ~= nil end
function OW.File() return A.ModDir .. "owners.txt" end

function OW.Touch()
    O.Gen, O.Dirty, B.DenySig = O.Gen + 1, true, nil
end

function OW.Load()
    if O.Loaded then return end
    O.Loaded = true
    local N = 0
    for Line in (Core.ReadAll(OW.File()) or ""):gmatch("[^\r\n]+") do
        local T, K, V = Line:match("^(%u)|([^|]+)|(.*)$")
        if T == "O" and ParseKey(K) and OW.GidOk(V) then O.Own[K] = V N = N + 1
        elseif T == "L" and ParseKey(K) and V:match("^%d%d%d%d%d?%d?%d?%d?$") then O.Lock[K] = V
        elseif T == "C" and ParseKey(K) and OW.GidOk(V) then O.Claim[K] = V
        elseif T == "N" and OW.GidOk(K) then O.Names[K] = Dec(V):sub(1, 40)
        elseif T == "W" and OW.GidOk(K) and tonumber(V) then O.Warn[K] = tonumber(V) end
    end
    O.Gen = O.Gen + 1
    if N > 0 then Log("owners.txt: %d Besitz-Eintraege geladen", N) end
end

function OW.Save(Force)
    if not O.Dirty then return end
    OW.Load()
    local Now = os.clock()
    if not Force and Now - O.SavedAt < 2 then return end
    O.SavedAt = Now
    local L = { "# LastSignal Runde 7: Besitz (O), Schloesser (L), Claims (C), Namen (N), Raid-Warnungen (W)" }
    local function Put(T, Tab, Fn)
        local Part = {}
        for K, V in pairs(Tab) do Part[#Part + 1] = T .. "|" .. K .. "|" .. (Fn and Fn(V) or tostring(V)) end
        table.sort(Part)
        for _, S in ipairs(Part) do L[#L + 1] = S end
    end
    Put("O", O.Own) Put("L", O.Lock) Put("C", O.Claim) Put("N", O.Names, Enc) Put("W", O.Warn)
    if Core.WriteAtomic(OW.File(), table.concat(L, "\n") .. "\n") then O.Dirty = false end
end

-- Positionsindex der Besitz-Schluessel und Claim-Liste (neu bei jeder Aenderung)
function OW.Index()
    OW.Load()
    if O.IdxGen == O.Gen then return end
    O.IdxGen = O.Gen
    local ByCls, Pos, Claims = {}, {}, {}
    local function Add(K)
        if Pos[K] then return end
        local Cls, X, Y, Z = ParseKey(K)
        if not Cls then return end
        Pos[K] = { X = X, Y = Y, Z = Z }
        local L = ByCls[Cls]
        if not L then L = {} ByCls[Cls] = L end
        L[#L + 1] = K
    end
    for K in pairs(O.Own) do Add(K) end
    for K in pairs(O.Lock) do Add(K) end
    for K, Gid in pairs(O.Claim) do
        Add(K)
        local Pt = Pos[K]
        if Pt then Claims[#Claims + 1] = { Key = K, Gid = Gid, X = Pt.X, Y = Pt.Y } end
    end
    O.ByCls, O.Pos, O.Claims = ByCls, Pos, Claims
end

-- Besitz-Schluessel zu Klasse/Position: genau, sonst naechster derselben Klasse <= MATCH_DIST
function OW.Find(Cls, X, Y, Z, Exact)
    OW.Index()
    if Exact and O.Pos[Exact] then return Exact end
    local Best, BestD
    for _, K in ipairs(O.ByCls[Cls] or {}) do
        local Pt = O.Pos[K]
        local D = Dist(Pt.X, Pt.Y, Pt.Z, X, Y, Z)
        if D <= MATCH_DIST and (not BestD or D < BestD) then Best, BestD = K, D end
    end
    return Best
end

-- Index-Eintrag -> Besitz-Schluessel (gecacht je Aenderungsstand)
function OW.EKey(E)
    OW.Index()
    if E.OKGen ~= O.Gen then E.OK, E.OKGen = OW.Find(E.Cls, E.X, E.Y, E.Z, E.Key) or false, O.Gen end
    return E.OK or nil
end

function OW.Remove(K)
    if K and (O.Own[K] or O.Lock[K] or O.Claim[K]) then
        O.Own[K], O.Lock[K], O.Claim[K] = nil, nil, nil
        OW.Touch()
    end
end

function OW.Clan()
    local C = A and A.Coop and A.Coop.Clan
    return type(C) == "table" and C or nil
end

-- gleiche GuestId oder gleicher Clan (Coop.Clan.Allied), Cache je Durchlauf (B.Ally)
function OW.Allied(Ga, Gb)
    if not (Ga and Gb) then return false end
    if Ga == Gb then return true end
    local Pair = Ga < Gb and (Ga .. "|" .. Gb) or (Gb .. "|" .. Ga)
    local V = B.Ally[Pair]
    if V == nil then
        V = false
        local C = OW.Clan()
        if C and type(C.Allied) == "function" then
            local ok, Res = pcall(C.Allied, Ga, Gb)
            V = ok and Res == true
        end
        B.Ally[Pair] = V
    end
    return V
end

function OW.ClaimR() return math.max(1, tonumber(Core.Flag("claim_radius_m", 40)) or 40) * 100 end

-- Claims am Ort (waagerecht): HasOwn = verbuendeter Claim, HasForeign/Foreign = fremder Claim
function OW.ClaimState(Gid, X, Y)
    if not On("claim_on") then return false, false, nil end
    OW.Index()
    local R2 = OW.ClaimR() ^ 2
    local HasOwn, Foreign = false, nil
    for _, C in ipairs(O.Claims) do
        local DX, DY = C.X - X, C.Y - Y
        if DX * DX + DY * DY <= R2 then
            if OW.Allied(Gid, C.Gid) then HasOwn = true elseif not Foreign then Foreign = C end
        end
    end
    return HasOwn, Foreign ~= nil, Foreign
end

-- gueltig nur bis Ablauf UND solange das Schloss noch denselben Code hat (/lock neu, /unlock -> ungueltig)
function OW.CodeValid(Gid, K)
    local T = Gid and K and B.Codes[Gid] and B.Codes[Gid][K]
    return type(T) == "table" and os.time() < T.Until and O.Lock[K] ~= nil and T.Code == O.Lock[K]
end

-- Fehlversuche: je Spieler 5/60 s, je Schloss (LockK) 5/10 min. Rueckgabe Sperrtext oder nil
function OW.CodeBlocked(Gid, LockK)
    local T = os.time()
    local F = B.CodeFail[Gid]
    if F and F.N >= 5 and T - F.T < 60 then return "Zu viele falsche Codes - warte eine Minute" end
    local L = LockK and B.CodeFail["k:" .. LockK]
    if L and L.N >= 5 and T - L.T < 600 then return "Schloss gesperrt (zu viele Fehlversuche) - warte 10 Minuten" end
    return nil
end

function OW.CodeBad(Gid, LockK, Owner)
    local T = os.time()
    local F = B.CodeFail[Gid]
    if not F or T - F.T >= 60 then F = { N = 0, T = T } B.CodeFail[Gid] = F end
    F.N = F.N + 1
    if not LockK then return end
    local L = B.CodeFail["k:" .. LockK]
    if not L or T - L.T >= 600 then L = { N = 0, T = T } B.CodeFail["k:" .. LockK] = L end
    L.N = L.N + 1
    if L.N == 5 then
        Log("Schloss %s nach 5 Fehlversuchen 10 min gesperrt (zuletzt %s)", LockK, OW.NameGid(Gid))
        for _, G2 in pairs(Owner and Net.Guests or {}) do
            if G2.GuestId == Owner then OW.Note(G2, "Jemand versucht, dein Schloss zu knacken!", true) end
        end
    end
end

-- Darf Gid das Bauteil an X/Y mit Besitz-Schluessel K benutzen? (nur Lua-Daten, keine UObjects)
-- Eigener/Clan-Claim gibt nur herrenlose Bauteile frei; fremdes Eigentum: Schloss/fremder Claim -> nur mit /code
function OW.Access(Gid, X, Y, K)
    local Owner = K and O.Own[K]
    if Owner and OW.Allied(Gid, Owner) then return true end
    local HasOwn, HasForeign = OW.ClaimState(Gid, X, Y)
    local Locked = On("locks_on") and K and O.Lock[K]
    if HasOwn and not Owner then return true end
    if Locked then return OW.CodeValid(Gid, K) end
    if HasForeign then return OW.CodeValid(Gid, K) end
    return true
end

-- Actor (nur Buildable_MASTER_C-Kinder) -> Access
function OW.ObjAccess(Gid, Obj)
    if not (On("claim_on") or On("locks_on")) or not IsA(Obj, P.MASTER) then return true end
    local K, Cls, X, Y, Z = KeyOf(Obj)
    if not K then return true end
    return OW.Access(Gid, X, Y, OW.Find(Cls, X, Y, Z, K))
end

-- Ersetzen/Umbauen: Besitzer im Clan, herrenlos nur ausserhalb fremder Claims
function OW.CanModify(Gid, Obj)
    if not On("claim_on") then return true end
    local K, Cls, X, Y, Z = KeyOf(Obj)
    if not K then return true end
    local OK = OW.Find(Cls, X, Y, Z, K)
    local Owner = OK and O.Own[OK]
    if Owner then return OW.Allied(Gid, Owner) end
    local _, HasForeign = OW.ClaimState(Gid, X, Y)
    return not HasForeign
end

-- Bauen am Ort: kein fremder Claim; Basis-Marker: kein fremder Claim im doppelten Radius (Ueberlappung)
function OW.BuildAllowed(Gid, Cls, X, Y)
    if not On("claim_on") or not X then return true end
    local _, HasForeign = OW.ClaimState(Gid, X, Y)
    if HasForeign then return false, "Fremdes Gebiet - hier darfst du nicht bauen (Item bleibt bei dir)" end
    if Cls == MARKER then
        local R2 = (2 * OW.ClaimR()) ^ 2
        for _, C in ipairs(O.Claims) do
            local DX, DY = C.X - X, C.Y - Y
            if DX * DX + DY * DY < R2 and not OW.Allied(Gid, C.Gid) then
                return false, "Gebiet ueberschneidet sich mit einem fremden Claim (Item bleibt bei dir)"
            end
        end
    end
    return true
end

-- Hinweis an einen Gast (note2 von ls_ui, sonst b_note); nur Spiel-Thread
function OW.Note(G, Text, Red)
    if not (G and G.Epoch) then return end
    if Net.Has("ui_note2", G) then
        Net.Send("note2", Enc(Text) .. "||" .. (Red and "1,0.35,0.3,1" or "1,1,1,1") .. "|4|1", G, 0)
    elseif Net.Has(CAP, G) then
        Net.Send("b_note", Text, G, 1)
    end
end

function OW.NameGid(Gid)
    if not Gid then return "?" end
    local Name = O.Names[Gid] or ("Spieler " .. tostring(Gid):sub(1, 4))
    local C = OW.Clan()
    local Clan = C and type(C.ClanOf) == "function" and A.Safe(function() return C.ClanOf(Gid) end)
    if type(Clan) == "string" and Clan ~= "" then Name = Name .. " [" .. Clan .. "]" end
    return Name
end

-- Spielername merken (fuer /owner und Offline-Warnungen); ohne Name: PlayerState fragen (hoechstens alle 10 s)
function OW.LearnName(G, Name)
    local Gid = G and G.GuestId
    if not OW.GidOk(Gid) then return end
    if not Name then
        if os.clock() - (B.NameTry[G.Key] or -1e9) < 10 then return end
        B.NameTry[G.Key] = os.clock()
        local PC = Net.PC(G)
        Name = PC and A.Safe(function()
            local PS = PC.PlayerState
            if not A.IsAlive(PS) then return nil end
            return PS:GetPlayerName():ToString()
        end)
    end
    if type(Name) ~= "string" then return end
    Name = Name:gsub("[%c|]", ""):sub(1, 40)
    if Name ~= "" and O.Names[Gid] ~= Name then
        O.Names[Gid], O.Dirty = Name, true
    end
    if Name ~= "" then B.NameDone[G.Key] = true end
end

-- Neuer Bau (VerifyEntry, Item verbraucht): Besitzer = Gast; Basis-Marker beansprucht das Gebiet
function OW.Placed(G, Obj)
    local Gid = G and G.GuestId
    if not OW.GidOk(Gid) then return end
    OW.Load()
    local K, Cls, X, Y, Z = KeyOf(Obj)
    if not K then return end
    O.Own[K], O.Doubt[K] = Gid, nil
    if Cls == MARKER and On("claim_on") then
        -- Review CO1: Marker-Umzug (< MATCH_DIST) auch unter der Grenze und bei claim_max=0: verbuendete Claims ohne
        -- Marker (O.Doubt) am neuen Ort sofort freigeben - sonst haelt OW.Prune sie ueber die Naehe dauerhaft am Leben
        -- (doppelter bzw. spaeter verwaister Claim). Der Umzug belegt keinen neuen Platz (OW.ClaimFull zaehlt K selbst
        -- nicht); Clan ueber der Grenze (claim_max gesenkt oder Platz im 60-s-Fenster anderweitig belegt) verliert den
        -- umgezogenen Claim. Umgekehrte Reihenfolge (neuer Marker vor dem IndexDrop des alten): OW.Succ in OW.Prune.
        local Moved = false
        OW.Index()
        for _, C in ipairs(O.Claims) do
            local Pt = O.Pos[C.Key]
            if C.Key ~= K and O.Doubt[C.Key] and Pt and OW.Allied(Gid, C.Gid)
                and Dist(Pt.X, Pt.Y, Pt.Z, X, Y, Z) <= MATCH_DIST then
                OW.Remove(C.Key)
                O.Doubt[C.Key] = nil
                Moved = true
                Log("Claim-Umzug von %s: %s -> %s", OW.NameGid(Gid), C.Key, K)
            end
        end
        -- Runde 9 (claim_max, BUILD-11): hoechstens claim_max Claims je Clan; der Marker steht, beansprucht aber nichts
        -- Closeout R3: K selbst nicht mitzaehlen (Neusetzen am selben Ort), Grenze auch nach Nah-Umzug (Moved) pruefen -
        -- der umgezogene Claim war als O.Doubt schon nicht gezaehlt, sein Platz kann inzwischen belegt sein
        local Full, Max, DK = OW.ClaimFull(Gid, K)
        if Full then
            if O.Claim[K] then O.Claim[K] = nil end
            OW.Note(G, "Claim-Grenze erreicht (" .. Max .. ") - Marker steht, beansprucht aber nichts", true)
            Log("Claim von %s bei %s abgelehnt: Grenze %d erreicht", OW.NameGid(Gid), K, Max)
        else
            -- Review 3: Marker-Umzug - alten Claim (Marker weg, Prune ausstehend) sofort freigeben, sonst haelt
            -- Prune ihn bei Neusetzen < 40 uu ueber die Naehe am Leben (doppelter Claim ueber claim_max).
            -- Review CO1: nicht nach einem Nah-Umzug (Moved) - der hat schon einen Claim ersetzt
            if DK and DK ~= K and not Moved then
                O.Claim[DK] = nil
                Log("Claim-Umzug von %s: %s -> %s", OW.NameGid(Gid), DK, K)
            end
            O.Claim[K] = Gid
            OW.Note(G, string.format("Gebiet beansprucht (Radius %d m)", R(OW.ClaimR() / 100)))
            Log("Claim von %s bei %s", OW.NameGid(Gid), K)
        end
    end
    OW.Touch()
end

-- claim_max (BUILD-11): Claims des Clans (verbuendet mit Gid) zaehlen; 0 = unbegrenzt. Fehler -> claim_max aus
-- (Core.Fail; Rueckfall unbegrenzt wie vor Runde 9). SkipK (Closeout R3): Schluessel, der gerade gesetzt bzw.
-- uebergeben wird - zaehlt nie mit (auch nicht als DK0)
function OW.ClaimFull(Gid, SkipK)
    local okF, Full, Max, DK = pcall(function()
        local M0 = math.floor(tonumber(Core.Flag("claim_max", 3)) or 3)
        if M0 <= 0 then return false, 0 end
        local N, DK0 = 0, nil
        for K, Owner in pairs(O.Claim) do
            if K ~= SkipK and OW.Allied(Gid, Owner) then
                if O.Doubt[K] then DK0 = DK0 or K else N = N + 1 end
            end
        end
        -- Review 3: Marker verschwunden (Prune ausstehend, O.Doubt) zaehlt nicht mit; DK0 = Kandidat fuer
        -- Marker-Umzug, nur wenn der neue Claim sonst die Grenze erreicht
        return N >= M0, M0, (N + 1 >= M0) and DK0 or nil
    end)
    if not okF then
        Core.Fail("claim_max", Full)
        return false, 0
    end
    return Full, Max, DK
end

-- Ersetzen (ReplaceDone): Eintraege wandern mit; herrenlos -> Ersetzender wird Besitzer
function OW.Replaced(G, OldK, NewK)
    if OldK and OldK ~= NewK and (O.Own[OldK] or O.Lock[OldK] or O.Claim[OldK]) then
        O.Own[NewK], O.Lock[NewK], O.Claim[NewK] = O.Own[OldK], O.Lock[OldK], O.Claim[OldK]
        O.Own[OldK], O.Lock[OldK], O.Claim[OldK] = nil, nil, nil
        O.Doubt[OldK], O.Doubt[NewK] = nil, nil
        OW.Touch()
    elseif not (OldK and O.Own[OldK]) and G and OW.GidOk(G.GuestId) then
        O.Own[NewK] = G.GuestId
        OW.Touch()
    end
end

-- Nachfolger-Pruefung fuer Besitz-Schluessel K (OW.Prune/OW.Reconcile): lebendig = Bau derselben Klasse <= MATCH_DIST.
-- Review CO1: bei Claims (claim_on) nur, wenn dieser Bau auch auf K aufloest - ein neu gesetzter Marker mit eigenem
-- Eintrag (OW.Placed) ueberholt den alten Claim, sonst haelt die Naehe ihn ewig am Leben (doppelter/Geister-Claim).
-- Rueckgabe: Alive, Nachfolger-Schluessel (nur wenn nicht lebendig)
function OW.Succ(K, Pt)
    local Cls = ParseKey(K)
    if not (Cls and Pt) then return false, nil end
    local Strict = O.Claim[K] ~= nil and On("claim_on")
    local Succ
    for _, C in ipairs(B.H.ByCls[Cls] or {}) do
        if Dist(C.X, C.Y, C.Z, Pt.X, Pt.Y, Pt.Z) <= MATCH_DIST then
            local CK = Strict and OW.EKey(C) or K
            if CK == K then return true, nil end
            Succ = Succ or CK
        end
    end
    return false, Succ
end

-- Review CO1: Marker-Umzug in umgekehrter Reihenfolge (neuer Marker vor dem IndexDrop des alten gesetzt, an der
-- Grenze ohne Claim): Claim von K geht auf den Nachfolger am Ort ueber, wenn der verbuendet ist und selbst keinen hat.
-- Closeout R3: nur, wenn der Clan ohne K unter claim_max liegt (Platz im 60-s-Fenster per /claim o. ae. belegt)
function OW.ClaimHand(K, Succ)
    local Gc = Succ and O.Claim[K]
    if Gc and Succ ~= K and not O.Claim[Succ] and OW.Allied(Gc, O.Own[Succ]) then
        if OW.ClaimFull(Gc, K) then
            Log("Claim-Umzug von %s: %s -> %s abgelehnt (Grenze)", OW.NameGid(Gc), K, Succ)
            return
        end
        O.Claim[Succ] = Gc
        OW.Touch()
        Log("Claim-Umzug von %s: %s -> %s (Nachfolger am Ort)", OW.NameGid(Gc), K, Succ)
    end
end

-- Abgebaute Bauten: Eintrag loeschen, wenn 60 s nach dem Verschwinden kein Bau derselben Klasse am Ort steht.
-- Viele gleichzeitig (Weltwechsel/Neuladen) -> nichts loeschen.
function OW.Prune(Now)
    local N = 0
    for _ in pairs(O.Doubt) do N = N + 1 end
    if N == 0 then return end
    if N > 30 then
        Log("Besitz: %d Bauten gleichzeitig weg - keine Eintraege geloescht", N)
        O.Doubt = {}
        return
    end
    OW.Index()
    for K, T in pairs(O.Doubt) do
        if Now - T >= 60 then
            O.Doubt[K] = nil
            local Pt = O.Pos[K]
            local Alive, Succ = OW.Succ(K, Pt)
            if Pt and not Alive then
                OW.ClaimHand(K, Succ)
                OW.Remove(K)
                Log("Besitz: %s entfernt (abgebaut)", K)
            end
        end
    end
end

-- Bestand des Bau-Items beim Gast (abgelehnter Bau: b_ok "n|<Anzahl>", Baumodus bleibt bei > 0)
function OW.HaveCount(G, Md)
    if Md.PickPath then return Fresh({ Path = Md.PickPath }) and 1 or 0 end
    local Pawn = GuestPawn(G)
    local Inv = Pawn and A.Safe(function() return Pawn.BP_JigMultiplayer end)
    local DA = FindAsset(Md.DA)
    if not (A.IsAlive(Inv) and DA) then return nil end
    local Out = {}
    if not pcall(function() Inv:GetTotalCountOfItem(DA, Out) end) then return nil end
    return tonumber(Out.TotalCount) or 0
end

-- Gesperrtes Objekt gehoert (Owner-Trick) noch dem Fremden -> Owner loesen (sonst Svr_Spawn-RPC = Abbau offen)
function OW.DropOwner(Obj, Pawn)
    if not (A.IsAlive(Obj) and A.IsAlive(Pawn)) then return end
    local Own = A.Safe(function() return Obj:GetOwner() end)
    if A.IsAlive(Own) and A.Safe(function() return Own:GetAddress() == Pawn:GetAddress() end, false) then
        pcall(function() Obj:SetOwner(nil) end)
    end
end

function OW.IsBox(E, Obj)
    if E.Box == nil then E.Box = IsA(Obj, P.CONTAINER) or IsA(Obj, P.TENT) end
    -- Runde 9 (locks_rpcplus, BUILD-17): Stationen mit Inventar (Muelleimer, Werkbaenke, Lagerfeuer) wie Kisten:
    -- Komponente in die Kisten-RPC-Gruppe der Sperrliste, /lock moeglich, Inhalt faellt beim Raid-Abriss
    return E.Box or (OW.STATIONS[E.Cls] == true and Core.Flag("locks_rpcplus", true))
end

-- Tuer/Tor (kein Licht) oder Kiste/Zelt
function OW.IsLockable(E, Obj)
    local S = SPEC[E.Cls]
    if S and S.T == "d" and S.P ~= "LightOn" then return true end
    return OW.IsBox(E, Obj)
end

-- Index-Eintrag: Tuer/Tor oder Kiste/Zelt? (gecacht; Objekt nur einmal frisch holen)
function OW.LockE(E)
    if OW.STATIONS[E.Cls] and Core.Flag("locks_rpcplus", true) then return true end   -- Runde 9: Station wie Kiste
    if E.Lk == nil then
        local S = SPEC[E.Cls]
        if S and S.T == "d" and S.P ~= "LightOn" then
            E.Lk = true
        elseif E.Box ~= nil then
            E.Lk = E.Box
        else
            local Obj = Fresh(E)
            if not Obj then return false end
            E.Lk = OW.IsBox(E, Obj)
        end
    end
    return E.Lk
end

-- DLL-Sperrliste wirkt wirklich (Beobachter aktiv, nicht nach Fehlern aus)
-- Runde 9 (BUILD-22): aus den Status-Feldern der DLL (capable/installed/broken/denyfaults); "denyon" heisst nur
-- "Tabelle nicht leer" (NetTestCore DenyOn) und meldete beim ersten eigenen Schloss falsch "DLL-Sperre inaktiv"
function OW.DenyOk()
    if type(Native.SetDeny) ~= "function" then return false end
    local S = type(Native.Status) == "function" and A.Safe(Native.Status) or nil
    if type(S) == "table" and S.capable ~= nil and S.installed ~= nil then
        return S.capable == 1 and S.installed == 1 and S.broken == 0 and (tonumber(S.denyfaults) or 0) < 3
    end
    if type(Native.DenyActive) ~= "function" then return false end
    local ok, Res = pcall(Native.DenyActive)
    return ok and Res == true
end

-- Owner-Trick (HostFocus/OwnerAtInteract) zuruecknehmen, sobald der Gast kein Recht mehr hat (Clan-Kick,
-- Code abgelaufen, neues Schloss/Claim) - auch ausserhalb seines Sperrfensters (Svr_Spawn = Abbau aus der Ferne)
function OW.OwnSweep()
    for Name, T in pairs(B.OwnT) do
        local E = B.H.ByName[Name]
        local G = Net.Guests[T.Key or ""]
        if not (E and G and G.GuestId == T.Gid) then
            B.OwnT[Name] = nil
        elseif not OW.Access(T.Gid, E.X, E.Y, OW.EKey(E)) or OW.ModNoOwner(G, Name) then
            B.OwnT[Name] = nil
            local Pawn = GuestPawn(G)
            local Obj = Pawn and Fresh(E)
            if Obj then OW.DropOwner(Obj, Pawn) end
        end
    end
end

-- ---------------------------------------------------------------- Runde 7: Sperrliste (DLL, 0,5 s)
-- Kisten-RPCs auf BP_JigComponent_C (UE 5.6; Parameter = Kisten-Komponente); je Kiste zusammen mit ForwardInteract
-- 5.6: SERVER_RequestData-Parameter heisst JigMPCompRef (5.3: JigMpCompRef), die anderen unveraendert
OW.BOX_RPC = {
    { "SERVER_RequestData", "JigMPCompRef" },
    { "SERVER_RequestMoveItemToAnotherComp", "From" }, { "SERVER_RequestMoveItemToAnotherComp", "To" },
    { "SERVER_RequestSplitItem", "FromComp" }, { "SERVER_RequestStackItem", "FromCom" },
    { "SERVER_RequestDropItem", "CompTarget" }, { "SERVER_RequestRemoveItem", "TargetComp" },
}
-- Runde 9 (locks_rpcplus, BUILD-17, a56\bp\BP_JigComponent_C.kdis): Verbrauchen per UID (Kisten und Stationen),
-- Herstellen an der Station (nur Stationen; spart Zeilen im Budget)
OW.BOX_RPC_PLUS = { { "SERVER_RequestConsumeItem", "TargetComp" } }
OW.STATION_RPC_PLUS = { { "SERVER_RequestCraftItem", "CompRef" }, { "SERVER_RequestCraftItemDrop", "CompRef" } }
OW.DENY_BOX_R = 3000     -- uu: Tueren/Kisten weiter als Bauteile (DENY_R)
-- Zeilen gesamt, gleichmaessig auf die Gaeste verteilt. Runde 9 (CAR-8): DLL-Grenze DENY_MAX 256 teilen sich
-- ls_build <= 200, ls_car <= 24 (Kofferraum-Schloesser), ls_combat_mrel + ls_combat_sde <= 32
OW.DENY_LINES = 200

function OW.DenyCompute(Now)
    B.Ally = {}
    local Want = On("claim_on") or On("locks_on")
    local Per, Sig, PPos = {}, {}, {}
    if Want then
        Net.ForEachGuest(function(G, Key)
            local Pawn = GuestPawn(G)
            if not Pawn then return end
            if not B.NameDone[Key] then OW.LearnName(G) end
            local PX, PY, PZ = Loc(Pawn)
            if not PX then return end
            PPos[Key] = { X = PX, Y = PY, Z = PZ }   -- locks_hookfirst: fuer OW.StationHeldLua (Hook)
            local Gid = G.GuestId
            local List = {}
            local BoxR = OW.DENY_BOX_R
            for _, E in pairs(B.H.ByName) do
                if E.Grp == MASTER and math.abs(E.X - PX) <= BoxR and math.abs(E.Y - PY) <= BoxR then
                    local D = Dist(E.X, E.Y, E.Z, PX, PY, PZ)
                    if D <= BoxR and not OW.Access(Gid, E.X, E.Y, OW.EKey(E)) then
                        -- Vorrang: Tueren/Kisten (bis BoxR) vor Bauteilen (bis DENY_R, zaehlen doppelte Distanz)
                        if OW.LockE(E) then List[#List + 1] = { E = E, D = D }
                        elseif D <= DENY_R then List[#List + 1] = { E = E, D = D * 2 } end
                    end
                end
            end
            table.sort(List, function(P1, P2) return P1.D < P2.D end)
            for I = #List, DENY_MAX + 1, -1 do List[I] = nil end
            Per[Key] = { Pawn = Pawn, List = List, G = G }
            local Names = {}
            for _, It in ipairs(List) do Names[#Names + 1] = It.E.Name end
            table.sort(Names)
            Sig[#Sig + 1] = Key .. "@" .. tostring(G.PawnName) .. ":" .. table.concat(Names, ",")
        end)
    else
        -- locks_hookfirst: Gast-Positionen auch ohne Schloesser/Claims (Stationshalten im Interaktions-Hook)
        Net.ForEachGuest(function(G, Key)
            local Pawn = GuestPawn(G)
            local PX, PY, PZ
            if Pawn then PX, PY, PZ = Loc(Pawn) end
            if PX then PPos[Key] = { X = PX, Y = PY, Z = PZ } end
        end)
    end
    B.PPos = PPos
    if Want then OW.OwnSweep() end
    table.sort(Sig)
    local Text = table.concat(Sig, "\n")
    -- unveraendert: hoechstens alle 10 s neu schreiben (Adressen koennen nach Abriss neu vergeben werden)
    if Text == B.DenySig and (Text == "" or Now - B.DenyAt < 10) then return end
    local Entries, Deny = {}, {}
    local FI = P.JIGMP .. ":SERVER_ForwardInteract"
    -- feste Reihenfolge, Zeilen-Budget je Gast begrenzt (sonst verdraengt ein Gast alle anderen)
    local Keys = {}
    for Key in pairs(Per) do Keys[#Keys + 1] = Key end
    table.sort(Keys)
    local Cut = 0
    local Plus = Core.Flag("locks_rpcplus", true)   -- Runde 9 (BUILD-17): weitere Kisten-/Stations-RPCs
    -- Review r9/2 (locks_denyfair): erst je Gast alle Zeilengruppen sammeln (Durchgang 1), dann das Budget nur auf
    -- Gaeste mit Bedarf verteilen, kleinster Bedarf zuerst; Ungenutztes geht an die naechsten (Durchgang 2).
    -- Vorher bekam jeder Gast (auch ohne gesperrte Objekte) DENY_LINES/#Keys -> Raider-Kisten ohne DLL-Sperre.
    local Fair = Core.Flag("locks_denyfair", true)
    local Act = {}
    for _, Key in ipairs(Keys) do
        local Pg = Per[Key]
        local Set, Old = {}, B.Deny[Key] or {}
        Deny[Key] = Set
        Pg.Grps, Pg.Need = {}, 0
        local Jig = A.IsAlive(Pg.Pawn) and A.Safe(function() return Pg.Pawn.BP_JigMultiplayer end)
        for _, It in ipairs(Pg.List) do
            Set[It.E.Name] = true   -- Lua-Sperre (Owner-Trick, HookNull) auch ohne DLL-Zeile
            local Obj = Fresh(It.E)
            if Obj then
                OW.DropOwner(Obj, Pg.Pawn)
                -- neu gesperrte Kiste in Reichweite: die DLL verwirft die Kisten-RPCs ohne CLIENT_MoveToIndexFailed ->
                -- Gast schliesst ein offenes Kistenfenster und gleicht sein Inventar neu ab (OW.DenyUi)
                if not Old[It.E.Name] and It.D <= USE_DIST and Pg.G and Core.Flag("locks_denyui", true)
                    and OW.IsBox(It.E, Obj) then
                    UiSend(Pg.G, "dn|" .. Enc(It.E.Key))
                end
                if A.IsAlive(Jig) then
                    local Grp = { { Func = FI, Context = Jig, Param = "Actor", Value = Obj } }
                    if OW.IsBox(It.E, Obj) then
                        local CJ = A.Safe(function() return Obj.BP_JigMultiplayer end)
                        if A.IsAlive(CJ) then
                            for _, R2 in ipairs(OW.BOX_RPC) do
                                Grp[#Grp + 1] = { Func = P.JIGMP .. ":" .. R2[1], Context = Jig, Param = R2[2], Value = CJ }
                            end
                            if Plus then
                                local L2 = OW.STATIONS[It.E.Cls] and OW.STATION_RPC_PLUS or {}
                                for _, R2 in ipairs(OW.BOX_RPC_PLUS) do
                                    Grp[#Grp + 1] = { Func = P.JIGMP .. ":" .. R2[1], Context = Jig, Param = R2[2], Value = CJ }
                                end
                                for _, R2 in ipairs(L2) do
                                    Grp[#Grp + 1] = { Func = P.JIGMP .. ":" .. R2[1], Context = Jig, Param = R2[2], Value = CJ }
                                end
                            end
                        end
                    end
                    Pg.Grps[#Pg.Grps + 1] = Grp
                    Pg.Need = Pg.Need + #Grp
                end
            end
        end
        if Pg.Need > 0 then Act[#Act + 1] = Key end
    end
    -- Durchgang 2: Zeilen vergeben (Gruppen je Gast in Distanz-Reihenfolge; passt eine nicht, zaehlt sie als Cut)
    local Share = math.floor(OW.DENY_LINES / math.max(1, #Keys))   -- alter Weg: fester Anteil je Gast
    if Fair then
        table.sort(Act, function(K1, K2)
            local N1, N2 = Per[K1].Need, Per[K2].Need
            if N1 ~= N2 then return N1 < N2 end
            return K1 < K2
        end)
        Share = math.floor(OW.DENY_LINES / math.max(1, #Act))
    end
    local Left = OW.DENY_LINES
    for I, Key in ipairs(Act) do
        local Budget = Fair and math.floor(Left / (#Act - I + 1)) or Share
        local Used = 0
        for _, Grp in ipairs(Per[Key].Grps) do
            if Used + #Grp <= Budget then
                for _, En in ipairs(Grp) do Entries[#Entries + 1] = En end
                Used = Used + #Grp
            else
                Cut = Cut + 1
            end
        end
        Left = Left - Used
    end
    if Cut > 0 then
        LogOnce("denycut", "Sperrliste voll: %d Objekte ohne DLL-Eintrag (%d Zeilen je aktivem Gast, %d/%d Gaeste)",
            Cut, Share, #Act, #Keys)
    end
    B.Deny, B.DenySig, B.DenyAt, B.DenyN = Deny, Text, Now, #Entries
    local SetDeny = Native.SetDeny
    if type(SetDeny) ~= "function" then
        if #Entries > 0 then LogOnce("nodeny", "Schloesser/Claims: Native.SetDeny fehlt - nur Lua-Pruefungen aktiv") end
        return
    end
    -- Runde 9 (FIXPLAN 4.4): eigener Besitzer "ls_build" (FlushDeny-Reihenfolge ls_combat, ls_car, ls_build, Rest);
    -- ohne Namen landete die Liste unter "main" hinter allen anderen
    local ok, err = pcall(SetDeny, Entries, "ls_build")
    if not ok and Core.Fail("locks_on", err) then Log("Sperrliste aus: %s", tostring(err)) end
end

function OW.DenyTick(Now)
    if Net.Side ~= "host" or not On() or not CheckWorld() then return end
    local ok, err = pcall(OW.DenyCompute, Now)
    if not ok and Core.Fail("locks_on", err) then Log("Schloesser aus: %s", tostring(err)) end
end

-- ---------------------------------------------------------------- Runde 7: Raids (ApplyDamage-Ereignisse)
-- Wer beobachtet ApplyDamage? Tags (cb_dmg von ls_combat, own_dmg von uns) und ob ein anderes Modul es tut
function OW.DmgWatchers()
    local Tags, Other = {}, false
    for Owner, List in pairs(Native.Watches or {}) do
        for _, W in ipairs(List or {}) do
            if (W.Func or W[1]) == DMG_FUNC then
                Tags[(tostring(W.Tag or W[2] or Owner):gsub("[^%w_]", "_")):sub(1, 31)] = true
                if Owner ~= "ls_build" then Other = true end
            end
        end
    end
    return Tags, Other
end

-- Eigene Beobachtung nur, wenn kein anderes Modul ApplyDamage beobachtet (die DLL nimmt je Funktion eine Zeile;
-- eine zweite Zeile ohne pre=ffblock koennte die von ls_combat verdraengen)
function OW.RaidWatch(Want)
    local _, Other = OW.DmgWatchers()
    local Mine = Native.Watches ~= nil and Native.Watches.ls_build ~= nil
    local Need = Want and not Other
    if Need == Mine then return end
    local ok, err = pcall(Native.SetWatch, Need and { { Func = DMG_FUNC, Tag = "own_dmg", Mode = "observe" } } or nil,
        "ls_build")
    if not ok then return Core.Fail("raid_on", err) end
    Log("Raid: eigene ApplyDamage-Beobachtung %s", Need and "an" or "aus")
end

-- "<Klasse> <Pfad>" -> explosive|melee|firearm|nil (Klasse gecacht, wenn das Objekt lebt)
function OW.KindOf(Full)
    if type(Full) ~= "string" then return nil end
    local Cls, Path = Full:match("^(%S+) (.+)$")
    if not Cls then return nil end
    local K = B.KindByCls[Cls]
    if K ~= nil then return K or nil end
    -- erst nach dem Klassennamen (gilt auch fuer schon zerstoerte Wurfkoerper nach der Explosion)
    if Cls:match("Flare") or Cls:match("NoiseMaker") then
        K = false
    elseif Cls:match("Molotov") then
        K = "fire"
    elseif Cls:match("^BP_Throwable_") or Cls:match("^BP_Projectile") or Cls:match("PipeBomb") or Cls:match("Grenade")
        or Cls:match("Rocket") then
        K = "explosive"
    end
    if K ~= nil then
        B.KindByCls[Cls] = K
        return K or nil
    end
    local Obj = StaticFindObject(Path)
    if not A.IsAlive(Obj) then return nil end
    K = false
    for _, KC in ipairs(KIND_CLS) do
        if IsA(Obj, KC[2]) then K = KC[1] break end
    end
    B.KindByCls[Cls] = K
    return K or nil
end

-- PC (Net.Guests-Schluessel) oder Gastfigur -> Gast
function OW.GuestOfFull(Full)
    if type(Full) ~= "string" then return nil end
    local G = Net.Guests[Full]
    if G then return G end
    local Path = Full:match("^%S+ (.+)$")
    local Name = Path and Path:match("([^%.:]+)$")
    return Name and Net.GuestByPawnName(Name) or nil
end

-- Owner-/Instigator-Kette (Waffe/Wurfkoerper -> Figur/PC), hoechstens 4 Schritte
function OW.ChainGuest(Full)
    local Path = type(Full) == "string" and Full:match("^%S+ (.+)$")
    local Obj = Path and StaticFindObject(Path)
    for _ = 1, 4 do
        if not A.IsAlive(Obj) then return nil end
        local Nxt = A.Safe(function() return Obj:GetOwner() end)
        if not A.IsAlive(Nxt) then Nxt = A.Safe(function() return Obj:GetInstigator() end) end
        if not A.IsAlive(Nxt) then return nil end
        local G = OW.GuestOfFull(A.Safe(function() return Nxt:GetFullName() end))
        if G then return G end
        Obj = Nxt
    end
    return nil
end

function OW.NearestGuest(X, Y, Z, Range)
    local Best, BestD
    Net.ForEachGuest(function(G)
        local Pawn = GuestPawn(G)
        if not Pawn then return end
        local PX, PY, PZ = Loc(Pawn)
        local D = PX and Dist(PX, PY, PZ, X, Y, Z)
        if D and D <= Range and (not BestD or D < BestD) then Best, BestD = G, D end
    end)
    return Best
end

-- Warnung an den Besitzer-Clan: online sofort (hoechstens 1/min je Besitzer), offline beim naechsten Beitritt
function OW.RaidWarn(Gid)
    if not OW.GidOk(Gid) then return end
    local Now = os.clock()
    if Now - (B.WarnAt[Gid] or -1e9) < 60 then return end
    B.WarnAt[Gid] = Now
    local Online = {}
    Net.ForEachGuest(function(G)
        if G.GuestId and OW.Allied(G.GuestId, Gid) then
            Online[G.GuestId] = true
            OW.Note(G, "Deine Basis wird angegriffen!", true)
        end
    end)
    local Cand = { [Gid] = true }
    for Id in pairs(O.Names) do Cand[Id] = true end
    for Id in pairs(Cand) do
        if not Online[Id] and OW.Allied(Id, Gid) then
            O.Warn[Id], O.Dirty = math.min((O.Warn[Id] or 0) + 1, 999), true
        end
    end
    Log("Raid-Warnung an %s", OW.NameGid(Gid))
end

-- Bau zerstoert: Kisteninhalt fallen lassen, Baumaterial (SpawnCraftingMaterials, zerstoert selbst), Rest abreissen
function OW.RaidDestroy(Obj, E, K, Att)
    local DAPath = PathOf(A.Safe(function()
        local DA = Obj.PickupDataAsset
        return A.IsAlive(DA) and DA:GetFullName() or nil
    end))
    if OW.IsBox(E, Obj) and On("raid_droploot") then
        -- DropAllItems spawnt an GetPlayerCharacter(0): Owner = Angreifer -> Umleitung der DLL auf ihn (wie b_pick)
        -- Ohne lebende Figur wuerde JigMP_OnRequestDropItem @000a/@0162 beim letzten Owner (fokussierender Gast) bzw. beim Geist
        -- spawnen: naechster Gast in 30 m, sonst Kiste mit 1 HP stehen lassen (Inhalt bleibt, naechster Treffer reisst ab)
        local APawn = GuestPawn(Att)
        if not APawn then
            local NG = OW.NearestGuest(E.X, E.Y, E.Z, 3000)
            APawn = NG and GuestPawn(NG)
        end
        if not APawn then
            pcall(function() Obj.Health = 1 end)
            Net.State("b_hp", E.Key, string.format("1;%.0f", B.MaxHp[E.Key] or 1), 2)
            Log("Raid: kein Angreifer-Pawn - %s bleibt mit 1 HP stehen (Inhalt nicht verschoben)", tostring(E.Cls))
            return
        end
        pcall(function() Obj:SetOwner(APawn) end)
        -- Runde 9 (raid_lootplace, BUILD-16): Zahl der Eintraege vor dem Abwurf merken, danach die neuen Bodenobjekte
        -- vom Angreifer an die Kiste legen (OW.LootPlace, 0,3 s spaeter)
        local LootN = On("raid_lootplace") and A.Safe(function() return OW.BoxCount(Obj) end) or nil
        OW.DropAll(Obj)
        if On("raid_lootplace") then
            local okL, errL = pcall(OW.LootQueue, E, APawn, LootN)
            if not okL then Core.Fail("raid_lootplace", errL) end
        end
    end
    local Dropped = false
    if On("raid_drop") and A.IsAlive(Obj) then
        local N = tonumber(A.Safe(function() return Obj.CraftingMaterials:GetArrayNum() end, 0)) or 0
        if N > 0 then Dropped = pcall(function() Obj:SpawnCraftingMaterials() end) end
    end
    if A.IsAlive(Obj) then pcall(function() Obj:K2_DestroyActor() end) end
    if not Dropped and On("raid_drop") and DAPath and math.random() < 0.5 then
        -- Rueckfall ohne Materialliste: mit 50 % das Bauteil-Item an den Angreifer (ls_inv, voll -> am Boden)
        local Inv = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_inv
        if Inv and type(Inv.Give) == "function" then pcall(Inv.Give, Att.Key, DAPath, 1) end
    end
    IndexDrop(E)
    RebuildByCls()
    OW.Remove(K)
    if K then O.Doubt[K] = nil end
    B.RaidKills = B.RaidKills + 1
    Log("Raid: %s zerstoert von %s (Material: %s)", tostring(E.Cls), OW.NameGid(Att.GuestId),
        Dropped and "ja" or "nein")
end

function OW.RaidHit(Ev)
    local TFull = Ev.Args[1]
    if type(TFull) ~= "string" then return end
    local TCls, TPath = TFull:match("^(%S+) (.+)$")
    if not TCls or B.BuildCls[TCls] == false then return end
    local Dmg = tonumber(Ev.Args[2]) or 0
    if Dmg <= 0 then return end
    local Kind = OW.KindOf(Ev.Caller) or OW.KindOf(Ev.Args[4])
    if not Kind then return end
    local Mult = tonumber(Core.Flag("raid_mult_" .. Kind, RAID_DEF[Kind])) or 0
    if Mult <= 0 then return end
    local E = B.H.ByName[TFull]
    local Obj
    if E then
        Obj = Fresh(E)
    else
        Obj = StaticFindObject(TPath)
        if not A.IsAlive(Obj) then return end
        if B.BuildCls[TCls] == nil then B.BuildCls[TCls] = IsA(Obj, P.MASTER) end
        if not B.BuildCls[TCls] then return end
        local Name = A.Safe(function() return Obj:GetFullName() end)
        E = Name and (B.H.ByName[Name] or IndexAdd(Obj, Name, MASTER))
        if not E then return end
        RebuildByCls()
    end
    if not Obj or E.Grp ~= MASTER then return end
    -- Angreifer: Instigator (PC), Verursacher (Figur), Owner-Kette von Verursacher/Waffe; Sprengstoff ohne Kette:
    -- naechster Gast in 30 m (nur fuer Clan-Ausnahme und Warnung)
    local Att = OW.GuestOfFull(Ev.Args[3]) or OW.GuestOfFull(Ev.Args[4]) or OW.ChainGuest(Ev.Args[4])
        or OW.ChainGuest(Ev.Caller)
    if not Att and (Kind == "explosive" or Kind == "fire") then Att = OW.NearestGuest(E.X, E.Y, E.Z, 3000) end
    if not Att then return end
    -- Verursacher mit Tag CanAttackBuildable: das Spiel zieht selbst ab (ReceiveAnyDamage), hier nur Abriss pruefen
    local CCls, CPath = (type(Ev.Args[4]) == "string" and Ev.Args[4] or ""):match("^(%S+) (.+)$")
    local Tagged = CCls and B.TagCls[CCls]
    if CCls and Tagged == nil then
        local C = StaticFindObject(CPath)
        if A.IsAlive(C) then
            Tagged = A.Safe(function() return C:ActorHasTag(FName("CanAttackBuildable")) end, false) == true
            B.TagCls[CCls] = Tagged
        end
    end
    OW.RaidApply(Obj, E, Att, Kind, Dmg * Mult, Tagged)
end

-- Runde 9 (BUILD-3): Treffer auf ein Bauteil anwenden - Feuerwaffen ueber cb_dmg (OW.RaidHit), Explosionen ueber
-- M.Boom (ls_combat), Nahkampf ueber b_rmel (OW.RaidMelee). Dmg = fertiger Schaden (Multiplikator schon drin);
-- Tagged = das Spiel hat schon abgezogen (ReceiveAnyDamage, CanAttackBuildable) -> nur Abriss pruefen
function OW.RaidApply(Obj, E, Att, Kind, Dmg, Tagged)
    local K = OW.EKey(E)
    local Owner = K and O.Own[K]
    if Owner and OW.Allied(Att.GuestId, Owner) then return end
    local HasOwn, _, Foreign = OW.ClaimState(Att.GuestId, E.X, E.Y)
    if not Owner and HasOwn then return end
    if not Owner and not Foreign and not On("raid_unowned") then return end
    local Hp = A.Safe(function() return tonumber(Obj.Health) end)
    if not Hp then return end
    LogOnce("raidk" .. tostring(Kind), "Raid: erster Treffer der Art %s (%s, %.0f Schaden)", tostring(Kind), E.Cls, Dmg)
    local New = Hp
    if not Tagged then
        if Hp <= 0 then LogOnce("hp0" .. E.Cls, "Raid: %s hat Health <= 0 - nicht zerstoerbar", E.Cls) return end
        New = Hp - Dmg
        pcall(function() Obj.Health = New end)
    end
    local Max = OW.MaxHp(E, Obj, Hp)
    B.RaidN = B.RaidN + 1
    OW.RaidWarn(Owner or (Foreign and Foreign.Gid))
    if New <= 0 then
        OW.RaidDestroy(Obj, E, K, Att)
    else
        Net.State("b_hp", E.Key, string.format("%.0f;%.0f", New, Max), 2)
    end
end

function OW.RaidTick(Now)
    if Net.Side ~= "host" or not On() then return end
    local Want = On("raid_on") and Core.Flag("pvp", true) == true and next(Net.Guests) ~= nil
    if Now - (B.RaidWatchAt or 0) >= 1 then
        B.RaidWatchAt = Now
        local ok, err = pcall(OW.RaidWatch, Want)
        if not ok then Core.Fail("raid_on", err) end
    end
    if not Want or not CheckWorld() then return end
    local Tags = OW.DmgWatchers()
    if next(Tags) == nil then return end
    B.Ally = {}
    for _, Ev in ipairs(Native.ReadEvents("_ls_build_dmg")) do
        if Tags[Ev.Tag] and type(Ev.Args) == "table" then
            local ok, err = pcall(OW.RaidHit, Ev)
            if not ok and Core.Fail("raid_on", err) then Log("Raids aus: %s", tostring(err)) break end
        end
    end
end

-- ---- Runde 9 (BUILD-3 A, raid_boom): 5.6-Sprengstoff ruft ApplyRadialDamage (fuer cb_dmg unsichtbar), Molotov nur
-- Damage_Object (BPI_Damage, Bauteile haben es nicht) -> Raids aus der Explosions-Verfolgung von ls_combat.
-- Radien aus dem 5.6-Decode (SphereOverlap/ApplyRadialDamage)
OW.BOOM_R = { BP_Throwable_PipeBomb_C = 300, BP_Throwable_Frag_C = 400, BP_ProjectileGrenade_C = 600,
    BP_ProjectileRocket_C = 1200 }

-- Figur des Gasts traegt CanAttackBuildable? (dann zieht Buildable_MASTER_C.ReceiveAnyDamage @000f selbst ab)
function OW.PawnTagged(G)
    local Pawn = GuestPawn(G)
    if not Pawn then return false end
    B.PTag = B.PTag or {}
    local Nm = tostring(G.PawnName)
    if B.PTag[Nm] == nil then
        B.PTag[Nm] = A.Safe(function() return Pawn:ActorHasTag(FName("CanAttackBuildable")) end, false) == true
    end
    return B.PTag[Nm]
end

-- E12 Coop.Build.Boom(GuestKey, Klasse, Pos{X,Y,Z}, Schaden): Explosion eines Gast-Wurfkoerpers (ls_combat
-- H.TrackProj, Spiel-Thread, kein Hook). Alle Bauteile im Radius (+ raid_boom_pad), naechste zuerst, hoechstens 24
function M.Boom(Key, Cls, Pos, Dmg)
    if Net.Side ~= "host" or not (On("raid_on") and On("raid_boom")) or Core.Flag("pvp", true) ~= true then return end
    local G, R0 = Net.Guests[Key or ""], OW.BOOM_R[Cls or ""]
    if not (G and R0 and type(Pos) == "table") then return end
    local PX, PY, PZ = tonumber(Pos.X), tonumber(Pos.Y), tonumber(Pos.Z)
    if not (PX and PY and PZ) or not CheckWorld() then return end
    local Mult = tonumber(Core.Flag("raid_mult_explosive", RAID_DEF.explosive)) or 0
    local D0 = tonumber(Dmg)
    if not D0 or D0 <= 0 then D0 = tonumber(Core.Flag("raid_boom_dmg", 150)) or 150 end
    D0 = D0 * Mult
    if D0 <= 0 then return end
    R0 = R0 + (tonumber(Core.Flag("raid_boom_pad", 150)) or 150)   -- Abstand Pivot <-> Flaeche grosser Bauteile
    local Hits = {}
    for _, E in pairs(B.H.ByName) do
        if E.Grp == MASTER and math.abs(E.X - PX) <= R0 and math.abs(E.Y - PY) <= R0 then
            local D = Dist(E.X, E.Y, E.Z, PX, PY, PZ)
            if D <= R0 then Hits[#Hits + 1] = { E = E, D = D } end
        end
    end
    if #Hits == 0 then return end
    table.sort(Hits, function(H1, H2) return H1.D < H2.D end)
    B.Ally = {}
    local Tagged, N = OW.PawnTagged(G), 0
    for _, H in ipairs(Hits) do
        if N >= 24 then break end
        local Obj = Fresh(H.E)
        if Obj then
            local ok, err = pcall(OW.RaidApply, Obj, H.E, G, "explosive", D0, Tagged)
            if not ok then return Core.Fail("raid_boom", err) end
            N = N + 1
        end
    end
    LogOnce("boom" .. tostring(Cls), "Raid: Explosion %s von %s erreicht %d Bauteile (%.0f Schaden)", tostring(Cls),
        tostring(G.PawnName), N, D0)
end

-- ---- Runde 9 (BUILD-3 B, raid_melee): 5.6 BP_MeleePickup EVT_Event_OnHitNormal @0a43-@0b7f ruft fuer Bauteile
-- nichts auf -> der Gast meldet das Bauteil vor sich (b_rmel), der Host prueft und wendet raid_melee_dmg an
-- Waagerechter Kegel: Richtung DX/DY gegen Blickrichtung FX/FY, CosMax = cos(halber Winkel); direkt am Pivot nie
function OW.InCone(DX, DY, FX, FY, CosMax)
    local L = math.sqrt(DX * DX + DY * DY)
    if L < 25 then return false end   -- Pivot unter der Figur (Boden/Fundament), nicht das Ziel des Schlags
    return (DX * FX + DY * FY) / L >= CosMax
end

-- E13 Coop.Build.OnSwing(Power) - ls_combat (Gast, je eigenem Nahkampfschlag): naechstes Bauteil <= 350 uu im
-- 40-Grad-Kegel der Blickrichtung (nur Lua ueber den Index), hoechstens 2/s
function M.OnSwing(Power)
    if Net.Side ~= "client" or not (On("raid_melee") and Net.Has("brmel")) then return end
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    local PC = A.LocalPC()
    if not (A.IsAlive(Pawn) and A.IsAlive(PC)) then return end
    local PX, PY, PZ = Loc(Pawn)
    local Rot = A.Safe(function() return PC:GetControlRotation() end)
    if not (PX and Rot) then return end
    local Yaw = math.rad(tonumber(Rot.Yaw) or 0)
    local FX, FY = math.cos(Yaw), math.sin(Yaw)
    local Best, BestD
    for _, E in pairs(B.H.ByName) do
        if E.Grp == MASTER and math.abs(E.X - PX) <= 350 and math.abs(E.Y - PY) <= 350 then
            local D = Dist(E.X, E.Y, E.Z, PX, PY, PZ)
            if D <= 350 and (not BestD or D < BestD) and OW.InCone(E.X - PX, E.Y - PY, FX, FY, 0.766) then
                Best, BestD = E, D
            end
        end
    end
    if Best and Throttle("rmel", 0.5) then Net.Send("b_rmel", Enc(Best.Key) .. "|" .. (Power and 1 or 0), nil, 0) end
end

-- Nahkampfwaffe in der Hand (Host-Kopie)? ls_combat E9 CombatActiveWeapon, sonst BP_JigHelperComp_C.GetActiveWeapon
function OW.MeleeInHand(Pawn)
    local W
    local F = A.Coop and A.Coop.CombatActiveWeapon
    if type(F) == "function" then
        local ok, R0 = pcall(F, Pawn)
        if ok then W = R0 end
    end
    if not A.IsAlive(W) then
        local Jig = A.Safe(function() return Pawn.BP_JigHelperComp end)
        local Out = {}
        if A.IsAlive(Jig) and pcall(function() Jig:GetActiveWeapon(Out) end) then W = OW.Out(Out, "Actor") end
    end
    return A.IsAlive(W) and IsA(W, P.MELEE) or false
end

-- Host (b_rmel, ueber OW.Queue im build_fast-Takt): Reichweite <= 450 uu, Nahkampfwaffe in der Hand, Blickrichtung
-- des Gast-PCs (50-Grad-Kegel, Toleranz fuer Verzoegerung), dann raid_melee_dmg (Power-Schlag doppelt)
function OW.RaidMelee(G, Key, Power)
    if not (On("raid_on") and On("raid_melee")) or Core.Flag("pvp", true) ~= true then return end
    local Pawn = OW.Pre(G, "b_rmel", Key)
    if not Pawn or not Throttle("rmel" .. G.Key, 0.4) then return end
    local Obj, E = Resolve(Key)
    if not (Obj and E and E.Grp == MASTER) then return end
    local PX, PY, PZ = Loc(Pawn)
    if not PX or Dist(PX, PY, PZ, E.X, E.Y, E.Z) > 450 then return Net.SecWarn(G, G.Key, "b_rmel_dist") end
    if not OW.MeleeInHand(Pawn) then return Net.SecWarn(G, G.Key, "b_rmel_weapon") end
    local PC = Net.PC(G)
    local Rot = PC and A.Safe(function() return PC:GetControlRotation() end)
    local Yaw = Rot and math.rad(tonumber(Rot.Yaw) or 0)
    if Yaw and not OW.InCone(E.X - PX, E.Y - PY, math.cos(Yaw), math.sin(Yaw), 0.643) then
        return Net.SecWarn(G, G.Key, "b_rmel_cone")
    end
    local Dmg = (tonumber(Core.Flag("raid_melee_dmg", 30)) or 30) * (Power and 2 or 1)
    if Dmg <= 0 then return end
    B.Ally = {}
    OW.RaidApply(Obj, E, G, "melee", Dmg, false)
end

-- ---------------------------------------------------------------- Runde 7: Chat-Befehle (Host)
-- Ziel: angeschaut (b_foc, <= 30 s alt, in Reichweite), sonst naechstes passendes Bauteil in Range (uu)
function OW.ChatTarget(G, Pred, Range)
    local Pawn = GuestPawn(G)
    if not Pawn then return nil end
    local PX, PY, PZ = Loc(Pawn)
    if not PX then return nil end
    local F = B.Foc[G.Key]
    if F and F.Key ~= "" and os.clock() - F.At < 30 then
        local Obj, E = Resolve(F.Key)
        if Obj and E and E.Grp == MASTER and Dist(E.X, E.Y, E.Z, PX, PY, PZ) <= USE_DIST and Pred(E, Obj) then
            return Obj, E
        end
    end
    local BestObj, BestE, BestD
    for _, E in pairs(B.H.ByName) do
        if E.Grp == MASTER then
            local D = Dist(E.X, E.Y, E.Z, PX, PY, PZ)
            if D <= (Range or 350) and (not BestD or D < BestD) then
                local Obj = Fresh(E)
                if Obj and Pred(E, Obj) then BestObj, BestE, BestD = Obj, E, D end
            end
        end
    end
    return BestObj, BestE
end

function OW.CmdLock(G, Gid, Cmd, Rest)
    if not On("locks_on") then return OW.Note(G, "Schloesser sind auf diesem Server aus") end
    local Pred = OW.IsLockable
    if Cmd == "code" then
        Pred = function(E1, Obj1)
            local K1 = OW.EKey(E1)
            return K1 ~= nil and O.Lock[K1] ~= nil and OW.IsLockable(E1, Obj1)
        end
    end
    local _, E = OW.ChatTarget(G, Pred)
    if not E then return OW.Note(G, "Keine passende Tuer oder Kiste gefunden (anschauen oder auf 3 m herangehen)") end
    local K = OW.EKey(E)
    if Cmd == "code" then
        local Code = Rest:match("^(%d+)$")
        if not Code then return OW.Note(G, "Benutzung: /code <Code>") end
        if not (K and O.Lock[K]) then return OW.Note(G, "Hier ist kein Schloss") end
        local Why = OW.CodeBlocked(Gid, K)
        if Why then return OW.Note(G, Why, true) end
        if Code ~= O.Lock[K] then
            OW.CodeBad(Gid, K, O.Own[K])
            Log("Falscher Code von %s an %s", OW.NameGid(Gid), E.Cls)
            return OW.Note(G, "Falscher Code", true)
        end
        B.Codes[Gid] = B.Codes[Gid] or {}
        B.Codes[Gid][K] = { Until = os.time() + 600, Code = O.Lock[K] }
        B.DenySig = nil
        return OW.Note(G, "Code richtig - 10 Minuten offen")
    end
    -- /lock, /unlock: Besitzer/Clan; herrenlos nur im eigenen Gebiet (wird dann dein Bauteil)
    local Owner = K and O.Own[K]
    if Owner and not OW.Allied(Gid, Owner) then return OW.Note(G, "Nicht dein Bauteil", true) end
    if not Owner then
        if not OW.ClaimState(Gid, E.X, E.Y) then
            return OW.Note(G, "Herrenlos - erst Basis-Marker setzen und /claim")
        end
        K = K or E.Key
        O.Own[K] = Gid
        OW.Touch()
    end
    if Cmd == "unlock" then
        if not O.Lock[K] then return OW.Note(G, "Kein Schloss gesetzt") end
        O.Lock[K] = nil
        OW.Touch()
        return OW.Note(G, "Schloss entfernt")
    end
    local Code = Rest:match("^(%d+)$")
    if not Code or #Code < 4 or #Code > 8 then return OW.Note(G, "Benutzung: /lock <4-8 Ziffern>") end
    O.Lock[K] = Code
    OW.Touch()
    Log("Schloss gesetzt von %s an %s", OW.NameGid(Gid), E.Cls)
    if not OW.DenyOk() then
        return OW.Note(G, "Schloss gesetzt - ACHTUNG: DLL-Sperre inaktiv, nur eingeschraenkter Schutz", true)
    end
    return OW.Note(G, "Schloss gesetzt - dein Clan kommt immer rein, Fremde brauchen /code")
end

function OW.CmdClaim(G, Gid, Cmd)
    if not On("claim_on") then return OW.Note(G, "Claims sind auf diesem Server aus") end
    local Pawn = GuestPawn(G)
    local PX, PY
    if Pawn then PX, PY = Loc(Pawn) end
    if not PX then return OW.Note(G, "Keine Figur") end
    local IsMarker = function(E1) return E1.Cls == MARKER end
    local _, E = OW.ChatTarget(G, IsMarker, 400)
    local K = E and (OW.EKey(E) or E.Key)
    if Cmd == "unclaim" then
        if not (K and O.Claim[K]) then
            OW.Index()
            local R2 = OW.ClaimR() ^ 2
            for _, C in ipairs(O.Claims) do
                if C.Gid == Gid and (C.X - PX) ^ 2 + (C.Y - PY) ^ 2 <= R2 then K = C.Key break end
            end
        end
        if not (K and O.Claim[K]) then return OW.Note(G, "Kein Claim gefunden") end
        if O.Claim[K] ~= Gid then return OW.Note(G, "Nur der Ersteller kann den Claim aufheben", true) end
        O.Claim[K] = nil
        OW.Touch()
        Log("Claim aufgehoben von %s (%s)", OW.NameGid(Gid), K)
        return OW.Note(G, "Claim aufgehoben")
    end
    local Msg = {}
    if K then
        local Owner = O.Own[K]
        if Owner and not OW.Allied(Gid, Owner) then return OW.Note(G, "Dieser Basis-Marker gehoert jemand anderem", true) end
        if not O.Claim[K] then
            local Ok, Why = OW.BuildAllowed(Gid, MARKER, E.X, E.Y)
            if not Ok then return OW.Note(G, (Why or ""):gsub(" %(Item bleibt bei dir%)", ""), true) end
            -- Runde 9 (claim_max): Grenze je Clan auch fuer /claim
            local Full, Max = OW.ClaimFull(Gid)
            if Full then return OW.Note(G, "Claim-Grenze erreicht (" .. Max .. ") - erst einen Claim aufheben (/unclaim)", true) end
            O.Own[K] = Owner or Gid
            O.Claim[K] = O.Own[K]
            OW.Touch()
            Msg[#Msg + 1] = string.format("Gebiet beansprucht (Radius %d m)", R(OW.ClaimR() / 100))
            Log("Claim per /claim von %s bei %s", OW.NameGid(Gid), K)
        end
    end
    -- herrenlose Bauten im eigenen Gebiet (und in keinem fremden) uebernehmen
    if OW.ClaimState(Gid, PX, PY) then
        local N = 0
        for _, E2 in pairs(B.H.ByName) do
            if E2.Grp == MASTER and N < 500 then
                local K2 = OW.EKey(E2)
                if not (K2 and O.Own[K2]) then
                    local Own2, Foreign2 = OW.ClaimState(Gid, E2.X, E2.Y)
                    if Own2 and not Foreign2 then
                        O.Own[K2 or E2.Key] = Gid
                        N = N + 1
                    end
                end
            end
        end
        if N > 0 then
            OW.Touch()
            Msg[#Msg + 1] = string.format("%d herrenlose Bauteile uebernommen", N)
        end
    end
    if #Msg == 0 then return OW.Note(G, "Nichts zu beanspruchen - Basis-Marker anschauen oder im eigenen Gebiet stehen") end
    return OW.Note(G, table.concat(Msg, ", "))
end

function OW.CmdOwner(G, Gid)
    local Parts = {}
    local _, E = OW.ChatTarget(G, function() return true end, 400)
    if E then
        local K = OW.EKey(E)
        local Owner = K and O.Own[K]
        Parts[#Parts + 1] = Owner and ("Besitzer: " .. OW.NameGid(Owner)) or "Herrenlos"
        if K and O.Lock[K] then Parts[#Parts + 1] = "Schloss: ja" end
    end
    local Pawn = GuestPawn(G)
    local PX, PY
    if Pawn then PX, PY = Loc(Pawn) end
    if PX and On("claim_on") then
        local HasOwn, _, Foreign = OW.ClaimState(Gid, PX, PY)
        Parts[#Parts + 1] = HasOwn and "Gebiet: deins/Clan" or (Foreign and ("Gebiet: " .. OW.NameGid(Foreign.Gid)))
            or "Gebiet: frei"
    end
    if #Parts == 0 then Parts[1] = "Nichts gefunden" end
    return OW.Note(G, table.concat(Parts, " | "))
end

-- Coop.Build.Chat (server.lua Srv.ChatCommand): true = Befehl dieses Moduls (nie an alle verteilen)
function M.Chat(G, Text)
    if type(Text) ~= "string" or type(G) ~= "table" then return false end
    local Cmd, Rest = Text:match("^%s*/(%a+)%s*(.-)%s*$")
    Cmd = Cmd and Cmd:lower()
    if not (Cmd and LOCK_CMDS[Cmd]) then return false end
    if Net.Side ~= "host" or not On() then return false end
    local NG = Net.Guests[G.Key or ""]
    if not NG and G.PC and A.IsAlive(G.PC) then NG = Net.ByPC(G.PC) end
    if not NG then return true end
    -- Doppel-Login (main.lua G.Dup -> A.Coop.GuestDup[Key]): nie Rechte - GuestIds[DupKey] haelt die echte ID weiter
    local DupT = A.Coop and A.Coop.GuestDup
    local Dup = G.Dup == true or (DupT ~= nil and ((NG.Key ~= nil and DupT[NG.Key] ~= nil) or (G.Key ~= nil and DupT[G.Key] ~= nil)))
    local Gid = not Dup and (NG.GuestId or G.GuestId) or nil
    if not OW.GidOk(Gid) then
        OW.Note(NG, "Keine Spieler-ID - Befehl nicht moeglich")
        return true
    end
    OW.Load()
    if type(G.Name) == "string" then OW.LearnName(NG, G.Name) end
    B.Ally = {}
    local ok, err
    if Cmd == "lock" or Cmd == "unlock" or Cmd == "code" then
        ok, err = pcall(OW.CmdLock, NG, Gid, Cmd, Rest or "")
        if not ok then Core.Fail("locks_on", err) end
    elseif Cmd == "claim" or Cmd == "unclaim" then
        ok, err = pcall(OW.CmdClaim, NG, Gid, Cmd)
        if not ok then Core.Fail("claim_on", err) end
    else
        ok, err = pcall(OW.CmdOwner, NG, Gid)
    end
    if not ok then
        Log("Befehl /%s fehlgeschlagen: %s", Cmd, tostring(err))
        OW.Note(NG, "Befehl /" .. Cmd .. " fehlgeschlagen", true)
    end
    return true
end

-- Coop.Build.OwnerOf(Actor) -> GuestId|nil (Host)
function M.OwnerOf(Actor)
    if Net.Side ~= "host" or not A.IsAlive(Actor) then return nil end
    local K, Cls, X, Y, Z = KeyOf(Actor)
    if not K then return nil end
    local OK = OW.Find(Cls, X, Y, Z, K)
    return OK and O.Own[OK] or nil
end

-- Coop.Build.CanUse(GuestId, Actor) -> bool (Host): Besitzer/Clan, eigener Claim oder gueltiger Code
function M.CanUse(Gid, Actor)
    if Net.Side ~= "host" or not A.IsAlive(Actor) then return true end
    return OW.ObjAccess(Gid, Actor)
end

-- ---- Runde 9 Exporte (nur Lua-Daten): E14 fuer ls_player P.Unstuck, E15/E16 fuer ls_world W.RespawnBlocked
-- E14 Coop.Build.ForeignClaimAt(GuestId, X, Y) -> true, wenn der Ort in einem fremden (nicht verbuendeten) Claim liegt
function M.ForeignClaimAt(Gid, X, Y)
    X, Y = tonumber(X), tonumber(Y)
    if Net.Side ~= "host" or not (X and Y) or not On("claim_on") then return false end
    B.Ally = {}
    local _, HasForeign = OW.ClaimState(Gid, X, Y)
    return HasForeign == true
end

-- E15 Coop.Build.BuiltNear(X, Y, R) -> true, wenn ein Bauteil (Index) waagerecht <= R uu entfernt steht
function M.BuiltNear(X, Y, R)
    X, Y, R = tonumber(X), tonumber(Y), tonumber(R) or 0
    if not (X and Y) or R <= 0 then return false end
    local R2 = R * R
    for _, E in pairs(B.H.ByName) do
        if E.Grp == MASTER and E.X and math.abs(E.X - X) <= R and math.abs(E.Y - Y) <= R
            and (E.X - X) ^ 2 + (E.Y - Y) ^ 2 <= R2 then
            return true
        end
    end
    return false
end

-- E16 Coop.Build.ClaimAt(X, Y) -> true, wenn der Ort in irgendeinem Claim liegt (Besitzer egal)
function M.ClaimAt(X, Y)
    X, Y = tonumber(X), tonumber(Y)
    if Net.Side ~= "host" or not (X and Y) or not On("claim_on") then return false end
    OW.Index()
    local R2 = OW.ClaimR() ^ 2
    for _, C in ipairs(O.Claims) do
        if (C.X - X) ^ 2 + (C.Y - Y) ^ 2 <= R2 then return true end
    end
    return false
end

-- Clan-Austritt/Kick (ls_clan Info {Gid, Leader, Name, Old}): Bauteile des Ausgetretenen innerhalb der Claims der
-- bisherigen Mitglieder gehen an den Clan-Leiter; Schloss und /code-Freigaben fallen weg (er kennt den Code).
-- Claims direkt aus O.Claims + Info.Old (nicht ClaimState/Allied: Mitgliedschaft ist schon entfernt).
-- Aufloesung (Leader nil): nichts zu uebergeben.
function OW.ClanLeft(Info)
    if type(Info) ~= "table" or not (OW.GidOk(Info.Gid) and OW.GidOk(Info.Leader)) then return end
    local Me = Info.Gid:lower()
    if Info.Leader:lower() == Me then return end
    -- laufende /code-Freigaben des Ausgetretenen sofort ungueltig (Zugriff endet mit dem Austritt)
    for G2 in pairs(B.Codes) do
        if type(G2) == "string" and G2:lower() == Me then B.Codes[G2] = nil end
    end
    OW.Load()
    OW.Index()
    local Was = {}
    for _, G2 in ipairs(type(Info.Old) == "table" and Info.Old or {}) do
        if type(G2) == "string" and G2:lower() ~= Me then Was[G2:lower()] = true end
    end
    local Cl = {}
    for _, C in ipairs(O.Claims) do
        local CG = type(C.Gid) == "string" and C.Gid:lower()
        if CG and CG ~= Me and Was[CG] then Cl[#Cl + 1] = C end
    end
    if #Cl == 0 then return end
    local R2, N, NL, Moved = OW.ClaimR() ^ 2, 0, 0, {}
    for K, Gid in pairs(O.Own) do
        local Pt = type(Gid) == "string" and Gid:lower() == Me and O.Pos[K]
        if Pt then
            for _, C in ipairs(Cl) do
                local DX, DY = C.X - Pt.X, C.Y - Pt.Y
                if DX * DX + DY * DY <= R2 then Moved[#Moved + 1] = K break end
            end
        end
    end
    for _, K in ipairs(Moved) do
        if O.Lock[K] then NL = NL + 1 end
        O.Own[K], O.Lock[K] = Info.Leader, nil
        if type(O.Claim[K]) == "string" and O.Claim[K]:lower() == Me then O.Claim[K] = Info.Leader end
        for _, T in pairs(B.Codes) do T[K] = nil end
        N = N + 1
    end
    if N > 0 then
        OW.Touch()
        OW.Save(true)
        Log("Clan-Austritt: %d Bauteile von %s an Leiter %s (Clan %s) uebergeben, %d Schloesser entfernt",
            N, OW.NameGid(Info.Gid), OW.NameGid(Info.Leader), tostring(Info.Name), NL)
    end
end

-- Host 1 s: Laden/Speichern, Clan-Listener, Offline-Warnungen beim Beitritt, abgebaute Bauten aufraeumen
function OW.Slow(Now)
    OW.Load()
    local C = OW.Clan()
    if C and not B.ClanHooked and type(C.OnChange) == "function" then
        B.ClanHooked = true
        pcall(C.OnChange, function(_, _, Info)
            B.Ally, B.DenySig = {}, nil
            if Info then
                local ok, err = pcall(OW.ClanLeft, Info)
                if not ok then Log("Clan-Austritt: Uebergabe fehlgeschlagen: %s", tostring(err)) end
                -- Sperrliste sofort neu (nicht erst im naechsten 0,5-s-Takt): Ausgetretener verliert Zugriff jetzt
                -- (Listener laeuft im clan_cmd-Takt, gleicher Kontext wie build_deny)
                B.Ally, B.DenySig = {}, nil
                OW.DenyTick(os.clock())
            end
        end)
    end
    -- Lua-Rueckfall (Interaktions-Hook leert Actor) auch, wenn die DLL-Sperrliste nicht wirkt
    local Degraded = (On("locks_on") or On("claim_on")) and not OW.DenyOk()
    if Degraded then
        LogOnce("denyoff", "Schloesser/Claims: DLL-Sperrliste inaktiv - nur Lua-Rueckfall (Interaktion), Kisten-RPCs ungeschuetzt")
    end
    B.HookNull = (On("locks_on") or On("claim_on")) and (Core.Flag("locks_hooknull", false) == true or Degraded)
    for Key, At in pairs(B.JoinQ) do
        if Now >= At then
            B.JoinQ[Key] = nil
            local G = Net.Guests[Key]
            local Gid = G and G.GuestId
            local N = Gid and O.Warn[Gid]
            if N then
                OW.Note(G, string.format("Deine Basis wurde angegriffen, waehrend du offline warst (%dx)", N), true)
                O.Warn[Gid], O.Dirty = nil, true
            end
        end
    end
    OW.Prune(Now)
    if On("claim_reconcile") then
        local okR, errR = pcall(OW.Reconcile, Now)
        if not okR then Core.Fail("claim_reconcile", errR) end
    end
    OW.Save()
end

-- claim_reconcile (BUILD-9): owners.txt gegen die Welt abgleichen (nach einem Absturz rollt die Welt auf den letzten
-- Spielstand zurueck, owners.txt nicht) - einmal je Welt, 120 s nach dem vollstaendigen Index (build_idxfull, ohne
-- ihn kein Abgleich). Eintrag ohne Bau derselben Klasse <= MATCH_DIST faellt weg; fehlen mehr als max(10, 30 %), nur
-- loggen (Spielstand unvollstaendig geladen?)
function OW.Reconcile(Now)
    if B.RecDone or not B.IdxReady or Now - B.IdxReady < 120 then return end
    B.RecDone = true
    OW.Index()
    -- Review CO1: OW.Succ wie in OW.Prune (Claim nur am eigenen Marker lebendig) - raeumt auch Geister-Claims aus
    -- frueheren Sitzungen neben einem neu gesetzten Marker; im Durchlauf kein Touch, O.Pos bleibt unveraendert
    local Miss, Total, Hand = {}, 0, {}
    for K, Pt in pairs(O.Pos) do
        Total = Total + 1
        local Alive, Succ = OW.Succ(K, Pt)
        if not Alive then
            Miss[#Miss + 1] = K
            Hand[K] = Succ
        end
    end
    if #Miss == 0 then return Log("Besitz-Abgleich: %d Eintraege, alle Bauten vorhanden", Total) end
    if #Miss > math.max(10, Total * 0.3) then
        return Log("Besitz-Abgleich abgebrochen: %d von %d Bauten fehlen (Welt unvollstaendig?) - nichts geloescht",
            #Miss, Total)
    end
    -- Closeout R3: zwei Durchlaeufe - erst Eintraege ohne Nachfolger entfernen, damit fehlende Geister-Claims eine
    -- gueltige Uebergabe (OW.ClaimHand -> OW.ClaimFull) nicht faelschlich an der Grenze scheitern lassen
    for Pass = 1, 2 do
        for _, K in ipairs(Miss) do
            if (Pass == 1) == (Hand[K] == nil) then
                OW.ClaimHand(K, Hand[K])
                OW.Remove(K)
                O.Doubt[K] = nil
                Log("Besitz-Abgleich: %s entfernt (kein Bau am Ort)", K)
            end
        end
    end
    OW.Save(true)
    Log("Besitz-Abgleich: %d von %d Eintraegen ohne Bau entfernt", #Miss, Total)
end

-- E17 Coop.Build.Flush() - server.lua Srv.Save/J.Commit (srv_ownjournal, pcall): owners.txt SOFORT und synchron
-- schreiben (OW.Save(true) -> Core.WriteAtomic, ohne 2-s-Drossel; laedt vorher, falls noch nicht geladen), danach
-- kopiert server.lua die Datei. Rueckgabe true = geschrieben
function M.Flush()
    O.Dirty = true
    OW.Save(true)
    return O.Dirty == false
end

-- ---------------------------------------------------------------- Gast: Baumodus spiegeln
local function OwnComp()
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    local Comp = A.IsAlive(Pawn) and A.Safe(function() return Pawn.BuildingComponent end)
    return A.IsAlive(Comp) and Comp or nil, Pawn
end

local function ModeText(Comp)
    if not Comp["BuildModeOn?"] then return "0" end
    local DA = Comp.DARef
    local DAPath = A.IsAlive(DA) and PathOf(DA:GetFullName()) or nil
    if not DAPath then return "0" end
    local Rep, Pick = "", ""
    if Comp["ReplacingObject?"] then Rep = KeyOf(Comp.ReplacingActor) or "" end
    local PR = Comp.PickupRef
    if A.IsAlive(PR) then Pick = KeyOf(PR) or "" end
    return "1|" .. Enc(DAPath) .. "|" .. Enc(Rep) .. "|" .. Enc(Pick)
end

local function IsKeyDown(PC, Name)
    B.FKeys = B.FKeys or {}
    B.FKeys[Name] = B.FKeys[Name] or { KeyName = FName(Name) }
    return A.Safe(function() return PC:IsInputKeyDown(B.FKeys[Name]) end, false) == true
end

local function ClientMode()
    local Comp = OwnComp()
    if not Comp then return end
    local Text = A.Safe(function() return ModeText(Comp) end, "0")
    local Now = os.clock()
    if Text ~= B.LastMode or (Text ~= "0" and Now - (B.ModeAt or 0) > 3) then
        if Net.Send("b_mode", Text, nil, 0) then B.LastMode, B.ModeAt = Text, Now end
    end
    -- Runde 9 (claim_preview, BUILD-15): Vorschau im fremden Claim rot + Hinweis (der Host lehnt den Bau ohnehin ab)
    B.ClmBlock = false
    if Text ~= "0" and next(B.Clm) ~= nil and On("claim_preview") then
        local okP, errP = pcall(OW.ClaimPreview, Comp)
        if not okP then Core.Fail("claim_preview", errP) end
    end
    -- Rueckfall ohne Host-Hook: Klick-Flanke (wie IA_PrimaryAction: BuildModeOn? und CanBuild)
    if Text ~= "0" and not Net.Has(CAP_HOOK) then
        local PC = A.LocalPC()
        local Down = A.IsAlive(PC) and IsKeyDown(PC, "LeftMouseButton")
        if Down and not B.ClickDown and not B.ClmBlock and A.Safe(function() return Comp.CanBuild end, false) then
            local T = A.Safe(function()
                local L = Comp.BuildTransform.Translation
                return string.format("%.1f|%.1f|%.1f", L.X, L.Y, L.Z)
            end)
            if T then Net.Send("b_click", T, nil, 0) end
        end
        B.ClickDown = Down
    end
end

local function OnOk(Data)
    if Net.Side ~= "client" then return end
    local Comp = OwnComp()
    local Kind, Rest = Data:match("^(%a)|(.*)$")
    if Kind == "n" then
        if (tonumber(Rest) or 0) <= 0 and Comp then pcall(function() Comp:Event_StopBuildMode() end) end
    elseif Kind == "r" then
        local Key, X, Y, Z, Pi, Ya, Ro = Rest:match("^([^|]*)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        local Obj, E = nil, nil
        if Key then Obj, E = Resolve(Dec(Key)) end
        if Obj then
            pcall(function()
                Obj:K2_SetActorLocation({ X = Num(X), Y = Num(Y), Z = Num(Z) }, false, {}, true)
                Obj:K2_SetActorRotation({ Pitch = Num(Pi), Yaw = Num(Ya), Roll = Num(Ro) }, true)
            end)
            if E then IndexDrop(E) RebuildByCls() end   -- neue Position: beim naechsten Scan neu aufnehmen
        end
        if Comp then pcall(function() Comp:Event_StopBuildMode() end) end
        -- Runde 9 (build_polish): B.Next ist nach dem Klartext-Schluessel abgelegt (Key kommt kodiert)
        B.Next[(Key and On("build_polish")) and Dec(Key) or (Key or "")] = nil
    end
end

-- ---------------------------------------------------------------- Gast: Fokus, Schloss, UI-Fenster
-- Dietrich-Minispiel (Gast): GetLockpickAmount zaehlt MainJigContainers (beim Gast leer) -> Tick springt immer nach
-- L_0c9a (Stift aus). Patch @028b (651): JumpIfNot 07 9A0C0000 -> Jump 06 99020000 (weiter bei 0x0299), nur solange
-- der Host >= 1 Dietrich im Server-Inventar meldet (b_lpq/b_lpk -> b_ui "lp"). Sonst 0-Zeile (wie SP ohne Dietrich).
function OW.LockpickPatch()
    if not Core.HasPatchRegistry() then return end
    local Want = (Net.Side == "client" and Net.Has(CAP) and On("build_lock") and On("build_lockpatch")
        and (B.LpN or 0) > 0) and true or false
    if not Want and not B.LpPatchOn then return end
    local Fn = StaticFindObject(P.LPUBER)
    if not A.IsAlive(Fn) then
        if not Want then B.LpPatchOn = false end   -- Klasse entladen: die DLL hat den Patch verworfen
        return
    end
    local Line = string.format("build_lockpick bytes %x 651 079A0C0000 0699020000 %d", Fn:GetAddress(), Want and 1 or 0)
    if Line == B.LpPatchLine then return end
    if Core.SetPatch("build_lockpick", Line) then
        B.LpPatchLine, B.LpPatchOn = Line, Want
        Log("Dietrich-Minispiel-Patch %s angefordert (Dietriche laut Host: %d)", Want and "an" or "aus", B.LpN or 0)
    end
end

local function ClientFocus(Now)
    local Comp, Pawn = OwnComp()
    if not Pawn then return end
    local Act = A.Safe(function()
        local Helper = Pawn.BP_JigHelperComp
        return A.IsAlive(Helper) and Helper.CurrentTracActor or nil
    end)
    local Key = ""
    if A.IsAlive(Act) and OwnTarget(Act) then
        -- nur in Host-Reichweite melden (sonst secwarn b_foc_dist beim Blick ueber weite Wandreihen)
        local K, _, X, Y, Z = KeyOf(Act)
        local PX, PY, PZ = Loc(Pawn)
        if K and PX and Dist(PX, PY, PZ, X, Y, Z) <= USE_DIST - 50 then Key = K end
    end
    if On("build_owner") and Key ~= B.LastFoc then
        if Key == "" or Net.Send("b_foc", Enc(Key), nil, 1) then B.LastFoc = Key end
    end
    -- Runde 9 (build_polish, BUILD-28): Gegenstands-Zahl der Kiste vom Host ins Interaktions-Fenster
    if next(B.BoxN) ~= nil and On("build_polish") then
        local okS, errS = pcall(OW.BoxStat, Key, Now)
        if not okS then Core.Fail("build_polish", errS) end
    end
    -- Radio/Jukebox angeschaut (eigenes Radio-Fenster von fremden unterscheiden, ClientWindows)
    if A.IsAlive(Act) and On("build_radio") then
        local Cls = ClsName(Act)
        if Cls and RADIO[Cls] then
            local K = KeyOf(Act)
            if K then B.RadioFoc = { Key = K, At = Now } end
        end
    end
    -- Runde 8 (build_kcard): Kartentuer angeschaut -> Host nach den Karten im Server-Inventar fragen (b_kcq)
    if On("build_kcard") then
        local okK, errK = pcall(OW.KcFocus, Act, Pawn, Now)
        if not okK then Core.Fail("build_kcard", errK) end
    end
    if not On("build_lock") then return end
    -- Schloss: waehrend des Minispiels das Ziel merken, danach lokal offen -> Host
    local LP = A.Safe(function()
        local C = Pawn.LockPickingComponent
        return A.IsAlive(C) and C or nil
    end)
    local Picking = LP and A.Safe(function() return LP["PlayerLockPicking?"] end, false) == true or false
    if Picking and A.IsAlive(Act) and IsA(Act, P.LOCK) then
        local K = KeyOf(Act)
        if K and not (B.Pick and B.Pick.Key == K) then
            Net.Send("b_lpq", Enc(K), nil, 0)   -- Host: Start merken, Dietrich-Zahl -> Patch
        end
        B.Pick = { Key = K, At = Now }
    end
    -- Dietrich zerbrochen (BreakLockpick: Haltbarkeit <= 0 -> 25, IsTryingLock = false; Erfolg setzt nur 25) -> Host
    if Picking and LP then
        local D = A.Safe(function() return tonumber(LP.LPDurability) end)
        local Trying = A.Safe(function() return LP.IsTryingLock end, true)
        if D and B.LpD and B.LpD < 5 and D >= 24.9 and Trying == false and B.Pick and B.Pick.Key then
            Net.Send("b_lpk", Enc(B.Pick.Key), nil, 0)
            if B.LpN then B.LpN = math.max(0, B.LpN - 1) end
            OW.LockpickPatch()
        end
        B.LpD = D
    else
        B.LpD = nil
    end
    if B.Pick then
        local Obj = B.Pick.Key and Resolve(B.Pick.Key) or ResolveScan(B.Pick.Key or "")
        if Obj and A.Safe(function() return Obj["IsLocked?"] end, true) == false then
            Net.Send("b_unlock", Enc(B.Pick.Key), nil, 0)
            B.Pick = nil
        elseif Now - B.Pick.At > 60 then
            B.Pick = nil
        end
    end
end

local function OwnHud()
    local PC = A.LocalPC()
    local Hud = A.IsAlive(PC) and A.Safe(function() return PC:GetHUD() end)
    return A.IsAlive(Hud) and Hud or nil, PC
end

local function OpenKeypad(Key, Code)
    local Door = Resolve(Key)
    local Cls, WBL = ClassObj(P.KEYPADUI), StaticFindObject(P.WBL)
    local PC = A.LocalPC()
    if not (Door and Cls and A.IsAlive(WBL) and A.IsAlive(PC)) then return end
    if Code then pcall(function() Door.Code = Code end) end
    local W = A.Safe(function() return WBL:Create(PC, Cls, PC) end)
    if not A.IsAlive(W) then return end
    pcall(function()
        W.DoorRef = Door
        W:AddToViewport(2)
        local Pawn = PC:K2_GetPawn()
        if A.IsAlive(Pawn) then Pawn:DisableInput(PC) end
        WBL:SetInputMode_GameAndUIEx(PC, W, 2, false, false)
        PC.bShowMouseCursor = true
    end)
    B.Kp = { Key = Key, Path = PathOf(A.Safe(function() return W:GetFullName() end)), Last = "", At = os.clock() }
end

local function OpenRename(Key)
    local Obj = Resolve(Key)
    local Hud = OwnHud()
    if not (Obj and Hud) then return end
    pcall(function() Hud:ShowChangeObjectNameWidget(true, Obj) end)
    B.Ren = { Key = Key, Old = A.Safe(function() return Obj.ContainerName:ToString() end, ""), At = os.clock() }
end

local function OpenYesNo(Key)
    local Hud = OwnHud()
    if not Hud then return end
    local Out = {}
    pcall(function() Hud:YesAndNoUI(true, FText("Are you sure you want to pick up this container?"), Out) end)
    local W = Out.UI
    if not A.IsAlive(W) then for _, V in pairs(Out) do W = V break end end
    if not A.IsAlive(W) then return end
    B.Yn = { Key = Key, Path = PathOf(A.Safe(function() return W:GetFullName() end)), Yes = false, YesN = 0,
        At = os.clock() }
    -- Runde 9 (build_polish): Ja-Knopf direkt beobachten (Klasse ist jetzt geladen), sonst 2 Hover-Proben
    if On("build_polish") then
        local okH, errH = pcall(OW.YnHook)
        if not okH then Core.Fail("build_polish", errH) end
    end
end

-- Gast: Schlaf-Fenster (b_ui slp). UE 5.6: HUD_Game_C.ShowSleepWidget prueft die Uhrzeit nicht mehr; Bett/Schlafsack
-- rufen BedComponent->GoToBed(1930, 630) (Bett/Schlafsack @019e: GetUDS-Zeit >= 19:30 oder <= 6:30, sonst Hinweis
-- "too early", dann GetGameHUD(self)->ShowSleepWidget(true)). Zelt @0bf1 (und 5.3 ohne BedComponent): ShowSleepWidget
function OW.GuestSleep(Key)
    local Obj = Key ~= "" and Resolve(Key) or nil
    if not Obj then return Log("Schlaf-Fenster: %s beim Gast nicht gefunden", tostring(Key)) end
    local BC = A.Safe(function() return Obj.BedComponent end)
    if A.IsAlive(BC) then
        local ok, err = pcall(function() BC:GoToBed(1930, 630) end)
        -- kein Rueckfall auf ShowSleepWidget: das wuerde die Uhrzeit-Pruefung umgehen
        return Log(ok and "Schlafen beim Gast angefordert (GoToBed)" or "GoToBed fehlgeschlagen: %s", tostring(err))
    end
    local Hud = OwnHud()
    if Hud and pcall(function() Hud:ShowSleepWidget(true) end) then Log("Schlaf-Fenster vom Host geoeffnet") end
end

local function OnUi(Data)
    if Net.Side ~= "client" then return end
    local Kind, Key, Extra = Data:match("^(%a+)|([^|]*)|?(.*)$")
    if not Kind then return end
    Key = Dec(Key)
    if Kind == "kp" and On("build_keypad") then OpenKeypad(Key, tonumber(Extra))
    elseif Kind == "ren" and On("build_rename") then OpenRename(Key)
    elseif Kind == "yn" and On("build_crate") then OpenYesNo(Key)
    elseif Kind == "lp" and On("build_lock") then
        B.LpN = math.max(0, math.floor(tonumber(Extra) or 0))
        OW.LockpickPatch()
    elseif Kind == "slp" and On("build_sleep") then
        OW.GuestSleep(Key)
    elseif Kind == "dn" and Core.Flag("locks_denyui", true) then
        OW.DenyUi(Key)
    elseif Kind == "kc" and On("build_kcard") then
        -- Runde 8: Karten im Server-Inventar (Allzugang|passende Karte) -> Gast-Patch build_kcard_h/_k
        local NA, NC = Extra:match("^(%d+)|(%d+)$")
        B.Kc = { Key = Key, All = tonumber(NA) or 0, Card = tonumber(NC) or 0, At = os.clock() }
        OW.KcPatch()
    elseif (Kind == "gsph" or Kind == "bsnd") and On("build_polish") then
        -- Runde 9 (BUILD-28): Generator-Reichweite (Option3 @0e9e) bzw. Bau-Ton (SpawnBuild @028b) beim Gast
        local ok, err = pcall(OW.UiPolish, Kind, Key, Extra)
        if not ok then Core.Fail("build_polish", err) end
    end
end

-- Gast: Kiste wurde fuer ihn gesperrt (b_ui dn). Ist ihr Fenster offen (IsInventoryVisible? der Kisten-Komponente,
-- wie OpenContainer @0f29), eigenes Inventar schliessen (wie ls_inv I.CloseOwnInv) und Neuabgleich vormerken
function OW.DenyUi(Key)
    local Obj = Resolve(Key)
    local CJ = Obj and A.Safe(function() return Obj.BP_JigMultiplayer end)
    if not A.IsAlive(CJ) then return end
    local T = {}
    if not pcall(function() CJ["IsInventoryVisible?"](CJ, T) end) then return end
    local Vis = T.Result
    if Vis == nil then for _, V in pairs(T) do Vis = V break end end
    if Vis ~= true then return end
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    local Jig = A.IsAlive(Pawn) and A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if A.IsAlive(Jig) then pcall(function() Jig:ToggleInventory() end) end
    local Inv = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_inv
    local ok, Done = false, false
    if Inv and type(Inv.Resync) == "function" then ok, Done = pcall(Inv.Resync, "Kiste gesperrt") end
    Log("Kiste %s gesperrt - Fenster geschlossen%s", tostring(Key), (ok and Done) and ", Inventar-Neuabgleich" or "")
end

-- Offenes Fenster frisch holen: ueber den Pfad, sonst (hoechstens 2/s) das erste Widget der Klasse
local function Widget(Path, Cls)
    local W = Path and StaticFindObject(Path)
    if A.IsAlive(W) then return W end
    if not Throttle("w_" .. Cls, 0.5) then return "wait" end
    W = A.Safe(function() return FindFirstOf(Cls) end)
    return A.IsAlive(W) and W or nil
end

-- Offene Fenster abfragen (100 ms): Tastenfeld-Code, neuer Kistenname, Ja/Nein
local function ClientWindows(Now)
    local K = B.Kp
    if K then
        local W = Widget(K.Path, "KeypadUI_C")
        local Open = W == "wait" or (W and A.Safe(function() return W:IsInViewport() end, false))
        if W and W ~= "wait" then K.Last = A.Safe(function() return W.CurrentCode:ToString() end, K.Last) or K.Last end
        if not Open or Now - K.At > 120 then
            if K.Last ~= "" and tonumber(K.Last) then Net.Send("b_code", Enc(K.Key) .. "|" .. K.Last, nil, 0) end
            B.Kp = nil
        end
    end
    local Rn = B.Ren
    if Rn then
        local Obj = Resolve(Rn.Key)
        local Name = Obj and A.Safe(function() return Obj.ContainerName:ToString() end)
        if Name and Name ~= Rn.Old then
            Net.Send("b_name", Enc(Rn.Key) .. "|" .. Enc(Name), nil, 0)
            B.Ren = nil
        elseif not Obj or Now - Rn.At > 120 then
            B.Ren = nil
        end
    end
    local Y = B.Yn
    if Y then
        local W = Widget(Y.Path, "ModularYesNoUI_C")
        local Open = W == "wait" or (W and A.Safe(function() return W:IsInViewport() end, false))
        if W == "wait" then
            Open = true
        elseif Open then
            Y.Yes = A.Safe(function()
                local Btn = W.Yes
                return A.IsAlive(Btn) and Btn:IsHovered()
            end, false) == true
            Y.YesN = Y.Yes and (Y.YesN or 0) + 1 or 0
        else
            -- Fenster zu: Maus stand auf "Ja" = bestaetigt (Ja/Nein schliessen das Fenster beide)
            -- Runde 9 (build_polish, BUILD-28): Klick auf "Ja" aus dem Knopf-Hook (OW.YnHook); ohne Hook mindestens
            -- 2 Hover-Proben auf "Ja" (ein schneller Wechsel zu "Nein" bestaetigt nicht mehr)
            local Ok = Y.Yes
            if On("build_polish") then
                local YY = B.YnYes
                if B.Hooks.yn then
                    Ok = YY ~= nil and YY.At >= Y.At and (YY.Path == nil or Y.Path == nil or YY.Path == Y.Path)
                else
                    Ok = (Y.YesN or 0) >= 2
                end
            end
            if Ok then Net.Send("b_pick", Enc(Y.Key), nil, 0) end
            B.Yn, B.YnYes = nil, nil
        end
        if B.Yn and Now - Y.At > 120 then B.Yn = nil end
    end
    if On("build_radio") and Throttle("radio_ui", 0.5) then
        local ok, err = pcall(OW.RadioWindows, Now)
        if not ok then Core.Fail("build_radio", err) end
    end
    -- Runde 8: Bau-Werkbank-Tab (build_bench), Stationsfenster aus der Ferne schliessen (build_stationclose)
    if Throttle("r8_ui", 0.5) then OW.ClientWindows8(Now) end
end

-- Radio-Fenster eines ANDEREN Spielers schliessen: MC_OnInteractBuildable ist Multicast, ToggleRadioUI (@011c Create
-- + AddToViewport + Eingabemodus) laeuft bei jedem Client. Eigenes = dieses Radio <= 3 s vorher angeschaut.
function OW.RadioWindows(Now)
    for Cls in pairs(RADIO) do
        for _, E in ipairs(B.H.ByCls[Cls] or {}) do
            local Obj = Fresh(E)
            local RC = Obj and A.Safe(function() return Obj.RadioComponent end)
            local UI = A.IsAlive(RC) and A.Safe(function() return RC.RadioUI end)
            if A.IsAlive(UI) then
                if not B.RadioOpen[E.Key] then
                    local F = B.RadioFoc
                    if F and F.Key == E.Key and Now - F.At <= 3 then
                        B.RadioOpen[E.Key] = true
                    else
                        pcall(function() RC:ToggleRadioUI(true) end)
                        Log("Radio-Fenster eines anderen Spielers geschlossen (%s)", E.Key)
                    end
                end
            else
                B.RadioOpen[E.Key] = nil
            end
            -- Runde 9 (build_radiosync, BUILD-20): eigenes Radio (Fenster offen bzw. bis 15 s danach) -> an/aus/Titel
            -- an den Host (b_radio), der es an alle verteilt (b_rd)
            if B.RadioOpen[E.Key] then B.RdMine[E.Key] = Now end
            local Mine = B.RdMine[E.Key]
            if Mine and Now - Mine > 15 then B.RdMine[E.Key], Mine = nil, nil end
            if Mine and A.IsAlive(RC) and On("build_radiosync") and Net.Has("brad") then
                local okS, errS = pcall(OW.RadioSend, E.Key, RC)
                if not okS then Core.Fail("build_radiosync", errS) end
            end
        end
    end
end

-- Host: Schlaf-Fenster, das das Spiel fuer einen GAST im Host-Viewport gebaut hat, schliessen (Gast hat per 'slp'
-- sein eigenes). Bett: Obj.SleepUI (Create ohne Besitzer, immer beim Host). Schlafsack/Zelt: HUD.SleepUI des Hosts,
-- nur wenn der Host-Pawn dabei gesperrt wurde (sonst lief GetGameHUD(0) per Owner-Kette beim Gast ins Leere).
-- Eingabe nur zurueckgeben, wenn APawn::DisableInput den Host-Pawn traf (InputEnabled false) und kein anderes
-- Schlaf-Fenster mehr offen ist. Eigene Host-Interaktion (B.HostSlp, 300 s) bleibt unangetastet.
function OW.HostSleepCleanup(Path, IsBed, Key, Who)
    local HS = B.HostSlp
    if HS and os.clock() - HS.At < 300 and (IsBed and HS.Path == Path or not IsBed) then
        return Log("Schlaf-Fenster beim Host belassen (eigene Schlaf-Interaktion des Hosts, %s)", tostring(Key))
    end
    local PC = A.LocalPC()
    local HP = A.IsAlive(PC) and A.Safe(function() return PC:K2_GetPawn() end) or nil
    if not A.IsAlive(HP) then HP = nil end
    local Locked = HP and A.Safe(function() return HP:InputEnabled() end, true) == false
    local Src
    if IsBed then
        Src = StaticFindObject(Path)
    elseif Locked then
        Src = OwnHud()
    end
    local U = A.IsAlive(Src) and A.Safe(function() return Src.SleepUI end) or nil
    if not (A.IsAlive(U) and A.Safe(function() return U:IsInViewport() end, false) == true) then return end
    pcall(function() U:RemoveFromParent() end)
    if not Locked then
        return Log("Schlaf-Fenster von %s beim Host geschlossen (%s, Eingabe unberuehrt)", tostring(Who), tostring(Key))
    end
    local All = A.Safe(function() return FindAllOf("SleepingUI_C") end)
    for _, W in ipairs(type(All) == "table" and All or {}) do
        if A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) == true then
            return Log("Schlaf-Fenster von %s beim Host geschlossen (%s), Host hat eigenes offen", tostring(Who), tostring(Key))
        end
    end
    pcall(function() HP:EnableInput(PC) end)
    OW.GameOnly(PC)   -- Runde 9 (CORE-20): WBL-CDO vor dem Aufruf pruefen
    pcall(function() PC.bShowMouseCursor = false end)
    Log("Schlaf-Fenster von %s beim Host geschlossen (%s), Eingabe freigegeben", tostring(Who), tostring(Key))
end

-- ---------------------------------------------------------------- Gast: Zustaende anwenden
local function CallFn(Obj, Spec, Pawn, WantOpen)
    if Spec.TL then
        if WantOpen then
            pcall(function()
                local TL = Obj[Spec.TL]
                if A.IsAlive(TL) then TL:PlayFromStart() end
            end)
        elseif Spec.CloseNil then
            pcall(function() Obj[Spec.Close](Obj, nil) end)
        else
            pcall(function() Obj[Spec.Close](Obj) end)
        end
        return
    end
    -- Runde 8: build_wdoorfix aus -> alter Weg (MC_OpenDoor mit eigener Figur)
    local Fn, Arg = Spec.Fn, Spec.Arg
    if Spec.OldFn and not On("build_wdoorfix") then Fn, Arg = Spec.OldFn, Spec.OldArg end
    if Spec.Pow and On("build_garagepow") then
        -- Garagentor (build_garagepow): ohne Strom zeigt OnInteractBuildable @0699 "Requires power" und bleibt zu ->
        -- PoweredOn? nur lokal fuer die Korrektur setzen, danach zurueck (OnRep feuert dabei nicht)
        local Old = A.Safe(function() return Obj["PoweredOn?"] end)
        pcall(function() Obj["PoweredOn?"] = true end)
        pcall(function() Obj[Fn](Obj, Pawn) end)
        if Old ~= nil then pcall(function() Obj["PoweredOn?"] = Old end) end
    elseif Arg then
        pcall(function() Obj[Fn](Obj, Pawn) end)
    else
        pcall(function() Obj[Fn](Obj) end)
    end
end

local function Toggle(Key, Obj, Spec, WantOpen, Pawn)
    local V = Obj[Spec.P] == true
    local Open = V
    if Spec.Inv then Open = not V end
    if Open == WantOpen then B.Tries[Key] = nil return end
    if Spec.Busy and Obj[Spec.Busy] == true then return end
    local Tr = (B.Tries[Key] or 0) + 1
    if Tr > 3 then return end
    B.Tries[Key] = Tr
    B.Next[Key] = os.clock() + 4
    CallFn(Obj, Spec, Pawn, WantOpen)
end

local function ApplyOne(Key, Value, Pawn)
    local Obj = Resolve(Key) or OW.ResolveLate(Key)   -- build_perf: noch nicht indizierter Bau in der Naehe
    if not Obj then return false end
    local Cls = ClsName(Obj)
    local Spec = SPEC[Cls]
    local F = {}
    for Part in (Value .. ";"):gmatch("([^;]*);") do F[#F + 1] = Part end
    local T = F[1]
    if T == "d" and Spec and Spec.T == "d" then
        local F3 = (F[3] == "0" or F[3] == "1") and F[3] or nil
        if Spec.Xp and F3 and On("build_kcard") then OW.SetXp(Obj, F3 == "1") end
        if Spec.Dot and F3 and On("build_doordir") then
            OW.DotApply(Key, Obj, Spec, F[2] == "1", Pawn, F3 == "1" and 1 or -1)
        else
            Toggle(Key, Obj, Spec, F[2] == "1", Pawn)
        end
    elseif T == "dl" and Spec then
        if F[3] == "0" and Obj["IsLocked?"] == true then pcall(function() Obj["IsLocked?"] = false end) end
        Toggle(Key, Obj, Spec, F[2] == "1", Pawn)
    elseif T == "k" and Spec then
        if (F[4] == "0" or F[4] == "1") and On("build_kcard") then OW.SetXp(Obj, F[4] == "1") end
        local Code = tonumber(F[3])
        if Code and Code ~= 0 and tonumber(Obj.Code) ~= Code then
            pcall(function()
                Obj.Code = Code
                if A.IsAlive(Obj.NoteRef) then Obj.NoteRef.Code = Code end
            end)
        end
        Toggle(Key, Obj, Spec, F[2] == "1", Pawn)
    elseif T == "l" then
        local Locked = F[2] == "1"
        local Picking = B.Pick and B.Pick.Key == Key
        if Obj["IsLocked?"] ~= Locked and not (Locked and Picking) then pcall(function() Obj["IsLocked?"] = Locked end) end
    elseif T == "n" then
        local Name = Value:sub(3)
        -- Runde 9 (build_polish): optionales 3. Feld = Gegenstands-Zahl (Namen enthalten kein ";" mehr, ReadState);
        -- die Zahl merkt schon der b_st-Handler (B.BoxN), hier nur abschneiden
        Name = Name:match("^(.-);%d+$") or Name
        if B.Ren and B.Ren.Key == Key then return true end   -- Gast benennt gerade selbst um
        if A.Safe(function() return Obj.ContainerName:ToString() end) ~= Name then
            pcall(function() Obj:OverrideBuildName(FText(Name)) end)
        end
    elseif T == "bs" and Spec and Spec.T == "bs" then
        if On("build_bunker") then OW.BunkerApply(Key, Obj, F[2] == "1", F[3] == "1") end
    elseif T == "v" then
        -- Runde 9 (build_display, BUILD-19): Vitrine - Mesh des ausgestellten Items (leer = nichts ausgestellt)
        if On("build_display") then OW.DisplayApply(Key, Obj, Dec(F[2] or "")) end
    elseif T == "h" then
        local Wave = tonumber(F[3]) or 0
        if B.Wave[Key] and Wave > B.Wave[Key] and F[2] == "1" and A.ShowNote then
            pcall(A.ShowNote, "Horde wave " .. Wave)
        end
        B.Wave[Key] = Wave
    elseif T == "t" then
        local Cls2 = ClassObj(P.TURRET)
        local C = Cls2 and A.Safe(function() return Obj:GetComponentByClass(Cls2) end)
        if A.IsAlive(C) then
            -- Tick bleibt an: Feuer-Timer setzt das Spiel nur beim Server (ReceiveBeginPlay IsServer), der Tick dreht
            -- beim Gast nur den Turm zum replizierten "Attack Target"
            pcall(function()
                C["Current Ammo"] = tonumber(F[2]) or 0
                C["Current Health"] = tonumber(F[3]) or 0
                C.Dead = F[4] == "1"
            end)
        end
    end
    return true
end

local function ClientApply(Now)
    if not On("build_state") then return end
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    if not A.IsAlive(Pawn) then return end
    local All = Now - B.ApplyAll > 5
    if All then B.ApplyAll = Now end
    local Budget = 40
    for Key, W in pairs(B.Want) do
        if Budget <= 0 then break end
        if (W.Dirty or All) and Now >= (B.Next[Key] or 0) then
            Budget = Budget - 1
            local ok, Found = pcall(ApplyOne, Key, W.V, Pawn)
            if ok and Found then W.Dirty = false end
        end
    end
    if On("build_hp") then
        for Key, H in pairs(B.Hp) do
            if H.Dirty then
                local Obj = Resolve(Key)
                if Obj then
                    pcall(function() Obj.Health = H.Hp end)
                    H.Dirty = false
                end
            end
        end
    end
end

-- SP-Geisterbauten: lokal gespawnte (Authority beim Gast) Bauten nach dem Beitritt entfernen
local function ClientGhosts(Now)
    if not On("build_ghost") or not B.GhostAt or Now < B.GhostAt then return end
    B.GhostRuns = B.GhostRuns + 1
    B.GhostAt = B.GhostRuns < 3 and Now + 30 or nil
    local N = 0
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not WL then return end
    for _, Obj in ipairs(A.Safe(function() return FindAllOf(MASTER) end) or {}) do
        -- wie IsClientGhost (main.lua): replizierende Klasse, Authority beim Gast und NICHT aus der Karte geladen
        -- (Karten-Actors haben direkt nach dem Beitritt noch Authority - die anzufassen liess den Client abstuerzen)
        if A.IsAlive(Obj) and A.Safe(function()
            return Obj:HasAuthority() and Obj.bReplicates == true and not Obj:HasAnyFlags(WL)
        end, false) == true then
            pcall(function() Obj:K2_DestroyActor() end)
            N = N + 1
        end
    end
    if N > 0 then Log("%d lokale Geisterbauten entfernt", N) end
end

-- ---------------------------------------------------------------- Runde 8: Interaktionen (Vertrag API.md §10)
-- Item-Felder (BP_JigMultiplayer-Strukturen, ls_inv F) und DisassemblyItems-Eintraege (W_DisassemblyWorkbenchUI @0014)
OW.IF = {
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA",
    CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28",
    MIN = "RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9",
    MAX = "RandomCountMax_18_C37B88104F52B02AA216B5912518580D",
    OUT = "ItemID_41_8C5E69274AB445604263E4A2B3091BAD",
}
-- Karten-/Hangartuer: UB-Einsprung des Erfolgszweigs nach der Kartenpruefung (Vertrag A6) und Gast-Patch (A8):
-- JumpIfNot(FindJigItemByDA) @0x9a2 -> L_0c85 bzw. @0xb18 -> L_0b39 wird zu Jump L_09b0 bzw. L_0b26
-- UE 5.6 geprueft (bp\BP_HangarDoor_C.kdis / BP_KeycardDoor_C.kdis): Offsets, Bytes und Einspruenge unveraendert
-- (Ubergraph-Diff nur Klassenname BP_JigComponent_C bzw. Keycard +1 Byte vor 0x66, danach deckungsgleich)
OW.KC = {
    BP_HangarDoor_C = { Ub = "ExecuteUbergraph_BP_HangarDoor", Entry = 2480, N = "build_kcard_h", Fn = P.HANGUB,
        Off = 2466, Old = "07850C0000", New = "06B0090000" },
    BP_KeycardDoor_C = { Ub = "ExecuteUbergraph_BP_KeycardDoor", Entry = 2854, N = "build_kcard_k", Fn = P.KCUB,
        Off = 2840, Old = "07390B0000", New = "06260B0000" },
}
-- Stationen mit Inventar-Fenster (build_stationlock / build_stationclose)
OW.STATIONS = { Buildable_TrashBin_C = true, Buildable_DisassemblyWorkbench_C = true, Buildable_CraftingWorkbench_C = true,
    Buildable_WeaponsEquipmentWorkbench_C = true, Buildable_Campfire_C = true, Buildable_ConstructionBench_C = true }
OW.PICKUPS = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }
-- Zerlegen-Knopf: UE 5.6 eigener Button (Stub -> ExecuteUbergraph_W_DisassemblyWorkbenchUI(15)), 5.3 ExitButton
OW.DIS_BTN = "BndEvt__W_DisassemblyWorkbenchUI_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
OW.DIS_BTN53 = "BndEvt__BP_BinWidget_ExitButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
OW.DIS_WHY = { off = "Zerlegen ist auf diesem Server aus", dist = "Zu weit von der Werkbank entfernt",
    rate = "Zu schnell - kurz warten", access = "Kein Zugriff", empty = "Nichts zum Zerlegen",
    bad = "Werkbank nicht gefunden", err = "Zerlegen fehlgeschlagen", busy = "Server beschaeftigt - nochmal versuchen",
    pawn = "Keine Figur", held = "Station belegt - ein anderer Spieler nutzt die Werkbank" }
-- Gast-Patches ret_early (Vertrag A8): Stub beginnt mit 46 + niedrigstes Adressbyte des Ubergraphs
OW.RET = {
    { N = "build_disasm", F = "build_disasm", FnF = function() return OW.DisPath() end,
        Ub = P.DISUI .. ":ExecuteUbergraph_W_DisassemblyWorkbenchUI" },
    { N = "build_beacon_w", F = "build_beacon", Fn = P.BEACON .. ":Event_NextWave",
        Ub = P.BEACON .. ":ExecuteUbergraph_Buildable_HordeBeacon" },
    { N = "build_beacon_d", F = "build_beacon", Fn = P.BEACON .. ":Event_PlayerDead",
        Ub = P.BEACON .. ":ExecuteUbergraph_Buildable_HordeBeacon" },
}

-- UE4SS-Ausgabeparameter: Wert unter dem Namen, sonst der einzige Eintrag (wie ls_inv I.Out)
function OW.Out(T, Name)
    if type(T) ~= "table" then return nil end
    if T[Name] ~= nil then return T[Name] end
    for _, V in pairs(T) do return V end
    return nil
end

-- UE 5.6: AddNewItemSomewhere hat 10 Parameter (neu an 6. Stelle SpecificContainer:Name, 'None' wie
-- BP_AnimalBear_C.Death @0106): ItemId, Count, ItemInside, ItemInsideCount, DropIfFailedToAdd?, SpecificContainer,
-- &Added, &Dropped?, &ItemUID, &AddedToUID. Fehler -> Lua-Fehler (Aufrufer nutzt pcall)
function OW.AddItem(J, DA, N, Drop, AddT, DropT)
    J:AddNewItemSomewhere(DA, N, nil, 0, Drop == true, FName("None"), AddT or {}, DropT or {}, {}, {})
end

-- UE 5.6: BuildableMaster_Container_C/_Tent_C.DropAll entfernt; das Spiel (Zelt @0eef) ruft
-- self.BP_JigMultiplayer->DropAllItems() (HandleServerDropRequest je Item -> JigMP_OnRequestDropItem des Baus).
-- Rueckfall 5.3: DropAll des Baus
function OW.DropAll(Obj)
    local CJ = A.Safe(function() return Obj.BP_JigMultiplayer end)
    if A.IsAlive(CJ) and pcall(function() CJ:DropAllItems() end) then return true end
    return pcall(function() Obj:DropAll() end)
end

-- Zerlegen-Knopf der geladenen Spielversion (5.6 zuerst, sonst 5.3)
function OW.DisPath()
    local P6 = P.DISUI .. ":" .. OW.DIS_BTN
    if OW.FnAddr(P6) or not OW.FnAddr(P.DISUI .. ":" .. OW.DIS_BTN53) then return P6 end
    return P.DISUI .. ":" .. OW.DIS_BTN53
end

-- Brecheisen-Zweig von ExecuteUbergraph_BP_LockedDoor (ReportNoiseEvent -> Event_Door [-> 5.6: XP Stufe*75]):
-- UE 5.6 L_0a52 = 2642 (OnExecuteInteract @0cd6 FindCrowbar -> goto L_0a52), 5.3 L_093f = 2367.
-- Version: 5.6 = neue Funktion BP_LockedDoor_C.FindCrowbar, 5.3 = Klasse BP_JigMultiplayer_C geladen; sonst nil
-- (unklar -> kein Einsprung, nie einen falschen Offset anspringen)
OW.LD_CROW56, OW.LD_CROW53 = 2642, 2367
function OW.LdEntry()
    if OW.FnAddr(P.LDOOR .. ":FindCrowbar") then return OW.LD_CROW56 end
    local Old = StaticFindObject("/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C")
    if A.IsAlive(Old) then return OW.LD_CROW53 end
    return nil
end

-- TArray als Lua-Liste: UFunction-Rueckgaben/Out-Arrays sind Lua-Tabellen, Eigenschaften TArray-Userdata (ls_world)
function OW.ArrList(V)
    local L = {}
    if type(V) == "table" then
        for _, E in ipairs(V) do L[#L + 1] = E end
    elseif V ~= nil then
        pcall(function() V:ForEach(function(_, E) L[#L + 1] = E:get() end) end)
    end
    return L
end

function OW.InvVisible(CJ)
    local T = {}
    if not pcall(function() CJ["IsInventoryVisible?"](CJ, T) end) then return false end
    return OW.Out(T, "Result") == true
end

-- GameFunctionLibrary.GetBehindObject?(Objekt, Figur, 0, Kontext, Out) wie MC_OpenDoor @01ad / LockedDoor @0d05 (5.6)
function OW.Behind(Obj, Pawn)
    local Lib = StaticFindObject(P.GFL)
    if not A.IsAlive(Lib) then return false end
    local Out = {}
    if not pcall(function() Lib["GetBehindObject?"](Lib, Obj, Pawn, { X = 0, Y = 0, Z = 0 }, Obj, Out) end) then
        return false
    end
    return OW.Out(Out, "BehindObject?") == true
end

-- Host-Pruefkette je Gast-Anfrage (Vertrag A1): Gast verbunden, Figur lebt und ist nicht tot, <= 8 Anfragen/s je
-- Gast, derselbe Schluessel je Art hoechstens alle 0,25 s. Rueckgabe Figur oder nil, Grund
function OW.Pre(G, Kind, Key)
    if not (G and G.Epoch and Net.Guests[G.Key]) then return nil, "off" end
    local Pawn = GuestPawn(G)
    if not Pawn or A.Safe(function() return Pawn["PlayerDead?"] end, false) == true then return nil, "pawn" end
    local Now = os.clock()
    local R0 = B.GRate[G.Key]
    if not R0 or Now - R0.T >= 1 then
        R0 = { T = Now, N = 0 }
        B.GRate[G.Key] = R0
    end
    R0.N = R0.N + 1
    local L = B.GLast[Kind .. G.Key]
    if R0.N > 8 or (L and L.K == Key and Now - L.T < 0.25) then
        Net.SecWarn(G, G.Key, Kind .. "_rate")
        return nil, "rate"
    end
    B.GLast[Kind .. G.Key] = { K = Key, T = Now }
    return Pawn
end

-- Handler: Schalter + Cap pruefen und einreihen; der Spielaufruf laeuft im build_fast-Takt (RunLater)
function OW.Queue(Flag, G, Fn, Msg)
    if Net.Side ~= "host" then return end
    if not On(Flag) or not (G and G.Epoch) or not Net.Has(CAP, G) then
        if Msg then Net.Reply(Msg, "no|off") end
        return
    end
    if #B.Later > 200 then
        if Msg then Net.Reply(Msg, "no|busy") end
        return
    end
    Later(0, function()
        local ok, err = pcall(Fn)
        if not ok then
            Core.Fail(Flag, err)
            if Msg then Net.Reply(Msg, "no|err") end
        end
    end)
end

-- ---- B2 build_kcard (Host)
-- Hook-Koerper (nur Tabellen): Kartentuer laut Index + interagierende Komponente gehoert einem Gast
function OW.KcEv(Ev)
    local E = B.H.ByName[Ev.Act]
    if E and OW.KC[E.Cls] and GuestOfComp(Ev.Comp) then Ev.Kc = true end
end

-- HostInteract: Ev.Kc-Eintraege vorab ausfuehren (der Spielweg wurde im Hook entfernt), Rest zurueck
function OW.KcSplit(Q)
    local Rest = {}
    for _, Ev in ipairs(Q) do
        if Ev.Kc or Ev.Bunk then
            local G = Ev.Comp and GuestOfComp(Ev.Comp)
            local Path = PathOf(Ev.Act)
            if G and Path then
                -- Runde 9: Bunker-Scanner (build_bunker) wie Kartentueren vorab beim Host
                local Fn, Flag = OW.KcHost, "build_kcard"
                if Ev.Bunk then Fn, Flag = OW.BunkerHost, "build_bunker" end
                local ok, err = pcall(Fn, G, Path)
                if not ok then Core.Fail(Flag, err) end
            end
        else
            Rest[#Rest + 1] = Ev
        end
    end
    return Rest
end

-- Wie OnServerExecuteInteract (Distanz < 500 @02a7/@022b, dann MC_OpenDoor(ByActor) @0327/@02ab), aber mit der
-- Allzugangskarte aus dem Server-Inventar (CountOf statt FindJigItemByDA, Vertrag A5) -> UB-Einsprung L_09b0/L_0b26
-- (XP Stufe*200 einmal je XPGiven? ueber die Owner-Kette @09c3/@0c93, Hinweis, Ton, Timeline)
function OW.KcHost(G, Path)
    -- Vertrag A1: dieselbe Tuer je Gast hoechstens alle 0,25 s, <= 8 Anfragen/s je Gast (wie LdHost/KcQuery)
    if not OW.Pre(G, "b_kc", Path) then return end
    local Obj = Path and StaticFindObject(Path)
    if not A.IsAlive(Obj) then return end
    local Pawn = GuestPawn(G)
    if not Pawn or A.Safe(function() return Pawn["PlayerDead?"] end, false) == true then return end
    local Cls = ClsName(Obj)
    local Kc = Cls and OW.KC[Cls]
    if not Kc then return end
    local X, Y, Z = Loc(Obj)
    local PX, PY, PZ = Loc(Pawn)
    if not (X and PX) or Dist(PX, PY, PZ, X, Y, Z) >= 500 then return end
    if M.CanUse(G.GuestId, Obj) == false then return OW.Note(G, "Kein Zugriff", true) end
    local ok, err = pcall(function() Obj:SetOwner(Pawn) end)
    if not ok then return Core.Fail("build_kcard", err) end
    local Open = A.Safe(function() return Obj["Open?"] end, false) == true
    local AllDA = not Open and FindAsset(P.ALLKC) or nil
    local NAll = AllDA and CountOf(JigOf(Pawn), AllDA) or 0
    if not Open and (NAll or 0) > 0 and not OW.Behind(Obj, Pawn) then
        ok, err = pcall(function() Obj[Kc.Ub](Obj, Kc.Entry) end)
        Log("Allzugangskarte: %s fuer %s (%s)", Cls, tostring(G.PawnName), ok and "ok" or tostring(err))
        if not ok then Core.Fail("build_kcard", err) end
    else
        ok, err = pcall(function() Obj:MC_OpenDoor(Pawn) end)
        if not ok then Core.Fail("build_kcard", err) end
    end
    local Key = KeyOf(Obj)
    -- hoechstens ein ausstehendes kc| je Gast + Tuer
    local PK = Key and (G.Key .. "|" .. Key)
    if PK and not (OW.KcPend[PK] and os.clock() - OW.KcPend[PK] < 3) then
        OW.KcPend[PK] = os.clock()
        Later(0.6, function()
            OW.KcPend[PK] = nil
            OW.KcSend(G, Key)
        end)
    end
end
OW.KcPend = {}

-- b_ui "kc|Schluessel|<Allzugang>|<passende Karte>" (Zaehlung im Server-Inventar)
function OW.KcSend(G, Key)
    if not (G and G.Epoch) then return end
    local Obj = Resolve(Key)
    local Jig = JigOf(GuestPawn(G))
    if not (Obj and Jig) then return end
    local AllDA = FindAsset(P.ALLKC)
    local Card = A.Safe(function() return Obj.Keycard end)
    local NA = AllDA and CountOf(Jig, AllDA) or 0
    local NC = A.IsAlive(Card) and CountOf(Jig, Card) or 0
    UiSend(G, string.format("kc|%s|%d|%d", Enc(Key), math.floor(NA or 0), math.floor(NC or 0)))
end

function OW.KcQuery(G, Key)
    if not OW.Pre(G, "b_kcq", Key) then return end
    local Obj = NearObj(G, Key, "b_kcq", true)
    if not Obj or not OW.KC[ClsName(Obj) or ""] then return end
    OW.KcSend(G, Key)
end

-- ---- Runde 9 build_bunker (BUILD-5/WORLD-3): Bunker-Scanner wie MC_CallInteract @05a3-@0742, nur beim Host.
-- Zustand per b_st "bs" an alle (auch Spaetjoiner), Tueren ueber b_st "d" (Open? ist nicht repliziert)
function OW.BunkerHost(G, Path)
    local Pawn = OW.Pre(G, "b_bunk", Path)
    local Obj = Pawn and StaticFindObject(Path)
    if not A.IsAlive(Obj) then return end
    local X, Y, Z = Loc(Obj)
    local PX, PY, PZ = Loc(Pawn)
    if not (X and PX) or Dist(PX, PY, PZ, X, Y, Z) >= 500 then return end   -- wie @035c GetDistanceTo < 500
    local Ls = OW.ArrList(A.Safe(function() return Obj.ListeningActor end))
    if #Ls == 0 then return end   -- @05a3 Array_IsValidIndex(ListeningActor, 0)
    -- FindKeycard @02cf GetLevellingComponent(self) -> CastToController -> Owner-Kette -> Gast-PC (XP Stufe*200)
    pcall(function() Obj:SetOwner(Pawn) end)
    local XpAll = false
    if Obj["KeycardRequired?"] == true then
        -- @009f FindJigItemByDA(Allzugang) ist beim Host fuer Gast-Kopien immer falsch (Vertrag A5) -> Server-Inventar
        -- zaehlen; Allzugang = frei ohne Verbrauch (KeycardRequired? aus -> FindKeycard @0192 Found)
        local AllDA = FindAsset(P.ALLKC)
        if AllDA and (CountOf(JigOf(Pawn), AllDA) or 0) > 0 then
            XpAll = Obj["Unlocked?"] ~= true and Obj.GiveXPOnInteraction == true
            Obj["KeycardRequired?"] = false
        end
    end
    local Out = {}
    -- Karte aus dem Server-Inventar (ServerFindThenConsumeByItemID @01d5), XP beim ersten Entsperren, Ton
    local okF, errF = pcall(function() Obj:FindKeycard(Pawn, Out) end)
    if not okF then return Core.Fail("build_bunker", errF) end
    if OW.Out(Out, "Found?") ~= true then return OW.Note(G, "No Keycard Available", true) end
    Obj["Unlocked?"], Obj["KeycardRequired?"] = true, false
    local Sc, Green = A.Safe(function() return Obj.Scanner end), FindAsset(P.BK_GREEN)
    if A.IsAlive(Sc) and Green then pcall(function() Sc:SetMaterial(1, Green) end) end
    -- Allzugang beim ersten Entsperren: XP wie @02c1-@0341 (dieser Zweig war beim Host fuer Gaeste nie erreichbar)
    if XpAll then OW.BunkerXp(G) end
    local N = 0
    for _, L in ipairs(Ls) do
        if A.IsAlive(L) and pcall(function() L:CallInteractOnObject() end) then N = N + 1 end
    end
    Log("Bunker-Scanner von %s: %d Tuer(en) umgeschaltet%s", tostring(G.PawnName), N, XpAll and " (Allzugangskarte, XP)" or "")
end

-- XP Stufe*200 ueber die LevellingComponent des Gast-PCs (wie ls_world Belohnungen)
function OW.BunkerXp(G)
    local PC = Net.PC(G)
    local LC = PC and A.Safe(function() return PC.LevellingComponent end)
    if not A.IsAlive(LC) then return end
    local Lvl = math.max(1, math.floor(tonumber(A.Safe(function() return LC.CurrentLevel end)) or 1))
    local ok, err = pcall(function() LC:AddXP(Lvl * 200, false, {}) end)
    if not ok then Core.Fail("build_bunker", err) end
end

-- Gast: Scanner-Zustand wie MC_CallInteract @060f-@065e (Material 1 gruen/rot); UnlockedSoundCue (FindKeycard @0139)
-- nur bei der miterlebten Flanke zu -> offen (nicht beim ersten Anwenden nach dem Beitritt)
function OW.BunkerApply(Key, Obj, U, K)
    B.BkSeen = B.BkSeen or {}
    local Last = B.BkSeen[Key]
    if (Obj["Unlocked?"] == true) ~= U then pcall(function() Obj["Unlocked?"] = U end) end
    if (Obj["KeycardRequired?"] == true) ~= K then pcall(function() Obj["KeycardRequired?"] = K end) end
    if Last == U then return end
    B.BkSeen[Key] = U
    local Sc, Mat = A.Safe(function() return Obj.Scanner end), FindAsset(U and P.BK_GREEN or P.BK_RED)
    if A.IsAlive(Sc) and Mat then pcall(function() Sc:SetMaterial(1, Mat) end) end
    if U and Last == false then
        local GS = A.UEHelpers and A.Safe(function() return A.UEHelpers.GetGameplayStatics() end)
        local Cue = A.Safe(function() return Obj.UnlockedSoundCue end)
        local X, Y, Z = Loc(Obj)
        if A.IsAlive(GS) and A.IsAlive(Cue) and X then
            pcall(function()
                GS:PlaySoundAtLocation(Obj, Cue, { X = X, Y = Y, Z = Z }, { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil, nil)
            end)
        end
    end
end

-- ---- B2 build_kcard (Gast): Fokus -> b_kcq, Patch nur solange diese Tuer angeschaut wird (bzw. < 3 s danach)
function OW.KcFocus(Act, Pawn, Now)
    local K = nil
    local Cls = A.IsAlive(Act) and ClsName(Act)
    if Cls and OW.KC[Cls] then
        local K0, _, X, Y, Z = KeyOf(Act)
        local PX, PY, PZ = Loc(Pawn)
        if K0 and PX and Dist(PX, PY, PZ, X, Y, Z) < 500 then K = K0 end
    end
    if K == B.KcFoc then return end
    if K and not Net.Send("b_kcq", Enc(K), nil, 0) then return end
    if B.KcFoc then B.KcLeft = { Key = B.KcFoc, At = Now } end
    B.KcFoc = K
end

-- build_kcard_patch: Karteninhaber bekommen beim MC des Hosts den SP-Erfolgsweg (XP-Hinweis/Erfolg) statt des falschen
-- "No Keycard Available" (@0d51/@0c05: ServerFindThenConsume auf dem leeren MainJigContainers des Gasts)
function OW.KcPatch()
    if not Core.HasPatchRegistry() then return end
    local K, Now = B.Kc, os.clock()
    local Foc = K ~= nil and (B.KcFoc == K.Key or (B.KcLeft ~= nil and B.KcLeft.Key == K.Key and Now - B.KcLeft.At < 3))
    local Base = Net.Side == "client" and Net.Has(CAP) and On("build_kcard") and On("build_kcard_patch")
        and K ~= nil and Now - K.At < 30 and (K.Card or 0) > 0 and Foc
    for Cls, Kc in pairs(OW.KC) do
        local Want = (Base and ParseKey(K.Key) == Cls) and true or false
        local Cur = B.KcLine[Cls]
        if Want or (Cur and Cur:sub(-1) == "1") then
            local Fn = StaticFindObject(Kc.Fn)
            if not A.IsAlive(Fn) then
                if not Want then B.KcLine[Cls] = nil end   -- Klasse entladen: die DLL hat den Patch verworfen
            else
                local Line = string.format("%s bytes %x %d %s %s %d", Kc.N, Fn:GetAddress(), Kc.Off, Kc.Old, Kc.New,
                    Want and 1 or 0)
                if Line ~= Cur and Core.SetPatch(Kc.N, Line) then
                    B.KcLine[Cls] = Line
                    Log("Kartentuer-Patch %s %s angefordert (Karten laut Host: %d)", Kc.N, Want and "an" or "aus",
                        K and K.Card or 0)
                end
            end
        end
    end
end

-- ---- B3 build_kpclean (Host): KeypadUI des Gasts im Host-Viewport schliessen, Eingabe wie OW.HostSleepCleanup
function OW.KpClean(Path, Who)
    local Door = StaticFindObject(Path)
    if not A.IsAlive(Door) then return end
    local DAddr = Door:GetAddress()
    local N, Other = 0, false
    local All = A.Safe(function() return FindAllOf("KeypadUI_C") end)
    for _, W in ipairs(type(All) == "table" and All or {}) do
        if A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) == true then
            local Ref = A.Safe(function() return W.DoorRef end)
            if A.IsAlive(Ref) and Ref:GetAddress() == DAddr then
                if pcall(function() W:RemoveFromParent() end) then N = N + 1 end
            else
                Other = true
            end
        end
    end
    if N == 0 then return end
    local PC = A.LocalPC()
    local HP = A.IsAlive(PC) and A.Safe(function() return PC:K2_GetPawn() end) or nil
    local Locked = A.IsAlive(HP) and A.Safe(function() return HP:InputEnabled() end, true) == false
    if Locked and not Other then
        local Sl = A.Safe(function() return FindAllOf("SleepingUI_C") end)
        for _, W in ipairs(type(Sl) == "table" and Sl or {}) do
            if A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) == true then Other = true break end
        end
    end
    local Free = Locked and not Other
    if Free then
        pcall(function() HP:EnableInput(PC) end)
        OW.GameOnly(PC)   -- Runde 9 (CORE-20): WBL-CDO vor dem Aufruf pruefen
        pcall(function() PC.bShowMouseCursor = false end)
    end
    Log("Tastenfeld von %s beim Host geschlossen%s", tostring(Who), Free and " (Eingabe freigegeben)" or "")
end

-- ---- B4 build_ldoor: Gast-Hook (nur Tabellen) -> b_ldoor; Host fuehrt die Tuer mit Owner-Trick aus
function OW.LdHook(Ctx, Actor, Option)
    if Net.Side ~= "client" or #B.LdQ >= 40 then return end
    local Ev = { At = os.clock() }
    pcall(function() Ev.Path = PathOf(Ctx:get():GetFullName()) end)
    pcall(function() Ev.Opt = Option:get().TagName:ToString() end)
    pcall(function()
        local Ac = Actor:get()
        if A.IsAlive(Ac) then Ev.Who = Ac:GetFullName() end
    end)
    B.LdQ[#B.LdQ + 1] = Ev
end

-- Bestes Brecheisen im Server-Inventar (MainJigContainers, Haltbarkeit .X). nil = unlesbar, false = keins
-- 2. Rueckgabe: UniqueServerID dieses Brecheisens (Lua-Tabelle A..D) fuer den Haltbarkeits-Abzug (UE 5.6)
function OW.Crowbar(Pawn)
    local Jig, Crow = JigOf(Pawn), FindAsset(P.CROWBAR)
    if not (Jig and Crow) then return nil end
    local CA, IF, Best, Uid = Crow:GetAddress(), OW.IF, false, nil
    Jig.MainJigContainers:ForEach(function(_, CE)
        CE:get()[IF.ITEMS]:ForEach(function(_, IE)
            local It = IE:get()
            local Info = It[IF.INFO]
            local DA = Info[IF.ID]
            if A.IsAlive(DA) and DA:GetAddress() == CA then
                local D = Info[IF.DUR]
                local X, Y = tonumber(D.X) or 0, tonumber(D.Y) or 0
                LogOnce("crowdur", "Brecheisen-Haltbarkeit gelesen: X=%.1f Y=%.1f", X, Y)
                if not Best or X > Best then
                    Best = X
                    Uid = A.Safe(function()
                        local U = It[IF.UID]
                        return { A = U.A, B = U.B, C = U.C, D = U.D }
                    end)
                end
            end
        end)
    end)
    return Best, Uid
end

-- OnExecuteInteract (5.6 @0c45, 5.3 @0b32; beim Gast lokal, OnServerExecuteInteract 5.6 @008c / 5.3 @0224 leer):
-- Option1 vorn/hinten, Option2 Brecheisen
function OW.LdHost(G, Key, N)
    local Pawn = OW.Pre(G, "b_ldoor", Key)
    if not Pawn then return end
    local Obj = NearObj(G, Key, "b_ldoor", true)
    if not Obj or ClsName(Obj) ~= "BP_LockedDoor_C" then return end
    if not Throttle("ld" .. G.Key, 0.5) then return end
    if M.CanUse(G.GuestId, Obj) == false then return OW.Note(G, "Kein Zugriff", true) end
    pcall(function() Obj:SetOwner(Pawn) end)
    local Locked = A.Safe(function() return Obj["IsLocked?"] end, false) == true
    if N == 1 then
        -- 5.6 @0d05 (5.3 @0e49): hinten -> verschlossen EventDoorBehind, sonst Event_Door; vorn offen -> Event_Door @0dc4
        -- (vorn verschlossen = Dietrich-Minispiel, bleibt b_lpq/b_unlock)
        local ok, err = pcall(function()
            if OW.Behind(Obj, Pawn) then
                if Locked then Obj:EventDoorBehind() else Obj:Event_Door() end
            elseif not Locked then
                Obj:Event_Door()
            end
        end)
        if not ok then Core.Fail("build_ldoor", err) end
    elseif N == 2 and Locked then
        -- UE 5.6 FindCrowbar (@0cd6): Brecheisen da; nur bei CVar Difficulty.OtherItemsDurability (@00a3) zusaetzlich
        -- Haltbarkeit > 10 * Difficulty.OtherItemsDurabilityMultiplier und Abzug 10 * Mult per
        -- ServerFuncUpdateDurabilityByUID(UID, .., true) (@0284; 5.3: immer Pruefung, Abzug mit Guid 0 = No-op)
        local Entry = OW.LdEntry()
        if not Entry then
            return LogOnce("crowver", "Brecheisen-Tuer: Spielversion nicht erkannt - Einsprung aus (nicht verifiziert)")
        end
        local V56 = Entry == OW.LD_CROW56
        local okC, Best, Uid = pcall(OW.Crowbar, Pawn)
        if not okC or Best == nil then
            return LogOnce("crowbad", "Brecheisen-Tuer: Server-Inventar unlesbar (%s)", tostring(okC and "?" or Best))
        end
        if Best == false then return OW.Note(G, "No crowbar found") end
        local CU = StaticFindObject(P.CU)
        local Mult = A.IsAlive(CU) and tonumber(A.Safe(function()
            return CU:GetFloatCVar(FName("Difficulty.OtherItemsDurabilityMultiplier"))
        end)) or 1
        local DurOn = not V56 or (A.IsAlive(CU) and A.Safe(function()
            return CU:GetBoolCVar(FName("Difficulty.OtherItemsDurability"))
        end, true) ~= false)
        if DurOn and Best <= 10 * Mult then
            return OW.Note(G, V56 and "No durability - Crowbar" or "Crowbar durability too low")
        end
        -- 5.6 L_0a52 (5.3 L_093f): ReportNoiseEvent an GetPlayerCharacter(0) (Owner-Kette -> Gast) + Event_Door
        -- (5.6 danach L_078c: XP Stufe*75 ueber GetLevellingComponent(self) -> Owner-Kette -> Gast)
        local ok, err = pcall(function() Obj:ExecuteUbergraph_BP_LockedDoor(Entry) end)
        Log("Brecheisen-Tuer von %s aufgebrochen (%s)", tostring(G.PawnName), ok and "ok" or tostring(err))
        if not ok then return Core.Fail("build_ldoor", err) end
        -- 5.6: Haltbarkeit wie FindCrowbar abziehen (beim Host auf MainJigContainers, CLIENT_UpdateDurability an den Gast)
        if V56 and DurOn and Uid and Core.Flag("build_crowdur", true) then
            local Jig = JigOf(Pawn)
            local okD, errD = pcall(function() Jig:ServerFuncUpdateDurabilityByUID(Uid, 10 * Mult, true, {}) end)
            if not okD then Core.Fail("build_crowdur", errD) end
        end
    end
end

-- ---- B5 build_pickinv (Host): Bodenobjekt (Laufzeit, frei, <= 300 uu um den Gast, gleiches Item) ins Inventar
-- MaxAge (optional, s): nur Bodenobjekte, die seit hoechstens MaxAge existieren (GetGameTimeSinceCreation)
-- DA: ein DataAsset oder Lua-Liste von DataAssets (ein einziger Scan fuer alle; Treffer bekommt sein eigenes DA)
function OW.GroundToInv(G, DA, Max, Why, MaxAge)
    if not G then return 0 end
    local ByAddr, First = {}, nil
    for _, D0 in ipairs(type(DA) == "table" and DA or { DA }) do
        if A.IsAlive(D0) then
            local Ad = D0:GetAddress()
            ByAddr[Ad] = D0
            First = First or Ad
        end
    end
    if not First then return 0 end
    if not Throttle("g2i" .. G.Key .. ":" .. tostring(First), 1.0) then return 0 end
    local Pawn = GuestPawn(G)
    local Jig = JigOf(Pawn)
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not (Jig and WL) then return 0 end
    local PX, PY, PZ = Loc(Pawn)
    if not PX then return 0 end
    local Cand = {}
    for _, Cls in ipairs(OW.PICKUPS) do
        for _, O in ipairs(A.Safe(function() return FindAllOf(Cls) end) or {}) do
            -- billige Filter (Flags/Alter) vor der Positionsabfrage: Level-Pickups fallen ohne Loc() raus
            if A.IsAlive(O) and A.Safe(function()
                if O:HasAnyFlags(WL) then return false end
                if MaxAge then
                    local Age = tonumber(O:GetGameTimeSinceCreation())
                    if not Age or Age > MaxAge then return false end
                end
                return true
            end, false) == true then
                local X, Y, Z = Loc(O)
                local D = X and Dist(PX, PY, PZ, X, Y, Z)
                local Hit = D and D <= 300 and A.Safe(function()
                    if A.IsAlive(O:GetAttachParentActor()) then return nil end
                    local C = O.BP_JigPickupComponent
                    local IDA = A.IsAlive(C) and C.ItemDataAsset or nil
                    return A.IsAlive(IDA) and ByAddr[IDA:GetAddress()] or nil
                end)
                if Hit then
                    Cand[#Cand + 1] = { O = O, D = D, DA = Hit }
                end
            end
        end
    end
    table.sort(Cand, function(P1, P2) return P1.D < P2.D end)
    local Moved = 0
    for I = 1, math.min(Max or 1, #Cand) do
        local O, DA1 = Cand[I].O, Cand[I].DA
        local Out, AddT, DropT = {}, {}, {}
        pcall(function() O.BP_JigPickupComponent:GetCount(Out) end)
        local Cnt = math.max(1, math.floor(tonumber(OW.Out(Out, "Count")) or 1))
        local ok = pcall(OW.AddItem, Jig, DA1, Cnt, true, AddT, DropT)
        if ok and not (OW.Out(AddT, "Added") == false and OW.Out(DropT, "Dropped?") ~= true) then
            pcall(function() O:K2_DestroyActor() end)
            Moved = Moved + 1
            Log("%s: Item lag am Boden - ins Inventar von %s (%dx)", tostring(Why), tostring(G.PawnName), Cnt)
        end
    end
    return Moved
end

-- HostInteract-Ergaenzung (Gast-Interaktion, Objekt lebt): Stationsfenster merken, Brunnen-Befuellung
function OW.HostInteractR8(G, Obj, Opt, Ev)
    if not Opt:match("Option1$") then return end
    local Cls = ClsName(Obj)
    -- Runde 9 (build_beacondeath): Option1 = Event_StartHorde (@1987, schaltet an/aus) -> Starter merken (OW.BeaconTick)
    if Cls == "Buildable_HordeBeacon_C" and Ev.Act and On("build_beacondeath") then
        local Pawn = GuestPawn(G)
        local PP = Pawn and PathOf(A.Safe(function() return Pawn:GetFullName() end))
        B.BeaconBy[PathOf(Ev.Act) or Ev.Act] = { Key = G.Key, Pawn = PP, At = Ev.At or os.clock() }
    end
    if Cls and OW.STATIONS[Cls] and Ev.Act and On("build_stationlock") then
        -- offenes Fenster eines anderen Gasts nicht ueberschreiben (sonst kann er die Station nie zurueckholen)
        if OW.StationHeld(Obj, G) then
            local R0 = B.StationOpen[Ev.Act]
            local G2 = R0 and Net.Guests[R0.Key]
            if Throttle("stheld" .. G.Key, 5) then
                OW.Note(G, "Station belegt - " .. tostring(G2 and G2.PawnName or "?") .. " nutzt sie gerade", true)
            end
        else
            B.StationOpen[Ev.Act] = { Key = G.Key, At = Ev.At }
        end
    end
    -- Brunnen @029c/@0471/@064a: JigTryAddItemSomewhere fuer die Gast-Komponente wirft das Wasser vor die Fuesse.
    -- Nur gefuellt, wenn @0224/@03f9/@05d2/@07ae einen leeren Behaelter verbraucht hat (sonst pop flow / @07f8) ->
    -- nur Bodenobjekte, die seit dieser Interaktion entstanden sind (keine alten/fremden Wasser-Pickups)
    -- Runde 9 (WORLD-11): Karten-Brunnen BP_WaterWell_C genauso (Option1 @1398 -> @0c31, JigTryAddItemSomewhere
    -- @0da1/@0f76/@114f)
    if (Cls == "Buildable_WaterWell_C" or Cls == "BP_WaterWell_C") and On("build_pickinv") then
        local At = Ev.At or os.clock()
        Later(0.4, function()
            local MaxAge = os.clock() - At + 0.5
            local DAs = {}
            for _, DP in ipairs(P.WATER) do
                DAs[#DAs + 1] = FindAsset(DP)
            end
            OW.GroundToInv(G, DAs, 1, "Brunnen", MaxAge)
        end)
    end
end

-- ---- B11 build_stationlock (Host): Station gehoert gerade einem anderen Gast mit offenem Fenster?
function OW.StationHeld(Obj, G)
    if not On("build_stationlock") then return false end
    local Nm = A.Safe(function() return Obj:GetFullName() end)
    local R0 = Nm and B.StationOpen[Nm]
    if not R0 or R0.Key == G.Key then return false end
    local G2 = Net.Guests[R0.Key]
    local P2 = G2 and os.clock() - R0.At < 120 and GuestPawn(G2)
    if not P2 then
        B.StationOpen[Nm] = nil
        return false
    end
    local X, Y, Z = Loc(Obj)
    local PX, PY, PZ = Loc(P2)
    local Held = X ~= nil and PX ~= nil and Dist(PX, PY, PZ, X, Y, Z) <= 400
    if Held then LogOnce("sthold" .. Nm, "Station %s bleibt bei %s (Fenster offen)", tostring(ClsName(Obj)), tostring(G2.PawnName)) end
    return Held
end

-- locks_hookfirst (CORE-18): wie OW.StationHeld, aber nur Lua-Tabellen (Hook-Koerper SERVER_ForwardInteract):
-- Station-Position aus dem Index, Position des haltenden Gasts aus dem 0,5-s-Sperrdurchlauf (B.PPos, ohne Figur = weg)
function OW.StationHeldLua(Nm, G)
    if not (Nm and On("build_stationlock")) then return false end
    local R0 = B.StationOpen[Nm]
    if not R0 or R0.Key == G.Key then return false end
    if not Net.Guests[R0.Key] or os.clock() - R0.At >= 120 then
        B.StationOpen[Nm] = nil
        return false
    end
    local P2, E = B.PPos and B.PPos[R0.Key], B.H.ByName[Nm]
    return P2 ~= nil and E ~= nil and E.X ~= nil and Dist(P2.X, P2.Y, P2.Z, E.X, E.Y, E.Z) <= 400
end

-- ---- B11 build_stationclose (Gast): wie OnInteractActorOverDistance (CheckDistanceFromActor > 300) eigenes
-- Inventar schliessen, wenn das Fenster einer Station offen ist und die Figur weggegangen ist
function OW.StationClose()
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    if not A.IsAlive(Pawn) then return end
    local PX, PY, PZ = Loc(Pawn)
    if not PX then return end
    local Seen = {}
    for Cls in pairs(OW.STATIONS) do
        for _, E in ipairs(B.H.ByCls[Cls] or {}) do
            local D = Dist(E.X, E.Y, E.Z, PX, PY, PZ)
            local Obj = D <= 1000 and Fresh(E)
            local CJ = Obj and A.Safe(function() return Obj.BP_JigMultiplayer end)
            if A.IsAlive(CJ) and OW.InvVisible(CJ) then
                Seen[E.Key] = true
                local S0 = B.StOpen[E.Key]
                if not S0 then
                    S0 = { D0 = D }   -- aus mehr als 300 uu geoeffnet: Grenze = Startabstand + 100
                    B.StOpen[E.Key] = S0
                end
                if D > math.max(300, S0.D0 + 100) then
                    local Jig = JigOf(Pawn)
                    if Jig and pcall(function() Jig:ToggleInventory() end) then
                        LogOnce("stclose" .. Cls, "Stationsfenster %s geschlossen (Figur zu weit weg)", Cls)
                    end
                    B.StOpen[E.Key], Seen[E.Key] = nil, nil
                end
            end
        end
    end
    for K in pairs(B.StOpen) do
        if not Seen[K] then B.StOpen[K] = nil end
    end
end

-- ---- B6 build_disasm: Gast-Hook (Widget-Pfad), Ausgang beim Gast per ret_early-Patch aus, Host zerlegt
function OW.DisHook(Ctx)
    if Net.Side ~= "client" or #B.DisQ >= 8 then return end
    pcall(function() B.DisQ[#B.DisQ + 1] = PathOf(Ctx:get():GetFullName()) end)
end

function OW.DisReply(Data, _, Err)
    if not Data then return Log("Zerlegen: keine Antwort vom Host (%s)", tostring(Err)) end
    local Why = Data:match("^no|(.*)$")
    if Why then
        Log("Zerlegen abgelehnt: %s", Why)
        if A.ShowNote then pcall(A.ShowNote, OW.DIS_WHY[Why] or OW.DIS_WHY.err) end
    end
end

-- Port von ExecuteUbergraph_W_DisassemblyWorkbenchUI (UE 5.6 L_000f-@098d; SP-Schleife ueber GetContainerItems(true)).
-- 5.6: nur mit DisassemblyItems[0] (@0203, sonst nur Verbrauch); je Stueck (1..Count @0395) und Teil eigener Wurf
-- RandomFloat(0,100) <= SpawnChance (@0414), Menge RandomInt(Min,Max) (@04e0) - 5.3 war ein Wurf * Count
-- Mengen je Teil summiert -> ein AddNewItemSomewhere je Teil (gleiche Verteilung, weniger UFunction-Aufrufe)
function OW.DisItem(G, C, Mine, It)
    local IF = OW.IF
    local Info = A.Safe(function() return It[IF.INFO] end)
    if Info == nil then
        -- Element als Wrapper (RemoteUnrealParam) statt Struktur: einmal auspacken
        It = A.Safe(function() return It:get() end) or It
        Info = It[IF.INFO]
    end
    local DA = Info[IF.ID]
    local Cnt = math.floor(tonumber(Info[IF.COUNT]) or 0)
    if not A.IsAlive(DA) or Cnt <= 0 then return 0 end
    if DA["CanBeDisassembled?"] ~= true then
        -- L_0512: Hinweis, Item bleibt liegen
        local Nm = A.Safe(function() return DA.Name:ToString() end) or "?"
        OW.Note(G, 'Item "' .. Nm .. '" cannot be disassembled')
        return 0
    end
    local Parts = 0
    local Rolls = math.min(Cnt, 1000)
    for _, E in ipairs(OW.ArrList(DA.DisassemblyItems)) do
        local Ch = tonumber(E[IF.CHANCE]) or 0
        local Lo, Hi = math.floor(tonumber(E[IF.MIN]) or 0), math.floor(tonumber(E[IF.MAX]) or 0)
        if Hi < Lo then Lo, Hi = Hi, Lo end
        local Num = 0
        for _ = 1, Rolls do
            if math.random() * 100 <= Ch then Num = Num + math.random(Lo, Hi) end
        end
        local ODA = E[IF.OUT]
        if Num > 0 and A.IsAlive(ODA) then
            -- @0598 JigTryAddItemSomewhere(Werkbank) -> beim Host AddNewItemSomewhere ohne Abwurf; voll -> Gast
            local AddT = {}
            local ok = pcall(OW.AddItem, C, ODA, Num, false, AddT)
            if not ok or OW.Out(AddT, "Added") == false then
                local ok2 = Mine and pcall(OW.AddItem, Mine, ODA, Num, true)
                if not ok2 then Log("Zerlegen: %d Teile nicht abgelegt (%s)", Num, tostring(G.PawnName)) end
            end
            Parts = Parts + Num
        end
    end
    -- 5.6 @091d (5.3 @0765) SERVER_RequestConsumeItem(Werkbank, UID, Anzahl, "") - beim Host lokal ausgefuehrt
    local U = It[IF.UID]
    local Gd = { A = U.A, B = U.B, C = U.C, D = U.D }
    if On("build_dislocal") then
        -- build_dislocal: RPC-Rumpf beim Host (BP_JigComponent_C @4ea6: TargetComp->HandleLocalRequestConsumeItem(UID,
        -- Anzahl, self, "", true)) direkt aufrufen - kein Lua-Struct an ein RPC (Regel 4, wie ls_inv I.HostUse).
        -- Fehler -> pcall in OW.DisHost -> Core.Fail("build_disasm") (Zerlegen aus, Gast nimmt den SP-Weg), nie RPC-Rueckfall
        C:HandleLocalRequestConsumeItem(Gd, Cnt, C, "", true)
    else
        C:SERVER_RequestConsumeItem(C, Gd, Cnt, "")
    end
    return Parts
end

function OW.DisHost(G, Key, Msg, CompName)
    local Pawn, Why = OW.Pre(G, "b_dis", Key)
    if not Pawn then return Net.Reply(Msg, "no|" .. (Why or "rate")) end
    local Obj = NearObj(G, Key, "b_dis", true)
    if not Obj then return Net.Reply(Msg, "no|dist") end
    if not IsA(Obj, P.DISBENCH) then
        Net.SecWarn(G, G.Key, "b_dis_bad")
        return Net.Reply(Msg, "no|bad")
    end
    if A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) == false then return Net.Reply(Msg, "no|access") end
    if not Throttle("dis" .. G.Key, 1.0) then
        Net.SecWarn(G, G.Key, "b_dis_rate")
        return Net.Reply(Msg, "no|rate")
    end
    -- build_stationlock: Werkbank mit offenem Fenster eines anderen Gasts - kein Umhaengen, kein Zerlegen seiner Items
    if A.Safe(function() return OW.StationHeld(Obj, G) end, false) == true then return Net.Reply(Msg, "no|held") end
    local C = A.Safe(function() return Obj.BP_JigMultiplayer end)
    -- 28.10. (Host fand die Werkbank leer, Gast-UI an die echte Werkbank gebunden): die Komponente nehmen, an die die
    -- Gast-UI gebunden ist (JSIContainer_1.JigMultiplayerComp), gleicher Vorlagen-Name auf Host und Gast
    if CompName and CompName ~= A.Safe(function() return C:GetFName():ToString() end) then
        local Alt = A.Safe(function() return Obj[CompName] end)
        if not A.IsAlive(Alt) then
            local Full = A.Safe(function() return Obj:GetFullName() end)
            Alt = Full and A.Safe(function() return StaticFindObject(PathOf(Full) .. "." .. CompName) end) or nil
        end
        if A.IsAlive(Alt) then C = Alt end
        LogOnce("dis_comp_" .. CompName, "Zerlegen: Gast-UI nutzt Komponente %s (%s)", CompName, A.IsAlive(Alt) and "gefunden" or "nicht gefunden")
    end
    if not A.IsAlive(C) then return Net.Reply(Msg, "no|bad") end
    pcall(function() Obj:SetOwner(Pawn) end)
    if On("build_stationlock") then
        local Nm = A.Safe(function() return Obj:GetFullName() end)
        if Nm then B.StationOpen[Nm] = { Key = G.Key, At = os.clock() } end
    end
    local function ItemsOf(Comp)
        local Out = {}
        pcall(function() Comp:GetContainerItems(true, Out) end)
        local L = OW.ArrList(OW.Out(Out, "AllItems") or {})
        if #L > 0 or not On("build_dis_raw") then return L end
        -- build_dis_raw (Live 28.10.): GetContainerItems ist eine BP-Funktion, ihre Ausgabe kommt in Lua nicht an -> die
        -- Werkbank galt immer als leer (Server-Werkbank hatte DA_9mmAmmo x381). Container direkt lesen (MainJigContainers
        -- -> ContainerItems) und nur Werte kopieren: DisItem legt Teile in denselben Container (Array kann umziehen) und
        -- liest die UID danach - ein Verweis ins Array waere dann ungueltig
        local IF = OW.IF
        pcall(function() Comp.MainJigContainers:ForEach(function(_, CE)
            CE:get()[IF.ITEMS]:ForEach(function(_, IE)
                pcall(function()
                    local E = IE:get()
                    local Info, U = E[IF.INFO], E[IF.UID]
                    local DA, Cnt = Info[IF.ID], Info[IF.COUNT]
                    if A.IsAlive(DA) and #L < 64 then
                        L[#L + 1] = { [IF.INFO] = { [IF.ID] = DA, [IF.COUNT] = Cnt }, [IF.UID] = { A = U.A, B = U.B, C = U.C, D = U.D } }
                    end
                end)
            end)
        end) end)
        return L
    end
    local Items = ItemsOf(C)
    if #Items == 0 then
        -- Live 28.10.: Host fand nichts ("empty", Zerlegen ging nie). Alle Jig-Komponenten der Werkbank pruefen (die UI
        -- liest JSIContainer_1, legt ueber JSIContainer ab) und den Befund loggen; ist alles leer, kam die Ablage des
        -- Gasts nie beim Server an
        local Info = {}
        local Cls = A.Safe(function() return C:GetClass() end)
        local List = Cls and OW.ArrList(A.Safe(function() return Obj:K2_GetComponentsByClass(Cls) end) or {}) or {}
        for _, Cp in ipairs(List) do
            if A.IsAlive(Cp) then
                local It = ItemsOf(Cp)
                Info[#Info + 1] = (A.Safe(function() return Cp:GetFName():ToString() end) or "?") .. "=" .. #It
                if #Items == 0 and #It > 0 then Items, C = It, Cp end
            end
        end
        Log("Zerlegen bei %s: Haupt-Container leer; Jig-Komponenten %s; MainJigContainers %s", Key,
            #Info > 0 and table.concat(Info, ",") or "-", tostring(A.Safe(function() return Obj.MainJigContainers:GetArrayNum() end)))
        if #Items == 0 then return Net.Reply(Msg, "no|empty") end
    end
    local Mine, Parts = JigOf(Pawn), 0
    for _, It in ipairs(Items) do
        local ok, N = pcall(OW.DisItem, G, C, Mine, It)
        if ok then Parts = Parts + (N or 0) else Core.Fail("build_disasm", N) end
    end
    Log("Zerlegen bei %s: %d Teile fuer %s", Key, Parts, tostring(G.PawnName))
    Net.Reply(Msg, "ok|" .. Parts)
end

-- ---- B7 build_bench: Tabelle (5/8) der Bau-Werkbank; SetItemsToCraft @026c nutzt CurrentCraftingTable je Maschine
function OW.TabHost(G, Key, N)
    if not OW.Pre(G, "b_tab", Key) then return end
    local Obj = NearObj(G, Key, "b_tab", true)
    if not Obj or not IsA(Obj, P.CONBENCH) then return end
    if N ~= 5 and N ~= 8 then return Net.SecWarn(G, G.Key, "b_tab") end
    if A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) == false then return end
    local Last = B.Bench[Key]
    local Cur = tonumber(A.Safe(function() return Obj.CurrentCraftingTable end))
    -- Tabelle ist nicht repliziert: ein anderer Gast mit offenem Fenster (BenchWatch meldet alle 5 s, <= 12 s, <= 400 uu)
    -- behaelt sie, sonst loest HandleServerFuncRequestCraft seinen CraftIndex in der falschen Tabelle auf
    local G2 = Last and Last.G ~= G.Key and os.clock() - Last.At < 12 and Net.Guests[Last.G]
    local P2 = G2 and GuestPawn(G2)
    if P2 then
        local X, Y, Z = Loc(Obj)
        local PX, PY, PZ = Loc(P2)
        if X and PX and Dist(PX, PY, PZ, X, Y, Z) <= 400 then
            if Cur ~= N and Throttle("btabheld" .. G.Key, 5) then
                OW.Note(G, "Station belegt - " .. tostring(G2.PawnName) .. " nutzt die Werkbank", true)
                Log("Bau-Werkbank %s: Tabelle %d fuer %s abgelehnt (belegt von %s)", Key, N, tostring(G.PawnName),
                    tostring(G2.PawnName))
            end
            return
        end
    end
    B.Bench[Key] = { G = G.Key, N = N, At = os.clock() }
    if Cur == N then return end
    local Lib = StaticFindObject(P.GFL)
    local C = A.Safe(function() return Obj.BP_JigMultiplayer end)
    if not (A.IsAlive(Lib) and A.IsAlive(C)) then return end
    local ok, err = pcall(function()
        Obj.CurrentCraftingTable = N
        Lib:SetItemsToCraft(N, C, Obj)
    end)
    if not ok then return Core.Fail("build_bench", err) end
    if Last and Last.G ~= G.Key and Last.N ~= N and os.clock() - Last.At < 600 then
        Log("Bau-Werkbank %s: Tabelle %d fuer %s (ueberschreibt Tabelle %d eines anderen Gasts)", Key, N,
            tostring(G.PawnName), Last.N)
    else
        Log("Bau-Werkbank %s: Tabelle %d fuer %s", Key, N, tostring(G.PawnName))
    end
end

-- Gast: offenes W_ConstructionWorkbenchUI -> Tabelle der Station melden (bei Wechsel/Oeffnen, sonst alle 5 s)
function OW.BenchWatch(Now)
    local W = B.BenchPath and StaticFindObject(B.BenchPath)
    if not (A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) == true) then
        W = nil
        -- FindAllOf nur, wenn das Fenster gerade zu war, der Gast eine Bau-Werkbank anschaut, sonst hoechstens alle 3 s
        local Scan = B.BenchPath ~= nil or Now - (B.BenchScan or -99) >= 3
        if not Scan then
            local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
            local Act = A.IsAlive(Pawn) and A.Safe(function()
                local Helper = Pawn.BP_JigHelperComp
                return A.IsAlive(Helper) and Helper.CurrentTracActor or nil
            end)
            Scan = A.IsAlive(Act) and IsA(Act, P.CONBENCH)
        end
        if Scan then
            B.BenchScan = Now
            for _, X in ipairs(A.Safe(function() return FindAllOf("W_ConstructionWorkbenchUI_C") end) or {}) do
                if A.IsAlive(X) and A.Safe(function() return X:IsInViewport() end, false) == true then W = X break end
            end
        end
        B.BenchPath = W and PathOf(A.Safe(function() return W:GetFullName() end)) or nil
    end
    if not W then
        B.BenchSent = nil
        return
    end
    local S = A.Safe(function() return W.StationOwner end)
    if not A.IsAlive(S) then return end
    local N = tonumber(A.Safe(function() return S.CurrentCraftingTable end))
    local K = N and KeyOf(S)
    if not K then return end
    local Sig = K .. "|" .. N
    if Sig ~= B.BenchSent or Now - (B.BenchAt or 0) > 5 then
        if Net.Send("b_tab", Enc(K) .. "|" .. N, nil, 1) then B.BenchSent, B.BenchAt = Sig, Now end
    end
end

function OW.ClientWindows8(Now)
    if On("build_bench") then
        local ok, err = pcall(OW.BenchWatch, Now)
        if not ok then Core.Fail("build_bench", err) end
    end
    if On("build_stationclose") then
        local ok, err = pcall(OW.StationClose)
        if not ok then Core.Fail("build_stationclose", err) end
    end
end

-- ---- B6/B8 Gast-Patches ret_early (Zerlegen-Ausgang, Beacon-Wellen/Tod) - nur Gast mit build2-Cap des Hosts
function OW.PatchOn(Name)
    local L = B.PLine[Name]
    return L ~= nil and L:sub(-1) == "1"
end

function OW.Patches()
    if not Core.HasPatchRegistry() then return end
    local Cl = Net.Side == "client" and Net.Has(CAP) and On()
    for _, Pt in ipairs(OW.RET) do
        -- Zerlegen nur, wenn der HOST zerlegt (bdis-Cap); sonst bleibt der lokale Spielweg
        local Want = (Cl and On(Pt.F) and (Pt.N ~= "build_disasm" or Net.Has("bdis"))) and true or false
        local Cur = B.PLine[Pt.N]
        if Want or OW.PatchOn(Pt.N) then
            local Fn, Ub = StaticFindObject(Pt.FnF and Pt.FnF() or Pt.Fn), StaticFindObject(Pt.Ub)
            if not (A.IsAlive(Fn) and A.IsAlive(Ub)) then
                if not Want then B.PLine[Pt.N] = nil end   -- Klasse entladen: die DLL hat den Patch verworfen
            else
                -- Zerlegen-Ausgang nur aus, wenn der Knopf-Hook auf genau dieser UFunction sitzt (sonst Klick ohne Wirkung)
                if Pt.N == "build_disasm" and B.Hooks.dis ~= Fn:GetAddress() then Want = false end
                local Line = string.format("%s ret_early %x 0 46%02X 040B %d", Pt.N, Fn:GetAddress(),
                    Ub:GetAddress() % 256, Want and 1 or 0)
                if Line ~= Cur and Core.SetPatch(Pt.N, Line) then
                    B.PLine[Pt.N] = Line
                    Log("Patch %s %s angefordert", Pt.N, Want and "an" or "aus")
                end
            end
        end
    end
end

-- ---- Gast-Hooks (Vertrag A9): nur Pre, Registrierung erst wenn die Klasse lebt, Wiederholung alle 10 s
-- Adresse der UFunction (nil = Klasse nicht geladen); Hooks merken sie wie ls_wobj X.Hooked
function OW.FnAddr(Path)
    local Fn = StaticFindObject(Path)
    return A.IsAlive(Fn) and A.Safe(function() return Fn:GetAddress() end) or nil
end

function OW.ClientHooks(Now)
    if Now < (B.CHookAt or 0) and Now - (B.CHookChk or -99) < 1 then return end
    B.CHookChk = Now
    -- Klasse neu geladen/entladen (Weltwechsel, Neu-Verbinden): alte UFunction ist weg -> Hook erneuern
    local DisP = OW.DisPath()
    local LdA, DisA = OW.FnAddr(P.LDOOR .. ":OnExecuteInteract"), OW.FnAddr(DisP)
    if B.Hooks.ld and B.Hooks.ld ~= LdA then
        B.Hooks.ld, B.CHookAt = nil, nil
        Log("Hook Brecheisen-Tuer: Klasse neu geladen, Hook wird erneuert")
    end
    if B.Hooks.dis and B.Hooks.dis ~= DisA then
        B.Hooks.dis, B.CHookAt = nil, nil
        Log("Hook Zerlegen-Knopf: Klasse neu geladen, Hook wird erneuert")
    end
    if Now < (B.CHookAt or 0) then return end
    B.CHookAt = Now + 10
    if On("build_ldoor") and not B.Hooks.ld and LdA then
        if A.TryHook(P.LDOOR .. ":OnExecuteInteract", OW.LdHook) then
            B.Hooks.ld = LdA
            Log("Hook Brecheisen-Tuer (OnExecuteInteract) aktiv")
        end
    end
    if On("build_disasm") and not B.Hooks.dis and DisA then
        if A.TryHook(DisP, OW.DisHook) then
            B.Hooks.dis = DisA
            Log("Hook Zerlegen-Knopf aktiv")
        end
    end
end

function OW.ClientDrain()
    if #B.LdQ > 0 then
        local Q = B.LdQ
        B.LdQ = {}
        local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
        local Me = A.IsAlive(Pawn) and A.Safe(function() return Pawn:GetFullName() end)
        for _, Ev in ipairs(On("build_ldoor") and Me and Q or {}) do
            local N = tonumber((Ev.Opt or ""):match("Option(%d)$"))
            local O = Ev.Who == Me and Ev.Path and (N == 1 or N == 2) and StaticFindObject(Ev.Path)
            local K = O and A.IsAlive(O) and KeyOf(O)
            if K then Net.Send("b_ldoor", Enc(K) .. "|" .. N, nil, 0) end
        end
    end
    if #B.DisQ > 0 then
        local Q = B.DisQ
        B.DisQ = {}
        -- nur mit aktivem Patch (sonst laeuft der lokale Spielweg: doppelt zerlegen)
        if not (On("build_disasm") and OW.PatchOn("build_disasm")) then
            return LogOnce("disnopatch", "Zerlegen: Gast-Patch nicht aktiv - lokaler Spielweg")
        end
        for _, Path in ipairs(Q) do
            local W = StaticFindObject(Path)
            local St = A.IsAlive(W) and A.Safe(function()
                -- Runde 9 (CORE-20): Unter-Widget vor dem Lesen pruefen
                local JS = W.JSIContainer_1
                local CJ = A.IsAlive(JS) and JS.JigMultiplayerComp or nil
                return A.IsAlive(CJ) and CJ:GetOwner() or nil
            end)
            local K = St and A.IsAlive(St) and KeyOf(St)
            -- Diagnose 28.10. (Host fand die Werkbank leer): gehoert der UI-Container einer lokalen Kopie (Authority beim
            -- Gast) oder der replizierten Werkbank? Wie viele Werkbaenke sieht der Gast, wie viele Items zeigt die UI?
            if (B.DisDiagN or 0) < 5 then
                B.DisDiagN = (B.DisDiagN or 0) + 1
                local NAll, NLoc = 0, 0
                for _, Wb in ipairs(FindAllOf("Buildable_DisassemblyWorkbench_C") or {}) do
                    if A.IsAlive(Wb) then
                        NAll = NAll + 1
                        if A.Safe(function() return Wb:HasAuthority() end) == true then NLoc = NLoc + 1 end
                    end
                end
                Log("Zerlegen-Diagnose: UI-Werkbank %s (lokale Kopie %s, Item-Liste %s), Werkbaenke beim Gast %d, davon lokal %d",
                    St and A.Safe(function() return St:GetFName():ToString() end) or "-",
                    tostring(St and A.Safe(function() return St:HasAuthority() end)),
                    tostring(A.Safe(function() return W.All:GetArrayNum() end)), NAll, NLoc)
            end
            local Cn = A.Safe(function() return W.JSIContainer_1.JigMultiplayerComp:GetFName():ToString() end)
            local Arg = (type(Cn) == "string" and Cn:match("^[%w_]+$")) and (Enc(K) .. "|" .. Cn) or (K and Enc(K))
            if K and Throttle("dis_req", 1.0) then Net.Request("b_dis", Arg, OW.DisReply, 8, nil, 1) end
        end
    end
end

-- ---- B2e/B9 Gast: XPGiven? und Tuerrichtung aus b_st
function OW.SetXp(Obj, V)
    if (A.Safe(function() return Obj["XPGiven?"] end) == true) ~= V then
        pcall(function() Obj["XPGiven?"] = V end)
    end
end

function OW.DotApply(Key, Obj, Spec, WantOpen, Pawn, S)
    local Old = tonumber(A.Safe(function() return Obj.DotProduct end))
    pcall(function() Obj.DotProduct = S end)
    local N0 = B.Next[Key]
    Toggle(Key, Obj, Spec, WantOpen, Pawn)
    pcall(function() Obj.DotProduct = S end)
    -- umgeschaltet oder Richtung war falsch: 3 s lang gegen das Multicast eines Zuschauers halten (@034f)
    if B.Next[Key] ~= N0 or (Old ~= nil and (Old >= 0) ~= (S >= 0)) then
        B.DotFix[Key] = { S = S, Until = os.clock() + 3 }
    end
end

function OW.DotTick(Now)
    for Key, D in pairs(B.DotFix) do
        if Now > D.Until then
            B.DotFix[Key] = nil
        else
            local Obj = Resolve(Key)
            if Obj and tonumber(A.Safe(function() return Obj.DotProduct end)) ~= D.S then
                pcall(function() Obj.DotProduct = D.S end)
            end
        end
    end
end

-- ---- build_idxfull (Host, BUILD-4): nach Weltstart sah der Index nur 150 Bauten je 2 s und erst mit Gast ->
-- Schloesser/Claims ohne DLL-/Lua-Sperre bis zu einer Minute. Hier: alle 5 s ein Durchlauf ohne Budget (auch ohne
-- Gaeste), fertig wenn die Zahl 3x gleich bleibt (Spielstand fertig geladen). Kosten ~4 Lesezugriffe je Bau einmal.
function OW.IdxFullPass(Now)
    local Added = ScanGroup(MASTER, true)
    local N = 0
    for _, E in pairs(B.H.ByName) do
        if E.Grp == MASTER then N = N + 1 end
    end
    B.IdxSame = (Added == 0 and N == B.IdxN) and (B.IdxSame or 0) + 1 or 0
    B.IdxN = N
    if B.IdxSame >= 3 and (N > 0 or AnyGuest()) then
        B.IdxFull, B.IdxReady = false, Now
        Log("Bau-Index nach Weltstart vollstaendig: %d Bauteile", N)
    end
end

-- ---- build_beacondeath (Host, BUILD-14 / AI-3 Beacon-Teil): der Beacon bindet beim Host PlayerDead der Spielfigur 0
-- (@0396 CastToCharacter -> Geist ohne Owner-Kette, feuert nie) -> Horde eines toten/getrennten Gasts liefe ewig.
-- SP @13f3: Event_PlayerDead -> Event_SpawnBeacon (Pickup @1434, Beacon weg). Nur gestartete Beacons ihres Starters
-- (SP setzt beim Tod auch ungestartete zurueck - im MP bleiben die stehen)
function OW.BeaconTick(Now)
    for Path, Bc in pairs(B.BeaconBy) do
        local Obj = StaticFindObject(Path)
        if not A.IsAlive(Obj) then
            B.BeaconBy[Path] = nil
        elseif A.Safe(function() return Obj["HordeStarted?"] end, false) ~= true then
            if Now - Bc.At > 15 then B.BeaconBy[Path] = nil end   -- gestoppt bzw. nie gestartet
        else
            local G = Net.Guests[Bc.Key]
            local P0 = G and (Bc.Pawn and StaticFindObject(Bc.Pawn) or GuestPawn(G))
            local Why = not G and "getrennt" or ((not A.IsAlive(P0)
                or A.Safe(function() return P0["PlayerDead?"] end, false) == true) and "tot" or nil)
            if Why then
                B.BeaconBy[Path] = nil
                local ok, err = pcall(function() Obj:Event_PlayerDead() end)
                Log("Horde-Beacon beendet (Starter %s %s): %s", tostring(G and G.PawnName or Bc.Key), Why,
                    ok and "liegt wieder als Gegenstand" or tostring(err))
                if not ok then Core.Fail("build_beacondeath", err) end
            end
        end
    end
end

-- Interaktion mit einem noch nicht indizierten Bau waehrend IdxFull (Hook hat gesperrt): sofort aufnehmen, Hinweis
function OW.IdxLate(G, Name, Path)
    local Obj = StaticFindObject(Path)
    if A.IsAlive(Obj) and not B.H.ByName[Name] and IsA(Obj, P.MASTER) then
        IndexAdd(Obj, Name, MASTER)
        RebuildByCls()
    end
    if G and Throttle("idxq" .. G.Key, 3) then OW.Note(G, "Bauteile werden noch geladen - gleich nochmal versuchen") end
end

-- ================================================================ Runde 9 (build-2): neue Wege, je eigener Schalter
-- ---- claim_ownpick (BUILD-7, Host): veraendernde Optionen je Klasse aus OnServerExecuteInteract (a56\fn\*\
-- EVT_OnServerExecuteInteract.txt). MASTER ohne eigene Funktion (Wand, Fundament, Turm, Marker, Deckenlicht, Deko):
-- Option1 = ReplacingObject, Option2 = Pickup(true); Klassen mit eigener Funktion: Option2 = Ersetzen, Option3 =
-- Aufheben; Bett/Schlafsack/Brunnen 3/4; Basisklassen mit Kindern (erben die Funktion): Kiste 3/4, Zelt 2/4,
-- Vitrine 2/3, Generator 4/5
OW.MOD_DEF = { Option1 = true, Option2 = true }
OW.MOD_OVR = { Option2 = true, Option3 = true }
OW.MOD_OWN = { Buildable_Radio_C = true, Buildable_Jukebox_C = true, Buildable_DecontaminationShower_C = true,
    Buildable_Lamp_C = true, Buildable_ConstructionLight_C = true, Buildable_CampingLamp_C = true,
    Buildable_TrashBin_C = true, Buildable_HordeBeacon_C = true, Buildable_BatteryCharger_C = true,
    Buildable_Campfire_C = true, Buildable_ConstructionBench_C = true, Buildable_CraftingWorkbench_C = true,
    Buildable_DisassemblyWorkbench_C = true, Buildable_WeaponsEquipmentWorkbench_C = true,
    Buildable_BarricadedMetalDoor_C = true, Buildable_BunkerDoor_C = true, Buildable_GarageDoor_C = true,
    Buildable_WoodenDoor_C = true, Buildable_WoodenDoor2_C = true, Buildable_WoodenGate_C = true }
OW.MOD_CLS = { Buildable_Bed_C = { Option3 = true, Option4 = true },
    Buildable_SleepingBag_C = { Option3 = true, Option4 = true },
    Buildable_WaterWell_C = { Option3 = true, Option4 = true } }
OW.MOD_ISA = { { P.CONTAINER, { Option3 = true, Option4 = true } }, { P.TENT, { Option2 = true, Option4 = true } },
    { P.DISPLAY, { Option2 = true, Option3 = true } }, { P.GEN, { Option4 = true, Option5 = true } } }

-- Klasse -> veraendernde Optionen (aus IndexAdd, nie im Hook; je Klassenname gemerkt)
function OW.ModOpts(Obj, Cls)
    local M0 = B.ModCls[Cls]
    if M0 ~= nil then return M0 or nil end
    M0 = OW.MOD_CLS[Cls] or (OW.MOD_OWN[Cls] and OW.MOD_OVR) or nil
    if not M0 then
        for _, G0 in ipairs(OW.MOD_ISA) do
            if IsA(Obj, G0[1]) then M0 = G0[2] break end
        end
    end
    local Known = ClassObj(P.MASTER) ~= nil
    if not M0 and Known and IsA(Obj, P.MASTER) then M0 = OW.MOD_DEF end
    if M0 or Known then B.ModCls[Cls] = M0 or false end   -- MASTER-Klasse unbekannt: spaeter nochmal
    return M0
end

-- Hook-Koerper SERVER_ForwardInteract (nur Lua-Tabellen): veraendernde Option an einem Bauteil, dessen Besitzer nicht
-- verbuendet ist? Herrenlose Bauteile bleiben frei (Claims regeln OW.Access/OW.CanModify)
function OW.ModDeny(Ev)
    local E = B.H.ByName[Ev.Act]
    local Opt = (Ev.Opt or ""):match("(Option%d)$")
    if not (E and E.Mod and Opt and E.Mod[Opt]) then return false end
    local G = GuestOfComp(Ev.Comp)
    if not G then return false end   -- Host selbst (kein Gast-Komponente)
    local K = OW.EKey(E)
    local Owner = K and O.Own[K]
    return Owner ~= nil and not (G.GuestId and OW.Allied(G.GuestId, Owner))
end

-- Owner-Trick verweigern: reines Bauteil (MOD_DEF) eines nicht verbuendeten Besitzers (nur Lua-Tabellen, auch im Hook)
function OW.ModNoOwner(G, Name)
    if not (G and Name and On("claim_ownpick") and On("claim_on")) then return false end
    local E = B.H.ByName[Name]
    if not (E and E.Mod == OW.MOD_DEF) then return false end
    local K = OW.EKey(E)
    local Owner = K and O.Own[K]
    return Owner ~= nil and not OW.Allied(G.GuestId, Owner)
end

-- ---- build_replflush (BUILD-10, Host): ersetzter Bau - Bewegung replizieren, Ruhezustand aufheben, sofort senden
-- (SpawnBuild @003e K2_SetActorTransform ohne FlushNetDormancy; das Spiel flusht sonst vor jeder Aenderung @012a)
function OW.ReplFlush(Obj)
    if not B.ReplDiag then
        B.ReplDiag = true
        Log("Ersetzen: %s bReplicateMovement=%s NetDormancy=%s (vor dem Flush, einmal)", tostring(ClsName(Obj)),
            tostring(A.Safe(function() return Obj.bReplicateMovement end)),
            tostring(A.Safe(function() return Obj.NetDormancy end)))
    end
    pcall(function() Obj:SetReplicateMovement(true) end)
    pcall(function() Obj:FlushNetDormancy() end)
    pcall(function() Obj:ForceNetUpdate() end)
end

-- ---- claim_hidemarker (BUILD-12, nur pvp): BeginPlay -> AddMarker (@000a/@0027) legt auf JEDER Maschine einen
-- Karten-/Kompass-Marker an. Host: je Gast keyed b_mk = "0" fuer Marker nicht verbuendeter Besitzer (herrenlos/
-- eigen/Clan: kein Eintrag = sichtbar). Alle 2 s, nur Aenderungen gehen raus; aus/PvE: Eintraege wieder loeschen
function OW.MarkTick(Now)
    if Now - (B.MkAt or -99) < 2 then return end
    B.MkAt = Now
    local Want = On("claim_hidemarker") and On("claim_on") and Core.Flag("pvp", true) == true
    if not (Want or B.MkPub) then return end
    B.Ally = {}
    local Any = false
    local List = B.H.ByCls.Buildable_BaseMarker_C or {}
    Net.ForEachGuest(function(G)
        local Can = Want and G.Epoch and Net.Has("bmk", G)
        for _, E in ipairs(List) do
            local V = nil
            if Can then
                local K = OW.EKey(E)
                local Owner = K and O.Own[K]
                if Owner and not OW.Allied(G.GuestId, Owner) then V, Any = "0", true end
            end
            Net.State("b_mk", E.Key, V, 2, G)
        end
    end)
    B.MkPub = Any
end

-- Host (IndexDrop): Marker weg -> Sonderwerte aller Gaeste loeschen
function OW.MarkDrop(Key)
    if not B.MkPub then return end
    Net.ForEachGuest(function(G) Net.State("b_mk", Key, nil, nil, G) end)
end

-- Gast: verbergen wie ReceiveDestroyed @033d-@03ce (Karten-Eintrag weg, BP_Marker_C zerstoeren), zeigen = AddMarker
-- (Spielfunktion, lokal). Unbekannte Objekte bleiben offen (naechster Index-Durchlauf)
function OW.MkApply()
    for Key, W in pairs(B.MkWant) do
        local Obj = W.Dirty and Resolve(Key)
        if Obj then
            W.Dirty = false
            local Mk = A.Safe(function() return Obj.Marker end)
            if W.Hide then
                if A.IsAlive(Mk) then
                    local Own = A.OwnPawn and A.Safe(A.OwnPawn)
                    local Mini = A.IsAlive(Own) and A.Safe(function() return Own.MinimapSystemComponent end)
                    local Wd = A.Safe(function() return Mk.Marker end)
                    if A.IsAlive(Mini) and A.IsAlive(Wd) then
                        pcall(function() Mini["Remove World Marker"](Mini, Wd, Mk) end)
                    end
                    pcall(function() Mk:K2_DestroyActor() end)
                    LogOnce("mkhide", "Fremde Basis-Marker werden auf der Karte verborgen (claim_hidemarker)")
                end
            else
                if not A.IsAlive(Mk) then pcall(function() Obj:AddMarker() end) end
                B.MkWant[Key] = nil
            end
        end
    end
end

-- ---- claim_preview (BUILD-15): Host je Gast keyed b_clm "x;y;r;1|0" (1 = verbuendet), alle 2 s
function OW.ClaimTick(Now)
    if Now - (B.ClmAt or -99) < 2 then return end
    B.ClmAt = Now
    local Want = On("claim_preview") and On("claim_on")
    if not (Want or B.ClmPub) then return end
    if Want then OW.Index() end
    local R0 = R(OW.ClaimR())
    B.Ally = {}
    local Any = false
    Net.ForEachGuest(function(G, Key)
        local Old, New = B.ClmSent[Key] or {}, {}
        if Want and G.Epoch and Net.Has("bclm", G) then
            for _, C in ipairs(O.Claims) do
                New[C.Key] = true
                Net.State("b_clm", C.Key, string.format("%d;%d;%d;%d", R(C.X), R(C.Y), R0,
                    OW.Allied(G.GuestId, C.Gid) and 1 or 0), 2, G)
            end
        end
        for K in pairs(Old) do
            if not New[K] then Net.State("b_clm", K, nil, nil, G) end
        end
        B.ClmSent[Key] = next(New) ~= nil and New or nil
        if next(New) ~= nil then Any = true end
    end)
    B.ClmPub = Any
end

-- Gast (ClientMode, 100 ms im Baumodus): Bau-Position im fremden Claim -> Vorschau rot (CanBuild/GiveBuildColour;
-- BuildCycle setzt beides alle 10 ms neu, wirkt also nur als Anzeige) und Hinweis alle 5 s. Der Host lehnt ab
function OW.ClaimPreview(Comp)
    local L = Comp.BuildTransform.Translation
    local X, Y = tonumber(L.X), tonumber(L.Y)
    if not (X and Y) then return end
    for _, C in pairs(B.Clm) do
        if not C.Own and (C.X - X) ^ 2 + (C.Y - Y) ^ 2 <= C.R * C.R then
            B.ClmBlock = true
            pcall(function() Comp.CanBuild = false end)
            pcall(function() Comp:GiveBuildColour(false) end)
            if Throttle("clmnote", 5) and A.ShowNote then
                pcall(A.ShowNote, "Fremdes Gebiet - hier darfst du nicht bauen")
            end
            return
        end
    end
end

-- ---- raid_lootplace (BUILD-16, Host): JigMP_OnRequestDropItem (@000a/@0162) wirft den Kisteninhalt am Angreifer ab
-- (Owner-Kette) -> neue Bodenobjekte (<= 1,5 s alt, nicht aus der Karte, nicht angehaengt, <= 400 uu um den
-- Angreifer) an die Kiste legen (+/- 60 uu), hoechstens so viele wie die Kiste Eintraege hatte
function OW.BoxCount(Obj)
    local CJ = A.Safe(function() return Obj.BP_JigMultiplayer end)
    if not A.IsAlive(CJ) then return nil end
    local T = {}
    if not pcall(function() CJ:GetContainerItems(false, T) end) then return nil end
    local V = OW.Out(T, "AllItems")
    if type(V) == "table" then return #V end
    return V ~= nil and tonumber(A.Safe(function() return V:GetArrayNum() end)) or nil
end

function OW.LootQueue(E, APawn, N)
    local PP = A.IsAlive(APawn) and PathOf(A.Safe(function() return APawn:GetFullName() end))
    if not (PP and E.X) or N == 0 then return end
    B.LootQ = B.LootQ or {}
    B.LootQ[#B.LootQ + 1] = { X = E.X, Y = E.Y, Z = E.Z, N = N, Pawn = PP }
    if B.LootAt then return end
    B.LootAt = true
    Later(0.3, function()
        B.LootAt = nil
        local ok, err = pcall(OW.LootPlace)
        if not ok then Core.Fail("raid_lootplace", err) end
    end)
end

function OW.LootPlace()
    local Q = B.LootQ or {}
    B.LootQ = {}
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if #Q == 0 or not WL then return end
    local Cand = {}
    for _, Cls in ipairs(OW.PICKUPS) do
        for _, P0 in ipairs(A.Safe(function() return FindAllOf(Cls) end) or {}) do
            if A.IsAlive(P0) and A.Safe(function()
                if P0:HasAnyFlags(WL) then return false end
                local Age = tonumber(P0:GetGameTimeSinceCreation())
                return Age ~= nil and Age <= 1.5 and not A.IsAlive(P0:GetAttachParentActor())
            end, false) == true then
                local X, Y, Z = Loc(P0)
                if X then Cand[#Cand + 1] = { O = P0, X = X, Y = Y, Z = Z } end
            end
        end
    end
    local Moved = 0
    for _, L in ipairs(Q) do
        local Pw = StaticFindObject(L.Pawn)
        local PX, PY, PZ
        if A.IsAlive(Pw) then PX, PY, PZ = Loc(Pw) end
        local Left = L.N or 64
        for _, C in ipairs(PX and Cand or {}) do
            if Left <= 0 then break end
            if not C.Done and Dist(PX, PY, PZ, C.X, C.Y, C.Z) <= 400 and A.IsAlive(C.O) then
                C.Done, Left = true, Left - 1
                local An, Ra = math.random() * 2 * math.pi, math.random() * 60
                local To = { X = L.X + math.cos(An) * Ra, Y = L.Y + math.sin(An) * Ra, Z = L.Z + 25 }
                if pcall(function() C.O:K2_SetActorLocation(To, false, {}, true) end) then
                    pcall(function() C.O:ForceNetUpdate() end)
                    Moved = Moved + 1
                end
            end
        end
    end
    if Moved > 0 then Log("Raid: %d Gegenstaende an die zerstoerte Kiste gelegt (raid_lootplace)", Moved) end
end

-- ---- build_display (BUILD-19 / WORLD-15): DisplayItem (@0c71) baut das Mesh nur lokal aus dem eigenen Kisten-Abbild
-- (GetItemByUID) -> Gaeste ohne Kisten-Daten und Spaetjoiner sehen nichts. Host: b_st "v;<Enc DA-Pfad>" (leer =
-- nichts ausgestellt). Nie ein zweites Kisten-Daten-Anfordern (Regel 5): das Mesh kommt nur aus dem DataAsset
OW.SPEC_V = { T = "v" }
function OW.DisplayState(Obj)
    if Obj.Displayed ~= true then return "v;" end
    local CJ = Obj.BP_JigMultiplayer
    if not A.IsAlive(CJ) then return nil end
    local Out = {}
    CJ:GetContainerItems(true, Out)
    local It = OW.ArrList(OW.Out(Out, "AllItems"))[1]
    if It == nil then return "v;" end
    local Info = A.Safe(function() return It[OW.IF.INFO] end)
    if Info == nil then
        It = A.Safe(function() return It:get() end) or It
        Info = It[OW.IF.INFO]
    end
    local DA = Info and Info[OW.IF.ID]
    local DP = A.IsAlive(DA) and PathOf(DA:GetFullName()) or nil
    return "v;" .. (DP and Enc(DP) or "")
end

-- Gast: eigene Mesh-Komponente wie DisplayItem @0d2f-@0e2e bzw. @00e7 (AddComponent, InspectTransform, Mesh, an
-- "Attach1"), nur bei Aenderung. Hat das eigene Spiel schon ein Mesh gebaut (Gast hat die Vitrine geoeffnet), bleibt
-- es. Waffen-Anbauteile (InstallAttachments) fehlen in v1
function OW.DisplayApply(Key, Obj, Path)
    local Last = B.Disp[Key]
    if Last == Path or (Path ~= "" and not Path:match("^/Game/")) then return end
    local Has = A.Safe(function() return Obj.Displayed end) == true
        and (A.IsAlive(A.Safe(function() return Obj.SMComp end)) or A.IsAlive(A.Safe(function() return Obj.SKMComp end)))
    if Last == nil and Path ~= "" and Has then B.Disp[Key] = Path return end
    OW.DispClear(Key, Obj)
    B.Disp[Key] = Path
    local DA = Path ~= "" and FindAsset(Path) or nil
    if not DA then return end
    local SM = A.Safe(function() return DA.StaticMeshToInspect end)
    local SK = A.Safe(function() return DA.SkeletalMeshToInspect end)
    local IsSM = A.IsAlive(SM)
    if not (IsSM or A.IsAlive(SK)) then return end
    local Cls = StaticFindObject(IsSM and "/Script/Engine.StaticMeshComponent" or "/Script/Engine.SkeletalMeshComponent")
    local Root = A.Safe(function() return Obj.StaticMesh end)
    if not (A.IsAlive(Cls) and A.IsAlive(Root)) then return end
    local Tr = A.Safe(function()
        local T = DA.InspectTransform
        return { Translation = { X = T.Translation.X, Y = T.Translation.Y, Z = T.Translation.Z },
            Rotation = { X = T.Rotation.X, Y = T.Rotation.Y, Z = T.Rotation.Z, W = T.Rotation.W },
            Scale3D = { X = T.Scale3D.X, Y = T.Scale3D.Y, Z = T.Scale3D.Z } }
    end)
    local Id = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Scale3D = { X = 1, Y = 1, Z = 1 } }
    local C = A.Safe(function() return Obj:AddComponentByClass(Cls, false, Id, false) end)
    if not A.IsAlive(C) then return LogOnce("dispadd", "Vitrine: Mesh-Komponente nicht erzeugt (%s)", tostring(Key)) end
    if Tr then pcall(function() C:K2_SetRelativeTransform(Tr, false, {}, false) end) end
    if IsSM then
        pcall(function() C:SetStaticMesh(SM) end)
        pcall(function() Obj.SMComp = C end)
    else
        pcall(function() C:SetSkeletalMeshAsset(SK) end)
        pcall(function() Obj.SKMComp = C end)
    end
    pcall(function() C:K2_AttachToComponent(Root, FName("Attach1"), 0, 0, 0, true) end)
    B.DispComp[Key] = PathOf(A.Safe(function() return C:GetFullName() end))
end

-- Gast: eigenes Mesh (Pfad) und das des Spiels weg - wie SP DisplayItem(false) @0e92 (lokales Spiel-Event, kein RPC)
function OW.DispClear(Key, Obj)
    local CP = B.DispComp[Key]
    local C = CP and StaticFindObject(CP)
    if A.IsAlive(C) then pcall(function() C:K2_DestroyComponent(Obj) end) end
    B.DispComp[Key] = nil
    if A.Safe(function() return Obj.Displayed end) == true or A.IsAlive(A.Safe(function() return Obj.SMComp end))
        or A.IsAlive(A.Safe(function() return Obj.SKMComp end)) then
        pcall(function() Obj:DisplayItem(false, { A = 0, B = 0, C = 0, D = 0 }) end)
    end
end

-- ---- build_radiosync / build_radio_any (BUILD-20 / WORLD-12): RadioUI ruft StartRadio/StopRadio nur lokal (Titel
-- zufaellig aus <Spiel>\Radio\*.mp3 je Rechner) -> Musik und Jukebox-Licht nur beim Spieler, der Play drueckt
function OW.Str(V)
    if type(V) == "string" then return V end
    return V ~= nil and A.Safe(function() return V:ToString() end) or nil
end

-- Gast: eigener Zustand geaendert (nicht von uns angewandt, B.RdSeen) -> b_radio an den Host
function OW.RadioSend(Key, RC)
    local OnF = A.Safe(function() return RC["TurnedOn?"] end, false) == true
    local Song = OW.Str(A.Safe(function() return RC.CurrentSong end)) or ""
    local S = B.RdSeen[Key]
    if S and S.On == OnF and (S.Song == Song or not OnF) then return end
    B.RdSeen[Key] = { On = OnF, Song = Song }
    if (not S and not OnF) or (OnF and Song == "") then return end
    Net.Send("b_radio", Enc(Key) .. "|" .. (OnF and 1 or 0) .. "|" .. Enc(Song), nil, 0)
    Log("Radio %s: %s an den Host", Key, OnF and Song or "aus")
end

-- Host (b_radio ueber OW.Queue): Reichweite, Zugriff (Schloss/Claim), Titelname (nur Dateiname *.mp3), Jukebox mit
-- Strom -> keyed b_rd an alle (Spaetjoiner bekommen es mit der Vollauffrischung)
function OW.RadioHost(G, Key, OnF, Song)
    if not OW.Pre(G, "b_radio", Key) then return end
    local Obj = NearObj(G, Key, "b_radio", true)
    local Cls = Obj and ClsName(Obj)
    if not (Cls and RADIO[Cls]) then return end
    if A.Safe(function() return OW.ObjAccess(G.GuestId, Obj) end, true) == false then return end
    if OnF then
        if Song == "" or #Song > 120 or Song:find("[/\\:%c]") or not Song:lower():match("%.mp3$") then
            return Net.SecWarn(G, G.Key, "b_radio_song")
        end
        if Cls == "Buildable_Jukebox_C" and A.Safe(function() return Obj["PoweredOn?"] end, true) == false then return end
    end
    local E0 = B.H.ByName[A.Safe(function() return Obj:GetFullName() end) or ""]
    local K = E0 and E0.Key or KeyOf(Obj) or Key
    Net.State("b_rd", K, OnF and ("1;" .. Enc(Song)) or nil, 2)
    Log("Radio %s von %s: %s", K, tostring(G.PawnName), OnF and Song or "aus")
end

-- Gast (Slow 1 s): Sollwerte in <= 100 m anwenden, weiter entfernte bleiben offen
function OW.RadioApply()
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    local PX, PY, PZ
    if A.IsAlive(Pawn) then PX, PY, PZ = Loc(Pawn) end
    if not PX then return end
    for Key, W in pairs(B.RdWant) do
        local Obj = W.Dirty and Resolve(Key)
        local X, Y, Z
        if Obj then X, Y, Z = Loc(Obj) end
        if X and Dist(PX, PY, PZ, X, Y, Z) <= 10000 then
            W.Dirty = false
            OW.RadioSet(Key, Obj, W.V)
            if W.V == nil then B.RdWant[Key] = nil end
        end
    end
end

function OW.HasSong(RC, Song)
    if Song == "" then return false end
    for _, V in ipairs(OW.ArrList(A.Safe(function() return RC["Found Files"] end))) do
        if OW.Str(V) == Song then return true end
    end
    return false
end

-- an: genau diesen Titel (PreviousSongRadio @0692 spielt PreviousSong, danach wie SP zufaellig weiter), Titel fehlt
-- hier -> build_radio_any: eigener Zufallstitel (StartRadio), sonst still. aus: nie StopRadio (@054f ToggleRadioUI
-- oeffnet/schliesst die RadioUI) -> MediaPlayer zu, MediaSound aus, TurnedOn? false, Jukebox-Licht aus
function OW.RadioSet(Key, Obj, V)
    local RC = A.Safe(function() return Obj.RadioComponent end)
    if not A.IsAlive(RC) then return end
    local F1, S1 = (V or ""):match("^([01]);(.*)$")
    local OnF, Song = F1 == "1", Dec(S1 or "")
    local CurOn = A.Safe(function() return RC["TurnedOn?"] end, false) == true
    local Cur = OW.Str(A.Safe(function() return RC.CurrentSong end)) or ""
    local Juke = ClsName(Obj) == "Buildable_Jukebox_C"
    if OnF then
        if not (CurOn and Cur == Song) then
            if OW.HasSong(RC, Song) then
                pcall(function() RC.PreviousSong = Song end)
                pcall(function() RC.CurrentSong = Song end)
                pcall(function() RC:PreviousSongRadio() end)
                pcall(function() RC["TurnedOn?"] = true end)
            elseif Core.Flag("build_radio_any", true) then
                if not CurOn then pcall(function() RC:StartRadio() end) end
            else
                return
            end
            if Juke then pcall(function() Obj:TurnedOn() end) end
        end
    elseif CurOn then
        local MP = A.Safe(function() return RC.MediaPlayer end)
        if A.IsAlive(MP) then pcall(function() MP:Close() end) end
        local MS = A.Safe(function() return RC.MediaSound end)
        if A.IsAlive(MS) then pcall(function() MS:Deactivate() end) end
        pcall(function() RC["TurnedOn?"] = false end)
        if Juke then pcall(function() Obj:TurnedOff() end) end
    end
    B.RdSeen[Key] = { On = A.Safe(function() return RC["TurnedOn?"] end, false) == true,
        Song = OW.Str(A.Safe(function() return RC.CurrentSong end)) or "" }
end

-- ---- build_perf (BUILD-23)
OW.SPEC_POWER = { Buildable_CeilingLight_C = true, Buildable_CeilingLight2_C = true, Buildable_WallLight_C = true }
OW.SPEC_N, OW.SPEC_L = { T = "n" }, { T = "l" }

-- Gast: b_st-Schluessel eines noch nicht indizierten Baus <= 50 m aufloesen (ein Klassen-Scan je Sekunde insgesamt;
-- Welt-Klassen haben ihre eigene Scan-Gruppe)
function OW.ResolveLate(Key)
    if Net.Side ~= "client" or not On("build_perf") then return nil end
    local Now = os.clock()
    if Now - (B.RLateAt or -99) < 1 then return nil end
    local Cls, X, Y, Z = ParseKey(Key)
    if not Cls then return nil end
    for _, W0 in ipairs(WORLD) do
        if W0 == Cls then return nil end
    end
    -- eigene Position hoechstens alle 0,5 s frisch (ClientApply fragt bis zu 40 Schluessel je Durchlauf)
    local Pp = B.RLatePos
    if not Pp or Now - Pp.At > 0.5 then
        local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
        local PX, PY, PZ
        if A.IsAlive(Pawn) then PX, PY, PZ = Loc(Pawn) end
        Pp = { At = Now, X = PX, Y = PY, Z = PZ }
        B.RLatePos = Pp
    end
    if not Pp.X or Dist(Pp.X, Pp.Y, Pp.Z, X, Y, Z) > 5000 then return nil end
    B.RLateAt = Now
    return ResolveScan(Key)
end

-- ---- BUILD-26 (build_polish): Max-HP = Klassen-Standard (CDO, je Klasse gemerkt). Health ist SaveGame und aendert
-- sich nur durch Schaden (ReceiveAnyDamage @009b) -> nach einem Neustart war "hoechster gesehener Wert" schon der
-- beschaedigte. Rueckfall: hoechster gesehener Wert
function OW.MaxHp(E, Obj, Hp)
    local Max = B.MaxHp[E.Key]
    if On("build_polish") then
        local D = B.HpCls[E.Cls]
        if D == nil then
            D = tonumber(A.Safe(function()
                local Cdo = Obj:GetClass():GetCDO()
                return A.IsAlive(Cdo) and Cdo.Health or nil
            end)) or false
            B.HpCls[E.Cls] = D
        end
        if D and D > 0 then Max = math.max(Max or D, D) end
    end
    Max = math.max(Max or Hp, Hp)
    B.MaxHp[E.Key] = Max
    return Max
end

-- ---- build_polish (BUILD-28)
-- Host: Bau-Ton an den bauenden Gast (SpawnBuild @028b spielt S_Build_Cue nur beim Host)
function OW.BuildSnd(G, X, Y, Z)
    if not (G and X and Y and Z and On("build_polish")) then return end
    UiSend(G, string.format("bsnd||%.0f,%.0f,%.0f", X, Y, Z))
end

-- Gast: b_ui gsph (Generator-Reichweite umschalten wie Option3 @0e9e) / bsnd (S_Build_Cue am Bauort)
function OW.UiPolish(Kind, Key, Extra)
    if Kind == "gsph" then
        local Obj = Resolve(Key) or OW.ResolveLate(Key)
        local Sp = Obj and A.Safe(function() return Obj.Sphere end)
        if not A.IsAlive(Sp) then return end
        local Vis = A.Safe(function() return Sp:IsVisible() end, false) == true
        pcall(function() Sp:SetVisibility(not Vis, false) end)
        return
    end
    local X, Y, Z = (Extra or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn)
    local GS = A.UEHelpers and A.Safe(function() return A.UEHelpers.GetGameplayStatics() end)
    local Cue = X and FindAsset(P.BUILDCUE)
    if not (Cue and A.IsAlive(Pawn) and A.IsAlive(GS)) then return end
    pcall(function()
        GS:PlaySoundAtLocation(Pawn, Cue, { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) },
            { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil, nil)
    end)
end

-- Gast (ClientFocus 200 ms): angeschaute Kiste -> Host-Zahl ins Interaktions-Fenster (UpdateInteractStats 'Storage',
-- Text wie UpdateStorageStat @06d0 "{A} {B}"), zweimal kurz nach Event_BeginInteract (das die lokale Zahl schreibt)
function OW.BoxStat(Key, Now)
    local N = Key ~= "" and B.BoxN[Key] or nil
    if not N and Key ~= "" then
        -- Host-Schluessel kann je Achse um 1 abweichen (Rundung der replizierten Position): naechster BoxN-Eintrag
        -- derselben Klasse <= 3 uu (nicht MATCH_DIST, sonst Zahl der Nachbarkiste); B.BoxN hat nur wenige Eintraege
        local Cls, X, Y, Z = ParseKey(Key)
        local BestD
        if Cls then
            for K2, N2 in pairs(B.BoxN) do
                local C2, X2, Y2, Z2 = ParseKey(K2)
                if C2 == Cls then
                    local D = Dist(X, Y, Z, X2, Y2, Z2)
                    if D <= 3 and (not BestD or D < BestD) then N, BestD = N2, D end
                end
            end
        end
    end
    if not N then B.NFoc = nil return end
    local F = B.NFoc
    if not F or F.Key ~= Key or F.N ~= N then
        F = { Key = Key, N = N, At = Now, Done = 0 }
        B.NFoc = F
    end
    if F.Done >= 2 or (F.Done == 1 and Now - F.At < 0.6) then return end
    local Hud = OwnHud()
    if not Hud then return end
    local T = string.format("%d %s", N, N == 1 and "Item" or "Items")
    if pcall(function() Hud:UpdateInteractStats(FName("Storage"), FText(T), false) end) then F.Done = F.Done + 1 end
end

-- Gast: Hook auf den Ja-Knopf der Ja/Nein-Abfrage (seltener Klick; Rumpf schreibt nur in B.YnYes). Registrierung
-- erst, wenn die Klasse lebt (OpenYesNo), neu bei neuer Adresse (Klasse neu geladen) wie OW.ClientHooks
function OW.YnHook()
    local Addr = OW.FnAddr(P.YNYES)
    if not Addr or B.Hooks.yn == Addr then return end
    if A.TryHook(P.YNYES, function(Ctx)
        pcall(function() B.YnYes = { Path = PathOf(Ctx:get():GetFullName()), At = os.clock() } end)
    end) then
        B.Hooks.yn = Addr
        Log("Hook Ja-Knopf (Kiste mit Inhalt aufheben) aktiv")
    end
end

-- Host (nur dedizierter Server): Kiste @0d0b oeffnet YesAndNoUI ueber GetHUD -> Spieler 0 = Geist; die Abfrage blieb
-- unsichtbar im Viewport liegen -> schliessen (das Ja-Delegat PickupContainer feuert dabei nicht)
function OW.YnClean(Who)
    if not (type(A.Settings and A.Settings.server) == "table" or (A.Coop and A.Coop.Server ~= nil)) then return end
    local N = 0
    for _, W in ipairs(A.Safe(function() return FindAllOf("ModularYesNoUI_C") end) or {}) do
        if A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) == true then
            if pcall(function() W:RemoveFromParent() end) then N = N + 1 end
        end
    end
    if N > 0 then LogOnce("ynclean", "Ja/Nein-Abfrage fuer %s beim Host geschlossen (%d)", tostring(Who), N) end
end

-- ---- build_nobuild / build_block_m (BUILD-29, Host): BuildCycle prueft Bauverbotszonen (Treffer mit Tag NoBuild
-- @0b91) nur beim Gast. BP_NoBuildArea_C-Boxen je Welt (alle 60 s neu), Bauort in einer Zone (Box waagerecht um
-- 100 uu verkleinert) -> build_nobuild 0 = nur Log "wuerde abgelehnt", 1 = ablehnen (Item bleibt). Ausnahme
-- DA.BuildAllowBuildingInNoBuildZones. build_block_m > 0: Mindestabstand (m) zu Bauteilen eines nicht verbuendeten
-- Besitzers ausserhalb von Claims. Rueckgabe true bzw. false, Grund
function OW.NoBuildList(Now)
    if B.NoBuild and Now - (B.NoBuildAt or 0) < 60 then return B.NoBuild end
    B.NoBuildAt = Now
    local L = {}
    for _, A0 in ipairs(A.Safe(function() return FindAllOf("BP_NoBuildArea_C") end) or {}) do
        local Bx = A.IsAlive(A0) and A.Safe(function() return A0.Box end)
        if A.IsAlive(Bx) then
            local Zn = A.Safe(function()
                local C, Ex, Ro = Bx:K2_GetComponentLocation(), Bx:GetScaledBoxExtent(), Bx:K2_GetComponentRotation()
                return { X = C.X, Y = C.Y, Z = C.Z, EX = Ex.X, EY = Ex.Y, EZ = Ex.Z, Yaw = math.rad(tonumber(Ro.Yaw) or 0) }
            end)
            if Zn then L[#L + 1] = Zn end
        end
    end
    B.NoBuild = L
    return L
end

function OW.InNoBuild(X, Y, Z)
    for _, Zn in ipairs(OW.NoBuildList(os.clock())) do
        local DX, DY = X - Zn.X, Y - Zn.Y
        local C, S = math.cos(Zn.Yaw), math.sin(Zn.Yaw)
        local LX, LY = DX * C + DY * S, DY * C - DX * S
        if math.abs(LX) <= math.max(Zn.EX - 100, Zn.EX * 0.5) and math.abs(LY) <= math.max(Zn.EY - 100, Zn.EY * 0.5)
            and math.abs(Z - Zn.Z) <= Zn.EZ + 300 then
            return true
        end
    end
    return false
end

function OW.PlaceCheck(G, Md, X, Y, Z)
    if not (X and Y and Z) then return true end
    if not Core.Down.build_nobuild then
        local DA = FindAsset(Md.DA)
        local Free = DA and A.Safe(function() return DA.BuildAllowBuildingInNoBuildZones end) == true
        if not Free and OW.InNoBuild(X, Y, Z) then
            if Core.Flag("build_nobuild", false) == true then
                Log("Bau von %s (%s) in Bauverbotszone abgelehnt", tostring(G.PawnName), tostring(Md.Cls))
                return false, "Hier darf nicht gebaut werden (Item bleibt bei dir)"
            end
            if Throttle("nobuild" .. G.Key, 30) then
                Log("Bau von %s (%s) in Bauverbotszone - wuerde abgelehnt (build_nobuild=0)", tostring(G.PawnName),
                    tostring(Md.Cls))
            end
        end
    end
    -- Review r9/2: Mindestabstand mit eigener Rueckfallebene - ein Fehler hier schaltet build_block_m ab,
    -- nicht mehr die Bauverbotszone (build_nobuild, Core.Fail in VerifyEntry)
    local okK, K1, K2 = pcall(OW.BlockCheck, G, X, Y)
    if not okK then Core.Fail("build_block_m", K1) elseif K1 == false then return false, K2 end
    return true
end

-- build_block_m: kein Bau ausserhalb von Claims naeher als Bm Meter an Bauten fremder (nicht verbuendeter) Besitzer
function OW.BlockCheck(G, X, Y)
    local Bm = tonumber(Core.Flag("build_block_m", 0)) or 0
    if Bm > 0 and On("claim_on") then
        local HasOwn, HasForeign = OW.ClaimState(G.GuestId, X, Y)
        if not (HasOwn or HasForeign) then
            local R0 = Bm * 100
            for _, E in pairs(B.H.ByName) do
                if E.Grp == MASTER and math.abs(E.X - X) <= R0 and math.abs(E.Y - Y) <= R0
                    and (E.X - X) ^ 2 + (E.Y - Y) ^ 2 <= R0 * R0 then
                    local K = OW.EKey(E)
                    local Owner = K and O.Own[K]
                    if Owner and not OW.Allied(G.GuestId, Owner) then
                        -- %g statt %d: Kommawerte (build_block_m=2.5) werfen sonst "no integer representation"
                        return false, string.format("Zu nah an fremden Bauten (%g m) - Item bleibt bei dir", Bm)
                    end
                end
            end
        end
    end
    return true
end

-- ---- build_prune (CORE-30, Host 60 s): Tabellen je Verbindung/Objekt/Name begrenzen (24/7-Server ohne Weltwechsel)
function OW.Janitor(Now)
    local T = os.time()
    for K, V in pairs(B.Claimed) do
        if type(V) ~= "number" or Now - V > 600 then B.Claimed[K] = nil end
    end
    for K, V in pairs(B.GLast) do
        if Now - (V.T or 0) > 60 then B.GLast[K] = nil end
    end
    for K, V in pairs(B.StationOpen) do
        if Now - (V.At or 0) > 120 then B.StationOpen[K] = nil end
    end
    for K, V in pairs(B.Bench) do
        if Now - (V.At or 0) > 600 then B.Bench[K] = nil end
    end
    for Gid, L in pairs(B.Codes) do
        for K, V in pairs(L) do
            if type(V) ~= "table" or T >= (V.Until or 0) then L[K] = nil end
        end
        if next(L) == nil then B.Codes[Gid] = nil end
    end
    for K, V in pairs(B.CodeFail) do
        if T - (V.T or 0) > 600 then B.CodeFail[K] = nil end
    end
    for K, V in pairs(B.WarnAt) do
        if Now - V > 3600 then B.WarnAt[K] = nil end
    end
    for K in pairs(B.PTag or {}) do
        if not Net.GuestByPawnName(K) then B.PTag[K] = nil end
    end
    -- Einmal-Logs (Schluessel je Pfad/Klasse): ab 2000 Eintraegen von vorn
    local N = 0
    for _ in pairs(B.Logged) do N = N + 1 end
    if N > 2000 then B.Logged = {} end
end

-- Gast weg (Net-Ereignis "gone"): Eintraege mit seinem Verbindungs-Schluessel
function OW.ForgetKey(Key)
    local Sfx = tostring(Key)
    for K in pairs(B.GLast) do
        if K:sub(-#Sfx) == Sfx then B.GLast[K] = nil end
    end
    for K, V in pairs(B.StationOpen) do
        if V.Key == Key then B.StationOpen[K] = nil end
    end
    for K, V in pairs(B.OwnT) do
        if V.Key == Key then B.OwnT[K] = nil end
    end
    for K, V in pairs(B.Bench) do
        if V.G == Key then B.Bench[K] = nil end
    end
end

-- ---- CORE-20: WidgetBlueprintLibrary-CDO vor dem Aufruf pruefen
function OW.GameOnly(PC)
    local WBL = StaticFindObject(P.WBL)
    if A.IsAlive(WBL) and A.IsAlive(PC) then pcall(function() WBL:SetInputMode_GameOnly(PC, false) end) end
end

-- ---- Faehigkeiten und Takte der Runde-9-Wege
function OW.Caps9()
    Net.Cap("bmk", On("claim_hidemarker"))   -- K13 b_mk
    Net.Cap("bclm", On("claim_preview"))     -- K14 b_clm
    Net.Cap("brad", On("build_radiosync"))   -- K11 b_radio / K12 b_rd
    Net.Cap("bcnt", On("build_polish"))      -- K15 b_st n mit Gegenstands-Zahl
end

function OW.HostSlow9(Now)
    if On("claim_hidemarker") or B.MkPub then
        local ok, err = pcall(OW.MarkTick, Now)
        if not ok then Core.Fail("claim_hidemarker", err) end
    end
    if On("claim_preview") or B.ClmPub then
        local ok, err = pcall(OW.ClaimTick, Now)
        if not ok then Core.Fail("claim_preview", err) end
    end
end

function OW.ClientSlow9(Now)
    if next(B.MkWant) ~= nil and On("claim_hidemarker") then
        local ok, err = pcall(OW.MkApply)
        if not ok then Core.Fail("claim_hidemarker", err) end
    end
    if next(B.RdWant) ~= nil and On("build_radiosync") then
        local ok, err = pcall(OW.RadioApply, Now)
        if not ok then Core.Fail("build_radiosync", err) end
    end
end

-- ---------------------------------------------------------------- Tasks
local function IndexStep()
    B.Step = B.Step + 1
    local Grp = MASTER
    if Net.Side == "client" and not B.CliFill and On("build_perf") then
        -- Runde 9 (build_perf, BUILD-23): Gast scannt Bauten nur alle 6 s (b_st unbekannter Bauten loest ApplyOne
        -- ueber OW.ResolveLate auf), Welttueren weiter jede 2. Sekunde; waechst der Index noch, wie bisher
        if B.Step % 6 ~= 1 then
            if B.Step % 2 == 1 then return end
            B.Seq = B.Seq % #WORLD + 1
            Grp = WORLD[B.Seq]
        end
    elseif B.Step % 2 == 0 then
        B.Seq = B.Seq % #WORLD + 1
        Grp = WORLD[B.Seq]
    end
    local Added = ScanGroup(Grp)
    if Grp == MASTER and Net.Side == "client" then B.CliFill = (Added or 0) >= 150 end
end

local function Fast(Now)
    if not On() or not CheckWorld() then return end
    if Net.Side == "host" then
        if next(Net.Guests) == nil then return end
        B.OwnHook = On("build_owner") and On("build_ownhook")
        TryHooks()
        HostFocus()
        HostPlace(Now)
        HostInteract()
        RunLater(Now)
    elseif Net.Side == "client" and Net.Has(CAP) then
        if On("build_place") then ClientMode() end
        ClientWindows(Now)
        if On("build_doordir") and next(B.DotFix) ~= nil then
            local okD, errD = pcall(OW.DotTick, Now)
            if not okD then Core.Fail("build_doordir", errD) end
        end
    end
end

local function Slow(Now)
    -- Zerlegen-Cap beider Seiten (Core.Fail("build_disasm") beim Host nimmt sie weg -> Gast-Patch aus, SP-Weg)
    Net.Cap("bdis", On("build_disasm"))
    -- Runde 9: Nahkampf-Raid-Relay (b_rmel) beider Seiten; Review 3: Host bietet sie nur an, wenn er b_rmel auch
    -- annimmt (raid_on + pvp, wie OW.RaidMelee) - sonst schicken Gaeste bei jedem Schlag umsonst
    Net.Cap("brmel", On("raid_melee") and (Net.Side ~= "host" or (On("raid_on") and Core.Flag("pvp", true) == true)))
    OW.Caps9()                           -- Runde 9 (build-2): bmk, bclm, brad, bcnt beider Seiten
    B.HygOn = Core.Flag("world_hygiene", true)   -- CORE-19: ClassObj liest den Schalter nicht selbst (heisser Pfad)
    -- Drosseltabelle: alle Fenster <= 5 s, Eintraege aelter 60 s verwerfen (Schluessel je Verbindung/Klasse)
    local Tc = os.clock()
    for K, T in pairs(B.Rate) do
        if Tc - T > 60 then B.Rate[K] = nil end
    end
    -- Dietrich-Patch aus, sobald kein Gast-Mehrspieler mehr (Trennung, Host-Wechsel, Schalter)
    if B.LpPatchOn then
        local okP, errP = pcall(OW.LockpickPatch)
        if not okP then Core.Fail("build_lockpatch", errP) end
    end
    -- Runde 8: Gast-Patches (Zerlegen, Beacon, Kartentuer) an/aus - auch nach Trennung/Schalter aus
    local okR8, errR8 = pcall(OW.Patches)
    if not okR8 then Core.Fail("build_v2", errR8) end
    if B.Kc or next(B.KcLine) ~= nil then
        okR8, errR8 = pcall(OW.KcPatch)
        if not okR8 then Core.Fail("build_kcard_patch", errR8) end
    end
    if not On() or not CheckWorld() then return end
    if Net.Side == "host" then
        -- Runde 7: Besitz laden/speichern, Offline-Warnungen, Aufraeumen (auch ohne Gaeste: offene Aenderungen sichern)
        local okO, errO = pcall(OW.Slow, Now)
        if not okO then Core.Fail("claim_on", errO) end
        -- build_idxfull: Index nach Weltstart ohne Budget, auch ohne Gaeste (alle 5 s, bis stabil)
        if B.IdxFull and On("build_idxfull") and Now - (B.IdxTry or -99) >= 5 then
            B.IdxTry = Now
            local okI, errI = pcall(OW.IdxFullPass, Now)
            if not okI then Core.Fail("build_idxfull", errI) end
        end
        -- build_beacondeath: Horde-Beacon endet mit Tod/Trennung seines Starters (auch wenn kein Gast mehr da ist)
        if next(B.BeaconBy) ~= nil and On("build_beacondeath") then
            local okB, errB = pcall(OW.BeaconTick, Now)
            if not okB then Core.Fail("build_beacondeath", errB) end
        end
        -- Runde 9 (build_prune, CORE-30): Tabellen je Verbindung/Objekt aufraeumen (alle 60 s, auch ohne Gaeste)
        if On("build_prune") and Now - (B.PruneAt or 0) >= 60 then
            B.PruneAt = Now
            local okJ, errJ = pcall(OW.Janitor, Now)
            if not okJ then Core.Fail("build_prune", errJ) end
        end
        if not AnyGuest() then return end
        -- genau ein FindAllOf je Sekunde: erst offene Spawn-Kontrollen, sonst der Index
        if not VerifyOne(Now) then IndexStep() end
        HostStates()
        HostHp()
        HostBeds()
        OW.HostSlow9(Now)   -- Runde 9: Basis-Marker je Gast (b_mk), Claim-Kreise (b_clm)
    elseif Net.Side == "client" and Net.Has(CAP) then
        IndexStep()
        ClientApply(Now)
        ClientGhosts(Now)
        OW.ClientSlow9(Now)   -- Runde 9: Basis-Marker verbergen/zeigen, Radio/Jukebox
    end
end

local function Focus(Now)
    if not On() or Net.Side ~= "client" or not Net.Has(CAP) or not CheckWorld() then return end
    ClientFocus(Now)
    -- Runde 8: Gast-Hooks (Brecheisen-Tuer, Zerlegen-Knopf) registrieren und ihre Warteschlangen leeren
    local ok, err = pcall(OW.ClientHooks, Now)
    if not ok then Core.Fail("build_v2", err) end
    ok, err = pcall(OW.ClientDrain, Now)
    if not ok then Core.Fail("build_v2", err) end
end

-- ---------------------------------------------------------------- Handler
M.Handlers = {
    b_mode = function(Data, G) if On() then OnMode(Data or "", G) end end,
    b_click = function(Data, G) if On() then OnClick(Data or "", G) end end,
    b_foc = function(Data, G) if On() then OnFocus(Data or "", G) end end,
    b_unlock = function(Data, G) if On() then OnUnlock(Data or "", G) end end,
    b_lpq = function(Data, G) if On() then OnLpq(Data or "", G) end end,
    b_lpk = function(Data, G) if On() then OnLpk(Data or "", G) end end,
    b_code = function(Data, G) if On() then OnCode(Data or "", G) end end,
    b_name = function(Data, G) if On() then OnName(Data or "", G) end end,
    b_pick = function(Data, G) if On() then OnPick(Data or "", G) end end,
    b_ok = function(Data) if On() then OnOk(Data or "") end end,
    b_ui = function(Data) if On() then OnUi(Data or "") end end,
    b_note = function(Data)
        if On() and Net.Side == "client" and A.ShowNote then pcall(A.ShowNote, Data or "") end
    end,
    b_st = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        if Value == nil then
            B.Want[Msg.Key], B.Tries[Msg.Key], B.Next[Msg.Key], B.BoxN[Msg.Key] = nil, nil, nil, nil
            return
        end
        local W = B.Want[Msg.Key]
        if W and W.V == Value then return end
        -- Runde 9 (build_polish, K15): Gegenstands-Zahl der Kiste sofort merken (ApplyOne wartet 1,5 s)
        if Value:sub(1, 2) == "n;" then B.BoxN[Msg.Key] = tonumber(Value:match("^n;[^;]*;(%d+)$")) end
        -- neuer Wert: erst nach 1,5 s anfassen, das Multicast des Spiels (MC_OnInteractBuildable/MC_OpenDoor)
        -- schaltet repliziert selbst um; sonst wuerde doppelt umgeschaltet
        B.Tries[Msg.Key] = nil
        B.Next[Msg.Key] = os.clock() + 1.5
        B.Want[Msg.Key] = { V = Value, Dirty = true }
        -- Runde 8 (build_doordir): Richtung sofort vormerken - das Multicast des Spiels rechnet DotProduct mit der
        -- EIGENEN Figur (@027d/@0321); Fast setzt sie 3 s lang auf den Host-Wert (Timeline @036f liest das Vorzeichen)
        local Cls = ParseKey(Msg.Key)
        local S3 = Cls and SPEC[Cls] and SPEC[Cls].Dot and Value:match("^d;[01];([01])$")
        if S3 and On("build_doordir") then B.DotFix[Msg.Key] = { S = S3 == "1" and 1 or -1, Until = os.clock() + 3 } end
    end,
    -- Runde 8 (Gast -> Host): nur pruefen + einreihen (OW.Queue), Spielaufrufe im build_fast-Takt
    b_kcq = function(Data, G)
        OW.Queue("build_kcard", G, function() OW.KcQuery(G, Dec(Data)) end)
    end,
    b_ldoor = function(Data, G)
        local K, N = (Data or ""):match("^([^|]*)|([12])$")
        if not K then
            if Net.Side == "host" and G then Net.SecWarn(G, G.Key, "b_ldoor_bad") end
            return
        end
        OW.Queue("build_ldoor", G, function() OW.LdHost(G, Dec(K), tonumber(N)) end)
    end,
    b_dis = function(Data, G, Msg)
        -- 28.10.: optional "|<Komponentenname>" (Jig-Komponente, an die die Gast-UI gebunden ist); alte Gaeste ohne
        local Kd, Cn = (Data or ""):match("^([^|]*)|([%w_]+)$")
        OW.Queue("build_disasm", G, function() OW.DisHost(G, Dec(Kd or Data), Msg, Cn) end, Msg)
    end,
    b_tab = function(Data, G)
        local K, N = (Data or ""):match("^([^|]*)|(%d+)$")
        if not K then
            if Net.Side == "host" and G then Net.SecWarn(G, G.Key, "b_tab") end
            return
        end
        OW.Queue("build_bench", G, function() OW.TabHost(G, Dec(K), tonumber(N)) end)
    end,
    -- Runde 9 (raid_melee, K10 Gast -> Host): "Enc(Schluessel)|0|1" Bauteil vor dem Gast beim Nahkampfschlag
    b_rmel = function(Data, G)
        local K, Pw = (Data or ""):match("^([^|]*)|([01])$")
        if not K or #K > 300 then
            if Net.Side == "host" and G then Net.SecWarn(G, G.Key, "b_rmel_bad") end
            return
        end
        OW.Queue("raid_melee", G, function() OW.RaidMelee(G, Dec(K), Pw == "1") end)
    end,
    b_hp = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        local Hp = Value and tonumber(Value:match("^(%-?[%d%.]+)"))
        B.Hp[Msg.Key] = Hp and { Hp = Hp, Dirty = true } or nil
    end,
    -- Runde 9 (claim_hidemarker, K13 keyed H -> G): "0" = Basis-Marker verbergen, nil = zeigen (OW.MkApply)
    b_mk = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        B.MkWant[Msg.Key] = { Hide = Value == "0", Dirty = true }
    end,
    -- Runde 9 (claim_preview, K14 keyed H -> G): Claim-Kreis "x;y;r;1|0" (1 = verbuendet), nil = weg
    b_clm = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        local X, Y, R0, Own = (Value or ""):match("^(%-?%d+);(%-?%d+);(%d+);([01])$")
        B.Clm[Msg.Key] = X and { X = tonumber(X), Y = tonumber(Y), R = tonumber(R0), Own = Own == "1" } or nil
    end,
    -- Runde 9 (build_radiosync, K12 keyed H -> alle): "1;Enc(Titel)" = an, nil = aus (OW.RadioApply)
    b_rd = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        B.RdWant[Msg.Key] = { V = Value, Dirty = true }
    end,
    -- Runde 9 (build_radiosync, K11 G -> H): "Enc(Schluessel)|0|1|Enc(Titel)" eigenes Radio an/aus/Titel
    b_radio = function(Data, G)
        local K, F, S = (Data or ""):match("^([^|]*)|([01])|([^|]*)$")
        if not K or #K > 300 or #S > 400 then
            if Net.Side == "host" and G then Net.SecWarn(G, G.Key, "b_radio_bad") end
            return
        end
        OW.Queue("build_radiosync", G, function() OW.RadioHost(G, Dec(K), F == "1", Dec(S)) end)
    end,
}

function M.HostTick()
    if Net.Side == "host" and On() then Net.Cap(CAP_HOOK, B.Hooks.spawn == true and On("build_hook")) end
end

function M.ClientTick()
end

function M.Init(Api)
    A = Api
    Net.Cap(CAP, Core.Flag(FLAG, true))
    Net.Cap(CAP_HOOK, true)   -- Gast: kann; Host: HostTick setzt den echten Stand (Hook registriert)
    Net.Cap("bdis", On("build_disasm"))   -- Slow haelt sie aktuell
    -- Runde 9 (K10), Slow haelt sie aktuell; Review 3: Host nur mit raid_on + pvp (wie OW.RaidMelee)
    Net.Cap("brmel", On("raid_melee") and (Net.Side ~= "host" or (On("raid_on") and Core.Flag("pvp", true) == true)))
    OW.Caps9()                            -- Runde 9 (build-2): K11-K14 und Kisten-Zahl, Slow haelt sie aktuell
    if A.Coop then A.Coop.Build = M end
    Core.Every("build_fast", 0.1, Fast)
    Core.Every("build_slow", 1.0, Slow)
    Core.Every("build_foc", 0.2, Focus)
    Core.Every("build_deny", 0.5, OW.DenyTick)   -- Runde 7: Sperrliste (Host)
    Core.Every("build_raid", 0.2, OW.RaidTick)   -- Runde 7: Raids (Host)
    Net.OnEvent("ready", function(Peer)
        if Net.Side == "client" and Peer == Net.Host then
            B.LastMode, B.LastFoc = nil, nil
            B.GhostAt = os.clock() + 5
            B.LpN, B.Pick = nil, nil   -- Dietrich-Zahl kommt neu vom Host (b_lpq); Patch geht in Slow aus
            B.Kc, B.KcFoc, B.KcLeft, B.BenchSent = nil, nil, nil, nil   -- Runde 8: Karten/Werkbank neu erfragen
        elseif Net.Side == "host" and Peer and Peer.Key then
            B.JoinQ[Peer.Key] = os.clock() + 5   -- Offline-Raid-Warnung nach dem Beitritt (OW.Slow)
            B.BedJoin[Peer.Key] = os.clock()     -- Runde 9 (BUILD-24): kein Spawnpunkt-Hinweis direkt nach dem Beitritt
        end
    end)
    Net.OnEvent("linked", function(Peer)
        if Net.Side == "client" and Peer == Net.Host then B.LastMode, B.LastFoc = nil, nil end
    end)
    Net.OnEvent("gone", function(Peer)
        if Peer and Peer.Key then
            B.Mode[Peer.Key], B.BedSeen[Peer.Key] = nil, nil
            B.FocQ[Peer.Key], B.Snap[Peer.Key] = nil, nil
            B.Foc[Peer.Key], B.Deny[Peer.Key], B.NameDone[Peer.Key], B.NameTry[Peer.Key] = nil, nil, nil, nil
            B.JoinQ[Peer.Key], B.DenySig, B.PickStart[Peer.Key] = nil, nil, nil
            B.GRate[Peer.Key] = nil
            -- Runde 9 (CORE-30): Daten je Verbindung (Claim-Kreise, Beitrittszeit, Stationsfenster des Gasts)
            B.ClmSent[Peer.Key], B.BedJoin[Peer.Key] = nil, nil
            if B.PPos then B.PPos[Peer.Key] = nil end
            if On("build_prune") then
                local okF, errF = pcall(OW.ForgetKey, Peer.Key)
                if not okF then Core.Fail("build_prune", errF) end
            end
        end
    end)
    -- Runde 7: Besitz/Claims/Schloesser/Raids (Host)
    A.TestCommands.own_probe = function()
        local function Cnt(T) local N = 0 for _ in pairs(T) do N = N + 1 end return N end
        local Tags = A.Safe(function() return OW.DmgWatchers() end, {}) or {}
        local TagList = {}
        for T in pairs(Tags) do TagList[#TagList + 1] = T end
        A.TestLog("own: Besitzer %d, Schloesser %d, Claims %d (r=%dm), Namen %d, Warn %d, Sperr-Eintraege %d, "
            .. "SetDeny=%s, Raid-Tags=%s, Treffer %d, zerstoert %d, Zweifel %d",
            Cnt(O.Own), Cnt(O.Lock), Cnt(O.Claim), R(OW.ClaimR() / 100), Cnt(O.Names), Cnt(O.Warn), B.DenyN or 0,
            tostring(type(Native.SetDeny) == "function"), table.concat(TagList, ","), B.RaidN, B.RaidKills, Cnt(O.Doubt))
    end
    A.TestCommands.build_probe = function()
        local N, S = 0, 0
        for _, E in pairs(B.H.ByName) do
            N = N + 1
            if E.Spec then S = S + 1 end
        end
        local Modes = 0
        for _ in pairs(B.Mode) do Modes = Modes + 1 end
        A.TestLog("build: Seite %s, Index %d (Zustand %d), Modi %d, Hooks spawn=%s inter=%s, Soll %d",
            tostring(Net.Side), N, S, Modes, tostring(B.Hooks.spawn), tostring(B.Hooks.inter),
            (function() local C = 0 for _ in pairs(B.Want) do C = C + 1 end return C end)())
    end
end

return M
