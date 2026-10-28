-- Last Signal, Runde 5: Spieler und Sitzung (ls_player). Befunde: _NetTest\analysis\findings\player.md
--   respawn_v2       Respawn mit Ladebildschirm, ohne Vollsync (setzt inv_v2a voraus), Rueckfall bei verlorenem RPC
--   death_guard      Todesbildschirm bleibt offen, ScreenPermadeath loescht nie den eigenen Spielstand,
--                    SaveMenu im Todesbildschirm = freiwilliges Verlassen
--   save_lock        Gast: AllowSaving? immer aus, Speichern im SaveMenu ausgeblendet
--   guest_backup     Gast: eigener SP-Slot einmal pro Verbindung gesichert (DLL-Dienst "backup")
--   bed_v2           Bett/Schlafsack-Spawnpunkt je Gast (gespeichert, beim Gast gespiegelt)
--   session_v2       gleiche Gast-ID: neue Verbindung gewinnt gegen eine tote, doppelte lebende wird abgelehnt
--   shutdown_v2      Server-Ende: alle Gaeste sofort speichern, "bye" (Srv.Commands.stop, Testbefehl shutdown)
--   player_cmds      Chat /suicide und /unstuck (Host fuehrt aus); /carlock geht an ls_car (E20, Schalter car_lock)
--   player_newquest  neuer Gast (kein Server-Spielstand): Hinweis pl_new (Startquest startet der Host in ls_world quest_start)
-- UE 5.6 geprueft (analysis56): Respawn-RPCs/Survival_Respawn, ScreenPermadeath.Construct + DeleteSave?, RespawnScreen,
--   Client_Died unveraendert im Verhalten; Schlafsack-Hook auf BedComponent_C.SetSpawnPoint umgestellt
-- Netz (Cap "pl2"): pl_req pl_rready pl_cmd pl_bag (Gast->Host), pl_resp pl_bye pl_new pl_spawnpt (Host->Gast)
--   Cap "pl_rsp" nur bei respawn_v2 (pl2 steht auch fuer player_cmds/bed_v2/...): Respawn-Weg je Gast
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local Native = require("ls_native")
local A   -- Coop.API

local P = {
    CAP = "pl2",
    RSP_CAP = "pl_rsp",
    H = {},                                    -- Host: [PC-Key] = Zustand je Gast (Figur, Tod, Respawn, Bett)
    C = {},                                    -- Gast: eigener Zustand (Tod, Bildschirm, Laden)
    S = { First = {}, Done = {}, Rejected = {} },   -- Host: Sitzung (gleiche Gast-ID)
    Cmd = {},                                  -- Host: [PC-Key] = { suicide = t, unstuck = t } (Sperrzeiten)
    New = {},                                  -- Host: [PC-Key] = "1" neu / "2" nach dem Tod (pl_new offen) / false
    Gen = -1,
    PermaHits = 0,
    REQ_FALLBACK = 2.5, REQ_TRIES = 2, HOLD_MAX = 30, RESEND = 2, ORPHAN_AGE = 15, LOAD_MAX = 25,
    TARGET_DIST = 1000,   -- pl_resp: eigene neue Figur liegt hoechstens so weit (uu) von der Host-Position

    QUIET = 3, KICK_HARD = 10, GHOST_NEAR = 400, GHOST_WINDOW = 10,
    -- unstuck_safe: Linie ab Kapselmitte + UNSTUCK_UP; "steckt fest" = < STILL_R uu in STILL_T s oder > FALL_T s im Fall
    UNSTUCK_UP = 60, STILL_R = 50, STILL_T = 5, FALL_T = 3,
    BAG_NEAR = 300, BAG_PAWN = 600, BAG_HOLD = 5,   -- Welt-Schlafsack (pl_bag): Sack-/Figur-Abstand, Gast-Schonfrist
    PATH = {
        Loading = "/Game/UI/Widgets/Other/LoadingScreenWidget.LoadingScreenWidget_C",
        Perma = "/Game/UI/Widgets/Player/ScreenPermadeath.ScreenPermadeath_C",
        PermaCDO = "/Game/UI/Widgets/Player/ScreenPermadeath.Default__ScreenPermadeath_C",
        Bag = "/Game/Blueprints/Other/Objects/BP_SleepingBag.BP_SleepingBag_C",
        -- UE 5.6: SetSpawnPoint liegt im BedComponent (BP_SleepingBag_C.SetSpawnPoint entfernt)
        BedComp = "/Game/Blueprints/Components/BedComponent.BedComponent_C",
        DamageType = "/Script/Engine.DamageType",
        WBL = "/Script/UMG.Default__WidgetBlueprintLibrary",
    },
    SCREENS = { RespawnScreen_C = true, ScreenPermadeath_C = true, QuitWidgetRespawn_C = true },
    CMDS = { suicide = "suicide", kill = "suicide", unstuck = "unstuck", stuck = "unstuck" },
}

local function Log(fmt, ...) A.Log("[Player] " .. fmt, ...) end
local function Flag(Name) return Core.Flag(Name, true) end

-- ---------------------------------------------------------------- Hilfen

-- respawn_v2 nur zusammen mit inv_v2a (sonst Vollsync bei jeder neuen Figur, R5_KRITIK)
function P.RespawnOn() return Flag("respawn_v2") and Core.Flag("inv_v2a", true) end

-- Pfad ohne Klassennamen (fuer StaticFindObject), nie das Objekt selbst merken
function P.PathOf(Obj)
    local Full = A.Safe(function() return Obj:GetFullName() end)
    return Full and Full:match("^%S+%s+(.+)$") or nil
end

function P.Find(Path)
    if not Path then return nil end
    local Obj = A.Safe(function() return StaticFindObject(Path) end)
    if Obj and A.IsAlive(Obj) then return Obj end
    return nil
end

function P.NameOf(Obj)
    return A.Safe(function() return Obj:GetFName():ToString() end)
end

-- CORE-31: gemeinsame, kurz gemerkte Suche (main.lua Coop.Scan, E30; ls_ui sucht RespawnScreen_C im selben Takt),
-- sonst FindAllOf. Liste nie veraendern, Eintraege erst bei der Benutzung pruefen.
function P.Scan(Class)
    local S = A.Coop.Scan
    if type(S) == "function" then
        local ok, L = pcall(S, Class, 0.25)
        if ok and type(L) == "table" then return L end
    end
    return A.Safe(function() return FindAllOf(Class) end, nil) or {}
end

-- Erstes sichtbares Widget einer Klasse (Suche: hoechstens 1 Hz je Klasse aufrufen)
function P.Visible(ClassName)
    for _, W in ipairs(P.Scan(ClassName)) do
        if A.IsAlive(W) and A.Safe(function() return W:IsInViewport() end, false) then return W end
    end
    return nil
end

-- Gemerktes Widget frisch nachschlagen, nur wenn es noch im Bild ist
function P.Up(Path)
    local W = P.Find(Path)
    if W and A.Safe(function() return W:IsInViewport() end, false) then return W end
    return nil
end

function P.IsDead(Pawn)
    return A.Safe(function() return Pawn["PlayerDead?"] == true end, false)
end

function P.GuestIdOf(Key)
    local G = Net.Guests[Key]
    local Id = (G and G.GuestId) or A.Coop.HelloIds and A.Coop.HelloIds[Key] or A.Coop.GuestIds and A.Coop.GuestIds[Key]
    if type(Id) == "string" and Id:match("^%x+$") then return Id end
    return nil
end

-- Doppel-Login (main.lua G.Dup, Coop.GuestDup[Controller-Key] gesetzt): fuer diese Verbindung nichts laden/speichern
function P.Dup(Key)
    local D = A.Coop.GuestDup
    return Key ~= nil and type(D) == "table" and D[Key] ~= nil
end

function P.HOf(Key)
    local H = P.H[Key]
    if not H then H = { RespPawns = {} } P.H[Key] = H end
    return H
end

function P.GuestDir()
    return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\"
end

function P.Note(Text)
    pcall(A.ShowNote, Text)
end

-- Legacy-Hinweis an einen Gast (alte Gegenstellen ohne pl2)
function P.LegacyNote(PC, Text)
    pcall(function() A.SendChunked(function(T) A.SendToClient(PC, T) end, "note", Text) end)
end

-- Weltwechsel: alles Objektbezogene vergessen
function P.CheckGen()
    local N = A.WorldGen and A.WorldGen.N or 0
    if N == P.Gen then return end
    P.Gen = N
    P.H, P.New, P.Cmd = {}, {}, {}
    P.S = { First = {}, Done = {}, Rejected = {} }
    P.GhostPath, P.LastReqKey = nil, nil
    P.C.ScreenPath, P.C.LoadPath, P.C.PermaPath = nil, nil, nil
end

-- ================================================================ Host: Respawn

function P.HostFast(Now)
    if Net.Side ~= "host" then return end
    P.CheckGen()
    local PCs = Net.ScanPCs()
    P.Prune(PCs)
    -- unstuck_safe: Lage-Verlauf je Gast fuer die "steckt fest"-Pruefung von /unstuck
    if Flag("unstuck_safe") and Flag("player_cmds") then
        for Key, PC in pairs(PCs) do
            local ok, err = pcall(P.TrackStill, Key, PC, Now)
            if not ok and Core.Fail("unstuck_safe", err) then break end
        end
    end
    if not P.RespawnOn() then return end
    for Key, PC in pairs(PCs) do
        local ok, err = pcall(P.HostStep, Key, PC, Now)
        if not ok and Core.Fail("respawn_v2", err) then return end
    end
    if A.Coop.Server then
        local ok, err = pcall(P.GhostCheck, Now)
        if not ok then Core.Fail("respawn_ghost", err) end
    end
