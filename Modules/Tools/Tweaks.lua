-- Modules/Tools/Tweaks.lua
-- 控制台优化（console tweaks）：把《无限》服流传的一批 `/console` 设置做成逐条开关。
-- 每条 = 一个 CVar + 目标值；打开就写入，关掉还原成玩家原来的值（第一次动它时先存一份原值）。
--
-- 写 CVar 走姓名板模块同一套安全姿势（Modules/Nameplates/Nameplates.lua:89-162）：
-- `C_CVar.GetCVarInfo` 先判 secure / readonly / locked，先读后写、写完复验，失败一次性警告 +
-- 逐条账本。名字在本客户端不存在或被拒写时，只会在账本里落一行 ✗，不报错、不静默空转。
--
-- 名单来自 2026-11-06 的常用优化截图。`nameplateMaxDistance`（姓名板可视距离）已由姓名板模块
-- 负责（Core.lua 的 viewDistance），这里不重复。**默认全关**：这些是画质 / 手感取向的改动，
-- 开哪条是玩家的选择，不是缺省。
--
-- 2026-11-08 作者拍板：另加一层「默认画面快照」—— 把当时调好的整套观感 CVar 设为出厂默认，
-- 每次登录自动对齐。快照只裁决插件不管的 CVar，开着的开关优先级更高（见 AlignVision）。
-- 记录当前画面用 /mui tweaks snapshot，查看 / 停掉自动对齐用 /mui tweaks defaults。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets

local M = { name = "Tweaks" }
ns.Tweaks = M

-- key = 存进 db.tweaks 的开关名；cvar = 客户端控制台变量；value = 打开时写入的目标值（字符串，
-- 和 CVar 的存储形态一致）；label = 面板 / 探针上给玩家看的一句话。
local TWEAKS = {
    { key = "cameraZoom",  cvar = "cameraDistanceMaxZoomFactor",           value = "4", label = "拉远视距（镜头能拉得更高更远）" },
    { key = "lootRange",   cvar = "autoLootRange",                         value = "1", label = "加大自动拾取范围（站远也能拾取掉落）" },
    { key = "combatText",  cvar = "WorldTextScale_v2",                     value = "2", label = "放大伤害数字（打击感更明显）" },
    { key = "questGlow",   cvar = "outlineModeShowLootEffectWhenDisabled", value = "1", label = "任务物品发光（关掉高亮也发光）" },
    { key = "noDeathGray", cvar = "ffxDeath",                              value = "0", label = "复活不灰屏（死亡后屏幕不变灰）" },
    -- 2026-11-07 实测：RenderScale = 1（1:1 像素映射）时这条**完全无效** ——
    -- `ResampleAlwaysSharpen` 只在发生重采样（渲染比例 < 100%）时才起作用，
    -- 玩家实测开/关画面零差异。留着是因为它仍会在「渲染比例拉低」的配置上有用，
    -- 但标签必须说实话，不能让 100% 渲染的人以为开了就更清晰。
    { key = "sharpen",     cvar = "ResampleAlwaysSharpen",                 value = "1", label = "画面锐化（仅渲染比例 <100% 时有效）" },
    { key = "noWeather",   cvar = "weatherDensity",                        value = "0", label = "关闭雨雪天气（画面干净、帧数更稳）" },
    { key = "fewParticles",cvar = "particleDensity",                       value = "0", label = "降低法术粒子" },
    { key = "noFog",       cvar = "volumefog",                             value = "0", label = "去体积雾（远景不蒙灰）" },
}

local function TweakByKey(key)
    for i = 1, #TWEAKS do
        if TWEAKS[i].key == key then return TWEAKS[i] end
    end
    return nil
end

