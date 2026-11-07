-- tools/tweaks-vision-probe.lua
-- `/mui tweaks vision` 的打印闸门。
-- 为什么值得单独测：这条命令是"画面发灰"时唯一的判读入口，它本身崩掉就等于没有诊断。
-- 风险全在格式化：`%d` 收到 string、`%.2f` 收到 nil 都是运行期报错，而且只在那一种
-- CVar 形态下触发（例如客户端返回数字、或根本不返回这个 CVar）。
--
-- 用桩件加载**真实** Modules/Tools/Tweaks.lua，验证：
--   1) 正常形态（客户端答 value + default）全流程不抛
--   2) 偏离默认的项被标出来，条数对得上
--   3) 客户端没有的 CVar 打成「本客户端没有」，不是 0 或空
--   4) 数字型值（RenderScale / default 是 number）不会喂崩 %s / 比较
--   5) 暗角模块缺席时不抛（没装/被裁）
--
-- 跑法：lua tools/tweaks-vision-probe.lua    退出码 0 = 全绿
-- 依赖：lua 5.4（loadfile 三参 env）；无第三方库。

local env = setmetatable({}, { __index = _G })
env._G = env

-- 模拟"存档里 tweaks 全开"的客户端：value = 打开后的目标值，default = 客户端原值。
local CVARS = {
    ResampleAlwaysSharpen = { value = "1", default = "0" },
    particleDensity       = { value = "0", default = "100" },
    volumefog             = { value = "0", default = "1" },
    ffxGlow               = { value = "0", default = "1" },
    ffxDeath              = { value = "0", default = "1" },
    weatherDensity        = { value = "0", default = "3" },
    ResampleQuality       = { value = "1", default = "1" },
    RenderScale           = { value = "1.000000", default = "1.000000" },
    -- 故意不给 particleDensity 之外的做缺失测试：下面单独删一项
}

local MISSING = "volumefog"

local function Info(name)
    local rec = CVARS[name]
    if not rec then return nil end
    -- 与项目里已验证的返回位次一致：value, default, _, _, _, locked, secure, readonly
    return rec.value, rec.default, nil, nil, nil, false, false, false
end

env.C_CVar = {
    GetCVar = function(name)
        local rec = CVARS[name]
        return rec and rec.value or nil
    end,
    GetCVarInfo = function(name) return Info(name) end,
    SetCVar = function() return true end,
}
env.GetMinRenderScale = function() return 0.33 end
env.GetMaxRenderScale = function() return 1.0 end

local printed = {}
local ns = {}
ns.Secrets = { IsSecret = function() return false end }
ns.Print = function(_, msg) printed[#printed + 1] = tostring(msg) end
ns.DB = function()
    -- 与用户存档一致：九条全开（2026-11-07 实机 MonetUI.lua 的 db.tweaks）
    return {
        tweaks = {
            cameraZoom = true, lootRange = true, combatText = true, questGlow = true,
            noDeathGray = true, sharpen = true, noWeather = true, fewParticles = true,
            noFog = true,
        },
        atmosphere = { strength = 0.10 },
    }
end
ns.Register = function() end
ns.GetModule = function(name)
    if name == "Atmosphere" then
        return { Tier = function() return { alpha = 0.10 } end }
    end
    return nil
end
ns.IsModuleEnabled = function() return true end

local chunk = assert(loadfile("Modules/Tools/Tweaks.lua", "t", env))
chunk("MonetUI", ns)
local T = assert(ns.Tweaks, "ns.Tweaks 未导出")

local fail = 0
local function check(name, cond, extra)
    if not cond then
        print("  ✗ " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
        fail = fail + 1
    else
        print("  ✓ " .. name)
    end
end

--- 逐个测试用例重跑一遍 Vision，并收集输出。
local function Run(label)
    printed = {}
    local ok, err = pcall(T.Vision, T)
    local text = table.concat(printed, "\n")
    return ok, err, text
end

print("== 1) 全开形态 ==")
local ok, err, text = Run("all-on")
check("Vision 不抛错", ok, err)
check("列出了锐化 CVar", text:find("ResampleAlwaysSharpen", 1, true) ~= nil)
check("标出了「偏离」", text:find("偏离", 1, true) ~= nil)
check("打出了判读汇总", text:find("判读：偏离默认", 1, true) ~= nil)
-- ResampleQuality 与 RenderScale 没偏离，其余 6 条偏离（含 ffxGlow/ffxDeath/weatherDensity）
local n = tonumber(text:match("判读：偏离默认 (%d+) 条")) or -1
check("偏离条数 = 6（7 条里只有 ResampleQuality 没偏离）", n == 6, n)
check("指出了「本插件写」", text:find("本插件写", 1, true) ~= nil)
check("给了先关哪条的命令", text:find("/mui tweaks set sharpen 0", 1, true) ~= nil)

print("== 2) 客户端没有这个 CVar ==")
local saved = CVARS[MISSING]
CVARS[MISSING] = nil
ok, err, text = Run("missing")
check("缺 CVar 时不抛", ok, err)
check("缺 CVar 打成「本客户端没有」", text:find("本客户端没有", 1, true) ~= nil)
CVARS[MISSING] = saved

print("== 3) 只有 value、没有 default（客户端不回默认值）==")
local oldInfo = env.C_CVar.GetCVarInfo
env.C_CVar.GetCVarInfo = function(name)
    local rec = CVARS[name]
    if not rec then return nil end
    return rec.value -- 只回一个值：default = nil
end
ok, err, text = Run("no-default")
check("没有 default 时不抛", ok, err)
check("没有 default 时不误标偏离", text:find("判读：偏离默认 0 条", 1, true) ~= nil,
    text:match("判读：[^\n]*"))
env.C_CVar.GetCVarInfo = oldInfo

print("== 4) 数字型 default（部分客户端把 default 当 number 给）==")
env.C_CVar.GetCVarInfo = function(name)
    local rec = CVARS[name]
    if not rec then return nil end
    return rec.value, tonumber(rec.default) -- default 是 number
end
ok, err, text = Run("numeric-default")
check("数字型 default 不抛", ok, err)
check("数字型 default 仍能判偏离", text:find("判读：偏离默认 6 条", 1, true) ~= nil)
env.C_CVar.GetCVarInfo = oldInfo

print("== 5) 没有暗角模块 ==")
local oldGet = ns.GetModule
ns.GetModule = function() return nil end
ok, err, text = Run("no-atmosphere")
check("暗角缺席时不抛", ok, err)
ns.GetModule = oldGet

print(fail == 0 and "\n全部通过" or ("\n失败 " .. fail .. " 项"))
os.exit(fail == 0 and 0 or 1)
