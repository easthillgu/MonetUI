-- Modules/Tools/DevTools.lua
-- 只读探针命令入口（任务 #10 缺口 G1/G2/G5/G6 的实现体）。
--
-- 硬约束（对齐 AGENTS.md「验证」与污染模型，逐条自检过）：
--   * **只读**：不写任何帧的属性/显隐/几何，不往暴雪对象挂字段（簿记全走 ns:Marked 旁表读），
--     不挂 HookScript / hooksecurefunc，不建 ticker / OnUpdate。
--   * 任何 `Get*` 都 pcall + 可读性判定；**游戏来的字符串进 concat/format 前必须过
--     `Secrets.CanRead`**（判例：机密串的 `type()` 照样是 "string"）。
--   * 长输出**必须同时落 SavedVariables 账本**（聊天框只留十几行）；账本写入比 /reload
--     晚 1–2 分钟，帮助文本里写明。
--   * 命令本体不做受保护写，因此战斗中调用同样安全；但读数会受受限窗口影响，
--     读不出的值记成 nil（"读不出"），不当 0、不当假。
--
-- 提供：
--   /mui perf                  → MonetUIDB.perfReport
--   /mui skins closes          → MonetUIDB.closeReport
--   /mui skins inset           → MonetUIDB.insetReport
--   /mui skins arrows          → MonetUIDB.arrowReport
-- 供 Modules/Skins/Skins.lua 的 HandleCommand 转调（OnSlash 也接顶层 `perf`，见 Core 分发）。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Widget  = ns.Widget

local MAX_NODES = 20000   -- 全量走的步数上限（与 Utils/Compat.lua:Find 同口径，12.1.5 实测一趟 15895 框）
local PRINT_CAP = 8       -- 聊天框预算：超出的部分只进账本
local LEDGER_DELAY = "全量已存 MonetUIDB.%s —— 写入比 /reload 晚 1–2 分钟，别立刻读（登出后再读最稳）"

-- ---------------------------------------------------------------------------
-- 小工具：安全读值（全部 pcall + Secrets 漏斗，读不出返回 nil）

local function ReadAlpha(obj)
    if not obj or type(obj.GetAlpha) ~= "function" then return nil end
    local ok, v = pcall(obj.GetAlpha, obj)
    if not ok or type(v) ~= "number" then return nil end
    if not Secrets.CanRead(v) then return nil end
    return v
end

--- 有效 alpha：沿父链把 GetAlpha 连乘（4323a1b 的判例就是"单点 α1 但父容器 α0"，
--- 单读一个框的 GetAlpha 会骗人）。链上任何一环读不出 → complete=false，
--- 乘出来的只是**下界口径的部分积**，调用方必须把"读不出"和"是 0"分开报。
local function EffAlpha(obj)
    local product, complete, seen = 1, true, 0
    local node = obj
    for _ = 1, 12 do
        if not node then break end
        local a = ReadAlpha(node)
        if a == nil then complete = false else product = product * a end
        seen = seen + 1
        if seen >= 12 then complete = false end
        local okP, parent
        if type(node.GetParent) == "function" then
            okP, parent = pcall(node.GetParent, node)
        end
        if not okP or parent == nil or parent == node then break end
        node = parent
    end
    if not complete then return product, false end
    return product, true
end

--- 框名：匿名是常态（12.x 一大批控件本来就是匿名 CreateFrame），nil 就照实 nil。
local function SafeName(obj)
    if not obj or type(obj.GetName) ~= "function" then return nil end
    local ok, name = pcall(obj.GetName, obj)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    if not Secrets.CanRead(name) then return "<不可读>" end
    return name
end

--- 对象一句话标识：有名报名，无名报最近的有名祖先（"（匿名·寄于 X）"）。
local function LabelOf(obj)
    local name = SafeName(obj)
    if name then return name end
    local node = obj
    for _ = 1, 4 do
        if not node or type(node.GetParent) ~= "function" then break end
        local okP, parent = pcall(node.GetParent, node)
        if not okP or not parent or parent == node then break end
        local pname = SafeName(parent)
        if pname then return "（匿名·寄于 " .. pname .. "）" end
        node = parent
    end
    return "（匿名）"
end

local function ReadObjectType(obj)
    if not obj or type(obj.GetObjectType) ~= "function" then return nil end
    local ok, t = pcall(obj.GetObjectType, obj)
    if ok and type(t) == "string" and Secrets.CanRead(t) then return t end
    return nil
end

local function ReadAtlas(tex)
    if not tex or type(tex.GetAtlas) ~= "function" then return nil end
    local ok, a = pcall(tex.GetAtlas, tex)
    if ok and type(a) == "string" and a ~= "" and Secrets.CanRead(a) then return a end
    return nil
end

local function ReadPath(tex)
    if not tex or type(tex.GetTexture) ~= "function" then return nil end
    local ok, p = pcall(tex.GetTexture, tex)
    if ok and type(p) == "string" and p ~= "" and Secrets.CanRead(p) then return p end
    return nil
end