-- 出厂默认「画面快照」（2026-11-08 作者拍板：把当时调好的那套设为默认，登录自动对齐）。
-- 值来自本机 `_forever_/WTF/Config.wtf` 的实盘读数，不是猜的、也不是客户端默认值：
--   Brightness 55 / Contrast 75 / ffxGlow 0 / particleDensity 80 / Gamma 1 /
--   RenderScale 1 / ResampleAlwaysSharpen 1 / ffxDeath 0 / weatherDensity 3 /
--   volumefog 未写 = 默认 1
-- ⚠ Config.wtf 是落盘值，可能比游戏内当前值旧（刚 /console 改过还没写盘）。所以这只是 seed：
--   进游戏敲一次 `/mui tweaks snapshot` 用实机值覆盖，命令会逐条打「旧 → 新」供核对。
--   没证据的条目（ResampleQuality）留空，对齐时跳过，等 snapshot 补 —— 不瞎填一个数。
-- 快照只裁决「插件不管」的 CVar；开关开着的条目一律交给开关，见 AlignVision。
local FACTORY_VISION = {
    gamma                 = "1",
    brightness            = "55",
    contrast              = "75",
    ResampleAlwaysSharpen = "1",
    particleDensity       = "80",
    volumefog             = "1",
    ffxGlow               = "0",
    ffxDeath              = "0",
    weatherDensity        = "3",
}

-- 出厂默认开关组合（同上，来自实盘 MonetUI.lua 的 db.tweaks：5 开 4 关）。
-- 只用于**新存档**（db.tweaks 还不存在时）；老存档已经有玩家显式拨过的开关，一个键都不动。
-- 稀疏存：关着的键不写，IsOn 判 nil 就是关，跟 Core 的 StripDefaults 不冲突（这个表不在 DEFAULTS 里）。
local DEFAULT_SWITCHES = {
    cameraZoom = true, lootRange = false, combatText = true, questGlow = true,
    noDeathGray = true, sharpen = false, noWeather = true,
    fewParticles = false, noFog = false,
}

-- 每个 CVar 一行账，`/mui tweaks status` 读的就是它。
local cvarLedger = {}
local cvarWarned = {}

local function Text(value)
    -- 从游戏拿来的值要进字符串之前再过一次机密判断：`type()` 判不出来（AGENTS 字符串条）。
    if value == nil then return "-" end
    if Secrets.IsSecret(value) then return "机密" end
    return tostring(value)
end

local function CVarRecord(cvar)
    local rec = cvarLedger[cvar]
    if not rec then
        rec = {}
        cvarLedger[cvar] = rec
    end
    return rec
end

local function ReadCVar(cvar)
    local getter = _G.C_CVar and _G.C_CVar.GetCVar or _G.GetCVar
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter, cvar)
    if ok then return value end
    return nil
end

--- @return table|nil { value, default, locked, secure, readonly }；nil = 客户端没答
local function CVarInfo(cvar)
    if not (_G.C_CVar and type(_G.C_CVar.GetCVarInfo) == "function") then return nil end
    local ok, value, default, _, _, locked, secure, readonly = pcall(_G.C_CVar.GetCVarInfo, cvar)
    if not ok then return nil end
    return { value = value, default = default, locked = locked,
             secure = secure, readonly = readonly }
end

-- 原值账：`origin[cvar]` = 第一次动这个 CVar 之前玩家的原值（关回去时用）。
--
-- **必须跨 `/reload` 活着**（2026-11-07 判例）：原值以前只存在运行期局部表里，reload 后
-- 重新采样时读到的是「我们上个会话写进去的值」，于是关掉开关等于把自己写的值再写一遍 ——
-- 玩家看到勾已经取消、画面一点没变（"灰蒙蒙关不掉"就是这么来的）。
-- 现在落库到 `db.tweakOrigin`，一个 CVar 一条。
local function OriginStore()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.tweakOrigin) ~= "table" then db.tweakOrigin = {} end
    return db.tweakOrigin
end

--- 没记过原值时的兜底：用客户端默认值。
--- 只在玩家显式要求还原（`/mui tweaks restore`）时用，不在 Apply 里自动套 ——
--- 玩家若真自己设过目标值，自动改成默认值就是误伤。
local function DefaultOf(cvar)
    local info = CVarInfo(cvar)
    if info and info.default ~= nil then
        local d = tostring(info.default)
        if d ~= "" then return d end
    end
    return nil
end

--- 同一个 CVar 只印一条（失败一次性警告，不刷屏）；细账在 status 里随时能重看。
local function CVarFlag(cvar, note)
    local rec = CVarRecord(cvar)
    rec.note = note
    if not cvarWarned[cvar] then
        cvarWarned[cvar] = true
        ns:Print(("|cffffa940控制台优化空转|r：%s —— %s（期望 %s）")
            :format(cvar, note, Text(rec.want)))
    end
end

