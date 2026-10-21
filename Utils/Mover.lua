-- Utils/Mover.lua
-- 位置服务：一个框注册一次，位置只从这里读写、只从这里吸附、只从这里锁。
--
-- 为什么要有它：以前每个模块各自 SetMovable + StartMoving，位置各存各的格式
-- （Modules/UnitFrames/UnitFrames.lua 存 GetPoint 的原始四元组，Modules/QuestTracker 存的点
-- 跟相对点还对不上），于是"拖动后 /reload 偏移"、"改 UI 缩放后错位"、"没法统一锁"全都无解。
--
-- 这里只做四件事：
--   1) 落点归一：把拖完的位置换算成"最自然的一对锚点 + 偏移"，点永远等于存下来的那对；
--   2) 网格 + 互相吸附：吸附在松手时算一次，拖动途中不跑每帧逻辑；
--   3) 锁：按组锁，战斗中不拦（锁本身不碰受保护框）；
--   4) 依赖顺序：位置相对另一个已登记的框时，先摆父框再摆子框，父框动子框跟着动。

local ADDON_NAME, ns = ...

local Media = ns.Media
local Math = ns.Math

local Mover = {}
ns.Mover = Mover

--- 已登记的框：key -> entry
-- entry = { key, frame, label, group, store(), default = {point,relativeTo,relativePoint,x,y} }
local entries = {}

local ANCHORS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }

--- 锚点在矩形里的坐标（矩形 = left, bottom, width, height，单位统一是 UIParent 的单位）。
local function AnchorX(left, width, anchor)
    if anchor == "TOPLEFT" or anchor == "LEFT" or anchor == "BOTTOMLEFT" then return left end
    if anchor == "TOPRIGHT" or anchor == "RIGHT" or anchor == "BOTTOMRIGHT" then return left + width end
    return left + width / 2
end

local function AnchorY(bottom, height, anchor)
    if anchor == "TOPLEFT" or anchor == "TOP" or anchor == "TOPRIGHT" then return bottom + height end
    if anchor == "BOTTOMLEFT" or anchor == "BOTTOM" or anchor == "BOTTOMRIGHT" then return bottom end
    return bottom + height / 2
end

--- 框的矩形，统一换算到 UIParent 的单位。
-- GetRect 的值是"屏幕坐标 × 这个框的有效缩放"，被父框缩放过（动作条 0.93、团队框 0.8）时
-- 直接拿来算吸附会差几个点，所以先除以它相对 UIParent 的缩放。
local function Rect(frame)
    if frame == UIParent then
        return 0, 0, UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    end
    if not frame or type(frame.GetRect) ~= "function" then return nil end
    local left, bottom, width, height = frame:GetRect()
    if not left or not width then return nil end
    local scale = (frame.GetEffectiveScale and frame:GetEffectiveScale() or 1)
                  / (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1)
    if scale > 0 and scale ~= 1 then
        left, bottom, width, height = left / scale, bottom / scale, width / scale, height / scale
    end
    return left, bottom, width, height
end

