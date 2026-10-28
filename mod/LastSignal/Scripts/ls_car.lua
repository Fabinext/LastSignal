-- ls_car.lua: Fahrzeuge v2 (Runde 5, WP14). Basis bleibt Coop.Car in main.lua (fahrer-autoritative Lage, 30 Hz).
-- Dieses Modul ergaenzt (Decode: _NetTest\analysis\findings\car.md):
--   Input-Flag (SetRequiresControllerForInputs), Beifahrer (Input-Lock, Zustand, Befoerderung), Release bei Tod/
--   Trennung, Keyed-State car_s (Tank, Zustand, Licht, Motor, Farbe, Radio; Rauch/Feuer ueber VehicleEngineFX) auch
--   fuer spaete Joiner, InVehicle? auf fremden Figuren (car_seat), Server-Schaden gegen den Fahrerwert (PoseHp),
--   Tanken/Reparieren ueber den Host (car_svc, ohne Inventar-Hook), Kofferraum repliziert, Fahrlaerm vom Host,
--   Kauf beim Fahrzeughaendler (car_buy), Roadkill (car_hit), Hupe, Radio.
-- Hooks: nur BP_VehicleMaster_C:Horn (Spieleraktion) und der Klick am VehicleVendorButton (UI), beide Pre und nur
-- Lua-Tabellen. Alles andere per Abfrage (Core.Every), UObjects nur innerhalb eines Durchlaufs.
-- Schieben/Abschleppen (car_push/car_tow): Interact_PushVehicle (AddForce 4e7 * Kamera-Vorwaerts) und AddTowingComp
-- (PhysicsConstraint) laufen nur lokal, ohne RPC - beim Gast nur auf seiner Kopie, die Replikation zieht das Auto
-- zurueck. Gast: Hooks (Spieleraktion, nur Name + Bool) -> c2s car_push; Host fuehrt es auf seiner Kopie aus.
-- Beide sind BP-Funktionen: UE4SS 3.0.1 ruft den Hook erst NACH dem BP-Rumpf (main.lua 7851) -> car_hook_post wertet
-- den Zustand danach aus (Schieben: eigene 2-s-Abklingzeit je Auto; Abschleppen: TowingVehicle? = neuer Stand).
-- Runde 7 Fahrzeugkauf (findings\traders_r7.md 5.7, Hauptschalter trd_v1): Gast-Klick per ret_early-Patch stumm
-- (car_buyclk, kein falsches "Not enough money"), Host-Preis aus DT_VehicleInfo 'Trader' (car_buydt), Sperre je
-- Spawner + freier Abholplatz (car_buymx), Geldstapel des Gasts in der Antwort (car_buyui), erst spawnen, dann
-- abbuchen, sonst Auto weg/Rueckgabe (car_buyref), Auto gehoert dem Kaeufer (car_buyown).
local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local A

local FLAG = "car_v2"
local F = { input = "car_input", pass = "car_pass", fx = "car_fx", seat = "car_seat", dmg = "car_dmg",
            svc = "car_svc", trunk = "car_trunk", noise = "car_noise", hit = "car_hit", buy = "car_buy",
            radio = "car_radio", horn = "car_horn", svcval = "car_svc_val", push = "car_push", tow = "car_tow",
            -- Runde 9 (Fix-Runde 24.10.)
            cleanup = "car_cleanup", ghost = "car_ghost", tags = "car_tags", water = "car_water", fuelhold = "car_fuelhold",
            strict = "car_strict", lock = "car_lock", occdmg = "car_occdmg", seatanim = "car_seatanim",
            sweep2 = "car_sweep2", perf = "car_perf", guard = "car_guard", trunkn = "car_trunkn", polish = "car_polish",
            lockplus = "car_lockplus",   -- Abschluss-Runde 2: CAR-8 Kofferraum-Sperre auch fuer ConsumeItem
            -- Abschluss-Runde 3: Host-Stand TowingVehicle? an Gaeste (car_tw); Kofferraumfenster bei Sperre zu (car_dn)
            towsync = "car_towsync", denyui = "car_denyui",
            -- Abschluss-Runde 4: Abschlepp-Angleich ohne Hinweise/HUD fuer unbeteiligte Gaeste
            towquiet = "car_towquiet" }
