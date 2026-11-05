-- MonetUI Core.lua
-- Entry point: saved settings, module registry & lifecycle, theme plumbing.
-- Every file shares the private namespace table `ns` (the second value of `...`); the Utils files hang off it, Core adds the module registry and exposes it as the global `MonetUI`.

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

ns.name = ADDON_NAME
ns.version = "0.12.0"

local DEFAULTS = {
    enabled = true,
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
    mover = {
        locked    = false,
        locks     = {},
        grid      = 8,
        snap      = true,
        snapRange = 6,
    },
    theme = {
        useMonetColor  = true,
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
            point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 300, y = 0,
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
        -- 地图内的三个独立按钮（3:4 矩形图标）
        mapTracking    = true, -- 追踪（左下）
        mapDifficulty  = true, -- 难度（左上）
        mapCompartment = true, -- 插件收纳（右上）
        microMenu      = true, -- 右键小地图弹出微型游戏菜单
        microMenuSecure = false, -- #43 全量安全载体（12 行代点原生微按钮）；默认关，作者实机验后再开
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
    -- Info bar (信息栏, Modules/InfoBar): one full-width strip along a screen edge carrying small data blocks.  anchorTop pins it to the top edge (so it clears the bottom action bars), height is the strip height (14 fits a 12px font), mouseover keeps the blocks invisible until hovered, combatPulse breathes red in combat / yellow with pending invites, xp draws the experience progress on the bottom hairline (hover the ▲ to read the numbers) and xpFaction hands that same line to the watched reputation at max level; blocks are one switch per data block.
    infobar = {
        anchorTop   = true,
        height      = 14,
        mouseover   = true,
        combatPulse = true,
        xp          = true,
        xpFaction   = true,
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
    self:Print(string.format("已加载 %d/%d 个模块%s。", count, #moduleOrder - off, tail))
end

local function RefreshTheme(reason)
    ns.Color:Refresh()
    ns.EventBus:Fire("MONETUI_THEME_CHANGED", reason)
end
ns.RefreshTheme = RefreshTheme

--- Opt into the engine's own "colours changed" notification, so a profile switch or an engine-side refresh re-tints every border / bar straight away instead of waiting for the next zone change.
-- LibMonetColor ships with or without CallbackHandler-1.0 and the two expose the registration differently, so the shape is detected rather than assumed and both are pcall'd.  Either way the handler is handed the event name first, which is why it ignores its arguments.  No engine, or no notification, leaves the zone handlers below as the baseline.
local function ReserveMonetColorCallback()
    if not LMC then return false end

    local handler = function() RefreshTheme("monet") end

    -- CallbackHandler style: the method is embedded on the library itself.
    if type(LMC.RegisterCallback) == "function" then
        if pcall(LMC.RegisterCallback, LMC, "OnThemeColorsChanged", handler) then
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
    ns:Print(string.format("v%s | MonetColor: %s | 主题来源: %s%s | 回调: %s",
        ns.version,
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

--- 受限窗口自查（`/mui restrict`）：本客户端把"不许插件碰东西"做成六类限制
--- （Combat / Encounter / ChallengeMode / PvPMatch / Map / Chat，`C_RestrictedActions`）。
--- 以前排查只盯着 PLAYER_REGEN_*，等于只看 Combat；这一条用一次就能看清另外五类
--- 在这个构建里到底存不存在、现在哪一类是活的，以及 `canaccessvalue` 这类正规前置可用不可用。
local function PrintRestrictions()
    local api = _G.C_RestrictedActions
    if type(api) ~= "table" then
        ns:Print("这个客户端没有 C_RestrictedActions（退回只看战斗中）。")
    else
        for _, name in ipairs({ "InCombatLockdown", "IsAddOnRestrictionActive",
            "GetAddOnRestrictionState", "CheckAllowProtectedFunctions" }) do
            ns:Print(("  C_RestrictedActions.%s：%s"):format(name, type(api[name]) == "function" and "有" or "没有"))
        end
    end
    local enum = _G.Enum and _G.Enum.AddOnRestrictionType
    ns:Print("  Enum.AddOnRestrictionType：" .. (type(enum) == "table" and "有" or "没有"))
    local tracked, known = ns:Restrictions()
    local live = {}
    for name in pairs(tracked) do live[#live + 1] = name end
    table.sort(live)
    ns:Print(("当前受限：%s（战斗中 %s · IsRestricted %s · 旗帜 %s · 账本 %s）"):format(
        #live > 0 and table.concat(live, " / ") or "无",
        ns:InCombat() and "是" or "否",
        ns:IsRestricted() and "是" or "否",
        ns.Restricted and "有" or "无",
        known and "已建立" or "还没建立（没收到过事件）"))
    -- 逐类对照"我们的账"和"客户端的实时答案"：只有两边不一致才说明事件路径有问题。
    -- 实机踩过一次坑：`当前受限：无` 分不清"真没限制"和"我们压根没记账"。
    local isActive = RestrictedFn("IsAddOnRestrictionActive")
    if isActive and enum then
        for i = 1, #RESTRICTION_ORDER do
            local name = RESTRICTION_ORDER[i]
            local t = enum[name]
            if t ~= nil then
                local ok, on = pcall(isActive, t)
                ns:Print(("  %s：账本 %s / 实时 %s"):format(name,
                    tracked[name] and "活" or "空",
                    (ok and on) and "活" or "空"))
            else
                ns:Print(("  %s：枚举里没有这个值"):format(name))
            end
        end
    end
    local Secrets = ns.Secrets
    if type(Secrets) == "table" and type(Secrets.CanRead) == "function" then
        ns:Print(("  canaccessvalue：%s（没有时 CanRead 退回 not issecretvalue）"):format(
            type(_G.canaccessvalue) == "function" and "有" or "没有"))
    end
    -- 被暂停的轮询框也放在这里看：告警每个框只印一条，聊天很快被 NPC 对话顶掉，
    -- 而这本账（`pausedUntil`）在暂停期间一直有效，随时能重看是谁登记的。
    local Widget = ns.Widget
    if type(Widget) == "table" and type(Widget.PrintStalled) == "function" then
        ns:Print("轮询被暂停的框（forbidden 对象，读不出可见性）：")
        Widget:PrintStalled()
    end
end

--- 拦截归因账本（`/mui blocks`）。AGENTS 的结论：本客户端对 `ADDON_ACTION_BLOCKED`
--- **不写 taint.log**，所以只能认我们自己记的栈 —— `Secrets.Bool()` 的失败路径会逐条存
--- `debugstack`。这一族就是 docs/PLAN-refactor 里那批 `UNKNOWN()`（机密布尔被真值测试）。
--- 只覆盖 `Secrets.Bool`：别的来源（引擎容器 / 半套压制）这里看不到，得走开关式二分。
local function PrintBlockLedger(rest)
    -- 事件处理器抛错也在这本账里露一面：EventBus 每个事件只提示一次、之后静默（不这样会刷屏），
    -- 所以"到底还在不在报"只能靠这里读。
    local function PrintBusErrors()
        local bus = ns.EventBus
        if not bus or type(bus.FailureCounts) ~= "function" then return end
        local counts = bus.FailureCounts()
        local order = {}
        for event in pairs(counts) do order[#order + 1] = event end
        if #order == 0 then return end
        table.sort(order, function(a, b) return counts[a] > counts[b] end)
        ns:Print("事件处理器失败（同一事件只提示一次，其余静默）：")
        for i = 1, #order do
            if i > 8 then
                ns:Print(("  …另有 %d 个事件"):format(#order - 8))
                break
            end
            ns:Print(("  |cffffd100×%d|r %s"):format(counts[order[i]], order[i]))
        end
    end

    if type(ns.Secrets) ~= "table" or type(ns.Secrets.BoolBlocks) ~= "function" then
        ns:Print("这个构建没有 BoolBlocks 账本。")
        PrintBusErrors()
        return
    end
    local blocks, total = ns.Secrets.BoolBlocks()
    if total == 0 or #blocks == 0 then
        ns:Print("|cff88ff88账本为空|r：本会话没有机密布尔被拦的记录。")
        ns:Print("（只统计 `Secrets.Bool` 的失败路径；其它 `UNKNOWN()` 来源要靠关模块二分。）")
        PrintBusErrors()
        return
    end
    local order, groups = {}, {}
    for _, entry in ipairs(blocks) do
        local head = string.match(entry.stack or "?", "[^\r\n]+") or "?"
        if not groups[head] then
            groups[head] = { n = 0 }
            order[#order + 1] = head
        end
        groups[head].n = groups[head].n + 1
    end
    ns:Print(("机密布尔被拦 |cffffa940%d|r 条 · 去重 %d 个调用点："):format(total, #order))
    for i, head in ipairs(order) do
        if i > 8 then
            ns:Print(("  …另有 %d 个调用点（/mui blocks full 看完整栈）"):format(#order - 8))
            break
        end
        ns:Print(("  |cffffd100×%d|r %s"):format(groups[head].n, head))
    end
    if rest == "full" then
        local first = blocks[1]
        ns:Print("最早一条的完整栈：")
        for line in string.gmatch((first and first.stack or "?"), "[^\r\n]+") do
            ns:Print("  " .. line)
        end
    end
    PrintBusErrors()
end

--- 亮度阶梯自查（`/mui colors`）。HANDOFF 8.14.3 的实测：面板（ambient×0.35）和掉血空槽
--- （neutral×0.32）在 14 个区域里对比度只有 1.00–1.19 —— 不是色相选错，是两档亮度重合。
--- 现在这两档都由 Utils/Color.lua 的阶梯按 CIE L* 定死，所以验收只看一个数：CR。
--- 为什么要账本：一行只装得下四档 hex，CR 的四组 + 每组的判定是十几行，聊天框一定被顶掉；
--- 读法同 compatReport —— <游戏目录>/WTF/Account/<账号>/SavedVariables/MonetUI.lua 里的
--- colorReport，而且落盘比 /reload 晚 1–2 分钟。
local COLOR_CR_MIN = 1.4
local COLOR_CR_PAIRS = {
    { key = "panelLost", label = "面板↔空槽" },
    { key = "lostWeave", label = "空槽↔织纹" },
    { key = "lostFill",  label = "空槽↔填充" },
    { key = "panelFill", label = "面板↔填充" },
}

--- 组一份亮度阶梯账本（`/mui colors` 的数据相）：四档色卡、逐组 CR 判定、区域与来源。
--- 只读 Color，不碰 DB、不 print —— 实机第一次跑就是"4/4 过线 + 账本没落成"，
--- 只报"读不到"查不下去，所以组数据和落盘分开，落盘的失败原因要能单独归因。
local function BuildColorReport(su)
    local source, profile = ns.Color:GetSource()
    local mapID, zoneName, envSource = ns.Color:GetZoneInfo()

    -- CR 逐个判定；工具函数缺失时四个数都是 nil，那就直说"退回固定乘数"，不要印 0。
    local checked, passed, rows = 0, 0, {}
    for i = 1, #COLOR_CR_PAIRS do
        local pair = COLOR_CR_PAIRS[i]
        local cr = su.cr and su.cr[pair.key]
        local ok = type(cr) == "number" and cr >= COLOR_CR_MIN
        if type(cr) == "number" then
            checked = checked + 1
            if ok then passed = passed + 1 end
        end
        rows[#rows + 1] = { label = pair.label, cr = cr, ok = ok and true or false }
    end

    -- 副本而非 su 本身：账本要进 SavedVariables，不许和运行期阶梯表共用引用。
    local colors = {}
    for i = 1, #su.keys do
        local c = su[su.keys[i]]
        if c then colors[su.keys[i]] = { r = c.r, g = c.g, b = c.b } end
    end

    return {
        client = ns:ClientIdentity(),
        when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil,
        source = source,
        profile = profile,
        mapID = mapID,
        zone = zoneName,
        envSource = envSource,
        keys = { unpack(su.keys) },
        steps = su.steps,
        levels = su.levels,
        colors = colors,
        cr = su.cr,
        rows = rows,
        min = COLOR_CR_MIN,
        passed = passed,
        checked = checked,
    }
end

--- 账本无条件写：判不过的那一趟恰恰最需要留在 WTF 里看（聊天框那时已经全是红字）。
-- @return saved, why —— why 只在失败时有意义，供 print 归因。
local function SaveColorReport(report)
    local ok, db = pcall(function() return ns:DB() end)
    if not ok then return false, "DB() 抛错：" .. tostring(db) end
    if type(db) ~= "table" then return false, "DB() 返回 " .. type(db) end
    local okSet, errSet = pcall(function() db.colorReport = report end)
    if okSet then return true end
    return false, "写入抛错：" .. tostring(errSet)
end

local function PrintColorLadder()
    local Color = ns.Color
    if type(Color) ~= "table" or type(Color.Surface) ~= "function" then
        ns:Print("Color.Surface 不可用：阶梯层没进去（Utils/Color.lua 是旧的）。")
        return
    end

    local su = Color:Surface()

    -- 每档写成"用这个颜色本身显示的文字"：一眼看出四档的明暗次序，数字是那档的 CIE L*。
    -- 一行只放得下这么多：文字压到"档名 + 一位小数"，颜色靠颜色码自己表观（Compat 的教训是
    -- 一折行，颜色码就会被转义成字面量）。
    local hexes = {}
    for i = 1, #su.keys do
        local key = su.keys[i]
        local c = su[key]
        if c then
            local hex = ns.Math:RGBToHex(c.r, c.g, c.b)
            local l = su.levels and su.levels[key]
            hexes[#hexes + 1] = string.format("|cff%s%s %s|r", hex, key,
                type(l) == "number" and string.format("%.1f", l) or "?")
        end
    end

    local report = BuildColorReport(su)
    ns:Print(string.format("配色阶梯 %s | %s | %s",
        table.concat(hexes, " "),
        report.source == "monet" and ("monet/" .. tostring(report.profile)) or "fallback",
        report.mapID and (tostring(report.zone or "?") .. " " .. tostring(report.mapID) .. " " .. tostring(report.envSource or "?")) or "区域未知"))

    for i = 1, #report.rows do
        local row = report.rows[i]
        if type(row.cr) == "number" then
            ns:Print(string.format("  %s %s%.2f（阈值 %.1f）|r", row.label,
                row.ok and "|cff88ff88" or "|cffff6b6b", row.cr, COLOR_CR_MIN))
        end
    end

    local saved, why = SaveColorReport(report)

    if report.checked == 0 then
        ns:Print("|cffff6b6b没有 ContrastRatio / AtLightness|r：vendored LibMonetColor 早于 1.2.0，阶梯退回旧的固定乘数（观感和升级前一致）。")
        ns:Print("  修法：把 monetcolors 仓库的 LibMonetColor-1.0.lua 同步进 Libs/ 后 /reload。")
        return
    end

    ns:Print(string.format("|cffffd100配色阶梯|r：%d/%d 组过线（阈值 %.1f）%s",
        report.passed, report.checked, COLOR_CR_MIN,
        saved and "；全量已存 MonetUIDB.colorReport（WTF 里可直接读）"
            or ("；|cffff6b6b账本没落成 —— " .. tostring(why) .. "|r")))
end

local function PrintHelp()
    ns:Print("命令：")
    ns:Print("  |cffffd100/mui|r            打开配置面板")
    ns:Print("  |cffffd100/mui status|r     显示模块与主题状态")
    ns:Print("  |cffffd100/mui theme|r      重算当前区域配色并重涂（mapID 查表，不采像素）")
    ns:Print("  |cffffd100/mui scale|r      像素网格 / 缩放自检（改完 UI 缩放后再跑一次对比）")
    ns:Print("  |cffffd100/mui blocks|r     机密布尔被拦的调用栈账本（`UNKNOWN()` 归因，加 full 看完整栈）")
    ns:Print("  |cffffd100/mui restrict|r   六类受限窗口自查（战斗只是其中一类）+ 可读性前置是否可用")
    ns:Print("  |cffffd100/mui colors|r     配色四级亮度阶梯（面板/空槽/织纹/填充）+ 逐组对比度，账本 MonetUIDB.colorReport")
    ns:Print("  |cffffd100/mui lost|r       血条「损失部分」配色自查：样式有没有落地、织纹有没有把颜色盖住")
    ns:Print("  |cffffd100/mui compat|r     客户端能力自查：换客户端第一趟跑它（bad 只看与假设不符的，tmpl 连模板一起探，find <片段> 扫暴雪帧真名）")
    ns:Print("  |cffffd100/mui enable|r     启用本体")
    ns:Print("  |cffffd100/mui disable|r    禁用本体（需 /reload）")
    ns:Print("  |cffffd100/mui <模块> on|off|r  单独开关模块")
    ns:Print("  |cffffd100/mui skins diagnose|r 对象名可达性账本（全仓一本账：skins / nameplates / infobar / minimap）")
    ns:Print("  |cffffd100/mui minimap menu|r 微菜单现场判据：行建不建得出 / 面板受不受保护 / 此刻右键落点（开服日「右键没反应」）")
    ns:Print("  |cffffd100/mui skins diagnose bad|r 只看\"命中但不是框体\"那一类（全量几百行，聊天框装不下）")
    ns:Print("  |cffffd100/mui skins layers <窗口名> [片段]|r 这个窗口的底有几层、每层谁能碰（region / 字段可剥 / 要点名；全量存 MonetUIDB.layerReport）")
    ns:Print("  |cffffd100/mui skins templates [片段]|r 模板库账本：多少个模板 / 映射到 skinAs / Camelot 覆盖；带片段查\"这个控件被认成什么\"")
    -- 上线日验收用的只读探针（一个字节都不写，全量都落 SavedVariables）：
    ns:Print("  |cffffd100/mui perf|r       调度器总账：订阅数 / 逐路耗时排序 / 失败计数 + Lua 内存 + 当前被暂停的轮询框（账本 MonetUIDB.perfReport）")
    ns:Print("  |cffffd100/mui skins closes|r 关闭按钮换皮覆盖面：按图集全量扫，已换皮/仍是暴雪原样/读不出三档（closeReport）")
    ns:Print("  |cffffd100/mui skins inset|r 换皮容器的有效 alpha（父链连乘，不是单点 GetAlpha），α<0.99 全列（insetReport）")
    ns:Print("  |cffffd100/mui skins arrows|r 滚动条/步进器箭头逐对象：旋转角 + UV 翻转 + stepper 属性，用来定左右方向（arrowReport）")
    ns:Print("  |cffffd100/mui buffframe probe|r 只数战斗光环容器的子框个数，不读任何 aura 字段（buffProbe）")
    ns:Print("  |cffffd100/mui nameplates siblings|r 每块牌 base:GetChildren() 的真名 + alpha，判据是名单里有没有 BuffListFrame（nameplateSiblings）")
    ns:Print("  |cffffd100/mui …|r          以上探针全量只进账本：落盘比 /reload 晚 1–2 分钟，登出后读最稳，聊天框只有前几行")
    ns:Print("  |cffffd100/mui reset|r      恢复默认设置（需 /reload）")
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
        ns:Print(string.format("UI 缩放：%s 高度不在固定表里，保持游戏自己的设置。", tostring(height)))
        return false
    end

    local current = tonumber(ReadCVar("uiScale"))
    local applied = tonumber(theme.uiScaleApplied)
    if applied and current and math.abs(current - applied) > 0.0001 then
        -- The player moved the game's own slider: hands off from now on.
        theme.uiScaleMode = "game"
        ns:Print("UI 缩放：检测到你自己改过缩放，MonetUI 交还控制权（/mui scale 看当前值）。")
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
            ns:Print(string.format("UI 缩放：按 %d 高度固定为 %.4f（1 UI 单位 = %d 物理像素）。",
                height, candidate.scale, candidate.pixels))
            return true
        end
        -- Clamped away (the client's UI-scale slider stops at 0.65): try the next candidate.
    end
    applyingScale = false

    ns:Print("UI 缩放：这个客户端不接受固定值（/mui scale 看当前值）。")
    return false
end

-- Pixel-grid / scale report.  Every quantity the border model leans on, in one place, because the
-- two obvious ways of measuring it are both unavailable on this client (see Utils/Media.lua Mult):
-- GetEffectiveScale() comes back secret, and UIParent:GetHeight() stops tracking the screen as soon
-- as another addon resizes UIParent.  What IS readable is the uiScale CVar, which is what we use --
-- so this command is also the way to confirm that path is still returning something sane.
--   Run it, then drag the UI scale slider in the game's settings and run it again: mult must track it.
local function PrintScale()
    local Media = ns.Media
    local raw = (_G.C_CVar and _G.C_CVar.GetCVar) and _G.C_CVar.GetCVar("uiScale") or nil
    local scale = tonumber(raw)
    local mult  = Media:Mult()

    ns:Print("---- 像素网格 / 缩放 ----")
    ns:Print(string.format("uiScale CVar        : %s", tostring(raw)))
    ns:Print(string.format("Mult() = 1/scale    : %.4f UI 单位 / 物理px", mult))
    ns:Print(string.format("  => 1 物理px 需要   : %.4f UI 单位", mult))
    ns:Print(string.format("  => 1 UI 单位 =     : %.3f 物理px", mult > 0 and 1 / mult or 0))

    local theme = ns:DB().theme or {}
    ns:Print(string.format("缩放模式            : %s", theme.uiScaleMode == "auto" and "自动（按分辨率固定）" or "跟随游戏设置"))
    local presetScale, presetPixels = Media:PinnedScale()
    if presetScale then
        ns:Print(string.format("固定值（按分辨率）  : %.4f  ->  1 UI 单位 = %d 物理像素",
            presetScale, presetPixels or 0))
    else
        local h = Media:ScreenHeight()
        ns:Print(string.format("固定值（按分辨率）  : 无（当前高度 %s 不在固定表里）", tostring(h)))
    end

    if _G.GetPhysicalScreenSize then
        local w, h = _G.GetPhysicalScreenSize()
        ns:Print(string.format("物理分辨率         : %d x %d", w or 0, h or 0))
    end
    ns:Print(string.format("逻辑分辨率         : %d x %d", _G.GetScreenWidth and _G.GetScreenWidth() or 0,
                                                _G.GetScreenHeight and _G.GetScreenHeight() or 0))
    if UIParent and UIParent.GetHeight then
        ns:Print(string.format("UIParent:GetHeight(): %.2f UI 单位", UIParent:GetHeight()))
    end

    -- 原生分辨率校验：逻辑分辨率与物理分辨率不等，说明画面在被缩放，"1 物理像素"不是真正的栅格
    local pw, ph = _G.GetPhysicalScreenSize and _G.GetPhysicalScreenSize()
    local lw, lh = _G.GetScreenWidth and _G.GetScreenWidth(), _G.GetScreenHeight and _G.GetScreenHeight()
    if pw and ph and lw and lh and pw > 0 and ph > 0 then
        if lw == pw and lh == ph then
            ns:Print("分辨率            : 原生（栅格 = 物理像素）")
        else
            ns:Print(string.format("分辨率            : 非原生！%dx%d -> %dx%d，栅格比物理像素粗",
                                    lw, lh, pw, ph))
        end
    end
    -- 本客户端没有 C_Console 命名空间（wow-forever-api 索引里只有全局 ConsoleGetAllCommands），
    -- 这里以前用 C_Console.GetAllCommands 当开关，永远为假，那行提示从来没打出来过。
    if type(_G.ConsoleGetAllCommands) == "function" then
        ns:Print("提示：graphicsTextureResolution = "
            .. tostring((_G.C_CVar and _G.C_CVar.GetCVar and _G.C_CVar.GetCVar("graphicsTextureResolution")) or "?")
            .. "（UI 贴图不受它缩放，仅供确认）")
    end

    ns:Print(string.format("示例：thickness=1 的边框 = %.4f UI 单位 = 1 物理px",
                           1 * mult))
    ns:Print(string.format("      thickness=2 的边框 = %.4f UI 单位 = 2 物理px", 2 * mult))
    ns:Print("改动游戏里的 UI 缩放后再跑一次，Mult() 应随之变化。")
end

local function HandleSlash(message)
    local command, rest = string.match(message or "", "^(%S*)%s*(.-)$")
    command = string.lower(command or "")

    if command == "" or command == "config" or command == "options" then
        if ns.Config and ns.Config.Toggle then
            ns.Config:Toggle()
        else
            ns:Print("配置面板尚未加载。")
        end

    elseif command == "status" then
        PrintStatus()

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

    elseif command == "scale" then
        PrintScale()

    elseif command == "blocks" then
        PrintBlockLedger(rest)

    elseif command == "restrict" then
        PrintRestrictions()

    elseif command == "colors" then
        PrintColorLadder()

    elseif command == "lost" then
        -- 血条"损失部分"配色自查：样式有没有落地、织纹有没有把颜色盖住（见 HANDOFF 8.17）。
        local unitFrames = ns:GetModule("UnitFrames")
        if unitFrames and type(unitFrames.DebugLost) == "function" then
            unitFrames:DebugLost()
        else
            ns:Print("单位框模块没加载，读不到血条配色。")
        end

    elseif command == "perf" then
        -- 调度器总账 + Lua 内存 + 当前被暂停的轮询框（只读，见 Modules/Tools/DevTools.lua）。
        local devTools = ns:GetModule("DevTools")
        if devTools and type(devTools.Perf) == "function" then
            devTools:Perf()
        else
            ns:Print("DevTools 探针模块没加载：检查 Modules/Tools/Tools.xml 里有没有 DevTools.lua。")
        end

    elseif command == "compat" then
        local Compat = ns.Compat
        if type(Compat) ~= "table" then
            ns:Print("能力自查没加载：检查 Utils/Utils.xml 里有没有 Compat.lua。")
        else
            local arg = string.lower(rest or "")
            if string.find(arg, "^find") then
                Compat:Find(string.match(arg, "^find%s+(.*)"))
            elseif arg == "caps" then
                -- N4：只报"代码已经问过哪些能力、答案是什么"，不造任何实例（报告命令不许改运行期状态）
                ns:Print("|cffffd100能力表|r（未探测 = 还没人问过；要现探就照常跑 /mui compat）")
                for _, line in ipairs(Compat:ListCapabilities()) do ns:Print("  " .. line) end
            elseif type(Compat.Print) == "function" then
                Compat:Print({ bad = string.find(arg, "bad") ~= nil, tmpl = string.find(arg, "tmpl") ~= nil })
            else
                ns:Print("Compat.Print 不可调用。")
            end
        end

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
                    if type(module.HandleCommand) == "function" then
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
    -- Before the modules: every size they build is computed from the scale.
    ApplyAutoScale()
    ns:StartModules()

    ns:Print(string.format("v%s 已加载。MonetColor: %s。输入 |cffffd100/mui|r 打开配置。",
        ns.version,
        ns:HasMonetColor() and "|cff00ff00已接入|r" or "|cffff6b6b未找到（使用内置调色板）|r"))
    ns:Print("客户端：" .. ns:ClientIdentity())
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
