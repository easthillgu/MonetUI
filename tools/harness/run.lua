-- tools/harness/run.lua
-- 离线 harness 的驱动：按 MonetUI.toc + 各 *.xml 的真实顺序把插件**跑起来**，
-- 然后在六种受限窗口里执行所有刷新路径，边跑边让 api_stub.lua 记账。
--
-- 五类断言分别落在：
--   一  加载期 + 首次 Apply（ADDON_LOADED / PLAYER_LOGIN / PLAYER_ENTERING_WORLD）：
--      编译错、运行时抛错、被 pcall 吞掉后 print 出来的失败，全记 A0 / A0p / L 红。
--   二  六类受限窗口 × 全部刷新路径：未被守卫就写暴雪对象 = A2 红（自己 pcall 包住的记 guarded，不算红）。
--   三  往暴雪对象直接写字段 / HookScript / hooksecurefunc = A3 / A3h 红（stub 里记）。
--   四  α 继承体检：被我们挂过背板的容器，**动画收敛后**有效 α 必须 > 0 = A4 红；
--       中途各阶段的 α0 多是逐拍逼近的中间态（InfoBar 呼吸、Toast 淡入），只记 A4t 黄。
--   四b 受限写入被继承型保护（A2i）打断的脚本记 A0b 黄：一条离线没有判据的猜测不配两条红。
--   五  Skin:Need 的命中 / 缺席台账 → 离线 ✗ 清单 = 上线首日目标清单（A5，不算 FAIL）。
--
-- 这一层不改任何发行代码：只读文件、只往沙箱 env 里灌东西。

local ADDON_NAME = "MonetUI"

local Run = {}

---------------------------------------------------------------- 小工具
local function slash(p) return (tostring(p):gsub("\\", "/")) end
local function dirOf(p) return (p:match("^(.-)[^/]*$") or "") end
local function join(a, b)
    if b:sub(1, 1) == "/" then return b end
    -- 两头都可能有斜杠：拼出 `Modules//Groups.lua` 的话，报错里的 file:line 就多了个空格，
    -- 照着它去 grep 会 grep 不到，白耽误一次定位。
    local base = slash(a):gsub("/+$", "")
    return base .. "/" .. slash(b):gsub("^/+", "")
end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

--- 从 "abs/path.lua:123: message" 里拆出 file / line / msg
local function splitError(msg, fallbackFile)
    local m = tostring(msg)
    local file, line, rest = m:match("^(.-):(%d+):(.*)$")
    if file then return file, tonumber(line), rest:match("^%s*(.-)%s*$") end
    return fallbackFile, nil, m
end

