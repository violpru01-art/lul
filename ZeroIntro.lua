--[[
    ZERO // 零  —  cinematic katana intro & loading screen

    Standalone script. It does not depend on the main script and does not
    touch it. Run it as-is to play the intro, or integrate it later:

        local intro = loadstring(source)({      -- any CONFIG field can be overridden
            LoadDuration = 6,
            AutoProgress = false,               -- drive the bar yourself
            OnFinished   = function(completed) end,
        })
        intro.SetProgress(0.4)   -- 0..1, manual mode only
        intro.Skip()             -- rush to the finale
        intro.Wait()             -- yields until the screen is gone
        intro.Destroy()          -- abort immediately

    Stages:
        fade in -> photo -> title -> katana strike (half way) -> loading
        -> final thrust at 100% -> blood floods the screen -> fade out

    The katana and all blood are drawn from four PNG textures (the assets/
    folder next to this script). An executor downloads them once, keeps them
    in its workspace and reuses them on later runs; the script yields while
    that happens. See CONFIG.Textures to host them elsewhere or to use images
    uploaded to Roblox. Without textures the intro still runs, with simple
    shapes instead.
]]

local OVERRIDES = ...

----------------------------------------------------------------------
-- 1. SETTINGS
----------------------------------------------------------------------
local CONFIG = {
    -- Content
    Title         = "ZERO",
    Subtitle      = "ゼ ロ",
    Kanji         = "零",                       -- watermark + seal
    SideTextLeft  = "零式起動",
    SideTextRight = "読込中",
    Photo         = "rbxassetid://133651902906896",
    PhotoTint     = Color3.fromRGB(232, 220, 220),
    PhotoSize     = 196,                        -- px at the 1480x832 reference
    PhotoCorner   = 1,                          -- 1 = circle, 0.08 = rounded square
    Steps         = { "Initializing core", "Loading visuals", "Loading auras", "Preparing combat", "Securing session", "Finalizing" },

    -- Flow
    Speed         = 1,                          -- global time scale for the whole intro
    LoadDuration  = 7,                          -- seconds from 0% to 100% (AutoProgress)
    AutoProgress  = true,                       -- false: call intro.SetProgress(0..1)
    CanSkip       = true,
    OnFinished    = nil,                        -- function(completed: boolean)
    OnProgress    = nil,                        -- function(progress 0..1), fired once per percent

    -- Layout (reference pixels, scaled to the viewport)
    TitleSize     = 150,
    TitleSpacing  = 18,
    BarWidth      = 460,

    -- Stage durations in seconds (before Speed is applied)
    Timings = {
        FadeIn       = 0.9,   -- black -> scene
        PhotoReveal  = 1.0,
        TitleStagger = 0.13,  -- delay between letters slamming in
        TitleSlam    = 0.24,
        PreStrike    = 0.75,  -- stillness before the katana appears
        KatanaFlight = 0.42,
        PostStrike   = 0.9,   -- pause after the strike before loading starts
        FinalHold    = 0.5,   -- pause at 100% before the final thrust
        FinalWindup  = 0.28,
        FinalThrust  = 0.11,
        BloodCover   = 1.6,   -- time for blood to flood the whole screen
        EndHold      = 0.4,
        FadeToBlack  = 0.7,
        FadeOut      = 0.8,
    },

    Katana = {
        FromSide     = "Right",  -- "Right" or "Left"
        BladeLength  = 600,      -- grows automatically when the title is wider
        BladeWidth   = 15,
        HandleLength = 132,
        Curve        = 3.2,      -- blade curvature in degrees
        HeightOffset = -0.12,    -- where the blade crosses the letters (fraction of cap height, 0 = middle)
        FlightTilt   = 13,       -- degrees of tilt at the start of the flight
        FlightRise   = 96,       -- how far above the title the flight starts
        Quiver       = 2.4,      -- degrees of vibration after the strike
        Windup       = 20,       -- px pulled back before the final thrust
    },

    Blood = {
        SplashCount      = 38,   -- droplets thrown by the first strike
        FinalSplashCount = 90,
        ImpactStains     = 4,    -- blots that land on the "lens" at the strike
        MaxStains        = 9,    -- lens blots in total while loading
        FinalStains      = 6,
        MaxDrips         = 11,   -- drips running down the letters
        DripSpeed        = { 7, 16 },
        CoverBlots       = 15,   -- big blots that flood the screen at the end
        CoverColumns     = 15,   -- (shape fallback only)
        CoverBlobs       = 8,    -- (shape fallback only)
        PoolSize         = 130,  -- pooled flying droplets
    },

    Atmosphere = {
        Particles     = 28,
        FlashInterval = { 2.8, 5.5 },
        Heartbeat     = true,
        Letterbox     = 0.075,   -- bar height as a fraction of the screen
    },

    Shake = 1,                   -- camera shake multiplier (0 disables)

    -- Optional sound ids ("rbxassetid://..."); empty = silent
    Sounds = { Thud = "", Whoosh = "", Impact = "", Final = "", Volume = 0.6 },

    -- Katana and blood textures
    Textures = {
        Enabled = true,          -- false: always use the simple shapes
        BaseUrl = "https://raw.githubusercontent.com/violpru01-art/lul/HEAD/assets/",
        Folder  = "ZeroIntro",   -- cache folder inside the executor workspace
        Version = 1,             -- change after replacing the files to force a new download
        Timeout = 10,            -- seconds to wait for downloads before falling back to shapes
        Files   = { Katana = "zero_katana.png", BlotsA = "zero_blots_a.png", BlotsB = "zero_blots_b.png", BloodFx = "zero_blood_fx.png" },
        -- Images uploaded to Roblox take priority over downloads, e.g. Ids = { Katana = "rbxassetid://123" }
        Ids     = {},
    },

    Colors = {
        BgTop       = Color3.fromRGB(13, 5, 7),
        BgMid       = Color3.fromRGB(5, 3, 4),
        BgBottom    = Color3.fromRGB(22, 4, 8),
        Fog         = Color3.fromRGB(120, 10, 20),
        Bone        = Color3.fromRGB(236, 228, 220),
        Ash         = Color3.fromRGB(150, 140, 138),
        Blood       = Color3.fromRGB(134, 10, 18),
        BloodBright = Color3.fromRGB(196, 26, 34),
        BloodDark   = Color3.fromRGB(64, 3, 8),
        Ember       = Color3.fromRGB(255, 96, 54),
        FaceTop     = Color3.fromRGB(244, 238, 232),
        FaceMid     = Color3.fromRGB(205, 196, 192),
        FaceLow     = Color3.fromRGB(118, 102, 102),
        Steel       = Color3.fromRGB(30, 30, 38),
        SteelDark   = Color3.fromRGB(15, 15, 19),
        SteelRidge  = Color3.fromRGB(74, 74, 88),
        SteelHi     = Color3.fromRGB(96, 96, 112),
        Hamon       = Color3.fromRGB(112, 114, 130),
        Edge        = Color3.fromRGB(208, 210, 224),
        Brass       = Color3.fromRGB(88, 66, 36),
        BrassHi     = Color3.fromRGB(150, 118, 62),
        Track       = Color3.fromRGB(24, 8, 10),
    },

    Fonts = {
        Title  = Enum.Font.GothamBlack,
        Ui     = Enum.Font.GothamMedium,
        UiBold = Enum.Font.GothamBold,
        Kanji  = Enum.Font.GothamBold,
    },
}

local function merge(dst, src)
    for k, v in pairs(src) do
        if typeof(v) == "table" and typeof(dst[k]) == "table" and #v == 0 then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end
if typeof(OVERRIDES) == "table" then merge(CONFIG, OVERRIDES) end

----------------------------------------------------------------------
-- 2. SERVICES & CONSTANTS
----------------------------------------------------------------------
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local TextService  = game:GetService("TextService")

if not game:IsLoaded() then game.Loaded:Wait() end
local LP = Players.LocalPlayer
while not LP do
    task.wait()
    LP = Players.LocalPlayer
end

local SPEED = math.max(CONFIG.Speed, 0.05)
local T, KAT, BLOOD, ATMOS, COL, FONT = CONFIG.Timings, CONFIG.Katana, CONFIG.Blood, CONFIG.Atmosphere, CONFIG.Colors, CONFIG.Fonts
local ES, ED = Enum.EasingStyle, Enum.EasingDirection

local GUI_NAME     = "ZeroIntro"
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
local CENTER       = Vector2.new(0.5, 0.5)
local TAU          = math.pi * 2
local REF_W, REF_H = 1480, 832
local CX, CY       = REF_W / 2, REF_H / 2

local FROM_RIGHT = KAT.FromSide ~= "Left"
local SX         = FROM_RIGHT and 1 or -1      -- side the katana comes from

-- Vertical layout, relative to the screen centre
local PHOTO_Y = -214
local TITLE_Y = 34
local CAP_H   = CONFIG.TitleSize * 0.72
local BLADE_Y = TITLE_Y + KAT.HeightOffset * CAP_H
local BAR_Y   = 232

local SHADES = { COL.Blood, COL.BloodBright:Lerp(COL.Blood, 0.55), COL.Blood:Lerp(COL.BloodDark, 0.45), COL.Blood:Lerp(BLACK, 0.2) }
local CANCELLED = {}

