-- Modules/Tools/DevCommands.lua
-- 开发版专属斜杠命令层（`/mui scale|blocks|restrict|colors|lost|perf|compat|dev|dig`
-- 以及它们的实现 / 帮助文案）。只在仓库与本地部署里加载：
--   * Tools.xml 里本文件的 Script 行带 <!-- DEV-ONLY -->，发版由 tools/strip-dev.js 摘掉；
--   * 本文件列在 .pkgmeta 的 ignore 里，不进发布 zip；
--   * Core.lua 只留 ns.DevCommands 两处钩子（发布版为 nil，整层代码根本不在包里）。
-- fail-closed：TOC 的 X-Dev-Build 不是 dev 时直接 return，不注册任何命令。
-- 玩家向命令（配置 / status / theme / init / 模块开关 / 背包 / 货币 / tweaks /
-- whatsnew / reset）一律留在 Core.lua，不受本文件影响。

local ADDON_NAME, ns = ...
if type(ns) ~= "table" or not ns.dev then return end

local M = {}
ns.DevCommands = M

-- PrintRestrictions 要用 Core 的这两份 local。为诊断在 Core 里多开一个公开接口不值得，
-- 这里各留一份只读副本；Core 的定义仍是运行期唯一权威。
local RESTRICTION_ORDER = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }
local function RestrictedFn(name)
    local api = _G.C_RestrictedActions
    local fn = api and api[name]
    return type(fn) == "function" and fn or nil
end

