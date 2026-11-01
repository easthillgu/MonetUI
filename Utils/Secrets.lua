-- Utils/Secrets.lua
-- Secret-value guard (保密值处理层) for the "Forever" client (Interface 16001).
-- Under a restriction (combat, PvP, boss encounters, chat lockdown ...) the client hands addons *secret* values for health, power, identity, auras and cooldowns: a secret may pass to widgets untouched (e.g. StatusBar:SetValue), but arithmetic / comparison / formatting / concatenation raises "attempt to perform arithmetic on a secret number value".
-- Every module must therefore ask this layer first and only compute plainly when the client reports the value is NOT secret.

local ADDON_NAME, ns = ...

local Secrets = {}
ns.Secrets = Secrets

local function API()
    return _G.C_Secrets
end

--- Is this client build capable of hiding values at all?
function Secrets.Enabled()
    local api = API()
    if not api or not api.HasSecretRestrictions then return false end
    local ok, restricted = pcall(api.HasSecretRestrictions)
    return (ok and restricted) and true or false
end

-- Generic "should this be secret?" wrapper.  A missing client API is treated as *secret* so that a query we do not understand can never cause an error.
local function Ask(query, ...)
    if not Secrets.Enabled() then return false end
    local api = API()
    local fn = api and api[query]
    if not fn then return true end
    local ok, isSecret = pcall(fn, ...)
    if not ok then return true end
    -- 查询本身可能返回**机密布尔**（ArcAuras 在同一处踩过）：对它做真值测试会被客户端
    -- 拦成 ADDON_ACTION_BLOCKED。机密答案一律按"受限"处理（= true）。
    if Secrets.IsSecret(isSecret) then return true end
    return isSecret and true or false
end

function Secrets.HealthSecret(unit)     return Ask("ShouldUnitHealthMaxBeSecret", unit) end
function Secrets.PowerSecret(unit, pt)  return Ask("ShouldUnitPowerBeSecret", unit, pt) end
function Secrets.IdentitySecret(unit)   return Ask("ShouldUnitIdentityBeSecret", unit) end
function Secrets.CastSecret(unit)       return Ask("ShouldUnitSpellCastingBeSecret", unit) end
function Secrets.AurasSecret()          return Ask("ShouldAurasBeSecret") end
function Secrets.CooldownsSecret()      return Ask("ShouldCooldownsBeSecret") end

-- Convenience inverses: "can I do maths / read a string?"

function Secrets.CanMeasureHealth(unit)     return not Secrets.HealthSecret(unit) end
function Secrets.CanMeasurePower(unit, pt)  return not Secrets.PowerSecret(unit, pt) end
function Secrets.CanReadIdentity(unit)      return not Secrets.IdentitySecret(unit) end
function Secrets.CanReadAuras()             return not Secrets.AurasSecret() end

--- Enum.StatusBarInterpolation.ExponentialEaseOut when the client has it, else nil.
-- Handed to StatusBar:SetValue the bar eases inside the client, so it keeps working while the value itself is secret; guarded because the enum is not on every build.
Secrets.SMOOTH = nil
do
    local ok, value = pcall(function()
        local enum = _G.Enum
        local interpolation = enum and enum.StatusBarInterpolation
        return interpolation and interpolation.ExponentialEaseOut
    end)
    if ok and type(value) == "number" then Secrets.SMOOTH = value end
end

local function Add0(value) return value + 0 end

--- Plain boolean test for whether a value is a secret.
function Secrets.IsSecret(value)
    if value == nil then return false end
    local is = _G.issecretvalue
    if is then
        local ok, res = pcall(is, value)
        if ok then return res and true or false end
    end
    return false
end

--- 这个值**当前这个调用上下文**能不能读/运算？（1.60 正规前置：`canaccessvalue`）
--- 与 `IsSecret` 的区别：`issecretvalue` 只说"是不是机密"，`canaccessvalue` 说的是
--- "我此刻能不能对它做运算/比较" —— 后者才是我们真正要的那道门，而且它不抛（call: ok，插件可调）。
--- 客户端没有这个名字（老构建/别的客户端）时退回 `not IsSecret`，行为与以前一致。
function Secrets.CanRead(value)
    if value == nil then return true end
    local can = _G.canaccessvalue
    if can then
        local ok, res = pcall(can, value)
        if ok then return res and true or false end
        return false
    end
    return not Secrets.IsSecret(value)
end

--- Return `value` as a plain number, or nil when it is secret / not numeric.
function Secrets.Number(value)
    if value == nil then return nil end
    if not Secrets.CanRead(value) then return nil end
    local ok, number = pcall(Add0, value)
    if ok and type(number) == "number" then return number end
    return nil
end

