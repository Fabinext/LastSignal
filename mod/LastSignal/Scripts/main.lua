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
local function IsAlive(Object)
    -- Nur echte Unreal-Objekte (userdata); alles andere (z. B. beim Trennen eines Mitspielers) als tot werten
    if type(Object) ~= "userdata" then return false end
    local okValid, Valid = pcall(function() return Object:IsValid() end)
    if not okValid or not Valid then return false end
    local ok, Dying = pcall(function()
        return Object:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)
            or Object:HasAnyInternalFlags(EInternalObjectFlags.Unreachable)
    end)
    return ok and not Dying   -- Fehler bei der Pruefung: lieber als tot werten
end

local function Safe(fn, fallback)
    local ok, result = pcall(fn)
    if ok then return result end
    return fallback
end

-- Schalter fuer A/B-Tests ohne neuen Build: coop.txt im Mod-Ordner, Zeilen "name=0" oder "name=1".
--   trust_movement   Host uebernimmt die Position des Mitspielers (gegen Ruckeln)
--   replay_possessed Spieler-Einrichtung des Spiels beim Mitspieler nachholen
--   frame_walk       nativer Hook folgt der Blueprint-Aufrufkette (noetig fuer Respawn)
--   save_before_join Mitspieler speichert seinen Spielstand, bevor er beitritt
--   save_back        Mitspieler schreibt sein Inventar vom Host in seinen eigenen Spielstand
--                    (beides im lokalen Zwei-Instanzen-Test aus: beide teilen einen Spielstand)
--   local_inventory  nur beim Host: 1 = Mitspieler bringen ihr lokales Inventar mit und bekommen es
--                    zurueckgeschrieben (wie Valheim), 0 = Inventar bleibt auf dem Server (Standard)
--   dev              Entwickler-Tasten F4-F7 (Messung, USMAP, Client-Einrichtung, Diagnose); fuer Spieler aus
local SETTINGS = { trust_movement = true, replay_possessed = false, frame_walk = true,
                   save_before_join = true, save_back = true, local_inventory = false, dev = false }

local function LoadSettings()
    local File = io.open(MOD_DIR .. "coop.txt", "r")
    if not File then return end
    for Line in File:lines() do
        local Key, Value = Line:match("^%s*([%w_]+)%s*=%s*(%d)")
        if Key and SETTINGS[Key] ~= nil then SETTINGS[Key] = Value == "1" end
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

