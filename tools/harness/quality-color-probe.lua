-- tools/harness/quality-color-probe.lua
-- 品质色（`Skin:QualityColor`）的**离线断言探针**，不是发行码：toc / Utils.xml 都不收它，
-- 游戏里永远不会加载。
--
-- 怎么跑（任选一条，仓库根目录执行）：
--     node tools/quality-color-probe.js                    ← 推荐，和其它闸门同一个入口
--     lua tools/harness/quality-color-probe.lua            ← 直接喂本机 Lua 解释器
--     lua tools/harness/quality-color-probe.lua ..\..\Utils\Skin.lua
-- 退出码：全过 0，任何一条失败 1。
--
-- 它验的是什么（上线前 #14 交付的判据，逐条对得上交付说明）：
--   1. 品质色全仓**只有一个来源**：`Utils/Skin.lua` 的 memo；`Modules/Bags/Bags.lua` 不再自带表。
--   2. **唯一形状 = 命名字段** `{ r=, g=, b= }`；位置索引 `[1]/[2]/[3]` 一律为空。
--   3. **同一品质返回同一张表**（引用稳定）—— 驱动帧靠 `color ~= entry.last` 判变化，
--      Bags 的 hover 闭包按引用透传；每次现造新表 = 每 0.5 秒重涂一遍全部边框。
--   4. 六档兜底数值与改动前**逐位相等**（OLD 表就是从上一版源码里抠出来的那六个数）。
--   5. 客户端答不上来的**每一条**路都落兜底：没有 C_Item / 没有这个方法 / 抛错 /
--      返回一张表（不是三个数）/ 数字越界 / 分量读不出；离线没有 Secrets 层也照跑。
--   6. 0 / 1 / 8 / nil 品质 = 素边（返回 nil），机密品质不当表键。
--   7. 顺带钉住 Bags 的 tipPrev 簿记（提示框原色）：存之前四个分量全过 `Secrets.Number`，
--      读不出就不存不还原；只给三个值时 alpha 补 1。守卫在 OnEnter 闭包里切不出来，
--      所以这一段是**镜像 + 源码钉**（同 tools/test-mult.js 的办法）。
--
-- 为什么不 use `tools/harness/api_stub.lua`：那是 harness 道正在改的文件（同文件不双写），
-- 本探针自带最小桩。等正式替身层交付后，可以把它接上来当第二数据源。
--
-- 实现取舍：本探针**不加载整个 Skin.lua**（那需要 Widget / Media / EventBus / 暴雪帧替身一整套），
-- 而是按标记行从源码里切出品质色那一段（`local Secrets = ns.Secrets` → `Skin:QualityColor` 的 `end`），
-- 塞进 `local ns, Skin, C_Item, Widget = ...` 的头再编译。这样跑的就是**发行码本身的那几行**，
-- 而切不出标记（有人搬动或改名了）时直接判失败，不会静默空跑。
-- 语法只用 Lua 5.1 也有的东西（`load` 收字符串、无 `//`、无 `goto`、无 `table.unpack`）。

local probePath = arg and arg[0] or ...
local explicit = arg and arg[1]

local function norm(p) return (p or ""):gsub("\\", "/") end

--- 仓库根：探针在 <root>/tools/harness/ 下；显式传过 Skin.lua 路径就跳过这步。
local function RepoRoot()
    local p = norm(probePath)
    local i = p:find("tools/harness/quality%-color%-probe.lua$", 1)
    if i then return p:sub(1, i - 1) end
    return "./"
end

local root = RepoRoot()
local skinPath = explicit or (root .. "Utils/Skin.lua")
local bagsPath = root .. "Modules/Bags/Bags.lua"

local function ReadFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local skinSrc = ReadFile(skinPath)
if not skinSrc then
    print("[FAIL] 读不到 " .. tostring(skinPath) .. "（在工作树根目录跑，或把它当第一个参数传进来）")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