local function ReadRotation(tex)
    if not tex or type(tex.GetRotation) ~= "function" then return nil end
    local ok, r = pcall(tex.GetRotation, tex)
    if not ok or type(r) ~= "number" or not Secrets.CanRead(r) then return nil end
    return r
end

--- UV 是否翻转（`Widget:Arrow` 的 down 档走**双轴镜像**而不是 SetRotation，得读回来）。
--- 本客户端 `GetTexCoord()` 返回 8 个角点（ulX ulY llX llY urX urY lrX lrY，docs/api 为准，
--- 不是老的四元 left/right/top/bottom）：横向翻 = urX<ulX，纵向翻 = llY<ulY，
--- 两个同时为真 = 精确 180°（就是 down 档那一发）。返回 (任一翻转, 8 元组, {u=,v=})。
local function ReadFlipped(tex)
    if not tex or type(tex.GetTexCoord) ~= "function" then return nil, nil, nil end
    local ok, ulX, ulY, llX, llY, urX, urY, lrX, lrY = pcall(tex.GetTexCoord, tex)
    local nums = { ulX, ulY, llX, llY, urX, urY, lrX, lrY }
    if not ok then return nil, nil, nil end
    for i = 1, 8 do
        if type(nums[i]) ~= "number" or not Secrets.CanRead(nums[i]) then return nil, nil, nil end
    end
    local flipU = urX < ulX
    local flipV = llY < ulY
    return (flipU or flipV), nums, { u = flipU and true or nil, v = flipV and true or nil }
end

--- EnumerateFrames + 子树遍历（Compat:Find 同一条路）。visit 自己负责 pcall 之外的分类，
--- 计数上限统一在这里管。
local function Scan(visit)
    local bag = { n = 0, done = setmetatable({}, { __mode = "k" }) }
    if type(_G.EnumerateFrames) ~= "function" then return bag, "EnumerateFrames 不存在，扫不了全量" end
    local function walk(frame, depth)
        if bag.n >= MAX_NODES or depth > 14 then return end
        bag.n = bag.n + 1
        local ok, err = pcall(visit, frame, bag)
        if not ok then bag.errors = (bag.errors or 0) + 1 end
        if type(frame.GetChildren) ~= "function" then return end
        local okK, kids = pcall(frame.GetChildren, frame)
        if not okK or type(kids) ~= "table" then return end
        for i = 1, #kids do
            local c = kids[i]
            if c and not bag.done[c] then
                bag.done[c] = true
                walk(c, depth + 1)
            end
        end
    end
    local ok0, first = pcall(_G.EnumerateFrames)
    local frame = ok0 and first or nil
    while frame do
        if not bag.done[frame] then
            bag.done[frame] = true
            walk(frame, 0)
        end
        if bag.n >= MAX_NODES then break end
        local okN, nxt = pcall(_G.EnumerateFrames, frame)
        if not okN or nxt == frame then break end
        frame = nxt
    end
    return bag, nil
end

local function Stamp()
    if type(_G.date) == "function" then
        local ok, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
        if ok then return s end
    end
    return nil
end

--- 账本落盘：失败要把原因打出来（Compat/Color 两本的教训——"读不到"得能归因）。
local function SaveLedger(key, data)
    if type(ns.DB) ~= "function" then return false, "ns:DB 不可用" end
    local ok, db = pcall(function() return ns:DB() end)
    if not ok or type(db) ~= "table" then return false, "账本没打开" end
    local okSet, err = pcall(function() db[key] = data end)
    if not okSet then return false, tostring(err) end
    return true
end

local function SaySaved(key)
    ns:Print((LEDGER_DELAY):format(key))
end

-- ---------------------------------------------------------------------------

local DevTools = { name = "DevTools" }

-- ---------------------------------------------------------------------------
-- /mui perf —— 调度器总账（计划文档阶段 3 第 5 条欠的项）
-- 读 Utils/Scheduler.lua 的现成数据面（Count / Snapshot，a9cbc512 落地）；
-- pollDriver 门命中数读 `Widget:PrintStalled()` 的**返回值**（此刻暂停中的框数），
-- 它会顺带把自己那本清单打到聊天框——照旧，不劫持它的输出。