end

-- CORE-30: Tabellen je Verbindung (P.H, P.New, P.Cmd) ohne Controller leeren. Stand vorher hinter dem fruehen return
-- (respawn_v2 aus) bzw. nach einem abgebrochenen Durchlauf. Leere Liste ohne Welt (kurzer Weltverlust) nie werten.
function P.Prune(PCs)
    if next(PCs) == nil and not A.IsAlive(A.Safe(A.CurrentWorld)) then return end
    for _, T in ipairs({ P.H, P.New, P.Cmd }) do
        for Key in pairs(T) do
            if not PCs[Key] then T[Key] = nil end
        end
    end
end

-- unstuck_safe (0,2 s, Host): Anker, solange die Figur innerhalb STILL_R bleibt (H.StillAt = seit wann), Fallbeginn
function P.TrackStill(Key, PC, Now)
    local H = P.HOf(Key)
    local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
    local L = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    if not L then H.Still, H.FallAt = nil, nil return end
    local Addr = A.Safe(function() return Pawn:GetAddress() end)
    local S = H.Still
    if not S or S.Addr ~= Addr or (L.X - S.X) ^ 2 + (L.Y - S.Y) ^ 2 + (L.Z - S.Z) ^ 2 > P.STILL_R * P.STILL_R then
        H.Still = { X = L.X, Y = L.Y, Z = L.Z, At = Now, Addr = Addr }
    end
    local Mode = A.Safe(function()
        local Move = Pawn.CharacterMovement
        return A.IsAlive(Move) and Move.MovementMode or nil
    end)
    if Mode == 3 then H.FallAt = H.FallAt or Now else H.FallAt = nil end   -- 3 = MOVE_Falling
end

-- Steckt die Figur wirklich fest? (weniger als STILL_R uu in STILL_T s bewegt, oder faellt laenger als FALL_T s)
function P.IsStuck(Key, Now)
    local H = P.H[Key]
    if not (H and H.Still) then return false end
    if Now - H.Still.At >= P.STILL_T then return true end
    return H.FallAt ~= nil and Now - H.FallAt >= P.FALL_T
end

-- E14 (ls_build): liegt die Stelle in einem fremden (nicht verbuendeten) Claim? Ohne ls_build/claim_on: nein.
function P.ForeignClaim(Key, T)
    local B, Gid = A.Coop.Build, P.GuestIdOf(Key)
    if not (Gid and type(B) == "table" and type(B.ForeignClaimAt) == "function") then return false end
    local ok, Foreign = pcall(B.ForeignClaimAt, Gid, T.X, T.Y)
    return ok and Foreign == true
end

function P.HostStep(Key, PC, Now)
    local H = P.HOf(Key)
    local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) then Pawn = nil end
    local Name = Pawn and P.NameOf(Pawn) or nil
    local Dead = Pawn ~= nil and P.IsDead(Pawn)
    if Name ~= H.Pawn then
        if not Name then
            if H.Pawn and not H.Dead then H.Dead, H.DeadAt = true, Now end
            H.Pawn, H.Path = nil, nil
        else
            local Old, OldPath, WasDead = H.Pawn, H.Path, H.Dead
            H.Pawn, H.Path = Name, P.PathOf(Pawn)
            if (Old or WasDead) and not Dead then P.OnRespawn(Key, Pawn, Name, H, Old, OldPath, Now) end
            H.Dead = Dead
        end
    end
    if Dead and not H.Dead then
        H.Dead, H.DeadAt = true, Now
        Log("Mitspieler-Figur %s tot, warte auf Respawn-Wunsch", tostring(Name))
    end
    if H.Dead and H.ReqAt and Now - H.ReqAt >= P.REQ_FALLBACK then P.Fallback(Key, PC, H, Now) end
    if H.Resp then P.HoldStep(Key, Pawn, Name, H, Now) end
end

-- Gast hat geklickt, aber nach REQ_FALLBACK s keine Figur: Spiel-RPC selbst auf dem Host ausfuehren.
-- Svr_RequestRespawn_SpawnPoint ist nicht reliable, darum mit Bett zuerst dieser Weg.
function P.Fallback(Key, PC, H, Now)
    if (H.ReqN or 0) >= P.REQ_TRIES then
        H.ReqAt = nil
        Log("Respawn fuer %s: nach %d Versuchen keine Figur", Key, P.REQ_TRIES)
        return
    end
    H.ReqN, H.ReqAt = (H.ReqN or 0) + 1, Now
    P.LastReqKey, P.LastReqAt = Key, Now
    local Point = A.Safe(function() return PC.RespawnPointEnabled == true end, false)
    local ok, err = pcall(function()
        if Point then PC:Svr_RequestRespawn_SpawnPoint() else PC:Svr_RequestRespawn_Random() end
    end)
    Log("Respawn-Rueckfall %d fuer %s (%s): %s", H.ReqN, Key, Point and "Spawnpunkt" or "zufaellig",
        ok and "angestossen" or tostring(err))
end

function P.OnRespawn(Key, Pawn, Name, H, OldName, OldPath, Now)
    H.Dead, H.ReqAt, H.ReqN = false, nil, 0
    -- Doppel-Respawn (RPC + Rueckfall): die eben erst erzeugte, nun unbesessene Figur entfernen
    local Old = OldPath and P.Find(OldPath) or nil
    if Old and not P.IsDead(Old) then
        local Born = OldName and H.RespPawns[OldName]
        local Ctrl = A.Safe(function() return Old.Controller end)
        if Born and Now - Born < P.ORPHAN_AGE and not A.IsAlive(Ctrl) then
            pcall(function() Old:K2_DestroyActor() end)
            Log("Doppelter Respawn: verwaiste Figur %s entfernt", tostring(OldName))
        else
            Log("Alte Figur %s lebt noch (Selbstmord-Respawn des Spiels?), bleibt stehen", tostring(OldName))
        end
    end
    H.RespPawns = { [Name] = Now }
    local G = Net.Guests[Key]
    local Hold = G ~= nil and Net.Has(P.RSP_CAP, G)
    H.Resp = { Name = Name, At = Now, SendAt = 0, Hold = Hold }
    if Hold and H.EarlyReady and Now - H.EarlyReady < 3 then
        H.Resp.Ready = true
        Log("Respawn: ready von %s kam vor der Figur, wird uebernommen", Key)
    end
    H.EarlyReady = nil
    if Hold then pcall(function() Pawn.bCanBeDamaged = false end) end
    Log("Respawn: %s hat neue Figur %s%s", Key, Name, Hold and " (haelt bis ready)" or "")
end

-- Figur bis pl_rready (Gast: Figur, HUD, Boden geladen) halten und unverwundbar lassen, Lage melden
function P.HoldStep(Key, Pawn, Name, H, Now)
    local R = H.Resp
    if not R.Hold or Name ~= R.Name or not Pawn then H.Resp = nil return end
    if R.Ready or R.Ended or Now - R.At >= P.HOLD_MAX then
        H.Resp = nil
        return P.Release(Pawn, R, R.Ready and "ready" or R.Ended and "eigener Angriff"
            or string.format("Zeitlimit %d s", P.HOLD_MAX), Now)
    end
    if A.Safe(function() return Pawn.bCanBeDamaged end, false) then pcall(function() Pawn.bCanBeDamaged = false end) end
    if Now >= R.SendAt then
        R.SendAt = Now + P.RESEND
        local L = Pawn:K2_GetActorLocation()
        Net.Send("pl_resp", string.format("%s|%.0f|%.0f|%.0f", Net.Enc(Name), L.X, L.Y, L.Z), Key, 0)
    end
end

-- Freigeben wie Coop.Join.Release: Laufen bzw. Fallen; verwundbar macht der Spawn-Schutz von server.lua
function P.Release(Pawn, R, Why, Now)
    local Floor = A.Coop.Ground(Pawn:K2_GetActorLocation(), Pawn, 50)
    local Move = A.Safe(function() return Pawn.CharacterMovement end)
    if A.IsAlive(Move) and A.Safe(function() return Move.MovementMode == 0 end, false) then
        pcall(function() Move:SetMovementMode(Floor and 1 or 3, 0) end)
    end
    local Srv = A.Coop.Server
    if not (Srv and Srv.Protect and Srv.Protect[R.Name]) then pcall(function() Pawn.bCanBeDamaged = true end) end
    Log("Respawn: Figur %s freigegeben (%s) nach %.1f s", R.Name, Why, Now - R.At)
end

-- Dedizierter Host: Hat der Geist (Spieler 0) die neue Figur uebernommen, fehlte die Umleitung. Zurueckgeben.
function P.GhostCheck(Now)
    local Srv = A.Coop.Server
    local GPC = A.LocalPC()
    if not (Srv and Srv.GhostOf and A.IsAlive(GPC)) then return end
    local GP = A.Safe(function() return GPC:K2_GetPawn() end)
    if not A.IsAlive(GP) then return end
    local GN = P.NameOf(GP)
    if GN == Srv.GhostOf then
        if not P.GhostPath then P.GhostPath = P.PathOf(GP) end
        return
    end
    local Key = P.LastReqKey
    if not Key or Now - (P.LastReqAt or -1e9) > P.GHOST_WINDOW then return end
    local PC, H = Net.PC(Key), P.H[Key]
    -- nur wenn dieser Gast wirklich ohne Figur wartet (sonst z. B. neuer Geist nach server.lua-Respawn)
    if not PC or not (H and H.Dead) or A.IsAlive(A.Safe(function() return PC:K2_GetPawn() end)) then return end
    P.LastReqKey = nil
    local Ghost = P.Find(P.GhostPath)
    pcall(function() PC:Possess(GP) end)
    if Ghost then pcall(function() GPC:Possess(Ghost) end) end
    Log("Respawn: Server-Geist hatte die neue Figur %s uebernommen, an %s gegeben (Umleitung fehlte)", tostring(GN), Key)
    Core.Fail("respawn_ghost", "Spieler-0-Umleitung fehlte beim Respawn")
