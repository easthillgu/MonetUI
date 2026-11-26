-- Init 旧 CVar 迁移与分阶段启动的真实代码回归。
--   lua tools/harness/init-cvar-stage-probe.lua [repo-root]

local root = arg[1] or "."
local checks = 0
local function check(name, condition)
    assert(condition, name)
    checks = checks + 1
    print("PASS  " .. name)
end

local function world()
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local state = {
        values = {}, info = {}, writes = {}, timers = {}, listeners = {},
        loaded = true, failRead = false, failInfo = false, rejectWrite = false, silentWrite = false,
        secretAfterWrite = false, restricted = false,
    }
    local secret = setmetatable({}, { __metatable = "secret" })
    state.secret = secret

    env.C_CVar = {
        AreCVarsLoaded = function() return state.loaded end,
        GetCVar = function(name)
            if state.failRead then error("mock read failure") end
            return state.values[name]
        end,
        GetCVarInfo = function(name)
            if state.failInfo then error("mock info failure") end
            local rec = state.info[name]
            if rec then
                return rec.value, rec.default or "0", nil, nil,
                    rec.locked, rec.secure, rec.readonly
            end
            return state.values[name], "0", nil, nil, nil, false, false, false
        end,
        SetCVar = function(name, value)
            state.writes[#state.writes + 1] = { name = name, value = value }
            if state.rejectWrite then error("mock write denied") end
            if not state.silentWrite then
                state.values[name] = state.secretAfterWrite and secret or value
            end
        end,
    }
    env.C_Timer = {
        After = function(_, fn)
            state.timers[#state.timers + 1] = fn
        end,
    }
    local function runTimers()
        local batch = state.timers
        state.timers = {}
        for _, fn in ipairs(batch) do fn() end
    end
    state.runTimers = runTimers

    env.EditModeManagerFrame = {
        layoutInfo = { layouts = { { layoutName = "MonetUI" } } },
    }
    local ns = {
        Layout = { bottom = 145 },
        DB = function() return state.db end,
        Secrets = {
            IsSecret = function(value) return value == secret end,
            CanRead = function(value) return value ~= secret end,
            Bool = function(value, default)
                if value == secret or value == nil then return default end
                return value and true or false
            end,
        },
        EventBus = {
            Register = function(_, event, fn)
                state.listeners[event] = state.listeners[event] or {}
                table.insert(state.listeners[event], fn)
                return fn
            end,
        },
        IsRestricted = function() return state.restricted end,
        DevPrint = function() end,
        Print = function() end,
    }
    env.MonetUIDB = {
        schema = 9,
        init = { chatAligned = true },
        combatText = { enabled = true, saved = {} },
        tweaks = { lootRange = true, worldTextScale = true },
        tweakOrigin = { autoLootRange = "0", worldTextScale = "1" },
    }
    state.db = env.MonetUIDB

    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = assert(loadfile(root .. "/Init.lua"))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile(root .. "/Init.lua", "t", env))
    end
    chunk("MonetUI", ns)
    return env, ns, ns.Init, state
end

local function seedCombat(state)
    state.db.combatText.saved.floatingCombatTextCombatDamage_v2 = "1"
    state.db.combatText.saved.floatingCombatTextCombatHealing_v2 = "0"
    state.db.combatText.saved.gamma = "0.75"
    state.values.floatingCombatTextCombatDamage_v2 = "0"
    state.values.floatingCombatTextCombatHealing_v2 = "0"
    state.values.autoLootRange = "1"
end

local function writeCount(state, name)
    local count = 0
    for _, write in ipairs(state.writes) do
        if write.name == name then count = count + 1 end
    end
    return count
end

local _, _, Init, state = world()
state.loaded = false
seedCombat(state)
check("CVar 未加载时等待且不写", Init:Prepare() == false and #state.writes == 0)
check("CVar 未加载时保留旧账", state.db.combatText.saved ~= nil)
state.loaded = true
check("加载完成后恢复白名单原值", Init:Prepare() == true)
check("旧 CombatText 原值按读回结果结算",
    state.values.floatingCombatTextCombatDamage_v2 == "1"
    and state.values.floatingCombatTextCombatHealing_v2 == "0"
    and state.db.combatText == nil)
check("非白名单存档键不被当作 CVar 写入",
    writeCount(state, "gamma") == 0 and state.values.gamma == nil)
check("废弃 autoLootRange 账目恢复", state.values.autoLootRange == "0")
check("lootRange 开关清理且其他设置保留",
    state.db.tweaks.lootRange == nil and state.db.tweaks.worldTextScale == true
    and state.db.tweakOrigin.autoLootRange == nil
    and state.db.tweakOrigin.worldTextScale == "1")
local writes = #state.writes
check("清理幂等", Init:Prepare() == true and #state.writes == writes)

_, _, Init, state = world()
seedCombat(state)
state.values.floatingCombatTextCombatDamage_v2 = "1"
check("玩家改过当前值时只清账不覆盖", Init:Prepare() == true
    and writeCount(state, "floatingCombatTextCombatDamage_v2") == 0
    and state.values.floatingCombatTextCombatDamage_v2 == "1")

_, _, Init, state = world()
seedCombat(state)
state.db.combatText.saved[state.secret] = "untrusted"
check("机密存档键不参与表索引", Init:Prepare() == true
    and state.db.combatText == nil and writeCount(state, "gamma") == 0)

_, _, Init, state = world()
seedCombat(state)
state.db.combatText.saved.floatingCombatTextCombatDamage_v2 = state.secret
state.db.tweakOrigin.autoLootRange = state.secret
check("机密原值不比较、不写入且保留账", Init:Prepare() == false
    and writeCount(state, "floatingCombatTextCombatDamage_v2") == 0
    and writeCount(state, "autoLootRange") == 0
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == state.secret
    and state.db.tweakOrigin.autoLootRange == state.secret)

_, _, Init, state = world()
seedCombat(state)
state.values.floatingCombatTextCombatDamage_v2 = state.secret
check("机密当前值不写且保留账", Init:Prepare() == false
    and writeCount(state, "floatingCombatTextCombatDamage_v2") == 0
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1")
check("限制解除事件只注册一次", #state.listeners.MONETUI_RESTRICTION_CHANGED == 1)
state.restricted = true
state.listeners.MONETUI_RESTRICTION_CHANGED[1]("Combat", true)
state.runTimers()
check("限制仍生效时不重试写入", #state.writes == 2)
state.values.floatingCombatTextCombatDamage_v2 = "0"
state.restricted = false
state.listeners.MONETUI_RESTRICTION_CHANGED[1]("Combat", false)
state.runTimers()
check("限制解除后补做旧账恢复", state.db.combatText == nil
    and state.values.floatingCombatTextCombatDamage_v2 == "1")

_, _, Init, state = world()
seedCombat(state)
state.rejectWrite = true
check("SetCVar 抛错时保留原值账", Init:Prepare() == false
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1")
state.rejectWrite = false
check("写失败后可重试", Init:Prepare() == true
    and state.values.floatingCombatTextCombatDamage_v2 == "1")

_, _, Init, state = world()
seedCombat(state)
state.silentWrite = true
check("SetCVar 静默不落地时保留原值账", Init:Prepare() == false
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1")
state.silentWrite = false
state.secretAfterWrite = true
check("写后机密复验按失败处理", Init:Prepare() == false
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1")

_, _, Init, state = world()
seedCombat(state)
state.failRead = true
state.failInfo = true
check("读取失败不被误判为 CVar 不存在", Init:Prepare() == false
    and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1"
    and #state.writes == 0)

for _, flag in ipairs({ "locked", "secure", "readonly" }) do
    _, _, Init, state = world()
    seedCombat(state)
    state.info.floatingCombatTextCombatDamage_v2 = { [flag] = true }
    check("CVar " .. flag .. " 时拒写并保留账", Init:Prepare() == false
        and writeCount(state, "floatingCombatTextCombatDamage_v2") == 0
        and state.db.combatText.saved.floatingCombatTextCombatDamage_v2 == "1")
end

_, _, Init, state = world()
seedCombat(state)
state.values.autoLootRange = nil
state.info.autoLootRange = { value = nil, default = nil }
check("不存在的废弃 CVar 只清账不写", Init:Prepare() == true
    and state.db.tweakOrigin.autoLootRange == nil
    and writeCount(state, "autoLootRange") == 0)

_, _, Init, state = world()
seedCombat(state)
state.values.autoLootRange = "0"
check("废弃 CVar 已被玩家改过时只清账", Init:Prepare() == true
    and state.db.tweakOrigin.autoLootRange == nil
    and writeCount(state, "autoLootRange") == 0)

local env, ns, Init, state = world()
local ready = 0
ns.Async = {
    Run = function(_, body, onDone, name)
        check("启动任务带显式标签", name == "启动:模块初始化")
        local co = coroutine.create(body)
        state.co = co
        local job = {
            resume = function()
                local ok, err = coroutine.resume(co)
                assert(ok, err)
                if coroutine.status(co) == "dead" and onDone then onDone() end
            end,
        }
        state.job = job
        return job
    end,
}
Init:Run(function() ready = ready + 1 end)
check("Init:Run 不同步执行重模块", ready == 0 and state.co ~= nil)
check("启动中状态可诊断", Init.reason == "模块启动任务已排队")
state.job.resume()
check("协程完成后才放行模块", ready == 1 and Init.reason == "模块已放行")
local timers = #state.timers
state.runTimers()
check("聊天布局仍延后且对齐标记避免重建", Init.attempts == 0 and #state.timers <= timers)

ns.Async = nil
Init:Run(function() error("expected startup failure") end)
check("无 Async 时启动异常被隔离", Init.reason:find("模块启动异常", 1, true) ~= nil)
Init:Run(nil)
check("无启动回调时不误报异常", Init.reason == "模块已放行")

print(("ALL PASS (%d checks)"):format(checks))