function DevTools:Perf()
    local S = ns.Scheduler
    if type(S) ~= "table" then
        ns:Print("Scheduler 没加载，perf 读不到。")
        return
    end

    local totals, rows
    if type(S.Count) == "function" then
        local okC, _, t = pcall(S.Count, S)
        if okC then totals = t end
    end
    if type(S.Snapshot) == "function" then
        local okS, r = pcall(S.Snapshot, S)
        if okS then rows = r end
    end
    if type(rows) ~= "table" then rows = {} end

    local okKb, kb = pcall(_G.collectgarbage, "count")
    local stalled, stallErr
    if type(Widget) == "table" and type(Widget.PrintStalled) == "function" then
        local okP, n = pcall(Widget.PrintStalled, Widget)
        if okP then stalled = n else stallErr = tostring(n) end
    else
        stallErr = "Widget.PrintStalled 不可用"
    end

    table.sort(rows, function(a, b)
        local ac = (a and a.cost) or -1
        local bc = (b and b.cost) or -1
        return ac > bc
    end)

    local report = {
        when = Stamp(),
        totals = totals,
        subs = rows,
        luaKB = (okKb and type(kb) == "number") and kb or nil,
        stalledFrames = stalled,
        stallError = stallErr,
        note = "stalledFrames = 此刻被 pollDriver 门暂停的框数（累计命中次数没有现成计数器）",
    }
    local saved = SaveLedger("perfReport", report)

    if type(totals) == "table" then
        ns:Print(("调度器：在册 %s · 等一拍 %s · 累计调用 %s · 累计耗时 %s · 失败 %s"):format(
            tostring(totals.running), tostring(totals.pending),
            tostring(totals.calls), tostring(totals.cost), tostring(totals.failures)))
    else
        ns:Print("Scheduler:Count 读不出（数据面不在？）。")
    end
    ns:Print(("Lua 内存 %.0f KB · 轮询暂停中 %s"):format(
        (okKb and type(kb) == "number") and kb or -1, tostring(stalled)))
    for i = 1, math.min(#rows, PRINT_CAP) do
        local row = rows[i]
        ns:Print(("  #%s %s · 调用 %s · 累计 %.3fs · 峰值 %.3fs · 失败 %s"):format(
            tostring(row.id), row.everyFrame and "每帧" or (("%.3fs"):format((row.intervalSec or 0))),
            tostring(row.calls), (row.cost or 0), (row.max or 0), tostring(row.failures)))
    end
    if #rows > PRINT_CAP then
        ns:Print(("  …另有 %d 路，全量在账本"):format(#rows - PRINT_CAP))
    end
    if saved then SaySaved("perfReport") else ns:Print("|cffff6b6b账本落盘失败|r") end
end

-- ---------------------------------------------------------------------------
-- /mui skins closes 的实现放在箭头探针那一节之后（要用 `RegionsOf` / `FindIn`，
-- 文件内局部函数只能往下看得到；两个探针读的本来就是同一批 region）。

-- ---------------------------------------------------------------------------
-- /mui skins inset —— 批量列凹槽容器的**有效 alpha**（G5）
-- 名单来源：Skins 面板 registry 的 entry.frames（点路径），逐个解析后取
-- `Skin:FindInset`（字段 .Inset 或同名全局 <窗口名>Inset，与换肤走同一条判定）。
-- 有效 alpha = 容器父链连乘（单点 GetAlpha 会被父 α0 骗，MerchantFrame 判例）；
-- 我们的背板（旁表 skinPlate）挂在窗口直下，一并数进这一行。
-- 懒建窗口没显示过时解析不到——那行照实记 unresolved，不算通过也不算失败。

function DevTools:SkinsInset()
    local Skin = ns.Skin
    local SK = ns.GetModule and ns:GetModule("Skins")
    local registry = type(SK) == "table" and SK.registry
    if type(registry) ~= "table" then
        ns:Print("Skins 面板 registry 读不到，inset 探针没有名单。")
        return
    end
    if type(Skin) ~= "table" or type(Skin.FindInset) ~= "function" then
        ns:Print("Skin.FindInset 不可用。")
        return
    end

    local done = setmetatable({}, { __mode = "k" })
    local rows, lowCount, unreadable = {}, 0, 0
    local unresolved, blocked, noInset = 0, 0, 0
    for _, entry in ipairs(registry) do
        local paths = entry and entry.frames
        if type(paths) == "table" then
            for _, path in ipairs(paths) do
                if type(path) == "string" and path ~= "" then
                    local okR, obj = pcall(ns.ResolveObject, path)
                    if not okR or type(obj) ~= "table" or type(obj.IsVisible) ~= "function" then
                        -- 懒建窗口没被打开过 → 全局里根本没有这个对象：记 unresolved，不算通过也不算失败
                        unresolved = unresolved + 1
                    else
                        local okRead, readable = true, true
                        if Widget and type(Widget.Readable) == "function" then
                            okRead, readable = pcall(Widget.Readable, Widget, obj)
                        end
                        if not okRead or not readable then
                            blocked = blocked + 1   -- 这一趟碰不了（forbidden / 受限窗口），下一趟再读
                        else
                            local okI, inset = pcall(Skin.FindInset, Skin, obj)
                            if not okI or not inset then
                                noInset = noInset + 1   -- 解析到了但这个名字下没有凹槽（按钮/页签一类）
                            elseif not done[inset] then
                                done[inset] = true
                                local eff, complete = EffAlpha(inset)
                                local plates, plateLow, plateUnread = 0, 0, 0
                                if type(obj.GetChildren) == "function" then
                                    local okK, kids = pcall(obj.GetChildren, obj)
                                    if okK and type(kids) == "table" then
                                        for i = 1, #kids do
                                            local c = kids[i]
                                            if c and ns:Marked(c, "skinPlate") then
                                                plates = plates + 1
                                                -- EffAlpha 的第一个返回值恒为数字（读不出的环节按 1 计），
                                                -- 所以"读不出"只能看第二个返回值 complete。
                                                local ca, cOk = EffAlpha(c)
                                                if not cOk then
                                                    plateUnread = plateUnread + 1
                                                elseif ca < 0.99 then
                                                    plateLow = plateLow + 1
                                                end
                                            end
                                        end
                                    end
                                end
                                local row = {
                                    panel = entry.key, path = path,
                                    inset = LabelOf(inset),
                                    effAlpha = eff, readable = complete,
                                    plates = plates, plateLow = plateLow, plateUnread = plateUnread,
                                }
                                rows[#rows + 1] = row
                                if not complete then
                                    unreadable = unreadable + 1
                                elseif eff < 0.99 or plateLow > 0 then
                                    lowCount = lowCount + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        local av = a.readable and (a.effAlpha or 0) or -1
        local bv = b.readable and (b.effAlpha or 0) or -1
        return av < bv
    end)

    local report = {
        when = Stamp(), sites = #rows, low = lowCount,
        unreadable = unreadable, unresolvedPaths = unresolved,
        blockedPaths = blocked, noInsetPaths = noInset, rows = rows,
        note = "sites=探到的凹槽容器数（43 是代码接线数）；unresolved=懒建窗口没开过、对象还不存在；"
            .. "blocked=这一趟读不出（受限窗口/forbidden）；noInset=名字解析到了但下面没有凹槽控件。"
            .. "effAlpha 是「父链连乘」的有效值，不是单点 GetAlpha。",
    }
    local saved = SaveLedger("insetReport", report)

    ns:Print(("inset 批量：探到 %d 处 · |cffff6b6b有效 α<0.99|r %d · 父链读不全 %d · 没解析到 %d · 碰不了 %d · 无凹槽 %d"):format(
        #rows, lowCount, unreadable, unresolved, blocked, noInset))
    for i = 1, math.min(#rows, PRINT_CAP) do
        local row = rows[i]
        local state = row.readable and string.format("α=%.2f", (row.effAlpha or 0)) or "α 读不全"
        ns:Print(("  %s · %s · %s · 背板 %d（偏暗 %d · 读不出 %d）"):format(
            tostring(row.panel), tostring(row.inset), state,
            row.plates or 0, row.plateLow or 0, row.plateUnread or 0))
    end
    if #rows > PRINT_CAP then
        ns:Print(("  …另有 %d 处，全量在账本"):format(#rows - PRINT_CAP))
    end
    if saved then SaySaved("insetReport") else ns:Print("|cffff6b6b账本落盘失败|r") end
end

-- ---------------------------------------------------------------------------
-- /mui skins arrows —— stepper / 滚条 / 翻页箭头逐对象表（G2 + G3 的一半）
-- 认脸三条腿：名字片段（老式 Scroll*Button / *PageButton / Arrow）**或**任一 region 的 atlas
-- 带 scrollbar/arrow/chevron 味（12.x 步进钮的图**不在** GetNormalTexture 上，只读 normal 会整批判错）
-- **或**步进钮 mixin 的 `upTexture` / `normalTexture`（属性 + 字段两条都读，存在性即名单第 2 项的答案）。
-- 方向读回来：我们那张 monet_chevron/monet_arrow 的 rotation + UV 翻转 + alpha，
-- 旁边照抄暴雪原层（button.Texture / Overlay）的 alpha —— 一张表同时回答"朝哪边"和"原图压住没有"。

local ARROW_NEEDLES = {
    "scrollup", "scrolldown", "scrollleft", "scrollright",
    "upbutton", "downbutton", "leftbutton", "rightbutton",
    "backbutton", "forwardbutton", "prevpage", "nextpage", "arrow",
}
local ARROW_ATLASES = { "scrollbar", "scroll", "arrow", "chevron", "trip", "stepper" }
local ARROW_ATLASES = { "scrollbar", "scroll", "arrow", "chevron", "trip", "stepper" }
local ARROW_ROWS_CAP = 400
local ARROW_PER_SIDE = 4   -- 每个按钮每类最多记 4 个 region，够判"有没有 / 方向对不对"

--- 读暴雪按钮上 mixin 存进来的**字段**（`button.upTexture` = 图集键、`button.Texture` = 原图层）。
--- 先 rawget，取不到再走一次普通索引（元表提供的值 rawget 看不见）；两条都 pcall 包着，
--- forbidden 对象直接算"读不出"。字符串出栈前过 `Secrets.CanRead`。
local function FieldString(obj, key)
    if type(obj) ~= "table" then return nil end
    local okRaw, raw = pcall(rawget, obj, key)
    local v = okRaw and raw or nil
    if v == nil then
        local okI, got = pcall(function() return obj[key] end)
        if okI then v = got end
    end
    if type(v) ~= "string" or v == "" then return nil end
    if not Secrets.CanRead(v) then return "<不可读>" end
    return v
end

local function FieldObject(obj, key)
    if type(obj) ~= "table" then return nil end
    local okRaw, raw = pcall(rawget, obj, key)
    local v = okRaw and raw or nil
    if v == nil then
        local okI, got = pcall(function() return obj[key] end)
        if okI then v = got end
    end
    if type(v) == "table" then return v end
    return nil
end

--- 图集键 / 路径里能读出的方向意图——只为把"±π/2 到底朝哪边"变成一行可核对的对照，
--- 不是判据本身（判据要肉眼在同一个箭头上看）。
local function DirHint(text)
    if not text then return nil end
    local t = string.lower(text)
    if string.find(t, "left") then return "left" end
    if string.find(t, "right") then return "right" end
    if string.find(t, "bottom") or string.find(t, "down") then return "down" end
    if string.find(t, "top") or string.find(t, "up") then return "up" end
    return nil
end

--- `frame:GetRegions()` 返回**多返回值**，必须包成 table（照 Utils/Skin.lua:1132 的同一条坑）。
local function RegionsOf(frame)
    if type(frame) ~= "table" or type(frame.GetRegions) ~= "function" then return nil end
    local ok, list = pcall(function() return { frame:GetRegions() } end)
    if ok and type(list) == "table" then return list end
    return nil
end

--- 一只按钮上"可能是图"的全部候选：GetRegions 那一层 **加上** 四个具名贴图口
--- （normal / pushed / highlight / disabled）。
--- 两条腿缺一不可：真实客户端的 `GetRegions()` 不返回模板的具名贴图，而换肤恰好把我们的
--- 图挂在具名口上（`Skin:CloseButton` 换四张、`Skin:ScrollBar` 走 `TexOf(button,"GetNormalTexture")`）；
--- 反过来 12.x 步进钮的图只在 region 里（`Skin:ScrollArrowButton` 用 CreateTexture 补一张）。
--- 只读一条腿的结果就是"已换皮/仍是暴雪"两档互相漏报。
local ART_GETTERS = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }
local function ArtOf(frame, Skin)
    local list = {}
    local seen = setmetatable({}, { __mode = "k" })
    local function put(o)
        if type(o) == "table" and not seen[o] then
            seen[o] = true
            list[#list + 1] = o
        end
    end
    local regions = RegionsOf(frame)
    if regions then
        for i = 1, #regions do put(regions[i]) end
    end
    for i = 1, #ART_GETTERS do
        if Skin and type(Skin.TexOf) == "function" then
            put(Skin:TexOf(frame, ART_GETTERS[i]))
        elseif type(frame[ART_GETTERS[i]]) == "function" then
            local okG, got = pcall(frame[ART_GETTERS[i]], frame)
            if okG then put(got) end
        end
    end
    return list, regions ~= nil
end

local function ReadVertex(tex)
    if not tex or type(tex.GetVertexColor) ~= "function" then return nil end
    local ok, r, g, b, a = pcall(tex.GetVertexColor, tex)
    if not ok or type(r) ~= "number" then return nil end
    if not Secrets.CanRead(r) then return nil end
    return { r, g, b, a }
end

-- 我们自绘的箭头基图（Utils/Skin.lua 两条路都落在这两个键上：`Media:Texture` 直挂 或 `SwapArt`）。
local OUR_ARROW_KEYS = { "monet_chevron", "monet_arrow" }

local function IsOurArrowPath(path)
    if not path then return false end
    local p = string.lower(path)
    for i = 1, #OUR_ARROW_KEYS do
        if string.find(p, OUR_ARROW_KEYS[i]) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- /mui skins closes —— 按图集认脸的全量 ✕ 扫（G1）
--
-- 判据和换肤必须同一条：`Skin:CloseButtonByArt` 认的是 normal 贴图的 atlas 里有 `redbutton%-exit`，
-- `Skin:CloseButton` 一次换**四张**（normal/pushed/highlight/disabled），`Skin:FindAnonClose`
-- 认的是**任一 region** 带这个图集。所以这里逐 region 读——只看 normal 的那版会把"四张里漏一张"
-- 判成已换皮（`5f84a93` 那块实心方板就是这么漏的）。
-- 四档：我们的 monet_close_* 图 / 暴雪层仍可见（atlas 还在且 α>0）/ 暴雪层已压 0 / 减号
-- （`RedButton-MiniCondense`，**不该**换，数出来是防回归）。

local CLOSE_ROWS_CAP = 400
local CLOSE_PER_SIDE = 6

function DevTools:SkinsCloses()
    if type(_G.EnumerateFrames) ~= "function" then
        ns:Print("EnumerateFrames 不存在，✕ 探针扫不了全量。")
        return
    end

    local rows, skinnedCount, visibleCount, pressedCount, condenseCount = {}, 0, 0, 0, 0
    local unreadable, buttons = 0, 0

    local function visit(frame)
        if ReadObjectType(frame) ~= "Button" then return end
        buttons = buttons + 1
        if #rows >= CLOSE_ROWS_CAP then return end
        if Widget and type(Widget.Readable) == "function" then
            -- forbidden 框：连 GetName 都抛，挂进名单只是噪声（归 unreadable，不占行）
            local okRead, readable = pcall(Widget.Readable, Widget, frame)
            if not okRead or not readable then
                unreadable = unreadable + 1
                return
            end
        end

        local rawName = SafeName(frame)
        local lowerName = rawName and string.lower(rawName) or nil
        local arts, regionsReadable = ArtOf(frame, ns.Skin)

        local oursList, blizzList, isCondense
        for i = 1, #arts do
            local reg = arts[i]
            if type(reg) == "table" then
                local atlas = ReadAtlas(reg)
                local path = ReadPath(reg)
                local la = atlas and string.lower(atlas) or nil
                local lp = path and string.lower(path) or nil
                if lp and string.find(lp, "monet_close") then
                    oursList = oursList or {}
                    if #oursList < CLOSE_PER_SIDE then
                        oursList[#oursList + 1] = {
                            path = path, alpha = ReadAlpha(reg),
                            art = ns:Marked(reg, "art") and true or nil,
                        }
                    end
                elseif la and (string.find(la, "condense") or string.find(la, "minus")) then
                    isCondense = atlas
                elseif la and (string.find(la, "redbutton%-exit")
                    or string.find(la, "ui%-panel%-close") or string.find(la, "closebutton")) then
                    blizzList = blizzList or {}
                    if #blizzList < CLOSE_PER_SIDE then
                        blizzList[#blizzList + 1] = { atlas = atlas, alpha = ReadAlpha(reg) }
                    end
                end
            end
        end

        -- 名字这条腿兜住"region 读不出但确实是关闭钮"的那些：宁可多一行也别漏报
        local nameHit = lowerName and (string.find(lowerName, "close") or string.find(lowerName, "exit"))
        if not (oursList or blizzList or isCondense or nameHit) then return end

        local visible, pressed
        if blizzList then
            visible, pressed = 0, 0
            for i = 1, #blizzList do
                local a = blizzList[i].alpha
                if a == nil then
                    -- 读不出 alpha：单独算一层，不猜成"压住了"
                elseif a > 0.001 then
                    visible = visible + 1
                    visibleCount = visibleCount + 1
                else
                    pressed = pressed + 1
                    pressedCount = pressedCount + 1
                end
            end
        end

        rows[#rows + 1] = {
            label = LabelOf(frame),
            name = rawName,
            ours = oursList,
            blizzard = blizzList,
            visibleLayers = visible,
            pressedLayers = pressed,
            condense = isCondense,
            regionsReadable = regionsReadable,
        }
        if oursList then skinnedCount = skinnedCount + 1 end
        if isCondense then condenseCount = condenseCount + 1 end
    end

    local bag, scanErr = Scan(visit)
    table.sort(rows, function(a, b)
        return (a.visibleLayers or -1) > (b.visibleLayers or -1)
    end)

    local report = {
        when = Stamp(), walked = bag.n, visitErrors = bag.errors, buttons = buttons,
        closeButtons = #rows, skinned = skinnedCount,
        blizzardVisible = visibleCount, blizzardPressed = pressedCount,
        miniCondense = condenseCount, unreadable = unreadable,
        rows = rows, scanError = scanErr,
        note = "逐 region 判：ours=我们的 monet_close 几张；visibleLayers=还带 RedButton-Exit 族图集且 α>0 的张数"
            .. "（四张里漏一张就是这里 +1）；visibleLayers=nil 是 α 读不出。"
            .. "MiniCondense 是减号，不该换 ✕，数出来只防回归。",
    }
    local saved = SaveLedger("closeReport", report)

    ns:Print(("✕ 全量扫：走了 %d 框 · 按钮 %d · 认定关闭钮 %d · 我们的图 %d · 暴雪层 仍可见 |cffff6b6b%d|r · 已压 0 %d · 减号 %d · 读不出 %d"):format(
        bag.n, buttons, #rows, skinnedCount, visibleCount, pressedCount, condenseCount, unreadable))
    local printed = 0
    for i = 1, #rows do
        local row = rows[i]
        if (row.visibleLayers or 0) > 0 then
            if printed < PRINT_CAP then
                printed = printed + 1
                local first = row.blizzard and row.blizzard[1]
                ns:Print(("  |cffffa940漏层|r %s · 可见 %d · %s · 我们的 %d 张"):format(
                    tostring(row.label), row.visibleLayers or 0,
                    tostring(first and first.atlas or "-"),
                    row.ours and #row.ours or 0))
            end
        else
            break   -- rows 按 visibleLayers 降序排过：第一个 0 之后不会再有
        end
    end
    if printed > 0 then
        local more = 0
        for i = 1, #rows do if (rows[i].visibleLayers or 0) > 0 then more = more + 1 end end
        ns:Print(("  —— 前 %d 只（共 %d 只仍挂可见的暴雪 ✕ 层），全量在账本 closeReport.rows"):format(
            printed, more))
    else
        ns:Print("  没有一只还挂着可见的暴雪 ✕ 层（已换皮 / 已压 0 的名单在账本）。")
    end
    if condenseCount > 0 then
        ns:Print(("  减号 %d 只（RedButton-MiniCondense 一族，按口径不该换 ✕）"):format(condenseCount))
    end
    if saved then SaySaved("closeReport") else ns:Print("|cffff6b6b账本落盘失败|r") end
end

function DevTools:SkinsArrows()
    -- 不借 Skin:TexOf：新式步进钮的图不在 GetNormalTexture 上，直接读按钮的 region 才看得全。
    if type(_G.EnumerateFrames) ~= "function" then
        ns:Print("EnumerateFrames 不存在，箭头探针扫不了全量。")
        return
    end

    local rows, ours, leak, pressed, stepper, unreadable = {}, 0, 0, 0, 0, 0
    local function nameHit(lowerName)
        if not lowerName then return false end
        for i = 1, #ARROW_NEEDLES do
            if string.find(lowerName, ARROW_NEEDLES[i]) then return true end
        end
        return false
    end

    local function atlasHit(lowerAtlas)
        if not lowerAtlas then return false end
        for i = 1, #ARROW_ATLASES do
            if string.find(lowerAtlas, ARROW_ATLASES[i]) then return true end
        end
        return false
    end

    --- 一个 region 的一句话读数（三态里"我们的那一张"到底被转成了什么方向，全在这几项上）。
    local function RegionRow(reg)
        local anyFlip, uv, axes = ReadFlipped(reg)
        return {
            atlas = ReadAtlas(reg),
            path = ReadPath(reg),
            art = ns:Marked(reg, "art") and true or nil,
            rotation = ReadRotation(reg),
            uvFlipped = anyFlip and true or nil,
            uvAxes = axes,
            uv = uv,
            alpha = ReadAlpha(reg),
            color = ReadVertex(reg),
        }
    end

    --- "朝哪边"的两半读数：rotation（SetRotation 的角度）+ UV 镜像轴向。
    local function UvText(one)
        if not one.uvFlipped then return "uv正" end
        local ax = one.uvAxes or {}
        if ax.u and ax.v then return "uv双翻=180°" end
        if ax.u then return "uv横翻" end
        return "uv纵翻"
    end

    local function visit(frame)
        if ReadObjectType(frame) ~= "Button" then return end
        if #rows >= ARROW_ROWS_CAP then return end
        if Widget and type(Widget.Readable) == "function" then
            -- forbidden 框从一开始就读不出：挂进账本只会变成长期空转的一行
            local okRead, readable = pcall(Widget.Readable, Widget, frame)
            if not okRead or not readable then return end
        end

        local rawName = SafeName(frame)
        local lowerName = rawName and string.lower(rawName) or nil

        -- 新式步进钮的两条腿：state driver 属性 `upTexture`，和 mixin 存在按钮**字段**上的图集键
        -- （`button.upTexture` / `button.normalTexture`，名单第 2 项问的就是它）。
        -- 值是 `...-top/-bottom/-left/-right`，正好当方向对照的那一半。
        local okAttr, attr = pcall(function()
            if type(frame.GetAttribute) ~= "function" then return nil end
            return frame:GetAttribute("upTexture")
        end)
        local attrKey = (okAttr and type(attr) == "string" and Secrets.CanRead(attr)) and attr or nil
        local fieldKey = FieldString(frame, "upTexture") or FieldString(frame, "normalTexture")
        local stepperKey = attrKey or fieldKey

        -- 图两条腿都要读：新式步进钮的图只在 region（`Skin:ScrollArrowButton` 用 CreateTexture
        -- 补一张、暴雪原图压 alpha 0），老式滚条 / 翻页的图在**具名贴图口**上（`Skin:ScrollBar`
        -- 走 `TexOf(button, "GetNormalTexture")` + SwapArt，而具名贴图不进 GetRegions）。
        -- 只读一条腿就会把另一条腿已经换好皮的判成"读不出"。
        local ourList, blizzList
        local arts, regionsReadable = ArtOf(frame, ns.Skin)
        for i = 1, #arts do
            local reg = arts[i]
            if type(reg) == "table" and ReadObjectType(reg) == "Texture" then
                local atlas = ReadAtlas(reg)
                local path = ReadPath(reg)
                local isOurs = IsOurArrowPath(path)
                if isOurs or atlasHit(atlas and string.lower(atlas)) then
                    local one = RegionRow(reg)
                    local into
                    if isOurs then
                        into = ourList
                        if not into then into = {} ourList = into end
                    else
                        into = blizzList
                        if not into then into = {} blizzList = into end
                    end
                    if #into < ARROW_PER_SIDE then into[#into + 1] = one end
                end
            end
        end

        if not (nameHit(lowerName) or stepperKey ~= nil or ourList or blizzList) then return end

        rows[#rows + 1] = {
            label = LabelOf(frame),
            name = rawName,
            stepperKey = stepperKey,
            dirHint = DirHint(stepperKey),
            ourArrows = ourList,
            blizzardArrows = blizzList,
            origAlpha = ReadAlpha(FieldObject(frame, "Texture")),
            overlayAlpha = ReadAlpha(FieldObject(frame, "Overlay")),
            regionsReadable = regionsReadable,
        }

        if stepperKey ~= nil then stepper = stepper + 1 end
        if ourList then ours = ours + #ourList end
        if blizzList then
            for i = 1, #blizzList do
                local a = blizzList[i].alpha
                if a == nil then
                    unreadable = unreadable + 1
                elseif a > 0.001 then
                    leak = leak + 1        -- 暴雪原图还看得见 = 这一层的压制没落地
                else
                    pressed = pressed + 1
                end
            end
        elseif not regionsReadable then
            -- 有名字/属性像是箭头钮，但 GetRegions 读不出：记一笔，别当"没有箭头"
            unreadable = unreadable + 1
        end
    end

    local bag, scanErr = Scan(visit)
    local report = {
        when = Stamp(), walked = bag.n, count = #rows,
        ourArrows = ours, blizzardVisible = leak, blizzardPressed = pressed,
        stepperAttrs = stepper, unreadable = unreadable,
        rows = rows, scanError = scanErr,
        note = "基图朝上：rotation=0 且未翻转=上；uvFlipped=下（双轴镜像=180°）；左右靠 ±1.5708"
            .. "（本仓按「逆时针」推：left=+π/2、right=-π/2，未实机证实）。"
            .. "对照 stepperKey 自带的 -top/-bottom/-left/-right 与 rotation，肉眼在同一支箭头上定方向。"
            .. "blizzardVisible>0 = 暴雪原图没压住（漏层）；origAlpha/overlayAlpha 读的是 button.Texture / Overlay 两层。",
    }
    local saved = SaveLedger("arrowReport", report)

    ns:Print(("箭头逐对象：走了 %d 框 · 命中 %d · 我们的箭头 %d · 暴雪层 仍可见 |cffff6b6b%d|r · 已压 0 %d · stepper %d · 读不出 %d"):format(
        bag.n, #rows, ours, leak, pressed, stepper, unreadable))
    for i = 1, math.min(#rows, PRINT_CAP) do
        local row = rows[i]
        local oursTxt = "无我们的图"
        if row.ourArrows then
            local one = row.ourArrows[1]
            oursTxt = string.format("%d 张 rot=%s %s α=%s", #row.ourArrows,
                (one.rotation and string.format("%.3f", one.rotation)) or "?",
                UvText(one),
                (one.alpha and string.format("%.2f", one.alpha)) or "?")
        end
        local blizzTxt = "无暴雪箭头层"
        if row.blizzardArrows then
            local one = row.blizzardArrows[1]
            blizzTxt = string.format("暴雪层 %d α=%s", #row.blizzardArrows,
                (one.alpha and string.format("%.2f", one.alpha)) or "?")
        end
        ns:Print(("  %s · 键=%s(%s) · %s · %s · 原层 α=%s"):format(
            tostring(row.label), tostring(row.stepperKey or "-"), tostring(row.dirHint or "-"),
            oursTxt, blizzTxt,
            (row.origAlpha and string.format("%.2f", row.origAlpha)) or (row.regionsReadable and "-" or "?")))
    end
    if #rows > PRINT_CAP then
        ns:Print(("  …另有 %d 行，全量在账本"):format(#rows - PRINT_CAP))
    end
    if saved then SaySaved("arrowReport") else ns:Print("|cffff6b6b账本落盘失败|r") end
end

-- ---------------------------------------------------------------------------
-- 顶层 `/mui perf` 的接入口（Core 的分发在认不出命令时先来这问一次，见 Core.lua）。

--- Skins 三探针的统一转接口（`Modules/Skins/Skins.lua` 的 HandleCommand 调这里，
--- 免得到处 `if sub == ...` 分叉；探针本体都在上面）。
function DevTools:SkinsProbe(which)
    if which == "closes" then
        self:SkinsCloses()
    elseif which == "inset" then
        self:SkinsInset()
    elseif which == "arrows" then
        self:SkinsArrows()
    end
end

--- Core 的模块名兜底走这里：`/mui devtools perf|closes|inset|arrows`，
--- 和顶层 `/mui perf`、`/mui skins <探针>` 互为别名（本体只有一份）。
function DevTools:HandleCommand(rest)
    local arg = string.lower(rest or "")
    if arg == "perf" then
        self:Perf()
        return true
    end
    if arg == "closes" or arg == "inset" or arg == "arrows" then
        self:SkinsProbe(arg)
        return true
    end
    if arg == "" then
        ns:Print("用法：/mui perf · /mui skins closes|inset|arrows ·（同义：/mui devtools <子命令>）。")
        return true
    end
    return false
end

function DevTools:OnSlash(command, rest)
    local c = string.lower(command or "")
    local r = string.lower(rest or "")
    if c == "perf" then
        self:Perf()
        return true
    end
    -- 顺路兼容 `/mui skins <探针>`（真正的注册在 Skins:HandleCommand，这里只是兜底直连）。
    if c == "skins" and (r == "closes" or r == "inset" or r == "arrows") then
        self:SkinsProbe(r)
        return true
    end
    return false
end

function DevTools:Initialize()
    -- 无状态探针：不注册事件、不建帧、不开定时——上线日敲一次动一次。
end

ns:Register("DevTools", DevTools)