local rng = Random.new()
local clamp = math.clamp
local function rand(a, b) return rng:NextNumber(a, b) end
local function pick(list) return list[rng:NextInteger(1, #list)] end
local function lerp(a, b, t) return a + (b - a) * t end

local ease = {
    outCubic = function(a) return 1 - (1 - a) ^ 3 end,
    inCubic  = function(a) return a * a * a end,
    outQuint = function(a) return 1 - (1 - a) ^ 5 end,
    outExpo  = function(a) return (a >= 1) and 1 or (1 - 2 ^ (-10 * a)) end,
    inOut    = function(a) return a * a * (3 - 2 * a) end,
    outBack  = function(a) local c = 1.9; return 1 + (c + 1) * (a - 1) ^ 3 + c * (a - 1) ^ 2 end,
}

----------------------------------------------------------------------
-- 3. INSTANCE HELPERS
----------------------------------------------------------------------
local function make(class, props)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        if k ~= "Parent" then o[k] = v end
    end
    if props.Parent then o.Parent = props.Parent end
    return o
end

-- Borderless Frame; invisible unless a colour or transparency is given.
local function frame(props)
    props.BorderSizePixel = 0
    if props.BackgroundColor3 == nil and props.BackgroundTransparency == nil then
        props.BackgroundTransparency = 1
    end
    return make("Frame", props)
end

local function label(props)
    props.BackgroundTransparency = 1
    props.BorderSizePixel = 0
    props.Font = props.Font or FONT.Ui
    props.TextColor3 = props.TextColor3 or COL.Bone
    return make("TextLabel", props)
end

local function corner(o, scale, px)
    make("UICorner", { CornerRadius = UDim.new(scale or 1, px or 0), Parent = o })
    return o
end

-- nseq({ t0, v0, t1, v1, ... }) / cseq({ t0, c0, t1, c1, ... })
local function nseq(list)
    local kp = {}
    for i = 1, #list, 2 do kp[#kp + 1] = NumberSequenceKeypoint.new(list[i], list[i + 1]) end
    return NumberSequence.new(kp)
end
local function cseq(list)
    local kp = {}
    for i = 1, #list, 2 do kp[#kp + 1] = ColorSequenceKeypoint.new(list[i], list[i + 1]) end
    return ColorSequence.new(kp)
end

-- Gradient colours multiply the object's own colour: keep that white when passing `colors`.
local function gradient(o, rotation, colors, transparency)
    local props = { Rotation = rotation or 0, Parent = o }
    if colors then props.Color = colors end
    if transparency then props.Transparency = transparency end
    return make("UIGradient", props)
end

local function tween(o, t, props, style, dir, delay)
    local info = TweenInfo.new(t / SPEED, style or ES.Quint, dir or ED.Out, 0, false, (delay or 0) / SPEED)
    local tw = TweenService:Create(o, info, props)
    tw:Play()
    return tw
end

local function loopTween(o, t, props, style, reverses)
    local tw = TweenService:Create(o, TweenInfo.new(t / SPEED, style or ES.Linear, ED.InOut, -1, reverses or false), props)
    tw:Play()
    return tw
end

local function spaced(s)
    return ((s:gsub(".", "%0 ")):sub(1, -2))
end

local function vertical(s)
    local out = {}
    for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(cp) end
    return table.concat(out, "\n"), #out
end

----------------------------------------------------------------------
-- 4. ROOT GUI & LIFECYCLE
----------------------------------------------------------------------
local function pickParent()
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then return h end
    local ok2, cg = pcall(function()
        local c = game:GetService("CoreGui")
        local f = Instance.new("Folder")
        f.Parent = c
        f:Destroy()
        return c
    end)
    if ok2 and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end

local guiParent = pickParent()
pcall(function()
    for _, p in ipairs({ guiParent, LP:FindFirstChildOfClass("PlayerGui") }) do
        local old = p:FindFirstChild(GUI_NAME)
        if old then old:Destroy() end
    end
end)

local gui = make("ScreenGui", {
    Name = GUI_NAME, IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 1000000,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = guiParent,
})

-- Shared runtime state
local S = {
    alive = true, completed = false, phase = "boot", rush = false,
    clock = 0, hitStop = 0, trauma = 0, shaking = false,
    light = 0, beat = 0, beatPhase = 0, glowBase = 0, lightKey = -1,
    target = 0, shown = 0, loadT = 0, pctShown = -1, stepShown = 0,
    katRot = 0, struck = false, thrust = false,
}
local conns, waiters = {}, {}
local ui = {}

local function cleanup()
    if not S.alive then return end
    S.alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
    pcall(function() getgenv().ZeroIntroDone = true end)
    if CONFIG.OnFinished then
        task.spawn(function()
            local ok, err = pcall(CONFIG.OnFinished, S.completed)
            if not ok then warn("[ZeroIntro] OnFinished: " .. tostring(err)) end
        end)
    end
    for _, th in ipairs(waiters) do task.spawn(th) end
end

-- Viewport metrics: scale `s` maps reference pixels to screen pixels.
local view = { w = REF_W, h = REF_H, s = 1, halfW = CX, halfH = CY }
local function layer(z, name)
    return frame({ Name = name, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = gui })
end

-- Black curtain first: it hides everything while textures load and the scene is built.
ui.fade = frame({ Name = "Fade", Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BackgroundTransparency = 1, ZIndex = 13, Parent = gui })
tween(ui.fade, 0.35, { BackgroundTransparency = 0 }, ES.Quad)

----------------------------------------------------------------------
-- 5. TEXTURES (katana + blood; downloaded once, then read from the cache)
----------------------------------------------------------------------
local TEX = {}
do
    local cfg = CONFIG.Textures
    local toAsset = getcustomasset or getsynasset
    local canCache = toAsset ~= nil and writefile ~= nil and isfile ~= nil

    local function httpGet(url)
        local ok, body = pcall(function() return game:HttpGet(url) end)
        if ok and typeof(body) == "string" then return body end
        local send = request or http_request or (syn and syn.request)
        if send then
            local res = send({ Url = url, Method = "GET" })
            if typeof(res) == "table" and res.StatusCode == 200 then return res.Body end
        end
        return nil
    end

    local function resolve(key, file)
        local id = cfg.Ids[key]
        if typeof(id) == "string" and id ~= "" then return id end      -- image uploaded to Roblox
        if not canCache then return nil end
        local path = cfg.Folder .. "/v" .. tostring(cfg.Version) .. "_" .. file
        if not isfile(path) then
            if makefolder then pcall(makefolder, cfg.Folder) end
            local data = httpGet(cfg.BaseUrl .. file)
            -- an error page must never end up in the cache as a "texture"
            if typeof(data) ~= "string" or #data < 1024 or data:sub(2, 4) ~= "PNG" then return nil end
            writefile(path, data)
        end
        return toAsset(path)
    end

    if cfg.Enabled then
        local found, pending, open = {}, 0, true
        for key, file in pairs(cfg.Files) do
            pending += 1
            task.spawn(function()
                local ok, asset = pcall(resolve, key, file)
                if open and ok and typeof(asset) == "string" and asset ~= "" then found[key] = asset end
                pending -= 1
            end)
        end
        -- a pulsing kanji shows the script is alive if the first download is slow
        local started, deadline = os.clock(), os.clock() + cfg.Timeout
        local sign
        while pending > 0 and os.clock() < deadline do
            if not sign and os.clock() - started > 0.6 then
                sign = label({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(80, 80), Text = CONFIG.Kanji, TextSize = 44, Font = FONT.Kanji, TextColor3 = COL.Blood, TextTransparency = 1, Parent = ui.fade })
                loopTween(sign, 0.9, { TextTransparency = 0.25 }, ES.Sine, true)
            end
            task.wait()
        end
        open = false                                       -- a late download only fills the cache for next time
        if sign then sign:Destroy() end
        for key, asset in pairs(found) do TEX[key] = asset end

        local list = {}
        for _, asset in pairs(TEX) do list[#list + 1] = asset end
        if #list > 0 then                                  -- decode before the first frame that shows them
            local done = false
            task.spawn(function()
                pcall(function() game:GetService("ContentProvider"):PreloadAsync(list) end)
                done = true
            end)
            local limit = os.clock() + 3
            while not done and os.clock() < limit do task.wait() end
        end
        if #list < 4 then warn("[ZeroIntro] textures unavailable (" .. #list .. "/4 loaded), missing parts use simple shapes") end
    end
end
local HAS_KATANA = TEX.Katana ~= nil
local HAS_BLOOD = TEX.BlotsA ~= nil and TEX.BlotsB ~= nil and TEX.BloodFx ~= nil

-- Sprite rectangles inside the atlases: { texture, x, y, width, height } (see tools/gen_blood.py).
local ATLAS = {
    blots  = {},                                   -- 8 impact blots, 512 px cells
    spray  = { "BloodFx", 0, 0, 512, 512 },        -- droplets thrown all around a point
    cone   = { "BloodFx", 512, 0, 512, 512 },      -- droplets flying along +X from the left edge
    streak = { "BloodFx", 256, 512, 256, 128 },    -- one flying drop, head on the right
    bleed  = { "BloodFx", 512, 512, 512, 512 },    -- soft soaking blot
    blade  = { "Katana", 0, 0, 1024, 128 },
    coat   = { "Katana", 0, 128, 1024, 128 },      -- blood lying on the blade
    hilt   = { "Katana", 0, 256, 512, 256 },
}
for i = 0, 7 do
    ATLAS.blots[i + 1] = { (i < 4) and "BlotsA" or "BlotsB", (i % 2) * 512, (math.floor(i / 2) % 2) * 512, 512, 512 }
end
local DRIP_TRAIL, DRIP_BEAD = 384, 128             -- a drip column: 64 px wide, trail rows then the hanging bead

local function sprite(def, props)
    props.BackgroundTransparency = 1
    props.BorderSizePixel = 0
    props.Image = TEX[def[1]]
    props.ImageRectOffset = Vector2.new(def[2], def[3])
    props.ImageRectSize = Vector2.new(def[4], def[5])
    return make("ImageLabel", props)
end

----------------------------------------------------------------------
-- 5. SCHEDULER (scene clock: honours Speed, hit-stop and cleanup)
----------------------------------------------------------------------
local tracks, timers = {}, {}

-- Calls fn(alpha 0..1) every frame for `duration` seconds.
local function animate(duration, fn, easing, onDone)
    tracks[#tracks + 1] = { t = 0, d = math.max(duration, 0.001), fn = fn, ease = easing, done = onDone }
    fn(0)
end

local function after(delay, fn)
    timers[#timers + 1] = { at = S.clock + delay, fn = fn }
end

local function sleep(t)
    local target = S.clock + (S.rush and S.phase ~= "finale" and t * 0.3 or t)
    while S.alive and S.clock < target do RunService.RenderStepped:Wait() end
    if not S.alive then error(CANCELLED) end
end

local function waitFor(cond)
    while S.alive and not cond() do RunService.RenderStepped:Wait() end
    if not S.alive then error(CANCELLED) end
end

local function sound(id, volume, pitch)
    if not id or id == "" then return end
    pcall(function()
        local s = make("Sound", { SoundId = id, Volume = (volume or 1) * CONFIG.Sounds.Volume, PlaybackSpeed = pitch or 1, Parent = gui })
        game:GetService("SoundService"):PlayLocalSound(s)
        task.delay(8, function() s:Destroy() end)
    end)
end

----------------------------------------------------------------------
-- 6. SCENE: BACKGROUND, STAGE, OVERLAYS
----------------------------------------------------------------------
do
    local bg = layer(1, "Background")
    bg.Visible = false
    ui.bg = bg
    local base = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = bg })
    gradient(base, 90, cseq({ 0, COL.BgTop, 0.5, COL.BgMid, 1, COL.BgBottom }))

    ui.kanji = label({
        AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.54), Size = UDim2.fromScale(0.9, 0.86),
        Text = CONFIG.Kanji, TextScaled = true, Font = FONT.Kanji, TextColor3 = COL.Blood,
        TextTransparency = 1, ZIndex = 2, Parent = bg,
    })

    -- Slow drifting fog bands
    ui.fog = {}
    for i = 1, 3 do
        local f = frame({
            AnchorPoint = CENTER, Position = UDim2.fromScale(0.42 + i * 0.04, 0.2 + i * 0.2), Size = UDim2.fromScale(1.8, 0.2 + 0.05 * i),
            BackgroundColor3 = COL.Fog, BackgroundTransparency = 1, ZIndex = 3, Parent = bg,
        })
        gradient(f, 90, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))
        loopTween(f, 13 + i * 5, { Position = UDim2.fromScale(0.58 - i * 0.04, 0.22 + i * 0.2) }, ES.Sine, true)
        ui.fog[i] = { f, 0.84 + 0.02 * i }
    end
end

ui.dustFar = layer(2, "DustFar")

local stage = frame({ Name = "Stage", AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(REF_W, REF_H), ZIndex = 5, Visible = false, Parent = gui })
local stageScale = make("UIScale", { Scale = 1, Parent = stage })

-- Stage position from coordinates relative to the screen centre.
local function P(x, y)
    return UDim2.fromOffset(CX + x, CY + y)
end

local function rescale()
    local size = gui.AbsoluteSize
    if size.X < 10 or size.Y < 10 then
        local cam = workspace.CurrentCamera
        size = cam and cam.ViewportSize or Vector2.new(REF_W, REF_H)
    end
    view.w, view.h = size.X, size.Y
    view.s = clamp(math.min(size.X / REF_W, size.Y / REF_H), 0.3, 3)
    view.halfW, view.halfH = size.X / view.s / 2, size.Y / view.s / 2
    stageScale.Scale = view.s
end
rescale()
table.insert(conns, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale))

ui.dustNear = layer(6, "DustNear")
ui.lens     = layer(7, "Lens")       -- blood on the "camera"
ui.cover    = layer(10, "Cover")     -- final blood curtain

do
    -- Vignette + red edge glow (driven by lighting)
    local vig = layer(8, "Vignette")
    vig.Visible = false
    ui.vignette = vig
    ui.redEdges = {}
    local function edge(anchor, pos, size, rot, color, peak, z)
        local f = frame({ AnchorPoint = anchor, Position = pos, Size = size, BackgroundColor3 = color, BackgroundTransparency = 0, ZIndex = z, Parent = vig })
        gradient(f, rot, nil, nseq({ 0, 1 - peak, 1, 1 }))
        return f
    end
    edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.34), 90, BLACK, 0.85, 2)
    edge(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.34), 270, BLACK, 0.9, 2)
    edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.28, 1), 0, BLACK, 0.8, 2)
    edge(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.28, 1), 180, BLACK, 0.8, 2)
    for _, e in ipairs({
        edge(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.22, 1), 0, COL.Blood, 0.7, 1),
        edge(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.22, 1), 180, COL.Blood, 0.7, 1),
        edge(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.3), 270, COL.Blood, 0.6, 1),
    }) do
        e.BackgroundTransparency = 1
        table.insert(ui.redEdges, e)
    end

    -- Wide red light band that occasionally passes across the screen
    ui.sweep = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(-0.4, 0.5), Size = UDim2.fromScale(0.5, 1.3), BackgroundColor3 = COL.BloodBright, BackgroundTransparency = 1, Rotation = 12, ZIndex = 3, Parent = vig })
    gradient(ui.sweep, 0, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))

    -- Cinematic letterbox bars (taller than the visible band so they can "thump" inwards)
    local bars = layer(9, "Letterbox")
    local h = ATMOS.Letterbox
    local full = h + 0.06
    ui.barTop = frame({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, full), BackgroundColor3 = BLACK, Parent = bars })
    ui.barBottom = frame({ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, full), BackgroundColor3 = BLACK, Parent = bars })
    frame({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COL.Blood, BackgroundTransparency = 0.45, Parent = ui.barTop })
    frame({ Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COL.Blood, BackgroundTransparency = 0.45, Parent = ui.barBottom })
    local textY = 0.5 * h / full
    label({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 26, textY, 0), Size = UDim2.fromOffset(300, 14), Text = spaced(string.upper(CONFIG.Title)) .. "   //   " .. CONFIG.Kanji, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 0.6, Parent = ui.barBottom })
    ui.hint = label({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -26, textY, 0), Size = UDim2.fromOffset(300, 14), Text = spaced(game:GetService("UserInputService").TouchEnabled and "TAP TO SKIP" or "CLICK TO SKIP"), TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right, TextTransparency = 1, Parent = ui.barBottom })

    ui.flashRed   = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = COL.BloodBright, BackgroundTransparency = 1, ZIndex = 11, Parent = gui })
    ui.flashWhite = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 12, Parent = gui })
    ui.skip       = make("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 14, Parent = gui })
end

-- Stack of translucent discs: a cheap radial glow without image assets.
local function softGlow(parent, pos, diameter, color, z, layers)
    local g = { frames = {}, shown = -1 }
    for i = 1, layers do
        local d = diameter * i / layers
        g.frames[i] = corner(frame({ AnchorPoint = CENTER, Position = pos, Size = UDim2.fromOffset(d, d), BackgroundColor3 = color, BackgroundTransparency = 1, ZIndex = z, Parent = parent }))
    end
    function g.set(a)                            -- a = opacity at the core
        a = clamp(a, 0, 0.98)
        if math.abs(a - g.shown) < 0.004 then return end
        g.shown = a
        local per = 1 - (1 - a) ^ (1 / layers)
        for _, f in ipairs(g.frames) do f.BackgroundTransparency = 1 - per end
    end
    return g
end

----------------------------------------------------------------------
-- 7. SCENE: PHOTO
----------------------------------------------------------------------
do
    local d = CONFIG.PhotoSize
    local root = frame({ Name = "Photo", AnchorPoint = CENTER, Position = P(0, PHOTO_Y), Size = UDim2.fromOffset(d, d), ZIndex = 4, Parent = stage })
    local ph = { root = root, strokes = {} }
    ui.photo = ph
    ph.scale = make("UIScale", { Scale = 1.16, Parent = root })

    -- Blood moon behind the portrait, dissolving downwards
    ph.moon = corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.44), Size = UDim2.fromOffset(d * 1.9, d * 1.9), BackgroundColor3 = COL.Blood, BackgroundTransparency = 1, ZIndex = 1, Parent = root }))
    gradient(ph.moon, 90, nil, nseq({ 0, 0.05, 0.55, 0.45, 1, 1 }))
    ph.halo = softGlow(root, UDim2.fromScale(0.5, 0.5), d * 1.55, COL.BloodBright, 2, 7)

    local function ring(extra, thickness, target, period)
        local r = corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, extra, 1, extra), ZIndex = 5, Parent = root }), CONFIG.PhotoCorner)
        local s = make("UIStroke", { Color = COL.BloodBright, Thickness = thickness, Transparency = 1, Parent = r })
        if period then
            local g = gradient(s, 0, nil, nseq({ 0, 0, 0.3, 0.92, 0.7, 0.92, 1, 0 }))
            loopTween(g, math.abs(period), { Rotation = (period > 0) and 360 or -360 })
        end
        table.insert(ph.strokes, { s, target })
    end
    ring(2, 2, 0.25)
    ring(18, 1.6, 0.05, 9)
    ring(36, 1, 0.5, -15)

    ph.canvas = make("CanvasGroup", {
        AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = BLACK, BorderSizePixel = 0, GroupTransparency = 1, ZIndex = 4, Parent = root,
    })
    corner(ph.canvas, CONFIG.PhotoCorner)
    ph.img = make("ImageLabel", {
        AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
        Image = CONFIG.Photo, ImageColor3 = CONFIG.PhotoTint, ScaleType = Enum.ScaleType.Crop, Parent = ph.canvas,
    })
    -- Shade the bottom into the scene and add a travelling sheen
    local shade = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, ZIndex = 2, Parent = ph.canvas })
    gradient(shade, 90, cseq({ 0, COL.Blood, 1, Color3.fromRGB(6, 0, 2) }), nseq({ 0, 0.92, 0.45, 0.8, 1, 0.12 }))
    ph.sheen = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(-0.6, 0.5), Size = UDim2.fromScale(0.34, 2), BackgroundColor3 = WHITE, BackgroundTransparency = 0, Rotation = 22, ZIndex = 3, Parent = ph.canvas })
    gradient(ph.sheen, 0, nil, nseq({ 0, 1, 0.5, 0.74, 1, 1 }))

    -- Hanko seal
    local seal = corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.88, 0.9), Size = UDim2.fromOffset(30, 30), BackgroundColor3 = COL.Blood, BackgroundTransparency = 1, Rotation = -8, ZIndex = 7, Parent = root }), 0, 4)
    ph.seal = seal
    ph.sealScale = make("UIScale", { Scale = 2.4, Parent = seal })
    ph.sealText = label({ Size = UDim2.fromScale(1, 1), Text = CONFIG.Kanji, TextSize = 20, Font = FONT.Kanji, TextTransparency = 1, Parent = seal })
