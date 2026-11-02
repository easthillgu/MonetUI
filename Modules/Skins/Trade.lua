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

local function SkinTrade()
    M:Dress("TradeFrame", {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = TRADE_BUTTONS,
    })
    -- 金额输入框：以前把 `panel` 塞进 Skin:Panel 的参数里（它读的是 opts.bgAlpha），
    -- 底衬一直是默认的 0.85 而不是 0.96；走 Dress 之后参数只有一层，不会再套错。
    M:Dress(TRADE_MONEY_FRAMES, { panel = { bgAlpha = 0.96 }, deep = true })
end

local MAIL_FRAMES = { "MailFrame", "InboxFrame", "SendMailFrame", "OpenMailFrame" }

local MAIL_BUTTONS = {
    "InboxFrameOpenButton", "InboxFrameReplyButton", "InboxFrameDeleteButton",
    "InboxPrevPageButton", "InboxNextPageButton",
    "SendMailMailButton", "SendMailCancelButton",
    -- 70450 起邮件收取走 C_SecureTransfer（TakeMailMoney + MAIL_OPEN_ALL_CANCELED），
    -- 收件箱多了"一键收取"按钮 OpenAllMail（全局名，Ellesmere 同客户端实机名单佐证）。
    "OpenAllMail",
}

local function SkinMail()
    M:Dress(MAIL_FRAMES, {
        window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, buttons = MAIL_BUTTONS,
    })
    -- 收件箱列表的滚动区在两种布局里挂在不同对象上：全局名，或 MailFrame 的子窗成员。
    -- 以前传的是 `frame.InboxFrame`（一个 Window，没有 ScrollBar），Skin:ScrollFrame 静默返回，
    -- 邮件列表的滚动条从来没被美化过。
    local scroll = Skin:Need("MailListScrollFrame")
        or Skin:Need("MailFrame.InboxFrame.MailListScrollFrame")
        or Skin:Need("InboxFrame.MailListScrollFrame")
    if scroll then Skin:ScrollFrame(scroll) end
    -- 翻页按钮换成细线左右箭头。
    Skin:PageArrow(Skin:Need("InboxPrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("InboxNextPageButton"), "right")
end

local MERCHANT_BUTTONS = {
    "MerchantNextPageButton", "MerchantPrevPageButton", "MerchantRepairButton",
    "MerchantRepairAllButton", "MerchantSellButton", "MerchantBuyBackButton",
}

local function SkinMerchant()
    M:Dress("MerchantFrame", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        buttons = MERCHANT_BUTTONS,
        scrolls = { "MerchantFrameScrollFrame" },
    })
    -- 翻页按钮换成细线左右箭头（monet_arrow_left/right）。
    Skin:PageArrow(Skin:Need("MerchantPrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("MerchantNextPageButton"), "right")

    -- 底部两条货币小框（MoneyInset / ExtraCurrencyInset）：同一套凹槽语言收掉原生浅底。
    -- 背板走 host 挂窗口本体（2026-11-02 渲染判例：中间容器名下 level 0 子框不渲染）；
    -- Strip 只压小框名下的那 1 条原生底框 texture，钱数内容在 child（MoneyFrame）里不受影响。
    local root = Skin:Need("MerchantFrame")
    for _, key in ipairs({ "MerchantMoneyInset", "MerchantExtraCurrencyInset" }) do
        local box = Skin:Need(key)
        if box and root then
            Skin:Strip(box)
            Skin:Panel(box, { bgSurface = "lost", bgAlpha = 0.965, thickness = 1, host = root })
        end
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
    M:Dress({ "ProfessionsFrame", "TradeSkillFrame" }, {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        tabs = { "ProfessionsFrameTab1", "ProfessionsFrameTab2", "TradeSkillFrameTab1" },
    })
end

local function SkinBank()
    M:Dress({ "BankFrame", "WarbandBankFrame" }, { window = true, inset = true, panel = { bgAlpha = 0.96 } })
end

M:Panel("trade", { label = "交易", group = "交易", apply = SkinTrade,
    frames = {
        "TradeFrame", "TradeFrameCloseButton",
        TRADE_BUTTONS, TRADE_MONEY_FRAMES, TRADE_MONEY_BUTTONS,
    } })

M:Panel("mail", { label = "邮箱", group = "交易", apply = SkinMail,
    frames = {
        MAIL_FRAMES, MAIL_BUTTONS,
        "MailListScrollFrame", "MailFrame.InboxFrame.MailListScrollFrame",
        "InboxFrame.MailListScrollFrame",
    } })

M:Panel("merchant", { label = "商贩", group = "交易", apply = SkinMerchant,
    frames = { "MerchantFrame", MERCHANT_BUTTONS, "MerchantFrameScrollFrame" } })

M:Panel("trainer", { label = "训练师", group = "交易", apply = SkinTrainer,
    frames = {
        "ClassTrainerFrame", "TrainerFrame",
        "ClassTrainerTrainButton", "ClassTrainerCancelButton",
    } })

M:Panel("auction", { label = "拍卖行", group = "交易", apply = SkinAuction,
    frames = { "AuctionFrame", AUCTION_TABS, AUCTION_PANELS, AUCTION_BUTTONS, AUCTION_EDITS } })

M:Panel("professions", { label = "专业 / 制造", group = "交易", apply = SkinProfessions,
    frames = {
        "ProfessionsFrame", "TradeSkillFrame",
        "ProfessionsFrameTab1", "ProfessionsFrameTab2", "TradeSkillFrameTab1",
    } })

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
