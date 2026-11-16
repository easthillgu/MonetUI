-- MonetUI Core.lua
-- Entry point: saved settings, module registry & lifecycle, theme plumbing.
-- Every file shares the private namespace table `ns` (the second value of `...`); the Utils files hang off it, Core adds the module registry and exposes it as the global `MonetUI`.

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

ns.name = ADDON_NAME
-- 版本一律从 TOC 读，别再硬编码：0.13.0 / 0.13.1 发版时只改了 TOC / CHANGELOG / tag，
-- 这里却留在 0.12.0，启动横幅和 /mui status 都在报旧版本（11-10 实机读数发现）。
-- 与 WhatsNew 同一个来源，发版时不再需要第四处手工对齐。
do
    local CAddOns = _G.C_AddOns
    local ok, tocVersion = false, nil
    if type(CAddOns) == "table" and type(CAddOns.GetAddOnMetadata) == "function" then
        ok, tocVersion = pcall(CAddOns.GetAddOnMetadata, ADDON_NAME, "Version")
    end
    ns.version = (ok and type(tocVersion) == "string" and tocVersion ~= "") and tocVersion or "?"
end

-- 开发版门闸：TOC 的 `## X-Dev-Build: dev` 只在仓库与本地部署里是这个值。
-- release.yml 在 packager 之前跑 tools/strip-dev.js，把标记改成 release 并从加载清单里
-- 摘掉 DevTools.lua / Report.lua；两份文件也列在 .pkgmeta 的 ignore 里，不进 zip。
-- 于是发布版不注册诊断命令、不打印开发期自检提示，dev 代码仍完整留在本地/仓库。
-- 默认关闭（取不到元数据或字段被改坏都按发布版处理），别让漏改的打包变成刷屏。
do
    local CAddOns = _G.C_AddOns
    local ok, flag = false, nil
    if type(CAddOns) == "table" and type(CAddOns.GetAddOnMetadata) == "function" then
        ok, flag = pcall(CAddOns.GetAddOnMetadata, ADDON_NAME, "X-Dev-Build")
    end
    ns.dev = (ok and flag == "dev") and true or false
end

