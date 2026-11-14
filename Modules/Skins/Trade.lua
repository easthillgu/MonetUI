-- Modules/Skins/Trade.lua
-- Mail, merchant, trainer, auction house, professions, the bank and the trade window.  Item rows keep
-- their icons: only chrome buttons, tabs and scroll bars are restyled.

local ADDON_NAME, ns = ...

local M      = ns.Skins
local Skin   = ns.Skin
local Widget = ns.Widget
local Color  = ns.Color

-- 交易窗口 plus the two money frames that pop up beside it.  Both are separate frames that
-- stay on screen while the trade is open, so they need their own treatment, not the main frame's.
-- 12.1.5 实机取到的真名：判定 / 取消是 `TradeFrameTradeButton` / `TradeFrameCancelButton` ——
-- `AcceptTradeButton` / `CancelTradeButton` / `AcceptAllTradesButton` / `TradeFrameToggleReciprocate`
-- 在本客户端一个都不存在（那些只会让 `Skin:Need` 记 miss，按钮保持原样）。
local TRADE_BUTTONS = { "TradeFrameTradeButton", "TradeFrameCancelButton" }

-- 金额输入：接受方那个叫 `TradeRecipientMoneyFrame`（不是 `...InputMoneyFrame`）；
-- 旁边那组 Okay / Cancel 小按钮整组不存在（金额是内联输入框），所以只收拾两个 money frame。
local TRADE_MONEY_FRAMES = { "TradePlayerInputMoneyFrame", "TradeRecipientMoneyFrame" }

--- 物品格按钮铺平 + 方形描边已上移为 Dress 引擎的**默认档**（Skins.lua 的
--- IconWidgetsIn：压圆角 IconMask / 原生槽框 + 8% 裁切 + 1px 主题方边），这里不再本地实现。

local function SkinTrade()
    M:Dress("TradeFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = TRADE_BUTTONS,
        -- 交易窗是多内容窗口（实机 2026-11-02 枚举）：对方/我方物品区、附魔区、金额输入区
        -- 各是独立的 Inset 框；金钱两件是控件底语义（不上签名色边）。
        wells = {
            TradeRecipientItemsInset = true,
            TradePlayerItemsInset = true,
            TradeRecipientEnchantInset = true,
            TradePlayerEnchantInset = true,
            TradePlayerInputMoneyInset = true,
            TradeRecipientMoneyInset = { borderAlpha = 0 },
            TradeRecipientMoneyBg = { panel = false },
        },
        -- 物品格铺平裁切走引擎默认档（双方物品 6+6 + 附魔格，认 .icon 指纹不点名）。
    })
    -- 金额输入框：以前把 `panel` 塞进 Skin:Panel 的参数里（它读的是 opts.bgAlpha），
    -- 底衬一直是默认的 0.85 而不是 0.96；走 Dress 之后参数只有一层，不会再套错。
    M:Dress(TRADE_MONEY_FRAMES, { panel = { bgAlpha = 0.96 }, deep = true })
end

local MAIL_FRAMES = { "MailFrame", "InboxFrame", "SendMailFrame", "OpenMailFrame" }

-- **11-05 实机（邮箱开过）**：`InboxFrameOpenButton` / `…ReplyButton` / `…DeleteButton` /
-- `InboxPrevPageButton` / `InboxNextPageButton` 与三种 `…MailListScrollFrame` 拼法**都没有实名**
-- —— 1.60 的收件箱按钮和列表挂在 `MailFrame`/`InboxFrame` 的 `parentKey` 子件上，
-- 滚动区是 `ScrollBox` + `MinimalScrollBar`。⇒ 点名摘掉，收件箱由 `MAIL_FRAMES` 的 `deep` 接住
-- （§8.40 ②）。发送邮件那一侧的两个按钮 + `OpenAllMail` 有实名，保留。
local MAIL_BUTTONS = {
    "SendMailMailButton", "SendMailCancelButton",
    -- 70450 起邮件收取走 C_SecureTransfer（TakeMailMoney + MAIL_OPEN_ALL_CANCELED），
    -- 收件箱多了"一键收取"按钮 OpenAllMail（全局名，Ellesmere 同客户端实机名单佐证）。
    "OpenAllMail",
}

-- §8.99 四张信纸（写信 / 读信页背景）：挂在两个 ScrollFrame 的 Layers 上
-- （MailFrame.xml:525/531/989/995）。Strip 不递归子帧、deep 只认 Button、滚动框补扫
-- 只换滚动条 —— 三条路径都够不着；暴雪还在运行期 SetTexture 重设
-- （MailFrame.lua:784-785 读信 / 1396-1397 写信）。照专业窗先例：点名 + 轮询纠回。
local STATIONERY_BG = {
    "SendStationeryBackgroundLeft", "SendStationeryBackgroundRight",
    "OpenStationeryBackgroundLeft", "OpenStationeryBackgroundRight",
}