--- @return boolean 写进去了 / 本来就是那个值
local function WriteCVar(cvar, value)
    if value == nil then return false end
    local want = tostring(value)
    local info = CVarInfo(cvar)
    local cur = (info and info.value) or ReadCVar(cvar)
    local rec = CVarRecord(cvar)
    rec.want, rec.got = want, cur

    -- 两个 getter 都答 nil ⇒ 本客户端没这个 CVar（名字错 / 不存在）。不拦的话会一路走到
    -- SetCVar（不报错）+ 复验读回 nil（不是 string，旧判据放过）⇒ 假记"已写"。
    -- 实机判例 1.60：autoLootRange 不存在，旧版就把它记成了"已写"。
    if cur == nil and (not info or info.value == nil) then
        CVarFlag(cvar, "本客户端没有这个 CVar（名字不存在）")
        return false
    end

    -- 先读后写：常态下值没变就不该落一笔。
    if type(cur) == "string" and not Secrets.IsSecret(cur) and cur == want then
        rec.note = "已是"
        return true
    end

    if info and (info.secure or info.readonly or info.locked) then
        CVarFlag(cvar, info.secure and "客户端拒写（isSecure，插件无权改）"
                       or info.readonly and "只读（isReadOnly）"
                       or "玩家已锁定（isLockedFromUser）")
        return false
    end

    local setter = _G.C_CVar and _G.C_CVar.SetCVar or _G.SetCVar
    if type(setter) ~= "function" then return false end
    local ok, err = pcall(setter, cvar, want)
    if not ok then
        CVarFlag(cvar, "写入被拒：" .. Text(err))
        return false
    end

    -- 不报错不等于写进去了：secure / read-only 可能"静默收下、值不动"。复验一次。
    local after = ReadCVar(cvar)
    if after == nil then
        CVarFlag(cvar, "写了复验读不到（值没落地）")
        return false
    end
    if type(after) == "string" and not Secrets.IsSecret(after) and after ~= want then
        CVarFlag(cvar, "写了没生效（复验仍是 " .. Text(after) .. "）")
        return false
    end
    rec.note = "已写"
    return true
end

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.tweaks) ~= "table" then
        db.tweaks = {}
        -- 新存档铺一遍出厂开关组合；老存档原样保留（玩家自己拨过的不许被默认顶回去）。
        for k, v in pairs(DEFAULT_SWITCHES) do
            if v then db.tweaks[k] = true end
        end
    end
    return db.tweaks
end

--- 给设置面板用：逐条清单（key / cvar / value / label）。
function M:Tweaks()
    return TWEAKS
end

function M:IsOn(key)
    return self:Settings()[key] and true or false
end

--- 还原单条（`set <key> 0` / `restore` / `all 0` 走的就是它）。
--- 两档：有账 → 玩家原值；没账（旧版遗留）→ 只在「当前值 == 我们的目标值、且 ≠ 客户端默认值」
--- 时推回默认值，绝不碰玩家自己设的值（他设 55，既非目标也非默认，一个字节不动）。
---
--- **为什么不并进 Apply 的逐条循环**（2026-11-07 判例）：Apply 每次都会遍历九条，
--- 若关着的条目也走「没账就推默认值」这档，玩家自己把 volumefog 设成 0 之后，
--- 只是去开另一条开关，就会被顺手改成 1 —— 这不是还原，是误伤。
--- 所以兜底只在**玩家显式关这一条**时发生。
--- @return string|nil before, string|nil after
local function RestoreOne(t)
    local origin = OriginStore()
    local before = ReadCVar(t.cvar)
    local back = origin[t.cvar]
    if back ~= nil then
        WriteCVar(t.cvar, back)
        origin[t.cvar] = nil
    elseif before ~= nil and not Secrets.IsSecret(before) then
        local def = DefaultOf(t.cvar)
        if def ~= nil
            and tostring(before) == tostring(t.value)
            and tostring(def) ~= tostring(t.value) then
            WriteCVar(t.cvar, def)
        end
    end
    return before, ReadCVar(t.cvar)
end

