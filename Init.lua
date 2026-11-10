-- Init.lua
-- 启动前置配置层：把「所有模块都要依赖的布局设置」在插件主体加载之前统一调整好，
-- 然后才放行 ns:StartModules()。这样各模块读到的第一份几何就是最终值，
-- 不需要在运行期反复重贴 / 自愈（动态 Mover 以后再做）。
--
-- 2026-11-10 判例：默认聊天框底边 145（暴雪编辑模式预设「现代」，来自
--   Blizzard_EditMode/Camelot/EditModePresetLayoutConstants.lua 的
--   CHAT_FRAME_ANCHOR_OFFSET_Y = 145），而我们动作条 / 小地图面板统一用
--   Utils/Layout.lua 的 bottom = 31 ⇒ 差 114 UI 单位。
-- Utils/Layout.lua 的旧注释说「聊天框对齐 ChatFrame1 的底边」，但
-- Modules/Skins/Social.lua 在 2026-10-29 已把聊天框贴底整个移除：
-- ChatFrame1 是 EditMode 系统帧（system=8），对它 ClearAllPoints/SetPoint/
-- SetClampRectInsets 会把帧永久标脏，编辑模式 secureexecuterange 遍历系统帧时
-- 整条执行被带脏（AGENTS / HANDOFF §3.1 的 taint 链）。
--
-- 因此这里走的是暴雪自己的官方路径：C_EditMode 的「另存布局」流程
-- （EditModeManagerFrame:MakeNewLayout → SaveLayouts → OnLayoutAdded），
-- 把当前预设深拷贝成一份玩家布局、只改 ChatFrame 一个系统的一条 anchorInfo，
-- 然后激活。全程不对任何系统帧 SetPoint、不覆写暴雪方法、不改预设表。

local ADDON_NAME, ns = ...

local Init = {}
ns.Init = Init

--- 所有前置设置的单一声明处。新增启动期设置往这里加，别散到各模块里再各自兜底。
Init.SETUP = {
    -- 贴底基线：动作条 Bar1、小地图面板、聊天框底边都用它（Utils/Layout.lua）。
    bottom = 31,
    -- 另存出来的布局名；C_EditMode.IsValidLayoutName 校验过。
    chatLayoutName = "MonetUI",
    -- 聊天框左边距沿用暴雪当前预设，不改水平位置。
    keepChatOffsetX = true,
}

Init.reason = "未运行"
Init.lastAlign = "未运行"

--- 数值漏斗：机密值 / 非数字一律不采信（12.x 判例）。
local function Num(v)
    local S = ns.Secrets
    if type(v) ~= "number" then return nil end
    if S and S.IsSecret and S.IsSecret(v) then return nil end
    return v
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[DeepCopy(k)] = DeepCopy(v) end
    return out
end

--- ① 静态阶段：文件加载期就跑，不依赖暴雪 UI / SavedVariables。
---    所有模块（ActionBars / Minimap / Skins）读 ns.Layout.bottom 时拿到的都是这个值。
function Init:ApplyStatic()
    if type(ns.Layout) ~= "table" then return end
    ns.Layout.bottom = self.SETUP.bottom
end

Init:ApplyStatic()

--- 只读几何诊断：聊天框底边 / 动作条底边 / 差值。
function Init:Geometry()
    local out = { bottom = self.SETUP.bottom }
    local cf = _G.ChatFrame1
    if cf and type(cf.GetBottom) == "function" then
        local ok, b = pcall(cf.GetBottom, cf)
        out.chatBottom = ok and Num(b) or nil
    end
    local bar = _G.MonetUIBar1
    if bar and type(bar.GetBottom) == "function" then
        local ok, b = pcall(bar.GetBottom, bar)
        out.barBottom = ok and Num(b) or nil
    end
    if out.chatBottom and out.barBottom then
        out.delta = out.chatBottom - out.barBottom
    end
    local em = _G.EditModeManagerFrame
    if em and type(em.GetActiveLayoutInfo) == "function" then
        local ok, cur = pcall(em.GetActiveLayoutInfo, em)
        if ok and type(cur) == "table" then
            out.layoutName = cur.layoutName
            out.layoutType = cur.layoutType
        end
    end
    return out
end

--- 是否已有我们另存的布局（防止重复新建）。
local function HasAlignedLayout(name)
    local em = _G.EditModeManagerFrame
    if not em or type(em.layoutInfo) ~= "table"
        or type(em.layoutInfo.layouts) ~= "table" then return false end
    for _, layout in ipairs(em.layoutInfo.layouts) do
        if type(layout) == "table" and layout.layoutName == name then return true end
    end
    return false
