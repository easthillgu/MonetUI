-- tools/harness/api_stub.lua
-- 无头 WoW 客户端替身层（只给 tools/harness/ 用，不参与发行；.toc 里没有它）。
--
-- 这一层要回答的问题只有一个：**把 MonetUI 真的跑起来**，让静态闸门看不见的运行期
-- 行为当场发生 —— 换皮循环真的去 SetPoint/GetRegions、机密值真的抛、受限状态下写暴雪
-- 框真的被拒。所以这里的每一条行为都要有出处：
--   · 受保护操作 / forbidden 语义      → AGENTS.md「安全边界」「污染模型」
--   · 机密值执法强度                  → AGENTS.md「执法强度不均匀」实测表（12.1.5 / 70688）
--   · 六类限制 / InCombatLockdown     → Core.lua 的 ns:IsRestricted / ns:InCombat
--   · GetAlpha 与顶点色 alpha 同一份存储 → AGENTS.md「客户端行为细则」（InsetWell 判例）
--
-- 对象模型：每个 UI 对象都是**空原始表 + 元表**，所有可变状态放在旁表 STATE 里。
-- 原始表恒空 ⇒ 任何字段赋值都会走 __newindex ⇒ 断言三（往暴雪对象写字段）不可能漏。
-- 子件（暴雪框的 `frame.Inset` / `CharacterFrame.CloseButton`）由 frames.lua 通过
-- hooks.blizzChild 惰性实例化，所以"读一个还没建过的子件"与真客户端一致。
--
-- luacheck: ignore

local ApiStub = {}
ApiStub.__version = "1.0"

-- ------------------------------------------------------------------ 受限操作清单
-- 受限状态下（ns:IsRestricted() 为真 / 自家 secure 框在战斗中）对这些写入直接抛
-- `ADDON_ACTION_BLOCKED MonetUI <Frame>:<Op>()`。SetAlpha **不在**这张表里：
-- Widget:Mute 就是靠它在战斗中压掉暴雪 HUD，实机证明可用（AGENTS「压制暴雪显示」）。
local PROTECTED_OP = {
    SetPoint = true, ClearAllPoints = true, SetAllPoints = true,
    SetSize = true, SetWidth = true, SetHeight = true,
    Show = true, Hide = true, SetShown = true,
    SetParent = true, SetScale = true, SetFrameStrata = true, SetFrameLevel = true,
    SetScript = true, HookScript = true,
    SetAttribute = true, SetAttributeMismatch = true,
    RegisterEvent = true, RegisterUnitEvent = true, UnregisterEvent = true,
    UnregisterAllEvents = true, RegisterStateDriver = true, UnregisterStateDriver = true,
    RegisterForClicks = true, RegisterForDrag = true, RegisterDisabledTicks = true,
    -- EnableMouse / EnableMouseWheel / EnableKeyboard **不是**受保护调用（AGENTS 判例：
    -- 「要让它不响应鼠标就用 EnableMouse(false)（不受保护、也不写字段）」，Widget:Mute 的
    -- 子树关鼠标全靠它）。放进来会把 Skin:Need("CharacterFramePortrait") 后那句合法的
    -- EnableMouse(false) 升成红（11-04 run3 的 A2 ×14 / A0p ×1 假红），还把 Apply 半路打断。
    SetClampedToScreen = true, SetMovable = true, SetUserPlaced = true, SetToplevel = true,
    SetHitRectInsets = true, SetClampRectInsets = true, SetAlphaKeyRange = true,
    SetValue = true,            -- secure 条（如暴雪施法条）战斗中被写 = 判例里的 SetPointBase 同类
    SetMinMaxValues = true,
}

-- 内容类写入：换皮本来就要做（贴图/颜色/文字），不抛，只在"暴雪对象 + 受限"时记一条
-- 信息账（AGENTS：碰过的框体之后由引擎代写会被记成 MonetUI 的名义）。
local CONTENT_OP = {
    SetAlpha = true, SetVertexColor = true, SetTexture = true, SetColorTexture = true,
    SetTexCoord = true, SetBackdrop = true, SetBackdropColor = true,
    SetBackdropBorderColor = true, SetText = true, SetFormattedText = true,
    SetFont = true, SetTextColor = true, SetNormalTexture = true, SetHighlightTexture = true,
    SetPushedTexture = true, SetDisabledTexture = true, SetCheckedTexture = true,
    SetStatusBarTexture = true, SetStatusBarColor = true, SetBlendMode = true,
    SetJustifyH = true, SetJustifyV = true, SetWordWrap = true, SetMaskTexture = true,
}

-- ------------------------------------------------------------------ 调用点定位
local HARNESS_SRC = { api_stub = true, frames = true, run = true, report = true }

local function isHarnessSource(src)
    if not src then return false end
    if src:sub(1, 1) == "[" then return true end        -- [C] / [string "…"]
    local base = src:match("([^/\\]+)%.lua$")
    return (base ~= nil and HARNESS_SRC[base]) and true or false
end

--- 取「最近的非 harness 帧」= 真正的调用点，以及它外面有没有 pcall。
-- guarded   = __ 紧邻这一刀就是 pcall/xpcall（代码自己包了这一层）
-- swallowed = 更外面才有 pcall（错误会被别人吃掉，实机只剩一行聊天提示或什么都不剩）
local function CallSite(skip)
    local level = (skip or 2)
    local file, line, firstLuaLevel = nil, nil, nil
    local guarded, swallowedAt = false, nil
    for i = level, 80 do
        local info = debug.getinfo(i, "nSl")
        if not info then break end
        local isC = info.short_src == "[C]"
        if isC and (info.name == "pcall" or info.name == "xpcall") then
            local outer = debug.getinfo(i + 1, "Sl")
            local outerIsHarness = outer and outer.short_src ~= "[C]" and isHarnessSource(outer.source or "")
            if outerIsHarness then
                -- **harness 自己的 pcall**（run.lua 驱动产品函数时包的）：不算产品做了守卫，
                -- 否则"未守卫的暴雪写入"会被我们自己的驱动层洗成 guarded —— 那是假绿。
            elseif not firstLuaLevel then
                guarded = true          -- 紧邻这一刀就是 pcall ⇒ 调用点自己包了
            elseif not swallowedAt then
                if outer and outer.short_src ~= "[C]" then
                    swallowedAt = string.format("%s:%d",
                        tostring(outer.source):match("@?([^/\\]+)$") or outer.short_src,
                        outer.currentline or 0)
                else
                    swallowedAt = "顶层"
                end
            end
        elseif not isC and isHarnessSource(info.source) then
            -- 替身自己的内部帧，跳过
        elseif not isC then
            if not firstLuaLevel then
                firstLuaLevel = i
                file = tostring(info.source):gsub("^@", "")
                line = info.currentline or 0
            end
        end
        if firstLuaLevel and (guarded or swallowedAt) then break end
    end
    return file, line, guarded, swallowedAt
end

-- ------------------------------------------------------------------ 机密值
local secretMT
local function MakeSecret(kindLabel)
    return setmetatable({ __mui_secret = kindLabel or "value" }, secretMT)
end

secretMT = {
    -- 只有这两样在实测表里是"稳定不抛"的：== nil / 真值测试。表天然满足，不做手脚。
    __index = function(_, k)
        if k == "__mui_secret" then return rawget(_, 1) end
        error("attempt to index a secret " .. tostring(rawget(_, 1) or "value") .. " value", 2)
    end,
    __call = function() error("attempt to call a secret value", 2) end,
    __tostring = function(s) return "<SECRET>" end,   -- 实测：tostring 稳定 → 不抛，由 ledger 记账
    __concat = function(a, b)
        local which = rawget(a, "__mui_secret") and a or b
        error("attempt to concatenate a secret " .. tostring(rawget(which, "__mui_secret") or "value") .. " value", 2)
    end,
    __len = function() error("attempt to get length of a secret value", 2) end,
    __lt = function() error("attempt to compare a secret value", 2) end,
    __le = function() error("attempt to compare a secret value", 2) end,
    __gt = function() error("attempt to compare a secret value", 2) end,
    __add = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __sub = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __mul = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __div = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __mod = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __unm = function() error("attempt to perform arithmetic on a secret number value", 2) end,
    __metatable = "secret value",
}

-- ------------------------------------------------------------------ ColorMixin
-- 依据 framexml-source：Blizzard_SharedXMLBase/Color.lua 的 ColorMixin +
-- Blizzard_SharedXML/ClassColors.lua 的 RAID_CLASS_COLORS。
-- 为什么要在替身里补这个：APIDocumentationGenerated/ClassColorDocumentation.lua 写明
-- `C_ClassColor.GetClassColor` 的 Returns 是**一个 colorRGB（ColorMixin 表）**，不是三个数；
-- Utils/Color.lua:302 就是按表读的（`c.r`）。替身若返回三个数，产品会在自己没错的那一行
-- 报 "attempt to index a number value" —— 那是替身的洞，不是 MonetUI 的 bug。
-- 同理 CreateColor / RAID_CLASS_COLORS 都是 FrameXML 里的真东西：不给，Widget.lua:583 的
-- `type(CreateColor) ~= "function"` 就直接跳过渐变那一整支（假绿的一种）。
-- 色值本身离线不验证：任何一组 0..1 都能把分支跑完，真值以实机为准。
local CLASS_LIST = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}
local CLASS_TINT = {
    DEATHKNIGHT = { 0.77, 0.12, 0.23 }, DEMONHUNTER = { 0.64, 0.19, 0.68 },
    DRUID = { 0.92, 0.51, 0.50 }, EVOKER = { 0.25, 0.78, 0.92 },
    HUNTER = { 0.67, 0.83, 0.45 }, MAGE = { 0.40, 0.76, 1.00 },
    MONK = { 0.20, 0.86, 0.77 }, PALADIN = { 0.96, 0.84, 0.14 },
    PRIEST = { 1.00, 1.00, 1.00 }, ROGUE = { 1.00, 0.96, 0.41 },
    SHAMAN = { 0.00, 0.44, 0.87 }, WARLOCK = { 0.53, 0.52, 0.93 },
    WARRIOR = { 0.78, 0.61, 0.43 },
}

local function MakeColor(r, g, b, a)
    local c = { r = r or 1, g = g or 1, b = b or 1, a = a or 1 }
    function c:GetRGB() return self.r, self.g, self.b end
    function c:GetRGBA() return self.r, self.g, self.b, self.a end
    function c:GetColor() return self.r, self.g, self.b, self.a end
    function c:SetRGB(rr, gg, bb) self.r, self.g, self.b = rr, gg, bb return self end
    function c:SetRGBA(rr, gg, bb, aa)
        self.r, self.g, self.b, self.a = rr, gg, bb, aa or 1
        return self
    end
    function c:Copy(other)
        if other then self:SetRGBA(other.r, other.g, other.b, other.a) end
        return self
    end
    function c:IsEqualTo(other)
        return other ~= nil and self.r == other.r and self.g == other.g
            and self.b == other.b and self.a == other.a
    end
    function c:GenerateHexColor()
        local function hx(v)
            local n = math.floor(math.max(0, math.min(1, v or 0)) * 255 + 0.5)
            return string.format("%02X", n)
        end
        return hx(self.r) .. hx(self.g) .. hx(self.b)
    end
    function c:GenerateHexColorMarkup()
        return "|cFF" .. self:GenerateHexColor() .. "%s"
    end
    function c:WrapTextInColorCode(text)
        return "|cFF" .. self:GenerateHexColor() .. tostring(text or "") .. "|r"
    end
    c.colorStr = c:GenerateHexColor()
    return c
end

-- ------------------------------------------------------------------ 构造