--- 逐条对齐：开的写入目标值（先存原值），关的若之前写过就还原成原值。
function M:Apply()
    local origin = OriginStore()
    for i = 1, #TWEAKS do
        local t = TWEAKS[i]
        if self:IsOn(t.key) then
            if origin[t.cvar] == nil then origin[t.cvar] = ReadCVar(t.cvar) end
            WriteCVar(t.cvar, t.value)
        elseif origin[t.cvar] ~= nil then
            local cur = ReadCVar(t.cvar)
            if cur == nil then
                -- 读不到值，这条账没有意义
                origin[t.cvar] = nil
            elseif tostring(cur) == tostring(t.value) then
                -- 值还是我们写进去的 → 还原成玩家的原值
                WriteCVar(t.cvar, origin[t.cvar])
                origin[t.cvar] = nil
            else
                -- 玩家中途自己改过：不抢他的值，只清账
                origin[t.cvar] = nil
            end
        end
    end
end

--- 关掉整个模块 / `/mui tweaks all 0`：九条全部走 RestoreOne。
function M:RestoreAll()
    for i = 1, #TWEAKS do
        RestoreOne(TWEAKS[i])
    end
end

--- `/mui tweaks restore`：九条全部推回原值；没记账的用客户端默认值。
--- 这是「画面调不回来」时的最后一道 —— 旧版没记账、值却被写过的那批，只有这条能救。
--- @return number 实际写成功的条数
function M:RestoreToDefault()
    local origin = OriginStore()
    local n = 0
    for i = 1, #TWEAKS do
        local t = TWEAKS[i]
        local back = origin[t.cvar] or DefaultOf(t.cvar)
        if back ~= nil then
            if WriteCVar(t.cvar, back) then n = n + 1 end
            origin[t.cvar] = nil
        end
    end
    return n
end

