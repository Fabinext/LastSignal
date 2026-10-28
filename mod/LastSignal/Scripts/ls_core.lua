-- Last Signal, Runde 5: Grundbausteine fuer die ls_*-Module (main.lua laedt sie nach server.lua).
--   Core.WriteAtomic/ReadAll  Dateien (erst .tmp, dann umbenennen: die DLL liest nie halbe Dateien)
--   Core.Flag                 Schalter aus coop.txt; profile=legacy stellt alle neuen Wege ab
--   Core.Fail                 Autofallback: mehr als 3 Fehler in 60 s -> Schalter aus (Runde 9: nach core_down_expire
--                             s neuer Versuch, Frist verdoppelt sich; Core.ResetFlags = Konsole "flags")
--   Core.SafeGuestPath        Runde 9: Asset-Pfad eines Gasts pruefen (untrusted_paths, E24)
--   Core.Every                Aufgaben-Liste, eine gemeinsame Schleife (100 ms) im Spiel-Thread; Runde 9: steht
--                             zwischen Weltwechsel und Coop.DropWorldRefs (world_hygiene, hoechstens 10 s)
--   Core.PerfAdd/PerfReport   Laufzeit je Aufgabe (gleitend 60 s), Warnung bei Laeufen ueber 5 ms, Testbefehl perf
local Core = {}
local A           -- API aus main.lua (siehe Init)
local FAIL_LIMIT, FAIL_WINDOW = 3, 60
local PERF_SLOT, PERF_SLOTS = 10, 6          -- 6 Faecher a 10 s = gleitend die letzten 60 s
local PERF_WARN, PERF_WARN_GAP = 0.005, 60   -- Warnung ab 5 ms je Lauf, hoechstens alle 60 s je Aufgabe

Core.Extra = {}   -- Schalter aus coop.txt, die SETTINGS nicht kennt (LoadSettings liest nur bekannte Zahlen)
Core.Down = {}    -- [Schalter] = os.clock des Abschaltens (wahr = aus); laeuft nach core_down_expire s ab (Core.DownTick)
Core.Fails = {}   -- [Schalter] = { Zeitpunkte (os.clock) }
Core.DownN = {}   -- [Schalter] = wie oft in dieser Sitzung abgeschaltet (Frist verdoppelt sich je Mal, hoechstens 1 h)
Core.DownUntil = {} -- [Schalter] = os.clock, ab dem er wieder versucht wird (nil = nie, core_down_expire=0)
Core.Tasks, Core.Order = {}, {}
Core.Perf = {}    -- [Aufgabe] = { Id/Runs/Sum/Max = je PERF_SLOTS Zahlen, Since, WarnAt } (Zeiten in s, os.clock)

local function Log(fmt, ...) A.Log("[Core] " .. fmt, ...) end

-- Laeufe, Summe, Maximum (s) und erfasste Spanne (s) der letzten 60 s
local function PerfWindow(P, Now)
    local Cur, Runs, Sum, Max = math.floor(Now / PERF_SLOT), 0, 0, 0
    for I = 1, PERF_SLOTS do
        if Cur - P.Id[I] < PERF_SLOTS then
            Runs, Sum = Runs + P.Runs[I], Sum + P.Sum[I]
            if P.Max[I] > Max then Max = P.Max[I] end
        end
    end
    local Span = math.min(Now - P.Since, (PERF_SLOTS - 1) * PERF_SLOT + Now - Cur * PERF_SLOT)
    return Runs, Sum, Max, math.max(Span, 1)
end

