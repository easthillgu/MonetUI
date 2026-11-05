-- Modules/Skins/Trade.lua
-- Mail, merchant, trainer, auction house, professions, the bank and the trade window.  Item rows keep
-- their icons: only chrome buttons, tabs and scroll bars are restyled.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

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

local function SkinMerchant()
    M:Dress("MerchantFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        buttons = MERCHANT_BUTTONS,
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

    -- **格子边框（11-05 作者报"回购物品的按钮比修理/全修/出售大"）**：量出来根本不是尺寸问题
    -- （回购格 37×37、三颗按钮 36×36，`GetEffectiveScale` 都是 0.6400 ⇒ 屏幕 23.7 vs 23.0 px，差 3%）。
    -- 真因是**两种格子都没套我们的边框，而暴雪的槽框又被我们剥成 α0** ⇒ 铺满整格的物品图标
    -- 没有参照边界，读起来就比"带内边距的符号图形"大一号。
    -- ⇒ 补边框（复用背包/装备格那套 `Skin:ItemQualityBorder`，不开等级数字——商人格不是装备格），
    --   并压掉回购格上那张 20×20 的暴雪小叠加图（实测在它名下的子框里，ARTWORK 层，不是物品图标）。
    for i = 1, 12 do
        local slot = Skin:Need(("MerchantItem%dItemButton"):format(i))
        if slot then Skin:ItemQualityBorder(slot) end
    end
    local bbSlot = Skin:Need("MerchantBuyBackItemItemButton")
    if bbSlot then
        Skin:ItemQualityBorder(bbSlot)
        local icon = bbSlot.icon or bbSlot.Icon
        local okKids, kids = pcall(function() return { bbSlot:GetChildren() } end)
        if okKids then
            for _, child in ipairs(kids) do
                local okR, regions = pcall(function() return { child:GetRegions() } end)
                if okR then
                    for _, reg in ipairs(regions) do
                        local isIcon = (reg == icon)
                        local layer, sub
                        pcall(function() layer, sub = reg:GetDrawLayer() end)
                        local w, h
                        pcall(function() w, h = reg:GetWidth(), reg:GetHeight() end)
                        -- 只认"小尺寸 + ARTWORK + 不是物品图标"这一类叠加图；其余一律不动
                        if not isIcon and layer == "ARTWORK" and type(w) == "number" and type(h) == "number"
                            and w > 0 and w <= 24 and h > 0 and h <= 24 then
                            Skin:Fade(reg)
                        end
                    end
                end
            end
        end
    end

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
end

local function SkinTrainer()
    M:Dress({ "ClassTrainerFrame", "TrainerFrame" }, {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
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

local function SkinProfessions()
    -- **11-05 实机（专业窗开过）**：`TradeSkillFrame` 与三个页签名（`ProfessionsFrameTab1/2`、
    -- `TradeSkillFrameTab1`）都没有实名 —— 1.60 的页签是 `ProfessionsFrame` 内 `TabSystemTemplate`
    -- 的运行期子件 ⇒ 只点窗口本体，页签与内容靠 `deep` 扫（§8.40 ②）。
    M:Dress("ProfessionsFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
    })
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