end

----------------------------------------------------------------------
-- 8. SCENE: TITLE (extruded letters split into depth layers so the
--    katana can sit between the letter bodies and their faces)
----------------------------------------------------------------------
local TITLE = { letters = {}, width = 0, active = false, live = false }
do
    ui.titleBack = frame({ Name = "TitleBack", Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = stage })
    ui.titleMid  = frame({ Name = "TitleMid", Size = UDim2.fromScale(1, 1), ZIndex = 14, Parent = stage })
    ui.titleFace = frame({ Name = "TitleFace", Size = UDim2.fromScale(1, 1), ZIndex = 16, Parent = stage })
    ui.titleFx   = frame({ Name = "TitleFx", Size = UDim2.fromScale(1, 1), ZIndex = 18, Parent = stage })

    local TS = CONFIG.TitleSize / 100            -- labels are built at TextSize 100 (Roblox max) and scaled
    TITLE.scale = TS
    local DEPTH, STEP = 9, 1.5
    local EX, EY = 0.48, 0.88                    -- extrusion direction

    -- UIGradient spans the whole label; these map the cap height into it
    local CAP_TOP, CAP_SPAN = 0.24, 0.52
    local bladeG = CAP_TOP + CAP_SPAN * (0.5 + KAT.HeightOffset)
    local function faceColors(s)                 -- s = how blood-soaked the lower half is
        return cseq({
            0, COL.FaceTop,
            clamp(bladeG - 0.03, 0.05, 0.6), COL.FaceMid,
            clamp(bladeG + 0.06, 0.1, 0.7), COL.FaceMid:Lerp(COL.FaceLow, 0.3):Lerp(COL.BloodBright, s),
            CAP_TOP + CAP_SPAN, COL.FaceLow:Lerp(COL.Blood, s),
            1, COL.FaceLow:Lerp(COL.BloodDark, s),
        })
    end

    local chars, widths, total = {}, {}, 0
    for _, cp in utf8.codes(CONFIG.Title) do
        local ch = utf8.char(cp)
        local ok, size = pcall(function() return TextService:GetTextSize(ch, 100, FONT.Title, Vector2.new(2000, 2000)) end)
        local w = ((ok and size.X > 0) and size.X or 72) * TS
        chars[#chars + 1], widths[#widths + 1] = ch, w
        total += w
    end
    total += CONFIG.TitleSpacing * math.max(#chars - 1, 0)
    TITLE.width = total

    local cursor = -total / 2
    for i, ch in ipairs(chars) do
        local w = widths[i]
        local L = { ch = ch, x = cursor + w / 2, w = w, ox = 0, oy = 0, vx = 0, vy = 0, stain = 0, stainGoal = 0, stainShown = 0, fades = {}, parts = {}, scales = {} }
        cursor += w + CONFIG.TitleSpacing

        local function part(parentLayer)
            local f = frame({ AnchorPoint = CENTER, Position = P(L.x, TITLE_Y), Size = UDim2.fromOffset(w / TS, 100), Parent = parentLayer })
            table.insert(L.parts, f)
            table.insert(L.scales, make("UIScale", { Scale = TS, Parent = f }))
            return f
        end
        local function glyph(parent, dx, dy, color, z, alpha)
            local l = make("TextLabel", {
                AnchorPoint = CENTER, Position = UDim2.new(0.5, dx / TS, 0.5, dy / TS), Size = UDim2.new(1, 80, 1, 40),
                BackgroundTransparency = 1, BorderSizePixel = 0, Font = FONT.Title, Text = ch, TextSize = 100,
                TextColor3 = color, TextTransparency = 1, ZIndex = z, Parent = parent,
            })
            table.insert(L.fades, { l, "TextTransparency", alpha or 0 })
            return l
        end

        local back, mid, face = part(ui.titleBack), part(ui.titleMid), part(ui.titleFace)

        -- Rim glow + soft contact shadow
        local glowLabel = glyph(back, 0, 0, COL.BloodDark, 1, 0)
        L.glow = make("UIStroke", { Color = COL.BloodBright, Thickness = 5, Transparency = 1, Parent = glowLabel })
        table.insert(L.fades, { L.glow, "Transparency", 0.78 })
        for k = 1, 3 do
            local off = DEPTH * STEP + 3 + k * 3.5
            glyph(back, EX * off, EY * off, BLACK, 2, 0.5 + k * 0.13)
        end
        -- Extrusion: far half behind the katana, near half in front of it
        for k = DEPTH, 1, -1 do
            local color = COL.Blood:Lerp(Color3.fromRGB(16, 2, 4), (k - 1) / (DEPTH - 1))
            local near = k <= DEPTH / 2
            glyph(near and mid or back, EX * k * STEP, EY * k * STEP, color, DEPTH - k + 3, 0)
        end
        -- Bevel highlight + face
        glyph(face, -0.9, -1.5, WHITE, 1, 0.35)
        local faceLabel = glyph(face, 0, 0, WHITE, 2, 0)
        L.faceGrad = gradient(faceLabel, 90, faceColors(0))
        local stroke = make("UIStroke", { Color = Color3.fromRGB(14, 2, 4), Thickness = 1.2, Transparency = 1, Parent = faceLabel })
        table.insert(L.fades, { stroke, "Transparency", 0.1 })

        -- Unscaled container for wounds / drips; moves with the letter
        L.fx = frame({ AnchorPoint = CENTER, Position = P(L.x, TITLE_Y), Size = UDim2.fromOffset(w, CONFIG.TitleSize), Parent = ui.titleFx })
        table.insert(L.parts, L.fx)

        function L.reveal(duration)
            for _, f in ipairs(L.fades) do tween(f[1], duration, { [f[2]] = f[3] }, ES.Quad) end
        end
        function L.setStain(s)
            L.stain, L.stainShown = s, s
            L.faceGrad.Color = faceColors(s)
        end
        TITLE.letters[i] = L
    end

    -- Subtitle with hairlines
    local subY = TITLE_Y + CAP_H / 2 + 46
    ui.sub = label({ AnchorPoint = CENTER, Position = P(0, subY), Size = UDim2.fromOffset(200, 20), Text = CONFIG.Subtitle, TextSize = 15, Font = FONT.Kanji, TextTransparency = 1, ZIndex = 8, Parent = stage })
    ui.subLines = {}
    for side = -1, 1, 2 do
        local line = frame({ AnchorPoint = Vector2.new((side < 0) and 1 or 0, 0.5), Position = P(side * 46, subY), Size = UDim2.fromOffset(0, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.2, ZIndex = 8, Parent = stage })
        gradient(line, (side < 0) and 180 or 0, cseq({ 0, COL.BloodBright, 1, COL.Blood }), nseq({ 0, 0, 1, 1 }))
        table.insert(ui.subLines, line)
    end

    -- Vertical kanji columns at the sides
    ui.side = {}
    local sideY = -150                           -- above the katana's path
    local sideX = math.min(640, view.halfW - 44)
    if sideX > total / 2 + 190 then
        for side = -1, 1, 2 do
            local text, n = vertical((side < 0) and CONFIG.SideTextLeft or CONFIG.SideTextRight)
            local h = n * 23
            local l = label({ AnchorPoint = CENTER, Position = P(side * sideX, sideY), Size = UDim2.fromOffset(30, h), Text = text, TextSize = 15, LineHeight = 1.3, Font = FONT.Kanji, TextTransparency = 1, ZIndex = 6, Parent = stage })
            table.insert(ui.side, { l, "TextTransparency", 0.5 })
            for dir = -1, 1, 2 do
                local line = frame({ AnchorPoint = Vector2.new(0.5, (dir < 0) and 1 or 0), Position = P(side * sideX, sideY + dir * (h / 2 + 12)), Size = UDim2.fromOffset(1, 70), BackgroundColor3 = COL.Blood, BackgroundTransparency = 1, ZIndex = 6, Parent = stage })
                gradient(line, (dir < 0) and 270 or 90, nil, nseq({ 0, 0, 1, 1 }))
                table.insert(ui.side, { line, "BackgroundTransparency", 0.25 })
            end
        end
    end
end

----------------------------------------------------------------------
-- 9. SCENE: KATANA (textured sprite; built from frames when the texture is missing)
----------------------------------------------------------------------
local KATANA = { overlays = {}, tipRows = {}, streaks = {}, tipX = 0, tassel = { a = 0, w = 0, b = 0, v = 0, goal = 0, live = false } }

-- Tassel: two-link pendulum hanging from the pommel
local function buildTassel(parent, position)
    local ts = KATANA.tassel
    ts.pivot = frame({ AnchorPoint = CENTER, Position = position, Size = UDim2.fromOffset(2, 2), ZIndex = 1, Parent = parent })
    local cord = frame({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(2, 26), BackgroundColor3 = COL.Blood, Parent = ts.pivot })
    ts.pivot2 = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(2, 2), Parent = cord })
    corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(7, 7), BackgroundColor3 = COL.BrassHi, ZIndex = 2, Parent = ts.pivot2 }))
    local tuft = corner(frame({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(7, 24), BackgroundColor3 = COL.BloodBright, Parent = ts.pivot2 }), 0, 2)
    gradient(tuft, 90, nil, nseq({ 0, 0, 0.6, 0.1, 1, 0.75 }))
end

-- Texture layout (tools/gen_katana.py): tip at (8, 34), spine y = 34 + 16 * (1 - u^2) with
-- u = (x - 512) / 504, blade 22..30 px wide, base at x = 1016; the hilt is a separate cell.
local function buildKatanaTextured()
    local bladeLen = math.max(KAT.BladeLength, TITLE.width + 80)
    local k = bladeLen / 1008                              -- texture pixels -> reference pixels
    local W, H = 1024 * k, 128 * k
    KATANA.bladeLen, KATANA.bladeH, KATANA.tipLen = bladeLen, 26 * k, 82 * k

    local root = frame({ Name = "Katana", AnchorPoint = CENTER, Position = P(0, 0), Size = UDim2.fromOffset(W, H), ZIndex = 12, Visible = false, Parent = stage })
    KATANA.root = root
    sprite(ATLAS.blade, { Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = root })
    local coat = sprite(ATLAS.coat, { Size = UDim2.fromOffset(0, H), ZIndex = 3, Visible = false, Parent = root })
    local hiltTilt = -math.deg(math.atan(32 / 504))        -- the handle continues the curve of the blade
    local hilt = sprite(ATLAS.hilt, { AnchorPoint = Vector2.new(16 / 512, 0.5), Position = UDim2.fromOffset(1016 * k, 49 * k), Size = UDim2.fromOffset(512 * k, 256 * k), Rotation = hiltTilt, ZIndex = 4, Parent = root })
    KATANA.hiltRot = hiltTilt
    buildTassel(hilt, UDim2.fromScale(431 / 512, 0.5 + 16 / 256))

    for i = 1, 3 do                                        -- motion streaks trailing behind the sword
        local len = bladeLen * 0.65 + 430 * k + 220 + i * 120
        local st = frame({ Position = UDim2.fromOffset(W * 0.35, 62 * k + (i - 2) * 7 - 2), Size = UDim2.fromOffset(len, (i == 2) and 3 or 1.5), BackgroundColor3 = (i == 2) and COL.Bone or COL.BloodBright, BackgroundTransparency = 1, ZIndex = 1, Parent = root })
        gradient(st, 0, nil, nseq({ 0, 1, 0.2, 0.15, 1, 1 }))
        KATANA.streaks[i] = st
    end

    local glint = frame({ AnchorPoint = CENTER, Size = UDim2.fromOffset(110, 22 * k), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 5, Parent = root })
    gradient(glint, 0, nil, nseq({ 0, 1, 0.5, 0.1, 1, 1 }))
    function KATANA.glint(duration)                        -- light sliding from the collar to the tip
        animate(duration, function(a)
            local x = 8 + 1008 * lerp(0.94, 0.14, a)
            local u = (x - 512) / 504
            glint.Position = UDim2.fromOffset(x * k, (34 + 16 * (1 - u * u) + 14) * k)
            glint.Rotation = -math.deg(32 * u / 504)
            glint.BackgroundTransparency = 1 - 0.5 * math.sin(a * math.pi)
        end)
    end

    -- From the left the sprite is turned upside down instead of mirrored (edge up, as a katana is worn).
    local baseRot = FROM_RIGHT and 0 or 180
    local vx, vy = SX * (W / 2 - 8 * k), SX * (H / 2 - 34 * k)
    local yBias = -SX * 14 * k                             -- the middle of the blade, not its tip, runs through the letters
    function KATANA.setPose(tipX, tipY, tilt, pivotDist)
        local rot = tilt * SX
        local r = math.rad(rot)
        local c, s = math.cos(r), math.sin(r)
        local tx = tipX + SX * pivotDist - SX * pivotDist * c
        local ty = tipY + yBias - SX * pivotDist * s
        root.Position = P(tx + vx * c - vy * s, ty + vx * s + vy * c)
        root.Rotation = rot + baseRot
        S.katRot = rot + baseRot
        KATANA.tipX = tipX
    end

    -- Lower outline of the blade, relative to BLADE_Y, `dist` behind the tip.
    function KATANA.lowerY(dist)
        local u = clamp((8 + dist / k - 512) / 504, -1, 1)
        local sag = 16 * (1 - u * u)
        return (FROM_RIGHT and (sag + 12) or (14 - sag)) * k
    end

    -- Coat the leading `fraction` of the blade in blood (cropping instead of clipping: clips break under rotation).
    local coated = 0
    function KATANA.setBlood(fraction)
        local from = coated
        coated = fraction
        coat.Visible = true
        animate(0.3, function(a)
            local f = lerp(from, fraction, a)
            coat.Size = UDim2.fromOffset(W * f, H)
            coat.ImageRectSize = Vector2.new(1024 * f, 128)
        end)
    end
end