local DEFAULTS = {
    enabled = true,
    -- 启动前置设置（Init.lua）：一次性把暴雪编辑模式布局另存并激活，让聊天框底边
    -- 与动作条共用 ns.Layout.bottom。true = 已处理过，不再重复新建布局。
    init = {
        chatAligned = false,
    },
    modules = {
        UnitFrames   = true,
        GroupFrames  = true,
        Cooldown     = true,
        BuffFrame    = true,
        Minimap      = true,
        Bags         = true,
        QuestTracker = true,
        ActionBars   = true,
        Nameplates   = true,
        Skins        = true,
        InfoBar      = true,
        Tooltip      = true,
        Atmosphere   = false,   -- A4 氛围暗角：默认关（它压的是整个画面，开不开是审美选择，不是缺省）
    },
    -- 位置服务（Utils/Mover.lua）：全 addon 的框共用一套拖拽 / 吸附 / 锁。locked 是全局锁，locks 按组覆盖；
    -- grid 是网格步长（物理像素，0 = 关），snap / snapRange 是框与框互相吸附的开关与范围（物理像素）。
    -- 2026-11-15（§8.124）：**默认锁定**。原来 locked=false，player 框常驻可见，左键一点一拖就把
    -- 单位框架挪走（战斗外 SetPoint 一定成功），玩家没打算摆位置却把布局弄乱。要摆位置时用
    -- `/mui unlock` 或配置面板的「锁定所有可移动框」临时解锁，摆完 `/mui lock`。
    -- 老存档兼容靠稀疏落盘（StripDefaults）：旧默认 false 的键在登出时已被剥掉，MergeDefaults
    -- 会补上新默认 true；只有玩家显式改过锁的存档才保留他自己的选择。
    mover = {
        locked    = true,
        locks     = {},
        grid      = 8,
        snap      = true,
        snapRange = 6,
    },
    theme = {
        useMonetColor  = true,
        -- 最小对比控制值（§8.123）：血条「填充↔背景（世界 / 空槽）」的最小 CR，
        -- 既是撞色区域纠偏的目标、也是那些区域在 /mui colors 账本里的判定线。
        -- 达标的区域（含河林默认）保持引擎原色。文字(4.5) / 边框(3.0) 另有固定可读线，
        -- 不跟这一条滑，避免把可读线调低成假达标。
        minContrast    = 1.8,
        -- Which engine slot borders are drawn from (see Color:GetBorderKey); one dropdown re-tints every border in the addon.
        borderKey      = "edge",
        -- Who owns the UI scale: "auto" pins it to the resolution (Utils/Media.lua scalePresets, so
        -- 1 UI unit is a whole number of physical pixels), "game" leaves it to the client's own setting.
        uiScaleMode    = "auto",
    },
    -- 氛围暗角（Modules/Atmosphere.lua）：strength = 压暗层的顶点 alpha，只有验收页量过的三档
    -- （0.06 / 0.10 / 0.12）；认不到就退回 0.10 那一档。压的是世界，所有 UI 天然在这层之上。
    atmosphere = {
        strength = 0.10,
    },
    -- Big-number formatting for health text: "cn" = 万/亿 (natural on zhCN), "auto" = K/M/B.
    numberFormat = (GetLocale() == "zhCN") and "cn" or "auto",
    -- Categorized bags & bank (Modules/Bags/Bags.lua): every slot is scanned once and claimed by the first matching category (垃圾 / 装备 / 消耗品 / 材料 / 任务 / 收藏 / 其他); each category gets its own framed, movable window tiled from `anchor`.  Reads only this client's C_Container / C_Bank APIs.
    bags = {
        iconSize       = 34,
        gap            = 4,
        columns        = 10,
        windowsPerRow  = 1,
        showReagentBag = true,
        showBank       = true,
        -- 「剩余空间」标题行右侧显示货币（复用 InfoBar 的自定义监控清单）。
        -- `/mui bags currency on|off` 可关；关掉只收文字，不动布局。
        currencyTitle  = true,
        -- §8.84：标题行用「图标 + 短数量」代替「名称 + 完整数量」，追踪项多时才放得下；
        -- 名称与完整数量移到悬停提示。icons off 可切回原来的纯文字排版。
        currencyIcons  = true,
        -- 银行：**接管暴雪银行框**（alpha 0 + 关鼠标），只留我们的窗。2026-11-06 作者拍板默认 on ——
        -- 依据 HANDOFF §8.57：银行空格已是真 ItemButton（绑 bag/slot），三条拖放（背→银 / 银→背 /
        -- 背→背）逐格实测通过。代价写清：买栏位 / 换银行包要走 `/mui bags bank off`（或面板里的
        -- 「放开暴雪」钮），因为 `C_Bank.PurchaseBankTab` 是受限 API，我们不做。
        -- ⚠ 关掉时必须写**显式 false**（见 `/mui bags hidebliz off` 分支），写 nil 会被默认值顶回来。
        hideBlizzardBank = true,
        anchor         = { frame = "MonetUIQuestTracker", side = "right", x = -18, y = -28 },
        positions      = {},   -- per-category window spots the user dragged to
    },
    -- Cooldown countdown text (Modules/Cooldown): the renderer scales the unit itself (60s -> minutes, 1h -> hours, 24h -> days, via Math:DurationText) and treats the last alertSeconds as "tight".  false for scale hands the numbers back to Blizzard; false for alert keeps one colour and one size.
    cooldown = {
        scale        = true,
        alert        = true,
        alertSeconds = 5,
        tenthsTH     = 10,   -- below 10s show one decimal (Andromeda's TenthTH)
        mmssTH       = 60,   -- at/above 60s show mm:ss       (Andromeda's MmssTH)
    },
    -- Unit frames in a slim-bar layout (see docs/mockup), sized per unit so target / focus / pet can follow the player frame.
    -- Health 4px / power 1px / widths 160-160-60-60-60: Andromeda's own configured numbers (Andromeda/gui/configs.lua:
    -- PlayerHealthHeight = 4, PlayerPowerHeight = 1, PlayerWidth = 160, PetWidth = 60 ...).  They used to be half that
    -- (health 2) because Andromeda rescales UIParent while MonetUI draws 1:1, so half its number was the same physical
    -- thickness -- but the woven ground (Widget:BarWeave) needs the room, so the bars are Andromeda's numbers now.
    -- fillColor/lostColor/powerColor pick the bar colours (inverse = edge 的 RGB 反相 + lost = 暗织纹底，两者都吃 Utils/Color.lua 的四级亮度阶梯，玩家/宠物/目标的目标默认这一对；class = the colour the game itself draws the unit in; black = missing part reads as background; type = coloured by UnitPowerType); smoothBars eases every bar from the client side so it still works while values are hidden.
    -- classPower draws the player's combo points as slim pips under the player frame (Blizzard keeps them inside the PlayerFrame this addon hides); threatGlow / hoverGlow are Andromeda-style edge glows re-tinted through Widget:SetBorderState so theme refreshes cannot stomp them.
    unitFrames = {
        hideBlizzard = true,
        -- 1px Monet border, then the gap Andromeda keeps between its health and power bars (its C.MULT, ~1px at 1440p).
        border = 1,
        split  = 1,
        threatGlow = true,
        hoverGlow  = true,
        textColorByPercent = true,
        smoothBars = true,
        powerColor = "type",
        classPower       = true,
        classPowerHeight = 3,
        classPowerGap    = 3,
        -- petHover：宠物单位框只在"鼠标悬停"或"宠物被选中（当前目标/焦点）"时 alpha 1，
        -- 其余时间 alpha 0（帧仍是显示状态，靠 visibility 驱动决定有没有宠物，见 UnitFrames）。
        petHover = true,
        -- Target auras: reparent Blizzard's own TargetFrame aura list onto our target frame (Andromeda's layout, growing up) and anchor it above.  Only the position is borrowed, never the data -- C_UnitAuras is hidden mid-fight, so this is the same ForeverUI trick the Nameplates module uses.
        showTargetAuras = true,
        targetAuraGap   = 22,
        player = { width = 160, health = 4, power = 1, fillColor = "inverse", lostColor = "weave",
                   point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0,    y = -180 },
        target = { width = 160, health = 4, power = 1, fillColor = "class", lostColor = "danger",
                   point = "LEFT",   relativeTo = "player",   relativePoint = "RIGHT",  x = 40,   y = 40 },
        targettarget = { width = 60, health = 4, power = 1, fillColor = "inverse", lostColor = "weave",
                   point = "LEFT",   relativeTo = "target",   relativePoint = "RIGHT",  x = 6,    y = 0 },
        pet    = { width = 60,  health = 4, power = 1, fillColor = "inverse", lostColor = "weave",
                   point = "RIGHT",  relativeTo = "player",   relativePoint = "LEFT",   x = -6,   y = 0 },
        focus  = { width = 60,  health = 4, power = 1, fillColor = "class", lostColor = "danger",
                   point = "RIGHT",  relativeTo = "player",   relativePoint = "LEFT",   x = -100, y = -40 },
    },
    -- 小队 / 团队框架（Modules/UnitFrames/Groups.lua）：暴雪安全头 + Monet 皮肤，位置交给 Utils/Mover.lua。
    -- party 是"自己 + 小队 1..4"一列；raid 是 8 组 × 5 人，每组一个头、并排成一排（空组留空位）。
    -- hideBlizzard 只在我们真的把头建出来之后才生效：模板缺失时暴雪的框一定留着，不能让人没框可用。
    groupFrames = {
        hideBlizzard = true,
        showIncomingHeals = true,
        showAbsorbs = true,
        -- 位置口径（2026-11-09 16:33 作者修订）：**只有团队框**贴小地图可见面板左侧，
        -- 小队框保持原来的屏幕位置（CENTER / UIParent / -330, 40），不跟着小地图跑。
        -- 团队锚的是 `MonetUIMinimapPanel` 而不是 `Minimap` 画布 —— 画布 256×256 上下各有
        -- 33 的透明带，锚它会高出一截。Mover 的 `ParentOf` 支持具名全局框；面板还没建 /
        -- 小地图模块关掉时按 fallback 落回屏幕（沿用团队原来的 300, 0）。
        -- 拖过的位置存在存档里、优先于这组默认值（项目惯例：不改玩家存过的位置），
        -- 想把团队贴回去用 `/mui groupframes minimap`；两者都回默认用 `defaults`。
        party = {
            enabled = true,
            width = 110, health = 18, power = 4, spacing = 2,
            showPlayer = true,
            healthText = "none",
            point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = -330, y = 40,
        },
        raid = {
            enabled = true,
            width = 72, health = 24, power = 3, spacing = 2, groupGap = 8,
            healthText = "none",
            point = "RIGHT", relativeTo = "MonetUIMinimapPanel", relativePoint = "LEFT", x = -14, y = 0,
            fallback = { point = "CENTER", relativePoint = "CENTER", x = 300, y = 0 },
        },
    },
    -- 首领框架（Modules/UnitFrames/BossFrames.lua）：安全按钮 + visibility 驱动，
    -- 风格与团队框同源；hideBlizzard 压制暴雪的 BossTargetFrameContainer。
    bossFrames = {
        enabled    = true,
        hideBlizzard = true,
        width      = 180,
        health     = 20,
        power      = 4,
        spacing    = 2,
        healthText = "none",
        point = "RIGHT", relativeTo = "UIParent", relativePoint = "RIGHT", x = -200, y = -100,
    },
    -- Blizzard's bottom chrome is re-parented off screen, not destroyed, so the buttons keep working for keybinds.
    -- ownBars: MonetUI draws its own 1..8 bars on LibActionButton-1.0 (Modules/ActionBars) and parks Blizzard's bars; with it off only hideBlizzard can still hide them.  First-run layout lives in BAR_DEFS, positions holds a per-bar override.
    actionBars = {
        ownBars      = true,
        hideBlizzard = true,
        hideBagBar   = true,
        barCount     = 3,
        buttonSize   = 28,
        spacing      = 2,
        showHotkey   = true,
        showCount    = true,
        showMacro    = true,
        -- petHover / stanceHover：收养来的两条（宠物动作条、姿态条）平时半透明 alpha 0.3，
        -- 鼠标移上去变 1（帧仍是"显示"状态，所以鼠标进得来，也不会和状态驱动的显隐打架）。
        -- 见 Modules/ActionBars 的 SetupHoverOnly。
        petHover     = true,
        stanceHover  = true,
        positions    = {},
    },
    -- Nameplates (姓名板, Modules/Nameplates) sit on Blizzard's own plate bases: the base owns targeting/clicks, the module draws a Monet slim bar on it and hides Blizzard's UnitFrame child.  Which units get a plate at all is a CVar, so the show* switches are pushed into nameplateShowFriends/Enemies/... on Apply and put back when the module is off; hideCritters/hideDead filter on top of that.
    -- width/height are the health box, nameSize the name/level row, castHeight the cast bar; forcePlateSize matches Blizzard's clickable hitbox to the drawn box so a click lands on the plate you actually see.
    nameplates = {
        showFriendly = false,   -- friendly players (Blizzard default: off)
        showEnemy    = true,    -- hostile players and npcs
        showNPC      = false,   -- friendly npcs (guard / quest givers)
        showMinor    = true,    -- "minus" mobs (the client's enemy-minus CVar)
        showTotems   = true,
        showSelf     = false,
        hideCritters = true,
        hideDead     = false,
        viewDistance = 60,      -- nameplateMaxDistance

        width        = 120,
        height       = 12,
        -- 10：暴雪自己的名牌名是 9.6 号，我们原来跟它用 12 反而更大（玩家 2026-10-27 要求缩小）。
        -- SnapSize 的紧凑档就是 10 / 12，10 = 比暴雪原版略小、比 12 收一档。
        nameSize     = 10,
        showName     = true,
        showLevel    = true,
        showPercent  = true,
        truncate     = true,
        nameLength   = 16,

        showCast     = true,
        castHeight   = 13,

        showThreat      = true,
        highlightTarget = true,
        classColor      = true,
        smooth          = true,
        forcePlateSize  = true,
    },
    -- Blizzard panel beautification (Modules/Skins): each window is a switch under `panels`.  `font` is an optional global override: "off" (Blizzard faces) or "pixel" (dual-track per Media's funnel: WenKai + AA at >=12px, PingFangPixel hard-edged below).
    skins = {
        font   = "pixel",
        panels = {},
        -- 聊天页签悬停才显示（§8.89）：关掉就回到始终显示。输入框嵌入框内顶部不受此开关影响。
        hoverChatTabs = true,
        -- 聊天输入框位置（§8.89.4 / C）：`top` 骑在聊天框顶沿，`bottom` 回到原生框底。
        -- 仅对 `chatEditBoxMode` 为 `show` / `fade` 有意义（`hide` 档无论如何都折在顶部带里，聚焦才露出）。
        chatEditBoxPos = "top",
        -- 输入框平时状态（§8.96，取代 §8.91 的二元 `chatEditBoxAutoHide`）：
        --   "hide" = 完全折叠，仅聚焦（Enter/点击）才出现；
        --   "fade" = 平时渐隐到 0.25（失焦 3 秒后开始、0.35 秒淡出），聚焦回 1.0；
        --   "show" = 常显，不淡不藏。
        -- 三档由「输入框平时状态」下拉切换，PollWatch 下一拍即生效，不必 /reload。
        chatEditBoxMode = "fade",
        -- 已废弃（§8.96）：仅作老 DB 兼容占位，新代码一律读 `chatEditBoxMode`。
        chatEditBoxAutoHide = true,
        -- §8.90 聊天页签三态色 + 独立淡入时长（hex，不含 #）：未选中 / 选中 / 未读闪烁。
        -- 默认取中性灰 / 白 / 警示红，足以区分三态；玩家可在 SimpleConfig 改。
        tabColorNormal   = "9a9a9a",
        tabColorSelected = "ffffff",
        tabColorFlash    = "ff6b6b",
        -- 页签悬停淡入淡出时长（秒）；0.18 贴近 Chattynator，支持 0.1/0.3/0.5。
        tabFade         = 0.18,
    },
    -- 小地图 (Modules/Minimap)：方形地图 + 主题面板 + 顶部区域名条；暴雪的集群按钮逐项接管。
    -- hide* 是「把暴雪那个按钮藏起来」，默认全藏（方形面板和暴雪原样按钮混在一起最难看）；
    -- 改成 false 就把暴雪原样放回来，隐藏与还原都由模块自己做，配置面板即时生效。
    minimap = {
        zoneText     = true,   -- 自建区域名（悬停小地图时显示在地图内部中间靠上）
        zonePvPColor = true,   -- 战区 / 冲突区域时区域名染成危险色
        scrollZoom   = true,   -- 方形地图上滚轮缩放（四角也够得到）
        border       = 1,      -- 面板边框粗细（固定 1 物理像素，旧存档里的值不再生效）
        gap          = 33,     -- 面板**右边缘**离屏幕右边的距离（底边由 Utils/Layout.lua 统一对齐第一动作条）
        zoom         = -1,     -- 记住的缩放级别（-1 = 没记过，第一次滚轮后才有值）
        -- 地图形状只有一套：正方画布 256×256 + 遮罩裁掉上下各 33，露出 256×190 的可见带。
        -- 画面不重绘，所以不会被拉伸。曾经还有一档 "resize"（画布直接 256×190），因为
        -- 非正方形 SetSize 在 WoW 里是把正方渲染拉伸（纵向压扁 ~26%），已经删掉；
        -- 老存档里的 shape 键由 schema 5 清掉（见 Migrate）。
        -- 地图内的四个独立按钮（前三颗是 3:4 徽章贴图，第四颗是动态字符徽章）
        mapTracking    = true, -- 追踪（左下）
        mapDifficulty  = true, -- 难度（左上）
        mapCompartment = true, -- 插件收纳（右上）
        mapQueueStatus = true, -- 排队/寻找组队状态（右下）；与 LFG 窗肖像位共用 Skin:GlyphBadge
        microMenu      = true, -- 右键小地图弹出微型游戏菜单
        microMenuSecure = true, -- #43 全量安全载体（14 行：4 个自有动作 + 10 行代点原生微按钮）。
                                 -- 2026-11-06 作者实机逐行验过转正：能开的全部开出对应面板，
                                 -- 传承（IsEnabled=false）与游戏菜单（暴雪不吃脚本化点击）不建行，
                                 -- 全程 logs ERR / BLOCKED 与 taint.log 零新增。关掉即回 4 行纯 C_* 菜单。
        hideZoneText    = true,
        hideCoords      = true,
        hideClock       = true,
        hideMail        = true,
        hideTracking    = true,
        hideZoom        = true,
        hideDifficulty  = true,
        hideCrafting    = true,
        hideLanding     = true,
        hideCompartment = true,
        hidePromo       = true,
        hideCompass     = true,
        hideBorderTop   = true,
        hideMicroMenu   = true,
    },
    -- Info bar (信息栏, Modules/InfoBar): one full-width strip along a screen edge carrying small data blocks.  anchorTop pins it to the top edge (so it clears the bottom action bars), height is the strip height (14 fits a 12px font), mouseover keeps the blocks invisible until hovered (except the system block: position="CENTER" + always=true, it stays lit -- 11-07 作者指示), combatPulse breathes red in combat / yellow with pending invites, xp draws the experience progress on the bottom hairline (hover the ▲ to read the numbers) and xpFaction hands that same line to the watched reputation at max level; blocks are one switch per data block.
    infobar = {
        anchorTop   = true,
        height      = 14,
        mouseover   = true,
        combatPulse = true,
        xp          = true,
        xpFaction   = true,
        -- 货币块（Modules/InfoBar/Currency.lua）：backpack=沿用背包显示标记 / custom=自己勾的
        -- currencyID 清单 / all=货币页全部已发现项；currencyMax 是条上最多显示几项，
        -- 多出来的折成 "+N"，提示框始终列全；currencyShowZero 管 0 值要不要占一格。
        -- §8.82：金币是 Snapshot 的基线条目（GetMoney，伪 ID 0），不属于 currencyWatch；
        -- 三种模式都带它。其它货币默认一条都不追踪，由玩家自己 add / 右键勾选。
        currencyMode     = "backpack",
        currencyWatch    = {},
        currencyMax      = 3,
        currencyShowZero = true,
        blocks = {
            gold       = true,
            durability = true,
            currency   = true,
            system     = true,
            spec       = true,
            friends    = true,
            quest      = true,
            stats      = true,
        },
    },
    -- 鼠标提示 (Modules/Tooltip)：位置是全局行为，和美化分开开关。三种摆法：
    --   cursor  = 所有提示框（物品 / 技能 / 角色 / 光环……）跟着鼠标走（默认，跟手且贴边自动翻）；
    --   minimap = 提示框右下角对齐小地图面板右上角（贴在地图上沿、右边缘齐平）；
    --   off     = 退回暴雪的默认容器（编辑模式下可移动）。
    tooltip = {
        anchor   = "cursor",  -- 位置：cursor=跟随鼠标 / minimap=贴小地图右上角 / off=暴雪默认
        enrich   = true,      -- 单位提示追加「目标: 谁」一行
        idsByAlt = true,      -- 按住 Alt 显示 ID（NPC / 物品 / 法术）
        neutralText = true,   -- 正文归一：通用说明文字（白 / 灰 / 纯黄）染成主题 neutral，品质与职业色不碰
    },
    -- 光标拖尾 / 速度星芒 (Modules/Cursor)：纯装饰，拖尾跟主题边框色，星芒用高光色。
    cursor = {
        trail = true,
        glow  = true,
    },
    -- 通知横幅 (Modules/Toast)：只做本项目真的缺的两件事 —— 新邮件（小地图邮件图标被藏掉了）
    -- 和背包满。duration = 每条停留秒数。
    toast = {
        mail    = true,
        bagFull = true,
        duration = 5,
        combatAlert = true,   -- 进入 / 离开战斗提醒（原 CombatText 的 alert，2026-11-02 并入）
    },
    -- 装备耐久警告 (Modules/Durability)：跌破 threshold 时弹一条通知，修好/换装后才再次提醒。
    durability = {
        warn      = true,
        threshold = 30,
    },
}
ns.DEFAULTS = DEFAULTS

local modules = {}
local moduleOrder = {}
local started = false

local function MergeDefaults(dst, src)
    for key, value in pairs(src) do
        if type(value) == "table" then
            if type(dst[key]) ~= "table" then dst[key] = {} end
            MergeDefaults(dst[key], value)
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
    return dst
end

--- 稀疏落盘（#33，2026-11-05）：把 `dst` 里**等于 `src`（DEFAULTS）默认值**的键就地删掉，只留玩家真正改过的。
--- 只在 `PLAYER_LOGOUT` 落盘前跑一次 —— 运行期 `ns:DB()` 仍是 `MergeDefaults` 补满的全量，所有读取点不用改。
--- 收益：① 以后改 `DEFAULTS` 里某个值能传到老玩家（他们的库里没烘死旧默认）；② WTF 文件瘦下来。
--- 递归只对"默认值也是表"的下钻：默认是空表（`bags.positions` / `mover.locks`）时下钻剥不到任何键，
--- 玩家写进去的位置/锁自然保留；诊断账本（colorReport / layerReport / perfReport / compatReport）和
--- `schema` 都不在 DEFAULTS 顶层，本函数只遍历 DEFAULTS 的键，绝不误删它们。
--- 清空的子表顺手删掉，省得 SavedVariables 里留一堆 `{ }`。
local function StripDefaults(dst, src)
    if type(dst) ~= "table" then return end
    for key, defVal in pairs(src) do
        if type(defVal) == "table" then
            if type(dst[key]) == "table" then
                StripDefaults(dst[key], defVal)
                if next(dst[key]) == nil then dst[key] = nil end
            end
        else
            if dst[key] == defVal then dst[key] = nil end
        end
    end
end

--- Database schema.  Bumping this re-applies the settings that changed their meaning in the shipped defaults (see Migrate).
local SCHEMA = 9

--- One-off adjustments to a database written by an older MonetUI: MergeDefaults only fills in *missing* keys, so a value whose number changed has to be pushed explicitly.  Stored positions are the player's and are never touched here.
--- One entry per schema version, keyed by the version it migrates *to*; the loop below runs exactly the entries newer than the stored schema, in version order.  Adding a setting whose meaning changed = append MIGRATIONS[SCHEMA + 1] and bump SCHEMA -- never a new if-block inside a previous entry.
local MIGRATIONS = {}

-- v2: health bars halved to Andromeda's real thickness, plus the fillColor / lostColor colour rules.
MIGRATIONS[2] = function(db)
    for unit, defaults in pairs(DEFAULTS.unitFrames) do
        if type(defaults) == "table" then
            local stored = db.unitFrames[unit]
            if type(stored) == "table" then
                stored.health    = defaults.health
                stored.power     = defaults.power
                stored.fillColor = defaults.fillColor
                stored.lostColor = defaults.lostColor
            end
        end
    end
end

-- v3: the bars go back to Andromeda's configured size (health 4, power 1) -- the woven ground needs the room.
-- Only the sizes are pushed; the position the player dragged the frame to is left alone.
MIGRATIONS[3] = function(db)
    for unit, defaults in pairs(DEFAULTS.unitFrames) do
        if type(defaults) == "table" then
            local stored = db.unitFrames[unit]
            if type(stored) == "table" then
                stored.health = defaults.health
                stored.power  = defaults.power
            end
        end
    end
end

-- v4: 小地图曾经把默认形状翻成 "mask"（非正方形 SetSize 会把正方渲染拉伸）。
-- v5: 现在形状只剩一套，"shape" 这个键作废 —— 顺手从老存档里删掉，免得以后有人问它是干什么的。
MIGRATIONS[5] = function(db)
    if type(db.minimap) == "table" then
        db.minimap.shape = nil
    end
end

-- v6: 战斗辅助换方向 —— 战斗数字默认回到暴雪自己的（机密值拿不到明文），我们自己的
-- 三类从"开"强制翻成"关"；"combat"（压暴雪进出战斗小字）这个键由 alert 接管，作废删除。
MIGRATIONS[6] = function(db)
    if type(db.combatText) == "table" then
        db.combatText.damage = false
        db.combatText.heal   = false
        db.combatText.avoid  = false
        db.combatText.combat = nil
    end
end

-- v7: 撤销"战斗数字显示区域偏移" —— 该功能往 CombatText.textLocations 写值，会污染
-- 暴雪在机密比较里读的字段（CombatText.lua:364 比较机密的 lowestMessage 时读
-- textLocations.startY），按玩家规矩"涉及机密值则不改"作废，键删掉。
MIGRATIONS[7] = function(db)
    if type(db.combatText) == "table" then
        db.combatText.area = nil
    end
end

-- v8: 姓名板名字 12 → 10。暴雪自己的名牌名是 9.6 号，我们原来跟它平级用 12 反而更大
-- （玩家 2026-10-27："名字字体缩小到 10 或 12"）。只降"还是旧默认 12"的库，玩家自己改过的不动。
MIGRATIONS[8] = function(db)
    if type(db.nameplates) == "table" and db.nameplates.nameSize == 12 then
        db.nameplates.nameSize = 10
    end
end

-- v9: 玩家 / 目标的目标的"反相血条 + 暗织纹空槽"从代码硬顶改成两种可选样式
-- （fillColor = "inverse"、lostColor = "weave"，见 HANDOFF 8.14.4③）。存档里还写着旧默认值的
-- 那两栏（那套观感当时无论如何都由代码决定）换成新样式；玩家真选过的一个不动。
MIGRATIONS[9] = function(db)
    local legacy = {
        player       = { fillColor = "highlight", lostColor = "black" },
        pet          = { fillColor = "highlight", lostColor = "black" },
        targettarget = { fillColor = "class",     lostColor = "danger" },
    }
    for unit, old in pairs(legacy) do
        local stored = type(db.unitFrames) == "table" and db.unitFrames[unit]
        if type(stored) == "table" then
            if stored.fillColor == old.fillColor then stored.fillColor = "inverse" end
            if stored.lostColor == old.lostColor then stored.lostColor = "weave" end
        end
    end
end

local function Migrate(db)
    local from = db.schema or 1
    if from >= SCHEMA then return end

    for v = from + 1, SCHEMA do
        local step = MIGRATIONS[v]
        if step then step(db) end
    end

    db.schema = SCHEMA
end

local function LoadDatabase()
    local db = ns:DB()
    MergeDefaults(db, DEFAULTS)
    Migrate(db)
    return db
end

function ns:Print(message)
    print("|cff88aaff[MonetUI]|r " .. tostring(message))
end

--- 开发期自检提示：发布版静默（账本 / 返回值照旧，只是不往聊天框刷）。
--- 只给"启动时自动打出来的诊断信息"用；玩家主动敲命令的输出仍走 ns:Print。
function ns:DevPrint(message)
    if self.dev then self:Print(message) end
end

--- The saved variable table, always a table.
function ns:DB()
    if type(_G.MonetUIDB) ~= "table" then
        _G.MonetUIDB = {}
    end
    return _G.MonetUIDB
end

--- Walk a dotted path through the global table ("WorldMapFrame.BorderFrame") and return the object, or nil.
-- 每一段都用 pcall 取：中间节点既可能是表也可能是**帧对象（本客户端的框体是带元表的用户数据）**，
-- 对它们取字段要靠 __index；碰上字符串 / 数字 / nil 会抛，吞掉当成"这条路径到不了"。
-- 这是本仓唯一的"按名字找对象"：皮肤层每个调用点都过它（见 `Skin:Need`），
-- 所以名字写错不再是静默跳过，而是 `/mui skins diagnose` 里的一行 ✗。
function ns.ResolveObject(path)
    if type(path) ~= "string" or path == "" then return nil end
    local node = _G
    for segment in string.gmatch(path, "[^%.]+") do
        if node == nil then return nil end
        local ok, value = pcall(function() return node[segment] end)
        if not ok then return nil end
        node = value
    end
    return node
end

function ns:Register(name, module)
    assert(type(name) == "string", "Module name must be a string")
    assert(type(module) == "table", "Module must be a table")

    if not modules[name] then
        moduleOrder[#moduleOrder + 1] = name
    end
    modules[name] = module
    return module
end

function ns:GetModule(name)
    return modules[name]
end

--- 给任意对象（框体、贴图、字体串）挂"我们做过了"的标记，**不写进对象本身**。
--- 本客户端的污染判定是按键算的：插件往暴雪的框体上写一个字段，这个框体随后的暴雪代码
--- 就会以我们的名义跑（实机证据：`issecurevariable` 在 NamePlate1UnitFrame 上唯一为 false
--- 的键就是 `__monetAuraHook`，随后 `CompactUnitFrame_OnUpdate` 报
--- "compare 'maxHealth' (secret number) ... tainted by 'MonetUI'"；同一原因还让暴雪自己的
--- SetPoint 被判 "anchor family connection"）。所以所有簿记走这张以对象为弱键的旁表。
local marks = setmetatable({}, { __mode = "k" })

function ns:Mark(object, key, value)
    if object == nil then return value end
    local t = marks[object]
    if not t then
        t = {}
        marks[object] = t
    end
    t[key] = value
    return value
end

function ns:Marked(object, key)
    local t = marks[object]
    return t and t[key]
end

--- 每模块一对的弱键旁表（Ellesmere `NewFrameData` 结构，2026-11-06 提取自 9.7.6）。
--- 调用方 `local FFD, GetFFD = ns:NewFrameData()`：FFD 以对象为弱键，框体销毁/池回收自动除名；
--- GetFFD(frame) 首次访问建行表，之后 `d.x` 直接字段读写——字段按文件天然隔离，两个模块
--- 各自 `d.done` 互不可见，不用给键加全仓前缀。
--- **与 ns:Mark 并存**：跨文件共享的键（如 `art` 由 Widget 与 Skin 共写、`hidden` 由 Skin
--- 与 ActionBars 共用）仍走 ns:Mark 全局表；只有模块私有的幂等守卫键迁到 NewFrameData。
function ns:NewFrameData()
    local FFD = setmetatable({}, { __mode = "k" })
    local EMPTY = {}   -- nil 对象的占位行：读恒为 nil、写不落地，复刻 ns:Mark(nil,…) 的 no-op 语义
    return FFD, function(frame)
        if frame == nil then return EMPTY end
        local d = FFD[frame]
        if not d then d = {}; FFD[frame] = d end
        return d
    end
end

-- ------------------------------------------------------------------ 战斗延迟队列

-- 战斗里对受保护对象的操作（属性 / 换父 / 显隐 / 建容器）会被无声拒绝。各模块以前
-- 各自维护"战斗中置标记 → PLAYER_REGEN_ENABLED 排空"的小队列（review 2026-10-24
-- 数出 ~8 处重复），现在统一走 ns:AfterCombat：
--
--   ns:AfterCombat(key, fn)
--     key  字符串，模块内唯一。按 key 去重：同一个 key 只保留最新一次排入的动作。
--     fn   无参函数。不当场完成的动作在脱战（PLAYER_REGEN_ENABLED）后逐个执行；
--          单个动作失败就留在队列里，下一次脱战再试（失败每个 key 只提示一次）。
--   ns:AfterCombat(key, fn, "regen")
--     无论如何都等下一次脱战再执行，不当场跑。给"排空函数在自己执行中又往队列
--     加东西"的场景用：当场跑会立刻重入，等下一轮才是正确的一次性重试
--     （Minimap 的套用队列就是这种：Skin 在执行中失败会自己再排一次）。
--     队里的 fn 返回 false 表示"这次还做不了"（条件未满足，如秘值仍存活）：
--     留队等下一次排空重试，不计失败、不提示。
--
-- **排空的 fn 里判战斗一律用 `ns:InCombat()`，不要用原始的 `InCombatLockdown()`**：
-- 本客户端先派发 PLAYER_REGEN_ENABLED、之后才翻那个标志（见下面 combatState 的注释），
-- 所以排空执行当拍 `InCombatLockdown()` 仍然返回 **true** —— 拿它当门会把"脱战补做"
-- 判成"还在战斗"，动作再排回队列，玩家得**脱两次战**才看到生效（Nameplates 的牌子尺寸、
-- Auras 的战斗光环容器、BuffFrame 的战斗容器、Mover 挪受保护框都是这个症状）。

local afterCombatPending = {}   -- key -> fn
local afterCombatOrder   = {}   -- 排队顺序（pairs 无序，这里保插入序）
local afterCombatWarned  = {}   -- key -> true（该 key 的失败提示打过了）

-- ---- 战斗状态的唯一来源：PLAYER_REGEN_* 事件 ----------------------------------
-- **不要**在 PLAYER_REGEN_* 的回调里直接读 InCombatLockdown()：本客户端先把事件派给插件、
-- 之后才翻那个标志（2026-10-27 实机探针：disabled 事件里读到的还是 false，enabled 里还是 true）。
-- 所以这里用事件维护一份状态：Core 在文件加载时就注册，早于所有模块的回调，模块问
-- `ns:InCombat()` 拿到的永远是"派发当拍正确"的值。
local combatState = nil    -- nil = 还没收到过 regen 事件（登录/重载时可能就在战斗中）

--- 现在是否在战斗中。事件派发当拍也正确（见 combatState 注释）；没收到过事件时退回实时标志。
function ns:InCombat()
    if combatState ~= nil then return combatState end
    return (InCombatLockdown and InCombatLockdown()) and true or false
end

ns.EventBus:Register("PLAYER_REGEN_DISABLED", function() combatState = true end)
ns.EventBus:Register("PLAYER_REGEN_ENABLED",  function() combatState = false end)
-- 登录 / 重载时可能已经在战斗里（事件不会补发）：用实时标志定初值。
ns.EventBus:Register("PLAYER_ENTERING_WORLD", function()
    combatState = (InCombatLockdown and InCombatLockdown()) and true or false
end)

local function RunAfterCombat(key, fn)
    local ok, res = pcall(fn)
    if ok and res == false then
        -- fn 自己声明"这次还做不了"（如秘值仍存活）：留队重试，且不算失败 —— 不提示。
        return false
    end
    if ok then
        afterCombatWarned[key] = nil   -- 成跑一次就清提示位，之后再失败重新提示
    elseif not afterCombatWarned[key] then
        afterCombatWarned[key] = true
        ns:Print("AfterCombat '" .. key .. "': " .. tostring(res))
    end
    return ok
end

local function FlushNow()
    -- 动作执行中可能又往队列里加东西：先把整个队列摘走再跑，新排入的落在空表里
    local order, pending = afterCombatOrder, afterCombatPending
    afterCombatOrder, afterCombatPending = {}, {}
    for i = 1, #order do
        local key, fn = order[i], pending[order[i]]
        if fn and not RunAfterCombat(key, fn) then
            afterCombatPending[key] = fn        -- 失败：留队列，下次脱战重试
            afterCombatOrder[#afterCombatOrder + 1] = key
        end
    end
end

local flushTickQueued = false

--- 排空**必须挪一拍**：本客户端先派 PLAYER_REGEN_ENABLED、之后才翻 `InCombatLockdown()`
--- （2026-10-27 实机探针 + harness 断言二 A6 复现：安全头 `SetAttribute`、安全按钮 `SetSize`
--- 在排空当拍照被拒）。`ns:IsRestricted()` 那一拍已经答"自由"（它读事件记的 combatState），
--- 所以**判据拦不住这一刀** —— 只有把动作推到标志翻完之后才真写得进去。Bags 的停车同款做法。
local function FlushAfterCombat()
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        FlushNow()      -- 没有 C_Timer 的客户端：退回原行为（派发当拍做，最多被拒一次）
        return
    end
    if flushTickQueued then return end
    flushTickQueued = true
    C_Timer.After(0, function()
        flushTickQueued = false
        -- 新的一拍里标志已翻，此时再问一次才算数：仍在别的受限窗口（Map / Chat …）
        -- 就整队留着，等解禁事件或下次脱战再排，不硬写。
        if ns.IsRestricted and ns:IsRestricted() then return end
        FlushNow()
    end)
end

-- **在 Core 加载期就注册，不要等第一次排队**：EventBus 按注册序派发，早点注册才能保证
-- 排空早于模块自己挂的 PLAYER_REGEN_ENABLED 处理（旧写法是惰性注册，谁先排一次队就决定了
-- 顺序，等于随机）。注：现在排空本身被推到**下一个 tick**，这条注册序保证的是"队列由 Core
-- 先摘走"，不再保证模块回调跑之前动作已落地 —— 依赖"更早的统一排空"的模块按新序各做各的，
-- 最坏多等一拍。
ns.EventBus:Register("PLAYER_REGEN_ENABLED", FlushAfterCombat)
-- 那个新 tick 若发现还在别的受限窗口里（Map / Chat 一类）会整队留着 —— 没有下一次脱战就永远
-- 没人做。换边事件就是那个"下一次"（Core 自己派发，见下面六类限制那本账）。
ns.EventBus:Register("MONETUI_RESTRICTION_CHANGED", FlushAfterCombat)

function ns:AfterCombat(key, fn, mode)
    if type(key) ~= "string" or type(fn) ~= "function" then return end

    -- 当场能做的条件从"不在战斗中"放宽成"不在任何一类受限窗口里"（见下面 6 类限制）：
    -- Map / Chat 这类限制生效时写入同样会被拒，排到队列里等状态清掉。
    -- 再加一道**原生标志**前置：脱战派发当拍 `IsRestricted()` 已答"自由"，但客户端此刻仍
    -- 锁着（先派事件后翻标志）—— 那一刻当场跑等于替模块写被拒，所以让它排队，由上面
    -- `FlushAfterCombat` 的新 tick 做掉。两处判据必须同源：谁收紧"能不能写"，这里就得跟着收紧，
    -- 否则守卫排队、这边同步重跑 = 互顶成死循环（11-04 实测 962 层爆栈那条）。
    if mode ~= "regen" and not ns:IsRestricted()
        and not (InCombatLockdown and InCombatLockdown()) then
        RunAfterCombat(key, fn)
        return
    end

    if afterCombatPending[key] == nil then
        afterCombatOrder[#afterCombatOrder + 1] = key
    end
    afterCombatPending[key] = fn
end

-- ---- 受限窗口（addon restriction）：本客户端把"什么时候不许插件碰东西"做成 6 类 ------
-- `C_RestrictedActions` 暴露 Combat / Encounter / ChallengeMode / PvPMatch / Map / Chat 六类，
-- 并派发 `ADDON_RESTRICTION_STATE_CHANGED`。文档两条要紧的：事件**在生效之前、解除之后**发
-- （所以 Activating 就该当"已经不自由"处理），且**派发期间 `IsAddOnRestrictionActive` 恒为 false**
-- （所以状态由我们按事件载荷自己记，不在回调里问 API）。
-- 以前本仓只盯 PLAYER_REGEN_*，等于只看 Combat 这一类；Map / Chat 是盲区 —— 实机"某个框突然
-- 读不了、写入被拒"就发生在那些窗口里。客户端没有这套 API 时全部退回战斗标志，行为逐位不变。
local RESTRICTION_ORDER = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }
local restrictionActive = {}
local restrictionKnown = false

local function RestrictedFn(name)
    local api = _G.C_RestrictedActions
    local fn = api and api[name]
    return type(fn) == "function" and fn or nil
end

local function RestrictionValue(kind, name)
    local e = _G.Enum and _G.Enum[kind]
    return e and tonumber(e[name]) or nil
end

local function AnyRestrictionActive()
    for _ in pairs(restrictionActive) do return true end
    return false
end

--- 当前哪几类限制是活的（诊断用：`/mui restrict`）。
--- 第二个返回值 = 这本账是否已经建立（收到过事件、或 PLAYER_ENTERING_WORLD 种子成功）；
--- false 时账本为空**不代表**一切自由，只代表我们还没听过消息。
function ns:Restrictions()
    return restrictionActive, restrictionKnown
end

--- 现在是否处在任何一类受限窗口里 = 战斗中，或六类里任何一类活着。
--- 用来代替散落各处的 `InCombatLockdown()`：那一只管 Combat 这一类。
function ns:IsRestricted()
    if not restrictionKnown then return ns:InCombat() end
    if ns:InCombat() then return true end
    return AnyRestrictionActive()
end

--- 任一禁限类型激活中（含 Activating 等待态，宁可多守一拍）。
--- 这面旗以前由文件末尾那段"事件 → activeTypes"自己记账，消费方是 `MONETUI_RESTRICTION_CHANGED`
--- 的四个订阅（ActionBars / BuffFrame / Nameplates / UnitFrames）；现在六类的账本只留这一本，
--- 旗和事件都由 `NotifyRestriction` 统一推 —— **Utils 比 Core 先加载，所以别人只能订阅这个事件，
--- 不能反过来调 Core 的注册接口**（Widget 的轮询恢复就是这么接的）。
--- 秘值存活窗口**探针测不全**（实机取证：player 的血量是明文、姓名板单位却已在返回机密；
--- 旗与全局级 ShouldAurasBeSecret 全关时 Blizzard 链内仍读到机密）。哪类单位被加密是客户端
--- 自己的事 —— 真正的守则仍是"秘值期不从我们的上下文跑暴雪的生产者"（Nameplates:RestoreBlizzardPlate
--- 不碰 ApplyFrameOptions 那条）。这面旗只做"什么时候该重读"的通用判据，别拿它当探针用。
ns.Restricted = false

local function NotifyRestriction(name, active)
    ns.Restricted = AnyRestrictionActive()
    ns.EventBus:Fire("MONETUI_RESTRICTION_CHANGED", name, active)
end

-- 登录 / 重载时限制可能已经是活的（事件不补发），用实时查询定初值。
local function SeedRestrictions()
    local isActive = RestrictedFn("IsAddOnRestrictionActive")
    if not isActive then return end
    restrictionKnown = true
    for i = 1, #RESTRICTION_ORDER do
        local name = RESTRICTION_ORDER[i]
        local t = RestrictionValue("AddOnRestrictionType", name)
        if t then
            local ok, active = pcall(isActive, t)
            restrictionActive[name] = (ok and active) and true or nil
        end
    end
    ns.Restricted = AnyRestrictionActive()
end

ns.EventBus:Register("ADDON_RESTRICTION_STATE_CHANGED", function(_, typeValue, stateValue)
    local name
    for i = 1, #RESTRICTION_ORDER do
        if RestrictionValue("AddOnRestrictionType", RESTRICTION_ORDER[i]) == typeValue then
            name = RESTRICTION_ORDER[i]
            break
        end
    end
    if not name then return end
    restrictionKnown = true
    local inactiveValue = RestrictionValue("AddOnRestrictionState", "Inactive") or 0
    local active = (stateValue ~= nil) and (stateValue ~= inactiveValue)
    restrictionActive[name] = active and true or nil
    -- 队列排空以前只挂在 PLAYER_REGEN_ENABLED 上：非战斗类限制（Map / Chat）结束时
    -- 也得排一次，否则那些窗口里排入的动作要压到下次脱战。
    if not active and not AnyRestrictionActive() and not ns:InCombat() then
        pcall(FlushAfterCombat)
    end
    NotifyRestriction(name, active)
end)

ns.EventBus:Register("PLAYER_ENTERING_WORLD", SeedRestrictions)

function ns:GetModuleOrder()
    return moduleOrder
end

function ns:HasMonetColor()
    return LMC ~= nil
end

--- The state colour layer (LibMonetColor-Anim-1.0): it turns the player's
--- combat / rest / health state into colours and runs the shared pulse
--- ticker.  nil when the layer is not present (older vendored copy).
function ns:GetAnim()
    if not LMC then return nil end
    return LMC.Anim
end

function ns:IsModuleEnabled(name)
    local value = self:DB().modules[name]
    if value == nil then
        value = DEFAULTS.modules[name] ~= false
    end
    return value and true or false
end

function ns:InitializeModule(name)
    local module = modules[name]
    if not module or module._initialized then return false end

    if module.Initialize then
        local ok, err = pcall(module.Initialize, module)
        if not ok then
            self:Print("模块 " .. name .. " 初始化失败: " .. tostring(err))
            return false
        end
    end

    module._initialized = true
    return true
end

--- Enable/disable a module at runtime (used by the config panel).
function ns:SetModuleEnabled(name, value)
    local module = modules[name]
    if not module then return end

    value = value and true or false
    self:DB().modules[name] = value

    if value then
        self:InitializeModule(name)
    end
    if module.SetEnabled then
        local ok, err = pcall(module.SetEnabled, module, value)
        if not ok then
            self:Print("模块 " .. name .. " 切换失败: " .. tostring(err))
        end
    end

    -- 模块开关会把别处依赖的**具名锚框**藏起来（QuestTracker 关掉只是 Hide，
    -- 全局框还在；Minimap 关掉把 panel SetShown(false)）。只靠各模块自己轮询
    -- 补扫，关掉方向永远等不到「帧出生」那一刻 —— 2026-11-10「关任务追踪后
    -- 背包跑到屏幕边缘」判例。给依赖方一个统一重排时机（回调首参是事件名）。
    ns.EventBus:Fire("MONETUI_MODULE_STATE_CHANGED", name, value)
end

function ns:StartModules()
    if started then return end
    started = true

    if self:DB().enabled == false then
        self:Print("本体已被禁用，输入 |cffffd100/mui enable|r 启用。")
        return
    end

    for _, name in ipairs(moduleOrder) do
        if self:IsModuleEnabled(name) then
            self:InitializeModule(name)
        end
    end

    local count, off = 0, 0
    for _, name in ipairs(moduleOrder) do
        if modules[name]._initialized then
            count = count + 1
        elseif not self:IsModuleEnabled(name) then
            off = off + 1
        end
    end
    -- 分母只算"开着要加载"的模块。旧写法在玩家于设置里关掉一个模块时打成「已加载 19/20」，
    -- 看着就像有模块坏了（11-05 开服实测：Atmosphere 被关 → 接手的人第一反应是找故障）。
    -- 真没初始化起来的模块仍然会让两个数不等，那种才是故障。
    local tail = off > 0 and string.format("（另 %d 个已在设置中关闭）", off) or ""
    self:DevPrint(string.format("已加载 %d/%d 个模块%s。", count, #moduleOrder - off, tail))
end

local function RefreshTheme(reason)
    ns.Color:Refresh()
    ns.EventBus:Fire("MONETUI_THEME_CHANGED", reason)
end
ns.RefreshTheme = RefreshTheme

--- Opt into the engine's "a recompute happened" notification, so a profile switch or an
--- engine-side refresh re-tints every border / bar straight away instead of waiting for
--- the next zone change.
---
--- 2026-11-15（§8.125）：**订阅 OnThemeRefreshed，不是 OnThemeColorsChanged**。后者按 DeltaE
--- 去抖，而 LMC 的 `shouldFireEvent` 比的是 `colorCache[mapID]` 的旧值与**同一张地图**的重算值
--- —— 地图数据表不变时 DeltaE 恒为 0，只有首次进入某地图（oldEntry = nil）才会派发。
--- 玩家回到去过的地图时整条重涂链不跑，表现成「换地图配色不变」；Core 又因为这个回调注册
--- 成功而跳过了下面的 zone 兜底，于是连兜底都没有。OnThemeRefreshed 每趟重算都发，
--- 且与 zone 兜底互斥（hasMonetColorCallback），不会双重重涂。
---
--- LibMonetColor ships with or without CallbackHandler-1.0 and the two expose the registration differently, so the shape is detected rather than assumed and both are pcall'd.  Either way the handler is handed the event name first, which is why it ignores its arguments.  No engine, or no notification, leaves the zone handlers below as the baseline.
local function ReserveMonetColorCallback()
    if not LMC then return false end

    local handler = function() RefreshTheme("monet") end

    -- CallbackHandler style: the method is embedded on the library itself.
    if type(LMC.RegisterCallback) == "function" then
        if pcall(LMC.RegisterCallback, LMC, "OnThemeRefreshed", handler) then
            return true
        end
    end

    -- Built-in fallback registry: the method lives on LMC.events and keys on an arbitrary consumer id.
    local events = LMC.events
    if events and type(events.RegisterCallback) == "function" then
        if pcall(events.RegisterCallback, events, ADDON_NAME, handler) then
            return true
        end
    end

    return false
end

--- True when the engine itself will tell us about colour changes.
ns.hasMonetColorCallback = ReserveMonetColorCallback()

local function PrintStatus()
    local source, profile = ns.Color:GetSource()
    ns:Print(string.format("v%s%s | MonetColor: %s | 主题来源: %s%s | 回调: %s",
        ns.version, ns.dev and " |cffffa940[DEV]|r" or "",
        ns:HasMonetColor() and "|cff00ff00已接入|r" or "|cffff6b6b未找到|r",
        source,
        source == "monet" and ("（" .. tostring(profile) .. "）") or "",
        ns.hasMonetColorCallback and "|cff00ff00已订阅|r" or "|cff808080未订阅|r"))

    for _, name in ipairs(moduleOrder) do
        local module = modules[name]
        local state
        if not ns:IsModuleEnabled(name) then
            state = "|cff808080关闭|r"
        elseif module._initialized then
            state = "|cff00ff00开启|r"
        else
            state = "|cffffd100待机|r"
        end
        ns:Print(string.format("  - %-13s %s", name, state))
    end

    local er, eg, eb = ns.Color:GetEdge()
    ns:Print(string.format("边缘色 |cff%s|r (%.2f, %.2f, %.2f)   %s",
        ns.Math:RGBToHex(er, eg, eb), er, eg, eb, ns.Secrets:Describe()))

    -- Zone sampling: which environment colour drives the theme here.
    local mapID, zoneName, envSource, h, s, l = ns.Color:GetZoneInfo()
    if mapID then
        ns:Print(string.format("区域取色 %s | 地图 %d | HSL %.1f / %.2f / %.2f | 来源: %s",
            zoneName or "未知", mapID, h, s, l, envSource or "?"))
    end
end


local function PrintHelp()
    -- 玩家向命令固定在这里；开发版诊断清单由 ns.DevCommands 追加（发布包不含那层代码）。
    ns:Print("命令：")
    ns:Print("  |cffffd100/mui|r            打开配置面板")
    ns:Print("  |cffffd100/mui status|r     显示模块与主题状态")
    ns:Print("  |cffffd100/mui unlock / lock|r  临时解锁 / 锁定框架位置（默认锁着，防止左键误拖；摆完记得锁回去）")
    ns:Print("  |cffffd100/mui init status|r  启动前置设置：基线 / 聊天框与动作条底边 / 布局状态")
    ns:Print("  |cffffd100/mui init run|r     强制重跑一次聊天框对齐（会另存编辑模式布局）")
    ns:Print("  |cffffd100/mui theme|r      重算当前区域配色并重涂（mapID 查表，不采像素）")
    ns:Print("  |cffffd100/mui enable|r     启用本体")
    ns:Print("  |cffffd100/mui disable|r    禁用本体（需 /reload）")
    ns:Print("  |cffffd100/mui <模块> on|off|r  单独开关模块")
    ns:Print("  |cffffd100/mui infobar currency|r 货币自定义监控：list 看 ID / add|del <ID> / mode / max / zero / panel（右键货币格也能勾）")
    ns:Print("  |cffffd100/mui bags sort|r 整理背包（与「剩余空间」标题行的「整理」钮同一入口）")
    ns:Print("  |cffffd100/mui bags currency on|off|icons on|off|r 「剩余空间」标题行货币显示")
    ns:Print("  |cffffd100/mui groupframes minimap|r 只把团队框贴回小地图左侧（间隔 14、垂直居中；小队保持原位）")
    ns:Print("  |cffffd100/mui groupframes defaults|r 恢复默认位置：小队回屏幕原位，团队贴小地图")
    ns:Print("  |cffffd100/mui whatsnew|r  重看本版要点；/mui tweaks 看控制台优化")
    ns:Print("  |cffffd100/mui reset|r      恢复默认设置（需 /reload）")
    if ns.DevCommands then ns.DevCommands:PrintHelpTail() end
end

-- The UI scale.  Every size in this addon is authored in UI units, so the scale decides
-- whether those sizes land on whole physical pixels: 1 unit = N whole pixels (N an integer)
-- is the only way a 4-unit bar or a 12-unit font has crisp edges.  The resolution decides
-- N (Utils/Media.lua, scalePresets), and the uiScale CVar is the only lever MonetUI has --
-- UIParent's effective scale comes back secret on this client (see Utils/Media.lua Mult).
-- Andromeda reaches the same numbers by scaling UIParent itself (Andromeda/core/uiscale.lua).
--
-- The value we push is remembered: if the player then moves the game's own slider, the CVar
-- no longer matches what we wrote, and MonetUI hands the scale back instead of fighting them.
local function ReadCVar(name)
    local getter = _G.C_CVar and _G.C_CVar.GetCVar or _G.GetCVar
    if not getter then return nil end
    local ok, value = pcall(getter, name)
    if not ok or type(value) ~= "string" then return nil end
    return value
end

local function WriteCVar(name, value)
    local setter = _G.C_CVar and _G.C_CVar.SetCVar or _G.SetCVar
    if not setter then return false end
    local ok = pcall(setter, name, tostring(value))
    return ok and true or false
end

-- Set while we are writing the CVar, so the UI_SCALE_CHANGED the client fires for our own
-- write is not mistaken for the player taking the scale over.
local applyingScale = false

--- Push the pinned scale for the current resolution into the uiScale CVar.
-- @return true when the CVar was changed
local function ApplyAutoScale()
    local db = ns:DB()
    local theme = db.theme or {}
    if theme.uiScaleMode ~= "auto" then return false end

    local height = ns.Media:ScreenHeight()
    local presets = height and ns.Media.scalePresets[height]
    if not presets then
        ns:DevPrint(string.format("UI 缩放：%s 高度不在固定表里，保持游戏自己的设置。", tostring(height)))
        return false
    end

    local current = tonumber(ReadCVar("uiScale"))
    local applied = tonumber(theme.uiScaleApplied)
    if applied and current and math.abs(current - applied) > 0.0001 then
        -- The player moved the game's own slider: hands off from now on.
        theme.uiScaleMode = "game"
        ns:DevPrint("UI 缩放：检测到你自己改过缩放，MonetUI 交还控制权（/mui scale 看当前值）。")
        return false
    end

    -- The CVar only counts when the client's "Use UI Scale" switch is on; with it off the
    -- scale follows the render scale and nothing written here would take effect.
    if ReadCVar("useUIScale") == "0" then
        WriteCVar("useUIScale", "1")
    end

    applyingScale = true
    for _, candidate in ipairs(presets) do
        if not WriteCVar("uiScale", candidate.scale) then break end
        local after = tonumber(ReadCVar("uiScale"))
        if after and math.abs(after - candidate.scale) < 0.0001 then
            theme.uiScaleApplied = candidate.scale
            applyingScale = false
            ns:DevPrint(string.format("UI 缩放：按 %d 高度固定为 %.4f（1 UI 单位 = %d 物理像素）。",
                height, candidate.scale, candidate.pixels))
            return true
        end
        -- Clamped away (the client's UI-scale slider stops at 0.65): try the next candidate.
    end
    applyingScale = false

    ns:DevPrint("UI 缩放：这个客户端不接受固定值（/mui scale 看当前值）。")
    return false
end


--- 发布版拦截表（不是命令实现）：开发版命令层在 Modules/Tools/DevCommands.lua，
--- 发布包不含那层代码，但仍要挡住玩家输入诊断词 —— 否则 `/mui skins diagnose`
--- 会顺着「模块名 + HandleCommand」落到玩家向模块里执行诊断。
--- 玩家向命令（配置 / 模块开关 / 状态 / 主题 / 背包 / 货币 / 团队框 / tweaks /
--- whatsnew / init / reset）一律保留。模块子命令按「模块名 + 首词」精确匹配，
--- 别误伤 `/mui tweaks status` 这类玩家命令。
local DEV_COMMANDS = {
    scale = true, blocks = true, restrict = true, colors = true, lost = true,
    compat = true, perf = true, report = true, devtools = true,
    dev = true, dig = true,
}
local DEV_SUBCOMMANDS = {
    skins       = { diagnose=true, diag=true, probe=true, layers=true, templates=true,
                    closes=true, inset=true, arrows=true },
    infobar     = { diagnose=true, diag=true, probe=true },
    minimap     = { diagnose=true, diag=true, probe=true, menu=true },
    nameplates  = { diagnose=true, diag=true, probe=true, siblings=true, cvars=true },
    tooltip     = { diagnose=true, diag=true, probe=true },
    buffframe   = { probe=true, diag=true, diagnose=true },
    groupframes = { status=true },
}

local function HandleSlash(message)
    local command, rest = string.match(message or "", "^(%S*)%s*(.-)$")
    command = string.lower(command or "")

    -- 开发版命令层（Modules/Tools/DevCommands.lua）只在 dev 包里加载；发布版为 nil。
    if ns.DevCommands and ns.DevCommands:Handle(message) then return end

    -- 发布版：诊断命令整体不可达（帮助里也不列），给一句人话别让输入像被吞掉。
    if not ns.dev then
        local first = string.lower(string.match(rest or "", "^(%S*)") or "")
        local subs = DEV_SUBCOMMANDS[command]
        if DEV_COMMANDS[command] or (subs and subs[first]) then
            ns:Print("这是开发版诊断命令，发布版不提供。输入 |cffffd100/mui|r 查看可用命令。")
            return
        end
    end

    if command == "" or command == "config" or command == "options" then
        if ns.Config and ns.Config.Toggle then
            ns.Config:Toggle()
        else
            ns:Print("配置面板尚未加载。")
        end

    elseif command == "status" then
        PrintStatus()

    elseif command == "unlock" or command == "lock" then
        -- 位置锁（§8.124）：默认锁着，防止左键点着常驻的 player 框把它拖走。两条命令与
        -- 配置面板那枚复选框写的是同一个键（mover.locked）。单组覆盖 mover.locks.* 优先级
        -- 更高，所以状态读 IsLocked("unitframes") 的**实际结果**，别报一个看着锁了其实能拖的值。
        local wantLocked = command == "lock"
        if type(ns.Mover) ~= "table" or type(ns.Mover.SetLocked) ~= "function" then
            ns:Print("位置服务没加载，改不了锁。")
        else
            ns.Mover:SetLocked(nil, wantLocked)
            local locked = ns.Mover:IsLocked("unitframes")
            if locked then
                ns:Print(wantLocked and "框架位置已锁定：左键拖动不再挪动单位框架 / 小队团队框。"
                    or "全局锁已关，但单位框架这一组仍被单独锁着。")
            else
                ns:Print("框架位置已解锁：左键拖动框架即可摆位，松手吸附并记住；"
                    .. "摆完输入 |cffffd100/mui lock|r 锁回去。战斗中受保护框仍不能拖。")
            end
        end

    elseif command == "init" then
        if not (ns.Init and ns.Init.Status) then
            ns:Print("启动前置层没加载：检查 MonetUI.toc 里 Init.lua 是否在 Core.lua 之前。")
        elseif string.lower(rest or "") == "run" then
            ns:DB().init.chatAligned = false
            local _, why = ns.Init:AlignChatBottom(true)
            ns:Print("启动设置：" .. tostring(why))
        else
            ns.Init:Status()
        end

    elseif command == "theme" then
        RefreshTheme("manual")
        local er, eg, eb = ns.Color:GetEdge()
        ns:Print(string.format("主题已刷新：边缘色 #%s (%.2f, %.2f, %.2f)",
            ns.Math:RGBToHex(er, eg, eb), er, eg, eb))

    elseif command == "enable" then
        ns:DB().enabled = true
        ns:Print("已启用，执行 /reload 后生效。")

    elseif command == "disable" then
        ns:DB().enabled = false
        ns:Print("已禁用，执行 /reload 后生效。")

    elseif command == "reset" then
        -- 重置必须**就地清空再补默认值**：以前直接 `_G.MonetUIDB = nil`，之后 ns:DB() 建出来的
        -- 是一张空表、里面没有 modules，面板一开就 `IsModuleEnabled` 抛 index nil
        -- （review 2026-10-29 H7）。而且这是不可撤销的破坏性操作，要二次确认。
        if rest ~= "confirm" then
            ns:Print("这会清空所有 MonetUI 设置。确定请执行：/mui reset confirm")
            return
        end
        local db = ns:DB()
        for key in pairs(db) do db[key] = nil end
        MergeDefaults(db, DEFAULTS)
        db.schema = SCHEMA
        ns:Print("设置已重置为默认值，执行 /reload 后生效。")

    elseif command == "help" then
        PrintHelp()

    else
        local wanted = string.lower(command)
        local moduleName
        for key in pairs(modules) do
            if string.lower(key) == wanted then
                moduleName = key
                break
            end
        end

        if moduleName then
            local module = modules[moduleName]

            if rest == "on" or rest == "1" then
                ns:SetModuleEnabled(moduleName, true)
                ns:Print("模块 " .. moduleName .. " 已开启。")
            elseif rest == "off" or rest == "0" then
                ns:SetModuleEnabled(moduleName, false)
                ns:Print("模块 " .. moduleName .. " 已关闭。")
            else
                -- Modules may expose their own sub-commands (e.g. `/mui skins diagnose`): a handler returns true when it consumed the rest of the line, otherwise fall through to the usage line.
                local handled = false
                if type(module.HandleCommand) == "function" then
                    local ok, result = pcall(module.HandleCommand, module, rest)
                    handled = ok and result and true or false
                end

                if not handled then
                    local usage = "用法：/mui " .. moduleName .. " on|off"
                    -- 发布版不要把诊断子命令写进提示里（帮助文本同理，见 PrintHelp）。
                    if ns.dev and type(module.HandleCommand) == "function" then
                        usage = usage .. "  或  /mui " .. moduleName .. " diagnose"
                    end
                    ns:Print(usage)
                end
            end
        else
            PrintHelp()
        end
    end
end

SLASH_MONETUI1 = "/monetui"
SLASH_MONETUI2 = "/mui"
SlashCmdList["MONETUI"] = HandleSlash

--- 客户端身份一行（加载横幅用）。两个客户端交替验证（零售 12.1.5 / 无限 1.60），帧名、
--- 报错文案和能力位都按版本不同 —— 日志里认不出是哪一版就没法定位。
--- GetBuildInfo 的返回值**位次**按版本不一样（12.1.5 实测第 4 个才是 interface 号），
--- 所以认数不认位：用主/次版本去对 Interface 号的前四位。
function ns:ClientIdentity()
    local rel, iface, build
    if type(_G.GetBuildInfo) == "function" then
        local vals = { pcall(_G.GetBuildInfo) }
        if vals[1] then
            rel = vals[2]
            -- Interface 号在返回值里的**位置**按版本不一样（12.1.5 实测第 4 个才是 120105，
            -- 第 5 个是空串），所以不认位置，认**数**：Interface 号的前四位就是主/次版本。
            local m1, m2 = string.match(tostring(rel), "^(%d+)%.(%d+)")
            local want = m1 and (tonumber(m1) * 100 + tonumber(m2)) or nil
            for i = 3, #vals do
                local v = tonumber(vals[i])
                if v and v > 1000 then
                    if want and math.floor(v / 100) == want then
                        if not iface then iface = v end
                    elseif not build then
                        build = v
                    end
                end
            end
        end
    end
    iface = iface or _G.INTERFACE_VERSION
    return ("%s · build %s · Interface %s"):format(
        tostring(rel or "?"), tostring(build or "?"), tostring(iface or "?"))
end

-- Boot: EventBus owns the only frame; every listener below is registered on it.
local loginThemeReported = false

ns.EventBus:Register("ADDON_LOADED", function(_, addonName)
    if addonName ~= ADDON_NAME then return end
    LoadDatabase()
end)

-- 稀疏落盘（#33）：客户端在 PLAYER_LOGOUT 之后才序列化 MonetUIDB（/reload 与退出都会走这里），
-- 所以在这里就地剥掉等于默认值的键 —— 存下来的就只有玩家改过的 + 位置/账本/schema。
-- 运行期 ns:DB() 已是 MergeDefaults 补满的全量，各模块读取点不受影响；下次登录再 MergeDefaults 补回。
ns.EventBus:Register("PLAYER_LOGOUT", function()
    if type(_G.MonetUIDB) == "table" then
        StripDefaults(_G.MonetUIDB, DEFAULTS)
    end
end)

ns.EventBus:Register("PLAYER_LOGIN", function()
    LoadDatabase()
    -- 主题刷新失败不能让模块永远不启动：以前这里裸调 RefreshTheme，
    -- 抛一次错就停在 StartModules 之前（模块一个都没加载，玩家看到的是"插件没生效"）。
    local okTheme, themeErr = pcall(RefreshTheme, "login")
    if not okTheme and not loginThemeReported then
        loginThemeReported = true
        ns:Print("主题刷新失败（已继续启动模块）：" .. tostring(themeErr))
    end

    -- §8.126：状态染色层（LibMonetColor-Anim-1.0）原本直接读引擎缓存里的 slot 色，
    -- 绕过了 Utils/Color.lua 的亮度阶梯与 §8.123 对比度纠偏 —— 结果换地图时
    -- Widget:Theme 画的边框会跟着变，单位框那几条动态边框却不动。库 1.3.0 起
    -- 支持注入成品色板，这里把 Color:GetTheme() 交给它：provider 每次重绘都会
    -- 被重新调用，所以主题刷新后不需要重新注册。读不到色 / 库是旧副本（没有
    -- 这个 API）时静默跳过，行为与升级前完全一致。
    do
        local Anim = ns:GetAnim()
        if Anim and type(Anim.SetBaseColorProvider) == "function" then
            pcall(Anim.SetBaseColorProvider, Anim, function(key)
                if not ns.Color then return nil end
                local theme = ns.Color:GetTheme()
                local c = theme and theme[key]
                if not c or type(c.r) ~= "number" then return nil end
                -- 库原本对 highlight / neutral 补 alpha 1（引擎只给 RGB），
                -- edge / ambient 用各自色自带的 alpha；沿用同一口径，只换 RGB。
                local a = (key == "highlight" or key == "neutral") and 1 or (c.a or 1)
                return c.r, c.g, c.b, a
            end)
        end
    end

    -- 启动前置层（Init.lua）在放行模块之前把需要的设置统一调整好：静态基线已在
    -- 文件加载期固定，这里等编辑模式布局数据就绪、一次性对齐聊天框，然后才
    -- StartModules —— 各模块拿到的第一份几何就是最终值，不需要运行期反复重贴。
    local function Boot()
        -- Before the modules: every size they build is computed from the scale.
        ApplyAutoScale()
        ns:StartModules()

        ns:Print(string.format("v%s%s 已加载。MonetColor: %s。输入 |cffffd100/mui|r 打开配置。",
            ns.version, ns.dev and " |cffffa940[DEV]|r" or "",
            ns:HasMonetColor() and "|cff00ff00已接入|r" or "|cffff6b6b未找到（使用内置调色板）|r"))
        ns:DevPrint("客户端：" .. ns:ClientIdentity())
    end

    if ns.Init and type(ns.Init.Run) == "function" then
        ns.Init:Run(Boot)
    else
        Boot()
    end
end)

-- The player moved the game's own UI-scale slider: hand the scale back instead of fighting
-- them for it.  Our own write fires this event as well -- applyingScale guards that one.
ns.EventBus:Register("UI_SCALE_CHANGED", function()
    if applyingScale then return end
    local theme = ns:DB().theme or {}
    if theme.uiScaleMode ~= "auto" then return end
    local applied = tonumber(theme.uiScaleApplied)
    local current = tonumber(ReadCVar("uiScale"))
    if applied and current and math.abs(current - applied) > 0.0001 then
        theme.uiScaleMode = "game"
        ns:Print("UI 缩放：检测到你自己改过缩放，MonetUI 交还控制权。")
    end
end)

-- Zone-change fallbacks. When the engine's OnThemeColorsChanged subscription is
-- active it already recomputes on every zone transition and calls RefreshTheme
-- for us, so registering these too would fire MONETUI_THEME_CHANGED twice per
-- change. Keep them only for when the engine is missing or refused the callback
-- (the engine's Delta E debounce still applies in that case, as documented).
if not ns.hasMonetColorCallback then
    ns.EventBus:Register("ZONE_CHANGED",       function() RefreshTheme("zone") end)
    ns.EventBus:Register("ZONE_CHANGED_INDOORS", function() RefreshTheme("zone") end)
    ns.EventBus:Register("ZONE_CHANGED_NEW_AREA", function() RefreshTheme("zone") end)
    ns.EventBus:Register("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
        if not isInitialLogin and not isReloadingUi then
            RefreshTheme("world")
        end
    end)
end

-- Restricted states (combat / PvP) may hide values again, so let modules refresh their
-- text once the restriction lifts —— That re-read is driven by `MONETUI_RESTRICTION_CHANGED`,
-- which the six-class ledger above fires from `NotifyRestriction` (see 受限窗口 near AfterCombat).

_G.MonetUI = ns
