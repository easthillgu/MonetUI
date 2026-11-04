-- Modules/Tools/Report.lua
-- `/mui report` —— 一条命令产出一份可贴回来的诊断包。
--
-- 借鉴自同客户端的 TweaksForever（GPL-3.0-or-later，只读研究；分析见
-- docs/ANALYSIS-TWEAKSFOREVER.md）。它的报告通道比我们多四样，正好都是明天上线日要的：
--   ① 环境头（版本 / build / 语言 / 角色 / 地图坐标）
--   ② **与默认值的设置差异**（出事先知道这人改了什么）
--   ③ **本会话打过的一次性提示历史**（聊天框滚掉就没了；配套 Skin:WarnRing）
--   ④ **同机其它插件清单**（共存基线 = B，不清场，"是不是我们干的"必须能判定）
-- 只借字段构成与思路，代码全部自写 —— 许可不兼容（它 GPL、我们 MIT），不许抄实现。
--
-- 硬约束（与 Modules/Tools/DevTools.lua 同一套，逐条自检过）：
--   * 只读：不动任何帧的属性/显隐/几何，不挂 HookScript / hooksecurefunc，不建 ticker/OnUpdate。
--   * 从游戏读来的**字符串**进 format/concat 前一律过 `Secrets.CanRead`（判例：机密串的 `type()`
--     照样是 "string"，未守卫就抛 invalid value）；**数字**一律过 `Secrets.Number`。
--   * 读不出写 "读不出"，绝不当 0、不当假（"密值"与"缺失"不许混，本仓反复踩过的那条）。
--   * 长输出落 SavedVariables（`MonetUIDB.reportBundle`）；落盘比 /reload 晚 1–2 分钟，帮助里写明。
--
-- API 名字逐个对过 1.60 快照（1.60.1.70634）：`C_AddOns.GetNumAddOns` / `GetAddOnName(index)` /
-- `GetAddOnInfo(name)` / `GetAddOnMetadata(name, var)`、`C_Map.GetBestMapForUnit` /
-- `GetMapInfo(uiMapID) → UiMapDetails` / `GetPlayerMapPosition(mapID, unit) → vector2`（读 .x/.y）。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Skin    = ns.Skin

local PRINT_CAP   = 14      -- 聊天框只留十几行，其余进账本
local ADDON_CAP   = 80      -- 插件清单条数上限
local DIFF_CAP    = 40      -- 设置差异行数上限
local LEDGER_NAME = "reportBundle"
local UNKNOWN     = "读不出"

-- ---------------------------------------------------------------- 安全读取
-- 顺序固定：类型判断 → pcall → Secrets 漏斗 → 失败给 nil。

local function Num(v)
    if type(v) ~= "number" then return nil end
    if Secrets and Secrets.Number then return Secrets.Number(v) end
    return v
end

--- 暴雪来的字符串：不过可读性判定就不许进任何 format/concat。
local function Text(v)
    if type(v) ~= "string" or v == "" then return nil end
    if Secrets and Secrets.CanRead and not Secrets.CanRead(v) then return nil end
    return v
end

