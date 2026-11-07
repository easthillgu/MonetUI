-- Modules/Minimap/MicroMenu.lua
-- 右键小地图弹出的微型游戏菜单：一列游戏面板的快捷入口，面板用统一的 Monet 材质。
--
-- 入口全部"存在才画"：每一行要么把点击**安全转发**给暴雪自己的那颗微按钮
-- （`SecureActionButtonTemplate` + `type="click"`），要么只有一个**纯 C_* API** 动作
-- （`Settings.OpenToCategory` / `C_Map.OpenWorldMap` / 我们自己的模块）。两者都拿不到就不建行。
-- **不再有**"探测 _G 里的暴雪开关函数然后调用它"这条路 —— 那是 11-05 开服 P0 的写法（§8.36）。

local ADDON_NAME, ns = ...

local Widget = ns.Widget

local M = {}

local ROW_H  = 16
local MENU_W = 56

local frame      -- 菜单面板
local catcher    -- 点别处关闭
local rows       -- 已建的行

--- 入口定义：**只允许 `luaAction`，而且只能是纯 C_* API 或我们自己的模块**。
---
--- ⚠ 11-05 开服实测（`/mui minimap menu`）：这里曾给每行做 `SecureActionButtonTemplate` +
--- `type="click"` 去代点暴雪微按钮，结果是 **面板自己 `IsProtected()=true`、`GetNumPoints()=0`** ——
--- 13 颗安全行锚进面板这个家族，把面板一起标成受保护，之后 `frame:SetPoint/SetHeight`
--- 全部**静默丢弃**（不记 BLOCKED、不报错），玩家看到的就是「右键小地图没反应」。
--- 信息栏那一版是同一个机制、只是它的写入会记日志（HANDOFF §8.36 / §8.37 / §8.38）。
--- ⇒ 硬规矩：安全模板控件绝不锚到「我们要重摆 / 逐拍排版」的框上。
---
--- 代价说清楚：**这一版微菜单只剩三行**。角色 / 法术 / 任务 / 成就 / 好友 / 收藏 / 副本 /
--- 职业 / 寻找组 / 住房 / 商店 / 帮助 在本客户端**没有纯 C_* 开窗 API**（docs/api 快照里 Open 动词
--- 只有 `C_Map.OpenWorldMap` / `C_Calendar.OpenCalendar` / `C_TradeSkillUI.OpenTradeSkill` /
--- `C_SettingsUtil.OpenSettingsPanel` 这一小撮），而调暴雪 Lua 全局是被禁止的 P0 写法。
--- 要恢复它们走 #43 的独立安全载体，不要在这里重试第二种安全模板写法。
--- 动作抽成**函数**并导出（11-07；定向动作现为 `character` —— `questlog` / `talent` 随任务、专精两格删除撤掉）：
--- 信息栏的格子（`Blocks.lua`）也要用同一批动作，
--- 而 AGENTS 的规矩是"一处判据一份实现" —— 入口表可以各开各的，**开窗逻辑不能抄第二份**。
local function OpenBags()
    -- 我们自己的背包窗口，动作全在我们名下（`ToggleAllBags` 是暴雪 Lua 全局，不许调）。
    local bags = ns:GetModule("Bags")
    if bags and type(bags.Toggle) == "function" then bags:Toggle(true) end
end

local function OpenMap()
    -- `C_Map.OpenWorldMap` 文档标 [受限]：受限窗口里一行都不做，别让它替我们撞墙。
    if ns:IsRestricted() then return end
    local C_Map = _G.C_Map
    if C_Map and type(C_Map.OpenWorldMap) == "function" then C_Map.OpenWorldMap() end
end

local function OpenCalendar()
    -- 11-05 实测：本客户端的纯 C_* 开窗动词只有 `OpenWorldMap`/`OpenCalendar`/`OpenTradeSkill(要 skillLineID)`/
    -- `OpenSettingsPanel` 这一小撮（`/run` 扫遍所有 `C_*.Open*`）。日历是其中唯一无参、能直接加进行里的。
    if ns:IsRestricted() then return end
    local C_Calendar = _G.C_Calendar
    if C_Calendar and type(C_Calendar.OpenCalendar) == "function" then C_Calendar.OpenCalendar() end
end

local function OpenSettings()
    -- `Settings.OpenToCategory` 是客户端 C 侧 API，不会把暴雪的 Lua 面板链拉进我们的执行环境
    -- （对比：`ToggleGameMenu` 是暴雪 Lua 函数，已撤掉）。
    local settings = _G.Settings
    if settings and type(settings.OpenToCategory) == "function" and settings.INTERFACE_CATEGORY_ID then
        return settings.OpenToCategory(settings.INTERFACE_CATEGORY_ID)
    end