--  1) 从源码里切出品质色那一段
-- ---------------------------------------------------------------------------
local lines = {}
for line in (skinSrc .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
end

local function FindLine(pred, from)
    for i = from or 1, #lines do
        if pred(lines[i]) then return i end
    end
    return nil
end

local iSecrets = FindLine(function(l) return l:match("^local Secrets = ns%.Secrets") end)
local iFallback = FindLine(function(l) return l:match("^local QUALITY_FALLBACK = ") end)
local iReturn = FindLine(function(l) return l:match("^    return QUALITY_COLOR%[n%]") end)
local iEnd = iReturn and FindLine(function(l) return l == "end" end, iReturn)

if not (iSecrets and iFallback and iReturn and iEnd) or not (iSecrets < iFallback and iFallback < iReturn and iReturn < iEnd) then
    print("[FAIL] 在 Utils/Skin.lua 里切不出品质色那一段（标记行没了 —— 代码搬动或改名，判据失效，先看源码再改探针）")
    print("       iSecrets=" .. tostring(iSecrets) .. " iFallback=" .. tostring(iFallback)
        .. " iReturn=" .. tostring(iReturn) .. " iEnd=" .. tostring(iEnd))
    os.exit(1)
end

local segment = table.concat(lines, "\n", iSecrets, iEnd)
local chunkSrc = "local ns, Skin, C_Item, Widget = ...\n" .. segment .. "\nreturn Skin"

-- ---------------------------------------------------------------------------
--  2) 断言工具
-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, label)
    if cond then
        pass = pass + 1
        print("  [OK]   " .. label)
    else
        fail = fail + 1
        print("  [FAIL] " .. label)
    end
end

-- 改动前那六个数（一位都不许动，所以在这里以**字面量**钉住，而不是从源码里读回来）。
local OLD = {
    [2] = { 0.20, 0.80, 0.20 },   -- Uncommon
    [3] = { 0.20, 0.55, 1.00 },   -- Rare
    [4] = { 0.65, 0.30, 0.95 },   -- Epic
    [5] = { 1.00, 0.55, 0.00 },   -- Legendary
    [6] = { 0.90, 0.80, 0.40 },   -- Artifact
    [7] = { 0.90, 0.80, 0.40 },   -- Heirloom
}

local function isFallback(c, q)
    local o = OLD[q]
    if not c or not o then return false end
    return c[1] == nil and c[2] == nil and c[3] == nil
        and c.r == o[1] and c.g == o[2] and c.b == o[3]
end

--- 每次新造一份模块：memo 表必须是干净的，否则"至多问一次"数不出来。
local function Fresh(cfg)
    cfg = cfg or {}
    local compiled = assert(load(chunkSrc, "Utils/Skin.lua#quality-segment"))
    local Widget = { SetBorderState = function() end }
    return compiled({ Secrets = cfg.secrets }, {}, cfg.citem, Widget)
end

-- ---------------------------------------------------------------------------
--  3) 行为断言
-- ---------------------------------------------------------------------------
print("== 1  没有 C_Item（旧构建 / 别的客户端）")
local S = Fresh()
for q = 2, 7 do ok(isFallback(S:QualityColor(q), q), "q=" .. q .. " 落旧六档，数值逐位相等") end
ok(S:QualityColor(0) == nil, "q=0 素边")
ok(S:QualityColor(1) == nil, "q=1 素边")
ok(S:QualityColor(8) == nil, "q=8 素边")
ok(S:QualityColor(nil) == nil, "q=nil 素边（不抛）")
ok(S:QualityColor(4) == S:QualityColor(4), "同一品质 = 同一张表（引用稳定）")
ok(S:QualityColor(2) ~= S:QualityColor(3), "不同品质 = 不同表（驱动帧的比较有意义）")

print("== 2  C_Item 在，但没有 GetItemQualityColor 这个字段")
S = Fresh({ citem = setmetatable({}, { __index = function() return nil end }) })
ok(isFallback(S:QualityColor(3), 3), "q=3 落兜底")

print("== 3  方法抛错")
S = Fresh({ citem = { GetItemQualityColor = function() error("boom") end } })
ok(isFallback(S:QualityColor(5), 5), "pcall 吃下异常，q=5 落兜底")

print("== 4  第一个返回值是 table（= 同事 harness 现在的桩写法）")
S = Fresh({ citem = { GetItemQualityColor = function() return { r = 0.55, g = 0.57, b = 0.61 } end } })
ok(isFallback(S:QualityColor(2), 2), "q=2 落兜底（不崩、也不是 nil 色）")

