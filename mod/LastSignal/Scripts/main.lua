-- Last Signal (intern frueher NetTest): Koop-Multiplayer fuer SurrounDead mit der eingebauten Unreal-Netzwerktechnik.
--   F7 = Diagnose ins UE4SS-Log schreiben
--   F8 = Host-Modus: Menue als Listen-Server oeffnen, danach Spielstand laden
--   F9 = zu host_ip.txt verbinden (steam.<SteamID64> im Steam-Modus, IP/Domain[:Port] im IP-Modus)
--   netmode.txt = "steam" oder "ip" (IP-Modus: UDP-Port 7777 beim Host freigeben)
--   F5 = Mappings.usmap fuer die Blueprint-Analyse erzeugen
--   F6 = Menues schliessen (Client, passiert nach dem Beitritt auch automatisch)
--   F10 = Unreal-Konsole (vom ConsoleEnablerMod), dort geht auch: open <IP>

local UEHelpers = require("UEHelpers")

local MOD_DIR = "ue4ss/Mods/LastSignal/"
local MAX_PLAYERS = 8

local function Log(fmt, ...)
    print(string.format("[LastSignal] " .. fmt .. "\n", ...))
end

-- FindAllOf liefert auch Objekte, die gerade zerstoert werden. Funktionen darauf aufzurufen
-- kann das Spiel abstuerzen lassen, darum vorher pruefen.
-- Runde 9 CORE-27: dieselben drei Pruefungen, aber ohne neue Closures je Aufruf (tausende Aufrufe je Sekunde). Die
-- Pruef-Funktionen liegen als LS_-Felder in _G (rawset wie LS_ACTOR_CLS; keine neuen Hauptteil-Locals).
rawset(_G, "LS_ValidCall", function(Object) return Object:IsValid() end)
rawset(_G, "LS_DyingCall", function(Object)
    return Object:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)
        or Object:HasAnyInternalFlags(EInternalObjectFlags.Unreachable)
end)
rawset(_G, "LS_GoneCall", function(Object)
    local AC = rawget(_G, "LS_ACTOR_CLS")
    if AC == nil then AC = StaticFindObject("/Script/Engine.Actor") or false rawset(_G, "LS_ACTOR_CLS", AC) end
    return AC ~= false and Object:IsA(AC) and Object.bActorIsBeingDestroyed == true
end)
local function IsAlive(Object)
    -- Nur echte Unreal-Objekte (userdata); alles andere (z. B. beim Trennen eines Mitspielers) als tot werten
    if type(Object) ~= "userdata" then return false end
    local okValid, Valid = pcall(rawget(_G, "LS_ValidCall"), Object)
    if not okValid or not Valid then return false end
    local ok, Dying = pcall(rawget(_G, "LS_DyingCall"), Object)
    if not ok or Dying then return false end   -- Fehler bei der Pruefung: lieber als tot werten
    -- UE 5.6: zerstoerte Actors bleiben bis zur GC (~61 s) IsValid und ohne PendingKill/Unreachable (FindAllOf findet sie
    -- weiter: Layout/Geister/Boden-Doppel alle 5 s erneut 'entfernt'). AActor.bActorIsBeingDestroyed ist in 5.6 reflektiert.
    if rawget(_G, "LS_ALIVE_V56") == false then return true end
    local okD, Gone = pcall(rawget(_G, "LS_GoneCall"), Object)
    return not (okD and Gone)
end

local function Safe(fn, fallback)
    local ok, result = pcall(fn)
    if ok then return result end
    return fallback
end

-- Schalter fuer A/B-Tests ohne neuen Build: coop.txt im Mod-Ordner, Zeilen "name=0" oder "name=1"
-- (Zahl-Schalter: "name=<Zahl>"). Zeilen mit # davor sind Kommentare.
--   trust_movement   Host uebernimmt die Position des Mitspielers (gegen Ruckeln)
--   replay_possessed Spieler-Einrichtung des Spiels beim Mitspieler nachholen
--   frame_walk       nativer Hook folgt der Blueprint-Aufrufkette (noetig fuer Respawn)
--   save_before_join Mitspieler speichert seinen Spielstand, bevor er beitritt
--   save_back        Mitspieler schreibt sein Inventar vom Host in seinen eigenen Spielstand
--                    (beides im lokalen Zwei-Instanzen-Test aus: beide teilen einen Spielstand)
--   local_inventory  nur beim Host: 1 = Mitspieler bringen ihr lokales Inventar mit und bekommen es
--                    zurueckgeschrieben (wie Valheim), 0 = Inventar bleibt auf dem Server (Standard)
--   dev              Entwickler-Tasten F4-F7 (Messung, USMAP, Client-Einrichtung, Diagnose); fuer Spieler aus
--   test             Testbefehle aus test_cmd.txt ausfuehren (lokaler Zwei-Instanzen-Test; dev=1 erlaubt sie auch)
--   car_hz           Zahl: Fahrzeug-Posen pro Sekunde (Standard 30, sinnvoll 15-60; 0 = alter Weg mit 15)
--   corpse_v2        Leichen ohne Ragdoll-Sync (nur nahe Leichen relevant, Fallen nur lokal)
--   attach_v2        Waffenaufsaetze sofort einbauen (alle angehaengten Waffen, nicht nur die in der Hand)
--   hp_v2            Zombie-Leben mit festen IDs und nur bei Aenderung senden
--   join_v2          Beitritt direkt am Ziel hinter dem Ladebildschirm (nur Server-Inventarmodus)
--   spawner_stop     Zahl: Spawner beim Mitspieler stoppen, 0 = aus, 1 = Invoker-Variante, 2 = Spawner-Variante (Standard)
--   cloth_fast       Kleidung entprellt nachschicken (0,5 s stabil, nur die geaenderte Figur, 3 s Ruhe nach dem
--                    Inventar-Abgleich); 0 = bisheriger Weg
--   attach_partial   Waffenaufsaetze auch bei "teilweise eingebaut" einmal nachholen (nach 1,5 s ohne Aenderung)
--   consume_fix      Mitspieler: Gegenstand nach dem Verbrauch (leere Flasche) legt der Server vor die Fuesse
--                    (aus seit Runde 3: der Hook loeste nie aus, ersetzt durch inv_reconcile)
--   drop_mode        Zahl, nur Server: Cheat-Gegenstaende vor die Fuesse, 0 = selbst spawnen (bisher), 1 = ins
--                    Inventar und per Spiel fallen lassen (AddNewItemSomewhere + HandleServerDropRequest),
--                    2 = Fallenlassen des Spiels (RequestDropAsPickup); zur Laufzeit: Testbefehl "dropmode <0|1|2>"
--   attach_flags     Mitspieler: Schalldaempfer-/Visier-Flags der Waffe nach dem Einbau und beim Ziehen pruefen und
--                    richtigstellen (Schuss klang nach dem Wiederbeitritt ungedaempft)
--   inv_reconcile    Mitspieler: blinkende (wartende) Gegenstaende > 3 s -> leere Flasche u. ae. beim Server anlegen
--                    lassen ("pend"), sonst Inventar neu abgleichen (hoechstens alle 10 s)
local SETTINGS = { trust_movement = true, replay_possessed = false, frame_walk = true,
                   save_before_join = true, save_back = true, local_inventory = false, dev = false,
                   test = false, car_hz = 30, corpse_v2 = true, attach_v2 = true, hp_v2 = true, join_v2 = true,
                   spawner_stop = 2, cloth_fast = true, attach_partial = false, consume_fix = false,
                   drop_mode = 0, attach_flags = true, inv_reconcile = false }

local function LoadSettings()
    local File = io.open(MOD_DIR .. "coop.txt", "r")
    if not File then return end
    for Line in File:lines() do
        local Key, Value = Line:match("^%s*([%w_]+)%s*=%s*(%d+)")
        -- Zahl-Schalter (Standard ist eine Zahl) ganz lesen, Ein/Aus wie bisher nach der ersten Ziffer
        if Key and type(SETTINGS[Key]) == "number" then SETTINGS[Key] = tonumber(Value)
        elseif Key and SETTINGS[Key] ~= nil then SETTINGS[Key] = Value:sub(1, 1) == "1" end
    end
    File:close()
end
LoadSettings()

local function NetModeName(World)
    local KSL = UEHelpers.GetKismetSystemLibrary()
    if KSL:IsDedicatedServer(World) then return "DedicatedServer" end
    if KSL:IsStandalone(World) then return "Standalone" end
    if KSL:IsServer(World) then return "ListenServer" end
    return "Client"
end

-- "World /Game/Maps/Foo.Foo" -> "/Game/Maps/Foo"
local function MapPath(World)
    local FullName = World:GetFullName()
    return FullName:match("^%S+%s+([^%.]+)")
end

local function RaiseMaxPlayers()
    local GameMode = UEHelpers.GetGameModeBase()
    if not GameMode:IsValid() then return end
    local Session = GameMode.GameSession
    -- Server-Modus (server.lua) legt die Zahl fest, sonst nur anheben
    local Wanted, Fixed = SETTINGS.max_players or MAX_PLAYERS, SETTINGS.max_players ~= nil
    if Session:IsValid() and (Session.MaxPlayers < Wanted or (Fixed and Session.MaxPlayers ~= Wanted)) then
        Log("GameSession.MaxPlayers %d -> %d", Session.MaxPlayers, Wanted)
        Session.MaxPlayers = Wanted
    end
end

-- Netzwerkmodus aus netmode.txt: "steam" (Steam-P2P, Standard des Spiels) oder "ip"
-- (normales UDP ueber IpNetDriver, braucht eine Portfreigabe beim Host, Standardport 7777).
local IP_DRIVER = "/Script/OnlineSubsystemUtils.IpNetDriver"
local NetDriverMode = "steam"
local OriginalDriverClass = nil

local function ReadNetDriverMode()
    local File = io.open(MOD_DIR .. "netmode.txt", "r")
    if not File then return "steam" end
    local Mode = ((File:read("*l") or ""):match("^%s*(%a+)") or "steam"):lower()
    File:close()
    return Mode == "ip" and "ip" or "steam"
end

-- Im IP-Modus muss [OnlineSubsystemSteam] bUseSteamNetworking=false gelten, sonst laeuft der IpNetDriver ueber
-- Steam-Sockets und der Beitritt per IP scheitert sofort. UE 5.6 schreibt Saved\Config\Windows\Engine.ini beim
-- Beenden neu und laesst den Eintrag dabei weg (24.10.: jeder zweite Start ohne Beitritt). Darum zusaetzlich
-- <Spiel>\SurrounDead\Config\UserEngine.ini (Konfig-Ebene GameDirUser: Unreal liest sie, schreibt sie nie).
-- Fehlt sie, legt der Mod sie an; das wirkt erst ab dem naechsten Spielstart.
-- Rueckgabe: true = fuer diesen Start aktiv; sonst false und "neu" (eben angelegt) bzw. nil (nicht schreibbar).
local function SteamNetworkingDisabledInIni()
    local function Has(Path)
        local File = io.open(Path, "r")
        if not File then return false end
        local InSection, Disabled = false, false
        for Line in File:lines() do
            local Section = Line:match("^%s*%[(.-)%]")
            if Section then InSection = Section == "OnlineSubsystemSteam" end
            if InSection and Line:lower():match("^%s*busesteamnetworking%s*=%s*false") then Disabled = true end
        end
        File:close()
        return Disabled
    end
    local User = "..\\..\\Config\\UserEngine.ini"   -- Arbeitsordner ist Binaries\Win64
    if Has(User) then return true end
    local Saved = Has((os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\Config\\Windows\\Engine.ini")
    local Out = io.open(User, "a")
    if not Out then return Saved, nil end
    Out:write("\r\n[OnlineSubsystemSteam]\r\nbUseSteamNetworking=false\r\n")
    Out:close()
    return Saved, "neu"
end

local function GameNetDriverDefinition()
    local Engine = UEHelpers.GetEngine()
    if not IsAlive(Engine) then return nil end   -- CORE-20
    local Defs = Engine.NetDriverDefinitions
    for i = 1, #Defs do
        if Defs[i].DefName:ToString() == "GameNetDriver" then return Defs[i] end
    end
    return nil
end

-- Muss vor F8/F9 laufen: Unreal liest die Definition jedes Mal, wenn ein NetDriver erzeugt wird.
local function ApplyNetDriverMode()
    NetDriverMode = ReadNetDriverMode()
    local ok, err = pcall(function()
        local Def = GameNetDriverDefinition()
        if not Def then Log("GameNetDriver-Definition nicht gefunden") return end
        OriginalDriverClass = OriginalDriverClass or Def.DriverClassName:ToString()
        local Wanted = NetDriverMode == "ip" and IP_DRIVER or OriginalDriverClass
        if Def.DriverClassName:ToString() ~= Wanted then
            Def.DriverClassName = FName(Wanted)
            Def.DriverClassNameFallback = FName(Wanted)
        end
        Log("Netzwerkmodus %s: GameNetDriver = %s (Fallback %s)", NetDriverMode,
            Def.DriverClassName:ToString(), Def.DriverClassNameFallback:ToString())
    end)
    if not ok then Log("Netzwerkmodus setzen fehlgeschlagen: %s", tostring(err)) end
end

local function Diagnose()
    local World = UEHelpers.GetWorld()
    if not World:IsValid() then Log("Keine World gefunden") return end

    Log("===== Diagnose =====")
    Log("Netzwerkmodus: %s, IpNetDriver-Klasse vorhanden: %s", NetDriverMode,
        tostring(Safe(function() return StaticFindObject(IP_DRIVER):IsValid() end, false)))
    Log("Karte:     %s", tostring(MapPath(World)))
    Log("NetMode:   %s", NetModeName(World))

    local NetDriver = Safe(function() return World.NetDriver end)
    if NetDriver and NetDriver:IsValid() then
        Log("NetDriver: %s", NetDriver:GetClass():GetFullName())
        local Conns = Safe(function() return #NetDriver.ClientConnections end, "?")
        Log("Client-Verbindungen: %s", tostring(Conns))
    else
        Log("NetDriver: keiner (Spiel laeuft offline)")
    end

    local GameMode = UEHelpers.GetGameModeBase()
    if GameMode:IsValid() then
        Log("GameMode:  %s", GameMode:GetClass():GetFullName())
        local Session = GameMode.GameSession
        if Session:IsValid() then Log("MaxPlayers: %d", Session.MaxPlayers) end
    else
        Log("GameMode:  nicht vorhanden (normal auf dem Client)")
    end

    local GameState = UEHelpers.GetGameStateBase()
    if GameState:IsValid() then Log("GameState: %s", GameState:GetClass():GetFullName()) end

    local Pawn = UEHelpers.GetPlayer()
    if Pawn:IsValid() then
        Log("Spielfigur: %s", Pawn:GetClass():GetFullName())
        Log("  bReplicates=%s  HasAuthority=%s",
            tostring(Safe(function() return Pawn.bReplicates end, "?")),
            tostring(Safe(function() return Pawn:HasAuthority() end, "?")))
    end

    -- CORE-20: UEHelpers.GetAllPlayers liest PawnPrivate ungeprueft -> eigene Liste (FindAllOf, IsAlive je Figur unten)
    local Players = FindAllOf("BP_PlayerCharacter_C") or {}
    Log("Spielfiguren in der Welt: %d", #Players)
    for i, P in ipairs(Players) do
        if IsAlive(P) then Log("  [%d] %s", i, P:GetFullName()) end
    end

    RaiseMaxPlayers()
end

local function RunCommand(Command)
    local World = UEHelpers.GetWorld()
    local PC = UEHelpers.GetPlayerController()
    -- Die Adresse eines Servers steht nie im Log des Spielers (nur "open <Karte>?listen" des Hosts)
    Log("Befehl: %s", (Command:match("^open ") and not Command:find("?listen", 1, true)) and "open <Server>" or Command)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(World, Command, PC)
end

-- Hauptmenue und Spiel sind dieselbe Karte, und "Spielstand laden" laedt keine neue Karte
-- (getestet: kein LoadMap). Darum: erst das Menue als Listen-Server oeffnen (F8), dann den
-- Spielstand laden. Die Welt bleibt dabei Listen-Server.
local HostMode = false

local function StartHostMode()
    -- Nur der dedizierte Server darf hosten (start.sh setzt LASTSIGNAL_SERVER=1), Koop aus dem eigenen Spiel ist gesperrt
    if os.getenv("LASTSIGNAL_SERVER") ~= "1" and os.getenv("NETTEST_SERVER") ~= "1" then
        Log("Hosten ist nur auf einem Last-Signal-Server moeglich")
        return
    end
    local World = UEHelpers.GetWorld()
    if not World:IsValid() then Log("Keine World gefunden") return end
    HostMode = true
    if NetModeName(World) ~= "Standalone" then
        Log("Host-Modus AN, laeuft bereits als %s. Jetzt Spielstand laden.", NetModeName(World))
        return
    end
    local Path = MapPath(World)
    if not Path then Log("Kartenpfad nicht erkannt: %s", World:GetFullName()) return end
    ApplyNetDriverMode()
    Log("Host-Modus AN. Oeffne das Menue als Listen-Server, danach Spielstand laden.")
    RunCommand("open " .. Path .. "?listen")
end

local function Unwrap(Param)
    local ok, Value = pcall(function() return Param:get() end)
    if ok and Value ~= nil then return Value end
    return Param
end

-- Weltwechsel (Beitritt, Kick, zurueck in den eigenen Spielstand): Jede geladene Karte zaehlt hoch. Gemerkte
-- Spielobjekte der alten Welt sind dann freigegeben; wer sie danach anfasst (auch IsAlive), laesst das Spiel mit
-- EXCEPTION_ACCESS_VIOLATION abstuerzen, das faengt kein pcall. Coop.DropWorldRefs vergisst sie (Schnell-Loop und
-- Hauptschleife pruefen N). Loading: zwischen Vor- und Nach-Hook nichts anfassen (hoechstens 60 s).
local WorldGen = { N = 0, Loading = false, LoadingAt = 0 }
if type(RegisterLoadMapPreHook) == "function" then
    pcall(RegisterLoadMapPreHook, function()
        WorldGen.N, WorldGen.Loading, WorldGen.LoadingAt = WorldGen.N + 1, true, os.clock()
    end)
end

RegisterLoadMapPostHook(function(_, World)
    WorldGen.N, WorldGen.Loading = WorldGen.N + 1, false
    local W = Unwrap(World)
    if W and W:IsValid() then Log("LoadMap fertig, NetMode=%s", NetModeName(W)) end
end)

RegisterHook("/Script/Engine.GameplayStatics:OpenLevel", function(_, _, LevelName, _, Options)
    Log("OpenLevel(%s, options='%s')", LevelName:get():ToString(), Options:get():ToString())
end)

-- Hauptmenue und Spiel sind dieselbe Karte. Verbindet man, waehrend das Menue noch laedt oder
-- streamt, laedt die Engine die Karte doppelt und stuerzt ab ("RecastNavMesh ... does not have all
-- load flags"). Darum erst verbinden, wenn kein Lade-/Startbildschirm offen ist und das Menue
-- seit ein paar Sekunden steht; sonst merken und automatisch nachholen.
local MENU_SETTLE, CONNECT_GIVE_UP = 3, 90
local MenuVisibleSince, PendingConnectSince = nil, nil

local function VisibleWidget(ClassName)
    for _, Widget in ipairs(FindAllOf(ClassName) or {}) do
        if IsAlive(Widget) and Widget:IsInViewport() then return true end
    end
    return false
end

local function ReadyToTravel()
    if VisibleWidget("LoadingScreenWidget_C") or VisibleWidget("PressAnyKeyWidget_C") then
        MenuVisibleSince = nil
        return false, "Lade-/Startbildschirm offen"
    end
    if not VisibleWidget("MenuWidget_C") then return true end  -- z. B. aus einem Einzelspieler-Spiel
    MenuVisibleSince = MenuVisibleSince or os.time()
    if os.time() - MenuVisibleSince < MENU_SETTLE then return false, "Hauptmenue laedt noch" end
    return true
end

-- Beitreten nur aus dem eigenen Spielstand (wie Valheim): Der Mitspieler bringt seinen Charakter
-- mit (Aussehen, Inventar aus Save_Player). Vorher speichert er, damit der Stand aktuell ist.
local JOIN_SAVE_TIMEOUT = 20
local JoinSaveStarted = nil

local function InOwnSave(World)
    if NetModeName(World) ~= "Standalone" or VisibleWidget("MenuWidget_C") then return false end
    local PC = UEHelpers.GetPlayerController()
    local Pawn = PC and PC:IsValid() and PC:K2_GetPawn()
    return Pawn and Pawn:IsValid() and Pawn:GetClass():GetFName():ToString() == "BP_PlayerCharacter_C"
end

local function SaveBeforeJoin(World)
    if not SETTINGS.save_before_join then return true end
    local EMS = StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary")
    if not JoinSaveStarted then
        JoinSaveStarted = os.time()
        local ok, err = pcall(function()
            local PC = UEHelpers.GetPlayerController()
            if not IsAlive(PC) then error("kein PlayerController") end
            PC:SaveGameToSlot()
        end)
        Log("Speichere eigenen Spielstand vor dem Beitritt: %s", ok and "gestartet" or tostring(err))
        return false
    end
    local Busy = IsAlive(EMS) and Safe(function() return EMS:IsSavingOrLoading(World) end, false) or false   -- CORE-20
    if (Busy or os.time() - JoinSaveStarted < 2) and os.time() - JoinSaveStarted < JOIN_SAVE_TIMEOUT then
        return false
    end
    return true
end

local function ConnectToHost()
    -- Ein zweites "open" bricht den laufenden Verbindungsaufbau ab.
    local World = UEHelpers.GetWorld()
    if World:IsValid() and NetModeName(World) == "Client" then
        Log("Verbindung laeuft bereits, bitte warten. Abbrechen: F10 und 'disconnect'.")
        return
    end
    if not InOwnSave(World) then
        PendingConnectSince, JoinSaveStarted = nil, nil
        Log("Beitreten geht nur aus dem eigenen Spielstand: erst Spielstand laden (Continue/Load), dann im Journal (J) die Serverliste")
        return
    end
    if not SaveBeforeJoin(World) then
        PendingConnectSince = PendingConnectSince or os.time()
        return
    end
    JoinSaveStarted = nil
    local Ready, Reason = ReadyToTravel()
    if not Ready then
        if not PendingConnectSince then
            PendingConnectSince = os.time()
            Log("Verbinden wartet: %s - verbinde automatisch, sobald das Menue bereit ist", Reason)
        end
        return
    end
    PendingConnectSince = nil
    -- Aus der Serverliste (Journal, Coop.List): Adresse nur im Speicher. Sonst host_ip.txt (F9).
    -- (Globale Tabelle: Coop wird erst weiter unten angelegt.)
    local Join, Address = rawget(_G, "LastSignalJoin"), nil
    if Join and Join.Address then
        Address, Join.Address = Join.Address, nil
        Log("Verbinde mit '%s' (Serverliste)", tostring(Join.Name))
    elseif Join and Join.Direct then
        -- Nur fuer Tests (test_cmd "connect"): direkt zur Adresse in host_ip.txt. Fuer Spieler gesperrt (kein F9).
        Join.Direct = nil
        local File = io.open(MOD_DIR .. "host_ip.txt", "r")
        if not File then Log("%shost_ip.txt fehlt", MOD_DIR) return end
        Address = (File:read("*l") or ""):match("^%s*(%S+)")
        File:close()
    else
        Log("Direktes Verbinden ist gesperrt: Server in der Serverliste (Journal, J) waehlen")
        return
    end
    if not Address or Address == "" then Log("host_ip.txt ist leer") return end
    ApplyNetDriverMode()
    local IsSteamAddress = Address:lower():find("^steam%.") ~= nil
    if NetDriverMode == "ip" and IsSteamAddress then
        Log("IP-Modus aktiv, aber host_ip.txt enthaelt eine Steam-ID. Bitte IP oder Domain eintragen.")
        return
    end
    if NetDriverMode == "steam" and not IsSteamAddress then
        Log("Steam-Modus aktiv, aber host_ip.txt enthaelt keine Steam-ID. Fuer IP: netmode.txt auf 'ip' setzen.")
        return
    end
    if Join then Join.OpenAt = os.time() end   -- Hauptschleife: Verbindungs-Beobachter jede Sekunde, solange es laeuft
    RunCommand("open " .. Address)
end

if SETTINGS.dev then RegisterKeyBind(Key.F7, function() ExecuteInGameThread(Diagnose) end) end
-- Last Signal ist nur fuer grosse Server: Koop aus dem eigenen Spiel (F8 hosten, F9 direkt per IP verbinden)
-- bleibt im Code, ist aber gesperrt (Absprache: Koop macht ein anderer Mod). Beitreten nur ueber die
-- Serverliste im Journal (J); hosten nur der dedizierte Server (LASTSIGNAL_SERVER=1).

-- Nach jedem Kartenwechsel als Host die Spielerzahl anheben, sonst lehnt der Server Clients ab.
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteInGameThread(function()
        local World = UEHelpers.GetWorld()
        if World:IsValid() then
            Log("ClientRestart, NetMode=%s", NetModeName(World))
            RaiseMaxPlayers()
        end
    end)
end)

-- Netzwerkfehler mitschreiben. Shipping-Builds haben kein Engine-Log, das hier ist die einzige Quelle.
local NETWORK_FAILURES = {
    [0] = "NetDriverAlreadyExists", "NetDriverCreateFailure", "NetDriverListenFailure",
    "ConnectionLost", "ConnectionTimeout", "FailureReceived", "OutdatedClient", "OutdatedServer",
    "PendingConnectionFailure", "NetGuidMismatch", "NetChecksumMismatch",
}
local TRAVEL_FAILURES = {
    [0] = "NoLevel", "LoadMapFailure", "InvalidURL", "PackageMissing", "PackageVersion",
    "NoDownload", "TravelFailure", "CheatCommands", "PendingNetGameCreateFailure",
    "CloudSaveFailure", "ServerTravelFailure", "ClientTravelFailure",
}

local function TryHook(Path, Callback, PostCallback)
    local ok, PreId, PostId = pcall(RegisterHook, Path, Callback, PostCallback)
    if not ok then Log("Hook fehlgeschlagen %s: %s", Path, tostring(PreId)) return nil end
    return { Path = Path, PreId = PreId, PostId = PostId }
end

TryHook("/Script/Engine.GameInstance:HandleNetworkError", function(_, FailureType, bIsServer)
    local T = FailureType:get()
    Log("NETZWERKFEHLER: %s (%s), Server=%s", NETWORK_FAILURES[T] or "?", tostring(T), tostring(bIsServer:get()))
end)

TryHook("/Script/Engine.GameInstance:HandleTravelError", function(_, FailureType)
    local T = FailureType:get()
    Log("REISEFEHLER: %s (%s)", TRAVEL_FAILURES[T] or "?", tostring(T))
end)

TryHook("/Script/Engine.PlayerController:ClientWasKicked", function(_, KickReason)
    Log("GEKICKT: %s", Safe(function() return KickReason:get():ToString() end, "?"))
end)

-- Jede Sekunde den Netzwerkzustand pruefen und Aenderungen loggen, damit niemand F7 im
-- richtigen Moment druecken muss.
local LastState = nil

local function NetState()
    local World = UEHelpers.GetWorld()
    if not World:IsValid() then return "keine World" end
    local Parts = { "NetMode=" .. NetModeName(World) }
    local NetDriver = Safe(function() return World.NetDriver end)
    if NetDriver and NetDriver:IsValid() then
        Parts[#Parts + 1] = "Verbindungen=" .. tostring(Safe(function() return #NetDriver.ClientConnections end, "?"))
        local ServerConn = Safe(function() return NetDriver.ServerConnection end)
        if ServerConn and ServerConn:IsValid() then Parts[#Parts + 1] = "mitServerVerbunden" end
    end
    local GameState = UEHelpers.GetGameStateBase()
    if GameState:IsValid() then
        Parts[#Parts + 1] = "Spieler=" .. tostring(Safe(function() return #GameState.PlayerArray end, "?"))
    end
    Parts[#Parts + 1] = "Figuren=" .. tostring(#(FindAllOf("BP_PlayerCharacter_C") or {}))   -- CORE-20: ohne GetAllPlayers
    return table.concat(Parts, " ")
end

-- Verbindungsobjekte (NetConnection, PendingNetGame) per Reflection beobachten. Damit sehen wir,
-- an welcher Stelle des Handshakes es haengt, obwohl das Spiel selbst nichts loggt.
local WATCHED_CLASSES = { "NetConnection", "SteamSocketsNetConnection", "IpConnection", "PendingNetGame" }
local NOISY_PROPS = { "time", "stat", "bytes", "packet", "ack", "seq", "rate", "lag", "frame" }
local Watched = {}

local function IsNoisy(Name)
    local Lower = Name:lower()
    for _, Pattern in ipairs(NOISY_PROPS) do
        if Lower:find(Pattern, 1, true) then return true end
    end
    return false
end

local function SimpleValue(Object, Property)
    local Name = Property:GetFName():ToString()
    local V = Object[Name]
    if Property:IsA(PropertyTypes.BoolProperty) then return V and "true" or "false" end
    if Property:IsA(PropertyTypes.IntProperty) or Property:IsA(PropertyTypes.Int64Property)
        or Property:IsA(PropertyTypes.FloatProperty) or Property:IsA(PropertyTypes.ByteProperty) then
        return tostring(V)
    end
    if Property:IsA(PropertyTypes.EnumProperty) then
        return Property:GetEnum():GetNameByValue(V):ToString()
    end
    if Property:IsA(PropertyTypes.NameProperty) or Property:IsA(PropertyTypes.StrProperty) then
        return V:ToString()
    end
    if Property:IsA(PropertyTypes.ObjectProperty) then
        return V:IsValid() and V:GetFName():ToString() or "nil"
    end
    return nil
end

local function DumpObject(Object)
    local Props = {}
    local Class = Object:GetClass()
    while Class and Class:IsValid() do
        Class:ForEachProperty(function(Property)
            local Name = Property:GetFName():ToString()
            if not IsNoisy(Name) then
                local ok, Value = pcall(SimpleValue, Object, Property)
                if ok and Value ~= nil then Props[Name] = Value end
            end
        end)
        Class = Class:GetSuperStruct()
    end
    return Props
end

local function SortedKeys(T)
    local Keys = {}
    for K in pairs(T) do Keys[#Keys + 1] = K end
    table.sort(Keys)
    return Keys
end

local function WatchConnections()
    local Seen = {}
    for _, ClassName in ipairs(WATCHED_CLASSES) do
        for _, Object in ipairs(FindAllOf(ClassName) or {}) do
            if IsAlive(Object) then
                local Key = Object:GetFullName()
                if not Seen[Key] and not Key:find("Default__", 1, true) then
                    Seen[Key] = true
                    local Props = DumpObject(Object)
                    local Old = Watched[Key]
                    if not Old then
                        local Parts = {}
                        for _, K in ipairs(SortedKeys(Props)) do Parts[#Parts + 1] = K .. "=" .. Props[K] end
                        Log("NEU %s: %s", Key, table.concat(Parts, " "))
                    else
                        for _, K in ipairs(SortedKeys(Props)) do
                            if Old[K] ~= Props[K] then
                                Log("%s.%s: %s -> %s", Object:GetFName():ToString(), K, tostring(Old[K]), Props[K])
                            end
                        end
                    end
                    Watched[Key] = Props
                end
            end
        end
    end
    for Key in pairs(Watched) do
        if not Seen[Key] then
            Log("WEG %s", Key)
            Watched[Key] = nil
        end
    end
end

-- UEHelpers.GetWorld/GetPlayerController durchsuchen bei jedem Aufruf alle Objekte. Jede Sekunde
-- mehrfach aufgerufen ergibt das spuerbare Ruckler, darum den lokalen PlayerController merken.
local CachedPC = nil

local function LocalPC()
    -- world_hygiene (CORE-8): gemerkter Controller gilt nur in der Welt, in der er gefunden wurde; nach einem Weltwechsel
    -- oder waehrend des Ladens nie anfassen (auch IsAlive auf freigegebenem Speicher stuerzt ab). Schalter steht in
    -- WorldGen.Hygiene (Coop.Hygiene, Coop ist hier noch nicht sichtbar); nil = an.
    if WorldGen.Hygiene ~= false and (WorldGen.PCGen ~= WorldGen.N
        or (WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60)) then
        CachedPC = nil
    end
    if CachedPC and IsAlive(CachedPC) and Safe(function() return CachedPC:IsLocalController() end, false) then
        return CachedPC
    end
    -- UEHelpers nimmt den ersten PlayerController - auf dem Host kann das der des Mitspielers sein.
    for _, PC in ipairs(FindAllOf("PlayerController") or {}) do
        if IsAlive(PC) and Safe(function() return PC:IsLocalController() end, false) then
            CachedPC, WorldGen.PCGen = PC, WorldGen.N
            return PC
        end
    end
    CachedPC = nil
    return UEHelpers.GetPlayerController()
end

local function CurrentWorld()
    local PC = LocalPC()
    if PC and PC:IsValid() then return PC:GetWorld() end
    return UEHelpers.GetWorld()
end

local function PlayerStates(World)
    local States = {}
    if not IsAlive(World) then return States end
    local GameState = Safe(function() return World.GameState end)
    if not (GameState and IsAlive(GameState)) then return States end
    local Array = GameState.PlayerArray
    for i = 1, #Array do
        local PS = Array[i]
        if IsAlive(PS) then States[#States + 1] = PS end
    end
    return States
end

-- Lua erlaubt nur 200 lokale Variablen pro Datei: neuere Teile stehen in do-Bloecken und
-- reichen nur das nach aussen, was der Rest braucht.
local Coop = {}

-- Runde 9: Schalter eines neuen Wegs ueber ls_core (Core.Flag: coop.txt, FLAG_DOWN, profile=legacy); vor dem Laden der
-- Module bzw. ohne ls_core gilt Default. Nur Ein/Aus (true/false). Coop.FlagFail: Fehler des neuen Wegs an Core.Fail
-- melden (mehr als 3 in 60 s -> Schalter fuer diese Sitzung aus = alter Weg). Felder in Coop: keine neuen Locals.
function Coop.FlagOn(Name, Default)
    local LC = Coop.Modules and Coop.Modules.ls_core
    if not (LC and LC.Flag) then return Default end
    local ok, Value = pcall(LC.Flag, Name, Default)
    if not ok then return Default end
    return Value == true
end
function Coop.FlagFail(Name, Err)
    local LC = Coop.Modules and Coop.Modules.ls_core
    if LC and LC.Fail then pcall(LC.Fail, Name, Err) return end
    Coop.FailLogged = Coop.FailLogged or {}
    if not Coop.FailLogged[Name] then Coop.FailLogged[Name] = true Log("Fehler in %s: %s", Name, tostring(Err)) end
end

-- Runde 9 CORE-20: Klassen-Standardobjekt (CDO, z. B. "/Script/Engine.Default__GameplayStatics") oder nil. Gemerkt, aber
-- bei jeder Nutzung mit IsAlive geprueft (StaticFindObject liefert sonst eine ungueltige Huelle, deren Methodenaufruf
-- nativ abstuerzt). Coop.DropWorldRefsHygiene leert den Merker.
Coop.CdoCache = {}
function Coop.Cdo(Path)
    local O = Coop.CdoCache[Path]
    if O and IsAlive(O) then return O end
    O = StaticFindObject(Path)
    Coop.CdoCache[Path] = IsAlive(O) and O or nil
    return Coop.CdoCache[Path]
end

-- Runde 9 CORE-27 (perf_hotpath): NetModeName fragt je Aufruf 3 UFunctions ab (~20 Aufrufe je Hauptschleife plus jede
-- Aufgabe). Ergebnis je Welt (Adresse + WorldGen.N) 0,05 s merken. Die Funktion oben bleibt Coop.ModeRaw; der lokale Name
-- NetModeName wird nur neu belegt (kein neues Local, alle Aufrufer sehen die neue Funktion). Coop.ModeOn setzt die
-- Hauptschleife je Durchlauf aus dem Schalter (bis zum ersten Durchlauf: alter Weg).
Coop.ModeRaw, Coop.ModeCache = NetModeName, { At = -1 }
NetModeName = function(World)
    if not Coop.ModeOn or type(World) ~= "userdata" then return Coop.ModeRaw(World) end
    local okA, Addr = pcall(World.GetAddress, World)
    if not okA then return Coop.ModeRaw(World) end
    local MC, Now = Coop.ModeCache, os.clock()
    if MC.Addr == Addr and MC.Gen == WorldGen.N and Now - MC.At < 0.05 then return MC.Mode end
    local Mode = Coop.ModeRaw(World)
    MC.Addr, MC.Gen, MC.At, MC.Mode = Addr, WorldGen.N, Now, Mode
    return Mode
end

-- TArray-Rueckgabewerte von UFunctions kommen in UE4SS als Lua-Tabelle (1-basiert), Array-Eigenschaften
-- als TArray-Userdata. Beides hier in eine einfache Liste der Elemente umwandeln.
function Coop.ArrList(R)
    local L = {}
    if type(R) == "table" then
        for _, V in ipairs(R) do L[#L + 1] = V end
    elseif R ~= nil then
        pcall(function() R:ForEach(function(_, E) L[#L + 1] = E:get() end) end)
    end
    return L
end

-- UE 5.6 (Port): Gibt es die Eigenschaft oder Blueprint-Funktion Name an der Klasse von Obj (samt Elternklassen)?
-- Fuer Namen, die 5.3 und 5.6 unterschiedlich haben (z. B. VehicleHealth -> VehicleEngineFX, "Is Burning?" ->
-- IsBurning), statt eine fehlende Funktion blind aufzurufen. Je Klasse und Name einmal per Reflection, gemerkt werden
-- nur Namen und true/false.
Coop.MemberCache = {}
function Coop.HasMember(Obj, Name)
    local Class = IsAlive(Obj) and Safe(function() return Obj:GetClass() end) or nil
    if not IsAlive(Class) then return false end
    local Key = Safe(function() return Class:GetFName():ToString() end, "?") .. ":" .. Name
    if Coop.MemberCache[Key] ~= nil then return Coop.MemberCache[Key] end
    local Found, C, Depth = false, Class, 0
    while not Found and IsAlive(C) and Depth < 16 do
        local Path = Safe(function() return C:GetFullName():match("^%S+%s+(%S+)$") end)
        if Path and IsAlive(StaticFindObject(Path .. ":" .. Name)) then Found = true end
        if not Found then
            pcall(function()
                C:ForEachProperty(function(P)
                    if P:GetFName():ToString() == Name then Found = true return true end
                end)
            end)
        end
        C, Depth = Safe(function() return C:GetSuperStruct() end), Depth + 1
    end
    Coop.MemberCache[Key] = Found
    return Found
end

-- Host: SurrounDead erzeugt die Spielfigur nur beim Laden eines Spielstands, nie fuer Mitspieler.
-- Darum bekommt jeder fremde PlayerController ohne Figur eine Kopie der Host-Figur neben dem Host.
local SPAWN_DELAY = 3
local RemoteSeen, SpawnTried, SpawnedPawns, DeadSince = {}, {}, {}, {}
local RESPAWN_DELAY = 90  -- Notfall, falls der Respawn-Knopf des Spiels nicht greift

-- Wie das Spiel bei einem neuen Spiel: verzoegert spawnen, vor dem Construction Script
-- "SpawnStartingItems?" setzen, dann fertig spawnen. So vergibt das Spiel die Startausruestung
-- selbst auf dem Host (dort liegt das Inventar), statt dass wir sie nachtraeglich bauen.
-- NoKit (join_nokit, Coop.ReturningGuest): ohne "SpawnStartingItems?" wie Survival_SpawnPlayer beim Laden (UE 5.6 @02e6,
-- 5.3 @02e5; mit Ausruestung @0154). BP_PlayerCharacter ReceiveBeginPlay @0320 -> SetStartingItems (5.6 unveraendert).
local function SpawnWithStartingItems(World, Class, Loc, Yaw, Owner, NoKit)
    local GPS = UEHelpers.GetGameplayStatics()
    local Half = math.rad(Yaw) / 2
    local Transform = {
        Rotation = { X = 0, Y = 0, Z = math.sin(Half), W = math.cos(Half) },
        Translation = Loc,
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    -- 2 = AdjustIfPossibleButAlwaysSpawn, Skalierung 1 = MultiplyWithRoot (UE 5.3 hat den extra Parameter)
    local Pawn = GPS:BeginDeferredActorSpawnFromClass(World, Class, Transform, 2, Owner, 1)
    if not IsAlive(Pawn) then return nil end
    -- join_nokit: Rueckkehrer ohne Startausruestung, sonst kollidiert sie mit dem geladenen Inventar.
    if not NoKit then pcall(function() Pawn["SpawnStartingItems?"] = true end) end
    GPS:FinishSpawningActor(Pawn, Transform, 1)
    return Pawn
end

-- Target (join_v2, Coop.Join.Target): fertiges Ziel { X, Y, Z, Yaw } (Boden + 1 m, Spawnpunkt oder Startpunkt der
-- Welt). Dann genau dort und ohne +1 m (der Startpunkt der Welt ist schon Boden + 1 m: sonst doppelt gehoben),
-- die Versaetze nur, falls dort kein Platz ist.
local function SpawnPawnFor(World, PC, Target)
    local HostPawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(HostPawn) then Log("Keine Host-Figur, kann fuer Mitspieler nichts spawnen") return nil end
    local Loc = HostPawn:K2_GetActorLocation()
    local Yaw = HostPawn:K2_GetActorRotation().Yaw
    local Offsets, Lift = { { 200, 0 }, { -200, 0 }, { 0, 200 }, { 0, -200 } }, 100
    if Target then
        Loc, Yaw, Lift = Target, Target.Yaw or Yaw, 0
        table.insert(Offsets, 1, { 0, 0 })
    -- Server-Modus: die Server-Figur schwebt unsichtbar in der Luft. Neben einem Mitspieler am Boden
    -- oder am Startpunkt der Welt spawnen (server.lua).
    elseif SETTINGS.server then Loc, Yaw = SETTINGS.server.SpawnPoint(World, PC, Loc, Yaw) end
    -- join_nokit: Mitspieler mit gespeichertem Server-Inventar ohne Startausruestung (sonst liefert das native
    -- SERVER_RequestData (BP_PlayerCharacter UE 5.6 @242e, 5.3 @23a7) die Ausruestung ins Gast-UI, die LSD-Antwort
    -- scheitert dort -> BuildDataToContainer @0479 RemoveItem = Verlust)
    local okKit, NoKit = pcall(Coop.ReturningGuest, PC)
    if not okKit then Log("Rueckkehrer-Pruefung fehlgeschlagen (%s): Figur mit Startausruestung", tostring(NoKit)) end
    NoKit = okKit and NoKit == true
    if NoKit then Log("Mitspieler kommt mit gespeichertem Inventar zurueck: Figur ohne Startausruestung (wie Laden im Einzelspiel)") end
    for _, Offset in ipairs(Offsets) do
        local Spot = { X = Loc.X + Offset[1], Y = Loc.Y + Offset[2], Z = Loc.Z + Lift }
        local ok, Pawn = pcall(SpawnWithStartingItems, World, HostPawn:GetClass(), Spot, Yaw, PC, NoKit)
        if not ok then Log("Spawn mit Startausruestung fehlgeschlagen: %s", tostring(Pawn)) Pawn = nil end
        if not IsAlive(Pawn) then
            Pawn = World:SpawnActor(HostPawn:GetClass(), Spot, { Pitch = 0, Yaw = Yaw, Roll = 0 })
        end
        if Pawn and Pawn:IsValid() then
            PC:Possess(Pawn)
            Log("Figur fuer Mitspieler gespawnt: %s -> %s", Pawn:GetFName():ToString(), PC:GetFName():ToString())
            return Pawn
        end
    end
    Log("Spawnen fuer Mitspieler fehlgeschlagen (kein freier Platz?)")
    return nil
end

-- Ruckeln: Der Mitspieler sagt seine Bewegung voraus, der Host korrigiert ihn staendig, weil das
-- Spiel z. B. Laufgeschwindigkeit nur auf dem Host setzt. Darum seiner Position vertrauen - aber
-- erst, wenn er 10 s sicher steht (sonst faellt er durch noch nicht geladenen Boden und der Host
-- uebernimmt das). Faellt er trotzdem weit unter den Host, kurz Host-Kontrolle und zurueckholen.
local TRUST_AFTER, RESCUE_DEPTH, RESCUE_PAUSE = 10, 5000, 5
local MOVE_WALKING = 1
local MovementState = {}

local function SetClientTrust(Pawn, Trust)
    pcall(function()
        local Movement = Pawn.CharacterMovement
        if not IsAlive(Movement) then return end
        Movement.bIgnoreClientMovementErrorChecksAndCorrection = Trust
        Movement.bServerAcceptClientAuthoritativePosition = Trust
    end)
end

-- Runde 9 PLAYER-16 (move_check): mit trust_movement uebernimmt der Host nach TRUST_AFTER s die Position des Gasts.
-- Waagrechte Geschwindigkeit zwischen zwei Durchlaeufen (~1 s) ueber MaxWalkSpeed*2+600 uu/s - beim Gehen/Schwimmen,
-- ohne Fahrzeug, nicht direkt nach einem Mod-Teleport (Coop.TrustSkip, E23) - ist eine Verletzung (geloggt, hoechstens
-- alle 5 s); 3 in 10 s -> Client-Position RESCUE_PAUSE s nicht mehr uebernommen (wie beim Zurueckholen). true = entzogen.
Coop.TrustSkip = Coop.TrustSkip or {}   -- [Controller-Key] = os.clock() bis dahin keine Pruefung (Schreiber legen sie an)
function Coop.MoveCheck(Key, Pawn, State, Here, Now)
    local Last, Clock = State.Last, os.clock()
    State.Last = nil
    if not Coop.FlagOn("move_check", true) then return false end
    local Skip = Coop.TrustSkip and Coop.TrustSkip[Key]
    if Skip then
        if Clock < Skip then return false end
        Coop.TrustSkip[Key] = nil
    end
    local Move = Safe(function() return Pawn.CharacterMovement end)
    if not IsAlive(Move) then return false end
    local Mode = Safe(function() return Move.MovementMode end)
    if not (Mode == MOVE_WALKING or Mode == 2 or Mode == 4) then return false end   -- Gehen, NavWalking, Schwimmen
    if IsAlive(Safe(function() return Pawn:GetAttachParentActor() end)) then return false end
    local C = Coop.Car
    if C and ((type(C.Drivers) == "table" and C.Drivers[Key]) or (type(C.Passengers) == "table" and C.Passengers[Key])) then
        return false
    end
    State.Last = { X = Here.X, Y = Here.Y, T = Clock }
    if not Last or Clock - Last.T < 0.5 or Clock - Last.T > 3 then return false end
    local Dx, Dy = Here.X - Last.X, Here.Y - Last.Y
    local Speed = math.sqrt(Dx * Dx + Dy * Dy) / (Clock - Last.T)
    local Limit = (tonumber(Safe(function() return Move.MaxWalkSpeed end)) or 600) * 2 + 600
    if Speed <= Limit then return false end
    local Recent = {}
    for _, T in ipairs(State.Viol or {}) do if Clock - T < 10 then Recent[#Recent + 1] = T end end
    Recent[#Recent + 1] = Clock
    State.Viol = Recent
    if Clock >= (State.WarnAt or 0) then
        State.WarnAt = Clock + 5
        Log("Bewegung von %s unplausibel (%.0f uu/s, Grenze %.0f, %d in 10 s)", tostring(State.Pawn), Speed, Limit, #Recent)
    end
    if #Recent < 3 then return false end
    State.Viol, State.Last = nil, nil
    SetClientTrust(Pawn, false)
    State.Trusted, State.Since = false, Now + RESCUE_PAUSE
    Log("Bewegung von %s: 3 Verstoesse in 10 s - Client-Position voruebergehend nicht uebernommen", tostring(State.Pawn))
    return true
end

local function ManageMovementTrust(Key, Pawn, Now)
    if not SETTINGS.trust_movement or not IsAlive(Pawn) then return end
    local Name = Pawn:GetFName():ToString()
    local State = MovementState[Key]
    if not State or State.Pawn ~= Name then
        State = { Pawn = Name, Since = Now, Trusted = false }
        MovementState[Key] = State
    end
    local HostPawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local Here = Pawn:K2_GetActorLocation()
    local Z = Here.Z
    local Walking = Safe(function() local Move = Pawn.CharacterMovement return IsAlive(Move) and Move.MovementMode or nil end) == MOVE_WALKING
    if Walking then State.Ground = { X = Here.X, Y = Here.Y, Z = Here.Z } end
    -- Bezug: der Host - im Server-Modus aber der eigene letzte Bodenpunkt (die Server-Figur schwebt)
    local Ref, Depth, Offset = nil, RESCUE_DEPTH, 200
    if SETTINGS.server then
        Ref, Depth, Offset = State.Ground, RESCUE_DEPTH * 2, 0
    elseif IsAlive(HostPawn) then
        Ref = HostPawn:K2_GetActorLocation()
    end
    if State.Trusted and Ref and Z < Ref.Z - Depth then
        SetClientTrust(Pawn, false)
        Pawn:K2_TeleportTo({ X = Ref.X + Offset, Y = Ref.Y, Z = Ref.Z + 100 }, Pawn:K2_GetActorRotation())
        State.Trusted, State.Since = false, Now + RESCUE_PAUSE
        Log("Mitspieler war durch die Welt gefallen, zurueck zum Host geholt")
        return
    end
    if State.Trusted then
        local okM, Revoked = pcall(Coop.MoveCheck, Key, Pawn, State, Here, Now)
        if not okM then Coop.FlagFail("move_check", Revoked) elseif Revoked then return end
    else
        State.Last = nil
    end
    if not State.Trusted and Now - State.Since >= TRUST_AFTER then
        local Mode = Safe(function() local Move = Pawn.CharacterMovement return IsAlive(Move) and Move.MovementMode or nil end)
        if Mode == MOVE_WALKING then
            SetClientTrust(Pawn, true)
            State.Trusted = true
            Log("Bewegung des Mitspielers: Client-Position wird uebernommen")
        end
    end
end

-- Mikroruckler beim Mitspieler: Die Kapsel (Wurzel jeder Spielerfigur) steht im Spiel auf
-- "repliziert". Dann schickt der Host seine Kapsel-Position - um die Laufzeit aelter - auch an den
-- Besitzer der Figur, und dessen Vorhersage springt bei jedem Paket ein paar Frames zurueck.
-- Normale UE-Figuren replizieren die Kapsel nicht, die Position laeuft ueber die
-- Bewegungskomponente. Fuer jede Spielerfigur (auch die des Hosts) einmal abschalten.
local CapsuleFixed = {}

local function StopCapsuleReplication(Pawn)
    if not IsAlive(Pawn) then return end
    local Name = Pawn:GetFName():ToString()
    if CapsuleFixed[Name] then return end
    CapsuleFixed[Name] = true
    local ok, err = pcall(function()
        local Capsule = Pawn.CapsuleComponent
        if IsAlive(Capsule) and Capsule.bReplicates then Capsule:SetIsReplicated(false) end
    end)
    Log("Kapsel-Replikation fuer %s aus: %s", Name, ok and "ok" or tostring(err))
end

-- Waffen/Ausruestung beim anderen sichtbar: Gehaltene Gegenstaende (Waffen, Rucksack, Helm,
-- Brille, ...) sind eigene "Pickup"-Actors, die das Spiel nicht repliziert. Die Liste der
-- ausgeruesteten Actors kommt beim Mitspieler zwar an, ihre Eintraege bleiben dort aber leer: Er
-- sieht nichts, und die Hotbar bricht ab, weil sie die ausgeruestete Waffe nicht findet. Darum
-- stellt der Host jeden ausgeruesteten Gegenstand jeder Spielerfigur auf repliziert; die
-- Befestigung an Hand/Ruecken kommt dann automatisch mit. Neue Beute innerhalb einer Sekunde.
local REP_ACTOR_FIELD = "Actor_5_6FDDEF454801C671BE34D7B2377175C5"

local function ReplicateEquipment(Pawn)
    if not IsAlive(Pawn) then return end
    local Count = 0
    local Jig = Pawn.BP_JigHelperComp
    if not IsAlive(Jig) then return end
    Jig.RepActorsData:ForEach(function(_, Entry)
        local Item = Entry:get()[REP_ACTOR_FIELD]
        if IsAlive(Item) and not Item.bReplicates then
            Item:SetReplicates(true)
            Item:SetReplicateMovement(true)
            Count = Count + 1
        end
    end)
    if Count > 0 then
        Log("Ausruestung von %s: %d Gegenstaende fuer Mitspieler sichtbar gemacht", Pawn:GetFName():ToString(), Count)
    end
end

-- Alles, was der Host an jeder Spielerfigur (eigene und Mitspieler) laufend einrichtet.
local function PreparePlayerPawn(Pawn)
    StopCapsuleReplication(Pawn)
    local ok, err = pcall(ReplicateEquipment, Pawn)
    if not ok then Log("Ausruestungs-Fehler: %s", tostring(err)) end
end

-- Speicherschutz: Das Speichersystem (Easy Multi Save) wuerde die Figur des Mitspielers wie eine
-- zweite Spielerfigur in den Host-Spielstand schreiben und dessen Inventar/Aussehen ueberschreiben.
-- Darum Figur und Controller des Mitspielers als "nicht speichern" markieren (wie das Spiel es bei
-- toten Figuren selbst macht), bei jeder neuen Figur erneut.
local NoSaveMarked = {}

local function MarkNoSave(Actor)
    if not IsAlive(Actor) then return end
    local Name = Actor:GetFName():ToString()
    if NoSaveMarked[Name] then return end
    local ok, err = pcall(function()
        local EMS = Coop.Cdo("/Script/EasyMultiSave.Default__EMSFunctionLibrary")   -- CORE-20
        if not EMS then error("EMSFunctionLibrary fehlt") end
        EMS:SetActorSaveProperties(Actor, true, false, false, 0)
        Actor.Tags[#Actor.Tags + 1] = FName("EMS_SkipSave")
    end)
    NoSaveMarked[Name] = true
    Log("Speicherschutz fuer %s: %s", Name, ok and "aktiv" or tostring(err))
end

-- leave_dead_ref (CORE-2): Ist Pawn (gemerkt) jetzt noch die Figur dieses Controllers? Nur ueber die frische Figurenliste
-- dieses Durchlaufs (Adressvergleich, GetAddress liest nur den Zeiger), erst danach wird Pawn selbst angefasst: eine vom
-- GC freigegebene Leiche oder die Figur eines anderen Spielers an derselben Adresse zaehlt nicht. Controller der Figur:
-- keiner (getrennt) oder derselbe Key.
function Coop.IsCurrentPawnOf(Key, Pawn)
    local Addr = Safe(function() return Pawn:GetAddress() end)
    if not Addr then return false end
    local Hit = nil
    for _, P in ipairs(Coop.PlayerPawns()) do
        if Safe(function() return P:GetAddress() end) == Addr then Hit = P break end
    end
    if not Hit then return false end
    local Ctrl = Safe(function() return Hit.Controller end)
    if not (Ctrl and IsAlive(Ctrl)) then return true end
    return Safe(function() return Ctrl:GetFullName() end) == Key
end

local function HandleRemotePlayers(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Now, Current = os.time(), {}
    local HostPC = LocalPC()
    if IsAlive(HostPC) then PreparePlayerPawn(HostPC:K2_GetPawn()) end
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            Current[Key] = true
            RemoteSeen[Key] = RemoteSeen[Key] or Now
            MarkNoSave(PC)
            MarkNoSave(PC:K2_GetPawn())
            PreparePlayerPawn(PC:K2_GetPawn())
            local HasPawn = PC:K2_GetPawn():IsValid()
            -- join_v2: erst auf das hello des Mitspielers warten (hoechstens Coop.Join.WAIT_HELLO s), dann direkt am
            -- Ziel spawnen (gespeicherte Position oder Spawnpunkt); ohne join_v2/hello wie bisher
            if not HasPawn and not SpawnTried[Key] and Now - RemoteSeen[Key] >= SPAWN_DELAY
                and not Coop.Join.WaitHello(Key, Now - RemoteSeen[Key]) then
                SpawnTried[Key] = true
                -- PLAYER-13 (pvp_logout): alte Figur desselben Mitspielers vor ReturningGuest sichern und entfernen
                if Coop.Logout and next(Coop.Logout) then
                    local okR, errR = pcall(Coop.LogoutResolve, Key)
                    if not okR then Coop.FlagFail("pvp_logout", errR) end
                end
                local okAim, Target = pcall(Coop.Join.Target, World, PC, Key)
                if not okAim then Log("Beitritts-Ziel fehlerhaft: %s", tostring(Target)) Target = nil end
                SpawnedPawns[Key] = SpawnPawnFor(World, PC, Target)
                if Target and IsAlive(SpawnedPawns[Key]) then
                    local okJoin, errJoin = pcall(Coop.Join.OnSpawned, Key, PC, SpawnedPawns[Key], Target)
                    if not okJoin then Log("Beitritt (Spawn) fehlerhaft: %s", tostring(errJoin)) end
                end
            elseif HasPawn then
                DeadSince[Key] = nil
                -- leave_live_pawn: nach Respawn (respawn_v2/Spiel) zeigte SpawnedPawns noch auf die erste, tote Figur ->
                -- beim Trennen StoreLeaving still uebersprungen (G.Dead) und die Leiche statt der Figur entfernt
                local LC = Coop.Modules and Coop.Modules.ls_core
                if not (LC and LC.Flag) or LC.Flag("leave_live_pawn", true) == true then SpawnedPawns[Key] = PC:K2_GetPawn() end
                -- join_v2: bis "ready" haelt Coop.Join die Figur eingefroren, kein Vertrauen/Zurueckholen
                if Coop.Join.IsReady(Key) then
                    local okTrust, errTrust = pcall(ManageMovementTrust, Key, PC:K2_GetPawn(), Now)
                    if not okTrust then Log("Bewegungs-Fehler: %s", tostring(errTrust)) end
                end
            elseif SpawnTried[Key] then
                -- leave_dead_ref (CORE-2): die tote Figur nicht ueber Ticks halten (das Spiel zerstoert sie nach 30 s, die
                -- GC gibt sie frei; beim Trennen vom Todesbildschirm lief IsAlive sonst auf freien Speicher)
                if Coop.FlagOn("leave_dead_ref", true) then SpawnedPawns[Key] = nil end
                -- Figur weg = gestorben. Erst dem Spiel Zeit fuer seinen eigenen Respawn lassen,
                -- dann selbst eine neue Figur neben den Host stellen.
                if not DeadSince[Key] then
                    DeadSince[Key] = Now
                    Log("Mitspieler ohne Figur (gestorben?), Respawn in %d s", RESPAWN_DELAY)
                elseif Now - DeadSince[Key] >= RESPAWN_DELAY
                    -- respawn_v2 (ls_player, braucht inv_v2a/ls_inv): Anfrage + Rueckfall statt blindem Notfall-Respawn,
                    -- aber nur fuer Gaeste, die den neuen Weg sprechen (Respawn-Faehigkeit pl_rsp der Verbindung; pl2
                    -- steht auch fuer player_cmds/bed_v2); alle anderen behalten den Notfall-Respawn
                    and not (Coop.Player and Coop.Modules.ls_inv and Coop.Player.OwnsRespawn(Key)
                        and Coop.Net and Coop.Net.Has("pl_rsp", Key)) then
                    DeadSince[Key] = nil
                    SpawnedPawns[Key] = SpawnPawnFor(World, PC)
                end
            end
        end
    end
    -- Mitspieler weg: seine Figur wieder entfernen (Coop.LeaveKey; PLAYER-13 pvp_logout kann es aufschieben)
    for Key in pairs(RemoteSeen) do
        if not Current[Key] then Coop.LeaveKey(Key) end
    end
end

-- Mitspieler (Controller-Key) getrennt: Quest-Stand, letzte Sicherung, Figur entfernen, Tabellen vergessen. Aus
-- HandleRemotePlayers (vorher dort direkt) und Coop.LogoutResolve.
function Coop.LeaveKey(Key)
    -- PLAYER-13 (pvp_logout): im Kampf getrennt -> Figur bleibt noch stehen (Coop.Logout), Abbau spaeter
    local okH, Hold = pcall(Coop.LogoutHold, Key)
    if not okH then Coop.FlagFail("pvp_logout", Hold) elseif Hold then return end
    -- X8: Quest-Stand zusammen mit dem Inventar sichern (ls_world, best effort: nur Gaeste, deren PC noch gefunden wird)
    local W = Coop.Modules and Coop.Modules.ls_world
    if W and W.SaveQuests then
        local okQ, errQ = pcall(W.SaveQuests)
        if not okQ then Log("Quest-Sicherung beim Trennen fehlgeschlagen: %s", tostring(errQ)) end
    end
    local Pawn = SpawnedPawns[Key]
    -- leave_dead_ref (CORE-2): nur die aktuelle Figur dieses Controllers sichern und entfernen
    if Pawn and Coop.FlagOn("leave_dead_ref", true) then
        local okCur, Cur = pcall(Coop.IsCurrentPawnOf, Key, Pawn)
        if not okCur then Coop.FlagFail("leave_dead_ref", Cur) end
        if not (okCur and Cur) then
            if okCur then Log("Mitspieler getrennt: gemerkte Figur ist nicht mehr seine (tot/ersetzt) - nichts gesichert/entfernt") end
            Pawn = nil
        end
    end
    if Pawn and IsAlive(Pawn) then
        -- Letzte Sicherung mit der noch lebenden Figur, vor dem Entfernen und vor Join.Forget (danach fehlt
        -- G.Restored und ls_inv speichert nicht mehr): sonst Duplikat/Verlust der letzten 2-10 s
        local okLast, errLast = pcall(Coop.StoreLeaving, Key, Pawn)
        if not okLast then Log("Letzte Sicherung des Mitspielers fehlgeschlagen: %s", tostring(errLast)) end
        Pawn:K2_DestroyActor()
        Log("Figur des Mitspielers entfernt")
    end
    RemoteSeen[Key], SpawnTried[Key], SpawnedPawns[Key], DeadSince[Key] = nil, nil, nil, nil
    MovementState[Key] = nil
    if SETTINGS.join_v2 then pcall(Coop.Join.Forget, Key) end   -- Beitritt, Laden/Abgleich beim Wiederkommen neu
    if Coop.Logout then Coop.Logout[Key] = nil end
    -- CORE-30 (leave_forget): alle main.lua-Tabellen dieser Verbindung vergessen (nach der letzten Sicherung)
    if Coop.ForgetKey then
        local okF, errF = pcall(Coop.ForgetKey, Key)
        if not okF then Coop.FlagFail("leave_forget", errF) end
    end
end

-- PLAYER-13: Figur (FName) in den letzten pvp_logout_s Sekunden von einem ANDEREN Spieler getroffen (ls_combat E10
-- Coop.CombatTag, haelt 120 s)? Nur mit Schalter Flag und pvp an (wie ls_combat U.PvpMode). Fehler -> Flag aus.
function Coop.InCombat(PawnName, Flag, Default)
    if not (PawnName and Coop.FlagOn(Flag, Default) and Coop.FlagOn("pvp", true)) then return false end
    local Tag = Coop.CombatTag
    if type(Tag) ~= "function" then return false end
    local ok, T = pcall(Tag, PawnName)
    if not ok then Coop.FlagFail(Flag, T) return false end
    return type(T) == "number" and os.clock() - T < Coop.PvpLogoutSecs()
end
function Coop.PvpLogoutSecs()
    local LC = Coop.Modules and Coop.Modules.ls_core
    local V = LC and LC.Flag and Safe(function() return LC.Flag("pvp_logout_s", 30) end)
    return math.max(5, math.min(tonumber(V) or 30, 600))
end

-- PLAYER-13 (pvp_logout, Standard aus): Gehoerte die Figur einem Gast, der im PvP-Kampf getrennt hat, bleibt sie
-- pvp_logout_s stehen (ohne Controller, verwundbar); danach (oder bei Wiederkehr, Coop.LogoutResolve) der normale Abbau.
-- Coop.Logout[Key] = { Addr, Name, Until (os.clock), GuestId, Done }. true = Abbau noch aufschieben.
function Coop.LogoutHold(Key)
    local E = Coop.Logout and Coop.Logout[Key]
    if E then
        -- Figur nur ueber die frische Liste (Adresse + Name), das gemerkte Objekt nie anfassen
        if not E.Done and os.clock() < E.Until and Coop.LogoutPawn(E) then return true end
        if not E.Done then Log("Kampf-Ausloggen von %s beendet: Figur wird abgebaut", tostring(E.GuestId)) end
        E.Done = true
        return false
    end
    if not Coop.FlagOn("pvp_logout", false) then return false end
    local Pawn = SpawnedPawns[Key]
    if not Pawn then return false end
    local okCur, Cur = pcall(Coop.IsCurrentPawnOf, Key, Pawn)
    if not (okCur and Cur) or not IsAlive(Pawn) then return false end
    if not ((tonumber(Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and M.Health or nil end)) or 0) > 0) then
        return false
    end
    local Name = Safe(function() return Pawn:GetFName():ToString() end)
    if not Coop.InCombat(Name, "pvp_logout", false) then return false end
    local Secs = Coop.PvpLogoutSecs()
    Coop.Logout = Coop.Logout or {}
    Coop.Logout[Key] = { Addr = Pawn:GetAddress(), Name = Name, Until = os.clock() + Secs, GuestId = Coop.GuestIds[Key] }
    Log("Mitspieler %s im Kampf getrennt: Figur %s bleibt %d s stehen (pvp_logout)", tostring(Coop.GuestIds[Key]), Name, Secs)
    return true
end
-- Figur eines Coop.Logout-Eintrags in der frischen Figurenliste (lebend oder tot, bis das Spiel sie entfernt) oder nil
function Coop.LogoutPawn(E)
    for _, P in ipairs(Coop.PlayerPawns()) do
        if Safe(function() return P:GetAddress() end) == E.Addr then
            return Safe(function() return P:GetFName():ToString() end) == E.Name and P or nil
        end
    end
    return nil
end
-- PLAYER-13: derselbe Mitspieler kommt waehrend der Frist zurueck -> alte Figur zuerst sichern und entfernen (vor
-- Coop.ReturningGuest/G.Sync, die den Spielstand lesen)
function Coop.LogoutResolve(NewKey, GuestId)
    local L = Coop.Logout
    if not (L and next(L)) then return end
    GuestId = GuestId or (Coop.HelloIds and Coop.HelloIds[NewKey]) or Coop.GuestIds[NewKey]
    if type(GuestId) ~= "string" then return end
    local Old = {}
    for K, E in pairs(L) do
        if K ~= NewKey and not E.Done and type(E.GuestId) == "string" and E.GuestId:lower() == GuestId:lower() then
            Old[#Old + 1] = K
        end
    end
    for _, K in ipairs(Old) do
        L[K].Done = true
        Log("Mitspieler %s ist zurueck: alte Figur wird jetzt gesichert und entfernt (pvp_logout)", GuestId)
        Coop.LeaveKey(K)
    end
end

-- Diagnose fuer geteilten Schaden/Tod: Leben jeder Figur mitschreiben und festhalten, welche Figur
-- Schaden bekommt und welche stirbt. Daraus sehen wir, wo das Spiel die Figuren verwechselt.
local LastHealth = nil

local function LogHealth(World)
    local Parts = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local Pawn = Safe(function() return PS:GetPawn() end)
        if Pawn and IsAlive(Pawn) then
            local Health = Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and M.Health or nil end)
            Parts[#Parts + 1] = string.format("%s=%s", Pawn:GetFName():ToString(),
                Health and string.format("%.0f", Health) or "?")
        end
    end
    local Line = table.concat(Parts, " ")
    if Line ~= LastHealth and Line ~= "" then
        Log("Leben: %s", Line)
        LastHealth = Line
    end
end

-- Diagnose fuers Ruckeln: Weichen Laufgeschwindigkeit oder Bewegungsmodus der Mitspieler-Figur
-- zwischen Host und Client ab, korrigiert der Host ihn staendig. Beide Seiten schreiben das mit.
local LastSpeed = nil

local function LogSpeed(World)
    local Parts = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local Pawn = Safe(function() return PS:GetPawn() end)
        if Pawn and IsAlive(Pawn) then
            local Movement = Safe(function() return Pawn.CharacterMovement end)
            if not IsAlive(Movement) then Movement = nil end   -- CORE-20
            local Speed = Movement and Safe(function() return Movement.MaxWalkSpeed end)
            local Mode = Movement and Safe(function() return Movement.MovementMode end)
            Parts[#Parts + 1] = string.format("%s=%s/Modus%s", Pawn:GetFName():ToString(),
                Speed and string.format("%.0f", Speed) or "?", tostring(Mode))
        end
    end
    local Line = table.concat(Parts, " ")
    if Line ~= LastSpeed and Line ~= "" then
        Log("Tempo: %s", Line)
        LastSpeed = Line
    end
end

-- Datenkanal Host -> Mitspieler: ClientMessage ist ein zuverlaessiger Client-RPC der Engine (sonst
-- fuer Konsolenmeldungen). Nachrichten mit dem Praefix NETTEST| wertet der Mod beim Mitspieler aus.
-- (Praefix und die Spielstand-Namen NetTest_* bleiben bewusst beim alten Namen: Umbenennen auf "Last Signal"
-- haette alle Mitspieler-IDs und Server-Inventare ungueltig gemacht.)
local MESSAGE_PREFIX = "NETTEST|"

local function SendToClient(PC, Text)
    PC:ClientMessage(MESSAGE_PREFIX .. Text, FName("NetTest"), 0.0)
end

-- Spieler-Statistiken (Kills, ueberlebte Tage) liegen am Controller. Der Controller des Mitspielers
-- lebt auf dem Host; seine Anzeige (Respawn-Bildschirm, Tage-Anzeige) liest aber die lokale, nie
-- abgeglichene Kopie. Darum schickt der Host die Werte bei jeder Aenderung an ihn.
local STAT_FIELDS = { "ZombieKills", "BossZombieKills", "AnimalKills", "HumanKills", "DaysSurvived" }
local LastSentStats = {}

local function SyncStats(World)
    if NetModeName(World) ~= "ListenServer" then return end
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Parts = {}
            for _, Field in ipairs(STAT_FIELDS) do
                Parts[#Parts + 1] = Field .. "=" .. tostring(Safe(function() return PC[Field] end, 0))
            end
            local Text = "stats|" .. table.concat(Parts, ";")
            local Key = PC:GetFName():ToString()
            -- ls_combat (combat_credit, Gast mit cb2): Kill-Zaehler/Tage per cb_kills statt "stats"
            if LastSentStats[Key] ~= Text and not (Coop.CombatOwnsStats and Safe(function() return Coop.CombatOwnsStats(PC) end, false)) then
                local ok, err = pcall(SendToClient, PC, Text)
                if ok then
                    LastSentStats[Key] = Text
                    Log("Statistik an Mitspieler: %s", Text)
                else
                    Log("Statistik senden fehlgeschlagen: %s", tostring(err))
                end
            end
        end
    end
end

local OnHostData = nil  -- Stueckweise Daten vom Host (Aussehen, ...), wird weiter unten gesetzt
-- (local Coop steht seit join_v2 vor SpawnPawnFor: HandleRemotePlayers braucht Coop.Join)

-- Eine gemeinsame Liste aller Figuren (statt mehrerer FindAllOf("Character") pro Sekunde): je Welt neu, alle Nutzer
-- pruefen jede Figur mit IsAlive. CORE-19 (world_hygiene): 0,2 s gueltig wie in API.md zugesagt (je laenger die Liste
-- gilt, desto eher liegt ein GC-Lauf dazwischen und die Nutzer fassen freigegebene Figuren an); sonst 1 s wie bisher.
function Coop.Characters()
    local Now = os.clock()
    local Ttl = WorldGen.Hygiene ~= false and 0.2 or 1
    if not Coop.CharList or Now - Coop.CharAt >= Ttl or Coop.CharGen ~= WorldGen.N then
        Coop.CharList, Coop.CharAt, Coop.CharGen = FindAllOf("Character") or {}, Now, WorldGen.N
    end
    return Coop.CharList
end

-- Runde 9 CORE-31 (E30): FindAllOf(Class) gemeinsam fuer alle Nutzer, je Klasse hoechstens alle MaxAge s (<= 0,25) und
-- nie ueber einen Weltwechsel (WorldGen.N). Die Liste enthaelt rohe Huellen: jeder Nutzer prueft IsAlive vor dem
-- Zugriff und haelt die Liste nicht ueber den Aufruf hinaus. Module: mit FindAllOf-Rueckfall, falls es fehlt.
Coop.ScanCache = {}
function Coop.Scan(Class, MaxAge)
    if type(Class) ~= "string" then return {} end
    local Age, Now = math.min(tonumber(MaxAge) or 0.25, 0.25), os.clock()
    local E = Coop.ScanCache[Class]
    if E and E.Gen == WorldGen.N and Now - E.At < Age then return E.List end
    local List = FindAllOf(Class) or {}
    Coop.ScanCache[Class] = { List = List, At = Now, Gen = WorldGen.N }
    return List
end

-- Boden unter einer Stelle (wie server.lua Ground: Linie ab Up = 2 m darueber nach unten, Kanal Visibility), aber
-- die Hoehe des Bodens selbst (ohne +1 m). nil ohne Treffer (Boden noch nicht geladen). Self (eigene Figur) als
-- Welt-Kontext mit bIgnoreSelf: die Linie trifft dann nicht die eigene Kapsel. Kleineres Up in Gebaeuden (join_v2:
-- Figur bzw. gespeicherter Standpunkt), sonst startet die Linie ueber der Decke und findet das Dach.
function Coop.Ground(Loc, Self, Up)
    local Hit, Clear = {}, { R = 0, G = 0, B = 0, A = 0 }
    local Context = IsAlive(Self) and Self or CurrentWorld()
    local ok = Safe(function()
        return UEHelpers.GetKismetSystemLibrary():LineTraceSingle(Context,
            { X = Loc.X, Y = Loc.Y, Z = Loc.Z + (Up or 200) }, { X = Loc.X, Y = Loc.Y, Z = Loc.Z - 100000 },
            0, false, {}, 0, Hit, true, Clear, Clear, 0)
    end, false)
    if ok and Hit.ImpactPoint then return Hit.ImpactPoint.Z end
    return nil
end

local function ApplyHostMessage(Text)
    if OnHostData and Text:sub(1, 5) == "part|" then OnHostData(Text) return end
    local Kind, Payload = Text:match("^(%w+)|(.*)$")
    if Kind == "stats" then
        local PC = LocalPC()
        if not IsAlive(PC) then return end
        for Field, Value in Payload:gmatch("(%w+)=(%-?%d+)") do
            pcall(function() PC[Field] = tonumber(Value) end)
        end
        Log("Statistik vom Host uebernommen: %s", Payload)
    end
end

-- Runde 5 (WP0): Die Empfangs-Hooks rufen keine Spielfunktionen mehr auf. Alte Nachrichten (part|...) kommen nur in
-- diese Warteschlange (Absender-Key + Text), abgearbeitet im Schnell-Loop (Coop.Inbox.Tick, 100 ms, Spiel-Thread):
-- hoechstens 30 Nachrichten bzw. 4 ms pro Durchlauf, Reihenfolge bleibt. Der Controller wird dort frisch gesucht.
-- Je Mitspieler (nicht "host"): Eimer mit BURST Nachrichten, REFILL pro Sekunde nachgefuellt, und hoechstens die halbe
-- Warteschlange - ein flutender Gast verdraengt nicht hb/auth/ready der anderen.
Coop.Inbox = { Q = {}, Head = 1, Tail = 0, Max = 2000, Dropped = 0, LocalKey = nil,
               BURST = 400, REFILL = 150, Rate = {}, PerKey = {}, PruneAt = 0 }
function Coop.Inbox.Push(Key, Text)
    local IB = Coop.Inbox
    if IB.Tail - IB.Head + 1 >= IB.Max then IB.Dropped = IB.Dropped + 1 return end
    if Key ~= "host" then
        local Now = os.clock()
        local B = IB.Rate[Key]
        if not B then B = { Tok = IB.BURST, T = Now } IB.Rate[Key] = B end
        B.Tok, B.T = math.min(IB.BURST, B.Tok + (Now - B.T) * IB.REFILL), Now
        if B.Tok < 1 or (IB.PerKey[Key] or 0) >= IB.Max / 2 then
            IB.Dropped, IB.Flood = IB.Dropped + 1, Key
            return
        end
        B.Tok = B.Tok - 1
    end
    IB.PerKey[Key] = (IB.PerKey[Key] or 0) + 1
    IB.Tail = IB.Tail + 1
    IB.Q[IB.Tail] = { K = Key, T = Text, N = WorldGen.N }   -- N: aus einer frueheren Welt nicht mehr anwenden
end

-- Nur beim Spieler (empfaengt): Der Server ruft ClientMessage selbst auf (Senden), oft mitten in einem anderen
-- Hook - ein Hook im Hook ist in UE4SS nicht stabil.
if os.getenv("LASTSIGNAL_SERVER") ~= "1" and os.getenv("NETTEST_SERVER") ~= "1" then
    TryHook("/Script/Engine.PlayerController:ClientMessage", function(_, Message)
        local Text = Safe(function() return Message:get():ToString() end, "")
        if Text:sub(1, #MESSAGE_PREFIX) == MESSAGE_PREFIX then
            -- Runde 5: Protokoll v3 nur in die Inbox (ls_net), abgearbeitet im 100-ms-Task
            if Coop.Net and Text:sub(#MESSAGE_PREFIX + 1, #MESSAGE_PREFIX + 3) == "v3|" then
                Coop.Net.Push(Text:sub(#MESSAGE_PREFIX + 4), "host")
                return
            end
            Coop.Inbox.Push("host", Text:sub(#MESSAGE_PREFIX + 1))   -- WP0: ApplyHostMessage im Schnell-Loop
        end
    end)
end
Coop.Inbox.Host = ApplyHostMessage

do
-- Datenkanal Mitspieler -> Host: ServerExecRPC ist ein zuverlaessiger Server-RPC der Engine, der im
-- Shipping-Build nichts ausfuehrt (Konsolenbefehle gibt es dort nur mit Cheat-Manager im
-- Entwickler-Build). Der Host liest NETTEST|-Nachrichten im Hook mit und weiss dabei, von welchem
-- Controller sie kommen. Laengere Daten gehen in beide Richtungen in Stuecken:
-- part|<Art>|<Nr>|<Anzahl>|<Text>.
local CHUNK_SIZE = 1000

local function SendToHost(Text)
    local PC = LocalPC()
    if not IsAlive(PC) then return end
    PC:ServerExecRPC(MESSAGE_PREFIX .. Text)
end

local function SendChunked(Send, Kind, Data)
    local Total = math.max(1, math.ceil(#Data / CHUNK_SIZE))
    for I = 1, Total do
        Send(string.format("part|%s|%d|%d|%s", Kind, I, Total, Data:sub((I - 1) * CHUNK_SIZE + 1, I * CHUNK_SIZE)))
    end
end

local Incoming = {}

-- Gibt Art und vollstaendige Daten zurueck, sobald alle Stuecke eines Absenders da sind.
-- Grenzen: hoechstens MAX_PARTS Stuecke je Nachricht (256 KB), MAX_OPEN offene Nachrichten je Absender, offene
-- Reste nach 60 s weg (sonst wuchs Incoming mit jeder unvollstaendigen oder erfundenen Art).
-- Ausnahme "inv" vom Host: ganzer Save_Player als Hex (78-KB-Save = 157 Stuecke), volle Inventare koennen mehr sein.
local REASM = { MAX_PARTS = 256, MAX_PARTS_INV = 2048, MAX_OPEN = 16, TTL = 60, SweepAt = 0 }
local function Reassemble(Sender, Text)
    local Kind, Index, Total, Chunk = Text:match("^part|([%w_]+)|(%d+)|(%d+)|(.*)$")
    if not Kind then return nil end
    Index, Total = tonumber(Index), tonumber(Total)
    local Max = (Sender == "host" and Kind == "inv") and REASM.MAX_PARTS_INV or REASM.MAX_PARTS
    if not Index or not Total or Total < 1 or Total > Max or Index < 1 or Index > Total then return nil end
    local Now = os.clock()
    if Now >= REASM.SweepAt then
        REASM.SweepAt = Now + 10
        for K, E in pairs(Incoming) do if Now - E.At > REASM.TTL then Incoming[K] = nil end end
    end
    local Key = Sender .. "|" .. Kind
    local Entry = Incoming[Key]
    if Index == 1 or not Entry or Entry.Total ~= Total then
        if not Entry then
            local Open, Prefix = 0, Sender .. "|"
            for K in pairs(Incoming) do if K:sub(1, #Prefix) == Prefix then Open = Open + 1 end end
            if Open >= REASM.MAX_OPEN then return nil end
        end
        Entry = { Total = Total, Parts = {}, Count = 0, At = Now }
        Incoming[Key] = Entry
    end
    Entry.At = Now
    if not Entry.Parts[Index] then Entry.Count = Entry.Count + 1 end
    Entry.Parts[Index] = Chunk
    if Entry.Count < Total then return nil end
    Incoming[Key] = nil
    return Kind, table.concat(Entry.Parts)
end

-- Werte in Nachrichten: | ; = und % maskieren (Namen tippt der Spieler selbst).
local function Encode(Value)
    return (tostring(Value):gsub("[%%|;=]", function(C) return string.format("%%%02X", C:byte()) end))
end

local function Decode(Value)
    return (Value:gsub("%%(%x%x)", function(H) return string.char(tonumber(H, 16)) end))
end

-- Aussehen: Das Spiel baut JEDE Spielerfigur (SetSexMesh) aus dem Spielstand des eigenen Rechners
-- (Save_Player: Geschlecht, Hautfarbe, Haare, Bart, Accessoires). Darum sah jeder alle mit seinem
-- eigenen Gesicht. Jeder schickt sein Aussehen, der Host verteilt es an alle; angewendet wird es,
-- indem kurz die Werte in den lokalen Save_Player geschrieben, SetSexMesh der Figur aufgerufen und
-- die eigenen Werte sofort zurueckgeschrieben werden (gespeichert wird dabei nichts).
local APPEARANCE_TEXTS = { "Sex", "Forename", "Surname" }
local APPEARANCE_OBJECTS = { "SkinColor", "HairColor", "BeardColor", "HairType", "MouthType", "EyebrowsType",
    "BeardType", "AccessoryType1", "AccessoryType2", "AccessoryType3" }

local function PlayerSave()
    local Fallback
    for _, Save in ipairs(FindAllOf("Save_Player_C") or {}) do
        if IsAlive(Save) then
            if Save:GetFullName():find("EMSObject", 1, true) then return Save end
            Fallback = Fallback or Save
        end
    end
    return Fallback
end

local function ObjectPath(Object)
    if not (Object and Object:IsValid()) then return "" end
    return (Object:GetFullName():gsub("^%S+%s+", ""))
end

local function LoadByPath(Path)
    if Path == "" then return nil end
    local Object = StaticFindObject(Path)
    if Object and Object:IsValid() then return Object end
    local ok, Loaded = pcall(LoadAsset, Path)
    if ok and Loaded and Loaded:IsValid() then return Loaded end
    return nil
end

local function SerializeAppearance(Save)
    local Parts = {}
    for _, Field in ipairs(APPEARANCE_TEXTS) do
        Parts[#Parts + 1] = Field .. "=" .. Encode(Safe(function() return Save[Field]:ToString() end, ""))
    end
    for _, Field in ipairs(APPEARANCE_OBJECTS) do
        Parts[#Parts + 1] = Field .. "=" .. Encode(ObjectPath(Safe(function() return Save[Field] end)))
    end
    return table.concat(Parts, ";")
end

local function ParseFields(Text)
    local Fields = {}
    for Key, Value in Text:gmatch("([%w_]+)=([^;]*)") do Fields[Key] = Decode(Value) end
    return Fields
end

-- untrusted_paths (CORE-14): Aussehen kommt vom Gast (Text frei waehlbar). Zulaessige Ordner: alle Assets aus
-- Charakter-Editor/Friseur/Neues Spiel liegen unter /Game/PlayerModel/ (Decode CharacterCreatorMenu_C,
-- CharacterBarberMenu_C, NewGameDifficultySelectionPage_C). Klasse je Feld wie SetSexMesh sie benutzt (@01ca ff.:
-- *Type -> SetStaticMesh, *Color -> SetMaterial). Feste Basisklasse statt der des eigenen Werts: der kann leer sein
-- oder eine Unterklasse (MaterialInstanceConstant) und haette gueltige Materialien abgelehnt.
Coop.APPEAR_PREFIXES = { "/Game/PlayerModel/" }
Coop.APPEAR_CLASS = { SkinColor = "/Script/Engine.MaterialInterface", HairColor = "/Script/Engine.MaterialInterface",
    BeardColor = "/Script/Engine.MaterialInterface", HairType = "/Script/Engine.StaticMesh",
    MouthType = "/Script/Engine.StaticMesh", EyebrowsType = "/Script/Engine.StaticMesh", BeardType = "/Script/Engine.StaticMesh",
    AccessoryType1 = "/Script/Engine.StaticMesh", AccessoryType2 = "/Script/Engine.StaticMesh",
    AccessoryType3 = "/Script/Engine.StaticMesh" }

-- Pfad eines Gasts laden duerfen? ls_core Core.SafeGuestPath (E24), ohne ls_core dieselbe Pruefung hier
function Coop.SafeAppearPath(Path)
    if Path == "" then return true end
    local LC = Coop.Modules and Coop.Modules.ls_core
    if LC and type(LC.SafeGuestPath) == "function" then
        local ok, Res = pcall(LC.SafeGuestPath, Path, Coop.APPEAR_PREFIXES)
        if ok then return Res == true end
    end
    if type(Path) ~= "string" or #Path > 200 or not Path:match("^/Game/[%w_/]+%.[%w_]+$") then return false end
    local Low = Path:lower()
    if Low:find("/maps/", 1, true) or Low:find("/levels/", 1, true) then return false end
    for _, P in ipairs(Coop.APPEAR_PREFIXES) do if Path:sub(1, #P) == P then return true end end
    return false
end

-- Host: Aussehen-Text eines Gasts neu bauen - nur bekannte Felder, Namen gekuerzt ohne Steuerzeichen, unzulaessige
-- Pfade leer. Nur dieser Text wird angewendet und an die anderen weitergegeben. Rueckgabe: Text, Zahl verworfener Pfade
function Coop.SanitizeAppearance(Text)
    local Fields, Parts, Bad = ParseFields(Text), {}, 0
    for _, Field in ipairs(APPEARANCE_TEXTS) do
        local Value = tostring(Fields[Field] or ""):gsub("%c", ""):sub(1, 40)
        Parts[#Parts + 1] = Field .. "=" .. Encode(Value)
    end
    for _, Field in ipairs(APPEARANCE_OBJECTS) do
        local Path = Fields[Field] or ""
        if Path ~= "" and not Coop.SafeAppearPath(Path) then Path, Bad = "", Bad + 1 end
        Parts[#Parts + 1] = Field .. "=" .. Encode(Path)
    end
    return table.concat(Parts, ";"), Bad
end

-- Objekt fuer ein Aussehen-Feld: StaticFindObject zuerst, LoadAsset nur fuer zulaessige Pfade, nur mit der erwarteten
-- Klasse des Felds; sonst nil (Feld leer, wie ein leerer Pfad)
function Coop.AppearObject(Field, Path)
    if type(Path) ~= "string" or Path == "" then return nil end
    local Obj = StaticFindObject(Path)
    if not IsAlive(Obj) then
        Obj = nil
        if Coop.SafeAppearPath(Path) then
            local ok, Loaded = pcall(LoadAsset, Path)
            if ok and IsAlive(Loaded) then Obj = Loaded end
        end
    end
    if not Obj then return nil end
    local Cls = Coop.APPEAR_CLASS[Field] and StaticFindObject(Coop.APPEAR_CLASS[Field])
    if not (IsAlive(Cls) and Safe(function() return Obj:IsA(Cls) end, false) == true) then return nil end
    return Obj
end

local function ApplyAppearance(Pawn, Text)
    local Save = PlayerSave()
    if not (IsAlive(Save) and IsAlive(Pawn)) then return false end
    local Wanted, Backup = ParseFields(Text), {}
    for _, Field in ipairs(APPEARANCE_TEXTS) do Backup[Field] = Save[Field]:ToString() end
    for _, Field in ipairs(APPEARANCE_OBJECTS) do Backup[Field] = Save[Field] end
    local Strict = Coop.FlagOn("untrusted_paths", true)   -- CORE-14: Klassenpruefung, LoadAsset nur fuer zulaessige Pfade
    local ok, err = pcall(function()
        for _, Field in ipairs(APPEARANCE_TEXTS) do
            if Wanted[Field] then Save[Field] = Wanted[Field] end
        end
        for _, Field in ipairs(APPEARANCE_OBJECTS) do
            if Wanted[Field] then
                if Strict then Save[Field] = Coop.AppearObject(Field, Wanted[Field])
                else Save[Field] = LoadByPath(Wanted[Field]) end
            end
        end
        Pawn:SetSexMesh()
    end)
    for _, Field in ipairs(APPEARANCE_TEXTS) do pcall(function() Save[Field] = Backup[Field] end) end
    for _, Field in ipairs(APPEARANCE_OBJECTS) do
        local Old = Backup[Field]
        pcall(function() Save[Field] = (Old and Old:IsValid()) and Old or nil end)
    end
    if not ok then Log("Aussehen anwenden fehlgeschlagen: %s", tostring(err)) end
    return ok
end

local function PlayerIdOf(Pawn)
    return Safe(function()
        local PS = Pawn.PlayerState
        if PS and PS:IsValid() then return PS:GetPlayerId() end
    end)
end

-- Kleidung: Beim Anlegen schickt der Host die Kleidung per MC_AttachClothing (unzuverlaessiger
-- Multicast) an alle. Wer da noch nicht verbunden war, sieht die Figur nackt. Die OnRep-Funktionen
-- der Kleidungs-Slots nehmen beim Host den Server-Weg und verschicken den Multicast erneut.
local CLOTHING_ONREPS = { "OnRep_ClothingTorsoEquipped?", "OnRep_ClothingGlovesEquipped?",
    "OnRep_ClothingLegsEquipped?", "OnRep_ClothingFeetEquipped?" }

-- Nie, waehrend die Figur etwas in der Hand haelt: Der Multicast (UpdateBodyParts) setzt bei allen Rechnern
-- die Animation der Figur zurueck - die Waffe sitzt dann bis zum Wegstecken falsch, auch beim Zielen.
-- Gibt false zurueck, wenn verschoben (der Aufrufer versucht es spaeter erneut).
-- Hand-Sockets enden auf "_r" (Weapon_r Gewehre, Sidearm_r Pistolen, MeleeWeapon_r Messer); weggesteckt heissen sie
-- ohne "_r" (Sidearm, SmallMeleeWeapon, ...). Frueher zaehlte nur Weapon_r: die Glock in der Hand (Sidearm_r) galt
-- als weggesteckt (Munitionsanzeige weg nach jedem Schuss, Kleidung mitten im Zielen nachgeschickt).
function Coop.IsHandSocket(Name) return type(Name) == "string" and #Name > 2 and Name:sub(-2) == "_r" end

-- COMBAT-3 (E9): Waffe in der Hand nach Spiel-Sicht (ls_combat Coop.CombatActiveWeapon: BP_JigHelperComp.ActiveWeapon +
-- RepActorsData, beides repliziert). Der Socket "*_r" taugt in 5.6 nicht mehr. Rueckgabe: Waffe|nil, Slot|nil,
-- Entschieden (true = gilt, auch "Hand frei"; false = Socket-Weg als Rueckfall, z. B. ohne ls_combat)
function Coop.ActiveHand(Pawn)
    local F = Coop.CombatActiveWeapon
    if type(F) ~= "function" then return nil, nil, false end
    local ok, W, Slot, Readable = pcall(F, Pawn)
    if not ok then return nil, nil, false end
    if W ~= nil and IsAlive(W) then return W, Slot, true end
    return nil, Slot, Readable == true
end

-- Erster Actor an einem Hand-Socket der Figur und sein Socket (nil: Hand frei); COMBAT-3: zuerst die aktive Waffe
-- (dritter Wert = ihr Slot), der Socket-Weg nur, wenn ls_combat nichts entscheiden konnte
function Coop.HandItem(Pawn)
    if not IsAlive(Pawn) then return nil end
    local W, Slot, Decided = Coop.ActiveHand(Pawn)
    if W then return W, Safe(function() return W:GetAttachParentSocketName():ToString() end, "?"), Slot end
    if Decided then return nil end
    local Attached = {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local A = Entry:get()
        local Socket = IsAlive(A) and A:GetAttachParentSocketName():ToString()
        if Socket and Coop.IsHandSocket(Socket) then return A, Socket end
    end
    return nil
end

-- Kleidung wartet, weil etwas in der Hand ist: je Socket einmal ins Log (haengt dort dauerhaft etwas, sieht man es)
-- Runde 4: nur Gewehre (Weapon_r) sperren, wie urspruenglich. Mit Sidearm_r/MeleeWeapon_r blieb der Mitspieler nackt,
-- solange er Pistole/Messer hielt. Und hoechstens HAND_BLOCK_MAX s: dann lieber einmal die Waffe verrutschen lassen
-- als nackt bleiben. HandWait: [Figurenname] = wartet seit (os.clock), nur Namen
Coop.HandLogged, Coop.HandWait, Coop.HAND_BLOCK_MAX = {}, {}, 5
-- COMBAT-3: Gewehr = aktive Waffe in einem Gewehr-Slot (Slot-Tags laut Decode); ohne Slot (Socket-Rueckfall) Weapon_r
Coop.RIFLE_SLOTS = { ["Jig.PlayerSlot.PrimaryWeapon"] = true, ["Jig.PlayerSlot.SecondaryWeapon"] = true,
                     ["Jig.PlayerSlot.Primary"] = true, ["Jig.PlayerSlot.Secondary"] = true }
function Coop.HandBlocked(Pawn)
    local ok, Item, Socket, Slot = pcall(Coop.HandItem, Pawn)
    local Name = Safe(function() return Pawn:GetFName():ToString() end, "?")
    local Rifle = ok and Item ~= nil and ((Slot ~= nil and Coop.RIFLE_SLOTS[Slot] == true) or (Slot == nil and Socket == "Weapon_r"))
    if not Rifle then Coop.HandWait[Name] = nil return false end
    local Now = os.clock()
    Coop.HandWait[Name] = Coop.HandWait[Name] or Now
    if Now - Coop.HandWait[Name] >= Coop.HAND_BLOCK_MAX then
        Coop.HandWait[Name] = nil
        Log("Kleidung von %s trotz Waffe in der Hand nachgeschickt (wartete %d s)", Name, Coop.HAND_BLOCK_MAX)
        return false
    end
    if not Coop.HandLogged[Slot or Socket] then
        Coop.HandLogged[Slot or Socket] = true
        Log("Kleidung wartet: %s in der Hand (Socket %s, Slot %s)", Safe(function() return Item:GetClass():GetFName():ToString() end, "?"),
            tostring(Socket), tostring(Slot))
    end
    return true
end

local function ResendClothing(Pawn)
    if Coop.HandBlocked(Pawn) then return false end
    for _, Name in ipairs(CLOTHING_ONREPS) do pcall(function() Pawn[Name](Pawn) end) end
    return true
end

-- Kleidungsstand einer Figur (Slots belegt + angezeigte Modelle). Aendert er sich (an-/ausziehen,
-- tauschen), kommt der Multicast beim Wieder-Anziehen oft nicht an: Dann wird nachgeschickt.
local CLOTHING_FLAGS = { "ClothingTorsoEquipped?", "ClothingGlovesEquipped?", "ClothingLegsEquipped?",
    "ClothingFeetEquipped?" }
local CLOTHING_MESHES = { "Clothing_Torso", "Clothing_Gloves", "Clothing_Legs", "Clothing_Feet", "Clothing_Armor" }

local function ClothingState(Pawn)
    local Parts = {}
    for _, Name in ipairs(CLOTHING_FLAGS) do
        Parts[#Parts + 1] = Safe(function() return tostring(Pawn[Name]) end, "?")
    end
    for _, Name in ipairs(CLOTHING_MESHES) do
        Parts[#Parts + 1] = Safe(function()
            local Mesh = Pawn[Name]
            local Asset = IsAlive(Mesh) and Mesh:GetSkeletalMeshAsset()
            return IsAlive(Asset) and Asset:GetFName():ToString() or "-"
        end, "?")
    end
    return table.concat(Parts, ",")
end

local HostAppearance = {}      -- [PlayerId] = Text (Host eigenes + alle Mitspieler)
local HostApplied = {}         -- [PlayerId] = Figurenname, auf die es beim Host angewendet ist
local SentAppearance = {}      -- [Controller-Key] = { [PlayerId] = Text }
local ClothingResendAt = {}    -- Zeitpunkte (os.clock), zu denen die Kleidung erneut verschickt wird
local ClothingPawn = {}        -- [PlayerId] = Figurenname, fuer die das Nachschicken geplant ist
local ClothingSeen = {}        -- [Figurenname] = Kleidungsstand beim letzten Durchlauf
local ClothingResendFor = {}   -- [Figurenname] = Zeitpunkte (os.clock), zu denen nur diese Figur nachgeschickt wird

local function PlayerPawns()
    local Pawns = {}
    for _, Pawn in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if IsAlive(Pawn) then Pawns[#Pawns + 1] = Pawn end
    end
    return Pawns
end

-- appear_prune (CORE-7): Die PlayerId ist je Anmeldung neu, die Tabellen wuchsen mit jedem Beitritt (SentAppearance mit
-- Beitritten^2) und jeder Neue bekam alle alten Aussehen auf einmal. Aussehen/Merker getrennter Spieler 60 s nach dem
-- letzten Sehen vergessen; SentAppearance nur fuer verbundene Controller und vorhandene Aussehen. Alle 5 s.
function Coop.PruneHostAppearance(States, HostId, Now)
    if Now < (Coop.AppearPruneAt or 0) then return end
    Coop.AppearPruneAt = Now + 5
    Coop.AppearSeen = Coop.AppearSeen or {}
    local Seen, LiveId, LiveKey, Ids, Dropped = Coop.AppearSeen, {}, {}, {}, 0
    if HostId then LiveId[HostId] = true end
    for _, PS in ipairs(States) do
        local Id = Safe(function() return PS:GetPlayerId() end)
        if Id then LiveId[Id] = true end
        local K = Safe(function() local PC = PS:GetOwner() return IsAlive(PC) and PC:GetFullName() or nil end)
        if K then LiveKey[K] = true end
    end
    for Id in pairs(HostAppearance) do Ids[Id] = true end
    for Id in pairs(HostApplied) do Ids[Id] = true end
    for Id in pairs(ClothingPawn) do Ids[Id] = true end
    for Id in pairs(Ids) do
        if LiveId[Id] or not Seen[Id] then
            Seen[Id] = Now
        elseif Now - Seen[Id] > 60 then
            HostAppearance[Id], HostApplied[Id], ClothingPawn[Id], Seen[Id] = nil, nil, nil, nil
            Dropped = Dropped + 1
        end
    end
    for Id in pairs(Seen) do if not Ids[Id] then Seen[Id] = nil end end
    for Key, Sent in pairs(SentAppearance) do
        if not LiveKey[Key] then
            SentAppearance[Key] = nil
        else
            for Id in pairs(Sent) do if HostAppearance[Id] == nil then Sent[Id] = nil end end
        end
    end
    if Dropped > 0 then Log("Aussehen: %d getrennte Spieler vergessen", Dropped) end
end

local function HandleHostAppearance(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Now = os.clock()   -- alle Kleidungs-Zeitpunkte in os.clock (wie der Schnell-Loop und "cloth")
    -- Figurenliste (FindAllOf) nur hier, 1x/s; der Schnell-Loop (Coop.ClothFast) arbeitet auf dieser Liste
    local Pawns = PlayerPawns()
    Coop.ClothFast.Pawns = Pawns
    local HostPawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local HostId = IsAlive(HostPawn) and PlayerIdOf(HostPawn)
    if HostId and not HostAppearance[HostId] and IsAlive(PlayerSave()) then
        HostAppearance[HostId] = SerializeAppearance(PlayerSave())
    end
    local States = PlayerStates(World)
    local Prune = Coop.FlagOn("appear_prune", true)
    if Prune then
        local okP, errP = pcall(Coop.PruneHostAppearance, States, HostId, Now)
        if not okP then Coop.FlagFail("appear_prune", errP) end
    end
    -- Einzelne Kleidungs-Plaetze, um die Mitspieler gebeten haben (nicht mit Waffe in der Hand, sonst spaeter)
    local Queue, Later = Coop.ClothSlotQueue, {}
    Coop.ClothSlotQueue = Later
    for _, Req in ipairs(Queue) do
        for _, Pawn in ipairs(Pawns) do
            if PlayerIdOf(Pawn) == Req.Id and CLOTHING_ONREPS[Req.Index] then
                if Coop.HandBlocked(Pawn) then
                    Later[#Later + 1] = Req
                else
                    pcall(function() Pawn[CLOTHING_ONREPS[Req.Index]](Pawn) end)
                    -- Wie sieht der Host den Platz? (Nach dem Tod liegen die Schuhe in der Todes-Kiste.)
                    local Server = Safe(function()
                        local Mesh = Pawn[CLOTHING_MESHES[Req.Index]]
                        local Asset = IsAlive(Mesh) and Mesh:GetSkeletalMeshAsset()
                        return tostring(Pawn[CLOTHING_FLAGS[Req.Index]]) .. "/" .. (IsAlive(Asset) and Asset:GetFName():ToString() or "-")
                    end, "?")
                    Log("Kleidung %s von Spieler %d einzeln nachgeschickt (beim Host: %s)", CLOTHING_ONREPS[Req.Index], Req.Id, Server)
                end
            end
        end
    end
    -- Mitspieler-Figuren beim Host so aussehen lassen, wie ihr Besitzer sie gebaut hat.
    -- (Kleidungsstand vergleichen und Nachsendungen abarbeiten: Coop.ClothFast.Tick im Schnell-Loop)
    for _, Pawn in ipairs(Pawns) do
        local Id = PlayerIdOf(Pawn)
        local Name = Pawn:GetFName():ToString()
        -- Neue Figur (Beitritt oder Respawn, auch beim Host): Der Kleidungs-Multicast kommt oft,
        -- bevor der Mitspieler die Figur kennt. Unabhaengig vom Aussehen mehrmals nachschicken.
        -- (cloth_fast: wieder die alten Stufen +2/+5/+10 s, die frueheren kamen vor der fertigen Figur)
        if Id and ClothingPawn[Id] ~= Name then
            ClothingPawn[Id] = Name
            for _, Delay in ipairs(SETTINGS.cloth_fast and { 2, 5, 10 } or { 0.5, 2, 5 }) do Coop.ClothFast.At(Now + Delay) end
        end
        if Id and Id ~= HostId and HostAppearance[Id] and HostApplied[Id] ~= Name then
            HostApplied[Id] = Name
            local ok = ApplyAppearance(Pawn, HostAppearance[Id])
            Log("Aussehen von Spieler %d auf %s angewendet: %s", Id, Name, ok and "ok" or "Fehler")
            Coop.ClothFast.At(Now + 1)
        end
    end
    -- Jedem Mitspieler alle Aussehen schicken, die er noch nicht hat (appear_prune: hoechstens 4 je Durchlauf und
    -- Mitspieler, der Rest in den naechsten Sekunden - sonst ein Stoss zuverlaessiger Nachrichten beim Beitritt)
    for _, PS in ipairs(States) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            SentAppearance[Key] = SentAppearance[Key] or {}
            local NewData, Budget = false, Prune and 4 or math.huge
            for Id, Text in pairs(HostAppearance) do
                if SentAppearance[Key][Id] ~= Text and Budget > 0 then
                    Budget = Budget - 1
                    SentAppearance[Key][Id] = Text
                    SendChunked(function(T) SendToClient(PC, T) end, "appear", Id .. "#" .. Text)
                    NewData = true
                end
            end
            if NewData then
                -- Erst nachdem der Mitspieler das Aussehen angewendet hat, Kleidung erneut schicken
                -- (zweimal, der Multicast ist unzuverlaessig).
                Coop.ClothFast.At(Now + 3)
                Coop.ClothFast.At(Now + 6)
            end
        end
    end
end

-- Schnell-Loop (nur Host): Kleidungsstand der Figuren 5x/s vergleichen, faellige Nachsendungen 10x/s abarbeiten.
-- Figuren aus der Liste von HandleHostAppearance (1x/s, kein FindAllOf hier). Now = os.clock.
-- Wait: [Figurenname] = naechster Versuch, solange sie eine Waffe in der Hand haelt (nicht 10x/s nachfragen)
-- cloth_fast: Pend = [Figurenname] = { State, At } (neuer Stand, noch nicht 0,5 s stabil), Quiet = Ruhe bis (os.clock,
-- G.Sync setzt es), LastAll = letzte Nachsendung an alle Figuren
Coop.ClothFast = { N = 0, Pawns = {}, Wait = {}, Pend = {}, Quiet = 0, LastAll = -10 }

-- Nachsendung an alle Figuren einplanen. cloth_fast: Zeitpunkte naeher als 1,5 s an einem schon geplanten fallen weg
-- (mehrere Anlaesse auf einmal = eine Nachsendung); sonst wie bisher jeder einzeln.
function Coop.ClothFast.At(T)
    if SETTINGS.cloth_fast then
        for _, Old in ipairs(ClothingResendAt) do if math.abs(Old - T) < 1.5 then return end end
    end
    ClothingResendAt[#ClothingResendAt + 1] = T
end

-- cloth_fast: Bitte eines Mitspielers ("cloth") nur einmal und nur, wenn in den letzten 2 s keine Nachsendung an alle
-- lief und in den naechsten 3 s keine geplant ist. Laeuft im Empfangs-Hook: nur Tabellen, keine UFunction.
function Coop.ClothFast.Ask(Now)
    local CF = Coop.ClothFast
    if Now - CF.LastAll < 2 then return end
    for _, T in ipairs(ClothingResendAt) do if T - Now < 3 then return end end
    ClothingResendAt[#ClothingResendAt + 1] = Now
end

-- cloth_fast: Eine Aenderung zaehlt erst, wenn der neue Stand 0,5 s gleich bleibt (Umziehen und der Inventar-Abgleich
-- setzen die Plaetze nacheinander). Dann nur diese Figur nachschicken (sofort und nach 0,8 s). Im Ruhefenster nur merken.
function Coop.ClothFast.Settle(Name, State, Now, Quiet)
    local CF, Seen = Coop.ClothFast, ClothingSeen[Name]
    if Seen == nil or Seen == State or Quiet then
        ClothingSeen[Name], CF.Pend[Name] = State, nil
        return
    end
    local P = CF.Pend[Name]
    if not P or P.State ~= State then CF.Pend[Name] = { State = State, At = Now } return end
    if Now - P.At < 0.5 then return end
    Log("Kleidung von %s geaendert (%.1f s stabil)", Name, Now - P.At)
    ClothingResendFor[Name] = { Now, Now + 0.8 }
    ClothingSeen[Name], CF.Pend[Name] = State, nil
end

function Coop.ClothFast.Tick(Now, Mode)
    local CF = Coop.ClothFast
    if Mode ~= "ListenServer" then CF.Pawns = {} return end
    CF.N = CF.N + 1
    -- cloth_fast: Ruhefenster nach dem Inventar-Abgleich: Stand weiter merken, faellige Nachsendungen warten
    local Quiet = SETTINGS.cloth_fast and Now < CF.Quiet
    for _, Pawn in ipairs(CF.Pawns) do
        if IsAlive(Pawn) then
            local Name = Pawn:GetFName():ToString()
            if CF.N % 2 == 0 and SETTINGS.cloth_fast then
                CF.Settle(Name, ClothingState(Pawn), Now, Quiet)
            elseif CF.N % 2 == 0 then
                local State = ClothingState(Pawn)
                -- An-/Ausziehen: nur diese Figur nachschicken (sofort und nach 0,8 s), egal wie viele Spieler da sind.
                if ClothingSeen[Name] and ClothingSeen[Name] ~= State then
                    Log("Kleidung von %s geaendert", Name)
                    ClothingResendFor[Name] = { Now, Now + 0.8 }
                end
                ClothingSeen[Name] = State
            end
            local Times = ClothingResendFor[Name]
            if Times and not Quiet and Now >= (CF.Wait[Name] or 0) then
                -- Einmal senden deckt alle faelligen Zeitpunkte ab. Verschoben (Waffe in der Hand): bleibt faellig
                -- und wird alle 0,5 s erneut versucht
                local Due = false
                for I = 1, #Times do if Now >= Times[I] then Due = true break end end
                if Due and ResendClothing(Pawn) then
                    for I = #Times, 1, -1 do if Now >= Times[I] then table.remove(Times, I) end end
                elseif Due then
                    CF.Wait[Name] = Now + 0.5
                end
                if #Times == 0 then ClothingResendFor[Name], CF.Wait[Name] = nil, nil end
            end
        end
    end
    if Quiet then return end
    local Due = false
    for I = #ClothingResendAt, 1, -1 do
        if Now >= ClothingResendAt[I] then table.remove(ClothingResendAt, I) Due = true end
    end
    if Due then
        CF.LastAll = Now
        local Pawns, Later = {}, 0
        for _, Pawn in ipairs(CF.Pawns) do if IsAlive(Pawn) then Pawns[#Pawns + 1] = Pawn end end
        for _, Pawn in ipairs(Pawns) do
            if not ResendClothing(Pawn) then
                -- Waffe in der Hand: diese Figur einzeln nachschicken, sobald die Hand frei ist
                local Name = Pawn:GetFName():ToString()
                ClothingResendFor[Name] = ClothingResendFor[Name] or { Now }
                Later = Later + 1
            end
        end
        Log("Kleidung aller %d Spielerfiguren erneut verschickt%s", #Pawns,
            Later > 0 and string.format(" (%d mit Waffe in der Hand: spaeter)", Later) or "")
    end
end

local function OnClientData(PC, Text)
    local Key = PC:GetFullName()
    local Kind, Data = Reassemble(Key, Text)
    if not Kind then return end
    -- fuer den Haenger-Waechter (landet im Log: Passwort und Chat ohne Inhalt)
    Coop.LastStep = Kind .. " " .. os.date("%H:%M:%S") .. " " .. ((Kind == "auth" or Kind == "chat") and "-" or tostring(Data):sub(1, 40))
    if Kind == "appear" then
        local Id = Safe(function() local PS = PC.PlayerState return IsAlive(PS) and PS:GetPlayerId() or nil end)
        -- untrusted_paths (CORE-14): nur den bereinigten Text halten, anwenden und weitergeben
        if Id and Coop.FlagOn("untrusted_paths", true) then
            local okS, Clean, Bad = pcall(Coop.SanitizeAppearance, Data)
            if not okS then
                Coop.FlagFail("untrusted_paths", Clean)
                Data = nil   -- nie ungeprueft weitergeben
            else
                if Bad > 0 then Log("Aussehen von Spieler %d: %d unzulaessige Pfade verworfen", Id, Bad) end
                Data = Clean
            end
        end
        if Id and Data and HostAppearance[Id] ~= Data then
            HostAppearance[Id], HostApplied[Id] = Data, nil
            Log("Aussehen von Spieler %d erhalten (%d Zeichen)", Id, #Data)
        end
    elseif Kind == "guestid" then
        local Id, PawnName = Data:match("^(%x+)#(.+)$")
        if Id and not Coop.BindGuestId(Key, PC, Id) then Id = nil end   -- ID-Wechsel am selben Controller: verworfen
        if Id and Coop.GuestIds[Key] ~= Id then Log("Mitspieler-ID erhalten: %s", Id) end
        if Id then Coop.GuestIds[Key], Coop.SyncRequest[Key] = Id, PawnName end
    elseif Kind == "cloth" then
        -- Mitspieler bittet um die Kleidung aller Figuren (sofort und 2 s spaeter; os.clock wie alle Kleidungs-Zeiten).
        -- cloth_fast: einmal, nicht kurz nach/vor einer anderen Nachsendung an alle (Coop.ClothFast.Ask)
        if SETTINGS.cloth_fast then
            Coop.ClothFast.Ask(os.clock())
        else
            ClothingResendAt[#ClothingResendAt + 1] = os.clock()
            ClothingResendAt[#ClothingResendAt + 1] = os.clock() + 2
        end
    elseif Kind == "clothslot" then
        -- Nur ein Platz einer Figur ("SpielerId#Platz"): Alle vier Multicasts auf einmal kamen nicht immer an
        -- (die Schuhe als letzter fehlten), einzeln schon. Abgearbeitet in HandleHostAppearance.
        local Id, Index = Data:match("^(%d+)#(%d)$")
        if Id then Coop.ClothSlotQueue[#Coop.ClothSlotQueue + 1] = { Id = tonumber(Id), Index = tonumber(Index) } end
    elseif Kind == "hb" then
        pcall(Coop.Link.OnBeat, PC, Data)   -- Lebenszeichen jede Sekunde (Schutz bei Verbindungsabbruch), mit Steam-ID
    elseif Kind == "admin" then
        -- Admin-Befehl aus dem Spiel; server.lua prueft, ob der Absender Admin ist
        if Coop.OnAdminCommand then
            local ok, err = pcall(Coop.OnAdminCommand, PC, Data)
            if not ok then Log("Admin-Befehl fehlerhaft: %s", tostring(err)) end
        end
    elseif Kind == "auth" then
        if Coop.OnAuth then pcall(Coop.OnAuth, PC, Data) end   -- Server-Passwort (nie loggen)
    elseif Kind == "chat" then
        if Coop.OnChat then
            local ok, err = pcall(Coop.OnChat, PC, Data)
            if not ok then Log("Chat-Nachricht fehlerhaft: %s", tostring(err)) end
        end
    elseif Kind == "pend" then
        -- Gegenstand, den das Spiel beim Mitspieler nur lokal erzeugt hat (leere Flasche ...): server.lua legt ihn an
        -- Legacy-Weg: nur mit inv_reconcile und ohne ls_inv v2b (wie Srv.PendingAdd), sonst still verwerfen
        local InvMod = Coop.Modules and Coop.Modules.ls_inv
        local V2b = InvMod and InvMod.Active and select(2, pcall(InvMod.Active)) == true
        if SETTINGS.inv_reconcile and not V2b and Coop.OnPendingAdd then
            local ok, err = pcall(Coop.OnPendingAdd, PC, Data)
            if not ok then Log("Gegenstand fuer Mitspieler fehlerhaft: %s", tostring(err)) end
        end
    elseif Kind == "consumed" then
        -- consume_fix: Gegenstand nach dem Verbrauch beim Mitspieler ("<Pfad>|<n>", leere Flasche): server.lua merkt ihn
        -- nur vor (hier im Empfangs-Hook) und legt ihn im naechsten Tick vor die Fuesse
        if Coop.OnConsumed then
            local ok, err = pcall(Coop.OnConsumed, PC, Data)
            if not ok then Log("Verbrauch des Mitspielers fehlerhaft: %s", tostring(err)) end
        end
    elseif Kind == "car" then
        local ok, err = pcall(Coop.Car.OnClient, PC, Data)   -- Fahrzeug des Mitspielers (Lage, Tanken, Reparieren)
        if not ok and not Coop.Car.ErrLogged then Coop.Car.ErrLogged = true Log("Fahrzeug-Nachricht fehlerhaft: %s", tostring(err)) end
    elseif Kind == "noise" then
        local ok, err = pcall(Coop.OnGuestNoise, PC, Data)
        if not ok then Log("Geraeusch des Mitspielers fehlerhaft: %s", tostring(err)) end
    elseif Kind == "vit" then
        local ok, err = pcall(Coop.Stats.OnGuestValues, Key, PC, Data)
        if not ok then Log("Werte des Mitspielers fehlerhaft: %s", tostring(err)) end
    elseif Kind == "vitspend" then
        pcall(Coop.Stats.OnSpend, Key, Data)   -- Skillpunkt-Ausgaben des Mitspielers (nur merken, s. V.OnSpend)
    elseif Kind == "hello" then
        -- Protokoll-Version des Mitspielers (hp_v2, Zombie-Leben weiter unten): "2|<Mitspieler-ID>"
        if Coop.OnHello then
            local ok, err = pcall(Coop.OnHello, Key, PC, Data)
            if not ok then Log("hello des Mitspielers fehlerhaft: %s", tostring(err)) end
        end
    elseif Kind == "ready" then
        -- join_v2: Mitspieler ist am Ziel bereit (Ladebildschirm zu). Nur merken, freigeben im Schnell-Loop.
        if Coop.Join then pcall(Coop.Join.OnReady, Key) end
    elseif Coop.Net then
        Coop.Net.PushLegacy(Key, Kind, Data)   -- Runde 5: unbekannte alte Art -> ls_net-Handler (100-ms-Task)
    end
end
Coop.Inbox.Client = OnClientData   -- WP0: abgearbeitet in Coop.Inbox.Tick (nicht im Empfangs-Hook)
Coop.ClothSlotQueue = {}       -- { Id = PlayerId, Index = Platz in CLOTHING_ONREPS }, vom Mitspieler angefragt
Coop.GuestIds = {}             -- [Controller-Key] = feste ID des Mitspielers (ueber Beitritte hinweg)
Coop.SyncRequest = {}          -- [Controller-Key] = Figur, fuer die der Mitspieler den Abgleich will
-- Mitspieler-ID an das Controller-Objekt binden: die erste gemeldete ID (hello/guestid) gilt, eine andere spaeter wird
-- verworfen (sonst speicherte G.Store das Inventar unter einer zweiten ID, jede neue ID gab neue Startausruestung).
-- Ein neues Controller-Objekt unter demselben Namen (Wiederbeitritt) bindet neu. [Key] = { Id, Addr }
Coop.IdBind = {}
function Coop.BindGuestId(Key, PC, Id)
    local Addr = Safe(function() return PC:GetAddress() end)
    local B, Low = Coop.IdBind[Key], tostring(Id):lower()
    if B and Addr and B.Addr == Addr then
        if B.Id == Low then return true end
        if B.Warned ~= Low then
            B.Warned = Low
            Log("Mitspieler-ID-Wechsel von %s abgelehnt (%s -> %s)", Key:match("[^%.]+$") or Key, B.Id, Low)
        end
        return false
    end
    Coop.IdBind[Key] = { Id = Low, Addr = Addr }
    return true
end

-- Nur auf dem Server (empfaengt): Beim Spieler feuerte der Hook bei jedem eigenen Senden, oft mitten in einem
-- anderen Hook (z. B. Geraeusch bei jedem Schuss) - ein Hook im Hook ist in UE4SS nicht stabil.
if os.getenv("LASTSIGNAL_SERVER") == "1" or os.getenv("NETTEST_SERVER") == "1" then
    -- RecvHook: Empfang laeuft (join_v2 wartet nur dann auf das hello des Mitspielers)
    Coop.RecvHook = TryHook("/Script/Engine.PlayerController:ServerExecRPC", function(Context, Message)
        local Text = Safe(function() return Message:get():ToString() end, "")
        if Text:sub(1, #MESSAGE_PREFIX) ~= MESSAGE_PREFIX then return end
        local PC = Context:get()
        if not IsAlive(PC) then return end
        -- WP0: kein UFunction-Aufruf im Hook. Eigener Controller (Geist) per Lua-Vergleich mit dem im Schnell-Loop
        -- gemerkten Key; alte Nachrichten prueft Coop.Inbox.Tick zusaetzlich mit IsLocalController.
        local Key = Safe(function() return PC:GetFullName() end)
        if not Key or Key == Coop.Inbox.LocalKey then return end
        -- Runde 5: Protokoll v3 nur in die Inbox (ls_net), abgearbeitet im 100-ms-Task
        if Coop.Net and Text:sub(#MESSAGE_PREFIX + 1, #MESSAGE_PREFIX + 3) == "v3|" then
            Coop.Net.Push(Text:sub(#MESSAGE_PREFIX + 4), Key)
            return
        end
        Coop.Inbox.Push(Key, Text:sub(#MESSAGE_PREFIX + 1))   -- WP0: OnClientData im Schnell-Loop
    end) ~= nil
end

-- Mitspieler-Seite: eigenes Aussehen einmal pro Verbindung schicken, Aussehen der anderen
-- anwenden, sobald ihre Figur da ist (und nach jedem Respawn erneut).
local ClientAppearance = {}    -- [PlayerId] = Text
local ClientApplied = {}       -- [PlayerId] = Figurenname
local AppearanceSentFor = nil  -- eigene Figur, fuer die das Aussehen zuletzt geschickt wurde
local AppearanceRepeatAt = nil -- direkt nach dem Beitritt geht die erste Nachricht manchmal verloren

-- appear_prune (CORE-7, Mitspieler): Aussehen von Spielern ohne PlayerState (getrennt; PlayerStates sind immer
-- repliziert, auch ferne Spieler) 60 s nach dem letzten Sehen vergessen. Alle 5 s.
function Coop.PruneClientAppearance(World)
    local Now = os.clock()
    if Now < (Coop.AppearPruneAtC or 0) then return end
    Coop.AppearPruneAtC = Now + 5
    Coop.AppearSeenC = Coop.AppearSeenC or {}
    local Seen, Live = Coop.AppearSeenC, {}
    for _, PS in ipairs(PlayerStates(World)) do
        local Id = Safe(function() return PS:GetPlayerId() end)
        if Id then Live[Id] = true end
    end
    for Id in pairs(ClientAppearance) do
        if Live[Id] or not Seen[Id] then
            Seen[Id] = Now
        elseif Now - Seen[Id] > 60 then
            ClientAppearance[Id], ClientApplied[Id], Seen[Id] = nil, nil, nil
        end
    end
    for Id in pairs(ClientApplied) do if ClientAppearance[Id] == nil then ClientApplied[Id] = nil end end
    for Id in pairs(Seen) do if ClientAppearance[Id] == nil then Seen[Id] = nil end end
end

local function HandleClientAppearance(World)
    if NetModeName(World) ~= "Client" then
        AppearanceSentFor, AppearanceRepeatAt, ClientAppearance, ClientApplied = nil, nil, {}, {}
        Coop.ClothingAsk = nil
        return
    end
    if Coop.FlagOn("appear_prune", true) then
        local okP, errP = pcall(Coop.PruneClientAppearance, World)
        if not okP then Coop.FlagFail("appear_prune", errP) end
    end
    local Own = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Own) then return end
    local OwnName = Own:GetFName():ToString()
    local Now = os.time()
    local Save = Coop.ClientSave()   -- CORE-31: Save_Player einmal je Welt suchen
    if IsAlive(Save) and (AppearanceSentFor ~= OwnName
        or (AppearanceRepeatAt and Now >= AppearanceRepeatAt)) then
        if AppearanceSentFor ~= OwnName then Coop.ClothingAsk = { Now + 5, Now + 15, Now + 30 } end
        AppearanceRepeatAt = AppearanceSentFor ~= OwnName and Now + 10 or nil
        AppearanceSentFor = OwnName
        SendChunked(SendToHost, "appear", SerializeAppearance(Save))
        Log("Eigenes Aussehen an den Host geschickt")
    end
    local OwnId = PlayerIdOf(Own)
    for _, Pawn in ipairs(PlayerPawns()) do
        local Id = PlayerIdOf(Pawn)
        local Name = Pawn:GetFName():ToString()
        if Id and Id ~= OwnId and ClientAppearance[Id] and ClientApplied[Id] ~= Name then
            ClientApplied[Id] = Name
            local ok = ApplyAppearance(Pawn, ClientAppearance[Id])
            Log("Aussehen von Spieler %d auf %s angewendet: %s", Id, Name, ok and "ok" or "Fehler")
            Coop.ClothingAsk = Coop.ClothingAsk or {}
            Coop.ClothingAsk[#Coop.ClothingAsk + 1] = Now + 2
            Coop.ClothingAsk[#Coop.ClothingAsk + 1] = Now + 8
        end
    end
    -- SetSexMesh (beim Anwenden des Aussehens, auch vom Spiel beim Spawn) setzt die Fuesse zurueck: Schuhe
    -- waren beim Mitspieler bei allen weg. Danach die Kleidung beim Host neu anfordern, mehrmals (die ersten
    -- Anfragen nach dem Beitritt kamen zu frueh, bevor der Mitspieler seine Figuren fertig hatte).
    local Ask, Due = Coop.ClothingAsk, false
    for I = #(Ask or {}), 1, -1 do
        if Now >= Ask[I] then table.remove(Ask, I) Due = true end
    end
    if Due then SendChunked(SendToHost, "cloth", "1") end
end

local HostDataHandlers = {}  -- weitere Arten (z. B. Inventar zurueckschreiben) tragen sich unten ein

OnHostData = function(Text)
    local Kind, Data = Reassemble("host", Text)
    if Kind and HostDataHandlers[Kind] then
        local ok, err = pcall(HostDataHandlers[Kind], Data)
        if not ok then Log("Host-Daten '%s' fehlerhaft: %s", Kind, tostring(err)) end
    elseif Kind == "appear" then
        local Id, Appearance = Data:match("^(%-?%d+)#(.*)$")
        if Id then
            Id = tonumber(Id)
            ClientAppearance[Id], ClientApplied[Id] = Appearance, nil
            Log("Aussehen von Spieler %d vom Host erhalten", Id)
        end
    elseif Kind and Coop.Net then
        Coop.Net.PushLegacy("host", Kind, Data)   -- Runde 5: unbekannte alte Art -> ls_net-Handler (100-ms-Task)
    end
end

Coop.HandleHostAppearance, Coop.HandleClientAppearance = HandleHostAppearance, HandleClientAppearance
Coop.PlayerSave, Coop.LoadByPath, Coop.PlayerPawns = PlayerSave, LoadByPath, PlayerPawns
Coop.SendChunked, Coop.SendToHost, Coop.HostDataHandlers = SendChunked, SendToHost, HostDataHandlers
Coop.SendToClient, Coop.Encode, Coop.Decode = SendToClient, Encode, Decode
Coop.ResendAppearance = function() AppearanceSentFor = nil end

-- Runde 9 CORE-31 (perf_rates): Save_Player des Gasts (PlayerSave = FindAllOf) einmal je Welt; gemerkt wird nur das
-- EMS-Objekt (das Spiel legt es einmal an), IsAlive bei jeder Nutzung. Coop.DropWorldRefsHygiene leert den Merker.
Coop.ClientSave = function()
    if not Coop.PerfRates then return PlayerSave() end
    local C = Coop.SaveCache
    if C and C.Gen == WorldGen.N and IsAlive(C.Save) then return C.Save end
    local Save = PlayerSave()
    local Ems = IsAlive(Save) and Safe(function() return Save:GetFullName():find("EMSObject", 1, true) ~= nil end, false)
    Coop.SaveCache = Ems and { Gen = WorldGen.N, Save = Save } or nil
    return Save
end

-- Runde 9 WORLD-13 (E21, ls_world world_look): eigenes Aussehen als Text (Format wie "appear") bzw. das beim Server
-- gespeicherte Aussehen dauerhaft uebernehmen: Werte im eigenen Save_Player bleiben stehen (kein Zuruecksetzen wie
-- ApplyAppearance), SetSexMesh der eigenen Figur, danach erneut an den Host (AppearanceSentFor = nil). false = noch
-- nicht moeglich (keine Figur/kein Save_Player, Asset noch nicht ladbar), ls_world versucht es dann erneut.
Coop.AppearanceText = function()
    local Save = PlayerSave()
    if not IsAlive(Save) then return nil end
    return SerializeAppearance(Save)
end
Coop.ApplyOwnAppearance = function(Text)
    if type(Text) ~= "string" or Text == "" or #Text > 4000 then return false end
    local Save = PlayerSave()
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not (IsAlive(Save) and IsAlive(Pawn)) then return false end
    local Wanted, Objects, Missing = ParseFields(Text), {}, 0
    local Strict = Coop.FlagOn("untrusted_paths", true)
    for _, Field in ipairs(APPEARANCE_OBJECTS) do
        local Path = Wanted[Field]
        if Path == "" then
            Objects[Field] = false   -- leer = kein Objekt (z. B. kein Bart)
        elseif Path and not (Strict and not Coop.SafeAppearPath(Path)) then
            local Obj = Strict and Coop.AppearObject(Field, Path) or (not Strict and LoadByPath(Path)) or nil
            if Obj then Objects[Field] = Obj else Missing = Missing + 1 end
        end
    end
    if Missing > 0 then return false end
    local ok, err = pcall(function()
        for _, Field in ipairs(APPEARANCE_TEXTS) do
            if Wanted[Field] then Save[Field] = Wanted[Field] end
        end
        for _, Field in ipairs(APPEARANCE_OBJECTS) do
            if Objects[Field] ~= nil then Save[Field] = Objects[Field] or nil end
        end
        Pawn:SetSexMesh()
    end)
    if not ok then Log("Eigenes Aussehen vom Server: anwenden fehlgeschlagen: %s", tostring(err)) return false end
    AppearanceSentFor = nil
    return true
end
end

-- Mitternacht: Die GameMode zaehlt DaysSurvived nur fuer "Spieler 0" (Timer, kein Spieler in der
-- Aufrufkette) hoch. Jeder Mitspieler-Controller bekommt hier denselben Tag dazu.
local function OnMidnight()
    local World = CurrentWorld()
    if not IsAlive(World) or NetModeName(World) ~= "ListenServer" then return end
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            pcall(function() PC.DaysSurvived = PC.DaysSurvived + 1 end)
            Log("Mitternacht: %s hat jetzt %s Tage", PC:GetFName():ToString(), tostring(Safe(function() return PC.DaysSurvived end)))
        end
    end
end

-- Tod (Hooks): nur Figur bzw. MedicalComponent und Eigenschaften (PlayerState, Controller - kein UFunction-Aufruf)
-- merken. Das Spiel ruft im Tod UnPossess auf, danach sind beide leer: darum hier lesen, solange sie noch da sind.
-- Die Figur bleibt nach dem Tod noch 30 s stehen (Delay -> K2_DestroyActor), der Schnell-Loop findet sie also sicher.
Coop.DeathQ = {}
Coop.QueueDeath = function(Pawn, Fn, Comp)
    local Q = Coop.DeathQ
    if #Q >= 32 then return end
    local E = { Pawn = Pawn, Fn = Fn, Comp = Comp }
    if Pawn then
        E.PS = Safe(function() return Pawn.PlayerState end)
        E.Ctrl = Safe(function() return Pawn.Controller end)
    end
    Q[#Q + 1] = E
end

-- Schnell-Aufgabe "death" (100 ms): je Figur einmal NoteDeath (Server) und OnGuestDeath, mit dem im Hook gelesenen
-- Controller/PlayerState (Doppelte aus den vier Hooks zusammengefasst)
Coop.DeathFast = function(_, Mode)
    local Q = Coop.DeathQ
    if #Q == 0 then return end
    Coop.DeathQ = {}
    local List, ByName = {}, {}
    for _, E in ipairs(Q) do
        local Pawn = E.Pawn
        if not IsAlive(Pawn) and IsAlive(E.Comp) then Pawn = Safe(function() return E.Comp:GetOwner() end) end
        if IsAlive(Pawn) then
            local Name = Pawn:GetFName():ToString()
            local M = ByName[Name]
            if not M then M = { Pawn = Pawn, Name = Name, Fns = {} } ByName[Name] = M List[#List + 1] = M end
            if not M.PS and IsAlive(E.PS) then M.PS = E.PS end
            if not M.Ctrl and IsAlive(E.Ctrl) then M.Ctrl = E.Ctrl end
            M.Fns[#M.Fns + 1] = E.Fn
        end
    end
    for _, M in ipairs(List) do
        Log("TOD: %s (%s)", M.Name, table.concat(M.Fns, "/"))
        if Coop.NoteDeath and Mode == "ListenServer" then pcall(Coop.NoteDeath, M.Pawn, M.PS) end
        local PC = M.Ctrl or (M.PS and Safe(function() return M.PS.Owner end)) or nil
        local ok, err = pcall(Coop.OnGuestDeath, M.Pawn, IsAlive(PC) and PC or nil)
        if not ok then Log("Tod-Fehler: %s", tostring(err)) end
    end
end

local CharacterHooksDone = false
local CHARACTER_CLASS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

-- Zielfernrohr: Das Spiel versteckt die Waffe per SetActorHiddenInGame. Die Waffe ist repliziert,
-- also verschwindet sie beim Host-Zielen auch fuer alle anderen (nur das lokale Magazin bleibt).
-- Beim Host gleich wieder einblenden; lokal bleibt sie weg, weil SetEnableScope vorher den ganzen
-- Koerper samt angehaengter Waffe per SetVisibility (nicht repliziert) ausblendet.
-- CORE-18: Der Hook auf SetCurrentWeaponVisibility merkt nur die Figur (Coop.WVisQ), die Arbeit macht die
-- Schnell-Aufgabe "wvis" (100 ms, danach ist die Waffe sicher schon versteckt).
Coop.WVisQ = {}
function Coop.WeaponVisFix(Pawn)
    if not IsAlive(Pawn) then return end
    local Mesh = Pawn.Mesh
    -- Nur, wenn der Koerper lokal schon ausgeblendet ist (sonst waere die Waffe lokal sichtbar)
    if not Pawn:IsLocallyControlled() or not IsAlive(Mesh) or Mesh:IsVisible() then return end
    local Attached = {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local Weapon = Entry:get()
        if IsAlive(Weapon) and Weapon:GetAttachParentSocketName():ToString() == "Weapon_r" then
            local Parts = {}
            Weapon:GetAttachedActors(Parts, true, true)
            Parts[#Parts + 1] = { get = function() return Weapon end }
            for _, Part in ipairs(Parts) do
                local Actor = Part:get()
                if IsAlive(Actor) and Actor.bHidden and Actor.bReplicates then Actor:SetActorHiddenInGame(false) end
            end
        end
    end
end
function Coop.WeaponVisFast(_, Mode)
    Coop.WVisMode = Mode
    if #Coop.WVisQ == 0 then return end
    local Q = Coop.WVisQ
    Coop.WVisQ = {}
    if Mode ~= "ListenServer" then return end
    for _, Pawn in ipairs(Q) do
        local ok, err = pcall(Coop.WeaponVisFix, Pawn)
        if not ok then Log("Zielfernrohr-Fehler: %s", tostring(err)) end
    end
end

-- Blueprint-Funktionen lassen sich erst hooken, wenn ihre Klasse geladen ist.
local function RegisterCharacterHooks()
    if CharacterHooksDone or not StaticFindObject(CHARACTER_CLASS):IsValid() then return end
    CharacterHooksDone = true
    -- Nicht jeder Tod laeuft ueber PlayerDeath (z. B. ueber PlayerDead), am Ende steht aber immer der
    -- Multicast MC_PlayerDead. Alle drei melden; OnGuestDeath verarbeitet jede Figur nur einmal.
    -- Alle vier Tod-Hooks liegen in derselben Kette (Schaden -> Tod): dort nur Figur + Eigenschaften merken
    -- (Coop.QueueDeath), Lage/Besitzer/Spielstand im Schnell-Loop (Coop.DeathFast, <= 100 ms spaeter).
    if not Coop.DeathAdded then Coop.DeathAdded = true Coop.AddFast("death", Coop.DeathFast) end
    for _, Fn in ipairs({ "PlayerDeath", "PlayerDead", "MC_PlayerDead" }) do
        -- UE 5.6: PlayerDead gibt es nicht mehr (nur noch die Delegate-Signatur) -> fehlende Ziele ueberspringen
        if IsAlive(StaticFindObject(CHARACTER_CLASS .. ":" .. Fn)) then
            TryHook(CHARACTER_CLASS .. ":" .. Fn, function(Context)
                local ok, err = pcall(Coop.QueueDeath, Context:get(), Fn)
                if not ok then Log("Tod-Fehler: %s", tostring(err)) end
            end)
        end
    end
    -- Zielfernrohr (Coop.WeaponVisFix oben). CORE-18: im Hook nur die Figur merken (keine UFunction im Rumpf), Arbeit
    -- im Schnell-Loop (Coop.WeaponVisFast). Nur der Listen-Host zielt selbst; der dedizierte Server merkt nichts.
    TryHook(CHARACTER_CLASS .. ":SetCurrentWeaponVisibility", function(Context, Hidden)
        if Coop.WVisMode ~= "ListenServer" or #Coop.WVisQ >= 8 then return end
        pcall(function() if Hidden:get() then Coop.WVisQ[#Coop.WVisQ + 1] = Context:get() end end)
    end)
    if not Coop.WVisAdded then Coop.WVisAdded = true Coop.AddFast("wvis", Coop.WeaponVisFast) end
    local Medical = FindFirstOf("MedicalComponent_C")
    if IsAlive(Medical) then
        local ClassPath = Medical:GetClass():GetFullName():match("^%S+%s+(.+)$")
        -- vit_v2: kein Lua-Hook in der Schadenskette; CORE-18: die reine Diagnose (GetOwner + Log je Schaden) nur mit dev=1
        if SETTINGS.dev and not (Coop.VitV2Flag and Coop.VitV2Flag()) then
        TryHook(ClassPath .. ":Svr_Damage", function(Context, DamagedActor, BaseDamage)
            local Comp = Context:get()
            Log("Svr_Damage: Komponente von %s, Ziel %s, Schaden %.1f",
                Safe(function() local O = IsAlive(Comp) and Comp:GetOwner() return IsAlive(O) and O:GetFName():ToString() or "?" end, "?"),
                Safe(function() local D = DamagedActor:get() return IsAlive(D) and D:GetFName():ToString() or "?" end, "?"),
                Safe(function() return BaseDamage:get() end, 0))
        end)
        end
        TryHook(ClassPath .. ":PlayerDeath", function(Context)
            local ok, err = pcall(function() Coop.QueueDeath(nil, "MedicalComponent", Context:get()) end)
            if not ok then Log("Tod-Fehler: %s", tostring(err)) end
        end)
    end
    TryHook("/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:EventBindMidnight", function()
        local ok, err = pcall(OnMidnight)
        if not ok then Log("Mitternacht-Fehler: %s", tostring(err)) end
    end)
    Log("Schadens-/Tod-Hooks registriert")
end

-- Multiplayer-Hook: Die Blueprints holen sich "Spieler 0" ueber GameplayStatics (GetPlayerController,
-- GetPlayerCameraManager, ...), z. B. in der Todeslogik, bei Kamerawackeln, Schritten, Skilltree und
-- Waffen-Traces. Auf dem Host ist Spieler 0 immer der Host, darum landen Tod und Effekte des
-- Mitspielers beim Host. Hier wird stattdessen der Spieler zurueckgegeben, dem das aufrufende Objekt
-- (Figur, Komponente, Waffe, Animation, Widget) gehoert.
local MultiplayerActive = false
local RedirectCount, RedirectLogged = 0, 0

local CLASSES = {}
for Name, Path in pairs({
    Pawn = "/Script/Engine.Pawn", Character = "/Script/Engine.Character",
    Controller = "/Script/Engine.Controller", PlayerController = "/Script/Engine.PlayerController",
    ActorComponent = "/Script/Engine.ActorComponent", Actor = "/Script/Engine.Actor",
    AnimInstance = "/Script/Engine.AnimInstance", UserWidget = "/Script/UMG.UserWidget",
    Function = "/Script/CoreUObject.Function",
}) do CLASSES[Name] = StaticFindObject(Path) end

local function PlayerControllerOf(Actor)
    -- Waffen, Projektile usw. haengen ueber Owner an der Figur: ein paar Stufen hochlaufen.
    for _ = 1, 4 do
        if not IsAlive(Actor) then return nil end
        if Actor:IsA(CLASSES.PlayerController) then return Actor end
        if Actor:IsA(CLASSES.Pawn) then
            local C = Actor:GetController()
            if IsAlive(C) and C:IsA(CLASSES.PlayerController) then return C end
            return nil
        end
        Actor = Actor:GetOwner()
    end
    return nil
end

local function ResolvePlayerController(Context)
    if not IsAlive(Context) then return nil end
    if Context:IsA(CLASSES.UserWidget) then
        local PC = Context:GetOwningPlayer()
        return IsAlive(PC) and PC or nil
    end
    if Context:IsA(CLASSES.ActorComponent) then return PlayerControllerOf(Context:GetOwner()) end
    if Context:IsA(CLASSES.AnimInstance) then return PlayerControllerOf(Context:TryGetPawnOwner()) end
    if Context:IsA(CLASSES.Actor) then return PlayerControllerOf(Context) end
    return nil
end

-- Liefert den "richtigen" PlayerController, wenn er sich vom Ergebnis fuer Spieler 0 unterscheidet.
local function Redirect(WorldContext, PlayerIndex, Original)
    if not MultiplayerActive or PlayerIndex:get() ~= 0 then return nil end
    local ok, PC = pcall(ResolvePlayerController, WorldContext:get())
    if not ok or not PC then return nil end
    local OrigValue = Original and Safe(function() return Original:get() end)
    if OrigValue and IsAlive(OrigValue) and OrigValue:GetFName():ToString() == PC:GetFName():ToString() then
        return nil
    end
    RedirectCount = RedirectCount + 1
    return PC
end

local function Override(ReturnValue, Value)
    if ReturnValue then pcall(function() ReturnValue:set(Value) end) end
    return Value
end

-- Diese Funktionen ruft das Spiel staendig auf, auch im Hauptmenue. Ein Lua-Hook darauf hat im
-- Einzelspieler nach einigen Minuten zum Absturz gefuehrt, darum nur im Multiplayer anschalten.
local GPS = "/Script/Engine.GameplayStatics:"
local REDIRECT_HOOKS = {
    GetPlayerController = function(PC) return PC end,
    GetPlayerPawn = function(PC) return PC:K2_GetPawn() end,
    GetPlayerCharacter = function(PC)
        local Pawn = PC:K2_GetPawn()
        return IsAlive(Pawn) and Pawn:IsA(CLASSES.Character) and Pawn or nil
    end,
    GetPlayerCameraManager = function(PC) return PC.PlayerCameraManager end,
}
local ActiveRedirectHooks = nil

-- Beim ersten echten Umleiten (Mitspieler tritt bei) ist das Spiel des Hosts abgestuerzt: Den
-- Rueckgabewert dieser nativen Funktionen aus Lua zu ersetzen ist nicht stabil. Darum aus, bis es
-- eine C++-Variante gibt. Zum Testen: multiplayer_hook.txt mit "an" in den Mod-Ordner legen.
local function RedirectHookWanted()
    local File = io.open(MOD_DIR .. "multiplayer_hook.txt", "r")
    if not File then return false end
    local Value = (File:read("*l") or ""):lower()
    File:close()
    return Value:find("an", 1, true) == 1 or Value:find("on", 1, true) == 1
end
local RedirectHookEnabled = RedirectHookWanted()

local function EnableRedirectHooks()
    if ActiveRedirectHooks or not RedirectHookEnabled then return end
    ActiveRedirectHooks = {}
    for Name, Pick in pairs(REDIRECT_HOOKS) do
        local CompareOriginal = Name == "GetPlayerController"
        local Hook = TryHook(GPS .. Name, function() end, function(_, WorldContext, PlayerIndex, ReturnValue)
            local PC = Redirect(WorldContext, PlayerIndex, CompareOriginal and ReturnValue or nil)
            if not PC then return end
            local Value = Pick(PC)
            if Value then return Override(ReturnValue, Value) end
        end)
        if Hook then ActiveRedirectHooks[#ActiveRedirectHooks + 1] = Hook end
    end
    Log("Multiplayer-Hook an (%d Funktionen)", #ActiveRedirectHooks)
end

local function DisableRedirectHooks()
    if not ActiveRedirectHooks then return end
    for _, Hook in ipairs(ActiveRedirectHooks) do
        pcall(UnregisterHook, Hook.Path, Hook.PreId, Hook.PostId)
    end
    ActiveRedirectHooks = nil
    Log("Multiplayer-Hook aus")
end

-- Nativer Multiplayer-Hook (LastSignalCore.dll): macht dasselbe wie oben, aber in C++ direkt im
-- Funktions-Thunk statt in Lua. Die DLL kennt keine UE-Typen; Adressen und Offsets bekommt sie
-- ueber netcore.cfg, an/aus ueber netcore_enabled.txt.
local NativeCoreLoaded, NativeCoreEnabled = false, nil

local function ModRoot()
    local Source = debug.getinfo(1, "S").source:gsub("^@", "")
    return Source:match("^(.*[\\/])Scripts[\\/][^\\/]+$")
end

local function PropertyOffset(ClassPath, Name)
    local Class, Found = StaticFindObject(ClassPath), nil
    if not Class:IsValid() then return nil end
    Class:ForEachProperty(function(Property)
        if Property:GetFName():ToString() == Name then
            Found = Property:GetOffset_Internal()
            return true
        end
    end)
    return Found
end

local function WriteNativeConfig(Path)
    local Values = {
        func_gpc = StaticFindObject(GPS .. "GetPlayerController"),
        func_gpp = StaticFindObject(GPS .. "GetPlayerPawn"),
        func_gpchar = StaticFindObject(GPS .. "GetPlayerCharacter"),
        func_gpcm = StaticFindObject(GPS .. "GetPlayerCameraManager"),
        cls_pawn = CLASSES.Pawn, cls_character = CLASSES.Character, cls_pc = CLASSES.PlayerController,
        cls_actorcomp = CLASSES.ActorComponent, cls_actor = CLASSES.Actor, cls_anim = CLASSES.AnimInstance,
        cls_function = CLASSES.Function,
    }
    local Offsets = {
        off_actor_owner = PropertyOffset("/Script/Engine.Actor", "Owner"),
        off_pawn_controller = PropertyOffset("/Script/Engine.Pawn", "Controller"),
        off_controller_pawn = PropertyOffset("/Script/Engine.Controller", "Pawn"),
        off_camera_manager = PropertyOffset("/Script/Engine.PlayerController", "PlayerCameraManager"),
        -- FFrame::PreviousFrame (UE 5.3; fuer 5.6 unveraendert angenommen - FFrame ist nicht reflektiert, im Decode nicht
        -- pruefbar); 0 schaltet das Hochlaufen der Aufrufkette ab.
        off_frame_previous = SETTINGS.frame_walk and 0x78 or 0,
    }
    local Lines = {}
    for Key, Object in pairs(Values) do
        if not (Object and Object:IsValid()) then Log("LastSignalCore: %s nicht gefunden", Key) return false end
        Lines[#Lines + 1] = string.format("%s=%X", Key, Object:GetAddress())
    end
    for Key, Offset in pairs(Offsets) do
        if not Offset then Log("LastSignalCore: Offset %s nicht gefunden", Key) return false end
        Lines[#Lines + 1] = string.format("%s=%X", Key, Offset)
    end
    -- Fuer die Killer-Zuordnung prueft die DLL Parameter gegen die globale Objektliste. Deren
    -- Adresse hat UE4SS beim Start ins eigene Log geschrieben ("Found GUObjectArray: 0x...").
    local UE4SSLog = io.open(ModRoot():match("^(.*[\\/])Mods[\\/]") .. "UE4SS.log", "r")
    if UE4SSLog then
        for Line in UE4SSLog:lines() do
            local Address = Line:match("Found GUObjectArray: 0x(%x+)")
            if Address then Lines[#Lines + 1] = "guobjectarray=" .. Address break end
        end
        UE4SSLog:close()
    end
    if not Lines[#Lines]:find("^guobjectarray=") then
        Log("LastSignalCore: GUObjectArray nicht im Log gefunden, Killer-Zuordnung aus")
    end
    local File = io.open(Path, "w")
    if not File then Log("LastSignalCore: %s nicht schreibbar", Path) return false end
    File:write(table.concat(Lines, "\n"), "\n")
    File:close()
    return true
end

-- CORE-23 (Regel 6): kleine IPC-Datei fuer die DLL atomar (ls_core WriteAtomic: tmp + rename), ohne ls_core wie bisher.
-- true = geschrieben
function Coop.WriteIpc(Path, Text)
    local Core = Coop.Modules and Coop.Modules.ls_core
    if Core and type(Core.WriteAtomic) == "function" then
        local ok, Res = pcall(Core.WriteAtomic, Path, Text)
        if ok then return Res ~= false end
    end
    local File = io.open(Path, "w")
    if not File then return false end
    File:write(Text)
    File:close()
    return true
end

local function SetNativeCoreEnabled(Enabled)
    if not NativeCoreLoaded or NativeCoreEnabled == Enabled then return end
    if not Coop.WriteIpc(ModRoot() .. "netcore_enabled.txt", Enabled and "1" or "0") then return end
    NativeCoreEnabled = Enabled
end

local function LoadNativeCore()
    local Root = ModRoot()
    local Dll = Root .. "LastSignalCore.dll"
    local Probe = io.open(Dll, "rb")
    if not Probe then Log("LastSignalCore.dll fehlt, nativer Multiplayer-Hook aus") return end
    Probe:close()
    Coop.WriteIpc(Root .. "netcore_enabled.txt", "0")   -- CORE-23
    -- Alte Patch-Anforderungen (Adressen aus einer frueheren Sitzung) nie anwenden lassen.
    os.remove(Root .. "netcore_patch.txt")
    if not WriteNativeConfig(Root .. "netcore.cfg") then return end
    if not (package and package.loadlib) then Log("package.loadlib fehlt, LastSignalCore kann nicht laden") return end
    local Loaded, Err = package.loadlib(Dll, "*")
    if not Loaded then Log("LastSignalCore laden fehlgeschlagen: %s", tostring(Err)) return end
    NativeCoreLoaded, NativeCoreEnabled = true, false
    Log("LastSignalCore geladen (Details in netcore.log)")
end

-- Prueft auf dem Host einmal, ob das Umleiten wirklich greift (ruft GetPlayerController selbst mit
-- der Figur des Mitspielers auf, das geht ebenfalls durch den Hook).
local RedirectSelfTested = false

local function SelfTestRedirect(World)
    if RedirectSelfTested or not ActiveRedirectHooks or NetModeName(World) ~= "ListenServer" then return end
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        local Pawn = IsAlive(PC) and PC:K2_GetPawn() or nil
        if Pawn and IsAlive(Pawn) and not PC:IsLocalController() then
            RedirectSelfTested = true
            local Result = UEHelpers.GetGameplayStatics():GetPlayerController(Pawn, 0)
            local Works = IsAlive(Result) and Result:GetFName():ToString() == PC:GetFName():ToString()
            Log("Multiplayer-Hook Selbsttest: %s (erwartet %s, bekommen %s)", Works and "OK" or "FEHLGESCHLAGEN",
                PC:GetFName():ToString(), IsAlive(Result) and Result:GetFName():ToString() or "nil")
            return
        end
    end
end

-- Client: Das Hauptmenue bleibt nach dem Beitritt offen und liegt ueber der Welt des Hosts.
-- Nach dem Verbinden alle Widgets mit "Menu" im Namen schliessen und auf Spielsteuerung umschalten.
local ClientConnectedSince, MenuClosed = nil, false

-- Bildschirme ohne "Menu" im Namen, die beim Mitspieler haengen bleiben: Hauptmenue-Start,
-- Ladebildschirm und Respawn-Bildschirm (bleibt nach dem Respawn sonst offen).
local LEFTOVER_SCREENS = {
    PressAnyKeyWidget_C = true, LoadingScreenWidget_C = true,
    RespawnScreen_C = true, ScreenPermadeath_C = true,
}

local function CloseMenus()
    local PC = LocalPC()
    local Visible, Closed = {}, {}
    -- join_v2: Der Ladebildschirm bleibt, bis die Figur am Ziel bereit ist (Coop.JoinC). Hier statt bei den
    -- Aufrufern, damit es fuer alle gilt (Beitritt, neue Figur, InputWatch, F6, Testbefehl menu).
    local KeepLoading, Kept = Coop.JoinLoading ~= nil and Coop.JoinLoading(), false
    for _, Widget in ipairs(FindAllOf("UserWidget") or {}) do
        if IsAlive(Widget) and Widget:IsInViewport() then
            local Name = Widget:GetClass():GetFName():ToString()
            Visible[#Visible + 1] = Name
            if KeepLoading and Name == "LoadingScreenWidget_C" then
                Kept = true
            elseif (Name:lower():find("menu", 1, true) or LEFTOVER_SCREENS[Name])
                and not (Coop.Player and Coop.Player.KeepScreen(Name)) then   -- ls_player: Todesbildschirm bleibt
                Widget:RemoveFromParent()
                Closed[#Closed + 1] = Name
            end
        end
    end
    Log("Sichtbare Widgets: %s", #Visible > 0 and table.concat(Visible, ", ") or "keine")
    Log("Geschlossen: %s%s", #Closed > 0 and table.concat(Closed, ", ") or "nichts",
        Kept and " (Ladebildschirm bleibt bis zum Beitritts-ready)" or "")
    if IsAlive(PC) and not (Coop.Player and Coop.Player.DeathScreenUp()) then   -- ls_player: Maus im Todesbildschirm
        local WBL = Coop.Cdo("/Script/UMG.Default__WidgetBlueprintLibrary")   -- CORE-20
        if WBL then WBL:SetInputMode_GameOnly(PC, false) end
        PC.bShowMouseCursor = false
        PC:ResetIgnoreInputFlags()
    end
end

-- SurrounDead nutzt Enhanced Input mit einer einzigen Tastenbelegung (IMC_General). Die aktiviert
-- das Spiel nur beim Laden eines Spielstands, beim Mitspieler also nie: keine Bewegung, kein Umsehen.
local MAPPING_CONTEXT = "IMC_General"

local function FindMappingContext()
    for _, IMC in ipairs(FindAllOf("InputMappingContext") or {}) do
        if IsAlive(IMC) and IMC:GetFName():ToString() == MAPPING_CONTEXT then return IMC end
    end
    return nil
end

local function InputSubsystem()
    for _, Subsystem in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
        if IsAlive(Subsystem) then return Subsystem end
    end
    return nil
end

local function EnableGameInput()
    local IMC, Subsystem = FindMappingContext(), InputSubsystem()
    if not IMC then Log("%s nicht gefunden", MAPPING_CONTEXT) return end
    if not Subsystem then Log("EnhancedInputLocalPlayerSubsystem nicht gefunden") return end
    if Subsystem:HasMappingContext(IMC, {}) then
        Log("%s ist bereits aktiv", MAPPING_CONTEXT)
        return
    end
    Subsystem:AddMappingContext(IMC, 0, { bIgnoreAllPressedKeysUntilRelease = true, bForceImmediately = true })
    Log("%s aktiviert: %s", MAPPING_CONTEXT, tostring(Subsystem:HasMappingContext(IMC, {})))
end

local function SetupClient()
    local ok, err = pcall(CloseMenus)
    if not ok then Log("Menue schliessen fehlgeschlagen: %s", tostring(err)) end
    ok, err = pcall(EnableGameInput)
    if not ok then Log("Steuerung aktivieren fehlgeschlagen: %s", tostring(err)) end
end

-- Maus/Tastatur nach dem Beitritt gefangen (nichts geht, auch ESC nicht; frueher half F6): Die Tastenbelegung
-- IMC_General ist nicht aktiv oder ein Lade-/Titelbild liegt noch im Bild. Als Mitspieler jede Sekunde pruefen
-- und dann wie F6 neu einrichten (hoechstens alle 3 s). Das Pausenmenue bleibt dabei unberuehrt (nur im Fehlerfall).
Coop.InputWatch = function()
    if Coop.Player and Coop.Player.DeathScreenUp() then return end   -- ls_player: Todesbildschirm, Eingabe gehoert ihm
    local IMC, Subsystem = FindMappingContext(), InputSubsystem()
    local Missing = IMC ~= nil and Subsystem ~= nil and not Subsystem:HasMappingContext(IMC, {})
    local Stuck
    -- join_v2: Ladebildschirm waehrend des Beitritts ist gewollt (schliesst Coop.Join beim ready), kein Haenger
    local Loading = Coop.JoinLoading ~= nil and Coop.JoinLoading()
    for _, Name in ipairs({ "LoadingScreenWidget_C", "PressAnyKeyWidget_C" }) do
        for _, W in ipairs((Loading and Name == "LoadingScreenWidget_C") and {} or FindAllOf(Name) or {}) do
            if IsAlive(W) and Safe(function() return W:IsInViewport() end, false) then Stuck = Name end
        end
    end
    if not (Missing or Stuck) or os.time() < (Coop.InputFixAt or 0) then return end
    Coop.InputFixAt = os.time() + 3
    Log("Steuerung gefangen (%s): richte neu ein", Missing and "IMC_General fehlte" or Stuck)
    SetupClient()
end

-- Spieler-Einrichtung: Beim Uebernehmen einer Figur (ReceivePossessed) richtet das Spiel Hotbar,
-- Slots, Kamera, Komponenten und Laufgeschwindigkeit ein - aber nur auf dem Host und nur fuer die
-- lokal gesteuerte Figur. Beim Mitspieler laeuft das nie: kein HUD, keine Hotbar. Darum hier auf
-- seinem PC nachholen, und das HUD (BP_Ingame) selbst anlegen, falls es danach noch fehlt.
local SETUP_DELAY, HUD_DELAY = 2, 5
local INGAME_UI_CLASS = "/Game/Inventory/BP_Ingame.BP_Ingame_C"
local LastClientPawn, ClientPawnSince, PossessReplayed, HudChecked = nil, nil, false, false

local function ReplayPossessed(Pawn)
    if not SETTINGS.replay_possessed then return end
    local ok, err = pcall(function() Pawn:ReceivePossessed(LocalPC()) end)
    Log("Spieler-Einrichtung (ReceivePossessed): %s", ok and "ausgefuehrt" or tostring(err))
end

local function EnsureHud(Pawn)
    local Existing = Safe(function() return Pawn.InGameUI end)
    if Existing and IsAlive(Existing) then
        if not Existing:IsInViewport() then Existing:AddToViewport(0) end
        Log("HUD vorhanden (%s)", Existing:GetFName():ToString())
        return
    end
    local Class = StaticFindObject(INGAME_UI_CLASS)
    if not IsAlive(Class) then Log("HUD-Klasse nicht geladen") return end
    local PC = LocalPC()
    local WBL = Coop.Cdo("/Script/UMG.Default__WidgetBlueprintLibrary")   -- CORE-20
    if not (WBL and IsAlive(PC)) then Log("HUD erstellen fehlgeschlagen (kein Controller/WBL)") return end
    local Widget = WBL:Create(PC, Class, PC)
    if not IsAlive(Widget) then Log("HUD erstellen fehlgeschlagen") return end
    Pawn.InGameUI = Widget
    Widget:AddToViewport(0)
    Log("HUD erstellt: %s", Widget:GetFName():ToString())
end

-- Speichern beim Mitspieler aus: Er hat keinen eigenen Spielstand der Host-Welt, Speichern wuerde
-- nur seine lokale Kopie in seinen eigenen Spielstand schreiben. Das Level-Script setzt
-- AllowSaving? wieder auf true, darum jede Sekunde; Schnellspeichern (F5) einmal abklemmen.
local QuickSaveUnmapped = false

local function DisableClientSaving()
    pcall(function()
        local GI = UEHelpers.GetGameInstance()
        if IsAlive(GI) and GI["AllowSaving?"] then GI["AllowSaving?"] = false end
    end)
    if QuickSaveUnmapped then return end
    local IMC = FindMappingContext()
    local Action = StaticFindObject("/Game/Input/Other/IA_QuickSave.IA_QuickSave")
    if IMC and IsAlive(Action) then
        local ok = pcall(function() IMC:UnmapAllKeysFromAction(Action) end)
        QuickSaveUnmapped = ok
        Log("Schnellspeichern (F5) beim Mitspieler %s", ok and "abgeschaltet" or "nicht abschaltbar")
    end
end

-- Geister beim Mitspieler: Auf seinem PC laufen Level-Script, Spielstand-Laden und Spawner so, als
-- spiele er allein. Dabei entstehen lokale Kopien replizierter Objekte (Spielerfigur aus dem
-- Spielstand, Kisten, Fahrzeuge, Haendler, Zombie-Spawner ...). Echte Objekte vom Host haben beim
-- Client Role=SimulatedProxy; Role=Authority bei einer replizierten Klasse heisst "nur hier
-- gespawnt". Solche Geister kollidieren nur bei ihm (Rubber-Banding), funktionieren nicht und
-- koennen Geister-Zombies erzeugen -> entfernen. Neue Actors werden beim Erzeugen vorgemerkt und
-- eine Sekunde spaeter geprueft (erst dann steht ihre Rolle fest).
local ROLE_AUTHORITY = 3
local GhostWatch, GhostScanDone, PendingActors = false, false, {}
local GhostRemoved = {}

-- Wichtig: Direkt nach dem Beitritt streamt der Client noch die Karte, deren Objekte (Spawner,
-- Kisten, Fahrzeuge ...) sind dann noch nicht auf "gehoert dem Host" umgestellt und haben ebenfalls
-- Role=Authority. Die duerfen nie geloescht werden (das hat den Client abstuerzen lassen). Echte
-- Geister entstehen erst zur Laufzeit; aus der Karte geladene Objekte tragen RF_WasLoaded.
local WAS_LOADED = EObjectFlags and EObjectFlags.RF_WasLoaded
local GHOST_BATCH_LIMIT = 300

local function IsClientGhost(Actor)
    if not WAS_LOADED or not IsAlive(Actor) then return false end
    if Actor.Role ~= ROLE_AUTHORITY or Actor.bReplicates ~= true then return false end
    return not Actor:HasAnyFlags(WAS_LOADED)
end

local function RemoveGhost(Actor)
    if not IsAlive(Actor) then return end
    local Name = Actor:GetClass():GetFName():ToString()
    Actor:K2_DestroyActor()
    GhostRemoved[Name] = (GhostRemoved[Name] or 0) + 1
end

local function LogGhostSummary(Prefix)
    local Parts, Total = {}, 0
    for Name, Count in pairs(GhostRemoved) do
        Parts[#Parts + 1] = Name .. "=" .. Count
        Total = Total + Count
    end
    if Total == 0 then return end
    table.sort(Parts)
    Log("%s: %d lokale Geister entfernt (%s)", Prefix, Total, table.concat(Parts, ", "))
    GhostRemoved = {}
end

-- Notbremse: Ein normaler Geister-Durchgang sind ein paar Dutzend bis ~150 Objekte. Will ein
-- Durchgang deutlich mehr loeschen, stimmt etwas nicht - dann lieber gar nichts anfassen.
local function RemoveGhosts(Candidates, Prefix)
    if #Candidates == 0 then return end
    if #Candidates > GHOST_BATCH_LIMIT then
        Log("%s: %d Geister-Kandidaten - zu viele, nichts entfernt (Notbremse)", Prefix, #Candidates)
        return
    end
    for _, Actor in ipairs(Candidates) do pcall(RemoveGhost, Actor) end
    LogGhostSummary(Prefix)
end

-- Neue Geister: kein NotifyOnNewObject mehr (lief auch beim asynchronen Laden in einem anderen Thread, Lua in
-- UE4SS ist nicht threadsicher; gemerkte Objekte waren eine Sekunde spaeter oft schon zerstoert). Stattdessen
-- jede Sekunde alle Figuren und jede Minute alle Actors pruefen - im Spiel-Thread, zwischen zwei Bildern.
local function CleanupClientGhosts()
    if not WAS_LOADED then return end  -- ohne sicheres Unterscheidungsmerkmal lieber nichts loeschen
    GhostWatch = true
    if not GhostScanDone then
        GhostScanDone = true
        local Candidates = {}
        for _, Actor in ipairs(FindAllOf("Actor") or {}) do
            if Safe(function() return IsClientGhost(Actor) end, false) then Candidates[#Candidates + 1] = Actor end
        end
        RemoveGhosts(Candidates, "Beim Beitritt")
    end
    local Full, Candidates = os.time() >= (Coop.GhostFullAt or 0), {}
    if Full then Coop.GhostFullAt = os.time() + 60 end
    -- ls_ai GhostStep (ai_v2 + ai_ghosts) entfernt dieselben Laufzeit-Geister in kleinen Schritten: dann kein
    -- minuetlicher Vollscan aller Actors (~6 UE4SS-Aufrufe je Actor in einem Bild = regelmaessiges Stocken)
    if Full then
        local Core = Coop.Modules and Coop.Modules.ls_core
        if Coop.Modules and Coop.Modules.ls_ai and Core and Core.Flag
            and Safe(function() return Core.Flag("ai_v2", true) and Core.Flag("ai_ghosts", true) end, false) then
            Full = false
            if not Coop.GhostFullSkipLogged then
                Coop.GhostFullSkipLogged = true
                Log("Geister-Vollscan uebersprungen (ls_ai GhostStep aktiv)")
            end
        end
    end
    for _, Actor in ipairs(Full and (FindAllOf("Actor") or {}) or Coop.Characters()) do
        if Safe(function() return IsClientGhost(Actor) end, false) then Candidates[#Candidates + 1] = Actor end
    end
    RemoveGhosts(Candidates, "Nachgespawnt")
end

do
-- spawner_stop (nur Mitspieler und verbunden, nie solo oder beim Host): Spawner beim Mitspieler aus, damit lokale
-- Geister-Zombies gar nicht erst entstehen. Was trotzdem entsteht, entfernt weiter CleanupClientGhosts (1 s / 60 s).
--   1 = Invoker-Variante: AIOInvoker jeder Spielerfigur (eigene und fremde) beim AI-Optimizer abmelden (wie server.lua
--       RemoveInvoker, ohne Geist-Anker); Spawner und KI richten sich nur nach Invokern. Neue Figuren jede Sekunde.
--   2 = Spawner-Variante: Spawner und Spawn-Volumes aus der Karte (Role=Authority und RF_WasLoaded, also nicht vom
--       Host) stoppen, ab START s nach dem Beitritt alle FAST s, nach FAST_FOR s alle SLOW s. Jeder Durchlauf prueft neu
--       (Streaming legt Objekte mit demselben Namen neu an): Schluessel Adresse:FName, Zustand jedes Mal neu lesen.
--       Quest-Spawner (UE 5.6 BP_Quest_Spawner_AI_C, 5.3 BP_AISpawningVolume_HumanQuest_C), AIManager und
--       EventManager bleiben unberuehrt; kein KillSpawnedActors. (5.6: "Stop Spawning"/"Enable Spawn AI" der Volumes und
--       SetIsSpawningStopped/IsSpawningStopped des Masters unveraendert, kdis FUNC "Stop Spawning" SCRIPT 18.)
-- Aufruf aus HandleClient (1 Hz, nach der Verbindungspruefung), Zeitbasis os.clock.
local S = { START = 2, FAST = 2, FAST_FOR = 30, SLOW = 15, LOG_EVERY = 60, RETRY = 3, NextAt = 0, Invoker = {}, Done = {},
            -- Unterklassen zuerst: FindAllOf der Basisklasse kann sie nochmal liefern (Dedupe pro Durchlauf)
            SPAWNERS = { "BP_AISpawner_Zombies_C", "BP_AISpawner_Animals_C", "BP_AISpawner_ZombieHounds_C",
                         "BP_AISpawner_Master_C" },
            VOLUMES = { "BP_AISpawningVolume_RandomChanceToSpawn_C", "BP_AISpawningVolume_Prefab_C" } }
Coop.SpawnerStop = S

-- AIOInvoker einer Figur beim AI-Optimizer abmelden (wie server.lua RemoveInvoker, ohne Geist-Anker und ohne
-- Merk-Zustand). Rueckgabe: Text fuers Log
function Coop.UnregisterInvoker(Pawn)
    local Component = Safe(function() return Pawn.AIOInvoker end)
    if not IsAlive(Component) then return "keine Komponente" end
    local Subsystem = FindFirstOf("AIOptimizerSubsystem")
    if not IsAlive(Subsystem) then return "kein AIOptimizerSubsystem" end
    local Before = Safe(function() return #Subsystem.Invokers end, -1)
    pcall(function() Subsystem:UnregisterInvoker(Component) end)
    pcall(function() Component:Deactivate() end)
    return string.format("%d -> %d Invoker", Before, Safe(function() return #Subsystem.Invokers end, -1))
end

local function KeyOf(Obj)
    return string.format("%X:%s", Obj:GetAddress(), Obj:GetFName():ToString())
end

-- Variante 1: jede Spielerfigur einmal; meldet das Spiel den Invoker wieder an (Komponente wieder aktiv), bis zu
-- RETRY Versuche. Figuren, die weg sind, fallen aus der Liste.
function S.InvokerTick()
    local Seen = {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Safe(function() return Char:GetClass():GetFName():ToString() == "BP_PlayerCharacter_C" end, false) then
            local Key = KeyOf(Char)
            local Tries = S.Invoker[Key] or 0
            local Again = Tries > 0 and Tries < S.RETRY and Safe(function() local Inv = Char.AIOInvoker return IsAlive(Inv) and Inv:IsActive() end, false) == true
            if Tries == 0 or Again then
                Tries = Tries + 1
                local ok, Result = pcall(Coop.UnregisterInvoker, Char)
                Log("Spawner-Stopp (Invoker): %s %s%s", Char:GetFName():ToString(),
                    ok and Result or ("Fehler " .. tostring(Result)), Again and " (erneut, war wieder aktiv)" or "")
            end
            Seen[Key] = Tries
        end
    end
    S.Invoker = Seen
end

-- Spawner gestoppt? Eigenschaft oder Funktion (wie probe_spawners); nil = nicht lesbar
function S.IsStopped(Obj)
    local Stopped = Safe(function() return Obj.IsSpawningStopped end)
    if type(Stopped) == "userdata" then Stopped = Safe(function() return Obj:IsSpawningStopped() end) end
    if type(Stopped) == "boolean" then return Stopped end
    return nil
end

-- Volume spawnt? (Eigenschaft "Enable Spawn AI"); nil = nicht lesbar
function S.VolumeOn(Obj)
    local On = Safe(function() return Obj["Enable Spawn AI"] end)
    if type(On) == "boolean" then return On end
    return nil
end

-- Ein Objekt: zaehlt in C (Found, New, Off, Host, Runtime, Err); Done = Schluessel, die jetzt gestoppt sind
function S.Handle(Obj, Volume, C, Seen, Done)
    if not IsAlive(Obj) then return end
    local Key = KeyOf(Obj)
    if Seen[Key] then return end   -- schon unter einer Unterklasse gezaehlt
    Seen[Key] = true
    C.Found = C.Found + 1
    if Obj.Role ~= ROLE_AUTHORITY then C.Host = C.Host + 1 return end
    if not Obj:HasAnyFlags(WAS_LOADED) then C.Runtime = C.Runtime + 1 return end   -- Laufzeit: CleanupClientGhosts
    local ok, err
    if Volume then
        local On = S.VolumeOn(Obj)
        if S.Done[Key] and On ~= true then Done[Key] = true C.Off = C.Off + 1 return end
        local okStop, errStop = pcall(function() Obj["Stop Spawning"](Obj) end)
        local okOff = On ~= nil and pcall(function() Obj["Enable Spawn AI"] = false end) and S.VolumeOn(Obj) == false
        ok, err = okStop or okOff, errStop
    else
        local Stopped = S.IsStopped(Obj)
        if Stopped == true or (S.Done[Key] and Stopped == nil) then Done[Key] = true C.Off = C.Off + 1 return end
        ok, err = pcall(function() Obj:SetIsSpawningStopped(true) end)
        if ok and S.IsStopped(Obj) == false then ok, err = false, "IsSpawningStopped bleibt false" end
    end
    if ok then
        Done[Key] = true
        C.New = C.New + 1
    else
        C.Err = C.Err + 1
        if not S.ErrText then S.ErrText = true Log("Spawner-Stopp: %s nicht gestoppt: %s", Key, tostring(err)) end
    end
end

-- Variante 2: ein Durchlauf ueber alle Klassen; Log nur bei neu gestoppten oder alle LOG_EVERY s
function S.Pass(Now)
    if not WAS_LOADED then
        if not S.NoFlag then S.NoFlag = true Log("Spawner-Stopp: RF_WasLoaded fehlt, Spawner-Variante bleibt aus") end
        return
    end
    local Seen, Done, Parts, New, Found, Host = {}, {}, {}, 0, 0, 0
    local function Run(List, Volume)
        for _, Class in ipairs(List) do
            local C = { Found = 0, New = 0, Off = 0, Host = 0, Runtime = 0, Err = 0 }
            for _, Obj in ipairs(FindAllOf(Class) or {}) do
                local ok, err = pcall(S.Handle, Obj, Volume, C, Seen, Done)
                if not ok then
                    C.Err = C.Err + 1
                    if not S.ErrText then S.ErrText = true Log("Spawner-Stopp-Fehler (%s): %s", Class, tostring(err)) end
                end
            end
            New, Found, Host = New + C.New, Found + C.Found, Host + C.Host
            if C.Found + C.Err > 0 then
                Parts[#Parts + 1] = string.format("%s %d (neu %d, aus %d, Host %d, Laufzeit %d, Fehler %d)", Class,
                    C.Found, C.New, C.Off, C.Host, C.Runtime, C.Err)
            end
        end
    end
    Run(S.SPAWNERS, false)
    Run(S.VOLUMES, true)
    S.Done = Done   -- nur, was es noch gibt (Streaming: neu angelegte Objekte werden neu geprueft)
    if New > 0 or Now >= (S.LogAt or 0) then
        S.LogAt = Now + S.LOG_EVERY
        Log("Spawner-Stopp: %s", #Parts > 0 and table.concat(Parts, "; ") or "keine Spawner gefunden")
    end
    -- AI-8 (spawner_idle_end): in 5.6 sind alle Spawner Host-repliziert (Role ~= Authority, spawnen beim Gast nichts).
    -- 2 Durchlaeufe ohne neu gestoppte und nur Host-Objekte -> fuer diese Sitzung keine Durchlaeufe mehr (6 FindAllOf)
    if Coop.FlagOn("spawner_idle_end", true) then
        S.IdleN = (New == 0 and Found > 0 and Found == Host) and (S.IdleN or 0) + 1 or 0
        if S.IdleN >= 2 then
            S.Ended = true
            Log("Spawner-Stopp: alle %d Spawner kommen vom Host - Durchlaeufe fuer diese Sitzung beendet", Found)
        end
    end
end

function S.SpawnerTick(Now)
    if S.Ended then return end   -- AI-8: Sitzung fertig (S.Reset beim Trennen)
    S.T0 = S.T0 or Now
    if Now - S.T0 < S.START or Now < S.NextAt then return end
    S.NextAt = Now + (Now - S.T0 < S.START + S.FAST_FOR and S.FAST or S.SLOW)
    S.Pass(Now)
end

-- Aus HandleClient (nur als verbundener Mitspieler, nur mit spawner_stop ~= 0)
function S.ClientTick()
    if SETTINGS.spawner_stop == 1 then S.InvokerTick()
    elseif SETTINGS.spawner_stop == 2 then S.SpawnerTick(os.clock()) end
end

-- Getrennt: naechster Beitritt beginnt neu (auch der erste Fehlertext wird wieder einmal geloggt)
function S.Reset()
    S.Ended, S.IdleN = nil, nil   -- AI-8: neue Sitzung wieder pruefen
    if not S.T0 and next(S.Invoker) == nil and next(S.Done) == nil then return end
    S.T0, S.NextAt, S.LogAt, S.Invoker, S.Done, S.ErrText = nil, 0, nil, {}, {}, nil
end
end

-- Hotbar beim Mitspieler: Das Spiel traegt die ausgeruesteten Waffen (Felder 1-4, G, Angel) nur
-- einmal in BeginPlay der Figur in die Hotbar ein. Beim Mitspieler laeuft BeginPlay, bevor es das
-- HUD gibt, und die Hotbar bleibt leer, bis man die Waffe einmal ab- und wieder anlegt. Darum hier
-- derselbe Schritt wie in BeginPlay: jedes belegte Ausruestungsfeld des Inventars, das in der
-- Hotbar fehlt, nachtragen.
local function RefillHotbar(Pawn)
    local UI = Pawn.InGameUI
    if not IsAlive(UI) then return end
    local Index, Added = 0, 0
    Pawn.MainJSIContainers:ForEach(function(_, Entry)
        local Slot = Index
        Index = Index + 1
        local Container = Entry:get()
        if not IsAlive(Container) then return end
        local HbFound, HbContainer = {}, {}
        UI:GetHotbarByIndex(Slot, {}, HbFound, HbContainer, {})
        if HbFound["Found?"] or not IsAlive(HbContainer.ContainerRef) then return end
        local Found, Ref, Pending = {}, {}, {}
        Container:GetEquippedItemRef(Found, Ref, Pending)
        if not Found["Found?"] or Pending.IsPending or not IsAlive(Ref.ItemRef) then return end
        local Item, Asset = Ref.ItemRef, {}
        -- UID zuerst lesen (GetUniqueID(FGuid& UniqueServerID): UE4SS legt Ausgaben unter dem Parameternamen ab, wie
        -- Found["Found?"] oben; aeltere Lesart Uid.A..D als Rueckfall). Ohne gueltige UID kein Hotbar-Eintrag: ein Feld
        -- ohne UID passt zu keinem Inventar-Gegenstand (falsches/kein Anlegen ueber die Hotbar).
        local Guid = nil
        pcall(function()
            local Uid = {}
            Item:GetUniqueID(Uid)
            local Src = Uid.UniqueServerID
            if Src == nil or type(Src) == "number" or type(Src) == "boolean" then Src = Uid end
            local A, B, C, D = tonumber(Src.A), tonumber(Src.B), tonumber(Src.C), tonumber(Src.D)
            if A and B and C and D and (A ~= 0 or B ~= 0 or C ~= 0 or D ~= 0) then Guid = { A = A, B = B, C = C, D = D } end
        end)
        if not Guid then
            if not Coop.HotbarUidWarned then
                Coop.HotbarUidWarned = true
                Log("Hotbar: UID von %s nicht lesbar - Feld %d nicht nachgetragen", Safe(function() return Item:GetFName():ToString() end, "?"), Slot)
            end
            return
        end
        Item:GetJigDA(Asset)
        local Equipped, SlotRef = {}, {}
        HbContainer.ContainerRef:EquipItem(Asset.JigDataAsset, -1, nil, true, Equipped, SlotRef)
        local HotbarItem = SlotRef.SlotItemRef
        if not Equipped.Equipped or not IsAlive(HotbarItem) then return end
        pcall(function() HotbarItem:HideCapacity() end)
        pcall(function() HotbarItem:AdaptImageToActionbar(Item.RenderTargetSnap) end)
        local okUid = pcall(function() HotbarItem:SetUniqueID(Guid, {}) end)
        if not okUid then Log("Hotbar: UID fuer Feld %d nicht gesetzt", Slot) end
        Added = Added + 1
    end)
    if Added > 0 then Log("Hotbar: %d Waffen-Felder nachgetragen", Added) end
end

-- Haltbarkeit beim Mitspieler: Vor jedem Nahkampfschlag (und bei der Ladehemmung von
-- Schusswaffen) fragt das Spiel BP_JigMultiplayer.GetDurability. Die Liste, in der diese Funktion
-- sucht (MainJigContainers), fuellt nur der Host. Beim Mitspieler findet sie nichts und meldet 0:
-- "Item durability too low", Angriff abgebrochen. Beim Mitspieler gibt sie darum 100 zurueck, wenn
-- sie nichts findet (Bytecode-Patch in LastSignalCore, der vorher die erwarteten Bytes prueft).
-- Echte Haltbarkeit und Abnutzung bleiben beim Host.
-- UE 5.6: Klasse heisst BP_JigComponent_C (Eigenschaft der Figur weiter BP_JigMultiplayer). GetDurability ist
-- unveraendert (SCRIPT 921, kdis @02a2 DoubleConst 0 + @02ab Jump ->0x0396 = dieselben Bytes wie 5.3), Offset 674 gilt.
-- Erster gefundener Pfad zaehlt (5.6, Rueckfall 5.3).
local GET_DURABILITY = { "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:GetDurability",
                         "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:GetDurability" }
local DURABILITY_PATCH = { Offset = 674, Expect = "3700000000000000000696030000", New = "3700000000000059400696030000" }
local PatchLine = nil

-- Runde 5: Patch-Registry fuer Gast-Bytecode-Patches der Module (ls_ui ueber Coop.SetPatch, ls_world direkt in
-- Coop.ClientPatches). [Name] = Zeile ohne "\n"; Abschalten = gleiche Zeile mit 0 am Ende (die DLL nimmt einen Patch
-- nur mit der 0-Zeile zurueck, eine fehlende Zeile aendert nichts). Die DLL liest immer die ganze Datei ("Lua schreibt
-- immer alles"), darum schreibt UpdateClientPatches alle Zeilen zusammen und atomar (jede Sekunde aus der Hauptschleife).
Coop.ClientPatches = Coop.ClientPatches or {}
function Coop.SetPatch(Name, Line) Coop.ClientPatches[Name] = Line end

local function UpdateClientPatches(IsClient)
    if not NativeCoreLoaded then return end
    local Lines, Names = {}, {}
    local Fn = nil
    for _, Path in ipairs(GET_DURABILITY) do
        local F = StaticFindObject(Path)
        if not Fn and F ~= nil and F:IsValid() then Fn = F end
    end
    local Durability = Fn ~= nil and (IsClient or PatchLine ~= nil)
    if Durability then
        Lines[1] = string.format("durability %x %d %s %s %d", Fn:GetAddress(), DURABILITY_PATCH.Offset,
            DURABILITY_PATCH.Expect, DURABILITY_PATCH.New, IsClient and 1 or 0)
    end
    for Name, Line in pairs(Coop.ClientPatches) do if type(Line) == "string" then Names[#Names + 1] = Name end end
    table.sort(Names)
    for _, Name in ipairs(Names) do Lines[#Lines + 1] = Coop.ClientPatches[Name] end
    Coop.PatchesDirty = nil
    if #Lines == 0 then return end
    local Text = table.concat(Lines, "\n") .. "\n"
    if Text == PatchLine then return end
    local Path = ModRoot() .. "netcore_patch.txt"
    local Core = Coop.Modules and Coop.Modules.ls_core
    if Core and Core.WriteAtomic then
        if not Core.WriteAtomic(Path, Text) then return end
    else
        local File = io.open(Path, "w")
        if not File then return end
        File:write(Text)
        File:close()
    end
    PatchLine = Text
    Log("Gast-Patches angefordert: %d Zeile(n), Haltbarkeit %s (Ergebnis in netcore.log)", #Lines,
        Durability and (IsClient and "an" or "aus") or "-")
end

do
local PlayerPawns, PlayerSave, SendChunked = Coop.PlayerPawns, Coop.PlayerSave, Coop.SendChunked
local HostDataHandlers = Coop.HostDataHandlers

-- "Weapon muzzle blocked" beim Mitspieler: Beim Anlegen schaltet der Host die Kollision der
-- Waffe in der Hand ab (wird nicht repliziert). Beim Mitspieler behielt die Kopie ihre Kollision,
-- der Wand-Check an der Muendung (WeaponWallTrace) traf die eigene Waffe und sperrte das Schiessen.
-- Darum beim Mitspieler die Kollision aller ausgeruesteten Gegenstaende abschalten und wieder
-- herstellen, sobald sie nicht mehr ausgeruestet sind (z. B. auf den Boden gelegt).
local PrimitiveClass = nil
local CollisionOff = {}   -- [Komponenten-Adresse] = { Comp, Old }

local function SyncEquipmentCollision()
    PrimitiveClass = PrimitiveClass or StaticFindObject("/Script/Engine.PrimitiveComponent")
    local Equipped = {}
    local Core = Coop.Modules and Coop.Modules.ls_core
    local Att = not (Core and Core.Flag) or Core.Flag("equip_col_attach", true) == true
    -- equip_col_attach: auch bereits gemerkte Komponenten jedes Mal pruefen (das Spiel schaltet Kollision z. B. beim
    -- Aufsatz-Update wieder ein); der Altwert bleibt der zuerst gemerkte.
    local function Off(Item)
        for _, Comp in ipairs(Coop.ArrList(Item:K2_GetComponentsByClass(PrimitiveClass))) do
            local Key = IsAlive(Comp) and Comp:GetAddress()
            if Key then Equipped[Key] = true end
            if Key and (Att or not CollisionOff[Key]) then
                local Old = Comp:GetCollisionEnabled()
                if Old ~= 0 then
                    Comp:SetCollisionEnabled(0)
                    CollisionOff[Key] = CollisionOff[Key] or { Comp = Comp, Old = Old }
                end
            end
        end
    end
    -- equip_col_attach: Aufsaetze (Daempfer, Visier, Magazin) sind eigene Actors an der Waffe (InstalledAttachments),
    -- nicht in RepActorsData. Beim Zielen prueft BP_PlayerCharacter_C:WeaponWallTrace ShootingPoint -> vor die Muendung
    -- und ignoriert nur die Figur: ein Aufsatz mit Kollision trifft den Strahl -> "Weapon Muzzle Blocked", kein Zielen.
    -- Dazu die Waffe in der Hand (CurrentFiringWeapon), falls sie in RepActorsData fehlt. 0 = nur RepActorsData.
    local function WithAtt(Item)
        Off(Item)
        if not Att then return end
        local okJ, J = pcall(function() return Item.BP_JigPickupComponent end)
        if okJ and IsAlive(J) then pcall(function() J.InstalledAttachments:ForEach(function(_, E)
            local At = E:get()
            if IsAlive(At) then Off(At) end
        end) end) end
    end
    for _, Pawn in ipairs(PlayerPawns()) do
        local Jig = Pawn.BP_JigHelperComp
        if IsAlive(Jig) then Jig.RepActorsData:ForEach(function(_, Entry)
            local Item = Entry:get()[REP_ACTOR_FIELD]
            if not IsAlive(Item) then return end
            WithAtt(Item)
        end) end
        if Att then
            local okW, W = pcall(function() return Pawn.CurrentFiringWeapon end)
            if okW and IsAlive(W) then pcall(WithAtt, W) end
        end
    end
    for Key, Entry in pairs(CollisionOff) do
        if not Equipped[Key] then
            if IsAlive(Entry.Comp) then pcall(function() Entry.Comp:SetCollisionEnabled(Entry.Old) end) end
            CollisionOff[Key] = nil
        end
    end
end

-- Eigenen Charakter mitbringen: Das Inventar-Plugin hat dafuer einen Server-RPC
-- (SERVER_LoadSaveDataFromClientSide), den das Spiel selbst nie benutzt. Er nimmt genau die vier
-- Listen aus Save_Player (Container, Container-IDs, Gewichte, Hotbar), ersetzt beim Host die
-- Startausruestung und ruestet alles aus. Einmal pro Verbindung, nicht nach einem Respawn.
local InventoryUploaded = false

-- Liefert true, wenn jetzt hochgeladen wurde (dann schickt der Host die Daten von selbst zurueck).
local function UploadOwnInventory(Pawn)
    if InventoryUploaded then return false end
    local Save = PlayerSave()
    if not IsAlive(Save) then return false end
    InventoryUploaded = true
    if #Save.MainJigContainers == 0 then
        Log("Kein eigenes Inventar im Spielstand - Startausruestung bleibt")
        return false
    end
    local Inv = IsAlive(Pawn) and Pawn.BP_JigMultiplayer
    if not IsAlive(Inv) then InventoryUploaded = false return false end
    Inv:SERVER_LoadSaveDataFromClientSide(Save.MainJigContainers, Save.MainUIDs,
        Save.Weights, Save.ActionbarUIDs)
    Log("Eigenes Inventar an den Host geschickt (%d Container)", #Save.MainJigContainers)
    return true
end

-- Zurueckschreiben: Der Host packt das aktuelle Inventar des Mitspielers alle SAVE_BACK_EVERY
-- Sekunden in einen Save_Player, speichert ihn mit dem Standard-Speicher von Unreal als Datei und
-- schickt die Bytes. Der Mitspieler laedt die Datei, uebernimmt die vier Listen in seinen eigenen
-- Save_Player und speichert seinen Spielstand (vorher einmal Sicherung von PlayerInfo.sav).
local SAVE_BACK_EVERY = 60
local SAVE_PLAYER_CLASS = "/Game/Blueprints/Saves/Save_Player.Save_Player_C"
local CONTAINER_ITEMS_FIELD = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local PICKUP_REF_FIELD = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657"
local SaveBackAt = {}
local CHUNKS_PER_TICK = 20
local OutQueue = {}            -- [Controller-Key] = { PC, Chunks, Next }
local LastSentInventory = {}   -- [Controller-Key] = zuletzt geschickte Bytes (nur Aenderungen schicken)

local function SaveGamesDir()
    return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\"
end

-- In Bloecken statt gsub pro Byte: schneller, und die lange gsub-Schleife brach einmal mit einem
-- unerklaerlichen Lua-Fehler ab.
-- FromHex: erst pruefen (gerade Laenge, nur Hex-Zeichen, sonst nil), dann ein gsub ueber eine fertige Tabelle
-- (Paar -> Zeichen, klein und gross geschrieben) statt tonumber pro Byte. (FromHex hier mit drin: keine neue
-- lokale Variable im Hauptteil, Lua erlaubt nur 200.)
local ToHex, FromHex
do
    local HEX, HEX2CHR = {}, {}
    for I = 0, 255 do
        HEX[I] = string.format("%02x", I)
        HEX2CHR[HEX[I]], HEX2CHR[string.format("%02X", I)] = string.char(I), string.char(I)
    end
    ToHex = function(Bytes)
        local Out = {}
        for I = 1, #Bytes, 4096 do
            local Part = { Bytes:byte(I, math.min(I + 4095, #Bytes)) }
            for J = 1, #Part do Part[J] = HEX[Part[J]] end
            Out[#Out + 1] = table.concat(Part)
        end
        return table.concat(Out)
    end
    FromHex = function(Hex)
        if type(Hex) ~= "string" or #Hex % 2 ~= 0 or Hex:find("[^%x]") then return nil end
        local Out = Hex:gsub("%x%x", HEX2CHR)
        -- gemischte Schreibweise ("aF") steht nicht in der Tabelle und bliebe zweistellig stehen
        if #Out * 2 ~= #Hex then return nil end
        return Out
    end
end

-- Inventar einer Mitspieler-Figur als Save_Player-Kopie (fuer das Zurueckschreiben und das
-- Server-Inventar). nil, wenn die Figur (noch) kein Inventar hat.
local function BuildGuestSave(Pawn)
    local Inventory = IsAlive(Pawn) and Pawn.BP_JigMultiplayer
    if not IsAlive(Inventory) or #Inventory.MainJigContainers == 0 then return nil end
    -- Sicherung: Ein Inventar ohne einen einzigen Gegenstand nie speichern oder zurueckschicken
    -- (nach dem Lade-RPC sind die Listen beim Host zeitweise leer -> Spielstand waere ueberschrieben).
    local Items = 0
    Inventory.MainJigContainers:ForEach(function(_, Container)
        Items = Items + Container:get()[CONTAINER_ITEMS_FIELD]:GetArrayNum()
    end)
    if Items == 0 then return nil end
    -- CORE-20: Klasse und GameInstance pruefen (StaticConstructObject mit ungueltiger Huelle stuerzt nativ ab)
    local SaveClass, GI = StaticFindObject(SAVE_PLAYER_CLASS), UEHelpers.GetGameInstance()
    if not (IsAlive(SaveClass) and IsAlive(GI)) then error("Save_Player-Klasse oder GameInstance fehlt") end
    local Temp = StaticConstructObject(SaveClass, GI)
    if not IsAlive(Temp) then error("Save_Player nicht erzeugt") end
    Temp.MainJigContainers = Inventory.MainJigContainers
    Temp.MainUIDs = Inventory.MainContainersIDs
    Temp.Weights = Inventory.InventoryWeight
    -- Hotbar-IDs gibt es beim Host nicht (nur im UI des Mitspielers, RefillHotbar fuellt sie nach).
    -- Nie etwas Ungeprueftes einer Array-Eigenschaft zuweisen: das stuerzt ab.
    -- PickupRef zeigt auf den Gegenstand in der Welt des Hosts (z. B. die Waffe in der Hand). Beim
    -- Laden versucht Unreal, das zugehoerige Level von der Platte zu laden, das beim Mitspieler schon
    -- laeuft -> Absturz (RecastNavMesh ... does not have all load flags). Nur in der Kopie leeren.
    Temp.MainJigContainers:ForEach(function(_, Container)
        Container:get()[CONTAINER_ITEMS_FIELD]:ForEach(function(_, Item) Item:get()[PICKUP_REF_FIELD] = nil end)
    end)
    return Temp
end
Coop.BuildGuestSave = BuildGuestSave

local function SendGuestInventory(PC)
    local Pawn = PC:K2_GetPawn()
    if not IsAlive(Pawn) then return end
    local Temp = BuildGuestSave(Pawn)
    if not Temp then return end
    local Inventory = Pawn.BP_JigMultiplayer
    local PS = PC.PlayerState
    if not IsAlive(PS) then return end
    local Id = PS:GetPlayerId()
    local Slot = "NetTest_Guest_" .. Id
    if not UEHelpers.GetGameplayStatics():SaveGameToSlot(Temp, Slot, 0) then
        Log("Inventar von Spieler %d: Zwischenspeichern fehlgeschlagen", Id)
        return
    end
    local File = io.open(SaveGamesDir() .. Slot .. ".sav", "rb")
    if not File then Log("Inventar von Spieler %d: Datei nicht lesbar", Id) return end
    local Bytes = File:read("*a")
    File:close()
    local Key = PC:GetFullName()
    if LastSentInventory[Key] == Bytes then return end
    LastSentInventory[Key] = Bytes
    local Chunks = {}
    SendChunked(function(T) Chunks[#Chunks + 1] = T end, "inv", ToHex(Bytes))
    OutQueue[Key] = { PC = PC, Chunks = Chunks, Next = 1 }
    Log("Inventar von Spieler %d wird zurueckgeschickt (%d Container, %d Bytes, %d Stuecke)", Id,
        #Inventory.MainJigContainers, #Bytes, #Chunks)
end

-- Viele zuverlaessige Nachrichten auf einmal ueberlaufen den Puffer der Verbindung (der Mitspieler
-- flog raus). Darum hoechstens CHUNKS_PER_TICK Stuecke pro Sekunde und Mitspieler.

local function PumpQueues()
    for Key, Queue in pairs(OutQueue) do
        if not IsAlive(Queue.PC) then
            OutQueue[Key] = nil
        else
            for _ = 1, CHUNKS_PER_TICK do
                local Chunk = Queue.Chunks[Queue.Next]
                if not Chunk then OutQueue[Key] = nil break end
                SendToClient(Queue.PC, Chunk)
                Queue.Next = Queue.Next + 1
            end
        end
    end
end

local function HandleSaveBack(World)
    if NetModeName(World) ~= "ListenServer" then return end
    PumpQueues()
    if not SETTINGS.local_inventory then return end  -- Server-Inventar: nichts zurueckschicken
    local Now = os.time()
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            SaveBackAt[Key] = SaveBackAt[Key] or (Now + SAVE_BACK_EVERY)
            if Now >= SaveBackAt[Key] and not OutQueue[Key] then
                SaveBackAt[Key] = Now + SAVE_BACK_EVERY
                local ok, err = pcall(SendGuestInventory, PC)
                if not ok then Log("Zurueckschreiben fehlgeschlagen: %s", tostring(err)) end
            end
        end
    end
end

local SaveBackBackupDone = false

HostDataHandlers.inv = function(Hex)
    local Slot = "NetTest_FromHost"
    local Bytes = FromHex(Hex)
    if not Bytes then Log("Inventar vom Host: Daten beschaedigt (kein Hex), nichts uebernommen") return end
    local File = io.open(SaveGamesDir() .. Slot .. ".sav", "wb")
    if not File then Log("Inventar vom Host: Datei nicht schreibbar") return end
    File:write(Bytes)
    File:close()
    local Loaded = UEHelpers.GetGameplayStatics():LoadGameFromSlot(Slot, 0)
    if not IsAlive(Loaded) or #Loaded.MainJigContainers == 0 then
        Log("Inventar vom Host: unbrauchbar, nichts uebernommen")
        return
    end
    local Save = PlayerSave()
    if not IsAlive(Save) then return end
    Save.MainJigContainers = Loaded.MainJigContainers
    Save.MainUIDs = Loaded.MainUIDs
    Save.Weights = Loaded.Weights
    if not SETTINGS.save_back then
        Log("Inventar vom Host uebernommen (%d Container), Speichern abgeschaltet (Test)", #Save.MainJigContainers)
        return
    end
    local SlotName = Safe(function() local O = Save:GetOuter() return IsAlive(O) and O.CurrentSaveGameName:ToString() or "" end, "")
    if not SaveBackBackupDone and SlotName ~= "" then
        local Path = SaveGamesDir() .. SlotName .. "\\PlayerInfo.sav"
        local Source = io.open(Path, "rb")
        if Source then
            local Target = io.open(Path .. ".vor-koop", "wb")
            if Target then Target:write(Source:read("*a")) Target:close() SaveBackBackupDone = true end
            Source:close()
        end
    end
    local EMS = Coop.Cdo("/Script/EasyMultiSave.Default__EMSFunctionLibrary")   -- CORE-20
    local ok = EMS ~= nil and EMS:SaveCustom(CurrentWorld(), Save)
    Log("Inventar vom Host in eigenen Spielstand '%s' geschrieben: %s (%d Container)", SlotName,
        ok and "ok" or "Fehler", #Save.MainJigContainers)
end

-- Schaden der Mitspieler-Waffen: Den Schaden berechnet der Host (SERVER_DamageEvent). Die Werte
-- (Schaden, Fall-Off, Krit-Chance) holt FindStat der Waffe ueber GetPlayerCharacter(0) aus dem
-- Inventar-UI des Besitzers. Die Figur eines Mitspielers hat beim Host kein UI -> Ersatzwert 1:
-- 1 Schaden pro Schuss, Messer praktisch ohne Schaden. Der Host hat die Werte aber in den
-- Itemdaten (Stats des Gegenstands, dessen PickupRef genau diese Waffe ist). Darum traegt ein
-- Hook auf FindStat beim Host fuer Waffen anderer Spieler die echten Werte ein.
local ITEM_INFO_FIELD = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local STATS_FIELD = "Stats_26_C770972746930CB80CC49AB7A6D19359"
local STAT_NAME_FIELD = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"
local STAT_MIN_FIELD = "MinValue_6_4B4822A7420F784740B6A58155973EE6"
local STAT_MAX_FIELD = "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"
local WEAPON_CLASSES = {
    "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C",
    "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C",
}
local STAT_CACHE_SECONDS = 5
-- StatCache.Map = { [Waffen-Adresse] = { [Tag] = { Min, Max } } } fuer alle Gegenstaende mit Pickup-Actor in den
-- Inventaren der Mitspieler-Figuren; neu aufgebaut (und damit aufgeraeumt) in RegisterWeaponStatHooks (1 s), alle
-- STAT_CACHE_SECONDS s oder sobald der Hook eine unbekannte Waffe sah (Miss). Der Hook liest nur diese Tabelle.
local StatCache = { Map = {}, At = 0, Miss = false }
local StatHooked = {}

-- Alle Werte der Gegenstaende einer Figur, deren PickupRef ein Actor ist (ausgeruestete Waffen), in Map eintragen
local function ReadWeaponStats(Pawn, Map)
    local Inv = Pawn.BP_JigMultiplayer
    if not IsAlive(Inv) then return end
    Inv.MainJigContainers:ForEach(function(_, Container)
        Container:get()[CONTAINER_ITEMS_FIELD]:ForEach(function(_, Entry)
            local Item = Entry:get()
            local Ref = Item[PICKUP_REF_FIELD]
            if not (Ref and Ref:IsValid()) then return end
            local Stats = {}
            Item[ITEM_INFO_FIELD][STATS_FIELD]:ForEach(function(_, StatEntry)
                local Stat = StatEntry:get()
                Stats[Stat[STAT_NAME_FIELD].TagName:ToString()] = { Stat[STAT_MIN_FIELD], Stat[STAT_MAX_FIELD] }
            end)
            Map[Ref:GetAddress()] = Stats
        end)
    end)
end

-- Im Schadens-Hook (SERVER_DamageEvent -> FindStat, mehrfach je Treffer): keine Spielfunktion, nur StatCache.Map.
-- Waffen der eigenen Figur stehen nicht in der Tabelle (sie finden ihre Werte selbst ueber das eigene UI).
-- UE 5.6 (stat_force): FindStat liest ueber GetPlayerCharacter(0) -> InventoryWidgetRef der Gast-Figur (Host-Widget aus
-- SERVER_UpdateStatByUID @0c2d), das ein falsches/veraltetes Teil liefern kann -> auch bei Found=true die Werte der Gast-Waffe.
-- CORE-18 (Hook-Sweep): Dieser Hook bleibt bewusst - er muss Out-Parameter (Found/MinValue/MaxValue) setzen, das kann
-- kein DLL-Beobachter. Rumpf: nur GetAddress, Parameter und Lua-Tabellen, keine UFunction.
local function OnFindStat(Context, Tag, Found, MinValue, MaxValue)
    local Stats = StatCache.Map[Context:get():GetAddress()]
    if not Stats then
        if not Found:get() then StatCache.Miss = true end
        return
    end
    if Found:get() and not StatCache.Force then return end
    local Stat = Stats[Tag:get().TagName:ToString()]
    if Stat then
        Found:set(true)
        MinValue:set(Stat[1])
        MaxValue:set(Stat[2])
    end
end

-- Blueprint-Funktionen lassen sich erst hooken, wenn ihre Klasse geladen ist (erste Waffe).
local function RegisterWeaponStatHooks(World)
    if NetModeName(World) ~= "ListenServer" then return end
    for _, ClassPath in ipairs(WEAPON_CLASSES) do
        if not StatHooked[ClassPath] and StaticFindObject(ClassPath):IsValid() then
            StatHooked[ClassPath] = true
            TryHook(ClassPath .. ":FindStat", function(...)
                local ok, err = pcall(OnFindStat, ...)
                if not ok then Log("Waffenwerte-Fehler: %s", tostring(err)) end
            end)
            Log("Waffenwerte fuer Mitspieler aktiv: %s", ClassPath:match("([%w_]+)$"))
        end
    end
    -- Werte-Tabelle fuer den Hook (1 s-Takt, ausserhalb der Schadenskette)
    local CoreM = Coop.Modules and Coop.Modules.ls_core
    StatCache.Force = not (CoreM and CoreM.Flag) or CoreM.Flag("stat_force", true) == true
    if not next(StatHooked) then return end
    local Now = os.clock()
    if not StatCache.Miss and Now < StatCache.At then return end
    StatCache.Miss, StatCache.At = false, Now + STAT_CACHE_SECONDS
    local Map = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local Pawn = Safe(function() local O = PS:GetOwner() return IsAlive(O) and O:K2_GetPawn() or nil end)
        if IsAlive(Pawn) and Safe(function() return Pawn:GetClass():GetFName():ToString() end) == "BP_PlayerCharacter_C"
            and not Safe(function() return Pawn:IsLocallyControlled() end, true) then
            local ok, err = pcall(ReadWeaponStats, Pawn, Map)
            if not ok and not StatCache.ErrLogged then StatCache.ErrLogged = true Log("Waffenwerte-Fehler: %s", tostring(err)) end
        end
    end
    StatCache.Map = Map
end

-- Tote Spielerfiguren (z. B. der Host nach dem Tod) haben keine Kapsel-Kollision mehr. Beim
-- Mitspieler rechnet die Bewegung sie trotzdem weiter und sie fallen endlos durch den Boden, beim
-- Host bleiben sie liegen. Also anhalten und auf die Position vom Host zuruecksetzen.
-- Wer spaeter beitritt, verpasst den Tod-Multicast (MC_PlayerDead): Die Leiche (Todes-Kiste) stand bei
-- ihm als normale Spielerfigur mit Kapsel-Kollision da und liess sich nicht looten. PlayerDead? kommt
-- per Replikation an: dann den Multicast einmal lokal ausfuehren (erst, wenn die Figur 1 s bekannt ist,
-- nie mitten im Erzeugen).
Coop.DeadBodySeen, Coop.DeadBodyDone = {}, {}

local function HoldDeadBodies()
    local Now = os.clock()
    for _, Body in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        local Name = IsAlive(Body) and Body:GetFName():ToString()
        if Name and not Body:IsLocallyControlled() and not Coop.DeadBodyDone[Name]
            and Safe(function() return Body["PlayerDead?"] == true end, false) then
            Coop.DeadBodySeen[Name] = Coop.DeadBodySeen[Name] or Now
            local Cap = Body.CapsuleComponent
            if Now - Coop.DeadBodySeen[Name] >= 1 and IsAlive(Cap) and Cap:GetCollisionEnabled() ~= 0 then
                Coop.DeadBodyDone[Name] = true
                local ok, err = pcall(function() Body:MC_PlayerDead() end)
                Log("Tote Figur %s nachtraeglich eingerichtet: %s", Name, ok and "ok" or tostring(err))
            end
        end
        if IsAlive(Body) and not Body:IsLocallyControlled() and not IsAlive(Body.PlayerState)
            and Safe(function() local Cap = Body.CapsuleComponent return IsAlive(Cap) and Cap:GetCollisionEnabled() == 0 end, false) then
            local Move = Body.CharacterMovement
            if IsAlive(Move) and Move.MovementMode ~= 0 then
                Move:DisableMovement()
                local Target = Body.ReplicatedMovement.Location
                local Z = Body:K2_GetActorLocation().Z
                Body:K2_SetActorLocation({ X = Target.X, Y = Target.Y, Z = Target.Z }, false, {}, true)
                Log("Tote Figur %s angehalten (Z %.0f -> %.0f)", Body:GetFName():ToString(), Z, Target.Z)
            end
        end
    end
end

-- Zombie-Leichen: Beim Host wird beim Tod die Kapsel entfernt und nur das Mesh faellt als Ragdoll. Beim
-- Mitspieler kommt nur IsDead? an, die Figur bleibt stehen. Also selbst zur Ragdoll machen (wie beim
-- Host: Bewegung aus, Kapsel ohne Kollision, Mesh als Physik-Koerper, Animation angehalten) und als
-- Leiche markieren: Dead/CanAttack? sind nicht repliziert, ohne Dead=true verweigert JigCanInteract
-- das Looten. Sofort ueber OnRep_IsDead?, die Schleife faengt den Rest (z. B. Bosse) auf.
do
local Corpse = { Done = {}, At = {}, Still = {}, Glides = {}, Seen = {}, Queued = {}, BoxDone = {}, Hooked = false, Pending = {},  -- Done: [Name] = true, At: [Name] = uebernommene Host-Lage, Still: Ruhe-Pruefung, Glides: laufendes Gleiten; (Namen werden nicht wiederverwendet, Adressen schon)
    ONREP = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:OnRep_IsDead?" }

local function IsDeadAI(Char)
    return Safe(function() return Char["IsDead?"] == true end, false)
end

function Corpse.Setup(Char)
    local Name = Char:GetFName():ToString()
    if Corpse.Done[Name] then return end
    Corpse.Done[Name] = true
    -- Augen weg, Saeure-Explosion (siehe Zombie-Aussehen weiter unten)
    pcall(function() Coop.Zombies.OnClientDeath(Char, Name) end)
    local ok, err = pcall(function()
        -- einzeln: Tiere haben nicht alle Felder der Zombies
        pcall(function() Char.Dead = true end)
        pcall(function() Char["CanAttack?"] = false end)
        -- Das Stoehnen (Zombie_Cue) haelt nur der Host beim Tod an
        pcall(function() local Cue = Char.Zombie_Cue if IsAlive(Cue) then Cue:Stop() end end)
        local Mesh = Char.Mesh
        -- Tiere (BP_Animal*): ohne Kapsel-Restbewegung umfallen und nie auf die Host-Lage setzen (siehe unten)
        local IsAnimal = Safe(function() return Char:GetClass():GetFName():ToString():find("Animal", 1, true) ~= nil end, false)
        pcall(function() local Move = Char.CharacterMovement if IsAlive(Move) then Move:StopMovementImmediately() end end)
        pcall(function() local Move = Char.CharacterMovement if IsAlive(Move) then Move:DisableMovement() end end)
        pcall(function() local Cap = Char.CapsuleComponent if IsAlive(Cap) then Cap:SetCollisionEnabled(0) end end)
        if not IsAlive(Mesh) then return end
        -- Mesh von der Kapsel loesen: Der Host schreibt die Ragdoll-Lage in ReplicatedMovement, das
        -- verschiebt beim Mitspieler die Kapsel (Wurzel) jede Sekunde - die angehaengte Ragdoll wurde
        -- mitgerissen und flog hin und her. Positioniert wird sie nur noch von Corpse.Follow (corpse_v2:
        -- gar nicht mehr, sie bleibt liegen, wo sie hier faellt; Corpse.LocalRest friert sie ein).
        -- (Auch, wenn das Spiel sie schon selbst zur Ragdoll gemacht hat.)
        pcall(function() Mesh:K2_DetachFromComponent(1, 1, 1, false) end)  -- EDetachmentRule::KeepWorld
        -- Tiere: Bis zum Tod folgte die Kopie dem toten Tier des Hosts, das ohne Kapsel-Kollision in den Boden
        -- sinkt. Eine Ragdoll, die halb im Boden startet, schiesst die Physik nach oben heraus: darum vorher auf
        -- den Boden darunter setzen (Mesh-Ursprung = Fuesse), mit Teleport und ohne Physik.
        if IsAnimal and not Mesh:IsSimulatingPhysics(FName("None")) then
            local M = Mesh:K2_GetComponentLocation()
            local Floor = Coop.Ground(M, Char, 150)
            if Floor and M.Z < Floor + 5 then
                pcall(function() Mesh:K2_SetWorldLocation({ X = M.X, Y = M.Y, Z = Floor + 20 }, false, {}, true) end)
                Log("Tier-Leiche %s: aus dem Boden gehoben (%.0f cm)", Name, Floor + 20 - M.Z)
            end
        end
        if not Mesh:IsSimulatingPhysics(FName("None")) then
            Mesh:SetCollisionProfileName(FName("Ragdoll"), true)
            Mesh:SetSimulatePhysics(true)
            Mesh.bPauseAnims = true
        end
        -- Ohne Schwung umfallen (sonst fliegt sie mit dem Restimpuls weg) und gleich auf die Host-Lage
        pcall(function() Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false) end)
        pcall(function() Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false) end)
        -- Nur weit daneben (z. B. Leiche, die schon vor dem Beitritt lag) sofort hinsetzen; sonst faellt
        -- sie dort um, wo sie steht (kein Sprung), und gleitet erst spaeter einmal auf die Host-Lage.
        -- corpse_v2: kein laufender Lage-Sync. Nur eine grob falsche Lage (neu hereingekommene Leiche bei 0,0,0
        -- oder an der alten Lebend-Lage) per X/Y auf die einmal gesendete Host-Lage setzen, sie faellt lokal.
        -- Tiere nie: Die Ragdoll des Servers (ohne Grafik) liegt oft daneben oder in der Luft; das Versetzen einer schon
        -- simulierenden Ragdoll in Boden/Hang schleuderte die Leiche durch die Gegend. Sie faellt dort um, wo sie steht.
        if IsAnimal then
            Log("Tier-Leiche %s: lokal umgefallen (ohne Versetzen)", Name)
        elseif not SETTINGS.corpse_v2 then
            local R, M = Char.ReplicatedMovement.Location, Mesh:K2_GetComponentLocation()
            if (R.X ~= 0 or R.Y ~= 0) and (M.X - R.X) ^ 2 + (M.Y - R.Y) ^ 2 + (M.Z - R.Z) ^ 2 > 100 * 100 then
                Mesh:K2_SetWorldLocation({ X = R.X, Y = R.Y, Z = R.Z + 10 }, false, {}, true)
            end
        else
            local R, M = Char.ReplicatedMovement.Location, Mesh:K2_GetComponentLocation()
            if (R.X ~= 0 or R.Y ~= 0) and (M.X - R.X) ^ 2 + (M.Y - R.Y) ^ 2 > 300 * 300 then
                Mesh:K2_SetWorldLocation({ X = R.X, Y = R.Y, Z = R.Z + 50 }, false, {}, true)
            end
        end
    end)
    if not ok then Log("Leichen-Fehler bei %s: %s", Name, tostring(err)) end
end

-- Nur Figuren anfassen, die seit mindestens 1 s bekannt sind: Beim Beitritt kommen vorhandene Leichen
-- mit IsDead? = true herein, OnRep_IsDead? laeuft dann noch waehrend des Erzeugens. Physik/Abhaengen
-- in dem Moment liess das Spiel abstuerzen. Bekannt wird eine Figur nur in der Sekunden-Schleife (die
-- laeuft nie mitten im Erzeugen); HasActorBegunPlay ist aus Lua nicht aufrufbar.
function Corpse.Ready(Char, Name)
    local Now = os.clock()
    Corpse.Seen[Name] = Corpse.Seen[Name] or Now
    return Now - Corpse.Seen[Name] >= 1
end

-- Tier-Tod vom Host (Z.AnimalApply/AnimalApply2): Ragdoll sofort statt bis zu 1 s spaeter in der Sekunden-Schleife (in
-- der Zeit sank die Kopie mit dem toten Tier des Hosts in den Boden). Nur schon bekannte Figuren (Corpse.Ready).
Coop.CorpseNow = function(Char)
    if not IsAlive(Char) then return end
    local Name = Char:GetFName():ToString()
    if not Corpse.Done[Name] and Corpse.Ready(Char, Name) then Corpse.Setup(Char) end
end

-- Schnell-Aufgabe "corpse" (100 ms, Mitspieler): im OnRep-Hook vorgemerkte Leichen einrichten
function Corpse.Fast()
    local P = Corpse.Pending
    if #P == 0 then return end
    Corpse.Pending = {}
    for _, Char in ipairs(P) do
        if IsAlive(Char) then
            local ok, err = pcall(Corpse.Setup, Char)
            if not ok then Log("Leichen-Fehler: %s", tostring(err)) end
        end
    end
end

local function RagdollDeadAI()
    if not Corpse.Hooked then
        -- Im OnRep (Netzwerk-Empfang) nur Eigenschaften lesen (Role statt HasAuthority: 3 = ROLE_Authority) und die
        -- Figur in Corpse.Pending legen; kein ExecuteInGameThread im Hook. Eingerichtet wird in der Schnell-Aufgabe
        -- "corpse" (<= 100 ms spaeter).
        if not Corpse.FastAdded then Corpse.FastAdded = true Coop.AddFast("corpse", Corpse.Fast) end
        Corpse.Hooked = pcall(RegisterHook, Corpse.ONREP, function(Context)
            local Char = Context:get()
            if IsAlive(Char) and Safe(function() return Char.Role end, 3) ~= 3 and IsDeadAI(Char) then
                local Name = Char:GetFName():ToString()
                -- nur schon bekannte Figuren (frischer Tod), nie neu hereinkommende. Nicht hier im
                -- Netzwerk-Callback einrichten (Physik/Abhaengen mitten im Empfang), sondern gleich danach.
                if Corpse.Seen[Name] and Corpse.Ready(Char, Name) and not Corpse.Queued[Name] and #Corpse.Pending < 64 then
                    Corpse.Queued[Name] = true
                    Corpse.Pending[#Corpse.Pending + 1] = Char
                end
            end
        end)
    end
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and not Char:HasAuthority() then
            -- Auch lebende Zombies merken, damit ihr Tod spaeter sofort (per OnRep) eingerichtet wird
            Corpse.Ready(Char, Char:GetFName():ToString())
        end
        if IsAlive(Char) and IsDeadAI(Char) and Corpse.Ready(Char, Char:GetFName():ToString()) then
            local Name = Char:GetFName():ToString()
            if not Corpse.Done[Name] then Corpse.Setup(Char) end
            -- Stoehnen bleibt aus (das Spiel startet Zombie_Cue z. B. nach einem Wiederbeitritt neu)
            if not Char:HasAuthority() then
                pcall(function()
                    local Cue = Char.Zombie_Cue
                    if not IsAlive(Cue) then return end
                    if Cue:IsPlaying() then Cue:Stop() end
                    if Cue.VolumeMultiplier ~= 0 then Cue:SetVolumeMultiplier(0) end
                end)
            end
            -- corpse_v2: keine Host-Lage, nur lokal liegen lassen und einfrieren
            local ok, err
            if SETTINGS.corpse_v2 then
                ok, err = pcall(function() Corpse.LocalRest(Char, Char.Mesh) end)
            else
                ok, err = pcall(Corpse.Follow, Char, Name)
            end
            if not ok and not Corpse.FollowErr then Corpse.FollowErr = true Log("Leichen-Position: %s", tostring(err)) end
        end
    end
    if not SETTINGS.corpse_v2 then
        local ok, err = pcall(Corpse.GlideStep)
        if not ok and not Corpse.GlideErr then Corpse.GlideErr = true Log("Leichen-Absetzen: %s", tostring(err)) end
    end
    local okBox, errBox = pcall(Corpse.ClientBoxes)
    if not okBox and not Corpse.BoxErr then Corpse.BoxErr = true Log("Todes-Kisten-Fehler: %s", tostring(errBox)) end
    local okMark, errMark = pcall(Corpse.ClientMarkers)
    if not okMark and not Corpse.MarkErr then Corpse.MarkErr = true Log("Todes-Marker-Fehler: %s", tostring(errMark)) end
end

-- Todes-Kiste (Container_DeadPlayerLoot_C): Beim Mitspieler sank sie nach dem Beitritt endlos durch den
-- Boden (ihre eigene Logik sucht den Boden und findet ihn dort nicht) und liess sich nicht looten. Der
-- Host repliziert ihre Lage (Corpse.HostBoxes), der Mitspieler setzt sie dorthin und macht sie
-- unbeweglich (Mobility Static), damit sie nicht weiter sinkt.
Corpse.BOX_CLASS = "Container_DeadPlayerLoot_C"

function Corpse.HostBoxes()
    local Now = os.time()
    for Key, D in pairs(Corpse.Deaths) do if Now - D.T > 120 then Corpse.Deaths[Key] = nil end end
    for _, Box in ipairs(FindAllOf(Corpse.BOX_CLASS) or {}) do
        if IsAlive(Box) and not Box.bReplicateMovement then
            Box:SetReplicateMovement(true)
            pcall(function() Box:ForceNetUpdate() end)
        end
        -- Besitzer = der Spieler, der dort gestorben ist (Owner ist repliziert): Nur er sieht "Last Death"
        if IsAlive(Box) and next(Corpse.Deaths) and not IsAlive(Box:GetOwner()) then
            local L, Best, BestKey, BestD = Box:K2_GetActorLocation(), nil, nil, 2000 * 2000
            for Key, D in pairs(Corpse.Deaths) do
                local Dist = (D.L.X - L.X) ^ 2 + (D.L.Y - L.Y) ^ 2 + (D.L.Z - L.Z) ^ 2
                if Dist < BestD then Best, BestKey, BestD = D, Key, Dist end
            end
            local PC = Best and Corpse.PCOf(Best.Id)
            if PC then
                Box:SetOwner(PC)
                Corpse.Deaths[BestKey] = nil
                Log("Todes-Kiste %s gehoert Spieler %d", Box:GetFName():ToString(), Best.Id)
            end
        end
    end
end

-- Server: Tod einer Spielerfigur merken (Lage, PlayerId), fuer den Besitzer der Todes-Kiste
Corpse.Deaths = {}
function Corpse.NoteDeath(Pawn, HintPS)
    if not IsAlive(Pawn) or Corpse.Deaths[Pawn:GetFName():ToString()] then return end
    local PS = Pawn.PlayerState
    if not IsAlive(PS) then PS = HintPS end   -- nach UnPossess leer: der im Tod-Hook gelesene PlayerState
    if not IsAlive(PS) then return end
    Corpse.Deaths[Pawn:GetFName():ToString()] = { L = Pawn:K2_GetActorLocation(), Id = PS.PlayerId, T = os.time() }
end

Coop.NoteDeath = Corpse.NoteDeath

function Corpse.PCOf(Id)
    for _, PS in ipairs(PlayerStates(CurrentWorld())) do
        if PS.PlayerId == Id then
            local PC = PS:GetOwner()
            if IsAlive(PC) then return PC end
        end
    end
end

-- Spieler: "Last Death" (Marker der Todes-Kiste) nur fuer den Besitzer. Fremde Kisten: Marker und Anzeige
-- jede Sekunde ausblenden. Eigene: verschwand beim Respawn fast sofort -> Marker einmal pro neuer Figur neu
-- eintragen, solange die Kiste da ist.
-- All: Markerliste des Durchlaufs (FindAllOf einmal je Durchlauf, nicht je Kiste)
function Corpse.BoxMarkers(Box, All)
    local List, L = {}, Box:K2_GetActorLocation()
    if IsAlive(Box.DeathMarker) then List[1] = Box.DeathMarker end
    for _, M in ipairs(All or FindAllOf("BP_Marker_C") or {}) do
        if IsAlive(M) and (not List[1] or M:GetAddress() ~= List[1]:GetAddress()) then
            local P = M:K2_GetActorLocation()
            if (P.X - L.X) ^ 2 + (P.Y - L.Y) ^ 2 + (P.Z - L.Z) ^ 2 < 500 * 500 then List[#List + 1] = M end
        end
    end
    return List
end

-- Todes-Kisten des Durchlaufs: FindAllOf hoechstens 1x pro Sekunde (ClientBoxes und ClientMarkers teilen die Liste)
function Corpse.Boxes()
    local Now = os.clock()
    if not Corpse.BoxL or Now - (Corpse.BoxAt or 0) >= 0.9 or Corpse.BoxGen ~= WorldGen.N then
        Corpse.BoxL, Corpse.BoxAt, Corpse.BoxGen = FindAllOf(Corpse.BOX_CLASS) or {}, Now, WorldGen.N
    end
    return Corpse.BoxL
end

-- Fremde Kisten: einmal ausblenden, dann nur alle 10 s und nach jeder neuen eigenen Figur erneut (statt jede Sekunde
-- mit FindAllOf("BP_Marker_C") je Kiste). Markerliste einmal je Durchlauf.
function Corpse.ClientMarkers()
    local PC, Own = LocalPC(), nil
    Own = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end)
    local OwnAddr, Now, All = IsAlive(Own) and Own:GetAddress() or 0, os.clock(), nil
    local function Markers()
        All = All or FindAllOf("BP_Marker_C") or {}
        return All
    end
    Corpse.MarkerFor = Corpse.MarkerFor or {}
    local Hidden, Keep = Corpse.HiddenAt or {}, {}
    for _, Box in ipairs(Corpse.Boxes()) do
        if IsAlive(Box) then
            local Owner = Box:GetOwner()
            local Mine = IsAlive(Owner) and IsAlive(PC) and Owner:GetAddress() == PC:GetAddress()
            local Name = Box:GetFName():ToString()
            local H = Hidden[Name]
            if not Mine and H and H.Own == OwnAddr and Now < H.At then
                Keep[Name] = H
            elseif not Mine then
                Keep[Name] = { Own = OwnAddr, At = Now + 10 }
                if IsAlive(Box.DeathWidget) then Box.DeathWidget:SetVisibility(false, true) end
                for _, M in ipairs(Corpse.BoxMarkers(Box, Markers())) do
                    if IsAlive(M.Marker) then M.Marker:SetVisibility(1) end  -- Collapsed
                    -- Liste Markers gibt es nur in 5.3 (UE 5.6 BP_Marker_C: nur noch Marker, AddMarker @01b8)
                    if Coop.HasMember(M, "Markers") then
                        M.Markers:ForEach(function(_, W) local Widget = W:get() if IsAlive(Widget) then Widget:SetVisibility(1) end end)
                    end
                end
            elseif IsAlive(Own) and Corpse.MarkerFor[Name] ~= Own:GetAddress() and not Box["Looted?"] then
                Corpse.MarkerFor[Name] = Own:GetAddress()
                for _, M in ipairs(Corpse.BoxMarkers(Box, Markers())) do
                    if not IsAlive(M.Marker) then pcall(function() M:AddMarker() end) Log("Eigener Todes-Marker neu eingetragen (%s)", Name) end
                end
            end
        end
    end
    Corpse.HiddenAt = Keep   -- nur noch vorhandene Kisten
end

function Corpse.ClientBoxes()
    for _, Box in ipairs(Corpse.Boxes()) do
        local Name = IsAlive(Box) and Box:GetFName():ToString()
        if Name and not Box:HasAuthority() and not Corpse.BoxDone[Name] and Corpse.Ready(Box, Name) then
            local R = Box.ReplicatedMovement.Location
            if R.X ~= 0 or R.Y ~= 0 then
                Corpse.BoxDone[Name] = true
                Box:K2_SetActorLocation({ X = R.X, Y = R.Y, Z = R.Z }, false, {}, true)
                pcall(function() local Root = Box.RootComponent if IsAlive(Root) then Root:SetMobility(0) end end)  -- EComponentMobility::Static
                Log("Todes-Kiste %s auf die Host-Lage gesetzt und festgehalten", Name)
            end
        end
    end
end

-- Ruht die Ragdoll (Physik schlaeft oder seit 2 s weniger als 5 cm bewegt)? Auf beiden Rechnern,
-- jeder fuer seine eigene Ragdoll.
function Corpse.AtRest(Char, Mesh, L)
    if not Safe(function() return Mesh:IsAnyRigidBodyAwake() end, true) then return true end
    local Name, Now = Char:GetFName():ToString(), os.clock()
    local Last = Corpse.Still[Name]
    if not Last or (Last.X - L.X) ^ 2 + (Last.Y - L.Y) ^ 2 + (Last.Z - L.Z) ^ 2 > 5 * 5 then
        Corpse.Still[Name] = { X = L.X, Y = L.Y, Z = L.Z, T = Now }
        return false
    end
    return Now - Last.T >= 2
end

-- Mitspieler: Jeder Rechner rechnet seine Ragdoll selbst, die Haltung ist nie ganz gleich (wie in
-- anderen Spielen auch). Liegen beide (Host: Ruhe-Flag in ReplicatedMovement), die eigene Ragdoll
-- einmal auf die Host-Lage setzen, 1,5 s absetzen lassen und einfrieren: gleiche Stelle, kein Rutschen.
-- Bewegt der Host seine Leiche spaeter (z. B. Treffer), kommt eine neue Lage und sie wird neu gesetzt.
-- (Kein fluessiges Gleiten: dafuer braeuchte es eine schnelle Hintergrund-Schleife, und Lua in UE4SS ist
-- nicht threadsicher - das liess den Mitspieler beim Schiessen abstuerzen.)
function Corpse.Follow(Char, Name)
    if Corpse.Glides[Name] or not IsAlive(Char.Mesh) then return end
    if not Char.ReplicatedMovement.bSimulatedPhysicSleep then
        -- Keine Lage vom Host (dedizierter Server: seine Ragdolls ohne Grafik liegen oft in der Luft): die
        -- Leiche bleibt, wo sie beim Mitspieler zur Ruhe kommt, und wird dort eingefroren.
        if not Corpse.At[Name] and Corpse.AtRest(Char, Char.Mesh, Char.Mesh:K2_GetComponentLocation()) then
            Corpse.At[Name] = "eigen"
            Corpse.Freeze(Char.Mesh)
        end
        return
    end
    local R = Char.ReplicatedMovement.Location
    if R.X == 0 and R.Y == 0 then return end
    local Key = string.format("%.0f,%.0f,%.0f", R.X, R.Y, R.Z)
    if Corpse.At[Name] == Key then return end
    local Mesh = Char.Mesh
    local M = Mesh:K2_GetComponentLocation()
    if not Corpse.AtRest(Char, Mesh, M) then return end
    Corpse.At[Name] = Key
    if (M.X - R.X) ^ 2 + (M.Y - R.Y) ^ 2 + (M.Z - R.Z) ^ 2 < 30 * 30 then
        Corpse.Freeze(Mesh)
        return
    end
    -- Schon eingefroren (Host hat seine Leiche spaeter bewegt): fuer das Absetzen wieder Physik an
    if not Mesh:IsSimulatingPhysics(FName("None")) then
        pcall(function() Mesh:SetComponentTickEnabled(true) end)
        pcall(function() Mesh:SetSimulatePhysics(true) end)
    end
    Mesh:K2_SetWorldLocation({ X = R.X, Y = R.Y, Z = R.Z + 5 }, false, {}, true)
    Corpse.Glides[Name] = { Char = Char, T0 = os.clock() }
    Corpse.Settle(Corpse.Glides[Name])
end

-- corpse_v2 (Mitspieler): Leiche bleibt, wo sie hier zur Ruhe kommt, und wird dort einmal eingefroren (rein
-- lokal, keine Host-Lage). Merker wie bei Follow: Corpse.At[Name] = "eigen".
function Corpse.LocalRest(Char, Mesh)
    local Name = Char:GetFName():ToString()
    if Corpse.At[Name] or not IsAlive(Mesh) then return end
    if Corpse.AtRest(Char, Mesh, Mesh:K2_GetComponentLocation()) then
        Corpse.At[Name] = "eigen"
        Corpse.Freeze(Mesh)
    end
end

-- Festhalten: Die eigene Haltung liegt an der Host-Stelle oft nicht stabil (Hang, Bodenkontakt) und
-- rutschte sonst Meter weit weg; ohne Schwerkraft trieb sie mit dem Restschwung in den Himmel. Darum
-- die Haltung einfrieren: Mesh-Tick aus (Knochen bleiben, wie sie sind), dann Physik aus (Koerper
-- bleiben stehen, Looten trifft weiter). PutAllRigidBodiesToSleep ist aus Lua nicht aufrufbar.
function Corpse.Freeze(Mesh)
    if not IsAlive(Mesh) then return end
    pcall(function() Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false) end)
    pcall(function() Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false) end)
    pcall(function() Mesh:SetComponentTickEnabled(false) end)
    pcall(function() Mesh:SetSimulatePhysics(false) end)
end

-- Absetzen: Mit Schwerkraft, aber ohne Schwung sinkt sie auf den Boden (nach sofortigem Einfrieren
-- schwebte sie), nach 1,5 s einfrieren. Laeuft in der Sekunden-Schleife (RagdollDeadAI).
function Corpse.Settle(G)
    local Mesh = G.Char.Mesh
    if not IsAlive(Mesh) then return true end
    pcall(function() Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false) end)
    pcall(function() Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false) end)
    return os.clock() - G.T0 >= 1.5
end

function Corpse.GlideStep()
    for Name, G in pairs(Corpse.Glides) do
        local ok, Done = pcall(function() return not IsAlive(G.Char) or Corpse.Settle(G) end)
        if not ok or Done then
            Corpse.Glides[Name] = nil
            if ok and IsAlive(G.Char) then Corpse.Freeze(G.Char.Mesh) end
        end
    end
end

-- corpse_v2 (Host): kein Lage-Sync mehr (kein ReplicatedMovement-Schreiben). Ohne Kapsel liegt der Actor fuer
-- Unreal bei 0,0,0, ohne bAlwaysRelevant loescht der Mitspieler auch nahe Leichen. Darum relevant nur, solange
-- ein Mitspieler nahe ist: an unter 15000 (Sichtweite der Zombies), aus erst ueber 18000 (kein Flackern an der
-- Grenze). Ferne Leichen verschwinden beim Mitspieler, beim Zurueckkommen kommen sie neu. Selten senden
-- (NetUpdateFrequency 2, einmal je toter Figur); lebt der Actor wieder (Pooling), alte Werte zurueck.
-- HostDead: [Name] = { Char, Nuf = alter Wert, Rel = von hier relevant gesetzt }. Bewusst nicht in ResetCorpses:
-- HandleClient ruft das beim Host jede Sekunde auf.
Corpse.HostDead = {}
Coop.ForgetHostDead = function() Corpse.HostDead = {} end   -- Weltwechsel (Coop.DropWorldRefs)

function Corpse.HostRelevance(Char, Mesh, Guests)
    local Name = Char:GetFName():ToString()
    local E = Corpse.HostDead[Name]
    if not E then
        E = { Char = Char, Nuf = Safe(function() return Char.NetUpdateFrequency end) }
        Corpse.HostDead[Name] = E
        pcall(function() Char.NetUpdateFrequency = 2 end)
    end
    local L, Near, Far = Mesh:K2_GetComponentLocation(), false, true
    for _, G in ipairs(Guests) do
        local D2 = (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2
        if D2 < 15000 * 15000 then Near = true end
        if D2 < 18000 * 18000 then Far = false end
    end
    if Near and not Char.bAlwaysRelevant then
        Char.bAlwaysRelevant, E.Rel = true, true
        -- Einmalige Lage (kein laufender Sync): Kommt die Leiche beim Mitspieler neu herein (zurueckgekommen,
        -- spaeter beigetreten), erzeugt er sie hier statt bei 0,0,0. Die Hoehe ist beim Server unzuverlaessig,
        -- der Mitspieler nimmt nur X/Y (Corpse.Setup) und laesst sie selbst fallen.
        pcall(function() Char.ReplicatedMovement.Location = { X = L.X, Y = L.Y, Z = L.Z } end)
        pcall(function() Char:ForceNetUpdate() end)
    elseif Far and E.Rel and Char.bAlwaysRelevant then
        Char.bAlwaysRelevant, E.Rel = false, nil   -- nur selbst gesetztes zuruecknehmen
    end
end

function Corpse.HostAlive(Char)
    local Name = Char:GetFName():ToString()
    local E = Corpse.HostDead[Name]
    if not E then return end
    Corpse.HostDead[Name] = nil
    if type(E.Nuf) == "number" then pcall(function() Char.NetUpdateFrequency = E.Nuf end) end
    if E.Rel then pcall(function() Char.bAlwaysRelevant = false end) end
    Log("Leiche %s lebt wieder (Pooling): NetUpdateFrequency/Relevanz zurueck", Name)
end

-- Der Host animiert Figuren nur, wenn er sie selbst sieht (OnlyTickPoseWhenRendered). Zombie-Angriffe
-- (Montage + AnimNotify) und die Nahkampf-Treffer des Mitspielers haengen an der Animation: Steht der
-- Mitspieler weit weg vom Host, bekommt er kaum Schaden und sein Messer trifft nicht. Daher beim Host
-- die Mitspieler-Figuren und alle Figuren in ihrer Naehe immer animieren.
local WAKE_RADIUS = 6000

local ALWAYS_TICK = 0  -- EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones
local WokenMeshes = {}  -- [Mesh-Adresse] = urspruengliche Einstellung
local SkeletalMeshClass = nil

local function WakeAINearGuests(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local okBox, errBox = pcall(Corpse.HostBoxes)
    if not okBox and not Corpse.BoxErr then Corpse.BoxErr = true Log("Todes-Kisten-Fehler (Host): %s", tostring(errBox)) end
    SkeletalMeshClass = SkeletalMeshClass or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    local Guests = {}
    for _, Pawn in ipairs(PlayerPawns()) do
        if not Pawn:IsLocallyControlled() and IsAlive(Pawn.PlayerState) then
            Guests[#Guests + 1] = Pawn:K2_GetActorLocation()
            for _, Mesh in ipairs(Coop.ArrList(Pawn:K2_GetComponentsByClass(SkeletalMeshClass))) do
                if IsAlive(Mesh) and Mesh.VisibilityBasedAnimTickOption ~= ALWAYS_TICK then
                    Mesh.VisibilityBasedAnimTickOption = ALWAYS_TICK
                end
            end
        end
    end
    local Seen, Radius2 = {}, WAKE_RADIUS * WAKE_RADIUS
    -- wake_v2: Weckwert jede Sekunde neu setzen (statt einmalig) + Mesh-TickInterval des AI-Optimizers aufheben
    local CoreM = Coop.Modules and Coop.Modules.ls_core
    local Re = not (CoreM and CoreM.Flag) or CoreM.Flag("wake_v2", true) == true
    -- corpse_v2: Merker toter Actors aufraeumen (zerstoert, z. B. Leichen-Aufraeumen des Servers)
    if SETTINGS.corpse_v2 then
        for Name, E in pairs(Corpse.HostDead) do
            if not IsAlive(E.Char) then Corpse.HostDead[Name] = nil end
        end
    end
    for _, Char in ipairs(Coop.Characters()) do
        local Mesh = IsAlive(Char) and Char:GetClass():GetFName():ToString() ~= "BP_PlayerCharacter_C" and Char.Mesh
        local Dead = Mesh and Mesh:IsValid() and IsDeadAI(Char)
        if Dead and SETTINGS.corpse_v2 then
            local ok, err = pcall(Corpse.HostRelevance, Char, Mesh, Guests)
            if not ok and not Corpse.HostErr then Corpse.HostErr = true Log("Leichen-Relevanz (Host): %s", tostring(err)) end
        elseif SETTINGS.corpse_v2 and Mesh and Mesh:IsValid() and next(Corpse.HostDead) then
            -- lebt wieder (Pooling): alte Werte zurueck
            pcall(Corpse.HostAlive, Char)
        end
        if Dead and not SETTINGS.corpse_v2 then
            -- Leiche: Ohne Kapsel liegt der Actor fuer Unreal bei 0,0,0 und faellt beim Mitspieler aus
            -- der Sichtweite (er loescht sie). Leichen nahe einem Mitspieler darum immer schicken.
            local L = Mesh:K2_GetComponentLocation()
            if not Char.bAlwaysRelevant then
                for _, G in ipairs(Guests) do
                    if (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2 < 15000 * 15000 then  -- Sichtweite (NetCullDistance) der Zombies
                        Char.bAlwaysRelevant = true
                        pcall(function() Char:ForceNetUpdate() end)
                        break
                    end
                end
            end
            -- Lage der Ragdoll fuer den Mitspieler (ohne Kapsel aktualisiert Unreal ReplicatedMovement
            -- nicht), erst wenn sie liegt. Das Ruhe-Flag sagt dem Mitspieler: Diese Lage ist endgueltig.
            -- Nicht im Server-Modus: ohne Grafik ist die Ragdoll des Servers unzuverlaessig (lag in der Luft)
            if Char.bAlwaysRelevant and not SETTINGS.server and Corpse.AtRest(Char, Mesh, L) then
                local R = Char.ReplicatedMovement.Location
                if not Char.ReplicatedMovement.bSimulatedPhysicSleep
                    or (R.X - L.X) ^ 2 + (R.Y - L.Y) ^ 2 + (R.Z - L.Z) ^ 2 > 20 * 20 then
                    Char.ReplicatedMovement.Location = { X = L.X, Y = L.Y, Z = L.Z }
                    Char.ReplicatedMovement.bSimulatedPhysicSleep = true
                    pcall(function() Char:ForceNetUpdate() end)
                end
            end
        end
        if Mesh and Mesh:IsValid() then
            local Key, L, Near = Mesh:GetAddress(), Char:K2_GetActorLocation(), false
            -- corpse_v2: Leichen nicht animieren (Near bleibt false: eine frueher geweckte bekommt ihren Wert zurueck)
            if not (Dead and SETTINGS.corpse_v2) then
                for _, G in ipairs(Guests) do
                    if (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2 + (L.Z - G.Z) ^ 2 < Radius2 then Near = true break end
                end
            end
            Seen[Key] = true
            if Near and (Re or WokenMeshes[Key] == nil) then
                local Cur = Mesh.VisibilityBasedAnimTickOption
                if WokenMeshes[Key] == nil then
                    -- ls_ai (ai_wake) uebergibt seinen Originalwert (Coop.WakeOrig), sonst der aktuelle Wert
                    WokenMeshes[Key] = (Re and Coop.WakeOrig and Coop.WakeOrig[Key]) or Cur
                end
                if Coop.WakeOrig then Coop.WakeOrig[Key] = nil end
                -- jede Sekunde neu: ls_ai-Ruecksetzung und AI-Optimizer-Layerwechsel ueberschreiben den Wert sonst dauerhaft
                if Cur ~= ALWAYS_TICK then Mesh.VisibilityBasedAnimTickOption = ALWAYS_TICK end
                -- UE 5.6: OnOptimizationUpdate setzt Mesh-TickInterval 0.05-0.3 s (@3bc7/@3c8a/@3947/@39e6) -> Sockets/Notifies stocken
                if Re and not Dead then
                    pcall(function() if Mesh:GetComponentTickInterval() > 0 then Mesh:SetComponentTickInterval(0) end end)
                end
            elseif not Near and WokenMeshes[Key] ~= nil then
                Mesh.VisibilityBasedAnimTickOption = WokenMeshes[Key]
                WokenMeshes[Key] = nil
            end
        end
    end
    for Key in pairs(WokenMeshes) do
        if not Seen[Key] then WokenMeshes[Key] = nil end
    end
    if Coop.WakeOrig then for Key in pairs(Coop.WakeOrig) do if not Seen[Key] then Coop.WakeOrig[Key] = nil end end end
end

-- Neue Mitspieler-Figur: Das Spiel friert sie beim Spawn ein (Bewegungsmodus "None") und gibt sie
-- normalerweise nach ~10 s frei. Selten bleibt das aus: Der Mitspieler schwebt und kann nicht laufen.
-- Ist sie 15 s nach dem Spawn noch eingefroren, faellt sie auf den Boden ("Falling"). Host und
-- Mitspieler frieren ihre Kopie jeweils selbst ein, darum geben beide frei.
-- (Als Tabelle statt einzelner lokaler Variablen: Lua erlaubt im Hauptteil nur 200.)
local U = { AFTER = 15, Seen = {}, OwnChecked = nil }  -- Seen: [Figurenname] = erstes Sehen (false = geprueft)

function U.Unfreeze(Pawn)
    local Move = Pawn.CharacterMovement
    if not IsAlive(Move) or Move.MovementMode ~= 0 or IsAlive(Pawn:GetAttachParentActor()) then return false end
    Move:SetMovementMode(3, 0)
    return true
end

function U.OwnPawn(Pawn, Since)
    local Name = Pawn:GetFName():ToString()
    if U.OwnChecked == Name or os.time() - Since < U.AFTER then return end
    if Coop.JoinLoading() then return end   -- join_v2: eingefroren hinter dem Ladebildschirm, erst nach ready
    U.OwnChecked = Name
    if U.Unfreeze(Pawn) then Log("Eigene Figur war nach dem Spawn eingefroren: freigegeben") end
end

function U.Guests(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Now = os.time()
    for _, Pawn in ipairs(PlayerPawns()) do
        if not Pawn:IsLocallyControlled() and IsAlive(Pawn.PlayerState) then
            local Name = Pawn:GetFName():ToString()
            local Since = U.Seen[Name]
            if Since == nil then
                U.Seen[Name] = Now
            elseif Since and Now - Since >= U.AFTER and Coop.Join.IsReady(Pawn) then   -- join_v2: erst nach ready
                U.Seen[Name] = false
                if U.Unfreeze(Pawn) then Log("Mitspieler-Figur %s war nach dem Spawn eingefroren: freigegeben", Name) end
            end
        end
    end
end

Coop.WakeAINearGuests, Coop.UnfreezeSpawnedGuests, Coop.UnfreezeOwnPawn = WakeAINearGuests, U.Guests, U.OwnPawn
Coop.RegisterWeaponStatHooks, Coop.HoldDeadBodies = RegisterWeaponStatHooks, HoldDeadBodies
Coop.RagdollDeadAI, Coop.IsDeadAI = RagdollDeadAI, IsDeadAI
-- Nach dem Trennen vergessen: In der neuen Welt kommen dieselben Namen wieder vor, sonst wuerden
-- Leichen nach einem Wiederbeitritt nicht mehr eingerichtet (und stoehnen weiter). (corpse_v2: LocalRest merkt
-- sich das Einfrieren in At, das hier mit geleert wird; Corpse.HostDead nicht - laeuft beim Host jede Sekunde.)
Coop.ResetCorpses = function()
    Corpse.Done, Corpse.At, Corpse.Still, Corpse.Glides, Corpse.Seen, Corpse.Queued, Corpse.BoxDone = {}, {}, {}, {}, {}, {}, {}
    Corpse.Pending, Corpse.HiddenAt, Corpse.BoxL = {}, {}, nil
    Coop.DeadBodySeen, Coop.DeadBodyDone = {}, {}
end
end  -- Leichen, KI-Animation, Spawn-Freigabe (eigener Block: Lua erlaubt nur 200 lokale Variablen)
Coop.SyncEquipmentCollision, Coop.UploadOwnInventory = SyncEquipmentCollision, UploadOwnInventory
Coop.HandleSaveBack = HandleSaveBack
-- Tod: ausstehendes Zurueckschreiben (Stand von vor dem Tod) verwerfen und erst nach SAVE_BACK_EVERY neu
Coop.CancelSaveBack = function(Key)
    OutQueue[Key], LastSentInventory[Key], SaveBackAt[Key] = nil, nil, os.time() + SAVE_BACK_EVERY
end
-- CORE-30 (leave_forget) / Weltwechsel: Zurueckschreib-Warteschlange vergessen. Die Tabellen sind lokal in diesem Block,
-- Coop.ForgetKey liegt ausserhalb und sah sie nur als nil-Globale. Key=nil: alles leeren (Coop.DropWorldRefs), damit
-- OutQueue keine Controller der alten Welt haelt (IsAlive darauf in PumpQueues stuerzt nativ ab).
Coop.ForgetSaveBack = function(Key)
    if Key == nil then
        for _, T in ipairs({ OutQueue, LastSentInventory, SaveBackAt }) do for K in pairs(T) do T[K] = nil end end
    else
        OutQueue[Key], LastSentInventory[Key], SaveBackAt[Key] = nil, nil, nil
    end
end
Coop.ResetClientInventory = function() InventoryUploaded, CollisionOff, Coop.InventoryMode = false, {}, nil end
end

do
-- Werte des Mitspielers: Leben, Hunger, Durst, Strahlung (an der Figur) sowie Stufe, XP, Skillpunkte
-- und passive Faehigkeiten (am Controller). Gerechnet wird beim Host, die Kopie beim Mitspieler steht
-- still. Im Server-Modus speichert der Host sie neben dem Inventar (erster Beitritt = Startwerte), im
-- lokalen Modus bringt der Mitspieler seine mit. Stufe/XP/Faehigkeiten spiegelt der Host zum
-- Mitspieler (dessen Anzeige erfaehrt sie sonst nie), Leben & Co. schickt das Spiel selbst.
local V = { ON_PAWN = { MedicalComponent = true, HungerThirstComponent = true, RadiationComponent = true },
            VITALS = { { "MedicalComponent", "Health" }, { "HungerThirstComponent", "CurrentHunger" },
                       { "HungerThirstComponent", "CurrentThirst" }, { "RadiationComponent", "CurrentRadiation" } },
            PROGRESS = { { "LevellingComponent", { "CurrentLevel", "CurrentXP", "CurrentMaxXP", "CurrentPercentage",
                                                   "BufferXP", "RemainingXP" } },
                         { "TechTreeComponent", { "SkillPoints", "CurrentPoints" } } },
            Ready = {}, SentText = {}, CheckAt = {}, StoredText = {},
            -- Skillpunkt-Ausgaben (V.OnSpend/V.ApplySpend): Host [Key] = letzte Meldung bzw. abgezogener Stand,
            -- Gast: Summe seit Verbindungsbeginn (SpendSent), vom Host bestaetigt (SpendAck), Sitzungs-Kennung
            SpendIn = {}, SpendDone = {}, SpendSent = 0, SpendAck = 0,
            TT_CLASS = "/Game/Blueprints/Components/TechTreeComponent.TechTreeComponent_C",
            -- UE 5.6: Figur-Eigenschaft "Hunger&ThirstComponent" (props.tsv 0x7D0), 5.3 "HungerThirstComponent". Im
            -- Text (werte.txt, vit/vitset) bleibt der alte Name (%w-Muster, & geht dort nicht); V.Comp loest ihn auf.
            ALIAS = { HungerThirstComponent = "Hunger&ThirstComponent" } }

-- Komponente am Besitzer (Figur/Controller) ueber den Text-Namen (UE 5.6 zuerst der neue Name aus ALIAS)
function V.Comp(Owner, Comp)
    local New = V.ALIAS[Comp]
    local C = New and Safe(function() return Owner[New] end) or nil
    if IsAlive(C) then return C end
    C = Safe(function() return Owner[Comp] end)
    return IsAlive(C) and C or nil
end

-- Felder der passiven Faehigkeiten (Current*, Max*XP, *Percentage), einmal aus der Klasse gelesen.
function V.SkillFields(Comp)
    if V.Skills then return V.Skills end
    if not IsAlive(Comp) then return {} end
    local Names = {}
    Comp:GetClass():ForEachProperty(function(Prop)
        local N = Prop:GetFName():ToString()
        if Prop:GetClass():GetFName():ToString() == "DoubleProperty"
            and (N:match("^Current") or N:match("^Max.*XP$") or N:match("Percentage$")) then
            Names[#Names + 1] = N
        end
    end)
    V.Skills = Names
    return Names
end

-- "Komponente.Feld=Wert;..." (mit oder ohne Leben & Co.)
function V.Collect(Pawn, PC, WithVitals)
    local Parts = {}
    if not IsAlive(PC) then error("kein Controller") end
    local function Add(Owner, Comp, Field)
        local C = V.Comp(Owner, Comp)
        if not IsAlive(C) then error("Komponente " .. Comp .. " fehlt") end
        local Value = C[Field]
        Parts[#Parts + 1] = Comp .. "." .. Field .. "="
            .. (math.type(Value) == "integer" and tostring(Value) or string.format("%.10g", Value))
    end
    if WithVitals then
        for _, E in ipairs(V.VITALS) do Add(Pawn, E[1], E[2]) end
    end
    for _, E in ipairs(V.PROGRESS) do
        for _, Field in ipairs(E[2]) do Add(PC, E[1], Field) end
    end
    for _, Field in ipairs(V.SkillFields(PC.PassiveSkillsComponent)) do Add(PC, "PassiveSkillsComponent", Field) end
    -- Position fuer den Wiederbeitritt (Server-Modus): letzter Punkt am Boden, nicht mitten im Sprung/Fall
    if WithVitals and Pawn then
        local State = MovementState[PC:GetFullName()]
        local L, Yaw = (State and State.Ground) or Pawn:K2_GetActorLocation(), Pawn:K2_GetActorRotation().Yaw
        Parts[#Parts + 1] = string.format("Pos.X=%.1f;Pos.Y=%.1f;Pos.Z=%.1f;Pos.Yaw=%.1f", L.X, L.Y, L.Z, Yaw)
    end
    return table.concat(Parts, ";")
end

function V.Apply(Pawn, PC, Text)
    local Count = 0
    for Comp, Field, Value in Text:gmatch("(%w+)%.([%w_]+)=([^;]+)") do
        local Owner, Number = V.ON_PAWN[Comp] and Pawn or PC, tonumber(Value)
        if Comp ~= "Pos" and IsAlive(Owner) and Number and pcall(function() local C = V.Comp(Owner, Comp) if not IsAlive(C) then error("keine Komponente") end C[Field] = Number end) then
            Count = Count + 1
        end
    end
    return Count
end

-- Host: Anzeige des Mitspielers fuer Leben & Co. sofort aktualisieren (sonst erst bei der naechsten
-- Aenderung - das Leben stand nach dem Beitritt auf dem Wert seines lokalen Spielstands).
function V.PushVitalsUI(Pawn)
    if not IsAlive(Pawn) then return end
    pcall(function() local C = Pawn.MedicalComponent if IsAlive(C) then Pawn:Client_UpdateHealthUI(C.Health) end end)
    pcall(function() local C = V.Comp(Pawn, "HungerThirstComponent") if IsAlive(C) then Pawn:Client_UpdateHungerUI(C.CurrentHunger) end end)
    pcall(function() local C = V.Comp(Pawn, "HungerThirstComponent") if IsAlive(C) then Pawn:Client_UpdateThirstUI(C.CurrentThirst) end end)
    pcall(function() local C = Pawn.RadiationComponent if IsAlive(C) then Pawn:Client_UpdateRadiationUI(C.CurrentRadiation) end end)
end

function V.SetReady(Key, Pawn)
    V.Ready[Key], V.SentText[Key], V.CheckAt[Key] = true, nil, nil
    V.PushVitalsUI(Pawn)
end

function V.Path(GuestId)
    return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\"
        .. GuestId .. ".werte.txt"
end

-- Letzte Position des Mitspielers aus seiner Werte-Datei (Text: schon gelesen, sonst aus der Datei): Ziel 50 cm
-- ueber dem gespeicherten Punkt und Blickrichtung, nil ohne (nach einem Tod ist keine gespeichert -> Spawnpunkt).
-- Auch fuer join_v2 (Coop.Join.Target: direkt dort spawnen).
function V.ReadPos(GuestId, Text)
    if not Text then
        local File = io.open(V.Path(GuestId), "r")
        Text = File and File:read("*a")
        if File then File:close() end
    end
    local X, Y, Z, Yaw = (Text or ""):match("Pos%.X=([^;]+);Pos%.Y=([^;]+);Pos%.Z=([^;]+);Pos%.Yaw=([^;]+)")
    if not X then return nil end
    return { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) + 50 }, tonumber(Yaw)
end

-- Server-Modus, erster Abgleich nach dem Beitritt: gespeicherte Werte oder Startwerte.
function V.Restore(Key, Pawn, PC, GuestId)
    local File = io.open(V.Path(GuestId), "r")
    local Text = File and File:read("*a")
    if File then File:close() end
    if Text and Text ~= "" then
        Log("Werte von Mitspieler %s geladen (%d Felder)", GuestId, V.Apply(Pawn, PC, Text))
        -- Server-Modus: zurueck an die letzte Position (nach einem Tod ist keine gespeichert -> Spawnpunkt)
        local Target, Yaw = V.ReadPos(GuestId, Text)
        -- join_v2: Figur wurde schon dort (bzw. am Spawnpunkt) gespawnt und steht hinter dem Ladebildschirm
        local Join = Coop.Join[Key]
        if Target and SETTINGS.server and type(Join) == "table" and Join.Placed
            and Join.PawnName == Pawn:GetFName():ToString() then
            Log("Mitspieler %s steht schon am Beitritts-Ziel (%s): kein Teleport", GuestId, tostring(Join.Kind))
        elseif Target and SETTINGS.server then
            Pawn:K2_TeleportTo(Target, { Pitch = 0, Yaw = Yaw, Roll = 0 })
            local State = MovementState[PC:GetFullName()]
            if State then State.Ground = Target end
            Log("Mitspieler %s an seine letzte Position gesetzt (%.0f %.0f %.0f)", GuestId, Target.X, Target.Y, Target.Z)
        end
    else
        local M, H, R = Pawn.MedicalComponent, V.Comp(Pawn, "HungerThirstComponent"), Pawn.RadiationComponent
        if not (IsAlive(M) and IsAlive(H) and IsAlive(R)) then error("Werte-Komponenten fehlen") end
        M.Health, H.CurrentHunger, H.CurrentThirst = M.MaxHealth, H.MaxHunger, H.MaxThirst
        R.CurrentRadiation = R.MaxRadiation
        Log("Mitspieler %s ohne gespeicherte Werte: Startwerte (Stufe %d)", GuestId, Safe(function() local L = PC.LevellingComponent return IsAlive(L) and L.CurrentLevel or -1 end, -1))
    end
    V.SetReady(Key, Pawn)
end

-- Tod: nur Stufe/XP/Faehigkeiten behalten (Leben, Hunger usw. beginnen nach dem Tod neu). Sonst kaemen
-- bei einem Wiederbeitritt die Werte von vor dem Tod zurueck.
function V.StoreProgressOnly(PC, GuestId)
    local Text = V.Collect(nil, PC, false)
    local File = io.open(V.Path(GuestId), "w")
    if not File then return end
    File:write(Text)
    File:close()
    V.StoredText[GuestId] = Text
end

-- Nie mit 0 Leben speichern (Tod): Beim naechsten Beitritt waere er sofort wieder tot.
function V.Store(Pawn, PC, GuestId)
    local Med = IsAlive(Pawn) and Pawn.MedicalComponent
    if not (IsAlive(Med) and Med.Health > 0) then return end
    local Text = V.Collect(Pawn, PC, true)
    if Text == V.StoredText[GuestId] then return end
    local File = io.open(V.Path(GuestId), "w")
    if not File then return end
    File:write(Text)
    File:close()
    V.StoredText[GuestId] = Text
end

-- Host, pro Mitspieler: Stufe/XP/Faehigkeiten bei Aenderung zum Mitspieler schicken.
function V.HostTick(Key, PC, Pawn, Now)
    if V.SpendIn[Key] then V.ApplySpend(Key, PC) end
    if not V.Ready[Key] or Now < (V.CheckAt[Key] or 0) then return end
    V.CheckAt[Key] = Now + 2
    local Text = V.Collect(Pawn, PC, false)
    -- Bestaetigung der gemeldeten Skillpunkt-Ausgaben (alte Gaeste: V.Apply ueberspringt den nicht-numerischen Wert)
    local R = V.SpendDone[Key]
    if R then Text = Text .. ";Spend.Ack=" .. R.Nonce .. ":" .. R.N end
    if Text ~= V.SentText[Key] then
        V.SentText[Key] = Text
        Coop.SendChunked(function(T) SendToClient(PC, T) end, "vit", Text)
    end
end

-- Skillpunkte: TechTreeComponent hat keine RPCs und wird nicht repliziert. Der Gast kauft Techniken lokal (PayCost zieht
-- nur bei ihm ab), der vit-Spiegel setzte die Punkte danach auf den nie verringerten Host-Wert zurueck (Punkte zurueck,
-- Technik bleibt; gespeichert wurde der Host-Wert). Jetzt meldet der Gast jede Ausgabe (Hook PayCost, nur beim Kauf) als
-- Summe "<Sitzung>|<gesamt>" ("vitspend"), der Host zieht den neuen Teil von seiner Kopie ab (nie unter 0) und
-- bestaetigt im vit-Text (Spend.Ack). Bis dahin zieht der Gast den offenen Rest vom Host-Wert ab. Der Gast kann so
-- nur eigene Punkte verringern, nie erhoehen.
-- Host (Empfangs-Hook): nur merken, abgezogen wird in V.HostTick (Spiel-Thread)
function V.OnSpend(Key, Data)
    local Nonce, Total = tostring(Data):match("^(%x+)|(%d+)$")
    Total = tonumber(Total)
    if not Nonce or not Total or Total > 100000 then return end
    V.SpendIn[Key] = { Nonce = Nonce, Total = Total }
end

function V.ApplySpend(Key, PC)
    local In = V.SpendIn[Key]
    if not In or not IsAlive(PC) then return end
    local R = V.SpendDone[Key]
    if not R or R.Nonce ~= In.Nonce then R = { Nonce = In.Nonce, N = 0 } V.SpendDone[Key] = R end   -- neue Verbindung
    local Delta = In.Total - R.N
    if Delta <= 0 then return end
    local TT = PC.TechTreeComponent
    if not IsAlive(TT) then return end
    local Have = math.max(0, math.floor(tonumber(TT.SkillPoints) or 0))
    -- world_tech: W.TechHost (ls_world, w_tech) zieht dieselbe Technik schon von dieser Server-Kopie ab (mit Eltern-/
    -- Kostenpruefung) -> hier nicht noch einmal abziehen, nur bestaetigen. Bestaetigt wird erst, wenn die Host-Punkte
    -- gesunken sind (w_tech verarbeitet) oder nach 10 s, damit der Gast nie kurz zu viele Punkte sieht.
    local NetM = Coop.Net
    if Coop.Modules and Coop.Modules.ls_world and NetM and Safe(function() return NetM.Has("wtech", Key) end, false) then
        local Clock = os.clock()
        if not R.Wait or R.Wait.Total ~= In.Total then R.Wait = { Total = In.Total, SP = Have, At = Clock + 10 } end
        if Have > R.Wait.SP - Delta and Clock < R.Wait.At then return end
        R.N, R.Wait = In.Total, nil
        Log("Skillpunkte: Mitspieler %s hat %d ausgegeben - Abzug uebernimmt der Tech-Abgleich (w_tech), nur bestaetigt (Host-Kopie %d)",
            Coop.GuestIds[Key] or Key:match("[^%.]+$") or Key, Delta, Have)
        return
    end
    local Take = math.min(Delta, Have)
    TT.SkillPoints = Have - Take
    R.N = In.Total
    Log("Skillpunkte: Mitspieler %s hat %d ausgegeben (Host-Kopie %d -> %d)%s", Coop.GuestIds[Key] or Key:match("[^%.]+$") or Key,
        Delta, Have, Have - Take, Take < Delta and " - mehr als vorhanden gemeldet, bei 0 gekappt" or "")
end

-- Mitspieler, Hook TechTreeComponent_C:PayCost (nur beim Technik-Kauf): Kosten merken; gesendet wird in V.SpendTick
-- (kein RPC im Hook)
function V.OnPayCost(Ctx, Cost)
    local N = math.floor(tonumber(Cost:get()) or 0)
    if N <= 0 or NetModeName(CurrentWorld()) ~= "Client" then return end
    local PC = LocalPC()
    local Own = IsAlive(PC) and PC.TechTreeComponent or nil
    if not (IsAlive(Own) and Ctx:get():GetAddress() == Own:GetAddress()) then return end
    V.SpendNonce = V.SpendNonce or string.format("%x%04x", os.time(), math.random(0, 0xffff))
    V.SpendSent, V.SpendResendAt = V.SpendSent + N, 0
    Log("Skillpunkte: %d ausgegeben, wird dem Host gemeldet (gesamt %d)", N, V.SpendSent)
end

-- Mitspieler (HandleClient, verbunden, HUD steht): Hook einmal registrieren, offene Summe sofort und alle 5 s erneut
function V.SpendTick(Now)
    if not V.SpendHooked and IsAlive(StaticFindObject(V.TT_CLASS)) then
        V.SpendHooked = true
        TryHook(V.TT_CLASS .. ":PayCost", V.OnPayCost)
    end
    if V.SpendNonce and V.SpendSent > V.SpendAck and Now >= (V.SpendResendAt or 0) then
        V.SpendResendAt = Now + 5
        Coop.SendChunked(Coop.SendToHost, "vitspend", V.SpendNonce .. "|" .. V.SpendSent)
    end
end

-- Host, lokaler Modus: Werte, die der Mitspieler aus seinem Spielstand mitbringt.
function V.OnGuestValues(Key, PC, Text)
    local Pawn = IsAlive(PC) and PC:K2_GetPawn() or nil
    if not SETTINGS.local_inventory or V.Ready[Key] or not IsAlive(Pawn) then return end
    Log("Werte des Mitspielers aus seinem Spielstand uebernommen (%d Felder)", V.Apply(Pawn, PC, Text))
    V.SetReady(Key, Pawn)
end

-- join_v2, Host: nach "ready" die Lebenswerte der Host-Kopie (werte.txt bzw. Startwerte) zweimal im Abstand von 2 s an
-- den Mitspieler schicken ("vitset"). Leben & Co. sind im Spiel nicht repliziert; vorher zeigte er bis zur naechsten
-- Aenderung (Bandage) den Wert seines eigenen Spielstands (60 statt 100). V.PushVitalsUI beim Abgleich kam zu frueh
-- (hinter dem Ladebildschirm, vor dem HUD). VitsetDue: [Controller-Key] = { os.clock-Zeitpunkte }
V.VitsetDue = {}
function V.QueueVitset(Key)
    if Coop.VitV2 and Coop.VitV2(Key) then return end   -- vit_v2: Host-Spiegel vit2 (ls_vit) ersetzt vitset
    local Now = os.clock()
    V.VitsetDue[Key] = { Now, Now + 2 }
    Coop.AddFast("vitset", V.VitsetTick)
end

function V.VitsetTick(Now)
    local Left = false
    for Key, Times in pairs(V.VitsetDue) do
        if Times[1] and Now >= Times[1] then
            table.remove(Times, 1)
            local E = Coop.Join[Key]
            local PC = type(E) == "table" and E.PC or nil
            local Pawn = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end) or nil
            if IsAlive(Pawn) then
                local Parts = {}
                for _, F in ipairs(V.VITALS) do
                    local Value = Safe(function() local C = V.Comp(Pawn, F[1]) return IsAlive(C) and C[F[2]] or nil end)
                    if type(Value) == "number" then Parts[#Parts + 1] = string.format("%s.%s=%.10g", F[1], F[2], Value) end
                end
                Coop.SendChunked(function(T) SendToClient(PC, T) end, "vitset", table.concat(Parts, ";"))
                V.PushVitalsUI(Pawn)
                if not Times[1] then Log("Lebenswerte an Mitspieler geschickt (%s)", table.concat(Parts, ";")) end
            end
        end
        if Times[1] then Left = true else V.VitsetDue[Key] = nil end
    end
    return not Left   -- nichts mehr offen: Aufgabe beenden
end

-- Mitspieler: Lebenswerte vom Host in die eigene Kopie schreiben und die Anzeige aktualisieren (nicht im Empfangs-Hook)
Coop.HostDataHandlers.vitset = function(Text)
    if Coop.VitV2 and Coop.VitV2() then return end   -- vit_v2: ls_vit spiegelt dauerhaft (ersetzt auch vitguard)
    ExecuteInGameThread(function()
        local PC = LocalPC()
        local Pawn = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end) or nil
        if not IsAlive(Pawn) then return end
        local Count = V.Apply(Pawn, PC, Text)
        V.PushVitalsUI(Pawn)
        Log("Lebenswerte vom Host gesetzt (%d Felder): Leben %s", Count,
            tostring(Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and math.floor(M.Health + 0.5) or "?" end, "?")))
        -- Das Spiel ueberschreibt sie kurz danach mit dem eigenen Spielstand (Log: 100, dann wieder 60): 10 s halten
        V.Guard = { Text = Text, Health = tonumber(Text:match("MedicalComponent%.Health=([^;]+)")), Until = os.clock() + 10 }
        Coop.AddFast("vitguard", V.GuardTick)
    end)
end

-- Mitspieler: nach "vitset" VITGUARD s lang 2x pro Sekunde pruefen, ob das Leben noch dem Host-Wert entspricht; wenn
-- nicht (das Spiel hat den eigenen Spielstand nachgeladen), die Host-Werte erneut setzen.
V.GuardN = 0
function V.GuardTick(Now)
    local G = V.Guard
    if not G or Now >= G.Until then V.Guard = nil return true end
    V.GuardN = V.GuardN + 1
    if V.GuardN % 5 ~= 0 or not G.Health then return end
    local PC = LocalPC()
    local Pawn = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end) or nil
    local Health = IsAlive(Pawn) and Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and M.Health or nil end) or nil
    if type(Health) == "number" and math.abs(Health - G.Health) > 0.5 then
        V.Apply(Pawn, PC, G.Text)
        V.PushVitalsUI(Pawn)
        Log("Lebenswerte: Spiel hatte das Leben auf %.0f gesetzt, Host-Wert %.0f wiederhergestellt", Health, G.Health)
    end
end

-- Mitspieler: gespiegelte Werte in die eigene Kopie schreiben und die Anzeige aktualisieren.
Coop.HostDataHandlers.vit = function(Text)
    local PC = LocalPC()
    if not IsAlive(PC) then return end
    local L = PC.LevellingComponent
    if not IsAlive(L) then return end
    local OldLevel = L.CurrentLevel
    local AckNonce, AckN = Text:match("Spend%.Ack=(%x+):(%d+)")
    Text = Text:gsub(";?Spend%.Ack=[^;]*", "")
    V.Apply(PC:K2_GetPawn(), PC, Text)
    -- Skillpunkte: noch nicht bestaetigte eigene Ausgaben vom Host-Wert abziehen (sonst Punkte zurueck, s. V.OnSpend)
    V.SpendAck = (AckNonce and AckNonce == V.SpendNonce) and tonumber(AckN) or 0
    local Open = V.SpendSent - V.SpendAck
    if Open > 0 then
        pcall(function()
            local TT = PC.TechTreeComponent
            if not IsAlive(TT) then return end
            local Host = math.floor(tonumber(TT.SkillPoints) or 0)
            TT.SkillPoints = math.max(0, Host - Open)
            if V.SpendLogged ~= Open then
                V.SpendLogged = Open
                Log("vit: Skillpunkte Host %d, %d eigene Ausgabe(n) noch unbestaetigt - Gast behaelt %d", Host, Open, math.max(0, Host - Open))
            end
        end)
    end
    if not V.Shown or L.CurrentLevel ~= OldLevel then pcall(function() L:UpdateLevelUI(L.CurrentLevel) end) end
    pcall(function() L:UpdateXPUI(L.CurrentXP, L.CurrentMaxXP) end)
    if not V.Shown then Log("Stufe/XP vom Host uebernommen: Stufe %d, XP %.0f", L.CurrentLevel, L.CurrentXP) end
    V.Shown = true
end

Coop.Stats = V
end

do
-- Inventar-Modus, vom Host per local_inventory festgelegt und an jeden Mitspieler geschickt:
--   "server" (Standard): Das Inventar des Mitspielers bleibt beim Host, pro Host-Spielstand und
--     Mitspieler-ID in <Spielstand>\NetTest_Guest_<ID>.sav. Erster Beitritt = Startausruestung, danach
--     das zuletzt gespeicherte. In den Spielstand des Mitspielers wird nichts geschrieben.
--   "local": Mitspieler bringt sein lokales Inventar mit und bekommt es zurueckgeschrieben (Valheim).
local G = { STORE_EVERY = 10, ModeSentAt = {}, StoreAt = {}, Restored = {}, RetryAt = {}, Synced = {},
            FIRST_MIN = 0.5, FIRST_MAX = 4,   -- inv_first_wait: erster Abgleich fruehestens/spaetestens nach s (G.ClientTick)
            Dead = {},   -- Dead: [Controller-Key] = Name der gestorbenen Figur (fuer sie nie mehr speichern)
            Dup = {} }   -- Dup: [Controller-Key] = Mitspieler-ID, die schon ein anderer Controller haelt (G.HandleHost)

-- Feste Mitspieler-ID (die PlayerId aendert sich bei jedem Beitritt). Einmal zufaellig erzeugt,
-- liegt ausserhalb des Spielordners und ueberlebt so eine Neuinstallation.
function G.OwnGuestId()
    if G.Id then return G.Id end
    -- Test-Mitspieler auf demselben PC (gleiches LOCALAPPDATA): eigene ID aus guest_id.txt im Mod-Ordner,
    -- sonst kaeme er als derselbe Spieler beim Server an
    local Override = io.open(MOD_DIR .. "guest_id.txt", "r")
    local Fixed = Override and Override:read("*l")
    if Override then Override:close() end
    if Fixed and Fixed:match("^%x+$") then G.Id = Fixed return Fixed end
    local Path = (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\NetTest_GuestId.txt"
    local File = io.open(Path, "r")
    local Id = File and File:read("*l")
    if File then File:close() end
    if not (Id and Id:match("^%x+$")) then
        math.randomseed(os.time() + math.floor(os.clock() * 1000000))
        Id = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
        File = io.open(Path, "w")
        if File then File:write(Id) File:close() end
    end
    G.Id = Id
    return Id
end

-- Nicht im Ordner des Host-Spielstands: jeder Quicksave legt einen neuen Ordner an.
function G.GuestSlot(GuestId)
    return "NetTest_Guests/" .. GuestId
end

-- Server-Inventar aus der Datei direkt in die Inventar-Komponente kopieren (Objekt-zu-Objekt-Kopien
-- behalten alle Gegenstaende).
function G.LoadInto(Inventory, GuestId)
    local GS = UEHelpers.GetGameplayStatics()
    local Slot = G.GuestSlot(GuestId)
    if not GS:DoesSaveGameExist(Slot, 0) then
        Log("Mitspieler %s ist neu: Startausruestung", GuestId)
        return
    end
    local Loaded = GS:LoadGameFromSlot(Slot, 0)
    if not IsAlive(Loaded) or #Loaded.MainJigContainers == 0 then
        Log("Gespeichertes Inventar von Mitspieler %s unbrauchbar: Startausruestung", GuestId)
        return
    end
    Inventory.MainJigContainers = Loaded.MainJigContainers
    Inventory.MainContainersIDs = Loaded.MainUIDs
    Inventory.InventoryWeight = Loaded.Weights
    Log("Inventar von Mitspieler %s aus %s geladen (%d Container)", GuestId, Slot, #Loaded.MainJigContainers)
end

-- Host (SpawnPawnFor, vor dem Spawn): kommt dieser Mitspieler mit brauchbarem gespeichertem Server-Inventar zurueck?
-- Gleiches Kriterium wie G.LoadInto. false = wie bisher mit Startausruestung (neu, nach Tod geloescht, Notfall-Respawn).
function Coop.ReturningGuest(PC)
    local Core = Coop.Modules and Coop.Modules.ls_core
    if Core and Core.Flag and Core.Flag("join_nokit", true) ~= true then return false end
    if SETTINGS.local_inventory or not IsAlive(PC) then return false end
    local Key = PC:GetFullName()
    if G.Restored[Key] then return false end   -- neue Figur derselben Verbindung (Notfall-Respawn): Startausruestung wie im Spiel
    local Id = (Coop.HelloIds and Coop.HelloIds[Key]) or Coop.GuestIds[Key]
    if type(Id) ~= "string" or not Id:match("^%x+$") then return false end   -- ohne hello: wie bisher
    -- Doppel-Login (wie G.HandleHost Holders): nur noch VERBUNDENE Controller zaehlen. Der Key einer frueheren,
    -- getrennten Verbindung behaelt ohne join_v2 G.Restored (kein Join.Forget) - sonst kaeme jedes Wiederkommen
    -- mit Startausruestung, waehrend G.HandleHost die neue Verbindung trotzdem als Halter laedt.
    local Live = nil
    for K, Other in pairs(Coop.GuestIds) do
        if K ~= Key and Other == Id and G.Restored[K] then
            if not Live then
                Live = {}
                for _, PS in ipairs(PlayerStates(CurrentWorld())) do
                    local LK = Safe(function() local P = PS:GetOwner() return IsAlive(P) and P:GetFullName() or nil end)
                    if LK then Live[LK] = true end
                end
            end
            if Live[K] then return false end
        end
    end
    local GS, Slot = UEHelpers.GetGameplayStatics(), G.GuestSlot(Id)
    if not GS:DoesSaveGameExist(Slot, 0) then return false end
    local Loaded = GS:LoadGameFromSlot(Slot, 0)
    return IsAlive(Loaded) and #Loaded.MainJigContainers > 0
end

-- Abgleich: Das Inventar-UI des Mitspielers enthaelt nach jedem Spawn eine lokal gewuerfelte
-- Startausruestung, die der Host nicht kennt (darum gingen Messer und Rags nicht). Der Mitspieler leert
-- sein UI und fragt an; der Host schickt dann seinen Stand ueber den Plugin-RPC (der verschickt
-- CLIENT_ContainerDataResponse und legt die Ausruestung neu an). Mit vollem UI beim Mitspieler
-- loescht dessen UI die Gegenstaende beim Host wieder (SERVER_RequestRemoveItem).
function G.Sync(Key, PC, Pawn, Mode, GuestId)
    local Inventory = Pawn.BP_JigMultiplayer
    if not IsAlive(Inventory) then error("keine Inventar-Komponente") end
    -- cloth_fast: Der Abgleich legt die Kleidung neu an; 3 s keine Kleidungs-Nachsendung (Coop.ClothFast.Quiet)
    if SETTINGS.cloth_fast then Coop.ClothFast.Quiet = os.clock() + 3 end
    local First = not G.Restored[Key]   -- erster Abgleich (Beitritt): Actionbar leer wie bisher, siehe unten
    if Mode == "server" and not G.Restored[Key] then
        G.LoadInto(Inventory, GuestId)
        G.Restored[Key] = true
        local ok, err = pcall(Coop.Stats.Restore, Key, Pawn, PC, GuestId)
        if not ok then Log("Werte von Mitspieler %s: Laden fehlgeschlagen (%s)", GuestId, tostring(err)) end
    end
    -- Runde 3: Actionbar nicht mehr immer leer (Neuabgleich verlor das GPS). Quelle siehe G.Actionbar; im Log stehen
    -- Quelle, Anzahl und das GPS laut Server vor/direkt nach dem Abgleich. Nur beim Neuabgleich: der erste Abgleich
    -- (Beitritt, auch lokaler Modus) bleibt unveraendert mit leerer Actionbar.
    local Bar, From, N
    if First then
        Bar, N = G.Actionbar(nil, nil), 0
        From = "erster Abgleich, leer wie bisher"
    else
        Bar, From, N = G.Actionbar(Inventory, GuestId)
    end
    local GpsBefore = G.HasGps(Pawn)
    Inventory:SERVER_LoadSaveDataFromClientSide(Inventory.MainJigContainers, Inventory.MainContainersIDs,
        Inventory.InventoryWeight, Bar)
    Log("Abgleich %s: Actionbar %d UIDs (%s), GPS vorher %s, direkt danach %s", tostring(GuestId), N, From,
        tostring(GpsBefore), tostring(G.HasGps(Pawn)))
    -- inv_join_guard (ls_inv): geladenen Stand merken; fehlt davon etwas, bevor der Gast handeln kann, hat sein UI es
    -- per SERVER_RequestRemoveItem geloescht -> diese Figur wird nicht mehr gespeichert
    if First and Mode == "server" then
        local InvMod = Coop.Modules and Coop.Modules.ls_inv
        if InvMod and InvMod.JoinBaseline then
            local okB, errB = pcall(InvMod.JoinBaseline, Key, Pawn)
            if not okB then Log("Beitritts-Schutz fehlgeschlagen: %s", tostring(errB)) end
        end
    end
end

-- GPS laut Server (wie Coop.Map.HostTick); nil = nicht lesbar
function G.HasGps(Pawn)
    return Safe(function()
        local Out = {}
        Pawn["IsGPSEquipped?"](Pawn, Out)
        return Out["GPS?"] == true
    end)
end

-- Anzahl Gegenstaende im Inventar-UI der Figur (LocalJSIContainers, wie ls_inv I.LootItems); nil = UI noch nicht da
function G.UiItems(Pawn)
    return Safe(function()
        local Jig = Pawn.BP_JigMultiplayer
        if not IsAlive(Jig) then return nil end
        local N, Any = 0, false
        Jig.LocalJSIContainers:ForEach(function(_, E)
            local J = E:get()
            if IsAlive(J) then Any, N = true, N + J.ArrayOfItems:GetArrayNum() end
        end)
        return Any and N or nil
    end)
end
function G.FirstWaitOn()
    local Core = Coop.Modules and Coop.Modules.ls_core
    return not (Core and Core.Flag) or Core.Flag("inv_first_wait", true) == true
end

-- Actionbar-UIDs fuer SERVER_LoadSaveDataFromClientSide: 1. eine Liste der Inventar-Komponente selbst (falls es sie
-- gibt), 2. die im gespeicherten Save_Player des Gasts (G.GuestSlot), 3. leer wie bisher. Nur nicht leere Listen
-- zaehlen. Achtung: BuildGuestSave legt keine Actionbar ab (beim Host gibt es keine), 2. ist darum meist leer.
-- Rueckgabe: TArray, Quelle (Text), Anzahl. Arrays nur weiterreichen, nie einer Eigenschaft zuweisen.
function G.Actionbar(Inventory, GuestId)
    local function Num(Arr) return tonumber(Safe(function() return Arr:GetArrayNum() end)) or 0 end
    local Own = Inventory and Safe(function() return Inventory.ActionbarUIDs end)
    if type(Own) == "userdata" and Num(Own) > 0 then return Own, "Inventar-Komponente", Num(Own) end
    if GuestId then
        local GS, Slot = UEHelpers.GetGameplayStatics(), G.GuestSlot(GuestId)
        local Loaded = Safe(function() return GS:DoesSaveGameExist(Slot, 0) and GS:LoadGameFromSlot(Slot, 0) or nil end)
        local Saved = IsAlive(Loaded) and Safe(function() return Loaded.ActionbarUIDs end)
        if type(Saved) == "userdata" and Num(Saved) > 0 then return Saved, "gespeicherter Save_Player", Num(Saved) end
    end
    -- CORE-20: Klasse/GameInstance pruefen
    local SaveClass, GI = StaticFindObject("/Game/Blueprints/Saves/Save_Player.Save_Player_C"), UEHelpers.GetGameInstance()
    if not (IsAlive(SaveClass) and IsAlive(GI)) then error("Save_Player-Klasse oder GameInstance fehlt") end
    local Empty = StaticConstructObject(SaveClass, GI)
    if not IsAlive(Empty) then error("leerer Save_Player nicht erzeugt") end
    return Empty.ActionbarUIDs, "leer, keine Quelle", 0
end

function G.Store(Pawn, Slot, GuestId)
    -- CORE-10 (srv_store_freeze, server.lua stop): nach dem Einfrieren des Spielstands keine Gast-Slots mehr schreiben
    -- (sonst waere der .sav neuer als die gespeicherte Welt)
    if Coop.GuestStoreFrozen then
        if not G.FrozenLogged then G.FrozenLogged = true Log("Gast-Inventare eingefroren (Server stoppt): Sichern uebersprungen") end
        return
    end
    local InvMod = Coop.Modules and Coop.Modules.ls_inv
    if InvMod and InvMod.StoreOk then
        local okG, Allow = pcall(InvMod.StoreOk, Pawn)
        if okG and Allow == false then return end   -- Beitritts-Schutz: Spielstand bleibt (ls_inv loggt)
    end
    local Temp = Coop.BuildGuestSave(Pawn)
    if not Temp then return end
    local ok = UEHelpers.GetGameplayStatics():SaveGameToSlot(Temp, Slot, 0)
    if not ok then Log("Inventar von Mitspieler %s: Speichern beim Host fehlgeschlagen", GuestId) end
    if ok and not G.StoredOnce then
        G.StoredOnce = true
        Log("Inventar von Mitspieler %s wird beim Host gespeichert (%s)", GuestId, Slot)
    end
end

-- INV-24 (inv_store_dedup): speichert ls_inv diesen Gast selbst? Wie ls_inv I.HostFast: Modul geladen, inv_store und
-- inv_v2a/inv_v2b an, Gast mit v3-Handshake und bereit (G.Epoch/G.Ready). Dann ist G.Store alle 10 s doppelte Arbeit.
function G.InvStores(Key)
    if not Coop.FlagOn("inv_store_dedup", true) then return false end
    local InvMod, NetM = Coop.Modules and Coop.Modules.ls_inv, Coop.Net
    if not (InvMod and type(NetM) == "table" and type(NetM.Guests) == "table") then return false end
    if not (Coop.FlagOn("inv_store", true) and (Coop.FlagOn("inv_v2a", true) or Coop.FlagOn("inv_v2b", true))) then
        return false
    end
    local Peer = NetM.Guests[Key]
    return type(Peer) == "table" and Peer.Epoch ~= nil and Peer.Ready and true or false
end

-- Host: Modus verschicken, auf Anfrage abgleichen (beim Beitritt vorher aus der Datei laden),
-- im Server-Modus regelmaessig speichern.
function G.HandleHost(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Mode = SETTINGS.local_inventory and "local" or "server"
    local Now = os.time()
    local States = PlayerStates(World)
    -- Doppel-Login (kopierte ID-Datei): dieselbe Mitspieler-ID an zwei verbundenen Controllern. Es gilt der schon
    -- abgeglichene (sonst der erste); der andere bekommt kein gespeichertes Inventar, fuer ihn wird nichts gespeichert
    -- und sein Tod loescht nichts (G.Dup). [ID] = Controller-Key
    local Holders = {}
    for _, PS in ipairs(States) do
        local K = Safe(function() local P = PS:GetOwner() return IsAlive(P) and P:GetFullName() or nil end)
        local Id = K and Coop.GuestIds[K]
        if Id and G.Restored[K] and not Holders[Id] then Holders[Id] = K end
    end
    for _, PS in ipairs(States) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            if Now >= (G.ModeSentAt[Key] or 0) then
                G.ModeSentAt[Key] = Now + 30
                Coop.SendChunked(function(T) SendToClient(PC, T) end, "mode", Mode)
            end
            local GuestId, Pawn, Wanted = Coop.GuestIds[Key], PC:K2_GetPawn(), Coop.SyncRequest[Key]
            if GuestId and Holders[GuestId] and Holders[GuestId] ~= Key then
                if G.Dup[Key] ~= GuestId then
                    Log("Mitspieler-ID %s ist schon verbunden - zweite Verbindung (%s) ohne gespeichertes Inventar", GuestId, Key:match("[^%.]+$") or Key)
                end
                G.Dup[Key], GuestId = GuestId, nil
            elseif GuestId then
                Holders[GuestId], G.Dup[Key] = Key, nil
            end
            -- Nur lebende Figuren (die Leiche hat keinen PlayerState)
            if IsAlive(Pawn) and IsAlive(Pawn.PlayerState) then
                -- join_v2: bis "ready" kein Einfrieren/Freigeben ueber die Lebenszeichen (Laden stockt sie), das macht Coop.Join
                if Coop.Join.IsReady(Key) then
                    local okLink, errLink = pcall(Coop.Link.HostTick, Key, Pawn, Now)
                    if not okLink and not Coop.Link.ErrLogged then Coop.Link.ErrLogged = true Log("Verbindungs-Schutz-Fehler: %s", tostring(errLink)) end
                end
                local okVal, errVal = pcall(Coop.Stats.HostTick, Key, PC, Pawn, Now)
                if not okVal then Log("Werte-Fehler: %s", tostring(errVal)) end
                local okGps, errGps = pcall(Coop.Map.HostTick, Key, PC, Pawn, Now)
                if not okGps then Log("GPS-Fehler: %s", tostring(errGps)) end
                local okMed, errMed = pcall(Coop.Medic.HostTick, Pawn)
                if not okMed and not Coop.Medic.ErrLogged then
                    Coop.Medic.ErrLogged = true
                    Log("Blutungs-Stopp-Fehler: %s", tostring(errMed))
                end
            end
            if GuestId and IsAlive(Pawn) and IsAlive(Pawn.PlayerState) then
                if Wanted and G.Synced[Key] ~= Wanted then
                    -- Bei einem Fehler nicht speichern (sonst ueberschreibt die Startausruestung die
                    -- Datei), sondern in 5 s neu versuchen.
                    -- inv_v2a (ls_inv): nach dem ersten Abgleich der Verbindung kein LSD mehr (baut alle Ausruestungs-
                    -- Actors neu: Flackern, neue Waffen-UID). Respawn holt der Gast per SERVER_RequestData.
                    local InvMod = Coop.Modules and Coop.Modules.ls_inv
                    if G.Synced[Key] and InvMod and InvMod.SkipResync and InvMod.SkipResync(Key) then
                        G.Synced[Key] = Wanted
                        -- Neue Figur per guestid kommt nur, wenn ClientRespawn beim Gast scheiterte: sein UI ist schon
                        -- geleert -> Server-Stand schicken (SERVER_RequestData am Server = CLIENT_ContainerDataResponse
                        -- an den besitzenden Gast, wie ls_inv HostPrime)
                        local okReq, errReq = pcall(function()
                            local Inv = Pawn.BP_JigMultiplayer
                            if not IsAlive(Inv) then error("kein BP_JigMultiplayer") end
                            Inv:SERVER_RequestData(Inv)
                        end)
                        Log("Abgleich %s: Gast hat UI geleert - Server-Stand per SERVER_RequestData %s", GuestId,
                            okReq and "geschickt" or ("fehlgeschlagen (" .. tostring(errReq) .. ")"))
                        if SETTINGS.join_v2 then pcall(Coop.Join.OnSynced, Key, PC) end
                    elseif Now >= (G.RetryAt[Key] or 0) then
                        -- PLAYER-13 (pvp_logout): alte, noch stehende Figur desselben Mitspielers zuerst sichern
                        if not G.Restored[Key] and Coop.Logout and next(Coop.Logout) then
                            local okR, errR = pcall(Coop.LogoutResolve, Key, GuestId)
                            if not okR then Coop.FlagFail("pvp_logout", errR) end
                        end
                        local ok, err = pcall(G.Sync, Key, PC, Pawn, Mode, GuestId)
                        if ok then
                            G.Synced[Key], G.StoreAt[Key] = Wanted, Now + G.STORE_EVERY
                            Log("Inventar mit Mitspieler %s abgeglichen (%s)", GuestId, Wanted)
                            -- join_v2: dem Mitspieler "synced" melden (Teil seiner ready-Bedingung)
                            if SETTINGS.join_v2 then pcall(Coop.Join.OnSynced, Key, PC) end
                        else
                            G.RetryAt[Key] = Now + 5
                            Log("Inventar von Mitspieler %s: Abgleich fehlgeschlagen (%s)", GuestId, tostring(err))
                        end
                    end
                elseif Mode == "server" and G.Restored[Key] and Now >= (G.StoreAt[Key] or math.huge)
                    and G.Dead[Key] ~= Pawn:GetFName():ToString()
                    and Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and M.Health > 0 end, false) then
                    G.StoreAt[Key] = Now + G.STORE_EVERY
                    -- INV-24 (inv_store_dedup): ls_inv speichert diesen Gast schon selbst (Ledger-Signatur-Store) -> nur die Werte
                    local okS, Skip = pcall(G.InvStores, Key)
                    if not okS then Coop.FlagFail("inv_store_dedup", Skip) end
                    if not (okS and Skip) then
                        local okG, errG = pcall(G.Store, Pawn, G.GuestSlot(GuestId), GuestId)
                        if not okG then Log("Inventar von Mitspieler %s: Speichern fehlgeschlagen (%s)", GuestId, tostring(errG)) end
                    end
                    local okVal, errVal = pcall(Coop.Stats.Store, Pawn, PC, GuestId)
                    if not okVal then Log("Werte von Mitspieler %s: Speichern fehlgeschlagen (%s)", GuestId, tostring(errVal)) end
                end
            end
        end
    end
end

-- Mitspieler: Sobald das HUD steht und der Modus bekannt ist, pro Figur das UI leeren und dann im
-- lokalen Modus (nur erste Figur) das eigene Inventar hochladen, sonst beim Host den Abgleich
-- anfragen (10 s spaeter noch einmal, falls die Nachricht verloren ging; der Host gleicht pro Figur
-- nur einmal ab).
function G.ClientTick(Pawn)
    local Mode = Coop.InventoryMode
    if not Mode then return end
    if G.ResyncAt and os.clock() >= G.ResyncAt then
        G.ResyncAt, G.SyncFor = nil, nil
        Log("Inventar wird mit dem Server neu abgeglichen")
    end
    local Name, Now = Pawn:GetFName():ToString(), os.time()
    if G.SyncFor ~= Name and Mode == "server" and (G.SyncSeq or 0) >= 1 and Coop.Modules and Coop.Modules.ls_inv
        and Coop.Modules.ls_inv.ClientRespawn(Pawn) then
        G.SyncFor, G.SyncRepeatAt = Name, nil   -- inv_v2a: Respawn per SERVER_RequestData (UI leeren + Server-Stand)
    elseif G.SyncFor ~= Name then
        -- inv_first_wait: erster Abgleich der Verbindung erst, wenn die Antwort auf das native SERVER_RequestData
        -- (BeginPlay, UE 5.6 @242e / 5.3 @23a7) im UI ist - kommt sie nach dem Leeren, scheitert die LSD-Antwort an
        -- belegten Plaetzen (BuildDataToContainer @0479 -> Verlust beim Host). Wie Event_LoadPlayer (UE 5.6
        -- @366b/@368f, 5.3 @42ae/@42d2: ClearJSIItems/ClearContainers erst nach 1,2 s).
        if (G.SyncSeq or 0) == 0 and G.FirstWaitOn() then
            local Clock = os.clock()
            if G.FirstName ~= Name then G.FirstName, G.FirstAt = Name, Clock end
            local Waited, Items = Clock - G.FirstAt, G.UiItems(Pawn) or 0
            if not ((Items > 0 and Waited >= G.FIRST_MIN) or Waited >= G.FIRST_MAX) then return end
            Log("Erster Inventar-Abgleich nach %.1f s: %s - UI wird geleert", Waited,
                Items > 0 and string.format("native Antwort da (%d Gegenstaende)", Items) or "keine Gegenstaende im UI (Frist abgelaufen)")
        end
        G.SyncFor, G.SyncRepeatAt, G.SyncSeq = Name, Now + 10, (G.SyncSeq or 0) + 1
        pcall(function() local Inv = Pawn.BP_JigMultiplayer if IsAlive(Inv) then Inv:ClearJSIItems() end end)
        pcall(function() local UI = Pawn.InGameUI if IsAlive(UI) then UI:ClearContainers() end end)
        -- Lokaler Modus: beim ersten Mal die Werte aus dem eigenen Spielstand mitbringen
        if Mode == "local" and G.SyncSeq == 1 then
            local ok, Text = pcall(Coop.Stats.Collect, Pawn, LocalPC(), true)
            if ok then Coop.SendChunked(Coop.SendToHost, "vit", Text) end
        end
        if Mode == "local" and Coop.UploadOwnInventory(Pawn) then
            G.SyncRepeatAt = nil
            return
        end
        Coop.SendChunked(Coop.SendToHost, "guestid", G.OwnGuestId() .. "#" .. G.SyncSeq)
    elseif G.SyncRepeatAt and Now >= G.SyncRepeatAt then
        G.SyncRepeatAt = nil
        Coop.SendChunked(Coop.SendToHost, "guestid", G.OwnGuestId() .. "#" .. G.SyncSeq)
    end
end

-- Host hat dem Inventar etwas hinzugefuegt (Admin-Cheat-Menue, server.lua "give"): Das UI kennt nur die
-- Meldung, nicht den Gegenstand (blinkt, nicht nehmbar). Wie beim Beitritt neu abgleichen.
-- Gesammelt: erst 2 s nach dem letzten "invsync" (mehrere Gegenstaende hintereinander = ein Abgleich statt
-- jedes Mal Inventar leeren und neu fuellen - das liess Sachen kurz verschwinden und wieder auftauchen)
Coop.HostDataHandlers.invsync = function()
    local InvMod = Coop.Modules and Coop.Modules.ls_inv
    if InvMod and InvMod.Active() then return end   -- inv_v2b: Host-Items kommen per CLIENT_AddNewItem
    G.ResyncAt = os.clock() + 2
end

Coop.HostDataHandlers.mode = function(Mode)
    if Coop.InventoryMode ~= Mode then
        Coop.InventoryMode = Mode
        Log("Inventar-Modus des Hosts: %s", Mode == "local" and "lokales Inventar" or "Server-Inventar")
    end
end

-- Host: Mitspieler gestorben. Das Spiel legt sein Inventar in die Leichen-Kiste, die Datei beim Host
-- hat aber noch den Stand von vor dem Tod. Trennt er sofort, bekaeme er beim naechsten Beitritt alles
-- zurueck (Duplikat). Darum die gespeicherte Ausruestung sofort loeschen und fuer diese Figur nichts
-- mehr speichern; Stufe/XP bleiben (V.Store speichert ohnehin nie mit 0 Leben).
-- inv_keepinv: behaelt das Spiel beim Tod das Inventar? (Server-Regeln Difficulty.KeepInventory=1 und
-- Difficulty.LoseAllItemsOnDeath=0, gelesen wie die BPs ueber ConsoleUtils; unlesbar = nein, wie bisher)
function G.KeepOnDeath()
    if not Coop.FlagOn("inv_keepinv", true) then return false end
    local CU = StaticFindObject("/Script/AutoSettings.Default__ConsoleUtils")
    if not IsAlive(CU) then return false end
    return Safe(function() return CU:GetBoolCVar(FName("Difficulty.KeepInventory")) end, false) == true
        and Safe(function() return CU:GetBoolCVar(FName("Difficulty.LoseAllItemsOnDeath")) end, true) ~= true
end

-- HintPC: Controller aus dem Tod-Hook (Coop.DeathFast), nach UnPossess sonst nicht mehr ueber die Figur zu finden.
function G.OnPawnDeath(Pawn, HintPC)
    if not IsAlive(Pawn) or NetModeName(CurrentWorld()) ~= "ListenServer" then return end
    if IsAlive(HintPC) then
        if Safe(function() return HintPC:IsLocalController() end, true) then return end
    elseif Pawn:IsLocallyControlled() then
        return
    end
    local Name, PC = Pawn:GetFName():ToString(), IsAlive(HintPC) and HintPC or nil
    for _, PS in ipairs(PC and {} or PlayerStates(CurrentWorld())) do
        local Owner = PS:GetOwner()
        local Own = IsAlive(Owner) and Safe(function() return Owner:K2_GetPawn() end)
        if IsAlive(Own) and Own:GetAddress() == Pawn:GetAddress() then PC = Owner break end
    end
    PC = PC or Safe(function() return IsAlive(Pawn.Controller) and Pawn.Controller or nil end)
    if not IsAlive(PC) then
        -- PLAYER-13 (pvp_logout): Figur eines im Kampf getrennten Gasts hat keinen Controller mehr
        if Coop.Logout and next(Coop.Logout) then
            local okL, errL = pcall(Coop.LogoutDeath, Pawn, Name)
            if not okL then Coop.FlagFail("pvp_logout", errL) end
        end
        return
    end
    local Key = PC:GetFullName()
    if G.Dead[Key] == Name then return end
    G.Dead[Key], G.StoreAt[Key] = Name, nil
    Coop.CancelSaveBack(Key)
    local GuestId = Coop.GuestIds[Key]
    if GuestId and G.Dup[Key] then
        Log("Mitspieler %s (Doppel-Login) gestorben: gespeicherte Ausruestung bleibt", tostring(GuestId))
        return
    end
    -- death_xp (PLAYER-5): Client_Died (NetClient) fuehrt XPDeath nur beim Gast aus (BP_PlayerController_C @1be0:
    -- Stufe -1, XP 0) -> Host-Kopie nachziehen, sonst springt die Stufe mit dem naechsten Abgleich zurueck. Vor dem
    -- Speichern der Werte (StoreProgressOnly unten).
    if Coop.FlagOn("death_xp", true) then
        local okXp, errXp = pcall(function()
            local Lv = PC.LevellingComponent
            if IsAlive(Lv) then Lv:XPDeath() end
        end)
        if not okXp then Coop.FlagFail("death_xp", errXp) end
    end
    -- inv_keepinv (INV-9/PLAYER-1): Difficulty.KeepInventory ohne LoseAllItemsOnDeath -> das Spiel behaelt das Inventar
    -- (SpawnDeadPlayerLoot @0034-@013f -> PC.KeepInventory, keine Todes-Kiste). Gespeicherte Ausruestung dann NICHT
    -- verwerfen, sondern mit dem Stand der toten Figur sichern (Trennen/Neustart auf dem Todesbildschirm: sonst alles weg).
    -- G.Dead bleibt gesetzt (keine weiteren Sicherungen der Leiche); nach dem Respawn speichert die neue Figur normal.
    if GuestId and not SETTINGS.local_inventory and G.KeepOnDeath() then
        local okK, errK = pcall(G.Store, Pawn, G.GuestSlot(GuestId), GuestId)
        if not okK then Coop.FlagFail("inv_keepinv", errK) end
        local okP, errP = pcall(Coop.Stats.StoreProgressOnly, PC, GuestId)
        if not okP then Log("Werte nach dem Tod: %s", tostring(errP)) end
        Log("Mitspieler %s gestorben (KeepInventory): Ausruestung %s", tostring(GuestId), okK and "behalten" or ("NICHT gesichert: " .. tostring(errK)))
        return
    end
    if GuestId and not SETTINGS.local_inventory then
        local GS = UEHelpers.GetGameplayStatics()
        local Slot = G.GuestSlot(GuestId)
        if GS:DoesSaveGameExist(Slot, 0) then GS:DeleteGameInSlot(Slot, 0) end
        local ok, err = pcall(Coop.Stats.StoreProgressOnly, PC, GuestId)
        if not ok then Log("Werte nach dem Tod: %s", tostring(err)) end
    end
    Log("Mitspieler %s gestorben: gespeicherte Ausruestung verworfen", tostring(GuestId))
end

-- join_v2: Modus gleich beim hello schicken (der Mitspieler braucht ihn fuer guestid#seq), nicht erst im 30-s-Takt
Coop.SendMode = function(PC)
    G.ModeSentAt[PC:GetFullName()] = os.time() + 30
    Coop.SendChunked(function(T) SendToClient(PC, T) end, "mode", SETTINGS.local_inventory and "local" or "server")
end
-- join_v2: Mitspieler getrennt -> beim Wiederkommen Inventar und Werte neu laden und abgleichen
Coop.ForgetGuestSync = function(Key)
    G.Restored[Key], G.Synced[Key], G.ModeSentAt[Key], G.RetryAt[Key] = nil, nil, nil, nil
end

Coop.OnGuestDeath, Coop.GuestInv = G.OnPawnDeath, G   -- GuestInv: Runde-5-API (A.G)
Coop.GuestDup = G.Dup   -- fuer ls_inv/ls_net/ls_player: [Controller-Key] gesetzt = Doppel-Login, nichts laden/speichern
Coop.OwnGuestId = G.OwnGuestId   -- Serverliste: eigene ID anzeigen
Coop.HandleGuestInventory, Coop.ClientInventoryTick = G.HandleHost, G.ClientTick
Coop.ResetGuestId = function()
    G.SyncFor, G.SyncRepeatAt, G.SyncSeq, Coop.Stats.Shown = nil, nil, nil, nil
    G.FirstName, G.FirstAt = nil, nil   -- inv_first_wait: neue Verbindung wartet wieder auf die native Antwort
    -- Skillpunkt-Meldungen: neue Verbindung = neue Sitzung (Host zaehlt je Sitzungs-Kennung ab 0)
    Coop.Stats.SpendNonce, Coop.Stats.SpendSent, Coop.Stats.SpendAck, Coop.Stats.SpendLogged = nil, 0, 0, nil
end
-- Mitspieler getrennt (HandleRemotePlayers, Figur lebt noch): einmal Inventar und Werte sichern, gleiche Regeln wie
-- die regelmaessige Sicherung (Server-Modus, abgeglichen, nicht tot, Leben > 0). ls_inv kann mit StoreLeaving
-- uebernehmen (dort auch leeres Inventar); sonst G.Store.
Coop.StoreLeaving = function(Key, Pawn)
    if SETTINGS.local_inventory or not IsAlive(Pawn) then return end
    -- CORE-10: Server stoppt (Coop.GuestStoreFrozen, server.lua): der Stand von vor dem Einfrieren gilt
    if Coop.GuestStoreFrozen then
        if not G.FrozenLogged then G.FrozenLogged = true Log("Gast-Inventare eingefroren (Server stoppt): Sichern uebersprungen") end
        return
    end
    local GuestId = Coop.GuestIds[Key]
    if not GuestId or not G.Restored[Key] or G.Dup[Key] or G.Dead[Key] == Pawn:GetFName():ToString() then return end
    if not ((tonumber(Safe(function() local M = Pawn.MedicalComponent return IsAlive(M) and M.Health or nil end)) or 0) > 0) then return end
    local InvMod = Coop.Modules and Coop.Modules.ls_inv
    if InvMod and InvMod.StoreLeaving then
        InvMod.StoreLeaving(Key, Pawn)
    else
        G.Store(Pawn, G.GuestSlot(GuestId), GuestId)
    end
    local PC = Safe(function() return Pawn.Controller end)
    if IsAlive(PC) then pcall(Coop.Stats.ApplySpend, Key, PC) end   -- gemeldete Skillpunkt-Ausgaben vor dem Speichern
    if IsAlive(PC) then pcall(Coop.Stats.Store, Pawn, PC, GuestId) end
    G.StoreAt[Key] = nil
    Log("Mitspieler %s getrennt: Inventar%s gesichert", tostring(GuestId), IsAlive(PC) and " und Werte" or "")
end

-- Server stoppt/speichert: alle Mitspieler im naechsten Durchlauf sichern
Coop.StoreGuestsNow = function()
    for Key in pairs(G.StoreAt) do G.StoreAt[Key] = 0 end
    local InvMod = Coop.Modules and Coop.Modules.ls_inv
    if InvMod then pcall(InvMod.StoreAll) end   -- inv_store: sofort, nicht erst im naechsten 1-s-Durchlauf
end

-- PLAYER-13 (pvp_logout): Tod der stehengebliebenen Figur eines getrennten Gasts (G.OnPawnDeath ohne Controller).
-- Wie G.OnPawnDeath: gespeicherte Ausruestung verwerfen (liegt in der Todes-Kiste) bzw. mit KeepInventory sichern.
-- Werte/XP brauchen den Controller und bleiben auf dem letzten Stand.
function Coop.LogoutDeath(Pawn, Name)
    local Addr = Pawn:GetAddress()
    for Key, E in pairs(Coop.Logout or {}) do
        if E.Name == Name and E.Addr == Addr and not E.Done then
            if G.Dead[Key] == Name then return end
            G.Dead[Key], G.StoreAt[Key] = Name, nil
            Coop.CancelSaveBack(Key)
            local GuestId = E.GuestId
            if not GuestId or G.Dup[Key] or SETTINGS.local_inventory then return end
            if G.KeepOnDeath() then
                local okK, errK = pcall(G.Store, Pawn, G.GuestSlot(GuestId), GuestId)
                Log("Mitspieler %s (getrennt, im Kampf) gestorben (KeepInventory): Ausruestung %s", tostring(GuestId),
                    okK and "behalten" or ("NICHT gesichert: " .. tostring(errK)))
                return
            end
            local GS = UEHelpers.GetGameplayStatics()
            local Slot = G.GuestSlot(GuestId)
            if GS:DoesSaveGameExist(Slot, 0) then GS:DeleteGameInSlot(Slot, 0) end
            Log("Mitspieler %s (getrennt, im Kampf) gestorben: gespeicherte Ausruestung verworfen", tostring(GuestId))
            return
        end
    end
end

-- CORE-30 (leave_forget): Verbindung weg (Coop.LeaveKey, nach StoreLeaving und Join.Forget). Alle main.lua-Tabellen mit
-- diesem Controller-Key vergessen; Daten je Mitspieler-ID (Spielstaende, Werte, Bans, Clans) bleiben. Dazu einmal je
-- Trennen die Merker nach Figurennamen (jeder Respawn = neuer Name) gegen die lebenden Figuren/Controller abgleichen.
function Coop.ForgetKey(Key)
    if not Coop.FlagOn("leave_forget", true) or type(Key) ~= "string" then return end
    local function Clear(T) if type(T) == "table" then T[Key] = nil end end
    Clear(Coop.GuestIds) Clear(Coop.SyncRequest) Clear(Coop.IdBind) Clear(Coop.SteamIds) Clear(Coop.TrustSkip)
    Clear(G.Dead) Clear(G.Dup) Clear(G.StoreAt)
    if Coop.ForgetSaveBack then Coop.ForgetSaveBack(Key) end   -- Zurueckschreib-Tabellen (lokal im Speicher-Block)
    if type(Coop.Link) == "table" then Clear(Coop.Link.Beat) Clear(Coop.Link.Frozen) end
    if type(Coop.Map) == "table" then Clear(Coop.Map.HostSent) end
    local V = Coop.Stats
    if type(V) == "table" then
        for _, Name in ipairs({ "Ready", "SentText", "CheckAt", "SpendIn", "SpendDone", "VitsetDue" }) do Clear(V[Name]) end
    end
    if Coop.ForgetGuestSync then Coop.ForgetGuestSync(Key) end
    if Coop.SkyForget then Coop.SkyForget(Key) end
    local PCName = Key:match("([^%.:]+)$")
    if PCName then LastSentStats[PCName], NoSaveMarked[PCName] = nil, nil end
    -- Figurennamen: lebende Figuren und verbundene Controller bleiben
    local Live = {}
    for _, P in ipairs(Coop.PlayerPawns()) do
        local N = Safe(function() return P:GetFName():ToString() end)
        if N then Live[N] = true end
    end
    for _, PS in ipairs(PlayerStates(CurrentWorld())) do
        local N = Safe(function() local O = PS:GetOwner() return IsAlive(O) and O:GetFName():ToString() or nil end)
        if N then Live[N] = true end
    end
    local Gone = 0
    for _, T in ipairs({ CapsuleFixed, NoSaveMarked }) do
        local Drop = {}
        for N in pairs(T) do if not Live[N] then Drop[#Drop + 1] = N end end
        for _, N in ipairs(Drop) do T[N] = nil end
        Gone = Gone + #Drop
    end
    local Due = Coop.Medic and Coop.Medic.Due
    if type(Due) == "table" and type(Coop.Medic.STOPS) == "table" then
        local Drop = {}
        for K in pairs(Due) do   -- Schluessel = Figurenname .. Zustand ("Bleed?", "HeavyBleed?": laengste Endung zaehlt)
            local Owner, Best = nil, 0
            for _, S in ipairs(Coop.Medic.STOPS) do
                if #S[1] > Best and tostring(K):sub(-#S[1]) == S[1] then Owner, Best = tostring(K):sub(1, -#S[1] - 1), #S[1] end
            end
            if not (Owner and Live[Owner]) then Drop[#Drop + 1] = K end
        end
        for _, K in ipairs(Drop) do Due[K] = nil end
    end
    if Gone > 0 then Log("Aufraeumen nach dem Trennen: %d alte Figuren-Merker vergessen", Gone) end
end
end

do
-- Zombie-Leben: Nur der Host rechnet (DamageComponent.CurrentHealth). Beim Mitspieler zieht das Spiel
-- Treffer zusaetzlich an seiner Kopie ab, die dann frueher oder spaeter als der Host stirbt (eigene
-- Ragdoll mit Schwung, asynchron). Darum beim Mitspieler Schaden an Zombies auf 0 setzen (und das Leben
-- nach dem Treffer zuruecksetzen, falls das Spiel den Wert anders abzieht). Der Host schickt das Leben
-- der Zombies in der Naehe von Mitspielern; der Tod kommt ueber OnRep_IsDead? (Leichen oben).
local Z = { CLASS = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C", RANGE = 15000, MATCH = 300,
            FULL_EVERY = 5, MAX_ENTRIES = 150, Sent = {}, SentTo = {}, NEAR = 5000, FullAt = 0, Hooked = false, HostHp = {}, Before = {} }

local function ZombieHp(Char)
    return Safe(function() local DC = Char.DamageComponent return IsAlive(DC) and DC.CurrentHealth or nil end)
end

-- Host: geaenderte Werte jede Sekunde, alle FULL_EVERY s alle angeschlagenen (fuer neue Mitspieler).
-- ai_montage (ls_ai): Gast bekommt Montagen ueber ai2 (MonCheck)? Entscheidung Z.NoMon einmal beim ersten
-- Durchlauf (vor jedem Gast, ohne spaeteres FLAG_DOWN) gemerkt; je Gast dazu die Faehigkeit ai2 der Verbindung.
function Z.MonV2(Key)
    return Z.NoMon == true and Coop.Net ~= nil and Coop.Net.Has("ai2", Key) == true
end

function Z.HostTick(World)
    if NetModeName(World) ~= "ListenServer" then return end
    if Z.NoMon == nil then Z.NoMon = (Coop.AI2NoMonHook and Coop.AI2NoMonHook()) == true end
    local Guests, PCs, NeedMon, Seen, NowT = {}, {}, false, {}, os.time()
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            PCs[#PCs + 1] = PC
            local Pawn = PC:K2_GetPawn()
            if IsAlive(Pawn) then Guests[#Guests + 1] = Pawn:K2_GetActorLocation() end
            -- Gast ohne ai2 (nach 15 s Handshake-Zeit): braucht den alten Montage-Weg
            local Key = PC:GetFullName()
            Seen[Key] = (Z.MonSeen and Z.MonSeen[Key]) or NowT
            if NowT - Seen[Key] >= 15 and not Z.MonV2(Key) then NeedMon = true end
        end
    end
    Z.MonSeen = Seen
    -- hp_v2: getrennte Mitspieler vergessen, Id-Register jede Minute aufraeumen (auch ohne Figuren)
    if SETTINGS.hp_v2 then
        local okNet, errNet = pcall(Z.NetHostTick, PCs)
        if not okNet and not Z.NetErr then Z.NetErr = true Log("Id-Register-Fehler (Host): %s", tostring(errNet)) end
    end
    if #Guests == 0 then return end
    -- ai_montage (ls_ai): Montage per Polling statt Hook auf PlayAnimMontage (haeufige Funktion). Der alte Hook nur,
    -- solange ein Gast ihn braucht (ohne ai2 oder ai_montage beim Host aus); gesendet wird je Gast (Z.MonFast).
    -- Die Hooks merken nur Objekte/Werte in Z.MonQ, verschickt wird im Schnell-Loop.
    -- CORE-18: Die alten Hooks auf PlayAnimMontage/CreateProxyObjectForPlayMontage (jede Montage jeder Figur) gibt es
    -- nicht mehr; Gaeste ohne ai2 (alter Mod-Stand oder ai_montage aus) sehen KI-Angriffe dann ohne Animation.
    if not Z.MontageHooked and NeedMon then
        Z.MontageHooked = true
        Log("KI-Animationen: Gast ohne ai2 - alter Montage-Weg ist abgeschaltet (Hook auf jede Montage), keine Angriffs-Animationen fuer ihn")
    end
    Z.ZombieClass = Z.ZClass()
    if not IsAlive(Z.ZombieClass) then return end
    local okLook, errLook = pcall(Z.LookHost, PCs)
    if not okLook and not Z.LOOK.HostErr then Z.LOOK.HostErr = true Log("Zombie-Aussehen-Fehler (Host): %s", tostring(errLook)) end
    -- animal_v3 (ls_ai): Gaeste mit Cap anim3 bekommen Tier-HP/Tod ueber ai2, ahp/ahp2 nur fuer die anderen
    local APCs = PCs
    if Coop.AI2Anim then
        APCs = {}
        for _, PC in ipairs(PCs) do if not Coop.AI2Anim(PC:GetFullName()) then APCs[#APCs + 1] = PC end end
    end
    local okAnimal, errAnimal = true, nil
    if #APCs > 0 then okAnimal, errAnimal = pcall(Z.AnimalHost, APCs, Guests) end
    if not okAnimal and not Z.ANIMAL.HostErr then Z.ANIMAL.HostErr = true Log("Tier-Fehler (Host): %s", tostring(errAnimal)) end
end

-- Zombie-Leben 4x pro Sekunde (eigene Schleife im Spiel-Thread, nur Server): Der Lebensbalken beim Spieler folgte
-- sonst bis zu 1 s spaeter. Nur Aenderungen; alle FULL_EVERY s alle angeschlagenen (auch fuer neu erzeugte Kopien).
function Z.HpTick(World)
    if NetModeName(World) ~= "ListenServer" then return end
    -- Pro Spieler nur die Zombies in seiner Naehe: bis 50 m 4x pro Sekunde, bis 150 m 1x pro Sekunde, weiter weg
    -- nichts (verlaesst ein Zombie den Bereich, wird er beim Wiederkommen neu geschickt). Nur Aenderungen, alle
    -- FULL_EVERY s alle angeschlagenen.
    -- hp_v2: Gaeste mit hello 2 bekommen hp2 (Z.Hp2Tick), alle anderen wie bisher hp
    local Players, V2 = {}, {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Pawn = PC:K2_GetPawn()
            if IsAlive(Pawn) then
                local Key = PC:GetFullName()
                if Coop.AI2Owns and Coop.AI2Owns(Key) then
                    -- Runde 5: ls_ai schickt diesem Gast ai2 (HP, Standard-Max fuer den Balken)
                elseif SETTINGS.hp_v2 and Coop.GuestProto[Key] == 2 then
                    V2[#V2 + 1] = { PC = PC, L = Pawn:K2_GetActorLocation(), Key = Key }
                else
                    Z.SentTo[Key] = Z.SentTo[Key] or {}
                    Players[#Players + 1] = { PC = PC, L = Pawn:K2_GetActorLocation(), Sent = Z.SentTo[Key], Parts = {}, Key = Key }
                end
            end
        end
    end
    if #V2 > 0 then
        local ok2, err2 = pcall(Z.Hp2Tick, V2)
        if not ok2 and not Z.Hp2Err then Z.Hp2Err = true Log("Zombie-Leben-Fehler (Host, feste IDs): %s", tostring(err2)) end
    end
    if #Players == 0 then return end
    Z.ZombieClass = Z.ZClass()
    if not IsAlive(Z.ZombieClass) then return end
    Z.TickN = (Z.TickN or 0) + 1
    local Now = os.time()
    local Full = Now >= Z.FullAt
    if Full then Z.FullAt = Now + Z.FULL_EVERY end
    local Near2, Range2, FarTick, Seen = Z.NEAR * Z.NEAR, Z.RANGE * Z.RANGE, Z.TickN % 4 == 0, {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Char:IsA(Z.ZombieClass) and not Coop.IsDeadAI(Char) then
            local Hp = ZombieHp(Char)
            if Hp then
                local Name, L = Char:GetFName():ToString(), Char:K2_GetActorLocation()
                local Max = Safe(function() local DC = Char.DamageComponent return IsAlive(DC) and DC.MaxHealth or Hp end, Hp)
                Seen[Name] = true
                for _, P in ipairs(Players) do
                    local D2 = (L.X - P.L.X) ^ 2 + (L.Y - P.L.Y) ^ 2
                    if D2 >= Range2 then
                        P.Sent[Name] = nil
                    elseif (D2 < Near2 or FarTick or Full) and #P.Parts < Z.MAX_ENTRIES
                        and (Full and Hp < Max or math.abs(Hp - (P.Sent[Name] or Max)) > 0.05) then
                        P.Parts[#P.Parts + 1] = string.format("%.0f;%.0f;%.0f;%.2f", L.X, L.Y, L.Z, Hp)
                        P.Sent[Name] = Hp
                    end
                end
            end
        end
    end
    local Present = {}
    for _, P in ipairs(Players) do
        Present[P.Key] = true
        if Full then for Name in pairs(P.Sent) do if not Seen[Name] then P.Sent[Name] = nil end end end
        if #P.Parts > 0 then
            local PC = P.PC
            Coop.SendChunked(function(T) SendToClient(PC, T) end, "hp", table.concat(P.Parts, "|"))
        end
    end
    if Full then for Key in pairs(Z.SentTo) do if not Present[Key] then Z.SentTo[Key] = nil end end end
end
if os.getenv("LASTSIGNAL_SERVER") == "1" or os.getenv("NETTEST_SERVER") == "1" then
    LoopInGameThreadWithDelay(250, function()
        -- wie Schnell-Loop/Inbox: nicht waehrend des Ladens und erst nach dem Vergessen der alten Welt
        if not MultiplayerActive or (WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60) or WorldGen.Dropped ~= WorldGen.N then return end
        local ok, err = pcall(Z.HpTick, CurrentWorld())
        if not ok and not Z.HpErr then Z.HpErr = true Log("Zombie-Leben-Fehler (Host): %s", tostring(err)) end
    end)
end

-- Animationen der KI (Zombie-Angriffe und -Treffer, Baeren, Scavenger): Die KI rechnet nur beim Host, ihre
-- Montagen (PlayAnimMontage / "Play Montage") laufen nur dort, ohne Multicast - der Mitspieler sah Zombies
-- ohne Schlag-Animation zuschlagen. Der Host meldet jede Montage einer KI-Figur (Lage, Klasse, Montage,
-- Tempo, Abschnitt) an die Mitspieler in der Naehe; die spielen sie auf ihrer Kopie (gefunden ueber die Lage).
Z.MONTAGE_RANGE, Z.MontageSent = 10000, {}

-- Schnell-Aufgabe "z_mon" (100 ms, Host): gesammelte Montagen an die Gaeste ohne ai2-Montagen (Ziele einmal je Lauf)
function Z.MonFast(_, Mode, World)
    local Q = Z.MonQ
    if #Q == 0 then return end
    Z.MonQ = {}
    if Mode ~= "ListenServer" then return end
    local Targets = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = Safe(function() return PS:GetOwner() end)
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            local Pawn = not Z.MonV2(Key) and Safe(function() return PC:K2_GetPawn() end)
            if IsAlive(Pawn) then Targets[#Targets + 1] = { PC = PC, Key = Key, L = Pawn:K2_GetActorLocation() } end
        end
    end
    if #Targets == 0 then return end
    for _, E in ipairs(Q) do
        local Char = E[1]
        if not Char and IsAlive(E[5]) then Char = Safe(function() return E[5]:GetOwner() end) end
        pcall(Z.OnMontage, Char, E[2], E[3], E[4], Targets)
    end
end

function Z.OnMontage(Char, Montage, Rate, Section, Targets)
    if not (IsAlive(Char) and IsAlive(Montage)) then return end
    local Class = Char:GetClass():GetFName():ToString()
    if Class == "BP_PlayerCharacter_C" then return end
    local Path = Montage:GetFullName():match("^%S+%s+(.+)$")
    if not Path then return end
    -- Dieselbe Montage derselben Figur hoechstens alle 0,3 s (Trefferserien); Merkliste jede Minute leeren
    local Key, Now = Char:GetFName():ToString() .. Path, os.clock()
    if Now - (Z.MontageClean or 0) > 60 then Z.MontageSent, Z.MontageClean = {}, Now end
    if Now - (Z.MontageSent[Key] or -1) < 0.3 then return end
    Z.MontageSent[Key] = Now
    local L, Range2 = Char:K2_GetActorLocation(), Z.MONTAGE_RANGE * Z.MONTAGE_RANGE
    local SectionName = Safe(function() return Section:ToString() end, "None")
    local Text = string.format("%.0f;%.0f;%.0f;%s;%.2f;%s;%s", L.X, L.Y, L.Z, Class, Rate or 1, SectionName, Path)
    local Text2   -- hp_v2: dieselbe Zeile mit fester Id vorn (amon2), nur fuer Gaeste mit hello 2
    for _, T in ipairs(Targets or {}) do
        local PC, G = T.PC, T.L
        if IsAlive(PC) and (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2 < Range2 then
            if SETTINGS.hp_v2 and Coop.GuestProto[T.Key] == 2 then
                Text2 = Text2 or (Z.NetIdFor(Char) .. ";" .. Text)
                Coop.SendChunked(function(Part) SendToClient(PC, Part) end, "amon2", Text2)
            else
                Coop.SendChunked(function(Part) SendToClient(PC, Part) end, "amon", Text)
            end
        end
    end
end

-- Mitspieler: Die Montage loest beim Zombie ueber ihr AnimNotify die Treffer-Pruefung (AttackTrace) aus - beim
-- Mitspieler darf die niemanden treffen (der Schaden kommt vom Host). Darum vorher die Spielerklasse in
-- ClassesToIgnore des Zombies (dort prueft AttackTrace jeden Treffer). Baeren treffen per Timer im Host.
Z.Montages, Z.Ignoring = {}, {}

-- CORE-19 (world_hygiene): Spielobjekte nicht ueber Ticks merken (nur Pfade); je Nutzung frisch per StaticFindObject
-- (Hash-Suche). world_hygiene aus: wie bisher gemerkt.
function Z.MontageOf(Path)
    if WorldGen.Hygiene ~= false then return StaticFindObject(Path) end
    local Montage = Z.Montages[Path]
    if not IsAlive(Montage) then Montage = StaticFindObject(Path) Z.Montages[Path] = Montage end
    return Montage
end
function Z.ZClass()
    if WorldGen.Hygiene ~= false then return StaticFindObject(Z.CLASS) end
    return Z.ZombieClass or StaticFindObject(Z.CLASS)
end

Coop.HostDataHandlers.amon = function(Text)
    local SX, SY, SZ, Class, SRate, Section, Path = Text:match("^(%-?%d+);(%-?%d+);(%-?%d+);([^;]+);([%d.]+);([^;]*);(.+)$")
    if not SX then return end
    -- Nicht mitten in der Netzwerk-Verarbeitung animieren: im naechsten Frame
    ExecuteInGameThread(function()
        pcall(function()
            local X, Y, Zc = tonumber(SX), tonumber(SY), tonumber(SZ)
            local Montage = Z.MontageOf(Path)
            if not IsAlive(Montage) then return end
            local Best, BestD = nil, Z.MATCH * Z.MATCH
            for _, Char in ipairs(FindAllOf(Class) or {}) do
                if IsAlive(Char) and not Coop.IsDeadAI(Char) then
                    local L = Char:K2_GetActorLocation()
                    local D = (L.X - X) ^ 2 + (L.Y - Y) ^ 2 + (L.Z - Zc) ^ 2
                    if D < BestD then Best, BestD = Char, D end
                end
            end
            if not Best then return end
            local Name = Best:GetFName():ToString()   -- Namen werden nicht wiederverwendet, Adressen schon
            if not Z.Ignoring[Name] then
                Z.Ignoring[Name] = true
                pcall(function()
                    local List = Best.ClassesToIgnore
                    List[#List + 1] = StaticFindObject(CHARACTER_CLASS)
                end)
            end
            Best:PlayAnimMontage(Montage, tonumber(SRate), FName(Section ~= "" and Section or "None"))
            if not Z.MontageLogged then Z.MontageLogged = true Log("KI-Animationen vom Host werden abgespielt (%s)", Class) end
        end)
    end)
end

-- hp_v2: wie amon, aber mit fester Id vorn ("Id;X;Y;Z;Klasse;Tempo;Abschnitt;Pfad"); die Figur kommt aus der
-- Bindung (Z.Resolve), die Klasse dient nur der ersten Zuordnung. Kein FindAllOf pro Nachricht.
Coop.HostDataHandlers.amon2 = function(Text)
    local SId, SX, SY, SZ, Class, SRate, Section, Path =
        Text:match("^(%d+);(%-?%d+);(%-?%d+);(%-?%d+);([^;]+);([%d.]+);([^;]*);(.+)$")
    if not SId then Z.BadEntry("amon2", Text) return end
    ExecuteInGameThread(function()
        pcall(function()
            local Montage = Z.MontageOf(Path)
            if not IsAlive(Montage) then return end
            local Best = Z.Resolve(tonumber(SId), tonumber(SX), tonumber(SY), tonumber(SZ), Class, true)
            if not Best then return end
            local Name = Best:GetFName():ToString()
            if not Z.Ignoring[Name] then
                Z.Ignoring[Name] = true
                pcall(function()
                    local List = Best.ClassesToIgnore
                    List[#List + 1] = StaticFindObject(CHARACTER_CLASS)
                end)
            end
            Best:PlayAnimMontage(Montage, tonumber(SRate), FName(Section ~= "" and Section or "None"))
            if not Z.MontageLogged then Z.MontageLogged = true Log("KI-Animationen vom Host werden abgespielt (%s, feste IDs)", Class) end
        end)
    end)
end

-- Mitspieler: jeden Eintrag dem naechsten lebenden Zombie (innerhalb MATCH) zuordnen. Namen taugen nicht:
-- replizierte Actors heissen beim Mitspieler anders.
-- Im naechsten Bild anwenden (nicht im Netzwerk-Hook)
Coop.HostDataHandlers.hp = function(Text)
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.ApplyHp, Text)
        if not ok and not Z.ApplyErr then Z.ApplyErr = true Log("Zombie-Leben-Fehler: %s", tostring(err)) end
    end)
end

function Z.ApplyHp(Text)
    Z.ZombieClass = Z.ZClass()
    if not IsAlive(Z.ZombieClass) then return end
    local Zombies = {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Char:IsA(Z.ZombieClass) and not Coop.IsDeadAI(Char) then
            Zombies[#Zombies + 1] = { Char = Char, L = Char:K2_GetActorLocation() }
        end
    end
    local Count = 0
    for SX, SY, SZ, SHp in Text:gmatch("(%-?%d+);(%-?%d+);(%-?%d+);([%d.]+)") do
        local X, Y, Zc, Hp = tonumber(SX), tonumber(SY), tonumber(SZ), tonumber(SHp)
        local Best, BestD = nil, Z.MATCH * Z.MATCH
        for _, E in ipairs(Zombies) do
            local D = (E.L.X - X) ^ 2 + (E.L.Y - Y) ^ 2 + (E.L.Z - Zc) ^ 2
            if D < BestD then Best, BestD = E.Char, D end
        end
        -- SetCurrent&MaxHealth loest das Ereignis aus, an dem der Lebensbalken haengt (5.3 AIHealthBarUI.UpdateHealth,
        -- UE 5.6 HUD_Game_C.EnemyHealthBarUI = W_EnemyHealthBarOverlay; DamageComponent @00ca unveraendert);
        -- nur den Wert zu schreiben liess den Balken auf dem alten Stand
        if Best and pcall(function()
            local DC = Best.DamageComponent
            if not IsAlive(DC) then error("keine DamageComponent") end
            if Hp <= 0 or not pcall(function() DC["SetCurrent&MaxHealth"](DC, Hp, DC.MaxHealth) end) then DC.CurrentHealth = Hp end   -- 0: kein Tod beim Spieler
        end) then
            Z.HostHp[Best:GetAddress()] = Hp
            Count = Count + 1
        end
    end
    if not Z.Logged and Count > 0 then Z.Logged = true Log("Zombie-Leben vom Host uebernommen (%d)", Count) end
end

-- hp_v2: "Id;X;Y;Z;Hp" je Zombie, Zuordnung ueber die feste Id (Z.Resolve) statt jedes Mal ueber die Lage
Coop.HostDataHandlers.hp2 = function(Text)
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.ApplyHp2, Text)
        if not ok and not Z.Apply2Err then Z.Apply2Err = true Log("Zombie-Leben-Fehler (feste IDs): %s", tostring(err)) end
    end)
end

function Z.ApplyHp2(Text)
    Z.ZombieClass = Z.ZClass()
    if not IsAlive(Z.ZombieClass) then return end
    local Count = 0
    for Entry in Text:gmatch("[^|]+") do
        local SId, SX, SY, SZ, SHp = Entry:match("^(%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?[%d%.]+)$")
        local Hp = tonumber(SHp)
        if not (SId and Hp) then
            Z.BadEntry("hp2", Entry)
        else
            local Best = Z.Resolve(tonumber(SId), tonumber(SX), tonumber(SY), tonumber(SZ), Z.ZombieClass, true)
            -- wie Z.ApplyHp: SetCurrent&MaxHealth fuer den Lebensbalken, bei 0 nur den Wert (kein Tod beim Spieler)
            if Best and pcall(function()
                local DC = Best.DamageComponent
                if not IsAlive(DC) then error("keine DamageComponent") end
                if Hp <= 0 or not pcall(function() DC["SetCurrent&MaxHealth"](DC, Hp, DC.MaxHealth) end) then DC.CurrentHealth = Hp end
            end) then
                Z.HostHp[Best:GetAddress()] = Hp
                Count = Count + 1
            end
        end
    end
    if not Z.Logged and Count > 0 then Z.Logged = true Log("Zombie-Leben vom Host uebernommen (%d, feste IDs)", Count) end
end

-- Mitspieler: Schaden an Zombie-Kopien neutralisieren (Pre-Hook: Schaden 0). Kein Post-Hook mehr:
-- ReceiveAnyDamage ruft Damage_Object auf, verschachtelte Post-Hooks liessen UE4SS beim Schiessen des
-- Mitspielers abstuerzen. Das Leben kommt ohnehin jede Sekunde vom Host (hp).
-- CORE-18: keine UFunction im Rumpf (Schadenskette, verschachtelt): Modus aus Lua (Z.ClientMode, gesetzt in
-- Z.ClientTick), Autoritaet ueber die Eigenschaft Role statt HasAuthority
local function GuardPre(Context, Damage)
    if Z.ClientMode ~= true then return end
    local Char = Context:get()
    if not IsAlive(Char) or Safe(function() return Char.Role end) == ROLE_AUTHORITY then return end
    pcall(function() Damage:set(0) end)
end

function Z.ClientTick()
    Z.ClientMode = true   -- laeuft nur verbunden als Mitspieler (HandleClient); Z.Reset nimmt es zurueck
    local okFx, errFx = pcall(Z.LookClientTick)
    if not okFx and not Z.LOOK.TickErr then Z.LOOK.TickErr = true Log("Zombie-Effekt-Fehler: %s", tostring(errFx)) end
    -- ai_guard (ls_ai): Waechter per Eigenschaft statt Lua-Hooks auf ReceiveAnyDamage/Damage_Object
    -- Entscheidung einmal merken: ein spaeteres FLAG_DOWN von ai_guard registriert nie die alten Hooks in der
    -- Schadenskette. CORE-18: erst entscheiden, wenn ls_ai sich gemeldet hat (Coop.AI2GuestGuard gesetzt); fehlt ls_ai,
    -- nach 30 s der alte Weg.
    if Z.NoGuard == nil then
        if Coop.AI2GuestGuard ~= nil then
            Z.NoGuard = Safe(Coop.AI2GuestGuard, false) == true
        else
            Z.GuardWaitAt = Z.GuardWaitAt or os.clock()
            if os.clock() - Z.GuardWaitAt < 30 then return end
            Z.NoGuard = false
            Log("Zombie-Schaden: ls_ai fehlt - alter Weg (Hooks ohne Spielfunktionen im Rumpf)")
        end
    end
    if Z.Hooked or Z.NoGuard or not StaticFindObject(Z.CLASS):IsValid() then return end
    Z.Hooked = true
    TryHook(Z.CLASS .. ":ReceiveAnyDamage", GuardPre)
    TryHook(Z.CLASS .. ":Damage_Object", GuardPre)
    Log("Zombie-Schaden beim Mitspieler: nur noch vom Host")
end

-- Zombie-Aussehen und -Typ: Repliziert ist nur IsDead?. Jeder Rechner wuerfelt in BeginPlay selbst das
-- Modell und Material (SetMeshAndMaterial) und die Unterklassen den Typ (Archetype_*: Modell, Material,
-- Name, Lauf-Animation, Mund-Effekt/Strahlungsnebel, Strahlungs-Timer); Brennen laeuft auch nur beim
-- Host. Jeder sah andere Zombies. Der Host schickt jedem Mitspieler fuer die Zombies in seiner Naehe
-- Modell, Material, Augen-Material, Typ und Brennen (neu/geaendert sofort, 3 s spaeter noch einmal, dann
-- alle 30 s, falls die Zuordnung ueber die Lage einmal daneben lag). Pfade und Klassen gehen als kurze
-- Nummern (zdef, einmal je Mitspieler). Der Mitspieler setzt den Typ des Hosts (eigene falsche Effekte
-- weg), dann Modell und Materialien; seine Kopie macht nie selbst Strahlungsschaden (der kommt vom Host).
Z.LOOK = { EVERY = 2, AGAIN = 3, REFRESH = 30, MAX_PER_TICK = 60, At = 0, CleanAt = 0,
           Ids = {}, Texts = {}, NextId = 0, Def = {}, Sent = {},       -- Host
           Paths = {}, Assets = {}, Alive = {}, Unrad = {}, Pending = {} }  -- Mitspieler
-- UE 5.6 (Ubergraph BP_MasterZombie, self.Name = Text(...)): Sprinter @584a, Acidic @5c77, Ultra-Radiated @26da,
-- Crawler @60cf, neu Grenadier @614b und Screamer @6510; Bomber gibt es nicht mehr (Nummer 3 bleibt fuer 5.3 frei, die Nummern
-- gehen ueber das Netz). Archetype_* rufen nur noch den Ubergraph (Einsprung je Version, hier nur per Name aufgerufen).
Z.ARCH = { "Undead Sprinter", "Acidic Undead", "Bomber Undead", "Ultra-Radiated Undead", "Toughened Undead Crawler",
           "Undead Grenadier", "Undead Screamer" }
Z.ARCH_FN = { "Archetype_Sprinter", "Archetype_Acidic", "Archetype_Bomber", "Archetype_UltraRadiated",
              "Archetype_ToughenedCrawler", "Archetype_Grenadier", "Archetype_Screamer" }
Z.ACID, Z.RADIATED = 2, 4
-- Typen mit Timer, der beim Mitspieler nur Wirkung ohne Sicht haette (Schaden/Explosion/Schrei kommen vom Host):
-- UE 5.6 K2_SetTimerDelegate -> ArchetypeTimer: Event_Rad @2729, Event_Grenadier @6195, Event_Screamer @63fd
-- (5.3: nur Event_Rad, RadTimer). Abgeschaltet per K2_ClearTimer(Figur, Funktionsname) - geht fuer beide Versionen.
Z.ARCH_TIMER = { [4] = "Event_Rad", [6] = "Event_Grenadier", [7] = "Event_Screamer" }

-- Brennt die Figur? UE 5.6 "IsBurning" (SetBurning @67e8), 5.3 "Is Burning?"
function Z.BurnField(Char)
    return Coop.HasMember(Char, "IsBurning") and "IsBurning" or "Is Burning?"
end

function Z.Burning(Char)
    return Safe(function() return Char[Z.BurnField(Char)] == true end, false)
end

-- UE 5.6: Augen sind ein Parameter des Koerper-Materials (EyesColour: dynamische Instanz @0033, 'EyesColour' @007c,
-- 'EyesColourEmissiveStrength' @00cf). Werte der aktuellen Instanz lesen (nil = keine dynamische Instanz/kein Wert).
function Z.EyeParams(Mesh)
    Z.MidClass = Z.MidClass or StaticFindObject("/Script/Engine.MaterialInstanceDynamic")
    return Safe(function()
        local Mat = Mesh:GetMaterial(0)
        if not (IsAlive(Mat) and IsAlive(Z.MidClass) and Mat:IsA(Z.MidClass)) then return nil end
        local C = Mat:K2_GetVectorParameterValue(FName("EyesColour"))
        local S = Mat:K2_GetScalarParameterValue(FName("EyesColourEmissiveStrength"))
        if type(S) ~= "number" or C == nil then return nil end
        return { Colour = { R = C.R, G = C.G, B = C.B, A = C.A }, Strength = S }
    end)
end

-- UE 5.6: nach dem Materialtausch die Augen wie vorher (oder wie Event_EyesCallback @37e8: EyesEmissiveColour, Staerke
-- 10, mit CVar Game.DisableZombieEyes 0) neu setzen. 5.3 (Augen-Meshes) hat kein EyesColour: nichts tun.
function Z.ReapplyEyes(Char, Eyes)
    if not Coop.HasMember(Char, "EyesColour") then return end
    if not Eyes then
        local Off = Safe(function() return UEHelpers.GetKismetSystemLibrary():GetConsoleVariableBoolValue("Game.DisableZombieEyes") end, false)
        local C = Safe(function() return Char.EyesEmissiveColour end)
        if C == nil then return end
        Eyes = { Colour = { R = C.R, G = C.G, B = C.B, A = C.A }, Strength = Off == true and 0 or 10 }
    end
    pcall(function() Char:EyesColour(Eyes.Colour, Eyes.Strength) end)
end
Z.ACID_FX = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_RadiatedZombie.FX_Explosion_RadiatedZombie"
Z.ACID_SOUND = "/Game/Audio/Infected_SpecialCue.Infected_SpecialCue"

function Z.PathOf(Obj)
    return IsAlive(Obj) and Obj:GetFullName():match("^%S+%s+(.+)$") or nil
end

-- Material als Asset-Pfad (eine dynamische Instanz zaehlt als ihr Eltern-Material)
function Z.MatPath(Mat)
    local Path = Z.PathOf(Mat)
    if Path and not Path:match("^/Game/") then Path = Safe(function() return Z.PathOf(Mat.Parent) end) end
    return Path and Path:match("^/Game/") and Path or nil
end

-- Typ ueber den angezeigten Namen (die Archetype-Funktionen setzen ihn; das Spiel ist nicht uebersetzt)
function Z.ArchOf(Char)
    local Text = Safe(function() return Char.Name:ToString() end, "")
    for I, Name in ipairs(Z.ARCH) do
        if Name == Text then return I end
    end
    return 0
end

function Z.IdOf(Text)
    if not Text then return 0 end
    local Id = Z.LOOK.Ids[Text]
    if not Id then
        Z.LOOK.NextId = Z.LOOK.NextId + 1
        Id = Z.LOOK.NextId
        Z.LOOK.Ids[Text], Z.LOOK.Texts[Id] = Id, Text
    end
    return Id
end

-- Host: "Klasse;Modell;Material;Augen;Typ;Brennt" (Nummern) eines Zombies
function Z.Signature(Char)
    local Mesh = Char.Mesh
    local Ids = { Z.IdOf(Char:GetClass():GetFName():ToString()),
                  Z.IdOf(Safe(function() return IsAlive(Mesh) and Z.PathOf(Mesh:GetSkeletalMeshAsset()) or nil end)),
                  Z.IdOf(Safe(function() return IsAlive(Mesh) and Z.MatPath(Mesh:GetMaterial(0)) or nil end)),
                  -- Augen-Material nur in 5.3 (EyeLeftMesh); 5.6 hat keine Augen-Meshes mehr: 0
                  Z.IdOf(Coop.HasMember(Char, "EyeLeftMesh") and Safe(function() local Eye = Char.EyeLeftMesh return IsAlive(Eye) and Z.MatPath(Eye:GetMaterial(0)) or nil end) or nil) }
    local Burning = Z.Burning(Char)
    return string.format("%d;%d;%d;%d;%d;%d", Ids[1], Ids[2], Ids[3], Ids[4], Z.ArchOf(Char), Burning and 1 or 0), Ids
end

function Z.LookHost(PCs)
    local L0, Now = Z.LOOK, os.clock()
    if Now < L0.At then return end
    L0.At = Now + L0.EVERY
    local Targets, Range2 = {}, Z.RANGE * Z.RANGE
    for _, PC in ipairs(PCs) do
        local Pawn = PC:K2_GetPawn()
        if IsAlive(Pawn) then
            local Key = PC:GetFName():ToString()
            L0.Sent[Key], L0.Def[Key] = L0.Sent[Key] or {}, L0.Def[Key] or {}
            Targets[#Targets + 1] = { PC = PC, Key = Key, L = Pawn:K2_GetActorLocation(), Parts = {}, Defs = {},
                                      V2 = SETTINGS.hp_v2 and Coop.GuestProto[PC:GetFullName()] == 2 }   -- hp_v2: zlook2 mit Id
        end
    end
    if #Targets == 0 then return end
    local Seen = {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Char:IsA(Z.ZombieClass) and not Coop.IsDeadAI(Char) then
            local Name, L, Sig, Ids = Char:GetFName():ToString(), Char:K2_GetActorLocation(), nil, nil
            local NetId   -- feste Id, nur fuer Gaeste mit hello 2
            Seen[Name] = true
            for _, T in ipairs(Targets) do
                if #T.Parts < L0.MAX_PER_TICK and (L.X - T.L.X) ^ 2 + (L.Y - T.L.Y) ^ 2 < Range2 then
                    if not Sig then Sig, Ids = Z.Signature(Char) end
                    local S = L0.Sent[T.Key][Name]
                    local Changed = not S or S.Sig ~= Sig
                    if Changed or Now >= S.Next then
                        local Count = Changed and 1 or S.Count + 1
                        L0.Sent[T.Key][Name] = { Sig = Sig, Count = Count, Next = Now + (Count < 2 and L0.AGAIN or L0.REFRESH) }
                        if T.V2 then
                            NetId = NetId or Z.NetIdFor(Char, Name)
                            T.Parts[#T.Parts + 1] = string.format("%d;%.0f;%.0f;%.0f;%s", NetId, L.X, L.Y, L.Z, Sig)
                        else
                            T.Parts[#T.Parts + 1] = string.format("%.0f;%.0f;%.0f;%s", L.X, L.Y, L.Z, Sig)
                        end
                        for _, Id in ipairs(Ids) do
                            if Id > 0 and not L0.Def[T.Key][Id] then
                                L0.Def[T.Key][Id] = true
                                T.Defs[#T.Defs + 1] = Id .. "=" .. L0.Texts[Id]
                            end
                        end
                    end
                end
            end
        end
    end
    for _, T in ipairs(Targets) do
        local function Send(Text) SendToClient(T.PC, Text) end
        if #T.Defs > 0 then Coop.SendChunked(Send, "zdef", table.concat(T.Defs, "|")) end
        if #T.Parts > 0 then Coop.SendChunked(Send, T.V2 and "zlook2" or "zlook", table.concat(T.Parts, "|")) end
    end
    -- Jede Minute vergessen: tote/verschwundene Zombies und getrennte Mitspieler
    if Now >= L0.CleanAt then
        L0.CleanAt = Now + 60
        local Live = {}
        for _, PC in ipairs(PCs) do Live[PC:GetFName():ToString()] = true end
        for Key, List in pairs(L0.Sent) do
            if not Live[Key] then L0.Sent[Key], L0.Def[Key] = nil, nil
            else for Name in pairs(List) do if not Seen[Name] then List[Name] = nil end end end
        end
    end
end

-- Mitspieler: Pfade/Klassen zu den Nummern
Coop.HostDataHandlers.zdef = function(Text)
    for Id, Path in Text:gmatch("(%d+)=([^|]+)") do Z.LOOK.Paths[tonumber(Id)] = Path end
end

Coop.HostDataHandlers.zlook = function(Text)
    -- Nicht mitten im Netzwerk-Empfang Modelle tauschen: im naechsten Frame
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.LookApplyAll, Text)
        if not ok and not Z.LOOK.Err then Z.LOOK.Err = true Log("Zombie-Aussehen-Fehler: %s", tostring(err)) end
    end)
end

function Z.Asset(Path)
    if not Path then return nil end
    if WorldGen.Hygiene ~= false then   -- CORE-19: kein Objekt-Cache (nur per LoadAsset geladene Assets sammelt die GC ein)
        local Found = StaticFindObject(Path)
        if not IsAlive(Found) then
            local ok, Loaded = pcall(LoadAsset, Path)
            Found = ok and Loaded or nil
        end
        return IsAlive(Found) and Found or nil
    end
    local Asset = Z.LOOK.Assets[Path]
    if IsAlive(Asset) then return Asset end
    Asset = StaticFindObject(Path)
    if not IsAlive(Asset) then
        local ok, Loaded = pcall(LoadAsset, Path)
        Asset = ok and Loaded or nil
    end
    if IsAlive(Asset) then Z.LOOK.Assets[Path] = Asset return Asset end
    return nil
end

-- Jeder Eintrag geht an den naechsten lebenden Zombie derselben Klasse (innerhalb MATCH), jeder nur einmal
function Z.LookApplyAll(Text)
    local L0, ByClass, Used, Count = Z.LOOK, {}, {}, 0
    for SX, SY, SZ, SC, SM, SMat, SE, SA, SB in
        Text:gmatch("(%-?%d+);(%-?%d+);(%-?%d+);(%d+);(%d+);(%d+);(%d+);(%d+);(%d)") do
        local Class = L0.Paths[tonumber(SC)]
        if Class then
            local List = ByClass[Class]
            if not List then
                List = {}
                for _, Char in ipairs(FindAllOf(Class) or {}) do
                    if IsAlive(Char) and not Char:HasAuthority() and not Coop.IsDeadAI(Char) then
                        List[#List + 1] = { Char = Char, L = Char:K2_GetActorLocation() }
                    end
                end
                ByClass[Class] = List
            end
            local X, Y, Zc = tonumber(SX), tonumber(SY), tonumber(SZ)
            local Best, BestD = nil, Z.MATCH * Z.MATCH
            for _, E in ipairs(List) do
                if not Used[E] then
                    local D = (E.L.X - X) ^ 2 + (E.L.Y - Y) ^ 2 + (E.L.Z - Zc) ^ 2
                    if D < BestD then Best, BestD = E, D end
                end
            end
            if Best then
                Used[Best] = true
                local ok, Changed = pcall(Z.LookApply, Best.Char, L0.Paths[tonumber(SM)], L0.Paths[tonumber(SMat)],
                    L0.Paths[tonumber(SE)], tonumber(SA), SB == "1")
                if ok and Changed then Count = Count + 1 end
                if not ok and not L0.ApplyErr then L0.ApplyErr = true Log("Zombie-Aussehen: %s", tostring(Changed)) end
            end
        end
    end
    if Count > 0 then
        L0.Applied = (L0.Applied or 0) + Count
        if not L0.Logged then L0.Logged = true Log("Zombie-Aussehen vom Host uebernommen (%d angepasst)", Count) end
    end
end

-- hp_v2: "Id;X;Y;Z;Klasse;Modell;Material;Augen;Typ;Brennt" - wie Z.LookApplyAll, die Figur aber ueber die feste Id
-- (Z.Resolve mit der Klasse aus zdef; die Bindung ersetzt die Used-Liste)
Coop.HostDataHandlers.zlook2 = function(Text)
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.LookApplyAll2, Text)
        if not ok and not Z.LOOK.Err2 then Z.LOOK.Err2 = true Log("Zombie-Aussehen-Fehler (feste IDs): %s", tostring(err)) end
    end)
end

function Z.LookApplyAll2(Text)
    local L0, Count = Z.LOOK, 0
    for Entry in Text:gmatch("[^|]+") do
        local SId, SX, SY, SZ, SC, SM, SMat, SE, SA, SB =
            Entry:match("^(%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%d+);(%d+);(%d+);(%d+);(%d+);([01])$")
        if not SId then
            Z.BadEntry("zlook2", Entry)
        else
            local Class = L0.Paths[tonumber(SC)]
            local Best = Class and Z.Resolve(tonumber(SId), tonumber(SX), tonumber(SY), tonumber(SZ), Class, true)
            if Best then
                local ok, Changed = pcall(Z.LookApply, Best, L0.Paths[tonumber(SM)], L0.Paths[tonumber(SMat)],
                    L0.Paths[tonumber(SE)], tonumber(SA), SB == "1")
                if ok and Changed then Count = Count + 1 end
                if not ok and not L0.ApplyErr then L0.ApplyErr = true Log("Zombie-Aussehen: %s", tostring(Changed)) end
            end
        end
    end
    if Count > 0 then
        L0.Applied = (L0.Applied or 0) + Count
        if not L0.Logged then L0.Logged = true Log("Zombie-Aussehen vom Host uebernommen (%d angepasst, feste IDs)", Count) end
    end
end

function Z.LookApply(Char, MeshPath, MatPath, EyePath, Arch, Burn)
    local L0, Name, Changed = Z.LOOK, Char:GetFName():ToString(), false
    L0.Alive[Name] = Arch   -- fuer den Tod merken (Saeure-Explosion)
    local Own = Z.ArchOf(Char)
    if Own ~= Arch then
        -- Eigenen (falschen) Typ zuruecknehmen: seine Effekte weg, Name/Lauf-Animation wie die Klasse
        -- (5.3 MouthFX; UE 5.6 Saeure-Spucke BloodSpitFX @5c64, Strahlungsnebel ZombieMist @26c7)
        for _, Field in ipairs({ "MouthFX", "ZombieMist", "BloodSpitFX" }) do
            if Coop.HasMember(Char, Field) then
                pcall(function()
                    local Comp = Char[Field]
                    if IsAlive(Comp) then Comp:K2_DestroyComponent(Char) end
                end)
            end
        end
        if Arch > 0 and Z.ARCH_FN[Arch] and Coop.HasMember(Char, Z.ARCH_FN[Arch]) then
            Char[Z.ARCH_FN[Arch]](Char)   -- wuerfelt Modell/Material neu, das wird gleich ueberschrieben
        else
            local CDO = Char:GetClass():GetCDO()
            pcall(function() Char.Name = FText(CDO.Name:ToString()) end)
            pcall(function() Char.MovementBlendspace = CDO.MovementBlendspace end)
        end
        Changed = true
    end
    -- Strahlungsschaden (5.6 auch Grenadier/Screamer) rechnet nur der Host (sonst doppelt auf der eigenen Figur)
    -- Je Typ-Paar einmal (wuerfelt die eigene Kopie spaeter selbst einen Typ, SelectArchetype 5.6 @0039 nach 1-1,25 s,
    -- ist das Paar neu und der neue Timer geht auch weg)
    local Timer, Pair = Z.ARCH_TIMER[Arch] or Z.ARCH_TIMER[Own], tostring(Own) .. ">" .. tostring(Arch)
    if Timer and L0.Unrad[Name] ~= Pair then
        L0.Unrad[Name] = Pair
        local KSL = UEHelpers.GetKismetSystemLibrary()
        for _, Fn in pairs({ A = Z.ARCH_TIMER[Arch], B = Z.ARCH_TIMER[Own] }) do
            pcall(function() KSL:K2_ClearTimer(Char, Fn) end)
        end
    end
    local Mesh = Char.Mesh
    if MeshPath and IsAlive(Mesh) and Z.PathOf(Mesh:GetSkeletalMeshAsset()) ~= MeshPath then
        local Asset = Z.Asset(MeshPath)
        if Asset then Mesh:SetSkinnedAssetAndUpdate(Asset, false) Changed = true end
    end
    if MatPath and IsAlive(Mesh) and Z.MatPath(Mesh:GetMaterial(0)) ~= MatPath then
        local Asset = Z.Asset(MatPath)
        if Asset then
            -- UE 5.6: Augenfarbe haengt an der dynamischen Instanz des Koerper-Materials -> vorher lesen, danach neu
            local Eyes = Z.EyeParams(Mesh)
            Mesh:SetMaterial(0, Asset)
            Changed = true
            Z.ReapplyEyes(Char, Eyes)
        end
    end
    if EyePath then   -- nur 5.3 (Augen-Meshes mit eigenem Material)
        for _, Field in ipairs({ "EyeLeftMesh", "EyeRightMesh" }) do
            if Coop.HasMember(Char, Field) then
                pcall(function()
                    local Eye = Char[Field]
                    if IsAlive(Eye) and Z.MatPath(Eye:GetMaterial(0)) ~= EyePath then
                        local Asset = Z.Asset(EyePath)
                        if Asset then Eye:SetMaterial(0, Asset) Changed = true end
                    end
                end)
            end
        end
    end
    -- Feuer: Der Schaden der eigenen Kopie wird ohnehin auf 0 gesetzt (GuardPre), das Leben kommt vom Host
    local Burning = Z.Burning(Char)
    if Burn and not Burning then
        pcall(function() Char:SetBurning(true, 0, nil) end)
        Changed = true
    elseif not Burn and Burning then
        pcall(function() Char:StopBurning() end)
        Changed = true
    end
    return Changed
end

-- Mitspieler, beim Tod eines Zombies (Corpse.Setup): Das Spiel entfernt die Augen und zeigt bei
-- Saeure-Zombies nach 1,5 s eine Explosion - beides nur beim Host (Death laeuft nur dort).
function Z.OnClientDeath(Char, Name)
    if Char:HasAuthority() then return end
    for _, Field in ipairs({ "EyeLeftMesh", "EyeRightMesh" }) do   -- nur 5.3 (Death @03fe/@0978 entfernt die Augen)
        if Coop.HasMember(Char, Field) then
            pcall(function() local Eye = Char[Field] if IsAlive(Eye) then Eye:SetVisibility(false, false) end end)
        end
    end
    -- UE 5.6: Death schaltet beim Host Strahlungsnebel und Saeure-Spucke ab (@0946 ZombieMist, @099d BloodSpitFX)
    for _, Field in ipairs({ "ZombieMist", "BloodSpitFX" }) do
        if Coop.HasMember(Char, Field) then
            pcall(function() local Fx = Char[Field] if IsAlive(Fx) then Fx:Deactivate() end end)
        end
    end
    pcall(function() if Z.Burning(Char) then Char:StopBurning() end end)
    -- Geraeusche der Figur aus (Tiere: Deer_Noises usw., das stoppt sonst nur der Host)
    pcall(function()
        Z.AudioClass = Z.AudioClass or StaticFindObject("/Script/Engine.AudioComponent")
        for _, Comp in ipairs(Coop.ArrList(Char:K2_GetComponentsByClass(Z.AudioClass))) do
            if IsAlive(Comp) and Comp:IsPlaying() then Comp:Stop() end
        end
    end)
    local Arch = Z.LOOK.Alive[Name] or Z.ArchOf(Char)
    -- Saeure-Explosion: 5.3 nach 1,5 s (@406e), UE 5.6 nach 1,3-1,6 s (Event_SpecialDeath @5186 -> @0760:
    -- FX_Explosion_RadiatedZombie @080c, Infected_SpecialCue @08e9 - dieselben Assets wie Z.ACID_FX/Z.ACID_SOUND)
    if Z.LOOK.Alive[Name] ~= nil and Arch == Z.ACID then
        if Coop.HasMember(Char, "MouthFX") then
            pcall(function() local Fx = Char.MouthFX if IsAlive(Fx) then Fx:Deactivate() end end)
        end
        -- CORE-19 (world_hygiene): nur den Pfad merken, nach 1,5 s frisch aufloesen
        local Path = WorldGen.Hygiene ~= false and Safe(function() return Char:GetFullName():match("^%S+%s+(.+)$") end) or nil
        Z.LOOK.Pending[#Z.LOOK.Pending + 1] = Path and { Path = Path, At = os.clock() + 1.5 } or { Char = Char, At = os.clock() + 1.5 }
    end
    Z.LOOK.Alive[Name] = nil
end

function Z.AcidFx(Char)
    local Mesh = Char.Mesh
    if not IsAlive(Mesh) then return end
    local L = Mesh:K2_GetComponentLocation()
    local Loc, World, GS = { X = L.X, Y = L.Y, Z = L.Z }, CurrentWorld(), UEHelpers.GetGameplayStatics()
    local Fx, Sound = Z.Asset(Z.ACID_FX), Z.Asset(Z.ACID_SOUND)
    if Fx then
        GS:SpawnEmitterAtLocation(World, Fx, Loc, { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 },
            { X = 1, Y = 1, Z = 1 }, true, 0, true)
    end
    if Sound then
        GS:PlaySoundAtLocation(World, Sound, Loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil, nil)
    end
    if not Z.LOOK.FxLogged then Z.LOOK.FxLogged = true Log("Saeure-Explosion eines Zombies gezeigt") end
end

function Z.LookClientTick()
    local P, Now = Z.LOOK.Pending, os.clock()
    if Z.ANIMAL.MeatAt and Now >= Z.ANIMAL.MeatAt then
        Z.ANIMAL.MeatAt = nil
        -- UE 5.6: keine Fleisch-Kiste mehr (Container_AnimalMeat_C entfernt). Das Fleisch legt der Host ins Inventar des
        -- toten Tiers (BP_AnimalDeer @07dd AddNewItemSomewhere DA_RawMeat), gelootet wird das Tier selbst
        -- (JigCanInteract: Health <= 0, das Leben kommt per ahp/ahp2). Diagnose darum: tote Tiere hier.
        local Dead = 0
        for _, Char in ipairs(FindAllOf("BP_Animal_C") or {}) do
            if IsAlive(Char) and Z.AnimalDead(Char) then Dead = Dead + 1 end
        end
        Log("Tier-Leichen hier: %d (Fleisch im Inventar des Tiers)", Dead)
    end
    for I = #P, 1, -1 do
        if Now >= P[I].At then
            local E = table.remove(P, I)
            local Char = E.Path and StaticFindObject(E.Path) or E.Char
            if IsAlive(Char) then Z.AcidFx(Char) end
        end
    end
end

-- Tiere: Bei ihnen ist gar nichts repliziert (nicht einmal IsDead?). Leben, Tod und Flucht rechnet nur der
-- Host; beim Mitspieler stand eine Kopie mit voller Lebensleiste, die nie umfiel. Der Host schickt Leben und
-- Tod der Tiere nahe Mitspielern (ahp, Zuordnung ueber die Lage, Aenderungen sofort, alle 15 s alle); der
-- Mitspieler setzt Health, beim Tod IsDead?/Dead (die Leichen-Schleife macht daraus die Ragdoll).
-- Diagnose im Host-Log: jeder Treffer auf ein Tier (kommt der Schaden an?) und was Tiere nahe Mitspielern
-- wahrnehmen (warum fliehen sie nicht?).
Z.ANIMAL = { FULL_EVERY = 15, FullAt = 0, Sent = {}, HitMinute = 0, HitCount = 0, Sense = {}, SENSE_RANGE = 6000,
             MeatAt = nil, DeathFor = {}, DEATH_TICKS = 3, DeadDone = {}, DEATH_NEAR = 1000 }

function Z.AnimalDead(Char)
    return Safe(function() return Char["IsDead?"] == true or Char.Dead == true end, false)
end

function Z.AnimalHost(PCs, Guests)
    local A0 = Z.ANIMAL
    local Now, Parts, Range2 = os.time(), {}, Z.RANGE * Z.RANGE
    local Full = Now >= A0.FullAt
    if Full then A0.FullAt = Now + A0.FULL_EVERY end
    -- hp_v2: Gaeste mit hello 2 bekommen ahp2 ("Id;X;Y;Z;Klasse;Leben;Tot"), die anderen wie bisher ahp
    local IsV2, Parts2 = {}, nil
    for I, PC in ipairs(PCs) do
        IsV2[I] = SETTINGS.hp_v2 and Coop.GuestProto[PC:GetFullName()] == 2
        if IsV2[I] then Parts2 = Parts2 or {} end
    end
    -- Runde 3: Ein totes Tier hat beim Host die Actor-Lage 0,0,0 (Kapsel weg): es fiel aus der Reichweite, der Tod kam
    -- nie beim Mitspieler an (Kopie lebte weiter, Schuesse aus der Naehe "ohne Schaden"). Darum bei ~0,0,0 oder tot die
    -- Lage des Mesh (fuer Reichweite und Meldung), und ein frisch gestorbenes, schon einmal gemeldetes Tier noch DEATH_TICKS
    -- Durchlaeufe lang an alle schicken, auch ausser Reichweite. DeathFor: [Name] = verbleibende Durchlaeufe (nur Zahlen).
    local DeathFor, ForcedNow = A0.DeathFor, {}
    for _, Char in ipairs(FindAllOf("BP_Animal_C") or {}) do
        if IsAlive(Char) then
            local Name = Char:GetFName():ToString()
            local S = A0.Sent[Name]
            local L, NearD2 = Char:K2_GetActorLocation(), math.huge
            local Dead = nil
            if math.abs(L.X) + math.abs(L.Y) + math.abs(L.Z) < 1 or (S and S.Dead) then
                L = Safe(function() local M = Char.Mesh return IsAlive(M) and M:K2_GetComponentLocation() or nil end) or L
            end
            for _, G in ipairs(Guests) do NearD2 = math.min(NearD2, (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2) end
            -- Schon gemeldet, lebte beim letzten Mal und jetzt ausser Reichweite: nur pruefen, ob es gestorben ist
            if NearD2 >= Range2 and S and not S.Dead and not DeathFor[Name] then
                Dead = Z.AnimalDead(Char)
                if Dead then
                    DeathFor[Name] = A0.DEATH_TICKS
                    L = Safe(function() local M = Char.Mesh return IsAlive(M) and M:K2_GetComponentLocation() or nil end) or L
                end
            end
            local Forced = (DeathFor[Name] or 0) > 0
            if Forced then ForcedNow[Name] = true end
            if NearD2 < Range2 or Forced then
                local Hp = Safe(function() return Char.Health end)
                if Dead == nil then Dead = Z.AnimalDead(Char) end
                if SETTINGS.hp_v2 then A0.Seen[Name] = true end   -- fuer das Aufraeumen von Sent/Sense (Z.NetPrune)
                if S and type(Hp) == "number" and (Hp < S.Hp - 0.05 or Dead ~= S.Dead) then pcall(Z.AnimalHit, Name, S.Hp, Hp, Dead) end
                -- frisch gestorben (in Reichweite): ebenfalls die naechsten Durchlaeufe wiederholen
                if Dead and S and not S.Dead and not Forced then DeathFor[Name], Forced, ForcedNow[Name] = A0.DEATH_TICKS, true, true end
                -- Tod gemeldet und wiederholt: nie wieder schicken (auch nicht alle FULL_EVERY s oder bei Schuessen auf die
                -- Leiche) - sonst suchte der Mitspieler ohne Bindung eine lebende Kopie in der Naehe und toetete die
                local Settled = Dead and S and S.Dead and not Forced
                if type(Hp) == "number" and not Settled and (Full or Forced or not S or S.Dead ~= Dead or math.abs(S.Hp - Hp) > 0.05) then
                    A0.Sent[Name] = { Hp = Hp, Dead = Dead }
                    local Class = Char:GetClass():GetFName():ToString()
                    Parts[#Parts + 1] = string.format("%.0f;%.0f;%.0f;%s;%.2f;%d", L.X, L.Y, L.Z,
                        Class, Hp, Dead and 1 or 0)
                    if Parts2 then
                        Parts2[#Parts2 + 1] = string.format("%d;%.0f;%.0f;%.0f;%s;%.2f;%d", Z.NetIdFor(Char, Name), L.X, L.Y, L.Z,
                            Class, Hp, Dead and 1 or 0)
                    end
                end
                if not Dead and NearD2 < A0.SENSE_RANGE ^ 2 then pcall(Z.AnimalSense, Char, Name, math.sqrt(NearD2) / 100) end
            end
        end
    end
    -- Tod-Wiederholungen herunterzaehlen (nicht mehr gefundene Tiere vergessen)
    for Name, K in pairs(DeathFor) do
        if ForcedNow[Name] and K > 1 then DeathFor[Name] = K - 1 else DeathFor[Name] = nil end
    end
    if #Parts == 0 then return end
    local Text, Text2 = table.concat(Parts, "|"), Parts2 and table.concat(Parts2, "|")
    for I, PC in ipairs(PCs) do
        if IsV2[I] then Coop.SendChunked(function(T) SendToClient(PC, T) end, "ahp2", Text2)
        else Coop.SendChunked(function(T) SendToClient(PC, T) end, "ahp", Text) end
    end
end

-- Host: Treffer an sinkendem Leben erkennen (hoechstens 20 Zeilen pro Minute). Kein Hook auf ReceiveAnyDamage:
-- damit stuerzte der Server ab (UE4SS, Zugriff auf 0x18), als ein Lua-Befehl einem Hirsch Schaden machte.
function Z.AnimalHit(Name, Before, Hp, Dead)
    local A0, Minute = Z.ANIMAL, os.time() // 60
    if A0.HitMinute ~= Minute then A0.HitMinute, A0.HitCount = Minute, 0 end
    A0.HitCount = A0.HitCount + 1
    if A0.HitCount > 20 then return end
    Log("Tier-Treffer: %s Leben %.0f -> %.0f%s", Name, Before, Hp, Dead and " (tot)" or "")
end

-- Host: Was nimmt ein Tier nahe einem Mitspieler wahr? (nur bei Aenderung ins Log)
function Z.AnimalSense(Char, Name, DistM)
    local Ctrl = Char:GetController()
    if not IsAlive(Ctrl) then return end
    local Sees = Safe(function() local BB = Ctrl.Blackboard return IsAlive(BB) and BB:GetValueAsBool(FName("CanSeePlayer")) or nil end)
    local Count = Safe(function()
        local Out = {}
        local Perc = Ctrl:GetAIPerceptionComponent()
        if not IsAlive(Perc) then return nil end
        Perc:GetCurrentlyPerceivedActors(nil, Out)
        return #Out
    end)
    local State = tostring(Sees) .. "/" .. tostring(Count)
    if Z.ANIMAL.Sense[Name] == State then return end
    Z.ANIMAL.Sense[Name] = State
    Log("Tier %s %.0f m vom naechsten Mitspieler: sieht Spieler=%s, nimmt %s Figuren wahr", Name, DistM,
        tostring(Sees), tostring(Count))
end

Coop.HostDataHandlers.ahp = function(Text)
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.AnimalApply, Text)
        if not ok and not Z.ANIMAL.Err then Z.ANIMAL.Err = true Log("Tier-Fehler: %s", tostring(err)) end
    end)
end

-- Mitspieler: jeder Eintrag an das naechste Tier derselben Klasse (innerhalb MATCH), jedes nur einmal
function Z.AnimalApply(Text)
    local ByClass, Used, Count, Deaths = {}, {}, 0, 0
    for SX, SY, SZ, Class, SHp, SDead in Text:gmatch("(%-?%d+);(%-?%d+);(%-?%d+);([^;|]+);(%-?[%d.]+);(%d)") do
        local List = ByClass[Class]
        if not List then
            List = {}
            for _, Char in ipairs(FindAllOf(Class) or {}) do
                if IsAlive(Char) and not Char:HasAuthority() then List[#List + 1] = { Char = Char, L = Char:K2_GetActorLocation() } end
            end
            ByClass[Class] = List
        end
        local X, Y, Zc = tonumber(SX), tonumber(SY), tonumber(SZ)
        local Best, BestD = nil, Z.MATCH * Z.MATCH
        for _, E in ipairs(List) do
            if not Used[E] then
                local D = (E.L.X - X) ^ 2 + (E.L.Y - Y) ^ 2 + (E.L.Z - Zc) ^ 2
                if D < BestD then Best, BestD = E, D end
            end
        end
        -- Runde 3: Tod ohne Kopie innerhalb MATCH -> naechste lebende innerhalb DEATH_NEAR (der Host meldet tote Tiere
        -- jetzt an der Mesh-Lage und wiederholt den Tod), aber nicht, wenn hier gerade schon eins umgefallen ist
        if not Best and SDead == "1" and not Z.RecentDeathAt(X, Y, Zc) then
            BestD = Z.ANIMAL.DEATH_NEAR ^ 2
            for _, E in ipairs(List) do
                if not Used[E] and not Z.AnimalDead(E.Char) then
                    local D = (E.L.X - X) ^ 2 + (E.L.Y - Y) ^ 2 + (E.L.Z - Zc) ^ 2
                    if D < BestD then Best, BestD = E, D end
                end
            end
        end
        if Best and SDead == "1" then Z.NoteDeathAt(X, Y, Zc) end
        if Best then
            Used[Best] = true
            local Char = Best.Char
            if pcall(function() Char.Health = tonumber(SHp) end) then Count = Count + 1 end
            if SDead == "1" and not Z.AnimalDead(Char) then
                pcall(function() Char["IsDead?"] = true end)
                pcall(function() Char.Dead = true end)
                pcall(Coop.CorpseNow, Char)   -- Ragdoll sofort (nicht erst in der Sekunden-Schleife)
                Deaths = Deaths + 1
            end
        end
    end
    if Count > 0 and not Z.ANIMAL.Logged then Z.ANIMAL.Logged = true Log("Tier-Leben vom Host uebernommen (%d)", Count) end
    if Deaths > 0 then
        Log("%d Tier(e) beim Host gestorben: hier umgefallen", Deaths)
        Z.ANIMAL.MeatAt = os.clock() + 5   -- danach pruefen, ob die Fleisch-Kiste des Hosts ankam
    end
end

-- hp_v2 (feste IDs): Der Host gibt jeder KI-Figur (Zombies, Tiere, KI mit Montagen) eine feste Nummer. Seine Namen
-- sind stabil und werden nicht wiederverwendet. Die Nummer bleibt auch, wenn ein toter Zombie wieder lebt (Pool):
-- seine Kopie beim Mitspieler ist derselbe replizierte Actor, die Bindung stimmt weiter (eine neue Nummer liesse die
-- alte Bindung die Kopie blockieren). Der Mitspieler bindet jede Nummer einmal an seine Kopie (naechste freie Figur
-- innerhalb MATCH) und prueft danach nur noch Name und Lage - kein FindAllOf und kein Vergleich mit allen Figuren pro
-- Nachricht. Version per "hello": nur Gaeste mit hello 2 bekommen hp2/zlook2/ahp2/amon2, alle anderen die alten
-- Formate (alte Peers ignorieren unbekannte Arten).
Coop.GuestProto, Coop.HelloIds = {}, {}   -- Host: [Controller-Key] = Protokoll (2) bzw. Mitspieler-ID aus hello
Z.NetIdNext, Z.NetIdByName, Z.ActorByNetId = 0, {}, {}   -- Host: Id-Register ([Name] = Id, [Id] = { Obj, Name })
Z.Hp2, Z.Near, Z.NearIds = {}, {}, {}                    -- Host: hp2 je Gast, Zombies nahe Gaesten (1x pro Sekunde)
Z.PcSeen, Z.ProtoGone = {}, {}                           -- Host: Controller vom letzten Durchlauf, Protokoll-Gnadenfrist
Z.V2At = { Near = 0, Prune = 0, Bound = 0 }              -- Zeitplan (alles os.clock): Z.Near, Aufraeumen Host/Mitspieler
Z.ANIMAL.Seen = {}                                       -- Host: Tiere nahe Gaesten seit dem letzten Aufraeumen
Z.Bound, Z.BoundBy, Z.Pool, Z.Extra = {}, {}, nil, {}    -- Mitspieler: Bindungen und Kandidaten
Z.KEEP, Z.POOL_FOR, Z.EXTRA_FOR = 150, 0.2, 5
Z.HELLO = { EVERY = 2, WAIT = 10, Sent = 0, NOTE = "Server veraltet - Legacy-Modus" }
Z.Bad = { N = 0, LogAt = 0 }

-- Host: feste Id einer Figur (Name = GetFName, falls schon gelesen)
function Z.NetIdFor(Char, Name)
    Name = Name or Char:GetFName():ToString()
    local Id = Z.NetIdByName[Name]
    if Id and Z.ActorByNetId[Id] then return Id end
    Z.NetIdNext = Z.NetIdNext + 1
    Id = Z.NetIdNext
    Z.NetIdByName[Name], Z.ActorByNetId[Id] = Id, { Obj = Char, Name = Name }
    return Id
end

-- Host (1x pro Sekunde): getrennte Mitspieler vergessen (zdef beim Wiederkommen neu, hp2 neu), jede Minute aufraeumen
function Z.NetHostTick(PCs)
    local Live = {}
    for _, PC in ipairs(PCs) do Live[PC:GetFullName()] = PC:GetFName():ToString() end
    for Key, Short in pairs(Z.PcSeen) do
        if not Live[Key] then
            Z.LOOK.Sent[Short], Z.LOOK.Def[Short], Z.Hp2[Key], Z.SentTo[Key] = nil, nil, nil, nil   -- SentTo: hp (alt)
            Log("Mitspieler getrennt: Zombie-Zustand fuer %s verworfen", Short)
        end
    end
    Z.PcSeen = Live
    local Now = os.clock()
    if Now < Z.V2At.Prune then return end
    Z.V2At.Prune = Now + 60
    Z.NetPrune(Live)
end

function Z.NetPrune(Live)
    local Ids, Gone = 0, 0
    -- Lebende nur ueber frische Listen (Namen), das gemerkte Objekt nie anfassen: vom GC freigegeben = Absturz
    local Alive = {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) then Alive[Char:GetFName():ToString()] = true end
    end
    for _, Char in ipairs(FindAllOf("BP_Animal_C") or {}) do
        if IsAlive(Char) then Alive[Char:GetFName():ToString()] = true end
    end
    for Id, E in pairs(Z.ActorByNetId) do
        Ids = Ids + 1
        if not Alive[E.Name] then
            Z.ActorByNetId[Id], Gone = nil, Gone + 1
            if Z.NetIdByName[E.Name] == Id then Z.NetIdByName[E.Name] = nil end
        end
    end
    for Name, Id in pairs(Z.NetIdByName) do if not Z.ActorByNetId[Id] then Z.NetIdByName[Name] = nil end end
    -- Tiere: Sent/Sense wurden nie geleert (nur was seit dem letzten Aufraeumen nahe einem Gast war, bleibt)
    local A0 = Z.ANIMAL
    -- Runde 3: gemeldete Tode behalten, solange das Tier existiert - sonst schickte Z.AnimalHost den Tod beim naechsten
    -- Naeherkommen erneut, und der Mitspieler (Bindung/DeadDone laengst weg) toetete eine lebende Kopie bis DEATH_NEAR
    for Name, S in pairs(A0.Sent) do
        if not A0.Seen[Name] and not (S.Dead and Alive[Name]) then A0.Sent[Name] = nil end
    end
    for Name in pairs(A0.Sense) do if not A0.Seen[Name] then A0.Sense[Name] = nil end end
    A0.Seen = {}
    for Key in pairs(Z.Hp2) do if not Live[Key] then Z.Hp2[Key] = nil end end
    -- Protokoll erst nach zwei Durchlaeufen ohne Controller vergessen (kurz fehlender PlayerState)
    for Key in pairs(Coop.GuestProto) do
        if Live[Key] then Z.ProtoGone[Key] = nil
        elseif Z.ProtoGone[Key] then
            Coop.GuestProto[Key], Coop.HelloIds[Key], Z.ProtoGone[Key], Coop.GuestJoin[Key] = nil, nil, nil, nil
        else Z.ProtoGone[Key] = true end
    end
    if Gone > 0 then Log("Id-Register: %d von %d Figuren verschwunden, aufgeraeumt", Gone, Ids) end
end

-- Host (250-ms-Schleife, nur Gaeste mit hello 2): Zombies nahe Gaesten hoechstens 1x pro Sekunde aus dem Figuren-
-- Cache (Z.Near), sonst nur deren Leben lesen, die Lage erst beim Senden. Pro Gast und Id das zuletzt geschickte
-- Leben; senden bei Aenderung > 0,05, alle FULL_EVERY s alle angeschlagenen. Hoechstens eine Nachricht pro Gast und
-- Durchlauf; mehr als MAX_ENTRIES: naechstes Mal an dieser Stelle weiter (rotierend, keiner verhungert).
function Z.Hp2Tick(Guests)
    Z.ZombieClass = Z.ZClass()
    if not IsAlive(Z.ZombieClass) then return end
    local Now, Range2 = os.clock(), Z.RANGE * Z.RANGE
    if Now >= Z.V2At.Near then
        Z.V2At.Near = Now + 1
        local Near, Ids = {}, {}
        for _, Char in ipairs(Coop.Characters()) do
            if IsAlive(Char) and Char:IsA(Z.ZombieClass) and not Coop.IsDeadAI(Char) then
                local L = Char:K2_GetActorLocation()
                for _, G in ipairs(Guests) do
                    if (L.X - G.L.X) ^ 2 + (L.Y - G.L.Y) ^ 2 < Range2 then
                        local Id = Z.NetIdFor(Char)
                        Near[#Near + 1], Ids[Id] = { Char = Char, Id = Id, L = L }, true
                        break
                    end
                end
            end
        end
        Z.Near, Z.NearIds = Near, Ids
    end
    local Near, Hps, Maxs, Locs = Z.Near, {}, {}, {}
    for I, E in ipairs(Near) do
        if IsAlive(E.Char) and not Coop.IsDeadAI(E.Char) then
            local Hp = ZombieHp(E.Char)
            if type(Hp) == "number" then
                Hps[I], Maxs[I] = Hp, Safe(function() local DC = E.Char.DamageComponent return IsAlive(DC) and DC.MaxHealth or Hp end, Hp)
            end
        end
    end
    local N = #Near
    for _, G in ipairs(Guests) do
        local St = Z.Hp2[G.Key]
        if not St then St = { Sent = {}, FullAt = 0, Cursor = 1 } Z.Hp2[G.Key] = St end
        local Full, Parts = Now >= St.FullAt, {}
        if Full then
            St.FullAt = Now + Z.FULL_EVERY
            for Id in pairs(St.Sent) do if not Z.NearIds[Id] then St.Sent[Id] = nil end end
        end
        local Start = St.Cursor <= N and St.Cursor or 1
        for K = 0, N - 1 do
            local I = (Start - 1 + K) % N + 1
            local Hp, E = Hps[I], Near[I]
            if Hp then
                if (E.L.X - G.L.X) ^ 2 + (E.L.Y - G.L.Y) ^ 2 >= Range2 then
                    St.Sent[E.Id] = nil   -- ausser Reichweite: beim Wiederkommen neu
                elseif (Full and Hp < Maxs[I]) or math.abs(Hp - (St.Sent[E.Id] or Maxs[I])) > 0.05 then
                    if #Parts >= Z.MAX_ENTRIES then St.Cursor = I break end
                    Locs[I] = Locs[I] or Safe(function() return E.Char:K2_GetActorLocation() end, E.L)
                    local L = Locs[I]
                    Parts[#Parts + 1] = string.format("%d;%.0f;%.0f;%.0f;%.2f", E.Id, L.X, L.Y, L.Z, Hp)
                    St.Sent[E.Id] = Hp
                end
            end
        end
        if #Parts > 0 then
            local PC = G.PC
            Coop.SendChunked(function(T) SendToClient(PC, T) end, "hp2", table.concat(Parts, "|"))
        end
    end
end

-- Host: hello eines Mitspielers ("2|<Mitspieler-ID>", kommt im Empfangs-Hook: Antwort erst im naechsten Bild).
-- Die ID nur merken (HelloIds), der Inventar-Abgleich bleibt bei guestid#seq. Antwort "2|<Server-FPS-Ziel>".
-- join_v2: Protokoll 3 = 2 plus Beitritt am Ziel (Mitspieler mit join_v2). Der Host antwortet 3, wenn er so spawnt
-- (join_v2, Server-Inventar), schickt dann gleich den Modus mit und merkt es in Coop.GuestJoin.
function Coop.OnHello(Key, PC, Data)
    if not SETTINGS.hp_v2 then return end   -- aus: keine Antwort, der Mitspieler bleibt bei den alten Formaten
    local SProto, GuestId = Data:match("^(%d+)|(%x*)$")
    local Raw = tonumber(SProto)
    if not Raw then return end
    local Proto = math.min(Raw, 2)
    local Join = SETTINGS.join_v2 and not SETTINGS.local_inventory and Raw >= 3
    if Coop.GuestProto[Key] ~= Proto then
        Log("hello von Mitspieler %s: Protokoll %d%s", GuestId ~= "" and GuestId or "?", Proto, Join and " (Beitritt am Ziel)" or "")
    end
    Coop.GuestProto[Key], Z.ProtoGone[Key] = Proto, nil
    Coop.GuestJoin[Key] = Join or nil
    if GuestId ~= "" and Coop.BindGuestId(Key, PC, GuestId) then Coop.HelloIds[Key] = GuestId end
    ExecuteInGameThread(function()
        pcall(function()
            if not IsAlive(PC) then return end
            local Srv, Fps = SETTINGS.server, 60
            if Srv and Srv.FpsCap then Fps = tonumber(Safe(Srv.FpsCap)) or 60 end
            Coop.SendChunked(function(T) SendToClient(PC, T) end, "hello", string.format("%d|%d", Join and 3 or 2, math.floor(Fps)))
            if Join then Coop.SendMode(PC) end
        end)
    end)
end
Coop.GuestJoin = {}   -- Host: [Controller-Key] = true, Mitspieler kann join_v2 (hello 3)

-- Mitspieler: hello des Hosts ("2|<FPS>", "3|<FPS>" = Beitritt am Ziel kommt): neue Formate kommen, Fahrzeug-Takt
-- nie ueber den Server-FPS
Coop.HostDataHandlers.hello = function(Text)
    local Proto, Fps = Text:match("^(%d+)|(%d+)")
    if not Proto then return end
    if Coop.HostProto ~= 2 then Log("hello vom Server: Protokoll %s, Server-FPS %s", Proto, Fps) end
    Coop.HostProto = tonumber(Proto) >= 2 and 2 or 1
    Coop.HostJoin = tonumber(Proto) >= 3
    if Coop.Car then Coop.Car.HostFps = tonumber(Fps) end
    Z.HELLO.Note = nil   -- spaete Antwort: kein Legacy-Hinweis mehr
end

-- Mitspieler (jede Sekunde, sobald verbunden, auch ohne Figur): eigenes hello alle EVERY s, bis das des Hosts kommt.
-- Kommt WAIT s nach dem ersten hello keins (alter Server): Legacy, Hinweis einmal, sobald das HUD steht. Kein Kick.
function Z.NetClientTick()
    if not SETTINGS.hp_v2 then return end
    local H, Now = Z.HELLO, os.clock()
    if Coop.HostProto == nil then
        if H.FirstAt and H.Sent >= H.WAIT / H.EVERY and Now - H.FirstAt >= H.WAIT then
            Coop.HostProto, H.Note = 1, true
            Log("Kein hello vom Server nach %d s: Legacy-Modus (alte Formate)", H.WAIT)
        elseif Now >= (H.At or 0) then
            H.At = Now + H.EVERY
            -- join_v2: Protokoll 3 (alte Hosts lesen es als 2)
            if pcall(Coop.SendChunked, Coop.SendToHost, "hello", (SETTINGS.join_v2 and "3|" or "2|") .. Coop.OwnGuestId()) then
                H.Sent, H.FirstAt = H.Sent + 1, H.FirstAt or Now
            end
        end
    end
    if H.Note then
        local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
        if IsAlive(Pawn) and IsAlive(Safe(function() return Pawn.InGameUI end)) then
            H.Note = nil
            pcall(Coop.ShowNote, H.NOTE)
        end
    end
    if Now >= Z.V2At.Bound then
        Z.V2At.Bound = Now + 60
        -- Weg oder seit 60 s ohne Meldung (zlook2 kommt fuer jeden Zombie in Reichweite alle 30 s): loesen, sonst
        -- blockierte eine falsche Bindung einer verschwundenen Id die Figur fuer immer
        for Id, B in pairs(Z.Bound) do if not Z.LiveByName(B.Name) or Now - B.At > 60 then Z.Unbind(Id) end end
        for Id, T in pairs(Z.ANIMAL.DeadDone) do if Now - T > 60 then Z.ANIMAL.DeadDone[Id] = nil end end
        -- Runde 3 (3b): lokale Tiere (Autoritaet beim Mitspieler, vom Client-Spawner) nur zaehlen und loggen; die
        -- Probe zeigte keine. Hoechstens 1x pro Minute, nur wenn es welche gibt.
        local Own, Loaded = 0, 0
        for _, Char in ipairs(FindAllOf("BP_Animal_C") or {}) do
            if IsAlive(Char) and Safe(function() return Char:HasAuthority() end, false) then
                Own = Own + 1
                if WAS_LOADED and Safe(function() return Char:HasAnyFlags(WAS_LOADED) end, false) then Loaded = Loaded + 1 end
            end
        end
        if Own > 0 then Log("Tiere: %d lokale Kopien beim Mitspieler (Autoritaet, davon %d aus der Karte) - nur gezaehlt", Own, Loaded) end
    end
end

-- Unlesbare Eintraege der v2-Formate zaehlen, hoechstens alle 30 s ins Log
function Z.BadEntry(Kind, Entry)
    local B, Now = Z.Bad, os.clock()
    B.N = B.N + 1
    if Now < B.LogAt then return end
    B.LogAt = Now + 30
    Log("%s: unlesbarer Eintrag (%d bisher): %s", Kind, B.N, tostring(Entry):sub(1, 80))
end

-- Mitspieler: Kandidaten fuer neue Bindungen (Figuren ohne Autoritaet, also keine lokalen Geister) aus
-- Coop.Characters, POOL_FOR s gueltig und nur gebaut, wenn eine Id (neu) gebunden werden muss
function Z.PoolList()
    local P, Now = Z.Pool, os.clock()
    if P and Now - P.At <= Z.POOL_FOR then return P end
    Z.ZombieClass = Z.ZClass()
    local ZC = IsAlive(Z.ZombieClass) and Z.ZombieClass or nil
    P = { At = Now, List = {}, Classes = {}, ByName = {} }
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and not Safe(function() return Char:HasAuthority() end, true) then
            local Class = Safe(function() return Char:GetClass():GetFName():ToString() end, "")
            local Name = Char:GetFName():ToString()
            P.Classes[Class] = true
            P.ByName[Name] = Char
            P.List[#P.List + 1] = { Char = Char, Name = Name, L = Char:K2_GetActorLocation(),
                                    Class = Class, Dead = Coop.IsDeadAI(Char),
                                    Zombie = ZC ~= nil and Safe(function() return Char:IsA(ZC) end, false) }
        end
    end
    Z.Pool = P
    return P
end

-- Klassen, die nicht unter den Figuren sind (Tiere, falls kein Character): FindAllOf hoechstens alle EXTRA_FOR s
function Z.ExtraList(Class)
    local X, Now = Z.Extra[Class], os.clock()
    if not X or Now - X.ObjAt > Z.EXTRA_FOR then
        X = { ObjAt = Now, Objs = FindAllOf(Class) or {}, At = -math.huge }
        -- CORE-19 (world_hygiene): ueber die EXTRA_FOR s nur Pfade halten, je Neuaufbau frisch aufloesen (die Objekte
        -- der FindAllOf-Liste konnte die GC inzwischen freigeben)
        if WorldGen.Hygiene ~= false then
            local Paths = {}
            for _, O in ipairs(X.Objs) do
                local P = IsAlive(O) and Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end) or nil
                if P then Paths[#Paths + 1] = P end
            end
            X.Objs, X.Paths = nil, Paths
        end
        Z.Extra[Class] = X
    end
    if Now - X.At > Z.POOL_FOR then
        X.At, X.List, X.ByName = Now, {}, {}
        local Objs = X.Objs
        if X.Paths then
            Objs = {}
            for _, P in ipairs(X.Paths) do
                local O = StaticFindObject(P)
                if IsAlive(O) then Objs[#Objs + 1] = O end
            end
        end
        for _, Char in ipairs(Objs) do
            if IsAlive(Char) and not Safe(function() return Char:HasAuthority() end, true) then
                local Name = Char:GetFName():ToString()
                X.ByName[Name] = Char
                X.List[#X.List + 1] = { Char = Char, Name = Name, L = Char:K2_GetActorLocation(),
                                        Class = Class, Dead = Coop.IsDeadAI(Char) }
            end
        end
    end
    return X.List
end

-- Gebundene Figur nur ueber die frische Liste holen, nie das gemerkte Objekt selbst anfassen: Ist es inzwischen vom
-- GC freigegeben, liest schon IsAlive freien Speicher (Absturz EXCEPTION_ACCESS_VIOLATION, kein pcall hilft).
function Z.LiveByName(Name, Class)
    local P = Z.PoolList()
    if P.ByName[Name] then return P.ByName[Name] end
    if type(Class) == "string" and not P.Classes[Class] then
        Z.ExtraList(Class)
        local X = Z.Extra[Class]
        return X and X.ByName and X.ByName[Name] or nil
    end
    return nil
end

function Z.Unbind(Id)
    local B = Z.Bound[Id]
    if B and Z.BoundBy[B.Name] == Id then Z.BoundBy[B.Name] = nil end
    Z.Bound[Id] = nil
end

function Z.Bind(Id, Char, Name, X, Y, Zc)
    Z.Unbind(Id)
    local Other = Z.BoundBy[Name]
    if Other and Other ~= Id then Z.Bound[Other] = nil end   -- uebernommen (vertauschte Bindung)
    Z.Bound[Id], Z.BoundBy[Name] = { Obj = Char, Name = Name, X = X, Y = Y, Zc = Zc, At = os.clock() }, Id
end

-- Fremd gebundene Figur uebernehmen (ihre Id hat sie wohl vertauscht)? Meldet sich deren Id gerade (hoechstens 1 s alt):
-- nur wenn ihre Meldung weiter als KEEP und weiter als unsere (D) von der Figur weg liegt - und, wenn wir selbst eine
-- lebende Figur haben (CurL, Abstand CurD), nur wenn der Tausch beide Abstaende zusammen kleiner macht. Sonst tauschten
-- hintereinander laufende Zombies, deren Kopien mehr als KEEP hinterherhinken, ihre Bindungen (und behielten sie, sobald
-- sie stehen). Meldet sie sich nicht (Leben unveraendert, tot beim Host): nur eine Figur innerhalb KEEP und nur, wenn
-- wir keine Figur haben oder unsere lebende weiter als MATCH steht - sonst bliebe eine vertauschte Figur blockiert.
function Z.Free(E, Owner, D, Now, CurL, CurD)
    local O, Keep2 = Z.Bound[Owner], Z.KEEP * Z.KEEP
    if not (O and Now - O.At <= 1) then
        return D <= Keep2 and (CurD == math.huge or (CurL ~= nil and CurD > Z.MATCH * Z.MATCH))
    end
    local DO = (E.L.X - O.X) ^ 2 + (E.L.Y - O.Y) ^ 2 + (E.L.Z - O.Zc) ^ 2
    if not (DO > Keep2 and DO > D) then return false end
    if not CurL then return true end
    return D + (CurL.X - O.X) ^ 2 + (CurL.Y - O.Y) ^ 2 + (CurL.Z - O.Zc) ^ 2 < CurD + DO
end

-- Mitspieler: Figur zur festen Id des Hosts. Gebunden, lebt und gleicher Name: gilt, solange sie hoechstens KEEP
-- (1,5 m) von der gemeldeten Lage steht; weiter weg nur neu binden, wenn eine freie Figur naeher steht. Ungebunden:
-- naechste freie Figur innerhalb MATCH. Class: Klassenname (genau) oder die Zombie-Klasse (IsA). Living: keine Toten;
-- ist die gebundene Kopie (noch) tot, Bindung behalten (Pool: lebt gleich wieder) und nur eine lebende freie Figur
-- innerhalb KEEP nehmen (die Bindung war falsch).
function Z.Resolve(Id, X, Y, Zc, Class, Living)
    if Coop.AI2Resolve then   -- ls_ai: ein Binder fuer ai2/zlook2/amon2/hp2 (false = nicht zustaendig -> alter Weg)
        local R = Coop.AI2Resolve(Id)
        if R ~= false then return R end
    end
    if not (Id and X and Y and Zc) then return nil end
    local B, CurD, CurL, Now, Dead = Z.Bound[Id], math.huge, nil, os.clock(), false
    if B then
        local Obj = Z.LiveByName(B.Name, Class)   -- frisch, statt B.Obj (siehe Z.LiveByName)
        if Obj then
            B.Obj = Obj
            B.X, B.Y, B.Zc, B.At = X, Y, Zc, Now
            Dead = Living and Coop.IsDeadAI(Obj)
            if Dead then
                CurD = Z.KEEP * Z.KEEP
            else
                CurL = Obj:K2_GetActorLocation()
                CurD = (CurL.X - X) ^ 2 + (CurL.Y - Y) ^ 2 + (CurL.Z - Zc) ^ 2
                if CurD <= Z.KEEP * Z.KEEP then return Obj end
            end
        else
            Z.Unbind(Id)
            B = nil
        end
    end
    local ByName = type(Class) == "string"
    local List = Z.PoolList()
    List = (not ByName or List.Classes[Class]) and List.List or Z.ExtraList(Class)
    -- Freie Figuren (ohne Bindung) und fremd gebundene (Z.Free) getrennt; die eigene zaehlt schon als CurD
    local Limit = math.min(CurD, Z.MATCH * Z.MATCH)
    local Best, BestD, Steal, StealD = nil, Limit, nil, Limit
    for _, E in ipairs(List) do
        if (ByName and E.Class == Class or not ByName and E.Zombie) and not (Living and E.Dead) then
            local D = (E.L.X - X) ^ 2 + (E.L.Y - Y) ^ 2 + (E.L.Z - Zc) ^ 2
            local Owner = Z.BoundBy[E.Name]
            if Owner == nil then
                if D < BestD then Best, BestD = E, D end
            elseif Owner ~= Id and D < StealD and Z.Free(E, Owner, D, Now, CurL, CurD) then
                Steal, StealD = E, D
            end
        end
    end
    -- Ohne eigene Figur zuerst eine freie (die uns weggenommene ist meist die frei gewordene des anderen), mit eigener
    -- die naechste
    if Steal and (not Best or (B and StealD < BestD)) then Best = Steal end
    if Best and not (B and Best.Name == B.Name) and IsAlive(Best.Char) then
        Z.Bind(Id, Best.Char, Best.Name, X, Y, Zc)
        return Best.Char
    end
    return B and not Dead and B.Obj or nil
end

-- hp_v2: Tiere mit fester Id ("Id;X;Y;Z;Klasse;Leben;Tot"), sonst wie Z.AnimalApply
Coop.HostDataHandlers.ahp2 = function(Text)
    ExecuteInGameThread(function()
        local ok, err = pcall(Z.AnimalApply2, Text)
        if not ok and not Z.ANIMAL.Err2 then Z.ANIMAL.Err2 = true Log("Tier-Fehler (feste IDs): %s", tostring(err)) end
    end)
end

function Z.AnimalApply2(Text)
    local Count, Deaths = 0, 0
    for Entry in Text:gmatch("[^|]+") do
        local SId, SX, SY, SZ, Class, SHp, SDead =
            Entry:match("^(%d+);(%-?%d+);(%-?%d+);(%-?%d+);([^;]+);(%-?[%d%.]+);([01])$")
        local Hp = tonumber(SHp)
        if not (SId and Hp) then
            Z.BadEntry("ahp2", Entry)
        else
            -- Runde 3: Tod-Eintraege nicht ueber Z.Resolve (gab die gebundene Kopie zurueck, egal wie weit weg, oder
            -- nichts, wenn keine innerhalb MATCH stand), sondern Z.AnimalDeathTarget. Leben weiter ueber Z.Resolve.
            local Char
            if SDead == "1" then
                Char = Z.AnimalDeathTarget(tonumber(SId), tonumber(SX), tonumber(SY), tonumber(SZ), Class)
            else
                Char = Z.Resolve(tonumber(SId), tonumber(SX), tonumber(SY), tonumber(SZ), Class, false)
            end
            if Char then
                if pcall(function() Char.Health = Hp end) then Count = Count + 1 end
                if SDead == "1" and not Z.AnimalDead(Char) then
                    pcall(function() Char["IsDead?"] = true end)
                    pcall(function() Char.Dead = true end)
                    pcall(Coop.CorpseNow, Char)   -- Ragdoll sofort (nicht erst in der Sekunden-Schleife)
                    Deaths = Deaths + 1
                end
            end
        end
    end
    if Count > 0 and not Z.ANIMAL.Logged then Z.ANIMAL.Logged = true Log("Tier-Leben vom Host uebernommen (%d, feste IDs)", Count) end
    if Deaths > 0 then
        Log("%d Tier(e) beim Host gestorben: hier umgefallen", Deaths)
        Z.ANIMAL.MeatAt = os.clock() + 5
    end
end

-- Runde 3: Kopie fuer einen Tod-Eintrag (ahp2). 1. die gebundene Kopie, ohne Abstandsgrenze (frisch ueber
-- Z.LiveByName, ist sie schon tot: nichts weiter), 2. sonst die naechste Kopie derselben Klasse innerhalb MATCH (wie das
-- alte Z.AnimalApply, auch eine schon tote: dann nichts weiter), 3. sonst die naechste lebende innerhalb DEATH_NEAR -
-- 2./3. nicht, wenn diese Id hier schon umgefallen ist (der Host wiederholt den Tod 3x). Gewaehlte Kopie wird an die Id
-- gebunden. Lage einer Kopie bei ~0,0,0: die des Mesh.
function Z.AnimalDeathTarget(Id, X, Y, Zc, Class)
    if not (Id and X and Y and Zc) then return nil end
    local A0, Now = Z.ANIMAL, os.clock()
    local B = Z.Bound[Id]
    local Obj = B and Z.LiveByName(B.Name, Class)
    if Obj then A0.DeadDone[Id] = Now return Obj end
    if Now - (A0.DeadDone[Id] or -math.huge) < 30 then return nil end
    local Pool = Z.PoolList()
    local List = Pool.Classes[Class] and Pool.List or Z.ExtraList(Class)
    local Best, BestD, Near, NearD = nil, A0.DEATH_NEAR ^ 2, nil, Z.MATCH * Z.MATCH
    for _, E in ipairs(List) do
        if E.Class == Class then
            local L = E.L
            if math.abs(L.X) + math.abs(L.Y) + math.abs(L.Z) < 1 then
                L = Safe(function() local M = E.Char.Mesh return IsAlive(M) and M:K2_GetComponentLocation() or nil end) or L
            end
            local D = (L.X - X) ^ 2 + (L.Y - Y) ^ 2 + (L.Z - Zc) ^ 2
            if D < NearD then Near, NearD = E, D end
            if not E.Dead and D < BestD then Best, BestD = E, D end
        end
    end
    if Near then Best, BestD = Near, NearD end   -- innerhalb MATCH gewinnt die naechste, lebend oder tot
    if not (Best and IsAlive(Best.Char)) then
        if not A0.MissLogged then A0.MissLogged = true Log("Tier-Tod Id %d (%s): keine lebende Kopie innerhalb %.0f m", Id, Class, A0.DEATH_NEAR / 100) end
        return nil
    end
    Z.Bind(Id, Best.Char, Best.Name, X, Y, Zc)
    A0.DeadDone[Id] = Now
    if (A0.FarLogged or 0) < 5 and BestD > Z.MATCH * Z.MATCH then
        A0.FarLogged = (A0.FarLogged or 0) + 1
        Log("Tier-Tod Id %d: Kopie %s %.1f m vom Host-Ort (ueber MATCH)", Id, Best.Name, math.sqrt(BestD) / 100)
    end
    return Best.Char
end

-- Alte Tier-Meldung (ahp, ohne Id): hier schon ein Tod nahe dieser Stelle (2 m, 30 s)? Nur Zahlen gemerkt.
function Z.RecentDeathAt(X, Y, Zc)
    local Now, Keep = os.clock(), {}
    local Hit = false
    for _, E in ipairs(Z.ANIMAL.DeadAt or {}) do
        if Now - E[4] < 30 then
            Keep[#Keep + 1] = E
            if (E[1] - X) ^ 2 + (E[2] - Y) ^ 2 + (E[3] - Zc) ^ 2 < 200 * 200 then Hit = true end
        end
    end
    Z.ANIMAL.DeadAt = Keep
    return Hit
end

function Z.NoteDeathAt(X, Y, Zc)
    local List = Z.ANIMAL.DeadAt or {}
    if #List < 50 then List[#List + 1] = { X, Y, Zc, os.clock() } end
    Z.ANIMAL.DeadAt = List
end

function Z.Reset()
    Z.HostHp, Z.Before, Z.Logged, Z.ClientMode = {}, {}, nil, nil
    Z.LOOK.Paths, Z.LOOK.Alive, Z.LOOK.Unrad, Z.LOOK.Pending, Z.LOOK.Logged = {}, {}, {}, {}, nil
    Z.ANIMAL.Logged = nil
    -- Runde 3: nur Mitspieler-Tabellen (Ids/Zahlen); DeathFor (Host, nur Namen) nicht: Z.Reset laeuft beim Host jede Sekunde
    if next(Z.ANIMAL.DeadDone) or Z.ANIMAL.DeadAt then Z.ANIMAL.DeadDone, Z.ANIMAL.DeadAt = {}, nil end
    -- hp_v2 (nur Mitspieler-Zustand; laeuft auch beim Host jede Sekunde, darum kein Host-Register hier)
    if SETTINGS.hp_v2 then
        if next(Z.Bound) or next(Z.BoundBy) then Z.Bound, Z.BoundBy = {}, {} end
        if next(Z.Extra) then Z.Extra = {} end
        Z.Pool, Coop.HostProto = nil, nil
        Z.HELLO.At, Z.HELLO.FirstAt, Z.HELLO.Sent, Z.HELLO.Note = nil, nil, 0, nil
        if Coop.Car then Coop.Car.HostFps = nil end
    end
end

Coop.Zombies = Z
end

do
-- Verbindungsabbruch (Absturz, Internet weg, Spiel hart beendet): Der Host merkt das erst nach dem
-- Verbindungs-Timeout. Bis dahin stand die Figur weiter in der Welt (lief beim anderen weiter), Zombies
-- toeteten sie und die Ausruestung war weg. Jeder Mitspieler meldet sich darum jede Sekunde (hb); bleibt das
-- QUIET s aus, friert der Host seine Figur ein und macht sie unverwundbar, bis er sich wieder meldet.
-- Mitspieler mit aelterer Mod-Version melden sich nie: fuer sie bleibt alles wie bisher.
Coop.Link = { QUIET = 3, Beat = {}, Frozen = {} }   -- Beat: [Controller] = Zeit, Frozen: [Controller] = Zustand

-- Server weg (gestoppt, abgestuerzt, Verbindung verloren): Unreal wirft den Mitspieler ins Hauptmenue
-- (Titelbild). Dann automatisch den eigenen Spielstand laden wie mit "Continue" (Titelbild weg, Menue
-- abwarten, Continue druecken). Erkannt am Wechsel Client -> Standalone (ein sauberer Server-Stopp meldet
-- keinen Netzwerkfehler) und am Netzwerkfehler. Nicht beim freiwilligen Verlassen: "Hauptmenue" im
-- Pausen-/Tod-Bildschirm ruft SD_GameInstance:Event_LoadLevel("MainMenu") (VoluntaryAt).
-- Ausserdem merkt der Mitspieler einen abgestuerzten Server nach 20 s statt 60 s (ConnectionTimeout).
Coop.Home = { GIVE_UP = 120, TIMEOUT = 20, VOLUNTARY_FOR = 300, Pending = nil, WasClient = false, VoluntaryAt = nil,
              LOST = { [3] = true, [4] = true, [5] = true },   -- ConnectionLost, ConnectionTimeout, FailureReceived
              GI = "/Game/Blueprints/SD_GameInstance.SD_GameInstance_C",
              CONTINUE = "BndEvt__MenuWidget_ContinueGame_K2Node_ComponentBoundEvent_25_OnButtonClickedEvent__DelegateSignature" }

-- Das Spiel ruft Event_LoadLevel("MainMenu") auch selbst beim Beitritt (0,4 s nach dem Verbinden): erst nach
-- 15 s auf dem Server zaehlt es als freiwilliges Verlassen
function Coop.Home.OnLoadLevel(Level)
    local Since = Coop.Home.ClientSince
    if NetModeName(CurrentWorld()) == "Client" and Since and os.time() - Since >= 15 and tostring(Level):find("MainMenu") then
        -- Hauptmenue und Spiel sind dieselbe Karte: das Menue stand sonst ueber der Server-Welt samt Figur.
        -- Darum gleich richtig trennen (disconnect laedt die Karte neu, ohne Server).
        Coop.Home.VoluntaryAt, Coop.Home.DisconnectAt = os.time(), os.time() + 1
        Log("Mitspieler verlaesst den Server selbst (Hauptmenue): trenne, eigener Spielstand wird nicht automatisch geladen")
    end
end

-- Knopf LEAVE SERVER (Journal, Reiter SERVER): trennen und sofort den eigenen Spielstand laden
function Coop.Home.Leave()
    if NetModeName(CurrentWorld()) ~= "Client" then return end
    Coop.Home.VoluntaryAt, Coop.Home.DisconnectAt = nil, nil
    Log("Mitspieler verlaesst den Server (LEAVE): lade danach den eigenen Spielstand")
    RunCommand("disconnect")
end

function Coop.Home.OnNetworkError(Type)
    if not (Coop.Home.WasClient and Coop.Home.LOST[Type]) then return end
    Coop.Home.Pending = os.time()
    Log("Verbindung zum Server verloren: lade gleich den eigenen Spielstand")
end

-- Jede Sekunde in der Hauptschleife
function Coop.Home.Tick(World, Mode)
    local H = Coop.Home
    if not H.Hooked and IsAlive(StaticFindObject(H.GI)) then
        H.Hooked = true
        TryHook(H.GI .. ":Event_LoadLevel", function(_, Level)
            pcall(function()
                local V = Level:get()
                Coop.Home.OnLoadLevel(type(V) == "string" and V or Safe(function() return V:ToString() end, tostring(V)))
            end)
        end)
    end
    if Mode == "Client" then
        if not H.WasClient then H.ClientSince = os.time() end
        H.WasClient = true
        local Driver = World.NetDriver
        if IsAlive(Driver) and Driver.ConnectionTimeout ~= H.TIMEOUT then Driver.ConnectionTimeout = H.TIMEOUT end
        if H.DisconnectAt and os.time() >= H.DisconnectAt then
            H.DisconnectAt = nil
            RunCommand("disconnect")
        end
        return
    end
    -- Client-Modus eben verlassen: freiwillig (Hauptmenue-Knopf kurz vorher) oder Server weg
    if H.WasClient and Mode == "Standalone" then
        H.WasClient = false
        if H.VoluntaryAt and os.time() - H.VoluntaryAt < H.VOLUNTARY_FOR then
            H.VoluntaryAt = nil
        elseif not H.Pending then
            H.Pending = os.time()
            Log("Verbindung zum Server beendet: lade gleich den eigenen Spielstand")
        end
    end
    if Mode ~= "Standalone" or not H.Pending then H.WasClient = Mode == "Client" return end
    if os.time() - H.Pending > H.GIVE_UP then
        H.Pending, H.WasClient = nil, false
        Log("Eigenen Spielstand nicht geladen: Hauptmenue kam nicht")
        return
    end
    -- Titelbild ("Press any key") weg, wie beim Server (server.lua DismissTitle)
    for _, W in ipairs(FindAllOf("PressAnyKeyWidget_C") or {}) do
        if IsAlive(W) and W:IsInViewport() then
            pcall(function() W:RemoveFromParent() end)
            local Level = FindFirstOf("MainMenu_C")
            if IsAlive(Level) then pcall(function() Level:Event_KeyDown() end) end
            return
        end
    end
    local Menu = FindFirstOf("MenuWidget_C")
    if IsAlive(Menu) and Menu:IsInViewport() and ReadyToTravel() then
        H.Pending, H.WasClient = nil, false
        local ok, err = pcall(function() Menu[H.CONTINUE](Menu) end)
        Log("Eigener Spielstand wird geladen (Continue)%s", ok and "" or (": Fehler " .. tostring(err)))
    end
end

function Coop.Link.OnBeat(PC, Data)
    local Key = PC:GetFullName()
    Coop.Link.Beat[Key] = os.time()
    -- Steam-ID des Spielers (liest die DLL aus Steam): nur fuer Bans und die Spielerliste der Konsole
    if Data and Data:match("^%d+$") and #Data >= 15 then Coop.SteamIds[Key] = Data end
end
Coop.SteamIds = {}   -- [Controller-Key] = SteamID64 (vom Spieler gemeldet, nicht geprueft)

function Coop.Link.ClientTick()
    local L = Coop.Link
    if not L.SteamId and os.time() >= (L.SteamCheckAt or 0) then
        L.SteamCheckAt = os.time() + 10
        local File = io.open(MOD_DIR .. "netcore_steamid.txt", "r")
        if File then L.SteamId = (File:read("*l") or ""):match("^(%d+)") File:close() end
    end
    Coop.SendChunked(Coop.SendToHost, "hb", L.SteamId or "1")
end

-- Hinweis oben im Bild (wie "Spiel gespeichert"), ueber die eigene Figur (BPI_Player:CreateNotificationUI).
-- Der Server schickt solche Hinweise (note): Admin-Nachrichten, Kick-Grund, Ergebnis von Admin-Befehlen.
Coop.NOTE_ICON = "/Game/UI/Textures/over_250_survival_flat_icons/radio.radio"
function Coop.ShowNote(Text)
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) then return end
    local Icon = StaticFindObject(Coop.NOTE_ICON)
    if not IsAlive(Icon) then Icon = Safe(function() return LoadAsset(Coop.NOTE_ICON) end) end
    Pawn:CreateNotificationUI(FText(Text), Icon, { R = 1, G = 1, B = 1, A = 1 }, 6.0)
end

Coop.HostDataHandlers.note = function(Text)
    Log("Hinweis vom Server: %s", Text)
    ExecuteInGameThread(function() pcall(Coop.ShowNote, Text) end)
end

-- Fuer andere Stellen (Spawn-Schutz des Servers): Ist die Figur gerade eingefroren, den Schaden-Wert erst
-- beim Freigeben setzen
function Coop.Link.Defer(Pawn, CanBeDamaged)
    for _, F in pairs(Coop.Link.Frozen) do
        if F.Pawn == Pawn then F.Damage = CanBeDamaged return true end
    end
    return false
end

function Coop.Link.HostTick(Key, Pawn, Now)
    local L, Last = Coop.Link, Coop.Link.Beat[Key]
    local F = L.Frozen[Key]
    if F and F.Pawn ~= Pawn then L.Frozen[Key], F = nil, nil end   -- andere Figur (Respawn)
    if not Last then return end
    local Name = Pawn:GetFName():ToString()
    if Now - Last >= L.QUIET then
        if F then
            -- PLAYER-13 (pvp_hbdmg): Kampf-Markierung abgelaufen -> jetzt wie sonst unverwundbar
            if F.KeepDmg and not Coop.InCombat(Name, "pvp_hbdmg", true) then
                F.KeepDmg = nil
                pcall(function() Pawn.bCanBeDamaged = false end)
                Log("Mitspieler-Figur %s: Kampf vorbei, jetzt unverwundbar", Name)
            end
            return
        end
        local Riding = IsAlive(Pawn:GetAttachParentActor())   -- im Fahrzeug: Sitz nicht anfassen
        -- PLAYER-13 (pvp_hbdmg): wer im PvP-Kampf (Treffer eines anderen Spielers < pvp_logout_s) das Lebenszeichen
        -- abreisst, wird eingefroren, bleibt aber verwundbar (sonst Unverwundbarkeit per Kabelziehen)
        local Keep = Coop.InCombat(Name, "pvp_hbdmg", true)
        L.Frozen[Key] = { Pawn = Pawn, Damage = Pawn.bCanBeDamaged, Riding = Riding, KeepDmg = Keep or nil }
        if not Keep then pcall(function() Pawn.bCanBeDamaged = false end) end
        if not Riding then
            pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:StopMovementImmediately() end end)
            pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:DisableMovement() end end)
        end
        Log("Mitspieler-Figur %s: seit %d s kein Lebenszeichen, eingefroren und %s", Name, Now - Last,
            Keep and "verwundbar (im Kampf, pvp_hbdmg)" or "unverwundbar")
    elseif F then
        L.Frozen[Key] = nil
        pcall(function() Pawn.bCanBeDamaged = F.Damage end)
        if not F.Riding then pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:SetMovementMode(3, 0) end end) end   -- Falling
        -- E23 (move_check): die Position springt beim Freigeben auf den Stand des Gasts, keine Verletzung
        Coop.TrustSkip = Coop.TrustSkip or {}
        Coop.TrustSkip[Key] = os.clock() + 5
        Log("Mitspieler-Figur %s: meldet sich wieder, freigegeben", Name)
    end
end

-- Netzwerkfehler (Verbindung verloren/Timeout) als Mitspieler: eigenen Spielstand laden. Hier statt beim
-- Hook oben in der Datei registriert: dort ist Coop noch nicht sichtbar (local Coop steht weiter unten).
TryHook("/Script/Engine.GameInstance:HandleNetworkError", function(_, FailureType)
    pcall(function() Coop.Home.OnNetworkError(FailureType:get()) end)
end)
end

do
-- Tab "Server Liste" im Journal (J): Die Master-Liste (master_url.txt im Mod-Ordner, schreibt der Installer)
-- nennt die laufenden Last-Signal-Server, die DLL holt sie und pingt jeden Server direkt (Dateien
-- netcore_list_req/_ping_req, siehe NetTestCore.cpp). Die Adressen kommen verschleiert an und werden nur zum
-- Beitreten im Speicher entschluesselt: im Spiel, im Log und in Dateien steht keine IP.
-- Aussehen wie das Journal selbst (Kopien seiner Widgets, siehe Setup); Klicks ueber die linke Maustaste
-- (Keybind) und IsHovered, die drei Journal-Reiter blenden die Liste wieder aus.
Coop.List = {
    CODE = "LastSignal-1", MAX_ROWS = 12, MAX_CELLS = 7, LIST_TIMEOUT = 8,
    -- Texte im Spiel auf Englisch (internationale Spieler), das Log bleibt deutsch. Reiter unter "Quests",
    -- je eine Stufe tiefer; ADMIN nur fuer Admins des Servers.
    TABS = { { Mode = "servers", Text = "SERVER", Color = { R = 0.35, G = 0.85, B = 0.35, A = 1 } },
             { Mode = "admin", Text = "ADMIN", Color = { R = 0.7, G = 0.4, B = 1, A = 1 } } },
    TITLES = { servers = "SERVER LIST", admin = "ADMIN" },
    Tabs = {}, Players = {}, IsAdmin = false,
    HIDE = { "ClockOverlay", "PlayerOverlay", "DaysDistanceOverlay", "ZombiesKilled", "BossZombiesKilled",
             "HumansKilled", "AnimalsKilled", "InfestationsDestroyed" },   -- Inhalt der Info-Seite
    JOURNAL = "/Game/UI/Widgets/Journal/JournalUI.JournalUI_C",
    JOURNAL_TABS = { "BndEvt__InfoSkillQuestUI_Button_56_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature",
                     "BndEvt__JournalUI_Test_QuestsButton_K2Node_ComponentBoundEvent_6_OnButtonClickedEvent__DelegateSignature",
                     "BndEvt__JournalUI_Test_SkillsButton_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature" },
    PAGES = { "Journal_InfoUI", "Journal_QuestsUI", "Journal_SkillsUI" },
    Journal = nil, Rows = {}, Servers = {}, Hidden = {},
    Mode = nil, ListSince = nil, PingSince = nil, Status = "",
    MAX_SERVERS = 7, Extra = {}, Typing = nil, ShowId = false,   -- Serverliste: Auswahl, Passwort/Adresse, eigene ID
}

function Coop.List.Decode(Text)
    local Alphabet, Value, Bits, Bytes = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 0, 0, {}
    for C in Text:gmatch("[%w%+/]") do
        Value = ((Value << 6) | (Alphabet:find(C, 1, true) - 1)) & 0xFFFFFF
        Bits = Bits + 6
        if Bits >= 8 then
            Bits = Bits - 8
            Bytes[#Bytes + 1] = (Value >> Bits) & 0xFF
        end
    end
    local Code = Coop.List.CODE
    for I = 1, #Bytes do Bytes[I] = string.char(Bytes[I] ~ Code:byte((I - 1) % #Code + 1)) end
    return table.concat(Bytes)
end

function Coop.List.B64(Text)
    local Alphabet, Value, Bits, Bytes = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 0, 0, {}
    for C in Text:gmatch("[%w%+/]") do
        Value = ((Value << 6) | (Alphabet:find(C, 1, true) - 1)) & 0xFFFFFF
        Bits = Bits + 6
        if Bits >= 8 then Bits = Bits - 8 Bytes[#Bytes + 1] = string.char((Value >> Bits) & 0xFF) end
    end
    return table.concat(Bytes)
end

function Coop.List.MasterUrl()
    local File = io.open(MOD_DIR .. "master_url.txt", "r")
    local Url = File and (File:read("*l") or ""):match("^%s*(%S+)")
    if File then File:close() end
    return Url and Url:gsub("/+$", "") or nil
end

-- Kopie eines vorhandenen Widgets (gleiche Schrift, Farbe, Drehung): StaticConstructObject mit Vorlage.
-- Name 0 = automatisch (nie ein fester Name: ein Namenskonflikt im selben Outer kann das Spiel abstuerzen lassen).
function Coop.List.Copy(Template, Outer)
    return StaticConstructObject(Template:GetClass(), Outer, 0, 0, 0, false, false, Template, nil, nil)
end

function Coop.List.Vec(V) return { X = V.X, Y = V.Y } end

-- Unsichtbarer Knopf mit einer Text-Kopie darin (wie die Reiter des Journals). Ein reiner Text meldet die Maus
-- nicht zuverlaessig (IsHovered nur kurz nach einem Klick, ein Klick reichte nicht), ein Knopf schon. Neu
-- gebaut statt kopiert: eine Kopie von QuestsButton haette dessen Klick-Bindung und Slot-Objekte geerbt.
function Coop.List.NewButton(Outer, TextTemplate, Text)
    local Button = StaticConstructObject(StaticFindObject("/Script/UMG.Button"), Outer, 0, 0, 0, false, false, nil, nil, nil)
    -- Stil vor dem ersten Anzeigen: normal unsichtbar, unter der Maus/gedrueckt ein schwarzer Rahmen (RoundedBox
    -- mit Umriss). Klappt das nicht, bleibt der Knopf einfach unsichtbar (Hintergrundfarbe transparent).
    local Styled = pcall(function()
        local Style = Button.WidgetStyle
        Style.Normal.DrawAs = 0   -- NoDrawType
        for _, State in ipairs({ "Hovered", "Pressed" }) do
            local Brush = Style[State]
            Brush.DrawAs = 4      -- RoundedBox
            Brush.TintColor = { SpecifiedColor = { R = 0, G = 0, B = 0, A = State == "Pressed" and 0.15 or 0 }, ColorUseRule = 0 }
            Brush.OutlineSettings = { CornerRadii = { X = 6, Y = 6, Z = 6, W = 6 },
                                      Color = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 1 }, ColorUseRule = 0 },
                                      Width = 2, RoundingType = 0, bUseBrushTransparency = false }
        end
    end) and Safe(function() return Button.WidgetStyle.Normal.DrawAs == 0 end, false)
    if not Styled then Button:SetBackgroundColor({ R = 0, G = 0, B = 0, A = 0 }) end
    if not Coop.List.StyleLogged then
        Coop.List.StyleLogged = true
        Log("Journal: Hover-Rahmen %s", Styled and "aktiv" or "nicht moeglich (Knoepfe unsichtbar)")
    end
    local Label = Coop.List.Copy(TextTemplate, Outer)
    Label:SetText(FText(Text))
    Button:SetContent(Label)
    return Button, Label
end

-- Widget per Name im Baum eines UserWidgets suchen. Die meisten Journal-Teile sind keine Blueprint-Variablen
-- (Info.Text = nil) und GetWidgetFromName ist aus Lua nicht aufrufbar (TrivialObject): Baum durchlaufen.
function Coop.List.Find(UserWidget, Name)
    local function Walk(W, Depth)
        if not IsAlive(W) or Depth > 8 then return nil end
        if W:GetFName():ToString() == Name then return W end
        local Count = Safe(function() return W:GetChildrenCount() end)
        if type(Count) == "number" then
            for K = 0, Count - 1 do
                local Hit = Walk(Safe(function() return W:GetChildAt(K) end), Depth + 1)
                if Hit then return Hit end
            end
        end
        return nil
    end
    return Walk(Safe(function() local Tree = IsAlive(UserWidget) and UserWidget.WidgetTree return IsAlive(Tree) and Tree.RootWidget or nil end), 0)
end

-- Reiter, Markierungen und Zeilen ins Journal einbauen (einmal je Journal-Widget). Vorbild ist das Journal:
-- Seine Reiter sind unsichtbare Knoepfe mit schwarzem Text, die Farbe kommt von Markierungs-Bildern auf jeder
-- Seite (QuestMarker usw.). Als Seite dient die Info-Seite: ihr Inhalt wird ausgeblendet, die Ueberschrift
-- wechselt ("SERVER LIST", "ADMIN"), die Zeilen sind Reihen von Knoepfen mit Kopien ihrer Handschrift-Texte.
-- Nach einem Kartenwechsel (Beitritt, Trennen) sind die alten Journal-Widgets weg: Verweise darauf nie mehr
-- anfassen (Absturz 0xffffffffffffffff beim Beitritt, als "admin" vom Server den alten Reiter aenderte)
function Coop.List.Valid()
    local L = Coop.List
    if not L.Journal then return false end
    -- world_hygiene (CORE-8 e): die Welt-Adresse kann sich nach LoadMap wiederholen -> zuerst die Welt-Generation
    -- vergleichen, bevor irgendein gemerktes Widget angefasst wird
    local NewWorld = L.Gen ~= WorldGen.N and WorldGen.Hygiene ~= false
    if NewWorld or Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end) ~= L.WorldAddr or not IsAlive(L.Journal) then
        L.Forget(NewWorld)
        L.Status = ""   -- "Connecting ..."/"Leaving ..." gelten nur bis zum Kartenwechsel
        return false
    end
    return true
end

-- NewWorld (world_hygiene): Weltwechsel -> auch Eingabefeld und HUD-Merker vergessen (I.Poll fasst L.Input als Erstes
-- an); ohne (neues HUD nach Respawn) bleibt das Eingabefeld wie bisher, FinishTyping stellt die Steuerung zurueck
function Coop.List.Forget(NewWorld)
    local L = Coop.List
    L.Journal, L.Rows, L.Tabs, L.Mode, L.Hidden, L.InfoMarker, L.Header, L.HudAddr = nil, {}, {}, nil, {}, nil, nil, nil
    if NewWorld then L.Input, L.InputBox, L.Typing, L.ViewHudW, L.ViewHudAt = nil, nil, nil, nil, nil end
end

-- HUD im Bild (BP_Ingame_C, enthaelt das Journal); nil z. B. im Hauptmenue
-- Ohne Multiplayer (Solo, Hauptmenue) nur alle 5 s suchen (FindAllOf), dazwischen das letzte Ergebnis
function Coop.List.ViewHud()
    local L, Now = Coop.List, os.clock()
    if not MultiplayerActive and L.ViewHudAt and Now - L.ViewHudAt < 5 and (L.ViewHudW == nil or IsAlive(L.ViewHudW)) then
        return L.ViewHudW
    end
    L.ViewHudAt, L.ViewHudW = Now, nil
    for _, W in ipairs(FindAllOf("BP_Ingame_C") or {}) do
        if IsAlive(W) and Safe(function() return W:IsInViewport() end, false) then L.ViewHudW = W return W end
    end
    return nil
end

-- Zu welchem HUD gehoert ein Journal? (Outer = WidgetTree des HUDs, dessen Outer = das HUD)
function Coop.List.HudOf(J) return Safe(function()
    local Tree = IsAlive(J) and J:GetOuter()
    local Hud = IsAlive(Tree) and Tree:GetOuter()
    return IsAlive(Hud) and Hud:GetAddress() or nil
end) end

function Coop.List.Setup()
    local L = Coop.List
    -- Nach Tod und Respawn baut das Spiel ein neues HUD samt Journal: dann dort neu einbauen (sonst fehlte der
    -- Reiter bis zum Neustart des Spiels)
    local Hud = L.ViewHud()
    local HudAddr = Hud and Hud:GetAddress()
    if L.Valid() and L.Tabs.servers and IsAlive(L.Tabs.servers.Button) then
        if not HudAddr or HudAddr == L.HudAddr then return end
        -- eingebaut, als kein HUD im Bild war: gleiches Journal, nur merken (sonst doppelte Reiter)
        if L.HudOf(L.Journal) == HudAddr then L.HudAddr = HudAddr return end
    end
    if L.Journal then
        Log("Journal: neues HUD (Respawn), Reiter neu einbauen")
        L.Forget()
    end
    -- Das Journal mit fertigem Widget-Baum (es gibt auch Exemplare ohne Inhalt, z. B. Vorlagen), bevorzugt das im Bild
    local J, Header, Row
    for Pass = 1, 2 do
        for _, Candidate in ipairs(FindAllOf("JournalUI_C") or {}) do
            local Info = IsAlive(Candidate) and Safe(function() return Candidate.Journal_InfoUI end)
            local TabText = IsAlive(Candidate) and Safe(function() return Candidate.QuestsText end)
            if IsAlive(Info) and IsAlive(TabText) and (Pass == 2 or not HudAddr or L.HudOf(Candidate) == HudAddr) then
                Header, Row = L.Find(Info, "Text"), L.Find(Info, "ZombiesKilled")
                if IsAlive(Header) and IsAlive(Row) then J = Candidate break end
            end
        end
        if J then break end
    end
    if not J then return end
    -- Teile, an denen unten Methoden aufgerufen werden, vor dem Einbau pruefen (ungueltig = Absturz, kein pcall hilft)
    if not (IsAlive(J.QuestsButton) and IsAlive(Safe(function() return J.QuestsButton:GetParent() end))
        and IsAlive(Safe(function() return Row:GetParent() end)) and IsAlive(Safe(function() return Row:GetChildAt(0) end))) then
        return
    end
    local Info = J.Journal_InfoUI
    L.Journal, L.Info, L.Header, L.Rows, L.Mode, L.Hidden, L.Tabs = J, Info, Header, {}, nil, {}, {}
    L.Input, L.InputBox, L.Typing = nil, nil, nil
    L.WorldAddr = Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end)
    L.Gen = WorldGen.N   -- world_hygiene: Welt-Generation des Einbaus (Coop.List.Valid)
    L.HudAddr = HudAddr
    -- Abstand der Reiter (Overlay-Padding Skills -> Quests: 18 nach links, 161 nach unten); die Markierungen
    -- sind ganzseitige Bilder (1920x1080) mit dem Reiter an seiner Stelle und werden genauso verschoben
    local Step = Safe(function()
        local QS, SS = J.QuestsButton.Slot, IsAlive(J.SkillsButton) and J.SkillsButton.Slot
        if not (IsAlive(QS) and IsAlive(SS)) then error("kein Slot") end
        local QB, SB = QS.Padding, SS.Padding
        return { X = QB.Left - SB.Left, Y = SB.Bottom - QB.Bottom }
    end, { X = -18, Y = 161 })
    local Base = Safe(function()
        local QS = J.QuestsButton.Slot
        if not IsAlive(QS) then error("kein Slot") end
        local P = QS.Padding
        return { Left = P.Left, Bottom = P.Bottom }
    end, { Left = 112, Bottom = -125 })
    local Angle = Safe(function() return J.QuestsButton.RenderTransform.Angle end, -80)
    local Overlay = J.QuestsButton:GetParent()
    for Index, Def in ipairs(L.TABS) do
        local Tab = { Mode = Def.Mode, Markers = {} }
        Tab.Button = L.NewButton(J.WidgetTree, J.QuestsText, Def.Text)
        local Slot = Overlay:AddChildToOverlay(Tab.Button)
        Slot:SetHorizontalAlignment(2)
        Slot:SetVerticalAlignment(2)
        Slot:SetPadding({ Left = Base.Left + Step.X * Index, Top = 0, Right = 0, Bottom = Base.Bottom - Step.Y * Index })
        Tab.Button:SetRenderTransformAngle(Angle)
        for _, PageName in ipairs(L.PAGES) do
            local ok, err = pcall(function()
                local Page = J[PageName]
                local Q = L.Find(Page, "QuestMarker")
                local QS = Q.Slot
                local Canvas = Q:GetParent()
                if not (IsAlive(QS) and IsAlive(Canvas)) then error("QuestMarker ohne Slot/Eltern") end
                local M = L.Copy(Q, Page.WidgetTree)
                local MS = Canvas:AddChildToCanvas(M)
                local A = QS:GetAnchors()
                MS:SetAnchors({ Minimum = L.Vec(A.Minimum), Maximum = L.Vec(A.Maximum) })
                MS:SetAlignment(L.Vec(QS:GetAlignment()))
                MS:SetSize(L.Vec(QS:GetSize()))
                local QP = QS:GetPosition()
                MS:SetPosition({ X = QP.X + Step.X * Index, Y = QP.Y + Step.Y * Index })
                MS:SetZOrder(-1)   -- unter das Seitenbild, wie die anderen
                M:SetColorAndOpacity(Def.Color)
                Tab.Markers[#Tab.Markers + 1] = M
                -- Auf der Info-Seite (unserer Seite): "ausgewaehlt" = ueber dem Seitenbild
                if PageName == "Journal_InfoUI" then Tab.InfoSlot = MS end
            end)
            if not ok then Log("Journal: Markierung auf %s fehlt: %s", PageName, tostring(err)) end
        end
        L.Tabs[Def.Mode] = Tab
    end
    L.InfoMarker = L.Find(Info, "InfoMarker")
    L.UpdateAdminTab()
    -- Seite: was auf der Info-Seite verschwindet; Zeilen (Knopf-Reihen) in ihre Statistik-Liste
    for _, Name in ipairs(L.HIDE) do
        local W = L.Find(Info, Name)
        if IsAlive(W) then L.Hidden[#L.Hidden + 1] = W end
    end
    local Box = Row:GetParent()
    local Template = Row:GetChildAt(0)
    local Padding = Safe(function()
        local P = Row.Slot.Padding
        return { Left = P.Left, Top = P.Top, Right = P.Right, Bottom = P.Bottom }
    end)
    -- Die Statistik-Liste steht mittig (StatsOverlay: HAlign_Center): jede breitere Zeile schob die ganze Liste
    -- nach links. Darum steckt jede Zeile in einer SizeBox mit fester Breite (= Breite der Original-Liste, siehe
    -- FixWidth); laengere Zeilen ragen nach rechts hinaus.
    L.StatsBox, L.RowPad = Box, Padding and (Padding.Left + Padding.Right) or 20
    local HBoxClass = StaticFindObject("/Script/UMG.HorizontalBox")
    local SizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    for I = 0, L.MAX_ROWS do
        local HBox = StaticConstructObject(HBoxClass, Info.WidgetTree, 0, 0, 0, false, false, nil, nil, nil)
        local Size = IsAlive(SizeBoxClass) and Safe(function()
            return StaticConstructObject(SizeBoxClass, Info.WidgetTree, 0, 0, 0, false, false, nil, nil, nil)
        end)
        local Outer = HBox
        if IsAlive(Size) and pcall(function() Size:SetContent(HBox) end) then Outer = Size else Size = nil end
        local Slot = Box:AddChildToVerticalBox(Outer)
        if Padding then pcall(function() Slot:SetPadding(Padding) end) end
        pcall(function() Slot:SetHorizontalAlignment(1) end)   -- links, wie die Statistik-Zeilen
        Outer:SetVisibility(1)
        if Size then HBox:SetVisibility(4) end
        local R = { Box = Outer, Size = Size, HBox = HBox, Cells = {} }
        for C = 1, L.MAX_CELLS do
            local Button, Label = L.NewButton(Info.WidgetTree, Template, "")
            local CellSlot = HBox:AddChildToHorizontalBox(Button)
            pcall(function() CellSlot:SetPadding({ Left = 0, Top = 0, Right = 20, Bottom = 0 }) end)
            Button:SetVisibility(1)
            R.Cells[C] = { Button = Button, Label = Label }
        end
        L.Rows[I] = R
    end
    -- Eingabefeld (Server-Passwort / Adresse) hinter dem Text der vorletzten Zeile, sonst unsichtbar
    local okIn, errIn = pcall(function()
        if not IsAlive(SizeBoxClass) then error("SizeBox-Klasse fehlt") end
        local SB = StaticConstructObject(SizeBoxClass, Info.WidgetTree, 0, 0, 0, false, false, nil, nil, nil)
        pcall(function() SB:SetWidthOverride(320) end)
        local Edit = StaticConstructObject(StaticFindObject("/Script/UMG.EditableTextBox"), Info.WidgetTree, 0, 0, 0, false, false, nil, nil, nil)
        pcall(function()
            local Style, White = Edit.WidgetStyle, { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }
            for _, Brush in ipairs({ "BackgroundImageNormal", "BackgroundImageHovered", "BackgroundImageFocused", "BackgroundImageReadOnly" }) do
                pcall(function() Style[Brush].TintColor = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 0.7 }, ColorUseRule = 0 } end)
            end
            Style.ForegroundColor, Style.FocusedForegroundColor = White, White
            pcall(function() Style.TextStyle.ColorAndOpacity = White end)
        end)
        pcall(function() Edit.RevertTextOnEscape = true Edit.ClearKeyboardFocusOnCommit = true end)
        SB:SetContent(Edit)
        L.Rows[L.MAX_ROWS - 1].HBox:AddChildToHorizontalBox(SB)
        SB:SetVisibility(1)
        L.Input, L.InputBox = Edit, SB
    end)
    if not okIn then Log("Journal: Eingabefeld fehlt: %s", tostring(errIn)) end
    if not L.Hooked then
        L.Hooked = true
        for _, Name in ipairs(L.JOURNAL_TABS) do
            TryHook(L.JOURNAL .. ":" .. Name, function()
                ExecuteInGameThread(function() pcall(Coop.List.Show, nil) end)
            end)
        end
    end
    Log("Journal: Reiter 'Server' und 'Admin' eingebaut")
end

-- Reiter ADMIN nur fuer Admins (der Server meldet es, "admin")
function Coop.List.UpdateAdminTab()
    local L = Coop.List
    local Tab = L.Valid() and L.Tabs.admin
    if not Tab then return end
    pcall(function() Tab.Button:SetVisibility(L.IsAdmin and 0 or 1) end)
    for _, M in ipairs(Tab.Markers) do pcall(function() M:SetVisibility(L.IsAdmin and 3 or 1) end) end
    if not L.IsAdmin and L.Mode == "admin" then L.Show(nil) end
end

-- Feste Zeilenbreite = Breite der Original-Statistik-Liste (einmal gemessen, solange nur sie sichtbar ist)
function Coop.List.FixWidth()
    local L = Coop.List
    if not L.Width then
        local W = Safe(function() return L.StatsBox:GetDesiredSize().X end, 0)
        if type(W) == "number" and W > 50 then
            L.Width = W - L.RowPad
            Log("Journal: Zeilenbreite %.0f", L.Width)
        end
    end
    if not L.Width then return end
    for I = 0, L.MAX_ROWS do
        local Size = L.Rows[I] and L.Rows[I].Size
        if Size then
            pcall(function()
                Size:SetMinDesiredWidth(L.Width)
                Size:SetMaxDesiredWidth(L.Width)
            end)
        end
    end
end

-- Seite zeigen (Mode "servers"/"admin": Info-Seite nach vorn, ihr Inhalt aus) oder verstecken (nil)
function Coop.List.Show(Mode)
    local L, J = Coop.List, Coop.List.Journal
    if not L.Valid() or L.Mode == Mode then return end
    local Was = L.Mode
    L.Mode = Mode
    if Mode and not Was then
        -- wie die Reiter des Spiels: die gewaehlte Seite nach vorn (Z-Reihenfolge)
        for _, PageName in ipairs(L.PAGES) do
            pcall(function() J[PageName].Slot:SetZOrder(PageName == "Journal_InfoUI" and 1 or 0) end)
        end
        L.HeaderText = Safe(function() return L.Header:GetText():ToString() end, L.HeaderText)
        L.FixWidth()
        L.Vis = {}
        for I, W in ipairs(L.Hidden) do
            L.Vis[I] = W:GetVisibility()
            W:SetVisibility(1)
        end
    elseif not Mode and Was then
        if L.HeaderText then L.Header:SetText(FText(L.HeaderText)) end
        for I, W in ipairs(L.Hidden) do
            if L.Vis and L.Vis[I] then W:SetVisibility(L.Vis[I]) end
        end
    end
    if Mode then L.Header:SetText(FText(L.TITLES[Mode])) end
    -- Markierung des gewaehlten Reiters vor, die anderen und die rote (Info) hinter das Seitenbild
    for M, Tab in pairs(L.Tabs) do pcall(function() Tab.InfoSlot:SetZOrder(Mode == M and 1 or -1) end) end
    pcall(function() L.InfoMarker.Slot:SetZOrder(Mode and -1 or 0) end)
    L.Render()
end

-- Linke Maustaste (Keybind): Welcher unserer Knoepfe liegt unter der Maus? (Falls der Klick noch nicht als
-- Hover ankam: bis zu drei Frames spaeter nachsehen.)
function Coop.List.OnMouse(Try)
    local L = Coop.List
    Try = Try or 0
    if not (L.Valid() and L.Journal:IsVisible()) then return end
    local Hit
    for Mode, Tab in pairs(L.Tabs) do
        if IsAlive(Tab.Button) and Tab.Button:IsVisible() and Tab.Button:IsHovered() then Hit = { Tab = Mode } break end
    end
    if not Hit and L.Mode then
        for I = 0, L.MAX_ROWS do
            for _, Cell in ipairs(L.Rows[I] and L.Rows[I].Cells or {}) do
                if Cell.Action and IsAlive(Cell.Button) and Cell.Button:IsVisible() and Cell.Button:IsHovered() then
                    Hit = Cell.Action
                    break
                end
            end
            if Hit then break end
        end
    end
    if not Hit and Try < 3 then
        ExecuteInGameThread(function() pcall(Coop.List.OnMouse, Try + 1) end)
        return
    end
    if Hit then L.Do(Hit) end
end

-- Kick/Ban erst nach einem zweiten Klick binnen 5 s ("CONFIRM ...")
function Coop.List.Do(Action)
    local L = Coop.List
    if Action.Tab then
        L.Show(Action.Tab)
        if Action.Tab == "servers" then L.Refresh() end
    elseif Action.Refresh then
        L.Refresh()
    elseif Action.Leave then
        L.Status = "Leaving ..."
        L.Render()
        Coop.Home.Leave()
    elseif Action.ChatKey then
        Coop.Chat.StartCapture()
        L.Render()
    elseif Action.Pick then
        L.SelServer = Action.Pick
        L.Render()
    elseif Action.Join then
        local S = L.Servers[Action.Join]
        if S and S.Locked then L.StartTyping("password") else L.Join(S) end
    elseif Action.ToggleId then
        L.ShowId = not L.ShowId
        L.Render()
    elseif Action.TypeAddress then
        L.StartTyping("address")
    elseif Action.Select then
        -- PLAYER-20 (admin_pid): PlayerId der Zeile mitmerken, damit eine Verschiebung der Nummern zwischen
        -- Auswahl und Klick (Spieler mit kleinerer Nummer trennt) nicht den falschen Spieler trifft
        L.Selected, L.SelectedPid, L.Armed = Action.Select, Action.Pid, nil
        L.Render()
    elseif Action.Admin and L.Selected then
        local Confirm = Action.Admin == "kick" or Action.Admin == "ban"
        if Confirm and not (L.Armed == Action.Admin and os.time() - (L.ArmedAt or 0) <= 5) then
            L.Armed, L.ArmedAt = Action.Admin, os.time()
        else
            L.Armed = nil
            -- PLAYER-20 (admin_pid, K34): Ziel per PlayerId (4. plist-Feld) statt der Listennummer, die sich bei jedem
            -- Beitritt/Trennen verschiebt; alte Server schicken kein 4. Feld -> weiter "#N".
            -- Bevorzugt die bei der Auswahl gemerkte PlayerId (L.SelectedPid); ist der Spieler schon weg, meldet der
            -- Server "pid:... ist nicht (mehr) online" und trifft niemanden sonst
            local Target = "#" .. L.Selected
            if Coop.FlagOn("admin_pid", true) then
                if L.SelectedPid then
                    Target = "pid:" .. L.SelectedPid
                else
                    for _, P in ipairs(L.Players or {}) do
                        if P.N == L.Selected and P.Pid then Target = "pid:" .. P.Pid break end
                    end
                end
            end
            Coop.SendChunked(Coop.SendToHost, "admin", Action.Admin .. " " .. Target)
        end
        L.Render()
    elseif Action.Cmd then
        Coop.SendChunked(Coop.SendToHost, "admin", Action.Cmd)
    end
end

function Coop.List.Refresh()
    local L, Url = Coop.List, Coop.List.MasterUrl()
    if not Url then L.Status = "No master list configured" L.Render() return end
    os.remove(MOD_DIR .. "netcore_list.txt")
    local File = io.open(MOD_DIR .. "netcore_list_req.txt", "w")
    if not File then return end
    File:write(Url .. "\n")
    File:close()
    L.ListSince, L.Status = os.time(), "Loading server list ..."
    L.Render()
end

function Coop.List.Join(S, Password)
    if not S then return end
    Coop.List.JoinAddress(Coop.List.Decode(S.Addr), S.Name, Password)
end

-- Beitreten (Liste oder von Hand eingegebene Adresse). Das Passwort bleibt nur im Speicher und geht nach dem
-- Verbinden an den Server ("auth", Tick unten), nie ins Log.
function Coop.List.JoinAddress(Address, Name, Password)
    local L = Coop.List
    local World = CurrentWorld()
    if NetModeName(World) ~= "Standalone" then L.Status = "Leave the current server first" L.Render() return end
    if not InOwnSave(World) then L.Status = "Load your own save first" L.Render() return end
    if Address:match("^[%w%.%-]+$") then Address = Address .. ":7777" end
    if not Address:match("^[%w%.%-]+:%d+$") then L.Status = "Invalid server address" L.Render() return end
    -- Nur beim Betreiber im selben Netz (Router ohne NAT-Loopback): address_override.txt, Zeilen "oeffentlich=lokal"
    local Override = io.open(MOD_DIR .. "address_override.txt", "r")
    if Override then
        for Line in Override:lines() do
            local From, To = Line:match("^%s*([%w%.%-]+:%d+)%s*=%s*([%w%.%-]+:%d+)")
            if From == Address then Address = To Log("Beitritt: Adresse aus address_override.txt") end
        end
        Override:close()
    end
    rawset(_G, "LastSignalJoin", { Address = Address, Name = Name })
    Coop.JoinPassword = (Password and Password ~= "") and Password or nil
    L.Status = "Connecting ..."   -- kurz: lange Zeilen verschieben die ganze Liste
    L.Render()
    ConnectToHost()
end

-- Eingabe im Journal (Passwort / Adresse): Feld zeigen, Tastatur hinein; fertig = Feld verliert den Fokus
-- (Enter; Esc leert es vorher = abbrechen), abgefragt in Coop.Input.Poll
function Coop.List.StartTyping(Kind)
    local L = Coop.List
    if not (IsAlive(L.Input) and IsAlive(L.InputBox)) then L.Status = "Input field not available" L.Render() return end
    L.Typing, L.TypingAt = Kind, os.clock()
    L.Input:SetText(FText(""))
    pcall(function() L.Input:SetIsPassword(Kind ~= "address") end)
    L.InputBox:SetVisibility(0)
    L.Render()
    pcall(function() Coop.Chat.WBL():SetInputMode_UIOnlyEx(LocalPC(), L.Input, 0, false) end)
    pcall(function() L.Input:SetKeyboardFocus() end)
end

function Coop.List.FinishTyping()
    local L = Coop.List
    local Kind, Text = L.Typing, Safe(function() return L.Input:GetText():ToString() end, "") or ""
    L.Typing = nil
    pcall(function() L.Input:SetText(FText("")) end)
    pcall(function() L.InputBox:SetVisibility(1) end)
    pcall(function() Coop.Chat.WBL():SetInputMode_GameAndUIEx(LocalPC(), nil, 0, false) end)   -- Journal bleibt bedienbar
    Text = Text:match("^%s*(.-)%s*$")
    if Kind == "address" then
        if Text ~= "" then L.PendingAddress = Text L.StartTyping("password_addr") return end
    elseif Kind == "password" then
        if Text ~= "" and L.SelServer then L.Join(L.Servers[L.SelServer], Text) return end
    elseif Kind == "password_addr" and L.PendingAddress then
        local Address = L.PendingAddress
        L.PendingAddress = nil
        L.JoinAddress(Address, "Direct", Text)   -- leeres Passwort = Server ohne Passwort
        return
    end
    L.PendingAddress = nil
    L.Render()
end

-- Inhalt der Seite: Zeilen aus Zellen { Text, Action } (Index 0 = oberste Zeile)
function Coop.List.View()
    local L, Rows = Coop.List, {}
    if L.Mode == "servers" then
        Rows[0] = { { Text = (L.Status ~= "" and L.Status or "Servers") .. "   -   refresh", Action = { Refresh = true } } }
        if NetModeName(CurrentWorld()) == "Client" then Rows[0][2] = { Text = "LEAVE SERVER", Action = { Leave = true } } end
        -- unterste Zeile: Chat-Taste (Klick, dann die neue Taste druecken)
        Rows[L.MAX_ROWS] = { { Text = Coop.Chat.Capture and "PRESS THE NEW CHAT KEY ...   (ESC = cancel)"
                                                      or ("CHAT KEY: " .. Coop.Chat.Key .. "   (click to change)"),
                               Action = { ChatKey = true } } }
        -- Server (Klick = auswaehlen), darunter Beschreibung und JOIN des ausgewaehlten
        for I, S in ipairs(L.Servers) do
            if I > L.MAX_SERVERS then break end
            local Ping = S.Ping == nil and "..." or (S.Ping < 0 and "-" or (S.Ping < 1 and "<1 ms" or (S.Ping .. " ms")))
            Rows[I] = { { Text = string.format("%s%s%s :   %d/%d   %s", I == L.SelServer and "> " or "",
                S.Locked and "[LOCKED] " or "", S.Name, S.Players, S.Max, Ping), Action = { Pick = I } } }
        end
        local Sel = L.SelServer and L.Servers[L.SelServer]
        if Sel then
            local Desc = Sel.Desc ~= "" and Sel.Desc or "No description"
            if utf8.len(Desc) and utf8.len(Desc) > 70 then Desc = Desc:sub(1, utf8.offset(Desc, 71) - 1) .. " ..." end
            Rows[L.MAX_SERVERS + 1] = { { Text = "   " .. Desc } }
            Rows[L.MAX_SERVERS + 2] = { { Text = Sel.Locked and "JOIN  (password)" or "JOIN", Action = { Join = L.SelServer } } }
        end
        -- Eigene Mitspieler-ID (fuer Admin-Rechte beim Betreiber), erst auf Klick sichtbar: sie wirkt wie ein Passwort
        Rows[L.MAX_ROWS - 2] = { { Text = L.ShowId and ("YOUR PLAYER ID: " .. tostring(Coop.OwnGuestId and Coop.OwnGuestId() or "?")
                                       .. "   (for admin rights - keep it secret)") or "YOUR PLAYER ID: ********   (click to show)",
                                   Action = { ToggleId = true } } }
        if L.Typing then
            Rows[L.MAX_ROWS - 1] = { { Text = L.Typing == "address" and "ADDRESS (ip:port):"
                                          or (L.Typing == "password_addr" and "PASSWORD (empty = none):" or "PASSWORD (Enter = OK, Esc = cancel):") } }
        else
            Rows[L.MAX_ROWS - 1] = { { Text = "JOIN BY ADDRESS   (click)", Action = { TypeAddress = true } } }
        end
    elseif L.Mode == "admin" then
        Rows[0] = { { Text = "PLAYERS ONLINE: " .. #L.Players } }
        local I = 0
        for _, P in ipairs(L.Players) do
            if I >= L.MAX_ROWS - 4 then break end
            I = I + 1
            Rows[I] = { { Text = string.format("%s#%d  %s   %d ms", P.N == L.Selected and "> " or "", P.N, P.Name, P.Ping),
                          Action = { Select = P.N, Pid = P.Pid } } }
        end
        if L.Selected then
            local function Button(Cmd, Label)
                local Armed = L.Armed == Cmd and os.time() - (L.ArmedAt or 0) <= 5
                return { Text = Armed and ("CONFIRM " .. Label) or Label, Action = { Admin = Cmd } }
            end
            I = I + 1
            Rows[I] = { Button("goto", "GO TO"), Button("bring", "BRING HERE"), Button("kick", "KICK"), Button("ban", "BAN") }
        end
        I = I + 1
        Rows[I] = { { Text = "TIME:" }, { Text = "6:00", Action = { Cmd = "time 6" } }, { Text = "12:00", Action = { Cmd = "time 12" } },
                    { Text = "18:00", Action = { Cmd = "time 18" } }, { Text = "0:00", Action = { Cmd = "time 0" } } }
        I = I + 1
        Rows[I] = { { Text = "WEATHER:" }, { Text = "CLEAR", Action = { Cmd = "weather clear" } },
                    { Text = "CLOUDY", Action = { Cmd = "weather cloudy" } }, { Text = "RAIN", Action = { Cmd = "weather rain" } } }
        I = I + 1
        Rows[I] = { { Text = "WEATHER:" }, { Text = "STORM", Action = { Cmd = "weather storm" } },
                    { Text = "FOG", Action = { Cmd = "weather fog" } }, { Text = "SNOW", Action = { Cmd = "weather snow" } } }
    end
    return Rows
end

function Coop.List.Render()
    local L = Coop.List
    if not L.Valid() or not L.Rows[0] then return end
    local View = L.Mode and L.View() or {}
    for I = 0, L.MAX_ROWS do
        local Row, Cells = L.Rows[I], View[I]
        pcall(function()
            -- 4 = SelfHitTestInvisible: nur die Knoepfe nehmen Klicks an (3 = HitTestInvisible schaltete auch
            -- die Knoepfe taub: Klicks auf die Zeilen kamen nicht an)
            Row.Box:SetVisibility(Cells and 4 or 1)
            for C, Cell in ipairs(Row.Cells) do
                local Spec = Cells and Cells[C]
                if Spec then
                    Cell.Label:SetText(FText(Spec.Text))
                    Cell.Action = Spec.Action
                    Cell.Button:SetVisibility(0)
                else
                    Cell.Action = nil
                    Cell.Button:SetVisibility(1)
                end
            end
        end)
    end
end

-- Vom Server: bin ich Admin? Und (fuer Admins) die Spielerliste "Nummer;Name;Ping"
Coop.HostDataHandlers.admin = function(Text)
    ExecuteInGameThread(function()
        Coop.List.IsAdmin = Text == "1"
        Log("Admin-Rechte auf diesem Server: %s", Coop.List.IsAdmin and "ja" or "nein")
        pcall(Coop.List.UpdateAdminTab)
    end)
end

Coop.HostDataHandlers.plist = function(Text)
    local List = {}
    -- PLAYER-20 (K33): je Zeile "Nummer;Name;Ping" oder mit 4. Feld ";PlayerId"
    for Line in (Text .. "\n"):gmatch("([^\n]*)\n") do
        local N, Name, Ping, Pid = Line:match("^(%d+);([^;]*);(%d+);?(%d*)$")
        if N then List[#List + 1] = { N = tonumber(N), Name = Name, Ping = tonumber(Ping), Pid = tonumber(Pid) } end
    end
    ExecuteInGameThread(function()
        local L = Coop.List
        L.Players = List
        if L.Selected and L.SelectedPid and Coop.FlagOn("admin_pid", true) then
            -- PLAYER-20 (admin_pid): Auswahl folgt der PlayerId auf ihre neue Nummer; Spieler weg -> Auswahl aufheben
            local NewN
            for _, P in ipairs(List) do if P.Pid == L.SelectedPid then NewN = P.N break end end
            L.Selected = NewN
            if not NewN then L.SelectedPid, L.Armed = nil, nil end
        else
            local Still = false
            for _, P in ipairs(List) do if P.N == L.Selected then Still = true end end
            if not Still then L.Selected, L.SelectedPid, L.Armed = nil, nil, nil end
        end
        if L.Mode == "admin" then pcall(L.Render) end
    end)
end

-- Antworten der DLL abholen (jede Sekunde aus der Hauptschleife)
function Coop.List.Tick()
    local L = Coop.List
    L.Setup()
    -- Admin-Rechte gelten nur auf dem Server, der sie vergeben hat
    if L.IsAdmin and NetModeName(CurrentWorld()) ~= "Client" then
        L.IsAdmin, L.Players, L.Selected, L.SelectedPid, L.Armed = false, {}, nil, nil, nil
        pcall(L.UpdateAdminTab)
    end
    if L.ListSince then
        local File = io.open(MOD_DIR .. "netcore_list.txt", "r")
        if File then
            local Text = File:read("*a") or ""
            File:close()
            os.remove(MOD_DIR .. "netcore_list.txt")
            L.ListSince = nil
            local Status = tonumber(Text:match("^STATUS (%d+)")) or 0
            if Status ~= 200 or not Text:find("LASTSIGNAL%-LIST 1") then
                L.Servers, L.Status = {}, "Master list unreachable"
            else
                L.Servers, L.Extra, L.SelServer = {}, {}, nil
                for Line in Text:gmatch("[^\n]+") do
                    local Id, Name, Players, Max, Version, Addr = Line:match("^(%x+)|([^|]*)|(%d+)|(%d+)|([^|]*)|(%S+)$")
                    if Id and #L.Servers < L.MAX_SERVERS then
                        L.Servers[#L.Servers + 1] = { Id = Id, Name = Name, Players = tonumber(Players),
                                                      Max = tonumber(Max), Version = Version, Addr = Addr }
                    end
                    -- Zusatz je Server (alte Spielversionen ueberspringen die Zeile): Passwort ja/nein, Beschreibung
                    local XId, Locked, Desc = Line:match("^X|(%x+)|([01])|([%w%+/=]*)%s*$")
                    if XId then L.Extra[XId] = { Locked = Locked == "1", Desc = L.B64(Desc):gsub("%c", " ") } end
                end
                for _, S in ipairs(L.Servers) do
                    local E = L.Extra[S.Id]
                    S.Locked, S.Desc = E ~= nil and E.Locked, E and E.Desc or ""
                end
                L.Status = #L.Servers == 0 and "No servers online" or (#L.Servers .. (#L.Servers == 1 and " server online" or " servers online"))
                local Req = io.open(MOD_DIR .. "netcore_ping_req.txt", "w")
                if Req and #L.Servers > 0 then
                    for _, S in ipairs(L.Servers) do Req:write(S.Id .. "|" .. S.Addr .. "\n") end
                    L.PingSince = os.time()
                end
                if Req then Req:close() end
            end
            L.Render()
        elseif os.time() - L.ListSince > L.LIST_TIMEOUT then
            L.ListSince, L.Status = nil, "Master list unreachable"
            L.Render()
        end
    end
    if L.PingSince then
        local File = io.open(MOD_DIR .. "netcore_ping.txt", "r")
        if File then
            local Text = File:read("*a") or ""
            File:close()
            os.remove(MOD_DIR .. "netcore_ping.txt")
            L.PingSince = nil
            for Id, Ms in Text:gmatch("(%x+)|(%-?%d+)") do
                for _, S in ipairs(L.Servers) do
                    if S.Id == Id then S.Ping = tonumber(Ms) end
                end
            end
            L.Render()
        elseif os.time() - L.PingSince > 10 then
            L.PingSince = nil
        end
    end
    if Coop.JoinPassword and NetModeName(CurrentWorld()) == "Client" then
        local W = Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end)
        if W ~= L.AuthWorld then L.AuthWorld, L.AuthUntil, L.AuthAt = W, os.time() + 60, 0 end
        if os.time() < L.AuthUntil and os.time() >= L.AuthAt then
            L.AuthAt = os.time() + 5
            Coop.SendChunked(Coop.SendToHost, "auth", Coop.JoinPassword)
        end
    end
    -- Beitritt aus der Liste, der nicht zustande kam: Adresse nicht ewig im Speicher halten
    local Join = rawget(_G, "LastSignalJoin")
    if Join and Join.Address then
        Join.Since = Join.Since or os.time()
        if os.time() - Join.Since > 120 then Join.Address = nil end
    end
end

-- Passwort aus dem Chat ("/pw", Coop.Chat.OnEnter): merken, sofort schicken (derselbe Weg wie oben), danach wie beim
-- Beitritt alle 5 s bis 60 s. Im Chat nur eine Bestaetigung ohne das Passwort; nie ins Log.
function Coop.List.SendPassword(Pw)
    local L = Coop.List
    Coop.JoinPassword = Pw
    L.AuthWorld = Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end)
    L.AuthUntil, L.AuthAt = os.time() + 60, os.time() + 5
    local ok = pcall(Coop.SendChunked, Coop.SendToHost, "auth", Pw)
    local C = Coop.Chat
    C.Count = (C.Count or 0) + 1
    C.History[#C.History + 1] = { Id = C.Count, Name = "LastSignal", Msg = ok and "Passwort gesendet" or "Passwort: Senden fehlgeschlagen",
                                  Admin = true, At = os.time() }
    if pcall(C.Setup) then pcall(C.Render) end
end
end

do
-- Chat (nur als Mitspieler auf einem Server): Taste aus chat_key.txt im Mod-Ordner (Standard Enter, schreibt der
-- Installer), Enter schickt, Esc bricht ab. Verlauf und Eingabefeld unten links im HUD (BP_Ingame_C im Bild). Der Server verteilt die Nachrichten ("chat": "1|Name|Text",
-- 1 = Admin/Server, hervorgehoben).
-- Sichtbar, solange der Chat offen ist oder die letzte Nachricht juenger als SHOW_SECONDS ist. Name orange,
-- Text weiss; Admins/Server ganz rot.
Coop.Chat = { LINES = 8, SHOW_SECONDS = 10, MAX_LEN = 150, WRAP = 600, History = {}, Lines = {}, Open = false,
              WHITE = { R = 1, G = 1, B = 1, A = 1 }, NAME = { R = 1, G = 0.55, B = 0.1, A = 1 },
              ADMIN = { R = 1, G = 0.15, B = 0.15, A = 1 } }

function Coop.Chat.KeyName()
    local File = io.open(MOD_DIR .. "chat_key.txt", "r")
    local Name = File and (File:read("*l") or ""):match("^%s*([%w_]+)")
    if File then File:close() end
    Name = Name and Name:upper() or "RETURN"   -- T ist im Spiel die Kamera (1./3. Person)
    return Key[Name] and Name or "RETURN"
end

-- Chat-Taste aendern (Journal, Reiter SERVER: Klick auf "CHAT KEY", dann die neue Taste druecken, Esc = abbrechen).
-- Dafuer sind alle Tasten ausser Maus und Esc gebunden; es zaehlt Coop.Chat.Key.
Coop.Chat.Key = Coop.Chat.KeyName()

function Coop.Chat.StartCapture() Coop.Chat.Capture = true end

function Coop.Chat.OnKey(Name)
    local C = Coop.Chat
    if C.Capture then
        C.Capture, C.Key = false, Name
        local File = io.open(MOD_DIR .. "chat_key.txt", "w")
        if File then File:write(Name, "\n") File:close() end
        Log("Chat-Taste: %s", Name)
        pcall(Coop.List.Render)
    elseif C.Key == Name then
        C.OpenInput()
    end
end

function Coop.Chat.WBL() return Coop.Cdo("/Script/UMG.Default__WidgetBlueprintLibrary") end   -- CORE-20: nil statt Huelle

function Coop.Chat.Allowed() return NetModeName(CurrentWorld()) == "Client" end

-- Verweise ungueltig nach Kartenwechsel oder neuer Figur (neues HUD): nie mehr anfassen
function Coop.Chat.Valid()
    local C = Coop.Chat
    if not C.Hud then return false end
    -- world_hygiene (CORE-8 e): Welt-Generation zuerst (die Welt-Adresse kann sich nach LoadMap wiederholen)
    if (C.Gen ~= WorldGen.N and WorldGen.Hygiene ~= false)
        or Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end) ~= C.WorldAddr or not IsAlive(C.Hud) or not IsAlive(C.Box) then
        C.Hud, C.Box, C.Edit, C.EditBox, C.Lines, C.Shown = nil, nil, nil, nil, {}, nil
        return false
    end
    return true
end

-- Verlauf (VerticalBox mit Texten) und Eingabefeld ins HUD der eigenen Figur
function Coop.Chat.Setup()
    local C = Coop.Chat
    if C.Valid() and Safe(function() return C.Hud:IsInViewport() end, false) then return true end
    -- Das HUD im Bild: BP_Ingame_C (Wurzel CanvasPanel; BP_HUD_C gibt es im Spiel nicht)
    local Hud
    for _, W in ipairs(FindAllOf("BP_Ingame_C") or {}) do
        if IsAlive(W) and Safe(function() return W:IsInViewport() end, false) then Hud = W break end
    end
    if not Hud then
        if not C.HudLogged then C.HudLogged = true Log("Chat: kein HUD im Bild gefunden") end
        return false
    end
    if C.Hud == Hud and C.Valid() then return true end   -- nur kurz aus dem Bild (Menue)
    local Root = Safe(function() local Tree = Hud.WidgetTree return IsAlive(Tree) and Tree.RootWidget or nil end)
    local Kind = IsAlive(Root) and Root:GetClass():GetFName():ToString() or "nil"
    if Kind ~= "CanvasPanel" and Kind ~= "Overlay" then
        if C.RootLogged ~= Kind then C.RootLogged = Kind Log("Chat: HUD-Wurzel ist %s, kein Chat", Kind) end
        return false
    end
    local function New(Path) return StaticConstructObject(StaticFindObject(Path), Hud.WidgetTree, 0, 0, 0, false, false, nil, nil, nil) end
    local Box = New("/Script/UMG.VerticalBox")
    if Kind == "CanvasPanel" then
        local Slot = Root:AddChildToCanvas(Box)
        Slot:SetAnchors({ Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } })
        Slot:SetAlignment({ X = 0, Y = 1 })
        Slot:SetPosition({ X = 30, Y = -280 })
        Slot:SetAutoSize(true)
        Slot:SetZOrder(50)
    else
        local Slot = Root:AddChildToOverlay(Box)
        Slot:SetHorizontalAlignment(1)   -- links
        Slot:SetVerticalAlignment(3)     -- unten
        Slot:SetPadding({ Left = 30, Top = 0, Right = 0, Bottom = 280 })
    end
    Box:SetVisibility(3)
    -- Zeile = HorizontalBox aus Name und Text (zwei Farben); Eigenschaften vor dem Einhaengen setzen (dann
    -- entsteht das Slate-Widget)
    local function Text(Wrap)
        local T = New("/Script/UMG.TextBlock")
        pcall(function()
            local F = T.Font
            F.Size = 16
            T:SetFont(F)
        end)
        pcall(function() T:SetShadowOffset({ X = 1, Y = 1 }) end)
        pcall(function() T:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
        if Wrap then pcall(function() T.WrapTextAt = Wrap end) end
        return T
    end
    local Lines = {}
    for I = 1, C.LINES do
        local Row = New("/Script/UMG.HorizontalBox")
        local Name, Msg = Text(nil), Text(C.WRAP)
        Box:AddChildToVerticalBox(Row)
        local NameSlot = Row:AddChildToHorizontalBox(Name)
        pcall(function() NameSlot:SetVerticalAlignment(1) end)   -- oben, falls der Text umbricht
        Row:AddChildToHorizontalBox(Msg)
        Row:SetVisibility(1)
        Lines[I] = { Row = Row, Name = Name, Msg = Msg }
    end
    -- Eingabefeld in fester Breite (sonst nur so breit wie der Hinweistext): dunkel mit weisser Schrift
    local EditBox = New("/Script/UMG.SizeBox")
    pcall(function() EditBox:SetWidthOverride(520) end)
    local Edit = New("/Script/UMG.EditableTextBox")
    pcall(function()
        local Style, Dark = Edit.WidgetStyle, { SpecifiedColor = { R = 0, G = 0, B = 0, A = 0.7 }, ColorUseRule = 0 }
        local White = { SpecifiedColor = C.WHITE, ColorUseRule = 0 }
        for _, Brush in ipairs({ "BackgroundImageNormal", "BackgroundImageHovered", "BackgroundImageFocused", "BackgroundImageReadOnly" }) do
            pcall(function() Style[Brush].TintColor = Dark end)
        end
        Style.BackgroundColor = { SpecifiedColor = C.WHITE, ColorUseRule = 0 }
        Style.ForegroundColor = White
        Style.FocusedForegroundColor = White
        pcall(function() Style.TextStyle.ColorAndOpacity = White end)
        pcall(function()
            local F = Style.TextStyle.Font
            F.Size = 14
        end)
    end)
    pcall(function() Edit:SetForegroundColor(C.WHITE) end)
    pcall(function() Edit:SetHintText(FText("Chat ... (Enter = send, Esc = cancel)")) end)
    EditBox:SetContent(Edit)
    local EditSlot = Box:AddChildToVerticalBox(EditBox)
    pcall(function() EditSlot:SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 0 }) end)
    EditBox:SetVisibility(1)
    C.Hud, C.Box, C.Edit, C.EditBox, C.Lines, C.Shown, C.Open = Hud, Box, Edit, EditBox, Lines, nil, false
    C.WorldAddr = Safe(function() local W = CurrentWorld() return IsAlive(W) and W:GetAddress() or nil end)
    C.Gen = WorldGen.N   -- world_hygiene: Welt-Generation des Einbaus (Coop.Chat.Valid)
    Log("Chat: im HUD eingebaut (%s), Taste %s", Kind, C.Key)
    return true
end

-- Die letzten LINES Nachrichten (aeltere oben), solange der Chat offen oder die letzte juenger als SHOW_SECONDS ist
function Coop.Chat.Render()
    local C = Coop.Chat
    if not C.Valid() then return end
    local Last = C.History[#C.History]
    local Show = C.Open or (Last ~= nil and os.time() - Last.At < C.SHOW_SECONDS)
    local First = math.max(1, #C.History - C.LINES + 1)
    local Sign = Show and ((Last and Last.Id or 0) .. "/" .. #C.History) or "-"
    if Sign == C.Shown then return end
    C.Shown = Sign
    for I, L in ipairs(C.Lines) do
        local Entry = Show and C.History[First + I - 1]
        pcall(function()
            if Entry then
                local Color = { SpecifiedColor = Entry.Admin and C.ADMIN or C.NAME, ColorUseRule = 0 }
                L.Name:SetText(FText(Entry.Name .. ": "))
                L.Name:SetColorAndOpacity(Color)
                L.Msg:SetText(FText(Entry.Msg))
                L.Msg:SetColorAndOpacity(Entry.Admin and Color or { SpecifiedColor = C.WHITE, ColorUseRule = 0 })
                L.Row:SetVisibility(3)
            else
                L.Row:SetVisibility(1)
            end
        end)
    end
end

function Coop.Chat.OpenInput()
    local C = Coop.Chat
    if C.Open or not C.Allowed() or not C.Setup() then return end
    local PC = LocalPC()
    -- PLAYER-21 (chat_deathscreen): auf dem Todesbildschirm (ls_player, Mauszeiger an) darf man trotzdem schreiben
    local Dead = Coop.FlagOn("chat_deathscreen", true) and Coop.Player ~= nil
        and Safe(function() return Coop.Player.DeathScreenUp() end, false) == true
    -- Nur im Spiel selbst, nicht in Menues/Inventar (dort ist der Mauszeiger an)
    if not IsAlive(PC) or (not Dead and Safe(function() return PC.bShowMouseCursor end, false)) then return end
    C.Open, C.OpenedAt, C.OpenDead = true, os.clock(), Dead or nil
    C.Edit:SetText(FText(""))
    pcall(function() C.Edit.RevertTextOnEscape = true C.Edit.ClearKeyboardFocusOnCommit = true end)
    C.EditBox:SetVisibility(0)
    C.WBL():SetInputMode_UIOnlyEx(PC, C.Edit, 0, true)   -- Tastatur ins Feld, gedrueckte Tasten loslassen
    pcall(function() C.Edit:SetKeyboardFocus() end)
    C.Render()
end

function Coop.Chat.Close()
    local C = Coop.Chat
    if not C.Open then return end
    C.Open = false
    if C.Valid() then pcall(function() C.EditBox:SetVisibility(1) end) end
    -- PLAYER-21: noch auf dem Todesbildschirm -> Eingabe wie das Spiel dort (BP_PlayerController @1da4 GameAndUI, Maus an)
    local Dead = C.OpenDead and Coop.Player ~= nil and Safe(function() return Coop.Player.DeathScreenUp() end, false) == true
    C.OpenDead = nil
    if Dead then
        pcall(function()
            local PC = LocalPC()
            C.WBL():SetInputMode_GameAndUIEx(PC, nil, 2, false, false)
            PC.bShowMouseCursor = true
        end)
    else
        pcall(function() C.WBL():SetInputMode_GameOnly(LocalPC(), false) end)
    end
    C.Render()
end

function Coop.Chat.OnEnter()
    local C = Coop.Chat
    if not C.Open or os.clock() - (C.OpenedAt or 0) < 0.3 then return end   -- Chat-Taste Enter: nicht gleich senden
    local Text = C.Valid() and Safe(function() return C.Edit:GetText():ToString() end, "") or ""
    C.Close()
    -- "/pw <Passwort>": Server-Passwort nachreichen (Feld beim Beitritt leer gelassen). Geht nur als "auth" an den Host,
    -- nie in den Chat, nie ins Log, wird nicht angezeigt; das Eingabefeld wird geleert.
    local Pw = Text:match("^%s*/[pP][wW]%s+(.-)%s*$")
    if Pw or Text:match("^%s*/[pP][wW]%s*$") then
        if C.Valid() then pcall(function() C.Edit:SetText(FText("")) end) end
        if Pw and Pw ~= "" then pcall(Coop.List.SendPassword, Pw) end
        return
    end
    -- "/admin <Passwort>" (core-A, LASTSIGNAL_ADMIN_PASSWORD): geht wie jedes "/..." als Chat an den Host (Srv.ChatCommand,
    -- nie verteilt, nie geloggt); wie bei /pw das Eingabefeld gleich leeren, damit das Passwort nirgends stehen bleibt
    if Text:match("^%s*/[aA][dD][mM][iI][nN]%s") and C.Valid() then pcall(function() C.Edit:SetText(FText("")) end) end
    Text = Text:gsub("[%c|]", " "):match("^%s*(.-)%s*$")
    -- ls_player: nur /suicide /kill /unstuck /stuck und (Runde 9, E20) /carlock (ohne Argumente). Alle anderen "/..." (/clan, /c, /lock, /unlock,
    -- /code, /claim, /unclaim, /owner) gehen als normaler Chat an den Host (server.lua Srv.ChatCommand, nie verteilt).
    if Coop.Player and Coop.Player.ChatCommand(Text) then
        if C.Valid() then pcall(function() C.Edit:SetText(FText("")) end) end
        return
    end
    if Text ~= "" then Coop.SendChunked(Coop.SendToHost, "chat", Text:sub(1, C.MAX_LEN * 4)) end
end

-- Jede Sekunde: einbauen, alte Zeilen ausblenden; ausserhalb eines Servers Verlauf leeren
function Coop.Chat.Tick()
    local C = Coop.Chat
    if not C.Allowed() then
        if C.Open then C.Close() end
        C.History = {}
        return
    end
    if C.Open and not C.Valid() then C.Close() end
    if C.Setup() then C.Render() end
end

Coop.HostDataHandlers.chat = function(Text)
    local Admin, Name, Msg = Text:match("^(%d)|([^|]*)|(.*)$")
    if not Msg then return end
    ExecuteInGameThread(function()
        local C = Coop.Chat
        C.Count = (C.Count or 0) + 1
        C.History[#C.History + 1] = { Id = C.Count, Name = Name, Msg = Msg, Admin = Admin == "1", At = os.time() }
        while #C.History > 50 do table.remove(C.History, 1) end
        if pcall(C.Setup) then pcall(C.Render) end
    end)
end

end

do
-- Cheat-Menue des Spiels (DebugMenu_C, Taste IA_DebugMenu, nur mit CVar Debug.Allow) auf einem Server: nur fuer
-- Admins (Coop.List.IsAdmin). Fuer alle anderen Debug.Allow aus und ein offenes Menue sofort zu; nach dem Verlassen
-- des Servers der alte Wert. Beim Admin laufen die Knoepfe sonst nur lokal (Mitspieler: keine Rechte ueber
-- Inventar/Welt), darum: Item-/Fahrzeug-Knopf vor dem Ausfuehren leeren (Vor-Hook, nichts Lokales) und den
-- Wunsch an den Server ("admin give"/"admin vehicle"); Wetter und Zeitlupe zusaetzlich an den Server.
Coop.Cheat = { MENU = "/Game/UI/Widgets/Debug/DebugMenu.DebugMenu_C",
               BUTTONS = { "/Game/UI/Widgets/Debug/ItemButton.ItemButton_C", "/Game/UI/Widgets/Debug/VehicleButton.VehicleButton_C" },
               CLICK = "BndEvt__ItemButton_Button_41_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
               DILATION = { "BndEvt__DebugMenu_Slider_126_K2Node_ComponentBoundEvent_27_OnFloatValueChangedEvent__DelegateSignature",
                            "BndEvt__DebugMenu_EditableDilationTxt_K2Node_ComponentBoundEvent_5_OnEditableTextChangedEvent__DelegateSignature" },
               -- Knoepfe, die nur die eigene Figur aendern: dasselbe beim Server ausfuehren (Werte wie im Menue)
               SELF = { BndEvt__DebugMenu_ReduceHungerButton_K2Node_ComponentBoundEvent_32_OnButtonClickedEvent__DelegateSignature = "hunger -10",
                        BndEvt__DebugMenu_ReduceThirstButton_K2Node_ComponentBoundEvent_33_OnButtonClickedEvent__DelegateSignature = "thirst -10",
                        BndEvt__DebugMenu_DamagePlayerButton_K2Node_ComponentBoundEvent_30_OnButtonClickedEvent__DelegateSignature = "damage 10" },
               Hooked = {}, Saved = {} }

function Coop.Cheat.Forward() return NetModeName(CurrentWorld()) == "Client" and Coop.List.IsAdmin end

-- "BlueprintGeneratedClass /Game/A/B.B_C" -> "/Game/A/B.B_C"
function Coop.Cheat.Path(Object) return (Object:GetFullName():match("^%S+%s+(%S+)$")) end

-- Eigene Jig-Komponente / PendingRequests (Platzhalter) als { Slot, Key=uid32 }
function Coop.Cheat.OwnJig()
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local Jig = IsAlive(Pawn) and Safe(function() return Pawn.BP_JigMultiplayer end)
    return IsAlive(Jig) and Jig or nil
end
function Coop.Cheat.PendList(Jig)
    local L = {}
    Jig.PendingRequests:ForEach(function(_, E)
        local Slot = E:get()
        if IsAlive(Slot) then
            local G = Slot.ItemUniqueID
            L[#L + 1] = { Slot = Slot, Key = string.format("%08X%08X%08X%08X", math.floor(G.A) & 0xFFFFFFFF,
                math.floor(G.B) & 0xFFFFFFFF, math.floor(G.C) & 0xFFFFFFFF, math.floor(G.D) & 0xFFFFFFFF) }
        end
    end)
    return L
end
-- ItemButton @06b0 JigTryAddItemSomewhere legt trotz Vor-Hook einen Platzhalter an (JigTryAddGetPendingRef @0975, erster freier
-- Slot). Der Host legt per give in denselben Slot an -> CLIENT_AddNewItem scheitert beim Gast (JSIContainer AddNewItem IsEmptySlot),
-- Item unsichtbar, Slot beim Server belegt -> spaetere Verschiebungen abgelehnt. Darum gleich im Klick-Hook weg.
-- UE4SS ruft bei BP-Funktionen (script hook, Ids "(19, 19)") nur EINEN Callback auf, und zwar NACH dem BP-Rumpf:
-- Platzhalter steht also schon. Vergleich gegen PendBase (offenes Menue, 1x/s in Cheat.Tick) + gleiches DataAsset.
-- Runde 9 INV-13 (cheat_rmpend2): Want = Adresse des DataAssets (Item darf nil sein); Rueckgabe = Anzahl entfernt.
-- UIDs, die der Host schon kennt (Digest inv_sum von ls_inv), sind echte Items einer laufenden Spiel-Anfrage
-- (Verschieben/Stapeln legt echte Widgets in PendingRequests) und bleiben immer stehen.
function Coop.Cheat.DropPend(Item, Base, Want)
    local Jig = Coop.Cheat.OwnJig()
    if not Jig then return 0 end
    local N, Dg = 0, Coop.Cheat.Known()
    Want = Want or Item:GetAddress()
    for _, E in ipairs(Coop.Cheat.PendList(Jig)) do
        local DA = Safe(function() return E.Slot.JigDataAsset end)
        if not Base[E.Key] and not (Dg and Dg:find(E.Key:sub(1, 16) .. ":", 1, true))
            and IsAlive(DA) and DA:GetAddress() == Want and IsAlive(E.Slot)
            and pcall(function() Jig:RemoveRequestByUID(E.Slot.ItemUniqueID, true, {}) end) then
            N = N + 1
        end
    end
    if N > 0 then Log("Cheat-Platzhalter: %d lokal sofort entfernt (Host legt das Item an)", N) end
    return N
end

-- INV-13: Server-Digest (nil = Schalter aus, kein ls_net oder noch kein Digest)
function Coop.Cheat.Known()
    if not Coop.FlagOn("cheat_rmpend2", true) then return nil end
    local NetM = Coop.Net
    if not (NetM and type(NetM.Get) == "function") then return nil end
    local Dg = Safe(function() return NetM.Get("inv_sum", "s") end)
    return type(Dg) == "string" and Dg or nil
end

-- INV-13: Platzhalter-Stand der eigenen Jig-Komponente (Menge der UIDs) oder nil
function Coop.Cheat.PendSnap()
    local Jig = Coop.Cheat.OwnJig()
    return Jig and Safe(function()
        local S = {}
        for _, E in ipairs(Coop.Cheat.PendList(Jig)) do S[E.Key] = true end
        return S
    end) or nil
end

-- INV-13: Stand gleich beim Oeffnen des Menues (Construct-Hook merkt nur vor, der Schnell-Loop liest), damit ein Klick in
-- der ersten Sekunde nicht mit leerem Stand echte Platzhalter desselben DataAssets entfernt
function Coop.Cheat.SnapSoon()
    if MultiplayerActive and Coop.FlagOn("cheat_rmpend2", true) then Coop.AddFast("cheatsnap", Coop.Cheat.SnapTask) end
end
function Coop.Cheat.SnapTask(_, Mode)
    if Mode == "Client" then
        local ok, Snap = pcall(Coop.Cheat.PendSnap)
        if ok then Coop.Cheat.PendBase = Snap else Coop.FlagFail("cheat_rmpend2", Snap) end
    end
    return true
end

-- bp_hook_first: Einmal-Aufgabe nach Construct (Schnell-Loop): freie Kamera als Mitspieler sofort aus, nicht erst im
-- naechsten Cheat.Tick (Klick in der ersten Sekunde: Kamera lokal, HUD weg, Possess nur beim Server)
-- Ausserdem Zeitlupe: Construct setzt EditableDilationTxt per SetText (OnTextChanged ohne Eingabe) -> diese Markierung
-- verwerfen; Basis = Stand beim Oeffnen (Inventar/Radialmenue setzen die lokale Zeitlupe selbst, z. B. auf 1,
-- ohne Rueck-Replikation, weil sich der Server-Wert nicht aendert; Respawn-Bildschirm nur im Standalone).
-- Cheat.Tick wertet bis hierher nicht aus (DilOpen).
function Coop.Cheat.CamOffTask(_, Mode)
    if Mode == "Client" then
        pcall(function()
            local P = LocalPC()
            local Pawn = IsAlive(P) and P:K2_GetPawn() or nil
            local M = IsAlive(Pawn) and Pawn.DebugMenu or nil
            local Btn = IsAlive(M) and M.SpawnCameraButton or nil
            if IsAlive(Btn) then Btn:SetIsEnabled(false) end
        end)
    end
    local C = Coop.Cheat
    C.DilOpen, C.DilationDirty, C.DilWant = nil, false, nil
    if Mode == "Client" then C.DilBase = Safe(C.Dil) end
    return true
end

-- bp_hook_first: Zeitlupe gleich nach der Eingabe festhalten (<= 0,1 s, Einmal-Aufgabe "cheatdil" im Schnell-Loop).
-- Der Regler-/Text-Hook laeuft nach dem BP-Rumpf (SetGlobalTimeDilation schon gesetzt). Bis zur Sekunden-Pruefung
-- setzen Inventar/Radialmenue (mit Game.SlowTime 0,25/0,2) bzw. Inventar-Ende/Radial-Loslassen (1) die lokale Zeitlupe
-- selbst -> sonst ginge deren Wert statt des Reglers an den Host (serverweit). DilOpen: Markierung vom Oeffnen, nicht lesen.
function Coop.Cheat.DilTask(_, Mode)
    local C = Coop.Cheat
    if Mode == "Client" and C.DilationDirty and not C.DilOpen then C.DilWant = Safe(C.Dil) end
    return true
end

-- Zeitlupe der eigenen Welt; nil ohne gueltige Welt/WorldSettings (nie eine Methode auf einem ungueltigen Wrapper)
function Coop.Cheat.Dil()
    local W = CurrentWorld()
    local WS = IsAlive(W) and W:K2_GetWorldSettings() or nil
    if IsAlive(WS) then return WS.TimeDilation end
end

-- INV-13: zweiter Durchlauf (1,5 s, 5 Hz, gleicher Stand und gleiches DataAsset), wenn der Klick-Hook noch keinen
-- Platzhalter fand (Hook vor dem BP-Rumpf, z. B. nach einem UE4SS-Update)
function Coop.Cheat.RmTick(Now, Mode)
    local C = Coop.Cheat
    if Mode ~= "Client" or not C.RmJobs then C.RmJobs = nil return true end
    if Now < (C.RmNext or 0) then return end
    C.RmNext = Now + 0.2
    local Keep = {}
    for _, J in ipairs(C.RmJobs) do
        local ok, N = pcall(C.DropPend, nil, J.Base, J.Want)
        if not ok then Coop.FlagFail("cheat_rmpend2", N)
        elseif N == 0 and Now < J.Until then Keep[#Keep + 1] = J end
    end
    C.RmJobs = #Keep > 0 and Keep or nil
    return C.RmJobs == nil
end

function Coop.Cheat.OnClickPre(Self)
    local Button = Self:get()
    if not Coop.Cheat.Forward() then
        -- Nicht-Admin auf einem Server (Menue per Konsole erzwungen): Knopf wirkungslos. Sonst legte er den Gegenstand
        -- lokal an und Coop.Pending holte ihn danach vom Server.
        if NetModeName(CurrentWorld()) == "Client" then
            for _, Field in ipairs({ "ItemID", "Item" }) do
                local Value = Safe(function() return Button[Field] end)
                if IsAlive(Value) then
                    Coop.Cheat.Saved[Button:GetAddress()] = { Field = Field, Value = Value }
                    Button[Field] = nil
                end
            end
        end
        return
    end
    local Item = Safe(function() return Button.ItemID end)
    if IsAlive(Item) then
        local Amount = math.max(1, math.floor((Safe(function() local DM = Button.DebugMenu return IsAlive(DM) and DM.Amount or 1 end, 1) or 1) + 0.5))
        -- Runde 9 INV-12a (cheat_clamp): wie im Spiel (ItemButton @0667 clamp(round(Amount), 1, ItemId->MaxStack)),
        -- sonst wurden z. B. aus "Axt x50" fuenfzig Aexte
        if Coop.FlagOn("cheat_clamp", true) then
            local Max = math.floor(tonumber(Safe(function() return Item.MaxStack end, 0)) or 0)
            if Max >= 1 and Amount > Max then Amount = Max end
        end
        -- ItemID nicht mehr leeren: der Hook laeuft nach dem Rumpf (wirkungslos), und ohne Nach-Hook blieb der Knopf
        -- danach tot (zweiter Klick schickte kein give mehr)
        local CoreM = Coop.Modules and Coop.Modules.ls_core
        local Rm = ""
        if not (CoreM and CoreM.Flag) or CoreM.Flag("cheat_rmpend", true) == true then
            local Base = Coop.Cheat.PendBase or {}
            local ok, N = pcall(Coop.Cheat.DropPend, Item, Base)
            if not ok then Log("Cheat-Platzhalter: %s", tostring(N)) end
            if Coop.FlagOn("cheat_rmpend2", true) then
                -- INV-13 (K35): Platzhalter schon weg -> Host ohne Gutschrift (ls_inv M.Give NoCredit); sonst zweiter Durchlauf
                if ok and N > 0 then
                    -- K35 nur an Hosts mit Cap invgrm (Runde-9-Parser); ein Server vor Runde 9 lehnt " rm" mit
                    -- "give: invalid asset" ab. Ohne Cap altes Format (Host schreibt gut wie in Runde 8)
                    if Safe(function()
                        local NetM = Coop.Net
                        return NetM ~= nil and type(NetM.Has) == "function" and NetM.Has("invgrm") == true
                    end, false) == true then
                        Rm = " rm"
                    end
                else
                    local okW, Want = pcall(function() return Item:GetAddress() end)
                    if okW and Want then
                        local C = Coop.Cheat
                        C.RmJobs = C.RmJobs or {}
                        C.RmJobs[#C.RmJobs + 1] = { Base = Base, Want = Want, Until = os.clock() + 1.5 }
                        Coop.AddFast("cheatrm", C.RmTick)
                    end
                end
            end
        end
        Coop.SendChunked(Coop.SendToHost, "admin", "give ".. Coop.Cheat.Path(Item) .. " " .. Amount .. Rm)
        if Coop.Loot and Coop.Loot.DupArm then Coop.Loot.DupArm() end   -- lokale Kopie gleich weg (nur Tabellen)
        return
    end
    local Class = Safe(function() return Button.Item end)
    if IsAlive(Class) then
        Coop.SendChunked(Coop.SendToHost, "admin", "vehicle " .. Coop.Cheat.Path(Class))
        local CoreM = Coop.Modules and Coop.Modules.ls_core
        if not (CoreM and CoreM.Flag) or CoreM.Flag("cheat_ghostcar", true) == true then
            Coop.Cheat.GhostCls, Coop.Cheat.GhostUntil = Coop.Cheat.Path(Class), os.clock() + 2
            Coop.AddFast("cheatcar", Coop.Cheat.GhostTick)
        end
    end
end

-- Fahrzeug-Knopf: das Spiel spawnt beim Gast trotzdem lokal (VehicleButton-Ubergraph @01f3 BeginDeferredActorSpawnFromClass),
-- der Gast stieg sonst ins Geisterauto (Server: "kein Auto beim Mitspieler"). Lokale Kopie (HasAuthority beim Gast, nicht
-- aus der Karte, nahe der eigenen Figur) weg; das echte Auto kommt repliziert (wie ls_car Kauf-Geisterauto).
function Coop.Cheat.GhostTick(Now, Mode)
    local C = Coop.Cheat
    if Mode ~= "Client" or not C.GhostCls or Now > (C.GhostUntil or 0) then C.GhostCls = nil return true end
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) then return end
    local P0 = Pawn:K2_GetActorLocation()
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if IsAlive(V) and Safe(function() return V:HasAuthority() end) == true
            and (not WAS_LOADED or not V:HasAnyFlags(WAS_LOADED))
            and Safe(function() return C.Path(V:GetClass()) end) == C.GhostCls then
            local L = V:K2_GetActorLocation()
            local Dx, Dy = L.X - P0.X, L.Y - P0.Y
            if Dx * Dx + Dy * Dy <= 2000 * 2000 then
                pcall(function() V:K2_DestroyActor() end)
                Log("Cheat-Fahrzeug: lokale Kopie entfernt (%s)", C.GhostCls:match("[^%.]+$") or C.GhostCls)
            end
        end
    end
end

-- Hooks erst, wenn die Widget-Klassen geladen sind (beim ersten Oeffnen des Menues)
function Coop.Cheat.Hook()
    local C = Coop.Cheat
    for _, Class in ipairs(C.BUTTONS) do
        if not C.Hooked[Class] and IsAlive(StaticFindObject(Class)) then
            C.Hooked[Class] = true
            TryHook(Class .. ":" .. C.CLICK,
                function(Self) local ok, err = pcall(C.OnClickPre, Self) if not ok then Log("Cheat-Menue: %s", tostring(err)) end end)
        end
    end
    if not C.Hooked.Menu and IsAlive(StaticFindObject(C.MENU)) then
        C.Hooked.Menu = true
        TryHook(C.MENU .. ":ChangeWeather", function(_, Preset)
            pcall(function()
                local P = Preset:get()
                if IsAlive(P) and C.Forward() then Coop.SendChunked(Coop.SendToHost, "admin", "weatherpreset " .. P:GetFName():ToString()) end
            end)
        end)
        -- bp_hook_first: die BndEvt-Ereignisse sind BP-Funktionen (DebugMenu_C.kdis FLAGS 0x08000000/0x08400000, kein
        -- Native). UE4SS 3.0.1 ruft dort nur den ERSTEN Callback (nach dem BP-Rumpf) -> im zweiten war der Koerper tot,
        -- DilationDirty blieb aus und die Zeitlupe kam nie beim Host an. Koerper = reine Tabellen-Schreibung.
        -- 0 = alte Registrierung (Koerper im zweiten Callback).
        local First = Coop.FlagOn("bp_hook_first", true)
        for _, Event in ipairs(C.DILATION) do
            if First then
                -- Wert erst im Schnell-Loop lesen ("cheatdil", <= 0,1 s), Koerper = reine Tabellen-Schreibung
                TryHook(C.MENU .. ":" .. Event, function() C.DilationDirty = true Coop.AddFast("cheatdil", C.DilTask) end)
            else
                TryHook(C.MENU .. ":" .. Event, function() end, function() C.DilationDirty = true end)
            end
        end
        -- gleich beim Oeffnen: freie Kamera aus (siehe Tick)
        -- INV-13: Platzhalter-Stand beim Oeffnen (nur vormerken; beide Rueckrufe, UE4SS ruft bei BP-Funktionen nur einen)
        -- bp_hook_first: Construct ist ebenfalls eine BP-Funktion (DebugMenu_C.kdis:4606 FLAGS 0x08020808, kein Native) ->
        -- der zweite Callback (Kamera-Knopf aus) war tot, nur Cheat.Tick (1 Hz) schaltete ihn ab. Jetzt nur vormerken:
        -- Einmal-Aufgabe "cheatcam" im Schnell-Loop (100 ms, Spiel-Thread), kein UFunction-Aufruf im Hook.
        if First then
            TryHook(C.MENU .. ":Construct", function()
                pcall(C.SnapSoon)
                -- Zeitlupe: Construct setzt EditableDilationTxt per SetText (OnTextChanged ohne Eingabe); UE4SS ruft den
                -- Callback nach dem BP-Rumpf -> Markierung verwerfen. DilOpen: Cheat.Tick wertet erst nach "cheatcam" aus
                -- (1-s- und 100-ms-Schleife laufen unabhaengig). Reine Tabellen-Schreibung.
                C.DilationDirty, C.DilWant = false, nil
                if MultiplayerActive then
                    C.DilOpen = true
                    Coop.AddFast("cheatcam", C.CamOffTask)
                end
            end)
        else
            TryHook(C.MENU .. ":Construct", function() pcall(C.SnapSoon) end, function(Self)
                pcall(C.SnapSoon)
                if NetModeName(CurrentWorld()) == "Client" then
                    pcall(function()
                        local M = Self:get()
                        local Btn = IsAlive(M) and M.SpawnCameraButton
                        if IsAlive(Btn) then Btn:SetIsEnabled(false) end
                    end)
                end
            end)
        end
        for Event, Cmd in pairs(C.SELF) do
            TryHook(C.MENU .. ":" .. Event, function()
                if C.Forward() then Coop.SendChunked(Coop.SendToHost, "admin", Cmd) end
            end)
        end
        Log("Cheat-Menue: Hooks gesetzt")
    end
end

-- Jede Sekunde (nicht im Server-Modus)
function Coop.Cheat.Tick()
    local C = Coop.Cheat
    local KSL = UEHelpers.GetKismetSystemLibrary()
    local OnServer = NetModeName(CurrentWorld()) == "Client"
    if OnServer then
        if C.Allow == nil then C.Allow = Safe(function() return KSL:GetConsoleVariableBoolValue("Debug.Allow") end, false) end
        local Want = Coop.List.IsAdmin == true
        if C.Set ~= Want then
            C.Set = Want
            RunCommand("Debug.Allow " .. (Want and "1" or "0"))
        end
        local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
        local Menu = IsAlive(Pawn) and Safe(function() return Pawn.DebugMenu end)
        if not Want then
            if IsAlive(Menu) then
                pcall(function() Pawn:CloseDebugMenu() end)
                Log("Cheat-Menue geschlossen: nur fuer Admins")
            end
        elseif IsAlive(Menu) then
            -- Freie Kamera geht als Mitspieler nicht (Possess nur beim Server): HUD war weg, kam nicht wieder
            pcall(function() local Btn = Menu.SpawnCameraButton if IsAlive(Btn) then Btn:SetIsEnabled(false) end end)
            -- Platzhalter-Stand vor dem naechsten Cheat-Klick (siehe DropPend)
            C.PendBase = C.PendSnap()
        end
        if not IsAlive(Menu) then C.PendBase = nil end
    elseif C.Allow ~= nil then
        RunCommand("Debug.Allow " .. (C.Allow and "1" or "0"))
        C.Allow, C.Set = nil, nil
    end
    if MultiplayerActive then C.Hook() end   -- Solo: keine Hooks (die Knoepfe laufen dort ohnehin lokal)
    -- bp_hook_first macht den Zeitlupen-Hook lebendig: Construct setzt EditableDilationTxt programmatisch (SetText ->
    -- OnTextChanged ohne Eingabe) -> DilationDirty bei jedem Oeffnen; der Construct-Hook und "cheatcam" (CamOffTask)
    -- verwerfen diese Markierung, Basis = Stand beim Oeffnen. Zweite Sperre: nur eine echte Aenderung gegen DilBase an den
    -- Host schicken. Gelesen wird nur als Mitspieler, Welt/WorldSettings vorher geprueft (C.Dil).
    -- Wert = DilWant (gleich nach der Eingabe festgehalten, DilTask), sonst wie bisher der Stand jetzt.
    local Only = Coop.FlagOn("bp_hook_first", true)
    local Dil = OnServer and Only and Safe(C.Dil) or nil
    if Only and not OnServer then C.DilationDirty, C.DilOpen, C.DilWant = false, nil, nil end   -- kein Rest aus Host/Solo
    if C.DilOpen then
        -- "cheatcam" noch nicht gelaufen: Markierung behalten, Basis unten = Stand nach dem Oeffnen (Construct lief schon)
        C.DilOpen = nil
    elseif C.DilationDirty and C.Forward() then
        local Value = C.DilWant or Dil or Safe(C.Dil)
        C.DilationDirty, C.DilWant = false, nil
        if type(Value) == "number" and (not Only or type(C.DilBase) ~= "number" or math.abs(Value - C.DilBase) > 0.0005) then
            Coop.SendChunked(Coop.SendToHost, "admin", string.format("dilation %.3f", Value))
        end
    end
    C.DilBase = type(Dil) == "number" and Dil or nil
end
end

do
-- Fahrzeuge auf dem Server. Das Spiel kennt Fahrzeuge nur fuer einen Spieler: Einsteigen haengt die Figur
-- nur lokal ans Auto (kein Possess), Gas/Lenkung gehen lokal an die ChaosVehicleMovementComponent, Tank und
-- Schaden (FuelComponent, VehicleHealthComponent) sind nicht repliziert, Kanister/Reparaturset sucht es im
-- lokalen Inventar (beim Mitspieler leer, das Inventar liegt beim Server).
-- Fahren wie in den meisten UE-Spielen mit Physik-Fahrzeugen, fahrer-autoritativ: Der Fahrer rechnet sein Auto
-- selbst (lokal keine Bewegungs-Replikation mehr, also kein Zurueckziehen) und schickt car_hz-mal pro Sekunde
-- (Standard 30, 15-60; car_hz=0: alter Weg mit 15) Lage und Geschwindigkeit ("car": pose). Der Server setzt sein
-- Auto darauf, die normale Replikation zeigt es allen anderen (die Physik-Replikation glaettet). Solange gefahren
-- wird, ignoriert das Auto beim Server Spieler (wie beim Fahrer lokal), sonst schiebt die Figur des Fahrers es weg.
-- Tanken/Reparieren: Die lokale Pruefung schlaegt fehl ("No gas found"); stattdessen zieht der Server den
-- Gegenstand aus dem Inventar ab und schickt Tank/Zustand an alle ("carstate").
-- Mail/MailAt (Server, car_hz > 0): neueste Lage je Fahrer und Zeitpunkt der offenen Arbeit im naechsten Bild.
-- HostFps (Mitspieler): Bilder pro Sekunde des Servers, kommt mit "hello" (Phase 2), bis dahin nil.
Coop.Car = { SeatCheck = {}, NoColl = {}, RATE = 1 / math.max(15, math.min(60, SETTINGS.car_hz)), NEAR = 800,
             Drivers = {}, Passengers = {}, Hooked = {}, Mail = {}, MailAt = {},
             CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
             -- UE 5.6: BP_JigMultiplayer_C -> BP_JigComponent_C (ServerFindThenConsumeByItemID, RemoveRequestByUID identisch,
             -- JigTryAddItemSomewhere Signatur gleich (5 Parameter, 40 Byte); Figur-Eigenschaft heisst weiter BP_JigMultiplayer)
             JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C",
             NOTE = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C",
             ITEMS = { gas = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
                       repair = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit" },
             FAILED = { ["No gas found"] = "Using gas can ...", ["No repair kits found"] = "Using repair kit ..." } }

-- Runde 5: ls_car aktiv fuer ein Feature (car_v2 + car_<Flag>)? Peer nil = nur Schalter, true = Gast mit Host
-- (Cap car2), PC = Host mit diesem Gast. Liefert das Modul oder nil (kein neues local, Feld in Coop).
Coop.CarV2 = function(Flag, Peer)
    local Mod = Coop.Modules and Coop.Modules.ls_car
    if not (Mod and Mod.Flag and Mod.Flag(Flag)) then return nil end
    if Peer == nil then return Mod end
    local N = Coop.Net
    if not N then return nil end
    if Peer == true then return N.Has("car2") and Mod or nil end
    local G = N.ByPC(Peer)
    return G and N.Has("car2", G) and Mod or nil
end

-- Autoliste: FindAllOf hoechstens 1x pro Sekunde (je Welt neu); Nutzer pruefen jedes Auto mit IsAlive
function Coop.Car.Vehicles()
    local C, Now = Coop.Car, os.clock()
    if not C.VList or Now - (C.VAt or 0) >= 1 or C.VGen ~= WorldGen.N then
        C.VList, C.VAt, C.VGen = FindAllOf("BP_VehicleMaster_C") or {}, Now, WorldGen.N
    end
    return C.VList
end

function Coop.Car.Nearest(Loc, Max)
    local Best, BestD = nil, Max * Max
    for _, V in ipairs(Coop.Car.Vehicles()) do
        if IsAlive(V) then
            local P = V:K2_GetActorLocation()
            local D = (P.X - Loc.X) ^ 2 + (P.Y - Loc.Y) ^ 2 + (P.Z - Loc.Z) ^ 2
            if D < BestD then Best, BestD = V, D end
        end
    end
    return Best
end

function Coop.Car.Mesh(V)
    local M = Safe(function() return V.Mesh end)
    return IsAlive(M) and M or V:K2_GetRootComponent()
end

-- Abstand zwischen zwei Lage-Meldungen: RATE (car_hz), aber nie oefter, als der Server Bilder rechnet (HostFps)
function Coop.Car.SendRate()
    local C = Coop.Car
    if SETTINGS.car_hz > 0 and type(C.HostFps) == "number" and C.HostFps > 0 then return math.max(C.RATE, 1 / C.HostFps) end
    return C.RATE
end

function Coop.Car.State(V)
    local F, H = V.FuelComponent, V.VehicleHealthComponent
    if not (IsAlive(F) and IsAlive(H)) then error("Tank/Zustand fehlt") end
    return string.format("%.1f|%.1f|%.1f|%.1f", F.CurrentFuel, F.MaxFuel, H.CurrentHealth, H.MaxHealth)
end

-- Server: eigener Stand als Zahlen { Tank, MaxTank, Zustand, MaxZustand }, nil = nicht lesbar
function Coop.Car.HostState(V)
    local ok, Text = pcall(Coop.Car.State, V)
    if not ok then return nil end
    local S = {}
    for X in (Text .. "|"):gmatch("([^|]*)|") do S[#S + 1] = tonumber(X) end
    if not (S[1] and S[2] and S[3] and S[4]) or S[2] <= 0 or S[4] <= 0 then return nil end
    return S
end

-- Tank/Zustand uebernehmen (Repaired: Rauch/Feuer aus, Motor an), Anzeigen am Auto mit
function Coop.Car.ApplyState(V, Fuel, MaxFuel, Health, MaxHealth, Repaired)
    pcall(function()
        local F = V.FuelComponent
        if not IsAlive(F) then return end
        F.CurrentFuel = Fuel
        F.Empty = Fuel <= 0
    end)
    pcall(function() local H = V.VehicleHealthComponent if IsAlive(H) then H.CurrentHealth = Health end end)
    -- Rauch (<= 30) und Feuer (<= 10) wie das Spiel nach dem Laden (VehicleHealth: schaltet beides an und aus).
    -- UE 5.6: VehicleHealth entfernt, dieselbe Logik in VehicleEngineFX(Visible=true) (@0018 <= 30 Rauch, @0091 <= 10 Feuer)
    if Coop.HasMember(V, "VehicleEngineFX") then
        pcall(function() V:VehicleEngineFX(true) end)
    elseif Coop.HasMember(V, "VehicleHealth") then
        pcall(function() V:VehicleHealth() end)
    end
    if Repaired then pcall(function() V["EngineOn?"] = true end) end
    pcall(function()
        local WC = V.FuelWidget
        local W = IsAlive(WC) and WC:GetUserWidgetObject()
        if IsAlive(W) then W:UpdateFuel(Fuel, MaxFuel) end
    end)
    pcall(function()
        local WC = V.RepairWidget
        local W = IsAlive(WC) and WC:GetUserWidgetObject()
        if IsAlive(W) then W:UpdateHealth(Health, MaxHealth) end
    end)
    if V == Coop.Car.Looking then pcall(Coop.Car.ShowStats, V) end
end

-- Anzeige "Fuel"/"Health" beim Anschauen des Autos: Das Spiel fuellt sie ueber die Server-RPCs Svr_UpdateFuel/
-- Svr_UpdateEngine (OnBeginInteract), die beim Mitspieler ohne Besitz am Auto verworfen werden -> selbst setzen,
-- gleicher Text wie das Spiel ("73%")
function Coop.Car.ShowStats(V)
    if not IsAlive(V) then return end
    local Hud = Safe(function() local P = LocalPC() return IsAlive(P) and P.MyHUD or nil end)
    if not IsAlive(Hud) then Hud = FindFirstOf("HUD_Game_C") end
    if not IsAlive(Hud) then return end
    local F, H = V.FuelComponent, V.VehicleHealthComponent
    if not (IsAlive(F) and IsAlive(H)) then return end
    local function Pct(X, Max) return string.format("%d%%", Max > 0 and math.floor(X / Max * 100 + 0.5) or 0) end
    Hud:UpdateInteractStats(FName("Fuel"), FText(Pct(F.CurrentFuel, F.MaxFuel)), false)
    Hud:UpdateInteractStats(FName("Health"), FText(Pct(H.CurrentHealth, H.MaxHealth)), false)
end

-- Klasse BP_VehicleMaster_C (Pfad unbekannt): von einem Auto aus die Elternklassen hochgehen
function Coop.Car.MasterPath()
    local V = FindFirstOf("BP_VehicleMaster_C")
    local Class = IsAlive(V) and V:GetClass()
    for _ = 1, 8 do
        if not IsAlive(Class) then return nil end
        if Class:GetFName():ToString() == "BP_VehicleMaster_C" then return (Class:GetFullName():match("^%S+%s+(%S+)$")) end
        Class = Safe(function() return Class:GetSuperStruct() end)
    end
    return nil
end

-- Mitspieler: jedes Bild (ReceiveTick der eigenen Figur): Fahren erkennen, Lage schicken
-- Andere Spieler im Auto: Der Server setzt ihre Figur in den Sitz; hier stiess ihre Kapsel gegen die eigene Physik
-- des Autos (beim Fahrer, beim Beifahrer, bei Zuschauern) -> Auto zitterte, mit zwei Leuten flog es in alle
-- Richtungen. Sitzende (Bewegungsmodus None, nahe einem Auto, keine Ragdoll) hier ohne Kollision.
function Coop.Car.CheckSeated(Pawn)
    local C, Addr, Now = Coop.Car, Pawn:GetAddress(), os.clock()
    if (C.SeatCheck[Addr] or 0) > Now then return end
    C.SeatCheck[Addr] = Now + 0.2
    local Move = Pawn.CharacterMovement
    local Seated = IsAlive(Move) and Move.MovementMode == 0
        and Safe(function() local M = Pawn.Mesh return IsAlive(M) and M:IsSimulatingPhysics(FName("None")) end, true) == false
        and C.Nearest(Pawn:K2_GetActorLocation(), 400) ~= nil
    if Seated and not C.NoColl[Addr] then
        C.NoColl[Addr] = true
        Pawn:SetActorEnableCollision(false)
        Log("Fahrzeug: %s sitzt im Auto, Kollision hier aus", Pawn:GetFName():ToString())
    elseif not Seated and C.NoColl[Addr] then
        C.NoColl[Addr] = nil
        Pawn:SetActorEnableCollision(true)
    end
end

-- Schnell-Aufgabe "car_seat" (100 ms, Mitspieler): Sitz-Pruefung der anderen Figuren (je Figur alle 0,2 s), die
-- Figurenliste (FindAllOf) 1x pro Sekunde. Ersetzt den Hook auf ReceiveTick jeder Figur.
function Coop.Car.SeatFast(Now, Mode)
    local C = Coop.Car
    if Mode ~= "Client" or not C.Active or not C.LocalAddr then return end
    if not C.Pawns or Now >= (C.PawnsAt or 0) or C.PawnsGen ~= WorldGen.N then
        C.Pawns, C.PawnsAt, C.PawnsGen = Coop.PlayerPawns(), Now + 1, WorldGen.N
    end
    for _, Pawn in ipairs(C.Pawns) do
        if IsAlive(Pawn) and Pawn:GetAddress() ~= C.LocalAddr then
            local ok, err = pcall(C.CheckSeated, Pawn)
            if not ok and not C.SeatErr then C.SeatErr = true Log("Fahrzeug-Sitz-Fehler: %s", tostring(err)) end
        end
    end
end

-- Eigene 33-ms-Schleife (statt Hook auf ReceiveTick): eigene Figur; zu Fuss 10x pro Sekunde (Einsteigen erkennen,
-- AmmoHold), am Steuer jede Runde (Lage mit car_hz, SendRate prueft selbst)
function Coop.Car.Frame()
    local C = Coop.Car
    if not MultiplayerActive or not C.Active or not C.LocalAddr then return end
    if (WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60) or WorldGen.Dropped ~= WorldGen.N then return end
    local Now = os.clock()
    if not C.Driving and Now < (C.FrameAt or 0) then return end
    C.FrameAt = Now + 0.1
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) or Pawn:GetAddress() ~= C.LocalAddr then return end
    C.OnTick(Pawn)
end

-- CAR-7 (car_strict, Gast): Auto, das nur beim Gast existiert (HasAuthority beim Gast = nicht vom Server repliziert, z. B.
-- ein Geisterauto). Der Server kennt es nicht -> aussteigen (ExitVehicle wie die Aussteige-Taste) statt blind zu fahren.
-- true = ausgestiegen (kein "start"). Hinweis/Log je Auto hoechstens alle 5 s.
function Coop.Car.LocalOnly(V)
    if not Coop.CarV2("strict") or Safe(function() return V:HasAuthority() end) ~= true then return false end
    if not pcall(function() V:ExitVehicle({}) end) then pcall(function() V:ExitVehicle() end) end
    local C, Addr, Now = Coop.Car, Safe(function() return V:GetAddress() end), os.clock()
    if C.NoSyncAddr ~= Addr or Now - (C.NoSyncAt or 0) > 5 then
        C.NoSyncAddr, C.NoSyncAt = Addr, Now
        pcall(Coop.ShowNote, "Vehicle not synced with the server")
        Log("Fahrzeug %s gibt es nur hier (nicht vom Server): ausgestiegen", Safe(function() return V:GetFName():ToString() end, "?"))
    end
    return true
end

-- K28 carnone (Host -> Gast, legacy "x|y|z|Grund", Grund none/far/locked/local): Einsteigen abgelehnt. Handler: ls_car
-- (A.HostDataHandlers.carnone, steigt beim Gast aus). Nur mit Coop.CarV2("strict", PC).
function Coop.Car.SendNone(PC, X, Y, Z, Why)
    Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "carnone", string.format("%.0f|%.0f|%.0f|%s", X, Y, Z, Why))
end

function Coop.Car.OnTick(Pawn)
    local C = Coop.Car
    if not C.Active then return end
    -- ls_ui (ui_ammo): AmmoHold im 10-Hz-Task statt im Bild-Tick-Hook
    if not (Coop.Modules and Coop.Modules.ls_ui and Coop.Modules.ls_ui.Owns("ammo")) then pcall(Coop.AmmoHold, Pawn) end
    local V = Pawn["InVehicle?"] and Safe(function() local VDC = Pawn.VehicleDrivingComponent return IsAlive(VDC) and VDC.Vehicle or nil end)
    if not IsAlive(V) then V = nil end
    if V ~= C.Driving then
        if C.Driving then C.Stop() end
        -- CAR-7 (car_strict): Auto gibt es nur hier (nicht vom Server repliziert) -> ausgestiegen, kein "start"
        if V and C.LocalOnly(V) then return end
        if V then
            -- Tank/Zustand erst schicken, wenn der Stand des Servers da ist (carstate): sonst ueberschrieb der
            -- veraltete lokale Stand (nicht repliziert) den des Servers.
            -- Selbst fahren erst, wenn der Server es bestaetigt ("cardriver"); sitzt schon jemand am Steuer, wird man
            -- Beifahrer ("carbusy"). Bis dahin bewegt der Server das Auto weiter (sonst lief es beim Beifahrer kurz los).
            C.Driving, C.Confirmed, C.SentAt, C.StateAt, C.StateOk = V, false, 0, 0, false
            C.EnterAt, C.SeatAt = os.clock(), os.clock() + 0.6
            if C.Resume and C.Resume.V == V then C.Resume = nil end
            -- Sitzend keine eigenen Bewegungen an den Server (er uebernimmt sonst die Client-Lage und die Figur
            -- sprang fuer die anderen zwischen ihr und dem Sitz hin und her); den Sitz setzt der Server
            C.SetMoveTick(Pawn, false)
            local P = V:K2_GetActorLocation()
            -- CAR-7 (K29, car_strict, Host mit car2): 5. Feld = Host-FName des Autos aus der car_s-Bindung (ls_car E18);
            -- alte Hosts lesen nur x|y|z
            local Mod, HK = Coop.CarV2("strict", true), nil
            if Mod and type(Mod.HostKeyOf) == "function" then HK = Safe(function() return Mod.HostKeyOf(V) end) end
            HK = (type(HK) == "string" and HK:match("^[%w_]+$")) and ("|" .. HK) or ""
            Coop.SendChunked(Coop.SendToHost, "car", string.format("start|%.0f|%.0f|%.0f", P.X, P.Y, P.Z) .. HK)
        end
    end
    if not V then return end
    if C.SeatAt and os.clock() >= C.SeatAt then C.SeatAt = nil pcall(C.SendSeat, Pawn, V) end
    if C.PassengerOf == V then
        if not C.PassengerSet then
            C.PassengerSet = true
            C.SetPassenger(Pawn, V)
        end
        return   -- Beifahrer: faehrt nicht, schickt nichts
    end
    if not C.Confirmed then
        -- CAR-7 (car_strict, Host mit car2): der Host antwortet immer (cardriver/carbusy/carnone). Ohne Antwort nach 5 s
        -- aussteigen statt blind zu fahren (der Server bewegte das Auto sonst nie mit)
        if Coop.CarV2("strict", true) then
            local Now = os.clock()
            if Now - (C.EnterAt or 0) < 5 or Now < (C.StrictExitAt or 0) then return end
            C.StrictExitAt = Now + 1
            if not pcall(function() V:ExitVehicle({}) end) then pcall(function() V:ExitVehicle() end) end
            pcall(Coop.ShowNote, "Vehicle: no answer from the server")
            Log("Fahrzeug: keine Antwort des Servers nach 5 s - ausgestiegen (car_strict)")
            return
        end
        -- ohne Antwort (alter Server, verlorene Nachricht) nach 1,5 s trotzdem selbst fahren
        if os.clock() - (C.EnterAt or 0) < 1.5 then return end
        C.StartDriving(V)
    end
    local Now = os.clock()
    if Now - C.SentAt < C.SendRate() then return end
    -- Ping ueber 400 ms (Car.Tick, 1x/s): nichts schicken, danach gleich mit der neuesten Lage weiter
    if C.PingHigh then return end
    C.SentAt = Now
    if C.CheckAt and Now >= C.CheckAt then   -- Fehlersuche: faehrt das Auto wirklich?
        C.CheckAt = nil
        local P0, P1 = C.CheckFrom, V:K2_GetActorLocation()
        Log("Fahrzeug: nach 3 s %.0f cm bewegt", math.sqrt((P1.X - P0.X) ^ 2 + (P1.Y - P0.Y) ^ 2))
    end
    local Mesh, P, R = C.Mesh(V), V:K2_GetActorLocation(), V:K2_GetActorRotation()
    local Lin = Safe(function() return Mesh:GetPhysicsLinearVelocity(FName("None")) end, { X = 0, Y = 0, Z = 0 })
    local Ang = Safe(function() return Mesh:GetPhysicsAngularVelocityInDegrees(FName("None")) end, { X = 0, Y = 0, Z = 0 })
    local Text = string.format("pose|%.1f|%.1f|%.1f|%.2f|%.2f|%.2f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f",
        P.X, P.Y, P.Z, R.Pitch, R.Yaw, R.Roll, Lin.X, Lin.Y, Lin.Z, Ang.X, Ang.Y, Ang.Z)
    if C.StateOk and Now - C.StateAt >= 1 then   -- Tank/Zustand jede Sekunde mit (verbraucht wird beim Fahrer)
        C.StateAt = Now
        local ok, State = pcall(C.State, V)
        if ok then Text = Text .. "|" .. State end
    end
    Coop.SendChunked(Coop.SendToHost, "car", Text)
end

-- Beifahrer (Server: "carbusy"): Auto wieder vom Server bewegen lassen, eigene Eingaben ans Auto kappen, auf die
-- andere Seite setzen, beim Aussteigen die Beifahrerseite nehmen
function Coop.Car.SetPassenger(Pawn, V)
    local C = Coop.Car
    pcall(function() V:SetReplicateMovement(true) end)
    C.Resume = nil
    -- CAR-22: VehicleDrivingComponent hat in 5.6 kein VehicleMovementComponent mehr (props.tsv: Vehicle, DeathInVehicle);
    -- das Kappen der Eingaben macht ls_car (car_input). Schreibzugriffe darauf entfernt.
    pcall(function() V.GetOutPasseenger = true end)
    pcall(function()
        local Root = Pawn:K2_GetRootComponent()
        if not IsAlive(Root) then return end
        local R = Root.RelativeLocation
        Pawn:K2_SetActorRelativeLocation({ X = R.X, Y = -R.Y, Z = R.Z }, false, {}, true)
    end)
    C.SeatAt = os.clock() + 0.2   -- gespiegelten Sitz an den Server
    Log("Fahrzeug: Beifahrer in %s", V:GetFName():ToString())
end

-- Fahrer bestaetigt (Server "cardriver" oder Zeitablauf): Auto selbst rechnen
function Coop.Car.StartDriving(V)
    local C = Coop.Car
    if V ~= C.Driving or C.PassengerOf == V or C.Confirmed then return end
    C.Confirmed = true
    C.CheckAt, C.CheckFrom = os.clock() + 3, V:K2_GetActorLocation()
    pcall(function() V:SetReplicateMovement(false) end)   -- nur hier: kein Zurueckziehen durch den Server
    do local Mod = Coop.CarV2 and Coop.CarV2("input") if Mod and Mod.OnStartDriving then pcall(Mod.OnStartDriving, V) end end
    -- Die Replikation kann die Physik des Autos hier abgeschaltet haben (ruhendes Auto): wieder an, aufwecken
    local Mesh = C.Mesh(V)
    local Sim = Safe(function() return Mesh:IsSimulatingPhysics(FName("None")) end)
    if Sim == false then pcall(function() Mesh:SetSimulatePhysics(true) end) end
    pcall(function() Mesh:WakeAllRigidBodies() end)
    -- car_hb_release: das Spiel zieht beim Aussteigen auf der eigenen Kopie die Handbremse (BP_VehicleMaster @10df) und
    -- loest sie nur im eigenen Einstiegs-Ablauf (@1e8c), der beim Gast nicht laeuft -> ab der zweiten Fahrt "0 cm bewegt".
    do
        local Core = Coop.Modules and Coop.Modules.ls_core
        if not (Core and Core.Flag) or Core.Flag("car_hb_release", true) == true then
            pcall(function() local M = V.VehicleMovementComponent if IsAlive(M) then M:SetHandbrakeInput(false) M:SetBrakeInput(0) end end)
        end
    end
    Log("Fahrzeug: fahre %s selbst (Physik %s, Motor %s, Tank %s)", V:GetFName():ToString(), tostring(Sim),
        tostring(Safe(function() return V["EngineOn?"] end)), tostring(Safe(function() local F = V.FuelComponent return IsAlive(F) and math.floor(F.CurrentFuel) or nil end)))
end

function Coop.Car.SetMoveTick(Pawn, On)
    if IsAlive(Pawn) then pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:SetComponentTickEnabled(On) end end) end
end

-- Eigener Sitz relativ zum Auto (wie SeatRel: nur Drehung um die Hochachse) an den Server: dort sitzt die Figur
-- dann fuer alle genau so wie beim Spieler selbst (je Auto-Modell richtig, auch Buggy)
function Coop.Car.SendSeat(Pawn, V)
    local S, P, Yaw = Pawn:K2_GetActorLocation(), V:K2_GetActorLocation(), V:K2_GetActorRotation().Yaw
    local R, DX, DY = math.rad(-Yaw), S.X - P.X, S.Y - P.Y
    local X, Y = DX * math.cos(R) - DY * math.sin(R), DX * math.sin(R) + DY * math.cos(R)
    local DYaw = (Pawn:K2_GetActorRotation().Yaw - Yaw + 540) % 360 - 180
    if X * X + Y * Y > 600 * 600 then return end   -- noch nicht im Auto
    Coop.SendChunked(Coop.SendToHost, "car", string.format("seat|%.1f|%.1f|%.1f|%.1f", X, Y, S.Z - P.Z, DYaw))
end

function Coop.Car.Stop()
    local C = Coop.Car
    C.SetMoveTick(Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end), true)
    if C.PassengerOf and C.PassengerOf == C.Driving then
        if IsAlive(C.Driving) then pcall(function() C.Driving.GetOutPasseenger = false end) end
    elseif IsAlive(C.Driving) and C.Confirmed then
        -- Bewegung vom Server erst wieder annehmen, wenn sein Auto steht: Lagen eines noch rollenden Autos blieben
        -- als Physik-Ziel haengen und hielten das Auto beim sofortigen Wiedereinsteigen fest
        C.Resume = { V = C.Driving, At = os.clock() + 4 }
    end
    do local Mod = Coop.CarV2 and Coop.CarV2("input") if Mod and Mod.OnStop and IsAlive(C.Driving) then pcall(Mod.OnStop, C.Driving) end end
    C.Driving, C.PassengerOf, C.PassengerSet, C.SavedMove, C.Confirmed, C.SeatAt = nil, nil, nil, nil, false, nil
    -- eigene Lage nach dem Aussteigen mit: der Server stellt die Figur dorthin (sonst zog er sie zurueck)
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local P = IsAlive(Pawn) and Pawn:K2_GetActorLocation()
    Coop.SendChunked(Coop.SendToHost, "car", P and string.format("stop|%.1f|%.1f|%.1f|%.1f", P.X, P.Y, P.Z, Pawn:K2_GetActorRotation().Yaw) or "stop")
    Log("Fahrzeug: ausgestiegen")
end

-- Mitspieler: Kanister/Reparaturset aus dem eigenen Inventar (lokal leer) -> beim Server abziehen lassen
function Coop.Car.OnConsume(Self, Item)
    local C = Coop.Car
    if not C.Active then return end   -- C.Active = Mitspieler (Car.Tick, 1 s); kein NetModeName im Hook
    local Path = Safe(function() local I = Item:get() return IsAlive(I) and I:GetFullName():match("^%S+%s+(%S+)$") or nil end)
    local What
    for K, P in pairs(C.ITEMS) do if P == Path then What = K end end
    if not What then return end
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) or Self:get():GetAddress() ~= Safe(function() local Inv = Pawn.BP_JigMultiplayer return IsAlive(Inv) and Inv:GetAddress() or nil end) then
        Log("Fahrzeug: %s aus fremdem Inventar (%s), ignoriert", What, Safe(function() return Self:get():GetFullName() end, "?"))
        return
    end
    local V = C.Nearest(Pawn:K2_GetActorLocation(), C.NEAR)
    if not V then Log("Fahrzeug: %s ohne Auto in der Naehe", What) return end
    -- Lokal nie verbrauchen (sonst nur beim Spieler weg und das Inventar blieb danach gesperrt): Gegenstand leeren,
    -- die Pruefung schlaegt fehl, den Rest macht der Server
    local Cleared = pcall(function() Item:set(nil) end)
    local P = V:K2_GetActorLocation()
    C.PendingAt = os.clock()
    local ok, State = pcall(C.State, V)
    Coop.SendChunked(Coop.SendToHost, "car", string.format("svc|%s|%.0f|%.0f|%.0f|%s", What, P.X, P.Y, P.Z, ok and State or ""))
    Log("Fahrzeug: %s beim Server angefragt (%s, lokal %s)", What, V:GetFName():ToString(), Cleared and "verhindert" or "NICHT verhindert")
end

-- Die lokale Fehlermeldung ("No gas found") gleich danach ersetzen; das Ergebnis meldet der Server
function Coop.Car.OnNote(_, Message)
    local C = Coop.Car
    if not C.PendingAt or os.clock() - C.PendingAt > 2 then return end
    local Text = Safe(function() return Message:get():ToString() end, "")
    local New = C.FAILED[Text]
    if New then
        C.PendingAt = nil
        pcall(function() Message:set(FText(New)) end)
    end
end

-- Jede Sekunde (nicht im Server-Modus): Hooks, eigene Figur merken
function Coop.Car.Tick()
    local C = Coop.Car
    C.Active = NetModeName(CurrentWorld()) == "Client"
    local Pawn = C.Active and Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    C.LocalAddr = IsAlive(Pawn) and Pawn:GetAddress() or nil
    if C.Driving and (not C.Active or not IsAlive(C.Driving)) then
        if C.Active then C.Stop() else C.Driving = nil end
    end
    if C.Resume and (os.clock() >= C.Resume.At or not C.Active) then
        local V = C.Resume.V
        C.Resume = nil
        if IsAlive(V) and V ~= C.Driving then pcall(function() V:SetReplicateMovement(true) end) end
    end
    -- Eigener Ping (car_hz > 0, 1x/s gemerkt): ueber 400 ms keine Lage-Meldungen (sie stauten sich nur beim Server)
    if C.Active and SETTINGS.car_hz > 0 then
        local Ping = tonumber(Safe(function() local P = LocalPC() local PS = IsAlive(P) and P.PlayerState return IsAlive(PS) and PS:GetPingInMilliseconds() or nil end))
        local High = Ping ~= nil and Ping > 400
        if High ~= (C.PingHigh == true) and C.Driving then
            Log("Fahrzeug: Ping %.0f ms - Lage-Meldungen %s", Ping or -1, High and "pausiert" or "laufen wieder")
        end
        C.PingHigh = High
    else
        C.PingHigh = false
    end
    -- Erst im Multiplayer beim Mitspieler (Solo/Host: nichts). Kein Hook mehr auf ReceiveTick (lief jedes Bild fuer
    -- jede Figur, mit FindAllOf/RPC darin): eigene 33-ms-Schleife + Schnell-Aufgabe "car_seat"
    if MultiplayerActive and C.Active and not C.Hooked.Frame then
        C.Hooked.Frame = true
        LoopInGameThreadWithDelay(33, function()
            local ok, err = pcall(C.Frame)
            if not ok and not C.TickErr then C.TickErr = true Log("Fahrzeug-Fehler: %s", tostring(err)) end
        end)
        Coop.AddFast("car_seat", C.SeatFast)
    end
    -- car_svc (ls_car): Entscheidung je Verbindung im Hook (Host mit car2?), nicht nur nach dem eigenen Schalter -
    -- sonst konnte ein Gast mit car_v2 an einem Host ohne car2 weder alt noch neu tanken/reparieren
    -- CORE-18: der Hook (Inventar-Interna) nur, wenn der alte Weg gebraucht wird (Coop.Car.LegacySvc)
    if MultiplayerActive and C.Active and not C.Hooked.Jig and IsAlive(StaticFindObject(C.JIG)) and C.LegacySvc() then
        C.Hooked.Jig = true
        TryHook(C.JIG .. ":ServerFindThenConsumeByItemID", function(Self, Item)
            if not C.Active or (Coop.CarV2 and Coop.CarV2("svc", true)) then return end
            pcall(C.OnConsume, Self, Item)
        end)
        Log("Fahrzeug: alter Tank-/Reparatur-Weg aktiv (Host ohne car_svc v2)")
    end
    -- Tank/Zustand aller Autos vom Server holen: 5 s nach jeder neuen eigenen Figur (dann sind die Autos da)
    if C.LocalAddr and C.SyncFor ~= C.LocalAddr then
        C.SyncFor, C.SyncAt = C.LocalAddr, os.time() + 5
    elseif C.SyncAt and os.time() >= C.SyncAt then
        C.SyncAt = nil
        Coop.SendChunked(Coop.SendToHost, "car", "sync")
    end
    if C.Looking and (not C.Active or not IsAlive(C.Looking)) then C.Looking = nil end
    if C.Looking then pcall(C.ShowStats, C.Looking) end
    if not C.Hooked.Master and C.Active then
        local Path = C.MasterPath()
        if Path then
            C.Hooked.Master = true
            -- bp_hook_first: OnBeginInteract ist eine BP-Funktion (BP_VehicleMaster_C.kdis FLAGS 0x0c020000, kein Native,
            -- Kinder ueberschreiben sie nicht). UE4SS 3.0.1 ruft dort nur den ERSTEN Callback (nach dem BP-Rumpf) -> im
            -- zweiten war der Koerper tot, Looking blieb nil. Neu: nur vormerken (Tabelle). Beim Anschauen zeigt der
            -- BP-Rumpf Fuel/Health schon aus denselben Komponenten (EVT_OnBeginInteract @59dc); nachgezogen wird in
            -- Car.Tick (1 s) und bei der Sync-Antwort. 0 = alte Registrierung (Koerper im zweiten Callback).
            if Coop.FlagOn("bp_hook_first", true) then
                TryHook(Path .. ":OnBeginInteract", function(Self)
                    if Coop.Car.Active then Coop.Car.Looking = Self:get() end
                end)
            else
                TryHook(Path .. ":OnBeginInteract", function() end, function(Self)
                    if not Coop.Car.Active then return end
                    local V = Self:get()
                    Coop.Car.Looking = V
                    ExecuteInGameThread(function() pcall(Coop.Car.ShowStats, V) end)
                end)
            end
            TryHook(Path .. ":OnEndInteract", function() Coop.Car.Looking = nil end)
        end
    end
    -- CORE-18: CreateNotificationUI (rund 290 Aufrufer) nur zusammen mit dem alten Tank-/Reparatur-Weg: nur dort setzt
    -- OnConsume PendingAt, sonst ersetzt OnNote nie etwas
    if MultiplayerActive and C.Active and C.Hooked.Jig and not C.Hooked.Note and IsAlive(StaticFindObject(C.NOTE)) then
        C.Hooked.Note = true
        TryHook(C.NOTE .. ":CreateNotificationUI", function(Self, Message) pcall(C.OnNote, Self, Message) end)
    end
end

-- CORE-18: Wird der alte Tank-/Reparatur-Weg (Hook auf ServerFindThenConsumeByItemID) gebraucht? Ja, wenn der eigene
-- neue Weg aus ist; nach dem Handshake nur ohne car2 beim Host; ohne Handshake 30 s nach dem Verbinden (alter Host).
function Coop.Car.LegacySvc()
    local Mod = Coop.Modules and Coop.Modules.ls_car
    if not (Mod and Mod.Flag and Safe(function() return Mod.Flag("svc") end, false)) then return true end
    local N = Coop.Net
    if N and N.Linked and Safe(N.Linked, false) == true then
        return Safe(function() return N.Has("car2") end, false) ~= true
    end
    return ClientConnectedSince ~= nil and os.time() - ClientConnectedSince >= 30
end

-- Server: Nachrichten eines Mitspielers (im Netzwerk-Hook: Arbeit ins naechste Bild)
-- car_hz > 0: Lagen ("pose") ueber ein Postfach je Fahrer - die neueste gewinnt, hoechstens eine Arbeit je Fahrer
-- offen (statt einer je Meldung). Nach einem Haenger des Servers also kein Stoss alter Lagen. Alles andere wie
-- bisher einzeln und in Reihenfolge. (Offen laenger als 2 s: verloren geglaubt, neu einplanen.)
-- MailAt[Key] = { At = os.clock } der offenen Arbeit; eine abgeloeste Arbeit (anderer Befehl dazwischen, neu
-- eingeplant) erkennt das am Vergleich und tut nichts.
function Coop.Car.OnClient(PC, Data)
    local Key = PC:GetFullName()
    local C = Coop.Car
    if SETTINGS.car_hz > 0 and Data:sub(1, 5) == "pose|" then
        C.Mail[Key] = { PC = PC, Data = Data }
        local Now, Job = os.clock(), C.MailAt[Key]
        if Job and Now - Job.At < 2 then return end
        Job = { At = Now }
        C.MailAt[Key] = Job
        ExecuteInGameThread(function()
            if C.MailAt[Key] ~= Job then return end
            local M = C.Mail[Key]
            C.Mail[Key], C.MailAt[Key] = nil, nil
            if not M then return end
            local ok, err = pcall(C.Handle, M.PC, Key, M.Data)
            if not ok and not C.HandleErr then C.HandleErr = true Log("Fahrzeug (Server): %s", tostring(err)) end
        end)
        return
    end
    -- Reihenfolge wie gesendet: eine noch offene Lage vor diesem Befehl anwenden (sonst kam eine spaetere Lage vor
    -- "stop"/"start" dran und setzte womoeglich das alte Auto); Lagen danach planen sich neu ein
    local Pending = C.Mail[Key]
    C.Mail[Key], C.MailAt[Key] = nil, nil
    ExecuteInGameThread(function()
        if Pending then
            local okP, errP = pcall(Coop.Car.Handle, Pending.PC, Key, Pending.Data)
            if not okP and not Coop.Car.HandleErr then Coop.Car.HandleErr = true Log("Fahrzeug (Server): %s", tostring(errP)) end
        end
        local ok, err = pcall(Coop.Car.Handle, PC, Key, Data)
        if not ok and not Coop.Car.HandleErr then Coop.Car.HandleErr = true Log("Fahrzeug (Server): %s", tostring(err)) end
    end)
end

-- Fahrer weg: Figur beim Server abhaengen und dorthin, wo der Spieler ausgestiegen ist (At), wieder laufen lassen
-- Sitz im Auto relativ zum Auto (nur Drehung um die Hochachse): Fahrer = PlayerLocation, Beifahrer gespiegelt
function Coop.Car.SeatRel(V)
    local C, Addr = Coop.Car, V:GetAddress()
    C.Seats = C.Seats or {}
    if C.Seats[Addr] then return C.Seats[Addr] end
    local Rel = { X = 0, Y = -40, Z = 60 }
    pcall(function()
        local Seat = V.PlayerLocation
        if not IsAlive(Seat) then return end
        local S, P, Yaw = Seat:K2_GetComponentLocation(), V:K2_GetActorLocation(), math.rad(-V:K2_GetActorRotation().Yaw)
        local DX, DY = S.X - P.X, S.Y - P.Y
        Rel = { X = DX * math.cos(Yaw) - DY * math.sin(Yaw), Y = DX * math.sin(Yaw) + DY * math.cos(Yaw), Z = S.Z - P.Z }
    end)
    C.Seats[Addr] = Rel
    return Rel
end

-- Server: Figur (Fahrer/Beifahrer) mit dem Auto mitfuehren, damit die anderen sie im Auto sehen und sie beim
-- Aussteigen nicht vom Einstieg aus zurueckgezogen wird. Nicht anhaengen (die Anhaengung wird repliziert, s. o.).
-- Seat = vom Spieler gemeldeter Sitz ("seat", genau), sonst PlayerLocation (Beifahrer gespiegelt)
function Coop.Car.PlacePawn(Pawn, V, Passenger, Seat)
    local Rel, P, Yaw = Seat or Coop.Car.SeatRel(V), V:K2_GetActorLocation(), V:K2_GetActorRotation().Yaw
    local R, Y = math.rad(Yaw), (Passenger and not Seat) and -Rel.Y or Rel.Y
    local At = { X = P.X + Rel.X * math.cos(R) - Y * math.sin(R), Y = P.Y + Rel.X * math.sin(R) + Y * math.cos(R), Z = P.Z + Rel.Z }
    Pawn:K2_SetActorLocationAndRotation(At, { Pitch = 0, Yaw = Yaw + (Seat and Seat.Yaw or 0), Roll = 0 }, false, {}, true)
end

-- Fahrer/Beifahrer weg: Figur beim Server dorthin, wo der Spieler ausgestiegen ist (At), wieder laufen lassen, und
-- allen sagen, dass die Sitz-Animation endet (das Spiel stoppt sie nur bei ihm selbst)
function Coop.Car.Release(Key, At)
    local C = Coop.Car
    local D = C.Drivers[Key] or C.Passengers[Key]
    C.Drivers[Key], C.Passengers[Key] = nil, nil
    -- ls_car: tote oder ersetzte Figur (Tod im Auto) nicht teleportieren und nicht laufen lassen
    if D and IsAlive(D.Pawn) and Coop.CarV2 and Coop.CarV2("pass")
        and (Safe(function() return D.Pawn["PlayerDead?"] end) == true
             or (IsAlive(D.PC) and Safe(function() return D.PC:K2_GetPawn() == D.Pawn end) ~= true)) then
        D.Pawn = nil
    end
    if D and IsAlive(D.Pawn) then
        if At then
            pcall(function()
                D.Pawn:K2_SetActorLocationAndRotation({ X = At.X, Y = At.Y, Z = At.Z }, { Pitch = 0, Yaw = At.Yaw, Roll = 0 }, false, {}, true)
            end)
        end
        pcall(function() local Move = D.Pawn.CharacterMovement if IsAlive(Move) then Move:SetMovementMode(1, 0) end end)   -- Walking
        pcall(function() D.Pawn:StopAnimMontage(nil) end)
        local Id = Safe(function() local PS = IsAlive(D.PC) and D.PC.PlayerState return IsAlive(PS) and PS.PlayerId or nil end)
        if Id then
            for _, PS in ipairs(PlayerStates(CurrentWorld())) do
                local Other = PS:GetOwner()
                if IsAlive(Other) and Safe(function() return not Other:IsLocalController() end, false) then
                    Coop.SendChunked(function(T) Coop.SendToClient(Other, T) end, "carexit", tostring(Id))
                end
            end
        end
    end
    if D and D.Passenger then
        -- CAR-12: hat der Fahrer die Kapsel/Handbremse fuer diesen Beifahrer offen gelassen (HeldOpen) und sitzt jetzt
        -- niemand mehr drin (kein Promote: beide tot/getrennt, Beifahrer ohne car2), hier nachholen. Nicht an car_pass
        -- gebunden (Core.Fail kann den Schalter inzwischen abgeschaltet haben).
        if C.HeldOpen and IsAlive(D.V) then
            local Addr = Safe(function() return D.V:GetAddress() end)
            if Addr and C.HeldOpen[Addr] then
                local Busy = false
                for _, X in pairs(C.Drivers) do if X.V == D.V then Busy = true break end end
                if not Busy then for _, X in pairs(C.Passengers) do if X.V == D.V then Busy = true break end end end
                if not Busy then
                    C.HeldOpen[Addr] = nil
                    pcall(function() local Me = Coop.Car.Mesh(D.V) if IsAlive(Me) then Me:SetCollisionResponseToChannel(2, 2) end end)   -- Pawn: Block (nachgeholt)
                    pcall(function() local M = D.V.VehicleMovementComponent if IsAlive(M) then M:SetThrottleInput(0) M:SetHandbrakeInput(true) end end)
                    Log("Fahrzeug %s: leer nach Beifahrer - Kapsel/Handbremse nachgeholt (CAR-12)", Safe(function() return D.V:GetFName():ToString() end, "?"))
                end
            end
        end
        return
    end
    if D and IsAlive(D.V) then
        do   -- ls_car: Server rechnet wieder mit eigenen Eingaben (vor der Handbremse unten)
            local Mod = Coop.CarV2 and Coop.CarV2("input")
            if Mod and Mod.HostRelease then pcall(Mod.HostRelease, D.V) end
        end
        if D.Nuf then pcall(function() D.V.NetUpdateFrequency = D.Nuf end) end   -- car_hz: alter Wert (s. "start")
        -- CAR-12 (car_pass): sitzt noch ein Beifahrer drin, uebernimmt ihn ls_car (Promote) - Kapsel nicht wieder blocken
        -- (das Auto stiess die sitzende Server-Figur sonst weg) und keine Handbremse, nur die Eingaben auf 0
        -- Nur Beifahrer zaehlen, die ls_car wirklich befoerdert (lebender Controller mit car2, Figur nicht tot); sonst
        -- blieb das Auto ohne Kollision/Handbremse. Offen gelassen: Merker HeldOpen, der letzte Beifahrer holt es nach.
        local Occupied = false
        if Coop.CarV2 and Coop.CarV2("pass") then
            for _, P in pairs(C.Passengers) do
                if P.V == D.V and IsAlive(P.PC) and Coop.CarV2("pass", P.PC)
                    and Safe(function() local Pw = P.PC:K2_GetPawn() return IsAlive(Pw) and Pw["PlayerDead?"] ~= true end, false) then
                    Occupied = true break
                end
            end
        end
        do
            local Addr = Safe(function() return D.V:GetAddress() end)
            if Addr and Occupied then
                C.HeldOpen = C.HeldOpen or {}
                C.HeldOpen[Addr] = true
            elseif Addr and C.HeldOpen then
                C.HeldOpen[Addr] = nil
            end
        end
        if not Occupied then
            pcall(function() Coop.Car.Mesh(D.V):SetCollisionResponseToChannel(2, 2) end)   -- Pawn: Block
        end
        -- Besitzer zurueck an den Kaeufer (ls_car car_buyown), sonst keiner: SetOwner(nil) nahm dem Kaeufer nach der
        -- ersten Fahrt den Besitz (seine NetServer-RPCs am Auto, z. B. Svr_UpdateFuel/Kofferraum, wurden verworfen)
        local CarMod = Coop.Modules and Coop.Modules.ls_car
        local Buyer = CarMod and CarMod.BuyerPC and Safe(function() return CarMod.BuyerPC(D.V) end) or nil
        if not IsAlive(Buyer) then Buyer = nil end
        pcall(function() D.V:SetOwner(Buyer) end)
        if Buyer then Log("Fahrzeug %s: Besitzer zurueck an Kaeufer", Safe(function() return D.V:GetFName():ToString() end, "?")) end
        -- ohne Fahrer stehen bleiben (sonst rollt es mit den letzten Eingaben weiter)
        pcall(function()
            local M = D.V.VehicleMovementComponent
            if not IsAlive(M) then return end
            M:SetThrottleInput(0)
            M:SetBrakeInput(0)
            M:SetSteeringInput(0)
            if not Occupied then M:SetHandbrakeInput(true) end
        end)
    end
end

function Coop.Car.Handle(PC, Key, Data)
    local C = Coop.Car
    local F = {}
    for Part in (Data .. "|"):gmatch("([^|]*)|") do F[#F + 1] = Part end
    local Cmd, N = F[1], function(I) return tonumber(F[I]) or 0 end
    if Cmd == "pose" then
        local D = C.Drivers[Key]
        if not (D and IsAlive(D.V)) then return end
        local V = D.V
        V:K2_SetActorLocationAndRotation({ X = N(2), Y = N(3), Z = N(4) }, { Pitch = N(5), Yaw = N(6), Roll = N(7) }, false, {}, true)
        local Mesh = C.Mesh(V)
        pcall(function() Mesh:SetPhysicsLinearVelocity({ X = N(8), Y = N(9), Z = N(10) }, false, FName("None")) end)
        pcall(function() Mesh:SetPhysicsAngularVelocityInDegrees({ X = N(11), Y = N(12), Z = N(13) }, false, FName("None")) end)
        if F[17] then
            -- ls_car: Schaden, den der Server seit der letzten Lage am Auto gemacht hat, vom Fahrerwert abziehen
            local Hp, Mod = N(16), Coop.CarV2 and Coop.CarV2("dmg")
            if Mod and Mod.PoseHp then
                local okH, NewHp = pcall(Mod.PoseHp, Key, V, Hp)
                if okH and type(NewHp) == "number" then Hp = NewHp end
            end
            -- Tank/Zustand sind nicht repliziert: vom Fahrer nur Verbrauch/Schaden annehmen (nie ueber den Host-Wert),
            -- Maxima immer vom Host (Tanken/Reparieren laeuft ueber "svc" bzw. car_svc beim Host)
            local Fuel, MaxFuel, MaxHp = N(14), N(15), N(17)
            local HS = C.HostState(V)
            if HS then
                C.ClampLogAt = C.ClampLogAt or {}
                local LogKey = V:GetFName():ToString()
                if (Fuel > HS[1] + 1 or Hp > HS[3] + 1) and os.clock() >= (C.ClampLogAt[LogKey] or 0) then
                    C.ClampLogAt[LogKey] = os.clock() + 10
                    Log("Fahrzeug %s: Gastwert Tank %.1f / Zustand %.1f ueber Host %.1f / %.1f - Host-Wert behalten",
                        V:GetFName():ToString(), Fuel, Hp, HS[1], HS[3])
                end
                Fuel, MaxFuel, Hp, MaxHp = math.min(Fuel, HS[1]), HS[2], math.min(Hp, HS[3]), HS[4]
            end
            C.ApplyState(V, Fuel, MaxFuel, Hp, MaxHp, false)
        end
        if IsAlive(D.Pawn) then pcall(C.PlacePawn, D.Pawn, V, false, D.Seat) end
        for _, P in pairs(C.Passengers) do
            if P.V == V and IsAlive(P.Pawn) then pcall(C.PlacePawn, P.Pawn, V, true, P.Seat) end
        end
    elseif Cmd == "seat" then
        local D = C.Drivers[Key] or C.Passengers[Key]
        if not (D and IsAlive(D.V)) then return end
        D.Seat = { X = N(2), Y = N(3), Z = N(4), Yaw = N(5) }
        if IsAlive(D.Pawn) then pcall(C.PlacePawn, D.Pawn, D.V, D.Passenger, D.Seat) end
        Log("Fahrzeug %s: Sitz %s %.0f/%.0f/%.0f", D.V:GetFName():ToString(), D.Passenger and "Beifahrer" or "Fahrer", N(2), N(3), N(4))
    elseif Cmd == "start" then
        C.Release(Key)
        for K, D in pairs(C.Drivers) do if not IsAlive(D.PC) then C.Release(K) end end   -- Fahrer getrennt
        for K, D in pairs(C.Passengers) do if not IsAlive(D.PC) then C.Release(K) end end
        if not IsAlive(PC) then return end
        -- CAR-7 (car_strict, E18/K29): zuerst das Auto zum Host-Schluessel des Gasts (5. Feld), dann wie bisher das naechste
        local Strict, V = Coop.CarV2("strict", PC), nil
        if Strict and F[5] and F[5]:match("^[%w_]+$") and type(Strict.HostByKey) == "function" then
            V = Safe(function() return Strict.HostByKey(F[5], N(2), N(3), N(4), C.NEAR) end)
            if not IsAlive(V) then V = nil end
        end
        -- K28 (Cap carnone = car_strict beim Gast): nur ein Gast mit carnone steigt auf "carnone" aus. Gaeste vor Runde 9
        -- oder mit car_strict=0 haben car2, verwerfen carnone aber und fuhren nach 1.5 s eine Geisterkopie. Nie
        -- Net.Has("carnone", nil) (prueft dann alle Gaeste). Host-ls_car ohne carnone-Cap (aelterer Stand): wie bisher.
        local NoneOk = false
        if Strict and Coop.Net then
            NoneOk = Safe(function()
                local NetM = Coop.Net
                if not (NetM.LocalCaps and NetM.LocalCaps.carnone) then return true end
                local G = NetM.ByPC(PC)
                return G ~= nil and NetM.Has("carnone", G) == true
            end, false) == true
        end
        V = V or C.Nearest({ X = N(2), Y = N(3), Z = N(4) }, C.NEAR)
        if not V then
            Log("Fahrzeug: kein Auto beim Mitspieler gefunden")
            if NoneOk then
                C.SendNone(PC, N(2), N(3), N(4), "none")   -- K28: Gast steigt aus statt blind zu fahren
            elseif Strict then
                Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "note", "Vehicle not synced - please re-enter")
            end
            return
        end
        local Pawn = PC:K2_GetPawn()
        Pawn = IsAlive(Pawn) and Pawn or nil
        if NoneOk and Pawn then   -- ohne carnone beim Gast wie vor Runde 9 annehmen (er stiege sonst nicht aus)
            -- Figur des Gasts beim Server mehr als 15 m vom Auto weg: Lage passt nicht, nicht einsteigen lassen
            local P, L = V:K2_GetActorLocation(), Pawn:K2_GetActorLocation()
            local D2 = (P.X - L.X) ^ 2 + (P.Y - L.Y) ^ 2 + (P.Z - L.Z) ^ 2
            if D2 > 1500 * 1500 then
                Log("Fahrzeug %s: Mitspieler %s %.0f m entfernt - abgelehnt", V:GetFName():ToString(), Key:match("[^%.]+$") or Key, math.sqrt(D2) / 100)
                C.SendNone(PC, N(2), N(3), N(4), "far")
                return
            end
        end
        -- CAR-8 (car_lock, E18): abgeschlossenes Auto nur fuer Besitzer/Clan (ls_car M.CanUse). Nur der Host-Schalter
        -- zaehlt (nicht car2 des Gasts): sonst fuhr jeder Gast mit car_v2=0/altem Mod abgeschlossene Autos.
        local Lock = Coop.CarV2("lock")
        if Lock and type(Lock.CanUse) == "function" then
            local okU, Can = pcall(Lock.CanUse, PC, V)
            if okU and Can ~= true then
                Log("Fahrzeug %s: abgeschlossen - %s darf nicht einsteigen", V:GetFName():ToString(), Key:match("[^%.]+$") or Key)
                if NoneOk then
                    C.SendNone(PC, N(2), N(3), N(4), "locked")
                else
                    -- Gast ohne carnone: "carbusy" (kennt jede Version) = Beifahrer ohne Fahren, keine Geisterkopie; dazu Hinweis
                    Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "carbusy", string.format("%.0f|%.0f|%.0f", N(2), N(3), N(4)))
                    Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "note", "Vehicle is locked")
                end
                return
            end
        end
        if Pawn then pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:DisableMovement() end end) end
        -- Sitzt schon jemand am Steuer: Beifahrer (das Spiel kennt nur den Fahrersitz; der Spieler setzt sich selbst
        -- auf die andere Seite und faehrt nicht mit, "carbusy")
        for _, D in pairs(C.Drivers) do
            if D.V == V then
                C.Passengers[Key] = { V = V, PC = PC, Pawn = Pawn, Passenger = true }
                local P = V:K2_GetActorLocation()
                Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "carbusy", string.format("%.0f|%.0f|%.0f", P.X, P.Y, P.Z))
                if Pawn then pcall(C.PlacePawn, Pawn, V, true) end
                Log("Fahrzeug %s: Beifahrer %s", V:GetFName():ToString(), Key:match("[^%.]+$") or Key)
                return
            end
        end
        C.Drivers[Key] = { V = V, PC = PC, Pawn = Pawn }
        -- car_hz > 0: Auto so oft replizieren, wie der Fahrer Lagen schickt (nur Fahrer, nicht Beifahrer); der alte
        -- Wert kommt in Release zurueck (Aussteigen, Tod, Trennen; beim Wechsel erst das alte Auto, dann dieses).
        -- Nur anheben: Ist der Wert des Spiels schon hoeher (Unreal-Standard 100), bleibt er.
        if SETTINGS.car_hz > 0 then
            local D, Hz = C.Drivers[Key], math.floor(1 / C.RATE + 0.5)
            D.Nuf = Safe(function() return V.NetUpdateFrequency end)
            if type(D.Nuf) == "number" and D.Nuf < Hz then
                pcall(function() V.NetUpdateFrequency = Hz end)
                if not C.NufLogged then C.NufLogged = true Log("Fahrzeug: NetUpdateFrequency %.0f -> %d (car_hz)", D.Nuf, Hz) end
            else
                if not C.NufLogged then C.NufLogged = true Log("Fahrzeug: NetUpdateFrequency bleibt %s (car_hz %d)", tostring(D.Nuf), Hz) end
                D.Nuf = nil
            end
        end
        if Pawn then pcall(C.PlacePawn, Pawn, V, false) end
        pcall(function() C.Mesh(V):SetCollisionResponseToChannel(2, 0) end)   -- Pawn: Ignore (wie beim Fahrer)
        pcall(function() local M = V.VehicleMovementComponent if IsAlive(M) then M:SetHandbrakeInput(false) end end)
        -- Die Figur beim Server NICHT ans Auto haengen: die Anhaengung wird repliziert und ersetzt beim Spieler die des
        -- Spiels (KeepWorld: Spieler neben dem Auto; Sitz per Snap: Auto flog weg). Sie bleibt beim Server am Einstieg
        -- stehen; beim Aussteigen setzt Release sie an die Stelle des Spielers (sonst zog sie ihn zurueck).
        -- Besitzer = Fahrer: dann nimmt der Server dessen Gas/Lenkung an (ChaosVehicle ServerUpdateState, sonst
        -- verworfen) und rechnet zwischen den Lage-Meldungen gleich weiter
        pcall(function() V:SetOwner(PC) end)
        do
            local P = V:K2_GetActorLocation()
            Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "cardriver", string.format("%.0f|%.0f|%.0f", P.X, P.Y, P.Z))
        end
        -- Stand des Servers (letzter Fahrer, Tanken) an den neuen Fahrer
        local ok, State = pcall(C.State, V)
        if ok then
            local P = V:K2_GetActorLocation()
            Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "carstate", string.format("%.0f|%.0f|%.0f|%s|0", P.X, P.Y, P.Z, State))
        end
        Log("Fahrzeug %s: faehrt jetzt %s", V:GetFName():ToString(), Key:match("[^%.]+$") or Key)
    elseif Cmd == "stop" then
        C.Release(Key, F[5] and { X = N(2), Y = N(3), Z = N(4), Yaw = N(5) } or nil)
    elseif Cmd == "sync" then
        if IsAlive(PC) and not (Coop.CarV2 and Coop.CarV2("fx", PC)) then C.SendAll(PC, Key) end   -- ls_car: car_s (Vollauffrischung bei ready)
    elseif Cmd == "svc" then
        local What, Pawn = F[2], IsAlive(PC) and PC:K2_GetPawn() or nil
        local V = C.Nearest({ X = N(3), Y = N(4), Z = N(5) }, 500)
        if not (V and IsAlive(Pawn) and C.ITEMS[What]) then
            Log("Fahrzeug: %s abgelehnt (Auto %s, Figur %s)", tostring(What), tostring(V ~= nil), tostring(IsAlive(Pawn)))
            return
        end
        -- Immer der Stand des Servers: Tank/Zustand sind nicht repliziert, der Gastwert (N 6-9) ist ungeprueft (MaxFuel
        -- beliebig hoch = beliebig voll, alter Stand = Tank leerer). Waehrend der Fahrt haelt "pose" den Host-Wert aktuell.
        -- Vor dem Verbrauch lesen: nicht lesbar -> abgelehnt, ohne den Kanister/das Werkzeug zu nehmen
        local HS = C.HostState(V)
        if not HS then Log("Fahrzeug: %s abgelehnt (Tank/Zustand beim Server nicht lesbar)", tostring(What)) return end
        local Note = function(T) Coop.SendChunked(function(X) Coop.SendToClient(PC, X) end, "note", T) end
        -- CAR-8 (car_lock, handoff car): alter svc-Weg (Gaeste ohne car_svc v2) tankt/repariert sonst auch abgeschlossene
        -- Autos. Vor dem Verbrauch pruefen; CanUse = true ohne car_lock oder bei offenem Auto
        do
            local L = Coop.CarV2 and Coop.CarV2("lock")
            if L and type(L.CanUse) == "function" then
                local okU, Can = pcall(L.CanUse, PC, V)
                if okU and Can ~= true then
                    Log("Fahrzeug %s: %s abgelehnt (abgeschlossen)", V:GetFName():ToString(), tostring(What))
                    Note("Vehicle is locked")
                    return
                end
            end
        end
        local Item = StaticFindObject(C.ITEMS[What])
        if not IsAlive(Item) then Item = Safe(function() return LoadAsset(C.ITEMS[What]) end) end
        local Out = {}
        local R = Safe(function() local Inv = Pawn.BP_JigMultiplayer return IsAlive(Inv) and IsAlive(Item) and Inv:ServerFindThenConsumeByItemID(Item, 1, Out) or nil end)
        if not (R == true or Out.Result == true) then
            Log("Fahrzeug: %s - nichts im Inventar (Antwort %s/%s)", What, tostring(R), tostring(Out.Result))
            Note(What == "gas" and "No gas can in your inventory" or "No repair kit in your inventory")
            return
        end
        local Fuel, MaxFuel, Health, MaxHealth = HS[1], HS[2], HS[3], HS[4]
        if N(7) > 0 and (math.abs(N(6) - Fuel) > 1 or math.abs(N(8) - Health) > 1) then
            Log("Fahrzeug %s: Gastwert Tank %.1f / Zustand %.1f verworfen, Host %.1f / %.1f", V:GetFName():ToString(), N(6), N(8), Fuel, Health)
        end
        if What == "gas" then Fuel = math.min(Fuel + MaxFuel / 2, MaxFuel) else Health = math.min(Health + MaxHealth / 2, MaxHealth) end
        C.ApplyState(V, Fuel, MaxFuel, Health, MaxHealth, What == "repair")
        local P = V:K2_GetActorLocation()
        local Line = string.format("%.0f|%.0f|%.0f|%.1f|%.1f|%.1f|%.1f|%d", P.X, P.Y, P.Z, Fuel, MaxFuel, Health, MaxHealth, What == "repair" and 1 or 0)
        for _, PS in ipairs(PlayerStates(CurrentWorld())) do
            local Other = PS:GetOwner()
            if IsAlive(Other) and Safe(function() return not Other:IsLocalController() end, false) then
                Coop.SendChunked(function(X) Coop.SendToClient(Other, X) end, "carstate", Line)
            end
        end
        Note(What == "gas" and "Vehicle refueled" or "Vehicle repaired")
        Log("Fahrzeug %s: %s (Tank %.0f/%.0f, Zustand %.0f/%.0f)", V:GetFName():ToString(), What, Fuel, MaxFuel, Health, MaxHealth)
    end
end

-- Gegenstaende, die das Spiel beim Mitspieler nur lokal anlegt (Einzelspieler-Code): JigTryAddItemSomewhere
-- legt sie "wartend" ins Inventar (blinkt, gesperrt), der Server erfaehrt nichts davon und bestaetigt nie
-- (RemoveRequestByUID). Beispiel: leere Flasche nach dem Austrinken (HotBarConsume), Auffuellen am Brunnen.
-- Ohne Bestaetigung nach 3 s: den Server bitten, ihn anzulegen ("pend"); er gleicht danach das Inventar neu ab,
-- das ersetzt auch den wartenden Platz. Mit Bestaetigung (der Server legt selbst an) nichts tun: sonst doppelt.
-- AUS (20.10.): Spiel stuerzte beim Laden ab (0xc0000028), genau als diese Hooks (RemoveRequestByUID,
-- JigTryAddItemSomewhere) erstmals registriert wurden. Ersatz geplant: beim Server nach dem Verbrauch anlegen.
Coop.Pending = { ENABLED = false, WAIT = 3, Adds = {}, Hooked = false, ConfirmedAt = 0 }

function Coop.Pending.OnAdd(Comp, Item, Count, Added)
    local P = Coop.Pending
    if NetModeName(CurrentWorld()) ~= "Client" or not Added:get() then return end
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) or Comp:get():GetAddress() ~= Safe(function() local Inv = Pawn.BP_JigMultiplayer return IsAlive(Inv) and Inv:GetAddress() or nil end) then return end
    local Path = Safe(function() local I = Item:get() return IsAlive(I) and I:GetFullName():match("^%S+%s+(%S+)$") or nil end)
    if Path then P.Adds[#P.Adds + 1] = { Path = Path, Count = Count:get(), At = os.clock() } end
end

function Coop.Pending.Tick()
    local P = Coop.Pending
    if not P.ENABLED then return end
    if not P.Hooked then
        local Jig = Coop.Car.JIG
        if not IsAlive(StaticFindObject(Jig)) then return end
        P.Hooked = true
        -- Ohne die Bestaetigung waere nicht zu erkennen, ob der Server selbst anlegt: dann gar nicht weiterleiten
        P.Ready = TryHook(Jig .. ":RemoveRequestByUID", function() Coop.Pending.ConfirmedAt = os.clock() end) ~= nil
        if P.Ready then
            -- ACHTUNG (bp_hook_first): JigTryAddItemSomewhere ist eine BP-Funktion (BP_JigComponent_C FLAGS 0x0cc20000).
            -- UE4SS 3.0.1 ruft bei BP-Funktionen nur den ERSTEN Callback (nach dem BP-Rumpf): der Koerper hier im zweiten
            -- ist tot. Falls Coop.Pending je wieder eingeschaltet wird, den Koerper als ersten Callback uebergeben
            -- (Inventar-Interna, heisse Funktion: nur Tabelle fuellen). Solange ENABLED = false bleibt das hier inert.
            TryHook(Jig .. ":JigTryAddItemSomewhere", function() end, function(_, Comp, Item, Count, Added)
                pcall(Coop.Pending.OnAdd, Comp, Item, Count, Added)
            end)
        end
    end
    local Now, Keep = os.clock(), {}
    for _, A in ipairs(P.Adds) do
        if P.ConfirmedAt >= A.At then
            -- bestaetigt: Server hat es selbst
        elseif Now - A.At >= P.WAIT then
            Coop.SendChunked(Coop.SendToHost, "pend", A.Path .. " " .. tostring(A.Count))
            Log("Gegenstand nur lokal angelegt (%s x%s): beim Server angefragt", A.Path:match("([^%.]+)$") or A.Path, tostring(A.Count))
        else
            Keep[#Keep + 1] = A
        end
    end
    P.Adds = Keep
end

-- Mitspieler: Tank/Zustand eines Autos vom Server ("x|y|z|Tank|MaxTank|Zustand|MaxZustand|repariert")
function Coop.Car.ApplyLine(Line)
    local C, F = Coop.Car, {}
    for Part in (Line .. "|"):gmatch("([^|]*)|") do F[#F + 1] = tonumber(Part) or 0 end
    if #F < 7 then return end
    local V = C.Nearest({ X = F[1], Y = F[2], Z = F[3] }, 500)
    if not V then return end
    if V == C.Driving then
        if C.StateOk then return end   -- beim Fahrer zaehlt sein eigener Verbrauch
        C.StateOk = true
    end
    C.ApplyState(V, F[4], F[5], F[6], F[7], F[8] == 1)
end

Coop.HostDataHandlers.carstate = function(Text)
    ExecuteInGameThread(function()
        local V = nil
        pcall(function()
            local F = {}
            for Part in (Text .. "|"):gmatch("([^|]*)|") do F[#F + 1] = tonumber(Part) or 0 end
            V = Coop.Car.Nearest({ X = F[1], Y = F[2], Z = F[3] }, 500)
        end)
        if V and V == Coop.Car.Driving then Coop.Car.StateOk = false end   -- Stand vom Server gilt (Start, Tanken)
        pcall(Coop.Car.ApplyLine, Text)
    end)
end

-- Mitspieler: Auto hat schon einen Fahrer -> Beifahrer (OnTick setzt um)
Coop.HostDataHandlers.carbusy = function(Text)
    local X, Y, Z = Text:match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)")
    ExecuteInGameThread(function()
        local V = Coop.Car.Nearest({ X = tonumber(X) or 0, Y = tonumber(Y) or 0, Z = tonumber(Z) or 0 }, 800)
        if V and V == Coop.Car.Driving then Coop.Car.PassengerOf, Coop.Car.PassengerSet = V, false end
    end)
end

-- Mitspieler: Server bestaetigt den Fahrersitz -> Auto selbst rechnen
Coop.HostDataHandlers.cardriver = function(Text)
    local X, Y, Z = Text:match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)")
    ExecuteInGameThread(function()
        local V = Coop.Car.Nearest({ X = tonumber(X) or 0, Y = tonumber(Y) or 0, Z = tonumber(Z) or 0 }, 800)
        if V and V == Coop.Car.Driving then pcall(Coop.Car.StartDriving, V) end
    end)
end

-- Mitspieler: ein anderer ist ausgestiegen -> seine Sitz-Animation beenden
Coop.HostDataHandlers.carexit = function(Text)
    local Id = tonumber(Text)
    ExecuteInGameThread(function()
        for _, PS in ipairs(PlayerStates(CurrentWorld())) do
            if Safe(function() return PS.PlayerId end) == Id then
                local Pawn = Safe(function() return PS:GetPawn() end)
                if IsAlive(Pawn) then pcall(function() Pawn:StopAnimMontage(nil) end) end
            end
        end
    end)
end

-- Mitspieler: Tank/Zustand aller (geaenderten) Autos, eine Zeile je Auto (Server: HostTick)
Coop.HostDataHandlers.cars = function(Text)
    ExecuteInGameThread(function()
        for Line in Text:gmatch("[^\n]+") do pcall(Coop.Car.ApplyLine, Line) end
    end)
end

-- Server: Tank/Zustand aller Autos an einen Mitspieler (er fragt an, sobald seine Figur steht: "sync"; vorher hat
-- er die Autos oft noch nicht und die Zeilen gingen ins Leere)
function Coop.Car.SendAll(PC, Key)
    local C, Lines = Coop.Car, {}
    local Own = C.Drivers[Key] and C.Drivers[Key].V
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if IsAlive(V) and V ~= Own then
            local ok, State = pcall(C.State, V)
            if ok then
                local P = V:K2_GetActorLocation()
                Lines[#Lines + 1] = string.format("%.0f|%.0f|%.0f|%s|0", P.X, P.Y, P.Z, State)
            end
        end
    end
    if #Lines > 0 then Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "cars", table.concat(Lines, "\n")) end
end

-- Server, jede Sekunde: Tank/Zustand sind nicht repliziert. Alle 5 s die geaenderten Autos an alle, alle 30 s alle
-- (ohne das Auto, das einer selbst faehrt: dort zaehlt sein eigener Verbrauch).
function Coop.Car.HostTick(World)
    local C = Coop.Car
    if NetModeName(World) ~= "ListenServer" or os.time() < (C.HostAt or 0) then return end
    C.HostAt = os.time() + 5
    C.Last, C.Known = C.Last or {}, C.Known or {}
    if os.time() >= (C.FullAt or 0) then C.FullAt, C.Known = os.time() + 30, {} end
    local All, Changed = {}, {}
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if IsAlive(V) then
            local ok, State = pcall(C.State, V)
            if ok then
                local P, Addr = V:K2_GetActorLocation(), V:GetAddress()
                local Line = { V = V, Text = string.format("%.0f|%.0f|%.0f|%s|0", P.X, P.Y, P.Z, State) }
                All[#All + 1] = Line
                if C.Last[Addr] ~= State then
                    if C.Last[Addr] ~= nil then Changed[#Changed + 1] = Line end
                    C.Last[Addr] = State
                end
            end
        end
    end
    local Seen = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            Seen[Key] = true
            local Own = C.Drivers[Key] and C.Drivers[Key].V
            local Lines = {}
            -- ls_car: Gaeste mit Cap car2 bekommen Tank/Zustand ueber den Keyed-State car_s statt "cars"
            local CarV2 = Coop.CarV2 and Coop.CarV2("fx", PC)
            for _, L in ipairs(CarV2 and {} or (C.Known[Key] and Changed or All)) do
                if L.V ~= Own then Lines[#Lines + 1] = L.Text end
            end
            C.Known[Key] = true
            if #Lines > 0 then Coop.SendChunked(function(T) Coop.SendToClient(PC, T) end, "cars", table.concat(Lines, "\n")) end
        end
    end
    for Key in pairs(C.Known) do if not Seen[Key] then C.Known[Key] = nil end end
end
end

do
-- Himmel: Uhrzeit (Ultra Dynamic Sky) und Wetter (Ultra Dynamic Weather) laufen auf jedem Rechner
-- selbst, das Wetter wuerfelt jeder fuer sich. Der Host schickt alle 2 s seinen Stand: Uhrzeit, die
-- Werte des Wetters (mit "Manual Override"), die beiden Wetterzustaende, aus denen UDW pro Bild rechnet
-- (Global/Local Weather State), das Wetter-Preset und Wolken/Nebel/Staub am Himmel. Der Mitspieler
-- uebernimmt alles, bricht eigene Wetterwechsel ab; die Uhrzeit nur bei Abweichung (laeuft fluessig weiter).
local S = { EVERY = 2, At = 0,
            UDW = { "Cloud Coverage", "Rain", "Snow", "Thunder/Lightning", "Wind Intensity", "Fog", "Dust",
                    "Material Wetness", "Material Snow Coverage", "Material Dust Coverage" },
            UDS = { "Cloud Coverage", "Fog", "Dust Amount" },
            STATES = { gws = "Global Weather State", lws = "Local Weather State" } }

-- Nie den Himmel des Hauptmenue-Teillevels nehmen (bleibt beim Mitspieler erst geladen, siehe unten)
function S.Actors()
    local function Pick(Class)
        for _, A in ipairs(FindAllOf(Class) or {}) do
            if IsAlive(A) and not A:GetFullName():find("/MainMenu%.") then return A end
        end
    end
    return Pick("Ultra_Dynamic_Sky_C"), Pick("Ultra_Dynamic_Weather_C")
end

function S.Collect(Sky, Weather)
    local Parts = {}
    local function Add(Prefix, Owner, Field)
        local V = Safe(function() return Owner[Field] end)
        if type(V) == "number" then Parts[#Parts + 1] = string.format("%s.%s=%.4f", Prefix, Field, V) end
    end
    if Sky then
        Add("uds", Sky, "Time of Day")
        for _, F in ipairs(S.UDS) do Add("uds", Sky, F) end
    end
    if Weather then
        for _, F in ipairs(S.UDW) do Add("udw", Weather, F) end
        Add("udw", Weather, "Wind Direction")
        for Prefix, Name in pairs(S.STATES) do
            local State = Safe(function() return Weather[Name] end)
            if IsAlive(State) then
                for _, F in ipairs(S.UDW) do Add(Prefix, State, F) end
            end
        end
        local Preset = Safe(function() local P = Weather.Weather return IsAlive(P) and P:GetPathName() or nil end)
        if Preset and Preset:match("^/Game/") then Parts[#Parts + 1] = "preset.Path=" .. Preset end
    end
    return Parts
end

-- Ultra Dynamic Sky/Weather koennen sich selbst replizieren (Replicated Time of Day, Clients Transition
-- Start, Initial Replication): Dann rechnet nur der Host Uhrzeit und Wetter, der Mitspieler uebernimmt.
-- Im Einzelspieler-Level ist die Replikation aber aus. Beim Host einschalten; der Mitspieler nutzt die
-- eigenen Werte unten nur, solange sein Himmel noch lokal laeuft (Rolle Authority).
function S.EnableReplication(Sky, Weather)
    for _, Actor in ipairs({ Sky or false, Weather or false }) do
        if Actor and not Actor.bReplicates then
            Actor:SetReplicates(true)
            pcall(function() Actor.bAlwaysRelevant = true end)
            Log("Replikation eingeschaltet: %s (NetLoadOnClient=%s)", Actor:GetClass():GetFName():ToString(),
                tostring(Safe(function() return Actor.bNetLoadOnClient end)))
        end
    end
    if not S.CountLogged then
        S.CountLogged = true
        Log("Himmel beim Host: %d Sky, %d Wetter", #(FindAllOf("Ultra_Dynamic_Sky_C") or {}), #(FindAllOf("Ultra_Dynamic_Weather_C") or {}))
    end
end

-- Mitspieler: Laeuft sein Himmel schon ueber die Replikation (Rolle Simulated/Autonomous Proxy)?
function S.Replicated(Sky, Weather)
    local function Proxy(A) return A and Safe(function() local R = A:GetLocalRole() return R == 1 or R == 2 end, false) end
    return (not Sky or Proxy(Sky)) and (not Weather or Proxy(Weather)) and (Sky or Weather) ~= nil
end

-- Mitspieler: Das Hauptmenue-Teillevel (MainMenu) bleibt nach dem Beitritt geladen, samt eigenem Himmel
-- und Wetter. Zwei Himmel ueberlagerten sich (Flackern, falsche Uhrzeit), der echte aus LongdownValley
-- kommt per Replikation vom Host. Der Host entlaedt das Menue beim Spielstart selbst, hier nachholen.
function S.UnloadMenuLevel(World)
    local Done = false   -- CORE-31: true = Menue-Teillevel entladen (der Aufrufer prueft dann in dieser Welt nicht mehr)
    World.StreamingLevels:ForEach(function(_, Entry)
        local Level = Entry:get()
        if IsAlive(Level) and Level:ShouldBeLoaded() and Level:GetWorldAssetPackageFName():ToString():find("/MainMenu$") then
            Level:SetShouldBeVisible(false)
            Level:SetShouldBeLoaded(false)
            Done = true
            Log("Hauptmenue-Teillevel beim Mitspieler entladen (zweiter Himmel)")
        end
    end)
    return Done
end
Coop.UnloadMenuLevel = S.UnloadMenuLevel
Coop.ResetSky = function() S.FirstSkyAt, S.OverridesCleared, S.ClientCountLogged, S.ReplLogged = nil, nil, nil, nil end
Coop.SkyForget = function(Key) if S.SentTo then S.SentTo[Key] = nil end end   -- CORE-30 (Coop.ForgetKey)

function S.HostTick(World)
    if NetModeName(World) ~= "ListenServer" or os.time() < S.At then return end
    S.At = os.time() + S.EVERY
    -- X29: gemischte Sitzung - Gaeste mit wld2 bekommen w_sky ueber v3 (ls_world), der alte Weg nur fuer die anderen
    local Net, Core = Coop.Net, Coop.Modules and Coop.Modules.ls_core
    local V3Sky = Coop.Modules and Coop.Modules.ls_world and Net and Core and Safe(function()
        return Core.Flag("world_v2", true) and Core.Flag("world_sky", true) and Net.Enabled()
    end, false)
    local PCs = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false)
            and not (V3Sky and Safe(function() return Net.Has("wld2", PC:GetFullName()) end, false)) then
            PCs[#PCs + 1] = PC
        end
    end
    if #PCs == 0 then return end
    local Sky, Weather = S.Actors()
    S.EnableReplication(Sky, Weather)
    local Parts = S.Collect(Sky, Weather)
    if not S.HostLogged then
        S.HostLogged = true
        Log("Himmel-Sync: Sky=%s Wetter=%s (%d Werte)", tostring(Sky ~= nil), tostring(Weather ~= nil), #Parts)
    end
    if #Parts == 0 then return end
    local Text = table.concat(Parts, ";")
    -- Nur bei Aenderung (je Spieler: neue Spieler bekommen es sofort), zur Sicherheit alle 30 s noch einmal
    S.SentTo = S.SentTo or {}
    local Now = os.time()
    local Again = Now >= (S.AgainAt or 0)
    if Again then S.AgainAt = Now + 30 end
    for _, PC in ipairs(PCs) do
        local Key = PC:GetFullName()
        if Again or S.SentTo[Key] ~= Text then
            S.SentTo[Key] = Text
            Coop.SendChunked(function(T) SendToClient(PC, T) end, "sky", Text)
        end
    end
end

function S.ApplyOne(Sky, Weather, Kind, Field, Value)
    if Kind == "preset" then
        if not Weather then return false end
        local Cur = Safe(function() local P = Weather.Weather return IsAlive(P) and P:GetPathName() or nil end)
        if Cur == Value then return true end
        local Preset = StaticFindObject(Value)
        if not IsAlive(Preset) then return false end
        Weather["Change Weather"](Weather, Preset, 0.0)
        return true
    end
    local N = tonumber(Value)
    if not N then return false end
    if Kind == "uds" and Sky then
        if Field == "Time of Day" then
            local D = math.abs(Sky[Field] - N)
            if math.min(D, 2400 - D) > 10 then Sky[Field] = N end  -- 0..2400, 10 = 6 Minuten
        elseif Sky[Field] ~= N then
            Sky[Field] = N
        end
    elseif Kind == "udw" and Weather then
        if Weather[Field] ~= N then Weather[Field] = N end
        local Override = Field .. " - Manual Override"
        if Field ~= "Wind Direction" and Weather[Override] ~= true then Weather[Override] = true end
    elseif S.STATES[Kind] and Weather then
        local State = Weather[S.STATES[Kind]]
        if not IsAlive(State) then return false end
        if State[Field] ~= N then State[Field] = N end
    else
        return false
    end
    return true
end

Coop.HostDataHandlers.sky = function(Text)
    local Sky, Weather = S.Actors()
    if not S.ClientCountLogged then
        S.ClientCountLogged = true
        Log("Himmel beim Mitspieler: %d Sky, %d Wetter, Rollen %s/%s", #(FindAllOf("Ultra_Dynamic_Sky_C") or {}),
            #(FindAllOf("Ultra_Dynamic_Weather_C") or {}), tostring(Safe(function() return Sky:GetLocalRole() end)),
            tostring(Safe(function() return Weather:GetLocalRole() end)))
    end
    -- Kommt der Himmel per Replikation, das Wetter nicht selbst setzen (Manual Override hielt es sonst fest)
    -- und frueher gesetzte Overrides einmal loeschen. Wolken/Nebel/Staub des Himmels (UDS) repliziert
    -- UDS nicht selbst: die weiter uebernehmen (die Uhrzeit repliziert UDS).
    if S.Replicated(Sky, Weather) then
        if not S.ReplLogged then S.ReplLogged = true Log("Himmel kommt per Replikation vom Host") end
        if Weather and not S.OverridesCleared then
            S.OverridesCleared = true
            for _, F in ipairs(S.UDW) do pcall(function() Weather[F .. " - Manual Override"] = false end) end
        end
        for Key, Value in Text:gmatch("([^=;]+)=([^;]+)") do
            local Kind, Field = Key:match("^(%a+)%.(.+)$")
            if Kind == "uds" and Field ~= "Time of Day" then pcall(S.ApplyOne, Sky, Weather, Kind, Field, Value) end
        end
        return
    end
    -- Rueckfall nur, wenn der Himmel auch 15 s nach der ersten Nachricht noch nicht repliziert wird (gleich
    -- nach dem Beitritt ist er kurz noch lokal - damals gesetzte Overrides hielten das Wetter fest)
    S.FirstSkyAt = S.FirstSkyAt or os.time()
    if os.time() - S.FirstSkyAt < 15 then return end
    -- Eigenen Wetterwechsel abbrechen (sonst blendet UDW zu einem lokal gewuerfelten Wetter ueber)
    if Weather then pcall(function() if Weather["Transition Active"] then Weather["Transition Active"] = false end end) end
    local Count, Failed = 0, {}
    for Key, Value in Text:gmatch("([^=;]+)=([^;]+)") do
        local Kind, Field = Key:match("^(%a+)%.(.+)$")
        local ok, Done = pcall(S.ApplyOne, Sky, Weather, Kind, Field, Value)
        if ok and Done then Count = Count + 1 else Failed[#Failed + 1] = Key end
    end
    if not S.ClientLogged then
        S.ClientLogged = true
        Log("Himmel vom Host uebernommen: %d Werte (Sky=%s Wetter=%s)%s", Count, tostring(Sky ~= nil),
            tostring(Weather ~= nil), #Failed > 0 and (", nicht gesetzt: " .. table.concat(Failed, ", ")) or "")
    end
end

Coop.SkyHostTick = S.HostTick
end

do
-- Munitions-Anzeige (AmmoBox im BP_Ingame): Im Koop stand sie bei der Schrotflinte genau verkehrt
-- herum (beim Wegstecken sichtbar, in der Hand weg). Fuer die eigene Figur darum selbst setzen:
-- sichtbar genau dann, wenn die aktuelle Schusswaffe in der rechten Hand (Hand-Socket "*_r") haengt.
local H = { VISIBLE = 4, HIDDEN = 2 }  -- ESlateVisibility: SelfHitTestInvisible / Hidden

-- CurrentFiringWeapon taugt nicht (bleibt z. B. bei der Schrotflinte in der Hand leer): Was am Socket
-- Weapon_r haengt und eine Schusswaffe ist (Klasse BP_FirearmPickup_C oder davon abgeleitet), ist in der
-- Hand. Ueber die Klassen-Kette statt eines Pfads (ein falscher Pfad hiess: Anzeige nie sichtbar).
H.IsFirearmClass = {}  -- [Klassenname] = true/false

function H.IsFirearm(Actor)
    local Class = Actor:GetClass()
    local Name = Class:GetFName():ToString()
    if H.IsFirearmClass[Name] == nil then
        local Found, C = false, Class
        while C and C:IsValid() do
            if C:GetFName():ToString() == "BP_FirearmPickup_C" then Found = true break end
            C = C:GetSuperStruct()
        end
        H.IsFirearmClass[Name] = Found
    end
    return H.IsFirearmClass[Name]
end

-- Runde 3: jeder Hand-Socket (Coop.IsHandSocket: Weapon_r, Sidearm_r, MeleeWeapon_r), nicht nur Weapon_r - die Glock
-- haengt in der Hand an Sidearm_r (Anzeige verschwand ~1 s nach jedem Schuss). Mehrere in der Hand: die, die
-- CurrentFiringWeapon ist. CurrentFiringWeapon allein zaehlt nicht (bleibt nach dem Wegstecken gesetzt).
function H.FirearmInHand(Pawn)
    -- COMBAT-3 (E9): erst die aktive Waffe nach Spiel-Sicht (ls_combat), die Socket-Suche nur als Rueckfall
    local Active, _, Decided = Coop.ActiveHand(Pawn)
    if Active then
        if H.IsFirearm(Active) then return true, Active end
        return false
    end
    if Decided then return false end
    local Attached, Found = {}, nil
    Pawn:GetAttachedActors(Attached, true, false)
    local Current = Safe(function() return Pawn.CurrentFiringWeapon end)
    local CurAddr = IsAlive(Current) and Current:GetAddress() or nil
    for _, Entry in ipairs(Attached) do
        local W = Entry:get()
        if IsAlive(W) and Coop.IsHandSocket(W:GetAttachParentSocketName():ToString()) and H.IsFirearm(W) then
            if CurAddr and W:GetAddress() == CurAddr then return true, W end
            Found = Found or W
        end
    end
    if Found then return true, Found end
    return false
end

-- Die Schuss-Zahl liest UpdateAmmoCount aus CurrentFiringWeapon, das beim Mitspieler erst der erste
-- Schuss setzt (bis dahin "0"). Darum beim Ziehen selbst setzen und die Anzeige neu berechnen lassen.
function H.FixAmmoCount(Pawn, Weapon)
    local Current = Safe(function() return Pawn.CurrentFiringWeapon end)
    if IsAlive(Current) and Current:GetAddress() == Weapon:GetAddress() then return end
    Pawn.CurrentFiringWeapon = Weapon
    pcall(function() Pawn:UpdateAmmoCount() end)
    if (H.AmmoLogCount or 0) < 3 then
        H.AmmoLogCount = (H.AmmoLogCount or 0) + 1
        Log("Munitions-Anzeige: aktuelle Waffe gesetzt (%s)", Weapon:GetClass():GetFName():ToString())
    end
end

-- Waffenname (unten rechts) setzt beim Mitspieler erst der erste Schuss: beim Ziehen selbst setzen, einmal je Waffe in
-- der Hand. Name = Daten-Asset der Waffe (BP_JigPickupComponent.ItemDataAsset.Name, FText) -> BP_Ingame:UpdateFirearmName.
function H.FixName(UI, Weapon)
    local Addr = Weapon:GetAddress()
    if H.NameFor == Addr then return end
    H.NameFor = Addr
    local DA = Safe(function() local PC = Weapon.BP_JigPickupComponent return IsAlive(PC) and PC.ItemDataAsset or nil end)
    local Name = IsAlive(DA) and Safe(function() return DA.Name end) or nil
    if Name then pcall(function() UI:UpdateFirearmName(Name) end) end
end

-- Das Spiel blendet die Anzeige auch ueber Animationen (Deckkraft) ein und aus. Stand die verkehrt auf
-- 0, half das Sichtbar-Schalten nichts: beim Einblenden darum auch die Deckkraft auf 1 setzen.
function H.Check()
    if not MultiplayerActive or NetModeName(CurrentWorld()) ~= "Client" then return end  -- nur der Mitspieler war betroffen
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) then return end
    local UI = Safe(function() return Pawn.InGameUI end)
    local Box = IsAlive(UI) and Safe(function() return UI.AmmoBox end)
    if not IsAlive(Box) then return end
    local Want, Weapon = H.FirearmInHand(Pawn)
    if Want then
        local ok, err = pcall(H.FixAmmoCount, Pawn, Weapon)
        if not ok and not H.FixErr then H.FixErr = true Log("Munitions-Zahl-Fehler: %s", tostring(err)) end
        pcall(H.FixName, UI, Weapon)
    else
        H.NameFor = nil   -- weggesteckt: beim naechsten Ziehen den Namen wieder setzen
    end
    local Vis = Box:GetVisibility()
    local Shown = Vis ~= 1 and Vis ~= 2
    if Want ~= Shown then Box:SetVisibility(Want and H.VISIBLE or H.HIDDEN) end
    if Want then
        for _, Name in ipairs({ "AmmoBox", "CurrentAmmoTxt", "MaxAmmoTxt", "CurrentFirearmName" }) do
            pcall(function()
                local W = UI[Name]
                if IsAlive(W) and W:GetRenderOpacity() < 0.99 then W:SetRenderOpacity(1.0) end
            end)
        end
    end
    if Want ~= H.LastWant then
        H.LastWant = Want
        if (H.LogCount or 0) < 6 then
            H.LogCount = (H.LogCount or 0) + 1
            Log("Munitions-Anzeige: Schusswaffe in der Hand=%s (vorher sichtbar=%s, Deckkraft %.2f)", tostring(Want),
                tostring(Shown), Safe(function() return Box:GetRenderOpacity() end, -1))
        end
    end
end

-- Einmal pro Sekunde aus der Hauptschleife (HandleClient): keine eigene Hintergrund-Schleife mehr, Lua in
-- UE4SS ist nicht threadsicher (Abstuerze beim Schiessen des Mitspielers).
Coop.AmmoTick = function()
    local ok, err = pcall(H.Check)
    if not ok and not H.Err then H.Err = true Log("Munitions-Anzeige-Fehler: %s", tostring(err)) end
end

-- Zielen (rechte Maustaste) blendet die Anzeige nach ~1 s per Animation (Deckkraft) wieder aus. Solange eine
-- Schusswaffe in der Hand ist (Erkennung oben, 1x pro Sekunde), Deckkraft/Sichtbarkeit 10x pro Sekunde halten -
-- aus Coop.Car.OnTick (33-ms-Schleife Coop.Car.Frame, kein Bild-Tick-Hook mehr).
H.HOLD = { "AmmoBox", "CurrentAmmoTxt", "MaxAmmoTxt", "CurrentFirearmName" }
Coop.AmmoHold = function(Pawn)
    if not H.LastWant then return end
    local Now = os.clock()
    if Now < (H.HoldAt or 0) then return end
    H.HoldAt = Now + 0.1
    local UI = Pawn.InGameUI
    if not IsAlive(UI) then return end
    for _, Name in ipairs(H.HOLD) do
        local W = UI[Name]
        if IsAlive(W) and W:GetRenderOpacity() < 0.99 then W:SetRenderOpacity(1.0) end
    end
    local Box = UI.AmmoBox
    if IsAlive(Box) then
        local Vis = Box:GetVisibility()
        if Vis == 1 or Vis == 2 then Box:SetVisibility(H.VISIBLE) end
    end
end
end

do
-- Geraeusche: Die Zombies hoeren nur beim Host (dort laeuft ihre KI). Schuesse des Mitspielers meldet das
-- Spiel aber nur bei ihm selbst (ReportNoiseEvent), Schritte meldet der Host selbst. Darum schickt der
-- Mitspieler eigene Geraeusche und die von Dingen ohne Figur (z. B. Sirene) an den Host, der sie mit
-- der Mitspieler-Figur als Verursacher meldet. Doppelte Meldungen schaden der KI nicht.
local N = { MAX_PER_SECOND = 10, Second = 0, Count = 0, Q = {},
            FUNC = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent" }

-- Schnell-Aufgabe "noise" (100 ms): NetMode und eigene Figur (Adresse/Pfad, 2x pro Sekunde) fuer Hook bzw. DLL-Weg
-- merken, die gesammelten Geraeusche hier (ausserhalb der Schuss-/Schritt-Kette) an den Host schicken.
function N.Fast(Now, Mode)
    N.Mode = Mode
    if Mode == "Client" and Now >= (N.OwnAt or 0) then
        N.OwnAt = Now + 0.5
        local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
        N.OwnAddr = IsAlive(Pawn) and Pawn:GetAddress() or nil
        N.OwnFull = IsAlive(Pawn) and Safe(function() return Pawn:GetFullName() end) or nil
        N.OwnLoc = IsAlive(Pawn) and Safe(function() return Pawn:K2_GetActorLocation() end) or nil
        N.NoSteps = Coop.FlagOn("noise_nosteps", false)
    end
    if N.Way == "dll" and Now >= (N.CheckAt or 0) then
        N.CheckAt = Now + 5
        N.CheckDll()
    end
    if #N.Q == 0 then return end
    local Q = N.Q
    N.Q = {}
    if Mode ~= "Client" then return end
    for _, Text in ipairs(Q) do Coop.SendChunked(Coop.SendToHost, "noise", Text) end
end

-- Ein Geraeusch fuer den Host vormerken (Hook und DLL-Weg): Budget MAX_PER_SECOND, Format wie bisher. Nur Lua-Werte.
-- noise_nosteps (AI-14): Schritte (Tag "Noise", Reichweite 1-900; Footstep @0110 meldet der Host fuer die Gastfigur
-- selbst) nicht doppelt schicken. Reichweite 0 (Standard des Sinns) zaehlt nicht als Schritt.
function N.Queue(L, Loud, Range, TagText, Own)
    if type(L) ~= "table" and type(L) ~= "userdata" then return end
    Range, TagText = tonumber(Range) or 0, tostring(TagText or "None")
    if N.NoSteps and TagText == "Noise" and Range > 0 and Range <= 900 then return end
    local Now = os.time()
    if Now ~= N.Second then N.Second, N.Count = Now, 0 end
    if N.Count >= N.MAX_PER_SECOND or #N.Q >= N.MAX_PER_SECOND then return end
    N.Count = N.Count + 1
    if Coop.Shot then Coop.Shot.Count("geraeusch_gesendet", TagText .. "/" .. Range) end
    N.Q[#N.Q + 1] = string.format("%.0f;%.0f;%.0f;%.3f;%.0f;%s;%s", L.X, L.Y, L.Z, tonumber(Loud) or 1, Range,
        TagText, Own and "1" or "0")
end

-- noise_dll (CORE-18): Weg festlegen. "dll" = DLL-Beobachter an der Aufrufstelle (braucht maxargs >= 6: MaxRange, Tag),
-- "hook" = alter Lua-Hook, nil = DLL-Status noch nicht da (naechste Sekunde erneut, hoechstens 10 s)
function N.Decide()
    if not Coop.FlagOn("noise_dll", true) then return "hook" end
    local Nat = Coop.Modules and Coop.Modules.ls_native
    if not (Nat and Nat.Status and Nat.SetWatch and Nat.OnEvent and Nat.Available) then return "hook" end
    local St = Safe(Nat.Status)
    if type(St) == "table" and St.capable == 1 then
        return ((tonumber(St.maxargs) or 0) >= 6 and Safe(Nat.Available, false) == true) and "dll" or "hook"
    end
    N.WaitN = (N.WaitN or 0) + 1
    return N.WaitN >= 10 and "hook" or nil
end

-- DLL-Weg: Watch-Besitzer main_noise (Tag n_noise, observe, at=call, local=1: nur Aufrufe, deren Aufrufer dem eigenen
-- Controller gehoert), Zustellung per Native.OnEvent im 100-ms-Takt (eine gemeinsame Lesung der Ereignis-Datei).
-- Bewusst local=1: ohne Filter landeten alle Geraeusche aller Figuren in der Ereignis-Datei (jeder Leser parst sie).
-- Folge: Geraeusche von Welt-Objekten ohne Besitzer, die nur beim Gast laufen (z. B. BP_GuaranteedSpawner_C), gehen
-- nicht mehr an den Host (Tueren/Kisten/Sirenen laufen beim Host selbst). noise_dll=0 = alter Hook mit allem.
function N.StartDll()
    local Nat = Coop.Modules and Coop.Modules.ls_native
    local ok, Res = pcall(Nat.SetWatch, { { Func = N.FUNC, Tag = "n_noise", Mode = "observe", At = "call", Local = true } },
        "main_noise")
    if not ok or Res == false then Coop.FlagFail("noise_dll", ok and "Watch nicht schreibbar" or Res) return false end
    local okE, errE = pcall(Nat.OnEvent, "n_noise", N.OnEvent)
    if not okE then
        pcall(Nat.SetWatch, nil, "main_noise")
        Coop.FlagFail("noise_dll", errE)
        return false
    end
    N.Way, N.CheckAt = "dll", os.clock() + 5
    Log("Geraeusche: DLL-Beobachter statt Lua-Hook (ReportNoiseEvent an der Aufrufstelle)")
    return true
end

-- DLL-Ereignis (rohe geteilte Tabelle, nur lesen): Args = Kontext, Ort {X,Y,Z}, Lautstaerke, Verursacher ("<Klasse> <Pfad>",
-- false = keiner, nil = an der Aufrufstelle nicht lesbar), Reichweite, Tag. Regel wie der Hook: eigene Figur oder kein
-- Verursacher. Ev.Remote == false = Aufrufer gehoert sicher dem eigenen Controller (DLL kennt local_pc); kennt die DLL
-- ihn nicht (nil), filtert sie nicht -> dann nur Geraeusche mit der eigenen Figur als Verursacher. Ohne lesbaren Ort:
-- eigene Lage (nur eigene Geraeusche).
function N.OnEvent(Ev)
    if N.Way ~= "dll" or N.Mode ~= "Client" then return end
    local Args = Ev.Args or {}
    local Inst, Own, Mine = Args[4], nil, Ev.Remote == false
    if N.OwnFull ~= nil and Inst == N.OwnFull then
        Own = true
    elseif Inst == false and Mine then
        Own = false
    elseif Inst == nil and Mine then
        Own = true   -- Verursacher an der Aufrufstelle nicht lesbar, Aufruf aber von uns
    else
        return   -- andere Verursacher: meldet der Host selbst
    end
    local L = Args[2]
    if type(L) ~= "table" or not (L.X and L.Y and L.Z) then
        if not Own then return end
        L = N.OwnLoc
    end
    N.Queue(L, Args[3], Args[5], Args[6], Own)
end

-- Autofallback (alle 5 s): DLL-Beobachter weg, Zustellung abgeschaltet oder noise_dll per FLAG_DOWN aus -> Lua-Hook
function N.CheckDll()
    local Nat = Coop.Modules and Coop.Modules.ls_native
    local LC = Coop.Modules and Coop.Modules.ls_core
    local Down = LC and LC.Down or {}
    local Why = nil
    if not Coop.FlagOn("noise_dll", true) then Why = "noise_dll aus"
    elseif not (Nat and Safe(Nat.Available, false) == true) then Why = "DLL-Beobachter nicht verfuegbar"
    elseif Down.native_ev or Down.native_ev_n_noise then Why = "Ereignis-Zustellung abgeschaltet" end
    if not Why then return end
    if Nat then pcall(Nat.SetWatch, nil, "main_noise") end
    Log("Geraeusche: zurueck zum Lua-Hook (%s)", Why)
    N.StartHook()
end

-- Alter Weg: Hook auf ReportNoiseEvent (einmal). Liest nur Parameter und Lua-Werte (N.Mode, N.OwnAddr), Text in N.Q.
function N.StartHook()
    N.Way = "hook"
    if N.HookDone then return end
    N.HookDone = true
    TryHook(N.FUNC, function(_, _, Location, Loudness, Instigator, MaxRange, Tag)
        if N.Sending or N.Mode ~= "Client" or N.Way ~= "hook" then return end
        local ok, err = pcall(function()
            -- Den Verursacher NIE anfassen (IsAlive/IsA): Er kann schon zerstoert sein (Geschoss, toter Zombie), UE4SS
            -- warf dann Fehler und das Spiel stuerzte ab (20.10. 05:47, 0x70; vermutlich viele "Abstuerze beim Schiessen").
            -- Nur die Adresse vergleichen: eigene Figur oder gar kein Verursacher (z. B. Sirene) -> an den Host.
            local Source = Instigator:get()
            local Addr = Source and Safe(function() return Source:GetAddress() end, 0) or 0
            local Own = Addr ~= 0 and N.OwnAddr ~= nil and Addr == N.OwnAddr
            if not Own and Addr ~= 0 then return end  -- andere Verursacher: meldet der Host selbst
            if os.time() == N.Second and (N.Count >= N.MAX_PER_SECOND or #N.Q >= N.MAX_PER_SECOND) then return end
            N.Queue(Location:get(), Loudness:get(), MaxRange:get(), Tag:get():ToString(), Own)
        end)
        if not ok then Log("Geraeusch-Fehler: %s", tostring(err)) end
    end)
end

-- Nur beim Spieler: Auf dem Server meldet OnGuestNoise selbst ReportNoiseEvent (das waere ein Hook im Hook)
-- Erst beim ersten Multiplayer (Coop.HookNoise aus der Hauptschleife, bis der Weg feststeht): Solo bleibt ohne Hook.
-- noise_dll: mit DLL-Beobachter (maxargs >= 6) gar kein Lua-Hook auf der heissesten Funktion (CORE-18/AI-14).
Coop.HookNoise = function()
    if N.Hooked then return end
    if os.getenv("LASTSIGNAL_SERVER") == "1" or os.getenv("NETTEST_SERVER") == "1" then N.Hooked = true return end
    local Way = N.Decide()
    if not Way then return end
    N.Hooked = true
    Coop.AddFast("noise", N.Fast)
    if Way == "dll" and N.StartDll() then return end
    N.StartHook()
end

-- Host: Geraeusch eines Mitspielers fuer die KI melden.
Coop.OnGuestNoise = function(PC, Data)
    local X, Y, Z, Loud, Range, Tag, Own = Data:match("^(%-?%d+);(%-?%d+);(%-?%d+);([%d.]+);(%d+);([^;]*);([01])$")
    if not X then return end
    local Pawn = Own == "1" and IsAlive(PC) and PC:K2_GetPawn() or nil
    N.Hearing = Coop.Cdo("/Script/AIModule.Default__AISense_Hearing")   -- CORE-20: je Nutzung geprueft
    if not N.Hearing then return end
    N.Sending = true
    pcall(function()
        N.Hearing:ReportNoiseEvent(CurrentWorld(), { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) },
            tonumber(Loud), IsAlive(Pawn) and Pawn or nil, tonumber(Range), FName(Tag))
    end)
    N.Sending = false
    if Coop.Shot then Coop.Shot.Count("geraeusch_vom_spieler", Tag) end
    if not N.Logged then N.Logged = true Log("Geraeusche des Mitspielers werden an die KI gemeldet") end
end
end

do
-- Fremde Schuesse beim Mitspieler: Effekte laufen per Multicast (MC_WeaponShot/MC_WeaponEffects) auf jedem
-- Rechner, das Kamerawackeln darin trifft aber die Kamera des lokalen Spielers - sie wackelte bei jedem
-- fremden Schuss mit. Waehrend eines fremden Multicasts wird jedes Kamerawackeln auf 0 gesetzt.
-- Zaehler (Schuesse, Ton, Wackeln, Geraeusche) alle 10 s im Log, fuer die Fehlersuche bei Ton/Schalldaempfer.
local S = { WEAPON = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C",
            CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
            Remote = 0, Own = 0, Stack = {}, Hooked = {}, Counts = {}, Names = {}, LogAt = 0, ServerShots = {}, SoundQ = {},
            FxQ = {} }   -- FxQ: MC_WeaponEffects ohne Einordnung im Hook (shot_shake_hooks=0), eingeordnet in S.Fast
Coop.Shot = S
-- Hooks lesen nur Lua-Werte: S.Mode (NetMode), S.OwnAddr/S.OwnPC (eigene Figur/Controller) setzt die Schnell-Aufgabe
-- "shot" (S.Fast, 100 ms) bzw. S.Tick (1 s). Fremder Schusston: Warteschlange S.SoundQ, abgespielt in S.Fast.

function S.Count(Key, Name)
    S.Counts[Key] = (S.Counts[Key] or 0) + 1
    if Name and not S.Names[Key] then S.Names[Key] = tostring(Name) end
    S.Dirty = true
end

local function NameOf(Param)
    return Safe(function() local O = Param:get() return IsAlive(O) and O:GetFName():ToString() or "?" end, "?")
end

-- Gehoert der Schuetze (Waffe: Traeger, Figur: sie selbst) nicht zur eigenen Figur? Laeuft im Hook: eigene Adressen
-- aus S.OwnAddr/S.OwnPC (Schnell-Aufgabe), Traeger ueber die Eigenschaft Owner (kein UFunction-Aufruf); nur ohne
-- Owner noch GetAttachParentActor.
function S.IsRemote(Actor)
    local Own = S.OwnAddr
    if not Own or not S.PawnClass or not IsAlive(Actor) then return false end
    local Holder = Actor
    if not Actor:IsA(S.PawnClass) then
        Holder = Safe(function() return Actor.Owner end)
        if not IsAlive(Holder) then Holder = Safe(function() return Actor:GetAttachParentActor() end) end
        if not IsAlive(Holder) then return false end
    end
    local Addr = Holder:GetAddress()
    return Addr ~= Own and Addr ~= S.OwnPC
end

-- Schussgeraeusch fremder Schuesse: Das Spiel spielt es nur beim Schuetzen selbst. MC_WeaponEffects kommt bei jedem
-- Schuss bei allen an (Muendungsfeuer; mit Schalldaempfer das gedaempfte) -> hier den Ton der Waffe abspielen.
-- Aufruf aus S.Fast (Warteschlange), nie im Hook. Flash = Muendungsfeuer-Objekt (im Hook gelesen) oder nil.
-- CompRead/Comp: Ziel-Komponente des Multicasts (AttachToComponent) im Hook gelesen; nil/tot = beim Zuschauer nicht
-- aufloesbar (COMBAT-17)
function S.PlayRemote(W, Flash, CompRead, Comp)
    if not IsAlive(W) then return end
    if CompRead then pcall(S.RemoteFlash, W, Flash, Comp) end
    local Now, Key = os.clock(), W:GetAddress()
    S.LastSound = S.LastSound or {}
    if Now - (S.LastSound[Key] or 0) < 0.05 then return end
    S.LastSound[Key] = Now
    local WC = Coop.Scope.Comp(W, "BP_WeaponsPickupComponent_C")
    if not WC then return end
    local Quiet = WC["SuppressorAttached?"] == true
    if IsAlive(Flash) and IsAlive(WC.SuppressedMuzzleFlash) then Quiet = Flash:GetAddress() == WC.SuppressedMuzzleFlash:GetAddress() end
    local Sound = Quiet and WC.FirearmSuppressedSound or WC.FirearmSound
    if not IsAlive(Sound) then Sound = WC.FirearmSound end
    if not IsAlive(Sound) then S.Count("ton_fremd_FEHLT") return end
    S.GS = Coop.Cdo("/Script/Engine.Default__GameplayStatics")   -- CORE-20
    if not S.GS then return end
    S.GS:PlaySoundAtLocation(W, Sound, W:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil)
    S.Count(Quiet and "ton_fremd_gedaempft" or "ton_fremd_gespielt", Sound:GetFName():ToString())
end

-- COMBAT-17 (shot_flash): Gedaempfte Schuesse haengen das Muendungsfeuer an das Mesh des Daempfer-Anbaus (MuzzleEffects
-- @0426: Svr_WeaponEffects(SuppressedMuzzleFlash, Attachment.StaticMesh, 'Muzzle')). Der Anbau ist lokal erzeugt und beim
-- Zuschauer nicht aufloesbar -> das Spiel zeigt dort kein Feuer. Dann wie MC_WeaponEffects (@0a3d, Groesse 0,75) am
-- Waffen-Mesh, Socket Muzzle. Nur das gedaempfte Feuer, nur wenn die Komponente fehlt.
function S.RemoteFlash(W, Flash, Comp)
    if IsAlive(Comp) or not Coop.FlagOn("shot_flash", true) then return end
    local WC = Coop.Scope.Comp(W, "BP_WeaponsPickupComponent_C")
    local Fx = WC and Safe(function() return WC.SuppressedMuzzleFlash end)
    if not (IsAlive(Fx) and IsAlive(Flash) and Flash:GetAddress() == Fx:GetAddress()) then return end
    local Mesh = Safe(function() return W.SkeletalMeshComponent end)
    if not IsAlive(Mesh) then return end
    S.GS = Coop.Cdo("/Script/Engine.Default__GameplayStatics")   -- CORE-20
    if not S.GS then return end
    local ok, err = pcall(function()
        S.GS:SpawnEmitterAttached(Fx, Mesh, FName("Muzzle"), { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 },
            { X = 0.75, Y = 0.75, Z = 0.75 }, 0, true, 0, true)
    end)
    if ok then S.Count("feuer_fremd_gedaempft") else Coop.FlagFail("shot_flash", err) end
end

-- ls_combat (Haltbarkeit/Kill-Zuordnung): Schuesse je Waffe auf dem Host, nur Lua-Tabelle
local function ServerShot(Self)
    if S.Mode == "Client" then return end
    pcall(function() local Addr = Self:get():GetAddress() S.ServerShots[Addr] = (S.ServerShots[Addr] or 0) + 1 end)
end

local function Pre(Key)
    return function(Self, ...)
        if S.Mode ~= "Client" then
            -- Host (Hooks aus einer frueheren Sitzung als Mitspieler): nur zaehlen, Stapel fuer Post halten
            if Key == "MC_WeaponEffects" and not S.Hooked.Srv then ServerShot(Self) end
            S.Stack[#S.Stack + 1] = "server"
            return
        end
        local Kind = "eigen"
        pcall(function() if S.IsRemote(Self:get()) then Kind = "fremd" end end)
        S.Count(Kind .. "_" .. Key)
        if Kind == "fremd" and Key == "MC_WeaponEffects" and #S.SoundQ < 16 then
            local Particle, AttachComp = ...
            local W = Safe(function() return Self:get() end)
            if W then
                S.SoundQ[#S.SoundQ + 1] = { W = W, Flash = Safe(function() return Particle:get() end),
                                            Comp = Safe(function() return AttachComp:get() end), CompRead = AttachComp ~= nil }
            end
        end
        S.Stack[#S.Stack + 1] = Kind
        if Kind == "fremd" then S.Remote = S.Remote + 1 elseif Kind == "eigen" then S.Own = S.Own + 1 end
    end
end

-- CORE-18 (shot_shake_hooks=0): Hook auf MC_WeaponEffects merkt nur Waffe + Muendungsfeuer (kein IsRemote/IsA/
-- GetAttachParentActor im Rumpf); eigen/fremd entscheidet S.Fast. Host: wie Pre nur der Schusszaehler.
function S.FxPre(Self, Particle, AttachComp)
    if S.Mode ~= "Client" then
        if not S.Hooked.Srv then ServerShot(Self) end
        return
    end
    if #S.FxQ >= 16 then return end
    pcall(function()
        S.FxQ[#S.FxQ + 1] = { W = Self:get(), Flash = Particle:get(), Comp = AttachComp and AttachComp:get() or nil,
                              CompRead = AttachComp ~= nil }
    end)
end

-- Schnell-Aufgabe "shot" (100 ms, nur Multiplayer): NetMode und eigene Adressen fuer die Hooks merken, fremde
-- Schusstoene aus der Warteschlange abspielen (ausserhalb der Schuss-Kette).
function S.Fast(Now, Mode)
    S.Mode = Mode
    S.PawnClass = S.PawnClass or StaticFindObject("/Script/Engine.Pawn")
    if Mode ~= "Client" then S.SoundQ, S.FxQ = {}, {} return end
    if Now >= (S.OwnAt or 0) then
        S.OwnAt = Now + 0.5
        local PC = Safe(LocalPC)
        local Pawn = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end)
        S.OwnPC = IsAlive(PC) and PC:GetAddress() or nil
        S.OwnAddr = IsAlive(Pawn) and Pawn:GetAddress() or nil
    end
    if #S.FxQ > 0 then   -- CORE-18: Einordnung der im Hook gemerkten Effekte hier statt im Hook
        local Fx = S.FxQ
        S.FxQ = {}
        for _, E in ipairs(Fx) do
            local okR, Remote = pcall(S.IsRemote, E.W)
            local Kind = (okR and Remote) and "fremd" or "eigen"
            S.Count(Kind .. "_MC_WeaponEffects")
            if Kind == "fremd" and #S.SoundQ < 16 then S.SoundQ[#S.SoundQ + 1] = E end
        end
    end
    if #S.SoundQ == 0 then return end
    local Q = S.SoundQ
    S.SoundQ = {}
    for _, E in ipairs(Q) do pcall(S.PlayRemote, E.W, E.Flash, E.CompRead, E.Comp) end
end

local function Post()
    local Kind = table.remove(S.Stack)
    if Kind == "fremd" then S.Remote = math.max(0, S.Remote - 1)
    elseif Kind == "eigen" then S.Own = math.max(0, S.Own - 1) end
end

-- Kamerawackeln nur waehrend eines fremden Schusses auf 0
local function Mute(Key, Fn)
    return function(...)
        if S.Remote <= 0 then return end
        local ok = pcall(Fn, ...)
        S.Count(ok and "wackeln_aus" or "wackeln_aus_FEHLER", Key)
    end
end

-- Toene waehrend eines Schusses zaehlen (eigen/fremd); Index = Stelle des Sound-Parameters
local function SoundPre(Key, Index)
    return function(...)
        if S.Remote <= 0 and S.Own <= 0 then return end
        local Sound = select(Index, ...)
        S.Count((S.Remote > 0 and "ton_fremd_" or "ton_eigen_") .. Key, NameOf(Sound))
    end
end

function S.Tick(World)
    S.Remote, S.Own, S.Stack = 0, 0, {}
    if World then S.Mode = Safe(function() return NetModeName(World) end, S.Mode) end
    if not S.FastAdded then S.FastAdded = true Coop.AddFast("shot", S.Fast) end
    if S.Dirty and os.time() >= S.LogAt then
        local Parts = {}
        for Key, N in pairs(S.Counts) do
            Parts[#Parts + 1] = Key .. "=" .. N .. (S.Names[Key] and ("(" .. S.Names[Key] .. ")") or "")
        end
        table.sort(Parts)
        Log("Schuss-Diagnose: %s", table.concat(Parts, " "))
        S.Counts, S.Names, S.Dirty, S.LogAt = {}, {}, false, os.time() + 10
    end
    -- Host/Server: keine Kamera-/Ton-Hooks (dort wackelt keine fremde Kamera), nur der Schusszaehler fuer ls_combat
    if Coop.Server or S.Mode ~= "Client" then
        if not S.Hooked.Srv and IsAlive(StaticFindObject(S.WEAPON)) then
            S.Hooked.Srv = true
            TryHook(S.WEAPON .. ":MC_WeaponEffects", ServerShot)
        end
        return
    end
    -- CORE-18 (shot_shake_hooks, Standard 0): die Kamerawackel-Hooks verschachteln sich mit den Schuss-Multicasts (Hook im
    -- Hook in der Schuss-Kette). Ohne: nur MC_WeaponEffects mit reinem Merk-Hook (S.FxPre), fremde Schuesse wackeln die
    -- eigene Kamera dann wie im Spiel mit. PlayWorldCameraShake ganz weg (kein BP-Aufrufer laut xref_calls.tsv).
    local Shake = Coop.FlagOn("shot_shake_hooks", false)
    if Shake and not S.Hooked.Engine then
        S.Hooked.Engine = true
        TryHook("/Script/Engine.PlayerCameraManager:StartCameraShake",
            Mute("StartCameraShake", function(_, _, Scale) Scale:set(0) end))
        TryHook("/Script/Engine.PlayerController:ClientStartCameraShake",
            Mute("ClientStartCameraShake", function(_, _, Scale) Scale:set(0) end))
    end
    if not S.Hooked.Weapon and IsAlive(StaticFindObject(S.WEAPON)) then
        S.Hooked.Weapon = true
        -- UE 5.6: MC_WeaponShot entfernt (Svr_WeaponShot ohne Parameter, ruft keinen Multicast mehr); MC_WeaponEffects
        -- unveraendert (EmitterTemplate, AttachToComponent, AttachPointName). Nur vorhandene Funktionen haken.
        if Shake then
            for _, Fn in ipairs({ "MC_WeaponShot", "MC_WeaponEffects", "Svr_WeaponShot" }) do
                if IsAlive(StaticFindObject(S.WEAPON .. ":" .. Fn)) then TryHook(S.WEAPON .. ":" .. Fn, Pre(Fn), Post) end
            end
        elseif IsAlive(StaticFindObject(S.WEAPON .. ":MC_WeaponEffects")) then
            TryHook(S.WEAPON .. ":MC_WeaponEffects", S.FxPre)
        end
    end
    if not S.Hooked.Char and IsAlive(StaticFindObject(S.CHAR)) then
        S.Hooked.Char = true
        if Shake then
            TryHook(S.CHAR .. ":CameraShake", Pre("CameraShake"), Post)
            TryHook(S.CHAR .. ":Client_CameraShake", Mute("Client_CameraShake", function(_, Shake2) Shake2:set(nil) end))
        end
        -- Nur Diagnose (Zaehler): feuert bei jedem Schritt jeder Figur (Footstep -> MC_PlaySoundAtLocation), darum nur dev=1
        if SETTINGS.dev then
            TryHook(S.CHAR .. ":MC_PlaySoundAtLocation", function(_, Sound) S.Count("MC_PlaySoundAtLocation", NameOf(Sound)) end)
        end
    end
    if Shake and not S.Hooked.PC then
        local PC = Safe(LocalPC)
        local Path = IsAlive(PC) and Safe(function() return PC:GetClass():GetFullName():match("^%S+%s+(%S+)$") end)
        if Path and Path:match("BP_PlayerController") then
            S.Hooked.PC = true
            TryHook(Path .. ":CameraShake", Mute("PC.CameraShake", function(_, Shake) Shake:set(nil) end))
            TryHook(Path .. ":CameraShakeClient", Mute("PC.CameraShakeClient", function(_, _, Scale) Scale:set(0) end))
        end
    end
end
end

do
-- Fehlersuche Inventar (Fallenlassen, Aufheben, Anlegen): zaehlt die Netzwerk-Eingaenge (ONLY) von
-- BP_JigMultiplayer und BP_JigHelperComp (Server: was ankommt, Spieler: was zurueckkommt) und TryPickup/JSI_* beim
-- Spieler. Bei bekannten Actor-Parametern: Name, Rolle, repliziert, aus der Karte. Alle 10 s im Log.
-- Nur mit dev=1. Dazu die Equip-Laufzeit beim Mitspieler (RTT): Anfrage SERVER_RequestEquipActorToContainer bzw.
-- JSI_TryEquipToMain (Pre) legt einen Zeitstempel in eine Warteschlange, die Antwort CLIENT_EquipActorSuccess/...Failed
-- (Post) nimmt den aeltesten heraus. Alle 10 s Anzahl/Schnitt/Max und der eigene Ping.
local D = { Hooked = {}, Counts = {}, Detail = {}, LogAt = 0,
            Rtt = { Fifo = {}, Ms = {}, LogAt = 0, Client = false, Starts = 0, NoStart = 0, Lost = 0 } }  -- Rtt: os.clock
Coop.InvDiag = D
-- Nur Netzwerk-Eingaenge (vom Netz oder von der Eingabe aufgerufen, nicht voneinander): 81 Hooks auf alle
-- Inventar-Funktionen liessen das Spiel einfrieren (Hooks in Hooks, Spiel-Thread wartete in UE4SS, 20.10. 05:29)
local ONLY = { SERVER_RequestDropItem = true, SERVER_RequestAddActorToContainer = true, SERVER_RequestActorAddStackItem = true,
               SERVER_RequestEquipActorToContainer = true, CLIENT_DropRequestFailed = true,
               CLIENT_RequestEquipResponseFailed = true, CLIENT_EquipActorSuccess = true, TryPickup = true,
               JSI_TryEquipToMain = true, CLIENT_MoveToIndexFailed = true, CLIENT_MoveItemToIndex = true }
local DESCRIBE = { SERVER_RequestEquipActorToContainer = 1, ServerFuncHandleEquipActor = 1, JSI_TryEquipToMain = 1,
                   SERVER_RequestAddActorToContainer = 1, SERVER_RequestActorAddStackItem = 1,
                   ServerFunc_HandleActorToCapacityContainer = 1, CLIENT_RequestEquipResponseFailed = 2, CLIENT_EquipActorSuccess = 1 }

function D.Count(Key, Detail)
    D.Counts[Key] = (D.Counts[Key] or 0) + 1
    if Detail then
        D.Detail[Key] = D.Detail[Key] or {}
        if #D.Detail[Key] < 3 then table.insert(D.Detail[Key], Detail) end
    end
end

function D.Describe(Index, ...)
    local P = select(Index, ...)
    local V = P and Safe(function() return P:get() end)
    if not IsAlive(V) then return "nil" end
    return string.format("%s role=%s rep=%s karte=%s", V:GetFName():ToString(), tostring(V.Role), tostring(V.bReplicates),
        tostring(WAS_LOADED and V:HasAnyFlags(WAS_LOADED)))
end

-- Nur Lua-Tabellen, keine Spielfunktionen (laeuft im Hook); D.Rtt.Client setzt D.Tick.
-- Start auch ueber JSI_TryEquipToMain (Pre): UE4SS-Hooks auf Blueprint-Funktionen laufen nur bei lokaler
-- Ausfuehrung, ein Server-RPC wird beim Mitspieler nur gesendet - der Pre auf SERVER_RequestEquipActorToContainer
-- kommt dort womoeglich nie. Zweiter Start binnen 0,1 s = dieselbe Anfrage (zwei Klassen, JSI -> SERVER_).
-- Rueckgabe: Zeitstempel des neuen Eintrags oder nil.
function D.RttStart()
    local R, Now = D.Rtt, os.clock()
    if not R.Client then return nil end
    if R.Fifo[#R.Fifo] and Now - R.Fifo[#R.Fifo] < 0.1 then return nil end
    if #R.Fifo >= 32 then table.remove(R.Fifo, 1) R.Lost = R.Lost + 1 end
    R.Fifo[#R.Fifo + 1] = Now
    R.Starts = R.Starts + 1
    return Now
end

-- JSI_TryEquipToMain ohne Ziel schickt keine Anfrage: seinen Start wieder herausnehmen
function D.RttJsiDone(HasTarget)
    local R, At = D.Rtt, D.Rtt.Jsi
    R.Jsi = nil
    if At and not HasTarget and R.Fifo[#R.Fifo] == At then R.Fifo[#R.Fifo] = nil R.Starts = R.Starts - 1 end
end

function D.RttEnd()
    local R = D.Rtt
    if not R.Client then return end
    local Now = os.clock()
    while R.Fifo[1] and Now - R.Fifo[1] > 10 do table.remove(R.Fifo, 1) R.Lost = R.Lost + 1 end  -- ohne Antwort
    local Start = table.remove(R.Fifo, 1)
    if not Start then R.NoStart = R.NoStart + 1 return end
    R.Ms[#R.Ms + 1] = (Now - Start) * 1000
end

function D.HookClass(Path)
    local Class = StaticFindObject(Path)
    if not IsAlive(Class) then return false end
    local Names, N = {}, 0
    Class:ForEachFunction(function(Func) Names[#Names + 1] = Func:GetFName():ToString() end)
    for _, Name in ipairs(Names) do
        if ONLY[Name] then
            local Index = DESCRIBE[Name]
            local Post = nil
            local Pre = function(_, ...) D.Count(Name, Index and D.Describe(Index, ...) or nil) end
            if Name == "JSI_TryEquipToMain" then
                Pre = function(_, ...) D.Rtt.Jsi = D.RttStart() or D.Rtt.Jsi D.Count(Name, Index and D.Describe(Index, ...) or nil) end
                Post = function(_, _, _, _, EquipTo)
                    local HasTarget = IsAlive(Safe(function() return EquipTo:get() end))
                    D.RttJsiDone(HasTarget)
                    D.Count("JSI_TryEquipToMain->" .. (HasTarget and "ziel" or "KEIN_ZIEL"))
                end
            elseif Name == "SERVER_RequestEquipActorToContainer" then
                Pre = function(_, ...) D.RttStart() D.Count(Name, Index and D.Describe(Index, ...) or nil) end
            elseif Name == "CLIENT_EquipActorSuccess" or Name == "CLIENT_RequestEquipResponseFailed" then
                Post = function() D.RttEnd() end
            end
            if TryHook(Path .. ":" .. Name, Pre, Post) then
                N = N + 1
            end
        end
    end
    Log("Inventar-Diagnose: %d Funktionen in %s", N, Path:match("[^%.]+$") or Path)
    return true
end

function D.RttLog()
    local R, Now = D.Rtt, os.clock()
    if not R.Client or Now < R.LogAt then return end
    R.LogAt = Now + 10
    local Sum, Max = 0, 0
    for _, Ms in ipairs(R.Ms) do Sum, Max = Sum + Ms, math.max(Max, Ms) end
    local Ping = tonumber(Safe(function() local P = LocalPC() local PS = IsAlive(P) and P.PlayerState return IsAlive(PS) and PS:GetPingInMilliseconds() or nil end)) or -1
    Log("Equip-RTT: %d Messungen, Schnitt %.0f ms, Max %.0f ms, Ping %.0f ms (Anfragen %d, Antwort ohne Anfrage %d, verworfen %d, offen %d)",
        #R.Ms, #R.Ms > 0 and Sum / #R.Ms or 0, Max, Ping, R.Starts, R.NoStart, R.Lost, #R.Fifo)
    R.Ms, R.Starts, R.NoStart, R.Lost = {}, 0, 0, 0
end

function D.Tick()
    if not SETTINGS.dev then return end
    local World, R = CurrentWorld(), D.Rtt
    local WorldAt = IsAlive(World) and World:GetAddress() or 0
    if WorldAt ~= R.World then   -- neue Welt (Beitritt, Trennen, Solo dazwischen): alte Messwerte verwerfen
        R.World, R.Fifo, R.Ms, R.Starts, R.NoStart, R.Lost, R.Jsi = WorldAt, {}, {}, 0, 0, 0, nil
    end
    R.Client = NetModeName(World) == "Client"
    D.RttLog()
    -- vorher auf "laeuft" setzen: bei einem Fehler nicht jede Sekunde neu versuchen
    if not D.Hooked.Jig then D.Hooked.Jig = "laeuft" D.Hooked.Jig = D.HookClass(Coop.Car.JIG) end
    if not D.Hooked.Helper then
        local Comp = FindFirstOf("BP_JigHelperComp_C")
        local Path = IsAlive(Comp) and Comp:GetClass():GetFullName():match("^%S+%s+(%S+)$")
        if Path then D.Hooked.Helper = "laeuft" D.Hooked.Helper = D.HookClass(Path) end
    end
    if next(D.Counts) and os.time() >= D.LogAt then
        local Parts = {}
        for Key, N in pairs(D.Counts) do
            Parts[#Parts + 1] = Key .. "=" .. N .. (D.Detail[Key] and (" [" .. table.concat(D.Detail[Key], "; ") .. "]") or "")
        end
        table.sort(Parts)
        Log("Inventar-Diagnose: %s", table.concat(Parts, " | "))
        D.Counts, D.Detail, D.LogAt = {}, {}, os.time() + 10
    end
end
end

do
-- Gegenstaende am Boden: Pickup-Actors (BP_StaticMeshPickup_C/BP_SkeletalMeshPickup_C und Unterklassen) sind im Spiel
-- nicht repliziert. Auf dem Server gespawnte (Beute, Fallengelassenes) sah darum kein Spieler, und die lokalen Kopien
-- des Spielers kennt der Server nicht (Aufheben ging nicht).
-- Server: alle 3 s jeden freien (nicht angehaengten, ohne Besitzer) Pickup replizieren.
-- Spieler: lokal entstandene freie Pickups (Rolle Authority, nicht aus der Karte, ohne Besitzer, >= 10 s) sind Doppel
-- der Server-Gegenstaende -> entfernen.
local L = { CLASSES = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }, At = 0, Seen = {}, MAX = 300 }
Coop.Loot = L

function L.Each(Fn)
    for _, Name in ipairs(L.CLASSES) do
        for _, A in ipairs(FindAllOf(Name) or {}) do
            if IsAlive(A) then Fn(A) end
        end
    end
end

function L.Free(A)
    return not IsAlive(Safe(function() return A:GetAttachParentActor() end)) and not IsAlive(A:GetOwner())
end

function L.HostTick(World)
    if NetModeName(World) ~= "ListenServer" or os.time() < L.At then return end
    L.At = os.time() + 3
    local N = 0
    L.Each(function(A)
        if N < L.MAX and not A.bReplicates and not IsAlive(Safe(function() return A:GetAttachParentActor() end)) then
            A:SetReplicates(true)
            A:SetReplicateMovement(true)
            N = N + 1
        end
    end)
    if N > 0 then Log("Boden-Gegenstaende: %d fuer alle sichtbar gemacht", N) end
end

function L.ClientTick(World)
    if NetModeName(World) ~= "Client" or not WAS_LOADED or os.time() < L.At then return end
    L.At = os.time() + 5
    local Now, Removed, Seen, Names = os.time(), {}, {}, {}
    L.Each(function(A)
        if A.Role == ROLE_AUTHORITY and not A:HasAnyFlags(WAS_LOADED) and L.Free(A) then
            local Name = A:GetFName():ToString()
            Seen[Name] = L.Seen[Name] or Now
            if Now - Seen[Name] >= 10 then
                Removed[#Removed + 1] = A
                local C = A:GetClass():GetFName():ToString()
                Names[C] = (Names[C] or 0) + 1
            end
        end
    end)
    L.Seen = Seen
    if #Removed == 0 then return end
    if #Removed > L.MAX then Log("Boden-Gegenstaende: %d lokale Doppel - zu viele, nichts entfernt", #Removed) return end
    for _, A in ipairs(Removed) do pcall(function() A:K2_DestroyActor() end) end
    local Parts = {}
    for C, N in pairs(Names) do Parts[#Parts + 1] = C .. "=" .. N end
    Log("Boden-Gegenstaende: %d lokale Doppel entfernt (%s)", #Removed, table.concat(Parts, ", "))
end

-- Runde 3: Cheat-Klick (Coop.Cheat.OnClickPre, weitergeleitetes "give") -> lokale Kopie sofort weg, nicht erst nach
-- 10 s (der "F Aufheben"-Hinweis blieb sonst haengen). 3 s lang mit 5 Hz im Schnell-Loop: neue Pickups mit denselben
-- Schutzregeln wie L.ClientTick (Rolle Authority, nicht aus der Karte, frei) und hoechstens DUP_RANGE von der eigenen
-- Figur. Neu = nicht schon vor dem Klick von L.ClientTick gesehen (L.Seen). Nur Namen/Zahlen gemerkt, keine Objekte.
L.DUP_FOR, L.DUP_EVERY, L.DUP_RANGE = 3, 0.2, 500

-- Aus dem Vor-Hook des Cheat-Knopfs: nur Tabellen (der Schnell-Loop macht den Rest)
function L.DupArm()
    L.DupUntil, L.DupNext, L.DupClick = os.clock() + L.DUP_FOR, 0, os.time()
    L.DupCounts = L.DupCounts or {}
    Coop.AddFast("cheatdup", L.DupTick)
end

function L.DupTick(Now, Mode)
    if Mode ~= "Client" or not WAS_LOADED or Now > (L.DupUntil or 0) then
        local Parts, N = {}, 0
        for C, K in pairs(L.DupCounts or {}) do Parts[#Parts + 1] = C .. "=" .. K N = N + K end
        Log("Cheat-Doppel: %d lokale Kopie(n) sofort entfernt%s", N, N > 0 and (" (" .. table.concat(Parts, ", ") .. ")") or "")
        L.DupCounts = nil
        return true
    end
    if Now < L.DupNext then return end
    L.DupNext = Now + L.DUP_EVERY
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) then return end
    local P0, Removed = Pawn:K2_GetActorLocation(), {}
    L.Each(function(A)
        if A.Role == ROLE_AUTHORITY and not A:HasAnyFlags(WAS_LOADED) and L.Free(A) then
            local Seen = L.Seen[A:GetFName():ToString()]
            if Seen and Seen < L.DupClick then return end   -- schon vor dem Klick da: macht L.ClientTick
            local P = A:K2_GetActorLocation()
            if (P.X - P0.X) ^ 2 + (P.Y - P0.Y) ^ 2 + (P.Z - P0.Z) ^ 2 <= L.DUP_RANGE ^ 2 then Removed[#Removed + 1] = A end
        end
    end)
    for _, A in ipairs(Removed) do
        local C = Safe(function() return A:GetClass():GetFName():ToString() end, "?")
        if pcall(function() A:K2_DestroyActor() end) then L.DupCounts[C] = (L.DupCounts[C] or 0) + 1 end
    end
end
end

do
-- Zielfernrohr beim Spieler: Waffe aus einer Kiste direkt in den Waffen-Slot gezogen -> nur Zoom, kein Scope.
-- Die Waffe entsteht dabei auf dem Server; ihre Aufsaetze (RepAttachments, repliziert) baut das Spiel beim
-- Spieler offenbar nicht ein (InstalledAttachments leer, SightAttached? false). Darum: Waffe in der Hand mit
-- replizierten, aber nicht eingebauten Aufsaetzen -> nach 2 s OnRep_RepAttachments, nach 4 s ProcessAttachments.
local P = { ATTACH = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969", Weapon = nil, Since = 0, Step = 0 }
Coop.Scope = P

-- In der Hand: jeder Hand-Socket (Coop.HandItem, Runde 3: auch Sidearm_r der Pistolen)
function P.Held(Pawn)
    return (Coop.HandItem(Pawn))
end

-- Klasse ueber eine vorhandene Instanz. Ohne Instanz liefert FindFirstOf ein ungueltiges Objekt, und ein
-- Methodenaufruf darauf (:GetClass) bringt das Spiel nativ zum Absturz (pcall hilft nicht; Server-Test 22.10.).
function P.Comp(Actor, Name)
    if not IsAlive(P[Name]) then
        P[Name] = nil
        local Inst = FindFirstOf(Name)
        if IsAlive(Inst) then P[Name] = Safe(function() return Inst:GetClass() end) end
    end
    if not IsAlive(P[Name]) or not IsAlive(Actor) then P[Name] = IsAlive(P[Name]) and P[Name] or nil return nil end
    local C = Actor:GetComponentByClass(P[Name])
    return IsAlive(C) and C or nil
end

function P.Tick()
    if SETTINGS.attach_v2 then return end   -- ersetzt durch Coop.AttachFix (Schnell-Loop); P.Comp bleibt in Gebrauch
    if NetModeName(CurrentWorld()) ~= "Client" then return end
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(Pawn) then return end
    local W = P.Held(Pawn)
    if not W then P.Weapon = nil return end
    if P.Weapon ~= W:GetAddress() then P.Weapon, P.Since, P.Step = W:GetAddress(), os.time(), 0 end
    if P.Step >= 3 then return end
    local J = P.Comp(W, "BP_JigPickupComponent_C")
    if not J then return end
    local Rep = J.RepAttachments[P.ATTACH]:GetArrayNum()
    local Installed = J.InstalledAttachments:GetArrayNum()
    local WC = P.Comp(W, "BP_WeaponsPickupComponent_C")
    local Sight = WC and WC["SightAttached?"]
    if Rep == 0 or Installed > 0 then
        if P.Step > 0 then Log("Aufsaetze %s: %d/%d eingebaut, Visier %s", W:GetFName():ToString(), Installed, Rep, tostring(Sight)) end
        P.Step = 3
        return
    end
    local Age = os.time() - P.Since
    if P.Step == 0 and Age >= 2 then
        P.Step = 1
        Log("Aufsaetze %s: %d repliziert, 0 eingebaut (Visier %s) -> OnRep_RepAttachments", W:GetFName():ToString(), Rep, tostring(Sight))
        J:OnRep_RepAttachments()
    elseif P.Step == 1 and Age >= 4 then
        P.Step = 2
        Log("Aufsaetze %s: noch 0 eingebaut -> ProcessAttachments", W:GetFName():ToString())
        J:ProcessAttachments()
    elseif P.Step == 2 and Age >= 6 then
        P.Step = 3
        Log("Aufsaetze %s: weiter 0/%d eingebaut, Visier %s (aufgegeben)", W:GetFName():ToString(), Rep, tostring(Sight))
    end
end

-- attach_v2 (statt P.Tick): Aufsaetze sofort, an allen angehaengten Schusswaffen der eigenen Figur (jeder Socket,
-- auch auf dem Ruecken), nicht nur an der in der Hand. Im Schnell-Loop 2x/s zaehlen (Rep = replizierte, Installed =
-- eingebaute Aufsaetze); neue Waffe oder andere Rep-Zahl -> scharf: +0,5 s OnRep_RepAttachments, +1 s und +2 s
-- ProcessAttachments, dann Schluss. Fertig, sobald Installed >= Rep. Eingegriffen wird wie beim alten Fix nur bei
-- Installed == 0: teilweise eingebaut = das Spiel baut gerade selbst, nachhelfen gaebe doppelte Aufsaetze.
-- Rep == 0 (noch nicht repliziert): bis 3 s warten, sonst nichts tun. Solange etwas scharf ist, 10x/s pruefen.
-- Nur beim Mitspieler, nur die eigene Figur.
-- attach_partial: Bleibt "teilweise eingebaut" (0 < Installed < Rep) 1,5 s gleich, genau ein ProcessAttachments, dann
-- Schluss (Glock 3/5: Schalldaempfer fehlte, Schuss klang laut). Installed > Rep im Log = doppelte Aufsaetze.
-- W: [Waffenname] = { W = Waffe, Rep, At = scharf seit (os.clock), Step = 0..3, Armed, PartN/PartAt = Teilzahl und
-- seit wann, PartDone = Zeitpunkt des einen Nachholens }; Firearm: [Klasse] = bool
-- REP_ID: Daten-Asset eines Eintrags in RepAttachments (FS_RepAttachmentInfo)
Coop.AttachFix = { N = 0, W = {}, Firearm = {}, REP_ID = "AttachmentID_21_84163C9E4A907293E46F1888C9CBB5C8" }

-- Schusswaffe? Ueber die Klassen-Kette (BP_FirearmPickup_C), je Klasse gemerkt
function Coop.AttachFix.IsFirearm(A)
    local AF, Class = Coop.AttachFix, A:GetClass()
    local Name = Class:GetFName():ToString()
    if AF.Firearm[Name] == nil then
        local Found, C = false, Class
        while C and C:IsValid() do
            if C:GetFName():ToString() == "BP_FirearmPickup_C" then Found = true break end
            C = C:GetSuperStruct()
        end
        AF.Firearm[Name] = Found
    end
    return AF.Firearm[Name]
end

-- Rep, Installed (nil, wenn nicht lesbar). Runde 3: Rep ohne Munition - Eintraege mit Munitions-Asset (*Ammo*, z. B.
-- 2x DA_9mmAmmo in der Glock) baut das Spiel nie ein, sie zaehlten als fehlend (3/5 statt 3/3). Unlesbar zaehlt mit.
function Coop.AttachFix.IsAmmo(Entry)
    local D = Safe(function() return Entry:get()[Coop.AttachFix.REP_ID] end)
    return IsAlive(D) and D:GetFName():ToString():find("Ammo", 1, true) ~= nil
end

function Coop.AttachFix.Count(J)
    local AF = Coop.AttachFix
    local Rep = Safe(function()
        local N = 0
        J.RepAttachments[P.ATTACH]:ForEach(function(_, Entry) if not AF.IsAmmo(Entry) then N = N + 1 end end)
        return N
    end)
    local Installed = Safe(function() return J.InstalledAttachments:GetArrayNum() end)
    return tonumber(Rep), tonumber(Installed)
end

function Coop.AttachFix.Arm(E, Rep, Now)
    E.Rep, E.At, E.Step, E.Armed = Rep, Now, 0, true
    E.PartN, E.PartAt, E.PartDone = nil, nil, nil
end

-- Fuers Log: replizierte Aufsaetze (Daten-Asset), die in keinem eingebauten stecken. Eingebaut = Aufsatz-Actors
-- (BP_AMainLocalAttachment_C), ihr Daten-Asset heisst im Dump "Attachment Info" (mit Leerzeichen, darum auch ohne
-- versucht). Nicht lesbar = "?". Nur lesen.
function Coop.AttachFix.Missing(J)
    local AF, Have, Out = Coop.AttachFix, {}, {}
    local function AssetName(D) return IsAlive(D) and D:GetFName():ToString() or "?" end
    Safe(function()
        J.InstalledAttachments:ForEach(function(_, Entry)
            local A = Entry:get()
            local D = IsAlive(A) and Safe(function() return A["Attachment Info"] end)
            if not IsAlive(D) and IsAlive(A) then D = Safe(function() return A.AttachmentInfo end) end
            local N = AssetName(D)
            Have[N] = (Have[N] or 0) + 1
        end)
    end)
    Safe(function()
        J.RepAttachments[P.ATTACH]:ForEach(function(_, Entry)
            if AF.IsAmmo(Entry) then return end   -- Munition wird nie eingebaut (Runde 3)
            local N = AssetName(Safe(function() return Entry:get()[AF.REP_ID] end))
            if (Have[N] or 0) > 0 then Have[N] = Have[N] - 1 else Out[#Out + 1] = N end
        end)
    end)
    return #Out > 0 and table.concat(Out, ",") or "-"
end

-- 2x/s: angehaengte Schusswaffen der Figur, neue/geaenderte scharf machen, abgelegte vergessen
function Coop.AttachFix.Scan(Pawn, Now)
    local AF, Attached, Seen = Coop.AttachFix, {}, {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local W = Entry:get()
        if IsAlive(W) and Safe(function() return AF.IsFirearm(W) end, false) then
            local J = P.Comp(W, "BP_JigPickupComponent_C")
            local Rep = J and AF.Count(J)
            if Rep then
                local Name = W:GetFName():ToString()
                local E = AF.W[Name]
                Seen[Name] = true
                if not E then
                    E = { W = W }
                    AF.W[Name] = E
                    AF.Arm(E, Rep, Now)   -- neue Waffe (aufgehoben, angelegt, nach Beitritt/Respawn)
                elseif Rep ~= E.Rep then
                    AF.Arm(E, Rep, Now)   -- Aufsaetze geaendert
                end
                E.W = W   -- Runde 3: jedes Mal frisch aus der Liste
                -- attach_flags: in die Hand genommen (Ziehen per Quickslot, auch gleich nach dem Beitritt) -> Flags
                -- 0,5 s spaeter pruefen (das Spiel setzt beim Ziehen selbst); Pruefung nur hier mit frischer Waffe
                local Socket = Safe(function() return W:GetAttachParentSocketName():ToString() end, "")
                if SETTINGS.attach_flags and Coop.IsHandSocket(Socket) and not Coop.IsHandSocket(E.Socket) then
                    E.FlagAt, E.FlagStep = Now + 0.5, 0
                end
                E.Socket = Socket
                if SETTINGS.attach_flags and E.FlagAt and Now >= E.FlagAt and not E.Armed then
                    local ok, err = pcall(AF.Flags, Name, E, W, J, Now)
                    if not ok then
                        E.FlagAt, E.FlagStep = nil, nil
                        if not AF.FlagErr then AF.FlagErr = true Log("Aufsatz-Flags-Fehler: %s", tostring(err)) end
                    end
                end
            end
        end
    end
    for Name in pairs(AF.W) do
        if not Seen[Name] then AF.W[Name] = nil end
    end
end

-- attach_flags (Runde 3): Nach dem Wiederbeitritt standen SuppressorAttached?/SightAttached? (BP_WeaponsPickupComponent)
-- beim Mitspieler auf false, obwohl Schalldaempfer und Visier eingebaut waren: Schuss ungedaempft, bis Magazin raus/rein.
-- Soll = eingebaute Aufsaetze (Klasse und Daten-Asset "Attachment Info") nach den Mustern unten. Nur "sollte an, ist
-- aus" gilt als falsch (ein unbekannter Aufsatz schaltet nie etwas ab). Schritt 0: OnAttachmentsUpdated der Waffe (wie
-- beim Magazinwechsel), Schritt 1 (naechster Scan, >= 0,3 s): noch falsch -> Flags direkt setzen, Schritt 2: Ergebnis.
-- Log einmal je Waffe (FlagLogged: Waffenname).
Coop.AttachFix.FLAGS = { { Flag = "SuppressorAttached?", Pat = { "suppressor", "silencer" } },
                         { Flag = "SightAttached?", Pat = { "sight", "scope", "optic", "reddot", "holo" } } }
Coop.AttachFix.FlagLogged = {}

-- Soll-Flags ([Flag] = true) und die eingebauten Aufsaetze (Text fuers Log)
function Coop.AttachFix.Wanted(J)
    local AF, Want, Names = Coop.AttachFix, {}, {}
    J.InstalledAttachments:ForEach(function(_, Entry)
        local A = Entry:get()
        if not IsAlive(A) then return end
        local Text = Safe(function() return A:GetClass():GetFName():ToString() end, "?")
        local D = Safe(function() return A["Attachment Info"] end)
        if not IsAlive(D) then D = Safe(function() return A.AttachmentInfo end) end
        if IsAlive(D) then Text = Text .. "/" .. D:GetFName():ToString() end
        Names[#Names + 1] = Text
        local Low = Text:lower()
        for _, F in ipairs(AF.FLAGS) do
            for _, Pat in ipairs(F.Pat) do if Low:find(Pat, 1, true) then Want[F.Flag] = true end end
        end
    end)
    return Want, table.concat(Names, ",")
end

function Coop.AttachFix.FlagLog(Name, Fmt, ...)
    local AF = Coop.AttachFix
    if AF.FlagLogged[Name] then return end
    AF.FlagLogged[Name] = true
    Log("Aufsatz-Flags %s: " .. Fmt, Name, ...)
end

function Coop.AttachFix.Flags(Name, E, W, J, Now)
    local AF = Coop.AttachFix
    E.FlagAt = nil
    local Rep, Installed = AF.Count(J)
    if not (Rep and Installed) or Installed < Rep then E.FlagStep = nil return end   -- noch nicht fertig eingebaut
    local WC = P.Comp(W, "BP_WeaponsPickupComponent_C")
    if not WC then E.FlagStep = nil return end
    local Want, Names = AF.Wanted(J)
    local Wrong = {}
    for _, F in ipairs(AF.FLAGS) do
        if Want[F.Flag] and Safe(function() return WC[F.Flag] end) ~= true then Wrong[#Wrong + 1] = F.Flag end
    end
    local Step = E.FlagStep or 0
    if #Wrong == 0 then
        if Step == 1 then AF.FlagLog(Name, "richtig nach OnAttachmentsUpdated (eingebaut %s)", Names)
        elseif Step == 2 then AF.FlagLog(Name, "direkt gesetzt, jetzt richtig (eingebaut %s)", Names) end
        E.FlagStep = nil
        return
    end
    if Step == 0 then
        local ok, err = pcall(function() W:OnAttachmentsUpdated() end)
        if not ok and not AF.FlagCallErr then AF.FlagCallErr = true Log("OnAttachmentsUpdated fehlgeschlagen: %s", tostring(err)) end
        E.FlagStep, E.FlagAt = 1, Now + 0.3
    elseif Step == 1 then
        for _, Flag in ipairs(Wrong) do pcall(function() WC[Flag] = true end) end
        E.FlagStep, E.FlagAt = 2, Now + 0.3
    else
        AF.FlagLog(Name, "weiter falsch (%s) trotz Setzen (eingebaut %s)", table.concat(Wrong, ","), Names)
        E.FlagStep = nil
    end
end

-- 10x/s fuer jede scharfe Waffe: fertig? sonst den naechsten faelligen Schritt
function Coop.AttachFix.Step(Name, E, Now)
    local AF, W = Coop.AttachFix, E.W
    if not IsAlive(W) then AF.W[Name] = nil return end
    local J = P.Comp(W, "BP_JigPickupComponent_C")
    local Rep, Installed
    if J then Rep, Installed = AF.Count(J) end
    if not (Rep and Installed) then E.Armed = false return end
    if Rep ~= E.Rep then AF.Arm(E, Rep, Now) end
    local Age = Now - E.At
    if E.Rep == 0 then
        if Age >= 3 then E.Armed = false end   -- keine Aufsaetze (kommen sie spaeter, macht Scan neu scharf)
        return
    end
    local function Sight()
        local WC = P.Comp(W, "BP_WeaponsPickupComponent_C")
        return string.format("Visier %s, Daempfer %s", tostring(WC and Safe(function() return WC["SightAttached?"] end)),
            tostring(WC and Safe(function() return WC["SuppressorAttached?"] end)))
    end
    if Installed >= E.Rep then
        E.Armed = false
        -- attach_flags: Schalldaempfer-/Visier-Flags im naechsten Scan pruefen (Coop.AttachFix.Flags)
        if SETTINGS.attach_flags and E.Rep > 0 then E.FlagAt, E.FlagStep = Now + 0.3, 0 end
        local How = E.Step == 0 and "(vom Spiel)" or string.format("(nach Schritt %d, %.1f s)", E.Step, Age)
        if E.PartDone then How = string.format("(nach Nachholen bei teilweise, %.1f s)", Now - E.PartDone) end
        Log("Aufsaetze %s: %d/%d eingebaut %s, %s%s", Name, Installed, E.Rep, How, Sight(),
            Installed > E.Rep and " - DOPPELT (mehr eingebaut als repliziert)" or "")
    elseif SETTINGS.attach_partial and (Installed > 0 or E.PartDone) then
        -- attach_partial: dieselbe Teilzahl 1,5 s lang -> genau einmal ProcessAttachments, 1 s spaeter Schluss.
        -- Faellt Installed danach auf 0, nicht in die Schritte unten (die riefen sofort noch 2x ProcessAttachments)
        if E.PartN ~= Installed then E.PartN, E.PartAt = Installed, Now end
        if not E.PartDone and Now - E.PartAt >= 1.5 then
            E.PartDone = Now
            Log("Aufsaetze %s: %d/%d eingebaut seit %.1f s, %s, fehlt %s -> ProcessAttachments", Name, Installed, E.Rep,
                Now - E.PartAt, Sight(), AF.Missing(J))
            pcall(function() J:ProcessAttachments() end)
        elseif E.PartDone and Now - E.PartDone >= 1.0 then
            E.Armed = false
            Log("Aufsaetze %s: nach dem Nachholen weiter %d/%d eingebaut, %s, fehlt %s (aufgegeben)", Name, Installed,
                E.Rep, Sight(), AF.Missing(J))
        end
    elseif Installed > 0 then
        -- teilweise eingebaut: das Spiel ist dran, nicht dazwischenfunken (doppelte Aufsaetze)
        if Age >= 2.5 then
            E.Armed = false
            Log("Aufsaetze %s: %d/%d eingebaut, %s, fehlt %s (teilweise, kein Eingriff)", Name, Installed, E.Rep, Sight(),
                AF.Missing(J))
        end
    elseif E.Step == 0 and Age >= 0.5 then
        E.Step = 1
        pcall(function() J:OnRep_RepAttachments() end)
    elseif (E.Step == 1 and Age >= 1.0) or (E.Step == 2 and Age >= 2.0) then
        E.Step = E.Step + 1
        pcall(function() J:ProcessAttachments() end)
    elseif E.Step == 3 and Age >= 2.5 then
        E.Armed = false
        Log("Aufsaetze %s: weiter %d/%d eingebaut, %s, fehlt %s (aufgegeben)", Name, Installed, E.Rep, Sight(), AF.Missing(J))
    end
end

-- Aufgabe im Schnell-Loop (registriert dort, nur mit attach_v2)
function Coop.AttachFix.Tick(Now, Mode)
    local AF = Coop.AttachFix
    if Mode ~= "Client" then AF.W = {} return end
    AF.N = AF.N + 1
    if AF.N % 5 == 0 then
        local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
        if not IsAlive(Pawn) then AF.W = {} return end
        AF.Scan(Pawn, Now)
    end
    for Name, E in pairs(AF.W) do
        if E.Armed then
            local ok, err = pcall(AF.Step, Name, E, Now)
            if not ok then
                E.Armed = false
                if not AF.ErrLogged then AF.ErrLogged = true Log("Aufsatz-Fehler: %s", tostring(err)) end
            end
        end
    end
end
end

do
-- consume_fix: Gegenstand nach dem Verbrauch (leere Flasche nach dem Trinken). Das Spiel legt ihn beim Mitspieler nur
-- lokal an (JigTryAddItemSomewhere), der Server kennt ihn nicht: er blinkt kurz und ist weg (die alte Weiterleitung
-- Coop.Pending ist aus). Vor-Hook auf ConsumeItem der Spielerfigur, erst im ersten Online-Tick gesetzt (nicht beim
-- Laden, Solo bleibt unberuehrt). Der Callback liest nur Felder (Info.ItemID -> ItemGainedFromConsumption) und merkt
-- sich den Pfad, keine UFunction. Der Schnell-Loop schickt "consumed|<Pfad>|<n>" an den Host, server.lua
-- (Srv.OnConsumed) legt den Gegenstand vor die Fuesse. Nur beim Mitspieler, nur die eigene Figur.
-- Own = Adresse der eigenen Figur (Filter im Callback, 1x/s), Queue = { From, To } (To nil: es entsteht nichts)
Coop.Consume = { CLASS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
                 ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", Queue = {}, Own = nil, OwnAt = 0,
                 Hooked = false, RetryAt = 0 }

-- "Klasse /Game/Pfad.Name" -> "/Game/Pfad.Name"
function Coop.Consume.PathOf(O)
    return IsAlive(O) and O:GetFullName():match("^%S+%s+(%S+)$") or nil
end

-- Vor-Hook ConsumeItem(FRepItemInfo Info): nur Felder lesen und vormerken
function Coop.Consume.OnConsume(Context, Info)
    local CU = Coop.Consume
    if not CU.Own or #CU.Queue >= 20 then return end
    local Self = Context:get()
    if not (IsAlive(Self) and Self:GetAddress() == CU.Own) then return end
    local Item = Safe(function() return Info:get()[CU.ITEM_ID] end)
    if not IsAlive(Item) then return end
    local Gain = Safe(function() return Item.ItemGainedFromConsumption end)
    CU.Queue[#CU.Queue + 1] = { From = CU.PathOf(Item) or "?", To = CU.PathOf(Gain) }
end

-- Aufgabe im Schnell-Loop (registriert dort, nur mit consume_fix)
function Coop.Consume.Tick(Now, Mode)
    local CU = Coop.Consume
    if Mode ~= "Client" then CU.Own, CU.Queue = nil, {} return end
    if not CU.Hooked and Now >= CU.RetryAt then
        CU.RetryAt = Now + 5   -- Klasse noch nicht geladen: spaeter nochmal
        if IsAlive(StaticFindObject(CU.CLASS)) then
            CU.Hooked = true   -- nur ein Versuch (kein Hook-Stapel bei Fehlern)
            local ok = TryHook(CU.CLASS .. ":ConsumeItem", CU.OnConsume) ~= nil
            Log("Verbrauch-Hook (consume_fix) %s", ok and "gesetzt" or "fehlgeschlagen")
        end
    end
    if Now >= CU.OwnAt then
        CU.OwnAt = Now + 1
        local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
        CU.Own = IsAlive(Pawn) and Pawn:GetAddress() or nil
    end
    if #CU.Queue == 0 then return end
    local Queue, Count = CU.Queue, {}
    CU.Queue = {}
    for _, E in ipairs(Queue) do
        Log("Verbrauch gesehen: %s -> %s", E.From:match("([^%./]+)$") or E.From,
            E.To and (E.To:match("([^%./]+)$") or E.To) or "nichts")
        if E.To then Count[E.To] = (Count[E.To] or 0) + 1 end
    end
    for Path, N in pairs(Count) do pcall(Coop.SendChunked, Coop.SendToHost, "consumed", Path .. "|" .. N) end
end
end

do
-- inv_reconcile (Runde 3, ersetzt consume_fix): Aendert das Spiel beim Mitspieler ein Item selbst (leere Flasche nach dem
-- Trinken, Aufsatz vom Boden direkt auf die Waffe, gecheatete Doppel), liegt es nur lokal "wartend" im Inventar
-- (Pending? in FRepItemInfo, blinkt, gesperrt); der Server bestaetigt es nie. 1x/s: wartende Gegenstaende suchen; nach
-- WAIT s: ist das Asset ein ItemGainedFromConsumption (leere Flasche, Dose ...), den Server per "pend" bitten, es
-- anzulegen (Srv.PendingAdd, Format "<Pfad> <Anzahl>" wie Coop.Pending; der Server gleicht danach selbst ab). Danach
-- (und fuer alle anderen): Neuabgleich ueber den invsync-Weg (G.ResyncAt), hoechstens alle RESYNC_EVERY s und
-- MAX_RESYNC je 5 min. Ein Gegenstand, der MAX_TRIES Abgleiche ueberlebt, wird ignoriert (Log).
-- Tries/Ignore/PendN gelten je Asset-Pfad (Sig), nicht je Widget-Name: der Abgleich leert das UI und baut die Widgets
-- neu (neue Namen) - ein Platzhalter, der ihn ueberlebt (invsync liess schon Cheat-Items blinken), kaeme sonst als
-- "neuer" Gegenstand zurueck und loeste alle 10 s den naechsten Abgleich bzw. das naechste "pend" aus (Endlos-Abgleich,
-- leere Flaschen ohne Ende). Vergessen wird eine Sig erst FORGET s, nachdem zuletzt einer davon wartete.
-- Felder werden einmal zur Laufzeit gesucht (Discover): Pending-Feld ueber den Parameter von ConsumeItem (FRepItemInfo),
-- Gegenstands-Klasse ueber ein ausgeruestetes Item (wie RefillHotbar). Gemerkt werden nur Namen und Zahlen.
local IR = { WAIT = 3, PEND_WAIT = 8, RESYNC_EVERY = 10, MAX_RESYNC = 6, MAX_TRIES = 2, PEND_MAX = 3, FORGET = 60,
             At = 0, Seen = {}, Sent = {}, Tries = {}, Ignore = {}, SigSeen = {}, PendN = {}, ResyncAt = -math.huge,
             Win = { Since = -math.huge, N = 0 }, GainAt = -math.huge,
             DiscoverAt = 0, DiscoverN = 0, ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
             COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD" }
Coop.InvRec = IR

function IR.Reset()
    IR.Seen, IR.Sent, IR.Tries, IR.Ignore, IR.SigSeen, IR.PendN, IR.At = {}, {}, {}, {}, {}, {}, 0
end

-- Pending-Feld (und Anzahl-Feld) von FRepItemInfo ueber den Parameter Info von BP_PlayerCharacter_C:ConsumeItem
function IR.FindInfoStruct()
    local Fn = StaticFindObject(Coop.Consume.CLASS .. ":ConsumeItem")
    if not IsAlive(Fn) then return end
    Fn:ForEachProperty(function(Prop)
        local S = Safe(function() return Prop:GetStruct() end)
        if not IsAlive(S) then return end
        local Pend, Count
        S:ForEachProperty(function(F)
            local N = F:GetFName():ToString()
            if N:find("^Pending") then Pend = N end
            if N:find("^Count_") then Count = N end
        end)
        if Pend then
            IR.InfoStruct, IR.PendField, IR.CountField = S:GetFName():ToString(), Pend, Count or IR.COUNT
            return true
        end
    end)
end

-- Gegenstands-Klasse (Widget) und wo sein Pending steht: Struktur-Eigenschaft vom Typ FRepItemInfo (InfoProp), sonst
-- eine Bool-Eigenschaft mit "pending" im Namen (FlagProp)
function IR.Probe(Item)
    local Class = Item:GetClass()
    local Info, Flag, C = nil, nil, Class
    while C and IsAlive(C) and not Info do
        C:ForEachProperty(function(Prop)
            local N = Prop:GetFName():ToString()
            local Kind = Safe(function() return Prop:GetClass():GetFName():ToString() end, "")
            if Kind == "StructProperty" and IR.InfoStruct and not Info then
                if Safe(function() return Prop:GetStruct():GetFName():ToString() end) == IR.InfoStruct then Info = N end
            elseif Kind == "BoolProperty" and not Flag and N:lower():find("pending", 1, true) then
                Flag = N
            end
        end)
        C = Safe(function() return C:GetSuperStruct() end)
    end
    IR.ItemClass, IR.InfoProp, IR.FlagProp = Class:GetFName():ToString(), Info, Flag
end

function IR.Discover(Pawn, Now)
    if Now < IR.DiscoverAt then return end
    IR.DiscoverAt, IR.DiscoverN = Now + 10, IR.DiscoverN + 1
    if not IR.InfoStruct then pcall(IR.FindInfoStruct) end
    local Item = nil
    Pawn.MainJSIContainers:ForEach(function(_, Entry)
        if Item then return end
        local Container = Entry:get()
        if not IsAlive(Container) then return end
        local Found, Ref = {}, {}
        pcall(function() Container:GetEquippedItemRef(Found, Ref, {}) end)
        if Found["Found?"] and IsAlive(Ref.ItemRef) then Item = Ref.ItemRef end
    end)
    if Item then pcall(IR.Probe, Item) end
    IR.Ready = IR.ItemClass ~= nil and ((IR.InfoProp ~= nil and IR.PendField ~= nil) or IR.FlagProp ~= nil)
    -- ohne ausgeruesteten Gegenstand weiter alle 10 s suchen; Klasse da, aber kein Feld: nach 3 Versuchen aus
    if IR.DiscoverN == 3 and not IR.ItemClass then Log("Inventar-Abgleich: noch kein ausgeruesteter Gegenstand zum Suchen der Felder") end
    if IR.Ready or (IR.ItemClass and IR.DiscoverN >= 3) then
        Log("Inventar-Abgleich (inv_reconcile): %s - Klasse %s, FRepItemInfo %s (Pending %s), am Gegenstand %s / Flag %s",
            IR.Ready and "bereit" or "AUS, Felder nicht gefunden", tostring(IR.ItemClass), tostring(IR.InfoStruct),
            tostring(IR.PendField), tostring(IR.InfoProp), tostring(IR.FlagProp))
        if not IR.Ready then IR.Off = true end
    end
end

function IR.IsPending(Item)
    if IR.InfoProp then return Safe(function() return Item[IR.InfoProp][IR.PendField] == true end, false) end
    return Safe(function() return Item[IR.FlagProp] == true end, false)
end

-- Pfad des Daten-Assets und Anzahl eines Gegenstands (nil, wenn nicht lesbar)
function IR.AssetOf(Item)
    local Asset = IR.InfoProp and Safe(function() return Item[IR.InfoProp][IR.ITEM_ID] end)
    if not IsAlive(Asset) then
        Asset = Safe(function() local Out = {} Item:GetJigDA(Out) return Out.JigDataAsset end)
    end
    local Count = IR.InfoProp and tonumber(Safe(function() return Item[IR.InfoProp][IR.CountField] end)) or 1
    return IsAlive(Asset) and Coop.Consume.PathOf(Asset) or nil, math.max(1, math.floor(Count))
end

-- Pfade aller ItemGainedFromConsumption (einmal gebaut, hoechstens alle 60 s neu, nur wenn gebraucht)
function IR.GainSet(Now)
    if IR.Gain and Now - IR.GainAt < 60 then return IR.Gain end
    IR.GainAt = Now
    local Set, N = {}, 0
    for _, DA in ipairs(FindAllOf("JigsawItem_DataAsset_C") or {}) do
        local Gain = IsAlive(DA) and Safe(function() return DA.ItemGainedFromConsumption end)
        local Path = IsAlive(Gain) and Coop.Consume.PathOf(Gain)
        if Path and not Set[Path] then Set[Path], N = true, N + 1 end
    end
    if N ~= IR.GainN then Log("Inventar-Abgleich: %d Gegenstaende entstehen beim Verbrauch (leere Flasche u. ae.)", N) end
    IR.Gain, IR.GainN = Set, N
    return Set
end

-- 1x/s aus der Hauptschleife (verbundener Mitspieler mit HUD)
function IR.Tick(Pawn)
    if not SETTINGS.inv_reconcile or IR.Off or not Coop.InventoryMode then return end
    local Now = os.clock()
    if Now < IR.At then return end
    IR.At = Now + 1
    if not IR.Ready then IR.Discover(Pawn, Now) return end
    local Seen, Stale, Total = {}, {}, 0
    for _, Item in ipairs(FindAllOf(IR.ItemClass) or {}) do
        if IsAlive(Item) and IR.IsPending(Item) then
            Total = Total + 1
            local Key = Item:GetFName():ToString()
            Seen[Key] = IR.Seen[Key] or Now
            if Now - Seen[Key] >= IR.WAIT then
                local Path, Count = IR.AssetOf(Item)
                local Sig = Path or "?"   -- unlesbar: alle zusammen
                IR.SigSeen[Sig] = Now
                if not IR.Ignore[Sig] then
                    Stale[#Stale + 1] = { Item = Item, Key = Key, Sig = Sig, Path = Path, Count = Count }
                end
            end
        end
    end
    -- Vergessen: Sent je Widget sofort, Tries/Ignore/PendN je Sig erst FORGET s nach dem letzten Warten (nur Namen)
    for Key in pairs(IR.Sent) do if not Seen[Key] then IR.Sent[Key] = nil end end
    for Sig, T in pairs(IR.SigSeen) do
        if Now - T >= IR.FORGET then IR.SigSeen[Sig], IR.Tries[Sig], IR.Ignore[Sig], IR.PendN[Sig] = nil, nil, nil, nil end
    end
    IR.Seen = Seen
    if #Stale == 0 then return end
    local Gain, Pend, Other, Resync = IR.GainSet(Now), 0, 0, false
    for _, S in ipairs(Stale) do
        if IR.Sent[S.Key] then
            if Now - IR.Sent[S.Key] >= IR.PEND_WAIT then Resync = true end   -- "pend" ohne Wirkung
        elseif S.Path and Gain[S.Path] and (IR.PendN[S.Sig] or 0) < IR.PEND_MAX then
            pcall(Coop.SendChunked, Coop.SendToHost, "pend", S.Path .. " " .. tostring(math.min(S.Count, 10)))
            -- danach auch selbst abgleichen (lehnt der Server ab, kommt kein invsync); invsync setzt nur G.ResyncAt
            -- auf +2 s, beide fallen zu einem Abgleich zusammen. PendN: hoechstens PEND_MAX je Sig (blinkt der vom
            -- Server angelegte Gegenstand nach dem Abgleich wieder, kein "pend" ohne Ende)
            IR.Sent[S.Key], IR.PendN[S.Sig], Pend, Resync = Now, (IR.PendN[S.Sig] or 0) + 1, Pend + 1, true
            Log("Inventar-Abgleich: %s x%d wartet %.0f s (beim Verbrauch entstanden) -> beim Server angefragt",
                S.Path:match("([^%./]+)$") or S.Path, S.Count, Now - Seen[S.Key])
        else
            Other, Resync = Other + 1, true
        end
    end
    if not Resync or Now < IR.ResyncAt then return end
    -- Je Sig hoechstens MAX_TRIES Abgleiche: wartet danach wieder einer, ab jetzt ignorieren; abgleichen nur, wenn noch
    -- eine nicht ignorierte Sig uebrig ist
    local Sigs, Ignored, Left = {}, {}, 0
    for _, S in ipairs(Stale) do Sigs[S.Sig] = true end
    for Sig in pairs(Sigs) do
        if (IR.Tries[Sig] or 0) >= IR.MAX_TRIES then
            IR.Ignore[Sig], Ignored[#Ignored + 1] = true, Sig:match("([^%./]+)$") or Sig
        else
            Left = Left + 1
        end
    end
    if #Ignored > 0 then
        Log("Inventar-Abgleich: %s wartet nach %d Abgleichen weiter - ab jetzt ignoriert", table.concat(Ignored, ","), IR.MAX_TRIES)
    end
    if Left == 0 then return end
    local W = IR.Win
    if Now - W.Since >= 300 then W.Since, W.N = Now, 0 end
    if W.N >= IR.MAX_RESYNC then
        if not W.Logged then W.Logged = true Log("Inventar-Abgleich: %d Neuabgleiche in 5 min, Pause", W.N) end
        return
    end
    W.N, W.Logged, IR.ResyncAt = W.N + 1, nil, Now + IR.RESYNC_EVERY
    for Sig in pairs(Sigs) do if not IR.Ignore[Sig] then IR.Tries[Sig] = (IR.Tries[Sig] or 0) + 1 end end
    Log("Inventar-Abgleich: %d wartend (%d > %.0f s, %d angefragt, %d andere) -> Neuabgleich mit dem Server", Total,
        #Stale, IR.WAIT, Pend, Other)
    if Coop.HostDataHandlers.invsync then Coop.HostDataHandlers.invsync() end
end
end

-- Karte beim Mitspieler: Das Spiel baut sie in ReceivePossessed, und das laeuft nur auf dem Server (beim
-- Listen-Host also nur fuer seine eigene Figur). Darum baut der Mitspieler sie fuer seine Figur selbst.
-- GPS: IsGPSEquipped? liest die Ausruestungsliste der Figur, die beim Mitspieler leer bleibt. Der Host meldet
-- jedem Mitspieler, ob er laut Server ein GPS traegt; beim Mitspieler setzt ein Post-Hook den Wert.
Coop.Map = { BuiltFor = nil, OwnAddress = nil, HasGps = false, HostSent = {}, Hooked = false }

Coop.Map.ClientTick = function(Pawn)
    local Name = Pawn:GetFName():ToString()
    local Minimap = Pawn.MinimapSystemComponent
    if not IsAlive(Minimap) then return end
    if Coop.Map.BuiltFor ~= Name then
        if not IsAlive(Minimap.MapWidget) then
            Minimap:Event_ConstructMap()
            Log("Karte fuer die eigene Figur gebaut: %s", tostring(IsAlive(Minimap.MapWidget)))
        end
        Coop.Map.BuiltFor, Coop.Map.OwnAddress = Name, Pawn:GetAddress()
    end
    -- ToggleMap fragt IsGPSEquipped? (beim Mitspieler false) und blendet Spieler-Symbol, Marker-Auswahl und
    -- Marker-Ebene ein (4 = SelfHitTestInvisible) oder aus (2). Hooks halfen nicht (Post-Hook auf IsGPSEquipped?:
    -- Ausgabe schon uebergeben; ToggleMap-Hook feuerte nicht). Darum jede Sekunde: Karte offen, Server meldet
    -- GPS, Symbol versteckt -> einblenden.
    local Widget = Minimap.MapWidget
    local Open = IsAlive(Widget) and Widget:IsVisible()
    if Coop.Map.HasGps and Open then
        local Texture = Widget.PlayerTexture
        if IsAlive(Texture) and not Texture:IsVisible() then
            for _, Part in ipairs({ "PlayerTexture", "PlayerMarkerSelectionUI", "StandardMarkerOverlay" }) do
                pcall(function() local W = Widget[Part] if IsAlive(W) then W:SetVisibility(4) end end)
            end
            if not Coop.Map.ShowLogged then Coop.Map.ShowLogged = true Log("Karte: eigene Position per GPS eingeblendet") end
        end
        -- Die Karte oeffnet immer auf die Weltmitte (4,5 km breit): das eigene Symbol lag ausserhalb des
        -- sichtbaren Bereichs. Beim Oeffnen einmal auf die eigene Position zentrieren (Funktion des Spiels,
        -- die es selbst nirgends aufruft).
        if not Coop.Map.WasOpen then
            local ok = pcall(function() Widget:SetScreenPositionToPlayer() end)
            if not Coop.Map.CenterLogged then Coop.Map.CenterLogged = true Log("Karte auf die eigene Position zentriert: %s", tostring(ok)) end
        end
    end
    Coop.Map.WasOpen = Open
end

-- Host, pro Mitspieler: GPS-Stand bei Aenderung (und alle 15 s) schicken
Coop.Map.HostTick = function(Key, PC, Pawn, Now)
    local Out = {}
    Pawn["IsGPSEquipped?"](Pawn, Out)
    local Value = Out["GPS?"] and "1" or "0"
    local Sent = Coop.Map.HostSent[Key]
    if Sent and Sent.Value == Value and Now < Sent.At + 15 then return end
    Coop.Map.HostSent[Key] = { Value = Value, At = Now }
    Coop.SendChunked(function(T) SendToClient(PC, T) end, "gps", Value)
end

Coop.HostDataHandlers.gps = function(Value)
    if Coop.Map.HasGps ~= (Value == "1") then Log("GPS laut Server: %s", Value == "1" and "ausgeruestet" or "keins") end
    Coop.Map.HasGps = Value == "1"
end

-- Ausruestung am Koerper (Messer am Guertel, Waffe auf dem Ruecken): Die Lage kommt vom Host richtig an
-- (AttachmentReplication), wird beim Mitspieler aber beim Anlegen mit Drehung 0 ueberschrieben - das Messer
-- stand quer ab, bis man es zog und wegsteckte (alle Nahkampfwaffen, auch nach Looten/Umruesten). Jede
-- Sekunde: gleicher Socket, andere Lage -> die vom Host nehmen. In der Hand setzt die Animation die Lage.
Coop.Attach = { HAND = { Weapon_r = true, MeleeWeapon_r = true }, Fixed = 0 }

-- Gleiche Ausrichtung? (Ueber die Achsen: bei Pitch +-90 gibt es viele gleichwertige Yaw/Roll-Paare)
Coop.Attach.Axes = function(R)
    local P, Y, Rl = math.rad(R.Pitch), math.rad(R.Yaw), math.rad(R.Roll)
    local SP, CP, SY, CY, SR, CR = math.sin(P), math.cos(P), math.sin(Y), math.cos(Y), math.sin(Rl), math.cos(Rl)
    return { CP * CY, CP * SY, SP }, { -(CR * SP * CY + SR * SY), CY * SR - CR * SP * SY, CR * CP }
end

Coop.Attach.Same = function(A, B)
    local AX, AZ = Coop.Attach.Axes(A)
    local BX, BZ = Coop.Attach.Axes(B)
    local function Dot(U, V) return U[1] * V[1] + U[2] * V[2] + U[3] * V[3] end
    return Dot(AX, BX) > 0.999 and Dot(AZ, BZ) > 0.999
end

Coop.Attach.ClientTick = function()
    for _, Pawn in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        local Attached = {}
        if IsAlive(Pawn) then Pawn:GetAttachedActors(Attached, true, false) end
        for _, Entry in ipairs(Attached) do
            local Item = Entry:get()
            local Root = IsAlive(Item) and Item.RootComponent
            local Rep = IsAlive(Root) and Item.AttachmentReplication
            local Socket = Rep and Rep.AttachSocket:ToString()
            if Socket and not Coop.Attach.HAND[Socket] and Root:GetAttachSocketName():ToString() == Socket then
                local R, L, WR, WL = Root.RelativeRotation, Root.RelativeLocation, Rep.RotationOffset, Rep.LocationOffset
                local Moved = (L.X - WL.X) ^ 2 + (L.Y - WL.Y) ^ 2 + (L.Z - WL.Z) ^ 2 > 1
                if Moved or not Coop.Attach.Same(R, WR) then
                    Root:K2_SetRelativeLocationAndRotation({ X = WL.X, Y = WL.Y, Z = WL.Z },
                        { Pitch = WR.Pitch, Yaw = WR.Yaw, Roll = WR.Roll }, false, {}, true)
                    Coop.Attach.Fixed = Coop.Attach.Fixed + 1
                    if Coop.Attach.Fixed <= 5 then
                        Log("Ausruestung %s an %s auf die Lage vom Host gesetzt", Item:GetClass():GetFName():ToString(), Socket)
                    end
                end
            end
        end
    end
end

-- Kleidung beim Mitspieler: Ist ein Kleidungs-Platz belegt, aber kein Modell geladen (Schuhe fehlten, weil das
-- Anwenden des Aussehens die Fuesse nach dem letzten Nachsenden zuruecksetzte), den Host um erneutes Senden
-- bitten - hoechstens alle 3 s (Aufruf 1x/s aus der Hauptschleife). Einmal Nachsenden brachte die Schuhe zurueck.
Coop.Cloth = { SLOTS = { { "ClothingTorsoEquipped?", "Clothing_Torso" }, { "ClothingGlovesEquipped?", "Clothing_Gloves" },
                         { "ClothingLegsEquipped?", "Clothing_Legs" }, { "ClothingFeetEquipped?", "Clothing_Feet" } },
               AskedAt = 0, Asked = 0,
               -- cloth_ask_cap: erfolglose Bitten je "Figur#Platz" (Flag gesetzt, aber kein Gegenstand beim Host ->
               -- jedes Nachsenden setzt per MC_AttachClothing die Waffen-Animation zurueck), hoechstens MAX_TRIES
               Tries = {}, TriesN = 0, MAX_TRIES = 5 }

Coop.Cloth.ClientTick = function()
    local Now = os.time()
    if Now - Coop.Cloth.AskedAt < 3 then return end
    local Core = Coop.Modules and Coop.Modules.ls_core
    local Cap = not (Core and Core.Flag) or Core.Flag("cloth_ask_cap", true) == true
    for _, Pawn in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if IsAlive(Pawn) and IsAlive(Pawn.PlayerState) then
            local PawnName = Safe(function() return Pawn:GetFName():ToString() end, "?")
            for Index, Slot in ipairs(Coop.Cloth.SLOTS) do
                local Missing = Safe(function()
                    if Pawn[Slot[1]] ~= true then return false end
                    local Mesh = Pawn[Slot[2]]
                    if not IsAlive(Mesh) then return false end
                    local Asset = Mesh:GetSkeletalMeshAsset()
                    return not (Asset and Asset:IsValid())
                end, false)
                local TK = PawnName .. "#" .. Index
                if not Missing then
                    Coop.Cloth.Tries[TK] = nil
                elseif not Cap or (Coop.Cloth.Tries[TK] or 0) < Coop.Cloth.MAX_TRIES then
                    if Cap then
                        if Coop.Cloth.Tries[TK] == nil then
                            Coop.Cloth.TriesN = Coop.Cloth.TriesN + 1
                            if Coop.Cloth.TriesN > 256 then Coop.Cloth.Tries, Coop.Cloth.TriesN = {}, 1 end
                        end
                        Coop.Cloth.Tries[TK] = (Coop.Cloth.Tries[TK] or 0) + 1
                        if Coop.Cloth.Tries[TK] == Coop.Cloth.MAX_TRIES then
                            Log("Kleidung %s bei %s: %d-mal erfolglos angefragt - keine weiteren Bitten (Platz belegt, Host hat kein Modell)",
                                Slot[2], PawnName, Coop.Cloth.MAX_TRIES)
                        end
                    end
                    Coop.Cloth.AskedAt, Coop.Cloth.Asked = Now, Coop.Cloth.Asked + 1
                    -- Nur diesen Platz (die SpielerId ist auf beiden Seiten gleich, Figurennamen nicht)
                    Coop.SendChunked(Coop.SendToHost, "clothslot",
                        tostring(Pawn.PlayerState:GetPlayerId()) .. "#" .. tostring(Index))
                    if Coop.Cloth.Asked <= 5 then
                        Log("Kleidung fehlt bei %s (%s): Host um erneutes Senden gebeten", Pawn:GetFName():ToString(), Slot[2])
                    end
                    return
                end
            end
        end
    end
end

-- Diagnose Blutung (gemeldet: hoert beim Mitspieler nicht von selbst auf, im Spiel sonst nach 10-12 s):
-- Zustand und Timer der eigenen Figur bei jeder Aenderung ins Log (der Host loggt seine Seite, server.lua).
Coop.Medic = {}

Coop.Medic.State = function(Pawn)
    local M = Pawn.MedicalComponent
    if not IsAlive(M) then return "keine MedicalComponent" end
    local function Handle(Name) return Safe(function() return tostring(M[Name].Handle) end, "?") end
    return string.format("Blutung=%s schwer=%s BleedTimer=%s StopTimer=%s HeavyStopTimer=%s",
        tostring(M["Bleed?"]), tostring(M["HeavyBleed?"]), Handle("BleedTimer"), Handle("BleedStopTimer"),
        Handle("HeavyBleedStopTimer"))
end

-- Host, pro Mitspieler: Das Spiel beendet Blutung, schwere Blutung und Knochenbruch per Timer, den
-- Event_TimeToStop... startet - das ist ein Client-RPC: Beim Mitspieler lief der Timer auf dessen Rechner und
-- setzte die Blutung nur dort zurueck, beim Host blutete die Figur bis zum Tod (Diagnose: StopTimer blieb
-- beim Host 0, 57 Aufrufe von Event_TimeToStopBleed ohne Wirkung). Darum zaehlt der Host selbst und ruft nach
-- der Zeit des Spiels die Funktion, die der Timer aufriefe (setzt den Zustand zurueck, repliziert, OnRep).
Coop.Medic.STOPS = { { "Bleed?", "Time_Bleed", 10, 12 }, { "HeavyBleed?", "Time_HeavyBleed", 14, 16 },
                     { "BrokenBone?", "Time_BrokenBone", 180, 360 } }
Coop.Medic.Due = {}   -- [Figur .. Zustand] = Zeitpunkt, zu dem er endet

Coop.Medic.HostTick = function(Pawn)
    local M, Name, Now = Pawn.MedicalComponent, Pawn:GetFName():ToString(), os.time()
    if not IsAlive(M) then return end
    for _, E in ipairs(Coop.Medic.STOPS) do
        local Key = Name .. E[1]
        if M[E[1]] ~= true then
            Coop.Medic.Due[Key] = nil
        elseif not Coop.Medic.Due[Key] then
            Coop.Medic.Due[Key] = Now + math.random(E[3], E[4])
        elseif Now >= Coop.Medic.Due[Key] then
            Coop.Medic.Due[Key] = nil
            M[E[2]](M)
            Log("%s bei %s nach der Zeit des Spiels beendet: %s", E[1], Name, tostring(M[E[1]]))
        end
    end
end

Coop.Medic.ClientTick = function(Pawn)
    local State = Coop.Medic.State(Pawn)
    if State ~= Coop.Medic.Last then
        Coop.Medic.Last = State
        Log("Medizin (eigene Figur): %s", State)
    end
end

-- Mitspieler-Zustand zuruecksetzen (nicht verbunden; world_hygiene: auch bei jedem Weltwechsel aus Coop.DropWorldRefs,
-- sonst blieb er nach Trennen -> Solo stehen, weil die Hauptschleife solo vor HandleClient endet)
function Coop.ClientWorldReset()
    ClientConnectedSince, MenuClosed, LastClientPawn, ClientPawnSince = nil, false, nil, nil
    GhostWatch, GhostScanDone, PendingActors = false, false, {}
    if SETTINGS.spawner_stop ~= 0 then Coop.SpawnerStop.Reset() end
    Coop.ResetClientInventory()
    Coop.ResetGuestId()
    Coop.ResetCorpses()
    Coop.ResetSky()
    Coop.Zombies.Reset()
    PossessReplayed, HudChecked = false, false
    Coop.JoinC, Coop.HostJoin = nil, nil   -- join_v2: naechster Beitritt beginnt neu (auch nach Trennen im Laden)
end

local function HandleClient(World)
    local Connected = false
    if NetModeName(World) == "Client" then
        local NetDriver = Safe(function() return World.NetDriver end)
        Connected = NetDriver and NetDriver:IsValid() and NetDriver.ServerConnection:IsValid() or false
    end
    if not Connected then
        Coop.ClientWorldReset()
        return
    end
    local Now = os.time()
    ClientConnectedSince = ClientConnectedSince or Now
    -- join_v2: ab dem Verbinden den Ladebildschirm halten, bis die Figur am Ziel bereit ist (Coop.Join.ClientTick;
    -- alter Host/lokales Inventar: gleich wieder aus)
    if SETTINGS.join_v2 and SETTINGS.hp_v2 and not Coop.JoinC then
        Coop.JoinC = { State = "wait", T0 = os.clock() }
        Log("Beitritt: Ladebildschirm bleibt bis zum Ziel (join_v2)")
    end
    -- hello an den Host (hp_v2), sobald verbunden und noch vor der eigenen Figur
    local okNet, errNet = pcall(Coop.Zombies.NetClientTick)
    if not okNet and not Coop.Zombies.NetClientErr then Coop.Zombies.NetClientErr = true Log("hello-Fehler: %s", tostring(errNet)) end
    if not MenuClosed and Now - ClientConnectedSince >= SPAWN_DELAY then
        MenuClosed = true
        SetupClient()
    end
    -- Sobald der Host uns eine Figur gibt (oder eine neue), Menue und Steuerung erneut einrichten.
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local PawnName = IsAlive(Pawn) and Pawn:GetFName():ToString() or nil
    if PawnName and PawnName ~= LastClientPawn then
        LastClientPawn, ClientPawnSince = PawnName, Now
        PossessReplayed, HudChecked = false, false
        Log("Eigene Figur erhalten: %s", PawnName)
        SetupClient()
    end
    DisableClientSaving()
    -- CORE-31 (perf_rates): Steuerungs-Pruefung (4x FindAllOf) nur alle 3 s statt jede Sekunde
    if MenuClosed and (not Coop.PerfRates or os.clock() >= (Coop.InputWatchAt or 0)) then
        Coop.InputWatchAt = os.clock() + 3
        local okIn, errIn = pcall(Coop.InputWatch)
        if not okIn and not Coop.InputErr then Coop.InputErr = true Log("Steuerungs-Pruefung fehlgeschlagen: %s", tostring(errIn)) end
    end
    pcall(Coop.Link.ClientTick)
    local okBody, errBody = pcall(Coop.HoldDeadBodies)
    if not okBody then Log("Fehler bei toten Figuren: %s", tostring(errBody)) end
    local okRag, errRag = pcall(Coop.RagdollDeadAI)
    if not okRag then Log("Leichen-Fehler: %s", tostring(errRag)) end
    local okZom, errZom = pcall(Coop.Zombies.ClientTick)
    if not okZom then Log("Zombie-Leben-Fehler: %s", tostring(errZom)) end
    local okGhost, errGhost = pcall(CleanupClientGhosts)
    if not okGhost then Log("Geister-Fehler: %s", tostring(errGhost)) end
    -- spawner_stop: Spawner beim Mitspieler aus (Coop.SpawnerStop; 0 = wie bisher nur Geister entfernen)
    if SETTINGS.spawner_stop ~= 0 then
        local okSp, errSp = pcall(Coop.SpawnerStop.ClientTick)
        if not okSp and not Coop.SpawnerStop.TickErr then Coop.SpawnerStop.TickErr = true Log("Spawner-Stopp-Fehler: %s", tostring(errSp)) end
    end
    if not PawnName then return end
    local okFreeze, errFreeze = pcall(Coop.UnfreezeOwnPawn, Pawn, ClientPawnSince)
    if not okFreeze then Log("Spawn-Freigabe-Fehler: %s", tostring(errFreeze)) end
    -- join_v2: Figur steht schon am Ziel ("spawned" vom Host): HUD sofort hinter dem Ladebildschirm statt nach
    -- SETUP_DELAY + HUD_DELAY. HudChecked startet gleich darunter G.ClientTick (UI leeren, guestid#seq) - aber erst
    -- mit HUD (sonst kaeme die lokal gewuerfelte Startausruestung nach dem Leeren ins UI). Legt Client_AddUI es nicht
    -- sofort an: EnsureHud einen Durchlauf spaeter (os.clock + 1 s), sonst entstuende evtl. ein zweites.
    local JC = Coop.JoinC
    if Coop.Player then JC = Coop.Player.HudFast(JC) end   -- ls_player: Respawn hinter dem Ladebildschirm wie Beitritt
    if JC and JC.State == "spawned" and not HudChecked and JC.HudFor ~= PawnName then
        JC.HudFor, JC.HudAt = PawnName, os.clock() + 1
        -- Kam "spawned" spaeter als SETUP_DELAY nach der Figur, hat der alte Weg ReceivePossessed schon nachgeholt:
        -- nicht doppelt (Hotbar/Komponenten doppelt eingerichtet)
        if not PossessReplayed then
            PossessReplayed = true
            ReplayPossessed(Pawn)
            if not IsAlive(Safe(function() return Pawn.InGameUI end)) then
                local ok, err = pcall(function() Pawn:Client_AddUI() end)
                Log("HUD ueber Client_AddUI (Beitritt): %s", ok and "aufgerufen" or tostring(err))
            end
            SetupClient()
        end
        if IsAlive(Safe(function() return Pawn.InGameUI end)) then
            JC.HudAt, HudChecked = nil, true
            local ok, err = pcall(EnsureHud, Pawn)
            if not ok then Log("HUD-Fehler: %s", tostring(err)) end
        end
    elseif JC and JC.HudAt and JC.HudFor == PawnName and not HudChecked and os.clock() >= JC.HudAt then
        JC.HudAt, HudChecked = nil, true
        local ok, err = pcall(EnsureHud, Pawn)
        if not ok then Log("HUD-Fehler: %s", tostring(err)) end
    end
    if not PossessReplayed and Now - ClientPawnSince >= SETUP_DELAY then
        PossessReplayed = true
        ReplayPossessed(Pawn)
        -- Das HUD legt das Spiel ueber Client_AddUI an, das der Host beim Uebernehmen der Figur
        -- unzuverlaessig schickt (geht im Spawn-Frame oft verloren). Lokal einfach selbst aufrufen.
        if not IsAlive(Safe(function() return Pawn.InGameUI end)) then
            local ok, err = pcall(function() Pawn:Client_AddUI() end)
            Log("HUD ueber Client_AddUI: %s", ok and "aufgerufen" or tostring(err))
        end
        SetupClient()
    end
    if not HudChecked and Now - ClientPawnSince >= HUD_DELAY then
        HudChecked = true
        local ok, err = pcall(EnsureHud, Pawn)
        if not ok then Log("HUD-Fehler: %s", tostring(err)) end
    end
    if HudChecked and Now % 2 == 0 then
        local ok, err = pcall(RefillHotbar, Pawn)
        if not ok then Log("Hotbar-Fehler: %s", tostring(err)) end
    end
    if HudChecked then   -- Skillpunkt-Ausgaben an den Host (Coop.Stats.SpendTick)
        local okSp, errSp = pcall(Coop.Stats.SpendTick, os.clock())
        if not okSp and not Coop.Stats.SpendErr then Coop.Stats.SpendErr = true Log("Skillpunkt-Meldung fehlerhaft: %s", tostring(errSp)) end
    end
    if HudChecked then
        local okInv, errInv = pcall(Coop.ClientInventoryTick, Pawn)
        if not okInv then Log("Inventar-Fehler: %s", tostring(errInv)) end
        -- inv_reconcile: blinkende Gegenstaende (Runde 3); nicht waehrend des Beitritts (erster Abgleich laeuft noch)
        -- inv_v2b (ls_inv) ersetzt ihn (pend2 + Digest), dann ruht der alte Weg
        if not Coop.JoinLoading() and not (Coop.Modules and Coop.Modules.ls_inv and Coop.Modules.ls_inv.Active()) then
            local okRec, errRec = pcall(Coop.InvRec.Tick, Pawn)
            if not okRec and not Coop.InvRec.ErrLogged then Coop.InvRec.ErrLogged = true Log("Inventar-Abgleich-Fehler: %s", tostring(errRec)) end
        end
        -- Erst mit Figur und HUD: Waehrend des Beitritts entladen liess das Spiel abstuerzen (join_v2: HUD steht
        -- schon hinter dem Ladebildschirm, darum erst nach ready)
        if not Coop.JoinLoading() then
            -- CORE-31 (perf_rates): je Welt nur, bis das Menue-Teillevel einmal entladen ist (hoechstens 30 Versuche)
            local MU = Coop.MenuUnload
            if not MU or MU.Gen ~= WorldGen.N then MU = { Gen = WorldGen.N, N = 0 } Coop.MenuUnload = MU end
            if not Coop.PerfRates or (not MU.Done and MU.N < 30) then
                MU.N = MU.N + 1
                local okMenu, Res = pcall(Coop.UnloadMenuLevel, World)
                if not okMenu then Log("Menue-Level-Fehler: %s", tostring(Res)) elseif Res then MU.Done = true end
            end
        end
        -- ls_ui (ui_ammo/ui_map): 10-Hz-Task ui_fast ruft beides selbst, dann hier nicht doppelt
        local UiMod = Coop.Modules and Coop.Modules.ls_ui
        if not (UiMod and UiMod.Owns("ammo")) then pcall(Coop.AmmoTick) end
        local okMap, errMap = true, nil
        if not (UiMod and UiMod.Owns("map")) then okMap, errMap = pcall(Coop.Map.ClientTick, Pawn) end
        if not okMap then Log("Karten-Fehler: %s", tostring(errMap)) end
        pcall(Coop.Medic.ClientTick, Pawn)
        local okCloth, errCloth = pcall(Coop.Cloth.ClientTick)
        if not okCloth then Log("Kleidungs-Pruefung-Fehler: %s", tostring(errCloth)) end
        local okAtt, errAtt = pcall(Coop.Attach.ClientTick)
        if not okAtt and not Coop.Attach.ErrLogged then
            Coop.Attach.ErrLogged = true
            Log("Ausruestungs-Lage-Fehler: %s", tostring(errAtt))
        end
    end
    local okCol, errCol = pcall(Coop.SyncEquipmentCollision)
    if not okCol then Log("Kollisions-Fehler: %s", tostring(errCol)) end
end

do
-- join_v2: Beitritt direkt am Ziel hinter dem Ladebildschirm. Nur mit Empfangs-Hook (Server), Server-Inventar und
-- Mitspielern mit hello 3 (join_v2 an), sonst alles wie bisher.
--   Host: wartet bis WAIT_HELLO s auf das hello, spawnt dann direkt an der gespeicherten Position (Boden + 1 m) oder
--     am Spawnpunkt, haelt die Figur eingefroren und unverwundbar und schickt "spawned|X|Y|Z" (tatsaechliche Lage)
--     alle RESEND s bis "ready". Fehlt dort der Boden (Welt noch nicht geladen): 50 cm ueber dem Punkt eingefroren,
--     jeden Schnell-Tick neu suchen, nach GROUND_FOR s an einen Spawnpunkt. Inventar-Abgleich wie bisher (guestid#seq
--     -> G.Sync, ohne Teleport), danach "synced". Bei "ready" freigeben, Zeitlimit HOST_TIMEOUT s.
--   Mitspieler: haelt den Ladebildschirm (CloseMenus), richtet bei "spawned" sofort das HUD ein (HandleClient) und
--     meldet "ready", sobald spawned + synced + Figur am Ziel + Boden darunter geladen + HUD da. Zeitlimit
--     CLIENT_TIMEOUT s. Tod oder Trennen im Laden beendet das Warten auf beiden Seiten.
-- Coop.Join[Controller-Key] = { State = "spawned"|"ready"|"gone", PossessAt, Pos, ... } (Host), Coop.JoinC = { State =
-- "wait"|"spawned"|"ready"|"off", T0, Target, Synced } (Mitspieler). Zeitbasis os.clock (HandleRemotePlayers: os.time).
local J = { WAIT_HELLO = 6, RESEND = 2, GROUND_FOR = 10, HOST_TIMEOUT = 40, CLIENT_TIMEOUT = 30, NEAR = 300,
            NO_SPAWNED = 3, GONE_FOR = 3 }
Coop.Join = J

-- Host: Beitritt am Ziel fuer diesen Controller? Hello = auch das hello 3 des Mitspielers verlangen
function J.Eligible(Key, Hello)
    if not (SETTINGS.join_v2 and SETTINGS.hp_v2 and Coop.RecvHook) or SETTINGS.local_inventory then return false end
    return not Hello or Coop.GuestJoin[Key] == true
end

-- Host (HandleRemotePlayers, Age = s seit dem ersten Sehen): noch auf das hello des Mitspielers warten?
function J.WaitHello(Key, Age)
    return J.Eligible(Key, false) and not Coop.GuestProto[Key] and Age < J.WAIT_HELLO
end

-- Host: Ziel fuer den ersten Spawn. Gespeicherte Position (Server-Modus): Boden darunter + 1 m, ohne Boden 50 cm ueber
-- dem Punkt (Aim: dort weitersuchen). Sonst Spawnpunkt wie bisher (server.lua), aber genau dort. nil = bisheriger Weg.
-- Die Linie startet am gespeicherten Punkt + 50 cm (Up 0): Standpunkt einer Figur, also unter jeder Decke.
function J.Target(World, PC, Key)
    if not J.Eligible(Key, true) then return nil end
    local GuestId, Pos, Yaw = Coop.HelloIds[Key], nil, nil
    if GuestId and SETTINGS.server then Pos, Yaw = Coop.Stats.ReadPos(GuestId) end
    if Pos then
        local Floor = Coop.Ground(Pos, nil, 0)
        if Floor then return { X = Pos.X, Y = Pos.Y, Z = Floor + 100, Yaw = Yaw, Kind = "letzte Position" } end
        return { X = Pos.X, Y = Pos.Y, Z = Pos.Z, Yaw = Yaw, Kind = "letzte Position, Boden fehlt", Aim = Pos }
    end
    local HostPawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    if not IsAlive(HostPawn) then return nil end
    local Loc, StartYaw = HostPawn:K2_GetActorLocation(), HostPawn:K2_GetActorRotation().Yaw
    if SETTINGS.server then Loc, StartYaw = SETTINGS.server.SpawnPoint(World, PC, Loc, StartYaw) end
    return { X = Loc.X, Y = Loc.Y, Z = Loc.Z, Yaw = StartYaw, Kind = "Spawnpunkt" }
end

function J.Freeze(Pawn)
    if not IsAlive(Pawn) then return end
    pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:StopMovementImmediately() end end)
    pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:DisableMovement() end end)
end

-- Host: tatsaechliche Lage melden (nach einem Umsetzen die neue), "synced" mit, sobald abgeglichen
function J.SendSpawned(E)
    local L, PC = E.Pawn:K2_GetActorLocation(), E.PC
    E.Pos, E.SendAt = { X = L.X, Y = L.Y, Z = L.Z }, os.clock() + J.RESEND
    Coop.SendChunked(function(T) SendToClient(PC, T) end, "spawned", string.format("%.0f|%.0f|%.0f", L.X, L.Y, L.Z))
    if E.Synced then Coop.SendChunked(function(T) SendToClient(PC, T) end, "synced", "1") end
end

-- Host (HandleRemotePlayers, nach Possess): einfrieren, unverwundbar, server.lua nicht umsetzen lassen, "spawned"
function J.OnSpawned(Key, PC, Pawn, Target)
    local Name = Pawn:GetFName():ToString()
    local E = { State = "spawned", PossessAt = os.clock(), PC = PC, Pawn = Pawn, PawnName = Name, Placed = true,
                Kind = Target.Kind, SendAt = 0 }
    J[Key] = E
    pcall(function() Pawn.bCanBeDamaged = false end)
    J.Freeze(Pawn)
    if Target.Aim then E.Aim, E.GroundUntil = Target.Aim, E.PossessAt + J.GROUND_FOR end
    local Srv = SETTINGS.server
    if Srv and Srv.MarkPlaced then pcall(Srv.MarkPlaced, Name, Key) end
    local ok, err = pcall(J.SendSpawned, E)
    if not ok then Log("Beitritt: spawned senden fehlgeschlagen: %s", tostring(err)) end
    local P = E.Pos or Target
    Log("Beitritt: Figur %s direkt am Ziel (%s) %.0f %.0f %.0f, eingefroren bis ready", Name, Target.Kind, P.X, P.Y, P.Z)
end

-- Host (im Empfangs-Hook: nur merken, freigeben im Schnell-Loop)
function J.OnReady(Key)
    local E = J[Key]
    if type(E) == "table" and E.State == "spawned" and not E.ReadyAsked then
        E.ReadyAsked = true
    end
end

-- Host (G.HandleHost, nach erfolgreichem G.Sync)
function J.OnSynced(Key, PC)
    local E = J[Key]
    if type(E) ~= "table" or E.State ~= "spawned" then return end
    E.Synced = true
    Coop.SendChunked(function(T) SendToClient(PC, T) end, "synced", "1")
end

-- Host: Controller getrennt (HandleRemotePlayers)
function J.Forget(Key)
    if type(J[Key]) == "table" then J[Key] = nil end
    Coop.ForgetGuestSync(Key)
end

-- Fuer U.Guests, Coop.Link, ManageMovementTrust und den Spawn-Schutz in server.lua: false, solange dieser Controller
-- (Key, Text) bzw. diese Figur noch hinter dem Ladebildschirm wartet. Ohne join_v2 immer true.
function J.IsReady(X)
    if type(X) == "string" then
        local E = J[X]
        return not (type(E) == "table" and E.State == "spawned")
    end
    local Name
    for _, E in pairs(J) do
        if type(E) == "table" and E.State == "spawned" then
            Name = Name or Safe(function() return X:GetFName():ToString() end, "")
            if E.PawnName == Name then return false end
        end
    end
    return true
end

function J.MoveTo(E, Loc, Yaw, Why)
    local Pawn = E.Pawn
    -- E23 (move_check): Mod-Teleport, die naechsten 5 s keine Geschwindigkeits-Pruefung
    local PCKey = Safe(function() return IsAlive(E.PC) and E.PC:GetFullName() or nil end)
    if PCKey then
        Coop.TrustSkip = Coop.TrustSkip or {}
        Coop.TrustSkip[PCKey] = os.clock() + 5
    end
    local Rot = { Pitch = 0, Yaw = Yaw or Safe(function() return Pawn:K2_GetActorRotation().Yaw end, 0), Roll = 0 }
    local ok = Safe(function() return Pawn:K2_TeleportTo(Loc, Rot) end, false)
    if not ok then ok = pcall(function() Pawn:K2_SetActorLocation(Loc, false, {}, true) end) end
    J.Freeze(Pawn)
    E.SendAt = 0   -- neue Lage gleich melden
    Log("Beitritt: Figur %s umgesetzt (%s) nach %.0f %.0f %.0f: %s", E.PawnName, Why, Loc.X, Loc.Y, Loc.Z,
        ok and "ok" or "fehlgeschlagen")
end

-- Host: freigeben (Laufen, ohne Boden darunter Fallen). Verwundbar macht der Spawn-Schutz von server.lua (3 s nach
-- der Freigabe); hat er die Figur nicht (mehr), gleich hier.
function J.Release(E, Why)
    E.State, E.ReadyAt = "ready", os.clock()
    local Pawn = E.Pawn
    if not IsAlive(Pawn) then return end
    local Floor = Coop.Ground(Pawn:K2_GetActorLocation(), Pawn, 50)
    pcall(function() local Move = Pawn.CharacterMovement if IsAlive(Move) then Move:SetMovementMode(Floor and 1 or 3, 0) end end)
    local Srv = SETTINGS.server
    if not (Srv and Srv.Protect and Srv.Protect[E.PawnName]) then pcall(function() Pawn.bCanBeDamaged = true end) end
    Log("Beitritt: Figur %s freigegeben (%s) nach %.1f s, %s", E.PawnName, Why, E.ReadyAt - E.PossessAt,
        Floor and "steht am Boden" or "kein Boden darunter: faellt")
    -- Lebenswerte des Hosts jetzt (HUD steht) zum Mitspieler, siehe Coop.Stats.QueueVitset
    local okVit, errVit = pcall(function() if IsAlive(E.PC) then Coop.Stats.QueueVitset(E.PC:GetFullName()) end end)
    if not okVit then Log("vitset-Fehler: %s", tostring(errVit)) end
end

-- CORE-6 (E26): wartet dieser Controller noch auf das Server-Passwort? (server.lua Srv.AuthWait; ohne: nein)
function J.AuthWait(Key)
    local Srv = SETTINGS.server
    return type(Srv) == "table" and type(Srv.AuthWait) == "function"
        and Safe(function() return Srv.AuthWait(Key) end, false) == true
end

function J.HostStep(Key, E, Now, World)
    local Pawn, PC = E.Pawn, E.PC
    local Cur = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end) or nil
    if not IsAlive(Pawn) or not IsAlive(Cur) or Cur:GetFName():ToString() ~= E.PawnName then
        E.State = "gone"
        Log("Beitritt: Figur %s weg (Tod/Trennen im Laden), Warten beendet", E.PawnName)
        return
    end
    if E.GroundUntil then
        local Floor = Coop.Ground(E.Aim, Pawn, 0)
        if Floor then
            E.GroundUntil = nil
            J.MoveTo(E, { X = E.Aim.X, Y = E.Aim.Y, Z = Floor + 100 }, nil, "Boden geladen")
        elseif Now >= E.GroundUntil then
            E.GroundUntil = nil
            local Srv = SETTINGS.server
            if Srv then
                local L = Pawn:K2_GetActorLocation()
                local Loc, Yaw = Srv.SpawnPoint(World, PC, L, Safe(function() return Pawn:K2_GetActorRotation().Yaw end, 0))
                J.MoveTo(E, { X = Loc.X, Y = Loc.Y, Z = Loc.Z }, Yaw, string.format("kein Boden nach %d s: Spawnpunkt", J.GROUND_FOR))
                if Srv.MarkPlaced then pcall(Srv.MarkPlaced, E.PawnName, Key) end
            else
                Log("Beitritt: kein Boden unter %s nach %d s", E.PawnName, J.GROUND_FOR)
            end
        end
    end
    if E.ReadyAsked and (not E.GroundUntil or E.Timeout) then
        -- CORE-6 (srv_auth_gate in server.lua, Srv.AuthWait): Passwort-Server geben erst nach "auth" frei. Bis dahin bleibt
        -- die Figur eingefroren und unverwundbar (unten), auch nach dem Zeitlimit; AuthTick kickt nach Ablauf der Frist.
        if not J.AuthWait(Key) then
            return J.Release(E, E.Timeout and string.format("Zeitlimit %d s", J.HOST_TIMEOUT) or "ready")
        end
        if not E.AuthLogged then E.AuthLogged = true Log("Beitritt: Figur %s wartet auf das Server-Passwort", E.PawnName) end
    end
    if Safe(function() return Pawn.bCanBeDamaged end, false) then pcall(function() Pawn.bCanBeDamaged = false end) end
    -- Das Spiel gibt neue Figuren nach ~10 s selbst frei: bis ready wieder einfrieren
    if Safe(function() local Move = Pawn.CharacterMovement return IsAlive(Move) and Move.MovementMode ~= 0 end, false) then
        J.Freeze(Pawn)
        if not E.Refrozen then
            E.Refrozen = true
            Log("Beitritt: Figur %s vor ready freigegeben (Spiel), wieder eingefroren", E.PawnName)
        end
    end
    if Now >= E.SendAt then J.SendSpawned(E) end
end

-- Host (Schnell-Loop)
function J.HostTick(Now, World)
    for Key, E in pairs(J) do
        if type(E) == "table" and E.State == "spawned" then
            if Now - E.PossessAt >= J.HOST_TIMEOUT then E.ReadyAsked, E.Timeout = true, true end
            local ok, err = pcall(J.HostStep, Key, E, Now, World)
            if not ok and E.State == "spawned" then
                E.Errors = (E.Errors or 0) + 1
                if E.Errors == 1 then Log("Beitritt %s: Fehler %s", E.PawnName, tostring(err)) end
                -- Fehler bis zum Zeitlimit: trotzdem freigeben, nie haengen bleiben (CORE-6: nicht ohne Passwort)
                if E.Timeout and not J.AuthWait(Key) then E.State = "ready" pcall(J.Release, E, "nach Fehlern") end
            end
        end
    end
end

-- Mitspieler: Ladebildschirm halten? (CloseMenus, InputWatch, U.OwnPawn, HandleClient)
function Coop.JoinLoading()
    local C = Coop.JoinC
    -- ls_player (respawn_v2): eigener Respawn-Ladebildschirm zaehlt wie der Beitritts-Ladebildschirm
    return (C ~= nil and (C.State == "wait" or C.State == "spawned")) or (Coop.Player ~= nil and Coop.Player.Loading())
end

function J.ClientReady(C, Why)
    C.State = "ready"
    Log("Beitritt bereit (%s) nach %.1f s: Ladebildschirm zu, melde ready", Why, os.clock() - C.T0)
    SetupClient()
    local ok, err = pcall(Coop.SendChunked, Coop.SendToHost, "ready", "1")
    if not ok then Log("Beitritt: ready senden fehlgeschlagen: %s", tostring(err)) end
end

-- Mitspieler (Schnell-Loop): ready pruefen. Alter Host/Host ohne join_v2/lokales Inventar/Figur ohne "spawned" ->
-- wie bisher (aus). Zeitlimit, Tod oder Trennen im Laden -> ready erzwingen.
function J.ClientTick(Now)
    local C = Coop.JoinC
    if not C then return end
    if C.Ack then   -- "spawned" nach ready (oder doppelt): ready nochmal, der Host wartet sonst bis zum Zeitlimit
        C.Ack = nil
        pcall(Coop.SendChunked, Coop.SendToHost, "ready", "1")
    end
    if C.State ~= "wait" and C.State ~= "spawned" then return end
    if Now - C.T0 >= J.CLIENT_TIMEOUT then return J.ClientReady(C, string.format("Zeitlimit %d s", J.CLIENT_TIMEOUT)) end
    if Now < (C.CheckAt or 0) then return end
    C.CheckAt = Now + 0.25
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    local Own = IsAlive(Pawn) and Pawn:GetFName():ToString() or nil
    if C.State == "wait" then
        local Why = (Coop.HostProto == 1 and "alter Server")
            or (Coop.HostProto == 2 and not Coop.HostJoin and "Server ohne join_v2")
            or (Coop.InventoryMode == "local" and "lokales Inventar") or nil
        if Own then
            C.PawnAt = C.PawnAt or Now
            if not Why and Now - C.PawnAt >= J.NO_SPAWNED then Why = "Figur ohne spawned" end
        end
        if Why then
            C.State = "off"
            Log("Beitritt wie bisher (%s): Ladebildschirm zu", Why)
            if MenuClosed then SetupClient() end   -- sonst wie bisher 3 s nach dem Verbinden (HandleClient)
        end
        return
    end
    if not Own then
        -- Figur weg (Tod/Trennen im Laden): nicht haengen bleiben
        if C.PawnName then
            C.GoneAt = C.GoneAt or Now
            if Now - C.GoneAt >= J.GONE_FOR then J.ClientReady(C, "Figur weg") end
        end
        return
    end
    C.PawnName, C.GoneAt = C.PawnName or Own, nil
    if Own ~= C.PawnName then return J.ClientReady(C, "neue Figur") end
    if not (C.Synced and C.Target) then return end
    local L = Pawn:K2_GetActorLocation()
    if (L.X - C.Target.X) ^ 2 + (L.Y - C.Target.Y) ^ 2 > J.NEAR * J.NEAR then return end
    if not Coop.Ground(L, Pawn, 50) then return end   -- Boden unter der eigenen Kapsel geladen (Linie ab 50 cm darueber)
    local Hud = Safe(function() return Pawn.InGameUI end)   -- wie EnsureHud
    if not (Hud and IsAlive(Hud)) then return end
    J.ClientReady(C, "am Ziel")
end

-- Schnell-Loop (nur mit join_v2 eingetragen)
function J.Tick(Now, Mode, World)
    if Mode == "ListenServer" then J.HostTick(Now, World)
    elseif Mode == "Client" then J.ClientTick(Now) end
end

-- Mitspieler: "spawned|X|Y|Z" vom Host (im Empfangs-Hook: nur merken). Schon bereit/aus oder ohne join_v2: ready
-- gleich (nochmal) schicken, damit der Host nicht bis zu seinem Zeitlimit eingefroren wartet.
Coop.HostDataHandlers.spawned = function(Text)
    local X, Y, H = Text:match("^(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if not X then return end
    local C = Coop.JoinC
    if not C or C.State == "ready" or C.State == "off" then
        if C then
            C.Ack = true
        else
            ExecuteInGameThread(function() pcall(Coop.SendChunked, Coop.SendToHost, "ready", "1") end)
        end
        return
    end
    C.Target = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(H) }
    if C.State == "wait" then
        C.State = "spawned"
        Log("Beitritt: Figur steht am Ziel %s %s %s (Host), HUD und Abgleich hinter dem Ladebildschirm", X, Y, H)
    end
end

Coop.HostDataHandlers.synced = function()
    local C = Coop.JoinC
    if C and (C.State == "wait" or C.State == "spawned") and not C.Synced then
        C.Synced = true
        Log("Beitritt: Inventar abgeglichen (Host)")
    end
end
end

do
-- Tasten und Klicks im Spiel-Thread abfragen statt RegisterKeyBind: UE4SS fuehrt Tasten-Rueckrufe in einem eigenen
-- Thread aus. Jeder Linksklick (= Schuss; war fuer die Serverliste gebunden) und jede Taste (die Chat-Tasten-Aufnahme
-- band alle) liess Lua gleichzeitig mit den Hooks im Spiel-Thread laufen -> Lua-Zustand kaputt, Absturz (20.10. 05:47:
-- "No overload found for ExecuteInGameThread", im selben Stack ein Geraeusch-Hook des Spiel-Threads).
-- Zweite Schleife im Spiel-Thread (33 ms): Chat-Taste/Esc/F6 per IsInputKeyDown (Flanke), Senden = Eingabefeld verliert
-- den Fokus (Enter; Esc leert es vorher), Klick im Journal = einer unserer Knoepfe war gedrueckt und ist wieder los.
local I = { Down = {}, Pressed = {}, FKeys = {} }
Coop.Input = I
-- UE4SS-Tastennamen (chat_key.txt, Installer) -> FKey-Namen des Spiels
I.NAMES = { RETURN = "Enter", ESCAPE = "Escape", SPACE = "SpaceBar", TAB = "Tab", BACKSPACE = "BackSpace",
            CAPS_LOCK = "CapsLock", LEFT_SHIFT = "LeftShift", RIGHT_SHIFT = "RightShift", LEFT_CONTROL = "LeftControl",
            RIGHT_CONTROL = "RightControl", LEFT_ALT = "LeftAlt", RIGHT_ALT = "RightAlt", HOME = "Home", END = "End",
            INS = "Insert", DEL = "Delete", PAGE_UP = "PageUp", PAGE_DOWN = "PageDown", UP_ARROW = "Up",
            DOWN_ARROW = "Down", LEFT_ARROW = "Left", RIGHT_ARROW = "Right" }
do
    local Digits = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
    local Names = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
    for N = 1, 10 do I.NAMES[Digits[N]], I.NAMES["NUM_" .. Digits[N]] = Names[N], "NumPad" .. Names[N] end
    for C = string.byte("A"), string.byte("Z") do I.NAMES[string.char(C)] = string.char(C) end
    for N = 1, 12 do I.NAMES["F" .. N] = "F" .. N end
end

function I.IsDown(PC, Name)
    local FK = I.NAMES[Name]
    if not FK then return false end
    I.FKeys[Name] = I.FKeys[Name] or { KeyName = FName(FK) }
    return PC:IsInputKeyDown(I.FKeys[Name]) == true
end

-- true nur im Moment des Druckens (vorher los)
function I.Edge(Name, Now)
    local Was = I.Down[Name]
    I.Down[Name] = Now
    return Now and not Was
end

function I.PollButtons(L)
    local Released = false
    local function Check(B)
        if not IsAlive(B) then return end
        local Key, P = B:GetAddress(), B:IsPressed() == true
        if I.Pressed[Key] and not P then Released = true end
        I.Pressed[Key] = P
    end
    for _, Tab in pairs(L.Tabs) do Check(Tab.Button) end
    if L.Mode then
        for Row = 0, L.MAX_ROWS do
            for _, Cell in ipairs(L.Rows[Row] and L.Rows[Row].Cells or {}) do
                if Cell.Action then Check(Cell.Button) end
            end
        end
    end
    if Released then pcall(L.OnMouse) end
end

function I.Poll()
    if Coop.Server and Coop.PerfRates then return end   -- CORE-31: dedizierter Server hat keine Tastatur/Chat/Liste
    local PC = LocalPC()
    if not IsAlive(PC) then return end
    local C, L = Coop.Chat, Coop.List
    if L.Typing then
        if os.clock() - (L.TypingAt or 0) > 0.3 and (not IsAlive(L.Input) or not L.Input:HasKeyboardFocus()) then pcall(L.FinishTyping) end
        return
    end
    if L.Valid() and L.Journal:IsVisible() then
        I.PollButtons(L)
    elseif C.Capture then
        C.Capture = false   -- Journal zu: Tastenaufnahme abbrechen
    end
    if C.Capture then
        -- Tastenaufnahme (~75 Tasten je Abfrage): hoechstens alle 100 ms statt alle 33 ms
        local Now = os.clock()
        if Now < (I.CaptureAt or 0) then return end
        I.CaptureAt = Now + 0.1
        if I.Edge("ESCAPE", I.IsDown(PC, "ESCAPE")) then C.Capture = false pcall(L.Render) return end
        for Name in pairs(I.NAMES) do
            if Name ~= "ESCAPE" and I.Edge(Name, I.IsDown(PC, Name)) then pcall(C.OnKey, Name) return end
        end
        return
    end
    if C.Open then
        if os.clock() - (C.OpenedAt or 0) > 0.3 and C.Valid() and not C.Edit:HasKeyboardFocus() then
            pcall(C.OnEnter)
            I.Down[C.Key] = true   -- Chat-Taste (z. B. Enter) ist noch gedrueckt: erst nach dem Loslassen wieder oeffnen
        end
        return
    end
    if I.Edge(C.Key, I.IsDown(PC, C.Key)) then pcall(C.OpenInput) end
    -- F6: Steuerung von Hand neu einrichten (Notfall, falls die Maus doch gefangen bleibt) - nur auf einem Server
    if I.Edge("F6", I.IsDown(PC, "F6")) and (SETTINGS.dev or NetModeName(CurrentWorld()) == "Client") then pcall(SetupClient) end
end

LoopInGameThreadWithDelay(33, function()
    -- Solo noetig (Journal/Serverliste, Chat-Taste), aber nicht waehrend eine Karte laedt
    if WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60 then return end
    -- world_hygiene (CORE-8): erst nach Coop.DropWorldRefs (alte Widgets/Controller vergessen)
    if WorldGen.Dropped ~= WorldGen.N and WorldGen.Hygiene ~= false then return end
    local ok, err = pcall(I.Poll)
    if not ok and not I.Err then I.Err = true Log("Tasten-Fehler: %s", tostring(err)) end
end)
end

do
-- Schnell-Loop (100 ms) im Spiel-Thread fuer alles, wofuer die 1-s-Hauptschleife zu traege ist (Aufsaetze, Kleidung,
-- Join). Nur im Multiplayer (Solo bleibt unberuehrt). Aufgaben: Coop.AddFast(Name, Fn), Fn(Now, Modus, World) mit
-- Now = os.clock() (Zeitbasis hier immer os.clock); Rueckgabe true beendet die Aufgabe (Einmal-Aufgaben),
-- Coop.AddFast(Name, nil) entfernt sie. Fehler pro Aufgabe hoechstens alle 30 s im Log.
local F = { Tasks = {}, Order = {}, ErrAt = {} }
Coop.Fast = F

function Coop.AddFast(Name, Fn)
    if Fn and not F.Tasks[Name] then F.Order[#F.Order + 1] = Name end
    F.Tasks[Name] = Fn
end

-- world_hygiene (CORE-8): Schalter je Durchlauf in WorldGen.Hygiene spiegeln (LocalPC und die 33-ms-Schleifen lesen ihn
-- dort; LocalPC steht vor Coop). true = neuer Weg.
function Coop.Hygiene()
    local On = Coop.FlagOn("world_hygiene", true)
    WorldGen.Hygiene = On
    return On
end

-- world_hygiene: Tabelle an Ort und Stelle leeren (Module halten Verweise darauf, z. B. A.RemoteSeen/A.SpawnedPawns)
function Coop.ClearTable(T)
    if type(T) ~= "table" then return end
    local Keys = {}
    for K in pairs(T) do Keys[#Keys + 1] = K end
    for _, K in ipairs(Keys) do T[K] = nil end
end

-- world_hygiene (CORE-8 d): alle Verweise der alten Welt (Spielobjekte, Adressen, Widgets) vergessen, nur Tabellen
function Coop.DropWorldRefsHygiene()
    pcall(Coop.ClientWorldReset)   -- Mitspieler-Zustand (Kollision, Geister, HUD-Pruefung, Figur), sonst erst beim Trennen
    local C = Coop.Car
    if C then
        C.Resume, C.Looking, C.Driving, C.SavedMove, C.PassengerOf, C.LocalAddr, C.Pawns = nil, nil, nil, nil, nil, nil, nil
        C.PassengerSet, C.Confirmed, C.SeatAt, C.VList, C.SyncFor = nil, false, nil, nil, nil
        for _, Name in ipairs({ "Drivers", "Passengers", "Mail", "MailAt", "Seats", "SeatCheck", "NoColl", "HeldOpen" }) do
            if type(C[Name]) == "table" then Coop.ClearTable(C[Name]) end
        end
    end
    if Coop.List then pcall(Coop.List.Forget, true) end
    local Ch = Coop.Chat
    if Ch then Ch.Hud, Ch.Box, Ch.Edit, Ch.EditBox, Ch.Lines, Ch.Shown = nil, nil, nil, nil, {}, nil end
    if Coop.Shot then Coop.Shot.ServerShots, Coop.Shot.LastSound, Coop.Shot.FxQ = {}, {}, {} end
    Coop.WVisQ = {}
    local Z = Coop.Zombies
    if Z then
        Z.Montages, Z.ZombieClass, Z.Ignoring, Z.AudioClass = {}, nil, {}, nil
        if Z.LOOK then Z.LOOK.Assets, Z.LOOK.Pending = {}, {} end
        Z.Extra, Z.Pool = {}, nil
    end
    Coop.CharList = nil
    Coop.ClearTable(Coop.Logout)      -- PLAYER-13: stehengebliebene Figuren der alten Welt
    Coop.ClearTable(Coop.TrustSkip)   -- PLAYER-16
    Coop.ClearTable(Coop.CdoCache)    -- CORE-20: keine Objekte ueber den Weltwechsel
    Coop.ClearTable(Coop.ScanCache)   -- CORE-31 (E30)
    Coop.SaveCache = nil              -- CORE-31: Save_Player des Gasts
    -- Host (Listen-Host-Fall; der Server wechselt die Welt nur beim Start): Mitspieler-Tabellen der alten Welt
    Coop.ClearTable(RemoteSeen)
    Coop.ClearTable(SpawnTried)
    Coop.ClearTable(SpawnedPawns)
    Coop.ClearTable(DeadSince)
    if Coop.Join then
        local Gone = {}
        for K, E in pairs(Coop.Join) do if type(E) == "table" and E.PawnName then Gone[#Gone + 1] = K end end
        for _, K in ipairs(Gone) do Coop.Join[K] = nil end
    end
end

-- Weltwechsel: alle gemerkten Spielobjekte vergessen (nur Lua-Tabellen, keine UFunction). Siehe WorldGen oben.
function Coop.DropWorldRefs()
    if Coop.Hygiene() then
        local okH, errH = pcall(Coop.DropWorldRefsHygiene)
        if not okH then Coop.FlagFail("world_hygiene", errH) end
    end
    if Coop.AttachFix then Coop.AttachFix.W = {} end
    if Coop.Consume then Coop.Consume.Own, Coop.Consume.Queue = nil, {} end
    if Coop.InvRec then Coop.InvRec.Reset() end   -- nur Namen/Zahlen, aber je Welt neu
    if Coop.ClothFast then Coop.ClothFast.Pawns = {} end
    if Coop.ForgetHostDead then Coop.ForgetHostDead() end
    if Coop.ForgetSaveBack then Coop.ForgetSaveBack(nil) end   -- OutQueue haelt Controller der alten Welt (PumpQueues/IsAlive)
    if Coop.Zombies and Coop.Zombies.Reset then Coop.Zombies.Reset() end
    -- Hook-Warteschlangen (halten Spielobjekte bis zum naechsten Schnell-Loop)
    if Coop.Zombies and Coop.Zombies.MonQ then Coop.Zombies.MonQ = {} end
    if Coop.Shot then Coop.Shot.SoundQ, Coop.Shot.OwnAddr, Coop.Shot.OwnPC = {}, nil, nil end
    Coop.DeathQ = {}
    if Coop.ResetCorpses then Coop.ResetCorpses() end
    if Coop.SpawnerStop and Coop.SpawnerStop.Reset then Coop.SpawnerStop.Reset() end
    Coop.JoinC, Coop.HostJoin = nil, nil
    for Name in pairs(F.Tasks) do
        if Name:find("^probe") then F.Tasks[Name] = nil end   -- Einmal-Aufgaben der Probes halten Objekte
    end
end

function F.Tick()
    if WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60 then return end   -- Karte laedt gerade
    if WorldGen.Dropped ~= WorldGen.N then   -- einmal je Welt (Schnell-Loop oder Hauptschleife, wer zuerst kommt)
        WorldGen.Dropped = WorldGen.N
        local ok, err = pcall(Coop.DropWorldRefs)
        if not ok then Log("Weltwechsel-Fehler: %s", tostring(err)) end
    end
    if not MultiplayerActive or #F.Order == 0 then return end
    local Now, World = os.clock(), CurrentWorld()
    if not IsAlive(World) then return end
    local Mode, Seen = NetModeName(World), {}
    for _, Name in ipairs(F.Order) do   -- waehrend des Durchlaufs neu eingetragene Aufgaben laufen gleich mit
        local Fn = F.Tasks[Name]
        if Fn and not Seen[Name] then
            Seen[Name] = true
            local ok, Done = pcall(Fn, Now, Mode, World)
            if not ok then
                if not F.ErrAt[Name] or Now - F.ErrAt[Name] >= 30 then
                    F.ErrAt[Name] = Now
                    Log("Schnell-Loop %s: %s", Name, tostring(Done))
                end
            elseif Done == true and F.Tasks[Name] == Fn then
                F.Tasks[Name] = nil   -- nur entfernen, wenn sie sich nicht selbst neu eingetragen hat
            end
        end
    end
    local Keep = {}
    for _, Name in ipairs(F.Order) do
        if F.Tasks[Name] and Seen[Name] ~= 0 then Seen[Name] = 0 Keep[#Keep + 1] = Name end
    end
    F.Order = Keep
end

LoopInGameThreadWithDelay(100, function()
    local ok, err = pcall(F.Tick)
    if not ok and not F.Err then F.Err = true Log("Schnell-Loop-Fehler: %s", tostring(err)) end
end)

-- WP0: alte Nachrichten aus den Empfangs-Hooks abarbeiten (siehe Coop.Inbox oben). Controller frisch je Durchlauf.
function Coop.Inbox.Tick(Now, Mode, World)
    local IB = Coop.Inbox
    -- CORE-27 (perf_hotpath): KeyAt auch beim Gast setzen - die 33-ms-Schleife ruht dann bei leerer Warteschlange bis KeyAt
    -- (vorher beim Gast 30x/s CurrentWorld + NetModeName ohne Arbeit)
    local Hot = Coop.ModeOn == true
    if (Mode ~= "Client" or Hot) and Now >= (IB.KeyAt or 0) then   -- eigener Controller (Geist) fuer den Hook, 1x pro Sekunde
        IB.KeyAt = Now + 1
        if Mode ~= "Client" then
            local Own = LocalPC()
            IB.LocalKey = IsAlive(Own) and Safe(function() return Own:GetFullName() end) or nil
        end
    end
    if IB.Dropped > 0 then
        Log("Empfangs-Warteschlange voll: %d Nachrichten verworfen%s", IB.Dropped,
            IB.Flood and (" (Mitspieler-Limit: " .. tostring(IB.Flood) .. ")") or "")
        IB.Dropped, IB.Flood = 0, nil
    end
    if Now >= IB.PruneAt then   -- Eimer getrennter Mitspieler vergessen
        IB.PruneAt = Now + 60
        for K, B in pairs(IB.Rate) do if Now - B.T > 60 and not IB.PerKey[K] then IB.Rate[K] = nil end end
    end
    if IB.Head > IB.Tail then return end
    local Start, Done, PCs = os.clock(), 0, nil
    while IB.Head <= IB.Tail and Done < 30 and (Done == 0 or os.clock() - Start < 0.004) do
        local E = IB.Q[IB.Head]
        IB.Q[IB.Head], IB.Head, Done = nil, IB.Head + 1, Done + 1
        local Left = (IB.PerKey[E.K] or 1) - 1
        IB.PerKey[E.K] = Left > 0 and Left or nil
        if E.N ~= WorldGen.N then
            IB.Stale = (IB.Stale or 0) + 1   -- vor einem Weltwechsel empfangen (Trennen/Neuverbinden): verwerfen
        elseif E.K == "host" then
            local ok, err = pcall(IB.Host, E.T)
            if not ok then Log("Host-Nachricht fehlerhaft: %s", tostring(err)) end
        elseif IB.Client then
            if not PCs then
                PCs = {}
                for _, PS in ipairs(PlayerStates(World)) do
                    local PC = Safe(function() return PS:GetOwner() end)
                    local K = IsAlive(PC) and Safe(function() return not PC:IsLocalController() and PC:GetFullName() end)
                    if K then PCs[K] = PC end
                end
            end
            local PC = PCs[E.K]
            if PC then
                local ok, err = pcall(IB.Client, PC, E.T)
                if not ok then Log("Mitspieler-Nachricht fehlerhaft: %s", tostring(err)) end
            end
        end
    end
    if IB.Head > IB.Tail then IB.Q, IB.Head, IB.Tail, IB.PerKey = {}, 1, 0, {} end
    if IB.Stale then Log("Empfangs-Warteschlange: %d Nachrichten aus der vorigen Welt verworfen", IB.Stale) IB.Stale = nil end
end
-- Eigene 33-ms-Schleife statt Schnell-Loop: Fahrzeug-Lagen kommen mit bis zu 30/s (car_hz), im 100-ms-Takt
-- kaemen sie nur gebuendelt an. Leer kostet sie nichts (keine Spielfunktion). Nicht waehrend des Ladens und erst,
-- wenn die Objekte der alten Welt vergessen sind (Coop.DropWorldRefs).
LoopInGameThreadWithDelay(33, function()
    local IB = Coop.Inbox
    if not MultiplayerActive or (WorldGen.Loading and os.clock() - WorldGen.LoadingAt < 60) then return end
    if WorldGen.Dropped ~= WorldGen.N then return end
    if IB.Head > IB.Tail and IB.Dropped == 0 and os.clock() < (IB.KeyAt or 0) then return end
    local World = CurrentWorld()
    if not IsAlive(World) then return end
    local ok, err = pcall(IB.Tick, os.clock(), NetModeName(World), World)
    if not ok and not IB.Err then IB.Err = true Log("Empfangs-Schleife-Fehler: %s", tostring(err)) end
end)

-- Feste Aufgaben: Kleidung nachschicken (Host, Coop.ClothFast), Waffenaufsaetze (Mitspieler, nur attach_v2),
-- Beitritt am Ziel (Host und Mitspieler, nur join_v2), Verbrauch melden (Mitspieler, nur consume_fix; der Hook
-- entsteht erst im ersten Durchlauf)
Coop.AddFast("cloth", Coop.ClothFast.Tick)
if SETTINGS.attach_v2 then Coop.AddFast("attach", Coop.AttachFix.Tick) end
if SETTINGS.join_v2 then Coop.AddFast("join", Coop.Join.Tick) end
if SETTINGS.consume_fix then Coop.AddFast("consume", Coop.Consume.Tick) end
end

-- Mappings fuer die Blueprint-Analyse (wie Strg+Num 6, aber ohne Ziffernblock).
if SETTINGS.dev then
RegisterKeyBind(Key.F5, function()
    Log("Erzeuge Mappings.usmap ...")
    DumpUSMAP()
    Log("Mappings.usmap fertig")
end)
end

-- Teststeuerung ohne Tastendruck: Jede Instanz liest test_cmd.txt im Mod-Ordner, leert die Datei
-- und fuehrt die Zeilen aus. So laesst sich ein Koop-Test (Host + zweite Instanz als Mitspieler)
-- komplett von aussen steuern. Ergebnisse landen mit "[Test]" im UE4SS-Log.
local TEST_FILE = MOD_DIR .. "test_cmd.txt"
local Walk = nil

local function TestLog(fmt, ...) Log("[Test] " .. fmt, ...) end

local function OwnPawn()
    local Pawn = Safe(function() local P = LocalPC() return IsAlive(P) and P:K2_GetPawn() or nil end)
    return IsAlive(Pawn) and Pawn or nil
end

local function RemotePawns(World)
    local Pawns = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Pawn = PC:K2_GetPawn()
            if IsAlive(Pawn) then Pawns[#Pawns + 1] = Pawn end
        end
    end
    return Pawns
end

-- Laeuft ein paar Sekunden vorwaerts und misst, wie oft die Figur zurueckspringt (Server-Korrektur).
local function StartWalk(Seconds, Sprint)
    local Pawn = OwnPawn()
    if not Pawn then TestLog("walk: keine eigene Figur") return end
    if Sprint then pcall(function() Pawn:ToggleSprint(true) end) end
    local Start = Pawn:K2_GetActorLocation()
    Walk = { Pawn = Pawn, Until = os.clock() + Seconds, Last = Start, Start = Start, Ticks = 0,
             Backwards = 0, MaxStep = 0, Sprint = Sprint, Forward = Pawn:GetActorForwardVector() }
    TestLog("walk: %d s%s gestartet", Seconds, Sprint and " (Sprint)" or "")
    Coop.StartWalkLoop()
end

local function WalkTick()
    if not Walk then return end
    local Pawn = Walk.Pawn
    if not IsAlive(Pawn) then TestLog("walk: Figur weg") Walk = nil return end
    if os.clock() >= Walk.Until then
        local Loc = Pawn:K2_GetActorLocation()
        local Dist = math.sqrt((Loc.X - Walk.Start.X) ^ 2 + (Loc.Y - Walk.Start.Y) ^ 2)
        TestLog("walk fertig: %.0f cm in %d Ticks, Rueckspruenge=%d, groesster Schritt=%.0f cm, Tempo=%s",
            Dist, Walk.Ticks, Walk.Backwards, Walk.MaxStep,
            tostring(Safe(function() local Move = Pawn.CharacterMovement return IsAlive(Move) and Move.MaxWalkSpeed or nil end)))
        if Walk.Sprint then pcall(function() Pawn:ToggleSprint(false) end) end
        Walk = nil
        return
    end
    -- bForce: auch wenn das Fenster im Hintergrund ist und das Spiel Bewegungseingaben ignoriert
    Pawn:AddMovementInput(Walk.Forward, 1.0, true)
    local Loc = Pawn:K2_GetActorLocation()
    local DX, DY = Loc.X - Walk.Last.X, Loc.Y - Walk.Last.Y
    local Along = DX * Walk.Forward.X + DY * Walk.Forward.Y
    local Step = math.sqrt(DX * DX + DY * DY)
    if Along < -5 then Walk.Backwards = Walk.Backwards + 1 end
    if Step > Walk.MaxStep then Walk.MaxStep = Step end
    Walk.Ticks = Walk.Ticks + 1
    Walk.Last = Loc
end

-- Nur waehrend eines walk-Tests laufen lassen: Lua in UE4SS ist nicht threadsicher, eine dauernd
-- laufende 60-Hz-Schleife im Hintergrund kollidierte mit den Hooks im Spiel-Thread (Abstuerze).
-- Im Spiel-Thread (LoopInGameThreadWithDelay): LoopAsync lief in einem eigenen Thread und zerstoerte im Test 22.10. den
-- Lua-Zustand ("Ref was not function", Absturz des Clients). true beendet die Schleife.
Coop.StartWalkLoop = function()
    if Coop.WalkLoopOn then return end
    Coop.WalkLoopOn = true
    LoopInGameThreadWithDelay(16, function()
        if not Walk then Coop.WalkLoopOn = false return true end
        pcall(WalkTick)
        return false
    end)
end

-- Bewegungs-Messung (gegen Mikroruckler): haengt sich an das Tick-Ereignis der Spielerfigur und
-- schreibt fuer die eigene Figur jeden Frame Zeit, Position, Geschwindigkeit, Lauftempo und
-- Bewegungsmodus mit. F4 startet/stoppt, Ergebnis in track.csv und als Zusammenfassung im Log.
local TICK_FUNCTION = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:ReceiveTick"
-- Netzwerk-Antworten der Bewegungskomponente mitzaehlen (Bestaetigung vs. Korrektur). Nur
-- beobachten, nichts veraendern. Erst bei der ersten Messung registriert.
local MOVE_RPCS = { "ClientAckGoodMove", "ClientAdjustPosition", "ClientVeryShortAdjustPosition",
    "ClientMoveResponsePacked", "ClientAdjustRootMotionPosition", "ClientAdjustRootMotionSourcePosition" }
local Track, TrackHook = nil, nil

local function SummarizeTrack(Samples)
    local Frames, DtSum, DtMax, Moving, Uneven, Backwards, SpeedChanges, ModeChanges = #Samples, 0, 0, 0, 0, 0, 0, 0
    for i, S in ipairs(Samples) do
        DtSum = DtSum + S.dt
        if S.dt > DtMax then DtMax = S.dt end
        local P = Samples[i - 1]
        if P then
            if S.speed ~= P.speed then SpeedChanges = SpeedChanges + 1 end
            if S.mode ~= P.mode then ModeChanges = ModeChanges + 1 end
            if P.v > 50 and S.v > 50 then
                Moving = Moving + 1
                local DX, DY = S.x - P.x, S.y - P.y
                local Step, Expected = math.sqrt(DX * DX + DY * DY), P.v * S.dt
                if Step < Expected * 0.5 or Step > Expected * 1.5 then Uneven = Uneven + 1 end
                if DX * P.vx + DY * P.vy < 0 then Backwards = Backwards + 1 end
            end
        end
    end
    local Avg = Frames > 0 and DtSum / Frames or 0
    local Hitches = 0
    for _, S in ipairs(Samples) do if S.dt > Avg * 2 then Hitches = Hitches + 1 end end
    return string.format("%d Frames, %.1f fps, laengster Frame %.0f ms, %d Frame-Haenger; beim Laufen %d Frames: %d ungleichmaessige Schritte, %d Rueckspruenge; Tempo %d-mal geaendert, Modus %d-mal",
        Frames, Avg > 0 and 1 / Avg or 0, DtMax * 1000, Hitches, Moving, Uneven, Backwards, SpeedChanges, ModeChanges)
end

local function StopTrack()
    if not Track then return end
    local Samples, Counts, FileName = Track.Samples, Track.Counts, Track.FileName
    -- Der Tick-Hook bleibt registriert (ohne Messung kehrt er sofort zurueck): Hooks zur Laufzeit
    -- wieder zu entfernen hat den Client abstuerzen lassen ("Ref was not function").
    Track = nil
    local File = io.open(MOD_DIR .. FileName, "w")
    if File then
        File:write("t;dt;x;y;z;v;speed;mode;acks\n")
        for _, S in ipairs(Samples) do
            File:write(string.format("%.4f;%.4f;%.1f;%.1f;%.1f;%.0f;%.0f;%s;%d\n", S.t, S.dt, S.x, S.y, S.z, S.v, S.speed, tostring(S.mode), S.acks))
        end
        File:close()
    end
    local RpcParts = {}
    for _, Name in ipairs(MOVE_RPCS) do
        if Counts[Name] then RpcParts[#RpcParts + 1] = Name .. "=" .. Counts[Name] end
    end
    TestLog("Messung: %s; Netz-Antworten: %s", SummarizeTrack(Samples),
        #RpcParts > 0 and table.concat(RpcParts, ", ") or "keine gezaehlt")
end

local MoveRpcHooksDone = false

local function RegisterMoveRpcCounters()
    if MoveRpcHooksDone then return end
    MoveRpcHooksDone = true
    for _, Name in ipairs(MOVE_RPCS) do
        TryHook("/Script/Engine.Character:" .. Name, function()
            if Track then Track.Counts[Name], Track.Rpcs = (Track.Counts[Name] or 0) + 1, Track.Rpcs + 1 end
        end)
    end
end

-- Pawn/FileName nur fuer "trackremote": der Host misst seine Kopie der Mitspieler-Figur.
local function StartTrack(Seconds, Walk, Pawn, FileName)
    Pawn = Pawn or OwnPawn()
    if not Pawn then TestLog("Messung: keine Figur") return end
    RegisterMoveRpcCounters()
    Track = { Pawn = Pawn:GetFName():ToString(), Samples = {}, Counts = {}, Rpcs = 0,
              FileName = FileName or "track.csv", Until = Seconds and os.clock() + Seconds or nil }
    -- Automatisch laufen: Eingabe in jedem Frame (im Tick), zur Haelfte umdrehen gegen Waende.
    if Walk and Seconds then
        Track.Walk, Track.Forward, Track.TurnAt = true, Pawn:GetActorForwardVector(), os.clock() + Seconds / 2
    end
    if not TrackHook then
        TrackHook = TryHook(TICK_FUNCTION, function(Context, DeltaSeconds)
            if not Track then return end
            local P = Context:get()
            if P:GetFName():ToString() ~= Track.Pawn then return end
            if Track.Walk then
                if Track.TurnAt and os.clock() >= Track.TurnAt then
                    local F = Track.Forward
                    Track.Forward, Track.TurnAt = { X = -F.X, Y = -F.Y, Z = 0 }, nil
                end
                P:AddMovementInput(Track.Forward, 1.0, true)
            end
            local L, V, M = P:K2_GetActorLocation(), P:GetVelocity(), P.CharacterMovement
            if not IsAlive(M) then return end
            Track.Samples[#Track.Samples + 1] = {
                t = os.clock(), dt = DeltaSeconds:get(), x = L.X, y = L.Y, z = L.Z,
                v = math.sqrt(V.X * V.X + V.Y * V.Y), vx = V.X, vy = V.Y,
                speed = M.MaxWalkSpeed, mode = M.MovementMode, acks = Track.Rpcs,
            }
            -- Auswertung und Datei-Schreiben nicht mitten im Tick, sondern im naechsten Frame.
            if Track.Until and os.clock() >= Track.Until and not Track.Stopping then
                Track.Stopping = true
                ExecuteInGameThread(function() pcall(StopTrack) end)
            end
        end)
    end
    TestLog("Messung laeuft%s - jetzt laufen/sprinten (F4 stoppt)", Seconds and (" " .. Seconds .. " s") or "")
end

if SETTINGS.dev then
RegisterKeyBind(Key.F4, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function() if Track then StopTrack() else StartTrack(nil) end end)
        if not ok then TestLog("Messung-Fehler: %s", tostring(err)) end
    end)
end)
end

local TEST_COMMANDS = {
    track = function(Arg) StartTrack(tonumber(Arg) or 10) end,
    autowalk = function(Arg) StartTrack(tonumber(Arg) or 8, true) end,
    -- Lokaler Test (beide Instanzen teilen einen Spielstand): Mitspieler bekommt nur im Speicher ein
    -- anderes Aussehen und schickt es neu. Gespeichert wird beim Mitspieler im Koop nie.
    testlook = function()
        local Save = Coop.PlayerSave()
        Save.Sex = "Female"
        Save.SkinColor = Coop.LoadByPath("/Game/PlayerModel/Materials/1/M_Chr_Texture_1B.M_Chr_Texture_1B")   -- 5.6: Satz 4 entfernt
        Save.HairType = Coop.LoadByPath("/Game/PlayerModel/Hair/HairMesh/Chr_FemaleHair2.Chr_FemaleHair2")
        Save.HairColor = Coop.LoadByPath("/Game/PlayerModel/Hair/Material/Blonde/MI_CharacterHair_Blonde.MI_CharacterHair_Blonde")
        Save.MouthType = Coop.LoadByPath("/Game/PlayerModel/BodyParts/Head/Features/Female/Female_Mouth2.Female_Mouth2")
        OwnPawn():SetSexMesh()
        Coop.ResendAppearance()
        TestLog("Testaussehen gesetzt, wird neu geschickt")
    end,
    trackremote = function(Arg)
        StartTrack(tonumber(Arg) or 8, false, RemotePawns(CurrentWorld())[1], "track_remote.csv")
    end,
    -- Konsolenvariable setzen ("cvar p.NetUsePackedMovementRPCs 0") bzw. lesen ("cvar p.Name")
    cvar = function(Arg)
        local Name, Value = (Arg or ""):match("^(%S+)%s*(%S*)$")
        if not Name then TestLog("cvar: Name fehlt") return end
        local KSL = UEHelpers.GetKismetSystemLibrary()
        if Value ~= "" then KSL:ExecuteConsoleCommand(CurrentWorld(), Name .. " " .. Value, LocalPC()) end
        TestLog("cvar %s = %s", Name, tostring(Safe(function() return KSL:GetConsoleVariableIntValue(Name) end, "?")))
    end,
    host = function() StartHostMode() end,
    connect = function()   -- Test: direkt zu host_ip.txt (fuer Spieler gesperrt)
        local Join = rawget(_G, "LastSignalJoin") or {}
        Join.Direct = true
        rawset(_G, "LastSignalJoin", Join)
        ConnectToHost()
    end,
    diag = function() Diagnose() end,
    menu = function() SetupClient() end,
    walk = function(Arg) StartWalk(tonumber(Arg) or 5, false) end,
    sprint = function(Arg) StartWalk(tonumber(Arg) or 5, true) end,
    -- Host: Schaden an allen Mitspieler-Figuren (ueber das normale Schadenssystem des Spiels)
    -- CAR-1: immer mit echter Schadensart (nil als DamageType-Klasse liess UE4SS/den Server abstuerzen, server.lua)
    damage = function(Arg)
        local Dt = StaticFindObject("/Script/Engine.DamageType")
        if not IsAlive(Dt) then TestLog("damage: DamageType nicht gefunden - kein Schaden") return end
        for _, Pawn in ipairs(RemotePawns(CurrentWorld())) do
            if IsAlive(Pawn) then
                UEHelpers.GetGameplayStatics():ApplyDamage(Pawn, tonumber(Arg) or 10, nil, nil, Dt)
                TestLog("damage %s an %s", Arg or "10", Pawn:GetFName():ToString())
            end
        end
    end,
    -- Client: Respawn-Knopf des Spiels
    respawn = function() local P = LocalPC() if IsAlive(P) then P:Svr_RequestRespawn_Random() end TestLog("respawn angefragt") end,
    -- Beliebiger Lua-Code zum Debuggen, z. B. "lua return OwnPawn():GetFullName()"
    lua = function(Arg)
        local Chunk, Err = load(Arg, "test", "t", setmetatable({ OwnPawn = OwnPawn, LocalPC = LocalPC,
            CurrentWorld = CurrentWorld, RemotePawns = RemotePawns, Log = TestLog, Safe = Safe,
            IsAlive = IsAlive, UEHelpers = UEHelpers }, { __index = _G }))
        if not Chunk then TestLog("lua Fehler: %s", tostring(Err)) return end
        local ok, Result = pcall(Chunk)
        TestLog("lua -> %s", ok and tostring(Result) or ("Fehler: " .. tostring(Result)))
    end,
}

do
-- Proben fuer das Netcode-Paket (nur lesen, ausser "probe_attach fix|update" und "probe_spawners unreg").
-- Nachmessungen laufen als Einmal-Aufgabe im Schnell-Loop (nur im Multiplayer).
local Pr = { Dead = {}, SPAWNERS = { "BP_AISpawner_Master_C", "BP_AISpawner_Zombies_C", "BP_AISpawner_Animals_C",
    "BP_AISpawner_ZombieHounds_C", "BP_AISpawningVolume_RandomChanceToSpawn_C", "BP_AISpawningVolume_Prefab_C",
    "BP_Quest_Spawner_AI_C", "BP_AIManager_C", "BP_EventManager_C" }, FirearmClass = {} }   -- 5.6: Quest-Spawner statt HumanQuest-Volume

function Pr.Vec(V)
    return V and string.format("%.0f,%.0f,%.0f", V.X, V.Y, V.Z) or "?"
end

function Pr.Name(Object)
    return IsAlive(Object) and Object:GetFName():ToString() or "keins"
end

function Pr.Later(Name, Seconds, Fn)
    if not MultiplayerActive then TestLog("%s: Schnell-Loop laeuft nur im Multiplayer, Nachmessung entfaellt", Name) return end
    local At = os.clock() + Seconds
    Coop.AddFast(Name, function(Now)
        if Now < At then return end
        Coop.AddFast(Name, nil)            -- vor Fn austragen: auch bei einem Fehler nur einmal
        if Now - At < 30 then Fn(Now) end  -- nicht erst in einer spaeteren Sitzung (Loop ruht ohne Multiplayer)
    end)
end

-- Schusswaffe ueber die Klassen-Kette (wie die Munitions-Anzeige), nicht ueber einen Pfad
function Pr.IsFirearm(Actor)
    local Name = Actor:GetClass():GetFName():ToString()
    if Pr.FirearmClass[Name] == nil then
        local Found, C = false, Actor:GetClass()
        while C and C:IsValid() do
            if C:GetFName():ToString() == "BP_FirearmPickup_C" then Found = true break end
            C = C:GetSuperStruct()
        end
        Pr.FirearmClass[Name] = Found
    end
    return Pr.FirearmClass[Name]
end

-- Host: tote KI - Actor- gegen Mesh-Lage (liegt der Root bei 0,0,0?), Relevanz und ob IsDead? zurueckspringt (Pooling)
TEST_COMMANDS.probe_corpse = function()
    local N, Total, Back, Chars = 0, 0, {}, Coop.Characters()
    for _, Char in ipairs(Chars) do
        if IsAlive(Char) then
            local Name, Dead = Char:GetFName():ToString(), Coop.IsDeadAI(Char)
            if Pr.Dead[Name] and not Dead then Back[#Back + 1] = Name end
            if Dead then
                Pr.Dead[Name] = true
                Total = Total + 1
                if N < 10 then
                    N = N + 1
                    local Mesh = Safe(function() local M = Char.Mesh return IsAlive(M) and M or nil end)
                    TestLog("probe_corpse %s: Actor %s Mesh %s Root=%s MeshParent=%s IsDead?=%s bAlwaysRelevant=%s NetUpdateFrequency=%s",
                        Name, Pr.Vec(Safe(function() return Char:K2_GetActorLocation() end)),
                        Pr.Vec(Safe(function() return Mesh:K2_GetComponentLocation() end)),
                        Safe(function() return Pr.Name(Char:K2_GetRootComponent()) end, "?"),
                        Safe(function() return Pr.Name(Mesh:GetAttachParent()) end, "?"),
                        tostring(Safe(function() return Char["IsDead?"] end)),
                        tostring(Safe(function() return Char.bAlwaysRelevant end)),
                        tostring(Safe(function() return Char.NetUpdateFrequency end)))
                end
            end
        end
    end
    TestLog("probe_corpse: %d tote KI (max. 10 gezeigt), %d frueher tote wieder lebendig%s, Modus %s", Total, #Back,
        #Back > 0 and (" (" .. table.concat(Back, ", ", 1, math.min(#Back, 5)) .. ")") or "", NetModeName(CurrentWorld()))
end

-- Mitspieler: alle angehaengten Schusswaffen der eigenen Figur mit Socket und Aufsatz-Zaehlern (wie Coop.Scope).
-- "fix": bei Rep > Installed OnRep_RepAttachments + ProcessAttachments, "update": OnRep_RepAttachments +
-- UpdateAttachments; 1 s spaeter neu zaehlen.
TEST_COMMANDS.probe_attach = function(Arg)
    local Pawn, P = OwnPawn(), Coop.Scope
    if not Pawn then TestLog("probe_attach: keine eigene Figur") return end
    local Attached, Weapons, Fixed = {}, {}, {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local W = Entry:get()
        if IsAlive(W) and Safe(function() return Pr.IsFirearm(W) end, false) then Weapons[#Weapons + 1] = W end
    end
    local function Report(W, Tag)
        local J = P.Comp(W, "BP_JigPickupComponent_C")
        local Rep = J and Safe(function() return J.RepAttachments[P.ATTACH]:GetArrayNum() end, -1) or -1
        local Installed = J and Safe(function() return J.InstalledAttachments:GetArrayNum() end, -1) or -1
        local WC = P.Comp(W, "BP_WeaponsPickupComponent_C")
        TestLog("probe_attach%s %s: Socket %s, Rep %d, Installed %d, Visier %s, Daempfer %s, fehlt %s", Tag,
            W:GetFName():ToString(), Safe(function() return W:GetAttachParentSocketName():ToString() end, "?"), Rep,
            Installed, tostring(WC and Safe(function() return WC["SightAttached?"] end)),
            tostring(WC and Safe(function() return WC["SuppressorAttached?"] end)),
            J and Coop.AttachFix.Missing(J) or "?")
        return J, Rep, Installed
    end
    for _, W in ipairs(Weapons) do
        local J, Rep, Installed = Report(W, "")
        if J and (Arg == "fix" or Arg == "update") and Rep > Installed then
            local okRep, errRep = pcall(function() J:OnRep_RepAttachments() end)
            local okRun, errRun = pcall(function()
                if Arg == "fix" then J:ProcessAttachments() else J:UpdateAttachments() end
            end)
            TestLog("probe_attach %s: OnRep_RepAttachments %s, %s %s", W:GetFName():ToString(),
                okRep and "ok" or tostring(errRep), Arg == "fix" and "ProcessAttachments" or "UpdateAttachments",
                okRun and "ok" or tostring(errRun))
            Fixed[#Fixed + 1] = W
        end
    end
    TestLog("probe_attach: %d Schusswaffen an der Figur, %d nachgeholt (%s)", #Weapons, #Fixed, Arg or "nur lesen")
    if #Fixed > 0 then
        Pr.Later("probe_attach", 1, function()
            for _, W in ipairs(Fixed) do
                if IsAlive(W) then Report(W, " +1s") end
            end
        end)
    end
end

-- KI-Figuren zaehlen: vom Server repliziert (Role < 3) gegen lokal entstanden (Role 3 = Geister beim Mitspieler)
function Pr.CountAI()
    local Rep, Own = 0, 0
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Safe(function() return Char:GetClass():GetFName():ToString() ~= "BP_PlayerCharacter_C" end, false) then
            if Safe(function() return Char.Role end) == ROLE_AUTHORITY then Own = Own + 1 else Rep = Rep + 1 end
        end
    end
    return Rep, Own
end

-- Mitspieler: Spawner-Klassen (Anzahl, Rolle, repliziert, aus der Karte, gestoppt) und AI-Optimizer-Invoker.
-- "unreg": eigenen AIOInvoker abmelden (Coop.UnregisterInvoker, wie spawner_stop=1) und 10 s spaeter die KI neu zaehlen.
TEST_COMMANDS.probe_spawners = function(Arg)
    for _, Class in ipairs(Pr.SPAWNERS) do
        local List = FindAllOf(Class) or {}
        local Parts = {}
        for i = 1, math.min(3, #List) do
            local A = List[i]
            if IsAlive(A) then
                local Stopped = Safe(function() return A.IsSpawningStopped end)
                if type(Stopped) == "userdata" then Stopped = Safe(function() return A:IsSpawningStopped() end) end
                Parts[#Parts + 1] = string.format("%s role=%s rep=%s karte=%s gestoppt=%s", A:GetFName():ToString(),
                    tostring(Safe(function() return A.Role end)), tostring(Safe(function() return A.bReplicates end)),
                    tostring(WAS_LOADED and Safe(function() return A:HasAnyFlags(WAS_LOADED) end)), tostring(Stopped))
            end
        end
        TestLog("probe_spawners %s: %d%s", Class, #List, #Parts > 0 and (" [" .. table.concat(Parts, "; ") .. "]") or "")
    end
    local Pawn = OwnPawn()
    local Component = Pawn and Safe(function() return Pawn.AIOInvoker end)
    local Subsystem = FindFirstOf("AIOptimizerSubsystem")
    local function Invokers() return Safe(function() return IsAlive(Subsystem) and #Subsystem.Invokers or -1 end, -1) end
    local Rep, Own = Pr.CountAI()
    TestLog("probe_spawners: AIOptimizer %s, %d Invoker, eigener AIOInvoker %s, KI repliziert %d / lokal %d, Modus %s",
        IsAlive(Subsystem) and "da" or "fehlt", Invokers(), IsAlive(Component) and "gueltig" or "fehlt", Rep, Own,
        NetModeName(CurrentWorld()))
    if Arg == "unreg" and IsAlive(Component) and IsAlive(Subsystem) then
        local okUnreg, Result = pcall(Coop.UnregisterInvoker, Pawn)
        TestLog("probe_spawners unreg: %s", okUnreg and Result or ("Fehler " .. tostring(Result)))
        Pr.Later("probe_spawners", 10, function()
            local Rep2, Own2 = Pr.CountAI()
            TestLog("probe_spawners unreg +10s: Invoker %d, KI repliziert %d -> %d, lokal %d -> %d", Invokers(), Rep, Rep2, Own, Own2)
        end)
    end
end

-- Tiere als Character?, NetMode-Name, und ob os.clock unter Wine Wanduhrzeit liefert (10 s gegen os.time)
TEST_COMMANDS.probe_misc = function()
    local Animals = FindAllOf("BP_Animal_C") or {}
    local First, InCache = Animals[1], false
    if IsAlive(First) then
        for _, Char in ipairs(Coop.Characters()) do
            if IsAlive(Char) and Char:GetAddress() == First:GetAddress() then InCache = true break end
        end
    end
    TestLog("probe_misc: BP_Animal_C %d, erstes %s IsA(Character)=%s in Coop.Characters=%s, NetMode %s", #Animals,
        Pr.Name(First), tostring(IsAlive(First) and Safe(function() return First:IsA(CLASSES.Character) end)),
        tostring(InCache), NetModeName(CurrentWorld()))
    local Clock, Time = os.clock(), os.time()
    TestLog("probe_misc: os.clock %.3f, os.time %d", Clock, Time)
    Pr.Later("probe_misc", 10, function(Now)
        TestLog("probe_misc +10s: os.clock %+.2f s, os.time %+d s", Now - Clock, os.time() - Time)
    end)
end

-- Runde 3: Tiere im Umkreis von 100 m (Mitspieler: um die eigene Figur, Host/Server: um jede Gast-Figur) mit Klasse,
-- Name, Autoritaet, repliziert, aus der Karte, Abstand, Leben, IsDead?, Actor- und Mesh-Lage und (Mitspieler) der
-- gebundenen Id. Host zusaetzlich je Gast-Figur: AIPerceptionStimuliSource gueltig?, Bewegungsmodus, AIO-Invoker.
-- Hoechstens 12 Zeilen je Figur. Nur lesen.
function Pr.AnimalLoc(Char)
    local L = Safe(function() return Char:K2_GetActorLocation() end)
    if L and math.abs(L.X) + math.abs(L.Y) + math.abs(L.Z) > 1 then return L, "actor" end
    return Safe(function() local M = Char.Mesh return IsAlive(M) and M:K2_GetComponentLocation() or nil end) or L, "mesh"
end

TEST_COMMANDS.probe_animals = function()
    local World = CurrentWorld()
    local Mode = NetModeName(World)
    local Centers = Mode == "Client" and { OwnPawn() } or RemotePawns(World)
    if #Centers == 0 then TestLog("probe_animals: keine Figur (Modus %s)", Mode) return end
    local Animals = FindAllOf("BP_Animal_C") or {}
    local Z = Coop.Zombies
    for _, Pawn in ipairs(Centers) do
        local C = Pawn:K2_GetActorLocation()
        if Mode ~= "Client" then
            local Stim = Safe(function() return Pawn.AIPerceptionStimuliSource end)
            if not IsAlive(Stim) then
                Pr.StimClass = Pr.StimClass or StaticFindObject("/Script/AIModule.AIPerceptionStimuliSourceComponent")
                Stim = IsAlive(Pr.StimClass) and Safe(function() return Pawn:GetComponentByClass(Pr.StimClass) end) or nil
            end
            local Sub = FindFirstOf("AIOptimizerSubsystem")
            TestLog("probe_animals Gast %s: AIPerceptionStimuliSource %s, Bewegungsmodus %s, AIO-Invoker %s",
                Pawn:GetFName():ToString(), IsAlive(Stim) and "gueltig" or "FEHLT",
                tostring(Safe(function() local Move = Pawn.CharacterMovement return IsAlive(Move) and Move.MovementMode or nil end)),
                tostring(Safe(function() return IsAlive(Sub) and #Sub.Invokers or nil end)))
        end
        local Near, Local, Shown = 0, 0, 0
        for _, Char in ipairs(Animals) do
            if IsAlive(Char) then
                local L, From = Pr.AnimalLoc(Char)
                local D = L and math.sqrt((L.X - C.X) ^ 2 + (L.Y - C.Y) ^ 2 + (L.Z - C.Z) ^ 2) / 100 or math.huge
                if D <= 100 then
                    Near = Near + 1
                    local Auth = Safe(function() return Char:HasAuthority() end)
                    if Mode == "Client" and Auth then Local = Local + 1 end
                    if Shown < 12 then
                        Shown = Shown + 1
                        local Name = Char:GetFName():ToString()
                        local BoundId = Mode == "Client" and Z and Z.BoundBy and Z.BoundBy[Name] or nil
                        TestLog("probe_animals %s %s: Autoritaet %s, repliziert %s, Karte %s, %.0f m (%s), Leben %s, IsDead? %s, Actor %s, Mesh %s%s",
                            Safe(function() return Char:GetClass():GetFName():ToString() end, "?"), Name, tostring(Auth),
                            tostring(Safe(function() return Char.bReplicates end)),
                            tostring(WAS_LOADED and Safe(function() return Char:HasAnyFlags(WAS_LOADED) end)), D, From,
                            tostring(Safe(function() return Char.Health end)), tostring(Safe(function() return Char["IsDead?"] end)),
                            Pr.Vec(Safe(function() return Char:K2_GetActorLocation() end)),
                            Pr.Vec(Safe(function() local M = Char.Mesh return IsAlive(M) and M:K2_GetComponentLocation() or nil end)),
                            BoundId and (", gebunden an Id " .. tostring(BoundId)) or "")
                    end
                end
            end
        end
        TestLog("probe_animals um %s: %d Tiere <= 100 m%s (von %d insgesamt), Modus %s", Pawn:GetFName():ToString(), Near,
            Mode == "Client" and string.format(", davon %d lokal (Autoritaet)", Local) or "", #Animals, Mode)
    end
end

-- Runde 3: Ablage der Cheat-Gegenstaende beim Server umschalten (server.lua liest Coop.DropMode, sonst drop_mode)
TEST_COMMANDS.dropmode = function(Arg)
    local Names = { spawn = 0, adddrop = 1, game = 2 }
    local N = tonumber(Arg) or Names[(Arg or ""):lower()]
    if N ~= 0 and N ~= 1 and N ~= 2 then
        TestLog("dropmode <0|1|2> (spawn|adddrop|game), aktuell %s", tostring(Coop.DropMode or SETTINGS.drop_mode))
        return
    end
    Coop.DropMode = N
    TestLog("dropmode: Cheat-Gegenstaende jetzt per %d (%s)", N, ({ [0] = "spawn", "adddrop", "game" })[N])
end
end

local function RunTestCommands()
    local File = io.open(TEST_FILE, "r")
    if not File then return end
    local Content = File:read("*a")
    File:close()
    if not Content or Content:match("^%s*$") then return end
    File = io.open(TEST_FILE, "w")
    if File then File:close() end
    for Line in Content:gmatch("[^\r\n]+") do
        local Cmd, Arg = Line:match("^%s*(%S+)%s*(.-)%s*$")
        local Handler = Cmd and TEST_COMMANDS[Cmd]
        if Handler then
            TestLog("> %s", Line)
            local ok, err = pcall(Handler, Arg ~= "" and Arg or nil)
            if not ok then TestLog("%s Fehler: %s", Cmd, tostring(err)) end
        elseif Cmd then
            TestLog("unbekannter Befehl: %s", Cmd)
        end
    end
end

-- Test-Befehle laufen in der Hauptschleife unten mit (keine eigene Hintergrund-Schleife: Lua in UE4SS ist
-- nicht threadsicher, jede weitere Schleife erhoeht die Absturzgefahr).

-- Pause im Koop: Das Pausemenue haelt das Spiel an - auf dem Host friert das die Welt fuer alle
-- ein. Wie in normalen Multiplayer-Spielen laeuft die Welt weiter, nur das Menue bleibt offen.
-- Ausserdem hat das Pausemenue keinen Mehrfach-Schutz (zwei Menues beim Tod): Duplikate weg.
local PauseLogged = false

local function GuardPause(World)
    local Statics = UEHelpers.GetGameplayStatics()
    if not IsAlive(Statics) then return end   -- CORE-20
    -- CORE-31 (perf_rates): dedizierter Server hat kein Pausemenue (kein Spieler am Bildschirm) - nur alle 5 s die
    -- Spielpause aufheben, keine Suche nach PauseScreen_C
    if Coop.Server and Coop.PerfRates then
        local Now = os.clock()
        if Now < (Coop.PauseAt or 0) then return end
        Coop.PauseAt = Now + 5
        if Statics:IsGamePaused(World) then
            Statics:SetGamePaused(World, false)
            if not PauseLogged then Log("Koop: Spielpause aufgehoben (Welt laeuft fuer alle weiter)") end
            PauseLogged = true
        end
        return
    end
    if Statics:IsGamePaused(World) then
        Statics:SetGamePaused(World, false)
        if not PauseLogged then Log("Koop: Spielpause aufgehoben (Welt laeuft fuer alle weiter)") end
        PauseLogged = true
    end
    local Screens = {}
    for _, Widget in ipairs(FindAllOf("PauseScreen_C") or {}) do
        if IsAlive(Widget) and Widget:IsInViewport() then Screens[#Screens + 1] = Widget end
    end
    for i = 2, #Screens do
        Screens[i]:RemoveFromParent()
        Log("Doppeltes Pausemenue entfernt")
    end
end

-- log_quiet (CORE-24): Diagnose-Logs (Zustand, Verbindungen, Tempo) aus? dev=1 zeigt sie immer; Standard: auf dem
-- dedizierten Server aus, sonst an
function Coop.LogQuiet()
    if SETTINGS.dev then return false end
    return Coop.FlagOn("log_quiet", os.getenv("LASTSIGNAL_SERVER") == "1" or os.getenv("NETTEST_SERVER") == "1")
end

-- Schwere Diagnose (Objektsuche ueber alle Objekte) nur alle paar Sekunden, sonst ruckelt es.
local SLOW_EVERY = 5
local Tick = 0

-- Hauptschleife (1 s) direkt im Spiel-Thread. Frueher LoopAsync: dessen Rueckruf lief in einem eigenen Thread
-- und fuehrte dort Lua aus, gleichzeitig mit den Hooks im Spiel-Thread (Lua in UE4SS ist nicht threadsicher)
-- -> haeufige Abstuerze 0x8/0xffff... in UE4SS, v. a. bei vielen Hooks (Schiessen, Fahrzeug-Tick).
Coop.MainLoop = function()
        -- Haenger-Waechter: kam die Schleife > 5 s zu spaet, stand der Spiel-Thread (Server: alle froren ein)
        local NowClock = os.clock()
        if Coop.LoopAt and NowClock - Coop.LoopAt > 5 then
            Log("HAENGER: Spiel-Thread stand %.0f s (zuletzt: %s)", NowClock - Coop.LoopAt, tostring(Coop.LastStep))
        end
        Coop.LoopAt = NowClock
        if SETTINGS.dev or SETTINGS.test then pcall(RunTestCommands) end   -- Spieler: keine test_cmd.txt jede Sekunde
        Tick = Tick + 1
        Coop.ModeOn = Coop.FlagOn("perf_hotpath", true)   -- CORE-27: NetModeName-Merker (0,05 s je Welt)
        Coop.PerfRates = Coop.FlagOn("perf_rates", true)  -- CORE-31: seltenere Pruefungen (Pause, Eingabe, Menue-Level)
        -- world_hygiene (CORE-8): waehrend des Ladens nichts anfassen; nach einem Weltwechsel erst die alten Objekte
        -- vergessen, dann die Welt suchen (CurrentWorld nimmt den gemerkten Controller)
        if Coop.Hygiene() then
            if WorldGen.Loading and NowClock - WorldGen.LoadingAt < 60 then return end
            if WorldGen.Dropped ~= WorldGen.N and not WorldGen.Loading then
                WorldGen.Dropped = WorldGen.N
                local okDrop, errDrop = pcall(Coop.DropWorldRefs)
                if not okDrop then Log("Weltwechsel-Fehler: %s", tostring(errDrop)) end
            end
        end
        local World = CurrentWorld()
        if not IsAlive(World) then return end
        if WorldGen.Dropped ~= WorldGen.N and not WorldGen.Loading then   -- Weltwechsel: alte Objekte vergessen
            WorldGen.Dropped = WorldGen.N
            local okGen, errGen = pcall(Coop.DropWorldRefs)
            if not okGen then Log("Weltwechsel-Fehler: %s", tostring(errGen)) end
        end
        if Coop.Server then
            local okSrv, errSrv = pcall(Coop.Server.Tick, World)
            if not okSrv then Log("Server-Fehler: %s", tostring(errSrv)) end
        end
        local Online = NetModeName(World) ~= "Standalone"
        MultiplayerActive = Online
        local okPatch, errPatch = pcall(UpdateClientPatches, NetModeName(World) == "Client")
        if not okPatch then Log("Patch-Fehler: %s", tostring(errPatch)) end
        if NativeCoreLoaded then
            SetNativeCoreEnabled(Online)
        elseif Online then
            EnableRedirectHooks()
        else
            DisableRedirectHooks()
        end
        if Online and Tick % 30 == 0 and RedirectCount ~= RedirectLogged then
            Log("Multiplayer-Hook: %d Aufrufe auf den richtigen Spieler umgeleitet", RedirectCount)
            RedirectLogged = RedirectCount
        end
        -- Ohne Multiplayer nur jede Sekunde, solange ein Beitritt laeuft (Warten aufs Menue, Adresse aus der
        -- Serverliste noch offen, bis 60 s nach "open"); sonst wie online alle SLOW_EVERY s (Solo: 4x FindAllOf)
        local Join = rawget(_G, "LastSignalJoin")
        local Joining = PendingConnectSince ~= nil
            or (Join ~= nil and (Join.Address ~= nil or os.time() - (Join.OpenAt or 0) < 60))
        -- log_quiet (CORE-24/PLAYER-22): Zustand, Verbindungs-Beobachter und Tempo nur mit dev=1 oder log_quiet=0
        -- (Standard auf dem Server 1: sonst wuchs UE4SS.log bei 24/7-Betrieb um zig MB am Tag)
        local Quiet = Coop.LogQuiet()
        if not Quiet and (Tick % SLOW_EVERY == 0 or (not Online and Joining)) then
            local ok, State = pcall(NetState)
            if not ok then State = "Fehler: " .. tostring(State) end
            if State ~= LastState then
                Log("Zustand: %s", State)
                LastState = State
            end
            local okWatch, err = pcall(WatchConnections)
            if not okWatch then Log("Beobachter-Fehler: %s", tostring(err)) end
        end
        local okHome, errHome = pcall(Coop.Home.Tick, World, NetModeName(World))
        if not okHome and not Coop.Home.ErrLogged then Coop.Home.ErrLogged = true Log("Heimkehr-Fehler: %s", tostring(errHome)) end
        if not Coop.Server then
            local okList, errList = pcall(Coop.List.Tick)
            if not okList and not Coop.List.ErrLogged then Coop.List.ErrLogged = true Log("Serverlisten-Fehler: %s", tostring(errList)) end
            local okChat, errChat = pcall(Coop.Chat.Tick)
            if not okChat and not Coop.Chat.ErrLogged then Coop.Chat.ErrLogged = true Log("Chat-Fehler: %s", tostring(errChat)) end
            local okCheat, errCheat = pcall(Coop.Cheat.Tick)
            if not okCheat and not Coop.Cheat.ErrLogged then Coop.Cheat.ErrLogged = true Log("Cheat-Menue-Fehler: %s", tostring(errCheat)) end
            local okCar, errCar = pcall(Coop.Car.Tick)
            if not okCar and not Coop.Car.ErrLogged then Coop.Car.ErrLogged = true Log("Fahrzeug-Fehler: %s", tostring(errCar)) end
            local okPend, errPend = pcall(Coop.Pending.Tick)
            if not okPend and not Coop.Pending.ErrLogged then Coop.Pending.ErrLogged = true Log("Gegenstands-Fehler: %s", tostring(errPend)) end
            local okLoot, errLoot = pcall(Coop.Loot.ClientTick, World)
            if not okLoot and not Coop.Loot.ErrLogged then Coop.Loot.ErrLogged = true Log("Boden-Gegenstands-Fehler: %s", tostring(errLoot)) end
            local okScope, errScope = pcall(Coop.Scope.Tick)
            if not okScope and not Coop.Scope.ErrLogged then Coop.Scope.ErrLogged = true Log("Zielfernrohr-Fehler: %s", tostring(errScope)) end
        end
        if PendingConnectSince and not Online then
            if os.time() - PendingConnectSince > CONNECT_GIVE_UP then
                PendingConnectSince = nil
                Log("Verbinden abgebrochen: Menue wurde nicht bereit")
            else
                local okConnect, errConnect = pcall(ConnectToHost)
                if not okConnect then Log("Verbinden-Fehler: %s", tostring(errConnect)) PendingConnectSince = nil end
            end
        end
        if not Online then return end
        local okHooks, errHooks = pcall(RegisterCharacterHooks)
        if not okHooks then Log("Hook-Fehler: %s", tostring(errHooks)) end
        local okNoise, errNoise = pcall(Coop.HookNoise)   -- einmal, beim ersten Multiplayer (Solo ohne Hook)
        if not okNoise then Log("Geraeusch-Hook-Fehler: %s", tostring(errNoise)) end
        local okShot, errShot = pcall(Coop.Shot.Tick, World)
        if not okShot and not Coop.Shot.ErrLogged then Coop.Shot.ErrLogged = true Log("Schuss-Fehler: %s", tostring(errShot)) end
        local okInv, errInv = pcall(Coop.InvDiag.Tick)
        if not okInv and not Coop.InvDiag.ErrLogged then Coop.InvDiag.ErrLogged = true Log("Inventar-Diagnose-Fehler: %s", tostring(errInv)) end
        local okHealth, errHealth = true, nil   -- vit_v2: reine Diagnose nur ohne vit2 oder mit dev
        if not (Coop.VitV2Flag and Coop.VitV2Flag()) or SETTINGS.dev then okHealth, errHealth = pcall(LogHealth, World) end
        if not okHealth then Log("Leben-Fehler: %s", tostring(errHealth)) end
        if not Quiet then
            local okSpeed, errSpeed = pcall(LogSpeed, World)
            if not okSpeed then Log("Tempo-Fehler: %s", tostring(errSpeed)) end
        end
        local okHost, errHost = pcall(HandleRemotePlayers, World)
        if not okHost then Log("Mitspieler-Fehler: %s", tostring(errHost)) end
        local okTest, errTest = pcall(SelfTestRedirect, World)
        if not okTest then Log("Selbsttest-Fehler: %s", tostring(errTest)) end
        local okPause, errPause = pcall(GuardPause, World)
        if not okPause then Log("Pause-Fehler: %s", tostring(errPause)) end
        local okStats, errStats = pcall(SyncStats, World)
        if not okStats then Log("Statistik-Fehler: %s", tostring(errStats)) end
        local okStats2, errStats2 = pcall(Coop.RegisterWeaponStatHooks, World)
        if not okStats2 then Log("Waffenwerte-Hook-Fehler: %s", tostring(errStats2)) end
        local okBack, errBack = pcall(Coop.HandleSaveBack, World)
        if not okBack then Log("Zurueckschreiben-Fehler: %s", tostring(errBack)) end
        local okGuest, errGuest = pcall(Coop.HandleGuestInventory, World)
        if not okGuest then Log("Server-Inventar-Fehler: %s", tostring(errGuest)) end
        local okWake, errWake = pcall(Coop.WakeAINearGuests, World)
        if not okWake then Log("KI-Animations-Fehler: %s", tostring(errWake)) end
        local okHp, errHp = pcall(Coop.Zombies.HostTick, World)
        if not okHp then Log("Zombie-Leben-Fehler (Host): %s", tostring(errHp)) end
        local okSky, errSky = true, nil   -- ls_world (world_sky, alle Gaeste wld2): w_sky ersetzt den alten sky-Weg; gemischt: SkyHostTick filtert je Gast
        if not (Coop.Modules.ls_world and Coop.Modules.ls_world.Owns("sky")) then okSky, errSky = pcall(Coop.SkyHostTick, World) end
        if not okSky then Log("Himmel-Fehler (Host): %s", tostring(errSky)) end
        local okFreeze, errFreeze = pcall(Coop.UnfreezeSpawnedGuests, World)
        if not okFreeze then Log("Spawn-Freigabe-Fehler: %s", tostring(errFreeze)) end
        local okLootH, errLootH = pcall(Coop.Loot.HostTick, World)
        if not okLootH and not Coop.Loot.HostErr then Coop.Loot.HostErr = true Log("Boden-Gegenstands-Fehler (Host): %s", tostring(errLootH)) end
        local okCars, errCars = pcall(Coop.Car.HostTick, World)
        if not okCars and not Coop.Car.HostErr then Coop.Car.HostErr = true Log("Fahrzeug-Fehler (Host): %s", tostring(errCars)) end
        local okLook, errLook = pcall(Coop.HandleHostAppearance, World)
        if not okLook then Log("Aussehen-Fehler (Host): %s", tostring(errLook)) end
        local okLookC, errLookC = pcall(Coop.HandleClientAppearance, World)
        if not okLookC then Log("Aussehen-Fehler (Mitspieler): %s", tostring(errLookC)) end
        local okClient, errClient = pcall(HandleClient, World)
        if not okClient then Log("Client-Fehler: %s", tostring(errClient)) end
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(Coop.MainLoop)
        if not ok and not Coop.MainLoopErr then Coop.MainLoopErr = true Log("Hauptschleifen-Fehler: %s", tostring(err)) end
    end)
    Log("Hauptschleife im Spiel-Thread")
else
    LoopAsync(1000, function() ExecuteInGameThread(Coop.MainLoop) return false end)
    Log("Hauptschleife per LoopAsync (alte UE4SS-Version)")
end

ExecuteInGameThread(function()
    local okCore, errCore = pcall(LoadNativeCore)
    if not okCore then Log("LastSignalCore-Fehler: %s", tostring(errCore)) end
    ApplyNetDriverMode()
    if NetDriverMode == "ip" then
        local Active, Created = SteamNetworkingDisabledInIni()
        if Active then
            Log("Engine.ini: Steam-Networking aus, IP-Modus bereit.%s", Created and " (Config\\UserEngine.ini angelegt)" or "")
        elseif Created then
            Log("WARNUNG: Steam-Networking war noch an. Config\\UserEngine.ini ist jetzt angelegt - bitte das Spiel einmal neu starten, dann klappt der Beitritt per IP.")
        else
            Log("WARNUNG: IP-Modus, aber Steam-Networking ist noch an und Config\\UserEngine.ini ist nicht schreibbar. Installer nochmal ausfuehren.")
        end
    end
end)

-- Dedizierter Server (Linux/Pterodactyl, ohne Grafik): nur mit LASTSIGNAL_SERVER=1, siehe server.lua
-- (ohne neue locals: main.lua ist an Luas Grenze von 200)
Coop.ServerModule = { pcall(require, "server") }
if Coop.ServerModule[1] and type(Coop.ServerModule[2]) == "table" then
    Coop.Server = Coop.ServerModule[2].Init({ Log = Log, Safe = Safe, IsAlive = IsAlive, LocalPC = LocalPC,
        CurrentWorld = CurrentWorld, NetModeName = NetModeName, VisibleWidget = VisibleWidget,
        ReadyToTravel = ReadyToTravel, StartHostMode = StartHostMode, RunCommand = RunCommand,
        RaiseMaxPlayers = RaiseMaxPlayers, PlayerStates = PlayerStates, Settings = SETTINGS,
        Coop = Coop, TestCommands = TEST_COMMANDS, ModDir = MOD_DIR, UEHelpers = UEHelpers })
elseif not Coop.ServerModule[1] then
    Log("server.lua nicht geladen: %s", tostring(Coop.ServerModule[2]))
end

-- Runde 5: Module ls_*.lua der Reihe nach (M.Init(API), optional HostTick/ClientTick/Handlers).
-- Fehler werden geloggt und das Modul uebersprungen (ohne neue locals, alles in Coop).
Coop.API = { Log = Log, Safe = Safe, IsAlive = IsAlive, LocalPC = LocalPC, CurrentWorld = CurrentWorld,
    NetModeName = NetModeName, MapPath = MapPath, VisibleWidget = VisibleWidget, RunCommand = RunCommand,
    PlayerStates = PlayerStates, OwnPawn = OwnPawn, TestLog = TestLog, Settings = SETTINGS, Coop = Coop,
    TestCommands = TEST_COMMANDS, ModDir = MOD_DIR, ModRoot = ModRoot, UEHelpers = UEHelpers,
    -- Runde 5 (ls_net und Fachmodule), Vertrag: _NetTest\analysis\API.md
    TryHook = TryHook, ReadyToTravel = ReadyToTravel, StartHostMode = StartHostMode, RaiseMaxPlayers = RaiseMaxPlayers,
    WorldGen = WorldGen, MultiplayerActive = function() return MultiplayerActive end, RemotePawns = RemotePawns,
    MessagePrefix = MESSAGE_PREFIX, SendToClient = Coop.SendToClient, SendToHost = Coop.SendToHost,
    SendChunked = Coop.SendChunked, Encode = Coop.Encode, Decode = Coop.Decode, HostDataHandlers = Coop.HostDataHandlers,
    AddFast = Coop.AddFast, Characters = Coop.Characters, PlayerPawns = Coop.PlayerPawns, ShowNote = Coop.ShowNote,
    OwnGuestId = Coop.OwnGuestId, RemoteSeen = RemoteSeen, SpawnedPawns = SpawnedPawns,
    G = Coop.GuestInv, V = Coop.Stats, Z = Coop.Zombies, J = Coop.Join }
-- Fachmodule nach ls_net (Net.Cap/Net.On/Core.Every in Init); ls_player vor ls_inv (Respawn), ls_ui zuletzt
-- (ls_combat/ls_car nutzen Coop.Modules.ls_ui erst zur Laufzeit).
Coop.Modules, Coop.ModHandlers, Coop.ModuleOrder = {}, {}, { "ls_core", "ls_native", "ls_net", "ls_test", "ls_clan",
    "ls_player", "ls_inv", "ls_vit", "ls_ai", "ls_combat", "ls_build", "ls_wobj", "ls_car", "ls_world", "ls_ui" }
Coop.LoadModules = function()
    for _, Name in ipairs(Coop.ModuleOrder) do
        local ok, M = pcall(require, Name)
        local okInit, err = ok and type(M) == "table", M
        -- Felder, die ein Modul in Init auf Coop setzt (Coop.VitV2, Coop.AI2*, Coop.Player ...), schalten den alten
        -- Weg ab. Bricht Init ab, werden sie wieder entfernt: dann laeuft der alte Weg unveraendert weiter.
        -- Ebenso Aufgaben (Core.Every), Faehigkeiten (Net.Cap), Empfaenger (Net.On/Net.OnEvent) und Testbefehle, die
        -- Init vor dem Fehler schon eingetragen hat: Stand vorher merken, bei Fehler zuruecksetzen (sonst liefen die
        -- Aufgaben eines "nicht geladenen" Moduls weiter und doppelt mit dem alten Weg).
        local Before, Had = {}, {}
        for Field, Value in pairs(Coop) do Before[Field], Had[Field] = Value, true end
        local Core, Net = package.loaded["ls_core"], package.loaded["ls_net"]
        if type(Core) ~= "table" then Core = nil end
        if type(Net) ~= "table" then Net = nil end
        local Snap = { Tasks = {}, Caps = {}, Lists = {}, Handlers = {}, Tests = {} }
        if Core and Core.Tasks then for K, T in pairs(Core.Tasks) do Snap.Tasks[K] = T end end
        if Net and Net.LocalCaps then for K, V in pairs(Net.LocalCaps) do Snap.Caps[K] = V end end
        if Net and Net.Listeners then for K, L in pairs(Net.Listeners) do Snap.Lists[K] = #L end end
        if Net and Net.Handlers then for K, L in pairs(Net.Handlers) do Snap.Handlers[K] = #L end end
        for K in pairs(TEST_COMMANDS) do Snap.Tests[K] = true end
        if okInit and M.Init then okInit, err = pcall(M.Init, Coop.API) end
        if okInit then
            Coop.Modules[Name] = M
            for Kind, Fn in pairs(M.Handlers or {}) do Coop.ModHandlers[Kind] = Fn end
        else
            local Removed, Undone = {}, 0
            for Field in pairs(Coop) do if not Had[Field] then Removed[#Removed + 1] = Field end end
            for _, Field in ipairs(Removed) do Coop[Field] = nil end
            for Field, Value in pairs(Before) do
                if Coop[Field] ~= Value then Coop[Field] = Value Undone = Undone + 1 end   -- ueberschriebene Felder
            end
            pcall(function()
                if Core and Core.Tasks then
                    local New = {}
                    for K, T in pairs(Core.Tasks) do if Snap.Tasks[K] ~= T then New[#New + 1] = K end end
                    for _, K in ipairs(New) do
                        if Snap.Tasks[K] then Core.Tasks[K] = Snap.Tasks[K] else Core.Cancel(K) end
                        Undone = Undone + 1
                    end
                end
                if Net and Net.LocalCaps and Net.Cap then
                    local Diff = {}
                    for K in pairs(Net.LocalCaps) do if not Snap.Caps[K] then Diff[#Diff + 1] = { K, false } end end
                    for K in pairs(Snap.Caps) do if not Net.LocalCaps[K] then Diff[#Diff + 1] = { K, true } end end
                    for _, D in ipairs(Diff) do Net.Cap(D[1], D[2]) Undone = Undone + 1 end
                end
                for Tbl, Counts in pairs({ [Net and Net.Listeners or {}] = Snap.Lists, [Net and Net.Handlers or {}] = Snap.Handlers }) do
                    for K, L in pairs(Tbl) do
                        local Keep = Counts[K] or 0
                        while #L > Keep do L[#L] = nil Undone = Undone + 1 end
                        if #L == 0 and not Counts[K] then Tbl[K] = nil end
                    end
                end
            end)
            for K in pairs(TEST_COMMANDS) do if not Snap.Tests[K] then TEST_COMMANDS[K] = nil Undone = Undone + 1 end end
            Log("Modul %s nicht geladen: %s%s%s", Name, tostring(err),
                #Removed > 0 and (" (alter Weg bleibt, entfernt: " .. table.concat(Removed, ", ") .. ")") or "",
                Undone > 0 and string.format(" (%d Aufgaben/Faehigkeiten/Empfaenger zurueckgesetzt)", Undone) or "")
        end
    end
    if Coop.Modules.ls_core then pcall(Coop.Modules.ls_core.StartModuleTicks) end
end
Coop.LoadModules()

Log("geladen. Server beitreten: Journal (J) -> Server Liste")