--- 受限窗口自查（`/mui restrict`）：六类限制逐类对照"我们的账"和"客户端实时答案"。
local function PrintRestrictions()
    local api = _G.C_RestrictedActions
    if type(api) ~= "table" then
        ns:Print("这个客户端没有 C_RestrictedActions（退回只看战斗中）。")
    else
        for _, name in ipairs({ "InCombatLockdown", "IsAddOnRestrictionActive",
            "GetAddOnRestrictionState", "CheckAllowProtectedFunctions" }) do
            ns:Print(("  C_RestrictedActions.%s：%s"):format(name, type(api[name]) == "function" and "有" or "没有"))
        end
    end
    local enum = _G.Enum and _G.Enum.AddOnRestrictionType
    ns:Print("  Enum.AddOnRestrictionType：" .. (type(enum) == "table" and "有" or "没有"))
    local tracked, known = ns:Restrictions()
    local live = {}
    for name in pairs(tracked) do live[#live + 1] = name end
    table.sort(live)
    ns:Print(("当前受限：%s（战斗中 %s · IsRestricted %s · 旗帜 %s · 账本 %s）"):format(
        #live > 0 and table.concat(live, " / ") or "无",
        ns:InCombat() and "是" or "否",
        ns:IsRestricted() and "是" or "否",
        ns.Restricted and "有" or "无",
        known and "已建立" or "还没建立（没收到过事件）"))
    local isActive = RestrictedFn("IsAddOnRestrictionActive")
    if isActive and enum then
        for i = 1, #RESTRICTION_ORDER do
            local name = RESTRICTION_ORDER[i]
            local t = enum[name]
            if t ~= nil then
                local ok, on = pcall(isActive, t)
                ns:Print(("  %s：账本 %s / 实时 %s"):format(name,
                    tracked[name] and "活" or "空",
                    (ok and on) and "活" or "空"))
            else
                ns:Print(("  %s：枚举里没有这个值"):format(name))
            end
        end
    end
    local Secrets = ns.Secrets
    if type(Secrets) == "table" and type(Secrets.CanRead) == "function" then
        ns:Print(("  canaccessvalue：%s（没有时 CanRead 退回 not issecretvalue）"):format(
            type(_G.canaccessvalue) == "function" and "有" or "没有"))
    end
    -- 被暂停的轮询框：告警每框只印一条，聊天很快被顶掉，这本账随时能重看。
    local Widget = ns.Widget
    if type(Widget) == "table" and type(Widget.PrintStalled) == "function" then
        ns:Print("轮询被暂停的框（forbidden 对象，读不出可见性）：")
        Widget:PrintStalled()
    end
end

--- 拦截归因账本（`/mui blocks`）：本客户端对 ADDON_ACTION_BLOCKED 不写 taint.log，
--- 只能认 Secrets.Bool() 失败路径里自己记的 debugstack。
local function PrintBlockLedger(rest)
    local function PrintBusErrors()
        local bus = ns.EventBus
        if not bus or type(bus.FailureCounts) ~= "function" then return end
        local counts = bus.FailureCounts()
        local order = {}
        for event in pairs(counts) do order[#order + 1] = event end
        if #order == 0 then return end
        table.sort(order, function(a, b) return counts[a] > counts[b] end)
        ns:Print("事件处理器失败（同一事件只提示一次，其余静默）：")
        for i = 1, #order do
            if i > 8 then
                ns:Print(("  …另有 %d 个事件"):format(#order - 8))
                break
            end
            ns:Print(("  |cffffd100×%d|r %s"):format(counts[order[i]], order[i]))
        end
    end

    if type(ns.Secrets) ~= "table" or type(ns.Secrets.BoolBlocks) ~= "function" then
        ns:Print("这个构建没有 BoolBlocks 账本。")
        PrintBusErrors()
        return
    end
    local blocks, total = ns.Secrets.BoolBlocks()
    if total == 0 or #blocks == 0 then
        ns:Print("|cff88ff88账本为空|r：本会话没有机密布尔被拦的记录。")
        ns:Print("（只统计 `Secrets.Bool` 的失败路径；其它 `UNKNOWN()` 来源要靠关模块二分。）")
        PrintBusErrors()
        return
    end
    local order, groups = {}, {}
    for _, entry in ipairs(blocks) do
        local head = string.match(entry.stack or "?", "[^\r\n]+") or "?"
        if not groups[head] then
            groups[head] = { n = 0 }
            order[#order + 1] = head
        end
        groups[head].n = groups[head].n + 1
    end
    ns:Print(("机密布尔被拦 |cffffa940%d|r 条 · 去重 %d 个调用点："):format(total, #order))
    for i, head in ipairs(order) do
        if i > 8 then
            ns:Print(("  …另有 %d 个调用点（/mui blocks full 看完整栈）"):format(#order - 8))
            break
        end
        ns:Print(("  |cffffd100×%d|r %s"):format(groups[head].n, head))
    end
    if rest == "full" then
        local first = blocks[1]
        ns:Print("最早一条的完整栈：")
        for line in string.gmatch((first and first.stack or "?"), "[^\r\n]+") do
            ns:Print("  " .. line)
        end
    end
    PrintBusErrors()
end

--- 亮度阶梯自查（`/mui colors`）：判定行与各自的线全部来自 Color:Surface().rows，
--- 这里只组数据、打印、落盘（§8.123）。账本在 WTF 的 MonetUI.lua 里，落盘比 /reload 晚 1–2 分钟。
local function BuildColorReport(su)
    local source, profile = ns.Color:GetSource()
    local mapID, zoneName, envSource = ns.Color:GetZoneInfo()

    -- 副本而非 su 本身：账本要进 SavedVariables，不许和运行期阶梯表共用引用。
    local checked, passed, rows = 0, 0, {}
    for i = 1, #(su.rows or {}) do
        local src = su.rows[i]
        local entry = { key = src.key, label = src.label, cr = src.cr,
                        min = src.min, ok = src.ok, note = src.note }
        rows[#rows + 1] = entry
        if entry.min and type(entry.cr) == "number" then
            checked = checked + 1
            if entry.cr >= entry.min then passed = passed + 1 end
        end
    end

    local colors = {}
    for i = 1, #su.keys do
        local c = su[su.keys[i]]
        if c then colors[su.keys[i]] = { r = c.r, g = c.g, b = c.b } end
    end

    return {
        client = ns:ClientIdentity(),
        when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil,
        source = source,
        profile = profile,
        mapID = mapID,
        zone = zoneName,
        envSource = envSource,
        keys = { unpack(su.keys) },
        steps = su.steps,
        levels = su.levels,
        colors = colors,
        cr = su.cr,
        crMin = su.crMin,
        environment = su.environment,
        adjust = su.adjust,
        toolsReady = su.toolsReady,
        rows = rows,
        min = su.minContrast,
        passed = passed,
        checked = checked,
    }
end

--- 账本无条件写：判不过的那一趟恰恰最需要留在 WTF 里看。
local function SaveColorReport(report)
    local ok, db = pcall(function() return ns:DB() end)
    if not ok then return false, "DB() 抛错：" .. tostring(db) end
    if type(db) ~= "table" then return false, "DB() 返回 " .. type(db) end
    local okSet, errSet = pcall(function() db.colorReport = report end)
    if okSet then return true end
    return false, "写入抛错：" .. tostring(errSet)
end

local function PrintColorLadder()
    local Color = ns.Color
    if type(Color) ~= "table" or type(Color.Surface) ~= "function" then
        ns:Print("Color.Surface 不可用：阶梯层没进去（Utils/Color.lua 是旧的）。")
        return
    end

    local su = Color:Surface()

    local hexes = {}
    for i = 1, #su.keys do
        local key = su.keys[i]
        local c = su[key]
        if c then
            local hex = ns.Math:RGBToHex(c.r, c.g, c.b)
            local l = su.levels and su.levels[key]
            hexes[#hexes + 1] = string.format("|cff%s%s %s|r", hex, key,
                type(l) == "number" and string.format("%.1f", l) or "?")
        end
    end

    local report = BuildColorReport(su)
    ns:Print(string.format("配色阶梯 %s | %s | %s",
        table.concat(hexes, " "),
        report.source == "monet" and ("monet/" .. tostring(report.profile)) or "fallback",
        report.mapID and (tostring(report.zone or "?") .. " " .. tostring(report.mapID) .. " " .. tostring(report.envSource or "?")) or "区域未知"))

    for i = 1, #report.rows do
        local row = report.rows[i]
        if type(row.cr) == "number" then
            if row.min then
                ns:Print(string.format("  %s %s%.2f（线 %.1f）|r%s", row.label,
                    row.ok and "|cff88ff88" or "|cffff6b6b", row.cr, row.min,
                    row.note and (" · " .. row.note) or ""))
            else
                ns:Print(string.format("  %s %.2f · %s", row.label, row.cr, row.note or "豁免"))
            end
        end
    end

    local saved, why = SaveColorReport(report)

    if report.checked == 0 then
        ns:Print("|cffff6b6b没有 ContrastRatio / AtLightness|r：vendored LibMonetColor 早于 1.2.0，阶梯退回旧的固定乘数（观感和升级前一致）。")
        ns:Print("  修法：把 monetcolors 仓库的 LibMonetColor-1.0.lua 同步进 Libs/ 后 /reload。")
        return
    end

    local adj = su.adjust
    if adj and adj.applied then
        local bits = {}
        if adj.fillHue then bits[#bits + 1] = "血条转环境补色" end
        if adj.fillTo then bits[#bits + 1] = string.format("填充 L*%.0f→%.0f", adj.fillFrom or 0, adj.fillTo) end
        if adj.textTo then bits[#bits + 1] = string.format("文字 L*%.0f→%.0f", adj.textFrom or 0, adj.textTo) end
        if adj.edgeTo then bits[#bits + 1] = string.format("边框 L*%.0f→%.0f", adj.edgeFrom or 0, adj.edgeTo) end
        ns:Print("  自动纠偏：" .. table.concat(bits, " / "))
    else
        ns:Print("  自动纠偏：未触发（这一区各配对本来就过线，配色保持引擎原色）")
    end

    ns:Print(string.format("|cffffd100配色阶梯|r：%d/%d 组过线（最小对比控制值 %.1f）%s",
        report.passed, report.checked, report.min or 0,
        saved and "；全量已存 MonetUIDB.colorReport（WTF 里可直接读）"
            or ("；|cffff6b6b账本没落成 —— " .. tostring(why) .. "|r")))
end

--- 像素网格 / 缩放报告（`/mui scale`）：uiScale CVar 是本客户端唯一读得到的缩放依据。
local function PrintScale()
    local Media = ns.Media
    local raw = (_G.C_CVar and _G.C_CVar.GetCVar) and _G.C_CVar.GetCVar("uiScale") or nil
    local mult = Media:Mult()

    ns:Print("---- 像素网格 / 缩放 ----")
    ns:Print(string.format("uiScale CVar        : %s", tostring(raw)))
    ns:Print(string.format("Mult() = 1/scale    : %.4f UI 单位 / 物理px", mult))
    ns:Print(string.format("  => 1 物理px 需要   : %.4f UI 单位", mult))
    ns:Print(string.format("  => 1 UI 单位 =     : %.3f 物理px", mult > 0 and 1 / mult or 0))

    local theme = ns:DB().theme or {}
    ns:Print(string.format("缩放模式            : %s", theme.uiScaleMode == "auto" and "自动（按分辨率固定）" or "跟随游戏设置"))
    local presetScale, presetPixels = Media:PinnedScale()
    if presetScale then
        ns:Print(string.format("固定值（按分辨率）  : %.4f  ->  1 UI 单位 = %d 物理像素",
            presetScale, presetPixels or 0))
    else
        local h = Media:ScreenHeight()
        ns:Print(string.format("固定值（按分辨率）  : 无（当前高度 %s 不在固定表里）", tostring(h)))
    end

    if _G.GetPhysicalScreenSize then
        local w, h = _G.GetPhysicalScreenSize()
        ns:Print(string.format("物理分辨率         : %d x %d", w or 0, h or 0))
    end
    ns:Print(string.format("逻辑分辨率         : %d x %d", _G.GetScreenWidth and _G.GetScreenWidth() or 0,
                                                _G.GetScreenHeight and _G.GetScreenHeight() or 0))
    if UIParent and UIParent.GetHeight then
        ns:Print(string.format("UIParent:GetHeight(): %.2f UI 单位", UIParent:GetHeight()))
    end

    local pw, ph = _G.GetPhysicalScreenSize and _G.GetPhysicalScreenSize()
    local lw, lh = _G.GetScreenWidth and _G.GetScreenWidth(), _G.GetScreenHeight and _G.GetScreenHeight()
    if pw and ph and lw and lh and pw > 0 and ph > 0 then
        if lw == pw and lh == ph then
            ns:Print("分辨率            : 原生（栅格 = 物理像素）")
        else
            ns:Print(string.format("分辨率            : 非原生！%dx%d -> %dx%d，栅格比物理像素粗",
                                    lw, lh, pw, ph))
        end
    end
    if type(_G.ConsoleGetAllCommands) == "function" then
        ns:Print("提示：graphicsTextureResolution = "
            .. tostring((_G.C_CVar and _G.C_CVar.GetCVar and _G.C_CVar.GetCVar("graphicsTextureResolution")) or "?")
            .. "（UI 贴图不受它缩放，仅供确认）")
    end

    ns:Print(string.format("示例：thickness=1 的边框 = %.4f UI 单位 = 1 物理px", 1 * mult))
    ns:Print(string.format("      thickness=2 的边框 = %.4f UI 单位 = 2 物理px", 2 * mult))
    ns:Print("改动游戏里的 UI 缩放后再跑一次，Mult() 应随之变化。")
end

-- 本层真正接管的顶层命令。report / devtools 仍走 Core 的模块 HandleCommand 路径
-- （在 Core 里以模块名消费），这里不重复实现。
--- `/mui watch start|stop`：拍两张"此刻可见框"的名单，差集就是**这几秒新冒出来的框**。
---
--- 用途：报障"做了某个动作后屏幕上多出一个框，但不知道它是谁" —— 不用先猜位置/名字，
--- 先 start → 做那个动作 → stop，差的那些框带着真名、父级、尺寸、alpha、坐标。
--- 全量走 EnumerateFrames（本机 6 万多个框，拍一张约 0.5–1 秒）；forbidden 的框读不出就整条跳过。
local watchSnapshot
local function WatchSnapshot()
    local set = {}
    if type(EnumerateFrames) ~= "function" then return set end
    local frame = EnumerateFrames()
    while frame do
        local ok, shown = pcall(frame.IsShown, frame)
        -- 受限窗口里 IsShown 会返回机密布尔，`if shown then` 会被客户端拦成 BLOCKED（2026-11-27 实测）；
        -- 读不出真值就当"没看见"，反正是诊断用的名单。
        -- 注意：本文件没有文件级 `local Secrets`（只有某个函数体内有一份），这里必须走 `ns.Secrets`。
        local secrets = ns.Secrets
        local visible = false
        if ok then
            if type(secrets) == "table" and type(secrets.Bool) == "function" then
                visible = secrets.Bool(shown, false)
            else
                visible = shown == true
            end
        end
        if visible then set[frame] = true end
        frame = EnumerateFrames(frame)
    end
    return set
end
local function WatchDescribe(frame)
    local parts = {}
    local okN, name = pcall(frame.GetName, frame)
    parts[#parts + 1] = (okN and type(name) == "string") and name or "(匿名)"
    local okP, p = pcall(frame.GetParent, frame)
    if okP and p then
        local okPN, pn = pcall(p.GetName, p)
        parts[#parts + 1] = "父=" .. ((okPN and pn) or "(匿名)")
    end
    local okW, w = pcall(frame.GetWidth, frame)
    local okH, h = pcall(frame.GetHeight, frame)
    if okW and okH and w and h then parts[#parts + 1] = ("%dx%d"):format(math.floor(w), math.floor(h)) end
    local okA, a = pcall(frame.GetAlpha, frame)
    if okA and a and (not ns.Secrets or ns.Secrets.CanRead(a)) then
        parts[#parts + 1] = ("alpha=%.2f"):format(a)
    else
        parts[#parts + 1] = "alpha=?"
    end
    local okC, x, y = pcall(frame.GetCenter, frame)
    if okC and x and y and (not ns.Secrets or (ns.Secrets.CanRead(x) and ns.Secrets.CanRead(y))) then
        parts[#parts + 1] = ("(%.0f,%.0f)"):format(x, y)
    end
    return table.concat(parts, "  ")
end
local function WatchCommand(rest)
    rest = string.lower(rest or "")
    if rest == "" or rest == "start" then
        -- 先打一句再扫：扫六万多个框要 1 秒上下，如果先扫再打印，玩家看到的是"按了回车没反应"。
        ns:Print("正在拍快照（扫全部可见框，画面会卡一下）……")
        local function snap()
            local ok, err = pcall(function()
                watchSnapshot = WatchSnapshot()
            end)
            if not ok then
                ns:Print("快照失败：" .. tostring(err))
                return
            end
            local n = 0
            for _ in pairs(watchSnapshot) do n = n + 1 end
            ns:Print(("已拍快照：此刻可见框 %d 个。现在去做那个动作，回来跑 /mui watch stop。"):format(n))
        end
        if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
            pcall(_G.C_Timer.After, 0, snap)
        else
            snap()
        end
        return true
    end
    if rest == "stop" then
        if not watchSnapshot then
            ns:Print("还没有快照，先跑 /mui watch start。")
            return true
        end
        local now = WatchSnapshot()
        local new, count = {}, 0
        for frame in pairs(now) do
            if not watchSnapshot[frame] then
                count = count + 1
                new[#new + 1] = frame
            end
        end
        watchSnapshot = nil
        ns:Print(("新出现的可见框 %d 个："):format(count))
        for i = 1, math.min(#new, 40) do
            ns:Print(("  %2d. %s"):format(i, WatchDescribe(new[i])))
        end
        if #new > 40 then ns:Print(("  ……其余 %d 个未列"):format(#new - 40)) end
        return true
    end
    ns:Print("用法：/mui watch start  然后做动作，再 /mui watch stop")
    return true
end

local DISPATCH = {
    scale = true, blocks = true, restrict = true, colors = true, lost = true,
    compat = true, perf = true, dev = true, dig = true, chat = true, watch = true,
}

-- 只列开发版诊断命令的文案；发布版连这些字符串都不在包里。
local HELP_LINES = {
    "  —— 开发版诊断（发布版不提供）——",
    "  |cffffd100/mui scale|r      像素网格 / 缩放自检（改完 UI 缩放后再跑一次对比）",
    "  |cffffd100/mui blocks|r     机密布尔被拦的调用栈账本（`UNKNOWN()` 归因，加 full 看完整栈）",
    "  |cffffd100/mui watch start|r 拍一张可见框快照；做动作后 `/mui watch stop` 列出**新冒出来的框**（名字/父级/尺寸/alpha/坐标）",
    "  |cffffd100/mui restrict|r   六类受限窗口自查（战斗只是其中一类）+ 可读性前置是否可用",
    "  |cffffd100/mui colors|r     配色亮度阶梯 + 逐组对比度判定（含最小对比控制值与纠偏记录），账本 MonetUIDB.colorReport",
    "  |cffffd100/mui lost|r       血条「损失部分」配色自查：样式有没有落地、织纹有没有把颜色盖住",
    "  |cffffd100/mui compat|r     客户端能力自查：换客户端第一趟跑它（bad 只看与假设不符的，tmpl 连模板一起探，find <片段> 扫暴雪帧真名）",
    "  |cffffd100/mui skins diagnose|r 对象名可达性账本（全仓一本账：skins / nameplates / infobar / minimap）",
    "  |cffffd100/mui minimap menu|r 微菜单现场判据：行建不建得出 / 面板受不受保护 / 此刻右键落点（开服日「右键没反应」）",
    "  |cffffd100/mui groupframes status|r 打印锚点 / 显隐诊断（同时写入 MonetUIDB.groupReport）",
    "  |cffffd100/mui skins diagnose bad|r 只看「命中但不是框体」那一类（全量几百行，聊天框装不下）",
    "  |cffffd100/mui skins layers <窗口名> [片段]|r 这个窗口的底有几层、每层谁能碰（region / 字段可剥 / 要点名；全量存 MonetUIDB.layerReport）",
    "  |cffffd100/mui skins templates [片段]|r 模板库账本：多少个模板 / 映射到 skinAs / Camelot 覆盖；带片段查「这个控件被认成什么」",
    "  |cffffd100/mui dev|r        元素探测面板（256×256）：列出目标窗体包含的框体/贴图，点行复制名字去接线",
    "  |cffffd100/mui dig|r        枚举指针下的窗体：先把鼠标指到目标窗口上，再输入这条命令（全量存 MonetUIDB.devProbeReport）",
    "  |cffffd100/mui chat status|r 聊天条状态：当前频道 / 自定义频道数 / 发送锁定状态（不打印输入内容）",
    "  |cffffd100/mui perf [reset|diag]|r 调度器总账：订阅数 / 逐路耗时排序 / 失败计数 + 外部驱动账 + Lua 内存 + 当前被暂停的轮询框；带 reset 先清零再计时，带 diag 打调试能力自检（账本 MonetUIDB.perfReport）",
    "  |cffffd100/mui skins closes|r 关闭按钮换皮覆盖面：按图集全量扫，已换皮/仍是暴雪原样/读不出三档（closeReport）",
    "  |cffffd100/mui skins inset|r 换皮容器的有效 alpha（父链连乘，不是单点 GetAlpha），α<0.99 全列（insetReport）",
    "  |cffffd100/mui skins arrows|r 滚动条/步进器箭头逐对象：旋转角 + UV 翻转 + stepper 属性，用来定左右方向（arrowReport）",
    "  |cffffd100/mui buffframe probe|r 只数战斗光环容器的子框个数，不读任何 aura 字段（buffProbe）",
    "  |cffffd100/mui nameplates siblings|r 每块牌 base:GetChildren() 的真名 + alpha，判据是名单里有没有 BuffListFrame（nameplateSiblings）",
    "  |cffffd100/mui …|r          以上探针全量只进账本：落盘比 /reload 晚 1–2 分钟，登出后读最稳，聊天框只有前几行",
}

--- Core 的 HandleSlash 开头调用；返回 true 表示这条命令已被开发层消费。
function M:Handle(message)
    local command, rest = string.match(message or "", "^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if not DISPATCH[command] then return false end

    if command == "scale" then
        PrintScale()

    elseif command == "blocks" then
        PrintBlockLedger(rest)

    elseif command == "watch" then
        WatchCommand(rest)

    elseif command == "restrict" then
        PrintRestrictions()

    elseif command == "colors" then
        PrintColorLadder()

    elseif command == "lost" then
        local unitFrames = ns:GetModule("UnitFrames")
        if unitFrames and type(unitFrames.DebugLost) == "function" then
            unitFrames:DebugLost()
        else
            ns:Print("单位框模块没加载，读不到血条配色。")
        end

    elseif command == "perf" then
        local devTools = ns:GetModule("DevTools")
        if devTools and type(devTools.Perf) == "function" then
            devTools:Perf(rest)
        else
            ns:DevPrint("DevTools 探针模块没加载：检查 Modules/Tools/Tools.xml 里有没有 DevTools.lua。")
        end

    elseif command == "compat" then
        local Compat = ns.Compat
        if type(Compat) ~= "table" then
            ns:Print("能力自查没加载：检查 Utils/Utils.xml 里有没有 Compat.lua。")
        else
            local arg = string.lower(rest or "")
            if string.find(arg, "^find") then
                Compat:Find(string.match(arg, "^find%s+(.*)"))
            elseif arg == "legacy" then
                -- 老式全局族清单：只答"还有哪些老 API 活着"，不是缺陷报告（所以不进 WATCH）
                if type(Compat.LegacyReport) == "function" then Compat:LegacyReport()
                else ns:Print("这个版本的 Compat 没有 LegacyReport。") end
            elseif arg == "caps" then
                ns:Print("|cffffd100能力表|r（未探测 = 还没人问过；要现探就照常跑 /mui compat）")
                for _, line in ipairs(Compat:ListCapabilities()) do ns:Print("  " .. line) end
            elseif type(Compat.Print) == "function" then
                Compat:Print({ bad = string.find(arg, "bad") ~= nil, tmpl = string.find(arg, "tmpl") ~= nil })
            else
                ns:Print("Compat.Print 不可调用。")
            end
        end

    elseif command == "chat" then
        local chat = ns:GetModule("Chat")
        if chat and type(chat.HandleCommand) == "function" and chat:HandleCommand(string.lower(rest or "")) then
            return true
        end
        ns:Print("用法：/mui chat status")

    elseif command == "dev" or command == "dig" then
        local probe = ns:GetModule("DevProbe")
        if probe and type(probe.HandleCommand) == "function" then
            probe:HandleCommand(command == "dig" and "dig" or "")
        else
            ns:DevPrint("DevProbe 模块没加载：检查 Modules/Tools/Tools.xml 里有没有 DevProbe.lua。")
        end
    end

    return true
end

--- Core 的 PrintHelp 末尾调用；发布版没有本文件，不打印任何诊断文案。
function M:PrintHelpTail()
    for _, line in ipairs(HELP_LINES) do ns:Print(line) end
end
