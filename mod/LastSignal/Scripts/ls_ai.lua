-- Last Signal, Runde 5: KI v2 + Tiere v3 (ls_ai). Befunde: _NetTest\analysis\findings\ai.md
--   Host:  ai2 = Keyed-State je Gast (Zombie z, Boss b, Mensch h, Tier a, Geschuetz t, Nest n) mit HP, Max, Verhalten,
--          Tod, gelootet und Lage (2-m-Raster), nur in Reichweite. Montage-Relay ohne Hook (Polling, ai_mon).
--          Invoker + Sicht-Quelle der Gast-Figuren, Horde bei Gast-Tod, Blutmond (ai_bm), Fernkampf-KI wecken,
--          Tier-Kadaver-Jig replizieren.
--   Gast:  Bindung Id -> Kopie (Namen, nie Objekte merken), HP/Max/Tod anwenden, Waechter ohne Hooks (Eigenschaften),
--          Tier-Ragdoll ruhig halten, Geister entfernen, Blutmond nur vom Host.
-- UE 5.6 (Port): Familien ueber die Klassenkette, neue BP_MasterCoyoteSoldier_C (Officer/Rifleman) -> BP_MasterAICharacter_C
--          = "h" automatisch; Zombie 'Looted?'/AttackDamage, Blutmond als UDS-Sky-Modifier, Huntsman-Fleisch im Kadaver-Jig,
--          Geschuetz-Patch @032b.
-- Regeln: keine Hooks, Polling <= 10 Hz, FindAllOf <= 1 Hz je Klasse, alles in pcall, Objekte nur innerhalb eines Ticks
-- (bzw. der 0,2-s-Liste A.Characters()), Logs deutsch.
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local A

local F = { AI = "ai_v2", ANIM = "animal_v3", GUARD = "ai_guard", MON = "ai_montage", GHOST = "ai_ghosts",
            HORDE = "ai_horde", BM = "ai_bloodmoon", INV = "ai_invoker", WAKE = "ai_wake", AIO = "ai_aio_guest",
            RAG = "animal_ragdoll", LOOTREP = "animal_lootrep", GROUND = "animal_ground", MEAT = "animal_meat",
            TDIS = "ai_tdis", LOOTED = "ai_looted",
            -- Runde 9 (FIXPLAN 5.4)
            NOTRACE = "ai_notrace", LOCK = "ai_locktarget", HORDE2 = "ai_horde2", GDAYS = "ai_ghost_days",
            AIONEAR = "ai_aio_near", WAKEF = "ai_wake_fast", HITDIAG = "ai_hitdiag", MARK = "ai_markers",
            ROCK = "ai_bossrock", PERF = "ai_perf",
            -- Review-Runde 3
            AIOFAR = "ai_aio_far" }
local K = { RANGE = 15000, NEAR = 5000, MON = 4000, WAKE_IN = 6000, WAKE_FAR = 30000, Q = 200,
            KEEP = 400, MATCH = 600, MARGIN = 200, HORDE = 15000, MAX_APPLY = 60, MAX_MON = 40, MAX_MONQ = 40 }
-- Wurzelklassen der Familien (erste Treffer beim Hochlaufen der Klassenkette gewinnt)
-- AI-12: BP_AnimalDog_C (UE 5.6, Streichel-NPC) hat kein Health/IsDead?/Looted (props.tsv) -> keine Familie: kein
-- ai2-Verkehr, kein Waechter (der lokale Optimizer blendet den Hund wie im SP nach Abstand)
local FAM_ROOT = { BP_ZombieBoss_C = "b", BP_MasterZombie_C = "z", BP_MasterAICharacter_C = "h", BP_Animal_C = "a",
                   BP_MasterTurret_C = "t", BP_Infestation_C = "n", BP_PlayerCharacter_C = "-", BP_AnimalDog_C = "-" }
local U = { FamCache = {} }
local H = { STATIC_T = { "BP_MasterTurret_C", "BP_BanditTurret_AI_C", "BP_SurvivorTurret_AI_C" },
            HORDES = { "BP_Zombie_Infected_Horde_C", "BP_ZombieBossHorde_Infestation_C", "BP_ZombieBossHorde_Military_C",
                       "BP_ZombieBossHorde_Military_Small_C" } }
local C = { GHOSTS = { "BP_MasterTurret_C", "BP_BanditTurret_AI_C", "BP_SurvivorTurret_AI_C", "BP_AIManager_C",
                       "BP_AISpawner_Master_C", "BP_AISpawner_Zombies_C", "BP_AISpawner_Animals_C",
                       "BP_AISpawner_ZombieHounds_C", "BP_Infestation_C", "BP_QuestGiver_C" } }

-- ---------------------------------------------------------------- Hilfen

function U.Log(Fmt, ...) A.Log("[KI] " .. Fmt, ...) end

function U.On(Flag) return Core.Flag(Flag, true) == true end

function U.Name(Obj)
    return A.Safe(function() return Obj:GetFName():ToString() end)
end

-- Familie und Klassenname (Cache je Klassenname, Hochlaufen ueber GetSuperStruct nur beim ersten Mal)
function U.Fam(Obj)
    local Cls = A.Safe(function() return Obj:GetClass() end)
    local CN = Cls and A.Safe(function() return Cls:GetFName():ToString() end)
    if not CN then return nil end
    local Hit = U.FamCache[CN]
    if Hit ~= nil then return Hit or nil, CN end
    local Fam, S = false, Cls
    for _ = 1, 16 do
        local SN = A.Safe(function() return S:GetFName():ToString() end)
        if not SN then break end
        if FAM_ROOT[SN] then Fam = FAM_ROOT[SN] break end
        S = A.Safe(function() return S:GetSuperStruct() end)
        if not (S and A.IsAlive(S)) then break end
    end
    if Fam == "-" then Fam = false end
    U.FamCache[CN] = Fam
    return Fam or nil, CN
end

-- Lage als drei Zahlen (keine Struct-Objekte merken). Actor bei ~0,0,0 (Kapsel weg) oder Mesh gewuenscht: Mesh-Lage
function U.Loc(Obj, PreferMesh)
    local L = (not PreferMesh) and A.Safe(function() return Obj:K2_GetActorLocation() end) or nil
    if not L or math.abs(L.X) + math.abs(L.Y) + math.abs(L.Z) < 1 then
        local Mesh = A.Safe(function() return Obj.Mesh end)
        if A.IsAlive(Mesh) then L = A.Safe(function() return Mesh:K2_GetComponentLocation() end) or L end
    end
    if not L then return nil end
    return L.X, L.Y, L.Z
end

function U.WasLoaded(Obj)
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    return WL ~= nil and A.Safe(function() return Obj:HasAnyFlags(WL) end, false) == true
end

function U.Path(Obj)
    local Full = A.Safe(function() return Obj:GetFullName() end)
    return Full and Full:match("^%S+%s+(.+)$")
end

