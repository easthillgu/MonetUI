-- tools/harness/samples/bad-secret-math.lua
-- 故意写坏：拿到客户端给的机密值以后**没先问 Secrets 层**就直接比较 / 拼接。
-- 平明期它是一个普通数字（不出红）；受限窗口里它是机密值 ——
-- 期望：断言一记一条 A0 红（比较运算被客户端拦下），并且机密值不会静默变成 nil。
local ADDON_NAME, ns = ...

local M = {}
ns:Register("HarnessSampleSecretMath", M)

function M:Apply()
    local health = _G.UnitHealth and _G.UnitHealth("player")
    if health and health > 0 then          -- 机密值上做比较：attempt to compare …
        local label = "血量 " .. health    -- 机密值进字符串：attempt to concatenate …
        local fs = _G.HarnessSampleSecretText
        if fs and fs.SetText then fs:SetText(label) end
    end
end
