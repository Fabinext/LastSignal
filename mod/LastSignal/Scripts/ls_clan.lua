-- Last Signal Runde 7: Clans (Host-Autoritaet, Gast-Ansicht). Export: A.Coop.Clan = M
--   Host:  M.ClanOf(Gid), M.Allied(GidA, GidB), M.GuestIdOf(G|PC|Pawn|PS|Key), M.Chat(G, Text), M.Index(Gid),
--          M.OnChange(fn(Reason, ClanName, Info)), Info nur bei leave/kick/dissolve:
--          {Gid = Ausgetretener, Leader = neuer Leiter | nil (aufgeloest), Name, Old = {gid...} Mitglieder vorher},
--          M.Members(Gid|Name) -> {gid...}, M.AllyMap() -> {[Pawn] = Index}
--   Gast:  M.My() -> {Name, Leader, Members = {[PlayerId] = Name}, Offline = {Name...}} | nil, M.IsMatePid(PlayerId)
--   Netz:  clan_st (Host -> Gast, Keyed-State, Sonderwert je Gast, Schluessel "s":
--          "Name|Leiter|pid:name,pid:name,..." jedes Feld mit Esc maskiert, pid 0 = offline; "" = kein Clan)
--          clan_msg (Host -> Gast, "<c|s>|<Enc Name>|<Enc Text>": c = Clan-Chat, s = Systemzeile)
--   Datei: clans.txt im Mod-Ordner (Host, atomar): "c|<Name>|<LeiterId>|<Gruendung>", danach "m|<Id>|<Name>"
--   Schalter: clan_on (1), clan_max (8), clan_disband (1). Cap: clan1
--   Runde 9: /clan disband <Name> (Leiter, PLAYER-24), M.Flush() = offene Aenderungen sofort schreiben (E29, server.lua stop)
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local A

local FLAG, CAP = "clan_on", "clan1"
local FILE = "clans.txt"
local INVITE_SECONDS, CHAT_MAX = 300, 150

-- Host-Zustand
local C = {
    Clans = {},      -- [nameLower] = { Name, Leader = gid, Members = {gid...}, Names = {[gid] = Name}, Created }
    Of = {},         -- [gid] = nameLower
    Invites = {},    -- [gid] = { Clan = nameLower, By = gid, At = os.time() }
    Idx = {},        -- [nameLower] = Index (stabil je Sitzung)
    NextIdx = 1,
    Online = { List = {}, ByGid = {}, ByPid = {}, ByKey = {} },
    Queue = {},      -- Befehle aus dem Chat { Key, Gid, Name, Cmd, Arg }
    CmdAt = {},      -- [Key] = os.clock() letzter Befehl
    Loaded = false, Dirty = false,
    Listeners = {},
    -- Gast
    Mine = nil, MineRaw = nil,
}
M.C = C

local function Log(fmt, ...) A.Log("[Clan] " .. fmt, ...) end
local function On() return Core.Flag(FLAG, true) == true end
local function Lower(S) return type(S) == "string" and S:lower() or nil end

-- Felder im clan_st-Wert: Net.Enc plus ":" und ","
local function Esc(S)
    return (Net.Enc(tostring(S or "")):gsub("[:,]", function(Ch) return string.format("%%%02X", Ch:byte()) end))
end

local function CleanName(S)
    S = tostring(S or ""):gsub("[%c|]", " "):match("^%s*(.-)%s*$")
    return S:sub(1, 32)
end

local function CutText(S)
    S = tostring(S or ""):gsub("[%c|]", " "):match("^%s*(.-)%s*$")
    local Cut = utf8.len(S) and utf8.offset(S, CHAT_MAX + 1)
    if Cut then return S:sub(1, Cut - 1) end
    if utf8.len(S) then return S end
    return (S:gsub("[\128-\255]", "?"):sub(1, CHAT_MAX))
end

local function Fire(Reason, ClanName, Info)
    for _, Fn in ipairs(C.Listeners) do
        local ok, err = pcall(Fn, Reason, ClanName, Info)
        if not ok then Log("OnChange-Fehler: %s", tostring(err)) end
    end
end

local function IndexOf(Low)
    if not Low then return 0 end
    local I = C.Idx[Low]
    if not I then I = C.NextIdx C.Idx[Low] = I C.NextIdx = I + 1 end
    return I
end

-- ---------------------------------------------------------------- Persistenz (Host)