end

-- ================================================================ Gast: Tod, Todesbildschirm, Respawn

function P.ClientFast(Now)
    local C = P.C
    if Net.Side ~= "client" then
        if C.Active then P.ClientReset("kein Server mehr") end
        return
    end
    C.Active, P.ClientMode = true, true
    P.CheckGen()
    if Now >= (C.LockAt or 0) then
        C.LockAt = Now + 0.5
        local ok, err = pcall(P.SaveLock)
        if not ok then Core.Fail("save_lock", err) end
    end
    if Flag("death_guard") or P.RespawnOn() then
        local ok, err = pcall(P.DeathTick, Now)
        if not ok then Core.Fail("death_guard", err) end
    end
    if Flag("bed_v2") then
        local ok, err = pcall(P.BagTick, Now)
        if not ok then Core.Fail("bed_v2", err) end
    end
    if C.Tp then
        local ok, err = pcall(P.TpStep, Now)
        if not ok then C.Tp = nil Core.Fail("player_tp", err) end
    end
    if C.ByeAt and Now >= C.ByeAt then
        C.ByeAt = nil
        Log("Server beendet die Sitzung: trenne")
        pcall(A.RunCommand, "disconnect")
    end
end

-- player_tp (CORE-16, K27 pl_tp): Teleport des Servers (Admin tp/goto/bring, U-Bahn) an der eigenen Figur nachziehen.
-- Der Server versetzt seine Kopie selbst; ohne das zoege die Gast-Lage (trust_movement) sie zurueck. Nie
-- ClientSetLocation mit Lua-Strukturen (Regel 4). K2_TeleportTo ist kein RPC. Hoechstens 3 s auf die Figur warten.
function P.TpStep(Now)
    local T = P.C.Tp
    if Now - T.At > 3 then
        P.C.Tp = nil
        Log("Teleport vom Server verworfen (keine eigene Figur)")
        return
    end
    local Pawn = A.OwnPawn()
    if not A.IsAlive(Pawn) or P.IsDead(Pawn) then return end
    P.C.Tp = nil
    local ok = A.Safe(function()
        return Pawn:K2_TeleportTo({ X = T.X, Y = T.Y, Z = T.Z }, { Pitch = 0, Yaw = T.Yaw, Roll = 0 })
    end, false)
    Log("Teleport vom Server nach %.0f %.0f %.0f: %s", T.X, T.Y, T.Z, ok and "ok" or "fehlgeschlagen")
end

-- Verbindung weg / Modus gewechselt: eigenen Ladebildschirm entfernen, CDO zuruecksetzen, Zustand leeren
function P.ClientReset(Why)
    local C = P.C
    if C.LoadPath then pcall(P.HideLoading) end
    local D = P.Find(P.PATH.PermaCDO)
    if D and C.PermaOrig ~= nil then pcall(function() D["DeleteSave?"] = C.PermaOrig end) end
    P.ClientMode = false
    P.C = {}
    Log("Gast-Zustand zurueckgesetzt (%s)", Why)
end

-- AllowSaving? setzt das Level-Script zurueck: beim Gast alle 0,5 s aus (main.lua: 1 Hz)
function P.SaveLock()
    if not Flag("save_lock") then return end
    local GI = A.UEHelpers.GetGameInstance()
    if A.IsAlive(GI) and GI["AllowSaving?"] then GI["AllowSaving?"] = false end
end

function P.DeathTick(Now)
    local C = P.C
    local JC = A.Coop.JoinC   -- Beitritt laeuft (nicht Coop.JoinLoading: das meldet auch unseren Respawn)
    if JC and (JC.State == "wait" or JC.State == "spawned") then return end
    local Pawn = A.OwnPawn()
    local Name = Pawn and P.NameOf(Pawn) or nil
    local PawnDead = Pawn ~= nil and P.IsDead(Pawn)
    local Dead = PawnDead or (not Pawn and C.LastAlive ~= nil)
    if Dead and not C.Dead then
        C.DeadName, C.ScanAt = C.LastAlive or Name, 0
        Log("Eigene Figur %s tot", tostring(C.DeadName))
    end
    C.Dead = Dead
    if Dead then P.ScreenScan(Now) end
    local Phase = C.Phase
    if Phase == "screen" and not P.Up(C.ScreenPath) then
        C.Phase, C.GoneAt = "gone", Now
    elseif Phase == "gone" and Now - C.GoneAt >= 0.3 then
        P.Decide(Now)
    elseif Phase == "load" then
        return P.LoadStep(Now, Pawn, Name, PawnDead)
    end
    if Pawn and not PawnDead then
        -- neue Figur ohne eigenen Klick (Rueckfall des Hosts, alter Weg): trotzdem ready melden
        if C.LastAlive and Name ~= C.LastAlive and C.Phase ~= "load" then
            C.Phase, C.LoadAt, C.DeadName = "load", Now, C.LastAlive
            -- respawn_hudfast (PLAYER-18): auch hier den HUD-Schnellweg anbieten (sonst SETUP/HUD_DELAY, HUD erst nach
            -- 5-8 s). Eigene Tabelle mit Frist: LoadStep ist oft fertig, bevor main.lua HandleClient (1 Hz) sie sieht.
            if Flag("respawn_hudfast") then C.HudSpawn = { State = "spawned", Until = Now + 10 } end
            Log("Neue eigene Figur %s ohne Respawn-Klick", Name)
            return P.LoadStep(Now, Pawn, Name, false)
        end
        if C.Phase ~= "load" then C.LastAlive, C.Phase, C.DeadName = Name, nil, nil end
    end
end

-- Todesbildschirme finden (1 Hz), SaveMenu/Permadeath behandeln
function P.ScreenScan(Now)
    local C = P.C
    local W = P.Up(C.ScreenPath)
    if not W and Now >= (C.ScanAt or 0) then
        C.ScanAt = Now + 1
        W = P.Visible("RespawnScreen_C")
        C.ScreenPath = W and P.PathOf(W) or C.ScreenPath
        local Perma = P.Visible("ScreenPermadeath_C")
        if Perma then P.PermaGuard(Perma) end
        C.PermaUp = Perma ~= nil
    end
    if W and (C.Phase == nil or C.Phase == "gone" or C.Phase == "quit") then C.Phase = "screen" end
    if W and Now >= (C.MenuAt or 0) then
        C.MenuAt = Now + 0.5
        P.SaveMenuTick(W)
    end
end

-- ScreenPermadeath: nie den eigenen Spielstand loeschen (Hook setzt es schon in Construct; hier nur Nachzuegler)
function P.PermaGuard(W)
    if not Flag("death_guard") then return end
    if A.Safe(function() return W["DeleteSave?"] end, false) then
        pcall(function() W["DeleteSave?"] = false end)
        Log("ScreenPermadeath: DeleteSave? abgeschaltet (Nachzuegler, Hook griff nicht)")
    end
end

-- SaveMenu im Todesbildschirm: offen = freiwilliges Verlassen (Coop.Home laedt dann nicht automatisch den
-- eigenen Spielstand), Speichern ausgeblendet. Zurueck ohne Laden: Merker wieder weg.
function P.SaveMenuTick(W)
    local C, Home = P.C, A.Coop.Home
    local SM = A.Safe(function() return W.SaveMenu end)
    local Open = SM and A.IsAlive(SM) and A.Safe(function() return SM:IsVisible() end, false)
    if Open then
        if Home then Home.VoluntaryAt = os.time() end
        if not C.SaveMenuMarked then Log("SaveMenu im Todesbildschirm offen: Laden zaehlt als freiwilliges Verlassen") end
        C.SaveMenuMarked = true
        if Flag("save_lock") then
            for _, Field in ipairs({ "SaveGameButton", "NewGameBox" }) do
                local B = A.Safe(function() return SM[Field] end)
                if B and A.IsAlive(B) and A.Safe(function() return B:GetVisibility() ~= 1 end, false) then
                    pcall(function() B:SetVisibility(1) end)
                end
            end
        end
    elseif C.SaveMenuMarked then
        C.SaveMenuMarked = nil
        if Home then Home.VoluntaryAt = nil end
    end
end

-- RespawnScreen ist weg: Quit/Leave oder Respawn-Klick?
function P.Decide(Now)
    local C, Home = P.C, A.Coop.Home
    local Leaving = Home and ((Home.VoluntaryAt and os.time() - Home.VoluntaryAt < 5) or Home.DisconnectAt)
    if Leaving or P.Visible("QuitWidgetRespawn_C") then
        C.Phase = "quit"
        Log("Todesbildschirm geschlossen: Verlassen")
        return
    end
    if not P.RespawnOn() then C.Phase = nil return end
    if C.SaveMenuMarked and Home then Home.VoluntaryAt, C.SaveMenuMarked = nil, nil end
    C.Phase, C.LoadAt, C.Hud = "load", Now, { State = "spawned" }
    if C.Target and Now - C.Target.At > 5 then C.Target = nil end
    local ok, err = pcall(P.ShowLoading)
    if not ok then Log("Ladebildschirm fehlgeschlagen: %s", tostring(err)) end
    if Net.Has(P.RSP_CAP) then
        Net.Request("pl_req", "?", function(Data, _, Err)
            if not Data then Log("Respawn-Anfrage: %s", tostring(Err)) end
        end, 10, nil, 0)
    end
    Log("Respawn angefragt: Ladebildschirm bis die neue Figur steht")