local function buildKatanaShapes()
    local bladeLen  = math.max(KAT.BladeLength, TITLE.width + 80)
    local bladeH    = KAT.BladeWidth
    local tipLen    = bladeH * 3.1
    local pad       = 24
    local handleLen = KAT.HandleLength
    local hiltLen, hiltH = 38 + handleLen + 12, 64
    local W, H      = pad + bladeLen + hiltLen + pad, 96
    local y0        = H / 2
    local curve     = math.rad(KAT.Curve)
    local nSeg      = (KAT.Curve > 0.05) and 5 or 1
    local segLen    = bladeLen / nSeg
    KATANA.bladeLen, KATANA.bladeH, KATANA.tipLen = bladeLen, bladeH, tipLen

    local root = frame({ Name = "Katana", AnchorPoint = CENTER, Position = P(0, 0), Size = UDim2.fromOffset(W, H), ZIndex = 12, Visible = false, Parent = stage })
    KATANA.root = root

    -- Mirror helpers: the katana is authored pointing left and flipped for FromSide = "Left"
    local function mx(pw, x, w) return FROM_RIGHT and x or (pw - x - w) end
    local function mcx(pw, x) return FROM_RIGHT and x or (pw - x) end
    local function mrot(r) return FROM_RIGHT and r or -r end
    local function mgrad(r) return FROM_RIGHT and r or (180 - r) end
    local function slab(parent, pw, x, y, w, h, color, alpha, z)
        return frame({ Position = UDim2.fromOffset(mx(pw, x, w), y), Size = UDim2.fromOffset(w, h), BackgroundColor3 = color, BackgroundTransparency = alpha or 0, ZIndex = z or 1, Parent = parent })
    end

    -- Blade cross-section from spine (top) to cutting edge (bottom)
    local k = bladeH / 15
    local strips = {
        { 1.5 * k, COL.SteelHi }, { 4 * k, COL.SteelDark }, { 1 * k, COL.SteelRidge },
        { 4.5 * k, COL.Steel }, { 2.5 * k, COL.Hamon }, { 1.5 * k, COL.Edge },
    }
    local function colorAt(y)
        local acc = 0
        for _, s in ipairs(strips) do
            acc += s[1]
            if y < acc then return s[2] end
        end
        return strips[#strips][2]
    end

    -- Curved blade = short straight segments following an arc; tip and collar share one horizontal chord
    local px, py = pad, 0
    for i = 1, nSeg do
        local a = curve / 2 - curve * (i - 0.5) / nSeg
        local ca, sa = math.cos(a), math.sin(a)
        local len = segLen + 1.5
        local seg = frame({ AnchorPoint = CENTER, Position = UDim2.fromOffset(mcx(W, px + segLen / 2 * ca), y0 + py + segLen / 2 * sa), Size = UDim2.fromOffset(len, bladeH), Rotation = mrot(math.deg(a)), ZIndex = 2, Parent = root })
        local x0 = (i == 1) and tipLen or 0
        -- faint crimson aura so the black blade separates from the dark scene
        local aura = slab(seg, len, x0 * 0.6, -bladeH, len - x0 * 0.6, bladeH * 3, COL.BloodBright, 0.7, 1)
        gradient(aura, 90, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))
        local y = 0
        for _, s in ipairs(strips) do
            slab(seg, len, x0, y, len - x0, s[1] + 0.3, s[2], 0, 2)
            y += s[1]
        end
        if i == 1 then
            -- Kissaki: thin rows whose start follows the curve of the cutting edge
            local rows = math.max(6, math.floor(bladeH + 0.5))
            local rh = bladeH / rows
            for r = 0, rows - 1 do
                local xs = tipLen * ((r + 0.5) / rows) ^ 1.7
                local wRow = tipLen - xs + 0.6
                local c = colorAt((r + 0.5) * rh)
                local row = slab(seg, len, xs, r * rh, wRow, rh + 0.35, WHITE, 0, 2)
                local edgeAt = math.min(0.9, 2.2 / wRow)
                local g = gradient(row, mgrad(0), cseq({ 0, COL.Edge, edgeAt, c, 1, c }))
                table.insert(KATANA.tipRows, { g, c, edgeAt })
            end
        end
        local fx0 = (i == 1) and (tipLen + 26) or 0
        slab(seg, len, fx0, 2.6 * k, len - fx0, 1.6 * k, COL.Blood, 0.2, 3)    -- crimson fuller
        local ov = slab(seg, len, x0, 0, len - x0, bladeH, COL.Blood, 1, 4)    -- blood film
        gradient(ov, 90, nil, nseq({ 0, 0.6, 0.6, 0.25, 1, 0 }))
        KATANA.overlays[i] = ov
        px, py = px + segLen * ca, py + segLen * sa
    end

    -- Hilt: habaki, seppa, tsuba, wrapped tsuka, kashira
    local ah = -curve / 2
    local hilt = frame({ AnchorPoint = CENTER, Position = UDim2.fromOffset(mcx(W, px - 1 + hiltLen / 2 * math.cos(ah)), y0 + py + hiltLen / 2 * math.sin(ah)), Size = UDim2.fromOffset(hiltLen, hiltH), Rotation = mrot(math.deg(ah)), ZIndex = 3, Parent = root })
    KATANA.hiltRot = mrot(math.deg(ah))
    local mid = hiltH / 2
    local function hpart(x, w, h, color, z)
        return slab(hilt, hiltLen, x, mid - h / 2, w, h, color, 0, z)
    end
    hpart(0, 15, bladeH + 4, COL.Brass)
    hpart(2, 2, bladeH + 4, COL.BrassHi, 2)
    hpart(15, 2.5, 30, COL.BrassHi)
    local tsuba = corner(hpart(17.5, 9, 54, COL.SteelDark, 3), 0, 3)
    make("UIStroke", { Color = COL.Blood, Thickness = 1, Transparency = 0.3, Parent = tsuba })
    hpart(20, 1.5, 44, COL.SteelRidge, 4)
    hpart(26.5, 2.5, 30, COL.BrassHi)
    hpart(29, 9, 22, COL.Steel)
    hpart(38, handleLen, 19, COL.SteelDark)
    slab(hilt, hiltLen, 38, mid - 9.5, handleLen, 1.2, COL.SteelRidge, 0.2, 2)
    slab(hilt, hiltLen, 38, mid + 6.5, handleLen, 3, BLACK, 0.45, 2)
    local diamonds = math.max(1, math.floor(handleLen / 15))
    for d = 1, diamonds do
        frame({ AnchorPoint = CENTER, Position = UDim2.fromOffset(mcx(hiltLen, 38 + (d - 0.5) * handleLen / diamonds), mid), Size = UDim2.fromOffset(8, 8), Rotation = 45, BackgroundColor3 = COL.Blood, ZIndex = 3, Parent = hilt })
    end
    corner(hpart(38 + handleLen - 1, 13, 22, COL.Steel, 3), 0, 4)
    hpart(38 + handleLen + 2, 2, 22, COL.BloodBright, 4)

    buildTassel(hilt, UDim2.fromOffset(mcx(hiltLen, 38 + handleLen + 6), mid + 9))

    -- Motion streaks trailing behind the sword while it flies
    for i = 1, 3 do
        local len = bladeLen * 0.65 + hiltLen + 220 + i * 120
        local st = slab(root, W, pad + bladeLen * 0.35, y0 + (i - 2) * 7 - 2, len, (i == 2) and 3 or 1.5, (i == 2) and COL.Bone or COL.BloodBright, 1, 1)
        gradient(st, mgrad(0), nil, nseq({ 0, 1, 0.2, 0.15, 1, 1 }))
        KATANA.streaks[i] = st
    end

    -- Light glint that slides along the blade (u: 0 = tip, 1 = collar)
    local glint = frame({ AnchorPoint = CENTER, Size = UDim2.fromOffset(84, bladeH + 2), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 4, Parent = root })
    gradient(glint, mgrad(0), nil, nseq({ 0, 1, 0.5, 0.1, 1, 1 }))
    local sag = bladeLen / 2 * math.tan(curve / 4)
    function KATANA.glint(duration)
        animate(duration, function(a)
            local u = lerp(0.96, 0.12, a)
            glint.Position = UDim2.fromOffset(mcx(W, pad + bladeLen * u), y0 + sag * (1 - (2 * u - 1) ^ 2))
            glint.Rotation = mrot(math.deg(curve / 2 - curve * u))
            glint.BackgroundTransparency = 1 - 0.8 * math.sin(a * math.pi)
        end)
    end

    -- Pose: tip position, tilt in degrees (positive lifts the tip), rotating about a point `pivotDist` behind the tip.
    local vx, vy = SX * (W / 2 - pad), H / 2 - y0
    function KATANA.setPose(tipX, tipY, tilt, pivotDist)
        local rot = tilt * SX
        local r = math.rad(rot)
        local c, s = math.cos(r), math.sin(r)
        local tx = tipX + SX * pivotDist - SX * pivotDist * c
        local ty = tipY - SX * pivotDist * s
        root.Position = P(tx + vx * c - vy * s, ty + vx * s + vy * c)
        root.Rotation = rot
        S.katRot = rot
        KATANA.tipX = tipX
    end
    function KATANA.lowerY(_dist)
        return bladeH * 0.35
    end

    -- Coat the leading `fraction` of the blade in blood.
    function KATANA.setBlood(fraction)
        for _, row in ipairs(KATANA.tipRows) do
            local c = row[2]:Lerp(COL.Blood, 0.7)
            row[1].Color = cseq({ 0, COL.Edge:Lerp(COL.BloodBright, 0.6), row[3], c, 1, c })
        end
        for i, ov in ipairs(KATANA.overlays) do
            if (i - 0.5) / nSeg <= fraction then tween(ov, 0.25, { BackgroundTransparency = 0.2 }, ES.Quad) end
        end
    end
end

if HAS_KATANA then buildKatanaTextured() else buildKatanaShapes() end

function KATANA.setStreaks(a)
    for i, st in ipairs(KATANA.streaks) do st.BackgroundTransparency = 1 - a * ((i == 2) and 0.75 or 0.5) end
end

do  -- where the blade meets the title
    local n = #TITLE.letters
    local order = {}                             -- letters in the order the blade reaches them
    for i = 1, n do order[i] = TITLE.letters[FROM_RIGHT and (n - i + 1) or i] end
    KATANA.order = order
    local first, last = order[1], order[n]
    local half = math.ceil(n / 2)
    KATANA.pierced = half
    KATANA.entryX = first.x + SX * first.w * 0.44
    KATANA.exitX = last.x - SX * last.w * 0.44
    local nextL = order[half + 1]
    KATANA.halfTipX = nextL and (nextL.x + SX * nextL.w * 0.08) or (first.x - SX * first.w * 0.15)
    KATANA.fullTipX = KATANA.entryX + SX * (4 - KATANA.bladeLen)
end

----------------------------------------------------------------------
-- 10. SCENE: LOADING INDICATOR
----------------------------------------------------------------------
do
    local W = CONFIG.BarWidth
    local root = frame({ Name = "Progress", AnchorPoint = Vector2.new(0.5, 0), Position = P(0, BAR_Y), Size = UDim2.fromOffset(W, 84), ZIndex = 20, Parent = stage })
    local bar = { width = W, fades = {}, ticks = {} }
    ui.bar = bar
    local function fadeIn(o, prop, target) table.insert(bar.fades, { o, prop, target }) end

    bar.pct = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(160, 34), Text = "0%", TextSize = 30, Font = FONT.UiBold, TextTransparency = 1, Parent = root })
    bar.pctScale = make("UIScale", { Scale = 1, Parent = bar.pct })
    fadeIn(bar.pct, "TextTransparency", 0.04)
    local left = label({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromOffset(0, 32), Size = UDim2.fromOffset(120, 14), Text = CONFIG.SideTextRight, TextSize = 12, Font = FONT.Kanji, TextColor3 = COL.BloodBright, TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = root })
    fadeIn(left, "TextTransparency", 0.15)
    local right = label({ AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 0, 32), Size = UDim2.fromOffset(120, 14), Text = spaced("LOADING"), TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right, TextTransparency = 1, Parent = root })
    fadeIn(right, "TextTransparency", 0.5)
    bar.state = right

    local y, h = 46, 5
    bar.track = corner(frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, y), Size = UDim2.fromOffset(0, h), BackgroundColor3 = COL.Track, BackgroundTransparency = 1, Parent = root }))
    fadeIn(bar.track, "BackgroundTransparency", 0.1)
    local trackStroke = make("UIStroke", { Color = COL.Blood, Thickness = 1, Transparency = 1, Parent = bar.track })
    fadeIn(trackStroke, "Transparency", 0.45)

    -- The clip grows with progress; the fill inside keeps its full-width gradient
    bar.clip = frame({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(0, h), ClipsDescendants = true, ZIndex = 2, Parent = root })
    local fill = corner(frame({ Size = UDim2.fromOffset(W, h), BackgroundColor3 = WHITE, Parent = bar.clip }))
    gradient(fill, 0, cseq({ 0, COL.BloodDark, 0.65, COL.Blood, 1, COL.BloodBright }))
    local shimmer = frame({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(-80, 0), Size = UDim2.fromOffset(90, h), BackgroundColor3 = COL.Bone, BackgroundTransparency = 0.35, ZIndex = 2, Parent = bar.clip })
    gradient(shimmer, 0, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))
    loopTween(shimmer, 2.1, { Position = UDim2.fromOffset(W + 80, 0) }, ES.Sine)

    -- Glowing head of the fill
    bar.head = frame({ AnchorPoint = CENTER, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(2, 2), ZIndex = 3, Visible = false, Parent = root })
    bar.headGlow = softGlow(bar.head, UDim2.fromScale(0.5, 0.5), 38, COL.BloodBright, 1, 5)
    corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Color3.fromRGB(255, 120, 104), ZIndex = 2, Parent = bar.head }))
    corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = WHITE, ZIndex = 3, Parent = bar.head }))

    -- Diamond end caps and milestone ticks that light up when passed
    for side = 0, 1 do
        local dmd = frame({ AnchorPoint = CENTER, Position = UDim2.new(side, (side == 0) and -13 or 13, 0, y), Size = UDim2.fromOffset(6, 6), Rotation = 45, BackgroundColor3 = COL.Blood, BackgroundTransparency = 1, Parent = root })
        fadeIn(dmd, "BackgroundTransparency", 0.1)
    end
    for i = 0, 4 do
        local tick = frame({ AnchorPoint = CENTER, Position = UDim2.new(i / 4, 0, 0, y + 11), Size = UDim2.fromOffset(4, 4), Rotation = 45, BackgroundColor3 = COL.Ash, BackgroundTransparency = 1, Parent = root })
        fadeIn(tick, "BackgroundTransparency", 0.7)
        bar.ticks[i + 1] = { f = tick, at = i / 4, lit = false }
    end

    bar.step = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, y + 20), Size = UDim2.fromOffset(W, 14), Text = "", TextSize = 10, TextTransparency = 1, Parent = root })
end

-- In-stage effect layers (above the title)
ui.fx     = frame({ Name = "Fx", Size = UDim2.fromScale(1, 1), ZIndex = 22, Parent = stage })
ui.impact = frame({ Name = "Impact", Size = UDim2.fromScale(1, 1), ZIndex = 24, Parent = stage })

