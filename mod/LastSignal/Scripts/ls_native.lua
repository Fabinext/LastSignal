-- Last Signal, Runde 5: Datei-Austausch mit LastSignalCore.dll (Worker-Thread der DLL fragt alle 100-500 ms ab).
--   Native.Request(name, text)  schreibt netcore_<name>_req.txt, nur wenn keine Anfrage mehr wartet
--   Native.ReadResult(name)     liest netcore_<name>_done.txt bzw. netcore_<name>.txt
--   Native.ReadDone(name, seq)  "DONE <seq> key=wert ..." -> Tabelle der Werte, sonst nil
--   Native.Available()          kann der DLL-Beobachter arbeiten? (netcore_status.txt)
--   Native.Watch(...)           N4b: Blueprint-Aufrufe beobachten/unterdruecken (netcore_watch.txt)
--                               (list, owner) oder (tag, "/Pfad:Funktion", "fields=..;pre=..;owner=local")
--   Native.Events(name)         N4b: neue Ereignisse seit dem letzten Aufruf (netcore_events.txt)
--                               name = Tag -> nur dieser Tag, mit benannten Feldern; "main"/"_x" -> alle
--   Native.OnEvent(tag, fn)     N4b: Ereignisse eines Tags im 100-ms-Takt zustellen
--   Native.WritePlayers()       N6: Gaeste fuer "naechster Gast" (netcore_players.txt, Host, jede Sekunde)
--   Native.SetDeny(list, owner) Runde 7: Blueprint-Aufrufe beim Eintritt verwerfen (netcore_deny.txt, Host)
--   Native.SetAllies(map)       Runde 7: [Pawn] = Clan-Index fuer ff mit pvp=1 (netcore_allies.txt)
--   Native.WriteN6()            Runde 9: N6-Liste netcore_n6.txt (ai_n6_list=safe|full), immer vor netcore_opts.txt
-- Runde 9: Watch-Eintraege mit Remote = true -> " remote=1" (nur mit DLL-Status feat_remote=1, sonst weggelassen: eine
-- alte DLL ignoriert das Wort und wuerde jeden Aufruf unterdruecken); opts drop_outer (INV-15); SetDeny nimmt auch
-- Hex-Adressen; Sperrliste in fester Besitzer-Reihenfolge; Ereignis-Datei hoechstens alle 50 ms gelesen.
-- Native.Watch und Native.Events gibt es nur, solange Native.Available() wahr ist (Feature-Erkennung der Module:
-- type(Native.Watch) == "function"). Immer vorhanden: Native.SetWatch, Native.ReadEvents.
-- Doku: _NetTest\analysis\API_NATIVE.md
local Native = {}
local Core = require("ls_core")
local A           -- API aus main.lua (siehe Init)
local Hidden = {} -- Watch/Events, sichtbar nur mit verfuegbarem Beobachter

local function Log(fmt, ...) A.Log("[Native] " .. fmt, ...) end

-- Mod-Ordner der DLL (absolut, mit Trenner am Ende); netcore.cfg und netcore_*.txt liegen dort
function Native.Dir()
    if not Native.Root then
        Native.Root = A.Safe(function() return A.ModRoot() end, nil) or A.ModDir
    end
    return Native.Root
end

function Native.Path(Name, Suffix)
    return Native.Dir() .. "netcore_" .. Name .. (Suffix or "")
end

function Native.Pending(Name)
    local File = io.open(Native.Path(Name, "_req.txt"), "rb")
    if File then File:close() return true end
    return false
end

-- Gibt true zurueck, wenn die Anfrage liegt; false, "pending" wenn die vorige noch nicht abgeholt ist
function Native.Request(Name, Text)
    if Native.Pending(Name) then return false, "pending" end
    if not Core.WriteAtomic(Native.Path(Name, "_req.txt"), Text) then return false, "write" end
    return true
end

-- Nicht abgeholte Anfrage zuruecknehmen (z. B. nach Zeitablauf, DLL laeuft nicht)
function Native.Cancel(Name)
    os.remove(Native.Path(Name, "_req.txt"))
end

function Native.ReadResult(Name)
    return Core.ReadAll(Native.Path(Name, "_done.txt")) or Core.ReadAll(Native.Path(Name, ".txt"))
end

function Native.ReadDone(Name, Seq)
    local Text = Core.ReadAll(Native.Path(Name, "_done.txt"))
    local Got, Rest = (Text or ""):match("^%s*DONE%s+(%d+)(.*)")
    if not Got or tonumber(Got) ~= Seq then return nil end
    local Result = { seq = Seq }
    for Key, Value in Rest:gmatch("([%w_]+)=(%S+)") do Result[Key] = tonumber(Value) or Value end
    return Result
end

-- Fortlaufende Nummer je Sitzung, startet bei der Uhrzeit (alte _done-Dateien passen so nie)
function Native.NextSeq()
    Native.Seq = math.max((Native.Seq or 0) + 1, os.time())
    return Native.Seq
end

-- DLL-Zustand aus netcore_status.txt (schreibt die DLL bei Aenderung bzw. wenn die Datei fehlt), 2 s Cache
function Native.Status()
    local Now = os.clock()
    if Native.StatusAt and Now - Native.StatusAt < 2 then return Native.StatusTab end
    Native.StatusAt = Now
    local Text, Tab = Core.ReadAll(Native.Path("status", ".txt")), nil
    if Text then
        Tab = {}
        for Key, Value in Text:gmatch("([%w_]+)=(%S+)") do Tab[Key] = tonumber(Value) or Value end
    end
    Native.StatusTab = Tab
    return Tab
end

-- Beobachter nutzbar: DLL laeuft, GNatives bekannt, nicht nach Fehlern abgeschaltet, native_observer an
function Native.Available()
    if not A or Core.Down.native_watch or not Core.Flag("native_observer", true) then return false end
    local S = Native.Status()
    return S ~= nil and S.capable == 1
end

-- ---------------------------------------------------------------- N4b: Beobachter

Native.Watches = {}        -- [Besitzer] = { {Func=, Tag=, Mode="observe"|"suppress", Force=bool, Opts=" ..."}, ... }
Native.Named = {}          -- [Tag] = { Order = {Pfad...}, Fields = {..}, Local = bool, Pre = {shotdist=, ffblock=} }
Native.WatchDirty = true
local PLAYER_CLASS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

