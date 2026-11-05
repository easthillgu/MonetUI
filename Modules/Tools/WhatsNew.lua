-- Modules/Tools/WhatsNew.lua
-- 版本更新后一次性提示（借鉴 TweaksForever / RurutiaSuite 的 WhatsNew 思路：**只借机制**，
-- 条目全部我们自己写 —— 那两家都是不可复制的许可（GPL / All Rights Reserved），文案更不可能拿）。
--
-- 为什么要有：公开发行的插件每次更新后，玩家不知道"变了什么、去哪儿找设置"。
-- 做法克制到只有一屏：
--   * 版本号取 `.toc` 的 `## Version`（与启动横幅同一来源，不另立常数，避免两处不同步）；
--   * 与 SavedVariables 里记的 `whatsNewSeen` 比对，**只在版本变化时打一次**；
--   * 同一版本内任何时刻可用 `/mui whatsnew` 重看（打了就不再打扰，但玩家想再看能得到东西）。
--
-- 只读、不挂任何钩子、不建常驻帧：纯登录一次性的文本输出。
-- ⚠ 文案纪律：每条都必须真做到过（可在 git log / docs/HANDOFF.md 对上提交），
--   不写"优化了性能"这种无法核验的话；宁少不多。

local ADDON_NAME, ns = ...

local M = { name = "WhatsNew" }

-- 每个版本一组要点，**最新的放最前**。新加版本时就在这里加一项。
local NOTES = {
    ["0.12.0"] = {
        "背包：分类窗口 + 品质边框 + 物品等级数字 + 冷却遮罩；"
            .. "「剩余空间」那一行现在是**真格子**，物品可以直接拖进空位（开服日已实机掉落验证）。",
        "银行：与背包同语言、**同屏并存不重叠**（拖过的位置各记各的）；"
            .. "新增「包裹管理」折叠面板（一键存入 / 放开暴雪那块）。",
        "配色：随区域切换莫奈主题（环境色离线采样 + 运行期派生四档），无需读贴图像素。",
        "美化：约 46 个暴雪窗口换成我们的窗口语言；只做窗口装饰，不碰里面的按钮脚本。",
        "右键小地图的微型菜单这一版**只有三行**（背包 / 地图 / 设置）："
            .. "点一行去打开别的暴雪面板在这台客户端没有合法做法（试过两种，都会刷拦截），"
            .. "所以先收掉；信息栏那一排数字仍可悬停看明细。",
        "诊断：新增 `/mui report`（环境 / 与默认值的差异 / 本会话警告 / 美化台账 / 同机插件）、"
            .. "`/mui minimap menu`（小地图右键卡在哪一层）、`/mui bags probe`、`/mui bags layout`。"
            .. "出问题先跑 `/mui report`，并把其它插件全关掉复现一次 —— 同机的按钮收纳类插件"
            .. "会搬走我们的命中层，账容易记到 MonetUI 名下。",
    },
}

local function CurrentVersion()
    if type(C_AddOns) ~= "table" or type(C_AddOns.GetAddOnMetadata) ~= "function" then return nil end
    local ok, v = pcall(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version")
    if not ok or type(v) ~= "string" or v == "" then return nil end
    return v
end

--- 打印某个版本的要点（无该版本记录时给一句诚实的话，不编内容）。
function M:Show(version)
    version = version or CurrentVersion()
    if not version then
        ns:Print("读不到本插件版本号（C_AddOns.GetAddOnMetadata 不可用）。")
        return true
    end
    local notes = NOTES[version]
    if not notes then
        ns:Print(("当前版本 %s：本版没有单独的准备更新说明（改动明细见配置面板与项目仓库）。"):format(version))
        return true
    end
    ns:Print(("|cffffd100MonetUI 已更新到 %s|r —— 本版要点："):format(version))
    for _, line in ipairs(notes) do ns:Print("  · " .. line) end
    ns:Print("  输入 |cffffd100/mui|r 打开配置；出问题先跑 |cffffd100/mui report|r。")
    return true
end

--- 只在版本变化时提示一次；记在 SavedVariables（与本体存档同一份，落盘时机同其他设置）。
function M:AnnounceIfNeeded()
    local version = CurrentVersion()
    if not version then return end
    local ok, db = pcall(function() return ns:DB() end)
    if not ok or type(db) ~= "table" then return end
    if db.whatsNewSeen == version then return end
    db.whatsNewSeen = version
    self:Show(version)
end

function M:Initialize()
    -- 不在 Initialize 里直接刷屏：登录横幅已经占了十几行，晚一拍再提示，读起来分得清。
    if type(C_Timer) == "table" and C_Timer.After then
        C_Timer.After(3, function() self:AnnounceIfNeeded() end)
    else
        self:AnnounceIfNeeded()
    end
end

function M:HandleCommand(rest)
    if rest == nil or rest == "" or rest == "show" then return self:Show() end
    return false
end

function M:SetEnabled(enabled)
    -- 关掉就抹掉"已看过"，便于他重新打开时再看一次（不静默改别的模块状态）。
    if enabled then return end
    local ok, db = pcall(function() return ns:DB() end)
    if ok and type(db) == "table" then db.whatsNewSeen = nil end
end

ns:Register("WhatsNew", M)