-- Einen Lauf von Name eintragen (Dt = Dauer in s, Now = os.clock danach). Je Lauf nur Zahlen, keine Tabellen
-- (die gibt es nur beim ersten Lauf eines Namens). Ueber Warn s (Standard 5 ms): Warnung, hoechstens alle 60 s je Name.
function Core.PerfAdd(Name, Dt, Now, Warn)
    local P = Core.Perf[Name]
    if not P then
        P = { Id = {}, Runs = {}, Sum = {}, Max = {}, Since = Now, WarnAt = Now - PERF_WARN_GAP }
        for I = 1, PERF_SLOTS do P.Id[I], P.Runs[I], P.Sum[I], P.Max[I] = -PERF_SLOTS, 0, 0, 0 end
        Core.Perf[Name] = P
    end
    local Id = math.floor(Now / PERF_SLOT)
    local I = Id % PERF_SLOTS + 1
    if P.Id[I] ~= Id then P.Id[I], P.Runs[I], P.Sum[I], P.Max[I] = Id, 0, 0, 0 end
    P.Runs[I], P.Sum[I] = P.Runs[I] + 1, P.Sum[I] + Dt
    if Dt > P.Max[I] then P.Max[I] = Dt end
    if Dt > (Warn or PERF_WARN) and Now - P.WarnAt >= PERF_WARN_GAP and A then
        P.WarnAt = Now
        local Runs, Sum, Max = PerfWindow(P, Now)
        Log("WARNUNG: Aufgabe %s brauchte %.1f ms (letzte 60 s: %d Laeufe, Schnitt %.2f ms, max %.1f ms)",
            Name, Dt * 1000, Runs, Sum / Runs * 1000, Max * 1000)
    end
end