-- UFunction (Objekt, "/Script/..."-Pfad oder Hex-Adresse) -> Hex-Adresse oder nil (nur Spiel-Thread)
local function FuncAddress(Func)
    if type(Func) == "string" then
        if Func:match("^%x+$") then return Func:upper() end
        local Obj = A.Safe(function() return StaticFindObject(Func) end, nil)
        if Obj and A.IsAlive(Obj) then return A.Safe(function() return string.format("%X", Obj:GetAddress()) end, nil) end
        return nil
    end
    if Func and A.IsAlive(Func) then return A.Safe(function() return string.format("%X", Func:GetAddress()) end, nil) end
    return nil
end

local function PropertyOffset(ClassPath, Name)
    local Class, Found = StaticFindObject(ClassPath), nil
    if not (Class and Class:IsValid()) then return nil end
    Class:ForEachProperty(function(Property)
        if Property:GetFName():ToString() == Name then
            Found = Property:GetOffset_Internal()
            return true
        end
    end)
    return Found
end

-- Zusatzoptionen einer Watch-Zeile: Opts (roh, Listenform) bzw. aus At/Local/Remote/Pre (benannte Form):
-- at=entry|call, local=1, remote=1 (WORLD-7: nur Kontexte fremder Figuren), sd=<Offset ShotDistance der Klasse>,
-- ff=<Spielerklasse>|pc
local function LineOptions(W)
    local Out = W.Opts and (" " .. tostring(W.Opts):gsub("^%s+", "")) or ""
    if W.At then Out = Out .. " at=" .. W.At end
    if W.Local then Out = Out .. " local=1" end
    if W.Remote then Out = Out .. " remote=1" end
    if W.Pre and W.Pre.shotdist then
        local ClassPath = type(W.Func) == "string" and W.Func:match("^(.-):[^:]+$")
        Native.SdCache = Native.SdCache or {}
        local Off = ClassPath and Native.SdCache[ClassPath]
        if ClassPath and Off == nil then
            Off = A.Safe(function() return PropertyOffset(ClassPath, "ShotDistance") end, nil) or false
            if Off then Native.SdCache[ClassPath] = Off end
        end
        if Off then Out = Out .. string.format(" sd=%X", Off) end
    end
    if W.Pre and W.Pre.ffblock then
        local Cls = A.Safe(function() return StaticFindObject(PLAYER_CLASS) end, nil)
        local Addr = Cls and A.IsAlive(Cls) and A.Safe(function() return Cls:GetAddress() end, nil)
        Out = Out .. (Addr and string.format(" ff=%X", Addr) or " ff=pc")
    end
    return Out
end

-- Liste eines Besitzers setzen (nil/{} loescht sie) und netcore_watch.txt neu schreiben
function Native.SetWatch(List, Owner)
    Native.Watches[Owner or "main"] = List
    Native.WatchDirty = true
    return Native.FlushWatch()
end