----------------------------------------------------------------------
-- 11. EFFECTS: pooled flying droplets / sparks
----------------------------------------------------------------------
local FX = { pool = {}, bloodPool = {}, live = {} }
for _ = 1, (HAS_BLOOD and 56 or BLOOD.PoolSize) do            -- plain frames: sparks, dust, embers
    FX.pool[#FX.pool + 1] = corner(frame({ AnchorPoint = CENTER, Size = UDim2.fromOffset(4, 4), BackgroundColor3 = COL.Blood, BackgroundTransparency = 0, Visible = false, Parent = ui.fx }))
end
if HAS_BLOOD then
    for _ = 1, BLOOD.PoolSize do                               -- textured drops of blood
        FX.bloodPool[#FX.bloodPool + 1] = sprite(ATLAS.streak, { AnchorPoint = CENTER, Size = UDim2.fromOffset(8, 4), Visible = false, Parent = ui.fx })
    end
end

-- Spawns a droplet at stage coordinates. o = { size, life, color, gravity, drag, stretch, alpha }; no color = blood.
function FX.emit(x, y, vx, vy, o)
    local textured = HAS_BLOOD and o.color == nil
    local f = table.remove(textured and FX.bloodPool or FX.pool)
    if not f then return end
    if not textured then f.BackgroundColor3 = o.color or pick(SHADES) end
    f.Visible = true
    FX.live[#FX.live + 1] = {
        f = f, textured = textured, x = x, y = y, vx = vx, vy = vy, t = 0,
        size = o.size or 4, life = o.life or 0.8, g = o.gravity or 900, drag = o.drag or 1,
        stretch = o.stretch or 0.01, alpha = o.alpha or 1,
    }
end

function FX.update(dt)
    local live = FX.live
    local limitX, limitY = view.halfW + 60, view.halfH + 40
    for i = #live, 1, -1 do
        local p = live[i]
        p.t += dt
        if p.t >= p.life or math.abs(p.x) > limitX or p.y > limitY then
            p.f.Visible = false
            local pool = p.textured and FX.bloodPool or FX.pool
            pool[#pool + 1] = p.f
            live[i] = live[#live]
            live[#live] = nil
        else
            local damp = math.max(0, 1 - p.drag * dt)
            p.vx *= damp
            p.vy = p.vy * damp + p.g * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            local k = p.t / p.life
            local speed = math.sqrt(p.vx * p.vx + p.vy * p.vy)
            local thick = p.size * (1 - 0.45 * k)
            local len = thick * (1 + speed * p.stretch)
            local fade = 1 - p.alpha * ((k > 0.7) and (1 - k) / 0.3 or 1)
            local f = p.f
            f.Position = P(p.x, p.y)
            f.Rotation = math.deg(math.atan2(p.vy, p.vx))
            if p.textured then                                 -- the drop fills ~43% of its sprite's height
                local h = thick * 2.3
                f.Size = UDim2.fromOffset(math.max(len * 1.25, h * 1.3), h)
                f.ImageTransparency = fade
            else
                f.Size = UDim2.fromOffset(len, thick)
                f.BackgroundTransparency = fade
            end
        end
    end
end

-- Fan of blood from a point. dir in radians, spread = half-angle of the cone.
function FX.spray(x, y, dir, spread, count, speedMin, speedMax, lift)
    for _ = 1, count do
        local a = dir + rand(-spread, spread)
        local v = rand(speedMin, speedMax)
        FX.emit(x + rand(-4, 4), y + rand(-4, 4), math.cos(a) * v, math.sin(a) * v - rand(0, lift or 0), {
            size = rand(2.4, 6.4), life = rand(0.45, 1.1), gravity = 950, drag = 1.3, stretch = 0.011,
        })
    end
end

function FX.sparks(x, y, dir, count)
    for _ = 1, count do
        local a = dir + rand(-1.3, 1.3)
        local v = rand(260, 1100)
        FX.emit(x, y, math.cos(a) * v, math.sin(a) * v, {
            size = rand(1.4, 2.6), life = rand(0.18, 0.5), gravity = 500, drag = 3, stretch = 0.02,
            color = pick({ WHITE, Color3.fromRGB(255, 214, 170), COL.Ember }),
        })
    end
end

-- Airborne spurt: a cone of droplets bursting from (x, y) along `angle` (radians), gone in a moment.
local function spurt(x, y, angle, size, life)
    if not HAS_BLOOD then return end
    local img = sprite(ATLAS.cone, { AnchorPoint = Vector2.new(0.08, 0.5), Position = P(x, y), Size = UDim2.fromOffset(size, size), Rotation = math.deg(angle), Parent = ui.fx })
    local sc = make("UIScale", { Scale = 0.25, Parent = img })
    tween(sc, life, { Scale = 1.15 }, ES.Quint)
    tween(img, life * 0.55, { ImageTransparency = 1 }, ES.Quad, ED.In, life * 0.45)
    after(life + 0.1, function() img:Destroy() end)
end

----------------------------------------------------------------------
-- 12. EFFECTS: blots on the lens, drips on the letters
----------------------------------------------------------------------
local STAINS = { count = 0 }
local DRIPS = { list = {}, count = 0 }
local WOUNDS = { Z = { 0.1, -0.06 }, E = { -0.3 }, R = { -0.3, 0.22 }, O = { -0.36, 0.36 } }   -- where the blade crosses each letter

-- Shape fallback for a blot: overlapping lobes + satellites thrown along `dir`.
local function stainShapes(xs, ys, radius, dir, runs)
    local r = radius * view.s * 0.55
    local root = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(xs, ys), Size = UDim2.fromOffset(2, 2), Parent = ui.lens })
    local sc = make("UIScale", { Scale = 0.25, Parent = root })
    local shade = pick(SHADES)
    local function blob(dx, dy, w, h, color, rot, alpha, z)
        return corner(frame({ AnchorPoint = CENTER, Position = UDim2.new(0.5, dx, 0.5, dy), Size = UDim2.fromOffset(w, h), BackgroundColor3 = color, BackgroundTransparency = alpha or 0.06, Rotation = rot or 0, ZIndex = z or 1, Parent = root }))
    end
    blob(0, 0, r * 1.5, r * 1.5, shade)
    for _ = 1, rng:NextInteger(3, 5) do                    -- irregular core
        local a, d = rand(0, TAU), r * rand(0.35, 0.8)
        local s = r * rand(0.6, 1.25)
        blob(math.cos(a) * d, math.sin(a) * d, s * rand(1, 1.35), s, shade, math.deg(a))
    end
    for _ = 1, rng:NextInteger(6, 10) do                   -- thrown droplets get smaller and longer with distance
        local a = dir + rand(-1, 1)
        local dist = r * rand(1.3, 4.2)
        local s = math.max(1.2, r * rand(0.08, 0.3) * (1.5 - dist / (r * 4.2)))
        blob(math.cos(a) * dist, math.sin(a) * dist, s * (1 + dist / (r * 1.8)), s, pick(SHADES), math.deg(a), 0.1)
    end
    for _ = 1, rng:NextInteger(4, 6) do                    -- fine mist
        local a, dist = rand(0, TAU), r * rand(1.2, 2.8)
        local s = rand(1, 2.2) * view.s
        blob(math.cos(a) * dist, math.sin(a) * dist, s, s, shade, 0, 0.25)
    end
    blob(-r * 0.3, -r * 0.36, r * 0.3, r * 0.18, Color3.fromRGB(226, 84, 78), -30, 0.68, 2)    -- wet highlight
    if runs then
        local w = math.max(2, r * rand(0.16, 0.26))
        local run = corner(frame({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, rand(-0.4, 0.4) * r, 0.5, 0), Size = UDim2.fromOffset(w, w), BackgroundColor3 = shade, BackgroundTransparency = 0.06, Parent = root }))
        tween(run, rand(4, 8), { Size = UDim2.fromOffset(w, r * rand(2.8, 6)) }, ES.Sine, ED.Out, 0.3)
    end
    tween(sc, 0.22, { Scale = 1 }, ES.Back)
end

-- A blot of blood landing on the lens at (xs, ys), in screen fractions. `radius` is the size of its pool in
-- reference pixels, `dir` the direction it was thrown in; `runs` lets a drip creep down from it.
function STAINS.add(xs, ys, radius, dir, runs)
    STAINS.count += 1
    if not HAS_BLOOD then
        stainShapes(xs, ys, radius, dir, runs)
        return
    end
    local size = radius * view.s * 4.8                     -- the pool fills ~40% of its cell
    local root = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(xs, ys), Size = UDim2.fromOffset(size, size), Parent = ui.lens })
    local sc = make("UIScale", { Scale = 0.3, Parent = root })
    local tone = rand(0.72, 1)
    local tint = Color3.new(tone, tone, tone)
    sprite(pick(ATLAS.blots), { AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Rotation = rand(-40, 40), ImageColor3 = tint, ImageTransparency = 0.03, ZIndex = 2, Parent = root })
    if rng:NextNumber() < 0.55 then                        -- droplets thrown on along the flight direction
        sprite(ATLAS.cone, { AnchorPoint = Vector2.new(0.08, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.5, 1.5), Rotation = math.deg(dir), ImageColor3 = tint, Parent = root })
    end
    tween(sc, 0.16, { Scale = 1 }, ES.Back)
    if runs then
        after(rand(0.5, 1.4), function()
            local w = math.max(2.4, radius * view.s * rand(0.13, 0.19))
            DRIPS.add(root, nil, size * rand(0.42, 0.58), size * 0.55, radius * view.s * rand(2.4, 5.5), 0, rand(0.3, 0.6), w)
        end)
    end
end

-- Random spot on the lens that keeps the photo, title and bar readable.
function STAINS.spot()
    local x = rand(0.04, 0.3)
    if rng:NextNumber() < 0.5 then x = 1 - x end
    return x, rand(0.14, 0.86)
end

function STAINS.burst(count, rMin, rMax, spreadTime, cx)
    for _ = 1, count do
        local x, y = STAINS.spot()
        after(rand(0.04, spreadTime), function()
            STAINS.add(x, y, rand(rMin, rMax), math.atan2(y - 0.5, x - (cx or 0.5)), rng:NextNumber() < 0.6)
        end)
    end
end