function ApiStub.New(config)
    config = config or {}
    local api = setmetatable({}, { __index = ApiStub })
    api.report = config.report
    api.engine = config.engine or {}       -- engine-api.lua（客户端 API 证据）
    api.hooks = { blizzChild = nil, blizzList = nil, blizzArt = nil }

    -- 替身可控制的世界状态（run.lua 写它）
    api.world = {
        lockdown = false,       -- InCombatLockdown()
        restricted = false,     -- ns:IsRestricted() 的真值来源（六类任一激活）
        secrets = false,        -- C_Secrets.HasSecretRestrictions()
        flushWindow = false,    -- 正处在 Core.AfterCombat 的排空窗口里（run.lua 在派发 regen / 限制解除时置位）
        editMode = false,       -- PetBattleFrames / EditMode（暂不置）
        inRaid = false,         -- IsInRaid()：团队帧的显隐分支靠它
        inParty = false,        -- IsInGroup() / IsInParty()
        deadUnits = nil,        -- [unit] = true ⇒ UnitIsDeadOrGhost(unit)
        disconnectedUnits = nil,-- [unit] = true ⇒ not UnitIsConnected(unit)
        time = 1000,
        screen = { 1920, 1080 },
        scale = 1,
    }

    api.STATE = {}              -- obj -> state（harness 常驻，不做弱表）
    api.byName = {}             -- 名字 -> obj（含暴雪全局对象与自家命名框）
    api.eventRegs = {}          -- obj -> { event -> units }
    api.timers = {}             -- 到期队列
    api.nextTimer = 1
    api.onUpdate = {}           -- 有 OnUpdate 脚本的对象
    api.allObjects = {}
    api.scriptsRun = 0
    api.gapMethods = {}         -- 文档里也查不到的方法名 -> 次数（真客户端同样给 nil）
    api.unknownGlobals = {}     -- 读了但世界里没有的全局 -> { file, line }
    api.stubGaps = {}           -- 客户端有、替身只给空实现的名字（C_x.Method / Kind.Method / 全局）-> 次数
    api.helperGaps = {}         -- FrameXML 里确有此名（helper/常量）而替身没给 -> 次数
    api.unknownApi = {}         -- 文档里**没有**的 C_x.Method -> { file, line }（真客户端会给 nil）
    api.restrictedCalls = {}    -- 文档标 fl.r（受限）的 C_ 方法被调到 -> 次数（只记账，不判红）

    local rep = api.report
    local function add(cls, level, key, detail)
        if rep and rep.Add then rep:Add(cls, level, key, detail) end
    end
    api.add = add

    ---------------------------------------------------------------- 对象核心
    local STATE, ALL, BYNAME = api.STATE, api.allObjects, api.byName
    local KIND_METHODS = {}
    api.KIND_METHODS = KIND_METHODS

    -- "受保护"是**逐对象**的属性，不是"这是暴雪的框"。客户端的真值是 Frame:IsProtected()：
    -- 只有由安全环境生产的框（XML protected="true" / inherits 链碰到 Secure* 模板）才受保护，
    -- 普通暴雪框（CharacterFrame 的装饰件、Minimap 那一类）在受限窗口里被我们写点是合法的。
    -- 出处：world-data.lua 每行的 prot 位（由 build-world.js 沿模板 inherits 求传递闭包），
    -- 自家框走 CreateFrame 的模板判据。判据宽了会把合法写入报成假红（11-04 run3 的
    -- CharacterFramePortrait:SetSize ×14 / A0p ×1 就是这么来的），窄了会漏掉收养来的安全按钮。
    local function isProtectedObj(st)
        return (st.secure or st.protected) and true or false
    end
    api.isProtectedObj = isProtectedObj

    local function restrictionBlocks(st)
        if not isProtectedObj(st) then return false end
        return api.world.lockdown or api.world.restricted
    end

    local function labelOf(st)
        if type(st.name) == "string" and st.name ~= "" then return st.name end
        local p = st.parent and STATE[st.parent]
        return string.format("匿名%s(%s)", st.kind, p and labelOf(p) or "无父框")
    end

    --- 抛之前一定先记账：谁吞掉错误都不影响台账完整性。
    -- 判"这一刀是不是受保护操作"有两份判据（下面 need 里并联），其中来自文档快照的那份
    -- 定义在 DOC_KIND_CHAIN 之后，这里先拿一个前向引用。
    local docProtectedFor

    -- 红分三档，因为离线证据只撑得起前两档：
    --   A2  红  ：**受保护**对象 —— 暴雪侧是 world-data prot=1 的那批（Secure* 模板 /
    --             protected="true" 出身），自家侧是按 Secure 模板造的框。依据是 AGENTS
    --             「安全单位按钮的显隐只能交给 visibility state driver …… 战斗中必被拒
    --             （ADDON_ACTION_BLOCKED MonetUITargetFrame:Hide()）」，以及文档给这些方法挂的
    --             pm（受保护的方法）标记。
    --   A2i 黄 ：**我们自建**的子件，只因为"父框受保护"才算受保护（血条、火花这类匿名子控件）。
    --             客户端文档里没有"保护随父继承"这一条（CreateFrame 根本不在 APIDocumentation 里），
    --             拿它当红就是拿猜测当结论；但它又确实可能是实机那批拦截的来源，所以留黄待实机复核。
    --   A2n 黄 ：受限窗口里对**普通暴雪框**（prot=0）做受保护级写入。判据只到 XML：
    --             实机里有些框是 Lua 造的（ Blizzard_<X>.lua 里 CreateFrame 时带上 secure 模板），
    --             离线看不到 → 不判红，但要留在账上，实机复核同一条。
    --   A6  红 ：**regen / 限制解除派发当拍**里写受保护对象。本客户端"先派事件、后翻
    --             InCombatLockdown()"（2026-10-27 实机探针，Core.lua:505），所以那一拍原生
    --             标志仍是 true，客户端会照拒。这不一定是"缺守卫"，多半是**时序错**：
    --             这刀要挪进 `C_Timer.After(0, …)`（AGENTS 里 Bags 停车同款）。Core 11-04 已把
    --             它自己的排空挪走；仍会命中的是"模块自己在 regen 处理里硬写"这类形状。
    --             单独立一类是因为修法不同（不是补 pcall/补 InCombatLockdown 守卫）。
    local function deny(obj, op, file, line, guarded, swallowedAt, pmDoc)
        local st = STATE[obj]
        local frame = labelOf(st)
        local inherited = (not st.blizzard) and st.inheritedSecure and true or false
        local cls
        if inherited then cls = "A2i"
        elseif api.world.flushWindow then cls = "A6"
        else cls = "A2" end
        -- 判据要能自查：写成"文档 fl.pm（Frame）"的那一类是客户端文档给的，写成"替身清单"的
        -- 那一类是我们从 AGENTS 判例手抄的。红点如果只来自后者，复核时先怀疑判据而不是先改产品。
        local evidence = pmDoc and ("文档 fl.pm（" .. pmDoc .. "）") or "替身 PROTECTED_OP 清单（文档未标 pm）"
        -- 驱动层（run.lua）要知道手上这个抛错是哪一档带出来的：继承型保护只该记黄，
        -- 它打断的那条刷新路径就不能再升成一条红（一屏红全来自同一条猜测）。
        -- 去重键里带上"哪一拍拒的"：战斗中未守卫、脱战排空那一拍（lockdown 还没翻）、
        -- 以及非战斗类限制（只有 restricted），三者修法不同，合成一行就都看不见了（根因 b）。
        local win = (api.world.lockdown and "L" or "") .. (api.world.restricted and "R" or "")
        api.lastDeny = { cls = cls, frame = frame, op = op, file = file, line = line, win = win }
        add(cls, inherited and "warn" or (guarded and "guarded" or "red"),
            string.format("%s:%s:%s:%s:%s:%s", cls, frame, op, tostring(file), tostring(line), win), {
                file = file, line = line, frame = frame, op = op, kind = st.kind,
                guarded = guarded, swallowedAt = swallowedAt, evidence = evidence,
                -- 被拒那一拍的世界状态必须一起打：同一条写入发生在"战斗中"还是
                -- "脱战排空那一拍（lockdown 还没翻）"，修法完全不同（根因 b 就靠这个定位）。
                flags = string.format("lockdown=%s restricted=%s secrets=%s",
                    tostring(api.world.lockdown and true or false),
                    tostring(api.world.restricted and true or false),
                    tostring(api.world.secrets and true or false)),
                msg = string.format("ADDON_ACTION_BLOCKED MonetUI %s:%s()", frame, op),
                why = string.format("%s · 判据：%s",
                    cls == "A6"
                        and "regen / 限制解除派发当拍写受保护对象（InCombatLockdown() 还是 true）—— 时序错，这刀要 C_Timer.After(0) 再写"
                        or (st.blizzard and "受保护暴雪对象（world-data prot=1）+ 受限状态"
                            or (inherited and "自建子件、保护只从父框继承（离线无据，待实机）"
                                or "自家 secure 对象 + 战斗/受限")), evidence),
            })
        error(string.format("ADDON_ACTION_BLOCKED MonetUI %s:%s()", frame, op), 0)
    end

    local function need(obj, op)
        local st = STATE[obj]
        if not st then error("attempt to use a removed " .. tostring(op) .. " handle", 2) end
        if not (st.blizzard or st.secure) then return st end
        local file, line, guarded, swallowedAt = CallSite(3)
        local pmDoc = docProtectedFor(st.kind, op)
        local isProtectedOp = PROTECTED_OP[op] or pmDoc
        if not restrictionBlocks(st) then
            -- prot=0 的暴雪框 + 受限窗口：客户端不会拒这一刀，所以不判红；但"受保护级操作"
            -- 落在它身上只说明离线判据（XML inherits 链）没覆盖到它的出身，留黄等实机复核。
            if st.blizzard and not st.protected and isProtectedOp
                and (api.world.lockdown or api.world.restricted) then
                add("A2n", "warn", string.format("A2n:%s:%s:%s:%s", labelOf(st), op, tostring(file), tostring(line)), {
                    file = file, line = line, frame = labelOf(st), op = op, kind = st.kind,
                    guarded = guarded, swallowedAt = swallowedAt,
                    evidence = (pmDoc and ("文档 fl.pm（" .. pmDoc .. "）") or "替身 PROTECTED_OP 清单（文档未标 pm）"),
                    msg = string.format("受保护级写入落在非受保护暴雪框：%s:%s()（未拒绝）", labelOf(st), op),
                    why = "world-data prot=0：XML 声明里它不来自 Secure 模板 / protected=\"true\"；"
                        .. "实机可能是 Lua 里造的受保护框，留黄待 /mui skins diagnose 复核",
                })
            end
            return st
        end
        if isProtectedOp then
            return deny(obj, op, file, line, guarded, swallowedAt, pmDoc)
        end
        if CONTENT_OP[op] then
            add("A2c", "info", string.format("A2c:%s:%s", labelOf(st), op), {
                file = file, line = line, frame = labelOf(st), op = op,
                msg = "受限状态下仍然写了暴雪对象的内容属性",
            })
        end
        return st
    end

    ---------------------------------------------------------------- 有效 α
    local function effectiveAlpha(obj)
        local a, node, hops = 1, obj, 0
        while node and hops < 60 do
            local st = STATE[node]
            if not st then break end
            a = a * (st.alpha or 1)
            node = st.parent
            hops = hops + 1
        end
        return a
    end
    api.EffectiveAlpha = effectiveAlpha

    ---------------------------------------------------------------- α 写入记账（断言四的定位）
    -- 只报"哪个容器 α=0"没有可操作性：要改的是把 α 写成 0 的那一行。AGENTS 讲 GetAlpha 和
    -- 顶点色 alpha 共用一份存储，所以 SetVertexColor / SetColorTexture / SetTextColor 的 a
    -- 参数同样是 α 写入，四类都从这个漏斗过一遍，记下最后一笔"抹掉它"的写入位置。
    -- 之后有人把 α 写回正数就清账：那样这一笔已经不是当前状态的原因，红点指向别处才是假信息。
    local function noteAlpha(st, a, op)
        if a == nil then return end
        if a > 0.001 then
            st.alphaAt = nil
            return
        end
        local file, line, guarded = CallSite(3)
        st.alphaAt = { file = file, line = line, op = op, value = a, guarded = guarded }
    end
    api.noteAlpha = noteAlpha

    ---------------------------------------------------------------- 文档驱动的"存在但没实现"
    -- 手写的方法表 / 全局表只覆盖到我们真会用的那些。客户端文档（engine-api.lua）里有、
    -- 替身里没有的名字，真客户端**一定有**：那里报 "attempt to call a nil value" 是替身的洞，
    -- 让它混进断言一就等于把"harness 没写完"伪装成"产品有 bug"。
    -- 所以分两档：
    --   文档里有 ⇒ 给一个存在但答不上来的空函数，并记进 api.stubGaps（黄色，报告里单列覆盖面）；
    --   文档里没有 ⇒ 保持 nil，产品得到它上线真会得到的错误（红色才可信）。
    local emptyDocFn = function() return nil end
    local docGlobalSet, docGlobalReady = nil, false
    local function docGlobals()
        if not docGlobalReady then
            docGlobalSet = {}
            local list = api.engine.globals or {}
            for i = 1, #list do
                local g = list[i]
                if type(g) == "string" then docGlobalSet[g] = true end
            end
            docGlobalReady = true
        end
        return docGlobalSet
    end

    -- 本替身的 kind 名 → 文档里的 widget 类型名（按继承顺序，取并集才是客户端真给的方法）。
    -- 别名依据：Minimap 在文档里叫 MinimapFrame；Icon / AtlasTexture / MaskedTexture / 纹章
    -- 都是 Texture；ScrollMessage 是 MessageFrame；PlayerModel 走 DressUpModel 那一族。
    local DOC_KIND_CHAIN = {
        Frame = { "Frame" },
        Button = { "Button", "Frame" },
        ItemButton = { "Button", "Frame" },
        Item = { "Button", "Frame" },
        CheckButton = { "Checkbox", "Button", "Frame" },
        StatusBar = { "StatusBar", "Frame" },
        EditBox = { "EditBox", "Frame" },
        Slider = { "Slider", "Frame" },
        ScrollFrame = { "ScrollFrame", "Frame" },
        ScrollMessage = { "MessageFrame", "Frame" },
        Minimap = { "MinimapFrame", "Frame" },
        Cooldown = { "Cooldown", "Frame" },
        DropDownList = { "Frame" },
        PlayerModel = { "DressUpModel", "CharacterModelBase", "Model", "Frame" },
        ModelSceneFrame = { "ModelSceneFrame", "Frame" },
        GameTip = { "Tooltip", "Frame" },
        Texture = { "Texture", "TextureBase", "Frame" },
        Icon = { "Texture", "TextureBase", "Frame" },
        AtlasTexture = { "Texture", "TextureBase", "Frame" },
        AnimatedTexture = { "Texture", "TextureBase", "Frame" },
        MaskedTexture = { "Texture", "TextureBase", "Frame" },
        MaskTexture = { "TextureBase", "Frame" },
        Line = { "Line", "TextureBase", "Frame" },
        FontString = { "FontString", "Frame" },
    }
    for _, suffix in ipairs({ "Background", "Border", "Charter", "Emblem" }) do
        DOC_KIND_CHAIN["Tabard" .. suffix] = DOC_KIND_CHAIN.Texture
    end
    local docChainCache, docTypeCache = {}, {}
    local helperSet, helperReady = nil, false
    local function helperNames()
        if not helperReady then
            helperSet = {}
            local list = api.engine.framexmlGlobals or {}
            for i = 1, #list do
                local h = list[i]
                if type(h) == "string" then helperSet[h] = true end
            end
            helperReady = true
        end
        return helperSet
    end
    local function docTypeMethods(t)
        local set = docTypeCache[t]
        if set then return set end
        set = {}
        local doc = (api.engine.objectMethods or {})[t]
        if type(doc) == "table" then
            for i = 1, #doc do
                local m = doc[i]
                if type(m) == "string" then set[m] = true end
            end
        end
        docTypeCache[t] = set
        return set
    end
    local function docMethodFor(kind, k)
        if type(k) ~= "string" then return nil end
        local chain = docChainCache[kind]
        if not chain then
            chain = DOC_KIND_CHAIN[kind] or { kind, "Frame" }
            docChainCache[kind] = chain
        end
        for _, t in ipairs(chain) do
            if docTypeMethods(t)[k] then
                local key = kind .. "." .. k
                api.stubGaps[key] = (api.stubGaps[key] or 0) + 1
                return emptyDocFn
            end
        end
        return nil
    end

    ---------------------------------------------------------------- 断言二判据：文档 fl.pm
    -- PROTECTED_OP 是我们手抄的：漏一条就是一条假绿（离线看不到实机那批拦截，很可能就漏在这里）。
    -- 文档快照给每个「受保护的方法」挂了 fl.pm，build-engine.js 把「类型 -> 方法名」原样导进
    -- engine-api.lua 的 protectedMethods，这里按 widget 血统链取并集后**与手抄表并联**
    -- （并联而不是替换：SetValue / SetScript / RegisterEvent 这些文档没标 pm，但 AGENTS 的实机
    -- 判例撑得住，删掉就是放宽断言）。命中时把类型名带回给红点当判据。
    --
    -- 血统链只给"帧"这一支补全：文档把 Show 记在 Frame、SetPoint 记在 ScriptRegionResizing、
    -- SetParent 记在 ScriptRegion、SetScale 记在 Region，只查 Frame 会漏掉后面三层。贴图 / 字体
    -- 不补这一层 —— 离线没有任何证据说"挂在受保护框上的 Texture 也算受保护对象"，把它们升成红
    -- 就是拿猜测当结论（与 A2i 同一处理原则）。
    local FRAME_PM_TAIL = { "ScriptRegionResizing", "ScriptRegion", "Region" }
    local NON_FRAME_KIND = {
        Texture = true, Icon = true, AtlasTexture = true, AnimatedTexture = true,
        MaskedTexture = true, MaskTexture = true, Line = true, FontString = true,
        TabardBackground = true, TabardBorder = true, TabardCharter = true, TabardEmblem = true,
    }
    local docPmCache = {}
    docProtectedFor = function(kind, op)
        if type(op) ~= "string" then return nil end
        local set = docPmCache[kind]
        if not set then
            set = {}
            local pmRoot = api.engine.protectedMethods or {}
            local chain = DOC_KIND_CHAIN[kind] or { kind, "Frame" }
            local seen = {}
            local queue = {}
            for i = 1, #chain do queue[#queue + 1] = chain[i] end
            local head = 0
            while head < #queue do
                head = head + 1
                local t = queue[head]
                if not seen[t] then
                    seen[t] = true
                    if t == "Frame" and not NON_FRAME_KIND[kind] then
                        for i = 1, #FRAME_PM_TAIL do queue[#queue + 1] = FRAME_PM_TAIL[i] end
                    end
                    local list = pmRoot[t]
                    if type(list) == "table" then
                        for i = 1, #list do
                            local m = list[i]
                            if type(m) == "string" and set[m] == nil then set[m] = t end
                        end
                    end
                end
            end
            docPmCache[kind] = set
        end
        return set[op]
    end
    api.docProtectedFor = docProtectedFor

    ---------------------------------------------------------------- 字段写入（断言三）
    local metaCache = {}

    local function makeMeta(kind)
        if metaCache[kind] then return metaCache[kind] end
        local mt = {
            __index = function(obj, k)
                local st = STATE[obj]
                local w = st.w
                if w ~= nil and w[k] ~= nil then return w[k] end
                local methods = KIND_METHODS[st.kind] or KIND_METHODS.Frame
                local m = methods and methods[k]
                if m ~= nil then return m end
                -- 暴雪对象的命名子件（Inset / CloseButton / …）惰性建出来
                local blizzChild
                if st.blizzard and api.hooks.blizzChild then
                    local child = api.hooks.blizzChild(st, k)
                    if child then
                        st.w = st.w or {}
                        st.w[k] = child
                        return child
                    end
                    blizzChild = true      -- 世界里没有：下面按"文档有没有这个名字"再分档
                end
                local docFn = docMethodFor(st.kind, k)
                if docFn then return docFn end
                if blizzChild then return nil end          -- 世界里没有、文档里也没有：与真客户端一致
                if type(k) == "string" and k:find("^%u") and not k:find("^__") then
                    -- 自家对象上大写字母开头 = 想要一个 API：记缺口，返回 nil（= 真客户端"没有这个方法"）
                    api.gapMethods[st.kind .. "." .. k] = (api.gapMethods[st.kind .. "." .. k] or 0) + 1
                end
                return nil
            end,
            __newindex = function(obj, k, v)
                local st = STATE[obj]
                local file, line = CallSite(3)
                if st.blizzard and v ~= nil and type(k) == "string" then
                    add("A3", "red", string.format("A3:%s:%s:%s", labelOf(st), tostring(k), tostring(file)), {
                        file = file, line = line, frame = labelOf(st), field = k, kind = st.kind,
                        msg = string.format("直接往暴雪%s「%s」上写字段 %s（应走 ns:Mark）",
                            st.kind, labelOf(st), tostring(k)),
                        value = type(v),
                    })
                elseif st.secure and v ~= nil and type(k) == "string" then
                    add("A3s", "warn", string.format("A3s:%s:%s", labelOf(st), tostring(k)), {
                        file = file, line = line, frame = labelOf(st), field = k,
                        msg = "往 secure 对象上写字段",
                    })
                end
                st.w = st.w or {}
                st.w[k] = v
            end,
        }
        metaCache[kind] = mt
        return mt
    end

    --- 建一个 UI 对象。owner 由调用方决定：暴雪世界对象 blizzard=true。
    function api.NewObject(kind, name, parent, opts)
        opts = opts or {}
        local obj = setmetatable({}, makeMeta(kind))
        local st = {
            kind = kind, name = name, blizzard = opts.blizzard and true or false,
            secure = opts.secure and true or false, template = opts.template,
            -- 暴雪侧的受保护出身：world-data 每行的 prot 位（frames.lua 实例化时传进来）
            protected = opts.protected and true or false,
            parent = parent, children = {}, w = {},
            alpha = opts.alpha or 1, scale = 1, level = opts.level or 1, strata = opts.strata or "MEDIUM",
            shown = opts.shown ~= false, enabled = true, mouse = false,
            wh = { w = opts.w or 100, h = opts.h or 100, cx = 0, cy = 0 },
            points = {}, scripts = {}, attrs = {}, events = {}, text = "", font = { "", 12, "" },
            regions = nil, file = opts.file,
        }
        STATE[obj] = st
        ALL[#ALL + 1] = obj
        if type(name) == "string" and name ~= "" then
            BYNAME[name] = obj
            if not st.blizzard then api.noteGlobalWrite(name, opts) end
        end
        if parent then
            local ps = STATE[parent]
            if ps and ps.children then ps.children[#ps.children + 1] = obj end
        end
        return obj, st
    end

    ---------------------------------------------------------------- 方法表
    local BASE = {}

    -- 读取类：受限也不拦（读是安全的；forbidden 由 CanBeAccessedInContext 表达）
    function BASE.GetObjectType(o) return STATE[o].kind end
    function BASE.GetName(o) local st = STATE[o]; if type(st.name) == "string" and st.name ~= "" then return st.name end return nil end
    function BASE.GetDebugName(o) return labelOf(STATE[o]) end
    function BASE.GetParent(o) return STATE[o].parent end
    -- SetID / GetID 是真数据，不是空实现：背包把 bag/slot 身份装在 ID 上
    -- （Modules/Bags/Bags.lua:403「模板 OnClick 读 self:GetID() + 父壳 GetID()」），
    -- 单位帧的 Boss 按钮也 SetID(0)。给空实现 ⇒ 离线读到 nil，点击分支与实机不同。
    -- 文档还给 Frame:SetID 标了 fl.pm，所以这里必须走 need()：受限窗口写暴雪框的 ID 要能红。
    function BASE.SetID(o, id)
        local st = need(o, "SetID")
        st.id = tonumber(id) or 0
    end
    function BASE.GetID(o) return STATE[o].id or 0 end
    function BASE.SetName(o, n)
        local st = need(o, "SetName")
        st.name = n
        if type(n) == "string" then BYNAME[n] = o end
    end
    function BASE.IsForbidden(o)
        local st = STATE[o]
        -- forbidden 只发生在**受保护**对象上（普通暴雪框在战斗里照样能读，
        -- 把全仓暴雪框都报 forbidden 会让 Widget:Readable 把所有框挂进 5 秒暂停、
        -- 换皮主循环一行都不跑）
        if st.blizzard and st.protected then return api.world.restricted and true or false end
        return false
    end
    function BASE.CanBeAccessedInContext(o)
        local st = STATE[o]
        if st.blizzard and st.protected then return not (api.world.restricted or api.world.lockdown) end
        return true
    end
    -- 逐对象回答，和 world-data 的 prot 位同源；以前这里对一切暴雪对象回 true，
    -- 于是"IsProtected"在离线世界里没有任何信息量，假红全从它来。
    function BASE.IsProtected(o) local st = STATE[o]; return isProtectedObj(st) end
    function BASE.CanChangeProtectedState(o) return (not STATE[o].blizzard) and true or false end

    function BASE.GetAlpha(o) return STATE[o].alpha end
    function BASE.SetAlpha(o, a)
        local st = need(o, "SetAlpha")
        if type(a) ~= "number" then error("bad argument #2 to 'SetAlpha' (number expected)", 2) end
        st.alpha = a
        noteAlpha(st, a, "SetAlpha")
    end
    function BASE.GetEffectiveAlpha(o) return effectiveAlpha(o) end
    function BASE.GetScale(o) return STATE[o].scale end
    function BASE.SetScale(o, s)
        local st = need(o, "SetScale")
        st.scale = tonumber(s) or st.scale
    end
    function BASE.GetEffectiveScale(o)
        local sc, node, hops = 1, o, 0
        while node and hops < 60 do
            local st = STATE[node]
            if not st then break end
            sc = sc * (st.scale or 1)
            node = st.parent
            hops = hops + 1
        end
        return sc
    end
    function BASE.GetFrameLevel(o) return STATE[o].level end
    function BASE.SetFrameLevel(o, l)
        local st = need(o, "SetFrameLevel")
        st.level = tonumber(l) or st.level
    end
    function BASE.GetFrameStrata(o) return STATE[o].strata end
    function BASE.SetFrameStrata(o, s)
        local st = need(o, "SetFrameStrata")
        st.strata = tostring(s)
    end
    function BASE.IsShown(o)
        local st = STATE[o]
        if not st.shown then return false end
        return true
    end
    function BASE.IsVisible(o)
        local st = STATE[o]
        if not st.shown then return false end
        if st.parent then return BASE.IsVisible(st.parent) end
        return true
    end
    function BASE.IsShownForAlpha(o) return effectiveAlpha(o) > 0 end
    local function showHide(o, on, op)
        local st = need(o, op)
        st.shown = on
    end
    function BASE.Show(o) showHide(o, true, "Show") end
    function BASE.Hide(o) showHide(o, false, "Hide") end
    function BASE.SetShown(o, on) showHide(o, on and true or false, "SetShown") end
    function BASE.SetParent(o, p)
        local st = need(o, "SetParent")
        if p and not STATE[p] then error("SetParent: not a widget", 2) end
        local old = st.parent
        if old then
            local os = STATE[old]
            for i = #os.children, 1, -1 do if os.children[i] == o then table.remove(os.children, i) end end
        end
        st.parent = p
        if p then
            local ps = STATE[p]
            ps.children[#ps.children + 1] = o
            if not st.owned then st.secure = st.secure or ps.secure end
        end
    end

    -- 几何：只记账，不做锚点求解（离线近似的边界见 docs/CHECKS.md harness 一节）
    function BASE.SetPoint(o, point, x, y, ...)
        local st = need(o, "SetPoint")
        local anchor = { point = point, x = x, y = y }
        if STATE[x] then
            anchor.to = x
            anchor.toPoint = y
            anchor.ox, anchor.oy = ...
        else
            anchor.relFrame = x
            anchor.relPoint = y
            anchor.ox, anchor.oy = ...
        end
        st.points[#st.points + 1] = anchor
    end
    function BASE.SetAllPoints(o, other)
        local st = need(o, "SetAllPoints")
        st.points = { { allPoints = other and labelOf(STATE[other] or { kind = "?" }) } }
    end
    function BASE.ClearAllPoints(o)
        local st = need(o, "ClearAllPoints")
        st.points = {}
    end
    function BASE.GetNumPoints(o) return #STATE[o].points end
    function BASE.GetPoint(o, i)
        local p = STATE[o].points[i or 1]
        if not p then return nil end
        return p.point, p.to or p.relFrame, p.toPoint or p.relPoint, p.ox, p.oy
    end
    function BASE.GetSize(o)
        local z = STATE[o].wh
        return z.w, z.h
    end
    function BASE.SetSize(o, w, h)
        local st = need(o, "SetSize")
        st.wh.w, st.wh.h = tonumber(w) or st.wh.w, tonumber(h) or st.wh.h
    end
    function BASE.GetWidth(o) return STATE[o].wh.w end
    function BASE.SetWidth(o, v)
        local st = need(o, "SetWidth")
        st.wh.w = tonumber(v) or st.wh.w
    end
    function BASE.GetHeight(o) return STATE[o].wh.h end
    function BASE.SetHeight(o, v)
        local st = need(o, "SetHeight")
        st.wh.h = tonumber(v) or st.wh.h
    end
    function BASE.GetRect(o)
        local st = STATE[o]
        local w, h = st.wh.w, st.wh.h
        local cx, cy = st.wh.cx or 0, st.wh.cy or 0
        return cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    end
    function BASE.GetLeft(o) local l = BASE.GetRect(o); return l end
    function BASE.GetRight(o) local _, r = BASE.GetRect(o); return r end
    function BASE.GetTop(o) local _, _, t = BASE.GetRect(o); return t end
    function BASE.GetBottom(o) local _, _, _, b = BASE.GetRect(o); return b end
    function BASE.GetCenter(o) return STATE[o].wh.cx or 0, STATE[o].wh.cy or 0 end
    -- 人造光标：run.lua 把 api.cursorOver 指到某个框，就当鼠标停在那个框（含其子树）里。
    -- 断言四需要它：离线没有真鼠标，而本仓大量条是"平时 α0、悬停才亮"的设计
    -- （InfoBar 的 mouseover 静息目标就是 0、宠物/姿态条 SetupHoverOnly 同款）。
    -- 只按最终 α 判红会把这些全部冤枉成"美化白挂"。
    function BASE.IsMouseOver(o)
        local target = api.cursorOver
        if not target then return false end
        local node, hops = o, 0
        while node and hops < 40 do
            if node == target then return true end
            local s = STATE[node]
            node = s and s.parent
            hops = hops + 1
        end
        return false
    end
    function BASE.EnableMouse(o, on)
        local st = need(o, "EnableMouse")
        st.mouse = on and true or false
    end
    function BASE.IsMouseEnabled(o) return STATE[o].mouse and true or false end
    function BASE.EnableMouseWheel(o, on) need(o, "EnableMouseWheel") end
    function BASE.EnableKeyboard(o, on) need(o, "EnableKeyboard") end
    function BASE.SetPropagateMouseMotion() end
    function BASE.SetPropagateMouseClicks() end
    function BASE.SetClampedToScreen(o, on) need(o, "SetClampedToScreen") end
    function BASE.IsClampedToScreen() return false end
    function BASE.SetMovable(o, on) need(o, "SetMovable") end
    function BASE.StartMoving() end
    function BASE.StopMovingOrSizing() end
    function BASE.SetToplevel(o, on) need(o, "SetToplevel") end
    function BASE.SetUserPlaced(o, on) need(o, "SetUserPlaced") end
    function BASE.SetUserCreated(o, on) need(o, "SetUserCreated") end
    function BASE.SetHitRectInsets(o, ...) need(o, "SetHitRectInsets") end
    function BASE.GetHitRectInsets() return 0, 0, 0, 0 end
    function BASE.SetClampRectInsets(o, ...) need(o, "SetClampRectInsets") end
    function BASE.GetClampRectInsets() return 0, 0, 0, 0 end

    -- 子件 / 区域
    -- 真客户端的 GetChildren/GetRegions 回的是**多个值**而不是一个 table：仓库里既有
    -- `{ f:GetRegions() }`（Skin.lua 404/1973/2009），也有 `select("#", f:GetRegions())`
    -- （ActionBars.lua 2052/2105、2105 之后按 i 取）。只回一个 table 会让 select 永远数到 1，
    -- "区域为空就跳过"那条分支离线永远走不到。所以内部出表（run.lua 要用），公开方法摊成变参。
    local FRAME_KINDS = {
        Frame = true, Button = true, CheckButton = true, StatusBar = true, EditBox = true,
        Slider = true, ScrollFrame = true, ScrollMessage = true, Minimap = true,
        DropDownList = true, PlayerModel = true, ModelSceneFrame = true, Icon = true,
        Item = true, ItemButton = true, Cooldown = true,
    }
    local REGION_KINDS = { Texture = true, FontString = true, MaskTexture = true, Line = true, AtlasTexture = true }
    local function listOf(o, wantFrame)
        local st = STATE[o]
        if st.blizzard and api.hooks.blizzList then return api.hooks.blizzList(st, wantFrame and "frame" or "region") end
        local out = {}
        for _, c in ipairs(st.children) do
            local k = STATE[c].kind
            if wantFrame then
                if FRAME_KINDS[k] then out[#out + 1] = c end
            elseif REGION_KINDS[k] then
                out[#out + 1] = c
            end
        end
        return out
    end
    local function childrenOf(o) return listOf(o, true) end
    local function regionsOf(o) return listOf(o, false) end
    api.childrenOf = childrenOf
    api.regionsOf = regionsOf
    api.FRAME_KINDS = FRAME_KINDS
    api.REGION_KINDS = REGION_KINDS
    function BASE.GetChildren(o)
        local t = childrenOf(o)
        return table.unpack(t, 1, #t)
    end
    function BASE.GetRegions(o)
        local t = regionsOf(o)
        return table.unpack(t, 1, #t)
    end
    function BASE.GetNumChildren(o) return #childrenOf(o) end
    function BASE.GetFontStrings(o)
        local out = {}
        for _, r in ipairs(regionsOf(o)) do
            if STATE[r].kind == "FontString" then out[#out + 1] = r end
        end
        return table.unpack(out, 1, #out)
    end
    function BASE.GetTextures(o)
        local out = {}
        for _, r in ipairs(regionsOf(o)) do
            local k = STATE[r].kind
            if k == "Texture" or k == "MaskTexture" or k == "AtlasTexture" then out[#out + 1] = r end
        end
        return table.unpack(out, 1, #out)
    end

    -- 脚本 / 事件
    function BASE.GetScript(o, name) return STATE[o].scripts[name] end
    function BASE.SetScript(o, name, fn)
        local st = need(o, "SetScript")
        st.scripts[name] = fn
        if name == "OnUpdate" then
            if fn then
                if not st.inUpd then st.inUpd = true; api.onUpdate[o] = st end
            else
                st.inUpd = nil
                api.onUpdate[o] = nil
            end
        end
    end
    function BASE.HookScript(o, name, fn)
        -- 先记账再拒绝：这条红是"挂脚本"这个动作本身的违规，与"能不能写"无关。
        -- 顺序反过来时 need() 先抛，样例只会留下一条"加载期抛错"，断言三自己变成假绿。
        local stHook = STATE[o]
        if stHook and stHook.blizzard then
            local file, line, guarded, swallowedAt = CallSite(3)
            add("A3h", "red", string.format("A3h:%s:%s:%s", labelOf(stHook), name, tostring(line)), {
                file = file, line = line, frame = labelOf(stHook), op = "HookScript", script = name,
                guarded = guarded, swallowedAt = swallowedAt,
                msg = string.format("HookScript 挂到暴雪%s「%s」的 %s 上（AGENTS：改用轮询）",
                    stHook.kind, labelOf(stHook), name),
            })
        end
        local st = need(o, "HookScript")
        local old = st.scripts[name]
        st.scripts[name] = function(...)
            if old then old(...) end
            return fn(...)
        end
    end
    local function addEvent(st, event, unit)
        st.events = st.events or {}
        local list = st.events[event]
        if not list then list = {}; st.events[event] = list end
        list[#list + 1] = unit
    end
    local function watchEvents(o, st)
        api.eventRegs[o] = st
    end
    function BASE.RegisterEvent(o, event, ...)
        local st = need(o, "RegisterEvent")
        st.events = st.events or {}
        local list = st.events[event]
        if not list then list = {}; st.events[event] = list end
        api.eventRegs[o] = st
    end
    function BASE.RegisterUnitEvent(o, event, ...)
        local st = need(o, "RegisterUnitEvent")
        st.events = st.events or {}
        local list = st.events[event]
        if not list then list = {}; st.events[event] = list end
        for i = 1, select("#", ...) do list[#list + 1] = select(i, ...) end
        st.unitFiltered = st.unitFiltered or {}
        st.unitFiltered[event] = true
        api.eventRegs[o] = st
    end
    function BASE.UnregisterEvent(o, event)
        local st = need(o, "UnregisterEvent")
        if st.events then st.events[event] = nil end
    end
    function BASE.UnregisterAllEvents(o)
        local st = need(o, "UnregisterAllEvents")
        st.events = {}
        api.eventRegs[o] = nil
    end
    function BASE.RegisterStateDriver(o, ...)
        local st = need(o, "RegisterStateDriver")
        st.stateDrivers = st.stateDrivers or {}
        local key = select(1, ...)
        st.stateDrivers[key] = select(2, ...)
    end
    function BASE.UnregisterStateDriver(o, key)
        local st = need(o, "UnregisterStateDriver")
        if st.stateDrivers then st.stateDrivers[key] = nil end
    end
    function BASE.SetAttribute(o, key, value)
        local st = need(o, "SetAttribute")
        st.attrs[key] = value
    end
    function BASE.GetAttribute(o, key) return STATE[o].attrs[key] end
    function BASE.SetAttributeMismatch(o, ...) need(o, "SetAttributeMismatch") end
    function BASE.RegisterForClicks(o, ...) need(o, "RegisterForClicks") end
    function BASE.RegisterForDrag(o, ...) need(o, "RegisterForDrag") end
    function BASE.SetOverrideBinding() end
    function BASE.GetOverrideBinding() return nil end

    -- 背景板
    function BASE.SetBackdrop(o, tbl)
        local st = need(o, "SetBackdrop")
        st.backdrop = type(tbl) == "table" and tbl or nil
    end
    function BASE.GetBackdrop(o) return STATE[o].backdrop end
    function BASE.SetBackdropColor(o, r, g, b, a)
        local st = need(o, "SetBackdropColor")
        st.bdColor = { r, g, b, a }
    end
    function BASE.GetBackdropColor(o)
        local c = STATE[o].bdColor
        if c then return c[1], c[2], c[3], c[4] end
        return 0, 0, 0, 0
    end
    function BASE.SetBackdropBorderColor(o, r, g, b, a)
        local st = need(o, "SetBackdropBorderColor")
        st.bdEdge = { r, g, b, a }
    end
    function BASE.GetBackdropBorderColor(o)
        local c = STATE[o].bdEdge
        if c then return c[1], c[2], c[3], c[4] end
        return 1, 1, 1, 1
    end

    -- 通用"存在性"问答
    function BASE.IsEnabled(o) return STATE[o].enabled and true or false end
    function BASE.Enable(o, on)
        local st = STATE[o]
        if on == false then st.enabled = false else st.enabled = true end
    end
    function BASE.Disable(o) STATE[o].enabled = false end
    function BASE.SetEnabled(o, on) STATE[o].enabled = on and true or false end

    api.BASE = BASE
    api.PROTECTED_OP = PROTECTED_OP
    api.CONTENT_OP = CONTENT_OP
    api.labelOf = labelOf
    api.CallSite = CallSite
    api.need = need
    api.MakeSecret = MakeSecret
    api.restrictionBlocks = restrictionBlocks

    ---------------------------------------------------------------- 区域 / 控件方法
    -- AGENTS：GetAlpha 与顶点色 alpha 是同一份存储 ⇒ 两者读写同一个 st.alpha
    local REGION = {}
    for k, v in pairs(BASE) do REGION[k] = v end
    REGION.SetVertexColor = function(o, r, g, b, a)
        local st = need(o, "SetVertexColor")
        st.vc = { r or 1, g or 1, b or 1, a or st.alpha }
        if a ~= nil then
            st.alpha = a
            noteAlpha(st, a, "SetVertexColor")
        end
    end
    REGION.GetVertexColor = function(o)
        local st = STATE[o]
        local c = st.vc
        if c then return c[1], c[2], c[3], c[4] end
        return 1, 1, 1, st.alpha
    end
    REGION.SetTexture = function(o, tex, ...)
        local st = need(o, "SetTexture")
        if type(tex) == "table" then
            st.texture = labelOf(STATE[tex] or { kind = "Texture", name = "表" })
        elseif type(tex) == "string" or type(tex) == "number" then
            st.texture = tostring(tex)
        else
            st.texture = nil
        end
        if api.hooks.knownTexture then
            local ok, bad = pcall(api.hooks.knownTexture, st)
            if not ok then error(bad, 0) end
        end
    end
    REGION.GetTexture = function(o) return STATE[o].texture end
    REGION.SetColorTexture = function(o, r, g, b, a)
        local st = need(o, "SetColorTexture")
        st.texture = "color"
        st.vc = { r or 1, g or 1, b or 1, a or st.alpha }
        if a ~= nil then
            st.alpha = a
            noteAlpha(st, a, "SetColorTexture")
        end
    end
    REGION.SetTexCoord = function(o, ...)
        local st = need(o, "SetTexCoord")
        st.texcoord = { ... }
    end
    REGION.GetTexCoord = function(o)
        local t = STATE[o].texcoord or { 0, 0, 1, 1 }
        return t[1], t[2], t[3], t[4]
    end
    REGION.SetAtlas = function(o, name, ...)
        local st = need(o, "SetAtlas")
        st.atlas = name
        st.texture = "atlas:" .. tostring(name)
    end
    REGION.GetAtlas = function(o) return STATE[o].atlas end
    REGION.SetFromAtlas = REGION.SetAtlas
    REGION.SetBlendMode = function(o, m) need(o, "SetBlendMode") end
    REGION.GetBlendMode = function() return "BLEND" end
    REGION.SetDesaturated = function(o, on) STATE[o].desat = on and true or false end
    REGION.IsDesaturated = function(o) return STATE[o].desat end
    REGION.SetSnapToPixelGrid = function() end
    REGION.SetTexelSnapStyle = function() end
    REGION.SetNonPixelSnapSize = function() end
    REGION.SetIgnoreTilePixel = function() end
    REGION.SetGradient = function(o, ...) STATE[o].gradient = { ... } end
    REGION.SetVertexOffset = function() end
    REGION.SetDrawLayer = function(o, layer, ...) STATE[o].drawLayer = layer end
    REGION.GetDrawLayer = function(o) return STATE[o].drawLayer or "ARTWORK" end
    REGION.HideAll = function() end

    local FONT = {}
    for k, v in pairs(REGION) do FONT[k] = v end
    FONT.SetText = function(o, t)
        local st = need(o, "SetText")
        if api.secretSeen(t) then
            local f, l, g, s = CallSite(3)
            add("A1s", "red", string.format("A1s:SetText:%s:%s", tostring(f), tostring(l)), {
                file = f, line = l, guarded = g, swallowedAt = s,
                msg = "把机密值直接写进 FontString（应先过 Secrets）",
            })
        end
        st.text = t == nil and "" or tostring(t)
    end
    FONT.SetFormattedText = function(o, fmt, ...)
        local st = need(o, "SetFormattedText")
        local ok, s = pcall(string.format, fmt, ...)
        st.text = ok and s or tostring(fmt)
    end
    FONT.GetText = function(o) return STATE[o].text end
    FONT.IsTextEmpty = function(o) return (STATE[o].text or "") == "" end
    FONT.SetFont = function(o, path, size, flag, ...)
        local st = STATE[o]
        st.font = { path, tonumber(size) or 12, flag }
    end
    FONT.GetFont = function(o)
        local f = STATE[o].font
        return f[1], f[2], f[3]
    end
    FONT.SetTextColor = function(o, r, g, b, a)
        local st = STATE[o]
        st.tc = { r, g, b, a }
        if a ~= nil then
            st.alpha = a
            noteAlpha(st, a, "SetTextColor")
        end
    end
    FONT.GetTextColor = function(o)
        local st = STATE[o]
        local c = st.tc
        if c then return c[1], c[2], c[3], c[4] end
        return 1, 1, 1, st.alpha
    end
    FONT.SetRGBA = function(o, tbl)
        local st = STATE[o]
        st.tc = { tbl.r, tbl.g, tbl.b, tbl.a }
        if tbl.a ~= nil then
            st.alpha = tbl.a
            noteAlpha(st, tbl.a, "SetRGBA")
        end
    end
    FONT.GetRGBA = function(o)
        local c = STATE[o].tc or { r = 1, g = 1, b = 1, a = 1 }
        return { r = c[1], g = c[2], b = c[3], a = c[4] }
    end
    FONT.SetSpaceWidth = function() end
    FONT.SetSpacing = function() end
    FONT.SetShadowColor = function(o, r, g, b, a)
        local st = need(o, "SetShadowColor")
        st.shadow = { r or 0, g or 0, b or 0, a == nil and 1 or a }
    end
    -- 阴影颜色必须真存真取：Utils/Skin.lua:474 先 GetShadowColor 存旧值、稍后再 SetShadowColor
    -- 还原。这里回 nil 的话"还原"就变成 SetShadowColor(nil,nil,nil,nil)，离线看不出坏、实机是糊掉的字。
    FONT.GetShadowColor = function(o)
        local s = STATE[o].shadow or { 0, 0, 0, 1 }
        return s[1], s[2], s[3], s[4]
    end
    FONT.SetShadowOffset = function(o, x, y)
        local st = need(o, "SetShadowOffset")
        st.shadowOffset = { x or 0, y or 0 }
    end
    FONT.GetShadowOffset = function(o)
        local s = STATE[o].shadowOffset or { 0, 0 }
        return s[1], s[2]
    end
    FONT.SetOutline = function() end
    FONT.GetNumLines = function() return 1 end
    FONT.GetWidthString = function(o) return #(STATE[o].text or "") * 6 end
    FONT.GetStringWidth = function(o, t) return #(tostring(t or "")) * 6 end
    FONT.GetStringHeight = function(o, t)
        local f = STATE[o].font
        return tonumber((select(2, tostring(t or ""):find("\n")))) * (f and f[2] or 12) + (f and f[2] or 12)
    end
    FONT.SetJustifyH = function(o, j) STATE[o].justH = j end
    FONT.GetJustifyH = function(o) return STATE[o].justH or "CENTER" end
    FONT.SetJustifyV = function(o, j) STATE[o].justV = j end
    FONT.GetJustifyV = function(o) return STATE[o].justV or "MIDDLE" end
    FONT.SetWordWrap = function(o, on) STATE[o].wrap = on end
    FONT.GetWordWrap = function(o) return STATE[o].wrap end
    FONT.SetNonSpaceWrap = function(o, on) STATE[o].nonSpaceWrap = on end
    FONT.SetIndentedWordWrap = function() end
    FONT.SetMaxLines = function(o, n) STATE[o].maxLines = n end
    FONT.SetMaxLineLength = function() end
    FONT.AddFontString = function() end
    FONT.SetHeightForObject = function() end
    FONT.GetTextRect = function(o) return 0, 0, 0, 0 end
    FONT.SetTextAlignment = function() end
    FONT.GetContentRect = function(o) return 0, 0, 100, 20 end

    local TEX = {}
    for k, v in pairs(REGION) do TEX[k] = v end

    local BTN = {}
    for k, v in pairs(BASE) do BTN[k] = v end
    BTN.SetDisabled = function(o, on)
        local st = STATE[o]
        st.enabled = not (on and true or false)
        st.disabled = on and true or false
    end
    BTN.IsDisabled = function(o) return STATE[o].disabled and true or false end
    BTN.SetChecked = function(o, on)
        local st = need(o, "SetChecked")
        st.checked = on and true or false
    end
    BTN.GetChecked = function(o) return STATE[o].checked and true or false end
    BTN.SetAutoRepeat = function() end
    BTN.SetMotionScriptsWhileDisabled = function() end
    BTN.SetButtonState = function(o, s) STATE[o].state = s end
    BTN.GetButtonState = function(o) return STATE[o].state or "normal" end
    BTN.SetText = function(o, t)
        local st = STATE[o]
        if api.secretSeen(t) then
            local f, l = CallSite(3)
            add("A1s", "red", string.format("A1s:SetButtonText:%s:%s", tostring(f), tostring(l)), {
                file = f, line = l, msg = "把机密值写进按钮文字",
            })
        end
        st.text = t == nil and "" or tostring(t)
        -- 文字实体是那个 FontString 子件（客户端如此）：GetFontString 建过就得同步，否则皮肤层
        -- 从子件读到的是旧字，断言四看到的也不是同一处写入。
        if st.fontString then STATE[st.fontString].text = st.text end
    end
    BTN.GetText = function(o) return STATE[o].text end
    -- Button:GetFontString()：客户端把按钮文字放在一个 FontString 子件上，Utils/Skin.lua 的
    -- ButtonText 就是靠它拿字体对象（先看 .Text，再看 GetFontString）。以前只记 stubGaps 返回
    -- nil ⇒ 全插件的按钮字体分支离线一条都没跑过（×3660 次调用）。补上之后这些写入进断言四的
    -- α 漏斗与断言二的保护闸门，才是真的被执行。
    BTN.GetFontString = function(o)
        local st = STATE[o]
        if st.fontString then return st.fontString end
        local fs = api.NewObject("FontString", nil, o, {
            blizzard = st.blizzard and true or false,
            protected = st.protected and true or false,
        })
        STATE[fs].text = st.text or ""
        st.fontString = fs
        return fs
    end
    BTN.GetTextFontObject = function(o)
        local st = STATE[o]
        if st.fontString then return STATE[st.fontString].fontObject end
        return nil
    end
    BTN.GetFont = function(o) local f = STATE[o].font or { nil, 12, nil }; return f[1], f[2], f[3] end
    BTN.SetFont = function(o, p, s, fl) STATE[o].font = { p, s, fl } end
    BTN.SetFontObject = function() end
    BTN.SetHighlightColor = function() end
    BTN.SetNormalTexture = function(o, t)
        local st = need(o, "SetNormalTexture")
        st.art = st.art or {}
        st.art.normal = t
    end
    BTN.SetHighlightTexture = function(o, t)
        local st = need(o, "SetHighlightTexture")
        st.art = st.art or {}
        st.art.highlight = t
    end
    BTN.SetPushedTexture = function(o, t)
        local st = need(o, "SetPushedTexture")
        st.art = st.art or {}
        st.art.pushed = t
    end
    BTN.SetDisabledTexture = function(o, t)
        local st = need(o, "SetDisabledTexture")
        st.art = st.art or {}
        st.art.disabled = t
    end
    BTN.SetCheckedTexture = function(o, t)
        local st = need(o, "SetCheckedTexture")
        st.art = st.art or {}
        st.art.checked = t
    end
    local function artOf(st, slot)
        local a = st.art and st.art[slot]
        if a ~= nil then return a end
        -- 世界数据里的美术槽（build-world.js 记在宿主行 slots 上）
        if st.blizzard and api.hooks.blizzArt then return api.hooks.blizzArt(st, slot) end
        if st.blizzard then return nil end
        return nil
    end
    BTN.GetNormalTexture = function(o) return artOf(STATE[o], "normal") end
    BTN.GetHighlightTexture = function(o) return artOf(STATE[o], "highlight") end
    BTN.GetPushedTexture = function(o) return artOf(STATE[o], "pushed") end
    BTN.GetDisabledTexture = function(o) return artOf(STATE[o], "disabled") end
    BTN.GetCheckedTexture = function(o) return artOf(STATE[o], "checked") end
    BTN.SetFrameDuration = function() end
    BTN.GetFrameDuration = function() return 0 end
    BTN.SetClickOptions = function() end
    BTN.GetClickOptions = function() return "LEFT" end
    BTN.SetRightButton = function() end
    BTN.GetRightButton = function() return nil end
    BTN.SetNewBragLevel = function() end
    BTN.SetHasOffTalent = function() end
    BTN.UpdateTooltip = function() end
    BTN.SetTooltipAnchor = function() end

    local SB = {}
    for k, v in pairs(BASE) do SB[k] = v end
    SB.SetValue = function(o, v, interp)
        local st = need(o, "SetValue")
        if api.secretSeen(v) and interp == nil and not st.blizzard then
            -- 机密值裸喂 SetValue：客户端吃得下，但没插值就没有"引擎侧缓动"，
            -- 与 Secrets.SetBar 的三段兜底对照记一条信息账（不判红，避免假红）。
            local f, l, g = CallSite(3)
            add("A1b", "info", string.format("A1b:SetValue:%s:%s", tostring(f), tostring(l)), {
                file = f, line = l, guarded = g,
                msg = "机密值直接 SetValue（未走 Secrets.SetBar 的插值路径）",
            })
        end
        st.value = v
    end
    SB.GetValue = function(o) return STATE[o].value end
    SB.SetMinMaxValues = function(o, minv, maxv, interp)
        local st = need(o, "SetMinMaxValues")
        st.min, st.max = minv, maxv
    end
    SB.GetMinMaxValues = function(o)
        local st = STATE[o]
        return st.min or 0, st.max or 1
    end
    SB.SetStatusBarColor = function(o, r, g, b, a)
        local st = need(o, "SetStatusBarColor")
        st.barColor = { r, g, b, a }
    end
    SB.GetStatusBarColor = function(o)
        local c = STATE[o].barColor
        if c then return c[1], c[2], c[3], c[4] end
        return 1, 1, 1, 1
    end
    SB.SetStatusBarTexture = function(o, t) need(o, "SetStatusBarTexture") end
    SB.GetStatusBarTexture = function(o) return STATE[o].barTex end
    SB.SetStatusBarDesaturated = function() end
    SB.SetOrientation = function(o, orient) STATE[o].orient = orient end
    SB.GetOrientation = function(o) return STATE[o].orient or "HORIZONTAL" end
    SB.SetRotation = function(o, d) STATE[o].rotation = d end
    SB.GetRotation = function(o) return STATE[o].rotation or 0 end
    SB.SetUseBackgroundColorAlpha = function() end
    SB.SetFractionDisplayType = function() end
    SB.GetNormalizedValue = function(o)
        local st = STATE[o]
        local v = tonumber(st.value), tonumber(st.max)
        if v and st.max and st.max > 0 then return v / st.max end
        return 0
    end
    SB.SetBarFillMode = function() end

    local EB = {}
    for k, v in pairs(FONT) do EB[k] = v end
    EB.GetText = function(o) return STATE[o].text end
    EB.SetText = function(o, t)
        local st = STATE[o]
        st.text = t == nil and "" or tostring(t)
    end
    EB.SetNumber = function(o, n) STATE[o].text = tostring(n) end
    EB.GetNumber = function(o) return tonumber(STATE[o].text) or 0 end
    EB.SetNumeric = function() end
    EB.SetFocus = function() end
    EB.ClearFocus = function() end
    EB.HasFocus = function() return false end
    EB.SetCursorPosition = function() end
    EB.GetCursorPosition = function() return 0 end
    EB.GetHistoryLines = function() return 0 end
    EB.SetHistoryLines = function() end
    EB.SetMaxBytes = function() end
    EB.SetMaxLetters = function() end
    EB.GetMaxBytes = function() return 0 end
    EB.GetSelectedText = function() return "" end
    EB.SetTextFocus = function() end
    EB.Insert = function(o, t) STATE[o].text = (STATE[o].text or "") .. tostring(t) end
    EB.SetPlaceholder = function() end
    EB.GetPlaceholder = function() return "" end
    EB.SetMaxLetters = function() end

    local SL = {}
    for k, v in pairs(BASE) do SL[k] = v end
    SL.SetValue = function(o, v) STATE[o].value = v end
    SL.GetValue = function(o) return STATE[o].value or 0 end
    SL.SetMinMaxValues = function(o, a, b) STATE[o].min, STATE[o].max = a, b end
    SL.GetMinMaxValues = function(o) return STATE[o].min or 0, STATE[o].max or 1 end
    SL.SetValueStep = function() end
    SL.SetOrientation = function() end
    SL.GetOrientation = function() return "VERTICAL" end
    SL.SetThumbTexture = function(o, t) STATE[o].thumb = t end
    SL.GetThumbTexture = function(o) return STATE[o].thumb end
    SL.GetThumbnailSize = function() return 10, 20 end
    SL.SetTicks = function() end
    SL.Show = function(o) BASE.Show(o) end

    local SF = {}
    for k, v in pairs(BASE) do SF[k] = v end
    SF.SetScrollChild = function(o, c)
        local st = STATE[o]
        st.scrollChild = c
        if c then
            local cs = STATE[c]
            cs.parent = o
            st.children[#st.children + 1] = c
        end
    end
    SF.GetScrollChild = function(o) return STATE[o].scrollChild end
    SF.SetVerticalScroll = function(o, v) STATE[o].scroll = v end
    SF.GetVerticalScroll = function(o) return STATE[o].scroll or 0 end
    SF.GetMaxVerticalScroll = function(o) return 0 end
    SF.GetVerticalScrollRange = function(o) return 0 end
    SF.UpdateScrollChildRect = function() end
    SF.ScrollBy = function() end

    local CD = {}
    for k, v in pairs(BASE) do CD[k] = v end
    CD.SetCooldown = function(o, start, dur, mod)
        local st = STATE[o]
        st.cdStart, st.cdDuration = start, dur
    end
    -- GetCooldownTimes 给的是**毫秒**（Modules/Cooldown/Cooldown.lua:285 记着实机判例
    -- 48680011 / 360000，而 GetTime() 与 SetCooldown 用秒）。以前这里只记 stubGaps 返回 nil
    -- ⇒ 那条"按剩余时间决定倒计时"的分支离线一次没跑（×1648 次调用）。
    CD.GetCooldownTimes = function(o)
        local st = STATE[o]
        if not st.cdStart then return 0, 0 end
        return math.floor((st.cdStart or 0) * 1000 + 0.5), math.floor((st.cdDuration or 0) * 1000 + 0.5)
    end
    CD.SetCooldownDuration = function(o, dur, mod)
        local st = need(o, "SetCooldownDuration")
        st.cdStart, st.cdDuration = api.world.time, dur
    end
    CD.SetCooldownUNIX = function(o, start, dur)
        local st = need(o, "SetCooldownUNIX")
        st.cdStart = (start or 0) / 1000
        st.cdDuration = (dur or 0) / 1000
    end
    CD.GetCooldownDuration = function(o) return STATE[o].cdDuration or 0 end
    CD.GetExpirationTime = function(o)
        local st = STATE[o]
        if not st.cdDuration or st.cdDuration == 0 then return nil end
        return (st.cdStart or 0) + st.cdDuration
    end
    CD.IsReady = function(o)
        local st = STATE[o]
        if not st.cdDuration or st.cdDuration == 0 then return true end
        return (st.cdStart or 0) + st.cdDuration <= api.world.time
    end
    CD.Clear = function(o) STATE[o].cdStart, STATE[o].cdDuration = nil, nil end
    CD.SetHideCountdownNumbers = function(o, on) STATE[o].hideNumbers = on end
    -- Modules/Cooldown/Cooldown.lua:326 读它决定"要不要把倒计时数字补回来"：给 nil 等于
    -- 永远走补回来的分支，实机却可能已经是 true。存什么回什么。
    CD.GetHideCountdownNumbers = function(o) return STATE[o].hideNumbers and true or false end
    CD.GetReverseSlotRecorder = function() return nil end
    CD.SetSwipeTexture = function() end
    CD.GetSwipeTexture = function() return nil end
    CD.SetSwipeColor = function() end
    CD.SetDrawEdge = function() end
    CD.SetDrawSwipe = function() end
    CD.SetEdgeSize = function() end
    CD.SetCountdownThreshold = function() end
    CD.SetReverse = function() end
    CD.SetModelSceneFrame = function() end

    local MS = {}
    for k, v in pairs(BASE) do MS[k] = v end
    MS.SetModelScale = function() end
    MS.SetCameraDistance = function() end
    MS.SetPosition = function() end
    MS.TrySetUnit = function() return false end
    MS.SetDisplayID = function() end
    MS.SetAppearanceByID = function() end
    MS.RefreshActor = function() end
    MS.ClearModel = function() end
    MS.IsModelCleared = function() return true end
    MS.SetAnimation = function() end
    MS.SetFacing = function() end
    MS.SetOrigin = function() end

    -- kind → 方法表
    local function extend(...)
        local t = {}
        for _, src in ipairs({ ... }) do
            for k, v in pairs(src) do t[k] = v end
        end
        return t
    end
    KIND_METHODS.Frame = extend(BASE)
    KIND_METHODS.Minimap = extend(BASE)
    KIND_METHODS.Texture = extend(TEX)
    KIND_METHODS.Line = extend(TEX)
    KIND_METHODS.AtlasTexture = extend(TEX)
    KIND_METHODS.MaskTexture = extend(TEX, { SetMaskTexture = function() end })
    KIND_METHODS.FontString = extend(FONT)
    KIND_METHODS.ScrollMessage = extend(FONT)
    KIND_METHODS.Button = extend(BTN, REGION, { CreateTexture = true })
    KIND_METHODS.ItemButton = KIND_METHODS.Button
    KIND_METHODS.Item = KIND_METHODS.Button
    KIND_METHODS.Icon = KIND_METHODS.Texture
    KIND_METHODS.CheckButton = extend(BTN, REGION, { CreateTexture = true })
    KIND_METHODS.StatusBar = extend(SB, BASE)
    KIND_METHODS.EditBox = extend(EB, BASE)
    KIND_METHODS.Slider = extend(SL, BASE)
    KIND_METHODS.ScrollFrame = extend(SF, BASE)
    KIND_METHODS.Cooldown = extend(CD, BASE)
    KIND_METHODS.DDropDownList = nil
    KIND_METHODS.DropDownList = extend(BASE)
    KIND_METHODS.PlayerModel = extend(MS, BASE)
    KIND_METHODS.ModelSceneFrame = extend(MS, BASE)
    KIND_METHODS.TabardAtlas = KIND_METHODS.Texture
    KIND_METHODS.TabardBackground = KIND_METHODS.Texture
    KIND_METHODS.TabardBorder = KIND_METHODS.Texture
    KIND_METHODS.TabardCharter = KIND_METHODS.Texture
    KIND_METHODS.TabardEmblem = KIND_METHODS.Texture
    KIND_METHODS.GameTip = extend(BASE)
    KIND_METHODS.SpellBookPaginate = KIND_METHODS.Button
    KIND_METHODS.AnimatedTexture = KIND_METHODS.Texture
    KIND_METHODS.MaskedTexture = KIND_METHODS.Texture

    -- CreateTexture/CreateFontString/CreateLine 挂在容器类上
    local function creator(kindName, table_)
        return function(o, ...)
            local st = need(o, "Create" .. kindName)
            local name = select(1, ...)
            local child = api.NewObject(kindName, name, o, {})
            return child
        end
    end
    for _, kind in ipairs({ "Frame", "Button", "CheckButton", "StatusBar", "EditBox", "Slider", "ScrollFrame", "Minimap", "ScrollMessage" }) do
        local m = KIND_METHODS[kind]
        if m then
            m.CreateTexture = creator("Texture", TEX)
            m.CreateFontString = creator("FontString", FONT)
            m.CreateLine = creator("Line", TEX)
            m.CreateMaskTexture = creator("MaskTexture", TEX)
            m.CreateAtlas = creator("AtlasTexture", TEX)
            m.SetMaskTexture = function(o, tex) need(o, "SetMaskTexture") end
            m.GetMaskTexture = function() return nil end
        end
    end
    KIND_METHODS.Texture.CreateMaskTexture = nil
    KIND_METHODS.FontString.CreateMaskTexture = nil

    ---------------------------------------------------------------- 保护闸门（断言二的执行面）
    -- 上面每个方法各自记得不记得调 need()，是这条断言最脆的地方：漏一个（CD.SetCooldown、
    -- BTN.SetEnabled、SF.SetVerticalScroll 这类文档标了 fl.pm 的），受限窗口里真会被拦的写入
    -- 就从台账里静默消失 —— 判据升级成文档证据也救不回来。所以方法表装配完统一包一层：
    -- 只要「对象可能受保护 + 当前受限 + 这个名字被任一判据认定为受保护操作」，进函数先过 need()。
    -- 名字不在判据里的（读方法、内容写入）不包，热路径不多一跳；同一张表（别名共享）只包一次。
    local gatedTables = {}
    local function gateMethodTable(t)
        if gatedTables[t] then return end
        gatedTables[t] = true
        for name, f in pairs(t) do
            if type(f) == "function" then
                t[name] = function(...)
                    local self = select(1, ...)
                    local st = type(self) == "table" and STATE[self] or nil
                    -- 判"这一刀是不是受保护级"用两份判据的并集，然后一律交给 need()：
                    -- 真受保护对象它会拒绝并记 A2 红，prot=0 的暴雪框它只记 A2n 黄。
                    -- 在这里就按 restrictionBlocks 短路的话，非受保护那一档连黄都不留。
                    if st and (st.blizzard or st.secure)
                        and (PROTECTED_OP[name] or docProtectedFor(st.kind, name))
                        and (api.world.lockdown or api.world.restricted) then
                        need(self, name)          -- 未守卫就 error，账已经记过
                    end
                    return f(...)
                end
            end
        end
    end
    for _, t in pairs(KIND_METHODS) do
        if type(t) == "table" then gateMethodTable(t) end
    end
    api.gateMethodTable = gateMethodTable

    ---------------------------------------------------------------- 全局 API
    local env = {}
    api.env = env

    local function rawsetenv(k, v) rawset(env, k, v) end
    env._G = env

    -- 标准库（5.1 兼容面：本仓源码按 5.1 写，客户端是 Lua 5.1；宿主是 5.4）
    local base = {}
    for _, name in ipairs({ "type", "pairs", "ipairs", "next", "pcall", "xpcall", "error", "select",
                            "tostring", "tonumber", "rawget", "rawset", "rawequal", "rawlen",
                            "setmetatable", "getmetatable", "assert", "unpack", "load", "print" }) do
        base[name] = _G[name]
    end
    base.unpack = _G.table.unpack
    base.load = _G.load
    local function copyLib(dst, src)
        local t = setmetatable({}, { __index = src })
        for k, v in pairs(src) do t[k] = v end
        return t
    end
    base.table = setmetatable({}, { __index = _G.table })
    for k, v in pairs(_G.table) do base.table[k] = v end
    base.string = setmetatable({}, { __index = _G.string })
    for k, v in pairs(_G.string) do base.string[k] = v end
    base.math = setmetatable({}, { __index = _G.math })
    for k, v in pairs(_G.math) do base.math[k] = v end
    base.os = setmetatable({}, { __index = _G.os })
    for k, v in pairs(_G.os) do base.os[k] = v end
    base.coroutine = _G.coroutine
    base.debug = _G.debug

    -- 5.1 别名：客户端里没有的也不该让 harness 先炸
    base.table.getn = function(t) return #t end
    base.math.pow = function(a, b) return a ^ b end
    base.string.gfind = base.string.gmatch
    base.strtrim = function(s, t)
        t = t or " \255"
        return (string.gsub(string.gsub(s, "^" .. t .. "+", ""), t .. "+$", ""))
    end
    base.StrTrim = base.strtrim
    base.strsplit = function(delimiter, s, finish)
        if type(s) ~= "string" then return nil end
        local pos = string.find(s, delimiter, nil, true)
        if not pos then return s end
        local lastpos = 1
        finish = finish or string.len(s)
        return function()
            local e = string.find(s, delimiter, lastpos, true)
            if e == nil or lastpos > finish then return nil end
            local str = string.sub(s, lastpos, e - 1)
            lastpos = e + 1
            return str
        end
    end
    base.strjoin = function(sep, ...)
        local out = {}
        for i = 1, select("#", ...) do out[i] = tostring(select(i, ...)) end
        return table.concat(out, sep)
    end
    base.string.split = base.strsplit
    base.tContains = function(t, v)
        for _, value in ipairs(t) do if value == v then return true end end
        return nil
    end
    base.wipe = function(t)
        for k in pairs(t) do t[k] = nil end
        return t
    end
    base.CopyTable = function(c, t)
        t = t or {}
        for k, v in pairs(c) do t[k] = v end
        return t
    end
    base.table.getn = base.table.getn or function(t) return #t end
    base.slice = function(t, i, j)
        local out = {}
        j = j or #t
        for k = i, j do out[#out + 1] = t[k] end
        return out
    end
    base.getValue = function(t, k) return t and t[k] end

    -- 客户端在 _G 上直接挂了 Lua 标准库的别名（FrameXML 与 LibStub 到处写 strmatch / format），
    -- 文档快照不收录这批"语言别名"，只能手工给齐：少一个就是加载期一个 nil call 红。
    base.strmatch = base.string.match
    base.strfind = base.string.find
    base.strsub = base.string.sub
    base.strrep = base.string.rep
    base.strupper = base.string.upper
    base.strlower = base.string.lower
    base.strgsub = base.string.gsub
    base.strformat = base.string.format
    base.gsub = base.string.gsub
    base.match = base.string.match
    base.find = base.string.find
    base.format = base.string.format
    base.tinsert = base.table.insert
    base.tremove = base.table.remove
    base.table.contains = function(t, value)
        for _, v in pairs(t) do if v == value then return true end end
        return nil
    end
    base.table.indexOf = function(t, value)
        for i, v in ipairs(t) do if v == value then return i end end
        return nil
    end
    base.table.indexOfKey = function(t, key)
        for i, v in ipairs(t) do if v and v[key] ~= nil then return i end end
        return nil
    end
    base.table.getValueFromKey = function(t, key, valueKey)
        for _, v in ipairs(t) do
            if v and v[key] ~= nil then return v[valueKey] end
        end
        return nil
    end

    -- 机密值敏感的内置函数重写：真客户端在这些位置抛的是"invalid value (secret)"
    base.table.concat = function(list, sep, i, j)
        i = i or 1
        j = j or (#list)
        local out = {}
        for k = i, j do
            local v = list[k]
            if api.secretSeen(v) then
                error("invalid value (secret)", 2)
            end
            out[#out + 1] = v
        end
        return table.concat(list, sep, i, j)
    end
    local rawFormat = _G.string.format
    base.string.format = function(fmt, ...)
        for k = 1, select("#", ...) do
            local v = select(k, ...)
            if api.secretSeen(v) then
                local f, l, g, s = CallSite(3)
                add("A1s", g and "warn" or "red", string.format("A1s:format:%s:%s", tostring(f), tostring(l)), {
                    file = f, line = l, guarded = g, swallowedAt = s,
                    msg = "string.format 吃了机密值（实机在数字位上抛 invalid value (secret)）",
                })
            end
        end
        return rawFormat(fmt, ...)
    end
    local rawTostring = _G.tostring
    base.tostring = function(v)
        if api.secretSeen(v) then
            local f, l, g = CallSite(3)
            add("A1t", "warn", string.format("A1t:%s:%s", tostring(f), tostring(l)), {
                file = f, line = l, guarded = g,
                msg = "tostring(机密值)：实测稳定，但拼进文字就等于把 <SECRET> 画给玩家",
            })
            return "<SECRET>"
        end
        return rawTostring(v)
    end
    base.print = function(...)
        local n = select("#", ...)
        for i = 1, n do
            local v = select(i, ...)
            if api.secretSeen(v) then error("invalid value (secret)", 2) end
        end
        api.onPrint(...)
        return nil
    end

    for k, v in pairs(base) do rawsetenv(k, v) end
    api.base = base

    ---------------------------------------------------------------- 机密值工具
    function api.secretSeen(v)
        if v == nil then return false end
        if type(v) ~= "table" then return false end
        return rawget(v, "__mui_secret") ~= nil
    end
    local secretCount = 0
    function api.Secret(kindLabel)
        secretCount = secretCount + 1
        return MakeSecret(kindLabel)
    end
    function api.SecretCount() return secretCount end

    ---------------------------------------------------------------- 世界状态开关
    function api.SetRestricted(on) api.world.restricted = on and true or false end
    function api.SetLockdown(on) api.world.lockdown = on and true or false end
    function api.SetSecrets(on) api.world.secrets = on and true or false end
    function api.Now() return api.world.time end
    function api.Advance(dt) api.world.time = api.world.time + (dt or 0) end

    rawsetenv("GetTime", function() return api.world.time end)
    rawsetenv("GetTimeChecked", function() return api.world.time end)
    rawsetenv("InCombatLockdown", function() return api.world.lockdown and true or false end)
    rawsetenv("UnitIsGhost", function() return false end)
    rawsetenv("GetScreenResolution", function() return api.world.screen[1], api.world.screen[2] end)
    rawsetenv("GetPhysicalScreenSize", function() return 527.0, 296.0 end)
    rawsetenv("GetScreenHeight", function() return api.world.screen[2] end)
    rawsetenv("GetScreenWidth", function() return api.world.screen[1] end)
    rawsetenv("GetDisplayScale", function() return api.world.scale end)
    rawsetenv("IsMacClient", function() return false end)
    rawsetenv("IsPraClient", function() return false end)
    rawsetenv("IsRetailClient", function() return false end)
    rawsetenv("IsClassicClient", function() return false end)
    rawsetenv("IsVanillaClient", function() return false end)
    rawsetenv("IsTaintingClient", function() return false end)
    rawsetenv("GetBuildInfo", function() return 12, 1, 5, 70688, "Release" end)
    rawsetenv("GetTocBuildInfo", function() return 16001 end)
    rawsetenv("GetFrameRate", function() return 60 end)
    rawsetenv("GetCursorPosition", function() return 400, 300 end)
    rawsetenv("GetMouseFocus", function() return nil end)
    rawsetenv("IsMouseButtonDown", function() return false end)
    rawsetenv("IsAltKeyDown", function() return false end)
    rawsetenv("IsCtrlKeyDown", function() return false end)
    rawsetenv("IsShiftKeyDown", function() return false end)
    rawsetenv("GetBindingKey", function() return nil end)
    rawsetenv("GetActionInfo", function() return nil end)
    rawsetenv("GetMoney", function() return 0 end)
    rawsetenv("GetMoneyText", function() return "0g" end)
    rawsetenv("GetSpellInfo", function() return nil end)
    rawsetenv("GetItemInfo", function() return nil end)
    rawsetenv("GetContainerNumSlots", function() return 0 end)
    rawsetenv("GetContainerItemInfo", function() return nil end)
    rawsetenv("PickupPetSpell", function() return false end)
    rawsetenv("PlaySound", function() end)
    rawsetenv("PlaySoundFile", function() end)
    rawsetenv("StopSound", function() end)
    rawsetenv("ReloadUI", function() api.reloadRequested = true end)
    rawsetenv("SetCVar", function() end)
    rawsetenv("GetCVar", function() return "" end)
    rawsetenv("CVarIsDefault", function() return true end)
    rawsetenv("GetRealmName", function() return "Testrealm" end)
    -- 客户端语言：LibMonetColor / AceLocale 一类在加载期就要 GetLocale()，缺一个就整包挂掉
    rawsetenv("GetLocale", function() return "zhCN" end)
    rawsetenv("GetDefaultLanguage", function() return "zhCN" end)
    rawsetenv("GetRegion", function() return "CN" end)
    rawsetenv("GetAccountArea", function() return "China" end)
    rawsetenv("UnitRealmName", function() return "Testrealm" end)
    rawsetenv("UnitFactionGroup", function() return "Horde", "Horde" end)
    rawsetenv("UnitClass", function() return "Hunter", "猎人" end)
    rawsetenv("UnitLevel", function() return 80 end)
    rawsetenv("UnitRace", function() return "Orc", "兽人" end)
    rawsetenv("UnitName", function(unit)
        if unit == "player" then return "Tester" end
        return nil
    end)
    rawsetenv("UnitGUID", function(unit)
        if unit == "player" then return "GUI-PLAYER-1" end
        return nil
    end)
    rawsetenv("UnitExists", function(unit)
        local t = { player = true, target = true, focus = true, pet = true }
        if unit == "targettarget" then return true end
        if unit and unit:find("^nameplate") then return true end
        if unit and unit:find("^party") then return false end
        if unit and unit:find("^raid") then return false end
        return t[unit] and true or false
    end)
    rawsetenv("UnitIsPlayer", function() return true end)
    rawsetenv("UnitIsUnit", function(a, b) return a == b end)
    rawsetenv("UnitIsDead", function() return false end)
    rawsetenv("UnitIsGhost", function() return false end)
    rawsetenv("UnitIsFeignDeath", function() return false end)
    rawsetenv("UnitIsPVPFreeLife", function() return false end)
    rawsetenv("UnitIsTainted", function() return false end)
    rawsetenv("UnitIsFriend", function() return false end)
    rawsetenv("UnitInParty", function() return false end)
    rawsetenv("UnitInRaid", function() return false end)
    rawsetenv("UnitInCombat", function() return false end)
    rawsetenv("UnitIsCastingPetSpell", function() return false end)
    rawsetenv("UnitIsPrivateCreature", function() return false end)
    rawsetenv("UnitIsBattlePet", function() return false end)
    rawsetenv("UnitClassification", function() return nil end)
    rawsetenv("UnitReaction", function() return 4 end)
    rawsetenv("UnitThreatSituation", function() return nil end)
    rawsetenv("GetNumPartyMembers", function() return 0 end)
    rawsetenv("GetNumRaidMembers", function() return 0 end)
    rawsetenv("GetNumGroupMembers", function() return 0 end)
    rawsetenv("GetNumSubgroupMembers", function() return 0 end)
    -- 组队/团队判定：这批老 API 文档快照不收录（"缺席≠不存在"，见 docs 备忘），手工给齐。
    -- 默认给"不在队、不在团"这一最平常态，值挂在 api.world 上 —— Groups.lua 的
    -- MonetPartyHeader / MonetRaidHeader 显隐分支靠的就是它，改成 true 就能跑另一头。
    rawsetenv("IsInRaid", function(ignorePets)
        return api.world.inRaid and true or false
    end)
    rawsetenv("IsInGroup", function(ignorePets)
        return (api.world.inRaid or api.world.inParty) and true or false
    end)
    rawsetenv("IsInParty", function(ignorePets)
        return (api.world.inParty and not api.world.inRaid) and true or false
    end)
    rawsetenv("UnitIsDeadOrGhost", function(unit)
        local s = api.world.deadUnits
        return (s and s[unit]) and true or false
    end)
    rawsetenv("UnitIsConnected", function(unit)
        local s = api.world.disconnectedUnits
        return not (s and s[unit])
    end)
    ---------------------------------------------------------------- FrameXML helper
    -- 这批名字来自 FrameXML（ColorUtil.lua / ClassColors.lua 都在 framexml-source 里），
    -- 文档快照不收录，但客户端确实有。少给一个的后果不是报错，而是产品里
    -- "探测到才走"的那一整支静默跳过（Widget.lua:583 的 type(CreateColor) ~= "function"
    -- 就是这么把渐变路径跳过的）—— 静默假绿比一条红难发现得多，所以按证据补齐。
    local RAID_COLORS = {}
    for _, className in ipairs(CLASS_LIST) do
        local t = CLASS_TINT[className]
        RAID_COLORS[className] = MakeColor(t[1], t[2], t[3], 1)
    end
    rawsetenv("RAID_CLASS_COLORS", RAID_COLORS)
    -- CUSTOM_CLASS_COLORS 留给别的插件（Elvui 一类）设置：本机没有它们 ⇒ 缺席是忠实状态
    rawsetenv("CreateColor", function(r, g, b, a) return MakeColor(r, g, b, a) end)
    rawsetenv("CreateColorFromBytes", function(r, g, b, a)
        return MakeColor((r or 255) / 255, (g or 255) / 255, (b or 255) / 255, (a or 255) / 255)
    end)
    rawsetenv("AreColorsEqual", function(left, right)
        if left and right then return left:IsEqualTo(right) end
        return left == right
    end)
    rawsetenv("GetClassColor", function(classFilename)
        local c = classFilename and RAID_COLORS[classFilename]
        if c then return c.r, c.g, c.b, c.colorStr end
        return 1, 1, 1, "ffffffff"
    end)
    rawsetenv("GetClassColorObj", function(classFilename)
        return classFilename and RAID_COLORS[classFilename] or nil
    end)
    -- GetInstanceInfo 的返回值**次序**本仓没有可靠证据（文档快照里查不到，实机又进不去）：
    -- 宁可不给值 —— 产品的 `type(instanceType) ~= "string"` 会走"隐藏难度牌"那一支，
    -- 调用本身不抛（忠实），但难度相关分支离线**没有验证过**，报告里按缺口列出。
    rawsetenv("GetInstanceInfo", function()
        api.stubGaps["GetInstanceInfo（返回值次序无据，只走'不在副本'一支）"] =
            (api.stubGaps["GetInstanceInfo（返回值次序无据，只走'不在副本'一支）"] or 0) + 1
        return nil
    end)
    rawsetenv("GetRealInstanceId", function() return nil end)
    rawsetenv("GetSessionInstanceId", function() return nil end)
    rawsetenv("GetRaidRosterInfo", function() return nil end)
    rawsetenv("GetNumGuildMembers", function() return 0 end)
    rawsetenv("GetTimeUntilCorpseReady", function() return 0 end)
    rawsetenv("debugstack", function(depth, minDepth, count, maxCount)
        depth = depth or 2
        count = count or 3
        local out = {}
        for i = 1, count do
            local info = debug.getinfo(depth + i, "Sl")
            if not info then break end
            local src = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
            out[#out + 1] = string.format("    %s:%d: in function '%s'", src, info.currentline or 0,
                tostring(info.name or "?"))
        end
        return table.concat(out, "\n")
    end)
    rawsetenv("taint", function() end)
    rawsetenv("SecureLocateFunctionOwner", function() return nil end)
    rawsetenv("GetFramesRegisteredForEvent", function(event)
        local out = {}
        for obj, st in pairs(api.eventRegs) do
            if st.events and st.events[event] then out[#out + 1] = obj end
        end
        return out
    end)
    rawsetenv("EnumerateFrames", function()
        local i = 0
        return function()
            i = i + 1
            local obj = api.allObjects[i]
            if obj then return obj end
            return nil
        end
    end)

    ---------------------------------------------------------------- CreateFrame
    -- 模板出身判据的第一来源是 world-data 的 secureTemplates（build-world.js 沿 XML
    -- inherits 求出的传递闭包，311 个模板），手抄名单只当"转储里查不到的模板"兜底：
    -- ActionBarButtonTemplate 这类**名字里没有 Secure** 但 inherits 链上有 SecureFrameTemplate 的
    -- 才是要判的对象，光看名字会一路判成"不受保护"。
    local SECURE_TEMPLATE = {
        SecureUnitButtonTemplate = true, SecureActionButtonTemplate = true,
        SecureHandlerStateTemplate = true, SecureHandlerAttributeTemplate = true,
        SecureHandlerClickTemplate = true, SecureHandlePenTemplate = true,
        SecureRangeCheck = true,
    }
    rawsetenv("CreateFrame", function(frameType, name, parent, template, ...)
        frameType = frameType or "Frame"
        if type(name) == "string" and api.byName[name] then
            -- 与真客户端一致：重名直接抛（能暴露"我们和暴雪抢名字"这类问题）
            error(string.format("CreateFrame: %s already exists", name), 2)
        end
        local secure = false
        local ownReason = false          -- 保护是否来自这一句自己（模板 / protected 标志）
        if type(template) == "string" then
            if (api.secureTemplates and api.secureTemplates[template])
                or SECURE_TEMPLATE[template] or template:find("Secure") then
                secure = true
                ownReason = true
            end
        end
        local p = parent
        if p == nil then p = env.UIParent end
        if p and not STATE[p] then error("CreateFrame: parent is not a widget", 2) end
        if p and (STATE[p].secure or STATE[p].protected) then secure = true end
        local isProtectedFlag = select(1, ...)      -- 第 5 参 protected
        if isProtectedFlag then
            secure = true
            ownReason = true
        end
        local obj, st = api.NewObject(frameType, name, p, { secure = secure, template = template })
        st.owned = true
        st.inheritedSecure = secure and not ownReason
        if api.onObjectCreated then api.onObjectCreated(obj, st) end
        return obj
    end)

    rawsetenv("GetFrameByName", function(name) return api.byName[name] end)
    rawsetenv("GetMouseFocus", function() return nil end)

    ---------------------------------------------------------------- 事件泵 / 定时器
    ---------------------------------------------------------------- 脚本泵 / 事件泵
    --- 跑一段脚本；出错时抓**真正失败那一帧**的 file:line。
    -- 消息处理器仍在原始栈上运行，所以能取到出错位置；pcall 之后再看栈只能看到调用者，
    -- 位置就全丢了（这条以前踩过：红是红了，但报的是泵自己的行号）。
    local function runScript(fn, label, obj, ...)
        local site = {}
        local function msgh(err)
            for i = 2, 60 do
                local info = debug.getinfo(i, "Sl")
                if not info then break end
                if info.short_src ~= "[C]" and not isHarnessSource(info.source) then
                    site.file = tostring(info.source):gsub("^@", "")
                    site.line = info.currentline or 0
                    break
                end
            end
            return err
        end
        local ok, err = xpcall(fn, msgh, obj, ...)
        if not ok then
            local frame = obj and STATE[obj] and labelOf(STATE[obj]) or nil
            -- 脚本被"受限写入被拒"打断时，同一条写入已经在断言二记过账。继承型保护（A2i）只有黄，
            -- 它带出来的中断也停在黄：否则一条离线没有判据的猜测会同时变成两处红，把真红埋掉。
            -- A6（排空时序）已记红，同一个中断不必再记第二条红 —— 它的修法是同一个。
            local cls, level = "A0", "red"
            local d = api.lastDeny
            local blocked = type(err) == "string" and err:find("ADDON_ACTION_BLOCKED")
            if blocked and d and (d.cls == "A2i" or d.cls == "A6") then
                cls, level = "A0b", "warn"
            end
            add(cls, level, string.format("%s:%s:%s:%s", cls, label, tostring(site.file), tostring(site.line)), {
                file = site.file, line = site.line, frame = frame,
                -- 被哪一拍打断要写出来：L = InCombatLockdown 仍 true（脱战派发当拍就是这样），
                -- R = 六类受限窗口之一还开着。只看"某框抛错"分不出产品缺守卫还是排空排早了。
                -- 只在"这条错就是被拒"时给：普通 Lua 报错沿用 lastDeny 会把上一拍的窗口安错地方。
                flags = (blocked and d) and ("被拒那一拍 " .. tostring(d.win) .. (d.cls and (" · " .. d.cls) or "")),
                msg = label .. " 抛错: " .. tostring(err),
            })
        end
        return ok, err
    end
    api.runScript = runScript

    local onUpdateList = api.onUpdate
    function api.Pump(self, seconds, step)
        step = step or 0.5
        local t = 0
        while t < seconds do
            api.Advance(step)
            for obj, st in pairs(onUpdateList) do
                local fn = st.scripts and st.scripts.OnUpdate
                if fn and STATE[obj] then
                    runScript(fn, "OnUpdate", obj, step)
                    api.scriptsRun = api.scriptsRun + 1
                end
            end
            api:RunTimers()
            t = t + step
        end
    end

    function api.RunTimers(self)
        local due = {}
        for i = 1, #api.timers do
            local item = api.timers[i]
            if item.at <= api.world.time then due[#due + 1] = item end
        end
        for i = #api.timers, 1, -1 do
            for _, item in ipairs(due) do
                if api.timers[i] == item then table.remove(api.timers, i) break end
            end
        end
        for _, item in ipairs(due) do
            if not (item.handle and item.handle.Cancelled) then
                runScript(item.fn, "C_Timer 回调", item.handle)
                api.scriptsRun = api.scriptsRun + 1
            end
            if item.ticker and item.interval and item.interval > 0
                and not (item.handle and item.handle.Cancelled) then
                item.at = api.world.time + item.interval
                api.timers[#api.timers + 1] = item
            end
        end
    end

    --- 把事件投给**自家**注册过的对象。暴雪框的 OnEvent 属于引擎，离线不执行（见报告"离线近似"）。
    function api.Dispatch(self, event, ...)
        local snapshot = {}
        for obj, st in pairs(api.eventRegs) do
            if st.events and st.events[event] then snapshot[#snapshot + 1] = { obj, st } end
        end
        local args = { ... }
        local unit = ...
        for _, pair in ipairs(snapshot) do
            local obj, st = pair[1], pair[2]
            local fn = st.scripts and st.scripts.OnEvent
            if fn and STATE[obj] then
                local list = st.events[event]
                local skip = false
                if st.unitFiltered and st.unitFiltered[event] and list and #list > 0 then
                    skip = true
                    for i = 1, #list do
                        if list[i] == unit then skip = false break end
                    end
                end
                if not skip then
                    runScript(fn, "OnEvent(" .. event .. ")", obj, event, table.unpack(args))
                    api.scriptsRun = api.scriptsRun + 1
                end
            end
        end
        return api.scriptsRun
    end

    ---------------------------------------------------------------- 已知全局写入
    function api.noteGlobalWrite(name)
        api.globalWrites = api.globalWrites or {}
        api.globalWrites[name] = (api.globalWrites[name] or 0) + 1
    end

    ---------------------------------------------------------------- env 元表：未知全局
    -- `api.declaredGlobals` 里的名字**不记账**：SavedVariables（MonetUIDB）在登录前就是 nil，
    -- 记成"世界里没有的全局"会把真正的缺口淹没。run.lua 从 toc 里填它。
    api.declaredGlobals = {}
    local envMT = {
        __index = function(t, k)
            if type(k) ~= "string" then return nil end
            if api.declaredGlobals[k] then return nil end
            -- 客户端文档里存在、替身没实现的全局：调用不抛才是忠实行为，返回值缺失记进黄色覆盖面
            if docGlobals()[k] then
                api.stubGaps[k] = (api.stubGaps[k] or 0) + 1
                return emptyDocFn
            end
            -- FrameXML 里确有这个名字（helper / 常量），替身还没来得及照证据补：单列一本账。
            -- 它和"暴雪框名在这个分支里不存在"（断言五的 ✗）是两回事，混在一起会把两种
            -- 结论都读成"缺席清单"。仍然返回 nil：真客户端有它，产品多半做了存在性检测，
            -- 于是相应分支离线**没跑过** —— 报告里这条就是那个提醒。
            if helperNames()[k] then
                api.helperGaps[k] = (api.helperGaps[k] or 0) + 1
                return nil
            end
            local f, l = api.CallSite(3)
            local key = k
            local entry = api.unknownGlobals[key]
            if not entry then
                entry = { n = 0, file = f, line = l }
                api.unknownGlobals[key] = entry
            end
            entry.n = entry.n + 1
            return nil
        end,
    }
    setmetatable(env, envMT)
    rawset(env, "_G", env)

    ---------------------------------------------------------------- C_* / Enum
    local function newtbl(...)
        local t = {}
        for _, src in ipairs({ ... }) do for k, v in pairs(src) do t[k] = v end end
        return t
    end
    api.C = {}
    -- C_* 命名空间统一包一层"文档驱动"的 __index，目的有两个：
    --   1) 客户端文档里存在、替身还没来得及实现的方法 —— 给一个**存在但答不上来**的空方法，
    --      并记进 api.stubGaps（黄色：harness 自己的覆盖面，不是产品缺陷）。真实客户端确实有这个方法，
    --      所以"调用不抛"是忠实的；返回值缺失属于离线近似，报告里会单列。
    --   2) 文档里**不存在**的方法 —— 忠实返回 nil。产品真去调用它就会得到
    --      "attempt to call a nil value"，这正是"接了本客户端没有的 API"该有的红。
    local docMethodSets = {}
    local function docMethodsFor(nsName)
        local set = docMethodSets[nsName]
        if set then return set end
        local doc = (api.engine.namespaces or {})[nsName]
        set = {}
        if type(doc) == "table" then
            for i = 1, #doc do
                local m = doc[i]
                if type(m) == "string" then set[m] = true end
            end
        end
        docMethodSets[nsName] = set
        return set
    end
    -- 文档给 C_ 方法挂的 fl.r（受限：只能从安全代码调）。MonetUI 是 tainted 插件，调到它
    -- 实机是 ADDON_ACTION_FORBIDDEN 一类。这条判据的语义我们只有文档快照一份证据（AGENTS
    -- 没写、也没第二条来源能在离线复核），所以只记账不判红：报告里单列一批"上线第一天要点名
    -- 复核的调用点"，不拿它把产品刷成一屏红。
    local restrictedSets = {}
    local function isRestrictedC(nsName, k)
        local set = restrictedSets[nsName]
        if not set then
            set = {}
            local doc = (api.engine.restrictedNsMethods or {})[nsName]
            if type(doc) == "table" then
                for i = 1, #doc do
                    local m = doc[i]
                    if type(m) == "string" then set[m] = true end
                end
            end
            restrictedSets[nsName] = set
        end
        return set[k] == true
    end
    local function noteRestrictedC(nsName, k)
        local name = nsName .. "." .. k
        api.restrictedCalls[name] = (api.restrictedCalls[name] or 0) + 1
        local file, line, guarded = CallSite(3)
        add("A2r", "warn", string.format("A2r:%s:%s:%s", name, tostring(file), tostring(line)), {
            file = file, line = line, op = name, guarded = guarded,
            msg = "调了文档标 fl.r（受限）的方法 " .. name,
        })
    end

    -- 已经实现的方法也要过一遍：fl.r 说的是"谁能调"，跟替身给不给返回值无关。
    local restrictedWrapped = {}
    local function guardRestricted(nsName, tbl)
        local doc = (api.engine.restrictedNsMethods or {})[nsName]
        if type(doc) ~= "table" then return end
        for i = 1, #doc do
            local m = doc[i]
            local f = type(m) == "string" and tbl[m] or nil
            if type(f) == "function" and not restrictedWrapped[f] then
                restrictedWrapped[f] = true
                tbl[m] = function(...)
                    noteRestrictedC(nsName, m)
                    return f(...)
                end
            end
        end
    end

    local function wrapNamespace(nsName, tbl)
        guardRestricted(nsName, tbl)
        local docSet = docMethodsFor(nsName)
        return setmetatable(tbl, {
            __index = function(_, k)
                if type(k) ~= "string" then return nil end
                if docSet[k] then
                    local key = nsName .. "." .. k
                    api.stubGaps[key] = (api.stubGaps[key] or 0) + 1
                    if isRestrictedC(nsName, k) then
                        return function(...)
                            noteRestrictedC(nsName, k)
                            return nil
                        end
                    end
                    return function() return nil end
                end
                local key = nsName .. "." .. k
                local file, line = CallSite(3)
                local seen = api.unknownApi[key]
                if not seen then
                    api.unknownApi[key] = { file = file, line = line, n = 1 }
                else
                    seen.n = seen.n + 1
                end
                return nil
            end,
        })
    end
    api.wrapNamespace = wrapNamespace
    local function defC(name, tbl)
        local wrapped = wrapNamespace(name, tbl)
        api.C[name] = wrapped
        rawsetenv(name, wrapped)
        return wrapped
    end

    defC("C_AddOns", {
        GetAddOnInfo = function(name) return name, "", true, true, true end,
        GetAddOnMetadata = function(name, key)
            if key == "Interface" then return "16001" end
            return nil
        end,
        IsAddOnLoaded = function(name)
            if not name then return false end
            local loaded = api.loadedAddOns
            if loaded[name] ~= nil then return loaded[name] and true or false end
            return (api.ALWAYS_LOADED[name]) and true or false
        end,
        LoadAddOn = function(name)
            api.loadedAddOns[name] = true
            return true
        end,
        GetNumAddOns = function() return 0 end,
        GetAddOnEnableState = function() return 2 end,
        EnableAddOn = function() end,
        GetScriptsDisallowedForBeta = function() return nil end,
        GetAddOnDependencies = function() return nil end,
    })
    api.ALWAYS_LOADED = {
        Blizzard_FrameXML = true, Blizzard_FrameXMLBase = true, Blizzard_FrameXMLUtil = true,
        Blizzard_SharedXML = true, Blizzard_SharedXMLBase = true, Blizzard_SharedXMLGame = true,
        Blizzard_MoneyFrame = true, Blizzard_UIPanels_Game = true, Blizzard_CooldownUI = true,
    }
    api.loadedAddOns = {}

    defC("C_Timer", {
        After = function(delay, fn)
            api.timers[#api.timers + 1] = { at = api.world.time + (delay or 0), fn = fn }
            return nil
        end,
        NewTicker = function(interval, fn, times)
            local handle = { Cancelled = false }
            handle.Cancel = function() handle.Cancelled = true end
            api.timers[#api.timers + 1] = {
                at = api.world.time + (interval or 0), fn = fn, ticker = true,
                interval = interval, handle = handle, left = times,
            }
            return handle
        end,
        NewTimer = function(delay, fn)
            local handle = {}
            handle.Cancel = function() handle.Cancelled = true end
            api.timers[#api.timers + 1] = { at = api.world.time + (delay or 0), fn = fn, handle = handle }
            return handle
        end,
    })

    defC("C_CVar", {
        GetCVar = function(name) return api.cvars and api.cvars[name] or "" end,
        GetCVarDefault = function() return "" end,
        SetCVar = function(name, value)
            api.cvars = api.cvars or {}
            api.cvars[name] = tostring(value)
            return true
        end,
        GetCVarInfo = function(name) return api.cvars and api.cvars[name] or "", 0, 0, 0 end,
        IsCVarFlagSet = function() return false end,
        SetCVarBitfield = function() return true end,
        GetCVarBitfield = function() return 0 end,
    })

    -- 六类限制的**数值**一律取文档快照（Core.lua 的 RestrictionValue 就是 tonumber(Enum.…)，
    -- 替身自己编一套数字会让"事件载荷 → 类型名"的反查对不上，六类里五类静默失效）。
    local RESTRICTION_TYPES = {}
    for k, v in ipairs({ "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }) do
        RESTRICTION_TYPES[k] = v
    end
    api.RESTRICTION_ORDER = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map", "Chat" }
    api.restrictionByValue = {}
    local rt = (api.engine.enums or {}).AddOnRestrictionType
    if rt then
        for _, name in ipairs(api.RESTRICTION_ORDER) do
            if rt[name] ~= nil then api.restrictionByValue[rt[name]] = name end
        end
    end
    api.restrictions = {}
    defC("C_RestrictedActions", {
        HasRestrictedActions = function() return true end,
        GetRestrictionTypes = function()
            local out = {}
            for k in pairs(RESTRICTION_TYPES) do out[#out + 1] = k end
            return out
        end,
        IsAddOnRestrictionActive = function(typeValue)
            local name = api.restrictionByValue[typeValue]
            if not name then
                -- 反查不到 = 文档没给这一类的数值（或客户端不认识这个值）：如实答 nil
                return nil
            end
            return api.restrictions[name] and true or false
        end,
        GetRestrictionInfo = function(typeValue)
            local name = api.restrictionByValue[typeValue]
            return (name and api.restrictions[name]) and "Active" or "None"
        end,
    })
    api.RESTRICTION_TYPES = RESTRICTION_TYPES

    defC("C_Secrets", {
        HasSecretRestrictions = function() return api.world.secrets and true or false end,
        ShouldUnitHealthMaxBeSecret = function(unit)
            if not api.world.secrets then return false end
            return (unit == "target" or unit == "nameplate1") and true or false
        end,
        ShouldUnitPowerBeSecret = function() return api.world.secrets and true or false end,
        ShouldUnitIdentityBeSecret = function() return false end,
        ShouldUnitSpellCastingBeSecret = function() return api.world.secrets and true or false end,
        ShouldAurasBeSecret = function() return api.world.secrets and true or false end,
        ShouldCooldownsBeSecret = function() return api.world.secrets and true or false end,
        ShouldUnitCombatTurnBeSecret = function() return api.world.secrets and true or false end,
    })

    defC("C_EventUtils", {
        IsEventValid = function(event)
            if type(event) ~= "string" then return false end
            return api.KNOWN_EVENTS[event] and true or false
        end,
        IsEventRegisteredForFrame = function() return false end,
        ApplyToAllRegisteredEvents = function() end,
    })

    defC("C_UnitAuras", {
        GetAuraDataByIndex = function(unit, index, filterType)
            if api.world.secrets then return api.secretAura(unit, index, filterType) end
            return api.plainAura(unit, index, filterType)
        end,
        GetAuraDataBySlot = function() return nil end,
        GetAuraDataBySpellName = function() return nil end,
        GetAuraByToken = function() return nil end,
        CancelAura = function() return false end,
        CancelAuraByInstanceID = function() return false end,
        PurgeAuras = function(_, version) return version end,
        GetAuraPositionsFromSpell = function() return nil end,
    })

    defC("C_NamePlate", {
        GetNamePlates = function() return { [1] = nil } end,
        GetNamePlateForUnit = function(unit)
            local n = tonumber(unit and unit:match("^nameplate(%d+)$"))
            if not n then return nil end
            local name = "NamePlate" .. n
            return api.byName[name], api.byName[name .. "UnitFrame"]
        end,
        GetNamePlateSize = function() return 80, 120 end,
        GetNamePlateWorldScaleFrame = function() return nil end,
        SetNamePlateSize = function(w, h)
            if api.world.restricted then
                local f, l, g, s = CallSite(3)
                if not g then
                    add("A2", "red", string.format("A2:C_NamePlate:SetNamePlateSize:%s:%s", tostring(f), tostring(l)), {
                        file = f, line = l, guarded = g, swallowedAt = s, frame = "C_NamePlate",
                        op = "SetNamePlateSize",
                        msg = "ADDON_ACTION_BLOCKED MonetUI C_NamePlate:SetNamePlateSize()",
                        why = "受限状态下改引擎姓名板尺寸（AGENTS 判例：改轮询读 GetNamePlateSize）",
                    })
                end
                return false
            end
            return true
        end,
        SetNamePlateSupportWorldScaled = function() end,
    })

    defC("C_Map", {
        GetMapInfo = function(id)
            return { mapID = id or 870, name = "测试区域", description = "", isDungeon = false,
                     isRaid = false, parentMapID = 947, canonicalMapID = id or 870,
                     spawnOrigin = { x = 50, y = 50 }, flags = 0 }
        end,
        GetBestMapForUnit = function(unit)
            if unit == "player" then return 870 end
            return nil
        end,
        GetAreaPOIForUnit = function() end,
        GetAreaText = function() return "" end,
        GetNumZonesPerMap = function() return 0 end,
        IsEntityOnMap = function() return false end,
        SetToNearestZoneMap = function() return false end,
        GetDisplayedZoneMaps = function() return nil end,
    })
    defC("C_WorldMap", {
        GetMapName = function() return "测试区域" end,
        SetToMap = function() end,
        ToggleWorldMap = function() end,
        CanToggleMap = function() return true end,
        IsMounted = function() return false end,
        GetWorldMapFrame = function() return api.byName.WorldMapFrame end,
    })
    defC("C_Minimap", {
        ShouldUseHybridMinimap = function() return false end,
        GetNumIcons = function() return 0 end,
        GetIndoors = function() return false end,
        ShowFrame = function() end,
        GetMapType = function() return 0 end,
        ToggleFrame = function() end,
        SetZoom = function() end,
        GetZoom = function() return 0 end,
        GetRawZoom = function() return 0 end,
        SetAngle = function() end,
        GetPointOfInterestIcon = function() return nil end,
    })
    defC("C_GameRules", {
        IsGameRuleActive = function(rule) return rule == "Camelot" end,
        GetActiveGameRules = function() return { "Camelot" } end,
    })
    defC("C_ClassColor", {
        -- Returns 一个 ColorMixin 表（MayReturnNothing = true：不认识的职业技能名给 nil）
        GetClassColor = function(className, tint)
            local t = className and CLASS_TINT[className]
            if not t then return nil end
            return MakeColor(t[1], t[2], t[3], 1)
        end,
    })
    defC("C_Item", {
        GetItemInfo = function() return nil end,
        GetItemQuality = function() return nil end,
        GetItemQualityByID = function(id) return id and 1 or nil end,
        -- 真签名四个返回值（docs/api：C_Item.GetItemQualityColor(q) → r, g, b, qualityString）。
        -- 桩必须按文档元数返回、且数值故意不同于本仓 QUALITY_FALLBACK 六档，否则
        -- Skin:QualityColor 的 pcall 三重 type()=="number" 守卫恒失败，离线每次都静默走兜底分支
        -- —— 桩元数错不报错，只会让绿断言证不到它想证的分支。
        GetItemQualityColor = function(q) return 0.72, 0.46, 0.98, "stub-quality" end,
        GetItemInventoryTypeByID = function() return 1 end,
        IsAnimaItemByID = function() return false end,
        IsItemBindToAccountUntilEquip = function() return false end,
        GetItemIcon = function() return nil end,
        GetInventorySlotInfo = function() return 1 end,
    })
    defC("C_Container", {
        GetContainerNumSlots = function() return 0 end,
        GetContainerNumFreeSlots = function() return 0, 0 end,
        GetContainerItemInfo = function() return nil end,
        GetContainerItemDurability = function() return nil end,
        GetContainerItemQuestInfo = function() return nil end,
        GetItemCooldown = function() return nil end,
        ContainerIDToInventoryID = function(id) return id end,
        GetSplitContainerContainerID = function() return nil end,
        GetContainerName = function() return "背包" end,
        SortBags = function() end,
    })
    defC("C_Bank", { GetBankItemInfo = function() return nil end, HasBankTab = function() return false end })
    defC("C_QuestLog", {
        GetNumQuestLogEntries = function() return 0 end,
        GetInfo = function() return nil end,
        GetQuestObjectives = function() return nil end,
        GetQuestDifficultyLevel = function() return 0 end,
        GetQuestWatchType = function() return 0 end,
        IsComplete = function() return false end,
        IsFailed = function() return false end,
        IsOnQuest = function() return false end,
        GetQuestLogLevel = function() return 0 end,
        GetTitle = function() return nil end,
    })
    defC("C_ActionBar", {
        GetActionInfo = function() return nil end,
        GetActionCooldown = function() return 0, 0, 0 end,
        GetActionCooldownDuration = function() return 0 end,
        GetActionDisplayCount = function() return 0 end,
        IsActionInRange = function() return true end,
        HasAction = function() return true end,
        GetBarInfo = function() return { name = "动作条", displayCost = true } end,
        GetActionCount = function() return 0 end,
        GetMaxActionButtons = function() return 18 end,
        GetPetActionInfo = function() return nil end,
        RegisterActionUIButton = function() end,
        IsMounted = function() return false end,
        GetPetActionSlotUsable = function() return true end,
    })
    defC("C_Spell", {
        GetSpellInfo = function(id)
            return { spellID = id, name = "测试法术", iconID = 123456, castTime = 2000,
                     manaCost = 0, range = 40, minRange = 0, school = 1, isFlyout = false }
        end,
        GetSpellCooldown = function() return { starts = 0, duration = 0, isEnabled = true, modRate = 1 } end,
        IsSpellKnown = function() return true end,
        GetSpellTabInfo = function() return "测试", false, "SPELLS", 1, 1 end,
        GetSpellBaseCooldown = function() return { duration = 0, gcd = 1500 } end,
        DoesSpellExist = function() return true end,
        GetCharges = function() return 1, 1, 0 end,
        GetMaxCharges = function() return 1 end,
    })
    defC("C_SpecializationInfo", {
        GetSpecialization = function() return 1 end,
        GetSpecializationInfo = function(i) return i, "测试专精", "TEST", 123456, 1, 1 end,
        GetNumSpecializationsForClassID = function() return 3 end,
        GetClassIDForSpecializationInfo = function() return 1 end,
        GetSpecializationRole = function() return "DAMAGER" end,
    })
    defC("C_CurveUtil", {
        CreateColorCurve = function()
            if api.world.restricted then
                local f, l, g = CallSite(3)
                if not g then
                    add("A2", "red", string.format("A2:C_CurveUtil:%s:%s", tostring(f), tostring(l)), {
                        file = f, line = l, guarded = g, frame = "C_CurveUtil", op = "CreateColorCurve",
                        msg = "受限状态下创建颜色曲线（AGENTS：机密期不建曲线，C_CurveUtil 会被拒）",
                    })
                end
                error("ADDON_ACTION_BLOCKED MonetUI C_CurveUtil:CreateColorCurve()", 0)
            end
            local curve = { Add = function() end, Evaluate = function(_, x) return x end,
                           EvaluateRGBA = function(_, x) return x, x, x, 1 end, SetAlphaCurve = function() end }
            return curve
        end,
    })
    defC("C_CurrencyInfo", { GetCurrencyListSize = function() return 0 end, GetCurrencyListInfo = function() return nil end })
    defC("C_EquipmentSet", { GetItemLocations = function() return nil end })
    defC("C_FriendList", { GetNumFriends = function() return 0 end, GetFriendInfo = function() return nil end, GetNumOnlineFriends = function() return 0 end, GetFriendByIndex = function() return nil end })
    defC("C_PvP", { GetActiveBrawl = function() return nil end, IsInPVPPatchZone = function() return false end })
    defC("C_PaperDollInfo", { GetArmorEffectiveness = function() return 0 end, GetItemInteractionFrame = function() return nil end, TryInspectUnit = function() return false end })
    defC("C_Reputation", { GetWatchedFactionIndex = function() return 0 end, GetFactionData = function() return nil end })
    defC("C_Calendar", { GetNumPendingInvites = function() return 0 end, GetEventLinkData = function() return nil end })
    defC("C_NewItems", { IsNewItem = function() return false end, ClearAll = function() end, IsNewItemByID = function() return false end })
    defC("C_KeyBindings", { GetBindingByKey = function() return nil end, GetBindingFrame = function() return nil end })
    defC("C_Console", { GetAllCommands = function() return {} end })
    defC("C_SecureTransfer", { CanSend = function() return false end, GetPending = function() return nil end })
    defC("C_Authenticator", { GetLast = function() return nil end })
    defC("C_EncounterJournal", { IsEncounterComplete = function() return false end, GetEncounterInfo = function() return nil end })
    defC("C_UnitClass", { GetDisplayInfo = function() return nil end })
    defC("C_VideoOptions", { GetGSetting = function() return true end })
    defC("C_CharacterServices", { AreCharacterServicesAllowed = function() return false end })
    defC("C_GuildInfo", { GetNumMembers = function() return 0 end })
    defC("C_LootJournal", { GetItemSets = function() return nil end })
    defC("C_Collections", { IsInProgressMatch = function() return false end })
    defC("C_UIMap", { GetMap = function() return nil end })

    ---------------------------------------------------------------- 单位数值（机密语义按实测表）
    local function maybeSecretNumber(kindLabel)
        if api.world.secrets then return api.Secret(kindLabel) end
        return 100
    end
    rawsetenv("UnitHealth", function(unit)
        if api.world.secrets then
            if unit == "player" then return api.Secret("number") end
            return api.Secret("number")
        end
        return 1000
    end)
    rawsetenv("UnitHealthMax", function(unit)
        if api.world.secrets then return api.Secret("number") end
        return 1000
    end)
    rawsetenv("UnitPower", function(unit) if api.world.secrets then return api.Secret("number") end return 100 end)
    rawsetenv("UnitPowerMax", function(unit) if api.world.secrets then return api.Secret("number") end return 100 end)
    rawsetenv("UnitPowerBarID", function() return nil end)
    rawsetenv("UnitAlternatePowerCounterInfo", function() return nil end)
    rawsetenv("UnitHealthPercent", function(unit, useConstant, scaleTo)
        if api.world.secrets then return api.Secret("number") end
        return 100
    end)
    rawsetenv("CurveConstants", { ScaleTo100 = 100, ScaleTo255 = 255 })
    rawsetenv("GetUnitSpeed", function() return 0 end)
    rawsetenv("UnitCastingInfo", function()
        if api.world.secrets then return nil end
        return "测试施法", nil, nil, nil, 2000, api.world.time * 1000, (api.world.time + 2) * 1000, nil, false
    end)
    rawsetenv("UnitChannelInfo", function() return nil end)
    rawsetenv("UnitBuff", function() return nil end)
    rawsetenv("UnitDebuff", function() return nil end)
    rawsetenv("UnitAura", function() return nil end)
    rawsetenv("GetSpellCooldown", function() return 0, 0, 1 end)
    rawsetenv("GetSpellName", function() return nil end)
    rawsetenv("GetSpellTexture", function() return nil end)
    rawsetenv("UnitAttackPower", function() return 0 end)
    rawsetenv("UnitRangedAttackPower", function() return 0 end)
    rawsetenv("GetInventoryItemLink", function() return nil end)
    rawsetenv("GetInventoryItemQuality", function() return nil end)
    rawsetenv("GetInventoryItemTexture", function() return nil end)
    rawsetenv("GetInventoryItemDurability", function() return nil end)
    rawsetenv("EquipmentManagerSetItemInspection", function() end)
    rawsetenv("GetAuctionItemInfo", function() return nil end)
    rawsetenv("GetAuctionItemTexture", function() return nil end)
    rawsetenv("GetAuctionItemTimeLeft", function() return nil end)

    ---------------------------------------------------------------- issecretvalue / canaccessvalue
    rawsetenv("issecretvalue", function(v) return api.secretSeen(v) end)
    rawsetenv("canaccessvalue", function(v)
        if not api.secretSeen(v) then return true end
        return api.world.secrets and false or true
    end)
    rawsetenv("issensitivevalue", function(v) return api.secretSeen(v) end)
    rawsetenv("Secrets", nil)
    rawsetenv("makeSecret", function(v) return api.Secret(type(v) == "number" and "number" or "string") end)

    ---------------------------------------------------------------- secure hook（断言三的另一半）
    -- AGENTS：不往暴雪对象的方法槽里插钩子。`hooksecurefunc(暴雪框, "Show")` 是实机
    -- ADDON_ACTION_BLOCKED 的成因之一，因此只要目标是我们没建过的对象就记红。
    -- 名字形式（`hooksecurefunc("PanelTemplates_SelectTab", fn)`）钩的是引擎全局函数，
    -- 离线无从判断它会不会二次污染 —— 记 warn，让它可见但不淹没真红。
    rawsetenv("hooksecurefunc", function(object, methodName, handler)
        local file, line = CallSite(2)
        local st = type(object) == "table" and STATE[object] or nil
        if st and st.blizzard then
            add("A3h", "red", string.format("A3h:%s:%s:hook:%s:%s", labelOf(st), tostring(methodName), tostring(file), tostring(line)), {
                file = file, line = line, frame = labelOf(st), op = "hooksecurefunc",
                msg = string.format("hooksecurefunc 钩了暴雪%s「%s」的方法槽 %s（AGENTS：改用轮询）",
                    st.kind, labelOf(st), tostring(methodName)),
            })
        elseif type(object) == "string" then
            add("A3k", "warn", string.format("A3k:%s:%s", tostring(file), tostring(line)), {
                file = file, line = line, op = "hooksecurefunc",
                msg = "hooksecurefunc 钩引擎函数 " .. tostring(object),
            })
        end
        return nil
    end)

    ---------------------------------------------------------------- Aura 数据（含机密形态）
    function api.plainAura(unit, index, filter)
        if index == nil or index < 1 or index > 8 then return nil end
        return {
            name = "测试光环" .. index, iconFileDataID = 123456 + index,
            duration = 30, expirationTime = api.world.time + 30,
            applications = 1, spellID = 1000 + index, unitToken = unit,
            auraInstanceID = index, isHelpful = filter ~= "HARMFUL", canApplyAura = true,
            isFromClient = false, dispelType = filter == "HARMFUL" and "Magic" or nil,
            consolidationPoints = 1, maxConsolidationPoints = 1,
        }
    end
    function api.secretAura(unit, index, filter)
        if index == nil or index < 1 or index > 8 then return nil end
        return {
            name = api.Secret("string"), iconFileDataID = 123456 + index,
            duration = api.Secret("number"), expirationTime = api.Secret("number"),
            applications = api.Secret("number"), spellID = api.Secret("number"),
            unitToken = unit, auraInstanceID = index,
            isHelpful = api.Secret("boolean"), canApplyAura = true,
            dispelType = filter == "HARMFUL" and api.Secret("string") or nil,
            consolidationPoints = 1, maxConsolidationPoints = 1,
        }
    end

    ---------------------------------------------------------------- Enum
    -- 真身 = engine-api.lua 的枚举表（build-engine 从 1.60 API 文档快照取的）。
    -- 文档里没有的类型 ⇒ nil；类型里没写的成员 ⇒ nil。这样 `_G.Enum and _G.Enum.TooltipDataType`
    -- 这类"整张表在不在"的探针（Tooltip.lua:699、Core.lua:834、Auras.lua:187）才会给出真答案，
    -- 而不是被替身无条件喂一张表骗过去。
    local docEnums = api.engine.enums or {}
    api.enumGaps = {}
    local enumNodes = {}
    local function enumNode(typeName)
        local node = enumNodes[typeName]
        if node then return node end
        local src = docEnums[typeName]
        node = setmetatable({}, {
            __index = function(_, k)
                if type(k) ~= "string" then return nil end
                if src == nil then return nil end
                return src[k]
            end,
            __newindex = function() error("Enum is read-only", 2) end,
        })
        enumNodes[typeName] = node
        return node
    end
    local Enum = setmetatable({}, {
        __index = function(_, k)
            if type(k) ~= "string" then return nil end
            if docEnums[k] == nil then
                api.enumGaps[k] = (api.enumGaps[k] or 0) + 1
                return nil
            end
            return enumNode(k)
        end,
        __newindex = function() error("Enum is read-only", 2) end,
    })
    rawsetenv("Enum", Enum)
    api.Enum = Enum
    api.docEnums = docEnums

    rawsetenv("BACKDROP_TOAST", { bgFile = "Interface\\Buttons\\WHITE8X8", tile = false, tileSize = 1, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    rawsetenv("BACKDROP_DIALOG_32_32", { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", tile = true, tileSize = 32, edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    rawsetenv("BACKDROP_GOLD_DIALOG_32_32", { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 32, tile = true, tileSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    rawsetenv("BACKDROP_TOOLTIP_0_16", { bgFile = nil, edgeFile = nil, edgeSize = 16, tile = true, tileSize = 16, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
    rawsetenv("BACKDROP_BLUESYSTEM", { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16, tile = true, tileSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    rawsetenv("BACKDROP_SLIDER_8_8", { bgFile = nil, edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", edgeSize = 8, tile = true, tileSize = 8, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    rawsetenv("DEFAULT_TRANSITION", { duration = 0.3 })
    rawsetenv("FADECLAMP", 0)

    -- 斜杠命令表：Core 在加载期写 `SLASH_MONETUI1 = "/mui"` 然后 `SlashCmdList[...] = handler`
    -- （`_G.SlashCmdList` 缺失会让加载直接抛，属于替身缺口而不是产品缺陷，所以必须给）。
    rawsetenv("SlashCmdList", {})
    -- 客户端的 Enumerate(...)：把变参变成 for 迭代器（FrameXML / 库代码常用）
    rawsetenv("Enumerate", function(...)
        local args = { ... }
        local i = 0
        return function()
            i = i + 1
            local v = args[i]
            if v == nil then return nil end
            return i, v
        end
    end)
    rawsetenv("within", function(v, a, b) return v >= a and v <= b end)

    ---------------------------------------------------------------- 已知事件表
api.KNOWN_EVENTS = {}
    -- 事件表 = 客户端 API 文档快照（1816 条）逐条建起来。为什么不用手抄清单：
    -- 实测 WORLD_MAP_UPDATE 在本客户端文档里**不存在**（零售删/改名），而 Core/模块正是靠
    -- C_EventUtils.IsEventValid 决定要不要注册 —— 手抄清单会把它答成 true，登录时那行
    -- "先问客户端认不认"的分支就永远测不到。
    do
        local list = api.engine.events or {}
        for i = 1, #list do
            if type(list[i]) == "string" then api.KNOWN_EVENTS[list[i]] = true end
        end
    end

    ---------------------------------------------------------------- print 拦截
    api.prints = {}
    api.onPrint = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do
            local v = select(i, ...)
            parts[i] = (type(v) == "table" and api.secretSeen(v)) and "<SECRET>" or tostring(v)
        end
        local line = table.concat(parts, " ")
        api.prints[#api.prints + 1] = line
        local file, l = CallSite(3)
        api.reportLine(line, file, l)
    end
    api.reportLine = function() end   -- run.lua 覆盖

    ---------------------------------------------------------------- UIParent
    -- FrameXML 里**没有** UIParent 的声明（C++ 侧建的），世界数据自然也没有。
    -- 但它是一切父链的根：断言 4 的 α 继承、GetEffectiveScale、SetPoint 到 UIParent
    -- 都要求它存在，且必须是"暴雪对象"（受限状态下写它就红）。
    do
        local uiParent, upState = api.NewObject("Frame", "UIParent", nil, {
            blizzard = true, shown = true, level = 0, strata = "PARENT",
            w = api.world.screen[1], h = api.world.screen[2],
        })
        upState.points[1] = { point = "CENTER", relative = nil, anchor = "CENTER" }
        rawsetenv("UIParent", uiParent)
        api.UIParent = uiParent
    end

    ---------------------------------------------------------------- 备份：常用工具
    api.labelOfState = function(st) return labelOf(st) end
    api.stateOf = function(obj) return STATE[obj] end
    api.STATE = STATE
    api.BYNAME = BYNAME

    return api
end

return ApiStub
