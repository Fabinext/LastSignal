-- Last Signal, Runde 5: Lebenswerte v2 (vit_v2). Grundlage: _NetTest\analysis\findings\vit.md
-- Host autoritativ fuer Leben/Hunger/Durst/Strahlung/Sauerstoff/Medical-Flags/Feuer (Effekte laufen im Spiel auf
-- dem Server), Ausdauer sagt der Gast selbst voraus (Spiel), Laufgeschwindigkeit ist gast-autoritativ (wie im Spiel).
-- PawnKey = Net.PawnKey ("p<PlayerId>", sonst "n<FName>"): FNames von Laufzeit-Figuren sind auf Host und Gast VERSCHIEDEN
--   vit2   Host -> besitzender Gast, Keyed-State P1, Schluessel "self": "<PawnKey>|h;mh;hu;th;ra;ox;flags;tl"
--          (tl = InfectionTimeLeft des Hosts, -1 ohne Infektion; UE 5.6, alte Gegenstellen lesen nur 7 Felder)
--   vit2j  Host -> Gast, P0 einmalig bei Spruengen: "<PawnKey>|<h;...;flags;tl>"
--   vit_fx Host -> alle, Keyed-State: [PawnKey] = "1" solange die Figur brennt
--   vit_rm Gast -> Host, P0: "<PawnKey>|Bleed,Heavy,Broken,Infection,Subdue" (Effekt beim Gast beendet/eingedaemmt:
--          Stop-Timer/Bandage/Heilmittel; UE 5.6: CLIENT_RemoveMedicalEffect ist NetClient wie vorher Client_RemoveEffect)
--   vit_rg Gast -> Host, P1: "<PawnKey>|<Zuwachs>" (lokale Regeneration/Sitzen mit eigenem Skill)
--   vit_mv Gast -> Host, Keyed-State P0, Schluessel "m": "<PawnKey>|walk;crouch;swim;jump"
--   Faehigkeit vitinf (Runde 10): Host fuehrt Infektion (vit_v2 + vit_infect an, nicht Down) und meldet Bit 128;
--          nur dann gleicht der Gast ein "nur lokales" Infection? an (sonst waere es eine echte, replizierte Infektion)
-- Flag-Bits: 1 Bleed, 2 HeavyBleed, 4 BrokenBone, 8 RadiationSickness, 16 Burning, 32 tot, 64 unter Wasser,
--            128 Infektion (UE 5.6, MedicalComponent_C.Infection?)
-- Runde 9: vit_rm_check (Heilung nur mit Ablaufzeit oder Verbrauch), vit_regen_check (Pause nach Schaden, Kappe nach
--   Spielrate), vit_stale_clear (kein Wert der toten Figur), vit_infect_local (Phantom-Infektion beim Gast nach 3 s weg),
--   GuestFx nur ueber Spielerfiguren. E31-Wrapper ueber main.lua V (Coop.Stats = A.V): skill_mult, vit_med_persist,
--   stats_persist, werte_atomic (Abschnitt "Werte-Datei").
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local A

local FLAG = "vit_v2"
local F = { Move = "vit_move", Fx = "vit_fx", Regen = "vit_regen", Rm = "vit_rm", Timers = "vit_timers",
            RegenMax = "vit_regen_max", Infect = "vit_infect",
            -- Runde 9
            RmCheck = "vit_rm_check", RegenCheck = "vit_regen_check", Stale = "vit_stale_clear",
            InfLocal = "vit_infect_local", Mult = "skill_mult", Med = "vit_med_persist", Stats = "stats_persist",
            Atomic = "werte_atomic" }
local BIT = { Bleed = 1, Heavy = 2, Broken = 4, Rad = 8, Burn = 16, Dead = 32, Under = 64, Infect = 128 }
-- Medical-Effekte: Name im Netz -> Flag-Property, Bit, Loesch-Funktion der Komponente
-- Infektion (UE 5.6): Host heilt mit InfectionState(true) (wie CLIENT_RemoveMedicalEffect @0329). Keine Gast-Korrektur
-- "nur lokal" (NoLocalFix): Infection? ist nativ repliziert und wird beim Gast nie selbst gesetzt.
local EFFECTS = {
    { Name = "Bleed", Prop = "Bleed?", Bit = 1, Stop = "Time_Bleed" },
    { Name = "Heavy", Prop = "HeavyBleed?", Bit = 2, Stop = "Time_HeavyBleed" },
    { Name = "Broken", Prop = "BrokenBone?", Bit = 4, Stop = "Time_BrokenBone" },
    { Name = "Infection", Prop = "Infection?", Bit = 128, Stop = "InfectionState", Arg = true,
      NoLocalFix = true, Flag = "vit_infect" },
}
-- Grenzen fuer vit_mv (cm/s), Schutz gegen Unsinn
local MV_MAX = { 1500, 800, 1200, 1200 }

local HS = {}            -- Host: [Gast-Key] = { Pawn, H, Applied, JH, LastF, FlagAt = {[bit]=t}, RmN, RmAt, RgAt, MvLog }
local GS = { Fx = {} }   -- Gast: eigener Zustand (siehe ResetGuest), Fx = [PawnName] = true/false (vom Host)
local Fx = { Sent = {}, Gen = nil }   -- Host: zuletzt gemeldete brennende Figuren
-- Runde 9: Pruefungen (Heilung, Regeneration, Phantom-Infektion; Bad/LogAt je Gast-Key) und Werte-Datei-Wrapper (unten)
local VC = { Cure = {}, CureAt = -999, Bad = {}, LogAt = {}, Mult = 1, MultAt = -99 }
local VW = { Wraps = {}, Saving = false, Skip = false }

local function Log(fmt, ...) A.Log("[Vit] " .. fmt, ...) end
local function On() return Core.Flag(FLAG, true) == true end
local function Sub(Name) return On() and Core.Flag(Name, true) == true end
local function Abs(X) return X < 0 and -X or X end
local function HasBit(Flags, Bit) return math.floor((Flags or 0) / Bit) % 2 == 1 end

local function Loading()
    local W = A.WorldGen
    return W and W.Loading and (os.clock() - (W.LoadingAt or 0)) < 60
end

local function KSL()
    local K = A.Safe(function() return A.UEHelpers.GetKismetSystemLibrary() end)
    return A.IsAlive(K) and K or nil
end

local function NameOf(Obj)
    return A.Safe(function() return Obj:GetFName():ToString() end)
end

-- netzweiter Schluessel einer Spielerfigur (nie die FName senden)
local function KeyOf(Pawn)
    return A.Safe(function() return Net.PawnKey(Pawn) end) or "self"
end

-- empfangener PawnKey passt zur lokalen Figur? ("self"/"n..." ohne PlayerState: Kanal ist schon dem Gast zugeordnet)
local function KeyOk(Got, Pawn)
    if type(Got) ~= "string" or Got == "" then return false end
    if Got == "self" or Got:sub(1, 1) == "n" then return true end
    local Mine = A.Safe(function() return Net.PawnKey(Pawn) end)
    return Mine == nil or Mine:sub(1, 1) == "n" or Mine == Got
end

local function ClearTimer(Obj, FnName)
    local K = KSL()
    if K then pcall(function() K:K2_ClearTimer(Obj, FnName) end) end
end

-- Effekt aktiv? (Infektion nur mit vit_infect)
local function Use(E)
    return E.Flag == nil or Sub(E.Flag)
end

-- Effekt beenden wie das Spiel (Time_* ohne Parameter, InfectionState(Cure?=true))
local function StopEffect(Med, E)
    if E.Arg == nil then return Med[E.Stop](Med) end
    return Med[E.Stop](Med, E.Arg)
end

-- Hunger/Durst-Komponente: UE 5.6 heisst die Pawn-Eigenschaft "Hunger&ThirstComponent" (BP_PlayerCharacter_C @0x7D0),
-- UE 5.3 "HungerThirstComponent"
local function HTOf(Pawn)
    local HT = A.Safe(function() return Pawn["Hunger&ThirstComponent"] end)
    if A.IsAlive(HT) then return HT end
    HT = A.Safe(function() return Pawn.HungerThirstComponent end)
    return A.IsAlive(HT) and HT or nil
end

-- ---------------------------------------------------------------- Werte lesen / kodieren

-- Host: Werte einer Figur (nil bei Fehler)
local function ReadVitals(Pawn)
    local ok, V = pcall(function()
        local Med, HT = Pawn.MedicalComponent, HTOf(Pawn)
        local Rad, Swim = Pawn.RadiationComponent, Pawn.SwimmingComponent
        if not (A.IsAlive(Med) and A.IsAlive(HT) and A.IsAlive(Rad)) then return nil end
        if not A.IsAlive(Swim) then Swim = nil end
        local T = { h = Med.Health, mh = Med.MaxHealth, hu = HT.CurrentHunger, th = HT.CurrentThirst,
                    ra = Rad.CurrentRadiation, ox = Swim and A.Safe(function() return Swim.CurrentOxygen end, 100) or 100 }
        local Flags = 0
        for _, E in ipairs(EFFECTS) do
            if Use(E) and A.Safe(function() return Med[E.Prop] == true end, false) then Flags = Flags + E.Bit end
        end
        if HasBit(Flags, BIT.Infect) then
            local TL = A.Safe(function() return Med.InfectionTimeLeft end)
            if type(TL) == "number" then T.tl = TL end
        end
        if Med["RadiationSickness?"] then Flags = Flags + BIT.Rad end
        if Pawn["Burning?"] then Flags = Flags + BIT.Burn end
        if Pawn["PlayerDead?"] then Flags = Flags + BIT.Dead end
        if Swim and A.Safe(function() return Swim["UnderWater?"] end, false) then Flags = Flags + BIT.Under end
        T.f = Flags
        return T
    end)
    if ok and type(V) == "table" and type(V.h) == "number" then return V end
    return nil
end