---------------------------------------------------------------- toc / xml
function Run.ParseToc(text)
    local entries, savedVars = {}, {}
    for raw in text:gmatch("[^\r\n]+") do
        local line = raw:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            entries[#entries + 1] = slash(line)
        else
            local sv = line:match("^#-SavedVariables%s*:%s*(.+)$")
            if sv then
                for name in sv:gmatch("[A-Za-z0-9_]+") do savedVars[name] = true end
            end
        end
    end
    return entries, savedVars
end

--- 读一份 xml：只认 <Include file> / <Script file>（本仓的自有 xml 一个控件都不声明）。
--- 出现别的元素标签就记一条 harness 缺口 —— 那意味着"自有 xml 里开始声明控件了"，
--- 这份驱动得先长出手，不能当没看见。
function Run.ParseXml(path, root, rep)
    local src = readFile(path)
    if not src then
        rep:Add("L", "red", "L:missing-xml:" .. slash(path), { file = path, msg = "xml 读不到" })
        return {}
    end
    src = src:gsub("<!%-%-.-%-%->", "")
    local order, seenTag = {}, {}
    -- Lua 模式**没有 `|` 分支**（`(Include|Script)` 是字面量），所以先抓任意标签名再判。
    for tag, attr in src:gmatch("<(%a+)([^>]*)>") do
        if tag == "Include" or tag == "Script" then
            local file = attr:match('file%s*=%s*"([^"]*)"')
            if file then
                order[#order + 1] = { tag = tag, file = slash(file) }
            end
        end
    end
    for name in src:gmatch("<([A-Za-z][A-Za-z0-9_%.]*)[%s>/]") do
        if not (name == "Ui" or name == "Include" or name == "Script" or name == "Interface"
            or name == "Group" or name == "Frames" or name == "Layers" or name == "Regions") then
            seenTag[name] = true
        end
    end
    for name in pairs(seenTag) do
        rep:Add("H", "warn", "H:xml-widget:" .. name, {
            file = path, msg = string.format("自有 xml %s 里出现控件标签 <%s>，驱动层还没实现它", slash(path), name),
        })
    end
    return order, src
end

---------------------------------------------------------------- 驱动
--- @param opts { root, report, engine, world, samples={绝对路径}, loadedLoD=nil|{[名]=bool}, quiet }
function Run.Main(opts)
    local rep = opts.report
    local root = slash(opts.root)
    local R = { rep = rep, gaps = {} }

    ---------------------------------------------------------------- 替身与世界
    local ApiStub = dofile(join(root, "tools/harness/api_stub.lua"))
    local Frames = dofile(join(root, "tools/harness/frames.lua"))
    local api = ApiStub.New({ engine = opts.engine, report = rep })
    local env = api.env
    R.api = api

    local W = opts.world
    local F = Frames.New({ api = api, W = W, loadedLoD = opts.loadedLoD })
    F.InstantiateAll()
    R.frames = F
    R.objectCount = F.objects

    -- SavedVariables：真客户端在加载前就把它作为（可能为空的）全局建好
    local tocText = readFile(join(root, "MonetUI.toc"))
    if not tocText then
        rep:Add("L", "red", "L:missing-toc", { file = root, msg = "MonetUI.toc 读不到" })
        return R
    end
    local entries, savedVars = Run.ParseToc(tocText)
    for name in pairs(savedVars) do api.declaredGlobals[name] = true end
    api.declaredGlobals[ADDON_NAME] = true

    -- 聊天框：FrameXML 里 ChatFrame1..N 是 C++/运行期建的，世界数据没有声明。
    -- 客户端一定给得出这几个对象，所以离线必须补上 —— 用 rawget 探测，别把"替身补的"
    -- 记成"世界里没有的全局"。
    for i = 1, 10 do
        local name = "ChatFrame" .. i
        if not rawget(env, name) and not api.BYNAME[name] then
            api.NewObject("Frame", name, env.UIParent, { blizzard = true })
        end
    end
    if not rawget(env, "ChatFrame") and not api.BYNAME.ChatFrame then
        api.NewObject("Frame", "ChatFrame", env.UIParent, { blizzard = true })
    end
    if not rawget(env, "DEFAULT_CHAT_FRAME") then
        rawset(env, "DEFAULT_CHAT_FRAME", api.BYNAME.ChatFrame1 or api.NewObject("Frame", "ChatFrame1", env.UIParent, { blizzard = true }))
    end

    ---------------------------------------------------------------- 沙箱命名空间
    local ns = {}
    R.ns = ns
    rawset(env, "MonetUIDB", nil)

    ---------------------------------------------------------------- 加载（断言一）
    local loadedFiles, loadedSet = {}, {}
    local function loadLua(abs)
        local rel = abs:sub(#root + 2)
        if loadedSet[abs] then
            rep:Add("L", "warn", "L:dup:" .. rel, { file = abs, msg = "同一份 lua 被列了两次：" .. rel })
            return
        end
        loadedSet[abs] = true
        loadedFiles[#loadedFiles + 1] = rel
        local src = readFile(abs)
        if not src then
            rep:Add("L", "red", "L:unreadable:" .. rel, { file = abs, msg = "文件读不到（清单与磁盘不一致）" })
            return
        end
        local chunk, err = load(src, "@" .. abs, "t", env)
        if not chunk then
            local f, l, m = splitError(err, abs)
            rep:Add("L", "red", "L:compile:" .. rel, {
                file = f, line = l, msg = "编译失败：" .. m, phase = "load",
            })
            return
        end
        local ok, runtime = pcall(chunk, ADDON_NAME, ns)
        if not ok then
            local f, l, m = splitError(runtime, abs)
            rep:Add("L", "red", "L:runtime:" .. rel .. ":" .. tostring(l), {
                file = f, line = l, msg = "加载期抛错：" .. m, phase = "load",
            })
        end
    end

    local function loadEntry(rel, baseDir, depth)
        if depth > 8 then
            rep:Add("L", "warn", "L:xml-depth", { msg = "xml 递归超过 8 层，疑似 Include 成环" })
            return
        end
        local abs = join(baseDir, rel)
        local ext = rel:match("%.([A-Za-z0-9]+)$")
        if ext == "xml" then
            local order = Run.ParseXml(abs, root, rep)
            for _, item in ipairs(order) do
                local targetDir = dirOf(abs)
                if item.tag == "Include" then
                    loadEntry(item.file, targetDir, depth + 1)
                else
                    loadLua(join(targetDir, item.file))
                end
            end
        elseif ext == "lua" then
            loadLua(abs)
        elseif ext == "toc" then
            rep:Add("L", "warn", "L:toc-in-toc", { msg = "清单里又列了 .toc：" .. rel })
        else
            rep:Add("L", "warn", "L:unknown-ext:" .. tostring(ext), { msg = "清单里的陌生后缀：" .. rel })
        end
    end

    rep:Phase("load")
    for _, rel in ipairs(entries) do loadEntry(rel, root, 0) end
    R.loadedFiles = loadedFiles

    -- 清单里有、磁盘上没有（或大小写不一致）：真客户端会报"无法加载"，这里必须红
    for _, rel in ipairs(entries) do
        local abs = join(root, rel)
        local probe = io.open(abs, "rb")
        if probe then probe:close()
        else
            rep:Add("L", "red", "L:not-on-disk:" .. rel, { file = abs, msg = "toc 列了但磁盘上没有：" .. rel })
        end
    end

    ---------------------------------------------------------------- print 拦截（吞掉的失败）
    local FAIL_PATTERNS = {
        { "界面美化.*应用失败", "A0p" },
        { "模块 .* 初始化失败", "A0p" },
        { "模块 .* 切换失败", "A0p" },
        { "主题刷新失败", "A0p" },
        { "事件处理器失败", "A0p" },
        { "AfterCombat '.*':", "A0p" },
        { "配色引擎.*失败", "A0p" },
        { "读取.*失败", "A0p" },
    }
    api.reportLine = function(line, file, l)
        for _, spec in ipairs(FAIL_PATTERNS) do
            if line:find(spec[1]) then
                rep:Add(spec[2], "red", string.format("A0p:%s:%s:%s", tostring(file), tostring(l), line:sub(1, 80)), {
                    file = file, line = l, msg = "被 pcall 吞掉、只 print 出来的失败：" .. line,
                })
                return
            end
        end
    end

    ---------------------------------------------------------------- 阶段执行器
    local function dispatch(event, ...)
        rep:Phase("event:" .. event)
        api:Dispatch(event, ...)
    end

    local function bootSequence()
        dispatch("ADDON_LOADED", ADDON_NAME)
        dispatch("PLAYER_LOGIN")
        dispatch("PLAYER_ENTERING_WORLD", true, false)
        api:Pump(2, 0.5)
    end

    --- 受限写入被拒时，同一条写入已在断言二记过账；这里记的是"它把整条路径打断了"。
    -- 打断源若是 A2i（保护只从父框继承、离线没有判据），这一条也停在水位以下：
    -- 否则一个未经证实的模型猜测会变成两条红（写入 + 中断），把真的红埋掉。
    local function blockAware(m)
        if type(m) == "string" and m:find("ADDON_ACTION_BLOCKED") then
            local d = api.lastDeny
            if d and d.cls == "A2i" then
                return "warn", "A0b", m .. "（打断源是继承型保护，见断言二 A2i 的黄）"
            end
        end
        return "red", "A0", m
    end

    ---------------------------------------------------------------- 断言一：首启
    rep:Phase("boot")
    local okBoot, bootErr = pcall(bootSequence)
    if not okBoot then
        local f, l, m = splitError(bootErr, "run.lua")
        local level, cls, msg = blockAware(m)
        rep:Add(cls, level, cls .. ":boot:" .. tostring(l), { file = f, line = l, msg = "首启序列抛错：" .. msg })
    end

    ---------------------------------------------------------------- 刷新路径清单
    --- 每个模块的公开刷新入口（名字约定：Apply / Refresh / Update / Redraw / UpdateAll …）
    local REFRESH_NAMES = {
        "Apply", "ApplyAll", "Refresh", "RefreshAll", "Update", "UpdateAll", "Redraw",
        "UpdateLayout", "ApplyFont", "ApplySkin", "Skin", "ThemeChanged", "OnThemeChanged",
        "Reset", "Restore", "RestoreAll",
    }
    local function moduleRefreshers()
        local list = {}
        if type(ns.GetModuleOrder) ~= "function" then return list end
        for _, name in ipairs(ns:GetModuleOrder()) do
            local m = ns:GetModule(name)
            if type(m) == "table" then
                for _, fnName in ipairs(REFRESH_NAMES) do
                    local fn = m[fnName]
                    if type(fn) == "function" then
                        list[#list + 1] = { module = name, fnName = fnName, fn = fn, m = m }
                    end
                end
            end
        end
        return list
    end

    local function runRefreshers(tag)
        local refresherList = moduleRefreshers()
        for _, item in ipairs(refresherList) do
            rep:Phase(string.format("refresh[%s]:%s.%s", tag, item.module, item.fnName))
            local ok, err = pcall(item.fn, item.m)
            if not ok then
                local f, l, m = splitError(err, "run.lua")
                local level, cls, msg = blockAware(m)
                rep:Add(cls, level, string.format("%s:%s.%s:%s:%s", cls, item.module, item.fnName, tostring(f), tostring(l)), {
                    file = f, line = l, guarded = (level ~= "red"),
                    msg = string.format("模块 %s 的 %s 在 %s 阶段抛错：%s", item.module, item.fnName, tag, msg),
                })
            end
            R.refreshCalls = (R.refreshCalls or 0) + 1
        end
        -- 界面美化引擎的全量 Apply（历史上最贵的一条路径）
        local skins = type(ns.GetModule) == "function" and ns:GetModule("Skins") or nil
        if skins and type(skins.ApplyAll) == "function" then
            rep:Phase("refresh[" .. tag .. "]:Skins.ApplyAll")
            local ok, err = pcall(skins.ApplyAll, skins)
            if not ok then
                local f, l, m = splitError(err, "run.lua")
                local level, cls, msg = blockAware(m)
                rep:Add(cls, level, cls .. ":Skins.ApplyAll:" .. tostring(l), { file = f, line = l, msg = "Skins:ApplyAll 抛错：" .. msg })
            end
            R.refreshCalls = (R.refreshCalls or 0) + 1
        end
    end

    --- 主题切换：换 source / 换区域，逼 Color 与所有订阅 MONETUI_THEME_CHANGED 的模块重算
    local function themeSwitches(tag)
        if type(ns.RefreshTheme) ~= "function" then return end
        local db = ns.DB and ns:DB()
        local theme = db and db.theme
        local sources = { "monet", "zone", "custom", "auto" }
        for _, src in ipairs(sources) do
            rep:Phase(string.format("theme[%s]:%s", tag, src))
            if theme then theme.source = src end
            local ok, err = pcall(ns.RefreshTheme, "harness-" .. src)
            if not ok then
                local f, l, m = splitError(err, "run.lua")
                local level, cls, msg = blockAware(m)
                rep:Add(cls, level, cls .. ":theme:" .. src .. ":" .. tostring(l), { file = f, line = l, msg = "换主题抛错：" .. msg })
            end
        end
        if theme then theme.source = nil end
        pcall(ns.RefreshTheme, "harness")
    end

    --- 自家框的 OnShow 重绘：等价于"玩家把这个窗口打开一次"
    local function onShowPass(tag)
        rep:Phase("onshow[" .. tag .. "]")
        for _, obj in ipairs(api.allObjects) do
            local st = api.stateOf(obj)
            if st and not st.blizzard and st.shown then
                local fn = st.scripts and st.scripts.OnShow
                if fn then
                    api.scriptsRun = api.scriptsRun
                    local ok, err = pcall(fn, obj)
                    if not ok then
                        local f, l, m = splitError(err, "run.lua")
                        local level, cls, msg = blockAware(m)
                        -- 键里带上是哪个框：78 个不同框的同一行抛错合成一条，读数就全错了
                        local frame = tostring(st.name or (st.kind .. "(" ..
                            tostring((st.parent and api.stateOf(st.parent) or {}).name or "匿名") .. ")"))
                        rep:Add(cls, level, string.format("%s:onshow:%s:%s:%s", cls, frame, tostring(f), tostring(l)), {
                            file = f, line = l, frame = frame,
                            msg = "OnShow 重绘抛错：" .. msg,
                        })
                    end
                end
            end
        end
    end

    local SWEEP_EVENTS = {
        "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_DISPLAYPOWER",
        "UNIT_AURA", "UNIT_ENTERED_VEHICLE",
        "GROUP_ROSTER_UPDATE", "RAID_ROSTER_UPDATE", "PLAYER_TARGET_CHANGED",
        "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
        "ZONE_CHANGED_NEW_AREA", "MAP_CHALLENGE_MODE_UPDATED",
        "PLAYER_EQUIPMENT_CHANGED", "INVENTORY_UPDATE",
        "UNIT_PET", "SPEC_CHANGED", "PLAYER_SPECIALIZATION_CHANGED",
        "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
        "MONETUI_RESTRICTION_CHANGED",
    }
    local UNITS = { "player", "target", "nameplate1", "party1", "raid10", "focus" }

    local function eventSweep(tag)
        for _, event in ipairs(SWEEP_EVENTS) do
            -- 只投**世界承认**的事件：C_EventUtils.IsEventValid 的答案来自 API 文档，
            -- 产品代码拿它当门，投不存在的事件等于替我们改了判据。
            local valid = env.C_EventUtils and env.C_EventUtils.IsEventValid
                and env.C_EventUtils:IsEventValid(event)
            if valid then
                for _, unit in ipairs(UNITS) do
                    if event:find("^UNIT_") or event:find("^NAME_PLATE") then
                        api:Dispatch(event, unit)
                    end
                end
                api:Dispatch(event, ADDON_NAME)
                api:Dispatch(event)
                R.eventDispatches = (R.eventDispatches or 0) + 1
            else
                rep:Add("H", "info", "H:event-not-valid:" .. event, {
                    msg = string.format("%s 阶段跳过 %s：本客户端事件表里没有这个名字", tag, event),
                })
            end
        end
        api:Pump(1.5, 0.5)
    end

    ---------------------------------------------------------------- 断言四：α 继承体检
    --- 有效 α 归零时，往上找"最后一笔把它抹掉"的写入位置：可能是自己，也可能是某个祖先
    --- （实机那个 bug 就是根面板 Strip 把 43 个 inset 窗口整批带到 α0，报子件名没用）。
    local function alphaCulprit(obj)
        local node, hops, faint = obj, 0, nil
        while node and hops < 60 do
            local s = api.stateOf(node)
            if not s then break end
            if s.alphaAt then return s.alphaAt, s end
            if not faint and (s.alpha or 1) <= 0.001 then faint = s end
            node = s.parent
            hops = hops + 1
        end
        return nil, faint
    end

    local function alphaAudit(tag, final)
        rep:Phase("alpha[" .. tag .. "]")
        -- 断言四的口径是"**最终**有效 α > 0"（背板白挂的那种）。动画中间态 —— InfoBar 的
        -- blockAlpha 从 0 起步、Toast 入场淡入 —— 不是缺陷，所以中途各阶段只记 A4t 黄，
        -- 红只在本文件末尾"把时间推到收敛"之后的那一次判定里出（final = true）。
        local cls, level = final and "A4" or "A4t", final and "red" or "warn"
        local label = api.labelOfState or function(s) return tostring(s.name or s.kind) end
        local checked, bad = 0, 0
        for _, obj in ipairs(api.allObjects) do
            local st = api.stateOf(obj)
            if st and not st.blizzard and st.backdrop and st.shown then
                local visible = true
                local okVis, res = pcall(function() return obj:IsVisible() end)
                if okVis then visible = res and true or false end
                if visible then
                    checked = checked + 1
                    local a = api.EffectiveAlpha(obj)
                    if type(a) == "number" and a <= 0.001 then
                        bad = bad + 1
                        local chain, node, hops = {}, obj, 0
                        while node and hops < 20 do
                            local s = api.stateOf(node)
                            if not s then break end
                            chain[#chain + 1] = string.format("%s(α=%.3f)", label(s), s.alpha or 1)
                            node = s.parent
                            hops = hops + 1
                        end
                        local culprit, cs = alphaCulprit(obj)
                        local f, l = "?", "?"
                        local who = "查不到写入点（父链各自 α 都 >0，是逐级累乘衰减）"
                        if culprit then
                            f = culprit.file or "?"
                            l = culprit.line or "?"
                            who = string.format("%s 的 %s 把它写成 α=%s",
                                cs and label(cs) or "?", tostring(culprit.op), tostring(culprit.value))
                            if culprit.guarded then who = who .. "（这一刀外面套着 pcall）" end
                        elseif cs then
                            who = string.format("%s 自身 α=%s（写入点未记账）", label(cs), tostring(cs.alpha))
                        end
                        rep:Add(cls, level, string.format("%s:%s:%s", cls, label(st), table.concat(chain, "<")), {
                            file = f, line = l, frame = label(st),
                            msg = string.format("挂过背板的容器 %s 有效 α=%s —— 父链：%s；原因：%s",
                                label(st), string.format("%.4f", a),
                                table.concat(chain, " ← "), who),
                        })
                    end
                end
            end
        end
        R.alphaChecked = (R.alphaChecked or 0) + checked
        return checked, bad
    end

    --- 把时间推到收敛再做唯一的红判定：插值动画（InfoBar 的 blockAlpha 逐拍逼近、Toast 淡入）
    -- 中间态是 0 不代表"背板白挂"。30 秒仿真、0.1 一拍，够这类逐拍逼近走完。
    local function settleAndAudit(tag)
        api:Pump(30, 0.1)
        return alphaAudit(tag, true)
    end

    ---------------------------------------------------------------- 受限场景
    local ENUM_STATE = { Inactive = 0, Activating = 1, Active = 2 }
    local function typeValue(name)
        local t = env.Enum and env.Enum.AddOnRestrictionType
        return t and tonumber(t[name]) or nil
    end

    local CLASSES = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }

    local function enterClass(cls)
        local tv = typeValue(cls)
        if not tv then
            rep:Add("H", "warn", "H:enum-type:" .. cls, { msg = "AddOnRestrictionType." .. cls .. " 在文档枚举里没有值" })
            return nil
        end
        -- 真客户端：事件在**生效之前**发，所以派发时 IsAddOnRestrictionActive 还是 false
        api:Dispatch("ADDON_RESTRICTION_STATE_CHANGED", tv, ENUM_STATE.Activating)
        api.restrictions[cls] = true
        if cls == "Combat" then
            api:SetLockdown(true)
            -- 真客户端 lockdown 与 PLAYER_REGEN_DISABLED 同起同落；只翻 lockdown 不派事件，
            -- 模块里 `ns:InCombat()`（按 PLAYER_REGEN_* 记状态）就滞留 false，把
            -- InCombat() 守卫全绕过 —— 那批 restricted:Combat 红全是这一半模拟造出来的。
            api:Dispatch("PLAYER_REGEN_DISABLED")
        end
        api:SetRestricted(true)
        api.world.secrets = true
        api:Dispatch("ADDON_RESTRICTION_STATE_CHANGED", tv, ENUM_STATE.Active)
        return tv
    end

    local function leaveClass(cls, tv)
        if not tv then return end
        api:Dispatch("ADDON_RESTRICTION_STATE_CHANGED", tv, ENUM_STATE.Inactive)
        api.restrictions[cls] = nil
        if cls == "Combat" then api:SetLockdown(false) end
        local any = false
        for _ in pairs(api.restrictions) do any = true end
        api:SetRestricted(any)
        if not any then api.world.secrets = false end
        api:Dispatch("PLAYER_REGEN_ENABLED")
    end

    rep:Phase("restricted-sweep")
    for _, cls in ipairs(CLASSES) do
        local tv = enterClass(cls)
        local label = "restricted:" .. cls
        eventSweep(label)
        runRefreshers(label)
        themeSwitches(label)
        onShowPass(label)
        alphaAudit(label)
        api:Pump(1, 0.5)
        leaveClass(cls, tv)
    end

    -- 全清之后再跑一遍明文路径：脱战后的 AfterCombat 队列在这里排空
    rep:Phase("plain")
    eventSweep("plain")
    runRefreshers("plain")
    themeSwitches("plain")
    onShowPass("plain")
    api:Pump(3, 0.5)
    alphaAudit("plain")
    -- 断言四的红只在这里出（动画收敛之后仍然 α0 的挂背板容器才算"美化白挂"）
    settleAndAudit("final")

    ---------------------------------------------------------------- 断言五：Need 台账
    local function needLedger()
        local Skin = ns.Skin
        if not Skin or not Skin.targets then
            rep:Add("H", "warn", "H:no-ledger", { msg = "ns.Skin.targets 不存在：断言五没跑起来（加载失败？）" })
            return
        end
        local misses, hits = {}, 0
        for scope, byPath in pairs(Skin.targets) do
            for path, led in pairs(byPath) do
                if led.hits and led.hits > 0 then hits = hits + 1 end
                if (led.misses or 0) > 0 and (led.hits or 0) == 0 then
                    misses[#misses + 1] = { scope = scope, path = path, misses = led.misses, shape = led.shape }
                end
            end
        end
        table.sort(misses, function(a, b)
            if a.path == b.path then return tostring(a.scope) < tostring(b.scope) end
            return a.path < b.path
        end)
        for _, m in ipairs(misses) do
            -- 这个世界里到底有没有它？有 → 大概率是 LoD 没加载或运行时才有；没有 → 真 ✗
            local head = m.path:match("^[^%.]+")
            local known = head and F.HasGlobal(head)
            local provider = head and F.ProvidedBy(head)
            rep:Add("A5", known and "warn" or "info",
                string.format("A5:%s:%s:%s", tostring(m.scope), m.path, known and "inWorld" or "absent"), {
                    path = m.path, scope = m.scope, misses = m.misses, shape = m.shape,
                    inWorld = known and true or false, lod = provider,
                    msg = string.format("✗ %s.%s 缺席 %d 次（世界里%s%s）",
                        tostring(m.scope), m.path, m.misses,
                        known and "有这个名字" or "查不到",
                        provider and ("，属 LoD 插件 " .. provider) or ""),
                })
        end
        R.ledgerMisses = #misses
        R.ledgerHits = hits
    end
    needLedger()

    ---------------------------------------------------------------- 样例（假绿自检）
    if opts.samples and #opts.samples > 0 then
        for _, abs in ipairs(opts.samples) do
            abs = slash(abs)
            rep:Phase("sample:" .. abs)
            local src = readFile(abs)
            if not src then
                rep:Add("L", "red", "L:sample-missing:" .. abs, { file = abs, msg = "样例文件读不到" })
            else
                local chunk, err = load(src, "@" .. abs, "t", env)
                if not chunk then
                    local f, l, m = splitError(err, abs)
                    rep:Add("L", "red", "L:sample-compile:" .. abs, { file = f, line = l, msg = "样例编译失败：" .. m })
                else
                    local ok, runtime = pcall(chunk, ADDON_NAME, ns)
                    if not ok then
                        local f, l, m = splitError(runtime, abs)
                        rep:Add("L", "red", "L:sample-runtime:" .. abs .. ":" .. tostring(l), {
                            file = f, line = l, msg = "样例加载期抛错：" .. m,
                        })
                    end
                end
            end
        end
        -- 样例的破坏动作必须**真的被驱动一次**才算证明断言会红：
        -- 样例把自己注册成模块（ns:Register("HarnessSample…", M) + M:Apply），
        -- 于是 runRefreshers / 受限窗口都会走到它。
        runRefreshers("sample")
        onShowPass("sample")
        pcall(function() if type(ns.RefreshTheme) == "function" then ns:RefreshTheme("harness-sample") end end)
        alphaAudit("sample")
        for _, cls in ipairs(CLASSES) do
            local tv = enterClass(cls)
            runRefreshers("sample:" .. cls)
            alphaAudit("sample:" .. cls)
            leaveClass(cls, tv)
        end
        -- 样例里"Strip 后不回 α"的那一刀必须在收敛态仍然 α0 才算把断言四打红
        settleAndAudit("sample-final")
        needLedger()
    end

    ---------------------------------------------------------------- 收尾统计
    R.gaps = {
        stubGaps = api.stubGaps,
        gapMethods = api.gapMethods,
        unknownApi = api.unknownApi,
        enumGaps = api.enumGaps,
        helperGaps = api.helperGaps,
        unknownGlobals = api.unknownGlobals,
    }
    R.prints = api.prints
    R.scriptsRun = api.scriptsRun
    R.restrictionReds = nil
    return R
end

---------------------------------------------------------------- CLI
-- 直接 `lua tools/harness/run.lua --root=…` 也能跑；run.js 就是这么起的。
local function cli(args)
    local root, sampleDir, maxRows, selftest
    for _, a in ipairs(args) do
        root = a:match("^%-%-root=(.+)$") or root
        sampleDir = a:match("^%-%-samples=(.+)$") or sampleDir
        maxRows = tonumber(a:match("^%-%-max=(%d+)$")) or maxRows
        if a == "--selftest" then selftest = true end
    end
    if not root then
        local here = debug.getinfo(1, "S").source:sub(2)
        root = dirOf(dirOf(dirOf(here)))
    end
    root = slash(root)

    local Report = dofile(join(root, "tools/harness/report.lua"))
    local engine = dofile(join(root, "tools/harness/engine-api.lua"))
    local world = dofile(join(root, "tools/harness/world-data.lua"))
    local rep = Report.New()

    local samples = {}
    if sampleDir then
        sampleDir = slash(sampleDir)
        -- Lua 标准库没有目录枚举：把已知样例名排进来（新增样例要同步这里）
        local known = {
            "bad-write-blizzard-field.lua", "bad-strip-alpha.lua", "bad-combat-write.lua",
            "bad-hookscript.lua", "bad-secret-math.lua",
        }
        for _, name in ipairs(known) do
            local abs = join(sampleDir, name)
            if readFile(abs) then samples[#samples + 1] = abs end
        end
    end

    local R = Run.Main({
        root = root, report = rep, engine = engine, world = world, samples = samples,
    })

    print(rep:Render({
        max = maxRows or 12,
        gaps = R.gaps,
        meta = {
            string.format("世界：%s 分支 · 实例化 %d 个暴雪对象（%d 个有全局名）",
                tostring(world.branch), R.objectCount or 0, R.frames and R.frames.named or 0),
            string.format("加载：%d 份文件（toc + xml 顺序）· 事件投递 %d 次 · 脚本运行 %d 次 · 刷新调用 %d 次",
                #(R.loadedFiles or {}), R.eventDispatches or 0, R.scriptsRun or 0, R.refreshCalls or 0),
            string.format("α 体检：%d 个挂过背板的容器 · Need 台账：命中 %d 条 / 缺席 %d 条",
                R.alphaChecked or 0, R.ledgerHits or 0, R.ledgerMisses or 0),
            samples[1] and ("样例：" .. #samples .. " 份（--selftest 用来证明断言确实会红）") or nil,
        },
    }))

    local s = rep:Summary()
    print(string.format("HARNESS_RESULT red=%d warn=%d guarded=%d info=%d places=%d objects=%d files=%d",
        s.reds, s.warns, s.guarded, s.infos, s.places, R.objectCount or 0, #(R.loadedFiles or {})))

    if selftest then
        -- 每个样例都该把它那一类的红打出来；打不出来 = 断言是假的（假绿自检）。
        local EXPECT = {
            { "A3", "bad-write-blizzard-field", "断言三：往暴雪对象写字段" },
            { "A4", "bad-strip-alpha", "断言四：带背板容器 α=0" },
            { "A2", "bad-combat-write", "断言二：受限窗口未守卫写入" },
            { "A3h", "bad-hookscript", "断言三：HookScript 暴雪框" },
            { "A0", "bad-secret-math", "断言一：机密值裸比较" },
        }
        print("== 假绿自检（样例 -> 期望的红）==")
        local failed = 0
        for _, want in ipairs(EXPECT) do
            local hit = false
            for _, row in ipairs(rep.rows) do
                if row.level == "red" and row.cls == want[1] then
                    local d = row.detail or {}
                    if tostring(d.file or ""):find(want[2], 1, true) then hit = true break end
                end
            end
            print(string.format("  %-4s %-28s %s", hit and "OK" or "MISS", want[2], want[3]))
            if not hit then failed = failed + 1 end
        end
        print(failed == 0 and "自检：五类断言都能被对应的坏样例打红。"
            or string.format("自检：有 %d 类断言打不红 —— harness 本身有问题，先修 harness。", failed))
        os.exit(failed == 0 and 0 or 2)
    end
    os.exit(s.fails and 1 or 0)
end

if ... then
    local args = { ... }
    if type(args[1]) == "string" and args[1]:sub(1, 2) == "--" then
        local ok, err = pcall(cli, args)
        if not ok then
            io.stderr:write("harness 自身出错：" .. tostring(err) .. "\n")
            os.exit(3)
        end
    end
end

return Run
