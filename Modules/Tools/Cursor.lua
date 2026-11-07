-- Modules/Tools/Cursor.lua
-- 光标拖尾 + 速度光 (cursor trail / speed spark): 纯装饰, 与游戏功能无关.
--
-- 拖尾是一串 Line 段: 每次采样把光标位置压进队列, 相邻两点连一段, 段宽和 alpha 沿链递减,
-- 鼠标停下后按时间自己淡没. 速度光是十字星芒 (横竖两条 ADD 混合的 Line), 只在快速移动时
-- 出现, 长度随平滑后的速度增长.
--
-- 与参考插件的关系: 思路来自 Andromeda 的 modules/misc/cursor.lua (CursorTrail), 那份是
-- GPL-3.0, 代码不可复用; 这里的实现是自写的, 且把它的 Interface\Cooldown\star4 换成了自绘的
-- 两条线, 不引入任何暴雪 / 第三方贴图.
--
-- 只用文档化的 GetCursorPosition() (本客户端没有 GetScaledCursorPosition), 不碰受保护对象,
-- 也不改任何暴雪帧, 因此战斗 / 载具 / PvP 下都安全. 关掉模块时 OnUpdate 整个摘掉, 零开销.

local ADDON_NAME, ns = ...
local Scheduler = ns.Scheduler

local Color = ns.Color
local Media = ns.Media

local M = { name = "Cursor" }
ns.Cursor = M

local SEGMENTS     = 12      -- 拖尾最长几段
local SAMPLE       = 0.045   -- 采样间隔，秒（约 22Hz，肉眼够顺、又不是每帧都写 12 条线）
local LIFETIME     = 0.32    -- 一段从全亮到消失的时间，秒
local MIN_LEN      = 0.5     -- UI 单位：两点比这还近就当没动，省掉退化线段
local HEAD_WIDTH   = 4       -- 头部线宽（物理像素），往尾部收细
local SPARK_SPEED  = 1100    -- UI 单位/秒：平滑速度超过它才亮星芒
local SPARK_MAX    = 26      -- 星芒最长（UI 单位）
local SPARK_TAU    = 0.09    -- 速度指数平滑的时间常数，秒（越小越跟手）

local host                       -- 挂在 UIParent 上的透明框（TOOLTIP 层）
local lines = {}                 -- 拖尾段 [1] 是最新的一段
local sparkH, sparkV             -- 速度光的横 / 竖线
local samples = {}               -- 采样点，[1] 最新：{ x, y, t }
local enabled, trailOn, glowOn, cursorSubId
local acc                        -- 采样累加器
local clock = 0                  -- 自己的秒表（累加 OnUpdate 的 elapsed，不依赖 GetTime）
local speed                      -- 平滑后的光标速度（UI 单位/秒）
local lastX, lastY               -- 上一帧的光标位置（算速度用）

--- 光标位置 → UI 坐标（相对 UIParent）。GetCursorPosition 给的是物理像素，
--- 除以 effective scale 才能直接当 SetPoint 的偏移用（和 ActionBars / Tooltip 同一套换算）。
local function CursorUI()
    local x, y = _G.GetCursorPosition()
    if not x then return nil end
    local ui = _G.UIParent
    local scale = ui and ui:GetEffectiveScale() or 1
    if not scale or scale == 0 then scale = 1 end
    return x / scale, y / scale
end