local function Encode(V)
    return string.format("%.2f;%.1f;%.1f;%.1f;%.1f;%.1f;%d;%.0f", V.h, V.mh, V.hu, V.th, V.ra, V.ox or 100, V.f or 0,
        V.tl or -1)
end

local function Decode(Text)
    local N = {}
    for Part in tostring(Text or ""):gmatch("[^;]+") do N[#N + 1] = tonumber(Part) end
    if #N < 7 then return nil end
    local TL = N[8]   -- fehlt bei alten Hosts (UE 5.3)
    return { h = N[1], mh = N[2], hu = N[3], th = N[4], ra = N[5], ox = N[6], f = math.floor(N[7]),
             tl = (TL and TL >= 0) and TL or nil }
end

-- ---------------------------------------------------------------- Host

local function HostState(Key, PawnName)
    local St = HS[Key]
    if not St or St.Pawn ~= PawnName then
        St = { Pawn = PawnName, FlagAt = {}, Applied = 0, RmN = 0, RmAt = 0 }
        HS[Key] = St
    end
    return St
end

-- Host-eigene Regeneration auf Gast-Figuren (Skill des Geists ueber GetPlayerController(0)) stoppen: Der Gast
-- regeneriert mit seinem eigenen Skill und meldet den Zuwachs (vit_rg).
local function StopHostRegen(Pawn, St, V)
    if not Sub(F.Regen) or not St.H then return end
    local Rise = V.h - St.H - (St.Applied or 0)
    if Rise > 0.001 and Rise <= 0.6 and V.h <= 80.6 and not HasBit(V.f, BIT.Dead) then
        ClearTimer(Pawn, "RegenHealth")
        local Back = St.H + (St.Applied or 0)
        if pcall(function()
            local Med = Pawn.MedicalComponent
            if not A.IsAlive(Med) then error("keine MedicalComponent") end
            Med.Health = Back
        end) then V.h = Back end
        if not St.RegenLogged then
            St.RegenLogged = true
            Log("Host-Regeneration auf %s gestoppt (Gast regeneriert selbst)", St.Pawn)
        end
    end
end

local function HostGuest(G, Key, Pawn, Now)
    local Name = NameOf(Pawn)   -- host-lokal (Respawn-Erkennung), wird nicht gesendet
    if not Name then return end
    local PK = Net.Enc(KeyOf(Pawn))
    local St = HostState(Key, Name)
    local V = ReadVitals(Pawn)
    if not V then return end
    StopHostRegen(Pawn, St, V)
    -- vit_regen_check: Schaden seit dem letzten Takt (Leben unter Stand + gemeldetem Zuwachs) -> Regenerationspause (OnRg)
    if St.H and V.h < St.H + (St.Applied or 0) - 0.05 then St.DropAt = Now end
    for _, E in ipairs(EFFECTS) do
        local Now1 = Use(E) and HasBit(V.f, E.Bit)
        if Now1 and not HasBit(St.LastF or 0, E.Bit) then St.FlagAt[E.Bit] = Now end
    end
    local Text = Encode(V)
    Net.State("vit2", "self", PK .. "|" .. Text, 1, G)
    local Jump = St.LastF ~= V.f or not St.JH or Abs(V.h - St.JH) >= 5
    if Jump then
        Net.Send("vit2j", PK .. "|" .. Text, G, 0)
        St.JH = V.h
    end
    St.LastF, St.H, St.Applied = V.f, V.h, 0
end

-- Feuer aller Spielerfiguren an alle (Burning? ist nicht repliziert)
local function HostFx()
    if not Sub(F.Fx) then return end
    local Seen = {}
    local function Check(Pawn)
        if not A.IsAlive(Pawn) then return end
        local PK = A.Safe(function() return Net.PawnKey(Pawn) end)
        if not PK then return end
        local Burning = A.Safe(function() return Pawn["Burning?"] == true end, false)
        if Burning then Seen[PK] = true end
    end
    Net.ForEachGuest(function(G)
        local PC = G.Epoch and Net.PC(G)
        if PC then Check(A.Safe(function() return PC:K2_GetPawn() end)) end
    end)
    if not A.Settings.server then Check(A.OwnPawn()) end   -- normaler Host: eigene Figur auch
    for Name in pairs(Seen) do
        if not Fx.Sent[Name] then Net.State("vit_fx", Name, "1", 1) Fx.Sent[Name] = true end
    end
    for Name in pairs(Fx.Sent) do
        if not Seen[Name] then Net.State("vit_fx", Name, nil, 1) Fx.Sent[Name] = nil end
    end
end

local function HostTask(Now)
    if Net.Side ~= "host" or not On() or Loading() then return end
    if Fx.Gen ~= (A.WorldGen and A.WorldGen.N) then Fx.Gen, HS, Fx.Sent = A.WorldGen and A.WorldGen.N, {}, {} end
    local Stale = Sub(F.Stale)
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch or not Net.Has("vit2", G) then return end
        local PC = G.PawnName and Net.PC(G)
        local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
        -- vit_stale_clear (PLAYER-17): ohne lebende Figur keinen alten Wert stehen lassen. Die Vollauffrischung nach dem
        -- Respawn schickte sonst die Werte der toten Figur (Leben-Flackern, Rotblitz); der Gast ignoriert nil.
        if not A.IsAlive(Pawn) or (Stale and VC.Dead(Pawn)) then
            if Stale then Net.State("vit2", "self", nil, 1, G) end
            return
        end
        local ok, err = pcall(HostGuest, G, Key, Pawn, Now)
        if not ok and Core.Fail(FLAG, err) then Log("vit2 aus (Fehler): %s", tostring(err)) end
    end)
    local ok, err = pcall(HostFx)
    if not ok then Core.Fail(F.Fx, err) end
end

-- Host, 10 Hz: Bewegungswerte des Gasts auf die Host-Kopie (ohne RPC/Multicast), damit kein Rubberbanding entsteht
local function HostMove()
    if Net.Side ~= "host" or not Sub(F.Move) or Loading() then return end
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch or not Net.Has("vit2", G) then return end
        local Text = Net.Get("vit_mv", "m", G)
        local PK, Vals = tostring(Text or ""):match("^([^|]+)|(.+)$")
        if not PK then return end
        local N = {}
        for Part in Vals:gmatch("[^;]+") do N[#N + 1] = tonumber(Part) end
        if #N < 4 then return end
        local PC = Net.PC(G)
        local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
        if not A.IsAlive(Pawn) or not KeyOk(Net.Dec(PK), Pawn) then return end
        local ok, err = pcall(function()
            local CM = Pawn.CharacterMovement
            if not A.IsAlive(CM) then return end
            local Fields = { "MaxWalkSpeed", "MaxWalkSpeedCrouched", "MaxSwimSpeed", "JumpZVelocity" }
            for I, Field in ipairs(Fields) do
                local Want = math.max(0, math.min(MV_MAX[I], N[I] or 0))
                if N[I] and Abs(CM[Field] - Want) > 1 then CM[Field] = Want end
            end
        end)
        if not ok and Core.Fail(F.Move, err) then Log("vit_move aus: %s", tostring(err)) end
    end)
end

-- Host: Gast hat einen Medical-Effekt beendet (Stop-Timer laufen nur beim Gast, Client_RemoveEffect ist NetClient)
local function OnRm(Data, G, Msg)
    if Net.Side ~= "host" or not Sub(F.Rm) or type(G) ~= "table" then return end
    local PK, List = tostring(Data or ""):match("^([^|]*)|([%w,]*)$")
    if not PK then return Net.SecWarn(G, G.Key, "vit_rm") end
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or not KeyOk(Net.Dec(PK), Pawn) then return end
    local Name = NameOf(Pawn)   -- host-lokal
    if not Name or Name ~= G.PawnName then return end
    local St = HostState(G.Key, Name)
    local Now = os.clock()
    if Now - (St.RmAt or 0) > 1 then St.RmAt, St.RmN = Now, 0 end
    St.RmN = St.RmN + 1
    if St.RmN > 4 then return Net.SecWarn(G, G.Key, "vit_rm_rate") end
    local Med = A.Safe(function() return Pawn.MedicalComponent end)
    if not A.IsAlive(Med) then return end
    -- vit_rm_check: Tod beendet alles (CLIENT_RemoveMedicalEffect @34ef/@35b0), Bruch-Ablauf auch Blutung (@081e/@082e)
    local Free = VC.Dead(Pawn)
    local BoneEnd = List:find("Broken", 1, true) ~= nil and A.Safe(function() return Med["BrokenBone?"] == true end, false)
        and VC.TimeOk(St, "Broken", BIT.Broken, Now)
    for Want in List:gmatch("[^,]+") do
        for _, E in ipairs(EFFECTS) do
            if E.Name == Want and Use(E) and A.Safe(function() return Med[E.Prop] == true end, false)
                and Now - (St.FlagAt[E.Bit] or 0) >= 1
                and VC.CureAllowed(G, St, E.Name, E.Bit, Now, Free or (BoneEnd and E.Bit <= BIT.Heavy)) then
                local ok, err = pcall(StopEffect, Med, E)
                if ok then Log("%s: %s beendet (vom Gast)", Name, E.Name)
                elseif Core.Fail(F.Rm, err) then Log("vit_rm aus: %s", tostring(err)) end
            end
        end
        -- Eindaemmen (UE 5.6, CLIENT_RemoveMedicalEffect 'Subdue' -> InfectionState(false) @0339): nur beim Gast gelaufen
        if Want == "Subdue" and Sub(F.Infect) and Now - (St.SubAt or -99) >= 5
            and A.Safe(function() return Med["Infection?"] == true end, false) then
            St.SubAt = Now
            if VC.CureAllowed(G, St, "Subdue", BIT.Infect, Now, Free) then
                local ok, err = pcall(function() Med:InfectionState(false) end)
                if ok then Log("%s: Infektion eingedaemmt (vom Gast)", Name)
                elseif Core.Fail(F.Infect, err) then Log("vit_infect aus: %s", tostring(err)) end
            end
        end
    end
