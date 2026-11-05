-- Utils/Compat.lua
-- 客户端能力自查（`/mui compat`）。
--
-- 为什么要有这一条命令：本仓的结论有一半是在 **retail 12.1.5** 上跑出来的，而交付目标是
-- **《无限》1.60（camelot / Interface 16001）**。同一句"本客户端没有 X"在两个客户端上可能
-- 正好相反（12.1.5 实测没有 `SecureHandlerClickTemplate`，无限的安全环境文档里却整组都有）。
-- 换客户端要跑的第一趟就是它：一条一行、只答"有没有"，`/mui compat bad` 只看"和我们的假设
-- 不符"的那几条。
--
-- 为什么不套 `Skin:Need`：那本账的语义是"名字写错了就是缺陷"；这里"不存在"本身是答案
-- （我们正因为某个东西不存在才改成了轮询 / 收养 / 状态驱动）。所以走同一个解析漏斗
-- `ns.ResolveObject`，但不记进皮肤账本。
local ADDON_NAME, ns = ...

local Compat = {}
ns.Compat = Compat

local HAVE    = "|cff00d94f有|r"
local HAVE_NOT = "|cffff6b6b无|r"
local NA      = "|cffffa940读不出|r"
local FLAG    = "|cffff6b6b≠|r"   -- 与假设不符
local CLEAN   = " |cff6b6b=|r"     -- 与假设一致