end

--- 打开 #43 那个代点坞（`MicroMenuSecure`）的**全量菜单**。现在它是兜底：
--- 信息栏里"需要代点才能开的暴雪面板"的格子优先走下面的 `OpenTargeted`（贴着格子、只留对应一行），
--- 那条路拿不到东西时才退回这里开全量坞。
--- 信息栏本身**永远不能碰安全模板**（内容驱动排版，AGENTS 硬判据 / HANDOFF §8.64），
--- 所以这两条路都是"坞开在别处、第二击才到面板"，坞不在信息栏的锚定家族里，
--- 不会把信息栏标成受保护。
local function OpenMicroDock()
    local minimap = ns:GetModule("Minimap")
    local dock = minimap and minimap.microMenuSecure
    if dock and type(dock.Toggle) == "function" then dock:Toggle() end
end

--- 定向开（11-07，信息栏"点什么出什么"）：代点坞筛成只剩 `btnName` 那一行、贴着被点的格子开。
--- `OpenTarget` 返回 false 的四种情况（受限窗口 / 载体没建成 / 那一行没建出来 / 锚点读不出）
--- 一律由这里退回通用坞 —— **静默什么都不做**是本仓最难查的缺陷形态。
local function OpenTargeted(anchor, btnName)
    local minimap = ns:GetModule("Minimap")
    local dock = minimap and minimap.microMenuSecure
    if dock and type(dock.OpenTarget) == "function" and dock:OpenTarget(anchor, btnName) then
        return
    end
    OpenMicroDock()
end

--- 耐久格 → 角色界面（11-07 作者指示）：代点坞只留「角色」一行（`CharacterMicroButton` 是
--- 实机探针 12 颗原生微按钮之一），第二击由安全按钮代点开角色面板。
--- **不要**改成直调 `_G.ToggleCharacter`：那条正是 `InfoBar.lua` 头上 11-05 开服 P0 的原路
--- （ToggleCharacter → PaperDoll 读属性 → `TextStatusBar.lua:110` 机密值比较、按 MonetUI 记账）。
--- 任务 / 专精 两个定向动作（`questlog` / `talent`）随两格删除一并撤掉（11-07）。
local function OpenCharacter(anchor) OpenTargeted(anchor, "CharacterMicroButton") end

--- 好友格（11-07）：本客户端**没有**好友/社交的原生微按钮（实机探针：`MicroMenu` 只有 12 颗，
--- `FriendsMicroButton` / `SocialMicroButton` 都是 nil），定向代点坞对这格没有目标行；
--- `C_FriendList.ShowFriends()` 实测只刷新数据、不开面板。唯一能开社交窗的入口是
--- **暴雪 Lua 全局** `_G.ToggleFriendsFrame` —— 这是 AGENTS"暴雪 Lua 全局一律不碰"的
--- **作者批准例外**（2026-11-07 拍板），接线前在 1.60.1.70840 实测过三条：
---   ① 开窗成功：走 `SocialUIControl.IsEnabled()==true` → `SocialUIControl.Toggle()` → `SocialUIFrame`；
---   ② 前置全放行：`Kiosk.IsEnabled()=false`、`IngameFriendsListDisabled`（GameRule 79）`=false`；
---   ③ `taintLog=2` 下 open+close 各一次，`taint.log` **零新增**（SocialUI / FriendsFrame 关键字 0 条）。
--- 出错由 `BlockClick` 外层的 pcall 兜住（格子点了没反应，不报错）。
--- 若哪天它开始记 taint：撤回这里、退回 `dock`（改动只有 `Blocks.lua` 一行 + 本函数）。
local function OpenFriends()
    local fn = _G.ToggleFriendsFrame
    if type(fn) == "function" then fn() end
end

local ENTRIES = {
    { label = "背包", luaAction = OpenBags },
    { label = "地图", luaAction = OpenMap },
    { label = "日历", luaAction = OpenCalendar },
    { label = "设置", luaAction = OpenSettings },
}