-- Im IP-Modus muss in der Engine.ini des Spielers [OnlineSubsystemSteam] bUseSteamNetworking=false
-- stehen (setzt der Installer), sonst lauscht der IpNetDriver ueber Steam-Sockets und scheitert.
local function SteamNetworkingDisabledInIni()
    local Path = (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\Config\\Windows\\Engine.ini"
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

local function GameNetDriverDefinition()
    local Defs = UEHelpers.GetEngine().NetDriverDefinitions
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

    local Players = UEHelpers.GetAllPlayers()
    Log("Spielfiguren in der Welt: %d", #Players)
    for i, P in ipairs(Players) do
        Log("  [%d] %s", i, P:GetFullName())
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

RegisterLoadMapPostHook(function(_, World)
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
        local ok, err = pcall(function() UEHelpers.GetPlayerController():SaveGameToSlot() end)
        Log("Speichere eigenen Spielstand vor dem Beitritt: %s", ok and "gestartet" or tostring(err))
        return false
    end
    local Busy = Safe(function() return EMS:IsSavingOrLoading(World) end, false)
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
    Parts[#Parts + 1] = "Figuren=" .. tostring(#UEHelpers.GetAllPlayers())
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
    if CachedPC and IsAlive(CachedPC) and Safe(function() return CachedPC:IsLocalController() end, false) then
        return CachedPC
    end
    -- UEHelpers nimmt den ersten PlayerController - auf dem Host kann das der des Mitspielers sein.
    for _, PC in ipairs(FindAllOf("PlayerController") or {}) do
        if IsAlive(PC) and Safe(function() return PC:IsLocalController() end, false) then
            CachedPC = PC
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
    local GameState = Safe(function() return World.GameState end)
    if not (GameState and IsAlive(GameState)) then return States end
    local Array = GameState.PlayerArray
    for i = 1, #Array do
        local PS = Array[i]
        if IsAlive(PS) then States[#States + 1] = PS end
    end
    return States
end

-- Host: SurrounDead erzeugt die Spielfigur nur beim Laden eines Spielstands, nie fuer Mitspieler.
-- Darum bekommt jeder fremde PlayerController ohne Figur eine Kopie der Host-Figur neben dem Host.
local SPAWN_DELAY = 3
local RemoteSeen, SpawnTried, SpawnedPawns, DeadSince = {}, {}, {}, {}
local RESPAWN_DELAY = 90  -- Notfall, falls der Respawn-Knopf des Spiels nicht greift

-- Wie das Spiel bei einem neuen Spiel: verzoegert spawnen, vor dem Construction Script
-- "SpawnStartingItems?" setzen, dann fertig spawnen. So vergibt das Spiel die Startausruestung
-- selbst auf dem Host (dort liegt das Inventar), statt dass wir sie nachtraeglich bauen.
local function SpawnWithStartingItems(World, Class, Loc, Yaw, Owner)
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
    pcall(function() Pawn["SpawnStartingItems?"] = true end)
    GPS:FinishSpawningActor(Pawn, Transform, 1)
    return Pawn
end

local function SpawnPawnFor(World, PC)
    local HostPawn = LocalPC():K2_GetPawn()
    if not IsAlive(HostPawn) then Log("Keine Host-Figur, kann fuer Mitspieler nichts spawnen") return nil end
    local Loc = HostPawn:K2_GetActorLocation()
    local Yaw = HostPawn:K2_GetActorRotation().Yaw
    -- Server-Modus: die Server-Figur schwebt unsichtbar in der Luft. Neben einem Mitspieler am Boden
    -- oder am Startpunkt der Welt spawnen (server.lua).
    if SETTINGS.server then Loc, Yaw = SETTINGS.server.SpawnPoint(World, PC, Loc, Yaw) end
    for _, Offset in ipairs({ { 200, 0 }, { -200, 0 }, { 0, 200 }, { 0, -200 } }) do
        local Target = { X = Loc.X + Offset[1], Y = Loc.Y + Offset[2], Z = Loc.Z + 100 }
        local ok, Pawn = pcall(SpawnWithStartingItems, World, HostPawn:GetClass(), Target, Yaw, PC)
        if not ok then Log("Spawn mit Startausruestung fehlgeschlagen: %s", tostring(Pawn)) Pawn = nil end
        if not IsAlive(Pawn) then
            Pawn = World:SpawnActor(HostPawn:GetClass(), Target, { Pitch = 0, Yaw = Yaw, Roll = 0 })
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
        Movement.bIgnoreClientMovementErrorChecksAndCorrection = Trust
        Movement.bServerAcceptClientAuthoritativePosition = Trust
    end)
end

local function ManageMovementTrust(Key, Pawn, Now)
    if not SETTINGS.trust_movement then return end
    local Name = Pawn:GetFName():ToString()
    local State = MovementState[Key]
    if not State or State.Pawn ~= Name then
        State = { Pawn = Name, Since = Now, Trusted = false }
        MovementState[Key] = State
    end
    local HostPawn = LocalPC():K2_GetPawn()
    local Here = Pawn:K2_GetActorLocation()
    local Z = Here.Z
    local Walking = Safe(function() return Pawn.CharacterMovement.MovementMode end) == MOVE_WALKING
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
    if not State.Trusted and Now - State.Since >= TRUST_AFTER then
        local Mode = Safe(function() return Pawn.CharacterMovement.MovementMode end)
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
        if Capsule.bReplicates then Capsule:SetIsReplicated(false) end
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
    Pawn.BP_JigHelperComp.RepActorsData:ForEach(function(_, Entry)
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
        StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary")
            :SetActorSaveProperties(Actor, true, false, false, 0)
        Actor.Tags[#Actor.Tags + 1] = FName("EMS_SkipSave")
    end)
    NoSaveMarked[Name] = true
    Log("Speicherschutz fuer %s: %s", Name, ok and "aktiv" or tostring(err))
end

local function HandleRemotePlayers(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Now, Current = os.time(), {}
    local HostPC = LocalPC()
    if HostPC then PreparePlayerPawn(HostPC:K2_GetPawn()) end
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
            if not HasPawn and not SpawnTried[Key] and Now - RemoteSeen[Key] >= SPAWN_DELAY then
                SpawnTried[Key] = true
                SpawnedPawns[Key] = SpawnPawnFor(World, PC)
            elseif HasPawn then
                DeadSince[Key] = nil
                local okTrust, errTrust = pcall(ManageMovementTrust, Key, PC:K2_GetPawn(), Now)
                if not okTrust then Log("Bewegungs-Fehler: %s", tostring(errTrust)) end
            elseif SpawnTried[Key] then
                -- Figur weg = gestorben. Erst dem Spiel Zeit fuer seinen eigenen Respawn lassen,
                -- dann selbst eine neue Figur neben den Host stellen.
                if not DeadSince[Key] then
                    DeadSince[Key] = Now
                    Log("Mitspieler ohne Figur (gestorben?), Respawn in %d s", RESPAWN_DELAY)
                elseif Now - DeadSince[Key] >= RESPAWN_DELAY then
                    DeadSince[Key] = nil
                    SpawnedPawns[Key] = SpawnPawnFor(World, PC)
                end
            end
        end
    end
    -- Mitspieler weg: seine Figur wieder entfernen.
    for Key in pairs(RemoteSeen) do
        if not Current[Key] then
            local Pawn = SpawnedPawns[Key]
            if Pawn and IsAlive(Pawn) then
                Pawn:K2_DestroyActor()
                Log("Figur des Mitspielers entfernt")
            end
            RemoteSeen[Key], SpawnTried[Key], SpawnedPawns[Key], DeadSince[Key] = nil, nil, nil, nil
            MovementState[Key] = nil
        end
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
            local Health = Safe(function() return Pawn.MedicalComponent.Health end)
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
            if LastSentStats[Key] ~= Text then
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
-- Lua erlaubt nur 200 lokale Variablen pro Datei: neuere Teile stehen in do-Bloecken und
-- reichen nur das nach aussen, was der Rest braucht.
local Coop = {}

-- Eine gemeinsame Liste aller Figuren (statt mehrerer FindAllOf("Character") pro Sekunde): 0,2 s gueltig, alle
-- Nutzer pruefen jede Figur ohnehin mit IsAlive
function Coop.Characters()
    local Now = os.clock()
    if not Coop.CharList or Now - Coop.CharAt > 0.2 then Coop.CharList, Coop.CharAt = FindAllOf("Character") or {}, Now end
    return Coop.CharList
end

local function ApplyHostMessage(Text)
    if OnHostData and Text:sub(1, 5) == "part|" then OnHostData(Text) return end
    local Kind, Payload = Text:match("^(%w+)|(.*)$")
    if Kind == "stats" then
        local PC = LocalPC()
        for Field, Value in Payload:gmatch("(%w+)=(%-?%d+)") do
            pcall(function() PC[Field] = tonumber(Value) end)
        end
        Log("Statistik vom Host uebernommen: %s", Payload)
    end
end

-- Nur beim Spieler (empfaengt): Der Server ruft ClientMessage selbst auf (Senden), oft mitten in einem anderen
-- Hook - ein Hook im Hook ist in UE4SS nicht stabil.
if os.getenv("LASTSIGNAL_SERVER") ~= "1" and os.getenv("NETTEST_SERVER") ~= "1" then
    TryHook("/Script/Engine.PlayerController:ClientMessage", function(_, Message)
        local Text = Safe(function() return Message:get():ToString() end, "")
        if Text:sub(1, #MESSAGE_PREFIX) == MESSAGE_PREFIX then
            local ok, err = pcall(ApplyHostMessage, Text:sub(#MESSAGE_PREFIX + 1))
            if not ok then Log("Host-Nachricht fehlerhaft: %s", tostring(err)) end
        end
    end)
end

do
-- Datenkanal Mitspieler -> Host: ServerExecRPC ist ein zuverlaessiger Server-RPC der Engine, der im
-- Shipping-Build nichts ausfuehrt (Konsolenbefehle gibt es dort nur mit Cheat-Manager im
-- Entwickler-Build). Der Host liest NETTEST|-Nachrichten im Hook mit und weiss dabei, von welchem
-- Controller sie kommen. Laengere Daten gehen in beide Richtungen in Stuecken:
-- part|<Art>|<Nr>|<Anzahl>|<Text>.
local CHUNK_SIZE = 1000

local function SendToHost(Text)
    LocalPC():ServerExecRPC(MESSAGE_PREFIX .. Text)
end

local function SendChunked(Send, Kind, Data)
    local Total = math.max(1, math.ceil(#Data / CHUNK_SIZE))
    for I = 1, Total do
        Send(string.format("part|%s|%d|%d|%s", Kind, I, Total, Data:sub((I - 1) * CHUNK_SIZE + 1, I * CHUNK_SIZE)))
    end
end

local Incoming = {}

-- Gibt Art und vollstaendige Daten zurueck, sobald alle Stuecke eines Absenders da sind.
local function Reassemble(Sender, Text)
    local Kind, Index, Total, Chunk = Text:match("^part|([%w_]+)|(%d+)|(%d+)|(.*)$")
    if not Kind then return nil end
    Index, Total = tonumber(Index), tonumber(Total)
    local Key = Sender .. "|" .. Kind
    local Entry = Incoming[Key]
    if Index == 1 or not Entry or Entry.Total ~= Total then
        Entry = { Total = Total, Parts = {}, Count = 0 }
        Incoming[Key] = Entry
    end
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

local function ApplyAppearance(Pawn, Text)
    local Save = PlayerSave()
    if not (IsAlive(Save) and IsAlive(Pawn)) then return false end
    local Wanted, Backup = ParseFields(Text), {}
    for _, Field in ipairs(APPEARANCE_TEXTS) do Backup[Field] = Save[Field]:ToString() end
    for _, Field in ipairs(APPEARANCE_OBJECTS) do Backup[Field] = Save[Field] end
    local ok, err = pcall(function()
        for _, Field in ipairs(APPEARANCE_TEXTS) do
            if Wanted[Field] then Save[Field] = Wanted[Field] end
        end
        for _, Field in ipairs(APPEARANCE_OBJECTS) do
            if Wanted[Field] then Save[Field] = LoadByPath(Wanted[Field]) end
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
local function ResendClothing(Pawn)
    local Holding = Safe(function()
        local Attached = {}
        Pawn:GetAttachedActors(Attached, true, false)
        for _, Entry in ipairs(Attached) do
            if Entry:get():GetAttachParentSocketName():ToString() == "Weapon_r" then return true end
        end
        return false
    end, false)
    if Holding then return false end
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
            local Asset = Pawn[Name]:GetSkeletalMeshAsset()
            return IsAlive(Asset) and Asset:GetFName():ToString() or "-"
        end, "?")
    end
    return table.concat(Parts, ",")
end

local HostAppearance = {}      -- [PlayerId] = Text (Host eigenes + alle Mitspieler)
local HostApplied = {}         -- [PlayerId] = Figurenname, auf die es beim Host angewendet ist
local SentAppearance = {}      -- [Controller-Key] = { [PlayerId] = Text }
local ClothingResendAt = {}    -- Zeitpunkte, zu denen die Kleidung erneut verschickt wird
local ClothingPawn = {}        -- [PlayerId] = Figurenname, fuer die das Nachschicken geplant ist
local ClothingSeen = {}        -- [Figurenname] = Kleidungsstand beim letzten Durchlauf
local ClothingResendFor = {}   -- [Figurenname] = Zeitpunkte, zu denen nur diese Figur nachgeschickt wird

local function PlayerPawns()
    local Pawns = {}
    for _, Pawn in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if IsAlive(Pawn) then Pawns[#Pawns + 1] = Pawn end
    end
    return Pawns
end

local function HandleHostAppearance(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Now = os.time()
    local HostPawn = LocalPC():K2_GetPawn()
    local HostId = IsAlive(HostPawn) and PlayerIdOf(HostPawn)
    if HostId and not HostAppearance[HostId] and IsAlive(PlayerSave()) then
        HostAppearance[HostId] = SerializeAppearance(PlayerSave())
    end
    -- Einzelne Kleidungs-Plaetze, um die Mitspieler gebeten haben (nicht mit Waffe in der Hand, sonst spaeter)
    local Queue, Later = Coop.ClothSlotQueue, {}
    Coop.ClothSlotQueue = Later
    for _, Req in ipairs(Queue) do
        for _, Pawn in ipairs(PlayerPawns()) do
            if PlayerIdOf(Pawn) == Req.Id and CLOTHING_ONREPS[Req.Index] then
                local Holding = Safe(function()
                    local Attached = {}
                    Pawn:GetAttachedActors(Attached, true, false)
                    for _, Entry in ipairs(Attached) do
                        if Entry:get():GetAttachParentSocketName():ToString() == "Weapon_r" then return true end
                    end
                    return false
                end, false)
                if Holding then
                    Later[#Later + 1] = Req
                else
                    pcall(function() Pawn[CLOTHING_ONREPS[Req.Index]](Pawn) end)
                    -- Wie sieht der Host den Platz? (Nach dem Tod liegen die Schuhe in der Todes-Kiste.)
                    local Server = Safe(function()
                        local Asset = Pawn[CLOTHING_MESHES[Req.Index]]:GetSkeletalMeshAsset()
                        return tostring(Pawn[CLOTHING_FLAGS[Req.Index]]) .. "/" .. (IsAlive(Asset) and Asset:GetFName():ToString() or "-")
                    end, "?")
                    Log("Kleidung %s von Spieler %d einzeln nachgeschickt (beim Host: %s)", CLOTHING_ONREPS[Req.Index], Req.Id, Server)
                end
            end
        end
    end
    -- Mitspieler-Figuren beim Host so aussehen lassen, wie ihr Besitzer sie gebaut hat.
    for _, Pawn in ipairs(PlayerPawns()) do
        local Id = PlayerIdOf(Pawn)
        local Name = Pawn:GetFName():ToString()
        -- Neue Figur (Beitritt oder Respawn, auch beim Host): Der Kleidungs-Multicast kommt oft,
        -- bevor der Mitspieler die Figur kennt. Unabhaengig vom Aussehen mehrmals nachschicken.
        if Id and ClothingPawn[Id] ~= Name then
            ClothingPawn[Id] = Name
            for _, Delay in ipairs({ 2, 5, 10 }) do ClothingResendAt[#ClothingResendAt + 1] = Now + Delay end
        end
        local State = ClothingState(Pawn)
        -- An-/Ausziehen: nur diese Figur nachschicken (sofort und nach 2 s), egal wie viele Spieler da sind.
        if ClothingSeen[Name] and ClothingSeen[Name] ~= State then
            Log("Kleidung von %s geaendert", Name)
            ClothingResendFor[Name] = { Now, Now + 2 }
        end
        ClothingSeen[Name] = State
        local Times = ClothingResendFor[Name]
        if Times then
            -- Verschoben (Waffe in der Hand): bleibt faellig und wird jede Sekunde erneut versucht
            for I = #Times, 1, -1 do
                if Now >= Times[I] and ResendClothing(Pawn) then table.remove(Times, I) end
            end
            if #Times == 0 then ClothingResendFor[Name] = nil end
        end
        if Id and Id ~= HostId and HostAppearance[Id] and HostApplied[Id] ~= Name then
            HostApplied[Id] = Name
            local ok = ApplyAppearance(Pawn, HostAppearance[Id])
            Log("Aussehen von Spieler %d auf %s angewendet: %s", Id, Name, ok and "ok" or "Fehler")
            ClothingResendAt[#ClothingResendAt + 1] = Now + 1
        end
    end
    -- Jedem Mitspieler alle Aussehen schicken, die er noch nicht hat.
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            SentAppearance[Key] = SentAppearance[Key] or {}
            local NewData = false
            for Id, Text in pairs(HostAppearance) do
                if SentAppearance[Key][Id] ~= Text then
                    SentAppearance[Key][Id] = Text
                    SendChunked(function(T) SendToClient(PC, T) end, "appear", Id .. "#" .. Text)
                    NewData = true
                end
            end
            if NewData then
                -- Erst nachdem der Mitspieler das Aussehen angewendet hat, Kleidung erneut schicken
                -- (zweimal, der Multicast ist unzuverlaessig).
                ClothingResendAt[#ClothingResendAt + 1] = Now + 3
                ClothingResendAt[#ClothingResendAt + 1] = Now + 6
            end
        end
    end
    local Due = false
    for I = #ClothingResendAt, 1, -1 do
        if Now >= ClothingResendAt[I] then table.remove(ClothingResendAt, I) Due = true end
    end
    if Due then
        local Pawns, Later = PlayerPawns(), 0
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
    Coop.LastStep = Kind .. " " .. os.date("%H:%M:%S") .. " " .. tostring(Data):sub(1, 40)   -- fuer den Haenger-Waechter
    if Kind == "appear" then
        local Id = Safe(function() return PC.PlayerState:GetPlayerId() end)
        if Id and HostAppearance[Id] ~= Data then
            HostAppearance[Id], HostApplied[Id] = Data, nil
            Log("Aussehen von Spieler %d erhalten (%d Zeichen)", Id, #Data)
        end
    elseif Kind == "guestid" then
        local Id, PawnName = Data:match("^(%x+)#(.+)$")
        if Id and Coop.GuestIds[Key] ~= Id then Log("Mitspieler-ID erhalten: %s", Id) end
        if Id then Coop.GuestIds[Key], Coop.SyncRequest[Key] = Id, PawnName end
    elseif Kind == "cloth" then
        -- Mitspieler bittet um die Kleidung aller Figuren (sofort und 2 s spaeter)
        ClothingResendAt[#ClothingResendAt + 1] = os.time()
        ClothingResendAt[#ClothingResendAt + 1] = os.time() + 2
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
        if Coop.OnPendingAdd then
            local ok, err = pcall(Coop.OnPendingAdd, PC, Data)
            if not ok then Log("Gegenstand fuer Mitspieler fehlerhaft: %s", tostring(err)) end
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
    end
end
Coop.ClothSlotQueue = {}       -- { Id = PlayerId, Index = Platz in CLOTHING_ONREPS }, vom Mitspieler angefragt
Coop.GuestIds = {}             -- [Controller-Key] = feste ID des Mitspielers (ueber Beitritte hinweg)
Coop.SyncRequest = {}          -- [Controller-Key] = Figur, fuer die der Mitspieler den Abgleich will

-- Nur auf dem Server (empfaengt): Beim Spieler feuerte der Hook bei jedem eigenen Senden, oft mitten in einem
-- anderen Hook (z. B. Geraeusch bei jedem Schuss) - ein Hook im Hook ist in UE4SS nicht stabil.
if os.getenv("LASTSIGNAL_SERVER") == "1" or os.getenv("NETTEST_SERVER") == "1" then
    TryHook("/Script/Engine.PlayerController:ServerExecRPC", function(Context, Message)
        local Text = Safe(function() return Message:get():ToString() end, "")
        if Text:sub(1, #MESSAGE_PREFIX) ~= MESSAGE_PREFIX then return end
        local PC = Context:get()
        if not IsAlive(PC) or Safe(function() return PC:IsLocalController() end, true) then return end
        local ok, err = pcall(OnClientData, PC, Text:sub(#MESSAGE_PREFIX + 1))
        if not ok then Log("Mitspieler-Nachricht fehlerhaft: %s", tostring(err)) end
    end)
end

-- Mitspieler-Seite: eigenes Aussehen einmal pro Verbindung schicken, Aussehen der anderen
-- anwenden, sobald ihre Figur da ist (und nach jedem Respawn erneut).
local ClientAppearance = {}    -- [PlayerId] = Text
local ClientApplied = {}       -- [PlayerId] = Figurenname
local AppearanceSentFor = nil  -- eigene Figur, fuer die das Aussehen zuletzt geschickt wurde
local AppearanceRepeatAt = nil -- direkt nach dem Beitritt geht die erste Nachricht manchmal verloren

local function HandleClientAppearance(World)
    if NetModeName(World) ~= "Client" then
        AppearanceSentFor, AppearanceRepeatAt, ClientAppearance, ClientApplied = nil, nil, {}, {}
        Coop.ClothingAsk = nil
        return
    end
    local Own = LocalPC():K2_GetPawn()
    if not IsAlive(Own) then return end
    local OwnName = Own:GetFName():ToString()
    local Now = os.time()
    if IsAlive(PlayerSave()) and (AppearanceSentFor ~= OwnName
        or (AppearanceRepeatAt and Now >= AppearanceRepeatAt)) then
        if AppearanceSentFor ~= OwnName then Coop.ClothingAsk = { Now + 5, Now + 15, Now + 30 } end
        AppearanceRepeatAt = AppearanceSentFor ~= OwnName and Now + 10 or nil
        AppearanceSentFor = OwnName
        SendChunked(SendToHost, "appear", SerializeAppearance(PlayerSave()))
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
    end
end

Coop.HandleHostAppearance, Coop.HandleClientAppearance = HandleHostAppearance, HandleClientAppearance
Coop.PlayerSave, Coop.LoadByPath, Coop.PlayerPawns = PlayerSave, LoadByPath, PlayerPawns
Coop.SendChunked, Coop.SendToHost, Coop.HostDataHandlers = SendChunked, SendToHost, HostDataHandlers
Coop.SendToClient = SendToClient
Coop.ResendAppearance = function() AppearanceSentFor = nil end
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

local CharacterHooksDone = false
local CHARACTER_CLASS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

-- Blueprint-Funktionen lassen sich erst hooken, wenn ihre Klasse geladen ist.
local function RegisterCharacterHooks()
    if CharacterHooksDone or not StaticFindObject(CHARACTER_CLASS):IsValid() then return end
    CharacterHooksDone = true
    -- Nicht jeder Tod laeuft ueber PlayerDeath (z. B. ueber PlayerDead), am Ende steht aber immer der
    -- Multicast MC_PlayerDead. Alle drei melden; OnGuestDeath verarbeitet jede Figur nur einmal.
    for _, Fn in ipairs({ "PlayerDeath", "PlayerDead", "MC_PlayerDead" }) do
        TryHook(CHARACTER_CLASS .. ":" .. Fn, function(Context)
            Log("TOD: %s.%s", Context:get():GetFName():ToString(), Fn)
            if Coop.NoteDeath and NetModeName(CurrentWorld()) == "ListenServer" then pcall(Coop.NoteDeath, Context:get()) end
            local ok, err = pcall(Coop.OnGuestDeath, Context:get())
            if not ok then Log("Tod-Fehler: %s", tostring(err)) end
        end)
    end
    -- Zielfernrohr: Das Spiel versteckt die Waffe per SetActorHiddenInGame. Die Waffe ist repliziert,
    -- also verschwindet sie beim Host-Zielen auch fuer alle anderen (nur das lokale Magazin bleibt).
    -- Beim Host gleich wieder einblenden; lokal bleibt sie weg, weil SetEnableScope vorher den ganzen
    -- Koerper samt angehaengter Waffe per SetVisibility (nicht repliziert) ausblendet.
    TryHook(CHARACTER_CLASS .. ":SetCurrentWeaponVisibility", function(Context, Hidden)
        local ok, err = pcall(function()
            if not Hidden:get() or NetModeName(CurrentWorld()) ~= "ListenServer" then return end
            local Pawn = Context:get()
            -- Nur, wenn der Koerper lokal schon ausgeblendet ist (sonst waere die Waffe lokal sichtbar)
            if not Pawn:IsLocallyControlled() or Pawn.Mesh:IsVisible() then return end
            local Attached = {}
            Pawn:GetAttachedActors(Attached, true, false)
            for _, Entry in ipairs(Attached) do
                local Weapon = Entry:get()
                if Weapon:GetAttachParentSocketName():ToString() == "Weapon_r" then
                    local Parts = {}
                    Weapon:GetAttachedActors(Parts, true, true)
                    Parts[#Parts + 1] = { get = function() return Weapon end }
                    for _, Part in ipairs(Parts) do
                        local Actor = Part:get()
                        if Actor.bHidden and Actor.bReplicates then Actor:SetActorHiddenInGame(false) end
                    end
                end
            end
        end)
        if not ok then Log("Zielfernrohr-Fehler: %s", tostring(err)) end
    end)
    local Medical = FindFirstOf("MedicalComponent_C")
    if IsAlive(Medical) then
        local ClassPath = Medical:GetClass():GetFullName():match("^%S+%s+(.+)$")
        TryHook(ClassPath .. ":Svr_Damage", function(Context, DamagedActor, BaseDamage)
            local Comp = Context:get()
            Log("Svr_Damage: Komponente von %s, Ziel %s, Schaden %.1f",
                Safe(function() return Comp:GetOwner():GetFName():ToString() end, "?"),
                Safe(function() return DamagedActor:get():GetFName():ToString() end, "?"),
                Safe(function() return BaseDamage:get() end, 0))
        end)
        TryHook(ClassPath .. ":PlayerDeath", function(Context)
            Log("TOD: MedicalComponent von %s",
                Safe(function() return Context:get():GetOwner():GetFName():ToString() end, "?"))
            local ok, err = pcall(function() Coop.OnGuestDeath(Context:get():GetOwner()) end)
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
        -- FFrame::PreviousFrame (UE 5.3); 0 schaltet das Hochlaufen der Aufrufkette ab.
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

local function SetNativeCoreEnabled(Enabled)
    if not NativeCoreLoaded or NativeCoreEnabled == Enabled then return end
    local File = io.open(ModRoot() .. "netcore_enabled.txt", "w")
    if not File then return end
    File:write(Enabled and "1" or "0")
    File:close()
    NativeCoreEnabled = Enabled
end

local function LoadNativeCore()
    local Root = ModRoot()
    local Dll = Root .. "LastSignalCore.dll"
    local Probe = io.open(Dll, "rb")
    if not Probe then Log("LastSignalCore.dll fehlt, nativer Multiplayer-Hook aus") return end
    Probe:close()
    local File = io.open(Root .. "netcore_enabled.txt", "w")
    if File then File:write("0") File:close() end
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
    for _, Widget in ipairs(FindAllOf("UserWidget") or {}) do
        if IsAlive(Widget) and Widget:IsInViewport() then
            local Name = Widget:GetClass():GetFName():ToString()
            Visible[#Visible + 1] = Name
            if Name:lower():find("menu", 1, true) or LEFTOVER_SCREENS[Name] then
                Widget:RemoveFromParent()
                Closed[#Closed + 1] = Name
            end
        end
    end
    Log("Sichtbare Widgets: %s", #Visible > 0 and table.concat(Visible, ", ") or "keine")
    Log("Geschlossen: %s", #Closed > 0 and table.concat(Closed, ", ") or "nichts")
    if IsAlive(PC) then
        StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(PC, false)
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
    local IMC, Subsystem = FindMappingContext(), InputSubsystem()
    local Missing = IMC ~= nil and Subsystem ~= nil and not Subsystem:HasMappingContext(IMC, {})
    local Stuck
    for _, Name in ipairs({ "LoadingScreenWidget_C", "PressAnyKeyWidget_C" }) do
        for _, W in ipairs(FindAllOf(Name) or {}) do
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
    local Widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(PC, Class, PC)
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
        if GI["AllowSaving?"] then GI["AllowSaving?"] = false end
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
    for _, Actor in ipairs(Full and (FindAllOf("Actor") or {}) or Coop.Characters()) do
        if Safe(function() return IsClientGhost(Actor) end, false) then Candidates[#Candidates + 1] = Actor end
    end
    RemoveGhosts(Candidates, "Nachgespawnt")
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
        Item:GetJigDA(Asset)
        local Equipped, SlotRef = {}, {}
        HbContainer.ContainerRef:EquipItem(Asset.JigDataAsset, -1, nil, true, Equipped, SlotRef)
        local HotbarItem = SlotRef.SlotItemRef
        if not Equipped.Equipped or not IsAlive(HotbarItem) then return end
        pcall(function() HotbarItem:HideCapacity() end)
        pcall(function() HotbarItem:AdaptImageToActionbar(Item.RenderTargetSnap) end)
        pcall(function()
            local Uid = {}
            Item:GetUniqueID(Uid)
            HotbarItem:SetUniqueID({ A = Uid.A, B = Uid.B, C = Uid.C, D = Uid.D }, {})
        end)
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
local GET_DURABILITY = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:GetDurability"
local DURABILITY_PATCH = { Offset = 674, Expect = "3700000000000000000696030000", New = "3700000000000059400696030000" }
local PatchLine = nil

local function UpdateClientPatches(IsClient)
    if not NativeCoreLoaded or (not IsClient and not PatchLine) then return end
    local Fn = StaticFindObject(GET_DURABILITY)
    if not (Fn and Fn:IsValid()) then return end
    local Line = string.format("durability %x %d %s %s %d\n", Fn:GetAddress(), DURABILITY_PATCH.Offset,
        DURABILITY_PATCH.Expect, DURABILITY_PATCH.New, IsClient and 1 or 0)
    if Line == PatchLine then return end
    local File = io.open(ModRoot() .. "netcore_patch.txt", "w")
    if not File then return end
    File:write(Line)
    File:close()
    PatchLine = Line
    Log("Haltbarkeits-Patch %s angefordert (Ergebnis in netcore.log)", IsClient and "an" or "aus")
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
    for _, Pawn in ipairs(PlayerPawns()) do
        Pawn.BP_JigHelperComp.RepActorsData:ForEach(function(_, Entry)
            local Item = Entry:get()[REP_ACTOR_FIELD]
            if not IsAlive(Item) then return end
            for _, Ref in ipairs(Item:K2_GetComponentsByClass(PrimitiveClass)) do
                local Comp = Ref:get()
                local Key = Comp:GetAddress()
                Equipped[Key] = true
                if not CollisionOff[Key] then
                    local Old = Comp:GetCollisionEnabled()
                    if Old ~= 0 then
                        Comp:SetCollisionEnabled(0)
                        CollisionOff[Key] = { Comp = Comp, Old = Old }
                    end
                end
            end
        end)
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
    Pawn.BP_JigMultiplayer:SERVER_LoadSaveDataFromClientSide(Save.MainJigContainers, Save.MainUIDs,
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
local ToHex
do
    local HEX = {}
    for I = 0, 255 do HEX[I] = string.format("%02x", I) end
    ToHex = function(Bytes)
        local Out = {}
        for I = 1, #Bytes, 4096 do
            local Part = { Bytes:byte(I, math.min(I + 4095, #Bytes)) }
            for J = 1, #Part do Part[J] = HEX[Part[J]] end
            Out[#Out + 1] = table.concat(Part)
        end
        return table.concat(Out)
    end
end

local function FromHex(Hex)
    local Out = {}
    for I = 1, #Hex, 8192 do
        local Part, Bytes = Hex:sub(I, I + 8191), {}
        for J = 1, #Part - 1, 2 do Bytes[#Bytes + 1] = tonumber(Part:sub(J, J + 1), 16) end
        Out[#Out + 1] = string.char(table.unpack(Bytes))
    end
    return table.concat(Out)
end

-- Inventar einer Mitspieler-Figur als Save_Player-Kopie (fuer das Zurueckschreiben und das
-- Server-Inventar). nil, wenn die Figur (noch) kein Inventar hat.
local function BuildGuestSave(Pawn)
    local Inventory = Pawn.BP_JigMultiplayer
    if #Inventory.MainJigContainers == 0 then return nil end
    -- Sicherung: Ein Inventar ohne einen einzigen Gegenstand nie speichern oder zurueckschicken
    -- (nach dem Lade-RPC sind die Listen beim Host zeitweise leer -> Spielstand waere ueberschrieben).
    local Items = 0
    Inventory.MainJigContainers:ForEach(function(_, Container)
        Items = Items + Container:get()[CONTAINER_ITEMS_FIELD]:GetArrayNum()
    end)
    if Items == 0 then return nil end
    local Temp = StaticConstructObject(StaticFindObject(SAVE_PLAYER_CLASS), UEHelpers.GetGameInstance())
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
    local Id = PC.PlayerState:GetPlayerId()
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
    local File = io.open(SaveGamesDir() .. Slot .. ".sav", "wb")
    if not File then Log("Inventar vom Host: Datei nicht schreibbar") return end
    File:write(FromHex(Hex))
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
    local SlotName = Safe(function() return Save:GetOuter().CurrentSaveGameName:ToString() end, "")
    if not SaveBackBackupDone and SlotName ~= "" then
        local Path = SaveGamesDir() .. SlotName .. "\\PlayerInfo.sav"
        local Source = io.open(Path, "rb")
        if Source then
            local Target = io.open(Path .. ".vor-koop", "wb")
            if Target then Target:write(Source:read("*a")) Target:close() SaveBackBackupDone = true end
            Source:close()
        end
    end
    local ok = StaticFindObject("/Script/EasyMultiSave.Default__EMSFunctionLibrary"):SaveCustom(CurrentWorld(), Save)
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
local StatCache = {}           -- [Waffen-Adresse] = { Until, Stats = { [Tag] = { Min, Max } } }
local StatHooked = {}

local function ReadWeaponStats(Pawn, Weapon)
    local Address, Stats = Weapon:GetAddress(), {}
    Pawn.BP_JigMultiplayer.MainJigContainers:ForEach(function(_, Container)
        Container:get()[CONTAINER_ITEMS_FIELD]:ForEach(function(_, Entry)
            local Item = Entry:get()
            local Ref = Item[PICKUP_REF_FIELD]
            if not (Ref and Ref:IsValid() and Ref:GetAddress() == Address) then return end
            Item[ITEM_INFO_FIELD][STATS_FIELD]:ForEach(function(_, StatEntry)
                local Stat = StatEntry:get()
                Stats[Stat[STAT_NAME_FIELD].TagName:ToString()] = { Stat[STAT_MIN_FIELD], Stat[STAT_MAX_FIELD] }
            end)
        end)
    end)
    return Stats
end

local function OnFindStat(Context, Tag, Found, MinValue, MaxValue)
    if Found:get() then return end
    local Weapon = Context:get()
    local Pawn = Weapon:GetOwner()
    if not IsAlive(Pawn) or Pawn:GetClass():GetFName():ToString() ~= "BP_PlayerCharacter_C"
        or Pawn:IsLocallyControlled() then return end
    local Key, Now = Weapon:GetAddress(), os.clock()
    local Cached = StatCache[Key]
    if not Cached or Now > Cached.Until then
        Cached = { Until = Now + STAT_CACHE_SECONDS, Stats = ReadWeaponStats(Pawn, Weapon) }
        StatCache[Key] = Cached
    end
    local Stat = Cached.Stats[Tag:get().TagName:ToString()]
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
            if Now - Coop.DeadBodySeen[Name] >= 1 and Body.CapsuleComponent:GetCollisionEnabled() ~= 0 then
                Coop.DeadBodyDone[Name] = true
                local ok, err = pcall(function() Body:MC_PlayerDead() end)
                Log("Tote Figur %s nachtraeglich eingerichtet: %s", Name, ok and "ok" or tostring(err))
            end
        end
        if IsAlive(Body) and not Body:IsLocallyControlled() and not IsAlive(Body.PlayerState)
            and Body.CapsuleComponent:GetCollisionEnabled() == 0 then
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
local Corpse = { Done = {}, At = {}, Still = {}, Glides = {}, Seen = {}, Queued = {}, BoxDone = {}, Hooked = false,  -- Done: [Name] = true, At: [Name] = uebernommene Host-Lage, Still: Ruhe-Pruefung, Glides: laufendes Gleiten; (Namen werden nicht wiederverwendet, Adressen schon)
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
        pcall(function() Char.Zombie_Cue:Stop() end)
        local Mesh = Char.Mesh
        pcall(function() Char.CharacterMovement:DisableMovement() end)
        pcall(function() Char.CapsuleComponent:SetCollisionEnabled(0) end)
        -- Mesh von der Kapsel loesen: Der Host schreibt die Ragdoll-Lage in ReplicatedMovement, das
        -- verschiebt beim Mitspieler die Kapsel (Wurzel) jede Sekunde - die angehaengte Ragdoll wurde
        -- mitgerissen und flog hin und her. Positioniert wird sie nur noch von Corpse.Follow.
        -- (Auch, wenn das Spiel sie schon selbst zur Ragdoll gemacht hat.)
        pcall(function() Mesh:K2_DetachFromComponent(1, 1, 1, false) end)  -- EDetachmentRule::KeepWorld
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
        local R, M = Char.ReplicatedMovement.Location, Mesh:K2_GetComponentLocation()
        if (R.X ~= 0 or R.Y ~= 0) and (M.X - R.X) ^ 2 + (M.Y - R.Y) ^ 2 + (M.Z - R.Z) ^ 2 > 100 * 100 then
            Mesh:K2_SetWorldLocation({ X = R.X, Y = R.Y, Z = R.Z + 10 }, false, {}, true)
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

local function RagdollDeadAI()
    if not Corpse.Hooked then
        Corpse.Hooked = pcall(RegisterHook, Corpse.ONREP, function(Context)
            local Char = Context:get()
            if IsAlive(Char) and not Char:HasAuthority() and IsDeadAI(Char) then
                local Name = Char:GetFName():ToString()
                -- nur schon bekannte Figuren (frischer Tod), nie neu hereinkommende. Nicht hier im
                -- Netzwerk-Callback einrichten (Physik/Abhaengen mitten im Empfang), sondern gleich danach.
                if Corpse.Seen[Name] and Corpse.Ready(Char, Name) and not Corpse.Queued[Name] then
                    Corpse.Queued[Name] = true
                    ExecuteInGameThread(function()
                        if IsAlive(Char) then
                            local ok, err = pcall(Corpse.Setup, Char)
                            if not ok then Log("Leichen-Fehler: %s", tostring(err)) end
                        end
                    end)
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
                    if Cue:IsPlaying() then Cue:Stop() end
                    if Cue.VolumeMultiplier ~= 0 then Cue:SetVolumeMultiplier(0) end
                end)
            end
            local ok, err = pcall(Corpse.Follow, Char, Name)
            if not ok and not Corpse.FollowErr then Corpse.FollowErr = true Log("Leichen-Position: %s", tostring(err)) end
        end
    end
    local ok, err = pcall(Corpse.GlideStep)
    if not ok and not Corpse.GlideErr then Corpse.GlideErr = true Log("Leichen-Absetzen: %s", tostring(err)) end
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
function Corpse.NoteDeath(Pawn)
    if not IsAlive(Pawn) or Corpse.Deaths[Pawn:GetFName():ToString()] then return end
    local PS = Pawn.PlayerState
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
function Corpse.BoxMarkers(Box)
    local List, L = {}, Box:K2_GetActorLocation()
    if IsAlive(Box.DeathMarker) then List[1] = Box.DeathMarker end
    for _, M in ipairs(FindAllOf("BP_Marker_C") or {}) do
        if IsAlive(M) and (not List[1] or M:GetAddress() ~= List[1]:GetAddress()) then
            local P = M:K2_GetActorLocation()
            if (P.X - L.X) ^ 2 + (P.Y - L.Y) ^ 2 + (P.Z - L.Z) ^ 2 < 500 * 500 then List[#List + 1] = M end
        end
    end
    return List
end

function Corpse.ClientMarkers()
    local PC, Own = LocalPC(), nil
    Own = IsAlive(PC) and Safe(function() return PC:K2_GetPawn() end)
    Corpse.MarkerFor = Corpse.MarkerFor or {}
    for _, Box in ipairs(FindAllOf(Corpse.BOX_CLASS) or {}) do
        if IsAlive(Box) then
            local Owner = Box:GetOwner()
            local Mine = IsAlive(Owner) and IsAlive(PC) and Owner:GetAddress() == PC:GetAddress()
            local Name = Box:GetFName():ToString()
            if not Mine then
                if IsAlive(Box.DeathWidget) then Box.DeathWidget:SetVisibility(false, true) end
                for _, M in ipairs(Corpse.BoxMarkers(Box)) do
                    if IsAlive(M.Marker) then M.Marker:SetVisibility(1) end  -- Collapsed
                    M.Markers:ForEach(function(_, W) local Widget = W:get() if IsAlive(Widget) then Widget:SetVisibility(1) end end)
                end
            elseif IsAlive(Own) and Corpse.MarkerFor[Name] ~= Own:GetAddress() and not Box["Looted?"] then
                Corpse.MarkerFor[Name] = Own:GetAddress()
                for _, M in ipairs(Corpse.BoxMarkers(Box)) do
                    if not IsAlive(M.Marker) then pcall(function() M:AddMarker() end) Log("Eigener Todes-Marker neu eingetragen (%s)", Name) end
                end
            end
        end
    end
end

function Corpse.ClientBoxes()
    for _, Box in ipairs(FindAllOf(Corpse.BOX_CLASS) or {}) do
        local Name = IsAlive(Box) and Box:GetFName():ToString()
        if Name and not Box:HasAuthority() and not Corpse.BoxDone[Name] and Corpse.Ready(Box, Name) then
            local R = Box.ReplicatedMovement.Location
            if R.X ~= 0 or R.Y ~= 0 then
                Corpse.BoxDone[Name] = true
                Box:K2_SetActorLocation({ X = R.X, Y = R.Y, Z = R.Z }, false, {}, true)
                pcall(function() Box.RootComponent:SetMobility(0) end)  -- EComponentMobility::Static
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
    if Corpse.Glides[Name] then return end
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

-- Festhalten: Die eigene Haltung liegt an der Host-Stelle oft nicht stabil (Hang, Bodenkontakt) und
-- rutschte sonst Meter weit weg; ohne Schwerkraft trieb sie mit dem Restschwung in den Himmel. Darum
-- die Haltung einfrieren: Mesh-Tick aus (Knochen bleiben, wie sie sind), dann Physik aus (Koerper
-- bleiben stehen, Looten trifft weiter). PutAllRigidBodiesToSleep ist aus Lua nicht aufrufbar.
function Corpse.Freeze(Mesh)
    pcall(function() Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false) end)
    pcall(function() Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false) end)
    pcall(function() Mesh:SetComponentTickEnabled(false) end)
    pcall(function() Mesh:SetSimulatePhysics(false) end)
end

-- Absetzen: Mit Schwerkraft, aber ohne Schwung sinkt sie auf den Boden (nach sofortigem Einfrieren
-- schwebte sie), nach 1,5 s einfrieren. Laeuft in der Sekunden-Schleife (RagdollDeadAI).
function Corpse.Settle(G)
    local Mesh = G.Char.Mesh
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
            for _, Entry in ipairs(Pawn:K2_GetComponentsByClass(SkeletalMeshClass)) do
                local Mesh = Entry.get and Entry:get() or Entry
                if Mesh.VisibilityBasedAnimTickOption ~= ALWAYS_TICK then
                    Mesh.VisibilityBasedAnimTickOption = ALWAYS_TICK
                end
            end
        end
    end
    local Seen, Radius2 = {}, WAKE_RADIUS * WAKE_RADIUS
    for _, Char in ipairs(Coop.Characters()) do
        local Mesh = IsAlive(Char) and Char:GetClass():GetFName():ToString() ~= "BP_PlayerCharacter_C" and Char.Mesh
        if Mesh and Mesh:IsValid() and IsDeadAI(Char) then
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
            for _, G in ipairs(Guests) do
                if (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2 + (L.Z - G.Z) ^ 2 < Radius2 then Near = true break end
            end
            Seen[Key] = true
            if Near and WokenMeshes[Key] == nil then
                WokenMeshes[Key] = Mesh.VisibilityBasedAnimTickOption
                Mesh.VisibilityBasedAnimTickOption = ALWAYS_TICK
            elseif not Near and WokenMeshes[Key] ~= nil then
                Mesh.VisibilityBasedAnimTickOption = WokenMeshes[Key]
                WokenMeshes[Key] = nil
            end
        end
    end
    for Key in pairs(WokenMeshes) do
        if not Seen[Key] then WokenMeshes[Key] = nil end
    end
end

-- Neue Mitspieler-Figur: Das Spiel friert sie beim Spawn ein (Bewegungsmodus "None") und gibt sie
-- normalerweise nach ~10 s frei. Selten bleibt das aus: Der Mitspieler schwebt und kann nicht laufen.
-- Ist sie 15 s nach dem Spawn noch eingefroren, faellt sie auf den Boden ("Falling"). Host und
-- Mitspieler frieren ihre Kopie jeweils selbst ein, darum geben beide frei.
-- (Als Tabelle statt einzelner lokaler Variablen: Lua erlaubt im Hauptteil nur 200.)
local U = { AFTER = 15, Seen = {}, OwnChecked = nil }  -- Seen: [Figurenname] = erstes Sehen (false = geprueft)

function U.Unfreeze(Pawn)
    local Move = Pawn.CharacterMovement
    if Move.MovementMode ~= 0 or IsAlive(Pawn:GetAttachParentActor()) then return false end
    Move:SetMovementMode(3, 0)
    return true
end

function U.OwnPawn(Pawn, Since)
    local Name = Pawn:GetFName():ToString()
    if U.OwnChecked == Name or os.time() - Since < U.AFTER then return end
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
            elseif Since and Now - Since >= U.AFTER then
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
-- Leichen nach einem Wiederbeitritt nicht mehr eingerichtet (und stoehnen weiter).
Coop.ResetCorpses = function()
    Corpse.Done, Corpse.At, Corpse.Still, Corpse.Glides, Corpse.Seen, Corpse.Queued, Corpse.BoxDone = {}, {}, {}, {}, {}, {}, {}
    Coop.DeadBodySeen, Coop.DeadBodyDone = {}, {}
end
end  -- Leichen, KI-Animation, Spawn-Freigabe (eigener Block: Lua erlaubt nur 200 lokale Variablen)
Coop.SyncEquipmentCollision, Coop.UploadOwnInventory = SyncEquipmentCollision, UploadOwnInventory
Coop.HandleSaveBack = HandleSaveBack
-- Tod: ausstehendes Zurueckschreiben (Stand von vor dem Tod) verwerfen und erst nach SAVE_BACK_EVERY neu
Coop.CancelSaveBack = function(Key)
    OutQueue[Key], LastSentInventory[Key], SaveBackAt[Key] = nil, nil, os.time() + SAVE_BACK_EVERY
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
            Ready = {}, SentText = {}, CheckAt = {}, StoredText = {} }

-- Felder der passiven Faehigkeiten (Current*, Max*XP, *Percentage), einmal aus der Klasse gelesen.
function V.SkillFields(Comp)
    if V.Skills then return V.Skills end
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
    local function Add(Owner, Comp, Field)
        local Value = Owner[Comp][Field]
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
        if Comp ~= "Pos" and IsAlive(Owner) and Number and pcall(function() Owner[Comp][Field] = Number end) then
            Count = Count + 1
        end
    end
    return Count
end

-- Host: Anzeige des Mitspielers fuer Leben & Co. sofort aktualisieren (sonst erst bei der naechsten
-- Aenderung - das Leben stand nach dem Beitritt auf dem Wert seines lokalen Spielstands).
function V.PushVitalsUI(Pawn)
    pcall(function() Pawn:Client_UpdateHealthUI(Pawn.MedicalComponent.Health) end)
    pcall(function() Pawn:Client_UpdateHungerUI(Pawn.HungerThirstComponent.CurrentHunger) end)
    pcall(function() Pawn:Client_UpdateThirstUI(Pawn.HungerThirstComponent.CurrentThirst) end)
    pcall(function() Pawn:Client_UpdateRadiationUI(Pawn.RadiationComponent.CurrentRadiation) end)
end

function V.SetReady(Key, Pawn)
    V.Ready[Key], V.SentText[Key], V.CheckAt[Key] = true, nil, nil
    V.PushVitalsUI(Pawn)
end

function V.Path(GuestId)
    return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\"
        .. GuestId .. ".werte.txt"
end

-- Server-Modus, erster Abgleich nach dem Beitritt: gespeicherte Werte oder Startwerte.
function V.Restore(Key, Pawn, PC, GuestId)
    local File = io.open(V.Path(GuestId), "r")
    local Text = File and File:read("*a")
    if File then File:close() end
    if Text and Text ~= "" then
        Log("Werte von Mitspieler %s geladen (%d Felder)", GuestId, V.Apply(Pawn, PC, Text))
        -- Server-Modus: zurueck an die letzte Position (nach einem Tod ist keine gespeichert -> Spawnpunkt)
        local X, Y, Z, Yaw = Text:match("Pos%.X=([^;]+);Pos%.Y=([^;]+);Pos%.Z=([^;]+);Pos%.Yaw=([^;]+)")
        if X and SETTINGS.server then
            local Target = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) + 50 }
            Pawn:K2_TeleportTo(Target, { Pitch = 0, Yaw = tonumber(Yaw), Roll = 0 })
            local State = MovementState[PC:GetFullName()]
            if State then State.Ground = Target end
            Log("Mitspieler %s an seine letzte Position gesetzt (%.0f %.0f %.0f)", GuestId, Target.X, Target.Y, Target.Z)
        end
    else
        local M, H, R = Pawn.MedicalComponent, Pawn.HungerThirstComponent, Pawn.RadiationComponent
        M.Health, H.CurrentHunger, H.CurrentThirst = M.MaxHealth, H.MaxHunger, H.MaxThirst
        R.CurrentRadiation = R.MaxRadiation
        Log("Mitspieler %s ohne gespeicherte Werte: Startwerte (Stufe %d)", GuestId, PC.LevellingComponent.CurrentLevel)
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
    if not (Pawn.MedicalComponent.Health > 0) then return end
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
    if not V.Ready[Key] or Now < (V.CheckAt[Key] or 0) then return end
    V.CheckAt[Key] = Now + 2
    local Text = V.Collect(Pawn, PC, false)
    if Text ~= V.SentText[Key] then
        V.SentText[Key] = Text
        Coop.SendChunked(function(T) SendToClient(PC, T) end, "vit", Text)
    end
end

-- Host, lokaler Modus: Werte, die der Mitspieler aus seinem Spielstand mitbringt.
function V.OnGuestValues(Key, PC, Text)
    local Pawn = PC:K2_GetPawn()
    if not SETTINGS.local_inventory or V.Ready[Key] or not IsAlive(Pawn) then return end
    Log("Werte des Mitspielers aus seinem Spielstand uebernommen (%d Felder)", V.Apply(Pawn, PC, Text))
    V.SetReady(Key, Pawn)
end

-- Mitspieler: gespiegelte Werte in die eigene Kopie schreiben und die Anzeige aktualisieren.
Coop.HostDataHandlers.vit = function(Text)
    local PC = LocalPC()
    local L = PC.LevellingComponent
    local OldLevel = L.CurrentLevel
    V.Apply(PC:K2_GetPawn(), PC, Text)
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
            Dead = {} }  -- Dead: [Controller-Key] = Name der gestorbenen Figur (fuer sie nie mehr speichern)

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

-- Abgleich: Das Inventar-UI des Mitspielers enthaelt nach jedem Spawn eine lokal gewuerfelte
-- Startausruestung, die der Host nicht kennt (darum gingen Messer und Rags nicht). Der Mitspieler leert
-- sein UI und fragt an; der Host schickt dann seinen Stand ueber den Plugin-RPC (der verschickt
-- CLIENT_ContainerDataResponse und legt die Ausruestung neu an). Mit vollem UI beim Mitspieler
-- loescht dessen UI die Gegenstaende beim Host wieder (SERVER_RequestRemoveItem).
function G.Sync(Key, PC, Pawn, Mode, GuestId)
    local Inventory = Pawn.BP_JigMultiplayer
    if Mode == "server" and not G.Restored[Key] then
        G.LoadInto(Inventory, GuestId)
        G.Restored[Key] = true
        local ok, err = pcall(Coop.Stats.Restore, Key, Pawn, PC, GuestId)
        if not ok then Log("Werte von Mitspieler %s: Laden fehlgeschlagen (%s)", GuestId, tostring(err)) end
    end
    local Empty = StaticConstructObject(StaticFindObject("/Game/Blueprints/Saves/Save_Player.Save_Player_C"),
        UEHelpers.GetGameInstance())
    Inventory:SERVER_LoadSaveDataFromClientSide(Inventory.MainJigContainers, Inventory.MainContainersIDs,
        Inventory.InventoryWeight, Empty.ActionbarUIDs)
end

function G.Store(Pawn, Slot, GuestId)
    local Temp = Coop.BuildGuestSave(Pawn)
    if not Temp then return end
    local ok = UEHelpers.GetGameplayStatics():SaveGameToSlot(Temp, Slot, 0)
    if not ok then Log("Inventar von Mitspieler %s: Speichern beim Host fehlgeschlagen", GuestId) end
    if ok and not G.StoredOnce then
        G.StoredOnce = true
        Log("Inventar von Mitspieler %s wird beim Host gespeichert (%s)", GuestId, Slot)
    end
end

-- Host: Modus verschicken, auf Anfrage abgleichen (beim Beitritt vorher aus der Datei laden),
-- im Server-Modus regelmaessig speichern.
function G.HandleHost(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Mode = SETTINGS.local_inventory and "local" or "server"
    local Now = os.time()
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Key = PC:GetFullName()
            if Now >= (G.ModeSentAt[Key] or 0) then
                G.ModeSentAt[Key] = Now + 30
                Coop.SendChunked(function(T) SendToClient(PC, T) end, "mode", Mode)
            end
            local GuestId, Pawn, Wanted = Coop.GuestIds[Key], PC:K2_GetPawn(), Coop.SyncRequest[Key]
            -- Nur lebende Figuren (die Leiche hat keinen PlayerState)
            if IsAlive(Pawn) and IsAlive(Pawn.PlayerState) then
                local okLink, errLink = pcall(Coop.Link.HostTick, Key, Pawn, Now)
                if not okLink and not Coop.Link.ErrLogged then Coop.Link.ErrLogged = true Log("Verbindungs-Schutz-Fehler: %s", tostring(errLink)) end
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
                    if Now >= (G.RetryAt[Key] or 0) then
                        local ok, err = pcall(G.Sync, Key, PC, Pawn, Mode, GuestId)
                        if ok then
                            G.Synced[Key], G.StoreAt[Key] = Wanted, Now + G.STORE_EVERY
                            Log("Inventar mit Mitspieler %s abgeglichen (%s)", GuestId, Wanted)
                        else
                            G.RetryAt[Key] = Now + 5
                            Log("Inventar von Mitspieler %s: Abgleich fehlgeschlagen (%s)", GuestId, tostring(err))
                        end
                    end
                elseif Mode == "server" and G.Restored[Key] and Now >= (G.StoreAt[Key] or math.huge)
                    and G.Dead[Key] ~= Pawn:GetFName():ToString() and Pawn.MedicalComponent.Health > 0 then
                    G.StoreAt[Key] = Now + G.STORE_EVERY
                    G.Store(Pawn, G.GuestSlot(GuestId), GuestId)
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
    if G.SyncFor ~= Name then
        G.SyncFor, G.SyncRepeatAt, G.SyncSeq = Name, Now + 10, (G.SyncSeq or 0) + 1
        pcall(function() Pawn.BP_JigMultiplayer:ClearJSIItems() end)
        pcall(function() Pawn.InGameUI:ClearContainers() end)
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
function G.OnPawnDeath(Pawn)
    if not IsAlive(Pawn) or NetModeName(CurrentWorld()) ~= "ListenServer" or Pawn:IsLocallyControlled() then return end
    local Name, PC = Pawn:GetFName():ToString(), nil
    for _, PS in ipairs(PlayerStates(CurrentWorld())) do
        local Owner = PS:GetOwner()
        local Own = IsAlive(Owner) and Safe(function() return Owner:K2_GetPawn() end)
        if IsAlive(Own) and Own:GetAddress() == Pawn:GetAddress() then PC = Owner break end
    end
    PC = PC or Safe(function() return IsAlive(Pawn.Controller) and Pawn.Controller or nil end)
    if not IsAlive(PC) then return end
    local Key = PC:GetFullName()
    if G.Dead[Key] == Name then return end
    G.Dead[Key], G.StoreAt[Key] = Name, nil
    Coop.CancelSaveBack(Key)
    local GuestId = Coop.GuestIds[Key]
    if GuestId and not SETTINGS.local_inventory then
        local GS = UEHelpers.GetGameplayStatics()
        local Slot = G.GuestSlot(GuestId)
        if GS:DoesSaveGameExist(Slot, 0) then GS:DeleteGameInSlot(Slot, 0) end
        local ok, err = pcall(Coop.Stats.StoreProgressOnly, PC, GuestId)
        if not ok then Log("Werte nach dem Tod: %s", tostring(err)) end
    end
    Log("Mitspieler %s gestorben: gespeicherte Ausruestung verworfen", tostring(GuestId))
end

Coop.OnGuestDeath = G.OnPawnDeath
Coop.OwnGuestId = G.OwnGuestId   -- Serverliste: eigene ID anzeigen
Coop.HandleGuestInventory, Coop.ClientInventoryTick = G.HandleHost, G.ClientTick
Coop.ResetGuestId = function() G.SyncFor, G.SyncRepeatAt, G.SyncSeq, Coop.Stats.Shown = nil, nil, nil, nil end
-- Server stoppt/speichert: alle Mitspieler im naechsten Durchlauf sichern
Coop.StoreGuestsNow = function() for Key in pairs(G.StoreAt) do G.StoreAt[Key] = 0 end end
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
    return Safe(function() return Char.DamageComponent.CurrentHealth end)
end

-- Host: geaenderte Werte jede Sekunde, alle FULL_EVERY s alle angeschlagenen (fuer neue Mitspieler).
function Z.HostTick(World)
    if NetModeName(World) ~= "ListenServer" then return end
    local Guests, PCs = {}, {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            PCs[#PCs + 1] = PC
            local Pawn = PC:K2_GetPawn()
            if IsAlive(Pawn) then Guests[#Guests + 1] = Pawn:K2_GetActorLocation() end
        end
    end
    if #Guests == 0 then return end
    if not Z.MontageHooked then
        Z.MontageHooked = true
        -- Zombies (AttackPlayer, Treffer), Baeren, Scavenger: PlayAnimMontage bzw. der "Play Montage"-Knoten
        TryHook("/Script/Engine.Character:PlayAnimMontage", function(Context, Montage, Rate, Section)
            pcall(Z.OnMontage, Context:get(), Montage:get(), Rate:get(), Section:get())
        end)
        TryHook("/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage",
            function(_, Mesh, Montage, Rate, _Start, Section)
                pcall(function() Z.OnMontage(Mesh:get():GetOwner(), Montage:get(), Rate:get(), Section:get()) end)
            end)
    end
    Z.ZombieClass = Z.ZombieClass or StaticFindObject(Z.CLASS)
    if not IsAlive(Z.ZombieClass) then return end
    local okLook, errLook = pcall(Z.LookHost, PCs)
    if not okLook and not Z.LOOK.HostErr then Z.LOOK.HostErr = true Log("Zombie-Aussehen-Fehler (Host): %s", tostring(errLook)) end
    local okAnimal, errAnimal = pcall(Z.AnimalHost, PCs, Guests)
    if not okAnimal and not Z.ANIMAL.HostErr then Z.ANIMAL.HostErr = true Log("Tier-Fehler (Host): %s", tostring(errAnimal)) end
end

-- Zombie-Leben 4x pro Sekunde (eigene Schleife im Spiel-Thread, nur Server): Der Lebensbalken beim Spieler folgte
-- sonst bis zu 1 s spaeter. Nur Aenderungen; alle FULL_EVERY s alle angeschlagenen (auch fuer neu erzeugte Kopien).
function Z.HpTick(World)
    if NetModeName(World) ~= "ListenServer" then return end
    -- Pro Spieler nur die Zombies in seiner Naehe: bis 50 m 4x pro Sekunde, bis 150 m 1x pro Sekunde, weiter weg
    -- nichts (verlaesst ein Zombie den Bereich, wird er beim Wiederkommen neu geschickt). Nur Aenderungen, alle
    -- FULL_EVERY s alle angeschlagenen.
    local Players = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Pawn = PC:K2_GetPawn()
            if IsAlive(Pawn) then
                local Key = PC:GetFullName()
                Z.SentTo[Key] = Z.SentTo[Key] or {}
                Players[#Players + 1] = { PC = PC, L = Pawn:K2_GetActorLocation(), Sent = Z.SentTo[Key], Parts = {}, Key = Key }
            end
        end
    end
    if #Players == 0 then return end
    Z.ZombieClass = Z.ZombieClass or StaticFindObject(Z.CLASS)
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
                local Max = Safe(function() return Char.DamageComponent.MaxHealth end, Hp)
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
        local ok, err = pcall(Z.HpTick, CurrentWorld())
        if not ok and not Z.HpErr then Z.HpErr = true Log("Zombie-Leben-Fehler (Host): %s", tostring(err)) end
    end)
end

-- Animationen der KI (Zombie-Angriffe und -Treffer, Baeren, Scavenger): Die KI rechnet nur beim Host, ihre
-- Montagen (PlayAnimMontage / "Play Montage") laufen nur dort, ohne Multicast - der Mitspieler sah Zombies
-- ohne Schlag-Animation zuschlagen. Der Host meldet jede Montage einer KI-Figur (Lage, Klasse, Montage,
-- Tempo, Abschnitt) an die Mitspieler in der Naehe; die spielen sie auf ihrer Kopie (gefunden ueber die Lage).
Z.MONTAGE_RANGE, Z.MontageSent = 10000, {}

function Z.OnMontage(Char, Montage, Rate, Section)
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
    for _, PS in ipairs(PlayerStates(CurrentWorld())) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then
            local Pawn = PC:K2_GetPawn()
            local G = IsAlive(Pawn) and Pawn:K2_GetActorLocation()
            if G and (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2 < Range2 then
                Coop.SendChunked(function(T) SendToClient(PC, T) end, "amon", Text)
            end
        end
    end
end

-- Mitspieler: Die Montage loest beim Zombie ueber ihr AnimNotify die Treffer-Pruefung (AttackTrace) aus - beim
-- Mitspieler darf die niemanden treffen (der Schaden kommt vom Host). Darum vorher die Spielerklasse in
-- ClassesToIgnore des Zombies (dort prueft AttackTrace jeden Treffer). Baeren treffen per Timer im Host.
Z.Montages, Z.Ignoring = {}, {}

Coop.HostDataHandlers.amon = function(Text)
    local SX, SY, SZ, Class, SRate, Section, Path = Text:match("^(%-?%d+);(%-?%d+);(%-?%d+);([^;]+);([%d.]+);([^;]*);(.+)$")
    if not SX then return end
    -- Nicht mitten in der Netzwerk-Verarbeitung animieren: im naechsten Frame
    ExecuteInGameThread(function()
        pcall(function()
            local X, Y, Zc = tonumber(SX), tonumber(SY), tonumber(SZ)
            local Montage = Z.Montages[Path]
            if not IsAlive(Montage) then Montage = StaticFindObject(Path) Z.Montages[Path] = Montage end
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
    Z.ZombieClass = Z.ZombieClass or StaticFindObject(Z.CLASS)
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
        -- SetCurrent&MaxHealth loest das Ereignis aus, an dem der Lebensbalken haengt (AIHealthBarUI.UpdateHealth);
        -- nur den Wert zu schreiben liess den Balken auf dem alten Stand
        if Best and pcall(function()
            local DC = Best.DamageComponent
            if Hp <= 0 or not pcall(function() DC["SetCurrent&MaxHealth"](DC, Hp, DC.MaxHealth) end) then DC.CurrentHealth = Hp end   -- 0: kein Tod beim Spieler
        end) then
            Z.HostHp[Best:GetAddress()] = Hp
            Count = Count + 1
        end
    end
    if not Z.Logged and Count > 0 then Z.Logged = true Log("Zombie-Leben vom Host uebernommen (%d)", Count) end
end

-- Mitspieler: Schaden an Zombie-Kopien neutralisieren (Pre-Hook: Schaden 0). Kein Post-Hook mehr:
-- ReceiveAnyDamage ruft Damage_Object auf, verschachtelte Post-Hooks liessen UE4SS beim Schiessen des
-- Mitspielers abstuerzen. Das Leben kommt ohnehin jede Sekunde vom Host (hp).
local function GuardPre(Context, Damage)
    if NetModeName(CurrentWorld()) ~= "Client" then return end
    local Char = Context:get()
    if not IsAlive(Char) or Char:HasAuthority() then return end
    pcall(function() Damage:set(0) end)
end

function Z.ClientTick()
    local okFx, errFx = pcall(Z.LookClientTick)
    if not okFx and not Z.LOOK.TickErr then Z.LOOK.TickErr = true Log("Zombie-Effekt-Fehler: %s", tostring(errFx)) end
    if Z.Hooked or not StaticFindObject(Z.CLASS):IsValid() then return end
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
Z.ARCH = { "Undead Sprinter", "Acidic Undead", "Bomber Undead", "Ultra-Radiated Undead", "Toughened Undead Crawler" }
Z.ARCH_FN = { "Archetype_Sprinter", "Archetype_Acidic", "Archetype_Bomber", "Archetype_UltraRadiated",
              "Archetype_ToughenedCrawler" }
Z.ACID, Z.RADIATED = 2, 4
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
                  Z.IdOf(Safe(function() return Z.PathOf(Mesh:GetSkeletalMeshAsset()) end)),
                  Z.IdOf(Safe(function() return Z.MatPath(Mesh:GetMaterial(0)) end)),
                  Z.IdOf(Safe(function() return Z.MatPath(Char.EyeLeftMesh:GetMaterial(0)) end)) }
    local Burning = Safe(function() return Char["Is Burning?"] == true end, false)
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
            Targets[#Targets + 1] = { PC = PC, Key = Key, L = Pawn:K2_GetActorLocation(), Parts = {}, Defs = {} }
        end
    end
    if #Targets == 0 then return end
    local Seen = {}
    for _, Char in ipairs(Coop.Characters()) do
        if IsAlive(Char) and Char:IsA(Z.ZombieClass) and not Coop.IsDeadAI(Char) then
            local Name, L, Sig, Ids = Char:GetFName():ToString(), Char:K2_GetActorLocation(), nil, nil
            Seen[Name] = true
            for _, T in ipairs(Targets) do
                if #T.Parts < L0.MAX_PER_TICK and (L.X - T.L.X) ^ 2 + (L.Y - T.L.Y) ^ 2 < Range2 then
                    if not Sig then Sig, Ids = Z.Signature(Char) end
                    local S = L0.Sent[T.Key][Name]
                    local Changed = not S or S.Sig ~= Sig
                    if Changed or Now >= S.Next then
                        local Count = Changed and 1 or S.Count + 1
                        L0.Sent[T.Key][Name] = { Sig = Sig, Count = Count, Next = Now + (Count < 2 and L0.AGAIN or L0.REFRESH) }
                        T.Parts[#T.Parts + 1] = string.format("%.0f;%.0f;%.0f;%s", L.X, L.Y, L.Z, Sig)
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
        if #T.Parts > 0 then Coop.SendChunked(Send, "zlook", table.concat(T.Parts, "|")) end
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

function Z.LookApply(Char, MeshPath, MatPath, EyePath, Arch, Burn)
    local L0, Name, Changed = Z.LOOK, Char:GetFName():ToString(), false
    L0.Alive[Name] = Arch   -- fuer den Tod merken (Saeure-Explosion)
    local Own = Z.ArchOf(Char)
    if Own ~= Arch then
        -- Eigenen (falschen) Typ zuruecknehmen: seine Effekte weg, Name/Lauf-Animation wie die Klasse
        for _, Field in ipairs({ "MouthFX", "ZombieMist" }) do
            pcall(function()
                local Comp = Char[Field]
                if IsAlive(Comp) then Comp:K2_DestroyComponent(Char) end
            end)
        end
        if Arch > 0 and Z.ARCH_FN[Arch] then
            Char[Z.ARCH_FN[Arch]](Char)   -- wuerfelt Modell/Material neu, das wird gleich ueberschrieben
        else
            local CDO = Char:GetClass():GetCDO()
            pcall(function() Char.Name = FText(CDO.Name:ToString()) end)
            pcall(function() Char.MovementBlendspace = CDO.MovementBlendspace end)
        end
        Changed = true
    end
    -- Strahlungsschaden rechnet nur der Host (sonst doppelt auf der eigenen Figur)
    if (Arch == Z.RADIATED or Own == Z.RADIATED) and not L0.Unrad[Name] then
        L0.Unrad[Name] = true
        pcall(function() UEHelpers.GetKismetSystemLibrary():K2_ClearTimer(Char, "Event_Rad") end)
    end
    local Mesh = Char.Mesh
    if MeshPath and Z.PathOf(Mesh:GetSkeletalMeshAsset()) ~= MeshPath then
        local Asset = Z.Asset(MeshPath)
        if Asset then Mesh:SetSkinnedAssetAndUpdate(Asset, false) Changed = true end
    end
    if MatPath and Z.MatPath(Mesh:GetMaterial(0)) ~= MatPath then
        local Asset = Z.Asset(MatPath)
        if Asset then Mesh:SetMaterial(0, Asset) Changed = true end
    end
    if EyePath then
        for _, Field in ipairs({ "EyeLeftMesh", "EyeRightMesh" }) do
            pcall(function()
                local Eye = Char[Field]
                if IsAlive(Eye) and Z.MatPath(Eye:GetMaterial(0)) ~= EyePath then
                    local Asset = Z.Asset(EyePath)
                    if Asset then Eye:SetMaterial(0, Asset) Changed = true end
                end
            end)
        end
    end
    -- Feuer: Der Schaden der eigenen Kopie wird ohnehin auf 0 gesetzt (GuardPre), das Leben kommt vom Host
    local Burning = Safe(function() return Char["Is Burning?"] == true end, false)
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
    for _, Field in ipairs({ "EyeLeftMesh", "EyeRightMesh" }) do
        pcall(function() Char[Field]:SetVisibility(false, false) end)
    end
    pcall(function() if Char["Is Burning?"] == true then Char:StopBurning() end end)
    -- Geraeusche der Figur aus (Tiere: Deer_Noises usw., das stoppt sonst nur der Host)
    pcall(function()
        Z.AudioClass = Z.AudioClass or StaticFindObject("/Script/Engine.AudioComponent")
        for _, Entry in ipairs(Char:K2_GetComponentsByClass(Z.AudioClass)) do
            local Comp = Entry.get and Entry:get() or Entry
            if IsAlive(Comp) and Comp:IsPlaying() then Comp:Stop() end
        end
    end)
    local Arch = Z.LOOK.Alive[Name] or Z.ArchOf(Char)
    if Z.LOOK.Alive[Name] ~= nil and Arch == Z.ACID then
        pcall(function() Char.MouthFX:Deactivate() end)
        Z.LOOK.Pending[#Z.LOOK.Pending + 1] = { Char = Char, At = os.clock() + 1.5 }
    end
    Z.LOOK.Alive[Name] = nil
end

function Z.AcidFx(Char)
    local L = Char.Mesh:K2_GetComponentLocation()
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
        Log("Fleisch-Kisten hier: %d", #(FindAllOf("Container_AnimalMeat_C") or {}))
    end
    for I = #P, 1, -1 do
        if Now >= P[I].At then
            local E = table.remove(P, I)
            if IsAlive(E.Char) then Z.AcidFx(E.Char) end
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
             MeatAt = nil }

function Z.AnimalDead(Char)
    return Safe(function() return Char["IsDead?"] == true or Char.Dead == true end, false)
end

function Z.AnimalHost(PCs, Guests)
    local A0 = Z.ANIMAL
    local Now, Parts, Range2 = os.time(), {}, Z.RANGE * Z.RANGE
    local Full = Now >= A0.FullAt
    if Full then A0.FullAt = Now + A0.FULL_EVERY end
    for _, Char in ipairs(FindAllOf("BP_Animal_C") or {}) do
        if IsAlive(Char) then
            local L, NearD2 = Char:K2_GetActorLocation(), math.huge
            for _, G in ipairs(Guests) do NearD2 = math.min(NearD2, (L.X - G.X) ^ 2 + (L.Y - G.Y) ^ 2) end
            if NearD2 < Range2 then
                local Name, Hp, Dead = Char:GetFName():ToString(), Safe(function() return Char.Health end), Z.AnimalDead(Char)
                local S = A0.Sent[Name]
                if S and type(Hp) == "number" and (Hp < S.Hp - 0.05 or Dead ~= S.Dead) then pcall(Z.AnimalHit, Name, S.Hp, Hp, Dead) end
                if type(Hp) == "number" and (Full or not S or S.Dead ~= Dead or math.abs(S.Hp - Hp) > 0.05) then
                    A0.Sent[Name] = { Hp = Hp, Dead = Dead }
                    Parts[#Parts + 1] = string.format("%.0f;%.0f;%.0f;%s;%.2f;%d", L.X, L.Y, L.Z,
                        Char:GetClass():GetFName():ToString(), Hp, Dead and 1 or 0)
                end
                if not Dead and NearD2 < A0.SENSE_RANGE ^ 2 then pcall(Z.AnimalSense, Char, Name, math.sqrt(NearD2) / 100) end
            end
        end
    end
    if #Parts == 0 then return end
    local Text = table.concat(Parts, "|")
    for _, PC in ipairs(PCs) do Coop.SendChunked(function(T) SendToClient(PC, T) end, "ahp", Text) end
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
    local Sees = Safe(function() return Ctrl.Blackboard:GetValueAsBool(FName("CanSeePlayer")) end)
    local Count = Safe(function()
        local Out = {}
        Ctrl:GetAIPerceptionComponent():GetCurrentlyPerceivedActors(nil, Out)
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
        if Best then
            Used[Best] = true
            local Char = Best.Char
            if pcall(function() Char.Health = tonumber(SHp) end) then Count = Count + 1 end
            if SDead == "1" and not Z.AnimalDead(Char) then
                pcall(function() Char["IsDead?"] = true end)
                pcall(function() Char.Dead = true end)
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

function Z.Reset()
    Z.HostHp, Z.Before, Z.Logged = {}, {}, nil
    Z.LOOK.Paths, Z.LOOK.Alive, Z.LOOK.Unrad, Z.LOOK.Pending, Z.LOOK.Logged = {}, {}, {}, {}, nil
    Z.ANIMAL.Logged = nil
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
    local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
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
        if F then return end
        local Riding = IsAlive(Pawn:GetAttachParentActor())   -- im Fahrzeug: Sitz nicht anfassen
        L.Frozen[Key] = { Pawn = Pawn, Damage = Pawn.bCanBeDamaged, Riding = Riding }
        pcall(function() Pawn.bCanBeDamaged = false end)
        if not Riding then
            pcall(function() Pawn.CharacterMovement:StopMovementImmediately() end)
            pcall(function() Pawn.CharacterMovement:DisableMovement() end)
        end
        Log("Mitspieler-Figur %s: seit %d s kein Lebenszeichen, eingefroren und unverwundbar", Name, Now - Last)
    elseif F then
        L.Frozen[Key] = nil
        pcall(function() Pawn.bCanBeDamaged = F.Damage end)
        if not F.Riding then pcall(function() Pawn.CharacterMovement:SetMovementMode(3, 0) end) end   -- Falling
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
    return Walk(Safe(function() return UserWidget.WidgetTree.RootWidget end), 0)
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
    if Safe(function() return CurrentWorld():GetAddress() end) ~= L.WorldAddr or not IsAlive(L.Journal) then
        L.Forget()
        L.Status = ""   -- "Connecting ..."/"Leaving ..." gelten nur bis zum Kartenwechsel
        return false
    end
    return true
end

function Coop.List.Forget()
    local L = Coop.List
    L.Journal, L.Rows, L.Tabs, L.Mode, L.Hidden, L.InfoMarker, L.Header, L.HudAddr = nil, {}, {}, nil, {}, nil, nil, nil
end

-- HUD im Bild (BP_Ingame_C, enthaelt das Journal); nil z. B. im Hauptmenue
function Coop.List.ViewHud()
    for _, W in ipairs(FindAllOf("BP_Ingame_C") or {}) do
        if IsAlive(W) and Safe(function() return W:IsInViewport() end, false) then return W end
    end
    return nil
end

-- Zu welchem HUD gehoert ein Journal? (Outer = WidgetTree des HUDs, dessen Outer = das HUD)
function Coop.List.HudOf(J) return Safe(function() return J:GetOuter():GetOuter():GetAddress() end) end

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
    local Info = J.Journal_InfoUI
    L.Journal, L.Info, L.Header, L.Rows, L.Mode, L.Hidden, L.Tabs = J, Info, Header, {}, nil, {}, {}
    L.Input, L.InputBox, L.Typing = nil, nil, nil
    L.WorldAddr = Safe(function() return CurrentWorld():GetAddress() end)
    L.HudAddr = HudAddr
    -- Abstand der Reiter (Overlay-Padding Skills -> Quests: 18 nach links, 161 nach unten); die Markierungen
    -- sind ganzseitige Bilder (1920x1080) mit dem Reiter an seiner Stelle und werden genauso verschoben
    local Step = Safe(function()
        local QB, SB = J.QuestsButton.Slot.Padding, J.SkillsButton.Slot.Padding
        return { X = QB.Left - SB.Left, Y = SB.Bottom - QB.Bottom }
    end, { X = -18, Y = 161 })
    local Base = Safe(function()
        local P = J.QuestsButton.Slot.Padding
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
                local M = L.Copy(Q, Page.WidgetTree)
                local MS = Q:GetParent():AddChildToCanvas(M)
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
        L.Selected, L.Armed = Action.Select, nil
        L.Render()
    elseif Action.Admin and L.Selected then
        local Confirm = Action.Admin == "kick" or Action.Admin == "ban"
        if Confirm and not (L.Armed == Action.Admin and os.time() - (L.ArmedAt or 0) <= 5) then
            L.Armed, L.ArmedAt = Action.Admin, os.time()
        else
            L.Armed = nil
            Coop.SendChunked(Coop.SendToHost, "admin", Action.Admin .. " #" .. L.Selected)
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
                          Action = { Select = P.N } } }
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
    for N, Name, Ping in Text:gmatch("(%d+);([^;\n]*);(%d+)") do
        List[#List + 1] = { N = tonumber(N), Name = Name, Ping = tonumber(Ping) }
    end
    ExecuteInGameThread(function()
        local L = Coop.List
        L.Players = List
        local Still = false
        for _, P in ipairs(List) do if P.N == L.Selected then Still = true end end
        if not Still then L.Selected = nil end
        if L.Mode == "admin" then pcall(L.Render) end
    end)
end

-- Antworten der DLL abholen (jede Sekunde aus der Hauptschleife)
function Coop.List.Tick()
    local L = Coop.List
    L.Setup()
    -- Admin-Rechte gelten nur auf dem Server, der sie vergeben hat
    if L.IsAdmin and NetModeName(CurrentWorld()) ~= "Client" then
        L.IsAdmin, L.Players, L.Selected = false, {}, nil
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
        local W = Safe(function() return CurrentWorld():GetAddress() end)
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

function Coop.Chat.WBL() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end

function Coop.Chat.Allowed() return NetModeName(CurrentWorld()) == "Client" end

-- Verweise ungueltig nach Kartenwechsel oder neuer Figur (neues HUD): nie mehr anfassen
function Coop.Chat.Valid()
    local C = Coop.Chat
    if not C.Hud then return false end
    if Safe(function() return CurrentWorld():GetAddress() end) ~= C.WorldAddr or not IsAlive(C.Hud) or not IsAlive(C.Box) then
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
    local Root = Safe(function() return Hud.WidgetTree.RootWidget end)
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
    C.WorldAddr = Safe(function() return CurrentWorld():GetAddress() end)
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
    -- Nur im Spiel selbst, nicht in Menues/Inventar (dort ist der Mauszeiger an)
    if Safe(function() return PC.bShowMouseCursor end, false) then return end
    C.Open, C.OpenedAt = true, os.clock()
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
    pcall(function() C.WBL():SetInputMode_GameOnly(LocalPC(), false) end)
    C.Render()
end

function Coop.Chat.OnEnter()
    local C = Coop.Chat
    if not C.Open or os.clock() - (C.OpenedAt or 0) < 0.3 then return end   -- Chat-Taste Enter: nicht gleich senden
    local Text = C.Valid() and Safe(function() return C.Edit:GetText():ToString() end, "") or ""
    C.Close()
    Text = Text:gsub("[%c|]", " "):match("^%s*(.-)%s*$")
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
        local Amount = math.max(1, math.floor((Safe(function() return Button.DebugMenu.Amount end, 1) or 1) + 0.5))
        Coop.Cheat.Saved[Button:GetAddress()] = { Field = "ItemID", Value = Item }
        Button.ItemID = nil
        Coop.SendChunked(Coop.SendToHost, "admin", "give " .. Coop.Cheat.Path(Item) .. " " .. Amount)
        return
    end
    local Class = Safe(function() return Button.Item end)
    if IsAlive(Class) then
        Coop.Cheat.Saved[Button:GetAddress()] = { Field = "Item", Value = Class }
        Button.Item = nil
        Coop.SendChunked(Coop.SendToHost, "admin", "vehicle " .. Coop.Cheat.Path(Class))
    end
end

function Coop.Cheat.OnClickPost(Self)
    local Button = Self:get()
    local Key = Button:GetAddress()
    local S = Coop.Cheat.Saved[Key]
    if not S then return end
    Coop.Cheat.Saved[Key] = nil
    Button[S.Field] = S.Value
end

-- Hooks erst, wenn die Widget-Klassen geladen sind (beim ersten Oeffnen des Menues)
function Coop.Cheat.Hook()
    local C = Coop.Cheat
    for _, Class in ipairs(C.BUTTONS) do
        if not C.Hooked[Class] and IsAlive(StaticFindObject(Class)) then
            C.Hooked[Class] = true
            TryHook(Class .. ":" .. C.CLICK,
                function(Self) local ok, err = pcall(C.OnClickPre, Self) if not ok then Log("Cheat-Menue: %s", tostring(err)) end end,
                function(Self) pcall(C.OnClickPost, Self) end)
        end
    end
    if not C.Hooked.Menu and IsAlive(StaticFindObject(C.MENU)) then
        C.Hooked.Menu = true
        TryHook(C.MENU .. ":ChangeWeather", function(_, Preset)
            pcall(function()
                if C.Forward() then Coop.SendChunked(Coop.SendToHost, "admin", "weatherpreset " .. Preset:get():GetFName():ToString()) end
            end)
        end)
        for _, Event in ipairs(C.DILATION) do
            TryHook(C.MENU .. ":" .. Event, function() end, function() C.DilationDirty = true end)
        end
        -- gleich beim Oeffnen: freie Kamera aus (siehe Tick)
        TryHook(C.MENU .. ":Construct", function() end, function(Self)
            if NetModeName(CurrentWorld()) == "Client" then
                pcall(function() Self:get().SpawnCameraButton:SetIsEnabled(false) end)
            end
        end)
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
        local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
        local Menu = IsAlive(Pawn) and Safe(function() return Pawn.DebugMenu end)
        if not Want then
            if IsAlive(Menu) then
                pcall(function() Pawn:CloseDebugMenu() end)
                Log("Cheat-Menue geschlossen: nur fuer Admins")
            end
        elseif IsAlive(Menu) then
            -- Freie Kamera geht als Mitspieler nicht (Possess nur beim Server): HUD war weg, kam nicht wieder
            pcall(function() Menu.SpawnCameraButton:SetIsEnabled(false) end)
        end
    elseif C.Allow ~= nil then
        RunCommand("Debug.Allow " .. (C.Allow and "1" or "0"))
        C.Allow, C.Set = nil, nil
    end
    C.Hook()
    if C.DilationDirty and C.Forward() then
        C.DilationDirty = false
        local Value = Safe(function() return CurrentWorld():K2_GetWorldSettings().TimeDilation end)
        if type(Value) == "number" then Coop.SendChunked(Coop.SendToHost, "admin", string.format("dilation %.3f", Value)) end
    end
end
end

do
-- Fahrzeuge auf dem Server. Das Spiel kennt Fahrzeuge nur fuer einen Spieler: Einsteigen haengt die Figur
-- nur lokal ans Auto (kein Possess), Gas/Lenkung gehen lokal an die ChaosVehicleMovementComponent, Tank und
-- Schaden (FuelComponent, VehicleHealthComponent) sind nicht repliziert, Kanister/Reparaturset sucht es im
-- lokalen Inventar (beim Mitspieler leer, das Inventar liegt beim Server).
-- Fahren wie in den meisten UE-Spielen mit Physik-Fahrzeugen, fahrer-autoritativ: Der Fahrer rechnet sein Auto
-- selbst (lokal keine Bewegungs-Replikation mehr, also kein Zurueckziehen) und schickt ~15x/s Lage und
-- Geschwindigkeit ("car": pose). Der Server setzt sein Auto darauf, die normale Replikation zeigt es allen
-- anderen (die Physik-Replikation glaettet). Solange gefahren wird, ignoriert das Auto beim Server Spieler
-- (wie beim Fahrer lokal), sonst schiebt die Figur des Fahrers es weg.
-- Tanken/Reparieren: Die lokale Pruefung schlaegt fehl ("No gas found"); stattdessen zieht der Server den
-- Gegenstand aus dem Inventar ab und schickt Tank/Zustand an alle ("carstate").
Coop.Car = { SeatCheck = {}, NoColl = {}, RATE = 1 / 15, NEAR = 800, Drivers = {}, Passengers = {}, Hooked = {},
             CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
             JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C",
             NOTE = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C",
             ITEMS = { gas = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
                       repair = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit" },
             FAILED = { ["No gas found"] = "Using gas can ...", ["No repair kits found"] = "Using repair kit ..." } }

function Coop.Car.Nearest(Loc, Max)
    local Best, BestD = nil, Max * Max
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if IsAlive(V) then
            local P = V:K2_GetActorLocation()
            local D = (P.X - Loc.X) ^ 2 + (P.Y - Loc.Y) ^ 2 + (P.Z - Loc.Z) ^ 2
            if D < BestD then Best, BestD = V, D end
        end
    end
    return Best
end

function Coop.Car.Mesh(V) return Safe(function() return V.Mesh end) or V:K2_GetRootComponent() end

function Coop.Car.State(V)
    local F, H = V.FuelComponent, V.VehicleHealthComponent
    return string.format("%.1f|%.1f|%.1f|%.1f", F.CurrentFuel, F.MaxFuel, H.CurrentHealth, H.MaxHealth)
end

-- Tank/Zustand uebernehmen (Repaired: Rauch/Feuer aus, Motor an), Anzeigen am Auto mit
function Coop.Car.ApplyState(V, Fuel, MaxFuel, Health, MaxHealth, Repaired)
    pcall(function()
        V.FuelComponent.CurrentFuel = Fuel
        V.FuelComponent.Empty = Fuel <= 0
    end)
    pcall(function() V.VehicleHealthComponent.CurrentHealth = Health end)
    -- Rauch (<= 30) und Feuer (<= 10) wie das Spiel nach dem Laden (VehicleHealth: schaltet beides an und aus)
    pcall(function() V:VehicleHealth() end)
    if Repaired then pcall(function() V["EngineOn?"] = true end) end
    pcall(function() V.FuelWidget:GetUserWidgetObject():UpdateFuel(Fuel, MaxFuel) end)
    pcall(function() V.RepairWidget:GetUserWidgetObject():UpdateHealth(Health, MaxHealth) end)
    if V == Coop.Car.Looking then pcall(Coop.Car.ShowStats, V) end
end

-- Anzeige "Fuel"/"Health" beim Anschauen des Autos: Das Spiel fuellt sie ueber die Server-RPCs Svr_UpdateFuel/
-- Svr_UpdateEngine (OnBeginInteract), die beim Mitspieler ohne Besitz am Auto verworfen werden -> selbst setzen,
-- gleicher Text wie das Spiel ("73%")
function Coop.Car.ShowStats(V)
    local Hud = Safe(function() return LocalPC().MyHUD end)
    if not IsAlive(Hud) then Hud = FindFirstOf("HUD_Game_C") end
    if not IsAlive(Hud) then return end
    local F, H = V.FuelComponent, V.VehicleHealthComponent
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
    local Seated = Pawn.CharacterMovement.MovementMode == 0
        and Safe(function() return Pawn.Mesh:IsSimulatingPhysics(FName("None")) end, true) == false
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

function Coop.Car.OnTick(Self)
    local C = Coop.Car
    if not C.Active then return end
    local Pawn = Self:get()
    if Pawn:GetAddress() ~= C.LocalAddr then
        if C.LocalAddr then C.CheckSeated(Pawn) end
        return
    end
    pcall(Coop.AmmoHold, Pawn)
    local V = Pawn["InVehicle?"] and Safe(function() return Pawn.VehicleDrivingComponent.Vehicle end)
    if not IsAlive(V) then V = nil end
    if V ~= C.Driving then
        if C.Driving then C.Stop() end
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
            Coop.SendChunked(Coop.SendToHost, "car", string.format("start|%.0f|%.0f|%.0f", P.X, P.Y, P.Z))
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
        -- ohne Antwort (alter Server, verlorene Nachricht) nach 1,5 s trotzdem selbst fahren
        if os.clock() - (C.EnterAt or 0) < 1.5 then return end
        C.StartDriving(V)
    end
    local Now = os.clock()
    if Now - C.SentAt < C.RATE then return end
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
    C.SavedMove = Safe(function() return Pawn.VehicleDrivingComponent.VehicleMovementComponent end)
    pcall(function() Pawn.VehicleDrivingComponent.VehicleMovementComponent = nil end)
    pcall(function() V.GetOutPasseenger = true end)
    pcall(function()
        local R = Pawn:K2_GetRootComponent().RelativeLocation
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
    -- Die Replikation kann die Physik des Autos hier abgeschaltet haben (ruhendes Auto): wieder an, aufwecken
    local Mesh = C.Mesh(V)
    local Sim = Safe(function() return Mesh:IsSimulatingPhysics(FName("None")) end)
    if Sim == false then pcall(function() Mesh:SetSimulatePhysics(true) end) end
    pcall(function() Mesh:WakeAllRigidBodies() end)
    Log("Fahrzeug: fahre %s selbst (Physik %s, Motor %s, Tank %s)", V:GetFName():ToString(), tostring(Sim),
        tostring(Safe(function() return V["EngineOn?"] end)), tostring(Safe(function() return math.floor(V.FuelComponent.CurrentFuel) end)))
end

function Coop.Car.SetMoveTick(Pawn, On)
    if IsAlive(Pawn) then pcall(function() Pawn.CharacterMovement:SetComponentTickEnabled(On) end) end
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
    C.SetMoveTick(Safe(function() return LocalPC():K2_GetPawn() end), true)
    if C.PassengerOf and C.PassengerOf == C.Driving then
        local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
        if IsAlive(Pawn) and IsAlive(C.SavedMove) then
            pcall(function() Pawn.VehicleDrivingComponent.VehicleMovementComponent = C.SavedMove end)
        end
        if IsAlive(C.Driving) then pcall(function() C.Driving.GetOutPasseenger = false end) end
    elseif IsAlive(C.Driving) and C.Confirmed then
        -- Bewegung vom Server erst wieder annehmen, wenn sein Auto steht: Lagen eines noch rollenden Autos blieben
        -- als Physik-Ziel haengen und hielten das Auto beim sofortigen Wiedereinsteigen fest
        C.Resume = { V = C.Driving, At = os.clock() + 4 }
    end
    C.Driving, C.PassengerOf, C.PassengerSet, C.SavedMove, C.Confirmed, C.SeatAt = nil, nil, nil, nil, false, nil
    -- eigene Lage nach dem Aussteigen mit: der Server stellt die Figur dorthin (sonst zog er sie zurueck)
    local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
    local P = IsAlive(Pawn) and Pawn:K2_GetActorLocation()
    Coop.SendChunked(Coop.SendToHost, "car", P and string.format("stop|%.1f|%.1f|%.1f|%.1f", P.X, P.Y, P.Z, Pawn:K2_GetActorRotation().Yaw) or "stop")
    Log("Fahrzeug: ausgestiegen")
end

-- Mitspieler: Kanister/Reparaturset aus dem eigenen Inventar (lokal leer) -> beim Server abziehen lassen
function Coop.Car.OnConsume(Self, Item)
    local C = Coop.Car
    if NetModeName(CurrentWorld()) ~= "Client" then return end
    local Path = Safe(function() return Item:get():GetFullName():match("^%S+%s+(%S+)$") end)
    local What
    for K, P in pairs(C.ITEMS) do if P == Path then What = K end end
    if not What then return end
    local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
    if not IsAlive(Pawn) or Self:get():GetAddress() ~= Safe(function() return Pawn.BP_JigMultiplayer:GetAddress() end) then
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
    local Pawn = C.Active and Safe(function() return LocalPC():K2_GetPawn() end)
    C.LocalAddr = IsAlive(Pawn) and Pawn:GetAddress() or nil
    if C.Driving and (not C.Active or not IsAlive(C.Driving)) then
        if C.Active then C.Stop() else C.Driving = nil end
    end
    if C.Resume and (os.clock() >= C.Resume.At or not C.Active) then
        local V = C.Resume.V
        C.Resume = nil
        if IsAlive(V) and V ~= C.Driving then pcall(function() V:SetReplicateMovement(true) end) end
    end
    if not C.Hooked.Char and IsAlive(StaticFindObject(C.CHAR)) then
        C.Hooked.Char = true
        TryHook(C.CHAR .. ":ReceiveTick", function(Self)
            local ok, err = pcall(C.OnTick, Self)
            if not ok and not C.TickErr then C.TickErr = true Log("Fahrzeug-Fehler: %s", tostring(err)) end
        end)
    end
    if not C.Hooked.Jig and IsAlive(StaticFindObject(C.JIG)) then
        C.Hooked.Jig = true
        TryHook(C.JIG .. ":ServerFindThenConsumeByItemID", function(Self, Item) pcall(C.OnConsume, Self, Item) end)
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
            TryHook(Path .. ":OnBeginInteract", function() end, function(Self)
                if not Coop.Car.Active then return end
                local V = Self:get()
                Coop.Car.Looking = V
                ExecuteInGameThread(function() pcall(Coop.Car.ShowStats, V) end)
            end)
            TryHook(Path .. ":OnEndInteract", function() Coop.Car.Looking = nil end)
        end
    end
    if not C.Hooked.Note and IsAlive(StaticFindObject(C.NOTE)) then
        C.Hooked.Note = true
        TryHook(C.NOTE .. ":CreateNotificationUI", function(Self, Message) pcall(C.OnNote, Self, Message) end)
    end
end

-- Server: Nachrichten eines Mitspielers (im Netzwerk-Hook: Arbeit ins naechste Bild)
function Coop.Car.OnClient(PC, Data)
    local Key = PC:GetFullName()
    ExecuteInGameThread(function()
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
        local S, P, Yaw = V.PlayerLocation:K2_GetComponentLocation(), V:K2_GetActorLocation(), math.rad(-V:K2_GetActorRotation().Yaw)
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
    if D and IsAlive(D.Pawn) then
        if At then
            pcall(function()
                D.Pawn:K2_SetActorLocationAndRotation({ X = At.X, Y = At.Y, Z = At.Z }, { Pitch = 0, Yaw = At.Yaw, Roll = 0 }, false, {}, true)
            end)
        end
        pcall(function() D.Pawn.CharacterMovement:SetMovementMode(1, 0) end)   -- Walking
        pcall(function() D.Pawn:StopAnimMontage(nil) end)
        local Id = Safe(function() return D.PC.PlayerState.PlayerId end)
        if Id then
            for _, PS in ipairs(PlayerStates(CurrentWorld())) do
                local Other = PS:GetOwner()
                if IsAlive(Other) and Safe(function() return not Other:IsLocalController() end, false) then
                    Coop.SendChunked(function(T) Coop.SendToClient(Other, T) end, "carexit", tostring(Id))
                end
            end
        end
    end
    if D and D.Passenger then return end
    if D and IsAlive(D.V) then
        pcall(function() Coop.Car.Mesh(D.V):SetCollisionResponseToChannel(2, 2) end)   -- Pawn: Block
        pcall(function() D.V:SetOwner(nil) end)
        -- ohne Fahrer stehen bleiben (sonst rollt es mit den letzten Eingaben weiter)
        pcall(function()
            local M = D.V.VehicleMovementComponent
            M:SetThrottleInput(0)
            M:SetBrakeInput(0)
            M:SetSteeringInput(0)
            M:SetHandbrakeInput(true)
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
        if F[17] then C.ApplyState(V, N(14), N(15), N(16), N(17), false) end
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
        local V = C.Nearest({ X = N(2), Y = N(3), Z = N(4) }, C.NEAR)
        if not V then Log("Fahrzeug: kein Auto beim Mitspieler gefunden") return end
        local Pawn = PC:K2_GetPawn()
        Pawn = IsAlive(Pawn) and Pawn or nil
        if Pawn then pcall(function() Pawn.CharacterMovement:DisableMovement() end) end
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
        if Pawn then pcall(C.PlacePawn, Pawn, V, false) end
        pcall(function() C.Mesh(V):SetCollisionResponseToChannel(2, 0) end)   -- Pawn: Ignore (wie beim Fahrer)
        pcall(function() V.VehicleMovementComponent:SetHandbrakeInput(false) end)
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
        C.SendAll(PC, Key)
    elseif Cmd == "svc" then
        local What, Pawn = F[2], PC:K2_GetPawn()
        local V = C.Nearest({ X = N(3), Y = N(4), Z = N(5) }, 500)
        if not (V and IsAlive(Pawn) and C.ITEMS[What]) then
            Log("Fahrzeug: %s abgelehnt (Auto %s, Figur %s)", tostring(What), tostring(V ~= nil), tostring(IsAlive(Pawn)))
            return
        end
        local Item = StaticFindObject(C.ITEMS[What])
        if not IsAlive(Item) then Item = Safe(function() return LoadAsset(C.ITEMS[What]) end) end
        local Out = {}
        local R = Safe(function() return Pawn.BP_JigMultiplayer:ServerFindThenConsumeByItemID(Item, 1, Out) end)
        local Note = function(T) Coop.SendChunked(function(X) Coop.SendToClient(PC, X) end, "note", T) end
        if not (R == true or Out.Result == true) then
            Log("Fahrzeug: %s - nichts im Inventar (Antwort %s/%s)", What, tostring(R), tostring(Out.Result))
            Note(What == "gas" and "No gas can in your inventory" or "No repair kit in your inventory")
            return
        end
        -- Stand vom Mitspieler (sein Auto ist das aktuelle), sonst der des Servers
        local Fuel, MaxFuel, Health, MaxHealth = N(6), N(7), N(8), N(9)
        if MaxFuel <= 0 then
            local S = {}
            for X in (C.State(V) .. "|"):gmatch("([^|]*)|") do S[#S + 1] = tonumber(X) end
            Fuel, MaxFuel, Health, MaxHealth = S[1], S[2], S[3], S[4]
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
    local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
    if not IsAlive(Pawn) or Comp:get():GetAddress() ~= Safe(function() return Pawn.BP_JigMultiplayer:GetAddress() end) then return end
    local Path = Safe(function() return Item:get():GetFullName():match("^%S+%s+(%S+)$") end)
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
            for _, L in ipairs(C.Known[Key] and Changed or All) do
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
        local Preset = Safe(function() return Weather.Weather:GetPathName() end)
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
    World.StreamingLevels:ForEach(function(_, Entry)
        local Level = Entry:get()
        if Level:ShouldBeLoaded() and Level:GetWorldAssetPackageFName():ToString():find("/MainMenu$") then
            Level:SetShouldBeVisible(false)
            Level:SetShouldBeLoaded(false)
            Log("Hauptmenue-Teillevel beim Mitspieler entladen (zweiter Himmel)")
        end
    end)
end
Coop.UnloadMenuLevel = S.UnloadMenuLevel
Coop.ResetSky = function() S.FirstSkyAt, S.OverridesCleared, S.ClientCountLogged, S.ReplLogged = nil, nil, nil, nil end

function S.HostTick(World)
    if NetModeName(World) ~= "ListenServer" or os.time() < S.At then return end
    S.At = os.time() + S.EVERY
    local PCs = {}
    for _, PS in ipairs(PlayerStates(World)) do
        local PC = PS:GetOwner()
        if IsAlive(PC) and Safe(function() return not PC:IsLocalController() end, false) then PCs[#PCs + 1] = PC end
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
        local Cur = Safe(function() return Weather.Weather:GetPathName() end)
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
-- sichtbar genau dann, wenn die aktuelle Schusswaffe in der rechten Hand (Socket Weapon_r) haengt.
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

function H.FirearmInHand(Pawn)
    local Attached = {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local W = Entry:get()
        if W:GetAttachParentSocketName():ToString() == "Weapon_r" and H.IsFirearm(W) then return true, W end
    end
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

-- Das Spiel blendet die Anzeige auch ueber Animationen (Deckkraft) ein und aus. Stand die verkehrt auf
-- 0, half das Sichtbar-Schalten nichts: beim Einblenden darum auch die Deckkraft auf 1 setzen.
function H.Check()
    if not MultiplayerActive or NetModeName(CurrentWorld()) ~= "Client" then return end  -- nur der Mitspieler war betroffen
    local Pawn = LocalPC():K2_GetPawn()
    if not IsAlive(Pawn) then return end
    local UI = Safe(function() return Pawn.InGameUI end)
    local Box = Safe(function() return UI.AmmoBox end)
    if not IsAlive(Box) then return end
    local Want, Weapon = H.FirearmInHand(Pawn)
    if Want then
        local ok, err = pcall(H.FixAmmoCount, Pawn, Weapon)
        if not ok and not H.FixErr then H.FixErr = true Log("Munitions-Zahl-Fehler: %s", tostring(err)) end
    end
    local Vis = Box:GetVisibility()
    local Shown = Vis ~= 1 and Vis ~= 2
    if Want ~= Shown then Box:SetVisibility(Want and H.VISIBLE or H.HIDDEN) end
    if Want then
        for _, Name in ipairs({ "AmmoBox", "CurrentAmmoTxt", "MaxAmmoTxt", "CurrentFirearmName" }) do
            pcall(function()
                local W = UI[Name]
                if W:GetRenderOpacity() < 0.99 then W:SetRenderOpacity(1.0) end
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
-- aus dem Bild-Tick der eigenen Figur (Coop.Car.OnTick), keine eigene Schleife.
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
local N = { MAX_PER_SECOND = 10, Second = 0, Count = 0 }

-- Nur beim Spieler: Auf dem Server meldet OnGuestNoise selbst ReportNoiseEvent (das waere ein Hook im Hook)
if os.getenv("LASTSIGNAL_SERVER") ~= "1" and os.getenv("NETTEST_SERVER") ~= "1" then
    TryHook("/Script/AIModule.AISense_Hearing:ReportNoiseEvent", function(_, _, Location, Loudness, Instigator, MaxRange, Tag)
        if N.Sending or NetModeName(CurrentWorld()) ~= "Client" then return end
        local ok, err = pcall(function()
            -- Den Verursacher NIE anfassen (IsAlive/IsA): Er kann schon zerstoert sein (Geschoss, toter Zombie), UE4SS
            -- warf dann Fehler und das Spiel stuerzte ab (20.10. 05:47, 0x70; vermutlich viele "Abstuerze beim Schiessen").
            -- Nur die Adresse vergleichen: eigene Figur oder gar kein Verursacher (z. B. Sirene) -> an den Host.
            local Source = Instigator:get()
            local Addr = Source and Safe(function() return Source:GetAddress() end, 0) or 0
            local Pawn = LocalPC():K2_GetPawn()
            local Own = Addr ~= 0 and IsAlive(Pawn) and Addr == Pawn:GetAddress()
            if not Own and Addr ~= 0 then return end  -- andere Verursacher: meldet der Host selbst
            local Now = os.time()
            if Now ~= N.Second then N.Second, N.Count = Now, 0 end
            if N.Count >= N.MAX_PER_SECOND then return end
            N.Count = N.Count + 1
            if Coop.Shot then Coop.Shot.Count("geraeusch_gesendet", Tag:get():ToString() .. "/" .. MaxRange:get()) end
            local L = Location:get()
            Coop.SendChunked(Coop.SendToHost, "noise", string.format("%.0f;%.0f;%.0f;%.3f;%.0f;%s;%s", L.X, L.Y, L.Z,
                Loudness:get(), MaxRange:get(), Tag:get():ToString(), Own and "1" or "0"))
        end)
        if not ok then Log("Geraeusch-Fehler: %s", tostring(err)) end
    end)
end

-- Host: Geraeusch eines Mitspielers fuer die KI melden.
Coop.OnGuestNoise = function(PC, Data)
    local X, Y, Z, Loud, Range, Tag, Own = Data:match("^(%-?%d+);(%-?%d+);(%-?%d+);([%d.]+);(%d+);([^;]*);([01])$")
    if not X then return end
    local Pawn = Own == "1" and PC:K2_GetPawn() or nil
    N.Hearing = N.Hearing or StaticFindObject("/Script/AIModule.Default__AISense_Hearing")
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
            Remote = 0, Own = 0, Stack = {}, Hooked = {}, Counts = {}, Names = {}, LogAt = 0 }
Coop.Shot = S

function S.Count(Key, Name)
    S.Counts[Key] = (S.Counts[Key] or 0) + 1
    if Name and not S.Names[Key] then S.Names[Key] = tostring(Name) end
    S.Dirty = true
end

local function NameOf(Param)
    return Safe(function() return Param:get():GetFName():ToString() end, "?")
end

-- Gehoert der Schuetze (Waffe: Traeger, Figur: sie selbst) nicht zur eigenen Figur?
function S.IsRemote(Actor)
    local Own = Safe(function() return LocalPC():K2_GetPawn() end)
    if not IsAlive(Own) or not IsAlive(Actor) then return false end
    S.PawnClass = S.PawnClass or StaticFindObject("/Script/Engine.Pawn")
    local Holder = Actor
    if not Actor:IsA(S.PawnClass) then
        Holder = Safe(function() return Actor:GetAttachParentActor() end)
        if not IsAlive(Holder) then Holder = Safe(function() return Actor:GetOwner() end) end
        if not IsAlive(Holder) then return false end
    end
    return Holder:GetAddress() ~= Own:GetAddress()
end

-- Schussgeraeusch fremder Schuesse: Das Spiel spielt es nur beim Schuetzen selbst. MC_WeaponEffects kommt bei jedem
-- Schuss bei allen an (Muendungsfeuer; mit Schalldaempfer das gedaempfte) -> hier den Ton der Waffe abspielen.
function S.PlayRemote(W, Particle)
    if not IsAlive(W) then return end
    local Now, Key = os.clock(), W:GetAddress()
    S.LastSound = S.LastSound or {}
    if Now - (S.LastSound[Key] or 0) < 0.05 then return end
    S.LastSound[Key] = Now
    local WC = Coop.Scope.Comp(W, "BP_WeaponsPickupComponent_C")
    if not WC then return end
    local Flash = Safe(function() return Particle:get() end)
    local Quiet = WC["SuppressorAttached?"] == true
    if IsAlive(Flash) and IsAlive(WC.SuppressedMuzzleFlash) then Quiet = Flash:GetAddress() == WC.SuppressedMuzzleFlash:GetAddress() end
    local Sound = Quiet and WC.FirearmSuppressedSound or WC.FirearmSound
    if not IsAlive(Sound) then Sound = WC.FirearmSound end
    if not IsAlive(Sound) then S.Count("ton_fremd_FEHLT") return end
    S.GS = S.GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    S.GS:PlaySoundAtLocation(W, Sound, W:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil)
    S.Count(Quiet and "ton_fremd_gedaempft" or "ton_fremd_gespielt", Sound:GetFName():ToString())
end

local function Pre(Key)
    return function(Self, ...)
        local Kind = "eigen"
        pcall(function()
            if NetModeName(CurrentWorld()) ~= "Client" then Kind = "server"
            elseif S.IsRemote(Self:get()) then Kind = "fremd" end
        end)
        S.Count(Kind .. "_" .. Key)
        if Kind == "fremd" and Key == "MC_WeaponEffects" then
            local Particle = ...
            pcall(S.PlayRemote, Self:get(), Particle)
        end
        S.Stack[#S.Stack + 1] = Kind
        if Kind == "fremd" then S.Remote = S.Remote + 1 elseif Kind == "eigen" then S.Own = S.Own + 1 end
    end
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

function S.Tick()
    S.Remote, S.Own, S.Stack = 0, 0, {}
    if not S.Hooked.Engine then
        S.Hooked.Engine = true
        TryHook("/Script/Engine.PlayerCameraManager:StartCameraShake",
            Mute("StartCameraShake", function(_, _, Scale) Scale:set(0) end))
        TryHook("/Script/Engine.PlayerController:ClientStartCameraShake",
            Mute("ClientStartCameraShake", function(_, _, Scale) Scale:set(0) end))
        TryHook("/Script/Engine.GameplayStatics:PlayWorldCameraShake",
            Mute("PlayWorldCameraShake", function(_, _, _, _, Inner, Outer) Inner:set(0) Outer:set(0) end))
    end
    if not S.Hooked.Weapon and IsAlive(StaticFindObject(S.WEAPON)) then
        S.Hooked.Weapon = true
        for _, Fn in ipairs({ "MC_WeaponShot", "MC_WeaponEffects", "Svr_WeaponShot" }) do
            TryHook(S.WEAPON .. ":" .. Fn, Pre(Fn), Post)
        end
    end
    if not S.Hooked.Char and IsAlive(StaticFindObject(S.CHAR)) then
        S.Hooked.Char = true
        TryHook(S.CHAR .. ":CameraShake", Pre("CameraShake"), Post)
        TryHook(S.CHAR .. ":Client_CameraShake", Mute("Client_CameraShake", function(_, Shake) Shake:set(nil) end))
        TryHook(S.CHAR .. ":MC_PlaySoundAtLocation", function(_, Sound) S.Count("MC_PlaySoundAtLocation", NameOf(Sound)) end)
    end
    if not S.Hooked.PC then
        local PC = Safe(LocalPC)
        local Path = IsAlive(PC) and Safe(function() return PC:GetClass():GetFullName():match("^%S+%s+(%S+)$") end)
        if Path and Path:match("BP_PlayerController") then
            S.Hooked.PC = true
            TryHook(Path .. ":CameraShake", Mute("PC.CameraShake", function(_, Shake) Shake:set(nil) end))
            TryHook(Path .. ":CameraShakeClient", Mute("PC.CameraShakeClient", function(_, _, Scale) Scale:set(0) end))
        end
    end
    if S.Dirty and os.time() >= S.LogAt then
        local Parts = {}
        for Key, N in pairs(S.Counts) do
            Parts[#Parts + 1] = Key .. "=" .. N .. (S.Names[Key] and ("(" .. S.Names[Key] .. ")") or "")
        end
        table.sort(Parts)
        Log("Schuss-Diagnose: %s", table.concat(Parts, " "))
        S.Counts, S.Names, S.Dirty, S.LogAt = {}, {}, false, os.time() + 10
    end
end
end

do
-- Fehlersuche Inventar (Fallenlassen, Aufheben, Anlegen): zaehlt die Netzwerk-Eingaenge (ONLY) von
-- BP_JigMultiplayer und BP_JigHelperComp (Server: was ankommt, Spieler: was zurueckkommt) und TryPickup/JSI_* beim
-- Spieler. Bei bekannten Actor-Parametern: Name, Rolle, repliziert, aus der Karte. Alle 10 s im Log.
local D = { Hooked = {}, Counts = {}, Detail = {}, LogAt = 0 }
Coop.InvDiag = D
-- Nur Netzwerk-Eingaenge (vom Netz oder von der Eingabe aufgerufen, nicht voneinander): 81 Hooks auf alle
-- Inventar-Funktionen liessen das Spiel einfrieren (Hooks in Hooks, Spiel-Thread wartete in UE4SS, 20.10. 05:29)
local ONLY = { SERVER_RequestDropItem = true, SERVER_RequestAddActorToContainer = true, SERVER_RequestActorAddStackItem = true,
               SERVER_RequestEquipActorToContainer = true, CLIENT_DropRequestFailed = true,
               CLIENT_RequestEquipResponseFailed = true, CLIENT_EquipActorSuccess = true, TryPickup = true,
               JSI_TryEquipToMain = true }
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

function D.HookClass(Path)
    local Class = StaticFindObject(Path)
    if not IsAlive(Class) then return false end
    local Names, N = {}, 0
    Class:ForEachFunction(function(Func) Names[#Names + 1] = Func:GetFName():ToString() end)
    for _, Name in ipairs(Names) do
        if ONLY[Name] then
            local Index = DESCRIBE[Name]
            local Post = nil
            if Name == "JSI_TryEquipToMain" then
                Post = function(_, _, _, _, EquipTo)
                    D.Count("JSI_TryEquipToMain->" .. (IsAlive(Safe(function() return EquipTo:get() end)) and "ziel" or "KEIN_ZIEL"))
                end
            end
            if TryHook(Path .. ":" .. Name, function(_, ...) D.Count(Name, Index and D.Describe(Index, ...) or nil) end, Post) then
                N = N + 1
            end
        end
    end
    Log("Inventar-Diagnose: %d Funktionen in %s", N, Path:match("[^%.]+$") or Path)
    return true
end

function D.Tick()
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
end

do
-- Zielfernrohr beim Spieler: Waffe aus einer Kiste direkt in den Waffen-Slot gezogen -> nur Zoom, kein Scope.
-- Die Waffe entsteht dabei auf dem Server; ihre Aufsaetze (RepAttachments, repliziert) baut das Spiel beim
-- Spieler offenbar nicht ein (InstalledAttachments leer, SightAttached? false). Darum: Waffe in der Hand mit
-- replizierten, aber nicht eingebauten Aufsaetzen -> nach 2 s OnRep_RepAttachments, nach 4 s ProcessAttachments.
local P = { ATTACH = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969", Weapon = nil, Since = 0, Step = 0 }
Coop.Scope = P

function P.Held(Pawn)
    local Attached = {}
    Pawn:GetAttachedActors(Attached, true, false)
    for _, Entry in ipairs(Attached) do
        local A = Entry:get()
        if IsAlive(A) and A:GetAttachParentSocketName():ToString() == "Weapon_r" then return A end
    end
end

function P.Comp(Actor, Name)
    P[Name] = P[Name] or Safe(function() return FindFirstOf(Name):GetClass() end)
    if not IsAlive(P[Name]) then P[Name] = nil return nil end
    local C = Actor:GetComponentByClass(P[Name])
    return IsAlive(C) and C or nil
end

function P.Tick()
    if NetModeName(CurrentWorld()) ~= "Client" then return end
    local Pawn = Safe(function() return LocalPC():K2_GetPawn() end)
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
                pcall(function() Widget[Part]:SetVisibility(4) end)
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
            local Rep = Root and Item.AttachmentReplication
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
-- bitten - hoechstens alle 10 s. Einmal Nachsenden brachte die Schuhe zurueck.
Coop.Cloth = { SLOTS = { { "ClothingTorsoEquipped?", "Clothing_Torso" }, { "ClothingGlovesEquipped?", "Clothing_Gloves" },
                         { "ClothingLegsEquipped?", "Clothing_Legs" }, { "ClothingFeetEquipped?", "Clothing_Feet" } },
               AskedAt = 0, Asked = 0 }

Coop.Cloth.ClientTick = function()
    local Now = os.time()
    if Now - Coop.Cloth.AskedAt < 10 then return end
    for _, Pawn in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if IsAlive(Pawn) and IsAlive(Pawn.PlayerState) then
            for Index, Slot in ipairs(Coop.Cloth.SLOTS) do
                local Missing = Safe(function()
                    if Pawn[Slot[1]] ~= true then return false end
                    local Asset = Pawn[Slot[2]]:GetSkeletalMeshAsset()
                    return not (Asset and Asset:IsValid())
                end, false)
                if Missing then
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

local function HandleClient(World)
    local Connected = false
    if NetModeName(World) == "Client" then
        local NetDriver = Safe(function() return World.NetDriver end)
        Connected = NetDriver and NetDriver:IsValid() and NetDriver.ServerConnection:IsValid() or false
    end
    if not Connected then
        ClientConnectedSince, MenuClosed, LastClientPawn, ClientPawnSince = nil, false, nil, nil
        GhostWatch, GhostScanDone, PendingActors = false, false, {}
        Coop.ResetClientInventory()
        Coop.ResetGuestId()
        Coop.ResetCorpses()
        Coop.ResetSky()
        Coop.Zombies.Reset()
        PossessReplayed, HudChecked = false, false
        return
    end
    local Now = os.time()
    ClientConnectedSince = ClientConnectedSince or Now
    if not MenuClosed and Now - ClientConnectedSince >= SPAWN_DELAY then
        MenuClosed = true
        SetupClient()
    end
    -- Sobald der Host uns eine Figur gibt (oder eine neue), Menue und Steuerung erneut einrichten.
    local Pawn = LocalPC():K2_GetPawn()
    local PawnName = IsAlive(Pawn) and Pawn:GetFName():ToString() or nil
    if PawnName and PawnName ~= LastClientPawn then
        LastClientPawn, ClientPawnSince = PawnName, Now
        PossessReplayed, HudChecked = false, false
        Log("Eigene Figur erhalten: %s", PawnName)
        SetupClient()
    end
    DisableClientSaving()
    if MenuClosed then
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
    if not PawnName then return end
    local okFreeze, errFreeze = pcall(Coop.UnfreezeOwnPawn, Pawn, ClientPawnSince)
    if not okFreeze then Log("Spawn-Freigabe-Fehler: %s", tostring(errFreeze)) end
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
    if HudChecked then
        local okInv, errInv = pcall(Coop.ClientInventoryTick, Pawn)
        if not okInv then Log("Inventar-Fehler: %s", tostring(errInv)) end
        -- Erst mit Figur und HUD: Waehrend des Beitritts entladen liess das Spiel abstuerzen
        local okMenu, errMenu = pcall(Coop.UnloadMenuLevel, World)
        if not okMenu then Log("Menue-Level-Fehler: %s", tostring(errMenu)) end
        pcall(Coop.AmmoTick)
        local okMap, errMap = pcall(Coop.Map.ClientTick, Pawn)
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
    local ok, err = pcall(I.Poll)
    if not ok and not I.Err then I.Err = true Log("Tasten-Fehler: %s", tostring(err)) end
end)
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
    local Pawn = LocalPC():K2_GetPawn()
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
            tostring(Safe(function() return Pawn.CharacterMovement.MaxWalkSpeed end)))
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
Coop.StartWalkLoop = function()
    LoopAsync(16, function()
        if not Walk then return true end
        ExecuteInGameThread(function() pcall(WalkTick) end)
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
        Save.SkinColor = Coop.LoadByPath("/Game/PlayerModel/Materials/4/M_Chr_Texture_4A.M_Chr_Texture_4A")
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
    damage = function(Arg)
        for _, Pawn in ipairs(RemotePawns(CurrentWorld())) do
            UEHelpers.GetGameplayStatics():ApplyDamage(Pawn, tonumber(Arg) or 10, nil, nil, nil)
            TestLog("damage %s an %s", Arg or "10", Pawn:GetFName():ToString())
        end
    end,
    -- Client: Respawn-Knopf des Spiels
    respawn = function() LocalPC():Svr_RequestRespawn_Random() TestLog("respawn angefragt") end,
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
        pcall(RunTestCommands)
        Tick = Tick + 1
        local World = CurrentWorld()
        if not IsAlive(World) then return end
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
        if Tick % SLOW_EVERY == 0 or not Online then
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
        local okShot, errShot = pcall(Coop.Shot.Tick)
        if not okShot and not Coop.Shot.ErrLogged then Coop.Shot.ErrLogged = true Log("Schuss-Fehler: %s", tostring(errShot)) end
        local okInv, errInv = pcall(Coop.InvDiag.Tick)
        if not okInv and not Coop.InvDiag.ErrLogged then Coop.InvDiag.ErrLogged = true Log("Inventar-Diagnose-Fehler: %s", tostring(errInv)) end
        local okHealth, errHealth = pcall(LogHealth, World)
        if not okHealth then Log("Leben-Fehler: %s", tostring(errHealth)) end
        local okSpeed, errSpeed = pcall(LogSpeed, World)
        if not okSpeed then Log("Tempo-Fehler: %s", tostring(errSpeed)) end
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
        local okSky, errSky = pcall(Coop.SkyHostTick, World)
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
        if SteamNetworkingDisabledInIni() then
            Log("Engine.ini: Steam-Networking aus, IP-Modus bereit.")
        else
            Log("WARNUNG: IP-Modus, aber Steam-Networking ist in der Engine.ini noch an. Spiel beenden und Installer nochmal ausfuehren.")
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

Log("geladen. Server beitreten: Journal (J) -> Server Liste")