--- 从"子框相对于父框的实际摆放"反推最自然的一对锚点。
-- 贴边放（左右 / 上下相邻）时用贴边对（子框左边 ↔ 父框右边）：父框改宽度时间距不跟着变。
-- 叠在一起时用同点对（左上 ↔ 左上）：子框自己改大小不会跳。
local function ChoosePair(child, parent)
    local cl, cb, cw, ch = child[1], child[2], child[3], child[4]
    local pl, pb, pw, ph = parent[1], parent[2], parent[3], parent[4]

    local right = cl >= pl + pw
    local left  = pl >= cl + cw
    local above = cb >= pb + ph
    local below = pb >= cb + ch

    local candidates
    if right and above then
        candidates = { { "BOTTOMLEFT", "TOPRIGHT" }, { "LEFT", "RIGHT" }, { "BOTTOM", "TOP" } }
    elseif right and below then
        candidates = { { "TOPLEFT", "BOTTOMRIGHT" }, { "LEFT", "RIGHT" }, { "TOP", "BOTTOM" } }
    elseif left and above then
        candidates = { { "BOTTOMRIGHT", "TOPLEFT" }, { "RIGHT", "LEFT" }, { "BOTTOM", "TOP" } }
    elseif left and below then
        candidates = { { "TOPRIGHT", "BOTTOMLEFT" }, { "RIGHT", "LEFT" }, { "TOP", "BOTTOM" } }
    elseif right then
        candidates = { { "LEFT", "RIGHT" }, { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }
    elseif left then
        candidates = { { "RIGHT", "LEFT" }, { "TOPRIGHT", "TOPLEFT" }, { "BOTTOMRIGHT", "BOTTOMLEFT" } }
    elseif above then
        candidates = { { "BOTTOM", "TOP" }, { "BOTTOMLEFT", "TOPLEFT" }, { "BOTTOMRIGHT", "TOPRIGHT" } }
    elseif below then
        candidates = { { "TOP", "BOTTOM" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }
    end

    local bestPoint, bestRelative, bestX, bestY
    local bestScore = math.huge

    if candidates then
        for i = 1, #candidates do
            local point, relativePoint = candidates[i][1], candidates[i][2]
            local x = AnchorX(cl, cw, point) - AnchorX(pl, pw, relativePoint)
            local y = AnchorY(cb, ch, point) - AnchorY(pb, ph, relativePoint)
            local score = math.abs(x) + math.abs(y)
            if score < bestScore then
                bestScore, bestPoint, bestRelative, bestX, bestY = score, point, relativePoint, x, y
            end
        end
        return bestPoint, bestRelative, bestX, bestY
    end

    -- 重叠：同点对里挑偏移最小的那对
    for i = 1, #ANCHORS do
        local anchor = ANCHORS[i]
        local x = AnchorX(cl, cw, anchor) - AnchorX(pl, pw, anchor)
        local y = AnchorY(cb, ch, anchor) - AnchorY(pb, ph, anchor)
        local score = math.abs(x) + math.abs(y)
        if score < bestScore then
            bestScore, bestPoint, bestRelative, bestX, bestY = score, anchor, anchor, x, y
        end
    end
    return bestPoint, bestRelative, bestX, bestY
end

--- 在候选线里找离我们的边最近的一条，返回要把矩形平移多少（没有就返回 nil）。
local function SnapAxis(edges, candidates, range)
    local bestDelta, bestDistance
    for i = 1, #edges do
        for j = 1, #candidates do
            local delta = candidates[j] - edges[i]
            local distance = math.abs(delta)
            if distance <= range and (not bestDistance or distance < bestDistance) then
                bestDistance, bestDelta = distance, delta
            end
        end
    end
    return bestDelta
end

local function MoverConfig()
    local db = ns:DB()
    return db and db.mover or {}
end

--- 松手时把矩形吸到网格 / 别的框 / 屏幕边上。只算一次，拖动途中不跑。
local function SnapRect(rect, entry)
    local cfg = MoverConfig()
    local mult = Media:Mult()

    -- 1) 网格：左上角落到整数格（格子大小按物理像素算，换分辨率格距不变）
    local grid = cfg.grid
    if grid and grid > 0 then
        local step = grid * mult
        rect[1] = math.floor(rect[1] / step + 0.5) * step
        rect[2] = math.floor((rect[2] + rect[4]) / step + 0.5) * step - rect[4]
    end

    -- 2) 吸附：同组里其它可见框的左/中/右、下/中/上，加上屏幕的左/中/右、下/中/上
    if cfg.snap == false then return end
    local range = (cfg.snapRange or 6) * mult

    local xs, ys = {}, {}
    local uw, uh = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    xs[1], xs[2], xs[3] = 0, uw / 2, uw
    ys[1], ys[2], ys[3] = 0, uh / 2, uh

    for key, other in pairs(entries) do
        -- 容器框自己永远可见（内容由安全头控制），所以登记时可以给一个 isVisible 回调。
        local visible = other.frame and other.frame:IsShown()
        if visible and other.isVisible then
            local ok, shown = pcall(other.isVisible)
            visible = ok and shown and true or false
        end
        if key ~= entry.key and visible and other.group == entry.group then
            local ol, ob, ow, oh = Rect(other.frame)
            if ol then
                xs[#xs + 1], xs[#xs + 2], xs[#xs + 3] = ol, ol + ow / 2, ol + ow
                ys[#ys + 1], ys[#ys + 2], ys[#ys + 3] = ob, ob + oh / 2, ob + oh
            end
        end
    end

    local left, bottom, width, height = rect[1], rect[2], rect[3], rect[4]
    local right, top = left + width, bottom + height

    local dx = SnapAxis({ left, left + width / 2, right }, xs, range)
    local dy = SnapAxis({ bottom, bottom + height / 2, top }, ys, range)

    if dx then rect[1] = left + dx end
    if dy then rect[2] = bottom + dy end
end

--- 解析一个 key 的父框。relativeTo 是 "UIParent" 或是另一个登记过的 key。
local function ParentOf(key)
    if not key or key == "UIParent" then return UIParent, "UIParent" end
    local other = entries[key]
    if other and other.frame then return other.frame, key end
    return UIParent, "UIParent"
end

local function Stored(entry)
    if not entry.store then return nil end
    local ok, value = pcall(entry.store)
    if ok then return value end
    return nil
end

local function ApplyOne(entry)
    local frame = entry.frame
    if not frame then return end

    local stored = Stored(entry) or {}
    local default = entry.default or {}
    local point = stored.point or default.point or "CENTER"
    local relativePoint = stored.relativePoint or default.relativePoint or point
    local parent, parentKey = ParentOf(stored.relativeTo or default.relativeTo)
    local x = stored.x or default.x or 0
    local y = stored.y or default.y or 0

    -- 父框没解析出来时退回屏幕：这时相对点必须跟点一致，否则会差出半个框。
    if parent == UIParent and parentKey ~= (stored.relativeTo or default.relativeTo or "UIParent") then
        relativePoint = point
    end

    frame:ClearAllPoints()
    frame:SetPoint(point, parent, relativePoint, x, y)
end

local function ApplyTree(key, seen)
    local entry = entries[key]
    if not entry or seen[key] then return end
    seen[key] = true

    local stored = Stored(entry) or {}
    local parentKey = stored.relativeTo or (entry.default and entry.default.relativeTo)
    if parentKey and parentKey ~= "UIParent" and entries[parentKey] then
        ApplyTree(parentKey, seen)
    end
    ApplyOne(entry)
end

--- 摆好一个框（会先摆它相对的那个框）。
function Mover:Apply(key)
    if key then
        ApplyTree(key, {})
    else
        local seen = {}
        for k in pairs(entries) do ApplyTree(k, seen) end
    end
end

--- 摆好一个组（单位框架、动作条……位置互相独立的组）。
function Mover:ApplyGroup(group)
    local seen = {}
    for key, entry in pairs(entries) do
        if entry.group == group then ApplyTree(key, seen) end
    end
end

--- 记住一个框现在的位置（吸附之后），并摆好。
function Mover:Store(key)
    local entry = entries[key]
    local frame = entry and entry.frame
    if not frame then return end

    local left, bottom, width, height = Rect(frame)
    if not left then return end

    local rect = { left, bottom, width, height }
    SnapRect(rect, entry)

    local stored = Stored(entry)
    local parent, parentKey = ParentOf(stored and stored.relativeTo)
    local pl, pb, pw, ph = Rect(parent)
    if not pl then pl, pb, pw, ph = 0, 0, UIParent:GetWidth() or 0, UIParent:GetHeight() or 0 end

    local point, relativePoint, x, y = ChoosePair(rect, { pl, pb, pw, ph })
    x, y = Math:Round(x, 2), Math:Round(y, 2)

    if stored then
        stored.point = point
        stored.relativeTo = parentKey
        stored.relativePoint = relativePoint
        stored.x = x
        stored.y = y
    end

    frame:ClearAllPoints()
    frame:SetPoint(point, parent, relativePoint, x, y)
end

--- 回到默认位置（只清位置字段，不动同表里的宽度、颜色等设置）。
function Mover:Reset(key)
    local entry = entries[key]
    local stored = entry and Stored(entry)
    if stored then
        stored.point, stored.relativeTo, stored.relativePoint, stored.x, stored.y = nil
    end
    self:Apply(key)
end

--- 这个组锁了没有。单组的锁优先，否则看全局。
function Mover:IsLocked(group)
    local cfg = MoverConfig()
    local locks = cfg.locks
    local value = locks and group and locks[group]
    if value == nil then value = cfg.locked end
    return value and true or false
end

function Mover:SetLocked(group, locked)
    local db = ns:DB()
    local cfg = db and db.mover
    if not cfg then return end
    cfg.locks = cfg.locks or {}
    if group == nil then
        cfg.locked = locked and true or false
    else
        cfg.locks[group] = locked and true or false
    end
end

--- 拖动：受保护的框战斗里不能动，直接不响应（锁本身不碰框，所以解锁随时有效）。
local function InstallDrag(entry)
    local frame = entry.frame
    if not frame or type(frame.SetMovable) ~= "function" then return end

    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnDragStart", function(self)
        if Mover:IsLocked(entry.group) then return end
        if self.IsProtected and self:IsProtected()
           and type(InCombatLockdown) == "function" and InCombatLockdown() then
            return
        end
        self:StartMoving()
        -- 和别人的编辑模式浮层互相让路（LibEditMode 的约定，装了才触发）
        if type(EventRegistry) == "table" and type(EventRegistry.TriggerEvent) == "function" then
            pcall(EventRegistry.TriggerEvent, "EditModeExternal.hideDialog")
        end
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Mover:Store(entry.key)
        Mover:ApplyGroup(entry.group)
    end)
end

--- 把一个框交给位置服务。
--   opts.group    锁的分组（"unitframes" / "actionbars" / "minimap"……）
--   opts.default  { point, relativeTo, relativePoint, x, y }，没有存过位置时用
--   opts.store    返回存位置的那张表（一般就是 SavedVariables 里的子表）
function Mover:Register(frame, key, opts)
    if not frame or not key then return end
    opts = opts or {}

    local entry = entries[key]
    if not entry then
        entry = { key = key }
        entries[key] = entry
    end

    entry.frame = frame
    entry.label = opts.label or key
    entry.group = opts.group or "general"
    entry.store = opts.store
    entry.default = opts.default
    entry.isVisible = opts.isVisible

    InstallDrag(entry)
    self:Apply(key)
    return entry
end

function Mover:Unregister(key)
    local entry = entries[key]
    if not entry then return end
    entries[key] = nil
end

--- 读一个框登记的 entry（诊断用）。
function Mover:Get(key)
    return entries[key]
end
