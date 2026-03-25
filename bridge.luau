--!strict
--[[
    DaBlox Bridge v2.0 — File-Based Command & State Bridge
    ═══════════════════════════════════════════════════════
    Persistent daemon inside Roblox. Pure file I/O over ADB.

    WRITES  dablox/state.json     every 50ms  (20Hz)
    READS   dablox/command.json   every 50ms  (20Hz)
    WRITES  dablox/result.json    after each command
    WRITES  dablox/bridge.log     diagnostic log

    Host reads:  adb shell cat /sdcard/dablox/state.json
    Host writes: adb shell "echo '{...}' > /sdcard/dablox/command.json"
    Host reads:  adb shell cat /sdcard/dablox/result.json
]]

print("=== DaBlox Bridge v2.0 — File Bridge Initialized ===")

-- ═══════════════════════════════════════════════════════════
-- Type definitions
-- ═══════════════════════════════════════════════════════════

export type Vec3 = { x: number, y: number, z: number }

export type EntityInfo = {
    name: string, dist: number, pos: Vec3,
    hp: number, maxhp: number, hasPrompt: boolean,
}

export type QuestInfo = {
    active: boolean, text: string, progress: string,
    done: number, needed: number,
}

export type CommandResult = {
    id: number, ok: boolean, result: any?,
    error: string?, ms: number?,
}

export type ModuleInterface = {
    name: string,
    update: ((dt: number) -> ())?,
    onCommand: ((cmd: string, args: { [string]: any }) -> CommandResult?)?,
    getState: (() -> { [string]: any })?,
}

-- ═══════════════════════════════════════════════════════════
-- Constants & paths
-- ═══════════════════════════════════════════════════════════

local VERSION = "2.2.0"
local DIR = "dablox"
local STATE_FILE = DIR .. "/state.json"
local CMD_FILE = DIR .. "/command.json"
local RESULT_FILE = DIR .. "/result.json"
local LOG_FILE = DIR .. "/bridge.log"

-- ═══════════════════════════════════════════════════════════
-- Preflight
-- ═══════════════════════════════════════════════════════════

do
    local missing = {}
    if type(readfile) ~= "function" then table.insert(missing, "readfile") end
    if type(writefile) ~= "function" then table.insert(missing, "writefile") end
    if type(loadstring) ~= "function" then table.insert(missing, "loadstring") end
    if not game then table.insert(missing, "game") end
    if #missing > 0 then
        warn("[DaBlox] FATAL: missing " .. table.concat(missing, ", "))
        return
    end
end

pcall(function() makefolder(DIR) end)

-- ═══════════════════════════════════════════════════════════
-- Services & references
-- ═══════════════════════════════════════════════════════════

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local encode = function(t: any): string return HttpService:JSONEncode(t) end
local decode = function(s: string): any return HttpService:JSONDecode(s) end

-- ═══════════════════════════════════════════════════════════
-- Logging (uses appendfile if available, else read+write)
-- ═══════════════════════════════════════════════════════════

local hasAppendFile = type(appendfile) == "function"
local hasDelFile = type(delfile) == "function"

local function log(msg: string)
    local line = os.date("%H:%M:%S") .. " " .. msg
    print("[DaBlox] " .. msg)
    pcall(function()
        if hasAppendFile then
            appendfile(LOG_FILE, line .. "\n")
        else
            local prev = ""
            pcall(function() prev = readfile(LOG_FILE) end)
            if #prev > 50000 then prev = prev:sub(-25000) end
            writefile(LOG_FILE, prev .. line .. "\n")
        end
    end)
end

local function clearFile(path: string)
    pcall(function()
        if hasDelFile then
            delfile(path)
        else
            writefile(path, "")
        end
    end)
end

-- ═══════════════════════════════════════════════════════════
-- Character tracking
-- ═══════════════════════════════════════════════════════════

local Character: Model? = nil
local Humanoid: Humanoid? = nil
local RootPart: BasePart? = nil

local function refreshChar()
    Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    if Character then
        Humanoid = Character:WaitForChild("Humanoid", 5) :: Humanoid?
        RootPart = Character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
    end
end

pcall(refreshChar)
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.5)
    pcall(refreshChar)
end)

-- ═══════════════════════════════════════════════════════════
-- Module system
-- ═══════════════════════════════════════════════════════════

local Modules: { [string]: ModuleInterface } = {}
local PersistentEnv: { [string]: any } = {}

local function loadModule(name: string, code: string): (boolean, string)
    local fn, err = loadstring(code, "@module:" .. name)
    if not fn then return false, "compile: " .. tostring(err) end
    local ok, result = pcall(fn)
    if not ok then return false, "exec: " .. tostring(result) end
    if type(result) ~= "table" then return false, "must return table" end
    result.name = name
    Modules[name] = result :: ModuleInterface
    log("Module loaded: " .. name)
    return true, "ok"
end

-- ═══════════════════════════════════════════════════════════
-- Bridge API (available to all executed code)
-- ═══════════════════════════════════════════════════════════

local BridgeAPI = {
    game = game,
    workspace = Workspace,
    player = LocalPlayer,
    Players = Players,
    HttpService = HttpService,
    log = log,
    encode = encode,
    decode = decode,
    Vec3 = Vector3.new,
    modules = Modules,
    store = PersistentEnv,
    getCharacter = function() return Character end,
    getHumanoid = function() return Humanoid end,
    getRootPart = function() return RootPart end,
    getPosition = function(): Vec3
        if RootPart then return { x = RootPart.Position.X, y = RootPart.Position.Y, z = RootPart.Position.Z } end
        return { x = 0, y = 0, z = 0 }
    end,
}

-- ═══════════════════════════════════════════════════════════
-- Remote code execution
-- ═══════════════════════════════════════════════════════════

local function executeCode(code: string, cmdId: number): CommandResult
    local fn, compileErr = loadstring(code, "@exec:" .. tostring(cmdId))
    if not fn then
        return { id = cmdId, ok = false, error = "compile: " .. tostring(compileErr) }
    end

    local env = setmetatable({}, {
        __index = function(_, key)
            if BridgeAPI[key] ~= nil then return BridgeAPI[key] end
            if PersistentEnv[key] ~= nil then return PersistentEnv[key] end
            return getfenv(0)[key]
        end,
        __newindex = function(_, key, value)
            PersistentEnv[key] = value
        end,
    })
    setfenv(fn, env)

    local t0 = os.clock()
    local results = {}
    local ok, err = pcall(function() results = { fn() } end)
    local ms = math.floor((os.clock() - t0) * 1000)

    if not ok then
        return { id = cmdId, ok = false, error = "runtime: " .. tostring(err), ms = ms }
    end
    return { id = cmdId, ok = true, result = results[1] or true, ms = ms }
end

-- ═══════════════════════════════════════════════════════════
-- State building
-- ═══════════════════════════════════════════════════════════

local Tick: number = 0
local StartTime: number = os.clock()
local CurrentCmd: string = ""

-- Cached scans
local CachedNPCs: { EntityInfo } = {}
local CachedEnemies: { EntityInfo } = {}
local CachedQuest: QuestInfo = { active = false, text = "", progress = "", done = 0, needed = 0 }

local function v3(v: Vector3): Vec3
    return { x = math.floor(v.X * 10) / 10, y = math.floor(v.Y * 10) / 10, z = math.floor(v.Z * 10) / 10 }
end