local function Safe(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

local function Or(v)
    return v ~= nil and tostring(v) or UNKNOWN
end

-- ---------------------------------------------------------------- 各段

local function SectionEnvironment()
    local version = Text(Safe(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version"))
    -- 客户端身份**必须复用 `ns:ClientIdentity()`**：它按"值"认 Interface 号（12.1.5 实测第 4 个返回值
    -- 才是 120105、第 5 个是空串），而 `GetBuildInfo()` 的返回值**位置按版本不一样** ——
    -- 我上一版自己数索引，1.60 上就打成「客户端 1.60.1 70790 构建 读不出 / Interface 读不出」。
    local identity = (type(ns.ClientIdentity) == "function") and Text(ns:ClientIdentity()) or nil
    return {
        ("MonetUI %s · %s · 语言 %s"):format(
            Or(version),
            identity or ("客户端 " .. UNKNOWN),
            Or(Text(Safe(GetLocale)))),
    }
end

local function SectionCharacter()
    local name  = Text(Safe(UnitName, "player"))
    local level = Num(Safe(UnitLevel, "player"))
    local fac   = Text(Safe(UnitFactionGroup, "player"))
    return { ("角色：%s · 等级 %s · 阵营 %s"):format(Or(name), Or(level), Or(fac)) }
end

local function SectionLocation()
    local mapID = Num(Safe(C_Map.GetBestMapForUnit, "player"))
    if not mapID then return { ("位置：%s（C_Map 不可用或此刻受限）"):format(UNKNOWN) } end
    local okI, info = pcall(C_Map.GetMapInfo, mapID)
    local mapName = (okI and type(info) == "table") and Text(info.name) or nil
    local okP, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    local x, y
    if okP and type(pos) == "table" then
        x, y = Num(pos.x), Num(pos.y)
    end
    return { ("位置：地图 %d %s · 坐标 %s"):format(mapID, Or(mapName),
        (x and y) and string.format("%.2f, %.2f", x, y) or UNKNOWN) }
end

--- 与默认值的差异（模块 → 标量键两层）。目的很具体：出问题时先知道"这人改了什么"。
local function SectionSettings()
    local ok, db = pcall(function() return ns:DB() end)
    if not ok or type(db) ~= "table" then return { "设置：账本没打开" } end
    local defaults = ns.DEFAULTS or {}
    local out, count = {}, 0
    for modName, values in pairs(db) do
        if modName ~= "modules" and type(values) == "table" then
            local base = defaults[modName]
            if type(base) == "table" then
                for key, value in pairs(values) do
                    local t = type(value)
                    if (t == "number" or t == "boolean" or t == "string") then
                        local dflt = base[key]
                        if dflt ~= nil and type(dflt) == t and dflt ~= value then
                            count = count + 1
                            if count <= DIFF_CAP then
                                out[#out + 1] = ("  %s.%s = %s（默认 %s）")
                                    :format(modName, key, tostring(value), tostring(dflt))
                            end
                        end
                    end
                end
            end
        end
    end
    for name, on in pairs(db.modules or {}) do
        local dflt = defaults.modules and defaults.modules[name]
        if dflt ~= nil and dflt ~= on then
            out[#out + 1] = ("  模块 %s = %s（默认 %s）"):format(name, tostring(on), tostring(dflt))
        end
    end
    if #out == 0 then return { "设置：与默认值一致" } end
    if count > DIFF_CAP then out[#out + 1] = ("  …另有 %d 项差异只在账本里"):format(count - DIFF_CAP) end
    return out
end

--- 本会话的一次性提示历史（`Skin:WarnRing` 是这次一并加的：以前只有"打没打过"的布尔）。
local function SectionWarnings()
    local ring = (Skin and Skin.WarnRing) and Skin:WarnRing() or {}
    if #ring == 0 then return { "提示：本会话没有一次性警告" } end
    local out = { ("提示 %d 条（本会话）："):format(#ring) }
    for _, w in ipairs(ring) do
        out[#out + 1] = ("  [%s] %s"):format(tostring(w.topic), tostring(w.message))
    end
    return out
end

--- Need 台账：按档汇总命中/缺失。缺失的两种原因写进行里（没这名字 / LoD 或窗未出生），
--- 否则读数的人一定会把总数当缺陷数（11-04 实机就是这么误判过一次）。
local function SectionNeedLedger()
    local out, total, missing = {}, { hits = 0, miss = 0 }, 0
    local perScope = {}
    for scope, byPath in pairs((Skin and Skin.targets) or {}) do
        local hits, miss, names = 0, 0, {}
        for path, led in pairs(byPath) do
            hits = hits + (led.hits or 0)
            if (led.misses or 0) > 0 then
                miss = miss + 1
                names[#names + 1] = path
            end
        end
        total.hits, total.miss = total.hits + hits, total.miss + miss
        if miss > 0 then
            table.sort(names)
            missing = missing + 1
            perScope[#perScope + 1] = { scope = scope, hits = hits, miss = miss, names = names }
        end
    end
    table.sort(perScope, function(a, b) return a.scope < b.scope end)
    out[#out + 1] = ("美化台账：命中 %d · 有缺失的档 %d（缺失 = 没这名字 **或** LoD/窗未出生，开窗后重跑再看）")
        :format(total.hits, missing)
    for _, s in ipairs(perScope) do
        -- 结束下标必须跟着实际条数：`table.concat(t, sep, 1, 6)` 在不足 6 项时会在第 2 项
        -- 撞上 nil 直接抛（11-04 report-probe 抓到的真 bug —— 明早第一次 /mui report 就会红在这）。
        out[#out + 1] = ("  [%s] 缺 %d（命中 %d）：%s%s")
            :format(s.scope, s.miss, s.hits,
                table.concat(s.names, ", ", 1, math.min(6, #s.names)),
                #s.names > 6 and " …" or "")
    end
    return out, perScope
end

--- 同机插件清单：明天判"是不是我们干的"的根据（共存基线 B 不换环境，只能靠账本判归属）。
local function SectionAddons()
    if type(C_AddOns) ~= "table" or type(C_AddOns.GetNumAddOns) ~= "function" then
        return { "同机插件：C_AddOns 不可用" }, {}
    end
    local n = Num(C_AddOns.GetNumAddOns()) or 0
    local lines, list = {}, {}
    for i = 1, n do
        local name = Text(Safe(C_AddOns.GetAddOnName, i))
        if name and name ~= ADDON_NAME then
            local _, title, _, loadable, reason, security = Safe(C_AddOns.GetAddOnInfo, name)
            local state = loadable and "载入" or ("不载" .. (Text(reason) and ("/" .. Text(reason)) or ""))
            if security then state = state .. "/" .. security end
            local line = ("  %s · %s · %s"):format(state, name, Or(Text(title)))
            list[#list + 1] = line
            if #lines < ADDON_CAP then lines[#lines + 1] = line end
        end
    end
    table.sort(lines)
    table.sort(list)
    if #list > #lines then lines[#lines + 1] = ("  …其余 %d 个只在账本里"):format(#list - #lines) end
    return { ("同机插件 %d 个（除本插件）："):format(#list) }, list, lines
end

-- ---------------------------------------------------------------- 模块本体

local M = { name = "Report" }

--- 组装整份报告。返回：文本行数组（打印/存档用）、结构化明细（将来做窗口/上传用）。
function M:Build()
    local lines, detail = {}, {}
    local function add(title, body, extra)
        lines[#lines + 1] = "── " .. title .. " ──"
        for _, line in ipairs(body) do lines[#lines + 1] = line end
        if extra then detail[extra.key] = extra.value end
    end
    add("环境", SectionEnvironment())
    add("角色", SectionCharacter())
    add("位置", SectionLocation())
    add("受限状态", { ("受限 %s · 战斗 %s"):format(
        tostring(ns.IsRestricted and ns:IsRestricted() or false),
        tostring(ns.InCombat and ns:InCombat() or false)) })
    add("设置差异", SectionSettings())
    add("提示历史", SectionWarnings())
    local needLines, perScope = SectionNeedLedger()
    add("美化台账", needLines, { key = "missingScopes", value = perScope })
    local head, addonList, addonLines = SectionAddons()
    for _, line in ipairs(addonLines or {}) do head[#head + 1] = line end
    add("同机插件", head, { key = "addons", value = addonList })
    return lines, detail
end

function M:PrintHelp()
    ns:Print("用法：/mui report       打印诊断包（环境·角色·位置·受限·设置差异·提示历史·台账·同机插件）")
    ns:Print("      /mui report full  同一份逐行全打（会刷屏，聊天框只留最后十几行）")
    ns:Print(("全量已存 MonetUIDB.%s —— 落盘比 /reload 晚 1–2 分钟，登出后再读最稳。"):format(LEDGER_NAME))
end

function M:HandleCommand(rest)
    if rest == nil or rest == "" then rest = "summary" end
    if rest == "help" or rest == "?" then self:PrintHelp() return true end
    if rest ~= "summary" and rest ~= "full" then return false end

    local list, detail = self:Build()

    local saved = false
    local ok, db = pcall(function() return ns:DB() end)
    if ok and type(db) == "table" then
        local okSet = pcall(function()
            db[LEDGER_NAME] = {
                at = (type(time) == "function") and time() or nil,
                lines = list,
                addons = detail.addons,
                missingScopes = detail.missingScopes,
            }
        end)
        saved = okSet and true or false
    end

    if rest == "full" then
        for _, line in ipairs(list) do ns:Print(line) end
    else
        for i = 1, math.min(PRINT_CAP, #list) do ns:Print(list[i]) end
        if #list > PRINT_CAP then
            ns:Print(("…其余 %d 行只在账本里（/mui report full 逐行打）"):format(#list - PRINT_CAP))
        end
    end
    if not saved then ns:Print("⚠ 账本没打开：这份只存在于聊天框") end
    return true
end

ns:Register("Report", M)