--- 点路径存在性：nil = 中间一层就读不出来（forbidden / 受限），不当成"不存在"。
local function Exists(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, obj = pcall(ns.ResolveObject, path)
    if not ok then return nil end
    return obj ~= nil
end

--- 安全模板：只有真造一个才作数（模板名不是全局，_G 里查不到）。
--- 口径有两层假阳性，都要在附注里说清楚：
---   1. 客户端对"没有的模板"可能只是忽略 → 这行会误报"有"；所以能对上方法名的
---      （`item.method`）再查一次方法在不在，报"方法在"才算硬证据。
---      **反过来也成立**：方法名猜错会误报"无"（12.1.5 第一趟就把
---      `SecureHandlerStateTemplate` 报成"方法缺"，可我们自绘条的 `_onstate-page` 一直在用它）。
---      所以只有"有把握的方法名"才配 method，其余的结论一律降级成"名字被接受"。
---   2. 模板自带 OnLoad 的会**真的跑起来**：12.1.5 实测造一个 `ActionBarButtonTemplate`
---      就报 6 条 `RegisterActionUIButton` 参数错（它自己去找 checkboxFrame 找不到）。
---      所以模板这一组默认不探，只有 `/mui compat tmpl` 明确要时才探。
local function TemplateExists(name, method)
    if type(_G.CreateFrame) ~= "function" then return nil end
    local ok, frame = pcall(_G.CreateFrame, "Button", nil, nil, name)
    if not ok or frame == nil then return false, "造不出来" end
    local pass, note = true, "名字被接受"
    if type(method) == "string" then
        local ok2, fn = pcall(function() return frame[method] end)
        pass = ok2 and type(fn) == "function"
        note = pass and "方法在" or "方法缺"
    end
    pcall(frame.SetShown, frame, false)
    return pass, note
end

--- 六类限制枚举齐不齐（少一类 = 我们的 ns:IsRestricted 就会漏判一类窗口）。
local CLASSES = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }
local function ProbeRestrictionEnum()
    local ok, e = pcall(ns.ResolveObject, "Enum.AddOnRestrictionType")
    if not ok or type(e) ~= "table" then return nil, "枚举读不出" end
    local got = {}
    for _, name in ipairs(CLASSES) do
        if e[name] ~= nil then got[#got + 1] = name end
    end
    return #got == #CLASSES, ("%d/%d：%s"):format(#got, #CLASSES, table.concat(got, ","))
end

--- 受限窗口 API 是否成组存在（本仓 Core.lua 六类记账的前提）。
--- `InCombatLockdown` 只在全局那一档（12.1.5 实测命名空间里没它），别混进来算缺。
local function ProbeRestrictedActions()
    local names = { "IsAddOnRestrictionActive", "GetAddOnRestrictionState", "CheckAllowProtectedFunctions" }
    local ok, nsTable = pcall(ns.ResolveObject, "C_RestrictedActions")
    if not ok or type(nsTable) ~= "table" then return false, "整个命名空间没有" end
    local have = {}
    for _, n in ipairs(names) do
        if type(nsTable[n]) == "function" then have[#have + 1] = n end
    end
    return #have == #names, ("%d/3 有：%s"):format(#have, table.concat(have, ","))
end

--- 脚本通道（/run）到底能不能用 —— 探"函数在不在"没有意义（两个客户端都在），
--- 要的是它**回答什么**：为真时 /run 与 /script 被整体关掉，所有诊断只能走 /mui 子命令。
--- 结论口径：have = true 表示"通道可用"（我们的假设）。
local function ProbeScripts()
    local ok, fn = pcall(ns.ResolveObject, "C_AddOns.GetScriptsDisallowedForBeta")
    if not ok or type(fn) ~= "function" then
        -- 没有这个函数 = 没有"测试服禁脚本"这回事，通道可用
        return true, "没有这个 API，按可用处理"
    end
    local ok2, v = pcall(fn)
    if not ok2 then return nil, "调用被拒" end
    if ns.Secrets and ns.Secrets.CanRead and not ns.Secrets.CanRead(v) then return nil, "读不出" end
    return (not v), (v and "被禁" or "可用")
end

-- 条目：{ 路径, 为什么在意, want }
--   want 省略 = 我们指望它**有**；want = "absent" = 我们指望它**没有**（正因为没有才改成了别的做法）
--   带 probe 的条目自己给结论（函数返回 有/无/nil, 附注）
local WATCH = {
    {
        group = "身份与脚本通道（决定诊断怎么发得出）",
        items = {
            { "GetBuildInfo", "客户端身份横幅；Interface 号取第 4 个返回值" },
            { probe = ProbeScripts, label = "/run 脚本通道", why = "被禁时诊断只能走 /mui 子命令" },
            { "C_GameRules.IsGameRuleActive", "读服务器 GameRule（下面那一组靠它）" },
            { "RunScript", "/run 的底层" },
        },
    },
    {
        group = "机密值与受限窗口（Secrets / IsRestricted 的前提）",
        items = {
            { "issecretvalue", "判机密的老前置" },
            { "canaccessvalue", "读值前的正规前置（Secrets.CanRead 用它）" },
            { "canaccesstable", "同上，表版本" },
            { "canaccessobject", "碰暴雪对象前先问" },
            { "issecurevariable", "归因用：逐键扫脏键" },
            { "InCombatLockdown", "全局老名字（文档里挂在 C_RestrictedActions 下）" },
            { probe = ProbeRestrictedActions, label = "C_RestrictedActions.*", why = "六类受限窗口的账本源" },
            { probe = ProbeRestrictionEnum, label = "Enum.AddOnRestrictionType", why = "六类齐不齐" },
            { "C_CurveUtil", "机密期会被拒的颜色曲线（AGENTS 那条）" },
        },
    },
    {
        group = "鼠标与遍历（我们改成轮询 / 全量扫描的那几个）",
        items = {
            { "MouseIsOver", "旧全局；本仓一律用 frame:IsMouseOver", "absent" },
            { "GetMouseFocus", "旧全局；同上", "absent" },
            { "UIParent.IsMouseOver", "轮询判悬停靠这个方法" },
            { "UIParent.IsVisible", "VisibilityOf 每拍读的就是它" },
            { "UIParent.GetChildren", "M:SweepDeep 靠它下钻" },
            { "EnumerateFrames", "Skin:ScanScrollArrows 的全量扫描（文档里没有，靠实机）" },
        },
    },
    {
        group = "安全模板（自绘条 / 收养按钮的底座；默认不探，/mui compat tmpl 才造）",
        items = {
            { tmpl = "SecureActionButtonTemplate", why = "自绘安全按钮的模板" },
            { tmpl = "SecureUnitButtonTemplate", why = "安全单位按钮（显隐只能交给 visibility 驱动）" },
            { tmpl = "SecureHandlerStateTemplate", why = "_onstate-* / _childupdate-* 片段；**功能上已在用**（自绘条换页就是它），不猜方法名" },
            { tmpl = "SecureHandlerClickTemplate", method = "SetBindingClick", why = "12.1.5 的 AGENTS 结论说没有；无限的文档说整组都有" },
            { tmpl = "SecureHandlerInputTemplate", method = "SetPropagateKeyboardInput", why = "键盘/鼠标透传（悬停钩子的安全替代）" },
            { tmpl = "ActionBarButtonTemplate", why = "拖放接住器用的模板；**造出来会自己跑 OnLoad，会报错**" },
            { tmpl = "CompactUnitFrameTemplate", method = "SetupUnit", why = "小队 / 团队框模板（我们不再代劳暴雪那套）" },
        },
    },
    {
        group = "暴雪框体（12.1.5 已实测；Forever 那一趟和这行做差集）",
        items = {
            { "NamePlateDriverFrame", "姓名板驱动框：碰它一次，它产的牌子全脏" },
            { "C_NamePlate.GetNamePlateSize", "改名板尺寸改成轮询它" },
            { "EditModeManagerFrame", "编辑模式（oldR 那条污染的现场）" },
            { "MinimapCluster", "小地图集群：正解是把它留在默认位置" },
            { "WorldMapFrame", "世界地图（C_WorldMap 在 12.1.5 不存在）" },
            { "TradeFrame", "交易面板" },
            { "TradeRecipientMoneyFrame", "对手侧金额框（12.1.5 实机真名）" },
            { "PetActionBar", "宠物条外壳（我们是收养按钮，不收养壳）" },
            { "PetActionButton1", "收养来的宠物按钮" },
            { "PetActionBar_UpdateCooldowns", "本仓改用 PetActionBar:UpdateCooldowns；12.1.5 没有这个全局", "absent" },
            { "StanceBar", "姿态条外壳" },
            { "StanceButton1", "收养来的姿态按钮" },
            { "GetNumShapeshiftForms", "只有复数名（单数版 12.1.5 不存在）" },
            { "MainActionBar", "必须换父的那条（alpha 0 不够）" },
            { "BuffFrame", "战斗光环交给暴雪原生这三块的第一块" },
            { "DebuffFrame", "同上" },
            { "TempEnchantFrame", "同上；12.1.5 实测**没有这个名字**（BuffFrame.lua 的压制清单里是一条空枪），真名用 /mui compat find Enchant 找" },
            { "SpellFlyout", "弹出托盘：鼠标点开在 12.1.5 是越权的" },
            { "LFGParentFrame", "Forever 候选：12.1.5 没有属正常，Forever 有就得复核皮肤", "absent" },
            { "LegacySystemFrame", "同上（Forever 传承进度）", "absent" },
            { "MicroMenu", "Forever 微菜单（12.1.5 也有，名字撞上了）" },
        },
    },
}

-- 服务器规则：这些 GameRule 一开，对应暴雪面板就根本不存在，我们的模块等于对空气美化。
local RULES = {
    { "UserAddonsDisabled", "第三方插件被整体关掉" },
    { "UserScriptsDisabled", "/run 与 /script 被禁" },
    { "MacrosDisabled", "宏被禁（动作条的宏按钮没意义）" },
    { "EditModeDisabled", "编辑模式被禁（布局只能靠配置面板）" },
    { "PlayerCastBarDisabled", "玩家施法条被关（CastBar 模块没对象）" },
    { "TargetCastBarDisabled", "目标施法条被关" },
    { "NameplateCastBarDisabled", "姓名板施法条被关" },
    { "ObjectiveTrackerDisabled", "任务追踪框不存在（QuestTracker 交还）" },
    { "QuestLogSuperTrackingDisabled", "超级追踪没有" },
    { "BagsUIDisabled", "背包面板被关（Bags 模块没对象）" },
    { "CompactRaidFrameManagerDisabled", "团队框管理器被关（Groups 皮肤没对象）" },
    { "PersonalResourceDisplayDisabled", "个人资源显示没有（ClassPower 落空）" },
    { "WorldMapTrackingPinDisabled", "地图追踪针没有" },
    { "MaximizeWorldMapDisabled", "地图不能最大化" },
    { "AeLootDisabled", "团队拾取被关" },
    { "TalentsPanelDisabled", "天赋面板被关" },
    { "CollectionsPanelDisabled", "幻化 / 收藏面板被关" },
    { "EncounterJournalDisabled", "冒险指南被关" },
}

-- ============================================================================
-- N4 · 运行期能力表（给代码用的判断，不是给人看的报告）
-- ============================================================================
-- 与上面 WATCH 的分工：WATCH 是"跑一趟 /mui compat 打全表"；这里是**模块想知道
-- "这台客户端有没有 X"时的唯一出口**。以前这件事散在各文件里靠记忆写 `if`，
-- 而本仓最硬的一条判例就是：同一句"这台客户端没有 X"在 12.1.5 与 1.60 可以相反
-- （`SecureHandlerClickTemplate` 前脚测出"无"，后脚在 1.60 整组都有）。
--
-- 三条硬规矩（都是学费换来的）：
--   ① **三态**：true / false / nil（读不出）。**绝不把 nil 塌成 false**，也绝不塌成 0 ——
--      判例：`Secrets.CanMeasureHealth` 当门，结果血量文字整段空白还不报错；受限窗口里
--      `ResolveObject` 本来就会读不出，那种"不知道"必须留着下次再问。
--   ② **会造对象的探针不在运行期随手跑**：只有 `needsFrame = true` 的条目才允许造实例，
--      且受限窗口里直接返回 nil（不造）。判例：探 `ActionBarButtonTemplate` 会自己跑
--      OnLoad 报一串参数错；自建 `AuraContainer` 在战斗里 Show 会连环 ADDON_ACTION_BLOCKED。
--   ③ **只 cache 确定值**：nil 不进 cache（下次重试）；造过实例的条目记 attempted，
--      绝不重复造框。
local CAPABILITIES = {
    secretGate   = { path = "canaccessvalue",   note = "读值前置（Secrets.CanRead 用它）" },
    secretProbe  = { path = "issecretvalue",    note = "老前置，只当兜底" },
    restrictionApi = { path = "C_RestrictedActions.IsAddOnRestrictionActive",
                       note = "六类受限窗口账本（ns:IsRestricted 的来源）" },
    combatFlagNamespaced = { path = "C_RestrictedActions.InCombatLockdown",
                       note = "两客户端结论相反的那条：12.1.5 无，1.60 待验" },
    scriptsAllowed = { path = "RunScript",      note = "被 GameRule 关掉时诊断只能走 /mui" },
    gameRuleRead   = { path = "C_GameRules.IsGameRuleActive", note = "RULES 那一组的前提" },
    userWaypoint   = { path = "C_Map.SetUserWaypoint",
                       note = "普查旁证：同机 OpenMap/Polestar 用它成功" },
    exploredMapTextures = { path = "C_MapExplorationInfo.GetExploredMapTextures",
                       note = "地图迷雾主路径（旧的「部分受限」判断要下调）" },
    nameplateLookup = { path = "C_NamePlate.GetNamePlateForUnit",
                       note = "softinteract 高亮 / 姓名板能力入口" },
    auraContainerLoD = { addon = "Blizzard_AuraContainer",
                       note = "战斗光环顶班的加载前提（模板本身另开一条）" },
    secureClickHandler = { template = "SecureHandlerClickTemplate", needsFrame = true,
                       note = "只有真造出来才作数；受限窗口里不造" },
}

local capCache, capTried = {}, {}

--- 只查名字/函数在不在，不造任何东西。返回 true / false / nil（读不出）。
local function PathCapability(path)
    local ok, obj = pcall(ns.ResolveObject, path)
    if not ok then return nil end            -- 中间一层被拒 = 不知道，不是「没有」
    if obj == nil then return false end
    local t = type(obj)
    if t == "function" or t == "table" or t == "userdata" then return true end
    return false
end

--- LoD 插件：加载状态是"能不能用"的第一道门（不加载，模板再真也白搭）。
local function AddonCapability(name)
    if type(C_AddOns) ~= "table" then return nil end
    if type(C_AddOns.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
        if not ok then return nil end
        if loaded then return true end
    end
    if type(C_AddOns.GetAddOnInfo) ~= "function" then return nil end
    local ok, _, _, loadable = pcall(C_AddOns.GetAddOnInfo, name)
    if not ok then return nil end
    return (loadable and true) or false   -- 没加载但可加载 = true（调用方自己会去 LoadAddOn）
end

--- 求一条能力的真值；可能返回 nil = 现在还不知道（调用方必须能处理「不知道」）。
local function Evaluate(key, entry)
    if entry.path then return PathCapability(entry.path) end
    if entry.addon then return AddonCapability(entry.addon) end
    if entry.template then
        if entry.needsFrame then
            -- 规矩 ②：造实例的探测只在明确不受限的时点做，且一辈子只造一次。
            if ns.IsRestricted and ns:IsRestricted() then return nil end
            if capTried[key] then return capCache[key] end
            capTried[key] = true
            local found, note = TemplateExists(entry.template, entry.method)
            if found == nil then return nil end       -- 造不出来分不出「没有」与「被拒」
            capCache[key .. ":note"] = note
            return (found and true) or false
        end
        return Exists(entry.template)
    end
    return nil
end

--- 模块用这一个入口问能力。三态：true / false / nil（不知道）。第二返回值是附注。
function Compat:Capability(key)
    local entry = CAPABILITIES[key]
    if not entry then return nil, "未知能力名" end
    local cached = capCache[key]
    if cached ~= nil then return cached, capCache[key .. ":note"] end
    local value = Evaluate(key, entry)
    if value ~= nil then capCache[key] = value end    -- 规矩 ①：nil 不进 cache
    return value, capCache[key .. ":note"]
end

--- 普通调用点的唯一出口（#34）：问"这台客户端有没有 X"，**永不返回 nil**。
--- 不知道(nil) 塌成 `fallback`；知道就返回 true/false。逼每个调用点显式表态
--- "读不出时走哪条路"—— 而不是把 nil 当假值悄悄走错分支（判例：`Secrets.CanMeasureHealth`
--- 当门，血量整段空白还不报错）。典型：`if Compat:GetCapability("secureClickHandler", false) then`
--- 走安全模板，否则走轮询 —— 读不出也安全降级到轮询。
function Compat:GetCapability(key, fallback)
    local value = self:Capability(key)
    if value == nil then return fallback end
    return value
end

-- ============================================================================
-- 行为助手（#34）：返回"这台客户端该怎么用"的值，而不是"有没有"的布尔。
-- 判例来源：RurutiaSuite Core/Compat.lua 的 GetPrimarySecureClickEvents —— 同一句
-- "按下施法还是抬起施法"在两客户端会给出不同的点击掩码组合，散落 if 迟早漂移。
-- ============================================================================

--- 这台客户端的动作按钮是"按下施法"还是"抬起施法"（暴雪 cvar ActionButtonUseKeyDown）。
--- 读不到时默认 true（和原散落点一致：新版暴雪默认按下施法）。每次现读，不 cache
--- —— 玩家可在设置里改，CVAR_UPDATE 后必须拿到新值。
function Compat:UseOnKeyDown()
    local down = true
    if type(_G.GetCVarBool) == "function" then
        local ok, value = pcall(_G.GetCVarBool, "ActionButtonUseKeyDown")
        if ok then down = value ~= false end
    end
    return down
end

--- 配套：按上面的模式给出安全按钮该注册的两个点击掩码。
--- 按下施法要收 Down+Up（否则按下去不触发），抬起施法只收 Up。
--- 调用点：`button:RegisterForClicks(Compat:SecureClickEvents())`。
function Compat:SecureClickEvents()
    if self:UseOnKeyDown() then return "AnyDown", "AnyUp" end
    return "AnyUp"
end

--- 列全部能力（`/mui compat caps`）：只报**已经问过**的和"未探测"，
--- 绝不在这里造任何实例 —— 报告命令不许改变运行期状态。
function Compat:ListCapabilities()
    local keys = {}
    for k in pairs(CAPABILITIES) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = capCache[k]
        out[#out + 1] = ("%s = %s  （%s）"):format(k,
            v == true and HAVE or (v == false and HAVE_NOT or "|cffffa940未探测|r"),
            CAPABILITIES[k].note or "")
    end
    return out
end

--- 读一条 GameRule 的生效状态。返回 state, 附注：
---   "active" 生效 / "inactive" 没生效 / "unknown" 读不出（调用被拒或 API 不在）
---   "notarule" 这个客户端的枚举里根本没有这条（那是好消息，不算与假设不符）
local function RuleState(name)
    local ok, id = pcall(ns.ResolveObject, "Enum.GameRule." .. name)
    if not ok then return "unknown", "枚举读不出" end
    if id == nil then return "notarule", "" end
    local ok2, fn = pcall(ns.ResolveObject, "C_GameRules.IsGameRuleActive")
    if not ok2 or type(fn) ~= "function" then return "unknown", "IsGameRuleActive 没有" end
    local ok3, active = pcall(fn, id)
    if not ok3 then return "unknown", "调用被拒" end
    -- 显式分支：`a and b or c` 在 Bool 返回 false 时会掉进 c，把"生效"读成"没生效"
    if ns.Secrets and ns.Secrets.Bool then
        return (ns.Secrets.Bool(active, false) and "active" or "inactive"), ("#%s"):format(tostring(id))
    end
    return (active and "active" or "inactive"), ("#%s"):format(tostring(id))
end

--- 跑一遍，返回 client, rows, total, odd, skippedTmpl。
--- rows 每行 { 组名, 名字, 结论, 与假设不符(true/nil), 附注 } —— 这是账本的原样，不做裁剪。
--- withTmpl = 连安全模板一起探（会真造框体，见 TemplateExists 的注释）。
function Compat:Run(withTmpl)
    local okId, identity = pcall(function()
        return type(ns.ClientIdentity) == "function" and ns:ClientIdentity() or nil
    end)
    local client = tostring(okId and identity or "?")
    local rows, total, odd, skippedTmpl = {}, 0, 0, 0

    for _, grp in ipairs(WATCH) do
        for _, item in ipairs(grp.items) do
            if item.tmpl and not withTmpl then
                skippedTmpl = skippedTmpl + 1
            else
                local have, note
                if item.probe then
                    local ok, a, b = pcall(item.probe)
                    have = ok and a or nil
                    note = b
                elseif item.tmpl then
                    have, note = TemplateExists(item.tmpl, item.method)
                else
                    have = Exists(item.path or item[1])
                end
                local name = item.label or item.tmpl or item.path or item[1]
                local wantAbsent = (item.want == "absent") or (item[3] == "absent")
                local mismatch = (have == nil) or (wantAbsent and have == true) or ((not wantAbsent) and have == false)
                total = total + 1
                if mismatch then odd = odd + 1 end
                rows[#rows + 1] = { grp.group, name,
                    have == nil and "读不出" or (have and "有" or "无"),
                    mismatch or nil, note }
            end
        end
    end

    for _, r in ipairs(RULES) do
        local state, note = RuleState(r[1])
        -- 只有"生效"和"读不出"算与假设不符；"这条规则这个客户端没有"是好消息，不算缺陷
        local mismatch = (state == "active") or (state == "unknown")
        total = total + 1
        if mismatch then odd = odd + 1 end
        rows[#rows + 1] = { "GameRule", r[1],
            state == "active" and "生效" or (state == "inactive" and "无"
                or (state == "notarule" and "客户端没这条" or "读不出")),
            mismatch or nil, note }
    end

    return client, rows, total, odd, skippedTmpl
end

--- 存进 SavedVariables：这一趟有 60 多行，聊天框只留最后十几行，一定被顶掉。
--- 读法（/reload 或登出后，**写入比 reload 晚一两分钟**，别立刻去读）：
---   <游戏目录>/WTF/Account/<账号>/SavedVariables/MonetUI.lua 里的 compatReport
local function SaveReport(client, rows, total, odd)
    if type(ns.DB) ~= "function" then return end
    local ok, db = pcall(function() return ns:DB() end)
    if not ok or type(db) ~= "table" then return end
    local when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil
    db.compatReport = { client = client, when = when, total = total, odd = odd, rows = rows }
end

--- 按名字片段扫框体（`/mui compat find Enchant`）。
--- 为什么要有：暴雪框体的真名是两边客户端差得最多、文档又给不出的那一类
--- （12.1.5 实测就没有 TempEnchantFrame，全 UI 里带 Enchant 的只有 4 个交易附魔框）。
--- 两条腿一起走：12.1.5 实测 `EnumerateFrames` 会把**所有**框（含子框）都吐出来，
--- 但老口径只给没有父框的顶层框（265 个， MonetUI 自己的都不在里面）——
--- 所以取根之后还逐层 `GetChildren` 补一遍，用 seen 去重。只读名字，不写任何东西。
local MAX_NODES, MAX_DEPTH = 40000, 12

local function Note(bag, node)
    if node == nil or bag.done[node] then return end
    bag.done[node] = true
    bag.n = bag.n + 1
    local okName, name = pcall(node.GetName, node)
    if okName and type(name) == "string" and string.find(string.lower(name), bag.needle, 1, true) then
        bag.hits[#bag.hits + 1] = name
    end
end

local function Walk(node, depth, bag)
    if depth > MAX_DEPTH or bag.n >= MAX_NODES then return end
    -- `GetChildren` 返回的是**多返回值**，不是表：直接 `pcall(node.GetChildren, node)` 只会拿到
    -- 第一个子框，`ipairs` 于是永远空转（本仓其余十处都写成 `{ ... }`）。这里必须包成表。
    local ok, kids = pcall(function() return { node:GetChildren() } end)
    if not ok or type(kids) ~= "table" then return end
    for _, child in ipairs(kids) do
        if bag.n >= MAX_NODES then return end
        Note(bag, child)
        Walk(child, depth + 1, bag)
    end
end

function Compat:Find(sub)
    if type(_G.EnumerateFrames) ~= "function" then
        ns:Print("EnumerateFrames 没有，扫不了帧名。")
        return 0
    end
    sub = tostring(sub or "")
    if sub == "" then
        ns:Print("用法：/mui compat find <名字片段>，例如 /mui compat find Enchant")
        return 0
    end
    local bag = { needle = string.lower(sub), hits = {}, n = 0, done = {} }
    local frame = _G.EnumerateFrames()
    while frame do
        Note(bag, frame)
        Walk(frame, 1, bag)
        if bag.n >= MAX_NODES then break end
        local okNext, nxt = pcall(_G.EnumerateFrames, frame)
        if not okNext then break end
        frame = nxt
    end
    table.sort(bag.hits)
    for i = 1, math.min(#bag.hits, 24) do ns:Print("  " .. bag.hits[i]) end
    if #bag.hits > 24 then ns:Print(("  （还有 %d 个，片段再长一点）"):format(#bag.hits - 24)) end
    ns:Print(("|cffffd100帧名含 %q|r：%d 个（走了 %d 个框%s）"):format(
        sub, #bag.hits, bag.n, bag.n >= MAX_NODES and "，到上限截断" or ""))
    return #bag.hits
end

--- 打印并记账。opts = { bad = 只列与假设不符的, tmpl = 连模板一起探（会造框体） }。
function Compat:Print(opts)
    opts = opts or {}
    local onlyBad = opts.bad == true
    local client, rows, total, odd, skippedTmpl = Compat:Run(opts.tmpl == true)
    local lastGroup

    ns:Print("|cffffd100能力自查|r 客户端：" .. client)

    for _, row in ipairs(rows) do
        local group, name, verdict, mismatch, note = row[1], row[2], row[3], row[4], row[5]
        if not onlyBad or mismatch then
            if group ~= lastGroup then
                ns:Print("|cffffd100—— " .. group .. " ——|r")
                lastGroup = group
            end
            local state
            if verdict == "读不出" then state = NA
            elseif verdict == "有" then state = HAVE
            elseif verdict == "生效" then state = "|cffff6b6b生效|r"
            elseif verdict == "客户端没这条" then state = "|cff8a8a8a客户端没这条|r"
            else state = HAVE_NOT end
            local tail = (note ~= nil and note ~= "") and (" · " .. tostring(note)) or ""
            -- 名字压到 30 列：聊天框一行装不下"前缀 + 4 列标记 + 34 列名字"，
            -- 一折行颜色码就会被转义成字面量，读起来全是 |cff8a8a8a。
            ns:Print(("  %s %-30s %s%s"):format(mismatch and FLAG or CLEAN, name, state, tail))
        end
    end

    SaveReport(client, rows, total, odd)
    ns:Print(("|cffffd100能力自查|r：%d 项，与假设不符 %d 项%s；全量已存 MonetUIDB.compatReport（WTF 里可直接读）"):format(
        total, odd, odd == 0 and "（这一趟客户端和我们的假设一致）" or " —— /mui compat bad 只看它们"))
    if skippedTmpl > 0 then
        ns:Print(("模板 %d 项没探（要真造框体，ActionBarButtonTemplate 还会自带报错）：/mui compat tmpl"):format(skippedTmpl))
    end
    return odd
end