-- Kurzbericht: Text, nur die Aufgaben-Liste, Lua-Speicher (KB). Limit = Anzahl der teuersten Aufgaben (Standard 10),
-- sortiert nach Gesamtzeit der letzten 60 s; je Aufgabe Summe, Laeufe/s, Schnitt und Maximum in ms.
function Core.PerfReport(Limit)
    local Now, List = os.clock(), {}
    for Name, P in pairs(Core.Perf) do
        local Runs, Sum, Max, Span = PerfWindow(P, Now)
        if Runs > 0 then List[#List + 1] = { Name, Runs, Sum, Max, Span } end
    end
    table.sort(List, function(X, Y) return X[3] > Y[3] end)
    local Parts = {}
    for I = 1, math.min(Limit or 10, #List) do
        local E = List[I]
        Parts[#Parts + 1] = string.format("%s %.0f ms (%.1f/s, Schnitt %.2f, max %.1f)", E[1], E[3] * 1000,
            E[2] / E[5], E[3] / E[2] * 1000, E[4] * 1000)
    end
    local Top, KB = #Parts > 0 and table.concat(Parts, "; ") or "keine", collectgarbage("count")
    return string.format("Lua %.0f KB, Aufgaben (60 s): %s", KB, Top), Top, KB
end

local function ReadFile(Path)
    local File = io.open(Path, "rb")
    if not File then return nil end
    local Text = File:read("*a")
    File:close()
    return Text
end

Core.Recovered = {}   -- [Path] = true: schon einmal aus .bak gelesen (Meldung nur einmal)
Core.WriteErr = {}    -- [Path] = os.clock der letzten Schreib-Fehlermeldung (hoechstens alle 60 s je Datei)

-- Fehlt Path, aber es liegt ein Path.bak (nur WriteAtomic legt den an, die DLL nie): ein Speichern wurde
-- zwischen "Path -> .bak" und ".tmp -> Path" unterbrochen. Dann gilt der alte Stand aus .bak. Path.tmp wird
-- NIE gelesen: sie kann halb geschrieben sein (auch die DLL schreibt ihre Dateien ueber .tmp).
function Core.ReadAll(Path)
    local Text = ReadFile(Path)
    if Text then return Text end
    local Bak = ReadFile(Path .. ".bak")
    if not Bak then return nil end
    if not Core.Recovered[Path] and A then
        Core.Recovered[Path] = true
        Log("%s fehlte - aus %s.bak wiederhergestellt", Path, Path)
    end
    return Bak
end

-- Erst Path.tmp vollstaendig schreiben, dann direkt .tmp -> Path (klappt, wenn Path fehlt). Nur wenn das
-- scheitert (Windows: os.rename ersetzt keine vorhandene Datei) wird Path -> Path.bak rotiert, dann .tmp -> Path;
-- scheitert das (Virenscanner/Indexer haelt .tmp kurz offen), kommt .bak zurueck. Es wird nie geloescht,
-- solange der einzige gueltige Stand nur in der Datei liegt.
local function WriteFail(Path, Msg)
    local Now, Last = os.clock(), Core.WriteErr[Path]
    if A and (not Last or Now - Last >= 60) then
        Core.WriteErr[Path] = Now
        Log(Msg, Path)
    end
    return false
end

function Core.WriteAtomic(Path, Text)
    local Tmp, Bak = Path .. ".tmp", Path .. ".bak"
    local File = io.open(Tmp, "wb")
    if not File then return false end
    local okWrite = File:write(Text)
    if not File:close() then okWrite = false end
    if not okWrite then os.remove(Tmp) return false end
    if os.rename(Tmp, Path) then
        os.remove(Bak)   -- evtl. Rest eines frueher unterbrochenen Speicherns, Path ist jetzt gueltig
        return true
    end
    -- Path existiert (oder Tmp ist gesperrt): rotieren. Ein altes .bak ist jetzt ueberholt (Path ist gueltig).
    local Stale = io.open(Path, "rb")
    if not Stale then
        return WriteFail(Path, "WARNUNG: %s nicht schreibbar (.tmp nicht umbenennbar), Stand bleibt in .tmp")
    end
    Stale:close()
    os.remove(Bak)
    if not os.rename(Path, Bak) then
        os.remove(Tmp)
        return WriteFail(Path, "WARNUNG: %s nicht ersetzbar (alter Stand gesperrt), alter Stand bleibt")
    end
    for _ = 1, 3 do
        if os.rename(Tmp, Path) then
            os.remove(Bak)
            return true
        end
    end
    if not os.rename(Bak, Path) then
        -- alter Stand liegt in .bak (ReadAll findet ihn), neuer in .tmp
        return WriteFail(Path, "FEHLER: %s nicht ersetzbar - alter Stand bleibt in .bak")
    end
    os.remove(Tmp)   -- alter Stand wieder an seinem Platz
    return WriteFail(Path, "WARNUNG: %s nicht ersetzbar (umbenennen gescheitert), alter Stand bleibt")
end

-- Eine per WriteAtomic gepflegte Datei absichtlich loeschen (samt .bak, damit ReadAll sie nicht zurueckholt).
-- Nicht fuer DLL-Dateien benutzen (deren .tmp gehoert der DLL).
function Core.Remove(Path)
    os.remove(Path .. ".bak")
    os.remove(Path .. ".tmp")
    return os.remove(Path)
end

-- coop.txt nochmal lesen: auch Text-Werte (profile=legacy) und Schalter, die main.lua nicht kennt
local function LoadExtra()
    local File = io.open(A.ModDir .. "coop.txt", "r")
    if not File then return end
    for Line in File:lines() do
        local Key, Value = Line:match("^%s*([%w_]+)%s*=%s*(%S+)")
        if Key and A.Settings[Key] == nil then Core.Extra[Key] = Value end
    end
    File:close()
    if A.Settings.profile == nil and Core.Extra.profile then A.Settings.profile = Core.Extra.profile:lower() end
end

local function Off(Default) return type(Default) == "number" and 0 or false end

-- Schalter eines neuen Wegs: Down/legacy -> aus, sonst SETTINGS, sonst coop.txt, sonst Default
function Core.Flag(Name, Default)
    if Core.Down[Name] or A.Settings.profile == "legacy" then return Off(Default) end
    local Value = A.Settings[Name]
    if Value == nil then Value = Core.Extra[Name] end
    if Value == nil then return Default end
    if type(Default) == "number" then return tonumber(Value) or Default end
    if type(Value) == "string" then
        Value = Value:lower()
        return Value:sub(1, 1) == "1" or Value == "true" or Value == "on"
    end
    if type(Value) == "number" then return Value ~= 0 end
    return Value and true or false
end

-- core_down_expire (CORE-12, Sekunden, Standard 600, 0 = nie): ein abgeschalteter Schalter wird danach wieder
-- versucht; die Frist verdoppelt sich mit jeder Abschaltung in dieser Sitzung (hoechstens 1 h bzw. der Grundwert).
-- So erholen sich auch Module, die Core.Down direkt lesen, und vorueber gehende Fehler (Beitritts-Spitze) kosten
-- auf einem Dauer-Server kein Feature bis zum Neustart.
local function DownSpan(Name)
    local Base = Core.Flag("core_down_expire", 600)
    if type(Base) ~= "number" or Base <= 0 then return false end
    return math.min(math.max(Base, 3600), Base * 2 ^ ((Core.DownN[Name] or 1) - 1))
end

-- Fehler melden; gibt true zurueck, wenn der Schalter jetzt (oder schon) aus ist
function Core.Fail(Name, Err)
    if Core.Down[Name] then return true end
    local Now, Kept = os.clock(), {}
    for _, At in ipairs(Core.Fails[Name] or {}) do
        if Now - At <= FAIL_WINDOW then Kept[#Kept + 1] = At end
    end
    Kept[#Kept + 1] = Now
    Core.Fails[Name] = Kept
    if #Kept == 1 then Log("Fehler in %s: %s", Name, tostring(Err)) end
    if #Kept > FAIL_LIMIT then
        Core.Down[Name] = Now
        Core.DownN[Name] = (Core.DownN[Name] or 0) + 1
        local okSpan, Span = pcall(DownSpan, Name)
        Span = okSpan and Span or false
        Core.DownUntil[Name] = Span and Now + Span or false
        Log("FLAG_DOWN %s (%d Fehler in %d s, zuletzt: %s)%s", Name, #Kept, FAIL_WINDOW, tostring(Err),
            Span and string.format(", neuer Versuch in %d s", math.floor(Span)) or "")
        return true
    end
    return false
end

-- Abgelaufene Abschaltungen aufheben (hoechstens alle 5 s, aus RunTasks). Direkt gesetzte Eintraege (true statt
-- Zeitpunkt, ohne Core.Fail) bekommen ihre Frist ab dem ersten Sehen.
function Core.DownTick(Now)
    if Now < (Core.DownCheckAt or 0) or next(Core.Down) == nil then return end
    Core.DownCheckAt = Now + 5
    local Up = {}
    for Name, At in pairs(Core.Down) do
        local Until = Core.DownUntil[Name]
        if Until == nil then
            local Span = DownSpan(Name)
            Core.DownUntil[Name] = Span and Now + Span or false
            if type(At) ~= "number" then Core.Down[Name] = Now end   -- vorhandener Schluessel: erlaubt im pairs
        elseif Until and Now >= Until then
            Up[#Up + 1] = Name
        end
    end
    for _, Name in ipairs(Up) do
        local At = Core.Down[Name]
        Core.Down[Name], Core.Fails[Name], Core.DownUntil[Name] = nil, nil, nil
        Log("FLAG_UP %s (Versuch nach %d s, %d. Abschaltung)", Name, type(At) == "number" and math.floor(Now - At) or 0,
            math.floor(Core.DownN[Name] or 1))
    end
end

-- E25: alle abgeschalteten Schalter sofort wieder an (Konsole "flags", server.lua). Rueckgabe: sortierte Liste der
-- Namen, die aus waren (leer = nichts aus). Die Verdopplungs-Zaehler beginnen neu.
function Core.ResetFlags()
    local Now, List = os.clock(), {}
    for Name, At in pairs(Core.Down) do
        List[#List + 1] = Name
        Log("FLAG_UP %s (Konsole, war %d s aus)", Name, type(At) == "number" and math.floor(Now - At) or 0)
    end
    table.sort(List)
    for _, Name in ipairs(List) do
        Core.Down[Name], Core.Fails[Name], Core.DownUntil[Name], Core.DownN[Name] = nil, nil, nil, nil
    end
    return List
end

-- E24 (CORE-14, untrusted_paths): darf ein Pfad von einem Gast geladen/gesucht werden? Nur "/Game/<Ordner>/<Name>.<Name>"
-- bis 200 Zeichen, nie Karten/Level (Laden eines Level-Pakets ausserhalb der Reise stuerzt ab, main.lua RecastNavMesh),
-- mit Prefixes nur aus diesen Ordnern (nil = jeder Ordner). Den Schalter pruefen die Aufrufer.
function Core.SafeGuestPath(Path, Prefixes)
    if type(Path) ~= "string" or #Path > 200 or not Path:match("^/Game/[%w_/]+%.[%w_]+$") then return false end
    local Low = Path:lower()
    for _, Bad in ipairs({ "/maps/", "/levels/", "/__externalactors__/", "/__externalobjects__/" }) do
        if Low:find(Bad, 1, true) then return false end
    end
    if Prefixes == nil then return true end
    for _, P in ipairs(Prefixes) do
        if type(P) == "string" and P ~= "" and Path:sub(1, #P) == P then return true end
    end
    return false
end

-- world_hygiene (CORE-8 f): zwischen LoadMap und Coop.DropWorldRefs laeuft keine Aufgabe (sie faessten Objekte der
-- alten Welt an - Absturz, den kein pcall faengt; dazu gehoeren auch die Netz-Handler in net_in). Hoechstens 10 s je
-- Weltgeneration, dann einmal melden und weiterlaufen (haengt der Schnell-Loop, steht sonst alles).
local function WorldGate(Now)
    local W = A and A.WorldGen
    if not W then return false end
    if not ((W.Loading and Now - (W.LoadingAt or 0) < 60) or W.Dropped ~= W.N) then return false end
    if not Core.Flag("world_hygiene", true) then return false end
    if Core.GateGen ~= W.N then Core.GateGen, Core.GateAt, Core.GateLogged = W.N, Now, false end
    if Now - Core.GateAt < 10 then return true end
    if not Core.GateLogged then
        Core.GateLogged = true
        Log("Weltwechsel-Sperre abgelaufen (Welt %d, %s): Aufgaben laufen wieder", W.N,
            W.Loading and "Karte laedt noch" or "alte Objekte nicht vergessen")
    end
    return false
end

local function RunTasks()
    local Now = os.clock()
    local okD, errD = pcall(Core.DownTick, Now)
    if not okD and not Core.DownErr then Core.DownErr = true Log("Ablauf-Fehler: %s", tostring(errD)) end
    if WorldGate(Now) then return end
    for _, Name in ipairs(Core.Order) do
        local Task = Core.Tasks[Name]
        if Task and Now >= Task.Next and not Core.Down[Name] then
            Task.Next = Now + Task.Period
            local T0 = os.clock()
            local ok, Result = pcall(Task.Fn, Now)
            if not Task.NoPerf then
                local T1 = os.clock()
                Core.PerfAdd(Name, T1 - T0, T1)
            end
            if not ok then Core.Fail(Name, Result)
            elseif Result == true then Core.Cancel(Name) end   -- true = Aufgabe fertig
        end
    end
    -- Abgemeldete Aufgaben aus der Reihenfolge nehmen (nicht waehrend der Schleife oben)
    if Core.Dirty then
        local Order, Seen = {}, {}
        for _, Name in ipairs(Core.Order) do
            if Core.Tasks[Name] and not Seen[Name] then Seen[Name], Order[#Order + 1] = true, Name end
        end
        Core.Order, Core.Dirty = Order, false
    end
end

local function StartLoop()
    if Core.LoopStarted then return end
    Core.LoopStarted = true
    local function Tick()
        local ok, err = pcall(RunTasks)
        if not ok and not Core.LoopErr then Core.LoopErr = true Log("Schleifen-Fehler: %s", tostring(err)) end
    end
    if LoopInGameThreadWithDelay then
        LoopInGameThreadWithDelay(100, Tick)
    else
        LoopAsync(100, function() ExecuteInGameThread(Tick) return false end)
    end
end

-- Fn(now) alle Period Sekunden im Spiel-Thread; Fn gibt true zurueck = fertig. Gleicher Name ersetzt.
-- Fehler zaehlen auf den Aufgaben-Namen (Core.Fail); ist er Down, laeuft die Aufgabe nicht mehr.
function Core.Every(Name, Period, Fn)
    if not Core.Tasks[Name] then Core.Order[#Core.Order + 1] = Name end
    Core.Tasks[Name] = { Period = Period, Fn = Fn, Next = 0 }
    StartLoop()
end

function Core.Cancel(Name)
    if Core.Tasks[Name] then Core.Tasks[Name], Core.Dirty = nil, true end
end

-- HostTick/ClientTick der Module jede Sekunde (main.lua ruft das nach dem Laden einmal auf)
function Core.StartModuleTicks()
    local Any = false
    for _, M in pairs(A.Coop.Modules or {}) do
        if M.HostTick or M.ClientTick then Any = true end
    end
    if not Any then return end
    Core.Every("modtick", 1.0, function(Now)
        local World = A.CurrentWorld()
        if not (World and A.IsAlive(World)) then return end
        local Mode = A.Safe(function() return A.NetModeName(World) end, nil)
        local Host = Mode == "ListenServer" or Mode == "DedicatedServer"
        for _, Name in ipairs(A.Coop.ModuleOrder or {}) do
            local M = A.Coop.Modules[Name]
            local Fn = M and (Host and M.HostTick or (Mode == "Client" and M.ClientTick))
            local Flag = "tick_" .. Name
            if Fn and not Core.Down[Flag] then
                local T0 = os.clock()
                local ok, err = pcall(Fn, Now)
                local T1 = os.clock()
                Core.PerfAdd(Flag, T1 - T0, T1)
                if not ok then Core.Fail(Flag, err) end
            end
        end
    end)
    Core.Tasks.modtick.NoPerf = true   -- Zeit steht je Modul unter tick_<Modul>, nicht doppelt als modtick
end

-- Gast-Bytecode-Patch (netcore_patch.txt) ueber die Registry in main.lua, egal welche Form dort umgesetzt ist:
-- Coop.SetPatch(Name, Zeile) (ls_ui-Antrag) oder Tabelle Coop.ClientPatches[Name] = Zeile + Coop.PatchesDirty
-- (ls_world-Antrag). Zeile ohne "\n"; Abschalten = gleiche Zeile mit 0 am Ende. Rueckgabe true = eingetragen.
function Core.HasPatchRegistry()
    local Coop = A and A.Coop
    return Coop ~= nil and (type(Coop.SetPatch) == "function" or type(Coop.ClientPatches) == "table")
end

function Core.SetPatch(Name, Line)
    local Coop = A and A.Coop
    if not Coop or type(Name) ~= "string" or type(Line) ~= "string" then return false end
    if type(Coop.SetPatch) == "function" then return (pcall(Coop.SetPatch, Name, Line)) end
    if type(Coop.ClientPatches) == "table" then
        Coop.ClientPatches[Name] = Line
        Coop.PatchesDirty = true
        return true
    end
    return false
end

function Core.Init(Api)
    A = Api
    LoadExtra()
    rawset(_G, "LS_ALIVE_V56", Core.Flag("alive_v56", true))   -- neuer IsAlive-Check (alive_v56=0 = alter Weg)
    if A.Settings.profile == "legacy" then Log("profile=legacy: neue Wege aus") end
    if A.TestCommands then A.TestCommands.perf = function() Log("Leistung: %s", (Core.PerfReport(10))) end end
end

return Core