end

--- ② 一次性设置：把聊天框底边对齐到 SETUP.bottom。
---    force=true 时忽略「已对齐」标记（`/mui init run` 手动重跑）。
function Init:AlignChatBottom(force)
    local db = ns:DB().init
    local name = self.SETUP.chatLayoutName

    -- 幂等标记必须和布局实际存在性一起判（11-10 实机）：布局被玩家/编辑模式删掉，
    -- 或换账号后（Account 布局不共享），单看 chatAligned=true 会永久跳过重建，
    -- 表现就是「标记已对齐、lastAlign=未运行、聊天框却回到 145」。
    local layoutExists = HasAlignedLayout(name)
    if not force and db.chatAligned and layoutExists then
        self.lastAlign = "跳过：已标记对齐且布局仍在"
        return false, self.lastAlign
    end
    if db.chatAligned and not layoutExists then
        db.chatAligned = false   -- 布局不在，清标记让本次重建
    end
    if layoutExists then
        db.chatAligned = true
        self.lastAlign = "跳过：布局 " .. name .. " 已存在"
        return false, self.lastAlign
    end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        self.lastAlign = "跳过：战斗中"
        return false, self.lastAlign
    end

    local C, em = _G.C_EditMode, _G.EditModeManagerFrame
    if not (C and em and type(em.MakeNewLayout) == "function"
        and type(em.GetActiveLayoutInfo) == "function" and _G.Enum
        and _G.Enum.EditModeSystem and _G.Enum.EditModeLayoutType) then
        self.lastAlign = "跳过：编辑模式 API 未就绪"
        return false, self.lastAlign
    end

    local okCur, cur = pcall(em.GetActiveLayoutInfo, em)
    if not okCur or type(cur) ~= "table" or type(cur.systems) ~= "table" then
        self.lastAlign = "跳过：布局数据未就绪"
        return false, self.lastAlign
    end
    -- 只在预设布局上另存：玩家已经在用自定义布局时，不替他改整套布局。
    if cur.layoutType ~= _G.Enum.EditModeLayoutType.Preset then
        db.chatAligned = true
        self.lastAlign = "跳过：当前不是预设布局（不覆盖玩家自定义）"
        return false, self.lastAlign
    end

    local newLayout = DeepCopy(cur)
    newLayout.layoutIndex = nil       -- 用户布局没有这个字段，交给 MakeNewLayout 分配数组位置
    local chat
    for _, system in ipairs(newLayout.systems) do
        if type(system) == "table" and system.system == _G.Enum.EditModeSystem.ChatFrame then
            chat = system
            break
        end
    end
    if not chat or type(chat.anchorInfo) ~= "table" then
        self.lastAlign = "跳过：预设里没有 ChatFrame 的 anchorInfo"
        return false, self.lastAlign
    end

    -- 只改一条：底边偏移。水平位置、锚点方向、其余 58 个系统全部原样继承。
    -- **不要写 systemInfo.isInDefaultPosition**：AGENTS / HANDOFF §3.1 点名它是
    -- 编辑模式会读的脏值，addon 替玩家写会把 secureexecuterange 整条执行带脏
    -- （oldR / outOfRange 机密值报错）。ApplySystemAnchor 用的是 anchorInfo，
    -- 保留预设原值 true 即可，编辑模式里也仍显示「默认位置」。
    chat.anchorInfo.offsetY = self.SETUP.bottom

    -- MakeNewLayout 读 self.highestLayoutIndexByType[layoutType]；编辑模式 UI 未打开时
    -- 这张计数表可能还没建，补一个空表让它走 NumValues+1 的正常分支。
    if type(em.highestLayoutIndexByType) ~= "table" then
        em.highestLayoutIndexByType = {}
    end

    local okMake, makeErr = pcall(em.MakeNewLayout, em, newLayout,
        _G.Enum.EditModeLayoutType.Account, name, false)
    if not okMake then
        self.lastAlign = "失败：MakeNewLayout " .. tostring(makeErr)
        return false, self.lastAlign
    end

    -- 实机判例（2026-11-10）：PLAYER_LOGIN 阶段暴雪布局系统还没就绪，MakeNewLayout
    -- 不报错、但 C_EditMode.SaveLayouts 会被丢弃（激活布局仍是预设、聊天框回 145）。
    -- 所以必须以 C API 的读回结果为准，不能只看 pcall 成功。
    local okSaved, saved = pcall(C.GetLayouts)
    local persisted = false
    if okSaved and saved and type(saved.layouts) == "table" then
        for _, layout in ipairs(saved.layouts) do
            if type(layout) == "table" and layout.layoutName == name then
                persisted = true
                break
            end
        end
    end
    if not persisted then
        self.lastAlign = "失败：布局未保存（编辑模式尚未就绪）"
        return false, self.lastAlign
    end

    -- MakeNewLayout 里的 activateNewLayout 依赖 EditModeUnsavedChangesDialog 的状态，
    -- 早期可能为 false ⇒ 布局存下了却没激活。显式按内部索引激活一次。
    if type(em.layoutInfo) == "table" and type(em.layoutInfo.layouts) == "table" then
        for index, layout in ipairs(em.layoutInfo.layouts) do
            if type(layout) == "table" and layout.layoutName == name then
                pcall(C.SetActiveLayout, index)
                break
            end
        end
    end

    -- 布局确实存下了才打标记，别再建第二份。
    db.chatAligned = true
    self.lastAlign = "已另存并激活布局 " .. name

    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, function()
            local g = self:Geometry()
            if g.chatBottom and g.barBottom and math.abs(g.chatBottom - g.barBottom) <= 2 then
                ns:DevPrint(string.format("启动设置：聊天框底边已与动作条对齐（%.0f / %.0f）。",
                    g.chatBottom, g.barBottom))
            else
                ns:DevPrint(string.format(
                    "启动设置：布局 %s 已激活，但本帧聊天框底边 %.0f / 动作条 %.0f；/reload 后再用 /mui init status 复核。",
                    name, g.chatBottom or -1, g.barBottom or -1))
            end
        end)
    end
    return true, self.lastAlign