end

-- Host: lokaler Lebenszuwachs des Gasts (Regeneration/Sitzen mit eigenem Skill), Rate geprueft
local function OnRg(Data, G)
    if Net.Side ~= "host" or not Sub(F.Regen) or type(G) ~= "table" then return end
    local PK, Amount = tostring(Data or ""):match("^([^|]*)|([%d%.]+)$")
    Amount = tonumber(Amount)
    if not PK or not Amount then return Net.SecWarn(G, G.Key, "vit_rg") end
    if Amount <= 0 then return end
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not A.IsAlive(Pawn) or not KeyOk(Net.Dec(PK), Pawn) then return end
    local Name = NameOf(Pawn)   -- host-lokal
    if not Name or Name ~= G.PawnName then return end
    local St = HostState(G.Key, Name)
    local Now = os.clock()
    -- vit_regen_check: RegenHealth startet erst 4 s nach dem letzten Treffer (RetriggerableDelay @13055/@1487d; hier 3 s
    -- Spielraum fuer die Laufzeit), unterwegs gewesene Meldungen davor verfallen still
    local Check = Sub(F.RegenCheck)
    if Check and Now - (St.DropAt or -99) < 3 then St.RgAt = Now return end
    local Dt = math.max(0.1, math.min(2, Now - (St.RgAt or (Now - 0.5))))
    St.RgAt = Now
    local Max = (tonumber(Core.Flag(F.RegenMax, 3)) or 3) * Dt + 0.3
    if Check then
        -- Spielrate 0,8 x Multiplikator je s, doppelter Spielraum; vit_regen_max bleibt die Obergrenze
        local Cap = 0.8 * VC.RegenMult() * 2.0 * Dt + 0.3
        if Cap < Max then Max = Cap end
    end
    if Amount > Max then
        if Check then VC.RegenExcess(G, St, Amount, Max, Now) end
        Amount = Max
    end
    if A.Safe(function() return Pawn["PlayerDead?"] end, true) then return end
    local ok, err = pcall(function()
        local Med = Pawn.MedicalComponent
        if not A.IsAlive(Med) then return end
        local H = Med.Health
        if H <= 0 then return end
        local New = math.min(H + Amount, math.max(H, 80.5), Med.MaxHealth)
        if New > H then
            Med.Health = New
            St.Applied = (St.Applied or 0) + (New - H)
        end
    end)
    if not ok and Core.Fail(F.Regen, err) then Log("vit_regen aus: %s", tostring(err)) end
end

-- ---------------------------------------------------------------- Pruefungen (Runde 9)
-- vit_rm_check (PLAYER-8, Zahl: 0 aus, 1 nur melden, 2 ablehnen ab der 2. unbeglaubigten Heilung in 10 min, die erste
-- gilt): Der Host beendet einen Effekt auf Meldung des Gasts nur, wenn die Spielzeit abgelaufen ist (MedicalComponent_C
-- Event_TimeToStop*: Blutung @059c 10-12 s, starke @0698 14-16 s, Bruch @077d 180-360 s, ab Host-Beginn St.FlagAt) oder
-- das Server-Inventar gerade ein passendes Heilmittel verbraucht hat (JigsawItem_DataAsset_C.RemoveMedicalEffects, Ledger
-- A.Coop.Inv.LastConsume, 15 s). Sonst Net.SecWarn. Debug-Menue (InfectionStateButton @1f41) und veraenderte Gaeste
-- heilen so nicht mehr unbemerkt.
VC.MIN_T = { Bleed = 9.5, Heavy = 13.5, Broken = 179 }

function VC.TimeOk(St, Name, Bit, Now)
    local Min = VC.MIN_T[Name]
    return Min ~= nil and Now - (St.FlagAt[Bit] or Now) >= Min
end

