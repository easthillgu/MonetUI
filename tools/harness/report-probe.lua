-- tools/harness/report-probe.lua
-- `/mui report` 的**离线行为探针**（不是发行码：toc / Tools.xml 都不收它，游戏里永远不会加载）。
--
-- 为什么要有它：harness 的替身世界**不调斜杠命令**，所以 `node tools/harness/run.js` 的红 0
-- 只能证明"Report.lua 被加载了"，证明不了"报告打得出来、而且不把机密值拼进字符串"。
-- 后者正是这条命令的全部风险面（它读角色名、地图名、插件标题 —— 全是暴雪来的字符串）。
--
-- 怎么跑（仓库根目录）：
--     node tools/report-probe.js        ← 推荐，和其它闸门同一个入口
--     lua tools/harness/report-probe.lua
-- 退出码：全过 0，任何一条失败 1。
--
-- 手法照 `quality-color-probe.lua`：**跑发行码本身**（loadfile 真文件，喂假 `ns`），
-- 而不是复制一份逻辑 —— 复制的那份永远不会发现真代码坏了。
-- 只用 Lua 5.1 就有的东西（无 `//`、无 `goto`、无 `table.unpack`、`load` 收字符串）。

local probePath = arg and arg[0] or ...

local function norm(p) return (p or ""):gsub("\\", "/") end
local function RepoRoot()
    local p = norm(probePath)
    local i = p:find("tools/harness/report%-probe.lua$", 1)
    if i then return p:sub(1, i - 1) end
    return "./"
end
local root = RepoRoot()
local targetPath = (arg and arg[1]) or (root .. "Modules/Tools/Report.lua")

local f = io.open(targetPath, "rb")
if not f then
    print("[FAIL] 读不到 " .. tostring(targetPath) .. "（在工作树根目录跑，或把路径当第一个参数传）")
    os.exit(1)
end
local src = f:read("*a")
f:close()

-- ---------------------------------------------------------------- 假环境
-- 哨兵：真客户端里"机密值"是普通字符串/数字但带密文属性，`type()` 判不出来（AGENTS 判例）。
-- 这里用同形的办法模拟：**值就是那个值**，只有 `CanRead`/`Number` 知道它不可读。
local SECRET_TEXT = {
    ["SECRET-PLAYER-NAME"] = true,
    ["SECRET-MAP-NAME"] = true,
    ["SECRET-ADDON-TITLE"] = true,
    ["SECRET-ADDON-NAME"] = true,
    ["SECRET-REASON"] = true,
}
local SECRET_NUM = { [77.5] = true, [12] = true }

local printed = {}
local db = {
    modules = { Bags = true, Skins = false, Report = true },
    bags = { iconSize = 28, gap = 4, columns = 8, showBank = false, anchor = { x = -18 } },
    infoBar = { scale = 1.5 },
}

local function canRead(v)
    if type(v) == "string" and SECRET_TEXT[v] then return false end
    return true
end

local fakeSecrets = {
    CanRead = function(v) return canRead(v) end,
    Number = function(v)
        if type(v) ~= "number" then return nil end
        if SECRET_NUM[v] then return nil end
        return v
    end,
}

local fakeSkin = {
    targets = {
        ["_"] = { BankFrame = { hits = 3, misses = 0 }, WarbandBankFrame = { hits = 0, misses = 2 } },
        trade = { TradeFrame = { hits = 5, misses = 0 }, MailListScrollFrame = { hits = 0, misses = 1 } },
        bank = { BankFrame = { hits = 2, misses = 0 } },
    },
    WarnRing = function()
        return {
            { topic = "sweepSkip:无名框", message = "读不出来（forbidden 对象），跳过子控件补扫" },
            { topic = "dressDrop:trade", message = "此刻跳过 1 个非框体条目：TradePlayerInputMoneyFrame" },
        }
    end,
}

