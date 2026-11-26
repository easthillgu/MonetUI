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
    ["0.13.16"] = {
        "聊天条换成一条「频道细条」：宽与聊天窗齐平、高 3px，按 说/喊/密/队/团/公/世界 七格等分，每格用该频道自己的颜色；当前频道最亮、本场景用不上的格子压暗，点格子即切到该频道。",
        "聊天输入统一交回客户端自带的输入框（`/命令`、密语、物品链接都正常）；插件不再自建输入框，也不再改它的位置——它停在客户端放的地方，不会被拽回去。",
        "聊天页签挪到聊天框底边并常显，不再和输入框挤在同一行、也不再躲在输入框后面。",
        "自定义频道现在真的会出现（之前 `Enum.PermanentChatChannelType` 取成了整张表，把所有自定义频道过滤掉了）：大脚世界频道、本地防务都能在细条上看到。",
        "小地图：第三方插件的按钮统一收进「插件收纳」，地图边上不再围第二圈图标。",
        "信息栏：好友格改用战网好友数（本服名册恒空），名册没读到之前留空、不再冒充 0/0；新增加公会格（在线/总数）。",
        "信息栏：耐久提示改成「总评 + 最低一件 + 逐件清单」，`/mui infobar dura` 可看实时读数；槽位表按 InventorySlotId 修正（17 副手、18 远程）。",
        "姓名板：模块关掉时独立清点并还原暴雪自己的板子，只有 SetAlpha 真被拒才算还原失败。",
    },
    ["0.13.15"] = {
        "姓名板：暴雪自带的那只板子现在**真的**会被压暗（模块关掉时也真的还原）—— 这段代码此前一直没执行过。",
        "美化：下拉菜单的展开箭头终于换皮了；同一段毛病让它连第一个按钮都没走到就报错。",
        "动作条：拖放接收器改成整个模块共用一条轮询（此前每条动作栏各一条、永不注销，8 条栏 = 每秒 80 拍常驻），没有接收器时它自己摘掉。",
        "动作条：战斗中成串来的槽位事件合并成一帧最多一次整量重画，不再一发事件重画所有条。",
        "姓名板 / 团队框：名字只在「文字、可用宽度、字号」真变了的时候才重新量与缩档，不再每次掉血都重排。",
        "团队框：名册变化改成一条错峰补刷链（0.05 / 0.3 / 1.0 秒），一次组队不再叠三份全量刷新。",
        "信息栏：耐久与货币两块的连发事件做 0.25 秒合并（它们每次都是整批重算：约 110 个背包槽 / 最多 400 行货币）。",
    },
    ["0.13.14"] = {
        "姓名板 debuff 改由暴雪引擎容器绘制，只显示你自己施放的减益，排在名字上方、左对齐向右再向上长，图标用和目标框一样的矩形裁切。",
        "施法条倒计时、血量颜色和「对你施法」交给客户端自己的绑定，战斗中机密值锁住时也不会空白。",
        "团队框挪到小地图右侧，单位收窄到 48px 让 8 组放得下；团队里不再显示小队，窄格姓名只取前 3 个字。",
        "点团队成员时会立刻压住暴雪新建的黄色选中描边，小地图旁不再冒空框。",
        "修复战斗中拖放接住器写受保护按钮引发的拦截提示，以及锁定时拖动任务追踪标题会报错。",
    },
    ["0.13.13"] = {
        "增益/减益：长时与永久 buff 可以折起来了 —— 收起时显示「+N」，点开展开、旁边出现「-」点它收回；战斗中同样可用。",
        "增益/减益：武器临时附魔（毒药、磨刀石）战斗中也能看见；鼠标提示按光环实例取，排序后不再对错图标。",
        "姓名板与目标 / 焦点 / 目标的目标：显示暴雪团队标记（设置里可关）。",
        "控制台优化：新增两条「法术密度」开关，团队 / 副本里的地面法术效果不再消失。",
        "小地图：修复进副本后小地图美化失效、主菜单露出的问题。",
    },
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
    ns:Print("  输入 |cffffd100/mui|r 打开配置"
        .. (ns.dev and "；出问题先跑 |cffffd100/mui report|r。" or "。"))
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
