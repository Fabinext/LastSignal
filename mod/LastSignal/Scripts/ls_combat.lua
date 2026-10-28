-- Last Signal, Runde 5: Kampf v2 (WP10). Host und Gast in einem Modul, Befunde: _NetTest\analysis\findings\combat.md
--   Kill-Credit    Host: Kills/XP, die beim Geist (Spieler 0) landen, auf den Gast umbuchen (10 Hz Poll, kein Hook)
--   Skills         Host: PassiveSkillsComponent der Gast-Waffen = Komponente des Gast-PCs (Multiplikator, Marksmanship-XP)
--   Falloff        Host: ShotDistance der Gast-Schusswaffe aus einem Trace entlang der Gast-Blickrichtung
--   Einschlaege    Schuetze meldet Einschlagpunkt, Host verteilt, Zuschauer spawnen nur FX (Trace_* nie aufrufen!)
--   Hitmarker      Gast zeigt Hitmarker selbst (Spiel ruft ihn nur auf dem Host auf)
--   Wurf/Projektil Gast meldet seinen lokalen Wurfkoerper, Host spawnt die autoritative Kopie, Zuschauer Sicht-Kopien
--   Explosionen    Faesser/Minen: Host meldet, Gast-Explosionen werden beim Host ausgeloest
--   Haltbarkeit    Host ruft ReduceDurability auf seiner Kopie der Gast-Waffe je Schuss
--   Nahkampf       Clients treffen lokal nichts mehr (MaxActorsToHitInSwing?=0), nur der Host
--   PvP (Runde 7)  pvp/clan_ff: Clients lassen eigene Waffen-Traces nur durch geschuetzte Figuren gehen (pvp=0: alle,
--                  pvp=1: Clan-Kameraden); Host: Allies-Karte an die DLL (ffblock auf ApplyDamage), PvP-Kill-Credit
--   Aufsaetze      fremde/Gast-Waffen mit fehlenden Aufsaetzen: OnRep_RepAttachments -> ProcessAttachments
--   Owner-Trick    Host (4 Hz Poll): Gastwaffen, Baeume/Muell ohne Owner in 6 m und Gast-Wurfkoerper bekommen die
--                  Gastfigur als Owner -> DLL loest GetPlayerX(0) (Ernte, Schrott, Granaten-Kills) auf den Gast auf;
--                  Pre-Hook HitFoliageTree/HitTrashObject: Owner = Schlaeger; Steine nur ueber die Waffen-Kette
--   UE 5.6         Decode analysis56: Rakete/Granate ohne ReceiveBeginPlay (Hook auf UserConstructionScript),
--                  Waffen-Trace-Kanal 5 -> 6, Treffer-Sounds FleshImpact/FleshHeadshot, Rohrbombe zerstoert sich nicht
--                  mehr selbst (Explosion ueber Zuender-Zeit), Armbrust-Bolzen trifft per SERVER_DamageEvent (keine
--                  Host-Kopie noetig), Coyote-Soldaten zaehlen wie Militaer ueber CastToController (Geist-Diff)
--   Nahkampf-Relay  Gast meldet eigene Treffer (DLL unterdrueckt lokale Hit*-Aufrufe und zeichnet sie auf), Host prueft
--                  und ruft dieselbe Hit*-Funktion auf seiner Kopie der Gastwaffe
--   Runde 9        Waffe in der Hand ueber RepActorsData (5.6), Schuss-Diagnose/-Kette (DLL), Slot-Reparatur,
--                  cb_sde (Falloff-Abstand, Server-Hitmarker, Treffer-Pruefung), Objektschaden-Relay (cb_od),
--                  Haltbarkeit (cb_dur), Raid-Meldungen an ls_build, Kampf-Markierung, Hook-Koerper ohne UFunctions;
--                  Glasflasche, Armbrust-Bolzen (cb_bolt), HoldingFirearm?-Reparatur, Kill-Feed (cb_kf), Clan-Hinweis,
--                  MultiHit-Merker, Aufraeumen (M.Janitor), statische Owner-Lagen
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local Native = require("ls_native")
local A           -- Coop.API

local U, H, C = {}, {}, {}   -- Hilfen, Host, Client (alles in Tabellen: wenige Hauptchunk-Locals)
M.U, M.H, M.C = U, H, C

local function Log(fmt, ...) A.Log("[Kampf] " .. fmt, ...) end

-- Schalter (coop.txt), alle Standard an (PvP-Schalter siehe U.PvpMode)
U.FLAGS = {
    "combat_v2", "combat_credit", "combat_skills", "combat_falloff", "combat_impacts", "combat_hitmarker",
    "combat_proj", "combat_proj_hook", "combat_boom", "combat_durability", "combat_melee_guard",
    "combat_attach_remote", "combat_xppopup", "combat_mine_sync", "combat_proj_check",
    "combat_owner_weapons", "combat_owner_world", "combat_owner_proj",
    "combat_credit_scale", "combat_credit_sp", "combat_infcredit",   -- Runde 8 (Geist-Diff-Rueckfall)
    "combat_boom_fuse",                                               -- UE 5.6: Rohrbombe bleibt nach der Explosion liegen
    "combat_mrelay", "combat_mrelay_excl", "combat_mrelay_power", "combat_mrelay_fx",   -- Nahkampf-Relay (UE 5.6)
    "combat_mrelay_hafix", "combat_mrelay_strict", "combat_mrelay_los", "combat_mrelay_notify", -- Relay-Pruefungen
    "combat_fire_diag",                                               -- Gast: Schuss-Diagnose (nur lesen)
    "combat_mrelay_yield",                                            -- Host: Relay-Ertrag Boden -> Gastinventar
    -- Runde 9 (Fix-Runde 24.10.), Standard an
    "combat_hand_v2", "combat_fire_trace", "combat_fire_slotfix", "combat_owner_hitq", "combat_raidboom",
    "combat_raidswing", "combat_sd_native", "combat_hit_server", "combat_hitcheck", "combat_dur_v2", "combat_objdmg",
    "combat_bolt", "combat_hold_fix", "combat_mrelay_los_r", "combat_killfeed", "combat_multihit_restore",
    "combat_ff_note", "combat_own_cache",                             -- Runde 9 (combat-2)
    "combat_od_batch", "combat_dead_pawn",                            -- Abschluss-Runde (closeout)
}
-- Runde 9, Standard aus (nur mit coop.txt-Eintrag 1): combat_fire_diag_note, combat_hitcheck_deny, combat_dur_gate,
-- combat_killfeed_pve
function U.On(Name)
    if not Core.Flag("combat_v2", true) then return false end
    if Name == "combat_v2" then return true end
    return Core.Flag(Name, true) and true or false
end
-- Schalter mit Standard aus (Runde 9: Anti-Cheat/Sperren erst nach einem sauberen Live-Test scharf)
function U.Opt(Name)
    return Core.Flag("combat_v2", true) and Core.Flag(Name, false) and true or false
end

-- PvP-Politik (Runde 7). Der alte Schalter friendly_fire (bis Runde 6, Standard 0) wird nicht mehr gelesen:
--   friendly_fire=0 (alt)  ->  pvp=0            niemand trifft Spieler: Gaeste lassen Traces durch ALLE fremden Figuren
--                                              (Host setzt KEIN ffblock: ApplyDamage ist auch der Weg fuer Zombie-,
--                                              Sturz-, Blut- und Ertrinkschaden, ein Pauschal-Block waere Gottmodus)
--   friendly_fire=1 (alt)  ->  pvp=1 clan_ff=1  alle treffen alle (kein Trace-Ignore, kein ffblock)
--   Standard Runde 7       ->  pvp=1 clan_ff=0  Fremde treffbar, Clan-Kameraden geschuetzt: Gast-Trace-Ignore nur fuer
--                                              Kameraden (Coop.Clan.IsMatePid), Host: ffblock + Native.SetAllies
-- Rueckgabe "off" | "clan" | "all". Core.Down.pvp (Fehler) oder profile=legacy -> "off" (altes Verhalten).
function U.PvpMode()
    if not Core.Flag("pvp", true) then return "off" end
    return Core.Flag("clan_ff", false) and "all" or "clan"
end
U.PVP_MODES = { off = true, clan = true, all = true }
-- Fehler zaehlen auf "pvp"; einmal "aus" melden (Down -> U.PvpMode() = "off")
function U.PvpFail(What, Err)
    if Core.Fail("pvp", Err) and not U.PvpDownLogged then
        U.PvpDownLogged = true
        Log("PvP aus (%s): %s - zurueck zu pvp=0", What, tostring(Err))
    end
end
-- Gast: Politik des Hosts (cb_pvp), bis sie ankommt die eigene coop.txt
function U.ClientPvpMode()
    local V = Net.Get("cb_pvp", "m")
    if U.PVP_MODES[V] then return V end
    return U.PvpMode()
end

-- Pfade (aus all_assets.txt / bp_paths.txt)
U.FX = {
    World = "/Game/PolygonFiles/PolygonMilitary/FX/FX_WorldImpact.FX_WorldImpact",
    Body = "/Game/PolygonFiles/PolygonMilitary/FX/FX_BloodBodyImpact.FX_BloodBodyImpact",
    Head = "/Game/PolygonFiles/PolygonMilitary/FX/FX_BloodHeadshot.FX_BloodHeadshot",
    Boom = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_New.FX_Explosion_New",
    Decal = "/Game/Meshes/Materials/BulletHoleDecal.BulletHoleDecal",
    -- UE 5.6 (EVT_Trace_BodyImpact @1fd1 / EVT_Trace_Headshot @2091): je ein Cue; die nummerierten 5.3-Cues sind weg
    -- (bleiben als Rueckfall fuer 5.3, Platzhalter %d = Zufallsnummer)
    BodySnd = "/Game/Audio/WARFARE_SOUNDS/Weapons/Bullets/Cues/FleshImpact_Cue.FleshImpact_Cue",
    HeadSnd = "/Game/Audio/Real_Recorded_Guns/Cues/Bullet_Imacts_Flybys/Head_shot/FleshHeadshot_Cue.FleshHeadshot_Cue",
    BodySnd53 = "/Game/Audio/WARFARE_SOUNDS/Weapons/Bullets/Cues/bullet_impact_body_thump_0%d_Cue.bullet_impact_body_thump_0%d_Cue",
    HeadSnd53 = "/Game/Audio/Real_Recorded_Guns/Cues/Bullet_Imacts_Flybys/Head_shot/Head_shot_%d_Cue.Head_shot_%d_Cue",
    BoomSnd = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue",
}

-- Wurfkoerper/Projektile: Pfad, Schadensfelder (auf Kopien ohne Autoritaet = 0), Zuender-Funktion, explodiert?
-- UE 5.6: Schaden = DmgToDo, erst beim Zuenden/Treffer aus Min/Max berechnet (Frag @02c7 CalculateDmg, Rakete @084d,
-- Granate @08ad) -> Min/Max = 0 reicht weiterhin. Hook = Spawn-Funktion fuer den Gast-Hook (Rakete/Granate haben in
-- 5.6 kein ReceiveBeginPlay mehr, nur UserConstructionScript). Stays = Actor bleibt nach der Explosion bestehen
-- (5.6 Rohrbombe: kein K2_DestroyActor mehr im Ubergraph) -> Host meldet die Explosion nach Zuender-Zeit.
-- Armbrust-Bolzen (BP_ProjectileArrow_C) bewusst NICHT hier: trifft ueber WeaponOwner->SERVER_DamageEvent (@0532/@070a,
-- wie Kugeln) und spawnt beim Treffer einen BP_BoltAmmoPickup (@0585) - eine Host-/Sicht-Kopie gaebe doppelte Bolzen.
U.PROJ = {
    BP_Throwable_Frag_C = { Path = "/Game/Blueprints/Throwables/BP_Throwable_Frag.BP_Throwable_Frag_C",
        Dmg = { "MinDamage", "MaxDamage" }, Fuse = "Frag", Throw = true, Boom = true },
    BP_Throwable_PipeBomb_C = { Path = "/Game/Blueprints/Throwables/BP_Throwable_PipeBomb.BP_Throwable_PipeBomb_C",
        Dmg = { "MinDamage", "MaxDamage" }, Fuse = "PipeBomb", Throw = true, Boom = true, Stays = true },
    BP_Throwable_Molotov_C = { Path = "/Game/Blueprints/Throwables/BP_Throwable_Molotov.BP_Throwable_Molotov_C",
        Dmg = { "MinDamage", "MaxDamage" }, Throw = true, Boom = false },
    BP_Throwable_NoiseMaker_C = { Path = "/Game/Blueprints/Throwables/BP_Throwable_NoiseMaker.BP_Throwable_NoiseMaker_C",
        Dmg = {}, Fuse = "NoiseMaker", Throw = true, Boom = false },
    -- COMBAT-6 (UE 5.6 neu): Glasflasche ohne Schaden, beim Aufprall ReportNoiseEvent(self, Lage, 1, self, 6000) @01e3
    -- (Instigator = Flasche) -> nur die Host-Kopie lockt die KI. Kein DA_*GlassBottle* (all_assets): Consume = false
    -- schaltet die Verbrauchspruefung fuer diese Klasse ab (schadenlos, Rate 2/s je Gast).
    BP_Throwable_GlassBottle_C = { Path = "/Game/Blueprints/Throwables/BP_Throwable_GlassBottle.BP_Throwable_GlassBottle_C",
        Dmg = {}, Throw = true, Boom = false, Consume = false },
    BP_ProjectileGrenade_C = { Path = "/Game/Inventory/Items/Other/ItemProjectiles/BP_ProjectileGrenade.BP_ProjectileGrenade_C",
        Dmg = { "MinDmg", "MaxDmg" }, Boom = true, Hook = "UserConstructionScript" },
    BP_ProjectileRocket_C = { Path = "/Game/Inventory/Items/Other/ItemProjectiles/BP_ProjectileRocket.BP_ProjectileRocket_C",
        Dmg = { "MinDamage", "MaxDamage", "MinDmg", "MaxDmg" }, Boom = true, Hook = "UserConstructionScript" },
    BP_FlareRoundProjectile_C = { Path = "/Game/Inventory/Items/Other/ItemProjectiles/BP_FlareRoundProjectile.BP_FlareRoundProjectile_C",
        Dmg = { "MinDmg", "MaxDmg" }, Boom = false },
}

-- Sprengbares: FindAllOf kennt nur die genaue Klasse, darum auch die Kind-Klasse
U.EXPL = { { "BP_ExplosiveBarrelMaster_C", "b" }, { "BP_ExplosiveBarrel_Child_C", "b" }, { "BP_Landmine_C", "m" },
           { "Buildable_LandMine_C", "m" } }

-- Draht cb_kills: die ersten U.KILL_WIRE Felder, dann DaysSurvived (Feld 5), dann weitere Felder ab 6 (alte Gaeste
-- lesen nur 1..5). InfestationsDestroyed (BP_PlayerController_C 0x928) zaehlt nur mit combat_infcredit.
U.KILL_FIELDS = { "ZombieKills", "BossZombieKills", "AnimalKills", "HumanKills", "InfestationsDestroyed" }
U.KILL_WIRE = 4
U.INF_FIELD = "InfestationsDestroyed"
U.INF_CLS = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
U.ROLE_AUTHORITY = 3
U.NEAR = 15000          -- 150 m: Einschlaege/Explosionen nur in dieser Naehe zeigen
U.TRACE_CHANNEL = 6     -- TraceTypeQuery-Index von FireTrace/MeleeTrace (UE 5.6: FireTrace @03b0/@0567, MeleeTrace 6; 5.3: 5)
U.BOOMREQ_TOL = 400     -- cb_boomreq: Host-Kopie hoechstens so weit von der gemeldeten Stelle (Fass kann rollen)
U.THROW_MAX = 6000      -- Wurf: GrenadeThrowSpeed <= 3750 + Eigenbewegung
U.PROJ_MAX = 20000      -- Geschoss: harte Obergrenze (sonst MaxSpeed/InitialSpeed der Klasse)
U.MINE_CLS = "BP_Landmine_C"   -- zerstoert sich in ReceiveBeginPlay zufaellig (je Maschine) -> Host-Satz gilt
U.MINE_R = 9000         -- Gast gleicht nur Minen in diesem Umkreis um den Host-Bezugspunkt ab (Host-Scan: 20000)

-- ===================================================================== Hilfen

function U.Find(Path)
    if not Path then return nil end
    local O = A.Safe(function() return StaticFindObject(Path) end, nil)
    if O and A.IsAlive(O) then return O end
    return nil
end

function U.Path(Obj)
    local Full = A.Safe(function() return Obj:GetFullName() end, nil)
    if not Full then return nil end
    return Full:match("^%S+%s+(.+)$") or Full
end

function U.Name(Obj) return A.Safe(function() return Obj:GetFName():ToString() end, "?") end

function U.Loc(Actor)
    local L = Actor:K2_GetActorLocation()
    return { X = L.X, Y = L.Y, Z = L.Z }
end

function U.Dist(P, Q)
    local DX, DY, DZ = P.X - Q.X, P.Y - Q.Y, P.Z - Q.Z
    return math.sqrt(DX * DX + DY * DY + DZ * DZ)
end

-- Klassen-Kette (je Klasse gemerkt): ist Obj ein <ClassName> oder davon abgeleitet?
U.IsACache = {}
function U.IsA(Obj, ClassName)
    local Class = Obj:GetClass()
    local Key = U.Name(Class) .. "|" .. ClassName
    if U.IsACache[Key] == nil then
        local Found, K = false, Class
        while K and K:IsValid() do
            if K:GetFName():ToString() == ClassName then Found = true break end
            K = K:GetSuperStruct()
        end
        U.IsACache[Key] = Found
    end
    return U.IsACache[Key]
end

U.Assets = {}      -- CORE-19: ungenutzt (frueher UObject-Cache), bleibt fuer aeltere Leser leer
U.AssetMiss = {}   -- [Pfad] = os.clock des letzten Fehlschlags (60 s kein neuer LoadAsset, z. B. 5.6-Pfad unter 5.3)
-- CORE-19: keine UObjects ueber Ticks halten (GC alle ~61 s) - jedes Mal StaticFindObject (Hash), sonst LoadAsset
-- mit Fehlschlag-Drossel
function U.Asset(Path)
    if not Path then return nil end
    local Asset = U.Find(Path)
    if Asset then return Asset end
    local Miss = U.AssetMiss[Path]
    if Miss and os.clock() - Miss < 60 then return nil end
    local ok, Loaded = pcall(LoadAsset, Path)
    if ok and Loaded and A.IsAlive(Loaded) then
        U.AssetMiss[Path] = nil
        return Loaded
    end
    U.AssetMiss[Path] = os.clock()
    return nil
end

function U.GS() return A.UEHelpers.GetGameplayStatics() end
function U.KSL() return A.UEHelpers.GetKismetSystemLibrary() end

-- Blickrichtung aus einem Rotator (Grad)
function U.Forward(R)
    local P, Y = math.rad(R.Pitch), math.rad(R.Yaw)
    return { X = math.cos(P) * math.cos(Y), Y = math.cos(P) * math.sin(Y), Z = math.sin(P) }
end

function U.RotFromDir(D)
    local Len = math.sqrt(D.X * D.X + D.Y * D.Y)
    return { Pitch = math.deg(math.atan(D.Z, Len)), Yaw = math.deg(math.atan(D.Y, D.X)), Roll = 0 }
end

-- FRotator::Quaternion (UE)
function U.Quat(R)
    local H2 = math.pi / 360
    local SP, CP = math.sin(R.Pitch * H2), math.cos(R.Pitch * H2)
    local SY, CY = math.sin(R.Yaw * H2), math.cos(R.Yaw * H2)
    local SR, CR = math.sin(R.Roll * H2), math.cos(R.Roll * H2)
    return { X = CR * SP * SY - SR * CP * CY, Y = -CR * SP * CY - SR * CP * SY,
             Z = CR * CP * SY - SR * SP * CY, W = CR * CP * CY + SR * SP * SY }
end

function U.Split(Text)
    local Out = {}
    for Part in (Text or ""):gmatch("([^;]*);?") do
        if #Out > 32 then break end
        Out[#Out + 1] = Part
    end
    return Out
end

function U.Vec(Parts, I)
    local X, Y, Z = tonumber(Parts[I]), tonumber(Parts[I + 1]), tonumber(Parts[I + 2])
    if not (X and Y and Z) then return nil end
    if math.abs(X) > 5e7 or math.abs(Y) > 5e7 or math.abs(Z) > 5e7 then return nil end
    return { X = X, Y = Y, Z = Z }
end

function U.Fmt(V) return string.format("%.0f;%.0f;%.0f", V.X, V.Y, V.Z) end

-- Einfache Rate: hoechstens N je Sekunde und Schluessel
U.RateTab = {}
function U.Rate(Key, N)
    local Now, E = os.clock(), U.RateTab[Key]
    if not E or Now - E.T >= 1 then E = { T = Now, N = 0 } U.RateTab[Key] = E end
    if E.N >= N then return false end
    E.N = E.N + 1
    return true
end

function U.Attached(Pawn)
    local Out, List = {}, {}
    if not pcall(function() Pawn:GetAttachedActors(List, true, false) end) then return Out end
    for _, Entry in ipairs(List) do
        local W = A.Safe(function() return Entry:get() end, nil)
        if W and A.IsAlive(W) then Out[#Out + 1] = W end
    end
    return Out
end

-- UE 5.6 (combat_hand_v2, COMBAT-3): Waffe in der Hand nach Spiel-Sicht wie BP_JigHelperComp_C.GetActiveWeapon
-- (@0000-@01d1): RepActorsData[Slot == ActiveWeapon].Actor (beide repliziert). Der Socket "*_r" taugt in 5.6 nicht
-- (Live 24.10. 01:46:58: HoldingFirearm?/IsADS? an, die Socket-Suche fand nie eine Schusswaffe).
-- Rueckgabe: Waffe|nil, Slot-Tag|nil, Lesbar (true = Jig/ActiveWeapon gelesen; Slot leer = nichts in der Hand)
U.REP_SLOT, U.REP_ACTOR = "Slot_4_8843E80049E14A7C56C7E89EF659AAEC", "Actor_5_6FDDEF454801C671BE34D7B2377175C5"
function U.ActiveWeapon(Pawn)
    if not (Pawn and A.IsAlive(Pawn)) then return nil, nil, false end
    local Jig = A.Safe(function() return Pawn.BP_JigHelperComp end, nil)
    if not (Jig and A.IsAlive(Jig)) then return nil, nil, false end
    local Slot = A.Safe(function() return Jig.ActiveWeapon.TagName:ToString() end, nil)
    if Slot == nil then return nil, nil, false end
    if Slot == "" or Slot == "None" then return nil, nil, true end
    local Found = nil
    pcall(function()
        Jig.RepActorsData:ForEach(function(_, E)
            local Row = E:get()
            if A.Safe(function() return Row[U.REP_SLOT].TagName:ToString() end, nil) == Slot then
                local W = A.Safe(function() return Row[U.REP_ACTOR] end, nil)
                if W and A.IsAlive(W) then Found = W end
                return true
            end
        end)
    end)
    return Found, Slot, Found ~= nil
end

-- Einmal je Waffe (Name) loggen: Klasse, Slot, Socket - klaert den 5.6-Ausruestungs-Socket (EquipSocket des DA)
function U.HandLog(W, Slot)
    local Name = U.Name(W)
    U.HandSeen = U.HandSeen or {}
    if U.HandSeen[Name] then return end
    if (U.HandSeenN or 0) >= 64 then U.HandSeen, U.HandSeenN = {}, 0 end
    U.HandSeen[Name], U.HandSeenN = true, (U.HandSeenN or 0) + 1
    local Socket = A.Safe(function() return W:GetAttachParentSocketName():ToString() end, "?")
    Log("Waffe in der Hand: %s, Slot %s, Socket %s", Name, tostring(Slot), tostring(Socket))
end

-- Schusswaffe in der Hand. combat_hand_v2: aktive Waffe des Spiels (andere Waffe/leer = nil), nur wenn RepActorsData
-- nicht lesbar ist (kein Jig, Slot ohne gueltigen Actor) der alte Socket-Weg. Alt: Hand-Socket "*_r", mehrere: die
-- CurrentFiringWeapon.
function U.HandFirearm(Pawn)
    if U.On("combat_hand_v2") then
        local okA, W, Slot, Read = pcall(U.ActiveWeapon, Pawn)
        if okA and W then
            pcall(U.HandLog, W, Slot)
            if A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then return W end
            return nil
        end
        if okA and Read then return nil end      -- Slot leer: nichts in der Hand
    end
    local Current = A.Safe(function() return Pawn.CurrentFiringWeapon end, nil)
    local CurAddr = Current and A.IsAlive(Current) and Current:GetAddress() or nil
    local Found
    for _, W in ipairs(U.Attached(Pawn)) do
        local Socket = A.Safe(function() return W:GetAttachParentSocketName():ToString() end, "")
        if A.Coop.IsHandSocket(Socket) and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then
            if CurAddr and W:GetAddress() == CurAddr then return W end
            Found = Found or W
        end
    end
    return Found
end

-- Komponente: erst als Property, sonst ueber die Klasse (Coop.Scope.Comp)
function U.Comp(Actor, Prop, ClassName)
    local Comp = A.Safe(function() return Actor[Prop] end, nil)
    if Comp and A.IsAlive(Comp) then return Comp end
    local Scope = A.Coop.Scope
    if Scope and Scope.Comp then
        Comp = A.Safe(function() return Scope.Comp(Actor, ClassName) end, nil)
        return A.IsAlive(Comp) and Comp or nil
    end
    return nil
end

function U.Loading()
    local W = A.WorldGen
    return W and W.Loading and os.clock() - (W.LoadingAt or 0) < 60
end

-- Weltwechsel: alle Caches verwerfen (nur Namen/Pfade, keine UObjects ausser Assets)
function U.CheckWorld()
    local N = A.WorldGen and A.WorldGen.N or 0
    if U.Gen == N then return end
    U.Gen = N
    U.Expl, U.ExplIdx, U.Assets, U.ExplSkip, C.HostMines = {}, 0, {}, {}, nil
    H.Proj, H.Recent, H.Base, H.DeadSeen, H.Weap, H.ShotBase, H.Att, H.TimerOn = {}, {}, nil, {}, {}, {}, {}, {}
    H.InfQ = {}
    H.ProjAmmo, H.OwnCache, H.OwnSeen, H.OwnSeenN = {}, {}, {}, 0
    C.Own, C.Visual, C.VisualGid, C.Queue, C.LocalBoom, C.HostBoom, C.Att, C.FF, C.LastSD = {}, {}, {}, {}, {}, {}, {}, {}, nil
    -- Nahkampf-Relay: nur Pfade/Adressen/Zeiten; Schlag-Zaehler (H.MRelSw) und Nachweis (H.MRelProven) haengen an der Epoche
    C.MRelOwnW, C.MRelOrig, C.MSeen, C.MRelOut = {}, {}, {}, {}
    H.MNat, H.MRelFelled, H.MRelLastT, H.MRelCache, H.MRelTreeHP, H.MRelQ = {}, {}, {}, {}, {}, {}
    H.MRelYield = {}
    -- Runde 9: Warteschlangen/Adressen der alten Welt verwerfen (Sperrlisten leert ls_native beim Weltwechsel selbst)
    H.HitQ, H.OdQ, H.SdeDeny, H.SdeDenyN, H.SdDistAt, H.MRelPawns = {}, {}, {}, nil, nil, {}
    -- Review R1: gesperrte Waffen der alten Welt sind weg -> Menge nur leeren (kein FireReady-Zugriff)
    C.SlotBad, C.DurBlockedSet, U.HandSeen, U.HandSeenN = nil, {}, {}, 0
    -- Runde 9, combat-2: Bolzen, Kill-Feed, Relay-Ertrag-Zeit, statische Owner-Lagen (nur Pfade/Adressen/Zeiten)
    H.BoltQ, H.BoltUsed, H.LastDmgOn, H.KfHead, H.KfDead, H.MRelYieldAt = {}, {}, {}, {}, {}, {}
    H.KfPend, H.PvpPend = {}, {}       -- Review R1 (combat_kf_defer): wartende Tode der alten Welt verwerfen
    H.OwnPos, H.OwnGone = {}, {}
    C.BoltQ, C.Arrows, C.BoltDone, C.KfQ, C.HoldBad, C.HoldLast = {}, {}, {}, {}, nil, nil
    H.LastPawnP, C.OdCarry = {}, {}    -- Abschluss-Runde: gemerkte Gastfiguren (combat_dead_pawn), Objektschaden-Uebertrag
end

-- Owner (optional, nur Host): Werfer-Figur, damit GetPlayerX(0) im Wurfkoerper-Code auf den Gast aufloest
function U.Spawn(Ctx, Cls, Loc, Rot, Prepare, Owner)
    local Info = U.PROJ[Cls]
    local Class = Info and (U.Find(Info.Path) or U.Asset(Info.Path))
    if not Class then return nil end
    local T = { Translation = Loc, Rotation = U.Quat(Rot), Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GS = U.GS()
    local R = GS:BeginDeferredActorSpawnFromClass(Ctx, Class, T, 1, Owner, 0)
    if not (R and A.IsAlive(R)) then return nil end
    if Prepare then pcall(Prepare, R, Info) end
    GS:FinishSpawningActor(R, T, 0)
    return R, Info
end

-- Geschwindigkeit setzen und Zuender starten (wie das Spiel nach FinishSpawningActor)
function U.Launch(R, Info, Vel)
    if Info.Throw then
        local Cap = A.Safe(function() return R.Capsule end, nil)
        if A.IsAlive(Cap) then pcall(function() Cap:SetPhysicsLinearVelocity(Vel, false, FName("None")) end) end
        if Info.Fuse then pcall(function() R[Info.Fuse](R) end) end
    else
        local Speed = math.sqrt(Vel.X * Vel.X + Vel.Y * Vel.Y + Vel.Z * Vel.Z)
        local PM = A.Safe(function() return R.ProjectileMovement end, nil)
        if Speed > 1 and A.IsAlive(PM) then pcall(function() PM:SetVelocityInLocalSpace({ X = Speed, Y = 0, Z = 0 }) end) end
    end
end

function U.ZeroDamage(R, Info)
    for _, Field in ipairs(Info.Dmg or {}) do pcall(function() R[Field] = 0 end) end
end

-- Effekte (Zuschauer/Explosionen): nur Emitter/Decal/Ton, nie Trace_*/Event_Explode (die machen Schaden/RPCs)
function U.Emitter(Path, Loc, Rot, Scale)
    local Fx = U.Asset(Path)
    if not Fx then return end
    local World = A.CurrentWorld()
    U.GS():SpawnEmitterAtLocation(World, Fx, Loc, Rot, { X = Scale, Y = Scale, Z = Scale }, true, 0, true)
end

function U.Sound(Path, Loc)
    local Snd = U.Asset(Path)
    if not Snd then return end
    U.GS():PlaySoundAtLocation(A.CurrentWorld(), Snd, Loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1, 1, 0, nil, nil, nil, nil)
end

function U.NearOwn(Loc, Range)
    local Pawn = A.Safe(A.OwnPawn, nil)
    if not (Pawn and A.IsAlive(Pawn)) then return false end
    return U.Dist(U.Loc(Pawn), Loc) <= Range
end

-- Native Dienste (LastSignalCore.dll, N4b, API_NATIVE.md): Native.Watch(Liste, Besitzer), Native.Events(Cursor).
-- Der Beobachter sieht nur Aufrufe aus Blueprint-Bytecode (Aufrufstelle), nie ProcessEvent: RPC-Ankunft
-- (SERVER_DamageEvent beim Host, MC_SpawnTrail/Client_HitUI beim Gast) und ReceiveBeginPlay (aus C++) sind
-- unsichtbar. Genutzt wird darum nur cb_dmg = GameplayStatics:ApplyDamage, aufgerufen im SERVER_DamageEvent-Zweig
-- der Waffe auf dem Host (Caller = Waffe, Args[1] = getroffener Actor, Args[4] = DamageCauser = Figur).
U.NATIVE_DMG = { { Func = "/Script/Engine.GameplayStatics:ApplyDamage", Tag = "cb_dmg", Mode = "observe" } }
-- PvP mit Clan-Schutz: dieselbe Beobachtung plus Vor-Aktion ffblock. Die DLL (cfg pvp=1) ueberspringt den Aufruf nur,
-- wenn Ziel-Figur und Figur des Causers (Owner-Kette bis 4 Schritte) denselben Clan-Index != 0 aus Native.SetAllies
-- haben; Zombies/Tiere/Fallen (Causer keine Spielerfigur) und Selbstschaden (Causer null) laufen normal durch.
U.NATIVE_DMG_FF = { { Func = "/Script/Engine.GameplayStatics:ApplyDamage", Tag = "cb_dmg", Mode = "observe",
                      Pre = { ffblock = true } } }
function U.NativeOn()
    return type(Native.Watch) == "function" and type(Native.Events) == "function"
end
-- Host: Clan-Schutz ueber die DLL moeglich und gewollt (pvp=1, clan_ff=0, Allies-Schnittstelle vorhanden)
function U.HostFF()
    return U.PvpMode() == "clan" and U.NativeOn() and type(Native.SetAllies) == "function"
end
-- Host: gewuenschte ApplyDamage-Beobachtung: nil (keine) | "obs" (Kill-Zuordnung, Kill-Feed, Kampf-Markierung)
-- | "ff" (plus Clan-Schutz)
function U.WatchWanted()
    if Net.Side ~= "host" or not U.NativeOn() or not U.On("combat_v2") then return nil end
    if U.HostFF() then return "ff" end
    -- Abschluss-Runde: cb_dmg brauchen auch der Kill-Feed (H.KfHit) und die PLAYER-13-Kampf-Markierung (H.TagVictim ->
    -- main.lua Coop.InCombat fuer pvp_hbdmg/pvp_logout), nicht nur der Kill-Credit; Gutschrift bleibt an combat_credit
    -- gebunden (H.Fast/H.PvpTick)
    local Want = U.On("combat_credit") or U.On("combat_killfeed")
        or (U.PvpMode() ~= "off" and (Core.Flag("pvp_hbdmg", true) or Core.Flag("pvp_logout", false)))
    return Want and "obs" or nil
end

-- Ereignisse eines Tags; eigener Cursor je Tag (Native.Events liefert alle Tags seit dem letzten Aufruf)
function U.NativeEvents(Tag)
    if not U.NativeOn() then return {} end
    -- "_"-Praefix = Cursor ueber alle Tags (ls_native.ReadEvents); ohne "_" waere der Name ein Tag-Filter
    local ok, List = pcall(Native.Events, "_ls_combat_" .. Tag)
    if not ok or type(List) ~= "table" then return {} end
    local Out = {}
    for _, Ev in ipairs(List) do
        if Ev.Tag == Tag and type(Ev.Args) == "table" then Out[#Out + 1] = Ev end
    end
    return Out
end

-- "<Klasse> <Pfad>" -> Pfad (false/nil/"0x.." -> nil)
function U.EvPath(V)
    return type(V) == "string" and V:match("^%S+ (.+)$") or nil
end

-- ===================================================================== Host

-- Gast -> Figur/PC frisch (nie speichern)
function H.PawnPC(G)
    local PC = Net.PC(G)
    if not PC then return nil, nil end
    local Pawn = A.Safe(function() return PC:K2_GetPawn() end, nil)
    if not (Pawn and A.IsAlive(Pawn)) then return nil, PC end
    return Pawn, PC
end

-- 1 Hz: Waffen der Gaeste merken (Pfade), Skills binden, Aufsaetze, Haltbarkeit
function H.ScanWeapons(Now)
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        local Pawn, PC = H.PawnPC(G)
        if not Pawn then H.Weap[Key] = nil return end
        local Entry = { Pawn = U.Path(Pawn), Hand = nil, List = {} }
        H.LastPawnP[Key] = Entry.Pawn            -- Abschluss-Runde (combat_dead_pawn): Figur fuer den Tod merken
        local Hand = U.HandFirearm(Pawn)
        if Hand then Entry.Hand = U.Path(Hand) end
        for _, W in ipairs(U.Attached(Pawn)) do
            local Fire = A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false)
            local Melee = not Fire and A.Safe(function() return U.IsA(W, "BP_MeleePickup_C") end, false)
            if Fire or Melee then
                Entry.List[#Entry.List + 1] = U.Path(W)
                if U.On("combat_skills") then H.BindSkills(W, PC, Key) end
                if Fire and U.On("combat_attach_remote") then C.FixAttach(W, Now, H.Att) end
                if Fire and Hand and U.On("combat_durability") and W:GetAddress() == Hand:GetAddress() then
                    H.Durability(W, Key, Now, Pawn)
                end
            end
        end
        H.Weap[Key] = Entry
    end)
end

function H.BindSkills(W, PC, Key)
    local Comp = A.Safe(function() return PC.PassiveSkillsComponent end, nil)
    if not (Comp and A.IsAlive(Comp)) then return end
    local Cur = A.Safe(function() return W.PassiveSkillsComponent end, nil)
    if Cur and A.IsAlive(Cur) and Cur:GetAddress() == Comp:GetAddress() then return end
    local ok, err = pcall(function() W.PassiveSkillsComponent = Comp end)
    if ok then
        Log("Skills: Waffe %s rechnet jetzt mit den Faehigkeiten von %s", U.Name(W), Key:match("[^.:]+$") or Key)
    elseif Core.Fail("combat_skills", err) then Log("Skills-Bindung aus: %s", tostring(err)) end
end

-- Schuesse je Waffe: Coop.Shot.ServerShots[Adresse] (Integration), sonst gemeldete cb_shots des Gasts
function H.Durability(W, Key, Now, Pawn)
    local Addr = W:GetAddress()
    local Shot = A.Coop.Shot
    local N = 0
    if Shot and Shot.ServerShots then                 -- Host zaehlt selbst (MC_WeaponEffects je Schuss)
        H.Reported[Key] = 0
        local Count = Shot.ServerShots[Addr] or 0
        local Base = H.ShotBase[Addr]
        H.ShotBase[Addr] = Count
        if Base then N = Count - Base end
    else
        N = H.Reported[Key] or 0
        H.Reported[Key] = 0
    end
    if N <= 0 then return end
    H.ShotAt[Key] = Now
    -- COMBAT-4 (combat_dur_v2): PlayerActiveWeapon der Host-Kopie setzen (sonst UID 0 -> keine Abnutzung), dazu die
    -- Muendungs-Abnutzung (MuzzleDurability, GetOwner -> Gastfigur dank Owner-Trick) wie MuzzleEffects beim Schuetzen
    local V2 = U.On("combat_dur_v2") and Pawn ~= nil
    if V2 then
        local okS, errS = pcall(H.DurSlot, W, Pawn)
        if not okS and Core.Fail("combat_dur_v2", errS) then Log("Haltbarkeit v2 aus: %s", tostring(errS)) V2 = false end
    end
    for _ = 1, math.min(N, 15) do
        local ok, err = pcall(function() W:ReduceDurability({}) end)
        if not ok then
            if Core.Fail("combat_durability", err) then Log("Haltbarkeit aus: %s", tostring(err)) end
            return
        end
        if V2 then pcall(function() W:MuzzleDurability({}) end) end
    end
end
H.Reported = {}

-- 10 Hz: ShotDistance der Gast-Schusswaffe = Trace entlang der Blickrichtung (Kanal wie FireTrace)
function H.Falloff(Now)
    -- COMBAT-11: die DLL schreibt den echten Treffer-Abstand beim Eintritt von SERVER_DamageEvent -> Blick-Trace aus
    if H.SdeFalloffOk(Now) then return end
    for Key, E in pairs(H.Weap) do
        local W = E.Hand and U.Find(E.Hand)
        local G = Net.Guests[Key]
        if W and G then
            local Pawn, PC = H.PawnPC(G)
            if Pawn then
                local D = H.AimDistance(Pawn, PC)
                if not D and H.SD[Key] and Now - H.SD[Key].T < 3 then D = H.SD[Key].V end
                if D and D > 0 then pcall(function() W.ShotDistance = D end) end
            end
        end
    end
end
H.SD = {}

function H.AimDistance(Pawn, PC)
    local Rot = A.Safe(function() return PC:GetControlRotation() end, nil)
    if not Rot then return nil end
    local L = U.Loc(Pawn)
    local F = U.Forward({ Pitch = Rot.Pitch, Yaw = Rot.Yaw })
    -- Augenhoehe, 80 uu vor der Figur (nicht die eigene Waffe treffen)
    local Start = { X = L.X + F.X * 80, Y = L.Y + F.Y * 80, Z = L.Z + 60 + F.Z * 80 }
    local End = { X = Start.X + F.X * 30000, Y = Start.Y + F.Y * 30000, Z = Start.Z + F.Z * 30000 }
    local Hit, Clear = {}, { R = 0, G = 0, B = 0, A = 0 }
    local ok = A.Safe(function()
        return U.KSL():LineTraceSingle(Pawn, Start, End, U.TRACE_CHANNEL, false, {}, 0, Hit, true, Clear, Clear, 0)
    end, false)
    if not ok or not Hit.ImpactPoint then return nil end
    local P = Hit.ImpactPoint
    return U.Dist(Start, { X = P.X, Y = P.Y, Z = P.Z })
end

-- ---------------------------------------------------------------- Kill-Credit (nur dedizierter Host: Geist = Spieler 0)

function H.ReadGhost(PC)
    local S = { K = {} }
    for _, F in ipairs(U.KILL_FIELDS) do S.K[F] = tonumber(PC[F]) or 0 end
    local L = PC.LevellingComponent
    if not A.IsAlive(L) then error("LevellingComponent ungueltig") end
    S.Buffer, S.Cur, S.Level, S.Max = L.BufferXP, L.CurrentXP, L.CurrentLevel, L.CurrentMaxXP
    S.Mult = tonumber(L.MultiplyValue) or 1           -- combat_credit_scale: Kill-XP ~ CurrentLevel * MultiplyValue
    local TT = PC.TechTreeComponent                   -- combat_credit_sp: TechTreeComponent_C.Add (+1 SkillPoints/CurrentPoints)
    if A.IsAlive(TT) then S.SP, S.CP = tonumber(TT.SkillPoints), tonumber(TT.CurrentPoints) end
    return S
end

-- Nur die Felder, die TechTreeComponent_C.Add erhoeht (Add.txt @0045 SkillPoints, @00c1 CurrentPoints), um N zurueck.
-- Schreiben fehlgeschlagen -> Bezugspunkt uebernimmt den Geist-Stand (sonst jede 0,1 s ein neuer Punkt).
function H.RestoreSP(Ghost, B, S, N)
    local TT = A.Safe(function() return Ghost.TechTreeComponent end, nil)
    local ok = A.IsAlive(TT) and S.CP ~= nil
        and pcall(function() TT.SkillPoints, TT.CurrentPoints = S.SP - N, S.CP - N end)
    if ok then S.SP, S.CP = S.SP - N, S.CP - N else B.SP, B.CP = S.SP, S.CP end
end

-- Kill-XP-Formeln sind linear in CurrentLevel*MultiplyValue des Gutgeschriebenen (Zombie XpMultiplierCalc @0083/@00c7,
-- Bandit @01d6/@021a, Haendler @01db/@021f, Boss @0268/@02ac, Befall OnCompleted @281f/@2863): Geist -> Gast umrechnen.
-- UE 5.6 (analysis56): Zombie Death @0675, Bandit/Coyote-Soldat Death @0233/@0277, Haendler @0238, Boss @04cc,
-- Befall @2807 - alle weiter ueber CastToController (= GetPlayerController 0, Geist) und linear.
function H.ScaleXP(PC, B, XP)
    local GL = A.Safe(function() return PC.LevellingComponent end, nil)
    if not A.IsAlive(GL) then return XP end
    local Lv = tonumber(A.Safe(function() return GL.CurrentLevel end, nil))
    local Mu = tonumber(A.Safe(function() return GL.MultiplyValue end, nil)) or 1
    local Den = (tonumber(B.Level) or 0) * (tonumber(B.Mult) or 1)
    if not Lv or Lv < 1 or Mu <= 0 or Den <= 0 then return XP end
    local F = math.max(0.05, math.min(50, Lv * Mu / Den))
    if math.abs(F - 1) < 0.001 then return XP end
    Log("Kill-Credit skaliert: Geist-Stufe %d -> Gast-Stufe %d", math.floor(B.Level), math.floor(Lv))
    return XP * F
end

-- Nur Zaehler und XP-Puffer zuruecksetzen. Level/MaxXP nie schreiben: ein Rueckschreiben dieser Werte (Bezugspunkt
-- aus dem Laden) brachte den Server nativ zum Absturz (Test 22.10.); bei Level-Wechsel bleibt der Geist hochgestuft.
function H.RestoreGhost(PC, B, SameLevel)
    for _, F in ipairs(U.KILL_FIELDS) do pcall(function() PC[F] = B.K[F] end) end
    if not SameLevel then return end
    local L = PC.LevellingComponent
    if not A.IsAlive(L) then return end
    pcall(function() L.BufferXP, L.CurrentXP = B.Buffer, B.Cur end)
end

-- Bezugspunkt erst, wenn ein Gast verbunden ist und die Welt seit 10 s steht (vorher laedt der Spielstand die echten
-- Werte nach, das waere sonst ein riesiger "Kill"). Ohne Gast kann der Geist nichts verdienen: Bezugspunkt verwerfen.
function H.Credit(Now)
    if not A.Coop.Server then return end                      -- nur dedizierter Host (Geist)
    local AnyGuest = false
    Net.ForEachGuest(function(G) if G.Epoch then AnyGuest = true end end)
    if not AnyGuest then H.Base, H.BaseAt = nil, nil return end
    local WG = A.WorldGen
    if WG and H.GenSeen ~= WG.N then H.GenSeen, H.GenAt, H.Base = WG.N, Now, nil return end
    if (WG and WG.Loading) or Now - (H.GenAt or Now) < 10 then H.Base = nil return end
    local Ghost = A.Safe(A.LocalPC, nil)
    if not (Ghost and A.IsAlive(Ghost)) then return end
    local ok, S = pcall(H.ReadGhost, Ghost)
    if not ok or type(S.Level) ~= "number" or S.Level < 1 then return end
    local B = H.Base
    if not B then H.Base, H.BaseAt = S, Now pcall(H.NewDead) return end     -- vorhandene Leichen nicht spaeter zuordnen
    local Kills, Any = {}, false
    local InfOn = U.On("combat_infcredit")
    for _, F in ipairs(U.KILL_FIELDS) do
        local D = S.K[F] - B.K[F]
        if F == U.INF_FIELD and not InfOn then D = 0 end      -- Befall-Zaehler nur mit combat_infcredit
        if D > 0 then Kills[F], Any = D, true
        elseif D < 0 then H.Base = S return end           -- Spielstand neu geladen: neuer Bezugspunkt
        if D > 25 then H.Base = S return end              -- Sprung: Spielstand nachgeladen, kein echter Kill
    end
    if S.Level < B.Level or S.Level > B.Level + 1 then H.Base = S return end
    -- Skillpunkte: LevelUp ruft Add() selbst (LevelUp.txt @01ec) -> Stufen-Punkte des Geists abziehen, Rest = Kill-Punkte
    -- (Bandit/Militaer Death @0333, ZombieBoss @03b7: 25 %; UE 5.6 Coyote-Soldat Death @0390 statt Militaer)
    local SP = 0
    if U.On("combat_credit_sp") and S.SP and B.SP then
        SP = (S.SP - B.SP) - (S.Level - B.Level)
        if SP > 5 then H.Base = S return end                  -- Sprung: Spielstand nachgeladen
        if SP < 0 then B.SP, B.CP, SP = S.SP, S.CP, 0 end     -- Geist-Punkte anders veraendert: Bezugspunkt nachziehen
        if SP > 0 then Any = true end
    end
    local XP = 0
    if S.Level == B.Level then XP = (S.Buffer or 0) - (B.Buffer or 0)
    else XP = math.max(0, (B.Max or 0) - (B.Buffer or 0)) + (S.Buffer or 0) end
    if XP > 0.01 then Any = true else XP = 0 end
    if not Any then return end
    if XP > 20000 then H.Base = S return end                  -- Sprung: Spielstand nachgeladen
    if Core.Flag("combat_credit_dry", false) then             -- Diagnose: nur loggen, nichts schreiben
        local KT = {}
        for F, D in pairs(Kills) do KT[#KT + 1] = F .. "+" .. D end
        Log("Kill-Credit (trocken): %s XP %.1f SP %d Stufe %s->%s Puffer %.1f->%.1f Aktuell %.1f->%.1f",
            table.concat(KT, ","), XP, SP, tostring(B.Level), tostring(S.Level), B.Buffer or -1, S.Buffer or -1,
            B.Cur or -1, S.Cur or -1)
        H.Base = S
        return
    end
    H.RestoreGhost(Ghost, B, S.Level == B.Level)
    if SP > 0 then H.RestoreSP(Ghost, B, S, SP) end
    if S.Level ~= B.Level then H.Base = S end                 -- Geist bleibt hochgestuft: neuer Bezugspunkt
    local Key = H.Attribute(Now, Kills)
    if not Key then Log("Kill/XP beim Geist ohne Gast (verworfen): XP %.0f, SP %d", XP, SP) return end
    H.Apply(Key, Kills, XP, B, SP)
end

-- Befall-Verursacher (Event_OnDestroyed-Parameter Causer, "<Klasse> <Pfad>") -> Gast: Actor selbst, dann
-- GetOwner()/GetInstigator() hoechstens 4 Schritte bis zu Gast-PC bzw. Gastfigur (BP_PlayerCharacter_C)
function H.CauserGuest(Full)
    local Path = U.EvPath(Full)
    local O = Path and U.Find(Path)
    for _ = 0, 4 do
        if not O then return nil end
        local G = Net.ByPC(O)
        if not G and A.Safe(function() return U.IsA(O, "BP_PlayerCharacter_C") end, false) then
            G = Net.GuestByPawnName(U.Name(O))
        end
        if G and G.Key and Net.Guests[G.Key] then return G end
        local Nxt = A.Safe(function() return O:GetOwner() end, nil)
        if not A.IsAlive(Nxt) then Nxt = A.Safe(function() return O:GetInstigator() end, nil) end
        O = A.IsAlive(Nxt) and Nxt or nil
    end
    return nil
end

-- Wer war es? Native letzter Treffer -> Wurf/Explosion in der Naehe -> naechster Gast zum frischen Toten -> einziger Gast
-- (Befall mit combat_infcredit: zuerst Causer-Kette, dann letzter Treffer auf den Befall)
function H.Attribute(Now, Kills)
    local Dead = H.NewDead(Kills ~= nil and Kills[U.INF_FIELD] ~= nil)
    for _, D in ipairs(Dead) do
        if D.Inf then
            local G = D.Causer and H.CauserGuest(D.Causer)
            if G then
                Log("Befall %s zerstoert von %s (Verursacher)", D.Name, G.PCName or G.Key)
                return G.Key
            end
        end
    end
    for _, D in ipairs(Dead) do
        local Hit = H.LastHit[D.Name]
        if Hit and Now - Hit.T < (D.Inf and 30 or 10) and Net.Guests[Hit.Key] then return Hit.Key end
    end
    for I = #H.Recent, 1, -1 do
        local R = H.Recent[I]
        if Now - R.T < 10 and Net.Guests[R.Key] then
            for _, D in ipairs(Dead) do
                if D.Pos and U.Dist(D.Pos, R.Pos) < 2500 then return R.Key end
            end
            if #Dead == 0 and Now - R.T < 3 then return R.Key end
        end
    end
    local Best, BestD, Only, Count = nil, math.huge, nil, 0
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        Count, Only = Count + 1, Key
        local Pawn = H.PawnPC(G)
        if Pawn then
            local P = U.Loc(Pawn)
            for _, D in ipairs(Dead) do
                local Dist = D.Pos and U.Dist(P, D.Pos) or math.huge
                if Dist < BestD then Best, BestD = Key, Dist end
            end
        end
    end)
    if Best and BestD < 30000 then return Best end
    if Count == 1 then return Only end
    local Last, LastT = nil, -1
    for Key, T in pairs(H.ShotAt) do
        if T > LastT and Net.Guests[Key] then Last, LastT = Key, T end
    end
    return Last
end
H.LastHit, H.ShotAt = {}, {}

function H.IsDeadChar(Ch)
    if A.Safe(function() return Ch["IsDead?"] end, false) == true then return true end
    if A.Safe(function() return Ch.Dead end, false) == true then return true end
    local AI = U.Comp(Ch, "BP_SmartAIComponent", "BP_SmartAIComponent_C")
    return AI ~= nil and A.Safe(function() return AI.Dead end, false) == true
end

-- WithInf: auch die gemeldeten Befall-Zerstoerungen (H.InfQ) einmal liefern und verbrauchen
function H.NewDead(WithInf)
    local Out = {}
    if WithInf and #(H.InfQ or {}) > 0 then
        for _, E in ipairs(H.InfQ) do
            Out[#Out + 1] = { Name = E.Name, Pos = E.Pos, Causer = E.Causer, Inf = true }
        end
        H.InfQ = {}
    end
    for _, Ch in ipairs(A.Characters() or {}) do
        if A.IsAlive(Ch) and not A.Safe(function() return U.IsA(Ch, "BP_PlayerCharacter_C") end, true) then
            local Name = U.Name(Ch)
            if not H.DeadSeen[Name] and H.IsDeadChar(Ch) then
                H.DeadSeen[Name] = os.clock()           -- CORE-30: Zeitpunkt fuer M.Janitor
                local ok, Pos = pcall(U.Loc, Ch)
                if ok then Out[#Out + 1] = { Name = Name, Pos = Pos } end
            end
        end
    end
    return Out
end

-- Base: Geist-Bezugspunkt (Stufe/Multiplikator fuer combat_credit_scale), SP: Kill-Skillpunkte (combat_credit_sp)
function H.Apply(Key, Kills, XP, Base, SP)
    local G = Net.Guests[Key]
    local PC = G and Net.PC(G)
    if not PC then return end
    local Kind = nil
    for F, D in pairs(Kills) do
        pcall(function() PC[F] = (tonumber(PC[F]) or 0) + D end)
        Kind = Kind or F:sub(1, 1)
    end
    -- Skillpunkte auf der Host-Kopie des Gasts; der Gast bekommt sie ueber den Fortschritts-Spiegel (main.lua V.PROGRESS)
    if (SP or 0) > 0 then
        local TT = A.Safe(function() return PC.TechTreeComponent end, nil)
        if A.IsAlive(TT) then
            for _ = 1, math.min(SP, 5) do
                local ok, err = pcall(function() TT:Add() end)
                if not ok then
                    if Core.Fail("combat_credit_sp", err) then Log("Skillpunkt-Gutschrift aus: %s", tostring(err)) end
                    break
                end
                Log("Skillpunkt vom Geist an Gast %s", G.PCName or Key)
            end
        end
    end
    if XP > 0 and Base and U.On("combat_credit_scale") then
        local ok, Scaled = pcall(H.ScaleXP, PC, Base, XP)
        if ok and type(Scaled) == "number" then XP = Scaled
        elseif not ok and Core.Fail("combat_credit_scale", Scaled) then Log("XP-Skalierung aus: %s", tostring(Scaled)) end
    end
    if XP > 0 then
        local L = PC.LevellingComponent
        if not A.IsAlive(L) then return end
        local TimerKey = Key .. "#" .. tostring(U.Gen)
        if not H.TimerOn[TimerKey] then
            H.TimerOn[TimerKey] = true
            pcall(function() L:Event_LevelBarTimer() end)   -- CurrentXP zieht BufferXP nach, LevelUp
        end
        local ok = pcall(function() L:AddXP(XP, true, {}) end)
        if not ok then pcall(function() L.BufferXP = L.BufferXP + XP end) end
    end
    Log("Kill-Credit: %s +%s, XP %.0f", G.PCName or Key, Kind or "-", XP)
    if XP > 0 and U.On("combat_xppopup") and Net.Has("cb2", G) then
        Net.Send("cb_xp", string.format("%.0f;%s", XP, Kind or "X"), G, 2)
    end
end

-- 1 Hz: Kill-Zaehler (+ ueberlebte Tage) als Keyed-State an den jeweiligen Gast (ersetzt Legacy SyncStats)
function H.Stats()
    Net.ForEachGuest(function(G)
        if not (G.Epoch and Net.Has("cb2", G) and Net.Has("cb_kill", G)) then return end
        local PC = Net.PC(G)
        if not PC then return end
        local V = {}
        local function Put(F) V[#V + 1] = tostring(tonumber(A.Safe(function() return PC[F] end, 0)) or 0) end
        for I = 1, U.KILL_WIRE do Put(U.KILL_FIELDS[I]) end
        Put("DaysSurvived")                                   -- Feld 5 (alte Gaeste)
        if U.On("combat_infcredit") then                      -- ab Feld 6: neue Zaehler (alte Gaeste ignorieren sie)
            for I = U.KILL_WIRE + 1, #U.KILL_FIELDS do Put(U.KILL_FIELDS[I]) end
        end
        Net.State("cb_kills", "k", table.concat(V, ";"), 2, G)
    end)
end

-- ---------------------------------------------------------------- Befall (Host, combat_infcredit)
-- Nur lesender Pre-Hook BP_Infestation_C:Event_OnDestroyed(Causer, CalledFromGameLoad?) (Event_OnDestroyed.txt):
-- Zaehler/XP folgen erst nach Delay(0.2) im Ubergraph (OnCompleted @26d2 InfestationsDestroyed, @28a7 AddXP; UE 5.6
-- unveraendert: Event_OnDestroyed(Causer, CalledFromGameLoad?) -> Ubergraph(11106), @2715 Zaehler, @288f AddXP) ueber
-- CastToController(self) = Geist. Koerper schreibt nur in H.InfQ (<= 20), ruft nichts am Befall (Zustand: ls_world).
function H.InfHookBody(Ctx, Causer, Loaded)
    local Q = H.InfQ
    if not Q or #Q >= 20 or not U.On("combat_infcredit") then return end
    local okL, IsLoad = pcall(function() return Loaded:get() end)
    if okL and IsLoad == true then return end
    local Self = Ctx:get()
    if not A.IsAlive(Self) then return end
    local okP, Full = pcall(function() return Self:GetFullName() end)
    local okN, Name = pcall(function() return Self:GetFName():ToString() end)
    if not (okP and okN and Full and Name) then return end
    local CF = nil
    pcall(function()
        local C = Causer:get()
        if A.IsAlive(C) then CF = C:GetFullName() end
    end)
    Q[#Q + 1] = { Name = Name, Path = U.EvPath(Full) or Full, Causer = CF, At = os.clock() }
end

-- Adresse der aktuell geladenen Event_OnDestroyed-UFunction (nil = Klasse nicht geladen); nach Neuladen neue UFunction
function H.InfFnAddr()
    if not U.Find(U.INF_CLS) then return nil end
    local Fn = U.Find(U.INF_CLS .. ":Event_OnDestroyed")
    return Fn and A.Safe(function() return Fn:GetAddress() end, nil) or nil
end

-- 5 Hz: Hook setzen (alle 10 s versuchen, sobald die Klasse geladen ist; UFunction-Adresse geaendert -> neu hooken,
-- Pruefung alle 2 s und sofort nach Weltwechsel; gleiche Adresse = alter Hook greift noch, kein Doppel-Hook),
-- Lage der gemeldeten Befaelle lesen, alte Meldungen (> 30 s ohne Geist-Zaehler) verwerfen
function H.InfTick(Now)
    if not A.Coop.Server then return end
    local Gen = A.WorldGen and A.WorldGen.N or 0
    if H.InfHooked and (H.InfGen ~= Gen or Now >= (H.InfChkAt or 0)) then
        H.InfGen, H.InfChkAt = Gen, Now + 2
        if H.InfHooked ~= H.InfFnAddr() then
            H.InfHooked, H.InfHookAt = nil, nil
            Log("Befall-Hook: Klasse neu geladen/entladen, Hook wird erneuert")
        end
    end
    if not H.InfHooked and Now >= (H.InfHookAt or 0) then
        H.InfHookAt = Now + 10
        local Addr = H.InfFnAddr()
        if Addr and A.TryHook(U.INF_CLS .. ":Event_OnDestroyed", H.InfHookBody) ~= nil then
            H.InfHooked, H.InfGen, H.InfChkAt = Addr, Gen, Now + 2
        end
        if Addr then
            Log("Befall-Hook Event_OnDestroyed %s", H.InfHooked and "aktiv (Kill-Credit fuer Befall)" or "fehlgeschlagen")
        end
    end
    local Q = H.InfQ or {}
    if #Q == 0 then return end
    local Keep = {}
    for _, E in ipairs(Q) do
        if Now - (E.At or 0) < 30 then
            if not E.Pos and E.Path then
                local O = U.Find(E.Path)
                -- Review R1: "O and pcall(...)" kuerzt auf einen Wert (P war immer nil) -> zwei Anweisungen
                local ok, P = false, nil
                if O then ok, P = pcall(U.Loc, O) end
                if ok and P then E.Pos = P end
            end
            Keep[#Keep + 1] = E
        end
    end
    H.InfQ = Keep
end

-- ---------------------------------------------------------------- Wurf/Projektil (Host)

-- Verschiesst die Waffe W Geschosse der Klasse Cls? (ProjectileClass 0x248; nicht lesbar = ja, leer = nein)
function U.ProjMatch(W, Cls)
    local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
    if not WC then return true end
    local ok, PCls = pcall(function() return WC.ProjectileClass end)
    if not ok then return true end
    if not (PCls and A.Safe(function() return PCls:IsValid() end, false)) then return false end
    local Name = U.Name(PCls)
    return Name == "?" or Name == Cls
end

-- Wurfkoerper: Gast hat in den letzten 3 s passend verbraucht? A.Coop.Inv.LastConsume(Key, Muster) liefert den
-- os.clock-Zeitpunkt (oder true/false). Fehlt die Funktion oder wirft sie: keine Pruefung (true).
function U.ThrowConsumed(Key, Cls)
    local Inv = A.Coop and A.Coop.Inv
    local Fn = type(Inv) == "table" and Inv.LastConsume or nil
    if type(Fn) ~= "function" then return true end
    local Pat = (Cls or ""):match("^BP_Throwable_(.-)_C$") or Cls
    local ok, T = pcall(Fn, Key, Pat)
    if not ok then return true end
    if type(T) == "number" then return os.clock() - T <= 3 end
    return T == true
end

-- Werfer (Rakete/Granate/Leuchtkugel): Host-Schusszaehler Coop.Shot.ServerShots der Waffe muss mitlaufen
-- (Munition faellt). Zaehlt der Host diese Waffe nicht (nil): keine Pruefung. Ein Geschoss Vorlauf erlaubt
-- (cb_proj kann vor dem Schuss-RPC ankommen), alte Schuesse sammeln keinen Vorrat an.
function H.LauncherFired(W)
    local Shot = A.Coop and A.Coop.Shot
    local Shots = Shot and Shot.ServerShots
    if type(Shots) ~= "table" or not W then return true end
    local okA, Addr = pcall(function() return W:GetAddress() end)
    if not okA or not Addr then return true end
    local Count = tonumber(Shots[Addr])
    if not Count then return true end
    H.ProjAmmo = H.ProjAmmo or {}
    local Base = math.max(H.ProjAmmo[Addr] or (Count - 1), Count - 1)
    if Base > Count then return false end
    H.ProjAmmo[Addr] = Base + 1
    return true
end

function H.OnProj(Data, G)
    if not (U.On("combat_proj") and Net.Has("cb2", G)) then return end
    local P = U.Split(Data)
    local Lid, Cls = P[1], P[2]
    local Info = U.PROJ[Cls or ""]
    local Loc, Vel = U.Vec(P, 3), U.Vec(P, 6)
    local Age, Fuse = tonumber(P[9]) or 0, tonumber(P[10]) or 0
    if not (Info and Loc and Vel and Lid and #Lid <= 12) then return Net.SecWarn(G, G.Key, "cb_proj") end
    if not U.Rate("proj" .. G.Key, Info.Throw and 2 or 5) then return end
    local Pawn, PC = H.PawnPC(G)
    if not Pawn or U.Dist(U.Loc(Pawn), Loc) > 4000 then return Net.SecWarn(G, G.Key, "cb_proj_dist") end
    local Hand = U.HandFirearm(Pawn)
    -- Geschosse (Rakete/Granate/Leuchtkugel) nur mit passender Waffe in der Hand der Server-Figur
    if not Info.Throw then
        local Match = Hand and U.ProjMatch(Hand, Cls)
        local MatchW = Match and Hand or nil
        if not Match then
            for _, W in ipairs(U.Attached(Pawn)) do
                if A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) and U.ProjMatch(W, Cls) then
                    Match, Hand, MatchW = true, Hand or W, W
                    break
                end
            end
        end
        if not Match then return Net.SecWarn(G, G.Key, "cb_proj_weapon") end
        if U.On("combat_proj_check") and not H.LauncherFired(MatchW) then return Net.SecWarn(G, G.Key, "cb_proj_ammo") end
    elseif U.On("combat_proj_check") and Info.Consume ~= false and not U.ThrowConsumed(G.Key, Info.Consume or Cls) then
        return Net.SecWarn(G, G.Key, "cb_proj_consume")
    end
    local Speed = math.sqrt(Vel.X * Vel.X + Vel.Y * Vel.Y + Vel.Z * Vel.Z)
    local Max = Info.Throw and U.THROW_MAX or U.PROJ_MAX
    if Speed > Max then
        local F = Max / Speed
        Vel = { X = Vel.X * F, Y = Vel.Y * F, Z = Vel.Z * F }
        Speed = Max
    end
    local Rot = Speed > 1 and U.RotFromDir(Vel) or U.RotFromDir(U.Forward(A.Safe(function() return PC:GetControlRotation() end, { Pitch = 0, Yaw = 0 })))
    -- #17: Owner/Instigator = Werfer (Zuender/Treffer laufen spaeter per Timer, nur die Owner-Kette fuehrt zum Gast)
    local OwnP = U.On("combat_owner_proj") and Pawn or nil
    local R = U.Spawn(Pawn, Cls, Loc, Rot, function(Obj, I)
        -- "Tech Tree" gibt es nur am Wurfkoerper (BP_MasterThrowable_C); Projektile holen die Faehigkeiten in 5.6 erst
        -- beim Treffer ueber GetSkillTreeManager(self) (SkillCheck @0000 -> CastToController, Owner-Kette -> Gast)
        if I.Throw then pcall(function() Obj["Tech Tree"] = PC.TechTreeComponent end) end
        if I.Throw and Fuse > 0 then Obj.ExplosionDelay = math.max(0.05, Fuse - math.min(Age, 2) - 0.05) end
        if not I.Throw and Hand then pcall(function() Obj.WeaponOwner = Hand end) end
        if OwnP then pcall(function() Obj.Instigator = OwnP end) end
    end, OwnP)
    if not R then return end
    if not Info.Throw then
        -- Geschoss: nicht schneller als die Klasse selbst fliegt (MaxSpeed, sonst InitialSpeed; 0 = unbegrenzt)
        local PM = A.Safe(function() return R.ProjectileMovement end, nil)
        if not A.IsAlive(PM) then PM = nil end
        local Cap = PM and (tonumber(A.Safe(function() return PM.MaxSpeed end, 0)) or 0) or 0
        if Cap <= 0 and PM then Cap = tonumber(A.Safe(function() return PM.InitialSpeed end, 0)) or 0 end
        if Cap > 0 and Speed > Cap * 1.1 then
            local F = Cap / Speed
            Vel = { X = Vel.X * F, Y = Vel.Y * F, Z = Vel.Z * F }
        end
    end
    U.Launch(R, Info, Vel)
    local Gid = (G.PCName or "G") .. ":" .. Lid
    H.Proj[Gid] = { Path = U.Path(R), Cls = Cls, Key = G.Key, Lid = Lid, Pos = Loc, T = os.clock(), Owned = not OwnP,
                    FuseAt = (Info.Throw and Fuse > 0) and os.clock() + math.max(0.05, Fuse - math.min(Age, 2)) or nil,
                    Dmg = H.ProjDmg(R, Info) }
    H.Recent[#H.Recent + 1] = { Key = G.Key, Pos = Loc, T = os.clock() }
    Log("Wurf/Projektil von %s: %s (Zuender %.1f s)", G.PCName or "?", Cls, Fuse)
    local Fx = table.concat({ Gid, Cls, U.Fmt(Loc), string.format("%.0f;%.0f;%.0f", Vel.X, Vel.Y, Vel.Z),
        string.format("%.2f", math.max(0.05, Fuse - math.min(Age, 2))) }, ";")
    Net.ForEachGuest(function(G2, Key2)
        if Key2 ~= G.Key and G2.Epoch and Net.Has("cb2", G2) then
            local P2 = H.PawnPC(G2)
            if P2 and U.Dist(U.Loc(P2), Loc) < U.NEAR * 2 then Net.Send("cb_projfx", Fx, G2, 1) end
        end
    end)
end

-- BUILD-3: Schaden der Host-Kopie (Mittel aus Min/Max, erstes lesbares Paar; 5.6 rechnet DmgToDo erst beim Zuenden)
function H.ProjDmg(R, Info)
    local D = Info.Dmg or {}
    for I = 1, #D - 1, 2 do
        local Lo = tonumber(A.Safe(function() return R[D[I]] end, nil))
        local Hi = tonumber(A.Safe(function() return R[D[I + 1]] end, nil))
        if Lo and Hi and (Lo > 0 or Hi > 0) then return (Lo + Hi) / 2 end
    end
    return nil
end

-- BUILD-3 (combat_raidboom, E12): Explosion eines Gast-Wurfkoerpers an ls_build (Raids; 5.6 ApplyRadialDamage ist
-- fuer den cb_dmg-Beobachter unsichtbar). Rohrbombe lebt noch: DmgToDo der Host-Kopie, sonst gemerkter Schaden.
function H.RaidBoom(P, O)
    if not U.On("combat_raidboom") then return end
    local B = A.Coop and A.Coop.Build
    if not (type(B) == "table" and type(B.Boom) == "function") then return end
    local D = P.Dmg
    if O then D = tonumber(A.Safe(function() return O.DmgToDo end, nil)) or D end
    local ok, err = pcall(B.Boom, P.Key, P.Cls, { X = P.Pos.X, Y = P.Pos.Y, Z = P.Pos.Z }, D)
    if not ok and Core.Fail("combat_raidboom", err) then Log("Raid-Explosion aus: %s", tostring(err)) end
end

-- 10 Hz: Host-Kopien verfolgen; weg = explodiert -> cb_boom (Effekt bei allen, die keine eigene Kopie haben)
function H.TrackProj(Now)
    for Gid, P in pairs(H.Proj) do
        local O = U.Find(P.Path)
        if O then
            local ok, Pos = pcall(U.Loc, O)
            if ok then P.Pos = Pos end
            -- UE 5.6 Rohrbombe: explodiert (Delay(ExplosionDelay) @0ad2), bleibt aber liegen -> nach Zuender-Zeit melden
            local Info = U.PROJ[P.Cls]
            if Info.Stays and Info.Boom and P.FuseAt and not P.Boomed and Now >= P.FuseAt + 0.3
                and U.On("combat_boom_fuse") then
                P.Boomed = true
                H.Recent[#H.Recent + 1] = { Key = P.Key, Pos = P.Pos, T = Now, X = true }
                H.RaidBoom(P, O)
                H.BroadcastBoom("p:" .. Gid, P.Pos, "p", P.Key)
            end
            if Now - P.T > 40 then H.Proj[Gid] = nil end
        elseif P.Boomed then
            H.Proj[Gid] = nil
        else
            H.Proj[Gid] = nil
            if U.PROJ[P.Cls].Boom then
                H.Recent[#H.Recent + 1] = { Key = P.Key, Pos = P.Pos, T = Now, X = true }
                H.RaidBoom(P, nil)
                H.BroadcastBoom("p:" .. Gid, P.Pos, "p", P.Key)
            end
        end
    end
    for I = #H.Recent, 1, -1 do
        if Now - H.Recent[I].T > 12 then table.remove(H.Recent, I) end
    end
end

-- cb_boom: Src;X;Y;Z;Kind;Eigen;Klasse (Klasse nur bei "e:", Gast sucht damit + Lage seine Kopie)
function H.BroadcastBoom(Src, Pos, Kind, OwnerKey, Cls)
    if not U.On("combat_boom") then return end
    Net.ForEachGuest(function(G, Key)
        if not (G.Epoch and Net.Has("cb2", G)) then return end
        local Pawn = H.PawnPC(G)
        if Pawn and U.Dist(U.Loc(Pawn), Pos) <= U.NEAR * 2 then
            Net.Send("cb_boom", table.concat({ Src, U.Fmt(Pos), Kind, Key == OwnerKey and "1" or "0", Cls or "" }, ";"), G, 1)
        end
    end)
end

-- ---------------------------------------------------------------- Armbrust-Bolzen (COMBAT-7, K6 cb_bolt)
-- Decode BP_ProjectileArrow_C (Ubergraph): beim Treffer (ComponentHit, DoOnce) @0569-@05f5 BeginDeferredActorSpawnFromClass(
-- BP_BoltAmmoPickup_C, Transform des Pfeils, 2, null, 1) + SetLifeSpan(600), dann Delay(2) -> K2_DestroyActor; ohne
-- Treffer stirbt der Pfeil nach SetLifeSpan(5) (UserConstructionScript). Pfeil (FireBullet @0597) und Bolzen entstehen nur
-- beim Schuetzen: der Server kennt den Bolzen nicht, main.lua L.ClientTick loescht ihn nach 10 s als lokales Doppel.
-- Gast: Hook auf ReceiveBeginPlay des Pfeils (selten, nur einreihen), Pfeil verfolgen, nach Stillstand/Ende den frischen
-- lokalen Bolzen an der Pfeil-Lage suchen (FindAllOf nur dann), entfernen und die Lage melden. Host: Armbrust des Gasts,
-- echter Schuss (Coop.Shot.ServerShots, je Schuss hoechstens ein Bolzen), <= 150 m -> Bolzen wie das Spiel spawnen und
-- sofort replizieren (wie main.lua L.HostTick).
U.BOLT = { ARROW = "/Game/Inventory/Items/Other/ItemProjectiles/BP_ProjectileArrow.BP_ProjectileArrow_C",
           PICK = "/Game/Inventory/Items/Pickups/Attachments/Ammo/Special/BP_BoltAmmoPickup.BP_BoltAmmoPickup_C",
           PICK_CLS = "BP_BoltAmmoPickup_C", BOW = "BP_CrossbowPickup_C", MATCH = 300, ARROWS = 8, ARROW_S = 8,
           HOST_R = 15000, AHEAD = 3 }
H.BoltQ, H.BoltUsed = {}, {}

-- Handler cb_bolt "X;Y;Z": nur pruefen und einreihen (Spawn in H.BoltTick)
function H.BoltIn(Data, G)
    if not (G and G.Key and G.Epoch and Net.Has("cbbolt", G)) then return end
    if not U.Rate("bolt" .. G.Key, 2) then return Net.SecWarn(G, G.Key, "cb_bolt_rate") end
    if type(Data) ~= "string" or #Data > 64 then return Net.SecWarn(G, G.Key, "cb_bolt") end
    local Pos = U.Vec(U.Split(Data), 1)
    if not Pos then return Net.SecWarn(G, G.Key, "cb_bolt") end
    if #H.BoltQ >= 8 then return end
    H.BoltQ[#H.BoltQ + 1] = { Key = G.Key, Epoch = G.Epoch, Pos = Pos, T = os.clock() }
end

-- Armbrust des Gasts: aktive Waffe, sonst eine angehaengte (nach dem Schuss schon gewechselt)
function H.BoltBow(Pawn)
    local W = U.ActiveWeapon(Pawn)
    if W and A.Safe(function() return U.IsA(W, U.BOLT.BOW) end, false) then return W end
    for _, X in ipairs(U.Attached(Pawn)) do
        if A.Safe(function() return U.IsA(X, U.BOLT.BOW) end, false) then return X end
    end
    return nil
end

-- Je Schuss hoechstens ein Bolzen: Schuesse der Host-Kopie (MC_WeaponEffects) gegen vergebene Bolzen; erste Meldung
-- zaehlt nur den letzten Schuss, hoechstens U.BOLT.AHEAD Schuesse offen (Fehlschuesse sammeln keinen Vorrat an)
function H.BoltShot(W)
    local Shot = A.Coop and A.Coop.Shot
    local Shots = Shot and Shot.ServerShots
    if type(Shots) ~= "table" then return false, "noshots" end
    local Addr = W:GetAddress()
    local Count = tonumber(Shots[Addr])
    if not Count then return false, "noshots" end
    local Used = math.max(H.BoltUsed[Addr] or (Count - 1), Count - U.BOLT.AHEAD)
    if Used >= Count then return false, "used" end
    H.BoltUsed[Addr] = Used + 1
    return true
end

function H.BoltApply(E)
    local G = Net.Guests[E.Key]
    if not (G and G.Epoch == E.Epoch) or os.clock() - E.T > 5 then return end
    local Pawn = H.PawnPC(G)
    if not Pawn then return end
    local W = H.BoltBow(Pawn)
    if not W then return Net.SecWarn(G, E.Key, "cb_bolt_bow") end
    if U.Dist(U.Loc(Pawn), E.Pos) > U.BOLT.HOST_R then return Net.SecWarn(G, E.Key, "cb_bolt_dist") end
    local Class = U.Asset(U.BOLT.PICK)
    if not Class then return end
    local Ok, Why = H.BoltShot(W)
    if not Ok then
        if Why == "used" then return Net.SecWarn(G, E.Key, "cb_bolt_shot") end
        if not H.BoltNoShot then
            H.BoltNoShot = true
            Log("Armbrust-Bolzen: Host zaehlt keine Schuesse dieser Armbrust (Coop.Shot) - Bolzen verworfen")
        end
        return
    end
    local T = { Translation = E.Pos, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GS = U.GS()
    local R = GS:BeginDeferredActorSpawnFromClass(Pawn, Class, T, 2, nil, 1)
    if not (R and A.IsAlive(R)) then return end
    GS:FinishSpawningActor(R, T, 1)
    pcall(function() R:SetLifeSpan(600) end)
    pcall(function() R:SetReplicates(true) end)
    pcall(function() R:SetReplicateMovement(true) end)
    H.BoltN = (H.BoltN or 0) + 1
    if H.BoltN <= 3 or H.BoltN % 50 == 0 then
        Log("Armbrust-Bolzen von %s am Treffpunkt abgelegt (%d gesamt)", tostring(G.PCName or E.Key), H.BoltN)
    end
end

-- 0,1 s (H.STEPS9): hoechstens 4 Meldungen je Tick
function H.BoltTick()
    if #H.BoltQ == 0 then return end
    if not U.On("combat_bolt") then H.BoltQ = {} return end
    local Q = H.BoltQ
    H.BoltQ = {}
    for I, E in ipairs(Q) do
        if I <= 4 then
            local ok, err = pcall(H.BoltApply, E)
            if not ok and Core.Fail("combat_bolt", err) then Log("Armbrust-Bolzen aus: %s", tostring(err)) end
        else
            H.BoltQ[#H.BoltQ + 1] = E
        end
    end
end

-- ---------------------------------------------------------------- Sprengbares (beide Seiten)

-- 1 Hz: eine Klasse je Aufruf per FindAllOf (Regel: hoechstens 1 Hz), nur in der Naehe der Bezugsfiguren.
-- Rueckgabe true = eben BP_Landmine_C vollstaendig erfasst (kein 300er-Deckel) -> Host darf den Minen-Satz senden
function U.RefreshExpl(Refs)
    if #Refs == 0 then return false end
    U.ExplIdx = (U.ExplIdx or 0) % #U.EXPL + 1
    local Cls, Kind = U.EXPL[U.ExplIdx][1], U.EXPL[U.ExplIdx][2]
    local Full, List = pcall(FindAllOf, Cls)     -- nil ohne Fehler = keine Instanz
    if not Full or type(List) ~= "table" then List = {} end
    local Count = 0
    for _ in pairs(U.Expl) do Count = Count + 1 end
    for _, O in ipairs(List) do
        if Count >= 300 then Full = false break end
        if A.IsAlive(O) then
            local Path = U.Path(O)
            if not Path then Full = false end
            if Path and not U.Expl[Path] and not (U.ExplSkip and U.ExplSkip[Path]) then
                local ok, Pos = pcall(U.Loc, O)
                if ok then
                    for _, R in ipairs(Refs) do
                        if U.Dist(R, Pos) < 20000 then
                            U.Expl[Path] = { Pos = Pos, Kind = Kind, Cls = Cls }
                            Count = Count + 1
                            break
                        end
                    end
                else
                    Full = false
                end
            end
        end
    end
    return Cls == U.MINE_CLS and Full
end

-- Minen-Abgleich (BP_Landmine_C zerstoert sich in ReceiveBeginPlay zufaellig auf jeder Maschine selbst):
-- Host = Wahrheit. Host schickt je Gast nach jedem vollstaendigen Minen-Scan die Lagen um dessen Figur,
-- der Gast zerstoert eigene Minen in diesem Umkreis, die der Host nicht hat (sonst lokale Explosion ohne Host-Mine).
function H.PublishMines()
    Net.ForEachGuest(function(G)
        if not (G.Epoch and Net.Has("cb_mine", G)) then return end
        local Pawn = H.PawnPC(G)
        if not Pawn then return end
        local ok, C0 = pcall(U.Loc, Pawn)
        if not ok then return end
        local Out = { string.format("%.0f,%.0f,%.0f", C0.X, C0.Y, C0.Z) }
        for _, E in pairs(U.Expl) do
            if E.Cls == U.MINE_CLS and U.Dist(E.Pos, C0) <= U.MINE_R + 500 then
                Out[#Out + 1] = string.format("%.0f,%.0f,%.0f", E.Pos.X, E.Pos.Y, E.Pos.Z)
            end
        end
        Net.State("cb_mines", "m", table.concat(Out, "|"), 2, G)
    end)
end

function C.ApplyMines()
    local HM = C.HostMines
    if not HM or HM.Done or HM.Gen ~= U.Gen or os.clock() - HM.T > 6 then return end
    HM.Done = true
    local Pts = {}
    for X, Y, Z in tostring(HM.Raw or ""):gmatch("(%-?%d+),(%-?%d+),(%-?%d+)") do
        Pts[#Pts + 1] = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }
    end
    local Center = table.remove(Pts, 1)
    if not Center then return end
    local N = 0
    for Path, E in pairs(U.Expl) do
        if E.Cls == U.MINE_CLS and U.Dist(E.Pos, Center) <= U.MINE_R then
            local Known = false
            for _, P in ipairs(Pts) do
                if U.Dist(P, E.Pos) <= 100 then Known = true break end
            end
            if not Known then
                U.Expl[Path], U.ExplSkip[Path] = nil, true     -- vor dem Zerstoeren: kein cb_boomreq
                local O = U.Find(Path)
                if O then pcall(function() O:K2_DestroyActor() end) end
                N = N + 1
            end
        end
    end
    if N > 0 then Log("Minen-Abgleich: %d nur lokal vorhandene Mine(n) entfernt (Host hat sie nicht)", N) end
end

-- Sprengbares der anderen Maschine (Pfad + Lage + Klasse) auf DIESER Maschine finden. Zur Laufzeit gespawnte Actors
-- (Buildable_LandMine_C) heissen auf Host und Gast verschieden -> Pfad nur, wenn Klasse und Lage passen
-- (Map-Actors: gleicher FName, Fass darf rollen), sonst naechstes erfasstes Sprengbares gleicher Klasse.
-- Rueckgabe: Objekt (oder nil), lokaler Pfad (oder nil)
function U.MatchExpl(Path, Pos, Cls, Tol, PathTol)
    local O = U.Find(Path)
    if O then
        local OCls = U.Name(A.Safe(function() return O:GetClass() end, nil))
        local okL, L = pcall(U.Loc, O)
        local ClsOk = (Cls == nil or Cls == "" or OCls == Cls)
        if ClsOk and okL and U.Dist(L, Pos) <= (PathTol or Tol) then return O, Path end
    end
    local Best, BestD = nil, Tol
    for P2, E in pairs(U.Expl) do
        if Cls == nil or Cls == "" or E.Cls == Cls then
            local D = U.Dist(E.Pos, Pos)
            if D < BestD then Best, BestD = P2, D end
        end
    end
    return Best and U.Find(Best) or nil, Best
end

-- Ist das Sprengbare (noch) da? Fass: Health <= 0 zaehlt als explodiert
function U.ExplGone(Path, E)
    local O = U.Find(Path)
    if not O then return true end
    if E.Kind == "b" then
        local Hp = A.Safe(function() return O.Health end, nil)
        if Hp and Hp <= 0 then return true end
    end
    return false
end

function H.CheckExpl(Now)
    local Refs = H.RefPositions()
    for Path, E in pairs(U.Expl) do
        if U.ExplGone(Path, E) then
            U.Expl[Path] = nil
            local Near = false
            for _, R in ipairs(Refs) do if U.Dist(R, E.Pos) < U.NEAR then Near = true break end end
            if Near then
                local Req = H.BoomReq[Path]
                if Req and Now - Req.T < 10 then H.Recent[#H.Recent + 1] = { Key = Req.Key, Pos = E.Pos, T = Now, X = true } end
                H.BroadcastBoom("e:" .. Path, E.Pos, E.Kind, Req and Req.Key, E.Cls)
                H.BoomReq[Path] = nil
            end
        end
    end
end
H.BoomReq = {}

function H.RefPositions()
    local Out = {}
    Net.ForEachGuest(function(G)
        local Pawn = H.PawnPC(G)
        if Pawn then
            local ok, P = pcall(U.Loc, Pawn)
            if ok then Out[#Out + 1] = P end
        end
    end)
    return Out
end

-- Gast: "bei mir ist es explodiert" -> Host loest auf seiner Kopie aus (Damage_Object wie ein Treffer)
function H.OnBoomReq(Data, G)
    if not (U.On("combat_boom") and Net.Has("cb2", G)) then return end
    local P = U.Split(Data)
    local Path, Pos, Cls = P[1], U.Vec(P, 2), P[5]
    if not (Path and Pos and #Path < 300 and (Cls == nil or #Cls < 80)) then return Net.SecWarn(G, G.Key, "cb_boomreq") end
    if not U.Rate("boom" .. G.Key, 3) then return end
    local Pawn, PC = H.PawnPC(G)
    if not Pawn or U.Dist(U.Loc(Pawn), Pos) > U.NEAR then return Net.SecWarn(G, G.Key, "cb_boomreq_dist") end
    -- Gast-Pfad gilt nur fuer Map-Actors; Laufzeit-Actors (andere FName) ueber Klasse + Lage
    local O
    O, Path = U.MatchExpl(Path, Pos, Cls, 300, U.BOOMREQ_TOL)
    if not (O and Path) then return end
    local Ok = A.Safe(function() return U.IsA(O, "BP_ExplosiveBarrelMaster_C") or U.IsA(O, "BP_Landmine_C")
        or U.IsA(O, "Buildable_LandMine_C") end, false)
    if not Ok then return Net.SecWarn(G, G.Key, "cb_boomreq_class") end
    -- Echte Lage der Host-Kopie pruefen (auch bei direkt aufgeloestem Pfad): nahe am Gast und an der gemeldeten Stelle
    local okLoc, OLoc = pcall(U.Loc, O)
    if not okLoc or U.Dist(OLoc, Pos) > U.BOOMREQ_TOL or U.Dist(U.Loc(Pawn), OLoc) > U.NEAR then
        return Net.SecWarn(G, G.Key, "cb_boomreq_pos")
    end
    H.BoomReq[Path] = { Key = G.Key, T = os.clock() }
    local okDmg, err = pcall(function() O:Damage_Object(9999, Pawn, PC) end)
    if not okDmg then Log("Explosion fuer %s nicht ausgeloest: %s", G.PCName or "?", tostring(err)) end
end

-- ---------------------------------------------------------------- Einschlaege (Host verteilt)

function H.OnImpact(Data, G)
    if not Net.Has("cb2", G) then return end
    local P = U.Split(Data)
    local Pos, Kind, SD = U.Vec(P, 1), P[4], tonumber(P[5])
    if not (Pos and (Kind == "w" or Kind == "b" or Kind == "h")) then return Net.SecWarn(G, G.Key, "cb_imp") end
    H.ShotAt[G.Key] = os.clock()
    if SD and SD > 0 and SD < 100000 then H.SD[G.Key] = { V = SD, T = os.clock() } end
    if not U.On("combat_impacts") or not U.Rate("imp" .. G.Key, 15) then return end
    local Pawn = H.PawnPC(G)
    if not Pawn or U.Dist(U.Loc(Pawn), Pos) > 40000 then return end
    local Muzzle = U.Loc(Pawn)
    local Out = table.concat({ U.Fmt(Pos), Kind, U.Fmt(Muzzle) }, ";")
    Net.ForEachGuest(function(G2, Key2)
        if Key2 == G.Key or not (G2.Epoch and Net.Has("cb2", G2)) then return end
        local P2 = H.PawnPC(G2)
        if P2 and U.Dist(U.Loc(P2), Pos) <= U.NEAR then Net.Send("cb_imp", Out, G2, 1) end
    end)
end

-- Beobachter der DLL abmelden (Solo/Gast/Schalter aus); Fehler: trotzdem als aus merken (kein 10-Hz-Wiederholen)
function H.NativeOff()
    local ok = (not U.NativeOn()) or pcall(Native.Watch, nil, "ls_combat")
    H.NativeWatched = false
    Log("ApplyDamage-Beobachtung ueber die DLL (cb_dmg): aus%s", ok and "" or " (Abmelden fehlgeschlagen)")
end

-- ---------------------------------------------------------------- PvP (Host, Runde 7)

-- Allies-Karte { [Spielerfigur] = Clan-Index } (nur Index > 0) und Signatur (Adressen) fuer "geaendert?"
function H.AlliesMap()
    local Clan = A.Coop and A.Coop.Clan
    local Map, Parts = {}, {}
    if not (Clan and type(Clan.Index) == "function" and type(Clan.GuestIdOf) == "function") then return Map, "" end
    local function Add(Pawn, Who)
        local Gid = Clan.GuestIdOf(Who)
        local Idx = Gid ~= nil and tonumber(Clan.Index(Gid)) or 0
        if Idx and Idx > 0 and A.IsAlive(Pawn) then
            Map[Pawn] = math.floor(Idx)
            Parts[#Parts + 1] = string.format("%X=%d", Pawn:GetAddress(), math.floor(Idx))
        end
    end
    Net.ForEachGuest(function(G)
        if not G.Epoch then return end
        local Pawn = H.PawnPC(G)
        if Pawn then Add(Pawn, G) end
    end)
    -- Listen-Host mit eigener Figur (nicht der unsichtbare Geist des dedizierten Hosts)
    if not A.Coop.Server then
        local Own = A.Safe(A.OwnPawn, nil)
        if Own and A.IsAlive(Own) then Add(Own, Own) end
    end
    table.sort(Parts)
    return Map, table.concat(Parts, ",")
end

-- Native.SetAllies nur bei Aenderung (oder alle 30 s erneut, falls die DLL-Datei verloren ging)
function H.PushAllies(Map, Sig, Now)
    if type(Native.SetAllies) ~= "function" then
        if not H.AlliesWarned and Sig ~= "" then
            H.AlliesWarned = true
            Log("PvP: Native.SetAllies fehlt - Clan-Schutz beim Host (Nahkampf/Explosionen) nicht moeglich")
        end
        return
    end
    -- Weltwechsel: neue Spielerfiguren (FNames) -> Clan-Schutz sofort neu an die DLL, nicht erst nach 30 s
    local Gen = A.WorldGen and A.WorldGen.N or 0
    if Gen ~= H.AlliesGen then
        if H.AlliesGen ~= nil and H.AlliesSig ~= nil then Log("PvP: Weltwechsel - Clan-Schutz wird neu uebertragen") end
        H.AlliesGen, H.AlliesSig, H.AlliesAt = Gen, nil, nil
    end
    if Sig == H.AlliesSig and Now - (H.AlliesAt or 0) < 30 then return end
    local ok, Res = pcall(Native.SetAllies, Map)
    if not ok or Res == false then
        U.PvpFail("Allies", ok and "SetAllies=false" or Res)
        return
    end
    if Sig ~= H.AlliesSig then
        local N = select(2, Sig:gsub("=", ""))
        Log("PvP: Clan-Schutz fuer %d Spielerfiguren an die DLL", N)
    end
    H.AlliesSig, H.AlliesAt = Sig, Now
end

-- Tod einer Gastfigur (PlayerDead? bzw. Health <= 0) -> Kill-Credit an den Gast mit dem letzten Treffer (cb_dmg,
-- 10 s). Spielertode zaehlt das Spiel selbst nirgends (BP_PlayerCharacter: Health 0 -> PlayerDeath, kein Killer);
-- die Todeskiste entsteht unveraendert auf dem normalen Todesweg und ist fuer alle pluenderbar.
function H.PvpDeaths(Now)
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        local Pawn = H.DeathPawn(G, Key)          -- Abschluss-Runde: tote Figur ist sofort entbesessen
        if not Pawn then return end
        local Name = U.Name(Pawn)
        local Dead = A.Safe(function() return Pawn["PlayerDead?"] end, false) == true
        if not Dead then
            local MC = A.Safe(function() return Pawn.MedicalComponent end, nil)
            local HP = A.IsAlive(MC) and tonumber(A.Safe(function() return MC.Health end, nil)) or nil
            Dead = HP ~= nil and HP <= 0
        end
        if not Dead then H.PvpPend[Key] = nil return end
        if H.PvpDead[Key] == Name then return end
        -- Review R1 (combat_kf_defer): toedlicher Treffer evtl. noch nicht aus der DLL gelesen -> einen Takt warten,
        -- den ersten Treffer danach einfrieren (H.KfHold); spaetere Treffer auf die Leiche zaehlen nicht
        local Hit
        if U.On("combat_kf_defer") then
            local Ok, Rec = H.KfHold(H.PvpPend, Key, Name, H.LastHit[Name], Now)
            if not Ok then return end
            Hit = Rec or H.LastHit[Name]
        else
            Hit = H.LastHit[Name]
        end
        H.PvpDead[Key] = Name
        H.LastHit[Name] = nil
        if not (Hit and Now - Hit.T < 10 and Hit.Key ~= Key and Net.Guests[Hit.Key]) then return end
        local Killer = Net.Guests[Hit.Key]
        Log("PvP-Kill: %s hat %s getoetet", tostring(Killer.PCName or Hit.Key), tostring(G.PCName or Key))
        H.Apply(Hit.Key, { HumanKills = 1 }, math.max(0, Core.Flag("pvp_kill_xp", 100)))
    end)
end
H.PvpDead = {}

-- 0,5 s: Politik an die Gaeste (cb_pvp), Allies-Karte an die DLL, PvP-Tode
function H.PvpTick(Now)
    if Net.Side ~= "host" then
        if H.AlliesSig and H.AlliesSig ~= "" and type(Native.SetAllies) == "function" then pcall(Native.SetAllies, {}) end
        H.AlliesSig = nil
        return
    end
    local Mode = U.PvpMode()
    Net.State("cb_pvp", "m", Mode, 2)
    if Mode ~= H.PvpLogged then
        H.PvpLogged = Mode
        Log("PvP-Modus: %s", ({ off = "aus (niemand trifft Spieler)", clan = "an, Clan-Kameraden geschuetzt",
                                 all = "an, auch Clan-Kameraden treffbar" })[Mode])
    end
    if Mode == "clan" then
        local Map, Sig = H.AlliesMap()
        H.PushAllies(Map, Sig, Now)
    else
        H.PushAllies({}, "", Now)
    end
    if Mode ~= "off" and U.On("combat_credit") and H.NativeWatched then H.PvpDeaths(Now) end
end

-- Native (N4b): ApplyDamage aus dem SERVER_DamageEvent-Zweig einer Gast-Waffe -> letzter Treffer je Ziel (FName)
function H.NativeTick(Now)
    if not H.NativeWatched then return end
    if Now >= (H.LastHitPrune or 0) then
        H.LastHitPrune = Now + 30
        for Name, Hit in pairs(H.LastHit) do
            if Now - Hit.T > 10 then H.LastHit[Name] = nil end
        end
        for Name, T in pairs(H.CombatTag) do
            if Now - T > 120 then H.CombatTag[Name] = nil end
        end
    end
    for _, E in ipairs(H.EvTag("cb_dmg")) do
        local Target = U.EvPath(E.Args[1])
        local Actor = Target and Target:match("([^%.:]+)$")
        local Causer, Weapon = U.EvPath(E.Args[4]), U.EvPath(E.Caller)
        local Shooter = (Causer or Weapon) and H.DmgGuest(Causer, Weapon) or nil
        if E.Blocked == true then
            -- Runde 9: vom Clan-Schutz (ffblock) verworfener Treffer = kein Schaden -> kein Letzter-Treffer/Kill-Credit,
            -- keine Kampf-Markierung; COMBAT-16: nur ein Hinweis an den Schuetzen
            if Shooter then H.FfNote(Shooter, Now) end
        elseif Actor then
            -- Review R1 (combat_kf_defer): wartender PvP-Tod -> ersten Treffer einfrieren (auch ohne Gast-Schuetzen:
            -- Zombie-Treffer = kein PvP-Credit), Letzter-Treffer bleibt unveraendert
            local Held = next(H.PvpPend) ~= nil and U.On("combat_kf_defer")
                and H.KfCatch(H.PvpPend, Actor, { Key = Shooter, T = Now }, Now)
            if Shooter then
                if not Held then H.LastHit[Actor] = { Key = Shooter, T = Now } end
                H.ShotAt[Shooter] = Now
                H.FdAdd(Shooter, "dmg", Now)
                H.TagVictim(Target, Shooter, Now)
            end
            -- COMBAT-13: Treffer AUF Gastfiguren (jeder Verursacher) fuer den Kill-Feed
            if U.On("combat_killfeed") then H.KfHit(Target, Actor, Shooter, E, Now) end
        end
    end
end

-- Gast hinter einem ApplyDamage: Figur = Verursacher oder Waffe = Aufrufer (H.Weap, Pfade)
function H.DmgGuest(Causer, Weapon)
    for Key, W in pairs(H.Weap) do
        if Causer ~= nil and W.Pawn == Causer then return Key end
        if Weapon then
            for _, Path in ipairs(W.List) do
                if Path == Weapon then return Key end
            end
        end
    end
    return nil
end

-- COMBAT-16 (combat_ff_note): Clan-Kamerad getroffen, Schaden vom Clan-Schutz verworfen -> Hinweis (hoechstens alle 5 s)
H.FfNoteAt = {}
function H.FfNote(Key, Now)
    if not U.On("combat_ff_note") or Now - (H.FfNoteAt[Key] or -99) < 5 then return end
    local G = Net.Guests[Key]
    if not (G and G.Epoch and Net.Has("ui_note2", G)) then return end
    H.FfNoteAt[Key] = Now
    Net.Send("note2", Net.Enc("Clan-Mitglied - kein Schaden") .. "||1,1,1,1|2|0", G, 0)
end

-- ---------------------------------------------------------------- Kill-Feed (Host, COMBAT-13, K7 cb_kf)
-- Treffer AUF Gastfiguren (cb_dmg, jeder Verursacher) und Kopftreffer (cb_sde) merken; Tod einer Gastfigur (wie
-- H.PvpDeaths, in allen PvP-Modi) -> "<Killer>;<Opfer>;<Waffe>;<Kopf 0/1>;<Meter>" an alle Gaeste (Namen Net.Enc).
-- Spieler-Kill: Killer = Spielername (PlayerState), Waffe aus der Waffenklasse, Explosion eines anderen Gasts in 25 m
-- (Wurf/Geschoss, ApplyRadialDamage ist fuer cb_dmg unsichtbar) -> Waffe "Explosion". Sonst Killer leer und Waffe =
-- Ursache z (Zombie), a (Tier), h (Mensch), t (Geschuetz), u (Umwelt/selbst) - nur mit combat_killfeed_pve=1.
U.KF_CAUSE = { { "BP_MasterZombie_C", "z" }, { "BP_Animal_C", "a" }, { "BP_MasterBandit_C", "h" },
               { "BP_MasterCoyoteSoldier_C", "h" }, { "BP_Human_C", "h" }, { "BP_MasterTurret_C", "t" } }
H.LastDmgOn, H.KfHead, H.KfDead = {}, {}, {}

-- "<Klasse> <Pfad>" der Waffe -> kurzer Name ("BP_AK74Pickup_C" -> "AK74"), "" ohne Waffe
function U.KfWeapon(Full)
    local Cls = type(Full) == "string" and Full:match("^(%S+) ") or nil
    if not Cls or Cls:find("Default__", 1, true) or Cls:find("Character", 1, true) then return "" end
    local N = Cls:gsub("^BP_", ""):gsub("Pickup_C$", ""):gsub("_C$", "")
    return N:sub(1, 32)
end

-- Verursacher "<Klasse> <Pfad>" -> "p" (Spielerfigur) oder Ursache-Kuerzel
function H.KfCause(Full)
    local Cls, Path = tostring(Full or ""):match("^(%S+) (.+)$")
    local O = Path and U.Find(Path)
    if O then
        if A.Safe(function() return U.IsA(O, "BP_PlayerCharacter_C") end, false) then return "p" end
        for _, E in ipairs(U.KF_CAUSE) do
            if A.Safe(function() return U.IsA(O, E[1]) end, false) then return E[2] end
        end
    end
    Cls = Cls or ""
    if Cls:find("Zombie", 1, true) then return "z" end
    if Cls:find("Animal", 1, true) then return "a" end
    if Cls:find("Bandit", 1, true) or Cls:find("Soldier", 1, true) then return "h" end
    if Cls:find("Turret", 1, true) then return "t" end
    return "u"
end

function H.KfVictim(Target)
    for K, W in pairs(H.Weap) do
        if W.Pawn == Target then return K end
    end
    -- Abschluss-Runde (combat_dead_pawn): ScanWeapons loescht H.Weap[Key], sobald die tote Figur entbesessen ist ->
    -- toedlicher Treffer, der erst danach aus der DLL gelesen wird, ueber die gemerkte Figur zuordnen
    if U.On("combat_dead_pawn") then
        for K, P in pairs(H.LastPawnP) do
            if P == Target then return K end
        end
    end
    return nil
end

function H.KfHit(Target, Actor, Shooter, E, Now)
    local Victim = H.KfVictim(Target)
    if not Victim then return end
    local Rec = { T = Now }
    if Shooter and Shooter ~= Victim then
        Rec.Key, Rec.P, Rec.W = Shooter, H.Weap[Shooter].Pawn, U.KfWeapon(E.Caller)
    elseif Shooter then
        Rec.C = "u"                                   -- eigener Schaden
    else
        local Cause = H.KfCause(E.Args[4])
        if Cause == "p" then Rec.P, Rec.W = U.EvPath(E.Args[4]), U.KfWeapon(E.Caller) else Rec.C = Cause end
    end
    -- Review R1 (combat_kf_defer): Figur wartet auf den toedlichen Treffer -> einfrieren, Merker nicht ueberschreiben
    if U.On("combat_kf_defer") and H.KfCatch(H.KfPend, Actor, Rec, Now) then return end
    H.LastDmgOn[Actor] = Rec
end

-- ---- Review R1 (combat_kf_defer): Tod erst aufloesen, wenn der toedliche Treffer gelesen ist (DLL schreibt
-- Ereignisse nur alle 100 ms; cb_pvp kann den Tod vorher sehen). Ist der Merker frisch (< KF_FRESH s), sofort wie
-- bisher; sonst wartet der Tod einen cb_pvp-Takt (>= KF_DEFER s), der erste Treffer bis KF_DEFER s danach wird
-- eingefroren (Ereignisse kommen in Seq-Reihenfolge, der toedliche zuerst). Rueckgabe: true = jetzt aufloesen
-- (Rec = eingefrorener Treffer oder nil -> aktueller Merker), false = weiter warten.
U.KF_FRESH, U.KF_DEFER = 0.6, 0.3
H.KfPend, H.PvpPend = {}, {}       -- [PC-Key] = { Name = Figur-FName, At = Zeit des Todes, Rec = Treffer|nil }

-- ---- Abschluss-Runde (combat_dead_pawn): der Tod laeuft synchron (Ubergraph @2163f Health=0 -> @3488 PlayerDead? ->
-- @352f AfterDeath), AfterDeath @0551-056b ruft im selben Aufruf GetPlayerController(0)->UnPossess (beim Host per DLL
-- der Gast-PC) -> K2_GetPawn ist sofort leer, cb_pvp (2 Hz) sah den Tod nie. Letzte Figur je Gast als Pfad merken,
-- die tote Figur (bleibt 30 s liegen) darueber wiederfinden. [PC-Key] = Figur-Pfad (nur Pfade; Weltwechsel/"gone" leeren)
H.LastPawnP = H.LastPawnP or {}
function H.DeathPawn(G, Key)
    local Pawn, PC = H.PawnPC(G)
    if Pawn then
        H.LastPawnP[Key] = U.Path(Pawn)
        return Pawn, PC
    end
    if not U.On("combat_dead_pawn") then return nil, PC end
    local Old = U.Find(H.LastPawnP[Key])
    if Old and A.Safe(function() return Old["PlayerDead?"] end, false) == true then return Old, PC end
    if not Old then H.LastPawnP[Key] = nil end
    return nil, PC
end
function H.KfHold(Pend, Key, Name, R0, Now)
    local P = Pend[Key]
    if P and P.Name ~= Name then P, Pend[Key] = nil, nil end      -- neue Figur nach Respawn/Rejoin
    if not P then
        if R0 and Now - R0.T < U.KF_FRESH then return true, nil end
        Pend[Key] = { Name = Name, At = Now }
        return false, nil
    end
    if Now - P.At < U.KF_DEFER then return false, nil end
    Pend[Key] = nil
    return true, P.Rec
end

-- Treffer auf eine wartende Figur: ersten Treffer (<= KF_DEFER s nach dem Tod) merken; true = Merker nicht schreiben
function H.KfCatch(Pend, Name, Rec, Now)
    if not next(Pend) then return false end
    for _, P in pairs(Pend) do
        if P.Name == Name then
            if not P.Rec and Now - P.At <= U.KF_DEFER then P.Rec = Rec end
            return true
        end
    end
    return false
end

-- cb_sde (SERVER_DamageEvent) eines Gasts auf eine Gastfigur: Kopftreffer merken
function H.KfSde(Ev, Key, Now)
    local TP = U.EvPath(Ev.Args[2])
    if TP and H.KfVictim(TP) then
        H.KfHead[TP:match("([^%.:]+)$") or TP] = { Key = Key, Hs = Ev.Args[1] == true, T = Now }
    end
end

-- Spielername (PlayerState des PCs, sonst der Figur), hoechstens 32 Zeichen
function H.KfName(Pawn, PC)
    for _, O in ipairs({ PC or false, Pawn or false }) do
        local PS = O and A.IsAlive(O) and A.Safe(function() return O.PlayerState end, nil) or nil
        local N = PS and A.IsAlive(PS) and A.Safe(function() return PS:GetPlayerName():ToString() end, nil) or nil
        if type(N) == "string" and N ~= "" then return N:sub(1, 32) end
    end
    return nil
end

-- 2 Hz (cb_pvp): Tod je Gastfigur einmal melden (neue Figur nach dem Respawn = neuer Tod moeglich)
function H.KfTick(Now)
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        local Pawn, PC = H.DeathPawn(G, Key)      -- Abschluss-Runde: tote Figur ist sofort entbesessen
        if not Pawn then return end
        local Name = U.Name(Pawn)
        local Dead = A.Safe(function() return Pawn["PlayerDead?"] end, false) == true
        if not Dead then
            local MC = A.Safe(function() return Pawn.MedicalComponent end, nil)
            local HP = A.IsAlive(MC) and tonumber(A.Safe(function() return MC.Health end, nil)) or nil
            Dead = HP ~= nil and HP <= 0
        end
        if not Dead then H.KfPend[Key] = nil return end
        if H.KfDead[Key] == Name then return end
        local Rec = nil
        if U.On("combat_kf_defer") then          -- Review R1: auf den toedlichen Treffer warten (H.KfHold)
            local Ok
            Ok, Rec = H.KfHold(H.KfPend, Key, Name, H.LastDmgOn[Name], Now)
            if not Ok then return end
        end
        H.KfDead[Key] = Name
        H.KfSend(G, Key, Pawn, PC, Name, Now, Rec)
    end)
end

-- Rec (Review R1): eingefrorener toedlicher Treffer aus H.KfHold, sonst der aktuelle Merker
function H.KfSend(G, Key, Pawn, PC, Name, Now, Rec)
    local D, Hd = Rec or H.LastDmgOn[Name], H.KfHead[Name]
    H.LastDmgOn[Name], H.KfHead[Name] = nil, nil
    if D and Now - D.T > 10 then D = nil end
    local Killer, Weapon, Head, M = "", "u", "0", 0
    local okV, VPos = pcall(U.Loc, Pawn)
    if D and D.P then
        local KG = D.Key and Net.Guests[D.Key]
        local KPawn, KPC = nil, nil
        if KG then KPawn, KPC = H.PawnPC(KG) else KPawn = U.Find(D.P) end
        Killer = H.KfName(KPawn, KPC) or (KG and KG.PCName) or "?"
        Weapon = D.W or ""
        if Hd and Hd.Hs and Hd.Key == D.Key and Now - Hd.T < 10 then Head = "1" end
        local okK, KPos = false, nil
        if KPawn then okK, KPos = pcall(U.Loc, KPawn) end
        if okK and okV then M = math.floor(U.Dist(KPos, VPos) / 100 + 0.5) end
    elseif D and D.C then
        Weapon = D.C
    elseif okV then
        for I = #H.Recent, 1, -1 do
            local R = H.Recent[I]
            if R.X and R.Key ~= Key and Now - R.T < 10 and Net.Guests[R.Key] and U.Dist(R.Pos, VPos) < 2500 then
                local KPawn, KPC = H.PawnPC(Net.Guests[R.Key])
                Killer, Weapon = H.KfName(KPawn, KPC) or Net.Guests[R.Key].PCName or "?", "Explosion"
                break
            end
        end
    end
    if Killer == "" and not U.Opt("combat_killfeed_pve") then return end
    local Victim = H.KfName(Pawn, PC) or G.PCName or "?"
    local Data = table.concat({ Net.Enc(Killer), Net.Enc(Victim), Net.Enc(Weapon), Head, tostring(M) }, ";")
    Log("Kill-Feed: %s -> %s (%s, Kopf %s, %d m)", Killer ~= "" and Killer or "-", Victim, Weapon, Head, M)
    Net.ForEachGuest(function(G2)
        if G2.Epoch and Net.Has("cbkf", G2) then Net.Send("cb_kf", Data, G2, 2) end
    end)
end

-- PLAYER-13 (E10): Treffer eines Spielers auf die Figur eines ANDEREN Gasts -> Kampf-Markierung (120 s) unter dem
-- FName der getroffenen Figur (main.lua: Ausloggen im Kampf)
H.CombatTag = {}
function H.TagVictim(TargetPath, Key, Now)
    for K2, W2 in pairs(H.Weap) do
        if K2 ~= Key and W2.Pawn == TargetPath then
            local Name = TargetPath:match("([^%.:]+)$")
            if Name then H.CombatTag[Name] = Now end
            return
        end
    end
end

-- Runde 9: ein Lesen des DLL-Fensters je Host-Tick (Cursor "_ls_combat_h") fuer cb_dmg, cb_sde und fh_*
function H.ReadEvents()
    if not U.NativeOn() then return {} end
    local ok, List = pcall(Native.Events, "_ls_combat_h")
    return (ok and type(List) == "table") and List or {}
end

function H.EvTag(Tag)
    local Out = {}
    for _, Ev in ipairs(H.EvList or {}) do
        if Ev.Tag == Tag and type(Ev.Args) == "table" then Out[#Out + 1] = Ev end
    end
    return Out
end

-- DLL-Ereignis -> Gast-Key ueber H.Weap (Pfade): Kontext = Gastfigur (IsPawn) bzw. eine seiner Waffen
function H.EvGuest(Ev, IsPawn)
    local Path = U.EvPath(Ev.Ctx)
    if not Path then return nil end
    for Key, W in pairs(H.Weap) do
        if IsPawn then
            if W.Pawn == Path then return Key end
        else
            for _, P in ipairs(W.List) do
                if P == Path then return Key end
            end
        end
    end
    return nil
end

-- PLAYER-25 (E27): eigener Angriff (Relay-Nahkampftreffer, cb_sde-Schuss) beendet den Spawn-Schutz
-- (server.lua Srv.EndProtect(PawnName)), hoechstens alle 5 s je Gast
H.EndProtAt = {}
function H.EndProtect(Key, G)
    local Srv = A.Settings and A.Settings.server
    local Fn = type(Srv) == "table" and Srv.EndProtect or nil
    if type(Fn) ~= "function" then return end
    local Now = os.clock()
    if Now - (H.EndProtAt[Key] or -99) < 5 then return end
    H.EndProtAt[Key] = Now
    local Name = G and G.PawnName
    if not Name then
        local Pawn = G and H.PawnPC(G)
        Name = Pawn and U.Name(Pawn) or nil
    end
    if Name then pcall(Fn, Name) end
end

-- ---------------------------------------------------------------- SERVER_DamageEvent beim Host (Runde 9)
-- COMBAT-11 (combat_sd_native): Beobachter beim EINTRITT von SERVER_DamageEvent (RPC-Ankunft; Event-Stub mit Parametern
-- -> erster Opcode 0x64, sichtbar) mit Vor-Aktion sd: die DLL schreibt ShotDistance = |Owner(Waffe) - DamagedActor|
-- direkt vor der Schadensrechnung (EffectiveDamage @0000) -> Falloff wie im Einzelspieler. H.Falloff (Blick-Trace)
-- bleibt Rueckfall, bis ein cb_sde-Ereignis mit geschriebenem Abstand (Flag D) da war (danach 300 s Ruhe).
-- Dieselben Ereignisse speisen COMBAT-10 (Server-Hitmarker, ls_ui SendHit), COMBAT-12 (Treffer-Pruefung) und
-- PLAYER-25. Args: [1] Headshot (b), [2] DamagedActor ("<Klasse> <Pfad>"), [3] ImpactPoint {X,Y,Z}; Ctx = Waffe.
U.SDE = { HITS_S = 20, SHOT_MUL = 12, SHOT_ADD = 2, WIN = 2, PAWN_R = 20000, TGT_R = 500, VIOL_N = 5, VIOL_WIN = 10,
          DENY_S = 60, DENY_MAX = 16, MARK_RATE = 12, SD_KEEP = 300 }
H.HC, H.SdeDeny = {}, {}

-- nil (kein Beobachter) | "obs" | "sd" (mit Abstand)
function H.SdeWanted()
    if Net.Side ~= "host" or not U.NativeOn() then return nil end
    local Sd = U.On("combat_sd_native")
    if not (Sd or U.On("combat_hit_server") or U.On("combat_hitcheck")) then return nil end
    return Sd and "sd" or "obs"
end

function H.SdeWatch(Now)
    local Want = H.SdeWanted()
    if Want ~= (H.SdeOn or nil) then
        local ok, err
        if Want then
            ok, err = pcall(Native.Watch, { { Func = U.PROJ_WEAPON .. ":SERVER_DamageEvent", Tag = "cb_sde", Mode = "observe",
                At = "entry", Pre = Want == "sd" and { shotdist = true } or nil } }, "ls_combat_sde")
        else
            ok, err = pcall(Native.SetWatch, nil, "ls_combat_sde")
            if next(H.SdeDeny) or H.SdeDenyN then
                H.SdeDeny, H.SdeDenyN = {}, nil
                pcall(Native.SetDeny, {}, "ls_combat_sde")
            end
        end
        if ok then
            H.SdeOn, H.SdeEntry, H.SdeInfoAt = Want or false, false, 0
            Log("SERVER_DamageEvent-Beobachtung (cb_sde): %s", Want == "sd" and "an, mit Abstand fuer den Falloff"
                or (Want and "an" or "aus"))
        elseif not H.SdeErrLogged then
            H.SdeErrLogged = true
            Log("SERVER_DamageEvent-Beobachtung nicht gesetzt: %s", tostring(err))
        end
    end
    if not H.SdeOn or Now < (H.SdeInfoAt or 0) then return end
    H.SdeInfoAt = Now + 2
    local Text = Core.ReadAll(Native.Path("watchinfo", ".txt")) or ""
    local At, Mode = ("\n" .. Text):match("\ncb_sde\t%x+\t(%a+)\t([^\t\n]*)")
    local Entry = At == "entry"
    if Entry ~= H.SdeEntry then
        H.SdeEntry = Entry
        Log("cb_sde laut DLL: %s%s", Entry and "beim Eintritt" or "nicht beim Eintritt (kein Server-Hitmarker/Falloff)",
            (Entry and Mode and Mode:find("sd", 1, true)) and ", Abstand (sd) aktiv" or "")
    end
end

-- H.Falloff ueberspringen: DLL hat in den letzten 300 s einen Abstand beim Eintritt geschrieben
function H.SdeFalloffOk(Now)
    return H.SdeOn == "sd" and H.SdeEntry == true and H.SdDistAt ~= nil and Now - H.SdDistAt < U.SDE.SD_KEEP
end

-- COMBAT-10 (combat_hit_server, K9 cb_hit2): Hitmarker vom Server-Treffer an den Schuetzen (weiss, Kopf rot)
function H.SdeMarker(G, Ev)
    if not Net.Has("cb_hit2", G) or not U.Rate("sdem" .. G.Key, U.SDE.MARK_RATE) then return end
    local UI = A.Coop.Modules and A.Coop.Modules.ls_ui
    if not (type(UI) == "table" and type(UI.SendHit) == "function") then return end
    local Hs = Ev.Args[1] == true
    UI.SendHit(G, 0, 1, Hs and 0 or 1, Hs and 0 or 1, 1, "m", U.MRelVec(Ev.Args[3]))
end

-- COMBAT-12 (combat_hitcheck): Plausibilitaet je Gast, grosszuegig gegen Lag. Jeder Verstoss: Log + SecWarn; Sperre
-- (Besitzer ls_combat_sde, Tag cb_sdeny, 60 s) erst ab 5 Verstoessen in 10 s UND combat_hitcheck_deny=1.
function H.HitCheck(G, Key, Ev, Now)
    local S = H.HC[Key]
    if not S then S = { T = Now, Base = {}, Viol = {} } H.HC[Key] = S end
    if Now - S.T >= U.SDE.WIN then S.T, S.Base = Now, {} end
    local Why = nil
    if not U.Rate("hcr" .. Key, U.SDE.HITS_S) then Why = "rate" end
    local WPath = U.EvPath(Ev.Ctx)
    local W = WPath and U.Find(WPath)
    local Shots = A.Coop.Shot and A.Coop.Shot.ServerShots
    if not Why and W and type(Shots) == "table" then
        local Addr = W:GetAddress()
        local Cnt = tonumber(Shots[Addr])
        if Cnt then
            local B = S.Base[Addr]
            if not B then B = { Shots = Cnt - 1, Hits = 0 } S.Base[Addr] = B end
            B.Hits = B.Hits + 1
            if B.Hits > (Cnt - B.Shots) * U.SDE.SHOT_MUL + U.SDE.SHOT_ADD then Why = "shots" end
        end
    end
    local IP = U.MRelVec(Ev.Args[3])
    if not Why and IP then
        local Pawn = H.PawnPC(G)
        -- Review R1: "X and pcall(...)" kuerzt auf einen Wert (PL/TL nil -> U.Dist warf bei jedem Treffer)
        local okP, PL = false, nil
        if Pawn then okP, PL = pcall(U.Loc, Pawn) end
        if okP and PL and U.Dist(PL, IP) > U.SDE.PAWN_R then Why = "far" end
        local TPath = not Why and U.EvPath(Ev.Args[2]) or nil
        local T = TPath and U.Find(TPath)
        local okT, TL = false, nil
        if T then okT, TL = pcall(U.Loc, T) end
        if okT and TL and U.Dist(TL, IP) > U.SDE.TGT_R then Why = "target" end
    end
    if not Why then return end
    H.HCViol = (H.HCViol or 0) + 1
    Net.SecWarn(G, Key, "cb_hitcheck_" .. Why)
    local V = S.Viol
    V[#V + 1] = Now
    while #V > 0 and Now - V[1] > U.SDE.VIOL_WIN do table.remove(V, 1) end
    local Who = tostring(G.PCName or G.PawnName or Key)
    if U.Rate("hclog" .. Key, 1) then
        Log("Treffer-Pruefung: %s verletzt '%s' (%d in 10 s, Waffe %s)", Who, Why, #V, tostring(WPath and WPath:match("[^%.:]+$")))
    end
    if #V < U.SDE.VIOL_N or not WPath then return end
    if U.Opt("combat_hitcheck_deny") then
        if not H.SdeDeny[WPath] then
            local N = 0
            for _ in pairs(H.SdeDeny) do N = N + 1 end
            if N >= U.SDE.DENY_MAX then return end
            Log("Treffer-Pruefung: Waffe %s von %s fuer %d s gesperrt (%d Verstoesse in 10 s)", tostring(WPath:match("[^%.:]+$")),
                Who, U.SDE.DENY_S, #V)
        end
        H.SdeDeny[WPath], H.SdeDenyDirty = Now + U.SDE.DENY_S, true
    elseif Now - (S.WouldAt or -99) > 60 then
        S.WouldAt = Now
        Log("Treffer-Pruefung: %s wuerde gesperrt (%d Verstoesse in 10 s) - combat_hitcheck_deny=0, nur Log", Who, #V)
    end
end

-- Sperrliste cb_sdeny je Sekunde neu (abgelaufene raus, Objekte frisch nachgeschlagen)
function H.SdeDenyTick(Now)
    if not (next(H.SdeDeny) or H.SdeDenyN) then return end
    if not H.SdeDenyDirty and Now < (H.SdeDenyAt or 0) then return end
    H.SdeDenyAt, H.SdeDenyDirty = Now + 1, false
    local Entries = {}
    for WPath, Until in pairs(H.SdeDeny) do
        local W = Now < Until and U.Find(WPath) or nil
        if W then
            Entries[#Entries + 1] = { Func = U.PROJ_WEAPON .. ":SERVER_DamageEvent", Context = W, Tag = "cb_sdeny" }
        else
            H.SdeDeny[WPath] = nil
        end
    end
    pcall(Native.SetDeny, Entries, "ls_combat_sde")
    H.SdeDenyN = #Entries > 0 and #Entries or nil
end

function H.SdeTick(Now, List)
    H.SdeWatch(Now)
    if not H.SdeOn then return end
    for _, Ev in ipairs(List) do
        if Ev.Tag == "cb_sde" and type(Ev.Args) == "table" then
            local Key = H.EvGuest(Ev, false)
            local G = Key and Net.Guests[Key]
            if G then
                if Ev.Distance then H.SdDistAt = Now end
                H.ShotAt[Key] = Now
                H.FdAdd(Key, "hit", Now)
                if U.On("combat_hit_server") then
                    local ok, err = pcall(H.SdeMarker, G, Ev)
                    if not ok and Core.Fail("combat_hit_server", err) then Log("Server-Hitmarker aus: %s", tostring(err)) end
                end
                if U.On("combat_hitcheck") then
                    local ok, err = pcall(H.HitCheck, G, Key, Ev, Now)
                    if not ok and Core.Fail("combat_hitcheck", err) then Log("Treffer-Pruefung aus: %s", tostring(err)) end
                end
                if U.On("combat_killfeed") then H.KfSde(Ev, Key, Now) end
                H.EndProtect(Key, G)
            end
        end
    end
    H.SdeDenyTick(Now)
end

-- ---------------------------------------------------------------- Objektschaden (Host, COMBAT-5, K5 cb_od)
-- Gast-Kugeln/-Bolzen auf Nicht-Fleisch-Ziele (BPI_Damage) rufen Damage_Object nur auf der Gast-Kopie (L_18f5/L_1ced,
-- kein RPC). Gast unterdrueckt das per DLL (ls_combat_od) und meldet cb_od; der Host prueft und ruft dieselbe
-- Funktion auf seiner Kopie (Causer = Gastfigur, wie H.OnBoomReq). Ziel-Klassen (Basis, IsA):
U.OD_CLS = {
    BP_MasterTurret_C = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterTurret.BP_MasterTurret_C",
    BP_Infestation_C = "/Game/Infestation/BP_Infestation.BP_Infestation_C",
    BP_LaboratoryCircuitBox_C = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryCircuitBox.BP_LaboratoryCircuitBox_C",
    BP_ShootingRangeTarget_C = "/Game/Blueprints/Other/Objects/BP_ShootingRangeTarget.BP_ShootingRangeTarget_C",
    TrashObject_C = "/Game/Blueprints/Other/InteractableWorldObject/TrashObject.TrashObject_C",
    BP_EasterEgg_Nuke_C = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C",
}
H.OdQ, H.OdStat = {}, { ok = 0, miss = 0, nowpn = 0, cls = 0, dist = 0, err = 0 }

-- Handler cb_od "<Cls>;<Enc Pfad>;X;Y;Z;<dmg>[;<Treffer>]": nur pruefen und einreihen
-- Abschluss-Runde (combat_od_batch, Faehigkeit cbodn): Gast fasst Treffer je Ziel und Takt (5 Hz) zusammen, Feld 7 =
-- Trefferzahl (Schrotkugeln/hohe Kadenz gingen am 15/s-Limit verloren). Grenze dann ein Treffer-Budget je Gast
-- (60/s) statt der Meldungs-Rate; alte Gaeste ohne Feld 7 / ohne cbodn = 1 Treffer, Kappung 500 wie bisher.
function H.OdIn(Data, G)
    if not (G and G.Key and G.Epoch and Net.Has("cbod", G)) then return end
    local Batch = Net.Has("cbodn", G)
    if not U.Rate("od" .. G.Key, Batch and 30 or 15) then return Net.SecWarn(G, G.Key, "cb_od_rate") end
    if type(Data) ~= "string" or #Data > 700 then return Net.SecWarn(G, G.Key, "cb_od") end
    local P = U.Split(Data)
    local Cls, Path, Pos, Dmg = P[1], Net.Dec(P[2] or ""), U.Vec(P, 3), tonumber(P[6])
    if not (Cls and #Cls <= 96 and Cls:match("^[%w_]+$") and U.MRelPathOk(Path) and Pos and Dmg and Dmg == Dmg
        and Dmg > 0 and Dmg < 1e6) then
        return Net.SecWarn(G, G.Key, "cb_od")
    end
    if #H.OdQ >= 16 then return end
    local N = 1
    if Batch then
        N = math.max(1, math.min(32, math.floor(tonumber(P[7]) or 1)))
        local B, Now = U.RateTab["odn" .. G.Key], os.clock()
        if not B or Now - B.T >= 1 then B = { T = Now, N = 0 } U.RateTab["odn" .. G.Key] = B end
        if B.N >= 60 then return Net.SecWarn(G, G.Key, "cb_od_hits") end
        N = math.min(N, 60 - B.N)
        B.N = B.N + N
    end
    H.OdQ[#H.OdQ + 1] = { Key = G.Key, Epoch = G.Epoch, Cls = Cls, Path = Path, Pos = Pos, Dmg = math.min(500 * N, Dmg),
                          T = os.clock() }
end

function H.OdApply(E, Now)
    local St = H.OdStat
    local G = Net.Guests[E.Key]
    if not (G and G.Epoch == E.Epoch) or os.clock() - E.T > 2 then return end
    local Pawn, PC = H.PawnPC(G)
    if not Pawn then return end
    local W = U.ActiveWeapon(Pawn)
    if not (W and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false)) then St.nowpn = St.nowpn + 1 return end
    local O = E.Path ~= "" and U.Find(E.Path) or nil
    if O then
        local okL, L = pcall(U.Loc, O)
        if not (okL and U.Dist(L, E.Pos) <= 400) then O = nil end
    end
    O = O or H.MRelPick(E.Cls, os.clock(), E.Pos, 400)
    if not O then St.miss = St.miss + 1 return end
    local Base = nil
    for B in pairs(U.OD_CLS) do
        if A.Safe(function() return U.IsA(O, B) end, false) then Base = B break end
    end
    if not Base then St.cls = St.cls + 1 return Net.SecWarn(G, E.Key, "cb_od_class") end
    local okL, L = pcall(U.Loc, O)
    if not okL or U.Dist(U.Loc(Pawn), L) > 20000 then St.dist = St.dist + 1 return Net.SecWarn(G, E.Key, "cb_od_dist") end
    -- AI-2/WORLD-24: Befall gehoert dem Schuetzen (Wellen-KI @02f4 und Kill-Credit ueber die Owner-Kette)
    if Base == "BP_Infestation_C" and U.On("combat_owner_world") and H.OwnerOf(O) ~= Pawn:GetAddress() then
        H.SetOwner(O, Pawn, "combat_owner_world")
    end
    local ok, err = pcall(function() O:Damage_Object(E.Dmg, Pawn, PC) end)
    if not ok then
        St.err = St.err + 1
        if Core.Fail("combat_objdmg", err) then Log("Objektschaden-Relay aus: %s", tostring(err)) end
        return
    end
    St.ok = St.ok + 1
    H.LastHit[U.Name(O)] = { Key = E.Key, T = Now }
    H.ShotAt[E.Key] = Now
    if not H.OdLogged then
        H.OdLogged = true
        Log("Objektschaden-Relay aktiv: %s trifft %s (%.0f)", tostring(G.PCName or E.Key), Base, E.Dmg)
    end
end

-- 0,1 s: hoechstens 8 Meldungen je Tick
function H.OdTick(Now)
    if #H.OdQ == 0 then return end
    local Q = H.OdQ
    H.OdQ = {}
    for I, E in ipairs(Q) do
        if I <= 8 then
            local ok, err = pcall(H.OdApply, E, Now)
            if not ok and Core.Fail("combat_objdmg", err) then Log("Objektschaden-Relay aus: %s", tostring(err)) end
        else
            H.OdQ[#H.OdQ + 1] = E
        end
    end
end

-- ---------------------------------------------------------------- Haltbarkeit (Host, COMBAT-4, K8 cb_dur)
-- Echte Haltbarkeit (Host-Inventar des Gasts) der aktiven Schusswaffe und der Nahkampfwaffe, 1 Hz:
-- Jig:GetEquipmentUID(<Slot-Struct aus RepActorsData>) -> BP_JigMultiplayer:GetDurability(UID) -> NewDur.
-- Nur Structs aus UE (RepActorsData), nie Lua-gebaut; GUID 0 (nicht gefunden) = unbekannt (GetDurability gaebe 0).
H.DurNow = {}
U.MELEE_SLOT = "Jig.PlayerSlot.MeleeWeapon"

function H.DurRead(Jig, Comp, SlotStruct)
    local UidOut, DurOut = {}, {}
    if not pcall(function() Jig:GetEquipmentUID(SlotStruct, UidOut) end) or UidOut.Value == nil then return nil end
    local Uid = UidOut.Value
    local Set = A.Safe(function() return Uid.A ~= 0 or Uid.B ~= 0 or Uid.C ~= 0 or Uid.D ~= 0 end, false)
    if not Set then return nil end
    if not pcall(function() Comp:GetDurability(Uid, DurOut) end) then return nil end
    return tonumber(DurOut.NewDur)
end

-- Rueckgabe Schusswaffe%, Nahkampf% (nil = unbekannt/keine)
function H.DurOf(Pawn)
    local Jig, Comp = U.Prop(Pawn, "BP_JigHelperComp"), U.Prop(Pawn, "BP_JigMultiplayer")
    if not (Jig and Comp) then return nil, nil end
    local Active = A.Safe(function() return Jig.ActiveWeapon.TagName:ToString() end, "")
    local F, Ml = nil, nil
    pcall(function()
        Jig.RepActorsData:ForEach(function(_, E)
            local Row = E:get()
            local Slot = A.Safe(function() return Row[U.REP_SLOT].TagName:ToString() end, nil)
            local W = A.Safe(function() return Row[U.REP_ACTOR] end, nil)
            if not (Slot and W and A.IsAlive(W)) then return end
            if Slot == Active and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then
                F = H.DurRead(Jig, Comp, Row[U.REP_SLOT])
            elseif Slot == U.MELEE_SLOT then
                Ml = H.DurRead(Jig, Comp, Row[U.REP_SLOT])
            end
        end)
    end)
    return F, Ml, Active                       -- Review R1: 3. Wert = aktiver Slot (Tag) der Messung
end

function H.DurState()
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        local Pawn = H.PawnPC(G)
        if not Pawn then H.DurNow[Key] = nil return end
        local F, Ml, Slot = H.DurOf(Pawn)
        H.DurNow[Key] = { F = F, M = Ml }
        if Net.Has("cbdur", G) then
            -- Review R1: "<Schusswaffe>|<Nahkampf>|<Slot>" - der Gast traut F nur, wenn sein aktiver Slot gleich ist
            -- (nach einem Waffenwechsel kam sonst der alte Wert fuer die neue Waffe an); "|" im Tag ausgeschlossen
            Net.State("cb_dur", "d", string.format("%s|%s|%s", F and string.format("%.1f", F) or "-",
                Ml and string.format("%.1f", Ml) or "-", (tostring(Slot or ""):gsub("|", ""))), 2, G)
        end
    end)
end

-- 5.6 ReduceDurability @0178 sucht die UID ueber self.PlayerActiveWeapon, das nur Local_StartShooting (beim Gast)
-- schreibt -> auf der Host-Kopie den aktiven Slot der Gastfigur eintragen (Struct aus UE kopiert, sonst nur TagName)
function H.DurSlot(W, Pawn)
    local Jig = U.Prop(Pawn, "BP_JigHelperComp")
    if not Jig then return end
    local Want = A.Safe(function() return Jig.ActiveWeapon.TagName:ToString() end, nil)
    if not Want or Want == "" or Want == "None" then return end
    local function Cur() return A.Safe(function() return W.PlayerActiveWeapon.TagName:ToString() end, nil) end
    if Cur() == Want then return end
    pcall(function() W.PlayerActiveWeapon = Jig.ActiveWeapon end)
    if Cur() ~= Want then pcall(function() W.PlayerActiveWeapon.TagName = Jig.ActiveWeapon.TagName end) end
    local Done = Cur() == Want
    if Done ~= H.DurSlotOk then
        H.DurSlotOk = Done
        Log("Haltbarkeit: Host-Kopie %s %s", U.Name(W), Done and ("nutzt Slot " .. Want .. " (Abnutzung wie im Einzelspieler)")
            or "- PlayerActiveWeapon nicht setzbar, Abnutzung bleibt aus")
    end
end

-- ---------------------------------------------------------------- Treffer-Hook-Warteschlange (CORE-18)
-- combat_owner_hitq: der Pre-Hook HitFoliageTree/HitTrashObject merkt nur Pfade (keine UFunctions im Hook), der Owner
-- wird hier gesetzt (0,1 s, vor dem Baum-Delay(0.2)). Relay-Treffer setzen den Owner selbst (H.MRelApply).
H.HitQ = {}
function H.HitQTick()
    if #H.HitQ == 0 then return end
    local Q = H.HitQ
    H.HitQ = {}
    for _, E in ipairs(Q) do
        local W, O = U.Find(E.W), U.Find(E.O)
        if W and O then
            local ok, err = pcall(H.HarvestOwner, E.Fn, W, O)
            if not ok and Core.Fail("combat_owner_world", err) then Log("Owner-Trick Treffer-Hook aus: %s", tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------- Schuss-Kette Host (COMBAT-2, combat_fire_trace)
-- ServerFuncChangeActiveSlot (fh_slot, aus der SERVER_ChangeActiveSlot-Ankunft @19217) und MC_WeaponEffects (fh_fx,
-- aus Svr_WeaponEffects @0934) je Gast, dazu Treffer-RPCs (cb_sde) und Schaden (cb_dmg). Zeile alle 10 s bei Aenderung.
H.FdCnt = {}
function H.FdAdd(Key, Kind, Now)
    if not H.FdOn then return end
    local E = H.FdCnt[Key]
    if not E then E = { slot = 0, fx = 0, hit = 0, dmg = 0 } H.FdCnt[Key] = E end
    E[Kind] = (E[Kind] or 0) + 1
    H.FdFirst = H.FdFirst or Now
end

function H.FdTick(Now, List)
    local Want = Net.Side == "host" and U.On("combat_fire_diag") and U.On("combat_fire_trace") and not H.FdDone
        and U.NativeOn()
    if not Want then
        if H.FdOn then pcall(Native.SetWatch, nil, "ls_combat_fdiag") H.FdOn = false end
        return
    end
    if not H.FdOn then
        if Now < (H.FdTryAt or 0) then return end
        H.FdTryAt = Now + 10
        local ok, err = pcall(Native.Watch, U.FdList(true), "ls_combat_fdiag")
        if not ok then
            if Core.Fail("combat_fire_trace", err) then Log("Schuss-Kette aus: %s", tostring(err)) end
            return
        end
        -- Review R1: gleicher Besitzer ls_combat_fdiag wie beim Gast -> dessen Liste ist ersetzt, Flags schliessen sich aus
        H.FdOn, H.FdLogAt, C.FdOn = true, Now + 10, false
        Log("Schuss-Kette Host: DLL-Beobachtung an (Slot-Wechsel, Effekt-Multicast, Treffer-RPC, Schaden je Gast)")
    end
    for _, Ev in ipairs(List) do
        if Ev.Tag == "fh_slot" or Ev.Tag == "fh_fx" then
            local Key = H.EvGuest(Ev, Ev.Tag == "fh_slot")
            if Key then H.FdAdd(Key, Ev.Tag == "fh_slot" and "slot" or "fx", Now) end
        end
    end
    if Now < (H.FdLogAt or 0) or not H.FdFirst then return end
    H.FdLogAt = Now + 10
    for Key, E in pairs(H.FdCnt) do
        local Sig = string.format("Slot-Wechsel %d, Effekt-Multicast %d, Treffer-RPC %d, Schaden %d", E.slot, E.fx, E.hit, E.dmg)
        if Sig ~= E.Sig then
            E.Sig, H.FdLines = Sig, (H.FdLines or 0) + 1
            local G = Net.Guests[Key]
            Log("Schuss-Kette Host %s: %s", tostring(G and (G.PCName or G.PawnName) or Key), Sig)
        end
    end
    if (H.FdLines or 0) >= U.FD_LINES or Now - H.FdFirst > U.FD_SECS then
        H.FdDone, H.FdOn = true, false
        pcall(Native.SetWatch, nil, "ls_combat_fdiag")
        Log("Schuss-Kette Host: Diagnose beendet (%d Zeilen, %.0f min)", H.FdLines or 0, (Now - H.FdFirst) / 60)
    end
end

function H.Fast(Now)
    if U.On("combat_credit") then
        local ok, err = pcall(H.Credit, Now)
        if not ok and Core.Fail("combat_credit", err) then Log("Kill-Credit aus: %s", tostring(err)) end
    end
    for _, Step in ipairs(H.STEPS) do
        if U.On(Step[1]) and (Step[3] or H.Tick5 == 0) then
            local ok, err = pcall(Step[2], Now)
            if not ok and Core.Fail(Step[1], err) then Log("%s aus: %s", Step[1], tostring(err)) end
        end
    end
    H.Tick5 = ((H.Tick5 or 0) + 1) % 2
    -- Runde 9: ein Lesen des DLL-Fensters je Tick fuer alle Host-Auswertungen (cb_dmg, cb_sde, fh_*)
    local okE, List = pcall(H.ReadEvents)
    H.EvList = okE and List or {}
    pcall(H.NativeTick, Now)
    for _, Step in ipairs(H.STEPS9) do
        if not Core.Down[Step[1]] then
            local ok, err = pcall(Step[2], Now, H.EvList)
            if not ok and Core.Fail(Step[1], err) then Log("%s aus: %s", Step[1], tostring(err)) end
        end
    end
end
-- { Schalter, Funktion, jeden Tick (sonst jeden zweiten = 5 Hz) }
H.STEPS = { { "combat_falloff", H.Falloff, true }, { "combat_proj", H.TrackProj, true },
            { "combat_boom", H.CheckExpl, false }, { "combat_infcredit", H.InfTick, false } }
-- Runde 9: { Ausfall-Name (Core.Fail; combat_sde_task/combat_fd_task sind interne Namen), Funktion(Now, Ereignisse) }
H.STEPS9 = { { "combat_sde_task", function(Now, L) H.SdeTick(Now, L) end },
             { "combat_fd_task", function(Now, L) H.FdTick(Now, L) end },
             { "combat_objdmg", function(Now) H.OdTick(Now) end },
             { "combat_owner_hitq", function() H.HitQTick() end },
             { "combat_bolt", function() H.BoltTick() end } }

-- ---------------------------------------------------------------- Owner-Trick (Host, Fix-Plan #1/#2/#3/#17)
-- Die DLL leitet GetPlayerX(0) beim Host auf einen Gast um, wenn die Owner-Kette eines Objekts in den BP-Frames zu
-- einer Gastfigur/einem Gast-PC fuehrt. Decode (fn\...):
--   Stein  BP_MeleePickup.HitFoliageRock @0121 -> HitHarvestableObject -> Rocks-Ubergraph @02d5 GetPlayerCharacter
--          -> JigTryAddItemSomewhere(DA_Rock) @0406, synchron VOR Delay @0457: Owner der Gastwaffe reicht (Frame-Walk).
--   Baum   HitFoliageTree @0121 -> Tree-Ubergraph: Belohnung @0036 erst nach Delay(0.2) @0359 (latente Fortsetzung,
--          keine Waffen-Frames) -> der Baum-Actor selbst braucht den Gast als Owner.
--   Muell  HitTrashObject @0163 ObjectDamaged.Broadcast (Delegate) -> TrashObject-Ubergraph @0167 -> Owner des Muells.
--   Wurf   Throwable/Projektil-Ubergraph (Zuender/Treffer per Timer) -> Owner/Instigator des Wurfkoerpers.
--   UE 5.6: HitFoliageTree/HitTrashObject/HitFoliageRock unveraendert; Stein @0406 vor Delay @059c, Baum Delay @049c,
--          Ertrag ueber GetPlayerCharacter(0)->BP_JigComponent_C (statt BP_JigMultiplayer_C) - Owner-Kette gleich.
--          Neue Waffen (Hammer/Polizeiknueppel: BP_MeleePickup_C, Armbrust: BP_FirearmPickup_C) ueber IsA erfasst.
-- Erster Schlag auf Foliage spawnt den Stein/Baum-Actor mit Owner=null (BeginDeferredActorSpawnFromClass(.., null)),
-- darum Poll: Welt-Actors in 6 m um einen Gast -> Owner = naechster Gast (nur noch Rueckfall fuer Actors ohne Owner).
-- Steine NICHT im Poll: ein Naehe-Owner am Stein steht im innersten Frame und schlaegt die Waffen-Kette (2+ Gaeste:
-- falscher Gast bekaeme die Steine). Baum/Muell: Pre-Hook HitFoliageTree/HitTrashObject setzt Owner = Schlaeger.
U.OWN_WEAP = { "BP_MeleePickup_C", "BP_FirearmPickup_C", "BP_FishingRodPickup_C", "BP_MasterThrowable_C" }
-- Entdeckung: eine Klasse je 0,5 s (Baum jede Sekunde, Muell/Schrotthaufen alle 3 s)
U.OWN_SCAN = { "BP_HarvestableObject_Tree_C", "TrashObject_C", "BP_HarvestableObject_Tree_C",
               "BP_HarvestableObject_ScrapMetal_C" }
-- Treffer-Hooks (Host): Funktion der Nahkampfwaffe -> Klasse des getroffenen Actors
U.OWN_HIT_CLS = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C"
U.OWN_HIT = { HitFoliageTree = "BP_HarvestableObject_Tree_C", HitTrashObject = "TrashObject_C" }
-- Nahkampf-Relay (UE 5.6 MeleeTrace ohne Sweep): Grenzen/Toleranzen (uu, s, ms, je s), DLL-Tag -> Art, Art -> Hit*-Funktion
U.MREL = { GATE = 16, GAP_MS = 250, LOCAL_MAX = 8, PER_MSG = 4, REACH = 450, REACH_Z = 300, TGT_R = 300, LAG_S = 0.3,
           LAG_MAX = 250, TLAG_MAX = 200, INST_R = 400, HARV_R = 150, TREE_IMP = 1200, ROCK_IMP = 400, DEDUP = 0.6,
           SAME_T = 0.35, POWER_MAX = 6, MSG_RATE = 12, HIT_RATE = 30, SW_RATE = 4, Q_MAX = 64, PER_TICK = 24,
           REACH_T = 450, TREE_XY = 250, NOTE_WIN = 2.0, NOTE_WAIT = 0.6, KNOWN_MAX = 256 }
U.MREL_TAG = { cb_mh_b = "B", cb_mh_h = "H", cb_mh_w = "W", cb_mh_t = "T", cb_mh_r = "R" }
U.MREL_FN = { B = "HitBody", H = "HitHead", W = "HitObjectWorld", T = "HitFoliageTree", R = "HitFoliageRock" }
U.MREL_NOTIFY = "/Game/Animations/Notifies/Player/AnimNotify_MeleeHitDetect.AnimNotify_MeleeHitDetect_C"
U.MREL_HARV = { T = "BP_HarvestableObject_Tree_C", R = "BP_HarvestableObject_Rocks_C" }
-- Welt-Ziele (HitObjectWorld): Klassen-Kette muss eine davon enthalten (Bauteile nie -> Claims unberuehrt)
U.MREL_WORLD = { "TrashObject_C", "BP_ExplosiveBarrelMaster_C", "BP_Landmine_C", "Buildable_LandMine_C", "BP_Infestation_C",
                 "BP_MasterTurret_C", "BP_BanditTurret_AI_C", "BP_SurvivorTurret_AI_C", "BP_SecurityCamera_AI_C",
                 "BP_LaboratoryCircuitBox_C", "BP_EasterEgg_Nuke_C", "BP_ShootingRangeTarget_C", "BP_MasterZombie_C" }
H.HitHooked = {}       -- [Fn] = true, wenn der Hook steht (Hooks ueberleben Weltwechsel, nicht zuruecksetzen)
U.OWN_R = 600          -- Welt-Actor bekommt den naechsten Gast in 6 m
U.OWN_HYST = 150       -- anderer Gast behaelt den Owner, solange er in 6 m und hoechstens 1,5 m weiter weg ist
U.OWN_CACHE_R = 5000   -- entdeckte Welt-Actors bis 50 m um einen Gast merken (Pfad + Lage, keine UObjects)
U.OWN_CACHE_MAX = 600

-- Gaeste dieses Ticks (UObjects nur innerhalb des Ticks)
function H.GuestList()
    local Out = {}
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch then return end
        local Pawn, PC = H.PawnPC(G)
        if not Pawn then return end
        local ok, Pos = pcall(U.Loc, Pawn)
        if not ok then return end
        Out[#Out + 1] = { Key = Key, Pawn = Pawn, Pos = Pos, Addr = Pawn:GetAddress(), Name = G.PCName or Key,
                          PCAddr = (PC and A.IsAlive(PC)) and PC:GetAddress() or nil }
    end)
    return Out
end

function H.NearestGuest(Guests, Pos)
    local Best, BestD = nil, math.huge
    for _, Gu in ipairs(Guests) do
        local D = U.Dist(Gu.Pos, Pos)
        if D < BestD then Best, BestD = Gu, D end
    end
    return Best, BestD
end

-- Owner-Adresse (nil = keiner/ungueltig) und Objekt
function H.OwnerOf(O)
    local Cur = A.Safe(function() return O:GetOwner() end, nil)
    if Cur == nil or not A.IsAlive(Cur) then return nil, nil end
    return Cur:GetAddress(), Cur
end

-- Einmal je Objekt + Gast loggen (Tabelle begrenzt)
function H.OwnLog(O, Gu, Fmt, ...)
    local Key = U.Name(O) .. "|" .. (Gu and Gu.Key or "-")
    if H.OwnSeen[Key] then return end
    if H.OwnSeenN >= 2000 then H.OwnSeen, H.OwnSeenN = {}, 0 end
    H.OwnSeen[Key], H.OwnSeenN = true, H.OwnSeenN + 1
    Log(Fmt, ...)
end

function H.SetOwner(O, Pawn, Flag)
    local ok, err = pcall(function() O:SetOwner(Pawn) end)
    if not ok and Core.Fail(Flag, err) then Log("%s aus: %s", Flag, tostring(err)) end
    return ok
end

-- #1 Fix W: angehaengte Gastwaffen (Nahkampf/Schusswaffe/Angel/Wurfkoerper) -> Owner = Gastfigur (Gast-PC gilt auch)
function H.IsOwnWeapon(W)
    for _, Cls in ipairs(U.OWN_WEAP) do
        if A.Safe(function() return U.IsA(W, Cls) end, false) then return true end
    end
    return false
end

function H.OwnWeapons(Guests)
    for _, Gu in ipairs(Guests) do
        for _, W in ipairs(U.Attached(Gu.Pawn)) do
            if H.IsOwnWeapon(W) then
                local CurAddr, Cur = H.OwnerOf(W)
                if CurAddr ~= Gu.Addr and CurAddr ~= Gu.PCAddr then
                    local Old = Cur and U.Name(Cur) or "keiner"
                    if H.SetOwner(W, Gu.Pawn, "combat_owner_weapons") then
                        H.OwnLog(W, Gu, "Owner-Trick: Waffe %s von %s gehoert jetzt der Gastfigur (vorher %s)",
                            U.Name(W), Gu.Name, Old)
                    end
                end
            end
        end
    end
end

-- #1/#2/#3: Welt-Actor O (Lage Pos, Abstand D zum naechsten Gast Gu) -> Owner = Gu, wenn leer oder Spieler/PC
function H.OwnApply(O, Pos, Gu, D, Guests)
    local CurAddr, Cur = H.OwnerOf(O)
    if CurAddr and (CurAddr == Gu.Addr or CurAddr == Gu.PCAddr) then return end
    if Cur and H.HitOwned(O) then return end    -- Baum/Muell mit Owner: Treffer-Hook hat den Schlaeger gesetzt
    if Cur then
        for _, Other in ipairs(Guests) do       -- anderer Gast steht genauso nah: behalten (kein Hin und Her)
            if CurAddr == Other.Addr or CurAddr == Other.PCAddr then
                if U.Dist(Other.Pos, Pos) <= math.min(U.OWN_R, D + U.OWN_HYST) then return end
                break
            end
        end
        local Player = A.Safe(function() return U.IsA(Cur, "BP_PlayerCharacter_C") or U.IsA(Cur, "PlayerController") end, false)
        if not Player then
            H.OwnLog(O, nil, "Owner-Trick: %s hat fremden Owner %s, bleibt unveraendert", U.Name(O), U.Name(Cur))
            return
        end
    end
    local Old = Cur and U.Name(Cur) or "keiner"
    if H.SetOwner(O, Gu.Pawn, "combat_owner_world") then
        H.OwnLog(O, Gu, "Owner-Trick: %s (%.0f m) gehoert jetzt %s (vorher %s) -> Ertrag an den Gast",
            U.Name(O), D / 100, Gu.Name, Old)
    end
end

-- Baum/Muell, deren Treffer-Hook aktiv ist (dann vergibt die Naehe keinen Owner mehr um)
function H.HitOwned(O)
    for Fn, Cls in pairs(U.OWN_HIT) do
        if H.HitHooked[Fn] and A.Safe(function() return U.IsA(O, Cls) end, false) then return true end
    end
    return false
end

-- Pre-Hook (Host): getroffener Baum/Muell -> Owner = Owner der Waffe (Schlaeger), bevor Belohnung/Delegate laeuft
-- CORE-18 (combat_owner_hitq): im Hook nur Pfade merken (GetFullName ist UE4SS-nativ, keine UFunction), hoechstens 32;
-- Relay-Treffer (H.MRelBusy: eigener Hit*-Aufruf) setzen den Owner selbst in H.MRelApply (kein Hook-im-Hook).
function H.OnHarvestHit(Fn, Ctx, Obj)
    if H.MRelBusy or Net.Side ~= "host" or not U.On("combat_owner_world") then return end
    local W, O = Ctx:get(), Obj:get()
    if not (A.IsAlive(W) and A.IsAlive(O)) then return end
    if U.On("combat_owner_hitq") then
        if #H.HitQ >= 32 then return end
        local WP, OP = U.Path(W), U.Path(O)
        if WP and OP then H.HitQ[#H.HitQ + 1] = { Fn = Fn, W = WP, O = OP } end
        return
    end
    H.HarvestOwner(Fn, W, O)
end

-- Owner = Schlaeger (Owner der Waffe), wenn das Ziel ein Baum/Muell ist (alter Weg im Hook, sonst aus H.HitQTick)
function H.HarvestOwner(Fn, W, O)
    if not U.IsA(O, U.OWN_HIT[Fn]) then return end
    local _, P = H.OwnerOf(W)
    if not P or not (U.IsA(P, "BP_PlayerCharacter_C") or U.IsA(P, "PlayerController")) then return end
    if H.OwnerOf(O) == P:GetAddress() then return end
    if H.SetOwner(O, P, "combat_owner_world") then
        H.OwnLog(O, nil, "Owner-Trick: %s gehoert dem Schlaeger %s (Treffer-Hook %s)", U.Name(O), U.Name(P), Fn)
    end
end

-- Einmal, sobald die Nahkampf-Klasse geladen ist (BP-Funktionen erst dann hookbar)
function H.HookHits()
    if H.HitHookTried or not U.Find(U.OWN_HIT_CLS) then return end
    H.HitHookTried = true
    for Fn in pairs(U.OWN_HIT) do
        local Hook = A.TryHook(U.OWN_HIT_CLS .. ":" .. Fn, function(Ctx, Obj)
            local ok, err = pcall(H.OnHarvestHit, Fn, Ctx, Obj)
            if not ok and Core.Fail("combat_owner_world", err) then Log("Owner-Trick Treffer-Hook aus: %s", tostring(err)) end
        end)
        H.HitHooked[Fn] = Hook ~= nil
        Log("Owner-Trick: Treffer-Hook %s %s", Fn, Hook and "aktiv (Baum/Muell gehoeren dem Schlaeger)"
            or "fehlgeschlagen - Rueckfall Naehe-Owner")
    end
end

-- Je Welt einmal: Naehe-Owner an Steinen (aeltere Version) zuruecknehmen -> Belohnung ueber die Waffen-Kette
function H.RockReset()
    local okF, List = pcall(FindAllOf, "BP_HarvestableObject_Rocks_C")
    if not okF or type(List) ~= "table" then return end
    local N = 0
    for _, O in ipairs(List) do
        if A.IsAlive(O) then
            local _, Cur = H.OwnerOf(O)
            if Cur and A.Safe(function() return U.IsA(Cur, "BP_PlayerCharacter_C") or U.IsA(Cur, "PlayerController") end, false)
                and pcall(function() O:SetOwner(nil) end) then
                N = N + 1
            end
        end
    end
    if N > 0 then Log("Owner-Trick: %d Steine ohne Naehe-Owner (Ertrag ueber die Waffen-Kette)", N) end
end

-- Entdeckung: eine Klasse per FindAllOf (nur exakte Klasse), Treffer in 50 m merken, in 6 m sofort setzen
function H.OwnScan(Guests)
    H.OwnIdx = (H.OwnIdx or 0) % #U.OWN_SCAN + 1
    local Cls = U.OWN_SCAN[H.OwnIdx]
    local okF, List = pcall(FindAllOf, Cls)      -- nil ohne Fehler = keine Instanz
    if not okF or type(List) ~= "table" then return end
    local Count = 0
    for _ in pairs(H.OwnCache) do Count = Count + 1 end
    for _, O in ipairs(List) do
        if A.IsAlive(O) then
            local ok, Pos = pcall(U.Loc, O)
            if ok then
                local Gu, D = H.NearestGuest(Guests, Pos)
                if Gu and D <= U.OWN_CACHE_R then
                    local Path = U.Path(O)
                    if Path and not H.OwnCache[Path] and Count < U.OWN_CACHE_MAX then
                        H.OwnCache[Path], Count = { Pos = Pos }, Count + 1
                    end
                    if D <= U.OWN_R then H.OwnApply(O, Pos, Gu, D, Guests) end
                end
            end
        end
    end
end

-- CORE-31 (combat_own_cache): Lagen der Welt-Actors sind statisch -> je Klasse einmal einlesen (FindAllOf + Lage, nur
-- Pfade/Lagen), Baeume alle 5 s neu (entstehen beim ersten Treffer), Muell/Schrott alle 30 s; die Entdeckung im
-- 0,5-s-Takt rechnet nur noch in Lua ueber ein 50-m-Raster. Weg-gemeldete Pfade (H.OwnGone) bis zum Neu-Einlesen aus.
U.OWN_EVERY = { BP_HarvestableObject_Tree_C = 5, TrashObject_C = 30, BP_HarvestableObject_ScrapMetal_C = 30 }
U.OWN_CELL = 5000
H.OwnPos, H.OwnGone = {}, {}

function U.OwnCell(X, Y) return math.floor(X / U.OWN_CELL) .. ":" .. math.floor(Y / U.OWN_CELL) end

-- hoechstens eine faellige Klasse je Aufruf neu einlesen
function H.OwnRefresh(Now)
    for Cls, Every in pairs(U.OWN_EVERY) do
        local E = H.OwnPos[Cls]
        if not E or Now - E.At >= Every then
            local okF, List = pcall(FindAllOf, Cls)      -- nil ohne Fehler = keine Instanz
            local Grid, N = {}, 0
            for _, O in ipairs(okF and type(List) == "table" and List or {}) do
                if A.IsAlive(O) then
                    local ok, Pos = pcall(U.Loc, O)
                    local Path = ok and U.Path(O) or nil
                    if Path then
                        local C2 = U.OwnCell(Pos.X, Pos.Y)
                        Grid[C2] = Grid[C2] or {}
                        Grid[C2][#Grid[C2] + 1] = { P = Path, Pos = Pos }
                        N = N + 1
                        H.OwnGone[Path] = nil
                    end
                end
            end
            H.OwnPos[Cls] = { At = Now, Grid = Grid, N = N }
            return
        end
    end
end

-- Ersatz fuer H.OwnScan: Entdeckung nur ueber die gemerkten Lagen (3x3 Rasterzellen je Gast)
function H.OwnScanCached(Guests)
    local Now = os.clock()
    H.OwnRefresh(Now)
    local Count = 0
    for _ in pairs(H.OwnCache) do Count = Count + 1 end
    for _, Gu in ipairs(Guests) do
        local CX, CY = math.floor(Gu.Pos.X / U.OWN_CELL), math.floor(Gu.Pos.Y / U.OWN_CELL)
        for _, E in pairs(H.OwnPos) do
            for DX = -1, 1 do
                for DY = -1, 1 do
                    for _, R in ipairs(E.Grid[(CX + DX) .. ":" .. (CY + DY)] or {}) do
                        if not H.OwnCache[R.P] and not H.OwnGone[R.P] and Count < U.OWN_CACHE_MAX
                            and U.Dist(Gu.Pos, R.Pos) <= U.OWN_CACHE_R then
                            H.OwnCache[R.P], Count = { Pos = R.Pos }, Count + 1
                        end
                    end
                end
            end
        end
    end
end

-- Jeder Tick: gemerkte Welt-Actors in 6 m frisch nachschlagen (Pfad -> IsAlive) und Owner pruefen
function H.OwnNear(Guests)
    for Path, E in pairs(H.OwnCache) do
        local Gu, D = H.NearestGuest(Guests, E.Pos)
        if not Gu or D > U.OWN_CACHE_R + 1000 then
            H.OwnCache[Path] = nil
        elseif D <= U.OWN_R then
            local O = U.Find(Path)
            if not O then
                H.OwnCache[Path] = nil
                H.OwnGone[Path] = os.clock()
            else
                local ok, Pos = pcall(U.Loc, O)
                if ok then
                    E.Pos = Pos
                    Gu, D = H.NearestGuest(Guests, Pos)
                    if Gu and D <= U.OWN_R then H.OwnApply(O, Pos, Gu, D, Guests) end
                end
            end
        end
    end
end

-- #17: Host-Kopien der Gast-Wurfkoerper (cb_proj) ohne Owner -> Owner/Instigator = Werfer (Spawn setzt beides schon;
-- hier nur Nachkontrolle, falls der Spawn-Parameter nicht griff). Hoechstens 8 Versuche je Wurf.
function H.OwnProj(Guests)
    for _, P in pairs(H.Proj) do
        if not P.Owned then
            P.Tries = (P.Tries or 0) + 1
            if P.Tries >= 8 then P.Owned = true end
            local Gu
            for _, X in ipairs(Guests) do if X.Key == P.Key then Gu = X break end end
            local O = Gu and U.Find(P.Path)
            if O then
                if H.OwnerOf(O) then
                    P.Owned = true
                elseif H.SetOwner(O, Gu.Pawn, "combat_owner_proj") then
                    pcall(function() O.Instigator = Gu.Pawn end)
                    P.Owned = true
                    H.OwnLog(O, Gu, "Owner-Trick: Wurfkoerper %s gehoert jetzt %s (Kill/XP an den Werfer)", P.Cls, Gu.Name)
                end
            end
        end
    end
end

-- 4 Hz: Waffen jede 0,5 s, Entdeckung jede 0,5 s (versetzt), gemerkte Welt-Actors + Wurfkoerper jeden Tick
function H.OwnTick()
    if Net.Side ~= "host" or not U.On("combat_v2") or U.Loading() then return end
    local OnW, OnWo, OnP = U.On("combat_owner_weapons"), U.On("combat_owner_world"), U.On("combat_owner_proj")
    if not (OnW or OnWo or OnP) then return end
    U.CheckWorld()
    if OnWo then
        pcall(H.HookHits)
        if H.RockGen ~= U.Gen then H.RockGen = U.Gen pcall(H.RockReset) end
    end
    local Guests = H.GuestList()
    if #Guests == 0 then return end
    H.OwnN = ((H.OwnN or 0) + 1) % 2
    local Steps = {}
    if OnW and H.OwnN == 0 then Steps[#Steps + 1] = { "combat_owner_weapons", H.OwnWeapons } end
    if OnWo then
        if H.OwnN == 1 then
            -- CORE-31: gemerkte statische Lagen statt FindAllOf + Lage je 0,5 s (Fehler -> combat_own_cache aus, alter Scan)
            if U.On("combat_own_cache") then
                Steps[#Steps + 1] = { "combat_own_cache", H.OwnScanCached }
            else
                Steps[#Steps + 1] = { "combat_owner_world", H.OwnScan }
            end
        end
        Steps[#Steps + 1] = { "combat_owner_world", H.OwnNear }
    end
    if OnP then Steps[#Steps + 1] = { "combat_owner_proj", H.OwnProj } end
    for _, S in ipairs(Steps) do
        local ok, err = pcall(S[2], Guests)
        if not ok and Core.Fail(S[1], err) then Log("%s aus: %s", S[1], tostring(err)) end
    end
end

-- ===================================================================== Client

-- 10 Hz: eigener Schuss erkannt an geaenderter ShotDistance (FireTrace setzt sie bei jedem Treffer)
function C.OwnShot(Now)
    local Pawn = A.Safe(A.OwnPawn, nil)
    if not (Pawn and A.IsAlive(Pawn)) then return end
    local W = C.HandPath and U.Find(C.HandPath)
    if not W then C.LastSD = nil return end
    local SD = A.Safe(function() return W.ShotDistance end, nil)
    if not SD or SD <= 0 then return end
    if C.LastSD == nil then C.LastSD = SD return end
    if math.abs(SD - C.LastSD) < 0.01 then return end
    C.LastSD = SD
    C.ShotsSince = (C.ShotsSince or 0) + 1
    local PC = A.LocalPC()
    if not A.IsAlive(PC) then return end
    local Rot = A.Safe(function() return PC:GetControlRotation() end, nil)
    if not Rot then return end
    local F = U.Forward({ Pitch = Rot.Pitch, Yaw = Rot.Yaw })
    local M0 = U.Loc(W)
    local Pos = { X = M0.X + F.X * SD, Y = M0.Y + F.Y * SD, Z = M0.Z + F.Z * SD }
    local Kind = C.Classify(Pos, Pawn)
    if Kind ~= "w" and U.On("combat_hitmarker") and not C.NativeHitUI then C.Hitmarker(Kind == "h") end
    if Net.Has("cb2") then
        Net.Send("cb_imp", table.concat({ U.Fmt(Pos), Kind, string.format("%.0f", SD) }, ";"), nil, 1)
    end
end

-- combat_muzzle_fix (Gast): BP_PlayerCharacter_C:WeaponWallTrace (Decode fnWeaponWallTrace @0151-@0329) zieht beim
-- Zielen einen Strahl ShootingPoint -> Muzzle + Kamera-Vorwaerts (Objekttypen 0,1,4, ignoriert nur die Figur) und setzt
-- PlayerNearWall? -> "Weapon muzzle blocked", kein Zielen/Schiessen. Hier derselbe Strahl, nur wenn IsADS? und
-- PlayerNearWall? an (hoechstens 1x/s): Treffer loggen (8x) und gehoert der getroffene Actor zur eigenen Figur (Anhang-
-- oder Owner-Kette: Waffe, Aufsatz, Kleidung) -> Kollision dieser Komponente aus. Weltgeometrie bleibt (echte Wand). 0 = aus.
function C.MuzzleTick()
    if Net.Side ~= "client" or not U.On("combat_muzzle_fix") then return end
    local Pawn = A.Safe(A.OwnPawn, nil)
    if not A.IsAlive(Pawn) then return end
    if A.Safe(function() return Pawn["IsADS?"] == true and Pawn["PlayerNearWall?"] == true end, false) ~= true then return end
    local Now = os.clock()
    if Now < (C.MuzAt or 0) then return end
    C.MuzAt = Now + 1
    C.MuzN = (C.MuzN or 0) + 1
    local Say = C.MuzN <= 8
    local W = U.ActiveWeapon(Pawn)
    local Root = A.IsAlive(W) and A.Safe(function() return W:K2_GetRootComponent() end, nil) or nil
    if not A.IsAlive(Root) then if Say then Log("Muendung blockiert: keine aktive Waffe/Wurzel lesbar") end return end
    local Start = A.Safe(function() return Root:GetSocketLocation(FName("ShootingPoint")) end, nil)
    local Mz = A.Safe(function() return Root:GetSocketLocation(FName("Muzzle")) end, nil)
    local PC = A.Safe(function() return Pawn:GetController() end, nil)
    local Cam = A.IsAlive(PC) and A.Safe(function() return PC.PlayerCameraManager end, nil) or nil
    local Fw = A.IsAlive(Cam) and A.Safe(function() return Cam:GetActorForwardVector() end, nil) or nil
    if not (Start and Mz and Fw) then if Say then Log("Muendung blockiert: Socket/Kamera fehlt (Start %s, Muzzle %s, Kamera %s)", tostring(Start ~= nil), tostring(Mz ~= nil), tostring(Fw ~= nil)) end return end
    local End = { X = Mz.X + Fw.X, Y = Mz.Y + Fw.Y, Z = Mz.Z + Fw.Z }
    local Hit, Clear = {}, { R = 0, G = 0, B = 0, A = 0 }
    local Got = A.Safe(function()
        return U.KSL():LineTraceSingleForObjects(Pawn, { X = Start.X, Y = Start.Y, Z = Start.Z }, End, { 0, 1, 4 }, false, {}, 0, Hit, true, Clear, Clear, 0)
    end, false)
    local Len = math.sqrt((End.X - Start.X) ^ 2 + (End.Y - Start.Y) ^ 2 + (End.Z - Start.Z) ^ 2)
    if Got ~= true then if Say then Log("Muendung blockiert: Nachbau trifft nichts (Strahl %.0f uu) - Ursache nicht der Strahl selbst", Len) end return end
    -- Treffer-Komponente ist aus Lua nicht lesbar (schwacher Zeiger) -> Ausschlusstest: Strahl mit ignorierten Actors
    -- wiederholen (1. Waffe, 2. + Aufsaetze, 3. + Ausruestung aus RepActorsData). Die erste Stufe ohne Treffer nennt
    -- den Verursacher; genau diese Actors bekommen Kollision aus. Trifft auch Stufe 3 noch: fremdes Objekt, nur Log.
    local S0 = { X = Start.X, Y = Start.Y, Z = Start.Z }
    local function Hits(Ign)
        local H2 = {}
        return A.Safe(function()
            return U.KSL():LineTraceSingleForObjects(Pawn, S0, End, { 0, 1, 4 }, false, Ign, 0, H2, true, Clear, Clear, 0)
        end, nil)   -- nil = Aufruf fehlgeschlagen (nicht als "kein Treffer" werten)
    end
    local Stage1, Stage2, Stage3 = { W }, { W }, { W }
    local J = A.Safe(function() return W.BP_JigPickupComponent end, nil)
    if A.IsAlive(J) then pcall(function() J.InstalledAttachments:ForEach(function(_, E)
        local At = E:get()
        if A.IsAlive(At) then Stage2[#Stage2 + 1] = At Stage3[#Stage3 + 1] = At end
    end) end) end
    local Jig = A.Safe(function() return Pawn.BP_JigHelperComp end, nil)
    if A.IsAlive(Jig) then pcall(function() Jig.RepActorsData:ForEach(function(_, E)
        local It = E:get()[U.REP_ACTOR]
        if A.IsAlive(It) then Stage3[#Stage3 + 1] = It end
    end) end) end
    local Culprits, Stage = nil, "fremd"
    if Hits(Stage1) == false then Culprits, Stage = Stage1, "Waffe"
    elseif Hits(Stage2) == false then Culprits, Stage = { table.unpack(Stage2, 2) }, "Aufsatz"
    elseif Hits(Stage3) == false then Culprits, Stage = { table.unpack(Stage3, #Stage2 + 1) }, "Ausruestung" end
    -- Live 27.10.: Verursacher = die gehaltene Waffe selbst (Strahl startet in ihrer Kollision). Ganzen Actor ohne
    -- Kollision (Komponentenliste ist hier kein Lua-Array); C.MuzRestore schaltet sie wieder an, sobald der Actor nicht
    -- mehr an der eigenen Figur haengt (abgelegt/gestorben), sonst liesse er sich am Boden nicht aufheben.
    local Names, Fixed = {}, 0
    for _, Ac in ipairs(Culprits or {}) do
        Names[#Names + 1] = A.Safe(function() return Ac:GetFName():ToString() end, "?")
        if pcall(function() Ac:SetActorEnableCollision(false) end) then
            Fixed = Fixed + 1
            local K = A.Safe(function() return Ac:GetAddress() end, nil)
            if K then C.MuzOff = C.MuzOff or {} C.MuzOff[K] = Ac end
        end
    end
    if Say or Fixed > 0 then
        Log("Muendung blockiert: Verursacher %s (%s), Strahl %.0f uu, Treffer %.0f uu, im Objekt gestartet %s, Kollision aus an %d Komponente(n); Stufen %d/%d/%d",
            Stage, #Names > 0 and table.concat(Names, ",") or "-", Len, tonumber(A.Safe(function() return Hit.Distance end, -1)) or -1,
            tostring(A.Safe(function() return Hit.bStartPenetrating end, "?")), Fixed, #Stage1, #Stage2, #Stage3)
    end
end

-- Gast: von C.MuzzleTick abgeschaltete Actors wieder mit Kollision, sobald ihre Anhang-Kette die eigene Figur nicht mehr
-- erreicht (abgelegt, in die Todeskiste, Figur weg). Laeuft auch nach FLAG_DOWN (nur Rueckbau), hoechstens 1x/s.
function C.MuzRestore()
    if not C.MuzOff or next(C.MuzOff) == nil then return end
    local Now = os.clock()
    if Now < (C.MuzRAt or 0) then return end
    C.MuzRAt = Now + 1
    local Pawn = A.Safe(A.OwnPawn, nil)
    local PA = A.IsAlive(Pawn) and A.Safe(function() return Pawn:GetAddress() end, nil) or nil
    for K, Ac in pairs(C.MuzOff) do
        if not A.IsAlive(Ac) then C.MuzOff[K] = nil
        else
            local P, On = Ac, false
            for _ = 1, 4 do
                P = A.Safe(function() return P:GetAttachParentActor() end, nil)
                if not A.IsAlive(P) then break end
                if PA and A.Safe(function() return P:GetAddress() end, nil) == PA then On = true break end
            end
            if not On then
                pcall(function() Ac:SetActorEnableCollision(true) end)
                C.MuzOff[K] = nil
            end
        end
    end
end

-- Diagnose (combat_muzzle_fix, Gast): Waffe beim Zielen nicht angehoben. AnimBP_PlayerCharacter_C.ADS? =
-- PropertyAccess_17 OR _18 (GetThreadSafeBooleans @007c). Beim Zielen bis 6x (alle 2 s) loggen, was Figur und AnimBP sehen.
function C.AdsDiag()
    if Net.Side ~= "client" or not U.On("combat_muzzle_fix") or (C.AdsN or 0) >= 6 then return end
    local Pawn = A.Safe(A.OwnPawn, nil)
    if not A.IsAlive(Pawn) or A.Safe(function() return Pawn["IsADS?"] end, nil) ~= true then return end
    local Now = os.clock()
    if Now < (C.AdsAt or 0) then return end
    C.AdsAt, C.AdsN = Now + 2, (C.AdsN or 0) + 1
    local Mesh = A.Safe(function() return Pawn.Mesh end, nil)
    local AI = A.IsAlive(Mesh) and A.Safe(function() return Mesh:GetAnimInstance() end, nil) or nil
    local function B(O, K) return tostring(A.IsAlive(O) and A.Safe(function() return O[K] end, "?") or "-") end
    Log("Zielen-Diagnose: Figur IsADS %s HoldingFirearm %s NearWall %s | Anim %s ADS %s PA17 %s Pose %s",
        B(Pawn, "IsADS?"), B(Pawn, "HoldingFirearm?"), B(Pawn, "PlayerNearWall?"),
        A.IsAlive(AI) and A.Safe(function() return AI:GetClass():GetFName():ToString() end, "?") or "-",
        B(AI, "ADS?"), B(AI, "K2Node_PropertyAccess_17"), B(AI, "BlendSpaceInt"))
end

-- combat_pose_fix (Gast): Haltepose der Waffe. AnimBP BlendSpaceInt kommt nur ueber den Equip-Ablauf des Gasts
-- (Svr_UpdateCombatState(AnimBlendspace) -> Host MC_UpdateCombatState -> AnimBP CombatState; Decode BP_PlayerCharacter
-- @129f4/@12a27, @228cb, AnimBP EVT_CombatState). Haengt die Waffe nach Join/Wiederherstellung schon in der Hand, lief
-- der Ablauf nie -> Figur "unbewaffnet" (Arm haengt, kein Anheben beim Zielen; Live 27.10.). Hier 1x/s: eigene Figur
-- haelt eine Waffe, AnimBP BlendSpaceInt ~= AnimBlendspace der Waffe (BP_EquipmentPickupComponent_C) zwei Pruefungen in
-- Folge -> Svr_UpdateCombatState(N) (Host verteilt an alle); 2 s spaeter noch falsch -> lokal MC_UpdateCombatState(N)
-- (nur eigene Sicht). Je Waffenwert hoechstens 2 Runden. 0 = aus.
function C.PoseFix()
    if Net.Side ~= "client" or not U.On("combat_pose_fix") then return end
    local Now = os.clock()
    if Now < (C.PoseAt or 0) then return end
    C.PoseAt = Now + 0.1
    local Pawn = A.Safe(A.OwnPawn, nil)
    if not A.IsAlive(Pawn) then return end
    -- Ursache (28.10., Decode @235a9/@10a8f): die Zieh-Animation schickt SERVER_ChangeActiveSlot(ToSlot) kurz vor ihrem
    -- Ende; am Ende vergleicht das Spiel ToSlot mit dem replizierten ActiveWeapon. Bei 30 Server-FPS kommt der Wert
    -- zu spaet -> Else-Zweig: Pose 0, HoldingFirearm? aus. Waehrend des Wechsels nichts tun, danach den Erfolgs-Zweig
    -- sofort nachholen (lokal + Server), statt 1-2 s zu warten
    if A.Safe(function() return Pawn["CurrentlyChangingWeapon?"] end, false) == true then C.PoseTry = nil return end
    -- Live 27.10.: Wegstecken setzt die Pose beim Gast ebenfalls nicht zurueck -> leere Hand (Slot gelesen und leer) = 0
    local W, Slot, Readable = U.ActiveWeapon(Pawn)
    local Empty = not A.IsAlive(W) and Readable == true and (Slot == nil or Slot == "" or Slot == "None")
    if not A.IsAlive(W) and not Empty then C.PoseTry = nil return end
    local Mesh = A.Safe(function() return Pawn.Mesh end, nil)
    local AI = A.IsAlive(Mesh) and A.Safe(function() return Mesh:GetAnimInstance() end, nil) or nil
    local Cur = A.IsAlive(AI) and tonumber(A.Safe(function() return AI.BlendSpaceInt end, nil)) or nil
    if not Cur then return end
    local Eq = not Empty and A.Safe(function() return W.BP_EquipmentPickupComponent end, nil) or nil
    if not Empty and not A.IsAlive(Eq) then
        C.EqCls = C.EqCls or A.Safe(function()
            local O = FindFirstOf("BP_EquipmentPickupComponent_C")
            return A.IsAlive(O) and O:GetClass() or nil
        end, nil)
        Eq = C.EqCls and A.Safe(function() return W:GetComponentByClass(C.EqCls) end, nil) or nil
    end
    local Want = Empty and 0 or (A.IsAlive(Eq) and tonumber(A.Safe(function() return Eq.AnimBlendspace end, nil)) or nil)
    if not Want or Want == Cur then C.PoseTry = nil return end
    local T = C.PoseTry
    if not T or T.Want ~= Want then C.PoseTry = { Want = Want, Since = Now } return end
    if Now - T.Since < 0.15 or (T.Sent and Now - T.Sent < 3) or (T.Tries or 0) >= 3 then return end
    T.Sent, T.Tries = Now, (T.Tries or 0) + 1
    -- Erfolgs-Zweig des Spiels (@10afb/@10b06) fuer Schusswaffen nachholen: HoldingFirearm? an (Zielen/Schiessen)
    if Want > 0 and A.IsAlive(W) and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then
        pcall(function() Pawn["HoldingFirearm?"] = true end)
        pcall(function() Pawn["HoldingMelee?"] = false end)
        pcall(function() Pawn:UpdateAmmoCount() end)
    end
    -- sofort lokal (eigene Sicht ohne Rundreise), dazu an den Host (verteilt an alle; gleicher Wert, kein Flackern)
    local okL = pcall(function() Pawn:MC_UpdateCombatState(Want) end)
    local okS = pcall(function() Pawn:Svr_UpdateCombatState(Want) end)
    C.PoseLogN = (C.PoseLogN or 0) + 1
    if C.PoseLogN <= 10 then
        Log("Haltepose: Anim %d -> %d nachgeholt (lokal %s, Server %s)", Cur, Want, okL and "ok" or "Fehler", okS and "ok" or "Fehler")
    end
end

-- Schuss-Diagnose (combat_fire_diag, Gast, je ClientTick, nur lesen). 5.6: IA_PrimaryAction @131b6 (Sperren) -> GetActiveWeapon
-- muss Schusswaffe sein -> Local_StartShooting @0018 FireReady, @01c9 Waffen-Slot im Inventar-Widget gueltig/nicht pending,
-- @031e Kammer ("No ammo"), @05ab/@083f Magazin ("No mag in firearm"/"No ammo") -> FireBullet (DurabilityCheck
-- "Weapon jammed") -> MuzzleEffects. Pre-Hook auf die seltene Bibliotheksfunktion zaehlt diese Hinweise
-- (CreateNotificationUI(Message, Icon, Colour, Delay, Force, __WorldContext), Aufrufe z.B. Local_StartShooting @0a62/@0b67).
-- ChamberContainer/CurrentMag/PlayerActiveWeapon schreibt nur Local_StartShooting (@0039/@02a1/@0455/@0705).
C.FIRE_NOTES = { ["No ammo"] = true, ["No mag in firearm"] = true, ["Weapon jammed"] = true,
                 ["Weapon muzzle blocked"] = true, ["You need to ADS to fire"] = true }
C.FireNotes = C.FireNotes or {}      -- [Hinweis] = Anzahl seit Sitzungsbeginn (nur mit combat_fire_diag_note)
U.NOTE_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"

-- Hinweis-Hook nur mit combat_fire_diag_note=1 (CORE-18: ~290 Aufrufstellen, Regel 3). Der Koerper prueft zuerst den
-- Schalter (C.NoteOn, je Diagnose-Tick gesetzt) und zaehlt nur in eine Lua-Tabelle.
function C.FireNoteHook()
    if C.FireNoteTried or not U.Find(U.NOTE_FN) then return end
    C.FireNoteTried = true
    C.FireNoteOk = A.TryHook(U.NOTE_FN, function(_, Text)
        if not C.NoteOn then return end
        local ok, T = pcall(function() return Text:get():ToString() end)
        if ok and C.FIRE_NOTES[T] then C.FireNotes[T] = (C.FireNotes[T] or 0) + 1 end
    end) ~= nil
    Log("Schuss-Diagnose: Hinweis-Hook %s", C.FireNoteOk and "aktiv" or "fehlgeschlagen")
end

-- Hinweise als Text ("No ammo x2, ..."), "-" ohne, "aus" ohne Hook
function C.NotesText()
    if not C.NoteOn then return "aus (combat_fire_diag_note=0)" end
    local Out = {}
    for T, N in pairs(C.FireNotes) do Out[#Out + 1] = string.format("%s x%d", T, N) end
    table.sort(Out)
    return #Out > 0 and table.concat(Out, ", ") or "-"
end

-- Unterobjekt nur, wenn es lebt (Regel 1: nie Eigenschaften einer ungueltigen Huelle lesen)
function U.Prop(Obj, Name)
    local O = A.Safe(function() return Obj[Name] end, nil)
    if O and A.IsAlive(O) then return O end
    return nil
end

-- Spielinstanz (InSafeZone?): Pfad merken, FindFirstOf hoechstens alle 10 s (wie ls_world W.GameInstance)
function C.GameInstance()
    local GI = C.GIPath and U.Find(C.GIPath)
    if GI then return GI end
    if os.clock() < (C.GIAt or 0) then return nil end
    C.GIAt = os.clock() + 10
    GI = A.Safe(function() return FindFirstOf("SD_GameInstance_C") end, nil)
    if GI and A.IsAlive(GI) then C.GIPath = U.Path(GI) return GI end
    return nil
end

-- Stille Sperren von IA_PrimaryAction (@1331f-@1358c, Reihenfolge wie im Spiel), jede mit eigener Lesefunktion
C.FIRE_GATES = {
    { "SafeZone", function(P) local GI = C.GameInstance() return GI and GI["InSafeZone?"] end },
    { "Schwimmen", function(P) local CM = U.Prop(P, "CharacterMovement") return CM and CM:IsSwimming() end },
    { "Rolle", function(P) return P["IsPlayerRolling?"] end },
    { "Fernglas", function(P) return P["UsingBinoculars?"] end },
    { "Fotomodus", function(P) local O = U.Prop(P, "PhotoModeComponent") return O and O["UsingPhotoMode?"] end },
    { "Nachladen", function(P) return P["Reloading?"] end },
    { "Leiter", function(P) return P["ClimbingLadder?"] end },
    { "Baumodus", function(P) local O = U.Prop(P, "BuildingComponent") return O and O["BuildModeOn?"] end },
    { "Fahrzeug", function(P) return P["InVehicle?"] end },
    { "Inventar", function(P)
        local J, T = U.Prop(P, "BP_JigMultiplayer"), {}
        if not J then return nil end
        J["IsInventoryVisible?"](J, T)
        return T.Result
    end },
    { "Waffenwechsel", function(P) return P["CurrentlyChangingWeapon?"] end },
    { "Journal", function(P) return P["JournalOpen?"] end },
}

-- 1 Hz (M.ClientTick): Zustand der ganzen Abzug-Kette als eine Zeile, nur bei Aenderung (hoechstens 30 Zeilen).
-- Waffe nach Spiel-Sicht (U.ActiveWeapon, COMBAT-3), Slot-Gegenstand des Widgets (C.SlotState), alle stillen Sperren.
function C.FireDiag(Pawn, Now)
    if not (Pawn and A.IsAlive(Pawn)) then return end
    C.NoteOn = U.Opt("combat_fire_diag_note")
    if C.NoteOn then pcall(C.FireNoteHook) end
    if C.NoteOn and next(C.FireNotes) and Now >= (C.FireNoteAt or 0) then
        local Text = C.NotesText()
        if Text ~= C.FireNoteSig then
            C.FireNoteAt, C.FireNoteSig = Now + 10, Text
            Log("Schuss-Diagnose: Hinweise %s", Text)
        end
    end
    if (C.FireLogN or 0) >= 30 then return end          -- Zeilen verbraucht: keine Lesearbeit mehr
    local W, Slot = U.ActiveWeapon(Pawn)
    local Gun = Slot and (Slot:find("Primary") or Slot:find("Secondary") or Slot:find("Sidearm"))
    local Fire = W ~= nil and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false)
    if not Fire and not Gun then return end              -- Nahkampf/Werkzeug/leer: nichts zu pruefen
    local function V(O, K) return tostring(A.Safe(function() return O[K] end, "?")) end
    local function Ok(O, K) return tostring(A.Safe(function() return U.Prop(O, K) ~= nil end, false)) end
    local P = { "Slot " .. tostring(Slot) }
    if W then
        P[#P + 1] = "Waffe " .. U.Name(W) .. (Fire and "" or " (KEINE Schusswaffe)")
        if Fire then
            local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
            local _, Own = H.OwnerOf(W)
            local Cur = U.Prop(Pawn, "CurrentFiringWeapon")
            P[#P + 1] = "FireReady " .. V(W, "FireReady")
            P[#P + 1] = "Abzug-Slot " .. tostring(A.Safe(function() return W.PlayerActiveWeapon.TagName:ToString() end, "?"))
            P[#P + 1] = "Kammer " .. Ok(W, "ChamberContainer")
            P[#P + 1] = "Magazin " .. Ok(W, "CurrentMag")
            P[#P + 1] = "Owner " .. (Own and (Own:GetAddress() == Pawn:GetAddress() and "Figur" or U.Name(Own)) or "keiner")
            P[#P + 1] = "Socket " .. A.Safe(function() return W:GetAttachParentSocketName():ToString() end, "?")
            P[#P + 1] = "Projektil " .. (WC and V(WC, "DoesWeaponUseAProjectile?") or "?")
            P[#P + 1] = "Feuerwaffe-Ref " .. tostring(Cur ~= nil and Cur:GetAddress() == W:GetAddress())
        end
    else
        P[#P + 1] = "Waffe - (kein Actor im Slot)"
    end
    if Slot then
        local okS, St, _, N = pcall(C.SlotState, Pawn, Slot)
        P[#P + 1] = "Slot-Item " .. (okS and string.format("%s (%d Container)", tostring(St), N or 0) or "Fehler")
    end
    local Gates = {}
    for _, G in ipairs(C.FIRE_GATES) do
        if A.Safe(function() return G[2](Pawn) end, nil) == true then Gates[#Gates + 1] = G[1] end
    end
    P[#P + 1] = "| Sperren: " .. (#Gates > 0 and table.concat(Gates, "+") or "-")
    P[#P + 1] = "| ADS " .. V(Pawn, "IsADS?")
    P[#P + 1] = "Hueftfeuer " .. V(Pawn, "HipFire?")
    P[#P + 1] = "Halten " .. V(Pawn, "HoldingFirearm?")
    P[#P + 1] = "Wand " .. V(Pawn, "PlayerNearWall?")
    local Sig = table.concat(P, ", ")
    if Sig ~= C.FireSig and (C.FireLogN or 0) < 30 then
        C.FireSig, C.FireLogN = Sig, (C.FireLogN or 0) + 1
        Log("Schuss-Diagnose: %s", Sig)
    end
end

-- COMBAT-2: Slot-Gegenstand wie BP_MainJigInventory_C.GetJSIContainerByPlayerSlots (Local_StartShooting @0120/@01c9):
-- InventoryWidgetRef.Priv_Containers (Array-Property, :ForEach; = GetListOfContainers) -> ContainerTag == Slot ->
-- JSIContainer_C.GetEquippedItemRef(Found?, ItemRef, IsPending), je Out-Parameter eine Tabelle (main.lua RefillHotbar).
-- Rueckgabe Zustand, Gegenstand (JSI_Slot_C), Anzahl Container. Zustand: "ok" | "pending" | "missing" (Container ohne
-- Gegenstand) | "noslot" (kein Container mit dem Tag) | "nolist" (Containerliste nicht lesbar) | "nowidget" (kein
-- Inventar-Widget). Ausser "ok" bricht Local_StartShooting bei @01c9 still ab.
function C.SlotState(Pawn, Slot)
    local Comp = U.Prop(Pawn, "BP_JigMultiplayer")
    local Wid = Comp and U.Prop(Comp, "InventoryWidgetRef") or nil
    if not Wid then return "nowidget", nil, 0 end
    local St, Item, N = "noslot", nil, 0
    pcall(function()
        Wid.Priv_Containers:ForEach(function(_, E)
            N = N + 1
            local Ct = E:get()
            if not (Ct and A.IsAlive(Ct)) then return end
            if A.Safe(function() return Ct.ContainerTag.TagName:ToString() end, "") ~= Slot then return end
            St = "missing"
            local F, R, P = {}, {}, {}
            if pcall(function() Ct:GetEquippedItemRef(F, R, P) end) and F["Found?"] == true and R.ItemRef
                and A.IsAlive(R.ItemRef) then
                Item = R.ItemRef
                St = P.IsPending == true and "pending" or "ok"
            end
            return true
        end)
    end)
    if N == 0 then St = "nolist" end
    return St, Item, N
end

-- Gleiche Waffe? Daten-Asset des Widget-Gegenstands (GetJigDA, wie main.lua IR.AssetOf) == ItemDataAsset der Waffe
function C.SameItem(Item, W)
    local DA = A.Safe(function() local Out = {} Item:GetJigDA(Out) return Out.JigDataAsset end, nil)
    local WDA = A.Safe(function() local J = U.Prop(W, "BP_JigPickupComponent") return J and J.ItemDataAsset end, nil)
    return DA ~= nil and WDA ~= nil and A.IsAlive(DA) and A.IsAlive(WDA) and DA:GetAddress() == WDA:GetAddress()
end

-- COMBAT-1 (combat_fire_slotfix, 2 Hz aus C.Fast): aktive Schusswaffe ohne gueltigen/nicht wartenden Gegenstand im
-- Slot-Container des Inventar-Widgets -> Local_StartShooting @01c9 bricht still ab (Fabis Symptom: Waffe gezogen, ADS
-- geht, kein Schuss, kein Hinweis). Wartend > 8 s und gleiche Waffe -> Wartestatus lokal loesen (JSI_Slot_C.SetPending
-- false, wie das Spiel nach der Server-Antwort; der Server bleibt massgeblich, Bewegungen sind UID-geprueft). Fehlt der
-- Gegenstand > 3 s -> gezielte Reparatur ueber ls_inv (E5 A.Coop.Inv.RepairSlot, nie eine zweite Datenantwort),
-- sonst Hinweis. Je Fehl-Episode (gleiche Waffe, gleicher Zustand) hoechstens ein Versuch.
function C.FireSlotGuard(Pawn, Now)
    local W, Slot = U.ActiveWeapon(Pawn)
    if not (W and Slot) or A.Safe(function() return Pawn["CurrentlyChangingWeapon?"] end, false) == true
        or not A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then
        C.SlotBad = nil
        return
    end
    local St, Item = C.SlotState(Pawn, Slot)
    if St == "ok" then
        if C.SlotBad and C.SlotBad.Done then Log("Schuss-Sperre: Waffen-Slot %s wieder in Ordnung", Slot) end
        C.SlotBad = nil
        return
    end
    local WAddr = W:GetAddress()
    local B = C.SlotBad
    if not B or B.W ~= WAddr or B.St ~= St then
        B = { T = Now, St = St, W = WAddr }
        C.SlotBad = B
    end
    if B.Done or Now - B.T < (St == "pending" and 8 or 3) then return end
    B.Done = true
    if St == "nowidget" or St == "nolist" then
        -- keine Reparatur moeglich, nur fuer den Live-Test benennen (Local_StartShooting findet dann keinen Slot)
        Log("Schuss-Sperre: Waffe %s im Slot %s, aber %s - Abzug bricht ab", U.Name(W), Slot,
            St == "nowidget" and "kein Inventar-Widget (InventoryWidgetRef)" or "Widget ohne Container-Liste")
        return
    end
    if St == "pending" and Item and C.SameItem(Item, W) then
        local ok = pcall(function() Item:SetPending(false, 1.0, 0) end)
        Log("Schuss-Sperre: Waffen-Slot %s wartete %.0f s -> Wartestatus lokal geloest (%s)", Slot, Now - B.T, tostring(ok))
        return
    end
    local Inv = A.Coop and A.Coop.Inv
    local Asked = false
    if type(Inv) == "table" and type(Inv.RepairSlot) == "function" then
        local okR, R = pcall(Inv.RepairSlot, Slot, St)
        Asked = okR and R == true
    end
    Log("Schuss-Sperre: Waffe %s im Slot %s, Inventar-Slot %s -> Reparatur %s", U.Name(W), Slot, St,
        Asked and "angefordert" or "nicht moeglich")
    pcall(A.ShowNote, "Waffe im Inventar nicht synchron - Waffe einmal weglegen und neu ausruesten")
end

-- ---- Schuss-Kette (combat_fire_trace, COMBAT-2): DLL-Beobachter, nur zaehlen (keine Lua-Hooks in der Feuer-Kette),
-- Besitzer "ls_combat_fdiag". Gast (local=1): Klick (Eintritt, sieht auch den ProcessEvent-Aufruf der Eingabe) ->
-- Ziehen -> Slot-RPC -> Abzug (Local_StartShooting) -> Schuss-/Effekt-/Treffer-RPC (Aufrufstellen im Bytecode).
-- Host: fh_slot/fh_fx (H.FdTick). Zeile alle 10 s bei Aenderung; aus nach 30 Zeilen bzw. 20 min ab dem ersten
-- Ereignis (das Ereignis-Fenster der DLL teilt sie mit dem Nahkampf-Relay). Lesart der Zeile:
--   Klick > 0, Abzug = 0         -> stille Sperre in IA_PrimaryAction oder GetActiveWeapon (Schuss-Diagnose: Sperren)
--   Abzug > 0, Schuss-RPC = 0    -> FireReady / Slot-Gegenstand (Slot-Item) / Munition bzw. Magazin (Hinweise)
--   Schuss-RPC > 0, Effekt-RPC = 0 -> Haltbarkeit ("Weapon jammed") oder TryUseBullet (UI-Magazin leer)
--   Effekt-RPC > 0, Host Effekt-Multicast = 0 -> Server verwirft den RPC (Owner/Replikation)
--   Ziehen > 0, Slot-RPC = 0     -> Ausruest-Notify (Montage) feuert nicht
U.FT_CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
U.FD_TAGS = { "fd_click", "fd_equip", "fd_slot", "fd_start", "fd_shot", "fd_fx", "fd_hit" }
U.FD_NAMES = { fd_click = "Klick", fd_equip = "Ziehen", fd_slot = "Slot-RPC", fd_start = "Abzug", fd_shot = "Schuss-RPC",
               fd_fx = "Effekt-RPC", fd_hit = "Treffer-RPC" }
U.FD_LINES, U.FD_SECS = 30, 1200

-- Watch-Liste (zur Laufzeit gebaut: U.PROJ_WEAPON steht weiter unten)
function U.FdList(Host)
    local Wp, L = U.PROJ_WEAPON, nil
    if Host then
        L = { { Func = U.FT_CHAR .. ":ServerFuncChangeActiveSlot", Tag = "fh_slot", At = "call" },
              { Func = Wp .. ":MC_WeaponEffects", Tag = "fh_fx", At = "call" } }
    else
        L = { { Func = U.FT_CHAR .. ":InpActEvt_IA_PrimaryAction_K2Node_EnhancedInputActionEvent_64", Tag = "fd_click",
                At = "entry" },
              { Func = U.FT_CHAR .. ":EquipFirearm", Tag = "fd_equip", At = "call" },
              { Func = U.FT_CHAR .. ":SERVER_ChangeActiveSlot", Tag = "fd_slot", At = "call" },
              { Func = Wp .. ":Local_StartShooting", Tag = "fd_start", At = "call" },
              { Func = Wp .. ":Svr_WeaponShot", Tag = "fd_shot", At = "call" },
              { Func = Wp .. ":Svr_WeaponEffects", Tag = "fd_fx", At = "call" },
              { Func = Wp .. ":SERVER_DamageEvent", Tag = "fd_hit", At = "call" } }
    end
    for _, E in ipairs(L) do E.Mode, E.Local = "observe", not Host end
    return L
end

-- Gast: Beobachter setzen/abmelden; true = an
function C.FdWatch(Now)
    local Want = Net.Side == "client" and U.On("combat_fire_diag") and U.On("combat_fire_trace") and not C.FdDone
        and U.NativeOn()
    if not Want then
        if C.FdOn then pcall(Native.SetWatch, nil, "ls_combat_fdiag") C.FdOn = false end
        return false
    end
    if C.FdOn then return true end
    if Now < (C.FdTryAt or 0) then return false end
    C.FdTryAt = Now + 10
    local ok, err = pcall(Native.Watch, U.FdList(false), "ls_combat_fdiag")
    if not ok then
        if Core.Fail("combat_fire_trace", err) then Log("Schuss-Kette aus: %s", tostring(err)) end
        return false
    end
    -- Review R1: gleicher Besitzer ls_combat_fdiag wie beim Host -> dessen Liste ist ersetzt, Flags schliessen sich aus
    C.FdOn, C.FdCnt, C.FdLogAt, H.FdOn = true, C.FdCnt or {}, Now + 10, false
    Log("Schuss-Kette: DLL-Beobachtung an (Klick, Ziehen, Slot-RPC, Abzug, Schuss-, Effekt-, Treffer-RPC)")
    return true
end

-- Gast: Ereignisse zaehlen, alle 10 s eine Zeile bei Aenderung, Selbst-Abschaltung
function C.FdCount(List, Now)
    for _, Ev in ipairs(List) do
        if U.FD_NAMES[Ev.Tag] and Ev.Remote ~= true then
            C.FdCnt[Ev.Tag] = (C.FdCnt[Ev.Tag] or 0) + 1
            C.FdFirst = C.FdFirst or Now
        end
    end
    if Now < (C.FdLogAt or 0) or not C.FdFirst then return end
    C.FdLogAt = Now + 10
    local Parts = {}
    for _, Tag in ipairs(U.FD_TAGS) do Parts[#Parts + 1] = string.format("%s %d", U.FD_NAMES[Tag], C.FdCnt[Tag] or 0) end
    local Sig = table.concat(Parts, ", ") .. ", Hinweise " .. C.NotesText()
    if Sig ~= C.FdSig then
        C.FdSig, C.FdLines = Sig, (C.FdLines or 0) + 1
        Log("Schuss-Kette: %s", Sig)
    end
    if (C.FdLines or 0) >= U.FD_LINES or Now - C.FdFirst > U.FD_SECS then
        C.FdDone, C.FdOn = true, false
        pcall(Native.SetWatch, nil, "ls_combat_fdiag")
        Log("Schuss-Kette: Diagnose beendet (%d Zeilen, %.0f min) - neu nach Neustart des Spiels", C.FdLines or 0,
            (Now - C.FdFirst) / 60)
    end
end

-- ---- Objektschaden (Gast, COMBAT-5, combat_objdmg): Damage_Object der sechs Nicht-Fleisch-Klassen an der Aufrufstelle
-- unterdruecken (Besitzer "ls_combat_od", Tag cb_odw) und eigene Treffer (Aufrufer = eigene Schusswaffe oder Bolzen)
-- als cb_od an den Host melden. Faehigkeit cbod = "Relay unterstuetzt" (beide Seiten mit combat_objdmg); der Gast
-- unterdrueckt nur, solange der Host cbod hat (Review R2: Host-Schalter aus/Core.Fail/alter Host -> Unterdrueckung
-- weg, Treffer wieder lokal). Bereit erst, wenn netcore_watchinfo.txt "cb_odw ... call suppress" zeigt; davor werden
-- nur Treffer gemeldet, die die DLL schon unterdrueckt hat; sonst bleibt alles wie bisher (nur lokale Kopie).
function U.OdList()
    local L = {}
    for _, Path in pairs(U.OD_CLS) do
        L[#L + 1] = { Func = Path .. ":Damage_Object", Tag = "cb_odw", Mode = "suppress", At = "call" }
    end
    return L
end

function C.OdWatch(Now)
    -- Review R2: nur mit Host-Faehigkeit cbod unterdruecken; faellt sie weg (Host-Schalter aus, Core.Fail beim Host,
    -- Trennung), meldet der Zweig unten die Unterdrueckung ab -> Treffer wirken wieder auf der lokalen Kopie
    local Want = Net.Side == "client" and U.On("combat_objdmg") and U.NativeOn() and Net.Has("cbod")
    if not Want then
        -- Review R1: auch eine gespeicherte Liste ohne Flag (Native.Watch speichert vor dem Schreiben) abmelden
        if C.OdOn or Native.Watches.ls_combat_od then pcall(Native.SetWatch, nil, "ls_combat_od") end
        if C.OdReady then Log("Objektschaden-Relay (cb_od): aus") end
        C.OdOn, C.OdReady = false, false
        return false
    end
    if not C.OdOn or (not C.OdReady and Now - (C.OdWatchAt or -99) > 10) then
        C.OdWatchAt = Now
        if pcall(Native.Watch, U.OdList(), "ls_combat_od") then C.OdOn = true end
    end
    if C.OdOn and Now >= (C.OdInfoAt or 0) then
        C.OdInfoAt = Now + 2
        local Text = Core.ReadAll(Native.Path("watchinfo", ".txt")) or ""
        local Ready = ("\n" .. Text):find("\ncb_odw\t%x+\tcall\tsuppress") ~= nil
        if Ready ~= (C.OdReady == true) then
            C.OdReady = Ready
            Log("Objektschaden-Relay (cb_od): %s", Ready and "bereit (Kugeln/Bolzen auf Geschuetze, Befall, Schaltkasten, "
                .. "Zielscheiben, Muell treffen beim Host)" or "nicht bereit")
        end
    end
    return C.OdOn
end

function C.OdEvents(List)
    if not Net.Has("cbod") then return end
    -- Abschluss-Runde (combat_od_batch): je Schrotkugel ein Damage_Object (FireTrace @004f-@0c5b), unterdrueckt und
    -- ueber 15/s verworfen = Schaden weg. Darum Treffer je Ziel und Takt summieren, eine Meldung mit Trefferzahl;
    -- nur mit Host-Faehigkeit cbodn (alter Host kappte die Summe auf 500), sonst einzeln wie bisher
    local Batch = U.On("combat_od_batch") and Net.Has("cbodn")
    local Clock, Sum = os.clock(), C.OdCarry
    C.OdCarry = {}
    for _, Ev in ipairs(List) do
        -- Review R2: vor "bereit" (watchinfo bis 2 s alt) nur Treffer melden, die die DLL sicher unterdrueckt hat
        -- (Flag "s"); sonst liefen sie lokal UND beim Host
        if Ev.Tag == "cb_odw" and (C.OdReady or Ev.Suppressed == true) and type(Ev.Args) == "table" then
            local Cls, Path = U.MRelObj(Ev.Ctx)
            local CCls, CPath = U.MRelObj(Ev.Caller)
            local Dmg = tonumber(Ev.Args[1])
            local Own = CCls == "BP_ProjectileArrow_C" or (CPath ~= nil and C.OwnFire[CPath] == true)
            if Own and Cls and Path and Dmg and Dmg > 0 then
                if Batch then
                    if Dmg < 1e6 then
                        local S = Sum[Path]
                        if not S or Clock - S.T > 1.5 then
                            S = { Cls = Cls, Dmg = 0, DmgI = 0, N = 0, T = Clock }
                            Sum[Path] = S
                        end
                        S.Dmg, S.DmgI, S.N = S.Dmg + Dmg, S.DmgI + math.floor(Dmg), S.N + 1
                    end
                elseif U.Rate("od_tx", 15) then
                    C.OdSend(Cls, Path, Dmg)
                end
            end
        end
    end
    if Batch then C.OdFlush(Sum, Clock) end
end

-- Sammelbetrieb: je Ziel eine Meldung, hoechstens 8 Ziele je Takt; von der Rate abgelehnte bzw. ueberzaehlige Summen
-- bleiben als Uebertrag (C.OdCarry) fuer den naechsten Takt, bis 1,5 s nach ihrem ersten Treffer (spaeter waere der
-- Schaden unplausibel verspaetet; der Host verwirft Eintraege aelter als 2 s)
function C.OdFlush(Sum, Clock)
    local Sent = 0
    for Path, S in pairs(Sum) do
        if Clock - S.T <= 1.5 then
            if Sent < 8 and U.Rate("od_tx", 15) then
                Sent = Sent + 1
                C.OdSend(S.Cls, Path, S.Dmg, S.N, S.DmgI)
            else
                C.OdCarry[Path] = S
            end
        end
    end
end

-- Eine cb_od-Meldung; N (Trefferzahl, Feld 7) nur im Sammelbetrieb. Ziel weg oder ohne Lage -> verworfen
function C.OdSend(Cls, Path, Dmg, N, DmgI)
    local O = U.Find(Path)
    -- Review R1: "O and pcall(...)" kuerzte auf einen Wert (P immer nil -> cb_od wurde nie gesendet)
    local okL, P = false, nil
    if O then okL, P = pcall(U.Loc, O) end
    if not (okL and P) then return end
    local F = { Cls, Net.Enc(Path), U.Fmt(P), string.format("%.2f", Dmg) }
    if N then
        -- Geschuetz: Deduct zieht je Treffer FTrunc(Schaden) ab (BP_TurretAIComponent_C @0030) -> Summe der
        -- ganzzahligen Teile (wie im Einzelspieler)
        if DmgI and DmgI > 0 and A.Safe(function() return U.IsA(O, "BP_MasterTurret_C") end, false) then
            F[4] = string.format("%.2f", DmgI)
        end
        F[5] = tostring(math.min(N, 32))
    end
    Net.Send("cb_od", table.concat(F, ";"), nil, 1)
end
C.OwnFire = {}      -- [Pfad] = true: eigene Schusswaffen (1 Hz, M.ClientTick)
C.OdCarry = C.OdCarry or {}   -- Abschluss-Runde (combat_od_batch): [Pfad] = { Cls, Dmg, DmgI, N, T } nicht gesendet

-- Review R1 (cb_fast, 10 Hz, vor der combat_v2-/Lade-Pruefung): DLL-Listen und Sperren einer verlassenen Rolle
-- abmelden. C.OdWatch/C.FdWatch laufen nur als Gast (C.Fast -> C.EvTick), H.SdeWatch/H.FdTick nur als Host (H.Fast);
-- ohne diesen Schritt blieb z. B. die Gast-Unterdrueckung ls_combat_od nach dem Trennen im Einzelspieler bzw. als
-- Host aktiv (Damage_Object auf Geschuetz, Befall, Schaltkasten, Zielscheibe, Muell, Atombombe bis zum Neustart
-- wirkungslos). Im Normalfall nur Feld-Vergleiche; keine UObjects ausser den Waffen-Pfaden der Haltbarkeits-Sperre.
function M.RoleWatchOff()
    local Client, Host, V2 = Net.Side == "client", Net.Side == "host", U.On("combat_v2")
    -- Objektschaden (Gast): nur mit combat_v2 und laufendem Ereignis-Lesen (combat_c_ev), sonst Treffer weder lokal
    -- noch per cb_od -> Unterdrueckung weg; C.OdWatch setzt sie als Gast neu
    if (C.OdOn or Native.Watches.ls_combat_od) and (not Client or not V2 or Core.Down.combat_c_ev) then
        pcall(Native.SetWatch, nil, "ls_combat_od")
        if C.OdReady then Log("Objektschaden-Relay (cb_od): aus (Rolle/Schalter)") end
        C.OdOn, C.OdReady = false, false
    end
    -- Schuss-Kette: Gast und Host teilen den Besitzer ls_combat_fdiag; C.FdOn/H.FdOn schliessen sich aus (das Setzen
    -- der einen Seite loescht das Flag der anderen), daher loescht hier keine Seite die lebende Liste der anderen
    if C.FdOn and (not Client or not V2 or Core.Down.combat_c_ev) then
        pcall(Native.SetWatch, nil, "ls_combat_fdiag")
        C.FdOn = false
    end
    if H.FdOn and (not Host or not V2) then
        pcall(Native.SetWatch, nil, "ls_combat_fdiag")
        H.FdOn = false
    end
    -- SERVER_DamageEvent-Beobachtung und Sperrliste (Host), wie H.MRelHostOff
    if (H.SdeOn or H.SdeDenyN) and (not Host or not V2) then
        pcall(Native.SetWatch, nil, "ls_combat_sde")
        if H.SdeDenyN or next(H.SdeDeny) then pcall(Native.SetDeny, {}, "ls_combat_sde") end
        H.SdeOn, H.SdeEntry, H.SdeDeny, H.SdeDenyN = false, false, {}, nil
        Log("SERVER_DamageEvent-Beobachtung (cb_sde): aus (Rolle/Schalter)")
    end
    -- Haltbarkeits-Sperre (Gast): ohne Gast-Rolle oder combat_dur_v2 laeuft C.DurGate nicht mehr -> Abzug freigeben
    if next(C.DurBlockedSet) and (not Client or not U.On("combat_dur_v2")) and not U.Loading() then
        C.DurRelease(nil)
        Log("Haltbarkeit: Abzug wieder frei (Rolle/Schalter)")
    end
end

-- Gast, 5 Hz: ein Lesen des DLL-Fensters (Cursor "_ls_combat_c") fuer Schuss-Kette (fd_*) und Objektschaden (cb_odw)
function C.EvTick(Now)
    local Fd = C.FdWatch(Now)
    local Od = C.OdWatch(Now)
    if not (Fd or Od) then return end
    local ok, List = pcall(Native.Events, "_ls_combat_c")
    if not ok or type(List) ~= "table" then return end
    if Fd then
        local okF, errF = pcall(C.FdCount, List, Now)
        if not okF and Core.Fail("combat_fire_trace", errF) then Log("Schuss-Kette aus: %s", tostring(errF)) end
    end
    if Od then
        local okO, errO = pcall(C.OdEvents, List)
        if not okO and Core.Fail("combat_objdmg", errO) then Log("Objektschaden-Relay aus: %s", tostring(errO)) end
    end
end

-- ---- Haltbarkeit (Gast, COMBAT-4): Host-Wert cb_dur (K8). Schusswaffe <= 0: Abzug sperren (FireReady = false haelt
-- Local_StartShooting @0018 an), Hinweis "Weapon jammed"; nur mit combat_dur_gate=1, sonst nur Log "wuerde sperren"
-- (eine falsche Sperre wuerde das Schiessen der Gaeste wieder ganz verhindern).
-- Review R1: Menge statt eines Pfads (nach einem Waffenwechsel blieb die alte Waffe sonst fuer immer gesperrt, das
-- Spiel setzt FireReady nur nach einem Schuss zurueck). [Pfad] = true, nur Pfade (Weltwechsel leert, U.CheckWorld).
C.DurBlockedSet = {}

-- Gesperrte Waffen freigeben (ausser Keep) und aus der Menge nehmen: FireReady nie erneut auf einer nicht mehr
-- gesperrten Waffe setzen (wuerde die Feuerraten-Pause des Spiels @0c4a -> Delay -> @0106 ueberschreiben)
function C.DurRelease(Keep)
    for P in pairs(C.DurBlockedSet) do
        if P ~= Keep then
            local O = U.Find(P)
            if O then pcall(function() O.FireReady = true end) end
            C.DurBlockedSet[P] = nil
        end
    end
end

function C.DurGate(Pawn, Now)
    -- Abschluss-Runde: Host-Wert nur, solange der Host misst (cbdur); zieht er die Faehigkeit zurueck (combat_dur_v2
    -- aus/Core.Fail), bleibt C.Dur im Spiegel stehen -> nicht mehr vertrauen, Sperre loest unten C.DurRelease(nil)
    local D = Net.Has("cbdur") and C.Dur or nil
    local W, Slot = U.ActiveWeapon(Pawn)
    local Fire = W and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false)
    -- Review R1: Host-Wert gilt nur fuer den Slot, den der Host gemessen hat (D.S nil = alter Host ohne Slot-Tag)
    local Trust = D and (D.S == nil or D.S == Slot)
    local Broken = Fire and Trust and D.F and D.F <= 0
    if not Broken or not U.Opt("combat_dur_gate") then
        if next(C.DurBlockedSet) then
            C.DurRelease(nil)
            Log("Haltbarkeit: Abzug wieder frei")
        end
        if Broken and Now - (C.DurWouldAt or -99) > 60 then
            C.DurWouldAt = Now
            Log("Haltbarkeit: %s laut Host kaputt (%.1f) - wuerde Abzug sperren (combat_dur_gate=0)", U.Name(W), D.F)
        end
        return
    end
    local P = U.Path(W)
    if not P then return end                 -- ohne Pfad keine Freigabe moeglich -> nicht sperren
    C.DurRelease(P)                          -- jede andere gesperrte Waffe sofort frei
    pcall(function() W.FireReady = false end)
    if not C.DurBlockedSet[P] then
        C.DurBlockedSet[P] = true
        Log("Haltbarkeit: %s laut Host kaputt (%.1f) - Abzug gesperrt", U.Name(W), D.F)
    end
    local Clicks = C.FdCnt and C.FdCnt.fd_click or 0
    if Now - (C.DurNoteAt or -99) >= (Clicks ~= C.DurClicks and 3 or 30) then
        C.DurNoteAt, C.DurClicks = Now, Clicks
        pcall(A.ShowNote, "Weapon jammed")
    end
end

-- Einschlag auf einer Figur? (KI in 90 uu, Kopf ab +45 uu ueber der Mitte)
function C.Classify(Pos, Own)
    local OwnAddr = Own:GetAddress()
    for _, Ch in ipairs(A.Characters() or {}) do
        if A.IsAlive(Ch) and Ch:GetAddress() ~= OwnAddr then
            local ok, L = pcall(U.Loc, Ch)
            if ok then
                local DX, DY, DZ = Pos.X - L.X, Pos.Y - L.Y, Pos.Z - L.Z
                if DX * DX + DY * DY < 8100 and DZ > -110 and DZ < 110 then return DZ > 45 and "h" or "b" end
            end
        end
    end
    return "w"
end

function C.Hitmarker(Head)
    local Pawn = A.Safe(A.OwnPawn, nil)
    local UI = Pawn and A.Safe(function() return Pawn.InGameUI end, nil)
    if not (UI and A.IsAlive(UI)) then return end
    local Color = Head and { R = 1, G = 0, B = 0, A = 1 } or { R = 1, G = 1, B = 1, A = 1 }
    pcall(function() UI:Hitmarker(Color) end)
end

-- Fremder Einschlag: nur FX (Trace_* wuerden SERVER_DamageEvent bzw. lokalen Objektschaden ausloesen)
function C.ShowImpact(Pos, Kind, From)
    if not U.NearOwn(Pos, U.NEAR) then return end
    local Dir = { X = Pos.X - From.X, Y = Pos.Y - From.Y, Z = Pos.Z - From.Z }
    local Back = U.RotFromDir({ X = -Dir.X, Y = -Dir.Y, Z = -Dir.Z })
    if Kind == "b" then
        U.Emitter(U.FX.Body, Pos, Back, 1)
        local N = math.random(1, 8)
        U.Sound(U.Asset(U.FX.BodySnd) and U.FX.BodySnd or string.format(U.FX.BodySnd53, N, N), Pos)
    elseif Kind == "h" then
        U.Emitter(U.FX.Head, Pos, Back, 0.6)
        local N = math.random(1, 5)
        U.Sound(U.Asset(U.FX.HeadSnd) and U.FX.HeadSnd or string.format(U.FX.HeadSnd53, N, N), Pos)
    else
        local R = { Pitch = Back.Pitch, Yaw = Back.Yaw, Roll = math.random(0, 359) }
        U.Emitter(U.FX.World, Pos, R, 1)
        local Decal = U.Asset(U.FX.Decal)
        if Decal then
            pcall(function()
                U.GS():SpawnDecalAtLocation(A.CurrentWorld(), Decal, { X = 20, Y = 10, Z = 10 }, Pos, R, 30)
            end)
        end
    end
end

function C.OnImpact(Data)
    if not U.On("combat_impacts") or C.NativeTrail then return end
    local P = U.Split(Data)
    local Pos, Kind, From = U.Vec(P, 1), P[4], U.Vec(P, 5)
    if not (Pos and From) or not U.Rate("imp_show", 20) then return end
    local ok, err = pcall(C.ShowImpact, Pos, Kind, From)
    if not ok and Core.Fail("combat_impacts", err) then Log("Einschlaege aus: %s", tostring(err)) end
end

-- ---------------------------------------------------------------- Wurf/Projektil (Client)

-- Hook-Body (ReceiveBeginPlay, selten): nur Name + Zeit in eine Lua-Tabelle
function C.HookBody(Ctx)
    if #C.Queue >= 64 then return end
    local O = Ctx:get()                                   -- CORE-20: erst IsValid, dann GetFullName
    if not (O and A.IsAlive(O)) then return end
    local ok, Path = pcall(function() return O:GetFullName() end)
    if ok and Path then C.Queue[#C.Queue + 1] = { Path = Path:match("^%S+%s+(.+)$") or Path, T = os.clock() } end
end

-- ReceiveBeginPlay kommt aus C++ (ProcessEvent) und ist fuer den N4b-Beobachter unsichtbar: immer der Lua-Hook.
-- UE 5.6: BP_ProjectileRocket_C/BP_ProjectileGrenade_C haben kein ReceiveBeginPlay mehr (fn_diff "removed", Hook schlug
-- im Gast-Log fehl) -> UserConstructionScript (SetLifeSpan(5), ebenfalls einmal je Spawn aus C++). Nur Funktionen, die
-- es in der geladenen Klasse gibt (StaticFindObject), sonst die naechste; nichts gefunden -> deutlich loggen.
C.HOOK_FNS = { "ReceiveBeginPlay", "UserConstructionScript" }
function C.RegisterHooks()
    if not U.On("combat_proj_hook") then return end
    C.Hooked = C.Hooked or {}
    for Cls, Info in pairs(U.PROJ) do
        if not C.Hooked[Cls] and U.Find(Info.Path) then
            C.Hooked[Cls] = true
            local Done = nil
            local Order = Info.Hook and { Info.Hook } or {}
            for _, Fn in ipairs(C.HOOK_FNS) do if Fn ~= Info.Hook then Order[#Order + 1] = Fn end end
            for _, Fn in ipairs(Order) do
                if U.Find(Info.Path .. ":" .. Fn) and A.TryHook(Info.Path .. ":" .. Fn, C.HookBody) ~= nil then
                    Done = Fn
                    break
                end
            end
            if Done then
                if Done ~= "ReceiveBeginPlay" then Log("Wurf/Projektil-Hook %s:%s aktiv (UE 5.6)", Cls, Done) end
            else
                Log("Wurf/Projektil-Hook fuer %s nicht moeglich - eigene Schuesse dieser Klasse werden nicht gemeldet", Cls)
            end
        end
    end
end

function C.ProcessQueue(Now)
    if #C.Queue == 0 then return end
    local Queue = C.Queue
    C.Queue = {}
    for _, E in ipairs(Queue) do
        if not C.Visual[E.Path] then
            local ok, err = pcall(C.OwnProj, E, Now)
            if not ok and Core.Fail("combat_proj", err) then Log("Wurf/Projektil aus: %s", tostring(err)) end
        end
    end
end

function C.OwnProj(E, Now)
    local O = U.Find(E.Path)
    if not O then return end
    if A.Safe(function() return O.Role end, 0) ~= U.ROLE_AUTHORITY then return end
    local Cls = U.Name(O:GetClass())
    local Info = U.PROJ[Cls]
    if not Info then return end
    local Pos = U.Loc(O)
    if not U.NearOwn(Pos, 3000) then return end
    local Vel
    if Info.Throw then
        local Cap = A.Safe(function() return O.Capsule end, nil)
        Vel = A.IsAlive(Cap) and A.Safe(function() return Cap:GetPhysicsLinearVelocity(FName("None")) end, nil) or nil
    else
        local PM = A.Safe(function() return O.ProjectileMovement end, nil)
        Vel = A.IsAlive(PM) and A.Safe(function() return PM.Velocity end, nil) or nil
    end
    Vel = Vel and { X = Vel.X, Y = Vel.Y, Z = Vel.Z } or { X = 0, Y = 0, Z = 0 }
    local Fuse = Info.Throw and tonumber(A.Safe(function() return O.ExplosionDelay end, 0)) or 0
    if not Net.Has("cb2") then return end         -- Host ohne ls_combat: lokale Kopie bleibt wie bisher
    U.ZeroDamage(O, Info)                         -- die eigene Kopie ist nur noch Bild, Schaden macht der Host
    C.Lid = (C.Lid or 0) + 1
    local Lid = tostring(C.Lid)
    C.Own[Lid] = E.Path
    local Data = table.concat({ Lid, Cls, U.Fmt(Pos), string.format("%.0f;%.0f;%.0f", Vel.X, Vel.Y, Vel.Z),
        string.format("%.2f", Now - E.T), string.format("%.2f", Fuse) }, ";")
    Net.Send("cb_proj", Data, nil, 0)
    Log("Eigener Wurf/Schuss %s an den Host gemeldet", Cls)
end

-- Fremder Wurf: schadenlose Sicht-Kopie
function C.OnProjFx(Data)
    if not U.On("combat_proj") then return end
    local P = U.Split(Data)
    local Gid, Cls = P[1], P[2]
    local Info = U.PROJ[Cls or ""]
    local Loc, Vel, Fuse = U.Vec(P, 3), U.Vec(P, 6), tonumber(P[9]) or 0
    if not (Gid and Info and Loc and Vel) or not U.NearOwn(Loc, U.NEAR * 2) then return end
    local Speed = math.sqrt(Vel.X * Vel.X + Vel.Y * Vel.Y + Vel.Z * Vel.Z)
    local Rot = Speed > 1 and U.RotFromDir(Vel) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local Pawn = A.OwnPawn()
    local R = U.Spawn(Pawn, Cls, Loc, Rot, function(Obj, I)
        U.ZeroDamage(Obj, I)
        if I.Throw and Fuse > 0 then Obj.ExplosionDelay = Fuse end
    end)
    if not R then return end
    U.Launch(R, Info, Vel)
    local Path = U.Path(R)
    if Path then C.Visual[Path] = Gid end
    C.VisualGid["p:" .. Gid] = os.clock()
end

-- ---- Armbrust-Bolzen (Gast, COMBAT-7, combat_bolt): eigener Pfeil -> lokaler Bolzen weg, Lage an den Host (cb_bolt)
C.BoltQ, C.Arrows, C.BoltDone = {}, {}, {}

-- Hook-Koerper (Pfeil-Spawn beim Schuetzen, selten): nur Pfad + Zeit merken; Schalter C.BoltOn aus C.Fast
function C.BoltHookBody(Ctx)
    if not C.BoltOn or #C.BoltQ >= 8 then return end
    local O = Ctx:get()
    if not (O and A.IsAlive(O)) then return end
    local ok, Full = pcall(function() return O:GetFullName() end)
    if ok and Full then C.BoltQ[#C.BoltQ + 1] = { Path = Full:match("^%S+%s+(.+)$") or Full, T = os.clock() } end
end

-- 1 Hz: Hook setzen, sobald die Pfeil-Klasse geladen ist; neue UFunction-Adresse (Klasse neu geladen) -> neu hooken
function C.BoltHook()
    local Fn = U.Find(U.BOLT.ARROW) and U.Find(U.BOLT.ARROW .. ":ReceiveBeginPlay")
    local Addr = Fn and A.Safe(function() return Fn:GetAddress() end, nil) or nil
    if not Addr or Addr == C.BoltFnAddr then return end
    C.BoltFnAddr = Addr
    local Ok = A.TryHook(U.BOLT.ARROW .. ":ReceiveBeginPlay", C.BoltHookBody) ~= nil
    Log("Armbrust-Bolzen: Pfeil-Hook %s", Ok and "aktiv (Bolzen liegen beim Host)" or "fehlgeschlagen - Bolzen bleiben lokal")
end

-- 5 Hz: eigene Pfeile verfolgen; still (Treffer) oder weg -> hoechstens zwei Suchen nach dem frischen lokalen Bolzen
function C.BoltTick(Now)
    if #C.BoltQ > 0 then
        local Q = C.BoltQ
        C.BoltQ = {}
        for _, E in ipairs(Q) do
            if #C.Arrows < U.BOLT.ARROWS then C.Arrows[#C.Arrows + 1] = { Path = E.Path, T = E.T, Scans = 0 } end
        end
    end
    local Scan, Keep = false, {}
    for _, R in ipairs(C.Arrows) do
        local O = not R.Drop and U.Find(R.Path) or nil
        -- nur eigene Pfeile (lokal gespawnt: Rolle Authority)
        if O and not R.Own then
            if A.Safe(function() return O.Role end, 0) == U.ROLE_AUTHORITY then R.Own = true else O, R.Drop = nil, true end
        end
        if O then
            local ok, P = pcall(U.Loc, O)
            if ok then
                R.Still = R.Pos ~= nil and U.Dist(R.Pos, P) < 5
                R.Pos = P
            end
        elseif not R.Drop then
            R.Gone = true
        end
        R.Due = not R.Drop and R.Pos ~= nil and (R.Still or R.Gone) and R.Scans < 2 and Now - (R.ScanAt or -9) >= 0.3
        if R.Due then Scan = true end
        if not R.Drop and Now - R.T < U.BOLT.ARROW_S and not (R.Gone and R.Scans >= 2) and (R.Pos or not R.Gone) then
            Keep[#Keep + 1] = R
        end
    end
    C.Arrows = Keep
    if Scan then C.BoltScan(Now) end
end

-- Frische lokale Bolzen (Authority, nicht geladen, frei, < 10 s) -> je faelligem Pfeil der naechste in 3 m
function C.BoltScan(Now)
    local okF, List = pcall(FindAllOf, U.BOLT.PICK_CLS)
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    local Cands = {}
    for _, O in ipairs(okF and type(List) == "table" and List or {}) do
        if A.IsAlive(O) then
            local Name = U.Name(O)
            local Fresh = not C.BoltDone[Name] and A.Safe(function()
                if O.Role ~= U.ROLE_AUTHORITY or (WL and O:HasAnyFlags(WL)) then return false end
                if A.IsAlive(O:GetOwner()) or A.IsAlive(O:GetAttachParentActor()) then return false end
                local Age = tonumber(O:GetGameTimeSinceCreation())
                return Age ~= nil and Age < 10
            end, false)
            local okL, P = false, nil
            if Fresh then okL, P = pcall(U.Loc, O) end
            if okL then Cands[#Cands + 1] = { O = O, Name = Name, Pos = P } end
        end
    end
    for _, R in ipairs(C.Arrows) do
        if R.Due then
            R.Due, R.Scans, R.ScanAt = false, R.Scans + 1, Now
            local Best, BestD = nil, U.BOLT.MATCH
            for _, Cd in ipairs(Cands) do
                local D = not Cd.Used and U.Dist(Cd.Pos, R.Pos) or nil
                if D and D <= BestD then Best, BestD = Cd, D end
            end
            if Best then
                Best.Used, R.Drop = true, true
                C.BoltDone[Best.Name] = Now
                pcall(function() Best.O:K2_DestroyActor() end)
                Net.Send("cb_bolt", U.Fmt(Best.Pos), nil, 1)
                C.BoltSent = (C.BoltSent or 0) + 1
                if C.BoltSent <= 3 then Log("Armbrust-Bolzen an den Host gemeldet (%s)", U.Fmt(Best.Pos)) end
            end
        end
    end
end

-- ---- Kill-Feed (Gast, COMBAT-13, K7 cb_kf): pruefen, Text bauen, einreihen; Anzeige aus C.Fast (A.ShowNote)
U.KF_TEXT = { z = "einem Zombie", a = "einem Tier", h = "einem Menschen", t = "einem Geschuetz" }
C.KfQ = {}
function C.OnKf(Data)
    if not U.On("combat_killfeed") or type(Data) ~= "string" or #Data > 400 or #C.KfQ >= 8 then return end
    if not U.Rate("kf", 6) then return end
    local P = U.Split(Data)
    if #P < 5 then return end
    local Killer, Victim, Weapon = Net.Dec(P[1]), Net.Dec(P[2]), Net.Dec(P[3])
    local M = tonumber(P[5])
    if Victim == "" or #Killer > 64 or #Victim > 64 or #Weapon > 64 or not M or M < 0 or M > 100000 then return end
    local Text
    if Killer ~= "" then
        local Info = {}
        if Weapon ~= "" then Info[#Info + 1] = Weapon end
        if P[4] == "1" then Info[#Info + 1] = "Kopftreffer" end
        if M > 0 then Info[#Info + 1] = string.format("%d m", math.floor(M)) end
        Text = string.format("%s hat %s getoetet", Killer, Victim)
        if #Info > 0 then Text = Text .. " (" .. table.concat(Info, ", ") .. ")" end
    elseif U.KF_TEXT[Weapon] then
        Text = string.format("%s wurde von %s getoetet", Victim, U.KF_TEXT[Weapon])
    else
        Text = string.format("%s ist gestorben", Victim)
    end
    C.KfQ[#C.KfQ + 1] = Text
end

-- ---------------------------------------------------------------- Explosionen (Client)

function C.OnBoom(Data)
    if not U.On("combat_boom") then return end
    local P = U.Split(Data)
    local Src, Pos, Kind, Mine, Cls = P[1], U.Vec(P, 2), P[5], P[6], P[7]
    if not (Src and Pos) then return end
    local Now = os.clock()
    local Skip = Mine == "1" or (C.VisualGid[Src] and Now - C.VisualGid[Src] < 60)
    if Src:sub(1, 2) == "e:" then
        -- Host-Pfad != Gast-Pfad bei Laufzeit-Actors: Abgleich ueber Lage (+ Klasse), nie ueber den Host-FName allein
        C.HostBoom[#C.HostBoom + 1] = { T = Now, Pos = Pos }
        if C.RecentBoom(C.LocalBoom, Pos, Now, 30) then Skip = true end
        local O, LocalPath = U.MatchExpl(Src:sub(3), Pos, Cls, 200, 2000)
        if O then pcall(function() O:K2_DestroyActor() end) end
        if LocalPath then U.Expl[LocalPath] = nil end
    end
    if Skip or not U.NearOwn(Pos, U.NEAR * 2) then return end
    pcall(U.Emitter, U.FX.Boom, Pos, { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 }, 1.5)
    pcall(U.Sound, U.FX.BoomSnd, Pos)
end

-- Liste { T, Pos } (HostBoom/LocalBoom, lagebasiert): Eintrag in 200 uu juenger als MaxAge? Alte (> 60 s) raus
function C.RecentBoom(List, Pos, Now, MaxAge)
    local Hit = false
    for I = #List, 1, -1 do
        local B = List[I]
        if Now - B.T > 60 then table.remove(List, I)
        elseif Now - B.T < MaxAge and U.Dist(B.Pos, Pos) <= 200 then Hit = true end
    end
    return Hit
end

-- 5 Hz: lokal explodiert, ohne dass der Host es gemeldet hat -> Host soll es ausloesen
-- cb_boomreq: Pfad;X;Y;Z;Klasse (Host nimmt den Pfad nur bei passender Klasse + Lage, sonst Klasse + naechste Lage)
function C.CheckExpl(Now)
    for Path, E in pairs(U.Expl) do
        if U.ExplGone(Path, E) then
            U.Expl[Path] = nil
            if not C.RecentBoom(C.HostBoom, E.Pos, Now, 10) and U.NearOwn(E.Pos, U.NEAR) and Net.Has("cb2") and U.Rate("boomreq", 5) then
                C.LocalBoom[#C.LocalBoom + 1] = { T = Now, Pos = E.Pos }
                Net.Send("cb_boomreq", table.concat({ Path, U.Fmt(E.Pos), E.Cls or "" }, ";"), nil, 0)
            end
        end
    end
end

-- ---------------------------------------------------------------- 1 Hz Client: Nahkampf, Friendly Fire, Aufsaetze

C.CVAR = "Difficulty.MultiHit"
function C.ConsoleUtils()
    return U.Find("/Script/AutoSettings.Default__ConsoleUtils")
end

-- COMBAT-15 (combat_multihit_restore): Merker-Datei, solange MultiHit vom Mod angeschaltet ist; nach einem Absturz
-- stellt der naechste Start ohne Host-Verbindung (C.MhRestoreTask) bzw. das naechste "gone" den alten Wert zurueck
function C.MhPath() return A.ModDir .. "ls_multihit.txt" end

function C.MeleeGuard()
    local CU = C.ConsoleUtils()
    if CU and C.MultiHitOld == nil then
        C.MultiHitOld = A.Safe(function() return CU:GetBoolCVar(FName(C.CVAR)) end, nil)
        if C.MultiHitOld == false then
            pcall(function() CU:SetBoolCVar(FName(C.CVAR), true) end)
            Log("Nahkampf: lokale Treffer aus (MultiHit lokal an, MaxActorsToHitInSwing?=0)")
            if U.On("combat_multihit_restore") and not C.MhMarker then
                local ok, Done = pcall(Core.WriteAtomic, C.MhPath(), "0\n")
                if ok and Done then C.MhMarker = true
                elseif not ok and Core.Fail("combat_multihit_restore", Done) then
                    Log("MultiHit-Merker aus: %s", tostring(Done))
                end
            end
        end
    end
    for _, Pawn in ipairs(A.PlayerPawns() or {}) do
        -- Nahkampf-Relay offen: eigene Waffe steht auf U.MREL.GATE (C.MRelGate), nur Zuschauer-Kopien auf 0
        if A.IsAlive(Pawn) and not (C.MRelGateOpen and C.MOwnPawnAddr ~= nil and Pawn:GetAddress() == C.MOwnPawnAddr) then
            for _, W in ipairs(U.Attached(Pawn)) do
                if A.Safe(function() return U.IsA(W, "BP_MeleePickup_C") end, false) then
                    local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
                    if WC and A.Safe(function() return WC["MaxActorsToHitInSwing?"] end, 0) ~= 0 then
                        pcall(function() WC["MaxActorsToHitInSwing?"] = 0 end)
                    end
                end
            end
        end
    end
end

function C.RestoreMultiHit()
    if C.MultiHitOld == false or C.MhMarker == true then
        local CU = C.ConsoleUtils()
        local ok = CU ~= nil and pcall(function() CU:SetBoolCVar(FName(C.CVAR), false) end)
        Log("Nahkampf: MultiHit zurueckgesetzt%s", C.MultiHitOld == false and "" or " (Merker einer frueheren Sitzung)")
        if C.MhMarker then
            C.MhMarker = false                   -- ohne ConsoleUtils: Datei bleibt fuer den naechsten Start
            if ok then pcall(Core.Remove, C.MhPath()) end
        end
    end
    C.MultiHitOld = nil
end

-- Start (COMBAT-15): Merker vorhanden -> fruehestens 10 s nach dem Laden, ohne Host-Verbindung (Solo, Menue, eigener
-- Host) MultiHit auf aus und Merker loeschen; Rueckgabe true beendet die Aufgabe (als Gast erledigt das "gone")
function C.MhRestoreTask(Now)
    if not C.MhMarker or not U.On("combat_multihit_restore") then return true end
    if Now - (C.MhInitAt or Now) < 10 or Net.Side == "client" then return false end
    if not C.ConsoleUtils() then return false end
    C.RestoreMultiHit()
    return true
end

-- Friendly Fire (Gast, 1 Hz): geschuetzte fremde Spielerfiguren ignorieren die eigenen Trace-Kanaele (ECC 14..31),
-- alle 10 s erneuert. Geschuetzt: pvp=0 alle, pvp=1/clan_ff=0 nur Clan-Kameraden (PlayerState.PlayerId), sonst keine.
-- Faellt der Schutz weg (Clan verlassen, Modus geaendert), bekommt die Figur ihre gemerkten Antworten zurueck.
-- C.FF[FName] = { T = letzte Anwendung, Orig = { [1] = Mesh {[Kanal] = Antwort}, [2] = Kapsel {...} } }
function C.FFComps(Pawn)
    return { A.Safe(function() return Pawn.Mesh end, nil), A.Safe(function() return Pawn.CapsuleComponent end, nil) }
end

function C.FFIgnore(Pawn, E)
    local Comps = C.FFComps(Pawn)
    for I = 1, 2 do
        local Comp = Comps[I]
        if Comp and A.IsAlive(Comp) then
            if not E.Orig[I] then
                local O = {}
                for Ch = 14, 31 do
                    O[Ch] = tonumber(A.Safe(function() return Comp:GetCollisionResponseToChannel(Ch) end, nil))
                end
                E.Orig[I] = O
            end
            for Ch = 14, 31 do pcall(function() Comp:SetCollisionResponseToChannel(Ch, 0) end) end
        end
    end
end

function C.FFRestore(Pawn, E)
    local Comps = C.FFComps(Pawn)
    for I = 1, 2 do
        local Comp, O = Comps[I], E.Orig[I]
        if O and Comp and A.IsAlive(Comp) then
            for Ch = 14, 31 do
                local R = O[Ch] or 2   -- unbekannt: ECR_Block (Spielerfiguren blocken Waffen-Traces)
                pcall(function() Comp:SetCollisionResponseToChannel(Ch, R) end)
            end
        end
    end
end

-- Soll diese fremde Figur fuer eigene Traces unsichtbar sein?
function C.FFProtected(Pawn, Mode)
    if Mode == "off" then return true end
    if Mode ~= "clan" then return false end
    local Clan = A.Coop and A.Coop.Clan
    if not (Clan and type(Clan.IsMatePid) == "function") then return false end
    local PS = A.Safe(function() return Pawn.PlayerState end, nil)
    local Id = PS and A.IsAlive(PS) and A.Safe(function() return PS.PlayerId end, nil)
    if type(Id) ~= "number" then return false end
    return A.Safe(function() return Clan.IsMatePid(Id) end, false) == true
end

function C.FriendlyFireOff(Now)
    local Mode = U.ClientPvpMode()
    if Mode ~= C.FFMode then
        if C.FFMode then Log("PvP-Modus vom Host: %s", Mode) end
        C.FFMode = Mode
    end
    local Own = A.Safe(A.OwnPawn, nil)
    local OwnAddr = Own and A.IsAlive(Own) and Own:GetAddress()
    local Seen = {}
    for _, Pawn in ipairs(A.PlayerPawns() or {}) do
        if A.IsAlive(Pawn) and Pawn:GetAddress() ~= OwnAddr then
            local Name = U.Name(Pawn)
            Seen[Name] = true
            local E = C.FF[Name]
            if C.FFProtected(Pawn, Mode) then
                if not E or Now - E.T > 10 then
                    if not E then
                        E = { Orig = {} }
                        C.FF[Name] = E
                        Log("Friendly Fire: %s geschuetzt (%s)", Name, Mode)
                    end
                    E.T = Now
                    C.FFIgnore(Pawn, E)
                end
            elseif E then
                C.FFRestore(Pawn, E)
                C.FF[Name] = nil
                Log("Friendly Fire: %s wieder treffbar (%s)", Name, Mode)
            end
        end
    end
    for Name in pairs(C.FF) do
        if not Seen[Name] then C.FF[Name] = nil end
    end
end

-- Fehlende Aufsaetze (Rep > Installed): 2 s -> OnRep_RepAttachments, 2 s -> ProcessAttachments, hoechstens 2 Versuche
function C.FixAttach(W, Now, Tab)
    local AF = A.Coop.AttachFix
    if not (AF and AF.Count) then return end
    local J = U.Comp(W, "BP_JigPickupComponent", "BP_JigPickupComponent_C")
    if not J then return end
    local Rep, Inst = AF.Count(J)
    local Name = U.Name(W)
    if not (Rep and Inst) or Rep <= Inst then Tab[Name] = nil return end
    local E = Tab[Name]
    if not E then Tab[Name] = { T = Now, Step = 0, Tries = 0 } return end
    if E.Tries >= 2 or Now - E.T < 2 then return end
    if E.Step == 0 then
        pcall(function() J:OnRep_RepAttachments() end)
        E.Step, E.T = 1, Now
    elseif E.Step == 1 then
        pcall(function() J:ProcessAttachments() end)
        E.Step, E.T, E.Tries = 0, Now + 10, E.Tries + 1
        Log("Aufsaetze %s: %d/%d eingebaut -> ProcessAttachments", Name, Inst, Rep)
    end
end

function C.RemoteAttach(Now)
    local Own = A.Safe(A.OwnPawn, nil)
    local OwnAddr = Own and A.IsAlive(Own) and Own:GetAddress()
    for _, Pawn in ipairs(A.PlayerPawns() or {}) do
        if A.IsAlive(Pawn) and Pawn:GetAddress() ~= OwnAddr then
            local W = U.HandFirearm(Pawn)
            if W then C.FixAttach(W, Now, C.Att) end
        end
    end
end

-- COMBAT-8 (combat_hold_fix, 2 Hz): HoldingFirearm?-Wettlauf beim Ziehen. Decode L_10a8f @10aed: am Montage-Ende
-- vergleicht das Spiel ToSlot mit dem replizierten ActiveWeapon-Slot; kommt die Replikation spaeter (Ping), laeuft der
-- Else-Zweig @10b16 und die Waffe gilt als weggesteckt (kein ADS, Armbrust/Werfer schiessen nicht, @13a0b). Aktive Waffe
-- = Schusswaffe, HoldingFirearm? aus, kein Waffenwechsel, >= 1 s stabil -> die Zuweisungen von @10afb/@10b06 nachholen,
-- dazu UpdateAmmoCount/Svr_UpdateWeaponSpeed wie L_11e8. Setzt das Spiel es binnen 10 s wieder zurueck: 60 s Ruhe.
function C.HoldFix(Pawn, Now)
    if Now < (C.HoldQuietUntil or 0) then return end
    local W = U.ActiveWeapon(Pawn)
    local Bad = W ~= nil and A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false)
    if Bad then
        Bad = A.Safe(function()
            return Pawn["HoldingFirearm?"] == false and Pawn["CurrentlyChangingWeapon?"] == false
                and Pawn["PlayerDead?"] ~= true and Pawn["InVehicle?"] ~= true and Pawn["Is Climbing?"] ~= true
                and Pawn["ClimbingLadder?"] ~= true
        end, false)
    end
    local Path = Bad and U.Path(W) or nil
    if not Path then C.HoldBad = nil return end
    if not (C.HoldBad and C.HoldBad.P == Path) then C.HoldBad = { P = Path, T = Now } return end
    if Now - C.HoldBad.T < 1 then return end
    C.HoldBad = nil
    if C.HoldLast and C.HoldLast.P == Path and Now - C.HoldLast.T < 10 then
        C.HoldQuietUntil = Now + 60
        Log("Waffe halten: Spiel setzt HoldingFirearm? fuer %s wieder zurueck - 60 s Pause", tostring(Path:match("[^%.:]+$")))
        return
    end
    C.HoldLast = { P = Path, T = Now }
    Pawn["HoldingFirearm?"] = true
    pcall(function() Pawn["HoldingMelee?"] = false end)
    pcall(function() Pawn:UpdateAmmoCount() end)
    pcall(function() Pawn:Svr_UpdateWeaponSpeed() end)
    C.HoldFixN = (C.HoldFixN or 0) + 1
    if C.HoldFixN <= 5 or C.HoldFixN % 50 == 0 then
        Log("Waffe halten: HoldingFirearm? nachgezogen fuer %s (%d. Mal, Replikation kam nach dem Ziehen)",
            tostring(Path:match("[^%.:]+$")), C.HoldFixN)
    end
end

-- Gast: Client_HitUI/MC_SpawnTrail kommen als RPC (ProcessEvent) an -> fuer N4b unsichtbar; fremde Einschlaege laufen
-- ueber cb_imp. Hitmarker: mit Server-Hitmarkern (COMBAT-10, Faehigkeit cb_hit2 + ls_ui ui_hit) zeigt ls_ui die echten
-- Treffer des Hosts (C.NativeHitUI = true), sonst schaetzt der eigene Schuss-Poll.
function C.Fast(Now)
    C.NativeHitUI = (Net.Has("cb_hit2") and Net.Has("ui_hit")) or nil
    if U.On("combat_impacts") or U.On("combat_hitmarker") then
        local ok, err = pcall(C.OwnShot, Now)
        if not ok and Core.Fail("combat_impacts", err) then Log("Eigene Schuesse aus: %s", tostring(err)) end
    end
    if U.On("combat_proj") then C.ProcessQueue(Now) end
    C.Tick5 = ((C.Tick5 or 0) + 1) % 2
    if U.On("combat_boom") and C.Tick5 == 0 then pcall(C.CheckExpl, Now) end
    -- Runde 9 (5 Hz): DLL-Ereignisse fuer Schuss-Kette (COMBAT-2) und Objektschaden (COMBAT-5)
    if C.Tick5 == 1 and not Core.Down.combat_c_ev then
        local ok, err = pcall(C.EvTick, Now)
        if not ok then Core.Fail("combat_c_ev", err) end
    end
    -- COMBAT-7 (5 Hz, nur mit verfolgtem Pfeil): eigene Armbrust-Bolzen an den Host (C.BoltOn auch fuer den Hook-Koerper)
    C.BoltOn = U.On("combat_bolt") and Net.Has("cbbolt")
    if C.BoltOn and C.Tick5 == 0 and (#C.BoltQ > 0 or #C.Arrows > 0) then
        local ok, err = pcall(C.BoltTick, Now)
        if not ok and Core.Fail("combat_bolt", err) then Log("Armbrust-Bolzen aus: %s", tostring(err)) end
    elseif not C.BoltOn and (#C.BoltQ > 0 or #C.Arrows > 0) then
        C.BoltQ, C.Arrows = {}, {}
    end
    -- COMBAT-13: Kill-Feed-Zeilen anzeigen, hoechstens eine je 0,5 s
    if #C.KfQ > 0 and Now >= (C.KfAt or 0) then
        C.KfAt = Now + 0.5
        pcall(A.ShowNote, table.remove(C.KfQ, 1))
    end
    -- 2 Hz: Waffen-Slot-Waechter (COMBAT-1), Haltbarkeits-Sperre (COMBAT-4), HoldingFirearm?-Reparatur (COMBAT-8)
    if Now >= (C.GuardAt or 0) then
        C.GuardAt = Now + 0.5
        local Pawn = A.Safe(A.OwnPawn, nil)
        if Pawn and A.IsAlive(Pawn) then
            if U.On("combat_fire_slotfix") then
                local ok, err = pcall(C.FireSlotGuard, Pawn, Now)
                if not ok and Core.Fail("combat_fire_slotfix", err) then Log("Schuss-Sperre-Reparatur aus: %s", tostring(err)) end
            end
            if U.On("combat_hold_fix") then
                local ok, err = pcall(C.HoldFix, Pawn, Now)
                if not ok and Core.Fail("combat_hold_fix", err) then Log("Waffe-halten-Reparatur aus: %s", tostring(err)) end
            end
            if U.On("combat_dur_v2") then
                local ok, err = pcall(C.DurGate, Pawn, Now)
                if not ok and Core.Fail("combat_dur_v2", err) then Log("Haltbarkeit v2 aus: %s", tostring(err)) end
            end
        end
    end
end

-- ===================================================================== Nahkampf-Relay (UE 5.6, beide Seiten)
-- Decode analysis56: MeleeTrace @00be prueft je Timer-Tick nur Socket Start -> End der AKTUELLEN Pose (kein Sweep vom
-- Vorframe) und ruft @023f Event_OnHitNormal je Treffer (Power: MeleeTracePower/Event_OnHitPower, ohne Zahl-Grenze).
-- Der Host tastet den Gast-Schlag nur im Server-Takt ab -> die Klinge springt zwischen zwei Abtastungen durch Ziele.
--   Gast  DLL-Beobachter (at=call, suppress) ueberspringt HitBody/HitHead/HitObjectWorld/HitFoliageTree/HitFoliageRock
--         aller Nahkampfwaffen (eigene + Zuschauer-Kopien, normal + Power) und zeichnet die Argumente auf. Eigene Treffer
--         gehen gebuendelt als cb_mrel an den Host. Nur bei bestaetigter Unterdrueckung steht die eigene Waffe auf
--         MaxActorsToHitInSwing?=U.MREL.GATE (HitActors bleibt leer, das Tor in Event_OnHitNormal geht jeden Frame auf).
--   Host  prueft Reichweite, Ziel, Limits (wie HitActors/MaxMeleeHits), PvP/Clan und Doppel (Ledger + HitActors) und
--         ruft dieselbe Hit*-Funktion auf seiner Kopie der Gastwaffe (Owner = Gastfigur -> Schaden, XP, Kill-Credit,
--         Client_HitUI, Haltbarkeit). Baum-/Stein-Ertrag faellt beim dedizierten Host vor die Fuesse des Gasts
--         (JigTryAddItemSomewhere ohne LocalJSIContainers) -> combat_mrelay_yield holt ihn ins Gastinventar.
C.MRelOwnW, C.MRelOrig, C.MSeen, C.MRelOut = C.MRelOwnW or {}, C.MRelOrig or {}, C.MSeen or {}, C.MRelOut or {}
C.MRelStat = { sent = 0, drop = 0 }
H.MRelQ, H.MRelSw, H.MRelProven = H.MRelQ or {}, {}, {}
H.MNat, H.MRelFelled, H.MRelLastT = H.MNat or {}, H.MRelFelled or {}, H.MRelLastT or {}
H.MRelCache, H.MRelTreeHP = H.MRelCache or {}, H.MRelTreeHP or {}
-- MRelHA: [Waffe|Ziel] = Zeit, Relay hat das Ziel in HitActors der Host-Kopie gelegt (combat_mrelay_hafix)
-- MRelKnown: Klassen, fuer die FindAllOf erlaubt ist (combat_mrelay_strict); MNote: Host-Notify je Gastfigur
-- MRelRetry: Treffer, die auf die Host-Notify warten; MRelCompK: Foliage-Komponente -> Art (T/R) bzw. false
H.MRelHA, H.MNote, H.MRelRetry, H.MRelCompK = H.MRelHA or {}, H.MNote or {}, {}, H.MRelCompK or {}
H.MRelPawns = {}       -- [Adresse der Gastfigur] = true (0,5 s, fuer den Notify-Hook-Koerper)
H.MRelKnown, H.MRelKnownN = {}, 0
for _, Cls in ipairs(U.MREL_WORLD) do H.MRelKnown[Cls] = true end
for _, Cls in pairs(U.MREL_HARV) do H.MRelKnown[Cls] = true end
H.MRelStat = { ok = 0, dup = 0, reach = 0, miss = 0, dead = 0, pvp = 0, limit = 0, rate = 0, nowpn = 0, err = 0,
               los = 0, note = 0, dur = 0 }

-- Objektpfad, wie er in cb_mrel stehen darf ("" = unbekannt/zu lang)
function U.MRelPathOk(P)
    return P == "" or (type(P) == "string" and #P <= 260 and P:match("^/[%w_/%.:%-]+$") ~= nil)
end

-- DLL-Argument "<Klasse> <Pfad>" -> Klassen-Kurzname, Pfad (false, "0x.." = tot, sonst -> nil)
function U.MRelObj(V)
    if type(V) ~= "string" then return nil, nil end
    local Cls, Path = V:match("^(%S+) (.+)$")
    if not Path then return nil, nil end
    return Cls:match("([^%./:]+)$") or Cls, Path
end

-- DLL-Vektor {X,Y,Z} -> neue Tabelle (nil bei NaN/unsinnigen Werten)
function U.MRelVec(V)
    if type(V) ~= "table" then return nil end
    local X, Y, Z = tonumber(V.X), tonumber(V.Y), tonumber(V.Z)
    if not (X and Y and Z) or X ~= X or Y ~= Y or Z ~= Z then return nil end
    if math.abs(X) > 5e7 or math.abs(Y) > 5e7 or math.abs(Z) > 5e7 then return nil end
    return { X = X, Y = Y, Z = Z }
end

-- Kurzer Zustand fuer cb_status
function U.MRelState()
    if not U.On("combat_mrelay") then return "aus" end
    if Net.Side == "client" then
        return string.format("%s/%s%s", C.MRelReady and "bereit" or "nicht bereit", C.MRelGateOpen and "offen" or "zu",
            C.MRelBroken and "/defekt" or "")
    elseif Net.Side == "host" then
        local N = 0
        for _ in pairs(H.MRelProven) do N = N + 1 end
        return string.format("Host, %d Gast/Gaeste aktiv, Sperre %s", N, tostring(H.MRelExcl == true))
    end
    return "-"
end

-- ---------------------------------------------------------------- Gast

-- Watch-Liste (Listenform, Besitzer "ls_combat_mrel"): je Hit*-Funktion ein Tag, an der Aufrufstelle unterdrueckt.
-- Baum/Stein haben einen Out-Parameter (Hit?) -> Force.
function C.MRelList()
    local List = {}
    for Tag, K in pairs(U.MREL_TAG) do
        List[#List + 1] = { Func = U.OWN_HIT_CLS .. ":" .. U.MREL_FN[K], Tag = Tag, Mode = "suppress", At = "call",
                            Force = (K == "T" or K == "R") }
    end
    return List
end

-- Steht fuer Tag eine Zeile "<tag>\t<hex>\tcall\tsuppress" in netcore_watchinfo.txt?
function C.MRelInfoHas(Text, Tag)
    for Line in Text:gmatch("[^\n]+") do
        if Line:match("^" .. Tag .. "\t%x+\tcall\tsuppress") then return true end
    end
    return false
end

function C.MRelSetReady(Ready, Why)
    if Ready == (C.MRelReady == true) and (Ready or Why == C.MRelWhy) then return end
    C.MRelReady, C.MRelWhy = Ready, Why
    if Ready then
        Log("Nahkampf-Relay bereit: lokale Nahkampftreffer unterdrueckt, Treffer gehen an den Host")
    else
        Log("Nahkampf-Relay nicht bereit: %s", tostring(Why))
    end
end

-- 1 Hz: Beobachter setzen/abmelden und Installation pruefen (bereit erst nach >= 3 s ununterbrochen bestaetigt)
function C.MRelWatch(Now)
    if Net.Side ~= "client" or not U.On("combat_mrelay") then
        if C.MRelWatchOn then pcall(Native.SetWatch, nil, "ls_combat_mrel") end
        C.MRelWatchOn, C.MRelReady, C.MRelOkSince = false, false, nil
        return
    end
    if not U.NativeOn() then
        C.MRelReady, C.MRelOkSince = false, nil
        if not C.MRelNoDllLogged then
            C.MRelNoDllLogged = true
            Log("Nahkampf-Relay: DLL-Beobachter nicht verfuegbar - Host trifft selbst (alter Weg)")
        end
        return
    end
    if (not C.MRelWatchOn or (not C.MRelReady and Now - (C.MRelWatchAt or -99) > 10)) and U.Find(U.OWN_HIT_CLS) then
        C.MRelWatchAt = Now
        local ok, err = pcall(Native.Watch, C.MRelList(), "ls_combat_mrel")
        if ok then
            C.MRelWatchOn, C.MRelPrimed = true, false
        elseif not C.MRelWatchErr then
            C.MRelWatchErr = true
            Log("Nahkampf-Relay: Beobachter nicht gesetzt: %s", tostring(err))
        end
    end
    if not C.MRelWatchOn or Now < (C.MRelInfoAt or 0) then return end
    C.MRelInfoAt = Now + 2
    local Text = Core.ReadAll(Native.Path("watchinfo", ".txt"))
    local Miss = nil
    if not Text then
        Miss = "netcore_watchinfo.txt fehlt"
    else
        for Tag, K in pairs(U.MREL_TAG) do
            if not C.MRelInfoHas(Text, Tag) then Miss = U.MREL_FN[K] .. " nicht unterdrueckt (" .. Tag .. ")" break end
        end
    end
    if C.MRelBroken then Miss = "DLL hat einen Treffer nicht unterdrueckt" end
    -- watchinfo kann nach Abschalten des Beobachters (native_observer=0, Ausnahmen) stehen bleiben: Status pruefen
    if not Miss then
        local NS = Native.Status() or {}
        local Avail = type(Native.Available) == "function" and A.Safe(Native.Available, false) == true
        if not Avail or tonumber(NS.broken) == 1 or tonumber(NS.installed) ~= 1 then
            Miss = "DLL-Beobachter aus oder defekt (Status capable/installed/broken)"
        end
    end
    if Miss then
        C.MRelOkSince = nil
        C.MRelSetReady(false, Miss)
        return
    end
    C.MRelOkSince = C.MRelOkSince or Now
    if Now - C.MRelOkSince >= 3 then C.MRelSetReady(true) end
end

-- 1 Hz (und bei unbekannter Waffe): eigene Figur (Adresse) und eigene Nahkampfwaffen (Pfad -> Klasse)
function C.MRelOwn()
    C.MRelOwnAt = os.clock()
    local Own = {}
    local Pawn = A.Safe(A.OwnPawn, nil)
    if Pawn and A.IsAlive(Pawn) then
        C.MOwnPawnAddr = Pawn:GetAddress()
        for _, W in ipairs(U.Attached(Pawn)) do
            if A.Safe(function() return U.IsA(W, "BP_MeleePickup_C") end, false) then
                local Path = U.Path(W)
                if Path then Own[Path] = { Cls = U.Name(W:GetClass()) } end
            end
        end
    else
        C.MOwnPawnAddr = nil
    end
    C.MRelOwnW = Own
end

-- Tor der eigenen Waffe: offen = U.MREL.GATE (Event_OnHitNormal erreicht Hit* jeden Frame, die DLL unterdrueckt);
-- zu = alter Schutz 0 (combat_melee_guard) bzw. der vor dem Oeffnen gemerkte Wert
function C.MRelGate()
    local Open = (C.MRelReady == true and not C.MRelBroken and U.On("combat_mrelay") and Net.Has("cb_mrel")) and true or false
    local Guard = U.On("combat_melee_guard")
    local Pawn = A.Safe(A.OwnPawn, nil)
    if Pawn and A.IsAlive(Pawn) then
        for _, W in ipairs(U.Attached(Pawn)) do
            if A.Safe(function() return U.IsA(W, "BP_MeleePickup_C") end, false) then
                local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
                local Path = U.Path(W)
                if WC and Path then
                    local Cur = A.Safe(function() return WC["MaxActorsToHitInSwing?"] end, nil)
                    local Want = nil
                    if Open then
                        if C.MRelOrig[Path] == nil and Cur ~= nil and Cur ~= U.MREL.GATE then C.MRelOrig[Path] = Cur end
                        Want = U.MREL.GATE
                    else
                        if Guard then Want = 0 else Want = C.MRelOrig[Path] end
                        C.MRelOrig[Path] = nil
                    end
                    if Want ~= nil and Cur ~= Want then pcall(function() WC["MaxActorsToHitInSwing?"] = Want end) end
                end
            end
        end
    end
    if Open ~= (C.MRelGateOpen == true) then
        Log(Open and "Nahkampf-Relay: eigene Nahkampftreffer laufen jetzt ueber den Host"
            or "Nahkampf-Relay: eigene Nahkampftreffer wieder aus (lokal gesperrt, Host trifft selbst)")
    end
    C.MRelGateOpen = Open
end

-- Einmal: Pre-Hook AnimNotify_MeleeHitDetect_C:Received_NotifyBegin (einmal je Schlag) -> Power-Schlag? fuer Baum/Stein
-- Runde 9: auch fuer combat_raidswing (BUILD-3: ein Signal je eigenem Schlag, auch ohne Hit*-Treffer an Waenden).
-- CORE-18: Koerper prueft zuerst C.MNoteOn (je 0,1 s gesetzt) und ruft keine UFunction (GetOuter statt GetOwner).
function C.MRelHookNotify()
    if C.MRelNotifyTried or not (U.On("combat_mrelay_power") or U.On("combat_raidswing")) or not U.Find(U.MREL_NOTIFY) then
        return
    end
    C.MRelNotifyTried = true
    local Hook = A.TryHook(U.MREL_NOTIFY .. ":Received_NotifyBegin", function(Ctx, MeshComp)
        if not C.MNoteOn then return end
        local ok, e = pcall(C.MRelOnNotify, Ctx, MeshComp)
        if not ok then Core.Fail("combat_mrelay_power", e) end
    end)
    C.MRelNotifyOk = Hook ~= nil
    Log("Nahkampf-Relay: Schlag-Hook (Power-Erkennung) %s", Hook and "aktiv"
        or "fehlgeschlagen - Baum/Stein-Treffer zaehlen als normale Schlaege")
end

-- Hook-Koerper: nur aufzeichnen (eigene Figur, PowerAttack? der Notify)
function C.MRelOnNotify(Ctx, MeshComp)
    if Net.Side ~= "client" or not C.MOwnPawnAddr then return end
    local M0 = MeshComp:get()
    if not (M0 and A.IsAlive(M0)) then return end
    local O = M0:GetOuter()
    if not (O and A.IsAlive(O)) or O:GetAddress() ~= C.MOwnPawnAddr then return end
    local N = Ctx:get()
    if not (N and A.IsAlive(N)) then return end
    C.MPow = N["PowerAttack?"] == true
    C.MPowAt = os.clock()
    C.MNoteN = (C.MNoteN or 0) + 1      -- BUILD-3: Schlag-Zaehler (C.MRelTick ruft A.Coop.Build.OnSwing)
end

-- Neuer Schlag, wenn > GAP_MS seit dem letzten eigenen Treffer-Ereignis (DLL-Zeit GetTickCount64)
function C.MRelSwing(Ms)
    local Last = C.MLastMs
    if Last and Ms - Last <= U.MREL.GAP_MS and Ms >= Last - 1000 then return end
    C.MSw = (C.MSw or 0) % 2000000000 + 1
    C.MSwMs, C.MSeen, C.MN, C.MNote = Ms, {}, 0, nil
    C.MSwPow = (U.On("combat_mrelay_power") and C.MPow == true and os.clock() - (C.MPowAt or -9) < 1.2) and true or false
    -- BUILD-3 Rueckfall ohne Schlag-Hook: Schlag erst hier bekannt (nur bei Hit*-Treffern, Waende loesen keine aus)
    if not C.MRelNotifyOk then C.RaidSwing(C.MSwPow) end
end

-- BUILD-3 (combat_raidswing, E13): eigener Schlag -> ls_build prueft Bauteile vor der Figur (Raid-Nahkampf, b_rmel).
-- Normal einmal je Schlag aus C.MRelTick (Schlag-Hook-Zaehler C.MNoteN): Wand-Treffer rufen keine Hit*-Funktion
-- (BP_MeleePickup Event_OnHitNormal @0a43-@0b7f), C.MRelSwing allein saehe sie nie.
function C.RaidSwing(Power)
    if not U.On("combat_raidswing") then return end
    local B = A.Coop and A.Coop.Build
    if type(B) == "table" and type(B.OnSwing) == "function" then
        local ok, err = pcall(B.OnSwing, Power == true)
        if not ok and Core.Fail("combat_raidswing", err) then Log("Raid-Schlag aus: %s", tostring(err)) end
    end
end

-- Ereignis -> Treffer-Text (16 Felder, ";") oder nil (doppelt, Grenze, kein Schaden moeglich, unlesbar)
function C.MRelBuild(K, Ev, Own, WPath)
    local Args = Ev.Args or {}
    local I, T, TC, TP, P = nil, nil, nil, nil, false
    local PID, MESH, IDX = -1, "", -1
    if K == "B" or K == "H" then
        TC, TP = U.MRelObj(Args[1])
        I = U.MRelVec(Args[2])
        if not (TP and I) then return nil end
        P = Args[3] == true
        local O = U.Find(TP)
        T = O and A.Safe(function() return U.Loc(O) end, nil) or I
        if O and A.Safe(function() return U.IsA(O, "BP_PlayerCharacter_C") end, false) then
            local PS = A.Safe(function() return O.PlayerState end, nil)
            local Id = PS and A.IsAlive(PS) and tonumber(A.Safe(function() return PS.PlayerId end, nil))
            if Id then PID = math.floor(Id) end
        end
    elseif K == "W" then
        TC, TP = U.MRelObj(Args[1])
        if not TP then return nil end
        P = Args[2] == true
        local O = U.Find(TP)
        T = O and A.Safe(function() return U.Loc(O) end, nil)
        if not T then return nil end
        I = T
    else
        local ACls, APath = U.MRelObj(Args[1])
        local CCls, CPath = U.MRelObj(Args[3])
        local Idx = tonumber(Args[4])
        I = U.MRelVec(Args[2])
        if not I then return nil end
        P = C.MSwPow == true
        -- Spiel: CanDamageTree?/CanDamageRock? falsch -> nur Hinweis, kein Schaden (HitFoliageTree @0000/@039c)
        local Flag = K == "T" and "CanDamageTree?" or "CanDamageRock?"
        local Wp = U.Find(WPath)
        local WC = Wp and U.Comp(Wp, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
        if WC and A.Safe(function() return WC[Flag] end, true) == false then
            if not C.MNote then
                C.MNote = true
                pcall(A.ShowNote, K == "T" and "No damage to tree dealt." or "No damage to rock dealt.")
            end
            return nil
        end
        if CPath and CCls:find("InstancedStaticMeshComponent", 1, true) and Idx and Idx >= 0 then
            TC, TP, IDX = "ISM", CPath, math.floor(Idx)
            local Cm = U.Find(CPath)
            if Cm then
                local SM = A.Safe(function() return Cm.StaticMesh end, nil)
                MESH = SM and A.IsAlive(SM) and U.Path(SM) or ""
                local Out = {}
                local okT, Got = pcall(function() return Cm:GetInstanceTransform(IDX, Out, false) end)
                local Tr = okT and Got ~= false and Out.Translation or nil
                T = Tr and U.MRelVec({ X = Tr.X, Y = Tr.Y, Z = Tr.Z }) or nil
            end
            T = T or I
            if not (MESH:find("^/Game/") and U.MRelPathOk(MESH)) then MESH = "" end
        else
            if not APath then return nil end
            TC, TP = ACls, APath
            local O = U.Find(APath)
            T = O and A.Safe(function() return U.Loc(O) end, nil) or I
        end
    end
    if not (TC and #TC <= 96 and TC:match("^[%w_]+$")) then return nil end
    -- Schlag-Grenzen wie im Einzelspieler: Ziel einmal je Schlag (Erntekoerper bis combat_mrelay_harv), hoechstens LOCAL_MAX
    local Key
    if K == "B" or K == "H" or K == "W" then Key = "a|" .. TP
    elseif TC == "ISM" then Key = "i|" .. TP .. "|" .. IDX
    else Key = "h|" .. TP end
    local Seen = C.MSeen[Key]
    if Key:sub(1, 1) == "h" then
        if (Seen or 0) >= Core.Flag("combat_mrelay_harv", 2) then return nil end
    elseif Seen then
        return nil
    end
    if not Seen then
        if (C.MN or 0) >= U.MREL.LOCAL_MAX then return nil end
        C.MN = (C.MN or 0) + 1
    end
    C.MSeen[Key] = (Seen or 0) + 1
    -- Sofortige Rueckmeldung (optimistisch; Schaden/Zahlen kommen vom Host)
    if not Seen and U.On("combat_mrelay_fx") then
        if K == "B" or K == "H" then
            C.Hitmarker(K == "H")
            local Pawn = A.Safe(A.OwnPawn, nil)
            local From = Pawn and A.IsAlive(Pawn) and A.Safe(function() return U.Loc(Pawn) end, nil) or T
            pcall(C.ShowImpact, I, K == "H" and "h" or "b", From)
        else
            C.Hitmarker(false)
        end
    end
    local Dt = math.max(0, math.min(9999, math.floor((Ev.Ms or 0) - (C.MSwMs or Ev.Ms or 0))))
    local WireTP = U.MRelPathOk(TP) and TP or ""
    return table.concat({ tostring(C.MSw), tostring(Dt), K, P and "1" or "0", Net.Enc(Own.Cls), U.Fmt(I), U.Fmt(T),
        Net.Enc(TC), Net.Enc(WireTP), tostring(PID), Net.Enc(MESH), tostring(IDX) }, ";")
end

-- Gesammelte Treffer senden: je Nachricht bis PER_MSG, hoechstens 2 Nachrichten je Tick und unter der Host-Rate
function C.MRelFlush()
    local Out, Stat = C.MRelOut, C.MRelStat
    local Sends = 0
    while #Out > 0 and Sends < 2 do
        if not Net.Has("cb_mrel") then
            Stat.drop = Stat.drop + #Out
            C.MRelOut = {}
            return
        end
        if not U.Rate("mrel_tx", U.MREL.MSG_RATE - 2) then return end
        local Chunk = {}
        while #Chunk < U.MREL.PER_MSG and #Out > 0 do Chunk[#Chunk + 1] = table.remove(Out, 1) end
        if Net.Send("cb_mrel", "1|" .. table.concat(Chunk, "|"), nil, 0) then
            Stat.sent = Stat.sent + #Chunk
        else
            Stat.drop = Stat.drop + #Chunk
        end
        Sends = Sends + 1
    end
end

-- 0,1 s: Ereignisse der DLL lesen (eigener Cursor), eigene Treffer bauen, senden. Tor zu: nur leeren.
function C.MRelEvents(Now)
    if not (C.MRelWatchOn and U.NativeOn()) then return end
    local ok, List = pcall(Native.Events, "_ls_combat_mrel")
    if not ok or type(List) ~= "table" then return end
    if not C.MRelPrimed then C.MRelPrimed = true return end   -- altes Fenster der DLL verwerfen
    local Refreshed = false
    for _, Ev in ipairs(List) do
        local K = U.MREL_TAG[Ev.Tag]
        local WPath = K and Ev.Remote ~= true and U.EvPath(Ev.Ctx) or nil
        local Own = WPath and C.MRelOwnW[WPath]
        if WPath and not Own and not Refreshed and Now - (C.MRelOwnAt or -9) > 0.3 then
            Refreshed = true
            C.MRelOwn()
            Own = C.MRelOwnW[WPath]
        end
        if Own then
            local Open = C.MRelGateOpen == true
            if Ev.Suppressed == false and not C.MRelBroken then
                C.MRelBroken = true
                Log("Nahkampf-Relay: DLL hat %s nicht unterdrueckt - Relay aus", tostring(U.MREL_FN[K]))
                pcall(C.MRelGate)
            end
            if Open and type(Ev.Ms) == "number" then
                C.MRelSwing(Ev.Ms)
                C.MLastMs = Ev.Ms
                local okB, Hit = pcall(C.MRelBuild, K, Ev, Own, WPath)
                if okB and Hit then
                    if #C.MRelOut >= 24 then
                        table.remove(C.MRelOut, 1)
                        C.MRelStat.drop = C.MRelStat.drop + 1
                    end
                    C.MRelOut[#C.MRelOut + 1] = Hit
                elseif not okB then
                    C.MRelStat.drop = C.MRelStat.drop + 1
                    Core.Fail("combat_mrelay", Hit)
                end
            end
        end
    end
    C.MRelFlush()
end

-- Gast-Tick (0,1 s): 1-Hz-Teil (Waffen, Beobachter, Power-Hook, Tor), dann Ereignisse
function C.MRelTick(Now)
    if Net.Side ~= "client" then C.MNoteOn = false return end
    C.MNoteOn = U.On("combat_mrelay_power") or U.On("combat_raidswing")
    -- BUILD-3: neuer eigener Schlag seit dem letzten Tick (Schlag-Hook) -> ls_build (ausserhalb des Hooks)
    if (C.MNoteN or 0) ~= (C.MNoteSeen or 0) then
        C.MNoteSeen = C.MNoteN
        C.RaidSwing(C.MPow == true)
    end
    if Now >= (C.MRelSlowAt or 0) then
        C.MRelSlowAt = Now + 1
        for _, Name in ipairs({ "MRelOwn", "MRelWatch", "MRelHookNotify", "MRelGate" }) do
            local ok, err = pcall(C[Name], Now)
            if not ok then Core.Fail("combat_mrelay", err) end
        end
    end
    C.MRelEvents(Now)
end

-- Alles aus (combat_v2/combat_mrelay aus, keine Gast-Rolle mehr): Beobachter abmelden, Tor zu
function C.MRelOff()
    if C.MRelWatchOn then pcall(Native.SetWatch, nil, "ls_combat_mrel") end
    C.MRelWatchOn, C.MRelReady, C.MRelOkSince = false, false, nil
    C.MRelGate()
end

-- ---------------------------------------------------------------- Host

-- Gueltigen Treffer-Text (16 Felder) zerlegen, sonst nil
function H.MRelParse(Part)
    local P = U.Split(Part)
    if not (#P == 16 or (#P == 17 and P[17] == "")) then return nil end
    local Sw, Dt, K, Pw = tonumber(P[1]), tonumber(P[2]), P[3], P[4]
    if not (Sw and Sw == math.floor(Sw) and Sw >= 1 and Sw <= 2 ^ 31) then return nil end
    if not (Dt and Dt >= 0 and Dt <= 9999) then return nil end
    if not U.MREL_FN[K] or (Pw ~= "0" and Pw ~= "1") then return nil end
    local WC = Net.Dec(P[5])
    if not (#WC <= 64 and WC:match("^[%w_]+$")) then return nil end
    local I, T = U.Vec(P, 6), U.Vec(P, 9)
    if not (I and T) then return nil end
    local TC = Net.Dec(P[12])
    if not (#TC <= 96 and TC:match("^[%w_]+$")) then return nil end
    if TC == "ISM" and K ~= "T" and K ~= "R" then return nil end
    local TP = Net.Dec(P[13])
    if not U.MRelPathOk(TP) then return nil end
    local PID = tonumber(P[14])
    if not (PID and PID == math.floor(PID) and PID >= -1 and PID < 2 ^ 31) then return nil end
    local MESH = Net.Dec(P[15])
    if MESH ~= "" and not (#MESH <= 260 and MESH:find("^/Game/")) then return nil end
    local IDX = tonumber(P[16])
    if not (IDX and IDX == math.floor(IDX) and IDX >= -1 and IDX <= 1e7) then return nil end
    return { Sw = Sw, Dt = Dt, K = K, P = Pw == "1", WC = WC, I = I, T = T, TC = TC, TP = TP, PID = PID,
             MESH = MESH, IDX = IDX }
end

-- Handler cb_mrel: nur pruefen und einreihen (Arbeit in H.MRelTick)
function H.MRelIn(Data, G)
    if not (G and G.Key and G.Epoch and Net.Has("cb_mrel", G)) then return end
    if not U.Rate("mrel" .. G.Key, U.MREL.MSG_RATE) then
        H.MRelStat.rate = H.MRelStat.rate + 1
        return Net.SecWarn(G, G.Key, "cb_mrel_rate")
    end
    if type(Data) ~= "string" or #Data > 4000 or Data:sub(1, 2) ~= "1|" then return Net.SecWarn(G, G.Key, "cb_mrel") end
    local Items = {}
    for Part in Data:sub(3):gmatch("[^|]+") do
        if #Items >= U.MREL.PER_MSG then return Net.SecWarn(G, G.Key, "cb_mrel") end
        local F = H.MRelParse(Part)
        if not F then return Net.SecWarn(G, G.Key, "cb_mrel") end
        Items[#Items + 1] = F
    end
    if #Items == 0 then return Net.SecWarn(G, G.Key, "cb_mrel") end
    local Now = os.clock()
    for _, F in ipairs(Items) do
        if #H.MRelQ >= U.MREL.Q_MAX then
            H.MRelStat.rate = H.MRelStat.rate + 1
            return Net.SecWarn(G, G.Key, "cb_mrel_rate")
        end
        H.MRelQ[#H.MRelQ + 1] = { Key = G.Key, Epoch = G.Epoch, T = Now, F = F }
    end
end

-- Einmal, sobald die Nahkampf-Klasse geladen ist: Ledger-Hooks (Pre) auf die fuenf Hit*-Funktionen. Feuern nur bei
-- echten Treffern; der Koerper zeichnet nur Waffe|Ziel + Zeit auf.
function H.MRelHook()
    if H.MRelHooked or not U.Find(U.OWN_HIT_CLS) then return end
    H.MRelHooked = true
    local N = 0
    for _, Fn in ipairs({ "HitBody", "HitHead", "HitObjectWorld", "HitFoliageTree", "HitFoliageRock" }) do
        -- CORE-18: Schalter zuerst (H.MRelOnF je 0,1 s aus H.MRelTick), Koerper zeichnet nur auf
        if A.TryHook(U.OWN_HIT_CLS .. ":" .. Fn, function(Ctx, Obj)
            if H.MRelBusy or not H.MRelOnF then return end
            pcall(H.MRelLedger, Ctx, Obj)
        end) ~= nil then
            N = N + 1
        end
    end
    Log("Nahkampf-Relay: %d/5 Treffer-Hooks fuer den Doppel-Abgleich aktiv", N)
end

function H.MRelLedger(Ctx, Obj)
    if Net.Side ~= "host" or H.MRelBusy then return end
    local W, O = Ctx:get(), Obj:get()
    if not (W and O and A.IsAlive(W) and A.IsAlive(O)) then return end
    local Nat = H.MNat
    local Key = tostring(W:GetAddress()) .. "|" .. tostring(O:GetAddress())
    H.MRelHA[Key] = nil      -- Host-eigener Treffer: HitActors-Eintrag gehoert nicht (mehr) dem Relay
    if Nat.N and Nat.N > 2000 then return end
    Nat[Key] = os.clock()
end

-- Host aus (combat_v2/combat_mrelay aus oder keine Host-Rolle mehr): DLL-Sperrliste der Gastwaffen leeren, sonst
-- bleiben Event_OnHitNormal/Power der Gastwaffen gesperrt und weder Relay noch Host-Weg treffen
function H.MRelHostOff()
    H.MRelOnF, H.MRelNoteOn = false, false
    if H.MRelDenyN then
        pcall(Native.SetDeny, {}, "ls_combat_mrel")
        H.MRelDenyN, H.MRelDenyLog = nil, 0
        Log("Nahkampf-Relay: Host-Sperre der Gastwaffen aufgehoben (Relay aus)")
    end
    H.MRelExcl = false
    if next(H.MRelProven) then H.MRelProven = {} end
    if #H.MRelQ > 0 then H.MRelQ = {} end
    if #H.MRelRetry > 0 then H.MRelRetry = {} end
    if #H.MRelYield > 0 then H.MRelYield = {} end
end

-- Einmal (combat_mrelay_notify): Pre-Hook AnimNotify_MeleeHitDetect_C:Received_NotifyBegin auch auf dem Host. Feuert
-- einmal je Schlag (MC_Montage der Gastfigur); der Koerper zeichnet nur Figur-Adresse, Zeit und PowerAttack? auf.
function H.MRelHookNotify()
    if H.MRelNoteTried or not U.On("combat_mrelay_notify") or not U.Find(U.MREL_NOTIFY) then return end
    H.MRelNoteTried = true
    local Hook = A.TryHook(U.MREL_NOTIFY .. ":Received_NotifyBegin", function(Ctx, MeshComp)
        if not H.MRelNoteOn then return end      -- CORE-18: Schalter zuerst (je 0,1 s aus H.MRelTick)
        local ok, e = pcall(H.MRelOnNotify, Ctx, MeshComp)
        if not ok then Core.Fail("combat_mrelay_notify", e) end
    end)
    H.MRelNoteOk = Hook ~= nil
    Log("Nahkampf-Relay: Host-Schlag-Hook (Schlag-/Power-Nachweis) %s", Hook and "aktiv"
        or "fehlgeschlagen - Relay-Schlaege ohne Nachweis (alter Weg)")
end

function H.MRelOnNotify(Ctx, MeshComp)
    if Net.Side ~= "host" then return end
    local M0 = MeshComp:get()
    if not (M0 and A.IsAlive(M0)) then return end
    -- CORE-18: GetOuter (UE4SS, keine UFunction) statt GetOwner; nur Gastfiguren (H.MRelPawns, 0,5 s aus H.MRelTick)
    local O = M0:GetOuter()
    if not (O and A.IsAlive(O)) then return end
    local Key = O:GetAddress()
    if not H.MRelPawns[Key] then return end
    local N = Ctx:get()
    local P = (N and A.IsAlive(N) and N["PowerAttack?"] == true) and true or false
    local L = H.MNote[Key] or {}
    if #L >= 4 then table.remove(L, 1) end
    L[#L + 1] = { T = os.clock(), P = P, Uses = 0 }
    H.MNote[Key], H.MRelNoteSeen = L, true
end

-- Unverbrauchte Host-Notify der Gastfigur (hoechstens NOTE_WIN alt). Eine schon genutzte darf noch einen zweiten
-- Schlag tragen (Gast trennt Schlaege nach 250 ms Trefferpause), aber nur bis 1 s nach der Notify.
function H.MRelNoteFind(PawnAddr, Clock)
    local Second = nil
    for _, N in ipairs(H.MNote[PawnAddr] or {}) do
        local Age = Clock - N.T
        if Age >= -0.05 and Age <= U.MREL.NOTE_WIN then
            if N.Uses == 0 then return N end
            if N.Uses == 1 and Age <= 1.0 and not Second then Second = N end
        end
    end
    return Second
end

-- Wuerde dieser Treffer einen neuen Schlag beginnen? (gleiche Bedingungen wie H.MRelSwing)
function H.MRelNewSwing(E, F)
    local SS = H.MRelSw[E.Key]
    if not SS or SS.Epoch ~= E.Epoch then return true end
    return SS.List[F.Sw] == nil and F.Sw > SS.Cur
end

-- Sicht Gastfigur -> Ziel (Kanal Visibility, Figur ignoriert; ausgeruestete Waffen haben keine Kollision,
-- OnPickupEquipped -> JigSetCanInteract). Frei, wenn eine von zwei Linien (Mitte, +50) erst am Ziel blockt.
-- Trace nicht moeglich -> nicht ablehnen.
-- COMBAT-9 (combat_mrelay_los_r): der erste Block liegt auf der eigenen Kapsel/dem Mesh des Ziels, also um dessen Radius
-- vor der Mitte (Baer/Hirsch > 80 uu) -> Toleranz max(80, Radius + 30), Radius hoechstens 400
function H.MRelLosTol(Target)
    if not U.On("combat_mrelay_los_r") then return 80 end
    local ok, R = pcall(function()
        local Cap = Target.CapsuleComponent
        if not (Cap and A.IsAlive(Cap)) then return 0 end
        return tonumber(Cap:GetScaledCapsuleRadius()) or 0
    end)
    if not ok then
        if Core.Fail("combat_mrelay_los_r", R) then Log("Sichtlinie mit Kapselradius aus: %s", tostring(R)) end
        return 80
    end
    return math.max(80, math.min(R, 400) + 30)
end

function H.MRelLos(Pawn, Target)
    local L, T = U.Loc(Pawn), U.Loc(Target)
    local Start = { X = L.X, Y = L.Y, Z = L.Z + 60 }
    local Tol = H.MRelLosTol(Target)
    for _, DZ in ipairs({ 0, 50 }) do
        local End = { X = T.X, Y = T.Y, Z = T.Z + DZ }
        local Hit, Clear = {}, { R = 0, G = 0, B = 0, A = 0 }
        local okT, Blocked = pcall(function()
            return U.KSL():LineTraceSingle(Pawn, Start, End, 0, false, {}, 0, Hit, true, Clear, Clear, 0)
        end)
        if not okT or Blocked ~= true then return true end
        local P = Hit.ImpactPoint
        if not P then return true end
        local PI = { X = tonumber(P.X) or 0, Y = tonumber(P.Y) or 0, Z = tonumber(P.Z) or 0 }
        if U.Dist(Start, PI) >= U.Dist(Start, End) - Tol then return true end
    end
    return false
end

-- Klasse fuer FindAllOf zulassen (combat_mrelay_strict): nur Welt-/Ernte-Klassen und auf dem Host gesehene Klassen
function H.MRelLearn(Cls)
    if type(Cls) ~= "string" or Cls == "" or H.MRelKnown[Cls] or H.MRelKnownN >= U.MREL.KNOWN_MAX then return end
    H.MRelKnown[Cls], H.MRelKnownN = true, H.MRelKnownN + 1
end

-- Foliage-Instanz zur gemeldeten Art passend? Wie MeleeTrace nur Komponenten mit Kollision; PhysMat-Flaeche
-- (16 Baum, 17 Stein) aus BodyInstance-Override, Materialien und BodySetup. Andere Art belegt -> nein; unbekannt -> ja.
function H.MRelCompKind(Cm)
    local Key = U.Path(Cm) or tostring(Cm:GetAddress())
    local E = H.MRelCompK[Key]
    if E == nil then
        E = { Coll = tonumber(A.Safe(function() return Cm:GetCollisionEnabled() end, nil)) }
        local function Add(PM)
            if not (PM and A.IsAlive(PM)) then return end
            local S = tonumber(A.Safe(function() return PM.SurfaceType end, nil))
            if S == 16 then E.T = true elseif S == 17 then E.R = true end
        end
        Add(A.Safe(function() return Cm.BodyInstance.PhysMaterialOverride end, nil))
        for I = 0, 7 do
            local Mat = A.Safe(function() return Cm:GetMaterial(I) end, nil)
            if not (Mat and A.IsAlive(Mat)) then break end
            Add(A.Safe(function() return Mat:GetPhysicalMaterial() end, nil))
        end
        local SM = A.Safe(function() return Cm.StaticMesh end, nil)
        local BS = SM and A.IsAlive(SM) and A.Safe(function() return SM.BodySetup end, nil) or nil
        if BS and A.IsAlive(BS) then Add(A.Safe(function() return BS.PhysMaterial end, nil)) end
        local N = 0
        for _ in pairs(H.MRelCompK) do N = N + 1 end
        if N > 2000 then H.MRelCompK = {} end
        H.MRelCompK[Key] = E
    end
    return E
end

function H.MRelCompOk(Cm, K)
    local E = H.MRelCompKind(Cm)
    if E.Coll == 0 then return false end
    if E[K] then return true end
    local Other = K == "T" and "R" or "T"
    return not E[Other]
end

-- 0,5 s (combat_mrelay_excl): Host-eigene Trefferverarbeitung (Event_OnHitNormal/Power) der Gastwaffen nachgewiesener
-- Relay-Gaeste in der DLL verwerfen. Der Ledger laeuft unabhaengig davon immer.
function H.MRelDeny()
    local Entries, NW = {}, 0
    if U.On("combat_mrelay_excl") then
        Net.ForEachGuest(function(G, Key)
            if not (G.Epoch and Net.Has("cb_mrel", G) and H.MRelProven[Key] == G.Epoch) then return end
            local Pawn = H.PawnPC(G)
            if not Pawn then return end
            for _, W in ipairs(U.Attached(Pawn)) do
                if A.Safe(function() return U.IsA(W, "BP_MeleePickup_C") end, false) then
                    NW = NW + 1
                    Entries[#Entries + 1] = { Func = U.OWN_HIT_CLS .. ":Event_OnHitNormal", Context = W, Tag = "cb_mdeny" }
                    Entries[#Entries + 1] = { Func = U.OWN_HIT_CLS .. ":Event_OnHitPower", Context = W, Tag = "cb_mdeny" }
                end
            end
        end)
    end
    if #Entries == 0 and not H.MRelDenyN then return end   -- leere Liste nur einmal
    local ok = pcall(Native.SetDeny, Entries, "ls_combat_mrel")
    H.MRelDenyN = (#Entries > 0) and NW or nil
    local S = Native.Status() or {}
    local Was = H.MRelExcl == true
    H.MRelExcl = (ok and #Entries > 0 and Native.DenyActive() and (tonumber(S.deny) or 0) >= (Native.DenyCount or 0)) and true or false
    -- Status 2 s gecacht, DLL liest deny.txt alle 200 ms -> erste Pruefung meist "nicht bestaetigt"; Bestaetigung nachloggen
    if NW ~= (H.MRelDenyLog or 0) or (NW > 0 and H.MRelExcl and not Was) then
        H.MRelDenyLog = NW
        Log("Nahkampf-Relay: Host-Treffer von %d Gastwaffe(n) gesperrt (DLL-Sperre %s)", NW,
            H.MRelExcl and "aktiv" or (NW > 0 and "nicht bestaetigt" or "aus"))
    end
end

function H.MRelSpeed(O)
    local V = A.Safe(function() return O:GetVelocity() end, nil)
    if not V then return 0 end
    local X, Y, Z = tonumber(V.X) or 0, tonumber(V.Y) or 0, tonumber(V.Z) or 0
    return math.sqrt(X * X + Y * Y + Z * Z)
end

function H.MRelTol(O)
    return math.min(U.MREL.TLAG_MAX, H.MRelSpeed(O) * U.MREL.LAG_S)
end

function H.MRelClsName(O)
    return A.Safe(function() return U.Name(O:GetClass()) end, "")
end

-- FindAllOf(Cls) als Pfad + Lage in 50 m um Near (1 s Cache; Force: Neuaufbau ab 0,25 s); keine UObjects gespeichert
function H.MRelClsList(Cls, Now, Near, Force)
    local E = H.MRelCache[Cls]
    if E and U.Dist(E.C, Near) < 3000 and Now - E.T < (Force and 0.25 or 1) then return E.L end
    -- Klassenname kommt vom Gast: FindAllOf nur fuer zugelassene Klassen (sonst StaticMeshComponent & Co. -> Haenger)
    if U.On("combat_mrelay_strict") and not H.MRelKnown[Cls] then return {} end
    if not U.Rate("mrelfa", 8) then return E and E.L or {} end
    local okF, List = pcall(FindAllOf, Cls)
    local L = {}
    if okF and type(List) == "table" then
        for _, O in ipairs(List) do
            if A.IsAlive(O) then
                local okL, P = pcall(U.Loc, O)
                if okL and U.Dist(P, Near) <= 5000 then
                    local Path = U.Path(O)
                    if Path then L[#L + 1] = { Path = Path, Pos = P } end
                end
            end
        end
    end
    H.MRelCache[Cls] = { T = Now, C = Near, L = L }
    return L
end

-- Naechstes Objekt der Klasse Cls in R um T (frisch nachgeschlagen); beim Fehlschlag einmal neu aufbauen
function H.MRelPick(Cls, Now, T, R)
    for Pass = 1, 2 do
        local Best, BestD = nil, math.huge
        for _, E in ipairs(H.MRelClsList(Cls, Now, T, Pass == 2)) do
            local D = U.Dist(E.Pos, T)
            if D < BestD then Best, BestD = E, D end
        end
        local O = Best and BestD <= R + 200 and U.Find(Best.Path) or nil
        if O then
            local okL, L = pcall(U.Loc, O)
            if okL and U.Dist(L, T) <= R then return O, L end
        end
    end
    return nil
end

-- Figur-Ziel (B/H): Spieler ueber PlayerId, sonst Pfad (Map-Actor), sonst naechste Figur der Klasse
function H.MRelChar(F, PawnAddr, GhostAddr, Now)
    if F.PID >= 0 then
        for _, P in ipairs(A.PlayerPawns() or {}) do
            if A.IsAlive(P) and P:GetAddress() ~= PawnAddr and P:GetAddress() ~= GhostAddr then
                local PS = A.Safe(function() return P.PlayerState end, nil)
                local Id = PS and A.IsAlive(PS) and tonumber(A.Safe(function() return PS.PlayerId end, nil))
                if Id and math.floor(Id) == F.PID then return P end
            end
        end
        return nil
    end
    local O = F.TP ~= "" and U.Find(F.TP) or nil
    if O and H.MRelClsName(O) == F.TC then
        local okL, L = pcall(U.Loc, O)
        if okL and U.Dist(L, F.T) <= U.MREL.TGT_R + H.MRelTol(O) then return O end
    end
    local Best, BestD = nil, math.huge
    for _, Ch in ipairs(A.Characters() or {}) do
        if A.IsAlive(Ch) and Ch:GetAddress() ~= PawnAddr and Ch:GetAddress() ~= GhostAddr then
            local okL, L = pcall(U.Loc, Ch)
            local D = okL and U.Dist(L, F.T) or math.huge
            if D < BestD and D <= U.MREL.TGT_R + U.MREL.TLAG_MAX then
                local CN = H.MRelClsName(Ch)
                H.MRelLearn(CN)          -- Figur-Klasse (FindAllOf("Character")) -> Rueckfall-Suche erlaubt
                if CN == F.TC and D <= U.MREL.TGT_R + H.MRelTol(Ch) then Best, BestD = Ch, D end
            end
        end
    end
    if Best then return Best end
    if U.Rate("mrelchar", 4) then
        local P = H.MRelPick(F.TC, Now, F.T, U.MREL.TGT_R + U.MREL.TLAG_MAX)
        if P and P:GetAddress() ~= PawnAddr and P:GetAddress() ~= GhostAddr then return P end
    end
    return nil
end

function H.MRelDead(O)
    if A.Safe(function() return O["PlayerDead?"] end, false) == true then return true end
    if H.IsDeadChar(O) then return true end
    local AI = U.Comp(O, "BP_AIComponent", "BP_AIComponent_C")
    return AI ~= nil and A.Safe(function() return AI.Dead end, false) == true
end

-- PvP-Politik fuer Spielerziele: off -> nie, all -> immer, clan -> nicht innerhalb desselben Clans (Index > 0)
function H.MRelPvpOk(G, Target)
    local Mode = U.PvpMode()
    if Mode == "off" then return false end
    if Mode == "all" then return true end
    local Clan = A.Coop and A.Coop.Clan
    if not (Clan and type(Clan.Index) == "function" and type(Clan.GuestIdOf) == "function") then return true end
    local TG = Net.GuestByPawnName(U.Name(Target))
    local IA = tonumber(A.Safe(function() return Clan.Index(Clan.GuestIdOf(G)) end, 0)) or 0
    local IB = tonumber(A.Safe(function() return Clan.Index(Clan.GuestIdOf(TG or Target)) end, 0)) or 0
    return not (IA > 0 and IA == IB)
end

-- B/H/W-Ziel aufloesen und pruefen; Rueckgabe Ziel oder nil, Grund (Statistik-Schluessel)
function H.MRelActorTarget(F, G, PawnAddr, Now)
    local Ghost = A.Coop.Server and A.Safe(A.OwnPawn, nil) or nil
    local GhostAddr = Ghost and A.IsAlive(Ghost) and Ghost:GetAddress() or -1
    local O
    if F.K == "W" then
        O = F.TP ~= "" and U.Find(F.TP) or nil
        if O then
            local okL, L = pcall(U.Loc, O)
            if not (okL and U.Dist(L, F.T) <= U.MREL.TGT_R and H.MRelClsName(O) == F.TC) then O = nil end
        end
        O = O or H.MRelPick(F.TC, Now, F.T, U.MREL.TGT_R)
        if not O then return nil, "miss" end
        local Allowed = false
        for _, Cls in ipairs(U.MREL_WORLD) do
            if A.Safe(function() return U.IsA(O, Cls) end, false) then Allowed = true break end
        end
        if not Allowed then return nil, "miss" end
        H.MRelLearn(H.MRelClsName(O))
        -- Ziel muss am Einschlag liegen (echter Gast meldet I = Ziel-Lage), sonst Welt-Treffer von ueberall
        if U.On("combat_mrelay_strict") then
            local okL, L = pcall(U.Loc, O)
            if not okL or U.Dist(L, F.I) > U.MREL.TGT_R + H.MRelTol(O) + 100 then return nil, "reach" end
        end
    else
        O = H.MRelChar(F, PawnAddr, GhostAddr, Now)
        if not O then return nil, "miss" end
        -- HitBody/HitHead nur auf Figuren (Einzelspieler: Flaechen 7/8/13/14), sonst Staerke-XP an Waenden
        if U.On("combat_mrelay_strict") and not A.Safe(function() return U.IsA(O, "Character") end, false) then
            return nil, "miss"
        end
        local okL, L = pcall(U.Loc, O)
        if not okL or U.Dist(L, F.I) > U.MREL.TGT_R + H.MRelTol(O) + 100 then return nil, "reach" end
    end
    local Addr = O:GetAddress()
    if Addr == PawnAddr or Addr == GhostAddr then return nil, "miss" end
    if H.MRelDead(O) then return nil, "dead" end
    if A.Safe(function() return U.IsA(O, "BP_PlayerCharacter_C") end, false) and not H.MRelPvpOk(G, O) then
        return nil, "pvp"
    end
    return O
end

-- Foliage-Instanz (T/R, TC "ISM"): Gast-Pfad + Index, wenn die Instanz dort steht; sonst ls_world HarvFind (Mesh + Lage)
function H.MRelInst(F)
    local Cm = (F.TP ~= "" and F.IDX >= 0) and U.Find(F.TP) or nil
    if Cm and A.Safe(function() return U.IsA(Cm, "InstancedStaticMeshComponent") end, false) then
        local Owner = A.Safe(function() return Cm:GetOwner() end, nil)
        if Owner and A.IsAlive(Owner) and A.Safe(function() return U.IsA(Owner, "InstancedFoliageActor") end, false) then
            local Out = {}
            local ok, Got = pcall(function() return Cm:GetInstanceTransform(F.IDX, Out, false) end)
            local Tr = ok and Got ~= false and Out.Translation or nil
            local X, Y, Z = Tr and tonumber(Tr.X), Tr and tonumber(Tr.Y), Tr and tonumber(Tr.Z)
            if X and Y and Z and (X - F.T.X) ^ 2 + (Y - F.T.Y) ^ 2 <= 900 and math.abs(Z - F.T.Z) <= 60 then
                return Cm, F.IDX
            end
        end
    end
    local World = A.Coop and A.Coop.World
    if F.MESH ~= "" and type(World) == "table" and type(World.HarvFind) == "function" then
        local C2, I2 = World.HarvFind(F.MESH, F.T.X, F.T.Y, F.T.Z)
        if C2 and A.IsAlive(C2) and tonumber(I2) then return C2, math.floor(tonumber(I2)) end
    end
    return nil, -1
end

-- Erntekoerper-Actor (Baum/Stein) in HARV_R um T; Einschlag nah genug; nicht schon gefaellt
function H.MRelHarvActor(F, K, Now)
    local O, L = H.MRelPick(U.MREL_HARV[K], Now, F.T, U.MREL.HARV_R)
    if not O then return nil, "miss" end
    if U.Dist(L, F.I) > (K == "T" and U.MREL.TREE_IMP or U.MREL.ROCK_IMP) then return nil, "reach" end
    local Addr = O:GetAddress()
    if H.MRelFelled[Addr] then return nil, "dead" end
    if H.MRelTreeHP[Addr] then
        local MH = tonumber(A.Safe(function() return O.MaxHits end, nil))
        if MH and MH <= 0 then H.MRelFelled[Addr] = os.clock() return nil, "dead" end
    end
    return O
end

-- PrimitiveComponent eines Erntekoerpers (StaticMesh-Komponente, sonst Wurzel)
function H.MRelPrim(O)
    local SM = A.Safe(function() return O.StaticMesh end, nil)
    if SM and A.IsAlive(SM) and A.Safe(function() return U.IsA(SM, "PrimitiveComponent") end, false) then return SM end
    local R = A.Safe(function() return O:K2_GetRootComponent() end, nil)
    return (R and A.IsAlive(R)) and R or nil
end

-- Steht das Ziel schon in HitActors der Host-Kopie (Host-eigener Treffer in diesem Schlag)?
function H.MRelInHitActors(W, TAddr)
    local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
    if not WC then return false end
    local Arr = A.Safe(function() return WC.HitActors end, nil)
    if Arr == nil then return false end
    local Found = false
    local function Check(O)
        if O and A.IsAlive(O) and O:GetAddress() == TAddr then Found = true end
    end
    if type(Arr) == "table" then
        for _, X in ipairs(Arr) do
            pcall(Check, X)
            if Found then break end
        end
    else
        pcall(function()
            Arr:ForEach(function(_, Elem)
                pcall(Check, Elem:get())
                if Found then return true end
            end)
        end)
    end
    return Found
end

-- Host-Kopie der Gastwaffe: angehaengte BP_MeleePickup_C der Klasse Cls, bevorzugt mit Owner = Gastfigur
function H.MRelWeapon(Pawn, PawnAddr, Cls)
    local Fallback = nil
    for _, X in ipairs(U.Attached(Pawn)) do
        if A.Safe(function() return U.IsA(X, "BP_MeleePickup_C") end, false) and H.MRelClsName(X) == Cls then
            if H.OwnerOf(X) == PawnAddr then return X end
            Fallback = Fallback or X
        end
    end
    return Fallback
end

-- Schlag-Zustand je Gast (letzte 3 Schlaege, an die Epoche gebunden); nil = verwerfen
function H.MRelSwing(G, E, F, Clock)
    local St = H.MRelStat
    local SS = H.MRelSw[E.Key]
    if not SS or SS.Epoch ~= E.Epoch then
        SS = { Epoch = E.Epoch, Cur = 0, List = {}, PowAt = -99 }
        H.MRelSw[E.Key] = SS
    end
    local S = SS.List[F.Sw]
    if S then
        if S.Rej then St.limit = St.limit + 1 return nil end
        return S
    end
    if F.Sw <= SS.Cur then St.limit = St.limit + 1 return nil end
    if not U.Rate("mrels" .. E.Key, U.MREL.SW_RATE) then
        St.rate = St.rate + 1
        Net.SecWarn(G, E.Key, "cb_mrel_swing")
        return nil
    end
    -- Host-Notify (combat_mrelay_notify): verbrauchen; Power nur, wenn die Host-Notify Power war
    local Note = E.Note
    if Note then Note.Uses = Note.Uses + 1 end
    S = { N = 0, HN = 0, Added = {}, Harv = {}, Pow = F.P == true and (Note == nil or Note.P == true) }
    if S.Pow then
        if Clock - SS.PowAt < 1.0 then S.Rej = true else SS.PowAt = Clock end
    end
    SS.List[F.Sw], SS.Cur = S, F.Sw
    for Id in pairs(SS.List) do
        if Id <= F.Sw - 3 then SS.List[Id] = nil end
    end
    if S.Rej then St.limit = St.limit + 1 return nil end
    return S
end

-- Treffer je Schlag wie MaxMeleeHits: Power 6, sonst MultiHit (Host-CVar) ? MaxActorsToHitInSwing? der Host-Kopie : 1
function H.MRelLimit(W, Pw)
    if Pw then return U.MREL.POWER_MAX end
    local CU = C.ConsoleUtils()
    local Multi = CU and A.Safe(function() return CU:GetBoolCVar(FName(C.CVAR)) end, false) == true
    if not Multi then return 1 end
    local WC = U.Comp(W, "BP_WeaponsPickupComponent", "BP_WeaponsPickupComponent_C")
    local N = WC and tonumber(A.Safe(function() return WC["MaxActorsToHitInSwing?"] end, nil)) or 1
    return math.max(1, math.floor(N))
end

-- Einen gemeldeten Treffer pruefen und auf der Host-Kopie der Gastwaffe ausfuehren
function H.MRelApply(E, Now)
    local St, F, K = H.MRelStat, E.F, E.F.K
    local G = Net.Guests[E.Key]
    if not (G and G.Epoch == E.Epoch and Net.Has("cb_mrel", G)) then return end
    local Clock = os.clock()
    if Clock - E.T > 2 then St.rate = St.rate + 1 return end
    local Pawn, PC = H.PawnPC(G)
    if not Pawn or A.Safe(function() return Pawn["PlayerDead?"] end, false) == true then St.dead = St.dead + 1 return end
    local PawnAddr = Pawn:GetAddress()
    local W = H.MRelWeapon(Pawn, PawnAddr, F.WC)
    if not W then St.nowpn = St.nowpn + 1 return end
    -- Schlag-Nachweis: ein neuer Relay-Schlag braucht eine Host-Notify (MeleeHitDetect) der Gastfigur; kurz warten,
    -- falls der Treffer vor der Montage ankommt
    E.Note = nil
    -- erst ab der ersten gesehenen Host-Notify (Hook steht, feuert aber nie -> alter Weg statt alles verwerfen)
    if U.On("combat_mrelay_notify") and H.MRelNoteOk and H.MRelNoteSeen and H.MRelNewSwing(E, F) then
        E.Note = H.MRelNoteFind(PawnAddr, Clock)
        if not E.Note then
            if Clock - E.T < U.MREL.NOTE_WAIT then H.MRelRetry[#H.MRelRetry + 1] = E return end
            St.note = St.note + 1
            return
        end
    end
    if not U.Rate("mrelh" .. E.Key, U.MREL.HIT_RATE) then
        St.rate = St.rate + 1
        return Net.SecWarn(G, E.Key, "cb_mrel_rate")
    end
    local S = H.MRelSwing(G, E, F, Clock)
    if not S then return end
    local Pw = S.Pow == true and F.P == true
    local Limit = H.MRelLimit(W, Pw)
    -- Reichweite (Gastfigur zum Einschlag, mit Lag-Zuschlag aus der eigenen Geschwindigkeit)
    local L = U.Loc(Pawn)
    local Tol = math.min(U.MREL.LAG_MAX, H.MRelSpeed(Pawn) * U.MREL.LAG_S)
    if U.Dist(L, F.I) > U.MREL.REACH + Tol or math.abs(L.Z - F.I.Z) > U.MREL.REACH_Z then St.reach = St.reach + 1 return end
    -- Ziel
    local Target, Comp, Idx, Harv, Why = nil, nil, -1, false, nil
    if K == "B" or K == "H" or K == "W" then
        Target, Why = H.MRelActorTarget(F, G, PawnAddr, Clock)
    elseif F.TC == "ISM" then
        if U.Dist(F.I, F.T) > U.MREL.INST_R then St.reach = St.reach + 1 return end
        -- Baum: Einschlag am Stamm (waagrecht nah an der Instanz), Hoehe grosszuegig
        if K == "T" and U.On("combat_mrelay_strict")
            and (F.I.X - F.T.X) ^ 2 + (F.I.Y - F.T.Y) ^ 2 > U.MREL.TREE_XY ^ 2 then
            St.reach = St.reach + 1
            return
        end
        Comp, Idx = H.MRelInst(F)
        if Comp and U.On("combat_mrelay_strict") and not H.MRelCompOk(Comp, K) then
            St.miss = St.miss + 1      -- keine Kollision oder andere Art (Stein als Baum o. ae.)
            return
        end
        if Comp then
            Target = A.Safe(function() return Comp:GetOwner() end, nil)
            if not (Target and A.IsAlive(Target)) then Target, Comp, Idx = nil, nil, -1 end
        end
        if not Target then
            Harv = true
            Target, Why = H.MRelHarvActor(F, K, Clock)
        end
    else
        Harv = true
        Target, Why = H.MRelHarvActor(F, K, Clock)
    end
    if not Target then
        Why = Why or "miss"
        St[Why] = (St[Why] or 0) + 1
        return
    end
    local TAddr = Target:GetAddress()
    -- Figur-Ziel: Gastfigur -> Ziel direkt (Host-Lagen) mit Lag-Zuschlag beider Seiten; Sichtlinie
    if K == "B" or K == "H" then
        if U.On("combat_mrelay_strict") then
            local okT, TL = pcall(U.Loc, Target)
            if not okT or U.Dist(L, TL) > U.MREL.REACH_T + Tol + H.MRelTol(Target) then St.reach = St.reach + 1 return end
        end
        if U.On("combat_mrelay_los") and not H.MRelLos(Pawn, Target) then St.los = St.los + 1 return end
    end
    -- Grenzen je Schlag (Einzelspieler: HitActors/MaxMeleeHits; Erntekoerper ohne AddUnique -> eigene Grenze)
    local SKey = Comp and (tostring(Comp:GetAddress()) .. "|" .. tostring(Idx)) or tostring(TAddr)
    local HLim = Pw and 2 or math.max(1, math.min(Limit, 2))
    if Harv then
        local Cap = math.max(1, math.floor(Core.Flag("combat_mrelay_harv", 2)))
        if (not Pw and S.N >= Limit) or (S.Harv[SKey] or 0) >= Cap then St.limit = St.limit + 1 return end
        -- verschiedene Erntekoerper je Schlag begrenzen (sonst beliebig viele Baeume mit einem Schlag)
        if U.On("combat_mrelay_strict") and not S.Harv[SKey] and (S.HN or 0) >= HLim then
            St.limit = St.limit + 1
            return
        end
    else
        if S.Added[SKey] then St.dup = St.dup + 1 return end
        if S.N >= Limit then St.limit = St.limit + 1 return end
        if not Comp and Clock - (H.MRelLastT[E.Key .. "|" .. SKey] or -99) < U.MREL.SAME_T then
            St.dup = St.dup + 1
            return
        end
    end
    -- Doppel gegen Host-eigene Treffer: Ledger (Waffe|Ziel bzw. Waffe|Foliage-Actor) und HitActors der Host-Kopie
    local WAddr = W:GetAddress()
    local NT = H.MNat[tostring(WAddr) .. "|" .. tostring(TAddr)]
    if NT and Clock - NT < U.MREL.DEDUP then St.dup = St.dup + 1 return end
    -- HitActors-Eintraege, die das Relay selbst gelegt hat (Treffer kam nach der NotifyEnd der Host-Kopie an),
    -- zaehlen nicht: sonst faellt der naechste Schlag auf dasselbe Ziel als "doppelt" weg (combat_mrelay_hafix)
    local HAKey = tostring(WAddr) .. "|" .. tostring(TAddr)
    local RelayHA = U.On("combat_mrelay_hafix") and H.MRelHA[HAKey] ~= nil and Clock - H.MRelHA[HAKey] < 5
    if (K == "B" or K == "H" or K == "W") and not RelayHA and H.MRelInHitActors(W, TAddr) then
        St.dup = St.dup + 1
        return
    end
    -- COMBAT-4: Nahkampfwaffe laut Host-Inventar kaputt (<= 0) -> wie das Spiel "Item durability too low" (nur mit
    -- combat_dur_gate=1; Standard: nur loggen "wuerde ablehnen")
    -- Abschluss-Runde: nur mit laufender Messung (combat_dur_v2 aus/Core.Fail -> eingefrorener Wert, nicht sperren)
    local DN = U.On("combat_dur_v2") and H.DurNow[E.Key] or nil
    if DN and DN.M and DN.M <= 0 then
        if U.Opt("combat_dur_gate") then
            St.dur = (St.dur or 0) + 1
            if Clock - (H.DurNoteAt[E.Key] or -99) >= 3 then
                H.DurNoteAt[E.Key] = Clock
                if Net.Has("ui_note2", G) then
                    Net.Send("note2", Net.Enc("Item durability too low") .. "||1,1,1,1|4|1", G, 0)
                end
            end
            return
        elseif Clock - (H.DurWouldAt[E.Key] or -99) > 60 then
            H.DurWouldAt[E.Key] = Clock
            Log("Haltbarkeit: Nahkampfwaffe von %s kaputt (%.1f) - wuerde Treffer ablehnen (combat_dur_gate=0)",
                tostring(G.PCName or E.Key), DN.M)
        end
    end
    -- Owner-Kette -> Gast (Causer, Client-RPCs, GetPlayerX(0)), Faehigkeiten des Gast-PCs
    if U.On("combat_owner_weapons") and H.OwnerOf(W) ~= PawnAddr then H.SetOwner(W, Pawn, "combat_owner_weapons") end
    if U.On("combat_skills") and PC then H.BindSkills(W, PC, E.Key) end
    if K == "T" and Harv and U.On("combat_owner_world") and H.OwnerOf(Target) ~= PawnAddr then
        H.SetOwner(Target, Pawn, "combat_owner_world")      -- Baum-Ertrag laeuft erst nach Delay (nur Actor-Owner)
    end
    -- AI-2/WORLD-24 + CORE-18: Befall (Wellen-KI @02f4 ueber GetPlayerCharacter(0)) und Muell (Belohnung synchron im
    -- Delegate) gehoeren dem Schlaeger, bevor der Treffer laeuft (der Treffer-Hook ueberspringt Relay-Aufrufe)
    if K == "W" and U.On("combat_owner_world") and H.OwnerOf(Target) ~= PawnAddr
        and A.Safe(function() return U.IsA(Target, "BP_Infestation_C") or U.IsA(Target, "TrashObject_C") end, false) then
        H.SetOwner(Target, Pawn, "combat_owner_world")
    end
    local Vec = { X = F.I.X, Y = F.I.Y, Z = F.I.Z }
    local Hits = Pw and math.random(3, 4) or 1
    local Fn = U.MREL_FN[K]
    local Prim = Comp
    if (K == "T" or K == "R") and not Comp then Prim = H.MRelPrim(Target) end
    H.MRelBusy = true
    local okC, errC = pcall(function()
        if K == "B" or K == "H" then
            W[Fn](W, Target, Vec, Pw)
        elseif K == "W" then
            W:HitObjectWorld(Target, Pw)
        else
            W[Fn](W, Target, Vec, Prim, Comp and Idx or -1, Hits, {})
        end
    end)
    H.MRelBusy = false
    if not okC then
        St.err = St.err + 1
        if Core.Fail("combat_mrelay", errC) and not H.MRelErrLogged then
            H.MRelErrLogged = true
            Log("Nahkampf-Relay aus (%s): %s", Fn, tostring(errC))
        end
        return
    end
    if Harv then
        if not S.Harv[SKey] then S.HN = (S.HN or 0) + 1 end
        S.Harv[SKey] = (S.Harv[SKey] or 0) + 1
    else
        S.N = S.N + 1
        S.Added[SKey] = true
        H.MRelLastT[E.Key .. "|" .. SKey] = Clock
        if K == "B" or K == "H" or K == "W" then H.MRelHA[HAKey] = Clock end
    end
    if K == "B" or K == "H" then
        -- Review R1 (combat_kf_defer): Schlag auf eine wartende tote Gastfigur ueberschreibt den Letzter-Treffer nicht
        local TName, Rec = U.Name(Target), { Key = E.Key, T = Now }
        if not (next(H.PvpPend) ~= nil and U.On("combat_kf_defer") and H.KfCatch(H.PvpPend, TName, Rec, Now)) then
            H.LastHit[TName] = Rec
        end
        H.ShotAt[E.Key] = Now
    end
    if H.MRelProven[E.Key] ~= E.Epoch then
        H.MRelProven[E.Key] = E.Epoch
        Log("Nahkampf-Relay aktiv fuer %s", tostring(G.PCName or E.Key))
    end
    if Harv and A.IsAlive(Target) then
        local MH = tonumber(A.Safe(function() return Target.MaxHits end, nil))
        if MH then
            H.MRelTreeHP[TAddr] = MH
            if MH <= 0 then
                -- Ertrag (combat_mrelay_yield): erst bei MaxHits<=0, einmal je Erntekoerper
                if not H.MRelFelled[TAddr] and U.On("combat_mrelay_yield") then H.MRelYieldAdd(E, K, Clock) end
                H.MRelFelled[TAddr] = Clock
            end
        end
    elseif Comp then
        -- Erster Treffer auf eine Instanz: Host hat eben den replizierten Erntekoerper gespawnt -> w_harv sofort
        local World = A.Coop and A.Coop.World
        if type(World) == "table" and type(World.HarvNow) == "function" then pcall(World.HarvNow) end
    end
    St.ok = St.ok + 1
    H.EndProtect(E.Key, G)        -- PLAYER-25: eigener Angriff beendet den Spawn-Schutz
end
H.DurNoteAt, H.DurWouldAt = {}, {}

-- ---- Relay-Ertrag (Host, combat_mrelay_yield). Decode 5.6: Rocks-UB @016f MaxHits<=0 -> @0406 / Tree-UB @046c ->
-- Delay(0.2) @049c -> @0167 GetPlayerCharacter(0)->BP_JigComponent_C.JigTryAddItemSomewhere(DA_Rock/DA_WoodenLog).
-- Fuer die Gastkomponente ist LocalJSIContainers beim Server leer (nur SetupInventoryWidget, IsLocallyControlled) ->
-- JigTryAddGetPendingRef ungueltig -> L_049c JigMP_OnRequestDropItem = Bodenobjekt vor dem Gast (Vertrag A5, wie
-- Brunnen ls_build OW.GroundToInv). Darum: frisches Bodenobjekt (DA_Rock/DA_WoodenLog, <= 300 uu, nicht geladen)
-- per AddNewItemSomewhere (Variante A: CLIENT_AddNewItem an den Gast) ins Gastinventar, dann Bodenobjekt weg.
-- WORLD-21: Hinweis wie im Einzelspieler (Rocks-UB @050d / Tree-UB @026c: "... added to inventory", Symbol rocks2/wood2,
-- weiss, 3 s); ls_ui F.Drain laesst "... dropped on ground" des Hosts weg, solange E11 MRelYieldPending(Key) wahr ist
U.MREL_YIELD = { R = { DA = "DA_Rock", Wait = 0.15, Name = "Steine", Note = "Rocks added to inventory",
                       Icon = "/Game/UI/Textures/over_250_survival_flat_icons/rocks2.rocks2" },
                 T = { DA = "DA_WoodenLog", Wait = 0.45, Name = "Holz", Note = "Wood added to inventory",
                       Icon = "/Game/UI/Textures/over_250_survival_flat_icons/wood2.wood2" } }
U.MREL_PICK = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }
H.MRelYield = H.MRelYield or {}
H.MRelYieldAt = H.MRelYieldAt or {}   -- [Gast-Key] = os.clock der letzten Relay-Ernte (E11, 2 s)

function H.MRelYieldAdd(E, K, Clock)
    local Y = U.MREL_YIELD[K]
    if not Y or #H.MRelYield >= 16 then return end
    H.MRelYield[#H.MRelYield + 1] = { Key = E.Key, Epoch = E.Epoch, K = K, At = Clock, Due = Clock + Y.Wait, N = 0 }
    H.MRelYieldAt[E.Key] = Clock
end

-- true = erledigt (verschoben oder aufgegeben), false = spaeter nochmal
function H.MRelYieldTake(R)
    local Y = U.MREL_YIELD[R.K]
    local G = Net.Guests[R.Key]
    if not (Y and G and G.Epoch == R.Epoch) then return true end
    local Pawn = H.PawnPC(G)
    local Jig = Pawn and A.Safe(function() return Pawn.BP_JigMultiplayer end, nil)
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not (Jig and A.IsAlive(Jig) and WL) then return true end
    local PL = U.Loc(Pawn)
    local MaxAge = os.clock() - R.At + 0.5
    local Cand = {}
    for _, Cls in ipairs(U.MREL_PICK) do
        local okF, List = pcall(FindAllOf, Cls)
        for _, O in ipairs(okF and type(List) == "table" and List or {}) do
            -- billige Filter (Flags/Alter) vor der Lage, dann DataAsset-Name
            local DA = A.IsAlive(O) and A.Safe(function()
                if O:HasAnyFlags(WL) then return nil end
                local Age = tonumber(O:GetGameTimeSinceCreation())
                if not Age or Age > MaxAge then return nil end
                if A.IsAlive(O:GetAttachParentActor()) then return nil end
                local PC0 = O.BP_JigPickupComponent
                local IDA = A.IsAlive(PC0) and PC0.ItemDataAsset or nil
                if not (IDA and A.IsAlive(IDA) and IDA:GetFName():ToString() == Y.DA) then return nil end
                return IDA
            end, nil) or nil
            if DA then
                local okL, L = pcall(U.Loc, O)
                local D = okL and U.Dist(PL, L) or nil
                if D and D <= 300 then Cand[#Cand + 1] = { O = O, D = D, DA = DA } end
            end
        end
    end
    if #Cand == 0 then
        R.N = R.N + 1
        if R.N < 3 then return false end
        Log("Relay-Ertrag %s fuer %s: kein Bodenobjekt gefunden", Y.Name, tostring(G.PawnName or G.PCName or R.Key))
        return true
    end
    table.sort(Cand, function(P1, P2) return P1.D < P2.D end)
    local Moved = 0
    for I = 1, math.min(4, #Cand) do
        local O, DA = Cand[I].O, Cand[I].DA
        local Out, AddT, DropT = {}, {}, {}
        local JC = A.Safe(function() return O.BP_JigPickupComponent end, nil)     -- CORE-20: Komponente pruefen
        if JC and A.IsAlive(JC) then pcall(function() JC:GetCount(Out) end) end
        local Cnt = Out.Count
        if Cnt == nil then for _, V in pairs(Out) do Cnt = V break end end
        Cnt = math.max(1, math.floor(tonumber(Cnt) or 1))
        local ok, err = pcall(function()
            Jig:AddNewItemSomewhere(DA, Cnt, nil, 0, true, FName("None"), AddT, DropT, {}, {})
        end)
        if not ok then
            if Core.Fail("combat_mrelay_yield", err) then Log("Relay-Ertrag aus: %s", tostring(err)) end
            return true
        end
        local Added = AddT.Added
        if Added == nil then for _, V in pairs(AddT) do Added = V break end end
        local Dropped = DropT["Dropped?"]
        if Dropped == nil then for _, V in pairs(DropT) do Dropped = V break end end
        if not (Added == false and Dropped ~= true) then
            pcall(function() O:K2_DestroyActor() end)
            Moved = Moved + Cnt
        end
    end
    if Moved > 0 then
        Log("Relay-Ertrag: %d %s vom Boden ins Inventar von %s", Moved, Y.Name, tostring(G.PawnName or G.PCName or R.Key))
        if Net.Has("ui_note2", G) then
            H.MRelYieldAt[R.Key] = os.clock()   -- E11: Host-Hinweis "... dropped on ground" noch 2 s unterdruecken
            Net.Send("note2", Net.Enc(Y.Note) .. "|" .. Net.Enc(Y.Icon) .. "|1,1,1,1|3|0", G, 0)
        end
    end
    return true
end

function H.MRelYieldTick()
    if #H.MRelYield == 0 then return end
    local Clock, Keep = os.clock(), {}
    for _, R in ipairs(H.MRelYield) do
        if Clock < R.Due then
            Keep[#Keep + 1] = R
        else
            local ok, Done = pcall(H.MRelYieldTake, R)
            if not ok then
                Core.Fail("combat_mrelay_yield", Done)
            elseif not Done then
                R.Due = Clock + 0.5
                Keep[#Keep + 1] = R
            end
        end
    end
    H.MRelYield = Keep
end

-- Host-Tick (0,1 s): Hooks, Sperrliste, Aufraeumen, Warteschlange (hoechstens PER_TICK), Statistik je 60 s
function H.MRelTick(Now)
    if not U.On("combat_mrelay") then
        H.MRelHostOff()
        return
    end
    local Clock = os.clock()
    -- CORE-18: Schalter fuer die Hook-Koerper und die Gastfiguren-Adressen (Notify-Hook vergleicht nur Adressen)
    H.MRelOnF, H.MRelNoteOn = true, U.On("combat_mrelay_notify")
    if Clock >= (H.MRelPawnAt or 0) then
        H.MRelPawnAt = Clock + 0.5
        local T = {}
        Net.ForEachGuest(function(G)
            local P = G.Epoch and H.PawnPC(G)
            if P then T[P:GetAddress()] = true end
        end)
        H.MRelPawns = T
    end
    H.MRelHook()
    H.MRelHookNotify()
    if Clock >= (H.MRelDenyAt or 0) then
        H.MRelDenyAt = Clock + 0.5
        local ok, err = pcall(H.MRelDeny)
        if not ok then Core.Fail("combat_mrelay_excl", err) end
    end
    if Clock >= (H.MRelPruneAt or 0) then
        H.MRelPruneAt = Clock + 2
        local N = 0
        for Key, T in pairs(H.MNat) do
            if Key ~= "N" then
                if Clock - T > 5 then H.MNat[Key] = nil else N = N + 1 end
            end
        end
        H.MNat.N = N
        for Key, T in pairs(H.MRelFelled) do
            if Clock - T > 60 then H.MRelFelled[Key], H.MRelTreeHP[Key] = nil, nil end
        end
        for Key, T in pairs(H.MRelLastT) do
            if Clock - T > 5 then H.MRelLastT[Key] = nil end
        end
        for Key, T in pairs(H.MRelHA) do
            if Clock - T > 5 then H.MRelHA[Key] = nil end
        end
        for Key, L in pairs(H.MNote) do
            if #L == 0 or Clock - L[#L].T > 5 then H.MNote[Key] = nil end
        end
        for Key, E in pairs(H.MRelCache) do
            if Clock - E.T > 5 then H.MRelCache[Key] = nil end
        end
        local NT = 0
        for _ in pairs(H.MRelTreeHP) do NT = NT + 1 end
        if NT > 500 then H.MRelTreeHP = {} end
    end
    local Q = H.MRelQ
    if #Q > 0 then
        local Batch, Rest = {}, {}
        for I, E in ipairs(Q) do
            if I <= U.MREL.PER_TICK then Batch[#Batch + 1] = E else Rest[#Rest + 1] = E end
        end
        H.MRelQ = Rest
        for _, E in ipairs(Batch) do
            local ok, err = pcall(H.MRelApply, E, Now)
            H.MRelBusy = false
            if not ok then
                H.MRelStat.err = H.MRelStat.err + 1
                Core.Fail("combat_mrelay", err)
            end
        end
    end
    if U.On("combat_mrelay_yield") then H.MRelYieldTick() elseif #H.MRelYield > 0 then H.MRelYield = {} end
    -- Auf die Host-Notify wartende Treffer im naechsten Tick erneut (Reihenfolge bleibt, hoechstens Q_MAX)
    if #H.MRelRetry > 0 then
        local Retry = H.MRelRetry
        H.MRelRetry = {}
        local NQ = {}
        for _, E in ipairs(Retry) do if #NQ < U.MREL.Q_MAX then NQ[#NQ + 1] = E end end
        for _, E in ipairs(H.MRelQ) do if #NQ < U.MREL.Q_MAX then NQ[#NQ + 1] = E end end
        H.MRelQ = NQ
    end
    if not H.MRelLogAt then H.MRelLogAt = Clock + 60 end
    if Clock >= H.MRelLogAt then
        H.MRelLogAt = Clock + 60
        local St = H.MRelStat
        local Sig = table.concat({ St.ok, St.dup, St.reach, St.miss, St.dead, St.pvp, St.limit, St.rate, St.nowpn,
                                   St.los, St.note }, ",")
        if Sig ~= (H.MRelLogSig or "0,0,0,0,0,0,0,0,0,0,0") then
            H.MRelLogSig = Sig
            Log("Nahkampf-Relay: %d angenommen, %d doppelt, %d Reichweite, %d Ziel fehlt, %d tot, %d PvP, %d Limit, " ..
                "%d Rate, %d Waffe fehlt, %d keine Sicht, %d ohne Host-Schlag (exklusiv: %s)", St.ok, St.dup, St.reach,
                St.miss, St.dead, St.pvp, St.limit, St.rate, St.nowpn, St.los, St.note, tostring(H.MRelExcl == true))
        end
    end
end

-- ===================================================================== Modul-Vertrag

M.Handlers = {
    cb_imp = function(Data, Sender)
        if Net.Side == "host" then H.OnImpact(Data, Sender) else C.OnImpact(Data) end
    end,
    cb_proj = function(Data, Sender)
        if Net.Side == "host" then H.OnProj(Data, Sender) end
    end,
    cb_projfx = function(Data)
        if Net.Side == "client" then C.OnProjFx(Data) end
    end,
    cb_boom = function(Data)
        if Net.Side == "client" then C.OnBoom(Data) end
    end,
    cb_boomreq = function(Data, Sender)
        if Net.Side == "host" then H.OnBoomReq(Data, Sender) end
    end,
    -- Gast -> Host: eigene Nahkampftreffer (Nahkampf-Relay), nur einreihen
    cb_mrel = function(Data, Sender)
        if Net.Side == "host" and U.On("combat_mrelay") then H.MRelIn(Data, Sender) end
    end,
    -- Gast -> Host (COMBAT-5, K5): eigener Treffer auf ein Nicht-Fleisch-Ziel, nur pruefen und einreihen (H.OdTick)
    cb_od = function(Data, Sender)
        if Net.Side == "host" and U.On("combat_objdmg") then H.OdIn(Data, Sender) end
    end,
    -- Gast -> Host (COMBAT-7, K6): Lage des eigenen Armbrust-Bolzens, nur pruefen und einreihen (H.BoltTick)
    cb_bolt = function(Data, Sender)
        if Net.Side == "host" and U.On("combat_bolt") then H.BoltIn(Data, Sender) end
    end,
    -- Host -> alle Gaeste (COMBAT-13, K7): Kill-Feed-Zeile, nur pruefen und einreihen (Anzeige in C.Fast)
    cb_kf = function(Data)
        if Net.Side == "client" then C.OnKf(Data) end
    end,
    -- Host -> Gast, Keyed "d" (COMBAT-4, K8): "<Schusswaffe>|<Nahkampf>[|<Slot>]" Haltbarkeit laut Host ("-" = unbekannt);
    -- Review R1: Slot-Tag der Messung (alter Host ohne dritten Teil -> S nil, altes Verhalten)
    cb_dur = function(Value)
        if Net.Side ~= "client" then return end
        if Value == nil then C.Dur = nil return end
        local F, Ml, S = tostring(Value):match("^([^|]*)|([^|]*)|?([^|]*)$")
        C.Dur = { F = tonumber(F), M = tonumber(Ml), S = (S ~= nil and S ~= "") and S or nil }
    end,
    cb_shots = function(Data, Sender)
        if Net.Side ~= "host" or not U.On("combat_durability") then return end
        local N = tonumber(Data)
        if not N or N < 0 or N > 100 then return Net.SecWarn(Sender, Sender.Key, "cb_shots") end
        H.Reported[Sender.Key] = (H.Reported[Sender.Key] or 0) + N
    end,
    cb_kills = function(Value)
        if Net.Side ~= "client" or Value == nil or not U.On("combat_credit") then return end
        local P = U.Split(Value)
        local PC = A.LocalPC()
        if not (PC and A.IsAlive(PC)) then return end
        for I, F in ipairs(U.KILL_FIELDS) do              -- Felder 1..KILL_WIRE, dann ab 6 (5 = DaysSurvived)
            local V = tonumber(P[I <= U.KILL_WIRE and I or I + 1])
            if V then pcall(function() PC[F] = V end) end
        end
        local D = tonumber(P[U.KILL_WIRE + 1])
        if D then pcall(function() PC.DaysSurvived = D end) end
    end,
    -- Host -> Gast, Keyed-State "m": PvP-Politik "off" | "clan" | "all" (ausgewertet in C.FriendlyFireOff ueber Net.Get)
    cb_pvp = function(Value)
        if Net.Side ~= "client" or not U.PVP_MODES[Value] then return end
        if C.FF then for _, E in pairs(C.FF) do E.T = 0 end end   -- naechster Tick wendet sofort neu an
    end,
    cb_mines = function(Value)
        if Net.Side ~= "client" or Value == nil or not U.On("combat_mine_sync") then return end
        C.HostMines = { Raw = Value, T = os.clock(), Gen = U.Gen }
    end,
    cb_xp = function(Data)
        if Net.Side ~= "client" or not U.On("combat_xppopup") then return end
        local P = U.Split(Data)
        local XP, Kind = tonumber(P[1]), P[2]
        if not XP then return end
        local Fmt = ({ Z = "Zombie Killed, XP Given: %d", B = "Zombie Killed, XP Given: %d",
                       A = "Animal Killed, XP Given: %d", H = "Human Killed, XP Given: %d",
                       I = "Infestation Destroyed, XP Given: %d" })[Kind] or "XP Given: %d"
        pcall(A.ShowNote, string.format(Fmt, math.floor(XP + 0.5)))
    end,
}

-- CORE-30 (60 s, beide Seiten): Tabellen je Name/Adresse/Gast kuerzen - auf dem Dauer-Server gibt es keinen
-- Weltwechsel, der sie leert. Nur Pfade/Namen/Zeiten, keine UObjects.
function M.Janitor(Now)
    local Clock = os.clock()
    local function Old(T, Field, Max)
        for K, E in pairs(T) do
            local At = Field and type(E) == "table" and E[Field] or E
            if type(At) ~= "number" or Clock - At > Max then T[K] = nil end
        end
    end
    Old(U.RateTab, "T", 60)
    Old(H.BoomReq, "T", 60)
    Old(H.LastHit, "T", 30)
    Old(H.LastDmgOn, "T", 30)
    Old(H.KfHead, "T", 30)
    Old(H.CombatTag, nil, 120)
    Old(H.MRelYieldAt, nil, 10)
    Old(H.FfNoteAt, nil, 60)
    Old(C.BoltDone, nil, 60)
    Old(C.VisualGid, nil, 120)
    Old(H.Att, "T", 600)
    Old(C.Att, "T", 600)
    Old(H.OwnGone, nil, 60)                   -- CORE-31: laengstes Neu-Einlesen 30 s
    for K in pairs(H.TimerOn) do
        local Key = type(K) == "string" and K:match("^(.*)#[^#]*$") or nil
        if not (Key and Net.Guests[Key]) then H.TimerOn[K] = nil end
    end
    for Key in pairs(H.KfDead) do
        if not Net.Guests[Key] then H.KfDead[Key] = nil end
    end
    for Key in pairs(H.LastPawnP) do          -- Abschluss-Runde (combat_dead_pawn)
        if not Net.Guests[Key] then H.LastPawnP[Key] = nil end
    end
    -- Review R1 (combat_kf_defer): wartende Tode ohne Gast oder aelter als 5 s verwerfen
    for _, Pend in ipairs({ H.KfPend, H.PvpPend }) do
        Old(Pend, "At", 5)
        for Key in pairs(Pend) do
            if not Net.Guests[Key] then Pend[Key] = nil end
        end
    end
    -- Tote NPCs: Eintrag erst weg, wenn die Figur nicht mehr existiert (sonst zaehlte sie neu als Tod), fruehestens 120 s
    if next(H.DeadSeen) then
        local Live = {}
        for _, Ch in ipairs(A.Characters() or {}) do
            if A.IsAlive(Ch) then Live[U.Name(Ch)] = true end
        end
        for N, T in pairs(H.DeadSeen) do
            if not Live[N] and (type(T) ~= "number" or Clock - T > 120) then H.DeadSeen[N] = nil end
        end
    end
    -- Schuss-Tabellen je Waffen-Adresse: nur Waffen, die ein Gast gerade traegt (Adressen werden wiederverwendet)
    if Net.Side == "host" then
        local Addr = {}
        for _, W in pairs(H.Weap) do
            for _, P in ipairs(W.List) do
                local O = U.Find(P)
                if O then Addr[O:GetAddress()] = true end
            end
        end
        for _, T in ipairs({ H.ShotBase, H.ProjAmmo, H.BoltUsed }) do
            for K in pairs(T) do
                if not Addr[K] then T[K] = nil end
            end
        end
    end
    -- Gast: Sicht-Kopien und eigene Wuerfe, deren Actor weg ist
    for P in pairs(C.Visual) do
        if not U.Find(P) then C.Visual[P] = nil end
    end
    for Lid, P in pairs(C.Own) do
        if not U.Find(P) then C.Own[Lid] = nil end
    end
end

function M.HostTick(Now)
    if not U.On("combat_v2") or Net.Side ~= "host" or U.Loading() then return end
    U.CheckWorld()
    local ok, err = pcall(H.ScanWeapons, Now)
    if not ok then Core.Fail("combat_v2", err) end
    if U.On("combat_credit") then pcall(H.Stats) end
    -- COMBAT-4: echte Haltbarkeit je Gast (cb_dur, Relay-Ablehnung kaputter Nahkampfwaffen)
    if U.On("combat_dur_v2") then
        local okD, errD = pcall(H.DurState)
        if not okD and Core.Fail("combat_dur_v2", errD) then Log("Haltbarkeit v2 aus: %s", tostring(errD)) end
    elseif next(H.DurNow) then
        H.DurNow = {}                    -- Abschluss-Runde: Messung aus -> alte Werte verwerfen (H.MRelApply)
    end
    if U.On("combat_boom") then
        local okR, MineScan = pcall(U.RefreshExpl, H.RefPositions())
        if okR and MineScan and U.On("combat_mine_sync") then
            local okM, errM = pcall(H.PublishMines)
            if not okM and Core.Fail("combat_mine_sync", errM) then Log("Minen-Abgleich aus: %s", tostring(errM)) end
        end
    end
    -- N4b: ApplyDamage beobachten (Kill-Zuordnung; mit pvp=1/clan_ff=0 plus ffblock = Clan-Schutz), Besitzer "ls_combat"
    local Want = U.WatchWanted()
    if Want ~= (H.NativeWatched or nil) then
        local List = (Want == "ff" and U.NATIVE_DMG_FF) or (Want == "obs" and U.NATIVE_DMG) or nil
        local ok = pcall(Native.Watch, List, "ls_combat")
        if ok then
            H.NativeWatched = Want or false
            Log("ApplyDamage-Beobachtung ueber die DLL (cb_dmg): %s", Want == "ff" and "an, mit Clan-Schutz (ffblock)"
                or (Want == "obs" and "an (Kill-Zuordnung/Kill-Feed/Kampf-Markierung)" or "aus"))
        end
    end
end
U.PROJ_WEAPON = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"

function M.ClientTick(Now)
    if Net.Side ~= "client" or U.Loading() then return end
    if not U.On("combat_v2") then C.RestoreMultiHit() return end
    U.CheckWorld()
    local Pawn = A.Safe(A.OwnPawn, nil)
    local Hand = Pawn and A.IsAlive(Pawn) and U.HandFirearm(Pawn)
    local HandPath = Hand and U.Path(Hand) or nil
    if HandPath ~= C.HandPath then C.HandPath, C.LastSD = HandPath, nil end
    if U.On("combat_fire_diag") then
        local okD, errD = pcall(C.FireDiag, Pawn, Now)
        if not okD and Core.Fail("combat_fire_diag", errD) then Log("Schuss-Diagnose aus: %s", tostring(errD)) end
    else
        C.NoteOn = false
    end
    -- COMBAT-5: eigene Schusswaffen (Pfade) fuer die Aufrufer-Pruefung der cb_odw-Ereignisse
    if U.On("combat_objdmg") then
        local Own = {}
        if Pawn and A.IsAlive(Pawn) then
            for _, W in ipairs(U.Attached(Pawn)) do
                if A.Safe(function() return U.IsA(W, "BP_FirearmPickup_C") end, false) then
                    local P = U.Path(W)
                    if P then Own[P] = true end
                end
            end
        end
        C.OwnFire = Own
    end
    if U.On("combat_proj") then pcall(C.RegisterHooks) end
    -- COMBAT-7: Pfeil-Hook, sobald die Armbrust-Klassen geladen sind
    if U.On("combat_bolt") then
        local okB, errB = pcall(C.BoltHook)
        if not okB and Core.Fail("combat_bolt", errB) then Log("Armbrust-Bolzen aus: %s", tostring(errB)) end
    end
    if U.On("combat_melee_guard") then pcall(C.MeleeGuard) else C.RestoreMultiHit() end
    local okFF, errFF = pcall(C.FriendlyFireOff, Now)
    if not okFF then U.PvpFail("Friendly Fire", errFF) end
    if U.On("combat_attach_remote") then pcall(C.RemoteAttach, Now) end
    if U.On("combat_boom") and Pawn and A.IsAlive(Pawn) then
        local ok, P = pcall(U.Loc, Pawn)
        if ok then pcall(U.RefreshExpl, { P }) end
        if U.On("combat_mine_sync") then
            local okM, errM = pcall(C.ApplyMines)
            if not okM and Core.Fail("combat_mine_sync", errM) then Log("Minen-Abgleich aus: %s", tostring(errM)) end
        end
    end
    -- Haltbarkeit (Fallback ohne Coop.Shot.ServerShots beim Host): eigene Schuesse melden
    if U.On("combat_durability") and (C.ShotsSince or 0) > 0 and Net.Has("cb2") then
        Net.Send("cb_shots", tostring(C.ShotsSince), nil, 3)
        C.ShotsSince = 0
    end
end

-- Runde 9: Faehigkeiten cbod (K5), cbdur (K8), cb_hit2 (K9), cbbolt (K6), cbkf (K7); Abschluss-Runde: cbodn;
-- Net.Cap ohne Aenderung = No-op
function M.Caps9()
    -- Review R2: cbod = "Relay unterstuetzt" auf beiden Seiten (nicht mehr an C.OdReady gebunden: C.OdWatch wartet
    -- jetzt selbst auf Net.Has("cbod"), sonst kaeme keine Seite zuerst); gesendet wird weiter nur unterdrueckt
    Net.Cap("cbod", U.On("combat_objdmg"))
    -- Abschluss-Runde: cbodn = cb_od mit Trefferzahl (Feld 7, Summe je Ziel); alter Host ohne cbodn -> Gast einzeln
    Net.Cap("cbodn", U.On("combat_objdmg") and U.On("combat_od_batch"))
    Net.Cap("cbdur", U.On("combat_dur_v2"))
    Net.Cap("cb_hit2", U.On("combat_hit_server") and (Net.Side ~= "host" or H.SdeEntry == true))
    Net.Cap("cbbolt", U.On("combat_bolt"))
    Net.Cap("cbkf", U.On("combat_killfeed"))
end

function M.Init(Api)
    A = Api
    U.CheckWorld()
    -- COMBAT-15: MultiHit-Merker einer abgebrochenen Gast-Sitzung -> ohne Host-Verbindung zuruecksetzen
    C.MhInitAt = os.clock()
    C.MhMarker = (U.On("combat_multihit_restore") and Core.ReadAll(C.MhPath()) ~= nil) or nil
    if C.MhMarker then
        Log("MultiHit-Merker gefunden (Gast-Sitzung nicht sauber beendet) - wird ohne Host-Verbindung zurueckgesetzt")
        Core.Every("cb_mhr", 5, function(Now) return C.MhRestoreTask(Now) end)
    end
    Net.Cap("cb2", U.On("combat_v2"))
    -- Kill-Zaehler (cb_kills) nur, wenn beide Seiten combat_credit an haben; sonst bleibt Legacy "stats"
    Net.Cap("cb_kill", U.On("combat_credit"))
    -- Minen-Abgleich (cb_mines): beide Seiten mit combat_boom + combat_mine_sync
    Net.Cap("cb_mine", U.On("combat_boom") and U.On("combat_mine_sync"))
    -- Nahkampf-Relay (cb_mrel): Host = Schalter; Gast = Schalter UND Unterdrueckung der DLL bestaetigt
    Net.Cap("cb_mrel", U.On("combat_mrelay") and (Net.Side ~= "client" or C.MRelReady == true))
    -- Runde 9: Objektschaden-Relay (cbod = Relay unterstuetzt; Gast unterdrueckt erst mit Host-cbod), Haltbarkeit,
    -- Server-Hitmarker (Host
    -- erst, wenn cb_sde laut DLL beim Eintritt beobachtet wird)
    M.Caps9()
    -- E9 (COMBAT-3): aktive Waffe nach Spiel-Sicht (RepActorsData[ActiveWeapon]) fuer main.lua; nil, nil, false wenn
    -- combat_hand_v2 aus ist (dann bleibt main beim Socket-Weg). 3. Wert (handoff_main): Lesbar = Ergebnis gilt, auch
    -- "Hand frei" (Slot leer) - main faellt dann nicht auf die Socket-Suche zurueck
    A.Coop.CombatActiveWeapon = function(Pawn)
        if not U.On("combat_hand_v2") then return nil, nil, false end
        local ok, W, Slot, Read = pcall(U.ActiveWeapon, Pawn)
        if not ok then return nil, nil, false end
        return W, Slot, Read == true
    end
    -- E11 (WORLD-21): Relay-Ernte fuer diesen Gast-Key juenger als 2 s? (ls_ui F.Drain: "... dropped on ground" weglassen)
    A.Coop.MRelYieldPending = function(Key)
        local T = Key ~= nil and H.MRelYieldAt[Key] or nil
        return type(T) == "number" and os.clock() - T < 2
    end
    -- E10 (PLAYER-13): os.clock des letzten Treffers eines ANDEREN Spielers auf diese Figur (FName), haelt 120 s
    A.Coop.CombatTag = function(PawnName)
        if PawnName == nil then return nil end
        local T = H.CombatTag[tostring(PawnName)]
        if type(T) ~= "number" or os.clock() - T > 120 then return nil end
        return T
    end
    -- Fuer main.lua SyncStats: Kill-Zaehler dieses Gasts schickt ls_combat (cb_kills), Legacy "stats" auslassen
    A.Coop.CombatOwnsStats = function(PC)
        if not U.On("combat_credit") then return false end
        local G = Net.ByPC(PC)
        return G ~= nil and Net.Has("cb2", G) and Net.Has("cb_kill", G)
    end
    -- Letzter Gast-Treffer auf ein Ziel (FName, Host): Kopie {Key, T} oder nil (aelter als 10 s / unbekannt).
    -- H.LastHit bleibt fuer aeltere Leser (ls_ai/ls_world) unveraendert erhalten.
    A.Coop.CombatLastHit = function(Name)
        if Name == nil then return nil end
        local Hit = H.LastHit[type(Name) == "string" and Name or tostring(Name)]
        if type(Hit) ~= "table" or Hit.Key == nil then return nil end
        local T = tonumber(Hit.T)
        if not T or os.clock() - T > 10 then return nil end
        return { Key = Hit.Key, T = T }
    end
    -- Faehigkeiten jede Sekunde neu setzen: Schalter koennen sich zur Laufzeit aendern (coop.txt/Befehle);
    -- Net.Cap ist ohne Aenderung ein No-op und handelt bei Aenderung neu aus (h4/h4a), wie ls_inv "inv_caps"
    Core.Every("cb_caps", 1, function()
        Net.Cap("cb2", U.On("combat_v2"))
        Net.Cap("cb_kill", U.On("combat_credit"))
        Net.Cap("cb_mine", U.On("combat_boom") and U.On("combat_mine_sync"))
        Net.Cap("cb_mrel", U.On("combat_mrelay") and (Net.Side ~= "client" or C.MRelReady == true))
        M.Caps9()
    end)
    Core.Every("cb_muzzle", 0.1, function()
        local okM, errM = pcall(C.MuzzleTick)
        if not okM then Core.Fail("combat_muzzle_fix", errM) end
        local okR, errR = pcall(C.MuzRestore)
        pcall(C.AdsDiag)
        local okP, errP = pcall(C.PoseFix)
        if not okP then Core.Fail("combat_pose_fix", errP) end
        if not okR then Log("Muendung: Rueckbau-Fehler %s", tostring(errR)) end
    end)
    -- Nahkampf-Relay (UE 5.6): Gast meldet eigene Treffer, Host prueft und trifft auf seiner Kopie der Gastwaffe
    Core.Every("cb_mrel", 0.1, function(Now)
        if not U.On("combat_v2") then
            if C.MRelWatchOn or C.MRelGateOpen then pcall(C.MRelOff) end
            pcall(H.MRelHostOff)      -- DLL-Sperrliste sonst ohne combat_v2 haengend
            return
        end
        if U.Loading() then return end
        U.CheckWorld()
        local ok, err = true, nil
        if Net.Side ~= "host" and (H.MRelDenyN or next(H.MRelProven)) then pcall(H.MRelHostOff) end
        if Net.Side == "host" then
            ok, err = pcall(H.MRelTick, Now)
        elseif Net.Side == "client" then
            ok, err = pcall(C.MRelTick, Now)
        elseif C.MRelWatchOn or C.MRelGateOpen then
            ok, err = pcall(C.MRelOff)
        end
        if not ok and Core.Fail("combat_mrelay", err) and not M.MRelDownLogged then
            M.MRelDownLogged = true
            Log("Nahkampf-Relay aus: %s", tostring(err))
        end
    end)
    Core.Every("cb_fast", 0.1, function(Now)
        -- DLL-Beobachter (ApplyDamage) abmelden, sobald kein Host mehr bzw. ihn weder Kill-Credit noch Kill-Feed noch
        -- PvP-Kampf-Markierung brauchen (U.WatchWanted; HostTick laeuft dann evtl. nicht)
        if H.NativeWatched and U.WatchWanted() == nil then H.NativeOff() end
        -- Review R1: DLL-Listen/Sperren einer verlassenen Rolle bzw. ohne combat_v2 abmelden (ls_combat_od u. a.)
        local okR, errR = pcall(M.RoleWatchOff)
        if not okR and not M.RoleOffLogged then
            M.RoleOffLogged = true
            Log("Rollen-Aufraeumen fehlgeschlagen: %s", tostring(errR))
        end
        if not U.On("combat_v2") or U.Loading() then return end
        U.CheckWorld()
        if Net.Side == "host" then H.Fast(Now) elseif Net.Side == "client" then C.Fast(Now) end
    end)
    -- Owner-Trick (Fix-Plan #1/#2/#3/#17), nur Host mit Gaesten; eigener Aufgaben-Name fuer Core.Fail
    Core.Every("cb_own", 0.25, function() H.OwnTick() end)
    -- PvP (Runde 7): Politik/Allies/PvP-Kills; Fehler zaehlen auf "pvp" (Down -> pvp=0, altes Verhalten)
    Core.Every("cb_pvp", 0.5, function(Now)
        if U.Loading() then return end
        U.CheckWorld()
        local ok, err = pcall(H.PvpTick, Now)
        if not ok then U.PvpFail("Politik", err) end
        -- COMBAT-13: Kill-Feed (Host, alle PvP-Modi); eigener Ausfall-Name, schaltet PvP nicht ab
        if Net.Side == "host" and U.On("combat_v2") and U.On("combat_killfeed") then
            local okK, errK = pcall(H.KfTick, Now)
            if not okK and Core.Fail("combat_killfeed", errK) then Log("Kill-Feed aus: %s", tostring(errK)) end
        end
    end)
    -- CORE-30: Aufraeumen der Tabellen je Name/Adresse/Gast (Dauer-Server ohne Weltwechsel), 60 s
    Core.Every("cb_jan", 60, function(Now)
        if not U.Loading() then M.Janitor(Now) end      -- Fehler zaehlen auf "cb_jan" (Core.Every)
    end)
    Net.OnEvent("gone", function(Peer)
        if Net.Side == "host" and Peer and Peer.Key then
            H.Weap[Peer.Key], H.SD[Peer.Key], H.ShotAt[Peer.Key], H.Reported[Peer.Key] = nil, nil, nil, nil
            H.PvpDead[Peer.Key] = nil
            H.MRelSw[Peer.Key], H.MRelProven[Peer.Key] = nil, nil
            U.RateTab["mrel" .. Peer.Key], U.RateTab["mrelh" .. Peer.Key], U.RateTab["mrels" .. Peer.Key] = nil, nil, nil
            -- Runde 9
            H.HC[Peer.Key], H.DurNow[Peer.Key], H.EndProtAt[Peer.Key], H.FdCnt[Peer.Key] = nil, nil, nil, nil
            H.DurNoteAt[Peer.Key], H.DurWouldAt[Peer.Key] = nil, nil
            for _, P in ipairs({ "od", "odn", "sdem", "hcr", "hclog" }) do U.RateTab[P .. Peer.Key] = nil end
            H.LastPawnP[Peer.Key] = nil                             -- Abschluss-Runde (combat_dead_pawn)
            -- combat-2 (CORE-30): Kill-Feed, Hinweise, Relay-Ertrag, Raten und Level-Timer dieses PC-Keys
            H.KfDead[Peer.Key], H.FfNoteAt[Peer.Key], H.MRelYieldAt[Peer.Key] = nil, nil, nil
            H.KfPend[Peer.Key], H.PvpPend[Peer.Key] = nil, nil      -- Review R1 (combat_kf_defer)
            for _, P in ipairs({ "bolt", "proj", "imp", "boom" }) do U.RateTab[P .. Peer.Key] = nil end
            local Pre = Peer.Key .. "#"
            for K in pairs(H.TimerOn) do
                if type(K) == "string" and K:sub(1, #Pre) == Pre then H.TimerOn[K] = nil end
            end
        else
            -- Review R1: gesperrte Waffen freigeben (Gast bleibt evtl. in der Welt), dann Menge leeren
            if next(C.DurBlockedSet) and not U.Loading() then pcall(C.DurRelease, nil) end
            C.Dur, C.SlotBad, C.DurBlockedSet = nil, nil, {}
            C.OdCarry = {}                                          -- Abschluss-Runde (combat_od_batch)
            C.RestoreMultiHit()
            C.MRelGateOpen, C.MRelReady, C.MRelOkSince, C.MSw, C.MLastMs = false, false, nil, nil, nil
            C.MRelOut = {}
        end
    end)
    A.TestCommands.cb_status = function()
        local NP, NE, NO = 0, 0, 0
        for _ in pairs(H.Proj) do NP = NP + 1 end
        for _ in pairs(U.Expl) do NE = NE + 1 end
        for _ in pairs(H.OwnCache or {}) do NO = NO + 1 end
        local NF = 0
        for _ in pairs(C.FF or {}) do NF = NF + 1 end
        A.TestLog("Kampf: Seite %s, Proj %d, Sprengbares %d, Owner-Kandidaten %d, Waffe %s, Native %s, PvP %s, " ..
            "Watch %s, Allies %s, geschuetzt %d, Relay %s", tostring(Net.Side), NP, NE, NO, tostring(C.HandPath),
            tostring(U.NativeOn()), Net.Side == "client" and U.ClientPvpMode() or U.PvpMode(),
            tostring(H.NativeWatched), tostring(H.AlliesSig), NF, U.MRelState())
        local OS = H.OdStat
        A.TestLog("Kampf R9: Schuss-Kette Gast %s/Host %s, cb_sde %s (Eintritt %s, Abstand zuletzt %s), Treffer-Verstoesse %d, " ..
            "Sperren %s, Objektschaden Gast %s, Host ok %d/fehlt %d/Waffe %d/Klasse %d/Abstand %d, Haltbarkeit Gast %s, " ..
            "Server-Hitmarker %s", tostring(C.FdOn == true), tostring(H.FdOn == true), tostring(H.SdeOn),
            tostring(H.SdeEntry == true), H.SdDistAt and string.format("vor %.0f s", os.clock() - H.SdDistAt) or "-",
            H.HCViol or 0, tostring(H.SdeDenyN or 0), tostring(C.OdReady == true), OS.ok, OS.miss, OS.nowpn, OS.cls, OS.dist,
            C.Dur and string.format("%s|%s", tostring(C.Dur.F), tostring(C.Dur.M)) or "-", tostring(C.NativeHitUI == true))
    end
    A.TestCommands.cb_mrel = function()
        local St, CS = H.MRelStat, C.MRelStat
        local NP = 0
        for _ in pairs(H.MRelProven) do NP = NP + 1 end
        A.TestLog("Nahkampf-Relay: Seite %s, an %s, bereit %s, Tor %s, defekt %s, Beobachter %s, Schlag %s (Power %s), " ..
            "gesendet %d, verworfen %d, wartend %d, Power-Hook %s", tostring(Net.Side), tostring(U.On("combat_mrelay")),
            tostring(C.MRelReady == true), tostring(C.MRelGateOpen == true), tostring(C.MRelBroken == true),
            tostring(C.MRelWatchOn == true), tostring(C.MSw or 0), tostring(C.MSwPow == true), CS.sent, CS.drop,
            #(C.MRelOut or {}), tostring(C.MRelNotifyOk))
        A.TestLog("Nahkampf-Relay Host: %d angenommen, %d doppelt, %d Reichweite, %d Ziel fehlt, %d tot, %d PvP, %d Limit, " ..
            "%d Rate, %d Waffe fehlt, %d Fehler, %d keine Sicht, %d ohne Host-Schlag, Warteschlange %d, aktiv %d, " ..
            "gesperrte Waffen %s, exklusiv %s, Hooks %s, Schlag-Hook %s",
            St.ok, St.dup, St.reach, St.miss, St.dead, St.pvp, St.limit, St.rate, St.nowpn, St.err, St.los, St.note,
            #(H.MRelQ or {}), NP, tostring(H.MRelDenyN or 0), tostring(H.MRelExcl == true), tostring(H.MRelHooked == true),
            tostring(H.MRelNoteOk == true))
    end
    A.TestCommands.cb_boomtest = function()
        local Pawn = A.OwnPawn()
        if A.IsAlive(Pawn) then C.OnBoom(
"p:test;" .. U.Fmt(U.Loc(Pawn)) .. ";p;0") end
    end
    if A.Settings.friendly_fire ~= nil or Core.Extra.friendly_fire ~= nil then
        Log("Schalter friendly_fire ist veraltet und wird ignoriert: pvp=0 (niemand trifft Spieler), " ..
            "pvp=1 clan_ff=0 (Clan geschuetzt) oder pvp=1 clan_ff=1 (alle treffbar)")
    end
    Log("geladen (combat_v2=%s, pvp=%s)", tostring(U.On("combat_v2")), U.PvpMode())
end

return M