print("== 5  数字越界（0..255 口径 / 负数）")
S = Fresh({ citem = { GetItemQualityColor = function() return 255, 128, 0 end } })
ok(isFallback(S:QualityColor(4), 4), "255 口径 → q=4 落兜底")
S = Fresh({ citem = { GetItemQualityColor = function() return -0.1, 0.5, 0.5 end } })
ok(isFallback(S:QualityColor(6), 6), "负数 → q=6 落兜底")

print("== 6  合法答案")
local calls = {}
S = Fresh({ citem = { GetItemQualityColor = function(q)
    calls[q] = (calls[q] or 0) + 1
    return 0.10, 0.60, 0.90, "n" .. tostring(q)
end } })
local c = S:QualityColor(4)
ok(c ~= nil and c.r == 0.10 and c.g == 0.60 and c.b == 0.90, "吃到客户端的色（命名字段 r/g/b）")
ok(c[1] == nil and c[2] == nil and c[3] == nil, "位置索引全空 —— 全仓只剩一种形状")
for _ = 1, 50 do S:QualityColor(4) end
ok(calls[4] == 1, "惰性 memo：查 51 次只问了客户端 1 次")
ok(S:QualityColor(4) == c, "重复查同一品质返回同一张表")
ok(S:QualityColor(2) ~= c, "不同品质不是同一张表")
ok(S:QualityColor(0) == nil and S:QualityColor(1) == nil, "客户端给了合法答案也管不住 0/1：仍素边")

print("== 7  机密值")
local secretSecrets = {
    Number = function(v) if v == "SECRET" then return nil else return tonumber(v) end end,
}
S = Fresh({ secrets = secretSecrets, citem = { GetItemQualityColor = function() return "SECRET", 0.5, 0.5 end } })
ok(isFallback(S:QualityColor(3), 3), "通道里某个分量是机密 → 整档落兜底（不画半截色）")
ok(S:QualityColor("SECRET") == nil, "品质本身是机密值 → nil（机密不当表键）")
S = Fresh({ secrets = { Number = function(v) return tonumber(v) end },
    citem = { GetItemQualityColor = function() return 0.2, 0.4, 0.6 end } })
c = S:QualityColor(5)
ok(c ~= nil and c.r == 0.2 and c.b == 0.6, "有 Secrets 层且读得出 → 用客户端答案")

print("== 8  离线 tooling（ns.Secrets = nil 也要能跑）")
S = Fresh({ citem = { GetItemQualityColor = function() return 0.3, 0.4, 0.5 end } })
c = S:QualityColor(6)
ok(c ~= nil and c.r == 0.3 and c.g == 0.4 and c.b == 0.5, "没有 Secrets 也拿得到客户端答案")
S = Fresh()
ok(isFallback(S:QualityColor(7), 7), "没有 Secrets 且没 C_Item → 照样落兜底")

print("== 9  Bags 的调用形状（rec.quality or 0 → Skin:QualityColor → qc.r/.g/.b）")
S = Fresh()
for _, q in ipairs({ 0, 1, 2, 4, 7 }) do
    local got = S:QualityColor(q)
    local bad = false
    if got then
        bad = type(got.r) ~= "number" or type(got.g) ~= "number" or type(got.b) ~= "number"
    end
    ok(not bad, "q=" .. q .. " 能直接喂 Widget:Pulse(self, qc.r, qc.g, qc.b, 1)")
end

-- ---------------------------------------------------------------------------
--  4) 接线断言（源码级）：这些保证"只有一个来源"不会被下一个人悄悄改回两处
-- ---------------------------------------------------------------------------
print("== 10 源码接线")
local function contains(str, needle) return str:find(needle, 1, true) ~= nil end

