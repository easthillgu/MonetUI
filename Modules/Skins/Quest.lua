-- Modules/Skins/Quest.lua
-- Questing windows: the quest log (standalone QuestLogFrame on clients that still have one) and the NPC quest / gossip dialog windows.
-- Quest *content* (objective text, reward icons) is deliberately left alone -- only the frame's own chrome is faded, so item buttons keep working.

local ADDON_NAME, ns = ...

local M = ns.Skins
local Media = ns.Media
local Widget = ns.Widget
local Skin = ns.Skin

-- 任务对话框斜纹底板：暗色半透明衬底 + monet_stripe_weave + 亮色文字。
-- 替代原来的 Strip + Panel（纯深色底），解决暴雪 FontString 在深底上看不清的问题。
local WEAVE_SIZE = 64
local Mark = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

-- 按当前尺寸重算斜纹 texcoord（两轴同一密度 → 45° 不变形）
local function UpdateWeave(panel)
    local weave = Marked(panel, "questWeave")
    if not weave then return end
    local tex = Media.texture["monet_stripe_weave"]
    if not tex then return end
    weave:SetTexture(tex, "REPEAT", "REPEAT")
    local mult = Media:Mult()
    local w = panel:GetWidth() or 0
    local h = panel:GetHeight() or 0
    if w > 0 and h > 0 and mult > 0 then
        local cols = w / (mult * WEAVE_SIZE)
        local v0 = 1 / WEAVE_SIZE
        local v1 = v0 + h / (mult * WEAVE_SIZE)
        weave:SetTexCoord(0, cols, v0, v1)
    end
end

-- 递归提亮暗色 FontString（暴雪正文 0,0,0 / 深棕，深底上看不清）
-- 每一步都 pcall：任务面板里有受保护的子控件，`GetObjectType` / `GetChildren` 在零售构建上
-- 会直接抛 "forbidden object"。以前不包，一条抛错就把整棵树的提亮中断在半路（表现为"一半文字还是黑的"）。
local function BrightenTree(f)
    if not f or type(f.GetObjectType) ~= "function" then return end
    local okKind, kind = pcall(f.GetObjectType, f)
    if okKind and kind == "FontString" then
        local ok, r, g, b = pcall(f.GetTextColor, f)
        if ok and r and r < 0.55 and g < 0.55 and b < 0.55 then
            pcall(f.SetTextColor, f, 0.88, 0.86, 0.82, 1)
        end
    end
    if type(f.GetChildren) == "function" then
        local ok, kids = pcall(function() return { f:GetChildren() } end)
        if ok and kids then
            for i = 1, #kids do BrightenTree(kids[i]) end
        end
    end
end

local function WeavePanel(panel, opts)
    if not panel then return end
    opts = opts or {}
    local baseAlpha = opts.baseAlpha or 0.70
    local weaveAlpha = opts.weaveAlpha or 0.30
    local weaveColor = opts.weaveColor or { 0.55, 0.53, 0.50 }

    -- 去掉暴雪原始贴图和边框
    ns.Skin:Strip(panel)

    -- 衬底层：半透明深色，控制底板的整体明度
    local bg = Marked(panel, "questBg")
    if not bg then
        bg = panel:CreateTexture(nil, "BACKGROUND", nil, -2)
        bg:SetAllPoints(panel)
        Mark(panel, "questBg", bg)
    end
    bg:SetColorTexture(0.12, 0.12, 0.14, baseAlpha)

    -- 斜纹层：monet_stripe_weave 铺满，ADD 混合做柔光
    local weave = Marked(panel, "questWeave")
    if not weave then
        weave = panel:CreateTexture(nil, "BACKGROUND", nil, -1)
        weave:SetAllPoints(panel)
        weave:SetBlendMode("ADD")
        Mark(panel, "questWeave", weave)
    end
    weave:SetVertexColor(weaveColor[1], weaveColor[2], weaveColor[3], weaveAlpha)
    UpdateWeave(panel)

    BrightenTree(panel)
end

-- 任务窗口的四块正文底板：换肤一次，暴雪 Show 之后再提亮一次（任务数据是 Show 后才塞进来的）。
local QUEST_PANELS = {
    "QuestFrameGreetingPanel", "QuestFrameProgressPanel",
    "QuestFrameRewardPanel", "QuestFrameDetailPanel",
}

local QUEST_FONTS = {
    "QuestProgressText", "QuestGreetingText", "QuestDetailText",
    "QuestRewardText", "QuestProgressRequiredItemsText",
    "QuestProgressRequiredMoneyText", "QuestProgressCompleteText",
    "QuestProgressShowItemsText", "QuestRewardChoiceRequiredText",
    "QuestRewardTextRequiredText",
}