local function buildState(): { [string]: any }
    local pos: Vec3 = { x = 0, y = 0, z = 0 }
    local vel: Vec3 = { x = 0, y = 0, z = 0 }
    local hp, maxhp, speed = 0, 0, 0
    local alive, grounded, swimming, moving = false, true, false, false
    local ws, jp = 16, 50

    if RootPart then
        pos = v3(RootPart.Position)
        vel = v3(RootPart.Velocity)
        speed = math.floor(RootPart.Velocity.Magnitude * 10) / 10
    end
    if Humanoid then
        hp = math.floor(Humanoid.Health * 10) / 10
        maxhp = Humanoid.MaxHealth
        alive = Humanoid.Health > 0
        ws = Humanoid.WalkSpeed
        jp = Humanoid.JumpPower
        grounded = Humanoid.FloorMaterial ~= Enum.Material.Air
        swimming = Humanoid:GetState() == Enum.HumanoidStateType.Swimming
        moving = Humanoid.MoveDirection.Magnitude > 0.1
    end

    local stats: { [string]: any } = {}
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _, c in ipairs(ls:GetChildren()) do
            if c:IsA("ValueBase") then stats[c.Name] = (c :: any).Value end
        end
    end

    local toolName = ""
    if Character then
        local t = Character:FindFirstChildOfClass("Tool")
        if t then toolName = t.Name end
    end

    return {
        _v = VERSION, _t = tick(), _tick = Tick,
        _uptime = os.clock() - StartTime, _cmd = CurrentCmd,
        pos = pos, vel = vel, speed = speed,
        hp = hp, maxhp = maxhp, alive = alive,
        walkspeed = ws, jumppower = jp,
        grounded = grounded, swimming = swimming, moving = moving,
        stats = stats, tool = toolName,
        quest = CachedQuest,
        npcs = CachedNPCs, enemies = CachedEnemies,
        player = LocalPlayer.Name, place = game.PlaceId, server = game.JobId,
    }
end

-- ═══════════════════════════════════════════════════════════
-- Entity + quest scanners (run at 2Hz inside state loop)
-- ═══════════════════════════════════════════════════════════

local function scanEntities()
    if not RootPart then return end
    local myPos = RootPart.Position
    local npcs: { EntityInfo } = {}
    local enemies: { EntityInfo } = {}

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if not obj:IsA("Model") then continue end
        local hum = obj:FindFirstChildOfClass("Humanoid")
        local hrp = obj:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp or obj == Character then continue end
        local d = (hrp.Position - myPos).Magnitude
        if d > 80 then continue end

        local entry: EntityInfo = {
            name = obj.Name,
            dist = math.floor(d * 10) / 10,
            pos = { x = math.floor(hrp.Position.X), y = math.floor(hrp.Position.Y), z = math.floor(hrp.Position.Z) },
            hp = math.floor(hum.Health), maxhp = math.floor(hum.MaxHealth),
            hasPrompt = obj:FindFirstChildOfClass("ProximityPrompt", true) ~= nil,
        }
        if entry.hasPrompt then table.insert(npcs, entry) else if hum.Health > 0 then table.insert(enemies, entry) end end
    end

    table.sort(npcs, function(a, b) return a.dist < b.dist end)
    table.sort(enemies, function(a, b) return a.dist < b.dist end)
    CachedNPCs = npcs
    CachedEnemies = enemies
end

local function scanQuest()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    local quest: QuestInfo = { active = false, text = "", progress = "", done = 0, needed = 0 }
    for _, desc in ipairs(pg:GetDescendants()) do
        if not desc:IsA("TextLabel") or not desc.Visible then continue end
        local t = desc.Text or ""
        local d, n = t:match("(%d+)/(%d+)")
        if d and n then
            quest.active = true
            quest.progress = d .. "/" .. n
            quest.done = tonumber(d) or 0
            quest.needed = tonumber(n) or 0
            if #t > #quest.text then quest.text = t end
        end
    end
    CachedQuest = quest
end

-- ═══════════════════════════════════════════════════════════
-- Built-in commands
-- ═══════════════════════════════════════════════════════════

local Builtins: { [string]: (args: { [string]: any }) -> CommandResult } = {}

Builtins.ping = function(args)
    return { id = 0, ok = true, result = { version = VERSION, player = LocalPlayer.Name, uptime = os.clock() - StartTime } }
end

Builtins.state = function(args)
    return { id = 0, ok = true, result = buildState() }
end

Builtins.move_to = function(args)
    if not Humanoid or not RootPart then return { id = 0, ok = false, error = "no character" } end
    local target = Vector3.new(args.x or 0, args.y or RootPart.Position.Y, args.z or 0)
    local radius = args.radius or 6
    local timeoutS = (args.timeout_ms or 15000) / 1000

    CurrentCmd = "move_to"
    local t0 = os.clock()
    Humanoid:MoveTo(target)

    while (os.clock() - t0) < timeoutS do
        if not RootPart then break end
        local d = (Vector3.new(target.X, RootPart.Position.Y, target.Z) - RootPart.Position).Magnitude
        if d < radius then
            CurrentCmd = ""
            return { id = 0, ok = true, result = { arrived = true, dist = math.floor(d * 10) / 10, ms = math.floor((os.clock() - t0) * 1000), pos = v3(RootPart.Position) } }
        end
        task.wait(0.05)
    end

    CurrentCmd = ""
    local fd = RootPart and (Vector3.new(target.X, RootPart.Position.Y, target.Z) - RootPart.Position).Magnitude or 999
    return { id = 0, ok = true, result = { arrived = false, dist = math.floor(fd * 10) / 10, ms = math.floor((os.clock() - t0) * 1000) } }
end

Builtins.move_dir = function(args)
    if not Humanoid or not RootPart then return { id = 0, ok = false, error = "no character" } end
    local angle = math.rad(args.angle or 0)
    local ms = args.ms or 500
    CurrentCmd = "move_dir"
    Humanoid:MoveTo(RootPart.Position + Vector3.new(math.sin(angle), 0, -math.cos(angle)) * 200)
    task.wait(ms / 1000)
    if RootPart then Humanoid:MoveTo(RootPart.Position) end
    CurrentCmd = ""
    return { id = 0, ok = true, result = { pos = RootPart and v3(RootPart.Position) or { x = 0, y = 0, z = 0 } } }
end

Builtins.jump = function(args)
    if Humanoid then Humanoid.Jump = true end
    return { id = 0, ok = true }
end

Builtins.stop = function(args)
    if Humanoid and RootPart then Humanoid:MoveTo(RootPart.Position) end
    CurrentCmd = ""
    return { id = 0, ok = true }
end

Builtins.ability = function(args)
    local slot = args.slot or 1
    local keys = { [1] = Enum.KeyCode.One, [2] = Enum.KeyCode.Two, [3] = Enum.KeyCode.Three, [4] = Enum.KeyCode.Four, [5] = Enum.KeyCode.Five }
    local key = keys[slot]
    if not key then return { id = 0, ok = false, error = "bad slot" } end

    local fired = false
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, key, false, game); task.wait(0.05); vim:SendKeyEvent(false, key, false, game)
        fired = true
    end)
    if not fired then pcall(function() keypress(key.Value); task.wait(0.05); keyrelease(key.Value); fired = true end) end

    return { id = 0, ok = fired, result = { slot = slot } }
end

Builtins.interact = function(args)
    if not RootPart then return { id = 0, ok = false, error = "no character" } end
    local best: ProximityPrompt? = nil
    local bestDist: number = args.dist or 15

    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and obj.Enabled then
            local part = obj.Parent :: BasePart?
            if part and part:IsA("BasePart") then
                local d = (part.Position - RootPart.Position).Magnitude
                if d < bestDist then best = obj :: ProximityPrompt; bestDist = d end
            end
        end
    end

    if not best then return { id = 0, ok = true, result = { action = "nothing" } } end

    pcall(function() fireproximityprompt(best) end)
    task.wait(0.5)

    local buttons: { string } = {}
    local texts: { string } = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, desc in ipairs(pg:GetDescendants()) do
            if desc:IsA("TextButton") and desc.Visible and #desc.Text > 0 then table.insert(buttons, desc.Text)
            elseif desc:IsA("TextLabel") and desc.Visible and #desc.Text > 2 then table.insert(texts, desc.Text) end
        end
    end

    return { id = 0, ok = true, result = { action = "interacted", dist = math.floor(bestDist), buttons = buttons, texts = texts } }