local P = {
    MASTER = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C",
    VENDOR = "/Game/UI/Widgets/Other/VehicleVendorButton.VehicleVendorButton_C",
    CLICK = "BndEvt__VehicleVendorButton_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature",
    MONEY = "/Game/Inventory/Items/DataAssets/Currency/DA_Money.DA_Money",
    SPAWNER = "BP_VehicleTraderSpawner_C",
    ITEMS = { gas = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
              repair = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit" },
    KSL = "/Script/Engine.Default__KismetSystemLibrary",
    GPS = "/Script/Engine.Default__GameplayStatics",
    WBL = "/Script/UMG.Default__WidgetBlueprintLibrary",
    TRADER_UI = "/Game/Inventory/Widgets/Trader/W_VehicleTraderUI.W_VehicleTraderUI_C",
    HEAR = "/Script/AIModule.Default__AISense_Hearing",
    -- Runde 9 (CAR-1): echte Schadensart wie ApplyDamageToAIBasedOnSpeed @0082/@01b8 (nil als Klasse liess UE4SS abstuerzen)
    DMGT = "/Script/Engine.DamageType",
    JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C",   -- CAR-8 Kofferraum-Sperre
    CU = "/Script/AutoSettings.Default__ConsoleUtils",   -- CAR-10: Difficulty.DamageMultiplier wie die BPs
    SIT = "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage",   -- CAR-11 (UB @2c78/@5d9f)
    -- Kauf (Runde 7): Datentabelle wie W_VehicleTraderUI.GetDataTable_Vehicles, Ubergraph des Klick-Stubs (Patch)
    DT = "/Game/Blueprints/Vehicles/Spawner/DT_VehicleInfo.DT_VehicleInfo",
    UBER = "ExecuteUbergraph_VehicleVendorButton",
}
-- UE 5.6 geprueft: Pfade/Funktionen unveraendert (Jig-Komponente jetzt BP_JigComponent_C, Pawn-Eigenschaft heisst
-- weiter BP_JigMultiplayer; Signaturen CheckIfHasEnoughMoney/TakeMoney/ClientUpdateCount/ServerFindThenConsume gleich).
-- Struct-Felder (CXXHeaderDump Struct_VehicleSpawner.hpp / Struct_VehicleDT.hpp, bp2-Decode GetDataTable_Vehicles;
-- 5.6: GetDataTable_Vehicles @0086/@0193/@027f mit denselben GUID-Namen):
-- FStruct_VehicleSpawner.Vehicles (0x08, TArray<FStruct_VehicleDT>), FStruct_VehicleDT.Vehicles (0x00, Klasse),
-- .Price (0x20, double). Jig-Inventar wie ls_inv (TakeMoney-Decode: MainJigContainers[i].ContainerItems[j].ItemInfo).
local DTF = { ROWS = "Vehicles_14_6F62AF3348A4068731BE22ACF609D1D5",
              CLS = "Vehicles_11_54A68FE74C492D4E1322A1A28870318A",
              PRICE = "Price_10_6F62AF3348A4068731BE22ACF609D1D5" }
local JF = { ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
             UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
             INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
             ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
             COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD" }
-- Zustand: H = Host, Cl = Gast. Nur Namen/Zahlen, nie UObjects ueber Durchlaeufe.
-- Patch = Gast-Patch car_buyclk (Zeile/Stand ueber Weltwechsel, die DLL behaelt ihn bis zur 0-Zeile)
-- PushAt = Gast-Abklingzeit Schieben je Auto (car_hook_post, os.clock wie Delay(2) @320e)
local S = { Gen = -1, InHorn = false, HornQ = {}, BuyQ = {}, BuyRes = {}, PushQ = {}, PushAt = {}, Hooked = {}, HookTry = 0,
            Patch = { On = false, Line = nil }, H = {}, Cl = {}, LockQ = {}, NoneQ = {} }
-- Runde 9: spaeter im Datei-Text definierte Helfer, die fruehere Aufgaben aufrufen (ohne weitere Haupt-locals)
local Late = {}

local function Log(Fmt, ...) A.Log("[Car] " .. Fmt, ...) end
local function On(Name) return Core.Flag(FLAG, true) and Core.Flag(Name, true) end
-- Kauf-Feinschalter (Runde 7): car_buy + Hauptschalter trd_v1 + eigener Schalter (alle Standard 1)
local function BuyOn(Name) return On(F.buy) and Core.Flag("trd_v1", true) and Core.Flag(Name, true) end
local function Alive(O) return O ~= nil and A.IsAlive(O) end
local function Full(O) return (O:GetFullName():match("^%S+%s+(%S+)$")) end
local function Find(Path)
    if not Path then return nil end
    local O = A.Safe(function() return StaticFindObject(Path) end)
    return Alive(O) and O or nil
end
local function D2(P1, X, Y, Z) return (P1.X - X) ^ 2 + (P1.Y - Y) ^ 2 + (P1.Z - Z) ^ 2 end
local function Short(Key) return tostring(Key):match("[^%.]+$") or tostring(Key) end
local function Q(X) return math.floor(X / 100 + 0.5) * 100 end
local function B(V) return V and "1" or "0" end
local function Fields(Data)
    local Fd = {}
    for Part in (tostring(Data) .. "|"):gmatch("([^|]*)|") do Fd[#Fd + 1] = Part end
    return Fd
end
-- Teilfunktion in pcall; Fehler zaehlen auf den Feature-Schalter (Core.Fail -> FLAG_DOWN nach > 3 in 60 s)
local function Try(Name, Fn, ...)
    local ok, err = pcall(Fn, ...)
    if not ok then Core.Fail(Name, err) end
    return ok
end

-- CAR-14 (1): gemeinsame Autoliste (main.lua Coop.Car.Vehicles: FindAllOf hoechstens 1x/s je Welt), Nutzer pruefen
-- jedes Auto mit Alive. car_perf=0: eigenes FindAllOf wie bisher
local function Cars()
    local C = A.Coop.Car
    if On(F.perf) and C and type(C.Vehicles) == "function" then
        local ok, L = pcall(C.Vehicles)
        if ok and type(L) == "table" then return L end
    end
    return FindAllOf("BP_VehicleMaster_C") or {}
end

local function ResetH()
    S.H = { Flagged = {}, InVeh = {}, SeatIds = {}, Overlap = {}, LastHp = {}, HoldHp = {}, PushHp = {}, Trunk = {},
            Keys = {}, NoiseAt = 0, StateAt = 0, Rate = {}, HitCd = {}, BuyAt = {}, Logged = {},
            BuyMx = {}, Bought = {}, PriceSrc = nil, DtTry = 0, PushCd = {},
            Tagged = {}, WaterAt = 0, HoldFu = {}, Bad = {}, TrunkN = {}, TrunkAt = 0, Own = {}, Guard = {},
            SeatPawn = {}, JanAt = 0, DenyPrev = {} }
end
local function ResetCl()
    S.Cl = { Index = {}, Bind = {}, Rev = {}, OwnFull = nil, FxFor = nil, SentL = nil, SentR = nil, Held = nil,
             HitCd = {}, Cls = {}, ClsAt = 0, Eng = {}, Seat = {}, SweepAt = 0, PrevMph = 0,
             PassFor = nil, NearFull = nil, Missing = {}, Pend = {}, IndexAt = 0,
             Prev = nil, LastHeld = nil, SentAt = {}, Odd = {},
             Since = os.clock(), GhostT = {}, GhostSp = 0, GhostN = 0, GhostDel = 0, Lk = {}, LockAsk = nil,
             TrunkN = {}, RadioFrom = {}, PrevPos = nil, Sit = {}, SitTry = 0,
             -- car_towsync: Tow = Host-Stand je Host-FName ("1"/"0"), TowTry = letzter Angleich-Versuch je Host-Wert,
             -- TowHold = Sperrfrist je Gast-Pfad nach eigenem Druck (os.clock)
             Tow = {}, TowTry = {}, TowHold = {} }
end
ResetH()
ResetCl()

-- CORE-8: Welt freigegeben? Waehrend des Ladens und bis main.lua DropWorldRefs gelaufen ist, haengen in Coop.Car
-- (Driving, Drivers, Passengers) noch Objekte der alten Welt - die nie anfassen, auch kein IsAlive
local function Settled()
    local W = A.WorldGen
    if not W or not Core.Flag("world_hygiene", true) then return true end
    if W.Loading and os.clock() - (W.LoadingAt or 0) < 60 then return false end
    if W.Dropped ~= nil and W.Dropped ~= W.N then return false end
    return (W.N or 0) == S.Gen
end

local function CheckGen()
    local N = A.WorldGen and A.WorldGen.N or 0
    if N ~= S.Gen then
        -- CAR-8: geaenderten Besitz der alten Welt vor dem Zuruecksetzen sichern (dedizierter Server, ohne UObjects)
        if S.H.OwnDirty then pcall(M.StoreOwners, true) end
        S.Gen = N
        ResetH()
        ResetCl()
        S.HornQ, S.BuyQ, S.BuyRes, S.PushQ = {}, {}, {}, {}
        S.LockQ, S.NoneQ, S.PushAt = {}, {}, {}
    end
    if A.WorldGen and A.WorldGen.Loading and os.clock() - (A.WorldGen.LoadingAt or 0) < 60 then return false end
    return Settled()
end

-- Bewegungskomponente: true = Eingaben nur ueber ReplicatedState (Zuschauer, Beifahrer, Server bei Gast-Fahrer)
local function SetReq(V, Want)
    local MC = V.VehicleMovementComponent
    if not Alive(MC) then return end
    if MC.bRequiresControllerForInputs ~= Want then MC:SetRequiresControllerForInputs(Want) end
end

local function Stats(V)
    local Fu, He = V.FuelComponent, V.VehicleHealthComponent
    if not (Alive(Fu) and Alive(He)) then error("Fuel/Health-Komponente ungueltig") end
    return Fu.CurrentFuel, Fu.MaxFuel, He.CurrentHealth, He.MaxHealth
end

local function Radio(V)
    local RC = V.RadioComponent
    if not Alive(RC) then return false, "" end
    local OnR = RC["TurnedOn?"] == true
    local Song = OnR and A.Safe(function() return RC.CurrentSong:ToString() end, "") or ""
    return OnR, Song
end

local function HasSong(RC, Song)
    local Arr = A.Safe(function() return RC["Found Files"] end) or A.Safe(function() return RC.Found end)
    local Hit = false
    if Arr then
        pcall(function()
            Arr:ForEach(function(_, E) if E:get():ToString() == Song then Hit = true end end)
        end)
    end
    return Hit
end

-- Radio wie beim Spieler im Auto: Titel nur, wenn der Rechner die Datei selbst hat (Radio\*.mp3), sonst still
local function ApplyRadio(V, Want, Song)
    local RC = V.RadioComponent
    if not Alive(RC) then return end
    local Cur, CurSong = Radio(V)
    if A.Settings.server then   -- dedizierter Host: nur Zustand merken (kein Ton)
        RC["TurnedOn?"] = Want
        if Want then RC.CurrentSong = Song end
        return
    end
    if Want then
        if Cur and CurSong == Song then return end
        if Song == "" or not HasSong(RC, Song) then
            if Cur then RC:StopRadio() end
            if not S.Cl.Missing[Song] then S.Cl.Missing[Song] = true Log("Radio: Titel %s fehlt hier, bleibt still", Song) end
            return
        end
        RC.PreviousSong = Song
        RC.CurrentSong = Song
        RC["TurnedOn?"] = true
        RC["Paused?"] = false
        RC:PreviousSongRadio()
    elseif Cur then
        RC:StopRadio()
    end
end

-- Motorgeraeusch bei Zuschauern (das Spiel startet es nur beim Insassen): EngineSound + Timer VehicleSound (RPM)
local function ApplyEngine(V, Want, Key)
    local Cl = S.Cl
    if (Cl.Eng[Key] == true) == Want then return end
    Cl.Eng[Key] = Want or nil
    local Ksl = Find(P.KSL)
    local Snd = A.Safe(function() return V.EngineSound end)
    if not Alive(Snd) then Snd = nil end
    if Want then
        if Snd then pcall(function() Snd:Activate(true) end) end
        -- UE 5.6: K2_SetTimer hat bMaxOncePerFrame (BP_VehicleMaster @2312: "VehicleSound", 0.2, true, false, 0, 0);
        -- alte 6-Argument-Form (5.3) nur als Rueckfall
        if Ksl and not pcall(function() Ksl:K2_SetTimer(V, "VehicleSound", 0.2, true, false, 0, 0) end) then
            pcall(function() Ksl:K2_SetTimer(V, "VehicleSound", 0.2, true, 0, 0) end)
        end
    else
        if Snd then pcall(function() Snd:FadeOut(2.5, 0, 0) end) end
        if Ksl then pcall(function() Ksl:K2_ClearTimer(V, "VehicleSound") end) end
    end
end

-- ===================================================================================== Host

-- Befoerderung: Fahrer weg, Beifahrer im selben Auto wird Fahrer (wie Legacy "start", ohne PlacePawn)
local function Promote(C, PK, Pd)
    local V, PC = Pd.V, Pd.PC
    C.Passengers[PK] = nil
    local D = { V = V, PC = PC, Pawn = Pd.Pawn, Seat = Pd.Seat }
    C.Drivers[PK] = D
    local Hz = math.floor(1 / (C.RATE or (1 / 30)) + 0.5)
    local Nuf = A.Safe(function() return V.NetUpdateFrequency end)
    if (tonumber(A.Settings.car_hz) or 0) > 0 and type(Nuf) == "number" and Nuf < Hz then
        D.Nuf = Nuf
        pcall(function() V.NetUpdateFrequency = Hz end)
    end
    pcall(function() local Mesh = C.Mesh(V) if Alive(Mesh) then Mesh:SetCollisionResponseToChannel(2, 0) end end)
    pcall(function() local MC = V.VehicleMovementComponent if Alive(MC) then MC:SetHandbrakeInput(false) end end)
    pcall(function() V:SetOwner(PC) end)
    if On(F.input) then pcall(SetReq, V, true) S.H.Flagged[Full(V)] = true end
    local L = V:K2_GetActorLocation()
    local G = Net.Guests[PK]
    if G and Net.Has("car2", G) then Net.Send("car_promo", string.format("%.0f|%.0f|%.0f", L.X, L.Y, L.Z), G, 0) end
    local ok, St = pcall(C.State, V)   -- Legacy-carstate: der neue Fahrer uebernimmt den Stand des Servers (StateOk)
    if ok then
        A.SendChunked(function(T) A.SendToClient(PC, T) end, "carstate", string.format("%.0f|%.0f|%.0f|%s|0", L.X, L.Y, L.Z, St))
    end
    Log("%s: Beifahrer %s faehrt jetzt", V:GetFName():ToString(), Short(PK))
end

-- Fahrer/Beifahrer getrennt oder tot: freigeben (Leiche nicht teleportieren, nicht laufen lassen)
-- CORE-19 (world_hygiene): PC frisch ueber den Schluessel (Net.PC), Figur ueber ihren Namen (S.H.SeatPawn je Eintrag,
-- beim ersten Blick gemerkt) - D.Pawn wird nie mehr angefasst (ging eine stop-Meldung verloren und starb die alte
-- Figur, blieb sie gemerkt und IsAlive lief nach der GC auf freiem Speicher)
local function CheckRelease(C, K, D)
    local Fresh = Core.Flag("world_hygiene", true)
    local PC = Fresh and Net.PC(K) or nil
    if not PC and Alive(D.PC) then PC = D.PC end
    local Why
    if not Alive(PC) then
        Why = "getrennt"
    else
        local Pawn = A.Safe(function() return PC:K2_GetPawn() end)
        if not Alive(Pawn) then
            Why = "ohne Figur"
        elseif Fresh then
            local Nm, R = Full(Pawn), S.H.SeatPawn[K]
            if not R or R.D ~= D then R = { D = D, Name = Nm } S.H.SeatPawn[K] = R end
            if R.Name ~= Nm then Why = "neue Figur" end
        elseif Alive(D.Pawn) and Pawn:GetAddress() ~= D.Pawn:GetAddress() then
            Why = "neue Figur"
        end
        if not Why and A.Safe(function() return Pawn["PlayerDead?"] end) == true then Why = "tot" end
    end
    if not Why then return end
    -- CAR-10 (a, car_occdmg): Tod am Steuer wie SP AfterDeath @05fd/@0634 - Motor aus, Gas 0 (sonst blieb das Auto
    -- des Toten fahrbereit; SP braucht danach ein Reparaturset). car_s zeigt allen W=0.
    if Why == "tot" and On(F.occdmg) and C.Drivers[K] == D and Alive(D.V) then
        pcall(function()
            D.V["EngineOn?"] = false
            local MC = D.V.VehicleMovementComponent
            if Alive(MC) then MC:SetThrottleInput(0) end
        end)
        Log("%s: Fahrer %s tot - Motor aus", D.V:GetFName():ToString(), Short(K))
    end
    S.H.SeatPawn[K] = nil
    if Why ~= "getrennt" then D.Pawn = nil end
    local ok, err = pcall(C.Release, K)
    if not ok then Core.Fail(F.pass, err) end
    Log("Freigabe %s (%s)", Short(K), Why)
end

-- InVehicle? auf den Server-Kopien der Gastfiguren und car_seat an alle (Schluessel PlayerId)
local function HostSeats(C)
    local H, Want, Ids = S.H, {}, {}
    local function Add(D, Pass)
        if not Alive(D.V) or not Alive(D.PC) then return end
        local Pawn = Alive(D.Pawn) and D.Pawn or A.Safe(function() return D.PC:K2_GetPawn() end)
        local PS = A.Safe(function() return D.PC.PlayerState end)
        local Id = Alive(PS) and A.Safe(function() return PS.PlayerId end) or nil
        if not Alive(Pawn) or Id == nil then return end
        Want[Full(Pawn)] = { Pawn = Pawn, Id = tostring(Id), Car = D.V:GetFName():ToString(), Pass = Pass }
        Ids[tostring(Id)] = true
    end
    for _, D in pairs(C.Drivers) do Add(D, false) end
    for _, D in pairs(C.Passengers) do Add(D, true) end
    for Name, W in pairs(Want) do
        if not H.InVeh[Name] then
            pcall(function() W.Pawn["InVehicle?"] = true end)
            H.InVeh[Name] = W.Id
        end
        Net.State("car_seat", W.Id, W.Car .. "|" .. (W.Pass and "1" or "0"), 1)
        H.SeatIds[W.Id] = true
    end
    for Name in pairs(H.InVeh) do
        if not Want[Name] then
            local Pawn = Find(Name)
            if Pawn then pcall(function() Pawn["InVehicle?"] = false end) end
            H.InVeh[Name] = nil
        end
    end
    for Id in pairs(H.SeatIds) do
        if not Ids[Id] then Net.State("car_seat", Id, nil) H.SeatIds[Id] = nil end
    end
end

-- CAR-4 (Host, car_tags): Insassen-Tags wie Interact_GetInVehicle @1f44-2133 / Event_ExitVehicle @5bc6-602a. Der Host
-- fuehrt das Einsteigen fuer Gaeste nie aus: Tiere fliehen nicht (ScaresAnimals), Banditen/Militaer reagieren nicht,
-- Landminen (Player = auslassen, Buildable_LandMine @09ca) explodieren unter dem Gastauto. Entfernen ohne TArray:Empty:
-- Eintrag -> None; freie None-Plaetze nimmt das naechste Setzen wieder (Liste waechst nicht). Index = eigener Zaehler
-- in Reihenfolge (1-basiert wie Tags[#Tags + 1], main.lua), nicht der ForEach-Index.
local OCC = { "ScaresAnimals", "Player", "AI", "BanditCanAttack", "MilitaryCanAttack" }
local function OccTags(V, Want)
    local Tags = V.Tags
    local Idx, Free, I = {}, {}, 0
    Tags:ForEach(function(_, E)
        I = I + 1
        local N = E:get():ToString()
        if not Idx[N] then Idx[N] = I end
        if N == "None" then Free[#Free + 1] = I end
    end)
    for _, T in ipairs(OCC) do
        if Want and not Idx[T] then
            local Slot = table.remove(Free, 1)
            if Slot then Tags[Slot] = FName(T) else Tags[#Tags + 1] = FName(T) end
        elseif not Want and Idx[T] then
            Tags[Idx[T]] = FName("None")
        end
    end
end

-- Input-Flag und Overlap der Host-Kopie, solange ein Gast faehrt (Roadkill meldet dann nur der Fahrer)
local function HostDriven(Driven)
    local H = S.H
    for Name, X in pairs(Driven) do
        if On(F.tags) and not H.Tagged[Name] then
            local ok, err = pcall(OccTags, X.V, true)
            if ok then H.Tagged[Name] = true else Core.Fail(F.tags, err) end
        end
        if On(F.input) then
            local ok, err = pcall(SetReq, X.V, true)
            if ok then H.Flagged[Name] = true else Core.Fail(F.input, err) end
        end
        if On(F.hit) then
            local ok, err = pcall(function()
                local Box = X.V.HitBoxCollision
                if Alive(Box) and Box:GetGenerateOverlapEvents() then Box:SetGenerateOverlapEvents(false) end
            end)
            if ok then H.Overlap[Name] = true else Core.Fail(F.hit, err) end
        end
    end
    for Name in pairs(H.Flagged) do
        if not Driven[Name] then
            local V = Find(Name)
            if V then pcall(SetReq, V, false) end
            H.Flagged[Name] = nil
        end
    end
    for Name in pairs(H.LastHp) do   -- Schadensabgleich nur fuer gefahrene Autos
        if not Driven[Name] then H.LastHp[Name], H.HoldHp[Name] = nil, nil end
    end
    for Name in pairs(H.Overlap) do
        if not Driven[Name] then
            local V = Find(Name)
            if V then pcall(function() local Box = V.HitBoxCollision if Alive(Box) then Box:SetGenerateOverlapEvents(true) end end) end
            H.Overlap[Name] = nil
        end
    end
    for Name in pairs(H.Tagged) do   -- CAR-4: beim Freigeben wieder weg (auch mit car_tags=0, sonst blieben sie haengen)
        if not Driven[Name] then
            local V = Find(Name)
            if V then pcall(OccTags, V, false) end
            H.Tagged[Name] = nil
        end
    end
end

-- Fahrgeraeusch wie Event_Noise (alle 2 s @2365, Reichweite 3500 in UE 5.6 @5adc, 5.3: 2500), Verursacher = Gastfigur
local function HostNoise(Driven, World)
    local Hear = Find(P.HEAR)
    if not Hear then return end
    for _, X in pairs(Driven) do
        pcall(function()
            local Fu, _, Hp = Stats(X.V)
            if Fu <= 0 or Hp <= 0 then return end
            local Pawn = Alive(X.D.Pawn) and X.D.Pawn or (Alive(X.D.PC) and X.D.PC:K2_GetPawn() or nil)
            if not Alive(Pawn) then return end
            local Mesh = X.V.Mesh
            if not Alive(Mesh) then return end
            Hear:ReportNoiseEvent(World, Mesh:K2_GetComponentLocation(), 1, Pawn, 3500, FName("Noise"))
        end)
    end
end

-- CAR-17 (car_trunkn): Anzahl im Kofferraum wie UpdateStorageStat @19f7 (Host-Jig GetContainerItems(false) ->
-- Array_Length); Ausgabeparameter kommt als Lua-Tabelle (AllItems) oder TArray. nil = unlesbar
local function TrunkCount(V)
    local Jig = A.Safe(function() return V.BP_JigMultiplayer end)
    if not Alive(Jig) then return nil end
    local T = {}
    if not pcall(function() Jig:GetContainerItems(false, T) end) then return nil end
    local L = T.AllItems
    if L == nil then for _, X in pairs(T) do L = X break end end
    if type(L) == "table" then return #L end
    if L ~= nil then return tonumber(A.Safe(function() return L:GetArrayNum() end)) end
    return nil
end

-- Keyed-State car_s fuer alle Autos (1 s); Kofferraum einmal je Auto replizieren
-- CAR-14 (1, car_perf): Autoliste aus main.lua (Cars) statt eigenem FindAllOf.
-- CAR-18 (car_perf): Fehler je Auto zaehlen - nach 3 Fehlern 60 s auslassen (Stand bleibt), auf car_fx hoechstens
-- einmal je Auto und Minute (ein Auto mit ungueltigen Komponenten schaltete sonst car_fx fuer alle ab).
-- CAR-17 (car_trunkn): alle 3 s die Kofferraum-Anzahl als Keyed-State car_n (K32, nur Aenderungen gehen raus).
local function HostState(Driven, Now)
    local H, Seen = S.H, {}
    Now = Now or os.clock()
    local Perf = On(F.perf)
    local Trunk = On(F.trunkn) and Now >= (H.TrunkAt or 0)
    if Trunk then H.TrunkAt = Now + 3 end
    local SeenN, GPos = {}, {}
    -- car_towsync: TowingVehicle? ist nicht repliziert (SaveGame ohne CPF_Net) und wird nach dem Laden nur beim Host
    -- wieder angekuppelt (ActorLoaded -> @0617/@0621) -> eigener Keyed-State car_tw (car_s-Format bleibt, Song am Ende)
    local TwOn = On(F.tow) and On(F.towsync)
    if Trunk then   -- gezaehlt wird nur nahe einem Gast (<= 5000): angezeigt wird es erst beim Anschauen des Autos
        Net.ForEachGuest(function(G)
            local PC = Net.PC(G)
            local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
            local L = Alive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end)
            if L then GPos[#GPos + 1] = L end
        end)
    end
    for _, V in ipairs(Perf and Cars() or FindAllOf("BP_VehicleMaster_C") or {}) do
        local Name = Alive(V) and Full(V) or nil
        local Bd = Name and Perf and H.Bad[Name] or nil
        if Name and Bd and Bd.N >= 3 and Now < (Bd.Until or 0) then
            local K0 = A.Safe(function() return V:GetFName():ToString() end)
            if K0 then Seen[K0], SeenN[K0] = true, H.TrunkN[K0] end   -- ausgelassen: alter Stand bleibt
        elseif Name then
            local ok, err = pcall(function()
                local Key = V:GetFName():ToString()
                Seen[Key], SeenN[Key] = true, H.TrunkN[Key]
                local Fu, MaxFu, Hp, MaxHp = Stats(V)
                local L = V:K2_GetActorLocation()
                local Snd = A.Safe(function() return V.EngineSound end)
                local Run = (Driven[Name] ~= nil and Fu > 0) or (Alive(Snd) and A.Safe(function() return Snd:IsActive() end) == true)
                local ROn, Song = false, ""
                if On(F.radio) then ROn, Song = Radio(V) end
                local Val = string.format("%d|%d|%d|%.1f|%.1f|%.1f|%.1f|%s|%s|%s|%d|%s|%s", Q(L.X), Q(L.Y), Q(L.Z),
                    Fu, MaxFu, Hp, MaxHp, B(V["LightsOn?"]), B(V["EngineOn?"]), B(Run),
                    tonumber(V.VehicleColor) or -1, B(ROn), Song)
                Net.State("car_s", Key, Val, 1)
                if TwOn then Net.State("car_tw", Key, B(V["TowingVehicle?"] == true), 1) end
                -- Kofferraum: eigener pcall, Fehler zaehlen auf car_trunk (nicht car_fx). GetIsReplicated ist kein
                -- UFUNCTION -> Eigenschaft bReplicates lesen (nil = unlesbar -> trotzdem versuchen)
                if On(F.trunk) and not H.Trunk[Name] then
                    H.Trunk[Name] = true
                    local okT, errT = pcall(function()
                        local Jig = V.BP_JigMultiplayer
                        if Alive(Jig) and A.Safe(function() return V.bReplicates end) ~= false then
                            Jig:SetIsReplicated(true)
                            V:ForceNetUpdate()
                        end
                    end)
                    if not okT then Core.Fail(F.trunk, errT) end
                end
                local NearG = false
                for _, Gp in ipairs(Trunk and GPos or {}) do
                    if D2(Gp, L.X, L.Y, L.Z) <= 5000 ^ 2 then NearG = true break end
                end
                if NearG then
                    local okN, N = pcall(TrunkCount, V)
                    if okN and N then
                        SeenN[Key] = N
                        Net.State("car_n", Key, tostring(N), 2)
                    elseif not okN then
                        Core.Fail(F.trunkn, N)
                    end
                end
            end)
            if ok then
                if Bd then H.Bad[Name] = nil end
            elseif not Perf then
                if Core.Fail(F.fx, err) then return end
            else
                Bd = Bd or { N = 0 }
                H.Bad[Name], Bd.N = Bd, Bd.N + 1
                if Bd.N >= 3 then Bd.Until = Now + 60 end
                if Bd.N == 3 then Log("car_s: %s nach 3 Fehlern 60 s ausgelassen (%s)", Short(Name), tostring(err)) end
                if Now >= (Bd.FailAt or 0) then
                    Bd.FailAt = Now + 60
                    if Core.Fail(F.fx, err) then return end
                end
            end
        end
    end
    for Key in pairs(H.Keys) do
        if not Seen[Key] then Net.State("car_s", Key, nil) Net.State("car_tw", Key, nil) end
    end
    if not TwOn then   -- Schalter aus: Abschlepp-Stand zuruecknehmen (Net.State sendet nur Aenderungen)
        for Key in pairs(Seen) do Net.State("car_tw", Key, nil) end
    end
    H.Keys = Seen
    if Trunk or not On(F.trunkn) then   -- CAR-17: verschwundene Autos (bzw. Schalter aus) -> car_n weg
        for Key in pairs(H.TrunkN) do
            if not Trunk or SeenN[Key] == nil then Net.State("car_n", Key, nil) end
        end
        H.TrunkN = Trunk and SeenN or {}
    end
end

-- Server-Schaden gegen den Fahrerwert: PoseHp sendet "carstate" an den Fahrer, der den Stand dann uebernimmt
local function HostPushHp(C)
    local H = S.H
    for Key in pairs(H.PushHp) do
        H.PushHp[Key] = nil
        local D = C.Drivers[Key]
        if D and Alive(D.V) and Alive(D.PC) then
            local ok, St = pcall(C.State, D.V)
            if ok then
                local L = D.V:K2_GetActorLocation()
                A.SendChunked(function(T) A.SendToClient(D.PC, T) end, "carstate",
                    string.format("%.0f|%.0f|%.0f|%s|0", L.X, L.Y, L.Z, St))
            end
        end
    end
end

-- CAR-6 (car_fuelhold): Gast B tankt, waehrend Gast A faehrt. A's Piggyback (alter Tank, main.lua "pose":
-- min(Gast, Host)) kam vor dem neuen carstate an und senkte den Host-Wert wieder -> 3 s lang den getankten Wert halten:
-- wieder setzen und erneut an den Fahrer schicken (PushHp -> carstate). Verbrauch in den 3 s ist vernachlaessigbar.
local function HoldFuel(C, Driven, Now)
    local H = S.H
    for Name, Hd in pairs(H.HoldFu) do
        local X = Driven[Name]
        if Now > Hd.Until then
            H.HoldFu[Name] = nil
        elseif X then
            local Fu, MaxFu, Hp, MaxHp = Stats(X.V)
            if Fu < Hd.Fuel - 0.5 then
                C.ApplyState(X.V, Hd.Fuel, MaxFu, Hp, MaxHp, false)
                H.PushHp[X.K] = true
                if not Hd.Logged then
                    Hd.Logged = true
                    Log("%s: Tank %.1f -> %.1f gehalten (Fahrerstand war aelter als das Tanken)", Short(Name), Fu, Hd.Fuel)
                end
            end
        end
    end
end

-- CAR-10 (b, car_occdmg): SP ReceiveAnyDamage @6a3e-6bc1 - Auto bei 0 HP und nicht UnderWater: Schaden *
-- Difficulty.DamageMultiplier an den Spieler im Auto (GetPlayerCharacter(0) = beim Host der Geist). Hier je Gast im
-- Auto aus den ApplyDamage-Ereignissen der DLL (cb_dmg von ls_combat, own_dmg von ls_build; Args: Ziel "Klasse Pfad",
-- Schaden, ...) mit eigenem Cursor "_car". Ohne Beobachter keine Ereignisse -> still nichts. Der Cursor laeuft auch
-- ohne Insassen weiter (sonst kaemen alte Treffer beim naechsten Einsteigen nach).
function Late.OccDamage(C)
    local Nat = A.Coop.Modules and A.Coop.Modules.ls_native
    if type(Nat) ~= "table" or type(Nat.ReadEvents) ~= "function" then return end
    local Evs = Nat.ReadEvents("_car")
    if #Evs == 0 then return end
    local Seats = {}
    local function Add(K, D)
        if not Alive(D.V) then return end
        local N = Full(D.V)
        Seats[N] = Seats[N] or { V = D.V }
        table.insert(Seats[N], K)
    end
    for K, D in pairs(C.Drivers) do Add(K, D) end
    for K, D in pairs(C.Passengers) do Add(K, D) end
    if next(Seats) == nil then return end
    local Gps, Dt, Mult
    for _, Ev in ipairs(Evs) do
        local Args = (Ev.Tag == "cb_dmg" or Ev.Tag == "own_dmg") and type(Ev.Args) == "table" and Ev.Args or nil
        local Path = Args and tostring(Args[1] or ""):match("^%S+ (.+)$")
        local Seat = Path and Seats[Path]
        local Dmg = Seat and tonumber(Args[2]) or 0
        if Dmg > 0 then
            local V = Seat.V
            local HC = V.VehicleHealthComponent
            if Alive(HC) and (tonumber(HC.CurrentHealth) or 1) <= 0 and V.UnderWater ~= true then
                Gps, Dt = Gps or Find(P.GPS), Dt or Find(P.DMGT)
                if not Mult then
                    local CU = Find(P.CU)
                    Mult = CU and tonumber(A.Safe(function() return CU:GetFloatCVar(FName("Difficulty.DamageMultiplier")) end)) or 1
                    if Mult <= 0 then Mult = 1 end
                end
                if not (Gps and Dt) then return end
                for _, K in ipairs(Seat) do
                    local PC = Net.PC(K)
                    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
                    if Alive(Pawn) and A.Safe(function() return Pawn["PlayerDead?"] end) ~= true then
                        pcall(function() Gps:ApplyDamage(Pawn, Dmg * Mult, nil, V, Dt) end)
                        if not S.H.Logged["occ|" .. K] then
                            S.H.Logged["occ|" .. K] = true
                            Log("%s: Wrack (0 HP) - Treffer %.0f geht an %s durch", V:GetFName():ToString(), Dmg * Mult, Short(K))
                        end
                    end
                end
            end
        end
    end
end

-- Hupe des Host-Spielers (Listen-Server) an alle Gaeste
local function HostOwnHorn()
    if #S.HornQ == 0 then return end
    S.HornQ = {}
    local Pawn = A.OwnPawn()
    local VDC = Alive(Pawn) and Pawn["InVehicle?"] and A.Safe(function() return Pawn.VehicleDrivingComponent end)
    local V = Alive(VDC) and A.Safe(function() return VDC.Vehicle end)
    if not Alive(V) then return end
    local L = V:K2_GetActorLocation()
    Net.ForEachGuest(function(G)
        if G.Epoch and Net.Has("car2", G) then
            Net.Send("car_horn", string.format("%s|%.0f|%.0f|%.0f", V:GetFName():ToString(), L.X, L.Y, L.Z), G, 1)
        end
    end)
end

local function HostFast(Now)
    if Net.Side ~= "host" or not Core.Flag(FLAG, true) then return end
    if not CheckGen() then return end
    local C = A.Coop.Car
    if not (C and C.Drivers and C.Passengers) then return end
    local World = A.CurrentWorld()
    if not Alive(World) then return end
    if On(F.pass) then
        for K, D in pairs(C.Drivers) do CheckRelease(C, K, D) end
        for K, D in pairs(C.Passengers) do CheckRelease(C, K, D) end
        for K, R in pairs(S.H.SeatPawn) do   -- CORE-19: Eintraege ohne Sitz mehr (stop, Release in main.lua) weg
            if C.Drivers[K] ~= R.D and C.Passengers[K] ~= R.D then S.H.SeatPawn[K] = nil end
        end
        for PK, Pd in pairs(C.Passengers) do
            local G = Net.Guests[PK]
            if Alive(Pd.V) and Alive(Pd.PC) and G and Net.Has("car2", G) then
                local Has = false
                for _, D in pairs(C.Drivers) do if D.V == Pd.V then Has = true break end end
                if not Has then
                    if M.CanUse(G, Pd.V) == true then   -- CAR-8 (car_lock): ohne Schloss/als Besitzer/Clan wie bisher
                        local ok, err = pcall(Promote, C, PK, Pd)
                        if not ok then Core.Fail(F.pass, err) end
                    elseif not Pd.LockHeld then
                        -- CAR-8: abgeschlossenes fremdes Auto - Beifahrer wird nicht Fahrer (bleibt sitzen, steigt normal aus;
                        -- nach dem Aufschliessen befoerdert ihn der naechste Lauf). Release (main.lua) hat das Auto fuer ihn
                        -- offen gelassen (HeldOpen): Handbremse hier nachholen, Kapsel bleibt offen (sitzende Server-Figur),
                        -- der Ausstieg holt sie nach. Merker am Sitz-Eintrag: Hinweis/Handbremse einmal je Einsteigen.
                        -- NoteTo steht weiter unten (lokal) - hier direkt senden
                        Pd.LockHeld = true
                        pcall(function() local MC = Pd.V.VehicleMovementComponent if Alive(MC) then MC:SetThrottleInput(0) MC:SetHandbrakeInput(true) end end)
                        Log("%s: Beifahrer %s nicht befoerdert (abgeschlossen)", A.Safe(function() return Pd.V:GetFName():ToString() end) or "?", Short(PK))
                        local PCn = Net.PC(G)
                        if Alive(PCn) then pcall(A.SendChunked, function(T) A.SendToClient(PCn, T) end, "note", "Fahrzeug abgeschlossen") end
                    end
                end
            end
        end
    end
    local Driven = {}
    for K, D in pairs(C.Drivers) do
        if Alive(D.V) then Driven[Full(D.V)] = { V = D.V, K = K, D = D } end
    end
    HostDriven(Driven)
    -- CAR-5 (car_water): Timer "CheckWater" (0,5 s, @221c) laeuft nur beim Insassen; beim Gast schluckt die Kopie den
    -- Schaden (ReceiveAnyDamage BlueprintAuthorityOnly) -> Host prueft seine Kopie (5-10 Schaden + UnderWater wie SP)
    if On(F.water) and Now >= (S.H.WaterAt or 0) then
        S.H.WaterAt = Now + 0.5
        for _, X in pairs(Driven) do
            local ok, err = pcall(function() X.V:CheckWater() end)
            if not ok and Core.Fail(F.water, err) then break end
        end
    end
    if On(F.seat) then Try(F.seat, HostSeats, C) end
    if On(F.fuelhold) and next(S.H.HoldFu) then Try(F.fuelhold, HoldFuel, C, Driven, Now) end
    if On(F.dmg) then Try(F.dmg, HostPushHp, C) end
    if On(F.occdmg) then Try(F.occdmg, Late.OccDamage, C) end   -- CAR-10 (b)
    if On(F.horn) then Try(F.horn, HostOwnHorn) end
    local H = S.H
    -- CAR-14 (2, car_perf): ohne Gaeste weder car_s (FindAllOf + ~15 Aufrufe je Auto) noch Fahrlaerm (live56: car_host
    -- 14 ms mit 0 Gaesten); ein neuer Gast bekommt beim ersten Lauf alles (Net.State: volle Auffrischung bei ready)
    local Guests = not On(F.perf) or next(Net.Guests) ~= nil
    if Guests and On(F.noise) and Now >= H.NoiseAt then H.NoiseAt = Now + 2 Try(F.noise, HostNoise, Driven, World) end
    if Guests and On(F.fx) and Now >= H.StateAt then H.StateAt = Now + 1 Try(F.fx, HostState, Driven, Now) end
    if On(F.lock) then   -- CAR-8: Schloss-Anfragen, Besitz laden/zuordnen, Kofferraum-Sperre (1 s)
        if #S.LockQ > 0 then Try(F.lock, Late.LockFlush) end
        if Now >= (H.LkAt or 0) then H.LkAt = Now + 1 Try(F.lock, Late.LockTick, Now) end
    elseif H.DenySig ~= nil then
        pcall(Late.LockOff)
    end
end

-- Rate je Gast und kind (Host-Validierung)
local function RateOk(G, Kind, PerSec)
    local H, Now = S.H, os.clock()
    local K = G.Key .. "|" .. Kind
    local R = H.Rate[K]
    if not R or Now - R.T >= 1 then R = { T = Now, N = 0 } H.Rate[K] = R end
    R.N = R.N + 1
    if R.N > PerSec then
        if R.N == PerSec + 1 then Net.SecWarn(G, G.Key, Kind .. "_rate") end
        return false
    end
    return true
end

local function GuestSeat(G)
    local C = A.Coop.Car
    local D = C and (C.Drivers[G.Key] or C.Passengers[G.Key])
    if D and Alive(D.V) then return D, C end
    return nil, C
end

-- CAR-8 Helfer (vor den Handlern, car_buy/car_push/car_svc nutzen sie)
local function GidOf(G) return type(G) == "table" and G.GuestId and tostring(G.GuestId):lower() or nil end

-- gleicher Gast oder gleicher Clan (ls_clan Allied, zur Laufzeit gesucht)
local function Allied(GidA, GidB)
    if not (GidA and GidB) then return false end
    if GidA == GidB then return true end
    local Clan = A.Coop.Clan
    if type(Clan) ~= "table" or type(Clan.Allied) ~= "function" then return false end
    local ok, R = pcall(Clan.Allied, GidA, GidB)
    return ok and R == true
end

local function GuestName(G)
    local PC = Net.PC(G)
    local PS = PC and A.Safe(function() return PC.PlayerState end)
    local Nm = Alive(PS) and A.Safe(function() return PS:GetPlayerName():ToString() end) or nil
    Nm = tostring(Nm or "?"):gsub("[|;=%%\r\n]", ""):sub(1, 24)
    return Nm ~= "" and Nm or "?"
end

-- legacy "note" an einen Gast (main.lua HostDataHandlers.note)
local function NoteTo(PC, Text)
    if Alive(PC) and Text then pcall(A.SendChunked, function(T) A.SendToClient(PC, T) end, "note", Text) end
end

-- Neuer Besitz-Eintrag (Host)
local function NewOwn(V, Gid, Name)
    local L = V:K2_GetActorLocation()
    return { Gid = Gid, Name = Name, Lock = false, Path = Full(V), X = L.X, Y = L.Y, Z = L.Z,
             Cls = A.Safe(function() return V:GetClass():GetFName():ToString() end) or "?" }
end

-- ===================================================================================== Gast

-- Autoindex (FindAllOf hoechstens 1 Hz): voller Name, FName, Geist (lokal gespawnt: HasAuthority beim Client)
-- CAR-14 (4): mit Lage (X/Y/Z, hoechstens 1 s alt) als Vorfilter fuer Resolve und die offenen car_s
local function BuildIndex(Now)
    local Cl = S.Cl
    if Now < (Cl.IndexAt or 0) then return false end
    Cl.IndexAt = Now + 1
    local Index, Pos = {}, On(F.perf)
    for _, V in ipairs(Cars()) do
        if Alive(V) then
            local E = { Full = Full(V), Name = V:GetFName():ToString(),
                        Cls = A.Safe(function() return V:GetClass():GetFName():ToString() end),
                        Ghost = A.Safe(function() return V:HasAuthority() end) == true }
            if Pos then
                local L = A.Safe(function() return V:K2_GetActorLocation() end)
                if L then E.X, E.Y, E.Z = L.X, L.Y, L.Z end
            end
            Index[#Index + 1] = E
        end
    end
    Cl.Index = Index
    return true
end

-- CAR-2 (Gast, car_ghost): Geisterautos. Spawner-Kopien mit lokaler Authority (beim Gast nicht repliziert) spawnen
-- eigene Autos: OnCompleted @032f -> HasAuthority -> Svr_Spawn laeuft lokal, nach 6-8 s (@0409) Spawn @000f.
-- SpawnerUsed? = true vorher -> @000f bricht ab ("Already Used"). Schon entstandene Geister (Role Authority,
-- repliziert, nicht aus der Karte, nicht das eigene) nach 5 s weg (wie ls_ai C.GhostStep). Unabhaengig von car2.
local GHOST_SP = { "BP_VehicleSpawner_C", "BP_VehicleUniqueSpawner_C" }
local function GhostCars(Now)
    local Cl = S.Cl
    local WL = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not WL then return end
    if Now >= (Cl.GhostSpAt or 0) then   -- Spawner: 120 s nach dem Weltwechsel alle 3 s, danach alle 30 s
        Cl.GhostSpAt = Now + (Now - (Cl.Since or Now) < 120 and 3 or 30)
        for _, Cls in ipairs(GHOST_SP) do
            for _, Sp in ipairs(FindAllOf(Cls) or {}) do
                if Alive(Sp) and A.Safe(function() return Sp.Role == 3 and Sp["SpawnerUsed?"] ~= true end, false) == true then
                    pcall(function() Sp["SpawnerUsed?"] = true end)
                    Cl.GhostSp = Cl.GhostSp + 1
                    if Cl.GhostSp == 1 then Log("Geister-Spawner gesperrt (%s, lokale Authority)", Cls) end
                end
            end
        end
    end
    if Now < (Cl.GhostAt or 0) then return end
    Cl.GhostAt = Now + 5
    local C = A.Coop.Car
    local Own = C and C.Driving
    if not Alive(Own) then Own = nil end
    local Seen, N = {}, 0
    for _, V in ipairs(Cars()) do
        if Alive(V) and not (Own and V == Own) and A.Safe(function()
                return V.Role == 3 and V.bReplicates == true and not V:HasAnyFlags(WL) end, false) == true then
            local Name = Full(V)
            N, Seen[Name] = N + 1, true
            Cl.GhostT[Name] = Cl.GhostT[Name] or Now
            if Now - Cl.GhostT[Name] >= 5 and pcall(function() V:K2_DestroyActor() end) then
                Cl.GhostDel, Cl.GhostT[Name] = Cl.GhostDel + 1, nil
                Log("Geisterauto %s entfernt (lokaler Spawn)", Name:match("[^%.:]+$") or Name)
            end
        end
    end
    for Name in pairs(Cl.GhostT) do if not Seen[Name] then Cl.GhostT[Name] = nil end end
    Cl.GhostN = N
end

-- Auto zum Host-Schluessel (Host-FName): Laufzeit-Autos (gekauft/gespawnt) haben beim Gast einen ANDEREN FName,
-- daher Klasse (aus dem Schluessel "<Klasse>_<N>") + Lage; gleicher Name nur als Abkuerzung fuer Map-Autos < 2000,
-- sonst naechstes ungebundenes derselben Klasse < 800; Bindung als voller Name
local function Resolve(Key, X, Y, Z)
    Key = tostring(Key)
    local KCls = Key:match("^(.-)_%d+$")
    local Cl = S.Cl
    if #Cl.Index == 0 then BuildIndex(os.clock()) end
    local Bound = Cl.Bind[Key]
    if Bound then
        local V = Find(Bound)
        -- CAR-18: eigenes Auto (Fahrer/Beifahrer) nie wegen Abstand loesen (Lagepause bei Ping > 400 ms: Host-Lage
        -- liegt dann weit zurueck, sonst band Resolve ein anderes Auto derselben Klasse)
        local Mine = V and On(F.perf) and (Bound == Cl.OwnFull or Bound == Cl.FxFor)
        if V and (Mine or not X or D2(V:K2_GetActorLocation(), X, Y, Z) < 3000 ^ 2) then return V end
        Cl.Bind[Key], Cl.Rev[Bound] = nil, nil
    end
    if not X then return nil end
    local Best, BestD = nil, 800 ^ 2
    for _, E in ipairs(Cl.Index) do
        -- CAR-14 (4): Indexlage als Vorfilter (6000 = 2000 Namensabkuerzung + Fahrt seit dem Index), Find nur fuer Kandidaten
        local Near = not E.X or D2(E, X, Y, Z) < 6000 ^ 2
        if Near and not E.Ghost and (not KCls or not E.Cls or E.Cls == KCls) and (not Cl.Rev[E.Full] or Cl.Rev[E.Full] == Key) then
            local V = Find(E.Full)
            if V then
                local Dd = D2(V:K2_GetActorLocation(), X, Y, Z)
                if E.Name == Key and Dd < 2000 ^ 2 then Best, BestD = E.Full, -1 break end
                if Dd < BestD then Best, BestD = E.Full, Dd end
            end
        end
    end
    if not Best then return nil end
    Cl.Bind[Key], Cl.Rev[Best] = Best, Key
    return Find(Best)
end

local function OwnState()
    local C = A.Coop.Car
    if not Settled() then return C, nil, false end   -- CORE-8: C.Driving kann noch aus der alten Welt sein
    local V = C and C.Driving
    if not Alive(V) then return C, nil, false end
    return C, V, C.Confirmed == true and C.PassengerOf ~= V
end

-- car_s anwenden (ausser Tank/Zustand/Licht des selbst gefahrenen Autos: dort zaehlt der Fahrer)
local function ApplyCar(Key, Value)
    local Fd = {}
    for Part in (Value .. "|"):gmatch("([^|]*)|") do Fd[#Fd + 1] = Part end
    if #Fd < 12 then return end
    local X, Y, Z = tonumber(Fd[1]) or 0, tonumber(Fd[2]) or 0, tonumber(Fd[3]) or 0
    local V = Resolve(Key, X, Y, Z)
    if not V then S.Cl.Pend[Key] = Value return end   -- Auto (noch) nicht da: im 1-s-Task erneut
    S.Cl.Pend[Key] = nil
    local C, Own, Driver = OwnState()
    local Mine = Own == V
    local Driving = Mine and Driver
    local Fu, MaxFu, Hp, MaxHp = tonumber(Fd[4]) or 0, tonumber(Fd[5]) or 0, tonumber(Fd[6]) or 0, tonumber(Fd[7]) or 0
    if not Driving and C and C.ApplyState then
        local LF, _, LH = Stats(V)
        if math.abs(LF - Fu) > 0.05 or math.abs(LH - Hp) > 0.05 then
            C.ApplyState(V, Fu, MaxFu, Hp, MaxHp, false)
            local Pv = S.Cl.Prev   -- Wertsprung-Erkennung: ein Host-Wert ist kein Tanken
            if Pv and Pv.Name == Full(V) then Pv.Fu, Pv.Hp = Fu, Hp end
            -- CAR-9: mit ApplyState-Wrapper (car_polish) macht das der Wrapper fuer jeden Insassen
            local VUI = Mine and not (S.Wrapped.ApplyState and On(F.polish)) and A.Safe(function() return V.VehicleUI end)
            if Alive(VUI) then   -- Beifahrer: Anzeige im Auto (VehicleUI) wie beim Fahrer
                pcall(function() VUI:UpdateFuel(Fu, MaxFu) end)
                pcall(function() VUI:UpdateHealth(Hp, MaxHp) end)
            end
        end
    end
    local Col = tonumber(Fd[11]) or -1
    if Col >= 0 and V.VehicleColor ~= Col then
        pcall(function()
            local Mat = V.Colors[Col + 1]
            local Mesh = V.Mesh
            if Mat and Alive(Mesh) then Mesh:SetMaterial(0, Mat) end
            V.VehicleColor = Col
            V["RandomColorSelected?"] = true
        end)
    end
    if not Driving then
        V["EngineOn?"] = Fd[9] == "1"
        local WantL = Fd[8] == "1"
        if V["LightsOn?"] ~= WantL then V:TurnOnOffLights() end
    end
    if Mine then S.Cl.Eng[Key] = nil else ApplyEngine(V, Fd[10] == "1", Key) end   -- Insasse: das Spiel selbst
    if On(F.radio) then
        local WantR, Song = Fd[12] == "1", table.concat(Fd, "|", 13)
        if Mine then
            -- anderer Insasse hat umgeschaltet: nur uebernehmen, wenn wir seit der letzten Meldung nichts geaendert haben
            local LR, LS = Radio(V)
            local Local = (LR and "1" or "0") .. "|" .. LS
            if Local == S.Cl.SentR and Local ~= (Fd[12] .. "|" .. Song) then
                ApplyRadio(V, WantR, Song)
                S.Cl.SentR = Fd[12] .. "|" .. Song
            end
        else
            -- CAR-21 (car_polish): am Liedende waehlt jedes Radio selbst zufaellig weiter (RadioComponent @0874 ->
            -- StartRadio @047e); kam danach car_s mit demselben Host-Titel (auch wegen Tank/Lage), startete der alte Titel
            -- hier von vorn. Laeuft das eigene Radio, nur einen NEUEN Host-Stand anwenden.
            local Prior = S.Cl.RadioFrom[Key]
            local Cur = Radio(V)
            if not (On(F.polish) and WantR and Cur and Prior == Song) then ApplyRadio(V, WantR, Song) end
            S.Cl.RadioFrom[Key] = WantR and Song or nil
        end
    end
end

local function PawnById(Id)
    for _, PS in ipairs(A.PlayerStates(A.CurrentWorld()) or {}) do
        if tostring(A.Safe(function() return PS.PlayerId end)) == Id then
            local Pawn = A.Safe(function() return PS:GetPawn() end)
            return Alive(Pawn) and Pawn or nil
        end
    end
    return nil
end

-- CAR-11 (car_seatanim): Sitzpose fuer spaete Joiner/verlorene Pakete. Einsteigen spielt Chr_SitInCar_Montage nur
-- einmal (UB @2c54 PlayMontage -> Svr_Montage/MC_Montage, beide unzuverlaessig); die AnimBP liest InVehicle? nur als
-- Fall-/Blend-Flag. Montage per Find, sonst LoadAsset hoechstens alle 30 s.
local function SitMontage(Now)
    local Mon = Find(P.SIT)
    if not Mon and Now >= (S.Cl.SitTry or 0) then
        S.Cl.SitTry = Now + 30
        Mon = A.Safe(function() return LoadAsset(P.SIT) end)
        if not Alive(Mon) then Mon = nil end
    end
    return Mon
end

local function ApplySeat(Id, Value)
    local Pawn = PawnById(Id)
    local Own = A.OwnPawn()
    if not Pawn or (Alive(Own) and Own:GetAddress() == Pawn:GetAddress()) then return end
    local Want = Value ~= nil
    if Pawn["InVehicle?"] ~= Want then Pawn["InVehicle?"] = Want end
    -- wie SP genau einmal je Sitz-Stand (Cl.Sit[Id] = Wert@Figur): nicht nachspielen, falls die Montage selbst endet
    local Cl = S.Cl
    if not On(F.seatanim) or A.Settings.server then return end
    -- CAR-11b: einmal je Sitz-Stand UND Figur-Instanz (Relevanz weg/zurueck = neue Figur -> Sitzpose neu spielen)
    local Tag = Want and (tostring(Value) .. "@" .. (A.Safe(function() return Full(Pawn) end) or "?")) or nil
    if Cl.Sit[Id] == Tag then return end
    local Mon = SitMontage(os.clock())
    if not Mon then return end
    local Cur = A.Safe(function() return Pawn:GetCurrentMontage() end)
    local Is = Alive(Cur) and Cur:GetAddress() == Mon:GetAddress()
    if Want and not Is then
        local ok, err = pcall(function() Pawn:PlayAnimMontage(Mon, 1, FName("None")) end)
        if not ok then Core.Fail(F.seatanim, err) end
    elseif not Want and Is then
        pcall(function() Pawn:StopAnimMontage(Mon) end)
    end
    Cl.Sit[Id] = Tag
end

-- Eigenes Auto: Flag false nur als bestaetigter Fahrer; Licht (Fahrer) und Radio (jeder Insasse) an den Host
local function OwnCar(V, Driver)
    local Cl = S.Cl
    local Name = V and Full(V) or nil
    if On(F.input) then
        local OwnName = Driver and Name or nil
        if Cl.OwnFull and Cl.OwnFull ~= OwnName then
            local Old = Find(Cl.OwnFull)
            if Old then pcall(SetReq, Old, true) end
        end
        Cl.OwnFull = OwnName
        if V then
            local ok, err = pcall(SetReq, V, not Driver)
            if not ok then Core.Fail(F.input, err) end
        end
    end
    if not V then Cl.FxFor = nil return end
    local L = V["LightsOn?"] == true
    local ROn, Song = Radio(V)
    local R = (ROn and "1" or "0") .. "|" .. Song
    if Cl.FxFor ~= Name then Cl.FxFor, Cl.SentL, Cl.SentR = Name, L, R end   -- beim Einsteigen: Stand merken
    local SendL = Driver and On(F.fx) and L ~= Cl.SentL
    local SendR = On(F.radio) and R ~= Cl.SentR
    if SendL or SendR then
        if Net.Send("car_in", string.format("%s|%s", SendL and B(L) or "-", SendR and R or "-|"), nil, 1) then
            if SendL then Cl.SentL = L end
            if SendR then Cl.SentR = R end
        end
    end
end

local function Passenger(V)
    local Cl = S.Cl
    local Name = Full(V)
    if Cl.PassFor == Name then return end
    Cl.PassFor = Name
    pcall(function() local Fu = V.FuelComponent if Alive(Fu) then Fu:StopSpendFuel() end end)   -- Tank kommt vom Host (car_s), lokal nicht doppelt verbrauchen
    pcall(SetReq, V, true)
    Log("Beifahrer in %s: Eingaben gesperrt", V:GetFName():ToString())
end

local function IsDead(Ch)
    return A.Safe(function() return Ch.Dead end) == true or A.Safe(function() return Ch["IsDead?"] end) == true
end

-- CAR-13: Abstand Punkt Q zur Strecke A->B (2D, Quadrat)
local function SegD2(Ax, Ay, Bx, By, Qx, Qy)
    local Dx, Dy = Bx - Ax, By - Ay
    local L2 = Dx * Dx + Dy * Dy
    local T = L2 > 1 and math.max(0, math.min(1, ((Qx - Ax) * Dx + (Qy - Ay) * Dy) / L2)) or 0
    return (Qx - Ax - T * Dx) ^ 2 + (Qy - Ay - T * Dy) ^ 2
end

-- Roadkill (SP: HitBoxCollision-Overlap vorn, |MPH| >= 5, KI nicht tot), eigene Pruefung 5 Hz.
-- CAR-13 (car_sweep2): Strecke seit der letzten Pruefung (PrevPos -> jetzt, Radius 250) statt Kreis 330 um die
-- Mitte - lueckenlos auch ueber ~120 km/h - und nur vor dem Auto (Vorwaerts-Vektor, wie die HitBox vorn, UB @662f;
-- seitlich/hinter dem Auto zaehlt nicht mehr). Der ls_ai-Zweig (OnCarSweep) war tot (ls_ai hat ihn nicht): nur ohne
-- car_sweep2 noch gefragt.
local function Sweep(V, Now)
    local Cl = S.Cl
    local MC = V.VehicleMovementComponent
    if not Alive(MC) then return end
    local Mph = math.abs(tonumber(MC:GetForwardSpeedMPH()) or 0)
    local Prev = Cl.PrevMph
    Cl.PrevMph = Mph
    if math.max(Mph, Prev) < 5 then return end
    local Pl, Vel = V:K2_GetActorLocation(), V:GetVelocity()
    local Len = math.sqrt(Vel.X ^ 2 + Vel.Y ^ 2 + Vel.Z ^ 2)
    local Dx, Dy, Dz = 0, 0, 0
    if Len > 1 then Dx, Dy, Dz = Vel.X / Len, Vel.Y / Len, Vel.Z / Len end
    local S2 = On(F.sweep2)
    local Ax, Ay, Fx, Fy = Pl.X, Pl.Y, Dx, Dy
    if S2 then
        local Pv = Cl.PrevPos
        Cl.PrevPos = { X = Pl.X, Y = Pl.Y, T = Now }
        if Pv and Now - Pv.T < 0.6 and (Pv.X - Pl.X) ^ 2 + (Pv.Y - Pl.Y) ^ 2 < 3000 ^ 2 then Ax, Ay = Pv.X, Pv.Y end
        local Fw = A.Safe(function() return V:GetActorForwardVector() end)
        if Fw and tonumber(Fw.X) and tonumber(Fw.Y) then Fx, Fy = Fw.X, Fw.Y end
    else
        local AI = A.Coop.Modules and A.Coop.Modules.ls_ai
        if AI and AI.OnCarSweep then
            AI.OnCarSweep({ X = Pl.X, Y = Pl.Y, Z = Pl.Z, Mph = Mph, Dx = Dx, Dy = Dy, Dz = Dz, Car = V:GetFName():ToString() })
            return
        end
    end
    if Now >= Cl.ClsAt then Cl.Cls, Cl.ClsAt = {}, Now + 30 end
    for _, Ch in ipairs(A.Characters() or {}) do
        if Alive(Ch) then
            local Addr = Ch:GetAddress()
            local Cls = Cl.Cls[Addr]
            if Cls == nil then Cls = Ch:GetClass():GetFName():ToString() Cl.Cls[Addr] = Cls end
            if Cls ~= "BP_PlayerCharacter_C" and (Cl.HitCd[Addr] or 0) <= Now then
                local Qp = Ch:K2_GetActorLocation()
                local Hit
                if S2 then
                    Hit = math.abs(Qp.Z - Pl.Z) < 250 and SegD2(Ax, Ay, Pl.X, Pl.Y, Qp.X, Qp.Y) < 250 ^ 2
                        and (Qp.X - Ax) * Fx + (Qp.Y - Ay) * Fy > -100
                else
                    Hit = (Qp.X - Pl.X) ^ 2 + (Qp.Y - Pl.Y) ^ 2 < 330 ^ 2 and math.abs(Qp.Z - Pl.Z) < 250
                end
                if Hit and not IsDead(Ch) then
                    Cl.HitCd[Addr] = Now + 1.5
                    -- immer car_hit (H.car_hit beim Host); "ahit" hatte keinen Empfaenger -> Roadkill ging verloren
                    Net.Send("car_hit", string.format("%.0f|%.0f|%.0f|%.1f|%s", Qp.X, Qp.Y, Qp.Z, Mph, Cls), nil, 1)
                end
            end
        end
    end
end

-- Tanken/Reparieren ohne Inventar-Hook: IsHeld faellt nach Duration (RetriggerableDelay -> UseGasCan / Repair)
local function SvcReply(Mode, X, Y, Z)
    return function(Data, _, Err)
        if not Data then
            Log("%s: keine Antwort (%s)", Mode, tostring(Err))
            local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
            if Inv and Inv.Resync then pcall(Inv.Resync, "car_svc timeout") end
            return
        end
        local Fd = {}
        for Part in (Data .. "|"):gmatch("([^|]*)|") do Fd[#Fd + 1] = Part end
        local C = A.Coop.Car
        local V = C and C.Nearest and C.Nearest({ X = X, Y = Y, Z = Z }, 600)
        local Ok = Fd[1] == "ok"
        local Base = Ok and 1 or 2
        if V and Alive(V) and C.ApplyState and tonumber(Fd[Base + 2]) then
            pcall(C.ApplyState, V, tonumber(Fd[Base + 1]) or 0, tonumber(Fd[Base + 2]) or 0,
                tonumber(Fd[Base + 3]) or 0, tonumber(Fd[Base + 4]) or 0, Ok and Mode == "repair")
            S.Cl.Prev = nil   -- neu einmessen (Host-Wert)
        end
        if not Ok then
            local Why = Fd[2]
            local Lk = Why == "locked" and V and M.LockOf and A.Safe(function() return M.LockOf(V) end) or nil
            local Text = Why == "full" and (Mode == "gas" and "Gas full" or "Vehicle repaired")
                or Why == "locked" and (Lk and string.format("Fahrzeug abgeschlossen (%s)", Lk) or "Fahrzeug abgeschlossen")   -- CAR-8
                or (Mode == "gas" and "No gas found" or "No repair kits found")
            -- Echter Host-Fehltext: nicht von OnNote (car_svcnote-Fenster) umschreiben lassen
            if C then C.PendingAt = nil end
            pcall(A.ShowNote, Text)
            -- Jede Ablehnung: das Spiel hat lokal schon verbraucht -> Server-Stand holen statt nachspielen (inv_use)
            local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
            if Inv and Inv.Resync then pcall(Inv.Resync, "car_svc " .. tostring(Why)) end
        end
    end
end

-- Gemeinsamer Versand car_svc (IsHeld-Flanke oder Wertsprung), je Auto hoechstens 1x in 1,5 s (Halten dauert
-- Duration). Zusatzfelder (car_svc_val): Host-Schluessel des Autos (Bindung aus car_s) und der lokale neue Wert -
-- nur zur Pruefung, der Host verbraucht und rechnet selbst wie SP (+Max/2). Ein alter Host liest nur Feld 1-4.
local function Recent(Name, Now)
    local Cl = S.Cl
    return Now - (Cl.SentAt[Name .. "|gas"] or -1e9) < 1.5 or Now - (Cl.SentAt[Name .. "|repair"] or -1e9) < 1.5
end

local function SendSvc(V, Name, Mode, Now, Val)
    local Cl = S.Cl
    if Recent(Name, Now) then return false end
    Cl.SentAt[Name .. "|" .. Mode] = Now
    local L = V:K2_GetActorLocation()
    local Txt = string.format("%s|%.0f|%.0f|%.0f", Mode, L.X, L.Y, L.Z)
    if On(F.svcval) then Txt = Txt .. string.format("|%s|%.1f", Cl.Rev[Name] or "", tonumber(Val) or -1) end
    Net.Request("car_svc", Txt, SvcReply(Mode, L.X, L.Y, L.Z), 8, nil, 0)
    Log("%s an %s: beim Host angefragt (%s)", Mode, V:GetFName():ToString(), Val and "Wertsprung" or "Flanke")
    return true
end

-- #13/#14 Wertsprung am naechsten Auto (zu Fuss): UseGasCan bzw. die Reparatur setzen CurrentFuel/CurrentHealth
-- lokal um Max/2 hoch; Svr_UpdateFuel/Svr_UpdateEngine sind nur HUD-Text und beim Gast ohne Besitz verworfen.
-- Nur mit Halten (IsHeld zuletzt <= 2 s her) und passender Zone/Art - sonst war es ein Host-Abgleich (main.lua).
local function ValPoll(Now)
    local Cl = S.Cl
    local Name = Cl.NearFull
    local V = Find(Name)
    if not V then Cl.Prev = nil return end
    local Fu, He = V.FuelComponent, V.VehicleHealthComponent
    if not (Alive(Fu) and Alive(He)) then Cl.Prev = nil return end
    local F1, MF = tonumber(Fu.CurrentFuel) or 0, tonumber(Fu.MaxFuel) or 0
    local H1, MH = tonumber(He.CurrentHealth) or 0, tonumber(He.MaxHealth) or 0
    local Pv = Cl.Prev
    Cl.Prev = { Name = Name, Fu = F1, Hp = H1 }
    if not Pv or Pv.Name ~= Name then return end
    local Mode, Val
    if F1 - Pv.Fu > math.max(0.2, MF * 0.005) then Mode, Val = "gas", F1
    elseif H1 - Pv.Hp > math.max(0.2, MH * 0.005) then Mode, Val = "repair", H1 end
    if not Mode then return end
    local LH = Cl.LastHeld
    local Area = V[Mode == "gas" and "InRefuellingArea?" or "InRepairingArea?"] == true
    if not (LH and LH.Name == Name and Now - LH.T <= 2 and (Area or LH.Mode == Mode)) then
        if not Cl.Odd[Name] then
            Cl.Odd[Name] = true
            Log("%s: Wertsprung (%s) ohne Halten - kein Tanken/Reparieren, ignoriert", V:GetFName():ToString(), Mode)
        end
        return
    end
    SendSvc(V, Name, Mode, Now, Val)
end

-- CAR-20 (car_polish): OnEndFuelInteract/OnEndRepairInteract (UB @3986-39c7/@36d6-3717) setzen IsHeld fuer JEDEN
-- Spieler-Overlap zurueck - geht ein Mitspieler am Auto vorbei, bricht das eigene Halten still ab (verbraucht wird
-- nichts). Steht man noch in der Zone und ist ein anderer Spieler nah: Hinweis statt stillem Abbruch.
function Late.SvcBroken(V, Mode)
    if not Alive(V) or V[Mode == "gas" and "InRefuellingArea?" or "InRepairingArea?"] ~= true then return end
    local Own, VL = A.OwnPawn(), V:K2_GetActorLocation()
    for _, Pw in ipairs(A.PlayerPawns() or {}) do
        if Alive(Pw) and not (Alive(Own) and Pw:GetAddress() == Own:GetAddress())
            and D2(Pw:K2_GetActorLocation(), VL.X, VL.Y, VL.Z) < 1000 ^ 2 then
            pcall(A.ShowNote, "Unterbrochen - erneut halten")
            return
        end
    end
end

local function SvcPoll(Now)
    local Cl = S.Cl
    local V = Find(Cl.NearFull)
    if not V then Cl.Held = nil return end
    local Name = Cl.NearFull
    local Held = V.IsHeld == true
    if Held and (not Cl.Held or Cl.Held.Name ~= Name) then
        -- UE 5.6: Art kommt aus der Interaktionsoption (OnExecuteInteract @47fb RefuelVehicle / @47ad RepairVehicle),
        -- nicht mehr aus den Zonen. Beide Zonen: die volle Seite kann es nicht sein (Spiel zeigt dort nur den Hinweis)
        local Fa, Ra = V["InRefuellingArea?"] == true, V["InRepairingArea?"] == true
        local Mode = (Fa and "gas") or (Ra and "repair") or nil
        if Fa and Ra then
            local okS, Fu, MaxFu = pcall(Stats, V)
            if okS and Fu >= MaxFu - 0.01 then Mode = "repair" end
        end
        Cl.Held = { Name = Name, T0 = Now, Mode = Mode, Dur = tonumber(V.Duration) or 0 }
    end
    if Held then
        -- car_svcnote: UseGasCan @0052 / Reparatur (Ubergraph 5.6 @07d0) suchen beim Gast in den leeren MainJigContainers
        -- und zeigen 'No gas found' @0249 / 'No repair kits found' (5.6 @0af5) (RetriggerableDelay-Callback @4b31/@4f0c,
        -- IsHeld=false davor @0754/@0778 - Flanke wie 5.3). main.lua Coop.Car.OnNote
        -- schreibt den Text um, solange PendingAt <= 2 s alt ist -> waehrend des Haltens alle 0,1 s auffrischen.
        local C = Cl.Held.Mode and Core.Flag("car_svcnote", true) and A.Coop and A.Coop.Car
        if C then
            C.PendingAt = Now
            if not S.SvcNoteLog then
                S.SvcNoteLog = true
                Log("Tank-/Reparatur-Fehltext beim Halten unterdrueckt")
            end
        end
        local LH = Cl.LastHeld
        if LH and LH.Name == Name then
            LH.T, LH.Mode = Now, Cl.Held.Mode or LH.Mode
        else
            Cl.LastHeld = { Name = Name, T = Now, Mode = Cl.Held.Mode }
        end
    elseif Cl.Held then
        local Hd = Cl.Held
        Cl.Held = nil
        local Dt = Now - Hd.T0
        if Hd.Mode and Hd.Name == Name and Dt >= Hd.Dur - 0.25 and Dt <= Hd.Dur + 0.45 then
            SendSvc(V, Name, Hd.Mode, Now, nil)   -- schon per Wertsprung gesendet: SendSvc verwirft
        elseif Hd.Mode and Dt > Hd.Dur + 0.45 and not Recent(Name, Now) then
            -- Flanke zu spaet (Hakler): evtl. lokal verbraucht ohne Anfrage -> Server-Stand holen
            local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
            if Inv and Inv.Resync then pcall(Inv.Resync, "car_svc ohne Anfrage") end
        elseif Hd.Mode and Dt < Hd.Dur - 0.25 then
            -- Decode: UseGasCan/Repair laufen nur im RetriggerableDelay-Callback und nur bei IsHeld -> nichts verbraucht
            Log("%s an %s: zu frueh losgelassen (%.1f/%.1f s) - nichts verbraucht, kein Neuabgleich", Hd.Mode, Name, Dt, Hd.Dur)
            if On(F.polish) then Try(F.polish, Late.SvcBroken, V, Hd.Mode) end   -- CAR-20
        end
    end
end

-- Kauf: Klick (Hook) -> lokales Geisterauto entfernen, Host kauft wirklich. Anfrage "Pfad|Preis|2" (2 = Gast
-- versteht die erweiterte Antwort "ok|uid:n;..|Auto|x|y|z"); die Antwort wird im Gast-Task verarbeitet (BuyResults).
local function BuyFlush()
    local E = table.remove(S.BuyQ, 1)
    if not E then return end
    local Btn = Find(E.Name)
    if not Btn then return end
    local Cls = Btn.Vehicle
    local CPath = Alive(Cls) and Full(Cls) or nil
    -- Gastpreis nur zum Vergleich beim Host (der Host nimmt DT_VehicleInfo); Ziffern ohne Tausendertrenner
    local PText = A.Safe(function() return Btn.Price:ToString() end, "") or ""
    local Price = tonumber((PText:gsub("[^%d]", "")), 10)
    if not CPath or not Price then Log("Kauf: Klasse/Preis unlesbar") return end
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if Alive(V) and A.Safe(function() return V:HasAuthority() end) == true and A.Safe(function() return Full(V:GetClass()) end) == CPath then
            pcall(function() V:K2_DestroyActor() end)
            Log("Kauf: lokales Geisterauto entfernt")
        end
    end
    local Patched = S.Patch.On   -- Stand beim Klick: lief die Spiel-Logik lokal (Hinweis "Not enough money")?
    local Rid = Net.Request("car_buy", Net.Enc(CPath) .. "|" .. Price .. "|2", function(Data, _, Err)
        if #S.BuyRes < 8 then S.BuyRes[#S.BuyRes + 1] = { Data = Data, Err = Err, Cls = CPath, Patched = Patched } end
    end, 10, nil, 0)
    -- nicht gesendet (Warteschlange/Verbindung): kein Rueckruf -> sonst bliebe der Klick mit Patch stumm
    if not Rid and #S.BuyRes < 8 then S.BuyRes[#S.BuyRes + 1] = { Err = "nosend", Cls = CPath, Patched = Patched } end
    Log("Kauf angefragt: %s fuer %d", CPath:match("[^%.]+$") or CPath, Price)
end

-- 32 Hex-Zeichen -> FGuid-Tabelle (wie ls_inv I.GuidT; nur fuer lokale BP-Funktionen, nie an RPCs)
local function GuidT(Hx)
    local T, Keys = {}, { "A", "B", "C", "D" }
    for N = 1, 4 do
        local V = tonumber(Hx:sub(N * 8 - 7, N * 8), 16) or 0
        if V >= 0x80000000 then V = V - 0x100000000 end
        T[Keys[N]] = V
    end
    return T
end

-- car_buyui (Gast): neue Stueckzahlen der Geldstapel ("uid:n;uid:n") in die eigene Anzeige. ClientUpdateCount ist
-- eine lokale BP-Funktion (kein RPC) und arbeitet auf LocalJSIContainers (die Gast-Anzeige; MainJigContainers ist
-- beim Gast leer). Rueckgabe: Anzahl angewendeter Eintraege.
local function ApplyMoney(List)
    local Pawn = A.OwnPawn()
    local Jig = Alive(Pawn) and A.Safe(function() return Pawn.BP_JigMultiplayer end) or nil
    if not Alive(Jig) then return 0 end
    local N = 0
    for Uid, Cnt in tostring(List or ""):gmatch("(%x+):(%d+)") do
        if #Uid == 32 and N < 16 then
            if pcall(function() Jig:ClientUpdateCount(GuidT(Uid), tonumber(Cnt), true) end) then N = N + 1 end
        end
    end
    return N
end

-- Antworten auf car_buy (Spiel-Thread). Mit Patch hat das Spiel lokal nichts gemacht: Hinweise wie SP selbst zeigen.
-- Ohne Patch zeigte das Spiel schon "Not enough money" (lokale Pruefung auf leerem MainJigContainers).
local NOTES = { busy = "Bitte kurz warten", rate = "Bitte kurz warten", blocked = "Abholplatz belegt", spawn = "Kauf fehlgeschlagen",
                far = "Zu weit vom Abholplatz", price = "Kauf fehlgeschlagen", class = "Kauf fehlgeschlagen" }
local function BuyResults()
    local R = table.remove(S.BuyRes, 1)
    if not R then return end
    local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
    local Short2 = R.Cls:match("[^%.]+$") or R.Cls
    local Fd = R.Data and Fields(R.Data) or {}
    if Fd[1] == "ok" then
        local N = 0
        if BuyOn("car_buyui") and Fd[2] and Fd[2] ~= "" then N = ApplyMoney(Fd[2]) end
        if N == 0 and Inv and Inv.Resync then pcall(Inv.Resync, "car_buy ok") end   -- alter Host / UID unbekannt
        if not R.Patched then pcall(A.ShowNote, "Fahrzeug gekauft") end
        Log("Kauf bestaetigt: %s (Geldstapel %d, Auto %s)", Short2, N, tostring(Fd[3] or "?"))
        return
    end
    local Why = Fd[2] or tostring(R.Err)
    Log("Kauf abgelehnt: %s (%s)", Short2, tostring(R.Data or R.Err))
    if Why == "money" then
        if R.Patched then pcall(A.ShowNote, "Not enough money") end
    elseif NOTES[Why] then
        pcall(A.ShowNote, NOTES[Why])
    elseif R.Patched and not R.Data then
        pcall(A.ShowNote, "Kauf fehlgeschlagen")   -- keine Antwort vom Host
    end
    -- Ohne Antwort (Zeitueberschreitung/Trennung) kann der Host trotzdem gekauft haben -> Geldanzeige immer neu holen
    if (not R.Patched or not R.Data) and Inv and Inv.Resync then pcall(Inv.Resync, "car_buy") end
end

-- Gast: Schieben/Abschleppen aus den Hooks an den Host (Host-Schluessel aus der car_s-Bindung, sonst Lage).
-- Der Hook laeuft erst nach dem BP-Rumpf (UE4SS 3.0.1). car_hook_post: Schieben nur, wenn die eigene 2-s-Abklingzeit
-- je Auto frei war (CanPush? ist danach immer false, @3203; sonst "Push on cooldown" lokal); Richtung = eigene Kamera
-- (wie Interact_PushVehicle, GetPlayerCameraManager(0) ist beim Gast der eigene). Abschleppen: TowingVehicle? nach
-- dem Rumpf = neuer lokaler Stand (@00c5 an / @6f71 aus), Host gleicht ab. car_hook_post=0: alte Vor-Hook-Formel.
local function PushFlush()
    local Q = S.PushQ
    if #Q == 0 then return end
    S.PushQ = {}
    local Cl = S.Cl
    for _, E in ipairs(Q) do
        local V = Find(E.Name)
        if V and A.Safe(function() return V:HasAuthority() end) ~= true then
            local L = V:K2_GetActorLocation()
            local Key = Cl.Rev[E.Name] or ""
            if E.Kind == "push" and E.Ok and On(F.push) then
                local PC = A.LocalPC()
                local Cam = Alive(PC) and A.Safe(function() return PC.PlayerCameraManager end)
                local Fw = Alive(Cam) and A.Safe(function() return Cam:GetActorForwardVector() end)
                if Fw then
                    Net.Send("car_push", string.format("push|%s|%.0f|%.0f|%.0f|%.3f|%.3f|%.3f", Key, L.X, L.Y, L.Z,
                        Fw.X, Fw.Y, Fw.Z), nil, 1)
                    Log("Schieben an %s: beim Host angefragt", V:GetFName():ToString())
                end
            elseif E.Kind == "tow" and On(F.tow) then
                Net.Send("car_push", string.format("tow|%s|%.0f|%.0f|%.0f|%s", Key, L.X, L.Y, L.Z, B(E.Ok)), nil, 1)
                -- car_towsync: der 1-s-Angleich (Late.TowSync) wartet 3 s auf den neuen car_tw des Hosts, statt den
                -- eigenen Druck zurueckzudrehen; frischer Druck = neuer Angleich-Versuch erlaubt
                Cl.TowHold[E.Name] = os.clock() + 3
                if Key ~= "" then Cl.TowTry[Key] = nil end
                Log("Abschleppen %s an %s: beim Host angefragt", E.Ok and "an" or "aus", V:GetFName():ToString())
            end
        end
    end
end

local function ClientFast(Now)
    if Net.Side ~= "client" or not Core.Flag(FLAG, true) then return end
    if not CheckGen() or not Net.Has("car2") then return end
    local C, V, Driver = OwnState()
    if not C then return end
    if #S.NoneQ > 0 then Try(F.strict, Late.NoneFlush) end   -- K28 carnone (CAR-7)
    if S.Cl.LockAsk then Try(F.lock, Late.LockAsk) end         -- E20 /carlock (CAR-8)
    Try(F.fx, OwnCar, V, Driver)
    if V then
        if Driver and On(F.hit) and Now >= S.Cl.SweepAt then S.Cl.SweepAt = Now + 0.2 Try(F.hit, Sweep, V, Now) end
        if not Driver and C.PassengerOf == V and On(F.pass) then Try(F.pass, Passenger, V) end
    else
        S.Cl.PassFor = nil
    end
    if #S.HornQ > 0 then
        S.HornQ = {}
        if V and On(F.horn) then Net.Send("car_horn", "", nil, 1) end
    end
    if #S.PushQ > 0 then Try(F.push, PushFlush) end
    if On(F.svc) and not V then
        if On(F.svcval) then Try(F.svcval, ValPoll, Now) end   -- vor SvcPoll: Sprung und Flanke im selben Bild
        Try(F.svc, SvcPoll, Now)
    else
        S.Cl.Prev = nil
    end
    if On(F.buy) then
        Try(F.buy, BuyFlush)
        Try(F.buy, BuyResults)
    end
end

-- 1 s: Autoindex (FindAllOf), Zuschauer-Flags, naechstes Auto (Tanken), offene car_s, InVehicle?-Abgleich
local function ClientSlow(Now)
    if Net.Side ~= "client" or not Core.Flag(FLAG, true) then return end
    if not CheckGen() or not Net.Has("car2") then return end
    local Cl = S.Cl
    BuildIndex(Now)
    local Own = A.OwnPawn()
    local OP = Alive(Own) and Own:K2_GetActorLocation() or nil
    local Near, NearD = nil, 900 ^ 2
    for _, E in ipairs(Cl.Index) do
        local V = not E.Ghost and E.Full ~= Cl.OwnFull and Find(E.Full)
        if V then
            if On(F.input) then pcall(SetReq, V, true) end
            if OP then
                local Dd = D2(V:K2_GetActorLocation(), OP.X, OP.Y, OP.Z)
                if Dd < NearD then Near, NearD = E.Full, Dd end
            end
        end
    end
    Cl.NearFull = Near
    -- car_towsync: lokale Abschlepp-Kopie an den Host-Stand angleichen (Late.TowSync)
    if OP and next(Cl.Tow) ~= nil and On(F.tow) and On(F.towsync) then Try(F.towsync, Late.TowSync, OP) end
    -- CAR-14 (5, car_perf): offene car_s nach Abstand (x|y|z vorn im Wert), > 25000 uu warten (Auto beim Gast noch
    -- nicht repliziert), naechste zuerst - vorher die ersten 20 in pairs-Reihenfolge (fernere verhungerten)
    local Todo = {}
    if On(F.perf) and OP then
        for Key, Val in pairs(Cl.Pend) do
            local X, Y, Z = tostring(Val):match("^(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|")
            local Dd = X and D2(OP, tonumber(X) or 0, tonumber(Y) or 0, tonumber(Z) or 0) or 0
            if Dd <= 25000 ^ 2 then Todo[#Todo + 1] = { Key, Val, Dd } end
        end
        table.sort(Todo, function(T1, T2) return T1[3] < T2[3] end)
    else
        for Key, Val in pairs(Cl.Pend) do
            Todo[#Todo + 1] = { Key, Val }
            if #Todo >= 20 then break end
        end
    end
    for I = 1, math.min(#Todo, 20) do
        local Key, Val = Todo[I][1], Todo[I][2]
        local ok, err = pcall(ApplyCar, Key, Val)
        if not ok then Cl.Pend[Key] = nil Core.Fail(F.fx, err) end
    end
    if On(F.seat) then
        for Id, Val in pairs(Cl.Seat) do pcall(ApplySeat, Id, Val) end
    end
end

-- Hooks (selten, nur Lua-Tabellen): Hupe, Schieben/Abschleppen und Kauf-Klick. Bei BP-Funktionen ruft UE4SS 3.0.1
-- den Hook erst nach dem BP-Rumpf (main.lua 7851)
local function TryHooks(Now)
    if Now < S.HookTry or not A.MultiplayerActive() then return end
    S.HookTry = Now + 2
    if A.Settings.server then return end   -- dedizierter Host: kein lokaler Spieler
    if not S.Hooked.Horn and On(F.horn) and Find(P.MASTER) then
        S.Hooked.Horn = true
        A.TryHook(P.MASTER .. ":Horn", function()
            if not S.InHorn and #S.HornQ < 8 then S.HornQ[#S.HornQ + 1] = os.clock() end
        end)
    end
    -- Schieben/Abschleppen (nur Gast, Spieleraktion am Auto): Name + Bool in die Warteschlange, Senden in ClientFast
    if Net.Side == "client" and Find(P.MASTER) then
        local function Queue(Kind, Prop, Want)
            return function(Self, Skip)
                if Net.Side ~= "client" or #S.PushQ >= 4 then return end
                -- UE 5.6 AddTowingComp(SkipTowingCheck?, SkipNotification?): (true, true) = Wiederankuppeln nach dem
                -- Laden (Ubergraph @0621), keine Spieleraktion; Spieler-Option ruft (false, false) @30fb
                if Skip ~= nil and A.Safe(function() return Skip:get() end) == true then return end
                local ok, Name, Val = pcall(function()
                    local V = Self:get()
                    if not Alive(V) then return nil end   -- CORE-20: Hook-Kontext vor jedem Zugriff pruefen
                    return V:GetFullName(), V[Prop]
                end)
                if ok and Name then
                    local Nm = Name:match("^%S+%s+(%S+)$") or Name
                    local Okv
                    if Core.Flag("car_hook_post", true) then
                        -- UE4SS 3.0.1: Hook laeuft NACH dem BP-Rumpf (main.lua 7851)
                        if Kind == "push" then
                            -- CanPush? ist danach immer false (@3203) -> eigene 2-s-Abklingzeit je Auto wie Delay @320e
                            local Now = os.clock()
                            Okv = Now >= (S.PushAt[Nm] or 0)
                            if Okv then S.PushAt[Nm] = Now + 2 end
                        else
                            -- TowingVehicle? = neuer lokaler Stand (@00c5 an / @6f71 aus)
                            Okv = Val == true
                        end
                    else
                        Okv = (Val == true) == Want
                    end
                    -- car_towsync: Sperrfrist schon beim Druck (car_slow kann vor car_cli/PushFlush laufen und den
                    -- frischen Druck sonst mit RemoveTowingComp zurueckdrehen); PushFlush frischt sie beim Senden auf
                    if Kind == "tow" and On(F.towsync) then S.Cl.TowHold[Nm] = os.clock() + 3 end
                    S.PushQ[#S.PushQ + 1] = { Kind = Kind, Name = Nm, Ok = Okv }
                end
            end
        end
        if not S.Hooked.Push and On(F.push) then
            S.Hooked.Push = true
            A.TryHook(P.MASTER .. ":Interact_PushVehicle", Queue("push", "CanPush?", true))
        end
        if not S.Hooked.Tow and On(F.tow) then
            S.Hooked.Tow = true
            A.TryHook(P.MASTER .. ":AddTowingComp", Queue("tow", "TowingVehicle?", false))
        end
    end
    if not S.Hooked.Buy and Net.Side == "client" and On(F.buy) and Find(P.VENDOR) then
        S.Hooked.Buy = true
        S.Hooked.BuyOk = A.TryHook(P.VENDOR .. ":" .. P.CLICK, function(Self)
            if #S.BuyQ < 4 then
                local ok, Name = pcall(function()
                    local Btn = Self:get()
                    return Alive(Btn) and Btn:GetFullName() or nil   -- CORE-20
                end)
                if ok and Name then S.BuyQ[#S.BuyQ + 1] = { Name = Name:match("^%S+%s+(%S+)$") or Name } end
            end
        end) ~= nil
    end
end

-- UE 5.6 geprueft (bp\VehicleVendorButton_C.kdis): Stub unveraendert 18 Byte, 0000 LocalFinalFunction Ubergraph,
-- 0009 IntConst 230, 000f Return/Nothing, RET 65535 -> Erwartung "46 <Ubergraph-Lowbyte>" und neu 040B bleiben gueltig.
-- car_buyclk (Gast): Klick-Stub BndEvt_..._1_OnButtonClicked (parms=0, Script "46 <Ubergraph> 04 0B 53") per
-- ret_early stumm -> keine lokale CheckIfHasEnoughMoney/"Not enough money"/TakeMoney/SpawnVehicle. Die DLL nullt dabei
-- EventGraphFunction, ProcessEvent (Delegate) laeuft durch den Stub -> der Lua-Pre-Hook oben meldet den Klick weiter.
-- Nur mit registriertem Hook, als Gast im Mehrspieler mit car2-Host; sonst 0-Zeile (Einzelspieler kauft wie SP).
local function BuyPatch()
    if not Core.HasPatchRegistry() then return end
    local Want = (Net.Side == "client" and A.MultiplayerActive() and Net.Has("car2") and BuyOn("car_buyclk")
        and S.Hooked.BuyOk == true) and true or false
    if not Want and not S.Patch.On then return end
    local Fn = Find(P.VENDOR .. ":" .. P.CLICK)
    local Ub = Find(P.VENDOR .. ":" .. P.UBER)
    if not (Fn and Ub) then
        if not Want then S.Patch.On = false end   -- Klasse entladen: Script-Zeiger weg, die DLL hat den Patch verworfen
        return
    end
    local Line = string.format("car_buyclk ret_early %x 0 46%02X 040B %d", Fn:GetAddress(), Ub:GetAddress() % 256,
        Want and 1 or 0)
    if Line == S.Patch.Line and Want == S.Patch.On then return end
    if Core.SetPatch("car_buyclk", Line) then
        S.Patch.Line, S.Patch.On = Line, Want
        Log("Kauf-Klick-Patch %s angefordert", Want and "an" or "aus")
    end
end

-- ===================================================================================== Handler

local H = {}

-- s2c Keyed-State
function H.car_s(Value, _, Msg)
    if Net.Side ~= "client" or not On(F.fx) then return end
    if Value == nil then
        local Bound = S.Cl.Bind[Msg.Key]
        if Bound then S.Cl.Rev[Bound] = nil end
        S.Cl.Bind[Msg.Key], S.Cl.Eng[Msg.Key], S.Cl.Pend[Msg.Key] = nil, nil, nil
        S.Cl.RadioFrom[Msg.Key] = nil
        return
    end
    local ok, err = pcall(ApplyCar, Msg.Key, Value)
    if not ok then Core.Fail(F.fx, err) end
end

-- s2c Keyed-State car_tw (car_towsync): Host-Stand TowingVehicle? je Host-FName ("1"/"0", nil = weg). Nur merken,
-- angeglichen wird in Late.TowSync (ClientSlow); neuer Host-Wert = neuer Angleich-Versuch
function H.car_tw(Value, _, Msg)
    if Net.Side ~= "client" or not Msg or not Msg.Key then return end
    if Value ~= nil and Value ~= "1" and Value ~= "0" then return end
    local Cl = S.Cl
    if Cl.Tow[Msg.Key] ~= Value then Cl.TowTry[Msg.Key] = nil end
    Cl.Tow[Msg.Key] = Value
end

-- car_towquiet: stille Vorab-Spur wie H.car_push (Ausgabeparameter HitActor); true = Ziel getroffen
function Late.TowTgt(V)
    local T, Tgt = {}, nil
    if pcall(function() V:TraceForVehicleToTow(T) end) then
        Tgt = T.HitActor
        if Tgt == nil then for _, X in pairs(T) do Tgt = X break end end
    end
    return Alive(Tgt)
end

-- car_towquiet: lokale Kopie still abkuppeln wie @6f71-@6fbd/@7045, ohne @71c8/@712a-Hinweis und @6ed0-HUD. Die
-- Kupplung haengt am gezogenen Auto (AddComponent @01d7 auf HitActor) -> Besitzer = Ziel (K2_DestroyComponent(self)
-- des BPs lehnt UE ab). Entscheidend ist PhysicsConstraintComp = null (@6fbd), sonst bricht @0057 jedes spaetere
-- Ankuppeln dieser Kopie ab. Handbremse/Gas (@70a0/@70e4) nicht noetig: Gast-Kopien nehmen die replizierten Eingaben.
function Late.TowOff(V)
    local Pc = A.Safe(function() return V.PhysicsConstraintComp end)
    if Alive(Pc) then
        local Ow = A.Safe(function() return Pc:GetOwner() end)
        local Ms = Alive(Ow) and A.Safe(function() return Ow.Mesh end)
        if Alive(Ms) then pcall(function() Ms:SetCollisionResponseToChannel(6, 2) end) end   -- wie @7045
        pcall(function() Pc:BreakConstraint() end)   -- @6f7c
        if Alive(Ow) then pcall(function() Pc:K2_DestroyComponent(Ow) end) end   -- Pc danach nicht mehr anfassen
    end
    if Alive(V) then
        pcall(function() V.PhysicsConstraintComp = nil end)   -- @6fbd
        V["TowingVehicle?"] = false   -- @6f71
    end
end

-- Gast (car_towsync, 1 s aus ClientSlow): TowingVehicle? ist nicht repliziert, beim Host nach dem Laden wieder
-- angekuppelt (@0617/@0621) oder von einem anderen Spieler umgeschaltet -> die eigene Kopie (Beschriftung SelectText
-- @271f, lokale Kupplung) an den Host-Stand angleichen, damit der 0/1-Abgleich in H.car_push mit einem Druck greift.
-- Nur Autos <= 3000 uu, je Host-Wert ein Versuch (TowTry; begrenzt Hinweise nur je Gast, nicht fuer Unbeteiligte),
-- hoechstens 4 je Lauf. An: AddTowingComp(true, true) wie das Wiederankuppeln nach dem Laden (ohne Umschalten und
-- ohne "Vehicle hitched" @0509; der Queue-Hook ignoriert Skip=true). Aus (alt): RemoveTowingComp (@7265 -> @71c8
-- "Towed vehicle detached" -> @6ed0 HUD); ohne Kupplung meldet es nur "Unable to detach" (@712a) und laesst den
-- Merker an -> dann nur den Merker zuruecksetzen.
-- car_towquiet: der Angleich trifft jeden Gast im Umkreis, nicht nur den Handelnden -> Aus still (Late.TowOff, keine
-- Hinweise, keine HUD-Beschriftung), An nur <= 900 uu (Gast kann gleich interagieren; zu weit = kein Versuch, TowTry
-- bleibt frei) und nur mit stillem Vorab-Treffer (sonst zeigte @033f "No vehicle to tow found").
function Late.TowSync(OP)
    local Cl, Now, N = S.Cl, os.clock(), 0
    local Quiet = On(F.towquiet)
    for Key, Val in pairs(Cl.Tow) do
        local Path = Cl.Bind[Key]
        local V = Path and Now >= (Cl.TowHold[Path] or 0) and Find(Path) or nil
        local Dd = V and A.Safe(function() return V:HasAuthority() end) ~= true
            and D2(V:K2_GetActorLocation(), OP.X, OP.Y, OP.Z) or nil
        if Dd and Dd <= 3000 ^ 2 then
            local Want, Loc = Val == "1", V["TowingVehicle?"] == true
            if Want == Loc then
                Cl.TowTry[Key] = nil
            elseif Cl.TowTry[Key] ~= Val and N < 4 and (not Want or not Quiet or Dd <= 900 ^ 2) then
                Cl.TowTry[Key], N = Val, N + 1
                if Want then
                    if not Quiet or Late.TowTgt(V) then pcall(function() V:AddTowingComp(true, true) end) end
                elseif Quiet then
                    Try(F.towquiet, Late.TowOff, V)   -- Fehler -> Core.Fail(car_towquiet) -> alter Weg
                else
                    local Pc = A.Safe(function() return V.PhysicsConstraintComp end)
                    if Alive(Pc) then pcall(function() V:RemoveTowingComp() end) end
                    local Pc2 = Alive(V) and A.Safe(function() return V.PhysicsConstraintComp end)
                    if Alive(V) and V["TowingVehicle?"] == true and not Alive(Pc2) then V["TowingVehicle?"] = false end
                end
                Log("Abschleppen %s: lokale Kopie an Host-Stand %s angeglichen (lokal jetzt %s)", Short(Key),
                    Want and "an" or "aus", tostring(Alive(V) and V["TowingVehicle?"] == true))
            end
        end
    end
end

function H.car_seat(Value, _, Msg)
    if Net.Side ~= "client" or not On(F.seat) then return end
    S.Cl.Seat[Msg.Key] = Value
    ApplySeat(Msg.Key, Value)
end

-- beide Richtungen: c2s (Insasse hupt) / s2c (andere hupen)
function H.car_horn(Data, G)
    if not On(F.horn) then return end
    local V
    if Net.Side == "host" then
        if not RateOk(G, "car_horn", 2) then return end
        local D = GuestSeat(G)
        if not D then return end
        V = D.V
        local L = V:K2_GetActorLocation()
        local Text = string.format("%s|%.0f|%.0f|%.0f", V:GetFName():ToString(), L.X, L.Y, L.Z)
        Net.ForEachGuest(function(O)
            if O ~= G and O.Epoch and Net.Has("car2", O) then Net.Send("car_horn", Text, O, 1) end
        end)
    else
        local Fd = Fields(Data)
        V = Resolve(Fd[1], tonumber(Fd[2]), tonumber(Fd[3]), tonumber(Fd[4]))
    end
    if not V then return end
    S.InHorn = true
    pcall(function() V:Horn() end)   -- Ton und (beim Host) ReportNoiseEvent 8500 fuer die KI
    S.InHorn = false
end

-- c2s: Licht (Fahrer) / Radio (Insasse) "L|R|Song" (L/R "-" = unveraendert)
function H.car_in(Data, G)
    if Net.Side ~= "host" or not RateOk(G, "car_in", 10) then return end
    local D = GuestSeat(G)
    if not D then return end
    local Fd, V = Fields(Data), D.V
    if Fd[1] ~= "-" and not D.Passenger and On(F.fx) then
        local Want = Fd[1] == "1"
        if V["LightsOn?"] ~= Want then V:TurnOnOffLights() end
    end
    if Fd[2] ~= "-" and On(F.radio) then ApplyRadio(V, Fd[2] == "1", table.concat(Fd, "|", 3)) end
end

-- car_svc_val (Host): Auto ueber den Host-Schluessel aus der Anfrage (exakt statt naechstes), nur <= R (600) zur Lage
local function HostByKey(Key, X, Y, Z, R)
    if type(Key) ~= "string" or Key == "" or not (X and Y and Z) then return nil end
    R = tonumber(R) or 600
    for _, V in ipairs(Cars()) do
        if Alive(V) and V:GetFName():ToString() == Key then
            return D2(V:K2_GetActorLocation(), X, Y, Z) <= R * R and V or nil
        end
    end
    return nil
end

-- car_svc_val (Host): gemeldeter Gastwert darf hoechstens alt + Max/2 sein (SP-Menge); sonst einmal je Auto/Gast
-- loggen. Es gilt immer der Host-Wert (Gastwert kann wegen alter Anzeige abweichen -> kein SecWarn).
local function CheckClaim(G, V, What, Claim, Old, Max)
    if not Claim or Claim < 0 then return end
    local Allowed = math.min(Old + Max / 2, Max)
    if Claim <= Allowed + 1 then return end
    local LK = "svc|" .. G.Key .. "|" .. Full(V)
    if S.H.Logged[LK] then return end
    S.H.Logged[LK] = true
    Log("%s: %s-Wert vom Gast %s = %.1f, erlaubt %.1f - Host-Wert gilt", V:GetFName():ToString(), What, Short(G.Key), Claim, Allowed)
end

-- c2s Anfrage: Tanken/Reparieren am Auto "gas|x|y|z[|hostKey|neuerWert]" (Host verbraucht aus dem Server-Inventar,
-- Werte wie SP). #13/#14: Owner-Relay waere wirkungslos (Svr_UpdateFuel/Engine schreiben beim Server nur HUD-Text,
-- der Verbrauch ist lokal) - daher dieser Weg; der Host ruft die beiden RPCs nicht (kein HUD auf dem Host).
function H.car_svc(Data, G, Msg)
    if Net.Side ~= "host" then return end
    local function No(Why, V)
        local St = V and A.Safe(function() return string.format("%.1f|%.1f|%.1f|%.1f", Stats(V)) end) or ""
        Net.Reply(Msg, "no|" .. Why .. (St ~= "" and ("|" .. St) or ""))
    end
    if not On(F.svc) or not RateOk(G, "car_svc", 2) then return No("off") end
    local Fd = Fields(Data)
    local What, X, Y, Z = Fd[1], tonumber(Fd[2]), tonumber(Fd[3]), tonumber(Fd[4])
    local C = A.Coop.Car
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not (P.ITEMS[What] and X and C and Alive(Pawn)) then return No("bad") end
    local V = On(F.svcval) and Fd[5] and Fd[5] ~= "" and A.Safe(function() return HostByKey(Fd[5], X, Y, Z) end) or nil
    if not Alive(V) then V = C.Nearest({ X = X, Y = Y, Z = Z }, 600) end
    if not Alive(V) or D2(Pawn:K2_GetActorLocation(), X, Y, Z) > 1500 ^ 2 then return No("far") end
    if M.CanUse(G, V) ~= true then return No("locked", V) end   -- CAR-8: abgeschlossenes fremdes Auto
    local Fu, MaxFu, Hp, MaxHp = Stats(V)
    if On(F.svcval) then
        local Claim = tonumber(Fd[6])
        if What == "gas" then CheckClaim(G, V, What, Claim, Fu, MaxFu) else CheckClaim(G, V, What, Claim, Hp, MaxHp) end
    end
    if (What == "gas" and Fu >= MaxFu - 0.01) or (What == "repair" and Hp > MaxHp - 1) then return No("full", V) end
    local Item = Find(P.ITEMS[What]) or A.Safe(function() return LoadAsset(P.ITEMS[What]) end)
    local Out = {}
    local Jig = A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not (Alive(Item) and Alive(Jig)) then return No("item", V) end
    local R = A.Safe(function() return Jig:ServerFindThenConsumeByItemID(Item, 1, Out) end)
    if not (R == true or Out.Result == true) then return No("item", V) end
    if What == "gas" then Fu = math.min(Fu + MaxFu / 2, MaxFu) else Hp = math.min(Hp + MaxHp / 2, MaxHp) end
    C.ApplyState(V, Fu, MaxFu, Hp, MaxHp, What == "repair")
    if What == "repair" then
        pcall(function() V:VehicleSmoke(false) end)
        pcall(function() V:VehicleFire(false) end)
    end
    local Name = Full(V)
    S.H.LastHp[Name], S.H.HoldHp[Name] = Hp, os.clock() + 2
    if What == "gas" and On(F.fuelhold) then S.H.HoldFu[Name] = { Until = os.clock() + 3, Fuel = Fu } end   -- CAR-6
    for K, D in pairs(C.Drivers) do   -- ein anderer Fahrer: dessen Stand ersetzen (sonst ueberschreibt sein Piggyback)
        if D.V == V and K ~= G.Key then S.H.PushHp[K] = true end
    end
    Net.Reply(Msg, string.format("ok|%.1f|%.1f|%.1f|%.1f", Fu, MaxFu, Hp, MaxHp))
    Log("%s: %s fuer %s (Tank %.0f/%.0f, Zustand %.0f/%.0f)", V:GetFName():ToString(), What, Short(G.Key), Fu, MaxFu, Hp, MaxHp)
end

-- c2s: Schieben "push|hostKey|x|y|z|fx|fy|fz" / Abschleppen "tow|hostKey|x|y|z|1/0" (Decode Interact_PushVehicle
-- 5.6 Einsprung @311b: CanPush?, Mesh.AddForce(KameraVorwaerts * 4e7), 2 s Abklingzeit - unveraendert;
-- AddTowingComp @000f: schaltet um, ausser SkipTowingCheck?).
-- Host fuehrt es auf seiner Kopie aus (Interact_PushVehicle selbst nicht: GetPlayerCameraManager(0) = Host-Kamera).
function H.car_push(Data, G)
    if Net.Side ~= "host" or not RateOk(G, "car_push", 2) then return end
    local Fd = Fields(Data)
    local Kind, Key, X, Y, Z = Fd[1], Fd[2] or "", tonumber(Fd[3]), tonumber(Fd[4]), tonumber(Fd[5])
    if not Z or not ((Kind == "push" and On(F.push)) or (Kind == "tow" and On(F.tow))) then return end
    local C = A.Coop.Car
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not (C and Alive(Pawn)) then return end
    local V = Key ~= "" and A.Safe(function() return HostByKey(Key, X, Y, Z) end) or nil
    if not Alive(V) and C.Nearest then V = C.Nearest({ X = X, Y = Y, Z = Z }, 600) end
    if not Alive(V) then return end
    local VName = V:GetFName():ToString()
    local PL = Pawn:K2_GetActorLocation()
    if D2(V:K2_GetActorLocation(), PL.X, PL.Y, PL.Z) > 1000 ^ 2 then
        Log("%s: %s von %s abgelehnt (zu weit weg)", VName, Kind, Short(G.Key))
        return
    end
    if M.CanUse(G, V) ~= true then   -- CAR-8: abgeschlossenes fremdes Auto (Gast sieht den Hinweis, Auto bleibt)
        NoteTo(PC, "Fahrzeug abgeschlossen")
        return
    end
    if Kind == "tow" then
        local Want = Fd[6] == "1"
        if (V["TowingVehicle?"] == true) == Want then return end
        -- CAR-16 (car_guard): nur Autos mit Abschleppvorrichtung (SP OnBeginTowingInteract @2643 prueft CanThisTowVehicles?)
        if Want and On(F.guard) and V["CanThisTowVehicles?"] ~= true then
            Log("Auto %s: Abschleppen von %s abgelehnt (kann nicht abschleppen)", VName, Short(G.Key))
            return
        end
        -- CAR-8: ein abgeschlossenes fremdes Auto auch nicht an den Haken nehmen (Ziel wie AddTowingComp ueber
        -- TraceForVehicleToTow, Ausgabeparameter HitActor; sonst liesse es sich wegschleppen)
        if Want and On(F.lock) then
            local T, Tgt = {}, nil
            if pcall(function() V:TraceForVehicleToTow(T) end) then
                Tgt = T.HitActor
                if Tgt == nil then for _, X2 in pairs(T) do Tgt = X2 break end end
            end
            if Alive(Tgt) and M.CanUse(G, Tgt) ~= true then
                NoteTo(PC, "Fahrzeug abgeschlossen")
                Log("Auto %s: Abschleppen von %s abgelehnt (Ziel abgeschlossen)", VName, Short(G.Key))
                return
            end
        end
        -- Trace/Constraint auf der Host-Kopie, schaltet wie im SP um (5.6: AddTowingComp(false, false) wie die
        -- Spieler-Option @30fb; 5.3 ohne Parameter ignoriert die Zusatzargumente)
        pcall(function() V:AddTowingComp(false, false) end)
        Log("Auto %s: Abschleppen %s von %s (Host-Stand %s)", VName, Want and "an" or "aus", Short(G.Key),
            tostring(V["TowingVehicle?"] == true))
        return
    end
    for _, D in pairs(C.Drivers) do
        if D.V == V then return end   -- ein Gast faehrt: dessen Lage gilt
    end
    local Own = A.OwnPawn()
    local VDC = Alive(Own) and Own["InVehicle?"] and A.Safe(function() return Own.VehicleDrivingComponent end)
    local OwnV = Alive(VDC) and A.Safe(function() return VDC.Vehicle end)
    if Alive(OwnV) and OwnV:GetAddress() == V:GetAddress() then return end   -- Host-Spieler faehrt es
    local Fx, Fy, Fz = tonumber(Fd[6]), tonumber(Fd[7]), tonumber(Fd[8])
    local Len = Fx and Fy and Fz and math.sqrt(Fx * Fx + Fy * Fy + Fz * Fz) or 0
    if Len < 0.5 or Len > 1.5 then return end
    local Name, Now = Full(V), os.clock()
    if (S.H.PushCd[Name] or 0) > Now then return end
    local Mesh = C.Mesh and C.Mesh(V) or A.Safe(function() return V.Mesh end)
    if not Alive(Mesh) then return end
    if A.Safe(function() return Mesh:IsSimulatingPhysics(FName("None")) end) == false then
        Log("Auto %s: Schieben von %s ohne Wirkung (Host simuliert keine Physik)", VName, Short(G.Key))
        return
    end
    S.H.PushCd[Name] = Now + 2
    local K = 40000000 / Len
    pcall(function() Mesh:WakeAllRigidBodies() end)
    Mesh:AddForce({ X = Fx * K, Y = Fy * K, Z = Fz * K }, FName("None"), false)
    Log("Auto %s von %s geschoben", VName, Short(G.Key))
end

-- c2s: Roadkill "x|y|z|mph|Klasse" (nur Fahrer). Host fuehrt ApplyDamage wie ApplyDamageToAIBasedOnSpeed aus,
-- Verursacher = Gastfigur, plus Eigenschaden des Autos (DmgOnVehicleCollision)
function H.car_hit(Data, G)
    if Net.Side ~= "host" or not On(F.hit) or not RateOk(G, "car_hit", 8) then return end
    local C = A.Coop.Car
    local D = C and C.Drivers[G.Key]
    if not (D and Alive(D.V)) then return end
    local Fd = Fields(Data)
    local X, Y, Z, Mph, Cls = tonumber(Fd[1]), tonumber(Fd[2]), tonumber(Fd[3]), tonumber(Fd[4]), Fd[5]
    if not (X and Mph and Cls) or Mph < 4 then return end
    if Cls == "BP_PlayerCharacter_C" then return Net.SecWarn(G, G.Key, "car_hit_player") end
    local V = D.V
    if D2(V:K2_GetActorLocation(), X, Y, Z) > 1500 ^ 2 then return Net.SecWarn(G, G.Key, "car_hit_far") end
    local Best, BestD = nil, 450 ^ 2
    for _, Ch in ipairs(A.Characters() or {}) do
        if Alive(Ch) and Ch:GetClass():GetFName():ToString() == Cls then
            local Dd = D2(Ch:K2_GetActorLocation(), X, Y, Z)
            if Dd < BestD then Best, BestD = Ch, Dd end
        end
    end
    if Best then M.HostCarHit(G, Best) end
end

-- Host: Treffer wie ApplyDamageToAIBasedOnSpeed (300-350 an das Ziel, Verursacher Gastfigur; Eigenschaden
-- DmgOnVehicleCollision.X..Y am Auto -> ReceiveAnyDamage beim Host -> PoseHp gibt ihn an den Fahrer).
-- Auch fuer ls_ai (ahit kind "car"): M.HostCarHit(Gast, Ziel). Rueckgabe true = angewendet.
function M.HostCarHit(G, Target)
    if Net.Side ~= "host" or not On(F.hit) or not (G and G.Key) or not Alive(Target) or IsDead(Target) then return false end
    local C = A.Coop.Car
    local D = C and C.Drivers[G.Key]
    if not (D and Alive(D.V)) then return false end
    local V = D.V
    -- Kein Eigenbeschuss: Spielerfiguren (Klasse oder vom Spieler gesteuert) nie per Roadkill
    if A.Safe(function() return Target:GetClass():GetFName():ToString() end) == "BP_PlayerCharacter_C"
        or A.Safe(function() return Target:IsPlayerControlled() end) == true then
        if not S.H.Logged["hit_pl|" .. G.Key] then S.H.Logged["hit_pl|" .. G.Key] = true Log("Roadkill auf Spieler von %s verworfen", Short(G.Key)) end
        return false
    end
    -- Abstand Ziel <-> Auto beim Host (Fahrer meldet bei 330; Rest = Lage-Versatz) und echte Geschwindigkeit des
    -- Server-Autos (Lage/Velocity kommen vom Fahrer-Pose), nicht die gemeldete Mph
    local TL = Target:K2_GetActorLocation()
    if D2(V:K2_GetActorLocation(), TL.X, TL.Y, TL.Z) > 700 ^ 2 then return false end
    local Vel = A.Safe(function() return V:GetVelocity() end)
    local Spd = Vel and math.sqrt((Vel.X or 0) ^ 2 + (Vel.Y or 0) ^ 2 + (Vel.Z or 0) ^ 2) or 0
    if Spd < 3 * 44.704 then return false end   -- < 3 mph (Spiel: >= 5, Rest = Abbremsen beim Aufprall)
    local Now, Addr = os.clock(), Target:GetAddress()
    if (S.H.HitCd[Addr] or 0) > Now then return false end
    S.H.HitCd[Addr] = Now + 1
    local Gps = Find(P.GPS)
    local Pawn = Alive(D.Pawn) and D.Pawn or (Alive(D.PC) and A.Safe(function() return D.PC:K2_GetPawn() end) or nil)
    if not Alive(Pawn) then Pawn = nil end
    if not Gps then return false end
    -- CAR-1: nie nil als Schadensart (server.lua admin damage: nil liess UE4SS abstuerzen) - ohne Klasse kein Treffer
    local Dt = Find(P.DMGT)
    if not Dt then
        if not S.H.Logged.dmgt then S.H.Logged.dmgt = true Log("Roadkill: DamageType nicht gefunden - kein Schaden") end
        return false
    end
    pcall(function() Gps:ApplyDamage(Target, math.random(300, 350), nil, Pawn, Dt) end)
    pcall(function()
        local Dm = V.DmgOnVehicleCollision
        local Lo, Hi = math.floor(Dm.X), math.floor(Dm.Y)
        if Hi >= Lo and Hi > 0 then Gps:ApplyDamage(V, math.random(Lo, Hi), nil, Pawn, Dt) end
    end)
    return true
end

-- Host: Preistabelle des Haendlers wie im Spiel (W_VehicleTraderUI.GetDataTable_Vehicles: DT_VehicleInfo 'Trader'
-- -> VehicleVendorButton.Vehicle/Price). Widget nur erzeugen (nicht anzeigen), Knoepfe auslesen, nur Strings merken.
-- Rueckgabe { [Klassenpfad] = Preis } oder nil (dann hoechstens alle 30 s neu versuchen).
local function HostPrices(Ctx)
    local H, Now = S.H, os.clock()
    if H.Prices then return H.Prices end
    if (H.PriceTry or 0) > Now then return nil end
    H.PriceTry = Now + 30
    local T, N = {}, 0
    local ok, err = pcall(function()
        local Cls = Find(P.TRADER_UI) or A.Safe(function() return LoadAsset(P.TRADER_UI) end)
        local WBL = Find(P.WBL)
        if not (Alive(Cls) and WBL) then return end
        local UI = WBL:Create(Ctx, Cls, nil)
        if not Alive(UI) then return end
        local Box = UI.ScrollBox_Vehicle
        if not Alive(Box) then return end
        UI:GetDataTable_Vehicles(Box)
        local Cnt = tonumber(Box:GetChildrenCount()) or 0
        for I = 0, Cnt - 1 do
            local Btn = Box:GetChildAt(I)
            if Alive(Btn) and Alive(Btn.Vehicle) then
                local Pr = tonumber((A.Safe(function() return Btn.Price:ToString() end, "") or ""):gsub("[^%d]", ""), 10)
                local K = Full(Btn.Vehicle)
                if K and Pr and Pr > 0 then T[K] = Pr N = N + 1 end
            end
        end
        pcall(function() Box:ClearChildren() end)
    end)
    if not ok then Log("Kauf: Preistabelle nicht lesbar (%s)", tostring(err)) return nil end
    if N == 0 then Log("Kauf: Preistabelle leer") return nil end
    H.Prices, H.PriceSrc = T, "ui"
    Log("Kauf: Preistabelle des Haendlers gelesen (%d Fahrzeuge, Widget)", N)
    return T
end

-- Struct-Feld lesen: UE4SS-Struct (Name exakt) oder Lua-Tabelle (auch gekuerzter Schluessel "Price"/"Price_10_...")
local function SField(T, Name)
    local V = A.Safe(function() return T[Name] end)
    if V ~= nil or type(T) ~= "table" then return V end
    local Pre = Name:match("^(%a+)_")
    for K, X in pairs(T) do
        if type(K) == "string" and (K == Pre or K:sub(1, #Pre + 1) == Pre .. "_") then return X end
    end
    return nil
end

-- TArray (UE4SS) oder Lua-Tabelle (0- oder 1-basiert) -> Lua-Liste
local function SList(Arr)
    local L = {}
    if type(Arr) == "table" then
        local I = Arr[0] ~= nil and 0 or 1
        while Arr[I] ~= nil and #L < 64 do L[#L + 1] = Arr[I] I = I + 1 end
    elseif Arr ~= nil then
        pcall(function() Arr:ForEach(function(_, E) if #L < 64 then L[#L + 1] = E:get() end end) end)
    end
    return L
end

-- car_buydt (Host): Preise direkt aus DT_VehicleInfo Zeile 'Trader' (wie GetDataTable_Vehicles: .Vehicles[i].Vehicles
-- = Klasse, .Price = double; Anzeige Conv_DoubleToText). UE4SS 3.0.1 UDataTable:FindRow/ForEachRow, kein Widget noetig.
-- Rueckgabe { [Klassenpfad] = Preis } oder nil (dann hoechstens alle 30 s neu, Rueckfall HostPrices).
local function DTPrices()
    local H, Now = S.H, os.clock()
    if H.Prices and H.PriceSrc == "dt" then return H.Prices end
    if (H.DtTry or 0) > Now then return nil end
    H.DtTry = Now + 30
    local DT = Find(P.DT) or A.Safe(function() return LoadAsset(P.DT) end)
    if not Alive(DT) then Log("Kauf: DT_VehicleInfo nicht gefunden") return nil end
    local Row = A.Safe(function() return DT:FindRow("Trader") end)
    if Row == nil then
        pcall(function()
            DT:ForEachRow(function(Name, Data)
                local N = type(Name) == "string" and Name or A.Safe(function() return Name:ToString() end)
                if N == "Trader" and Row == nil then Row = Data end
            end)
        end)
    end
    if Row == nil then Log("Kauf: Zeile 'Trader' in DT_VehicleInfo nicht lesbar") return nil end
    local T, N = {}, 0
    for _, E in ipairs(SList(SField(Row, DTF.ROWS))) do
        local Cls, Pr = SField(E, DTF.CLS), tonumber(SField(E, DTF.PRICE))
        local K = (type(Cls) == "string" and Cls) or (type(Cls) == "userdata" and Alive(Cls) and Full(Cls)) or nil
        if K and Pr and Pr > 0 then T[K] = math.floor(Pr + 0.5) N = N + 1 end
    end
    if N == 0 then Log("Kauf: DT_VehicleInfo 'Trader' ohne Fahrzeuge/Preise") return nil end
    H.Prices, H.PriceSrc = T, "dt"
    Log("Kauf: Preise aus DT_VehicleInfo gelesen (%d Fahrzeuge)", N)
    return T
end

-- FGuid -> 32 Hex-Zeichen (wie ls_inv I.Hex)
local function GuidHex(Gd)
    local ok, Hx = pcall(function()
        return string.format("%08X%08X%08X%08X", math.floor(Gd.A) & 0xFFFFFFFF, math.floor(Gd.B) & 0xFFFFFFFF,
            math.floor(Gd.C) & 0xFFFFFFFF, math.floor(Gd.D) & 0xFFFFFFFF)
    end)
    return ok and Hx or nil
end

-- Host: Geldstapel des Gasts aus dessen SERVER-Komponente (MainJigContainers, wie TakeMoney/CheckIfHasEnoughMoney
-- sie lesen). Rueckgabe { [uid] = Anzahl }, Summe; nil bei Lesefehler.
local function MoneyStacks(Jig, Money)
    local T, Sum = {}, 0
    local MAddr = Money:GetAddress()
    local ok = pcall(function()
        Jig.MainJigContainers:ForEach(function(_, CE)
            CE:get()[JF.ITEMS]:ForEach(function(_, IE)
                local It = IE:get()
                local Info = It[JF.INFO]
                local Id = Info[JF.ID]
                if Alive(Id) and Id:GetAddress() == MAddr then
                    local N = math.floor(tonumber(Info[JF.COUNT]) or 0)
                    local Uid = GuidHex(It[JF.UID])
                    if Uid then T[Uid] = (T[Uid] or 0) + N end
                    Sum = Sum + N
                end
            end)
        end)
    end)
    if not ok then return nil, 0 end
    return T, Sum
end

-- Autos im Umkreis R um L: { [voller Name] = Klassenpfad } (nur Namen, keine UObjects zurueck)
local function CarsNear(L, R)
    local T = {}
    for _, V in ipairs(FindAllOf("BP_VehicleMaster_C") or {}) do
        if Alive(V) and D2(V:K2_GetActorLocation(), L.X, L.Y, L.Z) <= R * R then
            T[Full(V)] = A.Safe(function() return Full(V:GetClass()) end) or "?"
        end
    end
    return T
end

-- CORE-14 (untrusted_paths): Gastpfad pruefen - Core.SafeGuestPath (ls_core, E24), sonst dieselbe Regel hier:
-- nur /Game/<Ordner>.<Name>, keine Karten/Level, hoechstens 200 Zeichen, optional Praefix-Liste
local function SafePath(Path, Prefixes)
    if type(Core.SafeGuestPath) == "function" then
        local ok, R = pcall(Core.SafeGuestPath, Path, Prefixes)
        if ok then return R == true end
    end
    if type(Path) ~= "string" or #Path > 200 or not Path:match("^/Game/[%w_/]+%.[%w_]+$") then return false end
    local L = Path:lower()
    if L:find("/maps/", 1, true) or L:find("/levels/", 1, true) then return false end
    if not Prefixes then return true end
    for _, Pre in ipairs(Prefixes) do if Path:sub(1, #Pre) == Pre then return true end end
    return false
end

-- CAR-21 (car_polish): Haendler-Spawner am naechsten zum Gast (SP: GetActorOfClass @0321, mit einem Haendler gleich;
-- mit zwei Haendlern scheiterte der Kauf am zweiten immer mit "Zu weit vom Abholplatz")
local function TraderSpawner(Pawn)
    if not On(F.polish) then return A.Safe(function() return FindFirstOf(P.SPAWNER) end) end
    local PL = A.Safe(function() return Pawn:K2_GetActorLocation() end)
    local Best, BestD = nil, math.huge
    for _, Sp in ipairs(FindAllOf(P.SPAWNER) or {}) do
        if Alive(Sp) then
            local L = PL and A.Safe(function() return Sp:K2_GetActorLocation() end)
            local Dd = L and D2(L, PL.X, PL.Y, PL.Z) or math.huge
            if not Best or Dd < BestD then Best, BestD = Sp, Dd end
        end
    end
    return Best
end

-- c2s Anfrage: Kauf "Klassenpfad|Preis[|2]" (Host: Geld pruefen/nehmen, Spawner spawnt das replizierte Auto)
-- Preis gilt nur vom Host (DT_VehicleInfo, sonst HostPrices); der Gastwert dient nur zum Vergleich. Ohne Tabelle:
-- abgelehnt, ausser car_buy_guestprice=1 (alter Weg, Gastpreis). Antwort "ok" bzw. mit |2:
-- "ok|<uid>:<neu>;...|<Auto-FName>|x|y|z", Ablehnung "no|<Grund>" (off/rate/bad/class/price/far/busy/blocked/money/spawn).
function H.car_buy(Data, G, Msg)
    if Net.Side ~= "host" then return end
    if not On(F.buy) then return Net.Reply(Msg, "no|off") end
    local Now = os.clock()
    if (S.H.BuyAt[G.Key] or 0) > Now then return Net.Reply(Msg, "no|rate") end
    S.H.BuyAt[G.Key] = Now + 3
    local Fq = Fields(Data)
    local CPath = Fq[1] and Fq[1] ~= "" and Net.Dec(Fq[1]) or nil
    local Price = (Fq[2] or ""):match("^%d+$") and tonumber(Fq[2]) or nil
    local V2 = Fq[3] == "2"
    local PC = Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not (CPath and CPath:sub(1, 6) == "/Game/" and Price and Price > 0 and Alive(Pawn) and G.Ready ~= false) then
        Net.SecWarn(G, G.Key, "car_buy")
        return Net.Reply(Msg, "no|bad")
    end
    -- CORE-14: Gastpfad nie laden, bevor er auf der Preisliste des Hosts steht (LoadAsset eines beliebigen
    -- /Game/-Pfads, z. B. einer Karte, kann den Server abstuerzen lassen) - erst Form, dann Preisliste, dann laden
    if Core.Flag("untrusted_paths", true) and not SafePath(CPath) then
        Net.SecWarn(G, G.Key, "car_buy_path")
        return Net.Reply(Msg, "no|bad")
    end
    local Spawner = TraderSpawner(Pawn)
    if not Alive(Spawner) then return Net.Reply(Msg, "no|class") end
    local Prices = BuyOn("car_buydt") and DTPrices() or nil
    if not Prices then Prices = HostPrices(Spawner) end
    if Prices then
        local HostP = Prices[CPath]
        if not HostP then
            Net.SecWarn(G, G.Key, "car_buy_class")
            return Net.Reply(Msg, "no|class")
        end
        if HostP ~= Price then
            Net.SecWarn(G, G.Key, "car_buy_price")
            Log("Kauf: Preis vom Gast %d, beim Host %d (%s) - Host-Preis gilt", Price, HostP, Short(G.Key))
        end
        Price = HostP
    elseif not Core.Flag("car_buy_guestprice", false) then
        return Net.Reply(Msg, "no|price")
    end
    local Cls = Find(CPath) or A.Safe(function() return LoadAsset(CPath) end)
    local Ok, Sup = false, Cls
    for _ = 1, 10 do   -- muss von BP_VehicleMaster_C erben
        if not Alive(Sup) then break end
        if Sup:GetFName():ToString() == "BP_VehicleMaster_C" then Ok = true break end
        Sup = A.Safe(function() return Sup:GetSuperStruct() end)
    end
    if not Ok then return Net.Reply(Msg, "no|class") end
    local SL = Spawner:K2_GetActorLocation()
    if D2(Pawn:K2_GetActorLocation(), SL.X, SL.Y, SL.Z) > 5000 ^ 2 then return Net.Reply(Msg, "no|far") end
    -- car_buymx: ein Kauf je Spawner in 4 s, Abholplatz (400 uu um den Spawner) frei - sonst stapelt SpawnVehicle
    -- (AdjustIfPossibleButAlwaysSpawn) zwei Autos ineinander
    local SKey = Full(Spawner)
    if BuyOn("car_buymx") then
        if (S.H.BuyMx[SKey] or 0) > Now then return Net.Reply(Msg, "no|busy") end
        if next(CarsNear(SL, 400)) then return Net.Reply(Msg, "no|blocked") end
    end
    local Money = Find(P.MONEY) or A.Safe(function() return LoadAsset(P.MONEY) end)
    local Jig = A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not (Alive(Money) and Alive(Jig)) then return Net.Reply(Msg, "no|bad") end
    if A.Safe(function() return Jig:CheckIfHasEnoughMoney(Price, Money) end) ~= true then return Net.Reply(Msg, "no|money") end
    S.H.BuyMx[SKey] = Now + 4
    local Ui, Ref = BuyOn("car_buyui"), BuyOn("car_buyref")
    local Before, Sum0 = nil, 0
    if Ui or Ref then Before, Sum0 = MoneyStacks(Jig, Money) end
    local CarName
    if Ref and Before then
        -- Erst spawnen und pruefen, dann abbuchen (keine Rueckerstattung noetig, wenn der Spawn scheitert)
        local Old = CarsNear(SL, 1500)
        local okS, err = pcall(function() Spawner:SpawnVehicle(Cls) end)
        if not okS then Core.Fail(F.buy, err) end
        for Name, CP in pairs(CarsNear(SL, 1500)) do
            if not Old[Name] and CP == CPath then CarName = Name break end
        end
        if not CarName then
            Log("Kauf: %s fuer %s nicht gespawnt - kein Geld genommen", CPath:match("[^%.]+$") or CPath, Short(G.Key))
            return Net.Reply(Msg, "no|spawn")
        end
        -- TakeMoney (Decode) ist atomar: genug Geld -> genau Price weg + true, sonst nichts weg + false
        local okT, Took = pcall(function() return Jig:TakeMoney(Price, Money, {}) end)
        local After1, Sum1 = MoneyStacks(Jig, Money)
        local Taken
        if After1 then
            Taken = Sum0 - Sum1
        else   -- Nachlesen gescheitert: Rueckgabewert entscheidet (nicht "alles genommen" annehmen)
            Taken = (okT and Took == true) and Price or 0
        end
        if Taken < Price then
            -- Abbuchung unvollstaendig: Auto wieder weg, Genommenes zurueck (M.Give, je Auftrag hoechstens 1000)
            local Car = Find(CarName)
            if Car then pcall(function() Car:K2_DestroyActor() end) end
            local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
            local Left = math.max(0, Taken)
            while Left > 0 and Inv and Inv.Give do
                local N = math.min(Left, 1000)
                if not A.Safe(function() return Inv.Give(G.Key, P.MONEY, N) end) then break end
                Left = Left - N
            end
            Log("Kauf: Abbuchung %d/%d fuer %s - Auto entfernt, Rueckgabe %d%s", Taken, Price, Short(G.Key),
                math.max(0, Taken) - Left, Left > 0 and string.format(" (FEHLT %d)", Left) or "")
            if Inv and Inv.Dirty then pcall(Inv.Dirty, G) end
            return Net.Reply(Msg, "no|money")
        end
    else
        -- alter Ablauf (car_buyref aus oder Geldstapel unlesbar): abbuchen, dann spawnen
        -- TakeMoney liefert false, wenn nichts abgebucht wurde -> dann auch kein Auto
        local okT, Took = pcall(function() return Jig:TakeMoney(Price, Money, {}) end)
        if not okT or Took == false then return Net.Reply(Msg, "no|money") end
        local Old = CarsNear(SL, 1500)
        local okS, err = pcall(function() Spawner:SpawnVehicle(Cls) end)
        if not okS then Core.Fail(F.buy, err) end
        for Name, CP in pairs(CarsNear(SL, 1500)) do
            if not Old[Name] and CP == CPath then CarName = Name break end
        end
        if not okS or (Ref and not CarName) then
            -- Geld ist weg, aber kein Auto: mit car_buyref den Preis zurueckgeben (ls_inv Give, je Auftrag <= 1000)
            local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
            local Left = Ref and Price or 0
            while Left > 0 and Inv and Inv.Give do
                local N = math.min(Left, 1000)
                if not A.Safe(function() return Inv.Give(G.Key, P.MONEY, N) end) then break end
                Left = Left - N
            end
            Log("Kauf: %s fuer %s nicht gespawnt - Rueckgabe %d/%d%s", CPath:match("[^%.]+$") or CPath, Short(G.Key),
                (Ref and Price or 0) - Left, Price, Left > 0 and " (FEHLT)" or "")
            if Inv and Inv.Dirty then pcall(Inv.Dirty, G) end
            return Net.Reply(Msg, "no|spawn")
        end
    end
    local Car = CarName and Find(CarName)
    local CL = Car and A.Safe(function() return Car:K2_GetActorLocation() end) or SL
    if Car and BuyOn("car_buyown") then   -- Besitzer = Kaeufer (Server-RPCs am Auto, z. B. Kofferraum, kommen an)
        pcall(function() Car:SetOwner(PC) end)
        -- Kaeufer ueber GuestId merken (bleibt bei Neuverbindung gleich; G.Key = PC-Name aendert sich)
        S.H.Bought[Car:GetFName():ToString()] = { Id = G.GuestId and tostring(G.GuestId):lower() or nil, Key = G.Key }
    end
    -- CAR-8: Kaeufer ist Besitzer (Schloss offen; /carlock schliesst ab). Gespeichert mit der Welt (Srv.Save)
    local Gid = Car and On(F.lock) and GidOf(G)
    if Gid then
        local okO, E = pcall(NewOwn, Car, Gid, GuestName(G))
        if okO and E then S.H.Own[Car:GetFName():ToString()] = E S.H.OwnDirty = true end
    end
    local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
    if Inv and Inv.Dirty then pcall(Inv.Dirty, G) end
    local Reply = "ok"
    if V2 then
        local List = {}
        if Ui and Before then   -- geaenderte Geldstapel (auch auf 0 gefallene) fuer ClientUpdateCount beim Gast
            local After = MoneyStacks(Jig, Money) or {}
            for Uid, N0 in pairs(Before) do
                local N1 = After[Uid] or 0
                if N1 ~= N0 and #List < 16 then List[#List + 1] = Uid .. ":" .. math.max(0, N1) end
            end
        end
        Reply = string.format("ok|%s|%s|%.0f|%.0f|%.0f", table.concat(List, ";"),
            Car and Car:GetFName():ToString() or "", CL.X, CL.Y, CL.Z)
    end
    Net.Reply(Msg, Reply)
    Log("Kauf: %s fuer %d von %s (Preis aus %s, Auto %s)", CPath:match("[^%.]+$") or CPath, Price, Short(G.Key),
        tostring(S.H.PriceSrc or "Gast"), Car and Car:GetFName():ToString() or "?")
end

-- s2c: Beifahrer wird Fahrer (Host-Befoerderung)
function H.car_promo(Data)
    if Net.Side ~= "client" or not On(F.pass) then return end
    local C, V = OwnState()
    if not (C and V and C.PassengerOf == V) then return end
    local Fd = Fields(Data)
    local X, Y, Z = tonumber(Fd[1]), tonumber(Fd[2]), tonumber(Fd[3])
    if X and D2(V:K2_GetActorLocation(), X, Y, Z) > 3000 ^ 2 then return end
    C.PassengerOf, C.PassengerSet, C.Confirmed = nil, nil, false
    S.Cl.PassFor = nil
    pcall(SetReq, V, false)
    pcall(function() local Fu = V.FuelComponent if Alive(Fu) then Fu:StartFuelSpend() end end)
    pcall(C.StartDriving, V)
    pcall(A.ShowNote, "You are now driving")
    Log("Fahrersitz uebernommen: %s", V:GetFName():ToString())
end

-- ===================================================================================== CAR-8 Besitz und Schloss
-- car_lock (Standard 1, Schloss je Auto freiwillig: ohne /carlock bleibt alles wie im SP). Host: S.H.Own[Host-FName] =
-- { Gid, Name, Lock, Cls, Path, X, Y, Z }. Besitzer = Kaeufer (car_buy) oder wer ein besitzerloses Auto am Steuer
-- abschliesst. Benutzen darf: Besitzer, Clan (ls_clan Allied) oder jeder, solange nicht abgeschlossen.
-- Datei car_owners.txt (Core.WriteAtomic, beim Speichern ueber server.lua Srv.Save -> M.StoreOwners); nach dem Start
-- per Klasse + Lage (<= 300, gleicher FName bis 1500) zugeordnet, weil EMS Laufzeit-Autos mit neuem FName laedt.
-- Datei nur auf dem dedizierten Server (ein Spielstand); Listen-Host: Besitz nur bis zum Weltwechsel (sonst gingen
-- Schloesser per Klasse + Lage auf Autos eines anderen Spielstands ueber).
-- K30 car_lock (G->H "<HostFName>|1|0"), K31 car_lk (Keyed H->alle, Wert "1|<Name>"), Cap carlk.
local OWN_FILE = "car_owners.txt"
-- Kofferraum-RPCs (wie ls_build OW.BOX_RPC/BOX_RPC_PLUS) am Gast-Jig mit Wert = Kofferraum-Jig: 1-4 die wichtigen
-- (Durchgang 1 fuer alle Paare), 5 = Verbrauchen per UID (car_lockplus, Durchgang 2; Kontextmenue wie Kiste oeffnen/
-- Kleidung zerreissen verbraucht aus dem offenen Behaelter), 6-8 erst danach (Durchgang 3)
local TRUNK_RPC = { { "SERVER_RequestData", "JigMPCompRef" }, { "SERVER_RequestMoveItemToAnotherComp", "From" },
                    { "SERVER_RequestDropItem", "CompTarget" }, { "SERVER_RequestRemoveItem", "TargetComp" },
                    { "SERVER_RequestConsumeItem", "TargetComp" },
                    { "SERVER_RequestSplitItem", "FromComp" }, { "SERVER_RequestStackItem", "FromCom" },
                    { "SERVER_RequestMoveItemToAnotherComp", "To" } }
local DENY_LINES = 24   -- Anteil ls_car an DENY_MAX 256 (ls_build <= 200, ls_combat <= 32)

function Late.LockState(Key, E)
    Net.State("car_lk", Key, (E and E.Lock) and ("1|" .. Net.Enc(E.Name or "?")) or nil, 2)
end

-- E18: darf Gast (Tabelle, Key oder PC) das Auto benutzen? true | false, "locked"
function M.CanUse(Who, V)
    if Net.Side ~= "host" or not On(F.lock) or not Alive(V) then return true end
    local E = S.H.Own[A.Safe(function() return V:GetFName():ToString() end) or ""]
    if not (E and E.Lock) then return true end
    local G = Who
    if type(Who) == "userdata" then G = Net.ByPC(Who) elseif type(Who) == "string" then G = Net.Guests[Who] end
    if Allied(E.Gid, GidOf(G)) then return true end
    return false, "locked"
end

-- Gast (K31): Besitzername fuer Hinweise (nil = nicht abgeschlossen)
function M.LockOf(V)
    if not Alive(V) then return nil end
    local Key = S.Cl.Rev[Full(V)]
    local Val = Key and S.Cl.Lk[Key]
    return Val and Net.Dec(Val:match("^1|(.*)$") or "?") or nil
end

-- c2s K30: nur pruefen und merken, Ausfuehrung in HostFast (Late.LockFlush)
function H.car_lock(Data, G)
    if Net.Side ~= "host" or not On(F.lock) then return end
    local Key, W = tostring(Data or ""):match("^([%w_]+)|([01])$")
    if not Key or #Key > 100 then return Net.SecWarn(G, G.Key, "car_lock") end
    if not RateOk(G, "car_lock", 1) or #S.LockQ >= 16 then return end
    S.LockQ[#S.LockQ + 1] = { Key = G.Key, Car = Key, Want = W == "1" }
end

-- s2c K31 (Gast): Schloss-Stand je Host-FName
function H.car_lk(Value, _, Msg)
    if Net.Side ~= "client" or not On(F.lock) or not Msg or not Msg.Key then return end
    S.Cl.Lk[Msg.Key] = Value
end

-- s2c K32 (Gast, CAR-17 car_trunkn): Kofferraum-Anzahl je Host-FName (nil = unbekannt)
function H.car_n(Value, _, Msg)
    if Net.Side ~= "client" or not On(F.trunkn) or not Msg or not Msg.Key then return end
    S.Cl.TrunkN[Msg.Key] = tonumber(Value)
end

-- s2c car_dn (Gast, car_denyui): Kofferraum <Host-FName> ist fuer ihn gesperrt (DLL verwirft die Kofferraum-RPCs
-- still). Ist das Kofferraumfenster offen (IsInventoryVisible? der Kofferraum-Komponente wie Interact_OpenStorage
-- @32d0), eigenes Inventar schliessen (nur wenn es offen ist, ToggleInventory schaltet um; wie ls_inv I.CloseOwnInv)
-- und Neuabgleich vormerken - wie ls_build OW.DenyUi fuer Kisten
function H.car_dn(Data)
    if Net.Side ~= "client" or not On(F.denyui) then return end
    Try(F.denyui, Late.DenyUi, Data)
end

function Late.DenyUi(Data)
    local Key = tostring(Data or ""):match("^([%w_]+)$")
    local V = Key and Find(S.Cl.Bind[Key])
    local TJ = V and A.Safe(function() return V.BP_JigMultiplayer end)
    if not Alive(TJ) then return end
    local T = {}
    if not pcall(function() TJ["IsInventoryVisible?"](TJ, T) end) then return end
    local Vis = T.Result
    if Vis == nil then for _, X in pairs(T) do Vis = X break end end
    if Vis ~= true then return end
    local Pawn = A.Safe(A.OwnPawn)
    local Jig = Alive(Pawn) and A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if Alive(Jig) then
        local T2 = {}
        local Vis2
        if pcall(function() Jig["IsInventoryVisible?"](Jig, T2) end) then
            Vis2 = T2.Result
            if Vis2 == nil then for _, X in pairs(T2) do Vis2 = X break end end
        end
        if Vis2 ~= false then pcall(function() Jig:ToggleInventory() end) end
    end
    local Inv = A.Coop and A.Coop.Modules and A.Coop.Modules.ls_inv
    local ok, Done = false, false
    if Inv and type(Inv.Resync) == "function" then ok, Done = pcall(Inv.Resync, "Kofferraum gesperrt") end
    pcall(A.ShowNote, "Fahrzeug abgeschlossen")
    Log("Kofferraum %s gesperrt - Fenster geschlossen%s", Short(Key), (ok and Done) and ", Inventar-Neuabgleich" or "")
end

function Late.LockFlush()
    local Q = S.LockQ
    S.LockQ = {}
    local C = A.Coop.Car
    for _, R in ipairs(Q) do
        local G = Net.Guests[R.Key]
        local PC = G and Net.PC(G)
        local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
        if Alive(Pawn) then
            local PL = Pawn:K2_GetActorLocation()
            local V = HostByKey(R.Car, PL.X, PL.Y, PL.Z, 1500)
            local Gid, E = GidOf(G), S.H.Own[R.Car]
            local D = C and C.Drivers and C.Drivers[R.Key]
            local Note
            if not V then
                Note = "Kein Fahrzeug in der Naehe"
            elseif not Gid then
                Note = "Fahrzeug-Schloss: keine Gast-ID"
            elseif E and not Allied(E.Gid, Gid) then   -- nur Besitzer und Clan schalten
                Note = "Nicht dein Fahrzeug"
            elseif not E and not (D and D.V == V) then
                Note = "Zum Abschliessen erst ans Steuer setzen"
            else
                if not E then E = NewOwn(V, Gid, GuestName(G)) S.H.Own[R.Car] = E end
                E.Lock = R.Want
                S.H.OwnDirty = true
                Late.LockState(R.Car, E)
                Note = R.Want and "Fahrzeug abgeschlossen" or "Fahrzeug aufgeschlossen"
                Log("%s: %s von %s (Besitzer %s)", R.Car, R.Want and "abgeschlossen" or "aufgeschlossen", Short(R.Key), tostring(E.Name))
            end
            NoteTo(PC, Note)
        end
    end
end

-- Kofferraum-Sperre (DLL, Native.SetDeny Besitzer "ls_car"): je Gast abgeschlossene, fremde Autos <= 3000 uu,
-- naechste zuerst, hoechstens DENY_LINES Zeilen. Objekte frisch je Lauf (Liste lebt bis zum naechsten Lauf, 1 s).
function Late.LockDeny(Now)
    local Nat = A.Coop.Modules and A.Coop.Modules.ls_native
    if type(Nat) ~= "table" or type(Nat.SetDeny) ~= "function" then return end
    -- CORE-19: Kontext/Wert als Hex-Adresse aus diesem Lauf (ls_native DenyAddress nimmt Strings) - die Liste in
    -- ls_native haelt so keine UObjects bis zum naechsten SetDeny
    local function Hex(O) return A.Safe(function() return string.format("%X", O:GetAddress()) end) end
    local Locked = {}
    for Key, E in pairs(S.H.Own) do
        local V = E.Lock and E.Path and Find(E.Path)
        local J = V and A.Safe(function() return V.BP_JigMultiplayer end)
        local Jh = Alive(J) and Hex(J)
        if Jh then Locked[#Locked + 1] = { Key = Key, V = V, Cj = Jh, L = V:K2_GetActorLocation() } end
    end
    local List = {}
    if #Locked > 0 then
        Net.ForEachGuest(function(G)
            local PC = Net.PC(G)
            local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
            local Jig = Alive(Pawn) and A.Safe(function() return Pawn.BP_JigMultiplayer end)
            local Gh = Alive(Jig) and Hex(Jig)
            if not Gh then return end
            local PL = Pawn:K2_GetActorLocation()
            for _, Cr in ipairs(Locked) do
                local Dd = D2(Cr.L, PL.X, PL.Y, PL.Z)
                if Dd <= 3000 ^ 2 and M.CanUse(G, Cr.V) ~= true then
                    List[#List + 1] = { D = Dd, Jig = Gh, Cj = Cr.Cj, Sig = G.Key .. ">" .. Cr.Key .. ">" .. Full(Jig),
                                        G = G, Key = Cr.Key }
                end
            end
        end)
    end
    table.sort(List, function(X1, X2) return X1.D < X2.D end)
    -- Drei Durchgaenge (naechste Paare zuerst): 1. je Paar die 4 wichtigen Zeilen (RequestData, MoveItem From, Drop,
    -- Remove), solange 4 frei sind (24 Zeilen = 6 Paare, wie bisher); 2. mit car_lockplus dieselben Paare in derselben
    -- Reihenfolge Verbrauchen (ConsumeItem, 1 Zeile); 3. Split/Stack/MoveItem To, solange 3 frei sind (bis 3 Paare
    -- alle 8 Zeilen). Vorher gab es nur 7 oder 0 Zeilen je Paar (Rest 24/17/10/3), das 4. Paar blieb ganz ohne
    -- Sperre. Pr.N = hoechster vergebener Index, lebt nur in der Liste dieses Laufs; Cut = Paare ganz ohne Zeile.
    local Entries, Sig, Cut = {}, {}, 0
    local function AddRpc(Pr, I1, I2)
        for I = I1, I2 do
            local R2 = TRUNK_RPC[I]
            Entries[#Entries + 1] = { Func = P.JIG .. ":" .. R2[1], Context = Pr.Jig, Param = R2[2], Value = Pr.Cj, Tag = "car_lk" }
        end
        Pr.N = I2
    end
    local Plus = On(F.lockplus)   -- car_lockplus: Kontextmenue-Verbrauch (UID) wie ls_build locks_rpcplus
    for _, Pr in ipairs(List) do   -- 1: Kern 1-4
        if #Entries + 4 <= DENY_LINES then AddRpc(Pr, 1, 4) else Pr.N = 0 Cut = Cut + 1 end
    end
    for _, Pr in ipairs(List) do   -- 2: Verbrauchen, 1 Zeile je Paar
        if Plus and Pr.N == 4 and #Entries + 1 <= DENY_LINES then AddRpc(Pr, 5, 5) end
    end
    local Need = Plus and 5 or 4
    for _, Pr in ipairs(List) do   -- 3: Split/Stack/MoveItem To
        if Pr.N == Need and #Entries + (#TRUNK_RPC - 5) <= DENY_LINES then AddRpc(Pr, 6, #TRUNK_RPC) end
    end
    -- Sig erst nach beiden Durchgaengen, mit Zeilenzahl je Paar: geaenderte Abdeckung loest SetDeny aus
    for _, Pr in ipairs(List) do
        if Pr.N > 0 then Sig[#Sig + 1] = Pr.Sig .. ":" .. Pr.N end
    end
    -- "+" = mit Verbrauchen: ein voll abgedecktes Paar hat N=8 mit und ohne car_lockplus, sonst wartete ein
    -- Umschalten bis zur 10-s-Auffrischung
    local Text = (Plus and "+" or "") .. table.concat(Sig, ";")
    -- car_denyui: die DLL verwirft die Kofferraum-RPCs ohne CLIENT_MoveToIndexFailed (API_NATIVE 1.4) -> neu
    -- abgedecktes Paar (Gast > Auto) bekommt car_dn, der Gast schliesst ein offenes Kofferraumfenster (H.car_dn, wie
    -- ls_build OW.DenyUi). Vor der Sig-Rueckkehr: gleiche Sig = keine neuen Paare. Kein eigenes Abstandstor (Liste
    -- ist schon <= 3000 uu, das Fenster prueft der Gast selbst); ohne aktive DLL-Sperre wird nichts verworfen.
    local Cov, Prev = {}, S.H.DenyPrev or {}
    local Ui = On(F.denyui) and (type(Nat.DenyActive) ~= "function" or A.Safe(Nat.DenyActive) == true)
    for _, Pr in ipairs(List) do
        if Pr.N > 0 then
            local K2 = Pr.G.Key .. ">" .. Pr.Key
            if Ui and not Prev[K2] and Net.Has("cardn", Pr.G) then Net.Send("car_dn", Pr.Key, Pr.G, 1) end
            -- erst als gemeldet merken, wenn die DLL-Sperre wirkt: denyon=0 bei leerer Tabelle (ls_build BUILD-22),
            -- sonst kaeme car_dn nie, wenn ls_car die erste Sperrzeile setzt (SetDeny erst unten in diesem Lauf)
            Cov[K2] = (Prev[K2] or Ui) and true or nil
        end
    end
    S.H.DenyPrev = Cov
    if Text == S.H.DenySig and Now < (S.H.DenyAt or 0) then return end
    S.H.DenySig, S.H.DenyAt = Text, Now + 10
    if Cut > 0 and not S.H.Logged.denycut then
        S.H.Logged.denycut = true
        Log("Kofferraum-Sperre voll: %d Paare ohne DLL-Eintrag (%d Zeilen)", Cut, DENY_LINES)
    end
    local ok, err = pcall(Nat.SetDeny, Entries, "ls_car")
    if not ok then Core.Fail(F.lock, err) end
end

-- E19: Besitz speichern (dedizierter Server, server.lua Srv.Save). Nie bevor die Datei in dieser Welt gelesen wurde
-- (ein frueher Srv.Save haette sonst alles mit einer leeren Liste ueberschrieben); NoFind oder Welt nicht frei:
-- ohne UObjects mit den gemerkten Lagen. Offene Eintraege der Datei bleiben, bis Late.MatchOwners sie verwirft.
function M.StoreOwners(NoFind)
    if Net.Side ~= "host" or not On(F.lock) or not A.Settings.server then return false, 0 end
    local H = S.H
    if not H.OwnLoaded then return false, 0 end
    local Live = NoFind ~= true and Settled()
    local Lines, Now = { "# car_owners v1: Host-FName|GastId|Schloss|Klasse|X|Y|Z|Name" }, os.clock()
    local function Add(Key, E)
        if not (type(Key) == "string" and Key:match("^[%w_]+$") and E.Gid and tostring(E.Gid):match("^%w+$")) then return end
        Lines[#Lines + 1] = string.format("%s|%s|%d|%s|%.0f|%.0f|%.0f|%s", Key, tostring(E.Gid), E.Lock and 1 or 0,
            tostring(E.Cls or "?"):gsub("[^%w_%?]", ""), tonumber(E.X) or 0, tonumber(E.Y) or 0, tonumber(E.Z) or 0,
            Net.Enc(E.Name or "?"))
    end
    for Key, E in pairs(H.Own) do
        local V = Live and E.Path and Find(E.Path)
        if V then
            local L = V:K2_GetActorLocation()
            E.X, E.Y, E.Z, E.MissAt = L.X, L.Y, L.Z, nil
        elseif Live then
            E.MissAt = E.MissAt or Now   -- weg (entfernt/entladen): 1 h mit letzter Lage behalten
        end
        if Now - (E.MissAt or Now) < 3600 then
            Add(Key, E)
        else
            H.Own[Key] = nil
            Net.State("car_lk", Key, nil)
        end
    end
    for _, E in ipairs(H.OwnLoad or {}) do Add(E.Key, E) end
    local ok = Core.WriteAtomic(A.ModDir .. OWN_FILE, table.concat(Lines, "\n") .. "\n")
    if ok then H.OwnDirty = false end
    return ok, #Lines - 1
end

-- E19: Besitz laden (dedizierter Server; Zuordnung zu den Autos danach in Late.MatchOwners, alle 5 s)
function M.LoadOwners()
    if Net.Side ~= "host" or not A.Settings.server then return 0 end
    local Text, Now, L = Core.ReadAll(A.ModDir .. OWN_FILE), os.clock(), {}
    for Line in tostring(Text or ""):gmatch("[^\r\n]+") do
        local Key, Gid, Lk, Cls, X, Y, Z, Nm = Line:match(
            "^([%w_]+)|([%w]+)|([01])|([%w_%?]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|(%-?[%d%.]+)|(.*)$")
        if Key and #L < 512 then
            L[#L + 1] = { Key = Key, Gid = Gid:lower(), Lock = Lk == "1", Cls = Cls, X = tonumber(X), Y = tonumber(Y),
                          Z = tonumber(Z), Name = Net.Dec(Nm), At = Now }
        end
    end
    S.H.OwnLoad = L
    if #L > 0 then Log("Fahrzeug-Besitz: %d Eintraege aus %s", #L, OWN_FILE) end
    return #L
end

function Late.MatchOwners(Now)
    local L = S.H.OwnLoad
    if not L or #L == 0 then return end
    local Bound, List = {}, {}
    for _, E in pairs(S.H.Own) do if E.Path then Bound[E.Path] = true end end
    for _, V in ipairs(Cars()) do
        if Alive(V) then
            local Cls = A.Safe(function() return V:GetClass():GetFName():ToString() end)
            local Pl = A.Safe(function() return V:K2_GetActorLocation() end)
            if Cls and Pl then List[#List + 1] = { Cls = Cls, P = Pl, Name = V:GetFName():ToString(), Path = Full(V) } end
        end
    end
    -- Noch keine Autos (Menue-/Ladewelt beim Serverstart): die 15-min-Frist beginnt erst mit Autos in der Welt
    if #List == 0 then
        for _, E in ipairs(L) do E.At = Now end
        return
    end
    local Keep = {}
    for _, E in ipairs(L) do
        local Best, BestD = nil, 300 ^ 2
        for _, Cd in ipairs(List) do
            if Cd.Cls == E.Cls and not Bound[Cd.Path] and not S.H.Own[Cd.Name] and E.X then
                local Dd = D2(Cd.P, E.X, E.Y, E.Z)
                if Cd.Name == E.Key and Dd < 1500 ^ 2 then Best = Cd break end
                if Dd < BestD then Best, BestD = Cd, Dd end
            end
        end
        if Best then
            Bound[Best.Path] = true
            local O = { Gid = E.Gid, Name = E.Name, Lock = E.Lock, Cls = E.Cls, Path = Best.Path, X = Best.P.X,
                        Y = Best.P.Y, Z = Best.P.Z }
            S.H.Own[Best.Name] = O
            S.H.Bought[Best.Name] = S.H.Bought[Best.Name] or { Id = E.Gid }   -- BuyerPC nach Neustart (car_buyown)
            if O.Lock then Late.LockState(Best.Name, O) end
        elseif Now - (E.At or Now) < 900 then
            Keep[#Keep + 1] = E
        else
            Log("Fahrzeug-Besitz: %s (%s) nach 15 min nicht gefunden - verworfen", E.Key, tostring(E.Name))
        end
    end
    if #Keep < #L then Log("Fahrzeug-Besitz: %d zugeordnet, %d offen", #L - #Keep, #Keep) end
    S.H.OwnLoad = Keep
end

-- Host, 1 s (HostFast): Datei einmal je Welt laden (dedizierter Server), offene Eintraege zuordnen, Schloss-Stand an
-- alle (Net.State sendet nur Aenderungen, auch nach einem Schalterwechsel), Kofferraum-Sperre
function Late.LockTick(Now)
    local H = S.H
    if not H.OwnLoaded then
        H.OwnLoaded = true
        if A.Settings.server then M.LoadOwners() end
    end
    if H.OwnLoad and #H.OwnLoad > 0 and Now >= (H.MatchAt or 0) then H.MatchAt = Now + 5 Late.MatchOwners(Now) end
    for Key, E in pairs(H.Own) do Late.LockState(Key, E) end
    Late.LockDeny(Now)
end

-- Schalter car_lock aus (oder FLAG_DOWN): Kofferraum-Sperre und Schloss-Stand einmal zuruecknehmen
function Late.LockOff()
    local H = S.H
    H.DenySig, H.DenyAt, H.DenyPrev = nil, nil, {}   -- car_denyui: nach erneutem Einschalten wieder melden
    for Key in pairs(H.Own) do Net.State("car_lk", Key, nil) end
    local Nat = A.Coop.Modules and A.Coop.Modules.ls_native
    if type(Nat) == "table" and type(Nat.SetDeny) == "function" then pcall(Nat.SetDeny, {}, "ls_car") end
end

-- E20 (Gast, ls_player /carlock): nur merken (kein UObject), ClientFast schickt car_lock fuer das eigene bzw. naechste Auto
function Late.CarLockCmd()
    if Net.Side ~= "client" then return "Nur als Mitspieler auf einem Server" end
    if not On(F.lock) then return "Fahrzeug-Schloss ist aus (car_lock=0)" end
    if not Net.Has("carlk") then return "Der Server kennt keine Fahrzeug-Schloesser" end
    S.Cl.LockAsk = os.clock()
    return "Fahrzeug-Schloss: wird umgeschaltet ..."
end

function Late.LockAsk()
    S.Cl.LockAsk = nil
    local _, V = OwnState()
    local Name = V and Full(V) or S.Cl.NearFull
    local Key = Name and Find(Name) and S.Cl.Rev[Name]
    if not Key then
        pcall(A.ShowNote, Name and "Fahrzeug noch nicht synchron - bitte kurz warten" or "Kein Fahrzeug in der Naehe")
        return
    end
    local Want = S.Cl.Lk[Key] == nil
    Net.Send("car_lock", Key .. "|" .. (Want and "1" or "0"), nil, 1)
    Log("Schloss %s fuer %s angefragt", Want and "zu" or "auf", Key)
end

-- E19 (CAR-19, server.lua admin vehicles/vehicle_rm): Liste aller Autos (Host), nur Werte, keine UObjects
function M.Vehicles()
    local Out, C = {}, A.Coop.Car
    -- CORE-8: vor der Weltfreigabe keine Objekte der alten Welt anfassen (Sitze, Autoliste) -> leere Liste, vehicle_rm
    -- findet dann nichts (sicher). Ohne car_v2 laeuft CheckGen nicht (Settled bliebe false) -> wie bisher
    if Core.Flag(FLAG, true) and not Settled() then return Out end
    local Driven = {}
    for _, D in pairs(C and C.Drivers or {}) do if Alive(D.V) then Driven[Full(D.V)] = true end end
    -- Beifahrer ohne Fahrer (car_pass aus, Gast ohne car2, abgeschlossen/LockHeld): Auto ist besetzt - der Host haengt
    -- Gaeste nie ans Auto (main.lua PlacePawn teleportiert nur), server.lua vehicle_rm prueft deshalb nur Driven
    for _, D in pairs(C and C.Passengers or {}) do if Alive(D.V) then Driven[Full(D.V)] = true end end
    for _, V in ipairs(Cars()) do
        if Alive(V) and #Out < 256 then
            local Name, L = V:GetFName():ToString(), V:K2_GetActorLocation()
            local ok, Fu, MaxFu, Hp, MaxHp = pcall(Stats, V)
            local E = S.H.Own[Name]
            Out[#Out + 1] = { Name = Name, Path = Full(V), X = L.X, Y = L.Y, Z = L.Z,
                              Cls = A.Safe(function() return V:GetClass():GetFName():ToString() end) or "?",
                              Fuel = ok and Fu or nil, MaxFuel = ok and MaxFu or nil, Hp = ok and Hp or nil,
                              MaxHp = ok and MaxHp or nil, Owner = E and E.Gid or nil, OwnerName = E and E.Name or nil,
                              Lock = E and E.Lock or false, Driven = Driven[Full(V)] == true }
        end
    end
    return Out
end

-- CORE-8: Handler erst nach der Weltfreigabe (net_in laeuft auch zwischen LoadMap und DropWorldRefs)
M.Handlers = {}
for Kind, Fn in pairs(H) do
    M.Handlers[Kind] = function(...)
        if not Settled() then return end
        return Fn(...)
    end
end

-- ===================================================================================== Exporte (Integration)

-- CAR-3 (Gast, car_cleanup): lokal aufraeumen wie Event_ExitVehicle @5b16-5da9. Stirbt der Gast im Auto, laeuft der
-- Tod beim Host (DeathInVehicle-Delegate @22a9 wirkt beim Gast nie): Motorton, Timer VehicleSound/CheckWater/
-- Event_Noise (Delegate-Timer @2365, sonst lockt das abgestellte Auto alle 2 s Zombies an), Tankverbrauch, VehicleUI
-- und Radio-Menue blieben. Idempotent (nach normalem Aussteigen ist schon alles aus). V = Auto oder voller Pfad.
function M.LocalCleanup(V)
    if Net.Side ~= "client" or not On(F.cleanup) then return false end
    if type(V) == "string" then V = Find(V) end
    if not Alive(V) then return false end
    local Ksl = Find(P.KSL)
    pcall(function() local Snd = V.EngineSound if Alive(Snd) and Snd:IsActive() then Snd:FadeOut(2.5, 0, 0) end end)
    if Ksl then
        for _, Fn in ipairs({ "VehicleSound", "CheckWater", "Event_Noise" }) do
            pcall(function() Ksl:K2_ClearTimer(V, Fn) end)
        end
    end
    pcall(function() local Fu = V.FuelComponent if Alive(Fu) then Fu:StopSpendFuel() end end)
    pcall(function()
        local UI = V.VehicleUI
        if Alive(UI) then UI:RemoveFromParent() end
        V.VehicleUI = nil
    end)
    -- 5.6 ToggleRadioUI(ForceRemove?=true) @0000: nur ein offenes Radio-Menue schliessen
    pcall(function() local RC = V.RadioComponent if Alive(RC) and Alive(RC.RadioUI) then RC:ToggleRadioUI(true) end end)
    local Key = S.Cl.Rev[Full(V)]
    if Key then S.Cl.Eng[Key] = nil end   -- Zuschauer-Motorton danach wieder nach car_s
    return true
end

-- E18 (CAR-7, car_strict; main.lua OnTick/Handle "start", K29): Host-Schluessel (Host-FName) eines Autos beim Gast aus
-- der car_s-Bindung, nil ohne Bindung
function M.HostKeyOf(V)
    if Net.Side ~= "client" or not Alive(V) then return nil end
    return S.Cl.Rev[Full(V)]
end
-- Host: Auto zum Host-Schluessel innerhalb R um X/Y/Z (R optional, Standard 600 wie car_svc/car_push)
function M.HostByKey(Key, X, Y, Z, R)
    if Net.Side ~= "host" then return nil end
    return HostByKey(Key, tonumber(X), tonumber(Y), tonumber(Z), R)
end

-- K28 carnone (Gast, legacy "x|y|z|Grund", Grund none/far/locked/local; Sender main.lua Handle "start" mit car_strict):
-- Host hat kein passendes Auto, der Gast ist zu weit weg oder es ist abgeschlossen -> aussteigen statt blind zu fahren.
-- Empfangs-Hook (OnHostData): nur merken; Ausfuehrung in ClientFast (Spiel-Thread).
local NONE_NOTE = { none = "Fahrzeug nicht synchron - bitte erneut einsteigen", ["local"] = "Fahrzeug nicht synchron",
                    far = "Zu weit vom Fahrzeug", locked = "Fahrzeug abgeschlossen" }
local function OnCarNone(Text)
    if #S.NoneQ < 4 then S.NoneQ[#S.NoneQ + 1] = tostring(Text or ""):sub(1, 200) end
end
function Late.NoneFlush()
    local Text = S.NoneQ[#S.NoneQ]   -- neueste zaehlt
    S.NoneQ = {}
    if not Text or not On(F.strict) then return end
    local Fd = Fields(Text)
    local Why = NONE_NOTE[Fd[4] or ""] and Fd[4] or "none"
    local C, V = OwnState()
    if not (C and V) or C.Confirmed == true or C.PassengerOf == V then return end   -- schon Fahrer/Beifahrer
    local X, Y, Z = tonumber(Fd[1]), tonumber(Fd[2]), tonumber(Fd[3])
    if X and Y and Z and D2(V:K2_GetActorLocation(), X, Y, Z) > 3000 ^ 2 then return end   -- galt einem anderen Auto
    -- ExitVehicle (@00ca Event_ExitVehicle, Walking, Handbremse) hat einen bool-Ausgabeparameter -> Tabelle
    if not pcall(function() V:ExitVehicle({}) end) then pcall(function() V:ExitVehicle() end) end
    local Note = NONE_NOTE[Why]
    if Why == "locked" then
        local Lk = M.LockOf and M.LockOf(V)
        if Lk then Note = string.format("Fahrzeug abgeschlossen (%s)", Lk) end
    end
    pcall(A.ShowNote, Note)
    Log("Host lehnt das Fahrzeug ab (%s): ausgestiegen", Why)
end

-- E31: Init-Wrapper ueber main.lua Coop.Car (Stop, ApplyState, ShowStats, HostTick, Handle). Das Original wird einmal
-- gemerkt (Coop.Car.LsOrig: ueberlebt ein Neuladen des Moduls, nie Wrapper ueber Wrapper) und immer aufgerufen
-- (Fehler wie bisher an den Aufrufer), eigene Teile in pcall -> Core.Fail(Schalter); Modul nicht geladen -> durch.
S.Wrapped = {}
local function Loaded() return A.Coop.Modules ~= nil and A.Coop.Modules.ls_car == M end
local function WrapCar(Name, Make)
    local C = A.Coop and A.Coop.Car
    if type(C) ~= "table" then return false end
    C.LsOrig = C.LsOrig or {}
    local Old = C.LsOrig[Name] or C[Name]
    if type(Old) ~= "function" then return false end
    C.LsOrig[Name] = Old
    C[Name] = Make(Old)
    S.Wrapped[Name] = true
    return true
end

local Wraps = {}
-- CAR-3: Stop -> Auto vorher merken (Name), Original, dann M.LocalCleanup
function Wraps.Stop(Old)
    return function(...)
        if not (Loaded() and Net.Side == "client" and On(F.cleanup)) then return Old(...) end
        local C = A.Coop.Car
        local Name = Settled() and C and Alive(C.Driving) and Full(C.Driving) or nil
        local ok, err = pcall(Old, ...)
        if Name then Try(F.cleanup, M.LocalCleanup, Name) end
        if not ok then error(err, 0) end
    end
end

-- CAR-9 (car_polish): Anzeige im Auto (VehicleUI, nur beim Insassen gueltig) wie SP ReceiveAnyDamage @6996 /
-- VehicleUI UpdateFuel @01a1, UpdateHealth @0216. Host-Schaden (carstate), Tanken/Reparieren (car_svc) und car_s
-- erreichten bisher nur Fuel-/RepairWidget: der Fahrer sah Rauch, aber volle Balken.
function Late.VehicleUI(V, Fu, MaxFu, Hp, MaxHp)
    if not Alive(V) then return end
    local UI = A.Safe(function() return V.VehicleUI end)
    if not Alive(UI) then return end
    if tonumber(Fu) and tonumber(MaxFu) then UI:UpdateFuel(Fu, MaxFu) end
    if tonumber(Hp) and tonumber(MaxHp) then UI:UpdateHealth(Hp, MaxHp) end
end

-- CAR-17 (car_trunkn) + CAR-8 (car_lock), Gast: "Storage" beim Anschauen wie UpdateStorageStat @1d48-1d9c ("{A} {B}",
-- Item/Items) mit der Host-Anzahl (car_n) - die Gast-Kopie des Kofferraums ist leer, das Spiel zeigte immer "0 Items".
-- Abgeschlossen: Besitzer dazu (K31 car_lk). HUD wie main.lua ShowStats (eigener PC.MyHUD, sonst HUD_Game_C).
function Late.StorageStat(V)
    if not Alive(V) then return end
    local Key = S.Cl.Rev[Full(V)]
    if not Key then return end
    local N = On(F.trunkn) and Net.Has("carn") and S.Cl.TrunkN[Key] or nil
    local Lk = On(F.lock) and M.LockOf(V) or nil
    if not N and not Lk then return end
    local Text = N and string.format("%d %s", N, N == 1 and "Item" or "Items") or ""
    if Lk then Text = (Text ~= "" and (Text .. " - ") or "") .. "abgeschlossen (" .. Lk .. ")" end
    local PC = A.LocalPC()
    local Hud = Alive(PC) and A.Safe(function() return PC.MyHUD end) or nil
    if not Alive(Hud) then Hud = FindFirstOf("HUD_Game_C") end
    if not Alive(Hud) then return end
    Hud:UpdateInteractStats(FName("Storage"), FText(Text), false)
end

function Wraps.ShowStats(Old)
    return function(V, ...)
        Old(V, ...)
        if Loaded() and Net.Side == "client" and On(F.trunkn) then Try(F.trunkn, Late.StorageStat, V) end
    end
end

function Wraps.ApplyState(Old)
    return function(V, Fuel, MaxFuel, Health, MaxHealth, ...)
        Old(V, Fuel, MaxFuel, Health, MaxHealth, ...)
        if Loaded() and not A.Settings.server and On(F.polish) then
            Try(F.polish, Late.VehicleUI, V, Fuel, MaxFuel, Health, MaxHealth)
        end
    end
end

-- CAR-14 (3, car_perf, Host): main.lua Coop.Car.HostTick macht alle 5 s FindAllOf + State aller Autos fuer den alten
-- "cars"-Weg und wirft das fuer car2-Gaeste weg. Braucht ihn kein verbundener Gast (alle mit car_s), frueh zurueck.
function Late.LegacyCarsNeeded(World)
    local C = A.Coop.Car
    if C and os.time() < (C.HostAt or 0) then return true end   -- Original kehrt ohnehin sofort zurueck
    for _, PS in ipairs(A.PlayerStates(World) or {}) do
        local PC = A.Safe(function() return PS:GetOwner() end)
        if Alive(PC) and A.Safe(function() return not PC:IsLocalController() end, false) == true then
            if not (A.Coop.CarV2 and A.Coop.CarV2("fx", PC)) then return true end
        end
    end
    return false
end

function Wraps.HostTick(Old)
    return function(World, ...)
        if Loaded() and On(F.perf) and Alive(World) then
            local ok, Need = pcall(Late.LegacyCarsNeeded, World)
            if ok and Need == false then
                local C = A.Coop.Car
                if C then C.HostAt = os.time() + 5 end
                return
            end
            if not ok then Core.Fail(F.perf, Need) end
        end
        return Old(World, ...)
    end
end

-- CAR-16 (car_guard, Host): Gast-Befehle an main.lua Coop.Car.Handle pruefen (pose/seat/stop; start bleibt in main.lua).
-- pose: Sprung gegen die Host-Lage > 8000 uu/s * dt + 500 wird geloggt (SecWarn, je Gast 1x/10 s); erst ab 5 solchen in
-- 10 s werden sie 10 s lang verworfen (FIXPLAN 3.4: zuerst loggen, handeln erst bei Wiederholung). seat: Versatz auf
-- +-400 (X/Y) bzw. +-300 (Z) begrenzt. stop: Ausstiegspunkt > 1500 uu vom Auto weg -> ohne Punkt (Release nimmt den
-- eigenen). Rueckgabe: Daten (ggf. geaendert) oder false = verwerfen.
function Late.Guard(PC, Key, Data)
    local Cmd = Data:match("^(%a+)")
    local C = A.Coop.Car
    if not (Cmd and C and type(Key) == "string") then return Data end
    local H, Now = S.H, os.clock()
    if Cmd == "start" then H.Guard[Key] = nil return Data end
    if Cmd ~= "pose" and Cmd ~= "seat" and Cmd ~= "stop" then return Data end
    local D = (C.Drivers and C.Drivers[Key]) or (Cmd ~= "pose" and C.Passengers and C.Passengers[Key]) or nil
    if not (D and Alive(D.V)) then return Data end
    local Fd = Fields(Data)
    local X, Y, Z = tonumber(Fd[2]), tonumber(Fd[3]), tonumber(Fd[4])
    if not (X and Y and Z) then return Data end
    local VName = D.V:GetFName():ToString()
    if Cmd == "pose" then
        local Gd = H.Guard[Key]
        if not Gd or Gd.D ~= D then Gd = { D = D, Bad = {}, Until = 0 } H.Guard[Key] = Gd end
        if not Gd.At then Gd.At = Now return Data end   -- erste Lage nach dem Einsteigen: immer
        -- Review R3: Sperre endet nach genau 10 s. Danach neu aufsetzen und diese Lage annehmen (Host-Auto springt auf
        -- die echte Lage); sonst hielten die waehrend der Sperre gezaehlten Spruenge sie bei > 245 m Abstand ewig.
        if Gd.Until > 0 and Now >= Gd.Until then
            Gd.Until, Gd.Bad, Gd.At = 0, {}, Now
            return Data
        end
        local Dt = math.min(math.max(Now - Gd.At, 0.05), 3)
        local Dist, Lim = math.sqrt(D2(D.V:K2_GetActorLocation(), X, Y, Z)), 8000 * Dt + 500
        if Dist <= Lim then Gd.At = Now return Data end   -- plausibel: gilt auch waehrend der Sperre
        local Deny = Now < Gd.Until
        if not Deny then                                  -- waehrend der Sperre verworfene Lagen nicht zaehlen
            local Keep = {}
            for _, T in ipairs(Gd.Bad) do if Now - T <= 10 then Keep[#Keep + 1] = T end end
            Keep[#Keep + 1] = Now
            Gd.Bad = Keep
            if #Keep >= 5 then Gd.Until = Now + 10 Deny = true end
        end
        if Now >= (Gd.WarnAt or 0) then
            Gd.WarnAt = Now + 10
            Log("%s: Lage von %s springt %.0f uu in %.2f s (erlaubt %.0f, %d in 10 s)%s", VName, Short(Key), Dist, Dt,
                Lim, #Gd.Bad, Deny and " - 10 s verworfen" or " - nur geloggt")
            local G = Net.Guests[Key]
            if G then Net.SecWarn(G, Key, "car_pose") end
        end
        if Deny then return false end
        Gd.At = Now
        return Data
    elseif Cmd == "seat" then
        local Cx, Cy = math.max(-400, math.min(400, X)), math.max(-400, math.min(400, Y))
        local Cz = math.max(-300, math.min(300, Z))
        if Cx == X and Cy == Y and Cz == Z then return Data end
        if not H.Logged["seat|" .. Key] then
            H.Logged["seat|" .. Key] = true
            Log("%s: Sitz-Versatz von %s begrenzt (%.0f/%.0f/%.0f)", VName, Short(Key), X, Y, Z)
        end
        Fd[2], Fd[3], Fd[4] = string.format("%.1f", Cx), string.format("%.1f", Cy), string.format("%.1f", Cz)
        return table.concat(Fd, "|")
    end
    if not Fd[5] or D2(D.V:K2_GetActorLocation(), X, Y, Z) <= 1500 ^ 2 then return Data end
    Log("%s: Ausstiegspunkt von %s zu weit vom Auto - verworfen", VName, Short(Key))
    return "stop"
end

function Wraps.Handle(Old)
    return function(PC, Key, Data, ...)
        if not (Loaded() and Net.Side == "host" and On(F.guard)) or type(Data) ~= "string" then
            return Old(PC, Key, Data, ...)
        end
        local ok, New = pcall(Late.Guard, PC, Key, Data)
        if not ok then
            Core.Fail(F.guard, New)
            New = Data
        end
        if New == false then return end
        return Old(PC, Key, New or Data, ...)
    end
end

-- main.lua Coop.Car.Handle "pose": Zustand vom Fahrer, Server-Schaden davon abziehen. Rueckgabe: anzuwendender Wert.
function M.PoseHp(Key, V, Hp)
    if not On(F.dmg) or not Alive(V) then return Hp end
    local H2, Name, Now = S.H, Full(V), os.clock()
    local HC = V.VehicleHealthComponent
    if not Alive(HC) then return Hp end
    local Cur = tonumber(HC.CurrentHealth) or Hp

    local Out = Hp
    if (H2.HoldHp[Name] or 0) > Now then
        Out = Cur   -- gerade vom Host gesetzt (Reparatur/Schaden): Fahrerwert noch alt
    else
        local Last = H2.LastHp[Name]
        if Last and Cur < Last - 0.5 then
            Out = math.max(0, math.min(Hp, Hp - (Last - Cur)))
            H2.PushHp[Key], H2.HoldHp[Name] = true, Now + 2
            Log("%s: Server-Schaden %.1f gegen Fahrerwert", V:GetFName():ToString(), Last - Cur)
        end
    end
    H2.LastHp[Name] = Out
    return Out
end

-- main.lua Coop.Car.Release (Fahrer-Zweig, vor den Eingaben): Server rechnet wieder mit eigenen Eingaben
function M.HostRelease(V)
    if not Alive(V) then return end
    local Name = Full(V)
    if On(F.input) then pcall(SetReq, V, false) end
    S.H.Flagged[Name], S.H.LastHp[Name], S.H.HoldHp[Name] = nil, nil, nil
end

-- main.lua Coop.Car.StartDriving / Stop (Gast): Flag sofort statt im naechsten Durchlauf
-- car_diag (Diagnose 27.10.: Zombies beim Fahren unsichtbar?): nur waehrend einer Fahrt, alle 5 s. Host zaehlt lebende
-- KI-Figuren um jedes von einem Gast gefahrene Auto (und den Abstand der Server-Figur zum Auto), der Gast dasselbe um sein
-- Auto plus versteckte (bHidden) und Mesh-unsichtbare. Beide Logs per Uhrzeit vergleichen. 0 = aus.
function M.DiagCount(At)
    local N50, N100, Hid, Inv = 0, 0, 0, 0
    for _, Ch in ipairs(A.Coop.Characters and A.Coop.Characters() or {}) do
        local Cls = Alive(Ch) and A.Safe(function() return Ch:GetClass():GetFName():ToString() end) or "PlayerCharacter"
        if not Cls:find("PlayerCharacter", 1, true) and A.Safe(function() return Ch["IsDead?"] end) ~= true then
            local L = A.Safe(function() return Ch:K2_GetActorLocation() end)
            local D = L and (L.X - At.X) ^ 2 + (L.Y - At.Y) ^ 2 or math.huge
            if D <= 10000 ^ 2 then
                N100 = N100 + 1
                if D <= 5000 ^ 2 then N50 = N50 + 1 end
                if A.Safe(function() return Ch.bHidden end) == true then Hid = Hid + 1 end
                local Ms = A.Safe(function() return Ch.Mesh end)
                if Alive(Ms) and A.Safe(function() return Ms:IsVisible() end) == false then Inv = Inv + 1 end
            end
        end
    end
    return N50, N100, Hid, Inv
end
function M.DiagTick()
    if not Core.Flag("car_diag", false) then return end
    local C = A.Coop.Car
    if type(C) ~= "table" then return end
    local function Dist(P, At) return P and At and math.sqrt((P.X - At.X) ^ 2 + (P.Y - At.Y) ^ 2) / 100 or -1 end
    if Net.Side == "host" then
        for Key, D in pairs(C.Drivers or {}) do
            local At = Alive(D.V) and A.Safe(function() return D.V:K2_GetActorLocation() end)
            if At then
                local N50, N100 = M.DiagCount(At)
                local P = Alive(D.Pawn) and A.Safe(function() return D.Pawn:K2_GetActorLocation() end) or nil
                Log("Diag Fahrt %s: Server-Zombies 50 m %d / 100 m %d, Server-Figur %.0f m vom Auto", Short(Key), N50, N100, Dist(P, At))
            end
        end
    elseif Net.Side == "client" then
        local V = C.Driving or C.PassengerOf
        local At = Alive(V) and A.Safe(function() return V:K2_GetActorLocation() end)
        if not At then return end
        local N50, N100, Hid, Inv = M.DiagCount(At)
        local Pawn = A.Safe(A.OwnPawn, nil)
        local P = Alive(Pawn) and A.Safe(function() return Pawn:K2_GetActorLocation() end) or nil
        Log("Diag Fahrt: Client-Zombies 50 m %d / 100 m %d (versteckt %d, Mesh unsichtbar %d), eigene Figur %.0f m vom Auto", N50, N100, Hid, Inv, Dist(P, At))
    end
end

-- car_zrel (Live 27.10., car_diag: Server 8-13 Zombies in 50 m ums Auto, Gast 0): im Auto schickt der Gast keine
-- Kamera-Updates (die haengen an den Bewegungsdaten der Figur, die im Auto ruht) -> der Server rechnet die Relevanz vom
-- Einstieg aus, Zombies am Auto werden dem Gast nicht repliziert (unsichtbar, greifen aber an). Host 1x/s: lebende
-- KI-Figuren <= 80 m um ein von einem Gast gefahrenes Auto bAlwaysRelevant; zurueck bei > 120 m, Tod oder Fahrtende.
-- Figurenliste = Coop.Characters() (0,2-s-Cache der KI, kein eigenes FindAllOf). 0 = aus (gesetzte Marker werden zurueckgenommen).
function M.ZRelTick()
    if Net.Side ~= "host" then return end
    S.ZRel = S.ZRel or {}
    local C, Cars = A.Coop.Car, {}
    if Core.Flag("car_zrel", true) and type(C) == "table" then
        for _, D in pairs(C.Drivers or {}) do
            local At = Alive(D.V) and A.Safe(function() return D.V:K2_GetActorLocation() end)
            if At then Cars[#Cars + 1] = At end
        end
    end
    if #Cars == 0 and next(S.ZRel) == nil then return end
    local Keep = {}
    for _, Ch in ipairs(#Cars > 0 and A.Coop.Characters and A.Coop.Characters() or {}) do
        local Cls = Alive(Ch) and A.Safe(function() return Ch:GetClass():GetFName():ToString() end) or "PlayerCharacter"
        if not Cls:find("PlayerCharacter", 1, true) and A.Safe(function() return Ch["IsDead?"] end) ~= true then
            local L, K = A.Safe(function() return Ch:K2_GetActorLocation() end), A.Safe(function() return Ch:GetAddress() end)
            for _, At in ipairs((L and K) and Cars or {}) do
                local D = (L.X - At.X) ^ 2 + (L.Y - At.Y) ^ 2
                if D <= 8000 ^ 2 or (S.ZRel[K] and D <= 12000 ^ 2) then Keep[K] = Ch break end
            end
        end
    end
    local Added = 0
    for K, Ch in pairs(Keep) do
        if not S.ZRel[K] and pcall(function() Ch.bAlwaysRelevant = true end) then S.ZRel[K], Added = Ch, Added + 1 end
    end
    for K, Ch in pairs(S.ZRel) do
        if not Keep[K] then
            if Alive(Ch) then pcall(function() Ch.bAlwaysRelevant = false end) end
            S.ZRel[K] = nil
        end
    end
    if Added > 0 and not S.ZRelLogged then
        S.ZRelLogged = true
        Log("Fahrt: %d Zombie(s) am Auto fuer Gaeste immer relevant (car_zrel)", Added)
    end
end

function M.OnStartDriving(V)
    if Alive(V) and On(F.input) then pcall(SetReq, V, false) end
end
function M.OnStop(V)
    if Alive(V) and On(F.input) then pcall(SetReq, V, true) end
end

-- main.lua Coop.Car.Release (Host): PC des Kaeufers eines gekauften Autos (car_buyown), sonst nil.
-- Registry je Auto-FName (Host-seitig stabil) -> GuestId; PC frisch ueber Net.Guests/Net.PC (nach Reconnect neuer PC)
function M.BuyerPC(V)
    if Net.Side ~= "host" or not Alive(V) then return nil end
    local Name = A.Safe(function() return V:GetFName():ToString() end)
    local R = Name and S.H.Bought[Name]
    if type(R) ~= "table" then return nil end
    local Hit = nil
    if not R.Id then
        Hit = R.Key and Net.Guests[R.Key] or nil   -- ohne GuestId (Altgast): nur gleicher PC-Name
    else
        for _, G in pairs(Net.Guests) do
            if G.GuestId and tostring(G.GuestId):lower() == R.Id then Hit = G break end
        end
    end
    if not Hit then return nil end
    if Hit.Key ~= R.Key then
        Log("Kaeufer von %s neu verbunden: %s -> %s", Name, Short(R.Key), Short(Hit.Key))
        R.Key = Hit.Key
    end
    local PC = Net.PC(Hit)
    return Alive(PC) and PC or nil
end

-- fuer ls_ui: lokale Meldung "No gas found" usw. bis dahin unterdruecken
-- aktiver Fahrzeug-Weg (fuer die Legacy-Gates in main.lua)
function M.Active() return Core.Flag(FLAG, true) end
function M.Flag(Name) return On(F[Name] or Name) end

-- CORE-30 (car_perf): Tabellen je Gast-Schluessel beim Trennen leeren (Net "gone"); auf einem 24/7-Server gibt es
-- sonst nie einen Weltwechsel, der sie zuruecksetzt
function Late.ForgetGuest(Key)
    local H2 = S.H
    H2.BuyAt[Key], H2.Guard[Key], H2.SeatPawn[Key] = nil, nil, nil
    local Pre = Key .. "|"
    for K in pairs(H2.Rate) do if K:sub(1, #Pre) == Pre then H2.Rate[K] = nil end end
    for K in pairs(H2.Logged) do if type(K) == "string" and K:find(Key, 1, true) then H2.Logged[K] = nil end end
end

-- CORE-30 (car_perf), Host alle 60 s, nur bei freigegebener Welt: Eintraege zu verschwundenen Autos und abgelaufene
-- Sperren weg (S.H.Trunk/Bad je vollem Namen, Bought je FName, PushCd/BuyMx/BuyAt je Zeitpunkt, Guard ohne Sitz)
function Late.Janitor(Now)
    local H2, C = S.H, A.Coop.Car
    for Name in pairs(H2.Trunk) do if not Find(Name) then H2.Trunk[Name] = nil end end
    for Name in pairs(H2.Bad) do if not Find(Name) then H2.Bad[Name] = nil end end
    for K, T in pairs(H2.PushCd) do if T <= Now then H2.PushCd[K] = nil end end
    for K, T in pairs(H2.BuyMx) do if T <= Now then H2.BuyMx[K] = nil end end
    for K, T in pairs(H2.BuyAt) do if T <= Now then H2.BuyAt[K] = nil end end
    if next(H2.Bought) then
        local Live = {}
        for _, V in ipairs(Cars()) do
            local N = Alive(V) and A.Safe(function() return V:GetFName():ToString() end)
            if N then Live[N] = true end
        end
        for N in pairs(H2.Bought) do if not Live[N] and not H2.Own[N] then H2.Bought[N] = nil end end
    end
    for K, Gd in pairs(H2.Guard) do
        if not (C and C.Drivers and C.Drivers[K] == Gd.D) then H2.Guard[K] = nil end
    end
    local N = 0
    for _ in pairs(H2.Logged) do N = N + 1 end
    if N > 300 then H2.Logged = {} end
end

function M.HostTick(Now)
    local H2 = S.H
    for Addr, T in pairs(H2.HitCd) do if T <= Now then H2.HitCd[Addr] = nil end end
    for K, R in pairs(H2.Rate) do if Now - R.T > 5 then H2.Rate[K] = nil end end
    if On(F.perf) and Now >= (H2.JanAt or 0) and Settled() then
        H2.JanAt = Now + 60
        Try(F.perf, Late.Janitor, Now)
    end
end

function M.ClientTick(Now)
    local Cl = S.Cl
    for Addr, T in pairs(Cl.HitCd) do if T <= Now then Cl.HitCd[Addr] = nil end end
    for K, T in pairs(Cl.SentAt) do if Now - T > 10 then Cl.SentAt[K] = nil end end
    for Id in pairs(Cl.Sit) do if Cl.Seat[Id] == nil then Cl.Sit[Id] = nil end end   -- CORE-30: Sitzpose ohne Sitz
end

function M.Init(Api)
    A = Api
    Net.Cap("car2", Core.Flag(FLAG, true))
    Net.Cap("carlk", On(F.lock))     -- K30/K31 (CAR-8)
    Net.Cap("carn", On(F.trunkn))    -- K32 (CAR-17)
    Net.Cap("cardn", On(F.denyui))   -- car_dn: Kofferraumfenster bei Sperre schliessen (CAR-8)
    Net.Cap("carnone", On(F.strict))   -- K28: Gast fuehrt carnone aus (Host: main.lua Handle "start" liest LocalCaps/Net.Has)
    Net.OnEvent("gone", function(Peer)
        if Net.Side ~= "host" or not Peer or not Peer.Key then return end
        if On(F.perf) then pcall(Late.ForgetGuest, Peer.Key) end   -- CORE-30
        if not On(F.pass) then return end
        local C = A.Coop.Car
        if C and (C.Drivers[Peer.Key] or C.Passengers[Peer.Key]) then
            local ok, err = pcall(C.Release, Peer.Key)
            if not ok then Core.Fail(F.pass, err) end
            Log("Freigabe %s (Verbindung weg)", Short(Peer.Key))
        end
    end)
    Core.Every("car_host", 0.2, HostFast)
    Core.Every("car_diag", 5, function() pcall(M.DiagTick) end)
    Core.Every("car_zrel", 1, function()
        local okZ, errZ = pcall(M.ZRelTick)
        if not okZ then Core.Fail("car_zrel", errZ) end
    end)
    Core.Every("car_cli", 0.1, ClientFast)
    Core.Every("car_slow", 1, function(Now)
        -- Faehigkeit nachfuehren (FLAG_DOWN/Umschalten von car_v2 zieht car2 zurueck; ohne Aenderung No-op)
        Net.Cap("car2", Core.Flag(FLAG, true))
        Net.Cap("carlk", On(F.lock))
        Net.Cap("carn", On(F.trunkn))
        Net.Cap("cardn", On(F.denyui))
        Net.Cap("carnone", On(F.strict))   -- K28 (FLAG_DOWN von car_strict zieht carnone zurueck)
        TryHooks(Now)
        Try("car_buyclk", BuyPatch)
        -- CAR-2: Geister vor dem car2-Gate (Spawner feuern 6-8 s nach dem Laden, oft vor dem Handshake)
        if Net.Side == "client" and On(F.ghost) and CheckGen() then Try(F.ghost, GhostCars, Now) end
        ClientSlow(Now)
    end)
    A.TestCommands.car_diag = function()
        local C = A.Coop.Car or {}
        local Nd, Np, Nb = 0, 0, 0
        for _ in pairs(C.Drivers or {}) do Nd = Nd + 1 end
        for _ in pairs(C.Passengers or {}) do Np = Np + 1 end
        for _ in pairs(S.Cl.Bind) do Nb = Nb + 1 end
        A.TestLog("car: side=%s v2=%s cap=%s fahrer=%d beifahrer=%d bindungen=%d index=%d eigen=%s hooks=%s/%s/%s/%s",
            tostring(Net.Side), tostring(Core.Flag(FLAG, true)), tostring(Net.Has("car2")), Nd, Np, Nb, #S.Cl.Index,
            tostring(S.Cl.OwnFull), tostring(S.Hooked.Horn), tostring(S.Hooked.Buy), tostring(S.Hooked.Push),
            tostring(S.Hooked.Tow))
        local Nk = 0
        for _ in pairs(S.H.Bought) do Nk = Nk + 1 end
        A.TestLog("car kauf: klickpatch=%s hookok=%s preise=%s gekauft=%d offen=%d/%d",
            tostring(S.Patch.On), tostring(S.Hooked.BuyOk), tostring(S.H.PriceSrc or "-"), Nk, #S.BuyQ, #S.BuyRes)
        -- CAR-2: Geister (Index: HasAuthority beim Gast; Sweep: Role 3 + repliziert + nicht aus der Karte)
        local Ng = 0
        for _, E in ipairs(S.Cl.Index) do if E.Ghost then Ng = Ng + 1 end end
        A.TestLog("car geister: index=%d sweep=%d entfernt=%d spawner_gesperrt=%d (car_ghost=%s)", Ng, S.Cl.GhostN or 0,
            S.Cl.GhostDel or 0, S.Cl.GhostSp or 0, tostring(On(F.ghost)))
        -- Runde 9: Besitz/Schloss (CAR-8), Fehler-Autos (CAR-18), Wrapper (E31), Faehigkeiten
        local No, Nl, Nbad, Nlk = 0, 0, 0, 0
        for _, E in pairs(S.H.Own) do No = No + 1 if E.Lock then Nl = Nl + 1 end end
        for _ in pairs(S.H.Bad) do Nbad = Nbad + 1 end
        for _ in pairs(S.Cl.Lk) do Nlk = Nlk + 1 end
        local Nw = {}
        for Name in pairs(S.Wrapped) do Nw[#Nw + 1] = Name end
        table.sort(Nw)
        A.TestLog("car r9: besitz=%d zu=%d datei_offen=%d sperre=%s fehlerautos=%d gast_zu=%d wrapper=%s carlk=%s carn=%s",
            No, Nl, #(S.H.OwnLoad or {}), tostring(S.H.DenySig or "-"):sub(1, 60), Nbad, Nlk,
            #Nw > 0 and table.concat(Nw, ",") or "-", tostring(Net.Has("carlk")), tostring(Net.Has("carn")))
    end
    -- K28 carnone (Gast, legacy Host-Daten): Empfangs-Hook merkt nur, ClientFast fuehrt aus
    if type(A.HostDataHandlers) == "table" then A.HostDataHandlers.carnone = OnCarNone end
    -- E20: /carlock (ls_player) -> Text fuer den Spieler; die Arbeit macht ClientFast
    A.Coop.CarLockCmd = function()
        local ok, Text = pcall(Late.CarLockCmd)
        return ok and Text or "Fahrzeug-Schloss: Fehler"
    end
    -- E31-Wrapper zuletzt (nach allem, was in Init scheitern koennte; verschachtelte Coop.Car-Felder rollt der
    -- Modul-Lader nicht zurueck - die Wrapper rufen ohne geladenes Modul nur das Original)
    local Done = {}
    for _, Name in ipairs({ "Stop", "ApplyState", "ShowStats", "HostTick", "Handle" }) do
        if Wraps[Name] and WrapCar(Name, Wraps[Name]) then Done[#Done + 1] = Name end
    end
    Log("geladen (car_v2=%s, Wrapper: %s)", tostring(Core.Flag(FLAG, true)), #Done > 0 and table.concat(Done, ",") or "-")
end

return M