-- "fields=a,b;pre=shotdist,ffblock;owner=local;at=entry;mode=suppress" -> Tabelle
local function ParseOptions(Text)
    local O = { Fields = {}, Pre = {} }
    for Part in tostring(Text or ""):gmatch("[^;]+") do
        local Key, Value = Part:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if Key == "fields" then
            for F in Value:gmatch("[^,%s]+") do O.Fields[#O.Fields + 1] = F end
        elseif Key == "pre" then
            for P in Value:gmatch("[^,%s]+") do O.Pre[P] = true end
        elseif Key == "owner" then
            O.Local = Value == "local"
            O.Remote = Value == "remote"
        elseif Key == "remote" then
            O.Remote = Value == "1"
        elseif Key == "at" and (Value == "entry" or Value == "call") then
            O.At = Value
        elseif Key == "mode" and (Value == "observe" or Value == "suppress") then
            O.Mode = Value
        end
    end
    return O
end

-- Benannte Beobachtung (ls_combat): mehrere Aufrufe mit demselben Tag sammeln die Funktionen
local function NamedWatch(Tag, Path, Options)
    Tag = (tostring(Tag):gsub("[^%w_]", "_")):sub(1, 31)
    local N = Native.Named[Tag] or { Order = {}, Seen = {} }
    Native.Named[Tag] = N
    local O = ParseOptions(Options)
    if #O.Fields > 0 then N.Fields = O.Fields end
    N.Local, N.Remote, N.Pre, N.At, N.Mode = O.Local, O.Remote, O.Pre, O.At, O.Mode
    if not N.Seen[Path] then
        N.Seen[Path] = true
        N.Order[#N.Order + 1] = Path
    end
    local List = {}
    for _, P in ipairs(N.Order) do
        List[#List + 1] = { Func = P, Tag = Tag, Mode = N.Mode or "observe", Local = N.Local, Remote = N.Remote, Pre = N.Pre,
                            At = N.At }
    end
    Native.Watches["@" .. Tag] = List
    Native.WatchDirty = true
    Native.InfoAt = nil
    return Native.FlushWatch()
end

function Hidden.Watch(First, Second, Third)
    if type(First) == "string" and type(Second) == "string" then return NamedWatch(First, Second, Third) end
    return Native.SetWatch(First, Second)
end

-- Alle Listen aufloesen; geschrieben wird nur bei geaendertem Inhalt. Nicht gefundene Funktionen fehlen
-- (die Aufgabe native_watch versucht es spaeter erneut, z. B. nach dem Laden der Klasse).
function Native.FlushWatch()
    local Lines, Seen, Missing = {}, {}, 0
    -- remote=1 kennt nur die neue DLL (Status feat_remote=1). Eine alte ignoriert das Wort: aus "nur fremde Figuren
    -- unterdruecken" wuerde "alle unterdruecken". Solche Eintraege bis dahin weglassen (die Aufgabe schreibt neu).
    local S = Native.Status()
    local RemoteOk = S ~= nil and tonumber(S.feat_remote) == 1
    local RemoteSkip = 0
    for Owner, List in pairs(Native.Watches) do
        for _, W in ipairs(List or {}) do
            local Addr = FuncAddress(W.Func or W[1])
            local Tag = (tostring(W.Tag or W[2] or Owner):gsub("[^%w_]", "_")):sub(1, 31)
            local Mode = (W.Mode or W[3]) == "suppress" and "suppress" or "observe"
            if not RemoteOk and (W.Remote or (W.Opts and tostring(W.Opts):find("remote=1", 1, true))) then
                RemoteSkip = RemoteSkip + 1
            elseif not Addr then
                Missing = Missing + 1
            elseif not Seen[Addr] then
                Seen[Addr] = true
                Lines[#Lines + 1] = string.format("%s %s %s%s%s", Addr, Tag, Mode, W.Force and " force" or "",
                    A.Safe(function() return LineOptions(W) end, "") or "")
            end
        end
    end
    table.sort(Lines)
    local Text = table.concat(Lines, "\n") .. (#Lines > 0 and "\n" or "")
    Native.WatchDirty, Native.WatchMissing = Missing > 0, Missing
    if RemoteSkip ~= (Native.RemoteSkip or 0) then
        Native.RemoteSkip = RemoteSkip
        if RemoteSkip > 0 then Log("Beobachtung: %d Eintraege mit remote=1 weggelassen (DLL ohne feat_remote)", RemoteSkip) end
    end
    if Text == Native.WatchText then return true end
    if not Core.WriteAtomic(Native.Path("watch", ".txt"), Text) then return false end
    Native.WatchText = Text
    Log("Beobachtung: %d Funktionen%s", #Lines, Missing > 0 and string.format(" (%d nicht gefunden)", Missing) or "")
    return true
end

local function Unescape(S)
    return (S:gsub("%%(%x%x)", function(H) return string.char(tonumber(H, 16)) end))
end

local STRUCT_KEYS = { v = { "X", "Y", "Z" }, r = { "Pitch", "Yaw", "Roll" }, c = { "R", "G", "B", "A" } }

-- "o:<Klasse Pfad>" -> String, "o:-" -> false, "o:0x.." (tot) -> "0x..", i/f -> Zahl, b -> bool, s/n -> String,
-- v/r/c -> Tabelle {X,Y,Z} / {Pitch,Yaw,Roll} / {R,G,B,A}
local function DecodeValue(Token)
    local Kind, Value = Token:sub(1, 1), Token:sub(3)
    if Kind == "o" then
        if Value == "-" then return false end
        return Unescape(Value)
    elseif Kind == "i" or Kind == "f" then
        return tonumber(Value)
    elseif Kind == "b" then
        return Value == "1"
    elseif Kind == "s" or Kind == "n" then
        return Unescape(Value)
    elseif STRUCT_KEYS[Kind] and Token:sub(2, 2) == ":" then
        local Keys, Out, I = STRUCT_KEYS[Kind], {}, 0
        for Num in Value:gmatch("[^,]+") do
            I = I + 1
            if Keys[I] then Out[Keys[I]] = tonumber(Num) end
        end
        return Out
    end
    return nil   -- "?" unbekannt, "^" Out-Parameter
end

local function ParseEvents(Text)
    local List = {}
    for Line in Text:gmatch("[^\n]+") do
        if Line:sub(1, 1) ~= "#" then
            local F = {}
            for Field in (Line .. "\t"):gmatch("([^\t]*)\t") do F[#F + 1] = Field end
            local Seq = tonumber(F[1])
            if Seq and #F >= 6 then
                local Flags = F[3] or ""
                local Remote = nil
                if Flags:find("R", 2, true) then Remote = true elseif Flags:find("L", 2, true) then Remote = false end
                local Ev = { Seq = Seq, Tag = F[2], Suppressed = Flags:sub(1, 1) == "s", Remote = Remote,
                             Blocked = Flags:find("F", 2, true) ~= nil, Entry = Flags:find("E", 2, true) ~= nil,
                             Distance = Flags:find("D", 2, true) ~= nil, Ctx = DecodeValue(F[4]),
                             Caller = DecodeValue(F[5]), Ms = tonumber(F[6]), Args = {}, Raw = {}, N = #F - 6 }
                for I = 7, #F do
                    Ev.Raw[I - 6] = F[I]
                    Ev.Args[I - 6] = DecodeValue(F[I])
                end
                List[#List + 1] = Ev
            end
        end
    end
    return List
end

-- netcore_watchinfo.txt (DLL): je Tag die Parameter "Name:Typ" (erste Zeile des Tags), 2 s Cache
local function WatchInfo()
    local Now = os.clock()
    if Native.Info and Native.InfoAt and Now - Native.InfoAt < 2 then return Native.Info end
    Native.InfoAt = Now
    local Text = Core.ReadAll(Native.Path("watchinfo", ".txt")) or ""
    if Text == Native.InfoText and Native.Info then return Native.Info end
    local Info = {}
    for Line in Text:gmatch("[^\n]+") do
        local Tag, Func, At, Mode, Params = Line:match("^([^\t]+)\t(%x+)\t(%a+)\t([^\t]*)\t?(.*)$")
        if Tag and not Info[Tag] then
            local List = {}
            for Name, Type in (Params or ""):gmatch("([^,:]+):(.)") do List[#List + 1] = { Name = Name, Type = Type } end
            Info[Tag] = { Func = Func, At = At, Mode = Mode, Params = List }
        end
    end
    Native.Info, Native.InfoText, Native.MapCache = Info, Text, {}
    return Info
end

local SPECIAL = { self = true, caller = true, ctx = true, remote = true, t = true, blocked = true }
local COMP = { x = "X", y = "Y", z = "Z", r = "R", g = "G", b = "B", a = "A" }

-- Feldnamen -> { Param-Index, Struct-Schluessel } ueber die Parameternamen der DLL:
-- 1. gleicher Name oder enthalten (ab 3 Zeichen), 2. "mx"/"ey": Vektor, dessen Name mit m/e beginnt,
-- 3. r/g/b/a: Farbe, x/y/z: erster Vektor, 4. Rest der Reihe nach auf die freien einfachen Parameter
local function MapFields(Fields, Params)
    local Map, Used, Open = {}, {}, {}
    local function IsStruct(P) return STRUCT_KEYS[P.Type] ~= nil end
    for _, F in ipairs(Fields) do
        local L = F:lower()
        if not SPECIAL[L] then
            local Hit
            for I, P in ipairs(Params) do
                local PN = P.Name:lower()
                if not Used[I] and not IsStruct(P) and (PN == L or (#L >= 3 and PN:find(L, 1, true))) then
                    Hit = { I } Used[I] = true break
                end
            end
            if not Hit and #L == 2 and COMP[L:sub(2)] then
                for I, P in ipairs(Params) do
                    if P.Type == "v" and P.Name:lower():sub(1, 1) == L:sub(1, 1) then Hit = { I, COMP[L:sub(2)] } break end
                end
            end
            if not Hit and #L == 1 and COMP[L] then
                local Want = L:match("[xyz]") and "v" or "c"
                for I, P in ipairs(Params) do
                    if P.Type == Want then Hit = { I, COMP[L] } break end
                end
            end
            if Hit then Map[F] = Hit else Open[#Open + 1] = F end
        end
    end
    for _, F in ipairs(Open) do
        for I, P in ipairs(Params) do
            if not Used[I] and not IsStruct(P) then
                Map[F], Used[I] = { I }, true
                break
            end
        end
    end
    return Map
end

local function PathOf(Value)
    if type(Value) ~= "string" then return Value end
    return Value:match("^%S+%s+(.+)$") or Value
end

-- Ereignis -> neue Tabelle mit Feldern: self/caller (Pfad ohne Klasse), remote (1/0), blocked, t, a1..aN
-- (Objekte als Pfad), dazu die mit fields= angeforderten Namen (Objekte als FName, <feld>_path = Pfad)
local function Shape(Ev, Fields)
    local E = {}
    for K, V in pairs(Ev) do E[K] = V end
    E.t, E.self, E.ctx, E.caller = os.clock(), PathOf(Ev.Ctx), Ev.Ctx, PathOf(Ev.Caller)
    if Ev.Remote ~= nil then E.remote = Ev.Remote and 1 or 0 end
    E.blocked = Ev.Blocked and 1 or 0
    for I = 1, Ev.N or 0 do
        local V = Ev.Args[I]
        if Ev.Raw[I] and Ev.Raw[I]:sub(1, 2) == "o:" then V = PathOf(V) end
        E["a" .. I] = V
    end
    if Fields and #Fields > 0 then
        local Info = WatchInfo()[Ev.Tag]
        local Key = Ev.Tag .. "|" .. table.concat(Fields, ",")
        Native.MapCache = Native.MapCache or {}
        local Map = Native.MapCache[Key]
        if not Map and Info then
            Map = MapFields(Fields, Info.Params)
            Native.MapCache[Key] = Map
        end
        for F, M in pairs(Map or {}) do
            local V, Raw = Ev.Args[M[1]], Ev.Raw[M[1]] or ""
            if M[2] then
                V = type(V) == "table" and V[M[2]] or nil
            elseif Raw:sub(1, 2) == "o:" and type(V) == "string" then
                E[F .. "_path"] = PathOf(V)
                V = PathOf(V):match("[^%.:]+$")
            elseif type(V) == "boolean" then
                V = V and 1 or 0
            end
            E[F] = V
        end
    end
    return E
end

-- DLL CORE-25 (d): Kopfzeile von netcore_events.txt hinten optional " lost=<tag>:<n>,..." = je Tag vor Ablauf der 10 s
-- aus dem Fenster gefallene Ereignisse (Summe der DLL-Sitzung, die 16 groessten). Native.EvLost zaehlt nur die Luecke
-- vor dem ersten neuen Ereignis des All-Cursors (Fenster je Tag 64: Luecken mitten im Fenster fehlen dort).
-- Native.EvLostTag[Tag] = n, neu je DLL-Sitzung; ein Tag, der aus den 16 groessten faellt, behaelt seinen letzten Wert.
function Native.ReadLost(Text)
    if not Core.Flag("native_evlost", true) then return end
    local Raw = Text:match("^[^\n]* lost=(%S+)")
    if not Raw or Raw == Native.EvLostRaw then return end
    Native.EvLostRaw = Raw
    local Into = Native.EvLostTag or {}
    Native.EvLostTag = Into
    for Tag, N in Raw:gmatch("([^,:]+):(%d+)") do Into[Tag] = tonumber(N) end
end

-- Neue Ereignisse seit dem letzten Aufruf mit demselben Namen. "main", "*" und "_..." = alle Tags (Cursor),
-- jeder andere Name = nur dieser Tag (eigener Cursor, Tabellen mit benannten Feldern, neu je Aufruf).
-- Ein neuer Cursor bekommt das ganze Fenster der DLL (hoechstens 256 Ereignisse, <= 10 s alt).
function Native.ReadEvents(Name)
    Name = Name or "main"
    local All = Name == "main" or Name == "*" or Name:sub(1, 1) == "_"
    local Cursor = All and Name or ("#" .. Name)
    -- CORE-27: die Datei hoechstens alle 50 ms lesen (sonst 30-50 Lesezugriffe/s: jede Aufgabe mit eigenem Cursor)
    local Now, Text = os.clock(), nil
    if Native.EvText ~= nil and Now - (Native.EvTextAt or -1) < 0.05 and Now >= (Native.EvTextAt or 0) then
        Text = Native.EvText
    else
        Text = Core.ReadAll(Native.Path("events", ".txt"))
        Native.EvText, Native.EvTextAt = Text or false, Now
    end
    if not Text then return {} end
    local Session, Last, Dropped = Text:match("^#E (%x+) (%d+) (%d+)")
    if not Session then return {} end
    Last = tonumber(Last)
    if Session ~= Native.EvSession then
        Native.EvSession, Native.EvCursor, Native.EvParsed, Native.EvLost = Session, {}, nil, 0
        Native.EvLostTag, Native.EvLostRaw, Native.EvLostAt = {}, nil, nil
    end
    Native.EvDropped, Native.EvLast = tonumber(Dropped), Last
    -- native_evlost: Verluste je Tag aus der Kopfzeile (nur Diagnose), einmal je neuem Stand; eigener Autofallback,
    -- ein Fehler hier schaltet nie die Zustellung (native_ev) ab
    if Last ~= Native.EvLostAt and not Core.Down.native_evlost then
        Native.EvLostAt = Last
        local okL, errL = pcall(Native.ReadLost, Text)
        if not okL then Core.Fail("native_evlost", errL) end
    end
    local From = Native.EvCursor[Cursor] or 0
    if Last <= From then return {} end
    if not Native.EvParsed or Native.EvParsedLast ~= Last then
        Native.EvParsed, Native.EvParsedLast = ParseEvents(Text), Last
    end
    local Out = {}
    local Named = not All and Native.Named[Name]
    for _, Ev in ipairs(Native.EvParsed) do
        if Ev.Seq > From then
            if All then
                Out[#Out + 1] = Ev
            elseif Ev.Tag == Name and #Out < 256 then
                Out[#Out + 1] = Shape(Ev, Named and Named.Fields)
            end
        end
    end
    if All and From > 0 and Out[1] and Out[1].Seq > From + 1 then
        Native.EvLost = (Native.EvLost or 0) + Out[1].Seq - From - 1
    end
    Native.EvCursor[Cursor] = Last
    return Out
end
Hidden.Events = Native.ReadEvents

-- Native.Watch/Native.Events nur bei verfuegbarem Beobachter (sonst nil -> Module nehmen ihre Lua-Wege)
setmetatable(Native, { __index = function(_, Key)
    if Hidden[Key] and Native.Available() then return Hidden[Key] end
    return nil
end })

Native.Subs = {}   -- [Tag] = { fn(ev), ... }

-- Zustellung im 100-ms-Takt (Spiel-Thread, UFunctions erlaubt, jeder Aufruf in pcall)
function Native.Pump()
    if not next(Native.Subs) then return true end
    for _, Ev in ipairs(Native.ReadEvents("_pump")) do
        local Flag = "native_ev_" .. Ev.Tag
        for _, Fn in ipairs(Native.Subs[Ev.Tag] or {}) do
            if not Core.Down[Flag] then
                local ok, err = pcall(Fn, Ev)
                if not ok then Core.Fail(Flag, err) end
            end
        end
    end
end

function Native.OnEvent(Tag, Fn)
    local List = Native.Subs[Tag] or {}
    Native.Subs[Tag] = List
    for _, Known in ipairs(List) do
        if Known == Fn then return end
    end
    List[#List + 1] = Fn
    if not (Core.Tasks and Core.Tasks.native_ev) then Core.Every("native_ev", 0.1, Native.Pump) end
end

-- N8: Quest-Fortschritt der Narrative-Bibliothek (Host). Ereignis: Caller = Ausloeser (Zombie, Spawner, ...),
-- Args[1] Narrative-Komponente, Args[2] Task-Asset (nur n8_task), dann Argument (String) und Menge (Zahl)
Native.N8 = {
    { Func = "/Script/Narrative.NarrativeFunctionLibrary:CompleteNarrativeDataTask", Tag = "n8_task", Mode = "observe" },
    { Func = "/Script/Narrative.NarrativeFunctionLibrary:CompleteLooseNarrativeDataTask", Tag = "n8_loose", Mode = "observe" },
}

-- ---------------------------------------------------------------- Runde 7: Sperrliste und Clan-Verbuendete

-- Sperrliste (Host): Native.SetDeny(Entries[, Owner]) mit Eintraegen
--   { Func = "/Game/...Klasse_C:Funktion" | UFunction, Context = <UObject>, Param = "<Parametername>" | nil,
--     Value = <UObject> | false (Parameter null), Tag = "deny" (optional, [%w_], <= 31) }
-- Die DLL verwirft einen Aufruf der Blueprint-Funktion beim Eintritt, wenn Kontext und Parameterwert passen
-- (Param nil = jeder Aufruf mit diesem Kontext). Jeder Besitzer (Standard "main") hat seine eigene Liste.
-- Gast/Einzelspieler-Gast: Datei bleibt leer. Rueckgabe: Anzahl geschriebener Zeilen bzw. false bei Schreibfehler.
Native.DenyLists = {}   -- [Besitzer] = Liste
Native.DenyGens = {}    -- [Besitzer] = WorldGen.N beim SetDeny (Objekte gehoeren zu genau dieser Welt)
local DENY_MAX = 256

-- Weltwechsel-Schutz: Objekte einer alten Welt (auch IsAlive) crashen nativ (main.lua WorldGen). Laedt gerade eine
-- Karte (<= 60 s) oder stammt eine Liste aus einer anderen Generation, wird sie verworfen, BEVOR ein UObject
-- angefasst wird. Die Besitzer (build_deny, cb_pvp) setzen nach dem Laden frische Listen.
local function DenyWorld()
    local W = A and A.WorldGen
    local N = W and W.N or 0
    local Loading = W and W.Loading and os.clock() - (W.LoadingAt or 0) < 60 or false
    return N, Loading
end

-- Objekt -> Hex-Adresse. CORE-19: auch eine Hex-Adresse (String), die der Besitzer im selben Tick aufgeloest hat - so
-- haelt keine Liste UObjects ueber Ticks (GC/Weltwechsel); die DLL prueft Adresse und Name selbst.
local function DenyAddress(Obj)
    if type(Obj) == "string" then
        local Hex = Obj:match("^%s*0?[xX]?(%x+)%s*$")
        if not Hex or #Hex > 16 or Hex:match("^0*$") then return nil end
        return Hex:upper()
    end
    if not (Obj and A.IsAlive(Obj)) then return nil end
    return A.Safe(function() return string.format("%X", Obj:GetAddress()) end, nil)
end

-- Eintrag -> Zeile "<Func> <Kontext> <Param|-> <Wert|0> <Tag>" oder nil (tot, ungueltig)
local function DenyLine(E, FuncCache)
    if type(E) ~= "table" then return nil end
    local Key = E.Func
    local Func = FuncCache[Key]
    if Func == nil then
        Func = FuncAddress(Key) or false
        FuncCache[Key] = Func
    end
    if not Func then return nil end
    local Ctx = DenyAddress(E.Context)
    if not Ctx then return nil end
    local Param, Value = "-", "0"
    if E.Param ~= nil then
        Param = tostring(E.Param)
        if not Param:match("^[%w_]+$") then return nil end
        if E.Value == false then
            Value = "0"
        else
            Value = DenyAddress(E.Value)
            if not Value then return nil end
        end
    end
    local Tag = (tostring(E.Tag or "deny"):gsub("[^%w_]", "_")):sub(1, 31)
    return string.format("%s %s %s %s %s", Func, Ctx, Param, Value, Tag)
end

-- CORE-19 / FIXPLAN 4.4: feste Reihenfolge der Besitzer, wenn DENY_MAX nicht fuer alle reicht (Kampf-Sperren zuerst,
-- dann Fahrzeuge, dann Bauen, dann alle uebrigen alphabetisch); abgeschnittene Zeilen je Besitzer werden gemeldet.
local DENY_ORDER = { "ls_combat_mrel", "ls_combat_sde", "ls_car", "ls_build" }

function Native.FlushDeny()
    local Lines, Seen, FuncCache = {}, {}, {}
    local Gen, Loading = DenyWorld()
    local Dropped = 0
    for Owner in pairs(Native.DenyLists) do
        if Loading or Native.DenyGens[Owner] ~= Gen then
            Native.DenyLists[Owner], Native.DenyGens[Owner] = nil, nil
            Dropped = Dropped + 1
        end
    end
    if Dropped > 0 then Log("Weltwechsel: Sperrliste geleert (%d Besitzer)", Dropped) end
    local Cut, CutText = {}, {}
    if A and A.Net and A.Net.Side == "host" and not Core.Down.native_deny then
        local Owners, Known = {}, {}
        for _, Owner in ipairs(DENY_ORDER) do
            Known[Owner] = true
            if Native.DenyLists[Owner] then Owners[#Owners + 1] = Owner end
        end
        local Rest = {}
        for Owner in pairs(Native.DenyLists) do
            if not Known[Owner] then Rest[#Rest + 1] = tostring(Owner) end
        end
        table.sort(Rest)
        for _, Owner in ipairs(Rest) do Owners[#Owners + 1] = Owner end
        for _, Owner in ipairs(Owners) do
            for _, E in ipairs(Native.DenyLists[Owner] or {}) do
                local Line = A.Safe(function() return DenyLine(E, FuncCache) end, nil)
                if Line and not Seen[Line] then
                    Seen[Line] = true
                    if #Lines < DENY_MAX then Lines[#Lines + 1] = Line else Cut[Owner] = (Cut[Owner] or 0) + 1 end
                end
            end
            if Cut[Owner] then CutText[#CutText + 1] = string.format("%s %d", Owner, Cut[Owner]) end
        end
    end
    local CutLine = table.concat(CutText, ", ")
    if CutLine ~= (Native.DenyCut or "") and (CutLine == "" or os.clock() >= (Native.DenyCutAt or 0)) then
        Native.DenyCut = CutLine
        if CutLine ~= "" then
            Native.DenyCutAt = os.clock() + 60   -- hoechstens 1x pro Minute melden
            Log("Sperrliste voll (%d Zeilen): abgeschnitten %s", DENY_MAX, CutLine)
        end
    end
    table.sort(Lines)
    local Text = table.concat(Lines, "\n") .. (#Lines > 0 and "\n" or "")
    if Text ~= Native.DenyText then
        if not Core.WriteAtomic(Native.Path("deny", ".txt"), Text) then return false end
        if #Lines ~= (Native.DenyCount or 0) then Log("Sperrliste: %d Eintraege", #Lines) end
        Native.DenyText = Text
    end
    Native.DenyCount = #Lines
    return #Lines
end

function Native.SetDeny(Entries, Owner)
    local Key = Owner or "main"
    Native.DenyLists[Key] = (type(Entries) == "table" and next(Entries)) and Entries or nil
    Native.DenyGens[Key] = Native.DenyLists[Key] and (DenyWorld()) or nil
    return Native.FlushDeny()
end

-- Sperrliste wirkt in der DLL (Beobachter installiert, Host, nicht nach Fehlern abgeschaltet). Module pruefen damit,
-- ob sie zusaetzlich ihren Lua-Weg brauchen. 2 s Cache wie Native.Status.
function Native.DenyActive()
    local S = Native.Status()
    return S ~= nil and S.denyon == 1
end

-- Clan-Verbuendete: Native.SetAllies({ [Pawn] = ClanIndex, ... }) -> netcore_allies.txt "<Pawn hex> <Index>".
-- Mit pvp=1 nullt ff ein Spielerziel nur, wenn Ziel und Figur des Verursachers denselben Index > 0 haben.
-- clan_ff=1 (Clan-Eigenbeschuss erlaubt): Datei bleibt leer. Hoechstens 64 Figuren.
function Native.FlushAllies()
    local Lines = {}
    local Gen, Loading = DenyWorld()
    if (Loading or Native.AlliesGen ~= Gen) and next(Native.AlliesMap or {}) then
        Native.AlliesMap, Native.AlliesGen = {}, nil
        Log("Weltwechsel: Verbuendete geleert")
    end
    if A and not Core.Flag("clan_ff", false) then
        for Pawn, Index in pairs(Native.AlliesMap or {}) do
            local N = math.floor(tonumber(Index) or 0)
            if N > 0 and #Lines < 64 then
                local Addr = A.Safe(function() return DenyAddress(Pawn) end, nil)
                if Addr then Lines[#Lines + 1] = string.format("%s %d", Addr, N) end
            end
        end
    end
    table.sort(Lines)
    local Text = table.concat(Lines, "\n") .. (#Lines > 0 and "\n" or "")
    if Text == Native.AlliesText then return #Lines end
    if not Core.WriteAtomic(Native.Path("allies", ".txt"), Text) then return false end
    Native.AlliesText = Text
    return #Lines
end

function Native.SetAllies(Map)
    Native.AlliesMap = type(Map) == "table" and Map or {}
    Native.AlliesGen = (DenyWorld())
    return Native.FlushAllies()
end

-- ---------------------------------------------------------------- N6: naechster Gast, Optionen

-- N6-Liste (Runde 9, AI-4/AI-5/WORLD-25): netcore_n6.txt ersetzt die eingebaute Liste der DLL.
--   safe (Standard): nur Spawn-/Wellen-Kontexte und der POI-Manager (Spawner pruefen "nicht neben dem Spieler", Wellen
--     zielen auf den naechsten Gast) plus Funktions-Eintraege "Klasse.Funktion" (Skalierung nach Stufe/Tagen,
--     Umgebungspruefung der Prefab-Spawner). Zombies/Tiere/Banditen/Ernte bewusst NICHT: deren Tod-Pfade (Feuer,
--     Death(null), Tier-Tod nach Delay) gaeben Kill/XP sonst nativ dem naechsten Gast statt ls_combat H.Credit.
--   full: die alte eingebaute Liste (NetTestCore.cpp DefaultN6List bis Runde 8).
-- Funktions-Eintraege nur mit neuer DLL (Status n6fn=1): eine alte laese "Klasse.Funktion" als Klassennamen, faende
-- ihn nie und durchsuchte deshalb alle 30 s alle Objekte. Sperren ("-") gelten in beiden Listen.
local N6 = {
    SAFE = { "BP_AISpawner_Master_C", "BP_AISpawningVolume_Prefab_C", "BP_AISpawningVolume_RandomChanceToSpawn_C",
             "BP_Quest_Spawner_AI_C", "Buildable_HordeBeacon_C", "BP_Infestation_C", "BP_POIManager_C" },
    FUNCS = { "GameFunctionLibrary_C.ScalingDamageMultiplier", "GameFunctionLibrary_C.ScalingHealthMultiplier",
              "BP_PrefabSpawner_C.CheckSurroundingArea" },
    FULL = { "BP_MasterZombie_C", "BP_ZombieBoss_C", "BP_MasterBandit_C", "BP_MasterCoyoteSoldier_C", "BP_MasterScavenger_C",
             "BP_MasterTrader_C", "BP_TraderMaster_C", "BP_AnimalBear_C", "BP_AnimalDeer_C", "BP_AnimalRabbit_C",
             "BP_AnimalWolf_C", "BP_AnimalDog_C", "BP_AISpawner_Master_C", "BP_Quest_Spawner_AI_C",
             "BP_AISpawningVolume_Prefab_C", "BP_AISpawningVolume_RandomChanceToSpawn_C", "BP_PrefabSpawner_C",
             "BP_GuaranteedSpawner_C", "Master_AirdropContainer_C", "BP_Infestation_C", "BP_EventManager_C",
             "Buildable_HordeBeacon_C", "BP_POIManager_C", "BP_Siren_C", "BP_BountyQuestManager_C",
             "BP_ExplosiveBarrelMaster_C", "BP_Landmine_C", "Buildable_LandMine_C", "BP_RadiationArea_Sphere_C",
             "BP_HarvestableObject_Tree_C", "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_ScrapMetal_C" },
    BLOCK = { "UserWidget", "HUD", "PlayerCameraManager", "AnimInstance", "GameInstance", "BP_Audio_Manager_C",
              "BP_Audio_Area_C", "UDS_PlayerOcclusion_C", "Ultra_Dynamic_Sky_C", "Ultra_Dynamic_Weather_C" },
}

-- coop.txt ai_n6_list=safe|full (Text-Schalter: SETTINGS oder Core.Extra, Core.Flag kennt nur Zahlen/Wahrheitswerte)
function Native.N6ListName()
    local Value = A.Settings.ai_n6_list
    if Value == nil then Value = Core.Extra.ai_n6_list end
    return (Value ~= nil and tostring(Value):lower() == "full") and "full" or "safe"
end

-- netcore_n6.txt atomar schreiben (nur bei geaendertem Inhalt). Native.N6Ok = die DLL findet unsere Liste vor; erst
-- dann darf NearestMode "1" melden. Rueckgabe true = Liste liegt.
function Native.WriteN6()
    local Name = Native.N6ListName()
    local S = Native.Status()
    local WithFn = Name == "safe" and S ~= nil and tonumber(S.n6fn) == 1
    local Lines = { string.format("# Last Signal N6-Liste (ls_native, ai_n6_list=%s%s)", Name, WithFn and ", mit Funktionen" or "") }
    for _, Cls in ipairs(Name == "full" and N6.FULL or N6.SAFE) do Lines[#Lines + 1] = "+ " .. Cls end
    if WithFn then
        for _, Fn in ipairs(N6.FUNCS) do Lines[#Lines + 1] = "+ " .. Fn end
    end
    for _, Cls in ipairs(N6.BLOCK) do Lines[#Lines + 1] = "- " .. Cls end
    local Text = table.concat(Lines, "\n") .. "\n"
    if Text == Native.N6Text and Native.N6Ok then return true end
    if not Core.WriteAtomic(Native.Path("n6", ".txt"), Text) then
        if Native.N6Ok ~= false then Log("N6-Liste nicht schreibbar - ai_nearest bleibt diag") end
        Native.N6Ok = false
        return false
    end
    Native.N6Text, Native.N6Ok = Text, true
    Log("N6-Liste: %s (%d Klassen%s, %d Sperren)", Name, Name == "full" and #N6.FULL or #N6.SAFE,
        WithFn and string.format(", %d Funktionen", #N6.FUNCS) or (Name == "safe" and ", Funktionen erst mit neuer DLL" or ""),
        #N6.BLOCK)
    return true
end

-- coop.txt ai_nearest=diag|0|1. Ohne Eintrag (Runde 9, Entscheidung 1): "1" auf dem dedizierten Server (A.Coop.Server),
-- sonst "diag". "1" nur, wenn unsere N6-Liste liegt (sonst nimmt die DLL ihre eingebaute - bei einer alten DLL die volle
-- mit Zombies/Tieren -> Kill-Credit an den naechsten Gast); bis dahin "diag". profile=legacy oder Down -> 0.
-- Rueckweg: ai_nearest=diag oder 0 in coop.txt.
function Native.NearestMode()
    if A.Settings.profile == "legacy" or Core.Down.ai_nearest then return "0" end
    local Value = A.Settings.ai_nearest
    if Value == nil then Value = Core.Extra.ai_nearest end
    if Value == nil then Value = (A.Coop and A.Coop.Server) and "1" or "diag" end
    Value = tostring(Value):lower()
    if Value == "diag" then return "diag" end
    if Value == "1" or Value == "true" or Value == "on" then return Native.N6Ok and "1" or "diag" end
    return "0"
end

function Native.WriteOpts()
    -- N6-Liste immer vor dem Modus (Entscheidung 1): die DLL liest beim Umschalten auf 1 schon die richtige Liste
    if Core.Down.native_n6 then
        Native.N6Ok = false
    else
        local okN6, errN6 = pcall(Native.WriteN6)
        if not okN6 then
            Native.N6Ok = false
            Core.Fail("native_n6", errN6)
        end
    end
    if not Native.OffRoot then
        Native.OffRoot = A.Safe(function() return PropertyOffset("/Script/Engine.Actor", "RootComponent") end, nil)
    end
    if not Native.OffRel then
        Native.OffRel = A.Safe(function() return PropertyOffset("/Script/Engine.SceneComponent", "RelativeLocation") end, nil)
    end
    -- Lokaler PC nur als Vergleichswert fuer R/L bzw. owner=local (die DLL prueft ihn beim Lesen)
    local PC = A.Safe(A.LocalPC, nil)
    local PCAddr = PC and A.IsAlive(PC) and A.Safe(function() return PC:GetAddress() end, nil) or 0
    -- Runde 7: pvp (ff nur zwischen Clan-Verbuendeten), netmode (Sperrliste nur auf dem Host)
    local Side = A.Net and A.Net.Side
    Native.OptsSide = Side
    local Mode = Side == "host" and "host" or Side == "client" and "client" or "solo"
    -- INV-15: drop_outer=1 -> JigMP_OnRequestDropItem loest Spieler 0 aus den aeusseren Rahmen (dem anfragenden Spieler)
    -- statt vom Besitzer der Kiste (Todes-Kiste/Kofferraum); alte DLL ignoriert die Zeile
    local Text = string.format("ai_nearest=%s\nobserver=%d\noff_root_component=%X\noff_rel_location=%X\nlocal_pc=%X\npvp=%d\nnetmode=%s\ndrop_outer=%d\n",
        Native.NearestMode(), Core.Flag("native_observer", true) and 1 or 0, Native.OffRoot or 0, Native.OffRel or 0, PCAddr,
        Core.Flag("pvp", true) and 1 or 0, Mode, Core.Flag("drop_outer", true) and 1 or 0)
    if Text ~= Native.OptsText and Core.WriteAtomic(Native.Path("opts", ".txt"), Text) then Native.OptsText = Text end
end

-- Host: "<PC> <Pawn> <Character> <CameraManager> <X> <Y> <Z>" je echtem Gast (nie der Geist/lokale PC).
-- Sonst (Gast, Einzelspieler, N6 aus) eine leere Datei. Geschrieben wird nur bei Aenderung.
function Native.WritePlayers()
    local Net, Lines = A.Net, {}
    if Net and Net.Side == "host" and Native.NearestMode() ~= "0" then
        local CharClass = A.Safe(function() return StaticFindObject("/Script/Engine.Character") end, nil)
        local Local = A.Safe(A.LocalPC, nil)
        local LocalAddr = Local and A.IsAlive(Local) and A.Safe(function() return Local:GetAddress() end, nil)
        for _, PC in pairs(A.Safe(function() return Net.ScanPCs(true) end, {}) or {}) do
            A.Safe(function()
                if not A.IsAlive(PC) or PC:GetAddress() == LocalAddr then return end
                local Pawn = PC.Pawn
                if not A.IsAlive(Pawn) then return end
                local Loc = Pawn:K2_GetActorLocation()
                local Cam = PC.PlayerCameraManager
                local IsChar = CharClass and A.IsAlive(CharClass) and Pawn:IsA(CharClass)
                Lines[#Lines + 1] = string.format("%X %X %X %X %.1f %.1f %.1f", PC:GetAddress(), Pawn:GetAddress(),
                    IsChar and Pawn:GetAddress() or 0, A.IsAlive(Cam) and Cam:GetAddress() or 0, Loc.X, Loc.Y, Loc.Z)
            end)
        end
    end
    table.sort(Lines)
    local Text = table.concat(Lines, "\n") .. (#Lines > 0 and "\n" or "")
    if Text == Native.PlayersText then return true end
    if not Core.WriteAtomic(Native.Path("players", ".txt"), Text) then return false end
    Native.PlayersText = Text
    return true
end

function Native.Init(Api)
    A = Api
    -- Dateien einer frueheren Sitzung: Adressen waeren falsch (die DLL ignoriert sie zusaetzlich nach Datum)
    for _, Name in ipairs({ "watch", "players", "events", "status", "watchinfo", "deny", "allies" }) do
        os.remove(Native.Path(Name, ".txt"))
    end

    Core.Every("native_opts", 5.0, function() Native.WriteOpts() end)

    -- Runde 7: Sperrliste/Verbuendete jede Sekunde neu aufloesen (tote Objekte fallen heraus, Rollenwechsel
    -- Host/Gast leert die Sperrliste); netmode sofort nachziehen, wenn sich Net.Side aendert
    Core.Every("native_deny", 1.0, function()
        if (A.Net and A.Net.Side) ~= Native.OptsSide then Native.WriteOpts() end
        if next(Native.DenyLists) or (Native.DenyCount or 0) > 0 then
            local ok, err = pcall(Native.FlushDeny)
            if not ok and Core.Fail("native_deny", err) then pcall(Native.FlushDeny) end
        end
        if next(Native.AlliesMap or {}) or (Native.AlliesText or "") ~= "" then Native.FlushAllies() end
    end)

    -- Watch-Liste: N8 auf dem Host, neu aufloesen bei Weltwechsel, fehlenden Funktionen und alle 10 s
    Core.Every("native_watch", 1.0, function(Now)
        local Side = A.Net and A.Net.Side
        local WantN8 = Side == "host" and Core.Flag("native_n8", true)
        if WantN8 ~= Native.N8On then
            Native.N8On = WantN8
            Native.Watches.n8 = WantN8 and Native.N8 or nil
            Native.WatchDirty = true
        end
        local Gen = A.WorldGen and A.WorldGen.N
        if Native.WatchDirty or Gen ~= Native.WatchGen or Now - (Native.WatchAt or 0) >= 10 then
            if Gen ~= Native.WatchGen then
                Native.SdCache = nil
                Native.WriteOpts()   -- neuer lokaler PC nach Weltwechsel
            end
            Native.WatchGen, Native.WatchAt = Gen, Now
            Native.FlushWatch()
        end
    end)

    -- N6: Gaeste jede Sekunde, beim Trennen sofort
    Core.Every("native_players", 1.0, function()
        local Net = A.Net
        if Net and Net.OnEvent and not Native.GoneHooked then
            Native.GoneHooked = true
            Net.OnEvent("gone", function()
                local ok, err = pcall(Native.WritePlayers)
                if not ok then Core.Fail("native_players", err) end
            end)
        end
        Native.WritePlayers()
    end)

    if A.TestCommands then
        A.TestCommands.native_ev = function()
            local S = Native.Status() or {}
            local Tags = {}
            for Tag in pairs(Native.Named) do Tags[#Tags + 1] = Tag end
            table.sort(Tags)
            A.TestLog("native: verfuegbar=%s eintritt=%s aufruf=%s watch=%s fehlend=%s seq=%s verworfen(DLL)=%s verloren=%s ai_nearest=%s benannt=%s",
                tostring(Native.Available()), tostring(S.entry), tostring(S.call),
                tostring(select(2, (Native.WatchText or ""):gsub("\n", ""))), tostring(Native.WatchMissing),
                tostring(Native.EvLast), tostring(Native.EvDropped), tostring(Native.EvLost), Native.NearestMode(),
                table.concat(Tags, ","))
            A.TestLog("native: sperrliste=%s (dll %s, an=%s, verworfen=%s, fehler=%s) verbuendete=%s (dll %s) pvp=%s netmode=%s",
                tostring(Native.DenyCount or 0), tostring(S.deny), tostring(S.denyon), tostring(S.denied),
                tostring(S.denyfaults), tostring(select(2, (Native.AlliesText or ""):gsub("\n", ""))), tostring(S.allies),
                tostring(S.pvp), tostring(Native.OptsSide))
            -- Runde 9: N6-Liste und neue DLL-Faehigkeiten (Status n6fn/feat_remote/drop_outer/maxargs)
            A.TestLog("native: n6=%s (liegt=%s) dll n6fn=%s feat_remote=%s drop_outer=%s maxargs=%s, remote weggelassen=%s, sperrliste abgeschnitten=%s",
                Native.N6ListName(), tostring(Native.N6Ok), tostring(S.n6fn), tostring(S.feat_remote), tostring(S.drop_outer),
                tostring(S.maxargs), tostring(Native.RemoteSkip or 0), (Native.DenyCut or "") ~= "" and Native.DenyCut or "-")
            -- native_evlost: Kopfzeile lost= der DLL (je Tag, Summe der DLL-Sitzung), genauer als "verloren" oben
            local Lost, Parts = {}, {}
            for Tag, N in pairs(Native.EvLostTag or {}) do Lost[#Lost + 1] = { Tag, N } end
            table.sort(Lost, function(X, Y) if X[2] ~= Y[2] then return X[2] > Y[2] end return X[1] < Y[1] end)
            for _, E in ipairs(Lost) do Parts[#Parts + 1] = E[1] .. ":" .. tostring(E[2]) end
            A.TestLog("native: aus dem Fenster gefallen je Tag (dll lost=)=%s%s", #Parts > 0 and table.concat(Parts, ",") or "-",
                Core.Down.native_evlost and " (native_evlost aus)" or "")
        end
    end
end

return Native
