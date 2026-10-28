-- Last Signal, Runde 5: Protokoll v3 (Seitenkanal neben der Replikation des Spiels). Vertrag: _NetTest\analysis\API.md
--   Rahmen   NETTEST|v3|<kind>|<seq>|<i>|<n>|<flags>|<data>   (Transport wie bisher: ClientMessage / ServerExecRPC)
--   flags    e<Epoche> immer; r<rid> Anfrage, a<rid> Antwort, s Keyed-State (Eintraege "key=value;..."), z reserviert
--   Handshake  Gast: h4 "<guestId>|<cap,cap>|<nonce>" alle 2 s bis zur Antwort; Host: h4a "<epoche>|<fps>|<schnittmenge>"
--   Empfang  Hooks rufen nur Net.Push/PushLegacy (Lua-Tabellen); Abarbeitung im 100-ms-Task "net_in"
--   Senden   Warteschlangen P0..P3 je Gegenstelle, Token-Bucket (12 KB/s, Burst 24 KB, 30 Rahmen/s), Task "net_out"
local Net = {}
local Core = require("ls_core")
local A           -- API aus main.lua (siehe Init)

local FRAG = 1000                       -- Zeichen Nutzdaten je Rahmen
local LIM = { N = 64, TOTAL = 65536, OPEN = 8, EXPIRE = 10, FRAME = 1024, KIND = 24 }
local IN_FRAMES, IN_TIME = 30, 0.004    -- Empfang je Tick: hoechstens 30 Rahmen oder ~4 ms
local C2S_RATE = 40                     -- Host: Rahmen je Sekunde und Gast, darueber verwerfen
local PUSH_RATE, INBOX_MAX = 200, 2000  -- schon im Hook: harte Grenzen gegen Fluten
local LEGACY_RATE = 100                 -- PushLegacy: eigene Grenze je Absender und Sekunde
local PER_MSG, OPEN_OUT = 8, 4          -- Sender: Fragmente einer Nachricht je Tick, gleichzeitig offene Nachrichten
local QUEUE_MAX = 400                   -- Nachrichten je Prioritaet und Gegenstelle
local H4_EVERY, REFRESH_EVERY, WARN_EVERY = 2, 30, 5
local DONE_KEEP = 512                   -- gemerkte fertige seq je Gegenstelle
local MIRROR_KEYS, MIRROR_BYTES = 1024, 512 * 1024   -- Host: empfangener Keyed-State je Gast und Art bzw. je Gast
local STATE_ENTRIES = 300               -- Host: Eintraege je Keyed-State-Nachricht eines Gasts
local LOW_FORCE_MAX = 64                -- 30-s-Auffrischung erzwingt nur Arten bis zu so vielen Schluesseln, sonst nur Abweichungen
local KA_EVERY, LIVE_TIMEOUT = 10, 45   -- Lebenszeichen "nka" nach so viel s ohne Senden; ohne Empfang: Caps weg, neu aushandeln
local LEGACY_AFTER = 10                 -- Host: Gast so lange bereit ohne Handshake = legacy (Net.Has ohne Gast)

Net.Inbox = {}        -- { P = Rahmen ohne "NETTEST|v3|", K = Absender, T = os.clock() } bzw. { L = true, K, Kind, Data }
Net.Guests = {}       -- Host: [PC:GetFullName()] = Gast (siehe NewPeer)
Net.Host = nil        -- Gast: Gegenstelle "host"
Net.Side = nil        -- "host" | "client" | nil (aus NetMode, jeden Tick)
Net.Active = false    -- Schalter net_v3 (Core.Flag, inkl. Down/legacy)
Net.LocalCaps = {}    -- [cap] = true: diese Seite kann es (Net.Cap)
Net.Handlers = {}     -- [kind] = { fn, ... } (Net.On)
Net.Listeners = {}    -- [event] = { fn, ... } (Net.OnEvent)
Net.StateTab = {}     -- [kind] = { Prio, All = {[key]=value}, Per = {[peerKey] = {[key]=value}} }
Net.Mirror = {}       -- [peerKey][kind][key] = value (empfangener Keyed-State)
Net.PushRate = {}     -- [Absender] = { At, N } (Hook-Grenze)
Net.LegacyRate = {}   -- [Absender] = { At, N } (Grenze fuer PushLegacy)
Net.Stat = { inF = 0, inB = 0, inMsg = 0, outF = 0, outB = 0, outMsg = 0, pushed = 0, legacy = 0, drop = {} }
Net.EpochBase, Net.EpochSeq = 0, 0

local function Log(fmt, ...) A.Log("[Net] " .. fmt, ...) end

local function Drop(Why)
    local D = Net.Stat.drop
    D[Why] = (D[Why] or 0) + 1
end

-- Werte innerhalb von data maskieren (wie das alte Protokoll): | ; = %
function Net.Enc(Value)
    return (tostring(Value):gsub("[%%|;=]", function(C) return string.format("%%%02X", C:byte()) end))
end

function Net.Dec(Value)
    return (tostring(Value):gsub("%%(%x%x)", function(H) return string.char(tonumber(H, 16)) end))
end

local function NewPeer(Key)
    local Now = os.clock()
    return { Key = Key, Epoch = nil, Nonce = nil, SeqOut = 0, Rid = 0, Pend = {},
             Q = { [0] = {}, {}, {}, {} }, Bytes = Net.Burst, Frames = Net.Fps, TokAt = Now,
             Sent = {}, Dirty = {}, Force = {}, Caps = {}, PeerCaps = {}, RefreshAt = Now + REFRESH_EVERY,
             Rx = { Hi = 0, Floor = 0, Done = {}, DoneN = 0, Open = {}, OpenN = 0 }, Rate = { At = 0, N = 0 },
             WarnAt = 0, WarnN = 0, Seen = Now, Missing = 0, Ready = false,
             MirN = {}, MirB = 0, RxAt = Now, TxAt = Now }
end

-- Sicherheitswarnung: zaehlen, hoechstens alle WARN_EVERY s je Absender ins Log
function Net.SecWarn(Peer, Key, Why)
    Drop("sec_" .. Why)
    local Now, Box = os.clock(), Peer or Net.PushRate[Key]
    if not Box then Log("secwarn %s: %s", tostring(Key), Why) return end
    Box.WarnN = (Box.WarnN or 0) + 1
    if Now < (Box.WarnAt or 0) then return end
    Box.WarnAt = Now + WARN_EVERY
    Log("secwarn %s: %s (%d verworfen)", tostring(Key), Why, Box.WarnN)
    Box.WarnN = 0
end

local function Emit(Event, Peer)
    for _, Fn in ipairs(Net.Listeners[Event] or {}) do
        local ok, err = pcall(Fn, Peer)
        if not ok then Log("Ereignis %s: Fehler %s", Event, tostring(err)) end
    end
end

-- ---------------------------------------------------------------- Gegenstellen / Gaeste

-- Host: Controller der Gaeste (Key -> PC), hoechstens 50 ms alt, nie ueber Ticks halten (nur ueber Net.PC holen)
function Net.ScanPCs(Force)
    local Now = os.clock()
    if not Force and Net.PCs and Now - Net.PCAt < 0.05 then return Net.PCs end
    local Map = {}
    local World = A.Safe(A.CurrentWorld)
    if World and A.IsAlive(World) then
        for _, PS in ipairs(A.Safe(function() return A.PlayerStates(World) end, {})) do
            local PC = A.Safe(function() return PS:GetOwner() end)
            if A.IsAlive(PC) and A.Safe(function() return not PC:IsLocalController() end, false) then
                local Key = A.Safe(function() return PC:GetFullName() end)
                if Key then Map[Key] = PC end
            end
        end
    end
    Net.PCs, Net.PCAt = Map, Now
    return Map
end

-- Frischer PlayerController eines Gasts (Gast-Tabelle oder Key), nil wenn weg
function Net.PC(G)
    local Key = type(G) == "table" and G.Key or G
    local PC = Key and Net.ScanPCs()[Key]
    if PC and A.IsAlive(PC) then return PC end
    return nil