--- 一条线的两端（都在 UIParent 坐标里）。端点重合时返回 false，调用方把线藏起来。
local function Span(line, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    if (dx * dx + dy * dy) < (MIN_LEN * MIN_LEN) then return false end
    line:SetStartPoint("BOTTOMLEFT", _G.UIParent, x1, y1)
    line:SetEndPoint("BOTTOMLEFT", _G.UIParent, x2, y2)
    return true
end

--- 主题色：拖尾跟边框槽（和条子边框、分隔线同源），星芒用高光奶油色（ADD 混合下才像光）。
local function Paint()
    if not host then return end
    local r, g, b = Color:GetBorder()
    for i = 1, #lines do lines[i]:SetColorTexture(r, g, b, 1) end
    if sparkH then
        local hr, hg, hb = Color:GetHighlight()
        sparkH:SetColorTexture(hr, hg, hb, 1)
        sparkV:SetColorTexture(hr, hg, hb, 1)
    end
end

local function HideAll()
    for i = 1, #lines do lines[i]:Hide() end
    if sparkH then sparkH:Hide() end
    if sparkV then sparkV:Hide() end
end

local function Build()
    if host then return true end

    local ui = _G.UIParent
    if not ui or not ui.CreateLine then return false end

    host = CreateFrame("Frame", "MonetUICursor", ui)
    host:SetAllPoints(ui)
    -- TOOLTIP 层：压在面板与动作条之上、暴雪的光标贴图之下，拖尾不会钻进窗口里。
    host:SetFrameStrata("TOOLTIP")
    host:Hide()   -- 只是容器；里面每个 line 自己显隐

    for i = 1, SEGMENTS do
        local line = host:CreateLine(nil, "ARTWORK")
        -- 线宽只跟"第几段"有关，建的时候定死，之后每帧只改 alpha，省掉逐帧 SetThickness。
        local taper = 1 - (i - 1) / SEGMENTS
        line:SetThickness(Media:Mult() * (0.5 + (HEAD_WIDTH - 0.5) * taper))
        line:SetColorTexture(1, 1, 1, 1)
        line:Hide()
        lines[i] = line
    end

    sparkH = host:CreateLine(nil, "ARTWORK")
    sparkV = host:CreateLine(nil, "ARTWORK")
    for _, line in ipairs({ sparkH, sparkV }) do
        line:SetThickness(Media:Mult())
        line:SetColorTexture(1, 1, 1, 1)
        line:SetAlpha(0.75)
        -- ADD 才像"光"；Line 继承 TextureBase，但这一条不在文档的 Line 方法表里，兜一层。
        pcall(line.SetBlendMode, line, "ADD")
        line:Hide()
    end

    Paint()
    host:Show()
    return true
end

local function UpdateSpark(x, y, elapsed)
    if not sparkH then return end
    if not lastX then return end   -- 第一帧只记位置，速度还是 0
    if not elapsed or elapsed <= 0 then return end

    local dx, dy = x - lastX, y - lastY
    local instant = math.sqrt(dx * dx + dy * dy) / elapsed

    -- 指数平滑：时间越短权重越小，快速抖一下不会让星芒整帧闪。
    local k = math.exp(-elapsed / SPARK_TAU)
    speed = k * speed + (1 - k) * instant

    local size = (speed - SPARK_SPEED) / 45
    if size < 3 then
        sparkH:Hide()
        sparkV:Hide()
        return
    end
    if size > SPARK_MAX then size = SPARK_MAX end
    local half = size / 2

    sparkH:SetStartPoint("BOTTOMLEFT", _G.UIParent, x - half, y)
    sparkH:SetEndPoint("BOTTOMLEFT", _G.UIParent, x + half, y)
    sparkV:SetStartPoint("BOTTOMLEFT", _G.UIParent, x, y - half)
    sparkV:SetEndPoint("BOTTOMLEFT", _G.UIParent, x, y + half)
    sparkH:SetAlpha(0.75)
    sparkV:SetAlpha(0.75)
    sparkH:Show()
    sparkV:Show()
end

local function UpdateTrail(now)
    -- 段 i 连 samples[i]（新）和 samples[i+1]（旧）；没有采样点就把线收起来。
    for i = 1, #lines do
        local a, b = samples[i], samples[i + 1]
        local line = lines[i]
        if a and b and Span(line, b.x, b.y, a.x, a.y) then
            -- 按"较新那条"的年龄淡出，尾端再乘一个线性衰减，形成拖尾。
            local age = now - a.t
            local fade = 1 - (age / LIFETIME)
            if fade < 0 then fade = 0 end
            local taper = 1 - (i - 1) / SEGMENTS
            line:SetAlpha(fade * taper * 0.9)
            line:Show()
        else
            line:Hide()
        end
    end
end

local function OnUpdate(_, elapsed)
    if not host then return end

    local x, y = CursorUI()
    if not x then return end

    elapsed = elapsed or 0
    clock = clock + elapsed
    acc = acc + elapsed

    if trailOn then
        -- 只在"真的动了"时压新采样点：否则鼠标一停，同样的点会把整条尾巴顶掉、拖尾瞬间消失。
        if acc >= SAMPLE then
            acc = 0
            local tail = samples[1]
            local moved = true
            if tail then
                local dx, dy = x - tail.x, y - tail.y
                moved = (dx * dx + dy * dy) >= (MIN_LEN * MIN_LEN)
            end
            if moved then
                table.insert(samples, 1, { x = x, y = y, t = clock })
                while #samples > SEGMENTS do table.remove(samples) end
            end
        end
        -- 按年龄淘汰：停下后整条尾巴会自己淡没，最后清空。
        while #samples > 1 and (clock - samples[#samples].t) > LIFETIME do table.remove(samples) end
        if samples[1] and (clock - samples[1].t) > LIFETIME then
            for i = #samples, 1, -1 do samples[i] = nil end   -- 复用同一张表，别每轮新建
        end
        UpdateTrail(clock)
    else
        for i = 1, #lines do lines[i]:Hide() end
    end

    if glowOn then UpdateSpark(x, y, elapsed) else
        if sparkH then sparkH:Hide() end
        if sparkV then sparkV:Hide() end
    end

    lastX, lastY = x, y
end

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.cursor) ~= "table" then db.cursor = {} end
    return db.cursor
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.cursor[key] end
    return value
end

--- 两个效果都关了就把 OnUpdate 摘掉（模块仍然启用，随时能再打开）。
function M:Apply()
    trailOn = self:GetSetting("trail") and true or false
    glowOn  = self:GetSetting("glow") and true or false

    if not (enabled and host) then return end
    if trailOn or glowOn then
        if not cursorSubId then cursorSubId = Scheduler:EveryFrame(OnUpdate) end
    else
        if cursorSubId then Scheduler:Unregister(cursorSubId); cursorSubId = nil end
        HideAll()
    end
end

function M:Initialize()
    enabled = true
    if not Build() then return end
    samples = {}
    acc, clock, speed, lastX, lastY = 0, 0, 0, nil, nil
    Paint()
    self:Apply()
end

function M:SetEnabled(value)
    enabled = value and true or false
    if not host then return end

    if enabled then
        Paint()
        self:Apply()
    else
        if cursorSubId then Scheduler:Unregister(cursorSubId); cursorSubId = nil end
        HideAll()
        samples = {}
        speed, lastX, lastY, acc = 0, nil, nil, 0
    end
end

-- 换主题：拖尾跟边框槽走，星芒跟高光槽走，重涂一次即可。
ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
    if host then Paint() end
end)

ns:Register("Cursor", M)