local function Save()
    local Lines = { "# LastSignal Clans: c|Name|LeiterId|Gruendung, danach m|MitgliedId|Name" }
    local Keys = {}
    for Low in pairs(C.Clans) do Keys[#Keys + 1] = Low end
    table.sort(Keys)
    for _, Low in ipairs(Keys) do
        local Cl = C.Clans[Low]
        Lines[#Lines + 1] = string.format("c|%s|%s|%d", Net.Enc(Cl.Name), Cl.Leader, Cl.Created or 0)
        for _, Gid in ipairs(Cl.Members) do
            Lines[#Lines + 1] = string.format("m|%s|%s", Gid, Net.Enc(Cl.Names[Gid] or "?"))
        end
    end
    if Core.WriteAtomic(A.ModDir .. FILE, table.concat(Lines, "\n") .. "\n") then
        C.Dirty = false
    else
        Core.Fail(FLAG, "clans.txt nicht schreibbar")
    end
end

local function Load()
    if C.Loaded then return end
    C.Loaded = true
    local Text = Core.ReadAll(A.ModDir .. FILE)
    if not Text then Log("keine %s, starte ohne Clans", FILE) return end
    local Cur, N = nil, 0
    for Line in Text:gmatch("[^\r\n]+") do
        local Name, Leader, Created = Line:match("^c|([^|]+)|(%x+)|(%d*)$")
        if Name then
            Name = CleanName(Net.Dec(Name))
            local Low = Name:lower()
            if #Name >= 3 and not C.Clans[Low] then
                Cur = { Name = Name, Leader = Leader:lower(), Members = {}, Names = {}, Created = tonumber(Created) or 0 }
                C.Clans[Low] = Cur
                IndexOf(Low)
                N = N + 1
            else
                Cur = nil
            end
        else
            local Gid, MName = Line:match("^m|(%x+)|(.*)$")
            Gid = Lower(Gid)
            if Cur and Gid and not C.Of[Gid] then
                Cur.Members[#Cur.Members + 1] = Gid
                Cur.Names[Gid] = CleanName(Net.Dec(MName))
                C.Of[Gid] = Cur.Name:lower()
            end
        end
    end
    -- leere Clans weg, Leiter muss Mitglied sein
    for Low, Cl in pairs(C.Clans) do
        if #Cl.Members == 0 then
            C.Clans[Low] = nil
            N = N - 1
        elseif C.Of[Cl.Leader] ~= Low then
            Cl.Leader = Cl.Members[1]
        end
    end
    Log("%d Clans aus %s geladen", N, FILE)
end

-- ---------------------------------------------------------------- Spieler online (Host)

-- Doppel-Login (main.lua G.Dup = A.Coop.GuestDup[Controller-Key]): HelloIds/GuestIds tragen dort trotzdem die echte
-- ID des Opfers -> diese Verbindung hat fuer Clans keine Mitspieler-ID
local function IsDup(Key)
    local D = A.Coop and A.Coop.GuestDup
    return Key ~= nil and type(D) == "table" and D[Key] ~= nil
end

local function GidOfKey(Key)
    if not Key or IsDup(Key) then return nil end
    local Coop = A.Coop or {}
    local Gid = (Coop.HelloIds and Coop.HelloIds[Key]) or (Coop.GuestIds and Coop.GuestIds[Key])
        or (Net.Guests[Key] and Net.Guests[Key].GuestId)
    return Lower(Gid)
end

-- Nummerierung wie server.lua PlayerList ("players", Admin-Liste): Reihenfolge der PlayerStates ohne lokalen PC
local function Refresh()
    local World = A.CurrentWorld()
    if not (World and A.IsAlive(World)) then return C.Online end
    local O = { List = {}, ByGid = {}, ByPid = {}, ByKey = {} }
    local States = A.Safe(function() return A.PlayerStates(World) end, {}) or {}
    for _, PS in ipairs(States) do
        local PC = A.IsAlive(PS) and A.Safe(function() return PS:GetOwner() end) or nil
        if PC and A.IsAlive(PC) and A.Safe(function() return not PC:IsLocalController() end, false) then
            local Key = A.Safe(function() return PC:GetFullName() end)
            if Key then
                local E = { N = #O.List + 1, Key = Key, Gid = GidOfKey(Key),
                            Name = CleanName(A.Safe(function() return PS:GetPlayerName():ToString() end, "?")),
                            Pid = A.Safe(function() return math.floor(PS.PlayerId) end) }
                O.List[#O.List + 1] = E
                O.ByKey[Key] = E
                if E.Gid then O.ByGid[E.Gid] = E end
                if E.Pid then O.ByPid[E.Pid] = E end
            end
        end
    end
    C.Online = O
    return O
end

-- ---------------------------------------------------------------- Rueckmeldungen (Host)

local function Note(Key, Text)
    local G = Net.Guests[Key]
    local Ui = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_ui
    if G and Ui and Ui.Note and Net.Has("ui_note2", G) then
        if pcall(Ui.Note, G, Text, "", true) then return end
    end
    local PC = Net.PC(Key)
    if PC then pcall(A.SendChunked, function(T) A.SendToClient(PC, T) end, "note", Text) end
end

-- Systemzeile in den Chat des Spielers; Important (oder Gast ohne clan1) zusaetzlich als Hinweis
local function Tell(Key, Text, Important)
    if not Key then return end
    local G = Net.Guests[Key]
    local Sent = false
    if G and G.Epoch and Net.Has(CAP, G) then Sent = Net.Send("clan_msg", "s||" .. Net.Enc(Text), G, 0) end
    if Important or not Sent then Note(Key, Text) end
end

local function TellGid(Gid, Text, Important)
    local E = Gid and C.Online.ByGid[Gid]
    if E then Tell(E.Key, Text, Important) end
end

local function TellClan(Low, Text, Important, Except)
    local Cl = C.Clans[Low]
    if not Cl then return end
    for _, Gid in ipairs(Cl.Members) do
        if Gid ~= Except then TellGid(Gid, Text, Important) end
    end
end

-- ---------------------------------------------------------------- Zustand an die Gaeste (Host)

local function StateFor(Gid)
    local Low = Gid and C.Of[Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return "" end
    local Parts = {}
    for _, M2 in ipairs(Cl.Members) do
        local E = C.Online.ByGid[M2]
        Parts[#Parts + 1] = string.format("%d:%s", (E and E.Pid) or 0, Esc(Cl.Names[M2] or "?"))
    end
    return Esc(Cl.Name) .. "|" .. Esc(Cl.Names[Cl.Leader] or "?") .. "|" .. table.concat(Parts, ",")
end

local function Push(G)
    if not (G and G.Epoch and Net.Has(CAP, G)) then return end
    local Gid = Lower(G.GuestId) or GidOfKey(G.Key)
    Net.State("clan_st", "s", On() and StateFor(Gid) or "", 1, G)
end

local function PushAll()
    Net.ForEachGuest(function(G) Push(G) end)
end

local function Changed(Reason, ClanName, Info)
    C.Dirty = true
    PushAll()
    Fire(Reason, ClanName, Info)
end

-- Austritt/Kick: Mitglieder VOR Remove sichern (Besitz-Uebergabe in ls_build braucht die alten Claim-Inhaber)
local function LeaveInfo(Cl, Gid)
    local Old = {}
    for _, G2 in ipairs(Cl.Members) do Old[#Old + 1] = G2 end
    return { Gid = Gid, Name = Cl.Name, Old = Old }
end

-- ---------------------------------------------------------------- Clan-Logik (Host)

local function Remove(Gid)
    local Low = C.Of[Gid]
    local Cl = Low and C.Clans[Low]
    C.Of[Gid] = nil
    if not Cl then return nil end
    for I, M2 in ipairs(Cl.Members) do
        if M2 == Gid then table.remove(Cl.Members, I) break end
    end
    if #Cl.Members == 0 then
        C.Clans[Low] = nil
        for G2, Inv in pairs(C.Invites) do if Inv.Clan == Low then C.Invites[G2] = nil end end
        Log("Clan %s aufgeloest", Cl.Name)
        return Cl, "dissolved"
    end
    if Cl.Leader == Gid then
        Cl.Leader = Cl.Members[1]
        return Cl, "leader"
    end
    return Cl, "left"
end

local function FindOnline(Text)
    local O = Refresh()
    if not Text or Text == "" then return nil, "Spieler fehlt (Namensteil oder #Nummer)" end
    local Low, Num = Text:lower(), tonumber(Text:match("^#(%d+)$"))
    for _, E in ipairs(O.List) do
        if (Num and E.N == Num) or (E.Gid and E.Gid == Low) then return E end
    end
    if Num then return nil, "kein Spieler #" .. Num end
    local Hit
    for _, E in ipairs(O.List) do
        if E.Name:lower():find(Low, 1, true) then
            if E.Name:lower() == Low then return E end
            if Hit then return nil, "Name nicht eindeutig: " .. Text end
            Hit = E
        end
    end
    return Hit, Hit and nil or ("kein Spieler '" .. Text .. "' online")
end

-- Mitglied (auch offline) nach Namensteil, ID oder #Nummer
local function FindMember(Cl, Text)
    if not Text or Text == "" then return nil, "Spieler fehlt" end
    local Low = Text:lower()
    if Text:match("^#%d+$") then
        local E, Err = FindOnline(Text)
        if not E then return nil, Err end
        if E.Gid and C.Of[E.Gid] == Cl.Name:lower() then return E.Gid end
        return nil, E.Name .. " ist nicht in deinem Clan"
    end
    local Hit
    for _, Gid in ipairs(Cl.Members) do
        local N = (Cl.Names[Gid] or ""):lower()
        if Gid == Low or N == Low then return Gid end
        if N:find(Low, 1, true) then
            if Hit then return nil, "Name nicht eindeutig: " .. Text end
            Hit = Gid
        end
    end
    return Hit, Hit and nil or ("kein Mitglied '" .. Text .. "'")
end

-- Admin-Pruefung ueber server.lua Srv.IsAdmin; Doppel-Login (zweite Verbindung, kopierte ID-Datei) ist nie Admin
local function IsAdmin(Gid, Key)
    local Srv = A.Coop and A.Coop.Server
    local Dup = A.Coop ~= nil and A.Coop.GuestDup ~= nil and Key ~= nil and A.Coop.GuestDup[Key] ~= nil
    if type(Srv) == "table" and type(Srv.IsAdmin) == "function" then
        -- Key (PC:GetFullName) fuer LASTSIGNAL_ADMIN_PASSWORD (AdminAuth je Verbindung) und steam:<id> (SteamIds[Key])
        return Srv.IsAdmin({ GuestId = Gid and tostring(Gid):lower(), Dup = Dup, Key = Key }) == true
    end
    return Gid ~= nil and not Dup and type(Srv) == "table" and type(Srv.Admins) == "table" and Srv.Admins[Gid] == true
end

local HELP = "/clan create <Name> | invite <Spieler> | accept | decline | leave | kick <Spieler> | leader <Spieler> | info"
    .. " | disband <Name> | /c <Text>"

local Cmd = {}

function Cmd.create(E, Arg)
    if C.Of[E.Gid] then return Tell(E.Key, "Du bist schon in Clan " .. C.Clans[C.Of[E.Gid]].Name .. " (erst /clan leave)") end
    local Name = CleanName(Arg):gsub("%s+", " ")
    if #Name < 3 or #Name > 24 or not Name:match("^[%w][%w _%-%.]*$") then
        return Tell(E.Key, "Clan-Name: 3-24 Zeichen, nur Buchstaben, Ziffern, Leerzeichen, _ - .")
    end
    local Low = Name:lower()
    if C.Clans[Low] then return Tell(E.Key, "Clan " .. Name .. " gibt es schon") end
    C.Clans[Low] = { Name = Name, Leader = E.Gid, Members = { E.Gid }, Names = { [E.Gid] = E.Name }, Created = os.time() }
    C.Of[E.Gid] = Low
    C.Invites[E.Gid] = nil
    IndexOf(Low)
    Log("%s gruendet Clan %s", E.Name, Name)
    Tell(E.Key, "Clan " .. Name .. " gegruendet. Einladen: /clan invite <Spieler>", true)
    Changed("create", Name)
end

function Cmd.invite(E, Arg)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan (/clan create <Name>)") end
    if Cl.Leader ~= E.Gid then return Tell(E.Key, "Nur der Clan-Leiter kann einladen") end
    local T, Err = FindOnline(Arg)
    if not T then return Tell(E.Key, Err) end
    if not T.Gid then return Tell(E.Key, T.Name .. " hat noch keine Mitspieler-ID, gleich nochmal") end
    if T.Gid == E.Gid then return Tell(E.Key, "Dich selbst einladen geht nicht") end
    if C.Of[T.Gid] then return Tell(E.Key, T.Name .. " ist schon in einem Clan") end
    if #Cl.Members >= Core.Flag("clan_max", 8) then return Tell(E.Key, "Clan ist voll") end
    C.Invites[T.Gid] = { Clan = Low, By = E.Gid, At = os.time() }
    Log("%s laedt %s in Clan %s ein", E.Name, T.Name, Cl.Name)
    Tell(E.Key, "Einladung an " .. T.Name .. " geschickt (5 min gueltig)")
    Tell(T.Key, E.Name .. " laedt dich in Clan " .. Cl.Name .. " ein: /clan accept oder /clan decline", true)
end

function Cmd.accept(E)
    local Inv = C.Invites[E.Gid]
    if not Inv or os.time() - Inv.At > INVITE_SECONDS then
        C.Invites[E.Gid] = nil
        return Tell(E.Key, "Keine offene Clan-Einladung")
    end
    C.Invites[E.Gid] = nil
    local Cl = C.Clans[Inv.Clan]
    if not Cl then return Tell(E.Key, "Den Clan gibt es nicht mehr") end
    if C.Of[E.Gid] then return Tell(E.Key, "Du bist schon in einem Clan (erst /clan leave)") end
    if #Cl.Members >= Core.Flag("clan_max", 8) then return Tell(E.Key, "Clan " .. Cl.Name .. " ist voll") end
    Cl.Members[#Cl.Members + 1] = E.Gid
    Cl.Names[E.Gid] = E.Name
    C.Of[E.Gid] = Inv.Clan
    Log("%s tritt Clan %s bei", E.Name, Cl.Name)
    TellClan(Inv.Clan, E.Name .. " ist jetzt in Clan " .. Cl.Name, true)
    Changed("join", Cl.Name)
end

function Cmd.decline(E)
    local Inv = C.Invites[E.Gid]
    if not Inv then return Tell(E.Key, "Keine offene Clan-Einladung") end
    C.Invites[E.Gid] = nil
    local Cl = C.Clans[Inv.Clan]
    Tell(E.Key, "Einladung abgelehnt")
    if Cl then TellGid(Inv.By, E.Name .. " hat die Einladung in Clan " .. Cl.Name .. " abgelehnt", true) end
end

function Cmd.leave(E)
    local Low0 = C.Of[E.Gid]
    local Info = Low0 and C.Clans[Low0] and LeaveInfo(C.Clans[Low0], E.Gid) or nil
    local Cl, What = Remove(E.Gid)
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan") end
    if Info and What ~= "dissolved" then Info.Leader = Cl.Leader end
    Log("%s verlaesst Clan %s (%s)", E.Name, Cl.Name, What)
    Tell(E.Key, "Du hast Clan " .. Cl.Name .. " verlassen", true)
    local Low = Cl.Name:lower()
    if What == "leader" then
        TellClan(Low, E.Name .. " hat den Clan verlassen. Neuer Leiter: " .. (Cl.Names[Cl.Leader] or "?"), true)
    elseif What == "left" then
        TellClan(Low, E.Name .. " hat den Clan verlassen", true)
    end
    Changed(What == "dissolved" and "dissolve" or "leave", Cl.Name, Info)
end

function Cmd.kick(E, Arg)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan") end
    if Cl.Leader ~= E.Gid then return Tell(E.Key, "Nur der Clan-Leiter kann entfernen") end
    local Gid, Err = FindMember(Cl, Arg)
    if not Gid then return Tell(E.Key, Err) end
    if Gid == E.Gid then return Tell(E.Key, "Dich selbst: /clan leave") end
    local Name = Cl.Names[Gid] or "?"
    local Info = LeaveInfo(Cl, Gid)
    Remove(Gid)
    Info.Leader = Cl.Leader
    Log("%s entfernt %s aus Clan %s", E.Name, Name, Cl.Name)
    TellGid(Gid, "Du wurdest aus Clan " .. Cl.Name .. " entfernt", true)
    TellClan(Low, Name .. " wurde aus dem Clan entfernt", true)
    Changed("kick", Cl.Name, Info)
end

function Cmd.leader(E, Arg)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan") end
    if Cl.Leader ~= E.Gid then return Tell(E.Key, "Nur der Clan-Leiter kann das") end
    local Gid, Err = FindMember(Cl, Arg)
    if not Gid then return Tell(E.Key, Err) end
    if Gid == E.Gid then return Tell(E.Key, "Du bist schon Leiter") end
    Cl.Leader = Gid
    Log("Clan %s: neuer Leiter %s (von %s)", Cl.Name, Cl.Names[Gid] or "?", E.Name)
    TellClan(Low, "Neuer Clan-Leiter: " .. (Cl.Names[Gid] or "?"), true)
    Changed("leader", Cl.Name)
end

function Cmd.info(E)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then
        local Inv = C.Invites[E.Gid]
        local Extra = (Inv and C.Clans[Inv.Clan]) and (" Offene Einladung: " .. C.Clans[Inv.Clan].Name .. " (/clan accept)") or ""
        return Tell(E.Key, "Kein Clan. " .. HELP .. Extra)
    end
    local Parts = {}
    for _, Gid in ipairs(Cl.Members) do
        Parts[#Parts + 1] = (Cl.Names[Gid] or "?") .. (Gid == Cl.Leader and " (Leiter)" or "")
            .. (C.Online.ByGid[Gid] and " [on]" or "")
    end
    Tell(E.Key, string.format("Clan %s (%d/%d): %s", Cl.Name, #Cl.Members, Core.Flag("clan_max", 8), table.concat(Parts, ", ")))
end

function Cmd.list(E)
    if not IsAdmin(E.Gid, E.Key) then return Tell(E.Key, "Nur fuer Admins") end
    local Parts = {}
    for _, Cl in pairs(C.Clans) do
        Parts[#Parts + 1] = string.format("%s (%d, Leiter %s)", Cl.Name, #Cl.Members, Cl.Names[Cl.Leader] or "?")
    end
    table.sort(Parts)
    Tell(E.Key, #Parts == 0 and "Keine Clans" or ("Clans: " .. table.concat(Parts, "; ")))
end

function Cmd.help(E) Tell(E.Key, HELP) end

-- PLAYER-24 (clan_disband): der Leiter loest den Clan auf. Bestaetigung mit dem Clan-Namen (kein Versehen). Jedes Mitglied
-- wird wie bei leave entfernt; OnChange je Mitglied mit Info ohne Leader (= aufgeloest: ls_build uebergibt nichts, jeder
-- behaelt seine Bauten)
local function Disband(E, Arg)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan") end
    if Cl.Leader ~= E.Gid then return Tell(E.Key, "Nur der Clan-Leiter kann den Clan aufloesen") end
    local Want = (CleanName(Arg):gsub("%s+", " ")):lower()
    if Want ~= Low then return Tell(E.Key, "Clan wirklich aufloesen? Bestaetigen mit: /clan disband " .. Cl.Name) end
    local Old = {}
    for _, G2 in ipairs(Cl.Members) do Old[#Old + 1] = G2 end
    TellClan(Low, "Clan " .. Cl.Name .. " wurde von " .. E.Name .. " aufgeloest", true)
    for _, G2 in ipairs(Old) do Remove(G2) end
    Log("%s loest Clan %s auf (%d Mitglieder)", E.Name, Cl.Name, #Old)
    for _, G2 in ipairs(Old) do
        Changed("dissolve", Cl.Name, { Gid = G2, Name = Cl.Name, Old = Old })
    end
end

function Cmd.disband(E, Arg)
    if Core.Flag("clan_disband", true) ~= true then return Tell(E.Key, "Clan aufloesen ist auf diesem Server aus") end
    local ok, err = pcall(Disband, E, Arg)
    if not ok then
        if Core.Fail("clan_disband", err) then Log("clan_disband aus: %s", tostring(err)) end
        Tell(E.Key, "Clan aufloesen fehlgeschlagen")
    end
end

-- Clan-Chat an alle Mitglieder online (auch zurueck an den Absender)
local function ClanChat(E, Text)
    local Low = C.Of[E.Gid]
    local Cl = Low and C.Clans[Low]
    if not Cl then return Tell(E.Key, "Du bist in keinem Clan") end
    Text = CutText(Text)
    if Text == "" then return Tell(E.Key, "/c <Text> schreibt an deinen Clan") end
    Log("[Clan %s] %s: %s", Cl.Name, E.Name, Text)
    local Data = "c|" .. Net.Enc(E.Name) .. "|" .. Net.Enc(Text)
    for _, Gid in ipairs(Cl.Members) do
        local O = C.Online.ByGid[Gid]
        local G = O and Net.Guests[O.Key]
        if G and G.Epoch and Net.Has(CAP, G) then
            Net.Send("clan_msg", Data, G, 1)
        elseif O then
            Note(O.Key, "[Clan] " .. E.Name .. ": " .. Text)
        end
    end
end

local function RunOne(J)
    if IsDup(J.Key) then return Tell(J.Key, "Doppel-Login: keine Clan-Befehle") end
    local O = Refresh()
    local E = O.ByKey[J.Key] or { Key = J.Key, Gid = J.Gid, Name = J.Name, N = 0 }
    E.Gid = E.Gid or J.Gid
    if not On() then return Tell(E.Key, "Clans sind auf diesem Server aus") end
    if not E.Gid then return Tell(E.Key, "Noch keine Mitspieler-ID, gleich nochmal versuchen") end
    -- Name im Clan aktuell halten
    local Low = C.Of[E.Gid]
    if Low and C.Clans[Low] and C.Clans[Low].Names[E.Gid] ~= E.Name and E.Name ~= "?" then
        C.Clans[Low].Names[E.Gid] = E.Name
        C.Dirty = true
    end
    if J.Cmd == "c" then return ClanChat(E, J.Arg) end
    local Sub, Arg = (J.Arg or ""):match("^(%S*)%s*(.-)$")
    Sub = (Sub or ""):lower()
    local Fn = Cmd[Sub ~= "" and Sub or "info"]
    if not Fn then return Tell(E.Key, "Unbekannt: /clan " .. Sub .. ". " .. HELP) end
    Fn(E, Arg)
end

local function CmdTask()
    if Net.Side ~= "host" then C.Queue = {} return end
    if #C.Queue == 0 then
        if C.Dirty and os.clock() >= (C.SaveAt or 0) then C.SaveAt = os.clock() + 2 Save() end
        return
    end
    Load()
    local Queue = C.Queue
    C.Queue = {}
    for _, J in ipairs(Queue) do
        local ok, err = pcall(RunOne, J)
        if not ok then
            Log("Befehl /%s %s fehlgeschlagen: %s", J.Cmd, tostring(J.Arg), tostring(err))
            Core.Fail(FLAG, err)
            pcall(Tell, J.Key, "Clan-Befehl fehlgeschlagen")
        end
    end
end

-- ---------------------------------------------------------------- Export Host

-- Chat-Text eines Spielers (server.lua Srv.Chat, vor ChatAll). G: server.lua-Eintrag oder Net-Gast (Key, GuestId,
-- Name). true = Clan-Befehl, nicht verteilen. Nur vormerken: ausgefuehrt im Task clan_cmd (Spiel-Thread).
function M.Chat(G, Text)
    if type(Text) ~= "string" or type(G) ~= "table" then return false end
    local Word, Rest = Text:match("^%s*/(%a+)(.*)$")
    Word = Word and Word:lower()
    if Word ~= "clan" and Word ~= "c" then return false end
    if Rest ~= "" and not Rest:match("^%s") then return false end
    local Key = G.Key
    if not Key and G.PC and A.IsAlive(G.PC) then Key = A.Safe(function() return G.PC:GetFullName() end) end
    if not Key then return true end
    local Now = os.clock()
    if Now - (C.CmdAt[Key] or -10) < 0.5 or #C.Queue >= 50 then return true end
    C.CmdAt[Key] = Now
    local Gid = not IsDup(Key) and (Lower(G.GuestId) or GidOfKey(Key)) or nil
    C.Queue[#C.Queue + 1] = { Key = Key, Gid = Gid, Name = CleanName(G.Name or "?"),
                              Cmd = Word, Arg = Rest:match("^%s*(.-)%s*$") }
    return true
end

function M.ClanOf(Gid)
    Gid = Lower(Gid)
    if not Gid or not On() then return nil end
    Load()
    local Low = C.Of[Gid]
    return Low and C.Clans[Low] and C.Clans[Low].Name or nil
end

function M.Allied(GidA, GidB)
    GidA, GidB = Lower(GidA), Lower(GidB)
    if not GidA or not GidB then return false end
    if GidA == GidB then return true end
    if not On() then return false end
    Load()
    local La = C.Of[GidA]
    return La ~= nil and La == C.Of[GidB]
end

function M.Index(Gid)
    Gid = Lower(Gid)
    if not Gid or not On() then return 0 end
    Load()
    local Low = C.Of[Gid]
    if not (Low and C.Clans[Low]) then return 0 end
    return IndexOf(Low)
end

-- Gast-ID zu Net-Gast/server.lua-Eintrag, Key-String, Gast-ID, PC, Pawn oder PlayerState (billig: Cache 1 Hz)
function M.GuestIdOf(X)
    local T = type(X)
    if T == "table" then
        if IsDup(X.Key) then return nil end
        return Lower(X.GuestId) or GidOfKey(X.Key)
    end
    if T == "string" then
        if X:match("^%x+$") and #X >= 8 then return X:lower() end
        return GidOfKey(X)
    end
    if T ~= "userdata" or not A.IsAlive(X) then return nil end
    local Pid
    local PS = A.Safe(function() return X.PlayerState end)
    if PS and A.IsAlive(PS) then
        Pid = A.Safe(function() return math.floor(PS.PlayerId) end)
    else
        Pid = A.Safe(function() local V = X.PlayerId return type(V) == "number" and math.floor(V) or nil end)
    end
    local E = Pid and C.Online.ByPid[Pid]
    if E and E.Gid then return E.Gid end
    local Key = A.Safe(function() return X:GetFullName() end)
    local Gid = Key and GidOfKey(Key)
    if Gid then return Gid end
    local Name = A.Safe(function() return X:GetFName():ToString() end)
    local G = Name and Net.GuestByPawnName(Name)
    return G and (Lower(G.GuestId) or GidOfKey(G.Key)) or nil
end

-- E29 (PLAYER-24): offene Aenderungen sofort schreiben (server.lua stop, Shutdown); sonst erst im clan_cmd-Takt (2 s).
-- true = nichts offen bzw. geschrieben
function M.Flush()
    if not C.Dirty then return true end
    Save()
    if not C.Dirty then Log("%s sofort geschrieben (Flush)", FILE) end
    return not C.Dirty
end

function M.OnChange(Fn)
    if type(Fn) ~= "function" then return end
    for _, F in ipairs(C.Listeners) do if F == Fn then return end end
    C.Listeners[#C.Listeners + 1] = Fn
end

-- Mitglieder-IDs eines Clans (per Name oder Gast-ID eines Mitglieds)
function M.Members(X)
    Load()
    local Low = Lower(X)
    local Cl = Low and (C.Clans[Low] or (C.Of[Low] and C.Clans[C.Of[Low]]))
    local Out = {}
    if Cl then for _, Gid in ipairs(Cl.Members) do Out[#Out + 1] = Gid end end
    return Out
end

-- Host: {[Pawn] = ClanIndex} fuer Native.SetAllies (nur Spieler mit Clan, Figuren frisch geholt; Spiel-Thread)
function M.AllyMap()
    local Map = {}
    if Net.Side ~= "host" or not On() then return Map end
    Load()
    for _, E in ipairs(C.Online.List) do
        local I = E.Gid and M.Index(E.Gid) or 0
        if I > 0 then
            local PC = Net.PC(E.Key)
            local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
            if Pawn and A.IsAlive(Pawn) then Map[Pawn] = I end
        end
    end
    return Map
end

-- ---------------------------------------------------------------- Gast

function M.My() return C.Mine end

function M.IsMatePid(Pid)
    Pid = tonumber(Pid)
    return Pid ~= nil and C.Mine ~= nil and C.Mine.Members[math.floor(Pid)] ~= nil
end

local function GuestNote(Text)
    local Ui = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_ui
    if Ui and Ui.Note and pcall(Ui.Note, nil, Text, "", false) then return end
    if A.ShowNote then pcall(A.ShowNote, Text) end
end

-- Zeile in den vorhandenen Chat (main.lua Coop.Chat.History), sonst als Hinweis
local function ChatLine(Name, Text)
    local Ch = A.Coop and A.Coop.Chat
    if type(Ch) ~= "table" or type(Ch.History) ~= "table" then return GuestNote(Name .. ": " .. Text) end
    Ch.Count = (Ch.Count or 0) + 1
    Ch.History[#Ch.History + 1] = { Id = Ch.Count, Name = Name, Msg = Text, Admin = false, At = os.time() }
    while #Ch.History > 50 do table.remove(Ch.History, 1) end
    if Ch.Setup and A.Safe(Ch.Setup, false) and Ch.Render then pcall(Ch.Render) end
end

local function ParseState(Value)
    if not Value or Value == "" then return nil end
    local N, L, Ms = Value:match("^([^|]*)|([^|]*)|(.*)$")
    if not N then return nil end
    local Mine = { Name = Net.Dec(N), Leader = Net.Dec(L), Members = {}, Offline = {} }
    for Pid, Name in Ms:gmatch("(%-?%d+):([^,]*)") do
        Pid, Name = tonumber(Pid), Net.Dec(Name)
        if Pid and Pid ~= 0 then Mine.Members[Pid] = Name else Mine.Offline[#Mine.Offline + 1] = Name end
    end
    return Mine
end

-- ---------------------------------------------------------------- Netz

M.ShowsMsg = true   -- ls_ui F.OnClanMsg ueberspringt clan_msg (sonst doppelt und falsch geparst)

M.Handlers = {
    clan_st = function(Value, _, Msg)
        if Net.Side ~= "client" or (Msg and Msg.Key ~= "s") then return end
        if Value == C.MineRaw then return end
        local Old = C.Mine and C.Mine.Name
        C.MineRaw = Value
        C.Mine = ParseState(Value)
        local New = C.Mine and C.Mine.Name
        if Old ~= New then Log("eigener Clan: %s", tostring(New or "-")) end
        Fire("state", New)
    end,
    clan_msg = function(Data)
        if Net.Side ~= "client" or type(Data) ~= "string" then return end
        local T, Name, Text = Data:match("^([cs])|([^|]*)|(.*)$")
        if not T then return end
        Text = Net.Dec(Text)
        if Text == "" or #Text > 1200 then return end
        if T == "c" then ChatLine("[Clan] " .. Net.Dec(Name), Text) else ChatLine("[Clan]", Text) end
    end,
}

-- ---------------------------------------------------------------- Ticks

function M.HostTick()
    if Net.Side ~= "host" then return end
    Load()
    Refresh()
    local Now = os.time()
    for Gid, Inv in pairs(C.Invites) do
        if Now - Inv.At > INVITE_SECONDS then
            C.Invites[Gid] = nil
            local Cl = C.Clans[Inv.Clan]
            if Cl then TellGid(Gid, "Einladung in Clan " .. Cl.Name .. " abgelaufen") end
        end
    end
    -- Namen aktuell halten (Mitglieder online)
    for _, E in ipairs(C.Online.List) do
        local Low = E.Gid and C.Of[E.Gid]
        local Cl = Low and C.Clans[Low]
        if Cl and E.Name ~= "?" and Cl.Names[E.Gid] ~= E.Name then Cl.Names[E.Gid] = E.Name C.Dirty = true end
    end
    -- PlayerIds/Online-Stand an alle (Net.State schickt nur Aenderungen)
    PushAll()
    -- CORE-30: Befehls-Zeitstempel alter Verbindungen (auch ohne "gone", z. B. nur server.lua-Eintrag)
    local Clock = os.clock()
    for Key, At in pairs(C.CmdAt) do
        if Clock - At > 60 then C.CmdAt[Key] = nil end
    end
end

function M.ClientTick() end

function M.Init(Api)
    A = Api
    Net.Cap(CAP, On())
    if A.Coop then A.Coop.Clan = M end
    Core.Every("clan_cmd", 0.1, CmdTask)
    Net.OnEvent("ready", function(Peer)
        if Net.Side ~= "host" or type(Peer) ~= "table" then return end
        Load()
        Refresh()
        Push(Peer)
        local Gid = Lower(Peer.GuestId) or GidOfKey(Peer.Key)
        local Inv = Gid and C.Invites[Gid]
        if Inv and C.Clans[Inv.Clan] then
            Tell(Peer.Key, "Offene Einladung in Clan " .. C.Clans[Inv.Clan].Name .. ": /clan accept oder /clan decline", true)
        end
    end)
    Net.OnEvent("gone", function(Peer)
        if Net.Side == "client" or Peer == Net.Host then
            if C.Mine then C.Mine, C.MineRaw = nil, nil Fire("state", nil) end
        elseif type(Peer) == "table" and Peer.Key then
            C.CmdAt[Peer.Key] = nil
        end
    end)
    if A.TestCommands then
        A.TestCommands.clan_dump = function()
            Load()
            for _, Cl in pairs(C.Clans) do
                A.TestLog("clan %s idx=%d leader=%s members=%d", Cl.Name, IndexOf(Cl.Name:lower()), Cl.Leader, #Cl.Members)
            end
            A.TestLog("clan: side=%s mine=%s invites=%d", tostring(Net.Side), tostring(C.Mine and C.Mine.Name),
                (function() local N = 0 for _ in pairs(C.Invites) do N = N + 1 end return N end)())
        end
        -- "clan_as #<Nr> <Chattext>": Befehl im Namen eines Spielers (nur Host, Test)
        A.TestCommands.clan_as = function(Arg)
            local Nr, Text = tostring(Arg or ""):match("^(#%d+)%s+(.+)$")
            local E = Nr and FindOnline(Nr)
            if not E then A.TestLog("clan_as: Spieler fehlt") return end
            A.TestLog("clan_as %s: %s -> %s", E.Name, Text, tostring(M.Chat(E, Text)))
        end
    end
end

return M
