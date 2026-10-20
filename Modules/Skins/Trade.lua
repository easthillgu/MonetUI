-- Modules/Skins/Trade.lua
-- Mail, merchant, trainer, auction house, professions and the bank.  Item rows keep their icons: only chrome buttons, tabs and scroll bars are restyled.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- Modules/Skins/Trade.lua
-- Mail, merchant, trainer, auction house, professions, the bank and the trade window.  Item rows keep
-- their icons: only chrome buttons, tabs and scroll bars are restyled.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- The trade window plus the two money frames that pop up inside it.  Both are separate frames that
-- stay on screen while the trade is open, so they need their own treatment, not the main frame's.
local function SkinTrade()
    local frame = _G.TradeFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })

    M:Controls({ "TradePlayerInputMoneyFrame", "TradeRecipientInputMoneyFrame" }, function(money)
        if not money then return end
        Skin:Strip(money)
        Skin:Panel(money, { noTitle = true, panel = { bgAlpha = 0.96 } })
        M:Buttons({ "TradePlayerInputMoneyFrameOkayButton", "TradePlayerInputMoneyFrameCancelButton",
                    "TradeRecipientInputMoneyFrameOkayButton", "TradeRecipientInputMoneyFrameCancelButton" })
    end)

    -- AcceptAllTradesButton is the newer combined accept button; the rest are the classic pair plus the
    -- two "show items" toggles.  All optional -- M:Controls skips whatever this client does not have.
    M:Buttons({
        "AcceptTradeButton", "CancelTradeButton", "AcceptAllTradesButton",
        "TradeShowPlayerTargetItems", "TradeFrameToggleReciprocate", "TradeTargetToggleReciprocate",
    })

    M:SkinScrollsIn(frame)
end

local function SkinMail()
    M:Controls({ "MailFrame", "InboxFrame", "SendMailFrame", "OpenMailFrame" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        -- The scroll frame is reached through the inbox sub-window when the window is the mail frame
        -- itself.  Passing `frame.InboxFrame` straight to Skin:ScrollFrame handed it a Window where a
        -- ScrollFrame was expected: no ScrollBar member, so it returned silently and the mail list's
        -- scroll bar was never skinned at all.
        local scroll = frame.MailListScrollFrame
            or (frame.InboxFrame and frame.InboxFrame.MailListScrollFrame)
        Skin:ScrollFrame(scroll)
    end)
    M:Buttons({
        "InboxFrameOpenButton", "InboxFrameReplyButton", "InboxFrameDeleteButton",
        "InboxPrevPageButton", "InboxNextPageButton",
        "SendMailMailButton", "SendMailCancelButton",
    })
end

local function SkinMerchant()
    local frame = _G.MerchantFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })

    M:Buttons({
        "MerchantNextPageButton", "MerchantPrevPageButton", "MerchantRepairButton",
        "MerchantRepairAllButton", "MerchantSellButton", "MerchantBuyBackButton",
    })

    M:Scrolls({ "MerchantFrameScrollFrame" })
end

local function SkinTrainer()
    M:Controls({ "ClassTrainerFrame", "TrainerFrame" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        M:SkinButtonsIn(frame)
        M:SkinScrollsIn(frame)
    end)
    M:Buttons({ "ClassTrainerTrainButton", "ClassTrainerCancelButton" })
end

local function SkinAuction()
    local frame = _G.AuctionFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs({ "AuctionFrameTab1", "AuctionFrameTab2", "AuctionFrameTab3" })

    M:Controls({ "AuctionFrameBrowse", "AuctionFrameAuctions", "AuctionFrameBid" }, function(panel)
        Skin:Strip(panel)
        Skin:Panel(panel, { bgAlpha = 0.96 })
        M:SkinScrollsIn(panel)
    end)

    M:Controls({
        "BrowseSearchButton", "BrowseResetButton", "BrowseBuyoutButton",
        "AuctionsCreateAuctionButton", "AuctionsCancelAuctionButton", "BidBidButton",
    }, function(button)
        Skin:Button(button)
    end)

    M:Controls({ "BrowseName", "BrowseMinLevel", "BrowseMaxLevel", "BrowsePrice" }, function(control)
        if control and type(control.GetObjectType) == "function" and control:GetObjectType() == "EditBox" then
            Skin:EditBox(control)
        end
    end)
end

local function SkinProfessions()
    M:Controls({ "ProfessionsFrame", "TradeSkillFrame" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        M:Tabs({ "ProfessionsFrameTab1", "ProfessionsFrameTab2", "TradeSkillFrameTab1" })
        M:SkinScrollsIn(frame)
        M:SkinButtonsIn(frame)
    end)
end

local function SkinBank()
    M:Controls({ "BankFrame", "WarbandBankFrame" }, function(frame)
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    end)
end

M:Panel("trade", { label = "交易", group = "交易", apply = SkinTrade,
    frames = {
        "TradeFrame", "TradeFrameCloseButton",
        "AcceptTradeButton", "CancelTradeButton", "AcceptAllTradesButton",
        "TradeShowPlayerTargetItems", "TradeFrameToggleReciprocate", "TradeTargetToggleReciprocate",
        "TradePlayerInputMoneyFrame", "TradeRecipientInputMoneyFrame",
        "TradePlayerInputMoneyFrameOkayButton", "TradePlayerInputMoneyFrameCancelButton",
        "TradeRecipientInputMoneyFrameOkayButton", "TradeRecipientInputMoneyFrameCancelButton",
    } })

M:Panel("mail", { label = "邮箱", group = "交易", apply = SkinMail,
    frames = {
        "MailFrame", "InboxFrame", "SendMailFrame", "OpenMailFrame",
        "InboxFrameOpenButton", "InboxFrameReplyButton", "InboxFrameDeleteButton",
        "InboxPrevPageButton", "InboxNextPageButton",
        "SendMailMailButton", "SendMailCancelButton",
    } })

M:Panel("merchant", { label = "商贩", group = "交易", apply = SkinMerchant,
    frames = {
        "MerchantFrame", "MerchantNextPageButton", "MerchantPrevPageButton",
        "MerchantRepairButton", "MerchantRepairAllButton",
        "MerchantSellButton", "MerchantBuyBackButton", "MerchantFrameScrollFrame",
    } })

M:Panel("trainer", { label = "训练师", group = "交易", apply = SkinTrainer,
    frames = {
        "ClassTrainerFrame", "TrainerFrame",
        "ClassTrainerTrainButton", "ClassTrainerCancelButton",
    } })

M:Panel("auction", { label = "拍卖行", group = "交易", apply = SkinAuction,
    frames = {
        "AuctionFrame", "AuctionFrameTab1", "AuctionFrameTab2", "AuctionFrameTab3",
        "AuctionFrameBrowse", "AuctionFrameAuctions", "AuctionFrameBid",
        "BrowseSearchButton", "BrowseResetButton", "BrowseBuyoutButton",
        "AuctionsCreateAuctionButton", "AuctionsCancelAuctionButton", "BidBidButton",
        "BrowseName", "BrowseMinLevel", "BrowseMaxLevel", "BrowsePrice",
    } })

M:Panel("professions", { label = "专业 / 制造", group = "交易", apply = SkinProfessions,
    frames = {
        "ProfessionsFrame", "TradeSkillFrame",
        "ProfessionsFrameTab1", "ProfessionsFrameTab2", "TradeSkillFrameTab1",
    } })

M:Panel("bank", { label = "银行", group = "交易", apply = SkinBank,
    frames = { "BankFrame", "WarbandBankFrame" } })