end

function P.ShowLoading()
    local C = P.C
    local PC = A.LocalPC()
    local Cls = P.Find(P.PATH.Loading) or A.Safe(function() return LoadAsset(P.PATH.Loading) end)
    local WBL = P.Find(P.PATH.WBL)
    if not (A.IsAlive(PC) and Cls and A.IsAlive(Cls) and WBL) then error("Klasse oder PC fehlt") end
    local W = WBL:Create(PC, Cls, PC)
    if not A.IsAlive(W) then error("Create lieferte nichts") end
    W:AddToViewport(60)
    C.LoadPath = P.PathOf(W)
end

function P.HideLoading()
    local C = P.C
    local W = P.Find(C.LoadPath)
    C.LoadPath = nil
    if W then pcall(function() W:RemoveFromParent() end) end
end

-- Bereit: neue Figur (passend zu pl_resp), HUD da, Boden darunter geladen -> Ladebildschirm weg, pl_rready
function P.LoadStep(Now, Pawn, Name, PawnDead)
    local C = P.C
    local Done
    if Now - C.LoadAt >= P.LOAD_MAX then
        Done = string.format("Zeitlimit %d s", P.LOAD_MAX)
    elseif Pawn and not PawnDead and Name ~= C.DeadName then
        -- FNames laufzeit-gespawnter Figuren unterscheiden sich Host/Gast: neue Figur ueber die Position erkennen
        local Match = C.Target and P.NearTarget(Pawn, C.Target)
        if C.Target and not Match and Now - C.LoadAt < 5 then return end
        if Match then C.TargetId = C.Target.Id end
        if not A.IsAlive(A.Safe(function() return Pawn.InGameUI end)) then return end
        local L = Pawn:K2_GetActorLocation()
        if not A.Coop.Ground(L, Pawn, 50) and Now - C.LoadAt < 15 then return end
        Done = "Figur bereit"
    end
    if not Done then return end
    if C.LoadPath then P.HideLoading() end
    Log("Respawn fertig (%s) nach %.1f s", Done, Now - C.LoadAt)
    -- pl_rready: Host-Respawn-Kennung aus pl_resp zurueckgeben (passende Figur), sonst "self" (eigene Figur)
    local Ready = C.TargetId or "self"
    C.Phase, C.Hud, C.DeadName, C.Target, C.TargetId = nil, nil, nil, nil, nil
    if Name and not PawnDead then
        C.LastAlive = Name
        if Net.Has(P.RSP_CAP) then Net.Send("pl_rready", Net.Enc(Ready), nil, 0) end
    end
end

-- Liegt die eigene Figur an der vom Host gemeldeten Position der neuen Figur?
function P.NearTarget(Pawn, T)
    if not (T and T.X) then return false end
    local L = A.Safe(function() return Pawn:K2_GetActorLocation() end)
    if not L then return false end
    local DX, DY, DZ = L.X - T.X, L.Y - T.Y, L.Z - T.Z
    return DX * DX + DY * DY + DZ * DZ <= P.TARGET_DIST * P.TARGET_DIST
end

-- ScreenPermadeath: Pre-Hook auf Construct (seltenes UI-Ereignis). Ausnahme der Hook-Regel: nur eine
-- Property-Schreibung am Widget, kein UFunction-Aufruf - der Loeschbefehl laeuft schon im naechsten Tick.
-- Dazu der Klassen-Standardwert (CDO), solange wir Gast sind.
function P.PermaSetup()
    local C = P.C
    if not Flag("death_guard") then return end
    local Cls = P.Find(P.PATH.Perma)
    if not Cls and not C.PermaLoadTried then
        C.PermaLoadTried = true
        Cls = A.Safe(function() return LoadAsset(P.PATH.Perma) end)
    end
    if not (Cls and A.IsAlive(Cls)) then return end
    if P.PermaHooked == nil then
        P.PermaHooked = A.TryHook(P.PATH.Perma .. ":Construct", function(Context)
            if not P.ClientMode then return end
            P.PermaHits = P.PermaHits + 1
            pcall(function()   -- CORE-20: Widget erst pruefen
                local W = Context:get()
                if A.IsAlive(W) then W["DeleteSave?"] = false end
            end)
        end) or false
        Log("ScreenPermadeath-Schutz: Hook %s", P.PermaHooked and "aktiv" or "fehlgeschlagen")
    end
    local D = P.Find(P.PATH.PermaCDO)
    if D and A.Safe(function() return D["DeleteSave?"] end, false) then
        C.PermaOrig = true
        pcall(function() D["DeleteSave?"] = false end)
    end
end

-- Eigener SP-Spielstand: einmal pro Verbindung sichern (DLL-Dienst "backup", Datei-IPC)
function P.CurrentSlot()
    local E = A.Safe(function() return FindFirstOf("EMSObject") end)
    local Name = E and A.IsAlive(E) and A.Safe(function() return E.CurrentSaveGameName:ToString() end)
    if type(Name) == "string" and Name ~= "" then return Name end
    local Lib = P.Find("/Script/EasyMultiSave.Default__EMSFunctionLibrary")
    local World = A.Safe(A.CurrentWorld)   -- CORE-20: Welt erst pruefen
    local Out = {}
    if Lib and A.IsAlive(World) then pcall(function() Lib:GetSlotInfoSaveGame(World, Out) end) end
    Name = Out.SaveGameName
    if type(Name) == "userdata" then Name = A.Safe(function() return Name:ToString() end) end
    return type(Name) == "string" and Name ~= "" and Name or nil
end

function P.BackupTick()
    local C = P.C
    if not Flag("guest_backup") or C.BackupDone then return end
    if not C.BackupSeq then
        local Slot = P.CurrentSlot()
        if not Slot or not Slot:match("^[%w _%-%.]+$") or Slot:find("..", 1, true) then
            C.BackupDone = true
            Log("Sicherung des eigenen Spielstands: Slot unbekannt (%s)", tostring(Slot))
            return
        end
        local Base, Seq = P.GuestDir(), Native.NextSeq()
        local Text = string.format("seq=%d\nsrc=%s%s\ndst=%sLS_Backup\\%s_%s\nkeep=5\n", Seq, Base, Slot, Base, Slot,
            os.date("%Y%m%d_%H%M%S"))
        local ok, Why = Native.Request("backup", Text)
        if not ok then C.BackupDone = true Log("Sicherung nicht angefragt (%s)", tostring(Why)) return end
        C.BackupSeq, C.BackupAt = Seq, os.clock()
        Log("Sicherung des eigenen Spielstands %s angefragt", Slot)
        return
    end
    local R = Native.ReadDone("backup", C.BackupSeq)
    if R then
        C.BackupDone = true
        Log("Sicherung des eigenen Spielstands: %s", tostring(R.status or R.ok or "fertig"))
    elseif os.clock() - C.BackupAt > 60 then
        C.BackupDone = true
        Native.Cancel("backup")
        Log("Sicherung: DLL-Dienst backup antwortet nicht")
    end
end

-- Spawnpunkt-Spiegel: der Respawn-Knopf liest RespawnPointEnabled der lokalen PC-Kopie
function P.ApplySpawnPt()
    local V = Net.Get("pl_spawnpt", "en")
    if V == nil or P.BagHold() then return end
    local PC = A.LocalPC()
    local Want = V == "1"
    if A.IsAlive(PC) and A.Safe(function() return PC.RespawnPointEnabled end, Want) ~= Want then
        pcall(function() PC.RespawnPointEnabled = Want end)
    end
end

-- Welt-Schlafsack (BP_SleepingBag_C): SetSpawnPoint laeuft NUR beim Gast (OnServerExecuteInteract leer) und schreibt
-- nur die lokale PC-Kopie (CastToController = Spieler 0). UE 5.6: OnExecuteInteract Option2 -> L_00b0 ->
-- self.BedComponent->SetSpawnPoint(StaticMesh-Transform) @00e2; BedComponent_C.SetSpawnPoint setzt RespawnPointEnabled
-- und RespawnLoc. 5.3: BP_SleepingBag_C.SetSpawnPoint (Rueckfall). Pre-Hook merkt nur die Zeit (seltenes Ereignis,
-- kein UFunction-Aufruf); der Tick liest danach die lokale RespawnLoc und meldet sie dem Host (pl_bag).
-- Buildable_SleepingBag/Buildable_Bed rufen BedComponent.SetSpawnPoint serverseitig (OnServerExecuteInteract @0207):
-- beim Gast feuert der Hook dafuer nicht, auf dem Host faengt GhostBed das ab.
P.BAG_HOOKS = { { "BedComp", "BedComponent" }, { "Bag", "BP_SleepingBag (5.3)" } }
function P.BagHold()
    local At = P.C.BagAt
    return At ~= nil and os.clock() - At < P.BAG_HOLD
end

