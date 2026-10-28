-- Last-Signal-Server: SurrounDead als Koop-Server ohne Spieler am Host (Linux/Wine oder Windows, -nullrhi).
-- Nur aktiv mit LASTSIGNAL_SERVER=1 (setzt start.sh). Ablauf beim Start:
--   Titelbild weg -> Menue als Listen-Server oeffnen -> Titelbild weg -> Spielstand laden (Continue)
--   -> eigene Figur unsichtbar und unverwundbar ("Geist") -> Autosave, FPS-Grenze, Konsole.
-- Konsole: start.sh schreibt jede Eingabezeile nach server_cmd.txt (help, status, players, save, stop).
--   SIGTERM/docker stop: start.sh schreibt "shutdown" (= stop: Gaeste sofort speichern, bye, Welt speichern, beenden).
-- Einstellungen (Umgebungsvariablen): LASTSIGNAL_NAME, _PORT, _MAX_PLAYERS, _SAVE_MINUTES, _FPS,
--   _LOCAL_INVENTORY, _SAVE_SLOT, _CORPSE_MINUTES, _DEATHBOX_MINUTES, _LOOT_REFILL, _LOOT_REFILL_MIN,
--   _FPS_MIN (Untergrenze der FPS-Drossel, Standard 45), _FPS_AUTO (0 = festes FPS-Ziel ohne Drossel, Standard 1)
--   _BACKUP_MINUTES (Sicherung der Spielstaende durch start.sh hoechstens so oft, Standard 30, 0 = nur beim Start),
--   _ADMIN_PASSWORD (Admins zusaetzlich mit "/admin <Passwort>" im Chat; leer = nur Mitspieler-ID)
--   _RESTART_AT (HH:MM, Uhrzeit des Servers: taeglicher Neustart mit Ansagen; leer = keiner)
--   (die alten Namen NETTEST_* gelten weiter)
local Srv = {}
local VERSION = "0.10.0"   -- Mod-Version fuer die Master-Liste (start.sh liest sie aus status.txt)

-- LASTSIGNAL_<Name>, sonst der alte Name NETTEST_<Name> (aeltere Panels/server.cfg), sonst Default
local function Env(Name, Default)
    for _, Prefix in ipairs({ "LASTSIGNAL_", "NETTEST_" }) do
        local Value = os.getenv(Prefix .. Name)
        if Value ~= nil and Value ~= "" then return Value end
    end
    return Default
end

local A           -- Funktionen aus main.lua (siehe Init)
local function Log(fmt, ...) A.Log("[Server] " .. fmt, ...) end

local MAIN_MENU_LEVEL = "MainMenu_C"          -- Level-Blueprint des Hauptmenues
local TITLE_WIDGET = "PressAnyKeyWidget_C"
local MENU_WIDGET = "MenuWidget_C"
local CONTINUE = "BndEvt__MenuWidget_ContinueGame_K2Node_ComponentBoundEvent_25_OnButtonClickedEvent__DelegateSignature"
local EMS_PATH = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
local BOOT_GIVE_UP, LOAD_GIVE_UP, CONTINUE_RETRY = 240, 300, 60
-- Start ohne Grafik (UE 5.6, decode-verifiziert): PersistentLevel_C ReceiveBeginPlay @00e8 erzeugt den Ladebildschirm und
-- ruft GI.Event_LoadLevel('MainMenu') -> SmoothLoadLevel -> PersistentLevel Event_LoadLevel @02dc -> LoadingScreen.FadeIn
-- (Event_FadeFinished erst, wenn die Einblend-Animation fertig meldet) -> @02a0 UnloadStreamLevel -> @008b CurrentLevel =
-- Ziel, LoadStreamLevel -> 2 s -> FadeOut -> Event_RemoveLoadingScreen @02e1. Meldet eine Animation ohne Grafik nie
-- "fertig", bleibt der Ladebildschirm stehen und das Menue-Level kommt nie (5.6-Server: "Hauptmenue kam nicht").
-- CHECK: MenuWidget Continue @169f -> @0b13 EMSAsyncCheck.CheckSaveFiles(3, ""): OnCompleted @0ad2 -> RemoveFromParent +
-- SaveMenu.LoadGameFromSlot(false, 'LongdownValley'); OnFailed @0ad1 und OnVersionMismatch @169e (neu in 5.6) tun nichts.
local BOOT = { FADE_WAIT = 10, REMOVE_WAIT = 30, RETRY = 20, DIAG = 30, FALLBACK = 20, LEVEL = "LongdownValley",
               CHECK = { "OnCompleted", "OnFailed", "OnVersionMismatch" }, CHECK_ID = "_E146B6814333B39837D422955BF1D1E8" }

Srv.State, Srv.StateSince = "title", os.time()
Srv.StartedAt, Srv.SavedAt, Srv.Fps = os.time(), nil, nil
Srv.GhostAt, Srv.NoPawnSince, Srv.StopAt, Srv.Commands = 0, nil, nil, {}
Srv.LastStart, Srv.Placed, Srv.SeenPawns, Srv.Protect = {}, {}, {}, {}   -- Spawnpunkte und Spawn-Schutz
Srv.Restored = {}   -- join_v2 (main.lua Coop.Join): [Figurenname] = schon am Ziel gespawnt, OnNewGuestPawn setzt nicht um
Srv.MedicLast = {}                                                        -- Diagnose Blutung je Figur

Srv.FpsGraceS = 45   -- server_fps_v2: so lange nach Gast-/Ziel-/Zustandswechsel keine FPS-Drossel-Bewertung

local function SetState(State)
    Log("%s -> %s", Srv.State, State)
    Srv.State, Srv.StateSince = State, os.time()
    if State == "running" then Srv.FpsGraceUntil = os.time() + Srv.FpsGraceS end
end

local function Since() return os.time() - Srv.StateSince end

local function Quit(Reason)
    Log("Beende das Spiel: %s", Reason)
    local World = A.CurrentWorld()
    A.UEHelpers.GetKismetSystemLibrary():QuitGame(World, A.LocalPC(), 0, false)
end

local function SetFps(Fps)
    if Srv.Fps == Fps then return end
    Srv.Fps = Fps
    Srv.FpsGraceUntil = os.time() + Srv.FpsGraceS   -- neues Ziel: erst einschwingen lassen (nur v2 wertet es aus)
    A.RunCommand("t.MaxFPS " .. Fps)
end

-- Kisten fuellen sich wieder auf wie im Einzelspieler: sie lesen Difficulty.Refill beim Durchsuchen und
-- Difficulty.RefillTime (Minuten) beim Start ihres Timers (UE 5.6: BP_JigComponent_C, CVars in SD_GameInstance ReceiveInit). Der Spielstand
-- setzt beide beim Laden (Save_Difficulties), darum erst danach aus LASTSIGNAL_LOOT_REFILL/_LOOT_REFILL_MIN setzen.
-- Ueber ConsoleUtils wie das Spiel selbst (ein Konsolenbefehl haette Vorrang vor spaeteren Setzungen des Spiels).
-- Die Gaeste bekommen beide Werte ueber ls_ui (ui_cvars). Check = true: nur nachsetzen, wenn sie sich geaendert haben.
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"
local function ApplyLootRefill(Check)
    local On, Minutes = Srv.Cfg.LootRefill, Srv.Cfg.LootRefillMin
    local CU = A.Safe(function() return StaticFindObject(CONSOLE_UTILS) end, nil)
    if not A.IsAlive(CU) then
        if Check then return end
        A.RunCommand("Difficulty.Refill " .. (On and "1" or "0"))
        A.RunCommand("Difficulty.RefillTime " .. Minutes)
        Log("Kisten-Nachfuellen %s (per Konsole, ConsoleUtils fehlt)", On and (Minutes .. " min") or "aus")
        return
    end
    local function Read()
        return A.Safe(function() return CU:GetBoolCVar(FName("Difficulty.Refill")) end, nil),
            A.Safe(function() return CU:GetFloatCVar(FName("Difficulty.RefillTime")) end, nil)
    end
    local OldOn, OldMin = Read()
    if Check and OldOn == On and OldMin and math.abs(OldMin - Minutes) < 0.01 then return end
    pcall(function() CU:SetBoolCVar(FName("Difficulty.Refill"), On) end)
    pcall(function() CU:SetFloatCVar(FName("Difficulty.RefillTime"), Minutes) end)
    local NewOn, NewMin = Read()
    local function Num(V) return V and string.format("%.0f", V) or "?" end
    Log("%sKisten-Nachfuellen %s: Difficulty.Refill %s -> %s, Difficulty.RefillTime %s -> %s min",
        Check and "Erneut gesetzt (Spiel hatte es geaendert): " or "", On and (Minutes .. " min") or "aus",
        tostring(OldOn), tostring(NewOn), Num(OldMin), Num(NewMin))
end

-- Alle 5 min eine Zeile: gemessene FPS, Gaeste, Lua-Speicher und die teuersten Aufgaben (ls_core, letzte 60 s)
local PERF_LOG_SECONDS = 300
local function PerfLog(NGuests)
    local okC, Core = pcall(require, "ls_core")
    local Top, KB = "-", collectgarbage("count")
    if okC and type(Core) == "table" and Core.PerfReport then
        local _, T, K = Core.PerfReport(5)
        Top, KB = T, K
    end
    local Measured = Srv.Fps ~= Srv.Cfg.IdleFps and Srv.AvgFps
    -- CORE-15: dazu Netz (verworfene Rahmen je Grund, Eingangs-Warteschlange) und wegen Fehlern abgeschaltete Schalter
    local okN, NetText = pcall(Srv.PerfNetText)
    Log("Leistung: FPS %s (Ziel %.0f, Einstellung %d, Untergrenze %d, Automatik %s, Drossel %s), Gaeste %d, Lua %.0f KB, teuerste Aufgaben: %s; %s",
        Measured and string.format("%.0f", Measured) or "-", Srv.Fps or 0, Srv.Cfg.Fps, Srv.Cfg.FpsMin or 0,
        Srv.Cfg.FpsAuto and "an" or "aus", Srv.Cap and tostring(Srv.Cap) or "-", NGuests, KB, Top,
        okN and tostring(NetText) or ("Netz-Teil: Fehler " .. tostring(NetText)))
end