function M:Initialize()
    self:Apply()

    -- 历史遗留检查（2026-11-07 判例）：开关是关的、账上没有原值，值却还是我们的目标值 ——
    -- 旧版把原值只存在运行期，reload 后"还原"还原到自己写的值，于是这个状态会一直留着。
    -- 不自动改（玩家可能自己就喜欢那个值），只点名 + 给一条命令。
    local origin = OriginStore()
    local stuck = {}
    for i = 1, #TWEAKS do
        local t = TWEAKS[i]
        if not self:IsOn(t.key) and origin[t.cvar] == nil then
            local cur = ReadCVar(t.cvar)
            local def = DefaultOf(t.cvar)
            if cur ~= nil and def ~= nil
                and tostring(cur) == tostring(t.value)
                and tostring(def) ~= tostring(t.value) then
                stuck[#stuck + 1] = t.cvar
            end
        end
    end
    if #stuck > 0 then
        ns:Print(("|cffffa940控制台优化：%d 条开关是关的，值却还留在打开时的状态|r（%s）")
            :format(#stuck, table.concat(stuck, ", ")))
        ns:Print("  旧版没把原值记下来造成的。一条命令全推回去：/mui tweaks restore")
    end

    -- 默认画面对齐放在最后（2026-11-08）：
    -- ① 必须在 Apply 之后 —— 开着的开关才会赢过快照；
    -- ② 必须在 stuck 检查之后 —— 否则快照把值一写，这条诊断就被自己抹掉了
    --    （「开关关但值没还原」是查灰屏的关键信号，不能因为加了默认就看不见）。
    -- AlignVision 定义在文件后半，这里走 self: 表查找：chunk 整份加载完才轮到 Initialize，
    -- 不会踩「引用了还没声明的 local」那种静默失效。
    self:AlignVision()
end

function M:SetEnabled(value)
    if value then
        self:Apply()
    else
        self:RestoreAll()
    end
end

--- 「画面整体发灰 / 发白」这一类观感问题，能改它的 CVar 就这几个（2026-11-07 排查用）。
--- 只有前三条是本模块会写的；其余是玩家自己或在设置里可能被动过的，一起列出来才能对照。
--- `note` 写的是「偏离默认后往哪个方向变」，判读时不至于看数字猜。
local VISION = {
    { cvar = "gamma",                 key = nil,            note = "伽马：>1 = 整体提亮发白，暗部被拉起来 → 「灰蒙蒙」的头号嫌疑" },
    { cvar = "brightness",            key = nil,            note = "亮度：调太高会让整屏发白、黑变灰" },
    { cvar = "contrast",              key = nil,            note = "对比度：偏低 = 黑的不黑、画面糊成一片灰" },
    { cvar = "ResampleAlwaysSharpen", key = "sharpen",      note = "强制锐化重采样：只在渲染比例 <100%（发生重采样）时起作用；100% 下开关无差异" },
    { cvar = "particleDensity",       key = "fewParticles", note = "粒子密度：0 = 光效/尘埃/萤火全灭，画面发平" },
    { cvar = "volumefog",             key = "noFog",        note = "体积雾：关掉失去大气透视，远景发平" },
    { cvar = "ffxGlow",               key = nil,            note = "全屏泛光：关掉亮部不再溢光，画面发闷发灰" },
    { cvar = "ffxDeath",              key = "noDeathGray",  note = "死亡灰度（0 = 复活不灰屏）" },
    { cvar = "weatherDensity",        key = "noWeather",    note = "天气密度（0 = 无雨雪）" },
    { cvar = "ResampleQuality",       key = nil,            note = "重采样质量：偏低 = 放大糊" },
}

--- key → 我们为它写的目标值（判「这条值是不是我们写的」用）。
local function TweakValue(key)
    for i = 1, #TWEAKS do
        if TWEAKS[i].key == key then return TWEAKS[i].value end
    end
    return nil
end

--- 画面观感诊断：当前值 vs 客户端默认值，偏离的标出来，并指出哪几条是本插件写的。
--- 只读，不改任何 CVar（报告命令不许有副作用）。
--- 值比较：两边都能当数字看就按数字比。
--- 客户端把 default 给成 number 时是 `0.5`，给成 string 时是 `"0.500000"` —— 直接 tostring
--- 比会把这两个判成「偏离默认」，于是 brightness / contrast / gamma 这类浮点 CVar 永远
--- 假报偏离（2026-11-07：vision 探针在数字型 default 形态下报 9 条，真值 7 条）。
local function SameValue(a, b)
    if a == nil or b == nil then return false end
    local na, nb = tonumber(tostring(a)), tonumber(tostring(b))
    if na ~= nil and nb ~= nil then return na == nb end
    return tostring(a) == tostring(b)
end

--- 默认画面快照的存档（`db.tweakDefaults`）。
--- **不进 Core.DEFAULTS**：那样 StripDefaults 会在落盘前把「等于默认值」的键删掉，
--- 而且改出厂值得 bump schema + Migrate 才能传给老玩家。这里自己管：缺什么补什么，
--- 玩家用 `/mui tweaks snapshot` 覆盖后就以他的为准。
--- @return table { vision = { [cvar]=value }, switches = {...}, auto = boolean }
local function VisionStore()
    local db = ns:DB()
    if type(db) ~= "table" then return { vision = {}, auto = true } end
    if type(db.tweakDefaults) ~= "table" then db.tweakDefaults = {} end
    local store = db.tweakDefaults
    if type(store.vision) ~= "table" then
        store.vision = {}
        for k, v in pairs(FACTORY_VISION) do store.vision[k] = v end
    end
    if store.auto == nil then store.auto = true end  -- 作者拍板：登录自动对齐
    return store
end

--- 登录自动对齐：把快照写回「插件不管」的 CVar。
---
--- 两条纪律（2026-11-08）：
--- ① 顺序在 Apply() **之后** —— Apply 会按开关写目标值 / 还原原值，快照最后裁决。
---    反过来（快照先、Apply 后）玩家拨开关那一拍会被 Apply 顶掉，开关看起来失灵。
--- ② **跳过开关开着的条目** —— 那是玩家显式表达的画面取向，快照不许抢。
---    否则 noWeather 开着写 0、快照又要 3，每次登录两边各写一次，谁赢全看顺序。
--- 只写确实不同的值；零写入不打印，避免每次登录刷一行。
--- @param quiet boolean|nil true = 不打印汇总（命令里自己打）
--- @param force boolean|nil true = 忽略 auto 开关（`/mui tweaks defaults apply` 用）
--- @return number 实际写入条数, number 由开关接管的条数
function M:AlignVision(quiet, force)
    local store = VisionStore()
    if store.auto == false and not force then return 0, 0 end
    local snap = store.vision
    local wrote, skipped = 0, 0
    for i = 1, #VISION do
        local v = VISION[i]
        if v.key and self:IsOn(v.key) then
            skipped = skipped + 1
        else
            local want = snap[v.cvar]
            if want ~= nil then
                local cur = ReadCVar(v.cvar)
                -- 读不到 / 是机密值就跳过：不比较、不写，也不让 WriteCVar 落一笔"空转"警告。
                if cur ~= nil and not Secrets.IsSecret(cur) and not SameValue(cur, want) then
                    if WriteCVar(v.cvar, want) then wrote = wrote + 1 end
                end
            end
        end
    end
    if not quiet and wrote > 0 then
        ns:Print(("|cff00ff00默认画面对齐|r：写入 %d 条（另有 %d 条由开着的开关接管）。")
            :format(wrote, skipped))
        ns:Print("  想把新画面留作默认：/mui tweaks snapshot　｜　不想自动对齐：/mui tweaks defaults off")
    end
    return wrote, skipped
end

function M:Vision()
    ns:Print("|cffffd100画面观感诊断|r（当前值 vs 客户端默认值，只读）")

    local deviated, ours, stuck = 0, 0, 0
    -- 偏离默认、又不归我们管的条目：末尾直接给可抄的 /console 行。
    -- 报告命令本身仍然只读（不改 CVar），只是把「照着敲什么」算给玩家看。
    local fixes = {}
    for i = 1, #VISION do
        local v = VISION[i]
        local info = CVarInfo(v.cvar)
        local cur = (info and info.value) or ReadCVar(v.cvar)
        if cur == nil then
            ns:Print(("  %-22s 本客户端没有这个 CVar"):format(v.cvar))
        else
            local diff = ""
            if info and info.default ~= nil then
                local d = tostring(info.default)
                if not SameValue(cur, info.default) then
                    deviated = deviated + 1
                    diff = "  默认 " .. d
                end
            end

            -- 归属三态。中间那一档是 2026-11-07 判例：开关已关、值却还是我们的目标值
            -- （旧版原值只存运行期，reload 后"还原"还原到自己写的值）。以前这里打
            -- 「不是本插件」，等于把真问题盖住了 —— 玩家会觉得"关了没用，不是它"。
            local state, isOurs, isStuck
            if v.key then
                local want = TweakValue(v.key)
                local looksWritten = want ~= nil and SameValue(cur, want)
                if M:IsOn(v.key) then
                    state, isOurs = "|cff00ff00本插件写|r", true
                    ours = ours + 1
                elseif looksWritten then
                    state, isStuck = "|cffffa940已关·值没还原|r", true
                    stuck = stuck + 1
                else
                    state = "|cff808080不是本插件|r"
                end
            else
                state = "|cff808080不是本插件|r"
            end

            ns:Print(("  %-22s 当前 %-6s %s%s"):format(v.cvar, Text(cur), state, diff))
            if diff ~= "" then
                ns:Print("      └ " .. v.note)
                -- 只给「不归我们管」的条目出 /console：我们写的那些由开关负责，
                -- 已关没还原的由 restore 负责，混进去只会互相打架。
                if not isOurs and not isStuck and info and info.default ~= nil then
                    fixes[#fixes + 1] = { v.cvar, tostring(info.default) }
                end
            end
        end
    end

    -- 渲染比例：锐化重采样的影响完全取决于它。1:1 时锐化本该没有意义，低于 1 就是
    -- 「先缩小再锐化放大」，最容易看出灰和脏。
    local scale = ReadCVar("RenderScale")
    if scale ~= nil then
        local lo, hi = "?", "?"
        if type(_G.GetMinRenderScale) == "function" then
            local ok, a = pcall(_G.GetMinRenderScale)
            if ok then lo = tostring(a) end
        end
        if type(_G.GetMaxRenderScale) == "function" then
            local ok, b = pcall(_G.GetMaxRenderScale)
            if ok then hi = tostring(b) end
        end
        ns:Print(("  %-22s 当前 %-6s 范围 %s–%s"):format("RenderScale", Text(scale), lo, hi))
    end

    local atmo = ns:GetModule("Atmosphere")
    if atmo then
        local on = ns:IsModuleEnabled("Atmosphere")
        ns:Print(("  %-22s %s｜强度 %.2f｜只压四周，中心不压"):format(
            "氛围暗角", on and "|cff00ff00开|r" or "|cff808080关|r", atmo:Tier().alpha))
    end

    ns:Print(("判读：偏离默认 %d 条，其中本插件写的 %d 条。"):format(deviated, ours))
    if stuck > 0 then
        ns:Print(("  |cffffa940注意：%d 条开关已关，但值还是我们的目标值 —— 那次关闭没有还原成功。|r"):format(stuck))
        ns:Print("  一条命令全推回去：/mui tweaks restore")
    end
    if ours > 0 then
        ns:Print("  逐条关着试（即时生效，不用 reload）：/mui tweaks set <key> 0 —— 会打出「值 A → B」，值没变就是这条本来没生效")
        ns:Print("  全关：/mui tweaks all 0　｜　全推回原值：/mui tweaks restore")
    end
    if #fixes > 0 then
        ns:Print(("  另有 %d 条不是本插件写的，想回默认照着敲（即时生效，不用 reload）："):format(#fixes))
        local cap = #fixes < 6 and #fixes or 6
        for i = 1, cap do
            ns:Print(("    /console %s %s"):format(fixes[i][1], fixes[i][2]))
        end
        if #fixes > cap then
            ns:Print(("    …另有 %d 条，见上面标「偏离」的行"):format(#fixes - cap))
        end
    end
end

--- `/mui tweaks status` —— 逐条读账本：开关、目标值、当前值、写没写成。
--- `/mui tweaks set <key> 1|0` —— 不开面板逐条换，方便对着截图点名。
function M:HandleCommand(rest)
    local arg, value = string.match(rest or "", "^(%a+)%s*(.*)$")

    if arg == "restore" then
        local n = self:RestoreToDefault()
        ns:Print(("已把控制台优化全部推回原值（%d 条写成功）。"):format(n))
        ns:Print("  记过原值的还原成你原来的值；没记账的（旧版写过的）还原成客户端默认值。")
        ns:Print("  再跑 /mui tweaks vision 对照一眼。")
        ns:Print("  |cffffa940注意|r：登录自动对齐开着的话，/reload 后会按默认快照写回；要彻底停掉 /mui tweaks defaults off")
        return true
    end

    if arg == "all" then
        local flag = string.match(value or "", "^(%S+)$")
        local on = (flag == "1" or flag == "on" or flag == "true")
        if flag == nil then
            ns:Print("用法：/mui tweaks all 1|0")
            return true
        end
        for i = 1, #TWEAKS do
            self:Settings()[TWEAKS[i].key] = on
        end
        if on then self:Apply() else self:RestoreAll() end
        ns:Print(on and "控制台优化：九条全部打开。" or "控制台优化：九条全部关闭并还原。")
        return true
    end

    if arg == "vision" then
        self:Vision()
        return true
    end

    if arg == "snapshot" then
        local store = VisionStore()
        local old = store.vision or {}
        local nextSnap, n, changed = {}, 0, 0
        ns:Print("|cffffd100把当前画面记为默认|r（实机采样，逐条核对出厂值）")
        for i = 1, #VISION do
            local cvar = VISION[i].cvar
            local cur = ReadCVar(cvar)
            if cur == nil or Secrets.IsSecret(cur) then
                ns:Print(("  %-22s 读不到（本客户端没有 / 是机密），跳过"):format(cvar))
            else
                local s = tostring(cur)
                nextSnap[cvar] = s
                n = n + 1
                local prev = old[cvar]
                local same = prev ~= nil and SameValue(prev, s)
                if not same then changed = changed + 1 end
                ns:Print(("  %-22s %-8s → %-8s %s"):format(
                    cvar, prev or "未采样", s, same and "相同" or "更新"))
            end
        end
        store.vision = nextSnap
        store.switches = {}
        for i = 1, #TWEAKS do
            store.switches[TWEAKS[i].key] = self:IsOn(TWEAKS[i].key)
        end
        ns:Print(("已记下 %d 条（其中 %d 条与出厂快照不同）。"):format(n, changed))
        ns:Print("  登录自动对齐：" .. (store.auto ~= false
            and "|cff00ff00开|r" or "|cff808080关|r（/mui tweaks defaults on 打开）"))
        -- 开关开着的条目不受快照管辖，得说清楚，否则玩家会以为快照没生效。
        for i = 1, #VISION do
            local v = VISION[i]
            if v.key and self:IsOn(v.key) then
                ns:Print(("  |cffffa940注意|r：%s 由开着的开关 %s 接管，快照值不参与对齐；想让它生效就 /mui tweaks set %s 0")
                    :format(v.cvar, v.key, v.key))
            end
        end
        ns:Print("  查看：/mui tweaks defaults　｜　停掉自动对齐：/mui tweaks defaults off")
        return true
    end

    if arg == "defaults" then
        local flag = string.match(value or "", "^(%S+)$")
        local store = VisionStore()
        if flag == "on" or flag == "1" or flag == "off" or flag == "0" then
            store.auto = (flag == "on" or flag == "1")
            ns:Print(("默认画面：登录自动对齐已%s"):format(
                store.auto and "|cff00ff00打开|r" or "|cff808080关闭|r"))
            ns:Print(store.auto
                and "  之后每次 /reload 会按快照写回；手动改的画面设置会被顶回去。"
                or "  之后登录不再写任何 CVar，画面交给客户端自己持久化。")
            return true
        end
        if flag == "apply" then
            local w, s = self:AlignVision(true, true)
            ns:Print(("已按默认画面对齐：写入 %d 条，跳过 %d 条（开着的开关接管）。"):format(w, s))
            return true
        end
        ns:Print("|cffffd100默认画面快照|r（登录自动对齐：" ..
            (store.auto ~= false and "|cff00ff00开|r" or "|cff808080关|r") .. "）")
        for i = 1, #VISION do
            local v = VISION[i]
            local want = store.vision[v.cvar]
            local owned = v.key and self:IsOn(v.key)
            ns:Print(("  %-22s 默认 %-8s %s"):format(
                v.cvar, want or "未采样",
                owned and ("|cffffa940由开关 " .. v.key .. " 接管|r") or "|cff00ff00快照对齐|r"))
        end
        if type(store.switches) == "table" then
            local on = {}
            for i = 1, #TWEAKS do
                if store.switches[TWEAKS[i].key] then on[#on + 1] = TWEAKS[i].key end
            end
            ns:Print("  记快照时的开关：" .. (#on > 0 and table.concat(on, ", ") or "全关"))
        end
        ns:Print("  改这套值：/mui tweaks snapshot（实机重采）　｜　立刻应用：/mui tweaks defaults apply")
        ns:Print("  自动对齐开关：/mui tweaks defaults on|off")
        return true
    end

    if not arg or arg == "status" then
        ns:Print("控制台优化（开=写入，关=还原你原来的值）：")
        for i = 1, #TWEAKS do
            local t = TWEAKS[i]
            local on = self:IsOn(t.key) and "|cff00ff00开|r" or "|cff808080关|r"
            local rec = cvarLedger[t.cvar] or {}
            ns:Print(("  %s %-12s %s｜当前 %s｜%s"):format(
                on, t.key, t.cvar, Text(rec.got), rec.note or "-"))
        end
        ns:Print("开关：/mui tweaks set <key> 1|0（如 /mui tweaks set noFog 1）")
        ns:Print("画面发灰/发白：/mui tweaks vision（当前值 vs 默认值，只读）")
        ns:Print("默认画面：/mui tweaks defaults　｜　把当前画面记为默认：/mui tweaks snapshot")
        return true
    end

    if arg == "set" then
        local key, flag = string.match(value or "", "^(%S+)%s+(%S+)$")
        local t = key and TweakByKey(key)
        if not t then
            ns:Print("没有这一条：" .. tostring(key) .. "（用 /mui tweaks status 看清单）")
            return true
        end
        local on = (flag == "1" or flag == "on" or flag == "true")
        local before = ReadCVar(t.cvar)
        self:Settings()[t.key] = on
        if on then
            self:Apply()
        else
            -- 关：先按这一条显式还原（含「旧版遗留、账上没有」的兜底），再跑一遍全量对齐。
            RestoreOne(t)
            self:Apply()
        end
        -- 打印**写前 / 写后**的实际值：以前只打「已关」，玩家无从判断到底写没写进去。
        -- 2026-11-07 判例：这一条在账上没记录时 Apply 会整条跳过，命令照样回「已关」，
        -- 画面一点没变 —— 玩家只会以为「这个开关没用」。值一打出来就无处可藏。
        local after = ReadCVar(t.cvar)
        ns:Print(("%s：%s｜%s　值 %s → %s"):format(
            t.label, on and "已开" or "已关", t.cvar, Text(before), Text(after)))
        if Text(before) == Text(after) then
            if on then
                ns:Print("  值没变 —— 本来就是这个值，或者写入被客户端拒了（/mui tweaks status 看账本）。")
            else
                ns:Print("  值没变 —— 本来就在你的原值上，这一条没有需要还原的东西。")
            end
        end
        return true
    end

    return false
end

ns:Register("Tweaks", M)