local registered
local fakeNs = {
    DEFAULTS = {
        modules = { Bags = true, Skins = true, Report = true },
        bags = { iconSize = 28, gap = 4, columns = 8, showBank = true },
        infoBar = { scale = 1 },
    },
    Secrets = fakeSecrets,
    Skin = fakeSkin,
    Print = function(_, line) printed[#printed + 1] = tostring(line) end,
    DB = function() return db end,
    IsRestricted = function() return false end,
    InCombat = function() return false end,
    Register = function(_, name, mod) registered = mod; registered.registeredName = name end,
}

-- 暴雪 API 桩：故意把**每一个**字符串/数字都可能"带密"，好让断言能打出来。
GetLocale = function() return "zhCN" end
GetBuildInfo = function() return "WoW Forever", "1.60.1", 70783, "2026-11-01" end
UnitName = function() return SECRET_TEXT and "SECRET-PLAYER-NAME" or "player" end   -- 机密角色名
UnitLevel = function() return 60 end
UnitFactionGroup = function() return "Horde" end

C_Map = {
    GetBestMapForUnit = function() return 1411 end,
    GetMapInfo = function() return { name = "SECRET-MAP-NAME" } end,               -- 机密地图名
    GetPlayerMapPosition = function()
        local v = 77.5                                                             -- 机密坐标
        return setmetatable({ x = v, y = v }, {})
    end,
}
C_AddOns = {
    GetAddOnMetadata = function(_, variable)
        if variable == "Version" then return "0.12.0" end
        if variable == "Interface" then return "16001" end
        return nil
    end,
    GetNumAddOns = function() return 4 end,
    GetAddOnName = function(i)
        return ({ "MonetUI", "TweaksForever", "SECRET-ADDON-NAME", "EllesmereUI" })[i]
    end,
    GetAddOnInfo = function(name)
        if name == "TweaksForever" then return name, "Tweaks Forever", "", true, "", nil end
        if name == "SECRET-ADDON-NAME" then return name, "SECRET-ADDON-TITLE", "", false, "SECRET-REASON", nil end
        return name, "Ellesmere UI", "", true, nil, nil
    end,
    -- 载入状态与"可载入"是两件事：上一版把 `loadable` 绑错位置（pcall 的 ok 占了第一位），
    -- 结果真机上 64 个插件全被报成"不载"，连明确打了加载横幅的 QuestEcho/Rurutia 也不例外。
    IsAddOnLoaded = function(name) return name == "TweaksForever" and true or false end,
}
time = function() return 1730000000 end

-- ---------------------------------------------------------------- 跑真代码
local chunk, err = loadfile(targetPath)
if not chunk then
    print("[FAIL] Report.lua 编译失败：" .. tostring(err))
    os.exit(1)
end
local okRun, runErr = pcall(chunk, "MonetUI", fakeNs)
if not okRun then
    print("[FAIL] Report.lua 加载即抛：" .. tostring(runErr))
    os.exit(1)
end

local pass, failcount = 0, 0
local function ok(cond, label)
    if cond then pass = pass + 1; print("  [OK]   " .. label)
    else failcount = failcount + 1; print("  [FAIL] " .. label) end
end
-- 内容断言对着**账本全文**做，不对聊天框做：summary 只印前 14 行（聊天框装不下是设计），
-- 拿截断后的输出判"某段没出现"会把设计读成缺陷。
local function has(sub)
    for _, line in ipairs((db.reportBundle and db.reportBundle.lines) or {}) do
        if line:find(sub, 1, true) then return true end
    end
    return false
end
--- 只看聊天框输出（help / 账本写不进去时的提示语，本来就不该在账本里）。
local function hasPrinted(sub)
    for _, line in ipairs(printed) do if line:find(sub, 1, true) then return true end end
    return false
end
local function hasSentinel()
    local bag = {}
    for _, line in ipairs((db.reportBundle and db.reportBundle.lines) or {}) do bag[#bag + 1] = line end
    for _, line in ipairs(printed) do bag[#bag + 1] = line end
    for _, line in ipairs(bag) do
        for s in pairs(SECRET_TEXT) do if line:find(s, 1, true) then return s end end
        if line:find("77.50", 1, true) then return "机密坐标 77.5" end
    end
    return nil
end

ok(registered ~= nil, "注册发生（ns:Register(\"Report\", M)）")
ok(registered and registered.registeredName == "Report", "注册名 = Report（⇒ /mui report 走 Core 的模块名分发）")
printed = {}
local handled = registered:HandleCommand("summary")

-- 1. 不抛错、被消费、有产出
ok(handled == true, "1 未知之外的子命令被消费（返回 true）")
ok(#printed > 8, ("2 打印出行数够（%d 行；PRINT_CAP 截断后仍应有账本提示）"):format(#printed))

-- 2. 段落齐
for _, title in ipairs({ "环境", "角色", "位置", "受限状态", "设置差异", "提示历史", "美化台账", "同机插件" }) do
    ok(has("── " .. title .. " ──"), "3 段标题在场：" .. title)
end

-- 3. 秘密值一律没拼进输出，且以"读不出"呈现（这条是整份探针的存在理由）
local sentinel = hasSentinel()
ok(sentinel == nil, ("4 没有任何机密值进输出（命中即失败：%s）"):format(tostring(sentinel)))
ok(has("读不出"), "5 读不出的位置显式写「读不出」（不把密值当 0 / 不当缺失）")

-- 4. 设置差异只报差异
ok(has("bags.showBank = false（默认 true）"), "6 设置差异报「值 vs 默认」")
ok(has("模块 Skins = false（默认 true）"), "7 模块开关差异单独列")
ok(not has("bags.iconSize = 28"), "8 与默认一致的不列（不是全量转储）")
ok(has("与默认值") or has("= "), "9 设置段有内容")

-- 10. 台账汇总带口径（两种原因都写进行里）
ok(has("缺失 = 没这名字"), "10 台账行自带「缺失 ≠ 缺陷」口径")
ok(has("[trade] 缺 1"), "11 按档汇总缺失数")

-- 12. 提示历史
ok(has("sweepSkip:无名框"), "12 提示历史进报告（Skin:WarnRing 的读端）")

-- 13. 账本落盘
ok(type(db.reportBundle) == "table" and type(db.reportBundle.lines) == "table",
  "13 全量落 MonetUIDB.reportBundle（聊天框只留十几行的那条约定）")
ok(db.reportBundle.at == 1730000000, "14 账本带时间戳")

-- 15/16. 路由边界
printed = {}
ok(registered:HandleCommand("bogus") == false, "15 未知子命令返回 false（交回 Core 打用法）")
ok(#printed == 0, "16 未知子命令不自己印东西")
printed = {}
ok(registered:HandleCommand("help") == true and hasPrinted("/mui report full"), "17 help 打用法")
printed = {}
ok(registered:HandleCommand("full") == true and #printed > 20, "18 full 逐行打（比 summary 多）")

-- 19. 受限/战斗状态下不崩（战斗里读数会失败，命令必须还能跑）
local combatSaved = fakeNs.InCombat
fakeNs.InCombat = function() return true end
printed = {}
local okCombat = pcall(function() registered:HandleCommand("summary") end)
ok(okCombat, "19 战斗中调用不抛（只读，没有可被拒的写）")
fakeNs.InCombat = combatSaved

-- 20. DB 打不开时也要说清楚（不能静默）
local dbSaved = fakeNs.DB
fakeNs.DB = function() error("no db") end
printed = {}
local okNoDb = pcall(function() registered:HandleCommand("summary") end)
ok(okNoDb and hasPrinted("账本没打开"), "20 账本打不开：不崩，且明说这份只在聊天框")
fakeNs.DB = dbSaved

-- 21. 静态：这条命令永远是只读的。
--     **先剥注释**再看禁词 —— 文件头的纪律声明就写着"不挂 HookScript / hooksecurefunc"，
--     不剥会把"声明自己不做"当成"做了"（`check-frame-list.js` 为同样的坑写过同一条理由）。
local codeSrc = src:gsub("%-%-[^\n]*", "")
ok(not codeSrc:find("HookScript", 1, true) and not codeSrc:find("hooksecurefunc", 1, true)
   and not codeSrc:find("SetPoint", 1, true) and not codeSrc:find("SetAlpha", 1, true)
   and not codeSrc:find("Hide", 1, true) and not codeSrc:find("CreateFrame", 1, true),
  "21 代码里没有任何钩子/写操作/建框（只读诊断的边界，将来有人往里加就要另立新判据）")


-- 22. 只报告，不判定：用到的 C_* 名字列出来，人对着 1.60 快照核
--     （`node tools/api-audit.js` 已经把"快照里没有的 C_*"当 HARD 拦掉了，这条只是给阅读者一张清单）
local names, uniq = {}, {}
for nsName, fn in src:gmatch("(C_[A-Za-z0-9]+)%.([A-Za-z0-9]+)") do
    local k = nsName .. "." .. fn
    if not uniq[k] then uniq[k] = true; names[#names + 1] = k end
end
table.sort(names)
print("  [INFO] 用到的暴雪 API：" .. table.concat(names, ", "))

-- 23/24/25. 同机插件状态必须区分三态（真机上曾因 pcall 返回值错位而全员"不载"）
ok(has("已载入 · TweaksForever · Tweaks Forever"), "23 已载入的插件报「已载入」并带标题")
ok(has("可载入·未开 · EllesmereUI · Ellesmere UI"), "24 没载入但可载入的报「可载入·未开」")
ok(has("同机插件 2 个") and not has("SECRET-ADDON-NAME") and not has("SECRET-ADDON-TITLE")
   and not has("SECRET-REASON"),
   "25 名字/标题/理由带密 ⇒ 整行不出现（宁可不报，也不把密值拼进输出与账本）")

print(("report-probe: %d 过 / %d 失"):format(pass, failcount))
os.exit(failcount == 0 and 0 or 1)