-- 模块级函数 = 稳定引用：SkinQuestFrame 会被 QUEST_LOG_UPDATE 反复触发，
-- 在 Apply 里现造闭包的话每次触发都多挂一条回调（M:HookShow 按引用去重）。
local function BrightenQuestPanels()
    M:Controls(QUEST_PANELS, function(panel)
        UpdateWeave(panel)
        BrightenTree(panel)
    end)
    -- 正文是挂在窗口外的全局 FontString，也要一起提亮
    M:Controls(QUEST_FONTS, function(fs)
        local ok, r, g, b = pcall(fs.GetTextColor, fs)
        if ok and r and r < 0.55 and g < 0.55 and b < 0.55 then
            pcall(fs.SetTextColor, fs, 0.88, 0.86, 0.82, 1)
        end
    end)
end

local function HookQuestBrighten(frame)
    M:HookShow(frame, BrightenQuestPanels)
end

-- 对话选项按钮（GossipGreetingButton1..8）是暴雪在 Show 那一刻才建出来 / 复用的。
-- 模块级函数 + 稳定引用，重复 Apply 不会重复登记回调；查找记在 questframe 名下。
local function RestyleGossipButtons()
    Skin.With("questframe", function()
        if not (Skin:Need("GossipFrame.GreetingPanel") or Skin:Need("GossipFrameGreetingPanel")) then
            return
        end
        for index = 1, 8 do
            M:Dress("GossipGreetingButton" .. index, { as = "button" })
        end
    end)
end

local QUESTLOG_BUTTONS = {
    "QuestLogFrameAbandonButton", "QuestLogFrameTrackButton", "QuestLogFrameShareButton",
    "QuestLogFrameCancelButton", "QuestLogFramePushQuestButton",
}

local QUESTLOG_TABS = { "QuestLogFrameTab1", "QuestLogFrameTab2" }

local QUESTLOG_SCROLLS = {
    "QuestLogListScrollFrame", "QuestLogDetailScrollFrame", "QuestLogObjectiveScrollFrame",
}

-- 阅读型窗口一档 0.965（DESIGN-LANGUAGE §2 的独立一档）：任务日志 / 任务详情 / 剧情 / 书信。
-- 为什么不是 0.97：那一档是**对话框**（挡操作、要压住世界）；阅读窗口是"长时间对着看"，
-- 0.965 比常规窗口(0.96)更实、又不像弹窗那样闷。为什么不取 0.965~0.97 之间别的数：
-- 阶梯一个值一个语义，多出来的小数点只会让下一个人猜。
local READ_ALPHA = 0.965

local function SkinQuestLog()
    M:Dress("QuestLogFrame", { window = true, panel = { bgAlpha = READ_ALPHA } })
    M:Dress(QUESTLOG_BUTTONS, { as = "button" })
    M:Dress(QUESTLOG_TABS, { as = "tab" })
    M:Dress(QUESTLOG_SCROLLS, { as = "scroll" })

    M:Dress("QuestLogDetailFrame", { window = true, noTitle = true, panel = { bgAlpha = READ_ALPHA } })
    M:Dress("QuestLogPopupDetailFrame", { window = true, noTitle = true, panel = { bgAlpha = READ_ALPHA } })
end

local QUESTFRAME_BUTTONS = {
    "QuestFrameAcceptButton", "QuestFrameDeclineButton", "QuestFrameCompleteButton",
    "QuestFrameCompleteQuestButton", "QuestFrameGoodbyeButton", "QuestFramePushQuestButton",
}

local QUESTFRAME_SCROLLS = {
    "QuestProgressScrollFrame", "GossipGreetingScrollFrame", "QuestInfoObjectiveScrollFrame",
}

local function SkinQuestFrame()
    M:Dress("QuestFrame", { window = true, panel = { bgAlpha = READ_ALPHA } })
    M:Dress(QUESTFRAME_BUTTONS, { as = "button" })
    M:Dress(QUESTFRAME_SCROLLS, { as = "scroll" })

    -- 斜纹底板：暗色衬底 + monet_stripe_weave，解决暴雪正文在深底上看不清的问题
    M:Controls(QUEST_PANELS, function(panel)
        WeavePanel(panel, { baseAlpha = 0.70, weaveAlpha = 0.30 })
    end)

    -- Show 后再亮一次（暴雪 quest 数据是 Show 后才塞的）
    HookQuestBrighten(Skin:Need("QuestFrame"))

    M:Dress("GossipFrame", { window = true, panel = { bgAlpha = READ_ALPHA } })
    M:Dress(QUESTFRAME_SCROLLS, { as = "scroll" })
    M:Dress("GossipFrameGreetingGoodbyeButton", { as = "button" })

    M:HookShow(Skin:Need("GossipFrame"), RestyleGossipButtons)