local stationeryTex   -- 邮箱出生后解析一次（Need 走账本，不每秒重复记）

--- 模块级稳定引用：PollWatch 按引用去重，在 Apply 里现造闭包会每开一次窗多挂一条。
local function FadeStationery()
    if not stationeryTex then
        -- 轮询回调跑在 Apply 之外，作用域自己带（System.lua 的同型注释），账别落到 "_"。
        Skin.With("mail", function()
            stationeryTex = {}
            for _, nm in ipairs(STATIONERY_BG) do
                local t = Skin:Need(nm)
                stationeryTex[#stationeryTex + 1] =
                    (t and type(t.SetAlpha) == "function") and t or false
            end
        end)
    end
    for i = 1, #stationeryTex do
        local t = stationeryTex[i]
        if t then
            local okA, a = pcall(t.GetAlpha, t)
            if not okA or a ~= 0 then pcall(t.SetAlpha, t, 0) end
        end
    end
end

local function SkinMail()
    M:Dress(MAIL_FRAMES, {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = MAIL_BUTTONS,
    })
    -- 邮箱是 LoD：头几拍 Apply 时 MailFrame 还是 nil（Need 记"还没出生"的 miss），
    -- Blizzard_MailFrame 加载后下一轮 ApplyAll 接住，纠回轮询那时才挂上
    -- （PollWatch 自带可见性门槛，窗口关着不跑，零成本）。
    local mf = Skin:Need("MailFrame")
    if mf then Widget:PollWatch(mf, FadeStationery, 1) end
end

-- **11-05 实机（商人开过）**：`MerchantRepairButton` / `MerchantSellButton` /
-- `MerchantBuyBackButton` 与 `MerchantFrameScrollFrame` 都没有实名（修理/卖出/回购挂在
-- `MerchantFrame` 的 `parentKey` 下，商品列表是 `ScrollBox`）⇒ 摘点名，窗口侧 `deep` 接住。
-- **1.60 实名（11-05 由子帧探针扫出来的，不是照参考件写的）**：
--   `MerchantRepairItemButton`（修单件）/ `MerchantRepairAllButton`（修全部）/
--   `MerchantGuildBankRepairButton`（公会银行修理，随商人类型隐藏）/ `MerchantSellAllJunkButton`（卖灰货）
--   + 翻页 `MerchantPrevPageButton` / `MerchantNextPageButton`（只有超过 12 件才显示）。
-- ⚠ 订正我自己的一个流程漏洞：上一批我把 `MerchantRepairButton` / `MerchantSellButton` /
--   `MerchantBuyBackButton` 判成"实名不存在"就**摘掉了事**，没有去扫真名 —— 而作者换了个带修理的商人后
--   现场确认：那三个字符串确实不存在，但修理/卖出按钮**是存在的，只是叫别的名字**。
--   ⇒ 规矩：**"某名字不存在"只有配上"真名是什么"才算结论**，否则就是把覆盖删掉了还自称有依据。
local MERCHANT_BUTTONS = {
    "MerchantNextPageButton", "MerchantPrevPageButton",
    "MerchantRepairItemButton", "MerchantRepairAllButton",
    "MerchantGuildBankRepairButton", "MerchantSellAllJunkButton",
}

--- 商品格 / 回购格套上我们的格子边框，并压掉回购格那张 20×20 的暴雪小叠加图。
--- **必须是模块级函数**：`M:HookShow` 按引用去重，在 Apply 里现造闭包会每开一次窗多挂一条。
--- 也要挂在 Show 上：这些格子是首次显示才创建的（11-05 实测登录 Apply 时它们还不存在）。
--- 不开 `withInfo`：商人格不是装备格，等级数字会挤进 37px 的格子。
--- 工具钮图标的裁切档（11-05 作者选 A）：`SpellIcon-256x256-*` 把锤子和它的深色圆角底板画在同一张图里，
--- 外圈还有留白 ⇒ 在 36px 的格子里显得比商品格（37px + 裁 8%）小一号。
--- 裁掉外圈 8% 后图标填满格子、视觉重量与格子一致。**残留**：底板颜色是图的一部分，切不掉
--- （要连底板一起换掉得自绘模具，那是 #43 之后的材质工作）。
local TOOL_ICON_CROP = 0.08

--- 暴雪会在开窗/换商人时重设贴图 ⇒ 裁切必须每次开窗重做一次，不能只裁一遍（肖像那条同一纪律）。
local function CropToolIcon(btn)
    local okR, regions = pcall(function() return { btn:GetRegions() } end)
    if not okR then return end
    for _, reg in ipairs(regions) do
        local okA, atlas = pcall(reg.GetAtlas, reg)
        if okA and type(atlas) == "string" and string.lower(atlas):find("spellicon") then
            -- 内容图标豁免让它活了下来（不该被 Fade），这里只改它的取样范围
            pcall(reg.SetTexCoord, reg, TOOL_ICON_CROP, 1 - TOOL_ICON_CROP, TOOL_ICON_CROP, 1 - TOOL_ICON_CROP)
        end
    end
end

local function DressMerchantSlots()
    for i = 1, 12 do
        local slot = Skin:Need(("MerchantItem%dItemButton"):format(i))
        if slot then Skin:ItemQualityBorder(slot) end
    end
    -- **三颗工具钮也要有同一套格子边框（11-05 作者实测："三颗工具钮小一些，边框是暴雪材质"）**：
    -- 量出来暴雪的按钮框我们确实压掉了（`r1 BACKGROUND 64x64 a=0.00 我们压过`），
    -- 但 `SpellIcon-256x256-Repair/SellJunk` 这张图标**自带一块深色圆角底板**（`r2 BORDER 36x36 a=1.00`），
    -- 而我们的 `controlBg` 是 `SetAllPoints` 画在**同一尺寸的内侧** ⇒ 被图标美术整个盖住，
    -- 看到的"边框"其实是暴雪美术，且比格子小一号显得缩进去。
    -- ⇒ 复用商品格那条路：给它们套**外扩 1px 的边框**（画在图标之外，盖不住），
    --   与 37×37 的格子读起来同一权重；不改按钮尺寸（动暴雪控件的 Size 会牵动它自己的行布局）。
    for _, name in ipairs({ "MerchantRepairItemButton", "MerchantRepairAllButton",
                            "MerchantSellAllJunkButton", "MerchantGuildBankRepairButton" }) do
        local tool = Skin:Need(name)
        if tool then
            Skin:ItemQualityBorder(tool)
            CropToolIcon(tool)
        end
    end
    local bbSlot = Skin:Need("MerchantBuyBackItemItemButton")
    if not bbSlot then return end
    Skin:ItemQualityBorder(bbSlot)
    local icon = bbSlot.icon or bbSlot.Icon
    local okKids, kids = pcall(function() return { bbSlot:GetChildren() } end)
    if not okKids then return end
    for _, child in ipairs(kids) do
        local okR, regions = pcall(function() return { child:GetRegions() } end)
        if okR then
            for _, reg in ipairs(regions) do
                local layer
                pcall(function() layer = reg:GetDrawLayer() end)
                local w, h
                pcall(function() w, h = reg:GetWidth(), reg:GetHeight() end)
                -- 只认"小尺寸 + ARTWORK + 不是物品图标本体"这一类叠加图，其余一律不动
                if reg ~= icon and layer == "ARTWORK" and type(w) == "number" and type(h) == "number"
                    and w > 0 and w <= 24 and h > 0 and h <= 24 then
                    Skin:Fade(reg)
                end
            end
        end
    end
end

local function SkinMerchant()
    M:Dress("MerchantFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        buttons = MERCHANT_BUTTONS,
        -- 底板边框提到显眼档（11-05 作者："维修那三个按钮没有我们的方框边框吧?"）：
        -- 实测底板是有的（36x36、两点锚定、边框色 α0.80），但 1px + `edge` 档的半透明边框
        -- 在 36px 的小控件上读不出来 ⇒ 换成 `bright` 档 + α1（`opts.control` 必须在**第一次**
        -- ControlBg 时给：底板有缓存，第二次传参不会重做，这是 Skin:ControlBg 的既有行为）。
        control = { thickness = 1, bgAlpha = 0.9, borderAlpha = 1, borderKey = "bright" },
        deep = true,
        -- 11-05 实机（商人窗开着扫）：`rtportrait1 ×1` 还在"看得见"里 ⇒ 这扇窗的肖像没点名。
        portrait = true,
        -- 12 格商品 + 回购格的铺平裁切走引擎默认档（翻页后 CropIcon 轮询账本重压 texcoord）。
    })
    -- 翻页按钮换成细线左右箭头（monet_arrow_up + Widget:Arrow 转向）。
    Skin:PageArrow(Skin:Need("MerchantPrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("MerchantNextPageButton"), "right")

    -- 底部两条货币小框（MoneyInset / ExtraCurrencyInset）：同一套凹槽语言收掉原生浅底。
    -- 背板走 host 挂窗口本体（2026-11-02 渲染判例：中间容器名下 level 0 子框不渲染）；
    -- Strip 只压小框名下的那 1 条原生底框 texture，钱数内容在 child（MoneyFrame）里不受影响。
    -- 原生金框的 8 件 9-slice（UI-Frame-Inner* atlas）挂在 child 名下，不剥会整圈盖在
    -- 我们的背板之上（2026-11-02 实机判例：Strip 只剥本层，child 要点名）。
    local root = Skin:Need("MerchantFrame")
    for _, key in ipairs({ "MerchantMoneyInset", "MerchantExtraCurrencyInset" }) do
        local box = Skin:Need(key)
        if box and root then
            Skin:Strip(box)
            if type(box.GetNumChildren) == "function" then
                local cs = { box:GetChildren() }
                for i = 1, #cs do
                    Skin:Strip(cs[i])
                end
            end
            Skin:Panel(box, { bgSurface = "lost", bgAlpha = 0.96, thickness = 1, borderAlpha = 0, host = root })
        end
    end
    -- 金框的另一层真身（2026-11-02 实机判例）：MoneyInset / ExtraCurrencyInset 之外，
    -- 暴雪还有一对独立的具名背景框 MerchantMoneyBg / MerchantExtraCurrencyBg（159x19，
    -- MoneyBgMiddle 等原生金棕美术）叠在同一位置 —— 不叫 Inset、无 NineSlice、不在任何
    -- 既有清单里。钱数文字（MerchantMoneyFrame）是独立框叠在其上，Strip 不伤内容。
    for _, key in ipairs({ "MerchantMoneyBg", "MerchantExtraCurrencyBg" }) do
        local bg = Skin:Need(key)
        if bg then
            Skin:Strip(bg)
        end
    end

    -- 回购格（11-05 实名扫描出来的）：容器是 `MerchantBuyBackItem`，里面装着
    -- `MerchantBuyBackItemItemButton`（物品格）与 `MerchantBuyBackItemMoneyFrame`。
    -- **只剥容器自己的原生底、不碰子件** —— 上一批 MoneyInset 那圈剥子件是安全的（子件是钱框），
    -- 这里的子件是物品按钮，Strip 下去会把物品图标一起压掉（AGENTS「必需件先注册、装饰件各自 pcall」）。
    local buyback = Skin:Need("MerchantBuyBackItem")
    if buyback and root then
        Skin:Strip(buyback)
        Skin:Panel(buyback, { bgSurface = "lost", bgAlpha = 0.96, thickness = 1, borderAlpha = 0, host = root })
    end

    -- **格子边框 + 回购格小图（11-05 作者报"回购物品的按钮比修理/全修/出售大"）**：
    -- 量出来不是尺寸问题（回购格 37×37、三颗按钮 36×36，`GetEffectiveScale` 都是 0.6400
    -- ⇒ 屏幕 23.7 vs 23.0 px，差 3%）。真因是**格子没有参照边界**：我们的边框没套上，
    -- 而暴雪的槽框又被剥成 α0 ⇒ 铺满整格的物品图标读起来就比"带内边距的符号图形"大一号。
    -- 抽成 `DressMerchantSlots()` 是因为商人格**首次显示才创建**（11-05 实测：登录 Apply 时
    -- `Skin:Need("MerchantItem1ItemButton")` 拿不到 ⇒ 循环空跑，既不报错也没边框），
    -- 所以除了 Apply 这一次，还要挂 `M:HookShow(MerchantFrame)` 在每次开窗时补。
    DressMerchantSlots()

    -- 每格的文字衬底（2026-11-02 实机判例）：MerchantItem<N> 格自带两块**圆角**美术
    -- （fileID 130766 / 136423，α1.00 原样），四角不是方形，与凹槽语言不统一。
    -- Strip 后给整格挂方形 lost 底；host=root——2026-11-02 渲染判例，中间容器名下
    -- level 0 的背板不渲染，必须挂窗口本体。回购格同模板，一并处理。
    -- borderAlpha=0：行格是控件底语义（12 行格都描边会太吵），与金钱两框同档。
    for i = 1, 12 do
        local tile = Skin:Need("MerchantItem" .. i)
        if tile and root then
            Skin:Strip(tile)
            Skin:Panel(tile, { bgSurface = "lost", bgAlpha = 0.96, thickness = 1, borderAlpha = 0, host = root })
        end
    end
    local buyback = Skin:Need("MerchantBuyBackItem")
    if buyback and root then
        Skin:Strip(buyback)
        Skin:Panel(buyback, { bgSurface = "lost", bgAlpha = 0.96, thickness = 1, borderAlpha = 0, host = root })
    end

    -- 商品格是**首次显示才创建**的（11-05 实测：登录 Apply 时 `MerchantItem1ItemButton` 还不存在，
    -- 边框那趟循环空跑）⇒ 每次开窗补一次。`DressMerchantSlots` 是模块级函数 = 稳定引用，
    -- `M:HookShow` 自带幂等；在 Apply 里现造闭包会每开一次窗多挂一条（AGENTS 明文）。
    M:HookShow(root, DressMerchantSlots)
end

local function SkinTrainer()
    M:Dress({ "ClassTrainerFrame", "TrainerFrame" }, {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        -- 11-05 作者实测：训练师左上角那颗圆头像没处理。肖像实名是全局
        -- `ClassTrainerFramePortrait`（`ClassTrainerFrame` 没有 `.Portrait` 成员，SquarePortrait
        -- 靠 `<名>Portrait` 回退命中）⇒ 和其余窗口同一口径直接隐藏。
        portrait = true,
        buttons = { "ClassTrainerTrainButton", "ClassTrainerCancelButton" },
    })
end

-- 拍卖行整块移除（2026-11-11 转储定案，§8.100 P0-2）：`AuctionFrame` / `AuctionFrameTab1..3` /
-- `AuctionFrameBrowse|Auctions|Bid` / `Browse*Button` / `Browse*EditBox` 在 1.60
-- （framexml-source 1.60.1.70707）**全部零命中** —— 1.60 的拍卖行是 `AuctionHouseFrame`
-- （`Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseFrame.xml:4`，PortraitFrameTemplate）
-- 加一套 AuctionHouse* 模板实例，老名单一颗都接不上，这个面板从登录起就是静默空转。
-- 整组摘掉（照 §8.40 "名字全不存在 ⇒ 整组删" 的口径），配置面板的「拍卖行」勾选项随
-- M:Panel 注册消失。按新系统重做换皮 = 新功能，要实机开着拍卖行调研模板实例的真名，
-- 留给下一轮，不在缺口清理范围。

-- **专业窗的暴雪装饰件（11-05 作者选 B：剥水印 + 选中条换我们的颜色）**。
-- layers 实测这些 atlas 挂在 ScrollBox 回收行的匿名子帧上，deep 够不到：
local FADE_PROF_ATLAS = {
    -- 纯面板底图 / 水印 → 压没，露出我们的深色背板
    -- ⚠ 11-05 实机订正：这些 atlas 有**单数 `Profession-`** 和**复数 `Professions-`** 两种前缀，
    --   只写复数会漏掉详情面板的职业插画水印（`Profession-background-card-Cooking`）与 Template2 底图。
    "profession%-background%-card%-",
    "profession%-background%-template",
    -- 11-14 实机补：总览页的职业卡片底图**真名里没有 background 段** ——
    -- 是 `Profession-overview-Card` / `Profession-overview-card-generic-*`，
    -- 原来那条 `profession-background-card-*` 一张都没命中，于是卡片还是暴雪的棕底插画。
    "profession%-overview%-card",
    -- 11-14 实机补（配方页）：右详情面板的边框 `common-insideframe`，
    -- 以及两块内容区里的 9-slice 内框（`UI-Frame-Inner*`）与金属边（`UI-Frame-Metal*`）。
    -- 这些原名单里一条都没有 ⇒ 两块内容区还挂着暴雪的框，凹槽补不齐。
    "common%-insideframe",
    "ui%-frame%-",
    "gamepad%-uiframemetal",
    -- 11-14 实机补（真名与名单对不上的又两处）：
    -- 总览页大卡片底图 `Profession-Background-Overview`（我们认的是 `-overview-card`）；
    -- 空槽底 `Professions-Slot-bg`（我们认的是 `-slot-frame`）；
    -- 装备分隔线 `Professions-Equipment-Divider`；配方行的减号钮 `common-button-list-minus`。
    "profession%-background%-overview",
    "professions%-slot%-bg",
    "professions%-equipment%-divider",
    "common%-button%-list%-minus",
    "professions%-background%-summarylist",
    "professions%-qualitywindow%-background",
    "professions%-qualitypane%-bg",
    "professions%-minimizedview%-qualitypane%-bg",
    "professions%-recrafting%-panel",
    "professions%-qualitybar%-frame",
    -- 分类头的金色条（所有分类都显示，是装饰不是选中态 → 剥掉，留文字）
    "common%-button%-list%-collapseexpand",
    -- 左侧职业分类页签的底/悬停/遮罩（选中态在 SWAP 里换色，不剥）
    "common%-sidetab$",
    "common%-sidetab%-hover",
    "common%-sidetab%-mask",
    -- 右侧详情面板：材料槽框 / 结果槽框 / 重制槽框 / 分隔线（纯装饰，槽里的图标是数字 ID 不受影响）
    "professions%-slot%-frame",
    "professions%-choicereagent%-frame",
    "professions%-recrafting%-frame%-item",
    "professions%-qualitypane%-divider",
    -- 配方行背景（common-button-list 本体）→ 剥掉，行变透明坐在我们的深色上。
    "common%-button%-list$",
    -- 行底的 `HighlightOverlay`（`Professions_Recipe_Hover`，**每行常亮**、α0.5）——
    -- 它不是选中信号（选中信号是 `SelectedOverlay` 的显示/隐藏）⇒ 褪掉，行就平了。
    -- 真名用下划线分隔 ⇒ 两种分隔都认（`[-_]?`）。
    "professions[-_]?recipe[-_]?hover",
}
-- ⚠ 配方行的选中/悬停条（`Professions_Recipe_Active` / `_Hover`，真名用**下划线**分隔）
-- **故意不进褪色名单**：那两张贴图是暴雪用 alpha 当开关的（选中行 α1、其余 α0），
-- 褪掉就没有选中信号了（作者实测"看不出选中行"）；而直接换成我们的实心盒子又会因为
-- `SwapArt` 默认把 alpha 复位到 1，把 13 行全点亮（"行条都混成一片了"）。
-- ⇒ 单独一趟：**换图 + 保留 alpha**（见 `DressRecipeRows` 与 `Skin:SwapArt` 的 `keepAlpha`）。
local SWAP_PROF_ATLAS = {
    -- 侧页签选中态 → 换成我们的矩形 barfill（通用方法把盒子压到内容之下，不糊图标）
    "common%-sidetab%-selected",
}
local TINT_PROF_ATLAS = {
}

--- 专业窗的三块**内容区凹槽**（11-14 作者口径："专业面板的凹槽没做全"）。
---
--- 三处内容区都**点不到名字**（专业窗是 LoD 包，卡片 / 列表 / 详情都是运行期建的匿名子帧），
--- 只能按**图集**认脸：
---   ① 总览页的职业卡片 —— `Profession-overview-Card` / `Profession-overview-card-generic-*`；
---   ② 配方页左边的配方列表 —— `Professions-background-summarylist`（304×517）；
---   ③ 配方页右边的详情面板 —— `Profession-background-card-*`（同层还挂着 `common-insideframe`）。
--- 认出来之后：暴雪的底图交给 `FADE_PROF_ATLAS` 褪掉，我们给每块铺一档**凹槽**
--- （lost 底 + 1px 边，`Skin:Panel` 的板画在宿主**之下**，不吃点击；幂等，不会越挂越多）。
local PROF_WELL_ATLAS = {
    "^profession%-overview%-card",
    "professions%-background%-summarylist",
    "profession%-background%-card",
}
local function DressProfessionsWells()
    local f = Skin:Need("ProfessionsFrame")
    if not f then return end
    -- 公共遍历（`Skin:WalkFrames`）：认出"这是一整块内容区"就 `stop`，不再往里钻。
    Skin:WalkFrames(f, { depth = 4 }, function(frame, atlases)
        if not Skin:AtlasMatch(atlases, PROF_WELL_ATLAS) then return end
        pcall(Skin.Panel, Skin, frame, {
            bgSurface = "lost", bgAlpha = 0.96, borderAlpha = 1, thickness = 1,
        })
        return "stop"
    end)
end

--- 配方行的**选中态**（11-14 作者口径四轮："行条都混成一片了" → "看不出选中行"
--- → "把选中行改成斜纹" → "样子不对"）。
---
--- **暴雪的机制**（自己的 XML：`Blizzard_ProfessionsRecipeList.xml`）：
---   <Texture parentKey="SelectedOverlay"  atlas="Professions_Recipe_Active" hidden="true">
---   <Texture parentKey="HighlightOverlay" atlas="Professions_Recipe_Hover"   alpha="0.5">
--- ⇒ **选中开关是「显示/隐藏」**（`SelectedOverlay` 默认藏起来，选中才 Show），
---   **不是 alpha**。前几轮按 alpha 玩必然全错：
---   · 褪掉它 ⇒ 选中信号没了（"看不出选中行"）；
---   · 换成实心盒子 ⇒ `SwapArt` 把 alpha 复位到 1，13 行全点亮（"行条都混成一片了"）；
---   · 按 alpha 给它染色 ⇒ 本客户端 `SetVertexColor(r,g,b,a)` 与 `GetAlpha()` **共享同一份存储**
---     （AGENTS 记过），一染色就把暴雪的 alpha 覆盖掉（"样子不对"）。
--- ⇒ 正确做法：认 `SelectedOverlay` **字段**（parentKey，不是按图集猜），
---   换我们的**斜纹**材质（`monet_stripe_weave`，45°、带半像素过渡），
---   **不碰它的 alpha、也不碰它的显示/隐藏** —— 暴雪说"这行被选中"时它自己 Show。
---   平铺口径与 `Widget:BarWeave` 一致（`REPEAT` + 按 `Media:Mult()` 算重复数 ⇒ 45° 不歪）。
---   画在 `BACKGROUND/-6`（文字之下）；顶点色**只给 r/g/b**（带 a 会覆盖 alpha）。
---
--- 行底的 `HighlightOverlay`（每行常亮、α0.5）不是选中信号 ⇒ 交给 `FADE_PROF_ATLAS` 褪掉，
--- 行就平了（坐在我们的深色底板上），只有选中的那一行带斜纹。
local PROF_WEAVE_SIZE = 64      -- 与 Widget.lua 的 WEAVE_SIZE 同值（贴图 64×64）
local function DressRecipeRows()
    local f = Skin:Need("ProfessionsFrame")
    if not f then return end
    local Media = ns.Media
    local function weave(tex)
        if not tex then return end
        local swapped = Skin:SwapArt(tex, "monet_stripe_weave", { keepAlpha = true })
        if not swapped then return end
        -- SwapArt 换完给的是 0..1 贴图坐标；斜纹要**平铺**，所以按 `Widget:BarWeave` 的
        -- 口径重算：REPEAT + 重复数 = 宽 /(mult × 64)，纵向从 1/64 起、连续不取整
        -- （取整会让横纵采样密度不同，斜纹就歪了）。
        pcall(swapped.SetTexture, swapped, Media:Texture("monet_stripe_weave"), "REPEAT", "REPEAT")
        local mult = Media:Mult()
        local width = tex:GetWidth() or 1
        local height = tex:GetHeight() or 2
        local cols = math.max(0, width / (mult * PROF_WEAVE_SIZE))
        local v0 = 1 / PROF_WEAVE_SIZE
        local v1 = v0 + height / (mult * PROF_WEAVE_SIZE)
        pcall(swapped.SetTexCoord, swapped, 0, cols, v0, v1)
        -- 顶点色**只给 r/g/b**：带 a 会写进与 `GetAlpha()` 共享的那份存储，
        -- 把暴雪的 alpha 覆盖掉（选中 = 显示/隐藏的机制就废了）。
        local wr, wg, wb = Color:GetSurface("weave")
        if wr then pcall(swapped.SetVertexColor, swapped, wr, wg, wb) end
        pcall(swapped.SetDrawLayer, swapped, "BACKGROUND", -6)
    end
    -- 公共遍历（`Skin:WalkFrames`）：认 parentKey 字段（暴雪的 XML 里就叫 SelectedOverlay），
    -- 不按图集猜；认出就换斜纹，不必再往下钻。
    Skin:WalkFrames(f, { depth = 6 }, function(k)
        local sel = select(2, pcall(function() return k.SelectedOverlay end))
        if type(sel) ~= "table" then return end
        weave(sel)
        return "stop"
    end)
end

-- 模块级稳定引用：PollWatch 按引用去重，在 Apply 里现造闭包会每开一次窗多挂一条。
-- 走通用 Skin:StyleAtlasBackdrop（swap 实心行条 + tint 选中框），角色窗共用同一条。
-- **两趟分开、换在前褪在后**（同 §8.114.3）：swap 档会把 alpha 复位到 1，
-- 褪色档走「每趟写 α0」通道（`FadeAtlasBackdrop(..., alpha=0)`）——
-- 暴雪换页 / 换职业会把装饰贴图的 alpha 抬回来，只压一次的话凹槽一会儿就"压过又回来"。
local function StyleProfessionsArt()
    local f = Skin:Need("ProfessionsFrame")
    if f then
        Skin:StyleAtlasBackdrop(f, {}, SWAP_PROF_ATLAS, TINT_PROF_ATLAS)
        Skin:FadeAtlasBackdrop(f, FADE_PROF_ATLAS, nil, 0)
    end
    DressProfessionsWells()
    DressRecipeRows()
end

local function SkinProfessions()
    -- **11-05 实机（专业窗开过）**：`TradeSkillFrame` 与三个页签名（`ProfessionsFrameTab1/2`、
    -- `TradeSkillFrameTab1`）都没有实名 —— 1.60 的页签是 `ProfessionsFrame` 内 `TabSystemTemplate`
    -- 的运行期子件 ⇒ 只点窗口本体，页签与内容靠 `deep` 扫（§8.40 ②）。
    -- 11-05 作者要"把专业美化做掉"，layers 实测还剩 242 件看得见美术：肖像没藏 +
    -- 侧页签 `common-sidetab` / 配方行 `common-button-list` / `professions_recipe_hover` 都挂在
    -- 嵌套子帧上（默认 deep 只扫直接子件够不到）。补 portrait，并把行扫描深度开到 4
    -- （和社交窗同一手法：那些是按钮，够到了就走我们的按钮档）。
    -- 11-05 作者实测"背板尺寸不到边"（A 方案）：去掉 `inset` —— 专业窗自带复杂多面板布局，
    -- 我们再叠一层内缩凹槽反而和它打架、把"不到边"放大。只留 frame 背板铺满 + deep + portrait。
    M:Dress("ProfessionsFrame", {
        window = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        deepRows = 4,
        portrait = true,
    })
    -- 面板底图 / 水印剥掉 + 金色选中条换我们的颜色（配方行是 ScrollBox 回收的，挂可见期轮询补扫）。
    StyleProfessionsArt()
    local pf = Skin:Need("ProfessionsFrame")
    if pf then Widget:PollWatch(pf, StyleProfessionsArt, 2) end
end

local function SkinBank()
    -- 11-14 实机核对：`WarbandBankFrame` 在本客户端**不存在**（1.60 没有战团银行）⇒ 摘掉；
    -- 银行还是 `BankFrame` 那一扇。
    M:Dress("BankFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 },
        -- 现代框架的包裹格挂在 BankPanel（PanelTemplate）名下 —— 同一套凹槽语言收它
        -- （Strip 含 NineSlice）。实机核对后再定去留。
        wells = { BankPanel = true },
    })
end

M:Panel("trade", { label = "交易", group = "交易", apply = SkinTrade,
    frames = {
        "TradeFrame", "TradeFrameCloseButton",
        TRADE_BUTTONS, TRADE_MONEY_FRAMES, TRADE_MONEY_BUTTONS,
    } })

M:Panel("mail", { label = "邮箱", group = "交易", apply = SkinMail,
    frames = { MAIL_FRAMES, MAIL_BUTTONS, STATIONERY_BG } })

M:Panel("merchant", { label = "商贩", group = "交易", apply = SkinMerchant,
    frames = { "MerchantFrame", MERCHANT_BUTTONS, "MerchantBuyBackItem" } })

-- **格子边框必须走事件，不能只靠 Apply / HookShow**（11-05 两次实测）：
-- 商人 UI 是 LoD —— 登录 Apply 时 `MerchantFrame` 还不存在，所以 `root` 是 nil，
-- `M:HookShow(nil, …)` 静默什么也不做，格子边框一直没加上（开窗后量：子件仍是 1、那个是暴雪槽框）。
-- `MERCHANT_SHOW` 派发时窗口已经建好，格子也在里面 ⇒ 在这里补一次，`M:OnEvent` 自带 pcall 与开关判断。
M:OnEvent("MERCHANT_SHOW", DressMerchantSlots)

M:Panel("trainer", { label = "训练师", group = "交易", apply = SkinTrainer,
    frames = {
        "ClassTrainerFrame", "TrainerFrame",
        "ClassTrainerTrainButton", "ClassTrainerCancelButton",
    } })

-- 拍卖行面板已随死名整组移除（见上文注；1.60 真身 AuctionHouseFrame，重做留待下一轮）。

M:Panel("professions", { label = "专业 / 制造", group = "交易", apply = SkinProfessions,
    frames = { "ProfessionsFrame" } })

M:Panel("bank", { label = "银行", group = "交易", apply = SkinBank,
    frames = { "BankFrame" } })

-- 宝石镶嵌：无 game-type 门控（wow-ui-source forever 分支），本客户端存在。
-- 宝石格子是带图标的槽位，SkinButtonsIn 会自动跳过。
local function SkinSocketing()
    M:Dress("ItemSocketingFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        buttons = { "ItemSocketingSocketButton" },
    })
end

M:Panel("socket", { label = "宝石镶嵌", group = "交易", apply = SkinSocketing,
    addons = { Blizzard_ItemSocketingUI = true },
    frames = {
        "ItemSocketingFrame", "ItemSocketingFrameCloseButton",
        "ItemSocketingSocketButton",
    } })

-- 制造订单：Blizzard_ProfessionsCustomerOrders 无 game-type 门控。
local function SkinCraftOrders()
    M:Dress("ProfessionsCustomerOrdersFrame",
        { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })
end

M:Panel("craftorders", { label = "制造订单", group = "交易", apply = SkinCraftOrders,
    addons = { Blizzard_ProfessionsCustomerOrders = true },
    frames = {
        "ProfessionsCustomerOrdersFrame", "ProfessionsCustomerOrdersFrameCloseButton",
    } })