end

function Net.ByPC(PC)
    local Key = A.IsAlive(PC) and A.Safe(function() return PC:GetFullName() end)
    return Key and Net.Guests[Key] or nil
end

function Net.GuestByPawnName(Name)
    for _, G in pairs(Net.Guests) do
        if G.PawnName == Name then return G end
    end
    return nil
end

-- Maschinenuebergreifender Schluessel fuer eine Figur. Zur Laufzeit gespawnte, replizierte Actors heissen auf Host
-- und Gast VERSCHIEDEN (Test 22.10.: Host ..._2147475810, Gast ..._2147388915). Gleich ist PlayerState.PlayerId
-- -> "p<Id>". Map-Actors (aus dem Level geladen) behalten ihren FName -> "n<FName>". nil, wenn nicht bestimmbar.
function Net.PawnKey(Pawn)
    if not (A and A.IsAlive(Pawn)) then return nil end
    local PS = A.Safe(function() return Pawn.PlayerState end, nil)
    if A.IsAlive(PS) then
        local Id = A.Safe(function() return PS.PlayerId end, nil)
        if type(Id) == "number" then return "p" .. math.floor(Id) end
    end
    local Name = A.Safe(function() return Pawn:GetFName():ToString() end, nil)
    return Name and ("n" .. Name) or nil
end

-- Figur zu einem PawnKey auf dieser Maschine (frisch gesucht; Spielerfiguren ueber PlayerId, sonst ueber FName)
function Net.PawnByKey(Key)
    if type(Key) ~= "string" then return nil end
    local Id = tonumber(Key:match("^p(%-?%d+)$"))
    local Name = Key:match("^n(.+)$")
    local List = Id and (FindAllOf("Pawn") or {}) or ((A and A.Characters and A.Characters()) or FindAllOf("Character") or {})
    for _, P in ipairs(List) do
        if A.IsAlive(P) then
            if Id then
                local PS = A.Safe(function() return P.PlayerState end, nil)
                if A.IsAlive(PS) and A.Safe(function() return PS.PlayerId end, nil) == Id then return P end
            elseif A.Safe(function() return P:GetFName():ToString() end, nil) == Name then
                return P
            end
        end
    end
    return nil
end

-- Eigene Figur des Gasts (fuer Nachrichten, die der Host gezielt an diesen Gast schickt: "self" statt Name)
function Net.OwnPawnKey()
    local Pawn = A and A.Safe(A.OwnPawn, nil)
    return Pawn and Net.PawnKey(Pawn) or nil
end