local driverLines = {}
for i = 1, #lines do
    local l = lines[i]
    if contains(l, "color[1]") or contains(l, "color[2]") or contains(l, "color[3]") then driverLines[#driverLines + 1] = i end
end
ok(#driverLines == 0, "Skin.lua 里已经没有 color[1]/[2]/[3]（位置形状读法清零）")
local namedDriver = false
for i = 1, #lines do
    if contains(lines[i], "SetBorderState(border, color.r, color.g, color.b") then namedDriver = true end
end
ok(namedDriver, "Skin.lua 驱动帧按命名字段取色")
local positionalFallback = false
for i = iFallback, iFallback + 8 do
    local l = lines[i]
    if l and l:match("^    %[%d%] = { %d") then positionalFallback = true end
end
ok(not positionalFallback, "QUALITY_FALLBACK 六档都是命名字段")

local bagsSrc = ReadFile(bagsPath)
if not bagsSrc then
    ok(false, "读不到 Modules/Bags/Bags.lua（接线断言没跑成）")
else
    ok(not contains(bagsSrc, "local QUALITY_COLOR = {"), "Bags.lua 没有自己的品质色表了")
    ok(contains(bagsSrc, "Skin:QualityColor(rec.quality or 0)"), "Bags.lua 的 QualityBorder 走 Skin:QualityColor")
    ok(contains(bagsSrc, "local QUEST_COLOR = { r = 0.80, g = 0.80, b = 0.00 }"), "任务琥珀色仍归 Bags 自己")
    -- tipPrev（提示框原色簿记）这条只能钉源码：那段守卫写在 OnEnter 闭包里，切不出来单独跑。
    -- 钉的是"别改回把暴雪 getter 的返回值直接装表"这个写法（{ pr or 0, ... } 呸不掉机密值）。
    ok(not contains(bagsSrc, "{ pr or 0, pg or 0"), "Bags.lua 的 tipPrev 不再用 `pr or 0` 兜机密值")
    ok(contains(bagsSrc, "Secrets.Number(r0), Secrets.Number(g0)"), "tipPrev 存之前四个分量逐个过可读性判定")
    ok(contains(bagsSrc, "prev = { nr, ng, nb, na }"), "旁表里只放普通数字（读不出就 prev = nil，不存不还原）")
end

-- "品质色字面量全仓只剩 Skin 一处"这条要遍历整棵树，交给 node 入口去做（tools/quality-color-probe.js）：
-- Lua 侧的 io.popen + findstr 依赖当前目录和平台，容易假通过。

-- ---------------------------------------------------------------------------
--  5) tipPrev 守卫的**镜像**断言（Bags OnEnter 里那段写在闭包中，切不出来单独跑，
--     所以按 tools/test-mult.js 的老办法：镜像一份等价逻辑 + 用源码钉把两边锁在一起。
--     改了 Bags 的那段而不同步这里，下面的 SOURCE 钉会直接失败。）
-- ---------------------------------------------------------------------------
print("== 11 tipPrev 守卫（镜像 + 源码钉）")
local plainSecrets = { Number = function(v) if type(v) == "number" then return v end return nil end }

local function PrevOf(r0, g0, b0, a0, Sec)
    local nr, ng, nb = Sec.Number(r0), Sec.Number(g0), Sec.Number(b0)
    local na = Sec.Number(a0)
    if na == nil and a0 == nil then na = 1 end
    if nr and ng and nb and na then return { nr, ng, nb, na } end
    return nil
end

local p = PrevOf(0.1, 0.2, 0.3, 0.4, plainSecrets)
ok(p and p[1] == 0.1 and p[4] == 0.4, "四个都读得出 → 存原色")
ok(PrevOf(0.1, 0.2, "SECRET", 0.4, plainSecrets) == nil, "任一分量读不出 → 不存（OnLeave 就不还原）")
p = PrevOf(0.1, 0.2, 0.3, nil, plainSecrets)
ok(p and p[4] == 1, "客户端只给三个值 → alpha 补 1（旧写法补 0 = 把边框抹掉）")
ok(PrevOf(false, 0.2, 0.3, 0.4, plainSecrets) == nil, "false 不是数字 → 不存")
ok(bagsSrc and contains(bagsSrc, "if na == nil and a0 == nil then na = 1 end"),
    "源码里那条 alpha 补 1 的分支还在（镜像与源码同源）")
ok(bagsSrc and contains(bagsSrc, "local okC, r0, g0, b0, a0 = pcall(tip.GetBackdropBorderColor, tip)"),
    "源码里 getter 走 pcall（抛错时 prev 保持 nil，不写坏簿记）")

print(string.format("品质色探针：%d 通过 / %d 失败（切自 Utils/Skin.lua:%d-%d）",
    pass, fail, iSecrets, iEnd))
if fail > 0 then os.exit(1) end
os.exit(0)
