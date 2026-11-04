-- tools/harness/frames.lua
-- 把 world-data.lua（Camelot FrameXML 的声明式快照）实例化成替身对象世界。
--
-- 为什么"急切全量建"而不是"访问到才建"：换皮主循环走的是 GetChildren()/GetRegions()
-- （Utils/Skin.lua 404、1426、2009；Utils/Widget.lua 515；Modules/ActionBars/*.lua）。
-- 惰性建的话这些循环看到的是空表，"扫遍暴雪框"这条最贵的路径离线一次都不会执行 ——
-- 那是假绿，比没有 harness 更糟。代价是对象到几万量级，实测秒级 / 数百 MB，可接受。
--
-- 与 api_stub.lua 的约定（api.hooks.*，都以 state 表为键）：
--   blizzChild(st, k)  暴雪对象按字段名取命名子件（Inset / CloseButton / …）
--   blizzList(st, kind) GetChildren / GetRegions 的暴雪分支，回**数组表**
--   blizzArt(st, slot) Get*Texture 一类美术槽，slot ∈ normal/highlight/pushed/disabled/checked
-- 世界里没有的名字一律回 nil —— 与真客户端一致，**不算**替身缺口（这正是要喂给断言五的 ✗）。
--
-- 已知离线近似（报告里会单列，不当成产品结论）：
--   * 几何属性（size / setAllPoints / relativePoint）与 hidden 等属性 build-world.js 没采，
--     全部用替身默认值 —— 断言只看 α/显隐/写入许可这些行为，不看像素。
--   * Lua 运行时创建的子件（对象池、Mixin 造的 Artwork 等）不在 XML 声明里，取不到 →
--     表现为 Skin:Need 的 miss，需要人工分"真不存在"和"运行时才有"。

local Frames = {}

-- XML 标签 -> 引擎对象类型（api_stub 的 KIND_METHODS 键）
local KIND_FIX = {
    MaskedTexture = "Texture",
    Icon = "Texture",
    GameTip = "Frame",
    SpellBookPaginate = "Button",
    TabardAtlas = "Texture", TabardCharter = "Texture", TabardEmblem = "Texture",
    TabardBackground = "Texture", TabardBorder = "Texture",
    AnimatedTexture = "Texture",
}

--- @param opts { api=替身, W=world-data, loadedLoD=nil|{插件名=true|false}, maxObjects=数字 }
function Frames.New(opts)
    local api, W = opts.api, opts.W
    local strings, rows = W.strings, W.rows
    local env = api.env
    local maxObjects = opts.maxObjects or 400000
    local loadedLoD = opts.loadedLoD          -- nil = 全部加载（最真实的一次登录）

    ---------------------------------------------------------------- 行索引
    local childIdx = {}                        -- parentRow -> { {row=行号, key=字段名下标} }
    local slotsOf = {}                         -- hostRow   -> { [槽名] = 子贴图行号 }
    for i = 1, #rows do
        local r = rows[i]
        local p = r[4]
        if p and p > 0 then
            local bucket = childIdx[p]
            if not bucket then bucket = {}; childIdx[p] = bucket end
            bucket[#bucket + 1] = { row = i, key = r[3] }
        end
        local slots = r[6]
        if slots and #slots > 0 then
            local mine = {}
            for j = 1, #slots do mine[strings[slots[j][1]]] = slots[j][2] end
            slotsOf[i] = mine
        end
    end

    local templatesByName = W.templates
    -- 受保护模板名单交给替身：CreateFrame 判"这个模板出身受不受保护"用它，不再只看名字里有
    -- 没有 "Secure"（ActionBarButtonTemplate 这类靠 inherits 链继承保护，名字里没有）。
    do
        local set = {}
        for name in pairs(W.secureTemplates or {}) do set[name] = true end
        for name, rowIdx in pairs(templatesByName or {}) do
            local r = rows[rowIdx]
            if r and r[7] == 1 then set[name] = true end
        end
        api.secureTemplates = set
    end
    local globalsByName = W.globals
    local ownerOf = {}                         -- 行号 -> 提供它的 LoD 插件名
    for addonName, list in pairs(W.lod or {}) do
        for i = 1, #list do ownerOf[list[i]] = addonName end
    end
    local function loaded(name)
        if not name then return true end
        if not loadedLoD then return true end
        return loadedLoD[name] and true or false
    end

    ---------------------------------------------------------------- 每个宿主的实例账
    -- 均以 **state 表**为键（api_stub 的 hooks 只给得到 st）
    local keysOf, kidsOf, artOf, under, rowOfState = {}, {}, {}, {}, {}
    local F = {
        api = api, W = W, objects = 0, named = 0,
        skipped = {}, unbuiltGlobals = {}, rowOfState = rowOfState,
        under = under,
    }

    --- 宿主行的"槽名 -> 子行号"合并表（含模板链）。模板的美术槽要在每个宿主上各认一份。
    local function slotMap(rowIdx, out, seen)
        if not rowIdx or rowIdx <= 0 or seen[rowIdx] then return out end
        seen[rowIdx] = true
        local mine = slotsOf[rowIdx]
        if mine then
            for slotName, texRow in pairs(mine) do
                if out[slotName] == nil then out[slotName] = texRow end
            end
        end
        local inh = rows[rowIdx][5]
        if inh then
            for j = 1, #inh do
                local t = templatesByName[strings[inh[j]]]
                if t then slotMap(t, out, seen) end
            end
        end
        return out
    end

    --- 收集一个行的全部子件行（自身 + 模板链，递归去重）。
    local function collect(rowIdx, out, seen)
        if not rowIdx or rowIdx <= 0 or seen[rowIdx] then return end
        seen[rowIdx] = true
        local kids = childIdx[rowIdx]
        if kids then
            for i = 1, #kids do out[#out + 1] = kids[i] end
        end
        local inh = rows[rowIdx][5]
        if inh then
            for j = 1, #inh do
                local t = templatesByName[strings[inh[j]]]
                if t then collect(t, out, seen) end
            end
        end
    end

    local building = {}                         -- 行号 -> 已作为某棵树的宿主/顶层建过
    local instCount = {}                        -- 行号 -> 实例化次数（顶层或别人的子件）

    --- 建一个世界对象；hostSt/hostName 为 nil 表示 XML 顶层。
    local function buildRow(rowIdx, hostObj, hostSt, hostName, depth)
        if F.objects >= maxObjects then
            F.skipped[#F.skipped + 1] = rowIdx
            return nil
        end
        local row = rows[rowIdx]
        if not row then return nil end
        instCount[rowIdx] = (instCount[rowIdx] or 0) + 1
        local kind = strings[row[1]]
        kind = KIND_FIX[kind] or kind

        local rawName = row[2] > 0 and strings[row[2]] or nil
        local globalName, keyName
        if rawName then
            if rawName:sub(1, 7) == "$parent" then
                local suffix = rawName:sub(8)
                keyName = suffix ~= "" and suffix or (row[3] > 0 and strings[row[3]] or nil)
                if hostName then globalName = hostName .. suffix end
            else
                globalName = rawName
                if row[3] > 0 then keyName = strings[row[3]] end
            end
        elseif row[3] > 0 then
            keyName = strings[row[3]]
        end

        -- prot 位来自 world-data（build-world.js 沿模板 inherits 求闭包）。
        -- 宿主受保护 ⇒ 子件也算受保护：客户端是引擎在宿主的安全上下文里建整棵树，
        -- 实机判例都是子件被拒（ActionButton5:SetShown / MultiBar*ButtonContainerN:SetShown）。
        local obj, st = api.NewObject(kind, globalName, hostObj, {
            blizzard = true,
            protected = (row[7] == 1) or (hostSt and hostSt.protected) or false,
        })
        st.row = rowIdx
        F.objects = F.objects + 1
        rowOfState[st] = rowIdx
        st.obj = obj
        if globalName then
            rawset(env, globalName, obj)
            F.named = F.named + 1
        end

        if keyName and hostSt then
            local m = keysOf[hostSt]
            if not m then m = {}; keysOf[hostSt] = m end
            m[keyName] = obj
            local hostSlots = hostSt.slots
            if hostSlots and artOf[hostSt] then
                for s, r in pairs(hostSlots) do
                    if r == rowIdx and artOf[hostSt][s] == nil then artOf[hostSt][s] = obj end
                end
            end
        end

        local myKids = {}
        kidsOf[st] = myKids
        local myKeys = {}
        keysOf[st] = myKeys
        local myUnder = {}
        under[st] = myUnder
        st.slots = slotMap(rowIdx, {}, {})
        local myArt = {}
        artOf[st] = myArt

        local mine = {}
        collect(rowIdx, mine, {})
        for i = 1, #mine do
            local c = mine[i]
            local child = buildRow(c.row, obj, st, globalName or hostName, depth + 1)
            if child then
                myKids[#myKids + 1] = child
                myUnder[c.row] = child
                if c.key > 0 then myKeys[strings[c.key]] = child end
                for s, r in pairs(st.slots) do
                    if r == c.row and myArt[s] == nil then myArt[s] = child end
                end
            end
        end
        return obj
    end

    --- 顶层实例化：只建"全局名字且 XML 顶层"的行；嵌套的全局名跟着宿主建。
    function F.InstantiateAll()
        for _, rowIdx in pairs(globalsByName) do
            if loaded(ownerOf[rowIdx]) and not building[rowIdx] then
                building[rowIdx] = true
                if rowIdx > 0 and rowIdx <= #rows and rows[rowIdx][4] == 0 then
                    buildRow(rowIdx, nil, nil, nil, 0)
                end
            end
        end
        -- 全局名但宿主是 virtual 模板：那棵树不会有人实例化它，补一份顶层实例。
        -- 与真客户端"模板内 name= 只在模板被实例化时才存在"不一致，所以单记一笔，
        -- run.lua 报告里会列出 —— 拿它当"能跑"的证据是危险的，只当"别因为缺对象而短路整条链"。
        for name, rowIdx in pairs(globalsByName) do
            if loaded(ownerOf[rowIdx]) and (instCount[rowIdx] or 0) == 0 then
                buildRow(rowIdx, nil, nil, nil, 0)
                F.unbuiltGlobals[name] = rowIdx
            end
        end
        return F.objects
    end

    --- 按名取（run.lua 检查 LoD 缺席时用）
    function F.ObjectByName(name)
        local obj = api.BYNAME[name]
        if obj then return obj end
        local rowIdx = globalsByName[name]
        if not rowIdx then return nil end
        if not loaded(ownerOf[rowIdx]) then return nil, "lod-not-loaded:" .. tostring(ownerOf[rowIdx]) end
        if building[rowIdx] then return nil end
        building[rowIdx] = true
        return buildRow(rowIdx, nil, nil, nil, 0)
    end

    function F.RowCount() return #rows end
    function F.GlobalNames()
        local out = {}
        for name, rowIdx in pairs(globalsByName) do
            if loaded(ownerOf[rowIdx]) then out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end
    F.HasGlobal = function(_, name) return globalsByName[name] ~= nil end
    F.ProvidedBy = function(_, name)
        local rowIdx = globalsByName[name]
        if not rowIdx then return nil end
        return ownerOf[rowIdx]
    end

    ---------------------------------------------------------------- 替身钩子
    api.hooks.blizzChild = function(st, k)
        if type(k) ~= "string" then return nil end
        local m = keysOf[st]
        return m and m[k] or nil
    end
    api.hooks.blizzList = function(st, want)
        local list = kidsOf[st]
        if not list then return {} end
        local kinds = (want == "frame") and api.FRAME_KINDS or api.REGION_KINDS
        local out = {}
        for _, c in ipairs(list) do
            if kinds[api.stateOf(c).kind] then out[#out + 1] = c end
        end
        return out
    end
    api.hooks.blizzArt = function(st, slot)
        local m = artOf[st]
        return m and m[slot] or nil
    end

    return F
end

return Frames
