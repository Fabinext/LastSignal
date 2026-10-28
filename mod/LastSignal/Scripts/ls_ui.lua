-- Last Signal, Runde 5 (WP13): UI v2 - Hinweise, Menues, Schwierigkeit, Karte, Munition, Musik, Treffer.
-- Decode und Entscheidungen: _NetTest\analysis\findings\ui.md. Vertrag: _NetTest\analysis\API.md.
--   Host:  Proxy-HUD je Gast (PC.MyHUD) faengt die Toasts der Spiel-Logik auf -> note2 an genau diesen Gast;
--          Toasts beim Geist (ohne Besitzer) -> an alle. CVars (ui_cvar), Kampfstatus (ui_cmb), Respawnpunkt (ui_rsp).
--   Gast:  note2 anzeigen (Dedupe), Pausenmenue/Respawn-Bildschirm aufraeumen, CVars des Hosts (Original zurueck beim
--          Verlassen, Permadeath immer aus), Karte 10 Hz, eigene Marker + Mitspieler-Marker, Munitionsanzeige 10 Hz,
--          Kampfmusik, Hitmarker (ui_hit), Tage-Banner, Speichern gesperrt (Patch), HUD-Widgets (Lebensbalken/Hinweise)
--          nach dem Tod wieder ins Bild (ui_hudre).
-- Keine Hooks auf haeufigen Funktionen. Hooks (Pre, nur Tabelle): Karten-Doppelklick (CreatePlayerMarker, 5.3: Create Checkpoint Marker, Gast);
-- Runde 8 (ui_note_pawn, Host): BP_PlayerCharacter_C:CreateNotificationUI fuer Gast-Figuren -> note2.
-- Runde 7 (Clans): Mitspieler-Marker nur fuer Clan-Mitglieder (ui_mates_clan), Clan-Wegpunkte (ui_clanwp:
--   Gast -> Host Keyed-State ui_cwm "m" = eigene Marker dieser Karte; Host -> Gast Keyed-State ui_cwp <Alias w<n>> =
--   Marker der Clan-Mitglieder; Runde 9 ui_cwp_alias: nie die Gast-ID als Schluessel), Clan-Chat (clan_msg ->
--   Chatfenster bzw. Hinweis, ui_clanmsg).
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local A                     -- Coop.API (Init)

local P = {
    GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
    HUD = "/Game/Blueprints/HUD_Game.HUD_Game_C",
    CU = "/Script/AutoSettings.Default__ConsoleUtils",
    -- UE 5.6: Schadenszahl = GameFunctionLibrary_C.SpawnDamageNumbers(Dmg, Color, ImpactPoint, __WorldContext)
    -- (BFL_AI_C entfernt; Aufrufer z.B. BP_FirearmPickup_C Client_HitUI @2104). BFL_AI nur Rueckfall fuer UE 5.3.
    DMG_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:SpawnDamageNumbers",
    BFL_AI = "/Game/AI/BFL_AI.Default__BFL_AI_C",
    MARKER = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_Marker.BP_Marker_C",
    PMARKER = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_PlayerMarker.BP_PlayerMarker_C",
    MATE_TEX = "/Game/Blueprints/MinimapSystem/Texture/T_Player.T_Player",
    WP_TEX = "/Game/Blueprints/MinimapSystem/Texture/T_Marker.T_Marker",
    WP_MAX = 20,        -- Clan-Wegpunkte je Spieler
    WP_OWNERS = 64,     -- Host: Spieler mit Wegpunkten (Speicher begrenzen)
    WP_OFFLINE = 1800,  -- Host (CORE-30): Besitzer so lange (s) nicht verbunden -> Eintrag vergessen, Platz frei
    WP_SHOWN = 80,      -- Gast: hoechstens so viele fremde Wegpunkte gleichzeitig
    -- UE 5.6: "Create Checkpoint Marker" heisst CreatePlayerMarker (gleicher Ablauf: Marker Location -> Svr_SpawnPlayerMarker,
    -- EVT @3ce; Aufrufer MapWidget_C AddPlayerMarker @0faa). MARK_FN53 = Rueckfall fuer UE 5.3.
    MARK_FN = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:CreatePlayerMarker",
    MARK_FN53 = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:Create Checkpoint Marker",
    CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
    CTRL = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C",
    -- cheat_gate (UE 5.6, analysis56\bp\BP_PlayerCharacter_C.kdis): Tasten-Stub des Cheat-Menues, SCRIPT 90. @0000-@0047
    -- LetValueOnPersistentFrame x4 (Parameter), @0048 LocalFinalFunction ExecuteUbergraph (Einsprung 61301 = @ef75)
    DBG_EVT = "InpActEvt_IA_DebugMenu_K2Node_EnhancedInputActionEvent_0",
    DBG_OFF = 72,
    -- Felder von S_NotificationDetails (NotficationUI_C.NotificationDetailsStruct; Namen in UE 5.6 unveraendert,
    -- vgl. GameFunctionLibrary_C.CreateNotificationUI @009b..0123)
    MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE",
    ICON = "Icon_10_3D6D915A4220ED87F516EA92332632BD",
    COL = "IconColour_13_F2E791E94998CDA8212B52A98C4B91AA",
    DELAY = "Delay_16_92B008734D6D9C153C318E97E966427A",
    FORCE = "ForceNotification?_18_94622F304577F736C01BB49B778633DA",
    BACKUP = "ui_cvar_backup.txt",
    MARKS = "ui_marks.txt",
    COLLAPSED = 1,
    -- UE 5.6 HUD_Game_C: nur einmal angelegt von ReceiveBeginPlay(+2 s)/Re-Initialise @0087 (Feld, ZOrder wie AddToViewport dort)
    HUD_RE = { { "EnemyHealthBarUI", 1 }, { "NotificationUI", 999 } },
}

-- CVars der Spielregeln (aus dem Decode: GetBoolCVar/GetFloatCVar in BPs). Nicht synchron: Difficulty.Allow,
-- Difficulty.Permadeath (beim Gast immer 0) und Difficulty.MultiHit (gehoert ls_combat).
-- UE 5.6 (analysis56/pseudo): AIRespawnTimer -> RespawnTimer, BatteryMultiplier -> BatteryDepletionMultiplier, neu u.a.
-- Infektion, Airdrop-Zeiten, MapVisibility, Grenadier/Screamer/Hound, Military-/HigherTier-Loot.
local CVARS = {
    b = { "Airdrop", "ArmorDurability", "BlockBuildingPOI", "DisableBackpackInBackpack", "DisableBiteAnimation",
        "FirearmMalfunction", "FishingRodDurability", "HeadshotMode", "InfectionEnabled", "KeepInventory",
        "LootDegredation", "LoseAllItemsOnDeath", "MapVisibility", "MeleeDmgDegradation", "MuzzleAttachmentDurability",
        "OtherItemsDurability", "PrimaryInfestations", "RandomEventMarker", "RandomInfestations", "Refill",
        "ResetPassiveSkills", "RespawnPOIBosses", "ScalingEnabled", "TraderCurrencyAmount", "WeaponDurability" },
    f = { "AnimalAmount", "ArchetypeAcidic", "ArchetypeArmoredHound", "ArchetypeGrenadier", "ArchetypeScreamer",
        "ArchetypeSprinter", "ArchetypeToughenedCrawler", "ArchetypeUltraRadiated", "ArmorDurabilityMultiplier",
        "BanditHealth", "BanditsCampMultiplier", "BatteryDepletionMultiplier", "BiteInfectionChance", "ChanceOfAirdrop",
        "DamageMultiplier", "DayLength", "FishingRodDurabilityMultiplier", "FuelMultiplier", "HungerMultiplier",
        "InfectionTimer", "InfestationsHealth", "MaximumTimeAirdrop", "MilitaryCampMultiplier", "MilitaryHealth",
        "MinimumTimeAirdrop", "MuzzleAttachmentDurabilityMultiplier", "NightBrightness", "NightLength",
        "OtherItemsDurabilityMultiplier", "RadFilterDepletionMultiplier", "RadSeverityLvl1", "RadSeverityLvl2",
        "RadSeverityLvl3", "RandomEventMultiplier", "RandomInfestationsMultiplier", "RefillTime", "RegenMultiplier",
        "RespawnTimer", "ScalingDamage", "ScalingHealth", "ScavengerHealth", "ScavengersCampMultiplier", "SearchTime",
        "StaminaMultiplier", "StaminaRecoveryMultiplier", "ThirstMultiplier", "TraderCurrencyAmountMultiplier",
        "VehicleChance", "WeaponDurabilityMultiplier", "XPMultiplier", "ZombieAmount", "ZombieBossAmount",
        "ZombieDamage", "ZombieHealth", "ZombieHoundAmount", "ZombieSpeed" },
    loot = { "Ammo", "Attachments", "Clothing", "Crafting", "Equipment", "Food&Drink", "General", "HigherTierMelee",
        "HigherTierRanged", "Keycards", "LegendaryAttachments", "LegendaryGear", "LegendaryWeapons", "Medical", "Melee",
        "MilitaryAmmo", "MilitaryClothing", "MilitaryEquipment", "Ranged" },
}

-- Passive Skills: Feld Current<F>Level (Toughess = Schreibweise des Spiels), N = Anzeigename
local SKILLS = {
    { F = "FirstAid", N = "First Aid" }, { F = "Fishing", N = "Fishing" }, { F = "Fitness", N = "Fitness" },
    { F = "Marksmanship", N = "Marksmanship" }, { F = "Reloading", N = "Reloading" },
    { F = "Scavenging", N = "Scavenging" }, { F = "Sneaking", N = "Sneaking" }, { F = "Strength", N = "Strength" },
    { F = "Thief", N = "Thief" }, { F = "Toughess", N = "Toughness" },
}

-- Laufzeit-Zustand (keine UObjects ueber Ticks: nur Namen/Pfade/Zahlen)
local U = {
    NoteQ = {}, NoteSeen = {}, HostSeen = {}, HitQ = {},
    CvOrig = {}, CvDirty = false, CvSent = {}, CvAt = 0, BackupChecked = false,
    Cmb = nil, CmbLast = nil, CmbAt = 0, AudioName = nil, AudioFindAt = 0,
    Rsp = nil, RespFindAt = 0,
    Patch = {}, PatchWarn = false,
    MarkReq = {}, MarkHook = nil, Marks = nil, MarkObjs = {}, MarkGen = nil, PMFindAt = 0, MarkLogged = {},
    Mates = {}, MatesGen = nil, MatesOwner = nil, ClanSig = nil,
    CwpHost = {}, CwpHostN = 0, CwpAt = 0,              -- Host: [gid] = { N = Name, V = "x,y,z/...", LastAt }
    CwpAlias = {}, CwpAliasN = 0, CwpAliasOn = nil,     -- Host: [gid] = "w<n>" (ui_cwp_alias), zuletzt benutzte Art
    CwpIn = {}, CwpShown = {}, CwpGen = nil, CwpOwner = nil, -- Gast: [gid] = Wert / { V, Paths }
    ClanQ = {},
    PawnQ = {}, PawnHook = nil, PawnHookAt = -100, PawnOn = false,   -- Host: CreateNotificationUI an Gast-Figuren
    Lvl = {}, LvlGen = nil, Day = nil, DayGen = nil,
    Logged = {}, Gen = nil,
}

local F = {}

local function Log(fmt, ...) A.Log("[UI] " .. fmt, ...) end

-- Einmal-Log je Schluessel
local function Once(Key, fmt, ...)
    if U.Logged[Key] then return end
    U.Logged[Key] = true
    Log(fmt, ...)
end

-- Feature an? (Hauptschalter ui_v2 und Einzelschalter)
function F.On(Name)
    return Core.Flag("ui_v2", true) and Core.Flag(Name, true) and true or false
end

-- Feature-Fehler zaehlen (Autofallback: > 3 in 60 s -> FLAG_DOWN)
function F.Run(Flag, Fn, ...)
    local ok, err = pcall(Fn, ...)
    if not ok then Core.Fail(Flag, err) end
    return ok