-- A drip runs down from (x, y) in `parent`, swells into a bead and sheds drops (`cycles` of them; 0 = it only
-- leaves a trail). `toStage(x, y)` converts parent coordinates to stage coordinates for the falling drop.
function DRIPS.add(parent, toStage, x, y, maxLen, cycles, speedScale, width)
    local w = width or rand(3, 5)
    local d = {
        toStage = toStage, x = x, y = y, w = w, len = 0, max = maxLen,
        speed = rand(BLOOD.DripSpeed[1], BLOOD.DripSpeed[2]) * (speedScale or 1),
        state = (maxLen > 0) and "run" or "swell", t = 0, dur = rand(0.8, 1.6), cycles = cycles, seed = rand(0, 100),
    }
    if HAS_BLOOD then
        -- The trail is revealed by cropping its sprite, the bead rides on the front.
        local column = rng:NextInteger(0, 3) * 64
        local k = w / 11                                   -- a trail is ~11 px wide inside its 64 px column
        d.max = math.min(maxLen, (DRIP_TRAIL - 8) * k)
        d.tip = 80 * k                                     -- bottom of the bead below the front
        local trail = sprite({ "BloodFx", column, 512, 64, 1 }, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(64 * k, 0), Parent = parent })
        local bead = sprite({ "BloodFx", column, 512 + DRIP_TRAIL, 64, DRIP_BEAD }, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(64 * k, DRIP_BEAD * k), Parent = parent })
        function d.setLen(len)
            trail.Size = UDim2.fromOffset(64 * k, len)
            trail.ImageRectSize = Vector2.new(64, math.max(len / k, 1))
            bead.Position = UDim2.fromOffset(x, y + len)
        end
        function d.setBead(a)                              -- 0 = resting, 1 = about to fall
            local s = 1 + 0.34 * a
            bead.Size = UDim2.fromOffset(64 * k * s, DRIP_BEAD * k * s)
        end
        function d.hideBead() bead.Visible = false end
    else
        local shade = pick(SHADES)
        d.color, d.tip = shade, w
        local trail = corner(frame({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 0), BackgroundColor3 = WHITE, Parent = parent }))
        gradient(trail, 90, cseq({ 0, COL.BloodDark, 1, shade }))
        local bead = corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w + 1, w + 1), BackgroundColor3 = shade, ZIndex = 2, Parent = parent }))
        corner(frame({ Position = UDim2.fromScale(0.22, 0.2), Size = UDim2.fromScale(0.3, 0.3), BackgroundColor3 = Color3.fromRGB(255, 150, 140), BackgroundTransparency = 0.4, Parent = bead }))
        function d.setLen(len)
            trail.Size = UDim2.fromOffset(w, len + w * 0.5)
            bead.Position = UDim2.fromOffset(x, y + len)
        end
        function d.setBead(a)
            local s = w + 1 + 3.2 * a
            bead.Size = UDim2.fromOffset(s, s * (1 + 0.3 * a))
        end
        function d.hideBead() bead.Visible = false end
    end
    d.setLen(0)
    d.setBead(0)
    DRIPS.list[#DRIPS.list + 1] = d
    return d
end

function DRIPS.update(dt)
    local list = DRIPS.list
    local function drop(i)
        list[i] = list[#list]
        list[#list] = nil
    end
    for i = #list, 1, -1 do
        local d = list[i]
        if d.state == "run" then
            -- stick-slip: blood creeps, hesitates, creeps again
            local v = d.speed * (0.35 + 1.3 * clamp(0.5 + math.noise(S.clock * 0.9, d.seed), 0, 1))
            d.len = math.min(d.max, d.len + v * dt)
            d.setLen(d.len)
            if d.len >= d.max then
                if d.cycles > 0 then d.state, d.t = "swell", 0 else drop(i) end
            end
        elseif d.state == "swell" then
            d.t += dt
            local a = math.min(d.t / d.dur, 1)
            d.setBead(a * a)
            if a >= 1 then
                local sx, sy = d.toStage(d.x, d.y + d.len + d.tip)
                FX.emit(sx, sy, 0, 40, { size = d.w + 1.6, life = 1.5, gravity = 1300, drag = 0, stretch = 0.0034, color = d.color })
                d.setBead(0)
                d.cycles -= 1
                if d.cycles <= 0 then
                    drop(i)
                else
                    d.state, d.t, d.dur = "rest", rand(1.4, 3.8), rand(0.9, 2)
                end
            end
        else
            d.t -= dt
            if d.t <= 0 then d.state, d.t = "swell", 0 end
        end
    end
end

-- Letter coordinates of the blade's lower edge where it crosses the letter at local x.
local function woundY(L, x)
    return CONFIG.TitleSize / 2 + (BLADE_Y - TITLE_Y) + KATANA.lowerY(SX * (L.x - L.w / 2 + x - KATANA.tipX))
end

-- Drip on a letter: from the blade wound down the face, or a bead hanging under the letter.
function DRIPS.onLetter(L, speedScale)
    local size = CONFIG.TitleSize
    local function toStage(x, y)
        return L.x + L.ox - L.w / 2 + x, TITLE_Y + L.oy - size / 2 + y
    end
    local bottom = size / 2 + CAP_H / 2
    DRIPS.count += 1
    if rng:NextNumber() < 0.68 then
        local sites = WOUNDS[string.upper(L.ch)] or { -0.25, 0.25 }
        local x = L.w / 2 + (pick(sites) + rand(-0.03, 0.03)) * L.w
        local y = woundY(L, x) - 2
        DRIPS.add(L.fx, toStage, x, y, bottom - y + rand(4, 26), rng:NextInteger(1, 3), speedScale)
    else
        DRIPS.add(L.fx, toStage, L.w / 2 + rand(-0.3, 0.3) * L.w, bottom - 3, rand(6, 22), rng:NextInteger(1, 2), speedScale)
    end
end

-- Blood welling out of a letter where the blade passes through it.
local function woundSplat(L, scale)
    if not HAS_BLOOD then return end
    for _, site in ipairs(WOUNDS[string.upper(L.ch)] or { -0.25, 0.25 }) do
        local x = L.w / 2 + site * L.w
        local s = CONFIG.TitleSize * scale * rand(0.8, 1.15)
        local img = sprite(pick(ATLAS.blots), { AnchorPoint = CENTER, Position = UDim2.fromOffset(x, woundY(L, x) - KATANA.bladeH * 0.4), Size = UDim2.fromOffset(s, s), Rotation = rand(-40, 40), ZIndex = 3, Parent = L.fx })
        local sc = make("UIScale", { Scale = 0.2, Parent = img })
        tween(sc, 0.14, { Scale = 1 }, ES.Back)
    end
end

----------------------------------------------------------------------
-- 13. EFFECTS: atmosphere (ash, embers, petals)
----------------------------------------------------------------------
local ATM = { list = {}, gust = 0, alpha = 0, dirty = true }
do
    for i = 1, ATMOS.Particles do
        local near = (i % 3 == 0)
        local depth = near and rand(1.15, 1.8) or rand(0.45, 0.95)
        local roll = i % 10
        local p = { x = rand(0, 1), y = rand(0, 1), depth = depth, phase = rand(0, TAU), ix = 0, iy = 0, rot = rand(0, 360), vr = 0 }
        local w, h, color
        if roll < 4 then                                       -- ash
            p.kind, p.vx, p.vy, p.a = "ash", rand(-0.006, 0.012), rand(-0.022, -0.006), rand(0.2, 0.45)
            w = rand(1.5, 3); h = w; color = COL.Ash
        elseif roll < 7 then                                   -- embers
            p.kind, p.vx, p.vy, p.a = "ember", rand(-0.012, 0.02), rand(-0.055, -0.02), rand(0.45, 0.85)
            w = rand(1.5, 2.8); h = w; color = COL.Ember
        else                                                   -- petals
            p.kind, p.vx, p.vy, p.a = "petal", -SX * rand(0.015, 0.045), rand(0.03, 0.06), rand(0.3, 0.65)
            w = rand(6, 10); h = w * 0.5; color = COL.Blood:Lerp(COL.BloodBright, rand(0, 0.7))
            p.vr = rand(-140, 140)
        end
        p.f = corner(frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(p.x, p.y), Size = UDim2.fromOffset(w * depth * view.s, h * depth * view.s), BackgroundColor3 = color, BackgroundTransparency = 1, Rotation = p.rot, Parent = near and ui.dustNear or ui.dustFar }))
        ATM.list[i] = p
    end
end

function ATM.update(dt)
    ATM.gust *= math.exp(-dt * 1.6)
    local gust, alpha, dirty, clock = ATM.gust, ATM.alpha, ATM.dirty, S.clock
    local decay = math.exp(-dt * 2.6)
    for _, p in ipairs(ATM.list) do
        p.x += ((p.vx + gust) * p.depth + p.ix) * dt
        p.y += (p.vy * p.depth + p.iy) * dt
        p.ix *= decay
        p.iy *= decay
        if p.x < -0.06 then p.x += 1.12 elseif p.x > 1.06 then p.x -= 1.12 end
        if p.y < -0.06 then p.y += 1.12 elseif p.y > 1.06 then p.y -= 1.12 end
        p.f.Position = UDim2.fromScale(p.x + 0.004 * math.sin(clock * 0.8 + p.phase), p.y)
        if p.kind == "petal" then
            p.rot += p.vr * dt
            p.f.Rotation = p.rot
        end
        if p.kind == "ember" then
            p.f.BackgroundTransparency = 1 - p.a * alpha * (0.55 + 0.45 * math.sin(clock * 5 + p.phase))
        elseif dirty then
            p.f.BackgroundTransparency = 1 - p.a * alpha
        end
    end
    ATM.dirty = false
end

-- Push particles away from a point on screen (0..1 coordinates).
function ATM.blast(xs, ys, power)
    for _, p in ipairs(ATM.list) do
        local dx, dy = p.x - xs, p.y - ys
        local d = math.sqrt(dx * dx + dy * dy) + 0.06
        local k = power / (d * 5 + 0.4)
        p.ix += dx / d * k
        p.iy += dy / d * k
    end
end

----------------------------------------------------------------------
-- 14. EFFECTS: impacts, flashes, lighting
----------------------------------------------------------------------
local function stageToScreen(x, y)
    return 0.5 + x * view.s / view.w, 0.5 + y * view.s / view.h
end

local function flash(o, peak, hold, fadeTime)
    o.BackgroundTransparency = 1 - peak
    tween(o, fadeTime, { BackgroundTransparency = 1 }, ES.Quad, ED.Out, hold)
end

local function shockwave(x, y, size, thickness, duration, color)
    local ring = corner(frame({ AnchorPoint = CENTER, Position = P(x, y), Size = UDim2.fromOffset(16, 16), Parent = ui.impact }))
    local stroke = make("UIStroke", { Color = color or COL.Bone, Thickness = thickness, Transparency = 0.15, Parent = ring })
    tween(ring, duration, { Size = UDim2.fromOffset(size, size) }, ES.Quint)
    tween(stroke, duration, { Transparency = 1, Thickness = 0.5 }, ES.Quad)
    after(duration + 0.1, function() ring:Destroy() end)
end

local function impactLines(x, y, count, power)
    for _ = 1, count do
        local a = rand(0, TAU)
        local len, dist = rand(70, 230) * power, rand(34, 70)
        local line = frame({ AnchorPoint = CENTER, Position = P(x + math.cos(a) * (dist + len / 2), y + math.sin(a) * (dist + len / 2)), Size = UDim2.fromOffset(len * 0.3, rand(1.2, 2.8)), BackgroundColor3 = COL.Bone, BackgroundTransparency = 0.1, Rotation = math.deg(a), Parent = ui.impact })
        gradient(line, 0, nil, nseq({ 0, 1, 0.3, 0, 1, 1 }))
        tween(line, 0.26, { Size = UDim2.fromOffset(len, 0.5), BackgroundTransparency = 1 }, ES.Quad)
        after(0.4, function() line:Destroy() end)
    end
end

-- Thin line of light along the cut.
local function slashLine(y, power)
    local width = view.halfW * 2 + 300
    for i = 1, 2 do
        local core = (i == 1)
        local line = frame({ AnchorPoint = CENTER, Position = P(0, y), Size = UDim2.fromOffset(0, core and 2 or 12 * power), BackgroundColor3 = core and WHITE or COL.BloodBright, BackgroundTransparency = core and 0 or 0.55, ZIndex = core and 2 or 1, Parent = ui.impact })
        gradient(line, 0, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))
        tween(line, 0.1, { Size = UDim2.fromOffset(width, core and 2 or 12 * power) }, ES.Quad)
        tween(line, 0.5, { BackgroundTransparency = 1, Size = UDim2.fromOffset(width, 0) }, ES.Quad, ED.In, 0.12)
        after(0.8, function() line:Destroy() end)
    end
end

local function starGlint(x, y, size, duration)
    local root = frame({ AnchorPoint = CENTER, Position = P(x, y), Size = UDim2.fromOffset(2, 2), Rotation = 18, Parent = ui.impact })
    for i = 0, 1 do
        local ray = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 1.6), BackgroundColor3 = WHITE, Rotation = i * 90, Parent = root })
        gradient(ray, 0, nil, nseq({ 0, 1, 0.5, 0, 1, 1 }))
        tween(ray, duration * 0.45, { Size = UDim2.fromOffset(size * (1 - i * 0.35), 1.6) }, ES.Quad)
        tween(ray, duration * 0.55, { Size = UDim2.fromOffset(0, 1.6) }, ES.Quad, ED.In, duration * 0.45)
    end
    after(duration + 0.1, function() root:Destroy() end)
end

local function thumpBars(power)
    local h, d = ATMOS.Letterbox, 0.014 * power
    tween(ui.barTop, 0.06, { Position = UDim2.fromScale(0, h + d) }, ES.Quad)
    tween(ui.barTop, 0.5, { Position = UDim2.fromScale(0, h) }, ES.Quint, ED.Out, 0.07)
    tween(ui.barBottom, 0.06, { Position = UDim2.fromScale(0, 1 - h - d) }, ES.Quad)
    tween(ui.barBottom, 0.5, { Position = UDim2.fromScale(0, 1 - h) }, ES.Quint, ED.Out, 0.07)
end

-- Everything that happens the instant steel meets the title.
local function impact(x, y, power)
    S.hitStop = 0.05 + 0.04 * power
    S.trauma = math.min(1.4, S.trauma + 0.55 * power)
    S.light = 1
    flash(ui.flashWhite, math.min(0.3 + 0.16 * power, 0.75), 0.03, 0.24)
    flash(ui.flashRed, 0.1 + 0.08 * power, 0.05, 0.9)
    shockwave(x, y, 420 * power, 3, 0.55)
    after(0.07, function() shockwave(x, y, 680 * power, 1.5, 0.8, COL.BloodBright) end)
    impactLines(x, y, math.floor(8 + 5 * power), power)
    FX.sparks(x, y, (SX > 0) and 0 or math.pi, math.floor(12 * power))
    local sx, sy = stageToScreen(x, y)
    ATM.blast(sx, sy, 0.2 * power)
    thumpBars(power)
    local ph = ui.photo
    ph.canvas.GroupColor3 = Color3.fromRGB(255, 150, 150)
    tween(ph.canvas, 0.7, { GroupColor3 = WHITE }, ES.Quad)
    ph.scale.Scale = 1 + 0.035 * power
    tween(ph.scale, 0.6, { Scale = 1 }, ES.Quint)
    ph.sheen.Position = UDim2.fromScale(-0.6, 0.5)
    tween(ph.sheen, 0.8, { Position = UDim2.fromScale(1.6, 0.5) }, ES.Sine, ED.InOut)
end

-- Subtle dark-red light passing across the screen.
local function ambientFlash()
    S.light = math.max(S.light, 0.4)
    flash(ui.flashRed, rand(0.04, 0.08), 0.04, 0.7)
    local fromLeft = rng:NextNumber() < 0.5
    ui.sweep.Position = UDim2.fromScale(fromLeft and -0.4 or 1.4, 0.5)
    ui.sweep.BackgroundTransparency = 0.86
    tween(ui.sweep, 1.1, { Position = UDim2.fromScale(fromLeft and 1.4 or -0.4, 0.5) }, ES.Sine, ED.InOut)
end

-- Applies impact light + heartbeat to everything that glows. Cheap: only runs when the value changes.
local function applyLight()
    local l, b, g = S.light, S.beat, S.glowBase
    local key = math.floor(l * 90) * 10000 + math.floor(b * 60) * 100 + math.floor(g * 50)
    if key == S.lightKey then return end
    S.lightKey = key
    local ph = ui.photo
    ph.halo.set(g * (0.14 + 0.42 * l + 0.1 * b))
    ph.moon.BackgroundTransparency = 1 - g * clamp(0.36 + 0.3 * l + 0.08 * b, 0, 1)
    local red = 1 - g * clamp(0.1 + 0.5 * l + 0.24 * b, 0, 0.85)
    for _, e in ipairs(ui.redEdges) do e.BackgroundTransparency = red end
    if TITLE.live then
        local glow = 1 - clamp(0.22 + 0.45 * l + 0.2 * b, 0, 0.9)
        for _, L in ipairs(TITLE.letters) do L.glow.Transparency = glow end
    end
    ui.bar.headGlow.set(0.3 + 0.3 * l + 0.25 * b)
end

----------------------------------------------------------------------
-- 15. PER-FRAME UPDATE
----------------------------------------------------------------------
local function updateLetters(dt)
    if TITLE.active then
        local any = false
        for _, L in ipairs(TITLE.letters) do
            if L.ox ~= 0 or L.oy ~= 0 or L.vx ~= 0 or L.vy ~= 0 then
                L.vx += (-320 * L.ox - 20 * L.vx) * dt
                L.vy += (-320 * L.oy - 20 * L.vy) * dt
                L.ox += L.vx * dt
                L.oy += L.vy * dt
                if math.abs(L.ox) + math.abs(L.oy) < 0.05 and math.abs(L.vx) + math.abs(L.vy) < 2 then
                    L.ox, L.oy, L.vx, L.vy = 0, 0, 0, 0
                else
                    any = true
                end
                local pos = P(L.x + L.ox, TITLE_Y + L.oy)
                for _, part in ipairs(L.parts) do part.Position = pos end
            end
        end
        TITLE.active = any
    end
    for _, L in ipairs(TITLE.letters) do                   -- blood slowly soaks the lower half
        if L.stain < L.stainGoal then
            L.stain = math.min(L.stainGoal, L.stain + dt * 0.35)
            if L.stain - L.stainShown > 0.02 then L.setStain(L.stain) end
        end
    end
end

local function updateTassel(dt)
    local ts = KATANA.tassel
    if not ts.live then return end
    ts.w += (-60 * (ts.a - ts.goal) - 4.5 * ts.w) * dt
    ts.a += ts.w * dt
    ts.v += (-95 * (ts.b - ts.a) - 5 * ts.v) * dt
    ts.b += ts.v * dt
    ts.pivot.Rotation = ts.a - (S.katRot + KATANA.hiltRot)
    ts.pivot2.Rotation = ts.b - ts.a
    if ts.goal == 0 and math.abs(ts.a) + math.abs(ts.b) < 0.15 and math.abs(ts.w) + math.abs(ts.v) < 1 then
        ts.live = false                                    -- settled; stop simulating
    end
