-- Last Signal, Runde 8: Weltobjekte (ls_wobj). Vertrag: _NetTest\analysis\API.md (Runde 8, Interaktions-Design A-F)
-- Generatoren, Hebel, Labor-Schalter/-Schaltkasten/-Tueren, Sirenen, Lampen, Radios, U-Bahn-Tuer. In SP laeuft die ganze
-- Arbeit lokal in OnExecuteInteract (OnServerExecuteInteract ist bei allen Klassen leer) - beim Gast also nur auf seiner
-- Kopie (falsche Toasts, leere MainJigContainers, verlorene XP/Quest-Schritte). Deshalb:
--   Gast:  Pre-Hook OnExecuteInteract (nur Lua-Tabelle) -> wo_use "Enc(Key)|n" an den Host; lokale Ausfuehrung per
--          DLL-Eintritts-Unterdrueckung (Native.SetWatch, mode=suppress at=entry). U-Bahn: Hook Event_Teleport -> wo_tp.
--   Host:  Pruefkette (Gast/Epoche, Figur lebt, Abstand <= 800 uu, Drossel, Claim) -> SetOwner(Gastfigur) ->
--          OnExecuteInteract(Gastfigur, Option) auf dem Host (Owner-Trick: GetPlayerCharacter(0)/GetLevellingComponent/
--          CreateNotificationUI loesen auf den Gast auf). Allzugangskarte: UB-Einsprung (FindJigItemByDA ist beim Host
--          fuer Gast-Kopien immer false, Fehlerklasse A'). Generator-Startgegenstand: ItemUsed?-Bypass.
--   Zustand: Host -> alle per Keyed-State wo_st (Key = Klasse@x,y,z), Gast stellt nur kosmetisch/lokal nach.
-- Schalter: wobj_v1 (Haupt), wobj_power, wobj_labdoor, wobj_misc, wobj_subway, wobj_subtime, wobj_suppress, wobj_allaccess.
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local Native = require("ls_native")
local A
-- Alles Weitere (Konstanten, Zustand, Hilfsfunktionen) liegt in X (Haupt-Locals: nur M, Core, Net, Native, A, X)
local X = {
    FLAG = "wobj_v1", CAP = "wobj1", SUBWAY = "BP_SubwayTravelDoor_C",
    USE_DIST = 800, MATCH = 40, KEY_GAP = 0.25, GUEST_RATE = 8, GUEST_Q = 4, HQ_MAX = 30,
    -- Gruppen-Caps (= wobj_v1 und Feinschalter): Gast unterdrueckt/sendet nur, wenn der Host die Gruppe auch an hat
    GCAP = { wobj_power = "wobj1p", wobj_labdoor = "wobj1l", wobj_misc = "wobj1m", wobj_subway = "wobj1s" },
    P = {
        -- CDO von /Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C (5.6 unveraendert, GetBehindObject? "same")
        GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
        ALLKEY = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard",
        -- UE 5.6: Loot_MidShelf_GrabItem_Montage entfernt, alle Labor-Klassen spielen Chr_Interact_Pickup_Montage
        MONT = "/Game/Character/Anims/Interaction/Chr_Interact_Pickup_Montage.Chr_Interact_Pickup_Montage",
    },
    -- Klasse -> P Pfad, T Zustandstyp (wo_st), F Feinschalter, Opts hoechste Option, Card UB-Einsprung (Allzugangskarte),
    -- Touch = Zustand nur nach einer Gast-Interaktion veroeffentlichen (sonst gleicher Startzustand auf beiden Seiten)
    CLS = {
        BP_PowerGenerator_C = { P = "/Game/Blueprints/Other/Power/BP_PowerGenerator.BP_PowerGenerator_C",
            T = "pg", F = "wobj_power", Opts = 2 },
        BP_LaboratoryGenerator_C = { P = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryGenerator.BP_LaboratoryGenerator_C",
            T = "lg", F = "wobj_power" },
        BP_Lever_C = { P = "/Game/Blueprints/Other/Power/BP_Lever.BP_Lever_C", T = "lv", F = "wobj_power" },
        -- On?/Off?/Warning? sind RepNotify (replicated.tsv): kein eigener Zustand
        BP_LaboratoryLightSwitch_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/Lights/BP_LaboratoryLightSwitch.BP_LaboratoryLightSwitch_C",
            F = "wobj_power" },
        BP_LaboratoryCircuitBox_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryCircuitBox.BP_LaboratoryCircuitBox_C",
            T = "cb", F = "wobj_power" },
        BP_LaboratorySlidingDoor_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor.BP_LaboratorySlidingDoor_C",
            T = "sd", F = "wobj_labdoor", Card = 1773 },
        BP_LaboratorySecureDoors_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySecureDoors.BP_LaboratorySecureDoors_C",
            T = "sc", F = "wobj_labdoor", Card = 2101 },
        BP_LaboratoryEntranceDoors_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratoryEntranceDoors.BP_LaboratoryEntranceDoors_C",
            T = "ed", F = "wobj_labdoor" },
        BP_LaboratoryStairwellLightSwitch_C = {
            P = "/Game/Blueprints/Laboratory/Blueprints/Lights/Stairwell/BP_LaboratoryStairwellLightSwitch.BP_LaboratoryStairwellLightSwitch_C",
            T = "sw", F = "wobj_misc", Touch = true },
        BP_Siren_C = { P = "/Game/Blueprints/Other/Objects/BP_Siren.BP_Siren_C", T = "sr", F = "wobj_misc" },
        BP_Lamp_C = { P = "/Game/Blueprints/Other/Lights/BP_Lamp.BP_Lamp_C", T = "lp", F = "wobj_misc", Touch = true },
        BP_Radio_C = { P = "/Game/Blueprints/Other/Radio/BP_Radio.BP_Radio_C", T = "rd", F = "wobj_misc", Touch = true },
        BP_SubwayTravelDoor_C = { P = "/Game/Blueprints/Other/Doors/BP_SubwayTravelDoor.BP_SubwayTravelDoor_C",
            F = "wobj_subway" },
    },
    -- SP spielt die Greif-Montage lokal (LightSwitch @0ce8, Stairwell @054b, CircuitBox @095c, Secure @04f4,
    -- Entrance @0169, LabGen @08b6; 5.6-Decode): bei aktiver Unterdrueckung kosmetisch nachspielen
    MONT = { BP_LaboratoryLightSwitch_C = true, BP_LaboratoryStairwellLightSwitch_C = true, BP_LaboratoryCircuitBox_C = true,
             BP_LaboratorySecureDoors_C = true, BP_LaboratoryEntranceDoors_C = true, BP_LaboratoryGenerator_C = true },
    Hooked = {}, HookTry = {}, LogAt = {}, Q = {}, HQ = {}, HQN = {}, Gone = {}, Rate = {}, GRate = {}, Hot = {}, PruneAt = 0,
    Want = {}, AQ = {}, Mine = {}, SupSet = {}, Next = {}, SentAt = {}, Pub = {}, Touched = {}, ReadAt = {}, Owned = {}, SirenDone = {},
    H = { ByKey = {}, ByCls = {}, Seen = {}, Ci = 0, PubI = 1 }, FullAt = 0, Apply = {}, Read = {},
}
X.ORDER = {}
for Cls in pairs(X.CLS) do X.ORDER[#X.ORDER + 1] = Cls end
table.sort(X.ORDER)

-- ---------------------------------------------------------------- Hilfen

function X.Log(fmt, ...) A.Log("[WeltObj] " .. fmt, ...) end

-- hoechstens alle Sec Sekunden je Schluessel (Sec nil = einmalig)
function X.LogEvery(Key, Sec, fmt, ...)
    local Now, Last = os.clock(), X.LogAt[Key]
    if Last and (not Sec or Now - Last < Sec) then return end
    X.LogAt[Key] = Now
    X.Log(fmt, ...)
end

function X.On() return Core.Flag(X.FLAG, true) == true end
function X.Sub(Name) return X.On() and Core.Flag(Name, true) == true end
function X.ClsOn(Cls)
    local C = X.CLS[Cls]
    return C ~= nil and X.Sub(C.F)
end
-- Caps veroeffentlichen (Haupt + Gruppen); Core.Fail eines Feinschalters nimmt die Gruppen-Cap mit weg
-- FLAG_DOWN einer tragenden Aufgabe/eines Empfaengers (Core.Every/Dispatch setzen nur Core.Down, nicht den Schalter)
-- zieht die Cap zurueck: Host fuehrt sonst nichts mehr aus, Gast bliebe unterdrueckt -> beide Seiten fallen auf SP
X.DOWN_HOST = { "wobj_host", "wobj_pub", "wobj_hot", "wobj_idx", "net_h_wo_use" }
X.DOWN_CLI = { "wobj_idx", "wobj_hook", "wobj_cli", "wobj_apply", "net_h_wo_st" }
function X.Broken()
    local L = Net.Side == "host" and X.DOWN_HOST or Net.Side == "client" and X.DOWN_CLI or nil
    for _, N in ipairs(L or {}) do
        if Core.Down[N] then return true end
    end
    return false
end
function X.Caps()
    local Ok = X.On() and not X.Broken()
    Net.Cap(X.CAP, Ok)
    for F, Cap in pairs(X.GCAP) do
        -- U-Bahn laeuft ueber wo_tp: dessen Host-Empfaenger Down -> nur die U-Bahn-Gruppe zurueckziehen
        Net.Cap(Cap, Ok and X.Sub(F) and not (F == "wobj_subway" and Net.Side == "host" and Core.Down.net_h_wo_tp))
    end
end
-- Gast: Gruppe auf beiden Seiten an (Net.Has prueft eigene Cap = eigener Feinschalter und die des Hosts)
function X.GHas(F)
    return Net.Has(X.CAP) and Net.Has(X.GCAP[F] or X.CAP)
end

function X.Loading()
    local W = A.WorldGen
    return W and W.Loading and (os.clock() - (W.LoadingAt or 0)) < 60
end

function X.R(V) return math.floor(V + 0.5) end
function X.B(V) return V == true and "1" or "0" end
function X.PathOf(Full) return type(Full) == "string" and (Full:match("^%S+%s+(.+)$") or Full) or nil end

function X.Find(Path)
    if type(Path) ~= "string" then return nil end
    local O = A.Safe(function() return StaticFindObject(Path) end)
    return A.IsAlive(O) and O or nil
end

function X.Asset(Path)
    local O = X.Find(Path)
    if O then return O end
    O = A.Safe(function() return LoadAsset(Path) end)
    return A.IsAlive(O) and O or nil
end

-- Komponente/Unterobjekt lebend oder nil
function X.Comp(O, Name)
    local C = A.Safe(function() return O[Name] end)
    return A.IsAlive(C) and C or nil
end

function X.Loc(O)
    local L = A.Safe(function() return O:K2_GetActorLocation() end)
    if not L then return nil end
    return L.X, L.Y, L.Z
end

function X.Dist(AX, AY, AZ, BX, BY, BZ)
    local DX, DY, DZ = AX - BX, AY - BY, AZ - BZ
    return math.sqrt(DX * DX + DY * DY + DZ * DZ)
end

-- Schluessel wie ls_build KeyOf: Klasse@x,y,z (gerundet)
function X.KeyOf(O)
    if not A.IsAlive(O) then return nil end
    local Cls = A.Safe(function() return O:GetClass():GetFName():ToString() end)
    local PX, PY, PZ = X.Loc(O)
    if not (Cls and PX) then return nil end
    return string.format("%s@%d,%d,%d", Cls, X.R(PX), X.R(PY), X.R(PZ)), Cls, PX, PY, PZ
end

function X.ParseKey(Key)
    local Cls, KX, KY, KZ = tostring(Key or ""):match("^([%w_]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not Cls then return nil end
    return Cls, tonumber(KX), tonumber(KY), tonumber(KZ)
end

-- Rueckgabe-TArray (Lua-Tabelle) oder Eigenschafts-TArray (Userdata) -> Lua-Liste
function X.Arr(R)
    local L = {}
    if type(R) == "table" then
        for _, V in ipairs(R) do L[#L + 1] = V end
    elseif R ~= nil then
        pcall(function() R:ForEach(function(_, E) L[#L + 1] = E:get() end) end)
    end
    return L
end

function X.Tag(N) return { TagName = FName("Jig.InteractOptions.Option" .. tostring(N)) } end

function X.Busy(O, Names)
    for _, Name in ipairs(Names) do
        local TL = X.Comp(O, Name)
        if TL and A.Safe(function() return TL:IsPlaying() end, false) == true then return true end
    end
    return false
end

-- Endpose einer Timeline ohne FinishedFunc (bFireEvents=false), mit UpdateFunc (bFireUpdate=true)
function X.EndPose(TL)
    if not TL then return end
    local Len = TL:GetTimelineLength()
    TL:SetPlaybackPosition(tonumber(Len) or 0, false, true)
end

-- erstes Licht-Actor der Treppenhaus-Schalter -> PointLight an?
function X.FirstLightOn(O)
    local L = X.Arr(A.Safe(function() return O.Lights end))[1]
    if not A.IsAlive(L) then return nil end
    local PL = X.Comp(L, "PointLight")
    if not PL then return nil end
    return (tonumber(A.Safe(function() return PL.Intensity end)) or 0) > 0
end

function X.CountOf(Jig, DA)
    local Out = {}
    if not pcall(function() Jig:GetTotalCountOfItem(DA, Out) end) then return 0 end
    return tonumber(Out.TotalCount) or 0
end

function X.FirstBool(Out)
    if type(Out) ~= "table" then return nil end
    if type(Out["BehindObject?"]) == "boolean" then return Out["BehindObject?"] end
    for _, V in pairs(Out) do if type(V) == "boolean" then return V end end
    return nil
end

function X.GuestName(G) return tostring(G and (G.PawnName or G.GuestId or G.Key) or "?") end

-- ---------------------------------------------------------------- Index (beide Seiten)

function X.ResetWorld(Gen)
    if Net.Side == "host" then
        for Key in pairs(X.Pub) do Net.State("wo_st", Key, nil) end
    end
    X.H = { Gen = Gen, ByKey = {}, ByCls = {}, Seen = {}, Ci = 0, PubI = 1 }
    X.Pub, X.Touched, X.ReadAt, X.Owned, X.Gone, X.HQ, X.HQN, X.Hot = {}, {}, {}, {}, {}, {}, {}, {}
    -- X.Want bleibt: Host-Zustand kann vor dem Weltwechsel-Zaehler angekommen sein (wird nur geaendert nachgesendet)
    X.Mine, X.Next, X.SentAt, X.SirenDone, X.Q, X.Pend = {}, {}, {}, {}, {}, {}
    X.RelAt = {}
end

function X.IndexClass(Cls, Now)
    local List = {}
    for _, O in ipairs(X.Arr(A.Safe(function() return FindAllOf(Cls) end))) do
        if A.IsAlive(O) then
            local Path = X.PathOf(A.Safe(function() return O:GetFullName() end))
            if Path and not Path:find("Default__", 1, true) then
                local Key, C, PX, PY, PZ = X.KeyOf(O)
                if Key and C == Cls then List[#List + 1] = { Path = Path, Key = Key, Cls = Cls, X = PX, Y = PY, Z = PZ } end
            end
        end
    end
    for _, E in ipairs(X.H.ByCls[Cls] or {}) do
        if X.H.ByKey[E.Key] == E then X.H.ByKey[E.Key] = nil end
    end
    for _, E in ipairs(List) do X.H.ByKey[E.Key] = E end
    X.H.ByCls[Cls], X.H.Seen[Cls] = List, Now
    if Cls == "BP_Siren_C" and Net.Side == "client" then
        local ok, err = pcall(X.Sirens, List)
        if not ok then Core.Fail("wobj_misc", err) end
    end
end

-- 1 Hz, je Takt eine Klasse (hoechstens ein FindAllOf je Sekunde)
function X.IndexTick(Now)
    local Gen = A.WorldGen and A.WorldGen.N
    if X.H.Gen ~= Gen then X.SirenDone = {} end
    -- Gast-Sirenen zurueck auf SP, sobald Haupt-/Gruppenschalter oder Host-Cap fehlen (auch bei wobj_v1 aus)
    if Net.Side == "client" and next(X.SirenDone) ~= nil and not X.Loading()
        and not (X.Sub("wobj_misc") and X.GHas("wobj_misc")) then
        local ok, err = pcall(X.SirenRestore)
        if not ok then X.SirenDone = {}; X.Log("Sirenen wiederherstellen fehlgeschlagen: %s", tostring(err)) end
    end
    if not X.On() then return end
    if X.H.Gen ~= Gen then X.ResetWorld(Gen) end
    if X.Loading() then return end
    local N = #X.ORDER
    for _ = 1, N do
        X.H.Ci = X.H.Ci % N + 1
        local Cls = X.ORDER[X.H.Ci]
        if X.ClsOn(Cls) then return X.IndexClass(Cls, Now) end
    end
end

-- Schluessel -> Objekt: exakt, sonst naechstes Objekt derselben Klasse <= 40 uu (Karten-Actors)
function X.Resolve(Key)
    local E = X.H.ByKey[Key]
    local O = E and X.Find(E.Path)
    if O then return O, E end
    local Cls, KX, KY, KZ = X.ParseKey(Key)
    if not Cls then return nil end
    local Best, BD = nil, X.MATCH
    for _, C in ipairs(X.H.ByCls[Cls] or {}) do
        local D = X.Dist(KX, KY, KZ, C.X, C.Y, C.Z)
        if D <= BD then Best, BD = C, D end
    end
    O = Best and X.Find(Best.Path)
    if O then return O, Best end
    return nil
end

-- ---------------------------------------------------------------- Gast: Hooks, Unterdrueckung, Senden

-- Hook-Koerper: nur lesen und in die Lua-Tabelle schreiben (keine UFunction-Aufrufe)
function X.MakeHook(Cls)
    if Cls == X.SUBWAY then
        return function(Ctx, Actor)
            if #X.Q >= 20 then return end
            local R = { At = os.clock(), Cls = Cls, Tp = true }
            pcall(function() R.Path = Ctx:get():GetFullName() end)
            -- UE 5.6: Event_Teleport(Actor) (TravelToLocUI ruft DoorRef->Event_Teleport(ActorRef), UB @0277);
            -- 5.3-Rueckfall: Variable Interacting (wurde bei L_0172 genullt)
            local I
            pcall(function() if Actor then I = Actor:get() end end)
            if I == nil then pcall(function() I = Ctx:get()["Interacting Actor"] end) end
            if I == nil then pcall(function() I = Ctx:get().Interacting end) end
            pcall(function() if I and I:IsValid() then R.Who = I:GetFName():ToString() end end)
            X.Q[#X.Q + 1] = R
        end
    end
    return function(Ctx, Actor, Option)
        if #X.Q >= 20 then return end
        -- R.Sup setzt erst CliTick aus dem wo_sup-Ereignis der DLL (nur wirklich unterdrueckte Aufrufe werden gesendet)
        local R = { At = os.clock(), Cls = Cls }
        pcall(function() R.Path = Ctx:get():GetFullName() end)
        pcall(function()
            local Ac = Actor:get()
            if Ac and Ac:IsValid() then R.Who = Ac:GetFName():ToString() end
        end)
        pcall(function() R.Opt = Option:get().TagName:ToString() end)
        X.Q[#X.Q + 1] = R
    end
end

-- Adresse der gehookten UFunction (nil = Klasse nicht geladen). Nach Entladen/Neuladen (Weltwechsel) ist es eine
-- neue UFunction: der alte Hook greift nicht mehr, die DLL-Unterdrueckung loest den Pfad aber neu auf.
function X.FnAddr(Cls)
    local C = X.CLS[Cls]
    local Fn = C and X.Find(C.P .. (Cls == X.SUBWAY and ":Event_Teleport" or ":OnExecuteInteract"))
    return Fn and A.Safe(function() return Fn:GetAddress() end) or nil
end

function X.HookTick(Now)
    if Net.Side ~= "client" or not X.On() then return end
    for _, Cls in ipairs(X.ORDER) do
        local C = X.CLS[Cls]
        if X.Hooked[Cls] and X.Sub(C.F) and X.Hooked[Cls] ~= X.FnAddr(Cls) then
            X.Hooked[Cls], X.HookTry[Cls] = nil, nil   -- Klasse neu geladen/entladen: neu hooken
            X.Log("Hook %s: Klasse neu geladen, Hook wird erneuert", Cls)
        end
        if not X.Hooked[Cls] and X.Sub(C.F) and Now >= (X.HookTry[Cls] or 0) then
            X.HookTry[Cls] = Now + 10
            local Addr = X.Find(C.P) and X.FnAddr(Cls)
            if Addr then
                local Fn = Cls == X.SUBWAY and ":Event_Teleport" or ":OnExecuteInteract"
                if A.TryHook(C.P .. Fn, X.MakeHook(Cls)) then
                    X.Hooked[Cls] = Addr
                    X.Log("Hook %s%s aktiv", Cls, Fn)
                end
            end
        end
    end
end

-- DLL: OnExecuteInteract beim Gast am Eintritt unterdruecken, solange Host wobj1 + Gruppen-Cap hat, der Beobachter
-- laeuft und der Lua-Hook der Klasse aktiv ist (sonst wuerde die Interaktion weder lokal laufen noch gesendet)
function X.WatchTick()
    -- Anwenden (wobj_apply) oder Senden (wobj_cli) per Core.Fail aus -> Unterdrueckung aufheben (lokales SP statt eingefroren)
    local Want = Net.Side == "client" and X.On() and Net.Has(X.CAP) and Core.Flag("wobj_suppress", true) == true
        and not Core.Down.wobj_apply and not Core.Down.wobj_cli and not X.Broken()
        and type(Native.Available) == "function" and Native.Available() == true
    local List, Names = {}, {}
    if Want then
        for _, Cls in ipairs(X.ORDER) do
            local C = X.CLS[Cls]
            -- nur wenn der Hook auf genau der aktuell geladenen UFunction sitzt (sonst Unterdrueckung ohne Senden)
            if Cls ~= X.SUBWAY and X.Hooked[Cls] and X.GHas(C.F) and X.Hooked[Cls] == X.FnAddr(Cls) then
                List[#List + 1] = { Func = C.P .. ":OnExecuteInteract", Tag = "wo_sup", Mode = "suppress", At = "entry" }
                Names[#Names + 1] = Cls
            end
        end
    end
    Want = Want and #List > 0
    local Sig = tostring(Net.Side) .. "|" .. tostring(Want) .. "|" .. table.concat(Names, ",")
    if Sig ~= X.WatchSig then
        X.WatchSig = Sig
        local ok, err = pcall(Native.SetWatch, Want and List or nil, "ls_wobj")
        if not ok then
            if X.Sup then X.SupOff = os.clock() end
            X.Sup, X.SupSet = false, {}
            if Core.Fail("wobj_suppress", err) then X.Log("Unterdrueckung aus (Fehler): %s", tostring(err)) end
            return
        end
        if err == false then
            -- netcore_watch.txt nicht geschrieben: Zustand unveraendert lassen, naechster Takt versucht es erneut
            X.WatchSig = nil
            return X.LogEvery("watchw", 10, "Unterdrueckung: netcore_watch.txt nicht geschrieben, neuer Versuch")
        end
        if Want or X.Sup then
            X.Log(Want and "Weltobjekte: lokale Interaktion unterdrueckt (DLL): %d Klassen"
                or "Weltobjekte: lokale Interaktion unterdrueckt (DLL): aus", #List)
        end
        if X.Sup and not Want then X.SupOff = os.clock() end
        X.Sup = Want
        X.SupSet = {}
        if Want then for _, Cls in ipairs(Names) do X.SupSet[Cls] = true end end
    end
end

-- DLL-Bestaetigung: je Aufruf von OnExecuteInteract ein wo_sup-Ereignis (Suppressed = wirklich am Eintritt
-- uebersprungen). Die DLL uebernimmt netcore_watch.txt erst nach bis zu 0,5 s und schaltet den Beobachter nach
-- Fehlern selbst ab: massgeblich ist nur das Ereignis, nicht X.Sup. Gelesen wird, solange Lua die Unterdrueckung
-- will oder sie vor < 3 s abgeschaltet hat (sonst gibt es keine wo_sup-Zeile in der DLL).
X.SUP_WAIT = 0.6
function X.ReadSup(Now, Need)
    local Maybe = X.Sup == true or (X.SupOff ~= nil and Now - X.SupOff < 3)
    if not Maybe then X.SupEv = {} return false end
    local Ev = {}
    for _, E in ipairs(X.SupEv or {}) do
        if not E.Used and Now - E.T < 2 then Ev[#Ev + 1] = E end
    end
    -- ohne offene Interaktion nur jede Sekunde lesen (Cursor nachziehen, alte Ereignisse passen nie: T >= R.At)
    if Need or Now >= (X.SupReadAt or 0) then
        X.SupReadAt = Now + 1
        local ok, List = pcall(Native.ReadEvents, "wo_sup")
        local T = os.clock()   -- Lesezeit (Hook-Zeit R.At ist os.clock, Hooks koennen nach dem Takt-Now feuern)
        if ok and type(List) == "table" then
            for _, E in ipairs(List) do
                local Name = type(E.self) == "string" and E.self:match("[^%.:]+$")
                if Name and #Ev < 64 then Ev[#Ev + 1] = { Name = Name, Sup = E.Suppressed == true, T = T } end
            end
        end
    end
    X.SupEv = Ev
    return true
end

-- true/false = DLL hat (nicht) unterdrueckt, nil = noch auf das Ereignis warten (Flush alle 100 ms)
function X.MatchSup(R, Now, Maybe)
    local Name = type(R.Path) == "string" and R.Path:match("[^%.:]+$")
    if Name then
        for _, E in ipairs(X.SupEv or {}) do
            -- >= : os.clock hat 1 ms Aufloesung, Hook und Lesen koennen in dieselbe ms fallen (Lesen nie vor dem Hook)
            if not E.Used and E.Name == Name and E.T >= R.At then
                E.Used = true
                return E.Sup
            end
        end
    end
    if not (Maybe and Name) then return false end
    if Now - R.At >= X.SUP_WAIT then
        X.LogEvery("noconf" .. tostring(R.Cls), 10, "Weltobjekt %s: keine DLL-Bestaetigung, lokal SP (nicht gesendet)", R.Cls)
        return false
    end
    return nil
end

-- kosmetische Greif-Montage der eigenen Figur (SP spielt sie lokal, die Unterdrueckung nimmt sie mit weg)
function X.Montage(Pawn, O, Cls)
    if Cls == "BP_LaboratoryCircuitBox_C" and not (O["CanInteract?"] == true and O["DamageToActivate?"] ~= true) then
        return
    end
    -- nicht ueber Ticks halten (A11): Asset je Interaktion neu aufloesen (StaticFindObject zuerst, selten)
    local Mon = X.Asset(X.P.MONT)
    if Mon then Pawn:PlayAnimMontage(Mon, 1, FName("None")) end
end

function X.SendOne(R, Pawn, Now)
    local C = X.CLS[R.Cls]
    if not (C and X.GHas(C.F)) then return end
    -- ohne DLL-Unterdrueckung lief OnExecuteInteract lokal schon als SP: nicht zusaetzlich beim Host ausfuehren
    if not R.Tp and not R.Sup then
        return X.LogEvery("nosup" .. R.Cls, nil, "Weltobjekt %s: nicht unterdrueckt, lokal SP (nicht gesendet)", R.Cls)
    end
    local O = X.Find(X.PathOf(R.Path))
    if not O then return end
    local Key, Cls = X.KeyOf(O)
    if not Key or Cls ~= R.Cls then return end
    if Now - (X.SentAt[Key] or -9) < 0.3 then return end
    X.SentAt[Key] = Now
    local N = 1
    if R.Tp then
        Net.Send("wo_tp", Net.Enc(Key), nil, 0)
    else
        N = tonumber(tostring(R.Opt or ""):match("Option(%d)$")) or 1
        Net.Send("wo_use", Net.Enc(Key) .. "|" .. N, nil, 0)
        if X.MONT[Cls] then
            local ok = pcall(X.Montage, Pawn, O, Cls)
            if not ok then X.LogEvery("mont", nil, "Greif-Montage nicht abspielbar") end
        end
    end
    X.Mine[Key] = Now
    X.LogEvery("send" .. Cls, nil, "Weltobjekt %s: Interaktion an Host (Option %d)", Cls, N)
end

function X.CliTick(Now)
    if Net.Side ~= "client" then X.Q, X.Pend, X.SupEv = {}, {}, {} return end
    X.Pend = X.Pend or {}
    for _, R in ipairs(X.Q) do
        if #X.Pend < 20 then X.Pend[#X.Pend + 1] = R end
    end
    X.Q = {}
    local Maybe = X.ReadSup(Now, #X.Pend > 0)
    if #X.Pend == 0 then return end
    if not (X.On() and Net.Has(X.CAP)) then X.Pend = {} return end
    -- je Aufruf (alle Aufrufer, damit jedes Ereignis genau einem Aufruf zugeordnet wird) auf die DLL warten
    local Ready, Keep = {}, {}
    for _, R in ipairs(X.Pend) do
        if not R.Tp and R.Sup == nil then R.Sup = X.MatchSup(R, Now, Maybe) end
        if R.Tp or R.Sup ~= nil then Ready[#Ready + 1] = R else Keep[#Keep + 1] = R end
    end
    X.Pend = Keep
    if #Ready == 0 then return end
    local Pawn = A.OwnPawn()
    local Me = Pawn and A.Safe(function() return Pawn:GetFName():ToString() end)
    if not Me then return end
    for _, R in ipairs(Ready) do
        if R.Who == Me and R.Path and Now - R.At < 3 then
            local ok, err = pcall(X.SendOne, R, Pawn, Now)
            if not ok and Core.Fail(X.CLS[R.Cls] and X.CLS[R.Cls].F or X.FLAG, err) then
                X.Log("Senden %s aus (Fehler): %s", tostring(R.Cls), tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------- Gast: Host-Zustand anwenden (nur lokal/kosmetisch)

-- pg "pg;TurnedOn;GasAdded;ItemUsed" (Audio wie @03bf/@059e, 5.6)
function X.Apply.pg(O, F)
    local T, G, U = F[2] == "1", F[3] == "1", F[4] == "1"
    if O["GasAdded?"] ~= G then O["GasAdded?"] = G end
    if O["ItemUsed?"] ~= U then O["ItemUsed?"] = U end
    if O["TurnedOn?"] ~= T then
        O["TurnedOn?"] = T
        local Au = X.Comp(O, "Audio")
        if Au then if T then Au:Activate(false) else Au:Deactivate() end end
    end
end

-- lg "lg;TurnedOn" (Audio wie @05dd/@0460)
function X.Apply.lg(O, F)
    local T = F[2] == "1"
    if O["TurnedOn?"] == T then return end
    O["TurnedOn?"] = T
    local Au = X.Comp(O, "Audio")
    if Au then if T then Au:Activate(false) else Au:Deactivate() end end
end

-- lv "lv;PoweredOn;LeverToggled;Pitch" - LeverMovement nie abspielen (FinishedFunc setzt LeverToggled?)
function X.Apply.lv(O, F)
    local P, L, Pitch = F[2] == "1", F[3] == "1", tonumber(F[4])
    if O.PoweredOn ~= P then O:SetPower_TurnedOn(P) end   -- PoweredOn + Materialien (@0297), lokal
    if O["LeverToggled?"] ~= L then O["LeverToggled?"] = L end
    local TL, Lv = X.Comp(O, "LeverMovement"), X.Comp(O, "Lever")
    if not (Pitch and Lv) or (TL and TL:IsPlaying()) then return end
    local Cur = tonumber(A.Safe(function() return Lv.RelativeRotation.Pitch end))
    if Cur and math.abs(Cur - Pitch) > 2 then
        Lv:K2_SetRelativeRotation({ Pitch = Pitch, Yaw = 0, Roll = 0 }, false, {}, false)
    end
end

-- cb "cb;DoorClosed;CanInteract" - nur Endposen (TL_Levers/TL_DoorReverse nie abspielen: ihre Fortsetzungen
-- entsperren Tueren und schalten LightSwitches, L_0f4e). Schaden-Weg (L_090b): CanInteract?=false + Partikel aus.
function X.Apply.cb(O, F)
    if X.Busy(O, { "Timeline", "TL_Levers", "TL_DoorReverse" }) then return true end
    local D, C = F[2] == "1", F[3] == "1"
    if not D and O["DoorClosed?"] ~= false then
        O["DoorClosed?"] = false
        X.EndPose(X.Comp(O, "Timeline"))
    end
    if not C and O["CanInteract?"] ~= false then
        O["CanInteract?"] = false
        if O["DamageToActivate?"] == true then
            local PS = X.Comp(O, "ParticleSystem")
            if PS then PS:Deactivate() end
        else
            X.EndPose(X.Comp(O, "TL_Levers"))
            X.EndPose(X.Comp(O, "TL_DoorReverse"))
        end
    end
end

-- sd "sd;IsClosed": TL_DoorsKeycard (FinishedFunc L_0b67 setzt nur IsClosed)
function X.Apply.sd(O, F)
    if X.Busy(O, { "TL_DoorsKeycard", "TL_DoorsAuto" }) then return true end
    local C = F[2] == "1"
    if O.IsClosed == C then return end
    local TL = X.Comp(O, "TL_DoorsKeycard")
    if not TL then return end
    if C then TL:Reverse() else TL:Play() end
end

-- sc "sc;IsClosed": oeffnen wie @0900 (IsClosed=false, TL_Mechanism -> L_1087 -> TL_Doors), schliessen wie @0910.
-- Fortsetzungen decode-geprueft: L_1087 TL_Doors.Play, L_064f nichts, L_002f IsClosed=true, L_000a Timeline.Play.
function X.Apply.sc(O, F)
    if X.Busy(O, { "TL_Mechanism", "TL_MechanismReverse", "TL_Doors", "Timeline", "Timeline_0" }) then return true end
    local C = F[2] == "1"
    if O.IsClosed == C then return end
    if C then
        local TL = X.Comp(O, "TL_MechanismReverse")
        if TL then TL:Play() end
    else
        O.IsClosed = false
        local TL = X.Comp(O, "TL_Mechanism")
        if TL then TL:Play() end
    end
end

-- ed "ed;IsClosed": Event_Door schaltet um (@05dd), Timeline-FinishedFunc setzt nur IsClosed
function X.Apply.ed(O, F)
    if X.Busy(O, { "Timeline" }) then return true end
    if O.IsClosed ~= (F[2] == "1") then O:Event_Door() end
end

-- sw "sw;on": Event_LightSwitch schaltet jedes Licht gestaffelt (@038f) -> 3 s Ruhe
function X.Apply.sw(O, F, Key, Now)
    local Cur = X.FirstLightOn(O)
    if Cur == nil or Cur == (F[2] == "1") then return end
    O:Event_LightSwitch()
    X.Next[Key] = Now + 3
end

-- sr "sr;Playing"
function X.Apply.sr(O, F)
    local P = F[2] == "1"
    if O.Playing == P then return end
    if P then O:ActivateSiren() else O:DeactivateSiren() end
end

-- lp "lp;on" (ExecuteUbergraph_BP_Lamp @001d/@006c), Flip-Flop bleibt unberuehrt
function X.Apply.lp(O, F)
    local On = F[2] == "1"
    local PL, Au = X.Comp(O, "PointLight"), X.Comp(O, "Audio")
    if not PL then return end
    if ((tonumber(A.Safe(function() return PL.Intensity end)) or 0) > 0) == On then return end
    PL:SetIntensity(On and 15 or 0)
    if Au then Au:SetVolumeMultiplier(On and 0.5 or 0) end
end

-- rd "rd;on" (@0269/@0293)
function X.Apply.rd(O, F)
    local On = F[2] == "1"
    local Au = X.Comp(O, "Audio")
    if not Au then return end
    if ((tonumber(A.Safe(function() return Au.VolumeMultiplier end)) or 0) > 0) == On then return end
    Au:SetVolumeMultiplier(On and 0.5 or 0)
end

-- Rueckgabe true = spaeter erneut versuchen
function X.ApplyOne(Key, V, Now)
    local Cls = Key:match("^([%w_]+)@")
    local C = Cls and X.CLS[Cls]
    -- Gruppe muss auf beiden Seiten an sein (Host-Cap weg -> lokales SP, keinen eingefrorenen Host-Zustand drueberlegen)
    if not (C and C.T and X.Sub(C.F) and X.GHas(C.F) and X.Apply[C.T]) then return false end
    -- Host-Zustand auch ohne DLL-Unterdrueckung anwenden (Tueren/Generatoren sonst gegen den Server verschoben):
    -- eine lokale SP-Umschaltung (nicht gesendet) ueberschreibt der naechste Anwende-Lauf (<= 5 s) mit dem Host-Zustand
    local F = {}
    for Part in (tostring(V) .. ";"):gmatch("([^;]*);") do F[#F + 1] = Part end
    if F[1] ~= C.T then return false end
    local O = X.Resolve(Key)
    if not O then return false end
    -- WORLD-16 (wobj_relabel): Zustand vor dem Anwenden lesen (X.Read, nur die 0/1-Felder vergleichen)
    local Rel = X.Sub("wobj_relabel") and X.Read[C.T]
    local Before = Rel and A.Safe(function() return Rel(O) end) or nil
    local ok, R = pcall(X.Apply[C.T], O, F, Key, Now)
    if not ok then
        if Core.Fail("wobj_apply", R) then X.Log("Zustand anwenden aus (Fehler): %s", tostring(R)) end
        return false
    end
    if Before and X.Bits(Before) ~= X.Bits(V) then
        local okR, errR = pcall(X.RelabelMark, Key, O, Now)
        if not okR then Core.Fail("wobj_relabel", errR) end
    end
    return R == true
end

-- 0/1-Felder eines Zustands ("lv;1;0;-75" -> "10"): Winkel/Typ zaehlen fuer die Beschriftung nicht
function X.Bits(S)
    local B = {}
    for P in (tostring(S) .. ";"):gmatch("([^;]*);") do
        if P == "0" or P == "1" then B[#B + 1] = P end
    end
    return table.concat(B)
end

-- WORLD-16: Interaktions-Beschriftung ("Turn On/Off" ...) nach einer Host-Umschaltung erneuern. TraceToWorld liest die
-- Optionen beim selben Objekt nur bei geaenderter ANZAHL neu (@067f-@0833). Nur CurrentTracActor zu leeren reicht nicht:
-- OnEndInteract liefe nie, HUD ShowInteractWidget(true) kehrt bei noch gueltigem Widget sofort zurueck (@000e-@0039),
-- Lab-Generator/Schaltkasten behielten den alten Text, Prompt und Umriss blieben stehen. Daher StopInteraction des Spiels:
-- erst OnEndInteract (Widget + Umriss weg), dann baut das naechste TraceToWorld das Widget neu (ShowInteractWidget @00a8).
-- Nur wenn der Spieler gerade genau dieses Objekt anschaut.
function X.Relabel(O)
    local Pawn = A.OwnPawn and A.OwnPawn()
    local H = A.IsAlive(Pawn) and X.Comp(Pawn, "BP_JigHelperComp")
    local Cur = H and A.Safe(function() return H.CurrentTracActor end)
    if not (A.IsAlive(Cur) and A.IsAlive(O)) then return false end
    if A.Safe(function() return Cur:GetAddress() == O:GetAddress() end, false) ~= true then return false end
    -- StopInteraction (PARMS 0, @0000-@00c8): Optionen leeren, OnEndInteract, CurrentTracActor = null. Bewusst ohne
    -- eigenes pcall: beide Aufrufer laufen unter pcall und melden Fehler an Core.Fail('wobj_relabel')
    H:StopInteraction()
    X.LogEvery("relabel", nil, "Beschriftung nach Host-Umschaltung erneuert (wobj_relabel)")
    return true
end

-- sofort und 2,5 s spaeter nochmals (Timeline-Tueren setzen IsClosed erst am Ende); je Schluessel hoechstens alle 2 s
function X.RelabelMark(Key, O, Now)
    X.RelAt = X.RelAt or {}
    local E = X.RelAt[Key]
    if E and Now - E.Done < 2 then E.Again = Now + 2.5 return end
    X.RelAt[Key] = { Done = Now, Again = Now + 2.5 }
    X.Relabel(O)
end

-- Gast (aus X.ApplyTick): faellige zweite Erneuerungen, alte Eintraege weg
function X.RelabelTick(Now)
    if not X.RelAt or next(X.RelAt) == nil then return end
    if not X.Sub("wobj_relabel") then X.RelAt = {} return end
    for Key, E in pairs(X.RelAt) do
        if E.Again and Now >= E.Again then
            E.Again = nil
            local O = X.Resolve(Key)
            if O then
                local ok, err = pcall(X.Relabel, O)
                if not ok then Core.Fail("wobj_relabel", err) end
            end
        elseif not E.Again and Now - E.Done > 10 then
            X.RelAt[Key] = nil
        end
    end
end

-- Schluessel in die Anwende-Warteschlange (FIFO); Dirty = steht in X.AQ
function X.MarkWant(Key)
    local W = X.Want[Key]
    if W and not W.Dirty then
        W.Dirty = true
        X.AQ[#X.AQ + 1] = Key
    end
end

-- 2 Hz: geaenderte Schluessel, alle 5 s alle; hoechstens 20 je Lauf. Warteschlange statt pairs()-Reihenfolge:
-- jeder Lauf macht dort weiter, wo der letzte aufgehoert hat; Wiederholungen (Busy) hinten anstellen.
function X.ApplyTick(Now)
    if Net.Side ~= "client" or not X.On() or not Net.Has(X.CAP) or X.Loading() or Core.Down.wobj_apply then return end
    X.RelabelTick(Now)
    if Now - X.FullAt >= 5 then
        X.FullAt = Now
        for Key in pairs(X.Want) do X.MarkWant(Key) end
    end
    local Budget, Rest, Retry, Seen = 20, {}, {}, {}
    for _, Key in ipairs(X.AQ) do
        local W = X.Want[Key]
        if W and W.Dirty and not Seen[Key] then
            Seen[Key] = true
            if Budget > 0 and Now - (X.Mine[Key] or -9) >= 1.0 and Now >= (X.Next[Key] or 0) then
                Budget = Budget - 1
                W.Dirty = X.ApplyOne(Key, W.V, Now) == true
                if W.Dirty then Retry[#Retry + 1] = Key end
            else
                Rest[#Rest + 1] = Key
            end
        end
    end
    for _, Key in ipairs(Retry) do Rest[#Rest + 1] = Key end
    X.AQ = Rest
end

-- Gast: lokale Zufallssirenen (Timer aus Event_Siren @015a, 5.6) abstellen - es spielen nur die Host-Sirenen (wo_st)
function X.Sirens(List)
    -- nur wenn die Gruppe auf beiden Seiten an ist (sonst sendet der Host kein sr -> Gast haette nie Sirenen)
    if not (X.Sub("wobj_misc") and X.GHas("wobj_misc")) then return X.SirenRestore() end
    local K = A.Safe(function() return A.UEHelpers.GetKismetSystemLibrary() end)
    if not A.IsAlive(K) then return end
    local N = 0
    for _, E in ipairs(List) do
        local O = not X.SirenDone[E.Path] and X.Find(E.Path)
        if O then
            X.SirenDone[E.Path] = true
            local H = A.Safe(function() return O.RandomSirenTimer.Handle end)
            if H ~= nil then pcall(function() K:K2_ClearAndInvalidateTimerHandle(O, { Handle = H }) end) end
            pcall(function() K:K2_ClearTimer(O, "SirenPlayTimer") end)
            N = N + 1
        end
    end
    if N > 0 then X.Log("Sirenen: lokale Zufallssirenen aus (%d)", N) end
end

-- Gast: Gruppe/Cap zur Laufzeit weg -> abgestellte Zufallstimer wieder scharf (Event_Siren @00be setzt RandomSirenTimer neu)
function X.SirenRestore()
    if next(X.SirenDone) == nil then return end
    local Done, N = X.SirenDone, 0
    X.SirenDone = {}
    for Path in pairs(Done) do
        local O = X.Find(Path)
        if O and pcall(function() O:Event_Siren() end) then N = N + 1 end
    end
    if N > 0 then X.Log("Sirenen: lokale Zufallssirenen wieder an (%d)", N) end
end

-- ---------------------------------------------------------------- Host: Anfragen

function X.Note(G, Text)
    if not (G and G.Epoch) then return end
    if Net.Has("ui_note2", G) then
        Net.Send("note2", Net.Enc(Text) .. "||1,0.35,0.3,1|4|1", G, 0)
    elseif Net.Has(X.CAP, G) then
        Net.Send("wo_note", Text, G, 1)
    end
end

-- Handler: nur pruefen und einreihen (keine UFunction-Aufrufe)
function X.OnUse(Data, G, Tp)
    if Net.Side ~= "host" or type(G) ~= "table" or not G.Key or not X.On() then return end
    local Kind = Tp and "wo_tp" or "wo_use"
    local K, N
    if Tp then K, N = tostring(Data or ""), "1" else K, N = tostring(Data or ""):match("^([^|]+)|(%d)$") end
    N = tonumber(N)
    local Key = K and K ~= "" and Net.Dec(K)
    local Cls = Key and X.ParseKey(Key)
    local C = Cls and X.CLS[Cls]
    if not (C and N and N >= 1 and N <= (C.Opts or 1) and (Tp == true) == (Cls == X.SUBWAY)) then
        return Net.SecWarn(G, G.Key, Kind .. "_bad")
    end
    -- Gruppe beim Host aus/abgeschaltet: still verwerfen (Gast sieht die Gruppen-Cap nach <= 1 s nicht mehr)
    if not X.Sub(C.F) then return X.LogEvery("off" .. C.F, 60, "%s aus: Anfrage von %s verworfen", C.F, X.GuestName(G)) end
    -- Drossel (A1) schon beim Einreihen, je Gast: 0,25 s je Gast+Schluessel, <= 8/s, <= GUEST_Q Eintraege in HQ
    -- (sonst kann ein Gast die gemeinsame Warteschlange fuellen und fremde Anfragen verdraengen)
    local Now = os.clock()
    local RK = G.Key .. "|" .. Key
    if Now - (X.Rate[RK] or -9) < X.KEY_GAP then return Net.SecWarn(G, G.Key, Kind .. "_rate") end
    local GR = X.GRate[G.Key]
    if not GR or Now - GR.At >= 1 then GR = { At = Now, N = 0 } X.GRate[G.Key] = GR end
    GR.N = GR.N + 1
    if GR.N > X.GUEST_RATE then return Net.SecWarn(G, G.Key, Kind .. "_rate") end
    local QN = X.HQN[G.Key] or 0
    if QN >= X.GUEST_Q then return Net.SecWarn(G, G.Key, Kind .. "_rate") end
    -- Gesamtgrenze: kein Verstoss des Absenders (er liegt unter seinen Grenzen) -> nur gedrosselt loggen
    if #X.HQ >= X.HQ_MAX then return X.LogEvery("hqvoll", 10, "Warteschlange voll: Anfrage von %s verworfen", X.GuestName(G)) end
    X.Rate[RK] = Now
    X.HQN[G.Key] = QN + 1
    X.HQ[#X.HQ + 1] = { GKey = G.Key, Epoch = G.Epoch, Key = Key, N = N, Tp = Tp == true, At = Now }
end

-- alte Drossel-/Log-Eintraege abbauen (gefaelschte Schluessel duerfen die Tabellen nicht wachsen lassen)
function X.Prune(Now)
    if Now - X.PruneAt < 10 then return end
    X.PruneAt = Now
    for RK, T in pairs(X.Rate) do if Now - T > 1 then X.Rate[RK] = nil end end
    for GK, GR in pairs(X.GRate) do if Now - GR.At > 2 then X.GRate[GK] = nil end end
    for LK, T in pairs(X.LogAt) do
        if LK:sub(1, 4) == "miss" and Now - T > 60 then X.LogAt[LK] = nil end
    end
end

-- Generator: Startgegenstand beim Host pruefen (FindJigItemByDA @084e (5.6) ist fuer Gast-Kopien immer false, A')
function X.GenBypass(O, Pawn, G)
    if not (O["GasAdded?"] == true and O["TurnedOn?"] ~= true and O["RequiredItemToPowerOn?"] == true
        and O["ItemUsed?"] ~= true) then return end
    local DA = X.Comp(O, "RequiredItem")
    local Jig = X.Comp(Pawn, "BP_JigMultiplayer")
    if not (DA and Jig) then return end
    local N = X.CountOf(Jig, DA)
    if N <= 0 then return end   -- Spiel meldet "{A} Not Found" (@094d)
    if O["ConsumeItemOnUse?"] == true then
        local Out = {}
        local Res = A.Safe(function() return Jig:ServerFindThenConsumeByItemID(DA, 1, Out) end)
        if not (Res == true or Out.Result == true) then
            X.Log("Generator: Startgegenstand von %s nicht verbraucht - keine Freigabe", X.GuestName(G))
            return
        end
    end
    O["ItemUsed?"] = true   -- Spiel geht L_0788 -> L_039f (einschalten)
    X.LogEvery("genby", 30, "Generator: Startgegenstand bei %s gefunden (%d), Freigabe gesetzt", X.GuestName(G), N)
end

-- Labor-Kartentuer: Allzugangskarte beim Host zaehlen und SP-Erfolgszweig per UB-Einsprung (true = erledigt)
function X.CardDoor(O, Pawn, Cls, C, G)
    if not (C.Card and Core.Flag("wobj_allaccess", true) == true) then return false end
    local Behind = false
    if O["CanOpenDoorFromBehind?"] == true then
        local GFL = X.Find(X.P.GFL)
        if GFL then
            local Out = {}
            pcall(function() GFL["GetBehindObject?"](GFL, O, Pawn, { X = 0, Y = 0, Z = 0 }, O, Out) end)
            Behind = X.FirstBool(Out) == true
        end
    end
    local Needs
    if Cls == "BP_LaboratorySlidingDoor_C" then Needs = O.Locked == true else Needs = O.IsClosed == true end
    if not Needs or Behind then return false end
    local DA, Jig = X.Asset(X.P.ALLKEY), X.Comp(Pawn, "BP_JigMultiplayer")
    if not (DA and Jig) or X.CountOf(Jig, DA) <= 0 then return false end
    local Fn = "ExecuteUbergraph_" .. Cls:gsub("_C$", "")
    O[Fn](O, C.Card)
    X.Log("Allzugangskarte: %s fuer %s (Einsprung %d)", Cls, X.GuestName(G), C.Card)
    return true
end

-- U-Bahn-Ziel in Weltkoordinaten. UE 5.6 (UB @029e-@02e8): TransformLocation(self.GetTransform(), TravelToLoc) -
-- TravelToLoc ist jetzt relativ zur Tuer (5.3: absolut). TransformPosition = Rot(Scale * V) + Loc;
-- Rot(V) = V.X * Forward + V.Y * Right + V.Z * Up (Achsen der Actor-Rotation).
function X.SubwayTarget(O)
    local L = A.Safe(function() return O.TravelToLoc end)
    local LX, LY, LZ = L and tonumber(L.X), L and tonumber(L.Y), L and tonumber(L.Z)
    local OX, OY, OZ = X.Loc(O)
    if not (LX and LY and LZ and OX) then return nil end
    local S = A.Safe(function() return O:GetActorScale3D() end)
    LX, LY, LZ = LX * (tonumber(S and S.X) or 1), LY * (tonumber(S and S.Y) or 1), LZ * (tonumber(S and S.Z) or 1)
    local F = A.Safe(function() return O:GetActorForwardVector() end)
    local R = A.Safe(function() return O:GetActorRightVector() end)
    local U = A.Safe(function() return O:GetActorUpVector() end)
    local Ax = {}
    for I, V in ipairs({ F, R, U }) do
        local VX, VY, VZ = V and tonumber(V.X), V and tonumber(V.Y), V and tonumber(V.Z)
        if not (VX and VY and VZ) then return nil end
        Ax[I] = { VX, VY, VZ }
    end
    return OX + LX * Ax[1][1] + LY * Ax[2][1] + LZ * Ax[3][1],
        OY + LX * Ax[1][2] + LY * Ax[2][2] + LZ * Ax[3][2],
        OZ + LX * Ax[1][3] + LY * Ax[2][3] + LZ * Ax[3][3]
end

-- U-Bahn: Gast hat lokal teleportiert (Event_Teleport) - Host setzt die Figur ans Ziel
function X.Subway(O, Pawn, PC, G, PX, PY, PZ, Near)
    local LX, LY, LZ = X.SubwayTarget(O)
    if not (LX and LY and LZ) then
        return X.LogEvery("subtgt", 60, "U-Bahn-Ziel nicht berechenbar (TravelToLoc/Transform)")
    end
    if not Near and X.Dist(PX, PY, PZ, LX, LY, LZ) > X.USE_DIST then return Net.SecWarn(G, G.Key, "wo_tp_dist") end
    local Target = { X = LX, Y = LY, Z = LZ + 50 }
    local Yaw = tonumber(A.Safe(function() return Pawn:K2_GetActorRotation().Yaw end)) or 0
    local Rot = { Pitch = 0, Yaw = Yaw, Roll = 0 }
    -- E23: Bewegungspruefung (main move_check) wertet den Sprung nicht als Verstoss
    A.Coop.TrustSkip = A.Coop.TrustSkip or {}
    A.Coop.TrustSkip[G.Key] = os.clock() + 5
    Pawn:K2_TeleportTo(Target, Rot)
    -- CORE-16: kein ClientSetLocation (Client-RPC) mit Lua-Strukturen (Regel 4). Gast mit pl_tp setzt die eigene Figur
    -- selbst (ls_player, K2_TeleportTo ist kein RPC); alter Gast: nur die Server-Seite oben
    if Net.Has("pl_tp", G) then
        Net.Send("pl_tp", string.format("%.1f|%.1f|%.1f|%.1f", LX, LY, LZ + 50, Yaw), G, 0)
    end
    X.Log("U-Bahn-Fahrt: %s nach %.0f/%.0f/%.0f", X.GuestName(G), LX, LY, LZ)
    X.SubwayTime(O)
end

-- U-Bahn-Fahrzeit wie SP (5.6: UB Event_Teleport @0326 DelayUntilNextTick -> L_0010): GetUDS = erster Ultra_Dynamic_Sky_C,
-- "Transition Time of Day"(Time of Day + TimeToTravel, 0.5, 0, 0, false). Host-Himmel ist massgeblich (world_sky
-- Replikation bzw. W.ApplyTime-Rueckfall) - ohne diesen Sprung zieht der Host den lokalen Gast-Sprung zurueck.
-- Fahrten mehrerer Gaeste innerhalb 5 s zaehlen einmal (jeder Gast springt lokal auch nur einmal). Schalter wobj_subtime (Standard aus: Weltzeit ist geteilt, wie beim Schlafen).
function X.SubwayTime(O)
    if Core.Flag("wobj_subtime", false) ~= true then return end
    local Now = os.clock()
    if Now < (X.SubTimeAt or 0) then return end
    local Add = tonumber(A.Safe(function() return O.TimeToTravel end))
    if not Add or Add <= 0 then return end
    local Sky = A.Safe(function() return FindFirstOf("Ultra_Dynamic_Sky_C") end)
    if not A.IsAlive(Sky) then return end
    local Cur = tonumber(A.Safe(function() return Sky["Time of Day"] end))
    if not Cur then return end
    X.SubTimeAt = Now + 5
    local ok, err = pcall(function() Sky["Transition Time of Day"](Sky, Cur + Add, 0.5, 0, 0, false) end)
    if not ok then
        if Core.Fail("wobj_subtime", err) then X.Log("U-Bahn-Fahrzeit aus (Fehler): %s", tostring(err)) end
        return
    end
    pcall(function() Sky:ForceNetUpdate() end)
    X.Log("U-Bahn-Fahrzeit: Uhrzeit %.0f -> %.0f (+%.0f)", Cur, Cur + Add, Add)
end

function X.HostDo(E, Now)
    local G = Net.Guests[E.GKey]
    if not (G and G.Epoch and G.Epoch == E.Epoch) then return end
    local Kind = E.Tp and "wo_tp" or "wo_use"   -- Drossel bereits in X.OnUse
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or A.Safe(function() return Pawn["PlayerDead?"] end, true) == true then return end
    local O, Ent = X.Resolve(E.Key)
    if not O then return X.LogEvery("miss" .. E.Key, 60, "Weltobjekt %s beim Host nicht gefunden", E.Key) end
    local PX, PY, PZ = X.Loc(Pawn)
    local OX, OY, OZ = X.Loc(O)
    if not (PX and OX) then return end
    local Near = X.Dist(PX, PY, PZ, OX, OY, OZ) <= X.USE_DIST
    if not Near and not E.Tp then return Net.SecWarn(G, G.Key, Kind .. "_dist") end
    local Bld = A.Coop and A.Coop.Build
    if Bld and type(Bld.CanUse) == "function"
        and A.Safe(function() return Bld.CanUse(G.GuestId, O) end, true) == false then
        return X.Note(G, "Kein Zugriff")
    end
    if E.Tp then return X.Subway(O, Pawn, PC, G, PX, PY, PZ, Near) end
    local Cls = Ent.Cls
    local C = X.CLS[Cls]
    -- Owner-Trick: Owner bleibt gesetzt (latente Fortsetzungen, ls_world W.OwnerGuest), geloest erst nach "gone"
    pcall(function() O:SetOwner(Pawn) end)
    X.Owned[Ent.Path] = G.Key
    if Cls == "BP_PowerGenerator_C" and E.N == 1 then X.GenBypass(O, Pawn, G) end
    if not X.CardDoor(O, Pawn, Cls, C, G) then O:OnExecuteInteract(Pawn, X.Tag(E.N)) end
    X.Touched[Ent.Key] = true
    X.ReadAt[Ent.Key] = Now + (C.T == "sw" and 2.0 or 0.3)
    if C.T then X.Hot[Ent.Key] = X.ReadAt[Ent.Key] end   -- sofort veroeffentlichen (X.HotTick), nicht erst im 1-Hz-Durchlauf
    X.LogEvery("do" .. Cls, 10, "Weltobjekt %s: Option %d fuer %s ausgefuehrt", Cls, E.N, X.GuestName(G))
end

-- Owner nach "gone" loesen (nur wenn kein anderer Gast das Objekt inzwischen benutzt hat)
function X.GoneTick()
    local N = 0
    while #X.Gone > 0 and N < 8 do
        local Path = table.remove(X.Gone)
        N = N + 1
        if X.Owned[Path] == nil then
            local O = X.Find(Path)
            if O then pcall(function() O:SetOwner(nil) end) end
        end
    end
end

-- 10 Hz, hoechstens 4 Anfragen je Takt
function X.HostTick(Now)
    if Net.Side ~= "host" then X.HQ, X.HQN = {}, {} return end
    X.GoneTick()
    X.Prune(Now)
    if not X.On() or X.Loading() then X.HQ, X.HQN = {}, {} return end
    local N = 0
    while #X.HQ > 0 and N < 4 do
        local E = table.remove(X.HQ, 1)
        N = N + 1
        local QN = (X.HQN[E.GKey] or 1) - 1
        X.HQN[E.GKey] = QN > 0 and QN or nil
        if Now - E.At <= 5 then
            local ok, err = pcall(X.HostDo, E, Now)
            if not ok then
                local C = X.CLS[E.Key:match("^([%w_]+)@") or ""]
                local Flag = C and C.F or X.FLAG
                if Core.Fail(Flag, err) then X.Log("%s aus (Fehler): %s", Flag, tostring(err)) end
            end
        end
    end
end

-- ---------------------------------------------------------------- Host: Zustand veroeffentlichen

function X.Read.pg(O) return "pg;" .. X.B(O["TurnedOn?"]) .. ";" .. X.B(O["GasAdded?"]) .. ";" .. X.B(O["ItemUsed?"]) end
function X.Read.lg(O) return "lg;" .. X.B(O["TurnedOn?"]) end
-- Laufrichtung einer Timeline: nil = steht, true = rueckwaerts, false = vorwaerts. Die End-Flags (IsClosed,
-- LeverToggled?) setzt das Spiel erst im FinishedFunc - waehrend des Laufs wird das Ziel aus der Richtung gelesen.
function X.Dir(O, Name)
    local TL = X.Comp(O, Name)
    if not TL or A.Safe(function() return TL:IsPlaying() end, false) ~= true then return nil end
    return A.Safe(function() return TL:IsReversing() end, false) == true
end

-- lv: FinishedFunc @000f: vorwaerts -> LeverToggled?=false (@006a), rueckwaerts -> true (@0076);
-- Pitch = Lerp(75, -75, Alpha) @0634 -> Ziel -75 bzw. 75 (Ruhe-Lesung danach korrigiert Abweichungen)
function X.Read.lv(O)
    local Lv = X.Comp(O, "Lever")
    if not Lv then return nil end
    local D = X.Dir(O, "LeverMovement")
    if D ~= nil then return "lv;" .. X.B(O.PoweredOn) .. ";" .. X.B(D) .. ";" .. (D and 75 or -75) end
    local Pitch = tonumber(A.Safe(function() return Lv.RelativeRotation.Pitch end))
    if not Pitch then return nil end
    return "lv;" .. X.B(O.PoweredOn) .. ";" .. X.B(O["LeverToggled?"]) .. ";" .. X.R(Pitch)
end
function X.Read.cb(O) return "cb;" .. X.B(O["DoorClosed?"]) .. ";" .. X.B(O["CanInteract?"]) end
-- sd: Event_Door @053d Play (oeffnen) / Reverse (schliessen); FinishedFunc L_0b67: vorwaerts -> IsClosed=false, rueckwaerts -> true
function X.Read.sd(O)
    local D = X.Dir(O, "TL_DoorsKeycard")
    if D ~= nil then return "sd;" .. X.B(D) end
    return "sd;" .. X.B(O.IsClosed)
end
-- sc: oeffnen setzt IsClosed=false sofort (@0900); schliessen: TL_MechanismReverse (@0910), dessen UpdateFunc
-- TL_Doors->Reverse (@033c -> L_0219); IsClosed=true erst im TL_Doors-FinishedFunc rueckwaerts (L_0061)
function X.Read.sc(O)
    if O.IsClosed ~= true and (X.Dir(O, "TL_MechanismReverse") ~= nil or X.Dir(O, "TL_Doors") == true) then return "sc;1" end
    return "sc;" .. X.B(O.IsClosed)
end
-- ed: oeffnen setzt IsClosed=false sofort (@05cd); schliessen Timeline->Reverse (@02fd), IsClosed=true erst L_003c
function X.Read.ed(O)
    if X.Dir(O, "Timeline") == true then return "ed;1" end
    return "ed;" .. X.B(O.IsClosed)
end
function X.Read.sw(O)
    local On = X.FirstLightOn(O)
    if On == nil then return nil end
    return "sw;" .. X.B(On)
end
function X.Read.sr(O) return "sr;" .. X.B(O.Playing) end
function X.Read.lp(O)
    local PL = X.Comp(O, "PointLight")
    if not PL then return nil end
    return "lp;" .. X.B((tonumber(PL.Intensity) or 0) > 0)
end
function X.Read.rd(O)
    local Au = X.Comp(O, "Audio")
    if not Au then return nil end
    return "rd;" .. X.B((tonumber(Au.VolumeMultiplier) or 0) > 0)
end

function X.AnyGuest()
    for _, G in pairs(Net.Guests) do
        if G.Epoch and Net.Has(X.CAP, G) then return true end
    end
    return false
end

-- 1 Hz, hoechstens 80 Objekte je Lauf (Zeiger ueber die Schluessel-Liste)
function X.PubTick(Now)
    if Net.Side ~= "host" then return end
    -- Modul aus (Schalter/Core.Fail): veroeffentlichte Zustaende zurueckziehen, sonst kommen sie per Vollauffrischung wieder
    if not X.On() then
        for Key in pairs(X.Pub) do Net.State("wo_st", Key, nil) end
        X.Pub = {}
        return
    end
    if X.Loading() or not X.AnyGuest() then return end
    local H = X.H
    if not H.PubList or H.PubI > #H.PubList then
        local L = {}
        for Key, E in pairs(H.ByKey) do
            local C = X.CLS[E.Cls]
            if C and C.T then L[#L + 1] = Key end
        end
        table.sort(L)
        H.PubList, H.PubI = L, 1
        -- verschwundene Objekte (nur Klassen, die seit dem Weltwechsel schon indiziert sind)
        -- und Gruppen, die zur Laufzeit abgeschaltet wurden (Core.Fail/Schalter)
        for Key in pairs(X.Pub) do
            local Cls = Key:match("^([%w_]+)@")
            local CC = Cls and X.CLS[Cls]
            if (not H.ByKey[Key] and H.Seen[Cls]) or (CC and not X.Sub(CC.F)) then
                Net.State("wo_st", Key, nil)
                X.Pub[Key] = nil
            end
        end
    end
    local Budget = 80
    while H.PubI <= #H.PubList and Budget > 0 do
        local Key = H.PubList[H.PubI]
        H.PubI = H.PubI + 1
        local E = H.ByKey[Key]
        local C = E and X.CLS[E.Cls]
        if C and C.T and X.Sub(C.F) and (not C.Touch or X.Touched[Key]) and Now >= (X.ReadAt[Key] or 0) then
            Budget = Budget - 1
            X.PubOne(Key, E, C)
        end
    end
end

function X.PubOne(Key, E, C)
    local O = X.Find(E.Path)
    if not O then return end
    local ok, V = pcall(X.Read[C.T], O)
    if ok and V then
        if X.Pub[Key] ~= V then Net.State("wo_st", Key, V, 1) X.Pub[Key] = V end
    elseif not ok and Core.Fail("wobj_pub_read", V) then
        X.Log("Zustand lesen aus (Fehler): %s", tostring(V))
    end
end

-- 10 Hz: gerade benutzte Objekte sofort nach ReadAt veroeffentlichen (Zielzustand laufender Timelines, X.Read.*)
function X.HotTick(Now)
    if Net.Side ~= "host" or next(X.Hot) == nil then return end
    if not X.On() or X.Loading() then X.Hot = {} return end
    for Key, At in pairs(X.Hot) do
        if Now >= At then
            X.Hot[Key] = nil
            local E = X.H.ByKey[Key]
            local C = E and X.CLS[E.Cls]
            if C and C.T and X.Sub(C.F) then X.PubOne(Key, E, C) end
        end
    end
end

-- ---------------------------------------------------------------- Handler / Diagnose / Init

M.Handlers = {
    wo_use = function(Data, G) X.OnUse(Data, G, false) end,
    wo_tp = function(Data, G) X.OnUse(Data, G, true) end,
    wo_st = function(Value, _, Msg)
        if Net.Side ~= "client" or type(Msg) ~= "table" or not Msg.Key then return end
        if Value == nil then X.Want[Msg.Key] = nil return end
        local W = X.Want[Msg.Key] or {}
        W.V = tostring(Value)
        X.Want[Msg.Key] = W
        X.MarkWant(Msg.Key)
    end,
    wo_note = function(Data)
        if Net.Side ~= "client" or type(Data) ~= "string" or Data == "" then return end
        if A.ShowNote then pcall(A.ShowNote, Data) end
    end,
}

function M.KeyOf(Obj) return X.KeyOf(Obj) end

function M.Probe()
    local Out = A.TestLog or A.Log
    local Parts = {}
    for _, Cls in ipairs(X.ORDER) do
        Parts[#Parts + 1] = string.format("%s=%d%s", (Cls:gsub("^BP_", ""):gsub("_C$", "")), #(X.H.ByCls[Cls] or {}),
            X.Hooked[Cls] and "h" or "")
    end
    local NW, NP, NO = 0, 0, 0
    for _ in pairs(X.Want) do NW = NW + 1 end
    for _ in pairs(X.Pub) do NP = NP + 1 end
    for _ in pairs(X.Owned) do NO = NO + 1 end
    Out("wobj %s: an=%s cap=%s DLL-Unterdrueckung=%s Q=%d HQ=%d Want=%d Pub=%d Owned=%d", tostring(Net.Side),
        tostring(X.On()), tostring(Net.Has(X.CAP)), X.Sup and "an" or "aus", #X.Q, #X.HQ, NW, NP, NO)
    Out("wobj Index: %s", table.concat(Parts, " "))
end

function X.OnGone(Peer)
    if Net.Side == "host" and type(Peer) == "table" and Peer.Key then
        for Path, GK in pairs(X.Owned) do
            if GK == Peer.Key then X.Owned[Path] = nil X.Gone[#X.Gone + 1] = Path end
        end
        X.GRate[Peer.Key] = nil
        local Pre = Peer.Key .. "|"
        for RK in pairs(X.Rate) do
            if RK:sub(1, #Pre) == Pre then X.Rate[RK] = nil end
        end
    elseif Net.Side == "client" then
        X.Want, X.Mine, X.Q, X.AQ, X.RelAt = {}, {}, {}, {}, {}
    end
end

function M.Init(Api)
    A = Api
    X.Caps()
    Core.Every("wobj_caps", 1, X.Caps)
    if A.Coop then A.Coop.WObj = M end
    Core.Every("wobj_idx", 1.0, X.IndexTick)
    Core.Every("wobj_hook", 1.0, X.HookTick)
    Core.Every("wobj_watch", 2.0, X.WatchTick)
    Core.Every("wobj_cli", 0.1, X.CliTick)
    Core.Every("wobj_apply", 0.5, X.ApplyTick)
    Core.Every("wobj_host", 0.1, X.HostTick)
    Core.Every("wobj_pub", 1.0, X.PubTick)
    Core.Every("wobj_hot", 0.1, X.HotTick)
    Net.OnEvent("gone", X.OnGone)
    A.TestCommands.wobj_probe = M.Probe
    X.Log("geladen (%s, %d Klassen)", X.On() and "an" or "aus", #X.ORDER)
end

return M