function U.IsDead(E) return E.Fl % 2 == 1 end
function U.IsLooted(E) return (E.Fl // 2) % 2 == 1 end

-- Blutmond. UE 5.6: SetBloodMoon @003c/@0157 = UDS Add/Remove(Sky-Modifier BloodMoon, 10 s Blende): an = Modifier in
-- 'Current Modifiers' mit 'Modifier Targets' > 0,5 (Remove setzt das Ziel sofort auf 0, Add auf 1). Ohne das Asset
-- (UE 5.3): Mondfarbe (Moon Material Color 0.19/0.04/0.04, normal 0.49/0.58/0.86).
U.BM_MOD = "/Game/UltraDynamicSky/Blueprints/Sky_Modifiers/BloodMoon.BloodMoon"
function U.BloodOf(UDS)
    if not A.IsAlive(UDS) then return nil end
    local Mod = A.Safe(function() return StaticFindObject(U.BM_MOD) end)
    if A.IsAlive(Mod) then
        local Addr = A.Safe(function() return Mod:GetAddress() end)
        local Mods = A.Safe(function() return UDS["Current Modifiers"] end)
        if Addr and Mods ~= nil then
            local Pos, I = nil, 0
            local okM = pcall(function() Mods:ForEach(function(_, E)
                I = I + 1
                local O = not Pos and E:get() or nil
                if O and A.IsAlive(O) and O:GetAddress() == Addr then Pos = I end
            end) end)
            if okM then
                if not Pos then return false end
                local Tgt, J = nil, 0
                pcall(function() UDS["Modifier Targets"]:ForEach(function(_, E)
                    J = J + 1
                    if J == Pos then Tgt = tonumber(E:get()) end
                end) end)
                return Tgt == nil or Tgt > 0.5
            end
        end
    end
    return A.Safe(function()
        local Col = UDS["Moon Material Color"]
        return Col.R > 0.12 and Col.G < 0.1 and Col.B < 0.1
    end)
end

-- Gepluendert-Flag: UE 5.6 BP_MasterZombie_C 'Looted?' (@31ea), sonst 'Looted' (Boss, Menschen, Tiere, UE-5.3-Zombie)
function U.LootedOf(Obj, Fam)
    if Fam == "z" and A.Safe(function() return Obj["Looted?"] == true end, false) == true then return true end
    return A.Safe(function() return Obj.Looted == true end, false) == true
end

function U.SetLooted(Obj, Fam)
    local P = "Looted"
    if Fam == "z" and type(A.Safe(function() return Obj["Looted?"] end)) == "boolean" then P = "Looted?" end
    pcall(function() if Obj[P] ~= true then Obj[P] = true end end)
end

-- Weltwechsel/Kartenladen: true = diesen Durchlauf nichts tun
function U.Busy(T)
    local WG = A.WorldGen or {}
    if WG.Loading and os.clock() - (WG.LoadingAt or 0) < 60 then return true end
    if T.Gen ~= WG.N then
        T.Gen = WG.N
        T.Reset()
        return true
    end
    return false
end

-- ls_native zur Laufzeit (nie beim Laden cachen; fehlt das Modul, laufen die Lua-Wege)
function U.Native()
    local ok, N = pcall(require, "ls_native")
    return (ok and type(N) == "table") and N or nil
end

-- N6 scharf: ls_native meldet ai_nearest=1 (nur mit geschriebener Liste) und die DLL ist installiert. Dann loest die DLL
-- GetPlayerCharacter(0) der Wellen-/Spawn-Kontexte selbst auf (Lua-Rueckfaelle bleiben aus).
function U.N6On()
    local N = U.Native()
    if not (N and type(N.NearestMode) == "function" and type(N.Status) == "function") then return false end
    if A.Safe(function() return N.NearestMode() end) ~= "1" then return false end
    local S = A.Safe(function() return N.Status() end)
    return type(S) == "table" and S.installed == 1 and S.broken ~= 1
end

-- ---------------------------------------------------------------- Host

function H.Reset()
    H.Ent, H.Sent, H.Mon, H.Ids, H.Rep, H.Perc, H.Dead, H.Woke = {}, {}, {}, {}, {}, {}, {}, {}
    H.Tick, H.NextId, H.Slow, H.StaticI, H.BM = 0, 0, 0, 0, nil
    H.MeatQ, H.MeatDone, H.MeatRep, H.MeatDoneN = {}, {}, {}, 0
    H.TDisL = nil   -- Geschuetz-Liste (ai_tdis) nach Weltwechsel verwerfen
    -- Runde 9: Wellen-Ziel (AI-2), letzte Gast-Figur (AI-3), Adress-/Pfad-Caches (AI-8, CORE-31), Boss-Stein (AI-11)
    H.LockSeen, H.LockN, H.LastPawn, H.AddrC, H.StaticC, H.SkyPath = {}, 0, {}, {}, {}, nil
    H.RockUntil, H.RockMon, H.RockDone = 0, {}, {}
end

-- CORE-31 (ai_perf): Familie/Klasse/Name je Objekt-Adresse (je Welt; H.Reset). Ausser im 1-Hz-Durchlauf nur der Cache
-- (nil = unbekannt -> der Aufrufer laesst die Figur bis zum naechsten 1-Hz-Durchlauf aus). Im 1-Hz-Durchlauf den Namen
-- neu vergleichen: Adresse nach GC neu vergeben -> Familie neu bestimmen.
function H.Ident(Obj, Full)
    local Addr = A.Safe(function() return Obj:GetAddress() end)
    local E = Addr and H.AddrC[Addr]
    if not Full then return E end
    local Name = U.Name(Obj)
    if E and Name and E.Name == Name then
        E.T = H.Tick
        return E
    end
    local Fam, Cls = U.Fam(Obj)
    E = { Fam = Fam, Cls = Cls, Name = Name, T = H.Tick }
    if Addr then H.AddrC[Addr] = E end
    return E
end

-- ai_locktarget (AI-2): Beacon (@09ae-0a2d) und Befall (@0275-02f4) setzen ihrer Wellen-KI SetBB_LockOnTarget(Lage von
-- GetPlayerCharacter(0)) = Geist am Server-Anker -> die Welle laeuft weg, EnemyDefeatedCheck wird nie erfuellt.
-- Rueckfall ohne N6 (dedizierter Server): neue KI der ersten 15 s mit Behaviour 3 und MoveToLocation am Geist auf die
-- Lage des naechsten Gasts umlenken (SetBB_Location, Behaviour 3 bleibt wie im SP).
function H.GhostLoc()
    local PC = A.LocalPC and A.Safe(function() return A.LocalPC() end) or nil
    local Pawn = A.IsAlive(PC) and A.Safe(function() return PC:K2_GetPawn() end) or nil
    local L = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    return L and { X = L.X, Y = L.Y, Z = L.Z } or nil
end

function H.LockFix(Obj, Name, X, Y, Guests, GL)
    local T0, Now = H.LockSeen[Name], os.clock()
    if T0 == false then return end
    if not T0 then H.LockSeen[Name] = Now return end
    if Now - T0 > 15 then H.LockSeen[Name] = false return end
    local AC = A.Safe(function() return Obj.SD_AIComponent end)   -- props: MasterZombie/Boss 0x670, Animal 0x668
    if not A.IsAlive(AC) or A.Safe(function() return AC.Behaviour end) ~= 3 then return end
    local Ctrl = A.Safe(function() return Obj:GetController() end)
    local BB = A.IsAlive(Ctrl) and A.Safe(function() return Ctrl.Blackboard end) or nil
    if not A.IsAlive(BB) then return end
    local V = A.Safe(function() return BB:GetValueAsVector(FName("MoveToLocation")) end)
    local VX, VY = V and tonumber(A.Safe(function() return V.X end)), V and tonumber(A.Safe(function() return V.Y end))
    if not (VX and VY) or (VX - GL.X) ^ 2 + (VY - GL.Y) ^ 2 > 300 * 300 then H.LockSeen[Name] = false return end
    local Best, BD
    for _, G in ipairs(Guests) do
        local D = (G.X - X) ^ 2 + (G.Y - Y) ^ 2
        if not Best or D < BD then Best, BD = G, D end
    end
    if Best and pcall(function() AC:SetBB_Location({ X = Best.X, Y = Best.Y, Z = Best.Z }) end) then
        H.LockSeen[Name] = false
        H.LockN = (H.LockN or 0) + 1
        if H.LockN <= 10 or H.LockN % 50 == 0 then
            U.Log("Wellen-KI %s zielte auf den Geist: auf Gast-Lage umgelenkt (%d)", Name, H.LockN)
        end
    end
end

-- Gaeste mit Cap ai2 und lebender Figur (Objekte nur fuer diesen Durchlauf)
function H.GuestList()
    local List = {}
    Net.ForEachGuest(function(G, Key)
        if not (G.Epoch and Net.Has("ai2", G)) then return end
        local PC = Net.PC(G)
        local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
        if not A.IsAlive(Pawn) then return end
        local L = A.Safe(function() return Pawn:K2_GetActorLocation() end)
        if not L then return end
        H.Sent[Key] = H.Sent[Key] or {}
        List[#List + 1] = { G = G, Key = Key, X = L.X, Y = L.Y, Z = L.Z, Anim = Net.Has("anim3", G) and U.On(F.ANIM),
                            Pawn = U.Name(Pawn) }
    end)
    return List
end

-- Schluessel: Karten-Actor "m<FName>" (Name auf Host und Gast gleich), sonst die Host-Id aus Z.NetIdFor (wie zlook2)
function H.KeyFor(Obj, Name)
    if U.WasLoaded(Obj) then return "m" .. Name end
    local Z = A.Z
    if Z and Z.NetIdFor then
        local Id = A.Safe(function() return Z.NetIdFor(Obj, Name) end)
        if Id then return tostring(Id) end
    end
    local Id = H.Ids[Name]
    if not Id then H.NextId = H.NextId + 1 Id = 900000 + H.NextId H.Ids[Name] = Id end
    return tostring(Id)
end

function H.Read(Obj, Fam, E)
    local Hp, Max, Beh, Dead, Looted = 0, 0, 0, false, false
    if Fam == "z" or Fam == "b" then
        local DC = Obj.DamageComponent
        if not A.IsAlive(DC) then return nil end
        Hp, Max, Dead = DC.CurrentHealth, DC.StandardHealthValue, Obj["IsDead?"] == true
        -- ai_looted: Looted?/Looted setzt das Spiel nur gastlokal (UE 5.6 MasterZombie @31ea 'Looted?', Boss @12dd
        -- 'Looted'); beim Host setzt es ls_inv I.MarkLooted
        if Dead and U.On(F.LOOTED) then Looted = U.LootedOf(Obj, Fam) end
    elseif Fam == "h" then
        local AC = Obj.BP_AIComponent
        if not A.IsAlive(AC) then return nil end
        Hp, Max, Dead, Beh = AC.Health, AC.MaxHealth, AC.Dead == true, AC["AI Current Behaviour"]
        -- ai_looted: UE 5.6 MasterBandit @1019 / MasterCoyoteSoldier @1018 (nur gastlokal), Host-Wert aus ls_inv I.MarkLooted
        if Dead and U.On(F.LOOTED) then Looted = U.LootedOf(Obj, Fam) end
    elseif Fam == "a" then
        Hp, Dead = Obj.Health, Obj["IsDead?"] == true
        Looted = A.Safe(function() return Obj.Looted == true end, false)
        E.MaxSeen = math.max(E.MaxSeen or 0, tonumber(Hp) or 0)
        Max = E.MaxSeen
    elseif Fam == "t" then
        local TC = Obj.BP_TurretAIComponent
        if not A.IsAlive(TC) then return nil end
        Hp, Max, Dead, Beh = TC["Current Health"], TC["Max Health"], TC.Dead == true, TC["Current Ammo"]
    elseif Fam == "n" then
        local DC = Obj.DamageComponent
        if not A.IsAlive(DC) then return nil end
        Hp, Max, Dead = DC.CurrentHealth, DC.StandardHealthValue, Obj["IsDestroyed?"] == true
    end
    return tonumber(Hp) or 0, tonumber(Max) or 0, math.floor(tonumber(Beh) or 0), Dead, Looted
end

-- CORE-28 (E6): Inventar-Komponente wurde hier adressierbar -> ls_inv merkt den Zeitpunkt fuer die Prime-Regel
-- (inv_prime_strict: keine zweite Container-Datenantwort fuer laengst adressierbare Container). Laufzeit-Lookup.
function U.MarkAddr(Obj)
    local Inv = A.Coop and A.Coop.Inv
    if type(Inv) ~= "table" or type(Inv.MarkAddr) ~= "function" then return end
    local Full = U.Path(Obj)
    if Full then pcall(Inv.MarkAddr, Full) end
end

-- Tier stirbt beim Host: Kadaver-Inventar netzadressierbar machen (WP9.6)
function H.OnAnimalDeath(Obj, Name)
    if H.Rep[Name] or not U.On(F.LOOTREP) then return end
    H.Rep[Name] = true
    local Jig = A.Safe(function() return Obj.BP_JigMultiplayer end)
    local ok = A.IsAlive(Jig) and pcall(function() Jig:SetIsReplicated(true) end)
    if ok then U.MarkAddr(Obj) end
    pcall(function() Obj:ForceNetUpdate() end)
    U.Log("Tier %s tot: Kadaver-Inventar repliziert (%s)", Name, ok and "ok" or "Fehler")
    H.CarcFix[Name], H.CarcPath[Name] = os.clock() + 60, U.Path(Obj)
end

-- Host: Beim Ragdoll loest sich das Mesh von der Kapsel; der Actor-Ursprung blieb im Test bei 0,0,0 (Test 22.10.).
-- Dann ist der Kadaver fuer die Netz-Relevanz und die Interaktions-Distanz (JigCanInteract/RequestServerData)
-- kilometerweit weg: kein Loot. 60 s lang jede Sekunde den Ursprung auf das Mesh ziehen (Teleport, ohne Sweep).
-- Leistung (ai_carcfix_path): Kadaver ueber den beim Tod gemerkten Pfad holen (StaticFindObject je Eintrag) statt
-- FindAllOf("BP_Animal_C") jede Sekunde (kostete am Server ~18 ms je Lauf = Ruckler alle 1 s bei den Gaesten).
-- Nicht mehr auffindbar = Kadaver weg -> Eintrag loeschen. 0 = alter Weg (FindAllOf).
function H.CarcList()
    if not U.On("ai_carcfix_path") then return FindAllOf("BP_Animal_C") or {} end
    local List = {}
    for Name in pairs(H.CarcFix) do
        local Path = H.CarcPath[Name]
        local O = Path and A.Safe(function() return StaticFindObject(Path) end)
        if A.IsAlive(O) then List[#List + 1] = O
        else H.CarcFix[Name], H.CarcPath[Name], H.CarcLogged[Name] = nil, nil, nil end
    end
    return List
end

function H.CarcFixTick()
    if not next(H.CarcFix) then return end
    local Now = os.clock()
    for _, Obj in ipairs(H.CarcList()) do
        local Name = A.IsAlive(Obj) and A.Safe(function() return Obj:GetFName():ToString() end)
        local Until = Name and H.CarcFix[Name]
        if Until then
            local Mesh = A.Safe(function() return Obj.Mesh end)
            local ML = A.IsAlive(Mesh) and A.Safe(function() return Mesh:K2_GetComponentLocation() end)
            local AL = A.Safe(function() return Obj:K2_GetActorLocation() end)
            if ML and AL and ((ML.X - AL.X) ^ 2 + (ML.Y - AL.Y) ^ 2 + (ML.Z - AL.Z) ^ 2) > 150 * 150 then
                local ok, Ret = pcall(function()
                    return Obj:K2_SetActorLocation({ X = ML.X, Y = ML.Y, Z = ML.Z + 20 }, false, {}, true)
                end)
                -- AI-13: ohne RootComponent (Tier-Tod zerstoert die Kapsel, z. B. Hirsch @072a) bewegt sich nichts; ok war
                -- nur der pcall-Erfolg. Lage nachpruefen; wirkungslos -> einmal melden und fuer diesen Kadaver aufhoeren
                -- (die Relevanz regelt main.lua Corpse.HostRelevance)
                local NL = ok and A.Safe(function() return Obj:K2_GetActorLocation() end) or nil
                local Moved = NL ~= nil and Ret ~= false and (NL.X - ML.X) ^ 2 + (NL.Y - ML.Y) ^ 2 <= 150 * 150
                if not Moved then
                    U.Log("Kadaver %s: Wurzel fehlt, Ursprung %.0f m vom Mesh nicht verschiebbar - keine weiteren Versuche",
                        Name, math.sqrt((ML.X - AL.X) ^ 2 + (ML.Y - AL.Y) ^ 2) / 100)
                    H.CarcFix[Name], H.CarcPath[Name], H.CarcLogged[Name] = nil, nil, nil
                else
                    if not H.CarcLogged[Name] then
                        H.CarcLogged[Name] = true
                        U.Log("Kadaver %s: Ursprung %.0f m vom Mesh, auf das Mesh gesetzt (ok)", Name,
                            math.sqrt((ML.X - AL.X) ^ 2 + (ML.Y - AL.Y) ^ 2) / 100)
                    end
                    pcall(function() Obj:ForceNetUpdate() end)
                end
            end
        end
    end
    for Name, Until in pairs(H.CarcFix) do if Now > Until then H.CarcFix[Name], H.CarcPath[Name], H.CarcLogged[Name] = nil, nil, nil end end
end
H.CarcFix, H.CarcPath, H.CarcLogged = {}, {}, {}

-- Huntsman-Fleischkiste (Fixplan #15). UE 5.3: Das Spiel prueft im Tier-Tod (Baer Death @0075, Hase @06b6, Hirsch @0841,
-- Wolf @07fd) GetSkillTreeManager = Spieler 0 (Host/Geist) und spawnt Container_AnimalMeat_C nur beim Host, ohne
-- Replikation (Laufzeit-Actor, ls_inv MakeAddr lehnt ihn ab). Host: Kill durch einen Gast mit Skill_Huntsman (Server-
-- Kopie seines TechTree, von ls_world w_tech gepflegt) -> nach DELAY s (die Spiel-Kiste kommt nach Delay(0) zuerst)
-- selbst spawnen, falls keine Kiste am Kadaver liegt; jede Host-Kiste nahe einem Gast replizieren (Actor + Jig).
-- 'Skip' (SetBoolPropertyByName im Spiel) trifft keine Eigenschaft (nur 'Skip Save?' existiert): wie das Spiel nichts setzen.
-- UE 5.6: Container_AnimalMeat_C gibt es nicht mehr. Der Tier-Tod legt das Fleisch direkt ins Kadaver-Inventar (Baer
-- Death @0075/@0106, Hirsch UB @074c/@07dd, Wolf UB @0785/@07e8: DA_RawMeat 3-5; Hase UB @0652/@06b5: DA_SmallRawMeat
-- 2-4): GetSkillTreeManager (Spieler 0 = Geist) IsTechnologyUnlocked(Skill_Huntsman) -> self.BP_JigMultiplayer->
-- AddNewItemSomewhere(DA, N, null, 1, true, 'None', ...) (10 Parameter, neu: SpecificContainer). Host: dasselbe fuer den
-- Gast-Schuetzen mit Huntsman (H.MeatAddJig), Kadaver-Jig replizieren. Ohne die Kisten-Klasse laeuft nur dieser Weg.
H.MEAT = { CLS = "/Game/Inventory/Containers/Container_AnimalMeat.Container_AnimalMeat_C", BOX = "Container_AnimalMeat_C",
           SKILL = "/Game/Blueprints/SkillTree/Skills/Skill_Huntsman.Skill_Huntsman", SMALL = "BP_AnimalRabbit_C",
           DA = "/Game/Inventory/Items/DataAssets/Consumables/Hunger/Animals/DA_RawMeat.DA_RawMeat",
           DA_S = "/Game/Inventory/Items/DataAssets/Consumables/Hunger/Animals/DA_SmallRawMeat.DA_SmallRawMeat",
           DELAY = 2, NEAR = 300, GUEST = 5000, REP = 3000, HIT_TTL = 10 }
H.MeatQ, H.MeatDone, H.MeatRep, H.MeatDoneN, H.MeatWarn = {}, {}, {}, 0, {}

function H.MeatWarnOnce(Id, Fmt, ...)
    if H.MeatWarn[Id] then return end
    H.MeatWarn[Id] = true
    U.Log(Fmt, ...)
end

-- Schuetze: Gast mit dem letzten nativen Treffer (ls_combat cb_dmg, <= 10 s). Ohne native Zuordnung (Beobachter aus)
-- nur bei einem zuvor lebend gesehenen Tier: einziger Gast <= 50 m und die Host-Figur nicht in der Naehe.
function H.MeatShooter(Name, X, Y, Z, WasAlive, Guests)
    local Now = os.clock()
    local Combat = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_combat
    local CH = type(Combat) == "table" and type(Combat.H) == "table" and Combat.H or nil
    local Hit
    if A.Coop and type(A.Coop.CombatLastHit) == "function" then
        -- Vertrag ls_combat: Kopie {Key, T} oder nil (aelter als 10 s / unbekannt)
        Hit = A.Safe(function() return A.Coop.CombatLastHit(Name) end)
    elseif CH and type(CH.LastHit) == "table" then
        Hit = CH.LastHit[Name]   -- Rueckfall: aeltere ls_combat ohne Export
    end
    if type(Hit) == "table" and Now - (tonumber(Hit.T) or -100) <= H.MEAT.HIT_TTL and Hit.Key and Net.Guests[Hit.Key] then
        return Hit.Key, "Treffer"
    end
    if (CH and CH.NativeWatched) or not WasAlive then return nil end
    local R2, Only, N = H.MEAT.GUEST * H.MEAT.GUEST, nil, 0
    for _, G in ipairs(Guests or {}) do
        if (G.X - X) ^ 2 + (G.Y - Y) ^ 2 + (G.Z - Z) ^ 2 <= R2 then Only, N = G.Key, N + 1 end
    end
    if N ~= 1 then return nil end
    local PC = A.LocalPC and A.LocalPC()
    local Pawn = A.IsAlive(PC) and A.Safe(function() return PC:K2_GetPawn() end) or nil
    local HL = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    if HL and (HL.X - X) ^ 2 + (HL.Y - Y) ^ 2 + (HL.Z - Z) ^ 2 <= R2 then return nil end
    return Only, "einziger Gast"
end

-- Host, beim ersten Erkennen des Tier-Tods (Lage = Mesh, der Ursprung driftet nach dem Ragdoll)
function H.MeatQueue(Name, Cls, X, Y, Z, WasAlive, Guests, Obj)
    if Net.Side ~= "host" or not U.On(F.MEAT) or H.MeatQ[Name] or H.MeatDone[Name] then return end
    local Key, How = H.MeatShooter(Name, X, Y, Z, WasAlive, Guests)
    if not Key then return end
    H.MeatQ[Name] = { At = os.clock() + H.MEAT.DELAY, Key = Key, How = How, Small = Cls == H.MEAT.SMALL,
                      X = X, Y = Y, Z = Z, Path = Obj and U.Path(Obj) }
end

-- Actor + Jig-Komponente replizieren (nur Host-Kisten: beim Gast gibt es keine lokale Kopie, Geister entfernt C.MeatGhosts)
function H.MeatReplicate(Box)
    local okA = pcall(function() Box:SetReplicates(true) end)
    local Jig = A.Safe(function() return Box.BP_JigMultiplayer end)
    local okJ = A.IsAlive(Jig) and pcall(function() Jig:SetIsReplicated(true) end) or false
    if okJ then U.MarkAddr(Box) end
    pcall(function() Box:ForceNetUpdate() end)
    return okA and okJ
end

-- Server-Kopie des Gast-TechTree: Skill_Huntsman freigeschaltet? nil = nicht pruefbar (kein Baum/Asset)
function H.MeatHasSkill(G, OwnPC)
    local PC = OwnPC or Net.PC(G)
    local TT = A.IsAlive(PC) and A.Safe(function() return PC.TechTreeComponent end) or nil
    if not A.IsAlive(TT) then return nil end
    -- TechTreeManager-Methoden nur mit zugewiesenem Baum (nativ ohne Baum ungeprueft, wie ls_world W.TechTreeOf)
    local Tree = A.Safe(function() return TT.TechnologyTree end)
    if not A.IsAlive(Tree) then return nil end
    local Skill = A.Safe(function() return StaticFindObject(H.MEAT.SKILL) end)
    if not A.IsAlive(Skill) then return nil end
    return A.Safe(function() return TT:IsTechnologyUnlocked(Skill) end, false) == true
end

-- UE 5.6: Fleisch ins Kadaver-Inventar. Hat der Geist (Spieler 0) selbst Huntsman, hat das Spiel es schon getan.
function H.MeatAddJig(Name, Q, Who)
    local Own = A.LocalPC and A.Safe(function() return A.LocalPC() end) or nil
    if A.IsAlive(Own) and H.MeatHasSkill(nil, Own) == true then
        U.Log("Huntsman: Kadaver %s - Fleisch legt das Spiel selbst ab (Host hat Huntsman), fuer %s nichts extra", Name, Who)
        return
    end
    local O = Q.Path and A.Safe(function() return StaticFindObject(Q.Path) end) or nil
    if not A.IsAlive(O) then
        U.Log("Huntsman: Kadaver %s nicht mehr da - kein Fleisch fuer %s", Name, Who)
        return
    end
    local Jig = A.Safe(function() return O.BP_JigMultiplayer end)
    local DA = A.Safe(function() return StaticFindObject(Q.Small and H.MEAT.DA_S or H.MEAT.DA) end)
    if not (A.IsAlive(Jig) and A.IsAlive(DA)) then
        H.MeatWarnOnce("da", "Huntsman: Fleisch-Asset/Kadaver-Inventar nicht gefunden - kein Fleisch")
        return
    end
    local N = Q.Small and math.random(2, 4) or math.random(3, 5)
    local ok = pcall(function() Jig:AddNewItemSomewhere(DA, N, nil, 1, true, FName("None"), {}, {}, {}, {}) end)
    local okR = pcall(function() Jig:SetIsReplicated(true) end)
    if okR then U.MarkAddr(O) end
    pcall(function() O:ForceNetUpdate() end)
    U.Log("Huntsman: %d Fleisch fuer %s in Kadaver %s gelegt (%s, %s)", N, Who, Name, Q.How,
        ok and (okR and "repliziert" or "Replikation Fehler") or "Fehler")
end

function H.MeatSpawn(Name, Q, Boxes)
    local G = Net.Guests[Q.Key]
    if not (G and G.Epoch) then return end
    local Who = tostring(G.PawnName or G.PCName or Q.Key)
    local Has = H.MeatHasSkill(G)
    if Has == nil then
        H.MeatWarnOnce("tt" .. tostring(Q.Key), "Huntsman: Tech-Baum von %s beim Server nicht pruefbar - kein Fleisch", Who)
        return
    end
    if not Has then return end
    if not A.IsAlive(A.Safe(function() return StaticFindObject(H.MEAT.CLS) end)) then return H.MeatAddJig(Name, Q, Who) end
    local N2 = H.MEAT.NEAR * H.MEAT.NEAR
    for _, B in ipairs(Boxes) do
        local L = A.IsAlive(B) and A.Safe(function() return B:K2_GetActorLocation() end) or nil
        if L and (L.X - Q.X) ^ 2 + (L.Y - Q.Y) ^ 2 <= N2 and math.abs(L.Z - Q.Z) <= H.MEAT.NEAR then
            U.Log("Huntsman: Kadaver %s hat schon eine Fleischkiste (Spiel) - wird fuer %s repliziert", Name, Who)
            return
        end
    end
    local Cls = A.Safe(function() return StaticFindObject(H.MEAT.CLS) end)
    local World = A.CurrentWorld and A.Safe(function() return A.CurrentWorld() end) or nil
    if not (A.IsAlive(Cls) and A.IsAlive(World)) then
        H.MeatWarnOnce("cls", "Huntsman: Klasse Container_AnimalMeat_C/Welt nicht gefunden - keine Fleischkiste")
        return
    end
    -- wie das Spiel: BeginDeferredActorSpawnFromClass(.., 2 = AdjustIfPossibleButAlwaysSpawn, Owner null, 0),
    -- aber an der Mesh-Lage (Actor-Transform liegt nach dem Ragdoll oft bei 0,0,0); TraceForFloor legt sie ab
    local T = { Translation = { X = Q.X, Y = Q.Y, Z = Q.Z + 30 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Scale3D = { X = 1, Y = 1, Z = 1 } }
    local GS = A.UEHelpers.GetGameplayStatics()
    local Box = A.Safe(function() return GS:BeginDeferredActorSpawnFromClass(World, Cls, T, 2, nil, 0) end)
    if not A.IsAlive(Box) then
        U.Log("Huntsman: Fleischkiste fuer %s an %s nicht erzeugt (Spawn fehlgeschlagen)", Who, Name)
        return
    end
    if Q.Small then pcall(function() Box["SmallAnimal?"] = true end) end
    pcall(function() Box.ContainerName = FText("Animal Meat") end)
    local okF = pcall(function() GS:FinishSpawningActor(Box, T, 0) end)
    local okR = okF and A.IsAlive(Box) and H.MeatReplicate(Box) or false
    local BN = A.IsAlive(Box) and U.Name(Box) or nil
    if BN then H.MeatRep[BN] = true end
    U.Log("Huntsman: Fleischkiste fuer %s an %s erzeugt (%s, %s)", Who, Name, Q.How,
        okF and (okR and "repliziert" or "Replikation Fehler") or "Fehler")
end

-- Host 1 Hz: faellige Kisten spawnen; alle 2 s Host-Kisten nahe einem Gast replizieren (auch die des Spiels, Host mit Huntsman)
function H.MeatTick()
    if Net.Side ~= "host" or not U.On(F.MEAT) then return end
    local WG = A.WorldGen or {}
    if WG.Loading then return end
    -- AI-8: UE 5.6 hat keine Kistenklasse mehr -> ohne Klasse und ohne faellige Eintraege nichts tun (kein FindAllOf
    -- ins Leere alle 2 s, auch ohne Gaeste); FindAllOf erst nach der Gast-Pruefung
    local HasCls = A.IsAlive(A.Safe(function() return StaticFindObject(H.MEAT.CLS) end))
    if not HasCls and not next(H.MeatQ) then return end
    local Now = os.clock()
    local Due
    for Name, Q in pairs(H.MeatQ) do
        if Now >= Q.At then Due = Due or {} Due[Name] = Q end
    end
    H.MeatTickN = (H.MeatTickN or 0) + 1
    if not Due and H.MeatTickN % 2 ~= 0 then return end
    local Boxes
    if Due then
        Boxes = HasCls and (FindAllOf(H.MEAT.BOX) or {}) or {}
        for Name, Q in pairs(Due) do
            H.MeatQ[Name] = nil
            if H.MeatDoneN > 2000 then H.MeatDone, H.MeatDoneN = {}, 0 end
            H.MeatDone[Name], H.MeatDoneN = true, H.MeatDoneN + 1
            local ok, err = pcall(H.MeatSpawn, Name, Q, Boxes)
            if not ok then U.Log("Huntsman: Fehler bei %s: %s", Name, tostring(err)) end
        end
    end
    if not HasCls then return end
    local Guests = H.GuestList()
    if #Guests == 0 then return end
    Boxes = Boxes or FindAllOf(H.MEAT.BOX) or {}
    local R2 = H.MEAT.REP * H.MEAT.REP
    for _, B in ipairs(Boxes) do
        local BN = A.IsAlive(B) and U.Name(B) or nil
        if BN and not H.MeatRep[BN] and A.Safe(function() return B:HasAuthority() end, false) == true then
            local L = A.Safe(function() return B:K2_GetActorLocation() end)
            local Near = false
            for _, G in ipairs(Guests) do
                if L and (G.X - L.X) ^ 2 + (G.Y - L.Y) ^ 2 + (G.Z - L.Z) ^ 2 <= R2 then Near = true break end
            end
            if Near then
                H.MeatRep[BN] = true
                local Was = A.Safe(function() return B:GetIsReplicated() end, false) == true
                local ok = H.MeatReplicate(B)
                if not Was then U.Log("Fleischkiste %s fuer Gaeste repliziert (%s)", BN, ok and "ok" or "Fehler") end
            end
        end
    end
end

-- ai_wake_fast (AI-7): beim ersten Nah-Kontakt (<= 50 m, 3D) sofort wecken; main.lua WakeAINearGuests (1 Hz, 60 m)
-- greift erst bis zu 1 s spaeter (bis dahin Angriffs-Notifies/Knochen der Host-KI eingefroren). Originalwert ueber
-- A.Coop.WakeOrig an main.lua (Protokoll wie H.WakeCheck); H.Woke-Eintrag, damit H.WakeCheck den Wert zuruecknimmt,
-- falls die KI vor der Uebernahme durch main.lua wieder > 60 m weg ist. Rueckgabe true = erledigt.
function H.WakeNear(Obj, Name, X, Y, Z, Guests, Ctx)
    local R2, In = K.NEAR * K.NEAR, false
    for _, G in ipairs(Guests) do
        if (X - G.X) ^ 2 + (Y - G.Y) ^ 2 + (Z - G.Z) ^ 2 < R2 then In = true break end
    end
    if not In then return false end
    local Mesh = A.Safe(function() return Obj.Mesh end)
    if not A.IsAlive(Mesh) then return true end
    local Key = A.Safe(function() return Mesh:GetAddress() end)
    local Cur = tonumber(A.Safe(function() return Mesh.VisibilityBasedAnimTickOption end))
    if not (Key and Cur) then return true end
    if Cur ~= 0 then
        local W, CoopT = H.Woke[Name], A.Coop
        CoopT.WakeOrig = CoopT.WakeOrig or {}
        if CoopT.WakeOrig[Key] == nil then CoopT.WakeOrig[Key] = W and W.Orig or Cur end
        if not W then H.Woke[Name] = { Orig = Cur, Seen = Ctx.Tick } end
        pcall(function() Mesh.VisibilityBasedAnimTickOption = 0 end)
    end
    -- UE 5.6: OnOptimizationUpdate setzt Mesh-TickInterval 0.05-0.3 s (@3bc7/@3c8a) -> Sockets/Notifies stocken
    pcall(function() if Mesh:GetComponentTickInterval() > 0 then Mesh:SetComponentTickInterval(0) end end)
    return true
end

-- Fernkampf-KI ausserhalb des alten 60-m-Weckradius wecken, wenn ihr Ziel ein Gast ist (Anim-Notifies feuern sonst nicht).
-- Tiere nur mit Eintrag aus H.WakeNear (Uebergabe/Ruecknahme), sonst nicht zustaendig.
function H.WakeCheck(Obj, Name, Fam, MinD2, Ctx)
    if Fam ~= "h" and Fam ~= "z" and Fam ~= "b" and not H.Woke[Name] then return end
    local W = H.Woke[Name]
    local Mesh = A.Safe(function() return Obj.Mesh end)
    if not A.IsAlive(Mesh) then return end
    if MinD2 < K.WAKE_IN * K.WAKE_IN then
        -- WakeAINearGuests (main.lua) ist zustaendig: eigenen Wert zuruecksetzen, sie setzt ihn selbst
        if W then
            -- Uebergabe an WakeAINearGuests ohne Zuruecksetzen (lief main.lua in dieser Sekunde schon, bliebe der Zombie
            -- beim Host ungeweckt: kein Angriffs-Notify, eingefrorene Pose); Originalwert fuer main.lua hinterlegen
            local C, Key = A.Coop, A.Safe(function() return Mesh:GetAddress() end)
            if C and Key and Core.Flag("wake_v2", true) then
                C.WakeOrig = C.WakeOrig or {}
                C.WakeOrig[Key] = W.Orig
            else
                pcall(function() Mesh.VisibilityBasedAnimTickOption = W.Orig end)
            end
            H.Woke[Name] = nil
        end
        return
    end
    local Tgt, Hit
    if Fam == "h" then
        local AC = A.Safe(function() return Obj.BP_AIComponent end)
        Tgt = A.IsAlive(AC) and A.Safe(function() return AC["Attack Target"] end) or nil
    else
        -- Zombie/Boss: Ziel steht im Blackboard des BP_ZombieAIController_C (Schluessel 'AttackTarget');
        -- CurrentActor ist nur der Pluenderer der Leiche. Blackboard nicht lesbar: Combat-Flag als Ersatz.
        local Ctrl = A.Safe(function() return Obj:GetController() end)
        if A.IsAlive(Ctrl) then
            local BB = A.Safe(function() return Ctrl.Blackboard end)
            if A.IsAlive(BB) then
                Tgt = A.Safe(function() return BB:GetValueAsObject(FName("AttackTarget")) end)
            elseif A.Safe(function() return Ctrl.Combat == true end, false) == true then
                Hit = true
            end
        end
    end
    local TN = (not Hit) and A.IsAlive(Tgt) and U.Name(Tgt)
    Hit = Hit or (TN and Ctx.PawnNames[TN]) or false
    if Hit and not W then
        local Orig = A.Safe(function() return Mesh.VisibilityBasedAnimTickOption end)
        if pcall(function() Mesh.VisibilityBasedAnimTickOption = 0 end) then
            H.Woke[Name] = { Orig = tonumber(Orig) or 2, Seen = Ctx.Tick }
            -- ai_wake_fast (AI-7): auch den Optimizer-TickInterval aufheben (nur die Tick-Option reicht nicht)
            if U.On(F.WAKEF) then
                pcall(function() if Mesh:GetComponentTickInterval() > 0 then Mesh:SetComponentTickInterval(0) end end)
            end
        end
    elseif W and not Hit then
        pcall(function() Mesh.VisibilityBasedAnimTickOption = W.Orig end)
        H.Woke[Name] = nil
    elseif W then
        W.Seen = Ctx.Tick
    end
end

-- Montage-Relay ohne Hook: aktuelle Montage lesen, Wechsel (oder Neustart) an Gaeste in der Naehe
function H.MonCheck(Obj, Name, E, Guests, D2s)
    local Mesh = Obj.Mesh
    if not A.IsAlive(Mesh) then return end
    local Inst = Mesh:GetAnimInstance()
    if not A.IsAlive(Inst) then return end
    local Mon = Inst:GetCurrentActiveMontage()
    local Last = H.Mon[Name]
    if not A.IsAlive(Mon) then
        if Last then Last.Addr = nil end
        return
    end
    local Addr = Mon:GetAddress()
    local Pos = tonumber(A.Safe(function() return Inst:Montage_GetPosition(Mon) end, 0)) or 0
    if Last and Last.Addr == Addr and Pos >= (Last.Pos or 0) - 0.05 then Last.Pos = Pos return end
    H.Mon[Name] = { Addr = Addr, Pos = Pos }
    local Path = U.Path(Mon)
    if not Path then return end
    local Rate = tonumber(A.Safe(function() return Inst:Montage_GetPlayRate(Mon) end, 1)) or 1
    local Sec = A.Safe(function() return Inst:Montage_GetCurrentSection(Mon):ToString() end, "None") or "None"
    local Data = table.concat({ Net.Enc(E.Key), Net.Enc(Path), string.format("%.2f", Rate), Net.Enc(Sec),
                                string.format("%.2f", Pos) }, "|")
    for I, G in ipairs(Guests) do
        if D2s[I] < K.MON * K.MON and (E.Fam ~= "a" or G.Anim) then Net.Send("ai_mon", Data, G.G, 1) end
    end
end

-- ai_bossrock (AI-11, PLAUSIBLE): der Boss spawnt BP_ZombieBossRock_C (Actor + ProjectileMovement, ohne eigene
-- Schadenslogik) beim Notify 'Throw' der ZombieBossSlam-Montage (UB @08b0/@0b1e, Spawn @0bee, Launch @0ca8) nur beim
-- Host. Repliziert die Klasse nicht (CDO bReplicates, einmal geprueft), sehen Gaeste den Wurf nicht: waehrend der
-- Wurf-Montage 3 s lang (5 Hz) autoritative Steine replizieren (Actor + Bewegung). Klasse repliziert -> nichts tun.
H.ROCK = { CDO = "/Game/AI/Zombies/Boss/BP_ZombieBossRock.Default__BP_ZombieBossRock_C", CLS = "BP_ZombieBossRock_C",
           SECS = 3 }
function H.RockNeed()
    if H.ROCK.Need ~= nil then return H.ROCK.Need end
    local Now = os.clock()
    if Now < (H.ROCK.TryAt or 0) then return nil end
    H.ROCK.TryAt = Now + 10
    local Cdo = A.Safe(function() return StaticFindObject(H.ROCK.CDO) end)
    if not A.IsAlive(Cdo) then return nil end   -- Klasse noch nicht geladen
    local Rep = A.Safe(function() return Cdo.bReplicates end)
    if type(Rep) ~= "boolean" then return nil end
    H.ROCK.Need = not Rep
    U.Log("Boss-Stein: Klasse repliziert %s -> %s", tostring(Rep),
        H.ROCK.Need and "Host repliziert geworfene Steine" or "nichts zu tun")
    return H.ROCK.Need
end

-- Boss in Reichweite: laeuft die Wurf-Montage? (Montage-Adresse je Boss gemerkt, Pfad nur beim Wechsel)
function H.RockWatch(Obj, Name, Now)
    local Mesh = A.Safe(function() return Obj.Mesh end)
    local Inst = A.IsAlive(Mesh) and A.Safe(function() return Mesh:GetAnimInstance() end) or nil
    local Mon = A.IsAlive(Inst) and A.Safe(function() return Inst:GetCurrentActiveMontage() end) or nil
    local Addr = A.IsAlive(Mon) and A.Safe(function() return Mon:GetAddress() end) or nil
    if not Addr then
        H.RockMon[Name] = nil
        return
    end
    local R = H.RockMon[Name]
    if not R or R.Addr ~= Addr then
        local P = (U.Path(Mon) or ""):lower()
        R = { Addr = Addr, Throw = P:find("slam", 1, true) ~= nil or P:find("throw", 1, true) ~= nil }
        H.RockMon[Name] = R
    end
    if R.Throw then H.RockUntil = math.max(H.RockUntil, Now + H.ROCK.SECS) end
end

function H.RockStep()
    local N = 0
    for _, R in ipairs(FindAllOf(H.ROCK.CLS) or {}) do
        local RN = A.IsAlive(R) and U.Name(R) or nil
        if RN and not H.RockDone[RN] and A.Safe(function() return R:HasAuthority() end, false) == true then
            H.RockDone[RN] = true
            local ok = pcall(function() R:SetReplicates(true) end)
            pcall(function() R:SetReplicateMovement(true) end)
            pcall(function() R:ForceNetUpdate() end)
            N = N + 1
            H.RockN = (H.RockN or 0) + 1
            if H.RockN <= 5 or H.RockN % 50 == 0 then
                U.Log("Boss-Stein %s fuer Gaeste repliziert (%s, %d)", RN, ok and "ok" or "Fehler", H.RockN)
            end
        end
    end
    if N > 0 then
        local C2 = 0
        for _ in pairs(H.RockDone) do C2 = C2 + 1 end
        if C2 > 200 then H.RockDone = {} end
    end
end

-- Einen Actor auswerten: Wert bauen und je Gast (in Reichweite) als Sonderwert setzen, sonst loeschen
function H.Visit(Obj, Name, Fam, Cls, Guests, Full, Ctx)
    if Ctx.Visited[Name] then return end
    Ctx.Visited[Name] = true
    local Animal = Fam == "a"
    if Animal and not U.On(F.ANIM) then return end
    local E = H.Ent[Name]
    local X, Y, Z = U.Loc(Obj, Animal and E ~= nil and E.Dead)
    if not X then return end
    local MinD2, D2s = math.huge, {}
    for I, G in ipairs(Guests) do
        local D2 = (X - G.X) ^ 2 + (Y - G.Y) ^ 2
        D2s[I] = D2
        if D2 < MinD2 then MinD2 = D2 end
    end
    if Full and MinD2 < K.WAKE_FAR * K.WAKE_FAR and U.On(F.WAKE) then H.WakeCheck(Obj, Name, Fam, MinD2, Ctx) end
    if not E and MinD2 >= K.RANGE * K.RANGE then return end
    local Near = MinD2 < K.NEAR * K.NEAR
    if not E then
        E = { Fam = Fam, Cls = Cls, Key = H.KeyFor(Obj, Name), Static = Fam == "t" or Fam == "n" }
        H.Ent[Name] = E
    end
    E.Seen = Ctx.Tick
    -- ai_locktarget (AI-2): nur 1-Hz-Durchlauf, nur ohne N6 auf dem dedizierten Server (Ctx.GhostLoc)
    if Full and Ctx.GhostLoc and (Fam == "z" or Fam == "b" or Animal) and H.LockSeen[Name] ~= false then
        local okL, errL = pcall(H.LockFix, Obj, Name, X, Y, Guests, Ctx.GhostLoc)
        if not okL then Core.Fail(F.LOCK, errL) end
    end
    if not (Near or Full) then return end
    local Hp, Max, Beh, Dead, Looted = H.Read(Obj, Fam, E)
    if Hp == nil then return end
    if Dead and not E.Dead and Animal then
        local WasAlive = E.Dead == false
        H.OnAnimalDeath(Obj, Name)
        X, Y, Z = U.Loc(Obj, true)
        if not X then return end
        local okM, errM = pcall(H.MeatQueue, Name, Cls, X, Y, Z, WasAlive, Guests, Obj)
        if not okM then Core.Fail(F.MEAT, errM) end
    end
    E.Dead = Dead
    -- ai_wake_fast (AI-7): erster Nah-Kontakt lebender Zombies/Bosse/Tiere -> sofort wecken (Ruecknahme: H.WakeCheck)
    if Near and not Dead and not E.WakeF and (Fam == "z" or Fam == "b" or Animal) and U.On(F.WAKEF) and U.On(F.WAKE)
        and Core.Flag("wake_v2", true) then
        local okW, resW = pcall(H.WakeNear, Obj, Name, X, Y, Z, Guests, Ctx)
        if not okW then Core.Fail(F.WAKEF, resW) elseif resW then E.WakeF = true end
    elseif E.WakeF and not Near then
        E.WakeF = nil
    end
    -- Tote Zombies/Bosse/Menschen: IsDead?/Dead sind repliziert, nichts mehr senden (Schluessel loeschen)
    -- Ausnahme ai_looted: gepluenderte Leiche einmal mit Bit 2 melden (Gast setzt Looted?/Looted, 5.6 Label MasterZombie @3305/@374d)
    local Send = not (Dead and (Fam == "z" or Fam == "b" or Fam == "h")) or (Looted == true and U.On(F.LOOTED))
    local Val
    if Send then
        local Fl = (Dead and 1 or 0) + (Looted and 2 or 0) + (E.Key:sub(1, 1) == "m" and 4 or 0)
        Val = string.format("%s;%s;%d;%d;%d;%.1f;%.1f;%d;%d", Fam, Cls, math.floor(X / K.Q + 0.5),
            math.floor(Y / K.Q + 0.5), math.floor(Z / K.Q + 0.5), Hp, Max, Beh, Fl)
    end
    local R2 = K.RANGE * K.RANGE
    for I, G in ipairs(Guests) do
        local S = H.Sent[G.Key]
        if Send and D2s[I] < R2 and (not Animal or G.Anim) then
            Net.State("ai2", E.Key, Val, 1, G.G)
            S[E.Key] = true
        elseif S[E.Key] then
            Net.State("ai2", E.Key, nil, 1, G.G)
            S[E.Key] = nil
        end
    end
    -- bei keinem Gast mehr in Reichweite: Eintrag vergessen (kommt beim Naeherkommen neu)
    if MinD2 >= R2 then
        H.Ent[Name], H.Mon[Name] = nil, nil
        return
    end
    if Near and not Dead and (Fam == "z" or Fam == "b" or Animal) and MinD2 < K.MON * K.MON
        and Ctx.MonLeft > 0 and U.On(F.MON) then
        Ctx.MonLeft = Ctx.MonLeft - 1
        local ok, err = pcall(H.MonCheck, Obj, Name, E, Guests, D2s)
        if not ok then Core.Fail(F.MON, err) end
    end
    -- ai_bossrock (AI-11): lebender Boss in Reichweite eines Gasts, Steinklasse repliziert nicht von sich aus
    if Fam == "b" and not Dead and U.On(F.ROCK) and H.RockNeed() then
        local okR, errR = pcall(H.RockWatch, Obj, Name, os.clock())
        if not okR then Core.Fail(F.ROCK, errR) end
    end
end

-- Ein Geschuetz/Nest auswerten; Rueckgabe Name (nil = keine Familie t/n)
function H.StaticOne(Obj, Guests, Ctx)
    local Fam, CN = U.Fam(Obj)
    local Name = (Fam == "t" or Fam == "n") and U.Name(Obj)
    if not Name then return nil end
    local ok, err = pcall(H.Visit, Obj, Name, Fam, CN, Guests, true, Ctx)
    if not ok then Core.Fail("ai_visit", err) end
    return Name
end

-- Geschuetze und Nester (keine Characters). ai_perf aus: Nester jede Sekunde, Geschuetz-Klassen reihum (je 1 FindAllOf).
-- AI-8/CORE-31 (ai_perf): Pfadliste - Nester (Karten-Actors) alle 30 s per FindAllOf, Geschuetze (alle drei Klassen)
-- alle 5 s; dazwischen jede Sekunde StaticFindObject(Pfad) (Hash-Suche statt vollem Objekt-Scan). Bekannte Nester/
-- Geschuetze bleiben im 1-Hz-Takt, neue kommen nach hoechstens 30 s (Nest) bzw. 5 s (Geschuetz) dazu.
H.NEST_S, H.TUR_S = 30, 5
function H.StaticScan(Cls)
    for _, Obj in ipairs(FindAllOf(Cls) or {}) do
        local P = A.IsAlive(Obj) and U.Path(Obj) or nil
        if P then H.StaticC.Paths[P] = true end
    end
end

function H.Static(Guests, Ctx)
    if not U.On(F.PERF) then
        H.StaticI = H.StaticI % #H.STATIC_T + 1
        for _, Cls in ipairs({ "BP_Infestation_C", H.STATIC_T[H.StaticI] }) do
            for _, Obj in ipairs(FindAllOf(Cls) or {}) do
                if A.IsAlive(Obj) then H.StaticOne(Obj, Guests, Ctx) end
            end
        end
        return
    end
    local SC, Now = H.StaticC, os.clock()
    SC.Paths = SC.Paths or {}
    if Now >= (SC.NestAt or 0) then
        SC.NestAt = Now + H.NEST_S
        H.StaticScan("BP_Infestation_C")
    end
    if Now >= (SC.TurAt or 0) then
        SC.TurAt = Now + H.TUR_S
        for _, Cls in ipairs(H.STATIC_T) do H.StaticScan(Cls) end
    end
    for P in pairs(SC.Paths) do
        local Obj = A.Safe(function() return StaticFindObject(P) end)
        if not (A.IsAlive(Obj) and H.StaticOne(Obj, Guests, Ctx)) then SC.Paths[P] = nil end
    end
end

-- Verschwundene Actors: Schluessel bei allen Gaesten loeschen
function H.Prune(Tick)
    for Name, E in pairs(H.Ent) do
        if E.Seen < Tick - (E.Static and 25 or 10) then
            for GKey, S in pairs(H.Sent) do
                if S[E.Key] then Net.State("ai2", E.Key, nil, 1, GKey) S[E.Key] = nil end
            end
            H.Ent[Name], H.Mon[Name] = nil, nil
        end
    end
    for Name, W in pairs(H.Woke) do if (W.Seen or 0) < Tick - 25 then H.Woke[Name] = nil end end
    if Tick % 300 == 0 then
        for Name in pairs(H.Rep) do if not H.Ent[Name] then H.Rep[Name] = nil end end
        for Name in pairs(H.Ids) do if not H.Ent[Name] then H.Ids[Name] = nil end end
        for Name in pairs(H.Mon) do if not H.Ent[Name] then H.Mon[Name] = nil end end
        for Name in pairs(H.LockSeen) do if not H.Ent[Name] then H.LockSeen[Name] = nil end end
        for Addr, I in pairs(H.AddrC) do if (I.T or 0) < Tick - 300 then H.AddrC[Addr] = nil end end
        for Name in pairs(H.RockMon) do if not H.Ent[Name] then H.RockMon[Name] = nil end end
    end
end

-- 5 Hz: Zombies, Bosse, Menschen, Tiere aus der gemeinsamen Figuren-Liste; jede Sekunde alle (auch fern) + Statische
function H.Fast()
    if Net.Side ~= "host" or not U.On(F.AI) then return end
    if U.Busy(H) then return end
    local Guests = H.GuestList()
    if #Guests == 0 then return end
    H.Tick = H.Tick + 1
    local Full = H.Tick % 5 == 0
    local Ctx = { Tick = H.Tick, MonLeft = K.MAX_MON, PawnNames = {}, Visited = {} }
    for _, G in ipairs(Guests) do if G.Pawn then Ctx.PawnNames[G.Pawn] = true end end
    if Full and A.Coop and A.Coop.Server and U.On(F.LOCK) and not U.N6On() then Ctx.GhostLoc = H.GhostLoc() end
    local Perf = U.On(F.PERF)
    for _, Obj in ipairs(A.Characters() or {}) do
        if A.IsAlive(Obj) then
            local Fam, Cls, Name
            if Perf then
                -- CORE-31: Familie/Name aus dem Adress-Cache; ohne Eintrag in H.Ent (fern/neu) nur im 1-Hz-Durchlauf
                local I = H.Ident(Obj, Full)
                if I and I.Fam and I.Fam ~= "t" and I.Fam ~= "n" and I.Name and (Full or H.Ent[I.Name]) then
                    Fam, Cls, Name = I.Fam, I.Cls, I.Name
                end
            else
                Fam, Cls = U.Fam(Obj)
                Name = Fam and Fam ~= "t" and Fam ~= "n" and U.Name(Obj) or nil
            end
            if Name then
                local ok, err = pcall(H.Visit, Obj, Name, Fam, Cls, Guests, Full, Ctx)
                if not ok then Core.Fail("ai_visit", err) end
            end
        end
    end
    if H.RockUntil > os.clock() then
        local ok, err = pcall(H.RockStep)
        if not ok then Core.Fail(F.ROCK, err) end
    end
    if Full then
        H.Static(Guests, Ctx)
        H.Prune(H.Tick)
    end
end

-- Alle Gast-Figuren (auch ohne Cap; nie der Geist: der ist lokal) fuer Horde/Invoker.
-- ai_horde2 (AI-3): der Tod ruft im selben Aufruf GetPlayerController(0)->UnPossess (AfterDeath @0551-056b, beim Gast
-- dessen eigener PC) -> K2_GetPawn ist danach leer, die tote Figur stand nie mit Dead=true in der Liste und
-- H.KillHordes lief nie. Darum je Gast den Pfad der letzten Figur merken und die tote Figur (liegt noch) wiederfinden.
function H.LastPawnOf(Key)
    local Path = H.LastPawn[Key]
    if not (Path and U.On(F.HORDE2)) then return nil end
    local ok, Pawn = pcall(function() return StaticFindObject(Path) end)
    if not ok then
        Core.Fail(F.HORDE2, Pawn)
        return nil
    end
    return A.IsAlive(Pawn) and Pawn or nil
end

function H.GuestPawns()
    local List = {}
    Net.ForEachGuest(function(G, Key)
        local PC = Net.PC(G)
        local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
        local Own = A.IsAlive(Pawn)
        if Own then
            H.LastPawn[Key] = U.Path(Pawn)
        else
            Pawn = H.LastPawnOf(Key)
        end
        if not A.IsAlive(Pawn) then
            H.LastPawn[Key] = nil
            return
        end
        local Dead = A.Safe(function() return Pawn["PlayerDead?"] == true end, false) == true
        if not Own and not Dead then return end   -- gemerkte Figur lebt, gehoert aber nicht mehr dem Gast
        local L = A.Safe(function() return Pawn:K2_GetActorLocation() end)
        if not L then return end
        List[#List + 1] = { Key = Key, Pawn = Pawn, Name = U.Name(Pawn), X = L.X, Y = L.Y, Z = L.Z, Dead = Dead }
    end)
    return List
end

-- Lebt ein anderer Spieler (nicht P) im Radius R2 um X/Y? (Horden; der Beacon-Teil liegt in ls_build, BUILD-14)
function H.OtherAlive(X, Y, P, Pawns, R2)
    for _, Q in ipairs(Pawns) do
        if Q ~= P and not Q.Dead and (X - Q.X) ^ 2 + (Y - Q.Y) ^ 2 < R2 then return true end
    end
    return false
end

-- Horde: Event_PlayerDead haengt am Geist (Spieler 0). Bei Gast-Tod Horden in seiner Naehe beenden, wenn kein anderer
-- lebender Spieler naeher als HORDE steht. Listen-Host: Spieler 0 ist ein echter Spieler und zaehlt mit (H.HordeTick).
function H.KillHordes(P, Pawns)
    local R2, N = K.HORDE * K.HORDE, 0
    for _, Cls in ipairs(H.HORDES) do
        for _, Hd in ipairs(FindAllOf(Cls) or {}) do
            if N >= 60 then break end
            if A.IsAlive(Hd) and not A.Safe(function() return Hd["IsDead?"] == true end, false) then
                local X, Y = U.Loc(Hd)
                if X and (X - P.X) ^ 2 + (Y - P.Y) ^ 2 < R2 and not H.OtherAlive(X, Y, P, Pawns, R2)
                    and pcall(function() Hd:Event_PlayerDead() end) then
                    N = N + 1
                end
            end
        end
    end
    U.Log("Gast %s tot: %d Horden-Zombies beendet", P.Name or "?", N)
end

-- ai_horde2 (Review 3): auf dem Listen-Host (kein Coop.Server) ist der lokale Spieler kein Geist, sondern ein echter
-- Spieler; die Horde haengt nativ an ihm (EVT_ReceiveBeginPlay @010f-0154, CastToCharacter = Spieler 0). Darum zaehlt
-- er bei H.OtherAlive mit - sonst stirbt die Horde beim Gast-Tod, obwohl der Host daneben weiterkaempft.
-- Liste nur bei einem Todes-Uebergang bauen (1-Hz-Tick ohne zusaetzliche UObject-Aufrufe); InvokerTick/PercPrune
-- bekommen weiter die reine Gastliste.
function H.HordeOthers(Pawns)
    if A.Coop and A.Coop.Server then return Pawns end   -- dedizierter Server: Spieler 0 ist der Geist
    local Own = A.OwnPawn and A.Safe(A.OwnPawn) or nil
    local L = A.IsAlive(Own)
        and A.Safe(function() return Own["PlayerDead?"] ~= true and Own:K2_GetActorLocation() end) or nil
    if not L then return Pawns end
    local Others = {}
    for I, Q in ipairs(Pawns) do Others[I] = Q end
    Others[#Others + 1] = { Key = "host", X = L.X, Y = L.Y, Z = L.Z, Dead = false }
    return Others
end

function H.HordeTick(Pawns)
    local Others
    for _, P in ipairs(Pawns) do
        local Was = H.Dead[P.Key]
        H.Dead[P.Key] = P.Dead
        if P.Dead and Was == false then
            if not Others then Others = U.On(F.HORDE2) and H.HordeOthers(Pawns) or Pawns end
            H.KillHordes(P, Others)
        end
    end
end

-- Gast-Figuren: AI-Optimizer-Invoker (KI spawnt/denkt bei ihnen) und Sicht-Quelle (Tiere fliehen/greifen an)
function H.InvokerTick(Pawns)
    local Sub = FindFirstOf("AIOptimizerSubsystem")
    local Sight = StaticFindObject("/Script/AIModule.AISense_Sight")
    for _, P in ipairs(Pawns) do
        if not P.Dead and A.IsAlive(P.Pawn) then
            local Inv = A.Safe(function() return P.Pawn.AIOInvoker end)
            if A.IsAlive(Sub) and A.IsAlive(Inv) then
                local Idx = A.Safe(function() return Sub:GetInvokerIndex(Inv) end)
                if type(Idx) == "number" and Idx < 0 and pcall(function() Sub:RegisterInvoker(Inv) end) then
                    U.Log("Invoker fuer Gast-Figur %s angemeldet", P.Name or "?")
                end
            end
            if P.Name and not H.Perc[P.Name] and A.IsAlive(Sight) then
                local Src = A.Safe(function() return P.Pawn.AIPerceptionStimuliSource end)
                if A.IsAlive(Src) then
                    H.Perc[P.Name] = true
                    pcall(function() Src:RegisterWithPerceptionSystem() end)
                    local ok = pcall(function() Src:RegisterForSense(Sight) end)
                    U.Log("Gast-Figur %s als Sicht-Quelle %s", P.Name, ok and "angemeldet" or "nicht angemeldet")
                end
            end
        end
    end
end

-- ai_ghost_days (AI-5 Stufe 1, nur dedizierter Server, alle 10 s): ScalingDamage-/ScalingHealthMultiplier
-- (GameFunctionLibrary @0061-042f) und BP_EventManager lesen DaysSurvived von Spieler 0 = Geist. Der zaehlt jede
-- Mitternacht weiter (Tage des Servers statt der Spieler). Geist-Tage = Median der verbundenen Gaeste; nur dieses
-- Feld schreiben (wie main.lua OnMidnight fuer Gaeste), NIE CurrentLevel/MaxXP (stuerzte nativ ab, ls_combat).
-- Stufe 2 (Stufen-Anteil) sind die N6-Funktionseintraege (DLL/ls_native).
function H.GhostDays()
    local Ghost = A.LocalPC and A.Safe(function() return A.LocalPC() end) or nil
    if not A.IsAlive(Ghost) then return end
    local D = {}
    Net.ForEachGuest(function(G)
        if not G.Epoch then return end
        local PC = Net.PC(G)
        local V = PC and tonumber(A.Safe(function() return PC.DaysSurvived end))
        if V and V >= 1 then D[#D + 1] = V end   -- 0 = Werte des Gasts noch nicht geladen
    end)
    if #D == 0 then return end
    table.sort(D)
    local Want = math.max(1, math.floor(D[math.floor((#D + 1) / 2)]))
    local Cur = tonumber(A.Safe(function() return Ghost.DaysSurvived end))
    if Cur == nil or Cur == Want then return end
    if pcall(function() Ghost.DaysSurvived = Want end) and Want ~= H.GDaysLog then
        H.GDaysLog = Want
        U.Log("Geist-Tage fuer die KI-Skalierung: %d -> %d (Median von %d Gast/Gaesten)", Cur, Want, #D)
    end
end

-- CORE-30: Sicht-Quellen-Merker (Figurennamen, jeder Respawn ein neuer) auf die aktuellen Gast-Figuren kuerzen
function H.PercPrune(Pawns)
    local Live = {}
    for _, P in ipairs(Pawns) do if P.Name then Live[P.Name] = true end end
    for Name in pairs(H.Perc) do if not Live[Name] then H.Perc[Name] = nil end end
end

-- ai_hitdiag (AI-7): Wie oft schlagen Zombies beim Host zu, wie oft trifft der Schlag ("hauen vorbei")? Ohne Lua-Hook:
-- benannte DLL-Beobachtung beim Eintritt (N4b at=entry) von AttackPlayer (Angriff) und Event_OnHit (AttackTrace @036c,
-- nur bei Treffer). Zaehlen im 1-Hz-Takt (eigener Cursor), Log einmal je Minute, wenn Gaeste da sind.
H.HD = { ATK = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:AttackPlayer",
         HIT = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:Event_OnHit", Atk = 0, Hit = 0 }
function H.HitDiag(Now, NGuests)
    local N = U.Native()
    local Want = N and U.On(F.HITDIAG) and type(N.Watch) == "function" and type(N.Events) == "function"
    if not Want then
        if H.HD.On and N and type(N.SetWatch) == "function" then
            pcall(N.SetWatch, nil, "@ai_atk")
            pcall(N.SetWatch, nil, "@ai_hit")
            U.Log("KI-Treffer-Diagnose aus")
        end
        H.HD.On = false
        return
    end
    if not H.HD.On then
        if Now < (H.HD.TryAt or 0) then return end
        H.HD.TryAt = Now + 30
        N.Watch("ai_atk", H.HD.ATK, "at=entry")
        N.Watch("ai_hit", H.HD.HIT, "at=entry")
        N.Events("_ls_ai")   -- Cursor setzen: aeltere Ereignisse nicht mitzaehlen
        H.HD.On, H.HD.LogAt, H.HD.Atk, H.HD.Hit = true, Now + 60, 0, 0
        U.Log("KI-Treffer-Diagnose an (DLL-Beobachtung AttackPlayer/Event_OnHit, Log je Minute mit Gaesten)")
        return
    end
    local List = N.Events("_ls_ai")
    for _, Ev in ipairs(type(List) == "table" and List or {}) do
        if Ev.Tag == "ai_atk" then H.HD.Atk = H.HD.Atk + 1 elseif Ev.Tag == "ai_hit" then H.HD.Hit = H.HD.Hit + 1 end
    end
    if Now < (H.HD.LogAt or 0) then return end
    H.HD.LogAt = Now + 60
    if NGuests > 0 and H.HD.Atk + H.HD.Hit > 0 then
        U.Log("KI-Treffer (Zombies, 60 s): %d Angriffe, %d Treffer (%.0f %%)", H.HD.Atk, H.HD.Hit,
            H.HD.Atk > 0 and 100 * H.HD.Hit / H.HD.Atk or 0)
    end
    H.HD.Atk, H.HD.Hit = 0, 0
end

function H.BloodTick()
    local On = U.BloodOf(U.FindCached(H, "SkyPath", "Ultra_Dynamic_Sky_C"))
    if On == nil then return end
    Net.State("ai_bm", "m", On and "1" or "0", 2)
    if On ~= H.BM then
        if H.BM ~= nil or On then U.Log("Blutmond beim Host: %s", On and "an" or "aus") end
        H.BM = On
    end
end

-- Geschuetz deaktivieren (ai_tdis, Runde 8; UE 5.6 neu verifiziert). Befund BP_BanditTurret_AI_C (5.6): OnServer-
-- ExecuteInteract @04b6 leer; der Gast prueft lokal GetBehindObject? @12c2 -> @0e34/@0ca0 IsHeld -> Retriggerable-
-- Delay(Duration) @03e1 -> L_001f (0x1f = 31: JumpIfNot IsHeld -> @0337, Dead @0038, Can Attack @0059, Waffen-Pickup
-- +175 z @0180/@025d, Turret:K2_DestroyComponent @0315) - alles nur gastlokal, das Host-Geschuetz schiesst weiter.
-- Host: gleiche Bedingung, Owner-Trick, IsHeld = true + UB-Einsprung 31 (L_001f) = exakt der SP-Schwanz auf dem Host
-- (inkl. Server-Pickup), danach Pickup replizieren und ai_tdead an alle.
H.TD = { CLS = "BP_BanditTurret_AI_C", PATH = "/Game/AI/BP_BanditTurret_AI.BP_BanditTurret_AI_C",
         PICK = "BP_TurretGunPickup_C", GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
         MATCH = 300, PAWN = 500, RATE = 2, SRATE = 0.5, UP = 175, TOL = 0.5, HOLDMAX = 30 }
H.TDisQ, H.TDisAt, H.TDisOwn, H.TDisGone, H.TDisSAt, H.TDisHold = {}, {}, {}, {}, {}, {}

-- Handler (Host, Anfrage): nur pruefen + einreihen, Spielaufrufe in H.TDisTick. "...|s" = Halte-Beginn (SP @11cf),
-- ohne Suffix = Abschluss; der Abschluss gilt nur nach gemeldetem Beginn am selben Geschuetz + Duration (SP @0387).
function H.TDisMsg(Data, G, Msg)
    if Net.Side ~= "host" or type(G) ~= "table" or not G.Key then return end
    if not (U.On(F.AI) and U.On(F.TDIS) and Net.Has("aitd", G)) then return Net.Reply(Msg, "no|off") end
    local Now = os.clock()
    local Cls, X, Y, Z, Ph = tostring(Data or ""):match("^([%w_]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)(|?s?)$")
    if Ph ~= nil and Ph ~= "" and Ph ~= "|s" then Cls = nil end
    local Start = Ph == "|s"
    local RT = Start and H.TDisSAt or H.TDisAt
    if (RT[G.Key] or 0) > Now then
        Net.SecWarn(G, G.Key, "ai_tdis_rate")
        return Net.Reply(Msg, "no|rate")
    end
    RT[G.Key] = Now + (Start and H.TD.SRATE or H.TD.RATE)
    if Cls ~= H.TD.CLS or #H.TDisQ >= 16 then
        Net.SecWarn(G, G.Key, "ai_tdis_bad")
        return Net.Reply(Msg, "no|bad")
    end
    H.TDisQ[#H.TDisQ + 1] = { Key = G.Key, Msg = Msg, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z),
                              Start = Start, T = Now }
end

-- Eine Anfrage ausfuehren: "ok" oder Ablehnungsgrund, nil = Gast weg (keine Antwort moeglich)
function H.TDisOne(J)
    local G = Net.Guests[J.Key]
    if not (G and G.Epoch) then return nil end
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or A.Safe(function() return Pawn["PlayerDead?"] == true end, false) then return "tot" end
    -- Vorpruefung vor dem Scan: Anfrage-Punkt muss in Reichweite der Figur liegen (PAWN + MATCH)
    local QX, QY, QZ = U.Loc(Pawn)
    if not QX then return "fehler" end
    local QR = H.TD.PAWN + H.TD.MATCH
    if (QX - J.X) ^ 2 + (QY - J.Y) ^ 2 + (QZ - J.Z) ^ 2 > QR * QR then
        Net.SecWarn(G, G.Key, "ai_tdis_dist")
        return "weit"
    end
    -- FindAllOf hoechstens 1x/s (sonst erzwingen Gaeste mit wechselnden Koordinaten mehrere Scans/s)
    local Now, TL = os.clock(), H.TDisL
    if not TL or Now - TL.At >= 1 then
        TL = { At = Now, L = FindAllOf(H.TD.CLS) or {} }
        H.TDisL = TL
    end
    local O, Best = nil, H.TD.MATCH * H.TD.MATCH
    for _, Cd in ipairs(TL.L) do
        if A.IsAlive(Cd) then
            local X, Y, Z = U.Loc(Cd)
            local D = X and (X - J.X) ^ 2 + (Y - J.Y) ^ 2 + (Z - J.Z) ^ 2
            if D and D <= Best then O, Best = Cd, D end
        end
    end
    if not O then return "fehlt" end
    local TC = A.Safe(function() return O.BP_TurretAIComponent end)
    if not A.IsAlive(TC) then return "fehlt" end
    if A.Safe(function() return TC.Dead == true end, true) then return "aus" end
    local OX, OY, OZ = U.Loc(O)
    local PX, PY, PZ = U.Loc(Pawn)
    if not (OX and PX) then return "fehler" end
    if (OX - PX) ^ 2 + (OY - PY) ^ 2 + (OZ - PZ) ^ 2 > H.TD.PAWN * H.TD.PAWN then
        Net.SecWarn(G, G.Key, "ai_tdis_dist")
        return "weit"
    end
    local Build = A.Coop and A.Coop.Build
    if Build and type(Build.CanUse) == "function"
        and A.Safe(function() return Build.CanUse(G.GuestId, O) end, true) == false then return "zugriff" end
    -- SP-Bedingung @12c2: GetBehindObject?(self, InteractingActor, (0,0,0), self) -> erster boolean im Out
    local Lib = StaticFindObject(H.TD.GFL)
    if not A.IsAlive(Lib) then return "fehler" end
    local Out = {}
    local okB = pcall(function() Lib["GetBehindObject?"](Lib, O, Pawn, { X = 0, Y = 0, Z = 0 }, O, Out) end)
    local Behind = Out["BehindObject?"]
    if type(Behind) ~= "boolean" then
        for _, V in pairs(Out) do if type(V) == "boolean" then Behind = V break end end
    end
    if not okB then return "fehler" end
    if Behind ~= true then
        if not J.Start then H.TDisHold[J.Key] = nil end
        return "vorne"
    end
    local Path = U.Path(O)
    if not Path then return "fehler" end
    if J.Start then
        H.TDisHold[J.Key] = { Path = Path, At = J.T }   -- Halte-Beginn (Empfangszeit), Spiel bleibt unberuehrt
        return "ok"
    end
    -- SP-Gate RetriggerableDelay(Duration) @03e1: Beginn gemeldet, selbes Geschuetz, Duration verstrichen
    local Hd = H.TDisHold[J.Key]
    H.TDisHold[J.Key] = nil
    local Dur = tonumber(A.Safe(function() return O.Duration end)) or 0
    if not (Hd and Hd.Path == Path and J.T >= Hd.At + Dur - H.TD.TOL and J.T <= Hd.At + Dur + H.TD.HOLDMAX) then
        Net.SecWarn(G, G.Key, "ai_tdis_hold")
        return "halt"
    end
    -- Owner-Trick: bleibt gesetzt (latente BP-Fortsetzungen), SetOwner(nil) erst nach 'gone' des Gasts
    pcall(function() O:SetOwner(Pawn) end)
    if Path then H.TDisOwn[Path] = J.Key end
    local okE, errE = pcall(function()
        O.IsHeld = true
        O:ExecuteUbergraph_BP_BanditTurret_AI(31)
    end)
    if not okE then
        Core.Fail(F.TDIS, errE)
        return "fehler"
    end
    if not A.Safe(function() return TC.Dead == true end, false) then
        U.Log("Geschuetz deaktivieren: UB-Einsprung 31 ohne Wirkung (Dead=false)")
        return "fehler"
    end
    -- Server-Pickup (L_001f +175 z) fuer die Gaeste sichtbar machen
    local N, R2 = 0, H.TD.MATCH * H.TD.MATCH
    for _, P in ipairs(FindAllOf(H.TD.PICK) or {}) do
        if A.IsAlive(P) then
            local X, Y, Z = U.Loc(P)
            if X and (X - OX) ^ 2 + (Y - OY) ^ 2 + (Z - OZ - H.TD.UP) ^ 2 <= R2 then
                if A.Safe(function() return P.bReplicates == true end, false) ~= true then
                    pcall(function() P:SetReplicates(true) end)
                end
                pcall(function() P:ForceNetUpdate() end)
                N = N + 1
            end
        end
    end
    local Key = string.format("%s@%d,%d,%d", H.TD.CLS, math.floor(OX + 0.5), math.floor(OY + 0.5), math.floor(OZ + 0.5))
    Net.State("ai_tdead", Key, "1", 1)
    H.TDeadPub[Key] = { X = OX, Y = OY, Z = OZ }
    U.Log("Geschuetz %s von %s deaktiviert (Waffen-Pickups %d)", Key, J.Key:match("([^%.]+)$") or J.Key, N)
    return "ok"
end

-- ai_tdead-Buchfuehrung (Host): veroeffentlichte Schluessel -> Lage. Kartenobjekte kommen nach Weltwechsel/Neuladen
-- wieder (kein Laufzeit-Spawn), daher: Gen-Wechsel -> alle sofort zurueckziehen, nach dem Laden nur die wirklich
-- toten (TC.Dead) neu senden; sonst alle 30 s pruefen, lebendes Geschuetz -> zurueckziehen.
H.TDeadPub, H.TDeadRe, H.TDeadChkAt = {}, nil, 0

-- nil = nicht gefunden, true = tot, false = lebt
function H.TDeadFind(L, T)
    local O, Best = nil, H.TD.MATCH * H.TD.MATCH
    for _, Cd in ipairs(L) do
        if A.IsAlive(Cd) then
            local X, Y, Z = U.Loc(Cd)
            local D = X and (X - T.X) ^ 2 + (Y - T.Y) ^ 2 + (Z - T.Z) ^ 2
            if D and D <= Best then O, Best = Cd, D end
        end
    end
    local TC = O and A.Safe(function() return O.BP_TurretAIComponent end)
    if not A.IsAlive(TC) then return nil end
    return A.Safe(function() return TC.Dead == true end, true)
end

function H.TDeadCheck(Now)
    local WG = A.WorldGen or {}
    if H.TDeadGen ~= WG.N then
        H.TDeadGen = WG.N
        if next(H.TDeadPub) then
            H.TDeadRe = H.TDeadRe or {}
            local N = 0
            for Key, T in pairs(H.TDeadPub) do
                Net.State("ai_tdead", Key, nil)
                H.TDeadRe[Key], N = T, N + 1
            end
            H.TDeadPub = {}
            U.Log("Weltwechsel: %d Geschuetz-Zustaende (ai_tdead) zurueckgezogen, Pruefung nach dem Laden", N)
        end
        H.TDeadChkAt = Now + 5
        return
    end
    if WG.Loading and Now - (WG.LoadingAt or 0) < 60 then H.TDeadChkAt = Now + 5 return end
    if Now < H.TDeadChkAt or not (next(H.TDeadPub) or H.TDeadRe) then return end
    H.TDeadChkAt = Now + 30
    local L = FindAllOf(H.TD.CLS) or {}
    local Re = H.TDeadRe
    H.TDeadRe = nil
    for Key, T in pairs(Re or {}) do
        if H.TDeadFind(L, T) == true then
            Net.State("ai_tdead", Key, "1", 1)
            H.TDeadPub[Key] = T
        end
    end
    for Key, T in pairs(H.TDeadPub) do
        if H.TDeadFind(L, T) == false then
            Net.State("ai_tdead", Key, nil)
            H.TDeadPub[Key] = nil
            U.Log("Geschuetz %s lebt wieder: ai_tdead zurueckgezogen", Key)
        end
    end
end

-- Host 4 Hz: Warteschlange abarbeiten, Owner nach 'gone' zuruecksetzen, ai_tdead pruefen
function H.TDisTick()
    H.TDeadCheck(os.clock())
    if #H.TDisQ > 0 then
        local Q = H.TDisQ
        H.TDisQ = {}
        for _, J in ipairs(Q) do
            local ok, R = pcall(H.TDisOne, J)
            if not ok then
                U.Log("Geschuetz deaktivieren: Fehler %s", tostring(R))
                R = "fehler"
            end
            if R then Net.Reply(J.Msg, R == "ok" and "ok" or ("no|" .. R)) end
        end
    end
    if next(H.TDisGone) then
        for Path, Key in pairs(H.TDisOwn) do
            if H.TDisGone[Key] then
                H.TDisOwn[Path] = nil
                local O = StaticFindObject(Path)
                if A.IsAlive(O) then pcall(function() O:SetOwner(nil) end) end
            end
        end
        H.TDisGone = {}
    end
end

-- ---------------------------------------------------------------- Gast

function C.Reset()
    C.E, C.Dirty, C.Bind, C.BoundBy, C.Guarded, C.Watch, C.MonQ, C.Extra = {}, {}, {}, {}, {}, {}, {}, {}
    C.Pool, C.PoolSrc, C.Tick, C.Ghost, C.BMDone = nil, nil, 0, 0, nil
    C.Applied, C.Deaths, C.Mons = 0, 0, 0
    C.TDis, C.TDisPos, C.TDeadDone, C.TDisUndo = {}, {}, {}, {}
    C.TDeadAt = 0
    -- Runde 9: Markierungen (AI-9), Nahzustand (AI-6), Pfad-Caches (AI-8), Adress-Cache der Kandidaten (AI-8)
    C.Mark, C.NearDone, C.EmPath, C.SkyPath, C.AddrC = {}, {}, nil, nil, {}
end
C.TDead = {}   -- ai_tdead (Host-Zustand) ueberlebt Weltwechsel, geloescht nur bei linked/gone

function C.Active()
    return Net.Side == "client" and U.On(F.AI) and Net.Has("ai2")
end

function C.Parse(V)
    local Fam, Cls, QX, QY, QZ, Hp, Max, Beh, Fl =
        V:match("^(%a);([^;]+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?[%d%.]+);(%-?[%d%.]+);(%-?%d+);(%d+)$")
    if not Fam then return nil end
    return { Fam = Fam, Cls = Cls, X = tonumber(QX) * K.Q, Y = tonumber(QY) * K.Q, Z = tonumber(QZ) * K.Q,
             Hp = tonumber(Hp) or 0, Max = tonumber(Max) or 0, Beh = tonumber(Beh) or 0, Fl = tonumber(Fl) or 0 }
end

-- AI-8 (ai_perf): Name/Autoritaet/Familie je Objekt-Adresse merken (aendern sich fuer ein Objekt nie). Die Liste
-- A.Characters() ist 0,2 s jung -> der Pool wird bis 5x/s neu gebaut; ohne Cache je Figur ~6 Aufrufe mehr. Jede
-- Sekunde je Adresse den Namen neu vergleichen (Adresse nach GC neu vergeben -> alles neu bestimmen).
function C.Ident(Obj, Now)
    local Addr = U.On(F.PERF) and A.Safe(function() return Obj:GetAddress() end) or nil
    local E = Addr and C.AddrC[Addr]
    if E and Now - E.At < 1 then return E end
    local Name = U.Name(Obj)
    if E and Name and Name == E.Name then
        E.At = Now
        return E
    end
    local Auth = A.Safe(function() return Obj:HasAuthority() end, true)
    local Fam, Cls
    if not Auth then Fam, Cls = U.Fam(Obj) end
    E = { Name = Name, Fam = Fam, Cls = Cls, Auth = Auth, At = Now }
    if Addr then C.AddrC[Addr] = E end
    return E
end

-- Kandidaten (Kopien ohne Autoritaet) aus A.Characters(): neu nur, wenn die Liste neu ist (0,2 s)
function C.PoolGet()
    local Src = A.Characters() or {}
    if C.Pool and C.PoolSrc == Src then return C.Pool end
    local P, Now = { List = {}, ByName = {}, FamOf = {} }, os.clock()
    for _, Obj in ipairs(Src) do
        local I = A.IsAlive(Obj) and C.Ident(Obj, Now) or nil
        local Name = I and not I.Auth and I.Fam and I.Name
        if Name then
            P.ByName[Name], P.FamOf[Name] = Obj, I.Fam
            local X, Y, Z = U.Loc(Obj)
            if X then
                P.List[#P.List + 1] = { Name = Name, Cls = I.Cls, X = X, Y = Y, Z = Z, Obj = Obj,
                    Dead = A.Coop.IsDeadAI and A.Safe(function() return A.Coop.IsDeadAI(Obj) end, false) or false }
            end
        end
    end
    C.Pool, C.PoolSrc = P, Src
    return P
end

-- Nicht-Characters (Geschuetze, Nester): FindAllOf hoechstens 1x pro Sekunde je Klasse
function C.ExtraGet(Cls)
    local X, Now = C.Extra[Cls], os.clock()
    if X and Now - X.At < 1 then return X end
    X = { At = Now, List = {}, ByName = {} }
    for _, Obj in ipairs(FindAllOf(Cls) or {}) do
        if A.IsAlive(Obj) then
            local Name = U.Name(Obj)
            local PX, PY, PZ = U.Loc(Obj)
            if Name and PX then
                X.ByName[Name] = Obj
                X.List[#X.List + 1] = { Name = Name, Cls = Cls, X = PX, Y = PY, Z = PZ, Obj = Obj, Dead = false }
            end
        end
    end
    C.Extra[Cls] = X
    return X
end

function C.Unbind(Key)
    local B = C.Bind[Key]
    if B and C.BoundBy[B.Name] == Key then C.BoundBy[B.Name] = nil end
    C.Bind[Key] = nil
end

-- Neu binden; eine fremde Bindung an diese Kopie wird geloest und im naechsten Durchlauf neu gesucht
function C.DoBind(Key, Name, Later)
    C.Unbind(Key)
    local Other = C.BoundBy[Name]
    if Other and Other ~= Key then
        C.Bind[Other] = nil
        Later[#Later + 1] = Other
    end
    C.Bind[Key], C.BoundBy[Name] = { Name = Name }, Key
end

-- Fremd gebundene Kopie uebernehmen: nur, wenn deren Meldung weit (> KEEP) und deutlich weiter weg liegt als unsere
function C.CanSteal(Owner, Cd, D)
    local Eo = C.E[Owner]
    if not Eo then return true end
    local Do = (Cd.X - Eo.X) ^ 2 + (Cd.Y - Eo.Y) ^ 2 + (Cd.Z - Eo.Z) ^ 2
    return Do > K.KEEP * K.KEEP and Do > D + K.MARGIN * K.MARGIN
end

-- Kopie zu einem Schluessel. Karten-Actor: Name. Sonst klebende Bindung (Name), Neubindung nur bei klar besserer Kopie
-- derselben Klasse; Erstbindung nur innerhalb MATCH (auch fuer Tote: nie "naechste lebende" weiter weg).
function C.Resolve(Key, E, Later)
    local IsChar = E.Fam ~= "t" and E.Fam ~= "n"
    local P = IsChar and C.PoolGet() or C.ExtraGet(E.Cls)
    if Key:sub(1, 1) == "m" then
        local O = P.ByName[Key:sub(2)]
        return (O and A.IsAlive(O)) and O or nil
    end
    local Dead = U.IsDead(E)
    local B, Cur, CurD = C.Bind[Key], nil, math.huge
    if B then
        local O = P.ByName[B.Name]
        if O and A.IsAlive(O) then
            if Dead then return O end
            local X, Y, Z = U.Loc(O)
            if X then CurD = (X - E.X) ^ 2 + (Y - E.Y) ^ 2 + (Z - E.Z) ^ 2 end
            if CurD <= K.KEEP * K.KEEP then return O end
            Cur = O
        else
            C.Unbind(Key)
            B = nil
        end
    end
    local Lim = K.MATCH * K.MATCH
    if Cur then Lim = math.min(Lim, CurD - K.MARGIN * K.MARGIN) end
    local Best, BestD = nil, Lim
    for _, Cd in ipairs(P.List) do
        if Cd.Cls == E.Cls and not (B and Cd.Name == B.Name) and (Dead or not Cd.Dead) then
            local D = (Cd.X - E.X) ^ 2 + (Cd.Y - E.Y) ^ 2 + (Cd.Z - E.Z) ^ 2
            if D < BestD then
                local Owner = C.BoundBy[Cd.Name]
                if not Owner or C.CanSteal(Owner, Cd, D) then Best, BestD = Cd, D end
            end
        end
    end
    if Best and A.IsAlive(Best.Obj) then
        C.DoBind(Key, Best.Name, Later or {})
        return Best.Obj
    end
    return Cur
end

-- ai_notrace (AI-1): UE 5.6 Zombie-/Boss-Traces (Attack/LeftArm/RightArm/Bite, Boss GroundSmash) pruefen nur
-- self.ClassesToIgnore (Array_Contains(GetObjectClass(HitActor)), BP_MasterZombie_C AttackTrace @01c4) -> Spielerklasse
-- einmal eintragen: die Kopie trifft keine Spielerfigur mehr (kein Phantom-Biss/Svr_Montage, keine lokale Blutung,
-- Infektion, Strahlung). Echte Treffer kommen vom Host. (Wie Legacy amon/amon2, main.lua.)
C.PLAYER_CLS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
function C.IgnorePlayers(O)
    local PCls = A.Safe(function() return StaticFindObject(C.PLAYER_CLS) end)
    local L = A.Safe(function() return O.ClassesToIgnore end)
    if not (A.IsAlive(PCls) and L ~= nil) then return end
    local Addr, Has = A.Safe(function() return PCls:GetAddress() end), false
    if not Addr then return end
    pcall(function() L:ForEach(function(_, E)
        local Cv = E:get()
        if Cv and Cv:IsValid() and Cv:GetAddress() == Addr then Has = true end
    end) end)
    if not Has then pcall(function() L[#L + 1] = PCls end) end
end

-- Waechter ohne Hooks (nur Eigenschaften): keine lokale Schadensrechnung, kein Schaden durch die Kopie, kein lokaler
-- Optimizer (Einfrieren/Despawn replizierter Kopien)
function C.Guard(O, Fam)
    pcall(function() O.bCanBeDamaged = false end)
    if (Fam == "z" or Fam == "b") and U.On(F.NOTRACE) then C.IgnorePlayers(O) end
    local function Comp(P) local X = A.Safe(function() return O[P] end) return A.IsAlive(X) and X or nil end
    if Fam == "z" or Fam == "b" or Fam == "n" then
        local DC = Comp("DamageComponent")
        if DC then pcall(function() DC["CanDamage?"] = false end) end
    end
    -- Schaden der Kopie: UE 5.6 MasterZombie AttackDamage (Treffer @05be/@4b51, Blutmond-Ende @572c = Default_AttackDamage),
    -- Boss AttackDamage = Vector2D min/max (@266f RandomFloatInRange); UE 5.3 und Baer/Wolf: DamageToDo
    local Dmg = false
    if Fam == "z" then
        Dmg = pcall(function() O.AttackDamage = 0 end)
        if Dmg then pcall(function() O.Default_AttackDamage = 0 end) end
    elseif Fam == "b" then
        Dmg = pcall(function() O.AttackDamage = { X = 0, Y = 0 } end)
    end
    if not Dmg and (Fam == "z" or Fam == "b" or Fam == "a") then pcall(function() O.DamageToDo = 0 end) end
    if Fam == "a" then
        local CC = Comp("CCCollisionHandler")
        if CC then pcall(function() CC:Deactivate() end) end
    end
    if Fam ~= "t" and Fam ~= "n" and U.On(F.AIO) then
        local AS = Comp("AIOSubject")
        if AS then pcall(function() AS:SetCanBeUpdatedBySubsystem(false) end) end
    end
end

-- 1 Hz: alle KI-Kopien einmal je Name schuetzen (unabhaengig von ai2, auch bei altem Host)
function C.GuardPass()
    local N = 0
    if U.On(F.PERF) then
        -- AI-8: Kandidaten-Pool (Kopien ohne Autoritaet, Familie/Name bekannt) statt aller Figuren mit je 6 Aufrufen
        local P = C.PoolGet()
        for Name, O in pairs(P.ByName) do
            if N >= 40 then break end
            if not C.Guarded[Name] and A.IsAlive(O) then
                C.Guarded[Name] = true
                N = N + 1
                C.Guard(O, P.FamOf[Name])
            end
        end
        if N > 0 and not C.GuardLogged then C.GuardLogged = true U.Log("KI-Kopien geschuetzt (ohne Hooks): %d", N) end
        return
    end
    for _, O in ipairs(A.Characters() or {}) do
        if N >= 40 then break end
        if A.IsAlive(O) then
            local Fam = U.Fam(O)
            local Name = Fam and U.Name(O)
            if Name and not C.Guarded[Name] and not A.Safe(function() return O:HasAuthority() end, true) then
                C.Guarded[Name] = true
                N = N + 1
                C.Guard(O, Fam)
            end
        end
    end
    if N > 0 and not C.GuardLogged then C.GuardLogged = true U.Log("KI-Kopien geschuetzt (ohne Hooks): %d", N) end
end

-- ai_aio_near (AI-6): C.Guard sperrt den lokalen AI-Optimizer (SetCanBeUpdatedBySubsystem(false)) im Zustand des
-- Guard-Zeitpunkts - Kopien entstehen an der Relevanzgrenze (~150 m) und bleiben dann fern eingestuft (Features 8-31,
-- Mesh/Bewegung 10-20 Hz, Hund unsichtbar). Lebende Kopien <= 60 m einmal in den Nahzustand des Spiels setzen
-- (OnOptimizationUpdate Stufe 0: SetCharacterFeatures(self, 95) @3daa, Mesh/Bewegung-TickInterval @3c16-3c8a).
-- Nur <= 60 m (Gast-CPU); fernere bleiben, wie sie sind, bis sie naeherkommen.
K.AIO_NEAR = 6000
function C.NearState(O)
    local AS = A.Safe(function() return O.AIOSubject end)
    if A.IsAlive(AS) then pcall(function() AS:SetCharacterFeatures(O, 95) end) end
    local Me = A.Safe(function() return O.Mesh end)
    if A.IsAlive(Me) then
        pcall(function() Me:SetComponentTickInterval(0) end)
        pcall(function() Me:SetVisibility(true, false) end)
        pcall(function() if Me.bPauseAnims == true then Me.bPauseAnims = false end end)
    end
    local Mv = A.Safe(function() return O.CharacterMovement end)
    if A.IsAlive(Mv) then pcall(function() Mv:SetComponentTickInterval(0) end) end
end

-- ai_aio_far (Review 3, AI-6b): der Nahzustand war eine Einbahnstrasse (Guard sperrt den Optimizer, NearDone wurde
-- nie zurueckgenommen) -> jede einmal nahe Kopie tickte bis zur Relevanzgrenze jeden Frame. Ab 90 m (Hysterese zu
-- 60 m) zurueck auf die lebende Stufe 2 des Spiels: SetCharacterFeatures(self, 31) @404d, Mesh/Bewegung
-- RandomFloatInRange(0.05, 0.1) @3cd9-3d4d. Nie 8 (nur Kollision: Kopie waere unsichtbar/starr). Sichtbarkeit und
-- bPauseAnims bleiben unberuehrt (Stufe 2 aendert sie im SP auch nicht).
K.AIO_FAR = 9000
function C.FarState(O)
    local AS = A.Safe(function() return O.AIOSubject end)
    if A.IsAlive(AS) then pcall(function() AS:SetCharacterFeatures(O, 31) end) end
    local T = 0.05 + math.random() * 0.05
    local Me = A.Safe(function() return O.Mesh end)
    if A.IsAlive(Me) then pcall(function() Me:SetComponentTickInterval(T) end) end
    local Mv = A.Safe(function() return O.CharacterMovement end)
    if A.IsAlive(Mv) then pcall(function() Mv:SetComponentTickInterval(T) end) end
end

function C.NearStep()
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn) or nil
    local L = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    if not L then return end
    local R2, F2, N, NF = K.AIO_NEAR * K.AIO_NEAR, K.AIO_FAR * K.AIO_FAR, 0, 0
    local Far = U.On(F.AIOFAR)
    for _, Cd in ipairs(C.PoolGet().List) do
        if N >= 20 then break end
        if not Cd.Dead and C.Guarded[Cd.Name] then
            local D2 = (Cd.X - L.X) ^ 2 + (Cd.Y - L.Y) ^ 2 + (Cd.Z - L.Z) ^ 2
            if not C.NearDone[Cd.Name] then
                if D2 <= R2 and A.IsAlive(Cd.Obj) then
                    C.NearDone[Cd.Name] = true
                    N = N + 1
                    C.NearState(Cd.Obj)
                end
            elseif Far and D2 > F2 and A.IsAlive(Cd.Obj) then
                -- Ruecknahme: NearDone leeren, damit die Kopie bei erneuter Annaeherung wieder hochgestuft wird
                C.NearDone[Cd.Name] = nil
                N, NF = N + 1, NF + 1
                local ok, err = pcall(C.FarState, Cd.Obj)
                if not ok then
                    Core.Fail(F.AIOFAR, err)
                    Far = false
                end
            end
        end
    end
    -- N ist die gemeinsame Obergrenze pro Durchlauf (Hochstufungen + Ruecknahmen); fuer die Diagnose nur Hochstufungen zaehlen
    C.FarN = (C.FarN or 0) + NF
    C.NearN = (C.NearN or 0) + (N - NF)
    if N - NF > 0 and not C.NearLogged then
        C.NearLogged = true
        U.Log("KI-Kopien in der Naehe in den Nahzustand gesetzt (AI-Optimizer Stufe 0): %d", N - NF)
    end
end

-- Testbefehl ai_aiocheck (Gast): Zustand der Kopien <= 10 m (bestaetigt/widerlegt AI-6)
function C.AioCheck()
    local Pawn = A.OwnPawn and A.Safe(A.OwnPawn) or nil
    local L = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    if not L then return A.TestLog("ai_aiocheck: keine eigene Figur") end
    local function Val(Obj, Fn)
        if not A.IsAlive(Obj) then return "-" end
        return tostring(A.Safe(Fn))
    end
    local N = 0
    for _, Cd in ipairs(C.PoolGet().List) do
        if N >= 10 then break end
        if (Cd.X - L.X) ^ 2 + (Cd.Y - L.Y) ^ 2 + (Cd.Z - L.Z) ^ 2 <= 1000 * 1000 and A.IsAlive(Cd.Obj) then
            N = N + 1
            local O = Cd.Obj
            local Me = A.Safe(function() return O.Mesh end)
            local Mv = A.Safe(function() return O.CharacterMovement end)
            A.TestLog("ai_aiocheck %s (%s): Mesh-Tick %s, bPauseAnims %s, sichtbar %s, Bewegungs-Tick %s/%s, tot %s, "
                .. "geschuetzt %s, Nahzustand %s", Cd.Name, Cd.Cls,
                Val(Me, function() return Me:GetComponentTickInterval() end), Val(Me, function() return Me.bPauseAnims end),
                Val(Me, function() return Me:IsVisible() end), Val(Mv, function() return Mv:IsComponentTickEnabled() end),
                Val(Mv, function() return Mv:GetComponentTickInterval() end), tostring(Cd.Dead),
                tostring(C.Guarded[Cd.Name] == true), tostring(C.NearDone[Cd.Name] == true))
        end
    end
    A.TestLog("ai_aiocheck: %d Kopie(n) <= 10 m, Nahzustand gesetzt gesamt %d, ab 90 m zurueckgenommen %d "
        .. "(ai_aio_near=%s, ai_aio_far=%s, ai_aio_guest=%s)", N, C.NearN or 0, C.FarN or 0, tostring(U.On(F.AIONEAR)),
        tostring(U.On(F.AIOFAR)), tostring(U.On(F.AIO)))
end

function C.ApplyAnimal(Key, E, O)
    if not U.IsDead(E) then
        if math.abs((tonumber(O.Health) or 0) - E.Hp) > 0.01 then O.Health = E.Hp end
        return
    end
    if U.IsLooted(E) then pcall(function() if O.Looted ~= true then O.Looted = true end end) end
    if A.Safe(function() return O["IsDead?"] == true end, false) then return end
    pcall(function() O.Health = E.Hp end)
    pcall(function() O["IsDead?"] = true end)
    pcall(function() O.Dead = true end)
    local Name = U.Name(O)
    local MX, MY, MZ = U.Loc(O, true)
    if A.Coop.CorpseNow then pcall(A.Coop.CorpseNow, O) end
    if Name and MX and (U.On(F.RAG) or U.On(F.GROUND)) then C.Watch[Name] = { Key = Key, T0 = os.clock(), SX = MX, SY = MY, SZ = MZ } end
    C.Deaths = C.Deaths + 1
    U.Log("Tier %s beim Host gestorben (Id %s): hier umgefallen", Name or "?", Key)
end

function C.Apply(Key, E, O)
    local Fam, Dead = E.Fam, U.IsDead(E)
    local Name = U.Name(O)
    if Name and not C.Guarded[Name] then
        C.Guarded[Name] = true
        C.Guard(O, Fam)
    end
    -- ai_looted: Host-Markierung (Bit 2) auf die Kopie, damit Label/Pluendern wie im SP "gepluendert" zeigen
    if (Fam == "z" or Fam == "b" or Fam == "h") and U.IsLooted(E) and U.On(F.LOOTED) then U.SetLooted(O, Fam) end
    if Fam == "z" or Fam == "b" then
        local DC = O.DamageComponent
        if not A.IsAlive(DC) then return end
        if E.Max > 0 and DC.StandardHealthValue ~= E.Max then DC.StandardHealthValue = E.Max end
        if not Dead and math.abs((tonumber(DC.CurrentHealth) or 0) - E.Hp) > 0.01 then DC.CurrentHealth = E.Hp end
    elseif Fam == "h" then
        local AC = O.BP_AIComponent
        if not A.IsAlive(AC) then return end
        if E.Max > 0 and AC.MaxHealth ~= math.floor(E.Max) then AC.MaxHealth = math.floor(E.Max) end
        if not Dead and AC.Dead ~= true and math.abs((tonumber(AC.Health) or 0) - E.Hp) >= 1 then AC.Health = math.floor(E.Hp) end
    elseif Fam == "a" then
        C.ApplyAnimal(Key, E, O)
    elseif Fam == "t" then
        local TC = O.BP_TurretAIComponent
        if not A.IsAlive(TC) then return end
        if TC["Current Health"] ~= math.floor(E.Hp) then TC["Current Health"] = math.floor(E.Hp) end
        if Dead and TC.Dead ~= true then TC.Dead = true end
    elseif Fam == "n" then
        local DC = O.DamageComponent
        if not A.IsAlive(DC) then return end
        if E.Max > 0 then DC.StandardHealthValue = E.Max end
        if math.abs((tonumber(DC.CurrentHealth) or 0) - E.Hp) > 0.01 then DC.CurrentHealth = E.Hp end
        if Dead and O["IsDestroyed?"] ~= true then
            O:Event_OnDestroyed(nil, true)
            U.Log("Nest %s beim Host zerstoert: hier uebernommen", U.Name(O) or "?")
        end
    end
    C.Applied = C.Applied + 1
end

-- Tier-Ragdoll: in den ersten 3 s Geschwindigkeit klemmen und Wegfliegen zuruecksetzen, danach auf den Liegepunkt
-- des Hosts (Physik aus, Teleport). Freigabe nach 8 s (Corpse.LocalRest friert ein).
function C.WatchOne(O, W, Age)
    local Mesh = O.Mesh
    if not A.IsAlive(Mesh) then return end
    local Sim = Mesh:IsSimulatingPhysics(FName("None"))
    local L = Mesh:K2_GetComponentLocation()
    local X, Y, Z = L.X, L.Y, L.Z
    if Age < 3 then
        if not Sim then return end
        local V = Mesh:GetPhysicsLinearVelocity(FName("None"))
        if V.X * V.X + V.Y * V.Y + V.Z * V.Z > 1200 * 1200 then
            Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false)
            Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false)
        end
        if (X - W.SX) ^ 2 + (Y - W.SY) ^ 2 + (Z - W.SZ) ^ 2 > 400 * 400 then
            Mesh:SetSimulatePhysics(false)
            Mesh:K2_SetWorldLocation({ X = W.SX, Y = W.SY, Z = W.SZ + 10 }, false, {}, true)
            U.Log("Tier-Leiche %s: weggeflogen, zurueckgesetzt", W.Name or "?")
            W.GroundAt = 0   -- gleich danach auf den Boden pruefen (C.GroundOne)
        end
        return
    end
    if W.Placed then return end
    W.Placed = true
    local E = C.E[W.Key]
    if not (E and U.IsDead(E)) then return end
    local D2 = (X - E.X) ^ 2 + (Y - E.Y) ^ 2
    if D2 <= 250 * 250 then return end
    local G = A.Coop.Ground and A.Coop.Ground({ X = E.X, Y = E.Y, Z = E.Z }, O, 150)
    if Sim then Mesh:SetSimulatePhysics(false) end
    Mesh:K2_SetWorldLocation({ X = E.X, Y = E.Y, Z = (G or E.Z) + 15 }, false, {}, true)
    U.Log("Tier-Leiche %s auf die Host-Lage gesetzt (%.1f m)", W.Name or "?", math.sqrt(D2) / 100)
    W.GroundAt = 0
end

-- Tier-Leiche nicht im Boden (animal_ground, Test 22.10.: nach "auf die Host-Lage gesetzt" Kadaver Z 1373, Boden
-- 1394 - kleine Tiere unsichtbar, "kein Kadaver da"). Erst kurz ueber dem Mesh (5 cm) nach unten: liegt darunter
-- in hoechstens 60 cm ein Boden, ist alles gut. Sonst steckt das Mesh im Boden (Landschaft von unten trifft die
-- Linie nicht; Kollisionskoerper, in dem die Linie startet, liefern den Start): Boden von 1 m bzw. 2,5 m darueber
-- suchen und das Mesh auf Boden + 10 setzen (Teleport, Physik aus bzw. bleibt aus). Steht die eigene Figur auf
-- 80 cm daneben, spaeter nochmal (die Linie koennte sie treffen). Kontext = Tier (bIgnoreSelf: nicht das eigene
-- Mesh). Hoechstens 3 Korrekturen je Leiche.
function C.GroundOne(O, W)
    local Mesh = O.Mesh
    if not A.IsAlive(Mesh) or not A.Coop.Ground then return end
    local L = Mesh:K2_GetComponentLocation()
    local X, Y, Z = L.X, L.Y, L.Z
    local Pawn = A.OwnPawn and A.OwnPawn()
    local PL = A.IsAlive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
    if PL and (PL.X - X) ^ 2 + (PL.Y - Y) ^ 2 < 80 * 80 then return end
    local Here = { X = X, Y = Y, Z = Z }
    local G0 = A.Coop.Ground(Here, O, 5)
    if G0 and G0 <= Z + 1 and Z - G0 <= 60 then return end
    local G = A.Coop.Ground(Here, O, 100)
    if not (G and G > Z - 1 and G - Z <= 90) then
        G = A.Coop.Ground(Here, O, 250)
        if not (G and G > Z - 1 and G - Z <= 240) then return end
    end
    if Mesh:IsSimulatingPhysics(FName("None")) then
        pcall(function() Mesh:SetAllPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false) end)
        pcall(function() Mesh:SetAllPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false) end)
        Mesh:SetSimulatePhysics(false)
    end
    Mesh:K2_SetWorldLocation({ X = X, Y = Y, Z = G + 10 }, false, {}, true)
    W.Lifts = (W.Lifts or 0) + 1
    if not W.GroundLogged then
        W.GroundLogged = true
        U.Log("Tier-Leiche %s steckte im Boden (Z %.0f, Boden %.0f): auf den Boden gehoben", W.Name or "?", Z, G)
    end
end

-- Ragdoll bis 8 s, Bodenpruefung ab 3 s (bzw. direkt nach jeder Korrektur) jede Sekunde bis 15 s
function C.WatchStep(Now)
    if not next(C.Watch) then return end
    local P = C.PoolGet()
    local Rag, Gnd = U.On(F.RAG), U.On(F.GROUND)
    for Name, W in pairs(C.Watch) do
        local Age = Now - W.T0
        if Age > 15 or (Age > 8 and not Gnd) then
            C.Watch[Name] = nil
        else
            local O = P.ByName[Name]
            if O and A.IsAlive(O) then
                W.Name = Name
                if Rag and Age <= 8 and not W.RagFailed then
                    local ok, err = pcall(C.WatchOne, O, W, Age)
                    if not ok then
                        W.RagFailed = true
                        Core.Fail(F.RAG, err)
                    end
                end
                if Gnd and (Age >= 3 or W.GroundAt) and Now >= (W.GroundAt or 0) and (W.Lifts or 0) < 3 then
                    W.GroundAt = Now + 1
                    local ok, err = pcall(C.GroundOne, O, W)
                    if not ok then
                        C.Watch[Name] = nil
                        Core.Fail(F.GROUND, err)
                    end
                end
            end
        end
    end
end

function C.MonOne(Data)
    local SKey, SPath, SRate, SSec, SPos = Data:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not SKey then return end
    local Key = Net.Dec(SKey)
    local E = C.E[Key]
    if not E or U.IsDead(E) then return end
    local O = C.Resolve(Key, E)
    if not (O and A.IsAlive(O)) then return end
    if A.Coop.IsDeadAI and A.Coop.IsDeadAI(O) then return end
    local Mon = StaticFindObject(Net.Dec(SPath))
    if not A.IsAlive(Mon) then return end
    local Sec = Net.Dec(SSec)
    O:PlayAnimMontage(Mon, tonumber(SRate) or 1, FName(Sec ~= "" and Sec or "None"))
    local Pos = tonumber(SPos) or 0
    if Pos > 0.15 then
        local Mesh = A.Safe(function() return O.Mesh end)
        local Inst = A.IsAlive(Mesh) and A.Safe(function() return Mesh:GetAnimInstance() end) or nil
        if A.IsAlive(Inst) then pcall(function() Inst:Montage_SetPosition(Mon, Pos) end) end
    end
    C.Mons = C.Mons + 1
    if C.Mons == 1 then U.Log("KI-Animationen vom Host (ohne Hook) werden abgespielt") end
end

-- Geister: Laufzeit-Kopien replizierter Nicht-Character-Klassen (Role Authority, bReplicates, ohne RF_WasLoaded)
function C.GhostStep()
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not WL or os.clock() - (C.LinkedAt or os.clock()) < 3 then return end
    C.Ghost = C.Ghost % #C.GHOSTS + 1
    local Cls, N = C.GHOSTS[C.Ghost], 0
    for _, O in ipairs(FindAllOf(Cls) or {}) do
        if N >= 50 then break end
        if A.IsAlive(O) and A.Safe(function() return O.Role == 3 and O.bReplicates == true and not O:HasAnyFlags(WL) end, false)
            and pcall(function() O:K2_DestroyActor() end) then
            N = N + 1
        end
    end
    if N > 0 then U.Log("%d lokale Geister (%s) entfernt", N, Cls) end
end

-- ai_markers (AI-9): Markierung (BP_PlayerCharacter_C.MarkEnemy @0952 -> AddMarker, 1-s-Timer Event_Marker) laeuft im
-- SP 60 s nach dem letzten Sichtkontakt ab: Event_Marker (MasterZombie @66bb-6745, ebenso Tiere/Menschen/Boss/Haendler)
-- prueft PC0->LineOfSightTo(GetAIController(self)) und startet nur bei Sicht RetriggerableDelay(60) -> @147a
-- Marker->K2_DestroyComponent(self), @149b Timer weg. Auf der Kopie ist GetAIController(self) null -> nie Sicht -> die
-- Markierung bliebe bis Tod/Despawn. Gast 1 Hz: dieselbe Regel mit der Kopie selbst als Ziel.
C.MARK_S = 60
C.KSL = "/Script/Engine.Default__KismetSystemLibrary"
function C.MarkStep(Now)
    local PC = A.LocalPC and A.Safe(function() return A.LocalPC() end) or nil
    if not A.IsAlive(PC) then return end
    local Live = {}
    for Name, O in pairs(C.PoolGet().ByName) do
        local Mk = A.IsAlive(O) and A.Safe(function() return O.Marker end) or nil
        local Addr = A.IsAlive(Mk) and A.Safe(function() return Mk:GetAddress() end) or nil
        if Addr then
            Live[Name] = true
            local S = C.Mark[Name]
            if not S or S.Addr ~= Addr then
                S = { Addr = Addr, Seen = Now }   -- neue Markierung: gerade gesehen (Markieren braucht Sicht)
                C.Mark[Name] = S
            end
            if S.Done then
                -- schon entfernt, Komponente bis zur GC noch referenziert
            elseif A.Safe(function() return PC:LineOfSightTo(O, { X = 0, Y = 0, Z = 0 }, false) end, false) == true then
                S.Seen = Now
            elseif Now - S.Seen > C.MARK_S then
                S.Done = true
                pcall(function() Mk:K2_DestroyComponent(O) end)
                local KSL = A.Safe(function() return StaticFindObject(C.KSL) end)
                if A.IsAlive(KSL) then pcall(function() KSL:K2_ClearTimer(O, "Event_Marker") end) end
                -- wie SP-Ablauf: MasterZombie CanAddMarkerToAI? = !K2_IsValidTimerHandle(MarkerTimer) (@0000, SP @149b
                -- invalidiert den Griff); Boss/Tiere/Menschen/Haendler lesen self.CanAddMarker? (SP setzt es beim Ablauf
                -- auf true: Boss @0266, Bandit @0118, Wolf @0176). K2_ClearTimer laesst den gespeicherten Griff stehen ->
                -- ohne Reset waere der Gegner auf der Kopie nie wieder markierbar (beides nicht repliziert).
                if A.IsAlive(O) then
                    if not pcall(function() O.MarkerTimer.Handle = 0 end) then
                        pcall(function() O.MarkerTimer = { Handle = 0 } end)
                    end
                    if type(A.Safe(function() return O["CanAddMarker?"] end)) == "boolean" then
                        pcall(function() O["CanAddMarker?"] = true end)
                    end
                    local H = tonumber(A.Safe(function() return O.MarkerTimer.Handle end))
                    if H and H ~= 0 and not C.MarkWarn then
                        C.MarkWarn = true
                        U.Log("Markierung %s: Timer-Griff nicht zurueckgesetzt", Name)
                    end
                end
                C.MarkN = (C.MarkN or 0) + 1
                if C.MarkN <= 5 or C.MarkN % 50 == 0 then
                    U.Log("Markierung von %s nach %d s ohne Sicht entfernt (wie SP, %d)", Name, C.MARK_S, C.MarkN)
                end
            end
        end
    end
    for Name in pairs(C.Mark) do if not Live[Name] then C.Mark[Name] = nil end end
end

-- AI-8: Einzel-Actor (UDS, EventManager) ueber den gemerkten Pfad (StaticFindObject) statt FindFirstOf (voller Objekt-
-- Scan) je Aufruf. Neu suchen alle 30 s bzw. nach Fehlschlag hoechstens alle 5 s. ai_perf aus: FindFirstOf wie bisher.
function U.FindCached(T, Field, Cls)
    if not U.On(F.PERF) then
        local O = FindFirstOf(Cls)
        return A.IsAlive(O) and O or nil
    end
    local Now, E = os.clock(), T[Field]
    if type(E) == "table" and Now < E.Until then
        local O = E.Path and A.Safe(function() return StaticFindObject(E.Path) end) or nil
        if A.IsAlive(O) then return O end
        if Now < E.Retry then return nil end
    end
    local O = FindFirstOf(Cls)
    local Alive = A.IsAlive(O)
    T[Field] = { Path = Alive and U.Path(O) or nil, Until = Now + 30, Retry = Now + 5 }
    return Alive and O or nil
end

-- Blutmond: nie selbst wuerfeln, nur den Zustand des Hosts uebernehmen
function C.BloodStep()
    local EM = U.FindCached(C, "EmPath", "BP_EventManager_C")
    if not A.IsAlive(EM) then return end
    pcall(function() if EM.BloodMoonChance ~= 0 then EM.BloodMoonChance = 0 end end)
    local V = C.BM
    if V == nil or V == C.BMDone then return end
    C.BMDone = V
    local Want = V == "1"
    local Local = U.BloodOf(U.FindCached(C, "SkyPath", "Ultra_Dynamic_Sky_C"))
    if Local == nil or Local == Want then return end
    if pcall(function() EM:SetBloodMoon(Want) end) then U.Log("Blutmond vom Host: %s", Want and "an" or "aus") end
end

-- Gast 1 Hz: lokal entstandene Fleischkiste (Role Authority, z. B. Tod einer gastlokalen Tier-Kopie mit eigenem
-- Huntsman) ist ein Zwilling ohne Server-Inventar. Nur entfernen, wenn die replizierte Host-Kiste (keine Authority)
-- schon <= NEAR daneben liegt; ohne Host-Kiste (Schuetze nicht zuordenbar, Tech-Baum nicht pruefbar ...) bleibt
-- die lokale SP-Kiste wie vor Runde 8 erhalten.
function C.MeatGhosts()
    local Loc, Rep = {}, {}
    for _, O in ipairs(FindAllOf(H.MEAT.BOX) or {}) do
        if A.IsAlive(O) then
            local Auth = A.Safe(function() return O:HasAuthority() end)
            local L = (Auth == true or Auth == false) and A.Safe(function() return O:K2_GetActorLocation() end) or nil
            if L then
                local P = { O = O, X = L.X, Y = L.Y, Z = L.Z }
                if Auth then Loc[#Loc + 1] = P else Rep[#Rep + 1] = P end
            end
        end
    end
    if #Loc == 0 or #Rep == 0 then return end
    local N2 = H.MEAT.NEAR * H.MEAT.NEAR
    for _, P in ipairs(Loc) do
        for _, R in ipairs(Rep) do
            if (P.X - R.X) ^ 2 + (P.Y - R.Y) ^ 2 <= N2 and math.abs(P.Z - R.Z) <= H.MEAT.NEAR then
                local Nm = U.Name(P.O) or "?"
                local ok = A.IsAlive(P.O) and pcall(function() P.O:K2_DestroyActor() end) or false
                U.Log("Lokale Fleischkiste %s entfernt - Host-Kiste liegt daneben (%s)", Nm, ok and "ok" or "Fehler")
                break
            end
        end
    end
end

-- ai_tdis Gast: Pre-Hook-Koerper (nur Name lesen, <= 8 Eintraege, keine UFunction-Aufrufe ausser GetFullName)
function C.TDisHookBody(Ctx)
    if Net.Side ~= "client" or #C.TDis >= 8 then return end
    local ok, O = pcall(function() return Ctx:get() end)
    -- CORE-20: Kontext vor GetFullName pruefen (Methode auf ungueltigem Wrapper stuerzt nativ ab, pcall hilft nicht)
    if not (ok and A.IsAlive(O)) then return end
    local Path = U.Path(O)
    if Path then C.TDis[#C.TDis + 1] = { Path = Path, At = os.clock() } end
end

-- Adresse der aktuell geladenen OnExecuteInteract-UFunction (nil = Klasse nicht geladen). Nach Entladen/Neuladen
-- ist es eine neue UFunction: der alte Hook greift dort nicht mehr.
function C.TDisFnAddr()
    if not A.IsAlive(StaticFindObject(H.TD.PATH)) then return nil end
    local Fn = StaticFindObject(H.TD.PATH .. ":OnExecuteInteract")
    return A.IsAlive(Fn) and A.Safe(function() return Fn:GetAddress() end) or nil
end

-- Hook sitzt auf genau der aktuell geladenen UFunction (sonst kein ai_tdis-Relay)
function C.TDisHookLive()
    return C.TDisHook ~= nil and C.TDisHook == C.TDisFnAddr()
end

-- Hook registrieren, sobald die Klasse geladen ist (Wiederholung alle 10 s); Klasse neu geladen -> neu hooken
function C.TDisHookTry(Now)
    if C.TDisHook and C.TDisHook ~= C.TDisFnAddr() then
        C.TDisHook, C.TDisHookAt = nil, nil
        U.Log("Hook Geschuetz-Deaktivieren: Klasse neu geladen/entladen, Hook wird erneuert")
    end
    if C.TDisHook or Now < (C.TDisHookAt or 0) then return end
    C.TDisHookAt = Now + 10
    local Addr = C.TDisFnAddr()
    if not Addr then return end
    if A.TryHook(H.TD.PATH .. ":OnExecuteInteract", C.TDisHookBody) then
        C.TDisHook = Addr
        U.Log("Hook Geschuetz-Deaktivieren (OnExecuteInteract) aktiv")
    end
end

-- Lage eines deaktivierten Geschuetzes merken: dort 5 s lang lokale Geister-Waffen entfernen
function C.TDisMark(X, Y, Z, Now)
    if #C.TDisPos >= 16 then table.remove(C.TDisPos, 1) end
    C.TDisPos[#C.TDisPos + 1] = { X = X, Y = Y, Z = Z + H.TD.UP, Until = Now + 5 }
end

-- Lokale Waffen-Pickups (Role Authority, Laufzeit) nahe gemerkten Geschuetzen entfernen; echte kommen vom Host
function C.TDisClean(Now)
    if #C.TDisPos == 0 or Now < (C.TDisFindAt or 0) then return end
    C.TDisFindAt = Now + 1
    local R2, N = H.TD.MATCH * H.TD.MATCH, 0
    for _, P in ipairs(FindAllOf(H.TD.PICK) or {}) do
        if A.IsAlive(P) and A.Safe(function() return P:HasAuthority() end, false) == true and not U.WasLoaded(P) then
            local X, Y, Z = U.Loc(P)
            for _, T in ipairs(X and C.TDisPos or {}) do
                if (X - T.X) ^ 2 + (Y - T.Y) ^ 2 + (Z - T.Z) ^ 2 <= R2 then
                    if pcall(function() P:K2_DestroyActor() end) then N = N + 1 end
                    break
                end
            end
        end
    end
    if N > 0 then U.Log("%d lokale Geister-Waffe(n) am Geschuetz entfernt", N) end
    local Keep = {}
    for _, T in ipairs(C.TDisPos) do if Now < T.Until then Keep[#Keep + 1] = T end end
    C.TDisPos = Keep
end

-- Gast-Patch ai_tdis_mesh (nur mit Cap aitd): UE 5.6 L_001f Context @0315 -> @032b (811) FinalFunction
-- K2_DestroyComponent (1C + UFunction*, kdis) -> Jump 06 36030000 (weiter bei 0x0336 PopFlow; UE 5.3 war es @0327 ->
-- 0x0332). Die DLL prueft die erwarteten Bytes und laesst den Patch bei Abweichung weg. Lokal bleiben nur
-- Dead/Can Attack (umkehrbar); das Turret-Mesh verschwindet erst mit ai_tdead des Hosts (C.TDeadStep). Ohne Registry: Mesh lokal weg (Rueckfall).
function C.TDisPatch()
    if not Core.HasPatchRegistry() then return end
    -- nur mit lebendem Hook auf der aktuellen UFunction (sonst kein Relay -> unveraenderter SP-Ablauf)
    local Want = (Net.Side == "client" and U.On(F.AI) and U.On(F.TDIS) and Net.Has("aitd") and C.TDisHookLive())
        and true or false
    if not Want and not C.TDisPatchOn then return end
    local Fn = StaticFindObject(H.TD.PATH .. ":ExecuteUbergraph_BP_BanditTurret_AI")
    local Dc = StaticFindObject("/Script/Engine.ActorComponent:K2_DestroyComponent")
    if not (A.IsAlive(Fn) and A.IsAlive(Dc)) then
        if not Want then C.TDisPatchOn = false end   -- Klasse entladen: die DLL hat den Patch verworfen
        return
    end
    local P = Dc:GetAddress()
    local Old = string.format("1C%02X%02X%02X%02X", P % 256, math.floor(P / 256) % 256, math.floor(P / 65536) % 256,
        math.floor(P / 16777216) % 256)
    local Line = string.format("ai_tdis_mesh bytes %x 811 %s 0636030000 %d", Fn:GetAddress(), Old, Want and 1 or 0)
    if Line == C.TDisPatchLine then return end
    if Core.SetPatch("ai_tdis_mesh", Line) then
        C.TDisPatchLine, C.TDisPatchOn = Line, Want
        U.Log("Geschuetz-Mesh-Patch %s angefordert", Want and "an" or "aus")
    end
end

-- ai_notrace (AI-1) Gast-Patches: Baer/Wolf AttackTrace baut ClassesToIgnore lokal (MakeArray nur der eigenen Klasse,
-- bp\BP_AnimalBear_C.kdis / BP_AnimalWolf_C.kdis @0000 SetArray 31, @0001 LocalVariable 00) -> Lua kann es nicht
-- ergaenzen: ret_early (neu 04 0B = Return/Nothing, die DLL prueft "3100"). Host nie (dort laufen die echten Treffer);
-- nach Seitenwechsel schreibt der Aufruf die 0-Zeile. Klasse entladen: die DLL verwirft, neue Adresse -> neue Zeile.
C.TRACE = { { N = "ai_nt_bear", P = "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C:AttackTrace" },
            { N = "ai_nt_wolf", P = "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C:AttackTrace" } }
C.TraceLine, C.TraceOn = {}, {}
function C.TracePatch(Now)
    if Net.Side == nil or not Core.HasPatchRegistry() or (Now or 0) < (C.TraceAt or 0) then return end
    C.TraceAt = (Now or 0) + 1
    local Want = (Net.Side == "client" and U.On(F.AI) and U.On(F.NOTRACE) and Net.Has("ai2")) and true or false
    for _, T in ipairs(C.TRACE) do
        if Want or C.TraceOn[T.N] then
            local Fn = A.Safe(function() return StaticFindObject(T.P) end)
            local Addr = A.IsAlive(Fn) and A.Safe(function() return Fn:GetAddress() end) or nil
            if Addr then
                local Line = string.format("%s ret_early %x 0 3100 040B %d", T.N, Addr, Want and 1 or 0)
                if Line ~= C.TraceLine[T.N] and Core.SetPatch(T.N, Line) then
                    C.TraceLine[T.N], C.TraceOn[T.N] = Line, Want
                    U.Log("Patch %s %s angefordert", T.N, Want and "an" or "aus")
                end
            elseif not Want then
                C.TraceLine[T.N], C.TraceOn[T.N] = nil, false   -- Klasse entladen: die DLL hat den Patch verworfen
            end
        end
    end
end

-- Host lehnte ab / keine Antwort: lokale Kopie zuruecksetzen (Dead, Can Attack), ausser der Host meldet sie tot
function C.TDisUndoStep()
    if not (C.TDisUndo and next(C.TDisUndo)) then return end
    local R2 = H.TD.MATCH * H.TD.MATCH
    for _, E in ipairs(C.TDisUndo) do
        local O = StaticFindObject(E.Path)
        local TC = A.IsAlive(O) and A.Safe(function() return O.BP_TurretAIComponent end)
        local HostDead = false
        for _, T in pairs(C.TDead) do
            if (E.X - T.X) ^ 2 + (E.Y - T.Y) ^ 2 + (E.Z - T.Z) ^ 2 <= R2 then HostDead = true break end
        end
        if A.IsAlive(TC) and not HostDead then
            pcall(function() TC.Dead = false end)
            pcall(function() TC["Can Attack"] = E.Can0 ~= false end)
            local Mesh = A.IsAlive(A.Safe(function() return O.Turret end))
            U.Log("Geschuetz lokal zurueckgesetzt (Host: %s)%s", tostring(E.Why), Mesh and "" or ", Mesh fehlt (ohne Patch)")
        end
    end
    C.TDisUndo = {}
end

-- Lokaler SP-Ablauf fertig (L_001f gelaufen): Geister-Waffe weg, Host fragen; Ablehnung -> C.TDisUndoStep
function C.TDisSend(O, Now, E)
    local X, Y, Z = U.Loc(O)
    if not X then return end
    X, Y, Z = math.floor(X + 0.5), math.floor(Y + 0.5), math.floor(Z + 0.5)
    C.TDisMark(X, Y, Z, Now)
    C.TDisFindAt = 0
    local Undo = { Path = E and E.Path or U.Path(O), Can0 = E and E.Can0, X = X, Y = Y, Z = Z }
    Net.Request("ai_tdis", string.format("%s|%d|%d|%d", H.TD.CLS, X, Y, Z), function(R, _, Err)
        if R == "ok" then U.Log("Geschuetz beim Host deaktiviert") return end
        local Why = type(R) == "string" and R:match("^no|(.*)$") or Err or "?"
        U.Log("Geschuetz deaktivieren abgelehnt: %s", tostring(Why))
        if Why ~= "aus" then
            pcall(A.ShowNote, Why == "zugriff" and "Kein Zugriff" or "Geschuetz konnte nicht deaktiviert werden")
            if Undo.Path and type(C.TDisUndo) == "table" and #C.TDisUndo < 8 then
                Undo.Why = Why
                C.TDisUndo[#C.TDisUndo + 1] = Undo
            end
        end
    end, 8, nil, 0)
end

-- Host-Zustand ai_tdead auf die lokale Kopie (Klasse + Lage <= 300): Dead, Can Attack aus, Turret-Mesh weg
function C.TDeadStep(Now)
    if not next(C.TDead) or Now < (C.TDeadAt or 0) then return end
    -- Kein FindAllOf, wenn alle Schluessel uebernommen sind (neuer Schluessel / C.Reset setzt TDeadAt = 0)
    local Pend = 0
    for Key in pairs(C.TDead) do
        if not C.TDeadDone[Key] then Pend = Pend + 1 end
    end
    if Pend == 0 then C.TDeadAt = Now + 5 return end
    local L = C.ExtraGet(H.TD.CLS)
    local R2 = H.TD.MATCH * H.TD.MATCH
    local Hit = false
    for Key, T in pairs(C.TDead) do
        if not C.TDeadDone[Key] then
            local O, Best = nil, R2
            for _, Cd in ipairs(L.List) do
                local D = (Cd.X - T.X) ^ 2 + (Cd.Y - T.Y) ^ 2 + (Cd.Z - T.Z) ^ 2
                if D <= Best then O, Best = Cd.Obj, D end
            end
            local TC = A.IsAlive(O) and A.Safe(function() return O.BP_TurretAIComponent end)
            if A.IsAlive(TC) then
                C.TDeadDone[Key], Hit = true, true
                pcall(function() if TC.Dead ~= true then TC.Dead = true end end)
                pcall(function() TC["Can Attack"] = false end)
                local Tu = A.Safe(function() return O.Turret end)
                if A.IsAlive(Tu) then pcall(function() Tu:K2_DestroyComponent(O) end) end
                C.TDisMark(T.X, T.Y, T.Z, Now)
                U.Log("Geschuetz %s beim Host deaktiviert: hier uebernommen", Key)
            end
        end
    end
    -- Unaufgeloeste Schluessel (Geschuetz nicht geladen/andere Welt): seltener suchen
    C.TDeadAt = Now + (Hit and 1 or 5)
end

-- Gast 4 Hz: Eintraege aus dem Hook pruefen (lokaler Timer fertig, Dead gesetzt, nicht mehr gehalten)
function C.TDisStep(Now)
    C.TDisHookTry(Now)
    if not Net.Has("aitd") then C.TDis = {} return end   -- alter Host: lokaler SP-Ablauf bleibt unveraendert
    local Keep = {}
    for _, E in ipairs(C.TDis) do
        local O = StaticFindObject(E.Path)
        local TC = A.IsAlive(O) and A.Safe(function() return O.BP_TurretAIComponent end)
        if A.IsAlive(TC) then
            local Dead = A.Safe(function() return TC.Dead == true end, false)
            if E.Dead0 == nil then
                E.Dead0 = Dead
                E.Can0 = A.Safe(function() return TC["Can Attack"] end)
            end
            local Dur = tonumber(A.Safe(function() return O.Duration end)) or 0
            if not E.Dead0 and not E.SAt then
                E.SAt = Now   -- Halte-Beginn an den Host (er prueft Duration ab hier); Ablehnung -> Abschluss scheitert
                local X, Y, Z = U.Loc(O)
                if X then
                    Net.Request("ai_tdis", string.format("%s|%d|%d|%d|s", H.TD.CLS, math.floor(X + 0.5),
                        math.floor(Y + 0.5), math.floor(Z + 0.5)), function(R, _, Err)
                        if R ~= "ok" then U.Log("Geschuetz Halte-Beginn abgelehnt: %s", tostring(R or Err)) end
                    end, 8, nil, 0)
                end
            end
            local T0 = math.max(E.At, E.SAt or E.At)
            if not E.Dead0 then
                if Now >= T0 + Dur + 0.3 and Dead and A.Safe(function() return O.IsHeld == false end, false) then
                    C.TDisSend(O, Now, E)
                elseif Now < T0 + Dur + 3 then
                    Keep[#Keep + 1] = E   -- sonst: vorzeitig losgelassen bzw. von vorne -> verwerfen
                end
            end
        end
    end
    C.TDis = Keep
    C.TDeadStep(Now)
    C.TDisUndoStep()
    C.TDisClean(Now)
end

-- 10 Hz: geaenderte Eintraege anwenden (hoechstens MAX_APPLY), Montagen, Ragdoll; 1 Hz: Waechter, Geister, Blutmond,
-- Nahzustand, Markierungen. AI-8: die 1-Hz-Schritte liegen auf verschiedenen Zehnteln (keine 13-20-ms-Spitze je Sekunde)
function C.Fast(Now)
    if Net.Side ~= "client" or not U.On(F.AI) then return end
    if U.Busy(C) then return end
    C.Tick = C.Tick + 1
    local Slot = C.Tick % 10
    Now = Now or os.clock()
    if Slot == 0 and U.On(F.GUARD) then
        local ok, err = pcall(C.GuardPass)
        if not ok then Core.Fail(F.GUARD, err) end
    end
    if Slot == 3 and U.On(F.GHOST) then
        local ok, err = pcall(C.GhostStep)
        if not ok then Core.Fail(F.GHOST, err) end
    end
    -- UE 5.6: Container_AnimalMeat_C gibt es nicht mehr -> ohne geladene Klasse kein FindAllOf ins Leere
    if Slot == 9 and U.On(F.MEAT) and Net.Has("ameat") and Net.Has("ai2")
        and A.IsAlive(A.Safe(function() return StaticFindObject(H.MEAT.CLS) end)) then
        local ok, err = pcall(C.MeatGhosts)
        if not ok then Core.Fail(F.MEAT, err) end
    end
    if Slot == 8 and U.On(F.AIONEAR) and U.On(F.AIO) and U.On(F.GUARD) then
        local ok, err = pcall(C.NearStep)
        if not ok then Core.Fail(F.AIONEAR, err) end
    end
    if Slot == 4 and U.On(F.MARK) then
        local ok, err = pcall(C.MarkStep, Now)
        if not ok then Core.Fail(F.MARK, err) end
    end
    if C.Tick % 600 == 0 then
        -- Merker toter/verschwundener Kopien aufraeumen (Namen werden nicht wiederverwendet).
        -- Steht vor dem ai2-Return: GuardPass/NearStep fuellen Guarded/NearDone/AddrC auch ohne ai2 (alter Host)
        local Live = {}
        for _, O in ipairs(A.Characters() or {}) do
            local Name = A.IsAlive(O) and U.Name(O)
            if Name then Live[Name] = true end
        end
        for Name in pairs(C.Guarded) do if not Live[Name] then C.Guarded[Name] = nil end end
        for Name in pairs(C.NearDone) do if not Live[Name] then C.NearDone[Name] = nil end end
        for Addr, E in pairs(C.AddrC) do if not Live[E.Name] then C.AddrC[Addr] = nil end end
        for Name, Key in pairs(C.BoundBy) do if not Live[Name] and C.E[Key] and C.E[Key].Fam ~= "t" and C.E[Key].Fam ~= "n" then C.Unbind(Key) end end
    end
    if not Net.Has("ai2") then return end
    if Slot == 6 and U.On(F.BM) then
        local ok, err = pcall(C.BloodStep)
        if not ok then Core.Fail(F.BM, err) end
    end
    -- ungebundene Eintraege jede Sekunde neu versuchen, alle 5 s alles neu anwenden
    if C.Tick % 10 == 5 then
        local All = C.Tick % 50 == 5
        for Key, E in pairs(C.E) do if All or not E.Bound then C.Dirty[Key] = true end end
    end
    local Keys = {}
    for Key in pairs(C.Dirty) do
        if #Keys >= K.MAX_APPLY then break end
        Keys[#Keys + 1] = Key
    end
    local Later = {}
    for _, Key in ipairs(Keys) do
        C.Dirty[Key] = nil
        local E = C.E[Key]
        if E then
            local ok, O = pcall(C.Resolve, Key, E, Later)
            E.Bound = ok and O ~= nil
            if E.Bound then
                local okA, err = pcall(C.Apply, Key, E, O)
                if not okA then Core.Fail("ai_apply", err) end
            end
        end
    end
    for _, Key in ipairs(Later) do if C.E[Key] then C.Dirty[Key] = true end end
    if #C.MonQ > 0 then
        local Q = C.MonQ
        C.MonQ = {}
        for _, Data in ipairs(Q) do
            local ok, err = pcall(C.MonOne, Data)
            if not ok then Core.Fail(F.MON, err) end
        end
    end
    if U.On(F.RAG) or U.On(F.GROUND) then C.WatchStep(Now) end
end

-- ---------------------------------------------------------------- Modul

M.Handlers = {
    -- Host -> Gast, Keyed-State: Schluessel = Id bzw. m<FName>, Wert fam;Klasse;qx;qy;qz;hp;max;beh;flags
    ai2 = function(Value, _, Msg)
        if Net.Side ~= "client" or not U.On(F.AI) or type(Msg) ~= "table" or not Msg.Key then return end
        local Key = Msg.Key
        if Value == nil then
            C.E[Key], C.Dirty[Key] = nil, nil
            C.Unbind(Key)
            return
        end
        local E = C.Parse(Value)
        if not E then return Net.SecWarn(Net.Host, "host", "ai2") end
        local Old = C.E[Key]
        if Old then E.Bound = Old.Bound end
        C.E[Key], C.Dirty[Key] = E, true
    end,
    -- Host -> Gast: Montage "key|pfad|tempo|abschnitt|pos" (Enc)
    ai_mon = function(Data)
        if Net.Side ~= "client" or not U.On(F.MON) or type(Data) ~= "string" then return end
        if #C.MonQ < K.MAX_MONQ then C.MonQ[#C.MonQ + 1] = Data end
    end,
    -- Host -> alle, Keyed-State "m" = "1"/"0"
    ai_bm = function(Value)
        if Net.Side ~= "client" then return end
        C.BM = Value
    end,
    -- Gast -> Host, Anfrage "BP_BanditTurret_AI_C|x|y|z": Antwort "ok" | "no|<grund>"
    ai_tdis = function(Data, G, Msg) H.TDisMsg(Data, G, Msg) end,
    -- Host -> alle, Keyed-State "BP_BanditTurret_AI_C@x,y,z" = "1" (nur speichern, Anwenden in C.TDeadStep)
    ai_tdead = function(Value, _, Msg)
        if Net.Side ~= "client" or not U.On(F.TDIS) or type(Msg) ~= "table" or type(Msg.Key) ~= "string" then return end
        local Key = Msg.Key
        if Value == nil then
            C.TDead[Key], C.TDeadDone[Key] = nil, nil
            return
        end
        local X, Y, Z = Key:match("^BP_BanditTurret_AI_C@(%-?%d+),(%-?%d+),(%-?%d+)$")
        if not X then return Net.SecWarn(Net.Host, "host", "ai_tdead_bad") end
        if not C.TDead[Key] then C.TDeadAt = 0 end
        C.TDead[Key] = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }
    end,
}

-- 1 Hz Host: Horde (Tod-Uebergaenge), alle 2 s Blutmond, alle 5 s Invoker/Sicht-Quelle
function M.HostTick()
    if Net.Side ~= "host" or not U.On(F.AI) then return end
    if U.Busy(H) then return end
    H.Slow = H.Slow + 1
    local Pawns = H.GuestPawns()
    if #Pawns > 0 and U.On(F.HORDE) then
        local ok, err = pcall(H.HordeTick, Pawns)
        if not ok then Core.Fail(F.HORDE, err) end
    end
    if #Pawns > 0 and H.Slow % 5 == 0 and U.On(F.INV) then
        local ok, err = pcall(H.InvokerTick, Pawns)
        if not ok then Core.Fail(F.INV, err) end
    end
    if H.Slow % 2 == 0 and U.On(F.BM) then
        local ok, err = pcall(H.BloodTick)
        if not ok then Core.Fail(F.BM, err) end
    end
    if H.Slow % 10 == 3 and A.Coop and A.Coop.Server and U.On(F.GDAYS) then
        local ok, err = pcall(H.GhostDays)
        if not ok then Core.Fail(F.GDAYS, err) end
    end
    if H.Slow % 60 == 7 then pcall(H.PercPrune, Pawns) end
    if U.On(F.HITDIAG) or H.HD.On then
        local ok, err = pcall(H.HitDiag, os.clock(), #Pawns)
        if not ok then Core.Fail(F.HITDIAG, err) end
    end
end

-- Exporte fuer main.lua (Legacy-Gates, gemeinsamer Binder fuer zlook2/amon2)
function M.Exports()
    local Coop = A.Coop
    -- Host: bekommt dieser Gast ai2 (Zombies/Bosse/Menschen) bzw. Tiere ueber ai2?
    Coop.AI2Owns = function(Key) return Net.Side == "host" and U.On(F.AI) and Net.Has("ai2", Key) end
    Coop.AI2Anim = function(Key) return Net.Side == "host" and U.On(F.AI) and U.On(F.ANIM) and Net.Has("anim3", Key) end
    -- Host: alten Montage-Hook (Character:PlayAnimMontage) nicht registrieren
    Coop.AI2NoMonHook = function() return U.On(F.AI) and U.On(F.MON) end
    -- Gast: alte Lua-Schadens-Hooks (GuardPre) nicht registrieren
    Coop.AI2GuestGuard = function() return U.On(F.AI) and U.On(F.GUARD) end
    -- Gast: Z.Resolve-Ersatz. false = nicht zustaendig (Legacy weiter), nil = keine Kopie
    Coop.AI2Resolve = function(Id)
        if not C.Active() or Id == nil then return false end
        local Key = tostring(Id)
        local E = C.E[Key]
        if not E then return false end
        local ok, O = pcall(C.Resolve, Key, E)
        if not ok then return false end
        return O
    end
end

function M.Init(Api)
    A = Api
    H.Reset()
    C.Reset()
    H.Gen, C.Gen = A.WorldGen and A.WorldGen.N, A.WorldGen and A.WorldGen.N
    Net.Cap("ai2", U.On(F.AI))
    Net.Cap("anim3", U.On(F.AI) and U.On(F.ANIM))
    Net.Cap("aitd", U.On(F.AI) and U.On(F.TDIS))
    Net.Cap("ameat", U.On(F.AI) and U.On(F.MEAT))
    M.Exports()
    Net.OnEvent("linked", function()
        if Net.Side == "client" then C.Reset() C.TDead = {} C.LinkedAt = os.clock() end
    end)
    Net.OnEvent("gone", function(Peer)
        if Net.Side == "host" and type(Peer) == "table" and Peer.Key then
            H.Sent[Peer.Key], H.Dead[Peer.Key] = nil, nil
            H.TDisGone[Peer.Key], H.TDisAt[Peer.Key] = true, nil
            H.TDisSAt[Peer.Key], H.TDisHold[Peer.Key] = nil, nil
            -- Runde 9: AI-3 letzte Figur, CORE-30 Warn-Merker je Gast
            H.LastPawn[Peer.Key], H.MeatWarn["tt" .. tostring(Peer.Key)] = nil, nil
        elseif Net.Side ~= "host" then
            C.Reset()
            C.TDead = {}
        end
    end)
    Core.Every("ai_host", 0.2, function() H.Fast() end)
    Core.Every("ai_carcfix", 1, function()
        if Net.Side == "host" and U.On(F.LOOTREP) then H.CarcFixTick() end
        if Net.Side == "host" and U.On(F.MEAT) then
            local ok, err = pcall(H.MeatTick)
            if not ok then Core.Fail(F.MEAT, err) end
        end
    end)
    Core.Every("ai_cli", 0.1, function(Now) C.Fast(Now) end)
    -- ai_tdis: Gast Hook-Eintraege/ai_tdead/Geister-Waffen, Host Warteschlange (4 Hz)
    Core.Every("ai_tdis_cli", 0.25, function(Now)
        if Net.Side == "client" then pcall(C.TDisPatch) end   -- auch ohne Flag/Cap: Patch wieder abschalten
        local okT, errT = pcall(C.TracePatch, Now or os.clock())   -- ai_notrace: beide Seiten (Host schaltet ab)
        if not okT then Core.Fail(F.NOTRACE, errT) end
        if Net.Side ~= "client" or not (U.On(F.AI) and U.On(F.TDIS)) or U.Busy(C) then return end
        local ok, err = pcall(C.TDisStep, Now or os.clock())
        if not ok then Core.Fail(F.TDIS, err) end
    end)
    Core.Every("ai_tdis_host", 0.25, function()
        if Net.Side ~= "host" or not U.On(F.TDIS) then return end
        local ok, err = pcall(H.TDisTick)
        if not ok then Core.Fail(F.TDIS, err) end
    end)
    -- Faehigkeiten nachfuehren: FLAG_DOWN (Core.Fail) zieht ai2/anim3 zurueck, der Peer faellt auf Legacy
    -- (Net.Cap ist ohne Aenderung ein No-op und meldet Aenderungen per h4/h4a)
    Core.Every("ai_caps", 1, function()
        Net.Cap("ai2", U.On(F.AI))
        Net.Cap("anim3", U.On(F.AI) and U.On(F.ANIM))
        Net.Cap("aitd", U.On(F.AI) and U.On(F.TDIS))
        Net.Cap("ameat", U.On(F.AI) and U.On(F.MEAT))
    end)
    A.TestCommands.ai_probe = function()
        if Net.Side == "host" then
            local N, PerG = 0, {}
            for _ in pairs(H.Ent) do N = N + 1 end
            for Key, S in pairs(H.Sent) do
                local C2 = 0
                for _ in pairs(S) do C2 = C2 + 1 end
                PerG[#PerG + 1] = Key:match("([^%.]+)$") .. "=" .. C2
            end
            A.TestLog("ai_probe Host: %d Eintraege, je Gast %s, Sicht-Quellen %d, Blutmond %s", N,
                table.concat(PerG, ","), (function() local X = 0 for _ in pairs(H.Perc) do X = X + 1 end return X end)(),
                tostring(H.BM))
        else
            local N, B, W = 0, 0, 0
            for _, E in pairs(C.E) do N = N + 1 if E.Bound then B = B + 1 end end
            for _ in pairs(C.Watch) do W = W + 1 end
            A.TestLog("ai_probe Gast: %d Eintraege, %d gebunden, %d angewendet, %d Tier-Tode, %d Montagen, %d Ragdoll-Wachen, cap=%s",
                N, B, C.Applied, C.Deaths, C.Mons, W, tostring(Net.Has("ai2")))
        end
    end
    -- AI-6: Zustand der KI-Kopien <= 10 m (Mesh-/Bewegungs-Tick, bPauseAnims, Sichtbarkeit) - nur Gast
    A.TestCommands.ai_aiocheck = function()
        if Net.Side == "host" then return A.TestLog("ai_aiocheck: nur beim Gast (Kopien der Host-KI)") end
        local ok, err = pcall(C.AioCheck)
        if not ok then A.TestLog("ai_aiocheck Fehler: %s", tostring(err)) end
    end
    U.Log("geladen (ai_v2=%s, animal_v3=%s, ai_tdis=%s, ai_looted=%s)", tostring(U.On(F.AI)), tostring(U.On(F.ANIM)),
        tostring(U.On(F.TDIS)), tostring(U.On(F.LOOTED)))
end

return M