--- 把血量百分比写进一个 FontString —— **机密值也画得出来**。
---
--- 为什么需要这个入口（2026-11-01 副本内实机）：
---   `Secrets.CanMeasureHealth()` 不能当门。它问的是 `C_Secrets.ShouldUnitHealthMaxBeSecret`，
---   而这个答案和真实值会**不一致**：实测 `CanMeasureHealth("player") = true`，可
---   `UnitHealth("player")` 返回的却是机密值（`Secrets.Number` 拿 nil）；反过来
---   `CanMeasureHealth("target" / "nameplate1") = false` 又把整条路直接挡掉。
---   结果就是玩家框、目标框、26 块姓名板的血量文字全是空白（不报错，纯静默失效）。
---
---   `UnitHealthPercent()` 返回的是**机密数字**，但 `SetFormattedText` 吃得下（引擎侧格式化）——
---   小队/团队/首领的百分比一直是这么画出来的，所以那条路是好的。
---
--- @param fs      FontString（要有 SetFormattedText）
--- @param unit    单位令牌，机密百分比要走 `UnitHealthPercent(unit, …)`
--- @param current 已读到的当前血量（可能机密 / nil）
--- @param maximum 已读到的最大血量（可能机密 / nil）
--- @param fmt     printf 模板，默认 "%.0f%%"
--- @return true = 已经写进去了；false = 这个单位现在拿不到百分比（调用方自己决定留空还是保留上次）
function Secrets.FormatHealthPercent(fs, unit, current, maximum, fmt)
    if not fs or type(fs.SetFormattedText) ~= "function" then return false end
    fmt = fmt or "%.0f%%"

    -- 1) 能算就算：普通值下 c/m 最准，也顺带让调用方还能拿到这个比值去上色
    local c, m = Secrets.Number(current), Secrets.Number(maximum)
    if c and m and m > 0 then
        return pcall(fs.SetFormattedText, fs, fmt, c / m * 100)
    end

    -- 2) 机密值：交给客户端的百分比曲线。**值级判**（IsSecret 在比较之前），
    --    因为 `pct ~= nil` 本身在旧构建上就是一次被拦的比较。
    local constants = _G.CurveConstants
    if unit and _G.UnitHealthPercent and constants and constants.ScaleTo100 then
        local ok, pct = pcall(_G.UnitHealthPercent, unit, true, constants.ScaleTo100)
        if ok and (Secrets.IsSecret(pct) or pct ~= nil) then
            return pcall(fs.SetFormattedText, fs, fmt, pct)
        end
    end
    return false
end

local function TestBool(value)
    if value then return true end
    return false
end

-- 诊断：真值测试被客户端拦下时（机密布尔,设计内软拦），记**我们自己的账**——
-- 调用栈进旁表,探针直读,不再依赖 Logs/taint.log 的批量 flush（实机两次 A/B 窗口
-- 均零字节未落）。只记失败路径,成功路径零开销;表封顶丢弃,防长时段膨胀。
local boolBlocks = {}
local boolBlocksSeen = 0

--- 最近被拦的 Bool 调用（调试用）: { { at, stack }... } + 总数。只增不清(重载清)。
function Secrets.BoolBlocks()
    return boolBlocks, boolBlocksSeen
end

--- Truthiness test that survives secret booleans.
-- **值级前置在唯一的漏斗里做**（2026-10-25）：`issecretvalue` 读取本身不触发客户端的
-- "对机密值做布尔测试"拦截，所以机密值直接落回 `default`（= 以前被拦之后的回退值，
-- 逐位一致），非机密才真值测试。全仓 30 多个调用点因此不需要逐个改。
-- 失败路径（例如 issecretvalue 不可用的构建）仍然记账，见 `Secrets.BoolBlocks()`。
function Secrets.Bool(value, default)
    if not Secrets.CanRead(value) then return default end
    local ok, result = pcall(TestBool, value)
    if ok then return result end
    -- true 测试被客户端拦了（理论上不该再走到这里）。记调用栈（纯字符串，机密值不进 concat）。
    boolBlocksSeen = boolBlocksSeen + 1
    if #boolBlocks < 200 then
        local stack
        if type(_G.debugstack) == "function" then
            stack = _G.debugstack(2, 2, 4)
        end
        boolBlocks[#boolBlocks + 1] = { at = GetTime(), stack = stack or "?" }
    end
    return default
end

--- Run a function that may touch secret values; returns pcall's ok, ...
function Secrets.Measure(fn, ...)
    return pcall(fn, ...)
end

--- Feed a status bar without ever doing arithmetic on the values; returns true when the widget accepted both calls.
-- @param interpolation optional Secrets.SMOOTH; both calls take secret values, so the smooth path is used whenever the client takes it.
function Secrets.SetBar(bar, current, maximum, interpolation)
    if not bar then return false end

    local okRange
    if interpolation then
        okRange = pcall(bar.SetMinMaxValues, bar, 0, maximum, interpolation)
    end
    if not okRange then
        okRange = pcall(bar.SetMinMaxValues, bar, 0, maximum)
    end
    if not okRange then
        okRange = pcall(bar.SetMinMaxValues, bar, 0, 100)
    end

    local okValue
    if interpolation then
        okValue = pcall(bar.SetValue, bar, current, interpolation)
    end
    if not okValue then
        okValue = pcall(bar.SetValue, bar, current)
    end

    return okRange and okValue
end

--- Human readable description of the current restriction mode.
function Secrets.Describe()
    if not Secrets.Enabled() then
        return "此客户端允许插件读取所有单位数值。"
    end
    return "此客户端在战斗等状态下会向插件隐藏部分单位数值；血条仍会填充，但数字可能暂时为空。"
end