function P.BagTick(Now)
    local C = P.C
    if not P.BagHooked and Now >= (P.BagHookTry or 0) then
        P.BagHookTry = Now + 10
        for _, E in ipairs(P.BAG_HOOKS) do
            local Path = P.PATH[E[1]]
            -- nur hooken, wenn die UFunction existiert (5.6: BP_SleepingBag_C:SetSpawnPoint fehlt, kein Hook-Log je 10 s)
            if not P.BagHooked and P.Find(Path .. ":SetSpawnPoint") then
                P.BagHooked = A.TryHook(Path .. ":SetSpawnPoint", function()
                    if Net.Side ~= "client" then return end
                    P.C.BagAt, P.C.BagSent = os.clock(), false
                end)
                if P.BagHooked then Log("Welt-Schlafsack: Hook aktiv (%s.SetSpawnPoint)", E[2]) end
            end
        end
    end
    if not C.BagAt or C.BagSent or Now - C.BagAt < 0.2 then return end
    C.BagSent = true
    if not Net.Has(P.CAP) then Log("Welt-Schlafsack: Server kennt pl_bag nicht") return end
    local PC = A.LocalPC()
    local Text = A.IsAlive(PC) and A.Safe(function() return P.LocText(PC) end)
    if not Text then return end
    Net.Send("pl_bag", Text, nil, 1)
    Log("Welt-Schlafsack: Spawnpunkt an Server gemeldet (%s)", Text)
end

-- Host: pl_bag pruefen (echter BP_SleepingBag_C nahe der Meldung, Gast-Figur nahe) und Spawnpunkt setzen
function P.HostBag(Data, G)
    local H = P.HOf(G.Key)
    local Now = os.clock()
    if Now < (H.BagAskAt or 0) then return Net.SecWarn(G, G.Key, "pl_bag_rate") end
    H.BagAskAt = Now + 3
    local X, Y, Z, Yaw = (Data or ""):match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)$")
    X, Y, Z, Yaw = tonumber(X), tonumber(Y), tonumber(Z), tonumber(Yaw)
    if not (X and Y and Z and Yaw) then return end
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or P.IsDead(Pawn) then return end
    local function Far(L, Max)
        return not L or (L.X - X) ^ 2 + (L.Y - Y) ^ 2 + (L.Z - Z) ^ 2 > Max * Max
    end
    if Far(A.Safe(function() return Pawn:K2_GetActorLocation() end), P.BAG_PAWN) then
        return Log("Welt-Schlafsack von %s abgelehnt: Figur zu weit weg", tostring(G.GuestId or G.Key))
    end
    local Found = false
    for _, Bag in ipairs(A.Safe(function() return FindAllOf("BP_SleepingBag_C") end) or {}) do
        if A.IsAlive(Bag) and not Far(A.Safe(function() return Bag:K2_GetActorLocation() end), P.BAG_NEAR) then
            Found = true
            break
        end
    end
    if not Found then
        return Log("Welt-Schlafsack von %s abgelehnt: kein Schlafsack an der Stelle", tostring(G.GuestId or G.Key))
    end
    P.SetBed(PC, X, Y, Z, Yaw)
    Log("Spawnpunkt (Welt-Schlafsack) fuer %s gesetzt", tostring(P.GuestIdOf(G.Key) or G.Key))
end

-- Startquest fuer neue Gaeste: NICHT hier (Narrative BeginQuest ist serverseitig). Der Host startet sie in
-- ls_world (quest_start, W.StartQuest auf dem NC von Net.PC(G), mit IsQuestStartedOrFinished-Schutz).

-- ================================================================ Host: Bett/Spawnpunkt je Gast

function P.BedFile(Id) return P.GuestDir() .. "NetTest_Guests\\" .. Id .. ".spawn.txt" end

function P.ReadBed(PC)
    if not A.Safe(function() return PC.RespawnPointEnabled == true end, false) then return "0" end
    return P.LocText(PC)
end

-- RespawnLoc als "x|y|z|yaw" (ohne Pruefung von RespawnPointEnabled)
function P.LocText(PC)
    local T = PC.RespawnLoc
    local Tr, Q = T.Translation, T.Rotation
    local Yaw = math.deg(math.atan(2 * (Q.W * Q.Z + Q.X * Q.Y), 1 - 2 * (Q.Y * Q.Y + Q.Z * Q.Z)))
    return string.format("%.1f|%.1f|%.1f|%.1f", Tr.X, Tr.Y, Tr.Z, Yaw)
end

-- RespawnLoc (FTransform) feldweise schreiben, zuruecklesen; sonst als Ganzes (UE4SS wandelt die Tabelle).
-- PLAYER-26: RespawnPointEnabled erst nach dem bestaetigten Schreiben (vorher: an, RespawnLoc nicht schreibbar ->
-- Respawn bei 0,0,0); nicht schreibbar -> Spawnpunkt aus (zufaelliger Respawn) und Fehler.
function P.SetBed(PC, X, Y, Z, Yaw)
    local R = math.rad(Yaw or 0) / 2
    local function Written()
        local Back = A.Safe(function() return PC.RespawnLoc.Translation.X end)
        return type(Back) == "number" and math.abs(Back - X) < 1
    end
    pcall(function()
        local T = PC.RespawnLoc
        T.Translation.X, T.Translation.Y, T.Translation.Z = X, Y, Z
        T.Rotation.X, T.Rotation.Y, T.Rotation.Z, T.Rotation.W = 0, 0, math.sin(R), math.cos(R)
        T.Scale3D.X, T.Scale3D.Y, T.Scale3D.Z = 1, 1, 1
    end)
    if not Written() then
        pcall(function()
            PC.RespawnLoc = { Translation = { X = X, Y = Y, Z = Z },
                              Rotation = { X = 0, Y = 0, Z = math.sin(R), W = math.cos(R) }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        end)
    end
    if not Written() then
        pcall(function() PC.RespawnPointEnabled = false end)
        error("RespawnLoc nicht schreibbar")
    end
    PC.RespawnPointEnabled = true
end

function P.BedTick()
    if Net.Side ~= "host" or not Flag("bed_v2") then return end
    for Key, PC in pairs(Net.ScanPCs()) do
        local Id = P.GuestIdOf(Key)
        if Id and not P.S.Rejected[Key] and not P.Dup(Key) and A.Safe(function() return A.J.IsReady(Key) end, true) then
            local ok, err = pcall(P.BedStep, Key, PC, Id)
            if not ok and Core.Fail("bed_v2", err) then return end
        end
    end
    if A.Coop.Server then
        local ok, err = pcall(P.GhostBed)
        if not ok then Core.Fail("bed_v2", err) end
    end
end

function P.BedStep(Key, PC, Id)
    local H = P.HOf(Key)
    if H.BedId ~= Id then H.BedId, H.BedLoaded, H.BedLast = Id, false, nil end
    if not H.BedLoaded then
        H.BedLoaded = true
        local Text = Core.ReadAll(P.BedFile(Id))
        local X, Y, Z, Yaw = (Text or ""):match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)")
        if X then
            P.SetBed(PC, tonumber(X), tonumber(Y), tonumber(Z), tonumber(Yaw))
            H.BedLast = P.ReadBed(PC)
            Log("Spawnpunkt von Mitspieler %s wiederhergestellt (%s %s %s)", Id, X, Y, Z)
        end
    end
    local Cur = P.ReadBed(PC)
    if Cur ~= H.BedLast then
        if Cur ~= "0" then
            Core.WriteAtomic(P.BedFile(Id), Cur)
            Log("Spawnpunkt von Mitspieler %s gespeichert (%s)", Id, Cur)
        end
        H.BedLast = Cur
    end
    Net.State("pl_spawnpt", "en", Cur ~= "0" and "1" or "0", 2, Key)
end

-- Dedizierter Host: Spawnpunkt landete beim Geist (SetSpawnPoint nimmt Spieler 0) -> naechstem Gast geben
function P.GhostBed()
    local GPC = A.LocalPC()
    if not A.IsAlive(GPC) or not A.Safe(function() return GPC.RespawnPointEnabled == true end, false) then return end
    local Text = P.ReadBed(GPC)
    pcall(function() GPC.RespawnPointEnabled = false end)
    local X, Y, Z, Yaw = Text:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    X, Y, Z, Yaw = tonumber(X), tonumber(Y), tonumber(Z), tonumber(Yaw)
    if not X then return end
    local Best, BestD = nil, P.GHOST_NEAR
    for Key, PC in pairs(Net.ScanPCs()) do
        local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
        if A.IsAlive(Pawn) then
            local L = Pawn:K2_GetActorLocation()
            local D = math.sqrt((L.X - X) ^ 2 + (L.Y - Y) ^ 2 + (L.Z - Z) ^ 2)
            if D < BestD then Best, BestD = Key, D end
        end
    end
    local PC = Best and Net.PC(Best)
    if not PC then Log("Spawnpunkt beim Server-Geist ohne Mitspieler in der Naehe, verworfen") return end
    P.SetBed(PC, X, Y, Z, Yaw)
    Log("Spawnpunkt landete beim Server-Geist: %s zugeordnet (%.0f uu)", Best, BestD)
end

-- ================================================================ Host: Sitzung (gleiche Gast-ID)