function Net.ForEachGuest(Fn)
    local Keys = {}
    for Key in pairs(Net.Guests) do Keys[#Keys + 1] = Key end
    table.sort(Keys)
    for _, Key in ipairs(Keys) do
        local G = Net.Guests[Key]
        if G then
            local ok, err = pcall(Fn, G, Key)
            if not ok then Log("ForEachGuest: %s", tostring(err)) end
        end
    end
end

-- Ziel aufloesen: Gast-Tabelle, Gast-Key, PC (userdata), "host"/nil beim Gast
local function Resolve(Target)
    if Net.Side == "client" then return Net.Host end
    if type(Target) == "table" then return Net.Guests[Target.Key] end
    if type(Target) == "string" then return Net.Guests[Target] end
    if type(Target) == "userdata" then return Net.ByPC(Target) end
    return nil
end

local function Targets(Target)
    if Net.Side == "client" then return { Net.Host } end
    if Net.Side ~= "host" then return {} end
    if Target == nil or Target == "all" then
        local List = {}
        for _, G in pairs(Net.Guests) do List[#List + 1] = G end
        return List
    end
    return { Resolve(Target) }
end

local function FailPending(Peer, Why)
    local Pend = Peer.Pend
    Peer.Pend = {}
    for _, R in pairs(Pend) do pcall(R.Cb, nil, Peer, Why) end
end

-- Neue Epoche (Host) bzw. Verbindung neu: Folgenummern, Warteschlangen, Empfang, Cache zuruecksetzen
local function ResetLink(Peer)
    Peer.SeqOut, Peer.Q = 0, { [0] = {}, {}, {}, {} }
    Peer.Rx = { Hi = 0, Floor = 0, Done = {}, DoneN = 0, Open = {}, OpenN = 0 }
    Peer.Sent, Peer.Dirty, Peer.Force = {}, {}, {}
    Net.Mirror[Peer.Key] = nil
    Peer.MirN, Peer.MirB, Peer.RxAt = {}, 0, os.clock()
    FailPending(Peer, "reset")
end

-- ---------------------------------------------------------------- Senden

-- In Fragmente <= FRAG schneiden, nie mitten in einem UTF-8-Zeichen
local function Split(Data)
    local Parts, Pos, Len = {}, 1, #Data
    if Len == 0 then return { "" } end
    while Pos <= Len do
        local Stop = math.min(Pos + FRAG - 1, Len)
        local Back = 0
        while Stop < Len and Back < 3 and Stop > Pos do
            local B = Data:byte(Stop + 1)
            if B >= 0x80 and B < 0xC0 then Stop, Back = Stop - 1, Back + 1 else break end
        end
        Parts[#Parts + 1] = Data:sub(Pos, Stop)
        Pos = Stop + 1
    end
    return Parts
end

local function Enqueue(Peer, Kind, Data, Prio, Flags)
    local Parts = Split(Data)
    if #Parts > LIM.N then Log("%s: %d Zeichen zu gross, nicht gesendet", Kind, #Data) Drop("too_big") return false, "too_big" end
    local Q = Peer.Q[Prio]
    if #Q >= QUEUE_MAX then Net.SecWarn(Peer, Peer.Key, "queue_full_p" .. Prio) return false, "queue_full" end
    Q[#Q + 1] = { Kind = Kind, Parts = Parts, N = #Parts, I = 1, Flags = Flags, At = os.clock() }
    Net.Stat.outMsg = Net.Stat.outMsg + 1
    return true
end

-- Einen Rahmen verschicken (Spiel-Thread; Host: frischer PC). Gibt Laenge oder nil zurueck.
local function Wire(Peer, Kind, Seq, I, N, Flags, Chunk)
    local Text = "v3|" .. Kind .. "|" .. Seq .. "|" .. I .. "|" .. N .. "|" .. Flags .. "|" .. Chunk
    local ok, err
    if Net.Side == "host" then
        local PC = Net.PC(Peer)
        if not PC then Drop("no_pc") return nil end
        ok, err = pcall(A.Coop.SendToClient, PC, Text)
    elseif Net.Side == "client" then
        ok, err = pcall(A.Coop.SendToHost, Text)
    end
    if not ok then
        Drop("send_err")
        if Core.Fail("net_v3", err) then Net.Active = false end
        return nil
    end
    local S = Net.Stat
    S.outF, S.outB = S.outF + 1, S.outB + #Text + 8
    Peer.TxAt = os.clock()
    return #Text + 8
end

local function Refill(Peer, Now)
    local Dt = math.max(0, Now - Peer.TokAt)
    Peer.TokAt = Now
    Peer.Bytes = math.min(Net.Burst, Peer.Bytes + Dt * Net.Rate)
    Peer.Frames = math.min(Net.Fps, Peer.Frames + Dt * Net.Fps)
end

-- Keyed-State: schmutzige Schluessel in Nachrichten "key=value;..." (Flag s) packen, neuester Wert gewinnt.
-- Sent gilt erst, wenn die Nachricht eingereiht ist; Warteschlange voll = Schluessel (und Force) bleiben schmutzig.
local function BuildState(Peer)
    if next(Peer.Dirty) == nil then return end
    local Dirty = Peer.Dirty
    Peer.Dirty = {}
    for Kind, Keys in pairs(Dirty) do
        local S = Net.StateTab[Kind]
        local Sent = Peer.Sent[Kind] or {}
        Peer.Sent[Kind] = Sent
        local Force, Per = Peer.Force[Kind], S and S.Per[Peer.Key]
        local Prio = S and S.Prio or 2
        if Force == "low" then Prio = math.max(Prio, 2) end
        Peer.Force[Kind] = nil
        local Buf, Len, BK, BV, BN = {}, 0, {}, {}, 0
        local Full = #Peer.Q[Prio] >= QUEUE_MAX
        local function Flush()
            local ok, Why = Enqueue(Peer, Kind, table.concat(Buf, ";"), Prio, "s")
            if not ok and Why ~= "too_big" then return false end
            for J = 1, BN do Sent[BK[J]] = BV[J] Keys[BK[J]] = nil end
            Buf, Len, BK, BV, BN = {}, 0, {}, {}, 0
            return true
        end
        if not Full then
            for Key in pairs(Keys) do
                local V = nil
                if S then
                    if Per and Per[Key] ~= nil then V = Per[Key] else V = S.All[Key] end
                end
                if V ~= Sent[Key] or (Force and V ~= nil) then
                    local Entry = Net.Enc(Key) .. (V ~= nil and ("=" .. Net.Enc(V)) or "")
                    if BN > 0 and Len + #Entry + 1 > FRAG and not Flush() then Full = true break end
                    BN = BN + 1
                    Buf[BN], BK[BN], BV[BN], Len = Entry, Key, V, Len + #Entry + 1
                end
            end
            if not Full and BN > 0 and not Flush() then Full = true end
        end
        if Full then
            local D = Peer.Dirty[Kind] or {}
            Peer.Dirty[Kind] = D
            for Key in pairs(Keys) do D[Key] = true end
            if Force and Peer.Force[Kind] == nil then Peer.Force[Kind] = Force end
        end
    end
end

-- Warteschlangen einer Gegenstelle abarbeiten. P0 darf den Bucket bis -Burst / -Fps ueberziehen (sofort),
-- P1..P3 warten auf Guthaben. Je Nachricht hoechstens PER_MSG Fragmente pro Tick, hoechstens OPEN_OUT offene.
local function Pump(Peer, Now)
    if not Peer.Epoch then return end
    Refill(Peer, Now)
    BuildState(Peer)
    local Open = 0
    for Prio = 0, 3 do
        for _, M in ipairs(Peer.Q[Prio]) do
            if M.Seq and M.N > 1 then Open = Open + 1 end
        end
    end
    for Prio = 0, 3 do
        local Q, Idx = Peer.Q[Prio], 1
        while Q[Idx] do
            local M, Count = Q[Idx], 0
            local Starts = not M.Seq and M.N > 1
            if Starts and Open >= OPEN_OUT then
                Idx = Idx + 1
            else
                while M.I <= M.N and Count < PER_MSG do
                    local Cost = #M.Parts[M.I] + 48
                    local Floor = Prio == 0 and -Net.Burst or Cost
                    if Peer.Frames < (Prio == 0 and -Net.Fps + 1 or 1) or Peer.Bytes < Floor then return end
                    if not M.Seq then
                        Peer.SeqOut = Peer.SeqOut + 1
                        M.Seq = Peer.SeqOut
                        if Starts then Open = Open + 1 end
                    end
                    local Sent = Wire(Peer, M.Kind, M.Seq, M.I, M.N, "e" .. Peer.Epoch .. M.Flags, M.Parts[M.I])
                    if not Sent then return end
                    Peer.Bytes, Peer.Frames = Peer.Bytes - Sent, Peer.Frames - 1
                    M.I, Count = M.I + 1, Count + 1
                end
                if M.I > M.N then
                    table.remove(Q, Idx)
                    if M.N > 1 then Open = Open - 1 end
                else
                    Idx = Idx + 1
                end
            end
        end
    end
end

-- Nachricht senden. Gast: immer an den Host (Target egal). Host: Target = Gast-Tabelle, Gast-Key, PC oder "all"/nil.
-- Prio 0..3 (Standard 2). Nur an verbundene Gegenstellen (Handshake fertig). true = mindestens einmal eingereiht.
function Net.Send(Kind, Data, Target, Prio)
    if not Net.Active or type(Kind) ~= "string" or not Kind:match("^[%w_]+$") or #Kind > LIM.KIND then return false end
    Data = Data == nil and "" or tostring(Data)
    Prio = math.max(0, math.min(3, math.floor(tonumber(Prio) or 2)))
    local Any, Now = false, os.clock()
    for _, P in ipairs(Targets(Target)) do
        if P and P.Epoch and Enqueue(P, Kind, Data, Prio, "") then
            Any = true
            if Prio == 0 then Pump(P, Now) end
        end
    end
    return Any
end

-- Anfrage mit Antwort: Cb(data, peer) bzw. Cb(nil, peer, "timeout"|"gone"|"reset"). Gibt rid zurueck oder nil.
-- Host: Target ist genau ein Gast. Prio Standard 1.
function Net.Request(Kind, Data, Cb, Timeout, Target, Prio)
    if not Net.Active or type(Kind) ~= "string" or not Kind:match("^[%w_]+$") then return nil end
    local P = Resolve(Target)
    if not (P and P.Epoch) then return nil end
    P.Rid = P.Rid + 1
    local Rid = P.Rid
    Prio = math.max(0, math.min(3, math.floor(tonumber(Prio) or 1)))
    if not Enqueue(P, Kind, Data == nil and "" or tostring(Data), Prio, "r" .. Rid) then return nil end
    P.Pend[Rid] = { Cb = Cb or function() end, Until = os.clock() + (tonumber(Timeout) or 10), Kind = Kind }
    if Prio == 0 then Pump(P, os.clock()) end
    return Rid
end

-- Antwort auf eine empfangene Anfrage (Msg aus dem Handler). Immer P0.
function Net.Reply(Msg, Data)
    if not (Net.Active and type(Msg) == "table" and Msg.Rid and Msg.Sender) then return false end
    local P = Msg.Sender
    if not P.Epoch or P.Epoch ~= Msg.Epoch then return false end
    if not Enqueue(P, Msg.Kind, Data == nil and "" or tostring(Data), 0, "a" .. Msg.Rid) then return false end
    Pump(P, os.clock())
    return true
end

local function MarkAll(Peer, Kind, How)
    local S = Net.StateTab[Kind]
    local Keys = Peer.Dirty[Kind] or {}
    Peer.Dirty[Kind] = Keys
    local N = 0
    if S then
        for Key in pairs(S.All) do Keys[Key], N = true, N + 1 end
        for Key in pairs(S.Per[Peer.Key] or {}) do Keys[Key], N = true, N + 1 end
    end
    for Key in pairs(Peer.Sent[Kind] or {}) do Keys[Key], N = true, N + 1 end
    -- "low" bei grossen Arten (w_harv, b_st ...): nicht alles neu senden, nur Abweichungen von Sent
    if How == "low" and N > LOW_FORCE_MAX then How = nil end
    if How and Peer.Force[Kind] ~= "full" then Peer.Force[Kind] = How end
end

-- Vollauffrischung des Keyed-States fuer eine Gegenstelle (Handshake, ready: "full"; alle 30 s: "low" = Prio >= 2,
-- grosse Arten dann nur Abweichungen)
function Net.Refresh(Peer, How)
    for Kind in pairs(Net.StateTab) do MarkAll(Peer, Kind, How or "full") end
    Peer.RefreshAt = os.clock() + REFRESH_EVERY
end

-- Keyed-State setzen: nur Aenderungen gehen raus (je Gegenstelle zuletzt gesendeter Wert). Value nil = loeschen
-- (bzw. bei Target = ein Gast: dessen Sonderwert entfernen, dann gilt wieder der Wert fuer alle).
function Net.State(Kind, Key, Value, Prio, Target)
    if type(Kind) ~= "string" or not Kind:match("^[%w_]+$") or Key == nil then return false end
    Key = tostring(Key)
    if Value ~= nil then Value = tostring(Value) end
    local S = Net.StateTab[Kind]
    if not S then S = { Prio = 2, All = {}, Per = {} } Net.StateTab[Kind] = S end
    if Prio then S.Prio = math.max(0, math.min(3, math.floor(tonumber(Prio) or 2))) end
    local Peers
    if Net.Side == "client" or Target == nil or Target == "all" then
        if S.All[Key] == Value then return true end
        S.All[Key] = Value
        Peers = Net.Side == "client" and { Net.Host } or Targets("all")
    else
        local P = Resolve(Target)
        if not P then return false end
        local Per = S.Per[P.Key] or {}
        S.Per[P.Key] = Per
        if Per[Key] == Value then return true end
        Per[Key], Peers = Value, { P }
    end
    for _, P in ipairs(Peers) do
        if P then
            P.Dirty[Kind] = P.Dirty[Kind] or {}
            P.Dirty[Kind][Key] = true
        end
    end
    return true
end

-- Empfangener Keyed-State (Gast: vom Host; Host: von einem Gast)
function Net.Get(Kind, Key, Peer)
    local PK = Peer and (type(Peer) == "table" and Peer.Key or Peer) or "host"
    local M = Net.Mirror[PK]
    return M and M[Kind] and M[Kind][tostring(Key)]
end

-- ---------------------------------------------------------------- Handler / Faehigkeiten

function Net.On(Kind, Fn)
    local List = Net.Handlers[Kind] or {}
    Net.Handlers[Kind] = List
    for _, F in ipairs(List) do if F == Fn then return end end
    List[#List + 1] = Fn
end

function Net.OnEvent(Event, Fn)
    local List = Net.Listeners[Event] or {}
    Net.Listeners[Event] = List
    List[#List + 1] = Fn
end

local function CapList(Caps)
    local List = {}
    for Cap in pairs(Caps) do List[#List + 1] = Cap end
    table.sort(List)
    return table.concat(List, ",")
end

local function ParseCaps(Text)
    local Caps = {}
    for Cap in tostring(Text or ""):gmatch("[%w_]+") do Caps[Cap] = true end
    return Caps
end

local function Intersect(Theirs)
    local Out = {}
    for Cap in pairs(Theirs) do if Net.LocalCaps[Cap] then Out[Cap] = true end end
    return Out
end

local function FpsCap()
    local Srv, Fps = A.Settings.server, 60
    if type(Srv) == "table" and Srv.FpsCap then Fps = tonumber(A.Safe(Srv.FpsCap)) or 60 end
    return math.floor(Fps)
end

local function SendH4a(G)
    Enqueue(G, "h4a", string.format("%d|%d|%s", G.Epoch, FpsCap(), CapList(G.Caps)), 0, "")
    Pump(G, os.clock())
end

-- Eigene Faehigkeit an/aus (Modul-Init: Net.Cap("inv2a", Core.Flag("inv_v2a", true))). Aendert sich etwas nach dem
-- Handshake, handelt der Gast neu aus (h4, gleiche Epoche) bzw. der Host schickt jedem Gast ein neues h4a.
function Net.Cap(Name, On)
    local Was = Net.LocalCaps[Name] == true
    Net.LocalCaps[Name] = (On ~= false and On ~= 0) or nil
    if Was == (Net.LocalCaps[Name] == true) then return end
    if Net.Side == "client" and Net.Host then
        Net.Host.H4At = 0
        Net.Host.ReH4 = true
    elseif Net.Side == "host" then
        for _, G in pairs(Net.Guests) do
            if G.Epoch then G.Caps = Intersect(G.PeerCaps) SendH4a(G) end
        end
    end
end

-- Faehigkeit auf beiden Seiten aktiv? Gast: mit dem Host. Host: mit Gast G, ohne G: mit allen verbundenen Gaesten.
function Net.Has(Cap, G)
    if not Net.Active or not Net.LocalCaps[Cap] then return false end
    if Net.Side == "client" then
        local H = Net.Host
        return H ~= nil and H.Epoch ~= nil and H.Caps[Cap] == true
    end
    if Net.Side ~= "host" then return false end
    if G then
        local P = Resolve(G)
        return P ~= nil and P.Epoch ~= nil and P.Caps[Cap] == true
    end
    local Now = os.clock()
    for _, P in pairs(Net.Guests) do
        if P.Epoch then
            if not P.Caps[Cap] then return false end
        elseif P.Ready and Now - (P.ReadyAt or Now) > LEGACY_AFTER then
            return false   -- bereit, aber kein Handshake (legacy/net_v3 aus): Legacy-Pfad behalten
        end
    end
    return true
end

function Net.Linked(G)
    if Net.Side == "client" then return Net.Host ~= nil and Net.Host.Epoch ~= nil end
    local P = Resolve(G)
    return P ~= nil and P.Epoch ~= nil
end

function Net.Enabled() return Net.Active end

-- ---------------------------------------------------------------- Empfang

-- Aus dem Empfangs-Hook (nur Lua-Tabellen!): Rahmen ohne "NETTEST|v3|" und Absender ("host" bzw. PC-Key)
function Net.Push(Payload, Sender)
    local S, Now = Net.Stat, os.clock()
    S.pushed = S.pushed + 1
    if #Net.Inbox >= INBOX_MAX then Drop("inbox_full") return end
    local R = Net.PushRate[Sender]
    if not R or Now - R.At >= 1 then
        R = { At = Now, N = 0, WarnAt = R and R.WarnAt or 0, WarnN = R and R.WarnN or 0 }
        Net.PushRate[Sender] = R
    end
    R.N = R.N + 1
    if R.N > PUSH_RATE then Drop("flood") return end
    Net.Inbox[#Net.Inbox + 1] = { P = Payload, K = Sender, T = Now }
end

-- Alte Nachrichtenarten (part|kind|...), die der alte Verteiler nicht kennt: an Net.On-Handler (msg.Legacy = true)
function Net.PushLegacy(Sender, Kind, Data)
    if #Net.Inbox >= INBOX_MAX then Drop("inbox_full") return end
    local Now = os.clock()
    local R = Net.LegacyRate[Sender]
    if not R or Now - R.At >= 1 then R = { At = Now, N = 0 } Net.LegacyRate[Sender] = R end
    R.N = R.N + 1
    if R.N > LEGACY_RATE then Drop("legacy_flood") return end
    Net.Inbox[#Net.Inbox + 1] = { L = true, K = Sender, Kind = Kind, Data = Data, T = Now }
end

-- net_peer_fail (CORE-12): Handler-Fehler je (Art, Gegenstelle) zaehlen. Auf dem Host zaehlen von einem Gast hoechstens
-- 2 Fehler je 60 s fuer die Abschaltung der Art (Core.Fail: mehr als 3) - ein einzelner (modifizierter) Gast schaltet
-- eine Art so nie fuer alle ab, Fehler mehrerer Gaeste oder der eigenen Seite weiter schon. Darueber: nur secwarn.
local function HandlerFail(Flag, Kind, Peer, Err)
    if Net.Side ~= "host" or type(Peer) ~= "table" or not Core.Flag("net_peer_fail", true) then
        Core.Fail(Flag, Err)
        return
    end
    local Now = os.clock()
    local PF = Peer.Fail
    if not PF then PF = {} Peer.Fail = PF end
    local E = PF[Kind]
    if not E or Now - E.At > 60 then E = { At = Now, N = 0 } PF[Kind] = E end
    E.N = E.N + 1
    if E.N <= 2 then Core.Fail(Flag, Err) return end
    if E.N == 3 then Log("Handler %s: Fehler von %s ab jetzt nur gezaehlt (%s)", Kind, tostring(Peer.GuestId or Peer.Key), tostring(Err)) end
    Net.SecWarn(Peer, Peer.Key, "handler_" .. Kind)
end

local function Dispatch(Kind, Data, Peer, Msg)
    local List, Mod = Net.Handlers[Kind], A.Coop.ModHandlers and A.Coop.ModHandlers[Kind]
    if not List and not Mod then Drop("unhandled") return end
    local Flag = "net_h_" .. Kind
    if Core.Down[Flag] then Drop("handler_down") return end
    for _, Fn in ipairs(List or {}) do
        if Fn == Mod then Mod = nil end
        local ok, err = pcall(Fn, Data, Peer, Msg)
        if not ok then HandlerFail(Flag, Kind, Peer, err) end
    end
    if Mod then
        local ok, err = pcall(Mod, Data, Peer, Msg)
        if not ok then HandlerFail(Flag, Kind, Peer, err) end
    end
end

local function Complete(Peer, Kind, Seq, Flags, Data)
    local Rx, S = Peer.Rx, Net.Stat
    if not Rx.Done[Seq] then Rx.Done[Seq], Rx.DoneN = true, Rx.DoneN + 1 end
    if Seq > Rx.Hi then Rx.Hi = Seq end
    if Rx.DoneN > 2 * DONE_KEEP then
        Rx.Floor = Rx.Hi - DONE_KEEP
        local Keep, N = {}, 0
        for Q in pairs(Rx.Done) do if Q > Rx.Floor then Keep[Q], N = true, N + 1 end end
        Rx.Done, Rx.DoneN = Keep, N
    end
    S.inMsg = S.inMsg + 1
    local Answer = tonumber(Flags:match("a(%d+)"))
    if Answer then
        local R = Peer.Pend[Answer]
        if not R then Drop("late_answer") return end
        Peer.Pend[Answer] = nil
        local ok, err = pcall(R.Cb, Data, Peer)
        if not ok then Log("Antwort %s: Fehler %s", Kind, tostring(err)) end
        return
    end
    if Kind == "nka" then return end   -- Lebenszeichen (RxAt schon in HandleFrame)
    local Msg = { Kind = Kind, Sender = Peer, Seq = Seq, Epoch = Peer.Epoch, Rid = tonumber(Flags:match("r(%d+)")) }
    if not Flags:find("s", 1, true) then Dispatch(Kind, Data, Peer, Msg) return end
    local Host = Net.Side == "host"
    local Mirror = Net.Mirror[Peer.Key] or {}
    Net.Mirror[Peer.Key] = Mirror
    local Tab = Mirror[Kind] or {}
    Mirror[Kind] = Tab
    local N = 0
    for Entry in (Data .. ";"):gmatch("([^;]*);") do
        if Entry ~= "" then
            N = N + 1
            if Host and N > STATE_ENTRIES then Net.SecWarn(Peer, Peer.Key, "state_entries") return end
            local K, V = Entry:match("^([^=]*)=(.*)$")
            if K then K, V = Net.Dec(K), Net.Dec(V) else K = Net.Dec(Entry) end
            local Ok, Old = true, Tab[K]
            if Host then
                -- Gast-State begrenzen: Schluessel je Art und Bytes je Gast (sonst waechst der Host-Speicher ohne Ende)
                local Cnt = Peer.MirN[Kind] or 0
                local Delta = (V ~= nil and #K + #V + 32 or 0) - (Old ~= nil and #K + #Old + 32 or 0)
                if Old == nil and V ~= nil and Cnt >= MIRROR_KEYS then Ok = false Net.SecWarn(Peer, Peer.Key, "state_keys")
                elseif Delta > 0 and Peer.MirB + Delta > MIRROR_BYTES then Ok = false Net.SecWarn(Peer, Peer.Key, "state_bytes")
                else
                    Peer.MirB = Peer.MirB + Delta
                    if Old == nil and V ~= nil then Cnt = Cnt + 1 elseif Old ~= nil and V == nil then Cnt = Cnt - 1 end
                    Peer.MirN[Kind] = Cnt
                end
            end
            if Ok then
                Tab[K] = V
                Dispatch(Kind, V, Peer, { Kind = Kind, Sender = Peer, Seq = Seq, Epoch = Peer.Epoch, State = true, Key = K })
            end
        end
    end
end

-- Doppel-Login: anderer verbundener Gast (lebender PC, nicht in GuestDup), der diese ID schon hat
local function IdOwner(G, Id)
    local L, Dup = tostring(Id):lower(), A.Coop.GuestDup
    for K, O in pairs(Net.Guests) do
        if K ~= G.Key and O.GuestId and tostring(O.GuestId):lower() == L and not (Dup and Dup[K]) and Net.PC(K) then return O end
    end
    return nil
end

-- einmal je Gast und ID: deutsch loggen, Gast-Hinweis (Weg wie ls_clan Note: ui_note2, sonst Alt-Kanal "note")
local function RefuseDup(G, Id, Other)
    local Tag = tostring(Id):lower()
    if G.DupRefused == Tag then return end
    G.DupRefused = Tag
    Log("Doppel-Login: ID %s ist schon mit %s verbunden - %s bekommt sie nicht", tostring(Id),
        tostring(Other and (Other.PCName or Other.Key) or "?"), tostring(G.PCName or G.Key))
    local Text = "Diese Spieler-ID ist bereits verbunden - Doppel-Login abgelehnt"
    local Ui = A.Coop.Modules and A.Coop.Modules.ls_ui
    if Ui and Ui.Note and Net.Has("ui_note2", G) and pcall(Ui.Note, G, Text, "", true) then return end
    local PC = Net.PC(G)
    if PC then pcall(A.SendChunked, function(T) A.SendToClient(PC, T) end, "note", Text) end
end

-- GuestDup-Key: keine ID (bereits vergebene wieder weg), einmal loggen
local function SkipDup(G)
    local Dup = A.Coop.GuestDup
    if not (Dup and Dup[G.Key]) then G.DupSkipped = nil return false end
    G.WantId = nil
    if G.GuestId or not G.DupSkipped then
        Log("Doppel-Login: %s als Duplikat markiert - ID %s nicht uebernommen", tostring(G.PCName or G.Key), tostring(G.GuestId or "-"))
        G.GuestId, G.DupSkipped = nil, true
    end
    return true
end

-- Host: h4 eines Gasts. Gleiche Nonce = Wiederholung (gleiche Epoche, nur neu bestaetigen), sonst neue Epoche.
local function OnH4(G, Data)
    local GuestId, Caps, Nonce = Data:match("^(%x*)|([%w_,]*)|(%w+)$")
    if not GuestId then Net.SecWarn(G, G.Key, "h4") return end
    local New = not G.Epoch or G.Nonce ~= Nonce
    if New then
        ResetLink(G)
        Net.EpochSeq = Net.EpochSeq + 1
        G.Epoch, G.Nonce = Net.EpochBase + Net.EpochSeq, Nonce
    end
    G.RxAt = os.clock()
    local Taken
    if GuestId ~= "" and not SkipDup(G) then
        -- ID an die Verbindung binden: alte ID (hello/guestid) bzw. die erste h4-ID dieses Controllers gilt
        local Coop = A.Coop
        local Bound = (Coop.HelloIds and Coop.HelloIds[G.Key]) or (Coop.GuestIds and Coop.GuestIds[G.Key]) or G.GuestId
        if Bound and tostring(Bound):lower() ~= GuestId:lower() then
            Net.SecWarn(G, G.Key, "h4_id")
        elseif not (G.GuestId and tostring(G.GuestId):lower() == GuestId:lower()) then
            Taken = IdOwner(G, GuestId)
            if Taken then G.WantId = GuestId else G.GuestId, G.WantId = GuestId, nil end   -- WantId: ScanGuests vergibt spaeter, wenn frei
        end
    end
    local WasOff = next(G.Caps) == nil
    G.PeerCaps = ParseCaps(Caps)
    G.Caps = Intersect(G.PeerCaps)
    SendH4a(G)
    if Taken then RefuseDup(G, GuestId, Taken) end
    if New then
        Log("Gast %s verbunden (v3, Epoche %d, Caps %s)", G.GuestId or "?", G.Epoch, CapList(G.Caps))
        Net.Refresh(G, "full")
        Emit("linked", G)
        if G.Ready then Emit("ready", G) end   -- Figur war schon vor dem Handshake da
    elseif WasOff and next(G.Caps) ~= nil then
        Log("Gast %s: Caps wieder da (%s)", G.GuestId or "?", CapList(G.Caps))
        Net.Refresh(G, "full")
    end
end

-- Gast: h4a vom Host (gilt in jeder Epoche; neue Epoche = Folgenummern und Empfang neu)
local function OnH4a(H, Data, Epoch, Seq)
    local E, Fps, Caps = Data:match("^(%d+)|(%d*)|([%w_,]*)$")
    E = tonumber(E)
    if not E or E == 0 or E ~= Epoch then Net.SecWarn(H, H.Key, "h4a") return end
    local WasOff = next(H.Caps) == nil
    H.Fps, H.Caps = tonumber(Fps), ParseCaps(Caps)
    H.RxAt = os.clock()
    if H.Epoch == E then
        H.Rx.Done[Seq] = true
        if next(H.Caps) == nil and not WasOff then Log("Host hat v3 abgeschaltet (Caps leer), weiter mit legacy") end
        if WasOff and next(H.Caps) ~= nil then Net.Refresh(H, "full") end
        return
    end
    ResetLink(H)
    H.Epoch = E
    H.Rx.Done[Seq], H.Rx.DoneN, H.Rx.Hi = true, 1, Seq
    Log("Mit dem Host verbunden (v3, Epoche %d, Server-FPS %s, Caps %s)", E, tostring(H.Fps), CapList(H.Caps))
    Net.Refresh(H, "full")
    Emit("linked", H)
    if H.Ready then Emit("ready", H) end   -- Figur war schon vor dem Handshake da
end

-- Gast: h4n vom Host = er kennt unsere Epoche nicht (mehr) bzw. will neu aushandeln. Bis zum neuen h4a: Caps leer.
local function OnH4n(H, Data)
    if not H.Epoch then return end
    local E = tonumber(Data) or 0
    if E ~= 0 and E == H.Epoch then return end
    if next(H.Caps) ~= nil then Log("Host kennt unsere Verbindung nicht mehr (h4n), neuer Handshake") end
    H.Caps, H.ReH4 = {}, true
end

-- Host: Gast soll neu h4 schicken (unbekannte/alte Epoche, Zeitueberschreitung). Hoechstens alle H4_EVERY s.
local function Nack(G, Now, Renew)
    if Now < (G.NackAt or 0) then return end
    G.NackAt = Now + H4_EVERY
    local Sent = Wire(G, "h4n", 0, 1, 1, "e0", tostring((not Renew and G.Epoch) or 0))
    if Sent then G.Bytes, G.Frames = G.Bytes - Sent, G.Frames - 1 end
end

local function PeerFor(Sender, Kind)
    if Net.Side == "client" then
        if Sender ~= "host" then return nil end
        return Net.Host
    end
    if Net.Side ~= "host" or Sender == "host" then return nil end
    local G = Net.Guests[Sender]
    if not G and (Kind == "h4" or Kind == true) then
        G = NewPeer(Sender)
        Net.Guests[Sender] = G
        Emit("guest", G)
    end
    return G
end

-- Host: hoechstens C2S_RATE Rahmen je Sekunde und Gast
local function RateOk(Peer, Now)
    if Net.Side ~= "host" then return true end
    local R = Peer.Rate
    if Now - R.At >= 1 then R.At, R.N = Now, 0 end
    R.N = R.N + 1
    if R.N > C2S_RATE then Net.SecWarn(Peer, Peer.Key, "rate") return false end
    return true
end

local function HandleFrame(E, Now)
    local S = Net.Stat
    if E.L then
        S.legacy = S.legacy + 1
        local Peer = PeerFor(E.K, true)
        if Peer and RateOk(Peer, Now) then
            Dispatch(E.Kind, E.Data, Peer, { Kind = E.Kind, Sender = Peer, Legacy = true, Epoch = Peer.Epoch })
        end
        return
    end
    S.inF, S.inB = S.inF + 1, S.inB + #E.P + 11
    local Kind, Seq, I, N, Flags, Data = E.P:match("^([%w_]+)|(%d+)|(%d+)|(%d+)|(%w*)|(.*)$")
    local Peer = Kind and PeerFor(E.K, Kind)
    if not Kind then Net.SecWarn(nil, E.K, "frame") return end
    if not Peer then Drop("no_peer") return end
    if not RateOk(Peer, Now) then return end
    Seq, I, N = tonumber(Seq), tonumber(I), tonumber(N)
    if #Kind > LIM.KIND or N < 1 or N > LIM.N or I < 1 or I > N or #Data > LIM.FRAME then
        Net.SecWarn(Peer, Peer.Key, "limits") return
    end
    local Epoch = tonumber(Flags:match("e(%d+)")) or 0
    if Kind == "h4" and Net.Side == "host" and N == 1 then OnH4(Peer, Data) return end
    if Kind == "h4a" and Net.Side == "client" and N == 1 then OnH4a(Peer, Data, Epoch, Seq) return end
    if Kind == "h4n" and Net.Side == "client" and N == 1 then OnH4n(Peer, Data) return end
    if not Peer.Epoch or Epoch ~= Peer.Epoch then
        Drop("epoch")
        if Net.Side == "host" then Nack(Peer, Now) end   -- sonst bliebe der Gast mit alter Epoche stumm haengen
        return
    end
    Peer.RxAt = Now
    local Rx = Peer.Rx
    local O = Rx.Open[Seq]
    if not O and (Rx.Done[Seq] or Seq <= Rx.Floor) then Drop("dup") return end
    if N == 1 then Complete(Peer, Kind, Seq, Flags, Data) return end
    if not O then
        if Rx.OpenN >= LIM.OPEN then Net.SecWarn(Peer, Peer.Key, "open") return end
        O = { Kind = Kind, N = N, Parts = {}, Got = 0, Bytes = 0, At = Now, Flags = Flags }
        Rx.Open[Seq], Rx.OpenN = O, Rx.OpenN + 1
    elseif O.N ~= N or O.Kind ~= Kind then
        Rx.Open[Seq], Rx.OpenN, Rx.Done[Seq] = nil, Rx.OpenN - 1, true
        Net.SecWarn(Peer, Peer.Key, "mismatch") return
    end
    if O.Parts[I] then Drop("dup") return end
    O.Parts[I], O.Got, O.Bytes, O.At = Data, O.Got + 1, O.Bytes + #Data, Now   -- Ablauf zaehlt ab dem letzten Fragment
    if O.Bytes > LIM.TOTAL then
        Rx.Open[Seq], Rx.OpenN, Rx.Done[Seq] = nil, Rx.OpenN - 1, true
        Net.SecWarn(Peer, Peer.Key, "total") return
    end
    if O.Got < N then return end
    Rx.Open[Seq], Rx.OpenN = nil, Rx.OpenN - 1
    Complete(Peer, Kind, Seq, O.Flags, table.concat(O.Parts))
end

-- Anzahl verbundener Gaeste (Host; Gast: 0)
function Net.GuestCount()
    local N = 0
    for _ in pairs(Net.Guests) do N = N + 1 end
    return N
end

-- Verworfene Rahmen/Nachrichten seit dem Start als "grund=n,..." (sortiert; "-" = keine), z. B. fuer die Leistung-Zeile
function Net.DropText()
    local Parts = {}
    for Why, N in pairs(Net.Stat.drop) do Parts[#Parts + 1] = Why .. "=" .. N end
    table.sort(Parts)
    return #Parts > 0 and table.concat(Parts, ",") or "-"
end

-- CORE-15: je Tick IN_FRAMES Rahmen plus 15 je Gast (8 Gaeste mit voller C2S-Rate passten sonst nicht hinein), weiter
-- hoechstens ~4 ms. Staut es sich trotzdem (> 500 Rahmen), einmal je Minute melden.
local function ProcessInbox(Now)
    local Box = Net.Inbox
    if #Box == 0 then return end
    Net.Inbox = {}
    local Max = IN_FRAMES + 15 * Net.GuestCount()
    local T0, K = os.clock(), 0
    while K < #Box and K < Max and (K == 0 or os.clock() - T0 < IN_TIME) do
        K = K + 1
        if Net.Active and Net.Side then HandleFrame(Box[K], Now) else Drop("inactive") end
    end
    if K < #Box then
        local Rest = {}
        for J = K + 1, #Box do Rest[#Rest + 1] = Box[J] end
        for _, E in ipairs(Net.Inbox) do Rest[#Rest + 1] = E end
        Net.Inbox = Rest
        if #Rest > 500 and Now >= (Net.LagLogAt or 0) then
            Net.LagLogAt = Now + 60
            Log("Empfang hinkt: %d Rahmen warten (je Tick hoechstens %d, Verworfen{%s})", #Rest, Max, Net.DropText())
        end
    end
end

-- ---------------------------------------------------------------- Ticks

local function DropPeer(Peer, Why)
    FailPending(Peer, "gone")
    Net.Mirror[Peer.Key] = nil
    for _, S in pairs(Net.StateTab) do S.Per[Peer.Key] = nil end
    Emit("gone", Peer)
    Log("Gegenstelle %s weg (%s)", Peer.GuestId or Peer.Key, Why)
end

local function DropAll(Why)
    for Key, G in pairs(Net.Guests) do Net.Guests[Key] = nil DropPeer(G, Why) end
    if Net.Host then
        local H = Net.Host
        Net.Host = nil
        DropPeer(H, Why)
    end
    Net.PCs = nil
end

-- Gast: Nutzdaten fuer h4 ("<guestId>|<caps>|<nonce>")
local function H4Data(Caps)
    local Id = A.Safe(function() return A.Coop.OwnGuestId() end, "") or ""
    return string.format("%s|%s|%s", tostring(Id):match("^%x*$") and Id or "", Caps, Net.Host.Nonce)
end

-- net_v3 aus (FLAG_DOWN/Schalter): verbundenen Gegenstellen leere Caps melden (best effort, direkt ueber Wire),
-- damit sie fuer uns wieder die alten Pfade nehmen. Net.Active ist hier schon false.
local function SayBye()
    if Net.Side == "host" then
        for _, G in pairs(Net.Guests) do
            if G.Epoch then
                G.SeqOut = G.SeqOut + 1
                pcall(Wire, G, "h4a", G.SeqOut, 1, 1, "e" .. G.Epoch, string.format("%d|%d|", G.Epoch, FpsCap()))
            end
        end
    elseif Net.Side == "client" and Net.Host and Net.Host.Epoch then
        local ok, Data = pcall(H4Data, "")
        if ok then pcall(Wire, Net.Host, "h4", 0, 1, 1, "e0", Data) end
    end
end

-- net_v3 wieder an: Caps neu aushandeln, Keyed-State voll auffrischen (Warteschlangen wurden geleert)
local function Revive()
    local Now = os.clock()
    if Net.Side == "client" and Net.Host then
        local H = Net.Host
        H.ReH4, H.H4At, H.RxAt = true, 0, Now
        if H.Epoch then Net.Refresh(H, "full") end
    elseif Net.Side == "host" then
        for _, G in pairs(Net.Guests) do
            if G.Epoch then
                G.RxAt, G.Caps = Now, Intersect(G.PeerCaps)
                Net.Refresh(G, "full")
                SendH4a(G)
            end
        end
    end
end

local function UpdateSide()
    local Was = Net.Active
    Net.Active = Core.Flag("net_v3", true) and true or false
    if Was and not Net.Active then
        Log("Protokoll v3 aus, Gegenstellen bekommen leere Caps")
        SayBye()
    elseif Net.Active and not Was then
        Log("Protokoll v3 wieder an, Caps neu aushandeln")
        Revive()
    end
    -- world_hygiene (CORE-8 g): neue Weltgeneration (Beitritt, Trennen, Kick) = Gegenstellen und Caps der alten Welt
    -- sofort weg, ohne die 3-s-Gnade unten (Module blieben sonst im Modus "client" einer toten Welt). Danach wird die
    -- Seite aus der neuen Welt neu bestimmt (Handshake von vorn).
    local WG = A.WorldGen
    local Gen = WG and WG.N
    if Gen ~= nil and Net.Gen ~= Gen then
        local Old = Net.Gen
        Net.Gen = Gen
        if Old ~= nil and Net.Side and Core.Flag("world_hygiene", true) then
            DropAll("Weltwechsel")
            Net.Side, Net.NilSince = nil, nil
        end
    end
    local World = A.Safe(A.CurrentWorld)
    local Mode = World and A.IsAlive(World) and A.Safe(function() return A.NetModeName(World) end) or nil
    local Side = (Mode == "ListenServer" or Mode == "DedicatedServer") and "host" or (Mode == "Client" and "client") or nil
    -- kurz keine Welt/kein Modus (Respawn, Laden): erst nach 3 s als getrennt werten
    if Side == nil and Net.Side then
        Net.NilSince = Net.NilSince or os.clock()
        if os.clock() - Net.NilSince < 3 then return nil end
    end
    Net.NilSince = nil
    if Side ~= Net.Side then
        DropAll("Modus " .. tostring(Mode))
        Net.Side = Side
    end
    return World
end

-- Host, 1 s: Gaeste aus den Controllern der GameState (wie HandleRemotePlayers), Pawn, IDs, Ready
local function ScanGuests(World, Now)
    -- Gnadenfrist von UpdateSide (keine Welt): ScanPCs waere leer, Gaeste nicht als fehlend zaehlen
    if not World then return end
    local Map, Coop = Net.ScanPCs(true), A.Coop
    for Key, PC in pairs(Map) do
        local G = Net.Guests[Key]
        if not G then
            G = NewPeer(Key)
            Net.Guests[Key] = G
            Emit("guest", G)
        end
        G.Missing = 0
        G.PCName = A.Safe(function() return PC:GetFName():ToString() end, G.PCName)
        local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
        G.PawnName = A.IsAlive(Pawn) and A.Safe(function() return Pawn:GetFName():ToString() end) or nil
        -- alte ID (hello/guestid) hat Vorrang vor der h4-ID (OnH4 nimmt abweichende h4-IDs nicht an)
        -- Doppel-Login: GuestDup-Keys ueberspringen, ID eines anderen verbundenen Gasts nicht vergeben
        if not SkipDup(G) then
            local Legacy = (Coop.HelloIds and Coop.HelloIds[Key]) or (Coop.GuestIds and Coop.GuestIds[Key])
            if Legacy and G.GuestId and tostring(Legacy):lower() ~= tostring(G.GuestId):lower() then
                Log("Gast %s: h4-ID %s passt nicht zur alten ID %s, nehme die alte", tostring(G.PCName), tostring(G.GuestId), tostring(Legacy))
            end
            local Want = Legacy or G.WantId
            if Want and not (G.GuestId and tostring(G.GuestId):lower() == tostring(Want):lower()) then
                local Other = IdOwner(G, Want)
                if Other then
                    RefuseDup(G, Want, Other)
                    G.GuestId = nil   -- abweichende h4-ID nicht behalten (alte ID hat Vorrang)
                else
                    G.GuestId, G.WantId, G.DupRefused = Want, nil, nil
                end
            elseif Want then
                G.WantId = nil
            end
        end
        G.SteamId = Coop.SteamIds and Coop.SteamIds[Key]
        local Ready = G.PawnName ~= nil and A.Safe(function() return not Coop.Join or Coop.Join.IsReady(Key) end, true)
        if Ready and not G.Ready then G.ReadyAt = Now end
        if Ready and not G.Ready and G.Epoch then
            Net.Refresh(G, "full")
            Emit("ready", G)
        end
        G.Ready = Ready and true or false
    end
    for Key, G in pairs(Net.Guests) do
        if not Map[Key] then
            G.Missing = G.Missing + 1
            if G.Missing >= 2 then Net.Guests[Key] = nil DropPeer(G, "getrennt") end
        end
    end
    for Key, R in pairs(Net.PushRate) do
        if Now - R.At > 30 then Net.PushRate[Key] = nil end
    end
    for Key, R in pairs(Net.LegacyRate) do
        if Now - R.At > 30 then Net.LegacyRate[Key] = nil end
    end
end

-- Gast, 1 s: Verbindung erkennen, h4 bis zur Antwort, Ready (Figur da, join_v2 fertig)
local function ScanClient(World, Now)
    local ND = A.Safe(function() return World.NetDriver end)
    local Conn = A.IsAlive(ND) and A.Safe(function() return ND.ServerConnection:IsValid() end, false) or false
    if not Conn then
        local H = Net.Host
        if H then
            H.Lost = (H.Lost or 0) + 1
            if H.Lost >= 2 then Net.Host = nil DropPeer(H, "Verbindung zu") end
        end
        return
    end
    if not Net.Host then
        Net.Host = NewPeer("host")
        Net.Host.Nonce = string.format("%x%04x", os.time(), math.random(0, 0xFFFF))
    end
    local H = Net.Host
    H.Lost = 0
    if Net.Active and (not H.Epoch or H.ReH4) and Now >= (H.H4At or 0) then
        H.H4At, H.ReH4 = Now + H4_EVERY, nil
        local Data = H4Data(CapList(Net.LocalCaps))
        Refill(H, Now)
        local Sent = Wire(H, "h4", 0, 1, 1, "e0", Data)
        if Sent then H.Bytes, H.Frames = H.Bytes - Sent, H.Frames - 1 end
    end
    local LPC = A.Safe(A.LocalPC)
    local Pawn = A.IsAlive(LPC) and A.Safe(function() return LPC:K2_GetPawn() end) or nil
    local JC = A.Coop.JoinC
    local Ready = A.IsAlive(Pawn) and (JC == nil or JC.State == "ready" or JC.State == "off")
    if Ready and not H.Ready and H.Epoch then
        Net.Refresh(H, "full")
        Emit("ready", H)
    end
    H.Ready = Ready and true or false
end

local function Housekeep(Peer, Now)
    for Rid, R in pairs(Peer.Pend) do
        if Now >= R.Until then
            Peer.Pend[Rid] = nil
            pcall(R.Cb, nil, Peer, "timeout")
        end
    end
    local Rx = Peer.Rx
    for Seq, O in pairs(Rx.Open) do
        if Now - O.At > LIM.EXPIRE then
            Rx.Open[Seq], Rx.OpenN, Rx.Done[Seq] = nil, Rx.OpenN - 1, true
            Net.SecWarn(Peer, Peer.Key, "expired")
        end
    end
    if Peer.Epoch and Now >= Peer.RefreshAt then Net.Refresh(Peer, "low") end
    if Peer.Epoch and Net.Active then
        -- Lebenszeichen, damit die Gegenstelle einen toten Kanal erkennt
        if Now - (Peer.TxAt or 0) >= KA_EVERY and #Peer.Q[1] == 0 then Enqueue(Peer, "nka", "", 1, "") end
        if Now - (Peer.RxAt or Now) > LIVE_TIMEOUT then
            Peer.RxAt = Now
            if next(Peer.Caps) ~= nil then
                Log("Gegenstelle %s: %d s nichts empfangen, Caps aus, neu aushandeln", tostring(Peer.GuestId or Peer.Key), LIVE_TIMEOUT)
            end
            Peer.Caps = {}
            if Net.Side == "client" then Peer.ReH4 = true else Nack(Peer, Now, true) end
        end
    end
end

local function Guard(Fn)
    return function(Now)
        local ok, err = pcall(Fn, Now)
        if not ok and Core.Fail("net_v3", err) then
            if Net.Active then
                Log("Protokoll v3 abgeschaltet (Fehler): %s", tostring(err))
                Net.Active = false
                pcall(SayBye)
            end
            Net.Active = false
        end
    end
end

local function InTick(Now)
    UpdateSide()
    ProcessInbox(Now)
end

local function OutTick(Now)
    if not Net.Side then return end
    if not Net.Active then
        for _, P in pairs(Net.Guests) do P.Q = { [0] = {}, {}, {}, {} } end
        if Net.Host then Net.Host.Q = { [0] = {}, {}, {}, {} } end
        return
    end
    if Net.Side == "client" then
        if Net.Host then Pump(Net.Host, Now) end
        return
    end
    for _, G in pairs(Net.Guests) do Pump(G, Now) end
end

local function ScanTick(Now)
    local World = UpdateSide()
    if Net.Side == "host" then ScanGuests(World, Now)
    elseif Net.Side == "client" and World then ScanClient(World, Now) end
    for _, G in pairs(Net.Guests) do Housekeep(G, Now) end
    if Net.Host then Housekeep(Net.Host, Now) end
end

-- ---------------------------------------------------------------- Statistik

function Net.Stats()
    local S, Parts = Net.Stat, {}
    local Drops = {}
    for Why, N in pairs(S.drop) do Drops[#Drops + 1] = Why .. "=" .. N end
    table.sort(Drops)
    Parts[1] = string.format("v3 %s Seite=%s ein %dR/%dB/%dN aus %dR/%dB/%dN Inbox=%d Legacy=%d Verworfen{%s}",
        Net.Active and "an" or "aus", tostring(Net.Side), S.inF, S.inB, S.inMsg, S.outF, S.outB, S.outMsg,
        #Net.Inbox, S.legacy, table.concat(Drops, ","))
    local function Peer(P)
        local Q = {}
        for Prio = 0, 3 do Q[#Q + 1] = #P.Q[Prio] end
        Parts[#Parts + 1] = string.format("%s id=%s ep=%s seq=%d hi=%d offen=%d Q=%s Bytes=%.0f Rahmen=%.1f bereit=%s caps=%s",
            P.PCName or P.Key, tostring(P.GuestId), tostring(P.Epoch), P.SeqOut, P.Rx.Hi, P.Rx.OpenN,
            table.concat(Q, "/"), P.Bytes, P.Frames, tostring(P.Ready), CapList(P.Caps))
    end
    for _, G in pairs(Net.Guests) do Peer(G) end
    if Net.Host then Peer(Net.Host) end
    return table.concat(Parts, " | "), S
end

function Net.Init(Api)
    A = Api
    A.Coop.Net, A.Net = Net, Net   -- Coop.Net: Empfangs-Hooks in main.lua; A.Net: spaetere Module
    Net.Rate = Core.Flag("net_kbps", 12) * 1024
    Net.Burst = Core.Flag("net_burst", 24) * 1024
    Net.Fps = Core.Flag("net_fps", 30)
    if Net.Rate <= 0 then Net.Rate = 12 * 1024 end
    if Net.Burst <= 0 then Net.Burst = 24 * 1024 end
    if Net.Fps <= 0 then Net.Fps = 30 end
    Net.EpochBase = (os.time() % 100000) * 1000
    Net.Active = Core.Flag("net_v3", true) and true or false
    if A.TestCommands then
        A.TestCommands.netstats = function() Log("%s", (Net.Stats())) end
    end
    Core.Every("net_in", 0.1, Guard(InTick))
    Core.Every("net_out", 0.1, Guard(OutTick))
    Core.Every("net_scan", 1.0, Guard(ScanTick))
    Log("Protokoll v3 %s (%.0f KB/s, Burst %.0f KB, %d Rahmen/s)", Net.Active and "an" or "aus (net_v3=0/legacy)",
        Net.Rate / 1024, Net.Burst / 1024, Net.Fps)
end

return Net