end

function F.Alive(Obj) return Obj ~= nil and A.IsAlive(Obj) end

function F.Loading()
    local W = A.WorldGen
    return W and W.Loading and os.clock() - (W.LoadingAt or 0) < 60
end

function F.Gen() return A.WorldGen and A.WorldGen.N or 0 end

function F.Obj(Path)
    local Obj = StaticFindObject(Path)
    if F.Alive(Obj) then return Obj end
    return nil
end

-- CORE-31: gemeinsame, kurz gemerkte Suche (main.lua Coop.Scan, E30) wenn vorhanden, sonst FindAllOf.
-- Die Eintraege erst bei der Benutzung pruefen (F.Alive).
function F.Scan(Class)
    local S = A.Coop.Scan
    if type(S) == "function" then
        local ok, L = pcall(S, Class, 0.25)
        if ok and type(L) == "table" then return L end
    end
    return FindAllOf(Class) or {}
end

-- "Klasse /Pfad/Objekt.Objekt" -> "/Pfad/Objekt.Objekt"
function F.PathOf(Obj)
    local Full = A.Safe(function() return Obj:GetFullName() end, "") or ""
    return Full:match("^%S+%s+(.+)$") or Full
end

function F.ClientReady()
    return Net.Side == "client" and Net.Host ~= nil and Net.Host.Ready == true and not F.Loading()
end

function F.CU() return F.Obj(P.CU) end

function F.Map()
    local World = A.Safe(A.CurrentWorld)   -- CORE-20: Welt erst pruefen
    if not F.Alive(World) then return "?" end
    local Path = A.Safe(function() return A.MapPath(World) end)
    if not Path or Path == "" then return "?" end
    return (tostring(Path):gsub("|", "_"))
end

-- ---------------------------------------------------------------- Patch-Registry (ret_early, nur Gast)

-- Zeile fuer netcore_patch.txt: Event-/Funktions-Stub beginnt mit EX_LocalFinalFunction (0x46) + UFunction* des
-- Ubergraphs -> erwartet "46" + niedrigstes Adressbyte. Passt es nicht, aendert die DLL nichts.
-- Off (Stub mit Parametern, z. B. Eingabe-Events): dieselben Bytes als Typ "bytes" am Ubergraph-Aufruf bei Off
-- (davor nur LetValueOnPersistentFrame; ret_early geht nur bei Offset 0, dort steht ein FProperty-Zeiger).
function F.Patch(Name, FnPath, UbPath, On, Off)
    if (U.Patch[Name] or false) == On then return end
    -- Registry: Coop.SetPatch oder Coop.ClientPatches (Core.SetPatch nimmt, was main.lua anbietet)
    if not Core.HasPatchRegistry() then
        if not U.PatchWarn then U.PatchWarn = true Log("Patch-Registry fehlt (Coop.SetPatch/ClientPatches), %s nur mit Rueckfall", Name) end
        return
    end
    local Fn, Ub = F.Obj(FnPath), F.Obj(UbPath)
    if not (Fn and Ub) then return end
    local Line = string.format("%s ret_early %x 0 46%02X 040B %d", Name, Fn:GetAddress(), Ub:GetAddress() % 256,
        On and 1 or 0)
    if Off then
        Line = string.format("%s bytes %x %d 46%02X 040B %d", Name, Fn:GetAddress(), Off, Ub:GetAddress() % 256,
            On and 1 or 0)
    end
    if Core.SetPatch(Name, Line) then
        U.Patch[Name] = On
        Log("Patch %s %s angefordert", Name, On and "an" or "aus")
    end
end

function F.Patches(Client)
    F.Patch("ui_savelock", P.CTRL .. ":SaveGameToSlot", P.CTRL .. ":ExecuteUbergraph_BP_PlayerController",
        Client and F.On("ui_savelock"))
    F.Patch("ui_checkcombat", P.CHAR .. ":CheckCombat", P.CHAR .. ":ExecuteUbergraph_BP_PlayerCharacter",
        Client and F.On("ui_music") and F.On("ui_music_patch"))
end

-- ---------------------------------------------------------------- Cheat-Menue nur fuer Admins (cheat_gate)

-- Admin-Rechte auf diesem Server (main.lua Coop.List.IsAdmin, Antwort des Hosts; bis dahin: kein Admin)
function F.IsAdmin()
    local L = A.Coop.List
    return type(L) == "table" and L.IsAdmin == true
end

-- cheat_gate (PLAYER-10, 1 s): main.lua Coop.Cheat.Tick setzt Debug.Allow nur beim Wechsel des Admin-Status und
-- schliesst das Menue 1x/s. Wer Debug.Allow per Konsole wieder einschaltet, oeffnet es trotzdem (InpActEvt_IA_DebugMenu
-- @ef75 prueft nur die CVar). Hier fuer Nicht-Admins: CVar jede Sekunde zurueck auf 0, Tasten-Stub per Patch stumm
-- (@0048 Ubergraph-Aufruf -> 04 0B = Return), offenes Menue 10x/s zu (F.CheatClose). Nur Gast; Admin/Host/Solo: Patch aus.
function F.CheatGate(Client)
    local On = Client and F.On("cheat_gate") and not F.IsAdmin()
    F.Patch("cheat_gate", P.CHAR .. ":" .. P.DBG_EVT, P.CHAR .. ":ExecuteUbergraph_BP_PlayerCharacter", On, P.DBG_OFF)
    if not On then return end
    -- Den eigenen Wert von Debug.Allow merkt main.lua (Coop.Cheat.Allow) im ersten Server-Takt und setzt ihn beim
    -- Verlassen zurueck: vorher nichts setzen, sonst kaeme danach 0 statt des eigenen Werts zurueck (Einzelspieler)
    local Ch = A.Coop.Cheat
    if type(Ch) == "table" and Ch.Allow == nil then return end
    local KSL = A.UEHelpers.GetKismetSystemLibrary()
    if not F.Alive(KSL) then return end
    if A.Safe(function() return KSL:GetConsoleVariableBoolValue("Debug.Allow") end, false) == true then
        A.RunCommand("Debug.Allow 0")
        local Now = os.clock()
        if Now - (U.CheatLogAt or -99) > 30 then
            U.CheatLogAt = Now
            Log("Debug.Allow war an (kein Admin): wieder aus (cheat_gate)")
        end
    end
end

-- cheat_gate (10 Hz, Gast ohne Admin-Rechte): offenes Cheat-Menue sofort schliessen (Spielfunktion CloseDebugMenu)
function F.CheatClose(Pawn, Now)
    local Menu = Pawn.DebugMenu
    if not F.Alive(Menu) then return end
    Pawn:CloseDebugMenu()
    if Now - (U.CheatCloseAt or -99) > 10 then
        U.CheatCloseAt = Now
        Log("Cheat-Menue geschlossen: nur fuer Admins (cheat_gate)")
    end
end

-- ---------------------------------------------------------------- Hinweise (note2)

function F.NoteBox(Hud)
    local NP = Hud and Hud.NotificationUI
    if not F.Alive(NP) then return nil end
    local Box = NP.VerticalBox_31
    return F.Alive(Box) and Box or nil
end

-- Ist ein Hinweis mit diesem Text (bzw. Match(Text) wahr) gerade im eigenen HUD sichtbar?
function F.NoteVisible(Text, Match)
    local PC = A.LocalPC()
    local Hud = F.Alive(PC) and A.Safe(function() return PC.MyHUD end) or nil
    local Box = F.Alive(Hud) and F.NoteBox(Hud)
    if not Box then return false end
    local N = A.Safe(function() return Box:GetChildrenCount() end, 0) or 0
    for i = 0, math.min(N, 12) - 1 do
        local Child = A.Safe(function() return Box:GetChildAt(i) end)
        local T = F.Alive(Child) and A.Safe(function() return Child.NotificationDetailsStruct[P.MSG]:ToString() end) or nil
        if T and (T == Text or (Match and Match(T))) then return true end
    end
    return false
end

-- Hinweis beim Gast zeigen (Spielfunktion, Spieler 0 = eigener PC)
function F.ShowNote(Text, IconPath, R, G, B, Al, Delay, Force)
    local PC = A.LocalPC()
    if not F.Alive(PC) or F.NoteVisible(Text) then return end
    local Icon = nil
    if IconPath and IconPath ~= "" then
        Icon = F.Obj(IconPath)
        if not Icon and IconPath:sub(1, 6) == "/Game/" then Icon = A.Safe(function() return LoadAsset(IconPath) end) end
        if not F.Alive(Icon) then Icon = nil end
    end
    local Lib = F.Obj(P.GFL)
    if not Lib then return end
    Lib:CreateNotificationUI(FText(Text), Icon, { R = R, G = G, B = B, A = Al }, Delay, Force, PC)
end

function F.EncNote(Text, IconPath, R, G, B, Al, Delay, Force)
    return table.concat({ Net.Enc(Text), Net.Enc(IconPath or ""),
        string.format("%.3f,%.3f,%.3f,%.3f", R or 1, G or 1, B or 1, Al or 1),
        string.format("%.2f", Delay or 2), Force and "1" or "0" }, "|")
end

-- Host: Hinweis an Ziel ("all" oder Gast), nicht erzwungene gleiche Texte hoechstens alle 2 s je Ziel
function F.SendNote(Target, Data, Text, Force, Now)
    local function One(G)
        if not (G.Epoch and Net.Has("ui_note2", G)) then return end
        local Seen = U.HostSeen[G.Key] or {}
        U.HostSeen[G.Key] = Seen
        if not Force and Seen[Text] and Now - Seen[Text] < 2 then return end
        Seen[Text] = Now
        Net.Send("note2", Data, G, 0)
    end
    if Target == "all" then Net.ForEachGuest(One) else One(Target) end
end