-- 导出给信息栏用（同一个函数对象，不是复制一份实现）。
-- 统一签名：`fn(anchor)`，anchor = 被点那格的帧（`Blocks.lua` 的 `block.frame`）。
-- 只有定向的（现为 `character`）用它（菜单要贴着格子开），其余动作忽略这个参数。
M.actions = {
    bags     = OpenBags,
    map      = OpenMap,
    calendar = OpenCalendar,
    settings = OpenSettings,
    dock     = OpenMicroDock,
    character = OpenCharacter, -- 信息栏"耐久"格：只留「角色」一行，贴着格子开（两击）
    friends  = OpenFriends,    -- 信息栏"好友"格：直开社交窗（作者批准的例外，见 OpenFriends 头注）
}

--- 曾经这里按名字取暴雪那颗微按钮、把行做成安全按钮去代点它。11-05 实测：那些行锚进面板
--- 之后面板 `IsProtected()=true`，自己的 `SetPoint` 被静默丢弃 ⇒ 菜单展不开（ENTRIES 上方注释）。
--- 所以这里**不再有第二种动作源**：行只有 `luaAction`（纯 C_* API / 我们自己的模块）这一条路。
---
--- **11-06 加的唯一出口**：`#43` 那版独立安全载体（`MicroMenuSecure.lua`）要在它的菜单里也放这几行
--- （右键开着载体时本文件的 4 行菜单不参与，见 `Minimap.lua` 的右键分发），
--- 但入口定义**只能有一份** —— 这里导出，载体那边读，不许抄第二份。
M.ownEntries = ENTRIES

--- 只剩"纯 C_* API"可以留在 Lua 里直接调（不牵动暴雪的 Lua 面板链，也不会把机密值比较
--- 带进我们的环境）。`Settings.OpenToCategory` 属于这类；`ToggleGameMenu` 属于暴雪 Lua 函数，
--- **不再当备用动作**（以前会走到它，正是那条红字的来源之一）。
local function SafeActionFor(entry)
    return (type(entry.luaAction) == "function") and entry.luaAction or nil
end

--- 菜单贴着地图左上角展开（向左下），比"跟着鼠标跑"稳：地图本来就在屏幕右下角，
--- 菜单往左展开一定完整可见，不用去猜鼠标的屏幕坐标换算。
local function Build()
    if frame then return frame end

    frame = Widget:CreateFrame("MonetUIMinimapMicroMenu", UIParent, MENU_W, 40)
    -- 直角版（square-blp）：不带 round，走 SetBackdrop 的直角边框。
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.96, borderAlpha = 1 })
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(20)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    rows = {}
    local y = -4
    for _, entry in ipairs(ENTRIES) do
        local action = SafeActionFor(entry)
        if action then
            -- **普通按钮**，不是 SecureActionButtonTemplate：安全模板锚进面板会把面板标成受保护，
            -- 面板自己的 SetPoint/SetHeight 随后被静默丢弃（11-05 实测，见 ENTRIES 上方）。
            local row = CreateFrame("Button", nil, frame)
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, y)
            row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, y)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)
            row:RegisterForClicks("LeftButtonUp")

            local label = Widget:Font(row, 12, "pixel", "neutral", "CENTER")
            label:SetPoint("LEFT", row, "LEFT", 4, 0)
            label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            label:SetText(entry.label)

            row:SetScript("OnClick", function()
                -- 只有纯 C_* API / 我们自己的模块会走到这里（ENRIES 造行时就筛过一遍）。
                pcall(action)
                M:Close()
            end)
            row:SetScript("OnEnter", function() Widget:ColorText(label, "highlight") end)
            row:SetScript("OnLeave", function() Widget:ColorText(label, "neutral") end)

            rows[#rows + 1] = row
            y = y - (ROW_H + 1)
        end
    end

    frame:SetHeight(math.abs(y) + 10)

    -- 点别处关闭：整屏 catcher，层级比菜单低，菜单自己的点击不会被它吃掉。
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(10)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() M:Close() end)
    catcher:Hide()

    return frame
end

--- 现在有没有别的菜单开着？
--- 暴雪的追踪菜单、LibDBPanel 这类插件会在同一次右键里开菜单；我们再 Toggle 一次，
--- 人家刚开的菜单就被我们关掉了（同一个右键既开又关，看着像"点了没反应"）。
--- AishCore 的做法：查 DropDownList1 与菜单管理器（Comfort.lua 544-551）。
local function AnyMenuOpen()
    local list = _G.DropDownList1
    if list and list.IsShown then
        local ok, shown = pcall(list.IsShown, list)
        if ok and shown then return true end
    end
    local menu = _G.Menu
    if menu and menu.GetManager then
        -- 布尔换算也放在 pcall 里：万一返回值是保密值，条件判断会直接报错
        local ok, anyOpen = pcall(function()
            local open = menu.GetManager():GetOpenMenu()
            return open and true or false
        end)
        if ok and anyOpen then return true end
    end
    return false
