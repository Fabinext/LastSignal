-- Last Signal, Runde 5: Testbefehle fuer test_cmd.txt (nur mit dev=1 oder test=1).
--   bpdump <Liste> <Ausgabeordner> [Startindex|resume]  alle Blueprints der Liste laden und von der DLL
--          disassemblieren lassen (einmalig, NUR im Hauptmenue). Absturz -> mit "resume" weiter, das
--          Asset beim Absturz landet in bpdump_skip.txt.
--   kdump <KlassenPfad> [Ausgabeordner]                 eine Klasse dumpen (Standard: <Mod>\kdump)
--   bpdump_status                                       Fortschritt
-- Protokoll: netcore_kdump_req.txt "KDUMP <seq> <Ordner>" (Ordner absolut, ohne Leerzeichen) + Zeilen "C <Adresse hex> <Pfad>" oder "ALL <Praefix>",
-- die DLL antwortet in netcore_kdump_done.txt mit "DONE <seq> classes=.. funcs=.. bytes=.. errors=..".
local Test = {}
local Core = require("ls_core")
local Native = require("ls_native")
local A           -- API aus main.lua (siehe Init)

local BLOCK, TICK = 10, 0.1            -- Assets je Schritt, Schritt alle 100 ms
local WAIT_BLOCK, WAIT_ALL = 30, 120   -- Sekunden auf die DLL warten (Block / ALL am Ende)
local LOG_EVERY = 100
local GC_VAR, GC_DUMP, GC_NORMAL = "gc.TimeBetweenPurgingPendingKillObjects", "100000", "61.1"

local function Log(fmt, ...)
    local Out = A.TestLog or A.Log
    Out(fmt, ...)
end

local function File(Name) return Native.Dir() .. Name end

-- Pfad absolut machen (relativ = zum Mod-Ordner), Windows-Trenner, ohne Trenner am Ende
local function AbsDir(Path)
    Path = Path:gsub("/", "\\")
    if not (Path:match("^%a:\\") or Path:match("^\\\\")) then Path = Native.Dir():gsub("/", "\\") .. Path end
    return (Path:gsub("\\+$", ""))
end

local function AbsFile(Path)
    Path = Path:gsub("/", "\\")
    if Path:match("^%a:\\") or Path:match("^\\\\") then return Path end
    return Native.Dir():gsub("/", "\\") .. Path
end

-- Vertrag: Zeile 1 "KDUMP <seq> <Ordner>" wird an Leerzeichen getrennt -> Ordner ohne Leerzeichen
local function DirOk(Dir, What)
    if not Dir:find("%s") then return true end
    Log("%s: Ausgabeordner %s enthaelt Leerzeichen, bitte Ausgabeordner ohne Leerzeichen angeben", What, Dir)
    return false
end

-- Die DLL legt keine Ordner an: vorher pruefen, ob man dort schreiben kann
local function Writable(Dir)
    local Probe = Dir .. "\\.ls_probe"
    local Handle = io.open(Probe, "w")
    if not Handle then return false end
    Handle:close()
    os.remove(Probe)
    return true
end

local function Console(Command)
    local ok, err = pcall(A.RunCommand, Command)
    if not ok then Log("Konsole '%s' fehlgeschlagen: %s", Command, tostring(err)) end
end

local function IsClass(Object)
    if not (Object and A.Safe(function() return Object:IsValid() end, false)) then return false end
    -- Ersatz nur, wenn IsClass() selbst fehlt (sonst waere z.B. ein SoundClass-Asset eine "Klasse")
    local okM, Is = pcall(function() return Object:IsClass() end)
    if okM then return Is == true end
    local N = A.Safe(function() return Object:GetClass():GetFName():ToString() end, "") or ""
    return N == "Class" or N:find("GeneratedClass$") ~= nil
end

local function FindOrLoad(Path)
    local Object = A.Safe(function() return StaticFindObject(Path) end, nil)
    if IsClass(Object) then return Object end
    Object = A.Safe(function() return LoadAsset(Path) end, nil)
    if IsClass(Object) then return Object end
    return nil
end