end

-- The quest objective tracker that sits under the minimap.  It has no tabs and no chrome of its own --
-- just a header, a scroll and a list of tracker blocks, so the header font and the scroll carry it.
local TRACKER_HEADERS = { "ObjectiveTrackerHeader", "QuestLogObjectiveHeader" }

-- 追踪框每次显示都会重建/复用里面的行，所以显示时把滚动条补扫一遍、原底板再压一次。
-- 写成模块级函数：SkinObjectiveTracker 会被每次 Apply 触发，闭包会重复登记。
local function RepressObjectiveTracker()
    Skin.With("objectivetracker", function()
        local tracker = Skin:Need("ObjectiveTrackerFrame")
        if not tracker then return end
        M:SkinScrollsIn(tracker)
        ns.Skin:Strip(tracker, { regions = false, backdrops = true })
    end)
end

local function SkinObjectiveTracker()
    local tracker = Skin:Need("ObjectiveTrackerFrame")
    if not tracker then return end

    -- QuestTracker 模块默认开着，并且把暴雪的追踪框整个隐藏、自己画一份（QuestTracker.lua:305
    -- SuppressBlizzard）。给一个玩家永远看不见的框架换字体/关贴图不只是白做 —— 它会把这个框架
    -- 染成我们的，之后暴雪自己的布局代码里读光环就被拒，实机报过：
    --   GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'MonetUI'
    --   （Blizzard_MawBuffs → ScenarioObjectiveTracker:LayoutContents）
    -- 所以只有玩家关掉 QuestTracker、暴雪追踪框真的在显示时，才需要这层皮肤。
    if ns:IsModuleEnabled("QuestTracker") then return end

    -- Only the header: the blocks below it are content and must stay legible.
    M:Controls(TRACKER_HEADERS, function(header)
        local text = header.Text or (type(header.GetName) == "function"
            and header:GetName() and _G[header:GetName() .. "Text"])
        if text then ns.Skin:Font(text, 12, "pixel", nil, "edge") end
    end)

    M:HookShow(tracker, RepressObjectiveTracker)
end

M:Panel("objectivetracker", {
    label = "目标追踪",
    group = "任务",
    apply = SkinObjectiveTracker,
    frames = { "ObjectiveTrackerFrame", TRACKER_HEADERS },
})

M:Panel("questlog", {
    label = "任务日志",
    group = "任务",
    apply = SkinQuestLog,
    frames = {
        "QuestLogFrame", "QuestLogDetailFrame", "QuestLogPopupDetailFrame",
        QUESTLOG_BUTTONS, QUESTLOG_TABS, QUESTLOG_SCROLLS,
    },
})

M:Panel("questframe", {
    label = "任务 / 对话窗口",
    group = "任务",
    apply = SkinQuestFrame,
    frames = {
        "QuestFrame", "GossipFrame", "GossipFrame.GreetingPanel", "GossipFrameGreetingPanel",
        QUEST_PANELS, QUEST_FONTS, QUESTFRAME_BUTTONS, QUESTFRAME_SCROLLS,
        "GossipFrameGreetingGoodbyeButton",
        -- 对话选项按钮只有 1 号写在名单里：其余 7 个在同一趟循环里按名拼接（见 RestyleGossipButtons），
        -- 全列出来只是把"暴雪有没有建到第 8 个"当成我们的错报。
        "GossipGreetingButton1",
    },
})

-- The windows are load-on-demand and rebuilt as quests change; re-apply.
M:OnEvent("QUEST_LOG_UPDATE", function()
    M:Apply(M.byKey.questlog)
    M:Apply(M.byKey.questframe)
end)

-- 书籍 / 信件正文阅读窗：UIPanels_Game 的 [Family] ItemTextFrame 无 game-type 门控，本客户端存在。
local function SkinItemText()
    M:Dress("ItemTextFrame", {
        window = true,
        panel = { bgAlpha = READ_ALPHA },
        buttons = { "ItemTextNextPageButton", "ItemTextPrevPageButton" },
        scrolls = { "ItemTextScrollFrame" },
    })
    Skin:PageArrow(Skin:Need("ItemTextPrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("ItemTextNextPageButton"), "right")
end

M:Panel("itemtext", { label = "书籍 / 阅读", group = "任务", apply = SkinItemText,
    frames = {
        "ItemTextFrame", "ItemTextFrame.CloseButton",
        "ItemTextNextPageButton", "ItemTextPrevPageButton", "ItemTextScrollFrame",
    } })