end

Builtins.tap_button = function(args)
    local target = (args.text or ""):lower()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return { id = 0, ok = false, error = "no gui" } end
    for _, desc in ipairs(pg:GetDescendants()) do
        if desc:IsA("TextButton") and desc.Visible and #desc.Text > 0 then
            if desc.Text:lower():find(target) then
                pcall(function() desc.Activated:Fire() end)
                pcall(function() desc.MouseButton1Click:Fire() end)
                return { id = 0, ok = true, result = { tapped = desc.Text } }
            end
        end
    end
    return { id = 0, ok = false, error = "not found: " .. target }
end

Builtins.nearby = function(args) pcall(scanEntities); return { id = 0, ok = true, result = { npcs = CachedNPCs, enemies = CachedEnemies } } end
Builtins.quest = function(args) pcall(scanQuest); return { id = 0, ok = true, result = CachedQuest } end

Builtins.reflect = function(args)
    local pathStr: string = args.path or "game"
    local depth: number = args.depth or 1
    local function resolve(p: string): Instance?
        local obj: Instance = game
        for seg in p:gmatch("[^%.]+") do
            if seg == "game" then continue end
            local c = obj:FindFirstChild(seg); if not c then return nil end; obj = c
        end
        return obj
    end
    local function describe(obj: Instance, d: number): { [string]: any }
        local info: { [string]: any } = { name = obj.Name, class = obj.ClassName, childCount = #obj:GetChildren() }
        pcall(function() if obj:IsA("BasePart") then info.position = v3(obj.Position) end end)
        pcall(function() if obj:IsA("Humanoid") then info.health = obj.Health; info.maxHealth = obj.MaxHealth end end)
        pcall(function() if obj:IsA("TextLabel") or obj:IsA("TextButton") then info.text = obj.Text; info.visible = obj.Visible end end)
        pcall(function() if obj:IsA("ValueBase") then info.value = (obj :: any).Value end end)
        if d > 0 then info.children = {}; for _, c in ipairs(obj:GetChildren()) do table.insert(info.children, describe(c, d - 1)) end end
        return info
    end
    local obj = resolve(pathStr)
    if not obj then return { id = 0, ok = false, error = "not found: " .. pathStr } end
    return { id = 0, ok = true, result = describe(obj, depth) }
end

Builtins.load_module = function(args)
    local ok, err = loadModule(args.name or "", args.code or "")
    return { id = 0, ok = ok, error = if ok then nil else err }
end

Builtins.unload_module = function(args) Modules[args.name or ""] = nil; return { id = 0, ok = true } end
Builtins.list_modules = function(args)
    local n = {}; for k in pairs(Modules) do table.insert(n, k) end
    return { id = 0, ok = true, result = n }
end

Builtins.safety = function(args)
    if args.drowning ~= nil then PersistentEnv._safety_drowning = args.drowning end
    if args.death ~= nil then PersistentEnv._safety_death = args.death end
    return { id = 0, ok = true, result = { drowning = PersistentEnv._safety_drowning ~= false, death = PersistentEnv._safety_death ~= false } }
end

Builtins.load_script = function(args)
    local url = args.url or ""
    if #url < 10 then return { id = 0, ok = false, error = "no url" } end
    local ok, result = pcall(function() return game:HttpGet(url, true) end)
    if not ok or type(result) ~= "string" then return { id = 0, ok = false, error = "fetch failed: " .. tostring(result) } end
    local fn, err = loadstring(result, "@remote:" .. url:sub(-30))
    if not fn then return { id = 0, ok = false, error = "compile: " .. tostring(err) } end
    local eok, eerr = pcall(fn)
    if not eok then return { id = 0, ok = false, error = "exec: " .. tostring(eerr) } end
    return { id = 0, ok = true, result = { loaded = url, bytes = #result } }
end

-- ═══════════════════════════════════════════════════════════
-- SCRIPT ORCHESTRATOR — fetch, execute, introspect, configure
-- ═══════════════════════════════════════════════════════════

--[[
    Hub scripts (like Hoho Hub, Blox Fruits Script Hub, etc.) create
    ScreenGuis with toggle buttons. Common UI patterns:

    Pattern 1: TextButton with text "Auto Farm" — click to toggle
    Pattern 2: TextButton "Auto Farm [ON]" / "Auto Farm [OFF]"
    Pattern 3: Frame with TextLabel "Auto Farm" + child toggle button
    Pattern 4: ImageButton acting as checkbox (BackgroundColor changes)
    Pattern 5: Frame-based slider with a draggable knob
    Pattern 6: TextButton inside a ScrollingFrame (script hub menus)

    The scanner identifies all of these and the manipulator clicks them.
]]

-- Track which ScreenGuis existed before a script load
local PreExistingGuis: { [string]: boolean } = {}

local function snapshotGuis(): { [string]: boolean }
    local snapshot: { [string]: boolean } = {}

    -- Scan PlayerGui
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, child in ipairs(pg:GetChildren()) do
            if child:IsA("ScreenGui") then
                snapshot[child:GetFullName()] = true
            end
        end
    end

    -- Scan CoreGui (some scripts parent their UI here)
    pcall(function()
        local cg = game:GetService("CoreGui")
        for _, child in ipairs(cg:GetChildren()) do
            if child:IsA("ScreenGui") then
                snapshot[child:GetFullName()] = true
            end
        end
    end)

    -- Scan gethui() if available (hidden UI container some executors use)
    pcall(function()
        if gethui then
            for _, child in ipairs(gethui():GetChildren()) do
                if child:IsA("ScreenGui") then
                    snapshot[child:GetFullName()] = true
                end
            end
        end
    end)

    return snapshot
end

local function findNewGuis(before: { [string]: boolean }): { Instance }
    local newGuis: { Instance } = {}

    local function scan(parent: Instance)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("ScreenGui") and not before[child:GetFullName()] then
                table.insert(newGuis, child)
            end
        end
    end

    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then scan(pg) end
    pcall(function() scan(game:GetService("CoreGui")) end)
    pcall(function() if gethui then scan(gethui()) end end)

    return newGuis
end

-- ─── GUI Element Scanner ──────────────────────────────────

export type ScannedElement = {
    text: string,           -- Display text ("Auto Farm", "Speed Hack [ON]")
    cleanText: string,      -- Cleaned key ("autofarm", "speedhack")
    elementType: string,    -- "button", "toggle", "checkbox", "slider", "label"
    state: string,          -- "on", "off", "unknown", or a numeric value
    className: string,      -- Roblox ClassName
    fullName: string,       -- GetFullName() for debugging
    path: string,           -- Shortened path for logging
    guiName: string,        -- Which ScreenGui this belongs to
}

local function cleanOptionKey(text: string): string
    -- "Auto Farm [ON]" → "autofarm"
    -- "Speed Hack: 2.5" → "speedhack"
    local clean = text:lower()
    clean = clean:gsub("%[on%]", ""):gsub("%[off%]", "")
    clean = clean:gsub("%[x%]", ""):gsub("%[ %]", "")
    clean = clean:gsub("enabled", ""):gsub("disabled", "")
    clean = clean:gsub("[:%-%_%.]", ""):gsub("%s+", "")
    clean = clean:gsub("^%s+", ""):gsub("%s+$", "")
    return clean
end

local function detectState(element: Instance): string
    -- Try to determine if a toggle is ON or OFF

    -- Check text content
    if element:IsA("TextButton") or element:IsA("TextLabel") then
        local t = (element :: any).Text:lower()
        if t:find("%[on%]") or t:find("enabled") or t:find("✓") or t:find("✔") then
            return "on"
        end
        if t:find("%[off%]") or t:find("disabled") or t:find("✗") or t:find("✘") then
            return "off"
        end
    end

    -- Check background color (green = on, red/gray = off)
    pcall(function()
        local bg = (element :: any).BackgroundColor3
        if bg then
            -- Green-ish
            if bg.G > 0.5 and bg.R < 0.5 then return "on" end
            -- Red-ish or gray
            if bg.R > 0.5 and bg.G < 0.3 then return "off" end
            if bg.R < 0.3 and bg.G < 0.3 and bg.B < 0.3 then return "off" end
        end
    end)

    -- Check if there's a child Frame that acts as a toggle indicator
    for _, child in ipairs(element:GetChildren()) do
        if child:IsA("Frame") or child:IsA("ImageLabel") then
            pcall(function()
                local bg = child.BackgroundColor3
                if bg.G > 0.5 and bg.R < 0.4 then return "on" end
            end)
        end
    end

    return "unknown"
end

local function scanGuiElements(targets: { Instance }?): { ScannedElement }
    local elements: { ScannedElement } = {}
    local seen: { [string]: boolean } = {}

    local guisToScan: { Instance } = targets or {}

    -- If no specific targets, scan everything
    if #guisToScan == 0 then
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then
            for _, child in ipairs(pg:GetChildren()) do
                if child:IsA("ScreenGui") and child.Enabled then
                    table.insert(guisToScan, child)
                end
            end
        end
        pcall(function()
            for _, child in ipairs(game:GetService("CoreGui"):GetChildren()) do
                if child:IsA("ScreenGui") then
                    table.insert(guisToScan, child)
                end
            end
        end)
        pcall(function()
            if gethui then
                for _, child in ipairs(gethui():GetChildren()) do
                    if child:IsA("ScreenGui") then
                        table.insert(guisToScan, child)
                    end
                end
            end
        end)
    end

    for _, gui in ipairs(guisToScan) do
        local guiName = gui.Name
        for _, desc in ipairs(gui:GetDescendants()) do
            local text = ""
            local elementType = "unknown"
            local isInteractive = false

            -- TextButton — most common toggle type
            if desc:IsA("TextButton") and desc.Visible then
                text = desc.Text or ""
                elementType = "button"
                isInteractive = true

            -- ImageButton — often used as checkboxes
            elseif desc:IsA("ImageButton") and desc.Visible then
                -- Check for a sibling or parent TextLabel to get the name
                text = desc.Name
                if desc.Parent then
                    for _, sib in ipairs(desc.Parent:GetChildren()) do
                        if sib:IsA("TextLabel") and sib.Visible and #sib.Text > 1 then
                            text = sib.Text
                            break
                        end
                    end
                end
                elementType = "checkbox"
                isInteractive = true

            -- Frame that looks like a toggle (has a TextLabel + clickable child)
            elseif desc:IsA("Frame") and desc.Visible then
                local hasLabel = false
                local hasButton = false
                local labelText = ""
                for _, child in ipairs(desc:GetChildren()) do
                    if child:IsA("TextLabel") and child.Visible and #child.Text > 1 then
                        hasLabel = true
                        labelText = child.Text
                    end
                    if child:IsA("TextButton") or child:IsA("ImageButton") then
                        hasButton = true
                    end
                end
                if hasLabel and hasButton then
                    text = labelText
                    elementType = "toggle"
                    isInteractive = true
                end
            end

            -- Filter: must have meaningful text and not be a duplicate
            if isInteractive and #text > 1 and #text < 100 then
                local cleanKey = cleanOptionKey(text)
                if #cleanKey > 1 and not seen[cleanKey] then
                    seen[cleanKey] = true
                    table.insert(elements, {
                        text = text,
                        cleanText = cleanKey,
                        elementType = elementType,
                        state = detectState(desc),
                        className = desc.ClassName,
                        fullName = desc:GetFullName(),
                        path = guiName .. "/" .. desc.Name,
                        guiName = guiName,
                    })
                end
            end
        end
    end

    return elements
end

-- ─── GUI Element Manipulator ──────────────────────────────

local function clickElement(element: Instance): boolean
    -- Try every known click method
    local clicked = false

    pcall(function()
        if element:IsA("TextButton") or element:IsA("ImageButton") then
            (element :: any).Activated:Fire()
            clicked = true
        end
    end)

    if not clicked then
        pcall(function()
            (element :: any).MouseButton1Click:Fire()
            clicked = true
        end)
    end

    if not clicked then
        pcall(function()
            if firetouchinterest then
                firetouchinterest(element, element, 0) -- touch begin
                task.wait(0.05)
                firetouchinterest(element, element, 1) -- touch end
                clicked = true
            end
        end)
    end

    if not clicked then
        pcall(function()
            if fireclickdetector then
                local cd = element:FindFirstChildOfClass("ClickDetector")
                if cd then fireclickdetector(cd); clicked = true end
            end
        end)
    end

    return clicked
end

local function findAndClick(guis: { Instance }, optionKey: string): (boolean, string)
    local searchKey = cleanOptionKey(optionKey)

    for _, gui in ipairs(guis) do
        for _, desc in ipairs(gui:GetDescendants()) do
            -- Direct TextButton match
            if desc:IsA("TextButton") and desc.Visible then
                local btnKey = cleanOptionKey(desc.Text or "")
                if btnKey == searchKey or btnKey:find(searchKey) then
                    if clickElement(desc) then
                        return true, desc.Text
                    end
                end
            end

            -- Frame with label + toggle child
            if desc:IsA("Frame") and desc.Visible then
                local labelMatch = false
                local toggleBtn = nil
                for _, child in ipairs(desc:GetChildren()) do
                    if child:IsA("TextLabel") and child.Visible then
                        local labelKey = cleanOptionKey(child.Text or "")
                        if labelKey == searchKey or labelKey:find(searchKey) then
                            labelMatch = true
                        end
                    end
                    if child:IsA("TextButton") or child:IsA("ImageButton") then
                        toggleBtn = child
                    end
                end
                if labelMatch and toggleBtn then
                    if clickElement(toggleBtn) then
                        return true, optionKey .. " (frame toggle)"
                    end
                end
            end

            -- ImageButton checkbox with sibling label
            if desc:IsA("ImageButton") and desc.Visible and desc.Parent then
                for _, sib in ipairs(desc.Parent:GetChildren()) do
                    if sib:IsA("TextLabel") and sib.Visible then
                        local sibKey = cleanOptionKey(sib.Text or "")
                        if sibKey == searchKey or sibKey:find(searchKey) then
                            if clickElement(desc) then
                                return true, sib.Text .. " (checkbox)"
                            end
                        end
                    end
                end
            end
        end
    end

    return false, "not found: " .. optionKey
end

-- ─── Built-in commands for the orchestrator ───────────────

Builtins.scan_gui = function(args)
    -- Scan all visible GUIs and return detected interactive elements
    local elements = scanGuiElements()
    local summary = {}
    for _, el in ipairs(elements) do
        table.insert(summary, {
            text = el.text,
            key = el.cleanText,
            type = el.elementType,
            state = el.state,
            gui = el.guiName,
            path = el.path,
        })
    end
    log("GUI scan: found " .. #summary .. " interactive elements")
    return { id = 0, ok = true, result = { count = #summary, elements = summary } }
end

Builtins.click_option = function(args)
    -- Click a specific option by text match
    local option = args.option or args.text or ""
    if #option < 1 then return { id = 0, ok = false, error = "no option specified" } end

    -- Gather all GUIs
    local guis: { Instance } = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then for _, c in ipairs(pg:GetChildren()) do if c:IsA("ScreenGui") then table.insert(guis, c) end end end
    pcall(function() for _, c in ipairs(game:GetService("CoreGui"):GetChildren()) do if c:IsA("ScreenGui") then table.insert(guis, c) end end end)
    pcall(function() if gethui then for _, c in ipairs(gethui():GetChildren()) do if c:IsA("ScreenGui") then table.insert(guis, c) end end end end)

    local clicked, detail = findAndClick(guis, option)
    if clicked then
        log("Clicked option: " .. detail)
        return { id = 0, ok = true, result = { clicked = detail } }
    end
    return { id = 0, ok = false, error = "option not found: " .. option }
end

Builtins.load_and_configure_script = function(args)
    --[[
        Dynamic Script Loader + GUI Configurator
        ══════════════════════════════════════════
        Handles plain Luau AND LuaArmor-protected scripts.

        LuaArmor scripts are obfuscated blobs that self-decrypt at runtime.
        They take 2-6 seconds after execution before their GUI appears.
        The source code is encrypted so only GUI-based detection works.

        Flow:
          1. Snapshot existing GUIs (to detect new ones)
          2. Fetch script (HttpGet with cache=false for armored scripts)
          3. Save raw code to dablox/scripts/ (for debugging/analysis)
          4. Execute with loadstring()
          5. Adaptive wait: poll for new GUIs every 0.5s up to 8 seconds
          6. Deep scan every new ScreenGui for interactive elements
          7. Match desired_options to detected elements using fuzzy keywords
          8. Smart toggle: check current state before clicking (avoid double-toggle)
          9. Handle numeric values: find TextBoxes, sliders, or related inputs
         10. Return detailed report with everything found and configured

        Keyword matching strategy:
          "AutoFarm" matches: "Auto Farm", "Auto Farm [ON]", "autofarm", "Auto-Farm"
          "Speed"    matches: "Speed Hack", "WalkSpeed", "Speed: 16"
          Uses cleanOptionKey() which strips spaces, brackets, state text, punctuation
    ]]

    local url = args.url or ""
    local options = args.options or args.desired_options or {}
    local minWait = args.min_wait or 4       -- LuaArmor needs at least 4s
    local maxWait = args.max_wait or 8       -- Give up after 8s
    local retryClicks = args.retry_clicks or 3
    local scriptName = args.name or "temp_script"

    if #url < 10 then return { id = 0, ok = false, error = "no url" } end

    CurrentCmd = "load_and_configure"
    local report = {
        url = url,
        script_name = scriptName,
        fetched = false,
        source_bytes = 0,
        source_saved = false,
        source_path = "",
        is_armored = false,
        executed = false,
        gui_wait_ms = 0,
        new_guis = {},
        gui_elements_found = 0,
        options_requested = 0,
        options_applied = 0,
        options_skipped = {},
        options_failed = {},
        elements = {},
        log = {},
    }

    local function rlog(msg: string)
        table.insert(report.log, msg)
        log("LoadCfg: " .. msg)
    end

    -- ─── Step 1: Snapshot existing GUIs ───────────────────
    local guiBefore = snapshotGuis()
    local beforeCount = 0
    for _ in pairs(guiBefore) do beforeCount += 1 end
    rlog("Snapshot: " .. beforeCount .. " existing GUIs")

    -- ─── Step 2: Fetch the script ─────────────────────────
    -- Use cache=false for armored scripts (they may be one-time-use tokens)
    rlog("Fetching: " .. url)
    local fetchOk, scriptCode = pcall(function()
        return game:HttpGet(url, false)
    end)

    if not fetchOk or type(scriptCode) ~= "string" or #scriptCode < 20 then
        -- Retry with cache enabled (some CDNs require it)
        rlog("First fetch failed, retrying with cache...")
        fetchOk, scriptCode = pcall(function()
            return game:HttpGet(url, true)
        end)
    end

    if not fetchOk or type(scriptCode) ~= "string" or #scriptCode < 20 then
        rlog("FAILED: Could not download script")
        CurrentCmd = ""
        return { id = 0, ok = false, error = "fetch failed: " .. tostring(scriptCode), result = report }
    end

    report.fetched = true
    report.source_bytes = #scriptCode
    rlog("Downloaded " .. #scriptCode .. " bytes")

    -- Detect if this is a LuaArmor/obfuscated script
    -- LuaArmor scripts typically start with a long string assignment or have no readable function names
    local looksArmored = false
    if scriptCode:find("LPH_") or scriptCode:find("getfenv") and #scriptCode > 10000 then
        looksArmored = true
    end
    if not scriptCode:find("function") and #scriptCode > 5000 then
        looksArmored = true
    end
    -- Very long single-line scripts are usually obfuscated
    local firstNewline = scriptCode:find("\n") or #scriptCode
    if firstNewline > 5000 then
        looksArmored = true
    end

    report.is_armored = looksArmored
    if looksArmored then
        rlog("Detected: LuaArmor/obfuscated script (source analysis unavailable)")
    else
        rlog("Detected: Plain Luau script")
    end

    -- ─── Step 3: Save raw source to file ──────────────────
    pcall(function() makefolder("dablox/scripts") end)
    local savePath = "dablox/scripts/" .. scriptName .. ".luau"
    local saveOk = pcall(function()
        writefile(savePath, scriptCode)
    end)
    if saveOk then
        report.source_saved = true
        report.source_path = savePath
        rlog("Source saved: " .. savePath .. " (" .. #scriptCode .. " bytes)")
    else
        rlog("WARNING: Could not save source file")
    end

    -- ─── Step 4: Execute the script ───────────────────────
    rlog("Executing...")
    local fn, compileErr = loadstring(scriptCode, "@script:" .. scriptName)
    if not fn then
        rlog("COMPILE ERROR: " .. tostring(compileErr))
        CurrentCmd = ""
        report.error = "compile: " .. tostring(compileErr)
        -- Still return with source saved — host can inspect it
        return { id = 0, ok = false, result = report }
    end

    local execOk, execErr = pcall(fn)
    if not execOk then
        rlog("EXEC ERROR: " .. tostring(execErr))
        CurrentCmd = ""
        report.error = "exec: " .. tostring(execErr)
        return { id = 0, ok = false, result = report }
    end

    report.executed = true
    rlog("Script executed successfully")

    -- ─── Step 5: Adaptive wait for GUI ────────────────────
    -- LuaArmor scripts need 2-6s to decrypt and render their UI.
    -- We poll every 0.5s. Once we see new GUIs, wait an extra 2s
    -- for child elements to finish rendering (many hubs build their
    -- UI progressively with tweens and animations).

    rlog("Waiting for GUI (min=" .. minWait .. "s, max=" .. maxWait .. "s)...")
    local waitStart = os.clock()
    local newGuis: { Instance } = {}
    local guiDetectedAt = 0

    while (os.clock() - waitStart) < maxWait do
        task.wait(0.5)
        newGuis = findNewGuis(guiBefore)

        if #newGuis > 0 and guiDetectedAt == 0 then
            guiDetectedAt = os.clock() - waitStart
            rlog("New GUI detected at " .. string.format("%.1f", guiDetectedAt) .. "s")

            -- Wait at least minWait total, plus extra for rendering
            local remaining = math.max(2, minWait - guiDetectedAt)
            rlog("Waiting " .. string.format("%.1f", remaining) .. "s more for full render...")
            task.wait(remaining)

            -- Re-scan to catch late-spawning elements
            newGuis = findNewGuis(guiBefore)
            break
        end
    end

    report.gui_wait_ms = math.floor((os.clock() - waitStart) * 1000)

    for _, gui in ipairs(newGuis) do
        table.insert(report.new_guis, gui.Name)
    end

    if #newGuis == 0 then
        rlog("No new GUIs after " .. maxWait .. "s — script may not have visible UI")
        rlog("Will scan all existing GUIs as fallback")
    else
        rlog("Found " .. #newGuis .. " new ScreenGui(s): " .. table.concat(report.new_guis, ", "))
    end

    -- ─── Step 6: Deep scan for interactive elements ───────
    rlog("Scanning for interactive elements...")
    local scanTargets = #newGuis > 0 and newGuis or nil
    local elements = scanGuiElements(scanTargets)
    report.gui_elements_found = #elements

    for _, el in ipairs(elements) do
        table.insert(report.elements, {
            text = el.text,
            key = el.cleanText,
            type = el.elementType,
            state = el.state,
            class = el.className,
            gui = el.guiName,
            path = el.path,
            fullName = el.fullName,
        })
    end

    rlog("Found " .. #elements .. " interactive elements:")
    for _, el in ipairs(elements) do
        rlog("  [" .. el.elementType .. "] " .. el.text .. " (" .. el.state .. ") @ " .. el.guiName)
    end

    -- ─── Step 7: Apply desired options ────────────────────
    local optionCount = 0
    for _ in pairs(options) do optionCount += 1 end
    report.options_requested = optionCount

    if optionCount == 0 then
        rlog("No options requested — returning scan results only")
        CurrentCmd = ""
        return { id = 0, ok = true, result = report }
    end

    rlog("Applying " .. optionCount .. " options...")

    -- Build search GUI list
    local searchGuis: { Instance } = {}
    if #newGuis > 0 then
        searchGuis = newGuis
    else
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then
            for _, c in ipairs(pg:GetChildren()) do
                if c:IsA("ScreenGui") then table.insert(searchGuis, c) end
            end
        end
        pcall(function()
            for _, c in ipairs(game:GetService("CoreGui"):GetChildren()) do
                if c:IsA("ScreenGui") then table.insert(searchGuis, c) end
            end
        end)
        pcall(function()
            if gethui then
                for _, c in ipairs(gethui():GetChildren()) do
                    if c:IsA("ScreenGui") then table.insert(searchGuis, c) end
                end
            end
        end)
    end

    for optionName, desiredValue in pairs(options) do
        local applied = false
        local searchKey = cleanOptionKey(optionName)

        -- Find the matching element in our scan results to check its current state
        local currentState = "unknown"
        local matchedElement: ScannedElement? = nil
        for _, el in ipairs(elements) do
            if el.cleanText == searchKey or el.cleanText:find(searchKey) or searchKey:find(el.cleanText) then
                currentState = el.state
                matchedElement = el
                break
            end
        end

        -- Smart toggle: skip if already in desired state
        if type(desiredValue) == "boolean" then
            if desiredValue == true and currentState == "on" then
                rlog("  ~ " .. optionName .. " — already ON, skipping")
                table.insert(report.options_skipped, optionName)
                report.options_applied += 1  -- counts as applied (goal met)
                applied = true
            elseif desiredValue == false and currentState == "off" then
                rlog("  ~ " .. optionName .. " — already OFF, skipping")
                table.insert(report.options_skipped, optionName)
                report.options_applied += 1
                applied = true
            end
        end

        -- If not already handled, try clicking
        if not applied then
            for attempt = 1, retryClicks do
                local clicked, detail = findAndClick(searchGuis, optionName)
                if clicked then
                    rlog("  ✓ " .. optionName .. " → clicked (" .. detail .. ")")
                    applied = true

                    -- For numeric values, try to set a property after clicking
                    if type(desiredValue) == "number" and matchedElement then
                        -- Look for a TextBox or slider near the matched element
                        pcall(function()
                            -- Find instance by fullName
                            local function findByFullName(name: string): Instance?
                                for _, gui in ipairs(searchGuis) do
                                    for _, desc in ipairs(gui:GetDescendants()) do
                                        if desc:GetFullName() == name then return desc end
                                    end
                                end
                                return nil
                            end

                            local matched = findByFullName(matchedElement.fullName)
                            if matched and matched.Parent then
                                -- Search siblings and children for TextBox or value holder
                                for _, sib in ipairs(matched.Parent:GetDescendants()) do
                                    if sib:IsA("TextBox") then
                                        sib.Text = tostring(desiredValue)
                                        -- Fire focus lost to trigger update
                                        pcall(function() sib.FocusLost:Fire(true) end)
                                        rlog("  ✓ " .. optionName .. " → set TextBox to " .. tostring(desiredValue))
                                        break
                                    elseif sib:IsA("ValueBase") then
                                        (sib :: any).Value = desiredValue
                                        rlog("  ✓ " .. optionName .. " → set Value to " .. tostring(desiredValue))
                                        break
                                    end
                                end
                            end
                        end)
                    end

                    break
                end

                if attempt < retryClicks then
                    task.wait(0.5)
                    -- Re-scan in case GUI updated after previous clicks
                    if attempt == 2 then
                        rlog("  ... re-scanning GUI after initial clicks")
                        elements = scanGuiElements(scanTargets)
                    end
                end
            end
        end

        if applied then
            if not table.find(report.options_skipped, optionName) then
                report.options_applied += 1
            end
        else
            table.insert(report.options_failed, optionName)
            rlog("  ✗ " .. optionName .. " — not found in any GUI")
        end
    end

    -- ─── Step 8: Post-configuration verification scan ─────
    -- Re-scan to see if toggles actually changed state
    task.wait(0.5)
    local postElements = scanGuiElements(scanTargets)
    local postSummary = {}
    for _, el in ipairs(postElements) do
        table.insert(postSummary, {
            key = el.cleanText,
            state = el.state,
        })
    end
    report.post_scan = postSummary
    rlog("Post-scan: " .. #postElements .. " elements after configuration")

    rlog("Complete: " .. report.options_applied .. "/" .. optionCount .. " applied, " ..
         #report.options_failed .. " failed, " .. #report.options_skipped .. " skipped")
    CurrentCmd = ""
    return { id = 0, ok = true, result = report }
end

-- ═══════════════════════════════════════════════════════════
-- PHASE 2 ORCHESTRATOR — Claude-in-the-loop analysis
-- ═══════════════════════════════════════════════════════════

--[[
    Two-phase flow:

    Phase A: analyze_script
      1. Download script from URL
      2. Save raw source to dablox/scripts/ for host to pull
      3. Execute the script
      4. Wait for GUI to render
      5. Deep-scan all new GUI elements
      6. Write analysis report to dablox/analysis.json
      7. Return analysis to host

    Phase B: apply_configuration (sent by host after Claude analyzes)
      1. Receive precise action plan from Claude
      2. Execute each action: click buttons, set properties, fire events
      3. Verify each action took effect
      4. Return execution report

    The host pulls the source code, sends it + the GUI scan to Claude,
    Claude returns a precise configuration plan, host sends it back.
]]

Builtins.analyze_script = function(args)
    local url = args.url or ""
    local waitTime = args.wait_seconds or 4
    local scriptName = args.name or "downloaded_script"

    if #url < 10 then return { id = 0, ok = false, error = "no url" } end

    CurrentCmd = "analyze_script"
    local report = {
        phase = "analyze",
        url = url,
        script_name = scriptName,
        fetched = false,
        source_saved = false,
        source_path = "",
        source_bytes = 0,
        executed = false,
        gui_elements = {},
        gui_element_count = 0,
        new_gui_names = {},
        full_gui_tree = {},
        log = {},
    }

    local function rlog(msg: string)
        table.insert(report.log, msg)
        log("Analyze: " .. msg)
    end

    -- Step 1: Snapshot GUIs before load
    local guiBefore = snapshotGuis()
    local guiCountBefore = 0
    for _ in pairs(guiBefore) do guiCountBefore += 1 end
    rlog("Snapshot: " .. guiCountBefore .. " existing GUIs")

    -- Step 2: Fetch script source
    rlog("Fetching: " .. url)
    local fetchOk, scriptCode = pcall(function()
        return game:HttpGet(url, true)
    end)

    if not fetchOk or type(scriptCode) ~= "string" or #scriptCode < 20 then
        rlog("Fetch failed: " .. tostring(scriptCode))
        CurrentCmd = ""
        return { id = 0, ok = false, error = "fetch failed", result = report }
    end

    report.fetched = true
    report.source_bytes = #scriptCode
    rlog("Downloaded " .. #scriptCode .. " bytes")

    -- Step 3: Save raw source for host to pull via ADB
    pcall(function() makefolder("dablox/scripts") end)
    local savePath = "dablox/scripts/" .. scriptName .. ".luau"
    local saveOk = pcall(function()
        writefile(savePath, scriptCode)
    end)

    if saveOk then
        report.source_saved = true
        report.source_path = savePath
        rlog("Source saved to " .. savePath)
    else
        rlog("WARNING: Could not save source file")
    end

    -- Step 4: Execute the script
    rlog("Executing script...")
    local fn, compileErr = loadstring(scriptCode, "@analyze:" .. scriptName)
    if not fn then
        rlog("Compile error: " .. tostring(compileErr))
        report.error = "compile: " .. tostring(compileErr)
        -- Still return — host can analyze the source even if it doesn't compile
        CurrentCmd = ""
        return { id = 0, ok = true, result = report }
    end

    local execOk, execErr = pcall(fn)
    if not execOk then
        rlog("Exec error: " .. tostring(execErr))
        report.error = "exec: " .. tostring(execErr)
        CurrentCmd = ""
        return { id = 0, ok = true, result = report }
    end

    report.executed = true
    rlog("Script executed")

    -- Step 5: Wait for GUI to render
    rlog("Waiting " .. waitTime .. "s for GUI...")
    local newGuis: { Instance } = {}
    local waitDeadline = os.clock() + waitTime

    while os.clock() < waitDeadline do
        task.wait(0.5)
        newGuis = findNewGuis(guiBefore)
        if #newGuis > 0 then
            task.wait(1.5)
            newGuis = findNewGuis(guiBefore)
            break
        end
    end

    for _, gui in ipairs(newGuis) do
        table.insert(report.new_gui_names, gui.Name)
    end
    rlog("Found " .. #newGuis .. " new ScreenGui(s)")

    -- Step 6: Deep scan — get every interactive element with full detail
    local scanTargets = #newGuis > 0 and newGuis or nil
    local elements = scanGuiElements(scanTargets)
    report.gui_element_count = #elements

    for _, el in ipairs(elements) do
        table.insert(report.gui_elements, {
            text = el.text,
            key = el.cleanText,
            type = el.elementType,
            state = el.state,
            class = el.className,
            gui = el.guiName,
            path = el.path,
            fullName = el.fullName,
        })
    end

    -- Step 7: Build deep GUI tree for Claude to analyze
    -- This gives Claude the actual UI hierarchy, not just flat elements
    for _, gui in ipairs(newGuis) do
        local tree = {}
        local function walkTree(parent: Instance, depth: number, container: { any })
            if depth > 5 then return end
            for _, child in ipairs(parent:GetChildren()) do
                local node: { [string]: any } = {
                    name = child.Name,
                    class = child.ClassName,
                }

                -- Capture relevant properties
                pcall(function()
                    if child:IsA("TextButton") or child:IsA("TextLabel") then
                        node.text = (child :: any).Text
                        node.visible = (child :: any).Visible
                    end
                    if child:IsA("ImageButton") or child:IsA("ImageLabel") then
                        node.image = (child :: any).Image
                        node.visible = (child :: any).Visible
                    end
                    if child:IsA("Frame") then
                        node.visible = (child :: any).Visible
                        node.bgColor = tostring((child :: any).BackgroundColor3)
                    end
                    if child:IsA("GuiObject") then
                        node.size = tostring((child :: any).Size)
                        node.position = tostring((child :: any).Position)
                    end
                    if child:IsA("TextBox") then
                        node.text = (child :: any).Text
                        node.placeholderText = (child :: any).PlaceholderText
                    end
                end)

                local children = {}
                if #child:GetChildren() > 0 then
                    walkTree(child, depth + 1, children)
                end
                if #children > 0 then
                    node.children = children
                end

                table.insert(container, node)
            end
        end

        local guiTree: { any } = {}
        walkTree(gui, 0, guiTree)
        table.insert(report.full_gui_tree, {
            name = gui.Name,
            children = guiTree,
        })
    end

    -- Step 8: Write analysis file so host can pull it
    pcall(function()
        writefile("dablox/analysis.json", encode(report))
    end)

    rlog("Analysis complete: " .. report.gui_element_count .. " elements, " .. #report.full_gui_tree .. " GUI trees")
    CurrentCmd = ""
    return { id = 0, ok = true, result = report }
end

Builtins.apply_configuration = function(args)
    --[[
        Execute a precise configuration plan (usually generated by Claude).

        The plan is an ordered list of actions:
        {
            actions = {
                {type = "click", target = "Auto Farm", retries = 2},
                {type = "click", target = "Auto Quest"},
                {type = "set_property", path = "PlayerGui.HubGui.SpeedSlider.Value", value = 2.5},
                {type = "fire_event", path = "PlayerGui.HubGui.StartButton", event = "Activated"},
                {type = "click_nth", gui = "HohoHub", index = 3},
                {type = "wait", seconds = 0.5},
                {type = "execute", code = "game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = 50"},
            }
        }
    ]]

    local actions = args.actions or {}
    if #actions == 0 then
        return { id = 0, ok = false, error = "no actions in plan" }
    end

    CurrentCmd = "apply_config"
    local results = {}
    local applied = 0
    local failed = 0

    -- Gather all GUIs for searching
    local allGuis: { Instance } = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then for _, c in ipairs(pg:GetChildren()) do if c:IsA("ScreenGui") then table.insert(allGuis, c) end end end
    pcall(function() for _, c in ipairs(game:GetService("CoreGui"):GetChildren()) do if c:IsA("ScreenGui") then table.insert(allGuis, c) end end end)
    pcall(function() if gethui then for _, c in ipairs(gethui():GetChildren()) do if c:IsA("ScreenGui") then table.insert(allGuis, c) end end end end)

    -- Helper: resolve an instance path like "PlayerGui.HubGui.Frame.Button"
    local function resolvePath(pathStr: string): Instance?
        local parts = pathStr:split(".")
        local current: Instance = game

        for _, part in ipairs(parts) do
            if part == "PlayerGui" then
                current = LocalPlayer:FindFirstChild("PlayerGui") or current
            elseif part == "CoreGui" then
                pcall(function() current = game:GetService("CoreGui") end)
            else
                local child = current:FindFirstChild(part)
                if not child then
                    -- Try recursive search
                    child = current:FindFirstChild(part, true)
                end
                if not child then return nil end
                current = child
            end
        end

        return current
    end

    for i, action in ipairs(actions) do
        local actionType = action.type or ""
        local actionResult: { [string]: any } = { index = i, type = actionType, ok = false }

        if actionType == "click" then
            -- Click a GUI element by text match
            local target = action.target or ""
            local retries = action.retries or 2

            for attempt = 1, retries do
                local clicked, detail = findAndClick(allGuis, target)
                if clicked then
                    actionResult.ok = true
                    actionResult.clicked = detail
                    log("Config: clicked " .. detail)
                    break
                end
                if attempt < retries then task.wait(0.3) end
            end

            if not actionResult.ok then
                actionResult.error = "not found: " .. target
            end

        elseif actionType == "click_path" then
            -- Click a specific instance by path
            local path = action.path or ""
            local obj = resolvePath(path)
            if obj then
                if clickElement(obj) then
                    actionResult.ok = true
                    actionResult.clicked = path
                    log("Config: clicked path " .. path)
                else
                    actionResult.error = "click failed on " .. path
                end
            else
                actionResult.error = "path not found: " .. path
            end

        elseif actionType == "click_nth" then
            -- Click the Nth interactive element in a specific GUI
            local guiName = action.gui or ""
            local index = action.index or 1
            local targetGui: Instance? = nil

            for _, gui in ipairs(allGuis) do
                if gui.Name:lower():find(guiName:lower()) then
                    targetGui = gui
                    break
                end
            end

            if targetGui then
                local count = 0
                for _, desc in ipairs(targetGui:GetDescendants()) do
                    if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then
                        count += 1
                        if count == index then
                            if clickElement(desc) then
                                actionResult.ok = true
                                actionResult.clicked = desc.Name .. " (#" .. index .. ")"
                                log("Config: clicked #" .. index .. " in " .. guiName)
                            end
                            break
                        end
                    end
                end
                if not actionResult.ok then
                    actionResult.error = "index " .. index .. " not found (total: " .. count .. ")"
                end
            else
                actionResult.error = "gui not found: " .. guiName
            end

        elseif actionType == "set_property" then
            -- Set a property on a specific instance
            local path = action.path or ""
            local prop = action.property or "Value"
            local value = action.value

            local obj = resolvePath(path)
            if obj then
                local ok = pcall(function()
                    (obj :: any)[prop] = value
                end)
                actionResult.ok = ok
                if ok then
                    log("Config: set " .. path .. "." .. prop .. " = " .. tostring(value))
                else
                    actionResult.error = "failed to set " .. prop .. " on " .. path
                end
            else
                actionResult.error = "path not found: " .. path
            end

        elseif actionType == "fire_event" then
            -- Fire an event on a specific instance
            local path = action.path or ""
            local eventName = action.event or "Activated"

            local obj = resolvePath(path)
            if obj then
                local ok = pcall(function()
                    (obj :: any)[eventName]:Fire()
                end)
                actionResult.ok = ok
                if ok then
                    log("Config: fired " .. eventName .. " on " .. path)
                else
                    actionResult.error = "failed to fire " .. eventName
                end
            else
                actionResult.error = "path not found: " .. path
            end

        elseif actionType == "wait" then
            -- Pause between actions
            local secs = action.seconds or 0.5
            task.wait(secs)
            actionResult.ok = true

        elseif actionType == "execute" then
            -- Run arbitrary Luau code
            local code = action.code or ""
            if #code > 0 then
                local execResult = executeCode(code, 0)
                actionResult.ok = execResult.ok
                actionResult.result = execResult.result
                if not execResult.ok then
                    actionResult.error = execResult.error
                end
                log("Config: executed code (" .. #code .. " chars)")
            else
                actionResult.error = "no code"
            end

        elseif actionType == "verify" then
            -- Check if a GUI element is in the expected state
            local target = action.target or ""
            local expectedState = action.expected or "on"

            for _, gui in ipairs(allGuis) do
                for _, desc in ipairs(gui:GetDescendants()) do
                    if (desc:IsA("TextButton") or desc:IsA("TextLabel")) and desc.Visible then
                        if cleanOptionKey(desc.Text or ""):find(cleanOptionKey(target)) then
                            local actualState = detectState(desc)
                            actionResult.ok = true
                            actionResult.actual = actualState
                            actionResult.matches = actualState == expectedState or actualState == "unknown"
                            break
                        end
                    end
                end
                if actionResult.ok then break end
            end

            if not actionResult.ok then
                actionResult.error = "element not found: " .. target
            end

        else
            actionResult.error = "unknown action type: " .. actionType
        end

        if actionResult.ok then
            applied += 1
        else
            failed += 1
        end

        table.insert(results, actionResult)
    end

    CurrentCmd = ""
    log("Config plan: " .. applied .. "/" .. #actions .. " actions applied")

    return { id = 0, ok = true, result = {
        total = #actions,
        applied = applied,
        failed = failed,
        actions = results,
    }}
end

-- ═══════════════════════════════════════════════════════════
-- Safety overrides
-- ═══════════════════════════════════════════════════════════

PersistentEnv._safety_drowning = true
PersistentEnv._safety_death = true

task.spawn(function()
    while true do
        pcall(function()
            if not Humanoid then return end
            if PersistentEnv._safety_drowning and Humanoid:GetState() == Enum.HumanoidStateType.Swimming then
                Humanoid.Jump = true
            end
            if PersistentEnv._safety_death and Humanoid.Health <= 0 then
                local pg = LocalPlayer:FindFirstChild("PlayerGui")
                if pg then
                    for _, d in ipairs(pg:GetDescendants()) do
                        if d:IsA("TextButton") and d.Visible and d.Text:lower():find("respawn") then
                            pcall(function() d.Activated:Fire() end)
                            pcall(function() d.MouseButton1Click:Fire() end)
                            break
                        end
                    end
                end
            end
        end)
        task.wait(1)
    end
end)

-- ═══════════════════════════════════════════════════════════
-- Main loop — state writer + command reader at 20Hz
-- ═══════════════════════════════════════════════════════════

clearFile(CMD_FILE)
writefile(RESULT_FILE, encode({ id = 0, ok = true, result = "bridge_ready" }))

log("=== DaBlox Bridge v" .. VERSION .. " ONLINE ===")
log("Player: " .. LocalPlayer.Name .. " | Server: " .. game.JobId)

-- Log available APIs
local apis = {}
for _, name in ipairs({"readfile","writefile","appendfile","delfile","makefolder","isfile","listfiles","loadstring","getgenv","fireproximityprompt","fireclickdetector","keypress","mouse1click","request","identifyexecutor"}) do
    pcall(function() if type(getfenv(0)[name]) == "function" then table.insert(apis, name) end end)
end
log("APIs: " .. table.concat(apis, ", "))
pcall(function() if identifyexecutor then local n, v = identifyexecutor(); log("Executor: " .. tostring(n) .. " " .. tostring(v)) end end)

task.spawn(function()
    while true do
        Tick += 1
        local cycleStart = tick()

        -- Entity + quest scans every 10 ticks (~0.5s)
        if Tick % 10 == 0 then pcall(scanEntities); pcall(scanQuest) end

        -- Module updates
        for _, mod in pairs(Modules) do
            if mod.update then pcall(mod.update, 0.05) end
        end

        -- Write state
        pcall(function() writefile(STATE_FILE, encode(buildState())) end)

        -- Read + process command
        pcall(function()
            local raw = readfile(CMD_FILE)
            if not raw or #raw < 5 then return end

            clearFile(CMD_FILE)

            local cmd = decode(raw)
            if not cmd or not cmd.cmd then return end

            local cmdType = cmd.cmd
            local cmdId = cmd.id or 0
            local args = cmd.args or {}
            local result: CommandResult

            CurrentCmd = cmdType

            -- Check modules first
            local handled = false
            for _, mod in pairs(Modules) do
                if mod.onCommand then
                    local r = mod.onCommand(cmdType, args)
                    if r then r.id = cmdId; result = r; handled = true; break end
                end
            end

            -- Built-in commands
            if not handled and Builtins[cmdType] then
                result = Builtins[cmdType](args)
                result.id = cmdId
            -- Remote code execution
            elseif not handled and (cmdType == "execute" or cmdType == "exec") then
                result = executeCode(cmd.code or (args :: any).code or "", cmdId)
            else
                if not handled then result = { id = cmdId, ok = false, error = "unknown: " .. cmdType } end
            end

            CurrentCmd = ""
            writefile(RESULT_FILE, encode(result))
        end)

        -- Maintain 50ms cycle
        local elapsed = tick() - cycleStart
        local sleepTime = math.max(0.001, 0.05 - elapsed)
        task.wait(sleepTime)
    end
end)