-- "/Game/X/BP_Foo" oder "/Game/X/BP_Foo.BP_Foo" -> Klasse "/Game/X/BP_Foo.BP_Foo_C"
local function LoadClass(Path)
    if not Path:find(".", 1, true) then
        local Short = Path:match("([^/]+)$")
        if not Short then return nil, Path end   -- z.B. Zeile endet auf "/"
        Path = Path .. "." .. Short
    end
    local Class = FindOrLoad(Path)
    if not Class and not Path:match("_C$") then
        Path = Path .. "_C"
        Class = FindOrLoad(Path)
    end
    return Class, Path
end

local function ClassLine(Class, Path)
    return string.format("C %X %s", Class:GetAddress(), Path)
end

local function Request(Seq, Dir, Lines)
    return Native.Request("kdump", string.format("KDUMP %d %s\n%s\n", Seq, Dir, table.concat(Lines, "\n")))
end

local function ReadLines(Path)
    local Lines = {}
    local Handle = io.open(Path, "r")
    if not Handle then return nil end
    for Line in Handle:lines() do
        Line = Line:match("^%s*(.-)%s*$")
        if Line ~= "" and not Line:match("^#") then Lines[#Lines + 1] = Line end
    end
    Handle:close()
    return Lines
end

local function ReadKeys(Path)
    local Keys = {}
    for Key, Value in (Core.ReadAll(Path) or ""):gmatch("([%w_]+)=([^\r\n]*)") do Keys[Key] = Value end
    return Keys
end

-- ===== bpdump =====

local function WriteProgress(D)
    Core.WriteAtomic(File("bpdump_progress.txt"), string.format(
        "next=%d\ntotal=%d\nloaded=%d\nfailed=%d\nskipped=%d\nclasses=%d\nfuncs=%d\nerrors=%d\nlist=%s\nout=%s\n",
        D.Index, #D.List, D.Loaded, D.Failed, D.Skipped, D.Classes, D.Funcs, D.Errors, D.ListPath, D.Dir))
end

local function Finish(D, All)
    Console(GC_VAR .. " " .. GC_NORMAL)
    Core.Remove(File("bpdump_current.txt"))
    WriteProgress(D)
    if #D.FailedPaths > 0 then Core.WriteAtomic(File("bpdump_failed.txt"), table.concat(D.FailedPaths, "\n") .. "\n") end
    local Summary = string.format("bpdump fertig: %d geladen, %d fehlgeschlagen, %d Klassen gedumpt", D.Loaded,
        D.Failed + D.Skipped, D.Classes)
    local Extra = string.format("(%d Funktionen, %d Byte Script, %d Fehler; ALL /Game/: %s Klassen; %d uebersprungen; %.0f s)",
        D.Funcs, D.Bytes, D.Errors, All and tostring(All.classes) or "keine Antwort", D.Skipped, os.clock() - D.Started)
    Log("%s %s", Summary, Extra)
    Core.WriteAtomic(File("bpdump_finished.txt"), Summary .. "\n" .. Extra .. "\n")
    Test.Dump = nil
end

local function LoadBlock(D)
    local Last = math.min(D.Index + BLOCK - 1, #D.List)
    D.Lines = {}
    for I = D.Index, Last do
        local Path = D.List[I]
        if D.Skip[Path] then
            D.Skipped = D.Skipped + 1
        else
            -- Absturz-Merker: steht beim naechsten Start noch da, kommt der Pfad auf die Skip-Liste
            local Mark = io.open(File("bpdump_current.txt"), "w")
            if Mark then Mark:write(I, " ", Path, "\n") Mark:close() end
            -- Fehler je Asset abfangen: D.Index muss immer weiterlaufen
            local okL, Line = pcall(function()
                local Class, Full = LoadClass(Path)
                return Class and ClassLine(Class, Full) or nil
            end)
            if not okL then Log("bpdump: %s Fehler beim Laden: %s", Path, tostring(Line)) Line = nil end
            if Line then
                D.Loaded = D.Loaded + 1
                D.Lines[#D.Lines + 1] = Line
            else
                D.Failed = D.Failed + 1
                D.FailedPaths[#D.FailedPaths + 1] = Path
            end
        end
        if I % LOG_EVERY == 0 then
            Log("bpdump: %d/%d (geladen %d, fehlgeschlagen %d, Klassen gedumpt %d)", I, #D.List, D.Loaded,
                D.Failed, D.Classes)
        end
    end
    Core.Remove(File("bpdump_current.txt"))
    D.Index = Last + 1
end

local function BlockDone(D)
    if D.Final then return true end
    WriteProgress(D)
    D.Phase = "load"
end

local function DumpBody(D, Now)
    if D.Phase == "load" then
        if D.Index > #D.List then
            D.Final, D.Lines, D.Seq, D.Phase, D.Since = true, { "ALL /Game/" }, Native.NextSeq(), "send", Now
            return
        end
        LoadBlock(D)
        if #D.Lines == 0 then WriteProgress(D) return end
        D.Seq, D.Phase, D.Since = Native.NextSeq(), "send", Now
    elseif D.Phase == "send" then
        local ok, Why = Request(D.Seq, D.Dir, D.Lines)
        if ok then
            D.Phase, D.Since = "wait", Now
        elseif Why ~= "pending" or Now - D.Since > WAIT_BLOCK then
            -- Alte Anfrage wird nicht abgeholt (DLL aus?) bzw. Schreiben geht nicht: Block auslassen
            Log("bpdump: Anfrage %d nicht gestellt (%s), Block wird ausgelassen", D.Seq, tostring(Why))
            Native.Cancel("kdump")
            if BlockDone(D) then Finish(D, nil) return true end
        end
    elseif D.Phase == "wait" then
        local Done = Native.ReadDone("kdump", D.Seq)
        if Done then
            if D.Final then Finish(D, Done) return true end
            D.Classes = D.Classes + (tonumber(Done.classes) or 0)
            D.Funcs = D.Funcs + (tonumber(Done.funcs) or 0)
            D.Bytes = D.Bytes + (tonumber(Done.bytes) or 0)
            D.Errors = D.Errors + (tonumber(Done.errors) or 0)
            BlockDone(D)
        elseif Now - D.Since > (D.Final and WAIT_ALL or WAIT_BLOCK) then
            Log("bpdump: keine Antwort der DLL auf Anfrage %d nach %d s, weiter", D.Seq, D.Final and WAIT_ALL or WAIT_BLOCK)
            Native.Cancel("kdump")
            if BlockDone(D) then Finish(D, nil) return true end
        end
    end
end

-- Fehler selbst zaehlen (RunTasks raeumt bei Down nicht auf): dann Finish (GC zurueck, Test.Dump = nil)
local function DumpStep(Now)
    local D = Test.Dump
    if not D then return true end
    local ok, Result = pcall(DumpBody, D, Now)
    if ok then return Result end
    if Core.Fail("bpdump_step", Result) then
        Log("bpdump: abgebrochen nach wiederholten Fehlern (%s)", tostring(Result))
        pcall(Native.Cancel, "kdump")
        if not pcall(Finish, D, nil) then
            Test.Dump = nil
            Console(GC_VAR .. " " .. GC_NORMAL)
        end
        return true
    end
end

local function StartDump(Arg)
    local ListArg, OutArg, StartArg = (Arg or ""):match("^(%S+)%s+(%S+)%s*(%S*)$")
    if not ListArg then Log("bpdump <Liste> <Ausgabeordner> [Startindex|resume]") return end
    if Test.Dump or Test.Single then Log("bpdump: es laeuft schon ein Dump") return end
    local ListPath, Dir = AbsFile(ListArg), AbsDir(OutArg)
    local List = ReadLines(ListPath)
    if not List or #List == 0 then Log("bpdump: Liste %s fehlt oder ist leer", ListPath) return end
    if not DirOk(Dir, "bpdump") then return end
    if not Writable(Dir) then Log("bpdump: Ausgabeordner %s nicht beschreibbar (anlegen?)", Dir) return end
    local Start = tonumber(StartArg) or 1
    if StartArg == "resume" then Start = tonumber(ReadKeys(File("bpdump_progress.txt")).next) or 1 end
    -- Skip-Liste; ein uebrig gebliebener Absturz-Merker kommt dazu
    local Skip = {}
    for _, Path in ipairs(ReadLines(File("bpdump_skip.txt")) or {}) do Skip[Path] = true end
    local Crashed = (Core.ReadAll(File("bpdump_current.txt")) or ""):match("^%d+%s+(%S+)")
    if Crashed and not Skip[Crashed] then
        Skip[Crashed] = true
        local Handle = io.open(File("bpdump_skip.txt"), "a")
        if Handle then Handle:write(Crashed, "\n") Handle:close() end
        Log("bpdump: %s war beim letzten Lauf in Arbeit (Absturz?), wird uebersprungen", Crashed)
    end
    Core.Remove(File("bpdump_current.txt"))
    Core.Remove(File("bpdump_finished.txt"))
    Console(GC_VAR .. " " .. GC_DUMP)
    Test.Dump = { List = List, ListPath = ListPath, Dir = Dir, Index = math.max(1, math.floor(Start)), Skip = Skip,
        Phase = "load", Loaded = 0, Failed = 0, Skipped = 0, Classes = 0, Funcs = 0, Bytes = 0, Errors = 0,
        FailedPaths = {}, Started = os.clock() }
    Core.Down.bpdump, Core.Fails.bpdump = nil, nil
    Core.Down.bpdump_step, Core.Fails.bpdump_step = nil, nil
    Core.Every("bpdump", TICK, DumpStep)
    Log("bpdump: %d Eintraege ab %d -> %s (nur im Hauptmenue verwenden)", #List, Test.Dump.Index, Dir)
end

-- ===== kdump (eine Klasse) =====

local function SingleDump(Arg)
    local Path, Out = (Arg or ""):match("^(%S+)%s*(%S*)$")
    if not Path then Log("kdump <KlassenPfad> [Ausgabeordner]") return end
    if Test.Dump or Test.Single then Log("kdump: es laeuft schon ein Dump") return end
    local Class, Full = LoadClass(Path)
    if not Class then Log("kdump: %s nicht gefunden oder keine Klasse", Path) return end
    local Dir = AbsDir(Out ~= "" and Out or "kdump")
    if not DirOk(Dir, "kdump") then return end
    if not Writable(Dir) then Log("kdump: Ausgabeordner %s nicht beschreibbar (anlegen?)", Dir) return end
    local Seq = Native.NextSeq()
    local ok, Why = Request(Seq, Dir, { ClassLine(Class, Full) })
    if not ok then Log("kdump: Anfrage nicht geschrieben (%s)", tostring(Why)) return end
    Test.Single = { Seq = Seq, Since = os.clock(), Path = Full, Dir = Dir }
    Core.Down.kdump_wait, Core.Fails.kdump_wait = nil, nil
    Core.Down.kdump_step, Core.Fails.kdump_step = nil, nil
    local function WaitBody(S, Now)
        local Done = Native.ReadDone("kdump", S.Seq)
        if Done then
            Log("kdump %s fertig: %s Funktionen, %s Byte, %s Fehler -> %s", S.Path, tostring(Done.funcs),
                tostring(Done.bytes), tostring(Done.errors), S.Dir)
        elseif Now - S.Since > WAIT_BLOCK then
            Log("kdump %s: keine Antwort der DLL nach %d s", S.Path, WAIT_BLOCK)
            Native.Cancel("kdump")
        else
            return
        end
        Test.Single = nil
        return true
    end
    -- Fehler selbst zaehlen: bei Down Test.Single freigeben, sonst bleibt kdump/bpdump blockiert
    Core.Every("kdump_wait", 0.5, function(Now)
        local S = Test.Single
        if not S then return true end
        local ok, Result = pcall(WaitBody, S, Now)
        if ok then return Result end
        if Core.Fail("kdump_step", Result) then
            Log("kdump %s: abgebrochen nach wiederholten Fehlern (%s)", S.Path, tostring(Result))
            pcall(Native.Cancel, "kdump")
            Test.Single = nil
            return true
        end
    end)
    Log("kdump: %s angefordert (seq %d)", Full, Seq)
end

local function Status()
    local D = Test.Dump
    if D then
        Log("bpdump laeuft: %d/%d, Phase %s, geladen %d, fehlgeschlagen %d, uebersprungen %d, Klassen gedumpt %d",
            D.Index - 1, #D.List, D.Phase, D.Loaded, D.Failed, D.Skipped, D.Classes)
        return
    end
    local P = ReadKeys(File("bpdump_progress.txt"))
    if not P.next then Log("bpdump: kein Fortschritt gespeichert") return end
    Log("bpdump steht: naechster Index %s von %s, geladen %s, fehlgeschlagen %s, Klassen %s%s", P.next,
        tostring(P.total), tostring(P.loaded), tostring(P.failed), tostring(P.classes),
        Core.ReadAll(File("bpdump_finished.txt")) and " (fertig)" or "")
end

function Test.Init(Api)
    A = Api
    A.TestCommands.bpdump = StartDump
    A.TestCommands.kdump = SingleDump
    A.TestCommands.bpdump_status = Status
    -- Test: Passwort fuer den naechsten Beitritt setzen (wird nach dem Verbinden wie beim Spieler geschickt)
    A.TestCommands.pw = function(Arg)
        A.Coop.JoinPassword = (Arg and Arg ~= "") and Arg or nil
        A.TestLog("Passwort fuer den Beitritt %s", A.Coop.JoinPassword and "gesetzt" or "geloescht")
    end
    -- Test: Keyed-State einer Art ansehen (Gast: empfangen; Host: Sendetabelle)
    A.TestCommands.netstate = function(Arg)
        local Net = A.Coop.Net
        if not Net then A.TestLog("netstate: kein Net") return end
        local Kind = Arg or "vit2"
        local Out = {}
        for PK, M in pairs(Net.Mirror or {}) do
            for K, V in pairs((M or {})[Kind] or {}) do Out[#Out + 1] = "in " .. tostring(PK) .. ":" .. tostring(K) .. "=" .. tostring(V):sub(1, 80) end
        end
        local T = (Net.StateTab or {})[Kind]
        if T then
            for K, V in pairs(T.All or {}) do Out[#Out + 1] = "all " .. tostring(K) .. "=" .. tostring(V):sub(1, 80) end
            for PK, Tab in pairs(T.Per or {}) do
                for K, V in pairs(Tab) do Out[#Out + 1] = "per " .. tostring(PK):sub(-30) .. ":" .. tostring(K) .. "=" .. tostring(V):sub(1, 80) end
            end
        end
        local Fails = {}
        for Name, F in pairs(Core.Fails or {}) do Fails[#Fails + 1] = Name .. "=" .. tostring(type(F) == "table" and (F.N or #F) or F) end
        A.TestLog("netstate %s: %s | Fails: %s", Kind, #Out > 0 and table.concat(Out, " ; ") or "-",
            #Fails > 0 and table.concat(Fails, ",") or "-")
    end
    -- Test: Zustand der neuen Module (welche geladen, Netz-Statistik, abgeschaltete Schalter)
    A.TestCommands.r5 = function()
        local Names = {}
        for Name in pairs(A.Coop.Modules or {}) do Names[#Names + 1] = Name end
        table.sort(Names)
        local Down = {}
        for Name in pairs(Core.Down or {}) do Down[#Down + 1] = Name end
        local Net = A.Coop.Net
        local G = 0
        if Net and Net.ForEachGuest then pcall(Net.ForEachGuest, function() G = G + 1 end) end
        A.TestLog("R5: Module %s | Gaeste %d | Down: %s", table.concat(Names, ","), G,
            #Down > 0 and table.concat(Down, ",") or "-")
    end
    Test.RegisterPlay()
end

-- ===== Spiel-Tests (Host): Items geben, an Felsen teleportieren, Tiere spawnen/toeten, Inventar listen =====
local function FirstGuest()
    local Net = A.Coop.Net
    local Key, G
    if Net and Net.ForEachGuest then pcall(Net.ForEachGuest, function(GG, K) if not Key then Key, G = K, GG end end) end
    local PC = G and Net.PC(G)
    local Pawn = PC and A.Safe(function() return PC:K2_GetPawn() end)
    if not (A.IsAlive(Pawn) and A.IsAlive(PC)) then return nil end
    return Key, PC, Pawn
end

local function ItemList(Pawn)
    local Out = {}
    local J = A.Safe(function() return Pawn.BP_JigMultiplayer end)
    if not A.IsAlive(J) then return "kein Inventar" end
    pcall(function()
        J.MainJigContainers:ForEach(function(_, CE)
            CE:get().ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B:ForEach(function(_, IE)
                local It = IE:get().ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7
                local N = A.Safe(function() return It.ItemID_28_01CA27D84AF7D1014D9E2E83894C1848:GetFName():ToString() end, "?")
                Out[#Out + 1] = N .. "x" .. tostring(A.Safe(function() return It.Count_8_DD79AF2A46126A338C8DCCB4616D91CD end, "?"))
            end)
        end)
    end)
    return table.concat(Out, ",")
end

function Test.RegisterPlay()
    local T = A.TestCommands
    -- give <DA-Pfad> [n]: Server legt das Item ueber ls_inv.Give beim ersten Gast an
    T.give = function(Arg)
        local Path, N = tostring(Arg or ""):match("^(%S+)%s*(%d*)$")
        local Key = FirstGuest()
        local Inv = A.Coop.Modules and A.Coop.Modules.ls_inv
        if not (Path and Key and Inv and Inv.Give) then A.TestLog("give: kein Gast/Pfad/ls_inv") return end
        A.TestLog("give %s x%s an %s: %s", Path, N ~= "" and N or "1", tostring(Key):sub(-28), tostring(Inv.Give(Key, Path, tonumber(N) or 1)))
    end
    -- inv_list: Host = Inventar des ersten Gasts, Gast = eigenes
    T.inv_list = function()
        local Pawn
        if A.NetModeName(A.CurrentWorld()) == "Client" then Pawn = A.OwnPawn() else local _, _, P = FirstGuest() Pawn = P end
        if not A.IsAlive(Pawn) then A.TestLog("inv_list: keine Figur") return end
        A.TestLog("INV %s", ItemList(Pawn))
    end
    -- tp_rock: ersten Gast neben den naechsten Foliage-Felsen setzen (Blick zum Felsen)
    T.tp_rock = function(Arg)
        local GKey, _, Pawn = FirstGuest()
        if not Pawn then A.TestLog("tp_rock: kein Gast") return end
        local L = Pawn:K2_GetActorLocation()
        local Want = (Arg and Arg ~= "") and Arg or "Rock"
        local Best, BD, Checked = nil, math.huge, 0
        for _, C in ipairs(FindAllOf("FoliageInstancedStaticMeshComponent") or {}) do
            if A.IsAlive(C) and Checked < 400000 then
                -- CORE-20: Mesh-Eigenschaft vor dem Aufruf pruefen (ungueltiger Wrapper stuerzt nativ ab)
                local Mesh = A.Safe(function()
                    local SM = C.StaticMesh
                    return A.IsAlive(SM) and SM:GetFName():ToString() or ""
                end, "") or ""
                if Mesh:find(Want) and not Mesh:find("Rocket") and not Mesh:find("Rocking") then
                    local Count = A.Safe(function() return C:GetInstanceCount() end, 0) or 0
                    for I = 0, Count - 1 do
                        Checked = Checked + 1
                        local Out = {}
                        if A.Safe(function() return C:GetInstanceTransform(I, Out, true) end, false) and Out.Translation then
                            local P = Out.Translation
                            local D = (P.X - L.X) ^ 2 + (P.Y - L.Y) ^ 2
                            if D < BD then Best, BD = { X = P.X, Y = P.Y, Z = P.Z, Mesh = Mesh, I = I }, D end
                        end
                    end
                end
            end
        end
        if not Best then A.TestLog("tp_rock: kein Felsen gefunden (%d Instanzen geprueft)", Checked) return end
        local T2 = { X = Best.X - 160, Y = Best.Y, Z = Best.Z + 120 }
        local Rot = { Pitch = -10, Yaw = 0, Roll = 0 }
        pcall(function() Pawn:K2_TeleportTo(T2, Rot) end)
        -- CORE-16: keine Lua-Strukturen an Client-RPCs (ClientSetLocation/-Rotation entfernt); der Gast setzt sich ueber
        -- pl_tp (K27, ls_player) selbst, sonst bleibt nur der Server-Teleport
        local Net = A.Coop.Net
        if Net and GKey and Net.Has and Net.Has("pl_tp", GKey) then
            pcall(Net.Send, "pl_tp", string.format("%.1f|%.1f|%.1f|%.1f", T2.X, T2.Y, T2.Z, Rot.Yaw), GKey, 0)
        end
        A.TestLog("tp_rock: Gast zu %s #%d bei %.0f %.0f %.0f (vorher %.0f m entfernt, %d Instanzen)", Best.Mesh, Best.I,
            Best.X, Best.Y, Best.Z, math.sqrt(BD) / 100, Checked)
    end
    -- spawn_animal <Rabbit|Deer|Bear|Wolf>: 4 m vor dem ersten Gast
    T.spawn_animal = function(Arg)
        local _, _, Pawn = FirstGuest()
        if not Pawn then A.TestLog("spawn_animal: kein Gast") return end
        local Kind = (Arg and Arg ~= "") and Arg or "Rabbit"
        local Path = string.format("/Game/AI/Animals/%s/BP_Animal%s.BP_Animal%s_C", Kind, Kind, Kind)
        local Cls = StaticFindObject(Path)
        if not A.IsAlive(Cls) then pcall(function() Cls = LoadAsset(Path) end) end
        if not A.IsAlive(Cls) then A.TestLog("spawn_animal: Klasse fehlt %s", Path) return end
        local L = Pawn:K2_GetActorLocation()
        local Yaw = A.Safe(function() return Pawn:K2_GetActorRotation().Yaw end, 0)
        local R = math.rad(Yaw)
        local Spot = { X = L.X + math.cos(R) * 400, Y = L.Y + math.sin(R) * 400, Z = L.Z + 50 }
        local ok, Actor = pcall(function() return Pawn:GetWorld():SpawnActor(Cls, Spot, { Pitch = 0, Yaw = Yaw + 180, Roll = 0 }) end)
        A.TestLog("spawn_animal %s: %s %s", Kind, tostring(ok), A.Safe(function() return Actor:GetFName():ToString() end, "?"))
    end
    -- kill_animal: naechstes lebendes Tier beim ersten Gast mit Schaden des Gasts toeten (wie ein Treffer von ihm)
    T.kill_animal = function()
        local _, PC, Pawn = FirstGuest()
        if not Pawn then A.TestLog("kill_animal: kein Gast") return end
        local L = Pawn:K2_GetActorLocation()
        local Best, BD = nil, math.huge
        for _, An in ipairs(FindAllOf("BP_Animal_C") or {}) do
            if A.IsAlive(An) and not A.Safe(function() return An["IsDead?"] end, false) then
                local P = An:K2_GetActorLocation()
                local D = (P.X - L.X) ^ 2 + (P.Y - L.Y) ^ 2
                if D < BD then Best, BD = An, D end
            end
        end
        if not Best then A.TestLog("kill_animal: kein Tier") return end
        -- CAR-1/CORE-21: immer mit echter Schadensart (nil als DamageType-Klasse liess UE4SS/den Server abstuerzen)
        local Dt = A.Safe(function() return StaticFindObject("/Script/Engine.DamageType") end, nil)
        if not A.IsAlive(Dt) then A.TestLog("kill_animal: DamageType nicht gefunden - kein Schaden") return end
        local GS = A.UEHelpers.GetGameplayStatics()
        local ok, err = pcall(function() GS:ApplyDamage(Best, 5000, PC, Pawn, Dt) end)
        A.TestLog("kill_animal %s (%.0f m): %s %s", A.Safe(function() return Best:GetFName():ToString() end, "?"),
            math.sqrt(BD) / 100, tostring(ok), tostring(err or ""))
    end
    -- lootall (Gast): offenes Leichen-/Tier-Loot-Fenster per "Alles nehmen"-Knopf leeren
    T.lootall = function()
        local W = FindFirstOf("W_DeadAIUI_C")
        if not A.IsAlive(W) then A.TestLog("lootall: kein W_DeadAIUI offen") return end
        local ok, err = pcall(function() W:BndEvt__DeadZombieUI_Button_66_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() end)
        A.TestLog("lootall: %s %s", tostring(ok), tostring(err or ""))
    end
end

return Test