end

-- 11-06：`MicroMenuSecure.lua`（#43 全量载体）也要同一道判断，导出给那边读 ——
-- 单源，不在第二个文件里抄一份"什么叫别的菜单开着"。
M.anyMenuOpen = AnyMenuOpen

--- 在小地图旁边弹出（anchor 一般是小地图面板）。
function M:Toggle(anchor)
    if frame and frame:IsShown() then
        self:Close()
        return
    end
    -- 已经有别的菜单开着就别抢（见 AnyMenuOpen 的说明）
    if AnyMenuOpen() then return end
    Build()
    if not frame then return end

    frame:ClearAllPoints()
    if anchor then
        frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -6, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    frame:Show()
    if catcher then catcher:Show() end
end

function M:Close()
    if frame then frame:Hide() end
    if catcher then catcher:Hide() end
end

function M:IsOpen()
    return frame and frame:IsShown() and true or false
end

--- `/mui minimap menu` 用（11-05 开服实测：玩家报"右键小地图没出菜单"，而这台机器的 taint.log
--- 对 `ADDON_ACTION_BLOCKED` 零记录，拿不到栈 ⇒ 只能把判据做成一条命令）。
--- 报三件事，每件都指向一个不同的原因：
---   ① 行能不能建出来（入口名在本客户端不存在 ⇒ 那一行整个消失，不是"点了没反应"）；
---   ② 面板/行**是不是受保护**（安全模板锚到我们要重摆的框会把整条面板传染成受保护 ——
---      信息栏 §8.37 就是这么炸的，这里就是那条风险的现场复验）；
---   ③ 开关与展开状态（设置关着 ⇒ 右键那条 `if` 根本不走到这里）。
function M:Probe(enabledSetting)
    local actions, skipped = 0, {}
    for _, entry in ipairs(ENTRIES) do
        if SafeActionFor(entry) then actions = actions + 1 else skipped[#skipped + 1] = entry.label end
    end

    if not frame then Build() end
    if not frame then
        ns:Print("|cffff6b6b面板造不出来|r（入口里一个合法动作都没有）")
        return
    end

    local protFrame = (type(frame.IsProtected) == "function") and frame:IsProtected() or false
    local rowProt = 0
    for _, row in ipairs(rows or {}) do
        if type(row.IsProtected) == "function" and row:IsProtected() then rowProt = rowProt + 1 end
    end
    local np = (type(frame.GetNumPoints) == "function") and frame:GetNumPoints() or "?"
    -- GetRect 返回 left, bottom, width, height（四个角是读不出来的，11-04 记过）
    local rl, rb, rw, rh
    if type(frame.GetRect) == "function" then rl, rb, rw, rh = frame:GetRect() end

    ns:Print(("微菜单：入口 %d · 有合法动作 %d · 无动作跳过 %s"):format(
        #ENTRIES, actions, (#skipped > 0) and table.concat(skipped, "、") or "无"))
    ns:Print(("面板：已建 · 受保护=%s · 行 %d 颗（其中受保护 %d）· 锚点数=%s · 矩形=%s · 高 %.1f · shown=%s"):format(
        tostring(protFrame), #(rows or {}), rowProt, tostring(np),
        (rl and string.format("%.0f,%.0f %.0fx%.0f", rl, rb, rw or 0, rh or 0)) or "读不出",
        frame:GetHeight() or 0, tostring(frame:IsShown())))
    ns:Print(("设置 microMenu=%s ⇒ %s"):format(tostring(enabledSetting),
        enabledSetting and "右键会走到这里" or "右键不会走到这里（模块里那道 if 直接跳过）"))

    if protFrame or rowProt > 0 then
        ns:Print("|cffff6b6b判读：这一族里还有受保护对象|r ⇒ 我们自己的 SetPoint/SetHeight 会被**静默丢弃**"
            .. "（不记 BLOCKED、也不报错），症状就是「右键没反应」。成因一直是行上挂了安全模板。")
    elseif np == 0 then
        ns:Print("|cffff6b6b判读：面板一个锚点都没有|r ⇒ 上一次 Toggle 的 SetPoint 没落地"
            .. "（事件进来了、面板也建了，就是没位置）。")
    else
        ns:Print("判读：面板是普通框、锚点就位 ⇒ 若还展不开，只剩「此刻右键落点不在遮罩上」或「别的菜单抢了这次点击」（看最后一行）。")
    end
end

ns:GetModule("Minimap").microMenu = M
