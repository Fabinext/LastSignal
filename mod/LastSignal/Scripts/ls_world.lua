-- Last Signal, Runde 5: Welt + Quests (WP12a+b). Befunde: _NetTest\analysis\findings\world.md
-- Host und Gast in einem Modul (Net.Side). Jede Funktion hinter Core.Flag; Polling statt Hooks (Ausnahme: zwei seltene
-- UI-Knoepfe, nur Pre, Body schreibt nur in W). UObjects nie ueber Ticks halten: Pfade merken, frisch nachschlagen.
--   Himmel      world_sky       Host repliziert UDS/UDW, w_sky fuer nicht replizierte Werte + Rueckfall
--   Layout      world_layout    Host repliziert Laufzeit-Prefabs/Airdrops/Zufalls-Infestationen, Gast entfernt eigene
--   Ereignisse  world_events    Gast: Airdrop-/Zufallsereignis-Timer aus, Flugzeug-Trace aus
--   Blutmond    world_bmoon     Host-Zustand (Mondfarbe) -> Gast SetBloodMoon
--   Schlafen    world_sleep     Zeitsprung erst, wenn alle Gaeste schlafen
--   Brunnen     world_well      Wasserpegel vom Host
--   Ernte       world_harvest   gefaellte Foliage-Instanzen bei allen entfernen
--   Schrott     world_scrap     Schrotthaufen (Hold-E): Gast meldet w_scrap, Host gibt Schrott, w_scrapd an alle (#9)
--   Nachwachsen world_respawn_min  Minuten (Standard 60, 0 = aus): Host setzt Steine/Baeume (AddInstance) und
--                               Schrotthaufen (Salvaged? = false) zurueck und loescht w_harv/w_scrapd; Gaeste folgen
--   Owner       world_owner     Host: Schrotthaufen nahe einem Gast -> Owner = Gast-Figur (Polling 0,5 s)
--   Laptop      world_laptop    Host: Laptop-Ereignis-Manager -> Owner = Gast (#18)
--   Safe-Zone   world_safezone  InSafeZone? nur fuer die eigene Figur
--   POI         world_poi       Erkundet-Status je Gast (Host speichert)
--   Infestation world_infest    zerstoerte Nester vom Host
--   Barbier     world_barber    Aussehen nach dem Barbier neu senden
--   Tech        world_tech      Tech-Baum je Gast (Host speichert, Gast wendet an)
--   XP          world_xp        gast-lokale XP (Crafting, Buch, POI, Angeln) -> w_xp/w_poi, Host prueft und bucht
--   Kisten      world_crate     BP_GuaranteedSpawner: Gast meldet w_crate, Host spawnt die Belohnung (Cap wcrate);
--                               nur eigene/ungebundene Kopie; w_cst (Keyed-State) = offen + Deckel bei allen Gaesten
--               world_poicrate  POI-/Compound-Kisten ueber W.REP; Export Coop.World.PoiCrateLooted (ls_inv)
--   Quests      quest_v1 (+ quest_v2 = Runde 7, Cap qst2): quest_area/quest_start/quest_ui/quest_talk/quest_dialog/
--               quest_task/quest_assist/quest_gtask/quest_ghost/quest_laptop/quest_forget/quest_rewardpatch/quest_xppatch/
--               quest_refire/quest_spawnfix/quest_dedupe/quest_marker/quest_save (quest_share nur Rueckfall ohne N8)
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local Native = require("ls_native")
local A                                  -- Coop.API

-- Gesamter Zustand in einer Tabelle (Hauptchunk-Locals klein halten)
local W = {
    Gen = -1, Pending = {}, Scans = {}, Paths = {}, Hooks = {}, HookTry = 0,
    ScrapDone = {}, LapLog = {},
    -- Quests: ueber Weltwechsel bestehend (Hooks, Patches, Warteschlangen je Gast); Laufzeitstand in W.QReset
    QHooks = {}, QHookOn = {}, QHookAt = {}, QQueue = {}, ForgetQ = {}, PatchState = {}, PatchAddr = {}, QEv = {}, GEv = {},
    -- XP-Paritaet: Gast-Hooks/Aufzeichnungen (Quelle, AddXP), Host: Ratenbremse je GuestId/Quelle, Timer je Kopie
    XpHooks = {}, XpEv = {}, XpAdd = {}, XpSentAt = {}, XpRateT = {}, XpTimer = {},
    FishSvr = {}, FishAdd = {},                       -- Host (UE 5.6): Svr_CatchFish / AddXP_Fishing-Aufzeichnungen
    -- Runde 9: Laptop-Scan (Host), Fundort-Marker (Gast: Host-Stand, eigene Marker, Spawner-Orte)
    LapUsed = {}, LapBooked = {}, LapBookedC = {}, PfmWant = {}, PfmHave = {}, PfLoc = {},
    -- Himmel
    UDS = { "Cloud Coverage", "Fog", "Dust Amount" },
    UDS_REP = { "Time of Day", "Day Length", "Night Length", "Moon Phase" },
    UDS_INT = { "Year", "Month", "Day" },
    UDW = { "Cloud Coverage", "Rain", "Snow", "Thunder/Lightning", "Wind Intensity", "Fog", "Dust",
            "Material Wetness", "Material Snow Coverage", "Material Dust Coverage" },
    STATES = { gws = "Global Weather State", lws = "Local Weather State" },
    -- Layout: Laufzeit-Actors, die der Host repliziert und der Gast lokal entfernt
    -- WORLD-2: Kisten der Zufalls-Spawner (Keycard-Koffer, Verstecke, Spezialkisten; alle SUPER BP_LootContainer_C)
    REP = { "PrefabMaster_C", "Master_AirdropContainer_C", "AirdropAircraft_C", "BP_Infestation_C",
            "Container_POICrate_C", "Container_CompoundCrate_C",
            "BP_KeycardBriefcaseContainer_C", "Container_HiddenCache_C", "Container_SpecialItemSpawner_C" },
    -- Zusatzschalter je REP-Klasse; diese Kisten behalten die Standard-Frequenz (Jig-Inhalt muss zuegig nachkommen)
    REP_FLAG = { Container_POICrate_C = "world_poicrate", Container_CompoundCrate_C = "world_poicrate",
                 BP_KeycardBriefcaseContainer_C = "world_spawncrate", Container_HiddenCache_C = "world_spawncrate",
                 Container_SpecialItemSpawner_C = "world_spawncrate" },
    PURGE_MAX = 150,
    WELLS = { "BP_WaterWell_C", "Buildable_WaterWell_C" },
    NPCS = { "BP_QuestGiver_C", "BP_MasterTrader_C", "BP_TraderMaster_C" },
    SLEEP_HOOK = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:BndEvt__Button_60_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
    BARBER_HOOK = "/Game/UI/Widgets/Player/CharacterBarberMenu.CharacterBarberMenu_C:Exit",
    START_QUEST = "/Game/Quests/Quests/Random/Quest_TheSafeZone.Quest_TheSafeZone_C",   -- 5.6: unveraendert vorhanden
    -- 5.6: Event_RewardGiveItem entfernt (kein Item-Belohnungs-Event mehr) -> w_reward/w_rwload_i/rw_i entfallen
    REWARD_FN = nil,
    NARRATIVE_LIB = "/Script/Narrative.Default__NarrativeFunctionLibrary",
    -- Schrott (Fix #9) / Laptop (Fix #18)
    SCRAP = "BP_HarvestableObject_ScrapMetal_C",
    SCRAP_DA = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal",
    SCRAP_NEAR = 800,      -- Gast: Haufen in diesem Umkreis auf Salvaged? pruefen
    SCRAP_OWN = 450,       -- Host: Owner = naechster Gast in diesem Umkreis
    SCRAP_HYST = 150,      -- Host: Gast-Owner (jeder Gast, auch ohne wld2) bleibt, solange hoechstens so viel weiter weg
    SCRAP_USE = 650,       -- Host: Gast-Figur hoechstens so weit vom Haufen
    SCRAP_MATCH = 150,     -- Host: gemeldete Position -> eigener Haufen
    SCRAP_MAX = 1000,
    -- 5.6: BP_LaptopEventManager_C -> BP_BountyQuestManager_C (CallRandomEvent gleich, GetPlayerPawn(0) @0280, .Quests)
    LAPTOP = "BP_BountyQuestManager_C",
}

local function Log(Fmt, ...) A.Log("[Welt] " .. Fmt, ...) end

-- pcall mit Rueckfallwert (nil zaehlt als Fehlschlag)
local function Try(Fn, Default)
    local ok, R = pcall(Fn)
    if ok and R ~= nil then return R end
    return Default
end

local function Alive(O) return O ~= nil and A.IsAlive(O) end

-- TArray als Lua-Liste. UFunction-RUECKGABEN (z. B. GetInstancesOverlappingSphere, GetInProgressQuests) kommen in
-- UE4SS schon als Lua-Tabelle (1-basiert, ohne :ForEach/:GetArrayNum); Array-PROPERTIES sind TArray-Userdata.
local function ArrList(R)
    local L = {}
    if type(R) == "table" then
        for _, V in ipairs(R) do L[#L + 1] = V end
    elseif R ~= nil then
        pcall(function() R:ForEach(function(_, E) L[#L + 1] = E:get() end) end)
    end
    return L
end

-- Welt-Features: Hauptschalter world_v2 + Feinschalter; Quests: quest_v1 + Feinschalter
local function On(Name) return Core.Flag("world_v2", true) and Core.Flag(Name, true) end
local function QOn(Name) return Core.Flag("quest_v1", true) and Core.Flag(Name, true) end

-- ------------------------------------------------------------------------------------------- Hilfen

function W.Path(O)
    local Full = O:GetFullName()
    return Full:match("^%S+%s+(.+)$") or Full
end

function W.Obj(Path)
    if not Path then return nil end
    local O = Try(function() return StaticFindObject(Path) end)
    if O and A.IsAlive(O) then return O end
    return nil
end

-- Adresse der UFunction (nil = Klasse nicht geladen), wie ls_build OW.FnAddr / ls_wobj X.FnAddr
function W.FnAddr(Path)
    local Fn = W.Obj(Path)
    return Fn and Try(function() return Fn:GetAddress() end) or nil
end

-- Hook nur auf eine geladene UFunction setzen und ihre Adresse merken (W.HookStale)
function W.Hook(Path, Fn)
    local Addr = W.FnAddr(Path)
    if not Addr then return nil end
    local H = A.TryHook(Path, Fn)
    if type(H) == "table" then H.Addr = Addr end
    return H
end

-- Klasse neu geladen/entladen (Weltwechsel, Neu-Verbinden): alte UFunction ist weg, der Hook greift nicht mehr ->
-- Eintrag loeschen, damit der naechste Versuch neu hookt
function W.HookStale(Tab, Id, Path)
    local H = Tab[Id]
    -- ohne gemerkte Adresse (nicht ueber W.Hook gesetzt) nie neu hooken: sonst doppelter Hook
    if type(H) ~= "table" or H.Addr == nil or H.Addr == W.FnAddr(Path) then return false end
    Tab[Id] = nil
    Log("Hook %s: Klasse neu geladen/entladen, Hook wird erneuert", tostring(Id))
    return true
end

function W.Name(O) return O:GetFName():ToString() end

function W.Runtime(O)
    return W.WAS_LOADED ~= nil and not O:HasAnyFlags(W.WAS_LOADED)
end

function W.Role(O) return Try(function() return O.Role end, 0) end

function W.Dist2(X1, Y1, Z1, X2, Y2, Z2) return (X1 - X2) ^ 2 + (Y1 - Y2) ^ 2 + (Z1 - Z2) ^ 2 end

function W.LocKey(X, Y, Grid) return string.format("%d_%d", math.floor(X / Grid + 0.5), math.floor(Y / Grid + 0.5)) end

function W.KSL() return A.UEHelpers.GetKismetSystemLibrary() end

function W.Dedicated() return type(A.Settings.server) == "table" or A.Coop.Server ~= nil end

-- Gerade Karte laden: nichts tun (API.md 2.1 WorldGen)
function W.Busy()
    local WG = A.WorldGen
    return WG and WG.Loading and os.clock() - (WG.LoadingAt or 0) < 60
end

-- Weltwechsel: alle Pfad-Caches und Weltzustaende verwerfen
function W.CheckWorld()
    local N = A.WorldGen and A.WorldGen.N or 0
    if N == W.Gen then return end
    W.Gen, W.WorldAt = N, os.clock()
    W.HarvClear()
    W.ScrapClear()
    W.ScrapPos, W.ScrapWas, W.ScrapSent, W.ScrapRate, W.OwnLog = nil, {}, {}, {}, {}
    if Net.Side == "host" then W.ScrapDone = {} end    -- Gast: nur ueber den Keyed-State w_scrapd
    W.Paths, W.Sky, W.Foliage, W.FoliageAt = {}, {}, nil, 0
    W.AreaQuests, W.SkyFirst, W.OverCleared = {}, nil, false
    W.PoiEx, W.PoiN6, W.PoiObj, W.XpTimer = {}, {}, {}, {}
    W.QReset()
    W.HarvSeen, W.HarvDone, W.HarvQueue, W.HarvSentQ, W.HarvKeys = {}, {}, {}, {}, {}
    W.HarvResp, W.HarvGone, W.HarvObjSeen, W.HarvStand, W.ScrapResp, W.ScrapGot = {}, {}, {}, {}, {}, {}
    W.HarvCur, W.HarvSig = {}, {}
    W.WellKeys, W.WellSent, W.InfSent, W.PoiSent, W.PoiKnown = {}, {}, {}, {}, nil
    W.TaskBase, W.AreaAt = {}, {}
    W.CrateEv, W.CrateWin, W.CrateQ, W.CrateList, W.CrateListAt, W.PoiMgrAt = {}, {}, {}, nil, nil, nil
    if Net.Side == "host" then for K in pairs(W.CstPub or {}) do Net.State("w_cst", K, nil) end end
    W.CstPub, W.CstDone, W.CrateHolder, W.CrateDone, W.CstAt = {}, {}, {}, {}, nil
    W.CrateHold = {}
    -- Runde 9: Fundort-Marker (Actors der alten Welt) und Host-Veroeffentlichung neu
    if Net.Side == "host" then for K in pairs(W.PfmPub or {}) do Net.State("w_pfm", K, nil) end end
    W.PfmPub, W.PfList, W.PfmHave, W.PfLoc = nil, nil, {}, {}
    -- Runde 9 (world-2): Himmel-Zonen, Layout-Gedaechtnis, POI-Tooltips, Hunde-Effekte (alles Actors der alten Welt)
    if Net.Side == "host" then for K in pairs(W.PoiStPub or {}) do Net.State("w_poist", K, nil) end end
    W.PoiStPub, W.PoiStDone, W.SkyGeo, W.SkyIn, W.SkyHostIn, W.Killed = {}, {}, {}, {}, {}, {}
    W.HarvMeshSeen, W.PetEv, W.PetFx, W.PetQ, W.MarkDiag, W.OwnLogN = nil, nil, {}, {}, nil, 0
    W.TechAssets, W.TechApplied, W.TechSent = nil, false, nil
    W.BMoonAt, W.SleepOn, W.DlgAt = 0, false, 0
    for _, S in pairs(W.Scans) do S.Due = 0 end
end

-- Spielordner fuer die Gast-Dateien (wie main.lua V/G: NetTest_Guests)
function W.GuestDir() return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\" end

function W.Exists(Path)
    local F = io.open(Path, "rb")
    if F then F:close() return true end
    return false
end

-- Host: Datensatz je Gast (poi=..., tech=...), atomar geschrieben
function W.Rec(Id)
    W.Recs = W.Recs or {}
    if W.Recs[Id] then return W.Recs[Id] end
    local R = {}
    local Text = Core.ReadAll(W.GuestDir() .. Id .. ".world.txt")
    for Line in (Text or ""):gmatch("[^\r\n]+") do
        local K, V = Line:match("^([%w_]+)=(.*)$")
        if K then R[K] = V end
    end
    W.Recs[Id] = R
    return R
end

function W.SaveRec(Id)
    local R, Lines = W.Rec(Id), {}
    for K, V in pairs(R) do Lines[#Lines + 1] = K .. "=" .. V end
    table.sort(Lines)
    if not Core.WriteAtomic(W.GuestDir() .. Id .. ".world.txt", table.concat(Lines, "\n") .. "\n") and not W.RecErr then
        W.RecErr = true
        Log("Gast-Datei %s.world.txt nicht schreibbar", Id)
    end
end

-- Liste <-> Menge (Komma-getrennt, sortiert)
function W.SetOf(Text)
    local S = {}
    for Item in tostring(Text or ""):gmatch("[^,]+") do S[Item] = true end
    return S
end

function W.ListOf(Set)
    local L = {}
    for K in pairs(Set) do L[#L + 1] = K end
    table.sort(L)
    return table.concat(L, ",")
end

-- Bereite Gaeste mit Faehigkeit (Host)
function W.Guests(Cap)
    local List = {}
    Net.ForEachGuest(function(G)
        if G.Epoch and G.Ready and Net.Has(Cap, G) then List[#List + 1] = G end
    end)
    return List
end

function W.GuestPawn(G)
    local PC = Net.PC(G)
    local Pawn = PC and Try(function() return PC:K2_GetPawn() end)
    if Alive(Pawn) then return Pawn, PC end
    return nil, PC
end

function W.Loc(O)
    local P = O:K2_GetActorLocation()
    return P.X, P.Y, P.Z
end

-- Actor zu einem Objekt (Actor selbst, sonst Besitzer/Outer einer Komponente)
function W.ActorOf(O)
    if pcall(function() O:K2_GetActorLocation() end) then return O end
    local Owner = Try(function() return O:GetOwner() end)
    if Alive(Owner) then return Owner end
    local Outer = Try(function() return O:GetOuter() end)
    if Alive(Outer) and pcall(function() Outer:K2_GetActorLocation() end) then return Outer end
    return nil
end

-- Wetter-Preset als Pfad (gleich auf Host und Gast)
function W.PresetPath(Weather)
    local P = Try(function() return Weather.Weather end)
    if not Alive(P) then return nil end
    return Try(function() return P:GetPathName() end) or Try(function() return W.Path(P) end)
end

-- ------------------------------------------------------------------------------------------- Scanner
-- FindAllOf nur hier: je Klasse hoechstens alle Period s (>= 1 s), hoechstens 3 Klassen pro Sekunde. Die Funktion
-- bekommt die frischen Objekte (nur in diesem Tick gueltig); gemerkt werden nur Pfade (W.Paths[Klasse]).
function W.AddScan(Class, Period, Side, Flag, Fn, Early)
    W.Scans[Class] = { Class = Class, Period = math.max(1, Period), Early = Early, Side = Side, Flag = Flag, Fn = Fn, Due = 0 }
end

function W.ScanTick(Now)
    if W.Busy() then return end
    W.CheckWorld()
    local Side, Done = Net.Side, 0
    if not Side then return end
    local Due = {}
    for _, S in pairs(W.Scans) do
        if Now >= S.Due and (S.Side == "both" or S.Side == Side) and S.Flag() then Due[#Due + 1] = S end
    end
    table.sort(Due, function(X, Y) return X.Due < Y.Due end)
    for _, S in ipairs(Due) do
        if Done >= 3 then break end
        Done = Done + 1
        local Period = S.Period
        if S.Early and Now - (W.WorldAt or 0) < 90 then Period = S.Early end
        S.Due = Now + Period
        local Objs, Paths = {}, {}
        for _, O in ipairs(FindAllOf(S.Class) or {}) do
            if A.IsAlive(O) and not Try(function() return W.Path(O):find("/MainMenu%.") end, false) then
                Objs[#Objs + 1] = O
                Paths[#Paths + 1] = Try(function() return W.Path(O) end, nil)
            end
        end
        W.Paths[S.Class] = Paths
        if S.Fn then
            local ok, err = pcall(S.Fn, Objs, Now)
            if not ok then Core.Fail("w_scan_" .. S.Class, err) end
        end
    end
end

-- Frische Objekte einer Klasse aus den gemerkten Pfaden
function W.Each(Class, Fn)
    for _, Path in ipairs(W.Paths[Class] or {}) do
        local O = W.Obj(Path)
        if O then Fn(O, Path) end
    end
end

function W.First(Class)
    for _, Path in ipairs(W.Paths[Class] or {}) do
        local O = W.Obj(Path)
        if O then return O end
    end
    return nil
end

-- ------------------------------------------------------------------------------------------- Himmel (world_sky)

function W.SkyActors()
    return W.First("Ultra_Dynamic_Sky_C"), W.First("Ultra_Dynamic_Weather_C")
end

-- Host: Replikation von UDS/UDW sofort an (Zeit, Datum, Mond, Wetter kommen dann ueber das Spiel selbst)
function W.SkyReplicate(Objs)
    for _, O in ipairs(Objs) do
        if not O.bReplicates then
            O:SetReplicates(true)
            pcall(function() O.bAlwaysRelevant = true end)
            Log("Replikation an: %s", O:GetClass():GetFName():ToString())
        end
    end
end

function W.SkyCollect(Sky, Weather)
    local Parts = {}
    local function Add(Prefix, Owner, Field, Fmt)
        local V = Try(function() return Owner[Field] end)
        if type(V) == "number" then Parts[#Parts + 1] = string.format("%s.%s=" .. (Fmt or "%.3f"), Prefix, Field, V) end
    end
    if Sky then
        for _, F in ipairs(W.UDS) do Add("u", Sky, F) end
        Add("u", Sky, "Time of Day", "%.1f")
        for _, F in ipairs({ "Day Length", "Night Length", "Moon Phase" }) do Add("u", Sky, F) end
        for _, F in ipairs(W.UDS_INT) do Add("u", Sky, F, "%d") end
    end
    if Weather then
        for _, F in ipairs(W.UDW) do Add("w", Weather, F) end
        Add("w", Weather, "Wind Direction", "%.1f")
        for Prefix, Name in pairs(W.STATES) do
            local State = Try(function() return Weather[Name] end)
            if Alive(State) then for _, F in ipairs(W.UDW) do Add(Prefix, State, F) end end
        end
        local Preset = W.PresetPath(Weather)
        if Preset and Preset:match("^/Game/") then Parts[#Parts + 1] = "p.Path=" .. Preset end
    end
    return table.concat(Parts, ";")
end

-- Blutmond am Himmel erkennen. UE 5.6: SetBloodMoon ruft UDS "Add Modifier"(BloodMoon, 10) bzw. "Remove Modifier"
-- (BP_EventManager.SetBloodMoon @003c/@0157): an = Sky_Modifiers/BloodMoon in "Current Modifiers" mit "Modifier
-- Targets"[i] > 0,5 (Remove setzt das Ziel auf 0 und blendet aus). Kein BloodMoon-Modifier -> 5.3-Weg: SetBloodMoon
-- setzte dort Moon Light Color (1, .35, .35) bzw. (.45, .56, .86); in 5.6 bleibt die Farbe normal (B >= 0,6).
function W.BloodMoonOn(Sky)
    for I, M in ipairs(ArrList(Try(function() return Sky["Current Modifiers"] end))) do
        local P = type(M) == "userdata" and Alive(M) and Try(function() return M:GetFullName() end)
        if type(P) == "string" and P:find("BloodMoon", 1, true) then
            local T = tonumber(ArrList(Try(function() return Sky["Modifier Targets"] end))[I])
            return T == nil or T > 0.5
        end
    end
    local B = Try(function() return Sky["Moon Light Color"].B end)
    return B ~= nil and B < 0.6
end

function W.SkyHost(Now)
    if Net.Side ~= "host" or not On("world_sky") then return end
    if Now < (W.SkyAt or 0) then return end
    W.SkyAt = Now + 2
    local Sky, Weather = W.SkyActors()
    if not Sky and not Weather then return end
    Net.State("w_sky", "v", W.SkyCollect(Sky, Weather), 2)
    if Sky and On("world_bmoon") then Net.State("w_bmoon", "on", W.BloodMoonOn(Sky) and "1" or "0", 1) end
end

-- Gast: laeuft der Himmel per Replikation (Proxy-Rolle)?
function W.SkyIsReplicated(Sky, Weather)
    local function Proxy(O)
        local R = O and W.Role(O)
        return R == 1 or R == 2
    end
    return (Sky or Weather) ~= nil and (not Sky or Proxy(Sky)) and (not Weather or Proxy(Weather))
end

-- Gast-Rueckfall: Uhrzeit weich nachziehen statt springen
function W.ApplyTime(Sky, N)
    local Cur = Sky["Time of Day"]
    local D = N - Cur
    if D > 1200 then D = D - 2400 elseif D < -1200 then D = D + 2400 end
    if math.abs(D) <= 10 then return end
    if D > 0 and D <= 300 then
        local ok = pcall(function() Sky["Transition Time of Day"](Sky, N, 3.0, 0, 2.0, false) end)
        if ok then return end
    end
    Sky["Time of Day"] = N
end

function W.SkyApplyOne(Sky, Weather, Kind, Field, Value, Full)
    if Kind == "p" then
        if not Full or not Weather then return end
        if W.PresetPath(Weather) == Value then return end
        local Preset = W.Obj(Value)
        if Preset then Weather["Change Weather"](Weather, Preset, 5.0) end
        return
    end
    local N = tonumber(Value)
    if not N then return end
    if Kind == "u" and Sky then
        if Field == "Time of Day" then
            if Full then W.ApplyTime(Sky, N) end
        elseif W.SkyNonRep[Field] or Full then
            if Sky[Field] ~= N then Sky[Field] = N end
        end
    elseif Kind == "w" and Weather and Full then
        if Weather[Field] ~= N then Weather[Field] = N end
        if Field ~= "Wind Direction" and Weather[Field .. " - Manual Override"] ~= true then
            Weather[Field .. " - Manual Override"] = true
        end
    elseif W.STATES[Kind] and Weather and Full then
        local State = Weather[W.STATES[Kind]]
        if Alive(State) and State[Field] ~= N then State[Field] = N end
    end
end

function W.SkyClient(Now)
    if Net.Side ~= "client" or not On("world_sky") or not Net.Has("wld2") then return end
    local Text = Net.Get("w_sky", "v")
    if not Text or (Text == W.SkyLast and Now < (W.SkyAgain or 0)) then return end
    W.SkyLast, W.SkyAgain = Text, Now + 10
    local Sky, Weather = W.SkyActors()
    if not Sky and not Weather then return end
    local Full = false
    if W.SkyIsReplicated(Sky, Weather) then
        if Weather and not W.OverCleared then
            W.OverCleared = true
            for _, F in ipairs(W.UDW) do pcall(function() Weather[F .. " - Manual Override"] = false end) end
            Log("Himmel kommt per Replikation, nur Wolken/Nebel/Staub vom Host")
        end
    else
        W.SkyFirst = W.SkyFirst or Now
        if Now - W.SkyFirst < 15 then return end
        Full = true
        if Weather then pcall(function() if Weather["Transition Active"] then Weather["Transition Active"] = false end end) end
        if not W.SkyFallLog then W.SkyFallLog = true Log("Himmel ohne Replikation: Rueckfall auf Werte vom Host") end
    end
    for Key, Value in Text:gmatch("([^=;]+)=([^;]+)") do
        local Kind, Field = Key:match("^(%a+)%.(.+)$")
        if Kind then pcall(W.SkyApplyOne, Sky, Weather, Kind, Field, Value, Full) end
    end
end

-- ------------------------------------------------------------------- Himmel-Zonen (WORLD-10, world_skymod)
-- BP_EnterSkyModifer (5.6): Overlap mit GetPlayerCharacter(0) -> Event_Enter -> UDS "Add Modifier"(Modifier, 1)
-- (@01c5), Verlassen -> "Remove Modifier"(Modifier, 0.5) (@02d5). "Replicated Modifier State" ist repliziert (OnRep):
-- ein Gast in einer Zone verdunkelt beim Host den Himmel ALLER; der eigene lokale Modifier des Gasts faellt beim
-- naechsten OnRep weg. Dedizierter Host: Unterdrueckung (W.WatchTick) + Diagnose + Lua-Rueckfall; Gast: eigene Anwendung.

-- Zone einmal je Welt (Kartenobjekt, aendert sich nicht): Box-Mitte/-Ausdehnung/-Drehung, Modifier-Asset (Pfad +
-- Adresse nur zum Vergleich; aufgerufen wird mit frisch nachgeschlagenem Objekt). nil = (noch) nicht auffindbar
function W.SkyZone(Path)
    local G = W.SkyGeo[Path]
    if G ~= nil then return G or nil end
    local Zn = W.Obj(Path)
    if not Zn then return nil end
    local Box = Try(function() local B = Zn.Box if Alive(B) then return B end end)
    local Mod = Try(function() local M2 = Zn.Modifier if Alive(M2) then return M2 end end)
    G = Box and Mod and Try(function()
        local C, E = Box:K2_GetComponentLocation(), Box:GetScaledBoxExtent()
        local Yaw = math.rad(Box:K2_GetComponentRotation().Yaw)
        return { CX = C.X, CY = C.Y, CZ = C.Z, EX = E.X, EY = E.Y, EZ = E.Z, Cs = math.cos(-Yaw), Sn = math.sin(-Yaw),
                 ModPath = W.Path(Mod), ModAddr = Mod:GetAddress(), Name = W.Name(Zn) }
    end) or false
    W.SkyGeo[Path] = G
    return G or nil
end

function W.SkyZoneIn(G, X, Y, Z)
    local DX, DY = X - G.CX, Y - G.CY
    local LX, LY = DX * G.Cs - DY * G.Sn, DX * G.Sn + DY * G.Cs
    return math.abs(LX) <= G.EX and math.abs(LY) <= G.EY and math.abs(Z - G.CZ) <= G.EZ + 100
end

-- Aktive Modifier des Himmels als Adress-Menge ("Current Modifiers" mit Ziel > 0,5; Remove setzt das Ziel auf 0)
function W.SkyActiveSet(Sky)
    local Set, N = {}, 0
    local Targets
    for I, M2 in ipairs(ArrList(Try(function() return Sky["Current Modifiers"] end))) do
        local Ad = type(M2) == "userdata" and W.Addr(M2)
        if Ad then
            Targets = Targets or ArrList(Try(function() return Sky["Modifier Targets"] end))
            local T = tonumber(Targets[I])
            if T == nil or T > 0.5 then Set[Ad], N = true, N + 1 end
        end
    end
    return Set, N
end

-- Gast (1 s): in einer Zone und ihr Modifier nicht aktiv (z. B. nach OnRep vom Host) -> lokal hinzufuegen (je Zone
-- hoechstens alle 5 s); beim Verlassen entfernen, falls noch aktiv (das Spiel entfernt ihn normalerweise selbst)
function W.SkyModClient(Now)
    if Net.Side ~= "client" or not On("world_skymod") then return end
    local Paths = W.Paths.BP_EnterSkyModifer_C
    if not Paths or #Paths == 0 then return end
    local Pawn = A.OwnPawn()
    if not Alive(Pawn) then return end
    local X, Y, Z = W.Loc(Pawn)
    local Sky, Act
    W.SkyFix = W.SkyFix or {}
    for _, Path in ipairs(Paths) do
        local G = W.SkyZone(Path)
        if G then
            local In, Was = W.SkyZoneIn(G, X, Y, Z), W.SkyIn[Path]
            if (In and Now >= (W.SkyFix[Path] or 0)) or (not In and Was) then
                if In then W.SkyFix[Path] = Now + 5 end
                Sky = Sky or W.First("Ultra_Dynamic_Sky_C")
                if not Sky then return end
                Act = Act or W.SkyActiveSet(Sky)
                local Mod = (In ~= (Act[G.ModAddr] == true)) and W.Obj(G.ModPath)
                if Mod and In then
                    local ok, err = pcall(function() Sky["Add Modifier"](Sky, Mod, 1.0) end)
                    if not ok then Core.Fail("world_skymod", err) return end
                    Act[G.ModAddr] = true
                    W.LogOnce("skyadd", "Himmel-Zone %s: Modifier beim Gast lokal (wieder) gesetzt", tostring(G.Name))
                elseif Mod then
                    pcall(function() Sky["Remove Modifier"](Sky, Mod, 0.5) end)
                    Act[G.ModAddr] = nil
                end
            end
            W.SkyIn[Path] = In or nil
        end
    end
end

-- Dedizierter Host (1 s): Diagnose beim Betreten durch einen Gast (hat der Host-Himmel den Zonen-Modifier?) und
-- Rueckfall ohne DLL-Unterdrueckung: Zonen-Modifier vom Host-Himmel nehmen (der Geist betritt nie eine Zone)
function W.SkyModHost(Now)
    if Net.Side ~= "host" or not W.Dedicated() or not On("world_skymod") then return end
    local Paths = W.Paths.BP_EnterSkyModifer_C
    if not Paths or #Paths == 0 then return end
    local Sky = W.First("Ultra_Dynamic_Sky_C")
    if not Sky then return end
    local Pos = {}
    for _, G in ipairs(W.Guests("wld2")) do
        local P = W.GuestPawn(G)
        if P then
            local okL, X, Y, Z = pcall(W.Loc, P)
            if okL and X then Pos[#Pos + 1] = { G = G, X = X, Y = Y, Z = Z } end
        end
    end
    local Act, NAct = W.SkyActiveSet(Sky)
    for _, Path in ipairs(Paths) do
        local Z = W.SkyZone(Path)
        if Z then
            local Who
            for _, P in ipairs(Pos) do
                if W.SkyZoneIn(Z, P.X, P.Y, P.Z) then Who = P.G break end
            end
            local On2 = Act[Z.ModAddr] == true
            if Who and not W.SkyHostIn[Path] and (W.SkyDiagN or 0) < 30 then
                W.SkyDiagN = (W.SkyDiagN or 0) + 1
                Log("Himmel-Zone %s: Gast %s drin - Host-Himmel hat den Zonen-Modifier: %s (%d aktiv, DLL-Unterdrueckung %s)",
                    tostring(Z.Name), tostring(Who.GuestId or Who.Key), On2 and "JA" or "nein", NAct, W.SkySupOn and "an" or "aus")
            end
            W.SkyHostIn[Path] = Who and true or nil
            local Mod = On2 and W.Obj(Z.ModPath)
            if Mod then
                local ok, err = pcall(function() Sky["Remove Modifier"](Sky, Mod, 0.5) end)
                if not ok then Core.Fail("world_skymod", err) return end
                Act[Z.ModAddr] = nil
                W.LogOnce("skyrm", "Himmel-Zone: Zonen-Modifier vom Host-Himmel genommen (galt sonst fuer alle Spieler)")
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------- Blutmond / Ereignisse

-- Gast: eigene Ereignis-Timer des EventManagers aus (Airdrops, Zufallsereignisse); Jets/Explosionen bleiben lokal
-- (das Spiel baut sie so: Jet_Spawn ist Multicast, Spawn um den eigenen Spieler). Blutmond-Wurf aus.
function W.EventsClient(Objs)
    if not On("world_events") or not Net.Has("wld2") then return end
    local KSL = W.KSL()
    local Fns = { "SpawnAirdrop", "SpawnRandomEvent" }
    if not Core.Flag("world_localfx", true) then Fns[#Fns + 1] = "SpawnJet" Fns[#Fns + 1] = "SpawnExplosion" end
    for _, EM in ipairs(Objs) do
        for _, Fn in ipairs(Fns) do pcall(function() KSL:K2_ClearTimer(EM, Fn) end) end
        pcall(function() if EM.BloodMoonChance >= 0 then EM.BloodMoonChance = -1 end end)
    end
    if not W.EventsLog then W.EventsLog = true Log("Ereignis-Timer beim Gast aus (%d EventManager)", #Objs) end
end

-- Gast: repliziertes Airdrop-Flugzeug wirft sonst per eigenem Trace lokale Kisten ab
function W.AircraftClient(Objs)
    if not On("world_events") or not Net.Has("wld2") then return end
    local KSL = W.KSL()
    for _, AC in ipairs(Objs) do
        local R = W.Role(AC)
        if R == 1 or R == 2 then pcall(function() KSL:K2_ClearTimer(AC, "CheckForRegionCrossing") end) end
    end
end

function W.BloodMoonClient(Now)
    if Net.Side ~= "client" or not On("world_bmoon") or not Net.Has("wld2") or Now < (W.BMoonAt or 0) then return end
    local Want = Net.Get("w_bmoon", "on")
    if Want == nil then return end
    local Sky = W.First("Ultra_Dynamic_Sky_C")
    local EM = W.First("BP_EventManager_C")
    if not Sky or not EM then return end
    local Is = W.BloodMoonOn(Sky)
    if (Want == "1") == Is then return end
    W.BMoonAt = Now + 10
    local ok, err = pcall(function() EM:SetBloodMoon(Want == "1") end)
    if ok then Log("Blutmond vom Host: %s", Want == "1" and "an" or "aus") else Core.Fail("world_bmoon", err) end
end

-- ------------------------------------------------------------------------------------------- Layout (world_layout)

-- Host: Laufzeit-Actors (nicht aus der Karte, ohne Besitzer) replizieren, damit jeder Gast genau die Host-Variante sieht
function W.LayoutHost(Class)
    return function(Objs)
        if not On("world_layout") then return end
        Net.State("w_cfg", "rep_" .. Class, "1", 1)
        local N = 0
        for _, O in ipairs(Objs) do
            if W.Runtime(O) and not O.bReplicates and not Alive(Try(function() return O:GetOwner() end)) then
                local ok = pcall(function()
                    O:SetReplicates(true)
                    -- Siedlungen/Camps sind gross: ab 1 km uebertragen statt Standard 150 m (sonst Aufploppen)
                    O.NetCullDistanceSquared = 1.0e10
                    if not W.REP_FLAG[Class] then O.NetUpdateFrequency = 1 end
                    O:ForceNetUpdate()
                end)
                if ok then N = N + 1 end
            end
        end
        if N > 0 then Log("Layout: %d %s repliziert", N, Class) end
    end
end

-- Gast: eigene Laufzeit-Kopien (Rolle Authority, nicht aus der Karte) entfernen, sobald der Host die Klasse repliziert
function W.LayoutClient(Class)
    return function(Objs)
        if not On("world_layout") or not W.WAS_LOADED or not Net.Has("wld2") then return end
        if Net.Get("w_cfg", "rep_" .. Class) ~= "1" then return end
        -- WORLD-19 (world_layout_killmemo): schon zerstoerte Actors (bis zur GC noch in FindAllOf) nicht erneut
        -- zerstoeren/zaehlen; Schluessel Adresse + FName (Adresse allein kann nach der GC neu vergeben werden)
        local Memo = Core.Flag("world_layout_killmemo", true) and W.Killed or nil
        local Now, Kill, Keys = os.clock(), {}, {}
        for _, O in ipairs(Objs) do
            if W.Role(O) == 3 and W.Runtime(O) and not Alive(Try(function() return O:GetOwner() end)) then
                local K = Memo and Try(function() return string.format("%X|%s", O:GetAddress(), W.Name(O)) end)
                if not (K and Memo[K] and Now - Memo[K] < 120) then
                    local I = #Kill + 1
                    Kill[I], Keys[I] = O, K
                end
            end
        end
        if #Kill == 0 then return end
        if #Kill > W.PURGE_MAX then
            Log("Layout: %d lokale %s - zu viele, nichts entfernt (Notbremse)", #Kill, Class)
            return
        end
        local N = 0
        for I, O in ipairs(Kill) do
            if pcall(function() O:K2_DestroyActor() end) then
                N = N + 1
                if Memo and Keys[I] then Memo[Keys[I]] = Now end
            end
        end
        if Memo and Now >= (W.KilledAt or 0) then
            W.KilledAt = Now + 60
            for K, T in pairs(Memo) do if Now - T >= 120 then Memo[K] = nil end end
        end
        if N > 0 then Log("Layout: %d lokale %s entfernt (Host-Variante kommt per Replikation)", N, Class) end
    end
end

-- ------------------------------------------------------------------------------------------- Brunnen (world_well)

function W.WellHost(Objs)
    if not On("world_well") then return end
    for _, O in ipairs(Objs) do
        local X, Y = W.Loc(O)
        local V = Try(function() return O.CurrentWater end)
        if V then
            local Key = W.LocKey(X, Y, 100)
            local Val = string.format("%d", math.floor(V + 0.5))
            if W.WellSent[Key] ~= Val then W.WellSent[Key] = Val Net.State("w_well", Key, Val, 2) end
        end
    end
end

-- Gast: Ort -> Pfad (beide Brunnen-Klassen sammeln in dieselbe Tabelle; Weltwechsel leert sie)
function W.WellClient(Objs)
    for _, O in ipairs(Objs) do
        local X, Y = W.Loc(O)
        W.WellKeys[W.LocKey(X, Y, 100)] = W.Path(O)
    end
    W.WellDirty = true
end

function W.WellApply()
    if Net.Side ~= "client" or not On("world_well") or not Net.Has("wld2") or not W.WellDirty then return end
    W.WellDirty = false
    for Key, Path in pairs(W.WellKeys or {}) do
        local V = tonumber(Net.Get("w_well", Key))
        local O = V and W.Obj(Path)
        if O then pcall(function() if math.abs(O.CurrentWater - V) >= 0.5 then O.CurrentWater = V end end) end
    end
end

-- ------------------------------------------------------------------------------------------- Ernte (world_harvest)

-- Host: w_harv veroeffentlichen, hoechstens HARV_MAX Schluessel (FIFO). Faellt ein Schluessel aus der Liste, waechst
-- die Instanz beim Host sofort nach (Nachwachsen entfernt den Schluessel selbst), sonst nil -> Gaeste wie Host.
W.HARV_MAX = 2000
function W.HarvPub(Key, Val)
    local Q = W.HarvOrder
    if not Q then Q = { H = 1, T = 0 } W.HarvOrder = Q end
    W.HarvPubN = W.HarvPubN or {}
    Net.State("w_harv", Key, Val, 3)
    W.HarvPubN[Key] = (W.HarvPubN[Key] or 0) + 1
    Q.T = Q.T + 1
    Q[Q.T] = Key
    while Q.T - Q.H + 1 > W.HARV_MAX do
        local Old = Q[Q.H]
        Q[Q.H], Q.H = nil, Q.H + 1
        local N = (W.HarvPubN[Old] or 1) - 1
        W.HarvPubN[Old] = N > 0 and N or nil
        if N <= 0 then
            local R = W.HarvResp[Old]
            if R and W.RespawnMin() > 0 then R.Force = true else Net.State("w_harv", Old, nil) end
        end
    end
end

-- Weltwechsel: alle veroeffentlichten w_harv-Schluessel entfernen (Foliage ist in der neuen Welt frisch)
function W.HarvClear()
    local Q = W.HarvOrder
    W.HarvOrder, W.HarvPubN = nil, {}
    if not Q or Net.Side ~= "host" then return end
    for I = Q.H, Q.T do
        if Q[I] then pcall(Net.State, "w_harv", Q[I], nil) end
    end
end

-- w_harv-Wert "Mesh|X|Y|Z[|Pitch|Yaw|Roll|SX|SY|SZ]" (alte Werte ohne Drehung/Skalierung: 0/0/0 und 1/1/1)
function W.HarvParse(Val)
    local F = {}
    for P in (tostring(Val or "") .. "|"):gmatch("([^|]*)|") do F[#F + 1] = P end
    local X, Y, Z = tonumber(F[2]), tonumber(F[3]), tonumber(F[4])
    if not F[1] or not F[1]:match("^/Game/") or not X or not Y or not Z then return nil end
    local function Ang(V) V = tonumber(V) or 0 return (V > -720 and V < 720) and V or 0 end
    local function Sc(V) V = tonumber(V) or 1 return (V >= 0.01 and V <= 50) and V or 1 end
    return { Mesh = F[1], X = X, Y = Y, Z = Z, Pitch = Ang(F[5]), Yaw = Ang(F[6]), Roll = Ang(F[7]),
             SX = Sc(F[8]), SY = Sc(F[9]), SZ = Sc(F[10]) }
end

-- Laufzeit-Erntekoerper -> w_harv-Wert (Transform des Actors = ehemalige Instanz)
function W.HarvVal(O, Mesh, X, Y, Z)
    local P, Yw, R = 0, 0, 0
    local SX, SY, SZ = 1, 1, 1
    pcall(function() local Rot = O:K2_GetActorRotation() P, Yw, R = Rot.Pitch, Rot.Yaw, Rot.Roll end)
    pcall(function() local S = O:GetActorScale3D() SX, SY, SZ = S.X, S.Y, S.Z end)
    return string.format("%s|%.0f|%.0f|%.0f|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f", Mesh, X, Y, Z, P, Yw, R, SX, SY, SZ)
end

function W.AngDiff(A1, A2) return math.abs((A1 - A2 + 540) % 360 - 180) end

-- Steht dort noch ein (angebauter) Erntekoerper? Liegende Baeume (gekippt > 30 Grad) zaehlen nicht.
function W.HarvStanding(R)
    for _, S in ipairs(W.HarvStand or {}) do
        if W.Dist2(S.X, S.Y, 0, R.X, R.Y, 0) < 150 ^ 2 and W.AngDiff(S.Pitch, R.Pitch) < 30 and W.AngDiff(S.Roll, R.Roll) < 30 then
            return true
        end
    end
    return false
end

-- Laufzeit-Baeume/-Steine direkt je Unterklasse (Rueckfall world_harvest_sub, nur innerhalb eines Ticks gueltig)
W.HARV_SUB = { "BP_HarvestableObject_Tree_C", "BP_HarvestableObject_Rocks_C" }
function W.HarvDirect()
    local L = {}
    for _, Cls in ipairs(W.HARV_SUB) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if A.IsAlive(O) and W.Runtime(O) then L[#L + 1] = O end
        end
    end
    return L
end

-- 5.6 Gast: replizierter Erntekoerper kommt ohne Mesh an (Mesh nicht repliziert, props.tsv 0x205; UCS @000a
-- SetStaticMesh(null)) -> unsichtbar, ohne Kollision, das Nahkampf-Relay trifft ihn nie wieder (Stein weg nach 1 Treffer).
-- Mesh aus dem w_harv-Wert des Hosts (gleiche Lage) setzen. Static-Mobilitaet blockiert SetStaticMesh -> dann Movable.
-- Src (WORLD-20, nur Baeume): Pfad der Foliage-Komponente, aus der die Instanz entfernt wurde (Material)
function W.HarvMeshSet(O, MeshPath, Src)
    local SM = W.Obj(MeshPath)
    local MC = Try(function() return O.StaticMesh end)
    if not (SM and Alive(MC)) then return false end
    local function Has()
        return Try(function() local Cur = MC.StaticMesh return Alive(Cur) and Cur:GetAddress() == SM:GetAddress() end, false)
    end
    pcall(function() O.Mesh = SM end)
    pcall(function() MC:SetStaticMesh(SM) end)
    if not Has() then
        pcall(function() MC:SetMobility(2) end)      -- EComponentMobility::Movable
        pcall(function() MC:SetStaticMesh(SM) end)
    end
    local Ok = Has()
    if Ok and Src then W.HarvMatSet(O, MC, Src) end
    return Ok
end

-- WORLD-20 (world_harv_mat): Baum-Material wie HitFoliageTree (@02c7 Material = Material der Foliage-Komponente, UCS
-- @0041 SetMaterial(0, Material)); Material ist nicht repliziert (props.tsv 0x205) -> beim Gast aus der Komponente
function W.HarvMatSet(O, MC, Src)
    if Core.Down.world_harv_mat or not Core.Flag("world_harv_mat", true) then return end
    local C = W.Obj(Src)
    local Mat = C and Try(function() local Mt = C:GetMaterial(0) if Alive(Mt) then return Mt end end)
    if not Mat then return end
    local ok, err = pcall(function()
        local Cur = MC:GetMaterial(0)
        if not (Alive(Cur) and Cur:GetAddress() == Mat:GetAddress()) then MC:SetMaterial(0, Mat) end
        O.Material = Mat
    end)
    if ok then W.LogOnce("hmat", "Ernte: Baum-Material beim Gast aus der Foliage-Komponente gesetzt")
    else Core.Fail("world_harv_mat", err) end
end

-- Quelle (Foliage-Komponente) zu einem w_harv-Schluessel beim Gast (W.HarvClient merkt sie in W.HarvGone)
function W.HarvSrc(Key, Cls)
    if Cls ~= "BP_HarvestableObject_Tree_C" or not Key then return nil end
    local G = W.HarvGone and W.HarvGone[Key]
    return G and G.Path or nil
end

-- w_harv-Eintrag an X/Y (Schluessel LocKey 50 und Nachbarzellen, waagrecht <= 60 uu); zweite Rueckgabe: Schluessel
function W.HarvValAt(X, Y)
    local CX, CY = math.floor(X / 50 + 0.5), math.floor(Y / 50 + 0.5)
    for DX = -1, 1 do
        for DY = -1, 1 do
            local Key = string.format("%d_%d", CX + DX, CY + DY)
            local Val = Net.Get("w_harv", Key)
            local R = Val and W.HarvParse(Val)
            if R and W.Dist2(R.X, R.Y, 0, X, Y, 0) <= 60 ^ 2 then return R, Key end
        end
    end
    return nil
end

-- WORLD-18 (world_harv_meshbatch): meshlose Laufzeit-Erntekoerper einmal je W.HarvClient-Durchlauf (statt 2x FindAllOf
-- je Schluessel); nur Pfade/Orte, Objekte werden bei Bedarf frisch nachgeschlagen
function W.HarvMeshless()
    local L = {}
    for _, Cls in ipairs(W.HARV_SUB) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if Alive(O) and W.Runtime(O) and not Try(function() return Alive(O.Mesh) end, false) then
                local okL, X, Y = pcall(W.Loc, O)
                local P = okL and X and Try(function() return W.Path(O) end)
                if P then L[#L + 1] = { P = P, X = X, Y = Y, Cls = Cls } end
            end
        end
    end
    return L
end

-- Gast: nach dem Entfernen der Instanz sofort den meshlosen Erntekoerper an derselben Stelle reparieren.
-- List (WORLD-18): vorab gesammelte meshlose Koerper (W.HarvMeshless), Key: w_harv-Schluessel (Material-Quelle)
function W.HarvMeshNear(Val, List, Key)
    if Net.Side ~= "client" or not Core.Flag("world_harvest_mesh", true) then return end
    local R = W.HarvParse(Val)
    if not R then return end
    if List then
        for _, E in ipairs(List) do
            if not E.Done and W.Dist2(E.X, E.Y, 0, R.X, R.Y, 0) <= 60 ^ 2 then
                local O = W.Obj(E.P)
                if O and W.HarvMeshSet(O, R.Mesh, W.HarvSrc(Key, E.Cls)) then
                    E.Done = true
                    W.LogOnce("hmfix" .. E.Cls, "Ernte: %s ohne Mesh (nicht repliziert) - Mesh %s gesetzt, wieder sicht-/treffbar", E.Cls, R.Mesh)
                end
            end
        end
        return
    end
    for _, Cls in ipairs(W.HARV_SUB) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if Alive(O) and W.Runtime(O) and not Try(function() return Alive(O.Mesh) end, false) then
                local okL, X, Y = pcall(W.Loc, O)
                if okL and X and W.Dist2(X, Y, 0, R.X, R.Y, 0) <= 60 ^ 2 and W.HarvMeshSet(O, R.Mesh, W.HarvSrc(Key, Cls)) then
                    W.LogOnce("hmfix" .. Cls, "Ernte: %s ohne Mesh (nicht repliziert) - Mesh %s gesetzt, wieder sicht-/treffbar", Cls, R.Mesh)
                end
            end
        end
    end
end

-- Neue Laufzeit-Erntekoerper (BP_HarvestableObject_Tree/Rocks) = eine Foliage-Instanz wurde dort entfernt.
-- 5.6: HitFoliageTree @0229/@0355 spawnt BP_HarvestableObject_Tree_C (Mesh per SetObjectPropertyByName @0255) und
-- entfernt die Instanz. Diagnose je Welt einmal (LogOnce): Scan-Anzahl, Karten-Actor, fehlendes Mesh, Gast-Rolle.
function W.HarvScan(Objs, Now)
    if not On("world_harvest") then return end
    Now = Now or os.clock()
    local Stand, NRun, NoMesh = {}, 0, 0
    W.LogOnce("hd0", "Ernte-Diagnose (%s): Scan laeuft, %d BP_HarvestableObject_C gefunden", tostring(Net.Side), #Objs)
    local function Visit(O)
        -- Schrotthaufen sind auch BP_HarvestableObject_C, aber keine Foliage (eigener Weg: w_scrap/w_scrapd)
        local Cls = Try(function() return O:GetClass():GetFName():ToString() end, "?")
        if Cls == W.SCRAP then return end
        if not W.Runtime(O) then
            return W.LogOnce("hdl" .. Cls, "Ernte-Diagnose: %s stammt aus der Karte (kein Laufzeit-Actor), nicht gemeldet", Cls)
        end
        NRun = NRun + 1
        local Mesh = Try(function() local MC = O.Mesh if Alive(MC) then return W.Path(MC) end end)
        local X, Y, Z = W.Loc(O)
        local Key = W.LocKey(X, Y, 50)
        local Path = Try(function() return W.Path(O) end, "?" .. Key)
        local Rot = Try(function() local Rt = O:K2_GetActorRotation() return { Rt.Pitch, Rt.Roll } end, { 0, 0 })
        Stand[#Stand + 1] = { X = X, Y = Y, Pitch = Rot[1], Roll = Rot[2] }
        if not Mesh and Net.Side == "client" and Core.Flag("world_harvest_mesh", true) then
            NoMesh = NoMesh + 1                                         -- WORLD-18: W.HarvMeshSeen
            local R, RK = W.HarvValAt(X, Y)
            if R and W.HarvMeshSet(O, R.Mesh, W.HarvSrc(RK, Cls)) then
                Mesh = R.Mesh
                W.LogOnce("hmfix" .. Cls, "Ernte: %s ohne Mesh (nicht repliziert) - Mesh %s gesetzt, wieder sicht-/treffbar", Cls, R.Mesh)
            end
        end
        if not Mesh then
            return W.LogOnce("hdm" .. Cls, "Ernte-Diagnose: %s ohne lesbares Mesh (%s), nicht gemeldet", Cls,
                tostring(Try(function() return O.Mesh end)))
        end
        -- HarvObjSeen: ein schon gemeldeter Actor (z. B. liegender Baum) meldet nach dem Nachwachsen nicht erneut
        if W.HarvSeen[Key] or W.HarvObjSeen[Path] then return end
        -- Zeitstempel statt true: W.HarvObjPrune (CORE-30) raeumt Pfade verschwundener Actors nach 10 min weg
        W.HarvSeen[Key], W.HarvObjSeen[Path] = true, Now
        local Val = W.HarvVal(O, Mesh, X, Y, Z)
        if Net.Side == "host" then
            W.HarvDone[Key] = true
            W.HarvRecord(Key, Val)
            W.HarvPub(Key, Val)
            W.LogOnce("hpub", "Ernte: erster gefaellter Baum/Stein an die Gaeste gemeldet (%s)", Mesh)
        elseif W.Role(O) == 3 and Net.Has("wld2") and not W.HarvSentQ[Key] then
            W.HarvSentQ[Key] = true
            Net.Send("w_harvq", Val, nil, 2)
            W.LogOnce("hq", "Ernte: erster gefaellter Baum/Stein an den Host gemeldet (%s)", Mesh)
        else
            W.LogOnce("hdr", "Ernte-Diagnose (Gast): %s Rolle %s, wld2=%s - keine Meldung an den Host", Cls,
                tostring(W.Role(O)), tostring(Net.Has("wld2")))
        end
    end
    for _, O in ipairs(Objs) do Visit(O) end
    if W.HarvSub then
        for _, O in ipairs(W.HarvDirect()) do Visit(O) end
    elseif NRun == 0 and Core.Flag("world_harvest_sub", true) and Now >= (W.HarvSubAt or 0) then
        -- Liefert FindAllOf der Basisklasse die Unterklassen-Actors nicht, ab jetzt direkt je Unterklasse suchen
        W.HarvSubAt = Now + 30
        local D = W.HarvDirect()
        if #D > 0 then
            W.HarvSub = true
            Log("Ernte-Diagnose: Suche nach BP_HarvestableObject_C liefert %d Laufzeit-Baeume/-Steine nicht -> ab jetzt direkte Suche (world_harvest_sub)", #D)
            for _, O in ipairs(D) do Visit(O) end
        end
    end
    W.HarvStand = Stand
    if Net.Side == "client" then W.HarvMeshSeen = NoMesh end
end

-- CORE-30 (world_hygiene): HarvObjSeen waechst je gefaelltem Baum (Dauer-Server ohne Weltwechsel). Eintraege aelter
-- als 10 min, deren Actor nicht mehr existiert, entfernen (hoechstens 200 Pruefungen je Minute)
function W.HarvObjPrune(Now)
    if Now < (W.HarvPruneAt or 0) or not Core.Flag("world_hygiene", true) then return end
    W.HarvPruneAt = Now + 60
    local N, Gone = 0, 0
    for Path, At in pairs(W.HarvObjSeen or {}) do
        if N >= 200 then break end
        if type(At) ~= "number" then
            W.HarvObjSeen[Path] = Now
        elseif Now - At > 600 then
            N = N + 1
            if not W.Obj(Path) then W.HarvObjSeen[Path], Gone = nil, Gone + 1 else W.HarvObjSeen[Path] = Now end
        end
    end
    if Gone > 0 then W.LogOnce("hprune", "Ernte: %d gemerkte Erntekoerper ohne Actor entfernt (Speicher, CORE-30)", Gone) end
    -- Kisten-Belohnung je Gast+Ort zaehlt nur 30 min (W.CrateHostOne) -> aeltere Eintraege weg
    for K, E in pairs(W.CrateDone or {}) do
        if type(E) == "table" and Now - (tonumber(E.T) or 0) >= 1800 then W.CrateDone[K] = nil end
    end
end

-- Host: geerntete Instanz fuer das Nachwachsen merken
function W.HarvRecord(Key, Val)
    local R = W.HarvParse(Val)
    if R then R.At, R.Val = os.clock(), Val W.HarvResp[Key] = R end
end

-- Foliage-Komponenten je Mesh (einmal je Welt; neu nur bei unbekanntem Mesh und fruehestens nach 120 s)
function W.FoliageFor(Mesh, Now)
    if not W.Foliage or (not W.Foliage[Mesh] and Now - (W.FoliageAt or 0) > 120) then
        W.Foliage, W.FoliageAt, W.FoliageB = {}, Now, {}
        for _, C in ipairs(FindAllOf("FoliageInstancedStaticMeshComponent") or {}) do
            local MP = A.IsAlive(C) and Try(function() local SM = C.StaticMesh if Alive(SM) then return W.Path(SM) end end)
            if MP then
                W.Foliage[MP] = W.Foliage[MP] or {}
                table.insert(W.Foliage[MP], W.Path(C))
            end
        end
    end
    return W.Foliage[Mesh] or {}
end

-- Kann die Komponente Instanzen im Umkreis Radius um Center haben? Grenzen (Kugel) einmal je Komponente/Adresse
-- ueber KismetSystemLibrary.GetComponentBounds, 1000 Spielraum (Nachwachsen am Rand); unbekannt -> immer true
function W.FoliageNear(Path, C, Center, Radius)
    W.FoliageB = W.FoliageB or {}
    local Addr = W.Addr(C)
    local B = W.FoliageB[Path]
    if not B or B.Addr ~= Addr then
        local O, E = {}, {}
        local ok = pcall(function() W.KSL():GetComponentBounds(C, O, E, {}) end)
        local X, Y, Z = tonumber(O.X), tonumber(O.Y), tonumber(O.Z)
        local EX, EY, EZ = tonumber(E.X), tonumber(E.Y), tonumber(E.Z)
        B = { Addr = Addr }
        if ok and X and Y and Z and EX and EY and EZ and EX + EY + EZ > 0 then
            B.X, B.Y, B.Z, B.R = X, Y, Z, math.sqrt(EX * EX + EY * EY + EZ * EZ)
        end
        W.FoliageB[Path] = B
    end
    if not B.R then return true end
    return W.Dist2(Center.X, Center.Y, Center.Z, B.X, B.Y, B.Z) <= (B.R + Radius + 1000) ^ 2
end

-- Instanz-Indizes im Umkreis (Rueckgabe-TArray = Lua-Tabelle, siehe ArrList)
function W.Overlap(C, Center, Radius)
    return ArrList(Try(function() return C:GetInstancesOverlappingSphere(Center, Radius, true) end))
end

-- Steht Instanz I von C an R? Lage wie im Spiel lokal (HitFoliageTree @01ec GetInstanceTransform(.., false) = Spawn-Ort
-- des Erntekoerpers = w_harv X/Y/Z); waagrecht <= 30 uu, senkrecht <= 60 uu. nil = Lage nicht lesbar
function W.HarvAt(C, I, R)
    local Out = {}
    local ok, Got = pcall(function() return C:GetInstanceTransform(I, Out, false) end)
    if not ok then return nil end
    if Got == false then return false end
    local P = Out.Translation
    local X, Y, Z = P and tonumber(P.X), P and tonumber(P.Y), P and tonumber(P.Z)
    if not (X and Y and Z) then return nil end
    return (X - R.X) ^ 2 + (Y - R.Y) ^ 2 <= 30 ^ 2 and math.abs(Z - R.Z) <= 60
end

-- Kandidaten der Kugel-Abfrage auf die Instanz an R eingrenzen (HISM prueft die Bounds je Instanz: die Kugel am
-- Stammfuss trifft auch Nachbarbaeume). Keine Lage lesbar -> alle Kandidaten (alter Weg). Absteigend sortiert.
function W.HarvPick(C, Cands, R)
    local Hits, Unk, N = {}, {}, 0
    for _, I in ipairs(Cands) do
        if type(I) == "number" then
            N = N + 1
            local At = W.HarvAt(C, I, R)
            if At then Hits[#Hits + 1] = I elseif At == nil then Unk[#Unk + 1] = I end
        end
    end
    if #Hits == 0 and N > 0 and #Unk == N then Hits = Unk end
    table.sort(Hits, function(P, Q) return P > Q end)
    return Hits
end

-- Adressen der nahen Komponenten (gleiche Komponenten = gleiche Signatur, Streaming legt neue an)
function W.HarvSigOf(Near)
    local S = {}
    for _, Path in ipairs(Near) do S[#S + 1] = tostring(W.Addr(W.Obj(Path))) end
    return table.concat(S, ",")
end

-- Gast: Kugel-Abfrage ohne passende Instanz -> Instanzen der nahen Komponenten nach der Lage durchsuchen
-- (hoechstens 3 ms je Aufruf, Cursor je Schluessel). Je Schluessel dieselben Komponenten nur einmal.
-- Rueckgabe: Pfad (entfernt), "wait" (weiter im naechsten Durchlauf), nil (nicht da)
function W.HarvSeek(Key, R, Near, Sig)
    W.HarvCur, W.HarvSig = W.HarvCur or {}, W.HarvSig or {}
    if #Near == 0 or W.HarvSig[Key] == Sig then return nil end
    local Cur = W.HarvCur[Key]
    if not Cur or Cur.Sig ~= Sig then Cur = { Sig = Sig, CI = 1 } W.HarvCur[Key] = Cur end
    local T0 = os.clock()
    while Cur.CI <= #Near do
        local Path = Near[Cur.CI]
        local C = W.Obj(Path)
        if C and Cur.I == nil then Cur.I = (tonumber(Try(function() return C:GetInstanceCount() end, 0)) or 0) - 1 end
        while C and Cur.I >= 0 do
            if os.clock() - T0 > 0.003 then return "wait" end
            local I = Cur.I
            Cur.I = I - 1
            if W.HarvAt(C, I, R) and pcall(function() C:RemoveInstance(I) end) then
                W.HarvCur[Key], W.HarvSig[Key] = nil, Sig
                W.LogOnce("hseek", "Ernte: Instanz per Lage-Suche entfernt (Kugel-Abfrage ohne Treffer, %s)", R.Mesh)
                return Path
            end
        end
        Cur.CI, Cur.I = Cur.CI + 1, nil
    end
    W.HarvCur[Key], W.HarvSig[Key] = nil, Sig
    W.LogOnce("hmiss" .. R.Mesh, "Ernte: %s bei %.0f/%.0f/%.0f in %d Komponente(n) nicht gefunden", R.Mesh, R.X, R.Y, R.Z, #Near)
    return nil
end

-- Instanz an R entfernen: Kugel-Abfrage (80) + Lage-Pruefung; Gast (mit Key, Figur <= 150 m): sonst Lage-Suche.
-- Rueckgabe: entfernt, Pfad der Komponente, true = Suche laeuft weiter (Schluessel neu einreihen)
function W.HarvApply(Val, Now, Key)
    local R = W.HarvParse(Val)
    if not R then return false end
    local Center, Removed, From, Near = { X = R.X, Y = R.Y, Z = R.Z }, 0, nil, {}
    for _, Path in ipairs(W.FoliageFor(R.Mesh, Now)) do
        local C = W.Obj(Path)
        if C and W.FoliageNear(Path, C, Center, 80) then
            Near[#Near + 1] = Path
            for _, I in ipairs(W.HarvPick(C, W.Overlap(C, Center, 80), R)) do
                if pcall(function() C:RemoveInstance(I) end) then Removed, From = Removed + 1, Path end
            end
        end
    end
    if not Key or Net.Side ~= "client" then return Removed > 0, From end
    W.HarvSig = W.HarvSig or {}
    local Sig = W.HarvSigOf(Near)
    if Removed > 0 then
        W.HarvSig[Key] = Sig
        W.LogOnce("hok", "Ernte: gefaellte Instanz beim Gast entfernt (%s)", R.Mesh)
        return true, From
    end
    if #Near == 0 then
        W.LogOnce("hnone" .. R.Mesh, "Ernte: keine Foliage-Komponente fuer %s bei %.0f/%.0f", R.Mesh, R.X, R.Y)
        return false
    end
    local Pawn = A.OwnPawn()
    if not Alive(Pawn) then return false end
    local PX, PY = W.Loc(Pawn)
    if W.Dist2(R.X, R.Y, 0, PX, PY, 0) > 15000 ^ 2 then return false end   -- fern: spaeter ueber die 15-s-Runde
    local Res = W.HarvSeek(Key, R, Near, Sig)
    if Res == "wait" then return false, nil, true end
    if Res then return true, Res end
    return false
end

-- Host (Nahkampf-Relay): Instanz an X/Y/Z wie HarvApply finden (Kugel 80 + Lage), ohne zu entfernen; keine HarvSeek
function W.HarvFind(Mesh, X, Y, Z)
    if not On("world_harvest") or type(Mesh) ~= "string" or not Mesh:find("^/Game/") then return nil end
    X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
    if not (X and Y and Z) then return nil end
    local Center, R = { X = X, Y = Y, Z = Z }, { X = X, Y = Y, Z = Z }
    for _, Path in ipairs(W.FoliageFor(Mesh, os.clock())) do
        local C = W.Obj(Path)
        if C and A.IsAlive(C) and W.FoliageNear(Path, C, Center, 80) then
            local Hits = W.HarvPick(C, W.Overlap(C, Center, 80), R)
            if Hits[1] and W.HarvAt(C, Hits[1], R) then return C, Hits[1] end
        end
    end
    return nil
end

-- Host (Nahkampf-Relay): Erntekoerper sofort scannen/melden (statt naechster 2-s-Runde), hoechstens 4x je Sekunde.
-- HarvScan dedupliziert ueber HarvSeen/HarvObjSeen, der Zusatzaufruf ist also folgenlos wiederholbar.
function W.HarvNow()
    if Net.Side ~= "host" or not On("world_harvest") then return end
    local Now = os.clock()
    W.HarvNowAt = W.HarvNowAt or {}
    local Keep = {}
    for _, T in ipairs(W.HarvNowAt) do if Now - T < 1 then Keep[#Keep + 1] = T end end
    if #Keep >= 4 then W.HarvNowAt = Keep return end
    Keep[#Keep + 1] = Now
    W.HarvNowAt = Keep
    local Objs = {}
    for _, O in ipairs(FindAllOf("BP_HarvestableObject_C") or {}) do
        if A.IsAlive(O) then Objs[#Objs + 1] = O end
    end
    W.LogOnce("hnow", "Ernte: Relay-Treffer sofort gemeldet (HarvNow)")
    W.HarvScan(Objs, Now)
end

-- FRotator (Grad) -> FQuat (wie FRotator::Quaternion)
function W.Quat(P, Yw, R)
    local H = math.pi / 360
    local SP, CP = math.sin(P * H), math.cos(P * H)
    local SY, CY = math.sin(Yw * H), math.cos(Yw * H)
    local SR, CR = math.sin(R * H), math.cos(R * H)
    return { X = CR * SP * SY - SR * CP * CY, Y = -CR * SP * CY - SR * CP * SY,
             Z = CR * CP * SY - SR * SP * CY, W = CR * CP * CY + SR * SP * SY }
end

-- Instanz wieder anlegen (beide Seiten). Komponente: Prefer (Gast: aus der er entfernt hat), sonst die gleiche
-- Mesh-Komponente mit den meisten Instanzen im Umkreis 2000 (= naechste), sonst die erste. true = angelegt oder schon da.
function W.HarvAdd(R, Prefer, Now)
    local Center = { X = R.X, Y = R.Y, Z = R.Z }
    local Comps, Far = {}, {}
    for _, Path in ipairs(W.FoliageFor(R.Mesh, Now)) do
        local C = W.Obj(Path)
        if C then
            -- weit entfernte Komponenten (Grenzen) nicht abfragen; nur Rueckfall, wenn keine nahe existiert
            if W.FoliageNear(Path, C, Center, 2000) then
                if #W.HarvPick(C, W.Overlap(C, Center, 25), R) > 0 then return true end  -- schon da (nur Instanz an derselben Lage)
                Comps[#Comps + 1] = { C = C, Path = Path }
            else
                Far[#Far + 1] = { C = C, Path = Path }
            end
        end
    end
    if #Comps == 0 then Comps = Far end
    if #Comps == 0 then return false end
    local Best
    for _, E in ipairs(Comps) do if E.Path == Prefer then Best = E end end
    if not Best then
        local BestN = -1
        for _, E in ipairs(Comps) do
            local N = #W.Overlap(E.C, Center, 2000)
            if N > BestN then Best, BestN = E, N end
        end
    end
    local T = { Rotation = W.Quat(R.Pitch, R.Yaw, R.Roll), Translation = Center, Scale3D = { X = R.SX, Y = R.SY, Z = R.SZ } }
    local ok, I = pcall(function() return Best.C:AddInstance(T, true) end)
    if W.FoliageB then W.FoliageB[Best.Path] = nil end                  -- Grenzen neu (Instanz evtl. ausserhalb)
    if ok and (type(I) ~= "number" or I >= 0) then return true end
    W.LogOnce("ra" .. R.Mesh, "Nachwachsen: AddInstance fuer %s fehlgeschlagen (%s)", R.Mesh, tostring(I))
    return false
end

-- Gast: Warteschlange abarbeiten (10 je Durchlauf), alle 15 s die nahen erneut (Streaming legt Instanzen neu an);
-- Schluessel weg (Host hat nachwachsen lassen) -> eigene Instanz wieder anlegen
function W.HarvClient(Now)
    if Net.Side ~= "client" or not On("world_harvest") or not Net.Has("wld2") then return end
    local N, T0, Again = 0, os.clock(), {}
    -- WORLD-18 (world_harv_meshbatch): meshlose Koerper einmal je Durchlauf (nur bei wartenden Schluesseln und
    -- world_harvest_mesh). Kein Tor ueber
    -- W.HarvMeshSeen: ein frisch replizierter Koerper kommt oft vor dem naechsten HarvScan an und braucht sofort ein Mesh
    local Batch, Meshless = Core.Flag("world_harv_meshbatch", true), nil
    for Key in pairs(W.HarvQueue) do
        if N >= 10 or os.clock() - T0 > 0.004 then break end           -- hoechstens 10 bzw. 4 ms je Durchlauf
        N = N + 1
        W.HarvQueue[Key] = nil
        local Val = Net.Get("w_harv", Key)
        if Val then
            local ok, _, From, Wait = pcall(W.HarvApply, Val, Now, Key)
            local G = W.HarvGone[Key] or {}
            G.Val, W.HarvGone[Key] = Val, G
            if ok and From then G.Path = From end
            if ok and not Batch then pcall(W.HarvMeshNear, Val, nil, Key)
            elseif ok and Core.Flag("world_harvest_mesh", true) then
                -- nur mit world_harvest_mesh (sonst verwirft W.HarvMeshNear die Liste sofort: 2x FindAllOf umsonst)
                if not Meshless then
                    local okM, L = pcall(W.HarvMeshless)
                    Meshless = okM and L or {}
                    if not okM then Core.Fail("world_harv_meshbatch", L) end
                end
                pcall(W.HarvMeshNear, Val, Meshless, Key)
            end
            if ok and Wait then Again[#Again + 1] = Key end
        end
    end
    for _, K in ipairs(Again) do W.HarvQueue[K] = true end
    W.HarvReadd(Now)
    if Now < (W.HarvAgain or 0) then return end
    W.HarvAgain = Now + 15
    local Pawn = A.OwnPawn()
    if not Alive(Pawn) then return end
    local PX, PY = W.Loc(Pawn)
    local Done = 0
    T0 = os.clock()
    for Key in pairs(W.HarvKeys) do
        if Done >= 30 or os.clock() - T0 > 0.006 then break end
        local Val = Net.Get("w_harv", Key)
        local R = Val and W.HarvParse(Val)
        if R and W.Dist2(R.X, R.Y, 0, PX, PY, 0) < 15000 ^ 2 then
            Done = Done + 1
            local ok, _, From, Wait = pcall(W.HarvApply, Val, Now, Key)
            if ok and From and W.HarvGone[Key] then W.HarvGone[Key].Path = From end
            if ok and Wait then W.HarvQueue[Key] = true end
        end
    end
end

-- Gast: Schluessel nicht mehr im Host-Zustand (live per nil oder nach Neuverbindung, 30 s Schonfrist) -> wieder anlegen
function W.HarvReadd(Now)
    if W.RespawnCfg() <= 0 or not Net.Linked() or Now - (W.LinkAt or 0) < 30 then return end
    local N = 0
    for Key, G in pairs(W.HarvGone) do
        if N >= 5 then break end
        if Net.Get("w_harv", Key) == nil and Now >= (G.Hold or 0) then
            N = N + 1
            local R = W.HarvParse(G.Val)
            if not R then W.HarvGone[Key] = nil
            elseif W.HarvStanding(R) then G.Hold = Now + 60
            else
                local ok, Res = pcall(W.HarvAdd, R, G.Path, Now)
                if ok and Res then
                    W.HarvGone[Key], W.HarvSeen[Key], W.HarvSentQ[Key] = nil, nil, nil
                    W.RespNote("harv", R.Mesh)
                else
                    G.Hold = Now + 60
                end
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------- Nachwachsen

function W.RespawnMin() return Core.Flag("world_respawn_min", 60) end

-- WORLD-17 (world_resp_hostcfg): Gaeste folgen der Nachwachs-Zeit des Hosts (w_cfg "resp", K26) statt der eigenen
-- coop.txt (sonst legt ein Gast mit 0 nie nach bzw. einer mit > 0 Baeume an, die der Host nicht hat)
function W.RespawnCfg()
    if Net.Side == "client" and Core.Flag("world_resp_hostcfg", true) then
        local V = tonumber(Net.Get("w_cfg", "resp"))
        if V then return V end
    end
    return W.RespawnMin()
end

-- WORLD-8 (world_respawn_safe): nicht in Spielerbauten, Claims oder Spieler hinein nachwachsen lassen (Host).
-- Bauteile raeumen Foliage nur beim Platzieren (Buildable_MASTER_C RemoveFoliageComp @0710), AddInstance spaeter nicht.
function W.RespawnBlocked(R)
    if not Core.Flag("world_respawn_safe", true) then return false end
    local Pawns = {}
    for _, G in ipairs(W.Guests("wld2")) do Pawns[#Pawns + 1] = W.GuestPawn(G) end
    if not W.Dedicated() then Pawns[#Pawns + 1] = A.OwnPawn() end    -- Host-Spieler (nicht der Geist am Server)
    for _, P in ipairs(Pawns) do
        if Alive(P) then
            local okL, X, Y = pcall(W.Loc, P)
            if okL and X and W.Dist2(X, Y, 0, R.X, R.Y, 0) < 300 ^ 2 then return true, "Spieler" end
        end
    end
    local B = A.Coop.Build
    if type(B) == "table" and type(B.BuiltNear) == "function" then
        local ok, Hit = pcall(B.BuiltNear, R.X, R.Y, 400)
        if ok and Hit then return true, "Bauteil" end
    end
    if type(B) == "table" and type(B.ClaimAt) == "function" then
        local ok, Hit = pcall(B.ClaimAt, R.X, R.Y)
        if ok and Hit then return true, "Claim" end
    end
    return false
end

-- Sammel-Log: hoechstens einmal je Minute "Ressource wieder da"
function W.RespNote(Kind, Name)
    local C = W.RespCnt or { harv = 0, scrap = 0, Names = {} }
    W.RespCnt = C
    C[Kind] = (C[Kind] or 0) + 1
    if Name and #C.Names < 3 then C.Names[#C.Names + 1] = tostring(Name):match("([^/.]+)$") or tostring(Name) end
end

function W.RespFlush(Now)
    local C = W.RespCnt
    if not C or C.harv + C.scrap == 0 or Now < (W.RespLogAt or 0) then return end
    W.RespLogAt, W.RespCnt = Now + 60, nil
    Log("Ressource wieder da: %d Stein/Baum, %d Schrotthaufen (%s)", C.harv, C.scrap,
        #C.Names > 0 and table.concat(C.Names, ", ") or "-")
end

-- Host (alle 10 s, hoechstens 5 je Art): faellige Instanzen/Haufen zuruecksetzen und Schluessel loeschen
function W.RespawnHost(Now)
    if Net.Side ~= "host" or Now < (W.RespAt or 0) then return end
    W.RespAt = Now + 10
    local Min = W.RespawnMin()
    -- WORLD-17 (K26): Nachwachs-Minuten an die Gaeste (Net.State sendet nur Aenderungen)
    Net.State("w_cfg", "resp", Core.Flag("world_resp_hostcfg", true) and tostring(Min) or nil, 1)
    if Min <= 0 then return end
    local Wait, N = Min * 60, 0
    if On("world_harvest") then
        for Key, R in pairs(W.HarvResp) do
            if N >= 5 then break end
            if R.Force or Now >= math.max(R.At + Wait, R.Hold or 0) then
                N = N + 1
                local okB, Blocked, Why = pcall(W.RespawnBlocked, R)
                if not okB then Core.Fail("world_respawn_safe", Blocked) Blocked = false end
                if W.HarvStanding(R) then
                    R.Hold, R.Force = Now + 60, nil
                elseif Blocked then
                    -- WORLD-8: Schluessel bleibt (Gaeste behalten die Instanz entfernt), in 5 min erneut pruefen
                    R.Hold, R.Force = Now + 300, nil
                    W.LogOnce("rblk" .. tostring(Why), "Nachwachsen: %s bei %.0f/%.0f wartet (%s in der Naehe)", R.Mesh, R.X, R.Y,
                        tostring(Why))
                else
                    local ok, Res = pcall(W.HarvAdd, R, nil, Now)
                    if ok and Res then
                        W.HarvResp[Key], W.HarvDone[Key], W.HarvSeen[Key] = nil, nil, nil
                        Net.State("w_harv", Key, nil)
                        W.RespNote("harv", R.Mesh)
                    else
                        R.Hold, R.Force = Now + 120, nil
                    end
                end
            end
        end
    end
    N = 0
    if On("world_scrap") then
        for Key, R in pairs(W.ScrapResp) do
            if N >= 5 then break end
            if R.Force or Now >= R.At + Wait then
                N = N + 1
                local O, Path = W.ScrapByKey(Key)
                if O then W.ScrapReset(O, Path) end
                W.ScrapResp[Key], W.ScrapDone[Key], W.OwnLog["dup" .. Key] = nil, nil, nil
                Net.State("w_scrapd", Key, nil)
                W.RespNote("scrap", "Schrott " .. Key)
            end
        end
    end
end

-- ------------------------------------------------------------------------------------------- Schrott (#9) / Laptop (#18)
-- Schrotthaufen (Hold-E, 10 s) laufen nur beim Gast: OnExecuteInteract -> RetriggerableDelay -> L_01dd (Salvaged?,
-- Svr_PlaySound, DA_ScrapMetal 12-20, x2 mit Skill_HarvestMaster, an GetPlayerCharacter(0), Partikel weg). Der
-- Server-Zweig (OnServerExecuteInteract) ist leer. Darum meldet der Gast den Abschluss (Salvaged? false -> true,
-- Polling) per w_scrap; der Host prueft, schliesst auf seiner Kopie ab (Owner = Gast), gibt den Schrott dem Gast und
-- verteilt den Zustand per Keyed-State w_scrapd (Schluessel LocKey 50, gleiche Position auf Host und Gast).
-- Owner-Polling (Host, 0,5 s): Haufen nahe einem Gast bekommen Owner = Gast-Figur (Svr_PlaySound des Gasts wird
-- angenommen, GetPlayerCharacter(0) im Haufen loest beim Host auf den Gast auf).

function W.Addr(O)
    if not Alive(O) then return nil end
    return Try(function() return O:GetAddress() end)
end

function W.IsScrap(O)
    return Try(function() return O:GetClass():GetFName():ToString() end, "") == W.SCRAP
end

-- Host: w_scrapd veroeffentlichen (FIFO wie W.HarvPub)
function W.ScrapPub(Key, Val)
    local Q = W.ScrapOrder
    if not Q then Q = { H = 1, T = 0 } W.ScrapOrder = Q end
    W.ScrapPubN = W.ScrapPubN or {}
    Net.State("w_scrapd", Key, Val, 2)
    W.ScrapPubN[Key] = (W.ScrapPubN[Key] or 0) + 1
    Q.T = Q.T + 1
    Q[Q.T] = Key
    while Q.T - Q.H + 1 > W.SCRAP_MAX do
        local Old = Q[Q.H]
        Q[Q.H], Q.H = nil, Q.H + 1
        local N = (W.ScrapPubN[Old] or 1) - 1
        W.ScrapPubN[Old] = N > 0 and N or nil
        if N <= 0 then
            local R = W.ScrapResp[Old]
            if R and W.RespawnMin() > 0 then R.Force = true else Net.State("w_scrapd", Old, nil) end
        end
    end
end

function W.ScrapClear()
    local Q = W.ScrapOrder
    W.ScrapOrder, W.ScrapPubN = nil, {}
    if not Q or Net.Side ~= "host" then return end
    for I = Q.H, Q.T do
        if Q[I] then pcall(Net.State, "w_scrapd", Q[I], nil) end
    end
end

-- Haufen als geborgen setzen (wie L_01dd ohne Belohnung). IsHeld = false zuerst: ein laufendes Halten eines anderen
-- Spielers endet dann in L_01dd ohne Gutschrift (dort "if not IsHeld -> pop").
function W.ScrapSet(O, Path)
    W.ScrapWas[Path] = true
    if Try(function() return O["Salvaged?"] end, true) == true then return false end
    pcall(function() O.IsHeld = false end)
    pcall(function() O["Salvaged?"] = true end)
    local PS = Try(function() return O.ParticleSystem end)
    if Alive(PS) then
        -- Mit Nachwachsen nur ausblenden (W.ScrapReset blendet wieder ein); sonst wie das Spiel zerstoeren
        if W.RespawnCfg() > 0 then
            pcall(function() PS:Deactivate() end)
            pcall(function() PS:SetVisibility(false, false) end)
        else
            pcall(function() PS:K2_DestroyComponent(O) end)
        end
    end
    return true
end

-- Nachwachsen: Haufen wieder bergbar (Salvaged? = false). Partikel nur, wenn W.ScrapSet sie ausgeblendet hat; vom
-- Spiel selbst (L_01dd beim bergenden Spieler) zerstoerte Partikel kommen nicht zurueck, der Haufen ist trotzdem bergbar.
function W.ScrapReset(O, Path)
    pcall(function() O.IsHeld = false end)
    pcall(function() O["Salvaged?"] = false end)
    local PS = Try(function() return O.ParticleSystem end)
    if Alive(PS) then
        pcall(function() PS:SetVisibility(true, false) end)
        pcall(function() PS:Activate(true) end)
    end
    if Path then W.ScrapWas[Path] = false end
end

-- Host: eigener Haufen zu einem w_scrapd-Schluessel (Scanner-Pfade)
function W.ScrapByKey(Key)
    for Path, P in pairs(W.ScrapPos or {}) do
        if P.Key == Key then
            local O = W.Obj(Path)
            if O then return O, Path end
        end
    end
    return nil
end

-- Scanner (beide Seiten): Pfad -> Position/Schluessel; Gast wendet bekannte w_scrapd-Schluessel an
function W.ScrapScan(Objs)
    local Pos, Client = {}, Net.Side == "client"
    for _, O in ipairs(Objs) do
        pcall(function()
            local X, Y, Z = W.Loc(O)
            local Path = W.Path(O)
            local Key = W.LocKey(X, Y, 50)
            Pos[Path] = { X = X, Y = Y, Z = Z, Key = Key }
            if Client and W.ScrapDone[Key] and On("world_scrap") then W.ScrapSet(O, Path) end
        end)
    end
    W.ScrapPos = Pos
end

-- Gast (0,25 s): Abschluss erkennen (nur Uebergang false -> true in der Naehe) und Host-Zustand anwenden;
-- vom Host bestaetigte Haufen (ScrapGot), deren Schluessel weg ist (Nachwachsen), wieder bergbar machen
function W.ScrapClient(Now)
    if Net.Side ~= "client" or not On("world_scrap") or not W.ScrapPos then return end
    local Pawn = A.OwnPawn()
    if not Alive(Pawn) then return end
    local PX, PY, PZ = W.Loc(Pawn)
    local Dirty, Send, R2 = W.ScrapDirty, Net.Has("wscrap"), W.SCRAP_NEAR ^ 2
    local Undo = W.RespawnCfg() > 0 and Net.Linked() and (Now or os.clock()) - (W.LinkAt or 0) >= 30
    W.ScrapDirty = false
    for Path, P in pairs(W.ScrapPos) do
        if W.ScrapDone[P.Key] then
            W.ScrapGot[P.Key] = true
            local O = Dirty and W.Obj(Path)
            if O then W.ScrapSet(O, Path) end
        elseif W.ScrapGot[P.Key] and Undo then
            local O = W.Obj(Path)
            if O then W.ScrapReset(O, Path) end
            W.ScrapGot[P.Key], W.ScrapSent[P.Key] = nil, nil
            W.RespNote("scrap", "Schrott " .. P.Key)
        elseif W.Dist2(P.X, P.Y, P.Z, PX, PY, PZ) < R2 then
            local O = W.Obj(Path)
            local S = O and Try(function() return O["Salvaged?"] end)
            if S == true and W.ScrapWas[Path] == false and Send and not W.ScrapSent[P.Key] then
                W.ScrapSent[P.Key] = true
                Net.Send("w_scrap", string.format("%.0f|%.0f|%.0f", P.X, P.Y, P.Z), nil, 1)
                Log("Schrotthaufen %s geborgen -> Host", P.Key)
            end
            if S ~= nil then W.ScrapWas[Path] = S end
        end
    end
end

-- Host: eigenen Haufen zur gemeldeten Position (Scanner-Pfade, sonst einmal FindAllOf)
function W.ScrapFind(X, Y, Z)
    local Best, BestPath, BestD = nil, nil, W.SCRAP_MATCH ^ 2
    for Path, P in pairs(W.ScrapPos or {}) do
        local D = W.Dist2(X, Y, Z, P.X, P.Y, P.Z)
        if D < BestD then
            local O = W.Obj(Path)
            if O then Best, BestPath, BestD = O, Path, D end
        end
    end
    if Best then return Best, BestPath end
    for _, O in ipairs(FindAllOf(W.SCRAP) or {}) do
        if A.IsAlive(O) then
            pcall(function()
                local D = W.Dist2(X, Y, Z, W.Loc(O))
                if D < BestD then Best, BestPath, BestD = O, W.Path(O), D end
            end)
        end
    end
    return Best, BestPath
end

-- Host: Schrott fuer den Gast. Standard: Gutschrift an ls_inv (Regel b "Rest") -> der Gast-Platzhalter (Menge aus
-- dem lokalen Abschluss) wird angenommen; keine Doppelgabe, egal ob pend oder w_scrap zuerst ankommt.
-- Ohne ls_inv-pend fuer diesen Gast oder mit world_scrap_add=1: direkt JigTryAddItemSomewhere wie das Spiel.
function W.ScrapGrant(G, Pawn)
    local Tech = G.GuestId and W.Rec(G.GuestId).tech
    local Master = W.SetOf(Tech or "").Skill_HarvestMaster == true
    if not Core.Flag("world_scrap_add", false) and Net.Has("inv2b", G) and Core.Flag("inv_v2b", true)
        and Core.Flag("inv_pend", true) then
        local ok, Inv = pcall(require, "ls_inv")
        if ok and type(Inv) == "table" and type(Inv.Credit) == "function" then
            local Max = 20 * ((Master or Tech == nil) and 2 or 1)
            local okC, err = pcall(Inv.Credit, G.Key, W.SCRAP_DA, Max)
            if okC then return Max, "Gutschrift fuer den Platzhalter, hoechstens" end
            Core.Fail("w_scrap_credit", err)
        end
    end
    local N = math.random(12, 20) * (Master and 2 or 1)
    local Comp = Try(function() local C = Pawn.BP_JigMultiplayer if Alive(C) then return C end end)
    local DA = W.Obj(W.SCRAP_DA) or Try(function() local D = LoadAsset(W.SCRAP_DA) if Alive(D) then return D end end)
    if not Comp or not DA then return 0, "Komponente oder Asset fehlt" end
    -- WORLD-23 (world_scrap_addnew): JigTryAddItemSomewhere auf der Server-Kopie legt fuer eine Gast-Komponente vor die
    -- Fuesse (A5) -> AddNewItemSomewhere (Variante A wie ls_inv I.AddFor; 5.6: 10 Parameter, 6. = SpecificContainer)
    if Core.Flag("world_scrap_addnew", true) then
        local Dropped = {}
        local okA, errA = pcall(function()
            Comp:AddNewItemSomewhere(DA, N, nil, 0, true, FName("None"), {}, Dropped, {}, {})
        end)
        if okA then
            local D = Dropped["Dropped?"]
            if D == nil then for _, V in pairs(Dropped) do D = V break end end
            return N, D == true and "Inventar voll, abgelegt" or "Server-Inventar (AddNew)"
        end
        Core.Fail("world_scrap_addnew", errA)
    end
    local ok, err = pcall(function() Comp:JigTryAddItemSomewhere(Comp, DA, N, {}, {}) end)
    if not ok then Core.Fail("w_scrap_add", err) return 0, "Fehler" end
    return N, "Server-Inventar"
end

function W.LogOnce(Key, Fmt, ...)
    if W.OwnLog[Key] then return end
    -- CORE-30: Schluessel enthalten Orte/Gast-Angaben -> Tabelle begrenzen (nur Log-Entprellung)
    W.OwnLogN = (W.OwnLogN or 0) + 1
    if W.OwnLogN > 2000 then W.OwnLog, W.OwnLogN = {}, 1 end
    W.OwnLog[Key] = true
    Log(Fmt, ...)
end

-- Host: w_scrap eines Gasts pruefen und ausfuehren
function W.ScrapHost(G, X, Y, Z, Now)
    local Pawn = W.GuestPawn(G)
    if not Pawn then return end
    if Now - (W.ScrapRate[G.Key] or -100) < 5 then return Net.SecWarn(G, G.Key, "w_scrap_rate") end
    if W.Dist2(X, Y, Z, W.Loc(Pawn)) > W.SCRAP_USE ^ 2 then return Net.SecWarn(G, G.Key, "w_scrap_dist") end
    local O, Path = W.ScrapFind(X, Y, Z)
    local Who = G.GuestId or G.PCName or G.Key
    if not O then
        return W.LogOnce("nf" .. W.LocKey(X, Y, 50), "Schrotthaufen bei %.0f/%.0f nicht gefunden (Gast %s)", X, Y, Who)
    end
    local OX, OY, OZ = W.Loc(O)
    local Key = W.LocKey(OX, OY, 50)
    if W.ScrapDone[Key] or Try(function() return O["Salvaged?"] end, true) == true then
        return W.LogOnce("dup" .. Key, "Schrotthaufen %s schon geborgen, nichts fuer Gast %s", Key, Who)
    end
    W.ScrapRate[G.Key] = Now
    pcall(function() O:SetOwner(Pawn) end)
    W.ScrapSet(O, Path)
    W.ScrapDone[Key] = true
    W.ScrapResp[Key] = { At = Now }
    W.ScrapPub(Key, string.format("%.0f|%.0f|%.0f", OX, OY, OZ))
    local N, How = W.ScrapGrant(G, Pawn)
    Log("Schrotthaufen %s: Gast %s bekommt %d Schrott (%s)", Key, Who, N, How)
end

-- Host (0,5 s): Owner = naechste Gast-Figur fuer nicht geborgene Haufen in SCRAP_OWN. Gehoert der Haufen schon
-- irgendeinem Gast (auch ohne wld2, z. B. von ls_combat combat_owner_world gesetzt) und steht der hoechstens
-- SCRAP_HYST weiter weg (max. SCRAP_OWN + SCRAP_HYST), bleibt er -> kein Hin und Her zwischen den Modulen.
function W.ScrapOwner()
    if Net.Side ~= "host" or not On("world_owner") or not W.ScrapPos then return end
    local Pawns, Own = {}, {}
    Net.ForEachGuest(function(G)
        if not G.Epoch then return end
        local P, PC = W.GuestPawn(G)
        if not P then return end
        local X, Y, Z = W.Loc(P)
        local E = { P = P, X = X, Y = Y, Z = Z, G = G }
        local PA, CA = W.Addr(P), W.Addr(PC)
        if PA then Own[PA] = E end
        if CA then Own[CA] = E end
        if G.Ready and Net.Has("wld2", G) then Pawns[#Pawns + 1] = E end
    end)
    if #Pawns == 0 then return end
    local R2 = W.SCRAP_OWN ^ 2
    for Path, S in pairs(W.ScrapPos) do
        if not W.ScrapDone[S.Key] then
            local Best, BestD = nil, R2
            for _, E in ipairs(Pawns) do
                local D = W.Dist2(S.X, S.Y, S.Z, E.X, E.Y, E.Z)
                if D < BestD then Best, BestD = E, D end
            end
            local O = Best and W.Obj(Path)
            local Cur = O and Own[W.Addr(Try(function() return O:GetOwner() end))]
            local Keep = Cur and math.sqrt(W.Dist2(S.X, S.Y, S.Z, Cur.X, Cur.Y, Cur.Z))
                <= math.min(W.SCRAP_OWN, math.sqrt(BestD)) + W.SCRAP_HYST
            if O and not Keep and pcall(function() O:SetOwner(Best.P) end) then
                W.LogOnce(Path, "Schrotthaufen %s: Besitzer = Gast %s", S.Key, Best.G.GuestId or Best.G.Key)
            end
        end
    end
end

-- Host (0,5 s): Laptop-Ereignis-Manager (eine Instanz je Welt) bekommt Owner = Gast, damit GetPlayerPawn(0) in
-- CallRandomEvent (@0280) beim Host auf den Gast aufloest. Ziel: zuletzt redender Gast (W.LastTalk, wie
-- W.QuestGhost), sonst aktueller Gast-Owner behalten, sonst erster bereiter Gast.
function W.LaptopOwner(Now)
    if Net.Side ~= "host" or not On("world_laptop") then return end
    local Mgr = W.First(W.LAPTOP)
    if not Mgr then return end
    local Guests = W.Guests("wld2")
    if #Guests == 0 then return end
    local Cur = W.Addr(Try(function() return Mgr:GetOwner() end))
    local Last = W.LastTalk and Now - W.LastTalk.At < 120 and Net.Guests[W.LastTalk.Key]
    local T = (Last and Last.Ready and Last.Epoch) and Last or nil
    if not T then
        for _, G in ipairs(Guests) do
            if Cur and W.Addr(W.GuestPawn(G)) == Cur then return end
        end
        T = Guests[1]
    end
    local Pawn = W.GuestPawn(T)
    if not Pawn or W.Addr(Pawn) == Cur then return end
    if pcall(function() Mgr:SetOwner(Pawn) end) and not W.LapLog[T.Key] then
        W.LapLog[T.Key] = true
        Log("Laptop-Ereignis: Besitzer = Gast %s (Belohnung an ihn statt an den Geist)", T.GuestId or T.Key)
    end
end

-- ------------------------------------------------------------------------------------------- Safe-Zone (world_safezone)

function W.GameInstance()
    local GI = W.Obj(W.GIPath)
    if GI then return GI end
    if os.clock() < (W.GIAt or 0) then return nil end
    W.GIAt = os.clock() + 10
    GI = Try(function() return FindFirstOf("SD_GameInstance_C") end)
    if Alive(GI) then W.GIPath = W.Path(GI) return GI end
    return nil
end

function W.SafeZone()
    if not Net.Side or not On("world_safezone") then return end
    local GI = W.GameInstance()
    if not GI then return end
    local Inside, Pawn = false, A.OwnPawn()
    if Alive(Pawn) then
        local PX, PY, PZ = W.Loc(Pawn)
        W.Each("BP_EnterSafeZone_C", function(Z)
            if Inside then return end
            local S = Z.Sphere
            if not Alive(S) then return end
            local C = S:K2_GetComponentLocation()
            local R = S:GetScaledSphereRadius()
            if W.Dist2(C.X, C.Y, C.Z, PX, PY, PZ) <= R * R then Inside = true end
        end)
    end
    if GI["InSafeZone?"] ~= Inside then GI["InSafeZone?"] = Inside end
end

-- ------------------------------------------------------------------------------------------- POI / Infestation

-- Maschinenuebergreifender POI-Schluessel: Map-Actors (RF_WasLoaded) ueber den FName (gleich auf Host und Gast),
-- zur Laufzeit gespawnte ueber den Ort ("L<x>_<y>", Raster 100, "-" -> "m"; FName waere je Maschine anders)
function W.PoiKey(O)
    if not W.Runtime(O) then return W.Name(O) end
    local X, Y = W.Loc(O)
    return (("L" .. W.LocKey(X, Y, 100)):gsub("%-", "m"))
end

-- Host: bekannte POI-Schluessel aus dem Scanner (fuer W.PoiFlush) und ihre Pfade (POI-XP, W.PoiXp)
function W.PoiHost(Objs)
    local Known, Obj = {}, {}
    local N6 = On("world_xp") and Native.NearestMode() == "1"
    local Tip = On("world_poi_tip") and not Core.Down.w_poist
    for _, P in ipairs(Objs) do
        local K = Try(function() return W.PoiKey(P) end)
        if K then
            Known[K], Obj[K] = true, Try(function() return W.Path(P) end)
            if N6 then pcall(W.PoiN6Check, P, K) end
            if Tip then
                local ok, err = pcall(W.PoiStHost, P, K)
                if not ok then Core.Fail("w_poist", err) Tip = false end
            end
        end
    end
    W.PoiKnown, W.PoiObj = Known, Obj
    -- Schalter aus/abgeschaltet: veroeffentlichte Tooltip-Staende zurueckziehen
    if not Tip and next(W.PoiStPub or {}) then
        for K in pairs(W.PoiStPub) do Net.State("w_poist", K, nil) end
        W.PoiStPub = {}
    end
end

-- WORLD-26 Host (Scanner 10 s): Tooltip-Stand eines POI (BossesDefeated, "1/1 Special Container Looted") als Keyed-State
-- w_poist (K25, Schluessel W.PoiKey, Wert "<BossesDefeated>|<0/1>"); Standard (0|0) wird nicht veroeffentlicht
function W.PoiStHost(P, K)
    local B = math.floor(tonumber(Try(function() return P.BossesDefeated end)) or 0)
    local U = Try(function() return P["UniqueContainerLooted?"] end, false) == true
    local V = (B > 0 or U) and string.format("%d|%d", B, U and 1 or 0) or nil
    W.PoiStPub = W.PoiStPub or {}
    if W.PoiStPub[K] == V then return end
    W.PoiStPub[K] = V
    Net.State("w_poist", K, V, 2)
end

-- Host mit ai_nearest=1 (N6): BP_POIManager.DistanceCheck des Hosts loest GetPlayerCharacter(0)/GetLevellingComponent
-- auf den naechsten Gast auf und bucht dessen POI-XP selbst. Uebergang Explored? false->true dem dann naechsten Gast
-- zuordnen; dessen w_poi bekommt keine zweite XP (W.PoiXp). Erster Blick (Was == nil) = Spielstand, keine Zuordnung.
function W.PoiN6Check(P, K)
    W.PoiEx = W.PoiEx or {}
    local Ex = Try(function() return P["Explored?"] end, false) == true
    local Was = W.PoiEx[K]
    W.PoiEx[K] = Ex
    if Was ~= false or not Ex then return end
    local X, Y, Z = W.Loc(P)
    local Best, BestD
    for _, G in ipairs(W.Guests("wld2")) do
        local Pawn = G.GuestId and W.GuestPawn(G)
        if Pawn then
            local D = W.Dist2(X, Y, Z, W.Loc(Pawn))
            if not BestD or D < BestD then Best, BestD = G, D end
        end
    end
    if not Best then return end
    W.PoiN6 = W.PoiN6 or {}
    W.PoiN6[K] = Best.GuestId
    Log("POI %s am Host entdeckt (N6) -> XP dort schon an Gast %s", K, Best.GuestId)
end

-- Host: POI-XP fuer einen neu bestaetigten w_poi (W.PoiFlush). Spiel: XpMultiplierCalc(250|50) = Stufe * Wert *
-- MultiplyValue, AddXP(.., false). Pruefung: Gast-Figur beim Melden nahe am POI, nicht schon per N6 gebucht, Ratenbremse.
function W.PoiXp(Id, Name)
    local Key = Id .. "|" .. Name
    local Pos = W.PoiPos and W.PoiPos[Key]
    if W.PoiPos then W.PoiPos[Key] = nil end
    if not On("world_xp") or not Pos then return end
    local G = Net.Guests[Pos.Key]
    if not G or G.GuestId ~= Id then return end
    local Poi = W.Obj(W.PoiObj and W.PoiObj[Name])
    if not Poi then return Log("POI-XP fuer Gast %s: %s nicht gefunden", Id, Name) end
    if Native.NearestMode() == "1" then pcall(W.PoiN6Check, Poi, Name) end
    if W.PoiN6 and W.PoiN6[Name] == Id then
        return Log("POI-XP fuer Gast %s: %s schon vom Host vergeben (N6)", Id, Name)
    end
    local X, Y, Z = W.Loc(Poi)
    local R = (tonumber(Try(function() return Poi.ExploredCheckRadius end)) or 5000) + W.XP_POI_SLACK
    if W.Dist2(X, Y, Z, Pos[1], Pos[2], Pos[3]) > R * R then
        return Log("POI-XP fuer Gast %s: %s zu weit entfernt gemeldet - verworfen", Id, Name)
    end
    if not W.XpRate(G, "poi", os.clock()) then return end
    local LC = W.XpLC(G)
    if not LC then return end
    local Major = Try(function() return Poi.POI[W.POI_MAJOR] end, false) == true
    W.XpGrant(G, LC, "POI " .. Name, W.XpLevel(LC) * (Major and 250 or 50) * W.XpMul(LC))
end

function W.PoiClient(Objs)
    if not On("world_poi") or not Net.Has("wld2") or not W.PoiApplied then return end
    for _, P in ipairs(Objs) do
        local Name = W.PoiKey(P)
        if not W.PoiSent[Name] and Try(function() return P["Explored?"] end, false) then
            W.PoiSent[Name] = true
            Net.State("w_poi", Name, "1", 2)
        end
    end
end

-- Host: vorgemerkte w_poi-Namen gegen die bekannten BP_POIManager_C (Pfade aus dem Scanner) pruefen und je Gast
-- hoechstens einmal pro Durchlauf speichern. Unbekannte Namen warten bis zu 120 s (Scanner/Streaming), dann verworfen.
function W.PoiFlush(Now)
    if Net.Side ~= "host" or not W.PoiPend or Now < (W.PoiFlushAt or 0) then return end
    W.PoiFlushAt = Now + 5
    local Known = {}
    for K in pairs(W.PoiKnown or {}) do Known[K] = true end
    for _, Path in ipairs(W.Paths["BP_POIManager_C"] or {}) do
        local Name = Path:match("[%.:]([^%.:]+)$")
        if Name then Known[Name] = true end
    end
    for Id, P in pairs(W.PoiPend) do
        local R = W.Rec(Id)
        local Set, Dirty, Left = W.SetOf(R.poi), false, 0
        for Name, T in pairs(P) do
            if Name ~= "N" then
                if Set[Name] then
                    P[Name] = nil
                    if W.PoiPos then W.PoiPos[Id .. "|" .. Name] = nil end
                elseif Known[Name] then
                    Set[Name], P[Name], Dirty = true, nil, true
                    local ok, err = pcall(W.PoiXp, Id, Name)
                    if not ok then Core.Fail("w_xp_poi", err) end
                elseif Now - T > 120 then
                    P[Name] = nil
                    if W.PoiPos then W.PoiPos[Id .. "|" .. Name] = nil end
                    Log("POI %s von Gast %s unbekannt, verworfen", Name, tostring(Id))
                else
                    Left = Left + 1
                end
            end
        end
        if Dirty then R.poi = W.ListOf(Set) W.SaveRec(Id) end
        if Left == 0 then W.PoiPend[Id] = nil else P.N = Left end
    end
end

function W.InfHost(Objs)
    if not On("world_infest") then return end
    for _, O in ipairs(Objs) do
        if not W.Runtime(O) and Try(function() return O["IsDestroyed?"] end, false) then
            local Path = W.Path(O)
            if not W.InfSent[Path] then W.InfSent[Path] = true Net.State("w_inf", Path, "1", 2) end
        end
    end
end

-- ------------------------------------------------------------------------------------------- Fundorte (Runde 9)
-- BP_PrefabSpawner (5.6 UB): BeginPlay -> Delay(DelayStart) -> L_00bb (nicht DynamicEvent?): Zufall + Platz -> Prefab,
-- Timer DistanceToPrefab, SpawnMarker (@0551: Marker? und CVar Difficulty.RandomEventMarker -> BP_Marker_C @0352).
-- DistanceToPrefab: GetPlayerCharacter(0) < DistanceToDiscoverPrefab -> Marker weg, XpMultiplierCalc(40,60) -> AddXP.
--   WORLD-4 (world_prefabmark, Cap wpfm): Host veroeffentlicht w_pfm (Schluessel W.LocKey 100, Wert
--     "<TexPath>|<Enc Titel>|<Enc Text>") fuer Spawner mit eigenem Host-Marker; Gast entfernt eigene (lokale) Marker
--     und zeigt die des Hosts, ausser schon entdeckte (w_pfset/w_pfd).
--   WORLD-5 (world_prefabxp): Host prueft je 2 s die Naehe der Gaeste zu Spawnern mit Discover-Timer (nicht dynamisch,
--     gespawnt) und bucht die Fund-XP je GuestId einmal (.world.txt pfx), meldet w_pfd.
W.MARKER_CLS = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_Marker.BP_Marker_C"

-- Host (Scanner 30 s): Marker-Stand veroeffentlichen und Discover-Liste (nur Lua-Werte) fuer W.PrefabXpHost
function W.PrefabHost(Objs)
    local Mark, Xp = On("world_prefabmark"), On("world_prefabxp")
    local Pub, List = {}, {}
    for _, O in ipairs(Objs) do
        if Try(function() return O["Spawned?"] end, false) == true then
            local X, Y, Z = W.Loc(O)
            local Key = W.LocKey(X, Y, 100)
            if Mark and Try(function() return O["Marker?"] end, false) == true
                and Try(function() return A.IsAlive(O.Marker) end, false) then
                local Tex = Try(function() local T = O["Marker Texture"] if A.IsAlive(T) then return W.Path(T) end end, "")
                local Ti = Try(function() return O["Marker Title"]:ToString() end, "")
                local De = Try(function() return O["Marker Description"]:ToString() end, "")
                Pub[Key] = Tex .. "|" .. Net.Enc(Ti) .. "|" .. Net.Enc(De)
            end
            -- Discover-Timer nur im nicht dynamischen Weg (@0203); dynamische Ereignisse geben in SP keine Fund-XP
            local R = Xp and Try(function() return O["DynamicEvent?"] end, true) ~= true
                and tonumber(Try(function() return O.DistanceToDiscoverPrefab end)) or nil
            if R and R > 0 then
                List[#List + 1] = { Path = Try(function() return W.Path(O) end), Key = Key, X = X, Y = Y, Z = Z, R = R }
            end
        end
    end
    W.PfList = List
    local Old = W.PfmPub or {}
    for K, V in pairs(Pub) do
        if Old[K] ~= V then Net.State("w_pfm", K, V, 3) end
    end
    for K in pairs(Old) do
        if not Pub[K] then Net.State("w_pfm", K, nil) end
    end
    W.PfmPub = Pub
end

-- Gast-Minimap: Marker-Actor (BP_Marker_C) austragen und zerstoeren (wie ls_ui F.RemoveMate)
function W.DropMarker(Mk)
    if not Alive(Mk) then return end
    local Own = A.OwnPawn()
    local Mini = Alive(Own) and Try(function() local C = Own.MinimapSystemComponent if A.IsAlive(C) then return C end end)
    local Wd = Try(function() local M = Mk.Marker if A.IsAlive(M) then return M end end)
    if Mini and Wd then pcall(function() Mini["Remove World Marker"](Mini, Wd, Mk) end) end
    pcall(function() Mk:K2_DestroyActor() end)
end

-- Gast (Scanner 30 s): Spawner-Orte merken; bei aktiven Host-Markern die eigenen (lokalen) Marker der Spawner entfernen
function W.PrefabClient(Objs)
    local Clean = On("world_prefabmark") and Net.Has("wpfm") and Net.Has("wld2")
    local N = 0
    for _, O in ipairs(Objs) do
        local X, Y, Z = W.Loc(O)
        W.PfLoc[W.LocKey(X, Y, 100)] = { X = X, Y = Y, Z = Z }
        local Mk = Clean and Try(function() local M = O.Marker if A.IsAlive(M) then return M end end)
        if Mk and W.Role(Mk) == 3 then
            W.DropMarker(Mk)
            N = N + 1
        end
    end
    if N > 0 then Log("Fundort-Marker: %d lokale Marker entfernt (Marker kommen vom Host)", N) end
end

-- Gast: lokaler Welt-Marker wie BP_PrefabSpawner.SpawnMarker (@0352-@0515: Textur, Titel, Text, Groesse 3.5, Farbe)
function W.SpawnMarker(Key, Val)
    local Tex, Ti, De = tostring(Val):match("^([^|]*)|([^|]*)|([^|]*)$")
    if not Tex then return nil end
    local L = W.PfLoc[Key]
    if not L then
        local KX, KY = Key:match("^(%-?%d+)_(%-?%d+)$")
        if not KX then return nil end
        L = { X = tonumber(KX) * 100, Y = tonumber(KY) * 100, Z = 0 }
    end
    local Class, World = W.Obj(W.MARKER_CLS), A.CurrentWorld()
    if not (Class and Alive(World)) then return nil end
    local T = Tex:match("^/Game/[%w_/]+%.[%w_]+$") and (W.Obj(Tex)
        or Try(function() local O = LoadAsset(Tex) if A.IsAlive(O) then return O end end))
    local Tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = L.X, Y = L.Y, Z = L.Z },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GPS = A.UEHelpers.GetGameplayStatics()
    local Mk = GPS:BeginDeferredActorSpawnFromClass(World, Class, Tf, 1, nil, 1)
    if not Alive(Mk) then return nil end
    pcall(function() if T then Mk.MarkerTexture = T end end)
    pcall(function() Mk.MarkerTitle = FText(Net.Dec(Ti)) end)
    pcall(function() Mk.MarkerDescription = FText(Net.Dec(De)) end)
    -- Review 2: Eigenschaft heisst "Texture Size" (props.tsv 0x2E0, BP_PrefabSpawner SpawnMarker); AddMarker liest sie
    pcall(function() Mk["Texture Size"] = { X = 3.5, Y = 3.5 } end)
    pcall(function() Mk.Color = { R = 0.505208015, G = 0.169744, B = 0.0342070013, A = 1 } end)
    GPS:FinishSpawningActor(Mk, Tf, 1)
    return Try(function() return W.Path(Mk) end)
end

-- Gast (1 s): Host-Marker anzeigen/entfernen. Entdeckte (w_pfset/w_pfd) nie; ohne w_pfset hoechstens 20 s warten.
function W.PrefabMarkClient(Now)
    if Net.Side ~= "client" then return end
    local Want = On("world_prefabmark") and Net.Has("wpfm") and Net.Has("wld2")
    if not Want then
        for K, P in pairs(W.PfmHave) do pcall(W.DropMarker, W.Obj(P)) W.PfmHave[K] = nil end
        return
    end
    if not W.PfxSet and Now < (W.PfxWait or 0) then return end
    if not W.PfmDirty and Now < (W.PfmAt or 0) then return end
    W.PfmDirty, W.PfmAt = false, Now + 10
    local Done = W.PfxSet or {}
    for K, P in pairs(W.PfmHave) do
        local Mk = W.Obj(P)
        if not W.PfmWant[K] or Done[K] or not Mk then
            if Mk then pcall(W.DropMarker, Mk) end
            W.PfmHave[K] = nil
        end
    end
    local N = 0
    for K, V in pairs(W.PfmWant) do
        if not W.PfmHave[K] and not Done[K] then
            if N >= 10 then W.PfmDirty = true break end
            N = N + 1
            local ok, P = pcall(W.SpawnMarker, K, V)
            if ok and P then W.PfmHave[K] = P end
        end
    end
end

-- Host (2 s): Fund-XP wie DistanceToPrefab (Stufe * Zufall 40-60 * MultiplyValue), je GuestId und Spawner einmal
function W.PrefabXpHost(Now)
    if Net.Side ~= "host" or not On("world_prefabxp") or Now < (W.PfxAt or 0) then return end
    W.PfxAt = Now + 2
    local List = W.PfList
    if not List or #List == 0 then return end
    for _, G in ipairs(W.Guests("wld2")) do
        local Pawn = G.GuestId and W.GuestPawn(G)
        if Pawn then
            local X, Y, Z = W.Loc(Pawn)
            local Rec, Set
            for _, P in ipairs(List) do
                if W.Dist2(X, Y, Z, P.X, P.Y, P.Z) < P.R * P.R then
                    Rec = Rec or W.Rec(G.GuestId)
                    Set = Set or W.SetOf(Rec.pfx)
                    if not Set[P.Key] and not W.PrefabFound(G, P, Rec, Set, Now) then break end
                end
            end
        end
    end
end

-- Host: einen Fund buchen. false = Ratenbremse (spaeter erneut, noch nicht als entdeckt gemerkt)
function W.PrefabFound(G, P, Rec, Set, Now)
    local O = W.Obj(P.Path)
    if not O or Try(function() return O["Spawned?"] end, false) ~= true then return true end
    local XpOn = On("world_xp")
    if XpOn and not W.XpRate(G, "poi", Now) then return false end
    Set[P.Key] = true
    Rec.pfx = W.ListOf(Set)
    W.SaveRec(G.GuestId)
    local LC = XpOn and W.XpLC(G)
    if LC then W.XpGrant(G, LC, "Fundort " .. P.Key, W.XpLevel(LC) * (40 + math.random() * 20) * W.XpMul(LC)) end
    if Net.Has("wpfm", G) then Net.Send("w_pfd", P.Key, G, 1) end
    Log("Fundort %s von Gast %s entdeckt", P.Key, G.GuestId)
    return true
end

-- ------------------------------------------------------------------------------------------- Tech (world_tech)

-- Alle geladenen TechnologyAssets (Name -> Pfad); leer, solange der Baum noch nicht geladen ist
function W.TechList(Now)
    if W.TechAssets and next(W.TechAssets) and Now - (W.TechAssetsAt or 0) < 120 then return W.TechAssets end
    if W.TechAssets and not next(W.TechAssets) and Now - (W.TechAssetsAt or 0) < 5 then return W.TechAssets end
    W.TechAssets, W.TechAssetsAt = {}, Now
    for _, T in ipairs(FindAllOf("TechnologyAsset") or {}) do
        if A.IsAlive(T) then W.TechAssets[W.Name(T)] = W.Path(T) end
    end
    return W.TechAssets
end

function W.TechComp()
    local PC = A.LocalPC()
    local TT = Alive(PC) and Try(function() return PC.TechTreeComponent end)
    if Alive(TT) then return TT end
    return nil
end

-- Gast: Host-Stand anwenden ("?" = Host kennt den Gast nicht: lokalen Stand behalten und melden)
function W.TechApply(List, Now)
    local TT = W.TechComp()
    -- ohne Komponente oder ohne geladene Assets spaeter erneut (sonst wuerde ein leerer Stand gemeldet)
    if not TT or not next(W.TechList(Now)) then W.TechWant = List return end
    W.TechWant = nil
    if List ~= "?" then
        local Want, Up, Down = W.SetOf(List), 0, 0
        for Name, Path in pairs(W.TechList(Now)) do
            local T = W.Obj(Path)
            local Has = T and Try(function() return TT:IsTechnologyUnlocked(T) end, false)
            if T and Want[Name] and not Has then
                if pcall(function() TT:UnlockTechnology(T) end) then Up = Up + 1 end
            elseif T and Has and not Want[Name] then
                -- CORE-20: Knoten vor dem Feldzugriff pruefen (ohne Baum/Knoten: wie Standard, nicht sperren)
                local Ref = W.TechTreeOf(TT)
                local Node = Ref and Try(function() return Ref:GetNodeFromTechAsset(T) end)
                local Default = not Alive(Node) or Try(function() return Node.IsUnlockedByDefault end, true) == true
                if not Default and pcall(function() TT:LockTechnology(T) end) then Down = Down + 1 end
            end
        end
        Log("Tech-Baum vom Host: %d freigeschaltet, %d gesperrt", Up, Down)
    end
    W.TechApplied = true
end

function W.TechClient(Now)
    if Net.Side ~= "client" or not On("world_tech") or not Net.Has("wtech") then return end
    if W.TechWant then W.TechApply(W.TechWant, Now) return end
    if not W.TechApplied or Now < (W.TechAt or 0) then return end
    W.TechAt = Now + 5
    local TT = W.TechComp()
    local Assets = W.TechList(Now)
    if not TT or not next(Assets) then return end
    local Set = {}
    for Name, Path in pairs(Assets) do
        local T = W.Obj(Path)
        if T and Try(function() return TT:IsTechnologyUnlocked(T) end, false) then Set[Name] = true end
    end
    local List = W.ListOf(Set)
    if List ~= W.TechSent then W.TechSent = List Net.State("w_tech", "set", List == "" and "-" or List, 2) end
end

-- TechTreeManager-Methoden nur mit zugewiesenem Baum (nativ ohne Baum ungeprueft -> kein Aufruf)
function W.TechTreeOf(TT)
    if Alive(TT) and Alive(Try(function() return TT.TechnologyTree end)) then return TT end
    return nil
end

function W.TechDefault(Ref, T)
    if not Ref or not T then return false end
    local Node = Try(function() return Ref:GetNodeFromTechAsset(T) end)
    return Alive(Node) and Try(function() return Node.IsUnlockedByDefault end, false) == true
end

-- Host: w_tech eines Gasts pruefen und auf die Server-Kopie seines TechTreeComponent anwenden (die Perk-Abfragen
-- beim Host lesen sie; das Spiel selbst gleicht den Baum nie ab). Bereits bestaetigte Eintraege (R.tech) und
-- Standard-Freischaltungen kosten nichts; neue wie TryToUnlockTechnology (EVT @0133-018c): HasUnlockedParents,
-- BP_SkillTreeAsset_C.Cost <= SkillPoints, dann SkillPoints -= Cost - aber gegen die Server-Kopie der Punkte, die
-- main.lua (V.PROGRESS) zum Gast spiegelt. Entfernte bestaetigte (ResetTree beim Gast) = Punkte zurueck.
-- false = spaeter erneut (Controller/Assets/Baum fehlen noch).
function W.TechHost(G, P, Now)
    local Id = G.GuestId
    local PC = Net.PC(G)
    local TT = PC and Try(function() local C = PC.TechTreeComponent if Alive(C) then return C end end)
    local Assets = W.TechList(Now)
    local SP0 = TT and Try(function() return TT.SkillPoints end)
    if not TT or not next(Assets) or type(SP0) ~= "number" then return false end
    local Own = W.TechTreeOf(TT)
    W.TechNoTree = W.TechNoTree or {}
    if not Own and not W.TechNoTree[G.Key] then
        if Now - P.At < 30 then return false end
        W.TechNoTree[G.Key] = true
        Log("Tech-Baum: Server-Kopie von Gast %s hat keinen Baum - nur Kostenpruefung, Perks beim Host ohne Wirkung", Id)
    end
    local Ref = Own or W.TechTreeOf(W.TechComp())
    local CP = Try(function() return TT.CurrentPoints end)
    local R = W.Rec(Id)
    local Old, Want = W.SetOf(R.tech), W.SetOf(P.List)
    -- lokaler Modus: der Gast bringt Baum und Punkte aus seinem Spielstand mit (erste Meldung ohne Datensatz)
    local Free = (R.tech == nil and A.Settings.local_inventory) and true or false
    local Acc, Pend, Bad, SP, Spent, Refund, Up, Down = {}, {}, {}, SP0, 0, 0, 0, 0
    for Name in pairs(Want) do
        local T = Assets[Name] and W.Obj(Assets[Name])
        if Old[Name] or Free then Acc[Name] = T or true
        elseif not T then Bad[#Bad + 1] = Name
        elseif W.TechDefault(Ref, T) or (Own and Try(function() return Own:IsTechnologyUnlocked(T) end, false) == true) then
            Acc[Name] = T
        else Pend[Name] = T end
    end
    local function Unlock(T)
        if Own and type(T) ~= "boolean" and not Try(function() return Own:IsTechnologyUnlocked(T) end, false)
            and pcall(function() Own:UnlockTechnology(T) end) then Up = Up + 1 end
    end
    for _, T in pairs(Acc) do Unlock(T) end
    -- Neue in Eltern-Reihenfolge (mehrere Durchlaeufe), Kosten gegen die Server-Punkte
    local More = true
    while More and next(Pend) do
        More = false
        for Name, T in pairs(Pend) do
            local Cost = Try(function() return T.Cost end)
            local Parents = not Own or Try(function() return Own:HasUnlockedParents(T) end, false) == true
            if type(Cost) == "number" and Cost >= 0 and Cost <= SP and Parents then
                Unlock(T)
                SP, Spent, Acc[Name], Pend[Name], More = SP - Cost, Spent + Cost, T, nil, true
            end
        end
    end
    for Name in pairs(Pend) do Bad[#Bad + 1] = Name end
    -- Entfernte bestaetigte: sperren und Kosten zurueck (hoechstens bis CurrentPoints, wie ResetTree)
    for Name in pairs(Old) do
        local T = not Want[Name] and Assets[Name] and W.Obj(Assets[Name])
        if T and not W.TechDefault(Ref, T) then
            local Cost = Try(function() return T.Cost end)
            if type(Cost) == "number" and Cost > 0 then Refund = Refund + Cost end
            if Own and Try(function() return Own:IsTechnologyUnlocked(T) end, false)
                and pcall(function() Own:LockTechnology(T) end) then Down = Down + 1 end
        end
    end
    SP = SP + Refund
    if Refund > 0 and type(CP) == "number" then SP = math.min(SP, math.max(CP, SP0 - Spent)) end
    -- Unlock/Lock duerfen die Punkte nicht veraendern: immer auf den gerechneten Wert
    if Try(function() return TT.SkillPoints end) ~= SP then pcall(function() TT.SkillPoints = SP end) end
    local Names = {}
    for Name in pairs(Acc) do Names[Name] = true end
    local List = W.ListOf(Names)
    if R.tech ~= List then R.tech = List W.SaveRec(Id) end
    if Up + Down + Spent + Refund > 0 then
        Log("Tech-Baum von Gast %s am Host: %d frei, %d gesperrt, %d Punkte bezahlt, %d zurueck (Rest %d)",
            Id, Up, Down, Spent, Refund, SP)
    end
    if #Bad > 0 then
        table.sort(Bad)
        Log("w_tech: Gast %s meldet %d Techs ohne Punkte/Voraussetzung - verworfen: %s", Id, #Bad,
            table.concat(Bad, ",", 1, math.min(#Bad, 10)))
        if not P.Join then Net.SecWarn(G, G.Key, "w_tech_kosten") end
        -- Gast auf den bestaetigten Stand zuruecksetzen und die (lokal schon abgezogenen) Punkte neu spiegeln
        if Net.Has("wtech", G) then Net.Send("w_techset", List, G, 1) end
        local V = A.Coop and A.Coop.Stats
        if type(V) == "table" and type(V.SentText) == "table" then V.SentText[G.Key] = nil end
    end
    return true
end

-- Host (1 s): vorgemerkte Gaeste (w_tech oder Beitritt), hoechstens 2 je Durchlauf; nicht pruefbar -> alle 3 s erneut
function W.TechHostTick(Now)
    if Net.Side ~= "host" or not W.TechPend or not On("world_tech") then return end
    local Due = {}
    for Id, P in pairs(W.TechPend) do
        if #Due < 2 and Now >= (P.Next or 0) then Due[#Due + 1] = Id end
    end
    for _, Id in ipairs(Due) do
        local P = W.TechPend[Id]
        W.TechPend[Id] = nil
        local G = Net.Guests[P.Key]
        if G and G.GuestId == Id and not W.TechHost(G, P, Now) then
            if Now - P.At < 90 then P.Next, W.TechPend[Id] = Now + 3, P
            else Log("w_tech: Tech-Liste von Gast %s nicht pruefbar (keine Server-Kopie) - verworfen", Id) end
        end
    end
end

-- ------------------------------------------------------------------------------------------- Schlafen (world_sleep)

-- Gast: Klick merken (Hook-Body) -> 60 s "schlaeft" melden
function W.SleepClient(Now)
    if Net.Side ~= "client" or not On("world_sleep") or not Net.Has("wld2") then return end
    if W.SleepClick and W.SleepClick ~= W.SleepSeen then
        W.SleepSeen, W.SleepUntil = W.SleepClick, Now + 60
        Net.State("w_sleep", "on", "1", 0)
    elseif W.SleepUntil and Now > W.SleepUntil then
        W.SleepUntil = nil
        Net.State("w_sleep", "on", "0", 1)
    end
end

function W.Note(G, Text)
    if G then Net.Send("w_note", Text, G, 1) return end
    for _, P in ipairs(W.Guests("wld2")) do Net.Send("w_note", Text, P, 1) end
end

-- Host: alle bereiten Gaeste schlafen -> Zeitsprung am Host-Himmel (repliziert); sonst Zwischenstand melden
function W.SleepHost(Now)
    if Net.Side ~= "host" or not On("world_sleep") then return end
    local Guests, Sleeping = W.Guests("wld2"), 0
    for _, G in ipairs(Guests) do
        if Net.Get("w_sleep", "on", G) == "1" then Sleeping = Sleeping + 1 end
    end
    if Sleeping == 0 then W.SleepCount = 0 return end
    -- WORLD-27/PLAYER-23 (world_sleep_pct, 100 = alle wie bisher): Anteil schlafender Gaeste fuer den Zeitsprung
    local Pct = math.floor(math.max(1, math.min(100, tonumber(Core.Flag("world_sleep_pct", 100)) or 100)) + 0.5)
    local Need = math.max(1, math.ceil(#Guests * Pct / 100 - 1e-9))
    if Sleeping < Need then
        if Sleeping ~= W.SleepCount then
            W.SleepCount = Sleeping
            W.Note(nil, string.format("Schlafen: %d/%d Spieler", Sleeping, Need))
        end
        return
    end
    if Now < (W.SleptAt or 0) then return end
    W.SleptAt, W.SleepCount = Now + 30, 0
    local Sky = W.First("Ultra_Dynamic_Sky_C")
    if not Sky then return end
    local ok, err = pcall(function() Sky["Transition Time of Day"](Sky, 650, 2.0, 7, 2.0, false) end)
    if not ok then Core.Fail("world_sleep", err) return end
    pcall(function() Sky:ForceNetUpdate() end)
    Log("%d von %d Gaesten schlafen (noetig %d, %d%%): Zeitsprung auf 6:30", Sleeping, #Guests, Need, Pct)
    for _, G in ipairs(Guests) do Net.Send("w_slept", "1", G, 0) end
end

-- ------------------------------------------------------------------------------------------- XP-Paritaet (world_xp)
-- Der Host-Spiegel (main V.PROGRESS) ueberschreibt LevellingComponent/PassiveSkills des Gasts; XP aus Quellen, die nur
-- beim Gast laufen, ging so verloren. Decode UE 5.6 (analysis56\fn\...):
--   W_PlayerCraftingUI/W_CraftingWorkbenchUI/W_ConstructionWorkbenchUI/W_CookingUI (5.3: W_CampfireUI): Button_81 ->
--     CountIndex-mal SERVER_RequestCraftItem(Drop) am PlayerMPComp (@0242/@09db), danach einmal (ItemCrafted?)
--     GetLevellingComponent->AddXP(Stufe*CountIndex*4, false) (@049e-@0531, ohne Delay). Host vergibt keine XP.
--   JigContextMenuComp.ContextReadBook: Buch -> AddXP_<Skill>(250) + XpMultiplierCalc(75,75); Zeitschrift ->
--     XPMultiplier_<Skill>(Used?): Used? -> XpMultiplierCalc(75,75), sonst AddXP_<Skill>(125) + XpMultiplierCalc(25,25)
--     (@0fcc-@162b). XpMultiplierCalc = Stufe*Zufall*MultiplyValue am Spieler-0-Controller. Nur Gast-UI.
--   BP_POIManager.DistanceCheck: Spieler 0 nah -> XpMultiplierCalc(250|50) -> AddXP; beim Gast lokal (Host nur mit
--     N6 ai_nearest=1 fuer den naechsten Gast, W.PoiN6Check). Weg: w_poi -> W.PoiFlush -> W.PoiXp.
--   Angeln 5.6: BP_FishingRodPickup.CatchFish entfernt; FishingComponent_C.Svr_CatchFish (NetServer) -> MC_CatchFish
--     -> L_18b1 .. @1466 AddXP_Fishing(4-6) an GetPassiveSkillsComponent = GetPlayerController(0) (Host: Geist).
--     -> Host-Hooks Svr_CatchFish + AddXP_Fishing paaren (W.FishHostTick), Gutschrift auf die Server-Kopie des Gasts.
-- Gast: Pre-Hooks (nur Tabellen) auf Quelle + LevellingComponent.AddXP; Quelle mit passendem AddXP (=XP wirklich
-- vergeben) -> w_xp (Ratenbremse). Host: Ratenbremse je GuestId/Quelle, Betrag selbst aus der Server-Kopie, AddXP.
W.XP_SRC = {                          -- Gap = Mindestabstand s, Max = hoechstens je 60 s
    craft = { Gap = 0.5, Max = 30 },
    book = { Gap = 2, Max = 6 },
    poi = { Gap = 0, Max = 10 },
    fish = { Gap = 3, Max = 10 },
}
W.XP_CRAFT = {
    W_PlayerCraftingUI_C = "/Game/Inventory/Widgets/Crafting/W_PlayerCraftingUI.W_PlayerCraftingUI_C",
    W_CraftingWorkbenchUI_C = "/Game/Inventory/Widgets/Crafting/W_CraftingWorkbenchUI.W_CraftingWorkbenchUI_C",
    W_ConstructionWorkbenchUI_C = "/Game/Inventory/Widgets/Crafting/W_ConstructionWorkbenchUI.W_ConstructionWorkbenchUI_C",
    -- 5.6: W_CampfireUI_C -> W_CookingUI_C (gleicher Ordner, Button_81 gleich aufgebaut)
    W_CookingUI_C = "/Game/Inventory/Widgets/Crafting/W_CookingUI.W_CookingUI_C",
}
W.XP_CRAFT_MUL = 4                    -- 5.6: Stufe*CountIndex*4 (5.3: *5)
W.XP_BTN = ":BndEvt__Button_81_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
W.XP_BOOK_FN = "/Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C:ContextReadBook"
W.XP_ADD_FN = "/Game/Blueprints/Components/LevellingComponent.LevellingComponent_C:AddXP"
-- 5.6 Angeln (Host-Hooks): Svr_CatchFish (NetServer 0x0c200040) + AddXP_Fishing (Betrag 4-6, @1438/@1466)
W.XP_FISH_SVR = "/Game/Blueprints/Components/FishingComponent.FishingComponent_C:Svr_CatchFish"
W.XP_FISH_ADD = "/Game/Blueprints/Components/PassiveSkillsComponent.PassiveSkillsComponent_C:AddXP_Fishing"
W.XP_FISH_MIN, W.XP_FISH_MAX = 4, 6
W.XP_FISH = { s = { 20, 25 }, r = { 40, 50 }, l = { 80, 100 } }   -- nur alte Gast-Meldung "fish|s|r|l" (5.3)
-- ContextReadBook 5.6: <Skill>Book -> AddXP_<Skill>(250) + Stufen-XP 75; <Skill>Magazine -> XPMultiplier_<Skill>(Used?):
-- Used? -> Stufen-XP 75, sonst (Multiplikator schon aktiv) AddXP_<Skill>(125) + Stufen-XP 25; immer verbraucht
W.XP_BOOK = {}
for _, S in ipairs({ "FirstAid", "Fishing", "Fitness", "Marksmanship", "Reloading", "Sneaking", "Strength", "Thief",
    "Toughness", "Scavenging" }) do
    W.XP_BOOK[S .. "Book"], W.XP_BOOK[S .. "Magazine"] = { S, false }, { S, true }
end
W.POI_MAJOR = "IsAMajorPOI?_11_A87DDB26439CC030B3170C9A49D4FDEB"
W.XP_POI_SLACK = 30000                -- Gast-Scanner meldet bis 10 s spaeter (Fahrzeug): Radius + 300 m

-- Hook-Koerper (Gast, nur Pre, nur Felder lesen + Tabellen schreiben)
function W.XpRec(Rec)
    if #W.XpEv < 20 then Rec.At = os.clock() W.XpEv[#W.XpEv + 1] = Rec end
end

function W.HXpCraft(Ctx)
    -- INV-1 (E2): Crafting-Klick fuer ls_inv I.ClientFast (Button_81 sperren, bis die Antwort da ist); nur Tabellenfeld
    local Inv = A.Coop and A.Coop.Inv
    if type(Inv) == "table" then Inv.CraftBusy = os.clock() end
    if not W.XpOn then return end
    local Rec = { K = "craft" }
    pcall(function()
        local Wd = Ctx:get()
        Rec.Cls = Wd:GetClass():GetFName():ToString()
        Rec.N = Wd.CountIndex
    end)
    if Rec.Cls and W.XP_CRAFT[Rec.Cls] then W.XpRec(Rec) end
end

-- Buch/Zeitschrift: ItemId aus CurrentItemRef.JigDataAsset (wie GetItemID, JSI_Slot_C), nur Felder lesen
function W.HXpBook(Ctx)
    if not W.XpOn then return end
    local Rec = { K = "book" }
    pcall(function()
        local Item = Ctx:get().CurrentItemRef
        local DA = Item and Item:IsValid() and Item.JigDataAsset
        if DA and DA:IsValid() then Rec.Id = DA.ItemId:ToString() end
    end)
    W.XpRec(Rec)
end

function W.HXpAdd(_, XP)
    if not W.XpOn or not W.XpAddOn or #W.XpAdd >= 20 then return end
    W.XpAdd[#W.XpAdd + 1] = { At = os.clock(), V = Try(function() return XP:get() end, 0) }
end

-- Gast (10 s, W.TryHooks): Hooks setzen, sobald die Funktion geladen ist (Widgets erst nach dem ersten Oeffnen).
-- CORE-18: LevellingComponent.AddXP laeuft in der Schadens-/Tod-Kette (Regel 3) -> nur noch mit world_xp_addhook=1.
-- Crafting-Knoepfe auch ohne world_xp, solange ls_inv den Klick braucht (inv_craft_one, E2 CraftBusy).
function W.XpHookTry()
    local Xp = On("world_xp")
    local Defs = {}
    if Xp and Core.Flag("world_xp_addhook", false) then Defs[#Defs + 1] = { "add", W.XP_ADD_FN, W.HXpAdd } end
    if Xp then Defs[#Defs + 1] = { "book", W.XP_BOOK_FN, W.HXpBook } end
    if Xp or Core.Flag("inv_craft_one", true) then
        for Cls, Path in pairs(W.XP_CRAFT) do Defs[#Defs + 1] = { Cls, Path .. W.XP_BTN, W.HXpCraft } end
    end
    for _, D in ipairs(Defs) do
        W.HookStale(W.XpHooks, D[1], D[2])
        if not W.XpHooks[D[1]] and W.Obj(D[2]) then
            W.XpHooks[D[1]] = W.Hook(D[2], D[3])
            if W.XpHooks[D[1]] then Log("XP-Hook %s aktiv", D[1]) end
        end
    end
end

-- Gast: Meldung an den Host mit eigener Ratenbremse (Mindestabstand der Quelle)
function W.XpSend(K, Data, Now)
    local Cfg = W.XP_SRC[K]
    if Now - (W.XpSentAt[K] or -1e9) < Cfg.Gap then return end
    W.XpSentAt[K] = Now
    Net.Send("w_xp", K .. "|" .. Data, nil, 1)
end

-- w_xp-Nutzdaten einer Quellen-Aufzeichnung: "craft" -> "<Widget-Klasse>|<Anzahl>", "book" -> ItemId bzw. "1"
function W.XpData(E)
    if E.K == "craft" then return string.format("%s|%d", tostring(E.Cls), math.floor(tonumber(E.N) or 1)) end
    return E.K == "book" and E.Id and W.XP_BOOK[E.Id] and E.Id or "1"
end

-- Gast (0,25 s): Quellen-Aufzeichnungen mit AddXP-Aufzeichnungen paaren (Buch: gleicher Frame, Crafting: +0,2 s);
-- ohne AddXP-Hook (world_xp_addhook=0, Standard) direkt melden
function W.XpClient(Now)
    if Net.Side ~= "client" then W.XpOn = false return end
    W.XpOn = On("world_xp") and Net.Has("wxp")
    W.XpAddOn = W.XpOn and Core.Flag("world_xp_addhook", false) and W.XpHooks.add ~= nil
    if not W.XpOn then
        if #W.XpEv > 0 or #W.XpAdd > 0 then W.XpEv, W.XpAdd = {}, {} end
        return
    end
    local Keep = {}
    for _, E in ipairs(W.XpEv) do
        local Done = false
        if not W.XpAddOn then
            -- CORE-18 (world_xp_addhook=0): ohne AddXP-Hook direkt melden. Der Host prueft selbst (Crafting: gesehener
            -- SERVER_RequestCraftItem, Buch: Abnahme im Server-Inventar) und berechnet den Betrag aus der Server-Kopie.
            W.XpSend(E.K, W.XpData(E), Now)
            Done = true
        else
            -- 5.6: AddXP folgt im selben Aufruf (kein Delay mehr) -> X.At >= E.At
            for I, X in ipairs(W.XpAdd) do
                if X.At >= E.At - 0.05 and X.At - E.At < 2 and (tonumber(X.V) or 0) > 0 then
                    table.remove(W.XpAdd, I)
                    W.XpSend(E.K, W.XpData(E), Now)
                    Done = true
                    break
                end
            end
            -- keine XP binnen 2 s (z. B. Zeitschrift ohne Wirkung): nichts melden
            if not Done and Now - E.At > 2 then Done = true end
        end
        if not Done then Keep[#Keep + 1] = E end
    end
    W.XpEv = Keep
    -- AddXP ohne Quelle (POI geht ueber w_poi) nach 3 s verwerfen
    local Add = {}
    for _, X in ipairs(W.XpAdd) do
        if Now - X.At < 3 then Add[#Add + 1] = X end
    end
    W.XpAdd = Add
end

-- Host: Ratenbremse je GuestId und Quelle
function W.XpRate(G, K, Now)
    local Cfg = W.XP_SRC[K]
    local T = W.XpRateT[G.GuestId] or {}
    W.XpRateT[G.GuestId] = T
    local R = T[K] or { Last = -1e9, Win = Now, N = 0 }
    T[K] = R
    if Now - R.Win >= 60 then R.Win, R.N = Now, 0 end
    if Now - R.Last < Cfg.Gap or R.N >= Cfg.Max then
        if Now >= (R.LogAt or 0) then
            R.LogAt = Now + 30
            Log("XP von %s verworfen: %s (Ratenbremse)", G.GuestId, K)
        end
        return false
    end
    R.Last, R.N = Now, R.N + 1
    return true
end

function W.XpLC(G)
    local PC = Net.PC(G)
    return PC and Try(function() local C = PC.LevellingComponent if A.IsAlive(C) then return C end end)
end

function W.XpLevel(LC) return math.max(1, tonumber(Try(function() return LC.CurrentLevel end)) or 1) end

function W.XpMul(LC) return tonumber(Try(function() return LC.MultiplyValue end)) or 1 end

-- Host: AddXP(Delta, false, {}) auf der Server-Kopie (= BufferXP += Delta * Schwierigkeit, wie im Spiel). Timer
-- Event_LevelBarTimer einmal je Kopie (zieht CurrentXP/LevelUp nach, wie ls_combat; K2_SetTimerDelegate ersetzt).
function W.XpGrant(G, LC, Src, Delta)
    if not (Delta > 0) then return end
    local TK = G.Key .. "#" .. tostring(W.Gen)
    if not W.XpTimer[TK] then
        W.XpTimer[TK] = true
        pcall(function() LC:Event_LevelBarTimer() end)
    end
    if pcall(function() LC:AddXP(Delta, false, {}) end) then
        Log("XP von %s uebernommen: %s +%.0f", G.GuestId or G.Key, Src, Delta)
    else
        Log("XP von %s fehlgeschlagen: %s +%.0f", G.GuestId or G.Key, Src, Delta)
    end
end

-- Host: w_xp pruefen und buchen (Betrag aus der Server-Kopie, nie vom Gast)
function W.XpHost(G, K, Rest, Now)
    local Pawn, PC = W.GuestPawn(G)
    if not Pawn or not PC then return end
    if K == "craft" then
        local Cls, N = Rest:match("^([%w_]+)|(%d+)$")
        if not Cls or not W.XP_CRAFT[Cls] then return Net.SecWarn(G, G.Key, "w_xp_craft") end
        if not W.XpRate(G, K, Now) then return end
        if not W.XpLC(G) then return end
        -- 5.6: alle vier Widgets Stufe*CountIndex*4 je Klick (CountIndex Requests, W.XpCraftTick).
        -- XP = Stufe*4*gesehene Requests (hoechstens N, world_xp_craftcount)
        N = math.max(1, math.min(20, tonumber(N) or 1))
        -- Buchung erst, wenn der Host den SERVER_RequestCraftItem(Drop) dieses Gasts gesehen hat (W.XpCraftTick)
        if not W.XpCraftCheck() then return W.XpCraftApply(G, Cls, N) end
        W.XpCraftQ = W.XpCraftQ or {}
        if #W.XpCraftQ >= 40 then return end
        W.XpCraftQ[#W.XpCraftQ + 1] = { Key = G.Key, Cls = Cls, N = N, T0 = Now }
        return
    elseif K == "book" then
        -- "book|<ItemId>" (Runde 8) oder alt "book|1" (nur Stufen-XP)
        local B = W.XP_BOOK[Rest]
        if Rest ~= "1" and not B then return Net.SecWarn(G, G.Key, "w_xp_book") end
        if not W.XpRate(G, K, Now) then return end
        if not W.XpLC(G) then return end
        -- Buchung erst, wenn das Buch im Server-Inventar des Gasts abgenommen wurde (W.XpBookTick)
        local Pat = B and ("/da_" .. Rest:lower() .. "%.") or "/other/[bm]%a+/da_"
        if W.XpBookCons(G, Pat) == nil then return W.XpBookApply(G, Rest) end
        W.XpBookQ = W.XpBookQ or {}
        if #W.XpBookQ >= 40 then return end
        W.XpBookQ[#W.XpBookQ + 1] = { Key = G.Key, Rest = Rest, Pat = Pat, T0 = Now }
        return
    elseif K == "fish" then
        local R = W.XP_FISH[Rest]
        if not R then return Net.SecWarn(G, G.Key, "w_xp_fish") end
        if not W.XpRate(G, K, Now) then return end
        local PS = Try(function() local C = PC.PassiveSkillsComponent if A.IsAlive(C) then return C end end)
        if not PS then return end
        local V = R[1] + math.random() * (R[2] - R[1])
        if pcall(function() PS:AddXP_Fishing(V) end) then
            Log("XP von %s uebernommen: %s +%.0f", G.GuestId, "Angeln (Fertigkeit)", V)
        end
    end
end

-- Host: Crafting-Nachweis. Alle vier Crafting-Widgets rufen beim Klick (Button_81) PlayerMPComp->
-- SERVER_RequestCraftItem bzw. SERVER_RequestCraftItemDrop (Inventar voll) an der Jig-Komponente der eigenen Figur
-- (5.6 BP_JigComponent_C, Pawn-Property heisst weiter BP_JigMultiplayer; W_PlayerCraftingUI/Werkbank/Kochen @0242/@09db,
-- Bau-Werkbank @0361/@0ac6), CountIndex-mal, AddXP danach im selben Aufruf. Pre-Hook auf dem Host (wie ls_build
-- SERVER_ForwardInteract) merkt nur Figurname + Zeit; jede Meldung verbraucht mindestens einen (bis N) gesehenen Request
-- derselben Figur (hoechstens W.XP_CRAFT_PAST s alt), sonst wartet sie W.XP_CRAFT_WAIT s und wird verworfen.
-- XP = Stufe*4*gesehene Requests (hoechstens N, world_xp_craftcount).
-- Schalter world_xp_craftcheck=0 oder Hooks fehlen -> altes Verhalten.
W.XP_JIGMP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
W.XP_CREQ = { creq = W.XP_JIGMP .. ":SERVER_RequestCraftItem", creqd = W.XP_JIGMP .. ":SERVER_RequestCraftItemDrop" }
W.XP_CRAFT_WAIT, W.XP_CRAFT_PAST, W.XpCraftReq = 8, 15, {}

-- FGuid (Struktur aus dem Spiel) -> 32 Hex-Zeichen wie ls_inv I.Hex (uid32), nil wenn unlesbar
function W.Hex(G)
    local ok, H = pcall(function()
        return string.format("%08X%08X%08X%08X", math.floor(G.A) & 0xFFFFFFFF, math.floor(G.B) & 0xFFFFFFFF,
            math.floor(G.C) & 0xFFFFFFFF, math.floor(G.D) & 0xFFFFFFFF)
    end)
    return ok and H or nil
end

-- INV-1 (E1): ls_inv nimmt Crafting-Datensaetze (A.Coop.Inv.CraftNote, nur ablegen). Laufzeit-Lookup, nie gecacht.
function W.CraftNoteFn()
    local Inv = A.Coop and A.Coop.Inv
    local Fn = type(Inv) == "table" and Inv.CraftNote or nil
    return type(Fn) == "function" and Fn or nil
end

-- Hook-Koerper (Host, nur Pre): Komponenten-Pfad lesen, Figur = Outer der Komponente, nur Tabellen schreiben.
-- INV-1: dazu die RPC-Parameter (CompRef, CraftIndex, ConsumeUIDs) als Datensatz { Pawn, CompPath, Idx, Uids, Drop,
-- At } an ls_inv (I.CraftGuard/I.CraftCnt pruefen im Ledger-Takt). Nur Felder lesen, keine UFunctions.
function W.HCraftReq(Ctx, CompRef, CraftIndex, ConsumeUIDs, Drop)
    local Full = Try(function() return Ctx:get():GetFullName() end)
    local Pawn = Full and Full:match("([^%.:%s]+)[%.:][^%.:%s]+$")
    if not Pawn then return end
    local Now = os.clock()
    if #W.XpCraftReq >= 60 then table.remove(W.XpCraftReq, 1) end
    W.XpCraftReq[#W.XpCraftReq + 1] = { P = Pawn, At = Now }
    local Note = not Core.Down.w_craftnote and W.CraftNoteFn()
    if not Note then return end
    local Rec = { Pawn = Pawn, Drop = Drop == true, At = Now, Uids = {} }
    pcall(function()
        local C = CompRef:get()
        if C and C:IsValid() then Rec.CompPath = W.Path(C) end
    end)
    Rec.Idx = Try(function() return math.floor(CraftIndex:get()) end)
    pcall(function()
        ConsumeUIDs:get():ForEach(function(_, E)
            if #Rec.Uids < 32 then Rec.Uids[#Rec.Uids + 1] = W.Hex(E:get()) end
        end)
    end)
    local ok, err = pcall(Note, Pawn, Rec)
    if not ok then Core.Fail("w_craftnote", err) end
end

-- Host (10 s, W.TryHooks): Request-Hooks setzen, sobald die Klasse geladen ist; neu hooken nach Neuladen.
-- INV-1/INV-2: auch ohne world_xp_craftcheck, sobald ls_inv die Datensaetze nimmt (E1). Drop = SERVER_RequestCraftItemDrop.
function W.XpReqHookTry()
    if not ((On("world_xp") and On("world_xp_craftcheck")) or W.CraftNoteFn()) then return end
    for Id, Path in pairs(W.XP_CREQ) do
        W.HookStale(W.Hooks, Id, Path)
        if not W.Hooks[Id] and W.Obj(W.XP_JIGMP) then
            local Drop = Id == "creqd"
            W.Hooks[Id] = W.Hook(Path, function(Ctx, CompRef, CraftIndex, ConsumeUIDs)
                W.HCraftReq(Ctx, CompRef, CraftIndex, ConsumeUIDs, Drop)
            end)
            if W.Hooks[Id] then Log("Crafting-Nachweis-Hook %s aktiv", Id) end
        end
    end
end

-- Nachweis pruefbar: Schalter an und beide Request-Hooks gesetzt
function W.XpCraftCheck()
    return On("world_xp_craftcheck") and W.Hooks.creq ~= nil and W.Hooks.creqd ~= nil
end

function W.XpCraftApply(G, Cls, N)
    local LC = W.XpLC(G)
    if not LC then return end
    return W.XpGrant(G, LC, "Crafting " .. Cls, W.XpLevel(LC) * W.XP_CRAFT_MUL * N)
end

-- Host (0,25 s): vorgemerkte Crafting-Meldungen gegen gesehene Requests der Figur des Gasts buchen
function W.XpCraftTick()
    if not W.XpCraftQ or #W.XpCraftQ == 0 then return end
    local Now, Keep, Q = os.clock(), {}, W.XpCraftQ
    W.XpCraftQ = Keep
    for _, J in ipairs(Q) do
        local G = Net.Guests[J.Key]
        local Pawn = G and W.GuestPawn(G)
        local Name = Pawn and Try(function() return W.Name(Pawn) end)
        local Hit, Used = nil, 0
        if not W.XpCraftCheck() then
            Hit = true
        elseif Name then
            -- 5.6: ein Klick = CountIndex Requests -> bis zu J.N passende verbrauchen (mindestens einer noetig)
            local I = 1
            while I <= #W.XpCraftReq and Used < (J.N or 1) do
                local R = W.XpCraftReq[I]
                if R.P == Name and R.At >= J.T0 - W.XP_CRAFT_PAST then
                    table.remove(W.XpCraftReq, I)
                    Hit, Used = true, Used + 1
                else
                    I = I + 1
                end
            end
        end
        if Hit and G then
            -- Closeout 2 (world_xp_craftcount): Menge nur aus gesehenen Requests (hoechstens Gast-Angabe N), nicht aus der
            -- Gast-Angabe allein (sonst 1 Request + 'craft|Cls|20' = 20-fache XP). Pruefung aus -> Used = 0 -> alte Menge
            local N = (Used > 0 and On("world_xp_craftcount")) and Used or J.N
            local ok, err = pcall(W.XpCraftApply, G, J.Cls, N)
            if not ok then Core.Fail("w_xp", err) end
        elseif G and Now - J.T0 < W.XP_CRAFT_WAIT then
            Keep[#Keep + 1] = J
        elseif G then
            Log("Crafting-XP von %s verworfen: %s ohne SERVER_RequestCraftItem", G.GuestId or J.Key, J.Cls)
        end
    end
end

-- Host: Buch-Abnahme im Server-Inventar des Gasts (ls_inv Ledger, A.Coop.Inv.LastConsume; ContextReadBook verbraucht
-- per JigComp_CallServerConsumeRequest vor AddXP @05d8/@0fa9). nil = nicht pruefbar (ls_inv/Ledger aus, Schalter
-- world_xp_bookcheck=0) -> altes Verhalten; false = keine Abnahme bekannt; Zahl = os.clock der letzten Abnahme
W.XP_BOOK_WAIT, W.XP_BOOK_PAST, W.XpBookUsed = 8, 15, {}
function W.XpBookCons(G, Pat)
    local Inv = A.Coop and A.Coop.Inv
    local Fn = type(Inv) == "table" and Inv.LastConsume or nil
    if not On("world_xp_bookcheck") or type(Fn) ~= "function" then return nil end
    -- nur Host-Schalter (Ledger laeuft unabhaengig von den Caps des Gasts); Gast-Caps sind vom Gast gemeldet
    if not (Core.Flag("inv_v2a", true) or Core.Flag("inv_v2b", true)) then return nil end
    if not (G.Epoch and G.Ready) then return false end
    local ok, T = pcall(Fn, G.Key, Pat)
    if not ok then return nil end
    return type(T) == "number" and T or false
end

-- Host (0,25 s): vorgemerkte Buch-Meldungen buchen, sobald eine noch nicht verbuchte Abnahme passt (hoechstens
-- W.XP_BOOK_PAST s vor der Meldung); ohne Abnahme binnen W.XP_BOOK_WAIT s verwerfen
function W.XpBookTick()
    if not W.XpBookQ or #W.XpBookQ == 0 then return end
    local Now, Keep, Q = os.clock(), {}, W.XpBookQ
    W.XpBookQ = Keep
    for _, J in ipairs(Q) do
        local G = Net.Guests[J.Key]
        if G then
            local T = W.XpBookCons(G, J.Pat)
            -- Sperre je Abnahme (Gast + Zeitpunkt), nicht je Muster: "book|<Id>" und "book|1" treffen dieselbe Abnahme
            local U = W.XpBookUsed[J.Key]
            if not U then U = {} W.XpBookUsed[J.Key] = U end
            if T == nil or (T and not U[T] and T >= J.T0 - W.XP_BOOK_PAST) then
                if T then
                    for Tu, At in pairs(U) do if Now - At > 120 then U[Tu] = nil end end
                    U[T] = Now
                end
                local ok, err = pcall(W.XpBookApply, G, J.Rest)
                if not ok then Core.Fail("w_xp", err) end
            elseif Now - J.T0 < W.XP_BOOK_WAIT then
                Keep[#Keep + 1] = J
            else
                Log("Buch-XP von %s verworfen: %s ohne Abnahme im Server-Inventar", G.GuestId or J.Key, J.Rest)
            end
        end
    end
end

-- Host: Fertigkeits- und Stufen-XP buchen wie ContextReadBook 5.6 (Buch 250 + 75; Zeitschrift: Multiplikator neu -> 75,
-- schon aktiv -> Fertigkeit 125 + 25; Used? der Server-Kopie entscheidet)
function W.XpBookApply(G, Rest)
    local B = W.XP_BOOK[Rest]
    local Pawn, PC = W.GuestPawn(G)
    local LC = Pawn and PC and W.XpLC(G)
    if not LC then return end
    local Lvl = 75
    if B then
        local PS = Try(function() local C = PC.PassiveSkillsComponent if A.IsAlive(C) then return C end end)
        if not PS then return end
        local Who = G.GuestId or G.Key
        local Skill = 0
        if not B[2] then
            Skill = 250
        else
            local Flag = B[1] .. "MultiplierUsed?"
            if Try(function() return PS[Flag] end) == false then
                pcall(function() PS["XPMultiplier_" .. B[1]](PS, {}) end)
                if Try(function() return PS[Flag] end) ~= true then
                    return Log("Zeitschrift %s von %s: Multiplikator nicht gesetzt", Rest, Who)
                end
                Log("Zeitschrift %s von %s: Multiplikator %s aktiv", Rest, Who, B[1])
            else
                Skill, Lvl = 125, 25                      -- Multiplikator schon aktiv (@130e/@14b8)
            end
        end
        if Skill > 0 then
            if not pcall(function() PS["AddXP_" .. B[1]](PS, Skill) end) then
                return Log("XP von %s fehlgeschlagen: %s (Fertigkeit)", Who, Rest)
            end
            Log("XP von %s uebernommen: %s (Fertigkeit) +%d", Who, Rest, Skill)
        end
    end
    return W.XpGrant(G, LC, B and Rest or "Buch", W.XpLevel(LC) * Lvl * W.XpMul(LC))
end

-- Angeln (UE 5.6, Host). Hook-Koerper (nur Pre, nur Felder lesen + Tabellen schreiben): Svr_CatchFish eines Gasts und
-- das synchron folgende AddXP_Fishing(4-6) aus MC_CatchFish (geht beim Host an GetPlayerController(0) = Geist)
function W.HFishSvr(Ctx)
    if not W.FishOn or #W.FishSvr >= 20 then return end
    local P = W.HPath(Ctx)
    if P then W.FishSvr[#W.FishSvr + 1] = { Path = P, At = os.clock() } end
end

function W.HFishAdd(Ctx, V)
    if not W.FishOn or W.FishSelf or #W.FishAdd >= 20 then return end
    local N = Try(function() return V:get() end)
    if type(N) ~= "number" or N < W.XP_FISH_MIN - 0.01 or N > W.XP_FISH_MAX + 0.01 then return end
    W.FishAdd[#W.FishAdd + 1] = { At = os.clock(), V = N, PS = W.HPath(Ctx) }
end

-- Host (10 s, W.TryHooks): beide Hooks, sobald die Klassen geladen sind
function W.XpFishHookTry()
    if not (On("world_xp") and On("world_xp_fish")) then return end
    for Id, D in pairs({ fsvr = { W.XP_FISH_SVR, W.HFishSvr }, fadd = { W.XP_FISH_ADD, W.HFishAdd } }) do
        W.HookStale(W.Hooks, Id, D[1])
        if not W.Hooks[Id] and W.Obj(D[1]) then
            W.Hooks[Id] = W.Hook(D[1], D[2])
            if W.Hooks[Id] then Log("Angel-XP-Hook %s aktiv", Id) end
        end
    end
end

-- Host: Svr_CatchFish-Aufzeichnung + AddXP_Fishing -> gleicher Betrag auf die Server-Kopie des Gasts (Besitzer der
-- FishingComponent). Ohne AddXP (kein Koeder, AbleToCatchFish? false, WaterActor fehlt) gibt es auch keine XP.
-- Gast zu einer Svr_CatchFish-Aufzeichnung (Besitzer der FishingComponent = Gast-Figur); Key wird gemerkt
function W.FishGuest(R)
    if R.GKey then return Net.Guests[R.GKey] end
    local Comp = W.Obj(R.Path)
    local Owner = Comp and Try(function() return Comp:GetOwner() end)
    local OA = Alive(Owner) and W.Addr(Owner)
    if not OA then return nil end
    local G
    Net.ForEachGuest(function(P) if not G and P.Epoch and W.Addr((W.GuestPawn(P))) == OA then G = P end end)
    if G then R.GKey = G.Key end
    return G
end

-- INV-10 (E3): jeden Svr_CatchFish eines Gasts an ls_inv melden (Fisch-Nachweis fuer I.Decide, inv_fish_proof)
function W.FishNote(R)
    local Inv = A.Coop and A.Coop.Inv
    local Fn = type(Inv) == "table" and Inv.FishNote or nil
    if type(Fn) ~= "function" then return end
    local G = W.FishGuest(R)
    if G then Fn(G.Key) end
end

-- INV-10 (E4): ls_inv darf rohe Fische an Svr_CatchFish-Meldungen binden, solange der Hook lebt und beide Schalter an
-- sind (Host-Simulation aus, unverbuchte Faenge werden gebucht). Faellt die Aufgabe aus, setzt w_caps es zurueck.
function W.FishProofSet()
    local World = A.Coop.World
    if type(World) ~= "table" then return end
    local Proof = (W.FishOn and W.Hooks.fsvr ~= nil and On("world_xp_fishsvr") and On("world_fish_nohostsim")) and true or false
    if World.FishProof ~= Proof then
        World.FishProof = Proof
        Log("Fisch-Nachweis fuer ls_inv: %s", Proof and "an" or "aus")
    end
end

function W.FishGrant(R, X, Now)
    local G = W.FishGuest(R)
    if not G or not G.GuestId then return end
    local PC = Net.PC(G)
    local PS = PC and Try(function() local C = PC.PassiveSkillsComponent if A.IsAlive(C) then return C end end)
    if not PS then return end
    -- schon an die Server-Kopie des Gasts gegangen (z. B. Geist-Umleitung der DLL): nicht doppelt
    if X.PS and X.PS == Try(function() return W.Path(PS) end) then return end
    if not W.XpRate(G, "fish", Now) then return end
    W.FishSelf = true
    local ok = pcall(function() PS:AddXP_Fishing(X.V) end)
    W.FishSelf = false
    if ok then Log("XP von %s uebernommen: %s +%.1f", G.GuestId, "Angeln (Fertigkeit)", X.V) end
end

-- Host (0,25 s): Aufzeichnungen paaren (AddXP folgt synchron, <= 1 s); Svr_CatchFish ohne AddXP nach 1,5 s als Fang
-- buchen (world_xp_fishsvr), sonst verwerfen
function W.FishHostTick()
    W.FishOn = Net.Side == "host" and On("world_xp") and On("world_xp_fish")
    W.FishProofSet()
    if #W.FishSvr == 0 and #W.FishAdd == 0 then return end
    local S, Ad, Now = W.FishSvr, W.FishAdd, os.clock()
    W.FishSvr, W.FishAdd = {}, {}
    if not W.FishOn then return end
    for _, R in ipairs(S) do
        if not R.Noted then
            R.Noted = true
            local okN, errN = pcall(W.FishNote, R)
            if not okN then Core.Fail("w_fish_note", errN) end
        end
        local Hit
        for I, X in ipairs(Ad) do
            if X.At >= R.At - 0.05 and X.At - R.At < 1 then Hit = table.remove(Ad, I) break end
        end
        if Hit then
            local ok, err = pcall(W.FishGrant, R, Hit, Now)
            if not ok then Core.Fail("w_xp_fish", err) end
        elseif Now - R.At < 1.5 then
            W.FishSvr[#W.FishSvr + 1] = R
        elseif On("world_xp_fishsvr") then
            -- INV-10/WORLD-6: die Host-Simulation fing nichts (Kamera/Zufall des Hosts, mit world_fish_nohostsim ganz
            -- aus). Der Gast ruft Svr_CatchFish nur mit eigenem AbleToCatchFish? (@1a6e) -> Fang wie SP buchen (4-6, @1438)
            local ok, err = pcall(W.FishGrant, R, { V = W.XP_FISH_MIN + math.random() * (W.XP_FISH_MAX - W.XP_FISH_MIN) }, Now)
            if not ok then Core.Fail("w_xp_fish", err) end
        end
    end
    for _, X in ipairs(Ad) do if Now - X.At < 1.5 then W.FishAdd[#W.FishAdd + 1] = X end end
end

-- ------------------------------------------------------------------------------------------- Quests (quest_v1 + quest_v2)
-- Runde 7 (findings\quests_r7.md). Gast-Quests liegen nur am Host an Net.PC(G).NarrativeComponent (Narrative repliziert
-- PendingUpdateList -> Journal/Marker beim Gast). GetNarrativeComponent loest nativ Spieler 0 auf, auf dem dedizierten
-- Host also den Geist: was dort landet, wird genau einem Spieler zugeordnet oder verworfen (Log), nie an "alle".
--   quest_area/quest_start  Startquests je Gast, erst nach dem Laden seines Quest-Saves
--   quest_ui       G  eigenes Dialog-/Quest-HUD (wie BP_PlayerController.ReceivePossess, 5.6 @1f24, nur am Server)
--   quest_talk     G->H q_talk: Dialog am Gast-NC, InteractWithActor erst danach (SP-Reihenfolge QuestGiver @0546/@046a)
--   quest_dialog   H  Netz: Geist-Dialog ohne Gespraech nach 2 s beenden (Gaeste ohne qst2: alter Weg nach Naehe)
--   quest_task     H  N8-Gutschrift an den Taeter (Gespraech, Owner-Kette, letzter Treffer, einziger Gast <= 50 m)
--   quest_assist   H  Kill zusaetzlich fuer Gaeste <= 50 m mit gleichem offenem Task (5.6: Kills laufen nicht mehr
--                     ueber CompleteNarrativeDataTask, sondern BP_Quest_Spawner_AI.AIDeath -> praktisch nur noch 5.3)
--   quest_gtask    G->H q_task: gastlokale Aufrufe (5.3 BP_GuaranteedSpawner @08be; 5.6: Kisten ueber world_crate_prog)
--   quest_ghost    H  Geist-Quests vergessen, Uebergabe nur bei eindeutigem Gespraech (<= 10 s)
--   quest_laptop   H  Quest_Event_RandomBounty (5.3 Event_RandomLaptopQuest) aus, Lua waehlt je Spieler (CallRandomEvent)
--   quest_forget   G->H q_forget: Journal "Vergessen" (@1a0b wirkt ohne Autoritaet nur lokal)
--   quest_xppatch  G  XP-Belohnungs-Event lokal aus (Host gibt sie dem Abgebenden); quest_rewardpatch (Item) 5.6 entfallen
--   quest_refire   H  XP-Belohnungen mit bRefireOnLoad: beim Laden eines Gast-Saves aus, fremde nachreichen
--   quest_spawnfix G  lokale Zwillinge replizierter Quest-Actors weg (5.6: ohne Spawn-Event-Hooks wirkungslos)
--   quest_dedupe   H  5.6 deaktiviert (Event_SpawnActor/SpawnPrefab/SpawnAIHumanSpawner/RemoveActor entfernt)
--   quest_marker   H  replizierte Host-Marker weg, sobald alle Gaeste eigene Marker erzeugen (5.6 nur mit quest_marker56)
--   quest_save     H  NetTest_Guests/<GuestId>_q, Aenderung -> spaetestens 2 s

W.QC = {
    UI_CLASS = "/Game/Quests/UI/BP_CustomNarrativeDefaultUI.BP_CustomNarrativeDefaultUI_C",
    WBL = "/Script/UMG.Default__WidgetBlueprintLibrary",
    -- 5.6: Event_RewardPlayerXP -> Quest_Event_RewardPlayerXP (Bytecode identisch, @0000 LetObj/LocalVariable = 5F00)
    XP_FN = "/Game/Quests/Events/Reward/Quest_Event_RewardPlayerXP.Quest_Event_RewardPlayerXP_C:ExecuteEvent",
    -- 5.6: Event_RandomLaptopQuest -> Quest_Event_RandomBounty (Bytecode identisch bis auf BP_BountyQuestManager, 5F00)
    LAPTOP_FN = "/Game/Quests/Events/Quest_Event_RandomBounty.Quest_Event_RandomBounty_C:ExecuteEvent",
    -- 5.6: Event_SpawnAIHumanSpawner/SpawnActor/SpawnPrefab/RemoveActor entfernt (Quest-Inhalte jetzt ueber platzierte
    -- BP_Quest_Spawner_AI/_Object, Quest_Spawn nativ ausgeloest) -> quest_dedupe und HumanQuest-Spawnfix ohne Einstieg
    HUMAN_FN = nil, SPAWN_FN = nil, PREFAB_FN = nil, REMOVE_FN = nil,
    -- 5.6: Quest_Event_SpawnMarker existiert, ist aber nicht dekodiert -> nur mit quest_marker56=1 (Standard aus)
    MARKER_FN = "/Game/Quests/Events/Quest_Event_SpawnMarker.Quest_Event_SpawnMarker_C:ExecuteEvent",
    FORGET_FN = "/Game/UI/Widgets/Journal/Journal_QuestsUI.Journal_QuestsUI_C:ForgetQuest",
    TALK_FN = { "/Game/Quests/Blueprints/NPCs/BP_QuestGiver.BP_QuestGiver_C:OnExecuteInteract",
                "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C:OnExecuteInteract",
                "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C:OnExecuteInteract" },
    HUMAN = nil,        -- 5.6: BP_AISpawningVolume_HumanQuest_C entfernt
    MARKER = "BP_QuestMarker_C",
    -- Gespraechspartner (Klasse oder Oberklasse): QuestGiver laeuft ueber OnServerExecuteInteract (H), Haendler lokal (G)
    TALK = { BP_QuestGiver_C = "giver", BP_TraderMaster_C = "trader", BP_MasterTrader_C = "wander" },
    -- Quest-Kisten (Hold-Timer -> OpenContainer). 5.3: CompleteNarrativeDataTask @08be (q_task); 5.6: stattdessen
    -- BP_QuestTaskComponent.AddProgress.Broadcast(0) @0665 (Host-Weg in W.CrateHostOne, world_crate_prog)
    CRATE = { BP_GuaranteedSpawner_C = true, BP_GuaranteedSpawner_Classified_C = true },
    NEAR = 5000,        -- 50 m: einziger Gast / Mithilfe
    TALK_DIST = 700,    -- Gastfigur <-> NPC (QuestGiver selbst: < 500 @0657)
    LAPTOP_DONE = "Alle Laptop-Quests erledigt. Komm spaeter wieder...",
}

-- Runde-7-Teile: quest_v1 (Hauptschalter) + quest_v2 (Runde 7) + Feinschalter
function W.Q2(Name) return Core.Flag("quest_v2", true) and QOn(Name) end

function W.Short(P) return tostring(P or "?"):match("([^/.]+)$") or tostring(P) end

function W.NC(PC) return Alive(PC) and Try(function() local NC = PC.NarrativeComponent if A.IsAlive(NC) then return NC end end) end

function W.GhostNC() return W.NC(A.LocalPC()) end

W.OwnNC = W.GhostNC     -- Gast: eigener PC

function W.NarrLib() return W.Obj(W.NARRATIVE_LIB) end

-- Dialog beenden. 5.6 (Narrative neu): TryExitDialogue hat einen Parameter (BP: NarrativeComponent->TryExitDialogue(0),
-- Quest_Event_OnInteractNPC @0094); 5.3 ohne -> Rueckfall
function W.ExitDlg(NC)
    if not pcall(function() NC:TryExitDialogue(0) end) then pcall(function() NC:TryExitDialogue() end) end
end

-- Weltwechsel: Quest-Laufzeitstand verwerfen (Hooks, Patches, Warteschlangen je Gast bleiben)
function W.QReset()
    W.Talk, W.TalkQ, W.N8Wait, W.QEv, W.GEv, W.Twins = {}, {}, {}, {}, {}, {}
    W.Holders, W.Known, W.TagCls, W.TagGone, W.Frozen, W.GhostSeen = {}, {}, {}, {}, {}, {}
    W.RefireN, W.RefireAt, W.MarkerRep, W.RwLoad, W.LapSet, W.GTaskDone = nil, nil, nil, nil, nil, nil
end

-- Klassenname und Oberklassen (Unterklassen wie BP_QuestGiver_SettlementOfficer_C)
function W.ClassChain(O)
    local Set, C = {}, Try(function() return O:GetClass() end)
    for _ = 1, 12 do
        if not Alive(C) then break end
        local N = Try(function() return C:GetFName():ToString() end)
        if not N then break end
        Set[N] = true
        C = Try(function() return C:GetSuperStruct() end)
    end
    return Set
end

function W.TalkKind(O)
    local Set = W.ClassChain(O)
    for Cls, Kind in pairs(W.QC.TALK) do
        if Set[Cls] then return Kind end
    end
    return nil
end

-- CORE-14: zulaessige q_talk-Klassen (auch Unterklassen wie BP_QuestGiver_SettlementOfficer_C und die
-- stationaeren Haendler BP_<X>Trader_C, alle Unterklassen von BP_TraderMaster_C). %w+ statt [%w_]+, damit
-- BP_MasterAIController_Trader_C / BP_*TraderSpawner_C nicht passen; W.TalkHost prueft die Klassenkette zusaetzlich.
W.TALK_CLS = { "^BP_QuestGiver[%w_]*_C$", "^BP_TraderMaster_C$", "^BP_MasterTrader_C$", "^BP_%w+Trader_C$" }
function W.TalkClsOk(Cls)
    for _, P in ipairs(W.TALK_CLS) do
        if Cls:match(P) then return true end
    end
    return false
end

function W.QS(G) return W.QState and W.QState[G.Key] end
function W.QLoaded(G) local S = W.QS(G) return S ~= nil and S.Loaded == true end
function W.QDirty(G) local S = W.QS(G) if S then S.Dirty = true end end

-- Host: Narrative-Komponente (Pfad) -> Gast-Tabelle, "local" (eigener PC = Geist) oder nil
function W.NCOwner(Path)
    if not Path then return nil end
    local Ghost = W.GhostNC()
    if Ghost and W.Path(Ghost) == Path then return "local" end
    for _, G in ipairs(W.Guests("qst1")) do
        local NC = W.NC(Net.PC(G))
        if NC and W.Path(NC) == Path then return G end
    end
    return nil
end

-- Genau ein Gast mit Gespraech in den letzten Window s, sonst nil (mehrdeutig = keiner)
function W.TalkGuest(Now, Window)
    local Hit, N = nil, 0
    for Key, T in pairs(W.Talk) do
        if Now - T.At <= Window and Net.Guests[Key] then Hit, N = Net.Guests[Key], N + 1 end
    end
    if N == 1 then return Hit end
    return nil
end

-- Tasks im aktuellen Zustand aller laufenden Quests: Fn(Task, Quest)
function W.QTasks(NC, Fn)
    for _, Q in ipairs(ArrList(Try(function() return NC:GetInProgressQuests() end))) do
        pcall(function()
            if not A.IsAlive(Q) then return end
            local St = Q.CurrentState
            if not A.IsAlive(St) then return end
            St.Branches:ForEach(function(_, B)
                local Br = B:get()
                if A.IsAlive(Br) then
                    Br.QuestTasks:ForEach(function(_, T)
                        local Tk = T:get()
                        if A.IsAlive(Tk) then Fn(Tk, Q) end
                    end)
                end
            end)
        end)
    end
end

-- BPT_CompleteDataTask_C: { Task = Pfad, Arg, Open = noch nicht erfuellt } oder nil
function W.DataTaskOf(Task)
    if not Task:GetClass():GetFName():ToString():find("CompleteDataTask", 1, true) then return nil end
    local DT = Task.DataTask
    if not A.IsAlive(DT) then return nil end
    local Open = (tonumber(Task.CurrentProgress) or 0) < (tonumber(Task.RequiredQuantity) or 1)
    return { Task = W.Path(DT), Arg = Task.Argument:ToString(), Open = Open }
end

-- Aktive Data-Tasks: { [Task|arg] = { Task, Arg, Guests = {[GKey]=true} } } (fuer quest_share)
function W.ActiveTasks(NC, Out, GKey)
    W.QTasks(NC, function(Task)
        local D = W.DataTaskOf(Task)
        if not D then return end
        local Key = D.Task .. "|" .. D.Arg:lower()
        local E = Out[Key] or { Task = D.Task, Arg = D.Arg, Guests = {} }
        E.Guests[GKey] = true
        Out[Key] = E
    end)
end

-- Hat der Spieler diesen Task im aktuellen Zustand? Argumentvergleich wie BPT_CompleteDataTask (StriStri, leer = jedes)
function W.HasTask(NC, TaskPath, Arg, OpenOnly)
    local Hit, Want = false, tostring(Arg or ""):lower()
    W.QTasks(NC, function(Task)
        if Hit then return end
        local D = W.DataTaskOf(Task)
        if not D or D.Task ~= TaskPath or (OpenOnly and not D.Open) then return end
        local TA = D.Arg:lower()
        if TA == "" or TA == Want then Hit = true end
    end)
    return Hit
end

-- Gutschrift an genau einen Gast; vor dem Laden seines Saves in die Warteschlange (<= 60 s, <= 50)
function W.Credit(G, TaskPath, Arg, Qty, Why)
    if not W.QLoaded(G) then
        local Q = W.QQueue[G.Key] or {}
        W.QQueue[G.Key] = Q
        if #Q < 50 then Q[#Q + 1] = { Task = TaskPath, Arg = Arg, Qty = Qty, Why = Why, At = os.clock() } end
        return true
    end
    local NC, Lib, Task = W.NC(Net.PC(G)), W.NarrLib(), W.Obj(TaskPath)
    if not NC or not Lib or not Task then return false end
    local ok, err = pcall(function() Lib:CompleteNarrativeDataTask(NC, Task, Arg, Qty) end)
    if not ok then Core.Fail("quest_task", err) return false end
    W.QDirty(G)
    Log("Quest-Fortschritt %s (%s) +%d fuer Gast %s (%s)", W.Short(TaskPath), Arg, Qty, G.GuestId or "?", Why or "?")
    return true
end

function W.QFlush(G, Now)
    local Q = W.QQueue[G.Key]
    if not Q or not W.QLoaded(G) then return end
    W.QQueue[G.Key] = nil
    for _, C in ipairs(Q) do
        if Now - C.At <= 60 then W.Credit(G, C.Task, C.Arg, C.Qty, (C.Why or "?") .. ", nachgeholt") end
    end
end

-- ------------------------------------------------------------------- Quest-Starts

-- Startquest-Bereiche: Gastfigur in der (gedrehten) Box -> Quest beim Gast starten (erst nach dem Laden)
function W.QuestArea(Now)
    if Net.Side ~= "host" or not QOn("quest_area") then return end
    local Guests = W.Guests("qst1")
    if #Guests == 0 then return end
    W.Each("BP_StartQuestArea_C", function(Area, Path)
        local Box, Quest = Area.Box, Area.Quest
        if not Alive(Box) or not Alive(Quest) then return end
        W.AreaQuests[Quest:GetFullName()] = true
        local C, E = Box:K2_GetComponentLocation(), Box:GetScaledBoxExtent()
        local Yaw = math.rad(Box:K2_GetComponentRotation().Yaw)
        local Cs, Sn = math.cos(-Yaw), math.sin(-Yaw)
        for _, G in ipairs(Guests) do
            local Pawn, PC = W.GuestPawn(G)
            local Key = G.Key .. "|" .. Path
            if Pawn and W.QLoaded(G) and Now >= (W.AreaAt[Key] or 0) then
                local X, Y, Z = W.Loc(Pawn)
                local DX, DY = X - C.X, Y - C.Y
                local LX, LY = DX * Cs - DY * Sn, DX * Sn + DY * Cs
                if math.abs(LX) <= E.X + 50 and math.abs(LY) <= E.Y + 50 and math.abs(Z - C.Z) <= E.Z + 100 then
                    W.AreaAt[Key] = Now + 10
                    local NC = W.NC(PC)
                    if NC and not Try(function() return NC:IsQuestStartedOrFinished(Quest) end, true) then
                        local ok = pcall(function() NC:BeginQuest(Quest, FName("None")) end)
                        if ok then W.QDirty(G) end
                        Log("Startquest %s fuer Gast %s: %s", Quest:GetFName():ToString(), G.GuestId or "?", ok and "gestartet" or "Fehler")
                    end
                end
            end
        end
    end)
end

-- Neuer Gast ohne Quest-Save und ohne Quests: Start-Quest wie im Einzelspieler (nur fuer ihn)
function W.StartQuest(NC, Id)
    if not QOn("quest_start") then return end
    -- Abfrage fehlgeschlagen -> nichts starten (lieber keine als eine doppelte Start-Quest)
    local ok, Prog, Succ = pcall(function() return NC:GetInProgressQuests(), NC:GetSucceededQuests() end)
    if not ok or #ArrList(Prog) + #ArrList(Succ) > 0 then return end
    local Cls = W.Obj(W.START_QUEST)
    if Cls and not Try(function() return NC:IsQuestStartedOrFinished(Cls) end, true) then
        local okB = pcall(function() NC:BeginQuest(Cls, FName("None")) end)
        Log("Start-Quest fuer neuen Gast %s: %s", Id, okB and "gestartet" or "Fehler")
    end
end

-- Neue Quests beim Geist (Spieler 0 des dedizierten Hosts): immer vergessen; Uebergabe nur an den einen Gast mit
-- Gespraech in den letzten 10 s (Folgequest aus einem Geist-Dialog). Startbereichs-/Start-Quests nie uebergeben
-- (quest_area/quest_start geben sie dem richtigen Gast). Schluessel = Instanz, nach ForgetQuest wieder frei.
function W.QuestGhost(Now)
    if Net.Side ~= "host" or not W.Dedicated() or not QOn("quest_ghost") or Now < (W.GhostAt or 0) then return end
    W.GhostAt = Now + 1
    local Ghost = W.GhostNC()
    if not Ghost then return end
    local Forgot = 0
    for _, Q in ipairs(ArrList(Try(function() return Ghost:GetInProgressQuests() end))) do
        local Cls = Alive(Q) and Try(function() return Q:GetClass() end)
        local Key = Cls and Try(function() return Cls:GetFullName() end)
        if Key then
            -- Laptop-Quests waehlt mit aktivem Hook immer Lua je Spieler (W.LaptopPick) -> Geist-Kopie nie uebergeben
            local Plain = W.AreaQuests[Key] or Key:find("Quest_TheSafeZone", 1, true) or (W.QHooks.lap and W.LaptopQuest(Key))
            local Targets = {}
            if not Plain and W.Q2("quest_ghost") then
                Targets = { W.TalkGuest(Now, 10) }
            elseif not Plain then
                -- quest_v2 aus: alter Weg (letzter Redner <= 120 s, sonst alle Gaeste)
                local Last = W.LastTalk and Now - W.LastTalk.At < 120 and Net.Guests[W.LastTalk.Key]
                Targets = (Last and Last.Ready) and { Last } or W.Guests("qst1")
            end
            local To = {}
            for _, G in ipairs(Targets) do
                local NC = W.QLoaded(G) and W.NC(Net.PC(G)) or nil
                if NC and not Try(function() return NC:IsQuestStartedOrFinished(Cls) end, true)
                    and pcall(function() NC:BeginQuest(Cls, FName("None")) end) then
                    W.QDirty(G)
                    To[#To + 1] = G.GuestId or G.Key
                end
            end
            pcall(function() Ghost:ForgetQuest(Cls) end)
            Forgot = Forgot + 1
            Log("Geist-Quest %s vergessen, uebergeben an: %s", Cls:GetFName():ToString(), #To > 0 and table.concat(To, ",") or "-")
        end
    end
    if Forgot > 0 then W.GhostForgot(Now) end
end

-- Host: Laptop-Ereignis (Hook-Aufzeichnung) -> zufaellige Quest aus BP_BountyQuestManager.Quests (5.3:
-- BP_LaptopEventManager), die der Spieler noch nicht hat (wie CallRandomEvent @0056-@01af, in 5.6 unveraendert);
-- bevorzugt keine, die ein anderer Gast gerade spielt (eigene Lager)
function W.LaptopMgr()
    local Mgr = W.First(W.LAPTOP)
    if Mgr then return Mgr end
    Mgr = Try(function() return FindFirstOf(W.LAPTOP) end)
    if Alive(Mgr) then return Mgr end
    return nil
end

-- Gehoert die Quest-Klasse (GetFullName) zur Laptop-Liste? (je Welt einmal gesammelt)
function W.LaptopQuest(Key)
    if not W.LapSet then
        local Mgr = W.LaptopMgr()
        if not Mgr then return false end
        W.LapSet = {}
        for _, Q in ipairs(ArrList(Try(function() return Mgr.Quests end))) do
            local K = Alive(Q) and Try(function() return Q:GetFullName() end)
            if K then W.LapSet[K] = true end
        end
    end
    return W.LapSet[Key] == true
end

function W.LaptopPick(R, Now)
    local Who = W.NCOwner(R.NC)
    local G = type(Who) == "table" and Who or nil
    if Who == "local" and W.Dedicated() then G = W.TalkGuest(Now, 15) end
    local NC = G and W.NC(Net.PC(G)) or nil
    if not NC and Who == "local" and not W.Dedicated() then NC = W.GhostNC() end
    if not NC or (G and not W.QLoaded(G)) then Log("Laptop-Quest: kein Spieler zuzuordnen, verworfen") return end
    local Mgr = W.LaptopMgr()
    if not Mgr then Log("Laptop-Quest: kein %s", W.LAPTOP) return end
    local Busy = {}
    for _, O in ipairs(W.Guests("qst1")) do
        local ONC = O ~= G and W.NC(Net.PC(O)) or nil
        for _, Q in ipairs(ONC and ArrList(Try(function() return ONC:GetInProgressQuests() end)) or {}) do
            local C = Alive(Q) and Try(function() return Q:GetClass():GetFullName() end)
            if C then Busy[C] = true end
        end
    end
    local Free, Spare = {}, {}
    for _, Q in ipairs(ArrList(Try(function() return Mgr.Quests end))) do
        if Alive(Q) and not Try(function() return NC:IsQuestStartedOrFinished(Q) end, true) then
            if Busy[Try(function() return Q:GetFullName() end, "?")] then Spare[#Spare + 1] = Q else Free[#Free + 1] = Q end
        end
    end
    local Pool = #Free > 0 and Free or Spare
    local Who2 = G and (G.GuestId or G.Key) or "Host"
    if #Pool == 0 then
        if G then Net.Send("q_note", "laptop_done", G, 1) end
        Log("Laptop-Quest: alle erledigt fuer %s", Who2)
        -- WORLD-1: SP gibt den Laptop dann zurueck (@0280-@0325), fuer Scan und Dialog
        -- Review 2 (inv_cons_open): Abnahme bei offener Kiste/Haendler (R.NoRefund) kann ein in die Kiste verschobener
        -- Laptop sein -> kein Ersatz-Laptop. R.Proven = Ledger-Abnahme belegt (W.LapRefund, quest_lap_proven).
        if G and W.Q2("quest_laptopscan") and not R.NoRefund then
            local ok, err = pcall(W.LapRefund, G, Now, R.Proven == true)
            if not ok then Core.Fail("quest_laptopscan", err) end
        elseif G and R.NoRefund then
            Log("Laptop-Rueckgabe an Gast %s entfaellt: Abnahme bei offener Kiste/Haendler", Who2)
        end
        return
    end
    local Q = Pool[math.random(#Pool)]
    local ok, err = pcall(function() NC:BeginQuest(Q, FName("None")) end)
    if not ok then Core.Fail("quest_laptop", err) return end
    if G then W.QDirty(G) end
    Log("Laptop-Quest %s fuer %s gestartet", Try(function() return Q:GetFName():ToString() end, "?"), Who2)
end

-- ------------------------------------------------------------------- Gespraeche (quest_talk / quest_dialog)

-- Host: NPC zu einer Gast-Meldung (Map-Actor ueber FName <= 15 m, sonst Klasse + Position <= 500 uu; der wandernde
-- Haendler steht beim Gast schon @1395, beim Host laeuft er bis zum q_talk weiter)
function W.FindNPC(Cls, Name, X, Y, Z)
    local Best, BestD = nil, 500 ^ 2
    for _, O in ipairs(FindAllOf(Cls) or {}) do
        if A.IsAlive(O) then
            local D = W.Dist2(X, Y, Z, W.Loc(O))
            if Name ~= "-" and W.Name(O) == Name and D <= 1500 ^ 2 then return O end
            if D < BestD then Best, BestD = O, D end
        end
    end
    return Best
end

-- Host: Gespraech eines Gasts ausfuehren. Rueckgabe "wait" = spaeter erneut (Quest-Save noch nicht geladen)
function W.TalkHost(G, R, Now)
    local Pawn, PC = W.GuestPawn(G)
    if not Pawn then return end
    if not W.QLoaded(G) then return "wait" end
    local NPC = W.FindNPC(R.Cls, R.Name, R.X, R.Y, R.Z)
    if not NPC then return W.LogOnce("tk" .. R.Cls .. R.Name, "Gespraech: %s (%s) beim Host nicht gefunden", R.Cls, R.Name) end
    local Kind = W.TalkKind(NPC)
    if not Kind then return Net.SecWarn(G, G.Key, "q_talk_cls") end
    if W.Dist2(R.X, R.Y, R.Z, W.Loc(Pawn)) > (W.QC.TALK_DIST * 2) ^ 2 then return Net.SecWarn(G, G.Key, "q_talk_dist") end
    local NX, NY, NZ = W.Loc(NPC)
    if W.Dist2(NX, NY, NZ, W.Loc(Pawn)) > W.QC.TALK_DIST ^ 2 then return Net.SecWarn(G, G.Key, "q_talk_dist") end
    local NC = W.NC(PC)
    local Dlg = Try(function() local D = NPC.Dialogue if A.IsAlive(D) then return D end end)
    if not NC or not Dlg then return end
    local NPCPath = W.Path(NPC)
    W.Talk[G.Key] = { NPC = NPCPath, At = Now, Kind = Kind }
    W.LastTalk = { Key = G.Key, At = Now }
    -- 1. Geist (dedizierter Host) fuehrt keine Gespraeche: QuestGiver-Weg #1 hat ihm den Dialog gegeben
    local Ghost = W.Dedicated() and W.GhostNC()
    if Ghost and Try(function() return Ghost:IsInDialogue() end, false) then W.ExitDlg(Ghost) end
    -- 2. Dialog am Gast-NC (Narrative schickt ClientBeginDialogue an den Besitzer)
    if not Try(function() return NC:IsInDialogue() end, false) then
        local ok, err = pcall(function() NC:BeginDialogue(Dlg, { StartFromID = FName("None"), Priority = -1 }) end)
        if not ok then Core.Fail("quest_talk", err) return end
    end
    -- 3. erst jetzt die gepufferte InteractWithActor-Gutschrift dieses NPC (SP: BeginDialogue vor CompleteNarrativeDataTask)
    W.N8Flush(Now)
    -- 4. wandernder Haendler bleibt stehen wie @1395 (beim Host; der Gast stellt nur seine Kopie wieder her)
    local CM = Kind == "wander" and Try(function() local C = NPC.CharacterMovement if A.IsAlive(C) then return C end end)
    if CM and pcall(function() CM:DisableMovement() end) then
        W.Frozen[NPCPath] = { Key = G.Key, At = Now }
    end
    Log("Gespraech %s mit Gast %s gestartet", W.Name(NPC), G.GuestId or "?")
end

-- Host (0,25 s): Gespraeche abarbeiten (warten bis zu 6 s auf das Laden des Quest-Saves)
function W.TalkQTick(Now)
    if Net.Side ~= "host" or #W.TalkQ == 0 then return end
    local Keep = {}
    for _, R in ipairs(W.TalkQ) do
        local G = Net.Guests[R.Key]
        if G and G.Epoch then
            local ok, Res = pcall(W.TalkHost, G, R, Now)
            if not ok then Core.Fail("quest_talk", Res)
            elseif Res == "wait" and Now - R.At < 6 then Keep[#Keep + 1] = R end
        end
    end
    W.TalkQ = Keep
end

-- Host: angehaltene Haendler wieder laufen lassen (Gast weg, > 8 m entfernt oder 10 min)
function W.FrozenTick(Now)
    for Path, F in pairs(W.Frozen) do
        local G = Net.Guests[F.Key]
        local Pawn = G and W.GuestPawn(G)
        local NPC = W.Obj(Path)
        local Far = not Pawn or not NPC
        if not Far then
            local X, Y, Z = W.Loc(NPC)
            Far = W.Dist2(X, Y, Z, W.Loc(Pawn)) > 800 ^ 2
        end
        if Far or Now - F.At > 600 then
            local CM = NPC and Try(function() local C = NPC.CharacterMovement if A.IsAlive(C) then return C end end)
            if CM then pcall(function() CM:SetMovementMode(1, 0) end) end
            W.Frozen[Path] = nil
        end
    end
end

-- Gast (0,25 s): Interaktion mit QuestGiver/Haendler (Hook OnExecuteInteract, Rueckfall InteractExecutedActor @04c2)
-- -> nach 0,4 s q_talk; Haendler nur, wenn der lokale BeginDialogue (ohne Autoritaet) keinen Dialog ergab
function W.TalkClient(Now)
    if Net.Side ~= "client" or not W.Q2("quest_talk") or not Net.Has("qst2") then W.TalkHit = nil return end
    local Pawn = A.OwnPawn()
    if not Alive(Pawn) then return end
    local Path = W.TalkHit and W.TalkHit.Path
    W.TalkHit = nil
    local Act = Try(function()
        local C = Pawn.BP_JigHelperComp
        local O = A.IsAlive(C) and C.InteractExecutedActor
        if O and A.IsAlive(O) then return O end
    end)
    local Addr = W.Addr(Act)
    if Addr ~= W.TalkLastAddr then
        W.TalkLastAddr = Addr
        if Act and not Path then Path = Try(function() return W.Path(Act) end) end
    end
    if Path and (Path ~= W.TalkSentPath or Now - (W.TalkSentAt or 0) > 2) then
        local NPC = W.Obj(Path)
        local Kind = NPC and W.TalkKind(NPC)
        if Kind then W.TalkPend = { Path = Path, Kind = Kind, Due = Now + 0.4 } end
    end
    local P = W.TalkPend
    if not P or Now < P.Due then return end
    W.TalkPend = nil
    local NPC = W.Obj(P.Path)
    if not NPC then return end
    local NC = W.OwnNC()
    if P.Kind ~= "giver" and NC and Try(function() return NC:IsInDialogue() end, false) then return end
    local X, Y, Z = W.Loc(NPC)
    local Name = W.Runtime(NPC) and "-" or W.Name(NPC)
    local Cls = NPC:GetClass():GetFName():ToString()
    if Net.Send("q_talk", string.format("%s|%s|%.0f|%.0f|%.0f", Cls, Net.Enc(Name), X, Y, Z), nil, 0) then
        W.TalkSentPath, W.TalkSentAt = P.Path, Now
    end
end

-- Netz (Host, 0,5 s): Geist im Dialog. Mit qst2 kommt der Dialog ueber q_talk zum Gast, der Geist wird dort beendet;
-- haengt er > 2 s ohne Gespraech, beenden. Gaeste ohne qst2 (alter Mod): alter Weg, naechster an diesem NPC.
function W.QuestDialog(Now)
    if Net.Side ~= "host" or not W.Dedicated() or not QOn("quest_dialog") or Now < (W.DlgAt or 0) then return end
    W.DlgAt = Now + 0.5
    local Ghost = W.GhostNC()
    if not Ghost or not Try(function() return Ghost:IsInDialogue() end, false) then W.DlgSince = nil return end
    W.DlgSince = W.DlgSince or Now
    if Now - W.DlgSince < 2 then return end
    local Target, DlgClass = W.LegacyDialogTarget(Ghost)
    W.ExitDlg(Ghost)
    W.DlgSince = nil
    if not Target then
        if Now >= (W.DlgLogAt or 0) then W.DlgLogAt = Now + 30 Log("Dialog beim Geist ohne Gespraech beendet") end
        return
    end
    local NC = W.NC(Net.PC(Target))
    if not NC then return end
    local ok, err = pcall(function() NC:BeginDialogue(DlgClass, { StartFromID = FName("None"), Priority = -1 }) end)
    W.LastTalk = { Key = Target.Key, At = Now }
    if ok then Log("Dialog an Gast %s weitergegeben (alter Weg)", Target.GuestId or "?") else Core.Fail("quest_dialog", err) end
end

-- Alter Weg nur fuer Gaeste ohne qst2: naechster solche Gast <= 700 uu am NPC mit der Dialogklasse des Geists
function W.LegacyDialogTarget(Ghost)
    local Old = {}
    for _, G in ipairs(W.Guests("qst1")) do
        if not Net.Has("qst2", G) then Old[#Old + 1] = G end
    end
    if #Old == 0 then return nil end
    local Dlg = Try(function() return Ghost.CurrentDialogue end)
    local Cls = Dlg and Alive(Dlg) and Try(function() return Dlg:GetClass():GetFullName() end)
    if not Cls then return nil end
    local Best, BestD, BestDlg = nil, 700 ^ 2, nil
    for _, Class in ipairs(W.NPCS) do
        W.Each(Class, function(NPC)
            local D = Try(function() return NPC.Dialogue end)
            if not (Alive(D) and Try(function() return D:GetFullName() end) == Cls) then return end
            local X, Y, Z = W.Loc(NPC)
            for _, G in ipairs(Old) do
                local Pawn = W.GuestPawn(G)
                local Dist = Pawn and W.Dist2(X, Y, Z, W.Loc(Pawn))
                if Dist and Dist < BestD then Best, BestD, BestDlg = G, Dist, D end
            end
        end)
    end
    return Best, BestDlg
end

-- Gast: eigenes Dialog-/Quest-HUD (Scanner, 2 s). Wie @1f24 (5.6): Create(PC, Klasse, PC), NarrativeComponent setzen,
-- AddToViewport(0). Nach dem Tod (RemoveAllWidgets @1e3e) ist es nicht mehr im Viewport -> neu (SP: ReceivePossess).
function W.QuestUI(Objs, Now)
    if Net.Side ~= "client" or not W.Q2("quest_ui") or not Net.Has("qst2") or not (Net.Host and Net.Host.Ready) then return end
    local PC, Pawn = A.LocalPC(), A.OwnPawn()
    local NC = W.NC(PC)
    if not NC or not Alive(Pawn) or Try(function() return Pawn["PlayerDead?"] end, false) == true then return end
    local Own = W.Addr(NC)
    for _, O in ipairs(Objs) do
        if W.Addr(Try(function() return O.NarrativeComponent end)) == Own and Try(function() return O:IsInViewport() end, false) then
            return
        end
    end
    if (Now or os.clock()) < (W.UIAt or 0) then return end
    W.UIAt = (Now or os.clock()) + 10
    local Cls = W.Obj(W.QC.UI_CLASS) or Try(function() local C = LoadAsset(W.QC.UI_CLASS) if Alive(C) then return C end end)
    local WBL = W.Obj(W.QC.WBL)
    if not Cls or not WBL then return end
    local ok, err = pcall(function()
        local Wd = WBL:Create(PC, Cls, PC)
        if not A.IsAlive(Wd) then error("Create ohne Ergebnis") end
        Wd.NarrativeComponent = NC
        Wd:AddToViewport(0)
    end)
    if ok then Log("Narrative-UI erzeugt (Dialoge/Quest-HUD)") else Core.Fail("quest_ui", err) end
end

-- ------------------------------------------------------------------- Fortschritt (quest_task / quest_assist / quest_gtask)

-- N8-Ereignis -> Datensatz (Position/Name sofort, der Tote kann bald weg sein)
function W.N8Parse(Ev, GhostPath)
    local function ObjPath(V) return type(V) == "string" and V:match("^%S+ (.+)$") or nil end
    local NCPath, TaskPath = ObjPath(Ev.Args[1]), ObjPath(Ev.Args[2])
    local Arg = type(Ev.Args[3]) == "string" and Ev.Args[3] or nil
    if not NCPath or NCPath ~= GhostPath or not TaskPath or not Arg then return nil end
    local E = { Task = TaskPath, Arg = Arg, Qty = math.max(1, math.floor(tonumber(Ev.Args[4]) or 1)), At = os.clock() }
    local CallerPath = ObjPath(Ev.Caller)
    E.Name = CallerPath and CallerPath:match("([^%.:]+)$")
    local Caller = W.Obj(CallerPath)
    local Actor = Caller and W.ActorOf(Caller)
    if Actor then
        E.Path, E.Name = W.Path(Actor), W.Name(Actor)
        E.X, E.Y, E.Z = W.Loc(Actor)
        E.Kind = W.TalkKind(Actor)
    end
    return E
end

-- Host: Gast zu einem Actor ueber die Owner-Kette (Gastfigur oder Gast-PC; Generator per ls_build, Wurfkoerper)
function W.OwnerGuest(Actor)
    local Map = {}
    for _, G in ipairs(W.Guests("qst1")) do
        local Pawn, PC = W.GuestPawn(G)
        if Pawn then Map[W.Addr(Pawn)] = G end
        if Alive(PC) then Map[W.Addr(PC)] = G end
    end
    local O = Actor
    for _ = 1, 6 do
        if not Alive(O) then return nil end
        local Hit = Map[W.Addr(O)]
        if Hit then return Hit end
        O = Try(function() return O:GetOwner() end)
    end
    return nil
end

-- Letzter Treffer aus ls_combat (Coop.CombatLastHit(FName) -> Gast-Key oder {Key=...}, <= 10 s).
-- ls_combat exportiert CombatLastHit (noch) nicht -> Rueckfall: Modultabelle ls_combat.H.LastHit[FName] = {Key, T}
function W.LastHitGuest(Name)
    if not Name then return nil end
    local F = A.Coop and A.Coop.CombatLastHit
    local K
    if type(F) == "function" then
        K = Try(function() return F(Name) end)
    else
        K = Try(function()
            local Hit = A.Coop.Modules.ls_combat.H.LastHit[Name]
            if type(Hit) == "table" and os.clock() - (tonumber(Hit.T) or -100) <= 10 then return Hit.Key end
        end)
    end
    if type(K) == "table" then K = K.Key end
    local G = K and Net.Guests[K]
    if G and G.Epoch then return G end
    return nil
end

-- Wer hat es getan? 1. Gespraech (QuestGiver, <= 3 s), 2./3. Owner-Kette und letzter Treffer (bei KillNPC zuerst
-- der Treffer: ls_combat setzt Owner von Welt-Actors nach Naehe), 4. genau ein Gast <= 50 m (nur dediziert).
-- Rueckgabe Gast, Grund | nil, "wait" (QuestGiver ohne Gespraech, < 2 s alt) | nil
function W.QOwner(E, Now)
    -- je Gespraech genau eine InteractWithActor-Gutschrift (@046a); zwei Gaeste am selben NPC: zeitlich naechstes, unverbraucht
    local BestK, BestDt
    for Key, T in pairs(W.Talk) do
        if E.Path and T.NPC == E.Path and not T.Used and Net.Guests[Key] then
            local Dt = math.abs(T.At - E.At)
            if Dt <= 3 and (not BestDt or Dt < BestDt) then BestK, BestDt = Key, Dt end
        end
    end
    if BestK then
        W.Talk[BestK].Used = true
        return Net.Guests[BestK], "Gespraech"
    end
    if E.Kind == "giver" and Now - E.At < 2 then return nil, "wait" end
    local Actor = E.Path and W.Obj(E.Path)
    local G, Why
    if E.Task:find("KillNPC", 1, true) then
        G, Why = W.LastHitGuest(E.Name), "letzter Treffer"
        if not G and Actor then G, Why = W.OwnerGuest(Actor), "Besitzer" end
    else
        if Actor then G, Why = W.OwnerGuest(Actor), "Besitzer" end
        if not G then G, Why = W.LastHitGuest(E.Name), "letzter Treffer" end
    end
    if G then return G, Why end
    if not E.X or not W.Dedicated() then return nil end
    local Only, N = nil, 0
    for _, O in ipairs(W.Guests("qst1")) do
        local Pawn = W.GuestPawn(O)
        if Pawn and W.Dist2(E.X, E.Y, E.Z, W.Loc(Pawn)) <= W.QC.NEAR ^ 2 then Only, N = O, N + 1 end
    end
    if N == 1 then return Only, "einziger Gast in 50 m" end
    return nil
end

-- Mithilfe: andere Gaeste <= 50 m vom Toten mit offenem Task gleicher (Task, Argument)
function W.Assist(E, G)
    for _, O in ipairs(W.Guests("qst1")) do
        if O.Key ~= G.Key and W.QLoaded(O) then
            local Pawn, PC = W.GuestPawn(O)
            local NC = W.NC(PC)
            if Pawn and NC and W.Dist2(E.X, E.Y, E.Z, W.Loc(Pawn)) <= W.QC.NEAR ^ 2 and W.HasTask(NC, E.Task, E.Arg, true) then
                W.Credit(O, E.Task, E.Arg, E.Qty, "Mithilfe")
            end
        end
    end
end

function W.N8Flush(Now)
    if #W.N8Wait == 0 then return end
    local Keep = {}
    for _, E in ipairs(W.N8Wait) do
        local G, Why = W.QOwner(E, Now)
        if Why == "wait" then
            Keep[#Keep + 1] = E
        elseif G then
            W.Credit(G, E.Task, E.Arg, E.Qty, Why)
            if W.Q2("quest_assist") and E.X and E.Task:find("KillNPC", 1, true) then W.Assist(E, G) end
        else
            W.N8Drop = (W.N8Drop or 0) + 1
            if Now >= (W.N8DropAt or 0) then
                W.N8DropAt = Now + 10
                Log("Quest-Fortschritt ohne Taeter verworfen: %s (%s), bisher %d", W.Short(E.Task), E.Arg, W.N8Drop)
            end
        end
    end
    W.N8Wait = Keep
end

-- Host (0,25 s): N8 (DLL beobachtet CompleteNarrativeDataTask) -> Aufrufe mit Ziel Geist-NC dem Taeter gutschreiben.
-- Eigener Cursor "_ls_world" ("_" = alle Tags), Tabellen geteilt -> nur lesen.
-- Ereignis (API_NATIVE.md): Ev.Caller / Ev.Args[i] = "<Klasse> <Pfad>" (Objekt), false (null), "0x.." (tot)
function W.QuestN8(Now)
    if Net.Side ~= "host" or not W.Q2("quest_task") or type(Native.Events) ~= "function" then return end
    if Now < (W.N8At or 0) then W.N8Flush(Now) return end
    W.N8At = Now + 0.5                                           -- Ereignisdatei hoechstens 2x je Sekunde lesen
    local ok, List = pcall(Native.Events, "_ls_world")
    if ok and type(List) == "table" and #List > 0 then
        local Ghost = W.GhostNC()
        local GhostPath = Ghost and W.Path(Ghost)
        for _, Ev in ipairs(List) do
            if GhostPath and Ev.Tag == "n8_task" and type(Ev.Args) == "table" then
                local okP, E = pcall(W.N8Parse, Ev, GhostPath)
                if okP and E and #W.N8Wait < 200 then W.N8Wait[#W.N8Wait + 1] = E end
            end
        end
    end
    W.N8Flush(Now)
end

-- Rueckfall ohne N8 (DLL-Beobachter fehlt) oder mit quest_task=0: Zuwachs beim Geist an alle Gaeste mit diesem Task
function W.QuestShare(Now)
    if Net.Side ~= "host" or not QOn("quest_share") or Now < (W.ShareAt or 0) then return end
    if W.Q2("quest_task") and type(Native.Events) == "function" then return end
    W.ShareAt = Now + 2
    local Ghost, Lib = W.GhostNC(), W.NarrLib()
    if not Ghost or not Lib then return end
    local Pairs, NCs = {}, {}
    for _, G in ipairs(W.Guests("qst1")) do
        local NC = W.NC(Net.PC(G))
        if NC then NCs[G.Key] = NC W.ActiveTasks(NC, Pairs, G.Key) end
    end
    for Key, E in pairs(Pairs) do
        local Task = W.Obj(E.Task)
        local N = Task and Try(function() return Ghost:GetNumberOfTimesTaskWasCompleted(Task, E.Arg) end)
        if N then
            local Base = W.TaskBase[Key]
            W.TaskBase[Key] = N
            local D = Base and N - Base or 0
            if D > 0 then
                for GKey in pairs(E.Guests) do
                    local NC = NCs[GKey]
                    if NC then pcall(function() Lib:CompleteNarrativeDataTask(NC, Task, E.Arg, D) end) end
                end
                Log("Quest-Fortschritt %s (%s) +%d geteilt (Rueckfall)", W.Short(E.Task), E.Arg, D)
            end
        end
    end
end

-- Gast: eigene N8-Beobachtung von CompleteNarrativeDataTask (ls_native "n8g" kann sie ebenfalls setzen; die DLL fasst
-- gleiche Funktionen zu einer Zeile zusammen)
function W.GWatch()
    local Want = Net.Side == "client" and W.Q2("quest_gtask") and Net.Has("qst2") and type(Native.N8) == "table"
    Want = Want and true or false
    if Want == (W.GWatchOn or false) then return end
    W.GWatchOn = Want
    pcall(Native.SetWatch, Want and { Native.N8[1] } or nil, "w_n8g")
    Log("Gast-Beobachtung Quest-Aufrufe %s", Want and "an" or "aus")
end

-- Gast (1 s): lokale CompleteNarrativeDataTask-Aufrufe der Kisten (ohne Autoritaet verloren) an den Host melden
function W.GTaskClient()
    if Net.Side ~= "client" or not W.GWatchOn or type(Native.Events) ~= "function" then return end
    local ok, List = pcall(Native.Events, "_ls_world")
    if not ok or type(List) ~= "table" then return end
    local function ObjPath(V) return type(V) == "string" and V:match("^%S+ (.+)$") or nil end
    local Own = W.OwnNC()
    local OwnPath = Own and W.Path(Own)
    for _, Ev in ipairs(List) do
        if Ev.Tag == "n8_task" and type(Ev.Args) == "table" then pcall(function()
            local Actor = W.Obj(ObjPath(Ev.Caller))
            Actor = Actor and W.ActorOf(Actor)
            if not Actor then return end
            local Set = W.ClassChain(Actor)
            local Cls
            for C in pairs(W.QC.CRATE) do if Set[C] then Cls = C end end
            local NCPath, TaskPath, Arg = ObjPath(Ev.Args[1]), ObjPath(Ev.Args[2]), Ev.Args[3]
            if not Cls or not TaskPath or type(Arg) ~= "string" or (NCPath and OwnPath and NCPath ~= OwnPath) then return end
            local X, Y, Z = W.Loc(Actor)
            Net.Send("q_task", string.format("%s|%s|1|%s|%.0f,%.0f,%.0f", Net.Enc(TaskPath), Net.Enc(Arg), Cls, X, Y, Z), nil, 1)
            Log("Quest-Aufruf %s (%s) -> Host", Cls, Arg)
        end) end
    end
end

-- Host: q_task pruefen (Klasse erlaubt, nur InteractWithActor wie @08be, Figur <= 10 m, Kiste am Ort, Task offen,
-- <= 1 je 2 s, je Spieler und Kistenort einmal je 30 min). QuestArgument (BP_MasterQuestObject_C @0x2B0) ist NICHT
-- repliziert: die replizierte Kiste meldet beim Gast "" -> massgeblich ist das Argument der Host-Kiste.
-- First = Zeit der ersten Pruefung (nur bei Wiederholung ueber W.GTaskLater)
function W.GTaskHost(G, Data, Now, First)
    local TaskP, Arg, Qty, Cls, X, Y, Z = tostring(Data):match("^([^|]+)|([^|]*)|(%d+)|([%w_]+)|([%-%d]+),([%-%d]+),([%-%d]+)$")
    if not TaskP or not W.QC.CRATE[Cls] or Qty ~= "1" then return Net.SecWarn(G, G.Key, "q_task") end
    TaskP, Arg, X, Y, Z = Net.Dec(TaskP), Net.Dec(Arg), tonumber(X), tonumber(Y), tonumber(Z)
    if not TaskP:match("^/Game/[%w_/%.]+$") or not TaskP:find("InteractWithActor", 1, true) or #Arg > 200 or not Z then
        return Net.SecWarn(G, G.Key, "q_task")
    end
    if not First then
        W.GTaskAt = W.GTaskAt or {}
        if Now - (W.GTaskAt[G.Key] or -10) < 2 then return Net.SecWarn(G, G.Key, "q_task_rate") end
        W.GTaskAt[G.Key] = Now
    end
    local Pawn, PC = W.GuestPawn(G)
    if not Pawn or W.Dist2(X, Y, Z, W.Loc(Pawn)) > 1000 ^ 2 then return Net.SecWarn(G, G.Key, "q_task_dist") end
    -- naechste Host-Kiste <= 300 uu; gemeldetes Argument muss leer (replizierte Kiste), gleich oder ein 40-Zeichen-Praefix
    -- (N8-FString-Grenze) des Host-Arguments sein
    local Want, Best, BestD = Arg:lower(), nil, 300 ^ 2
    for C in pairs(W.QC.CRATE) do
        for _, O in ipairs(FindAllOf(C) or {}) do
            if A.IsAlive(O) then
                local D = W.Dist2(X, Y, Z, W.Loc(O))
                local HA = D <= BestD and Try(function() return O.QuestArgument:ToString() end)
                local L = type(HA) == "string" and HA:lower()
                if L and (Want == "" or Want == L or (#Want >= 40 and L:sub(1, #Want) == Want)) then
                    Best, BestD = { Arg = HA }, D
                    Best.X, Best.Y = W.Loc(O)
                end
            end
        end
    end
    local NC = W.NC(PC)
    local HostArg = Best and Best.Arg or Arg
    if not Best or not NC or not W.QLoaded(G) or not W.HasTask(NC, TaskP, HostArg, true) then
        return W.LogOnce("gt" .. G.Key .. Arg, "Quest-Aufruf von Gast %s (%s, %s) abgelehnt", G.GuestId or "?", Cls, Arg)
    end
    -- Host-Kisten-Weg aktiv (Cap wcrate): nur nach einer von W.CrateHostOne angenommenen Oeffnung (Halten, Halter,
    -- Opened) dieses Gasts an diesem Ort; w_crate kann nach q_task ankommen bzw. bis 3 s warten -> bis 8 s nachpruefen
    if On("world_crate") and Net.Has("wcrate", G) then
        local Ok = W.CrateOpenOk[G.Key]
        if not Ok or Ok.Epoch ~= G.Epoch or Now - Ok.T > 15 or W.Dist2(X, Y, Z, Ok.X, Ok.Y, Ok.Z) > 300 ^ 2 then
            First = First or Now
            if Now - First < 8 then
                W.Later[#W.Later + 1] = { At = Now + 0.5, Fn = W.GTaskLater, Flag = "quest_gtask", Key = G.Key,
                                          Epoch = G.Epoch, Data = Data, First = First }
                return
            end
            return W.LogOnce("gk" .. G.Key .. Arg, "Quest-Aufruf von Gast %s (%s, %s) ohne angenommene Kistenoeffnung abgelehnt",
                G.GuestId or "?", Cls, Arg)
        end
        W.CrateOpenOk[G.Key] = nil
    end
    -- dieselbe Kiste nicht zweimal (Rejoin: replizierte Kiste ist beim Gast wieder zu; zwei Kisten am selben Ort)
    W.GTaskDone = W.GTaskDone or {}
    local DoneKey = (G.GuestId or G.Key) .. "|" .. W.LocKey(Best.X, Best.Y, 100) .. "|" .. HostArg:lower()
    if Now - (W.GTaskDone[DoneKey] or -4000) < 1800 then
        return W.LogOnce("gd" .. DoneKey, "Quest-Aufruf von Gast %s (%s, %s): Kiste schon gezaehlt", G.GuestId or "?", Cls, HostArg)
    end
    W.GTaskDone[DoneKey] = Now
    W.Credit(G, TaskP, HostArg, 1, "Gast-Aufruf " .. Cls)
end

-- Host (W.Later aus W.CrateHost): q_task erneut pruefen, solange die Kistenoeffnung noch aussteht
function W.GTaskLater(E, Now)
    local G = Net.Guests[E.Key]
    if not G or G.Epoch ~= E.Epoch or not W.Q2("quest_gtask") or not Net.Has("qst2", G) then return end
    return W.GTaskHost(G, E.Data, Now, E.First)
end

-- ------------------------------------------------------------------- Journal "Vergessen" (quest_forget)

function W.ForgetClient()
    local L = W.ForgetQ
    if #L == 0 then return end
    W.ForgetQ = {}
    if Net.Side ~= "client" or not W.Q2("quest_forget") or not Net.Has("qst2") then return end
    for _, P in ipairs(L) do
        Net.Send("q_forget", P, nil, 1)
        Log("Quest vergessen -> Host: %s", W.Short(P))
    end
end

function W.ForgetHost(G, Data, Now)
    local P = tostring(Data)
    if not P:match("^/Game/[%w_/%.]+_C$") or #P > 256 then return Net.SecWarn(G, G.Key, "q_forget") end
    W.ForgetAt = W.ForgetAt or {}
    if Now - (W.ForgetAt[G.Key] or -10) < 1 then return Net.SecWarn(G, G.Key, "q_forget_rate") end
    W.ForgetAt[G.Key] = Now
    local NC, Cls = W.NC(Net.PC(G)), W.Obj(P)
    if not NC or not Cls or not W.QLoaded(G) then return end
    if not Try(function() return NC:IsQuestInProgress(Cls) end, false) then return end
    local ok, err = pcall(function() NC:ForgetQuest(Cls) end)
    if not ok then Core.Fail("quest_forget", err) return end
    local S = W.QS(G)
    if S then S.SaveNow = true end
    Log("Quest %s von Gast %s vergessen", W.Short(P), G.GuestId or "?")
end

-- ------------------------------------------------------------------- Welt-Inhalte der Quest-Events

-- Alle Actors mit Tag (GetAllActorsWithTag, Out-Parameter; Rueckfall: bekannte Klassen des Tags)
function W.HasTag(O, Tag)
    local Hit = false
    pcall(function() O.Tags:ForEach(function(_, E) if E:get():ToString() == Tag then Hit = true end end) end)
    return Hit
end

function W.TagActors(Tag, Classes)
    local Out, Seen = {}, {}
    local function Add(O)
        local Ad = Alive(O) and W.Addr(O)
        if Ad and not Seen[Ad] then Seen[Ad] = true Out[#Out + 1] = O end
    end
    local GS = Try(function() return A.UEHelpers.GetGameplayStatics() end)
    local Ctx = A.LocalPC()
    if GS and Alive(Ctx) then
        local T = {}
        if pcall(function() GS:GetAllActorsWithTag(Ctx, FName(Tag), T) end) then
            local V = T.OutActors
            if V == nil and #T == 1 then V = T[1] end
            local L = ArrList(V)
            if #L == 0 and #T > 0 then L = ArrList(T) end
            for _, O in ipairs(L) do if type(O) == "userdata" then Add(O) end end
        end
    end
    if #Out == 0 then
        for Cls in pairs(Classes or {}) do
            for _, O in ipairs(FindAllOf(Cls) or {}) do
                if A.IsAlive(O) and W.HasTag(O, Tag) then Add(O) end
            end
        end
    end
    return Out
end

-- Host: Spawn-Event (Hook) -> Halter des Tags merken; schon vorhandene Inhalte -> neue Doppel entfernen.
-- Kisten (BP_GuaranteedSpawner) bekommt ein weiterer echter Spieler eigene (Oeffnen verbraucht sie).
function W.DedupeSpawn(R, H)
    local Tag = R.Tag
    local Cls = W.TagCls[Tag] or {}
    W.TagCls[Tag] = Cls
    if R.Cls then Cls[R.Cls] = true end
    local Holders = W.Holders[Tag] or {}
    W.Holders[Tag] = Holders
    local Known = W.Known[Tag] or {}
    local Actors = W.TagActors(Tag, Cls)
    local Old, New, Cur = 0, {}, {}
    for _, O in ipairs(Actors) do
        local Ad = W.Addr(O)
        if Ad then
            Cur[Ad] = true
            if Known[Ad] then Old = Old + 1 else New[#New + 1] = O end
        end
    end
    local Others = false
    for K in pairs(Holders) do
        if K ~= H and not (K == "local" and W.Dedicated()) then Others = true end
    end
    local Crate = R.Cls and W.QC.CRATE[R.Cls]
    if Old > 0 and #New > 0 and not (Crate and Others and not Holders[H]) then
        local N = 0
        for _, O in ipairs(New) do
            if W.QC.HUMAN and R.Cls == W.QC.HUMAN then pcall(function() O:KillSpawnedActors() end) end
            local Ad = W.Addr(O)
            if Ad and pcall(function() O:K2_DestroyActor() end) then Cur[Ad], N = nil, N + 1 end
        end
        Log("Quest-Inhalt %s: %d doppelte entfernt (Spieler %s, schon da: %d)", Tag, N, tostring(H), Old)
    end
    -- Kisten: Halter je behaltener Kopie merken (W.CrateFind gibt nur die eigene oder eine ungebundene heraus)
    if type(H) == "string" and H:sub(1, 1) ~= "?" and not (H == "local" and W.Dedicated()) then
        for _, O in ipairs(New) do
            local Ad = W.Addr(O)
            local C = Ad and Cur[Ad] and Try(function() return O:GetClass():GetFName():ToString() end)
            local P = C and W.QC.CRATE[C] and Try(function() return W.Path(O) end)
            if P then W.CrateHolder[P] = H end
        end
    end
    W.Known[Tag] = Cur
    Holders[H] = true
    W.TagGone[Tag] = nil
end

function W.TagRemove(Tag)
    local N = 0
    for _, O in ipairs(W.TagActors(Tag, W.TagCls[Tag])) do
        if pcall(function() O:K2_DestroyActor() end) then N = N + 1 end
    end
    W.Known[Tag], W.Holders[Tag], W.TagGone[Tag] = nil, nil, nil
    Log("Quest-Inhalt %s entfernt (%d Actors)", Tag, N)
end

-- Host: Event_RemoveActor (beim Host per Patch aus) -> erst entfernen, wenn kein Spieler den Tag mehr haelt
function W.DedupeRemove(R, H)
    local Holders = W.Holders[R.Tag] or {}
    Holders[H] = nil
    W.Holders[R.Tag] = Holders
    if next(Holders) then
        local L = {}
        for K in pairs(Holders) do L[#L + 1] = tostring(K) end
        Log("Quest-Inhalt %s bleibt (gebraucht von %s)", R.Tag, table.concat(L, ","))
        return
    end
    W.TagRemove(R.Tag)
end

-- Geist hat Quests vergessen: seine Tags freigeben; nur noch vom Geist gehaltene in 2 s entfernen (wenn bis dahin kein
-- Gast denselben Tag spawnt -> DedupeSpawn haelt ihn)
function W.GhostForgot(Now)
    for Tag, Holders in pairs(W.Holders) do
        if Holders["local"] then
            Holders["local"] = nil
            if not next(Holders) then W.TagGone[Tag] = Now + 2 end
        end
    end
end

function W.TagGoneTick(Now)
    for Tag, Due in pairs(W.TagGone) do
        if Now >= Due then
            if next(W.Holders[Tag] or {}) then W.TagGone[Tag] = nil else W.TagRemove(Tag) end
        end
    end
end

-- Host (Scanner 5 s): Marker sind pro Rechner (5.3: BFL_MinimapSystem = eigener Spieler). Repliziert der Host sie, sehen
-- alle Gaeste fremde Marker -> Host-Kopien weg, sobald jeder Gast eigene erzeugt (q_cli lev=1).
-- UE 5.6: BFL_MinimapSystem entfernt, Quest_Event_SpawnMarker nicht dekodiert -> nur mit quest_marker56=1
-- WORLD-28: quest_marker56 als Zahl (Core.Flag mit Zahl-Standard; "2" waere als Schalter false, 2 als Zahl true):
-- 0 = aus, 1 = Host-Kopien entfernen (unverifiziert), 2 = nur Diagnose (Erkennung + Zaehlung, zerstoert nie)
function W.MarkerMode()
    local V = tonumber(Core.Flag("quest_marker56", 0)) or 0
    if V == 1 or V == 2 then return V end
    return 0
end

function W.MarkerOn56() return W.MarkerMode() ~= 0 end

-- Diagnose-Zeile hoechstens bei Aenderung bzw. alle 60 s
function W.MarkerDiagLog(Text)
    local Now = os.clock()
    if Text == W.MarkDiag and Now < (W.MarkDiagAt or 0) then return end
    W.MarkDiag, W.MarkDiagAt = Text, Now + 60
    Log("Quest-Marker-Diagnose (quest_marker56=2): %s", Text)
end

-- Gast (Scanner 30 s, nur Diagnose): eigene (Rolle Authority) und replizierte Quest-Marker zaehlen. Replizierte =
-- der Gast saehe Marker fremder Quests (Entscheidung fuer quest_marker56=1 nach einem Live-Test)
function W.MarkerDiagClient(Objs)
    if W.MarkerMode() ~= 2 or not W.Q2("quest_marker") then return end
    local Own, Rep = 0, 0
    for _, O in ipairs(Objs) do
        local R = W.Role(O)
        if R == 3 then Own = Own + 1 elseif R == 1 or R == 2 then Rep = Rep + 1 end
    end
    W.MarkerDiagLog(string.format("Gast: %d eigene, %d replizierte Marker, eigene Marker-Ereignisse=%s", Own, Rep,
        tostring(W.LocalEv == true)))
end

function W.MarkerHost(Objs)
    if Net.Side ~= "host" or not W.Q2("quest_marker") or not W.Dedicated() or #Objs == 0 or not W.MarkerOn56() then return end
    if W.MarkerRep == nil then
        W.MarkerRep = Try(function() return Objs[1].bReplicates end, false) == true
        Log("Quest-Marker werden %srepliziert", W.MarkerRep and "" or "nicht ")
    end
    if W.MarkerMode() == 2 then
        local Lev, Gs = 0, W.Guests("qst1")
        for _, G in ipairs(Gs) do if Net.Get("q_cli", "lev", G) == "1" then Lev = Lev + 1 end end
        return W.MarkerDiagLog(string.format("Host: %d Marker, repliziert=%s, Gaeste mit eigenen Markern %d/%d", #Objs,
            tostring(W.MarkerRep), Lev, #Gs))
    end
    if not W.MarkerRep then return end
    local Guests = W.Guests("qst1")
    if #Guests == 0 then return end
    for _, G in ipairs(Guests) do
        if not Net.Has("qst2", G) or Net.Get("q_cli", "lev", G) ~= "1" then return end
    end
    local N = 0
    for _, O in ipairs(Objs) do
        local CM = Try(function() local C = O.CompassMarker if A.IsAlive(C) then return C end end)
        if CM then pcall(function() CM:K2_DestroyActor() end) end
        if pcall(function() O:K2_DestroyActor() end) then N = N + 1 end
    end
    if N > 0 then Log("Quest-Marker: %d Host-Kopien entfernt (Gaeste haben eigene)", N) end
end

-- Gast (1 s): lokal gespawnte Quest-Actors (Rolle Authority beim Gast, mit Tag) mit repliziertem Zwilling gleicher
-- Klasse <= 150 uu entfernen; ohne Zwilling behalten (Pruefung bis 60 s)
function W.TwinClient(Now)
    if Net.Side ~= "client" then W.GEv = {} return end
    local On2 = W.Q2("quest_spawnfix") and Net.Has("qst2")
    for _, R in ipairs(W.GEv) do
        if On2 and R.Tag and R.Tag ~= "None" and R.Tag ~= "" and R.Cls then
            W.Twins[R.Cls .. "|" .. R.Tag] = { Cls = R.Cls, Tag = R.Tag, Until = Now + 60 }
        end
    end
    W.GEv = {}
    if W.LocalEv and not W.LevSent and Net.Has("qst2") then
        W.LevSent = true
        Net.State("q_cli", "lev", "1", 2)
    end
    local Done = 0
    for K, T in pairs(W.Twins) do
        if Done >= 2 then break end
        if Now > T.Until or not On2 then
            W.Twins[K] = nil
        elseif Now >= (T.Next or 0) then
            Done, T.Next = Done + 1, Now + 2
            local Local, Rep = {}, {}
            for _, O in ipairs(FindAllOf(T.Cls) or {}) do
                if A.IsAlive(O) then
                    local Role = W.Role(O)
                    if Role == 3 and W.Runtime(O) and W.HasTag(O, T.Tag) then Local[#Local + 1] = O
                    elseif Role == 1 or Role == 2 then Rep[#Rep + 1] = { W.Loc(O) } end
                end
            end
            local N = 0
            for _, O in ipairs(Local) do
                local X, Y, Z = W.Loc(O)
                for _, P in ipairs(Rep) do
                    if W.Dist2(X, Y, Z, P[1], P[2], P[3]) <= 150 ^ 2 then
                        if pcall(function() O:K2_DestroyActor() end) then N = N + 1 end
                        break
                    end
                end
            end
            if N > 0 then Log("Quest-Inhalt %s: %d lokale Kopien entfernt (Host-Variante repliziert)", T.Tag, N) end
            if #Local == 0 or N == #Local then W.Twins[K] = nil end
        end
    end
end

-- ------------------------------------------------------------------- Belohnung genau einmal (quest_refire)

-- bRefireOnLoad (UNarrativeEvent @0x28) an Belohnungs-Events in geladenen Quest-Vorlagen (QuestTemplate @0x368,
-- States/Branches -> Events); gecacht 60 s
function W.RefireCount(Now)
    if W.RefireN ~= nil and Now < (W.RefireAt or 0) then return W.RefireN end
    local N, Q = 0, 0
    for _, C in ipairs(FindAllOf("QuestBlueprintGeneratedClass") or {}) do
        pcall(function()
            local T = A.IsAlive(C) and C.QuestTemplate
            if not T or not A.IsAlive(T) then return end
            Q = Q + 1
            local function Scan(Nodes)
                Nodes:ForEach(function(_, E)
                    local Nd = E:get()
                    if not A.IsAlive(Nd) then return end
                    Nd.Events:ForEach(function(_, V)
                        local Ev = V:get()
                        if A.IsAlive(Ev) and Ev.bRefireOnLoad == true
                            and Ev:GetClass():GetFName():ToString():find("Event_Reward", 1, true) then N = N + 1 end
                    end)
                end)
            end
            Scan(T.States)
            Scan(T.Branches)
        end)
    end
    if N ~= W.RefireN then Log("Refire-Belohnungen: %d (in %d Quest-Vorlagen)", N, Q) end
    W.RefireN, W.RefireAt = N, Now + 60
    return N
end

-- Lade-Fenster: Patch-Ende 0,5 s nach Load, Aufzeichnung laeuft 2,5 s nach (DLL-Verzug), Notbremse 15 s
function W.RwTick(Now)
    local L = W.RwLoad
    if not L then return end
    if L.Off and Now >= L.Off then L.Patch = false end
    if (L.Off and Now >= L.Off + 2.5) or Now - L.T0 > 15 then W.RwLoad = nil end
end

-- DLL-Bestaetigung der Lade-Fenster-Patches (netcore_status.txt "patch_w_rwload_x=1", 5.3 zusaetzlich
-- "patch_w_rwload_i=1"): true/false; nil = diese DLL meldet keine Patch-Zustaende (alter Weg: angefordert = angewendet)
function W.RwPatchOk()
    local S = Native.Status and Try(Native.Status)
    if type(S) ~= "table" or (S.patch_w_rwload_i == nil and S.patch_w_rwload_x == nil) then return nil end
    return S.patch_w_rwload_x == 1 and (W.REWARD_FN == nil or S.patch_w_rwload_i == 1)
end

-- Belohnung eines ANDEREN Spielers im Lade-Fenster (vom Patch verschluckt) nachreichen
function W.RwRecord(R)
    local L = W.RwLoad
    if not L or R.NC == L.NC then return end
    local Who = W.NCOwner(R.NC)
    if type(Who) ~= "table" then return end
    -- Patch nicht wirksam (DLL verweigert, z. B. Opcode-Abweichung) oder nicht gemeldet (alte DLL = nil): das Spiel
    -- hat womoeglich selbst ausgezahlt -> nur bei bestaetigtem Patch nachreichen, nie doppelt
    if L.NoAck or W.RwPatchOk() ~= true then
        return Log("Lade-Fenster: Patch nicht bestaetigt - keine Nachreichung fuer Gast %s", Who.GuestId or "?")
    end
    local Ev = W.Obj(R.Ev)
    if not Ev then return Log("Belohnung im Lade-Fenster fuer Gast %s nicht nachreichbar", Who.GuestId or "?") end
    -- 5.6: nur noch XP-Belohnungen (Quest_Event_RewardPlayerXP.Amount); Item-Event (S_RewardGiveItem) entfernt
    if R.Kind ~= "xp" then return end
    local Amount = Try(function() return Ev.Amount end)
    local PC = Net.PC(Who)
    local LC = PC and Try(function() local C = PC.LevellingComponent if A.IsAlive(C) then return C end end)
    local ok = Amount and LC and pcall(function() LC:AddXP(Amount, false, {}) end)
    Log("XP-Belohnung %s fuer Gast %s nachgereicht: %s", tostring(Amount), Who.GuestId or "?", ok and "ja" or "nein")
end

-- ------------------------------------------------------------------- Hook-Aufzeichnungen (Host)

function W.QEvTick(Now)
    if #W.QEv == 0 then return end
    local List = W.QEv
    W.QEv = {}
    if Net.Side ~= "host" then return end
    for _, R in ipairs(List) do
        local ok, err = pcall(W.QEvOne, R, Now)
        if not ok then Core.Fail("quest_ev", err) end
    end
end

function W.QEvOne(R, Now)
    if R.K == "lap" then return W.LaptopPick(R, Now) end
    if R.K == "rw" then return W.RwRecord(R) end
    if not R.Tag or R.Tag == "None" or R.Tag == "" then return end
    local Who = W.NCOwner(R.NC)
    local H = type(Who) == "table" and (Who.GuestId or Who.Key) or Who or ("?" .. tostring(R.NC))
    if R.K == "spawn" then W.DedupeSpawn(R, H) elseif R.K == "rem" then W.DedupeRemove(R, H) end
end

-- ------------------------------------------------------------------- Persistenz pro GuestId (quest_save)

function W.QuestSlot(Id) return "NetTest_Guests/" .. Id .. "_q" end

-- Quest-Fingerabdruck: abgeschlossen/gescheitert, Zustand je laufender Quest, Summe CurrentProgress (@0x50)
function W.QuestSig(NC)
    local Parts = {}
    local ok, Succ, Fail, Prog = pcall(function()
        return NC:GetSucceededQuests(), NC:GetFailedQuests(), NC:GetInProgressQuests()
    end)
    if not ok then return "?" end
    Parts[1] = #ArrList(Succ) .. "/" .. #ArrList(Fail)
    for _, Q in ipairs(ArrList(Prog)) do
        pcall(function()
            local St = A.IsAlive(Q) and Q.CurrentState or nil
            Parts[#Parts + 1] = string.format("%x", A.IsAlive(St) and St:GetAddress() or 0)
        end)
    end
    local Sum = 0
    W.QTasks(NC, function(Task) Sum = Sum + (tonumber(Task.CurrentProgress) or 0) end)
    Parts[#Parts + 1] = "p" .. Sum
    return table.concat(Parts, ",")
end

function W.QuestSav(Id) return W.GuestDir() .. Id .. "_q.sav" end

function W.FileSize(Path)
    local F = io.open(Path, "rb")
    if not F then return nil end
    local N = F:seek("end")
    F:close()
    return N
end

-- Anzahl Quests (abgeschlossen + gescheitert + laufend), nil wenn nicht lesbar
function W.QuestCount(NC)
    local ok, Succ, Fail, Prog = pcall(function()
        return NC:GetSucceededQuests(), NC:GetFailedQuests(), NC:GetInProgressQuests()
    end)
    if not ok then return nil end
    return #ArrList(Succ) + #ArrList(Fail) + #ArrList(Prog)
end

-- CORE-29: Quest-Anzahl beim Speichern merken (.world.txt qn). Narrative Load/Save haben in 5.6 keinen Rueckgabewert
-- (CXXHeaderDump Narrative.hpp: void) -> Laden mit 0 Quests trotz qn > 0 gilt als Ladefehler (W.QuestLoadBad)
function W.QuestCountRec(NC, Id)
    if not QOn("quest_loadcheck") then return end
    local N = W.QuestCount(NC)
    if not N then return end
    local R = W.Rec(Id)
    if R.qn ~= tostring(N) then R.qn = tostring(N) W.SaveRec(Id) end
end

-- CORE-29 (quest_save_atomic): erst Slot <Id>_q_tmp, Datei pruefen, dann _q.sav -> _q.sav.bak und _q_tmp -> _q.sav.
-- Ein Abbruch mitten im Schreiben laesst _q.sav heil. Rueckgabe true oder Fehlertext.
function W.QuestSaveAtomic(NC, Id)
    local Sav = W.QuestSav(Id)
    local Tmp, Bak = W.GuestDir() .. Id .. "_q_tmp.sav", Sav .. ".bak"
    os.remove(Tmp)
    NC:Save(W.QuestSlot(Id) .. "_tmp", 0)
    if (W.FileSize(Tmp) or 0) <= 0 then os.remove(Tmp) return "_q_tmp.sav leer oder fehlt" end
    if W.Exists(Sav) then
        os.remove(Bak)
        if not os.rename(Sav, Bak) then os.remove(Tmp) return "_q.sav nicht nach .bak umbenennbar" end
    end
    if os.rename(Tmp, Sav) then return true end
    os.rename(Bak, Sav)
    os.remove(Tmp)
    return "_q_tmp.sav nicht umbenennbar"
end

function W.QuestSaveNow(S, NC, Id, Now)
    -- CORE-10 (E22): Server stoppt, Gast-Staende sind mit der Welt festgeschrieben -> keine Quest-Slots mehr schreiben
    if A.Coop.GuestStoreFrozen == true then
        if not W.FrozenLog then W.FrozenLog = true Log("Quest-Speichern gesperrt (Server stoppt, Staende festgeschrieben)") end
        return false
    end
    S.SaveAt = Now + 60
    if S.NoSave then return false end   -- CORE-29: unlesbarer Save liess sich nicht sichern -> nie ueberschreiben
    if QOn("quest_save_atomic") then
        local okA, Res = pcall(W.QuestSaveAtomic, NC, Id)
        if okA and Res == true then W.QuestCountRec(NC, Id) return true end
        -- Rueckfall fuer diesen Durchlauf: direkt in den Slot wie bisher (wiederholte Fehler schalten den Weg ab)
        Core.Fail("quest_save_atomic", Res)
    end
    local ok, err = pcall(function() NC:Save(W.QuestSlot(Id), 0) end)
    if not ok then Core.Fail("quest_save", err) else W.QuestCountRec(NC, Id) end
    return ok
end

-- CORE-29 (quest_loadcheck): Grund (Text) wenn das Laden nicht als gelungen gelten darf, sonst nil
function W.QuestLoadBad(ok, NC, Id)
    if not QOn("quest_loadcheck") then return nil end
    if not ok then return "Fehler" end
    local Want = tonumber(W.Rec(Id).qn)
    if Want and Want > 0 and W.QuestCount(NC) == 0 then return "0 statt " .. Want .. " Quests" end
    return nil
end

-- Einmal je Controller laden (ClientReceiveSave an den Gast). Mit Refire-Belohnungen: Lade-Fenster (Host-Patch an,
-- 2,5 s warten, Load, Patch aus), damit alte Belohnungen nicht erneut kommen.
function W.QuestLoad(G, S, NC, Id, Now)
    if S.HadSave == nil then
        -- CORE-29: _q.sav fehlt, aber .bak liegt da (Abbruch zwischen den Umbenennungen) -> letzten Stand zurueck
        local Sav = W.QuestSav(Id)
        if QOn("quest_save_atomic") and not W.Exists(Sav) and W.Exists(Sav .. ".bak") and os.rename(Sav .. ".bak", Sav) then
            Log("Quests von Gast %s: _q.sav fehlte - aus .bak wiederhergestellt", Id)
        end
        S.HadSave = W.Exists(Sav)
    end
    if S.HadSave and QOn("quest_save") then
        -- 5.6: ohne Item-Event nur der XP-Hook (rw_x); 5.3 zusaetzlich rw_i
        if W.Q2("quest_refire") and (W.QHooks.rw_i or not W.REWARD_FN) and W.QHooks.rw_x and W.RefireCount(Now) > 0 then
            local L = W.RwLoad
            -- Fenster eines anderen Gasts, oder eigenes Fenster laeuft schon aus (Off gesetzt, Wiederholung nach
            -- schlechtem Laden): warten, bis W.RwTick es loescht, dann frisches Fenster mit Patch
            if L and (L.Key ~= G.Key or L.Off) then return end
            if not L then
                W.RwLoad = { Key = G.Key, NC = W.Path(NC), Patch = true, LoadAt = Now + 2.5, T0 = Now }
                Native.StatusAt = nil      -- DLL-Status (Patch-Bestaetigung) frisch lesen, nicht aus dem 2-s-Cache
                Log("Lade-Fenster fuer Gast %s: Belohnungen kurz aus", Id)
                return
            end
            if Now < L.LoadAt then return end
            -- DLL meldet Patch-Zustaende: bis 6 s auf die Bestaetigung warten, sonst ohne Nachreichung laden
            local Ack = W.RwPatchOk()
            if Ack == false and Now - L.T0 < 6 then return end
            if Ack == false and not L.NoAck then
                L.NoAck = true
                Log("Lade-Fenster fuer Gast %s: Patch nicht bestaetigt - Laden ohne Nachreichung", Id)
            end
            L.Off = Now + 0.5
        end
        local ok = pcall(function() NC:Load(W.QuestSlot(Id), 0) end)
        local Bad = W.QuestLoadBad(ok, NC, Id)
        if not Bad then
            Log("Quests von Gast %s geladen: %s", Id, ok and "ja" or "Fehler")
        else
            -- CORE-29: nicht als geladen werten (sonst ueberschreibt der 60-s-Takt den Save mit leerem Stand)
            S.LoadTry = (S.LoadTry or 0) + 1
            if S.LoadTry < 3 then
                Log("Quests von Gast %s nicht geladen (%s) - neuer Versuch %d", Id, Bad, S.LoadTry)
                -- Lade-Fenster NICHT sofort loeschen: der Host-Patch (w_rwload_x) bleibt bis zum DLL-Abschalten noch
                -- 1-2,5 s aktiv; ohne Fenster wuerden verschluckte XP-Belohnungen anderer Gaeste nicht nachgereicht.
                -- W.RwTick laesst es normal auslaufen (Off + 2,5 s), der naechste Versuch oeffnet danach ein frisches.
                local L2 = W.RwLoad
                if L2 and L2.Key == G.Key then L2.Off = L2.Off or Now else L2 = nil end
                S.LoadAt = Now + (L2 and 3.5 or 2)
                return
            end
            local Sav = W.QuestSav(Id)
            local To = Sav .. ".bad" .. os.time()
            if os.rename(Sav, To) then S.HadSave = false else S.NoSave = true end
            Log("Quests von Gast %s nicht ladbar (%s) - %s", Id, Bad, S.NoSave
                and "Datei NICHT umbenennbar, Quest-Speichern fuer diese Sitzung aus (kein Ueberschreiben)"
                or ("Datei als " .. (To:match("[^\\/]+$") or To) .. " gesichert, Quests beginnen neu"))
        end
    end
    S.Loaded, S.SaveAt, S.SigAt = true, Now + 60, Now + 5
    S.Sig = W.QuestSig(NC)
    W.QFlush(G, Now)
end

-- Aenderung (eigene Host-Aktion = Dirty, sonst Fingerabdruck alle 2 s) -> spaetestens 2 s spaeter speichern; 60-s-Takt
function W.QuestSaveCheck(S, NC, Id, Now)
    if S.Dirty and not S.DirtyAt then S.DirtyAt = Now + 2 end
    if Now >= (S.SigAt or 0) then
        S.SigAt = Now + 2
        local Sig = W.QuestSig(NC)
        if Sig ~= S.Sig then S.Sig, S.Dirty, S.DirtyAt = Sig, true, S.DirtyAt or Now end
    end
    if not (S.SaveNow or (S.Dirty and Now >= S.DirtyAt) or Now >= S.SaveAt) then return end
    local Changed = S.Dirty or S.SaveNow
    S.SaveNow, S.Dirty, S.DirtyAt = nil, nil, nil
    if W.QuestSaveNow(S, NC, Id, Now) then
        S.Sig = W.QuestSig(NC)
        if Changed and Now >= (S.LogAt or 0) then
            S.LogAt = Now + 30
            Log("Quest-Stand von Gast %s gespeichert (Aenderung)", Id)
        end
    end
end

function W.QuestSave(Now)
    if Net.Side ~= "host" then return end
    W.QState = W.QState or {}
    W.RwTick(Now)
    for _, G in ipairs(W.Guests("qst1")) do
        local Id, S = G.GuestId, W.QState[G.Key]
        local NC = Id and W.NC(Net.PC(G))
        if NC and S then
            S.GuestId = Id
            if not S.Loaded then
                if Now >= S.LoadAt then W.QuestLoad(G, S, NC, Id, Now) end
            else
                W.QFlush(G, Now)
                if not S.Started and not S.HadSave and Now >= S.LoadAt + 20 then
                    S.Started, S.Dirty = true, true
                    W.StartQuest(NC, Id)
                end
                if QOn("quest_save") then W.QuestSaveCheck(S, NC, Id, Now) end
            end
        end
    end
end

-- Alle geladenen Gast-Quests sofort speichern (fuer main.lua/server.lua: Trennung, Srv.Save, Shutdown)
function M.SaveQuests()
    if Net.Side ~= "host" or not W.QState or not QOn("quest_save") then return 0 end
    local N, Now = 0, os.clock()
    Net.ForEachGuest(function(G)
        local S = W.QState[G.Key]
        local Id = S and S.Loaded and (G.GuestId or S.GuestId)
        local NC = Id and W.NC(Net.PC(G))
        if NC and W.QuestSaveNow(S, NC, Id, Now) then N = N + 1 end
    end)
    return N
end

-- ------------------------------------------------------------------- Bytecode-Patches (netcore_patch.txt)
-- ret_early an Offset 0 (neu 04 0B = EX_Return EX_Nothing); Erwartung = erste Opcodes aus bp\*.kdis. Passt sie nicht,
-- verweigert die DLL (Spielversion). Zeile ueber die Patch-Registry von main.lua (schreibt auf Host und Gast).
-- UE 5.6 (analysis56\bp): Quest_Event_RewardPlayerXP_C / Quest_Event_RandomBounty_C ExecuteEvent @0000 LetObj (5F),
-- @0001 LocalVariable (00) -> "5F00". Entfallen (Klassen entfernt): w_reward/w_rwload_i (Event_RewardGiveItem 4CD5),
-- w_qhuman (Event_SpawnAIHumanSpawner), w_qremove (Event_RemoveActor 4C99).
function W.QPatchList()
    local H, C, QC = Net.Side == "host", Net.Side == "client", W.QC
    local L = W.RwLoad
    return {
        { "w_rewxp", QC.XP_FN, "5F00", C and W.Q2("quest_xppatch") and Net.Has("qst2") },
        { "w_qlaptop", QC.LAPTOP_FN, "5F00", H and W.Q2("quest_laptop") and W.QHooks.lap ~= nil },
        { "w_rwload_x", QC.XP_FN, "5F00", H and L ~= nil and L.Patch },
    }
end

function W.QPatches()
    if not Core.HasPatchRegistry() then return end
    for _, P in ipairs(W.QPatchList()) do
        local Name, Path, Expect, Want = P[1], P[2], P[3], P[4] and true or false
        local Cur = W.PatchState[Name]
        local Fn = (Want or Cur) and W.Obj(Path) or nil
        local Addr = Fn and Fn:GetAddress()
        -- nie gesetzt und nicht gewuenscht, oder unveraendert (gleiche Funktion): nichts schreiben
        if Fn and not (Cur == Want and (not Want or Addr == W.PatchAddr[Name])) then
            if Core.SetPatch(Name, string.format("%s ret_early %x 0 %s 040B %d", Name, Addr, Expect, Want and 1 or 0)) then
                W.PatchState[Name], W.PatchAddr[Name] = Want, Addr
                Log("Patch %s %s angefordert", Name, Want and "an" or "aus")
            end
        end
    end
end

-- ------------------------------------------------------------------- Hooks (selten, nur Pre; Koerper schreibt Tabellen)
-- Koerper lesen nur Felder/Namen (GetFullName, FName, Properties), rufen keine UFunctions.

function W.HPath(P)
    local ok, O = pcall(function() return P:get() end)
    if ok and O and O:IsValid() then return Try(function() return W.Path(O) end) end
    return nil
end

function W.HRec(List, Rec)
    if #List < 300 then Rec.At = os.clock() List[#List + 1] = Rec end
end

function W.HSpawn(Id)
    return function(Ctx, _, _, NC)
        if not W.QHookOn[Id] then return end
        local Self = Try(function() return Ctx:get() end)
        if not Self then return end
        local Tag = Try(function() return Self.Tag:ToString() end)
        local Cls = Id == "sp_h" and W.QC.HUMAN or Try(function()
            local C = Id == "sp_p" and Self.Prefab or Self.Actor
            if C and C:IsValid() then return C:GetFName():ToString() end
        end)
        if Net.Side == "host" then
            W.HRec(W.QEv, { K = "spawn", Tag = Tag, Cls = Cls, NC = W.HPath(NC) })
        else
            W.LocalEv = true
            W.HRec(W.GEv, { Tag = Tag, Cls = Cls })
        end
    end
end

function W.HLaptop(_, _, _, NC)
    if not W.QHookOn.lap then return end
    if Net.Side == "host" then W.HRec(W.QEv, { K = "lap", NC = W.HPath(NC) })
    else W.LapLocalAt, W.LocalEv = os.clock(), true end
end

function W.HRemove(Ctx, _, _, NC)
    if not W.QHookOn.rem or Net.Side ~= "host" then return end
    W.HRec(W.QEv, { K = "rem", Tag = Try(function() return Ctx:get().Tag:ToString() end), NC = W.HPath(NC) })
end

function W.HReward(Kind)
    return function(Ctx, _, _, NC)
        if Net.Side ~= "host" or not W.RwLoad then return end
        W.HRec(W.QEv, { K = "rw", Kind = Kind, Ev = W.HPath(Ctx), NC = W.HPath(NC) })
    end
end

function W.HMarker() if W.QHookOn.mark and Net.Side == "client" then W.LocalEv = true end end

function W.HForget(Ctx)
    if not W.QHookOn.forget or Net.Side ~= "client" then return end
    local P = Try(function()
        local Q = Ctx:get().CurrentQuest
        if Q and Q:IsValid() then return W.Path(Q:GetClass()) end
    end)
    if P and #W.ForgetQ < 10 then W.ForgetQ[#W.ForgetQ + 1] = P end
end

function W.HTalk(Ctx)
    if not W.QHookOn.talk1 or Net.Side ~= "client" then return end
    local P = W.HPath(Ctx)
    if P then W.TalkHit = { Path = P, At = os.clock() } end
end

-- { Id, Funktionspfad, gewuenscht?, Koerper }
function W.QHookDefs()
    local QC = W.QC
    local function Host() return Net.Side == "host" end
    local function Cli() return Net.Side == "client" and Net.Has("qst2") end
    local function Spawn() return (Host() and W.Q2("quest_dedupe")) or (Cli() and W.Q2("quest_spawnfix")) end
    local function Talk() return Cli() and W.Q2("quest_talk") end
    local All = {
        { "lap", QC.LAPTOP_FN, function() return W.Q2("quest_laptop") and (Host() or Cli()) end, W.HLaptop },
        { "sp_a", QC.SPAWN_FN, Spawn, W.HSpawn("sp_a") },
        { "sp_p", QC.PREFAB_FN, Spawn, W.HSpawn("sp_p") },
        { "sp_h", QC.HUMAN_FN, function() return Host() and W.Q2("quest_dedupe") end, W.HSpawn("sp_h") },
        { "rem", QC.REMOVE_FN, function() return Host() and W.Q2("quest_dedupe") end, W.HRemove },
        { "rw_i", W.REWARD_FN, function() return Host() and W.Q2("quest_refire") end, W.HReward("item") },
        { "rw_x", QC.XP_FN, function() return Host() and W.Q2("quest_refire") end, W.HReward("xp") },
        { "mark", QC.MARKER_FN, function() return Cli() and W.Q2("quest_marker") and W.MarkerOn56() end, W.HMarker },
        { "forget", QC.FORGET_FN, function() return Cli() and W.Q2("quest_forget") end, W.HForget },
        { "talk1", QC.TALK_FN[1], Talk, W.HTalk },
        { "talk2", QC.TALK_FN[2], Talk, W.HTalk },
        { "talk3", QC.TALK_FN[3], Talk, W.HTalk },
    }
    -- 5.6: Eintraege ohne Funktionspfad (Klasse entfernt) nie hooken
    local L = {}
    for _, D in ipairs(All) do if D[2] then L[#L + 1] = D end end
    return L
end

-- 1 s: Schalter fuer die Koerper; fehlende Hooks alle 10 s versuchen (nur wenn die Funktion schon geladen ist)
function W.QHookTry(Now)
    W.QHOOKDEFS = W.QHOOKDEFS or W.QHookDefs()
    -- Klasse neu geladen/entladen: alle 10 s gegen die aktuelle UFunction pruefen (W.HookStale)
    local Chk = Now >= (W.QHookChk or 0)
    if Chk then W.QHookChk = Now + 10 end
    for _, D in ipairs(W.QHOOKDEFS) do
        local Id = D[1]
        local Want = D[3]() and true or false
        W.QHookOn[Id] = Want
        if Chk and W.HookStale(W.QHooks, Id, D[2]) then W.QHookAt[Id] = nil end
        if Want and not W.QHooks[Id] and Now >= (W.QHookAt[Id] or 0) then
            W.QHookAt[Id] = Now + 10
            if W.Obj(D[2]) then
                W.QHooks[Id] = W.Hook(D[2], D[4])
                if W.QHooks[Id] then Log("Quest-Hook %s aktiv", Id) end
            end
        end
    end
end


-- ------------------------------------------------------------------- DLL-Unterdrueckung (Native.SetWatch, at=entry)
-- Runde 9. Besitzer ls_world_lap (Gast: CallRandomEvent, WORLD-1), ls_world_lay (Gast: Zufalls-Spawner, deren Ergebnis
-- der Host repliziert, WORLD-2/WORLD-4; Fallback bleibt W.LayoutClient), ls_world_fish (dedizierter Host:
-- MC_CastRod/MC_StopFishing, WORLD-6). Alle Ziele ohne Out-Parameter (bp\*.kdis). Eigene Aufgabe w_watch_t: laeuft
-- auch ohne Net.Side, damit nach dem Verlassen nichts unterdrueckt bleibt.
W.LAPTOP_CLS = "/Game/Quests/Blueprints/Bounties/BP_BountyQuestManager.BP_BountyQuestManager_C"
W.LAY_CRATE = {   -- Spawner -> Kistenklasse (Host meldet w_cfg rep_<Kiste>, world_spawncrate)
    { "/Game/Blueprints/Other/Keycards/BP_Keycard_Spawner.BP_Keycard_Spawner_C:ReceiveBeginPlay",
      "BP_KeycardBriefcaseContainer_C" },
    { "/Game/Inventory/Containers/Containers/HiddenCache/BP_HiddenCache_Spawner.BP_HiddenCache_Spawner_C:ReceiveBeginPlay",
      "Container_HiddenCache_C" },
    { "/Game/Blueprints/Other/Objects/BP_SpecialItemContainerSpawner.BP_SpecialItemContainerSpawner_C:ReceiveBeginPlay",
      "Container_SpecialItemSpawner_C" },
}
W.LAY_PREFAB = {  -- Prefab-Spawner (Host meldet w_cfg rep_PrefabMaster_C, world_layout_nospawn)
    "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:ReceiveBeginPlay",
    "/Game/Blueprints/Settlements/BP_SettlementCampSpawner.BP_SettlementCampSpawner_C:SpawnSettlement",
    "/Game/POI/Alternates/BP_AlternatePOI_Listener.BP_AlternatePOI_Listener_C:SpawnPrefab",
}
W.FISH_SUP = { "/Game/Blueprints/Components/FishingComponent.FishingComponent_C:MC_CastRod",
               "/Game/Blueprints/Components/FishingComponent.FishingComponent_C:MC_StopFishing" }
-- Runde 9 (world-2): WORLD-7 Toasts fremder Figuren (Gast, at=call, remote=1), WORLD-10 Himmel-Zonen (dedizierter Host)
W.NOTE_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
W.SKY_SUP = { "/Game/Blueprints/Zones/BP_EnterSkyModifer.BP_EnterSkyModifer_C:Event_Enter",
              "/Game/Blueprints/Zones/BP_EnterSkyModifer.BP_EnterSkyModifer_C:Event_Exit" }
W.WATCH_OWNERS = { "ls_world_lap", "ls_world_lay", "ls_world_fish", "ls_world_note", "ls_world_sky" }

-- DLL kennt remote=1 (Status feat_remote=1)? Ohne: eine alte DLL ignoriert das Wort und wuerde JEDEN Toast unterdruecken
function W.RemoteOk()
    local S = Try(function() return Native.Status() end)
    return type(S) == "table" and tonumber(S.feat_remote) == 1
end

function W.Sup(Func, Tag) return { Func = Func, Tag = Tag, Mode = "suppress", At = "entry" } end

-- Liste eines Besitzers nur bei Aenderung setzen (Native.SetWatch schreibt netcore_watch.txt)
function W.SetWatch(Owner, List, What)
    W.WatchSig = W.WatchSig or {}
    local Names = {}
    for _, E in ipairs(List) do Names[#Names + 1] = E.Func end
    local Sig, Was = table.concat(Names, ","), W.WatchSig[Owner]
    if Was == Sig then return end
    local ok, Res = pcall(Native.SetWatch, #Names > 0 and List or nil, Owner)
    if not ok then Core.Fail("w_watch", Res) return end
    if Res == false then return end   -- Datei nicht geschrieben: naechster Takt versucht es erneut
    W.WatchSig[Owner] = Sig
    if Sig ~= "" or (Was and Was ~= "") then
        Log("%s: %s", What, #Names > 0 and (#Names .. " Funktion(en) lokal unterdrueckt (DLL)") or "Unterdrueckung aus")
    end
end

function W.WatchTick()
    local Dll = not Core.Down.w_watch and type(Native.Available) == "function" and Native.Available() == true
    local Cli, Host = Net.Side == "client", Net.Side == "host"
    -- WORLD-1: Gast fuehrt CallRandomEvent nicht lokal aus (BeginQuest ohne Autoritaet wirkungslos, "alle erledigt"
    -- @0325 waere ein Geister-Laptop); der Host waehlt per q_lapscan
    W.LapWatchOn = (Dll and Cli and W.Q2("quest_laptopscan") and Net.Has("qls1")) and true or false
    W.SetWatch("ls_world_lap", W.LapWatchOn and { W.Sup(W.LAPTOP_CLS .. ":CallRandomEvent", "q_lapsup") } or {},
        "Laptop-Ereignis beim Gast")
    -- WORLD-2/WORLD-4: eigene Zufalls-Spawner des Gasts aus, sobald der Host deren Ergebnis repliziert
    local Lay = {}
    if Dll and Cli and Net.Has("wld2") and On("world_layout") then
        if On("world_spawncrate") then
            for _, E in ipairs(W.LAY_CRATE) do
                if Net.Get("w_cfg", "rep_" .. E[2]) == "1" then Lay[#Lay + 1] = W.Sup(E[1], "w_laysup") end
            end
        end
        if On("world_layout_nospawn") and Net.Get("w_cfg", "rep_PrefabMaster_C") == "1" then
            for _, F in ipairs(W.LAY_PREFAB) do Lay[#Lay + 1] = W.Sup(F, "w_laysup") end
        end
    end
    W.SetWatch("ls_world_lay", Lay, "Zufalls-Spawner beim Gast")
    -- WORLD-6: dedizierter Host simuliert das Angeln der Gaeste nicht mit (Geist-Kamera, eigener Zufall, Toasts an den
    -- Gast). Der Multicast geht trotzdem raus (ProcessEvent sendet vor dem lokalen Koerper).
    local Fish = {}
    if Dll and Host and W.Dedicated() and On("world_fish_nohostsim") then
        for _, F in ipairs(W.FISH_SUP) do Fish[#Fish + 1] = W.Sup(F, "w_fishsup") end
    end
    W.SetWatch("ls_world_fish", Fish, "Angel-Simulation am Host")
    -- WORLD-7 (world_note_remote): MC_CastRod/MC_CatchFish/MC_StopFishing laufen als Multicast bei jedem Gast und zeigen
    -- die Toasts des FREMDEN Anglers (CreateNotificationUI -> GetPlayerController(0) = Zuschauer). Nur an der
    -- Aufrufstelle und nur fuer Kontexte fremder Spielerfiguren unterdruecken (Montagen/Effekte bleiben)
    local Note = {}
    if Dll and Cli and On("world_note_remote") and W.RemoteOk() then
        Note[1] = { Func = W.NOTE_FN, Tag = "w_noterm", Mode = "suppress", At = "call", Remote = true }
    end
    W.SetWatch("ls_world_note", Note, "Toasts fremder Spielerfiguren beim Gast")
    -- WORLD-10 (world_skymod): dedizierter Host fuehrt Event_Enter/Event_Exit der Himmel-Zonen nicht aus (die DLL loest
    -- GetPlayerCharacter(0) auf den Gast auf -> Modifier am replizierten Host-Himmel = fuer alle). Gast wendet lokal an.
    local SkyL = {}
    if Dll and Host and W.Dedicated() and On("world_skymod") then
        for _, F in ipairs(W.SKY_SUP) do SkyL[#SkyL + 1] = W.Sup(F, "w_skysup") end
    end
    W.SkySupOn = #SkyL > 0
    W.SetWatch("ls_world_sky", SkyL, "Himmel-Zonen am Host")
end

-- ------------------------------------------------------------------- Laptop-Scan (WORLD-1, quest_laptopscan, Cap qls1)
-- JigContextMenuComp.ContextScanLaptop (Gast-UI): @0049 RandomEvent.Broadcast -> CallRandomEvent lokal, @00ee Server
-- verbraucht den Laptop. Gast: Klick merken (Pre-Hook, nur Tabelle) -> q_lapscan. Host: Abnahme im Server-Inventar
-- belegen (ls_inv Ledger), dann W.LaptopPick fuer diesen Gast; alle erledigt -> Laptop zurueck (SP @0280-@0325).
W.LAPSCAN_FN = "/Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C:ContextScanLaptop"
W.LAPTOP_DA = "/Game/Inventory/Items/DataAssets/Quest/DA_MilitaryIntelLaptop.DA_MilitaryIntelLaptop"
W.LAP_WAIT, W.LAP_PAST = 8, 10
-- Closeout-Runde 2: world_lap_tight = Rueckgabe-Guthaben nur, wenn die Abnahme ohne offene Kiste hoechstens LAP_TIGHT s
-- vor/nach der Scan-Meldung lag
W.LAP_TIGHT = 3

function W.HLapScan() if Net.Side == "client" then W.LapScanAt = os.clock() end end

-- Gast (0,25 s): neuer Scan-Klick -> Host
function W.LapScanClient()
    local At = W.LapScanAt
    if not At or At == W.LapScanSent then return end
    W.LapScanSent = At
    if Net.Side == "client" and W.Q2("quest_laptopscan") and Net.Has("qls1") then Net.Send("q_lapscan", "1", nil, 1) end
end

-- Host: Abnahme eines Laptops im Server-Inventar des Gasts. nil = nicht pruefbar (ls_inv/Ledger aus), false = keine
-- bekannt, Zahl = os.clock der letzten Abnahme. Review 2 (inv_cons_open): zaehlt auch Einzel-Abnahmen bei offener
-- Kiste/Haendler (ls_inv H.ConsOpen, AllowOpen = true); 2. Rueckgabe true = Treffer kam von dort (kein Ersatz-Laptop).
-- Closeout: 3. Rueckgabe = Abnahme-Zaehler dieser Verbindung (ls_inv inv_cons_count), nil = alter ls_inv/Zaehler aus.
-- Closeout 2: 4. Rueckgabe = nur Abnahmen OHNE offene Kiste/Haendler (H.ConsN, 2-Argument-Aufruf; ein in die Kiste
-- verschobener/verkaufter Laptop zaehlt dort nicht) -> Grundlage fuer Proven-Rueckgaben (W.LapBookedC), nil = unbekannt
-- Closeout-Runde 2: 5. Rueckgabe = Zeit der letzten Abnahme OHNE offene Kiste/Haendler (H.Cons, world_lap_tight), nil = keine
function W.LapCons(G)
    local Inv = A.Coop and A.Coop.Inv
    local Fn = type(Inv) == "table" and Inv.LastConsume or nil
    if type(Fn) ~= "function" or not (Core.Flag("inv_v2a", true) or Core.Flag("inv_v2b", true)) then return nil end
    local ok, T, FromOpen, N = pcall(Fn, G.Key, "/da_militaryintellaptop%.", true)
    if not ok then return nil end
    -- Ledger ist gerade frisch (H.LedgerAt <= 0,1 s) -> nur Tabellen lesen, kein zweiter Ledger-Lauf
    local okC, Tc, _, Nc = pcall(Fn, G.Key, "/da_militaryintellaptop%.")
    return (type(T) == "number" and T or false), FromOpen == true, (type(N) == "number" and N or nil),
        ((okC and type(Nc) == "number") and Nc or nil), ((okC and type(Tc) == "number") and Tc or nil)
end

-- Host (0,25 s): vorgemerkte Scans buchen (Abnahme hoechstens LAP_PAST s vor der Meldung, je Abnahme einmal)
function W.LapScanTick(Now)
    local Q = W.LapScanQ
    if not Q or #Q == 0 then return end
    local Keep = {}
    W.LapScanQ = Keep
    -- Review 2 (world_lapscan_queue): 5-s-Drossel nur noch ohne Ledger-Nachweis (T == nil); Stempel erst beim Buchen
    local Queue = Core.Flag("world_lapscan_queue", true)
    W.LapNoProofAt = W.LapNoProofAt or {}
    -- Closeout (world_lapscan_count): mit Abnahme-Zaehler (ls_inv) gilt eine Abnahme als frei, solange Zaehler > gebucht;
    -- je gebuchtem Scan +1 (zwei Abnahmen vor der ersten Buchung -> beide Scans buchbar). Ohne Zaehler: W.LapUsed wie bisher
    local Cnt = Core.Flag("world_lapscan_count", true)
    -- Closeout-Runde 2 (world_lap_tight): Rueckgabe-Guthaben (PC) nur, wenn eine Abnahme OHNE offene Kiste hoechstens
    -- LAP_TIGHT s vor/nach dieser Scan-Meldung lag (echter Scan: Verbrauchs-RPC @00ee und q_lapscan im selben Klick).
    -- Ein gefaelschtes q_lapscan nach dem Verschieben in einen Behaelter hat so nur 3 statt 10 s
    -- (Verschieben in Behaelter: ls_inv inv_cons_nomove). Zeit je Eintrag einmal gemerkt (J.Tc), damit
    -- eine spaetere Abnahme die Zuordnung eines wartenden Scans (Quests noch nicht geladen) nicht verschiebt
    local Tight = Core.Flag("world_lap_tight", true)
    for _, J in ipairs(Q) do
        local G = Net.Guests[J.Key]
        if G and G.Epoch == J.Epoch then
            local T, FromOpen, N, Nc, Tc = W.LapCons(G)
            if J.Tc == nil and type(Tc) == "number" and math.abs(Tc - J.T0) <= W.LAP_TIGHT then J.Tc = Tc end
            local ByN = Cnt and type(N) == "number"
            -- Zaehler kleiner als gebucht = ls_inv-Stand neu (Neu-Verbinden ohne gone): Buchung von vorn (beide Zaehler)
            if ByN and N < (W.LapBooked[J.Key] or 0) then W.LapBooked[J.Key], W.LapBookedC[J.Key] = 0, 0 end
            if ByN and type(Nc) == "number" and Nc < (W.LapBookedC[J.Key] or 0) then W.LapBookedC[J.Key] = 0 end
            -- Closeout 2: Rueckgabe (Proven) nur, solange Abnahmen OHNE offene Kiste/Haendler > Proven-Buchungen. Sonst
            -- wuerde ein in die Kiste verschobener/verkaufter Laptop (ConsOpenN) Guthaben fuer ein gefaelschtes q_lapscan
            -- mit Rueckgabe liefern (Laptop-Dupe). Nc unbekannt -> keine Rueckgabe (vorsichtig)
            local PC = ByN and type(Nc) == "number" and Nc > (W.LapBookedC[J.Key] or 0) and (not Tight or J.Tc ~= nil)
            local Free = T and (ByN and N > (W.LapBooked[J.Key] or 0) or (not ByN and T ~= W.LapUsed[J.Key]))
            local Ok = T == nil or (T and T >= J.T0 - W.LAP_PAST and Free and true or false)
            local Hold = T == nil and Queue and Now - (W.LapNoProofAt[J.Key] or -100) < 5
            local NC = Ok and not Hold and W.QLoaded(G) and W.NC(Net.PC(G)) or nil
            if NC then
                if T then
                    W.LapUsed[J.Key] = T
                    -- je gebuchtem Scan genau +1 (nicht = N, sonst bliebe die zweite fruehe Abnahme ungebucht)
                    if ByN then W.LapBooked[J.Key] = (W.LapBooked[J.Key] or 0) + 1 end
                    if PC then W.LapBookedC[J.Key] = (W.LapBookedC[J.Key] or 0) + 1 end
                else
                    W.LapNoProofAt[J.Key] = Now
                end
                Log("Laptop-Scan von Gast %s%s", G.GuestId or J.Key, T == nil and " (ohne Abnahme-Nachweis)"
                    or (FromOpen and not PC) and " (Abnahme bei offener Kiste/Haendler)"
                    or (ByN and not PC) and " (kein Rueckgabe-Guthaben ohne offene Kiste)" or "")
                -- Proven nur fuer H.Cons-Treffer (ohne offene Kiste); FromOpen -> keine Rueckgabe (W.LaptopPick).
                -- Closeout-Runde 2: mit Zaehler entscheidet allein das Guthaben (PC). FromOpen kommt aus der NEUESTEN
                -- Abnahme und gehoert evtl. zu einem anderen Scan (zwei wartende Eintraege: geschlossen, dann offen) ->
                -- sonst wuerde ein gebuchtes Guthaben (W.LapBookedC +1) ohne Rueckgabe verbraucht
                local NoRef = (ByN and not PC) or (not ByN and FromOpen)
                W.LaptopPick({ NC = W.Path(NC), NoRefund = NoRef or nil,
                               Proven = (type(T) == "number" and ((ByN and PC) or (not ByN and not FromOpen))) or nil }, Now)
            elseif Hold then
                Log("Laptop-Scan von Gast %s verworfen: ohne Abnahme-Nachweis binnen 5 s", G.GuestId or J.Key)
                Net.SecWarn(G, G.Key, "q_lapscan_rate")
            elseif Now - J.T0 < (Ok and 30 or W.LAP_WAIT) then
                Keep[#Keep + 1] = J
            else
                Log("Laptop-Scan von Gast %s verworfen: %s", G.GuestId or J.Key,
                    Ok and "Quests nicht geladen" or "keine Laptop-Abnahme im Server-Inventar")
                if not Ok then Net.SecWarn(G, G.Key, "q_lapscan_nocons") end
            end
        end
    end
end

-- Host: SP-Rueckgabe des Laptops (@0325 JigMP_OnRequestDropItem waere am Server ein Abwurf vor die Fuesse) per
-- AddNewItemSomewhere ins Gast-Inventar wie ls_inv I.AddFor (5.6, 10 Parameter); hoechstens 1/60 s je Gast.
-- Review 2 (quest_lap_proven): mit Ledger-Nachweis (Proven, je Abnahme einmal ueber W.LapUsed) gibt es wie in SP bei
-- jedem Scan zurueck, hoechstens 3 je 60 s (ein Abwurf zaehlt nur mit inv_cons_nodrop=0 als Abnahme: Abwurf + gefaelschtes
-- q_lapscan bleibt begrenzt). Ohne Nachweis (Ledger aus, Dialog-Weg) bleibt die 60-s-Drossel.
function W.LapRefund(G, Now, Proven)
    W.LapRefundAt = W.LapRefundAt or {}
    local Id = G.GuestId or G.Key
    local Free = Proven == true and Core.Flag("quest_lap_proven", true)
    if Free then
        W.LapProvenAt = W.LapProvenAt or {}
        local Rec = {}
        for _, T in ipairs(W.LapProvenAt[Id] or {}) do if Now - T < 60 then Rec[#Rec + 1] = T end end
        W.LapProvenAt[Id] = Rec
        if #Rec >= 3 then return Log("Laptop-Rueckgabe an Gast %s: Drossel (3 je 60 s mit Nachweis)", Id) end
    elseif Now - (W.LapRefundAt[Id] or -1e9) < 60 then
        return Log("Laptop-Rueckgabe an Gast %s: Drossel (60 s)", Id)
    end
    local Pawn = W.GuestPawn(G)
    local Jig = Pawn and Try(function() local C = Pawn.BP_JigMultiplayer if A.IsAlive(C) then return C end end)
    local DA = Jig and (W.Obj(W.LAPTOP_DA) or Try(function() local D = LoadAsset(W.LAPTOP_DA) if A.IsAlive(D) then return D end end))
    if not (Jig and DA) then return Log("Laptop-Rueckgabe an Gast %s nicht moeglich (Figur/Asset fehlt)", Id) end
    W.LapRefundAt[Id] = Now
    if Free then W.LapProvenAt[Id][#W.LapProvenAt[Id] + 1] = Now end
    -- Verschieben in Behaelter ohne offen-Meldung: ls_inv inv_cons_nomove (braucht inv_cons_nodrop; kein Verbrauch ->
    -- kein Rueckgabe-Guthaben)
    local ok, err = pcall(function() Jig:AddNewItemSomewhere(DA, 1, nil, 0, true, FName("None"), {}, {}, {}, {}) end)
    if not ok then Core.Fail("quest_laptopscan", err) end
    Log("Laptop an Gast %s zurueckgegeben: %s", Id, ok and "ja" or "Fehler")
end

-- ------------------------------------------------------------------------------------------- Hooks (selten, nur Pre)

function W.TryHooks(Now)
    if Now < W.HookTry then return end
    if Net.Side == "host" then
        W.HookTry = Now + 10
        W.XpFishHookTry()
        return W.XpReqHookTry()
    end
    if Net.Side ~= "client" then return end
    W.HookTry = Now + 10
    -- Klasse neu geladen/entladen (Weltwechsel, Neu-Verbinden): Hook auf der alten UFunction verwerfen, neu hooken
    W.HookStale(W.Hooks, "sleep", W.SLEEP_HOOK)
    W.HookStale(W.Hooks, "barber", W.BARBER_HOOK)
    W.HookStale(W.Hooks, "crate", W.CRATE_FN)
    W.HookStale(W.Hooks, "crateh", W.CRATE_HOLD_FN)
    W.HookStale(W.Hooks, "lapscan", W.LAPSCAN_FN)
    W.HookStale(W.Hooks, "pet", W.PET_FN)
    -- WORLD-14: Hund streicheln (seltene Interaktion, Koerper schreibt nur W.PetEv)
    if not W.Hooks.pet and On("world_dogpet") and W.Obj(W.PET_FN) then
        W.Hooks.pet = W.Hook(W.PET_FN, W.HPet)
        if W.Hooks.pet then Log("Hunde-Streichel-Hook aktiv") end
    end
    -- WORLD-1: Laptop-Scan im Kontextmenue (seltener UI-Klick, Koerper schreibt nur W.LapScanAt)
    if not W.Hooks.lapscan and W.Q2("quest_laptopscan") and W.Obj(W.LAPSCAN_FN) then
        W.Hooks.lapscan = W.Hook(W.LAPSCAN_FN, W.HLapScan)
        if W.Hooks.lapscan then Log("Laptop-Scan-Hook aktiv") end
    end
    if not W.Hooks.sleep and On("world_sleep") then
        W.Hooks.sleep = W.Hook(W.SLEEP_HOOK, W.HSleep)
    end
    if not W.Hooks.barber and On("world_barber") then
        W.Hooks.barber = W.Hook(W.BARBER_HOOK, function() W.BarberAt = os.clock() end)
    end
    if On("world_xp") or Core.Flag("inv_craft_one", true) then W.XpHookTry() end
    if not W.Hooks.crate and On("world_crate") and W.Obj(W.CRATE_CLS) then
        W.Hooks.crate = W.Hook(W.CRATE_FN, W.HCrate)
        if W.Hooks.crate then Log("Kisten-Hook aktiv") end
    end
    if not W.Hooks.crateh and On("world_crate") and W.Obj(W.CRATE_CLS) then
        W.Hooks.crateh = W.Hook(W.CRATE_HOLD_FN, W.HCrateHold)
        if W.Hooks.crateh then Log("Kisten-Halte-Hook aktiv") end
    end
end

-- Schlaf-Knopf (Hook-Body, nur Tabellen). Gast: jeder Klick ist der eigene (ls_build oeffnet ihm per 'slp' nur sein
-- Fenster). Host: nur ein Fenster aus der EIGENEN Interaktion zaehlt (ls_build B.HostSlp, 300 s wie
-- OW.HostSleepCleanup); Fenster, die das Spiel fuer einen Gast im Host-Viewport baut, werden ignoriert.
function W.HSleep()
    if Net.Side == "host" then
        local MB = A.Coop.Modules and A.Coop.Modules.ls_build
        local HS = type(MB) == "table" and type(MB.B) == "table" and MB.B.HostSlp or nil
        if not (type(HS) == "table" and os.clock() - (tonumber(HS.At) or -1e9) < 300) then
            W.SleepIgn = (W.SleepIgn or 0) + 1
            return
        end
    end
    W.SleepClick = os.clock()
end

function W.BarberClient(Now)
    if not W.BarberAt or Now - W.BarberAt < 1.5 then return end
    W.BarberAt = nil
    if Net.Side == "client" and On("world_barber") and type(A.Coop.ResendAppearance) == "function" then
        pcall(A.Coop.ResendAppearance)
        Log("Barbier: Aussehen neu an den Host")
        -- WORLD-13 (E21): Barbier-Ergebnis am Server dauerhaft speichern (w_look)
        local Get = A.Coop.AppearanceText
        if On("world_look") and Net.Has("wlook") and type(Get) == "function" then
            local ok, T = pcall(Get)
            if ok and type(T) == "string" and T ~= "" and #T <= 4000 then Net.Send("w_look", T, nil, 1) end
        end
    end
end

-- WORLD-13 Gast (1 s): Aussehen vom Server (w_lookset) anwenden, sobald main.lua es kann (E21, bis 30 Versuche)
function W.LookClient()
    local T = W.LookWant
    if not T or Net.Side ~= "client" then return end
    local Get, Set = A.Coop.AppearanceText, A.Coop.ApplyOwnAppearance
    if type(Get) ~= "function" or type(Set) ~= "function" then W.LookWant = nil return end
    local okG, Cur = pcall(Get)
    if okG and Cur == T then W.LookWant = nil return end
    local ok, Res = pcall(Set, T)
    if ok and Res ~= false then
        W.LookWant = nil
        Log("Aussehen vom Server uebernommen")
        return
    end
    W.LookTry = (W.LookTry or 0) + 1
    if W.LookTry >= 30 then
        W.LookWant = nil
        Log("Aussehen vom Server nicht anwendbar: %s", tostring(Res))
    end
end

-- ------------------------------------------------------------------- Hund streicheln (WORLD-14, world_dogpet, Cap wpet)
-- BP_AnimalDog OnExecuteInteract (nur beim Gast, @06a8 -> L_061d): ohne laufende Montage -> Hund AN_DogPet_Montage
-- (@05dd), eigene Figur Chr_PettingDog_Montage (@0551); nichts davon ist vernetzt. Gast: Pre-Hook merkt den Hund (nur
-- Tabelle), Task meldet w_pet (K23) "x|y|z"; Host prueft (Figur <= 400 uu, Hund dort, 1/3 s) und schickt w_petfx (K24)
-- "PlayerId|x|y|z" an die anderen Gaeste; die spielen beide Montagen kosmetisch nach (Objekte je Aufruf frisch).
W.PET_FN = "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C:OnExecuteInteract"
W.PET_MON_DOG = "/Game/PolygonFiles/PolygonDog/Animation/AN_DogPet_Montage.AN_DogPet_Montage"
W.PET_MON_PAWN = "/Game/Character/Anims/Chr_PettingDog_Montage.Chr_PettingDog_Montage"

function W.HPet(Ctx)
    if Net.Side ~= "client" then return end
    local P = W.HPath(Ctx)
    if P then W.PetEv = { Path = P, At = os.clock() } end
end

-- Naechster Hund <= R uu an X/Y/Z (FindAllOf nur bei einem Streichel-Ereignis)
function W.PetDog(X, Y, Z, R)
    local Best, BD = nil, R * R
    for _, D in ipairs(FindAllOf("BP_AnimalDog_C") or {}) do
        if Alive(D) then
            local okL, DX, DY, DZ = pcall(W.Loc, D)
            if okL and DX then
                local Dd = W.Dist2(DX, DY, DZ, X, Y, Z)
                if Dd <= BD then Best, BD = D, Dd end
            end
        end
    end
    return Best
end

function W.PetMontage(Path)
    return W.Obj(Path) or Try(function() local M2 = LoadAsset(Path) if Alive(M2) then return M2 end end)
end

-- Beide Montagen an einer fremden Figur und dem Hund dort abspielen (nur Darstellung auf dieser Maschine)
function W.PetPlay(Pawn, X, Y, Z)
    local Dog = W.PetDog(X, Y, Z, 300)
    local MD, MP = W.PetMontage(W.PET_MON_DOG), W.PetMontage(W.PET_MON_PAWN)
    if Dog and MD then pcall(function() Dog:PlayAnimMontage(MD, 1.0, FName("None")) end) end
    if Alive(Pawn) and MP then pcall(function() Pawn:PlayAnimMontage(MP, 1.0, FName("None")) end) end
    return Dog ~= nil
end

-- 0,25 s, beide Seiten
function W.PetTick(Now)
    if not On("world_dogpet") then W.PetEv, W.PetQ, W.PetFx = nil, {}, {} return end
    if Net.Side == "client" then
        local E = W.PetEv
        if E and Now - E.At >= 0.2 then
            W.PetEv = nil
            local Dog = Now - E.At < 3 and W.Obj(E.Path)
            -- nur, wenn das Streicheln wirklich lief (Hund ohne laufende Montage -> L_05dd spielt eine)
            local Mon = Dog and Try(function() local M2 = Dog:GetCurrentMontage() if Alive(M2) then return M2 end end)
            if Mon and Net.Has("wpet") then
                local X, Y, Z = W.Loc(Dog)
                Net.Send("w_pet", string.format("%.0f|%.0f|%.0f", X, Y, Z), nil, 1)
            end
        end
        local L = W.PetFx
        if #L > 0 then
            W.PetFx = {}
            for I, R in ipairs(L) do
                if I <= 4 and Now - R.At < 5 then
                    local Pawn = Net.PawnByKey("p" .. R.Pid)
                    if Alive(Pawn) then W.PetPlay(Pawn, R.X, R.Y, R.Z) end
                end
            end
        end
    elseif Net.Side == "host" then
        local Q = W.PetQ
        if #Q == 0 then return end
        W.PetQ = {}
        for I, R in ipairs(Q) do
            local G = Net.Guests[R.Key]
            local Pawn = I <= 4 and G and G.Epoch == R.Epoch and W.GuestPawn(G)
            if Pawn then
                local okL, PX, PY, PZ = pcall(W.Loc, Pawn)
                -- PlayerId wie ls_net Net.PawnKey ("p<Id>", PlayerState mit IsAlive geprueft)
                local Pid = tonumber(tostring(Net.PawnKey(Pawn) or ""):match("^p(%-?%d+)$"))
                if not (okL and PX and Pid) or W.Dist2(PX, PY, PZ, R.X, R.Y, R.Z) > 400 ^ 2 then
                    Net.SecWarn(G, G.Key, "w_pet_dist")
                elseif not W.PetDog(R.X, R.Y, R.Z, 250) then
                    Net.SecWarn(G, G.Key, "w_pet_nodog")
                else
                    local Data = string.format("%d|%.0f|%.0f|%.0f", math.floor(Pid), R.X, R.Y, R.Z)
                    for _, O in ipairs(W.Guests("wpet")) do
                        if O.Key ~= G.Key then Net.Send("w_petfx", Data, O, 2) end
                    end
                    -- Host mit eigenem Spieler (nicht dediziert): selbst auch anzeigen
                    if not W.Dedicated() then W.PetPlay(Pawn, R.X, R.Y, R.Z) end
                end
            end
        end
    end
end

-- ------------------------------------------------------------------- Hygiene je Verbindung (CORE-30, world_hygiene)
-- Dauer-Server: jeder Beitritt bringt einen neuen PC-Key -> Tabellen je Verbindung beim Trennen leeren
W.PEER_TABS = { "ScrapRate", "TalkAt", "GTaskAt", "ForgetAt", "CrateRateT", "CrateHold", "CrateOpenOk", "TechNoTree",
                "HarvqRate", "PetAt" }
function W.ForgetPeer(Key)
    for _, Name in ipairs(W.PEER_TABS) do
        local T = W[Name]
        if type(T) == "table" then T[Key] = nil end
    end
    local Pre = Key .. "|"
    for K in pairs(W.AreaAt or {}) do
        if K:sub(1, #Pre) == Pre then W.AreaAt[K] = nil end
    end
end

-- WORLD-22 (world_harvq_guard): w_harvq nur ohne bewiesenes Nahkampf-Relay (ls_combat H.MRelProven, nur lesen; mit Relay
-- meldet der Host selbst) und hoechstens 2/s bzw. 60/min je Gast. Rueckgabe: Grund (SecWarn) oder nil = annehmen
function W.HarvqGuard(G)
    local MC = A.Coop.Modules and A.Coop.Modules.ls_combat
    local H = type(MC) == "table" and type(MC.H) == "table" and MC.H or nil
    if H and type(H.MRelProven) == "table" and G.Epoch and H.MRelProven[G.Key] == G.Epoch then return "w_harvq_relay" end
    local Now = os.clock()
    W.HarvqRate = W.HarvqRate or {}
    local R = W.HarvqRate[G.Key]
    if not R or Now - R.T0 >= 60 then R = { T0 = Now, N = 0, S = Now, SN = 0 } W.HarvqRate[G.Key] = R end
    if Now - R.S >= 1 then R.S, R.SN = Now, 0 end
    if R.N >= 60 or R.SN >= 2 then return "w_harvq_rate" end
    R.N, R.SN = R.N + 1, R.SN + 1
    return nil
end

-- ------------------------------------------------------------------- Kisten (world_crate / world_poicrate, Cap wcrate)
-- Runde 8. BP_GuaranteedSpawner: Hold-Timer -> OpenContainer laeuft nur beim Gast (5.6: L_0b40 Opened -> OnEndInteract
-- -> L_0665 AddProgress.Broadcast(0) (Quest-Fortschritt, 5.3: CompleteNarrativeDataTask @08be), MC_CrateOpen @0719,
-- Delay 1,3 s -> L_003b Array_Random(Items) + Spawn @026a/@048a am Direction-Punkt nur lokal = Geist; AddXP_Scavenging
-- HoldToInteract @0347 verloren). Gast: Pre-Hook OpenContainer merkt den Pfad, Task meldet w_crate und entfernt 3 s lang
-- eigene Laufzeit-Pickups <= 300 uu. Host: Kiste suchen, Opened, Owner = Gast; 5.6 (world_crate_prog): UB-Einsprung
-- 1637 (L_0665: AddProgress am Host-Exemplar + MC_CrateOpen + Delay 1,3 s -> L_003b), sonst MC_CrateOpen + nach 1,3 s
-- UB-Einsprung 59 (L_003b = SP-Belohnung); dann Pickup replizieren, Fertigkeits-XP. OpenContainer NIE am Host.
-- POI-Kisten: BP_POIManager spawnt sie ohne Autoritaets-Pruefung (@2067/@238d) -> W.REP; Pluendern meldet ls_inv
-- (W.PoiCrateLooted): Event_Looted (5.6 @281d -> L_26c0..@2751) am Host-Manager mit Owner = Gast (XP ueber
-- GetLevellingComponent(self)).
W.CRATE_CLS = "/Game/Quests/Blueprints/Objects/BP_GuaranteedSpawner.BP_GuaranteedSpawner_C"   -- 5.6: Ordner Objects
W.CRATE_UB_REWARD = 59        -- L_003b (5.6 unveraendert 0x003b: Let ...K2_GetComponentLocation, Belohnung)
W.CRATE_UB_PROG = 1637        -- 5.6 L_0665: CallMulticastDelegate AddProgress__DelegateSignature (kdis @0665)
W.CRATE_FN = W.CRATE_CLS .. ":OpenContainer"
-- Halte-Start: TryInteract (BP_JigHelperComp @0780) -> OnExecuteInteract lokal -> L_0e1d/L_0cb2 (IsHeld, MaxTime)
W.CRATE_HOLD_FN = W.CRATE_CLS .. ":OnExecuteInteract"
W.CU_PATH = "/Script/AutoSettings.Default__ConsoleUtils"
W.PICKUPS = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }
W.CrateEv, W.CrateWin, W.CrateQ, W.Later, W.CrateOwn, W.CrateGone, W.CrateRateT = {}, {}, {}, {}, {}, {}, {}
-- Halter je Kopie (Pfad -> GuestId/Key), Belohnung je Gast+Ort, w_cst (Host: gesendet, Gast: Schluessel/angewendet)
W.CrateHolder, W.CrateDone = W.CrateHolder or {}, W.CrateDone or {}
W.CstPub, W.CstWant, W.CstDone = W.CstPub or {}, {}, W.CstDone or {}
W.CrateHold = W.CrateHold or {}                                   -- Host: [GuestKey] = { X, Y, Z, At, Epoch } (w_crateh)
W.CrateOpenOk = W.CrateOpenOk or {}                               -- Host: [GuestKey] = { X, Y, Z, T, Epoch } (fuer q_task)

-- Gast (Hook-Body, nur Tabellen): Pfad der geoeffneten Kiste
function W.HCrate(Ctx)
    if #W.CrateEv >= 40 then return end
    local P = W.HPath(Ctx)
    if P then W.CrateEv[#W.CrateEv + 1] = { Path = P, At = os.clock() } end
end

-- Gast (Hook-Body, nur Tabellen): Halte-Start an einer Kiste
function W.HCrateHold(Ctx)
    if #W.CrateEv >= 40 then return end
    local P = W.HPath(Ctx)
    if P then W.CrateEv[#W.CrateEv + 1] = { Path = P, At = os.clock(), Hold = true } end
end

-- Spawn-Punkt der Belohnung: 5.6 Komponente "Direction" (L_003b @003b/@0296), 5.3 "Scene"
function W.SceneLoc(O)
    for _, F in ipairs(W.CRATE_PT) do
        local S = Try(function()
            local C = O[F]
            if Alive(C) then local V = C:K2_GetComponentLocation() return { V.X, V.Y, V.Z } end
        end)
        if S then return S[1], S[2], S[3] end
    end
    return W.Loc(O)
end
W.CRATE_PT = { "Direction", "Scene" }

-- Laufzeit-Pickups <= 300 uu um einen der Punkte Pts ({X, Y, Z}): Adresse -> { Objekt, Punkt-Index }; nur in diesem
-- Tick gueltig. Ein FindAllOf je Klasse fuer alle Punkte. OwnOnly = nur eigene (Gast, Authority ohne Owner) bzw. alle.
function W.PickupsNearAny(Pts, OwnOnly)
    local Out = {}
    for _, Cls in ipairs(W.PICKUPS) do
        for _, P in ipairs(FindAllOf(Cls) or {}) do
            if A.IsAlive(P) and W.Runtime(P) then pcall(function()
                local X, Y, Z = W.Loc(P)
                local Hit
                for I, Pt in ipairs(Pts) do
                    if W.Dist2(Pt[1], Pt[2], Pt[3], X, Y, Z) <= 300 ^ 2 then Hit = I break end
                end
                if not Hit then return end
                if OwnOnly and (not P:HasAuthority() or Alive(P:GetOwner())) then return end
                local Ad = W.Addr(P)
                if Ad then Out[Ad] = { P, Hit } end
            end) end
        end
    end
    return Out
end

-- Laufzeit-Pickups <= 300 uu um einen Punkt (Adresse -> Objekt; nur in diesem Tick gueltig)
function W.PickupsNear(X, Y, Z, OwnOnly)
    local Out = {}
    for Ad, E in pairs(W.PickupsNearAny({ { X, Y, Z } }, OwnOnly)) do Out[Ad] = E[1] end
    return Out
end

-- Gast (0,25 s): Kiste an den Host melden, 3 s lang eigene Belohnungs-Geister entfernen
function W.CrateClient(Now)
    local L = W.CrateEv
    if #L > 0 then W.CrateEv = {} end
    if not On("world_crate") or not Net.Has("wcrate") then W.CrateWin = {} return end
    for _, E in ipairs(L) do
        local O = Now - E.At < 5 and W.Obj(E.Path)
        if O and E.Hold then
            local X, Y, Z = W.Loc(O)
            Net.Send("w_crateh", string.format("BP_GuaranteedSpawner_C|%d|%d|%d", math.floor(X + 0.5),
                math.floor(Y + 0.5), math.floor(Z + 0.5)), nil, 0)
        elseif O and not W.Hooks.crateh then
            -- ohne Halte-Start lehnt der Host ab -> SP-Belohnung lokal behalten statt sie zu loeschen
            Log("Kiste geoeffnet, Halte-Hook fehlt -> nur lokal")
        elseif O then
            local X, Y, Z = W.Loc(O)
            Net.Send("w_crate", string.format("BP_GuaranteedSpawner_C|%d|%d|%d", math.floor(X + 0.5), math.floor(Y + 0.5),
                math.floor(Z + 0.5)), nil, 0)
            local SX, SY, SZ = W.SceneLoc(O)
            -- SP-Belohnung lokal erst nach Delay 1,3 s ab OpenContainer (5.6 @0b40 -> @0727 -> L_003b) -> vorher nicht suchen
            if #W.CrateWin < 8 then W.CrateWin[#W.CrateWin + 1] = { SX, SY, SZ, From = E.At + 1.1, Until = Now + 3 } end
            Log("Kiste geoeffnet -> Host (Belohnung kommt vom Host)")
        end
    end
    if #W.CrateWin == 0 then return end
    -- ein gemeinsamer Scan (je Klasse ein FindAllOf) fuer alle faelligen Fenster; ein Fenster mit Treffer ist erledigt
    -- (L_003b spawnt genau ein Pickup), bleibt aber bis Until fuer den Mine-Test in W.CstClient stehen
    local Keep, Due, N = {}, {}, 0
    for _, Win in ipairs(W.CrateWin) do
        if Now <= Win.Until then
            Keep[#Keep + 1] = Win
            if not Win.Done and Now >= (Win.From or 0) then Due[#Due + 1] = Win end
        end
    end
    W.CrateWin = Keep
    if #Due == 0 then return end
    for _, E in pairs(W.PickupsNearAny(Due, true)) do
        if pcall(function() E[1]:K2_DestroyActor() end) then N, Due[E[2]].Done = N + 1, true end
    end
    if N > 0 then Log("Kiste: %d lokale Belohnung(en) entfernt (Host-Variante kommt per Replikation)", N) end
end

-- Host: Drossel 0,25 s je Gast+Schluessel, <= 8 Anfragen/s je Gast
function W.CrateRate(G, Key, Now)
    local R = W.CrateRateT[G.Key]
    if not R or Now - R.T0 >= 1 then
        local K = {}
        for K2, T in pairs(R and R.K or {}) do if Now - T < 1 then K[K2] = T end end
        R = { N = 0, T0 = Now, K = K }
        W.CrateRateT[G.Key] = R
    end
    if R.N >= 8 or Now - (R.K[Key] or -1) < 0.25 then return false end
    R.N, R.K[Key] = R.N + 1, Now
    return true
end

-- Host: Pfade aller Kisten (beide Klassen, ohne Doppel) per FindAllOf hoechstens 1/s
function W.CrateListGet(Now)
    if Now - (W.CrateListAt or -10) >= 1 then
        W.CrateListAt = Now
        local L, Seen = {}, {}
        for C in pairs(W.QC.CRATE) do
            for _, O in ipairs(FindAllOf(C) or {}) do
                local P = A.IsAlive(O) and Try(function() return W.Path(O) end)
                if P and not Seen[P] then Seen[P], L[#L + 1] = true, P end
            end
        end
        W.CrateList = L
    end
    return W.CrateList or {}
end

-- Host: naechste ungeoeffnete Kiste <= 300 uu, die dem Gast gehoert (W.CrateHolder aus W.DedupeSpawn) oder ungebunden
-- ist; eigene Kopie vor ungebundener. Kopien anderer Quest-Halter nie (sonst zwei Belohnungen am selben Ort).
function W.CrateFind(X, Y, Z, Now, Who)
    local Own, OwnP, OwnD, Free, FreeP, FreeD = nil, nil, 300 ^ 2, nil, nil, 300 ^ 2
    local Opened, Foreign = false, false
    for _, P in ipairs(W.CrateListGet(Now)) do
        local O = W.Obj(P)
        local D = O and Try(function() return W.Dist2(X, Y, Z, W.Loc(O)) end)
        local H = W.CrateHolder[P]
        if D and D <= 300 ^ 2 then
            if H and H ~= Who then
                Foreign = true
            elseif Try(function() return O.Opened end, false) == true then
                Opened = true
            elseif H then
                if D <= OwnD then Own, OwnP, OwnD = O, P, D end
            elseif D <= FreeD then
                Free, FreeP, FreeD = O, P, D
            end
        end
    end
    if Own then return Own, OwnP, Opened, Foreign end
    return Free, FreeP, Opened, Foreign
end

-- Host: Mindest-Haltedauer in s (grosszuegige Untergrenze). SP: L_0cb2 MaxTime = DurationToHold/ScavengingMultiplier*
-- Difficulty.SearchTime; HoldToInteract +0,01*Multiplier je 0,01 s bis MaxTime-0,1; Widget-Multiplier hoechstens
-- 2,85*ScavengingMultiplier (BP_LootContainerWidget @0716). Faktor 0,5 und -0,4 s fangen Takt (0,25 s) und Latenz ab.
function W.CrateHoldMin(O, G)
    local D = tonumber(Try(function() return O.DurationToHold end)) or 0
    local PC = Net.PC(G)
    local S = PC and tonumber(Try(function()
        local C = PC.PassiveSkillsComponent
        if A.IsAlive(C) then return C.ScavengingMultiplier end
    end)) or 1
    local CU = Try(function() return StaticFindObject(W.CU_PATH) end)
    local T = Alive(CU) and tonumber(Try(function() return CU:GetFloatCVar(FName("Difficulty.SearchTime")) end)) or 1
    if S < 1 then S = 1 end
    if T < 0 then T = 0 end
    local Exp = (D * T / S - 0.1) / (2.85 * S)
    return math.min(math.max(0.5 * Exp - 0.4, 0), 10)
end

-- Host: eine w_crate-Anfrage; true = spaeter erneut (Kiste noch nicht in der Pfadliste)
function W.CrateHostOne(R, Now)
    local G = Net.Guests[R.Key]
    if not G or G.Epoch ~= R.Epoch then return false end
    local Pawn = W.GuestPawn(G)
    if not Pawn or Try(function() return Pawn["PlayerDead?"] end, false) == true then return false end
    local Who = G.GuestId or G.Key
    local O, Path, Opened, Foreign = W.CrateFind(R.X, R.Y, R.Z, Now, Who)
    if not O then
        if Opened or Foreign then
            Log("Kiste bei %d,%d,%d: %s (Gast %s)", R.X, R.Y, R.Z, Opened and "schon offen" or "fremde Quest-Kiste", Who)
            W.Note(G, Opened and "Diese Kiste ist schon geoeffnet." or "Kiste gehoert zur Quest eines anderen Spielers.")
            return false
        end
        if Now - R.At < 3 then return true end
        Log("Kiste bei %d,%d,%d nicht gefunden (Gast %s)", R.X, R.Y, R.Z, G.GuestId or G.Key)
        return false
    end
    local OX, OY, OZ = W.Loc(O)
    if W.Dist2(OX, OY, OZ, W.Loc(Pawn)) > 1000 ^ 2 then
        Net.SecWarn(G, G.Key, "w_crate_dist")
        return false
    end
    local B = A.Coop.Build
    if type(B) == "table" and type(B.CanUse) == "function" and not B.CanUse(G.GuestId, O) then
        W.Note(G, "Kein Zugriff")
        return false
    end
    -- SP belohnt erst nach dem Halten: der Halte-Start (w_crateh) dieses Gasts an dieser Kiste muss lange genug vor
    -- w_crate angekommen sein (W.CrateHoldMin); ein Halte-Start = eine Kiste
    local H = W.CrateHold[G.Key]
    if not H or H.Epoch ~= G.Epoch or W.Dist2(OX, OY, OZ, H.X, H.Y, H.Z) > 300 ^ 2 then
        Log("Kiste bei %d,%d,%d: kein Halte-Start von Gast %s -> abgelehnt", R.X, R.Y, R.Z, Who)
        Net.SecWarn(G, G.Key, "w_crate_nohold")
        return false
    end
    local Need = W.CrateHoldMin(O, G)
    -- veralteter Halte-Start (> Need + 60 s; erneutes Druecken haelt den Start nur 60 s) zaehlt nicht
    if R.At - H.At > Need + 60 then
        Log("Kiste bei %d,%d,%d: Halte-Start %.0f s alt (Gast %s) -> abgelehnt", R.X, R.Y, R.Z, R.At - H.At, Who)
        W.CrateHold[G.Key] = nil
        Net.SecWarn(G, G.Key, "w_crate_nohold")
        return false
    end
    if R.At - H.At < Need then
        Log("Kiste bei %d,%d,%d: nach %.2f s statt >= %.2f s geoeffnet (Gast %s) -> abgelehnt", R.X, R.Y, R.Z,
            R.At - H.At, Need, Who)
        Net.SecWarn(G, G.Key, "w_crate_fast")
        return false
    end
    W.CrateHold[G.Key] = nil
    -- je Gast und Kistenort eine Belohnung, solange die dort zuerst geoeffnete Kiste noch steht (ungebundene Kopien)
    local DoneKey = tostring(Who) .. "|" .. W.LocKey(OX, OY, 100)
    local Prev = W.CrateDone[DoneKey]
    if Prev and Prev.Path ~= Path and Now - Prev.T < 1800 and W.Obj(Prev.Path) then
        Log("Kiste bei %d,%d,%d: Gast %s hat hier schon eine geoeffnet", R.X, R.Y, R.Z, Who)
        W.Note(G, "Diese Kiste hast du schon geoeffnet.")
        return false
    end
    W.CrateDone[DoneKey] = { Path = Path, T = Now }
    W.CrateOpenOk[G.Key] = { X = OX, Y = OY, Z = OZ, T = Now, Epoch = G.Epoch }
    O.Opened = true
    pcall(function() O:SetOwner(Pawn) end)
    W.CrateOwn[Path] = G.Key
    W.CstAt = 0                                                   -- w_cst sofort neu berechnen (W.CstHost)
    -- 5.6: Quest-Fortschritt der Kiste laeuft ueber BP_QuestTaskComponent.AddProgress am Exemplar, das der Quest-Spawner
    -- (Host) gebunden hat -> am Host wie SP ab L_0665 (AddProgress, MC_CrateOpen, Delay 1,3 s -> L_003b Belohnung)
    if On("world_crate_prog") and Alive(Try(function() return O.BP_QuestTaskComponent end)) then
        local SX, SY, SZ = W.SceneLoc(O)
        local Before = {}
        for Ad in pairs(W.PickupsNear(SX, SY, SZ, false)) do Before[Ad] = true end
        local okP, errP = pcall(function() O:ExecuteUbergraph_BP_GuaranteedSpawner(W.CRATE_UB_PROG) end)
        if okP then
            -- Belohnung spawnt das Spiel selbst (Delay); nach 1,6 s nur Pickup replizieren + XP
            W.Later[#W.Later + 1] = { At = Now + 1.6, Fn = W.CrateReward, Path = Path, Key = G.Key, Epoch = G.Epoch,
                                      Spawned = true, Before = Before }
            return false
        end
        Core.Fail("world_crate_prog", errP)
    end
    local ok, err = pcall(function() O:MC_CrateOpen() end)
    if not ok then Core.Fail("world_crate", err) end
    W.Later[#W.Later + 1] = { At = Now + 1.3, Fn = W.CrateReward, Path = Path, Key = G.Key, Epoch = G.Epoch }
    return false
end

-- Host (W.Later, 1,3 s nach MC_CrateOpen wie Delay @0727): L_003b per UB-Einsprung (oder schon vom Spiel gespawnt,
-- L.Spawned), Pickup replizieren, XP
function W.CrateReward(L)
    local O = W.Obj(L.Path)
    if not O then return Log("Kiste %s: weg vor der Belohnung", W.Short(L.Path)) end
    local G = Net.Guests[L.Key]
    G = G and G.Epoch == L.Epoch and G or nil
    local Pawn = G and W.GuestPawn(G)
    if Pawn then pcall(function() O:SetOwner(Pawn) end) end
    local X, Y, Z = W.SceneLoc(O)
    local Before = L.Before
    if not L.Spawned then
        Before = {}
        for Ad in pairs(W.PickupsNear(X, Y, Z, false)) do Before[Ad] = true end
        local ok, err = pcall(function() O:ExecuteUbergraph_BP_GuaranteedSpawner(W.CRATE_UB_REWARD) end)
        if not ok then
            Core.Fail("world_crate", err)
            return Log("Kiste %s: Belohnung fehlgeschlagen (%s)", W.Short(L.Path), tostring(err))
        end
    end
    local New
    for Ad, P in pairs(W.PickupsNear(X, Y, Z, false)) do if not Before[Ad] then New = P end end
    if New and not Try(function() return New.bReplicates end, false) then
        pcall(function()
            New:SetReplicates(true)
            New:SetReplicateMovement(true)
            New:ForceNetUpdate()
        end)
    end
    local PC = G and Net.PC(G)
    local PS = PC and Try(function() local C = PC.PassiveSkillsComponent if A.IsAlive(C) then return C end end)
    local V = 4 + math.random() * 2
    if PS and pcall(function() PS:AddXP_Scavenging(V) end) then
        Log("XP von %s uebernommen: Kiste (Fertigkeit) +%.1f", G.GuestId or G.Key, V)
    end
    Log("Kiste %s: Belohnung fuer %s gespawnt%s", W.Short(L.Path), G and (G.GuestId or G.Key) or "?",
        New and "" or " (Pickup nicht gefunden)")
end

-- Host (0,25 s): Anfragen, verzoegerte Aufrufe (W.Later), Owner nach 'gone' loesen
function W.CrateHost(Now)
    local Q = W.CrateQ
    W.CrateQ = {}
    if not On("world_crate") then Q = {} end
    local Retry = {}
    for I, R in ipairs(Q) do
        if I > 4 then W.CrateQ[#W.CrateQ + 1] = R
        else
            local ok, Again = pcall(W.CrateHostOne, R, Now)
            if not ok then Core.Fail("world_crate", Again)
            elseif Again then Retry[#Retry + 1] = R end
        end
    end
    -- erneut zu pruefende Anfragen hinten anstellen, damit neuere nicht verhungern
    for _, R in ipairs(Retry) do W.CrateQ[#W.CrateQ + 1] = R end
    local L, Busy = W.Later, {}
    W.Later = {}
    for _, E in ipairs(L) do
        if Now >= E.At then
            local ok, err = pcall(E.Fn, E, Now)
            if not ok then Core.Fail(E.Flag or "world_crate", err) end
        else
            W.Later[#W.Later + 1] = E
            if E.Path then Busy[E.Path] = true end
        end
    end
    if not next(W.CrateGone) then return end
    local Left = {}
    for Path, K in pairs(W.CrateOwn) do
        if W.CrateGone[K] then
            if Busy[Path] then Left[K] = true
            else
                local O = W.Obj(Path)
                if O then pcall(function() O:SetOwner(nil) end) end
                W.CrateOwn[Path] = nil
            end
        end
    end
    W.CrateGone = Left
end

function W.CrateTick(Now)
    if Net.Side == "client" then W.CrateClient(Now) elseif Net.Side == "host" then W.CrateHost(Now) end
end

-- Host (5 s, nach Oeffnen sofort): Opened ist nicht repliziert und der Deckel (Svr_CrateOpen, NetServer, ueber
-- MC_CrateOpen L_05af) kommt bei Gaesten nie an -> Keyed-State w_cst "Cls@x,y,z" = "1;<n>", sobald ALLE n Kopien am
-- Ort (<= 40 uu, gleiche Klasse) offen sind (eine fremde ungeoeffnete Kopie bleibt fuer ihren Halter oeffenbar), sonst
-- geloescht (neue Kopie, Kiste weg, Weltwechsel)
function W.CstHost(Now)
    if Now < (W.CstAt or 0) then return end
    W.CstAt = Now + 5
    local Want, Groups = {}, {}
    if On("world_crate") and #W.Guests("wcrate") > 0 then
        for _, P in ipairs(W.CrateListGet(Now)) do
            local O = W.Obj(P)
            local C = O and Try(function() return O:GetClass():GetFName():ToString() end)
            if C then pcall(function()
                local X, Y, Z = W.Loc(O)
                local Op = O.Opened == true
                for _, Gr in ipairs(Groups) do
                    if Gr.C == C and W.Dist2(X, Y, Z, Gr.X, Gr.Y, Gr.Z) <= 40 ^ 2 then
                        Gr.N, Gr.Open = Gr.N + 1, Gr.Open and Op
                        if P < Gr.P then Gr.P, Gr.K = P, { X, Y, Z } end
                        return
                    end
                end
                Groups[#Groups + 1] = { C = C, P = P, X = X, Y = Y, Z = Z, K = { X, Y, Z }, N = 1, Open = Op }
            end) end
        end
        for _, Gr in ipairs(Groups) do
            if Gr.Open then
                Want[string.format("%s@%d,%d,%d", Gr.C, math.floor(Gr.K[1] + 0.5), math.floor(Gr.K[2] + 0.5),
                    math.floor(Gr.K[3] + 0.5))] = "1;" .. Gr.N
            end
        end
    end
    for K, V in pairs(Want) do if W.CstPub[K] ~= V then Net.State("w_cst", K, V, 1) end end
    for K in pairs(W.CstPub) do if not Want[K] then Net.State("w_cst", K, nil) end end
    W.CstPub = Want
end

-- Gast: eine Kiste als offen uebernehmen: Opened = true (OnExecuteInteract L_0e1d, OnStopExecuteInteract @09d3/@0aee
-- sperren dann wie in SP) und Deckel-Endpose per Timeline-Position (Update L_0e2c; FinishedFunc @0010 bei Opened leer)
-- Rueckgabe: Anzahl uebernommen (0/1), erledigt (true = Pfad in W.CstDone)
function W.CstApply(O)
    local P = Try(function() return W.Path(O) end)
    if not P then return 0, false end
    if W.CstDone[P] then return 0, true end
    local TL = Try(function() local T = O.Timeline if A.IsAlive(T) then return T end end)
    if TL and Try(function() return TL:IsPlaying() end, true) then return 0, false end
    local ok = pcall(function() O.Opened = true end)
    if TL then pcall(function() TL:SetPlaybackPosition(TL:GetTimelineLength(), false, true) end) end
    W.CstDone[P] = true
    return ok and 1 or 0, true
end

-- Gast (1 s, bei neuem Schluessel sofort): w_cst anwenden, nur wenn genau n Kopien am Ort stehen (sonst ist eine neue,
-- noch ungeoeffnete dabei), nicht <= 1 s nach der eigenen Meldung; geloeschte und vollstaendig angewendete Schluessel
-- fallen weg (ein spaeter neu gesetzter Wert kommt per w_cst-Handler wieder rein). Kisten-Orte einmal je Klasse und Lauf.
function W.CstClient(Now)
    if not next(W.CstWant) or Now < (W.CstAt or 0) then return end
    W.CstAt = Now + 1
    if not On("world_crate") or not Net.Has("wcrate") then return end
    local ByCls, N = {}, 0
    for Key in pairs(W.CstWant) do
        local C, X, Y, Z = Key:match("^([%w_]+)@([%-%d]+),([%-%d]+),([%-%d]+)$")
        local Cnt = tonumber(tostring(Net.Get("w_cst", Key) or ""):match("^1;(%d+)$") or "")
        if not C or not W.QC.CRATE[C] or not Cnt then
            W.CstWant[Key] = nil
        else
            X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
            if not ByCls[C] then
                local L = {}
                for _, O in ipairs(FindAllOf(C) or {}) do
                    if A.IsAlive(O) and Try(function() return O:GetClass():GetFName():ToString() end) == C then
                        local Pos = Try(function() return { W.Loc(O) } end)
                        if Pos and Pos[3] then L[#L + 1] = { O, Pos[1], Pos[2], Pos[3] } end
                    end
                end
                ByCls[C] = L
            end
            local Near, Mine = {}, false
            for _, E in ipairs(ByCls[C]) do
                if W.Dist2(X, Y, Z, E[2], E[3], E[4]) <= 40 ^ 2 then Near[#Near + 1] = E[1] end
            end
            for _, Win in ipairs(W.CrateWin) do
                if Now < Win.Until - 2 and W.Dist2(X, Y, Z, Win[1], Win[2], Win[3]) <= 300 ^ 2 then Mine = true end
            end
            if #Near == Cnt and not Mine then
                local All = true
                for _, O in ipairs(Near) do
                    local K, Done = W.CstApply(O)
                    N = N + K
                    if not Done then All = false end
                end
                if All then W.CstWant[Key] = nil end
            end
        end
    end
    if N > 0 then Log("Kiste: %d als geoeffnet vom Host uebernommen", N) end
end

function W.CstTick(Now)
    if Net.Side == "host" then W.CstHost(Now) elseif Net.Side == "client" then W.CstClient(Now) end
end

-- Host: BP_POIManager zur Kiste: .Container (@24a0, nur POICrate) per Adresse, sonst ContainerLocation (+ Actor-Ort,
-- wie @22ce-@2346; Compound-Zweig @2067-@221f setzt .Container NICHT) <= 300 uu
function W.PoiMgrMatch(Paths, CA, X, Y, Z)
    local Best, BestP, BestD = nil, nil, 300 ^ 2
    for _, P in ipairs(Paths or {}) do
        local Mgr = W.Obj(P)
        if Mgr then
            local C = Try(function() return Mgr.Container end)
            if CA and Alive(C) and W.Addr(C) == CA then return Mgr, P end
            local D = Try(function()
                local T = Mgr.ContainerLocation.Translation
                local MX, MY, MZ = W.Loc(Mgr)
                return W.Dist2(X, Y, Z, MX + T.X, MY + T.Y, MZ + T.Z)
            end)
            if D and D <= BestD then Best, BestP, BestD = Mgr, P, D end
        end
    end
    return Best, BestP
end

-- Export A.Coop.World.PoiCrateLooted (Host, Aufrufer ls_inv inv_scav): true = XP/Status fuer den Gast gebucht
function W.PoiCrateLooted(G, CratePath)
    if Net.Side ~= "host" or not On("world_poicrate") or type(G) ~= "table" then return false end
    local Crate = W.Obj(CratePath)
    if not Crate then return false end
    local CA, Now = W.Addr(Crate), os.clock()
    local X, Y, Z = W.Loc(Crate)
    local Mgr, MPath = W.PoiMgrMatch(W.Paths["BP_POIManager_C"], CA, X, Y, Z)
    if not Mgr and Now - (W.PoiMgrAt or -10) >= 1 then
        W.PoiMgrAt = Now
        local L = {}
        for _, O in ipairs(FindAllOf("BP_POIManager_C") or {}) do
            if A.IsAlive(O) then L[#L + 1] = Try(function() return W.Path(O) end) end
        end
        Mgr, MPath = W.PoiMgrMatch(L, CA, X, Y, Z)
    end
    if not Mgr then
        W.LogOnce("pc" .. tostring(CratePath), "POI-Kiste %s: kein POI-Manager gefunden", W.Short(CratePath))
        return false
    end
    if Try(function() return Mgr["UniqueContainerLooted?"] end, false) == true then return false end
    local Pawn = W.GuestPawn(G)
    if not Pawn then return false end
    -- Owner = Gast nur fuer den Aufruf: Event_Looted (5.6 @281d -> L_26c0..@2751) ist synchron. Bliebe der Gast Owner,
    -- loeste der Host-DistanceCheck-Timer (Explored? am Host false) GetPlayerCharacter/GetLevellingComponent auf ihn
    -- auf und buchte die POI-XP (@0140/@01f7) ein zweites Mal (schon per w_poi -> W.PoiXp)
    pcall(function() Mgr:SetOwner(Pawn) end)
    local ok, err = pcall(function() Mgr:Event_Looted() end)
    if A.IsAlive(Mgr) then pcall(function() Mgr:SetOwner(nil) end) end
    W.CrateOwn[MPath] = nil
    if not ok then Core.Fail("world_poicrate", err) return false end
    Log("POI-Kiste %s: XP und Status fuer %s", W.Short(CratePath), G.GuestId or G.Key)
    return true
end

-- ------------------------------------------------------------------------------------------- Netz-Handler

M.Handlers = {
    -- Host <- Gast
    w_sleep = function() end,                                     -- Keyed-State, Host liest per Net.Get
    w_tech = function(Value, G)
        if Net.Side ~= "host" or not On("world_tech") or not G.GuestId or not Value then return end
        if not Value:match("^[%w_,%-]*$") or #Value > 8000 then return Net.SecWarn(G, G.Key, "w_tech") end
        -- Nur vormerken; W.TechHostTick prueft Kosten gegen die Server-Skillpunkte und wendet auf die Server-Kopie an
        W.TechPend = W.TechPend or {}
        W.TechPend[G.GuestId] = { Key = G.Key, List = Value == "-" and "" or Value, At = os.clock() }
    end,
    w_poi = function(Value, G, Msg)
        if Net.Side ~= "host" or not On("world_poi") or not G.GuestId or Value ~= "1" then return end
        local Name = tostring(Msg.Key or "")
        if not Name:match("^[%w_]+$") or #Name > 120 then return Net.SecWarn(G, G.Key, "w_poi") end
        -- Nur vormerken; W.PoiFlush prueft gegen bekannte POI-Actors und schreibt gesammelt (hoechstens alle 5 s)
        W.PoiPend = W.PoiPend or {}
        local P = W.PoiPend[G.GuestId] or { N = 0 }
        W.PoiPend[G.GuestId] = P
        if P[Name] then return end
        if P.N >= 500 then return Net.SecWarn(G, G.Key, "w_poi_flut") end
        P[Name], P.N = os.clock(), P.N + 1
        -- POI-XP (W.PoiXp): Ort der Gast-Figur beim Melden fuer die Naehe-Pruefung
        local Pawn = On("world_xp") and W.GuestPawn(G)
        if Pawn then
            local X, Y, Z = W.Loc(Pawn)
            W.PoiPos = W.PoiPos or {}
            W.PoiPos[G.GuestId .. "|" .. Name] = { X, Y, Z, Key = G.Key }
        end
    end,
    -- Gast-lokale XP-Quelle: "craft|<Widget-Klasse>|<Anzahl>", "book|<ItemId>" (alt "book|1"), "fish|s|r|l" (W.XpHost)
    w_xp = function(Data, G)
        if Net.Side ~= "host" or not On("world_xp") or not G.GuestId then return end
        local K, Rest = tostring(Data or ""):match("^(%a+)|(.*)$")
        if not K or K == "poi" or not W.XP_SRC[K] or #Rest > 80 then return Net.SecWarn(G, G.Key, "w_xp") end
        local ok, err = pcall(W.XpHost, G, K, Rest, os.clock())
        if not ok then Core.Fail("w_xp", err) end
    end,
    w_harvq = function(Data, G)
        if Net.Side ~= "host" or not On("world_harvest") then return end
        -- WORLD-22 (world_harvq_guard): Relay bewiesen -> nicht noetig; Drossel 2/s, 60/min
        if Core.Flag("world_harvq_guard", true) then
            local okG, Why = pcall(W.HarvqGuard, G)
            if not okG then Core.Fail("world_harvq_guard", Why)
            elseif Why then return Net.SecWarn(G, G.Key, Why) end
        end
        -- "Mesh|X|Y|Z" (alt) oder mit "|Pitch|Yaw|Roll|SX|SY|SZ"
        Data = tostring(Data)
        local Mesh, X, Y, Z, Rest = Data:match("^(/Game/[^|]+)|([%-%d]+)|([%-%d]+)|([%-%d]+)(.*)$")
        local Pawn = W.GuestPawn(G)
        if not Mesh or not Pawn or #Data > 400 or not Rest:match("^[%-%d%.|]*$") then
            return Net.SecWarn(G, G.Key, "w_harvq")
        end
        X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
        if W.Dist2(X, Y, Z, W.Loc(Pawn)) > 1500 ^ 2 then return Net.SecWarn(G, G.Key, "w_harvq_dist") end
        local Key = W.LocKey(X, Y, 50)
        if W.HarvDone[Key] then return end
        W.HarvDone[Key], W.HarvSeen[Key] = true, true
        pcall(W.HarvApply, Data, os.clock())
        W.HarvRecord(Key, Data)
        W.HarvPub(Key, Data)
    end,
    -- Gast hat einen Schrotthaufen geborgen: "X|Y|Z"
    w_scrap = function(Data, G)
        if Net.Side ~= "host" or not On("world_scrap") or Core.Down.w_scrap then return end
        local X, Y, Z = tostring(Data):match("^([%-%d]+)|([%-%d]+)|([%-%d]+)$")
        if not X then return Net.SecWarn(G, G.Key, "w_scrap") end
        local ok, err = pcall(W.ScrapHost, G, tonumber(X), tonumber(Y), tonumber(Z), os.clock())
        if not ok then Core.Fail("w_scrap", err) end
    end,
    -- Gast hat eine BP_GuaranteedSpawner-Kiste geoeffnet: "BP_GuaranteedSpawner_C|x|y|z" (nur einreihen, W.CrateHost)
    w_crate = function(Data, G)
        if Net.Side ~= "host" or not On("world_crate") or not G or not G.Epoch then return end
        Data = tostring(Data)
        local X, Y, Z = Data:match("^BP_GuaranteedSpawner_C|([%-%d]+)|([%-%d]+)|([%-%d]+)$")
        if not Z or #Data > 80 then return Net.SecWarn(G, G.Key, "w_crate_bad") end
        local Now = os.clock()
        if not W.CrateRate(G, Data, Now) then return Net.SecWarn(G, G.Key, "w_crate_rate") end
        X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
        -- nur mit passendem Halte-Start (w_crateh kommt vorher, gleiche Koordinaten) und hoechstens 2 offene Anfragen je
        -- Gast: sonst fuellt ein Gast die gemeinsame Warteschlange und fremde Kisten-Belohnungen fallen weg
        local H = W.CrateHold[G.Key]
        if not H or H.Epoch ~= G.Epoch or W.Dist2(X, Y, Z, H.X, H.Y, H.Z) > 300 ^ 2 then
            Log("Kiste bei %.0f,%.0f,%.0f: kein Halte-Start von Gast %s -> nicht eingereiht", X, Y, Z, G.GuestId or G.Key)
            return Net.SecWarn(G, G.Key, "w_crate_nohold")
        end
        local Mine = 0
        for _, R in ipairs(W.CrateQ) do if R.Key == G.Key then Mine = Mine + 1 end end
        if Mine >= 2 then return Net.SecWarn(G, G.Key, "w_crate_full") end
        if #W.CrateQ < 20 then
            W.CrateQ[#W.CrateQ + 1] = { Key = G.Key, Epoch = G.Epoch, X = X, Y = Y, Z = Z, At = Now }
        else
            Log("Kisten-Warteschlange voll -> Anfrage von Gast %s verworfen", G.GuestId or G.Key)
        end
    end,
    -- Gast beginnt eine BP_GuaranteedSpawner-Kiste zu halten: "BP_GuaranteedSpawner_C|x|y|z" (Start fuer w_crate)
    w_crateh = function(Data, G)
        if Net.Side ~= "host" or not On("world_crate") or not G or not G.Epoch then return end
        Data = tostring(Data)
        local X, Y, Z = Data:match("^BP_GuaranteedSpawner_C|([%-%d]+)|([%-%d]+)|([%-%d]+)$")
        if not Z or #Data > 80 then return Net.SecWarn(G, G.Key, "w_crateh_bad") end
        local Now = os.clock()
        if not W.CrateRate(G, "h" .. Data, Now) then return Net.SecWarn(G, G.Key, "w_crateh_rate") end
        X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
        -- Halte-Start nur von einem lebenden Gast-Pawn <= 1000 uu an der Kiste (wie ai_tdis '|s'): sonst Fern-Start
        -- unterwegs und w_crate bei Ankunft ohne Halten
        local Pawn = W.GuestPawn(G)
        if not Pawn or Try(function() return Pawn["PlayerDead?"] end, false) == true then return end
        local PD = Try(function() return W.Dist2(X, Y, Z, W.Loc(Pawn)) end)
        if not PD or PD > 1000 ^ 2 then
            Log("Kisten-Halte-Start bei %.0f,%.0f,%.0f zu weit vom Gast %s -> verworfen", X, Y, Z, G.GuestId or G.Key)
            return Net.SecWarn(G, G.Key, "w_crateh_dist")
        end
        local H = W.CrateHold[G.Key]
        -- erneutes Druecken an derselben Kiste: Fortschritt bleibt im Widget (PauseInteract) -> fruehesten Start behalten
        if H and H.Epoch == G.Epoch and Now - H.At < 60 and W.Dist2(X, Y, Z, H.X, H.Y, H.Z) <= 300 ^ 2 then return end
        W.CrateHold[G.Key] = { X = X, Y = Y, Z = Z, At = Now, Epoch = G.Epoch }
    end,
    -- Gast <- Host
    w_sky = function() end,
    w_bmoon = function() end,
    w_cfg = function() end,
    w_well = function() W.WellDirty = true end,
    w_harv = function(Value, _, Msg)
        -- Nur der Gast leert HarvQueue/HarvKeys; beim Host wuerden die Tabellen endlos wachsen
        if Net.Side ~= "client" or not Msg.Key then return end
        if Value then W.HarvQueue[Msg.Key], W.HarvKeys[Msg.Key] = true, true
        else W.HarvQueue[Msg.Key], W.HarvKeys[Msg.Key] = nil, nil if W.HarvSig then W.HarvSig[Msg.Key] = nil end if W.HarvCur then W.HarvCur[Msg.Key] = nil end end
    end,
    -- Keyed-State: geborgene Schrotthaufen (Schluessel LocKey 50, Wert "X|Y|Z")
    w_scrapd = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg.Key then return end
        W.ScrapDone[Msg.Key] = Value and true or nil
        if Value then W.ScrapDirty = true end
    end,
    -- Keyed-State: BP_GuaranteedSpawner offen ("Cls@x,y,z" = "1;<Kopien>"); nur merken, anwenden in W.CstClient
    w_cst = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key or not Value then return end
        local K = tostring(Msg.Key)
        if #K <= 120 then W.CstWant[K], W.CstAt = true, 0 end
    end,
    w_inf = function(Value, _, Msg)
        if Net.Side ~= "client" or not On("world_infest") or Value ~= "1" then return end
        local Inf = W.Obj(Msg.Key)
        if Inf and not Try(function() return Inf["IsDestroyed?"] end, true) then
            local ok = pcall(function() Inf:Event_OnDestroyed(nil, true) end)
            if ok then pcall(function() Inf["IsDestroyed?"] = true end) end
        end
    end,
    w_techset = function(Data)
        if Net.Side ~= "client" or not On("world_tech") then return end
        W.TechApply(tostring(Data or ""), os.clock())
    end,
    w_poiset = function(Data)
        if Net.Side ~= "client" or not On("world_poi") then return end
        W.PoiWant = W.SetOf(Data)
    end,
    -- WORLD-4 (Keyed-State K18): Fundort-Marker des Hosts; nur merken, anwenden in W.PrefabMarkClient
    w_pfm = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        local K = tostring(Msg.Key)
        if #K > 40 or (Value and #tostring(Value) > 600) then return end
        W.PfmWant[K] = Value
        W.PfmDirty = true
    end,
    -- WORLD-5 (K19/K20): schon entdeckte Fundorte (Liste beim Bereitwerden, einzelne bei Entdeckung)
    w_pfset = function(Data)
        if Net.Side ~= "client" or #tostring(Data or "") > 60000 then return end
        W.PfxSet = W.SetOf(Data)
        W.PfmDirty = true
    end,
    w_pfd = function(Data)
        if Net.Side ~= "client" or type(Data) ~= "string" or #Data > 40 then return end
        W.PfxSet = W.PfxSet or {}
        W.PfxSet[Data] = true
        W.PfmDirty = true
    end,
    -- WORLD-13 (K21): Aussehen nach dem Barbier dauerhaft am Server (Gast-Spielstand wird im MP nie geschrieben)
    w_look = function(Data, G)
        if Net.Side ~= "host" or not On("world_look") or not G or not G.GuestId then return end
        Data = tostring(Data or "")
        if #Data == 0 or #Data > 4000 or Data:find("%c") or not Data:match("^[%w_]+=") then
            return Net.SecWarn(G, G.Key, "w_look")
        end
        -- Review 2: nichts verwerfen (zweiter Barbier-Besuch binnen 10 s ging verloren und das alte Aussehen kam beim
        -- naechsten ready zurueck). Neuestes je Gast vormerken; W.LookFlush schreibt hoechstens 1x je 10 s je Gast
        W.LookPend = W.LookPend or {}
        W.LookPend[G.GuestId] = Data
        W.LookFlush(os.clock())
    end,
    -- WORLD-13 (K22): gespeichertes Aussehen vom Host; anwenden in W.LookClient (wartet auf Figur/Spielstand)
    w_lookset = function(Data)
        if Net.Side ~= "client" or not On("world_look") or type(Data) ~= "string" or #Data > 4000 then return end
        W.LookWant, W.LookTry = Data, 0
    end,
    w_note = function(Data) if Net.Side == "client" then pcall(A.ShowNote, tostring(Data)) end end,
    -- WORLD-26 (Keyed-State K25): Tooltip-Stand eines POI "<BossesDefeated>|<0/1>"; nur merken, anwenden in W.PoiStClient
    w_poist = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg or not Msg.Key then return end
        local K = tostring(Msg.Key)
        if #K > 120 or (Value and not tostring(Value):match("^%d+|[01]$")) then return end
        W.PoiStWant = W.PoiStWant or {}
        W.PoiStWant[K] = Value
        if not Value and W.PoiStDone then W.PoiStDone[K] = nil end
        W.PoiStDirty = true
    end,
    -- WORLD-14 (K23): Gast hat einen Hund gestreichelt "x|y|z" (nur pruefen/einreihen, W.PetTick)
    w_pet = function(Data, G)
        if Net.Side ~= "host" or not On("world_dogpet") or not G or not G.Epoch or not Net.Has("wpet", G) then return end
        local X, Y, Z = tostring(Data):match("^(%-?%d+)|(%-?%d+)|(%-?%d+)$")
        if not Z or #tostring(Data) > 60 then return Net.SecWarn(G, G.Key, "w_pet") end
        local Now = os.clock()
        W.PetAt = W.PetAt or {}
        if Now - (W.PetAt[G.Key] or -100) < 3 then return Net.SecWarn(G, G.Key, "w_pet_rate") end
        W.PetAt[G.Key] = Now
        if #W.PetQ < 8 then
            W.PetQ[#W.PetQ + 1] = { Key = G.Key, Epoch = G.Epoch, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), At = Now }
        end
    end,
    -- WORLD-14 (K24): fremde Figur streichelt einen Hund "PlayerId|x|y|z" (nur einreihen, W.PetTick spielt ab)
    w_petfx = function(Data)
        if Net.Side ~= "client" or not On("world_dogpet") then return end
        local Pid, X, Y, Z = tostring(Data):match("^(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
        if not Z or #W.PetFx >= 8 then return end
        W.PetFx[#W.PetFx + 1] = { Pid = Pid, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), At = os.clock() }
    end,
    w_slept = function()
        if Net.Side ~= "client" then return end
        W.SleepUntil = nil
        Net.State("w_sleep", "on", "0", 1)
    end,
    -- Quests (Runde 7). Host <- Gast: Gespraech "Klasse|FName oder -|X|Y|Z"
    q_talk = function(Data, G)
        if Net.Side ~= "host" or not W.Q2("quest_talk") or not Net.Has("qst2", G) then return end
        local Cls, Name, X, Y, Z = tostring(Data):match("^([%w_]+)|([^|]+)|([%-%d]+)|([%-%d]+)|([%-%d]+)$")
        if not Cls or #tostring(Data) > 300 then return Net.SecWarn(G, G.Key, "q_talk") end
        -- CORE-14 (untrusted_paths): Gast-Klassenname geht in FindAllOf (W.FindNPC) -> nur Gespraechspartner-Klassen
        if Core.Flag("untrusted_paths", true) and not W.TalkClsOk(Cls) then return Net.SecWarn(G, G.Key, "q_talk_cls") end
        local Now = os.clock()
        W.TalkAt = W.TalkAt or {}
        if Now - (W.TalkAt[G.Key] or -10) < 0.8 then return Net.SecWarn(G, G.Key, "q_talk_rate") end
        W.TalkAt[G.Key] = Now
        if #W.TalkQ < 20 then
            W.TalkQ[#W.TalkQ + 1] = { Key = G.Key, Cls = Cls, Name = Net.Dec(Name), X = tonumber(X), Y = tonumber(Y),
                                      Z = tonumber(Z), At = Now }
        end
        W.TalkQTick(Now)
    end,
    -- WORLD-1: Gast hat einen Military-Intel-Laptop gescannt ("1"); nur einreihen, W.LapScanTick bucht
    q_lapscan = function(Data, G)
        if Net.Side ~= "host" or not W.Q2("quest_laptopscan") or not G or not G.Epoch or not Net.Has("qls1", G) then return end
        if Data ~= "1" then return Net.SecWarn(G, G.Key, "q_lapscan") end
        local Now = os.clock()
        W.LapScanQ = W.LapScanQ or {}
        if Core.Flag("world_lapscan_queue", true) then
            -- Review 2: jeder Scan hat am Server schon verbraucht (ContextScanLaptop @00ee) -> einreihen statt 5-s-Drop;
            -- hoechstens 3 offene je Gast, 20 gesamt. Drossel ohne Ledger-Nachweis macht W.LapScanTick
            local Mine = 0
            for _, J in ipairs(W.LapScanQ) do if J.Key == G.Key then Mine = Mine + 1 end end
            if Mine >= 3 or #W.LapScanQ >= 20 then return Net.SecWarn(G, G.Key, "q_lapscan_rate") end
        else
            W.LapScanRate = W.LapScanRate or {}
            if Now - (W.LapScanRate[G.Key] or -100) < 5 then return Net.SecWarn(G, G.Key, "q_lapscan_rate") end
            W.LapScanRate[G.Key] = Now
            if #W.LapScanQ >= 20 then return end
        end
        W.LapScanQ[#W.LapScanQ + 1] = { Key = G.Key, Epoch = G.Epoch, T0 = Now }
    end,
    -- Gastlokaler Quest-Aufruf "Task|Arg|Menge|Klasse|x,y,z"
    q_task = function(Data, G)
        if Net.Side ~= "host" or not W.Q2("quest_gtask") or not Net.Has("qst2", G) then return end
        local ok, err = pcall(W.GTaskHost, G, Data, os.clock())
        if not ok then Core.Fail("quest_gtask", err) end
    end,
    -- Journal "Vergessen": Quest-Klassenpfad
    q_forget = function(Data, G)
        if Net.Side ~= "host" or not W.Q2("quest_forget") or not Net.Has("qst2", G) then return end
        local ok, err = pcall(W.ForgetHost, G, Data, os.clock())
        if not ok then Core.Fail("quest_forget", err) end
    end,
    q_cli = function() end,                                       -- Keyed-State (lev), Host liest per Net.Get
    -- Gast <- Host: Hinweis (laptop_done); der lokale Laptop-Event zeigt seinen Text schon selbst -> dann nicht doppelt
    q_note = function(Data)
        if Net.Side ~= "client" then return end
        if Data == "laptop_done" then
            -- WORLD-1: mit unterdruecktem CallRandomEvent kommt der Text (@0369) nur noch vom Host
            if W.LapWatchOn or os.clock() - (W.LapLocalAt or -100) > 5 then pcall(A.ShowNote, W.QC.LAPTOP_DONE) end
            Log("Host: alle Laptop-Quests erledigt")
        end
    end,
}

-- Gast: POI-Stand vom Host anwenden (Explored? setzen, DistanceCheck stoppen -> kein doppeltes XP)
function W.PoiApply()
    if not W.PoiWant then return end
    local Want, N = W.PoiWant, 0
    W.PoiWant = nil
    local KSL = W.KSL()
    local Mark = Core.Flag("world_poi_mark", true)
    W.Each("BP_POIManager_C", function(P)
        local Name = W.PoiKey(P)
        if Want[Name] then
            W.PoiSent[Name] = true
            if not P["Explored?"] then
                P["Explored?"] = true
                pcall(function() KSL:K2_ClearTimer(P, "DistanceCheck") end)
                N = N + 1
                -- WORLD-9 (world_poi_mark): Karten-Marker wie nach dem Laden nachziehen (ActorLoaded @285e -> Delay 5 ->
                -- @168c POIExplored.Broadcast + Tooltips). Nicht bei gepluenderter Spezialkiste (@19c2 zerstoert Container)
                if Mark and Try(function() return P["UniqueContainerLooted?"] end, false) ~= true then
                    local ok, err = pcall(function() P:ActorLoaded() end)
                    if not ok then Core.Fail("world_poi_mark", err) Mark = false end
                end
            end
        end
    end)
    W.PoiApplied = true
    Log("POI vom Host: %d als erkundet gesetzt%s", N, (N > 0 and Mark) and " (Karten-Marker nachgezogen)" or "")
end

-- WORLD-26 Gast (1 s, nur bei neuem Host-Stand): BossesDefeated/UniqueContainerLooted? vom Host setzen und die Tooltips
-- per ActorLoaded neu zeichnen (@16e4 Boss-Anzahl, @19c2 Kisten-Text). Eine noch stehende replizierte Kiste (Container,
-- Rolle Proxy) wuerde @1a87 zerstoert -> dann erst, wenn sie weg ist (eigene Laufzeit-Kopien raeumt W.LayoutClient ohnehin)
function W.PoiStClient(Now)
    if Net.Side ~= "client" or not (On("world_poi_tip") and Net.Has("wpoi2")) then return end
    -- alle 30 s erneut (POIs, die erst spaeter gestreamt werden)
    if Now >= (W.PoiStAgain or 0) and next(W.PoiStWant or {}) then W.PoiStDirty, W.PoiStAgain = true, Now + 30 end
    if not W.PoiStDirty or Now < (W.PoiStAt or 0) then return end
    W.PoiStDirty, W.PoiStAt = false, Now + 2
    W.PoiStDone = W.PoiStDone or {}
    local Wait = false
    W.Each("BP_POIManager_C", function(P)
        local K = W.PoiKey(P)
        local V = K and W.PoiStWant and W.PoiStWant[K]
        if not V or W.PoiStDone[K] == V then return end
        local B, U = V:match("^(%d+)|([01])$")
        if not B then W.PoiStDone[K] = V return end
        if U == "1" then
            local C = Try(function() local O = P.Container if Alive(O) then return O end end)
            if C and W.Role(C) ~= 3 then Wait = true return end
        end
        B = tonumber(B)
        if Try(function() return P.BossesDefeated end) ~= B then pcall(function() P.BossesDefeated = B end) end
        if U == "1" then pcall(function() P["UniqueContainerLooted?"] = true end) end
        W.PoiStDone[K] = V
        local ok, err = pcall(function() P:ActorLoaded() end)
        if not ok then Core.Fail("w_poist_cli", err) end
    end)
    if Wait then W.PoiStDirty, W.PoiStAt = true, Now + 10 end
end

-- ------------------------------------------------------------------------------------------- Ereignisse

function W.OnReady(G)
    if Net.Side ~= "host" then return end
    W.QState = W.QState or {}
    -- ready kommt nach jedem Respawn erneut; NarrativeComponent sitzt am Controller -> Stand behalten, nicht neu laden
    local Old = W.QState[G.Key]
    if not (Old and (Old.GuestId == nil or G.GuestId == nil or Old.GuestId == G.GuestId)) then
        W.QState[G.Key] = { LoadAt = os.clock() + 3, GuestId = G.GuestId }
    end
    -- Closeout (world_lapscan_count): Laptop-Buchung beim ersten ready je Verbindung auf den aktuellen Abnahme-Zaehler
    -- setzen (Abnahmen vor dem Beitritt zaehlen nie). Spaetere ready (Respawn) behalten den Stand; nur ein kleinerer
    -- Zaehler (ls_inv-Stand neu) setzt neu. Ohne Zaehler (alter ls_inv) 0, dann ungenutzt
    if Core.Flag("world_lapscan_count", true) then
        local okL, _, _, N, Nc = pcall(W.LapCons, G)
        local B = W.LapBooked[G.Key]
        N = okL and type(N) == "number" and N or nil
        if B == nil or (N and N < B) then W.LapBooked[G.Key] = N or 0 end
        -- Closeout 2: Proven-Buchungen (nur Abnahmen ohne offene Kiste/Haendler) genauso starten
        Nc = okL and type(Nc) == "number" and Nc or nil
        local BC = W.LapBookedC[G.Key]
        if BC == nil or (Nc and Nc < BC) then W.LapBookedC[G.Key] = Nc or 0 end
    end
    if not G.GuestId then return end
    local R = W.Rec(G.GuestId)
    if On("world_tech") and Net.Has("wtech", G) then Net.Send("w_techset", R.tech or "?", G, 1) end
    -- Server-Kopie des Gast-Controllers (neu je Beitritt) auf den bestaetigten Stand bringen (kostenlos, W.TechHost)
    W.TechPend = W.TechPend or {}
    if On("world_tech") and R.tech and not W.TechPend[G.GuestId] then
        W.TechPend[G.GuestId] = { Key = G.Key, List = R.tech, At = os.clock(), Join = true }
    end
    if On("world_poi") and Net.Has("wld2", G) then Net.Send("w_poiset", R.poi or "", G, 2) end
    -- WORLD-5 (K19): entdeckte Fundorte; WORLD-13 (K22): gespeichertes Aussehen
    if On("world_prefabxp") and Net.Has("wpfm", G) then Net.Send("w_pfset", R.pfx or "", G, 2) end
    -- Review 2: noch vorgemerktes Aussehen (10-s-Fenster) zuerst speichern, sonst kaeme nach Respawn/Beitritt das alte
    if W.LookPend and W.LookPend[G.GuestId] then
        local okL, errL = pcall(W.LookFlush, os.clock(), G.GuestId)
        if not okL then Core.Fail("w_look_host", errL) end
        R = W.Rec(G.GuestId)
    end
    if On("world_look") and R.look and Net.Has("wlook", G) then Net.Send("w_lookset", Net.Dec(R.look), G, 1) end
end

-- WORLD-13 Host: vorgemerktes Aussehen (W.LookPend, neuestes je Gast) speichern, je Gast hoechstens 1x je 10 s.
-- Mit Id sofort und nur dieser Gast (W.OnReady). Ohne Id: 1-s-Takt (W.Slow) und direkt aus dem w_look-Empfang
function W.LookFlush(Now, Id)
    if Net.Side ~= "host" or not W.LookPend or next(W.LookPend) == nil then return end
    Now = Now or os.clock()
    W.LookAt = W.LookAt or {}
    for GId, Data in pairs(W.LookPend) do
        if (Id and GId == Id) or (not Id and Now - (W.LookAt[GId] or -100) >= 10) then
            W.LookPend[GId], W.LookAt[GId] = nil, Now   -- vorhandenen Schluessel auf nil setzen ist in pairs erlaubt
            local R, Enc = W.Rec(GId), Net.Enc(Data)
            if R.look ~= Enc then
                R.look = Enc
                W.SaveRec(GId)
                Log("Aussehen von Gast %s gespeichert", GId)
            end
        end
    end
end

function W.OnClientLink()
    W.TechApplied, W.TechSent, W.TechWant, W.PoiApplied, W.PoiWant = false, nil, nil, false, nil
    W.SleepUntil, W.SleepSeen, W.OverCleared, W.SkyFirst, W.SkyLast = nil, W.SleepClick, false, nil, nil
    W.PoiSent, W.HarvSentQ, W.HarvQueue = {}, {}, {}
    W.ScrapSent, W.ScrapDone, W.ScrapDirty = {}, {}, false
    W.LevSent, W.TalkPend, W.TalkLastAddr = nil, nil, nil
    W.XpEv, W.XpAdd, W.XpSentAt = {}, {}, {}
    -- Runde 9: Host-Stand kommt nach dem Handshake neu (Keyed-State voll, w_pfset/w_lookset bei ready)
    W.PfmWant, W.PfxSet, W.PfxWait, W.PfmDirty, W.LookWant = {}, nil, os.clock() + 20, true, nil
    -- world-2: POI-Tooltips (w_poist kommt mit dem Keyed-State neu), Hunde-Effekte
    W.PoiStWant, W.PoiStDone, W.PoiStDirty, W.PetFx, W.PetEv = {}, {}, false, {}, nil
    -- Schonfrist fuer das Nachwachsen beim Gast: erst nach 30 s gelten fehlende w_harv/w_scrapd-Schluessel als geloescht
    W.LinkAt = os.clock()
    if not Net.Has("wld2") then return end
    -- ohne Antwort vom Host nach 20 s: lokal weiter (POI-Meldungen ab dann)
    W.PoiApplyBy = os.clock() + 20
end

-- ------------------------------------------------------------------------------------------- Ticks

-- Teilfunktion mit eigenem Fehlerzaehler (Core.Fail schaltet sie nach wiederholten Fehlern ab)
local function Step(Name, Fn, Now)
    if Core.Down[Name] then return end
    local ok, err = pcall(Fn, Now)
    if not ok then Core.Fail(Name, err) end
end

-- 0,25 s: Safe-Zone (schnell, sonst kurz falscher Zustand bei fremden Overlaps), Schrott-Erkennung beim Gast;
-- 0,5 s: Owner-Polling beim Host (Schrotthaufen, Laptop-Manager)
function W.Fast(Now)
    if W.Busy() or not Net.Side then return end
    W.CheckWorld()
    W.SafeZone()
    Step("w_scrap_cli", W.ScrapClient, Now)
    Step("w_xp_cli", W.XpClient, Now)
    Step("w_crate", W.CrateTick, Now)
    Step("w_cst", W.CstTick, Now)
    Step("w_pet", W.PetTick, Now)
    if Net.Side == "host" then
        Step("w_xp_book", W.XpBookTick, Now)
        Step("w_xp_craft", W.XpCraftTick, Now)
        Step("w_xp_fish", W.FishHostTick, Now)
        Step("q_lapscan", W.LapScanTick, Now)
        Step("q_n8", W.QuestN8, Now)
        Step("q_ev", W.QEvTick, Now)
        Step("q_talkq", W.TalkQTick, Now)
        Step("q_frozen", W.FrozenTick, Now)
        Step("q_taggone", W.TagGoneTick, Now)
    else
        W.FishOn = false
        Step("q_talk_cli", W.TalkClient, Now)
        Step("q_lapscan_cli", W.LapScanClient, Now)
    end
    if Net.Side == "host" and Now >= (W.OwnAt or 0) then
        W.OwnAt = Now + 0.5
        Step("w_scrap_own", W.ScrapOwner, Now)
        Step("w_laptop", W.LaptopOwner, Now)
    end
end

-- 1 s: alles andere
function W.Slow(Now)
    if W.Busy() or not Net.Side then return end
    W.CheckWorld()
    Step("w_sky_host", W.SkyHost, Now)
    Step("w_sky_cli", W.SkyClient, Now)
    Step("w_bmoon", W.BloodMoonClient, Now)
    Step("w_well", W.WellApply, Now)
    Step("w_harv", W.HarvClient, Now)
    Step("w_respawn", W.RespawnHost, Now)
    Step("w_resp_log", W.RespFlush, Now)
    Step("w_poi_flush", W.PoiFlush, Now)
    Step("w_sleep_cli", W.SleepClient, Now)
    Step("w_sleep_host", W.SleepHost, Now)
    Step("w_tech", W.TechClient, Now)
    Step("w_tech_host", W.TechHostTick, Now)
    Step("w_hooks", W.TryHooks, Now)
    Step("w_barber", W.BarberClient, Now)
    Step("w_look_cli", W.LookClient, Now)
    Step("w_look_host", W.LookFlush, Now)
    Step("w_pfx", W.PrefabXpHost, Now)
    Step("w_pfm_cli", W.PrefabMarkClient, Now)
    -- Runde 9 (world-2): Himmel-Zonen (WORLD-10), POI-Tooltips (WORLD-26), Erntekoerper-Gedaechtnis (CORE-30)
    Step("w_skymod_cli", W.SkyModClient, Now)
    Step("w_skymod_host", W.SkyModHost, Now)
    Step("w_poist_cli", W.PoiStClient, Now)
    Step("w_harvprune", W.HarvObjPrune, Now)
    Step("q_area", W.QuestArea, Now)
    Step("q_dialog", W.QuestDialog, Now)
    Step("q_ghost", W.QuestGhost, Now)
    Step("q_share", W.QuestShare, Now)
    Step("q_save", W.QuestSave, Now)
    Step("q_hooks", W.QHookTry, Now)
    Step("q_gwatch", W.GWatch, Now)
    Step("q_gtask", W.GTaskClient, Now)
    Step("q_forget", W.ForgetClient, Now)
    Step("q_twin", W.TwinClient, Now)
    if Net.Side == "client" then
        if W.PoiWant then Step("w_poi_apply", W.PoiApply, Now) end
        if not W.PoiApplied and W.PoiApplyBy and Now > W.PoiApplyBy then W.PoiApplied = true end
    end
end

-- Fuer main.lua: Legacy-Bloecke abschalten, wenn ls_world den Teil uebernimmt (alle Gaeste koennen v3/wld2)
function M.Owns(Part)
    if not Core.Flag("world_v2", true) then return false end
    -- w_sky_host abgeschaltet (Fehlerzaehler): alten Weg (Coop.SkyHostTick) wieder zulassen, sonst gar kein Himmel-Sync
    if Part == "sky" then
        return Core.Flag("world_sky", true) and Net.Enabled() and Net.Has("wld2") and not Core.Down.w_sky_host
    end
    return false
end

function M.Init(Api)
    A = Api
    W.WAS_LOADED = EObjectFlags and EObjectFlags.RF_WasLoaded
    Net.Cap("wld2", Core.Flag("world_v2", true))
    Net.Cap("qst1", Core.Flag("quest_v1", true))
    Net.Cap("qst2", Core.Flag("quest_v1", true) and Core.Flag("quest_v2", true))
    Net.Cap("wtech", Core.Flag("world_v2", true) and Core.Flag("world_tech", true))
    Net.Cap("wscrap", Core.Flag("world_v2", true) and Core.Flag("world_scrap", true))
    Net.Cap("wxp", Core.Flag("world_v2", true) and Core.Flag("world_xp", true))
    -- wcrate nur fuer den Gast-Weg w_crate (Gast loescht seine SP-Belohnung): nur world_crate und nur solange die
    -- Host-Tasks laufen; POI-Kisten brauchen die Cap nicht (ls_inv invx). Nachfuehren in "w_caps" (FLAG_DOWN)
    W.CrateCap = function()
        return On("world_crate") and not Core.Down.w_crate and not Core.Down.w_fast and not Core.Down.net_h_w_crate
            and not Core.Down.net_h_w_crateh and true or false
    end
    Net.Cap("wcrate", W.CrateCap())
    -- Runde 9: qls1 (WORLD-1) faellt weg, wenn Empfaenger/Takt/Unterdrueckung ausgefallen sind (beide Seiten -> SP)
    W.LapCap = function()
        return W.Q2("quest_laptopscan") and not Core.Down.q_lapscan and not Core.Down.q_lapscan_cli
            and not Core.Down.net_h_q_lapscan and not Core.Down.w_fast and not Core.Down.w_watch and true or false
    end
    Net.Cap("qls1", W.LapCap())
    -- Review 2: wpfm heisst "Host veroeffentlicht Marker" (nur world_prefabmark, Scanner nicht ausgefallen). Sonst entfernt
    -- der Gast seine lokalen Marker und bekommt keine. Fund-XP (world_prefabxp, W.Guests("wld2")) braucht die Cap nicht;
    -- w_pfset/w_pfd dienen nur dem Ausblenden der Host-Marker. Nachfuehren in "w_caps"
    W.PfmCap = function()
        return Core.Flag("world_v2", true) and Core.Flag("world_prefabmark", true)
            and not Core.Down["w_scan_BP_PrefabSpawner_C"] and true or false
    end
    Net.Cap("wpfm", W.PfmCap())
    Net.Cap("wlook", Core.Flag("world_v2", true) and Core.Flag("world_look", true))
    -- world-2: POI-Tooltips (K25) und Hund streicheln (K23/K24); wpet faellt weg, wenn Takt/Empfaenger ausgefallen sind
    Net.Cap("wpoi2", Core.Flag("world_v2", true) and Core.Flag("world_poi_tip", true))
    W.PetCap = function()
        return On("world_dogpet") and not Core.Down.w_pet and not Core.Down.w_fast and not Core.Down.net_h_w_pet
            and not Core.Down.net_h_w_petfx and true or false
    end
    Net.Cap("wpet", W.PetCap())
    Core.Every("w_caps", 1, function()
        Net.Cap("wcrate", W.CrateCap())
        Net.Cap("qls1", W.LapCap())
        Net.Cap("wpet", W.PetCap())
        Net.Cap("wpfm", W.PfmCap())
        -- E4 nie stehen lassen, wenn die Angel-Aufgabe ausgefallen ist (ls_inv wuerde sonst jeden Fisch ablehnen)
        if (Core.Down.w_xp_fish or Core.Down.w_fast) and type(A.Coop.World) == "table" then A.Coop.World.FishProof = false end
    end)
    -- DLL-Unterdrueckung (W.WatchTick): eigene Aufgabe, auch ohne Net.Side/Flags (nach dem Verlassen alles aus)
    Core.Every("w_watch_t", 1, function(Now)
        local ok, err = pcall(W.WatchTick, Now)
        if not ok then Core.Fail("w_watch", err) end
    end)
    A.Coop.World = A.Coop.World or {}
    A.Coop.World.PoiCrateLooted = function(G, CratePath)
        local ok, R = pcall(W.PoiCrateLooted, G, CratePath)
        if not ok then Core.Fail("world_poicrate", R) return false end
        return R == true
    end
    -- Export fuer das Nahkampf-Relay (ls_combat, Host): Foliage-Instanz an X/Y/Z suchen, NICHT entfernen.
    -- Rueckgabe Comp, Index oder nil; das UObject gilt nur im Tick des Aufrufers.
    A.Coop.World.HarvFind = function(Mesh, X, Y, Z)
        local ok, C, I = pcall(W.HarvFind, Mesh, X, Y, Z)
        if not ok then Core.Fail("world_harvest", C) return nil end
        return C, I
    end
    -- Export fuer das Nahkampf-Relay (Host): neu gespawnten Erntekoerper sofort per w_harv melden
    A.Coop.World.HarvNow = function()
        local ok, err = pcall(W.HarvNow)
        if not ok then Core.Fail("world_harvest", err) end
    end
    W.SkyNonRep = {}
    for _, F in ipairs(W.UDS) do W.SkyNonRep[F] = true end

    local function Any() return Core.Flag("world_v2", true) or Core.Flag("quest_v1", true) end
    -- Scanner: Klasse, Periode, Seite, Schalter, Funktion, Periode in den ersten 90 s
    W.AddScan("Ultra_Dynamic_Sky_C", 10, "both", function() return On("world_sky") or On("world_bmoon") or On("world_sleep") end,
        function(Objs) if Net.Side == "host" and On("world_sky") then W.SkyReplicate(Objs) end end, 2)
    W.AddScan("Ultra_Dynamic_Weather_C", 10, "both", function() return On("world_sky") end,
        function(Objs) if Net.Side == "host" then W.SkyReplicate(Objs) end end, 2)
    W.AddScan("BP_EventManager_C", 5, "client", function() return On("world_events") or On("world_bmoon") end, W.EventsClient, 2)
    W.AddScan("AirdropAircraft_C", 5, "client", function() return On("world_events") or On("world_layout") end,
        function(Objs, Now) W.AircraftClient(Objs) W.LayoutClient("AirdropAircraft_C")(Objs, Now) end)
    for _, Class in ipairs(W.REP) do
        local Fl = W.REP_FLAG[Class]
        local function RepOn() return On("world_layout") and (not Fl or On(Fl)) end
        if Class ~= "AirdropAircraft_C" then
            W.AddScan(Class .. "#c", 5, "client", RepOn, W.LayoutClient(Class), 1)
            W.Scans[Class .. "#c"].Class = Class
        end
        W.AddScan(Class .. "#h", 5, "host", RepOn, W.LayoutHost(Class), 2)
        W.Scans[Class .. "#h"].Class = Class
    end
    for _, Class in ipairs(W.WELLS) do
        W.AddScan(Class, 10, "both", function() return On("world_well") end,
            function(Objs) if Net.Side == "host" then W.WellHost(Objs) else W.WellClient(Objs) end end, 3)
    end
    W.AddScan("BP_HarvestableObject_C", 2, "both", function() return On("world_harvest") end, W.HarvScan)
    W.AddScan(W.SCRAP, 5, "both", function() return On("world_scrap") or On("world_owner") end, W.ScrapScan, 2)
    W.AddScan(W.LAPTOP, 10, "host", function() return On("world_laptop") end, nil, 3)
    W.AddScan("BP_EnterSafeZone_C", 30, "both", function() return On("world_safezone") end, nil, 5)
    -- beide Seiten: der Host braucht die Pfade fuer W.PoiFlush (Namenspruefung), melden tut nur der Gast
    W.AddScan("BP_POIManager_C", 10, "both", function() return On("world_poi") end,
        function(Objs) if Net.Side == "client" then W.PoiClient(Objs) else W.PoiHost(Objs) end end, 5)
    W.AddScan("BP_Infestation_C", 10, "host", function() return On("world_infest") end, W.InfHost)
    -- WORLD-4/WORLD-5: Fundorte (Host: Marker + Discover-Liste; Gast: Orte + eigene Marker weg, nur mit Host-Cap wpfm)
    W.AddScan("BP_PrefabSpawner_C", 30, "both", function()
        return (On("world_prefabmark") or On("world_prefabxp")) and (Net.Side == "host" or Net.Has("wpfm"))
    end, function(Objs) if Net.Side == "host" then W.PrefabHost(Objs) else W.PrefabClient(Objs) end end, 5)
    W.AddScan("BP_StartQuestArea_C", 30, "host", function() return QOn("quest_area") end, nil, 5)
    W.AddScan("BP_CustomNarrativeDefaultUI_C", 2, "client", function() return W.Q2("quest_ui") end, W.QuestUI)
    W.AddScan(W.QC.MARKER, 5, "host", function() return W.Q2("quest_marker") and W.MarkerOn56() end, W.MarkerHost)
    -- WORLD-28: Gast zaehlt im Diagnose-Modus eigene/replizierte Marker
    W.AddScan(W.QC.MARKER .. "#c", 30, "client", function() return W.Q2("quest_marker") and W.MarkerMode() == 2 end,
        W.MarkerDiagClient, 10)
    W.Scans[W.QC.MARKER .. "#c"].Class = W.QC.MARKER
    -- WORLD-10: Himmel-Zonen (Kartenobjekte; Gast: eigene Anwendung, dedizierter Host: Diagnose + Rueckfall)
    W.AddScan("BP_EnterSkyModifer_C", 30, "both", function() return On("world_skymod") end, nil, 5)
    for _, Class in ipairs(W.NPCS) do
        W.AddScan(Class, 20, "host", function() return QOn("quest_dialog") and W.Dedicated() end, nil, 5)
    end
    W.CheckWorld()
    Core.Every("w_scan", 1.0, function(Now) if Any() then W.ScanTick(Now) end end)
    Core.Every("w_fast", 0.25, function(Now) if Any() then W.Fast(Now) end end)
    -- Quest-Patches seitenunabhaengig (auch ohne Net.Side/Flags), damit "aus" nach dem Verlassen geschrieben wird
    Core.Every("w_slow", 1.0, function(Now)
        Step("q_patch", W.QPatches, Now)
        if Any() then W.Slow(Now) end
    end)

    Net.OnEvent("ready", function(P) if Net.Side == "host" then W.OnReady(P) end end)
    Net.OnEvent("linked", function() if Net.Side == "client" then W.OnClientLink() end end)
    Net.OnEvent("gone", function(P)
        if Net.Side == "host" and W.QState then
            -- Controller meist schon weg; falls noch da (z. B. Moduswechsel): letzter Stand sichern
            local S = W.QState[P.Key]
            local Id = S and S.Loaded and (P.GuestId or S.GuestId)
            if Id and QOn("quest_save") then
                local NC = W.NC(Net.PC(P))
                if NC then W.QuestSaveNow(S, NC, Id, os.clock()) end
            end
            W.QState[P.Key], W.Talk[P.Key], W.QQueue[P.Key] = nil, nil, nil
        end
        -- Kisten: Owner = Gast bleibt bis jetzt (POI-Manager: nur waehrend Event_Looted); geloest wird im Task (W.CrateHost)
        if Net.Side == "host" and P and P.Key then W.CrateGone[P.Key] = true end
        -- Runde 9: Laptop-Scan-Tabellen je Verbindung
        if Net.Side == "host" and P and P.Key then
            W.LapUsed[P.Key], W.LapBooked[P.Key], W.LapBookedC[P.Key] = nil, nil, nil
            if W.LapScanRate then W.LapScanRate[P.Key] = nil end
            if W.LapNoProofAt then W.LapNoProofAt[P.Key] = nil end
            -- CORE-30 (world_hygiene): uebrige Tabellen je Verbindung (Drosseln, Halte-Starts, Startquest-Zonen ...)
            if Core.Flag("world_hygiene", true) and not Core.Down.w_hygiene then
                local okF, errF = pcall(W.ForgetPeer, P.Key)
                if not okF then Core.Fail("w_hygiene", errF) end
            end
        end
        if Net.Side == "client" then W.TechApplied, W.PoiApplied = false, false end
    end)

    A.TestCommands.world_state = function()
        local Sky = W.First("Ultra_Dynamic_Sky_C")
        A.TestLog("Welt: Seite=%s Gen=%s Sky=%s repl=%s Blutmond=%s Prefabs=%d Brunnen=%d Ernte=%d Dediziert=%s",
            tostring(Net.Side), tostring(W.Gen), tostring(Sky ~= nil),
            tostring(Sky and W.SkyIsReplicated(Sky, W.First("Ultra_Dynamic_Weather_C"))),
            tostring(Sky and W.BloodMoonOn(Sky)), #(W.Paths.PrefabMaster_C or {}),
            #(W.Paths.BP_WaterWell_C or {}), #(W.Paths.BP_HarvestableObject_C or {}), tostring(W.Dedicated()))
    end
    A.TestCommands.world_scrap = function()
        local Piles, Done, Near = 0, 0, 0
        local Pawn = Net.Side == "client" and A.OwnPawn() or nil
        local PX, PY, PZ
        if Alive(Pawn) then PX, PY, PZ = W.Loc(Pawn) end
        for _, P in pairs(W.ScrapPos or {}) do
            Piles = Piles + 1
            if W.ScrapDone[P.Key] then Done = Done + 1 end
            if PX and W.Dist2(P.X, P.Y, P.Z, PX, PY, PZ) < W.SCRAP_NEAR ^ 2 then Near = Near + 1 end
        end
        local Mgr = Net.Side == "host" and W.First(W.LAPTOP) or nil
        A.TestLog("Schrott: Seite=%s Haufen=%d geborgen=%d nah=%d Cap=%s Laptop-Owner=%s", tostring(Net.Side), Piles, Done,
            Near, tostring(Net.Has("wscrap")),
            tostring(Mgr and Try(function() local O = Mgr:GetOwner() if Alive(O) then return W.Name(O) end end, "-")))
    end
    -- Nachwachsen: Stand; world_respawn_now (Host) macht alle offenen sofort faellig (Test ohne eine Stunde Warten)
    A.TestCommands.world_respawn = function()
        local H, S, G, Got = 0, 0, 0, 0
        for _ in pairs(W.HarvResp or {}) do H = H + 1 end
        for _ in pairs(W.ScrapResp or {}) do S = S + 1 end
        for _ in pairs(W.HarvGone or {}) do G = G + 1 end
        for _ in pairs(W.ScrapGot or {}) do Got = Got + 1 end
        A.TestLog("Nachwachsen: Seite=%s Minuten=%s Host offen Ernte=%d Schrott=%d | Gast entfernt=%d Schrott=%d",
            tostring(Net.Side), tostring(W.RespawnMin()), H, S, G, Got)
    end
    A.TestCommands.world_respawn_now = function()
        if Net.Side ~= "host" then return A.TestLog("world_respawn_now nur beim Host") end
        local N = 0
        for _, R in pairs(W.HarvResp or {}) do R.Force, R.Hold, N = true, nil, N + 1 end
        for _, R in pairs(W.ScrapResp or {}) do R.Force, N = true, N + 1 end
        W.RespAt = 0
        A.TestLog("Nachwachsen: %d sofort faellig", N)
    end
    A.TestCommands.world_quests = function()
        for _, G in ipairs(W.Guests("qst1")) do
            local NC = W.NC(Net.PC(G))
            local R = NC and Try(function() return NC:GetInProgressQuests() end)
            local N = R ~= nil and #ArrList(R) or -1
            A.TestLog("Gast %s: %d Quests aktiv, Dialog=%s, geladen=%s, wartend=%d, qst2=%s", G.GuestId or "?", N,
                tostring(NC and Try(function() return NC:IsInDialogue() end, false)), tostring(W.QLoaded(G)),
                #(W.QQueue[G.Key] or {}), tostring(Net.Has("qst2", G)))
        end
        local Hooks, Patches, Tags = {}, {}, 0
        for Id in pairs(W.QHooks) do Hooks[#Hooks + 1] = Id end
        for Name, On in pairs(W.PatchState) do if On then Patches[#Patches + 1] = Name end end
        for _ in pairs(W.Holders or {}) do Tags = Tags + 1 end
        table.sort(Hooks) table.sort(Patches)
        A.TestLog("Quests: Seite=%s Hooks=%s Patches=%s Tags=%d N8-Puffer=%d verworfen=%d Refire=%s Marker-repl=%s",
            tostring(Net.Side), table.concat(Hooks, ","), table.concat(Patches, ","), Tags, #(W.N8Wait or {}),
            W.N8Drop or 0, tostring(W.RefireN), tostring(W.MarkerRep))
    end
    Log("geladen (world_v2=%s, quest_v1=%s, quest_v2=%s)", tostring(Core.Flag("world_v2", true)),
        tostring(Core.Flag("quest_v1", true)), tostring(Core.Flag("quest_v2", true)))
    -- UE 5.6: Teile ohne Einstieg im neuen Questsystem
    if Core.Flag("quest_v1", true) then
        Log("Quest-Dedupe (quest_dedupe), HumanQuest-Spawnfix und Item-Belohnungs-Patch (quest_rewardpatch) fuer UE 5.6 "
            .. "deaktiviert (Event_SpawnActor/SpawnPrefab/SpawnAIHumanSpawner/RemoveActor/RewardGiveItem entfernt)")
        if W.MarkerMode() == 2 then Log("Quest-Marker (quest_marker56=2): nur Diagnose, es wird nichts entfernt")
        elseif not W.MarkerOn56() then Log("Quest-Marker (quest_marker) fuer UE 5.6 deaktiviert (nicht verifiziert)") end
    end
end

return M