-- Host: Kinder des NotificationUI eines HUDs lesen, entfernen und weitergeben (hoechstens 6 je Durchlauf)
function F.Drain(Hud, Target, Now)
    local Box = F.NoteBox(Hud)
    if not Box then return end
    local N = A.Safe(function() return Box:GetChildrenCount() end, 0) or 0
    if N <= 0 then return end
    local Items = {}
    for i = 0, math.min(N, 6) - 1 do
        local Child = A.Safe(function() return Box:GetChildAt(i) end)
        if F.Alive(Child) then Items[#Items + 1] = Child end
    end
    for _, Child in ipairs(Items) do
        local ok, D = pcall(function()
            local S = Child.NotificationDetailsStruct
            local C = S[P.COL]
            local Icon = S[P.ICON]
            return { T = S[P.MSG]:ToString(), I = F.Alive(Icon) and F.PathOf(Icon) or "",
                R = C.R, G = C.G, B = C.B, A = C.A, D = S[P.DELAY], F = S[P.FORCE] == true }
        end)
        pcall(function() Child:RemoveFromParent() end)
        if ok and D and D.T and D.T ~= "" and #D.T <= 400 and not F.YieldDrop(Target, D.T) then
            F.SendNote(Target, F.EncNote(D.T, D.I, D.R, D.G, D.B, D.A, D.D, D.F), D.T, D.F, Now)
        end
    end
end

-- WORLD-21 (E11): Stein/Holz aus dem Nahkampf-Relay legt ls_combat ins Gast-Inventar; das JigTryAddItemSomewhere des
-- Spiels auf der Server-Kopie scheitert dabei und meldet "... dropped on ground" (Rocks UB @050d, Tree @026c) - falsch.
-- Diese zwei Texte fuer diesen Gast nicht weitergeben, solange A.Coop.MRelYieldPending(Key) wahr ist (ohne E11: nie).
P.YIELD_DROP = { ["Rocks dropped on ground"] = true, ["Wood dropped on ground"] = true }
function F.YieldDrop(Target, Text)
    if type(Target) ~= "table" or not P.YIELD_DROP[Text] then return false end
    local Fn = A.Coop.MRelYieldPending
    if type(Fn) ~= "function" then return false end
    local ok, Pending = pcall(Fn, Target.Key)
    return ok and Pending == true
end

-- Host: Proxy-HUD fuer einen Gast-PC (Server hat fuer entfernte PCs kein HUD -> GetHUD() == nil)
function F.Proxy(G, PC, Now)
    local Hud = PC.MyHUD
    if F.Alive(Hud) then return Hud end
    if G.ui_ProxyAt and Now - G.ui_ProxyAt < 10 then return nil end
    G.ui_ProxyAt = Now
    local Class, World = F.Obj(P.HUD), A.CurrentWorld()
    if not (Class and F.Alive(World)) then return nil end
    Hud = World:SpawnActor(Class, { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not F.Alive(Hud) then error("Proxy-HUD nicht gespawnt") end
    pcall(function() Hud:SetOwner(PC) end)
    pcall(function() Hud.PlayerOwner = PC end)
    PC.MyHUD = Hud
    Log("Proxy-HUD fuer %s angelegt (Hinweise gehen per note2 an den Gast)", tostring(G.PCName))
    return nil   -- NotificationUI entsteht im Spiel erst 2 s nach BeginPlay
end

function F.GuestNotes(G, Now)
    local PC = Net.PC(G)
    if not PC then return end
    local Hud = F.Proxy(G, PC, Now)
    if Hud then F.Drain(Hud, G, Now) end
end

-- Host (ui_note_pawn): BP_PlayerCharacter_C.CreateNotificationUI (BPI_Player, EVT @2fd2b) ist durch
-- IsLocallyControlled() gesperrt -> fuer eine Gast-Figur auf dem Host verworfen, ohne Client-RPC, das Proxy-HUD sieht
-- nichts (Aufrufer z.B. BP_HangarDoor_C @0d51, BP_KeycardDoor_C @0c05). Pre-Hook liest nur die Parameter
-- (Text, Image, Color, UI Delay) in U.PawnQ; F.PawnNotes schickt sie als note2 an den Gast dieser Figur.
function F.PawnHook(Now)
    if U.PawnHook or Now - U.PawnHookAt < 10 then return end
    U.PawnHookAt = Now
    if not F.Obj(P.CHAR) then return end
    U.PawnHook = A.TryHook(P.CHAR .. ":CreateNotificationUI", function(Ctx, Text, Image, Color, Delay)
        if not U.PawnOn or #U.PawnQ >= 30 then return end
        local ok, Pawn = pcall(function()   -- CORE-20: Kontext erst pruefen
            local O = Ctx:get()
            return F.Alive(O) and O:GetFName():ToString() or nil
        end)
        if not ok or type(Pawn) ~= "string" then return end
        local okT, T = pcall(function() return Text:get():ToString() end)
        if not okT or type(T) ~= "string" then return end
        local okI, I = pcall(function()
            local Icon = Image:get()
            return F.Alive(Icon) and F.PathOf(Icon) or ""
        end)
        local okC, C = pcall(function() local V = Color:get() return { R = V.R, G = V.G, B = V.B, A = V.A } end)
        local okD, D = pcall(function() return Delay:get() end)
        C = okC and type(C) == "table" and C or {}
        U.PawnQ[#U.PawnQ + 1] = { Pawn = Pawn, T = T, I = okI and type(I) == "string" and I or "",
            R = tonumber(C.R) or 1, G = tonumber(C.G) or 1, B = tonumber(C.B) or 1, A = tonumber(C.A) or 1,
            D = okD and tonumber(D) or 2, At = os.clock() }
    end) or nil
    if U.PawnHook then Once("pawnhook", "Spieler-Hinweise des Servers an Gaeste weitergeleitet") end
end

function F.PawnNotes(Now)
    U.PawnOn = F.On("ui_note_pawn")
    if not U.PawnOn then U.PawnQ = {} return end
    F.PawnHook(Now)
    if #U.PawnQ == 0 then return end
    local Q = U.PawnQ
    U.PawnQ = {}
    for _, N in ipairs(Q) do
        local G = Now - (N.At or 0) < 10 and Net.GuestByPawnName(N.Pawn) or nil   -- Geist/Host-Spieler: kein Gast
        if G and G.Epoch and Net.Has("ui_note2", G) and #N.T >= 1 and #N.T <= 400 then
            F.SendNote(G, F.EncNote(N.T, N.I, N.R, N.G, N.B, N.A, math.max(0.5, math.min(10, N.D)), false), N.T, false, Now)
        end
    end
end

function F.HostNotes(Now)
    if Net.Side ~= "host" or not F.On("ui_note") then U.PawnOn = false return end
    Net.ForEachGuest(function(G)
        if not (G.Epoch and Net.Has("ui_note2", G)) then return end
        F.Run("ui_note", F.GuestNotes, G, Now)
    end)
    F.Run("ui_note_pawn", F.PawnNotes, Now)
    -- Geist-HUD (dedizierter Host): Hinweise ohne Besitzer (Blutmond, Airdrop ...) an alle
    if A.Coop.Server and F.On("ui_note_ghost") then
        local PC = A.LocalPC()
        local Hud = F.Alive(PC) and A.Safe(function() return PC.MyHUD end) or nil
        if F.Alive(Hud) then F.Drain(Hud, "all", Now) end
    end
end

-- Gast: Warteschlange abarbeiten (hoechstens 3 je 100 ms)
function F.ClientNotes(Now)
    for _ = 1, 3 do
        local N = table.remove(U.NoteQ, 1)
        if not N then return end
        local Key = N.T
        if N.F or not U.NoteSeen[Key] or Now - U.NoteSeen[Key] >= 2 then
            U.NoteSeen[Key] = Now
            F.Run("ui_note", F.ShowNote, N.T, N.I, N.R, N.G, N.B, N.A, N.D, N.F)
        end
    end
end

-- ---------------------------------------------------------------- Level-/Skill-Up (Rueckfall ohne note2)

function F.LevelPoll()
    if not F.ClientReady() or not F.On("ui_lvl") or Net.Has("ui_note2") then U.LvlGen = nil return end
    local PC = A.LocalPC()
    if not F.Alive(PC) then return end
    local L, S = PC.LevellingComponent, PC.PassiveSkillsComponent
    if not (F.Alive(L) and F.Alive(S)) then return end
    if U.LvlGen ~= F.Gen() then U.LvlGen, U.LvlAt = F.Gen(), os.clock() end
    local Fresh = os.clock() - (U.LvlAt or 0) < 15   -- nach dem Join erst einschwingen (Spiegel vom Host)
    local Lv = L.CurrentLevel
    local Old = U.Lvl.Main
    U.Lvl.Main = Lv
    if not Fresh and Old and Lv == Old + 1 then
        local Text = string.format("Level up! You're now level %d!", Lv)
        if not F.NoteVisible(Text) then F.ShowNote(Text, "", 1, 1, 1, 1, 2, false) end
    end
    for _, Sk in ipairs(SKILLS) do
        local V = A.Safe(function() return S["Current" .. Sk.F .. "Level"] end)
        local Prev = U.Lvl[Sk.F]
        U.Lvl[Sk.F] = V
        if not Fresh and V and Prev and V > Prev and V - Prev < 1.5 then
            local Num = tostring(math.floor(V + 0.5))
            local Seen = F.NoteVisible("", function(T) return T:find(Sk.N, 1, true) and T:find(Num, 1, true) end)
            if not Seen then S:LevelUpNotification(FText(Sk.N), V) end
        end
    end
end

-- ---------------------------------------------------------------- Pausenmenue / Respawn / Tage-Banner (Gast)

function F.Pause()
    local PC = A.LocalPC()
    local Hud = F.Alive(PC) and A.Safe(function() return PC.MyHUD end) or nil
    local Menu = F.Alive(Hud) and Hud.PauseMenu
    if not F.Alive(Menu) or not Menu:IsInViewport() then return end
    for _, Name in ipairs({ "DifficultySettings", "Save", "QuickSave" }) do
        local W = Menu[Name]
        if F.Alive(W) and W:GetVisibility() ~= P.COLLAPSED then
            W:SetVisibility(P.COLLAPSED)
            Once("pause_" .. Name, "Pausenmenue: %s beim Gast ausgeblendet", Name)
        end
    end
end

function F.Respawn(Now)
    local PC = A.LocalPC()
    if not F.Alive(PC) then return end
    -- RespawnPointEnabled gehoert ls_player (P.ApplySpawnPt: pl_spawnpt + Schlafsack-Schonfrist). ui_rsp nur als
    -- Rueckfall, solange ls_player den Spiegel nicht fuehrt (bed_v2 aus / kein pl_spawnpt vom Host) -> nie zwei Schreiber.
    local Pl = A.Coop.Player
    local PlOwns = Pl ~= nil and Core.Flag("bed_v2", true) and Net.Get("pl_spawnpt", "en") ~= nil
    if PlOwns then
        Once("rsp_plowns", "Respawn: Spawnpunkt-Spiegel von ls_player (pl_spawnpt), ui_rsp nur Anzeige")
    elseif U.Rsp ~= nil and not (Pl and Pl.BagHold and Pl.BagHold() == true)
        and PC.RespawnPointEnabled ~= U.Rsp then
        PC.RespawnPointEnabled = U.Rsp
    end
    local Pawn = A.OwnPawn()
    local Dead = not F.Alive(Pawn) or Pawn["PlayerDead?"] == true
    if not Dead or Now < U.RespFindAt then return end
    U.RespFindAt = Now + 1   -- Suche hoechstens 1 Hz und nur, solange man tot ist (CORE-31: geteilt mit ls_player)
    for _, W in ipairs(F.Scan("RespawnScreen_C")) do
        if F.Alive(W) and W:IsInViewport() then
            local Btn = W.LoadSaveButton
            if F.Alive(Btn) and Btn:GetVisibility() ~= P.COLLAPSED then
                Btn:SetVisibility(P.COLLAPSED)
                Once("resp_load", "Respawn-Bildschirm: Spielstand-Laden beim Gast ausgeblendet")
            end
        end
    end
end

function F.DayBanner()
    if not F.ClientReady() or not F.On("ui_day") then U.Day = nil return end
    local PC = A.LocalPC()
    if not F.Alive(PC) then return end
    local D = PC.DaysSurvived

    if U.DayGen ~= F.Gen() or U.Day == nil then U.DayGen, U.Day, U.DayAt = F.Gen(), D, os.clock() return end
    if os.clock() - (U.DayAt or 0) < 15 then U.Day = D return end   -- Erst-Abgleich (stats) abwarten
    if D == U.Day + 1 then
        local Hud = PC.MyHUD
        local Shown = F.Alive(Hud) and F.Alive(Hud.DaysSurvivedUI) and Hud.DaysSurvivedUI:IsInViewport()
        if F.Alive(Hud) and not Shown then
            Hud:DaysSurvivedHUD()
            Log("Tage-Banner gezeigt (Tag %d)", D)
        end
    end
    U.Day = D
end

-- ---------------------------------------------------------------- CVars

function F.CvarNames()
    local List = {}
    for _, N in ipairs(CVARS.b) do List[#List + 1] = { "Difficulty." .. N, "b" } end
    for _, N in ipairs(CVARS.f) do List[#List + 1] = { "Difficulty." .. N, "f" } end
    for _, N in ipairs(CVARS.loot) do List[#List + 1] = { "Loot." .. N, "f" } end
    return List
end

function F.GetCvar(CU, Name, Type)
    if Type == "b" then return "b:" .. (CU:GetBoolCVar(FName(Name)) and "1" or "0") end
    return "f:" .. string.format("%.6g", CU:GetFloatCVar(FName(Name)))
end

function F.SetCvar(CU, Name, Value)
    local Type, Raw = Value:match("^([bf]):(.+)$")
    if Type == "b" then CU:SetBoolCVar(FName(Name), Raw == "1")
    elseif Type == "f" and tonumber(Raw) then CU:SetFloatCVar(FName(Name), tonumber(Raw)) end
end

-- Host: alle 5 s lesen, nur Aenderungen gehen als Keyed-State raus
function F.HostCvars(Now)
    if Now - U.CvAt < 5 or not F.On("ui_cvars") then return end
    U.CvAt = Now
    local CU = F.CU()
    if not CU then return end
    for _, E in ipairs(F.CvarNames()) do
        local ok, V = pcall(F.GetCvar, CU, E[1], E[2])
        if ok and V and U.CvSent[E[1]] ~= V then
            U.CvSent[E[1]] = V
            Net.State("ui_cvar", E[1], V, 2)
        end
    end
end

function F.SaveBackup()
    local Lines = {}
    for Name, V in pairs(U.CvOrig) do Lines[#Lines + 1] = Name .. "=" .. V end
    Core.WriteAtomic(A.ModDir .. P.BACKUP, table.concat(Lines, "\n") .. "\n")
    U.CvDirty = false
end

-- Gast: Wert des Hosts setzen, Original einmal merken
function F.ApplyCvar(Name, Value)
    local CU = F.CU()
    if not CU then return end
    local Type = Value:match("^([bf]):")
    if not Type then return end
    if U.CvOrig[Name] == nil then
        local ok, Orig = pcall(F.GetCvar, CU, Name, Type)
        if not ok then return end
        U.CvOrig[Name], U.CvDirty = Orig, true
    end
    F.SetCvar(CU, Name, Value)
end

-- Gast: Host-Werte aus dem empfangenen Keyed-State erneut setzen (nach einem Ruecksetzen bei kurzem Weltverlust)
function F.Reapply()
    U.CvReapply = false
    local Mirror = Net.Mirror and Net.Mirror.host and Net.Mirror.host.ui_cvar
    for Name, Value in pairs(Mirror or {}) do
        if not F.CvarSkip(Name) then pcall(F.ApplyCvar, Name, Value) end
    end
end

function F.CvarSkip(Name)
    return Name == "Difficulty.Permadeath" or Name == "Difficulty.Allow" or Name == "Difficulty.MultiHit"
end

-- Gast, jede Sekunde: Permadeath aus (Client_Suicide/Client_Died -> ScreenPermadeath loescht sonst den Spielstand)
function F.GuardPermadeath()
    local CU = F.CU()
    if not CU then return end
    local Name = "Difficulty.Permadeath"
    if CU:GetBoolCVar(FName(Name)) then
        if U.CvOrig[Name] == nil then U.CvOrig[Name], U.CvDirty = "b:1", true end
        CU:SetBoolCVar(FName(Name), false)
        Once("permadeath", "Permadeath beim Gast fuer die Sitzung aus (Spielstand-Schutz)")
    end
end

-- Originale zurueck (Verlassen, oder Sicherung aus einer abgebrochenen Sitzung)
function F.RestoreCvars(Source)
    local CU = F.CU()
    if not CU then return false end
    local N = 0
    for Name, V in pairs(Source) do
        if pcall(F.SetCvar, CU, Name, V) then N = N + 1 end
    end
    U.CvOrig, U.CvDirty = {}, false
    Core.Remove(A.ModDir .. P.BACKUP)   -- WriteAtomic-Datei: .bak/.tmp mit entfernen
    if N > 0 then Log("CVars: %d Originalwerte zurueckgesetzt", N) end
    return true
end

function F.CvarSlow()
    if Net.Side == "client" then
        if F.On("ui_cvars") then
            F.GuardPermadeath()
            if U.CvReapply then F.Reapply() end
        end
        if U.CvDirty then F.SaveBackup() end
        return
    end
    if next(U.CvOrig) then
        F.RestoreCvars(U.CvOrig)
        U.CvReapply = true   -- kommt die Verbindung (gleiche Epoche) zurueck: Host-Werte aus dem Spiegel neu setzen
        return
    end
    if U.BackupChecked or not F.Alive(A.CurrentWorld()) then return end
    U.BackupChecked = true
    local Text = Core.ReadAll(A.ModDir .. P.BACKUP)
    if not Text then return end
    local Saved = {}
    for Name, V in Text:gmatch("([%w%._&]+)=([bf]:[^\r\n]+)") do Saved[Name] = V end
    F.RestoreCvars(Saved)
end

-- ---------------------------------------------------------------- Kampfmusik

function F.HostCombat()
    if not F.On("ui_music") then return end
    Net.ForEachGuest(function(G)
        if not (G.Epoch and Net.Has("ui_cmb", G)) then return end
        local PC = Net.PC(G)
        local Pawn = PC and PC:K2_GetPawn()
        if not F.Alive(Pawn) then return end
        Net.State("ui_cmb", "c", Pawn.EnemiesClose and "1" or "0", 1, G)
    end)
end

function F.Audio(Now)
    local Mgr = U.AudioName and F.Obj(U.AudioName)
    if Mgr or Now < U.AudioFindAt then return Mgr end
    U.AudioFindAt = Now + 1
    for _, X in ipairs(F.Scan("BP_Audio_Manager_C")) do
        if F.Alive(X) and not X:GetFullName():find("Default__", 1, true) then
            U.AudioName = F.PathOf(X)
            return X
        end
    end
    return nil
end

-- 10 Hz: Wert des Hosts in die eigene Figur halten (lokales CheckCombat setzt ihn sonst alle 2 s zurueck)
function F.ClientCombat(Now)
    local Pawn = A.OwnPawn()
    if not F.Alive(Pawn) or U.Cmb == nil then return end
    local On = U.Cmb
    if On or U.CmbLast then
        if Pawn.EnemiesClose ~= On then Pawn.EnemiesClose = On end
        if Pawn.Combat ~= On then Pawn.Combat = On end
    end
    if On ~= U.CmbLast then
        local Mgr = F.Audio(Now)
        if Mgr then
            Mgr:UpdateCombatStatus(On and 1 or 0)
            U.CmbLast = On
        end
    end
end

-- 1 Hz: Audio-Manager an die aktuelle eigene Figur binden (nach Respawn zeigt Player auf die alte)
function F.AudioBind(Now)
    local Pawn, Mgr = A.OwnPawn(), F.Audio(Now)
    if not (F.Alive(Pawn) and Mgr) then return end
    local Cur = Mgr.Player
    if not F.Alive(Cur) or Cur:GetAddress() ~= Pawn:GetAddress() then
        Mgr.Player = Pawn
        Once("audio_bind", "Audio-Manager an die eigene Figur gebunden")
    end
end

-- ---------------------------------------------------------------- Treffer (ui_hit)

function F.ShowHit(H)
    local Pawn = A.OwnPawn()
    if not F.Alive(Pawn) then return end
    local Col = { R = H.R, G = H.G, B = H.B, A = H.A }
    if H.M then
        local UI = Pawn.InGameUI
        if F.Alive(UI) then UI:Hitmarker(Col) end
    end
    if H.D and H.Dmg ~= 0 then
        if F.Obj(P.DMG_FN) then
            -- UE 5.6: SpawnDamageNumbers projiziert ImpactPoint mit GetPlayerController(0) (beim Gast der eigene)
            local Lib = F.Obj(P.GFL)
            if Lib then Lib:SpawnDamageNumbers(H.Dmg, Col, F.HitPoint(Pawn, H), Pawn) end
        else
            local Lib = F.Obj(P.BFL_AI)
            if Lib then Lib:SpawnFloatingDamageText(H.Dmg, Col, Pawn)
            else Once("dmg_none", "Schadenszahl: weder SpawnDamageNumbers noch BFL_AI gefunden, nur Hitmarker") end
        end
    end
end

-- Weltpunkt der Schadenszahl: vom Host mitgeschickt, sonst 4 m vor der eigenen Kamera (Bildmitte)
function F.HitPoint(Pawn, H)
    if H.X and H.Y and H.Z then return { X = H.X, Y = H.Y, Z = H.Z } end
    local PC = A.LocalPC()
    local Cam = F.Alive(PC) and A.Safe(function() return PC.PlayerCameraManager end) or nil
    local L = F.Alive(Cam) and A.Safe(function() return Cam:GetCameraLocation() end) or nil
    local Fw = L and A.Safe(function() return Cam:GetActorForwardVector() end) or nil
    if not (L and Fw) then
        L = Pawn:K2_GetActorLocation()
        Fw = A.Safe(function() return Pawn:GetActorForwardVector() end) or { X = 0, Y = 0, Z = 0 }
    end
    return { X = L.X + (Fw.X or 0) * 400, Y = L.Y + (Fw.Y or 0) * 400, Z = L.Z + (Fw.Z or 0) * 400 }
end

-- "<dmg>|r,g,b,a|<flags>" optional "|x,y,z" (Trefferpunkt, UE 5.6 SpawnDamageNumbers)
function F.ParseHit(Data)
    local Dmg, R, G, B, Al, Flags, Loc = Data:match("^([%-%d%.]+)|([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)|(%a*)(.*)$")
    if not Dmg then return nil end
    local X, Y, Z = Loc:match("^|([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$")
    if Loc ~= "" and not X then return nil end
    return { Dmg = tonumber(Dmg) or 0, R = tonumber(R), G = tonumber(G), B = tonumber(B), A = tonumber(Al),
        M = Flags:find("m", 1, true) ~= nil, D = Flags:find("d", 1, true) ~= nil,
        X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }
end

-- ---------------------------------------------------------------- Karte: eigene Marker

function F.MarkHook()
    if U.MarkHook ~= nil or not F.On("ui_marks") then return end
    local Fn = F.Obj(P.MARK_FN) and P.MARK_FN or (F.Obj(P.MARK_FN53) and P.MARK_FN53) or nil
    if not Fn then return end
    U.MarkHook = A.TryHook(Fn, function(_, Loc)
        -- Pre-Hook: nur Parameter lesen und in die Lua-Tabelle schreiben
        if #U.MarkReq >= 10 then return end
        local ok, V = pcall(function() local L = Loc:get() return { X = L.X, Y = L.Y } end)
        if ok and V then U.MarkReq[#U.MarkReq + 1] = { X = V.X, Y = V.Y, T = os.clock() } end
    end) or false
    if U.MarkHook then Log("Karten-Marker: Doppelklick wird beobachtet") end
end

-- ui_mark_gps (Gast, Live 27.10.: Marker setzen ging nicht): MapWidget_C AddPlayerMarker (Doppelklick, @0e94) prueft
-- IsGPSEquipped? -> BP_JigHelperComp GetEquippedInfoBySlot('Jig.PlayerSlot.GPS'); die lokale Ausruestungsliste fuellt beim
-- Gast niemand -> immer false, CreatePlayerMarker (und F.MarkHook) laufen nie. Hook auf das seltene UI-Event merkt nur den
-- Klick; F.MarkClick rechnet wie das Spiel (@0f35-@0f81: GetMousePositionOnViewport -> CalculateMarkerToWorld) und reiht
-- den Punkt in U.MarkReq ein (Anzeige/Speichern/Clan-Teilen wie bisher), nur wenn der Server GPS meldet (Coop.Map.HasGps)
-- und das Spiel selbst nichts angefragt hat. 0 = aus.
function F.ClickHook(Pawn)
    if U.ClickHook ~= nil or not F.On("ui_mark_gps") or not F.Alive(Pawn) then return end
    local Mini = A.Safe(function() return Pawn.MinimapSystemComponent end)
    local W = F.Alive(Mini) and A.Safe(function() return Mini.MapWidget end) or nil
    if not F.Alive(W) then return end
    local Path = A.Safe(function() return W:GetClass():GetFullName():match("^%S+%s+(%S+)$") end)
    if not Path then return end
    U.ClickHook = A.TryHook(Path .. ":AddPlayerMarker", function()
        U.MarkClick = os.clock()   -- nur merken (Hook-Koerper fasst keine UObjects an)
    end) or false
    if U.ClickHook then Log("Karten-Marker: Doppelklick ohne Spiel-GPS wird uebernommen (ui_mark_gps)") end
end

function F.MarkClick(Pawn)
    local At = U.MarkClick
    if not At then return end
    U.MarkClick = nil
    if os.clock() - At > 1 or #U.MarkReq >= 10 then return end
    local Last = U.MarkReq[#U.MarkReq]
    if Last and math.abs((Last.T or 0) - At) < 0.5 then return end   -- Spiel hat selbst angefragt (GPS-Pruefung ok)
    if not (A.Coop.Map and A.Coop.Map.HasGps) then return end
    local Mini = A.Safe(function() return Pawn.MinimapSystemComponent end)
    local W = F.Alive(Mini) and A.Safe(function() return Mini.MapWidget end) or nil
    if not F.Alive(W) then return end
    local WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local Mouse = F.Alive(WLL) and A.Safe(function() return WLL:GetMousePositionOnViewport(W) end) or nil
    local Pt = Mouse and A.Safe(function() return W:CalculateMarkerToWorld({ X = Mouse.X, Y = Mouse.Y }) end) or nil
    if not (Pt and Pt.X and Pt.Y) then Log("Karten-Marker: Position nicht berechenbar") return end
    U.MarkReq[#U.MarkReq + 1] = { X = Pt.X, Y = Pt.Y, T = os.clock() }
    Log("Karten-Marker: per Doppelklick gesetzt (ohne Spiel-GPS)")
end

function F.LoadMarks()
    if U.Marks then return U.Marks end
    U.Marks = {}
    local Text = Core.ReadAll(A.ModDir .. P.MARKS) or ""
    for Map, X, Y, Z in Text:gmatch("([^|\r\n]+)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)") do
        U.Marks[#U.Marks + 1] = { Map = Map, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }
    end
    return U.Marks
end

function F.SaveMarks()
    local Lines = {}
    for _, Mk in ipairs(F.LoadMarks()) do
        Lines[#Lines + 1] = string.format("%s|%.1f|%.1f|%.1f", Mk.Map, Mk.X, Mk.Y, Mk.Z)
    end
    Core.WriteAtomic(A.ModDir .. P.MARKS, table.concat(Lines, "\n") .. "\n")
end

-- BP_PlayerMarker_C in der Naehe (FindAllOf hoechstens 1 Hz; nil = gerade nicht suchbar)
function F.MarkerNear(Pt, Now)
    if Now < U.PMFindAt then return nil, false end
    U.PMFindAt = Now + 1
    for _, Mk in ipairs(FindAllOf("BP_PlayerMarker_C") or {}) do
        if F.Alive(Mk) then
            local L = Mk:K2_GetActorLocation()
            local Dx, Dy = L.X - Pt.X, L.Y - Pt.Y
            if Dx * Dx + Dy * Dy < 150 * 150 then return Mk, true end
        end
    end
    return nil, true
end

-- Marker sichtbar machen: vorhandenen (replizierten) lokal eintragen oder lokal spawnen
function F.ShowMarker(Pt, Existing)
    local Mk = Existing
    if F.Alive(Mk) then
        -- UE 5.6: Event_AddMarker (@030d..03d3) setzt self.Marker = Widget aus Add Player Marker (Array Markers entfernt);
        -- UE 5.3: Array Markers
        local Added = F.Alive(A.Safe(function() return Mk.Marker end))
        if not Added then Added = (A.Safe(function() return Mk.Markers:GetArrayNum() end, 0) or 0) > 0 end
        if not Added then Mk:Event_AddMarker() end
        Once("mark_rep", "Karten-Marker: Server-Marker repliziert, lokal eingetragen")
    else
        local Class, World = F.Obj(P.PMARKER), A.CurrentWorld()
        if not (Class and F.Alive(World)) then return end
        Mk = World:SpawnActor(Class, { X = Pt.X, Y = Pt.Y, Z = Pt.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not F.Alive(Mk) then return end
        Mk:Event_AddMarker()
        Once("mark_local", "Karten-Marker: lokal gesetzt (Server-Marker nicht repliziert)")
    end
    U.MarkObjs[#U.MarkObjs + 1] = { Path = F.PathOf(Mk), Pt = Pt }
end

function F.MarkRequests(Now, Pawn)
    local Req = U.MarkReq[1]
    if not Req then return end
    if not Req.Pt then
        local Mini = Pawn.MinimapSystemComponent
        if not F.Alive(Mini) then table.remove(U.MarkReq, 1) return end
        local Out, Ok = {}, {}
        -- Name mit Leerzeichen (UE 5.3); falls 5.6 ihn anders fuehrt, "Marker" versuchen. Scheitern beide, faellt der
        -- Eintrag unten heraus (kein ewiges Haengen der Warteschlange)
        if not pcall(function() Mini["Marker Location"](Mini, { X = Req.X, Y = Req.Y }, Out, Ok) end) then
            pcall(function() Mini["Marker"](Mini, { X = Req.X, Y = Req.Y }, Out, Ok) end)
        end
        local Hit = Out.ImpactPoint
        if not (Ok.Success and Hit) then
            -- Live 27.10. (Gast): Spiel-Trace lieferte nichts -> Eintrag fiel still heraus, kein Marker. Boden selbst suchen
            -- (main.lua Coop.Ground, Linie von oben); ohne Treffer Hoehe der eigenen Figur
            local PZ = A.Safe(function() return Pawn:K2_GetActorLocation().Z end)
            local Z = type(PZ) == "number" and A.Coop.Ground
                and A.Safe(function() return A.Coop.Ground({ X = Req.X, Y = Req.Y, Z = PZ }, Pawn, 50000) end) or nil
            if type(Z) ~= "number" then Z = PZ end
            if type(Z) ~= "number" then table.remove(U.MarkReq, 1) Log("Karten-Marker: keine Bodenhoehe - verworfen") return end
            Once("mark_ground", "Karten-Marker: Spiel-Trace ohne Treffer, Boden selbst bestimmt")
            Hit = { X = Req.X, Y = Req.Y, Z = Z }
        end
        Req.Pt = { X = Hit.X, Y = Hit.Y, Z = Hit.Z }
        return
    end
    if Now - Req.T < 1.5 then return end
    local Found, Searched = F.MarkerNear(Req.Pt, Now)
    if not Searched then return end
    table.remove(U.MarkReq, 1)
    F.ShowMarker(Req.Pt, Found)
    local Marks = F.LoadMarks()
    Marks[#Marks + 1] = { Map = F.Map(), X = Req.Pt.X, Y = Req.Pt.Y, Z = Req.Pt.Z }
    F.SaveMarks()
end

-- Nach dem Join (je Welt einmal): gespeicherte eigene Marker dieser Karte wieder setzen
function F.RestoreMarks(Now)
    if U.MarkGen == F.Gen() then return end
    local Own = A.OwnPawn()
    local Mini = F.Alive(Own) and Own.MinimapSystemComponent
    if not (F.Alive(Mini) and F.Alive(Mini.MapWidget)) then return end   -- Karte noch nicht gebaut
    local Map = F.Map()
    local Todo = {}
    for _, Mk in ipairs(F.LoadMarks()) do if Mk.Map == Map then Todo[#Todo + 1] = Mk end end
    U.MarkGen, U.MarkObjs = F.Gen(), {}
    if #Todo == 0 then return end
    local Existing = {}
    for _, X in ipairs(FindAllOf("BP_PlayerMarker_C") or {}) do
        if F.Alive(X) then Existing[#Existing + 1] = X end
    end
    for _, Mk in ipairs(Todo) do
        local Near = nil
        for _, X in ipairs(Existing) do
            local L = X:K2_GetActorLocation()
            if (L.X - Mk.X) ^ 2 + (L.Y - Mk.Y) ^ 2 < 150 * 150 then Near = X break end
        end
        pcall(F.ShowMarker, Mk, Near)
    end
    U.PMFindAt = Now + 1
    Log("Karten-Marker: %d eigene Marker wiederhergestellt", #Todo)
end

-- 1 Hz: vom Spieler entfernte Marker aus der Datei streichen
function F.PruneMarks()
    local Gone = {}
    local Keep = {}
    for _, O in ipairs(U.MarkObjs) do
        if F.Obj(O.Path) then Keep[#Keep + 1] = O else Gone[#Gone + 1] = O.Pt end
    end
    if #Gone == 0 then return end
    U.MarkObjs = Keep
    local Marks, Left = F.LoadMarks(), {}
    for _, Mk in ipairs(Marks) do
        local Drop = false
        for _, Pt in ipairs(Gone) do
            if math.abs(Mk.X - Pt.X) < 1 and math.abs(Mk.Y - Pt.Y) < 1 then Drop = true break end
        end
        if not Drop then Left[#Left + 1] = Mk end
    end
    U.Marks = Left
    F.SaveMarks()
end

-- ---------------------------------------------------------------- Karte: Mitspieler-Marker

function F.RemoveMate(Path)
    local Mk = F.Obj(Path)
    if not Mk then return end
    local Own = A.OwnPawn()
    local Mini = F.Alive(Own) and Own.MinimapSystemComponent
    local W = Mk.Marker
    if F.Alive(Mini) and F.Alive(W) then pcall(function() Mini["Remove World Marker"](Mini, W, Mk) end) end
    pcall(function() Mk:K2_DestroyActor() end)
end

-- Lokaler Welt-Marker (BP_Marker_C, BeginPlay -> Add World Marker in die eigene Minimap). Pawn: anhaengen.
function F.SpawnWorldMarker(Loc, Title, Desc, TexPath, Col, Pawn)
    local Class, World = F.Obj(P.MARKER), A.CurrentWorld()
    local Tex = F.Obj(TexPath) or A.Safe(function() return LoadAsset(TexPath) end)
    if not (Class and F.Alive(World)) then return nil end
    local Transform = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = Loc.X, Y = Loc.Y, Z = Loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GPS = A.UEHelpers.GetGameplayStatics()
    local Mk = GPS:BeginDeferredActorSpawnFromClass(World, Class, Transform, 1, nil, 1)
    if not F.Alive(Mk) then return nil end
    pcall(function() if F.Alive(Tex) then Mk.MarkerTexture = Tex end end)
    pcall(function() Mk.MarkerTitle = FText(Title) end)
    pcall(function() Mk.MarkerDescription = FText(Desc) end)
    pcall(function() Mk["AddMarkerToCompass?"] = true end)
    if Col then pcall(function() Mk.Color = Col end) end
    GPS:FinishSpawningActor(Mk, Transform, 1)
    if Pawn then pcall(function() Mk:K2_AttachToActor(Pawn, FName("None"), 2, 1, 1, false) end) end
    return F.PathOf(Mk)
end

function F.SpawnMate(Pawn, Name, Desc)
    return F.SpawnWorldMarker(Pawn:K2_GetActorLocation(), Name, Desc or "Mitspieler", P.MATE_TEX, nil, Pawn)
end

-- Gast: eigener Clan (Coop.Clan.My) oder nil
function F.MyClan()
    local C = A.Coop.Clan
    if not (C and C.My) then return nil end
    local My = A.Safe(function() return C.My() end)
    return type(My) == "table" and My or nil
end

-- Gast: Signatur des eigenen Clans (Name + Mitglieder) - Aenderung -> Mitspieler-Marker neu aufbauen
function F.ClanSig()
    local My = F.MyClan()
    if not My then return "-" end
    local Pids = {}
    for Pid in pairs(My.Members or {}) do Pids[#Pids + 1] = tostring(Pid) end
    table.sort(Pids)
    return tostring(My.Name) .. "|" .. table.concat(Pids, ",")
end

-- Gast: Mitspieler-Marker fuer diese Figur? Nur Clan-Mitglieder; ohne Clan-System bzw. ohne Clan nur bei pvp=0 alle.
function F.ShowMate(Pawn)
    if not F.On("ui_mates_clan") then return true end
    local C = A.Coop.Clan
    if not (C and C.IsMatePid) or not F.MyClan() then
        local V = Net.Get("cb_pvp", "m")   -- Politik des Hosts (ls_combat); bis sie ankommt die eigene coop.txt
        if V == "off" or V == "clan" or V == "all" then return V == "off" end
        return not Core.Flag("pvp", true)
    end
    local PS = Pawn.PlayerState
    if not F.Alive(PS) then return false end
    local Pid = A.Safe(function() return PS.PlayerId end)
    if Pid == nil then Pid = A.Safe(function() return PS:GetPlayerId() end) end
    if Pid == nil then return false end
    return A.Safe(function() return C.IsMatePid(Pid) end, false) == true
end

-- Rueckfall, falls das Anhaengen nicht griff (z. B. statische Wurzel): 1x/s nachziehen
function F.Follow(Mk, Pawn)
    local L, To = Mk:K2_GetActorLocation(), Pawn:K2_GetActorLocation()
    if (L.X - To.X) ^ 2 + (L.Y - To.Y) ^ 2 > 300 * 300 then
        Mk:K2_SetActorLocation({ X = To.X, Y = To.Y, Z = To.Z }, false, {}, true)
    end
end

function F.Mates()
    local Own = A.OwnPawn()
    local Mini = F.Alive(Own) and Own.MinimapSystemComponent
    if not (F.Alive(Mini) and F.Alive(Mini.MapWidget)) then return end   -- Add World Marker braucht die Karte
    local OwnName = Own:GetFName():ToString()
    -- Clan geaendert (beitreten, verlassen, Mitglieder): alle Marker neu (Titel/Filter)
    local Sig = F.On("ui_mates_clan") and F.ClanSig() or "-"
    if Sig ~= U.ClanSig then
        if U.ClanSig ~= nil then Log("Clan geaendert (%s): Mitspieler-Marker neu", Sig) end
        U.ClanSig, U.MatesOwner = Sig, nil
    end
    -- Weltwechsel oder neue eigene Figur (Respawn): Marker haengen an der alten Minimap -> alle neu
    if U.MatesGen ~= F.Gen() or U.MatesOwner ~= OwnName then
        for _, Path in pairs(U.Mates) do pcall(F.RemoveMate, Path) end
        U.Mates, U.MatesGen, U.MatesOwner = {}, F.Gen(), OwnName
    end
    local My = F.MyClan()
    local Desc = My and ("Clan " .. tostring(My.Name)) or "Mitspieler"
    local Seen = {}
    for _, Pawn in ipairs(F.Scan("BP_PlayerCharacter_C")) do   -- CORE-31: geteilte Suche (sonst wie A.PlayerPawns)
        local Name = F.Alive(Pawn) and Pawn:GetFName():ToString()
        if Name and Name ~= OwnName and not Pawn.bHidden and Pawn["PlayerDead?"] ~= true and F.ShowMate(Pawn) then
            Seen[Name] = true
            local Mk = U.Mates[Name] and F.Obj(U.Mates[Name])
            if not Mk then
                local PS = Pawn.PlayerState
                local Title = F.Alive(PS) and A.Safe(function() return PS:GetPlayerName():ToString() end) or "Mitspieler"
                U.Mates[Name] = F.SpawnMate(Pawn, Title, Desc)
                if U.Mates[Name] then Log("Mitspieler-Marker fuer %s", Title) end
            else
                pcall(F.Follow, Mk, Pawn)
            end
        end
    end
    for Name, Path in pairs(U.Mates) do
        if not Seen[Name] then
            pcall(F.RemoveMate, Path)
            U.Mates[Name] = nil
        end
    end
end

-- ---------------------------------------------------------------- Karte: Clan-Wegpunkte

-- "x,y,z/x,y,z/..." -> Liste (hoechstens WP_MAX, Koordinaten begrenzt); nil bei Unsinn
function F.ParsePts(Text)
    local Out = {}
    if type(Text) ~= "string" or #Text > P.WP_MAX * 40 then return nil end
    for X, Y, Z in Text:gmatch("([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
        X, Y, Z = tonumber(X), tonumber(Y), tonumber(Z)
        if not (X and Y and Z) or math.abs(X) > 5e6 or math.abs(Y) > 5e6 or math.abs(Z) > 1e6 then return nil end
        Out[#Out + 1] = { X = X, Y = Y, Z = Z }
        if #Out >= P.WP_MAX then break end
    end
    return Out
end

function F.FmtPts(Pts)
    local Parts = {}
    for _, Pt in ipairs(Pts) do Parts[#Parts + 1] = string.format("%.0f,%.0f,%.0f", Pt.X, Pt.Y, Pt.Z) end
    return table.concat(Parts, "/")
end

-- Gast (1 Hz): eigene Marker dieser Karte als Keyed-State an den Host (nur Aenderungen gehen raus)
function F.SendOwnMarks()
    if U.MarkGen ~= F.Gen() or not Net.Has("ui_cwp") then return end
    local Map, Pts = F.Map(), {}
    for _, Mk in ipairs(F.LoadMarks()) do if Mk.Map == Map then Pts[#Pts + 1] = Mk end end
    while #Pts > P.WP_MAX do table.remove(Pts, 1) end   -- die neuesten behalten
    local V = F.FmtPts(Pts)
    Net.State("ui_cwm", "m", V ~= "" and V or nil, 2)
end

-- Host: Gast-ID (Coop.Clan.GuestIdOf, sonst Net-Tabelle)
function F.GidOf(G)
    local C = A.Coop.Clan
    local Gid = C and C.GuestIdOf and A.Safe(function() return C.GuestIdOf(G) end) or nil
    if Gid == nil and type(G) == "table" then Gid = G.GuestId end
    return Gid and tostring(Gid) or nil
end

-- Host: Keyed-State ui_cwm von einem Gast ("m" = eigene Marker)
function F.OnOwnMarks(Value, G, Msg)
    if not (Msg and Msg.State and Msg.Key == "m" and type(G) == "table") then return end
    local Now = os.clock()
    if Now - (G.ui_CwmAt or 0) > 10 then G.ui_CwmAt, G.ui_CwmN = Now, 0 end
    G.ui_CwmN = (G.ui_CwmN or 0) + 1
    if G.ui_CwmN > 15 then Once("cwm_rate_" .. tostring(G.Key), "Clan-Wegpunkte: %s sendet zu oft, ignoriert", tostring(G.PCName)) return end
    local Gid = F.GidOf(G)
    if not Gid or not Gid:match("^[%w_%-]+$") or #Gid > 64 then return end
    local Pts = {}
    if Value ~= nil then Pts = F.ParsePts(Value) end
    if not Pts then Net.SecWarn(G, G.Key, "ui_cwm") return end
    local W = U.CwpHost[Gid]
    if not W then
        if #Pts == 0 then return end
        if U.CwpHostN >= P.WP_OWNERS then Once("cwp_full", "Clan-Wegpunkte: Speicher voll (%d Spieler)", P.WP_OWNERS) return end
        U.CwpHostN = U.CwpHostN + 1
        W = {}
        U.CwpHost[Gid] = W
    end
    W.LastAt = Now
    local PC = Net.PC(G)
    local PS = PC and A.Safe(function() return PC.PlayerState end)
    local Name = F.Alive(PS) and A.Safe(function() return PS:GetPlayerName():ToString() end) or W.N or "Spieler"
    W.N = tostring(Name):gsub("[~/|;=%%]", ""):sub(1, 32)
    W.V = F.FmtPts(Pts)   -- "" = keine Wegpunkte (Eintrag bleibt, damit das Loeschen bei allen ankommt)
end

-- ui_cwp_alias (PLAYER-2): Schluessel je Besitzer = undurchsichtiger Sitzungs-Alias "w<n>" statt der Gast-ID (die ID
-- ist Admin- und Konto-Schluessel und darf nie an andere Gaeste). Der Gast braucht nichts Neues (Muster ^[%w_%-]+$).
function F.CwpKey(Gid, Alias)
    if not Alias then return Gid end
    local K = U.CwpAlias[Gid]
    if not K then
        U.CwpAliasN = U.CwpAliasN + 1
        K = "w" .. U.CwpAliasN
        U.CwpAlias[Gid] = K
    end
    return K
end

-- Host: einen ui_cwp-Schluessel bei allen Gaesten loeschen (nur wo er ankam: Net.State sendet nil nur bei Aenderung)
function F.CwpDrop(Key)
    Net.ForEachGuest(function(G)
        if G.Epoch and Net.Has("ui_cwp", G) then Net.State("ui_cwp", Key, nil, 2, G) end
    end)
end

-- Host: Schalterwechsel ui_cwp_alias -> alte Schluessel einmal loeschen; Besitzer > WP_OFFLINE s nicht verbunden ->
-- vergessen (CORE-30: sonst nach 64 Spielern je Laufzeit "Speicher voll", keine neuen Clan-Wegpunkte mehr)
function F.CwpHousekeep(Now, Alias)
    if U.CwpAliasOn ~= nil and U.CwpAliasOn ~= Alias then
        for Owner in pairs(U.CwpHost) do F.CwpDrop(F.CwpKey(Owner, U.CwpAliasOn)) end
        Log("Clan-Wegpunkte: Schluessel jetzt %s, alte Eintraege bei den Gaesten geloescht", Alias and "Alias" or "Gast-ID")
    end
    U.CwpAliasOn = Alias
    local Online, Gone = {}, {}
    for _, G in pairs(Net.Guests) do
        local Gid = F.GidOf(G)
        if Gid then Online[Gid] = true end
    end
    for Owner, W in pairs(U.CwpHost) do
        if Online[Owner] or not W.LastAt then W.LastAt = Now
        elseif Now - W.LastAt > P.WP_OFFLINE then Gone[#Gone + 1] = Owner end
    end
    for _, Owner in ipairs(Gone) do
        F.CwpDrop(F.CwpKey(Owner, Alias))
        U.CwpHost[Owner], U.CwpAlias[Owner] = nil, nil
        U.CwpHostN = math.max(0, U.CwpHostN - 1)
    end
    if #Gone > 0 then Log("Clan-Wegpunkte: %d Besitzer seit %d min offline vergessen", #Gone, math.floor(P.WP_OFFLINE / 60)) end
end

-- Host (1 Hz): jedem Gast die Wegpunkte seiner Clan-Mitglieder (Keyed-State je Gast, Schluessel = Alias bzw. gid)
function F.HostWaypoints(Now)
    if Now - U.CwpAt < 1 then return end
    U.CwpAt = Now
    local Alias = F.On("ui_cwp_alias")
    F.CwpHousekeep(Now, Alias)
    local C = A.Coop.Clan
    local Allied = C and C.Allied
    Net.ForEachGuest(function(G)
        if not (G.Epoch and Net.Has("ui_cwp", G)) then return end
        local Me = F.GidOf(G)
        for Owner, W in pairs(U.CwpHost) do
            local Show = Me ~= nil and Allied ~= nil and Owner ~= Me and W.V ~= nil and W.V ~= ""
                and A.Safe(function() return Allied(Owner, Me) end, false) == true
            Net.State("ui_cwp", F.CwpKey(Owner, Alias), Show and (W.N .. "~" .. W.V) or nil, 2, G)
        end
    end)
end

function F.ClearWaypoints()
    for _, S in pairs(U.CwpShown) do
        for _, Path in ipairs(S.Paths) do pcall(F.RemoveMate, Path) end
    end
    U.CwpShown = {}
end

-- Gast (1 Hz): empfangene Clan-Wegpunkte als lokale Welt-Marker zeigen / abgleichen
function F.Waypoints()
    local Own = A.OwnPawn()
    local Mini = F.Alive(Own) and Own.MinimapSystemComponent
    if not (F.Alive(Mini) and F.Alive(Mini.MapWidget)) then return end
    local OwnName = Own:GetFName():ToString()
    if U.CwpGen ~= F.Gen() or U.CwpOwner ~= OwnName then
        F.ClearWaypoints()
        U.CwpGen, U.CwpOwner = F.Gen(), OwnName
    end
    local Total = 0
    for Key, S in pairs(U.CwpShown) do
        if U.CwpIn[Key] ~= S.V then
            for _, Path in ipairs(S.Paths) do pcall(F.RemoveMate, Path) end
            U.CwpShown[Key] = nil
        else
            Total = Total + #S.Paths
        end
    end
    local Col = { R = 0.25, G = 1, B = 0.45, A = 1 }
    for Key, V in pairs(U.CwpIn) do
        if not U.CwpShown[Key] then
            local Name, Pts = V:match("^([^~]*)~(.*)$")
            Pts = Pts and F.ParsePts(Pts)
            local S = { V = V, Paths = {} }
            U.CwpShown[Key] = S
            for _, Pt in ipairs(Pts or {}) do
                if Total >= P.WP_SHOWN then Once("cwp_cap", "Clan-Wegpunkte: Obergrenze %d erreicht", P.WP_SHOWN) break end
                local Path = F.SpawnWorldMarker(Pt, (Name ~= "" and Name or "Clan"), "Clan-Wegpunkt", P.WP_TEX, Col, nil)
                if Path then S.Paths[#S.Paths + 1], Total = Path, Total + 1 end
            end
            if #S.Paths > 0 then Log("Clan-Wegpunkte von %s: %d", tostring(Name), #S.Paths) end
        end
    end
end

-- ---------------------------------------------------------------- Karte: Marker nach dem Respawn

-- Liegt Obj naeher als R an einem der Punkte?
function F.NearAny(Obj, Pts, R)
    if #Pts == 0 then return false end
    local L = A.Safe(function() return Obj:K2_GetActorLocation() end)
    if not L then return false end
    for _, Pt in ipairs(Pts) do
        if (L.X - Pt.X) ^ 2 + (L.Y - Pt.Y) ^ 2 + (L.Z - Pt.Z) ^ 2 < R * R then return true end
    end
    return false
end

-- ui_respawn_marks (PLAYER-6): Im Einzelspieler traegt GI.Survival_Respawn nach jedem Respawn alle Marker in die neue
-- Karte ein (BP_PlayerMarker_C.RespawnMarker @0390, BP_POIManager_C.RespawnMarker @066a, BP_Marker_C.AddMarker @07bd);
-- im Koop laeuft das nur beim Host. Hier einmal je neuer eigener Figur (die erste der Welt nicht: BeginPlay und
-- F.RestoreMarks tragen ein). Eigene Karten-Marker nur aus U.MarkObjs (replizierte BP_PlayerMarker_C anderer Spieler nie
-- eintragen), ohne Mitspieler-/Wegpunkt-Marker (F.Mates/F.Waypoints bauen sie neu) und ohne Marker an Todes-Kisten
-- (main.lua Corpse.ClientMarkers: eigene traegt es selbst neu ein, fremde bleiben versteckt).
function F.RespawnMarks()
    local Own = A.OwnPawn()
    if not F.Alive(Own) or A.Safe(function() return Own["PlayerDead?"] end, false) == true then return end
    local Mini = A.Safe(function() return Own.MinimapSystemComponent end)
    if not (F.Alive(Mini) and F.Alive(A.Safe(function() return Mini.MapWidget end))) then return end   -- Karte fehlt noch
    local Name = A.Safe(function() return Own:GetFName():ToString() end)
    if not Name then return end
    if U.RmGen ~= F.Gen() then U.RmGen, U.RmFor = F.Gen(), Name return end
    if U.RmFor == Name then return end
    U.RmFor = Name
    local Skip, Boxes, N = {}, {}, 0
    for _, Path in pairs(U.Mates) do Skip[Path] = true end
    for _, S in pairs(U.CwpShown) do for _, Path in ipairs(S.Paths) do Skip[Path] = true end end
    for _, Box in ipairs(F.Scan("Container_DeadPlayerLoot_C")) do
        local L = F.Alive(Box) and A.Safe(function() return Box:K2_GetActorLocation() end) or nil
        if L then Boxes[#Boxes + 1] = { X = L.X, Y = L.Y, Z = L.Z } end
    end
    for _, O in ipairs(U.MarkObjs) do
        local Mk = F.Obj(O.Path)
        if Mk and pcall(function() Mk:RespawnMarker() end) then N = N + 1 end
    end
    for _, Mgr in ipairs(F.Scan("BP_POIManager_C")) do
        if F.Alive(Mgr) and not F.PathOf(Mgr):find("Default__", 1, true)
            and pcall(function() Mgr:RespawnMarker() end) then N = N + 1 end
    end
    for _, Mk in ipairs(F.Scan("BP_Marker_C")) do
        local Path = F.Alive(Mk) and F.PathOf(Mk) or nil
        if Path and not Skip[Path] and not Path:find("Default__", 1, true) and not F.NearAny(Mk, Boxes, 500)
            and pcall(function() Mk:AddMarker() end) then N = N + 1 end
    end
    Log("Respawn: %d Karten-/Kompass-Marker neu eingetragen (wie Survival_Respawn)", N)
end

-- ---------------------------------------------------------------- Clan-Chat (clan_msg)

-- Empfang von clan_msg macht ls_clan selbst (M.Handlers.clan_msg); Anzeige ueber M.ClanMsg -> U.ClanQ moeglich.

-- Gast (10 Hz-Task): Clan-Zeile ins Chatfenster (main.lua Coop.Chat), sonst bzw. zusaetzlich als Hinweis
function F.ShowClanMsg(Name, Text)
    local Ch, Shown = A.Coop.Chat, false
    if F.On("ui_clanmsg_chat") and type(Ch) == "table" and type(Ch.History) == "table" then
        Ch.Count = (Ch.Count or 0) + 1
        Ch.History[#Ch.History + 1] = { Id = Ch.Count, Name = "[Clan] " .. Name, Msg = Text, Admin = false, At = os.time() }
        while #Ch.History > 50 do table.remove(Ch.History, 1) end
        if Ch.Setup and Ch.Render then
            local ok, Ready = pcall(Ch.Setup)
            if ok and Ready then pcall(Ch.Render) end
        end
        Shown = true
    end
    if not Shown or Core.Flag("ui_clanmsg_toast", false) then
        F.ShowNote("[Clan] " .. Name .. ": " .. Text, "", 0.25, 1, 0.45, 1, 5, true)
    end
end

function F.ClanMsgs()
    for _ = 1, 3 do
        local L = table.remove(U.ClanQ, 1)
        if not L then return end
        F.Run("ui_clanmsg", F.ShowClanMsg, L.N, L.T)
    end
end

-- ---------------------------------------------------------------- Aufgaben

-- 100 ms, Gast: Hinweise, Treffer, Pausenmenue, Respawn, Karte, Munition, Kampfmusik
function F.ClientFast(Now)
    if Net.Side ~= "client" or not Core.Flag("ui_v2", true) then return end
    if #U.NoteQ > 0 and F.On("ui_note") then F.Run("ui_note", F.ClientNotes, Now) end
    if #U.ClanQ > 0 then F.ClanMsgs() end
    for _ = 1, 4 do
        local H = table.remove(U.HitQ, 1)
        if not H then break end
        if F.On("ui_hit") then F.Run("ui_hit", F.ShowHit, H) end
    end
    if F.Loading() then return end
    if F.On("ui_pause") then F.Run("ui_pause", F.Pause) end
    if F.On("ui_respawn") then F.Run("ui_respawn", F.Respawn, Now) end
    if not F.ClientReady() then return end
    local Pawn = A.OwnPawn()
    if not F.Alive(Pawn) then return end
    if F.On("ui_ammo") and A.Coop.AmmoTick then
        F.Run("ui_ammo", A.Coop.AmmoTick)
        if A.Coop.AmmoHold then F.Run("ui_ammo", A.Coop.AmmoHold, Pawn) end
    end
    if F.On("ui_map") and A.Coop.Map and A.Coop.Map.ClientTick then F.Run("ui_map", A.Coop.Map.ClientTick, Pawn) end
    if F.On("ui_mark_gps") and U.MarkClick then F.Run("ui_mark_gps", F.MarkClick, Pawn) end
    if F.On("ui_marks") and #U.MarkReq > 0 then F.Run("ui_marks", F.MarkRequests, Now, Pawn) end
    if F.On("ui_music") then F.Run("ui_music", F.ClientCombat, Now) end
    if F.On("cheat_gate") and not F.IsAdmin() then F.Run("cheat_gate", F.CheatClose, Pawn, Now) end
end

-- Gast (ui_hudre): UE 5.6 HUD_Game legt EnemyHealthBarUI (W_EnemyHealthBarOverlay) und NotificationUI nur einmal an
-- (@0087). Client_Died -> RemoveAllWidgets (BP_PlayerController @1c04) nimmt beide aus dem Bild; im Einzelspieler
-- holt GI.Survival_Respawn @0033 sie per HUD.Re-Initialise zurueck, im Koop laeuft Survival_Respawn beim Host
-- (Svr_RequestRespawn_*), dessen GetGameHUD nie das HUD des Gasts trifft. Ohne das: nach dem ersten Tod keine
-- Zombie-Lebensbalken (ToggleAIHealthBar schaltet in 5.6 nur noch die Sichtbarkeit) und keine Hinweise.
function F.HudWidgets()
    local Pawn = A.OwnPawn()
    if not F.Alive(Pawn) or A.Safe(function() return Pawn["PlayerDead?"] end, false) == true then return end
    local PC = A.LocalPC()
    local Hud = F.Alive(PC) and A.Safe(function() return PC.MyHUD end) or nil
    if not F.Alive(Hud) then return end
    local Lost = 0
    for _, E in ipairs(P.HUD_RE) do
        local W = A.Safe(function() return Hud[E[1]] end)
        if F.Alive(W) and A.Safe(function() return W:IsInViewport() end, true) == false then
            W:AddToViewport(E[2])
            if A.Safe(function() return W:IsInViewport() end, false) then
                Log("HUD: %s wieder im Bild (nach Tod/RemoveAllWidgets)", E[1])
            else
                Lost = Lost + 1
            end
        end
    end
    -- Rueckfall wie im Einzelspieler (GI.Survival_Respawn), hoechstens einmal je Figur: legt beide neu an
    local Name = Lost > 0 and A.Safe(function() return Pawn:GetFName():ToString() end) or nil
    if Name and U.HudReFor ~= Name then
        U.HudReFor = Name
        Hud["Re-Initialise"](Hud)
        Log("HUD: Re-Initialise (Lebensbalken/Hinweise neu angelegt)")
    end
end

-- 1 s, beide Seiten (laeuft auch im Menue: CVar-Ruecksetzung nach dem Verlassen)
function F.Slow(Now)
    if not Core.Flag("ui_v2", true) then
        if next(U.CvOrig) then F.RestoreCvars(U.CvOrig) end
        return
    end
    Net.Cap("ui_note2", F.On("ui_note"))
    Net.Cap("ui_cvar", F.On("ui_cvars"))
    Net.Cap("ui_cmb", F.On("ui_music"))
    Net.Cap("ui_rsp", F.On("ui_respawn"))
    Net.Cap("ui_hit", F.On("ui_hit"))
    Net.Cap("ui_cwp", F.On("ui_clanwp"))
    if Now - (U.SeenAt or 0) > 60 then U.NoteSeen, U.HostSeen, U.SeenAt = {}, {}, Now end   -- Dedupe-Tabellen klein halten
    F.Run("ui_cvars", F.CvarSlow)
    F.Run("ui_patch", F.Patches, Net.Side == "client")
    F.Run("cheat_gate", F.CheatGate, Net.Side == "client")   -- auch Host/Solo: Patch wieder aus
    if Net.Side ~= "client" then
        U.Cmb, U.CmbLast, U.Rsp, U.NoteQ, U.HitQ, U.MarkReq, U.ClanQ = nil, nil, nil, {}, {}, {}, {}
        return
    end
    U.PawnOn, U.PawnQ = false, {}   -- Gast: CreateNotificationUI-Weiterleitung ist reine Host-Sache
    if F.Loading() then return end
    F.MarkHook()
    if not F.ClientReady() then return end
    F.ClickHook(A.Safe(A.OwnPawn, nil))
    if F.On("ui_hudre") then F.Run("ui_hudre", F.HudWidgets) end
    if F.On("ui_music") then F.Run("ui_music", F.AudioBind, Now) end
    if F.On("ui_marks") then
        F.Run("ui_marks", F.RestoreMarks, Now)
        F.Run("ui_marks", F.PruneMarks)
    end
    if F.On("ui_mates") then F.Run("ui_mates", F.Mates) end
    if F.On("ui_clanwp") then
        if F.On("ui_marks") then F.Run("ui_clanwp", F.SendOwnMarks) end
        F.Run("ui_clanwp", F.Waypoints)
    elseif next(U.CwpShown) then
        F.Run("ui_clanwp", F.ClearWaypoints)
    end
    -- nach F.Mates/F.Waypoints: deren neue Marker sind dann in U.Mates/U.CwpShown und werden uebersprungen
    if F.On("ui_respawn_marks") then F.Run("ui_respawn_marks", F.RespawnMarks) end
end

-- 0,5 s, Host: Kampfstatus, Respawnpunkt, CVars je Gast
function F.Host(Now)
    if Net.Side ~= "host" or not Core.Flag("ui_v2", true) or F.Loading() then return end
    F.Run("ui_music", F.HostCombat)
    if F.On("ui_respawn") then
        Net.ForEachGuest(function(G)
            if not (G.Epoch and Net.Has("ui_rsp", G)) then return end
            local PC = Net.PC(G)
            if PC then Net.State("ui_rsp", "r", PC.RespawnPointEnabled and "1" or "0", 2, G) end
        end)
    end
    F.Run("ui_cvars", F.HostCvars, Now)
    if F.On("ui_clanwp") then
        local C = A.Coop.Clan
        if not U.ClanHooked and C and C.OnChange then
            U.ClanHooked = true   -- Clan-Aenderung: Wegpunkte sofort neu verteilen (sonst spaetestens nach 1 s)
            pcall(C.OnChange, function() U.CwpAt = 0 end)
        end
        F.Run("ui_clanwp", F.HostWaypoints, Now)
    end
    if F.On("ui_music") and not U.HostMusicChecked then
        U.HostMusicChecked = true
        local CU = F.CU()
        if CU and not CU:GetBoolCVar(FName("Character.CombatMusic")) then
            CU:SetBoolCVar(FName("Character.CombatMusic"), true)   -- sonst rechnet CheckCombat auf dem Host nichts
            Log("Host: Character.CombatMusic eingeschaltet (Kampfstatus fuer Gaeste)")
        end
    end
end

-- ---------------------------------------------------------------- Netz-Handler

M.Handlers = {
    -- Host -> Gast: "<text>|<iconPfad>|r,g,b,a|<delay>|<force 0/1>"
    note2 = function(Data, _, Msg)
        if Net.Side ~= "client" or not F.On("ui_note") or (Msg and Msg.Legacy) then return end
        local T, I, Col, D, Fo = Data:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([01])$")
        if not T or #U.NoteQ >= 20 then return end
        local R, G, B, Al = Col:match("^([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)$")
        local Text = Net.Dec(T)
        if Text == "" or #Text > 400 then return end
        U.NoteQ[#U.NoteQ + 1] = { T = Text, I = Net.Dec(I), R = tonumber(R) or 1, G = tonumber(G) or 1,
            B = tonumber(B) or 1, A = tonumber(Al) or 1, D = math.max(0.5, math.min(10, tonumber(D) or 2)), F = Fo == "1" }
    end,
    -- Keyed-State Host -> alle: CVar-Name = "b:0|1" / "f:<zahl>"
    ui_cvar = function(Value, _, Msg)
        if Net.Side ~= "client" or not F.On("ui_cvars") or not (Msg and Msg.Key) or Value == nil then return end
        local Name = Msg.Key
        if not (Name:match("^Difficulty%.[%w]+$") or Name:match("^Loot%.[%w&]+$")) then return end
        if F.CvarSkip(Name) then return end
        F.Run("ui_cvars", F.ApplyCvar, Name, Value)
    end,
    -- Keyed-State Host -> Gast: "c" = EnemiesClose der Server-Kopie
    ui_cmb = function(Value)
        if Net.Side ~= "client" then return end
        if Value == nil then U.Cmb = nil else U.Cmb = Value == "1" end
    end,
    -- Keyed-State Host -> Gast: "r" = RespawnPointEnabled des Gast-PCs auf dem Host
    ui_rsp = function(Value)
        if Net.Side ~= "client" then return end
        if Value == nil then U.Rsp = nil else U.Rsp = Value == "1" end
    end,
    -- Keyed-State Gast -> Host: "m" = eigene Karten-Marker dieser Karte "x,y,z/x,y,z/..." (hoechstens 20)
    ui_cwm = function(Value, Peer, Msg)
        if Net.Side ~= "host" or not F.On("ui_clanwp") then return end
        F.Run("ui_clanwp", F.OnOwnMarks, Value, Peer, Msg)
    end,
    -- Keyed-State Host -> Gast: <Alias "w<n>" (ui_cwp_alias) bzw. gid des Besitzers> = "<Name>~x,y,z/..." (nur
    -- Clan-Mitglieder), nil = weg. Der Schluessel ist hier nur eine Kennung (Muster ^[%w_%-]+$ passt fuer beide).
    ui_cwp = function(Value, _, Msg)
        if Net.Side ~= "client" or not (Msg and Msg.Key) then return end
        local Key = tostring(Msg.Key)
        if not Key:match("^[%w_%-]+$") or #Key > 64 then return end
        if Value == nil then U.CwpIn[Key] = nil return end
        if not U.CwpIn[Key] then
            local N = 0
            for _ in pairs(U.CwpIn) do N = N + 1 end
            if N >= P.WP_OWNERS then return end
        end
        U.CwpIn[Key] = tostring(Value):sub(1, 64 + P.WP_MAX * 40)
    end,
    -- Host (ls_combat) -> Gast: "<dmg>|r,g,b,a|<flags m/d>"
    ui_hit = function(Data)
        if Net.Side ~= "client" or #U.HitQ >= 20 then return end
        local H = F.ParseHit(Data)
        if H then U.HitQ[#U.HitQ + 1] = H end
    end,
}

-- ---------------------------------------------------------------- Exporte fuer andere Module

-- Hinweis: Host -> Ziel (Gast-Tabelle/Key/"all"); Gast -> lokal anzeigen
function M.Note(Target, Text, IconPath, Force)
    Text = tostring(Text or "")
    if Text == "" then return false end
    if Net.Side == "client" then
        U.NoteQ[#U.NoteQ + 1] = { T = Text, I = IconPath or "", R = 1, G = 1, B = 1, A = 1, D = 4, F = Force == true }
        return true
    end
    if Net.Side ~= "host" then return false end
    local Data = F.EncNote(Text, IconPath, 1, 1, 1, 1, 4, Force == true)
    local G = Target
    if type(Target) == "string" and Target ~= "all" then G = Net.Guests[Target] end
    if Target == nil then G = "all" end
    if G == nil then return false end
    F.SendNote(G, Data, Text, Force == true, os.clock())
    return true
end

-- Host: Treffer-Feedback an einen Gast (ls_combat). Flags: "m" Hitmarker, "d" Schadenszahl.
-- Loc (optional, {X,Y,Z}): Trefferpunkt fuer die Schadenszahl (UE 5.6 SpawnDamageNumbers); ohne -> vor der Kamera.
function M.SendHit(Target, Dmg, R, G, B, Al, Flags, Loc)
    if Net.Side ~= "host" or not Net.Has("ui_hit", Target) then return false end
    local Pt = ""
    if type(Loc) == "table" and tonumber(Loc.X) and tonumber(Loc.Y) and tonumber(Loc.Z) then
        Pt = string.format("|%.0f,%.0f,%.0f", Loc.X, Loc.Y, Loc.Z)
    end
    return Net.Send("ui_hit", string.format("%.1f|%.3f,%.3f,%.3f,%.3f|%s%s", tonumber(Dmg) or 0, R or 1, G or 1, B or 1,
        Al or 1, Flags or "m", Pt), Target, 1)
end

-- Gast: Treffer-Feedback lokal (gleiche Felder wie ui_hit)
function M.Hit(Dmg, R, G, B, Al, Flags, Loc)
    if #U.HitQ >= 20 then return false end
    Flags = Flags or "m"
    local L = type(Loc) == "table" and Loc or {}
    U.HitQ[#U.HitQ + 1] = { Dmg = tonumber(Dmg) or 0, R = R or 1, G = G or 1, B = B or 1, A = Al or 1,
        M = Flags:find("m", 1, true) ~= nil, D = Flags:find("d", 1, true) ~= nil,
        X = tonumber(L.X), Y = tonumber(L.Y), Z = tonumber(L.Z) }
    return true
end

-- Gast: Clan-Chatzeile anzeigen (optional fuer andere Module; clan_msg selbst zeigt ls_clan an)
function M.ClanMsg(Name, Text)
    if Net.Side ~= "client" or #U.ClanQ >= 20 then return false end
    Text = tostring(Text or "")
    if Text == "" then return false end
    U.ClanQ[#U.ClanQ + 1] = { N = tostring(Name or "Clan"):sub(1, 40), T = Text:sub(1, 600) }
    return true
end

-- Uebernimmt ls_ui ein Feature? main.lua schaltet damit den Legacy-Aufruf ab ("ammo", "map")
-- Ist die Aufgabe ui_fast (fuehrt ammo/map/pause aus) wegen Fehlern Down, gilt das Feature als nicht uebernommen.
function M.Owns(What)
    if Core.Down.ui_fast or not Core.Tasks.ui_fast then return false end
    if What == "ammo" then return F.On("ui_ammo") end
    if What == "map" then return F.On("ui_map") end
    if What == "pause" then return F.On("ui_pause") end
    return false
end

function M.ClientTick(Now)
    F.Run("ui_lvl", F.LevelPoll)
    F.Run("ui_day", F.DayBanner)
end

function M.Init(Api)
    A = Api
    Net.Cap("ui_note2", F.On("ui_note"))
    Net.Cap("ui_cvar", F.On("ui_cvars"))
    Net.Cap("ui_cmb", F.On("ui_music"))
    Net.Cap("ui_rsp", F.On("ui_respawn"))
    Net.Cap("ui_hit", F.On("ui_hit"))
    Net.Cap("ui_cwp", F.On("ui_clanwp"))
    -- clan_msg behandelt ls_clan (M.Handlers.clan_msg -> Chatfenster); kein zweiter Handler hier (sonst doppelte Zeile)
    Core.Every("ui_fast", 0.1, F.ClientFast)
    Core.Every("ui_note", 0.2, function(Now)
        if Net.Side == "host" and Core.Flag("ui_v2", true) and not F.Loading() then F.Run("ui_note", F.HostNotes, Now) end
    end)
    Core.Every("ui_host", 0.5, F.Host)
    Core.Every("ui_slow", 1.0, F.Slow)
    Net.OnEvent("gone", function(Peer)
        if Peer and Peer.Key then U.HostSeen[Peer.Key] = nil end
    end)
    A.TestCommands.ui_note = function(Arg)
        local Text = (Arg and Arg ~= "") and Arg or "LastSignal Testhinweis"
        A.TestLog("ui_note: %s", tostring(M.Note("all", Text, "", true)))
    end
    A.TestCommands.ui_state = function()
        local Cv = 0
        for _ in pairs(U.CvOrig) do Cv = Cv + 1 end
        local Mates = 0
        for _ in pairs(U.Mates) do Mates = Mates + 1 end
        local Wp, WpIn = 0, 0
        for _, S in pairs(U.CwpShown) do Wp = Wp + #S.Paths end
        for _ in pairs(U.CwpIn) do WpIn = WpIn + 1 end
        A.TestLog("ui: Seite=%s note2=%s cvOrig=%d cmb=%s rsp=%s marks=%d mates=%d clan=%s cwp=%d/%d cwpHost=%d patch=%s/%s",
            tostring(Net.Side), tostring(Net.Has("ui_note2")), Cv, tostring(U.Cmb), tostring(U.Rsp),
            #(U.Marks or {}), Mates, tostring(U.ClanSig), Wp, WpIn, U.CwpHostN,
            tostring(U.Patch.ui_savelock), tostring(U.Patch.ui_checkcombat))
    end
    Log("geladen (ui_v2=%s)", tostring(Core.Flag("ui_v2", true)))
end

return M