function P.SessionTick(Now)
    if Net.Side ~= "host" or not Flag("session_v2") then return end
    P.CheckGen()
    local PCs, ById = Net.ScanPCs(), {}
    for Key in pairs(PCs) do
        P.S.First[Key] = P.S.First[Key] or Now
        local Id = P.GuestIdOf(Key)
        if Id and not P.S.Done[Key] then
            ById[Id] = ById[Id] or {}
            table.insert(ById[Id], Key)
        end
    end
    for Key in pairs(P.S.First) do
        if not PCs[Key] then P.S.First[Key], P.S.Done[Key], P.S.Rejected[Key] = nil, nil, nil end
    end
    for Id, Keys in pairs(ById) do
        if #Keys > 1 then
            local ok, err = pcall(P.Resolve, Id, Keys, PCs, Now)
            if not ok and Core.Fail("session_v2", err) then return end
        end
    end
    P.KickTick(Now)
end

function P.Stale(Key, Now)
    local L = A.Coop.Link or {}
    if L.Frozen and L.Frozen[Key] then return true end
    local Beat = L.Beat and L.Beat[Key]
    if Beat then return os.time() - Beat >= P.QUIET end
    return Now - (P.S.First[Key] or Now) > 15
end

function P.Resolve(Id, Keys, PCs, Now)
    table.sort(Keys, function(X, Y) return (P.S.First[X] or 0) < (P.S.First[Y] or 0) end)
    local New = Keys[#Keys]
    for I = 1, #Keys - 1 do
        local Old = Keys[I]
        if P.Stale(Old, Now) then
            P.Takeover(Old, New, Id, PCs)
        else
            return P.Reject(New, Id, PCs, Now)
        end
    end
end

-- Neue Verbindung gewinnt: alte Figur nie mehr speichern (ihr eingefrorener Stand ist schon gespeichert),
-- Figur und Controller entfernen
function P.Takeover(Old, New, Id, PCs)
    local G = A.G
    G.Restored[Old], G.StoreAt[Old] = nil, nil
    local PC = PCs[Old]
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if A.IsAlive(Pawn) then
        G.Dead[Old] = P.NameOf(Pawn)
        if not P.IsDead(Pawn) then pcall(function() Pawn:K2_DestroyActor() end) end
    end
    if PC then pcall(function() PC:K2_DestroyActor() end) end
    if G.RetryAt[New] == math.huge then G.RetryAt[New] = nil end
    P.S.Done[Old] = true
    Log("Wiederbeitritt %s: neue Verbindung gewinnt, alte geschlossen (ohne Speichern)", Id)
end

-- Gleiche ID, alte lebt noch: neue ablehnen (kein Abgleich, kein Speichern), nach KICK_HARD s Controller weg
function P.Reject(New, Id, PCs, Now)
    local Msg = "Diese Spieler-ID ist schon verbunden (Mod-Ordner kopiert?)"
    A.G.RetryAt[New] = math.huge
    P.S.Done[New], P.S.Rejected[New] = true, { At = Now }
    local PC = PCs[New]
    local G = Net.Guests[New]
    if G and Net.Linked(G) then Net.Send("pl_bye", "dup|" .. Net.Enc(Msg), G, 0) end
    if PC then
        P.LegacyNote(PC, Msg)
        pcall(function() PC:ClientReturnToMainMenuWithTextReason(FText(Msg)) end)
    end
    Log("Doppelte Mitspieler-ID %s: neue Verbindung abgelehnt", Id)
end

function P.KickTick(Now)
    for Key, R in pairs(P.S.Rejected) do
        if not R.Hard and Now - R.At > P.KICK_HARD then
            R.Hard = true
            local PC = Net.PC(Key)
            if PC then
                pcall(function() local Pawn = PC:K2_GetPawn() if A.IsAlive(Pawn) then Pawn:K2_DestroyActor() end end)
                pcall(function() PC:K2_DestroyActor() end)
                Log("Abgelehnte Verbindung trennte sich nicht selbst: Controller entfernt")
            end
        end
    end
end

-- ================================================================ Host: neuer Gast, Server-Ende, Befehle

function P.NewGuestTick()
    if Net.Side ~= "host" or not Flag("player_newquest") or A.Settings.local_inventory then return end
    local GS = A.UEHelpers.GetGameplayStatics()
    for Key in pairs(Net.ScanPCs()) do
        local Id = not P.Dup(Key) and P.GuestIdOf(Key) or nil   -- Doppel-Login: weder pruefen noch pl_new
        if Id and P.New[Key] == nil and not A.G.Restored[Key] then
            -- PLAYER-19: der Tod loescht den Inventar-Stand (main.lua), <Id>.werte.txt bleibt -> "2" (nach dem Tod)
            -- statt "1" (neu). P.New: nil = ungeprueft, "1"/"2" = pl_new offen, false = erledigt bzw. nicht neu
            local Inv = A.Safe(function() return GS:DoesSaveGameExist(A.G.GuestSlot(Id), 0) end, true)
            P.New[Key] = not Inv and (P.HasWerte(Id) and "2" or "1") or false
            if P.New[Key] == "1" then Log("Mitspieler %s ist neu auf diesem Server", Id)
            elseif P.New[Key] == "2" then Log("Mitspieler %s ohne Inventar-Stand (nach dem Tod): Startausruestung", Id) end
        end
        local G = Net.Guests[Key]
        if P.New[Key] and Id and G and G.Ready and Net.Has(P.CAP, G) then
            local Kind = P.New[Key]
            P.New[Key] = false
            Net.Send("pl_new", Kind, G, 1)
        end
    end
end

-- PLAYER-19: hat der Gast schon Werte auf diesem Server (Level/XP/Skills, main.lua V.Path = NetTest_Guests\<Id>.werte.txt)?
function P.HasWerte(Id)
    local V = A.V
    if type(V) ~= "table" or type(V.Path) ~= "function" then return false end
    local ok, Path = pcall(V.Path, Id)
    local Text = ok and type(Path) == "string" and Core.ReadAll(Path) or nil
    return type(Text) == "string" and Text ~= ""
end

-- Finales Speichern eines Gasts (wie G.HandleHost, nur sofort). ls_inv darf Coop.InvStoreNow anbieten.
function P.FinalStore(Key, PC)
    local G = A.G
    local Id = A.Coop.GuestIds and A.Coop.GuestIds[Key]
    local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
    if not (Id and A.IsAlive(Pawn) and G.Restored[Key]) or P.S.Done[Key] or P.S.Rejected[Key] or P.Dup(Key) then return false end
    if G.Dead[Key] == P.NameOf(Pawn) or P.IsDead(Pawn)
        or not A.Safe(function()
            local Med = Pawn.MedicalComponent
            return A.IsAlive(Med) and Med.Health > 0
        end, false) then return false end
    if A.Coop.InvStoreNow then
        A.Coop.InvStoreNow(Key, PC, Pawn, Id)
    else
        G.Store(Pawn, G.GuestSlot(Id), Id)
    end
    pcall(A.V.Store, Pawn, PC, Id)
    G.StoreAt[Key] = os.time() + 3600
    return true
end

function P.Shutdown(Reason)
    if Net.Side ~= "host" or P.ShutDone or not Flag("shutdown_v2") then return end
    P.ShutDone = true
    local N, Stored = 0, 0
    local Text = "Server wird beendet - dein Stand ist gespeichert"
    for Key, PC in pairs(Net.ScanPCs(true)) do
        N = N + 1
        if not A.Settings.local_inventory then
            local ok, Done = pcall(P.FinalStore, Key, PC)
            if ok and Done then Stored = Stored + 1 elseif not ok then Log("Speichern %s: %s", Key, tostring(Done)) end
        end
        local G = Net.Guests[Key]
        if G and Net.Has(P.CAP, G) then
            Net.Send("pl_bye", "stop|" .. Net.Enc(Text), G, 0)
        else
            P.LegacyNote(PC, Text)
        end
    end
    Log("Server-Ende (%s): %d Mitspieler, %d gespeichert, bye gesendet", tostring(Reason), N, Stored)
end

-- unstuck_safe (PLAYER-3): Linie ab Kapselmitte + 60 uu statt + 300 uu. Von dort oben traf sie die Decke/den Boden
-- des naechsten Stockwerks und setzte die Figur hinein (fremde Basen). Treffer ueber der Kapselmitte zaehlt nicht als
-- Boden. Ziel in einem fremden Claim: abgelehnt (Rueckgabe "claim", false, true). Vor dem Teleport E23 (TrustSkip).
function P.Unstuck(PC, Pawn, Key)
    local SafeOn = Flag("unstuck_safe")
    local L = Pawn:K2_GetActorLocation()
    local Yaw = A.Safe(function() return Pawn:K2_GetActorRotation().Yaw end, 0)
    local Floor = A.Coop.Ground({ X = L.X, Y = L.Y, Z = L.Z }, Pawn, SafeOn and P.UNSTUCK_UP or 300)
    if SafeOn and Floor and Floor > L.Z then Floor = nil end
    local Target, Kind
    if Floor then
        Target, Kind = { X = L.X, Y = L.Y, Z = Floor + 100 }, "Boden"
    elseif A.Coop.Server and A.Coop.Server.SpawnPoint then
        local Loc, SYaw = A.Coop.Server.SpawnPoint(A.CurrentWorld(), PC, L, Yaw)
        Target, Yaw, Kind = { X = Loc.X, Y = Loc.Y, Z = Loc.Z + 100 }, SYaw, "Spawnpunkt"
    else
        Target, Kind = { X = L.X, Y = L.Y, Z = L.Z + 150 }, "hoch"
    end
    if SafeOn and P.ForeignClaim(Key, Target) then return "claim", false, true end
    if Key then   -- E23: main.lua move_check wertet den Sprung nicht als Verstoss
        local Skip = A.Coop.TrustSkip or {}
        A.Coop.TrustSkip = Skip
        Skip[Key] = os.clock() + 5
    end
    local ok = A.Safe(function() return Pawn:K2_TeleportTo(Target, { Pitch = 0, Yaw = Yaw, Roll = 0 }) end, false)
    -- player_tp (K27): unter trust_movement uebernimmt der Server die Gast-Lage aus ServerMove und die Kapsel wird nicht
    -- repliziert -> ohne das zoege der Gast die Figur sofort zurueck in die Wand. Darum versetzt der Gast seine eigene
    -- Figur selbst (pl_tp -> P.TpStep, wie server.lua Teleport / U-Bahn). TrustSkip steht schon oben.
    if ok and Key and Flag("player_tp") then
        if A.Safe(function() return Net.Has("pl_tp", Key) end, false) then
            if not A.Safe(function()
                local Data = string.format("%.1f|%.1f|%.1f|%.1f", Target.X, Target.Y, Target.Z, tonumber(Yaw) or 0)
                return Net.Send("pl_tp", Data, Key, 0)
            end, false) then
                Log("unstuck %s: pl_tp nicht gesendet", tostring(Key))
            end
        elseif not P.UnstuckOldLogged then
            P.UnstuckOldLogged = true
            Log("unstuck %s: Gast ohne pl_tp - nur der Server versetzt die Figur (wirkt erst ohne trust_movement)", tostring(Key))
        end
    end
    pcall(function()
        local Move = Pawn.CharacterMovement
        if A.IsAlive(Move) then Move:SetMovementMode(3, 0) end
    end)
    return Kind, ok
end

function P.HostCmd(Data, G, Msg)
    local function No(Why) if Msg.Rid then Net.Reply(Msg, "no|" .. Why) end end
    if not Flag("player_cmds") then return No("aus") end
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or P.IsDead(Pawn) then return No("tot") end
    if not A.Safe(function() return A.J.IsReady(G.Key) end, true) or (P.H[G.Key] and P.H[G.Key].Resp) then
        return No("laedt")
    end
    local Cd, Now = P.Cmd[G.Key] or {}, os.clock()
    P.Cmd[G.Key] = Cd
    if Data == "suicide" then
        if Now < (Cd.suicide or 0) then return No("warte") end
        Cd.suicide = Now + 10
        -- DeathBringer rettet bei <= 0 HP auf 25 HP (Skill), bCanBeDamaged=false (Spawnschutz) schluckt den Schaden:
        -- beides fuer diesen Schaden ausschalten, danach pruefen; lebt die Figur noch, alten Stand zurueck und "no".
        -- UE 5.6: ReceiveAnyDamage (@21880) bricht zusaetzlich bei MedicalComponent.CanTakeDamage? = false ab
        local OldDmg = A.Safe(function() return Pawn.bCanBeDamaged end, true)
        local OldDB = A.Safe(function() return Pawn["DeathbringerSkillUsed?"] end, false)
        local Med0 = A.Safe(function() return Pawn.MedicalComponent end)
        if not A.IsAlive(Med0) then Med0 = nil end
        local OldCTD = Med0 and A.Safe(function() return Med0["CanTakeDamage?"] end)
        pcall(function() Pawn.bCanBeDamaged = true end)
        pcall(function() Pawn["DeathbringerSkillUsed?"] = true end)
        if OldCTD == false then pcall(function() Med0["CanTakeDamage?"] = true end) end
        -- PLAYER-27: ApplyDamage in pcall (sonst blieben die drei Werte bei einem Fehler umgestellt), nie ohne DamageType
        local GS, DT = A.UEHelpers.GetGameplayStatics(), P.Find(P.PATH.DamageType)
        local okD, errD = false, "GameplayStatics/DamageType fehlt"
        if A.IsAlive(GS) and DT then
            okD, errD = pcall(function() GS:ApplyDamage(Pawn, 1000, PC, Pawn, DT) end)
        end
        if not okD or A.IsAlive(Pawn) and not P.IsDead(Pawn) and A.Safe(function()
            local Med = Pawn.MedicalComponent
            return A.IsAlive(Med) and Med.Health > 0
        end, false) then
            if A.IsAlive(Pawn) then
                pcall(function() Pawn.bCanBeDamaged = OldDmg end)
                pcall(function() Pawn["DeathbringerSkillUsed?"] = OldDB end)
                if OldCTD == false and A.IsAlive(Med0) then pcall(function() Med0["CanTakeDamage?"] = false end) end
            end
            Log("Mitspieler %s: Selbstmord fehlgeschlagen (%s)", G.Key, okD and "Figur lebt noch" or tostring(errD))
            return No("lebt")
        end
        Log("Mitspieler %s: Selbstmord (Host-Schaden)", G.Key)
        return Net.Reply(Msg, "ok|suicide")
    elseif Data == "unstuck" then
        if Now < (Cd.unstuck or 0) then return No(string.format("warte %d s", math.ceil(Cd.unstuck - Now))) end
        if A.IsAlive(A.Safe(function() return Pawn:GetAttachParentActor() end)) then return No("fahrzeug") end
        -- unstuck_safe: nur wer wirklich feststeckt (Lage-Verlauf aus P.HostFast); Ablehnung sperrt nur kurz
        if Flag("unstuck_safe") and not P.IsStuck(G.Key, Now) then
            Cd.unstuck = Now + 5
            return No("frei")
        end
        Cd.unstuck = Now + 60
        local Kind, ok, Refused = P.Unstuck(PC, Pawn, G.Key)
        if Refused then
            Cd.unstuck = Now + 10
            Log("Mitspieler %s: unstuck abgelehnt (%s)", G.Key, tostring(Kind))
            return No(Kind)
        end
        Log("Mitspieler %s: unstuck (%s) %s", G.Key, Kind, ok and "ok" or "Teleport fehlgeschlagen")
        return Net.Reply(Msg, "ok|" .. Kind)
    end
    Net.SecWarn(G, G.Key, "pl_cmd")
    No("unbekannt")
end

-- Gast: Chat-Befehl (main.lua Coop.Chat.OnEnter). true = behandelt (nicht in den Chat schicken)
P.CMD_TEXT = { ["ok|suicide"] = "Du hast aufgegeben.", ["no|tot"] = "Geht nicht: du bist tot.",
               ["no|laedt"] = "Geht nicht waehrend des Ladens.", ["no|warte"] = "Bitte kurz warten.",
               ["no|fahrzeug"] = "Erst aus dem Fahrzeug aussteigen.", ["no|aus"] = "Auf diesem Server abgeschaltet.",
               ["no|lebt"] = "Hat nicht geklappt: du lebst noch.",
               ["no|claim"] = "Nicht in fremden Claims.",
               ["no|frei"] = "Du steckst nicht fest: erst 5 s stillstehen, dann /unstuck." }
function P.ChatCommand(Text)
    local Cmd = type(Text) == "string" and Text:match("^%s*/(%a+)%s*$")
    if Cmd and Cmd:lower() == "carlock" then return P.CarLock() end
    local What = Cmd and P.CMDS[Cmd:lower()]
    if not What or not Flag("player_cmds") then return false end
    if Net.Side ~= "client" or not Net.Has(P.CAP) then
        P.Note("Der Server kennt /" .. Cmd .. " nicht")
        return true
    end
    Net.Request("pl_cmd", What, function(Data, _, Err)
        if not Data then P.Note("Keine Antwort vom Server (" .. tostring(Err) .. ")") return end
        local Shown = P.CMD_TEXT[Data] or (Data:match("^ok|") and "Befreit (" .. Data:sub(4) .. ")")
            or ("Geht nicht: " .. Data:gsub("^no|", ""))
        P.Note(Shown)
    end, 8, nil, 0)
    return true
end

-- CAR-8 (E20): /carlock -> ls_car A.Coop.CarLockCmd (Gast, merkt nur vor; ls_car ClientFast schickt car_lock fuer das
-- eigene bzw. naechste Auto). Immer behandelt (true): sonst ginge der Befehl als Chat an den Host.
function P.CarLock()
    local Fn = A.Coop.CarLockCmd
    if type(Fn) ~= "function" then
        P.Note("Fahrzeug-Schloss gibt es hier nicht")
        return true
    end
    local ok, Text = pcall(Fn)
    P.Note(ok and type(Text) == "string" and Text ~= "" and Text or "Fahrzeug-Schloss: Fehler")
    return true
end

-- ================================================================ Netz-Handler

M.Handlers = {
    -- Gast -> Host: Respawn-Klick (Daten "?"), Antwort "ok"/"alive"
    pl_req = function(Data, G, Msg)
        if Net.Side ~= "host" or type(G) ~= "table" then return end
        local H = P.HOf(G.Key)
        local Now = os.clock()
        if Now < (H.ReqAskAt or 0) then return Net.SecWarn(G, G.Key, "pl_req_rate") end
        H.ReqAskAt = Now + 2
        if not H.Dead then
            if Msg.Rid then Net.Reply(Msg, "alive") end
            return
        end
        H.ReqAt, H.ReqN = Now, 0
        P.LastReqKey, P.LastReqAt = G.Key, Now
        if Msg.Rid then Net.Reply(Msg, "ok") end
    end,
    -- Gast -> Host: neue Figur steht (Echo der Host-Kennung aus pl_resp, oder "self" = eigene aktuelle Figur).
    -- Nie den Gast-FNamen vergleichen: laufzeit-gespawnte Figuren heissen auf beiden Seiten anders.
    pl_rready = function(Data, G)
        if Net.Side ~= "host" or type(G) ~= "table" then return end
        local H = P.HOf(G.Key)
        local Id = Net.Dec(Data or "")
        if H.Resp and (Id == H.Resp.Name or Id == "self") then H.Resp.Ready = true
        elseif Id == "self" then H.EarlyReady = os.clock() end   -- ready kam vor P.OnRespawn (pl_host-Takt 0,2 s)
    end,
    -- Gast -> Host: "suicide" | "unstuck"
    pl_cmd = function(Data, G, Msg)
        if Net.Side ~= "host" or type(G) ~= "table" then return end
        P.HostCmd(Data, G, Msg)
    end,
    -- Gast -> Host: Welt-Schlafsack benutzt "x|y|z|yaw" (lokale RespawnLoc nach BP_SleepingBag_C.SetSpawnPoint)
    pl_bag = function(Data, G)
        if Net.Side ~= "host" or type(G) ~= "table" or not Flag("bed_v2") then return end
        local ok, err = pcall(P.HostBag, Data, G)
        if not ok then Log("Welt-Schlafsack: %s", tostring(err)) end
    end,
    -- Host -> Gast: Id|X|Y|Z der neuen Figur. Id = Host-FName, nur als undurchsichtige Respawn-Kennung
    -- (Echo in pl_rready); beim Gast wird die Figur ueber die Position erkannt, nie ueber den Namen.
    pl_resp = function(Data)
        if Net.Side ~= "client" then return end
        local Id, X, Y, Z = (Data or ""):match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
        if Id and X and Y and Z then P.C.Target = { Id = Net.Dec(Id), X = X, Y = Y, Z = Z, At = os.clock() } end
    end,
    -- Host -> Gast: Sitzungsende "<grund>|<text>"
    pl_bye = function(Data)
        if Net.Side ~= "client" then return end
        local Why, Text = (Data or ""):match("^([%w_]+)|(.*)$")
        Log("Server meldet Ende: %s", tostring(Why))
        P.Note(Net.Dec(Text or "Server beendet die Sitzung"))
        P.C.ByeAt = os.clock() + 1.5
    end,
    -- Host -> Gast: neu auf diesem Server ("1"; alte Hosts) bzw. ohne Inventar-Stand nach dem Tod ("2", PLAYER-19)
    pl_new = function(Data)
        if Net.Side ~= "client" then return end
        P.Note(Data == "2" and "Startausruestung nach dem Tod erhalten" or "Neu auf diesem Server: Startausruestung erhalten")
    end,
    -- Host -> Gast (K27, player_tp): "x|y|z|yaw" = eigene Figur dorthin (nur vormerken, P.TpStep fuehrt aus)
    pl_tp = function(Data)
        if Net.Side ~= "client" or not Flag("player_tp") or type(Data) ~= "string" or #Data > 80 then return end
        local X, Y, Z, Yaw = Data:match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)$")
        X, Y, Z, Yaw = tonumber(X), tonumber(Y), tonumber(Z), tonumber(Yaw)
        if not (X and Y and Z and Yaw) or math.abs(X) > 5e6 or math.abs(Y) > 5e6 or math.abs(Z) > 1e6 then return end
        P.C.Tp = { X = X, Y = Y, Z = Z, Yaw = Yaw, At = os.clock() }
    end,
    -- Host -> Gast (Keyed-State, Schluessel "en"): Spawnpunkt gesetzt "1"/"0"
    pl_spawnpt = function(Value, _, Msg)
        if Net.Side ~= "client" or not (Msg and Msg.Key == "en") or Value == nil or P.BagHold() then return end
        local PC = A.LocalPC()
        if A.IsAlive(PC) then pcall(function() PC.RespawnPointEnabled = Value == "1" end) end
    end,
}