-- [Effekt] = { Lua-Muster gegen den Daten-Asset-Pfad, ... } aller Gegenstaende, die ihn entfernen (60 s Cache)
function VC.CureItems(Name)
    local Now = os.clock()
    if Now - VC.CureAt >= 60 then
        VC.CureAt = Now
        local Map = {}
        for _, DA in ipairs(A.Safe(function() return FindAllOf("JigsawItem_DataAsset_C") end) or {}) do
            local Short = A.IsAlive(DA) and NameOf(DA)
            local Arr = Short and A.Safe(function() return DA.RemoveMedicalEffects end)
            if Arr then
                pcall(function()
                    Arr:ForEach(function(_, E)
                        local N = E:get():ToString()
                        Map[N] = Map[N] or {}
                        Map[N][#Map[N] + 1] = "%." .. (Short:lower():gsub("%W", "%%%0")) .. "$"
                    end)
                end)
            end
        end
        VC.Cure = Map
    end
    return VC.Cure[Name] or {}
end

function VC.CureOk(G, St, Name, Bit, Now)
    if VC.TimeOk(St, Name, Bit, Now) then return true end
    local Inv = A.Coop and A.Coop.Inv
    if type(Inv) ~= "table" or type(Inv.LastConsume) ~= "function" then return true end   -- Ledger fehlt: altes Verhalten
    if Core.Flag("inv_v2a", true) ~= true and Core.Flag("inv_v2b", true) ~= true then return true end   -- Ledger aus
    local Pats = VC.CureItems(Name)
    if #Pats == 0 then return true end   -- kein Heilmittel bekannt: nicht pruefbar
    -- vit_rm_open: Einzel-Abnahmen bei offener Kiste/Haendler mitzaehlen (ls_inv H.ConsOpen, nur mit inv_cons_open).
    -- Abwaegung: ein Verschieben von genau 1 Heilmittel in die offene Kiste gilt dann auch als Nachweis; vertretbar,
    -- weil Stufe 1 von vit_rm_check nur meldet. 0 = alter Aufruf mit 2 Argumenten (nur Abnahmen ohne offene Kiste)
    local AllowOpen = Core.Flag("vit_rm_open", true) == true
    for _, Pat in ipairs(Pats) do
        local ok, T
        if AllowOpen then ok, T = pcall(Inv.LastConsume, G.Key, Pat, true) else ok, T = pcall(Inv.LastConsume, G.Key, Pat) end
        if ok and type(T) == "number" and Now - T <= 15 then return true end
    end
    return false
end

-- OnRm: true = Effekt beenden. Free = ohne Pruefung (Tod, Bruch-Ablauf beendet auch die Blutung)
function VC.CureAllowed(G, St, Name, Bit, Now, Free)
    local Mode = tonumber(Core.Flag(F.RmCheck, 1)) or 0
    if Mode <= 0 or Free then return true end
    local ok, Good = pcall(VC.CureOk, G, St, Name, Bit, Now)
    if not ok then
        if Core.Fail(F.RmCheck, Good) then Log("vit_rm_check aus: %s", tostring(Good)) end
        return true
    end
    if Good then return true end
    local L = {}
    for _, T in ipairs(VC.Bad[G.Key] or {}) do if Now - T <= 600 then L[#L + 1] = T end end
    L[#L + 1] = Now
    VC.Bad[G.Key] = L
    local Deny = Mode >= 2 and #L >= 2
    Net.SecWarn(G, G.Key, "vit_rm_cure")
    if Now - (VC.LogAt[G.Key] or -99) >= 10 then
        VC.LogAt[G.Key] = Now
        Log("%s: %s ohne Heilmittel oder Ablaufzeit beendet (%d in 10 min)%s", tostring(G.GuestId or G.Key), Name, #L,
            Deny and " - abgelehnt" or (Mode >= 2 and " - erste, angenommen" or " - nur gemeldet"))
    end
    return not Deny
end

-- vit_regen_check (PLAYER-9): Spielrate RegenHealth = 0,08 x Difficulty.RegenMultiplier je 0,1 s (5 s Cache)
function VC.RegenMult()
    local Now = os.clock()
    if Now - VC.MultAt >= 5 then
        VC.MultAt = Now
        local CU = A.Safe(function() return StaticFindObject("/Script/AutoSettings.Default__ConsoleUtils") end)
        local Val = A.IsAlive(CU) and tonumber(A.Safe(function() return CU:GetFloatCVar(FName("Difficulty.RegenMultiplier")) end)) or nil
        VC.Mult = (Val and Val >= 0) and Val or 1
    end
    return VC.Mult
end

-- Ueberschuss einer Regenerations-Meldung melden (deutlich zu viel -> Net.SecWarn); gekappt wird im Aufrufer
function VC.RegenExcess(G, St, Amount, Max, Now)
    if Amount > 2 * Max then Net.SecWarn(G, G.Key, "vit_rg_cap") end
    if Now - (St.RgLogAt or -99) >= 30 then
        St.RgLogAt = Now
        Log("Regeneration von %s gekappt: %.2f gemeldet, %.2f erlaubt", tostring(G.GuestId or G.Key), Amount, Max)
    end
end

-- vit_infect_local (AI-1): lokale Infektion ohne Host-Bit beenden wie InfectionState(true) @001c-@0052, aber ohne die
-- Meldung "Infection cured" (es gab nie eine): Flag aus, OnRep (Timer/Anzeige weg), Schadens-Timer weg
function VC.LocalStop(Med, E)
    if not E.NoLocalFix then return StopEffect(Med, E) end
    Med[E.Prop] = false
    pcall(function() Med["OnRep_" .. E.Prop](Med) end)
    ClearTimer(Med, "InfectionDamage")
end

function VC.Dead(Pawn) return A.Safe(function() return Pawn["PlayerDead?"] == true end, false) end

-- CORE-31: Spielerfiguren fuer GuestFx (Feuer-Merker gibt es nur fuer sie): Coop.Scan (E30), sonst A.PlayerPawns
function VC.Players()
    local Scan = A.Coop and A.Coop.Scan
    if type(Scan) == "function" then
        local ok, L = pcall(Scan, "BP_PlayerCharacter_C", 0.25)
        if ok and type(L) == "table" then return L end
    end
    if type(A.PlayerPawns) == "function" then
        local ok, L = pcall(A.PlayerPawns)
        if ok and type(L) == "table" then return L end
    end
    return A.Safe(function() return FindAllOf("BP_PlayerCharacter_C") end) or {}
end

-- ---------------------------------------------------------------- Gast

local function ResetGuest(Name)
    local Keep = GS.Fx
    GS = { Name = Name, Fx = Keep, Lf = {}, LfAt = {}, OnlyLocal = {}, RmAt = {}, RmTry = {}, Gain = 0,
           GainSent = 0, MirAt = 0, FxAt = 0, Gen = A.WorldGen and A.WorldGen.N }
end

local function UI(Pawn)
    local W = A.Safe(function() return Pawn.InGameUI end)
    return A.IsAlive(W) and W or nil
end

-- Host-Werte in die eigene Kopie schreiben (Fresh = gerade empfangen, sonst Nachpflege aus dem Task)
local function Mirror(Pawn, V, Fresh)
    local Med = Pawn.MedicalComponent
    if not A.IsAlive(Med) then return end
    local W = UI(Pawn)
    local Now = os.clock()
    local L = Med.Health
    local Prev = GS.PrevH
    local Regen = (Now - (GS.GainAt or -99)) < 1.5
    local Write = Abs(L - V.h) > 0.05
    -- lokale Regeneration ist dem Host voraus: nicht zuruecksetzen, solange der Host nicht faellt
    if Write and Regen and V.h < L and (Prev == nil or V.h >= Prev - 0.01) then Write = false end
    if Write then
        Med.Health = V.h
        GS.LastL = V.h
        if W then pcall(function() W:UpdateHealth(V.h) end) end
        local Damage = V.h < L
        pcall(function() Pawn:SetPostProcessHealth(Damage) end)
    end
    if Abs((Med.MaxHealth or 0) - V.mh) > 0.05 then Med.MaxHealth = V.mh end
    if Fresh and Prev and V.h > 0 and not HasBit(V.f, BIT.Dead) then
        if V.h < Prev - 0.05 then
            pcall(function() Pawn:Event_RegenerateHealth() end)   -- wie ReceiveAnyDamage, mit eigenem Skill
            local Heavy, Bleed = HasBit(V.f, BIT.Heavy), HasBit(V.f, BIT.Bleed)
            if W and (Heavy or Bleed) and Prev - V.h <= 7 then
                pcall(function() W:MedicalUIAnimation(FName(Heavy and "Heavy" or "Bleed")) end)
            end
        elseif V.h >= Prev + 1 then
            pcall(function() Pawn:Event_RegenerateHealth() end)   -- wie ConsumeItem
        end
    end
    if Fresh then GS.PrevH = V.h end
    -- Infektion (UE 5.6): InfectionTimeLeft ist nicht repliziert, der lokale Infection-Timer laeuft beim Gast mit.
    -- Host-Wert uebernehmen, ausser ein noch nicht gemeldetes Eindaemmen (lokaler Anstieg) steht aus.
    if V.tl and HasBit(V.f, BIT.Infect) and GS.Lf and GS.Lf.Infection and Sub(F.Infect) then
        local TL = A.Safe(function() return Med.InfectionTimeLeft end)
        if type(TL) == "number" and Abs(TL - V.tl) > 3 and not (GS.InfTL and TL > GS.InfTL + 20) then
            Med.InfectionTimeLeft = V.tl
            GS.InfTL = V.tl
        end
    end
    local HT, Rad = HTOf(Pawn), Pawn.RadiationComponent
    if A.IsAlive(HT) and Abs(HT.CurrentHunger - V.hu) > 3 then   -- repliziert: nur Sicherheitsnetz (Beitritt, eigener Spielstand)
        HT.CurrentHunger = V.hu
        if W then pcall(function() W:UpdateHunger(V.hu) end) end
    end
    if A.IsAlive(HT) and Abs(HT.CurrentThirst - V.th) > 3 then
        HT.CurrentThirst = V.th
        if W then pcall(function() W:UpdateThirst(V.th) end) end
    end
    if A.IsAlive(Rad) and Abs(Rad.CurrentRadiation - V.ra) > 3 then
        Rad.CurrentRadiation = V.ra
        if W then pcall(function() W:UpdateRadiation(V.ra) end) end
    end
    local Swim = A.Safe(function() return Pawn.SwimmingComponent end)
    if A.IsAlive(Swim) and V.ox then
        local Ox = A.Safe(function() return Swim.CurrentOxygen end)
        if type(Ox) == "number" and Abs(Ox - V.ox) > 5 then
            Swim.CurrentOxygen = V.ox
            if W then pcall(function() W:UpdateOxygen(V.ox) end) end
        end
    end
    GS.MirAt = Now
end

local function ApplyHost(PK, Text)
    if Net.Side ~= "client" or not On() or not Net.Has("vit2") then return end
    local V = Decode(Text)
    if not V then return end
    local Pawn = A.OwnPawn()
    if not A.IsAlive(Pawn) or not KeyOk(PK, Pawn) then return end
    local Own = NameOf(Pawn)   -- gast-lokal (Respawn-Erkennung)
    if not Own then return end
    if GS.Name ~= Own or GS.Gen ~= (A.WorldGen and A.WorldGen.N) then ResetGuest(Own) end
    local First = GS.Host == nil
    GS.Host, GS.HostAt = V, os.clock()
    local ok, err = pcall(Mirror, Pawn, V, true)
    if not ok and Core.Fail(FLAG, err) then Log("vit2 aus (Fehler): %s", tostring(err)) end
    if First and ok then Log("Lebenswerte vom Host: Leben %.0f, Hunger %.0f, Durst %.0f", V.h, V.hu, V.th) end
end

-- Medical-Flags: Uebergaenge beim Gast -> vit_rm; Flag nur beim Gast (Host sagt > 3 s nein) -> lokal loeschen
local function GuestFlags(Pawn, Med, Name, Now)
    local Host = GS.Host
    local HostF = Host and Host.f or nil   -- Keyed-State: nur Aenderungen kommen, der letzte Wert gilt
    local Rm = {}
    for _, E in ipairs(EFFECTS) do
      if Use(E) then
        local Local = A.Safe(function() return Med[E.Prop] == true end, false)
        local Was = GS.Lf[E.Name]
        local HostOn = HostF ~= nil and HasBit(HostF, E.Bit)
        if Was and not Local and HostOn then Rm[#Rm + 1] = E.Name GS.RmAt[E.Name], GS.RmTry[E.Name] = Now, 1 end
        -- Host haelt das Flag noch: hoechstens 5x im Abstand von 3 s nachfragen
        if not Local and HostOn and GS.RmTry[E.Name] and GS.RmTry[E.Name] < 5
            and Now - (GS.RmAt[E.Name] or 0) >= 3 then
            Rm[#Rm + 1] = E.Name
            GS.RmAt[E.Name], GS.RmTry[E.Name] = Now, GS.RmTry[E.Name] + 1
        end
        if not HostOn then GS.RmTry[E.Name] = nil end
        -- nur lokal gesetzt (z. B. eigener OnLanded-Bruch, den der Server nicht hat). Infektion (AI-1, vit_infect_local):
        -- ein Phantom-Biss der Gast-Kopie setzt Infection? lokal, das "false" des Hosts schickt das Push-Modell nie neu.
        -- Runde 10: nur mit Faehigkeit vitinf (Host fuehrt Infektion und meldet Bit 128). Hat der Host vit_infect aus
        -- oder Down, fehlt Bit 128 auch bei echter (nativ replizierter) Infektion -> dann nichts anfassen
        if Local and HostF ~= nil and not HostOn
            and (not E.NoLocalFix or (Sub(F.InfLocal) and Net.Has("vitinf"))) then
            GS.OnlyLocal[E.Name] = GS.OnlyLocal[E.Name] or Now
            if Now - GS.OnlyLocal[E.Name] > 3 then
                pcall(VC.LocalStop, Med, E)
                GS.OnlyLocal[E.Name] = nil
                Log("%s nur lokal gesetzt, an den Host angeglichen", E.Name)
            end
        else
            GS.OnlyLocal[E.Name] = nil
        end
        GS.Lf[E.Name] = Local
      else
        GS.Lf[E.Name], GS.OnlyLocal[E.Name], GS.RmTry[E.Name] = nil, nil, nil
      end
    end
    if #Rm > 0 and Sub(F.Rm) then Net.Send("vit_rm", Net.Enc(Name) .. "|" .. table.concat(Rm, ","), nil, 0) end
    -- Schadens-Timer beim Gast stoppen: der Host blutet selbst, Svr_Damage vom Gast waere doppelter Schaden.
    -- InfectionDamage (UE 5.6, alle 6 s ApplyDamage auf die eigene Figur): nur lokaler Schaden, der Host schadet selbst
    if Sub(F.Timers) then
        if GS.Lf.Bleed then ClearTimer(Med, "Bleed") end
        if GS.Lf.Heavy then ClearTimer(Med, "HeavyBleed") end
        if GS.Lf.Infection then ClearTimer(Med, "InfectionDamage") end
    end
end

-- Eindaemmen beim Gast erkennen (UE 5.6): InfectionState(false) laeuft nur hier (CLIENT_RemoveMedicalEffect 'Subdue',
-- NetClient) und erhoeht InfectionTimeLeft um 750..1000 (@0274); der lokale Timer senkt nur um 1/s -> Anstieg > 20 melden
local function GuestSubdue(Med, Name, Now)
    local TL = GS.Lf.Infection and Sub(F.Infect) and A.Safe(function() return Med.InfectionTimeLeft end) or nil
    if type(TL) ~= "number" then GS.InfTL = nil return end
    local Last = GS.InfTL
    GS.InfTL = TL
    local HostF = GS.Host and GS.Host.f
    if Last and TL > Last + 20 and HostF and HasBit(HostF, BIT.Infect) and Sub(F.Rm)
        and Now - (GS.SubAt or -99) >= 2 then
        GS.SubAt = Now
        Net.Send("vit_rm", Net.Enc(Name) .. "|Subdue", nil, 0)
        Log("Infektion beim Gast eingedaemmt, an den Host gemeldet")
    end
end

-- lokaler Lebenszuwachs (RegenHealth-Timer beim Gast) -> vit_rg
local function GuestRegen(Med, Name, Now)
    local L = Med.Health
    if type(L) ~= "number" then return end
    if GS.LastL and L > GS.LastL + 0.001 and L - GS.LastL <= 1.0 then
        GS.Gain = GS.Gain + (L - GS.LastL)
        GS.GainAt = Now
    end
    GS.LastL = L
    if GS.Gain > 0.05 and Now - GS.GainSent >= 0.5 and Sub(F.Regen) then
        Net.Send("vit_rg", Net.Enc(Name) .. "|" .. string.format("%.3f", GS.Gain), nil, 1)
        GS.Gain, GS.GainSent = 0, Now
    end
end

-- Bewegung: JumpZ bei Bruch wie der Server (Svr_SetJumpVelocity setzt nur dort), Werte an den Host melden
local function GuestMove(Pawn, Name)
    if not Sub(F.Move) then return end
    local CM = Pawn.CharacterMovement
    if not A.IsAlive(CM) then return end
    local Broken = GS.Lf.Broken == true
    if Broken ~= GS.WasBroken then
        if GS.WasBroken ~= nil or Broken then CM.JumpZVelocity = Broken and 400 or 600 end
        GS.WasBroken = Broken
    end
    local Text = string.format("%s|%d;%d;%d;%d", Net.Enc(Name), math.floor(CM.MaxWalkSpeed + 0.5),
        math.floor(CM.MaxWalkSpeedCrouched + 0.5), math.floor(CM.MaxSwimSpeed + 0.5), math.floor(CM.JumpZVelocity + 0.5))
    Net.State("vit_mv", "m", Text, 0)
end

-- Feuer anderer (und der eigenen) Figuren sichtbar machen, 2 Hz
local function GuestFx(Now)
    if not Sub(F.Fx) or Now - GS.FxAt < 0.5 then return end
    GS.FxAt = Now
    if next(GS.Fx) == nil then return end
    -- CORE-31: nur Spielerfiguren (vorher alle Figuren inkl. Zombies 2x/s, solange ein Eintrag stand)
    for _, Char in ipairs(VC.Players()) do
        if A.IsAlive(Char) then
            local PK = A.Safe(function() return Net.PawnKey(Char) end)
            local Want = PK and GS.Fx[PK]
            if Want ~= nil then
                local Is = A.Safe(function() return Char["Burning?"] == true end, nil)
                if Is ~= nil and Is ~= Want then
                    if Want then pcall(function() Char:SetBurning(true, 0) end)
                    else pcall(function() Char:StopBurning() end) end
                end
            end
        end
    end
    -- CORE-31: "aus"-Eintraege nach einem Durchlauf weg, auch ohne passende Figur (Spieler weg/tot): sonst lief der Takt
    -- fuer immer weiter
    for PK, Want in pairs(GS.Fx) do
        if Want == false then GS.Fx[PK] = nil end
    end
end

local function GuestTask(Now)
    if Net.Side ~= "client" or not On() or not Net.Has("vit2") or Loading() then return end
    local Pawn = A.OwnPawn()
    if not A.IsAlive(Pawn) then return end
    local Name = NameOf(Pawn)
    if not Name then return end
    if GS.Name ~= Name or GS.Gen ~= (A.WorldGen and A.WorldGen.N) then ResetGuest(Name) end
    local Med = Pawn.MedicalComponent
    if not A.IsAlive(Med) then return end
    local PK = KeyOf(Pawn)   -- gesendet wird der PawnKey, nie die (gast-lokale) FName
    GuestFlags(Pawn, Med, PK, Now)
    local okS, errS = pcall(GuestSubdue, Med, PK, Now)
    if not okS and Core.Fail(F.Infect, errS) then Log("vit_infect aus: %s", tostring(errS)) end
    GuestRegen(Med, PK, Now)
    -- ersetzt vitguard; vit_stale_clear: tote Figur nicht mit dem letzten Wert vor dem Tod nachpflegen (Host schickt dann nil)
    if GS.Host and Now - GS.MirAt >= 0.5 and not (Sub(F.Stale) and VC.Dead(Pawn)) then Mirror(Pawn, GS.Host, false) end
    local ok, err = pcall(GuestMove, Pawn, PK)
    if not ok and Core.Fail(F.Move, err) then Log("vit_move aus: %s", tostring(err)) end
    ok, err = pcall(GuestFx, Now)
    if not ok then Core.Fail(F.Fx, err) end
end

-- ---------------------------------------------------------------- Atemschutz-Anzeige (vit_resp, Runde 8)
-- RadiationComponent_C laeuft nur beim Host (UpdateRadiation NetServer). RadiationTimer @002e SetFilterUI(true) und
-- UseFilter @024b / Mask_Filter @077e (UE 5.3: @05cd) gehen ueber GetPlayerCharacter(0)->GetInGameUI(): beim Host gibt
-- es fuer den Gast keine InGameUI, der Gast sah die Filteranzeige nie (UE 5.6 unveraendert). Host liest den Zustand je
-- Gast, der Gast zeigt ihn selbst an. Hinweise ('No Filter' @02d8, 'Filter No Longer Working' @039e, 'Unusable Filter'
-- @07fe, UE 5.3: @064d) kommen ueber ls_ui (Proxy-HUD).
--   vit_rs Host -> Gast, Keyed-State P1 Sonderwert je Gast, Schluessel "self": "<0|1>;<Haltbarkeit>"
local RS = { Flag = "vit_resp", Sent = {}, Val = nil, Shown = nil, Dur = nil, UI = nil }

function RS.On() return Sub(RS.Flag) end

-- Out-Parameter: benannter Wert, sonst erster Boolean (UE4SS: Out-Tabelle nach Parameternamen)
function RS.Bool(Out, Name)
    if type(Out[Name]) == "boolean" then return Out[Name] end
    for _, V in pairs(Out) do if type(V) == "boolean" then return V end end
    return false
end

-- Host: Anzeige sichtbar?, Haltbarkeit des Filters (wie RadiationTimer: Timer aktiv und Atemschutz angelegt)
function RS.Read(Pawn)
    if A.Safe(function() return Pawn["PlayerDead?"] == true end, true) then return false, 0 end
    local Rad = A.Safe(function() return Pawn.RadiationComponent end)
    if not A.IsAlive(Rad) then return false, 0 end
    local K = KSL()
    local Act = K and A.Safe(function() return K:K2_IsTimerActiveHandle(Rad, Rad.RadiationHandle) end)
    if type(Act) ~= "boolean" then Act = A.Safe(function() return Rad.InRadArea == true end, false) end
    if not Act then return false, 0 end
    local Out = {}
    if not pcall(function() Rad:GetRespirator(Out) end) or not RS.Bool(Out, "Found?") then return false, 0 end
    local Out2 = {}
    if not pcall(function() Rad:GetRespiratorFilter(Out2) end) then return true, 0 end
    local V = A.Safe(function()
        local Info = Out2.ItemInfo
        local D = Info.ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7.Durability_22_A3557C454274D193D47AB9B71FB0C0CA
        return { X = D.X, Y = D.Y }
    end)
    if type(V) ~= "table" or type(V.X) ~= "number" then return true, 0 end
    if not RS.XY then
        RS.XY = true
        Log("Atemschutz-Filter Haltbarkeit X=%.2f Y=%.2f (X = aktuell)", V.X, tonumber(V.Y) or -1)
    end
    return true, math.max(0, math.floor(V.X + 0.5))
end

-- Host, 1 Hz: Zustand je Gast (nur Aenderungen gehen raus, Spaetjoiner ueber Vollauffrischung)
function RS.HostTask()
    if Net.Side ~= "host" or Loading() then return end
    local Run = RS.On()
    Net.ForEachGuest(function(G, Key)
        if not G.Epoch or not Net.Has("vit2", G) then RS.Sent[Key] = nil return end
        if not Run then
            if RS.Sent[Key] then Net.State("vit_rs", "self", "0;0", 1, G) RS.Sent[Key] = nil end
            return
        end
        local ok, err = pcall(function()
            local PC = Net.PC(G)
            local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
            local Shown, Dur = false, 0
            if A.IsAlive(Pawn) then Shown, Dur = RS.Read(Pawn) end
            Net.State("vit_rs", "self", (Shown and "1" or "0") .. ";" .. tostring(Dur), 1, G)
            RS.Sent[Key] = true
        end)
        if not ok and Core.Fail(RS.Flag, err) then Log("vit_resp aus (Fehler): %s", tostring(err)) end
    end)
end

-- Gast: InGameUI der eigenen Figur (GetInGameUI-Out "UI", sonst Eigenschaft InGameUI)
function RS.GuestUI(Pawn)
    local Out = {}
    pcall(function() Pawn:GetInGameUI(Out) end)
    local W = Out.UI
    if type(W) == "userdata" and A.IsAlive(W) then return W end
    return UI(Pawn)
end

-- Gast, 2 Hz: Anzeige nach Host-Zustand (nie UseFilter/RadiationTimer/ServerFuncUpdateDurabilityByUID aufrufen)
function RS.GuestTask()
    if Net.Side ~= "client" then return end
    local Want
    if RS.On() and Net.Has("vit2") and not Loading() then Want = RS.Val end
    local S, D = tostring(Want or ""):match("^([01]);(%d+)$")
    local Shown, Dur = S == "1", tonumber(D) or 0
    if not Shown and RS.Shown ~= true then return end
    local Pawn = A.OwnPawn()
    if not A.IsAlive(Pawn) then return end
    local W = RS.GuestUI(Pawn)
    if not W then return end
    local Id = NameOf(W)
    if Id ~= RS.UI then RS.UI, RS.Shown, RS.Dur = Id, nil, nil end   -- neue UI (Respawn): neu anwenden
    if Shown and Dur ~= RS.Dur then
        W:GetRespiratorDurability(Dur)
        RS.Dur = Dur
    end
    if Shown ~= RS.Shown then
        -- frische UI ist schon verborgen: kein Rueckwaerts-Abspielen der Animation
        if Shown or RS.Shown ~= nil then W:ShowRespiratorDurability(Shown) end
        RS.Shown = Shown
        if Shown and not RS.Logged then
            RS.Logged = true
            Log("Atemschutz-Anzeige vom Host (%s)", tostring(Want))
        end
    end
    if not Shown then RS.Dur = nil end
end

-- ---------------------------------------------------------------- Werte-Datei (Runde 9, E31-Wrapper ueber main.lua V)
-- main.lua ruft V (= Coop.Stats = A.V) immer ueber die Tabellenfelder auf (G.Sync -> Restore, HandleHost/StoreLeaving ->
-- Store, OnPawnDeath -> StoreProgressOnly, V.HostTick -> Collect, vit-Spiegel beim Gast -> Apply, join_v2 -> ReadPos).
-- Init ersetzt die Felder einmal, das Original liegt in V.VitOrig (ueberlebt ein Neuladen, nie Wrapper ueber Wrapper).
-- Modul nicht geladen oder Schalter aus -> Original; Fehler der neuen Teile -> Core.Fail(Schalter).
--   skill_mult (PLAYER-4): Wirkungs-Multiplikatoren (PassiveSkillsComponent_C *Multiplier, SaveGame) mit in Spiegel und
--     Datei, Zeitschrift-Merker *MultiplierUsed? als "PassiveFlag.<Name>=0|1". Alte Datei ohne Multiplikatoren:
--     Faktor ^ (Stufe - 1) (Faktoren aus *_LevelUp, z. B. Fitness_LevelUp @024d; Stufe startet bei 1, ResetPassiveSkills)
--   vit_med_persist (PLAYER-7): Ausdauer/Sauerstoff und "Med.<Effekt>=0|1;Med.InfTL=<s>" in der Datei. Laden: Flag wie
--     das Spiel setzen (MarkPropertyDirtyFromRepIndex + OnRep startet Timer/Anzeige), danach InfectionTimeLeft
--   stats_persist (PLAYER-11): "PCStat.<Feld>=<Wert>" (Kills, Tage, Strecke, Befall) nur in der Datei, nicht im Spiegel
--     (DistanceTravelled aendert sich laufend; Kills/Tage gehen per stats/cb_kills an den Gast)
--   werte_atomic (PLAYER-12): schreiben per Core.WriteAtomic, lesen per Core.ReadAll; leere/kaputte Datei beim Laden aus
--     .bak bzw. der Journal-Kopie .commit reparieren. Kaputt ohne Ersatz: nicht anwenden, Kopie <Id>.werte.broken,
--     V.Broken[GuestId] sperrt das Ueberschreiben (bis die Datei beim naechsten Laden wieder gueltig ist)
-- [Multiplikator] = { Faktor je Stufe, Stufen-Feld }
VW.MULT = {
    FitnessMultiplier = { 1.01, "CurrentFitnessLevel" }, FitnessStaminaMultiplier = { 1.05, "CurrentFitnessLevel" },
    FitnessStaminaRegainMultiplier = { 1.15, "CurrentFitnessLevel" },
    FitnessSwimmingMultiplier = { 1.0425, "CurrentFitnessLevel" },
    StrengthMultiplier = { 1.025, "CurrentStrengthLevel" }, StrengthSpeedMultiplier = { 1.0125, "CurrentStrengthLevel" },
    ToughnessMultiplier = { 1.0525, "CurrentToughessLevel" },   -- sic: das Stufen-Feld heisst im Spiel "Toughess"
    SneakingMultiplier = { 1.035, "CurrentSneakingLevel" }, FirstAidMultiplier = { 1.0325, "CurrentFirstAidLevel" },
    ReloadingMultiplier = { 1.0325, "CurrentReloadingLevel" }, MarksmanshipMultiplier = { 1.04, "CurrentMarksmanshipLevel" },
    ThiefMultiplier = { 1.0625, "CurrentThiefLevel" }, FishingMultiplier = { 1.05, "CurrentFishingLevel" },
    ScavengingMultiplier = { 1.025, "CurrentScavengingLevel" } }
-- Zeitschrift-Merker: BoolProperty "<Skill>MultiplierUsed?" (im Text ohne "?")
VW.FLAGS = { "Fitness", "Strength", "Toughness", "Sneaking", "FirstAid", "Marksmanship", "Reloading", "Thief", "Fishing",
             "Scavenging" }
-- Medical-Flags: Text-Name, Property, RepIndex (wie das Spiel: Bleed? 2, HeavyBleed? 3, BrokenBone? 4, Infection? 6)
VW.MED = { { "Bleed", "Bleed?", 2 }, { "Heavy", "HeavyBleed?", 3 }, { "Broken", "BrokenBone?", 4 }, { "Infection", "Infection?", 6 } }
VW.VIT = { { "StaminaComponent", "CurrentStamina" }, { "SwimmingComponent", "CurrentOxygen" } }
-- BP_PlayerController_C (props.tsv): IntProperty ausser DistanceTravelled (DoubleProperty)
VW.STATS = { "ZombieKills", "BossZombieKills", "AnimalKills", "HumanKills", "DaysSurvived", "DistanceTravelled",
             "InfestationsDestroyed" }
VW.OWN = { PassiveFlag = true, PCStat = true, Med = true }   -- eigene Eintraege: nie an das alte V.Apply
VW.FLAGSET, VW.STATSET = {}, {}
for _, N in ipairs(VW.FLAGS) do VW.FLAGSET[N .. "MultiplierUsed"] = true end
for _, N in ipairs(VW.STATS) do VW.STATSET[N] = true end

function VW.On(Name) return Core.Flag(Name, true) == true end
function VW.Loaded() return A.Coop ~= nil and A.Coop.Modules ~= nil and A.Coop.Modules.ls_vit == M end

function VW.ReadFile(Path)
    local File = io.open(Path, "rb")
    if not File then return nil end
    local Text = File:read("*a")
    File:close()
    return Text
end

function VW.Valid(Text)
    return type(Text) == "string" and Text:find("LevellingComponent.CurrentLevel=", 1, true) ~= nil
end

-- Werte dieses Gasts gerade nicht schreiben: Datei kaputt (V.Broken) oder Server stoppt (E22 Coop.GuestStoreFrozen)
function VW.Blocked(GuestId)
    local B = A.V.Broken
    if type(B) == "table" and B[GuestId] then return true end
    return A.Coop ~= nil and A.Coop.GuestStoreFrozen and true or false
end

-- Collect-Aufrufe waehrend Fn (Speichern) bekommen PCStat.* (der Spiegel V.HostTick nicht)
function VW.AsSave(Fn, ...)
    VW.Saving = true
    local ok, R = pcall(Fn, ...)
    VW.Saving = false
    if not ok then error(R, 0) end
    return R
end

-- Teil eines Schalters anhaengen; Fehler -> Core.Fail, der Text bleibt dann wie bisher
function VW.Extra(Parts, Flag, Fn, Obj)
    if not VW.On(Flag) or not A.IsAlive(Obj) then return end
    local Mine = {}
    local ok, err = pcall(Fn, Mine, Obj)
    if ok then
        for _, P in ipairs(Mine) do Parts[#Parts + 1] = P end
    elseif Core.Fail(Flag, err) then
        Log("%s aus: %s", Flag, tostring(err))
    end
end

function VW.FlagParts(Out, PC)
    local PS = PC.PassiveSkillsComponent
    if not A.IsAlive(PS) then return end
    for _, N in ipairs(VW.FLAGS) do
        local B = A.Safe(function() return PS[N .. "MultiplierUsed?"] end)
        if type(B) == "boolean" then Out[#Out + 1] = "PassiveFlag." .. N .. "MultiplierUsed=" .. (B and "1" or "0") end
    end
end

function VW.MedParts(Out, Pawn)
    for _, E in ipairs(VW.VIT) do
        local Val = A.Safe(function() local C = Pawn[E[1]] return A.IsAlive(C) and C[E[2]] or nil end)
        if type(Val) == "number" then Out[#Out + 1] = string.format("%s.%s=%.10g", E[1], E[2], Val) end
    end
    local Med = Pawn.MedicalComponent
    if not A.IsAlive(Med) then return end
    local Inf = false
    for _, E in ipairs(VW.MED) do
        local B = A.Safe(function() return Med[E[2]] == true end, false)
        if E[1] == "Infection" then Inf = B end
        Out[#Out + 1] = "Med." .. E[1] .. "=" .. (B and "1" or "0")
    end
    local TL = Inf and A.Safe(function() return Med.InfectionTimeLeft end)
    if type(TL) == "number" then Out[#Out + 1] = string.format("Med.InfTL=%.0f", TL) end
end

function VW.StatParts(Out, PC)
    for _, N in ipairs(VW.STATS) do
        local Val = A.Safe(function() return PC[N] end)
        if type(Val) == "number" then
            Out[#Out + 1] = N == "DistanceTravelled" and string.format("PCStat.%s=%.1f", N, Val)
                or string.format("PCStat.%s=%d", N, math.floor(Val + 0.5))
        end
    end
end

-- eigene Eintraege anwenden: PassiveFlag (skill_mult), PCStat (stats_persist); Med nur beim Laden (VW.MedRestore)
function VW.ApplyOwn(PC, Own)
    if #Own == 0 or not A.IsAlive(PC) then return 0 end
    local N, PS = 0, nil
    for _, Part in ipairs(Own) do
        local Comp, Field, Value = Part:match("^(%w+)%.([%w_]+)=(.+)$")
        if Comp == "PassiveFlag" and VW.FLAGSET[Field] and VW.On(F.Mult) then
            PS = PS or A.Safe(function() return PC.PassiveSkillsComponent end)
            if A.IsAlive(PS) and pcall(function() PS[Field .. "?"] = Value ~= "0" end) then N = N + 1 end
        elseif Comp == "PCStat" and VW.STATSET[Field] and VW.On(F.Stats) then
            local Num = tonumber(Value)
            if Num and Field ~= "DistanceTravelled" then Num = math.floor(Num + 0.5) end
            if Num and Num >= 0 and pcall(function() PC[Field] = Num end) then N = N + 1 end
        end
    end
    return N
end

-- Push-Modell: nach dem Setzen wie das Spiel markieren (sonst repliziert der Wert nicht zum Gast)
function VW.Dirty(Obj, Rep, Prop)
    local H = A.Safe(function() return StaticFindObject("/Script/Engine.Default__NetPushModelHelpers") end)
    if not A.IsAlive(H) then return false end
    return pcall(function() H:MarkPropertyDirtyFromRepIndex(Obj, Rep, FName(Prop)) end)
end

-- skill_mult: alte Datei (Stufen ohne Multiplikatoren) -> Multiplikatoren aus den gerade geladenen Stufen
function VW.Migrate(PC, Text, GuestId)
    if Text:find("Multiplier=", 1, true) or not Text:find("PassiveSkillsComponent.CurrentFitnessLevel=", 1, true) then return end
    local PS = A.IsAlive(PC) and PC.PassiveSkillsComponent
    if not A.IsAlive(PS) then return end
    local N = 0
    for Field, E in pairs(VW.MULT) do
        local Lv = tonumber(A.Safe(function() return PS[E[2]] end))
        if Lv and Lv > 1 then
            PS[Field] = E[1] ^ (math.floor(Lv + 0.5) - 1)
            N = N + 1
        end
    end
    if N > 0 then Log("Faehigkeiten von %s: %d Multiplikatoren aus den Stufen nachgerechnet (alte Werte-Datei)", tostring(GuestId), N) end
end

-- vit_med_persist: Blutung/Bruch/Infektion der Datei auf die (lebende) Host-Figur, wie ApplyMedicalEffect (@0382/@0608)
function VW.MedRestore(Pawn, Text, GuestId)
    if not Text:find("Med.", 1, true) or not A.IsAlive(Pawn) then return end
    if A.Safe(function() return Pawn["PlayerDead?"] == true end, true) then return end
    local Med = Pawn.MedicalComponent
    if not A.IsAlive(Med) then return end
    local Set = {}
    for _, E in ipairs(VW.MED) do
        if Text:find("Med." .. E[1] .. "=1", 1, true) and A.Safe(function() return Med[E[2]] == true end, true) == false then
            Med[E[2]] = true
            VW.Dirty(Med, E[3], E[2])
            pcall(function() Med["OnRep_" .. E[2]](Med) end)
            Set[#Set + 1] = E[1]
        end
    end
    -- nach OnRep (OnRep_Infection? @0068 zieht nur bei laufendem Timer ab)
    local TL = tonumber(Text:match("Med%.InfTL=([%d%.]+)"))
    if TL and A.Safe(function() return Med["Infection?"] == true end, false) then Med.InfectionTimeLeft = TL end
    if #Set > 0 then Log("Zustand von %s wiederhergestellt: %s", tostring(GuestId), table.concat(Set, ", ")) end
end

-- werte_atomic: Hauptdatei vor dem Laden pruefen/reparieren. Rueckgabe: Text (so liest ihn das Original gleich), Skip
function VW.Repair(GuestId)
    local V = A.V
    local Path = V.Path(GuestId)
    V.Broken[GuestId] = nil
    local Main = VW.ReadFile(Path)
    if VW.Valid(Main) then return Main end
    -- Ersatz: .bak (Core.WriteAtomic unterbrochen), sonst die Journal-Kopie .commit (nur wenn die Datei da, aber kaputt ist;
    -- eine geloeschte Datei bleibt ein Neuanfang)
    local Alt, From = VW.ReadFile(Path .. ".bak"), ".bak"
    if not VW.Valid(Alt) then
        Alt, From = nil, nil
        if Main ~= nil then
            local Com = VW.ReadFile((Path:gsub("%.txt$", ".commit")))
            if VW.Valid(Com) then Alt, From = Com, ".commit" end
        end
    end
    if Main == nil and Alt == nil then return nil end   -- neuer Gast
    local Blank = Main == nil or not Main:find("%S")
    if not Blank then Core.WriteAtomic((Path:gsub("%.txt$", ".broken")), Main) end   -- Stand fuer Handarbeit aufheben
    if Alt then
        if Core.WriteAtomic(Path, Alt) then
            Log("Werte von %s: Datei %s - Stand aus %s wiederhergestellt", tostring(GuestId),
                Main == nil and "fehlte" or (Blank and "leer" or "unvollstaendig"), From)
            return Alt
        end
        -- Ersatz nicht schreibbar: nichts anwenden, nichts ueberschreiben (naechstes Laden versucht es erneut)
        V.Broken[GuestId] = true
        Log("WARNUNG: Werte von %s: Stand aus %s nicht schreibbar - nicht angewendet, Datei wird nicht ueberschrieben",
            tostring(GuestId), From)
        return Alt, true
    end
    if Blank then return Main end   -- leer und kein Ersatz: Startwerte wie bisher
    V.Broken[GuestId] = true
    Log("WARNUNG: Werte von %s unvollstaendig - nicht angewendet, Datei wird nicht ueberschrieben (Kopie .werte.broken). "
        .. "Datei reparieren oder loeschen", tostring(GuestId))
    return Main, true
end

-- Ersatz V.Store (werte_atomic): wie das Original (nie mit 0 Leben, nur bei Aenderung), atomar geschrieben
function VW.StoreNew(Pawn, PC, GuestId)
    local V = A.V
    if VW.Blocked(GuestId) then return end
    local Med = A.IsAlive(Pawn) and Pawn.MedicalComponent
    if not (A.IsAlive(Med) and Med.Health > 0) then return end
    local Text = VW.AsSave(V.Collect, Pawn, PC, true)
    if Text == V.StoredText[GuestId] then return end
    if Core.WriteAtomic(V.Path(GuestId), Text) then V.StoredText[GuestId] = Text end
end

-- Ersatz V.StoreProgressOnly (werte_atomic, Tod): nur Stufe/XP/Faehigkeiten (+ PCStat), atomar
function VW.ProgressNew(PC, GuestId)
    local V = A.V
    if VW.Blocked(GuestId) then return end
    local Text = VW.AsSave(V.Collect, nil, PC, false)
    if Core.WriteAtomic(V.Path(GuestId), Text) then V.StoredText[GuestId] = Text end
end

-- Wrapper (Old = main.lua-Original)
function VW.Wraps.SkillFields(Old)
    return function(Comp)
        local Base = Old(Comp)
        if not (VW.Loaded() and VW.On(F.Mult)) or type(Base) ~= "table" or #Base == 0 then return Base end
        if VW.Fields and VW.FieldsOf == Base then return VW.Fields end
        if not A.IsAlive(Comp) then return Base end
        local ok, err = pcall(function()
            local L = {}
            for _, N in ipairs(Base) do L[#L + 1] = N end
            Comp:GetClass():ForEachProperty(function(Prop)
                local N = Prop:GetFName():ToString()
                if N:match("Multiplier$") and Prop:GetClass():GetFName():ToString() == "DoubleProperty" then L[#L + 1] = N end
            end)
            VW.Fields, VW.FieldsOf = L, Base
        end)
        if not ok then
            if Core.Fail(F.Mult, err) then Log("skill_mult aus: %s", tostring(err)) end
            return Base
        end
        return VW.Fields
    end
end

function VW.Wraps.Collect(Old)
    return function(Pawn, PC, WithVitals)
        local Text = Old(Pawn, PC, WithVitals)
        if type(Text) ~= "string" or not VW.Loaded() then return Text end
        local Parts = {}
        VW.Extra(Parts, F.Mult, VW.FlagParts, PC)
        if WithVitals and Pawn ~= nil then VW.Extra(Parts, F.Med, VW.MedParts, Pawn) end
        if VW.Saving then VW.Extra(Parts, F.Stats, VW.StatParts, PC) end
        if #Parts == 0 then return Text end
        return Text .. ";" .. table.concat(Parts, ";")
    end
end

function VW.Wraps.Apply(Old)
    return function(Pawn, PC, Text)
        if type(Text) ~= "string" or not VW.Loaded() then return Old(Pawn, PC, Text) end
        if VW.Skip then return 0 end
        if not (Text:find("PassiveFlag.", 1, true) or Text:find("PCStat.", 1, true) or Text:find("Med.", 1, true)) then
            return Old(Pawn, PC, Text)
        end
        local Keep, Own = {}, {}
        for Part in Text:gmatch("[^;]+") do
            local Comp = Part:match("^(%w+)%.")
            if Comp and VW.OWN[Comp] then Own[#Own + 1] = Part else Keep[#Keep + 1] = Part end
        end
        local N = Old(Pawn, PC, table.concat(Keep, ";"))
        return (tonumber(N) or 0) + VW.ApplyOwn(PC, Own)
    end
end

function VW.Wraps.Restore(Old)
    return function(Key, Pawn, PC, GuestId)
        if not VW.Loaded() or GuestId == nil then return Old(Key, Pawn, PC, GuestId) end
        local Text, Skip
        if VW.On(F.Atomic) then
            local ok, T, S = pcall(VW.Repair, GuestId)
            if ok then
                Text, Skip = T, S
            elseif Core.Fail(F.Atomic, T) then
                Log("werte_atomic aus: %s", tostring(T))
            end
        end
        if Text == nil then Text = A.Safe(function() return Core.ReadAll(A.V.Path(GuestId)) end) end
        VW.Skip = Skip == true
        local ok, err = pcall(Old, Key, Pawn, PC, GuestId)
        VW.Skip = false
        if not ok then error(err, 0) end
        if Skip or not VW.Valid(Text) then return end
        if VW.On(F.Mult) then
            local okM, errM = pcall(VW.Migrate, PC, Text, GuestId)
            if not okM and Core.Fail(F.Mult, errM) then Log("skill_mult aus: %s", tostring(errM)) end
        end
        if VW.On(F.Med) then
            local okD, errD = pcall(VW.MedRestore, Pawn, Text, GuestId)
            if not okD and Core.Fail(F.Med, errD) then Log("vit_med_persist aus: %s", tostring(errD)) end
        end
    end
end

function VW.Wraps.Store(Old)
    return function(Pawn, PC, GuestId)
        if not VW.Loaded() then return Old(Pawn, PC, GuestId) end
        if not VW.On(F.Atomic) then return VW.AsSave(Old, Pawn, PC, GuestId) end
        local ok, err = pcall(VW.StoreNew, Pawn, PC, GuestId)
        if not ok then
            if Core.Fail(F.Atomic, err) then Log("werte_atomic aus: %s", tostring(err)) end
            error(err, 0)   -- Aufrufer meldet wie bisher
        end
    end
end

function VW.Wraps.StoreProgressOnly(Old)
    return function(PC, GuestId)
        if not VW.Loaded() then return Old(PC, GuestId) end
        if not VW.On(F.Atomic) then return VW.AsSave(Old, PC, GuestId) end
        local ok, err = pcall(VW.ProgressNew, PC, GuestId)
        if not ok then
            if Core.Fail(F.Atomic, err) then Log("werte_atomic aus: %s", tostring(err)) end
            error(err, 0)
        end
    end
end

function VW.Wraps.ReadPos(Old)
    return function(GuestId, Text)
        if not VW.Loaded() then return Old(GuestId, Text) end
        if VW.Skip then return nil end   -- kaputte Datei: kein Teleport
        if Text == nil and VW.On(F.Atomic) then
            local ok, T = pcall(Core.ReadAll, A.V.Path(GuestId))
            if ok then Text = T or "" end
        end
        return Old(GuestId, Text)
    end
end

function VW.Install()
    local V = A.V
    if type(V) ~= "table" then Log("Coop.Stats fehlt: Werte-Erweiterungen aus") return end
    V.VitOrig = V.VitOrig or {}
    V.Broken = V.Broken or {}
    if type(V.ON_PAWN) == "table" then
        for _, E in ipairs(VW.VIT) do V.ON_PAWN[E[1]] = true end   -- Ausdauer/Sauerstoff liegen an der Figur (V.Apply)
    end
    local N = 0
    for Name, Make in pairs(VW.Wraps) do
        local Old = V.VitOrig[Name] or V[Name]
        if type(Old) == "function" then
            V.VitOrig[Name] = Old
            V[Name] = Make(Old)
            N = N + 1
        end
    end
    Log("Werte-Datei: %d Funktionen erweitert (skill_mult, vit_med_persist, stats_persist, werte_atomic)", N)
end

-- ---------------------------------------------------------------- Handler / Init

M.Handlers = {
    vit_rs = function(Value)
        if Net.Side == "client" then RS.Val = Value end
    end,
    vit2 = function(Value)
        if Value == nil then return end
        local PK, Text = tostring(Value):match("^([^|]*)|(.*)$")
        if PK then ApplyHost(Net.Dec(PK), Text) end
    end,
    vit2j = function(Data)
        local Name, Text = tostring(Data or ""):match("^([^|]*)|(.*)$")
        if Name then ApplyHost(Net.Dec(Name), Text) end
    end,
    vit_fx = function(Value, _, Msg)
        if Net.Side ~= "client" or type(Msg) ~= "table" or not Msg.Key then return end
        GS.Fx[Msg.Key] = Value == "1"
        GS.FxAt = 0
    end,
    vit_rm = OnRm,
    vit_rg = OnRg,
}

function M.HostTick()
    for Key in pairs(HS) do
        if not Net.Guests[Key] then HS[Key] = nil end
    end
    for Key in pairs(RS.Sent) do
        if not Net.Guests[Key] then RS.Sent[Key] = nil end
    end
    -- CORE-30: Pruef-Zaehler getrennter Gaeste
    for Key in pairs(VC.Bad) do
        if not Net.Guests[Key] then VC.Bad[Key], VC.LogAt[Key] = nil, nil end
    end
    for Key in pairs(VC.LogAt) do
        if not Net.Guests[Key] then VC.LogAt[Key] = nil end
    end
end

-- Faehigkeit vit2: aus, wenn vit_v2 aus/Down ist oder der vit2-Empfaenger (Dispatch, net_h_vit2) wegen Fehlern Down ist
local function CapOn()
    return On() and not Core.Down.net_h_vit2
end

-- Legacy-Gates fuer main.lua (vitset/vitguard, Svr_Damage-Diagnose-Hook, LogHealth)
local function Active(Key)
    if not On() or not Net.Enabled() then return false end
    if Net.Side == "host" then return Key ~= nil and Net.Has("vit2", Key) end
    -- Gast: vit2-Empfaenger Down -> sofort wieder vitset/vitguard (Host faellt per h4 nach vit_caps nach)
    if Net.Side == "client" then return not Core.Down.net_h_vit2 and Net.Has("vit2") end
    return false
end

function M.Init(Api)
    A = Api
    -- Runde 9: Werte-Datei-Wrapper ueber main.lua V (skill_mult, vit_med_persist, stats_persist, werte_atomic)
    local okW, errW = pcall(VW.Install)
    if not okW then Log("Werte-Erweiterungen nicht installiert: %s", tostring(errW)) end
    Net.Cap("vit2", CapOn())
    -- Runde 10: vitinf = Host fuehrt Infektion (setzt Bit 128); Gast-Angleichung von Infection? nur damit
    Net.Cap("vitinf", CapOn() and Sub(F.Infect))
    -- Faehigkeit nachfuehren: FLAG_DOWN (vit_v2 / net_h_vit2) zieht vit2 zurueck, der Peer faellt auf Legacy
    -- (Net.Cap ist ohne Aenderung ein No-op und meldet Aenderungen per h4/h4a)
    Core.Every("vit_caps", 1, function()
        Net.Cap("vit2", CapOn())
        -- FLAG_DOWN von vit_infect (Core.Fail) zieht vitinf zurueck, der Gast faellt auf NoLocalFix
        Net.Cap("vitinf", CapOn() and Sub(F.Infect))
    end)
    A.Coop.VitV2 = Active
    A.Coop.VitV2Flag = On
    Core.Every("vit_host", 0.25, HostTask)
    Core.Every("vit_hmove", 0.1, function()
        local ok, err = pcall(HostMove)
        if not ok then Core.Fail(F.Move, err) end
    end)
    Core.Every("vit_cli", 0.1, function(Now)
        local ok, err = pcall(GuestTask, Now)
        if not ok and Core.Fail(FLAG, err) then Log("vit2 aus (Fehler): %s", tostring(err)) end
    end)
    -- Atemschutz-Anzeige (vit_resp): Host liest je Gast, Gast zeigt an
    Core.Flag(RS.Flag, true)
    Core.Every("vit_resp", 1.0, function()
        local ok, err = pcall(RS.HostTask)
        if not ok and Core.Fail(RS.Flag, err) then Log("vit_resp aus (Fehler): %s", tostring(err)) end
    end)
    Core.Every("vit_resp_cli", 0.5, function()
        local ok, err = pcall(RS.GuestTask)
        if not ok and not Core.Down[RS.Flag] and Core.Fail(RS.Flag, err) then Log("vit_resp aus (Fehler): %s", tostring(err)) end
    end)
    Net.OnEvent("gone", function(Peer)
        if type(Peer) == "table" and Peer.Key then
            HS[Peer.Key], RS.Sent[Peer.Key], VC.Bad[Peer.Key], VC.LogAt[Peer.Key] = nil, nil, nil, nil
        end
        if Net.Side == "client" then GS = { Fx = {} } RS.Val = nil end   -- Anzeige verbergen (naechster Takt)
    end)
    Net.OnEvent("ready", function(Peer)
        if Net.Side == "host" and type(Peer) == "table" and Peer.Key and HS[Peer.Key] then
            HS[Peer.Key].JH, HS[Peer.Key].LastF = nil, nil   -- naechster Takt sendet sofort (vit2j)
        end
    end)
    A.TestCommands.vit_probe = function()
        local Out = A.TestLog or A.Log
        if Net.Side == "host" then
            Net.ForEachGuest(function(G, Key)
                local PC = Net.PC(G)
                local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
                local V = A.IsAlive(Pawn) and ReadVitals(Pawn)
                Out("vit host %s: %s mv=%s cap=%s", tostring(G.PawnName), V and Encode(V) or "?",
                    tostring(Net.Get("vit_mv", "m", G)), tostring(Net.Has("vit2", G)))
            end)
        else
            local Pawn = A.OwnPawn()
            local V = A.IsAlive(Pawn) and ReadVitals(Pawn)
            Out("vit gast %s: lokal %s host %s cap=%s", tostring(GS.Name), V and Encode(V) or "?",
                GS.Host and Encode(GS.Host) or "-", tostring(Net.Has("vit2")))
        end
    end
    Log("geladen (%s)", On() and "an" or "aus")
end

return M