end

--- ③ 放行门闸 + 暴雪侧设置。
---    静态基线在文件加载期就已固定，模块不依赖聊天框位置，所以这里先放行
---    StartModules（各模块拿到的第一份几何就是最终值，不需要运行期重贴）。
---    聊天框这一项必须等暴雪 EditMode 就绪：实机验证 PLAYER_LOGIN 阶段调
---    MakeNewLayout 会静默丢保存，进世界之后再调才稳定。
function Init:Run(onReady)
    self:ApplyStatic()
    self.reason = "静态基线已就位，模块已放行"
    if onReady then onReady() end

    self.attempts = 0
    local try
    try = function()
        local db = ns:DB().init
        if db.chatAligned and HasAlignedLayout(self.SETUP.chatLayoutName) then return end
        self.attempts = self.attempts + 1
        if self.attempts > 2 then
            self.lastAlign = self.lastAlign .. "；自动重试已用尽，可手动 /mui init run"
            return
        end
        local ok, why = pcall(self.AlignChatBottom, self, false)
        if not ok then
            self.lastAlign = "异常：" .. tostring(why)
        end
        if not ns:DB().init.chatAligned and _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(1, try)
        end
    end

    local scheduled = false
    local function schedule()
        if scheduled then return end
        scheduled = true
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0.2, try)   -- 进世界后再让一帧，等布局系统收尾
        else
            try()
        end
    end

    if ns.EventBus and ns.EventBus.Register then
        pcall(ns.EventBus.Register, ns.EventBus, "PLAYER_ENTERING_WORLD", schedule)
    end
    -- 事件已经错过（读图 / 计时器异常）时的兜底，绝不让设置永远不做。
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(3, schedule)
    else
        schedule()
    end
end

--- `/mui init status` 的输出。
function Init:Status()
    local g = self:Geometry()
    local db = ns:DB().init
    ns:Print(string.format("|cffffd100启动设置|r：基线 %d，放行=%s，标记=%s",
        self.SETUP.bottom, tostring(self.reason), tostring(db.chatAligned == true)))
    ns:Print(string.format("  聊天框底边 %s / 动作条底边 %s / 差值 %s",
        tostring(g.chatBottom or "读不到"), tostring(g.barBottom or "读不到"),
        tostring(g.delta or "读不到")))
    ns:Print(string.format("  当前布局 %s（type=%s）；对齐布局 %s 存在=%s；上次对齐：%s",
        tostring(g.layoutName or "读不到"), tostring(g.layoutType or "读不到"),
        tostring(self.SETUP.chatLayoutName), tostring(HasAlignedLayout(self.SETUP.chatLayoutName)),
        tostring(self.lastAlign)))
end
