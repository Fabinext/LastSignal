-- ls_inv.lua - LastSignal Runde 5: Inventar v2a (WP6) + v2b (WP7). Host und Gast in einem Modul.
-- Grundlage: analysis\findings\inv.md (Decode). Kurz:
--   * Kein Vollsync nach dem Join: SERVER_LoadSaveDataFromClientSide (LSD) nur einmal je Verbindung (main.lua G.Sync),
--     Respawn ueber SERVER_RequestData (keine Ausruestungs-Neuanlage). Exporte SkipResync/ClientRespawn.
--   * Hotbar (3 Verbrauchs-Slots, Hotbar 6-8) und aktive Waffe: Gast meldet, Host speichert .bar.txt, nach dem
--     Erst-Sync zurueck (Hotbar wie BP_PlayerCharacter:OnClientDataRequested, Waffe per ServerFuncChangeActiveSlot).
--   * Signatur-Store: Host-Ledger (0,5 s) erkennt jede Inventar-Aenderung -> G.Store hoechstens alle 2 s.
--   * Pending-Resolver inv_pend (pend2): Gast-Platzhalter (PendingRequests) -> Host prueft Gutschrift (Ledger),
--     legt per AddNewItemSomewhere an (CLIENT_AddNewItem erreicht den Gast), Gast entfernt den Platzhalter.
--   * Digest inv_sum: lokal erzeugte Items ohne Pending (adopt) und lokale Entnahmen (inv_use, Brunnen/Generator).
--   * Container: Replikation stabil benannter Kisten, Looted/Storage-Flag, Belegt-Hinweis, Haendler-Geld, Tier-Leichen.
--   * UE 5.6: Jig-Klasse heisst BP_JigComponent_C (Eigenschaft weiter BP_JigMultiplayer), AddNewItemSomewhere hat den neuen
--     Parameter SpecificContainer (FName, 6.), W_CampfireUI -> W_CookingUI_C, Daten-Asset Type -> ItemType, Zombie
--     Looted -> Looted?, Huntsman-Fleisch liegt im Tier-Jig selbst (Container_AnimalMeat entfaellt), Rohfisch je Art.
--   * Fixplan #8/#16 (22.10.): Laufzeit-Kisten (gebaut, Todeskiste) und tote KI nahe Gaesten bekommen beim
--     Host ein repliziertes Jig (inv_netrep); bleibt die Loot-UI beim Gast leer, laedt der Host sie im Namen des Gasts
--     (inv_carc -> GastComp:SERVER_RequestData(KisteComp), inv_lootprime). Gast entfernt lokale Geister-Todeskisten.
--   * Runde 7 Haendler (trd_v1, findings\traders_r7.md): Handel bleibt server-autoritativ (Spiel), die Mod macht den
--     Host-Haendler fuer Gaeste adressierbar, fuehrt Sitzungen (Geld, Sperre, Restock) und entfernt Geister-Haendler.
--   * Runde 8 (Cap invx): Pluender-XP beim Host (inv_scavxp: inv_loot-Uebergang, inv_scav Laufzeit-Kisten), Werkzeug-
--     Kisten (inv_toolxp: inv_tool, Haltbarkeit + XP), Lager-Aufhebung "3" (inv_unmark), Refill-Ruecksetzen beim Gast,
--     Rucksack mit Inhalt (inv_bpbag), Stationen adressierbar (inv_stationrep), kein Doppel-Hinweis (inv_trdnote).
-- Regeln: keine Hooks, nur Polling ueber Core.Every; UObjects nie ueber Ticks halten (Namen/Pfade); FGuid-Tabellen
-- nur an lokale BP-Funktionen, an RPCs nur Objekte aus dem Spiel; jeder Spielaufruf in pcall.

local M = {}
local Core = require("ls_core")
local Net = require("ls_net")
local NativeOk, Native = pcall(require, "ls_native")      -- nur fuer trd_note/trd_dlg/trd_reset (DLL optional)
if not NativeOk or type(Native) ~= "table" then Native = nil end
local A                                 -- Coop.API
local I = {}                              -- interne Funktionen (spart Hauptchunk-Locals)

-- Feldnamen der Jig-Strukturen (aus dem Header-Dump / main.lua)
local F = {
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    PICKUP_REF = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657",
    DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA",       -- Vector2D (X = aktuell)
    SAVE_PLAYER = "/Game/Blueprints/Saves/Save_Player.Save_Player_C",
}

-- Konstanten
local K = {
    ZERO = string.rep("0", 32),
    -- UE 5.6: W_CampfireUI entfernt, Kochen ueber W_CookingUI_C (/Game/Inventory/Widgets/Crafting/W_CookingUI)
    CRAFT_UIS = { "W_PlayerCraftingUI_C", "W_CraftingWorkbenchUI_C", "W_ConstructionWorkbenchUI_C", "W_CookingUI_C" },
    -- Runde 8 (inv_toolxp): Werkzeug-Kisten (SUPER BP_MasterObject, Karten-Actors) wie Kisten replizieren/markieren
    CONT_CLASSES = { "BP_LootContainer_C", "BP_MASTER_PicklockContainer_C", "BP_MASTER_ToolRequiredContainer_C" },
    TOOL_CLS = "BP_MASTER_ToolRequiredContainer_C",
    -- inv_scav: Laufzeit-Kisten -> Eigenschaft, die HoldToInteract/OpenContainer lokal setzt (Airdrop hat kein
    -- ContainerLooted: SetInspected @0b85; Kisten erben BP_LootContainer_C.HoldToInteract @03e4)
    -- Runde 9 (WORLD-2): Laufzeit-Kisten der Zufalls-Spawner (Keycard-Koffer, Versteck, Spezial-Kiste; SUPER
    -- BP_LootContainer_C wie Container_POICrate_C) - Host repliziert sie (ls_world world_spawncrate)
    SCAV = { Master_AirdropContainer_C = "Inspected", Container_POICrate_C = "ContainerLooted",
             Container_CompoundCrate_C = "ContainerLooted", BP_KeycardBriefcaseContainer_C = "ContainerLooted",
             Container_HiddenCache_C = "ContainerLooted", Container_SpecialItemSpawner_C = "ContainerLooted" },
    -- feste Reihenfolge fuer I.ClientScav (eine Klasse je Lauf -> 1 FindAllOf/s)
    SCAVL = { "Master_AirdropContainer_C", "Container_POICrate_C", "Container_CompoundCrate_C",
              "BP_KeycardBriefcaseContainer_C", "Container_HiddenCache_C", "Container_SpecialItemSpawner_C" },
    -- inv_stationrep: Stationen, deren Jig der Host fuer SERVER_RequestCraftItem (CompRef) adressierbar macht
    STATIONS = { "Buildable_Campfire_C", "Buildable_ConstructionBench_C", "Buildable_CraftingWorkbench_C",
                 "Buildable_WeaponsEquipmentWorkbench_C", "Buildable_DisassemblyWorkbench_C", "Buildable_TrashBin_C" },
    CU = "/Script/AutoSettings.Default__ConsoleUtils",
    PICKUP_CLASSES = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" },
    -- (d) Ernte/Angeln: exakte Kurznamen (klein) der Rohstoff-Ertraege. Frueher Teilstrings ("rock", "metal", "fish",
    -- "log" ...) -> trafen DA_RocketLauncher, DA_66mmRocket, DA_MakeshiftMetalArmor, DA_HolographicSight, DA_FishingRod
    FREE = { da_woodenlog = true, da_woodplank = true, da_rock = true, da_scrapmetal = true, da_rawfish = true,
             da_smallrawfish = true, da_largerawfish = true, da_rawmeat = true, da_smallrawmeat = true },
    -- UE 5.6: Angeln liefert je Art ein eigenes Daten-Asset (DA_RawCod, DA_RawPike, RawMutated/... statt DA_RawFish)
    FREE_DIRS = { "/Consumables/Hunger/Fish/Raw/" },
    ADOPT = { "water", "bottle", "canteen", "jug", "rag", "cloth" },   -- lokal-only ohne Pending (Purify u. ae.)
    -- (c) Verbrauchs-Budget nur fuer diese Item-Ordner (Zerlegen/Zerreissen/Reinigen/Brunnen -> Rohstoffe, Wasser,
    -- Lappen). ADOPT-Teilstrings allein trafen DA_FragGrenade/DA_StorageCrate*/DA_GarageDoor ("rag").
    BUDGET_DIRS = { "/DataAssets/CraftingMaterials/Resources/", "/DataAssets/CraftingMaterials/EmptyBottles/",
                    "/DataAssets/Consumables/Thirst/", "/DataAssets/Other/Junk/", "/Consumables/Medical/DA_Rags." },
    -- Lootbox (DA_Tier1-3LootBox). "crate"/"package" trafen gebaute Kisten (DA_StorageCrate*, DA_AmmoCrate ...):
    -- Kiste aufstellen = 8 beliebige Items
    BOX = { "lootbox", "loot_box" },
    ROLE_AUTHORITY = 3,
    HOLD = 6,              -- Host haelt eine pend-Anfrage ohne Gutschrift so lange (s)
    CREDIT_TTL = 30, BUDGET_TTL = 20, INC_TTL = 8, CARC_TTL = 90, OWN_TTL = 5, DONE_TTL = 120, EMPTY_SECS = 5, GIVE_TTL = 30,
    LEAVE_SECS = 20,
    REP_RADIUS = 3000, NEAR = 600, TRADER_RADIUS = 4000,
    -- inv_carc: nur Leichen dieser Familien (Wurzelklassen wie ls_ai FAM_ROOT) und Kisten ("c"); Spieler nie
    CARC_ROOTS = { BP_Animal_C = "a", BP_MasterZombie_C = "z", BP_ZombieBoss_C = "z", BP_MasterAICharacter_C = "h",
                   BP_PlayerCharacter_C = false, BuildableMaster_Container_C = "c", BuildableMaster_Tent_C = "c",
                   Container_DeadPlayerLoot_C = "c", BP_LootContainer_C = "c",
                   -- Laufzeit-Lager mit MainJigContainers (props.tsv): Airdrop (BP_MasterObject_C), Vitrine, Ladegeraet
                   Master_AirdropContainer_C = "c", BuildableMaster_Display_C = "c", Buildable_BatteryCharger_C = "c",
                   BP_MASTER_ToolRequiredContainer_C = "c", Container_POICrate_C = "c", Container_CompoundCrate_C = "c" },
    -- inv_netrep: Laufzeit-Kisten, deren Jig-Komponente der Host fuer Gaeste repliziert (je Durchlauf eine Klasse).
    -- UE 5.6: Container_AnimalMeat gibt es nicht mehr - Tier-Tod (Baer Death @0106, Hase/Hirsch/Wolf Ubergraph) legt das
    -- Huntsman-Fleisch per AddNewItemSomewhere(DA_RawMeat) direkt in das Tier-Jig -> Leichen-Weg (Familie "a", ls_ai/inv_carc)
    NETREP_CLASSES = { "BuildableMaster_Container_C", "Container_DeadPlayerLoot_C", "BuildableMaster_Tent_C",
                       "Master_AirdropContainer_C", "BuildableMaster_Display_C",
                       "Buildable_BatteryCharger_C", "Container_POICrate_C", "Container_CompoundCrate_C",
                       "BP_KeycardBriefcaseContainer_C", "Container_HiddenCache_C", "Container_SpecialItemSpawner_C" },
    GHOST_BOX = "Container_DeadPlayerLoot_C",
    -- Haendler (Runde 7): FindAllOf liefert Unterklassen mit (wie FindAllOf("Character")); Duplikate per Pfad verworfen
    TRD_CLASSES = { "BP_TraderMaster_C", "BP_MasterTrader_C" },
    TRD_ROOT = "BP_TraderMaster_C", TRD_WANDER = "BP_MasterTrader_C",
    -- Shakes/Military spawnen ihre Spawner ohne Authority-Pruefung auf jeder Maschine (Unterklassen von TRD_ROOT)
    TRD_GHOST = { "BP_TraderMaster_C" },
    TRD_NOTE = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI",
    TRD_DLG = { "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C:OnExecuteInteractDialogue",
                "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C:OnExecuteInteractDialogue" },
    TRD_RESET = "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C:Event_Reset",
    TRD_REF = "^([%w_]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]*)|([01])$",
    TRD_OPEN_R = 800, TRD_HOST_R = 1000, TRD_FAR = 1500, TRD_MATCH = 500,
    TRD_HB = 5, TRD_HB_TTL = 30,       -- Gast meldet offene Sitzung alle 5 s; Host gibt sie nach 30 s Stille frei
    JB_MIN = 3, JB_MAX = 45,           -- inv_join_guard: hoechstens 45 s (JB_MIN wird nicht mehr genutzt)
    JB_GRACE = 0.25,                   -- inv_join_guard: Abnahmen zaehlen nur bis 0,25 s nach der Freigabe des Gasts
    -- Runde 9 inv_craft_one/inv_craft_guard: Crafting-Widgets (Pfade wie ls_world W.XP_CRAFT), Mengen-Knoepfe (in allen
    -- vier gleich benannt), Felder der Rezept-Struktur (HandleServerFuncRequestCraft @0463 ItemsNeeded, @0747 DoNotConsume)
    CRAFT_PATHS = { "/Game/Inventory/Widgets/Crafting/W_PlayerCraftingUI.W_PlayerCraftingUI_C",
                    "/Game/Inventory/Widgets/Crafting/W_CraftingWorkbenchUI.W_CraftingWorkbenchUI_C",
                    "/Game/Inventory/Widgets/Crafting/W_ConstructionWorkbenchUI.W_ConstructionWorkbenchUI_C",
                    "/Game/Inventory/Widgets/Crafting/W_CookingUI.W_CookingUI_C" },
    CRAFT_INC = ":BndEvt__BP_CraftingWidget_Button_Increase_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature",
    CRAFT_DEC = "BndEvt__BP_CraftingWidget_Button_Decrease_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature",
    CF_NEED = "ItemsNeeded_8_03B3B6B348EE04631090FFB588341C30", CF_OUT = "ItemToCraft_4_D2CE3CA74FD5DD913A8E86BB23414908",
    CF_KEEP = "DoNotConsumeItemOnCraft?_42_6F1124D84CBF144157D75BAE1F7DB685",
    INCONT = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF",   -- Container steckt in einem Item (Rucksack, Waffe, Magazin)
    -- inv_battery_patch (Gast): CheckBatteryLevel @018d-@01b3 (kdis) "nicht gefunden" -> Battery?=true, Value=100
    BATT_FN = "/Game/Blueprints/Components/BatteryComponent.BatteryComponent_C:CheckBatteryLevel",
    -- Runde 9 INV-6b: UseBattery (Batterie-Timer der Lampen, alle 0,1 s) sucht ebenfalls per GetItemByUID in
    -- MainJigContainers -> beim Gast @01a8 "nicht gefunden" -> Successful?=false -> Taschenlampe Svr_Flashlight(false)
    -- (Ubergraph @1f26d -> @11e3d) bzw. Anbauteil Event_Battery(false) 0,1 s nach dem Einschalten. Gleicher Patch:
    -- @01ba DoubleConst 0 -> 100 (+ LetBool 14, LocalOutVariable 48), @01cd False -> True (+ Jump ->0x027d). Entladung:
    -- Taschenlampe beim Host selbst (Server-Timer), Anbauteile ueber inv_light (I.LightHost)
    BATT_USE = "/Game/Blueprints/Components/BatteryComponent.BatteryComponent_C:UseBattery",
    BATT = { { N = "inv_batt_a", Fn = 1, Off = 407, Old = "28", New = "27" },
             { N = "inv_batt_b", Fn = 1, Off = 426, Old = "3700000000000000000652030000", New = "3700000000000059400652030000" },
             { N = "inv_batt_c", Fn = 2, Off = 442, Old = "3700000000000000001448", New = "3700000000000059401448" },
             { N = "inv_batt_d", Fn = 2, Off = 461, Old = "28067d020000", New = "27067d020000" } },
    -- inv_station_tab: Siedlungs-Stationen (Karten-Actors), Rezepttabelle wie OnStopExecuteInteract (Kochen 2, Werkbank 1)
    STATION_TAB = { BP_CookingStation_C = 2, BP_CraftingStation_C = 1 },
    GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
    -- inv_repair: Reparatur-Wege (Kontextmenue ohne Parameter, Ziehen mit Receiver/Dropped) und passende Sets
    REP_CTX = "/Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C",
    REP_IOI = "/Game/JigSInventory/Jigsaw/Widgets/ItemOverItem/JigItemOverItemComp.JigItemOverItemComp_C",
    REP_FN = { w = "ContextRepairWeapon", a = "ContextRepairArmor", t = "ContextRepairAttachment",
               wd = "WeaponRepair", ad = "ArmorRepair", rf = "RefillRadFilter" },
    REP_KIT = { w = "cleaningkit", t = "cleaningkit", wd = "cleaningkit", a = "armorrepairkit", ad = "armorrepairkit",
                rf = "filter" },
    REP_KITDA = { w = { "Weapons/DA_WeaponCleaningKit", "Weapons/DA_MakeshiftWeaponCleaningKit" },
                  a = { "Equipment/DA_ArmorRepairKit", "Equipment/DA_MakeshiftArmorRepairKit" } },
    REP_DIR = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Repairing/",
    DA_ROOT = "/Game/Inventory/Items/DataAssets/",                  -- alle Item-Daten-Assets (CORE-14 Gast-Pfade)
    -- Runde 9 Welle 2 (inv-2)
    ATT_ID = "ID_21_A45B60654D588805C5D52BA4BC5CD4FD", ATT_MIN = "MinCount_31_E62F0FA548FC7DB0BDB860B4C0D695B6",  -- INV-12b
    AMMO_DIR = "/Attachments/Ammo/",                                -- INV-18: Munition gibt kein Verbrauchs-Budget
    JIG_DROP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestDropItem",  -- INV-28
    -- Closeout R2 (inv_cons_nomove): Stueck in eine andere Komponente (Kiste/Kofferraum/Haendler); Parameter From, To, UID
    JIG_MOVE = { "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestMoveItemToAnotherComp",
                 "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestSplitItem",
                 "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestStackItem" },
    -- INV-6b: Batterie-Verbrauch der Gast-Lampen. Lampen-Klassen (lokale Anbauteile, nur beim Spieler) und Rate je 0,1 s
    -- wie Battery_Flashlight (Licht 0.0125, Entfernungsmesser 0.01) -> je s
    LIGHT_CLS = { "BP_TacticalLightLocalAttachment_C", "BP_SmallTacticalLightLocalAttachment_C",
                  "BP_TacticalLaserLightComboLocalAttachment_C", "BP_RangeFinderLocalAttachment_C" },
    LIGHT_RATE = 0.125, RF_RATE = 0.1, LIGHT_TTL = 7,
    -- E5 RepairSlot: Gruende aus ls_combat C.SlotState (handoff_combat), die ein bewachter Voll-Abgleich beheben kann
    SLOT_WHY = { missing = "Gegenstand fehlt", pending = "wartet mit fremdem Gegenstand" },
}

local S = { H = {}, DA = {}, Gen = -1, Cont = nil, ContAt = -math.huge, Rep = {}, LState = {}, LCheckAt = 0,
            Traders = nil, TradersAt = -math.huge, Open = {}, GiveQ = {}, Pick = nil, PickAt = -math.huge,
            UseFns = {}, Warned = {}, CarcFam = {}, NetRep = {}, NetRepN = 0, Prime = {}, NRi = 0, AddrAt = {},
            TrdS = {}, TrdT = {}, TrdRep = {}, TrdTid = {}, TrdN = 0, TrdFam = {}, TrdEv = {},
            ScavDone = {}, ScavQ = {}, ScavL = {},            -- Runde 8: Pluender-/Werkzeug-XP (einmal je Kiste)
            ScSt = {},                                        -- Laufzeit-Kiste durchsucht: [Pfad] = inv_scst-Schluessel
            RepQ = {},                                        -- Runde 9 INV-4: Reparatur-Auftraege (inv_rep)
            -- Runde 9 Welle 2: INV-19 [Pfad] = os.clock|false (gehaltene Kiste), [Pfad] = Ende des Prime-Fensters; INV-6b
            -- [Gast-Key] = { [uid32] = { At, Last } } gemeldete Lampen
            RefHold = {}, PrimeHold = {}, Light = {},
            JB = {} }                                         -- [Figurenname] = { Key, Sum, At, Taint } Beitritts-Schutz
local C = {}                                                  -- Gast-Zustand (I.ClientReset)

local function Log(fmt, ...) A.Log("[Inv] " .. fmt, ...) end

-- ---------------------------------------------------------------------------------------------- Hilfen

function I.On(Name) return Core.Flag(Name, true) == true end
function I.OnOff(Name) return Core.Flag(Name, false) == true end      -- Schalter mit Standard aus
function I.Safe(Fn, Fallback) return A.Safe(Fn, Fallback) end
-- Faehigkeit invx (Runde 8): Pluender-/Werkzeug-XP, inv_scav/inv_tool
function I.InvX() return I.On("inv_v2b") and (I.On("inv_scavxp") or I.On("inv_toolxp")) end
-- Faehigkeit invu: Lager-Aufhebung "3" (inv_unmark) unabhaengig von invx; beide Seiten muessen sie fuehren
function I.InvU() return I.On("inv_v2b") and I.On("inv_lflag") and I.On("inv_unmark") end
function I.Alive(O) return O ~= nil and A.IsAlive(O) end

-- Fehler eines Teil-Features zaehlen (Core.Fail schaltet nach > 3 in 60 s ab)
function I.Try(Flag, Fn, ...)
    local ok, err = pcall(Fn, ...)
    if not ok then Core.Fail(Flag, err) end
    return ok, err
end

-- Schluessel koennen Gast-Text enthalten -> Tabelle begrenzt (bei 512 Eintraegen geleert, wie RateOk R.K)
function I.WarnOnce(Key, fmt, ...)
    if S.Warned[Key] then return end
    S.WarnedN = (S.WarnedN or 0) + 1
    if S.WarnedN > 512 then S.Warned, S.WarnedN = {}, 1 end
    S.Warned[Key] = true
    Log(fmt, ...)
end

-- FGuid (Struktur aus dem Spiel) -> 32 Hex-Zeichen, nil wenn unlesbar
function I.Hex(G)
    local ok, H = pcall(function()
        return string.format("%08X%08X%08X%08X", math.floor(G.A) & 0xFFFFFFFF, math.floor(G.B) & 0xFFFFFFFF,
            math.floor(G.C) & 0xFFFFFFFF, math.floor(G.D) & 0xFFFFFFFF)
    end)
    return ok and H or nil
end

-- 32 Hex-Zeichen -> FGuid-Tabelle (nur fuer lokale BP-Funktionen, nie an RPCs)
function I.GuidT(H)
    local T, Keys = {}, { "A", "B", "C", "D" }
    for N = 1, 4 do
        local V = tonumber(H:sub(N * 8 - 7, N * 8), 16) or 0
        if V >= 0x80000000 then V = V - 0x100000000 end
        T[Keys[N]] = V
    end
    return T
end

function I.Path(O)
    return I.Safe(function() return O:GetFullName():match("^%S+%s+(%S+)$") end)
end

function I.Name(O) return I.Safe(function() return O:GetFName():ToString() end) end

function I.Short(P) return tostring(P or "?"):match("([^%./]+)$") or tostring(P) end

-- UE4SS-Ausgabeparameter: Wert unter dem Namen, sonst der einzige Eintrag
function I.Out(T, Name)
    if T[Name] ~= nil then return T[Name] end
    for _, V in pairs(T) do return V end
    return nil
end

function I.Match(Name, List)
    for _, W in ipairs(List) do if Name:find(W, 1, true) then return true end end
    return false
end

function I.Dist2(L, X, Y, Z)
    local DX, DY, DZ = L.X - X, L.Y - Y, L.Z - Z
    return DX * DX + DY * DY + DZ * DZ
end

function I.Loc(Actor)
    local L = I.Safe(function() return Actor:K2_GetActorLocation() end)
    if not L then return nil end
    return { X = L.X, Y = L.Y, Z = L.Z }
end

-- Weltwechsel: alle Caches mit Namen/Adressen verwerfen
function I.CheckGen()
    local N = A.WorldGen and A.WorldGen.N or 0
    if N == S.Gen then return true end
    S.Gen, S.DA, S.Cont, S.ContAt, S.Rep, S.LState = N, {}, nil, -math.huge, {}, {}
    S.Traders, S.TradersAt, S.Open, S.Pick, S.PickAt = nil, -math.huge, {}, nil, -math.huge
    S.H, S.NetRep, S.NetRepN, S.Prime, S.AddrAt = {}, {}, 0, {}, {}
    S.TrdS, S.TrdT, S.TrdRep, S.TrdTid = {}, {}, {}, {}
    S.ScavDone, S.ScavQ, S.ScavL, S.RepQ = {}, {}, {}, {}
    S.RefHold, S.PrimeHold, S.Light, S.PruneL = {}, {}, {}, nil   -- Runde 9 Welle 2: INV-19, INV-6b, CORE-30
    S.GuestComp = nil                                             -- Closeout R3 (inv_cons_nomove_any): Adressen ungueltig
    for _, Key in pairs(S.ScSt) do Net.State("inv_scst", Key, nil, 2) end
    S.ScSt = {}
    I.ClientReset()
    return false
end

function I.Loading()
    local W = A.WorldGen
    return W and W.Loading and (os.clock() - (W.LoadingAt or 0)) < 60
end

-- Daten-Asset -> { P = Pfad, Gn = Pfad des ItemGainedFromConsumption oder false, Nm = Kurzname klein }
-- Cache je Adresse (Daten-Assets bleiben geladen), Weltwechsel leert ihn.
function I.DAInfo(DA)
    if not I.Alive(DA) then return nil end
    local Addr = I.Safe(function() return DA:GetAddress() end)
    local E = Addr and S.DA[Addr]
    if E then return E end
    E = { P = I.Path(DA) or "?" }
    local Gain = I.Safe(function() return DA.ItemGainedFromConsumption end)
    E.Gn = I.Alive(Gain) and (I.Path(Gain) or false) or false
    E.Nm = I.Short(E.P):lower()
    if Addr then S.DA[Addr] = E end
    return E
end

-- Daten-Asset nach Pfad (geladen oder nachladen), nur echte Jigsaw-Items.
-- Untrusted (Gast-Pfad, Runde 9 CORE-14, untrusted_paths): nachladen nur ein Item-Daten-Asset
-- (/Game/Inventory/Items/DataAssets/.../DA_X.DA_X) und nur mit Core.SafeGuestPath (E24, falls vorhanden); sonst nur schon
-- geladene Objekte (LoadAsset eines Karten-/Level-Pakets ausserhalb der Reise stuerzt den Server ab)
function I.ItemAsset(Path, Untrusted)
    if type(Path) ~= "string" or not Path:match("^/Game/[%w_/%.%-]+$") then return nil end
    local Load = true
    if Untrusted and Core.Flag("untrusted_paths", true) == true then
        local A1, A2 = Path:match("^/Game/[%w_/]+/(DA_[%w_]+)%.(DA_[%w_]+)$")
        Load = #Path <= 200 and A1 ~= nil and A1 == A2 and Path:sub(1, #K.DA_ROOT) == K.DA_ROOT
        local Sg = Core.SafeGuestPath
        if Load and type(Sg) == "function" then
            local ok, R = pcall(Sg, Path, { K.DA_ROOT })
            Load = ok and R == true
        end
    end
    local Asset = StaticFindObject(Path)
    if not I.Alive(Asset) and Load then Asset = I.Safe(function() return LoadAsset(Path) end) end
    if not I.Alive(Asset) then return nil end
    local Cls = I.Safe(function() return Asset:GetClass() end)
    while Cls and I.Safe(function() return Cls:IsValid() end, false) do
        if (I.Name(Cls) or ""):find("JigsawItem_DataAsset", 1, true) then return Asset end
        Cls = I.Safe(function() return Cls:GetSuperStruct() end)
    end
    return nil
end

-- Inventar einer Jig-Komponente lesen. Rueckgabe: Map uid32 -> { N, P, Gn, U }, Signatur-Text, Anzahl Eintraege.
function I.Scan(Comp)
    local Out, Num, Sum, X = {}, 0, 0, 0
    local Hold                                        -- Closeout (inv_cons_nodrop): UIDs der Items mit Unter-Container
    Comp.MainJigContainers:ForEach(function(_, CE)
        local Cont = CE:get()
        -- Runde 9: Container steckt in einem Item (Rucksack/Waffe/Magazin) -> Eintraege mit Nest (Digest "~", INV-7)
        local In = I.Safe(function() return I.Hex(Cont[K.INCONT]) end)
        local Nest = (In ~= nil and In ~= K.ZERO) or nil
        if Nest then Hold = Hold or {}; Hold[In] = true end   -- InContainerUID = UID des haltenden Items (GetSubContainers @00da)
        Cont[F.ITEMS]:ForEach(function(_, IE)
            local It = IE:get()
            local Uid = I.Hex(It[F.UID])
            if not Uid or Uid == K.ZERO then return end
            local Info = It[F.INFO]
            local Cnt = math.floor(tonumber(Info[F.COUNT]) or 0)
            local E = Out[Uid]
            if E then
                E.N = E.N + Cnt
            else
                local D = I.DAInfo(Info[F.ID]) or { P = "?", Gn = false, Nm = "?" }
                -- O = Reihenfolge in MainJigContainers (HandleServerFuncRequestCraft verbraucht in dieser Reihenfolge)
                -- Hd = UID des haltenden Items (Closeout R2, inv_cons_nodrop: Halter abgeworfener Items in I.Ledger)
                Out[Uid] = { N = Cnt, P = D.P, Gn = D.Gn, Nm = D.Nm, U = Uid:sub(1, 16), O = Num + 1, Nest = Nest,
                             Hd = Nest and In or nil }
            end
            Num, Sum = Num + 1, Sum + Cnt
            X = X ~ ((tonumber(Uid:sub(1, 8), 16) or 0) * 31 + (tonumber(Uid:sub(25, 32), 16) or 0) + Cnt)
        end)
    end)
    -- Ct = Item haelt Unter-Container (Rucksack/Waffe/Magazin): sein Abwurf nimmt sie mit (RemoveGetInfo @12f8/@14ee)
    if Hold then for U in pairs(Hold) do if Out[U] then Out[U].Ct = true end end end
    return Out, string.format("%d/%d/%X", Num, Sum, X & 0xFFFFFFFFFFFF), Num
end

-- Element (Struktur aus dem Spiel) mit dieser UID (32 oder 16 Zeichen Praefix) finden
function I.FindItem(Comp, Uid)
    local Found
    Comp.MainJigContainers:ForEach(function(_, CE)
        if Found then return end
        CE:get()[F.ITEMS]:ForEach(function(_, IE)
            if Found then return end
            local It = IE:get()
            local H = I.Hex(It[F.UID])
            if H and H:sub(1, #Uid) == Uid then Found = It end
        end)
    end)
    return Found
end

-- ---------------------------------------------------------------------------------------------- Container-Cache

-- Stabil benannte Kisten der Karte (RF_WasLoaded), Positionen einmal gelesen. FindAllOf nur alle 120 s.
function I.ContList(Now)
    -- inv_cont_secs: feste Kisten (RF_WasLoaded) bewegen sich nicht, Weltwechsel leert den Cache (I.CheckGen); der volle
    -- Neuaufbau (2902 Kisten) kostete 35-50 ms Ruckler bei Host und Gast. Runde 9 INV-23: Standard 0 = nie neu (nur nach
    -- Weltwechsel); > 0 = alle so viele s (mind. 30). Profil legacy/Down liefert 0 = ebenfalls nur nach Weltwechsel
    local Secs = tonumber(Core.Flag("inv_cont_secs", 0)) or 0
    if S.Cont and (Secs <= 0 or Now - S.ContAt < math.max(30, Secs)) then return S.Cont end
    S.ContAt = Now
    local List, Flag = {}, EObjectFlags and EObjectFlags.RF_WasLoaded
    for _, Cls in ipairs(K.CONT_CLASSES) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if #List < 20000 and I.Alive(O) and Flag and I.Safe(function() return O:HasAnyFlags(Flag) end, false) then
                local L, Full, Nm = I.Loc(O), I.Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end), I.Name(O)
                if L and Full and Nm then
                    -- Lc = BP_LootContainer_C-Familie (HoldToInteract @03e4: Pluender-XP), T = Werkzeug-Kiste
                    List[#List + 1] = { N = Nm, F = Full, X = L.X, Y = L.Y, Z = L.Z, Lc = Cls == "BP_LootContainer_C" or nil,
                                        T = Cls == K.TOOL_CLS or nil }
                end
            end
        end
    end
    if not S.Cont then Log("%d feste Kisten erkannt", #List) end
    S.Cont = List
    return List
end

-- Frisches Objekt zu einem Cache-Eintrag
function I.Fresh(E)
    local O = I.Safe(function() return StaticFindObject(E.F) end)
    return I.Alive(O) and O or nil
end

function I.NearConts(L, Radius, Max)
    local Out, R2 = {}, Radius * Radius
    for _, E in ipairs(I.ContList(os.clock())) do
        if I.Dist2(L, E.X, E.Y, E.Z) <= R2 then
            Out[#Out + 1] = E
            if #Out >= (Max or 64) then break end
        end
    end
    return Out
end

-- Haendler-Familie eines Actors: "t" = BP_TraderMaster_C (fest), "w" = BP_MasterTrader_C (wandernd), false = keiner.
-- Hochlaufen der Klassenkette, Cache je Klassenname. Zweiter Wert: Klassenname
function I.TrdFam(O)
    local Cls = I.Safe(function() return O:GetClass() end)
    local CN = Cls and I.Name(Cls)
    if not CN then return nil end
    local Hit = S.TrdFam[CN]
    if Hit ~= nil then return Hit, CN end
    local Fam, Sc = false, Cls
    for _ = 1, 16 do
        local SN = I.Name(Sc)
        if not SN then break end
        if SN == K.TRD_ROOT then Fam = "t" break end
        if SN == K.TRD_WANDER then Fam = "w" break end
        Sc = I.Safe(function() return Sc:GetSuperStruct() end)
        if not I.Alive(Sc) then break end
    end
    S.TrdFam[CN] = Fam
    return Fam, CN
end

-- Alle Haendler (feste + wandernde). MaxAge: Cache-Alter in s (Standard 60). Wd = wandernd (Position veraltet ->
-- immer frisch lesen), Ld = Karten-Actor (RF_WasLoaded, FName auf Host und Gast gleich), Cls = Klassenname
function I.TraderList(Now, MaxAge)
    if S.Traders and Now - S.TradersAt < (MaxAge or 60) then return S.Traders end
    S.TradersAt = Now
    local List, Seen, Flag = {}, {}, EObjectFlags and EObjectFlags.RF_WasLoaded
    for _, Cls in ipairs(K.TRD_CLASSES) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            local Full = I.Alive(O) and I.Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end)
            local Nm = Full and not Seen[Full] and I.Name(O)
            if Nm and not Nm:find("^Default__") and #List < 500 then
                Seen[Full] = true
                local Fam, CN = I.TrdFam(O)
                local L = Fam and I.Loc(O)
                if L then
                    -- Netz-Schluessel: FName nur fuer Karten-Haendler (RF_WasLoaded); zur Laufzeit gespawnte haben auf
                    -- Host und Gast verschiedene FNames -> Position "@x,y,z"
                    local Loaded = Flag and I.Safe(function() return O:HasAnyFlags(Flag) end, false) or false
                    local NK = Loaded and Nm or string.format("@%.0f,%.0f,%.0f", L.X, L.Y, L.Z)
                    List[#List + 1] = { N = Nm, F = Full, X = L.X, Y = L.Y, Z = L.Z, K = NK, Ld = Loaded, Cls = CN,
                                        Wd = Fam == "w" }
                end
            end
        end
    end
    S.Traders = List
    return List
end

-- Gast: Host-Wert zu einem lokalen Haendler (Karten-Haendler per FName, sonst naechste Host-Position <= 300)
function I.TraderVal(E)
    if E.Ld then return C.Trader[E.N] end
    local Best, BestD
    for Key, V in pairs(C.Trader) do
        local X, Y, Z = Key:match("^@(%-?%d+),(%-?%d+),(%-?%d+)$")
        if X then
            local D = I.Dist2(E, tonumber(X), tonumber(Y), tonumber(Z))
            if D <= 300 * 300 and (not BestD or D < BestD) then Best, BestD = V, D end
        end
    end
    return Best
end

-- ================================================================================================ HOST

function I.HState(Key)
    local H = S.H[Key]
    if not H then
        H = { Credit = {}, Inc = {}, Budget = { T = -math.huge, N = 0, Any = 0 }, PendQ = {}, Free = { Since = 0, N = 0 },
              Rate = { Since = 0, N = 0 }, StoreAt = 0, Own = {}, Done = {} }
        S.H[Key] = H
    end
    return H
end

function I.HostPawn(G)
    local PC = Net.PC(G)
    local Pawn = PC and I.Safe(function() return PC:K2_GetPawn() end)
    if not I.Alive(Pawn) then return nil end
    return Pawn
end

-- Gutschriften pflegen: Verbrauch eines Items (Server-Seite) -> Rest-Item / Budget; Zuwachs -> "had"
function I.OnDec(H, O, D, Now)
    if O.Gn then
        local Cr = H.Credit[O.Gn]
        if not Cr or Now - Cr.T > K.CREDIT_TTL then Cr = { N = 0 } H.Credit[O.Gn] = Cr end
        Cr.N, Cr.T = math.min(Cr.N + D, 20), Now
        -- inv_gain_host: Rueckgabe-Item (leere Flasche) ab der zweiten legt das Spiel beim Gast ohne Platzhalter auf den
        -- vorhandenen Stapel (Live 27.10.: nur die erste kam als Platzhalter) -> der Host erfaehrt nie davon. Vormerken;
        -- I.GainTick legt es nach GAIN_WAIT s selbst an, falls bis dahin kein Platzhalter die Gutschrift verbraucht hat
        if I.On("inv_gain_host") then
            H.GainQ = H.GainQ or {}
            if #H.GainQ < 20 then H.GainQ[#H.GainQ + 1] = { Gn = O.Gn, N = D, T = Now, Src = O.P } end
        end
    end
    -- Runde 9 INV-18 (inv_credit_strict): ein Schuss (SERVER_RequestConsumeItem(1) der Munition) ist kein Verbrauch, der
    -- Rohstoff-/Wasser-Budget rechtfertigt (sonst 2 Gratis-Items je Schuss fuer 20 s)
    if type(O.P) == "string" and O.P:find(K.AMMO_DIR, 1, true) and I.On("inv_credit_strict") then return end
    local B = H.Budget
    if Now - B.T > K.BUDGET_TTL then B.N, B.Any = 0, 0 end
    B.T, B.N = Now, math.min(B.N + 2 * D, 10)
    if I.Match(O.Nm or "", K.BOX) then B.Any = math.min(B.Any + 8 * D, 24) end
end

function I.OnInc(H, P, D, Now)
    -- Zuwachs aus eigenem AddFor (pend/give) ist kein "had": sonst verliert der naechste Platzhalter gleichen Typs
    local Own = H.Own and H.Own[P]
    if Own then
        if Now - Own.T > K.OWN_TTL then
            H.Own[P] = nil
        else
            local Sub = math.min(Own.N, D)
            Own.N, D = Own.N - Sub, D - Sub
            if Own.N <= 0 then H.Own[P] = nil end
        end
    end
    if D <= 0 then return end
    local E = H.Inc[P]
    if not E or Now - E.T > K.INC_TTL then E = { N = 0 } H.Inc[P] = E end
    E.N, E.T = E.N + D, Now
end

-- Ledger eines Gasts: Server-Inventar lesen, mit dem letzten Stand vergleichen, Digest und Signatur-Store
function I.Ledger(G, Key, Pawn, Now)
    local H = I.HState(Key)
    local Comp = Pawn.BP_JigMultiplayer
    if not I.Alive(Comp) then return H end
    if S.ConsNoMoveAny then I.GCompNote(H, Key, Comp, Now) end     -- Closeout R3 (inv_cons_nomove_any, I.MoveHooks)
    local Snap, Sig, Num = I.Scan(Comp)
    local PawnName = I.Name(Pawn)
    if H.Pawn ~= PawnName then
        H.Pawn, H.Snap, H.StoredSig, H.EmptySince, H.PawnAt = PawnName, nil, nil, nil, Now
        H.SeenFull, H.CraftQ = nil, nil          -- Runde 9: neue Figur (INV-3 SeenFull, INV-1 Auftraege der alten Figur)
    end
    local JoinOk = I.JoinCheck(PawnName, Pawn, Snap, Now)
    local Old = H.Snap
    if Old then
        local Decs, DecN = {}, 0
        local Open = I.GuestOpen(Key)
        -- Server-UIDs, die gerade verschwunden sind (Ablegen/Stapeln/Verschieben): pend fuer sie ist kein Platzhalter
        H.Gone = H.Gone or {}
        for U, T in pairs(H.Gone) do if Now - T > 30 then H.Gone[U] = nil end end
        -- Review 1 (inv_rep_strict): Abnahmen je UID (Stueckzahl), Beleg fuer den Filter-Verbrauch (RefillRadFilter @0229)
        local DecOn = I.On("inv_rep_strict")
        if H.Dec then for U, E in pairs(H.Dec) do if Now - E.T > 30 then H.Dec[U] = nil end end end
        local ConsOpen = Open and I.On("inv_cons_open")
        -- Closeout (inv_cons_count): Abnahme-Zaehler je Pfad neben dem Zeitstempel (M.LastConsume 3. Rueckgabe, ls_world
        -- Laptop-Scan: zwei Abnahmen vor der ersten Buchung). Je Verbindung, nie verringert
        local ConsCnt = I.On("inv_cons_count")
        -- Closeout (inv_cons_nodrop): Abwurf auf den Boden (I.DropHook) ist kein Verbrauch. nil = kein frischer Abwurf
        local DropC = I.DropCtx(Comp)
        -- Closeout-Fix (inv_cons_nodrop): Abwurf je UID genau einmal fragen (DropHit loescht S.DropU[Uid]). Abwurf eines
        -- Items mit Unter-Container (Rucksack/Waffe/Magazin, Ct): RemoveGetInfo entfernt dessen Unter-Container im selben
        -- Aufruf (@12f8/@14ee, GetSubContainers rekursiv) -> alles, was in diesem Lauf ganz verschwindet, ist kein Verbrauch
        -- (auch frisch Hineingelegtes: Verschieben + Abwurf im selben Ledger-Takt). Grenze: echter Verbrauch des letzten
        -- Stuecks im selben Takt wie ein Behaelter-Abwurf zaehlt nicht (nur strenger)
        local DropSet, DropAll, DropIn, DropHd = nil, false, 0, nil
        if DropC then
            DropSet = {}
            for Uid, O in pairs(Old) do
                local NewN = Snap[Uid] and Snap[Uid].N or 0
                if NewN < O.N and I.DropHit(DropC, Uid, Now) then
                    DropSet[Uid] = true
                    if O.Ct and not Snap[Uid] then DropAll = true end
                    -- Closeout R2: Halter des abgeworfenen Items merken (ContextRipClothing: Taschen-Inhalt @039d abwerfen,
                    -- danach Verbrauch der Kleidung @057c -> deren Rest-/Budget-Gutschrift bleibt)
                    if O.Hd then DropHd = DropHd or {}; DropHd[O.Hd] = true end
                end
            end
        end
        -- Closeout (inv_rep_proof): Filter-Beleg (H.Dec) nur aus echtem Einzel-Verbrauch. Ausgenommen: Pfade, die in diesem
        -- Lauf gewachsen sind (Teilen/Stapeln/Umlagern mit neuer UID), und Zutaten-UIDs aus Crafting-Auftraegen (M.CraftNote)
        local NoProof = DecOn and I.On("inv_rep_proof") and {} or nil
        if NoProof then
            for U2, E2 in pairs(Snap) do if E2.N > (Old[U2] and Old[U2].N or 0) then NoProof[E2.P] = true end end
            for _, Rc in ipairs(H.CraftQ or {}) do
                for _, U2 in ipairs(type(Rc) == "table" and type(Rc.Uids) == "table" and Rc.Uids or {}) do
                    NoProof[tostring(U2):upper()] = true
                end
            end
        end
        for Uid, O in pairs(Old) do
            if not Snap[Uid] then H.Gone[Uid] = Now end
            local NewN = Snap[Uid] and Snap[Uid].N or 0
            if NewN < O.N then
                local Drop = DropSet ~= nil and (DropSet[Uid] == true or (DropAll and not Snap[Uid]))
                -- Closeout R2 (inv_cons_nodrop): Abwurf, Behaelter-Inhalt und frisch Hineingelegtes sind auch keine Rest-/
                -- Budget-Gutschrift (inv_credit_strict "nicht beim Ablegen"; sonst Lootbox abwerfen = Budget.Any 8).
                -- Ausnahme: Halter abgeworfener Items, der selbst nicht abgeworfen wurde (ContextRipClothing @039d/@057c)
                if not Drop or (DropSet[Uid] ~= true and DropHd ~= nil and DropHd[Uid] == true) then
                    Decs[#Decs + 1], DecN = { O, O.N - NewN }, DecN + O.N - NewN
                end
                -- X20: letzte Abnahme je Item (ohne offene Kiste) fuer M.LastConsume (ls_combat Wurf-Pruefung)
                if Drop then
                    if DropSet[Uid] then
                        if S.MoveU and S.MoveU[Uid] then
                            S.MoveU[Uid] = nil      -- Umlagern in andere Komponente (inv_cons_nomove): ohne Log (haeufig)
                        else
                            Log("Abwurf %s x%d (Gast %s): keine Abnahme fuer LastConsume (inv_cons_nodrop)", tostring(O.Nm),
                                O.N - NewN, tostring(G.PCName or Key))
                        end
                    else
                        DropIn = DropIn + 1
                    end
                elseif not Open then
                    H.Cons = H.Cons or {}
                    H.Cons[O.P] = Now
                    if ConsCnt then
                        H.ConsN = H.ConsN or {}
                        H.ConsN[O.P] = (H.ConsN[O.P] or 0) + (O.N - NewN)
                    end
                elseif ConsOpen and O.N - NewN == 1 then
                    -- Review 1 (inv_cons_open): Einzel-Abnahme bei offener Kiste/Haendler (Laptop-Scan im Kontextmenue
                    -- verbraucht trotzdem, ContextScanLaptop @00ee); nur fuer M.LastConsume(..., true)
                    H.ConsOpen = H.ConsOpen or {}
                    H.ConsOpen[O.P] = Now
                    if ConsCnt then
                        H.ConsOpenN = H.ConsOpenN or {}
                        H.ConsOpenN[O.P] = (H.ConsOpenN[O.P] or 0) + 1
                    end
                end
                -- Closeout-Fix: Abwurf ist kein Filter-Beleg (inv_cons_nodrop); mit inv_rep_proof nur genau 1 Stueck je Lauf
                -- (RefillRadFilter @0229 verbraucht 1; mehr = Umlagern/Teilen/Crafting), nicht bei Wachstum/Crafting-Zutat.
                -- E.P = Pfad, damit I.HostRepair den Typ auch bei aufgebrauchtem Stapel pruefen kann
                if DecOn and not Drop and not (NoProof and (O.N - NewN ~= 1 or NoProof[O.P] or NoProof[Uid])) then
                    H.Dec = H.Dec or {}
                    local E = H.Dec[Uid]
                    if not E or Now - E.T > 15 then E = { N = 0 } H.Dec[Uid] = E end
                    E.T, E.N, E.P = Now, E.N + (O.N - NewN), O.P
                end
            end
        end
        if DropIn > 0 then
            Log("Abwurf eines Behaelters (Gast %s): %d enthaltene Items keine Abnahme fuer LastConsume (inv_cons_nodrop)",
                tostring(G.PCName or Key), DropIn)
        end
        -- Ersatz-Merker ohne lesbare UID gilt fuer genau einen Ledger-Lauf (eine Abwurf-Anfrage = eine UID)
        if DropC and DropC.Used and S.DropAt then S.DropAt[DropC.Ad] = nil end
        -- Verbrauch = 1 Einheit je Ledger-Lauf ohne offene Kiste. Mehr auf einmal bzw. bei offener Kiste ist Umlagern/
        -- Ablegen/Verkauf -> keine Rest-/Budget-Gutschrift (inv_credit_strict aus = altes Verhalten)
        if I.On("inv_credit_split") then
            -- Runde 9 INV-5: je Item statt je Fenster entscheiden. Umlagern/Ablegen bleibt ausgeschlossen (offene Kiste/
            -- Haendler-Sitzung, Menge > 1 desselben Items); Reinigen (PurifyWater @0232 Wasser 1 + @08ae Tabletten n im
            -- selben Bild) und Schiessen in einem Fenster mit anderem Verbrauch zaehlen wieder als Verbrauch
            local Strict = I.On("inv_credit_strict")
            for _, Dc in ipairs(Decs) do
                local Nm = Dc[1].Nm or ""
                local Tab = Nm:find("purif", 1, true) or Nm:find("tablet", 1, true)
                if not Strict or (not Open and (Dc[2] == 1 or Tab)) then I.OnDec(H, Dc[1], Dc[2], Now) end
            end
        elseif not (I.On("inv_credit_strict") and (DecN > 1 or Open)) then
            for _, Dc in ipairs(Decs) do I.OnDec(H, Dc[1], Dc[2], Now) end
        end
        for Uid, E in pairs(Snap) do
            local OldN = Old[Uid] and Old[Uid].N or 0
            if E.N > OldN then I.OnInc(H, E.P, E.N - OldN, Now) end
        end
    end
    -- Runde 9 INV-1/INV-2: Crafting-Auftraege seit dem letzten Lauf (M.CraftNote); Old = Stand vor diesen Auftraegen
    if H.CraftQ and #H.CraftQ > 0 then
        local Q = H.CraftQ
        H.CraftQ = nil
        local Changed = false
        if Old and I.On("inv_craft_guard") then
            local ok, R = I.Try("inv_craft_guard", I.CraftGuard, G, Key, H, Comp, Old, Snap, Q, Now)
            Changed = ok and R == true
        end
        if I.On("inv_craft_cnt") then I.Try("inv_craft_cnt", I.CraftCnt, G, Comp, Q) end
        -- Nachbelastung/Entfernen des Schutzes ist kein Verbrauch des Gasts (sonst Rest-/Budget-Gutschrift im naechsten Lauf)
        if Changed then Snap, Sig, Num = I.Scan(Comp) end
    end
    -- Runde 9 INV-3 (inv_leave_seen): diese Figur hatte nach dem Erst-Sync Items -> spaeteres Leer ist echt
    if Num > 0 and not (H.RestoreAt and not H.Restored) then H.SeenFull = true end
    H.Snap, H.Sig, H.Num, H.LedgerAt = Snap, Sig, Num, Now
    -- Digest an den Gast (nur Aenderungen gehen raus): "u16:n,u16:n,..." sortiert. Runde 9 INV-7 (inv_ui_view): Items in
    -- einem Item-Container (Rucksack/Waffe/Magazin) mit "~" (der Gast erwartet sie nicht in seinen UI-Containern); leeres
    -- Inventar nach SeenFull als "-" (sonst bliebe der alte Digest stehen)
    local UiV = I.On("inv_ui_view")
    if Net.Has("inv2b", G) and (I.On("inv_adopt") or I.On("inv_use")) and (Num > 0 or (UiV and H.SeenFull)) then
        local Parts = {}
        for _, E in pairs(Snap) do Parts[#Parts + 1] = (UiV and E.Nest and "~" or "") .. E.U .. ":" .. E.N end
        table.sort(Parts)
        Net.State("inv_sum", "s", #Parts > 0 and table.concat(Parts, ",") or "-", 3, G)
    end
    -- Signatur-Store: bei Aenderung, hoechstens alle 2 s. Leeres Inventar erst nach K.EMPTY_SECS stabil leer speichern
    -- (direkt nach dem Lade-RPC sind die Listen kurz leer), sonst stellt der alte Save beim Wiederbeitritt alles her.
    if Num > 0 then H.EmptySince = nil elseif not H.EmptySince then H.EmptySince = Now end
    if JoinOk and I.On("inv_store") and Sig ~= H.StoredSig and Now >= H.StoreAt and (Num > 0 or I.EmptyOk(H, Now)) then
        if I.StoreGuest(G, Key, Pawn) then H.StoredSig = Sig end
        H.StoreAt = Now + 2
    end
    return H
end

function I.EmptyOk(H, Now)
    if not (H ~= nil and H.Num == 0 and H.EmptySince ~= nil and I.On("inv_store_empty")) then return false end
    -- Runde 9 INV-3: die 5 s ueberbruecken nur die leeren Listen direkt nach dem Lade-RPC; hatte diese Figur schon
    -- Items (SeenFull), ist das Leer echt -> sofort (sonst ausgeraeumt + binnen 5 s getrennt = alter Save = Duplikat)
    if H.SeenFull == true and I.On("inv_leave_seen") then return true end
    return Now - H.EmptySince >= K.EMPTY_SECS
end

-- X35 Verlassen: leer speichern auch vor K.EMPTY_SECS, wenn der Ledger diese Figur schon leer gesehen hat (Gast noch
-- verbunden) und sie laenger als K.LEAVE_SECS verfolgt (kein kurzes Leer direkt nach dem Lade-RPC)
function I.LeaveEmptyOk(H, Pawn, Now)
    if not (H ~= nil and H.Pawn ~= nil and H.Pawn == I.Name(Pawn) and I.On("inv_store_empty")) then return false end
    if not I.On("inv_leave_seen") then
        return H.Num == 0 and H.EmptySince ~= nil and Now - (H.PawnAt or Now) >= K.LEAVE_SECS
    end
    -- Runde 9 INV-3: frisch zaehlen (H.Num ist bis inv_ledger_ms alt: letztes Item abgelegt + sofort getrennt = Duplikat);
    -- SeenFull statt LEAVE_SECS (Leer nach dem Ausraeumen gilt auch in den ersten 20 s nach Beitritt/Respawn)
    local Jig = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(Jig) then return false end
    local ok, _, _, Num = pcall(I.Scan, Jig)
    return ok and Num == 0 and H.SeenFull == true
end

-- Gast hat gerade eine Kiste offen (inv_open, nur mit inv_lock); Runde 9 (inv_credit_split, INV-26): auch eine
-- Haendler-Sitzung (Verkaufen ist kein Verbrauch)
function I.GuestOpen(Key)
    for _, O in pairs(S.Open) do if O.Key == Key then return true end end
    return S.TrdS[Key] ~= nil and I.On("inv_credit_split")
end

-- main.lua G.Dup (A.Coop.GuestDup[Controller-Key] gesetzt): zweite Verbindung mit derselben Mitspieler-ID ->
-- nichts laden (Hotbar/Waffe) und nichts speichern (Inventar, .bar.txt), sonst ueberschreibt sie den echten Spieler
function I.Dup(Key)
    local D = A and A.Coop and A.Coop.GuestDup
    return Key ~= nil and type(D) == "table" and D[Key] ~= nil
end

-- Leeres Inventar speichern: Save_Player mit den (leeren) Containern, damit G.LoadInto nichts Altes herstellt
-- Rueckgabe nil = jetzt doch nicht leer (normaler Weg), sonst true/false = gespeichert
function I.StoreEmpty(Pawn, Slot)
    if A.Coop.GuestStoreFrozen == true then return false end  -- Runde 9 E22 (CORE-10); Log einmal in I.StoreGuest
    local Jig = Pawn.BP_JigMultiplayer
    if not I.Alive(Jig) then return false end
    local _, _, Num = I.Scan(Jig)
    if Num ~= 0 then return nil end
    local Temp = M.BuildGuestSave(Pawn, true)
    if not Temp then return false end
    return A.UEHelpers.GetGameplayStatics():SaveGameToSlot(Temp, Slot, 0) == true
end

-- Inventar eines Gasts beim Host speichern (G.Store aus main.lua). true = gespeichert.
-- Leaving = true (Trennung): leeres Inventar auch nach I.LeaveEmptyOk speichern
function I.StoreGuest(G, Key, Pawn, Leaving)
    local GI = A.G
    if not GI or A.Settings.local_inventory then return false end
    -- Runde 9 (E22, CORE-10): Server stoppt, Welt + Gast-Inventare sind festgeschrieben -> kein Speichern mehr (sonst
    -- neuere .sav als die gespeicherte Welt)
    if A.Coop.GuestStoreFrozen == true then
        I.WarnOnce("frz" .. tostring(Key), "Inventar von %s nicht gespeichert: Speichern eingefroren (Server stoppt)",
            tostring(Key):match("[^%.]+$") or tostring(Key))
        return false
    end
    if I.Dup(Key) then                                        -- Doppel-Login: nie ueber den Stand des echten Spielers
        I.WarnOnce("dup_st" .. tostring(Key), "Doppel-Login %s: Inventar wird nicht gespeichert", tostring(Key):match("[^%.]+$") or tostring(Key))
        return false
    end
    local GuestId = G.GuestId or (A.Coop.GuestIds and A.Coop.GuestIds[Key])
    if not GuestId or not (GI.Restored and GI.Restored[Key]) then return false end
    local Name = I.Name(Pawn)
    if GI.Dead and GI.Dead[Key] == Name then return false end
    if not I.JoinCheck(Name, Pawn, nil, os.clock()) then
        I.WarnOnce("jb_st" .. tostring(Name), "Inventar von %s nicht gespeichert: Beitritts-Abgleich fehlerhaft, Spielstand bleibt", tostring(GuestId))
        return false
    end
    if (tonumber(I.Safe(function()
        local Med = Pawn.MedicalComponent
        return I.Alive(Med) and Med.Health or nil
    end)) or 0) <= 0 then return false end
    local H = S.H[Key]
    -- direkt nach dem Erst-Sync nicht; Runde 9 INV-3: beim Verlassen schon (JoinCheck oben bestanden), sonst bleibt nach
    -- Ablegen + sofortigem Trennen in den ersten 3 s der alte Save mit den Items stehen
    if H and H.RestoreAt and not H.Restored and not (Leaving and I.On("inv_leave_seen")) then return false end
    if I.EmptyOk(H, os.clock()) or (Leaving and I.LeaveEmptyOk(H, Pawn, os.clock())) then
        -- G.Store/BuildGuestSave speichern nie ein leeres Inventar -> eigener Weg
        local ok, R = pcall(I.StoreEmpty, Pawn, GI.GuestSlot(GuestId))
        if not ok then Core.Fail("inv_store", R) return false end
        if R ~= nil then
            if R then Log("Leeres Inventar von %s gespeichert", tostring(GuestId)) end
            return R == true
        end
    end
    local ok, err = pcall(GI.Store, Pawn, GI.GuestSlot(GuestId), GuestId)
    if not ok then Core.Fail("inv_store", err) return false end
    return true
end

-- inv_join_guard: Summe je Daten-Asset (K = Eintraege, N = Stueckzahl) aus einem I.Scan-Ergebnis
function I.JoinSum(Snap)
    local Sum = {}
    for _, O in pairs(Snap) do
        local P = O.P or "?"
        local E = Sum[P]
        if not E then E = { K = 0, N = 0, Nm = O.Nm or P } Sum[P] = E end
        E.K, E.N = E.K + 1, E.N + (tonumber(O.N) or 0)
    end
    return Sum
end

-- true = Speichern dieser Figur erlaubt. Snap = fertiges I.Scan (Ledger), sonst hier gelesen.
function I.JoinCheck(Name, Pawn, Snap, Now)
    local E = Name and S.JB[Name]
    if not E or not I.On("inv_join_guard") then return true end
    if E.Taint then return false end
    -- Fenster zuerst pruefen: Abnahmen zaehlen nur, solange der Gast noch nicht handeln kann (bis kurz nach der
    -- Freigabe, hoechstens JB_MAX). Spaeter ist eine Abnahme normales Spielen (Essen, Munition, Stapeln, Ablegen).
    local G = Net.Guests[E.Key]
    local RA = G and G.Ready and G.ReadyAt
    local Cut = E.At + K.JB_MAX
    if RA then Cut = math.min(Cut, RA + K.JB_GRACE) end
    if Now > Cut then
        S.JB[Name] = nil
        Log("Beitritts-Schutz fuer %s beendet (%s)", Name, RA and "Gast freigegeben" or "Zeit abgelaufen")
        return true
    end
    if not Snap then
        local Comp = I.Safe(function() return Pawn.BP_JigMultiplayer end)
        if not I.Alive(Comp) then return true end
        local ok, R = pcall(I.Scan, Comp)
        if not ok then return true end
        Snap = R
    end
    local Cur, Lost = I.JoinSum(Snap), {}
    for P, B in pairs(E.Sum) do
        local X = Cur[P]
        if not X or X.K < B.K or X.N < B.N then Lost[#Lost + 1] = tostring(B.Nm) end
    end
    if #Lost > 0 then
        E.Taint = true
        Log("Beitritt %s: %d geladene Gegenstaende fehlen (%s) - vom Gast-UI geloescht, diese Figur wird nicht mehr gespeichert (Spielstand bleibt)",
            Name, #Lost, table.concat(Lost, ",", 1, math.min(#Lost, 8)))
        if G then I.Note(G, "Inventar-Abgleich fehlgeschlagen - bitte neu verbinden") end
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------- Runde 9 Crafting
-- INV-1 (inv_craft_guard, Host): Die Crafting-Widgets schicken CountIndex-mal bzw. bei schnellem Nachklicken dieselben
-- RequestConsume-UIDs (Ubergraph @03c4/@0242; die Gast-UI wird erst mit CLIENT_ItemCraftedResponse aktuell).
-- HandleServerFuncRequestCraft legt das Ergebnis @03f5 VOR dem Verbrauch @0668 an und prueft keine Zutaten -> Items
-- ohne Zutaten. Nachpruefung im Ledger: Verbrauch des Spiels simulieren (@13eb-@164a: Count >= Bedarf ? Count-Bedarf : 0,
-- Bedarf -= Count; Reihenfolge MainJigContainers) ueber den Stand VOR den Auftraegen (Old).

-- E1 (ls_world W.HCraftReq, Hook-Koerper): nur Tabelle. Rec = { Pawn, CompPath, Idx, Uids = { hex32 }, Drop, At }
function M.CraftNote(PawnName, Rec)
    if Net.Side ~= "host" or type(PawnName) ~= "string" or type(Rec) ~= "table" then return end
    for _, H in pairs(S.H) do
        if H.Pawn == PawnName then
            H.CraftQ = H.CraftQ or {}
            if #H.CraftQ < 40 then H.CraftQ[#H.CraftQ + 1] = Rec end
            return
        end
    end
end

-- Rezept eines Auftrags aus CompRef.ItemsToCraft[Idx]: Need = { [Pfad] = n } (verbraucht), All = alle gelisteten
-- Zutaten (auch DoNotConsume-Werkzeuge), Out/OutN = Ergebnis. nil = unlesbar
function I.CraftRecipe(Rec)
    local CR = type(Rec.CompPath) == "string" and I.Safe(function() return StaticFindObject(Rec.CompPath) end) or nil
    local Idx = math.floor(tonumber(Rec.Idx) or -1)
    if not I.Alive(CR) or Idx < 0 then return nil end
    local R
    local ok = pcall(function()
        CR.ItemsToCraft:ForEach(function(N, E)
            if R or N - 1 ~= Idx then return end                -- ForEach zaehlt ab 1, CraftIndex ab 0
            local T = E:get()
            local Need, All = {}, {}
            T[K.CF_NEED]:ForEach(function(_, NE)
                local X = NE:get()
                local D = I.DAInfo(X[F.ID])
                local Cnt = math.floor(tonumber(X[F.COUNT]) or 0)
                if D and D.P ~= "?" then
                    All[D.P] = true
                    if Cnt > 0 and X[K.CF_KEEP] ~= true then Need[D.P] = (Need[D.P] or 0) + Cnt end
                end
            end)
            local Ot = T[K.CF_OUT]
            local OD = I.DAInfo(Ot[F.ID])
            R = { Need = Need, All = All, Out = OD and OD.P or nil, OutN = math.max(1, math.floor(tonumber(Ot[F.COUNT]) or 1)) }
        end)
    end)
    return ok and R or nil
end

-- Simulation: Rueckgabe Liste der Auftraege ohne Zutaten { Rec, R, Rest = { [Pfad] = fehlt } } und die Rezepte.
-- Snap/H/Now (optional, Review 2 inv_craft_fresh): Stand nach den Auftraegen und Host-Zustand fuer frische Stapel
function I.CraftSim(Old, Q, Snap, H, Now)
    local Sim, Bad, Cache, Good = {}, {}, {}, {}
    -- Review 2 (inv_craft_fresh): Stapel, die erst nach Old entstanden (pend/Defer/give per AddFor, Ergebnis eines frueheren
    -- Crafts im selben Lauf), fehlen in Old -> sonst "ohne Zutaten" und Nachbelasten/Entfernen eines echten Crafts.
    -- Pool = ungesehene Menge je Pfad: H.Own nach I.OnInc (im Ledger vor dem Schutz) = AddFor-Menge, die kein Scan zeigt
    -- (ganz verbraucht); dazu die Ergebnisse gedeckter Crafts dieses Laufs (Ketten-Crafting)
    local Fresh, Pool = I.On("inv_craft_fresh") and type(Snap) == "table", {}
    if Fresh and type(H) == "table" and type(H.Own) == "table" and Now then
        for P, O in pairs(H.Own) do
            if (tonumber(O.N) or 0) > 0 and Now - (tonumber(O.T) or -math.huge) <= K.OWN_TTL then Pool[P] = O.N end
        end
    end
    for _, Rec in ipairs(Q) do
        local CK = tostring(Rec.CompPath) .. "#" .. tostring(Rec.Idx)
        local R = Cache[CK]
        if R == nil then R = I.CraftRecipe(Rec) or false Cache[CK] = R end
        local L, Fit, Seen, Unk = {}, R ~= false, {}, {}
        for _, U in ipairs(Fit and type(Rec.Uids) == "table" and Rec.Uids or {}) do
            U = tostring(U):upper()
            local O = Old[U]
            -- gelistete UID mit fremdem Daten-Asset: Rezept/Tabelle passt nicht (Index, Stations-Tabelle) -> nicht werten
            if O and not R.All[O.P] then Fit = false break end
            -- das Spiel prueft je Item in MainJigContainers "in ConsumeUIDs?" -> doppelt gelistete UID zaehlt einmal
            if O and not Seen[U] then Seen[U], L[#L + 1] = true, U end
            -- Review 2 (inv_craft_fresh): gelistete UID erst nach Old entstanden und nach dem Craft noch da -> Vorstand
            -- unbekannt, aber das Spiel nimmt aus einem gelisteten Stapel, bis der Bedarf gedeckt ist: Rest war 0
            local Nw = not O and Fresh and Snap[U] or nil
            if Nw and (tonumber(Nw.N) or 0) > 0 and R.All[Nw.P] then Unk[Nw.P] = true end
        end
        if Fit and next(R.Need) then
            table.sort(L, function(X, Y) return Old[X].O < Old[Y].O end)
            local Rest = {}
            for P, N in pairs(R.Need) do Rest[P] = N end
            for _, U in ipairs(L) do
                local O = Old[U]
                local Need = Rest[O.P]
                -- Review 2: wie das Spiel (Get @00de: nur Rezept-Eintrag mit Count > 0) - ist der Bedarf gedeckt, bleibt
                -- jeder weitere gelistete Stapel unveraendert (sonst wuchs er hier um |Need| = Phantom-Zutaten)
                if Need ~= nil and Need > 0 then
                    local Cnt = Sim[U] or O.N
                    Sim[U] = Cnt >= Need and (Cnt - Need) or 0
                    Rest[O.P] = Need - Cnt
                end
            end
            -- Review 2 (inv_craft_fresh): Zutat aus frischem Stapel gilt als gedeckt (auch fuer CraftCharge), ganz
            -- verbrauchte frische Stapel deckt der Pool (begrenzt auf die ungesehene Menge, ueber alle Auftraege geteilt)
            if next(Unk) then
                for P in pairs(Unk) do if (Rest[P] or 0) > 0 then Rest[P] = 0 end end
                I.WarnOnce("crnew" .. CK, "Crafting-Schutz: frischer Stapel seit letztem Ledger-Lauf bei %s - Zutat nicht gewertet",
                    I.Short(CK))
            end
            if Fresh then
                for P, N in pairs(Rest) do
                    local Av = Pool[P] or 0
                    if N > 0 and Av > 0 then
                        local T = math.min(N, Av)
                        Rest[P], Pool[P] = N - T, Av - T
                    end
                end
            end
            -- nur ganze Crafts: eine Zutat wurde gar nicht verbraucht (Teilverbrauch durch paralleles Aufheben zaehlt nicht).
            -- Review 1 (inv_craft_dupkey): Wiederholung derselben Signatur binnen 3 s (Rec.Dup, I.CraftDupMark) kommt nur
            -- aus veralteter Gast-UI (Mehrfach-Menge/Nachklicken) -> dort zaehlt auch Teilverbrauch
            local Miss = false
            for P, N in pairs(R.Need) do
                if (Rest[P] or 0) >= N or (Rec.Dup and (Rest[P] or 0) > 0) then Miss = true end
            end
            if Miss then
                Bad[#Bad + 1] = { Rec = Rec, R = R, Rest = Rest }
            elseif not Rec.Drop and R.Out then
                Good[R.Out] = (Good[R.Out] or 0) + R.OutN         -- gedeckte Crafts: ihr Ergebnis ist rechtmaessig
                -- Review 2 (inv_craft_fresh): Ergebnis kann ein spaeterer Auftrag dieses Laufs verbrauchen (Ketten-Crafting)
                if Fresh then Pool[R.Out] = (Pool[R.Out] or 0) + R.OutN end
            end
        elseif not Fit and R ~= false then
            I.WarnOnce("crfit" .. CK, "Crafting-Schutz: Rezept %s passt nicht zu den gelisteten Zutaten - nicht gewertet", I.Short(CK))
        end
    end
    return Bad, Good
end

-- Fehlende Zutaten aus anderen Stapeln nachbelasten (true) - nur wenn alles vorhanden ist (sonst Ergebnis entfernen)
function I.CraftCharge(Comp, Snap, Rest, Used)
    local Plan = {}
    for P, Miss in pairs(Rest) do
        if Miss > 0 then
            local Left = Miss
            for U, E in pairs(Snap) do
                if Left <= 0 then break end
                local Av = E.P == P and E.N - (Used[U] or 0) or 0
                if Av > 0 then
                    local Take = math.min(Av, Left)
                    Plan[#Plan + 1] = { U = U, N = Take }
                    Left = Left - Take
                end
            end
            if Left > 0 then return false end
        end
    end
    for _, X in ipairs(Plan) do
        local It = I.FindItem(Comp, X.U)
        -- CallbackToPlayer? false: JigMP_OnItemConsumed ruft sonst ConsumeItem (Essen/Trinken-Wirkung)
        if not (It and pcall(function() Comp:HandleLocalRequestConsumeItem(It[F.UID], X.N, Comp, "", false) end)) then return false end
        Used[X.U] = (Used[X.U] or 0) + X.N
    end
    return true
end

-- Ergebnis eines Crafts ohne Zutaten wieder entfernen: neuester Zuwachs des Ergebnis-Assets seit Old
function I.CraftUndo(Comp, Old, Snap, R, Used)
    local Best, BestO
    for U, E in pairs(Snap) do
        local Gain = E.N - (Old[U] and Old[U].N or 0) - (Used[U] or 0)
        if E.P == R.Out and Gain >= R.OutN and (not BestO or E.O > BestO) then Best, BestO = U, E.O end
    end
    local It = Best and I.FindItem(Comp, Best)
    if not (It and pcall(function() Comp:HandleLocalRequestConsumeItem(It[F.UID], R.OutN, Comp, "", false) end)) then return false end
    Used[Best] = (Used[Best] or 0) + R.OutN
    return true
end

-- Review 1 (inv_craft_dupkey, Host): Signatur je Auftrag (CompPath#Idx#Drop#sortierte UIDs) ueber Ledger-Laeufe hinweg
-- merken (H.CraftKeys, 3 s). Gleiche Signatur binnen 3 s = Rec.Dup (Doppelklick kann in zwei 0,5-s-Laeufe fallen)
function I.CraftDupMark(H, Q, Now)
    local Keys = H.CraftKeys or {}
    H.CraftKeys = Keys
    local N = 0
    for Sig, T in pairs(Keys) do
        if Now - T > 10 then Keys[Sig] = nil else N = N + 1 end
    end
    for _, Rec in ipairs(Q) do
        if type(Rec.Uids) == "table" and #Rec.Uids > 0 then
            local L = {}
            for _, U in ipairs(Rec.Uids) do L[#L + 1] = tostring(U):upper() end
            table.sort(L)
            local Sig = tostring(Rec.CompPath) .. "#" .. tostring(Rec.Idx) .. "#" .. (Rec.Drop and 1 or 0) .. "#" .. table.concat(L, ",")
            local At = tonumber(Rec.At) or Now
            local Prev = Keys[Sig]
            if Prev and At - Prev >= 0 and At - Prev <= 3 then Rec.Dup = true end
            if Prev == nil then N = N + 1 end
            if Prev == nil and N > 64 then
                N = N - 1                                 -- Deckel: neue Signaturen nicht mehr merken
            else
                Keys[Sig] = At
            end
        end
    end
end

-- Rueckgabe true = Inventar geaendert (Ledger liest neu)
function I.CraftGuard(G, Key, H, Comp, Old, Snap, Q, Now)
    if I.On("inv_craft_dupkey") then I.CraftDupMark(H, Q, Now) end
    local Bad, Good = I.CraftSim(Old, Q, Snap, H, Now)
    if #Bad == 0 then return false end
    local Who = tostring(G.PCName or Key)
    -- wirklich entstanden? Zuwachs des Ergebnisses ueber das der gedeckten Crafts hinaus (sonst scheiterte
    -- AddNewItemToSlot @0450 und nichts kam dazu)
    local Gain = {}
    for U, E in pairs(Snap) do
        local D = E.N - (Old[U] and Old[U].N or 0)
        if D > 0 then Gain[E.P] = (Gain[E.P] or 0) + D end
    end
    for P, N in pairs(Good) do Gain[P] = (Gain[P] or 0) - N end
    local Real = {}
    for _, B in ipairs(Bad) do
        local Out = B.R.Out
        if B.Rec.Drop or (Out and (Gain[Out] or 0) >= B.R.OutN) then
            if not B.Rec.Drop then Gain[Out] = Gain[Out] - B.R.OutN end
            Real[#Real + 1] = B
        end
    end
    if #Real == 0 then return false end
    -- erst ab 2 ungedeckten Crafts in 60 s handeln (ein Mehrfach-Auftrag zaehlt je Craft); einzelner = nur Log
    H.CraftBad = H.CraftBad or {}
    local Keep = {}
    for _, T in ipairs(H.CraftBad) do if Now - T <= 60 then Keep[#Keep + 1] = T end end
    for _ = 1, #Real do Keep[#Keep + 1] = Now end
    while #Keep > 40 do table.remove(Keep, 1) end
    H.CraftBad = Keep
    local Out = I.Short(Real[1].R.Out)
    -- Review 1 (inv_craft_dupkey): ein wiederholter Auftrag (Rec.Dup) ist eindeutig -> sofort handeln, ohne 2-in-60-s
    local Dup = false
    for _, B in ipairs(Real) do if B.Rec.Dup then Dup = true break end end
    if #Keep < 2 and not Dup then
        Log("Crafting-Schutz (nur Log): %s %dx %s ohne Zutaten", Who, #Real, Out)
        return false
    end
    Net.SecWarn(G, Key, "inv_craft_free")
    local Used, Charged, Removed, Left = {}, 0, 0, 0
    local Pawn = I.HostPawn(G)
    -- Review 2: die Pickup-Liste (I.PickList, geteilt, bis 2 s alt) kennt ein abgelegtes Craft-Ergebnis nicht, wenn sie vor
    -- dem Auftrag gebaut wurde (Spawn synchron im RPC nach dem Pre-Hook, Rec.At). Dann einmal neu aufbauen lassen; beide
    -- Zeiten sind os.clock(). Der naechste I.GroundTake baut neu, weitere in diesem Lauf nutzen die frische Liste
    for _, B in ipairs(Real) do
        if B.Rec.Drop and (S.PickAt or -math.huge) <= (tonumber(B.Rec.At) or math.huge) then S.PickAt = -math.huge break end
    end
    for _, B in ipairs(Real) do
        if I.CraftCharge(Comp, Snap, B.Rest, Used) then
            Charged = Charged + 1
        elseif not B.Rec.Drop and I.CraftUndo(Comp, Old, Snap, B.R, Used) then
            Removed = Removed + 1
        elseif B.Rec.Drop and B.R.Out and Pawn and I.GroundTake(Pawn, B.R.Out, B.R.OutN) then
            Removed = Removed + 1
        else
            Left = Left + 1
        end
    end
    Log("Crafting-Schutz: %s %dx %s ohne Zutaten - %d nachbelastet, %d entfernt%s", Who, #Real, Out, Charged, Removed,
        Left > 0 and string.format(", %d nicht korrigierbar", Left) or "")
    I.Audit(G, Key, Real[1].R.Out, #Real, string.format("craftguard (%d nachbelastet, %d entfernt, %d offen)", Charged, Removed, Left))
    return Charged + Removed > 0
end

-- INV-2 (inv_craft_cnt, Host): Crafting mit vollem Inventar (SERVER_RequestCraftItemDrop) meldet dem Gast den Verbrauch nie
-- (HandleServerFuncRequestCraftDrop @0956 ClientUpdateCount ohne Net-Flag) -> Geister-Zutaten in der Gast-UI erlauben
-- weitere Gratis-Crafts. Neue Stueckzahlen der gelisteten UIDs an den Gast (inv_cnt, dort lokal ClientUpdateCount)
function I.CraftCnt(G, Comp, Q)
    if not Net.Has("invcnt", G) then return end
    local Parts, Seen, Cur = {}, {}, nil
    for _, Rec in ipairs(Q) do
        if Rec.Drop and type(Rec.Uids) == "table" then
            Cur = Cur or I.Scan(Comp)
            for _, U in ipairs(Rec.Uids) do
                U = tostring(U):upper()
                if #U == 32 and U:match("^%x+$") and not Seen[U] and #Parts < 16 then
                    Seen[U] = true
                    Parts[#Parts + 1] = U .. ":" .. (Cur[U] and Cur[U].N or 0)
                end
            end
        end
    end
    if #Parts == 0 then return end
    Net.Send("inv_cnt", table.concat(Parts, ";"), G, 1)
    Log("%s: Crafting mit vollem Inventar - %d Zutaten-Stapel an den Gast gemeldet", tostring(G.PCName or G.Key), #Parts)
end

-- Antwort-Entscheidung fuer eine pend-Anfrage. Rueckgabe Antworttext oder nil (= noch warten).
function I.Decide(G, H, J, Pawn, Now, Final)
    -- UID kennt der Server (im Inventar oder gerade entfernt): laufende Spiel-Anfrage (Ablegen/Teilen/Stapeln/
    -- Verschieben legen echte Items in PendingRequests), kein Gast-Platzhalter -> nichts anlegen, nichts entfernen
    if (H.Snap and H.Snap[J.Uid]) or (H.Gone and H.Gone[J.Uid] and Now - H.Gone[J.Uid] <= 30) then
        return "keep|srv"
    end
    -- Closeout R4 (inv_trunk_keep, handoff_closeout_car §1): UID liegt in einem Kofferraum <= 1000 uu um die Server-Figur
    -- -> echtes Server-Item. Fall: Gast zieht im ~1-RTT-Fenster nach der Kofferraum-Sperre (DLL verwirft das RPC still,
    -- car_denyui schliesst das Fenster erst danach) ein Item heraus; ohne diese Regel schrieb (c)/(d) es gut, der
    -- Kofferraum behielt das Original (Dupe). Gast-Platzhalter haben eigene UIDs, liegen also nie in einem Kofferraum
    if I.On("inv_trunk_keep") and I.TrunkUids(H, Pawn, Now)[tostring(J.Uid):upper()] then
        Log("inv_pend %s: %s liegt in einem Kofferraum beim Server - keine Gutschrift (inv_trunk_keep)",
            tostring(G.PCName or G.Key), I.Short(J.Path))
        return "keep|srv"
    end
    local Asset = I.ItemAsset(J.Path, true)                    -- Gast-Pfad (CORE-14)
    if not Asset then return "no|asset" end
    local D = I.DAInfo(Asset)
    local P, Nm, N = D.P, D.Nm, J.N
    -- (a) Server hat so ein Item selbst bekommen, seit der Platzhalter entstand -> nur Platzhalter weg
    local Inc = H.Inc[P]
    if Inc and Inc.N > 0 and Inc.T >= Now - J.Age - 1 and Now - Inc.T <= K.INC_TTL then
        Inc.N = Inc.N - math.min(Inc.N, N)
        return "had"
    end
    -- (a2) Cheat-Platzhalter: Item kam schon per Admin-give (CLIENT_AddNewItem) -> nur Platzhalter weg (sonst (e) Admin = Doppel)
    local Gc = H.GiveCr and H.GiveCr[P]
    -- nur Platzhalter, die beim give schon bestanden (Cheat-Klick kommt immer vor dem give des Hosts); spaetere echte
    -- Platzhalter gleichen Typs (Ernte, Angeln ...) laufen durch die normalen Pruefungen
    if Gc and Gc.N > 0 and J.Why == "p" and Now - Gc.T <= K.GIVE_TTL
        and (J.T0 or Now) - (J.Age or 0) <= Gc.T + 1 and I.On("inv_givecr") then
        Gc.N = Gc.N - math.min(Gc.N, N)
        Log("%s: Cheat-Platzhalter %s per give schon geliefert - nur Platzhalter entfernt", tostring(G.PCName or G.Key), I.Short(P))
        return "had"
    end
    local Why
    local Cr = H.Credit[P]
    if Cr and Cr.N > 0 and Now - Cr.T <= K.CREDIT_TTL then                               -- (b) Rest-Item
        N = math.min(N, Cr.N) Cr.N = Cr.N - N Why = "Rest"
    end
    -- (f)/(g) vor Admin/Budget/Ernte: eine vorhandene Server-Quelle wird zuerst belastet (sonst bleibt sie lootbar)
    if not Why and J.Why == "p" and I.On("inv_ground") then                              -- (f) Boden
        local Got, Bag = I.GroundTake(Pawn, P, N)
        if Bag == "bag" then
            I.Note(G, "Items inside Backpack")                -- Text wie CheckBackpack @013a
            Log("%s: Rucksack %s mit Inhalt nicht aufgehoben (Difficulty.DisableBackpackInBackpack)",
                tostring(G.PCName or G.Key), I.Short(P))
            return "no|rucksack"
        end
        if Got then N, Why = Got, "Boden" end
    end
    -- (g) seit inv_lootprime (Loot All serverbestaetigt) standardmaessig aus; inv_carcass=1 = alter Rueckfall
    if not Why and I.OnOff("inv_carcass") then                                            -- (g) Leiche
        local Got = I.CarcassTake(H, Pawn, P, N, Now)
        if Got then N, Why = Got, "Leiche" end
    end
    if Why then
        -- schon entschieden
    elseif I.OnOff("inv_admin_free") and I.IsAdmin(G) then                               -- (e) Admin
        -- Runde 9 INV-11: Standard aus (Cheat-Items kommen ueber inv_give + GiveCredit); sonst entstanden fuer Passwort-
        -- Admins Teilungs-/Reinigungs-/Angel-Platzhalter ohne Pruefung (Dupe, verdeckt Gutschrift-Fehler im Test)
        Why = "Admin"
    elseif Now - H.Budget.T <= K.BUDGET_TTL and (H.Budget.Any > 0
        or (H.Budget.N > 0 and (J.Why == "p" or I.Match(Nm, K.ADOPT)) and I.BudgetOk(P))) then
        -- (c) Verbrauchs-Budget nur fuer Rohstoffe/Wasser/Lappen (K.BUDGET_DIRS); lokal-only ohne Pending nur fuer
        -- Wasser/Stoff; beliebige Items nur nach einer echten Lootbox (Budget.Any)
        local UseN = (J.Why == "p" or I.Match(Nm, K.ADOPT)) and I.BudgetOk(P) and H.Budget.N >= 1
        N = math.min(N, UseN and H.Budget.N or H.Budget.Any)
        if UseN then H.Budget.N = H.Budget.N - N else H.Budget.Any = math.max(0, H.Budget.Any - N) end
        Why = "Budget"
    elseif J.Why == "p" and I.FreeItem(Nm, P) then                                        -- (d) Ernte/Angeln
        -- Runde 9 INV-10 (inv_fish_proof, nur mit A.Coop.World.FishProof): Rohfisch nur nach einem Fang beim Host
        -- (Svr_CatchFish -> M.FishNote), hoechstens 1 Fisch je Fang; die Host-Simulation fischt nicht mehr mit
        local Fish = I.FishProof() and I.IsFish(Nm, P)
        if Fish and not (H.FishAt and Now - H.FishAt <= 10 + math.min(J.Age or 0, 10) and (H.FishN or 0) > 0) then
            if not Final then return nil end
            Log("inv_pend %s: Rohfisch %s ohne Fang beim Host - abgelehnt", tostring(G.PCName or G.Key), I.Short(P))
            return "no|fisch"
        end
        -- Runde 9 INV-18 (inv_free_credit): Ernte ist vom Gast behauptet. 0 (Standard) = jede Gutschrift protokollieren,
        -- 1 = nur mit Host-Nachweis (Fang ueber FishProof), sonst warten (Erzeuger-Gutschrift M.Credit -> Regel b) und
        -- zuletzt "no|ernte". Erst einschalten, wenn die Erzeuger (Relay-Ertrag, Fleisch) per M.Credit gutschreiben
        local Enf = I.OnOff("inv_free_credit")
        if Enf and not Fish then
            if not Final then return nil end
            Log("inv_pend %s: %dx %s Ernte ohne Host-Nachweis - abgelehnt (inv_free_credit)", tostring(G.PCName or G.Key), N, I.Short(P))
            return "no|ernte"
        end
        if I.FreeOk(H, N, Now) then
            if Fish then H.FishN, N = H.FishN - 1, 1 end
            Why = "Ernte"
            Log("Ernte-Gutschrift%s: %s %dx %s", Enf and " (Fang)" or " (nur Log)", tostring(G.PCName or G.Key), N, I.Short(P))
        end
    end
    if not Why then
        if Final then
            if J.Why == "p" and not I.FreeItem(Nm, P) then
                Log("inv_pend %s: %s nicht auf der Ernte-/Budget-Liste - abgelehnt", tostring(G.PCName or G.Key), I.Short(P))
            end
            return "no|keine"
        end
        return nil
    end
    N = math.max(1, math.min(N, 50))
    if I.On("inv_pend_defer") then
        -- erst "ok" (Gast: RemoveRequestByUID gibt den Slot frei), dann anlegen: sonst landet CLIENT_AddNewItem auf dem
        -- Platzhalter-Slot (HandleAddNewItem @0108 ohne Stapeln -> AddNewItem IsEmptySlot) -> Item beim Gast unsichtbar
        -- inv_pend_ack: Anlage erst auf die Quittung des Gastes (inv_pfree nach RemoveRequestByUID), nicht nach fester Zeit;
        -- ohne Quittung nach inv_pend_ack_ms (Rueckfall). Gast ohne Faehigkeit invpf: alte feste Wartezeit
        local Ack = I.On("inv_pend_ack") and Net.Has("invpf", G)
        local Ms = Ack and (tonumber(Core.Flag("inv_pend_ack_ms", 3000)) or 3000)
            or (tonumber(Core.Flag("inv_pend_defer_ms", 1000)) or 1000)
        H.Defer = H.Defer or {}
        H.Defer[#H.Defer + 1] = { P = P, N = N, Why = Why, Until = Now + 15, Uid = J.Uid, Ack = Ack,
            At = Now + math.max(0.5, Ms / 1000) }
        return "ok|"
    end
    local R = I.AddFor(Pawn, Asset, N, H)
    Log("%s: %dx %s angelegt (%s, %s)", tostring(G.PCName or G.Key), N, I.Short(P), Why, R)
    if R ~= "fehler" then I.Audit(G, G.Key, P, N, I.Rule(Why)) end                       -- Runde 9 X-INV1
    return R == "fehler" and "no|fehler" or R
end

-- Closeout R4 (inv_trunk_keep): UIDs (Strings) in Kofferraeumen <= 1000 uu um die Server-Figur des Gasts, je Gast
-- hoechstens 1x/s neu (I.Decide laeuft alle 0,1 s je Anfrage). Autoliste aus main.lua Coop.Car.Vehicles (FindAllOf
-- hoechstens 1x/s), jedes Auto mit IsAlive geprueft, keine UObjects ueber Ticks; hoechstens 4 nahe Autos je Lauf.
-- Fehler -> Core.Fail("inv_trunk_keep") und leere Menge (nicht inv_pend abschalten)
function I.TrunkUids(H, Pawn, Now)
    if H.TkU and Now - (H.TkAt or -math.huge) < 1 then return H.TkU end
    local Set = {}
    H.TkAt, H.TkU = Now, Set
    local L = I.Alive(Pawn) and I.Loc(Pawn)
    local Car = A.Coop and A.Coop.Car
    if not L or type(Car) ~= "table" or type(Car.Vehicles) ~= "function" then return Set end
    local ok, err = pcall(function()
        local List, Near = Car.Vehicles(), 0
        for _, V in ipairs(type(List) == "table" and List or {}) do
            if Near >= 4 then break end
            local Vl = I.Alive(V) and I.Loc(V)
            if Vl and I.Dist2(Vl, L.X, L.Y, L.Z) <= 1000 * 1000 then
                Near = Near + 1
                local Tj = I.Safe(function() return V.BP_JigMultiplayer end)
                if I.Alive(Tj) then
                    Tj.MainJigContainers:ForEach(function(_, CE)
                        CE:get()[F.ITEMS]:ForEach(function(_, IE)
                            local U = I.Hex(IE:get()[F.UID])
                            if U and U ~= K.ZERO then Set[U] = true end
                        end)
                    end)
                end
            end
        end
    end)
    if not ok then Core.Fail("inv_trunk_keep", err) end
    return Set
end

-- Runde 9 INV-10: Fang-Nachweis aktiv (ls_world setzt E4 A.Coop.World.FishProof, wenn die Host-Simulation unterdrueckt
-- und Svr_CatchFish gebucht wird)
function I.FishProof()
    local W = A.Coop and A.Coop.World
    return I.On("inv_fish_proof") and type(W) == "table" and W.FishProof == true
end

function I.IsFish(Nm, P)
    if K.FREE[Nm] and Nm:find("fish", 1, true) then return true end
    return type(P) == "string" and P:find("/Hunger/Fish/Raw/", 1, true) ~= nil
end

-- E3 (ls_world, Host): Gast hat einen Fang gebucht (Svr_CatchFish) -> ein Rohfisch-Platzhalter darf "Ernte" werden
function M.FishNote(Key)
    if Net.Side ~= "host" or Key == nil then return end
    local H, Now = I.HState(Key), os.clock()
    if not H.FishAt or Now - H.FishAt > 20 then H.FishN = 0 end
    H.FishAt, H.FishN = Now, math.min((H.FishN or 0) + 1, 3)
end

-- (d) Ernte/Angeln: exakter Kurzname (K.FREE) oder Rohfisch-Ordner (UE 5.6, K.FREE_DIRS)
function I.FreeItem(Nm, P)
    if K.FREE[Nm] then return true end
    if type(P) ~= "string" then return false end
    for _, Dir in ipairs(K.FREE_DIRS) do if P:find(Dir, 1, true) then return true end end
    return false
end

-- UE 5.6: Jig-Komponente ist BP_JigComponent_C, AddNewItemSomewhere hat 10 Parameter (neu 6.: SpecificContainer FName,
-- 'None' = beliebiger Container, AddNewItemSomewhere @0acd). 5.3 (BP_JigMultiplayer_C): 9 Parameter. Je Klassenname gecacht.
function I.Jig53(Comp)
    local Cls = I.Safe(function() return Comp:GetClass() end)
    local CN = Cls and I.Name(Cls)
    if not CN then return false end
    S.JigCls = S.JigCls or {}
    if S.JigCls[CN] == nil then S.JigCls[CN] = CN == "BP_JigMultiplayer_C" end
    return S.JigCls[CN]
end

-- Item beim Host fuer die Gast-Figur anlegen (Variante A: AddNewItemSomewhere -> CLIENT_AddNewItem an den Gast)
-- H (optional): Zuwachs als eigen vormerken (I.OnInc zaehlt ihn nicht als "had").
-- Gestapelt liefert das Spiel ItemUID = 0 (AddNewItemSomewhere @095a, 5.3 und 5.6) -> "ok|" ohne UID.
function I.AddFor(Pawn, Asset, N, H)
    local Comp = Pawn.BP_JigMultiplayer
    if not I.Alive(Comp) then return "fehler" end
    local AddedT, DroppedT, UidT, ToT = {}, {}, {}, {}
    local Old = I.Jig53(Comp)
    local ok, err = pcall(function()
        if Old then
            Comp:AddNewItemSomewhere(Asset, N, nil, 0, true, AddedT, DroppedT, UidT, ToT)
        else
            Comp:AddNewItemSomewhere(Asset, N, nil, 0, true, FName("None"), AddedT, DroppedT, UidT, ToT)
        end
    end)
    if not ok then Core.Fail("inv_pend", err) return "fehler" end
    if I.Out(DroppedT, "Dropped?") == true then return "drop" end
    if I.Out(AddedT, "Added") == false then return "fehler" end    -- weder angelegt noch abgelegt
    if H then
        local D, Now = I.DAInfo(Asset), os.clock()
        H.Own = H.Own or {}
        if D then
            local O = H.Own[D.P]
            if not O or Now - O.T > K.OWN_TTL then O = { N = 0 } H.Own[D.P] = O end
            O.N, O.T = O.N + N, Now
        end
    end
    local U = I.Out(UidT, "ItemUID")
    local Hex = U ~= nil and type(U) ~= "boolean" and type(U) ~= "number" and I.Hex(U) or nil
    if Hex == K.ZERO then Hex = nil end
    return "ok|" .. (Hex or "")
end

-- X28: Admin fuer Gratis-Anlage (e) nicht allein ueber die Mitspieler-ID (h4/hello/guestid meldet der Gast selbst).
-- Coop.SteamIds ist ebenfalls vom Spieler gemeldet (hb, ungeprueft) und taugt nicht als Nachweis. Darum zusaetzlich das
-- Server-Passwort wie bei Admin-Befehlen (server.lua RunAdminCommand): ohne Passwort-Konfiguration kein (e).
function I.IsAdmin(G)
    local Srv = A.Coop.Server
    local Id = G.GuestId and tostring(G.GuestId):lower()
    if type(Srv) ~= "table" or Id == nil then return false end
    -- Runde 8: Doppel-Login (kopierte ID-Datei) nie Admin; Richtlinie wie server.lua Srv.IsAdmin
    local Dup = A.Coop.GuestDup ~= nil and A.Coop.GuestDup[G.Key] ~= nil
    local Base
    if type(Srv.IsAdmin) == "function" then
        -- Closeout: Verbindungs-Schluessel + Steam-ID mitgeben (Srv.IsAdmin braucht Key fuer LASTSIGNAL_ADMIN_PASSWORD,
        -- Steam-ID fuer "steam:"-Admins; ohne SteamId nimmt server.lua A.Coop.SteamIds[Key])
        Base = I.Safe(function() return Srv.IsAdmin({ GuestId = Id, Dup = Dup, Key = G.Key, SteamId = G.SteamId }) end) == true
    else
        Base = not Dup and type(Srv.Admins) == "table" and Srv.Admins[Id] == true
    end
    if not Base then return false end
    local Pw = type(Srv.Cfg) == "table" and Srv.Cfg.Password
    local Auth = type(Srv.Auth) == "table" and G.Key and Srv.Auth[G.Key]
    if Pw and type(Auth) == "table" and Auth.Ok == true then return true end
    I.WarnOnce("adm" .. tostring(G.Key), "Admin %s: Gratis-Anlage aus (nur mit Server-Passwort und /pw)",
        tostring(G.PCName or G.Key))
    return false
end

-- Daten-Asset-Pfad in einem der Budget-Ordner (K.BUDGET_DIRS)?
function I.BudgetOk(P)
    if type(P) ~= "string" then return false end
    for _, Dir in ipairs(K.BUDGET_DIRS) do if P:find(Dir, 1, true) then return true end end
    return false
end

function I.FreeOk(H, N, Now)
    local W, Max = H.Free, tonumber(Core.Flag("inv_free_per_min", 30)) or 30
    if Now - W.Since >= 60 then W.Since, W.N = Now, 0 end
    if W.N + N > Max then return false end
    W.N = W.N + N
    return true
end

-- Spiel-CVar ueber ConsoleUtils (wie die BPs): T "b" = GetBoolCVar, sonst GetFloatCVar. nil = unlesbar
function I.CVar(T, Name)
    local CU = I.Safe(function() return StaticFindObject(K.CU) end)
    if not I.Alive(CU) then return nil end
    return I.Safe(function()
        if T == "b" then return CU:GetBoolCVar(FName(Name)) end
        return CU:GetFloatCVar(FName(Name))
    end)
end

-- Hinweis an einen Gast: ls_ui note2 (Proxy-Weg), sonst inv_note
function I.Note(G, Text)
    if not (G and G.Epoch) then return end
    local Ui = A.Coop.Modules and A.Coop.Modules.ls_ui
    if Ui and type(Ui.Note) == "function" and Net.Has("ui_note2", G) and pcall(Ui.Note, G, Text, "", true) then return end
    if Net.Has("inv2b", G) then Net.Send("inv_note", Text, G, 1) end
end

-- inv_bpbag: BP_StaticMeshPickup_C.CheckBackpack @0000-@01fc (5.6) - mit Difficulty.DisableBackpackInBackpack ist ein Rucksack
-- (Typ Jig.ItemType.Backpack) mit eigenem Inhalt (GetContainerItems(false) > 0) im Einzelspiel nicht aufhebbar.
-- Beim Gast laeuft die Pruefung auf der leeren lokalen Kopie (Inhalt nicht repliziert) -> Host prueft vor der Belastung
function I.BagFull(O, Comp)
    if not I.On("inv_bpbag") or I.CVar("b", "Difficulty.DisableBackpackInBackpack") ~= true then return false end
    -- UE 5.6: JigsawItem_DataAsset_C.Type heisst ItemType (CheckBackpack @002f); 5.3-Name als Rueckfall
    local Tag = I.Safe(function() return Comp.ItemDataAsset.ItemType.TagName:ToString() end)
        or I.Safe(function() return Comp.ItemDataAsset.Type.TagName:ToString() end)
    if Tag ~= "Jig.ItemType.Backpack" then return false end
    local PJ = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(PJ) then return false end
    local T, N = {}, nil
    if pcall(function() PJ:GetContainerItems(false, T) end) then
        local V = I.Out(T, "AllItems")
        if type(V) == "table" then N = #V elseif V ~= nil then N = I.Safe(function() return V:GetArrayNum() end) end
    end
    if N == nil then
        local ok, _, _, Num = pcall(I.Scan, PJ)
        N = ok and Num or 0
    end
    return (tonumber(N) or 0) > 0
end

-- Boden-Gutschrift: Server-Pickup gleichen Typs <= 4 m um den Gast wird belastet (der Gast hat ihn aufgehoben).
-- Rueckgabe: gutzuschreibende Menge (Menge des Pickups, hoechstens N bei Teil-Entnahme per SetCount) oder false
-- (zweiter Wert "bag": Rucksack mit Inhalt, inv_bpbag).
-- Runde 9 CORE-31: Pickup-Liste mit Lagen (Pfade, keine UObjects), hoechstens alle 2 s neu aufgebaut
function I.PickList(Now)
    if S.Pick and Now - S.PickAt <= 2 then return S.Pick end
    S.PickAt, S.Pick = Now, {}
    for _, Cls in ipairs(K.PICKUP_CLASSES) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if #S.Pick >= 5000 then break end
            local Full = I.Alive(O) and I.Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end)
            local Pl = Full and I.Loc(O)
            if Pl then S.Pick[#S.Pick + 1] = { F = Full, X = Pl.X, Y = Pl.Y, Z = Pl.Z } end
        end
    end
    return S.Pick
end

-- Runde 9 CORE-31: vorher lief je pend-Anfrage und 0,1-s-Takt bis 6 s lang StaticFindObject + Lage fuer jeden Pickup der
-- Karte. Jetzt teilen sich alle Anfragen die Liste (I.PickList, Lagen mit drin, hoechstens alle 2 s neu wie bisher); frisch
-- aufgeloest werden nur Eintraege, deren gemerkte Lage <= 6 m von der Figur liegt (danach wie bisher frische Lage <= 4 m)
function I.GroundTake(Pawn, P, N)
    local L = I.Loc(Pawn)
    if not L then return false end
    local List = I.PickList(os.clock())
    local Bag = nil
    for _, E in ipairs(List) do
        local O = not E.Gone and I.Dist2(L, E.X, E.Y, E.Z) <= 600 * 600 and I.Safe(function() return StaticFindObject(E.F) end) or nil
        local Pl = I.Alive(O) and I.Loc(O)
        if Pl and I.Dist2(L, Pl.X, Pl.Y, Pl.Z) <= 400 * 400 then
            local Comp = I.Safe(function() return O.BP_JigPickupComponent end)
            local D = I.Alive(Comp) and I.DAInfo(I.Safe(function() return Comp.ItemDataAsset end))
            -- volle Rucksaecke (inv_bpbag) ueberspringen: ein leerer gleichen Typs daneben ist dann der aufgehobene
            if D and D.P == P and I.BagFull(O, Comp) then
                Bag = "bag"
            elseif D and D.P == P then
                local CntT = {}
                local Cnt = pcall(function() Comp:GetCount(CntT) end) and math.floor(tonumber(I.Out(CntT, "Count")) or 0) or 0
                if Cnt < 1 then Cnt = 1 end
                if Cnt > N and pcall(function() Comp:SetCount(Cnt - N) end) then return N end
                pcall(function() O:K2_DestroyActor() end)
                E.Gone = true                                 -- Liste ist geteilt (alle Anfragen bis zum Neuaufbau)
                return Cnt
            end
        end
    end
    return false, Bag
end

-- Leichen-Familie eines Actors (K.CARC_ROOTS, Hochlaufen der Klassenkette, Cache je Klassenname).
-- Rueckgabe: "a"/"z"/"h", false (keine Leiche, z. B. Spieler) oder nil (unlesbar); dazu der Klassenname.
function I.CarcFam(O)
    local Cls = I.Safe(function() return O:GetClass() end)
    local CN = Cls and I.Name(Cls)
    if not CN then return nil end
    local Hit = S.CarcFam[CN]
    if Hit ~= nil then return Hit, CN end
    local Fam, Sc = false, Cls
    for _ = 1, 16 do
        local SN = I.Name(Sc)
        if not SN then break end
        if K.CARC_ROOTS[SN] ~= nil then Fam = K.CARC_ROOTS[SN] break end
        Sc = I.Safe(function() return Sc:GetSuperStruct() end)
        if not I.Alive(Sc) then break end
    end
    S.CarcFam[CN] = Fam
    return Fam, CN
end

-- Server-Kopie wirklich tot? (Felder wie ls_ai H.Read)
function I.CarcDead(O, Fam)
    if Fam == "h" then
        return I.Safe(function()
            local AI = O.BP_AIComponent
            return I.Alive(AI) and AI.Dead or nil
        end) == true
    end
    if I.Safe(function() return O["IsDead?"] end) == true then return true end
    -- Zombie-JigCanInteract prueft self.Dead (Server-Bedingung fuer SERVER_RequestData)
    return Fam == "z" and I.Safe(function() return O.Dead end) == true
end

-- Leichen-Gutschrift: Inhalt der vom Gast gemeldeten Tier-/KI-Leiche (Server-Kopie) wird entnommen.
-- Rueckgabe: tatsaechlich entnommene Menge (nachgezaehlt; HandleLocalRequestConsumeItem ist bei fehlendem
-- MPComponentType ein stiller No-op) oder false.
function I.CarcassTake(H, Pawn, P, N, Now)
    local Cc = H.Carc
    if not Cc or Now - Cc.T > K.CARC_TTL then return false end
    local O = I.Safe(function() return StaticFindObject(Cc.F) end)
    if not I.Alive(O) then return false end
    local Fam = I.CarcFam(O)
    if not Fam or not I.CarcDead(O, Fam) then return false end
    local Comp = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(Comp) then return false end
    local Snap = I.Scan(Comp)
    for Uid, E in pairs(Snap) do
        if E.P == P and E.N >= 1 then
            local It = I.FindItem(Comp, Uid)
            if not It then return false end
            local Take = math.min(N, E.N)
            if not pcall(function() Comp:HandleLocalRequestConsumeItem(It[F.UID], Take, Comp, "", false) end) then return false end
            local After = I.Scan(Comp)
            local Got = E.N - (After[Uid] and After[Uid].N or 0)
            if Got < 1 then
                I.WarnOnce("carcnoop", "Leiche %s: Entnahme ohne Wirkung (keine Gutschrift)", I.Short(Cc.F))
                return false
            end
            return math.min(Got, Take)
        end
    end
    return false
end

-- Warteschlange der pend-Anfragen (Host-Task 0,1 s)
function I.HostPend(G, Key, H, Pawn, Now)
    if #H.PendQ == 0 then return end
    if not H.LedgerAt or Now - H.LedgerAt > 0.2 then I.Ledger(G, Key, Pawn, Now) end
    local Keep = {}
    for _, J in ipairs(H.PendQ) do
        local Final = Now - J.T0 >= K.HOLD
        local ok, R = pcall(I.Decide, G, H, J, Pawn, Now, Final)
        if not ok then
            Core.Fail("inv_pend", R)
            Net.Reply(J.Msg, "no|fehler")
        elseif R then
            -- Ergebnis je UID merken: Wiederholung nach Zeitueberschreitung beim Gast bekommt dieselbe Antwort
            H.Done = H.Done or {}
            H.Done[J.Uid] = { R = R, T = Now }
            Net.Reply(J.Msg, R)
        else
            Keep[#Keep + 1] = J
        end
    end
    H.PendQ = Keep
end

-- inv_pend_defer: vorgemerkte Anlagen nach Ablauf (Asset per Pfad neu, keine UObjects ueber Ticks)
function I.HostDefer(G, Key, H, Pawn, Now)
    local Keep = {}
    for _, D in ipairs(H.Defer) do
        if Now < D.At then
            Keep[#Keep + 1] = D
        else
            local Asset = I.ItemAsset(D.P)
            local R = Asset and I.AddFor(Pawn, Asset, D.N, H) or "fehler"
            if R == "fehler" and Now < D.Until then
                D.At = Now + 1
                Keep[#Keep + 1] = D
            elseif R == "fehler" then
                -- Runde 9 INV-21: nicht still verwerfen
                Log("%s: FEHLT %dx %s (%s) - Anlage bis zum Ablauf fehlgeschlagen", tostring(G.PCName or Key), D.N, I.Short(D.P), D.Why)
            else
                Log("%s: %dx %s angelegt (%s, %s, verzoegert%s)", tostring(G.PCName or Key), D.N, I.Short(D.P), D.Why, R,
                    D.Ack and (D.Acked and ", nach Quittung" or ", ohne Quittung") or "")
                I.Audit(G, Key, D.P, D.N, I.Rule(D.Why) .. (R == "drop" and " (Boden)" or ""))   -- X-INV1
                -- INV-21: Inventar voll -> AddNewItemSomewhere legt am Boden ab; der Gast sah dazu keinen Hinweis
                if R == "drop" then I.Note(G, "Inventar voll: am Boden") end
            end
        end
    end
    H.Defer = Keep
end

-- Gast fordert, eine lokal entnommene Menge auch beim Server zu entnehmen (Brunnen, Generator, Gaskanister ...)
function I.HostUse(G, Key, H, Pawn, J)
    local Comp = Pawn.BP_JigMultiplayer
    if not I.Alive(Comp) then return "no|weg" end
    local It = I.FindItem(Comp, J.Uid)
    if not It then return "no|weg" end
    local D = I.DAInfo(It[F.INFO][F.ID])
    local Have = math.floor(tonumber(It[F.INFO][F.COUNT]) or 0)
    if not D or (J.Path ~= "" and D.P ~= J.Path) then return "no|typ" end
    local N = math.max(1, math.min(J.N, Have))
    local ok, err = pcall(function() Comp:HandleLocalRequestConsumeItem(It[F.UID], N, Comp, "", false) end)
    if not ok then Core.Fail("inv_use", err) return "no|fehler" end
    Log("%s: %dx %s beim Server entnommen (lokal verbraucht)", tostring(G.PCName or Key), N, I.Short(D.P))
    for _, Fn in ipairs(S.UseFns) do pcall(Fn, G, D.P, N, Pawn) end
    return "ok"
end

-- Haltung Gast-Hotbar/Waffe: Datei NetTest_Guests\<id>.bar.txt im SaveGames-Ordner des Hosts
function I.BarPath(GuestId)
    local Id = tostring(GuestId or ""):match("^%x+$")
    if not Id then return nil end
    return (os.getenv("LOCALAPPDATA") or "") .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\" .. Id .. ".bar.txt"
end

function I.ReadBar(GuestId)
    local Path, Out = I.BarPath(GuestId), {}
    local Text = Path and Core.ReadAll(Path)
    for Line in tostring(Text or ""):gmatch("[^\r\n]+") do
        local Kk, V = Line:match("^(%w+)=(.*)$")
        if Kk then Out[Kk] = V end
    end
    return Out
end

function I.WriteBar(GuestId, H)
    local Path = I.BarPath(GuestId)
    if not Path then return end
    local Text = string.format("bar=%s\naw=%s\n", H.BarSaved or "", H.AWSaved or "None")
    if not Core.WriteAtomic(Path, Text) then I.WarnOnce("barw", "Hotbar-Datei nicht schreibbar: %s", Path) end
end

-- Nach dem Erst-Sync: Hotbar zurueck an den Gast, aktive Waffe nachspielen; danach Aenderungen mitschreiben
function I.HostBar(G, Key, H, Pawn, Now)
    -- Doppel-Login: keine gespeicherte Hotbar/Waffe laden und keine .bar.txt des echten Spielers schreiben. SyncVal
    -- zuruecksetzen -> endet der Doppel-Status, startet die Wiederherstellung normal (RestoreAt + 3 s)
    if I.Dup(Key) then H.SyncVal, H.Restored, H.RestoreAt = nil, false, nil return end
    local GI = A.G
    local Val = GI and GI.Synced and GI.Synced[Key]
    if Val ~= H.SyncVal then
        H.SyncVal, H.Restored = Val, false
        H.RestoreAt = Val and (Now + 3) or nil
    end
    if H.RestoreAt and not H.Restored and Now >= H.RestoreAt then
        H.Restored, H.TrackAt = true, Now + 5
        local Saved = I.ReadBar(G.GuestId)
        H.BarSaved, H.AWSaved = Saved.bar, Saved.aw
        if Saved.bar and Saved.bar ~= "" and I.On("inv_bar") and Net.Has("inv2a", G) then
            Net.Send("inv_barset", Saved.bar, G, 1)
        end
        if Saved.aw and Saved.aw ~= "" and Saved.aw ~= "None" and I.On("inv_aw") then
            -- ServerFuncChangeActiveSlot haengt nur an + SetActiveWeaponSlot; der Equip-Ablauf des Gasts (EquipPrimary:
            -- Svr_UpdateCombatState, ActionBarEquipUI, WeaponEquipped?) laeuft nicht -> Waffe in der Hand, Gast "unbewaffnet",
            -- erster Tastendruck holstert (EquipPrimary @27d26). Nur noch als Rueckfall mit inv_aw_srv=1.
            if I.OnOff("inv_aw_srv") then
                I.Try("inv_aw", function() Pawn:ServerFuncChangeActiveSlot({ TagName = FName(Saved.aw) }) end)
                Log("Aktive Waffe von %s wiederhergestellt: %s", tostring(G.PCName or Key), Saved.aw)
            else
                Log("Aktive Waffe von %s (%s) nicht serverseitig gezogen - Gast zieht selbst (Equip-Ablauf des Spiels)",
                    tostring(G.PCName or Key), Saved.aw)
            end
        end
    end
    if not H.Restored or Now < (H.TrackAt or math.huge) then return end
    local Changed = false
    local Bar = Net.Get("inv_bar", "b", G)
    if I.On("inv_bar") and Bar and Bar ~= H.BarSaved and Bar:match("^[%x,]+$") then H.BarSaved, Changed = Bar, true end
    if I.On("inv_aw") then
        local Tag = I.Safe(function()
            local Helper = Pawn.BP_JigHelperComp
            return I.Alive(Helper) and Helper.ActiveWeapon.TagName:ToString() or nil
        end)
        if Tag and Tag ~= H.AWSaved then H.AWSaved, Changed = Tag, true end
    end
    if Changed then I.WriteBar(G.GuestId, H) end
end

-- Kisten in der Naehe eines Gasts replizieren (nur stabil benannte Karten-Actors)
function I.HostRep(L)
    local N = 0
    for _, E in ipairs(I.NearConts(L, K.REP_RADIUS, 200)) do
        if not S.Rep[E.F] then
            S.Rep[E.F] = true
            local O = I.Fresh(E)
            if O and I.Safe(function() return O.Role end) == K.ROLE_AUTHORITY then
                I.Try("inv_crep", function()
                    if O.bReplicates ~= true then O:SetReplicates(true) end
                    local Comp = O.BP_JigMultiplayer
                    if I.Alive(Comp) then Comp:SetIsReplicated(true) S.AddrAt[E.F] = os.clock() end
                end)
                N = N + 1
                if N >= 20 then break end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------- Fixplan #8/#16
-- Laufzeit-Kisten und tote KI: Der Gast fragt beim Oeffnen SERVER_RequestData(KisteComp). Die Referenz kommt beim Host
-- nur an, wenn der Server dem Gast die GUID der Komponente schon geschickt hat (replizierte Komponente eines replizierten
-- Actors) -> sonst "You can't interact..." und leere UI. Wie beim funktionierenden Tier-Weg (ls_ai lootrep).

-- Repliziert (Actor oder Komponente)? GetIsReplicated, sonst bReplicates
function I.IsRep(O)
    local R = I.Safe(function() return O:GetIsReplicated() end)
    if R == nil then R = I.Safe(function() return O.bReplicates end) end
    return R == true
end

-- Lage fuer den Abgleich: Kisten = Actor, Leichen = Mesh (Kapsel/Root liegt nach dem Tod oft bei 0,0,0)
function I.CarcLoc(O, Fam)
    if Fam ~= "c" then
        local ML = I.Safe(function()
            local Mesh = O.Mesh
            if not I.Alive(Mesh) then return nil end
            local V = Mesh:K2_GetComponentLocation()
            return { X = V.X, Y = V.Y, Z = V.Z }
        end)
        if ML then return ML end
    end
    return I.Loc(O)
end

-- Jig-Komponente eines (schon replizierten) Actors netzadressierbar machen. Nie SetReplicates auf dem Actor: eine nur
-- lokal existierende Kopie kaeme sonst beim Gast doppelt an. Rueckgabe ok, Grund
function I.MakeAddr(O)
    if not I.IsRep(O) then return false, "Actor nicht repliziert" end
    local Comp = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(Comp) then return false, "keine Jig-Komponente" end
    local Was = I.IsRep(Comp)
    local Full = I.Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end)
    if not Was then
        local ok, err = pcall(function() Comp:SetIsReplicated(true) end)
        if not ok then return false, tostring(err) end
        if Full then S.AddrAt[Full] = os.clock() end
    elseif Full and S.AddrAt[Full] == nil and I.On("inv_prime_strict") then
        -- Runde 9 CORE-28: schon adressierbar (Spiel/anderes Modul ohne E6 MarkAddr) -> erste Sicht merken; I.HostCarc
        -- wertet "unbekannt" als alt (kein Prime). Zaehler klaert, wie oft das vorkommt
        S.AddrAt[Full] = os.clock()
        S.NoAddrN = (S.NoAddrN or 0) + 1
        if S.NoAddrN <= 20 or S.NoAddrN % 50 == 0 then
            Log("MakeAddr ohne AddrAt: %s war schon repliziert (Fall %d)", I.Short(Full), S.NoAddrN)
        end
    end
    pcall(function() O:ForceNetUpdate() end)
    return true, Was and "schon repliziert" or "repliziert"
end

-- inv_lootprime/trd_prime: Komponente ist laenger als inv_prime_fresh_s (Standard 10 s) durch die Mod adressierbar ->
-- die native Anfrage des Gasts hatte eine gueltige Referenz, ihre Antwort ist nur spaet. Eine zweite
-- CLIENT_ContainerDataResponse in die dann volle UI liesse BuildDataToContainer scheitern -> SERVER_RequestRemoveItem
-- (@0479) loescht die Items beim Server. Unbekannt (nil) = alter Weg (Prime erlaubt).
function I.PrimeLate(Full, Now)
    local At = Full and S.AddrAt[Full]
    return At ~= nil and Now - At > (tonumber(Core.Flag("inv_prime_fresh_s", 10)) or 10)
end

-- Einmal je Objekt (FName), nur nahe einem Gast. true = bearbeitet
function I.NetRepOne(O, Fam, Locs, Station)
    local Nm = I.Name(O)
    if not Nm or S.NetRep[Nm] then return false end
    local L = I.CarcLoc(O, Fam)
    if not L then return false end
    local Near = false
    for _, G in ipairs(Locs) do
        if I.Dist2(L, G.X, G.Y, G.Z) <= K.REP_RADIUS * K.REP_RADIUS then Near = true break end
    end
    if not Near then return false end
    if S.NetRepN > 5000 then S.NetRep, S.NetRepN = {}, 0 end
    S.NetRep[Nm], S.NetRepN = true, S.NetRepN + 1
    if Station and K.STATION_TAB[Station] then                -- Runde 9 INV-8: einmal je Station und Welt
        Log("Station %s: Rezepte fuer Gaeste - %s", Nm, tostring(I.StationTab(O, Station)))
        return true
    end
    local Ok, Why = I.MakeAddr(O)
    if Ok and Why == "schon repliziert" then return true end
    if Station then                                           -- inv_stationrep: einmal je Klasse loggen
        I.WarnOnce("st_" .. Station, "Station %s: Jig fuer Gaeste %s (CompRef fuer SERVER_RequestCraftItem)", Station,
            Ok and Why or ("nicht freigegeben (" .. Why .. ")"))
        return true
    end
    Log("%s %s: Inventar fuer Gaeste %s", Fam == "c" and "Kiste" or "Leiche", Nm, Ok and Why or ("nicht freigegeben (" .. Why .. ")"))
    return true
end

-- Runde 9 INV-8 (inv_station_tab, BUILD-6): Siedlungs-Kochstelle/-Werkbank (Karten-Actors). SetItemsToCraft laeuft im Spiel
-- nur beim interagierenden Client (OnStopExecuteInteract: Kochen @0333 Tabelle 2, Werkbank @00d5 Tabelle 1); beim Host
-- bleibt ItemsToCraft leer -> HandleServerFuncRequestCraft @01aa liest ins Leere. Host setzt die Tabelle einmal selbst (nur
-- solange leer, wie ls_build OW.TabHost) und repliziert den Actor (SetReplicates), damit die CompRef des Gasts aufloest.
-- Review 1: Siedlungen sind Laufzeit-Prefabs (BP_SettlementCampSpawner, CAC-Kinder eines PrefabMaster_C). Eine solche
-- Station kommt beim Gast ZUSAETZLICH zu seiner lokalen CAC-Kopie an (wie bei den Haendlern) -> der Gast entfernt seine
-- lokale Kopie (I.StationGhost, inv_station_ghost). Karten-Stationen (RF_WasLoaded) sind stabil benannt, kein Doppel.
-- Log je Station: Karte/Laufzeit + Eltern-Actor (Live-Bestaetigung)
function I.StationTab(O, Cls)
    local T = K.STATION_TAB[Cls]
    if not T or I.Safe(function() return O.Role end) ~= K.ROLE_AUTHORITY then return "keine Autoritaet" end
    local Jig = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(Jig) then return "kein Jig" end
    local Rep = pcall(function()
        if O.bReplicates ~= true then O:SetReplicates(true) end
        Jig:SetIsReplicated(true)
    end)
    local Full = I.Safe(function() return O:GetFullName():match("^%S+%s+(.+)$") end)
    if Rep and Full and S.AddrAt[Full] == nil then S.AddrAt[Full] = os.clock() end
    local Tab = "Tabelle schon gesetzt"
    if (I.Safe(function() return Jig.ItemsToCraft:GetArrayNum() end) or 0) == 0 then
        local GFL = I.Safe(function() return StaticFindObject(K.GFL) end)
        if not I.Alive(GFL) then return "GameFunctionLibrary fehlt" end
        local ok, err = pcall(function() GFL:SetItemsToCraft(T, Jig, O) end)
        if not ok then Core.Fail("inv_station_tab", err) return "Fehler" end
        Tab = string.format("Tabelle %d (%d Rezepte)", T, I.Safe(function() return Jig.ItemsToCraft:GetArrayNum() end) or 0)
    end
    pcall(function() O:ForceNetUpdate() end)
    -- Review 1: Herkunft fuer die Live-Bestaetigung (Laufzeit-Station = Gast braucht inv_station_ghost)
    local Flag = EObjectFlags and EObjectFlags.RF_WasLoaded
    local Ld = nil
    if Flag then Ld = I.Safe(function() return O:HasAnyFlags(Flag) end) end
    local Par = I.Safe(function() return O:GetParentActor() end)
    local ParN = I.Alive(Par) and I.Name(Par) or "-"
    return (Rep and "adressierbar, " or "nicht adressierbar, ") .. Tab
        .. string.format(", %s, Eltern %s", Ld == true and "Karte" or (Ld == false and "Laufzeit" or "?"), tostring(ParN))
end

-- Host-Takt 1 s: abwechselnd eine Kisten-Klasse (FindAllOf) bzw. tote KI aus A.Characters()
function I.HostNetRep(Locs)
    S.NRi = S.NRi + 1
    local N = 0
    if S.NRi % 2 == 1 then
        -- inv_stationrep: Stationen (K.STATIONS) hinten anhaengen - nur Jig SetIsReplicated + ForceNetUpdate (I.MakeAddr)
        -- Runde 9 inv_station_tab: Siedlungs-Stationen (K.STATION_TAB) dahinter - I.StationTab
        local List = K.NETREP_CLASSES
        local Sr, St = I.On("inv_stationrep"), I.On("inv_station_tab")
        if Sr or St then
            local Sig = tostring(Sr) .. tostring(St)
            if K.NETREP_SIG ~= Sig then
                K.NETREP_SIG, K.NETREP_ALL = Sig, {}
                for _, V in ipairs(K.NETREP_CLASSES) do K.NETREP_ALL[#K.NETREP_ALL + 1] = V end
                if Sr then for _, V in ipairs(K.STATIONS) do K.NETREP_ALL[#K.NETREP_ALL + 1] = V end end
                if St then for V in pairs(K.STATION_TAB) do K.NETREP_ALL[#K.NETREP_ALL + 1] = V end end
            end
            List = K.NETREP_ALL
        end
        local Idx = ((S.NRi - 1) // 2) % #List + 1
        local Cls = List[Idx]
        local Station = Idx > #K.NETREP_CLASSES and Cls or nil
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if N >= 20 then break end
            if I.Alive(O) and I.NetRepOne(O, "c", Locs, Station) then N = N + 1 end
        end
        return
    end
    for _, O in ipairs(I.Safe(function() return A.Characters() end) or {}) do
        if N >= 20 then break end
        if I.Alive(O) then
            local Fam = I.CarcFam(O)
            if (Fam == "z" or Fam == "h") and I.CarcDead(O, Fam) and I.NetRepOne(O, Fam, Locs) then N = N + 1 end
        end
    end
end

-- Host: Looted wie beim Spieler im Einzelspiel (sonst nur gastlokal gesetzt)
function I.MarkLooted(O, Fam, Cls)
    -- "h": Looted der KI-Unterklassen (BP_MasterBandit_C/BP_MasterCoyoteSoldier_C/...), ls_ai spiegelt es an alle.
    -- UE 5.6: BP_MasterZombie_C.Looted heisst Looted? (Ubergraph @31ea); BP_ZombieBoss_C/Tiere behalten Looted.
    -- Je Name eigener pcall: die jeweils fehlende Eigenschaft schlaegt nur fehl. Container_AnimalMeat entfaellt in 5.6.
    if Fam == "z" or Fam == "a" or Fam == "h" then
        pcall(function() O.Looted = true end)
        if Fam == "z" then pcall(function() O["Looted?"] = true end) end
    elseif Cls == "Container_DeadPlayerLoot_C" then
        pcall(function() O["Looted?"] = true end)
    end
end

-- Runde 9 CORE-28: RTT eines Gasts beim Host (PlayerState-Ping), 0,05-2 s
function I.GuestRtt(G)
    local Ms = tonumber(I.Safe(function()
        local PC = Net.PC(G)
        local PS = PC and PC.PlayerState
        return I.Alive(PS) and PS:GetPingInMilliseconds() or nil
    end))
    return math.min(math.max((Ms or 150) / 1000, 0.05), 2)
end

-- E6 (ls_ai lootrep): Komponente wurde ausserhalb von I.MakeAddr adressierbar gemacht -> Zeitpunkt fuer die Prime-Regel
function M.MarkAddr(Full)
    if Net.Side ~= "host" or type(Full) ~= "string" then return end
    Full = Full:match("^%S+%s+(.+)$") or Full
    if S.AddrAt[Full] == nil then S.AddrAt[Full] = os.clock() end
end

-- inv_carc (Host): Objekt zur Gast-Meldung suchen, netzadressierbar machen, Datenanfrage vormerken.
-- Age (Runde 9, Cap invps): Sekunden seit dem Oeffnen beim Gast, nil = alter Gast
function I.HostCarc(G, H, Cls, L, X, Y, Z, Now, Age)
    local Who = tostring(G.PCName or G.Key)
    local Best, BestD, BestFam
    for _, O in ipairs(FindAllOf(Cls) or {}) do
        local Fam, CN = nil, nil
        if I.Alive(O) then Fam, CN = I.CarcFam(O) end
        if Fam == false and CN == Cls then
            S.CarcFam[Cls] = false                          -- Klasse ist weder Leiche noch Kiste (z. B. Spieler)
            Log("inv_carc: Klasse %s abgelehnt (%s)", Cls, Who)
            return
        end
        if Fam and (Fam == "c" or I.CarcDead(O, Fam)) then
            local Ol = I.CarcLoc(O, Fam)
            local D = Ol and I.Dist2(Ol, X, Y, Z)
            local Tol = Fam == "c" and 300 or 600
            -- Host prueft selbst: Objekt <= 12 m von der Server-Figur des Gasts
            if D and D <= Tol * Tol and I.Dist2(Ol, L.X, L.Y, L.Z) <= 1200 * 1200 and (not BestD or D < BestD) then
                Best, BestD, BestFam = O, D, Fam
            end
        end
    end
    if not Best then I.WarnOnce("cm_" .. Cls .. Who, "inv_carc: kein passendes %s beim Server (%s)", Cls, Who) return end
    local Full = I.Safe(function() return Best:GetFullName():match("^%S+%s+(.+)$") end)
    if not Full then return end
    -- Schloss/Claim (ls_build): fremde gesperrte Kiste nie im Namen des Gasts laden/adressierbar machen
    local Bld = A.Coop and A.Coop.Build
    local Gid = I.RawGid(G)
    if BestFam == "c" and type(Bld) == "table" and type(Bld.CanUse) == "function" then
        local okU, Can = pcall(Bld.CanUse, Gid, Best)
        if okU and Can == false then
            I.WarnOnce("lk_" .. Full .. Who, "inv_carc: Kiste %s fuer %s gesperrt (Schloss/Claim)", I.Short(Full), Who)
            return
        end
    end
    if BestFam ~= "c" and I.OnOff("inv_carcass") then H.Carc = { F = Full, T = Now } end
    if not I.On("inv_lootprime") then return end
    H.PrimeAt = H.PrimeAt or {}
    for F, T in pairs(H.PrimeAt) do if Now - T > 30 then H.PrimeAt[F] = nil end end
    -- Runde 9 CORE-28 (inv_prime_strict): je (Gast, Kiste) hoechstens ein Prime in 15 s (Gast fragt bis 2x im Abstand 4 s)
    local Strict = I.On("inv_prime_strict")
    if Now - (H.PrimeAt[Full] or -math.huge) < (Strict and 15 or 3) then return end
    H.PrimeAt[Full] = Now
    local Prev = S.AddrAt[Full]
    local Ok, Why = I.MakeAddr(Best)
    if not Ok then I.WarnOnce("np_" .. Full, "%s: Inhalt nicht freigebbar (%s)", I.Short(Full), Why) return end
    if Why == "schon repliziert" then
        -- strikt: adressierbar seit vor dem Oeffnen (Gast-Alter + RTT) oder seit unbekannt -> die native Anfrage des
        -- Gasts hatte eine gueltige Referenz, ihre Antwort ist nur spaet (oder die Kiste leer). Ein Prime waere die
        -- zweite CLIENT_ContainerDataResponse -> BuildDataToContainer scheitert -> SERVER_RequestRemoveItem loescht Items
        local Late
        if Strict then
            Late = Prev == nil or (Age ~= nil and Prev < Now - Age - I.GuestRtt(G)) or (Age == nil and I.PrimeLate(Full, Now))
        else
            Late = I.PrimeLate(Full, Now)
        end
        if Late then
            I.WarnOnce("dp_" .. Full, "%s war schon vor dem Oeffnen adressierbar (%s) - kein Prime (Doppelantwort wuerde Items loeschen)",
                I.Short(Full), Prev and string.format("seit %.1f s", Now - Prev) or "seit unbekannt")
            return
        end
    end
    -- Datenanfrage erst im naechsten Durchlauf (Komponente erst replizieren lassen), Objekte dann neu aufloesen
    S.Prime[#S.Prime + 1] = { Key = G.Key, F = Full, Fam = BestFam, Cls = Cls, At = Now + 0.15 }
end

-- Host-Takt 0,1 s: GastComp:SERVER_RequestData(KisteComp) laeuft beim Server lokal -> CLIENT_ContainerDataResponse
-- an den Gast; dabei exportiert der Server die GUID der Kisten-Komponente, danach funktioniert Loot All nativ.
function I.HostPrime(Now)
    if #S.Prime == 0 then return end
    local Keep = {}
    for _, P in ipairs(S.Prime) do
        if Now < P.At then
            Keep[#Keep + 1] = P
        else
            local G = Net.Guests[P.Key]
            local Pawn = G and I.HostPawn(G)
            local O = I.Safe(function() return StaticFindObject(P.F) end)
            local GC = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
            local CC = I.Alive(O) and I.Safe(function() return O.BP_JigMultiplayer end) or nil
            if I.Alive(GC) and I.Alive(CC) then
                local ok, err = pcall(function() GC:SERVER_RequestData(CC) end)
                if not ok then Core.Fail("inv_lootprime", err) end
                if ok and I.On("inv_carc_looted") then I.MarkLooted(O, P.Fam, P.Cls) end
                if ok then S.PrimeHold[P.F] = Now + 10 end    -- Runde 9 INV-19: Kiste 10 s nicht nachfuellen
                I.WarnOnce("pr_" .. P.F, "%s %s fuer %s vom Server geladen (%s)", P.Cls, I.Short(P.F),
                    tostring(G.PCName or P.Key), ok and "ok" or "Fehler")
            end
        end
    end
    S.Prime = Keep
end

-- Looted-Flags, die der Host verteilt: zuruecknehmen, wenn die Kiste beim Host neu befuellt wurde
function I.HostLootRefill(Now)
    if Now < S.LCheckAt then return end
    S.LCheckAt = Now + 5
    for Full, St in pairs(S.LState) do
        local O = I.Safe(function() return StaticFindObject(Full) end)
        if not I.Alive(O) then
            S.LState[Full], S.ScavDone[Full] = nil, nil
        elseif I.Safe(function() return O.ContainerLooted end) == false then
            S.LState[Full], S.ScavDone[Full] = nil, nil          -- neu befuellt: naechstes Durchsuchen gibt wieder XP
            Net.State("inv_lflag", St.N, nil, 2)
        end
    end
    -- Laufzeit-Kisten (inv_scst): weg oder beim Host neu befuellt (Bind_Refill @0a2e) -> Schluessel loeschen
    for P, Key in pairs(S.ScSt) do
        local O = I.Safe(function() return StaticFindObject(P) end)
        if not I.Alive(O) or I.Safe(function() return O.ContainerLooted end) == false then
            S.ScSt[P], S.ScavDone[P] = nil, nil
            Net.State("inv_scst", Key, nil, 2)
        end
    end
end

-- ---------------------------------------------------------------------------------------------- Runde 8: Pluender-XP
-- Gastlokale XP geht verloren (Host spiegelt PassiveSkills/Levelling host->gast) -> XP auf der Server-Kopie buchen.

-- A1-Drossel: 0,25 s je Gast+Schluessel, hoechstens 8 Anfragen/s je Gast. false = verwerfen
function I.RateOk(G, Key, Kind)
    local H, Now = I.HState(G.Key), os.clock()
    local R = H.R8
    if not R then R = { Since = Now, N = 0, K = {}, KN = 0 } H.R8 = R end
    if Now - R.Since >= 1 then R.Since, R.N = Now, 0 end
    R.N = R.N + 1
    local Last = R.K[Key]
    if R.N > 8 or (Last and Now - Last < 0.25) then Net.SecWarn(G, G.Key, Kind .. "_rate") return false end
    if R.KN > 40 then R.K, R.KN = {}, 0 end
    if not Last then R.KN = R.KN + 1 end
    R.K[Key] = Now
    return true
end

-- Mindest-Haltedauer in s (grosszuegige Untergrenze wie W.CrateHoldMin): SP MaxTime = DurationToHold/ScavengingMultiplier
-- (* Difficulty.SearchTime bei BP_LootContainer @0de3-@0ec9 und Airdrop; Werkzeug-Kiste @0a72 ohne SearchTime),
-- Widget-Multiplier hoechstens 2,85*ScavengingMultiplier; Faktor 0,5 und -0,4 s fangen Takt und Latenz ab
function I.HoldMin(O, G, NoST)
    local D = tonumber(I.Safe(function() return O.DurationToHold end)) or 0
    local PC = Net.PC(G)
    local Sm = PC and tonumber(I.Safe(function()
        local Ps = PC.PassiveSkillsComponent
        if I.Alive(Ps) then return Ps.ScavengingMultiplier end
    end)) or 1
    local T = NoST and 1 or tonumber(I.CVar("f", "Difficulty.SearchTime")) or 1
    if Sm < 1 then Sm = 1 end
    if T < 0 then T = 0 end
    local Exp = (D * T / Sm - 0.1) / (2.85 * Sm)
    return math.min(math.max(0.5 * Exp - 0.4, 0), 10)
end

-- Durchsuch-XP nur im SP-Takt: Halten geht im Einzelspiel nacheinander, also verbraucht jede bezahlte Kiste
-- (Karte/Werkzeug/Laufzeit) ihre Mindest-Haltedauer aus einem Zeitkonto je Gast (H.SrchT = bis wann verbraucht);
-- Vorrat hoechstens 6 s (Meldetakt ClientScav 3 s + Latenz). false = zu schnell -> Zustand bleibt, nur keine XP
function I.HoldOk(G, O, What, NoST)
    local H, Now = I.HState(G.Key), os.clock()
    local Need = I.HoldMin(O, G, NoST)
    local T = math.max(H.SrchT or -math.huge, Now - 6)
    if T > Now then
        Net.SecWarn(G, G.Key, "inv_xp_fast")
        Log("Pluender-XP fuer %s verworfen: %s schneller als die Haltedauer (%.2f s)", tostring(G.PCName or G.Key), tostring(What), Need)
        return false
    end
    H.SrchT = T + Need
    return true
end

-- A13: Claim-Richtlinie von ls_build (heute true fuer Nicht-Bauten)
function I.CanUse(G, O)
    local Bld = A.Coop and A.Coop.Build
    if type(Bld) ~= "table" or type(Bld.CanUse) ~= "function" then return true end
    local Gid = I.RawGid(G)
    local ok, Can = pcall(Bld.CanUse, Gid, O)
    return not (ok and Can == false)
end

-- Server-Figur des Gasts lebend? Rueckgabe Figur, Lage
function I.LivePawn(G)
    local Pawn = G and G.Epoch and I.HostPawn(G)
    if not Pawn or I.Safe(function() return Pawn["PlayerDead?"] end) == true then return nil end
    local L = I.Loc(Pawn)
    if not L then return nil end
    return Pawn, L
end

-- AddXP_Scavenging(RandomFloatInRange(4, 6)) wie HoldToInteract (BP_LootContainer_C @03e4, Airdrop @0410,
-- Werkzeug-Kiste @05b4) auf der PassiveSkills-Komponente des Gast-PCs. Thief: zusaetzlich AddXP_Thief(40-60) (@068d)
function I.ScavXP(G, What, Flag, Thief)
    local PC = Net.PC(G)
    local PS = PC and I.Safe(function() return PC.PassiveSkillsComponent end)
    if not I.Alive(PS) then I.WarnOnce("nops_" .. tostring(G.Key), "Pluender-XP: PassiveSkills von %s fehlt", tostring(G.PCName or G.Key)) return nil end
    local V, T = 4 + math.random() * 2, Thief and (40 + math.random() * 20) or nil
    local ok, err = pcall(function()
        PS:AddXP_Scavenging(V)
        if T then PS:AddXP_Thief(T) end
    end)
    if not ok then Core.Fail(Flag, err) return nil end
    Log("Pluender-XP fuer %s: +%.1f (%s)%s", tostring(G.PCName or G.Key), V, tostring(What), T and string.format(", Dieb +%.0f", T) or "")
    return V, T
end

-- (a) Karten-Kiste (BP_LootContainer_C-Familie) vom Gast neu durchsucht: nur XP (Refill-Timer @0314 startet
-- der inv_loot-Handler beim Uebergang, sonst bliebe die Kiste bei verworfener XP fuer immer durchsucht)
function I.LootXP(J)
    local G = Net.Guests[J.Key]
    local Pawn, L = I.LivePawn(G)
    if not Pawn then return end
    local O = I.Safe(function() return StaticFindObject(J.F) end)
    if not I.Alive(O) then return end
    local Ol = I.Loc(O)
    if not Ol or I.Dist2(Ol, L.X, L.Y, L.Z) > 1000 * 1000 then Net.SecWarn(G, G.Key, "inv_loot_dist") return end
    if I.HoldOk(G, O, I.Short(J.F)) then I.ScavXP(G, I.Short(J.F), "inv_scavxp") end
end

-- Mitspieler-ID fuer Rechte (Claim/Schloss/Lager): Doppel-Login (A.Coop.GuestDup) hat keine - main.lua schreibt
-- GuestIds[DupKey] trotzdem, ls_net laesst G.GuestId bewusst nil (wie ls_build/ls_wobj/ls_world)
function I.RawGid(G)
    if not G or I.Dup(G.Key) then return nil end
    return G.GuestId or (A.Coop and A.Coop.GuestIds and A.Coop.GuestIds[G.Key]) or nil
end

function I.Gid(G)
    local Gid = I.RawGid(G)
    return Gid and tostring(Gid):lower() or nil
end

-- Lager-Markierung aufheben darf nur, wer sie gesetzt hat, sein Clan oder ein Admin (sonst loescht das naechste
-- Nachfuellen - ProcessRefillContainer @00be ClearContainer - das Eingelagerte eines Fremden)
function I.MarkOk(G, Cur)
    local Gid = I.Gid(G)
    if Cur.Key == G.Key or (Gid and Gid == Cur.Gid) then return true end
    local Cl = A.Coop.Clan
    if Gid and Cur.Gid and type(Cl) == "table" and type(Cl.Allied) == "function"
        and I.Safe(function() return Cl.Allied(Gid, Cur.Gid) end) == true then return true end
    return I.IsAdmin(G)
end

-- (c) Lager-Markierung aufgehoben: wie im Einzelspiel wieder Kiste mit Nachfuellen nach Spielregel (Difficulty.Refill)
function I.Unmark(J)
    local Cur = S.LState[J.F]
    if not (Cur and Cur.St == "2") then return end
    local G = Net.Guests[J.Key]
    local Pawn, L = I.LivePawn(G)
    if not Pawn then return end
    local O = I.Safe(function() return StaticFindObject(J.F) end)
    if not I.Alive(O) then return end
    local Ol = I.Loc(O)
    if not Ol or I.Dist2(Ol, L.X, L.Y, L.Z) > 800 * 800 then Net.SecWarn(G, G.Key, "inv_loot_dist") return end
    if not I.MarkOk(G, Cur) or not I.CanUse(G, O) then
        Net.SecWarn(G, G.Key, "inv_loot_bad")
        I.Note(G, "Kein Zugriff")
        Log("Lager-Markierung %s: Aufheben durch %s verweigert (gesetzt von %s)", tostring(J.N), tostring(G.PCName or G.Key), tostring(Cur.Gid or Cur.Key))
        return
    end
    pcall(function() O.MarkedAsStorageContainer = false end)
    local Refill = I.CVar("b", "Difficulty.Refill")
    pcall(function()
        local Jig = O.BP_JigMultiplayer
        if I.Alive(Jig) and Refill ~= nil then Jig["DoesContainerRefillLoot?"] = Refill == true end
    end)
    S.LState[J.F] = { N = J.N, St = "1" }
    Net.State("inv_lflag", J.N, "1", 2)
    Log("Lager-Markierung %s von %s aufgehoben (Nachfuellen %s)", tostring(J.N), tostring(G and G.PCName or J.Key), tostring(Refill))
end

-- Erstes Item eines Daten-Assets (Pfad) im Server-Inventar (MainJigContainers)
function I.FindByPath(Comp, P)
    local Found
    Comp.MainJigContainers:ForEach(function(_, CE)
        if Found then return end
        CE:get()[F.ITEMS]:ForEach(function(_, IE)
            if Found then return end
            local It = IE:get()
            local D = I.DAInfo(It[F.INFO][F.ID])
            if D and D.P == P then Found = It end
        end)
    end)
    return Found
end

-- (d) Haltbarkeit wie HoldToInteract @041c-@0490 -> ReduceDurabilityOfFoundItem(ToolNeeded, 10 * Difficulty.
-- OtherItemsDurabilityMultiplier, 1, false, true): MaxDurability 0 -> unveraendert; Durability > Abzug ->
-- ServerFuncUpdateDurabilityByUID(UID, Abzug, true) (subtrahiert @0270, CLIENT_UpdateDurability an den Gast); sonst nichts
-- (den Hinweis "No durability" zeigt der Gast schon selbst). Rueckgabe Text fuers Log
function I.ToolDur(Pawn, O, Uid)
    if I.Safe(function() return O["ToolNeeded?"] end) ~= true then return "kein Werkzeug noetig" end
    local DA = I.Safe(function() return O.ToolNeeded end)
    local D = I.Alive(DA) and I.DAInfo(DA)
    if not D then return "Werkzeug unbekannt" end
    -- Werkzeug-Besitz zuerst (Einzelspiel-Tor: Ubergraph @0ea4 FindItem_Pure(ToolNeeded)), erst dann CVar/Abzug
    local GJ = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(GJ) then return "kein Jig" end
    local It = Uid ~= "" and I.FindItem(GJ, Uid) or nil
    if It and (I.DAInfo(It[F.INFO][F.ID]) or {}).P ~= D.P then It = nil end
    It = It or I.FindByPath(GJ, D.P)
    if not It then return "Werkzeug nicht im Server-Inventar" end
    local Mult = tonumber(I.CVar("f", "Difficulty.OtherItemsDurabilityMultiplier"))
    if not Mult then return "CVar unlesbar" end
    local Minus = 10 * Mult
    if Minus <= 0 then return "kein Abzug" end
    local Dv = I.Safe(function()
        local V = It[F.INFO][F.DUR]
        return { X = tonumber(V.X), Y = tonumber(V.Y) }
    end) or {}
    local X, Y = Dv.X, Dv.Y
    if not S.DurLog then
        S.DurLog = true
        Log("Haltbarkeit erstes Lesen (%s): X=%s Y=%s", I.Short(D.P), tostring(X), tostring(Y))
    end
    if not (X and Y) then return "Haltbarkeit unlesbar" end
    if Y == 0 then return "ohne Haltbarkeit" end
    if X <= Minus then return "Haltbarkeit zu gering" end
    local ok, err = pcall(function() GJ:ServerFuncUpdateDurabilityByUID(It[F.UID], Minus, true, {}) end)
    if not ok then Core.Fail("inv_toolxp", err) return "Fehler" end
    return string.format("-%.1f", Minus)
end

-- (d) inv_tool: Werkzeug-Kiste beim Host als durchsucht, Refill-Timer, Haltbarkeit, XP. Das Level-XP-Ende (@0890-@090d,
-- Stufe*100) laeuft im Einzelspiel nur, wenn OpenContainer ContainerLooted nicht setzt (Fenster schon offen) -> nicht
function I.ToolOne(J)
    local G = Net.Guests[J.Key]
    local Pawn, L = I.LivePawn(G)
    if not Pawn then return end
    local E
    for _, X in ipairs(I.NearConts(L, 1500, 64)) do
        if X.N == J.N and X.T then E = X break end
    end
    -- Schluessel je Gast, nicht je gemeldetem Namen (Gast-Text, sonst beliebig viele Eintraege/Logzeilen)
    if not E then I.WarnOnce("tk_" .. tostring(G.Key), "inv_tool: Werkzeug-Kiste %s beim Server nicht gefunden (%s)", tostring(J.N):sub(1, 64), tostring(G.PCName or G.Key)) return end
    if I.Dist2(L, E.X, E.Y, E.Z) > 600 * 600 then Net.SecWarn(G, G.Key, "inv_tool_dist") return end
    local O = I.Fresh(E)
    if not O or I.Safe(function() return O.ContainerLooted end) ~= false then return end
    if not I.CanUse(G, O) then I.Note(G, "Kein Zugriff") return end
    -- Werkzeug beim Host pruefen, bevor Zustand/XP: ohne Werkzeug kein Durchsuchen (Einzelspiel @0ea4); geringe
    -- Haltbarkeit sperrt im Einzelspiel nicht (HoldToInteract @0490 ignoriert Found) -> weiter
    local Dur = I.ToolDur(Pawn, O, J.U or "")
    if Dur == "Werkzeug nicht im Server-Inventar" then Net.SecWarn(G, G.Key, "inv_tool_bad") return end
    if Dur == "Werkzeug unbekannt" or Dur == "kein Jig" then
        I.WarnOnce("tu_" .. tostring(E.F), "inv_tool: %s fuer %s nicht pruefbar (%s) - verworfen", I.Short(E.F), tostring(G.PCName or G.Key), Dur)
        return
    end
    pcall(function() O.ContainerLooted = true end)
    S.LState[E.F], S.ScavDone[E.F] = { N = E.N, St = "1" }, true
    if I.On("inv_lflag") then Net.State("inv_lflag", E.N, "1", 2) end
    pcall(function()
        local Jig = O.BP_JigMultiplayer
        if I.Alive(Jig) then Jig:StartRefillTimer(false) end
    end)
    if I.HoldOk(G, O, I.Short(E.F), true) then I.ScavXP(G, I.Short(E.F), "inv_toolxp", true) end
    Log("Werkzeug-Kiste %s: XP/Haltbarkeit fuer %s (Haltbarkeit %s)", I.Short(E.F), tostring(G.PCName or G.Key), Dur)
end

-- (e) inv_scav: Laufzeit-Kiste <= 300 uu um die gemeldete Lage und <= 800 uu um die Server-Figur; einmal je Objekt
-- (Airdrop: einmal je Objekt und Gast - Inspected ist im Einzelspiel je Spieler lokal)
function I.ScavOne(J)
    local G = Net.Guests[J.Key]
    local Pawn, L = I.LivePawn(G)
    if not Pawn then return end
    if I.Dist2(L, J.X, J.Y, J.Z) > 1100 * 1100 then Net.SecWarn(G, G.Key, "inv_scav_dist") return end
    -- FindAllOf hoechstens 1x/s je Klasse (sonst erzwingt ein Gast mit wechselnden Koordinaten 8 Scans/s). Runde 9 CORE-19:
    -- gemerkt werden Pfade + Lagen (keine UObject-Verweise ueber Ticks); Kandidaten <= 5 m/10 m frisch aufloesen und mit
    -- frischer Lage wie bisher pruefen (300/800)
    local Now, CL = os.clock(), S.ScavL[J.Cls]
    if not CL or Now - CL.At >= 1 then
        CL = { At = Now, L = {} }
        for _, O in ipairs(FindAllOf(J.Cls) or {}) do
            local Ol = #CL.L < 500 and I.Alive(O) and I.Loc(O)
            local P = Ol and I.Path(O)
            if P then CL.L[#CL.L + 1] = { P = P, X = Ol.X, Y = Ol.Y, Z = Ol.Z } end
        end
        S.ScavL[J.Cls] = CL
    end
    local Best, BestD
    for _, E in ipairs(CL.L) do
        local O = I.Dist2(E, J.X, J.Y, J.Z) <= 500 * 500 and I.Dist2(E, L.X, L.Y, L.Z) <= 1000 * 1000
            and I.Safe(function() return StaticFindObject(E.P) end) or nil
        local Ol = I.Alive(O) and I.Loc(O)
        local D = Ol and I.Dist2(Ol, J.X, J.Y, J.Z)
        if D and D <= 300 * 300 and I.Dist2(Ol, L.X, L.Y, L.Z) <= 800 * 800 and (not BestD or D < BestD) then Best, BestD = O, D end
    end
    if not Best then I.WarnOnce("sc_" .. J.Cls .. tostring(J.Key), "inv_scav: kein passendes %s beim Server", J.Cls) return end
    local P = I.Path(Best)
    if not P then return end
    local Air = K.SCAV[J.Cls] == "Inspected"
    -- Airdrop je Spieler: stabile GuestId statt PC-Name (Reconnect = neuer PC -> sonst erneut XP)
    local DK = Air and (P .. "|" .. (I.Gid(G) or tostring(J.Key))) or P
    -- POI-/Compound-Kiste: Host-Kopie neu befuellt (Bind_Refill @0a2e ContainerLooted=false) -> erneut XP/Refill-Timer
    -- wie HoldToInteract je Durchsuchen (Laufzeit-Kisten stehen nicht in S.LState/I.HostLootRefill)
    if not Air and S.ScavDone[DK] and I.Safe(function() return Best.ContainerLooted end) == false then S.ScavDone[DK] = nil end
    if S.ScavDone[DK] then return end
    if not I.CanUse(G, Best) then I.Note(G, "Kein Zugriff") return end
    S.ScavDone[DK] = true
    if not Air then
        pcall(function() Best.ContainerLooted = true end)
        pcall(function()                                      -- BP_LootContainer_C.HoldToInteract @0314
            local Jig = Best.BP_JigMultiplayer
            if I.Alive(Jig) then Jig:StartRefillTimer(false) end
        end)
        -- ContainerLooted repliziert nicht (props.tsv ohne CPF_Net), Laufzeit-Kisten fehlen in inv_lflag -> Durchsucht
        -- als Positions-Schluessel an alle (auch Nachzuegler); geloescht beim Nachfuellen (I.HostScavRefill)
        local Bl = I.On("inv_lflag") and I.Loc(Best)
        if Bl then
            local Key = string.format("%s@%d,%d,%d", J.Cls, math.floor(Bl.X + 0.5), math.floor(Bl.Y + 0.5), math.floor(Bl.Z + 0.5))
            S.ScSt[P] = Key
            Net.State("inv_scst", Key, "1", 2)
        end
    end
    -- Zeitkonto sperrt nur die Durchsuch-XP; POI-Status (Event_Looted L_2551: einmalig ueber UniqueContainerLooted?,
    -- danach kein zweites AddXP) immer buchen, sonst bleibt er nach ScavDone dauerhaft aus
    if I.HoldOk(G, Best, I.Short(P), false) then I.ScavXP(G, I.Short(P), "inv_scavxp") end
    local W = A.Coop.World
    -- POI-Status nur fuer POI-/Compound-Kisten (Runde 9 WORLD-2: Keycard-Koffer/Versteck/Spezial-Kiste gehoeren zu keinem
    -- POI-Manager; PoiMgrMatch nimmt sonst den naechsten Manager <= 3 m)
    if not Air and (J.Cls == "Container_POICrate_C" or J.Cls == "Container_CompoundCrate_C") and type(W) == "table"
        and type(W.PoiCrateLooted) == "function" then
        local ok, R = pcall(W.PoiCrateLooted, G, P)
        if not ok then Core.Fail("inv_scavxp", R) end
    end
end

-- inv_toolxp beim Host aus/abgeschaltet (invx bleibt ueber inv_scavxp): der Gast schickt statt inv_loot "1" nur
-- inv_tool -> Werkzeug-Kiste wenigstens wie inv_loot "1" als durchsucht fuehren (ohne XP/Haltbarkeit)
function I.ToolFallback(G, Name)
    if not (G and Name and I.On("inv_lflag")) then return end
    I.Try("inv_lflag", M.Handlers.inv_loot, Net.Enc(Name) .. "|1", G)
end

-- ---------------------------------------------------------------------------------------------- Runde 9 Reparatur
-- INV-4 (inv_repair): Reparatur-Sets/Ruestungs-Sets/Strahlenfilter schreiben beim Gast mit ServerFunc_UpdateDurabilityByUID
-- (kein RPC, sucht in MainJigContainers = beim Gast leer) ins Leere; das Set wird nie abgenutzt, der Filter verbraucht.
-- Gast meldet die Absicht (inv_rep), der Host rechnet wie das Spiel (ContextRepairWeapon @0253-@04a2, Set @073e-@0857,
-- Anbauteil /2 @073e, Ziehen WeaponRepair @044a SelectFloat(2,1,Attachment?)) und schreibt auf der Server-Kopie
-- (CLIENT_UpdateDurability @0291 erreicht den Gast).

-- Haltbarkeit (X aktuell, Y maximal) eines Server-Items
function I.DurOf(It)
    local V = I.Safe(function()
        local D = It[F.INFO][F.DUR]
        return { X = tonumber(D.X), Y = tonumber(D.Y) }
    end) or {}
    return V.X, V.Y
end

-- Review 1 (inv_rep_strict): Ziel-Typ wie JigItemOverItemComp_C.GetValid pruefen (nur lesen, DA vorher I.Alive).
-- w/wd: ItemType genau MainFirearm/Melee/Sidearm (@0491, exakt); t: genau WeaponAttachment, nicht MakeshiftMuffler(2)
-- (@0625-@0781); a/ad: IsArmor? und ItemType unter BodyArmor/Headwear (@085f-@091a, nicht exakt).
-- Kontextmenue-Weg zusaetzlich gueltig: das Daten-Asset bietet die Option selbst an (ContextMenuOptions,
-- JigContextMenuComp_C.On @05c7-@068b; ProcessMenuOptions prueft keinen ItemType). Tag nicht lesbar -> Pfad-Familie
function I.RepTargetOk(Kind, DA, Path)
    if not I.Alive(DA) then return false end
    local Ctx = ({ w = "Jig.Context.WeaponRepair", wd = "Jig.Context.WeaponRepair", t = "Jig.Context.AttachmentRepair",
        a = "Jig.Context.ArmorRepair", ad = "Jig.Context.ArmorRepair" })[Kind]
    local HasCtx = false
    if Ctx then
        pcall(function()
            DA.ContextMenuOptions.GameplayTags:ForEach(function(_, E)
                if HasCtx then return true end
                if E:get().TagName:ToString() == Ctx then HasCtx = true end
            end)
        end)
    end
    if HasCtx then return true end
    local Tag = I.Safe(function() return DA.ItemType.TagName:ToString() end)
    local P = tostring(Path or "")
    if Kind == "w" or Kind == "wd" then
        if type(Tag) == "string" and Tag ~= "" and Tag ~= "None" then
            return Tag == "Jig.ItemType.MainFirearm" or Tag == "Jig.ItemType.Melee" or Tag == "Jig.ItemType.Sidearm"
        end
        return P:find("/Weapons/Firearms/", 1, true) ~= nil or P:find("/Weapons/Melee/", 1, true) ~= nil
    elseif Kind == "t" then
        local Id = I.Safe(function() return DA.ItemId:ToString() end)
        if Id == "MakeshiftMuffler" or Id == "MakeshiftMuffler2" then return false end
        if type(Tag) == "string" and Tag ~= "" and Tag ~= "None" then return Tag == "Jig.ItemType.WeaponAttachment" end
        return P:find("/Attachments/", 1, true) ~= nil
    elseif Kind == "a" or Kind == "ad" then
        local Arm = I.Safe(function() return DA["IsArmor?"] end)
        if Arm == false then return false end
        if type(Tag) == "string" and Tag ~= "" and Tag ~= "None" then
            return Tag:sub(1, 22) == "Jig.ItemType.BodyArmor" or Tag:sub(1, 21) == "Jig.ItemType.Headwear"
        end
        return P:find("/Equipment/BodyArmor/", 1, true) ~= nil or P:find("/Equipment/Headwear/", 1, true) ~= nil
    end
    return true
end

-- Closeout (inv_rep_proof, Host): gezogenes Item bietet "Jig.ItemOverItem.RefillRadFilter" an (wie GetValid @0033-@0196,
-- @02b2: OverItemOptions des Dropped). P = Daten-Asset-Pfad aus dem Ledger (H.Dec E.P). Tags nicht lesbar -> Name "filter"
function I.RefillKitOk(P)
    if type(P) ~= "string" or P == "?" then return false end
    local DA = I.Safe(function() return StaticFindObject(P) end)
    local Hit, Read = false, false
    if I.Alive(DA) then
        Read = pcall(function()
            DA.OverItemOptions.GameplayTags:ForEach(function(_, T)
                if Hit then return true end
                if T:get().TagName:ToString() == "Jig.ItemOverItem.RefillRadFilter" then Hit = true end
            end)
        end)
    end
    if Read then return Hit end
    return I.Short(P):lower():find(K.REP_KIT.rf, 1, true) ~= nil
end

function I.HostRepair(J)
    local G = Net.Guests[J.Key]
    local Pawn = I.LivePawn(G)
    local GJ = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(GJ) then return end
    local Who = tostring(G.PCName or J.Key)
    local It = I.FindItem(GJ, J.U)
    if not It then I.WarnOnce("rpi" .. tostring(J.Key), "Reparatur von %s: Gegenstand nicht im Server-Inventar", Who) return end
    local Dur, Max = I.DurOf(It)
    if not (Dur and Max) or Max <= 0 then return end
    -- Review 1: Daten-Asset des Ziels jetzt lesen (vor jedem UFunction-Aufruf). HandleLocalRequestConsumeItem kann das
    -- Set per Array_Remove (@0662) aus demselben ContainerItems nehmen -> It zeigt danach auf ein anderes/freigegebenes Element
    local ItDA = I.Safe(function() return It[F.INFO][F.ID] end)
    local ItD = I.DAInfo(ItDA) or {}
    local ItP = ItD.P
    local Strict = I.On("inv_rep_strict")
    local Kit = I.FindItem(GJ, J.Kit)
    local KD = Kit and I.DAInfo(I.Safe(function() return Kit[F.INFO][F.ID] end))
    if J.K == "rf" and Strict then
        -- Review 1 (inv_rep_strict): Ziel = Receiver = DA_RadiationFilter, nicht voll (GetValid @09bf-@0a78). Kosten-Beleg:
        -- das Spiel verbraucht 1 Stueck des gezogenen Items selbst (RefillRadFilter @0229, RPC) -> Ledger-Abnahme dieser
        -- UID (H.Dec). Je verbrauchtem Stueck eine Fuellung; fehlt der Beleg, bis ~3 s neu einreihen (Ledger alle 0,5 s)
        if ItD.Nm ~= "da_radiationfilter" or Dur >= Max or J.Kit == J.U then Net.SecWarn(G, J.Key, "inv_rep_bad") return end
        local H = S.H[J.Key]
        local E = H and H.Dec and H.Dec[J.Kit]
        if not (E and E.N > 0 and os.clock() - E.T <= 15) then
            J.Tries = (J.Tries or 0) + 1
            if J.Tries <= 30 then S.RepQ[#S.RepQ + 1] = J else Net.SecWarn(G, J.Key, "inv_rep_bad") end
            return
        end
        -- Closeout (inv_rep_proof): Beleg nur von einem Filter-Nachfuellitem (sonst z. B. 1 Schuss Munition = Fuellung).
        -- Pfad aus dem Beleg, falls der Stapel aufgebraucht ist (Kit/KD nil)
        if I.On("inv_rep_proof") and not I.RefillKitOk(E.P or (KD and KD.P)) then
            Net.SecWarn(G, J.Key, "inv_rep_bad")
            return
        end
        E.N = E.N - 1
        if not pcall(function() GJ:ServerFunc_UpdateDurabilityByUID(It[F.UID], { X = Max, Y = Max }, {}) end) then return end
        Log("Filter von %s nachgefuellt (%.0f -> %.0f)", Who, Dur, Max)
        I.Audit(G, J.Key, ItP, string.format("%+.0f", Max - Dur), "repair rf")
        return
    end
    if J.K == "rf" then
        -- Filter: Ziel voll (RefillRadFilter @0036/@00fe); den Filter verbraucht das Spiel selbst (@0229, RPC). Beleg: Filter
        -- noch da oder gerade verschwunden (H.Gone)
        local H = S.H[J.Key]
        local Ok = (KD and KD.Nm:find("filter", 1, true) ~= nil)
            or (not Kit and H and H.Gone and H.Gone[J.Kit] ~= nil and os.clock() - H.Gone[J.Kit] <= 15)
        if not Ok then Net.SecWarn(G, J.Key, "inv_rep_bad") return end
        if not pcall(function() GJ:ServerFunc_UpdateDurabilityByUID(It[F.UID], { X = Max, Y = Max }, {}) end) then return end
        Log("Filter von %s nachgefuellt (%.0f -> %.0f)", Who, Dur, Max)
        I.Audit(G, J.Key, ItP, string.format("%+.0f", Max - Dur), "repair rf")
        return
    end
    if not KD then I.WarnOnce("rpk" .. tostring(J.Key), "Reparatur von %s: Set nicht im Server-Inventar", Who) return end
    if not KD.Nm:find(K.REP_KIT[J.K], 1, true) then Net.SecWarn(G, J.Key, "inv_rep_bad") return end
    -- Review 1 (inv_rep_strict): Ziel-Typ wie GetValid (sonst z. B. Reinigungs-Set laedt eine Batterie)
    if Strict and (J.Kit == J.U or not I.RepTargetOk(J.K, ItDA, ItP)) then Net.SecWarn(G, J.Key, "inv_rep_bad") return end
    local KX, KY = I.DurOf(Kit)
    if not (KX and KY) then return end
    local Red = tonumber(I.Safe(function() return Kit[F.INFO][F.ID].ReduceDurabilityAmount end)) or 1
    if Red <= 0 then Red = 1 end
    local Fix = math.max(0, math.min(Max - Dur, KX))
    if Fix <= 0 then return end
    local NewItem = math.min(math.max(Dur + Fix, 0), Max)
    local NewKit = KX - Fix / (J.K == "t" and 2 or 1) / Red
    local ok, err = pcall(function()
        GJ:ServerFunc_UpdateDurabilityByUID(It[F.UID], { X = NewItem, Y = Max }, {})
        GJ:ServerFunc_UpdateDurabilityByUID(Kit[F.UID], { X = NewKit, Y = KY }, {})
    end)
    if not ok then Core.Fail("inv_repair", err) return end
    -- Set aufgebraucht (Spiel @08cc: <= 1 -> Verbrauch). Beim Gast las das Spiel die alte Anzeige: war die schon <= 1,
    -- hat der Gast den Verbrauch selbst geschickt (RPC) -> hier nur, wenn erst diese Reparatur das Set leert
    local Used = ""
    if NewKit <= 1 and KX > 1 then
        local K2 = I.FindItem(GJ, J.Kit)
        if K2 and pcall(function() GJ:HandleLocalRequestConsumeItem(K2[F.UID], 1, GJ, "", false) end) then Used = ", Set verbraucht" end
    end
    -- Review 1: It nach dem Verbrauch nicht mehr anfassen (ItP oben gelesen)
    Log("Reparatur (%s) fuer %s: %s %.0f -> %.0f/%.0f, %s %.1f -> %.1f%s", J.K, Who, I.Short(ItP),
        Dur, NewItem, Max, I.Short(KD.P), KX, NewKit, Used)
    I.Audit(G, J.Key, ItP, string.format("%+.0f", NewItem - Dur), "repair " .. J.K .. Used)
end

-- Host 0,1 s: Reparatur-Auftraege (Handler reihen nur ein)
function I.HostRepairs()
    local Q = S.RepQ
    S.RepQ = {}
    for _, J in ipairs(Q) do I.Try("inv_repair", I.HostRepair, J) end
end

-- Host 0,1 s: Warteschlange der Runde-8-Anfragen (Handler reihen nur ein)
function I.HostScav()
    if #S.ScavQ == 0 then return end
    local Q = S.ScavQ
    S.ScavQ = {}
    for _, J in ipairs(Q) do
        if J.T == "l" then I.Try("inv_scavxp", I.LootXP, J)
        elseif J.T == "u" then I.Try("inv_unmark", I.Unmark, J)
        elseif J.T == "t" and not I.On("inv_toolxp") then I.ToolFallback(Net.Guests[J.Key], J.N)
        elseif J.T == "t" then I.Try("inv_toolxp", I.ToolOne, J)
        elseif J.T == "s" then I.Try("inv_scavxp", I.ScavOne, J) end
    end
end

function I.HostTraders(Locs)
    for _, E in ipairs(I.TraderList(os.clock())) do
        -- wandernde Haendler nicht: der Positions-Schluessel waere mit jeder Bewegung neu (Geld kommt ueber trd_m)
        local Near = false
        for _, L in ipairs(E.Wd and {} or Locs) do
            if I.Dist2(L, E.X, E.Y, E.Z) <= K.TRADER_RADIUS * K.TRADER_RADIUS then Near = true break end
        end
        if Near then
            local O = I.Fresh(E)
            local V = O and I.Safe(function()
                local Jig = O.BP_JigMultiplayer
                return I.Alive(Jig) and Jig.VendorCurrentCurrencyAmount or nil
            end)
            if tonumber(V) then Net.State("inv_trader", E.K, string.format("%.0f", tonumber(V)), 2) end
        end
    end
end

-- Admin-give aus dem Cheat-Menue: der Klick legt beim Gast trotzdem lokal an (ItemButton-Ubergraph @06b0
-- JigTryAddItemSomewhere -> Platzhalter in PendingRequests; der Vor-Hook verhindert das nicht). Gutschrift je
-- Daten-Asset: I.Decide loest diesen Platzhalter als "had" auf statt ihn per (e) Admin ein zweites Mal anzulegen.
function I.GiveCredit(H, Asset, N, Now)
    local D = I.DAInfo(Asset)
    if not D or D.P == "?" then return end
    H.GiveCr = H.GiveCr or {}
    local E = H.GiveCr[D.P]
    if not E or Now - E.T > K.GIVE_TTL then E = { N = 0 } H.GiveCr[D.P] = E end
    E.N, E.T = math.min(E.N + N, 1000), Now
end

-- Runde 9 INV-12b: Standard-Anbauteile eines Item-Daten-Assets (DefaultAttachments: ID_21 = Daten-Asset, MinCount_31) als
-- Pfade, einmal je Auftrag gelesen (keine UObjects ueber Ticks). nil = keine
function I.DefAtt(J, Asset)
    if J.Att == nil then
        local L = {}
        pcall(function()
            Asset.DefaultAttachments:ForEach(function(_, E)
                if #L >= 8 then return true end
                local V = E:get()
                local DA = V[K.ATT_ID]
                local P = I.Alive(DA) and I.Path(DA) or nil
                if P then L[#L + 1] = { P = P, N = math.max(1, math.min(math.floor(tonumber(V[K.ATT_MIN]) or 1), 100)) } end
            end)
        end)
        J.Att = L
    end
    return #J.Att > 0 and J.Att or nil
end

-- Admin-give ins Inventar (Warteschlange, im Host-Task abgearbeitet)
function I.HostGive(Now)
    if #S.GiveQ == 0 then return end
    local Q = S.GiveQ
    S.GiveQ = {}
    for _, J in ipairs(Q) do
        local G = Net.Guests[J.Key]
        local Pawn = G and I.HostPawn(G)
        local Comp = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
        local Asset = I.Alive(Comp) and I.ItemAsset(J.Path)
        local Text
        J.Until = J.Until or Now + 120
        if G and G.Epoch and (not I.Alive(Comp) or Now < (J.At or 0)) and Now < J.Until then
            S.GiveQ[#S.GiveQ + 1] = J                            -- Gast tot/Respawn/Laden: bis 120 s nachholen
        elseif not Asset then
            Text = "give: kein Spieler oder Gegenstand"
            Log("[Admin] give FEHLT: %dx %s an %s nicht zugestellt", J.N, I.Short(J.Path), tostring(J.Key):match("([^%.]+)$") or "?")
        else
            -- Stapel je Aufruf nach den Grenzen des Items (AddNewItemSomewhere klemmt neue Items nicht auf MaxStack);
            -- hoechstens 25 Aufrufe je Durchlauf, der Rest folgt im naechsten Host-Task (insgesamt max. 1000)
            local Stack = 1
            if I.Safe(function() return Asset["CanStack?"] end) == true then
                Stack = math.max(1, math.floor(tonumber(I.Safe(function() return Asset.MaxStack end)) or 1))
            end
            local Left, Given, Dropped, Calls, Err = J.N, J.Given or 0, J.Dropped or false, 0, false
            local Hs = I.HState(J.Key)
            -- Runde 9 INV-12b (cheat_defatt): Standard-Anbauteile je nicht gestapeltem Item wie der Cheat-Knopf im
            -- Einzelspiel (ItemButton @0060-@02f2 DefaultAttachments), hier ins Inventar statt montiert (kein Spiel-Struct)
            local Att = Stack == 1 and I.On("cheat_defatt") and I.DefAtt(J, Asset) or nil
            while Left > 0 and Given < 1000 and Calls < 25 do
                local N = math.min(Left, Stack, 100)
                local R = I.AddFor(Pawn, Asset, N, Hs)
                Calls = Calls + 1
                if R == "fehler" then Err = true break end
                -- Runde 9 E7/INV-13: "give <Pfad> <n> rm" - main.lua hat die Cheat-Platzhalter schon entfernt -> keine
                -- GiveCredit (sie schluckte sonst 30 s lang echte Platzhalter desselben Daten-Assets)
                if R == "drop" then Dropped = true elseif I.On("inv_givecr") and not J.NoCredit then I.GiveCredit(Hs, Asset, N, Now) end
                I.Audit(G, J.Key, J.Path, N, R == "drop" and "give (Boden)" or "give")
                Given, Left = Given + N, Left - N
                if Att and R:match("^ok|%x+$") then
                    for _, E in ipairs(Att) do
                        local AA = I.ItemAsset(E.P)
                        local R2 = AA and I.AddFor(Pawn, AA, E.N, Hs) or "fehler"
                        Calls = Calls + 1
                        if R2 ~= "fehler" then
                            J.AttN = (J.AttN or 0) + E.N
                            I.Audit(G, J.Key, E.P, E.N, "give (Anbauteil)")
                        end
                    end
                end
            end
            -- Fehler: Rest bis zu 3x im naechsten Durchlauf (innerhalb J.Until) erneut, danach FEHLT-Meldung
            if Err then
                J.Err, J.At = (J.Err or 0) + 1, Now + 2
                if J.Err > 3 or Now >= J.Until then
                    Log("[Admin] give FEHLT: %dx %s an %s nicht zugestellt (AddNewItemSomewhere)", Left, I.Short(J.Path),
                        tostring(J.Key):match("([^%.]+)$") or "?")
                    Left = 0
                end
            end
            if Left > 0 and Given < 1000 then
                J.N, J.Given, J.Dropped = Left, Given, Dropped     -- Rest im naechsten Durchlauf (Text bleibt nil)
                S.GiveQ[#S.GiveQ + 1] = J
            else
                Text = string.format("Given %dx %s%s%s", Given, I.Short(J.Path),
                    J.AttN and string.format(" (+%d Anbauteile)", J.AttN) or "", Dropped and " (Inventar voll: am Boden)" or "")
            end
        end
        if Text then
            Log("[Admin] give %s -> %s", tostring(J.Key):match("([^%.]+)$") or "?", Text)
            if G and G.Epoch then Net.Send("inv_note", Text, G, 1) end
        end
    end
end

-- inv_gain_host (Host): vorgemerkte Rueckgabe-Items, deren Gutschrift nach 2,5 s noch offen ist (kein Platzhalter des
-- Gasts kam), selbst anlegen und die Gutschrift verbrauchen. Ohne H an I.AddFor: der Zuwachs zaehlt als "had" -> ein
-- spaeterer Platzhalter wird nur entfernt (kein Doppel).
I.GAIN_WAIT = 2.5
function I.GainTick(G, H, Pawn, Now)
    local Q = H.GainQ
    while Q and Q[1] and Now - Q[1].T >= I.GAIN_WAIT do
        local E = table.remove(Q, 1)
        -- Stapel teilen/umstapeln: dieselbe Sorte waechst im selben Moment (H.Inc) -> kein Verbrauch, nichts anlegen
        local Inc = H.Inc and E.Src and H.Inc[E.Src]
        local Moved = Inc and Inc.T and math.abs(Inc.T - E.T) <= 1.5
        local Cr = not Moved and H.Credit[E.Gn] or nil
        local N = Cr and Now - Cr.T <= K.CREDIT_TTL + I.GAIN_WAIT and math.min(E.N, Cr.N) or 0
        if N > 0 then
            local Asset = I.ItemAsset(E.Gn, true)
            local R = Asset and I.AddFor(Pawn, Asset, N, nil) or "fehler"
            if R ~= "fehler" then Cr.N = Cr.N - N end
            Log("%s: Rueckgabe %s x%d ohne Platzhalter vom Host angelegt (%s)", tostring(G.PCName or G.Key), I.Short(E.Gn), N, tostring(R))
        end
    end
end

function I.HostFast(Now)
    if Net.Side ~= "host" or I.Loading() then return end
    I.CheckGen()
    local V2b = I.On("inv_v2b")
    if V2b and I.On("inv_give") then I.Try("inv_give", I.HostGive, Now) end
    if V2b and I.On("inv_lootprime") then I.Try("inv_lootprime", I.HostPrime, Now) end
    if V2b and #S.ScavQ > 0 then I.HostScav() end                      -- Runde 8: XP/Lager-Aufhebung (je Auftrag I.Try)
    if V2b and #S.RepQ > 0 then I.HostRepairs() end                    -- Runde 9 INV-4: Reparaturen (je Auftrag I.Try)
    local DoLedger = Now >= (S.LedgerAt or 0)
    if DoLedger then S.LedgerAt = Now + math.max(0.2, (tonumber(Core.Flag("inv_ledger_ms", 500)) or 500) / 1000) end
    if DoLedger and (S.DropU or S.DropAt or S.GuestComp) then I.DropPrune(Now) end -- Closeout inv_cons_nodrop (+R3)
    Net.ForEachGuest(function(G, Key)
        if not (G.Epoch and G.Ready) then return end
        local H = S.H[Key]
        if not DoLedger and not (H and (#H.PendQ > 0 or (H.Defer and #H.Defer > 0))) then return end
        local Pawn = I.HostPawn(G)
        if not Pawn then return end
        if DoLedger and (I.On("inv_v2a") or V2b) then H = I.Ledger(G, Key, Pawn, Now) end
        H = H or I.HState(Key)
        if V2b and I.On("inv_pend") then I.Try("inv_pend", I.HostPend, G, Key, H, Pawn, Now) end
        if V2b and H.Defer and #H.Defer > 0 then I.Try("inv_pend", I.HostDefer, G, Key, H, Pawn, Now) end
        if H.GainQ and #H.GainQ > 0 then I.Try("inv_gain_host", I.GainTick, G, H, Pawn, Now) end
    end)
end

function I.HostSlow(Now)
    if Net.Side ~= "host" or I.Loading() then return end
    I.CheckGen()
    local V2a, V2b, Locs = I.On("inv_v2a"), I.On("inv_v2b"), {}
    Net.ForEachGuest(function(G, Key)
        if not (G.Epoch and G.Ready) then return end
        local Pawn = I.HostPawn(G)
        if not Pawn then return end
        local L = I.Loc(Pawn)
        if L then Locs[#Locs + 1] = L end
        local H = I.HState(Key)
        if V2a and (I.On("inv_bar") or I.On("inv_aw")) then I.Try("inv_bar", I.HostBar, G, Key, H, Pawn, Now) end
        if V2b and I.On("inv_crep") and L then I.Try("inv_crep", I.HostRep, L) end
    end)
    if V2b and I.On("inv_lflag") then I.Try("inv_lflag", I.HostLootRefill, Now) end
    if V2b and I.On("inv_trader") and #Locs > 0 then I.Try("inv_trader", I.HostTraders, Locs) end
    if V2b and I.On("inv_netrep") and #Locs > 0 then I.Try("inv_netrep", I.HostNetRep, Locs) end
    -- Runde 7: Haendler adressierbar; trd_cfg rt=1 = Host repliziert seine Laufzeit-Haendler (Gast entfernt Geister)
    if I.TrdOn("trd_addr") then
        Net.State("trd_cfg", "rt", "1", 2)
        if #Locs > 0 then I.Try("trd_addr", I.TrdAddr, Locs, Now) end
    else
        Net.State("trd_cfg", "rt", nil, 2)
    end
    -- Runde 9 Welle 2 (inv-2)
    if V2b and I.On("inv_refill_hold") then I.Try("inv_refill_hold", I.RefillHold, Now) end      -- INV-19
    if V2b and I.On("inv_battery_drain") then I.Try("inv_battery_drain", I.LightHost, Now) end   -- INV-6b
    if V2b and I.On("inv_flash_guard") then I.Try("inv_flash_guard", I.FlashGuard, Now) end      -- Review 1 (B) eigenstaendig
    S.DropFast = I.On("inv_dropfast")
    S.ConsNoDrop = I.On("inv_cons_nodrop")                                                        -- Closeout
    if S.DropFast or S.ConsNoDrop then                                                            -- INV-28
        I.Try(S.DropFast and "inv_dropfast" or "inv_cons_nodrop", I.DropHook, Now)
    end
    S.ConsNoMove = I.On("inv_cons_nomove")                                                        -- Closeout R2
    S.ConsNoMoveAny = S.ConsNoMove and I.On("inv_cons_nomove_any")                                -- Closeout R3
    if S.ConsNoDrop and S.ConsNoMove then I.Try("inv_cons_nomove", I.MoveHooks, Now) end
    if Core.Flag("world_hygiene", true) == true and I.On("inv_prune") then I.Try("inv_prune", I.Prune, Now) end  -- CORE-30
    if S.AuditQ then I.Try("inv_audit_log", I.AuditFlush) end                                     -- X-INV1
end

-- ---------------------------------------------------------------------------------------------- Runde 9 Welle 2 (Host)

-- X-INV1: Regel-Buchstabe zur Begruendung aus I.Decide (a-g wie im Kopf von I.Decide)
function I.Rule(Why)
    local L = ({ Rest = "b", Budget = "c", Ernte = "d", Admin = "e", Boden = "f", Leiche = "g" })[tostring(Why)]
    return L and (L .. "/" .. Why) or tostring(Why)
end

-- X-INV1 (inv_audit_log, Host): eine Zeile je vom Host angelegtem oder korrigiertem Item (Zeit, Gast-ID, Name, Daten-Asset,
-- Menge, Regel), damit Dupes nachvollziehbar sind. Nur Tabelle; I.AuditFlush haengt einmal je Sekunde an
-- NetTest_Guests\audit_<Datum>.log an (Protokoll, keine Austausch-Datei)
function I.Audit(G, Key, P, N, Rule)
    if Net.Side ~= "host" or not I.On("inv_audit_log") then return end
    local Q = S.AuditQ or {}
    S.AuditQ = Q
    if #Q >= 500 then return end
    local Id = (G and G.GuestId) or (A.Coop.GuestIds and Key and A.Coop.GuestIds[Key]) or "?"
    local Who = (G and G.PCName) or tostring(Key or "?"):match("([^%.]+)$") or "?"
    Q[#Q + 1] = string.format("%s\t%s\t%s\t%s\t%s\t%s", os.date("%H:%M:%S"), tostring(Id), tostring(Who), tostring(P),
        tostring(N), tostring(Rule))
end

-- Ordner der Gast-Spielstaende: server.lua J.Dir (E32), sonst SaveGames\NetTest_Guests des Spiels (Listen-Host)
function I.GuestDir()
    local Srv = A.Settings and A.Settings.server
    local J = type(Srv) == "table" and type(Srv.Journal) == "table" and Srv.Journal or nil
    if J and type(J.Dir) == "function" then
        local ok, D = pcall(J.Dir)
        if ok and type(D) == "string" and D ~= "" then return D end
    end
    local L = os.getenv("LOCALAPPDATA")
    return L and (L .. "\\SurrounDead\\Saved\\SaveGames\\NetTest_Guests\\") or nil
end

function I.AuditFlush()
    local Q = S.AuditQ
    S.AuditQ = nil
    if not Q or #Q == 0 then return end
    local Dir = I.GuestDir()
    local File = Dir and io.open(Dir .. "audit_" .. os.date("%Y%m%d") .. ".log", "a")
    if not File then
        I.WarnOnce("audit_io", "Item-Protokoll: %s nicht beschreibbar - %d Zeilen verworfen", tostring(Dir), #Q)
        return
    end
    File:write(table.concat(Q, "\n"), "\n")
    File:close()
end

-- INV-19 (inv_refill_hold, Host): ProcessRefillContainer @0021 prueft nur die UI des Hosts (IsInventoryVisible?) ->
-- ClearContainer(true) leert eine Kiste, die ein Gast gerade offen hat (Items verschwinden, Verschieben scheitert).
-- Solange ein Gast sie offen hat (inv_open) bzw. bis 10 s nach einem Prime: DoesContainerRefillLoot? = false
-- (ProcessRefillContainer @0000 tut dann nichts); danach alter Wert + StartRefillTimer(false) (Nachfuellen spaeter, wie
-- HoldToInteract @0314). Nie bei Lager-Kisten (inv_lflag "2" / MarkedAsStorageContainer)
function I.RefillHold(Now)
    local Want = {}
    for Name, O in pairs(S.Open) do
        local G = Net.Guests[O.Key]
        local Pawn = G and I.HostPawn(G)
        local L = Pawn and I.Loc(Pawn)
        if L then
            for _, E in ipairs(I.NearConts(L, 1500, 64)) do
                if E.N == Name then Want[E.F] = true break end
            end
        end
    end
    for F, T in pairs(S.PrimeHold) do
        if Now < T then Want[F] = true else S.PrimeHold[F] = nil end
    end
    for F in pairs(Want) do
        if S.RefHold[F] == nil then
            local O = I.Safe(function() return StaticFindObject(F) end)
            -- Review 1: StaticFindObject liefert bei unaufloesbarem Pfad einen ungueltigen Wrapper -> jede Eigenschaft nur bei I.Alive(O)
            local OAlive = I.Alive(O)
            local Jig = OAlive and I.Safe(function() return O.BP_JigMultiplayer end) or nil
            local Store = (S.LState[F] and S.LState[F].St == "2")
                or (OAlive and I.Safe(function() return O.MarkedAsStorageContainer end) == true)
            if I.Alive(Jig) and not Store and I.Safe(function() return Jig["DoesContainerRefillLoot?"] end) == true
                and pcall(function() Jig["DoesContainerRefillLoot?"] = false end) then
                S.RefHold[F] = Now
            else
                S.RefHold[F] = false                          -- keine Nachfuell-Kiste: nichts zurueckzusetzen
            end
        end
    end
    for F, At in pairs(S.RefHold) do
        if not Want[F] then
            S.RefHold[F] = nil
            local O = At and I.Safe(function() return StaticFindObject(F) end) or nil
            local Jig = I.Alive(O) and I.Safe(function() return O.BP_JigMultiplayer end) or nil
            -- inzwischen Lager geworden (inv_loot "2" setzt das Flag selbst auf false): aus lassen
            if I.Alive(Jig) and not (S.LState[F] and S.LState[F].St == "2")
                and I.Safe(function() return O.MarkedAsStorageContainer end) ~= true then
                pcall(function() Jig["DoesContainerRefillLoot?"] = true end)
                pcall(function() Jig:StartRefillTimer(false) end)
            end
        end
    end
end

-- INV-6b (inv_battery_drain, Host).
-- (B) Taschenlampen-Slot: der Host entlaedt selbst (Svr_Flashlight -> MC_Flashlight laeuft auch beim Server ->
--     FlashlightToggle -> Batterie-Timer, UseBattery auf der Server-Kopie; bei 0 MC_Flashlight(false)). Ist die Lampe an
--     (FlashlightOn?), laeuft der Server-Timer aber nicht (Batterie leer/fehlt: CheckBatteryLevel @01e6), bliebe sie beim
--     Gast mit Batterie-Patch an -> fuer alle aus wie das Spiel (MC_Flashlight(false), Server-Autoritaet)
-- (C) Waffenlicht/Entfernungsmesser (lokale Anbauteile, laufen nur beim Gast): gemeldete Lampe (inv_light) entladen wie
--     UseBattery (Rate x Difficulty.BatteryDepletionMultiplier), leer/ohne Batterie -> inv_lightoff
-- Review 1: (B) ist jetzt I.FlashGuard (eigener Schalter inv_flash_guard, unabhaengig von inv_battery_drain/Cap invlt:
-- der Gast-Patch inv_batt_c/d haengt nicht an invlt, sonst bliebe eine leere Taschenlampe bei drain=0/FLAG_DOWN ewig an)
function I.LightHost(Now)
    if not I.On("inv_flash_guard") then I.FlashGuard(Now) end      -- Schalter aus: alter Weg (B) hier wie bisher
    I.LightAtt(Now)
end

-- (B) Host 1 s (inv_flash_guard): Taschenlampe eines Gasts an, Server-Batterie-Timer laeuft nicht -> nach 1 s fuer alle aus
function I.FlashGuard(Now)
    Net.ForEachGuest(function(G, Key)
        if not (G.Epoch and G.Ready) then return end
        local Pawn = I.HostPawn(G)
        if not Pawn then return end
        local H = I.HState(Key)
        local On = I.Safe(function() return Pawn["FlashlightOn?"] end) == true
        local Hd = On and tonumber(I.Safe(function() return Pawn.BatteryTimerFlashlight.Handle end)) or nil
        if Hd ~= 0 then H.FlOff = nil return end
        H.FlOff = H.FlOff or Now
        if Now - H.FlOff < 1 then return end
        H.FlOff = nil
        if pcall(function() Pawn:MC_Flashlight(false) end) then
            Log("Taschenlampe von %s aus: Batterie leer oder fehlt (Server-Timer laeuft nicht)", tostring(G.PCName or Key))
        end
    end)
end

-- (C) Host 1 s (inv_battery_drain): gemeldete Waffenlichter/Entfernungsmesser entladen
function I.LightAtt(Now)
    for Key, L in pairs(S.Light) do
        local G = Net.Guests[Key]
        local Pawn = G and G.Epoch and I.HostPawn(G)
        local GJ = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
        if not G then
            S.Light[Key] = nil
        elseif I.Alive(GJ) then
            for U, E in pairs(L) do
                if Now - E.At > K.LIGHT_TTL then
                    L[U] = nil
                else
                    local Dt = math.min(math.max(Now - (E.Last or Now), 0), 2)
                    E.Last = Now
                    if Dt > 0 then I.LightDrain(G, Key, GJ, U, Dt) end
                end
            end
            if not next(L) then S.Light[Key] = nil end
        end
    end
end

-- INV-6b: Batterie-Item (Struktur aus dem Spiel) zu einer gemeldeten UID im Server-Inventar des Gasts: die Batterie selbst
-- oder - wie UseBattery @0056 (SubContainers[0], Index 0) - das Batterie-Item im Container, der in der Lampe steckt
-- (InContainerUID). Rueckgabe Item|nil, Grund ("weg" = kein eigenes Item, "leer" = keine Batterie), Kurzname der Lampe
function I.BattItem(GJ, U)
    local It = I.FindItem(GJ, U)
    if not It then return nil, "weg" end
    local D = I.DAInfo(I.Safe(function() return It[F.INFO][F.ID] end))
    if D and D.Nm:find("battery", 1, true) then return It, nil, nil end
    local Hex = I.Hex(It[F.UID])
    local Found
    GJ.MainJigContainers:ForEach(function(_, CE)
        if Found then return true end
        local Cont = CE:get()
        if not Hex or I.Safe(function() return I.Hex(Cont[K.INCONT]) end) ~= Hex then return end
        Cont[F.ITEMS]:ForEach(function(_, IE)
            local B = IE:get()
            local BD = I.DAInfo(I.Safe(function() return B[F.INFO][F.ID] end))
            if BD and BD.Nm:find("battery", 1, true) then Found = B return true end
        end)
    end)
    return Found, Found == nil and "leer" or nil, D and D.Nm
end

function I.LightDrain(G, Key, GJ, U, Dt)
    local Batt, Why, Lamp = I.BattItem(GJ, U)
    local Dur = Batt and I.DurOf(Batt)
    if not Batt or not Dur or Dur <= 0 then
        S.Light[Key][U] = nil
        if Why == "weg" then return end                       -- kein eigenes Item (fremde Waffe): nichts schalten
        if Net.Has("invlt", G) then Net.Send("inv_lightoff", U, G, 1) end
        I.WarnOnce("lo" .. U, "Lampe %s von %s: Batterie %s - aus", tostring(Lamp or I.Short(U)), tostring(G.PCName or Key),
            Batt and "leer" or "fehlt")
        return
    end
    local Mult = tonumber(I.CVar("f", "Difficulty.BatteryDepletionMultiplier")) or 1
    local Amt = ((Lamp and Lamp:find("rangefinder", 1, true)) and K.RF_RATE or K.LIGHT_RATE) * Dt * Mult
    if Amt <= 0 then return end
    local T = {}
    if not pcall(function() GJ:ServerFuncUpdateDurabilityByUID(Batt[F.UID], Amt, false, T) end) then return end
    local New = tonumber(I.Out(T, "NewDur")) or (Dur - Amt)
    if New <= 0 then
        S.Light[Key][U] = nil
        if Net.Has("invlt", G) then Net.Send("inv_lightoff", U, G, 1) end
        Log("Lampe %s von %s: Batterie leer - aus", tostring(Lamp or "?"), tostring(G.PCName or Key))
    end
end

-- CORE-30 (world_hygiene, Host): Pfad-Tabellen wachsen auf dem Dedicated Server ohne Weltwechsel. Alle 60 s eine Liste,
-- je Lauf hoechstens 300 Pruefungen: Eintraege verschwundener Objekte weg (S.ScavDone inkl. Airdrop "Pfad|Gid", S.TrdRep,
-- S.TrdTid). S.AddrAt nur nach Alter (> 1 h) und nur bei verschwundenem Objekt (eine neue "erste Sicht" eines lebenden,
-- laengst adressierbaren Objekts liesse sonst einen Prime = zweite Daten-Antwort zu). Je-Gast-Tabellen: "gone"-Handler
function I.Prune(Now)
    local L = S.PruneL
    if not (L and #L > 0) then
        if Now < (S.PruneAt or 0) then return end
        S.PruneAt, L, S.PruneN = Now + 60, {}, 0
        for P in pairs(S.ScavDone) do L[#L + 1] = { "s", P } end
        for P in pairs(S.TrdRep) do L[#L + 1] = { "r", P } end
        for P in pairs(S.TrdTid) do L[#L + 1] = { "t", P } end
        for P, T in pairs(S.AddrAt) do if Now - T > 3600 then L[#L + 1] = { "a", P } end end
        S.PruneL = L
    end
    local Tabs = { s = S.ScavDone, r = S.TrdRep, t = S.TrdTid, a = S.AddrAt }
    for _ = 1, 300 do
        local E = table.remove(L)
        if not E then break end
        local Tab, P = Tabs[E[1]], E[2]
        if Tab[P] ~= nil then
            local O = I.Safe(function() return StaticFindObject(P:match("^([^|]+)|") or P) end)
            if not I.Alive(O) then Tab[P], S.PruneN = nil, S.PruneN + 1 end
        end
    end
    if #L == 0 and S.PruneN > 0 then
        Log("Aufraeumen: %d Eintraege verschwundener Objekte entfernt", S.PruneN)
        S.PruneN = 0
    end
end

-- INV-28 (inv_dropfast, Host): Abgelegtes war bis zu 3 s fuer alle unsichtbar (main.lua L.HostTick repliziert Pickups nur
-- alle 3 s). Hook (selten: Ablegen) auf SERVER_RequestDropItem, Koerper setzt nur Coop.Loot.At = 0 -> der naechste
-- L.HostTick (Hauptschleife) repliziert gleich. Neu gesetzt bei geaenderter Funktions-Adresse (neu geladen)
function I.DropHook(Now)
    if Now < (S.DropHkAt or 0) then return end
    S.DropHkAt = Now + 5
    local F0 = I.Safe(function() return StaticFindObject(K.JIG_DROP) end)
    local Addr = I.Alive(F0) and I.Safe(function() return F0:GetAddress() end) or nil
    if not Addr or S.DropHk == Addr then return end
    -- Review 1: SERVER_RequestDropItem ist eine BP-Funktion (Script-Hook): UE4SS 3.0.1 ruft nur den ERSTEN Callback auf,
    -- und zwar nach dem BP-Rumpf (main.lua:7824) -> Koerper als beide Callbacks (idempotent, nur Tabelle)
    local Body = function(Ctx, ItemUID)
        if S.DropFast then
            local L = A.Coop and A.Coop.Loot
            if type(L) == "table" then L.At = 0 end
        end
        -- Closeout (inv_cons_nodrop): Abwurf merken (nur lesen + Tabelle), I.Ledger zaehlt ihn nicht als Verbrauch.
        -- Ctx = anfragende Gast-Komponente (EVT_SERVER_RequestDropItem: CompTarget->HandleServerDropRequest(ItemUID,
        -- Count, self)); HandleServerDropRequest entfernt synchron (RemoveGetInfo @05b0), der Hook laeuft danach
        if S.ConsNoDrop then
            local Now = os.clock()
            local U = ItemUID and I.Hex(I.Safe(function() return ItemUID:get() end))
            if U and U ~= K.ZERO then
                -- Gast-Text (RPC-Parameter) -> Tabelle begrenzt (I.DropPrune raeumt nach 10 s)
                if (S.DropUN or 0) >= 512 then S.DropU, S.DropUN = {}, 0 end
                S.DropU = S.DropU or {}
                S.DropU[U], S.DropUN = Now, (S.DropUN or 0) + 1
            else
                -- UID unlesbar: Ersatz-Merker je Komponente (ein Ledger-Lauf, dann alle Abnahmen dieses Laufs)
                local C = Ctx and I.Safe(function() return Ctx:get() end)
                if I.Alive(C) then
                    local okA, Ad = pcall(function() return C:GetAddress() end)
                    if okA and Ad then S.DropAt = S.DropAt or {}; S.DropAt[Ad] = Now end
                end
            end
        end
    end
    local R = A.TryHook(K.JIG_DROP, Body, Body)
    if R then
        S.DropHk = Addr
        Log("Hook aktiv (Runde 9): SERVER_RequestDropItem (%s)", S.ConsNoDrop and
            (S.DropFast and "Abgelegtes sofort sichtbar, Abwurf kein Verbrauch" or "Abwurf kein Verbrauch") or
            "Abgelegtes sofort sichtbar")
    end
end

-- Closeout R2 (inv_cons_nomove, Host, braucht inv_cons_nodrop): Umlagern/Teilen/Stapeln aus dem eigenen Inventar in eine
-- andere Komponente (Kiste, Kofferraum, Haendler-Verkauf) ist kein Verbrauch und kein Filter-Beleg (inv_rep rf). Handle
-- @0728 RemoveGetInfo auf From, @0ce0/@0ee9 auf To (Haendler @0211-@0567); ServerHandleSplitRequest @0319/@01ed;
-- ServerFunc_RequestStackItem @08b5/@0915. Seltene Nutzer-RPCs; Koerper liest nur Parameter und merkt die UID in S.DropU
-- wie der Abwurf-Hook (I.DropCtx/I.DropHit unveraendert: ein RPC = eine Marke = eine Abnahme)
function I.MoveHooks(Now)
    if not (S.ConsNoDrop and S.ConsNoMove) or Now < (S.MoveHkAt or 0) then return end
    S.MoveHkAt = Now + 5
    S.MoveHk = S.MoveHk or {}
    -- Ctx = Komponente, auf der das RPC laeuft: normale Gaeste rufen auf GetLocalComp = eigene Figur-Komponente
    -- (Jig_UnhandledEvent @0dc7, OnItemStackRequest_Event @338a, HandleDropRequest @2eca). Nur merken, wenn das Stueck
    -- eine Gast-Komponente verlaesst (To anders); Herausnehmen aus Kiste/Kauf (From = Kiste/Haendler, @2b88) bleibt
    -- ungemerkt (sonst zaehlte echter Verbrauch kurz danach nicht). Closeout R3 (inv_cons_nomove_any): das Spiel entfernt
    -- aus From, nicht aus self (EVT_SERVER_RequestMoveItemToAnotherComp @5867 -> Handle, RemoveGetInfo @0728 auf From).
    -- Ein veraenderter Gast als Owner einer Kiste/eines Kofferraums (ls_build SetOwner(Pawn), ls_car SetOwner(PC)) ruft
    -- das RPC auf deren Komponente mit From = eigenes Inventar -> From genuegt, wenn es eine Gast-Figur-Komponente ist
    -- (S.GuestComp aus I.Ledger), sonst wie bisher nur From = Ctx. Wie I.DropHook: Koerper als beide Callbacks
    local Body = function(Ctx, From, To, ItemUID)
        if not (S.ConsNoDrop and S.ConsNoMove) then return end
        local Fr = From and I.Safe(function() return From:get() end)
        if not I.Alive(Fr) then return end
        local Af = I.Safe(function() return Fr:GetAddress() end)
        if not Af then return end
        local Mine = S.ConsNoMoveAny == true and S.GuestComp ~= nil and S.GuestComp[Af] ~= nil
        if not Mine then
            local Cc = Ctx and I.Safe(function() return Ctx:get() end)
            Mine = I.Alive(Cc) and I.Safe(function() return Cc:GetAddress() end) == Af
        end
        if not Mine then return end
        local Tc = To and I.Safe(function() return To:get() end)
        local At = I.Alive(Tc) and I.Safe(function() return Tc:GetAddress() end) or nil
        if At == Af then return end
        local U = ItemUID and I.Hex(I.Safe(function() return ItemUID:get() end))
        if not U or U == K.ZERO then return end
        -- Gast-Text (RPC-Parameter) -> Tabellen begrenzt (I.DropPrune raeumt nach 10 s)
        if (S.DropUN or 0) >= 512 then S.DropU, S.DropUN, S.MoveU = {}, 0, {} end
        S.DropU, S.MoveU = S.DropU or {}, S.MoveU or {}
        local T = os.clock()
        S.DropU[U], S.DropUN, S.MoveU[U] = T, (S.DropUN or 0) + 1, T
    end
    for _, P in ipairs(K.JIG_MOVE) do
        local F1 = I.Safe(function() return StaticFindObject(P) end)
        local A1 = I.Alive(F1) and I.Safe(function() return F1:GetAddress() end) or nil
        if A1 and S.MoveHk[P] ~= A1 and A.TryHook(P, Body, Body) then
            S.MoveHk[P] = A1
            Log("Hook aktiv (Closeout): %s (Umlagern in andere Komponente kein Verbrauch, inv_cons_nomove)",
                tostring(P:match(":(.+)$")))
        end
    end
end

-- Closeout (inv_cons_nodrop, Host): Abwurf-Kontext fuer einen Ledger-Lauf (Comp = BP_JigMultiplayer des Gasts, lebt).
-- nil = Schalter aus oder kein Abwurf gemerkt. Fenster W = ein Ledger-Takt (inv_ledger_ms) + 1 s, Standard 1,5 s
function I.DropCtx(Comp)
    local HasU, HasA = S.DropU ~= nil and next(S.DropU) ~= nil, S.DropAt ~= nil and next(S.DropAt) ~= nil
    if not (HasU or HasA) or not I.On("inv_cons_nodrop") then return nil end
    local Ad = HasA and I.Safe(function() return Comp:GetAddress() end) or 0
    return { Ad = Ad, W = math.max(1.5, (tonumber(Core.Flag("inv_ledger_ms", 500)) or 500) / 1000 + 1) }
end

-- true = diese Abnahme ist ein Abwurf: UID vom Hook gemerkt (eine Anfrage = eine Abnahme, Teil-Abwurf: der Rest des
-- Stapels zaehlt danach wieder), sonst Ersatz-Merker der Komponente (DropC.Used -> I.Ledger loescht ihn nach dem Lauf)
function I.DropHit(DropC, Uid, Now)
    local T = S.DropU and S.DropU[Uid]
    if T and Now - T <= DropC.W then
        S.DropU[Uid] = nil
        return true
    end
    T = S.DropAt and S.DropAt[DropC.Ad]
    if T and Now - T <= DropC.W then
        DropC.Used = true
        return true
    end
    return false
end

-- Abwurf-Merker aelter als 10 s entfernen (I.HostFast, je Ledger-Takt)
function I.DropPrune(Now)
    local N = 0
    for Ti, Tab in ipairs({ S.DropU or {}, S.DropAt or {}, S.MoveU or {} }) do                -- MoveU: Closeout R2
        for Kx, T in pairs(Tab) do
            if Now - T > 10 then Tab[Kx] = nil elseif Ti == 1 then N = N + 1 end
        end
    end
    S.DropUN = N
    -- Closeout R3: Gast-Komponenten ohne Ledger-Lauf seit 30 s (Leiche nach Tod, Figur weg) sind keine Gast-Inventare mehr
    if S.GuestComp then
        for Ad, E in pairs(S.GuestComp) do if Now - E.T > 30 then S.GuestComp[Ad] = nil end end
    end
end

-- Closeout R3 (inv_cons_nomove_any, Host): Adresse der Figur-Komponente eines Gasts merken (I.Ledger je Lauf, nicht im
-- Hook). Je Gast genau ein Eintrag: neue Figur (Respawn) ersetzt die alte Adresse sofort; Rest raeumt I.DropPrune nach
-- 30 s, "gone"/"linked" (I.GCompDrop) und Weltwechsel (I.CheckGen). Eintrag eines anderen Gasts (wiederverwendete
-- Adresse) bleibt unberuehrt
function I.GCompNote(H, Key, Comp, Now)
    local Ad = I.Safe(function() return Comp:GetAddress() end)
    if not Ad then return end
    S.GuestComp = S.GuestComp or {}
    if H.CompAd and H.CompAd ~= Ad then I.GCompDrop(H, Key) end
    local E = S.GuestComp[Ad]
    if E then E.K, E.T = Key, Now else S.GuestComp[Ad] = { K = Key, T = Now } end
    H.CompAd = Ad
end

function I.GCompDrop(H, Key)
    local E = H and H.CompAd and S.GuestComp and S.GuestComp[H.CompAd]
    if E and E.K == Key then S.GuestComp[H.CompAd] = nil end
end

-- INV-20 (inv_badsave, E31/E32, Host): main.lua G.LoadInto ersetzte einen unlesbaren Gast-Spielstand still durch die
-- Startausruestung, der naechste Ledger-Store ueberschrieb ihn. Vorher pruefen (gleiches Kriterium wie G.LoadInto: Slot da,
-- Laden scheitert oder 0 Container) -> .sav nach .bad-<Zeit> umbenennen (bleibt liegen), letzte Festschreibung (.commit)
-- per server.lua J.Copy als .sav; danach laeuft das Original (laedt die Kopie oder meldet Startausruestung)
function I.BadSave(GuestId)
    local GI = A.G
    local Id = tostring(GuestId or ""):match("^[%w_%-]+$")
    if not Id or A.Settings.local_inventory or type(GI) ~= "table" or type(GI.GuestSlot) ~= "function" then return end
    local GS = A.UEHelpers.GetGameplayStatics()
    local Slot = GI.GuestSlot(Id)
    if not (I.Alive(GS) and GS:DoesSaveGameExist(Slot, 0)) then return end
    local Loaded = GS:LoadGameFromSlot(Slot, 0)
    if I.Alive(Loaded) and (tonumber(I.Safe(function() return #Loaded.MainJigContainers end)) or 0) > 0 then return end
    local Dir = I.GuestDir()
    if not Dir then Log("Gast-Spielstand %s unbrauchbar - Ordner unbekannt, nichts gesichert", Id) return end
    local Base = Dir .. Id
    local Bad = string.format("%s.bad-%d", Base, os.time())
    if not os.rename(Base .. ".sav", Bad) then
        Log("Gast-Spielstand %s unbrauchbar und nicht umbenennbar - Startausruestung (Datei bleibt)", Id)
        return
    end
    local Srv = A.Settings and A.Settings.server
    local J = type(Srv) == "table" and type(Srv.Journal) == "table" and Srv.Journal or nil
    local Copied = J ~= nil and type(J.Copy) == "function" and J.Copy(Base .. ".commit", Base .. ".sav") == true
    Log("Gast-Spielstand %s unbrauchbar -> gesichert als %s; %s", Id, Bad:match("([^\\/]+)$") or Bad,
        Copied and "letzte Festschreibung (.commit) wird geladen" or "keine Festschreibung - Startausruestung")
end

-- E31: G.LoadInto einmal einwickeln (Merker am main.lua-Table, ueberlebt ein Neuladen des Moduls)
function I.WrapLoad()
    local GI = A.G
    if type(GI) ~= "table" or type(GI.LoadInto) ~= "function" or GI.InvBadSave then return end
    local Orig = GI.LoadInto
    GI.InvBadSave = true
    GI.LoadInto = function(Inventory, GuestId)
        if I.On("inv_badsave") then
            local ok, err = pcall(I.BadSave, GuestId)
            if not ok then Core.Fail("inv_badsave", err) end
        end
        return Orig(Inventory, GuestId)
    end
end

-- INV-21 (inv_pend_defer): vorgemerkte Anlagen beim Trennen sofort ausfuehren, solange die Figur noch da ist (sonst gingen
-- schon bestaetigte Items im Quittungs-Fenster verloren); vor dem letzten Speichern
function I.FlushDefer(G, Key, Pawn)
    local H = S.H[Key]
    if not (H and H.Defer and #H.Defer > 0 and I.Alive(Pawn)) or A.Coop.GuestStoreFrozen == true then return end
    local N = #H.Defer
    I.Try("inv_pend", I.HostDefer, G or { Key = Key }, Key, H, Pawn, math.huge)
    Log("%s: %d vorgemerkte Anlage(n) beim Trennen sofort ausgefuehrt", tostring(G and G.PCName or Key), N)
end

-- ================================================================================================ GAST

function I.ClientReset()
    for Kk in pairs(C) do C[Kk] = nil end
    C.PendSeen, C.Local, C.SeenEver, C.Mis, C.Tries, C.Ignore, C.Results, C.LSent, C.LFlag, C.Trader = {}, nil, {}, {}, {}, {}, {}, {}, {}, {}
    C.SelfRm = {}
    C.LocalAt, C.DataAt, C.ScanAt, C.CmpAt, C.RttAt, C.Rtt, C.InFlight = os.clock(), -math.huge, 0, 0, 0, 0.15, 0
    C.ResetAt = os.clock()                                    -- Runde 9: Verbindung/Figur neu (I.GuardedResync)
    C.CraftAt, C.CraftSeen, C.BarTry, C.ReqWin = -math.huge, false, 0, { Since = 0, N = 0 }
    C.Trd = {}                                                -- Haendler-Sitzung (I.TrdClient)
    -- Runde 8: Refill-Ruecksetzen (b), letzter lokaler Looted/Lager-Stand, offene Lager-Aufhebung (c), inv_scav (e)
    C.LReset, C.LPrev, C.LMark, C.LUn, C.ScavSent, C.ScavPrev, C.ScApp = {}, {}, {}, {}, {}, {}, {}
end

-- Ignorier-Liste mit Ablauf (Schluessel = UID bzw. "u"/"a" + UID)
function I.Ign(Key, Now, Secs) C.Ignore[Key] = Now + Secs end
function I.Ignored(Key, Now)
    local T = C.Ignore[Key]
    if T and Now >= T then C.Ignore[Key], T = nil, nil end
    return T ~= nil
end

function I.OwnPawn()
    local P = I.Safe(function() return A.OwnPawn() end)
    return I.Alive(P) and P or nil
end

-- RTT in s (PlayerState-Ping, 2 s gecacht)
function I.Rtt(Now)
    if Now - C.RttAt < 2 then return C.Rtt end
    C.RttAt = Now
    local Ms = tonumber(I.Safe(function()
        local PC = A.LocalPC()
        local PS = I.Alive(PC) and PC.PlayerState or nil
        return I.Alive(PS) and PS:GetPingInMilliseconds() or nil
    end))
    if Ms and Ms > 0 then C.Rtt = math.min(Ms / 1000, 2) end
    return C.Rtt
end

-- Crafting-UI offen? (FindAllOf hoechstens 1x/s)
function I.Crafting(Now)
    if Now - C.CraftAt < 1 then return C.CraftSeen end
    C.CraftAt, C.CraftSeen = Now, false
    for _, Cls in ipairs(K.CRAFT_UIS) do
        if I.Safe(function() return A.VisibleWidget(Cls) end) then C.CraftSeen = true break end
    end
    return C.CraftSeen
end

-- Runde 9 INV-1 (inv_craft_one, Gast). Hook-Koerper (selten: Knopf-Klick): Felder lesen/schreiben + Tabelle C, keine
-- UFunction. Review 1: UE4SS 3.0.1 ruft Script-Hooks auf BP-Funktionen nur EINMAL auf, und zwar NACH dem BP-Rumpf
-- (main.lua:7824). Die Schleife @03c4 (CountIndex-mal SERVER_RequestCraftItem mit denselben RequestConsume-UIDs) ist
-- beim Crafting-Knopf also schon gelaufen -> CountIndex muss schon beim Mengen-Knopf (nach dessen Rumpf) auf 1 zurueck.
-- Crafting-Knopf: CountIndex nachtraeglich auf 1 (Absicherung) + Zeit/Widget fuer die Sperre bis zur Server-Antwort;
-- Nachklicken binnen 0,25 s faengt der Host ab (inv_craft_dupkey)
function I.HCraftInc(Ctx)
    if Net.Side ~= "client" or not I.On("inv_craft_one") then return end
    -- Review 1: Menge sofort nach dem Increase-Rumpf auf 1 (nur die Eigenschaft); Anzeige frischt I.CraftOne auf (IncP)
    local W = I.Safe(function() return Ctx:get() end)
    if I.Alive(W) and (tonumber(I.Safe(function() return W.CountIndex end)) or 1) > 1 then
        pcall(function() W.CountIndex = 1 end)
    end
    local P = I.Alive(W) and I.Safe(function() return W:GetFullName():match("^%S+%s+(%S+)$") end) or nil
    if P then
        C.CraftEv = C.CraftEv or {}
        C.CraftEv.IncP = P
    end
end

function I.HCraftBtn(Ctx)
    if Net.Side ~= "client" or not I.On("inv_craft_one") then return end
    local W = I.Safe(function() return Ctx:get() end)
    if not W then return end
    if (tonumber(I.Safe(function() return W.CountIndex end)) or 1) > 1 and pcall(function() W.CountIndex = 1 end) then
        C.CraftClampN = (C.CraftClampN or 0) + 1
    end
    C.CraftEv = C.CraftEv or {}
    C.CraftEv.Btn, C.CraftEv.BtnP = os.clock(), I.Safe(function() return W:GetFullName():match("^%S+%s+(%S+)$") end)
end

-- INV-4 (inv_repair, Gast) Hook-Koerper (selten: Kontextmenue/Ziehen, nur Pre): nur Felder lesen + Tabelle C.
-- Kontextmenue (w/a/t): Item = CurrentItemRef, Set sucht I.RepSend wie das Spiel (FindJigItemByDA, echtes vor Behelfs-Set).
-- Ziehen (wd/ad/rf): Receiver/Dropped; WeaponRepair mit Attachment? = Anbauteil -> "t" (gleiche Formel /2)
function I.RepHook(Kind)
    return function(Ctx, P1, P2, P3)
        if Net.Side ~= "client" or not I.On("inv_repair") then return end
        local Rec = { K = Kind }
        pcall(function()
            if Kind == "w" or Kind == "a" or Kind == "t" then
                local W = Ctx:get().CurrentItemRef
                if I.Alive(W) then Rec.U = I.Hex(W.ItemUniqueID) end
            else
                local R, D = P1:get(), P2:get()
                if I.Alive(R) and I.Alive(D) then Rec.U, Rec.Kit = I.Hex(R.ItemUniqueID), I.Hex(D.ItemUniqueID) end
                if Kind == "wd" and P3 and P3:get() == true then Rec.K = "t" end
            end
        end)
        if Rec.U and Rec.U ~= K.ZERO then
            C.RepQ = C.RepQ or {}
            if #C.RepQ < 8 then C.RepQ[#C.RepQ + 1] = Rec end
        end
    end
end

-- Hooks setzen, sobald die Klasse geladen ist (Gast, hoechstens alle 5 s); neu bei geaenderter Adresse (neu geladen)
function I.GuestHooks(Now)
    if Now < (S.HkAt or 0) then return end
    S.HkAt = Now + 5
    S.Hk = S.Hk or {}
    local List = {}
    if I.On("inv_craft_one") then
        for _, Cls in ipairs(K.CRAFT_PATHS) do
            List[#List + 1] = { Cls .. K.CRAFT_INC, I.HCraftInc }
            List[#List + 1] = { Cls .. ":BndEvt__Button_81_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", I.HCraftBtn }
        end
    end
    if I.On("inv_repair") then
        for Kind, Fn in pairs(K.REP_FN) do
            local Base = (Kind == "w" or Kind == "a" or Kind == "t") and K.REP_CTX or K.REP_IOI
            List[#List + 1] = { Base .. ":" .. Fn, Kind }
        end
    end
    for _, E in ipairs(List) do
        local Path = E[1]
        local F0 = I.Safe(function() return StaticFindObject(Path) end)
        local Addr = I.Alive(F0) and I.Safe(function() return F0:GetAddress() end) or nil
        local Hk = S.Hk[Path]
        if Addr and (not Hk or Hk.Addr ~= Addr) then
            local Fn = type(E[2]) == "string" and I.RepHook(E[2]) or E[2]
            local R = A.TryHook(Path, Fn)
            S.Hk[Path] = { Addr = Addr, Ok = R ~= nil }
            if R then Log("Hook aktiv (Runde 9): %s", Path:match("([^%.]+)$") or Path) end
        end
    end
end

-- INV-4 Gast 0,25 s: gemeldete Reparaturen an den Host (Set-UID wie ContextRepair* ueber FindJigItemByDA der UI)
function I.RepSend(Pawn)
    local Q = C.RepQ
    C.RepQ = nil
    if not Net.Has("invrep") then return end
    local Jig = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    for _, R in ipairs(Q or {}) do
        local Kit = R.Kit
        if not Kit and I.Alive(Jig) then
            for _, Sub in ipairs(K.REP_KITDA[R.K == "a" and "a" or "w"]) do
                local Nm = Sub:match("([^/]+)$")
                local DA = I.Safe(function() return StaticFindObject(K.REP_DIR .. Sub .. "." .. Nm) end)
                local ResT, FoundT = {}, {}
                if I.Alive(DA) and pcall(function() Jig:FindJigItemByDA(DA, {}, true, false, 1, ResT, FoundT) end)
                    and I.Out(ResT, "Result") == true then
                    local Found = I.Out(FoundT, "Found")
                    Kit = I.Alive(Found) and I.Safe(function() return I.Hex(Found.ItemUniqueID) end) or nil
                end
                if Kit then break end
            end
        end
        if Kit and Kit ~= K.ZERO then
            Net.Send("inv_rep", R.K .. "|" .. R.U .. "|" .. Kit, nil, 1)
            Log("Reparatur (%s) an den Host gemeldet", R.K)
        end
    end
end

-- Gast-Takt 0,25 s: Anzeige der Crafting-UI auf Menge 1 (Decrease-Ereignis frischt die Zutaten-Anzeige auf), Hinweis
-- einmal; Crafting-Knopf bis zur Server-Antwort (Platzhalter seit dem Klick aufgeloest) bzw. max(1 s, 3*RTT) gesperrt
function I.CraftOne(Now)
    if (C.CraftClampN or 0) > 0 and not C.CraftNoted then
        C.CraftNoted = true
        pcall(A.ShowNote, "Im Mehrspieler einzeln herstellen")
        Log("Crafting-Menge auf 1 begrenzt (Mehrfach-Crafting schickt sonst dieselben Zutaten mehrfach)")
    end
    local Ev = C.CraftEv
    if not Ev then return end
    if Ev.IncP then
        local P = Ev.IncP
        Ev.IncP = nil
        local W = I.Safe(function() return StaticFindObject(P) end)
        -- Review 1: der Hook hat CountIndex schon auf 1 gesetzt (Anzeige zeigt noch 2) -> ohne "> 1"-Bedingung ueber
        -- 2 + Decrease die Zutaten-Anzeige auffrischen; danach Absicherung auf 1 (falls Decrease scheitert)
        if I.Alive(W) then
            pcall(function() W.CountIndex = 2 end)
            pcall(function() W[K.CRAFT_DEC](W) end)
            if (tonumber(I.Safe(function() return W.CountIndex end)) or 1) > 1 then pcall(function() W.CountIndex = 1 end) end
            C.CraftClampN = (C.CraftClampN or 0) + 1
        end
    end
    local Btn = Ev.Btn
    local E2 = A.Coop and type(A.Coop.Inv) == "table" and tonumber(A.Coop.Inv.CraftBusy) or nil   -- E2 (ls_world)
    if Btn and E2 and E2 > Btn then Btn = E2 end
    local Lock = Btn ~= nil and Now - Btn < math.max(1, 3 * I.Rtt(Now))
    if Lock and Now - Btn > 0.3 then
        Lock = false
        for _, P in pairs(C.PendSeen) do if P.T >= Btn - 0.3 then Lock = true break end end
    end
    local W = Ev.BtnP and I.Safe(function() return StaticFindObject(Ev.BtnP) end) or nil
    local B = I.Alive(W) and I.Safe(function() return W.Button_81 end) or nil
    if not I.Alive(B) then
        if not Lock then C.CraftEv = nil end
        return
    end
    if Lock then
        if I.Safe(function() return B:GetIsEnabled() end) == true and pcall(function() B:SetIsEnabled(false) end) then
            Ev.Locked = true
        end
        return
    end
    if Ev.Locked then
        -- wie der Ubergraph nach der Schleife (@040c/@0431): nur freigeben, wenn die Zutaten in der UI reichen
        local T = {}
        if pcall(function() W:CheckIngredientsAvailability(T) end) and I.Out(T, "Proceed") == true then
            pcall(function() B:SetIsEnabled(true) end)
        end
    end
    C.CraftEv = nil
end

-- INV-2 (inv_craft_cnt, Gast): Stueckzahlen vom Host (inv_cnt) in die eigene UI; ClientUpdateCount ist lokal (kein RPC)
-- und arbeitet auf LocalJSIContainers (0 = Widget weg, wie ls_car ApplyMoney)
function I.CntApply(Comp)
    local Q = C.CntQ
    C.CntQ = nil
    local N = 0
    for _, E in ipairs(Q or {}) do
        if pcall(function() Comp:ClientUpdateCount(I.GuidT(E.U), E.N, true) end) then N = N + 1 end
    end
    if N > 0 then Log("Crafting mit vollem Inventar: %d Zutaten-Stapel vom Host aktualisiert", N) end
end

-- Anfragen gedrosselt (hoechstens 4/s, 60/min)
function I.ReqOk(Now)
    local W = C.ReqWin
    if Now - W.Since >= 60 then W.Since, W.N = Now, 0 end
    if W.N >= 60 or C.InFlight >= 4 then return false end
    W.N = W.N + 1
    return true
end

-- Platzhalter beim Gast entfernen. Runde 9 INV-25: der inv_localrm-Zweig (HandleLocalRequestConsumeItem nach FindItem auf
-- MainJigContainers) ist entfallen - beim Gast ist die Liste leer (nicht repliziert), der Zweig lief nie. N/Data bleiben
-- fuer die Aufrufer in der Signatur
function I.RemoveLocal(Comp, Uid, N, Data)
    local Done = false
    Comp.PendingRequests:ForEach(function(_, E)
        if Done then return end
        local Slot = E:get()
        if I.Alive(Slot) and I.Hex(Slot.ItemUniqueID) == Uid then
            Done = pcall(function() Comp:RemoveRequestByUID(Slot.ItemUniqueID, true, {}) end)
        end
    end)
    return Done
end

-- Antworten der Anfragen (aus den Net-Callbacks gesammelt) im Gast-Task abarbeiten
function I.ClientResults(Comp, Now)
    if #C.Results == 0 then return end
    local Q = C.Results
    C.Results = {}
    for _, R in ipairs(Q) do
        C.InFlight = math.max(0, C.InFlight - 1)
        local Verdict, Arg = tostring(R.Data or ""):match("^(%a+)|?(.*)$")
        if R.Kind == "pend" then
            -- Diagnose 27.10. (leere Flasche ab der zweiten weg): jede Host-Antwort loggen, hoechstens 30 je Sitzung
            C.PendLogN = (C.PendLogN or 0) + 1
            if C.PendLogN <= 30 then
                Log("Platzhalter %s x%s (%s): Antwort %s", I.Short(R.Path), tostring(R.N), tostring(R.Uid):sub(1, 8), tostring(R.Data))
            end
            if Verdict == "ok" or Verdict == "had" or Verdict == "drop" then
                -- "had": Server hat das Item schon (evtl. gleiche UID) -> nur den Platzhalter entfernen, Daten nicht
                I.RemoveLocal(Comp, R.Uid, R.N, Verdict ~= "had")
                -- inv_pend_ack: "ok|" ohne UID = Host legt verzoegert an -> Slot ist jetzt frei, Host darf anlegen
                if Verdict == "ok" and Arg == "" and Net.Has("invpf") then Net.Send("inv_pfree", R.Uid, nil, 1) end
                -- nur echte UID erwarten (gestapelt = leer bzw. 0, kommt als CLIENT_UpdateCounts)
                if Verdict == "ok" and #Arg == 32 and Arg:match("^%x+$") and Arg ~= K.ZERO then
                    C.Expect = { U = Arg:sub(1, 16), T = Now + 3 }
                end
                I.Ign(R.Uid, Now, 120)
            elseif Verdict == "keep" then
                -- Server kennt die UID: laufende Spiel-Anfrage (Ablegen/Teilen/Stapeln/Verschieben), Antwort kommt nativ
                I.Ign(R.Uid, Now, 300)
                Log("Platzhalter %s ist ein Server-Item (laufende Anfrage) - nichts entfernt", I.Short(R.Path))
            elseif Verdict == "no" then
                if R.Why == "p" then
                    C.RemoveQ = C.RemoveQ or {}
                    C.RemoveQ[#C.RemoveQ + 1] = { Uid = R.Uid, N = R.N, T = Now + 2 * I.Rtt(Now) }
                    Log("Platzhalter %s ohne Gutschrift (%s) - wird entfernt", I.Short(R.Path), tostring(Arg))
                end
                I.Ign(R.Uid, Now, 300)
            else
                -- "wait" (Host gerade nicht bereit/Rate), "err" (Zeitueberschreitung): Platzhalter bleibt, spaeter neu
                local T = (C.Tries[R.Uid] or 0) + 1
                C.Tries[R.Uid] = T
                if T >= 2 then I.Ign(R.Uid, Now, 120) end
                if C.PendSeen[R.Uid] then C.PendSeen[R.Uid].Sent = nil end
            end
        elseif R.Kind == "use" then
            I.Ign("u" .. R.Uid, Now, 60)
        end
    end
end

function I.Request(Kind, Data, R)
    C.InFlight = C.InFlight + 1
    local Rid = Net.Request("inv_" .. Kind, Data, function(Reply, _, Err)
        R.Data = Reply or ("err|" .. tostring(Err))
        R.Kind = Kind
        C.Results[#C.Results + 1] = R
    end, 12, nil, 1)
    if not Rid then C.InFlight = math.max(0, C.InFlight - 1) end
    return Rid ~= nil
end

-- Platzhalter (PendingRequests) pruefen und nach der Schwelle beim Host anfragen
function I.ClientPend(Comp, Now)
    local Seen, Thr, Any = {}, math.max(0.8, 3 * I.Rtt(Now) + 0.5), false
    local Dg = Net.Get("inv_sum", "s")
    Comp.PendingRequests:ForEach(function(_, E)
        local Slot = E:get()
        if not I.Alive(Slot) then return end
        local Uid = I.Hex(Slot.ItemUniqueID)
        if not Uid or Uid == K.ZERO then return end
        Any = true
        local P = C.PendSeen[Uid]
        if not P then
            P = { T = Now }
            P.Craft = I.Crafting(Now)
        elseif P.Craft and not I.Crafting(Now) then
            -- Runde 9 INV-22: Crafting-UI zu -> wie ein normaler Platzhalter pruefen (Trinken/Essen bei offener Kochstelle
            -- blieb sonst fuer immer haengen); echte Craft-Platzhalter loest CLIENT_ItemCraftedResponse vorher auf
            P.Craft, P.T = nil, Now
        end
        Seen[Uid] = P
        -- UID im Server-Digest = echtes Item einer laufenden Spiel-Anfrage (Ablegen/Stapeln ...): erst viel spaeter fragen
        local T = (Dg and Dg:find(Uid:sub(1, 16) .. ":", 1, true)) and math.max(Thr, 6) or Thr
        if not P.Sent and not P.IgnLog and I.Ignored(Uid, Now) then
            P.IgnLog = true   -- Diagnose 27.10.: Platzhalter wegen gesperrter UID nicht gemeldet (einmal je UID)
            Log("Platzhalter (%s) x%s nicht gemeldet: UID gesperrt (frueher entschieden)", Uid:sub(1, 8),
                tostring(I.Safe(function() return Slot.ItemCount end)))
        end
        if P.Craft or P.Sent or I.Ignored(Uid, Now) or Now - P.T < T or not I.ReqOk(Now) then return end
        local D = I.DAInfo(I.Safe(function() return Slot.JigDataAsset end))
        if not D or D.P == "?" then return end
        local N = math.max(1, math.floor(tonumber(I.Safe(function() return Slot.ItemCount end)) or 1))
        P.Sent = Now
        local Data = table.concat({ Uid, Net.Enc(D.P), N, "p", math.floor((Now - P.T) * 1000) }, "|")
        if not I.Request("pend", Data, { Uid = Uid, Path = D.P, N = N, Why = "p" }) then P.Sent = nil end
    end)
    C.PendSeen = Seen
    C.HasPend = Any
end

-- Lokales Inventar beobachten: Aenderungszeit, lokal gesehene UIDs, lokale Entnahmen
function I.ClientLocal(Comp, Now)
    local Snap, Sig = I.Scan(Comp)
    if Sig ~= C.LocalSig then C.LocalSig, C.LocalAt = Sig, Now end
    for _, E in pairs(Snap) do C.SeenEver[E.U] = true end
    C.Local = Snap
end

-- Digest des Hosts mit dem lokalen Stand vergleichen (nur nach einem Ruhefenster)
function I.ClientCompare(Comp, Now)
    local Dg = Net.Get("inv_sum", "s")
    if not Dg or not C.Local or not next(C.Local) then return end   -- leere lokale Sicht = unbekannt: nie handeln
    if Dg ~= C.DgText then
        C.DgText, C.DgAt, C.Dg = Dg, Now, {}
        for U, N in Dg:gmatch("(%x+):(%d+)") do C.Dg[U] = tonumber(N) end
    end
    local Quiet = math.max(2, 3 * I.Rtt(Now) + 1)
    if Now - C.LocalAt < Quiet or Now - C.DgAt < Quiet / 2 or C.InFlight > 0 then return end
    local Srv, LocalN, Act = C.Dg, {}, 0
    for Uid, E in pairs(C.Local) do
        LocalN[E.U] = (LocalN[E.U] or 0) + E.N
        local SN = Srv[E.U]
        local Key = "a" .. Uid
        if C.PendSeen[Uid] or I.Ignored(Uid, Now) then
            C.Mis[Key] = nil
        elseif (SN == nil or E.N > SN) and I.On("inv_adopt") then
            C.Mis[Key] = C.Mis[Key] or Now
            if Now - C.Mis[Key] >= Quiet and Act < 3 and I.ReqOk(Now) then
                Act, C.Mis[Key] = Act + 1, nil
                local N, Why = SN == nil and E.N or (E.N - SN), SN == nil and "l" or "s"
                I.Ign(Uid, Now, 120)
                I.Request("pend", table.concat({ Uid, Net.Enc(E.P), N, Why, 0 }, "|"), { Uid = Uid, Path = E.P, N = N, Why = Why })
            end
        else
            C.Mis[Key] = nil
        end
    end
    for U, SN in pairs(Srv) do
        local LN = LocalN[U] or 0
        local Key = "u" .. U
        if SN > LN and not I.Ignored(Key, Now) then
            C.Mis[Key] = C.Mis[Key] or Now
            if Now - C.Mis[Key] >= Quiet and Act < 3 then
                C.Mis[Key] = nil
                if C.SeenEver[U] and not C.SelfRm[U] and I.On("inv_use") and I.InOtherLocal(U) then
                    -- lokal in eine Kiste/Leiche verschoben (Server konnte nicht folgen): kein Verbrauch -> Server-Stand holen
                    C.NeedData = true
                    I.Ign(Key, Now, 60)
                    I.WarnOnce("usemove", "Item lokal verschoben, Server nicht gefolgt - kein inv_use, Fallback SERVER_RequestData")
                elseif C.NeedData then
                    -- X13: Neuabgleich vorgemerkt (M.Resync/Verschieben) -> SERVER_RequestData hat Vorrang vor inv_use
                    C.Mis[Key] = Now
                elseif C.SeenEver[U] and not C.SelfRm[U] and I.On("inv_use") and I.ReqOk(Now) then
                    Act = Act + 1
                    I.Ign(Key, Now, 60)
                    I.Request("use", table.concat({ U, SN - LN, "" }, "|"), { Uid = U, N = SN - LN })
                elseif not C.SeenEver[U] or C.SelfRm[U] then
                    -- Fehlt das Item auch nach 2 Neuabgleichen, kommt es per SERVER_RequestData nie an (z. B. in einem
                    -- Unter-Container, den der Gast nicht fuehrt): ignorieren statt alle 30 s neu laden (Test 22.10.)
                    C.MissTry, C.MissPend = C.MissTry or {}, C.MissPend or {}
                    if (C.MissTry[U] or 0) >= 2 then
                        I.Ign(Key, Now, 900)
                        I.WarnOnce("miss_" .. U, "Server-Item " .. U .. " fehlt lokal auch nach 2 Neuabgleichen - ignoriert")
                    else
                        C.NeedData, C.MissPend[U] = true, true
                    end
                end
            end
        elseif SN <= LN then
            C.Mis[Key] = nil
        end
    end
    if C.NeedData and Now - C.DataAt >= 30 and I.OnOff("inv_sum") then
        for U in pairs(C.MissPend or {}) do C.MissTry[U] = (C.MissTry[U] or 0) + 1 end
        C.MissPend = {}
        I.RequestData(Comp, Now, "Server-Item fehlt lokal")
    end
end

-- Liegt die UID (16 Zeichen) lokal in einer anderen Komponente (Kiste in der Naehe, offene Leiche, Airdrop)?
-- Dann war die lokale Abnahme ein Verschieben, kein Verbrauch (inv_use wuerde das Server-Item vernichten).
function I.InOtherLocal(U)
    if not I.On("inv_use_movecheck") then return false end
    local Pawn = I.OwnPawn()
    local L = Pawn and I.Loc(Pawn)
    local Comps = {}
    -- offene Kiste/Leiche (A.VisibleWidget liefert nur true/false, kein Widget)
    local Dc = Pawn and select(2, I.OpenLoot(Pawn)) or nil
    if Dc then Comps[#Comps + 1] = Dc end
    if L then
        for _, E in ipairs(I.NearConts(L, 2 * K.NEAR, 32)) do
            local O = I.Fresh(E)
            local Cp = O and I.Safe(function() return O.BP_JigMultiplayer end)
            if I.Alive(Cp) then Comps[#Comps + 1] = Cp end
        end
        for _, O in ipairs(FindAllOf("Master_AirdropContainer_C") or {}) do
            local Ol = I.Alive(O) and I.Loc(O)
            local Cp = Ol and I.Dist2(L, Ol.X, Ol.Y, Ol.Z) <= 4 * K.NEAR * K.NEAR and I.Safe(function() return O.BP_JigMultiplayer end)
            if I.Alive(Cp) then Comps[#Comps + 1] = Cp end
        end
    end
    for _, Cp in ipairs(Comps) do
        local Found = I.Safe(function() return I.FindItem(Cp, U) end)
        if Found then return true end
    end
    return false
end

-- Fallback: UI leeren und Daten des Servers holen (SERVER_RequestData, keine Ausruestungs-Neuanlage)
function I.RequestData(Comp, Now, Why)
    C.NeedData, C.DataAt, C.ResyncWhy = false, Now, nil
    local Pawn = I.OwnPawn()
    pcall(function() Comp:ClearJSIItems() end)
    pcall(function()
        local UI = Pawn and Pawn.InGameUI
        if I.Alive(UI) then UI:ClearContainers() end
    end)
    local ok = pcall(function() Comp:SERVER_RequestData(Comp) end)
    -- Runde 9 inv_resync_nobar: keine Hotbar-Wiederherstellung (C.BarReapply war der Weg der vertauschten Ausruestung,
    -- Live-Test 22.10.); gespeicherte Hotbar nicht mit der geleerten "0,0,0" ueberschreiben (C.BarHold, I.ClientSlow)
    if I.On("inv_resync_nobar") then
        C.BarReapply, C.BarHold = nil, C.BarText
    else
        C.BarReapply = C.BarText and (Now + 2) or nil
    end
    C.SeenEver, C.Mis = {}, {}
    Log("Inventar vom Server neu angefordert (%s)%s", Why, ok and "" or " - fehlgeschlagen")
end

-- Runde 9 INV-7/E5: bewachter Voll-Abgleich. Eine Antwort in eine leere UI ist sicher, eine zweite in eine volle loescht
-- Items beim Server -> nie mit laufender Anfrage, offener Kiste/Haendler, Respawn-Nachholen, in den ersten 30 s nach
-- Verbindung/Respawn oder binnen 30 s nach der letzten Daten-Anfrage; hoechstens 2 je 10 min. true = angefordert
function I.GuardedResync(Pawn, Comp, Now, Why)
    if C.InFlight > 0 or Now - C.DataAt < 30 or Now - (C.ResetAt or Now) < 30 or S.Resp or S.RespChk
        or I.OpenLoot(Pawn) or (C.Trd and C.Trd.Open) then return false end
    local Keep = {}
    for _, T in ipairs(S.FixT or {}) do if Now - T < 600 then Keep[#Keep + 1] = T end end
    S.FixT = Keep
    if #Keep >= 2 then
        I.WarnOnce("fixmax" .. math.floor(Now / 600), "Voll-Abgleich (%s) ausgelassen: schon 2 in 10 min", tostring(Why))
        return false
    end
    Keep[#Keep + 1] = Now
    I.RequestData(Comp, Now, Why)
    return true
end

-- INV-7 (inv_ui_view, Gast): eigene Sicht aus den UI-Containern (MainJigContainers ist beim Gast leer). { [uid16] = n },
-- nil = UI nicht aufgebaut. Platzhalter (IsPending) zaehlen nicht; Hotbar-Spiegel derselben UID zaehlt einmal
function I.UiScan(Comp)
    local Out, Any = {}, false
    Comp.LocalJSIContainers:ForEach(function(_, E)
        local J = E:get()
        if not I.Alive(J) then return end
        Any = true
        J.ArrayOfItems:ForEach(function(_, IE)
            local W = IE:get()
            if not I.Alive(W) or W.IsPending == true then return end
            local U = I.Hex(W.ItemUniqueID)
            if U and U ~= K.ZERO then
                U = U:sub(1, 16)
                Out[U] = math.max(Out[U] or 0, math.floor(tonumber(W.ItemCount) or 1))
            end
        end)
    end)
    return Any and Out or nil
end

-- INV-7 Gast 1 s: UI-Sicht gegen den Host-Digest (inv_sum). "Fehlt" = im Digest (nicht "~"), nicht in der UI laenger als
-- Quiet; "Geist" = in der UI, nicht im Digest laenger als 10 s. Nur in Ruhe (keine Anfrage/Platzhalter/offene Kiste,
-- nicht kurz nach einer Daten-Antwort). Log bei Aenderung; Reparatur nur mit inv_reconcile2
function I.UiCheck(Pawn, Now)
    local Comp = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    local Dg = Net.Get("inv_sum", "s")
    if not (I.Alive(Comp) and Dg) then return end
    local Ui = I.UiScan(Comp)
    if not Ui then return end
    if Dg ~= C.UiDgText then
        C.UiDgText, C.UiDgAt, C.UiDg = Dg, Now, {}
        for T, U, N in Dg:gmatch("(~?)(%x+):(%d+)") do C.UiDg[U] = { N = tonumber(N), Nest = T == "~" } end
    end
    local Quiet = math.max(3, 3 * I.Rtt(Now) + 1)
    if C.InFlight > 0 or next(C.PendSeen) or Now - C.DataAt < 10 or Now - C.UiDgAt < Quiet / 2
        or Now - (C.ResetAt or Now) < 15 or I.OpenLoot(Pawn) or (C.Trd and C.Trd.Open) then
        C.UiMis, C.UiGh = {}, {}
        return
    end
    local Mis, Gh, OldMis, OldGh = 0, 0, C.UiMis or {}, C.UiGh or {}
    C.UiMis, C.UiGh = {}, {}
    for U, E in pairs(C.UiDg) do
        if not E.Nest and not Ui[U] then
            C.UiMis[U] = OldMis[U] or Now
            if Now - C.UiMis[U] >= Quiet then Mis = Mis + 1 end
        end
    end
    for U in pairs(Ui) do
        if not C.UiDg[U] then
            C.UiGh[U] = OldGh[U] or Now
            if Now - C.UiGh[U] >= 10 then Gh = Gh + 1 end
        end
    end
    local Txt = Mis .. "/" .. Gh
    if Txt ~= (C.UiLast or "0/0") then
        C.UiLast = Txt
        Log("UI-Abgleich: %d fehlen, %d Geister", Mis, Gh)
    end
    if (Mis > 0 or Gh > 0) and I.OnOff("inv_reconcile2") then I.UiRepair(Comp, Pawn, Now, Mis, Gh) end
end

-- INV-7 Schritt 3 (inv_reconcile2, Standard aus): hoechstens alle 60 s. Geister -> Widget aus der UI (RemoveFromJSIParent,
-- nur Anzeige); Fehlende -> bewachter Voll-Abgleich (I.GuardedResync)
function I.UiRepair(Comp, Pawn, Now, Mis, Gh)
    if Now - (S.UiFixAt or -math.huge) < 60 then return end
    S.UiFixAt = Now
    if Gh > 0 then
        local List = {}                                       -- erst sammeln, dann entfernen (Array aendert sich)
        Comp.LocalJSIContainers:ForEach(function(_, E)
            local J = E:get()
            if not I.Alive(J) then return end
            J.ArrayOfItems:ForEach(function(_, IE)
                local W = IE:get()
                local U = I.Alive(W) and W.IsPending ~= true and I.Hex(W.ItemUniqueID) or nil
                local T = U and C.UiGh[U:sub(1, 16)]
                if T and Now - T >= 10 and #List < 8 then List[#List + 1] = W end
            end)
        end)
        local N = 0
        for _, W in ipairs(List) do
            if I.Alive(W) and pcall(function() W:RemoveFromJSIParent({}) end) then N = N + 1 end
        end
        Log("UI-Abgleich: %d Geister-Widgets entfernt", N)
    end
    if Mis > 0 then I.GuardedResync(Pawn, Comp, Now, string.format("UI-Abgleich: %d fehlen", Mis)) end
end

-- E5 (ls_combat C.FireSlotGuard, Gast, Task): Waffen-Slot ohne Item -> bewachter Voll-Abgleich. true = angefordert.
-- Reason (handoff_combat): "missing" = Slot-Container ohne Gegenstand, "pending" = wartet > 8 s mit fremdem Daten-Asset -
-- beides baut die Daten-Antwort in die geleerte UI neu auf. "noslot" = kein Container mit dem Tag im Inventar-Widget:
-- Priv_Containers kommt aus dem Widget-Aufbau (BP_MainJigInventory ForceInitSpecialcontainer @0e12), nicht aus den Daten ->
-- ein Abgleich hilft nicht, nur Log (wie unbekannte Gruende)
function M.RepairSlot(SlotTagName, Reason)
    if Net.Side ~= "client" or not (I.On("inv_v2b") and I.On("inv_repairslot") and Net.Has("inv2b")) then return false end
    local Why = K.SLOT_WHY[tostring(Reason)]
    if not Why then
        I.WarnOnce("rslot" .. tostring(Reason), "Slot %s (%s): durch einen Voll-Abgleich nicht reparierbar - keine Anfrage",
            tostring(SlotTagName), tostring(Reason))
        return false
    end
    local Pawn = I.OwnPawn()
    local Comp = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(Comp) then return false end
    local ok, R = pcall(I.GuardedResync, Pawn, Comp, os.clock(),
        string.format("Slot %s: %s", tostring(SlotTagName), Why))
    if not ok then Core.Fail("inv_repairslot", R) return false end
    return R == true
end

-- Kalibrierung: kommt ein vom Host angelegtes Item (ok|uid) binnen 3 s an?
function I.ClientExpect(Now)
    local E = C.Expect
    if not E or not C.Local then return end
    -- Gast-Sicht aus MainJigContainers ist leer (nicht repliziert): Item nie "gefunden" -> kein Fehlalarm/NeedData
    if not next(C.Local) then
        C.Expect = nil
        I.WarnOnce("expectoff", "ClientExpect aus: Gast-Sicht leer (MainJigContainers nicht repliziert)")
        return
    end
    for _, It in pairs(C.Local) do
        if It.U == E.U then C.Expect, C.ExpectOk = nil, (C.ExpectOk or 0) + 1 return end
    end
    if Now >= E.T then
        C.Expect = nil
        C.NeedData = true
        I.WarnOnce("expect", "Vom Host angelegtes Item kam nicht an (CLIENT_AddNewItem) - Fallback SERVER_RequestData")
    end
end

function I.ClientFast(Now)
    if Net.Side ~= "client" or I.Loading() then return end
    I.CheckGen()
    if not (I.On("inv_v2b") and Net.Has("inv2b") and Net.Host and Net.Host.Ready) then return end
    local Pawn = I.OwnPawn()
    local Comp = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(Comp) then return end
    local Name = I.Name(Pawn)
    if C.Pawn ~= Name then
        local Bar, Want, Done = C.BarText, C.BarWant, C.BarDone   -- inv_barset kann vor dem ersten Durchlauf ankommen
        I.ClientReset()
        C.Pawn, C.BarText, C.BarWant, C.BarDone = Name, Bar, Want, Done
    end
    I.Try("inv_pend", I.ClientResults, Comp, Now)
    if C.RemoveQ then
        local Keep = {}
        for _, R in ipairs(C.RemoveQ) do
            if Now >= R.T then I.Try("inv_pend", I.RemoveLocal, Comp, R.Uid, R.N, true) else Keep[#Keep + 1] = R end
        end
        C.RemoveQ = #Keep > 0 and Keep or nil
    end
    if I.On("inv_pend") then I.Try("inv_pend", I.ClientPend, Comp, Now) end
    if C.CntQ then I.Try("inv_craft_cnt", I.CntApply, Comp) end                   -- Runde 9 INV-2
    if I.On("inv_craft_one") then I.Try("inv_craft_one", I.CraftOne, Now) end      -- Runde 9 INV-1
    if C.RepQ and I.On("inv_repair") then I.Try("inv_repair", I.RepSend, Pawn) end  -- Runde 9 INV-4
    if Now >= C.ScanAt then
        C.ScanAt = Now + 0.5
        I.Try("inv_sum", I.ClientLocal, Comp, Now)
        I.ClientExpect(Now)
    end
    if Now >= C.CmpAt then
        C.CmpAt = Now + 1
        -- Digest-Vergleich nur mit Standard AUS: MainJigContainers ist beim Gast leer (nicht repliziert, die Items stehen in
    -- den JSI-Containern) -> jedes Server-Item galt als "fehlt lokal", alle 30 s Neuabgleich + Hotbar-Wiederherstellung,
    -- dadurch vertauschte Ausruestung (Live-Test 22.10.). Erst wieder an, wenn die lokale Sicht aus JSI gebaut wird.
    if I.OnOff("inv_sum") then I.Try("inv_sum", I.ClientCompare, Comp, Now) end
        -- M.Resync (ls_car: Tanken/Reparieren/Kauf abgelehnt): einmaliger Neuabgleich unabhaengig von inv_sum. Hoechstens
        -- alle 30 s nach dem letzten SERVER_RequestData (zwei Antworten in eine volle UI loeschen Items beim Server),
        -- nicht bei offener Kiste/Haendler (ClearContainers leerte deren UI)
        -- Standard AUS (wie inv_sum): jeder Neuabgleich ist ClearContainers + SERVER_RequestData + Hotbar-Wiederherstellung,
        -- genau der Pfad der vertauschten Ausruestung (Live-Test 22.10.); erst wieder an, wenn er ohne Hotbar-Neusetzen laeuft
        if C.ResyncWhy and I.OnOff("inv_resync") and Now - C.DataAt >= 30 and C.InFlight == 0 and not I.OpenLoot(Pawn)
            and not (C.Trd and C.Trd.Open) then
            local W = C.ResyncWhy
            I.Try("inv_resync", I.RequestData, Comp, Now, "Neuabgleich " .. W)
            C.ResyncWhy = nil
            Log("Neuabgleich ausgefuehrt (%s)", W)
        end
    end
    if I.On("inv_lootprime") then I.Try("inv_lootprime", I.ClientLoot, Pawn, Now) end
end

-- Hotbar (3 Verbrauchs-Slots) lesen: "uid,uid,uid" (0 = leer)
function I.ReadBarLocal(Pawn)
    local UI = Pawn.InGameUI
    if not I.Alive(UI) then return nil end
    local Parts = {}
    for N = 1, 3 do
        local Cont = UI["JSIContainer_Consumable" .. N]
        local Found, Ref = {}, {}
        local Slot = nil
        if I.Alive(Cont) and pcall(function() Cont:GetEquippedItemRef(Found, Ref, {}) end) and I.Out(Found, "Found?") == true then
            Slot = I.Out(Ref, "ItemRef")
        end
        Parts[N] = I.Alive(Slot) and (I.Hex(Slot.ItemUniqueID) or "0") or "0"
    end
    return table.concat(Parts, ",")
end

-- Hotbar setzen wie BP_PlayerCharacter:OnClientDataRequested (DeepSearchForItem -> GetHotbarByIndex(i+6) -> Drop)
function I.ApplyBar(Pawn, Text)
    local Comp, UI = Pawn.BP_JigMultiplayer, Pawn.InGameUI
    if not (I.Alive(Comp) and I.Alive(UI)) then return false end
    local N, Missing = 0, 0
    for Uid in tostring(Text):gmatch("[^,]+") do
        N = N + 1
        if N > 3 then break end
        if Uid:match("^%x+$") and #Uid == 32 and Uid ~= K.ZERO then
            local RefT, FoundT, ContT, MainT = {}, {}, {}, {}
            pcall(function() UI:GetHotbarByIndex(N + 5, RefT, FoundT, ContT, MainT) end)
            local Busy, Cont = I.Out(FoundT, "Found?") == true, I.Out(ContT, "ContainerRef")
            if not Busy then
                local OutT = {}
                pcall(function() Comp:DeepSearchForItem(I.GuidT(Uid), OutT) end)
                local Item = I.Out(OutT, "ItemFound")
                if I.Alive(Item) and I.Alive(Cont) then
                    I.Try("inv_bar", function() UI:EventOnSomethingDropped(Item.ContainerMother, Cont, Item, nil, 0, false) end)
                else
                    Missing = Missing + 1
                end
            end
        end
    end
    return Missing == 0
end

-- Runde 8 (c) inv_unmark (Gast): lokale Lager-Markierung true->false, waehrend der Host "2" fuehrt -> "3" an den Host;
-- bis zu seiner Antwort (inv_lflag "1", hoechstens 10 s) nicht neu markieren. true = Markierung nicht anwenden
function I.ClientUnmark(E, Near, Now)
    local At = C.LUn[E.N]
    if At then
        if Now - At <= 10 then return true end
        C.LUn[E.N], C.LSent[E.N] = nil, "2"                   -- keine Antwort: Host-Stand gilt wieder
        return false
    end
    if not (Near and C.LMark[E.N] == true and I.On("inv_unmark") and Net.Has("invu")) then return false end
    C.LUn[E.N], C.LSent[E.N] = Now, "3"
    Net.Send("inv_loot", Net.Enc(E.N) .. "|3", nil, 2)
    Log("Lager-Markierung von %s aufgehoben - an den Host gemeldet", tostring(E.N))
    return true
end

-- Runde 8 (d) inv_toolxp (Gast): Werkzeug der eigenen Figur ueber die UI-Container suchen (FindJigItemByDA laeuft beim
-- Gast, Vertrag A5) und mit UID an den Host melden; UID leer = Host nimmt das erste passende Item
function I.ToolSend(Pawn, O, E)
    C.LSent[E.N] = "1"                                        -- kein zusaetzliches inv_loot "1"
    local Uid = ""
    local DA = I.Safe(function() return O.ToolNeeded end)
    local Jig = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if I.Alive(DA) and I.Alive(Jig) then
        local ResT, FoundT, UT = {}, {}, {}
        if pcall(function() Jig:FindJigItemByDA(DA, {}, true, false, 1, ResT, FoundT) end) and I.Out(ResT, "Result") == true then
            local Found = I.Out(FoundT, "Found")
            if I.Alive(Found) and pcall(function() Found:GetUniqueID(UT) end) then
                local U = I.Out(UT, "UniqueServerID")
                local Hex = U ~= nil and type(U) ~= "boolean" and type(U) ~= "number" and I.Hex(U) or nil
                if Hex and Hex ~= K.ZERO then Uid = Hex end
            end
        end
    end
    Net.Send("inv_tool", Net.Enc(E.N) .. "|" .. Uid, nil, 1)
    Log("Werkzeug-Kiste %s durchsucht - an den Host gemeldet (Werkzeug %s)", tostring(E.N), Uid ~= "" and Uid:sub(1, 8) or "?")
end

-- Runde 8 (e) inv_scav (Gast, 1 s): Laufzeit-Kisten (Airdrop, POI-/Compound-Kiste) <= 6 m: lokale Durchsucht-Eigenschaft
-- (K.SCAV) false->true -> einmal je Objektpfad "Klasse|x|y|z" an den Host. Karten-Actors (RF_WasLoaded) laufen ueber inv_loot
-- Je Lauf nur EINE Klasse (K.SCAVL rotierend, jede Klasse alle 3 s); Vorzustand je Klasse in C.ScavPrev[Cls]
function I.ClientScav(Pawn, Now)
    local L = I.Loc(Pawn)
    if not L then return end
    C.ScavI = (C.ScavI or 0) % #K.SCAVL + 1
    local Cls = K.SCAVL[C.ScavI]
    local Prop = K.SCAV[Cls]
    local Prev = C.ScavPrev[Cls] or {}
    local Flag, Seen, R2 = EObjectFlags and EObjectFlags.RF_WasLoaded, {}, K.NEAR * K.NEAR
    -- Host-Stand inv_scst (POI-/Compound-Kiste von jemandem durchsucht): "Klasse@x,y,z" aus dem Keyed-State-Spiegel
    local Hs, Mir = {}, Prop == "ContainerLooted" and Net.Mirror and Net.Mirror.host and Net.Mirror.host.inv_scst
    for Key in pairs(Mir or {}) do
        local Kc, X, Y, Z = tostring(Key):match("^([%w_]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
        if Kc == Cls then Hs[#Hs + 1] = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) } end
    end
    C.ScApp = C.ScApp or {}
    do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            local Ol = I.Alive(O) and I.Loc(O)
            if Ol and I.Dist2(L, Ol.X, Ol.Y, Ol.Z) <= R2 then
                local P = I.Path(O)
                local Ld = Flag and I.Safe(function() return O:HasAnyFlags(Flag) end, false) == true
                if P and not Ld then
                    local V = I.Safe(function() return O[Prop] end)
                    local Hit = false
                    for _, Hp in ipairs(Hs) do
                        if I.Dist2(Ol, Hp.X, Hp.Y, Hp.Z) <= 100 * 100 then Hit = true break end
                    end
                    if Hit and V == false then
                        -- fremd durchsucht: lokale Kopie wie im Einzelspiel gepluendert, kein eigenes inv_scav
                        pcall(function() O.ContainerLooted = true end)
                        V, C.ScavSent[P], C.ScApp[P] = true, true, true
                    elseif not Hit and C.ScApp[P] then
                        -- Host hat neu befuellt (Schluessel geloescht) -> nur die von uns gesetzte Markierung zuruecknehmen
                        C.ScApp[P] = nil
                        if V == true then
                            pcall(function() O.ContainerLooted = false end)
                            V = false
                        end
                    end
                    Seen[P] = V
                    if C.ScavSent[P] then
                        -- POI-/Compound-Kiste lokal neu befuellt (eigener Refill-Timer aus HoldToInteract @0314,
                        -- Bind_Refill @0a2e) -> naechstes Durchsuchen wieder melden; Airdrop (Inspected) bleibt einmalig
                        if V == false and Prop == "ContainerLooted" then C.ScavSent[P] = nil end
                    elseif V == true and Prev[P] == false then
                        C.ScavSent[P] = true
                        Net.Send("inv_scav", string.format("%s|%d|%d|%d", Cls, math.floor(Ol.X + 0.5), math.floor(Ol.Y + 0.5),
                            math.floor(Ol.Z + 0.5)), nil, 2)
                        Log("%s durchsucht - Pluender-XP beim Host angefragt", Cls)
                    end
                end
            end
        end
    end
    C.ScavPrev[Cls] = Seen
end

-- Kisten in der Naehe: Looted/Storage melden und anwenden, Belegt-Status, Haendler-Geld
function I.ClientConts(Pawn, Now)
    local L = I.Loc(Pawn)
    if not L then return end
    local Open
    for _, E in ipairs(I.NearConts(L, K.REP_RADIUS, 200)) do
        local Near = I.Dist2(L, E.X, E.Y, E.Z) <= K.NEAR * K.NEAR
        local Want = C.LFlag[E.N]
        if Near or Want or C.LReset[E.N] then
            local O = I.Fresh(E)
            if C.LReset[E.N] then
                -- Runde 8 (b): Host hat neu befuellt (inv_lflag geloescht) -> lokale Kopie einmal zuruecksetzen, damit das
                -- naechste Durchsuchen wieder gemeldet wird (Pluender-XP beim Host)
                C.LReset[E.N] = nil
                if O and I.On("inv_lflag") then
                    pcall(function() O.ContainerLooted = false end)
                    if I.Safe(function() return O.MarkedAsStorageContainer end) == true then
                        pcall(function() O.MarkedAsStorageContainer = false end)
                    end
                    C.LPrev[E.N], C.LMark[E.N] = false, false
                end
            end
            if Want ~= "2" then C.LUn[E.N] = nil end
            if O then
                if Want and I.On("inv_lflag") then
                    if I.Safe(function() return O.ContainerLooted end) == false then pcall(function() O.ContainerLooted = true end) end
                    -- Lager auch auf eine schon durchsuchte Kopie anwenden - ausser der Spieler hebt sie gerade auf (inv_unmark)
                    if Want == "2" and I.Safe(function() return O.MarkedAsStorageContainer end) == false
                        and not I.ClientUnmark(E, Near, Now) then
                        pcall(function() O.MarkedAsStorageContainer = true end)
                    end
                end
                if Near then
                    C.LMark[E.N] = I.Safe(function() return O.MarkedAsStorageContainer end)
                    local Looted = I.Safe(function() return O.ContainerLooted end) == true
                    -- Runde 8 (d): Werkzeug-Kiste lokal durchsucht -> inv_tool statt inv_loot "1" (Host bucht XP/Haltbarkeit)
                    if E.T and Looted and C.LPrev[E.N] == false and not Want and I.On("inv_toolxp") and Net.Has("invx") then
                        I.Try("inv_toolxp", I.ToolSend, Pawn, O, E)
                    end
                    C.LPrev[E.N] = Looted
                    local St = Looted and (I.Safe(function() return O.MarkedAsStorageContainer end) == true and "2" or "1") or nil
                    -- nur hoeher melden als der Host-Stand ("2" > "1"), nie herabstufen
                    if St and C.LSent[E.N] ~= St and (not Want or St > Want) and I.On("inv_lflag") then
                        C.LSent[E.N] = St
                        Net.Send("inv_loot", Net.Enc(E.N) .. "|" .. St, nil, 2)
                    end
                    local VisT = {}
                    if I.On("inv_lock") and pcall(function()
                        local Jig = O.BP_JigMultiplayer
                        if I.Alive(Jig) then Jig["IsInventoryVisible?"](Jig, VisT) end
                    end)
                        and I.Out(VisT, "Result") == true then
                        Open = E.N
                    end
                end
            end
        end
    end
    if I.On("inv_lock") then Net.State("inv_open", "o", Open, 2) end
    if I.On("inv_trader") and next(C.Trader) then
        local Ts = C.Trd or {}
        for _, E in ipairs(I.TraderList(Now)) do
            -- offene Haendler-Sitzung (trd_m) hat Vorrang; wandernde Haendler haben keinen festen Schluessel
            local V = not E.Wd and not (Ts.Open == E.F and Ts.M) and tonumber(I.TraderVal(E)) or nil
            if V and I.Dist2(L, E.X, E.Y, E.Z) <= K.TRADER_RADIUS * K.TRADER_RADIUS then
                local O = I.Fresh(E)
                if O then pcall(function()
                    local Jig = O.BP_JigMultiplayer
                    if I.Alive(Jig) then Jig.VendorCurrentCurrencyAmount = V end
                end) end
            end
        end
    end
end

-- Gerade per Interaktion geoeffneter Actor (BP_JigHelperComp.InteractExecutedActor: TryInteract setzt ihn, Schliessen
-- des Inventars leert ihn) und seine Jig-Komponente. nil wenn nichts offen.
function I.OpenLoot(Pawn)
    local Act = I.Safe(function()
        local Hc = Pawn.BP_JigHelperComp
        return I.Alive(Hc) and Hc.InteractExecutedActor or nil
    end)
    if not I.Alive(Act) then return nil end
    local Comp = I.Safe(function() return Act.BP_JigMultiplayer end)
    return Act, I.Alive(Comp) and Comp or nil
end

-- Anzahl Items in den UI-Containern (LocalJSIContainers) einer Komponente; nil = UI noch nicht aufgebaut
function I.LootItems(Comp)
    return I.Safe(function()
        local N, Any = 0, false
        Comp.LocalJSIContainers:ForEach(function(_, E)
            local J = E:get()
            if I.Alive(J) then Any, N = true, N + J.ArrayOfItems:GetArrayNum() end
        end)
        return Any and N or nil
    end)
end

-- Fixplan #8/#16 (Gast): Loot-UI einer Kiste/Leiche bleibt leer (CLIENT_ContainerDataResponse kam nicht) -> Host
-- bitten, die Daten im Namen des Gasts anzufordern. Nur bei leerer UI (eine zweite Antwort mit denselben Items liesse
-- BuildDataToContainer scheitern -> SERVER_RequestRemoveItem). Hoechstens 2 Versuche je Oeffnen, 4 s Abstand.
function I.ClientLoot(Pawn, Now)
    local Act, Comp = I.OpenLoot(Pawn)
    if not Act then C.Loot = nil return end
    local Nm = I.Name(Act)
    local Lt = C.Loot
    if not Lt or Lt.N ~= Nm then
        Lt = { N = Nm, T0 = Now, Tries = 0, At = -math.huge }
        C.Loot = Lt
        local Fam, CN = I.CarcFam(Act)
        Lt.Fam, Lt.Cls = Fam, CN
        -- keine Leiche/Kiste, Spieler, oder nur lokal existierende Kopie (Geister-Todeskiste): nichts melden
        Lt.Skip = not Fam or not Comp or I.Safe(function() return Act:HasAuthority() end) ~= false
        -- Haendler (auch der wandernde, Familie "h"): eigener Weg trd_prime
        if I.TrdFam(Act) then Lt.Skip = true end
    end
    if Lt.Skip or Lt.Tries >= 2 or not Comp then return end
    if Now - Lt.T0 < math.max(1.5, 3 * I.Rtt(Now) + 0.5) or Now - Lt.At < 4 then return end
    local Num = I.LootItems(Comp)
    if Num == nil then return end
    if Num > 0 then Lt.Skip = true return end                      -- Server-Daten sind da (nativer Weg)
    local L = I.CarcLoc(Act, Lt.Fam)
    if not (L and Lt.Cls) then return end
    Lt.Tries, Lt.At = Lt.Tries + 1, Now
    -- Runde 9 CORE-28: Alter der offenen UI mitschicken (Host prueft, ob die native Anfrage schon gueltig war)
    local AgeS = Net.Has("invps") and string.format("|%d", math.floor((Now - Lt.T0) * 1000)) or ""
    Net.Send("inv_carc", string.format("%s|%.0f|%.0f|%.0f%s", Net.Enc(Lt.Cls), L.X, L.Y, L.Z, AgeS), nil, 1)
    I.WarnOnce("lp_" .. tostring(Nm), "%s leer geoeffnet - Host um Server-Daten gebeten", Lt.Cls)
end

-- Fixplan #16 (Gast): lokal gespawnte Todeskiste (Selbstmord u. ae., HasAuthority beim Gast) nach 1 s entfernen;
-- die echte Kiste kommt repliziert vom Host.
function I.ClientGhostBoxes(Now)
    local Seen, Old = {}, C.Ghost or {}
    for _, O in ipairs(FindAllOf(K.GHOST_BOX) or {}) do
        if I.Alive(O) and I.Safe(function() return O:HasAuthority() end) == true then
            local Nm = I.Name(O)
            if Nm then
                local T = Old[Nm] or Now
                if Now - T >= 1 then
                    local ok = pcall(function() O:K2_DestroyActor() end)
                    I.WarnOnce("gb_" .. Nm, "Lokale Geister-Todeskiste %s entfernt (%s)", Nm, ok and "ok" or "Fehler")
                else
                    Seen[Nm] = T
                end
            end
        end
    end
    C.Ghost = Seen
end

function I.ClientSlow(Now)
    if Net.Side ~= "client" or I.Loading() then return end
    I.CheckGen()
    if not (Net.Host and Net.Host.Ready) then return end
    local Pawn = I.OwnPawn()
    if not Pawn then return end
    if I.On("inv_v2a") and I.On("inv_bar") and Net.Has("inv2a") then
        if C.BarWant and C.BarTry < 10 then
            C.BarTry = C.BarTry + 1
            local ok, Done = I.Try("inv_bar", I.ApplyBar, Pawn, C.BarWant)
            if ok and Done then
                Log("Hotbar wiederhergestellt")
                C.BarWant = nil
            elseif C.BarTry >= 10 then
                Log("Hotbar: nicht alle Gegenstaende gefunden")
                C.BarWant = nil
            end
        elseif C.BarReapply and Now >= C.BarReapply then
            C.BarReapply, C.BarWant, C.BarTry = nil, C.BarText, 5
        elseif not C.BarReapply then
            -- (C.BarReapply offen: I.RequestData hat die Hotbar geleert (ClearContainers) -> bis zur Wiederherstellung
            -- nicht lokal lesen, sonst ueberschreibt "0,0,0" C.BarText und landet per inv_bar im Host-Speicher)
            local Text = I.Safe(function() return I.ReadBarLocal(Pawn) end)
            C.ReadyAt = C.ReadyAt or Now
            -- Runde 9 inv_resync_nobar: nach einem Voll-Abgleich leere Hotbar nicht als neuen Stand melden
            if Text and C.BarHold then
                if Text:match("^[0,]+$") then Text = nil else C.BarHold = nil end
            end
            if Text and (C.BarDone or Now - C.ReadyAt > 20) then
                C.BarText = Text
                Net.State("inv_bar", "b", Text, 2)
            end
        end
    end
    if I.On("inv_v2b") and Net.Has("inv2b") then
        if I.On("inv_lflag") or I.On("inv_lock") or I.On("inv_trader") then I.Try("inv_lflag", I.ClientConts, Pawn, Now) end
        if I.On("inv_scavxp") and Net.Has("invx") then I.Try("inv_scavxp", I.ClientScav, Pawn, Now) end
    end
    if I.On("inv_ghostbox") then I.Try("inv_ghostbox", I.ClientGhostBoxes, Now) end
    if I.On("inv_craft_one") or I.On("inv_repair") then I.Try("inv_hooks9", I.GuestHooks, Now) end   -- Runde 9 INV-1/4
    if I.On("inv_ui_view") and I.On("inv_v2b") and Net.Has("inv2b") then I.Try("inv_ui_view", I.UiCheck, Pawn, Now) end
    if I.On("inv_patchwatch") then I.Try("inv_patchwatch", I.PatchWatch, Now) end                    -- Runde 9 INV-14a
    if I.On("inv_battery_drain") and I.On("inv_v2b") and Net.Has("invlt") then
        I.Try("inv_battery_drain", I.LightScan, Now)
    elseif S.BattOn == true and I.On("inv_light_local_off") and not Net.Has("invlt") then
        I.Try("inv_light_local_off", I.LightLocalOff, Now)                                           -- Review 1
    end
    -- Review 3 inv_scan_backoff: ohne Cap inv2b repliziert der Host keine Stationen (I.HostNetRep haengt an inv_v2b) ->
    -- keine Host-Kopie, nichts zu entfernen, also auch kein FindAllOf alle 2 s
    if I.On("inv_station_ghost") and (Net.Has("inv2b") or not I.On("inv_scan_backoff")) then
        I.Try("inv_station_ghost", I.StationGhost, Pawn, Now)                                        -- Review 1
    end
end

-- Runde 9 INV-14a (inv_patchwatch, Gast 1 s): Bytecode-Patches nach einem Spiel-Update pruefen. Ohne Haltbarkeits-Patch
-- (main.lua GetDurability) schiesst der Gast nicht ("Weapon jammed"), ohne Batterie-Patch geht kein Licht an. Die DLL meldet
-- patch_<Name>=1 (aktiv), 0 (Bytes passen nicht/verweigert), -1 (angefordert, offen). Laenger als 10 s nicht aktiv ->
-- einmal je Spielsitzung Log + Hinweis
function I.PatchWatch(Now)
    local St = (not S.PwDone and Native) and Native.Status() or nil
    if type(St) ~= "table" then S.PwBad = nil return end
    local Miss = {}
    if St.patch_durability ~= 1 then Miss[1] = "durability" end
    if S.BattOn == true then
        for _, N in ipairs(S.BattNames or {}) do if St["patch_" .. N] ~= 1 then Miss[#Miss + 1] = N end end
    end
    if #Miss == 0 then S.PwBad = nil return end
    S.PwBad = S.PwBad or Now
    if Now - S.PwBad < 10 then return end
    S.PwDone = true
    Log("Bytecode-Patch NICHT aktiv: %s (netcore_status.txt, Spiel-Update?) - %s", table.concat(Miss, ", "),
        Miss[1] == "durability" and "Gast kann nicht schiessen (Weapon jammed)" or "Lampen gehen nicht an")
    pcall(A.ShowNote, "LastSignal: Spiel-Update erkannt, Waffen-Patch fehlt")
end

-- Runde 9 INV-6b (inv_battery_drain, Gast 1 s): eigene Waffenlichter/Entfernungsmesser (lokale Anbauteile, je Lauf eine
-- Klasse). An = Batterie-Timer laeuft (BatteryTimer.Handle ~= 0); eigene = AttachmentUID im Host-Digest (inv_sum, auch
-- "~" fuer Items in Waffen) - ohne Digest keine Meldung (fremde Waffen). Meldung inv_light bei Aenderung und alle 5 s.
-- inv_lightoff (Host: Batterie leer/fehlt) -> Lampe wie ein UseBattery-Fehlschlag aus (Event_Battery(false))
function I.LightScan(Now)
    local Lt = C.Lt or { I = 0, Seen = {}, Sent = {}, At = 0 }
    C.Lt = Lt
    if C.LtOff then
        local Q = C.LtOff
        C.LtOff = nil
        local N = 0
        for _, U in ipairs(Q) do
            for P, E in pairs(Lt.Seen) do
                local O = E.On and (U == "" or E.U == U) and I.Safe(function() return StaticFindObject(P) end) or nil
                if I.Alive(O) and pcall(function() O:Event_Battery(false) end) then E.On, N = false, N + 1 end
            end
        end
        if N > 0 then
            pcall(A.ShowNote, "Battery run out")
            Log("%d Lampe(n) aus: Batterie beim Host leer oder fehlt", N)
        end
    end
    -- Review 3 inv_scan_backoff: letzte volle Runde (alle Klassen) ohne Lampen-Objekt -> 5 s Pause statt FindAllOf je
    -- Sekunde im ohnehin vollen inv_cli1-Takt. Lt.Seen leer = Lt.Sent schon leer, es geht keine "0|"-Meldung verloren
    if Lt.Idle and Now < Lt.Idle and I.On("inv_scan_backoff") then return end
    Lt.I = Lt.I % #K.LIGHT_CLS + 1
    local Cls = K.LIGHT_CLS[Lt.I]
    for P, E in pairs(Lt.Seen) do if E.C == Cls then Lt.Seen[P] = nil end end
    for _, O in ipairs(FindAllOf(Cls) or {}) do
        local P = I.Alive(O) and I.Path(O)
        local U = P and I.Safe(function() return I.Hex(O.AttachmentUID) end)
        if U and U ~= K.ZERO then
            local Hd = tonumber(I.Safe(function() return O.BatteryTimer.Handle end))
            Lt.Seen[P] = { C = Cls, U = U, On = Hd ~= nil and Hd ~= 0 }
        end
    end
    local Dg = Net.Get("inv_sum", "s")
    local On, Foreign = {}, 0
    for _, E in pairs(Lt.Seen) do
        if E.On then
            if Dg and Dg:find(E.U:sub(1, 16) .. ":", 1, true) then On[E.U] = true else Foreign = Foreign + 1 end
        end
    end
    if Foreign > 0 and not next(On) and not Lt.Warned and Dg then
        Lt.Warned = true
        Log("Lampe an, aber nicht im Host-Digest (fremde Waffe oder andere UID) - kein Batterie-Verbrauch gemeldet")
    end
    local Refresh = Now - Lt.At >= 5
    if Refresh then Lt.At = Now end
    for U in pairs(On) do
        if Refresh or not Lt.Sent[U] then Net.Send("inv_light", "1|" .. U, nil, 1) end
    end
    for U in pairs(Lt.Sent) do
        if not On[U] then Net.Send("inv_light", "0|" .. U, nil, 1) end
    end
    Lt.Sent = On
    -- Review 3 inv_scan_backoff: leere Laeufe in Folge zaehlen; nach einer vollen leeren Runde Pause, danach wieder eine
    -- volle Runde (Zaehler auf 0), sonst wuerde je Pause nur eine Klasse geprueft
    if next(Lt.Seen) or not I.On("inv_scan_backoff") then
        Lt.Empty, Lt.Idle = 0, nil
    else
        Lt.Empty = (Lt.Empty or 0) + 1
        if Lt.Empty >= #K.LIGHT_CLS then Lt.Empty, Lt.Idle = 0, Now + 5 end
    end
end

-- Review 1 (inv_light_local_off, Gast 1 s): Batterie-Patch c/d aktiv, aber keine Host-Entladung (Cap invlt fehlt: Host
-- inv_battery_drain=0, FLAG_DOWN, r8-Host) -> Waffenlicht/Entfernungsmesser liefen unbegrenzt. Wie vor INV-6b lokal aus
-- (Event_Battery(false) wie ein UseBattery-Fehlschlag), je Lauf eine Klasse. Die Taschenlampe bleibt beim Host (Server-Timer)
function I.LightLocalOff(Now)
    local Lo = C.LtLo or { I = 0 }
    C.LtLo = Lo
    -- Review 3 inv_scan_backoff: wie I.LightScan - nach einer vollen Runde ohne Lampen-Objekt 5 s Pause
    local Bo = I.On("inv_scan_backoff")
    if Bo and Lo.Idle and Now < Lo.Idle then return end
    Lo.I = Lo.I % #K.LIGHT_CLS + 1
    local N, F = 0, 0
    for _, O in ipairs(FindAllOf(K.LIGHT_CLS[Lo.I]) or {}) do
        if I.Alive(O) then
            F = F + 1
            local Hd = tonumber(I.Safe(function() return O.BatteryTimer.Handle end))
            if Hd ~= nil and Hd ~= 0 and pcall(function() O:Event_Battery(false) end) then N = N + 1 end
        end
    end
    if N > 0 and not Lo.Logged then
        Lo.Logged = true
        Log("Lampe(n) lokal aus: keine Batterie-Entladung ueber den Host (Cap invlt fehlt) - Verhalten wie vor INV-6b")
    end
    if F > 0 or not Bo then
        Lo.Empty, Lo.Idle = 0, nil
    else
        Lo.Empty = (Lo.Empty or 0) + 1
        if Lo.Empty >= #K.LIGHT_CLS then Lo.Empty, Lo.Idle = 0, Now + 5 end
    end
end

-- ================================================================================================ HAENDLER (Runde 7)
-- Grundlage findings\traders_r7.md. Kaufen/Verkaufen laufen im Spiel schon beim Server ("Handle Comp to Comp Move":
-- CheckIfHasEnoughMoney auf den Server-Daten, TakeMoney, CheckVendorAmountOfMoney, je RPC atomar; der Gast ruft
-- SERVER_RequestMoveItemToAnotherComp auf der EIGENEN Komponente). Die Mod sorgt nur dafuer, dass:
--   trd_addr  (Host)  Haendler-Actor + Vendor-Komponente repliziert sind (Referenz in SERVER_RequestData/MoveItem kommt
--                     an, CLIENT_MoveToIndexFailed setzt Platzhalter zurueck, MC_* zeigen Bestand bei allen)
--   trd_ghost (Gast)  lokal gespawnte Shakes/Military-Kopien weg sind (Host-Kopie kommt repliziert)
--   trd_sess  (beide) je offenem Haendler-Fenster eine Sitzung: Server-Geld sofort + bei Aenderung (trd_m), Ende bei
--                     Schliessen, > 15 m (3 s), Tod, Trennung ("gone")
--   trd_lock  (Host)  ein Kunde je Haendler; zweiter bekommt "busy" und sein Fenster wird lokal geschlossen
--   trd_busy  (Gast)  ohne Sperre: Hinweis, dass ein zweiter Spieler handelt
--   trd_prime (beide) Haendler-UI blieb leer -> Host fordert die Daten im Namen des Gasts an (wie inv_lootprime)
--   trd_note  (Host)  "Trader does not have enough money" entsteht nur beim Host -> an den Gast (DLL-Beobachter)
--   trd_reset (beide) Restock nur vom Host: Gast-Event_Reset unterdrueckt (DLL), Host meldet Restock (trd_rs)
--   trd_rsui  (Gast)  nach trd_rs Fenster schliessen und ueber OnExecuteInteractDialogue neu oeffnen (neuer Bestand)
--   trd_dlg   (Host)  laeuft OnExecuteInteractDialogue fuer eine Gastfigur beim Host: unterdruecken, Gast oeffnet selbst

function I.TrdOn(Name) return I.On("trd_v1") and (Name == "trd_v1" or I.On(Name)) end

function I.NoCls(V)
    if type(V) ~= "string" then return nil end
    return V:match("^%S+%s+(.+)$") or V
end

-- Inventar-Fenster einer Jig-Komponente sichtbar? (IsInventoryVisible?: InventoryWidgetRef gueltig und IsVisible)
function I.JigVis(Jig)
    if not I.Alive(Jig) then return false end
    local T = {}
    return pcall(function() Jig["IsInventoryVisible?"](Jig, T) end) and I.Out(T, "Result") == true
end

function I.CloseOwnInv(Pawn)
    local Jig = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if I.JigVis(Jig) then pcall(function() Jig:ToggleInventory() end) end
end

-- Haendlergeld als Text (gerundet wie im Spiel), "-" wenn unlesbar
function I.TrdMoney(O)
    local V = tonumber(I.Safe(function()
        local Jig = O.BP_JigMultiplayer
        return I.Alive(Jig) and Jig.VendorCurrentCurrencyAmount or nil
    end))
    return V and string.format("%.0f", V) or "-"
end

-- Anzahl MainContainersIDs (Restock beim Host: ClearContainer leert sie)
function I.TrdIds(O)
    return I.Safe(function()
        local Jig = O.BP_JigMultiplayer
        return I.Alive(Jig) and Jig.MainContainersIDs:GetArrayNum() or nil
    end)
end

-- Haendler-Verweis ueber Maschinen: "Klasse|x|y|z|FName|wl" (FName nur bei Karten-Actors gueltig)
function I.TrdRef(O)
    local L, Nm = I.Loc(O), I.Name(O)
    local CN = I.Safe(function() return I.Name(O:GetClass()) end)
    if not (L and Nm and CN) then return nil end
    local Flag = EObjectFlags and EObjectFlags.RF_WasLoaded
    local Ld = Flag and I.Safe(function() return O:HasAnyFlags(Flag) end, false) == true
    return string.format("%s|%.0f|%.0f|%.0f|%s|%d", CN, L.X, L.Y, L.Z, Net.Enc(Nm), Ld and 1 or 0)
end

-- Verweis -> lokaler Haendler: Karten-Haendler per FName, sonst naechster gleicher Klasse <= TRD_MATCH um die gemeldete
-- Position (und <= TRD_HOST_R von Near, falls angegeben). Rueckgabe Objekt, Listeneintrag bzw. nil, Grund
function I.TrdResolve(Ref, Near, Now)
    local Cls, X, Y, Z, Fn, Wl = tostring(Ref or ""):match(K.TRD_REF)
    if not Cls then return nil, "format" end
    X, Y, Z, Fn = tonumber(X), tonumber(Y), tonumber(Z), Net.Dec(Fn)
    local R2, H2 = K.TRD_MATCH * K.TRD_MATCH, K.TRD_HOST_R * K.TRD_HOST_R
    for Pass = 1, 2 do
        local Best, BestD, BestE
        for _, E in ipairs(I.TraderList(Now, 30)) do
            if Wl == "1" then
                if E.Ld and E.N == Fn then
                    local O = I.Fresh(E)
                    if O then return O, E end
                end
            elseif not E.Ld and E.Cls == Cls then
                local O = I.Fresh(E)
                local L = O and I.Loc(O)
                local D = L and I.Dist2(L, X, Y, Z)
                if D and D <= R2 and (not Near or I.Dist2(L, Near.X, Near.Y, Near.Z) <= H2) and (not BestD or D < BestD) then
                    Best, BestD, BestE = O, D, E
                end
            end
        end
        if Best then return Best, BestE end
        -- neu gespawnt/repliziert seit dem letzten FindAllOf: Liste einmal frisch
        if Pass == 1 and Now - S.TradersAt > 2 then S.Traders = nil else break end
    end
    return nil, "weit"
end

-- ------------------------------------------------------------------------------------------------ Host

-- Haendler fuer Gaeste netzadressierbar machen (einmal je Pfad). Feste Haendler: Actor + Komponente replizieren (wie
-- I.HostRep; Karten-Actor hat stabilen Namen -> keine Doppelkopie). Wandernder Haendler (repl. KI): nur die Komponente.
function I.TrdMakeRep(O, F)
    if S.TrdRep[F] then return true end
    if I.Safe(function() return O.Role end) ~= K.ROLE_AUTHORITY then return false end
    S.TrdRep[F] = true
    local Ok, Why
    if I.TrdFam(O) == "w" then
        Ok, Why = I.MakeAddr(O)
    else
        Ok, Why = pcall(function()
            if O.bReplicates ~= true then O:SetReplicates(true) end
            local Comp = O.BP_JigMultiplayer
            if I.Alive(Comp) then Comp:SetIsReplicated(true) S.AddrAt[F] = os.clock() end
            O:ForceNetUpdate()
        end)
        if not Ok then Core.Fail("trd_addr", Why) end
        Why = Ok and "repliziert" or tostring(Why)
    end
    Log("Haendler %s fuer Gaeste netzadressierbar: %s", I.Short(F), tostring(Why))
    return Ok
end

-- Host 1 s: Karten-Haendler <= 40 m eines Gasts, Laufzeit-Haendler (Shakes/Military, wandernd) immer; max. 20/Lauf
function I.TrdAddr(Locs, Now)
    local N, R2 = 0, K.TRADER_RADIUS * K.TRADER_RADIUS
    for _, E in ipairs(I.TraderList(Now, 30)) do
        if N >= 20 then break end
        if not S.TrdRep[E.F] then
            local Want = not E.Ld
            if not Want then
                for _, L in ipairs(Locs) do
                    if I.Dist2(L, E.X, E.Y, E.Z) <= R2 then Want = true break end
                end
            end
            local O = Want and I.Fresh(E)
            if O then
                N = N + 1
                I.TrdMakeRep(O, E.F)
            end
        end
    end
end

function I.TrdDead(Pawn)
    local Hp = tonumber(I.Safe(function()
        local Med = Pawn.MedicalComponent
        return I.Alive(Med) and Med.Health or nil
    end))
    return Hp ~= nil and Hp <= 0
end

-- Anzeigename eines Gasts (PlayerState), sonst PC-Name
function I.TrdWho(G)
    local Nm = I.Safe(function()
        local PC = Net.PC(G)
        local PS = PC and PC.PlayerState
        if not I.Alive(PS) then return nil end
        local V = PS:GetPlayerName()
        return type(V) == "string" and V or V:ToString()
    end)
    if type(Nm) ~= "string" or Nm == "" then Nm = tostring(G.PCName or "?") end
    return Nm
end

-- Andere aktive Kunden eines Haendlers (ohne Except). Rueckgabe Anzahl, eine Sitzung
function I.TrdCust(Tid, Except)
    local N, Other = 0, nil
    for Key, Ss in pairs(S.TrdS) do
        if Ss.Tid == Tid and Key ~= Except and Net.Guests[Key] then N, Other = N + 1, Other or Ss end
    end
    return N, Other
end

function I.TrdDrop(Key, Why)
    local Ss = Key and S.TrdS[Key]
    if not Ss then return end
    S.TrdS[Key] = nil
    Log("Haendler-Sitzung von %s an %s beendet (%s)", tostring(Ss.Who or Key), I.Short(Ss.F), tostring(Why))
end

-- trd_open (Host): Haendler zur Gast-Meldung finden, pruefen (Abstand zur Server-Figur, JigCanInteract, Sperre),
-- Sitzung anlegen. Antwort "ok|Tid|Geld|Kunden" bzw. "no|Grund[|Name]"
function I.TrdOpen(G, Ref, Now)
    local H = I.HState(G.Key)
    if Now - (H.TrdAt or -math.huge) < 0.3 then return "no|rate" end
    H.TrdAt = Now
    local Pawn = I.HostPawn(G)
    local L = Pawn and I.Loc(Pawn)
    if not L or I.TrdDead(Pawn) then return "no|figur" end
    local O, E = I.TrdResolve(Ref, L, Now)
    if not O then
        I.WarnOnce("tro_" .. tostring(G.Key) .. tostring(Ref), "trd_open: kein passender Haendler beim Server (%s, %s)",
            tostring(G.PCName or G.Key), tostring(Ref))
        return "no|weit"
    end
    local Ol = I.Loc(O)
    if not Ol or I.Dist2(Ol, L.X, L.Y, L.Z) > K.TRD_HOST_R * K.TRD_HOST_R then return "no|weit" end
    -- gleiche Bedingung wie SERVER_RequestData (MasterTrader: AI ~= 7,8 und nicht tot; TraderMaster: immer true)
    local CanT = {}
    if pcall(function() O:JigCanInteract(CanT) end) and I.Out(CanT, "Result") == false then return "no|tot" end
    if I.On("trd_addr") then I.TrdMakeRep(O, E.F) end
    local Tid = E.Ld and E.N or S.TrdTid[E.F]
    if not Tid then
        S.TrdN = S.TrdN + 1
        Tid = "r" .. S.TrdN
        S.TrdTid[E.F] = Tid
    end
    local Old = S.TrdS[G.Key]
    if Old and Old.Tid ~= Tid then I.TrdDrop(G.Key, "anderer Haendler") end
    local N, Other = I.TrdCust(Tid, G.Key)
    local Who = I.TrdWho(G)
    if N > 0 and I.On("trd_lock") then
        local OWho = Other and Other.Who or "?"
        Log("%s: Haendler %s belegt von %s", Who, I.Short(E.F), OWho)
        return "no|busy|" .. Net.Enc(OWho)
    end
    S.TrdS[G.Key] = { Tid = Tid, F = E.F, At = Now, Who = Who }
    local T = S.TrdT[Tid] or {}
    S.TrdT[Tid] = T
    T.F, T.M = E.F, I.TrdMoney(O)
    T.Ids = T.Ids or I.TrdIds(O)
    if not (Old and Old.Tid == Tid) then
        Log("%s handelt mit %s (%s, Geld %s, Kunden %d)", Who, I.Short(E.F), Tid, T.M, N + 1)
    end
    return string.format("ok|%s|%s|%d", Net.Enc(Tid), T.M, N + 1)
end

-- Host 0,25 s: Sitzungen pruefen (Trennung, Tod, Abstand), Geld-Aenderung und Restock an die Kunden
function I.TrdHost(Now)
    if Now < (S.TrdAt or 0) then return end
    S.TrdAt = Now + 0.25
    if #S.Prime > 0 and I.On("trd_prime") then I.HostPrime(Now) end
    for Key, Ss in pairs(S.TrdS) do
        local G = Net.Guests[Key]
        local Pawn = G and G.Epoch and I.HostPawn(G)
        local O = I.Safe(function() return StaticFindObject(Ss.F) end)
        local Why
        if not (G and G.Epoch) then
            Why = "getrennt"
        elseif not Pawn or I.TrdDead(Pawn) then
            Why = "Figur tot/weg"
        elseif not I.Alive(O) then
            Why = "Haendler weg"
        elseif Now - (Ss.Hb or Ss.At or Now) > K.TRD_HB_TTL then
            -- Gast-Seite meldet sich nicht mehr (trd_sess beim Gast abgeschaltet, trd_close verloren): Sperre freigeben
            Why = "keine Rueckmeldung"
        else
            local L, Ol = I.Loc(Pawn), I.Loc(O)
            if L and Ol and I.Dist2(L, Ol.X, Ol.Y, Ol.Z) > K.TRD_FAR * K.TRD_FAR then
                Ss.Far = Ss.Far or Now
                if Now - Ss.Far >= 3 then Why = "zu weit" end
            else
                Ss.Far = nil
            end
        end
        if Why then I.TrdDrop(Key, Why) end
    end
    for Tid, T in pairs(S.TrdT) do
        local Cust = {}
        for Key, Ss in pairs(S.TrdS) do
            if Ss.Tid == Tid then Cust[#Cust + 1] = Key end
        end
        local O = nil
        if #Cust > 0 then O = I.Safe(function() return StaticFindObject(T.F) end) end
        if not I.Alive(O) then
            S.TrdT[Tid] = nil
        else
            local M = I.TrdMoney(O)
            if M ~= T.M then
                T.M = M
                for _, Key in ipairs(Cust) do Net.Send("trd_m", Net.Enc(Tid) .. "|" .. M, Key, 1) end
            end
            local Ids = I.TrdIds(O)
            if I.On("trd_reset") and Ids == 0 and (T.Ids or 0) > 0 then
                Log("Haendler %s: Restock beim Host, %d Kunden informiert", I.Short(T.F), #Cust)
                for _, Key in ipairs(Cust) do Net.Send("trd_rs", Net.Enc(Tid), Key, 1) end
            end
            if Ids then T.Ids = Ids end
        end
    end
end

-- Gast zu einem Objektpfad (Figur selbst oder Unterobjekt der Figur, z. B. ihre Jig-Komponente)
function I.GuestByPath(P)
    if type(P) ~= "string" then return nil end
    local Hit
    Net.ForEachGuest(function(G)
        if Hit or not G.Epoch then return end
        local Pawn = I.HostPawn(G)
        local PP = Pawn and I.Path(Pawn)
        if PP and (P == PP or P:sub(1, #PP + 1) == PP .. ".") then Hit = G end
    end)
    return Hit
end

-- DLL-Ereignis trd_note: CreateNotificationUI(..., Marker_Trader, ...) aus CheckVendorAmountOfMoney; Aufrufer = die
-- Spieler-Komponente, auf der "Handle Comp to Comp Move" lief (= Gast-Komponente)
function I.TrdNoteEv(Ev)
    local Hit = false
    for N = 1, tonumber(Ev.N) or 0 do
        local V = Ev["a" .. N]
        if type(V) == "string" and V:find("Marker_Trader", 1, true) then Hit = true break end
    end
    if not Hit then return end
    local G = I.GuestByPath(I.NoCls(Ev.caller))
    -- inv_trdnote: CreateNotificationUI(..., self = Gast-Jig) erreicht den Gast schon ueber den ls_ui-Proxy-HUD -> sonst
    -- doppelter Hinweis
    if G and I.On("inv_trdnote") and Net.Has("ui_note2", G) and Core.Flag("ui_v2", true) == true and Core.Flag("ui_note", true) == true then
        I.WarnOnce("trnp_" .. tostring(G.Key), "Hinweis 'Trader does not have enough money' fuer %s kommt ueber ls_ui (kein trd_note)",
            tostring(G.PCName or G.Key))
        return
    end
    if G and Net.Has("trd1", G) then
        Net.Send("trd_note", "money", G, 0)
        I.WarnOnce("trn_" .. tostring(G.Key), "Hinweis 'Trader does not have enough money' an %s", tostring(G.PCName or G.Key))
    end
end

-- DLL-Ereignis trd_dlg (Eintritt unterdrueckt): Haendler-Fenster fuer eine Gastfigur beim Host -> Gast oeffnet selbst
function I.TrdDlgEv(Ev)
    local G = I.GuestByPath(I.NoCls(Ev.a1))
    local Ctx = I.NoCls(Ev.self)
    if not (G and Ctx and Net.Has("trd1", G)) then return end
    local H, Now = I.HState(G.Key), os.clock()
    if Now - (H.TrdDlgAt or -math.huge) < 1 then return end
    H.TrdDlgAt = Now
    local O = I.Safe(function() return StaticFindObject(Ctx) end)
    if not I.Alive(O) then return end
    if I.On("trd_addr") then I.TrdMakeRep(O, Ctx) end
    local Ref = I.TrdRef(O)
    if Ref then
        Net.Send("trd_ui", Ref, G, 0)
        Log("Haendler-Fenster %s lief beim Host fuer %s - an den Gast weitergegeben", I.Short(Ctx), tostring(G.PCName or G.Key))
    end
end

-- Ereignisse der eigenen Beobachtungen abholen (eigener Cursor je Tag; erster Abruf verwirft alte Ereignisse)
function I.TrdEvents()
    if not (Native and S.TrdWOn) then return end
    for Tag, Fn in pairs({ trd_note = I.TrdNoteEv, trd_dlg = I.TrdDlgEv }) do
        if S.TrdWOn[Tag] then
            local List = I.Safe(function() return Native.ReadEvents(Tag) end) or {}
            if S.TrdEv[Tag] then
                for _, Ev in ipairs(List) do I.Try(Tag, Fn, Ev) end
            end
            S.TrdEv[Tag] = true
        end
    end
end

-- DLL-Beobachtungen setzen (alle 2 s geprueft, geschrieben nur bei Aenderung). Ohne DLL: leer, Lua-Rueckfaelle
function I.TrdWatch(Now)
    if Now < (S.TrdWAt or 0) then return end
    S.TrdWAt = Now + 2
    if not (Native and type(Native.SetWatch) == "function") then return end
    local Avail = I.Safe(function() return Native.Available() end, false) == true
    local List, On, Tags = {}, {}, {}
    if Avail and I.TrdOn("trd_v1") and not I.Loading() then
        if Net.Side == "host" then
            if I.On("trd_note") then
                List[#List + 1] = { Func = K.TRD_NOTE, Tag = "trd_note", Mode = "observe", At = "call" }
                On.trd_note = true
            end
            -- nur kopfloser Host (Geist handelt nie); sonst wuerde der Host-Spieler unterdrueckt
            if I.On("trd_dlg") and type(A.Coop.Server) == "table" then
                for _, P in ipairs(K.TRD_DLG) do List[#List + 1] = { Func = P, Tag = "trd_dlg", Mode = "suppress", At = "entry" } end
                On.trd_dlg = true
            end
        elseif Net.Side == "client" and I.On("trd_reset") then
            List[#List + 1] = { Func = K.TRD_RESET, Tag = "trd_reset", Mode = "suppress", At = "entry" }
            On.trd_reset = true
        end
    end
    for Tag in pairs(On) do Tags[#Tags + 1] = Tag end
    table.sort(Tags)
    local Sig = tostring(Net.Side) .. ":" .. table.concat(Tags, ",")
    if Sig == S.TrdWSig then return end
    local ok, err = pcall(Native.SetWatch, #List > 0 and List or nil, "ls_inv_trd")
    if not ok then Core.Fail("trd_v1", err) return end
    S.TrdWSig, S.TrdWOn = Sig, On
    if #Tags > 0 or S.TrdWLogged then Log("Haendler-Beobachtung (DLL): %s", #Tags > 0 and table.concat(Tags, ", ") or "aus") end
    S.TrdWLogged = #Tags > 0
end

-- ------------------------------------------------------------------------------------------------ Gast

-- Gerade offenes Haendler-Fenster: Haendler <= 8 m, dessen Vendor-Fenster sichtbar ist und dessen CurrentActor (falls
-- gesetzt) die eigene Figur ist. Nur aufrufen, wenn das eigene Inventar sichtbar ist.
function I.TrdOpenLocal(Pawn, Now)
    local L = I.Loc(Pawn)
    if not L then return nil end
    local PN, R2 = I.Name(Pawn), K.TRD_OPEN_R * K.TRD_OPEN_R
    for _, E in ipairs(I.TraderList(Now, 30)) do
        if E.Wd or I.Dist2(L, E.X, E.Y, E.Z) <= 3000 * 3000 then
            local O = I.Fresh(E)
            local Ol = O and I.Loc(O)
            if Ol and I.Dist2(L, Ol.X, Ol.Y, Ol.Z) <= R2 and I.JigVis(I.Safe(function() return O.BP_JigMultiplayer end)) then
                local CA = I.Safe(function() return O.CurrentActor end)
                if not I.Alive(CA) or I.Name(CA) == PN then return O, E end
            end
        end
    end
    return nil
end

-- Haendler-Fenster ueber den Spielweg oeffnen (OnExecuteInteractDialogue: SetupInventoryWidget, AddJigWidgetToContent,
-- RequestServerData, Abstands-Timer). Nie doppelt: bei sichtbarem Vendor-Fenster nichts tun.
function I.TrdShowUi(O, Pawn, Why, Flag)
    local VJ = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(VJ) or I.JigVis(VJ) then return false end
    -- TraderMaster liest self.CurrentActor (OnExecuteInteract setzt ihn lokal); fehlt er, eigene Figur eintragen
    if not I.Alive(I.Safe(function() return O.CurrentActor end)) then pcall(function() O.CurrentActor = Pawn end) end
    local ok, err = pcall(function() O:OnExecuteInteractDialogue(Pawn) end)
    if not ok then Core.Fail(Flag, err) end
    Log("Haendler-Fenster %s geoeffnet (%s)%s", tostring(I.Name(O)), Why, ok and "" or " - Fehler")
    return ok
end

function I.TrdReply(Pawn, T, R)
    if R.F ~= T.Open then return end                         -- Fenster inzwischen zu bzw. anderer Haendler
    local Verdict, Rest = tostring(R.R):match("^(%a+)|?(.*)$")
    if Verdict == "ok" then
        local Tid, M, N = Rest:match("^([^|]*)|([^|]*)|(%d+)$")
        if not Tid then return end
        T.Tid, T.M = Net.Dec(Tid), tonumber(M)
        if (tonumber(N) or 1) > 1 and I.On("trd_busy") then
            pcall(A.ShowNote, "Ein anderer Spieler handelt gerade auch mit diesem Haendler")
        end
    elseif Verdict == "no" then
        local Why, Who = Rest:match("^(%a+)|?(.*)$")
        if Why == "rate" then
            T.Open = nil                                     -- zu schnell neu geoeffnet: naechster Takt fragt erneut
        elseif Why == "busy" then
            Who = Net.Dec(Who ~= "" and Who or "?")
            pcall(A.ShowNote, "Haendler handelt gerade mit " .. Who)
            I.CloseOwnInv(Pawn)
            Log("Haendler belegt (%s) - Fenster geschlossen", Who)
        elseif Why == "weit" and T.Ld == false then
            -- Laufzeit-Haendler beim Host (noch) nicht gefunden: Fenster zu, Liste neu (TrdGhost/TraderList scannen frisch)
            I.CloseOwnInv(Pawn)
            pcall(A.ShowNote, "Haendler wird vom Server geladen - bitte erneut oeffnen")
            S.Traders = nil
            Log("Laufzeit-Haendler beim Host nicht gefunden - Fenster geschlossen, Liste wird neu gelesen")
        else
            I.WarnOnce("trdno_" .. tostring(Why), "Haendler-Sitzung abgelehnt (%s) - Rueckfall inv_trader", tostring(Why))
        end
    else
        I.WarnOnce("trderr", "Haendler-Sitzung ohne Antwort (%s) - Rueckfall inv_trader", tostring(Rest))
    end
end

-- Gast 0,25 s: Sitzung oeffnen/schliessen, Server-Geld in die offene Kopie, leere UI melden, Neu-Oeffnen nach Restock
function I.TrdClient(Pawn, Now)
    local T = C.Trd
    if T.Reply then
        local R = T.Reply
        T.Reply = nil
        I.TrdReply(Pawn, T, R)
    end
    local O, E
    local OwnVis = I.JigVis(I.Safe(function() return Pawn.BP_JigMultiplayer end))
    -- FindAllOf nur beim Oeffnen des Inventars (hoechstens alle 2 s), sonst Liste bis 30 s alt (repl. Haendler neu)
    if OwnVis and not T.OwnVis and Now - S.TradersAt > 2 then S.Traders = nil end
    T.OwnVis = OwnVis
    if OwnVis then O, E = I.TrdOpenLocal(Pawn, Now) end
    local F = E and E.F or nil
    if T.Open and T.Open ~= F then                           -- fallende Flanke: Sitzung beim Host freigeben
        -- P0 wie trd_open: sonst ueberholt ein gleich danach gesendetes trd_open (P0) das Schliessen und der Host
        -- loescht die NEUE Sitzung (Haendlerwechsel, Restock-Neuoeffnen)
        Net.Send("trd_close", Net.Enc(T.Tid or "?"), nil, 0)
        T.Open, T.Tid, T.M, T.Prime = nil, nil, nil, nil
    end
    if F and T.Open ~= F then                                -- steigende Flanke
        T.Open, T.OpenAt, T.Tid, T.M, T.Prime, T.HbAt = F, Now, nil, nil, false, Now + K.TRD_HB
        T.Ld = E.Ld == true                                  -- Karten-Haendler (RF_WasLoaded) oder Laufzeit (I.TrdReply)
        local Ref = I.TrdRef(O)
        if Ref then
            Net.Request("trd_open", Ref, function(Reply, _, Err)
                if C.Trd then C.Trd.Reply = { F = F, R = Reply or ("err|" .. tostring(Err)) } end
            end, 8, nil, 0)
        end
    end
    local Ro = T.Reopen
    if Ro and Now >= Ro.At then
        T.Reopen = nil
        local RO = I.Safe(function() return StaticFindObject(Ro.F) end)
        if I.Alive(RO) then I.TrdShowUi(RO, Pawn, "Restock", "trd_rsui") end
    end
    if not (T.Open and O) then return end
    if T.Tid and Now >= (T.HbAt or 0) then                   -- Lebenszeichen der offenen Sitzung (Host: TRD_HB_TTL)
        T.HbAt = Now + K.TRD_HB
        Net.Send("trd_hb", Net.Enc(T.Tid), nil, 1)
    end
    local VJ = I.Safe(function() return O.BP_JigMultiplayer end)
    if not I.Alive(VJ) then return end
    -- GetText (W_TraderUI) liest jedes Bild die lokale VendorCurrentCurrencyAmount
    if T.M then
        pcall(function()
            if math.abs((tonumber(VJ.VendorCurrentCurrencyAmount) or 0) - T.M) >= 0.5 then VJ.VendorCurrentCurrencyAmount = T.M end
        end)
    end
    if T.Tid and T.Prime == false and I.On("trd_prime") and Now - T.OpenAt >= math.max(2.5, 4 * I.Rtt(Now) + 1) then
        T.Prime = true
        if I.LootItems(VJ) == 0 then
            Net.Send("trd_prime", Net.Enc(T.Tid), nil, 1)
            I.WarnOnce("trp_" .. tostring(T.Tid), "Haendler %s leer geoeffnet - Host um Server-Daten gebeten", tostring(T.Tid))
        end
    end
end

-- trd_dlg (Gast): Host hat das Fenster fuer uns nicht geoeffnet (unterdrueckt) -> lokal ueber den Spielweg oeffnen
function I.TrdUiApply(Pawn, Now)
    local U = C.TrdUi
    C.TrdUi = nil
    if not U or Now - U.T > 5 then return end
    local O = I.TrdResolve(U.Ref, I.Loc(Pawn), Now)
    if O then
        I.TrdShowUi(O, Pawn, "vom Host weitergegeben", "trd_dlg")
    else
        I.WarnOnce("trdui_" .. U.Ref, "trd_ui: Haendler %s lokal nicht gefunden", U.Ref)
    end
end

-- trd_ghost (Gast): lokal gespawnte Haendler (HasAuthority beim Gast, kein Karten-Actor) entfernen. Repl. Kopien
-- (Role SimulatedProxy) und Karten-Haendler (RF_WasLoaded) nie. Erste 90 s jede Sekunde, danach alle 5 s.
function I.TrdGhost(Pawn, Now)
    if Now < (C.TrdGhostAt or 0) then return end
    C.TrdGhost0 = C.TrdGhost0 or Now
    C.TrdGhostAt = Now + ((Now - C.TrdGhost0 < 90) and 1 or 5)
    local Flag = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not Flag then return end
    local N, Seen = 0, {}
    for _, Cls in ipairs(K.TRD_GHOST) do
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            if N >= 10 then break end
            local Nm = I.Alive(O) and I.Name(O)
            if Nm and not Seen[Nm] and not Nm:find("^Default__") then
                Seen[Nm] = true
                if I.Safe(function() return O:HasAnyFlags(Flag) end, true) == false
                    and I.Safe(function() return O:HasAuthority() end) == true then
                    if I.JigVis(I.Safe(function() return O.BP_JigMultiplayer end)) then I.CloseOwnInv(Pawn) end
                    local ok = pcall(function() O:K2_DestroyActor() end)
                    N = N + 1
                    Log("Lokale Haendler-Kopie %s entfernt (%s)", Nm, ok and "Host-Haendler kommt repliziert" or "Fehler")
                end
            end
        end
    end
    if N > 0 then S.Traders = nil end
end

-- Review 1 inv_station_ghost (Gast, 1-s-Takt, hoechstens alle 2 s, mit inv_scan_backoff ohne offene lokale Kopie alle 10 s
-- und nur mit Host-Cap inv2b): Laufzeit-Station (CAC-Kind eines replizierten
-- PrefabMaster_C: Role Authority beim Gast, ohne RF_WasLoaded) entfernen, sobald die Host-Kopie (Role SimulatedProxy,
-- I.StationTab) <= 1 m daneben steht. Sonst doppeltes Licht/Audio und die lokale CompRef loest beim Host nicht auf
function I.StationGhost(Pawn, Now)
    if Now < (C.StGhostAt or 0) then return end
    C.StGhostAt = Now + 2
    local Flag = EObjectFlags and EObjectFlags.RF_WasLoaded
    if not Flag then return end
    local N, Wait = 0, false
    for Cls in pairs(K.STATION_TAB) do
        local Rep, Loc = {}, {}
        for _, O in ipairs(FindAllOf(Cls) or {}) do
            local Nm = I.Alive(O) and I.Name(O)
            if Nm and not Nm:find("^Default__") then
                local R = I.Safe(function() return O.Role end)
                if R == 1 then
                    Rep[#Rep + 1] = I.Loc(O)
                elseif R == K.ROLE_AUTHORITY and I.Safe(function() return O:HasAnyFlags(Flag) end, true) == false then
                    Loc[#Loc + 1] = O
                end
            end
        end
        for _, O in ipairs(Loc) do
            if N >= 10 then Wait = true break end
            local L = I.Alive(O) and I.Loc(O)
            local Done = false
            for _, P in ipairs(Rep) do
                if L and P and I.Dist2(L, P.X, P.Y, P.Z) <= 10000 then
                    if I.JigVis(I.Safe(function() return O.BP_JigMultiplayer end)) then I.CloseOwnInv(Pawn) end
                    local Nm = I.Name(O)
                    local ok = pcall(function() O:K2_DestroyActor() end)
                    N, Done = N + 1, true
                    Log("Lokale Stations-Kopie %s entfernt (%s)", tostring(Nm), ok and "Host-Station kommt repliziert" or "Fehler")
                    break
                end
            end
            if not Done then Wait = true end
        end
    end
    -- Review 3 inv_scan_backoff: 2-s-Takt nur, solange eine lokale Kopie auf ihre Host-Kopie wartet (beide erscheinen
    -- zusammen, wenn eine Siedlung relevant wird). Nichts Lokales offen -> naechste Suche erst in 10 s. Bewusst NICHT an
    -- "keine replizierte Station" gekoppelt: sonst bliebe eine frische lokale Kopie bis zur Pause-Laenge doppelt stehen
    if not Wait and I.On("inv_scan_backoff") then C.StGhostAt = Now + 10 end
end

function I.TrdTick(Now)
    I.TrdWatch(Now)
    if I.Loading() or not I.TrdOn("trd_v1") then return end
    I.CheckGen()
    if Net.Side == "host" then
        if I.On("trd_sess") then I.Try("trd_sess", I.TrdHost, Now) end
        I.TrdEvents()
    elseif Net.Side == "client" then
        if not (Net.Has("trd1") and Net.Host and Net.Host.Ready) then return end
        local Pawn = I.OwnPawn()
        if not Pawn then return end
        C.Trd = C.Trd or {}
        if I.On("trd_sess") then I.Try("trd_sess", I.TrdClient, Pawn, Now) end
        if C.TrdUi and I.On("trd_dlg") then I.Try("trd_dlg", I.TrdUiApply, Pawn, Now) end
        if I.On("trd_ghost") and Net.Get("trd_cfg", "rt") == "1" then I.Try("trd_ghost", I.TrdGhost, Pawn, Now) end
    end
end

-- ================================================================================================ Handler

M.Handlers = {
    -- Gast -> Host: Platzhalter / lokal-only-Item anlegen. "uid32|path|n|why|ageMs"
    inv_pend = function(Data, G, Msg)
        if Net.Side ~= "host" or not Msg.Rid then return end
        -- voruebergehende Ablehnung = "wait" (Gast versucht spaeter erneut, loescht den Platzhalter nicht)
        if not (I.On("inv_v2b") and I.On("inv_pend") and Net.Has("inv2b", G) and G.Ready) then return Net.Reply(Msg, "wait|aus") end
        local Uid, Path, N, Why, Age = tostring(Data):match("^(%x+)|([^|]*)|(%d+)|(%a)|(%d+)$")
        if not Uid or #Uid ~= 32 then Net.SecWarn(G, G.Key, "inv_pend") return Net.Reply(Msg, "no|format") end
        local H, Now = I.HState(G.Key), os.clock()
        -- gleiche UID: schon entschieden -> dieselbe Antwort; noch in der Warteschlange -> nur die Antwortadresse ersetzen
        H.Done = H.Done or {}
        local Dn = H.Done[Uid]
        if Dn and Now - Dn.T <= K.DONE_TTL then return Net.Reply(Msg, Dn.R) end
        for _, J in ipairs(H.PendQ) do
            if J.Uid == Uid then J.Msg = Msg return end
        end
        local W = H.Rate
        if Now - W.Since >= 60 then W.Since, W.N = Now, 0 end
        W.N = W.N + 1
        if W.N > 60 or #H.PendQ >= 20 then return Net.Reply(Msg, "wait|rate") end
        for U, E in pairs(H.Done) do if Now - E.T > K.DONE_TTL then H.Done[U] = nil end end
        H.PendQ[#H.PendQ + 1] = { Msg = Msg, Uid = Uid, Path = Net.Dec(Path), N = math.max(1, math.min(tonumber(N) or 1, 50)),
                                  Why = Why, Age = math.min((tonumber(Age) or 0) / 1000, 30), T0 = Now }
    end,

    -- Gast -> Host: Platzhalter nach "ok|" entfernt (Slot frei) -> vorgemerkte Anlage (inv_pend_defer) sofort. "uid32"
    inv_pfree = function(Data, G)
        if Net.Side ~= "host" or not (I.On("inv_pend_ack") and Net.Has("invpf", G)) then return end
        local Uid = tostring(Data or ""):match("^(%x+)$")
        if not Uid or #Uid ~= 32 then Net.SecWarn(G, G.Key, "inv_pfree") return end
        local H = S.H[G.Key]
        for _, D in ipairs(H and H.Defer or {}) do
            if D.Uid == Uid and not D.Acked then D.Acked, D.At = true, math.min(D.At, os.clock()) return end
        end
    end,

    -- Gast -> Host: lokal entnommene Menge auch beim Server entnehmen. "uid16|n|path"
    inv_use = function(Data, G, Msg)
        if Net.Side ~= "host" or not Msg.Rid then return end
        if not (I.On("inv_v2b") and I.On("inv_use") and Net.Has("inv2b", G) and G.Ready) then return Net.Reply(Msg, "no|aus") end
        local Uid, N, Path = tostring(Data):match("^(%x+)|(%d+)|(.*)$")
        if not Uid or #Uid < 16 then Net.SecWarn(G, G.Key, "inv_use") return Net.Reply(Msg, "no|format") end
        local H, Now = I.HState(G.Key), os.clock()
        local W = H.Rate
        if Now - W.Since >= 60 then W.Since, W.N = Now, 0 end
        W.N = W.N + 1
        if W.N > 60 then return Net.Reply(Msg, "no|rate") end
        local Pawn = I.HostPawn(G)
        if not Pawn then return Net.Reply(Msg, "no|figur") end
        local ok, R = pcall(I.HostUse, G, G.Key, H, Pawn, { Uid = Uid, N = math.max(1, math.min(tonumber(N) or 1, 50)), Path = Net.Dec(Path) })
        if not ok then Core.Fail("inv_use", R) R = "no|fehler" end
        Net.Reply(Msg, R)
    end,

    -- Gast -> Host: Kiste als durchsucht (1) bzw. Lager (2) markiert, Lager-Markierung aufgehoben (3, inv_unmark).
    -- "name|state"
    inv_loot = function(Data, G)
        if Net.Side ~= "host" or not (I.On("inv_v2b") and I.On("inv_lflag")) then return end
        local Name, St = tostring(Data):match("^([^|]+)|([123])$")
        if not Name then Net.SecWarn(G, G.Key, "inv_loot") return end
        Name = Net.Dec(Name)
        local Pawn = I.HostPawn(G)
        local L = Pawn and I.Loc(Pawn)
        if not L then return end
        for _, E in ipairs(I.NearConts(L, 1500, 64)) do
            if E.N == Name then
                local O = I.Fresh(E)
                if not O then return end
                local Cur = S.LState[E.F]
                if St == "3" then
                    -- (c) nur eine vom Host gefuehrte Lager-Kiste; Besitz/Abstand/Claim im Host-Task (I.Unmark)
                    if I.On("inv_unmark") and Net.Has("invu", G) and Cur and Cur.St == "2" and #S.ScavQ < 64
                        and I.RateOk(G, "u" .. E.N, "inv_loot") then
                        S.ScavQ[#S.ScavQ + 1] = { T = "u", Key = G.Key, F = E.F, N = E.N }
                    end
                    return
                end
                -- neue Lager-Markierung schaltet das Nachfuellen fuer alle ab -> Drossel, Abstand (wie I.Unmark), Claim
                if St == "2" and not (Cur and Cur.St == "2") then
                    if not I.RateOk(G, "m" .. E.N, "inv_loot") then return end
                    local Ol = I.Loc(O)
                    if not Ol or I.Dist2(Ol, L.X, L.Y, L.Z) > 800 * 800 then Net.SecWarn(G, G.Key, "inv_loot_dist") return end
                    if not I.CanUse(G, O) then
                        Net.SecWarn(G, G.Key, "inv_loot_bad")
                        I.Note(G, "Kein Zugriff")
                        return
                    end
                end
                -- nie herabstufen: Lager (2) bleibt Lager (sonst Nachfuellen -> ClearContainer loescht Eingelagertes)
                if St == "1" and ((Cur and Cur.St == "2") or I.Safe(function() return O.MarkedAsStorageContainer end) == true) then
                    return
                end
                -- (a) neuer Uebergang durchsucht (Host-Kopie war false): Pluender-XP wie HoldToInteract @03e4, einmal je
                -- Kiste und Nachfuellen (S.ScavDone, geloescht in I.HostLootRefill). Picklock-Kisten: XP bei
                -- LockpickSuccessful (ls_build), Werkzeug-Kisten: inv_tool
                local Was = I.Safe(function() return O.ContainerLooted end)
                -- (d) Werkzeug-Kiste ohne inv_tool (Gast hat inv_toolxp aus): Host-Regel gilt -> wie inv_tool ueber I.ToolOne
                -- (Werkzeug-Besitz, Haltbarkeit, Dieb-XP); nie direkt als durchsucht fuehren. I.ToolFallback ruft nur bei
                -- inv_toolxp aus hierher -> keine Schleife
                if Was == false and E.T and I.On("inv_toolxp") then
                    if #S.ScavQ < 64 and I.RateOk(G, "tl" .. E.N, "inv_loot") then
                        S.ScavQ[#S.ScavQ + 1] = { T = "t", Key = G.Key, N = E.N, U = "" }
                    end
                    return
                end
                -- neuer Uebergang "durchsucht" gilt fuer alle -> Abstand wie St "2"/I.Unmark; Nachfuellen (HoldToInteract
                -- @0314) hier starten, unabhaengig von inv_scavxp/LivePawn/HoldOk (I.LootXP bucht nur noch XP)
                local New = Was == false and St == "1"
                if New then
                    local Ol = I.Loc(O)
                    if not Ol or I.Dist2(Ol, L.X, L.Y, L.Z) > 800 * 800 then Net.SecWarn(G, G.Key, "inv_loot_dist") return end
                end
                if Was == false and E.Lc and I.On("inv_scavxp") and not S.ScavDone[E.F] and #S.ScavQ < 64 then
                    S.ScavDone[E.F] = true
                    S.ScavQ[#S.ScavQ + 1] = { T = "l", Key = G.Key, F = E.F }
                end
                pcall(function() O.ContainerLooted = true end)
                if New and (E.Lc or E.T) then
                    pcall(function()
                        local Jig = O.BP_JigMultiplayer
                        if I.Alive(Jig) then Jig:StartRefillTimer(false) end
                    end)
                end
                if St == "2" then
                    pcall(function() O.MarkedAsStorageContainer = true end)
                    pcall(function()
                        local Jig = O.BP_JigMultiplayer
                        if I.Alive(Jig) then Jig["DoesContainerRefillLoot?"] = false end
                    end)
                end
                -- Lager: wer zuerst markiert hat, bleibt Besitzer der Markierung (I.MarkOk)
                local By = St == "2" and ((Cur and Cur.St == "2" and Cur) or { Gid = I.Gid(G), Key = G.Key }) or nil
                S.LState[E.F] = { N = E.N, St = St, Gid = By and By.Gid, Key = By and By.Key }
                Net.State("inv_lflag", E.N, St, 2)
                return
            end
        end
    end,

    -- Gast -> Host (State): gerade offene Kiste
    inv_open = function(Value, G)
        if Net.Side ~= "host" or not I.On("inv_lock") then return end
        for Name, O in pairs(S.Open) do if O.Key == G.Key then S.Open[Name] = nil end end
        if not Value or Value == "" then return end
        local Other = S.Open[Value]
        if Other and Other.Key ~= G.Key and Net.Guests[Other.Key] then
            Net.Send("inv_busy", Net.Enc(Other.Name or "?"), G, 1)
        else
            S.Open[Value] = { Key = G.Key, Name = G.PCName }
        end
    end,

    -- Gast -> Host: Kiste/Leiche geoeffnet, Loot-UI blieb leer. "class|x|y|z" (Leichen: Mesh-Lage)
    inv_carc = function(Data, G)
        if Net.Side ~= "host" or not I.On("inv_v2b") then return end
        if not (I.On("inv_lootprime") or I.OnOff("inv_carcass")) then return end
        -- Runde 9 CORE-28: optional 5. Feld = Alter der offenen UI in ms (nur Gaeste mit Cap invps)
        local Cls, X, Y, Z, Ms = tostring(Data):match("^([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|?(%d*)$")
        if not Cls then Net.SecWarn(G, G.Key, "inv_carc") return end
        Cls, X, Y, Z = Net.Dec(Cls), tonumber(X), tonumber(Y), tonumber(Z)
        local Age = Ms ~= "" and math.min((tonumber(Ms) or 0) / 1000, 120) or nil
        -- nur Blueprint-Klassennamen; bekannte Fremd-Klassen ohne FindAllOf abweisen; hoechstens 1 Meldung / s
        if #Cls > 80 or not Cls:match("^%a[%w_]*_C$") or S.CarcFam[Cls] == false then return end
        local H, Now = I.HState(G.Key), os.clock()
        if Now - (H.CarcAt or -math.huge) < 1 then return end
        H.CarcAt = Now
        local Pawn = I.HostPawn(G)
        local L = Pawn and I.Loc(Pawn)
        if not L or I.Dist2(L, X, Y, Z) > 1000 * 1000 then return end
        I.Try("inv_lootprime", I.HostCarc, G, H, Cls, L, X, Y, Z, Now, Age)
    end,

    -- Host -> Gast (State, nur fuer diesen Gast): Digest des Server-Inventars (Net.Get liest ihn)
    inv_sum = function() end,

    -- Runde 9 INV-2 Host -> Gast: Stueckzahlen nach Crafting mit vollem Inventar. "uid32:n;uid32:n..." (<= 16), nur einreihen
    inv_cnt = function(Data)
        if Net.Side ~= "client" or not I.On("inv_craft_cnt") then return end
        Data = tostring(Data or "")
        if #Data > 16 * 45 then return end
        C.CntQ = C.CntQ or {}
        for U, N in Data:gmatch("(%x+):(%d+)") do
            if #U == 32 and #C.CntQ < 32 then C.CntQ[#C.CntQ + 1] = { U = U, N = math.min(tonumber(N) or 0, 100000) } end
        end
    end,

    -- Runde 9 INV-4 Gast -> Host: Reparatur. "kind|itemUid32|kitUid32", kind w/a/t/wd/ad/rf; nur einreihen (I.HostFast)
    inv_rep = function(Data, G)
        if Net.Side ~= "host" or not (G and G.Epoch) then return end
        if not (I.On("inv_v2b") and I.On("inv_repair") and Net.Has("invrep", G)) then return end
        local Kd, U, Kit = tostring(Data or ""):match("^(%a%a?)|(%x+)|(%x+)$")
        if not Kd or not K.REP_KIT[Kd] or #U ~= 32 or #Kit ~= 32 then Net.SecWarn(G, G.Key, "inv_rep_bad") return end
        -- Review 1: Ziel = Set/Filter selbst gibt es im Spiel nicht (Set repariert/fuellt sich selbst, Verbrauch im selben Array)
        if U:upper() == Kit:upper() then Net.SecWarn(G, G.Key, "inv_rep_bad") return end
        if not I.RateOk(G, "rep" .. U, "inv_rep") or #S.RepQ >= 16 then return end
        S.RepQ[#S.RepQ + 1] = { Key = G.Key, K = Kd, U = U:upper(), Kit = Kit:upper() }
    end,

    -- Runde 9 INV-6b (K3) Gast -> Host: Lampe an "1|uid32" (Anbauteil oder Batterie; bei Aenderung und alle 5 s), aus "0|"
    -- (alle) bzw. "0|uid32". Nur Tabelle; Entladung in I.LightHost (1 s)
    inv_light = function(Data, G)
        if Net.Side ~= "host" or not (G and G.Epoch) then return end
        if not (I.On("inv_v2b") and I.On("inv_battery_drain") and Net.Has("invlt", G)) then return end
        local On, U = tostring(Data or ""):match("^([01])|(%x*)$")
        if not On or (#U ~= 0 and #U ~= 32) or (On == "1" and #U ~= 32) then Net.SecWarn(G, G.Key, "inv_light_bad") return end
        if not I.RateOk(G, "lt" .. U, "inv_light") then return end
        U = U:upper()
        local L = S.Light[G.Key] or {}
        if On == "0" then
            if U == "" then L = {} else L[U] = nil end
        elseif L[U] then
            L[U].At = os.clock()
        else
            local N = 0
            for _ in pairs(L) do N = N + 1 end
            if N < 4 then L[U] = { At = os.clock() } end
        end
        S.Light[G.Key] = next(L) and L or nil
    end,

    -- Runde 9 INV-6b (K4) Host -> Gast: Batterie der Lampe leer oder fehlt. "uid32" (leer = alle eigenen Lampen); nur
    -- einreihen, I.LightScan schaltet aus
    inv_lightoff = function(Data)
        if Net.Side ~= "client" or not I.On("inv_battery_drain") then return end
        local U = tostring(Data or ""):match("^(%x*)$")
        if not U or (#U ~= 0 and #U ~= 32) then return end
        C.LtOff = C.LtOff or {}
        if #C.LtOff < 8 then C.LtOff[#C.LtOff + 1] = U:upper() end
    end,

    -- Host -> Gast: gespeicherte Hotbar nach dem Erst-Sync
    inv_barset = function(Data)
        if Net.Side ~= "client" or not I.On("inv_bar") then return end
        if tostring(Data):match("^[%x,]+$") then C.BarWant, C.BarTry, C.BarDone = Data, 0, true end
    end,

    -- Host -> alle (State): Kiste durchsucht/Lager; nil = beim Host neu befuellt
    inv_lflag = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg.Key then return end
        C.LFlag[Msg.Key] = Value
        if Value then
            C.LSent[Msg.Key] = Value
        else
            -- (b) Refill: lokale Kopie einmal zuruecksetzen (I.ClientConts), naechstes Durchsuchen wird wieder gemeldet
            C.LSent[Msg.Key], C.LReset[Msg.Key] = nil, true
        end
    end,

    -- Runde 8 (e) Gast -> Host: Laufzeit-Kiste durchsucht. "Klasse|x|y|z"
    inv_scav = function(Data, G)
        if Net.Side ~= "host" or not (G and G.Epoch) then return end
        if not (I.On("inv_v2b") and I.On("inv_scavxp") and Net.Has("invx", G)) then return end
        local Cls, X, Y, Z = tostring(Data or ""):match("^([%w_]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
        if not Cls or not K.SCAV[Cls] then Net.SecWarn(G, G.Key, "inv_scav_bad") return end
        if not I.RateOk(G, Cls .. X .. "," .. Y .. "," .. Z, "inv_scav") or #S.ScavQ >= 64 then return end
        S.ScavQ[#S.ScavQ + 1] = { T = "s", Key = G.Key, Cls = Cls, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z) }
    end,

    -- Runde 8 (d) Gast -> Host: Werkzeug-Kiste durchsucht. "Enc(Name)|uid32 hex (oder leer)"
    inv_tool = function(Data, G)
        if Net.Side ~= "host" or not (G and G.Epoch) then return end
        if not (I.On("inv_v2b") and Net.Has("invx", G)) then return end
        local Name, Uid = tostring(Data or ""):match("^([^|]+)|(%x*)$")
        if not Name or (#Uid ~= 0 and #Uid ~= 32) then Net.SecWarn(G, G.Key, "inv_tool_bad") return end
        Name = Net.Dec(Name)
        if not Name or #Name > 128 then Net.SecWarn(G, G.Key, "inv_tool_bad") return end
        if not I.RateOk(G, "t" .. Name, "inv_tool") or #S.ScavQ >= 64 then return end
        -- ohne inv_toolxp beim Host: sonst bliebe die Kiste beim Host undurchsucht (Gast sendet kein inv_loot "1")
        if not I.On("inv_toolxp") then I.ToolFallback(G, Name) return end
        S.ScavQ[#S.ScavQ + 1] = { T = "t", Key = G.Key, N = Name, U = Uid }
    end,

    -- Host -> alle (State): Haendler-Geld
    inv_trader = function(Value, _, Msg)
        if Net.Side ~= "client" or not Msg.Key then return end
        C.Trader[Msg.Key] = Value
    end,

    -- Host -> Gast: Kiste wird von jemand anderem benutzt
    inv_busy = function(Data)
        if Net.Side ~= "client" then return end
        local Who = Net.Dec(tostring(Data or ""))
        pcall(A.ShowNote, "Wird gerade von " .. Who .. " benutzt")
    end,

    -- Host -> Gast: Hinweis (z. B. Admin-give)
    inv_note = function(Data)
        if Net.Side ~= "client" then return end
        pcall(A.ShowNote, tostring(Data or ""))
    end,

    -- Runde 7 Haendler. Gast -> Host (Anfrage): Haendler-Fenster geoeffnet. "Klasse|x|y|z|FName|wl"
    trd_open = function(Data, G, Msg)
        if Net.Side ~= "host" or not Msg.Rid then return end
        if not (I.TrdOn("trd_sess") and Net.Has("trd1", G) and G.Ready) then return Net.Reply(Msg, "no|aus") end
        Data = tostring(Data or "")
        if #Data > 200 or not Data:match(K.TRD_REF) then Net.SecWarn(G, G.Key, "trd_open") return Net.Reply(Msg, "no|format") end
        local ok, R = pcall(I.TrdOpen, G, Data, os.clock())
        if not ok then Core.Fail("trd_sess", R) R = "no|fehler" end
        Net.Reply(Msg, R)
    end,

    -- Gast -> Host: Haendler-Fenster geschlossen (Sitzung/Sperre frei). "Tid"
    trd_close = function(Data, G)
        if Net.Side ~= "host" or not G then return end
        -- "?" = Antwort war beim Gast noch nicht da (gilt der letzten Sitzung); sonst nur die genannte Sitzung
        local Tid, Ss = Net.Dec(tostring(Data or "?")), S.TrdS[G.Key]
        if Ss and Tid ~= "?" and Tid ~= "" and Ss.Tid ~= Tid then return end
        I.TrdDrop(G.Key, "geschlossen")
    end,

    -- Gast -> Host: Haendler-Fenster noch offen (alle TRD_HB s). "Tid"
    trd_hb = function(Data, G)
        if Net.Side ~= "host" or not G then return end
        local Ss = S.TrdS[G.Key]
        if Ss and Ss.Tid == Net.Dec(tostring(Data or "")) then Ss.Hb = os.clock() end
    end,

    -- Gast -> Host: Haendler-UI blieb leer -> SERVER_RequestData im Namen des Gasts (I.HostPrime). "Tid"
    trd_prime = function(Data, G)
        if Net.Side ~= "host" or not G or not I.TrdOn("trd_prime") then return end
        local Ss = S.TrdS[G.Key]
        if not Ss or Ss.Tid ~= Net.Dec(tostring(Data or "")) then return end
        local H, Now = I.HState(G.Key), os.clock()
        if Now - (H.TrdPrimeAt or -math.huge) < 5 then return end
        H.TrdPrimeAt = Now
        if I.PrimeLate(Ss.F, Now) then
            I.WarnOnce("dp_" .. tostring(Ss.F), "%s war schon repliziert - kein Prime (Doppelantwort wuerde Items loeschen)", I.Short(Ss.F))
            return
        end
        S.Prime[#S.Prime + 1] = { Key = G.Key, F = Ss.F, Fam = "t", Cls = "Haendler", At = Now + 0.15 }
    end,

    -- Host -> Gast: Geld des Haendlers der offenen Sitzung. "Tid|Geld"
    trd_m = function(Data)
        if Net.Side ~= "client" then return end
        local Tid, M = tostring(Data or ""):match("^([^|]*)|(.*)$")
        local T = C.Trd
        if Tid and T and T.Tid ~= nil and T.Tid == Net.Dec(Tid) then T.M = tonumber(M) or T.M end
    end,

    -- Host -> Gast: "Trader does not have enough money" (CheckVendorAmountOfMoney beim Host)
    trd_note = function()
        if Net.Side ~= "client" then return end
        local Now = os.clock()
        if Now - (C.TrdNoteAt or -math.huge) < 1 then return end
        C.TrdNoteAt = Now
        pcall(A.ShowNote, "Trader does not have enough money")
    end,

    -- Host -> Gast: Restock des Haendlers der offenen Sitzung. "Tid"
    trd_rs = function(Data)
        if Net.Side ~= "client" then return end
        local T = C.Trd
        if not (T and T.Open and T.Tid ~= nil and T.Tid == Net.Dec(tostring(Data or ""))) then return end
        Log("Haendler-Restock beim Host%s", I.On("trd_rsui") and " - Fenster wird neu geoeffnet" or "")
        if I.On("trd_rsui") then
            T.Reopen = { F = T.Open, At = os.clock() + 0.6 }
            I.CloseOwnInv(I.OwnPawn())
        end
    end,

    -- Host -> Gast: Haendler-Fenster lief beim Host (unterdrueckt) -> lokal oeffnen. "Klasse|x|y|z|FName|wl"
    trd_ui = function(Data)
        if Net.Side ~= "client" or not I.TrdOn("trd_dlg") then return end
        C.TrdUi = { Ref = tostring(Data or ""), T = os.clock() }
    end,

    -- Host -> alle (State): rt=1 = Host repliziert seine Laufzeit-Haendler (Net.Get liest ihn)
    trd_cfg = function() end,
}

-- ================================================================================================ Exporte

-- main.lua: Legacy-Wege (inv_reconcile, invsync) ruhen, solange v2b mit dem Host bzw. allen Gaesten aktiv ist
function M.Active()
    return I.On("inv_v2b") and Net.Has("inv2b")
end

-- main.lua G.HandleHost: true = kein zweiter LSD-Abgleich fuer diesen Gast (Respawn laeuft ueber SERVER_RequestData)
function M.SkipResync(Key)
    return I.On("inv_v2a") and Net.Has("inv2a", Key)
end

-- main.lua G.ClientTick bei neuer Figur (nicht der ersten der Verbindung): true = erledigt, kein guestid/LSD
-- inv_respawn_wait: ist das eigene BP_JigMultiplayer der neuen Figur noch nicht gueltig (Replikation laeuft), true
-- melden und in I.RespawnRetry (0,25 s) bis 10 s nachholen statt den Rueckfall (UI leeren + guestid) auszuloesen.
-- Klappt es nicht, setzt I.RespawnGiveUp A.G.SyncFor zurueck -> naechster Aufruf liefert false -> Rueckfall wie bisher.
function M.ClientRespawn(Pawn)
    if not (I.On("inv_v2a") and Net.Has("inv2a")) then return false end
    local Name = I.Name(Pawn)
    if Name and S.RespGaveUp == Name then S.RespGaveUp = nil return false end
    local Comp = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(Comp) then
        if not (Name and I.On("inv_respawn_wait")) then return false end
        S.Resp = { Name = Name, Until = os.clock() + 10 }
        Log("Respawn: eigenes BP_JigMultiplayer noch nicht gueltig - neuer Versuch bis 10 s")
        return true
    end
    S.Resp = nil
    return I.RespawnNow(Pawn, Comp)
end

function I.RespawnNow(Pawn, Comp)
    pcall(function() Comp:ClearJSIItems() end)
    pcall(function()
        local UI = Pawn.InGameUI
        if I.Alive(UI) then UI:ClearContainers() end
    end)
    -- inv_resp_native: BP_PlayerCharacter BeginPlay (5.3 @23a7, 5.6 @242e) schickt beim Gast schon SERVER_RequestData. Eine zweite
    -- Antwort in die volle UI liesse BuildDataToContainer scheitern -> SERVER_RequestRemoveItem. Eigene Anfrage nur,
    -- wenn die UI nach max(2,5 s, 3xRTT+2 s) noch leer ist (I.RespawnCheck).
    if I.On("inv_resp_native") then
        local Now = os.clock()
        C.BarText, C.DataAt = nil, Now
        S.RespChk = { Name = I.Name(Pawn), At = Now + math.max(2.5, 3 * (tonumber(I.Safe(function() return I.Rtt(Now) end)) or 0.15) + 2), Until = Now + 10 }
        Log("Respawn: UI geleert, warte auf die Antwort der nativen Anfrage (kein Vollsync)")
        return true
    end
    local ok, err = pcall(function() Comp:SERVER_RequestData(Comp) end)
    if not ok then Core.Fail("inv_v2a", err) return false end
    C.BarText, C.DataAt = nil, os.clock()
    Log("Respawn: Inventar per SERVER_RequestData geholt (kein Vollsync)")
    return true
end

-- inv_resp_native (Gast, 0,25 s): kam die native Antwort nicht (UI nach der Frist ohne Items), selbst anfordern.
-- Nach dem Tod ist das Inventar oft leer -> die Anfrage liefert dann nichts und stoert nicht. UI noch nicht
-- aufgebaut (nil): bis 10 s warten. Figur gewechselt -> verwerfen.
function I.RespawnCheck(Now)
    local R = S.RespChk
    if not R or Now < R.At then return end
    local Pawn = I.OwnPawn()
    if not Pawn or I.Name(Pawn) ~= R.Name then S.RespChk = nil return end
    local Comp = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not I.Alive(Comp) then S.RespChk = nil return end
    local Num = I.LootItems(Comp)
    if Num == nil and Now < R.Until then return end
    -- Runde 9 INV-17 (inv_resp_guard): eigene Anfrage nur, wenn der Host gerade hoerbar ist (letzter Empfang < 0,5 s).
    -- Haengt er (Autosave unter Wine), kaeme die Antwort der nativen BeginPlay-Anfrage spaeter als zweite Antwort in die
    -- dann volle UI (BuildDataToContainer -> Items beim Server geloescht) -> weiter warten (je Takt 0,25 s neu pruefen,
    -- damit ein Empfang im Sekundenrhythmus sicher getroffen wird), hoechstens bis R.Until
    if not (Num and Num > 0) and Now < R.Until and I.On("inv_resp_guard") then
        local Rx = Net.Host and tonumber(Net.Host.RxAt)
        if not Rx or Now - Rx > 0.5 then
            R.At = math.min(Now + 0.25, R.Until)
            if not R.Held then
                R.Held = true
                Log("Respawn: Host gerade still - eigene Inventar-Anfrage wartet (hoechstens %.0f s)", R.Until - Now)
            end
            return
        end
    end
    S.RespChk = nil
    if Num and Num > 0 then Log("Respawn: Inventar ueber die native Anfrage angekommen (%d Items)", Num) return end
    local ok, err = pcall(function() Comp:SERVER_RequestData(Comp) end)
    if not ok then Core.Fail("inv_v2a", err) return end
    C.DataAt = Now
    Log("Respawn: UI nach %.1f s leer - Inventar per SERVER_RequestData nachgefordert", Now - (R.Until - 10))
end

-- Nachholen von M.ClientRespawn (Gast, 0,25 s). Figur gewechselt -> verwerfen (neue Figur ruft ClientRespawn selbst)
function I.RespawnRetry(Now)
    if S.RespChk then I.RespawnCheck(Now) end
    local R = S.Resp
    if not R or Net.Side ~= "client" then return end
    local Pawn = I.OwnPawn()
    local Name = Pawn and I.Name(Pawn)
    if Name and Name ~= R.Name then S.Resp = nil return end
    local Comp = Pawn and I.Safe(function() return Pawn.BP_JigMultiplayer end)
    if I.Alive(Comp) then
        S.Resp = nil
        local ok, Done = pcall(I.RespawnNow, Pawn, Comp)
        if ok and Done then Log("Respawn nachgeholt nach %.1f s", 10 - (R.Until - Now)) return end
        I.RespawnGiveUp(R.Name, ok and "SERVER_RequestData fehlgeschlagen" or tostring(Done))
    elseif Now >= R.Until then
        S.Resp = nil
        I.RespawnGiveUp(R.Name, "BP_JigMultiplayer nach 10 s nicht gueltig")
    end
end

-- Aufgeben: main.lua G.ClientTick ruft ClientRespawn fuer diese Figur erneut auf (SyncFor geleert) -> false -> Rueckfall
function I.RespawnGiveUp(Name, Why)
    S.RespGaveUp = Name
    local GI = A.G
    if type(GI) == "table" and GI.SyncFor == Name then GI.SyncFor = nil end
    Log("Respawn per SERVER_RequestData aufgegeben (%s) - Rueckfall auf Abgleich", tostring(Why))
end

-- server.lua AdminInGame "give" (Empfangs-Hook: nur vormerken). true = uebernommen.
-- Runde 9 E7 (INV-13): NoCredit = true bei "give <Pfad> <n> rm" (main.lua hat die Cheat-Platzhalter schon entfernt)
function M.Give(Key, Path, Count, NoCredit)
    if Net.Side ~= "host" or not (I.On("inv_v2b") and I.On("inv_give")) then return false end
    local G = Net.Guests[Key]
    if not (G and G.Epoch and Net.Has("inv2b", G)) or #S.GiveQ >= 20 then return false end
    S.GiveQ[#S.GiveQ + 1] = { Key = Key, Path = tostring(Path), N = math.max(1, math.min(tonumber(Count) or 1, 9999)),
                              NoCredit = NoCredit == true or nil }
    return true
end

-- Gutschrift von aussen (ls_world: Quest-Belohnung, Ernte ...): Key = Gast-Key, Path = Daten-Asset
function M.Credit(Key, Path, N)
    if Net.Side ~= "host" or type(Path) ~= "string" then return end
    local Cr = I.HState(Key).Credit[Path]
    local Now = os.clock()
    if not Cr or Now - Cr.T > K.CREDIT_TTL then Cr = { N = 0 } I.HState(Key).Credit[Path] = Cr end
    Cr.N, Cr.T = math.min(Cr.N + (tonumber(N) or 1), 50), Now
end

-- Ereignis fuer Fachmodule: Gast hat lokal per ServerFindThenConsumeByItemID verbraucht (Fn(G, Path, N, Pawn))
function M.OnUse(Fn) if type(Fn) == "function" then S.UseFns[#S.UseFns + 1] = Fn end end

-- ls_car (Gast): Server hat Tanken/Reparieren/Kauf abgelehnt, das Spiel hat lokal schon verbraucht bzw. Geld
-- genommen -> Daten vom Server holen statt den lokalen Verbrauch nachzuspielen.
-- Nur vormerken (laeuft in Net-Antworten); SERVER_RequestData ruft I.ClientFast im eigenen Task (einmalig, auch mit
-- inv_sum=0; frueher nur I.ClientCompare -> mit inv_sum=0 wirkungslos). false = niemand gleicht ab.
-- inv_resync Standard AUS (vertauschte Ausruestung durch Neuabgleich + Hotbar-Wiederherstellung, Live-Test 22.10.)
function M.Resync(Why)
    if Net.Side ~= "client" or not (I.On("inv_v2b") and Net.Has("inv2b") and I.OnOff("inv_resync")) then return false end
    C.NeedData, C.ResyncWhy = true, tostring(Why or "?")
    Log("Neuabgleich vorgemerkt (%s)", C.ResyncWhy)
    return true
end

-- ls_car (Host): Inventar eines Gasts wurde von aussen geaendert (TakeMoney) -> Ledger/Digest sofort statt nach
-- inv_ledger_ms. G = Gast-Tabelle oder Key.
function M.Dirty(G)
    if Net.Side ~= "host" then return false end
    S.LedgerAt = 0
    return true
end

-- server.lua Save/Stop: alle Gaeste sofort speichern
function M.StoreAll()
    if Net.Side ~= "host" then return end
    -- Runde 9 INV-3: wie beim Verlassen (frisch gezaehltes Leer, SeenFull), sonst behaelt das Journal (.commit) nach
    -- Ausraeumen kurz vor dem Welt-Speichern die alten Items
    local Leave = I.On("inv_leave_seen")
    Net.ForEachGuest(function(G, Key)
        local Pawn = G.Epoch and I.HostPawn(G)
        if Pawn then I.StoreGuest(G, Key, Pawn, Leave) end
    end)
end

-- X35 main.lua Coop.StoreLeaving (Trennung, Figur lebt noch): letzte Sicherung mit den Regeln von I.StoreGuest,
-- inkl. leerem Inventar (G.Store speichert nie leer -> ausgeleert und getrennt = Duplikat). true = gespeichert
function M.StoreLeaving(Key, Pawn)
    if not I.Alive(Pawn) then return false end
    local G = Net.Guests[Key] or { Key = Key }
    if I.On("inv_pend_defer") then I.FlushDefer(G, Key, Pawn) end      -- Runde 9 INV-21: vor dem letzten Speichern
    local ok, R = pcall(I.StoreGuest, G, Key, Pawn, true)
    if not ok then
        Log("Letzte Sicherung von %s fehlgeschlagen: %s", tostring(G.PCName or Key), tostring(R))
        return false
    end
    return R == true
end

-- main.lua G.Sync direkt nach dem ersten LSD der Verbindung (Server-Modus): geladenen Stand merken
function M.JoinBaseline(Key, Pawn)
    if Net.Side ~= "host" or not I.On("inv_join_guard") then return end
    local Comp = I.Safe(function() return Pawn.BP_JigMultiplayer end)
    local Name = I.Name(Pawn)
    if not (I.Alive(Comp) and Name) then return end
    local Snap, _, Num = I.Scan(Comp)
    if Num == 0 then S.JB[Name] = nil return end
    S.JB[Name] = { Key = Key, Sum = I.JoinSum(Snap), At = os.clock() }
    Log("Beitritts-Schutz fuer %s: %d geladene Gegenstaende gemerkt", Name, Num)
end
-- main.lua G.Store (alle Speicherwege): false = nicht speichern
function M.StoreOk(Pawn)
    if Net.Side ~= "host" or not I.Alive(Pawn) then return true end
    return I.JoinCheck(I.Name(Pawn), Pawn, nil, os.clock())
end

-- X20 Host: os.clock() der letzten Abnahme eines passenden Items im Server-Inventar des Gasts (Ledger-Diff; der
-- SERVER_RequestConsumeItem-RPC laeuft ueber ProcessEvent und ist fuer den DLL-Beobachter unsichtbar).
-- Pattern = Lua-Muster (klein) gegen den Kurznamen bzw. Pfad des Daten-Assets. nil = keine bekannt.
-- Ist der Ledger aelter als 0,1 s, wird er vorher frisch gelesen (Wurf-RPC kann vor dem naechsten Ledger kommen).
-- Review 1 (inv_cons_open): AllowOpen = true zaehlt auch Einzel-Abnahmen bei offener Kiste/Haendler (H.ConsOpen, z. B.
-- Laptop-Scan mit offener Kiste). Zweiter Rueckgabewert true = Treffer kam aus H.ConsOpen (kein Laptop-Ersatz, ls_world).
-- ls_combat/ls_vit rufen mit 2 Argumenten -> unveraendert
function M.LastConsume(Key, Pattern, AllowOpen)
    if Net.Side ~= "host" or type(Pattern) ~= "string" or Pattern == "" then return nil end
    local G, Now = Net.Guests[Key], os.clock()
    local H = S.H[Key]
    if G and G.Epoch and G.Ready and (I.On("inv_v2a") or I.On("inv_v2b")) and not (H and H.LedgerAt and Now - H.LedgerAt <= 0.1) then
        local Pawn = I.HostPawn(G)
        if Pawn then
            local ok, R = pcall(I.Ledger, G, Key, Pawn, Now)
            if ok then H = R else Core.Fail("inv_v2a", R) end
        end
    end
    local Open = AllowOpen == true and I.On("inv_cons_open") and H and H.ConsOpen or nil
    -- Closeout (inv_cons_count): 3. Rueckgabe = Anzahl der Abnahmen passender Items seit Verbindungsbeginn (H.ConsN, mit
    -- AllowOpen + inv_cons_open auch H.ConsOpenN). Mit Schalter an immer eine Zahl (0 = keine), nil = Zaehler aus
    local CntOn = I.On("inv_cons_count")
    if not (H and (H.Cons or Open)) then return nil, nil, CntOn and 0 or nil end
    local Pat, Best, FromOpen = Pattern:lower(), nil, nil
    for Ti, Tab in ipairs({ H.Cons or {}, Open or {} }) do
        for P, T in pairs(Tab) do
            local Lp = tostring(P):lower()
            local okF, Hit = pcall(string.find, Lp, Pat)
            if not okF then Hit = Lp:find(Pat, 1, true) end
            if Hit and (not Best or T > Best) then Best, FromOpen = T, Ti == 2 or nil end
        end
    end
    local Count = CntOn and I.ConsCount(H, Pat, AllowOpen == true and I.On("inv_cons_open")) or nil
    return Best, FromOpen, Count
end

-- Closeout (inv_cons_count): Summe der Abnahme-Zaehler aller zum Muster passenden Pfade (gleiche Suche wie
-- M.LastConsume: Lua-Muster, bei ungueltigem Muster Klartext)
function I.ConsCount(H, Pat, WithOpen)
    local N = 0
    for _, Tab in ipairs({ H.ConsN or {}, WithOpen and H.ConsOpenN or {} }) do
        for P, C in pairs(Tab) do
            local Lp = tostring(P):lower()
            local okF, Hit = pcall(string.find, Lp, Pat)
            if not okF then Hit = Lp:find(Pat, 1, true) end
            if Hit then N = N + (tonumber(C) or 0) end
        end
    end
    return N
end

-- Inventar einer Mitspieler-Figur als Save_Player-Kopie (aus main.lua 2406 uebernommen, WP16 loescht das Original)
-- AllowEmpty (nur I.StoreEmpty): auch ohne Gegenstand (Container muessen da sein)
function M.BuildGuestSave(Pawn, AllowEmpty)
    local Inventory = Pawn.BP_JigMultiplayer
    if not I.Alive(Inventory) then return nil end
    if #Inventory.MainJigContainers == 0 then return nil end
    local Items = 0
    Inventory.MainJigContainers:ForEach(function(_, Container)
        Items = Items + Container:get()[F.ITEMS]:GetArrayNum()
    end)
    if Items == 0 and AllowEmpty ~= true then return nil end
    local SaveCls, GInst = StaticFindObject(F.SAVE_PLAYER), A.UEHelpers.GetGameInstance()
    if not (I.Alive(SaveCls) and I.Alive(GInst)) then return nil end
    local Temp = StaticConstructObject(SaveCls, GInst)
    if not I.Alive(Temp) then return nil end
    Temp.MainJigContainers = Inventory.MainJigContainers
    Temp.MainUIDs = Inventory.MainContainersIDs
    Temp.Weights = Inventory.InventoryWeight
    -- PickupRef zeigt in die Welt des Hosts: nur in der Kopie leeren (sonst Absturz beim Laden)
    Temp.MainJigContainers:ForEach(function(_, Container)
        Container:get()[F.ITEMS]:ForEach(function(_, Item) Item:get()[F.PICKUP_REF] = nil end)
    end)
    return Temp
end

-- Runde 9 INV-6 (inv_battery_patch): Taschenlampe, Waffenlicht/-laser, Entfernungsmesser des Gasts. CheckBatteryLevel sucht
-- die Batterie per GetItemByUID in MainJigContainers (beim Gast leer) -> @018d Battery?=false -> FlashlightToggle @01e6
-- bricht ab. Wie der Haltbarkeits-Patch (main.lua): "nicht gefunden" = Batterie da (@0197 False -> True, @01aa DoubleConst
-- 0 -> 100; die DLL prueft die erwarteten Bytes). Echte Entladung bleibt beim Host (Svr_Flashlight -> UseBattery auf der
-- Server-Kopie). Ausserhalb einer Gast-Verbindung (Host, Einzelspiel) die 0-Zeile, falls vorher an.
function I.BattPatch()
    if not Core.HasPatchRegistry() or I.Loading() then return end
    local Want = (Net.Side == "client" and I.On("inv_battery_patch") and Net.Has("inv2b") and Net.Host ~= nil
        and Net.Host.Ready == true) and true or false
    if not Want and not S.BattOn then return end
    -- Runde 9 INV-6b: zwei Funktionen (CheckBatteryLevel = 1, UseBattery = 2; Patch-Eintrag Fn)
    local Addr, Sig = {}, ""
    for Idx, Path in ipairs({ K.BATT_FN, K.BATT_USE }) do
        local Fn = I.Safe(function() return StaticFindObject(Path) end)
        Addr[Idx] = I.Alive(Fn) and I.Safe(function() return Fn:GetAddress() end) or nil
        Sig = Sig .. string.format("%x:", Addr[Idx] or 0)
    end
    if not Addr[1] then
        if not Want then S.BattOn, S.BattSig = false, nil end   -- Klasse entladen: die DLL hat den Patch verworfen
        return
    end
    Sig = Sig .. tostring(Want)
    if Sig == S.BattSig then return end
    local Names = {}
    for _, P in ipairs(K.BATT) do
        local Ad = Addr[P.Fn]
        if Ad then
            if not Core.SetPatch(P.N, string.format("%s bytes %x %d %s %s %d", P.N, Ad, P.Off, P.Old, P.New, Want and 1 or 0)) then
                return
            end
            Names[#Names + 1] = P.N
        end
    end
    S.BattSig, S.BattOn, S.BattNames = Sig, Want, Names
    Log("Batterie-Patch (CheckBatteryLevel/UseBattery: %s) %s angefordert (Ergebnis in netcore.log)", table.concat(Names, ","),
        Want and "an" or "aus")
end

-- ================================================================================================ Init

-- Runde 9: Faehigkeiten der neuen Wege (beide Seiten; Net.Cap ohne Aenderung ist ein No-op)
function I.Caps()
    Net.Cap("invcnt", I.On("inv_v2b") and I.On("inv_craft_cnt"))
    Net.Cap("invps", I.On("inv_v2b") and I.On("inv_prime_strict"))     -- inv_carc mit Alter (CORE-28)
    Net.Cap("invrep", I.On("inv_v2b") and I.On("inv_repair"))          -- K2 inv_rep (INV-4)
    Net.Cap("invlt", I.On("inv_v2b") and I.On("inv_battery_drain"))    -- K3/K4 inv_light/inv_lightoff (INV-6b)
    -- Review 2: K35 Host versteht "give <Pfad> <n> rm" (Gast main.lua Coop.Cheat.OnClickPre haengt " rm" nur mit dieser Cap
    -- an). Bewusst ohne inv_give: Host mit inv_give=0 faellt in server.lua auf QueueDrop ohne Gutschrift zurueck
    Net.Cap("invgrm", I.On("inv_v2b"))
end

function M.Init(Api)
    A = Api
    I.ClientReset()
    Net.Cap("inv2a", I.On("inv_v2a"))
    Net.Cap("inv2b", I.On("inv_v2b"))
    Net.Cap("trd1", I.TrdOn("trd_v1"))
    Net.Cap("invx", I.InvX())
    Net.Cap("invu", I.InvU())
    Net.Cap("invpf", I.On("inv_pend_ack"))
    I.Caps()
    if not A.Coop.BuildGuestSave then A.Coop.BuildGuestSave = M.BuildGuestSave end
    -- ls_combat H.OnProj: A.Coop.Inv.LastConsume(GuestKey, Muster)
    A.Coop.Inv = type(A.Coop.Inv) == "table" and A.Coop.Inv or {}
    A.Coop.Inv.LastConsume = M.LastConsume
    -- Runde 9: E1 CraftNote (ls_world W.HCraftReq, Host, nur Tabelle), E6 MarkAddr (ls_ai lootrep)
    A.Coop.Inv.CraftNote = M.CraftNote
    A.Coop.Inv.MarkAddr = M.MarkAddr
    A.Coop.Inv.RepairSlot = M.RepairSlot                      -- E5 (ls_combat, Gast)
    A.Coop.Inv.FishNote = M.FishNote                          -- E3 (ls_world, Host)
    -- ls_player (Shutdown/finales Speichern): Sofort-Speichern mit den Schutzregeln von I.StoreGuest. true = gespeichert
    A.Coop.InvStoreNow = function(Key, PC, Pawn, GuestId)
        if Net.Side ~= "host" or not I.Alive(Pawn) then return false end
        local G = Net.Guests[Key] or { Key = Key, GuestId = GuestId }
        if I.On("inv_pend_defer") then I.FlushDefer(G, Key, Pawn) end  -- Runde 9 INV-21
        return I.StoreGuest(G, Key, Pawn)
    end
    I.WrapLoad()                                                    -- Runde 9 INV-20 (E31, inv_badsave)

    Core.Every("inv_host", 0.1, function(Now) I.HostFast(Now) end)
    Core.Every("inv_host1", 1, function(Now) I.HostSlow(Now) end)
    Core.Every("inv_cli", 0.25, function(Now) I.ClientFast(Now) end)
    Core.Every("inv_cli1", 1, function(Now) I.ClientSlow(Now) end)
    Core.Every("inv_resp", 0.25, function(Now) I.Try("inv_respawn_wait", I.RespawnRetry, Now) end)
    Core.Every("inv_trd", 0.25, function(Now) I.TrdTick(Now) end)
    Core.Every("inv_batt", 2, function() I.Try("inv_battery_patch", I.BattPatch) end)   -- Runde 9 INV-6 (beide Seiten)
    -- Faehigkeiten nachfuehren: FLAG_DOWN (Core.Fail) zieht inv2a/inv2b zurueck, der Peer faellt auf Legacy
    -- (Net.Cap ist ohne Aenderung ein No-op und meldet Aenderungen per h4/h4a)
    Core.Every("inv_caps", 1, function()
        Net.Cap("inv2a", I.On("inv_v2a"))
        Net.Cap("inv2b", I.On("inv_v2b"))
        Net.Cap("trd1", I.TrdOn("trd_v1"))
        Net.Cap("invx", I.InvX())
        Net.Cap("invu", I.InvU())
        Net.Cap("invpf", I.On("inv_pend_ack"))
        I.Caps()
    end)

    Net.OnEvent("gone", function(Peer)
        if Net.Side ~= "host" or not Peer or not Peer.Key then return end
        local Key = Peer.Key
        for Name, O in pairs(S.Open) do if O.Key == Key then S.Open[Name] = nil end end
        I.TrdDrop(Key, "getrennt")                            -- Haendler-Sperre loest sich beim Trennen
        -- letzte Sicherung, falls die Figur noch existiert (Runde 9 INV-21: vorgemerkte Anlagen vorher ausfuehren)
        if Peer.PawnName and (I.On("inv_store") or I.On("inv_pend_defer")) then
            for _, P in ipairs(I.Safe(function() return A.PlayerPawns() end, {}) or {}) do
                if I.Alive(P) and I.Name(P) == Peer.PawnName then
                    if I.On("inv_pend_defer") then I.FlushDefer(Peer, Key, P) end
                    if I.On("inv_store") then I.StoreGuest(Peer, Key, P, true) end
                    break
                end
            end
        end
        for N, E in pairs(S.JB) do if E.Key == Key then S.JB[N] = nil end end
        I.GCompDrop(S.H[Key], Key)                            -- Closeout R3 (inv_cons_nomove_any)
        S.H[Key] = nil
        S.Light[Key] = nil                                    -- Runde 9 CORE-30/INV-6b: Je-Gast-Tabellen
    end)
    Net.OnEvent("linked", function(Peer)
        if Net.Side == "client" then
            local Bar = C.BarText
            I.ClientReset()
            S.Resp, S.RespGaveUp, S.RespChk = nil, nil, nil    -- neue Verbindung: kein Respawn-Nachholen
            C.BarText = Bar
        elseif Peer and Peer.Key then
            I.GCompDrop(S.H[Peer.Key], Peer.Key)              -- Closeout R3: I.Ledger traegt neu ein (vor jedem Vergleich)
            S.H[Peer.Key] = nil
        end
    end)

    A.TestCommands.inv_state = function()
        local N = 0
        for _ in pairs(S.H) do N = N + 1 end
        A.TestLog("inv: Seite %s, Gaeste %d, Kisten %d, repliziert %d, Platzhalter %d, offen %d, Erwartet-ok %d",
            tostring(Net.Side), N, S.Cont and #S.Cont or 0, (function() local R = 0 for _ in pairs(S.Rep) do R = R + 1 end return R end)(),
            (function() local R = 0 for _ in pairs(C.PendSeen or {}) do R = R + 1 end return R end)(), C.InFlight or 0, C.ExpectOk or 0)
    end
    A.TestCommands.trd_state = function()
        local N, Parts = 0, {}
        for Key, Ss in pairs(S.TrdS) do
            N = N + 1
            Parts[#Parts + 1] = string.format("%s->%s", tostring(Ss.Who or Key), tostring(Ss.Tid))
        end
        local R = 0
        for _ in pairs(S.TrdRep) do R = R + 1 end
        local T = C.Trd or {}
        A.TestLog("trd: Seite %s, Sitzungen %d [%s], repliziert %d, Haendler %d, Beobachtung %s, Gast offen %s Tid %s Geld %s",
            tostring(Net.Side), N, table.concat(Parts, ", "), R, S.Traders and #S.Traders or 0, tostring(S.TrdWSig),
            I.Short(T.Open), tostring(T.Tid), tostring(T.M))
    end
    A.TestCommands.inv_refetch = function()
        local Pawn = I.OwnPawn()
        local Comp = Pawn and Pawn.BP_JigMultiplayer
        if I.Alive(Comp) then I.RequestData(Comp, os.clock(), "Testbefehl") end
    end
    Log("Inventar v2 geladen (v2a %s, v2b %s)", tostring(I.On("inv_v2a")), tostring(I.On("inv_v2b")))
end

return M