-- CORE-15: ls_net Net.DropText/Inbox/GuestCount, ls_core Core.Down (Namen), aufgeraeumte Tabellen-Eintraege (CORE-30)
function Srv.PerfNetText()
    local Net = A.Coop.Net
    if type(Net) ~= "table" then Net = package.loaded["ls_net"] end
    local Parts = {}
    if type(Net) == "table" then
        local Drop = type(Net.DropText) == "function" and A.Safe(Net.DropText, "?") or "?"
        local Inbox = type(Net.Inbox) == "table" and #Net.Inbox or -1
        local NG = type(Net.GuestCount) == "function" and tonumber(A.Safe(Net.GuestCount, -1)) or -1
        Parts[#Parts + 1] = string.format("Netz: verworfen {%s}, Eingang %d, Net-Gaeste %d", tostring(Drop), Inbox, NG)
    end
    local Core, Down = Srv.Core(), {}
    for Name in pairs(Core and type(Core.Down) == "table" and Core.Down or {}) do Down[#Down + 1] = tostring(Name) end
    table.sort(Down)
    Parts[#Parts + 1] = "Schalter aus: " .. (#Down > 0 and table.concat(Down, ",") or "-")
    Parts[#Parts + 1] = "aufgeraeumt " .. (Srv.Pruned or 0)
    return table.concat(Parts, ", ")
end

-- Schalter (ls_core Core.Flag, coop.txt); vor dem Laden von ls_core (Srv.Init, J.Rollback) coop.txt selbst lesen
function Srv.Flag(Name, Default)
    local Core = package.loaded["ls_core"]
    if type(Core) == "table" and type(Core.Flag) == "function" then
        local ok, Value = pcall(Core.Flag, Name, Default)
        if ok and Value ~= nil then return Value end
        if ok then return Default end
        -- Fehler: ls_core ist geladen, aber noch ohne Init -> wie vor dem Laden
    end
    local ok, Value = pcall(Srv.BootFlag, Name, Default)
    if ok and Value ~= nil then return Value end
    return Default
end

-- Runde 9: wie Core.Flag (SETTINGS, sonst coop.txt, profile=legacy = aus), ohne Down. Nur bis ls_core geladen ist.
function Srv.BootFlag(Name, Default)
    if not Srv.Extra then
        Srv.Extra = {}
        local File = A and io.open(A.ModDir .. "coop.txt", "r")
        if File then
            for Line in File:lines() do
                local Key, Value = Line:match("^%s*([%w_]+)%s*=%s*(%S+)")
                if Key then Srv.Extra[Key] = Value end
            end
            File:close()
        end
    end
    local Settings = A and A.Settings or {}
    local Profile = Settings.profile or Srv.Extra.profile
    if type(Profile) == "string" and Profile:lower() == "legacy" then return type(Default) == "number" and 0 or false end
    local Value = Settings[Name]
    if Value == nil then Value = Srv.Extra[Name] end
    if Value == nil then return Default end
    if type(Default) == "number" then return tonumber(Value) or Default end
    if type(Value) == "string" then
        Value = Value:lower()
        return Value:sub(1, 1) == "1" or Value == "true" or Value == "on"
    end
    if type(Value) == "number" then return Value ~= 0 end
    return Value and true or false
end

-- Fehler eines neuen Wegs an ls_core melden (Autofallback: mehr als 3 Fehler in 60 s -> Schalter fuer die Sitzung aus)
function Srv.Fail(Name, Err)
    local Core = package.loaded["ls_core"]
    if type(Core) == "table" and type(Core.Fail) == "function" then pcall(Core.Fail, Name, Err) end
end

-- ls_core, sobald main.lua es geladen hat (nach server.lua); vorher (Srv.Init) die eigenen Rueckfall-Wege unten
function Srv.Core()
    local Core = package.loaded["ls_core"]
    return type(Core) == "table" and Core or nil
end

-- Dateien (Regel 6): lesen wie Core.ReadAll (fehlt Path, gilt ein liegengebliebenes Path.bak), schreiben atomar
-- (Core.WriteAtomic: .tmp, dann umbenennen). Loeschen samt .bak/.tmp (sonst holt ReadAll den alten Stand zurueck).
function Srv.ReadText(Path)
    local Core = Srv.Core()
    if Core and type(Core.ReadAll) == "function" then return Core.ReadAll(Path) end
    for _, P in ipairs({ Path, Path .. ".bak" }) do
        local File = io.open(P, "rb")
        if File then
            local Text = File:read("*a")
            File:close()
            if Text then return Text end
        end
    end
    return nil
end

function Srv.WriteText(Path, Text)
    local Core = Srv.Core()
    if Core and type(Core.WriteAtomic) == "function" then return Core.WriteAtomic(Path, Text) == true end
    local File = io.open(Path, "wb")
    if not File then return false end
    local ok = File:write(Text)
    if not File:close() then ok = false end
    return ok and true or false
end

function Srv.RemoveFile(Path)
    os.remove(Path .. ".bak")
    os.remove(Path .. ".tmp")
    return os.remove(Path)
end

-- EMS-Bibliothek (CDO) nur nach IsAlive (CORE-20: ungepruefte Lookups), nil ohne
function Srv.Ems()
    local Ems = A.Safe(function() return StaticFindObject(EMS_PATH) end)
    return A.IsAlive(Ems) and Ems or nil
end

-- Laeuft gerade ein Speichern/Laden (EMS)? Ohne EMS-Objekt: nein (wie bisher)
function Srv.Busy(World)
    local Ems = Srv.Ems()
    return Ems ~= nil and A.Safe(function() return Ems:IsSavingOrLoading(World) end, false) == true
end

-- Pfade von Gaesten (CORE-14, untrusted_paths): ls_core Core.SafeGuestPath (E24), sonst dieselbe Regel hier: nur
-- "/Game/<Ordner>/<Name>.<Name>", hoechstens 200 Zeichen, nie Karten/Level
function Srv.SafePath(Path, Prefixes)
    local Core = package.loaded["ls_core"]
    if type(Core) == "table" and type(Core.SafeGuestPath) == "function" then
        local ok, Res = pcall(Core.SafeGuestPath, Path, Prefixes)
        if ok then return Res == true end
    end
    if type(Path) ~= "string" or #Path > 200 or not Path:match("^/Game/[%w_/]+%.[%w_]+$") then return false end
    local Lower = Path:lower()
    if Lower:find("/maps/", 1, true) or Lower:find("/levels/", 1, true) then return false end
    for _, P in ipairs(Prefixes or {}) do if Path:sub(1, #P) == P then return true end end
    return Prefixes == nil
end

-- Titelbild ("Press any key"): das Widget fragt jeden Frame die Tastatur ab und meldet sich dann beim
-- Level-Blueprint des Menues (Event_KeyDown). Ohne Tastatur machen wir das selbst. UE 5.6 MainMenu_C Event_KeyDown
-- @05e0 -> @03e4: GameStarted? = false, CreateMenu nur mit Save_FirstLoadGame.PlayedTutorial?, sonst
-- GI.Event_LoadLevel('TutorialWorld'). Der Server braucht immer das Menue: srv_boot_menu (Standard an) setzt
-- GameStarted? selbst und ruft CreateMenu (@04e8: MenuWidget_C erzeugen + AddToViewport), nie das Tutorial.
local function DismissTitle()
    local Shown = false
    for _, Widget in ipairs(FindAllOf(TITLE_WIDGET) or {}) do
        if A.IsAlive(Widget) and A.Safe(function() return Widget:IsInViewport() end, false) then
            Shown = true
            pcall(function() Widget:RemoveFromParent() end)
        end
    end
    if not Shown then return false end
    local Level = FindFirstOf(MAIN_MENU_LEVEL)
    if not A.IsAlive(Level) then
        Log("Titelbild entfernt, Menue-Level nicht gefunden")
        return true
    end
    local ok, err, Way
    if Srv.Flag("srv_boot_menu", true) then
        local GI = FindFirstOf("SD_GameInstance_C")
        if A.IsAlive(GI) then pcall(function() GI["GameStarted?"] = false end) end
        ok, err = pcall(function() Level:CreateMenu() end)
        Way = "CreateMenu"
    else
        ok, err = pcall(function() Level:Event_KeyDown() end)
        Way = "Event_KeyDown"
    end
    Log("Titelbild uebersprungen (%s)%s", Way, ok and "" or (" (Fehler: " .. tostring(err) .. ")"))
    return true
end

local function MenuShown()
    local Menu = FindFirstOf(MENU_WIDGET)
    return A.IsAlive(Menu) and A.Safe(function() return Menu:IsInViewport() end, false) and Menu or nil
end

-- Ladebildschirm-Waechter (srv_ls_watch, Standard an), jede Sekunde in title/reload/menu/loading. Zustand je Phase:
-- Persistent.CurrentLevel ~= GI.CurrentLevel = Einblenden laeuft (Event_FadeFinished steht aus): nach FADE_WAIT s selbst
-- Event_FadeFinished (wie 5.3 beim Laden). Gleich = Level wird/ist geladen: steht der Ladebildschirm danach noch
-- REMOVE_WAIT s (FadeOut meldet nicht), Event_RemoveLoadingScreen (nur RemoveFromParent, rein optisch).
-- Doppelte Aufrufe: UnloadStreamLevel/LoadStreamLevel mit derselben Latent-UUID werden von der Engine verworfen.
Srv.LS = {}
function Srv.LoadingWatch()
    if not Srv.Flag("srv_ls_watch", true) then return end
    local W, Now = Srv.LS, os.time()
    local Persistent = FindFirstOf("PersistentLevel_C")
    if not A.IsAlive(Persistent) then W.Since, W.LoadAt = nil, nil return end
    local Screen = A.Safe(function() return Persistent.LoadingScreen end)
    local Shown = A.IsAlive(Screen) and A.Safe(function() return Screen:IsInViewport() end, false)
    local GI = FindFirstOf("SD_GameInstance_C")
    local Want = A.IsAlive(GI) and A.Safe(function() return GI.CurrentLevel:ToString() end) or nil
    local Have = A.Safe(function() return Persistent.CurrentLevel:ToString() end)
    -- Pending: GI will ein anderes Level als PersistentLevel zuletzt geladen hat (@008b steht noch aus)
    local Pending = Want ~= nil and Want ~= "None" and Have ~= Want
    if not Shown and not Pending then W.Since, W.LoadAt = nil, nil return end
    W.Since = W.Since or Now
    local Wait = Now - (W.At or 0) < BOOT.RETRY
    if Pending then
        W.LoadAt = nil
        if Wait or Now - W.Since < BOOT.FADE_WAIT then return end
        W.At = Now
        local ok, err = pcall(function() Persistent:Event_FadeFinished() end)
        Log("Levelwechsel haengt beim Einblenden (%d s, Ladebild=%s, Level %s -> %s): Event_FadeFinished angestossen%s",
            Now - W.Since, tostring(Shown), tostring(Have), Want, ok and "" or (": Fehler " .. tostring(err)))
        return
    end
    W.LoadAt = W.LoadAt or Now
    if Wait or Now - W.LoadAt < BOOT.REMOVE_WAIT then return end
    W.At = Now
    local ok, err = pcall(function() Persistent:Event_RemoveLoadingScreen() end)
    Log("Ladebildschirm steht seit %d s nach dem Levelwechsel (%s): Event_RemoveLoadingScreen%s", Now - W.Since,
        tostring(Want), ok and "" or (": Fehler " .. tostring(err)))
end

-- Diagnose waehrend des Starts (alle DIAG s): was steht im Bild, welche Level, warum noch nicht weiter
function Srv.BootDiag(Mode)
    if os.time() < (Srv.DiagAt or 0) then return end
    Srv.DiagAt = os.time() + BOOT.DIAG
    if Since() < 5 then return end
    local GI = FindFirstOf("SD_GameInstance_C")
    local Persistent = FindFirstOf("PersistentLevel_C")
    local Ready, Why = A.ReadyToTravel()
    Log("Start-Zustand %s seit %d s: NetMode=%s, Titelbild=%s, Menue=%s, Ladebild=%s, Level GI=%s Persistent=%s, " ..
        "GameStarted?=%s, Menue-Level=%s, bereit=%s%s", Srv.State, Since(), tostring(Mode),
        tostring(A.VisibleWidget(TITLE_WIDGET)), tostring(MenuShown() ~= nil), tostring(A.VisibleWidget("LoadingScreenWidget_C")),
        A.IsAlive(GI) and A.Safe(function() return GI.CurrentLevel:ToString() end, "?") or "-",
        A.IsAlive(Persistent) and A.Safe(function() return Persistent.CurrentLevel:ToString() end, "?") or "-",
        A.IsAlive(GI) and tostring(A.Safe(function() return GI["GameStarted?"] end)) or "-",
        tostring(A.IsAlive(FindFirstOf(MAIN_MENU_LEVEL))), tostring(Ready), Why and (" (" .. tostring(Why) .. ")") or "")
end

-- Antwort der Spielstand-Pruefung nach Continue mitlesen (nur einen Merker setzen, nichts aufrufen). Pfad aus der
-- geladenen Klasse des Menues. Srv.CheckHooked: nil = noch nicht versucht, true = alle drei Hooks sitzen.
function Srv.HookContinueCheck(Menu)
    if Srv.CheckHooked ~= nil then return end
    local Path = A.Safe(function() return Menu:GetClass():GetFullName():match("^%S+%s+(%S+)$") end)
    if not Path then return end
    Srv.CheckHooked = true
    for _, Name in ipairs(BOOT.CHECK) do
        local ok = pcall(RegisterHook, Path .. ":" .. Name .. BOOT.CHECK_ID, function() Srv.CheckResult = Name end)
        if not ok then Srv.CheckHooked = false end
    end
    Log("Spielstand-Pruefung (CheckSaveFiles) wird %s", Srv.CheckHooked and "mitgelesen" or "nicht mitgelesen (Hook fehlgeschlagen)")
end

-- Continue hat nach FALLBACK s nichts bewirkt (Menue steht noch): Antwort auswerten. Keine Antwort (Hooks sitzen) ->
-- direkt SaveMenu.LoadGameFromSlot(false, 'LongdownValley') wie OnCompleted @0ad2 (srv_load_fallback, Standard an).
-- OnVersionMismatch: das Spiel selbst laedt dann nicht (auch SaveMenu @27d1 nicht) -> nur mit srv_force_load (aus).
function Srv.LoadFallback()
    local R = Srv.CheckResult
    if R == "OnCompleted" then return end
    if R == "OnFailed" then
        Log("Spielstand-Pruefung meldet Fehler (CheckSaveFiles OnFailed): kein gueltiger Spielstand im Slot")
        return
    end
    if R == "OnVersionMismatch" and not Srv.Flag("srv_force_load", false) then
        Log("Spielstand passt nicht zur Spielversion (CheckSaveFiles OnVersionMismatch): Continue laedt nicht. " ..
            "Erzwingen nur mit srv_force_load=1 in coop.txt (Spielstand vorher sichern)")
        return
    end
    if R == nil and not (Srv.CheckHooked == true and Srv.Flag("srv_load_fallback", true)) then
        Log("Continue reagierte nicht, Antwort der Spielstand-Pruefung unbekannt: kein Ersatzweg")
        return
    end
    local Menu = MenuShown()
    local Save = Menu and A.Safe(function() return Menu.SaveMenu end) or nil
    if not A.IsAlive(Save) then Log("Ersatzweg Laden: SaveMenu nicht gefunden") return end
    local HasSlot = A.IsAlive(A.Safe(function() return Save.CurrentSelectedSlot end))
    local ok, err = pcall(function() Save:LoadGameFromSlot(false, FName(BOOT.LEVEL)) end)
    Log("Continue reagierte nicht (%s): lade direkt mit SaveMenu.LoadGameFromSlot('%s'), Slot gewaehlt=%s%s",
        R or "keine Antwort", BOOT.LEVEL, tostring(HasSlot), ok and "" or (": Fehler " .. tostring(err)))
end

local function OwnPawn()
    local PC = A.LocalPC()
    local Pawn = PC and A.IsAlive(PC) and PC:K2_GetPawn()
    if A.IsAlive(Pawn) and Pawn:GetClass():GetFName():ToString() == "BP_PlayerCharacter_C" then return Pawn end
    return nil
end

local function Guests(World)
    local List = {}
    for _, PS in ipairs(A.PlayerStates(World)) do
        local PC = PS:GetOwner()
        if A.IsAlive(PC) and A.Safe(function() return not PC:IsLocalController() end, false) then
            List[#List + 1] = { PS = PS, PC = PC, Pawn = PC:K2_GetPawn() }
        end
    end
    return List
end

-- Eigene Figur des Servers: unsichtbar, ohne Kollision, unverwundbar, fuer Zombies nicht wahrnehmbar und
-- kein "Invoker" des AI-Optimizers (Spawner und KI richten sich nur nach Invokern, also nur nach den
-- Mitspielern). Steht still am Startpunkt (Flugmodus, nicht "None": sonst loest die Spawn-Freigabe aus).
local function RemoveInvoker(Pawn)
    local Component = Pawn.AIOInvoker
    if not A.IsAlive(Component) then return "keine Komponente" end
    local Subsystem = FindFirstOf("AIOptimizerSubsystem")
    if not A.IsAlive(Subsystem) then return "kein Subsystem" end
    local Before = A.Safe(function() return #Subsystem.Invokers end, -1)
    pcall(function() Subsystem:UnregisterInvoker(Component) end)
    pcall(function() Component:Deactivate() end)
    return string.format("%d -> %d Invoker", Before, A.Safe(function() return #Subsystem.Invokers end, -1))
end

-- Hunger/Durst-Komponente der Figur: UE 5.6 heisst die Eigenschaft "Hunger&ThirstComponent" (5.3: HungerThirstComponent)
function Srv.HungerComp(Pawn)
    for _, Name in ipairs({ "Hunger&ThirstComponent", "HungerThirstComponent" }) do
        local Comp = A.Safe(function() return Pawn[Name] end)
        if A.IsAlive(Comp) then return Comp end
    end
    return nil
end

local function Ghost(Pawn, World)
    if Srv.GhostOf ~= Pawn:GetFName():ToString() then
        Srv.GhostOf = Pawn:GetFName():ToString()
        pcall(function() Pawn:SetActorHiddenInGame(true) end)
        pcall(function() Pawn:SetActorEnableCollision(false) end)
        pcall(function() Pawn.bCanBeDamaged = false end)
        pcall(function()
            local Src = Pawn.AIPerceptionStimuliSource
            if A.IsAlive(Src) then Src:UnregisterFromPerceptionSystem() end
        end)
        local okInv, Invoker = pcall(RemoveInvoker, Pawn)
        Log("Server-Figur %s ist jetzt unsichtbar, AI-Optimizer: %s", Srv.GhostOf,
            okInv and Invoker or ("Fehler " .. tostring(Invoker)))
    end
    pcall(function()
        local Move = Pawn.CharacterMovement
        if not A.IsAlive(Move) then return end
        if Move.MovementMode ~= 5 then Move:SetMovementMode(5, 0) end
        Move.Velocity = { X = 0, Y = 0, Z = 0 }
    end)
    -- Werte voll halten (wie die Startwerte neuer Mitspieler), sonst verhungert der Geist
    pcall(function()
        local M, H, R = Pawn.MedicalComponent, Srv.HungerComp(Pawn), Pawn.RadiationComponent
        if A.IsAlive(M) then M.Health = M.MaxHealth end
        if A.IsAlive(H) then H.CurrentHunger, H.CurrentThirst = H.MaxHunger, H.MaxThirst end
        if A.IsAlive(R) then R.CurrentRadiation = R.MaxRadiation end
    end)
    -- Am Startpunkt am Boden halten (dort steht sie auch im Spielstand)
    if Srv.Anchor then
        local L, T = Pawn:K2_GetActorLocation(), Srv.Anchor.Loc
        if math.abs(L.X - T.X) + math.abs(L.Y - T.Y) + math.abs(L.Z - T.Z) > 100 then
            pcall(function() Pawn:K2_SetActorLocation(T, false, {}, true) end)
        end
    end
end

-- Startausruestung mit GPS: Die Ausruestung kommt aus BP_JigMultiplayer.ContainersSettings der Figur (UE 5.6: Klasse
-- BP_JigComponent_C, Eigenschaft der Figur heisst weiter BP_JigMultiplayer; ReceiveBeginPlay @0320 -> SetStartingItems) (je
-- Platz eine Liste StartingItems; das Spiel gibt nur Lumpen in die Taschen). Vor SetStartingItems ein GPS
-- in den GPS-Platz legen - gilt fuer neue Mitspieler und fuer den Respawn des Spiels nach dem Tod.
local GPS_ASSET = "/Game/Inventory/Items/DataAssets/Equipment/Tools/DA_GPS.DA_GPS"
local KIT = { NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982",
              ITEMS = "StartingItems_10_C6DB208442353E0AA9B5DB892266821A",
              ID = "ItemID_41_8C5E69274AB445604263E4A2B3091BAD" }

local function AddGpsToStarterKit(Pawn)
    local Gps = StaticFindObject(GPS_ASSET)
    if not A.IsAlive(Gps) then return "nicht gefunden" end
    if not A.IsAlive(Pawn) then return "keine Figur" end
    local Jig = Pawn.BP_JigMultiplayer
    if not A.IsAlive(Jig) then return "kein Inventar" end
    local Settings = Jig.ContainersSettings
    for i = 1, #Settings do
        if Settings[i][KIT.NAME]:ToString() == "GPS" then
            local Items = Settings[i][KIT.ITEMS]
            for j = 1, #Items do
                local Id = Items[j][KIT.ID]
                if A.IsAlive(Id) and Id:GetFName():ToString() == "DA_GPS" then return "schon drin" end
            end
            -- Werte wie beim Lumpen-Eintrag des Spiels (Chance 100, Index -1, Preis -1), Anzahl 1. UE 5.6: LootType_44 und
            -- RandomStats_34 gibt es in RandomContainerItem nicht mehr (SetStartingItems MakeStruct @03da-@049e)
            Items[#Items + 1] = { [KIT.ID] = Gps,
                ["SpawnChance_9_0A1811814580181DD09AE78500C25A28"] = 100.0,
                ["RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9"] = 1,
                ["RandomCountMax_18_C37B88104F52B02AA216B5912518580D"] = 1,
                ["Index_37_B46F3993454026F67AFD6D936119D0F6"] = -1,
                ["PreferRotated?_39_71AEF07C444B177A20CAF4A74260B9CD"] = false,
                ["PriceOverride_29_306CC4B441051ADD17999E8D00D06A7F"] = -1.0 }
            return "hinzugefuegt"
        end
    end
    return "kein GPS-Platz"
end

local function HookStarterKit()
    if Srv.KitHooked then return end
    Srv.KitHooked = true
    local ok, err = pcall(RegisterHook, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetStartingItems",
        function(Context)
            local Pawn = Context:get()
            local okGps, Result = pcall(AddGpsToStarterKit, Pawn)
            Log("Startausruestung fuer %s: GPS %s", A.Safe(function() return Pawn:GetFName():ToString() end, "?"),
                okGps and Result or ("Fehler " .. tostring(Result)))
        end)
    Log("GPS in der Startausruestung %s", ok and "aktiv" or ("nicht moeglich: " .. tostring(err)))
end

-- Bodenpunkt unter einer Stelle (Linie nach unten, Kanal Visibility), 1 m darueber. nil ohne Treffer.
local function Ground(Loc)
    local Hit, Clear = {}, { R = 0, G = 0, B = 0, A = 0 }
    local ok = A.Safe(function()
        return A.UEHelpers.GetKismetSystemLibrary():LineTraceSingle(A.CurrentWorld(),
            { X = Loc.X, Y = Loc.Y, Z = Loc.Z + 200 }, { X = Loc.X, Y = Loc.Y, Z = Loc.Z - 100000 },
            0, false, {}, 0, Hit, true, Clear, Clear, 0)
    end, false)
    if ok and Hit.ImpactPoint then return { X = Loc.X, Y = Loc.Y, Z = Hit.ImpactPoint.Z + 100 } end
    return nil
end

-- Spawnpunkte des Spiels: wie beim zufaelligen Respawn (GI Survival_Respawn) alle PlayerStart mit Tag "Survival"
local function SurvivalStarts()
    local List, Seen = {}, {}
    for _, Class in ipairs({ "PlayerStart", "BP_GameModeStart_C" }) do
        for _, Start in ipairs(FindAllOf(Class) or {}) do
            local Name = A.IsAlive(Start) and Start:GetFullName()
            if Name and not Seen[Name] and A.Safe(function() return Start:ActorHasTag(FName("Survival")) end, false) then
                Seen[Name] = true
                List[#List + 1] = Start
            end
        end
    end
    return List
end

-- Lebende KI-Figuren (Zombies, Tiere, ...) und wie viele davon im Umkreis einer Stelle stehen
local SAFE_RADIUS = 4000   -- 40 m
local function LivingAI()
    local List = {}
    for _, Char in ipairs((A.Coop and A.Coop.Characters and A.Coop.Characters() or FindAllOf("Character") or {})) do
        if A.IsAlive(Char) and Char:GetClass():GetFName():ToString() ~= "BP_PlayerCharacter_C"
            and not A.Safe(function() return Char["IsDead?"] == true end, false) then
            List[#List + 1] = Char:K2_GetActorLocation()
        end
    end
    return List
end

local function CountNear(Loc, AI)
    local N, R2 = 0, SAFE_RADIUS * SAFE_RADIUS
    for _, L in ipairs(AI) do
        if (L.X - Loc.X) ^ 2 + (L.Y - Loc.Y) ^ 2 + (L.Z - Loc.Z) ^ 2 < R2 then N = N + 1 end
    end
    return N
end

-- Spawnpunkte, die ein anderer Mitspieler in den letzten 5 min bekommen hat, nicht vergeben (Respawn und
-- Beitritt in derselben Sekunde landeten sonst 2 m nebeneinander)
local RECENT_START = 300
Srv.UsedStarts = {}   -- [Spawnpunkt] = { T = Zeit, Key = Controller }
local function UseStart(Name, Key) Srv.UsedStarts[Name] = { T = os.time(), Key = Key } end
local function RecentlyUsed(Name, Key)
    local U = Srv.UsedStarts[Name]
    return U ~= nil and U.Key ~= Key and os.time() - U.T < RECENT_START
end

-- Zufaelliger Spawnpunkt ohne Zombies in 40 m (sonst der mit den wenigsten), nicht der ausgeschlossene und
-- moeglichst keiner, den eben ein anderer bekam
local function PickStart(ExcludeName, Key)
    local Starts, AI = SurvivalStarts(), LivingAI()
    local function Pick(SkipRecent)
        local Free, Best, BestN = {}, nil, math.huge
        for _, Start in ipairs(Starts) do
            local Name = Start:GetFullName()
            if Name ~= ExcludeName and not (SkipRecent and RecentlyUsed(Name, Key)) then
                local N = CountNear(Start:K2_GetActorLocation(), AI)
                if N == 0 then Free[#Free + 1] = Start end
                if N < BestN then Best, BestN = Start, N end
            end
        end
        return (#Free > 0 and Free[math.random(#Free)] or Best), #Free
    end
    local Start, Free = Pick(true)
    if not Start then Start, Free = Pick(false) end
    return Start, Free, #Starts
end

-- Wo ein Mitspieler erscheint (main.lua SpawnPawnFor): an einem zufaelligen Spawnpunkt des Spiels ohne Zombies
-- in der Naehe (verteilt ueber die Karte, nicht zweimal hintereinander derselbe), sonst am Startpunkt der Welt.
function Srv.SpawnPoint(World, PC, Loc, Yaw)
    local Key = PC:GetFullName()
    local Start, Free, Total = PickStart(Srv.LastStart[Key], Key)
    if Start then
        Srv.LastStart[Key], Srv.Placed[Key] = Start:GetFullName(), Start:GetFullName()
        UseStart(Start:GetFullName(), Key)
        Log("Mitspieler erscheint an einem Spawnpunkt (%d von %d ohne Zombies in 40 m)", Free, Total)
        return Start:K2_GetActorLocation(), Start:K2_GetActorRotation().Yaw
    end
    if Srv.Anchor then
        Log("Mitspieler erscheint am Startpunkt der Welt")
        return Srv.Anchor.Loc, Srv.Anchor.Yaw
    end
    return Loc, Yaw
end

-- join_v2 (main.lua Coop.Join): Figur steht schon am gewaehlten Ziel (gespeicherte Position oder Spawnpunkt). Nicht
-- mehr umsetzen und den Spawnpunkt-Vermerk von SpawnPoint verbrauchen (sonst galt er erst fuer den naechsten Respawn).
function Srv.MarkPlaced(Name, Key)
    if not Srv.SeenPawns[Name] then Srv.Restored[Name] = os.time() end   -- CORE-30: Zeit statt true (Srv.Prune)
    if Key then Srv.Placed[Key] = nil end
end

-- Neue Figur eines Mitspielers (Beitritt oder Respawn des Spiels): Das Spiel haelt sie ~10 s in der Luft fest,
-- in der Zeit ist sie unverwundbar (bis 3 s nach der Freigabe). Erscheint sie per Zufalls-Respawn des Spiels
-- an einem Spawnpunkt mit Zombies in der Naehe oder am selben wie zuletzt, an einen sicheren versetzen.
local function OnNewGuestPawn(G)
    local Name, Key = G.Pawn:GetFName():ToString(), G.PC:GetFullName()
    pcall(function() G.Pawn.bCanBeDamaged = false end)
    Srv.Protect[Name] = { Pawn = G.Pawn, Since = os.time() }
    local L, Near, NearD = G.Pawn:K2_GetActorLocation(), nil, math.huge
    for _, Start in ipairs(SurvivalStarts()) do
        local S = Start:K2_GetActorLocation()
        local D = math.sqrt((S.X - L.X) ^ 2 + (S.Y - L.Y) ^ 2 + (S.Z - L.Z) ^ 2)
        if D < NearD then Near, NearD = Start, D end
    end
    local Danger = CountNear(L, LivingAI())
    Log("Neue Figur %s bei %.0f %.0f %.0f: naechster Spawnpunkt %.0f m, %d KI-Figuren in 40 m, geschuetzt",
        Name, L.X, L.Y, L.Z, NearD / 100, Danger)
    if Srv.Restored[Name] then Srv.Restored[Name] = nil return end   -- join_v2: schon am Ziel (Srv.MarkPlaced)
    if not Near or NearD > 500 then return end            -- nicht an einem Spawnpunkt (z. B. Schlafsack)
    local NearName = Near:GetFullName()
    if Srv.Placed[Key] == NearName then Srv.Placed[Key] = nil return end   -- eben selbst so gesetzt
    local Taken = RecentlyUsed(NearName, Key)
    if Danger == 0 and Srv.LastStart[Key] ~= NearName and not Taken then
        Srv.LastStart[Key] = NearName
        UseStart(NearName, Key)
        return
    end
    local Start = PickStart(NearName, Key)
    if not Start then return end
    local S = Start:K2_GetActorLocation()
    G.Pawn:K2_TeleportTo({ X = S.X, Y = S.Y, Z = S.Z + 100 }, Start:K2_GetActorRotation())
    Srv.LastStart[Key] = Start:GetFullName()
    UseStart(Start:GetFullName(), Key)
    Log("Respawn versetzt (%s): an einen sicheren Spawnpunkt", Danger > 0 and "Zombies in der Naehe"
        or Taken and "anderer Mitspieler eben hier" or "gleicher Punkt wie zuletzt")
end

-- CORE-24 (log_quiet, auf dem Server Standard an): Diagnose-Logs nur mit dev=1 (wie main.lua Coop.LogQuiet)
function Srv.LogQuiet()
    if A.Settings.dev then return false end
    return Srv.Flag("log_quiet", true) == true
end

local function GuestSpawnTick(World)
    local Now = os.time()
    local MedicLog = not Srv.LogQuiet()
    for _, G in ipairs(Guests(World)) do
        if A.IsAlive(G.Pawn) and A.IsAlive(G.Pawn.PlayerState) then
            local Name = G.Pawn:GetFName():ToString()
            -- Diagnose Blutung: Zustand und Timer der Figur beim Server bei jeder Aenderung (CORE-24: nur mit dev=1
            -- bzw. log_quiet=0; sonst eine Zeile je Zustandswechsel und Figur auf einem Dauer-Server)
            if MedicLog then
                local okMed, Med = pcall(A.Coop.Medic.State, G.Pawn)
                if okMed and Srv.MedicLast[Name] ~= Med then
                    Srv.MedicLast[Name] = Med
                    Log("Medizin %s: %s", Name, Med)
                end
            end
            -- CORE-30: { T = zuletzt gesehen, P = Objekt-Pfad } fuer das Aufraeumen (Srv.Prune)
            local Seen = Srv.SeenPawns[Name]
            if type(Seen) == "table" then
                Seen.T = Now
            else
                Srv.SeenPawns[Name] = { T = Now, P = Srv.ObjPath(G.Pawn) }
                if not Seen then
                    local ok, err = pcall(OnNewGuestPawn, G)
                    if not ok then Log("Spawn-Pruefung: Fehler %s", tostring(err)) end
                end
            end
        end
    end
    for Name, P in pairs(Srv.Protect) do
        if not A.IsAlive(P.Pawn) then
            Srv.Protect[Name] = nil
        elseif not A.Safe(function() return A.Coop.Join.IsReady(P.Pawn) end, true) then
            -- join_v2: wartet noch hinter dem Ladebildschirm (eingefroren): Schutz laeuft erst ab ready ab
            P.Since, P.FreeAt = Now, nil
        else
            if not P.FreeAt and A.Safe(function()
                local Move = P.Pawn.CharacterMovement
                return A.IsAlive(Move) and Move.MovementMode ~= 0
            end, false) then
                P.FreeAt = Now
            end
            if (P.FreeAt and Now - P.FreeAt >= 3) or Now - P.Since > 45 then
                -- eingefroren (Verbindungsabbruch, main.lua Coop.Link): verwundbar erst beim Freigeben
                if not A.Safe(function() return A.Coop.Link.Defer(P.Pawn, true) end, false) then
                    pcall(function() P.Pawn.bCanBeDamaged = true end)
                end
                Srv.Protect[Name] = nil
                Log("Spawn-Schutz fuer %s beendet", Name)
            end
        end
    end
end

-- PLAYER-25 (E27, srv_endprotect): eigener Angriff beendet den Spawn-Schutz sofort (ls_combat: angenommener Relay-
-- Nahkampftreffer oder cb_sde-Schuss des Gasts, hoechstens alle 5 s je Gast), sonst erst 3 s nach der ersten
-- Bewegung bzw. nach 45 s. Gibt auch die Respawn-Sperre von ls_player frei (E28 A.Coop.Player.EndHold, falls da).
-- Aufrufer sind Aufgaben (Spiel-Thread), kein Hook. true = Schutz war aktiv und ist jetzt aus.
function Srv.EndProtect(PawnName)
    if type(PawnName) ~= "string" or PawnName == "" or not Srv.Flag("srv_endprotect", true) then return false end
    local ok, Res = pcall(function()
        local P, Ended = Srv.Protect[PawnName], false
        if P then
            Srv.Protect[PawnName], Ended = nil, true
            -- eingefroren (Verbindungsabbruch, main.lua Coop.Link): verwundbar erst beim Freigeben (wie GuestSpawnTick)
            if A.IsAlive(P.Pawn) and not A.Safe(function() return A.Coop.Link.Defer(P.Pawn, true) end, false) then
                pcall(function() P.Pawn.bCanBeDamaged = true end)
            end
            Log("Spawn-Schutz fuer %s beendet (eigener Angriff)", PawnName)
        end
        local Pl = A.Coop.Player
        if type(Pl) == "table" and type(Pl.EndHold) == "function" then
            local okH, errH = pcall(Pl.EndHold, PawnName)
            if not okH then Log("Respawn-Sperre (EndHold) fuer %s: Fehler %s", PawnName, tostring(errH)) end
        end
        return Ended
    end)
    if not ok then
        Log("Spawn-Schutz beenden (%s): Fehler %s", PawnName, tostring(Res))
        Srv.Fail("srv_endprotect", Res)
        return false
    end
    return Res == true
end

-- UE 5.6 ohne Grafik (NullRHI): SaveGameToSlot ruft BFL_SaveGames.SaveThumbnailImage auf (SceneCapture +
-- EMS ExportSaveThumbnail). Das stuerzte den Server beim ersten Autosave ab (23.10. 20:45, Zugriff auf 0x0,
-- drei Blueprint-Ebenen tief = in SaveThumbnailImage). Ein Vorschaubild braucht der Server nicht:
-- 1. DLL-Patch ret_early (nur wenn die Anfangsbytes 4C F5 = PushExecutionFlow ->0x02F5 passen, sonst nichts),
-- 2. Rueckfall: Vorschau-Kamera der Server-Figur entfernen (SaveThumbnailImage prueft IsValid/Tag und laesst aus).
-- Schalter srv_nothumb (Standard an).
local THUMB_FN = "/Game/Blueprints/Saves/BFL_SaveGames.BFL_SaveGames_C:SaveThumbnailImage"
local CAPTURE_CLS = "/Script/Engine.SceneCaptureComponent2D"
function Srv.NoThumb(Pawn)
    if Srv.Flag("srv_nothumb", true) ~= true then return end
    if not Srv.ThumbPatched then
        local Core = package.loaded["ls_core"]
        local Fn = A.Safe(function() return StaticFindObject(THUMB_FN) end)
        if type(Core) == "table" and type(Core.SetPatch) == "function" and Fn and A.IsAlive(Fn) then
            local Addr = A.Safe(function() return Fn:GetAddress() end)
            if Addr and Core.SetPatch("srv_nothumb", string.format("srv_nothumb ret_early %x 0 4CF5 040B 1", Addr)) then
                Srv.ThumbPatched = true
                Log("Speicher-Vorschaubild auf dem Server abgeschaltet (Patch srv_nothumb angefordert)")
            end
        end
    end
    if Pawn and A.IsAlive(Pawn) then
        local Removed = A.Safe(function()
            local Cls = StaticFindObject(CAPTURE_CLS)
            if not A.IsAlive(Cls) then return false end
            local Comp = Pawn:GetComponentByClass(Cls)
            if not A.IsAlive(Comp) then return false end
            Comp:K2_DestroyComponent(Comp)
            return true
        end, false)
        if Removed then Log("Vorschau-Kamera der Server-Figur entfernt (kein Speicher-Vorschaubild ohne Grafik)") end
    end
end

function Srv.Save(Reason)
    local PC = A.LocalPC()
    local Pawn = OwnPawn()
    if not Pawn or not A.IsAlive(PC) then Log("Speichern uebersprungen (%s): keine Welt geladen", Reason) return false end
    pcall(Srv.NoThumb, Pawn)
    -- Server-Figur vorher an den Startpunkt am Boden stellen: sonst steht sie im Spielstand in der Luft.
    -- Sie kehrt erst nach 15 s zu den Mitspielern zurueck (Speichern laeuft ueber mehrere Frames).
    if Srv.Anchor then
        pcall(function() Pawn:K2_SetActorLocation(Srv.Anchor.Loc, false, {}, true) end)
        Srv.GhostAt = os.time() + 15
    end
    -- Speichert in den aktuellen Spielstand (wie der Autosave des Spiels, ohne neuen Slot)
    local ok, err = pcall(function() PC:SaveGameToSlot() end)
    pcall(A.Coop.StoreGuestsNow)
    -- Gast-Quests zusammen mit den Inventaren speichern (sonst ~2 s Verlustfenster nach Quest-Aenderung)
    local W = A.Coop.Modules and A.Coop.Modules.ls_world
    if W and W.SaveQuests then pcall(W.SaveQuests) end
    -- CAR-8: Fahrzeug-Besitz (ls_car, car_owners.txt) mit der Welt speichern
    local Car = A.Coop.Modules and A.Coop.Modules.ls_car
    if type(Car) == "table" and type(Car.StoreOwners) == "function" then
        local okCar, errCar = pcall(Car.StoreOwners)
        if not okCar then Log("Fahrzeug-Besitz nicht gespeichert: %s", tostring(errCar)) end
    end
    Srv.SavedAt = os.time()
    -- Gast-Inventare erst festschreiben, wenn die Welt fertig gespeichert ist (Srv.Journal.Tick / stopping).
    -- Den Stand dazu jetzt (gleicher Frame wie der Welt-Schnappschuss) einfrieren: das live .sav schreibt ls_inv
    -- danach weiter, bis zum Festschreiben (+2 s) genommene Kisten-Items waeren sonst nach einem Absturz doppelt.
    if ok then
        if Srv.Journal.On() then
            pcall(Srv.Journal.Freeze)
            local okOwn, errOwn = pcall(Srv.Journal.OwnFreeze)   -- BUILD-9: owners.txt zum Welt-Stand
            if not okOwn then Log("[Journal] Besitz-Stand: Fehler %s", tostring(errOwn)) Srv.Fail("srv_ownjournal", errOwn) end
        end
        Srv.Journal.CommitAt = os.time() + 2
        pcall(Srv.Journal.FastCommit)   -- CORE-4: im Schnell-Loop festschreiben, sobald EMS fertig ist
    end
    Log("Welt gespeichert (%s)%s", Reason, ok and "" or (": Fehler " .. tostring(err)))
    return ok
end

-- Gast-Inventare und Welt gemeinsam: Die Gast-Slots (NetTest_Guests/<Id>.sav) schreibt der Host alle paar
-- Sekunden, die Welt nur bei Srv.Save. Stuerzt der Server dazwischen ab, passt beides nicht zusammen (aus
-- einer Kiste genommen = doppelt, verbaut = weg). Darum: nach jedem fertigen Welt-Speichern eine Kopie je
-- Gast (<Id>.commit, kein .sav: das Spiel sieht sie nicht) und ein Journal (guest_journal.txt) der seither
-- beruehrten Gaeste. Beim Start mit nicht leerem Journal (= kein sauberes Ende) die Kopien zurueckspielen;
-- der verworfene Stand bleibt als <Id>.crash liegen. Nur Dateien, keine UObjects (auch aus Srv.Init).
Srv.Journal = { Dirty = {}, Seen = {}, CommitAt = nil }
local J = Srv.Journal

function J.Dir() return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\" end
function J.File() return A.ModDir .. "guest_journal.txt" end
function J.On() return not (A.Settings and A.Settings.local_inventory) end
local function JValid(Id) return type(Id) == "string" and Id:match("^[%w_%-]+$") ~= nil end

function J.Exists(Path)
    local F = io.open(Path, "rb")
    if F then F:close() return true end
    return false
end

-- Frueher unterbrochenes Ersetzen (Path fehlt, Path.old da): den alten Stand zurueck an seinen Platz
function J.Recover(Path)
    if J.Exists(Path) or not J.Exists(Path .. ".old") then return end
    if os.rename(Path .. ".old", Path) then Log("[Journal] %s fehlte - aus .old wiederhergestellt", Path) end
end

-- Datei kopieren ueber eine .tmp (nie eine halbe Zieldatei), Rotation wie Core.WriteAtomic: Ziel nach .old,
-- .tmp an seinen Platz, bei Fehlschlag .old zurueck. Nie eine Datei loeschen, die den einzigen guten Stand
-- haelt (Ziel fehlt + .old da = frueher unterbrochen: .old bleibt, bis die neue Kopie sitzt). true = kopiert
function J.Copy(From, To)
    J.Recover(From)
    local In = io.open(From, "rb")
    if not In then return false end
    local Data = In:read("*a")
    In:close()
    if not Data then return false end
    local Tmp, Old = To .. ".tmp", To .. ".old"
    local Out = io.open(Tmp, "wb")
    if not Out then return false end
    local okW = Out:write(Data)
    if not Out:close() then okW = false end
    if not okW then os.remove(Tmp) return false end
    if J.Exists(To) then os.remove(Old) end   -- sonst ist .old der letzte gute Stand: bleibt
    local Had = os.rename(To, Old) and true or false
    for _ = 1, 3 do
        if os.rename(Tmp, To) then
            os.remove(Old)
            return true
        end
    end
    if Had and not os.rename(Old, To) then
        Log("[Journal] FEHLER: %s nicht ersetzbar - Stand liegt in .tmp/.old", To)
        return false
    end
    if Had then os.remove(Tmp) end   -- alter Stand wieder an seinem Platz
    Log("[Journal] %s nicht ersetzbar - alter Stand bleibt%s", To, Had and "" or " (neuer in .tmp)")
    return false
end

-- Runde 9 (srv_journal_v2): Journal atomar mit Merkern (CORE-4), nur verbundene Gaeste (CORE-3), Werte/Bett (PLAYER-28)
function J.V2() return Srv.Flag("srv_journal_v2", true) == true end

-- Journal-Datei: je Zeile eine Mitspieler-ID. srv_journal_v2 dazu die Merker des laufenden Festschreibens (CORE-4):
-- "#F <n>" Gast-Staende zum Welt-Speichern n eingefroren (.pending), "#S <n>" Welt-Speichern n fertig (EMS frei),
-- "#N <Id>" Gast hatte beim Einfrieren keinen Slot (Tod), "#P <Id>" Gast wurde in diesem Durchlauf eingefroren
-- (nur seine .pending darf J.Rollback uebernehmen), "#V 2" = Journal kennt "#P". Atomar (Core.WriteAtomic); ohne
-- Schalter die alte Form.
function J.Write()
    if not J.V2() then
        local F = io.open(J.File(), "w")
        if not F then return false end
        for Id in pairs(J.Dirty) do F:write(Id, "\n") end
        F:close()
        return true
    end
    local Lines = {}
    for Id in pairs(J.Dirty) do Lines[#Lines + 1] = Id end
    if J.PendF then
        Lines[#Lines + 1] = "#F " .. J.PendF
        if J.PendS then Lines[#Lines + 1] = "#S " .. J.PendS end
        -- Eingefrorene Menge aus J.PendIds (nicht J.Frozen: das ist nach J.Commit schon nil, die Merker bleiben bei
        -- "Bad > 0" aber bis zum naechsten Einfrieren stehen)
        Lines[#Lines + 1] = "#V 2"
        for Id, Had in pairs(J.PendIds or {}) do
            Lines[#Lines + 1] = (Had == true and "#P " or "#N ") .. Id
        end
    end
    return Srv.WriteText(J.File(), table.concat(Lines, "\n") .. "\n")
end

-- PLAYER-28 (srv_journal_v2): Werte (<Id>.werte.txt) und Bett (<Id>.spawn.txt) wie das Inventar: Kopie <Id><Art>.commit
-- beim Festschreiben, zurueck beim Start nach unsauberem Ende. Quelle notfalls .bak (Core.WriteAtomic unterbrochen).
-- Fehler zaehlen nicht als Inventar-Fehler. Ohne Schalter werden alte Kopien geloescht (nie einen veralteten Stand
-- zurueckspielen).
J.SIDE = { ".werte", ".spawn" }
function J.SideSrc(Path)
    if J.Exists(Path) then return Path end
    if J.Exists(Path .. ".bak") then return Path .. ".bak" end
    return nil
end

-- OnlyNew: nur, wenn es noch keine Kopie gibt (Sitzungsbeginn, J.Mark)
function J.SideCommit(Base, OnlyNew)
    for _, Kind in ipairs(J.SIDE) do
        local Src, Dst = J.SideSrc(Base .. Kind .. ".txt"), Base .. Kind .. ".commit"
        if Src and not (OnlyNew and J.Exists(Dst)) and not J.Copy(Src, Dst) then
            Log("[Journal] %s nicht festgeschrieben", Dst)
        end
    end
end

function J.SideDrop(Base)
    for _, Kind in ipairs(J.SIDE) do os.remove(Base .. Kind .. ".commit") end
end

-- Start nach unsauberem Ende: nur mit Kopie zuruecksetzen (ohne Kopie bleibt die Datei); verworfener Stand -> .crash
function J.SideRollback(Base)
    local N = 0
    for _, Kind in ipairs(J.SIDE) do
        local Cur, Com, Crash = Base .. Kind .. ".txt", Base .. Kind .. ".commit", Base .. Kind .. ".crash"
        if J.Exists(Com) then
            os.remove(Crash)
            local Moved = J.Exists(Cur) and os.rename(Cur, Crash)
            if J.Copy(Com, Cur) then
                os.remove(Cur .. ".bak")   -- ReadAll soll keinen verworfenen Stand zurueckholen
                N = N + 1
            elseif Moved and not J.Exists(Cur) then
                os.rename(Crash, Cur)   -- lieber der Absturz-Stand als Startwerte
            end
        end
    end
    return N
end

-- BUILD-9 (srv_ownjournal): Besitz/Claims/Schloesser (owners.txt, ls_build) passen nach einem Absturz zur Welt.
-- Beim Welt-Speichern schreibt ls_build seinen Stand (E17 Coop.Build.Flush) -> Kopie owners.pending; nach dem
-- Festschreiben -> owners.commit; beim Start nach unsauberem Ende -> owners.txt (vor ls_build, das erst spaeter laedt).
function J.OwnPath(Ext) return A.ModDir .. "owners" .. Ext end

function J.OwnFreeze()
    if not Srv.Flag("srv_ownjournal", true) then
        os.remove(J.OwnPath(".pending"))
        os.remove(J.OwnPath(".commit"))   -- ohne Schalter nie einen alten Stand zurueckspielen
        return
    end
    local B = A.Coop.Build
    if type(B) == "table" and type(B.Flush) == "function" then
        local ok, err = pcall(B.Flush)
        if not ok then Log("[Journal] Besitz-Stand nicht geschrieben (Coop.Build.Flush): %s", tostring(err)) end
    end
    local Src = J.SideSrc(J.OwnPath(".txt"))
    if not (Src and J.Copy(Src, J.OwnPath(".pending"))) then os.remove(J.OwnPath(".pending")) end
end

function J.OwnCommit()
    local Pend = J.OwnPath(".pending")
    if Srv.Flag("srv_ownjournal", true) and J.Exists(Pend) and J.Copy(Pend, J.OwnPath(".commit")) then os.remove(Pend) end
end

-- Saved: Welt-Speichern war fertig, Festschreiben fehlte -> erst owners.pending uebernehmen
function J.OwnRollback(Saved)
    if not Srv.Flag("srv_ownjournal", true) then return end
    local Pend, Com = J.OwnPath(".pending"), J.OwnPath(".commit")
    if Saved and J.Exists(Pend) and J.Copy(Pend, Com) then os.remove(Pend) end
    if not J.Exists(Com) then return end
    if J.Copy(Com, J.OwnPath(".txt")) then
        os.remove(J.OwnPath(".txt.bak"))
        Log("Besitz/Claims (owners.txt) auf den letzten Welt-Speicherstand gesetzt")
    else
        Log("[Journal] owners.txt nicht zurueckgesetzt (Kopie gescheitert)")
    end
end

-- Neu gesehener Gast: ins Journal, bevor sein Slot in dieser Sitzung geschrieben wird. Hat er noch keine
-- Kopie (erster Start mit Journal), den unveraenderten Slot vom Sitzungsbeginn als Kopie nehmen.
function J.Mark(Id)
    if not JValid(Id) or J.Dirty[Id] then return end
    if not J.Seen[Id] then
        J.Seen[Id] = true
        local Base = J.Dir() .. Id
        J.Recover(Base .. ".commit")
        J.Recover(Base .. ".sav")
        if not J.Exists(Base .. ".commit") and J.Exists(Base .. ".sav") then J.Copy(Base .. ".sav", Base .. ".commit") end
        if J.V2() then J.SideCommit(Base, true) end   -- PLAYER-28: Werte/Bett vom Sitzungsbeginn
    end
    J.Dirty[Id] = true
    J.Write()
end

-- Nach fertigem Welt-Speichern: Slots aller beruehrten Gaeste festschreiben, Journal auf die noch Verbundenen.
-- Final (Server stoppt): danach schreibt niemand mehr -> Journal ganz weg (naechster Start ohne Zuruecksetzen).
-- Srv.Save, direkt nach StoreGuestsNow: Slots aller beruehrten Gaeste nach <Id>.pending kopieren (Stand zum
-- Welt-Schnappschuss). Nur wenn ls_inv sofort gespeichert hat (StoreAll); der alte Weg speichert erst im naechsten
-- Durchlauf -> dann wie bisher beim Festschreiben das live .sav nehmen (J.Frozen = nil).
function J.Freeze()
    J.Frozen = nil
    J.PendIds = nil   -- eingefrorene Menge eines frueheren (auch abgebrochenen) Durchlaufs nie stehen lassen
    -- CORE-4: Merker eines frueheren Durchlaufs zuerst weg (sonst passten Merker und .pending nicht zusammen)
    if J.PendF then J.PendF, J.PendS = nil, nil J.Write() end
    local InvMod = A.Coop.Modules and A.Coop.Modules.ls_inv
    if not (InvMod and InvMod.StoreAll) then return end
    local Dir, Fr, N = J.Dir(), {}, 0
    for Id in pairs(J.Dirty) do
        local Base = Dir .. Id
        if J.Exists(Base .. ".sav") then
            if not J.Copy(Base .. ".sav", Base .. ".pending") then
                Log("Gast-Inventar %s nicht eingefroren: Festschreiben nimmt den aktuellen Stand", Id)
                return
            end
            Fr[Id], N = true, N + 1
        else
            os.remove(Base .. ".pending")
            Fr[Id] = false   -- kein Slot (Tod) zum Zeitpunkt des Welt-Speicherns
        end
    end
    J.Frozen = Fr
    if J.V2() then
        -- CORE-3: wer beim Einfrieren verbunden war, bleibt bis zum naechsten Festschreiben im Journal (sein .sav kann
        -- danach noch geschrieben werden, z. B. beim Trennen)
        J.FreezeLive = {}
        for _, Id in ipairs(J.Ids()) do J.FreezeLive[Id] = true end
        -- CORE-4: Merker "#F" erst nach vollstaendigem Einfrieren (alle .pending gehoeren dann zu diesem Durchlauf)
        J.FreezeSeq = (J.FreezeSeq or 0) + 1
        J.PendF, J.PendS = J.FreezeSeq, nil
        -- Welche IDs dieser Durchlauf eingefroren hat (true) bzw. ohne Slot (false): nur diese .pending uebernimmt
        -- J.Rollback (spaeter per J.Mark dazugekommene Gaeste stehen zwar im Journal, ihre .pending kann alt sein)
        J.PendIds = {}
        for Id, Had in pairs(Fr) do J.PendIds[Id] = Had end
        J.Write()
    end
    Log("Gast-Inventare zum Welt-Speicherstand eingefroren (%d)", N)
end

function J.Commit(Final)
    J.CommitAt = nil
    local V2 = J.V2()
    local Dir, N, Bad = J.Dir(), 0, 0
    local Fr = J.Frozen
    J.Frozen = nil
    -- CORE-10 (srv_store_freeze): beim Beenden schreibt nach dem Einfrieren niemand mehr Gast-Slots (E22) ->
    -- der eingefrorene Stand gilt auch fuers .sav (.sav = .commit = gespeicherte Welt)
    local ToSav = Final and A.Coop.GuestStoreFrozen == true and Srv.Flag("srv_store_freeze", true)
    if Fr then
        for Id, Had in pairs(Fr) do
            local Base = Dir .. Id
            if Had then
                if J.Copy(Base .. ".pending", Base .. ".commit")
                    and (not ToSav or J.Copy(Base .. ".pending", Base .. ".sav")) then
                    N = N + 1
                    os.remove(Base .. ".pending")
                else
                    Bad = Bad + 1
                end
            else
                os.remove(Base .. ".commit")   -- kein Slot (Tod): passt zur gespeicherten Welt
            end
            if V2 then J.SideCommit(Base) else J.SideDrop(Base) end   -- PLAYER-28
        end
    else
        for Id in pairs(J.Dirty) do
            local Base = Dir .. Id
            if J.Exists(Base .. ".sav") then
                if J.Copy(Base .. ".sav", Base .. ".commit") then N = N + 1 else Bad = Bad + 1 end
            else
                os.remove(Base .. ".commit")   -- kein Slot (Tod): passt zur gespeicherten Welt
            end
            -- Reste eines abgebrochenen Einfrierens: kein "#P" verweist darauf, also nur Aufraeumen
            if V2 then os.remove(Base .. ".pending") end
            if V2 then J.SideCommit(Base) else J.SideDrop(Base) end   -- PLAYER-28
        end
    end
    local okOwn, errOwn = pcall(J.OwnCommit)   -- BUILD-9: owners.pending -> owners.commit (die Welt ist gespeichert)
    if not okOwn then Log("[Journal] Besitz-Stand: Fehler %s", tostring(errOwn)) Srv.Fail("srv_ownjournal", errOwn) end
    if Bad > 0 then
        Log("Gast-Inventare: %d von %d nicht festgeschrieben (Journal bleibt)", Bad, N + Bad)
        return
    end
    -- Nach dem Einfrieren neu beruehrte Gaeste bleiben im Journal (ihre .commit passt noch zur Welt)
    local Keep = {}
    if Fr then
        for Id in pairs(J.Dirty) do if Fr[Id] == nil then Keep[Id] = true end end
        -- CORE-3: beim Einfrieren Verbundene bleiben bis zum naechsten Festschreiben (getrennt nach dem Einfrieren:
        -- ihr letztes .sav ist neuer als die Welt). Nicht beim Beenden: dort ist der Stand eingefroren.
        if V2 and not Final then for Id in pairs(J.FreezeLive or {}) do Keep[Id] = true end end
    end
    J.FreezeLive = nil
    J.Dirty = Keep
    J.PendF, J.PendS, J.PendIds = nil, nil, nil   -- CORE-4: Festschreiben fertig, Merker weg
    if Final and next(Keep) == nil then
        if V2 then Srv.RemoveFile(J.File()) else os.remove(J.File()) end
    else
        if not Final then
            for _, Id in ipairs(J.Ids()) do J.Dirty[Id] = true end
        end
        J.Write()
    end
    if N > 0 then Log("Gast-Inventare mit der Welt festgeschrieben (%d)", N) end
    -- CORE-5: Welt und Gast-Kopien passen jetzt zusammen -> Sicherung bei start.sh anfordern (nicht beim Beenden:
    -- start.sh sichert beim naechsten Start ohnehin)
    if not Final then pcall(Srv.BackupRequest) end
end

-- CORE-4: Welt-Speichern ist fertig (EMS frei): erst Merker "#S" schreiben, dann festschreiben. Stirbt der Server
-- dazwischen, uebernimmt J.Rollback die eingefrorenen .pending (sie passen zur fertig gespeicherten Welt).
function J.CommitNow(Final)
    if J.PendF and J.V2() then
        J.PendS = J.PendF
        J.Write()
    end
    J.Commit(Final)
end

-- CORE-4: im Schnell-Loop (100 ms) festschreiben, sobald CommitAt erreicht und EMS fertig ist (der 1-s-Tick ist der
-- Rueckfall). Nie im Zustand stopping: dort schreibt Tick mit Final fest (Journal danach leer).
function J.FastCommit()
    if not (J.On() and J.V2()) then return end
    pcall(A.Coop.AddFast, "srvcommit", function(_, _, World)
        if not J.CommitAt or Srv.StopAt or Srv.State ~= "running" then return true end
        if os.time() < J.CommitAt or Srv.Busy(World) then return false end
        local ok, err = pcall(J.CommitNow)
        if not ok then
            Log("Gast-Journal-Fehler (Festschreiben): %s", tostring(err))
            Srv.Fail("srv_journal_v2", err)
        end
        return true
    end)
end

-- Verbundene Gaeste mit gueltiger ID, ohne Doppel-Login (A.Coop.GuestDup[Key]: zweite Verbindung mit derselben
-- Mitspieler-ID, fuer sie wird nichts geladen/gespeichert - main.lua G.HandleHost)
function J.Ids()
    local Ids, Dup, Live = {}, A.Coop.GuestDup or {}, nil
    if J.V2() then
        -- CORE-3: nur VERBUNDENE Gaeste (Coop.GuestIds vergisst getrennte Verbindungen nie)
        Live = {}
        for _, G in ipairs(Guests(A.CurrentWorld())) do
            local K = A.Safe(function() return G.PC:GetFullName() end)
            if K then Live[K] = true end
        end
    end
    for Key, Id in pairs(A.Coop.GuestIds or {}) do
        if not Dup[Key] and JValid(Id) and (not Live or Live[Key]) then Ids[#Ids + 1] = Id end
    end
    return Ids
end

-- Running: Gaeste ins Journal, festschreiben, sobald das Speichern der Welt durch ist
function J.Tick(World)
    if not J.On() then
        -- lokales Inventar (kein Journal): Sicherung trotzdem nach fertigem Welt-Speichern anfordern (CORE-5)
        if J.CommitAt and os.time() >= J.CommitAt and not Srv.Busy(World) then
            J.CommitAt = nil
            pcall(Srv.BackupRequest)
        end
        return
    end
    for _, Id in ipairs(J.Ids()) do J.Mark(Id) end
    if J.CommitAt and os.time() >= J.CommitAt and not Srv.Busy(World) then J.CommitNow() end
end

-- Start (Srv.Init): Journal nicht leer -> letzter Lauf ohne sauberes Ende -> Gast-Slots auf den Stand
-- des letzten Welt-Speicherns zuruecksetzen
function J.Rollback()
    -- CORE-4: liest bei fehlender Datei ein liegengebliebenes .bak (Core.WriteAtomic unterbrochen)
    local Text = Srv.ReadText(J.File())
    if not Text then return end
    local Ids, Mark, NoSlot, Frozen = {}, {}, {}, {}
    for Line in Text:gmatch("[^\r\n]+") do
        local Id = Line:match("^%s*(.-)%s*$")
        local Tag, Value = Id:match("^#([FSNPV])%s+(%S+)$")
        if Tag == "N" then NoSlot[Value] = true
        elseif Tag == "P" then Frozen[Value] = true   -- vor dem allgemeinen Zweig (sonst landete "#P" in Mark.P)
        elseif Tag then Mark[Tag] = Value
        elseif JValid(Id) then Ids[#Ids + 1] = Id end
    end
    -- "#S" = "#F": das Welt-Speichern war fertig, nur das Festschreiben fehlte -> die eingefrorenen Staende gelten
    local Saved = Mark.F ~= nil and Mark.F == Mark.S
    -- .pending nur von Gaesten, die dieser Durchlauf eingefroren hat ("#P"). Journal ohne "#V" (aelterer Stand,
    -- kennt kein "#P"): wie bisher jede .pending der gelisteten IDs
    local Adopt = function(Id) return Saved and (Mark.V == nil or Frozen[Id] == true) end
    local okOwn, errOwn = pcall(J.OwnRollback, Saved)   -- BUILD-9 (auch ohne Gaeste im Journal)
    if not okOwn then Log("[Journal] owners.txt: Fehler %s", tostring(errOwn)) end
    if #Ids == 0 then Srv.RemoveFile(J.File()) return end
    if not J.On() then
        Log("Gast-Journal: lokales Inventar aktiv, %d Eintrag/Eintraege nicht zurueckgesetzt", #Ids)
        Srv.RemoveFile(J.File())
        return
    end
    local Dir, Back, Fresh, Pend, Side = J.Dir(), 0, 0, 0, 0
    local V2 = J.V2()
    for _, Id in ipairs(Ids) do
        local Base = Dir .. Id
        J.Recover(Base .. ".sav")
        J.Recover(Base .. ".commit")
        if Saved and NoSlot[Id] then
            os.remove(Base .. ".commit")   -- beim fertigen Welt-Speichern ohne Slot (Tod): passt zur Welt
            Pend = Pend + 1
        elseif Adopt(Id) and J.Exists(Base .. ".pending") and J.Copy(Base .. ".pending", Base .. ".commit") then
            os.remove(Base .. ".pending")
            Pend = Pend + 1
        end
        -- Veraltete .pending (nicht uebernehmbar) aufraeumen; eine uebernehmbare mit gescheiterter Kopie bleibt
        -- fuers Wiederherstellen von Hand liegen
        if V2 and not Adopt(Id) then os.remove(Base .. ".pending") end
        if V2 then Side = Side + J.SideRollback(Base) end   -- PLAYER-28: Werte/Bett
        if J.Exists(Base .. ".sav") then
            os.remove(Base .. ".crash")
            os.rename(Base .. ".sav", Base .. ".crash")   -- verworfener Stand bleibt erhalten
        end
        if J.Exists(Base .. ".commit") then
            if J.Copy(Base .. ".commit", Base .. ".sav") then
                Back = Back + 1
            elseif not J.Exists(Base .. ".sav") and os.rename(Base .. ".crash", Base .. ".sav") then
                -- lieber den Absturz-Stand als die Startausruestung
                Log("Gast-Inventar %s nicht zurueckgesetzt (Kopie gescheitert) - Absturz-Stand bleibt", Id)
            end
        else
            Fresh = Fresh + 1   -- erst nach dem letzten Welt-Speichern dazugekommen: startet wie neu
        end
        J.Seen[Id] = true
    end
    Srv.RemoveFile(J.File())
    if Pend > 0 then
        Log("Welt-Speichern war fertig, Festschreiben fehlte: %d eingefrorene(r) Gast-Stand/Staende uebernommen", Pend)
    end
    Log("Letzter Lauf ohne sauberes Ende: %d Gast-Inventar(e) auf den letzten Welt-Speicherstand gesetzt, %d ohne Stand (neu)%s",
        Back, Fresh, Side > 0 and string.format(", %d Werte-/Bett-Datei(en) zurueckgesetzt", Side) or "")
end

-- CORE-5 (srv_save_backup): nach erfolgreichem Festschreiben (Welt und Gast-Kopien .commit passen zusammen) bei
-- start.sh eine Sicherung anfordern: backup_req.txt (atomar), start.sh kopiert saves/ nach saves/_backup/<Zeit>.
-- Hoechstens alle LASTSIGNAL_BACKUP_MINUTES (Standard 30, 0 = nur die Sicherung von start.sh beim Start); die erste
-- Frist zaehlt ab dem Start (start.sh sichert vor dem Spielstart).
function Srv.BackupRequest()
    local Minutes = Srv.Cfg and Srv.Cfg.BackupMinutes or 0
    if Minutes <= 0 or os.time() < (Srv.BackupAt or 0) or not Srv.Flag("srv_save_backup", true) then return false end
    Srv.BackupAt = os.time() + 60 * Minutes
    local ok = Srv.WriteText(A.ModDir .. "backup_req.txt", os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    Log("Sicherung des Spielstands %s (backup_req.txt fuer start.sh, naechste fruehestens in %d min)",
        ok and "angefordert" or "NICHT angefordert (Datei nicht schreibbar)", Minutes)
    return ok
end

-- CORE-5 (srv_auto_restore, Standard aus): Welt-Spielstand kaputt (CheckSaveFiles OnFailed) -> restore_req.txt; start.sh
-- spielt beim naechsten Start die neueste Sicherung ein (Teil von start.sh, siehe SERVER.md)
function Srv.RestoreRequest(Why)
    if not Srv.Flag("srv_auto_restore", false) then return false end
    local ok = Srv.WriteText(A.ModDir .. "restore_req.txt", os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(Why) .. "\n")
    Log("Spielstand nicht ladbar: Wiederherstellung der neuesten Sicherung %s (restore_req.txt, start.sh)",
        ok and "angefordert" or "NICHT angefordert (Datei nicht schreibbar)")
    return ok
end

local function Busy(World) return Srv.Busy(World) end   -- CORE-20: EMS-CDO nur nach IsAlive

-- Aufraeumen: Das Spiel entfernt weder tote Zombies (der AI-Optimizer nur lebende, der Spawner vergisst
-- getoetete) noch Todes-Kisten von Spielern (nur ihre Karten-Markierung laeuft nach 20 min ab). Auf einem
-- Dauer-Server sammeln sie sich an, und jede nahe einem Mitspieler geht danach an alle. Nach der
-- eingestellten Zeit verschwinden sie samt Inhalt, aber nie, solange ein Spieler in 15 m steht (offenes
-- Loot-Fenster). BP_MainEnemy_C = alle Zombies samt Hunden und Bossen (Tiere/Menschen: andere Klassen).
local CLEANUP_CHECK, CLEANUP_NEAR = 30, 1500
local CLEANUP = {
    { Class = "BP_MainEnemy_C", Setting = "CorpseMinutes", What = "Leiche(n)",
      Ready = function(Char)   -- IsDead? (BP_MasterZombie/BP_ZombieBoss) oder Dead (BP_AI_C), je einzeln lesen
          return A.Safe(function() return Char["IsDead?"] == true end, false) or A.Safe(function() return Char.Dead == true end, false)
      end,
      Where = function(Char)
          local Mesh = Char.Mesh
          if not A.IsAlive(Mesh) then return nil end
          return Mesh:K2_GetComponentLocation()
      end },   -- ohne Kapsel: Actor bei 0,0,0
    { Class = "Container_DeadPlayerLoot_C", Setting = "DeathboxMinutes", What = "Todes-Kiste(n)",
      Ready = function() return true end,
      Where = function(Box) return Box:K2_GetActorLocation() end },
    -- Von Spielern fallengelassene Gegenstaende (nicht das Loot der Welt): gemerkt von Srv.DropScan (nach dem
    -- Fallenlassen-Hook, srv_drophook_first) und von Srv.DropForPlayer, gleiche Zeit wie Leichen. Aufgehobene sind
    -- zerstoert und fallen von selbst heraus. Srv.Dropped: Name -> Objekt-Pfad (kein UObject ueber Ticks halten), hier
    -- frisch per StaticFindObject. Closeout: nur Pickups (Srv.IsPickup), nie ein anderer Actor; wieder ausgeruestete
    -- (Srv.Held: Owner/Anhaenge-Eltern, persistente Actors werden wiederverwendet) fallen heraus -> Alter neu beim
    -- naechsten Abwurf statt des alten (sonst nach erneutem Fallenlassen sofort weg). Closeout R2: aufheben und neu
    -- ablegen ZWISCHEN zwei Pruefungen (30 s) sieht Srv.Held hier nicht -> Ort/Drehung seit der letzten Pruefung
    -- veraendert (Srv.DropMoved, srv_drop_moved) = Alter ab jetzt; dazu alle 2 s Srv.DropHeldScan (srv_drop_heldscan).
    { Setting = "CorpseMinutes", What = "fallengelassene Gegenstaende",
      Objects = function()
          local List, Moved = {}, Srv.Flag("srv_drop_moved", true) == true
          for Name, Path in pairs(Srv.Dropped) do
              local Obj = type(Path) == "string" and A.Safe(function() return StaticFindObject(Path) end) or nil
              if A.IsAlive(Obj) and Srv.IsPickup(Obj) and not Srv.Held(Obj) then
                  if Moved then
                      local okM, Res = pcall(Srv.DropMoved, Name, Obj)
                      if not okM then Srv.Fail("srv_drop_moved", Res)
                      elseif Res then Srv.DeadSince[Name] = nil end   -- neu abgelegt (auch am selben Fleck): Alter ab jetzt
                  end
                  List[#List + 1] = Obj
              else
                  Srv.Dropped[Name], Srv.DropLoc[Name] = nil, nil
              end
          end
          return List
      end,
      Ready = function() return true end,
      Where = function(Obj) return Obj:K2_GetActorLocation() end },
}
Srv.DeadSince, Srv.CleanupAt, Srv.Removed, Srv.Dropped, Srv.DropRep = {}, 0, {}, {}, {}
-- Closeout R2: letzter Ort/Drehung je fallengelassenem Gegenstand (Name -> Zahlen, kein UObject), Srv.DropMoved.
-- Schwellen: Abstand (uu) und Drehung (Grad) seit der letzten Aufraeum-Pruefung; Abstand des Held-Scans (s)
Srv.DropLoc, Srv.HeldScanAt = {}, 0
Srv.DROPMOVE = { DIST = 20, ANG = 5, HELDSCAN = 2 }
Srv.DropEv = {}   -- Zeitpunkte (os.time) der Fallenlassen-Hook-Aufrufe, abgearbeitet in Srv.DropScan
-- Srv.DropScan: Pickup-Basisklassen (alle Pickup-Klassen erben davon, Decode analysis56\bp: 682 Klassen), Radius um
-- einen Mitspieler (uu; GetDropLocation = Ort der Figur), Zeitpuffer und Hoechstfenster (s), Ereignisse je Schub
Srv.DROPSCAN = { CLASSES = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }, NEAR = 600, PAD = 3, MAXWIN = 15, EVENTS = 64 }
Srv.PICKUP_BASES = { BP_StaticMeshPickup_C = true, BP_SkeletalMeshPickup_C = true }

-- Objekt-Pfad eines UObject ("Klasse /Pfad" -> "/Pfad"), nil ohne
function Srv.ObjPath(Obj)
    return A.Safe(function() return Obj:GetFullName():match("^%S+%s+(%S+)$") end)
end

-- Closeout: nur Pickups duerfen in Srv.Dropped/Srv.DropRep (das Aufraeumen zerstoert, DropRepTick repliziert sie).
-- Klassenkette hoch bis zu einer der beiden Pickup-Basisklassen. Nie im Hook.
function Srv.IsPickup(Obj)
    if not A.IsAlive(Obj) then return false end
    return A.Safe(function()
        local C = Obj:GetClass()
        for _ = 1, 32 do
            if not (C and C:IsValid()) then return false end
            if Srv.PICKUP_BASES[C:GetFName():ToString()] then return true end
            C = C:GetSuperStruct()
        end
        return false
    end, false) == true
end

-- Getragen/ausgeruestet: Owner gesetzt (OnPickupEquipped/EquipActorToSocket setzen die Figur, Fallenlassen und Spawn
-- setzen null) oder an einen Actor angehaengt. Persistente Actors (Waffen, Rucksaecke) werden beim Ausruesten
-- wiederverwendet (OnPickupEquipped @012f), nicht neu erzeugt. Nie im Hook.
function Srv.Held(Obj)
    return A.IsAlive(A.Safe(function() return Obj:GetOwner() end))
        or A.IsAlive(A.Safe(function() return Obj:GetAttachParentActor() end))
end

-- Kleinster Winkelabstand in Grad (-180..180 umlaufend)
function Srv.AngDiff(A1, B1)
    return math.abs(((tonumber(A1) or 0) - (tonumber(B1) or 0) + 180) % 360 - 180)
end

-- Closeout R2 (srv_drop_moved): Aufgehoben und neu abgelegt seit der letzten Aufraeum-Pruefung? Merkt Ort und Drehung
-- je Name in Srv.DropLoc (nur Zahlen). Bewegt > DIST uu oder gedreht > ANG Grad -> true. Der Abwurf eines ausgeruesteten
-- Actors (RequestDropAsPickup L_0508) setzt nur den Ort (GetDropLocation = Ort der Figur, oft fast derselbe Fleck); die
-- Drehung bleibt die vom Sockel (K2_DetachFromActor KeepRelative @05a2) und weicht darum auch am selben Fleck ab.
-- Falsch-Positive (Physik, angestossen) verlaengern nur die Liegezeit. Nie im Hook.
function Srv.DropMoved(Name, Obj)
    local T = A.Safe(function()
        local L, R = Obj:K2_GetActorLocation(), Obj:K2_GetActorRotation()
        local V = { X = tonumber(L.X), Y = tonumber(L.Y), Z = tonumber(L.Z),
                    Pi = tonumber(R.Pitch), Ya = tonumber(R.Yaw), Ro = tonumber(R.Roll) }
        if V.X and V.Y and V.Z and V.Pi and V.Ya and V.Ro then return V end
        return nil
    end)
    local P, D = Srv.DropLoc[Name], Srv.DROPMOVE
    Srv.DropLoc[Name] = T
    if not (T and P) then return false end
    return (T.X - P.X) ^ 2 + (T.Y - P.Y) ^ 2 + (T.Z - P.Z) ^ 2 > D.DIST * D.DIST
        or Srv.AngDiff(T.Pi, P.Pi) > D.ANG or Srv.AngDiff(T.Ya, P.Ya) > D.ANG or Srv.AngDiff(T.Ro, P.Ro) > D.ANG
end

-- Closeout R2 (srv_drop_heldscan): alle HELDSCAN s (Srv.Tick, nie im Hook) gemerkte fallengelassene Gegenstaende
-- pruefen: wieder getragen (Owner/Anhang) oder weg -> aus der Liste samt Alter und Ort (sonst behaelt ein zwischen zwei
-- Aufraeum-Pruefungen aufgehobener und neu abgelegter Actor sein altes Alter). Nur Pfad -> frisches Objekt.
function Srv.DropHeldScan()
    if next(Srv.Dropped) == nil or Srv.Flag("srv_drop_heldscan", true) ~= true then return end
    local Now = os.time()
    if Now < (Srv.HeldScanAt or 0) then return end
    Srv.HeldScanAt = Now + Srv.DROPMOVE.HELDSCAN
    for Name, Path in pairs(Srv.Dropped) do   -- Eintraege auf nil setzen waehrend pairs ist erlaubt
        local Obj = type(Path) == "string" and A.Safe(function() return StaticFindObject(Path) end) or nil
        if not A.IsAlive(Obj) or Srv.Held(Obj) then
            Srv.Dropped[Name], Srv.DeadSince[Name], Srv.DropLoc[Name] = nil, nil, nil
        end
    end
end

-- Closeout (srv_drophook_first, Fund 1): Spieler-Abwuerfe finden, ohne ActorRef zu lesen. Der Hook-Koerper merkt nur die
-- Zeit (Srv.DropEv); hier (Schnell-Loop/Srv.Tick, nie im Hook) alle Pickups durchsehen: nur frisch erzeugte
-- (GetGameTimeSinceCreation <= Zeit seit dem aeltesten Ereignis + Puffer), ohne Owner/Anhang und in 6 m um einen
-- Mitspieler zaehlen als fallengelassen. Welt-Beute ist aelter oder weit weg und bleibt draussen. Ausruestungs-Abwurf
-- (vorhandener Actor wird wiederverwendet, RequestDropAsPickup @06ca) wird nicht erfasst und bleibt liegen wie bisher.
-- Kosten: zwei FindAllOf je Ereignis-Schub, hoechstens 1 Suche je Sekunde (Ereignisse dazwischen warten gesammelt).
function Srv.DropScan(World)
    local Ev = Srv.DropEv
    if type(Ev) ~= "table" or #Ev == 0 then return end
    if Srv.Flag("srv_drophook_first", false) ~= true then Srv.DropEv = {} return end   -- Autofallback: aus
    local C, Now = Srv.DROPSCAN, os.time()
    if Now - (Srv.DropScanAt or 0) < 1 then return end
    Srv.DropScanAt, Srv.DropEv = Now, {}
    local Window = math.min(math.max(Now - (tonumber(Ev[1]) or Now), 0), C.MAXWIN) + C.PAD
    World = World or A.Safe(function() return A.CurrentWorld() end)
    if not A.IsAlive(World) then return end
    local Players = {}
    for _, G in ipairs(Guests(World)) do
        local L = A.IsAlive(G.Pawn) and A.Safe(function() return G.Pawn:K2_GetActorLocation() end) or nil
        if L then Players[#Players + 1] = L end
    end
    if #Players == 0 then return end
    local Found = 0
    for _, Class in ipairs(C.CLASSES) do
        for _, Obj in ipairs(FindAllOf(Class) or {}) do
            local Age = A.IsAlive(Obj) and tonumber(A.Safe(function() return Obj:GetGameTimeSinceCreation() end)) or nil
            local L = Age and Age <= Window and A.Safe(function() return Obj:K2_GetActorLocation() end) or nil
            local Near = false
            for _, P in ipairs(L and Players or {}) do
                if (L.X - P.X) ^ 2 + (L.Y - P.Y) ^ 2 + (L.Z - P.Z) ^ 2 < C.NEAR * C.NEAR then Near = true break end
            end
            if Near and Srv.IsPickup(Obj) and not Srv.Held(Obj) then
                local Name, Path = A.Safe(function() return Obj:GetFName():ToString() end), Srv.ObjPath(Obj)
                if Name and Path and Name:sub(1, 9) ~= "Default__" then   -- nie ein Klassen-Standardobjekt (ohne Welt: Alter 0)
                    if Srv.Dropped[Name] ~= Path then Found = Found + 1 end
                    Srv.Dropped[Name], Srv.DeadSince[Name], Srv.DropLoc[Name] = Path, nil, nil   -- frisch fallengelassen: Alter ab jetzt
                    Srv.DropRep[Path] = true
                end
            end
        end
    end
    if Found > 0 and not Srv.DropLogged then
        Srv.DropLogged = true
        Log("Fallengelassen: %d Gegenstand/Gegenstaende erkannt (frisch, bei einem Spieler; repliziert, verschwinden wie Leichen)", Found)
    end
end

-- Fallengelassene Actors replizieren (aus dem Schnell-Loop bzw. Srv.Tick, nie im Hook): Pfad -> frisches Objekt
function Srv.DropRepTick(World)
    local okScan, errScan = pcall(Srv.DropScan, World)
    if not okScan then Srv.Fail("srv_drophook_first", errScan) end
    if next(Srv.DropRep) == nil then return end
    local Pending = Srv.DropRep
    Srv.DropRep = {}
    for Path in pairs(Pending) do
        local Obj = A.Safe(function() return StaticFindObject(Path) end)
        if A.IsAlive(Obj) and Srv.IsPickup(Obj) then
            pcall(function()
                if not Obj.bReplicates then
                    Obj:SetReplicates(true)
                    Obj:SetReplicateMovement(true)
                end
            end)
            pcall(function() Obj:ForceNetUpdate() end)
        end
    end
end

-- Fallenlassen (Inventar -> Boden, auch "voll, fallen lassen"): Das Spiel erzeugt den Gegenstand beim Server in
-- BP_JigHelperComp:RequestDropAsPickup. Hier nur fuers Aufraeumen/Replizieren merken (Srv.DropScan).
-- Closeout (srv_drophook_first, Standard aus): RequestDropAsPickup ist eine BP-Funktion (Script-Hook, kein FUNC_Native,
-- Decode BP_JigHelperComp_C.kdis FLAGS 0x0cc20000). UE4SS 3.0.1 ruft bei BP-Funktionen nur EINEN Callback auf (den
-- ersten), nach dem BP-Rumpf -> der Koerper steht als erster Callback (und als zweiter, falls eine spaetere UE4SS-Version
-- beide ruft). Der Koerper liest KEINEN Parameter: ActorRef ist ein Ausgabe-Parameter, den der BP bei BP->BP-Aufrufen
-- (jedes Fallenlassen des Spiels: JigMP_OnRequestDropItem @0433) per LocalOutVariable in den Speicher des Aufrufers
-- schreibt; der Slot im Rahmen des Aufgerufenen bleibt uninitialisiert -> ActorRef:get() koennte Stapel-Muell lesen
-- (nativer Absturz, pcall hilft nicht) oder einen fremden Actor liefern. Darum nur Zeit merken (Tabelle) + Schnell-Loop-
-- Aufgabe; den Actor sucht Srv.DropScan. Idempotent (zweimal gerufen = zwei Ereignisse, eine Suche).
-- 0 = alter Weg (Koerper nur als Nach-Callback: laeuft nie, Fallengelassenes bleibt fuer immer liegen).
local function DropHook()
    if Srv.DropHooked then return end
    local Comp = FindFirstOf("BP_JigHelperComp_C")
    local Path = A.IsAlive(Comp) and Comp:GetClass():GetFullName():match("^%S+%s+(%S+)$")
    if not Path then return end
    Srv.DropHooked = true
    local function Body()
        local Ev = Srv.DropEv
        if type(Ev) ~= "table" then Ev = {} Srv.DropEv = Ev end
        if #Ev < Srv.DROPSCAN.EVENTS then Ev[#Ev + 1] = os.time() end
        pcall(A.Coop.AddFast, "srvdroprep", function(_, _, World) pcall(Srv.DropRepTick, World) return true end)
    end
    local First = Srv.Flag("srv_drophook_first", false) == true
    local ok, err
    if First then
        ok, err = pcall(RegisterHook, Path .. ":RequestDropAsPickup", Body, Body)
        if not ok then Srv.Fail("srv_drophook_first", err) end
    else
        ok, err = pcall(RegisterHook, Path .. ":RequestDropAsPickup", function() end, Body)
    end
    -- Fund 3: nutzbar nur, wenn der Koerper ueberhaupt laufen kann (alter Weg: Nach-Callback laeuft bei BP-Funktionen nie).
    -- Nur noch Status; der Spiel-Weg in DropForPlayer haengt an srv_gamedrop_out (Ausgabe-Tabelle), nicht am Hook.
    Srv.DropHookOk = ok and First
    Log("Fallenlassen-Hook %s (%s)", ok and "gesetzt" or ("fehlgeschlagen: " .. tostring(err)),
        First and "Koerper als erster Callback, nur Zeit merken" or "alter Weg: nur Nach-Callback")
end

-- Alle Objekte einer Art mit ihrem Alter (seit dem ersten Sehen als Leiche/Kiste; nach Neustart neu)
local function CleanupList(Kind)
    local List, Now = {}, os.time()
    for _, Obj in ipairs(Kind.Objects and Kind.Objects() or FindAllOf(Kind.Class) or {}) do
        if A.IsAlive(Obj) and A.Safe(function() return Kind.Ready(Obj) end, false) then
            local Name = Obj:GetFName():ToString()
            Srv.DeadSince[Name] = Srv.DeadSince[Name] or Now
            List[#List + 1] = { Obj = Obj, Name = Name, Age = Now - Srv.DeadSince[Name] }
        end
    end
    return List
end

local function CleanupTick(World)
    pcall(DropHook)
    if os.time() < Srv.CleanupAt then return end
    Srv.CleanupAt = os.time() + CLEANUP_CHECK
    local Players, Known = {}, {}
    for _, G in ipairs(Guests(World)) do
        if A.IsAlive(G.Pawn) then Players[#Players + 1] = G.Pawn:K2_GetActorLocation() end
    end
    for _, Kind in ipairs(CLEANUP) do
        local Minutes, List, Removed, Waiting = Srv.Cfg[Kind.Setting], CleanupList(Kind), 0, 0
        for _, E in ipairs(List) do
            Known[E.Name] = true
            if Minutes > 0 and E.Age >= Minutes * 60 then
                local L = A.Safe(function() return Kind.Where(E.Obj) end) or E.Obj:K2_GetActorLocation()
                local Near = false
                for _, P in ipairs(Players) do
                    if (L.X - P.X) ^ 2 + (L.Y - P.Y) ^ 2 + (L.Z - P.Z) ^ 2 < CLEANUP_NEAR * CLEANUP_NEAR then Near = true break end
                end
                if Near then
                    Waiting = Waiting + 1
                elseif pcall(function() E.Obj:K2_DestroyActor() end) then
                    Removed, Known[E.Name] = Removed + 1, nil
                end
            end
        end
        if Removed > 0 then
            Srv.Removed[Kind.What] = (Srv.Removed[Kind.What] or 0) + Removed
            Log("%d %s entfernt (aelter als %d min)%s, %d liegen noch", Removed, Kind.What, Minutes,
                Waiting > 0 and string.format(", %d warten (Spieler in der Naehe)", Waiting) or "", #List - Removed)
        end
    end
    for Name in pairs(Srv.DeadSince) do
        if not Known[Name] then Srv.DeadSince[Name] = nil end
    end
end

-- ---------------------------------------------------------------------------------------------------------
-- Admin: Spieler finden, kicken, bannen, teleportieren, Nachrichten, Wetter. In der Konsole (Pterodactyl) und
-- im Spiel. Admins = Mitspieler-IDs aus LASTSIGNAL_ADMINS (zufaellig je PC, stehen bei "players"); Steam-IDs
-- sind oeffentlich und werden ohne Steam-Anmeldung nicht geprueft, darum zaehlen sie nur fuer Bans.
-- Bans in bans.txt im Mod-Ordner: Zeilen "guest:<id>", "ip:<ip>", "steam:<id>", danach " # Name | Datum | Grund".
local BANS_FILE = "bans.txt"
local WEATHER_PATH = "/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets/"
local WEATHER = { clear = "Clear_Skies", cloudy = "Cloudy", partly = "Partly_Cloudy", overcast = "Overcast",
                  fog = "Foggy", rain = "Rain", lightrain = "Rain_Light", storm = "Rain_Thunderstorm", snow = "Snow",
                  lightsnow = "Snow_Light", blizzard = "Snow_Blizzard", dust = "Sand_Dust_Calm",
                  sandstorm = "Sand_Dust_Storm" }   -- UE 5.6: Preset Radiation gibt es nicht mehr
Srv.Bans, Srv.BanNotes, Srv.Kicking, Srv.Admins, Srv.AdminSent = {}, {}, {}, {}, {}
-- CORE-26: Steam-IDs aus LASTSIGNAL_ADMINS ("steam:<id>"), Admin-Anmeldung per "/admin <Passwort>" je Verbindung
Srv.AdminSteam, Srv.AdminAuth, Srv.AdminFail = {}, {}, {}

-- CORE-23: bans.txt atomar (Core.WriteAtomic) und mit .bak-Rueckfall lesen
local function LoadBans()
    Srv.Bans, Srv.BanNotes = {}, {}
    local Text = Srv.ReadText(A.ModDir .. BANS_FILE)
    if not Text then return end
    for Line in Text:gmatch("[^\r\n]+") do
        local Entry, Note = Line:match("^%s*(%a+:[^%s#]+)%s*#?%s*(.-)%s*$")
        if Entry then Srv.Bans[Entry:lower()], Srv.BanNotes[Entry:lower()] = true, Note end
    end
end

local function SaveBans()
    local Lines = {}
    for Entry in pairs(Srv.Bans) do Lines[#Lines + 1] = Entry .. " # " .. (Srv.BanNotes[Entry] or "") end
    table.sort(Lines)
    if not Srv.WriteText(A.ModDir .. BANS_FILE, table.concat(Lines, "\n") .. (#Lines > 0 and "\n" or "")) then
        Log("WARNUNG: %s nicht geschrieben", BANS_FILE)
    end
end

-- CORE-26: nur echte Adressen bannen (unlesbar = "?" oder "" haette jeden mit unlesbarer Adresse getroffen)
function Srv.ValidIp(Ip)
    if type(Ip) ~= "string" then return false end
    if Ip:match("^%d+%.%d+%.%d+%.%d+$") then return true end
    return Ip:find(":", 1, true) ~= nil and Ip:match("^[%x:%.]+$") ~= nil   -- IPv6
end

-- Alle Mitspieler mit Nummer, Name, IP, Mitspieler-ID, Steam-ID und Ping
local function PlayerList(World)
    local List = {}
    for N, G in ipairs(Guests(World)) do
        G.N, G.Key = N, G.PC:GetFullName()
        G.Name = A.Safe(function() return G.PS:GetPlayerName():ToString() end, "?")
        G.Ip = A.Safe(function() return G.PS.SavedNetworkAddress:ToString():match("^%[?([^%]]-)%]?:%d+$") or G.PS.SavedNetworkAddress:ToString() end, "?")
        G.GuestId = A.Coop.GuestIds[G.Key]
        G.Dup = A.Coop.GuestDup ~= nil and A.Coop.GuestDup[G.Key] ~= nil   -- Doppel-Login mit derselben Mitspieler-ID
        G.SteamId = A.Coop.SteamIds and A.Coop.SteamIds[G.Key]
        G.Ping = A.Safe(function() return math.floor(G.PS:GetPingInMilliseconds()) end, 0)
        List[#List + 1] = G
    end
    return List
end

-- Admin nur ueber die eigene Mitspieler-ID, nie die zweite Verbindung eines Doppel-Logins (kopierte ID-Datei).
-- CORE-26: stehen "steam:<id>" in LASTSIGNAL_ADMINS, muss auch die (vom Spiel gemeldete) Steam-ID passen.
function Srv.IsAdminId(G)
    if not (G ~= nil and G.GuestId ~= nil and not G.Dup and Srv.Admins[G.GuestId] == true) then return false end
    -- Modul-Aufrufer (ls_clan/ls_inv) geben nur ihren Verbindungs-Schluessel (Key = PC:GetFullName()) mit: Steam-ID
    -- dann ueber A.Coop.SteamIds[Key] (gleicher Schluessel wie PlayerList). Ohne Key/Steam-ID: nein (sicher zu)
    local Steam = G.SteamId or (G.Key ~= nil and A.Coop.SteamIds ~= nil and A.Coop.SteamIds[G.Key]) or nil
    if next(Srv.AdminSteam) ~= nil and not (Steam and Srv.AdminSteam[Steam]) then return false end
    return true
end

-- CORE-26: mit LASTSIGNAL_ADMIN_PASSWORD erst nach "/admin <Passwort>" in dieser Verbindung (sonst wie bisher)
function Srv.IsAdmin(G)
    if not Srv.IsAdminId(G) then return false end
    return not (Srv.Cfg and Srv.Cfg.AdminPassword) or (G.Key ~= nil and Srv.AdminAuth[G.Key] == true)
end

-- PLAYER-20: PlayerId der Verbindung (bleibt, anders als die Listennummer #N bei Beitritt/Abgang); nil ohne. Je
-- PlayerList-Eintrag hoechstens einmal gelesen.
function Srv.Pid(G)
    if G.Pid == nil then
        G.Pid = A.IsAlive(G.PS) and A.Safe(function() return G.PS:GetPlayerId() end) or false
    end
    return tonumber(G.Pid)
end

-- Spieler nach "#Nummer", "pid:<PlayerId>" (Admin-Panel, PLAYER-20), Mitspieler-ID, Steam-ID, IP oder (eindeutigem)
-- Namensteil
local function FindPlayer(World, Text)
    if not Text or Text == "" then return nil, "Spieler fehlt (#Nummer, pid:<PlayerId>, Name, ID oder IP)" end
    local List, Lower = PlayerList(World), Text:lower()
    local Pid = tonumber(Lower:match("^pid:(%d+)$"))
    if Pid then
        for _, G in ipairs(List) do if Srv.Pid(G) == Pid then return G end end
        return nil, "Spieler pid:" .. Pid .. " ist nicht (mehr) online"
    end
    local Number = tonumber(Text:match("^#(%d+)$"))
    for _, G in ipairs(List) do
        if (Number and G.N == Number) or (G.GuestId == Lower and not G.Dup) or G.SteamId == Text or G.Ip == Text then return G end
    end
    local Hit
    for _, G in ipairs(List) do
        if G.Name:lower():find(Lower, 1, true) then
            if Hit then return nil, "Name nicht eindeutig: " .. Text end
            Hit = G
        end
    end
    return Hit, Hit and nil or ("kein Spieler '" .. Text .. "'")
end

local function Notify(PC, Text)
    pcall(function() A.Coop.SendChunked(function(T) A.Coop.SendToClient(PC, T) end, "note", Text) end)
end

-- Gegenstand, den das Spiel beim Spieler nur lokal angelegt hat (main.lua Coop.Pending / inv_reconcile, z. B. leere
-- Flasche nach dem Trinken): hier wirklich anlegen, dann sein Inventar neu abgleichen. Der Spieler koennte damit (mit
-- veraenderter Mod) beliebiges anfordern: darum hoechstens 20 je Minute und 10 Stueck je Anfrage, jede Anfrage im Log.
-- Runde 3: kommt im Empfangs-Hook an -> dort nur pruefen und vormerken (keine UFunction im Hook), angelegt wird im
-- naechsten Durchlauf des Schnell-Loops (Srv.PendNow). Gemerkt wird nur der Controller-Name, kein Objekt.
Srv.PendWindow, Srv.PendQueue = {}, {}
-- Legacy-Weg: nur mit inv_reconcile (Standard aus) und ohne ls_inv v2b (dort entscheidet I.Decide mit Ledger).
-- Sonst koennte ein veraenderter Client hier beliebige Items (bis 200/min) anlegen lassen.
function Srv.PendingAdd(PC, Text)
    local InvMod = A.Coop.Modules and A.Coop.Modules.ls_inv
    if not (A.Settings and A.Settings.inv_reconcile)
        or (InvMod and InvMod.Active and A.Safe(function() return InvMod.Active() end, false)) then
        if os.time() - (Srv.PendDropLog or 0) >= 60 then   -- hoechstens 1 Logzeile je Minute (Flut)
            Srv.PendDropLog = os.time()
            Log("[Gegenstand] alte pend-Anfrage verworfen (Legacy-Weg aus): %s", type(Text) == "string" and Text:sub(1, 120) or "?")
        end
        return
    end
    if type(Text) ~= "string" or not Text:match("^(/Game/[%w_/%.%-]+)%s+(%d+)$") or #Srv.PendQueue >= 20 then return end
    Srv.PendQueue[#Srv.PendQueue + 1] = { Key = PC:GetFullName(), Text = Text }
    pcall(A.Coop.AddFast, "srvpend", function()
        local Queue = Srv.PendQueue
        Srv.PendQueue = {}
        for _, Job in ipairs(Queue) do
            local ok, err = pcall(Srv.PendNow, Job.Key, Job.Text)
            if not ok then Log("[Gegenstand] Anlegen fehlgeschlagen: %s", tostring(err)) end
        end
        return true
    end)
end

-- Volle Namen aller ItemGainedFromConsumption-Assets (hoechstens alle 60 s neu, nur aus dem Schnell-Loop)
function Srv.GainSet()
    local Now = os.time()
    if Srv.Gain and Now - (Srv.GainAt or 0) < 60 then return Srv.Gain end
    local Set = {}
    for _, DA in ipairs(A.Safe(function() return FindAllOf("JigsawItem_DataAsset_C") end) or {}) do
        local Gain = A.IsAlive(DA) and A.Safe(function() return DA.ItemGainedFromConsumption end)
        local Name = A.IsAlive(Gain) and A.Safe(function() return Gain:GetFullName() end)
        if Name then Set[Name] = true end
    end
    Srv.Gain, Srv.GainAt = Set, Now
    return Set
end

-- Key = Controller-Name aus dem Empfangs-Hook, der Spieler kommt frisch aus PlayerList
function Srv.PendNow(Key, Text)
    local Path, Count = Text:match("^(/Game/[%w_/%.%-]+)%s+(%d+)$")
    if not Path then return end
    local World = A.CurrentWorld()
    local Caller
    for _, G in ipairs(PlayerList(World)) do if G.Key == Key then Caller = G end end
    if not (Caller and A.IsAlive(Caller.Pawn)) then return end
    local PC = Caller.PC
    local W, Now = Srv.PendWindow[Caller.Key], os.time()
    if not W or Now - W.Since >= 60 then W = { Since = Now, N = 0 } Srv.PendWindow[Caller.Key] = W end
    W.N = W.N + 1
    if W.N > 20 then
        if W.N == 21 then Log("[Gegenstand] %s: zu viele Anfragen, ignoriert", Caller.Name) end
        return
    end
    local Asset = A.Safe(function() return StaticFindObject(Path) end)
    if not A.IsAlive(Asset) then
        -- CORE-14 (untrusted_paths, E24): Pfad vom Gast -> LoadAsset nur fuer sichere Pfade (nie Karten/Level)
        if Srv.Flag("untrusted_paths", true) and not Srv.SafePath(Path) then
            Log("[Gegenstand] %s: unsicherer Pfad verworfen (%s)", Caller.Name, Path:sub(1, 120))
            return
        end
        Asset = A.Safe(function() return LoadAsset(Path) end)
    end
    if not (A.IsAlive(Asset) and Srv.IsItemAsset(Asset)) then
        Log("[Gegenstand] %s: unbekannt %s", Caller.Name, Path)
        return
    end
    -- Nur, was beim Verbrauch entsteht (ItemGainedFromConsumption: leere Flasche, Dose ...), wie main.lua IR.GainSet
    local AName = A.Safe(function() return Asset:GetFullName() end)
    if not (AName and Srv.GainSet()[AName]) then
        Log("[Gegenstand] %s: pend ohne Freigabe verworfen (%s)", Caller.Name, Path)
        return
    end
    Count = math.min(math.max(tonumber(Count) or 1, 1), 10)
    local Jig = Caller.Pawn.BP_JigMultiplayer
    if not A.IsAlive(Jig) then Log("[Gegenstand] %s: kein Inventar", Caller.Name) return end
    Jig:AddNewItemSomewhere(Asset, Count, nil, 0, true, FName("None"), {}, {}, {}, {})   -- UE 5.6: 6. Parameter SpecificContainer
    -- Kein invsync mehr: der Neuabgleich baute beim Host alle Ausruestungs-Actors neu (Waffe unsichtbar, Rucksack/GPS
    -- weg). Das Item liegt jetzt beim Host im Inventar; beim Mitspieler zeigt es der inkrementelle Weg (Runde 4, inv_v2).
    Log("[Gegenstand] %s: %dx %s", Caller.Name, Count, Path:match("([^%.]+)$") or Path)
end

-- Gegenstaende vor die Fuesse legen (Cheat "give" des Admins; consume_fix: leere Flasche nach dem Trinken). Kein
-- Inventar-Neuabgleich (invsync baute alles neu auf: Cheat-Items blinkten, das GPS ging verloren).
-- Ablage 1 m vor der Figur auf Fusshoehe (+20 cm), je Stapel etwas seitlich versetzt (5 nebeneinander, dann eine Reihe
-- weiter). Stapel bis MaxStack (nicht stapelbar: einzeln), hoechstens DROP.MAX Actors. Erst wie beim Fallenlassen ueber
-- das Spiel (BP_JigHelperComp:RequestDropAsPickup, den Actor liefert ActorRef in der Ausgabe-Tabelle; Daten-Asset und
-- Menge setzt der Mod danach selbst), sonst selbst spawnen (PickupClass des Daten-Assets, Menge per SetCount). Danach
-- fuer alle sichtbar wie Coop.Loot (repliziert) und gleich verschickt.
-- Laeuft nie im Empfangs-Hook (RequestDropAsPickup ist selbst gehookt: Hook im Hook), nur aus Srv.DropTick.
-- QUEUED: Rueckgabe von AdminInGame, wenn das Ergebnis spaeter Srv.DropTick meldet
Srv.DROP = { MAX = 20, AHEAD = 100, STEP = 30, ROW = 5, LIFT = 20, CONSUME_PER_MIN = 10, QUEUE_MAX = 50,
             ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD" }
Srv.DropQueue, Srv.ConsumeWindow, Srv.QUEUED = {}, {}, {}

-- Daten-Asset eines Gegenstands? (Klassen-Kette bis JigsawItem_DataAsset)
function Srv.IsItemAsset(Asset)
    local C = A.Safe(function() return Asset:GetClass() end)
    while C and A.Safe(function() return C:IsValid() end, false) do
        if C:GetFName():ToString():find("JigsawItem_DataAsset", 1, true) then return true end
        C = A.Safe(function() return C:GetSuperStruct() end)
    end
    return false
end

-- Daten-Asset nach Pfad (nil, wenn unbekannt oder kein Gegenstand)
function Srv.ItemAsset(Path)
    local Asset = StaticFindObject(Path)
    if not A.IsAlive(Asset) then Asset = A.Safe(function() return LoadAsset(Path) end) end
    return A.IsAlive(Asset) and Srv.IsItemAsset(Asset) and Asset or nil
end

-- Spiel-Weg: wie Fallenlassen (Aufruf aus Lua = ProcessEvent). Closeout (srv_gamedrop_out): den Actor liefert der
-- Ausgabe-Parameter ActorRef in einer Ausgabe-Tabelle (UE4SS schreibt Ausgabe-Parameter in uebergebene Tabellen zurueck,
-- wie AddNewItemSomewhere in Srv.AddDrop), nicht mehr der Hook (DropCatch blieb hier immer leer -> Modus 2 spawnte doppelt).
-- Rueckgabe: ok (Aufruf ohne Fehler), Known (ActorRef kam zurueck: bekannt, ob ein Actor entstand), Obj (lebender Actor
-- oder nil). Bei einem Fehler kein zweiter Aufruf mit nil (der lieferte nie eine Rueckmeldung): Aufrufer nehmen Modus 0.
-- Closeout R3: RequestDropAsPickup nimmt ItemID nur fuer die PickupClass (BeginDeferredActorSpawnFromClass @039c, dann
-- gleich FinishSpawningActor @04c8) und setzt weder Daten-Asset noch Menge; das Spiel macht das erst danach im Aufrufer
-- (HandleServerDropRequest @064b/@067e SetPickupContainerData). Ohne das behielte der Pickup die Klassen-Standardmenge
-- (GetCount = ItemDataAsset->Count) -> hier wie Srv.SpawnPickup setzen, aber nur auf einem echten Pickup (ActorRef kann
-- auch ein vorhandener ausgeruesteter Actor sein, RequestDropAsPickup @0508-06ca).
function Srv.GameDrop(Helper, Asset, N)
    local D, Out = Srv.DROP, {}
    local ok, err = pcall(function() Helper:RequestDropAsPickup({ [D.ITEM_ID] = Asset, [D.COUNT] = N }, FName("None"), Out) end)
    if not ok then
        Srv.Fail("srv_gamedrop_out", err)
        return false, false, nil
    end
    local Known = next(Out) ~= nil
    local V = Known and Srv.OutValue(Out, "ActorRef") or nil
    local Obj = A.IsAlive(V) and V or nil
    if Obj and Srv.IsPickup(Obj) then
        if not Srv.ApplyPickupData(Obj, Asset, N) then
            Log("Vor die Fuesse: Spiel-Pickup ohne BP_JigPickupComponent, Menge nicht gesetzt")
        end
    end
    return true, Known, Obj
end

-- Daten-Asset und Menge am Pickup setzen (RequestDropAsPickup setzt keins von beiden, das Spiel macht es erst danach per
-- SetPickupContainerData). false = keine lebende BP_JigPickupComponent
function Srv.ApplyPickupData(Obj, Asset, N)
    local Comp = A.Safe(function() return Obj.BP_JigPickupComponent end)
    if not A.IsAlive(Comp) then return false end
    pcall(function() Comp.ItemDataAsset = Asset end)
    pcall(function() Comp:SetCount(N) end)
    return true
end

-- Ersatzweg: Pickup-Actor des Gegenstands selbst spawnen, Daten-Asset und Menge setzen
function Srv.SpawnPickup(Asset, N, At, Yaw)
    local Class = A.Safe(function() return Asset.PickupClass end)
    if not A.IsAlive(Class) then return nil end
    local Obj = A.Safe(function() return A.CurrentWorld():SpawnActor(Class, At, { Pitch = 0, Yaw = Yaw, Roll = 0 }) end)
    if not A.IsAlive(Obj) then return nil end
    Srv.ApplyPickupData(Obj, Asset, N)
    return Obj
end

-- Runde 3: Ablage-Modus (Platzhalter beim Aufheben gespawnter Gegenstaende): Coop.DropMode (Testbefehl dropmode),
-- sonst coop.txt drop_mode. 0 = selbst spawnen (bisher), 1 = adddrop, 2 = game.
function Srv.DropMode()
    local M = tonumber(A.Coop.DropMode or A.Settings.drop_mode) or 0
    return (M == 1 or M == 2) and M or 0
end

function Srv.AssetName(Asset) return A.Safe(function() return Asset:GetFName():ToString() end, "?") end

-- UE4SS-Ausgabe-Parameter: je Parameter eine Tabelle, danach steht der Wert unter dem Parameternamen darin (wie
-- IsGPSEquipped? -> Out["GPS?"]). Fehlt der Name, den einzigen Eintrag nehmen.
function Srv.OutValue(T, Name)
    if T[Name] ~= nil then return T[Name] end
    for _, V in pairs(T) do return V end
    return nil
end

-- FGuid aus einem Ausgabe-Parameter: unter dem Namen (Struktur oder Tabelle) oder direkt als Felder A-D in der Tabelle
-- (wie GetUniqueID -> Uid.A). nil = nicht lesbar oder leer (0-0-0-0). Rueckgabe als neue Tabelle { A, B, C, D }.
function Srv.OutGuid(T, Name)
    local function Read(S)
        local ok, Guid = pcall(function() return { A = S.A, B = S.B, C = S.C, D = S.D } end)
        if ok and type(Guid.A) == "number" and type(Guid.D) == "number"
            and (Guid.A ~= 0 or Guid.B ~= 0 or Guid.C ~= 0 or Guid.D ~= 0) then return Guid end
        return nil
    end
    local V = T[Name]
    if V == nil then for _, X in pairs(T) do V = X break end end
    return (V ~= nil and type(V) ~= "number" and type(V) ~= "boolean" and Read(V)) or Read(T)
end

function Srv.GuidText(Guid)
    local function H(V) return string.format("%08X", math.floor(tonumber(V) or 0) & 0xFFFFFFFF) end
    return H(Guid.A) .. "-" .. H(Guid.B) .. "-" .. H(Guid.C) .. "-" .. H(Guid.D)
end

function Srv.Keys(T)
    local K = {}
    for Key in pairs(T) do K[#K + 1] = tostring(Key) end
    return #K > 0 and table.concat(K, ",") or "-"
end

-- drop_mode 1: als echter Gegenstand des Spielers (UID, Werte wie im Spiel) ins Inventar (AddNewItemSomewhere), dann
-- ueber den Weg des Spiels fallen lassen (HandleServerDropRequest, wie die Anfrage beim Fallenlassen). Closeout: kein
-- Actor mehr aus dem Hook (DropCatch entfernt, Hook liest keine Parameter); das Spiel legt ihn selbst bei der Figur ab,
-- Srv.DropScan erfasst ihn (srv_drophook_first). Rueckgabe { Ok = Gegenstand angekommen (Boden oder Inventar),
-- Obj = immer nil, Text = fuers Log }
function Srv.AddDrop(G, Asset, N)
    local Inv = G.Pawn.BP_JigMultiplayer
    if not A.IsAlive(Inv) then return { Ok = false, Text = "kein Inventar" } end
    local AddedT, DroppedT, UidT, ToT = {}, {}, {}, {}
    -- UE 5.6 (BP_JigComponent_C, 10 Parameter): nach DropIfFailedToAdd? neu SpecificContainer (Name, 'None' = irgendwo)
    local okAdd, errAdd = pcall(function() Inv:AddNewItemSomewhere(Asset, N, nil, 0, true, FName("None"), AddedT, DroppedT, UidT, ToT) end)
    local Added, Dropped = Srv.OutValue(AddedT, "Added"), Srv.OutValue(DroppedT, "Dropped?")
    local Uid = okAdd and Srv.OutGuid(UidT, "ItemUID") or nil
    local R = { Ok = false }
    if not okAdd then
        R.Text = "AddNewItemSomewhere Fehler " .. tostring(errAdd)
    elseif Dropped == true then
        R.Ok, R.Text = true, "Inventar voll: vom Spiel selbst fallen gelassen"
    elseif Added ~= true then
        R.Text = "nicht hinzugefuegt (Added=" .. tostring(Added) .. ", Felder " .. Srv.Keys(AddedT) .. ")"
    elseif not Uid then
        R.Ok, R.Text = true, "im Inventar, aber keine ItemUID lesbar (Felder " .. Srv.Keys(UidT) .. ") - bleibt im Inventar"
    else
        local okDrop, errDrop = pcall(function() Inv:HandleServerDropRequest(Uid, N, Inv) end)
        R.Ok = true
        R.Text = string.format("ItemUID %s, HandleServerDropRequest %s", Srv.GuidText(Uid),
            okDrop and "ok" or ("Fehler " .. tostring(errDrop) .. " - bleibt im Inventar"))
    end
    R.Obj = nil
    R.Text = R.Text .. ", Actor legt das Spiel ab"
    return R
end

-- G = Spieler aus PlayerList (mit Figur). Gibt die abgelegte Menge und die Zahl der Stapel zurueck.
function Srv.DropForPlayer(G, Asset, Count)
    local D, Pawn = Srv.DROP, G.Pawn
    local Per = 1
    if A.Safe(function() return Asset["CanStack?"] == true end, false) then
        Per = math.max(math.floor(tonumber(A.Safe(function() return Asset.MaxStack end)) or 1), 1)
    end
    local Stacks = math.min(math.ceil(Count / Per), D.MAX)
    local Loc = Pawn:K2_GetActorLocation()
    local Yaw = A.Safe(function() return Pawn:K2_GetActorRotation().Yaw end, 0)
    local Half = tonumber(A.Safe(function()
        local Cap = Pawn.CapsuleComponent
        return A.IsAlive(Cap) and Cap:GetScaledCapsuleHalfHeight() or nil
    end)) or 90
    local Fx, Fy = math.cos(math.rad(Yaw)), math.sin(math.rad(Yaw))
    pcall(DropHook)
    local Helper = A.Safe(function() return Pawn.BP_JigHelperComp end)
    -- Spiel-Weg nur, wenn wir erfahren, ob ein Actor entstand (Ausgabe-Tabelle, srv_gamedrop_out; sonst doppelt mit dem
    -- Ersatzweg). Closeout: nicht mehr am Fallenlassen-Hook (dessen Koerper liefert keinen Actor mehr).
    local Game = A.IsAlive(Helper) and Srv.Flag("srv_gamedrop_out", true) == true
    local Mode = Srv.DropMode()   -- drop_mode / Testbefehl dropmode (main.lua Coop.DropMode)
    local Given, Placed, Ways, Left = 0, 0, {}, Count
    for I = 0, Stacks - 1 do
        local N = math.min(Per, Left)
        Left = Left - N
        local Side, Ahead = (I % D.ROW - math.floor(D.ROW / 2)) * D.STEP, D.AHEAD + math.floor(I / D.ROW) * D.STEP
        local At = { X = Loc.X + Fx * Ahead - Fy * Side, Y = Loc.Y + Fy * Ahead + Fx * Side, Z = Loc.Z - Half + D.LIFT }
        local Obj, Way, Done = nil, nil, false
        -- drop_mode 1 (adddrop): ins Inventar, dann Fallenlassen des Spiels; die Lage macht das Spiel (nur loggen).
        -- Klappt das Hinzufuegen nicht, weiter wie Modus 0. Liegt er danach im Inventar, nicht noch einmal ablegen.
        if Mode == 1 then
            local okAD, R = pcall(Srv.AddDrop, G, Asset, N)
            if not okAD then R = { Ok = false, Text = "Fehler " .. tostring(R) } end
            Log("Vor die Fuesse [Modus 1 adddrop] %s x%d: %s", Srv.AssetName(Asset), N, R.Text)
            if R.Ok then Obj, Done, Way = R.Obj, true, R.Obj and "adddrop" or "adddrop ohne Actor" end
        -- drop_mode 2 (game): RequestDropAsPickup (ItemID waehlt nur die PickupClass; Daten-Asset und Menge setzt Srv.GameDrop
        -- danach selbst), Actor vor den Spieler setzen
        elseif Mode == 2 and Game then
            local ok, Known
            ok, Known, Obj = Srv.GameDrop(Helper, Asset, N)
            if Obj then
                Way, Done = "Spiel (Modus 2)", true
                pcall(function() Obj:K2_SetActorLocation(At, false, {}, true) end)
            elseif ok and not Known then
                -- ohne Rueckmeldung: das Spiel hat ihn wohl bei der Figur abgelegt -> kein Ersatz-Spawn (sonst doppelt)
                Way, Done = "Spiel ohne Rueckmeldung", true
            else
                Game = false   -- nichts erzeugt (ActorRef leer) oder Fehler: weiter wie Modus 0, Spiel-Weg nicht mehr versuchen
            end
            Log("Vor die Fuesse [Modus 2 game] %s x%d: RequestDropAsPickup %s, %s", Srv.AssetName(Asset), N,
                ok and "ok" or "fehlgeschlagen", Obj and ("Actor " .. Obj:GetFName():ToString())
                or (Done and "ohne Rueckmeldung -> kein Ersatz, als abgelegt gezaehlt (Menge unbekannt: Standardmenge des Spiels)"
                or "kein Actor -> Modus 0"))
        elseif Mode == 2 then
            Log("Vor die Fuesse [Modus 2 game]: kein Helper oder srv_gamedrop_out=0 -> Modus 0")
        end
        -- Modus 0: zuerst selbst spawnen (Pickup-Klasse des Gegenstands, Werte wie Welt-Beute): RequestDropAsPickup nimmt
        -- ItemID nur fuer die PickupClass und setzt weder Daten-Asset noch Menge (setzt Srv.GameDrop nach, nur mit ActorRef).
        -- Der Spiel-Weg nur, wenn das Asset keine Pickup-Klasse hat.
        if not Done then
            Obj = Srv.SpawnPickup(Asset, N, At, Yaw)
            Way = Obj and "gespawnt" or nil
        end
        if not Done and not Obj and Game then
            local ok, Known
            ok, Known, Obj = Srv.GameDrop(Helper, Asset, N)
            if Obj then
                Way = "Spiel"
                pcall(function() Obj:K2_SetActorLocation(At, false, {}, true) end)
            elseif ok and not Known then
                -- ohne Rueckmeldung: kein Ersatz (SpawnPickup hatte schon keine Pickup-Klasse), als abgelegt zaehlen
                Way, Done = "Spiel ohne Rueckmeldung", true
                if not Srv.GameDropLogged then
                    Srv.GameDropLogged = true
                    Log("Vor die Fuesse: Spiel-Ablage ohne Rueckmeldung (ActorRef nicht zurueckgeschrieben), kein Ersatz; Menge unbekannt (Standardmenge des Spiels)")
                end
            else
                Game = false   -- kein Actor: fuer die restlichen Stapel auch nicht mehr versuchen
                if not Srv.GameDropLogged then
                    Srv.GameDropLogged = true
                    Log("Vor die Fuesse: weder Pickup-Klasse noch RequestDropAsPickup lieferten einen Gegenstand (Aufruf %s)", ok and "ok" or "fehlgeschlagen")
                end
            end
        end
        if Obj then
            -- Closeout: nur Pickups replizieren/merken (nie einen fremden Actor aufraeumen)
            if Srv.IsPickup(Obj) then
                -- wie Coop.Loot (main.lua L.HostTick), aber sofort: repliziert, Bewegung mit, gleich verschicken
                pcall(function()
                    if not Obj.bReplicates then
                        Obj:SetReplicates(true)
                        Obj:SetReplicateMovement(true)
                    end
                end)
                pcall(function() Obj:ForceNetUpdate() end)
                pcall(function()   -- verschwindet wie Fallengelassenes (nur der Pfad, kein UObject ueber Ticks)
                    local ObjPath = Srv.ObjPath(Obj)
                    if ObjPath then
                        local Name = Obj:GetFName():ToString()
                        Srv.Dropped[Name], Srv.DeadSince[Name], Srv.DropLoc[Name] = ObjPath, nil, nil   -- neu abgelegt: Alter ab jetzt
                    end
                end)
            end
            Given, Placed = Given + N, Placed + 1
            Ways[Way] = (Ways[Way] or 0) + 1
        elseif Done then
            -- Modus 1 bzw. Spiel-Weg ohne Actor: das Spiel hat ihn abgelegt (oder er liegt im Inventar), siehe Log oben
            Given = Given + N
            Ways[Way] = (Ways[Way] or 0) + 1
        end
    end
    local Parts = {}
    for Way, N in pairs(Ways) do Parts[#Parts + 1] = Way .. " " .. N end
    Log("Vor die Fuesse von %s (Modus %d): %d von %d %s in %d Stapel (%s)", G.Name or "?", Mode, Given, Count,
        A.Safe(function() return Asset:GetFName():ToString() end, "?"), Placed,
        #Parts > 0 and table.concat(Parts, ", ") or "kein Weg klappte")
    return Given, Placed
end

-- Vormerken (auch aus dem Empfangs-Hook: nur Tabellen). Abgearbeitet im naechsten Durchlauf des Schnell-Loops von
-- main.lua, spaetestens in Srv.Tick (1x/s). Job = { What = "give"|"consumed", Key, PC, Asset oder Path, Count, Name }
function Srv.QueueDrop(Job)
    if #Srv.DropQueue >= Srv.DROP.QUEUE_MAX then return false end
    Srv.DropQueue[#Srv.DropQueue + 1] = Job
    pcall(A.Coop.AddFast, "srvdrop", function() pcall(Srv.DropTick) return true end)
    return true
end

function Srv.DropTick()
    if #Srv.DropQueue == 0 then return end
    local Queue, ByKey = Srv.DropQueue, {}
    Srv.DropQueue = {}
    for _, G in ipairs(PlayerList(A.CurrentWorld())) do ByKey[G.Key] = G end
    for _, Job in ipairs(Queue) do
        local G = ByKey[Job.Key]
        local Asset = Job.Asset or (Job.Path and Srv.ItemAsset(Job.Path))
        local Name = Job.Name or (Job.Path and Job.Path:match("([^%.]+)$")) or "?"
        local ok, Given = false, "keine Figur oder unbekannter Gegenstand"
        if G and A.IsAlive(G.Pawn) and A.IsAlive(Asset) then ok, Given = pcall(Srv.DropForPlayer, G, Asset, Job.Count) end
        if not ok then Log("Vor die Fuesse (%s %s) fehlgeschlagen: %s", Job.What, Name, tostring(Given)) end
        Given = ok and tonumber(Given) or 0
        if Job.What == "give" then
            local Text = Given > 0 and string.format("Given %dx %s (vor dir abgelegt)", Given, Name) or ("give: drop failed " .. Name)
            Log("[Admin %s] give %s -> %s", G and G.Name or "?", Name, Text)
            Notify(G and G.PC or Job.PC, Text)
        else
            Log("[Verbrauch] %s: %dx %s vor die Fuesse", G and G.Name or "?", Given, Name)
        end
    end
end

-- consume_fix (main.lua Coop.Consume beim Mitspieler): "<Pfad>|<n>" nach dem Verbrauch. Laeuft im Empfangs-Hook: nur
-- pruefen und vormerken. Hoechstens CONSUME_PER_MIN Stueck je Minute und Spieler (mit veraenderter Mod liesse sich sonst
-- beliebiges anfordern), je Meldung hoechstens 5.
function Srv.OnConsumed(PC, Text)
    if not A.Settings.consume_fix then return end
    -- ls_inv v2b aktiv: Ledger schreibt das Rest-Item gut und uebernimmt den Platzhalter des Gasts (I.Decide) ->
    -- zusaetzliche Ablage vor die Fuesse waere ein Duplikat (wie Srv.PendingAdd)
    local InvMod = A.Coop.Modules and A.Coop.Modules.ls_inv
    if InvMod and InvMod.Active and A.Safe(function() return InvMod.Active() end, false) then return end
    if type(Text) ~= "string" then return end
    local Path, Count = Text:match("^(/Game/[%w_/%.%-]+)|(%d+)$")
    if not Path then return end
    Count = math.min(math.max(tonumber(Count) or 1, 1), 5)
    local Key, Now = PC:GetFullName(), os.time()
    local W = Srv.ConsumeWindow[Key]
    if not W or Now - W.Since >= 60 then W = { Since = Now, N = 0 } Srv.ConsumeWindow[Key] = W end
    if W.N + Count > Srv.DROP.CONSUME_PER_MIN then
        if not W.Logged then W.Logged = true Log("[Verbrauch] zu viele Meldungen von %s, ignoriert", Key:match("([^%.]+)$") or Key) end
        return
    end
    W.N = W.N + Count
    Srv.QueueDrop({ What = "consumed", Key = Key, PC = PC, Path = Path, Count = Count })
end

-- Chat an alle ("1|Name|Text", 1 = Admin/Server: beim Spieler hervorgehoben)
local CHAT_MAX = 150
Srv.ChatAt = {}
local function ChatAll(World, IsAdmin, Name, Text)
    local Line = (IsAdmin and "1" or "0") .. "|" .. Name:gsub("[|%c]", " ") .. "|" .. Text
    for _, G in ipairs(PlayerList(World)) do
        pcall(function() A.Coop.SendChunked(function(T) A.Coop.SendToClient(G.PC, T) end, "chat", Line) end)
    end
end

-- Chat-Befehl eines Spielers: erst ls_clan (Coop.Clan.Chat), dann ls_build (Coop.Build.Chat); sonst kurze Hilfe nur an
-- ihn. Ins Log nur der Befehlsname (Codes von /lock /code bleiben draussen).
Srv.CHAT_CMDS = { clan = "Clan", c = "Clan", lock = "Build", unlock = "Build", code = "Build", claim = "Build",
    unclaim = "Build", owner = "Build" }
Srv.CHAT_HELP = "Befehle: /clan ... (Clan), /c <Text> (Clan-Chat), /claim, /unclaim, /lock <Code>, /unlock, "
    .. "/code <Code>, /owner, /carlock"
-- PLAYER-15 (srv_joinmsg): /players (/online) und /help; in der Hilfe auch die Befehle, die der Mod beim Spieler selbst
-- behandelt (ls_player /suicide /unstuck /carlock, main.lua /pw)
Srv.CHAT_HELP2 = "Befehle: /players, /help, /clan ... (Clan), /c <Text> (Clan-Chat), /claim, /unclaim, /lock <Code>, "
    .. "/unlock, /code <Code>, /owner, /suicide, /unstuck, /carlock, /pw <Passwort>"
function Srv.ChatHelp() return Srv.Flag("srv_joinmsg", true) and Srv.CHAT_HELP2 or Srv.CHAT_HELP end

-- PLAYER-15: Notiz an den Spieler mit allen Namen (nur Anzeige)
function Srv.ChatPlayers(G)
    local Names = {}
    for _, P in ipairs(PlayerList(A.CurrentWorld())) do Names[#Names + 1] = (P.Name:gsub("[|%c]", " ")) end
    table.sort(Names, function(X, Y) return X:lower() < Y:lower() end)
    local Text = string.format("Online (%d/%d): %s", #Names, Srv.Cfg.MaxPlayers, table.concat(Names, ", "))
    Notify(G.PC, #Text > 400 and (Text:sub(1, 397) .. "...") or Text)
end
Srv.CHAT_LOCAL = { players = Srv.ChatPlayers, online = Srv.ChatPlayers,
                   help = function(G) Notify(G.PC, Srv.ChatHelp()) end }

function Srv.ChatCommand(G, Text)
    local Cmd = (Text:match("^/(%S*)") or ""):lower():sub(1, 20)
    Log("[Chat] %s: Befehl /%s", G.Name, Cmd)
    local Local = Srv.CHAT_LOCAL[Cmd]
    if Local and Srv.Flag("srv_joinmsg", true) then
        local ok, err = pcall(Local, G)
        if not ok then
            Log("[Chat] Befehl /%s fehlgeschlagen: %s", Cmd, tostring(err):sub(1, 200))
            Srv.Fail("srv_joinmsg", err)
        end
        return
    end
    for _, Name in ipairs({ "Clan", "Build" }) do
        local M = A.Coop[Name]
        if type(M) == "table" and type(M.Chat) == "function" then
            local ok, Done = pcall(M.Chat, G, Text)
            if not ok then
                Log("[Chat] Befehl /%s (%s) fehlgeschlagen: %s", Cmd, Name, tostring(Done):sub(1, 200))
                Notify(G.PC, "Befehl /" .. Cmd .. " fehlgeschlagen")
                return
            end
            if Done then return end
        end
    end
    if Srv.CHAT_CMDS[Cmd] then
        Notify(G.PC, "/" .. Cmd .. " ist auf diesem Server aus")
    else
        Notify(G.PC, "Unbekannter Befehl /" .. Cmd .. ". " .. Srv.ChatHelp())
    end
end

-- CORE-26: "/admin <Passwort>" (LASTSIGNAL_ADMIN_PASSWORD): Admin-Rechte fuer diese Verbindung, nur fuer Admin-IDs.
-- Nie verteilen oder loggen; hoechstens 5 Versuche je Verbindung (Raten).
Srv.ADMIN_TRIES = 5
function Srv.OnAdminAuth(PC, Pw)
    local Key, Caller = PC:GetFullName(), nil
    for _, G in ipairs(PlayerList(A.CurrentWorld())) do if G.Key == Key then Caller = G end end
    if not Caller then return end
    if not Srv.Cfg.AdminPassword then Notify(Caller.PC, "Kein Admin-Passwort auf diesem Server") return end
    if Srv.AdminAuth[Key] then Notify(Caller.PC, "Admin-Rechte sind schon aktiv") return end
    if not Pw or Pw == "" then Notify(Caller.PC, "/admin <Passwort>") return end
    -- Wie der Gast-Chat (main.lua: "|"/Steuerzeichen -> Leerzeichen, Raender weg) bereinigen; verglichen wird mit der
    -- ebenso bereinigten Einstellung (Srv.Init: AdminPasswordCmp). Auch ein roh ankommendes "|" passt so.
    Pw = tostring(Pw):gsub("[%c|]", " "):match("^%s*(.-)%s*$")
    if Pw == "" then Notify(Caller.PC, "/admin <Passwort>") return end
    local Tries = Srv.AdminFail[Key] or 0
    if Tries >= Srv.ADMIN_TRIES then return end
    if not (Srv.IsAdminId(Caller) and Srv.Cfg.AdminPasswordCmp ~= nil and Srv.Cfg.AdminPasswordCmp ~= ""
        and Pw == Srv.Cfg.AdminPasswordCmp) then
        Srv.AdminFail[Key] = Tries + 1
        Log("Admin-Anmeldung abgelehnt: %s (%s, Versuch %d)", Caller.Name,
            Srv.IsAdminId(Caller) and "falsches Passwort" or "keine Admin-ID", Tries + 1)
        Srv.AdminLog(Srv.Who(Caller), "/admin", string.format("abgelehnt (Versuch %d)", Tries + 1))   -- X-CORE3, nie das Passwort
        Notify(Caller.PC, "Admin-Anmeldung fehlgeschlagen")
        return
    end
    Srv.AdminAuth[Key] = true
    Log("Admin-Anmeldung: %s", Caller.Name)
    Srv.AdminLog(Srv.Who(Caller), "/admin", "ok")
    Notify(Caller.PC, "Admin-Rechte aktiv")
end

-- Chat-Nachricht eines Spielers (main.lua: Kind "chat"): hoechstens eine je Sekunde, auf CHAT_MAX Zeichen gekuerzt
function Srv.Chat(PC, Text)
    -- "/pw <Passwort>" (aelterer Mod-Stand schickt es als Chat): als Passwort werten, nie verteilen oder loggen
    local Pw = Text:match("^%s*/[pP][wW]%s+(.-)%s*$")
    if Pw or Text:match("^%s*/[pP][wW]%s*$") then
        if Pw and Pw ~= "" then pcall(Srv.OnAuth, PC, Pw) end
        return
    end
    -- CORE-26: "/admin <Passwort>" nie als Chat oder Befehl weiterreichen (auch nicht an ls_clan/ls_build)
    local APw = Text:match("^%s*/[aA][dD][mM][iI][nN]%s+(.-)%s*$")
    if APw or Text:match("^%s*/[aA][dD][mM][iI][nN]%s*$") then
        local ok, err = pcall(Srv.OnAdminAuth, PC, APw)
        if not ok then Log("Admin-Anmeldung: Fehler %s", tostring(err)) end
        return
    end
    local World = A.CurrentWorld()
    local Caller
    for _, G in ipairs(PlayerList(World)) do if G.PC == PC or G.Key == PC:GetFullName() then Caller = G end end
    if not Caller then return end
    Text = Text:gsub("[|%c]", " "):match("^%s*(.-)%s*$")
    local Cut = utf8.len(Text) and utf8.offset(Text, CHAT_MAX + 1)
    Text = Cut and Text:sub(1, Cut - 1) or (utf8.len(Text) and Text or Text:gsub("[\128-\255]", "?"):sub(1, CHAT_MAX))
    if Text == "" then return end
    local IsCmd = Text:sub(1, 1) == "/"
    if os.time() < (Srv.ChatAt[Caller.Key] or 0) then
        if IsCmd then Notify(Caller.PC, "Zu schnell - Befehl bitte gleich nochmal") end
        return
    end
    Srv.ChatAt[Caller.Key] = os.time() + 1
    -- PLAYER-21: stummgeschaltet (Admin "mute"): kein Chat an alle und kein Clan-Chat (/c); andere Befehle gehen
    if (not IsCmd or (Text:match("^/(%S*)") or ""):lower() == "c") and Srv.IsMuted(Caller) then
        Notify(Caller.PC, "Du bist im Chat stummgeschaltet")
        return
    end
    -- Befehle (/clan, /c, /lock, /claim ...): nie an alle, nie mit Inhalt ins Log (Codes)
    if IsCmd then return Srv.ChatCommand(Caller, Text) end
    Log("[Chat] %s: %s", Caller.Name, Text)
    ChatAll(World, Srv.IsAdmin(Caller), Srv.ChatName(Caller), Text)
end

-- PLAYER-21 (chat_clantag): Clan vor dem Namen im Chat an alle ("[Clan] Name", ls_clan M.ClanOf; Clan-Namen sind
-- 3-24 Zeichen aus Buchstaben, Ziffern, Leerzeichen, _ - .)
function Srv.ChatName(G)
    if not (G.GuestId and not G.Dup and Srv.Flag("chat_clantag", true)) then return G.Name end
    local Clan = A.Coop.Clan
    if type(Clan) ~= "table" or type(Clan.ClanOf) ~= "function" then return G.Name end
    local ok, Tag = pcall(Clan.ClanOf, G.GuestId)
    if not ok then Srv.Fail("chat_clantag", Tag) return G.Name end
    Tag = type(Tag) == "string" and Tag:gsub("[^%w _%-%.]", ""):sub(1, 24) or ""
    return Tag ~= "" and ("[" .. Tag .. "] " .. G.Name) or G.Name
end

-- PLAYER-21: Stummschalten je Mitspieler-ID (sonst je Verbindung), gilt bis zum Neustart (Srv.Admin.mute/unmute)
Srv.Muted = {}   -- ["guest:<id>" | "key:<PC-Key>"] = Name
function Srv.MuteKey(G) return (G.GuestId and not G.Dup) and ("guest:" .. G.GuestId) or ("key:" .. tostring(G.Key)) end
function Srv.IsMuted(G)
    return Srv.Muted[Srv.MuteKey(G)] ~= nil or (G.Key ~= nil and Srv.Muted["key:" .. G.Key] ~= nil)
end

local function IsBanned(G)
    return (G.GuestId and Srv.Bans["guest:" .. G.GuestId]) or (G.SteamId and Srv.Bans["steam:" .. G.SteamId])
        or (Srv.ValidIp(G.Ip) and Srv.Bans["ip:" .. G.Ip])   -- CORE-26: alte "ip:?"-Eintraege treffen niemanden
end

-- Kicken: dem Spieler den Grund zeigen und ihn ins Hauptmenue schicken (sein Spiel laedt dann den eigenen
-- Spielstand). Haengt die Verbindung nach 10 s noch, wird sein Controller entfernt.
local function Kick(G, Reason)
    if Srv.Kicking[G.Key] then return end
    Srv.Kicking[G.Key] = { PC = G.PC, Name = G.Name, At = os.time() }
    Notify(G.PC, Reason)
    pcall(function() G.PC:ClientReturnToMainMenuWithTextReason(FText(Reason)) end)
    Log("Spieler '%s' (#%d) gekickt: %s", G.Name, G.N, Reason)
end

local function KickTick()
    for Key, K in pairs(Srv.Kicking) do
        if not A.IsAlive(K.PC) then
            Srv.Kicking[Key] = nil
        elseif os.time() - K.At > 10 and not K.Hard then
            K.Hard = true
            pcall(function() local P = K.PC:K2_GetPawn() if A.IsAlive(P) then P:K2_DestroyActor() end end)
            pcall(function() K.PC:K2_DestroyActor() end)
            Log("Spieler '%s' trennte sich nicht selbst: Controller entfernt", K.Name)
        end
    end
end

local function Teleport(G, Loc, Yaw)
    if not (tonumber(Loc.X) and tonumber(Loc.Y) and tonumber(Loc.Z)) then error("Ziel ungueltig") end
    local Rot = { Pitch = 0, Yaw = tonumber(Yaw) or 0, Roll = 0 }
    local Target = { X = Loc.X, Y = Loc.Y, Z = Loc.Z + 50 }
    -- E23: die Bewegungs-Pruefung (main.lua move_check) wertet den Sprung nicht als Verstoss
    if G.Key then
        local Skip = A.Coop.TrustSkip or {}
        A.Coop.TrustSkip = Skip
        Skip[G.Key] = os.clock() + 5
    end
    if A.IsAlive(G.Pawn) then pcall(function() G.Pawn:K2_TeleportTo(Target, Rot) end) end
    -- Der Server uebernimmt die Lage des Spielers (Bewegung): darum auch beim Spieler selbst setzen. CORE-16: per pl_tp
    -- (der Gast versetzt seine eigene Figur), nie ClientSetLocation mit Lua-Strukturen (Regel 4). Alte Gaeste ohne
    -- pl_tp: nur der Server-Teleport.
    local Net = A.Coop.Net
    if G.Key and type(Net) == "table" and type(Net.Has) == "function"
        and A.Safe(function() return Net.Has("pl_tp", G.Key) end, false) then
        local Data = string.format("%.1f|%.1f|%.1f|%.1f", Target.X, Target.Y, Target.Z, Rot.Yaw)
        if not A.Safe(function() return Net.Send("pl_tp", Data, G.Key, 0) end, false) then
            Log("Teleport %s: pl_tp nicht gesendet", tostring(G.Name))
        end
    elseif not Srv.TpOldLogged then
        Srv.TpOldLogged = true
        Log("Teleport %s: Gast ohne pl_tp - nur der Server versetzt die Figur (Gast-Mod aktualisieren)", tostring(G.Name))
    end
end

local function Ban(Entries, Name, Reason)
    local Note = string.format("%s | %s | %s", Name or "?", os.date("%Y-%m-%d %H:%M"), Reason or "")
    for _, Entry in ipairs(Entries) do Srv.Bans[Entry:lower()], Srv.BanNotes[Entry:lower()] = true, Note end
    SaveBans()
end

-- X-CORE3 (srv_adminlog): Admin-Protokoll admin_log.txt im Mod-Ordner, nur angehaengt (keine IPC-Datei):
-- "Zeit | wer | Befehl | Ergebnis". Konsolenbefehle (ohne reine Anzeigen), Admin-Befehle aus dem Spiel, abgelehnte
-- Versuche (hoechstens 1/min je Verbindung), /admin-Anmeldungen (nie das Passwort), AFK-Kicks, Neustarts.
-- Ab 2 MB wird die Datei zu admin_log.1.txt (genau eine alte Datei).
Srv.ADMIN_LOG, Srv.ADMIN_LOG_MAX = "admin_log.txt", 2 * 1024 * 1024
function Srv.AdminLog(Who, Text, Result)
    if not Srv.Flag("srv_adminlog", true) then return end
    local function Clean(S) return (tostring(S or ""):gsub("[%c|]", " "):sub(1, 300)) end
    local ok, err = pcall(function()
        local Path = A.ModDir .. Srv.ADMIN_LOG
        local File = io.open(Path, "a")
        if not File then error("nicht schreibbar") end
        local Size = File:seek("end")
        if type(Size) == "number" and Size > Srv.ADMIN_LOG_MAX then
            File:close()
            os.remove(A.ModDir .. "admin_log.1.txt")
            os.rename(Path, A.ModDir .. "admin_log.1.txt")
            File = io.open(Path, "a")
            if not File then error("nicht schreibbar (nach dem Umbenennen)") end
        end
        File:write(string.format("%s | %s | %s%s\n", os.date("%Y-%m-%d %H:%M:%S"), Clean(Who), Clean(Text),
            Result ~= nil and (" | " .. Clean(Result)) or ""))
        File:close()
    end)
    if not ok then
        if not Srv.AdminLogErr then Srv.AdminLogErr = true Log("Admin-Protokoll %s: Fehler %s", Srv.ADMIN_LOG, tostring(err)) end
        Srv.Fail("srv_adminlog", err)
    end
end

-- Spieler fuer Log/Protokoll: "Name (ID <Mitspieler-ID>)"
function Srv.Who(G)
    if not G then return "?" end
    return string.format("%s (ID %s%s)", tostring(G.Name or "?"), tostring(G.GuestId or "-"), G.Dup and ", Doppel-Login" or "")
end

-- Admin-Befehl eines Nicht-Admins. CORE-24 (log_quiet): hoechstens eine Logzeile je Minute und Verbindung (bis zu
-- 150 Nachrichten/s ueber den Legacy-Eingang); ohne log_quiet jede (alter Weg). Ins Admin-Protokoll immer nur 1/min.
Srv.AdminRejAt = {}
function Srv.AdminReject(Key, Caller, Text, PC)
    local Now = os.time()
    local Fresh = Now >= (Srv.AdminRejAt[Key] or 0)
    if Fresh then Srv.AdminRejAt[Key] = Now + 60 end
    if not Fresh and Srv.LogQuiet() then return end
    local Who = Caller and Srv.Who(Caller)
    if not Who then
        local Name = PC and A.IsAlive(PC) and A.Safe(function()
            local PS = PC.PlayerState
            return A.IsAlive(PS) and PS:GetPlayerName():ToString() or nil
        end) or nil
        Who = string.format("%s (ID %s)", tostring(Name or "?"), tostring(A.Coop.GuestIds and A.Coop.GuestIds[Key] or "-"))
    end
    Log("Admin-Befehl von Nicht-Admin abgelehnt: %s (%s)%s", Who, tostring(Text):sub(1, 120),
        Srv.LogQuiet() and " - weitere hoechstens 1/min" or "")
    if Fresh then Srv.AdminLog(Who, Text, "abgelehnt: keine Admin-Rechte") end
end

-- Admin-Befehle: geben einen kurzen Ergebnistext zurueck (Konsole: ins Log, Admin im Spiel: als Hinweis)
Srv.Admin = {}
Srv.Admin.kick = function(Arg, World)
    local Who, Reason = (Arg or ""):match("^(%S+)%s*(.-)$")
    local G, Err = FindPlayer(World, Who)
    if not G then return Err end
    Kick(G, "Kicked: " .. (Reason ~= "" and Reason or "by admin"))
    return "Kicked " .. G.Name
end
Srv.Admin.ban = function(Arg, World)
    local Who, Reason = (Arg or ""):match("^(%S+)%s*(.-)$")
    if not Who then return "ban <#Nummer|Name|ID|IP> [Grund]" end
    local G = FindPlayer(World, Who)
    Reason = Reason ~= "" and Reason or "by admin"
    if G then
        local Entries = {}
        if Srv.ValidIp(G.Ip) then Entries[#Entries + 1] = "ip:" .. G.Ip end   -- CORE-26: nur lesbare Adressen
        if G.GuestId then Entries[#Entries + 1] = "guest:" .. G.GuestId end
        if G.SteamId then Entries[#Entries + 1] = "steam:" .. G.SteamId end
        if #Entries > 0 then Ban(Entries, G.Name, Reason) end
        Kick(G, "Banned: " .. Reason)
        return "Banned " .. G.Name .. " (" .. #Entries .. " entries)"
    end
    -- Nicht online: direkt eintragen (IP, Steam-ID mit 17 Ziffern, sonst Mitspieler-ID)
    local Entry = Who:match("^%d+%.%d+%.%d+%.%d+$") and ("ip:" .. Who) or (Who:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") and ("steam:" .. Who))
        or (Who:match("^%x+$") and ("guest:" .. Who))
    if not Entry then return "kein Spieler und keine ID/IP: " .. Who end
    Ban({ Entry }, "offline", Reason)
    return "Banned " .. Entry
end
Srv.Admin.unban = function(Arg)
    if not Arg then return "unban <ID|IP>" end
    local Removed = 0
    for Entry in pairs(Srv.Bans) do
        if Entry:match(":(.+)$") == Arg:lower() or Entry == Arg:lower() then Srv.Bans[Entry], Srv.BanNotes[Entry] = nil, nil Removed = Removed + 1 end
    end
    SaveBans()
    return Removed > 0 and ("Unbanned " .. Arg) or ("not banned: " .. Arg)
end
Srv.Admin.tp = function(Arg, World)
    local Who, To = (Arg or ""):match("^(%S+)%s+(.+)$")
    local G, Err = FindPlayer(World, Who)
    if not G then return Err or "tp <Spieler> <Ziel-Spieler | x y z>" end
    local X, Y, Z = To:match("^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)$")
    if X then Teleport(G, { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }) return "Teleported " .. G.Name end
    local T, Err2 = FindPlayer(World, To)
    if not T or not A.IsAlive(T.Pawn) then return Err2 or "Ziel hat keine Figur" end
    Teleport(G, T.Pawn:K2_GetActorLocation(), T.Pawn:K2_GetActorRotation().Yaw)
    return "Teleported " .. G.Name .. " to " .. T.Name
end
Srv.Admin.say = function(Arg, World)
    if not Arg then return "say <Text>" end
    for _, G in ipairs(PlayerList(World)) do Notify(G.PC, "[Server] " .. Arg) end
    ChatAll(World, true, "Server", Arg)
    return "Message sent"
end
Srv.Admin.weather = function(Arg)
    local Name, Seconds = (Arg or ""):match("^(%S+)%s*(%d*)$")
    local Preset = Name and WEATHER[Name:lower()]
    if not Preset then
        local Names = {}
        for K in pairs(WEATHER) do Names[#Names + 1] = K end
        table.sort(Names)
        return "weather <" .. table.concat(Names, "|") .. "> [Sekunden]"
    end
    local Asset = StaticFindObject(WEATHER_PATH .. Preset .. "." .. Preset)
    if not A.IsAlive(Asset) then Asset = A.Safe(function() return LoadAsset(WEATHER_PATH .. Preset .. "." .. Preset) end) end
    local UDW = FindFirstOf("Ultra_Dynamic_Weather_C")
    if not (A.IsAlive(Asset) and A.IsAlive(UDW)) then return "Wetter nicht gefunden" end
    UDW["Change Weather"](UDW, Asset, tonumber(Seconds) or 10)
    return "Weather: " .. Name:lower()
end
-- PLAYER-21: Chat stummschalten (Srv.Muted, je Mitspieler-ID bis zum Neustart); ohne Spieler: Liste der Stummen
Srv.Admin.mute = function(Arg, World)
    if not Arg then
        local L = {}
        for K, Name in pairs(Srv.Muted) do L[#L + 1] = tostring(Name) .. " (" .. K .. ")" end
        table.sort(L)
        return #L > 0 and ("Stumm: " .. table.concat(L, ", ")) or "mute <Spieler> (niemand ist stumm)"
    end
    local G, Err = FindPlayer(World, Arg)
    if not G then return Err end
    Srv.Muted[Srv.MuteKey(G)] = G.Name
    Notify(G.PC, "Du wurdest im Chat stummgeschaltet")
    return "Muted " .. G.Name
end
Srv.Admin.unmute = function(Arg, World)
    if not Arg then return "unmute <Spieler|Mitspieler-ID>" end
    local G = FindPlayer(World, Arg)
    if G then
        local Was = Srv.IsMuted(G)
        Srv.Muted[Srv.MuteKey(G)], Srv.Muted["key:" .. G.Key] = nil, nil
        if Was then Notify(G.PC, "Du darfst wieder chatten") end
        return Was and ("Unmuted " .. G.Name) or ("not muted: " .. G.Name)
    end
    local K = "guest:" .. Arg:lower()   -- nicht online: Eintrag ueber die Mitspieler-ID
    if Srv.Muted[K] then Srv.Muted[K] = nil return "Unmuted " .. K end
    return "not muted: " .. Arg
end

-- CAR-19: Fahrzeuge auflisten (ls_car E19 M.Vehicles: nur Werte) bzw. eines entfernen. Im Spiel die 10 naechsten zum
-- Admin, an der Konsole bis 40 nach Name. Entfernen nie, solange es gefahren wird oder ein Spieler darin/daran ist.
function Srv.CarList()
    local Car = A.Coop.Modules and A.Coop.Modules.ls_car
    if type(Car) ~= "table" or type(Car.Vehicles) ~= "function" then return nil, "Fahrzeug-Modul (ls_car) ohne Vehicles()" end
    local ok, List = pcall(Car.Vehicles)
    if not ok or type(List) ~= "table" then return nil, "Fahrzeugliste: Fehler " .. tostring(List) end
    return List
end

Srv.Admin.vehicles = function(_, _, Caller)
    local List, Err = Srv.CarList()
    if not List then return Err end
    local At = Caller and A.IsAlive(Caller.Pawn) and A.Safe(function()
        local L = Caller.Pawn:K2_GetActorLocation()
        return { X = L.X, Y = L.Y }
    end) or nil
    for _, V in ipairs(List) do
        V.D = At and math.sqrt(((tonumber(V.X) or 0) - At.X) ^ 2 + ((tonumber(V.Y) or 0) - At.Y) ^ 2) / 100 or 0
        V.Name = tostring(V.Name or "?")
    end
    table.sort(List, function(X, Y) if At then return X.D < Y.D end return X.Name < Y.Name end)
    local Max = At and 10 or 40
    local Lines = { string.format("%d Fahrzeuge%s", #List, At and #List > Max and " (die 10 naechsten)" or "") }
    local function Num(V) return tonumber(V) and string.format("%.0f", V) or "?" end
    for I = 1, math.min(#List, Max) do
        local V = List[I]
        local Cls = tostring(V.Cls or "?"):gsub("^BP_", ""):gsub("_C$", "")
        Lines[#Lines + 1] = string.format("%s [%s] %s,%s,%s%s Sprit %s/%s HP %s/%s%s%s%s", V.Name, Cls, Num(V.X), Num(V.Y),
            Num(V.Z), At and string.format(" (%.0f m)", V.D) or "", Num(V.Fuel), Num(V.MaxFuel), Num(V.Hp), Num(V.MaxHp),
            V.Owner and (" Besitzer " .. tostring(V.OwnerName or V.Owner)) or "", V.Lock and " [zu]" or "",
            V.Driven and " [faehrt]" or "")
    end
    if #List > Max then Lines[#Lines + 1] = string.format("... %d weitere", #List - Max) end
    return table.concat(Lines, "\n")
end

Srv.Admin.vehicle_rm = function(Arg, World)
    local Name = Arg and Arg:match("^(%S+)$")
    if not Name then return "vehicle_rm <Fahrzeugname aus 'vehicles'>" end
    local List, Err = Srv.CarList()
    if not List then return Err end
    local Hit
    for _, V in ipairs(List) do if tostring(V.Name):lower() == Name:lower() then Hit = V end end
    if not Hit then return "vehicle_rm: kein Fahrzeug " .. Name end
    if Hit.Driven then return "vehicle_rm: " .. Hit.Name .. " wird gerade gefahren" end
    local Obj = type(Hit.Path) == "string" and A.Safe(function() return StaticFindObject(Hit.Path) end) or nil
    if not A.IsAlive(Obj) then return "vehicle_rm: " .. Hit.Name .. " nicht gefunden" end
    for _, G in ipairs(Guests(World)) do   -- sitzt/haengt ein Spieler darin oder daran?
        if A.IsAlive(G.Pawn) then
            local Parent = A.Safe(function() return G.Pawn:GetAttachParentActor() end)
            if G.Pawn == Obj or (A.IsAlive(Parent) and Parent == Obj) then
                return "vehicle_rm: in " .. Hit.Name .. " sitzt ein Spieler"
            end
        end
    end
    local ok, errD = pcall(function() Obj:K2_DestroyActor() end)
    return ok and ("Removed " .. Hit.Name) or ("vehicle_rm: Fehler " .. tostring(errD))
end

-- Im Spiel: "goto" und "bring" beziehen sich auf den Admin selbst
local function AdminInGame(Cmd, Arg, World, Caller)
    if Cmd == "goto" or Cmd == "bring" then
        local T, Err = FindPlayer(World, Arg)
        if not T or not A.IsAlive(T.Pawn) or not A.IsAlive(Caller.Pawn) then return Err or "keine Figur" end
        local From, To = Caller, T
        if Cmd == "bring" then From, To = T, Caller end
        Teleport(From, To.Pawn:K2_GetActorLocation(), To.Pawn:K2_GetActorRotation().Yaw)
        return (Cmd == "goto" and "Teleported to " or "Brought ") .. T.Name
    end
    if Cmd == "time" then return Srv.Commands.time(Arg, World) or "Time set" end
    -- Cheat-Menue des Admins (main.lua Coop.Cheat): Item vor die Fuesse, Fahrzeug vor ihm, Wetter-Preset, Zeitlupe
    if Cmd == "give" or Cmd == "vehicle" then
        if not A.IsAlive(Caller.Pawn) then return "no character" end
        -- INV-13: "give <Pfad> <n> rm" = der Gast hat seinen Platzhalter schon entfernt (ls_inv ohne Gutschrift, E7)
        local Path, Count, Opt = (Arg or ""):match("^(/Game/[%w_/%.%-]+)%s*(%d*)%s*(%a*)$")
        if not Path then return Cmd .. ": invalid asset" end
        if Opt ~= "" and not (Cmd == "give" and Opt == "rm") then return Cmd .. ": invalid option " .. Opt end
        local Asset = StaticFindObject(Path)
        if not A.IsAlive(Asset) then Asset = A.Safe(function() return LoadAsset(Path) end) end
        if not A.IsAlive(Asset) then return Cmd .. ": not found " .. Path end
        local Name = Path:match("([^%./]+)$")
        if Cmd == "give" then
            -- Als Bodenobjekt vor die Fuesse, nicht ins Inventar: AddNewItemSomewhere + invsync loeste einen kompletten
            -- Neuabgleich aus (Items blinkten, das GPS ging verloren). Hier nur vormerken; ablegen und
            -- "Given ... (vor dir abgelegt)" melden macht Srv.DropTick (mit inv_give: ls_inv direkt ins Inventar).
            if not Srv.IsItemAsset(Asset) then return "give: not an item " .. Name end
            Count = math.min(math.max(tonumber(Count) or 1, 1), 9999)
            -- inv_v2b (ls_inv): direkt ins Inventar (AddNewItemSomewhere -> CLIENT_AddNewItem an den Gast), ohne Neuabgleich.
            -- Nur vormerken, ls_inv legt im naechsten Tick an und meldet "Given ..." per inv_note.
            local InvMod = A.Coop.Modules and A.Coop.Modules.ls_inv
            if InvMod and InvMod.Give and InvMod.Give(Caller.Key, Path, Count, Opt == "rm") then return Srv.QUEUED end
            if not Srv.QueueDrop({ What = "give", Key = Caller.Key, PC = Caller.PC, Asset = Asset, Name = Name, Count = Count }) then
                return "give: busy, try again"
            end
            return Srv.QUEUED
        end
        local Loc, Yaw = Caller.Pawn:K2_GetActorLocation(), Caller.Pawn:K2_GetActorRotation().Yaw
        local R = math.rad(Yaw)
        local At = { X = Loc.X + math.cos(R) * 500, Y = Loc.Y + math.sin(R) * 500, Z = Loc.Z + 100 }
        local Vehicle = World:SpawnActor(Asset, At, { Pitch = 0, Yaw = Yaw, Roll = 0 })
        return A.IsAlive(Vehicle) and ("Spawned " .. Name) or ("vehicle: spawn failed " .. Name)
    end
    -- Eigene Figur des Admins (Cheat-Menue): Hunger/Durst aendern, Schaden (immer mit echter Schadensart, nil
    -- als Klasse liess UE4SS abstuerzen)
    if Cmd == "hunger" or Cmd == "thirst" or Cmd == "damage" then
        local Pawn, Value = Caller.Pawn, tonumber(Arg)
        if not (A.IsAlive(Pawn) and Value) then return Cmd .. ": no character" end
        if Cmd == "damage" then
            A.UEHelpers.GetGameplayStatics():ApplyDamage(Pawn, math.min(math.abs(Value), 1000), Caller.PC, Pawn,
                StaticFindObject("/Script/Engine.DamageType"))
            return string.format("Damage %.0f", Value)
        end
        local Comp = Srv.HungerComp(Pawn)
        if not A.IsAlive(Comp) then
            for _, C in ipairs(FindAllOf("HungerThirstComponent_C") or {}) do
                if A.IsAlive(C) and A.Safe(function() return C:GetOwner() == Pawn end, false) then Comp = C end
            end
        end
        if not A.IsAlive(Comp) then return Cmd .. ": component not found" end
        if Cmd == "hunger" then Comp["Increase Hunger"](Comp, Value) else Comp:IncreaseThirst(Value) end
        return string.format("%s %+.0f", Cmd == "hunger" and "Hunger" or "Thirst", Value)
    end
    if Cmd == "weatherpreset" then
        local Preset = (Arg or ""):match("^([%w_]+)$")
        if not Preset then return "weatherpreset: invalid" end
        local Path = WEATHER_PATH .. Preset .. "." .. Preset
        local Asset = StaticFindObject(Path)
        if not A.IsAlive(Asset) then Asset = A.Safe(function() return LoadAsset(Path) end) end
        local UDW = FindFirstOf("Ultra_Dynamic_Weather_C")
        if not (A.IsAlive(Asset) and A.IsAlive(UDW)) then return "Weather not found: " .. Preset end
        UDW["Change Weather"](UDW, Asset, 10)
        return "Weather: " .. Preset
    end
    if Cmd == "dilation" then
        local Value = tonumber(Arg)
        if not Value then return "dilation <0.1-10>" end
        Value = math.min(math.max(Value, 0.1), 10)
        A.UEHelpers.GetGameplayStatics():SetGlobalTimeDilation(World, Value)
        return string.format("Time dilation: %.2f", Value)
    end
    local Fn = Srv.Admin[Cmd]
    if not Fn then return "unknown command: " .. tostring(Cmd) end
    return Fn(Arg, World, Caller)   -- Caller: z. B. "vehicles" sortiert nach Abstand zum Admin (CAR-19)
end

-- Befehl eines Spielers aus dem Spiel (main.lua: Kind "admin"): nur fuer Admins. Laeuft im Empfangs-Hook: nur
-- vormerken (Key + Text, keine UObjects). Ausgefuehrt im Schnell-Loop (Srv.AdminQueueTick), spaetestens in Srv.Tick:
-- Fahrzeug-Spawn, Teleport, Schaden, Wetter usw. laufen so nie im Hook.
Srv.AdminQueue, Srv.ADMIN_QUEUE_MAX = {}, 32
function Srv.AdminCommand(PC, Text)
    local Key = PC:GetFullName()
    -- CORE-24 (log_quiet): ohne Admin-ID gar nicht erst vormerken (sonst fuellt eine Flut die Warteschlange und kostet
    -- je Nachricht eine Spielersuche); RunAdminCommand prueft weiter alles (Doppel-Login, Passwoerter)
    if Srv.LogQuiet() then
        local Gid = A.Coop.GuestIds and A.Coop.GuestIds[Key]
        if not (Gid and Srv.Admins[Gid] == true) then
            Srv.AdminReject(Key, nil, Text, PC)
            return
        end
    end
    if #Srv.AdminQueue >= Srv.ADMIN_QUEUE_MAX then
        if not Srv.LogQuiet() or os.time() >= (Srv.AdminQFullAt or 0) then
            Srv.AdminQFullAt = os.time() + 60
            Log("Admin-Befehl verworfen (Warteschlange voll): %s", tostring(Text):sub(1, 120))
        end
        return
    end
    Srv.AdminQueue[#Srv.AdminQueue + 1] = { Key = Key, Text = tostring(Text or "") }
    pcall(A.Coop.AddFast, "srvadmin", function() pcall(Srv.AdminQueueTick) return true end)
end

function Srv.AdminQueueTick()
    if #Srv.AdminQueue == 0 then return end
    local Queue = Srv.AdminQueue
    Srv.AdminQueue = {}
    for _, Job in ipairs(Queue) do
        local ok, err = pcall(Srv.RunAdminCommand, Job.Key, Job.Text)
        if not ok then Log("Admin-Befehl fehlerhaft: %s", tostring(err)) end
    end
end

-- Ausfuehren mit frischer Spielersuche (der PC aus dem Hook wird nicht aufgehoben)
function Srv.RunAdminCommand(Key, Text)
    local World = A.CurrentWorld()
    local Caller
    for _, G in ipairs(PlayerList(World)) do if G.Key == Key then Caller = G end end
    local PC = Caller and Caller.PC
    if not Srv.IsAdmin(Caller) then
        Srv.AdminReject(Key, Caller, Text)   -- CORE-24: hoechstens 1 Zeile/min je Verbindung (log_quiet)
        return
    end
    -- Mit Server-Passwort erst nach "auth" (die Mitspieler-ID allein reicht nicht)
    local Auth = Srv.Auth[Caller.Key]
    if Srv.Cfg.Password and not (Auth and Auth.Ok) then
        Log("Admin-Befehl vor dem Passwort abgelehnt: %s (%s)", Caller.Name, tostring(Text))
        Srv.AdminLog(Srv.Who(Caller), Text, "abgelehnt: Server-Passwort fehlt")
        Notify(PC, "Erst das Server-Passwort: im Chat /pw <Passwort>")
        return
    end
    local Cmd, Arg = Text:match("^%s*(%S+)%s*(.-)%s*$")
    local ok, Result = pcall(AdminInGame, Cmd and Cmd:lower(), Arg ~= "" and Arg or nil, World, Caller)
    if ok and Result == Srv.QUEUED then
        Log("[Admin %s] %s -> vorgemerkt", Caller.Name, Text)   -- Ergebnis meldet Srv.DropTick
        Srv.AdminLog(Srv.Who(Caller), Text, "vorgemerkt")       -- X-CORE3
        return
    end
    Result = ok and Result or ("error: " .. tostring(Result))
    Log("[Admin %s] %s -> %s", Caller.Name, Text, tostring(Result))
    Srv.AdminLog(Srv.Who(Caller), Text, Result)                 -- X-CORE3
    Notify(PC, tostring(Result))
end

-- Jede Sekunde: gebannte Spieler kicken; alle 3 s den Admins ihren Status und die Spielerliste schicken
-- Passwort: Der Spieler schickt es gleich nach dem Beitritt ("auth", main.lua Coop.List) oder per Chat "/pw <Passwort>".
-- Ohne richtiges Passwort nach AUTH_SECONDS gekickt, mit falschem sofort. Wird nie geloggt. Die Zeit laeuft erst ab
-- ready (join_v2: nicht, solange er hinter dem Ladebildschirm wartet) bzw. ab dem ersten Sehen, hoechstens AUTH_CAP s
-- ab dem ersten Sehen. Hinweis beim Spieler, sobald sie laeuft (mit Figur), und bei 25 s und 10 s Rest.
local AUTH_SECONDS = 45
Srv.AUTH_CAP = 90
Srv.Auth, Srv.MotdAt = {}, {}
function Srv.OnAuth(PC, Text)
    if not Srv.Cfg.Password then return end
    local Key = PC:GetFullName()
    local A2 = Srv.Auth[Key] or { Since = os.time() }
    Srv.Auth[Key] = A2
    if A2.Ok then return end   -- einmal richtig bleibt richtig: ein spaeteres falsches /pw kickt nicht
    A2.Ok = Text == Srv.Cfg.Password
    A2.Wrong = not A2.Ok
end

-- E26 (srv_auth_gate, CORE-6): Passwort-Server halten neue Gaeste hinter dem Ladebildschirm (main.lua J.HostStep gibt
-- erst frei, wenn das hier false ist: kein Spielen, Pluendern oder Toeten vor dem Passwort). AuthTick kickt dann
-- AUTH_GATE s nach dem ersten Sehen ohne richtiges Passwort (der Mod schickt es gleich nach dem Verbinden).
Srv.AUTH_GATE = 30
function Srv.AuthWait(Key)
    if not (Srv.Cfg and Srv.Cfg.Password) or not Srv.Flag("srv_auth_gate", true) then return false end
    local Auth = type(Key) == "string" and Srv.Auth[Key] or nil
    return not (Auth and Auth.Ok)
end

local function AuthTick(List)
    local Now, Present = os.time(), {}
    local Gate = Srv.Cfg.Password ~= nil and Srv.Flag("srv_auth_gate", true)
    for _, G in ipairs(List) do
        Present[G.Key] = true
        if Srv.Cfg.Password then
            local Auth = Srv.Auth[G.Key] or { Since = Now }
            Srv.Auth[G.Key] = Auth
            if A.Safe(function() return A.Coop.Join.IsReady(G.Key) end, true) then
                Auth.ReadyAt = Auth.ReadyAt or Now
            else
                -- wartet noch hinter dem Ladebildschirm. Vor dem hello sah es schon "ready" aus (Hinweis evtl. schon
                -- gezeigt, unter dem Ladebildschirm): beim echten Start erneut hinweisen
                if Auth.ReadyAt then Auth.ReadyAt, Auth.Noted = nil, nil end
            end
            -- srv_auth_gate: Frist ab dem ersten Sehen (er wartet eingefroren hinter dem Ladebildschirm, kein Hinweis)
            local Left = Gate and (Auth.Since + Srv.AUTH_GATE - Now)
                or (math.min((Auth.ReadyAt or math.huge) + AUTH_SECONDS, Auth.Since + Srv.AUTH_CAP) - Now)
            if Auth.Wrong then Kick(G, "Wrong server password")
            elseif not Auth.Ok and Left < 0 then Kick(G, "This server needs a password")
            elseif not Auth.Ok and not Gate then
                local Stage = (Left <= 10 and 3) or (Left <= 25 and 2) or (Auth.ReadyAt and 1) or 0
                if Stage > (Auth.Noted or 0) and A.IsAlive(G.Pawn) then
                    Auth.Noted = Stage
                    Notify(G.PC, string.format("Server braucht Passwort: im Chat /pw <Passwort> (noch %d s)", math.max(math.floor(Left), 0)))
                end
            end
        end
        -- Willkommens-Text einmal je Verbindung. PLAYER-21 (srv_joinmsg): 2 s nachdem er wirklich im Spiel ist
        -- (Srv.InGame; hinter dem Ladebildschirm lief die 10-s-Chatanzeige sonst ungesehen ab), zusaetzlich als Hinweis.
        -- Alter Weg: 3 s nachdem die Mitspieler-ID da ist.
        local JoinMsg = Srv.Cfg.Motd ~= nil and Srv.Flag("srv_joinmsg", true)
        if Srv.Cfg.Motd and not Srv.MotdAt[G.Key] then
            if JoinMsg then
                if A.Safe(function() return Srv.InGame(G) end, false) then Srv.MotdAt[G.Key] = Now + 2 end
            elseif G.GuestId then
                Srv.MotdAt[G.Key] = Now + 3
            end
        end
        local At = Srv.MotdAt[G.Key]
        if At and At ~= true and Now >= At then
            Srv.MotdAt[G.Key] = true
            local Motd = Srv.Cfg.Motd:gsub("[|%c]", " "):sub(1, 150)
            pcall(function() A.Coop.SendChunked(function(T) A.Coop.SendToClient(G.PC, T) end, "chat", "1|Server|" .. Motd) end)
            if JoinMsg then Notify(G.PC, Motd) end
        end
    end
    for Key in pairs(Srv.Auth) do if not Present[Key] then Srv.Auth[Key] = nil end end
    for Key in pairs(Srv.MotdAt) do if not Present[Key] then Srv.MotdAt[Key] = nil end end
    for Key in pairs(Srv.ConsumeWindow) do if not Present[Key] then Srv.ConsumeWindow[Key] = nil end end
    -- CORE-26: Admin-Anmeldung gilt je Verbindung
    for Key in pairs(Srv.AdminAuth) do if not Present[Key] then Srv.AdminAuth[Key] = nil end end
    for Key in pairs(Srv.AdminFail) do if not Present[Key] then Srv.AdminFail[Key] = nil end end
end

-- PLAYER-15/21: wirklich im Spiel = Mitspieler-ID da, kein Doppel-Login, Figur da, nicht mehr hinter dem Ladebildschirm
-- (join_v2, main.lua Coop.Join.IsReady) und mit Server-Passwort angemeldet
function Srv.InGame(G)
    if not (G.GuestId and not G.Dup and A.IsAlive(G.Pawn)) then return false end
    if not A.Safe(function() return A.Coop.Join.IsReady(G.Key) end, true) then return false end
    if Srv.Cfg.Password then
        local Auth = Srv.Auth[G.Key]
        if not (Auth and Auth.Ok) then return false end
    end
    return true
end

-- Chat-Zeile "Server" an alle (hervorgehoben) bzw. zusaetzlich als Hinweis (wie Admin "say")
function Srv.SayChat(World, Text)
    Text = tostring(Text):gsub("[|%c]", " ")
    Log("[Chat] Server: %s", Text)
    ChatAll(World, true, "Server", Text)
end
function Srv.SayAll(World, Text)
    Log("Ansage an alle: %s", tostring(Text))
    pcall(Srv.Admin.say, tostring(Text), World)
end

-- PLAYER-15 (srv_joinmsg): "<Name> ist beigetreten" an alle, sobald er 2 s lang wirklich im Spiel ist (Srv.InGame),
-- "<Name> hat den Server verlassen", wenn seine Verbindung weg ist (nur nach einer Beitrittsmeldung). Erster Lauf
-- (Start, Schalter wieder an): wer schon im Spiel ist, gilt ohne Meldung als gemeldet.
Srv.Present = {}   -- [PC-Key] = { Name, ReadyAt, Said }
function Srv.JoinTick(World, List, Now)
    local Prime = not Srv.JoinPrimed
    Srv.JoinPrimed = true
    local Seen, Joined, Left = {}, {}, {}
    for _, G in ipairs(List) do
        Seen[G.Key] = true
        local P = Srv.Present[G.Key]
        if not P then P = { Name = G.Name } Srv.Present[G.Key] = P end
        if G.Name and G.Name ~= "?" then P.Name = G.Name end
        if not P.Said then
            if Srv.InGame(G) then
                P.ReadyAt = P.ReadyAt or Now
                if Prime or Now - P.ReadyAt >= 2 then
                    P.Said = true
                    if not Prime then Joined[#Joined + 1] = P.Name end
                end
            else
                P.ReadyAt = nil
            end
        end
    end
    for Key, P in pairs(Srv.Present) do
        if not Seen[Key] then
            Srv.Present[Key] = nil
            if P.Said then Left[#Left + 1] = P.Name end
        end
    end
    for _, Name in ipairs(Joined) do Srv.SayChat(World, Name .. " ist beigetreten") end
    for _, Name in ipairs(Left) do Srv.SayChat(World, Name .. " hat den Server verlassen") end
end

-- PLAYER-15 (srv_afk_min Minuten, 0 = aus): wer so lange weder laeuft (< 100 uu) noch sich umsieht (< 10 Grad), wird
-- gekickt, 1 min vorher ein Hinweis. Nie Admins, Doppel-Logins oder wer hinter dem Ladebildschirm wartet.
-- srv_afk_full_only: nur, wenn der Server voll ist. Nur Werte (Lage, Drehung), keine UObjects ueber Ticks.
Srv.Afk, Srv.AFK_MOVE, Srv.AFK_TURN = {}, 100, 10
function Srv.AfkMoved(E, L, R)
    if (L == nil) ~= (E.L == nil) then return true end   -- Figur kam oder ging (Tod, Respawn)
    if L and math.abs(L.X - E.L.X) + math.abs(L.Y - E.L.Y) + math.abs(L.Z - E.L.Z) >= Srv.AFK_MOVE then return true end
    if R and E.R then
        local function Diff(X, Y) return math.abs((X - Y + 180) % 360 - 180) end
        return Diff(R.Y, E.R.Y) >= Srv.AFK_TURN or Diff(R.P, E.R.P) >= Srv.AFK_TURN
    end
    if R then E.R = R end   -- Drehung erst jetzt lesbar: ab hier Bezug
    return false
end

function Srv.AfkTick(List, Now)
    local Min = Srv.Flag("srv_afk_min", 0)
    if type(Min) ~= "number" or Min <= 0 then
        if next(Srv.Afk) then Srv.Afk = {} end
        return
    end
    local Armed = #List >= Srv.Cfg.MaxPlayers or not Srv.Flag("srv_afk_full_only", false)
    for _, G in ipairs(List) do
        local E = Srv.Afk[G.Key]
        local L = A.IsAlive(G.Pawn) and A.Safe(function()
            local V = G.Pawn:K2_GetActorLocation()
            return { X = V.X, Y = V.Y, Z = V.Z }
        end) or nil
        local R = A.IsAlive(G.PC) and A.Safe(function()
            local V = G.PC:GetControlRotation()
            return { P = V.Pitch, Y = V.Yaw }
        end) or nil
        if not E or G.Dup or Srv.IsAdmin(G) or not A.Safe(function() return A.Coop.Join.IsReady(G.Key) end, true)
            or Srv.AfkMoved(E, L, R) then
            Srv.Afk[G.Key] = { L = L, R = R, Since = Now }
        elseif Armed and not Srv.Kicking[G.Key] then
            -- immer erst der Hinweis, der Kick fruehestens 60 s danach (auch wenn der Server eben erst voll wurde)
            local Idle = Now - E.Since
            if not E.Warned then
                if Idle >= Min * 60 - 60 then
                    E.Warned = Now
                    Notify(G.PC, "AFK: in 1 min wirst du gekickt - kurz bewegen genuegt")
                end
            elseif Idle >= Min * 60 and Now - E.Warned >= 60 then
                Kick(G, string.format("AFK (%s min ohne Bewegung)", tostring(Min)))
                Srv.AdminLog("Server (AFK)", "kick " .. Srv.Who(G), string.format("%s min ohne Bewegung", tostring(Min)))
            end
        end
    end
end

-- CORE-30: Tabellen je Verbindung (PC-Key) und je Figur (Name) wuchsen auf einem Dauer-Server mit jedem Beitritt und
-- Respawn. Jede Minute: Eintraege getrennter Verbindungen weg; Figuren 10 min nach dem letzten Sehen, wenn es sie
-- nicht mehr gibt (StaticFindObject des gemerkten Pfads: wer lange faehrt, ist nicht seine Figur, bleibt aber gemerkt).
Srv.PRUNE_S, Srv.PAWN_KEEP_S = 60, 600
function Srv.Prune(List, Now)
    if Now < (Srv.PruneAt or 0) then return end
    Srv.PruneAt = Now + Srv.PRUNE_S
    local Present, N = {}, 0
    for _, G in ipairs(List) do Present[G.Key] = true end
    for _, T in ipairs({ Srv.LastStart, Srv.Placed, Srv.PendWindow, Srv.ChatAt, Srv.AdminSent, Srv.AdminRejAt, Srv.Afk }) do
        for Key in pairs(T) do
            if not Present[Key] then T[Key] = nil N = N + 1 end
        end
    end
    for Key in pairs(Srv.Muted) do
        local PCKey = Key:match("^key:(.+)$")
        if PCKey and not Present[PCKey] then Srv.Muted[Key] = nil N = N + 1 end
    end
    for Name, E in pairs(Srv.SeenPawns) do
        if type(E) ~= "table" or Now - (E.T or 0) > Srv.PAWN_KEEP_S then
            local Obj = type(E) == "table" and E.P and A.Safe(function() return StaticFindObject(E.P) end) or nil
            if A.IsAlive(Obj) then E.T = Now else Srv.SeenPawns[Name] = nil N = N + 1 end
        end
    end
    for Name in pairs(Srv.MedicLast) do
        if not Srv.SeenPawns[Name] then Srv.MedicLast[Name] = nil N = N + 1 end
    end
    for Name, T in pairs(Srv.Restored) do
        if type(T) ~= "number" or Now - T > Srv.PAWN_KEEP_S then Srv.Restored[Name] = nil N = N + 1 end
    end
    Srv.Pruned = (Srv.Pruned or 0) + N
end

local function AdminTick(World)
    KickTick()
    local List = PlayerList(World)
    for _, G in ipairs(List) do
        if IsBanned(G) then Kick(G, "Banned from this server") end
    end
    AuthTick(List)
    local Now = os.time()
    if Srv.Flag("srv_joinmsg", true) then   -- PLAYER-15
        local okJ, errJ = pcall(Srv.JoinTick, World, List, Now)
        if not okJ then Log("Beitrittsmeldungen: Fehler %s", tostring(errJ)) Srv.Fail("srv_joinmsg", errJ) end
    elseif Srv.JoinPrimed then
        Srv.Present, Srv.JoinPrimed = {}, false
    end
    local okA, errA = pcall(Srv.AfkTick, List, Now)   -- PLAYER-15 (aus mit srv_afk_min=0)
    if not okA then Log("AFK-Pruefung: Fehler %s", tostring(errA)) Srv.Fail("srv_afk_min", errA) end
    local okP, errP = pcall(Srv.Prune, List, Now)     -- CORE-30
    if not okP and not Srv.PruneErr then Srv.PruneErr = true Log("Aufraeumen der Tabellen: Fehler %s", tostring(errP)) end
    if os.time() < (Srv.AdminSyncAt or 0) then return end
    Srv.AdminSyncAt = os.time() + 3
    local Lines = {}
    for _, G in ipairs(List) do
        -- PLAYER-20 (K33): 4. Feld PlayerId fuer "kick/ban pid:<PlayerId>" (alte Gaeste lesen nur die ersten drei)
        local Pid = Srv.Pid(G)
        Lines[#Lines + 1] = string.format("%d;%s;%d", G.N, (G.Name:gsub("[;|\n]", " ")), G.Ping) .. (Pid and (";" .. Pid) or "")
    end
    for _, G in ipairs(List) do
        local IsAdmin = Srv.IsAdmin(G)
        local Send = function(T) A.Coop.SendToClient(G.PC, T) end
        if Srv.AdminSent[G.Key] ~= IsAdmin then
            Srv.AdminSent[G.Key] = IsAdmin
            A.Coop.SendChunked(Send, "admin", IsAdmin and "1" or "0")
            if IsAdmin then Log("Admin online: %s", G.Name) end
        end
        if IsAdmin then A.Coop.SendChunked(Send, "plist", table.concat(Lines, "\n")) end
    end
end

-- Konsolenbefehle (Panel/Terminal -> start.sh -> server_cmd.txt)
for _, Name in ipairs({ "kick", "ban", "unban", "tp", "say", "weather", "mute", "unmute", "vehicles", "vehicle_rm" }) do
    Srv.Commands[Name] = function(Arg, World) Log("%s", tostring(Srv.Admin[Name](Arg, World))) end
end
Srv.Commands.bans = function()
    local N = 0
    for Entry in pairs(Srv.Bans) do N = N + 1 Log("  %s  # %s", Entry, Srv.BanNotes[Entry] or "") end
    Log("%d Ban-Eintraege (%s)", N, BANS_FILE)
end
Srv.Commands.help = function()
    Log("Befehle: status, players, save, stop (= shutdown), restart <Minuten>|cancel, fps <n> | fps auto on|off, time <Stunde>, corpses, kick <Spieler> [Grund], ban <Spieler|ID|IP> [Grund], unban <ID|IP>, bans, tp <Spieler> <Spieler|x y z>, say <Text>, mute [Spieler], unmute <Spieler|ID>, weather <Art> [s], vehicles, vehicle_rm <Name>, flags [list], dropmode <0|1|2>, perf")
    Log("Spieler: #Nummer oder pid:<PlayerId> aus 'players', Namensteil, Mitspieler-ID, Steam-ID oder IP. Admins: Mitspieler-IDs in LASTSIGNAL_ADMINS " ..
        "(optional steam:<id>; mit LASTSIGNAL_ADMIN_PASSWORD im Spiel zuerst /admin <Passwort>)")
end
Srv.Commands.corpses = function()
    for _, Kind in ipairs(CLEANUP) do
        local List, Oldest, Minutes = CleanupList(Kind), 0, Srv.Cfg[Kind.Setting]
        for _, E in ipairs(List) do Oldest = math.max(Oldest, E.Age) end
        Log("%d %s, aelteste seit %d min, seit dem Start entfernt: %d (entfernen nach %s)", #List, Kind.What,
            Oldest // 60, Srv.Removed[Kind.What] or 0, Minutes > 0 and (Minutes .. " min") or "aus")
    end
end
Srv.Commands.status = function(_, World)
    Log("'%s' Port %d, Zustand %s, %d/%d Spieler, %d FPS (Ziel mit Spielern %d, Einstellung %d, Untergrenze %d, " ..
        "Automatik %s, Drossel %s, gemessen %s), laeuft %d min, letzter Save %s",
        Srv.Cfg.Name, Srv.Cfg.Port, Srv.State, #Guests(World), Srv.Cfg.MaxPlayers, Srv.Fps or 0, Srv.FpsCap(), Srv.Cfg.Fps,
        Srv.Cfg.FpsMin or 0, Srv.Cfg.FpsAuto and "an" or "aus", Srv.Cap and tostring(Srv.Cap) or "-",
        Srv.AvgFps and string.format("%.0f", Srv.AvgFps) or "-",
        (os.time() - Srv.StartedAt) // 60,
        Srv.SavedAt and (os.date("%H:%M:%S", Srv.SavedAt)) or "noch keiner")
    if Srv.RestartAt then   -- X-CORE1
        Log("Neustart geplant: %s (%s), in %d min", os.date("%Y-%m-%d %H:%M:%S", Srv.RestartAt), tostring(Srv.RestartWhy),
            math.max(0, Srv.RestartAt - os.time()) // 60)
    end
end
Srv.Commands.players = function(_, World)
    local List = PlayerList(World)
    Log("%d Spieler online", #List)
    for _, G in ipairs(List) do
        Log("  #%d %s  pid:%s  Ping %d ms  IP %s  Mitspieler-ID %s  Steam %s%s%s", G.N, G.Name, tostring(Srv.Pid(G) or "-"), G.Ping,
            G.Ip, G.GuestId or "-", G.SteamId or "-", G.Dup and "  [Doppel-Login]" or (Srv.IsAdmin(G) and "  [Admin]" or ""),
            Srv.IsMuted(G) and "  [stumm]" or "")
    end
end
Srv.Commands.save = function() Srv.Save("Konsole") end
Srv.Commands.stop = function()
    if Srv.StopAt then return end
    pcall(function() if A.Coop.Player then A.Coop.Player.Shutdown("stop") end end)   -- ls_player: Gaeste sofort speichern, bye
    -- PLAYER-24 (E29): offene Clan-Aenderungen jetzt schreiben (ls_clan speichert sonst erst 2 s spaeter)
    local Clan = A.Coop.Clan
    if type(Clan) == "table" and type(Clan.Flush) == "function" then
        local okC, errC = pcall(Clan.Flush)
        if not okC then Log("Clans beim Beenden nicht gespeichert: %s", tostring(errC)) end
    end
    Srv.RestartAt = nil   -- X-CORE1: ein geplanter Neustart ist damit erledigt
    Srv.Save("Server stoppt")
    -- CORE-10 (srv_store_freeze, E22): ab jetzt schreibt niemand mehr Gast-Slots (Trennen nach bye, Ledger, Quests);
    -- das Festschreiben beim Beenden nimmt den eben eingefrorenen Stand auch fuers .sav
    if Srv.Flag("srv_store_freeze", true) then
        A.Coop.GuestStoreFrozen = true
        Log("Gast-Speicherstaende eingefroren (Server stoppt)")
    end
    Srv.StopAt = os.time()
    -- srv_stopping_marker: start.sh startet seine Beenden-Frist (STOP_LIMIT) schon jetzt, nicht erst bei
    -- server_stopped.txt direkt vor QuitGame -> auch ein Haenger im Zustand "stopping" endet nach der Frist.
    -- start.sh loescht den Merker vor jedem Spielstart; die Startsicherung haengt weiter nur an server_stopped.txt.
    if Srv.Flag("srv_stopping_marker", true) then
        if not Srv.WriteText(A.ModDir .. "server_stopping.txt", os.date("%Y-%m-%d %H:%M:%S")) then
            Log("WARNUNG: server_stopping.txt nicht geschrieben")
        end
    end
    Srv.RemoveFile(A.ModDir .. "status.txt")   -- keine Anmeldung mehr bei der Master-Liste
    SetState("stopping")
end
Srv.Commands.quit = Srv.Commands.stop
-- start.sh bei SIGTERM/docker stop: wie stop (Gaeste sofort speichern, bye, Welt speichern, beenden). Eigener Name,
-- damit es auch ohne ls_player (Testbefehl shutdown) nicht als unbekannter Befehl endet.
Srv.Commands.shutdown = Srv.Commands.stop

-- X-CORE1: geplanter Neustart = Ansagen bei 10/5/1 min und 30 s, dann stop (start.sh endet sauber mit Code 0, das
-- Panel bzw. Docker startet neu: Pterodactyl-Absturzerkennung, Docker --restart unless-stopped). Konsole
-- "restart <Minuten>" (0 = sofort), "restart cancel", ohne Argument: Stand. LASTSIGNAL_RESTART_AT=HH:MM: taeglich.
Srv.RESTART_SAY = { 600, 300, 60, 30 }
function Srv.ScheduleRestart(At, Why)
    Srv.RestartAt, Srv.RestartWhy, Srv.RestartSaid = At, Why, {}
end

-- Naechster taeglicher Termin nach After (Uhrzeit des Servers; frisch gestartet: nicht in der ersten Stunde)
function Srv.ArmDaily(After)
    local R = Srv.Cfg and Srv.Cfg.RestartAt
    if not R then return end
    local D = os.date("*t", After)
    local At = os.time({ year = D.year, month = D.month, day = D.day, hour = R.H, min = R.M, sec = 0 })
    if At <= After then At = os.time({ year = D.year, month = D.month, day = D.day + 1, hour = R.H, min = R.M, sec = 0 }) end
    Srv.ScheduleRestart(At, string.format("taeglich %02d:%02d", R.H, R.M))
    Log("Taeglicher Neustart geplant: %s", os.date("%Y-%m-%d %H:%M", At))
end

function Srv.RestartLeft(Left)
    if Left >= 60 then return string.format("%d min", (Left + 30) // 60) end
    return string.format("%d s", math.max(Left, 1))
end

-- Aus Tick ("running", jede Sekunde). Force = true: eben geplant, einmal sofort ansagen
function Srv.RestartTick(World, Force)
    local At = Srv.RestartAt
    if not At or Srv.StopAt then return end
    local Left = At - os.time()
    if Left <= 0 then
        Srv.RestartAt = nil
        Log("Neustart (%s): Server stoppt jetzt", tostring(Srv.RestartWhy))
        Srv.AdminLog("Server", "restart", tostring(Srv.RestartWhy))
        Srv.SayAll(World, "Server startet jetzt neu - gleich wieder da")
        Srv.Commands.stop()
        return
    end
    local Due = Force == true
    for _, T in ipairs(Srv.RESTART_SAY) do
        if Left <= T and not Srv.RestartSaid[T] then Srv.RestartSaid[T], Due = true, true end
    end
    if Due then Srv.SayAll(World, "Server-Neustart in " .. Srv.RestartLeft(Left)) end
end

Srv.Commands.restart = function(Arg, World)
    local Word = Arg and Arg:lower() or nil
    if not Word then
        if Srv.RestartAt then
            Log("Neustart geplant um %s (%s), noch %s", os.date("%H:%M:%S", Srv.RestartAt), tostring(Srv.RestartWhy),
                Srv.RestartLeft(math.max(0, Srv.RestartAt - os.time())))
        else
            Log("Kein Neustart geplant. restart <Minuten 0-1440> | restart cancel")
        end
        return
    end
    if Word == "cancel" or Word == "off" or Word == "abbrechen" then
        if not Srv.RestartAt then Log("Kein Neustart geplant") return end
        local Said = next(Srv.RestartSaid or {}) ~= nil
        Srv.RestartAt = nil
        Log("Neustart abgebrochen")
        if Said then Srv.SayAll(World, "Server-Neustart abgebrochen") end
        Srv.ArmDaily(os.time() + 3600)   -- taeglicher Termin: der naechste (nicht gleich wieder derselbe)
        return
    end
    local Min = tonumber(Word)
    if not Min or Min < 0 or Min > 1440 then Log("restart <Minuten 0-1440> | restart cancel") return end
    Srv.ScheduleRestart(os.time() + math.floor(Min * 60), "Konsole")
    Log("Neustart in %s geplant (%s)", Srv.RestartLeft(math.floor(Min * 60)), os.date("%H:%M:%S", Srv.RestartAt))
    if Srv.State == "running" then pcall(Srv.RestartTick, World, true) end
end

-- CORE-12 (E25): "flags" zeigt die wegen Fehlern abgeschalteten Schalter (ls_core Core.Down) und schaltet sie wieder
-- an (Core.ResetFlags loggt FLAG_UP je Name); "flags list" zeigt nur.
Srv.Commands.flags = function(Arg)
    local Core = Srv.Core()
    if not (Core and type(Core.Down) == "table") then Log("flags: ls_core nicht geladen") return end
    local Now, List = os.clock(), {}
    local Until = type(Core.DownUntil) == "table" and Core.DownUntil or {}
    for Name, At in pairs(Core.Down) do
        local U = Until[Name]
        List[#List + 1] = string.format("%s (aus seit %s s%s)", tostring(Name),
            type(At) == "number" and string.format("%d", math.floor(Now - At)) or "?",
            type(U) == "number" and string.format(", neuer Versuch in %d s", math.floor(math.max(0, U - Now)))
                or (U == false and ", bis zum Neustart" or ""))
    end
    table.sort(List)
    Log("%d Schalter aus%s%s", #List, #List > 0 and ": " or "", table.concat(List, "; "))
    if #List == 0 or (Arg and Arg:lower() == "list") then return end
    if type(Core.ResetFlags) ~= "function" then Log("flags: ls_core ohne ResetFlags (alter Stand)") return end
    local ok, Res = pcall(Core.ResetFlags)
    if ok then Log("%d Schalter wieder an", type(Res) == "table" and #Res or 0) else Log("flags: Fehler %s", tostring(Res)) end
end
-- Uhrzeit setzen: "time 12" oder "time 1830" (Ultra Dynamic Sky zaehlt 0-2400, 100 = 1 Stunde)
Srv.Commands.time = function(Arg)
    local N = tonumber(Arg)
    if not N then Log("time <Stunde> oder <HHMM>, z. B. time 12 oder time 1830") return end
    if N < 24 then N = N * 100 else N = math.floor(N / 100) * 100 + (N % 100) / 60 * 100 end
    local Sky = FindFirstOf("Ultra_Dynamic_Sky_C")
    if not A.IsAlive(Sky) then Log("time: kein Himmel gefunden") return end
    Sky["Time of Day"] = N
    pcall(function() Sky:ForceNetUpdate() end)
    Log("Uhrzeit auf %02d:%02d gesetzt", math.floor(N / 100), math.floor((N % 100) * 0.6 + 0.5))
end
Srv.Commands.fps = function(Arg)
    if not Srv.Flag("server_fps_v2", true) then   -- alter Weg
        local N = tonumber(Arg)
        if N and N >= 5 and N <= 120 then Srv.Cfg.Fps, Srv.Cap = N, nil Log("Server-FPS mit Spielern: %d", N) end
        return
    end
    local Auto = Arg and Arg:lower():match("^auto%s*(%S*)$")
    if Auto then
        if Auto == "on" or Auto == "an" or Auto == "1" then Srv.Cfg.FpsAuto = true
        elseif Auto == "off" or Auto == "aus" or Auto == "0" then Srv.Cfg.FpsAuto = false end
        Srv.Cap, Srv.Low, Srv.High = nil, 0, 0
        Srv.FpsGraceUntil = os.time() + Srv.FpsGraceS
        Log("FPS-Automatik %s (Ziel %d, Untergrenze %d)", Srv.Cfg.FpsAuto and "an" or "aus", Srv.Cfg.Fps, Srv.Cfg.FpsMin)
        return
    end
    local N = tonumber(Arg)
    if not (N and N >= 5 and N <= 120) then
        Log("fps <5-120> oder fps auto on|off (jetzt Ziel %d, Untergrenze %d, Automatik %s)", Srv.Cfg.Fps,
            Srv.Cfg.FpsMin, Srv.Cfg.FpsAuto and "an" or "aus")
        return
    end
    Srv.Cfg.Fps, Srv.Cap, Srv.Low, Srv.High = N, nil, 0, 0
    -- CORE-11: Untergrenze aus der Einstellung (nicht die zuletzt gesenkte): "fps 30" und danach "fps 60" -> wieder 45
    Srv.Cfg.FpsMin = math.min(Srv.Cfg.FpsMinCfg or Srv.Cfg.FpsMin, N)
    Srv.FpsGraceUntil, Srv.Fps = os.time() + Srv.FpsGraceS, nil   -- Srv.Fps = nil: Tick setzt t.MaxFPS neu
    Log("Server-FPS mit Spielern: %d, Untergrenze %d (Drossel zurueckgesetzt). Gilt bis zum Neustart - dauerhaft: LASTSIGNAL_FPS",
        N, Srv.Cfg.FpsMin)
end

-- CORE-21: Testbefehle (ls_test/main.lua) auf dem Server nur mit dev=1/test=1, ausser diesen harmlosen
-- Anzeigen/Schaltern (dropmode = setzt nur die Zahl Coop.DropMode, wie drop_mode in coop.txt; steht in help).
-- dropmode bewusst NICHT in AUDIT_SKIP: aendert Serverzustand, gehoert ins Admin-Protokoll
Srv.SAFE_TEST = { perf = true, netstats = true, native_ev = true, r5 = true, dropmode = true }
-- X-CORE3: reine Anzeigen kommen nicht ins Admin-Protokoll
Srv.AUDIT_SKIP = { help = true, status = true, players = true, bans = true, corpses = true, vehicles = true,
                   perf = true, netstats = true, native_ev = true, r5 = true }

-- CORE-9 (srv_cmd_rename): start.sh haengt Zeilen jederzeit an (>>). Lesen und dann leeren verlor eine dazwischen
-- angehaengte Zeile (auch "shutdown"). Darum erst umbenennen (atomar) und die .work erst im naechsten Durchlauf lesen
-- und loeschen: eine waehrend des Umbenennens geschriebene Zeile landet sicher darin, neue in einer neuen Datei.
function Srv.ReadCommands()
    local Path, Work = A.ModDir .. "server_cmd.txt", A.ModDir .. "server_cmd.work"
    local Content
    local File = io.open(Work, "r")
    if File then
        Content = File:read("*a")
        File:close()
        if not os.remove(Work) then   -- sonst liefen dieselben Befehle jede Sekunde erneut
            if not Srv.CmdWorkErr then Srv.CmdWorkErr = true Log("WARNUNG: server_cmd.work nicht loeschbar - Befehle uebersprungen") end
            return nil
        end
    end
    os.rename(Path, Work)
    return Content
end

local function RunCommands(World)
    local Path = A.ModDir .. "server_cmd.txt"
    local Content
    if Srv.Flag("srv_cmd_rename", true) then
        Content = Srv.ReadCommands()
    else
        local File = io.open(Path, "r")
        if not File then return end
        Content = File:read("*a")
        File:close()
        if not Content or Content:match("^%s*$") then return end
        File = io.open(Path, "w")
        if File then File:close() end
    end
    if not Content or Content:match("^%s*$") then return end
    for Line in Content:gmatch("[^\r\n]+") do
        local Cmd, Arg = Line:match("^%s*(%S+)%s*(.-)%s*$")
        if Cmd then
            Cmd = Cmd:lower()
            if not Srv.AUDIT_SKIP[Cmd] then Srv.AdminLog("Konsole", Line) end   -- X-CORE3 (ohne reine Anzeigen)
            local Handler = Srv.Commands[Cmd]
            local Fallback = A.TestCommands[Cmd]
            if Handler then
                local ok, err = pcall(Handler, Arg ~= "" and Arg or nil, World)
                if not ok then Log("%s: Fehler %s", Cmd, tostring(err)) end
            elseif Fallback and (A.Settings.dev or A.Settings.test or Srv.SAFE_TEST[Cmd]) then
                local ok, err = pcall(Fallback, Arg ~= "" and Arg or nil)
                if not ok then Log("%s: Fehler %s", Cmd, tostring(err)) end
            elseif Fallback then
                Log("Testbefehl '%s' laeuft auf dem Server nur mit dev=1 oder test=1 in coop.txt (Schutz des laufenden Spiels)", Cmd)
            else
                Log("Unbekannter Befehl '%s' (help zeigt alle)", Cmd)
            end
        end
    end
end

-- Der Server laeuft ohne Steam (Null-Onlinesystem), Mitspieler melden sich mit ihrer Steam-ID an. Unreal
-- lehnt fremde ID-Typen im PreLogin ab ("incompatible_unique_net_id"), ausser sie stehen in
-- CompatibleUniqueNetIdTypes. Das Feld ist keine Config-Eigenschaft (Engine.ini wirkt nicht): zur Laufzeit setzen.
local function AllowSteamIds()
    local Interface = FindFirstOf("OnlineEngineInterfaceImpl")
    if not A.IsAlive(Interface) then return false end
    local Types = Interface.CompatibleUniqueNetIdTypes
    for _, Wanted in ipairs({ "STEAM", "NULL" }) do
        local Found = false
        for i = 1, #Types do if Types[i]:ToString() == Wanted then Found = true end end
        if not Found then Types[#Types + 1] = FName(Wanted) end
    end
    Log("Steam-Spieler zugelassen (%d ID-Typen)", #Types)
    return true
end

-- X-CORE2 (srv_empty_save): geht der letzte Gast, 15 s spaeter die Welt speichern (mit Gast-Journal, Besitz und
-- Sicherungs-Anforderung wie jedes Srv.Save): ein leerer Server haelt nie ungespeicherten Fortschritt, das Journal
-- ist im Leerlauf leer. Kommt vorher jemand, entfaellt es; ein Speichern in der Zeit (Autosave) genuegt.
Srv.EMPTY_SAVE_S = 15
function Srv.EmptySaveTick(N)
    if N > 0 then Srv.HadGuests, Srv.EmptySince = true, nil return end
    if not Srv.HadGuests then return end
    if not Srv.Flag("srv_empty_save", true) then Srv.HadGuests, Srv.EmptySince = false, nil return end
    local Now = os.time()
    Srv.EmptySince = Srv.EmptySince or Now
    if Now - Srv.EmptySince < Srv.EMPTY_SAVE_S then return end
    local Since = Srv.EmptySince
    Srv.HadGuests, Srv.EmptySince = false, nil
    if (Srv.SavedAt or 0) >= Since then return end
    Srv.Save("Server leer")
end

-- Laeuft jede Sekunde in der Hauptschleife von main.lua (Spiel-Thread), siehe Srv.Tick unten.
local function Tick(World)
    if not Srv.IdsAllowed then Srv.IdsAllowed = A.Safe(AllowSteamIds, false) end
    RunCommands(World)
    local Mode = A.NetModeName(World)

    if Srv.State == "title" then
        -- 1. Hauptmenue als Listen-Server oeffnen (vorher Titelbild weg und Menue fertig geladen)
        SetFps(30)
        if Mode ~= "Standalone" then SetState("menu") return end
        local okLS, errLS = pcall(Srv.LoadingWatch)
        if not okLS then Log("Ladebildschirm-Waechter-Fehler: %s", tostring(errLS)) end
        pcall(Srv.BootDiag, Mode)
        if DismissTitle() then return end
        local Ready = A.ReadyToTravel()
        if MenuShown() and Ready then
            A.StartHostMode()
            SetState("reload")
        elseif Since() > BOOT_GIVE_UP then
            Quit("Hauptmenue kam nicht (" .. BOOT_GIVE_UP .. " s)")
        end

    elseif Srv.State == "reload" then
        pcall(Srv.BootDiag, Mode)
        if Mode == "ListenServer" then SetState("menu")
        elseif Since() > BOOT_GIVE_UP then Quit("Listen-Server startete nicht") end

    elseif Srv.State == "menu" then
        -- 2. Im Listen-Server-Menue den letzten Spielstand laden
        local okLS, errLS = pcall(Srv.LoadingWatch)
        if not okLS then Log("Ladebildschirm-Waechter-Fehler: %s", tostring(errLS)) end
        pcall(Srv.BootDiag, Mode)
        if DismissTitle() then return end
        local Menu = MenuShown()
        if Menu and A.ReadyToTravel() then
            pcall(Srv.HookContinueCheck, Menu)
            Srv.CheckResult, Srv.FallbackDone = nil, false
            if Srv.Cfg.Slot then
                -- Continue laedt den aktuellen Spielstand der Spielstand-Bibliothek (EMS)
                local okSlot, errSlot = pcall(function()
                    local Ems = Srv.Ems()   -- CORE-20: nie eine Methode auf einem ungueltigen Objekt
                    if not Ems then error("EMS-Bibliothek nicht gefunden") end
                    Ems:SetCurrentSaveGameName(World, Srv.Cfg.Slot)
                end)
                Log("Spielstand '%s' gewaehlt%s", Srv.Cfg.Slot, okSlot and "" or (": Fehler " .. tostring(errSlot)))
            end
            local ok, err = pcall(function() Menu[CONTINUE](Menu) end)
            Log("Lade den letzten Spielstand (Continue)%s", ok and "" or (": Fehler " .. tostring(err)))
            Srv.NudgeAt = CONTINUE_RETRY
            Srv.LoadStartedAt = Srv.LoadStartedAt or os.time()   -- erstes Continue; SetState setzt Since() zurueck
            SetState("loading")
        elseif Since() > BOOT_GIVE_UP then
            Quit("Menue im Listen-Server kam nicht")
        end

    elseif Srv.State == "loading" then
        local okLS, errLS = pcall(Srv.LoadingWatch)
        if not okLS then Log("Ladebildschirm-Waechter-Fehler: %s", tostring(errLS)) end
        local Pawn = OwnPawn()
        local Loading = A.VisibleWidget("LoadingScreenWidget_C") or MenuShown() ~= nil
        if Pawn and not Loading and A.Safe(function()
            local Move = Pawn.CharacterMovement
            return A.IsAlive(Move) and Move.MovementMode ~= 0
        end, false) then
            -- Startpunkt = Boden unter der geladenen Figur (aeltere Spielstaende haben sie evtl. in der Luft).
            -- Erst zum Geist machen (Kollision aus), sonst trifft die Linie die eigene Kapsel.
            local L = Pawn:K2_GetActorLocation()
            L = { X = L.X, Y = L.Y, Z = L.Z }
            Ghost(Pawn, World)
            local Floor = Ground(L)
            Srv.Anchor = { Loc = Floor or L, Yaw = Pawn:K2_GetActorRotation().Yaw }
            Log("Startpunkt der Welt: %.0f %.0f %.0f (%s)", Srv.Anchor.Loc.X, Srv.Anchor.Loc.Y, Srv.Anchor.Loc.Z,
                Floor and string.format("Boden %.0f m unter der Figur", (L.Z - Floor.Z) / 100) or "kein Boden gefunden")
            A.RunCommand("Save.AutoSaveSlot 0")   -- Autosave des Spiels ohne neuen Slot je Speichern
            local okRefill, errRefill = pcall(ApplyLootRefill, false)
            if not okRefill then Log("Kisten-Nachfuellen-Fehler: %s", tostring(errRefill)) end
            Srv.RefillCheckAt, Srv.PerfAt = os.time() + 60, os.time() + PERF_LOG_SECONDS
            HookStarterKit()
            pcall(Srv.NoThumb, Pawn)
            Srv.SavedAt = os.time()
            SetState("running")
            Log("Last-Signal-Server bereit: '%s', UDP-Port %d, max. %d Spieler, Autosave alle %d min",
                Srv.Cfg.Name, Srv.Cfg.Port, Srv.Cfg.MaxPlayers, Srv.Cfg.SaveMinutes)
        elseif MenuShown() and Since() >= BOOT.FALLBACK and not Srv.FallbackDone then
            Srv.FallbackDone = true
            local okF, errF = pcall(Srv.LoadFallback)
            if not okF then Log("Ersatzweg-Laden-Fehler: %s", tostring(errF)) end
        elseif MenuShown() and Since() > CONTINUE_RETRY then
            Log("Kein Spielstand geladen (Pruefung: %s). Liegt ein Spielstand in saves/? (Ordner mit Slot.sav + SurrounDead.sav vom PC)",
                tostring(Srv.CheckResult or "keine Antwort"))
            local R = Srv.CheckResult
            if R == "OnFailed" then
                pcall(Srv.RestoreRequest, "OnFailed")   -- CORE-5: nur mit srv_auto_restore=1
                Quit("Spielstand-Pruefung meldet Fehler (OnFailed): kein gueltiger Spielstand, erneutes Continue hilft nicht")
            elseif R == "OnVersionMismatch" and not Srv.Flag("srv_force_load", false) then
                Quit("Spielstand passt nicht zur Spielversion (OnVersionMismatch, z. B. Spielstand aus UE 5.3): " ..
                    "Spielstand ersetzen oder srv_force_load=1 in coop.txt (vorher sichern)")
            elseif os.time() - (Srv.LoadStartedAt or Srv.StateSince) > LOAD_GIVE_UP then
                Quit("Spielstand lud nicht (" .. LOAD_GIVE_UP .. " s seit dem ersten Continue)")
            else
                SetState("menu")
            end
        elseif Since() >= Srv.NudgeAt then
            -- Haengt das Laden: Zustand ins Log. Den haengenden Ladebildschirm stoesst Srv.LoadingWatch an.
            Srv.NudgeAt = Srv.NudgeAt + CONTINUE_RETRY
            local GI = FindFirstOf("SD_GameInstance_C")
            local Persistent = FindFirstOf("PersistentLevel_C")
            Log("Laden haengt seit %d s: Ladebild=%s, Level GI=%s Persistent=%s, Figur=%s", Since(),
                tostring(A.VisibleWidget("LoadingScreenWidget_C")),
                A.IsAlive(GI) and A.Safe(function() return GI.CurrentLevel:ToString() end, "?") or "?",
                A.IsAlive(Persistent) and A.Safe(function() return Persistent.CurrentLevel:ToString() end, "?") or "?",
                tostring(Pawn ~= nil))
        elseif Since() > LOAD_GIVE_UP then
            Quit("Spielstand lud nicht (" .. LOAD_GIVE_UP .. " s)")
        end

    elseif Srv.State == "running" then
        local List = Guests(World)
        SetFps(#List > 0 and Srv.FpsCap() or Srv.Cfg.IdleFps)
        if Srv.Flag("server_fps_v2", true) then
            local okFG, errFG = pcall(Srv.FpsGuard, #List)
            if not okFG and not Srv.FpsGuardErr then Srv.FpsGuardErr = true Log("FPS-Waechter-Fehler: %s", tostring(errFG)) end
        end
        GuestSpawnTick(World)
        local okClean, errClean = pcall(CleanupTick, World)
        if not okClean and not Srv.CleanupErr then Srv.CleanupErr = true Log("Aufraeum-Fehler: %s", tostring(errClean)) end
        local okAdmin, errAdmin = pcall(AdminTick, World)
        if not okAdmin and not Srv.AdminErr then Srv.AdminErr = true Log("Admin-Fehler: %s", tostring(errAdmin)) end
        pcall(Srv.AdminQueueTick)   -- vorgemerkte Admin-Befehle aus dem Spiel (falls der Schnell-Loop sie nicht schon hatte)
        -- Vorgemerkte Gegenstaende vor die Fuesse (falls der Schnell-Loop sie nicht schon abgelegt hat)
        local okDrop, errDrop = pcall(Srv.DropTick)
        if not okDrop and not Srv.DropErr then Srv.DropErr = true Log("Ablage-Fehler: %s", tostring(errDrop)) end
        pcall(Srv.DropRepTick)   -- Fallengelassenes replizieren (falls der Schnell-Loop es nicht schon hatte)
        local okHeld, errHeld = pcall(Srv.DropHeldScan)   -- Closeout R2: wieder Getragenes aus dem Aufraeumen nehmen
        if not okHeld then Srv.Fail("srv_drop_heldscan", errHeld) end
        local okJ, errJ = pcall(Srv.Journal.Tick, World)
        if not okJ and not Srv.JournalErr then Srv.JournalErr = true Log("Gast-Journal-Fehler: %s", tostring(errJ)) end
        -- Fuer die Master-Liste (start.sh meldet den Server alle 30 s an): Spielerzahl und Version
        if os.time() >= (Srv.StatusAt or 0) then
            Srv.StatusAt = os.time() + 10
            Srv.WriteText(A.ModDir .. "status.txt", string.format("players=%d\nversion=%s\n", #List, VERSION))   -- CORE-23: atomar
        end
        if Srv.RefillCheckAt and os.time() >= Srv.RefillCheckAt then
            Srv.RefillCheckAt = nil
            local okRefill, errRefill = pcall(ApplyLootRefill, true)
            if not okRefill then Log("Kisten-Nachfuellen-Fehler: %s", tostring(errRefill)) end
        end
        if os.time() >= (Srv.PerfAt or 0) then
            Srv.PerfAt = os.time() + PERF_LOG_SECONDS
            local okPerf, errPerf = pcall(PerfLog, #List)
            if not okPerf then Log("Leistungs-Zeile-Fehler: %s", tostring(errPerf)) end
        end
        A.Settings.max_players = Srv.Cfg.MaxPlayers + 1   -- +1: die Server-Figur zaehlt mit
        A.RaiseMaxPlayers()
        local Pawn = OwnPawn()
        if Pawn then
            Srv.NoPawnSince = nil
            if os.time() >= Srv.GhostAt then
                Srv.GhostAt = os.time() + 5
                Ghost(Pawn, World)
            end
        else
            -- Sollte nie passieren (unverwundbar), sonst neu erscheinen lassen
            Srv.NoPawnSince = Srv.NoPawnSince or os.time()
            if os.time() - Srv.NoPawnSince > 10 then
                Srv.NoPawnSince = os.time()
                pcall(function()
                    local PC = A.LocalPC()
                    if A.IsAlive(PC) then PC:Svr_RequestRespawn_Random() end
                end)
                Log("Server-Figur fehlte, neu erscheinen lassen")
            end
        end
        if os.time() - (Srv.SavedAt or 0) >= Srv.Cfg.SaveMinutes * 60 then Srv.Save("Autosave") end
        local okE, errE = pcall(Srv.EmptySaveTick, #List)   -- X-CORE2
        if not okE then Log("Speichern bei leerem Server: Fehler %s", tostring(errE)) Srv.Fail("srv_empty_save", errE) end
        local okR, errR = pcall(Srv.RestartTick, World)      -- X-CORE1 (zuletzt: kann stop ausloesen)
        if not okR and not Srv.RestartErr then Srv.RestartErr = true Log("Neustart-Plan: Fehler %s", tostring(errR)) end

    elseif Srv.State == "stopping" then
        -- Warten, bis das Speichern fertig ist (mind. 3 s, hoechstens 30 s), dann beenden
        local StillBusy = Since() >= 3 and not Srv.QuitSent and Busy(World)   -- einmal lesen: Bedingung und Wahl gleich
        if Since() >= 3 and (not StillBusy or Since() > 30) and not Srv.QuitSent then
            Srv.QuitSent = true
            -- Gast-Inventare zur eben gespeicherten Welt festschreiben (sauberes Ende: Journal leer)
            if Srv.Journal.CommitAt and Srv.Journal.On() then
                if StillBusy and Srv.Journal.V2() then
                    -- CORE-4: EMS meldet das Welt-Speichern nach Ablauf NICHT fertig -> nicht festschreiben. Das Journal
                    -- (#F ohne #S) bleibt; der naechste Start (J.Rollback, Saved=false) setzt Gaeste/owners/Werte auf
                    -- die letzte Festschreibung, der Stand von jetzt bleibt als <Id>.crash
                    Log("Welt-Speichern nach %d s nicht fertig - Gast-Journal bleibt, naechster Start setzt auf den letzten Festschreibe-Stand", Since())
                else
                    -- ohne srv_journal_v2: alter Weg (Festschreiben auch nach Ablauf, ohne "#S")
                    local Fn = StillBusy and Srv.Journal.Commit or Srv.Journal.CommitNow
                    local okJ, errJ = pcall(Fn, true)
                    if not okJ then Log("Gast-Journal-Fehler beim Beenden: %s", tostring(errJ)) end
                end
            end
            -- Merker fuer start.sh: gewollt beendet (sonst wertet es das Ende als Absturz und startet neu).
            -- " busy": EMS speicherte nach 30 s noch (Quit mitten im Speichern, Slot.sav evtl. halb geschrieben) ->
            -- start.sh macht dann keine Startsicherung (`! grep -q busy`), damit keine gute Sicherung verdraengt wird;
            -- Exit-Code bleibt 0. StillBusy ist hier ein Block-Local aus diesem Zweig (keine neue Main-Chunk-Local).
            if not Srv.WriteText(A.ModDir .. "server_stopped.txt", os.date("%Y-%m-%d %H:%M:%S") .. (StillBusy and " busy" or "")) then
                Log("WARNUNG: server_stopped.txt nicht geschrieben")
            end
            Quit("stop")
        end
    end
end

-- Laufzeit fuer den Leistungs-Bericht (ls_core, Name server_tick, Warnung erst ab 20 ms); Fehler gehen
-- unveraendert an main.lua weiter
function Srv.Tick(World)
    local T0 = os.clock()
    local ok, err = pcall(Tick, World)
    local Core = package.loaded["ls_core"]
    if type(Core) == "table" and Core.PerfAdd then
        local T1 = os.clock()
        Core.PerfAdd("server_tick", T1 - T0, T1, 0.02)
    end
    if not ok then error(err, 0) end
end

local function Clamp(V, Lo, Hi) return math.max(Lo, math.min(Hi, V)) end

-- FPS-Drossel: Schafft der Server sein Ziel (LASTSIGNAL_FPS) nicht, laeuft er sonst unregelmaessig (mal 60, mal 35).
-- Gleichmaessig ist fluessiger: Alle 250 ms die echte Bildzeit messen, je 10 s mitteln. Liegt der Schnitt 30 s lang
-- unter 85 % der Grenze, eine Stufe runter (Ziel -> 45 -> 30 -> 20); mit 5 min Luft (>= 95 %) wieder hoch.
-- Ohne Spieler bleibt es bei IdleFps. Abstuerzen kann der Server dadurch nicht, er wird nur langsamer.
-- URSACHE "t.MaxFPS 30 mit Gaesten" (alter Weg, LASTSIGNAL_FPS=60): Mit Gaesten setzt Tick SetFps(Srv.FpsCap()) und
-- Srv.FpsCap() = Srv.Cap or Cfg.Fps. Srv.FpsSample misst ab dem Beitritt eines Gastes sofort, also mitten in der
-- Beitritts-/Ladespitze (Inventar, Spawn, ai2-Massenabgleich, Autosave): drei 10-s-Fenster unter 85 % (< 51) setzen
-- Srv.Cap auf 45, danach auf 30 (FPS_STEPS {45,30,20}). Zurueck nach oben braucht je Stufe 300 s ununterbrochen
-- >= 95 %, und jedes Fenster im Band 85-95 % setzt Srv.High zurueck - der Server bleibt bei 30. SetFps merkt sich
-- Srv.Fps, darum wird t.MaxFPS nie erneut gesetzt; A.RunCommand loggt "Befehl: t.MaxFPS 30".
-- server_fps_v2: 45 s Schonfrist nach Gast-/Ziel-/Zustandswechsel, Untergrenze LASTSIGNAL_FPS_MIN (45), Stufen
-- {50,45,40,30,20} ab Untergrenze, Erholung nach 60 s (summiert, >= 90 %) direkt aufs Ziel (verdoppelt sich bis 600 s,
-- wenn er binnen 10 min wieder einbricht), alle 30 s t.MaxFPS pruefen und still neu setzen. LASTSIGNAL_FPS_AUTO=0: festes Ziel.
local FPS_STEPS = { 45, 30, 20 }
local FPS_STEPS_V2 = { 50, 45, 40, 30, 20 }
Srv.FpsWin = { Sum = 0, N = 0, At = 0 }
function Srv.FpsCap() return Srv.Cap or Srv.Cfg.Fps end

local function FpsLevels(V2)
    local L = { Srv.Cfg.Fps }
    for _, F in ipairs(V2 and FPS_STEPS_V2 or FPS_STEPS) do
        if F < Srv.Cfg.Fps and (not V2 or F >= (Srv.Cfg.FpsMin or 0)) then L[#L + 1] = F end
    end
    return L
end

-- server_fps_v2, jede Sekunde aus Tick ("running"): Gastzahl-Wechsel -> Schonfrist; alle 30 s t.MaxFPS pruefen
function Srv.FpsGuard(NGuests)
    local Now = os.time()
    if Srv.LastGuestN ~= NGuests then
        Srv.LastGuestN = NGuests
        Srv.FpsGraceUntil = Now + Srv.FpsGraceS
        Srv.FpsWin = { Sum = 0, N = 0, At = 0 }
    end
    if not Srv.Fps or Now < (Srv.FpsCheckAt or 0) then return end
    Srv.FpsCheckAt = Now + 30
    local KSL = A.Safe(function() return A.UEHelpers.GetKismetSystemLibrary() end)
    if not A.IsAlive(KSL) then return end
    local V = A.Safe(function() return KSL:GetConsoleVariableFloatValue("t.MaxFPS") end)
    if type(V) == "number" and math.abs(V - Srv.Fps) <= 0.5 then return end
    local Target = Srv.Fps
    pcall(function() KSL:ExecuteConsoleCommand(A.CurrentWorld(), "t.MaxFPS " .. Target, A.LocalPC()) end)
    if type(V) == "number" and Srv.FpsFixLogged ~= V then
        Srv.FpsFixLogged = V
        Log("t.MaxFPS stand auf %s statt %d - neu gesetzt", string.format("%.0f", V), Target)
    end
end

-- server_fps_v2: Bewertung eines fertigen 10-s-Fensters
local function FpsJudgeV2(Avg, Cap)
    if not Srv.Cfg.FpsAuto then Srv.Cap, Srv.Low, Srv.High = nil, 0, 0 return end
    local Now = os.time()
    if Avg < Cap * 0.85 then
        Srv.Low, Srv.High = (Srv.Low or 0) + 10, 0
        if Srv.Low < 30 then return end
        Srv.Low = 0
        for _, F in ipairs(FpsLevels(true)) do
            if F < Cap then
                Srv.Cap = F
                if Srv.RecoveredAt and Now - Srv.RecoveredAt < 600 then Srv.RecoverS = math.min(600, (Srv.RecoverS or 60) * 2) end
                Log("WARNUNG: Server schafft %d FPS nicht (Schnitt %.0f) - Ziel jetzt %d (Untergrenze %d)", Cap, Avg, F,
                    Srv.Cfg.FpsMin)
                return
            end
        end
    elseif Avg >= Cap * 0.90 and Cap < Srv.Cfg.Fps then
        Srv.High, Srv.Low = (Srv.High or 0) + 10, 0
        if Srv.High >= (Srv.RecoverS or 60) then
            Srv.Cap, Srv.High, Srv.RecoveredAt = nil, 0, Now
            Log("Server hat wieder Luft (Schnitt %.0f) - FPS-Ziel wieder %d", Avg, Srv.Cfg.Fps)
        end
    else
        Srv.Low = 0   -- neutrales Fenster: Erholung zaehlt weiter (kein High-Reset)
    end
end

function Srv.FpsSample()
    if Srv.State ~= "running" or Srv.Fps == Srv.Cfg.IdleFps then Srv.FpsWin, Srv.Low, Srv.High = { Sum = 0, N = 0, At = 0 }, 0, 0 return end
    local V2 = Srv.Flag("server_fps_v2", true)
    if V2 and os.time() < (Srv.FpsGraceUntil or 0) then Srv.FpsWin = { Sum = 0, N = 0, At = 0 } return end
    local World = A.CurrentWorld()
    local Statics = A.UEHelpers.GetGameplayStatics()
    local Delta = Statics:GetWorldDeltaSeconds(World)
    local Dilation = A.Safe(function() return Statics:GetGlobalTimeDilation(World) end, 1)
    if not Delta or Delta <= 0 or not Dilation or Dilation <= 0 then return end
    local W, Now = Srv.FpsWin, os.time()
    if W.At == 0 then W.At = Now end
    W.Sum, W.N = W.Sum + Dilation / Delta, W.N + 1
    if Now - W.At < 10 or W.N == 0 then return end
    local Avg, Cap = W.Sum / W.N, Srv.FpsCap()
    Srv.FpsWin = { Sum = 0, N = 0, At = Now }
    Srv.AvgFps = Avg
    if V2 then FpsJudgeV2(Avg, Cap) return end
    local Levels = FpsLevels(false)
    if Avg < Cap * 0.85 then
        Srv.Low, Srv.High = (Srv.Low or 0) + 10, 0
        if Srv.Low >= 30 then
            for _, F in ipairs(Levels) do
                if F < Cap then
                    Srv.Cap, Srv.Low = F, 0
                    Log("WARNUNG: Server schafft %d FPS nicht (Schnitt %.0f) - jetzt %d FPS", Cap, Avg, F)
                    break
                end
            end
        end
    elseif Avg >= Cap * 0.95 and Cap < Srv.Cfg.Fps then
        Srv.High, Srv.Low = (Srv.High or 0) + 10, 0
        if Srv.High >= 300 then
            for I = #Levels, 1, -1 do
                if Levels[I] > Cap then
                    Srv.Cap, Srv.High = Levels[I] < Srv.Cfg.Fps and Levels[I] or nil, 0
                    Log("Server hat wieder Luft (Schnitt %.0f) - jetzt %d FPS", Avg, Levels[I])
                    break
                end
            end
        end
    else
        Srv.Low, Srv.High = 0, 0
    end
end
local function IsTrue(V) V = tostring(V or ""):lower() return V == "1" or V == "true" or V == "yes" or V == "on" end

-- A: Funktionen und Tabellen aus main.lua. Gibt nil zurueck, wenn der Server-Modus aus ist.
function Srv.Init(Api)
    if Env("SERVER", "0") ~= "1" then return nil end
    A = Api
    Srv.Cfg = {
        Name = Env("NAME", "Last Signal Server"),
        Port = tonumber(Env("PORT", "7777")) or 7777,
        MaxPlayers = Clamp(tonumber(Env("MAX_PLAYERS", "8")) or 8, 1, 64),
        SaveMinutes = Clamp(tonumber(Env("SAVE_MINUTES", "5")) or 5, 1, 60),
        Fps = Clamp(tonumber(Env("FPS", "60")) or 60, 20, 120),   -- Ziel; bei Ueberlast regelt FpsTick selbst herunter
        Password = Env("PASSWORD", nil),        -- leer = offen; nie ins Log oder an die Master-Liste
        Motd = Env("MOTD", nil),                -- Willkommens-Text im Chat beim Beitritt
        Description = Env("DESCRIPTION", nil),  -- Text in der Serverliste (schickt start.sh an die Master-Liste)
        IdleFps = 5,
        Slot = Env("SAVE_SLOT", nil),   -- leer = zuletzt gespielter Spielstand
        CorpseMinutes = tonumber(Env("CORPSE_MINUTES", "60")) or 60,       -- 0 = Leichen bleiben liegen
        DeathboxMinutes = tonumber(Env("DEATHBOX_MINUTES", "60")) or 60,   -- 0 = Todes-Kisten bleiben
        LootRefill = IsTrue(Env("LOOT_REFILL", "1")),                      -- Kisten fuellen sich wieder auf
        LootRefillMin = Clamp(tonumber(Env("LOOT_REFILL_MIN", "30")) or 30, 1, 10080),   -- nach so vielen Minuten
    }
    -- server_fps_v2: Untergrenze der Drossel und Automatik (aus = festes Ziel LASTSIGNAL_FPS)
    Srv.Cfg.FpsMin = Clamp(tonumber(Env("FPS_MIN", "45")) or 45, 20, Srv.Cfg.Fps)
    Srv.Cfg.FpsMinCfg = Srv.Cfg.FpsMin   -- CORE-11: eingestellte Untergrenze (Konsole "fps" senkt sie nur voruebergehend)
    Srv.Cfg.FpsAuto = IsTrue(Env("FPS_AUTO", "1")) and Srv.Flag("server_fps_auto", true) and true or false
    Srv.RecoverS = 60
    -- CORE-5: Abstand der Sicherungs-Anforderungen an start.sh (Minuten, 0 = nur die Sicherung beim Start)
    Srv.Cfg.BackupMinutes = Clamp(tonumber(Env("BACKUP_MINUTES", "30")) or 30, 0, 10080)
    Srv.BackupAt = os.time() + 60 * Srv.Cfg.BackupMinutes   -- start.sh hat eben vor dem Spielstart gesichert
    -- CORE-26: optionales Admin-Passwort (leer = wie bisher: Admin = Mitspieler-ID). Nie ins Log.
    Srv.Cfg.AdminPassword = Env("ADMIN_PASSWORD", nil)
    -- Vergleichsform wie der Gast-Chat sie schickt ("|"/Steuerzeichen -> Leerzeichen, Raender weg). Roh bleibt fuer
    -- an/aus (leer bereinigt: bleibt an, /admin gelingt nie - sicher zu). Nie den Wert loggen.
    Srv.Cfg.AdminPasswordCmp = nil
    if Srv.Cfg.AdminPassword then
        Srv.Cfg.AdminPasswordCmp = tostring(Srv.Cfg.AdminPassword):gsub("[%c|]", " "):match("^%s*(.-)%s*$")
        if Srv.Cfg.AdminPasswordCmp ~= Srv.Cfg.AdminPassword or Srv.Cfg.AdminPasswordCmp == "" then
            Log("Admin-Passwort enthaelt | oder Steuerzeichen/Randleerzeichen - im Chat gilt die bereinigte Form%s",
                Srv.Cfg.AdminPasswordCmp == "" and " (leer: /admin gelingt nie, Admins haben keine Rechte)" or "")
        end
    end
    -- X-CORE1: taeglicher Neustart (LASTSIGNAL_RESTART_AT=HH:MM, Uhrzeit des Servers/Containers, oft UTC)
    local RestartText = Env("RESTART_AT", nil)
    if RestartText then
        local RH, RM = tostring(RestartText):match("^%s*(%d%d?):(%d%d)%s*$")
        if RH and tonumber(RH) < 24 and tonumber(RM) < 60 then
            Srv.Cfg.RestartAt = { H = tonumber(RH), M = tonumber(RM) }
            local okD, errD = pcall(Srv.ArmDaily, os.time() + 3600)
            if not okD then Log("Taeglicher Neustart: Fehler %s", tostring(errD)) end
        else
            Log("LASTSIGNAL_RESTART_AT '%s' ungueltig (HH:MM erwartet) - kein taeglicher Neustart", tostring(RestartText):sub(1, 20))
        end
    end
    -- CORE-9: Befehle, die der letzte Lauf schon umbenannt, aber nicht mehr ausgefuehrt hat, verwerfen (wie start.sh
    -- server_cmd.txt beim Start loescht): ein altes "shutdown" beendete den Server sonst gleich wieder
    local OldCmd = io.open(A.ModDir .. "server_cmd.work", "r")
    if OldCmd then
        local OldText = OldCmd:read("*a")
        OldCmd:close()
        os.remove(A.ModDir .. "server_cmd.work")
        if OldText and not OldText:match("^%s*$") then Log("Alte Konsolenbefehle vom letzten Lauf verworfen (server_cmd.work)") end
    end
    A.Settings.local_inventory = IsTrue(Env("LOCAL_INVENTORY", "0"))
    -- Absturz im letzten Lauf: Gast-Inventare auf den Stand des letzten Welt-Speicherns (nur Dateien)
    local okJ, errJ = pcall(Srv.Journal.Rollback)
    if not okJ then Log("Gast-Journal-Fehler beim Start: %s", tostring(errJ)) end
    A.Settings.save_before_join, A.Settings.save_back = false, false
    A.Settings.server = Srv   -- fuer main.lua-Stellen vor der Coop-Tabelle (Spawnpunkt, Fall-Rettung)
    -- Admins: Mitspieler-IDs (Komma, Semikolon oder Leerzeichen getrennt), Befehle aus dem Spiel, Bann-Liste.
    -- CORE-26: Eintraege "steam:<id>" -> dann braucht ein Admin ID UND passende (vom Spiel gemeldete) Steam-ID
    for Token in (Env("ADMINS", "") or ""):gmatch("[^%s,;]+") do
        local Steam = Token:match("^[sS][tT][eE][aA][mM]:(%d+)$")
        if Steam then Srv.AdminSteam[Steam] = true
        elseif Token:match("^%x+$") then Srv.Admins[Token:lower()] = true end
    end
    A.Coop.OnAdminCommand = Srv.AdminCommand
    A.Coop.OnChat = Srv.Chat
    A.Coop.OnPendingAdd = Srv.PendingAdd
    A.Coop.OnAuth = Srv.OnAuth
    A.Coop.OnConsumed = Srv.OnConsumed   -- consume_fix (prueft den Schalter selbst)
    LoadBans()
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(Srv.FpsSample)
        if not ok and not Srv.FpsErr then Srv.FpsErr = true Log("FPS-Messung-Fehler: %s", tostring(err)) end
    end)
    Log("Server-Modus AN: '%s', Port %d, max. %d Spieler, Inventar %s, Leichen %s", Srv.Cfg.Name, Srv.Cfg.Port,
        Srv.Cfg.MaxPlayers, A.Settings.local_inventory and "lokal (mitgebracht)" or "auf dem Server",
        Srv.Cfg.CorpseMinutes > 0 and ("verschwinden nach " .. Srv.Cfg.CorpseMinutes .. " min") or "bleiben liegen")
    Log("Todes-Kisten %s", Srv.Cfg.DeathboxMinutes > 0 and ("verschwinden nach " .. Srv.Cfg.DeathboxMinutes .. " min") or "bleiben liegen")
    Log("Passwort %s, Willkommens-Text %s, FPS-Ziel %d (Untergrenze %d, Automatik %s)", Srv.Cfg.Password and "an" or "aus",
        Srv.Cfg.Motd and "an" or "aus", Srv.Cfg.Fps, Srv.Cfg.FpsMin, Srv.Cfg.FpsAuto and "an" or "aus")
    Log("Admin-Passwort %s, Admin-Steam-IDs %s, Sicherungs-Anforderung %s", Srv.Cfg.AdminPassword and "an (/admin)" or "aus",
        next(Srv.AdminSteam) and "Pflicht" or "aus",
        Srv.Cfg.BackupMinutes > 0 and ("alle " .. Srv.Cfg.BackupMinutes .. " min") or "aus (nur beim Start)")
    return Srv
end

return Srv