end

local function updateProgress(dt)
    local bar = ui.bar
    if S.phase == "load" then
        if CONFIG.AutoProgress then
            S.loadT += dt * (S.rush and 9 or 1)
            local k = clamp(S.loadT / math.max(CONFIG.LoadDuration, 0.1), 0, 1)
            -- blend of linear and per-step easing: breathes with the steps but never stalls or jumps
            local n = math.max(#CONFIG.Steps, 1)
            local seg = k * n
            local i = math.floor(seg)
            S.target = lerp(k, (i + ease.inOut(seg - i)) / n, 0.55)
        elseif S.rush then
            S.target = 1
        end
    end
    local diff = (S.phase == "load") and (S.target - S.shown) or 0   -- the bar only moves once the blade is in
    if diff ~= 0 then
        local move = math.min(diff * (1 - math.exp(-dt * 7)), 0.9 * dt)
        S.shown += move
        if S.target >= 1 and 1 - S.shown < 0.002 then S.shown = 1 end
        local shown = S.shown
        bar.clip.Size = UDim2.fromOffset(bar.width * shown, 5)
        bar.head.Position = UDim2.fromOffset(bar.width * shown, 46)

        local pct = math.floor(shown * 100 + 0.5)
        if pct ~= S.pctShown then
            S.pctShown = pct
            bar.pct.Text = pct .. "%"
            if CONFIG.OnProgress then pcall(CONFIG.OnProgress, shown) end
        end
        for _, tick in ipairs(bar.ticks) do                -- milestones light up
            if not tick.lit and shown >= tick.at then
                tick.lit = true
                tick.f.BackgroundColor3 = COL.BloodBright
                tick.f.BackgroundTransparency = 0
                tick.f.Size = UDim2.fromOffset(9, 9)
                tween(tick.f, 0.5, { Size = UDim2.fromOffset(5, 5) }, ES.Back)
                if tick.at > 0 then S.light = math.max(S.light, 0.3) end
            end
        end
        local n = #CONFIG.Steps
        if n > 0 then
            local idx = math.min(n, math.floor(shown * n) + 1)
            if idx ~= S.stepShown then
                S.stepShown = idx
                bar.step.Text = string.format("%02d / %02d   %s", idx, n, spaced(string.upper(CONFIG.Steps[idx])))
                bar.step.TextTransparency = 1
                tween(bar.step, 0.4, { TextTransparency = 0.45 }, ES.Quad)
            end
        end
        -- embers shed by the head of the bar while it moves
        if S.phase == "load" and rng:NextNumber() < dt * 14 then
            FX.emit(-bar.width / 2 + bar.width * shown, BAR_Y + 46, rand(-90, -20), rand(-70, -10), {
                size = rand(1.4, 2.4), life = rand(0.3, 0.6), gravity = 160, drag = 1.5, stretch = 0.01,
                color = pick({ COL.Ember, COL.BloodBright, Color3.fromRGB(255, 190, 160) }),
            })
        end
        -- pierced letters soak up blood as loading advances
        for i = 1, KATANA.pierced do KATANA.order[i].stainGoal = 0.3 + 0.55 * shown end
    end
end

-- Things that happen "by themselves" while the bar fills.
local nextDrip, nextStain, nextFlash = 0, 0, 0
local function updateAmbience(dt)
    if S.phase ~= "load" then return end
    local clock = S.clock
    if clock >= nextDrip and DRIPS.count < BLOOD.MaxDrips then
        nextDrip = clock + rand(0.7, 1.6)
        DRIPS.onLetter(KATANA.order[rng:NextInteger(1, KATANA.pierced)])
    end
    if clock >= nextStain and STAINS.count < BLOOD.MaxStains then
        nextStain = clock + rand(1.5, 3)
        local x, y = STAINS.spot()
        STAINS.add(x, y, rand(9, 22), rand(0, TAU), rng:NextNumber() < 0.5)
    end
    if clock >= nextFlash then
        nextFlash = clock + rand(ATMOS.FlashInterval[1], ATMOS.FlashInterval[2])
        ambientFlash()
    end
    if ATMOS.Heartbeat then                                -- double pulse that quickens with progress
        S.beatPhase = (S.beatPhase + dt * (0.75 + 1.25 * S.shown)) % 1
        local ph = S.beatPhase
        local b = math.exp(-((ph - 0.1) / 0.05) ^ 2) + 0.6 * math.exp(-((ph - 0.32) / 0.06) ^ 2)
        S.beat = b * (0.3 + 0.7 * S.shown)
    end
end

local function step(rawDt)
    local dt = math.min(rawDt, 1 / 15) * SPEED
    if S.hitStop > 0 then                                  -- impact freeze-frame
        S.hitStop -= rawDt
        dt *= 0.05
    end
    S.clock += dt
    local clock = S.clock

    for i = #timers, 1, -1 do
        local tm = timers[i]
        if clock >= tm.at then
            timers[i] = timers[#timers]
            timers[#timers] = nil
            tm.fn()
        end
    end
    for i = #tracks, 1, -1 do
        local tr = tracks[i]
        tr.t += dt
        local a = math.min(tr.t / tr.d, 1)
        tr.fn(tr.ease and tr.ease(a) or a)
        if a >= 1 then
            table.remove(tracks, i)
            if tr.done then tr.done() end
        end
    end

    -- Camera shake
    if S.trauma > 0.001 then
        S.trauma = math.max(0, S.trauma - dt * 1.9)
        local k = S.trauma * S.trauma * 24 * CONFIG.Shake * view.s
        stage.Position = UDim2.new(0.5, math.noise(clock * 31, 1.3) * 2 * k, 0.5, math.noise(4.7, clock * 31) * 2 * k)
        S.shaking = true
    elseif S.shaking then
        S.shaking = false
        stage.Position = UDim2.fromScale(0.5, 0.5)
    end

    S.light = math.max(0, S.light - dt * 2.2)
    updateAmbience(dt)
    applyLight()
    ATM.update(dt)
    FX.update(dt)
    DRIPS.update(dt)
    updateLetters(dt)
    updateTassel(dt)
    updateProgress(dt)
end

----------------------------------------------------------------------
-- 16. TIMELINE
----------------------------------------------------------------------
local function fadeList(list, duration)
    for _, f in ipairs(list) do tween(f[1], duration, { [f[2]] = f[3] }, ES.Quad) end
end

local function revealPhoto()
    local ph = ui.photo
    animate(T.PhotoReveal, function(a) S.glowBase = a end, ease.outCubic)
    tween(ph.scale, T.PhotoReveal * 1.3, { Scale = 1 }, ES.Quint)
    tween(ph.canvas, T.PhotoReveal, { GroupTransparency = 0 }, ES.Sine)
    for _, s in ipairs(ph.strokes) do tween(s[1], T.PhotoReveal, { Transparency = s[2] }, ES.Quad, ED.Out, T.PhotoReveal * 0.35) end
    tween(ph.img, CONFIG.LoadDuration + 9, { Size = UDim2.fromScale(1.12, 1.12) }, ES.Sine, ED.InOut)   -- slow push-in
    tween(ph.sheen, 1, { Position = UDim2.fromScale(1.6, 0.5) }, ES.Sine, ED.InOut, T.PhotoReveal * 0.5)
    after(T.PhotoReveal * 0.85, function()                 -- stamp the seal
        ph.seal.BackgroundTransparency = 0
        ph.sealText.TextTransparency = 0.05
        tween(ph.sealScale, 0.16, { Scale = 1 }, ES.Quad, ED.In)
        after(0.16, function() S.trauma = math.min(1, S.trauma + 0.14) end)
    end)
end

local function slamLetter(L)
    local TS = TITLE.scale
    L.reveal(T.TitleSlam * 0.6)
    animate(T.TitleSlam, function(a)
        local s = TS * lerp(1.9, 1, a)
        for _, sc in ipairs(L.scales) do sc.Scale = s end
    end, ease.inCubic, function()
        S.trauma = math.min(1, S.trauma + 0.24)
        S.light = math.max(S.light, 0.4)
        sound(CONFIG.Sounds.Thud, 0.7, rand(0.9, 1.05))
        for _ = 1, 6 do                                    -- dust kicked up from under the letter
            local dir = (rng:NextNumber() < 0.5) and -1 or 1
            FX.emit(L.x + dir * rand(0, L.w * 0.5), TITLE_Y + CAP_H / 2, dir * rand(60, 260), rand(-70, 10), {
                size = rand(2, 4), life = rand(0.35, 0.7), gravity = 60, drag = 3.5, stretch = 0.004, color = COL.Ash, alpha = 0.5,
            })
        end
    end)
end

local function revealProgress()
    local bar = ui.bar
    fadeList(bar.fades, 0.7)
    tween(bar.track, 0.9, { Size = UDim2.fromOffset(bar.width, 5) }, ES.Quint)
    bar.head.Visible = true
    if CONFIG.CanSkip then tween(ui.hint, 0.8, { TextTransparency = 0.6 }, ES.Quad) end
end

-- The katana flies in and buries itself half way through the title.
local function strike()
    local startX = SX * (view.halfW + 70)
    local endX = KATANA.halfTipX - SX * 15
    local ts = KATANA.tassel
    starGlint(SX * (view.halfW - 40), BLADE_Y - KAT.FlightRise, 150, 0.34)
    sleep(0.3)

    KATANA.root.Visible = true
    ts.live, ts.goal = true, -SX * 72                      -- tassel streams out behind
    ts.a, ts.b = ts.goal, ts.goal
    sound(CONFIG.Sounds.Whoosh, 1)
    ATM.gust = -SX * 0.35
    animate(T.KatanaFlight, function(a)
        local u = a ^ 2.6                                  -- hard acceleration
        local rest = 1 - u
        KATANA.setPose(lerp(startX, endX, u), BLADE_Y - KAT.FlightRise * rest ^ 1.6, -KAT.FlightTilt * rest, 0)
        KATANA.setStreaks(a ^ 1.5)
    end, nil, function()
        local entry = math.abs(KATANA.entryX - KATANA.halfTipX)
        impact(KATANA.entryX, BLADE_Y, 1)
        sound(CONFIG.Sounds.Impact, 1)
        KATANA.setBlood(0.45)
        KATANA.setStreaks(0)
        ts.goal = 0
        ts.w += SX * 620
        -- blood: back out of the wound and forward off the tip
        local back = (SX > 0) and 0 or math.pi
        FX.spray(KATANA.entryX, BLADE_Y, back, 1.25, math.floor(BLOOD.SplashCount * 0.6), 160, 760, 140)
        FX.spray(KATANA.halfTipX, BLADE_Y, back + math.pi, 0.55, math.floor(BLOOD.SplashCount * 0.4), 240, 900, 60)
        spurt(KATANA.entryX, BLADE_Y, back + rand(-0.15, 0.15), 340, 0.6)
        spurt(KATANA.halfTipX, BLADE_Y, back + math.pi + rand(-0.2, 0.2), 250, 0.5)
        for i = 1, KATANA.pierced do woundSplat(KATANA.order[i], 0.4) end
        local sx = stageToScreen(KATANA.entryX, BLADE_Y)
        STAINS.burst(BLOOD.ImpactStains, 12, 28, 0.4, sx)
        -- letters are shoved along the thrust, the nearest hardest
        for i, L in ipairs(KATANA.order) do
            after((i - 1) * 0.03, function()
                L.vx += -SX * 560 / (i * 0.9 + 0.3)
                L.vy += rand(-60, 60)
                TITLE.active = true
            end)
        end
        for i = 1, KATANA.pierced do
            local L = KATANA.order[i]
            L.stainGoal = 0.3
            after(rand(0.15, 0.7), function() DRIPS.onLetter(L, 1.6) end)
        end
        -- the blade rings: overshoot along the thrust + quiver about the wound
        animate(1.3, function(a)
            local t = a * 1.3
            local push = 15 * math.exp(-9 * t) * math.cos(22 * t)
            local wob = KAT.Quiver * math.exp(-3.6 * t) * math.sin(TAU * 6.5 * t)
            KATANA.setPose(KATANA.halfTipX - SX * push, BLADE_Y, wob, entry)
        end)
        after(0.35, function() KATANA.glint(0.5) end)
        -- blood gathers on the tip and drips into the gap
        local dist = KATANA.tipLen * 0.8
        KATANA.tipDrip = DRIPS.add(ui.titleFx, function(x, y) return x - CX, y - CY end, CX + KATANA.halfTipX + SX * dist, CY + BLADE_Y + KATANA.lowerY(dist) - 3, 0, 99)
        S.struck = true
    end)
    waitFor(function() return S.struck end)
end

-- Slices the title along the blade: clones of each depth layer clipped to the upper / lower half.
local function splitTitle()
    local cutY = CY + BLADE_Y + KATANA.bladeH * 0.2
    local tops, bottoms = {}, {}
    for _, src in ipairs({ ui.titleBack, ui.titleMid, ui.titleFace }) do
        for half = 1, 2 do
            local top = (half == 1)
            local clip = frame({
                Position = UDim2.fromOffset(0, top and 0 or cutY), Size = UDim2.fromOffset(REF_W, top and cutY or (REF_H - cutY)),
                ClipsDescendants = true, ZIndex = src.ZIndex, Parent = stage,
            })
            local copy = src:Clone()
            copy.Position = UDim2.fromOffset(0, top and 0 or -cutY)
            copy.Size = UDim2.fromOffset(REF_W, REF_H)
            copy.Parent = clip
            table.insert(top and tops or bottoms, clip)
        end
        src.Visible = false
    end
    -- upper half slides along the thrust, lower half recoils
    local base = cutY
    animate(3.2, function(a)
        local fast = ease.outExpo(math.min(a * 5, 1))
        local dx, dy = -SX * (15 * fast + 16 * a), -(5 * fast + 5 * a)
        for _, clip in ipairs(tops) do clip.Position = UDim2.fromOffset(dx, dy) end
        for _, clip in ipairs(bottoms) do clip.Position = UDim2.fromOffset(SX * 5 * fast, base + 3 * fast) end
        ui.titleFx.Position = UDim2.fromOffset(SX * 5 * fast, 3 * fast)
    end)
end

-- Blood spreads until it covers the whole screen.
local function bloodCover(duration)
    local L = ui.cover
    local big = math.max(view.w, view.h)
    local tx, ty = stageToScreen(0, BLADE_Y)

    for i = 1, BLOOD.CoverBlobs do                         -- pools growing out of the wound and the lens
        local first = (i == 1)
        local px, py = first and tx or rand(0.05, 0.95), first and ty or rand(0.05, 0.95)
        local d = big * rand(0.45, 0.9)
        local shade = pick(SHADES)
        local lobes = {}
        for j = 1, 5 do                                    -- overlapping discs read as one organic pool
            local a, off = rand(0, TAU), d * rand(0.1, 0.3)
            lobes[j] = {
                f = corner(frame({ AnchorPoint = CENTER, Position = UDim2.new(px, math.cos(a) * off, py, math.sin(a) * off), Size = UDim2.fromOffset(0, 0), BackgroundColor3 = shade, ZIndex = 1, Parent = L })),
                d = d * rand(0.5, 0.85), late = rand(0, 0.18),
            }
        end
        local delay = first and 0 or duration * rand(0.08, 0.5)
        after(delay, function()
            animate(duration - delay, function(a)
                for _, lobe in ipairs(lobes) do
                    local k = clamp((a - lobe.late) / (1 - lobe.late), 0, 1)
                    local s = lobe.d * k * k
                    lobe.f.Size = UDim2.fromOffset(s, s)
                end
            end)
        end)
    end

    local n = BLOOD.CoverColumns                           -- curtain running down from the top
    local colW = view.w / n
    for i = 1, n + math.floor(n / 2) do
        local runner = i > n                               -- thin fast drips ahead of the curtain
        local w = runner and rand(7, 18) * view.s or colW * 1.3
        local shade = pick(SHADES)
        local col = corner(frame({
            AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(runner and rand(0.03, 0.97) or (i - 0.5) / n, 0, 0, -w),
            Size = UDim2.fromOffset(w, w), BackgroundColor3 = WHITE, ZIndex = runner and 3 or 2, Parent = L,
        }))
        gradient(col, 90, cseq({ 0, COL.BloodDark, 0.75, shade, 1, shade:Lerp(COL.BloodBright, 0.5) }))
        local delay = duration * (runner and rand(0, 0.25) or rand(0.05, 0.35))
        local reach = view.h * rand(1.1, 1.3) + w
        local power = runner and rand(1.3, 1.7) or rand(1.7, 2.5)
        after(delay, function()
            animate(duration - delay, function(a)
                col.Size = UDim2.fromOffset(w, w + reach * a ^ power)
            end)
        end)
    end

    local solid = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 4, Parent = L })
    gradient(solid, 90, cseq({ 0, COL.Blood, 1, COL.BloodDark }))
    tween(solid, duration * 0.3, { BackgroundTransparency = 0 }, ES.Sine, ED.InOut, duration * 0.7)
end

-- Textured finale: big blots burst onto the screen one over another until nothing else is left
-- (ink-splash style: each one lands in a frame or two, the last gaps soak through).
local function bloodFlood(duration)
    local L = ui.cover
    local vw, vh = view.w, view.h
    local wx, wy = stageToScreen(0, BLADE_Y)

    -- Landing spots on a jittered grid, so the blots are certain to tile the screen; nearest to the wound first.
    local cols, rows = 5, 3
    local spots = {}
    for c = 0, cols - 1 do
        for r = 0, rows - 1 do
            local x, y = (c + 0.5 + rand(-0.28, 0.28)) / cols, (r + 0.5 + rand(-0.28, 0.28)) / rows
            local dx, dy = (x - wx) * vw / vh, y - wy
            spots[#spots + 1] = { x = x, y = y, order = math.sqrt(dx * dx + dy * dy) + rand(0, 0.45) }
        end
    end
    table.sort(spots, function(a, b) return a.order < b.order end)

    local n = math.min(#spots, BLOOD.CoverBlots)
    local shape = rng:NextInteger(1, #ATLAS.blots)
    for i = 1, n do
        local sp = spots[i]
        local f = math.max(i - 2, 0) / math.max(n - 2, 1)  -- the first two land together, then faster and faster
        after(duration * 0.7 * f ^ 0.6, function()
            local size = vh * lerp(0.95, 1.7, f) * rand(0.9, 1.1)
            local root = frame({ AnchorPoint = CENTER, Position = UDim2.fromScale(sp.x, sp.y), Size = UDim2.fromOffset(size, size), ZIndex = 2 + i, Parent = L })
            local sc = make("UIScale", { Scale = 0.2, Parent = root })
            local tone = rand(0.62, 1)
            local tint = Color3.new(tone, tone, tone)
            sprite(ATLAS.blots[(shape + i) % #ATLAS.blots + 1], { AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Rotation = rand(-35, 35), ImageColor3 = tint, ZIndex = 2, Parent = root })
            if i <= 9 then                                 -- later blots land on blood, their spray would not show
                sprite(ATLAS.spray, { AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.2, 1.2), Rotation = rand(0, 360), ImageColor3 = tint, Parent = root })
            end
            animate(0.085, function(a)
                sc.Scale = lerp(0.2, 1, a)
            end, ease.outCubic, function()
                tween(sc, 1.6, { Scale = 1.07 }, ES.Sine)  -- the pool keeps creeping outwards
            end)
            S.trauma = math.min(1.1, S.trauma + 0.2)
            S.light = math.max(S.light, 0.55)
            FX.spray((sp.x - 0.5) * vw / view.s, (sp.y - 0.5) * vh / view.s, rand(0, TAU), math.pi, 6, 300, 1300, 60)
        end)
    end

    for i = 1, 4 do                                        -- soft soaking closes the last gaps
        local sp = spots[n + i] or { x = rand(0.15, 0.85), y = rand(0.15, 0.85) }
        after(duration * (0.48 + 0.09 * i), function()
            local size = vh * rand(1.5, 2.1)
            local img = sprite(ATLAS.bleed, { AnchorPoint = CENTER, Position = UDim2.fromScale(sp.x, sp.y), Size = UDim2.fromOffset(size, size), Rotation = rand(0, 360), ImageTransparency = 1, ZIndex = 2, Parent = L })
            local sc = make("UIScale", { Scale = 0.45, Parent = img })
            tween(sc, duration * 0.5, { Scale = 1.5 }, ES.Quad)
            tween(img, duration * 0.28, { ImageTransparency = 0 }, ES.Quad)
        end)
    end

    local base = frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 1, Parent = L })
    gradient(base, 90, cseq({ 0, Color3.fromRGB(64, 2, 6), 1, Color3.fromRGB(30, 1, 3) }))
    tween(base, duration * 0.3, { BackgroundTransparency = 0 }, ES.Sine, ED.InOut, duration * 0.7)
end

-- 100%: the katana is driven all the way through.
local function finale()
    S.phase = "finale"
    local bar, ts = ui.bar, KATANA.tassel
    bar.state.Text = spaced("READY")
    bar.step.Text = "完了"
    tween(ui.hint, 0.3, { TextTransparency = 1 }, ES.Quad)
    bar.pctScale.Scale = 1.25
    tween(bar.pctScale, 0.5, { Scale = 1 }, ES.Back)
    flash(ui.flashRed, 0.08, 0, 0.5)
    S.beat = 0
    sleep(T.FinalHold)

    -- wind-up: the sword is drawn back, trembling
    local entry = math.abs(KATANA.entryX - KATANA.halfTipX)
    local back = KATANA.halfTipX + SX * KAT.Windup
    animate(T.FinalWindup, function(a)
        local e = ease.outCubic(a)
        KATANA.setPose(lerp(KATANA.halfTipX, back, e), BLADE_Y, -0.8 * e + 0.25 * math.sin(a * 60), entry + KAT.Windup * e)
    end)
    ts.live = true
    ts.w -= SX * 160
    S.light = math.max(S.light, 0.5)
    sleep(T.FinalWindup + 0.05)

    -- thrust
    local endX = KATANA.fullTipX - SX * 18
    if KATANA.tipDrip then                                 -- the bead on the tip leaves with the blade
        KATANA.tipDrip.cycles = 0
        KATANA.tipDrip.hideBead()
    end
    sound(CONFIG.Sounds.Whoosh, 1, 1.2)
    ATM.gust = -SX * 0.6
    animate(T.FinalThrust, function(a)
        local u = a * a * a
        KATANA.setPose(lerp(back, endX, u), BLADE_Y, -0.8 * (1 - u), 0)
        KATANA.setStreaks(a)
    end, nil, function()
        local bladeLen = KATANA.bladeLen
        sound(CONFIG.Sounds.Final ~= "" and CONFIG.Sounds.Final or CONFIG.Sounds.Impact, 1, 0.85)
        impact(KATANA.entryX, BLADE_Y, 1.7)
        after(0.05, function() impact(KATANA.exitX, BLADE_Y, 1.1) end)
        slashLine(BLADE_Y, 1.6)
        KATANA.setBlood(1)
        KATANA.setStreaks(0)
        ts.w += SX * 900
        for _, L in ipairs(TITLE.letters) do L.stainGoal = 0.9; L.setStain(0.9) end
        splitTitle()
        -- final wave: out of the exit wound, plus fans above and below every letter
        local fwd = (SX > 0) and math.pi or 0
        local count = BLOOD.FinalSplashCount
        FX.spray(KATANA.exitX, BLADE_Y, fwd, 0.6, math.floor(count * 0.45), 320, 1500, 80)
        spurt(KATANA.exitX, BLADE_Y, fwd + rand(-0.12, 0.12), 560, 0.75)
        spurt(KATANA.entryX, BLADE_Y, fwd + math.pi + rand(-0.2, 0.2), 380, 0.6)
        for i = KATANA.pierced + 1, #KATANA.order do woundSplat(KATANA.order[i], 0.44) end
        for _, L in ipairs(TITLE.letters) do
            local each = math.floor(count * 0.55 / #TITLE.letters / 2)
            FX.spray(L.x, BLADE_Y, -math.pi / 2, 0.9, each, 200, 900, 0)
            FX.spray(L.x, BLADE_Y, math.pi / 2, 0.9, each, 120, 520, 0)
            spurt(L.x, BLADE_Y, -math.pi / 2 + rand(-0.5, 0.5), 250, 0.55)
            DRIPS.onLetter(L, 3)
        end
        STAINS.burst(BLOOD.FinalStains, 20, 44, 0.5)
        animate(1.1, function(a)                           -- guard slams home and rings
            local t = a * 1.1
            local push = 18 * math.exp(-10 * t) * math.cos(26 * t)
            local wob = KAT.Quiver * 0.6 * math.exp(-5 * t) * math.sin(TAU * 8 * t)
            KATANA.setPose(KATANA.fullTipX - SX * push, BLADE_Y, wob, bladeLen)
        end)
        S.thrust = true
    end)
    waitFor(function() return S.thrust end)

    sleep(0.45)
    if HAS_BLOOD then
        bloodFlood(T.BloodCover)
    else
        bloodCover(T.BloodCover)
        for i = 1, 3 do                                    -- aftershocks while the blood spreads
            after(T.BloodCover * 0.22 * i, function()
                S.trauma = math.min(1, S.trauma + 0.2)
                flash(ui.flashRed, 0.12, 0, 0.6)
            end)
        end
    end
    sleep(T.BloodCover + T.EndHold)
end

local function timeline()
    -- the screen is already black; let the scene emerge from it
    sleep(0.4)
    S.phase = "intro"
    ui.bg.Visible, ui.vignette.Visible, stage.Visible = true, true, true
    tween(ui.barTop, 1.1, { Position = UDim2.fromScale(0, ATMOS.Letterbox) }, ES.Quint)
    tween(ui.barBottom, 1.1, { Position = UDim2.fromScale(0, 1 - ATMOS.Letterbox) }, ES.Quint)
    tween(ui.fade, T.FadeIn, { BackgroundTransparency = 1 }, ES.Sine, ED.InOut)
    tween(ui.kanji, T.FadeIn * 1.8, { TextTransparency = 0.9 }, ES.Sine)
    for _, f in ipairs(ui.fog) do tween(f[1], T.FadeIn * 2, { BackgroundTransparency = f[2] }, ES.Sine) end
    animate(T.FadeIn * 1.5, function(a)
        ATM.alpha, ATM.dirty = a, true
    end)
    sleep(T.FadeIn * 0.75)

    revealPhoto()
    sleep(T.PhotoReveal * 0.8)

    for _, L in ipairs(TITLE.letters) do
        slamLetter(L)
        sleep(T.TitleStagger)
    end
    sleep(T.TitleSlam + 0.1)
    TITLE.live = true
    tween(ui.sub, 0.7, { TextTransparency = 0.25 }, ES.Quad)
    for _, line in ipairs(ui.subLines) do tween(line, 0.9, { Size = UDim2.fromOffset(120, 1) }, ES.Quint) end
    fadeList(ui.side, 1.2)
    revealProgress()
    sleep(T.PreStrike)

    strike()
    sleep(T.PostStrike)

    S.phase = "load"
    nextDrip, nextStain, nextFlash = S.clock + 0.4, S.clock + 1.2, S.clock + 1.8
    waitFor(function() return S.shown >= 1 end)

    finale()

    -- curtain call: blood -> black -> gone
    tween(ui.fade, T.FadeToBlack, { BackgroundTransparency = 0 }, ES.Sine, ED.InOut)
    sleep(T.FadeToBlack + 0.05)
    S.phase = "out"
    for _, name in ipairs({ "bg", "dustFar", "dustNear", "lens", "cover", "vignette" }) do ui[name].Visible = false end
    stage.Visible = false
    ui.barTop.Parent.Visible = false
    tween(ui.fade, T.FadeOut, { BackgroundTransparency = 1 }, ES.Sine, ED.InOut)
    sleep(T.FadeOut + 0.05)
    S.completed = true
end

----------------------------------------------------------------------
-- 17. RUN
----------------------------------------------------------------------
table.insert(conns, RunService.RenderStepped:Connect(function(dt)
    if not S.alive then return end
    local ok, err = pcall(step, dt)
    if not ok then
        warn("[ZeroIntro] render: " .. tostring(err))
        cleanup()
    end
end))

table.insert(conns, ui.skip.Activated:Connect(function()
    if CONFIG.CanSkip and S.phase ~= "finale" and S.phase ~= "out" then S.rush = true end
end))

task.spawn(function()
    local ok, err = pcall(timeline)
    if not ok and err ~= CANCELLED then warn("[ZeroIntro] " .. tostring(err)) end
    cleanup()
end)

-- Failsafe so a stalled intro can never trap the player behind the screen.
if CONFIG.AutoProgress then
    local total = CONFIG.LoadDuration + T.BloodCover + 14
    task.delay(total / SPEED + 25, cleanup)
end

local controller = {}

function controller.SetProgress(p)                         -- manual mode: 0..1
    if not CONFIG.AutoProgress then S.target = clamp(tonumber(p) or 0, S.target, 1) end
end

function controller.GetProgress()
    return S.shown
end

function controller.Skip()
    if S.phase ~= "finale" and S.phase ~= "out" then S.rush = true end
end

function controller.IsFinished()
    return not S.alive
end

function controller.Wait()                                 -- yields until the intro is gone
    if not S.alive then return S.completed end
    table.insert(waiters, coroutine.running())
    coroutine.yield()
    return S.completed
end

function controller.Destroy()
    cleanup()
end

return controller
