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

local function SkinMail()
    M:Dress(MAIL_FRAMES, {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = MAIL_BUTTONS,
    })
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
            Skin:Panel(box, { bgSurface = "lost", bgAlpha = 0.965, thickness = 1, borderAlpha = 0, host = root })
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
        Skin:Panel(buyback, { bgSurface = "lost", bgAlpha = 0.965, thickness = 1, borderAlpha = 0, host = root })
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
            Skin:Panel(tile, { bgSurface = "lost", bgAlpha = 0.965, thickness = 1, borderAlpha = 0, host = root })
        end
    end
    local buyback = Skin:Need("MerchantBuyBackItem")
    if buyback and root then
        Skin:Strip(buyback)
        Skin:Panel(buyback, { bgSurface = "lost", bgAlpha = 0.965, thickness = 1, borderAlpha = 0, host = root })
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

local AUCTION_TABS = { "AuctionFrameTab1", "AuctionFrameTab2", "AuctionFrameTab3" }

local AUCTION_PANELS = { "AuctionFrameBrowse", "AuctionFrameAuctions", "AuctionFrameBid" }

local AUCTION_BUTTONS = {
    "BrowseSearchButton", "BrowseResetButton", "BrowseBuyoutButton",
    "AuctionsCreateAuctionButton", "AuctionsCancelAuctionButton", "BidBidButton",
}

local AUCTION_EDITS = { "BrowseName", "BrowseMinLevel", "BrowseMaxLevel", "BrowsePrice" }

local function SkinAuction()
    M:Dress("AuctionFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, tabs = AUCTION_TABS })
    M:Dress(AUCTION_PANELS, { panel = { bgAlpha = 0.96 }, deep = true })
    M:Dress(AUCTION_BUTTONS, { as = "button" })
    -- BrowseMinLevel 一类在别的构建里是 Slider：editbox 档会先认类型，认错就跳过。
    M:Dress(AUCTION_EDITS, { as = "editbox" })
end

-- **专业窗的暴雪装饰件（11-05 作者选 B：剥水印 + 选中条换我们的颜色）**。
-- layers 实测这些 atlas 挂在 ScrollBox 回收行的匿名子帧上，deep 够不到：
local FADE_PROF_ATLAS = {
    -- 纯面板底图 / 水印 → 压没，露出我们的深色背板
    -- ⚠ 11-05 实机订正：这些 atlas 有**单数 `Profession-`** 和**复数 `Professions-`** 两种前缀，
    --   只写复数会漏掉详情面板的职业插画水印（`Profession-background-card-Cooking`）与 Template2 底图。
    "profession%-background%-card%-",
    "profession%-background%-template",
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
    -- 配方行背景（common-button-list 本体）→ 剥掉，行变透明坐在我们的深色上；
    -- 选中行仍由 SWAP 的 recipe-active 给高亮，不会没有选中反馈。
    "common%-button%-list$",
}
local SWAP_PROF_ATLAS = {
    -- 金色选中态 → 换成我们的 barfill + 边框色（压没会丢选中反馈，所以是换不是剥）
    "professions%-recipe%-active",
    "common%-sidetab%-selected",
    "professions%-recipe%-hover",
}

-- 模块级稳定引用：PollWatch 按引用去重，在 Apply 里现造闭包会每开一次窗多挂一条。
-- 走通用 Skin:StyleAtlasBackdrop（fade 装饰底图 + swap 选中态换我们的颜色），角色窗共用同一条。
local function StyleProfessionsArt()
    local f = Skin:Need("ProfessionsFrame")
    if f then Skin:StyleAtlasBackdrop(f, FADE_PROF_ATLAS, SWAP_PROF_ATLAS) end
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
    M:Dress({ "BankFrame", "WarbandBankFrame" }, {
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
    frames = { MAIL_FRAMES, MAIL_BUTTONS } })

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

M:Panel("auction", { label = "拍卖行", group = "交易", apply = SkinAuction,
    frames = { "AuctionFrame", AUCTION_TABS, AUCTION_PANELS, AUCTION_BUTTONS, AUCTION_EDITS } })

M:Panel("professions", { label = "专业 / 制造", group = "交易", apply = SkinProfessions,
    frames = { "ProfessionsFrame" } })

M:Panel("bank", { label = "银行", group = "交易", apply = SkinBank,
    frames = { "BankFrame", "WarbandBankFrame" } })

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