-- ================================================================ Ticks, Init

function M.HostTick()
    P.CheckGen()
    local ok, err = pcall(P.BedTick)
    if not ok then Core.Fail("bed_v2", err) end
    ok, err = pcall(P.NewGuestTick)
    if not ok then Core.Fail("player_newquest", err) end
end

function M.ClientTick()
    local ok, err = pcall(P.PermaSetup)
    if not ok then Core.Fail("death_guard", err) end
    ok, err = pcall(P.BackupTick)
    if not ok then Core.Fail("guest_backup", err) end
    if Flag("bed_v2") then pcall(P.ApplySpawnPt) end
end

function P.Caps()
    local Rsp = P.RespawnOn()
    Net.Cap(P.CAP, Rsp or Flag("player_cmds") or Flag("shutdown_v2") or Flag("bed_v2")
        or Flag("session_v2") or Flag("player_newquest"))
    Net.Cap(P.RSP_CAP, Rsp)
    Net.Cap("pl_tp", Flag("player_tp"))   -- K27: beide Seiten (server.lua sendet nur mit Net.Has("pl_tp", Gast))
end

function M.Init(Api)
    A = Api
    A.Coop.Player = {
        -- main.lua CloseMenus/InputWatch: Todesbildschirme stehen lassen, Eingabe nicht auf GameOnly
        KeepScreen = function(Name)
            return Net.Side == "client" and P.C.Dead == true and P.SCREENS[Name] == true and Flag("death_guard")
        end,
        DeathScreenUp = function() return Net.Side == "client" and P.C.Dead == true and Flag("death_guard") end,
        -- main.lua Coop.JoinLoading: eigener Respawn-Ladebildschirm laeuft
        Loading = function() return P.C.Phase == "load" and P.C.LoadPath ~= nil end,
        -- main.lua HandleClient: HUD-Schnellweg auch nach dem Respawn (JC-Ersatz mit State/HudFor/HudAt)
        HudFast = function(JC)
            if JC and JC.State == "spawned" then return JC end
            if P.C.Phase == "load" and P.C.Hud then return P.C.Hud end
            -- respawn_hudfast: Respawn ohne Klick (HandleClient schreibt HudFor/HudAt hinein), hoechstens 10 s
            local S = P.C.HudSpawn
            if S and os.clock() < S.Until and Flag("respawn_hudfast") then return S end
            return JC
        end,
        -- main.lua HandleRemotePlayers: 90-s-Notfall-Respawn neben dem Host aus, je Gast (beide Seiten pl_rsp)
        OwnsRespawn = function(Key)
            if not P.RespawnOn() then return false end
            if Key == nil then return true end
            local ok, Has = pcall(Net.Has, P.RSP_CAP, Key)
            return ok and Has == true
        end,
        -- ls_ui F.Respawn (ui_rsp-Spiegel): waehrend der Welt-Schlafsack-Meldung lokale RespawnPointEnabled nicht zuruecksetzen
        BagHold = function() return Net.Side == "client" and P.BagHold() end,
        ChatCommand = function(Text)
            local ok, Done = pcall(P.ChatCommand, Text)
            return ok and Done == true
        end,
        Shutdown = function(Reason)
            local ok, err = pcall(P.Shutdown, Reason)
            if not ok then Log("Server-Ende: %s", tostring(err)) end
        end,
        -- E28 (PLAYER-25, Host; server.lua Srv.EndProtect): eigener Angriff beendet die Respawn-Haltezeit dieser Figur
        -- (Host-FName). Nur vormerken, P.HoldStep gibt im naechsten pl_host-Takt frei. true = Haltezeit gefunden
        EndHold = function(PawnName)
            if Net.Side ~= "host" or type(PawnName) ~= "string" or not P.RespawnOn() then return false end
            for _, H in pairs(P.H) do
                if H.Resp and H.Resp.Name == PawnName then
                    H.Resp.Ended = true
                    return true
                end
            end
            return false
        end,
    }
    P.Caps()
    -- Flags koennen zur Laufzeit wechseln: Faehigkeiten jede Sekunde nachziehen (Net.Cap meldet nur Aenderungen)
    Core.Every("pl_caps", 1, P.Caps)
    Core.Every("pl_host", 0.2, P.HostFast)
    Core.Every("pl_guest", 0.1, P.ClientFast)
    Core.Every("pl_sess", 0.5, P.SessionTick)
    A.TestCommands.shutdown = function()
        A.TestLog("shutdown: speichere Gaeste, bye, dann stop")
        P.Shutdown("Testbefehl")
        local Srv = A.Coop.Server
        if Srv and Srv.Commands and Srv.Commands.stop then Srv.Commands.stop() end
    end
    A.TestCommands.pl_state = function()
        local Parts = {}
        for Key, H in pairs(P.H) do
            Parts[#Parts + 1] = string.format("%s pawn=%s dead=%s resp=%s bed=%s", Key:match("[^.:]+$") or Key,
                tostring(H.Pawn), tostring(H.Dead), tostring(H.Resp and H.Resp.Name), tostring(H.BedLast))
        end
        local C = P.C
        Parts[#Parts + 1] = string.format("gast dead=%s phase=%s last=%s permahits=%d", tostring(C.Dead),
            tostring(C.Phase), tostring(C.LastAlive), P.PermaHits)
        A.TestLog("pl_state: %s", table.concat(Parts, " | "))
    end
    A.TestCommands.pl_cmd = function(Arg) A.TestLog("pl_cmd %s: %s", tostring(Arg), tostring(P.ChatCommand("/" .. tostring(Arg)))) end
    Log("geladen (respawn_v2=%s, death_guard=%s, bed_v2=%s, session_v2=%s)", tostring(P.RespawnOn()),
        tostring(Flag("death_guard")), tostring(Flag("bed_v2")), tostring(Flag("session_v2")))
end

M.P = P   -- Diagnose (ls_test)
return M
