-- Utils/Coexist.lua
-- 共存归因注册表（#28，2026-11-06）。
--
-- 要解决的问题：同机几十个插件会"接管"暴雪对象（开服日第一例：RurutiaSuite 的 MinimapCollector
-- 按 _G.Minimap 子树收养按钮，把我们的 MonetUIMinimapOverlay 搬走 + ClearAllPoints ⇒ 命中区 0×0，
-- 右键微型菜单 / 滚轮缩放 / 悬停区域名三条一起哑，且**零红字零 BLOCKED** —— 光看日志根本查不出来，
-- 只能人工读第三方源码归因）。
--
-- 这张表把"归因"变成自动的：模块声明"我拥有哪个表面 + 怎么判断它被别的插件接管了 + 接管者是谁"，
-- `Coexist:Scan()` 扫一遍，`/mui report` 出一行"某表面被某 addon 接管"。
--
-- 两条硬约束：
--   ① **只读检测，绝不自动静默**。误判静默 = 模块无声失效，比 Minimap 现在的"自愈重挂父"更糟。
--      需要降级的模块可以自己调 `Coexist:ContestedBy(key)` 决定，但注册表本身不改任何模块状态。
--   ② 检测器 `detect(surfaceObj)` 必须**不写任何东西**、pcall 兜住、返回 (contested?, takerName)。
--      读暴雪来的字符串/数字前按 Secrets 规矩（这里 taker 名走 GetName，是字符串，进 format 前由调用方守卫）。
local ADDON_NAME, ns = ...

local Coexist = {}
ns.Coexist = Coexist

-- key -> { surface = "点路径", detect = function(obj)->contested,taker, note }
local owned = {}

--- 模块登记一个"我拥有的表面"。surface 可省（detect 自己取对象）。
function Coexist:Own(key, spec)
    if type(key) ~= "string" or type(spec) ~= "table" then return end
    owned[key] = spec
end

--- 扫一遍所有登记的表面。返回按 key 排序的 { {key, contested, taker, note}, ... }。
--- 单个检测器抛错不影响其余（pcall 兜住，当"没被接管"）。
function Coexist:Scan()
    local out = {}
    for key, spec in pairs(owned) do
        local contested, taker
        if type(spec.detect) == "function" then
            local obj = spec.surface and ns.ResolveObject and ns.ResolveObject(spec.surface) or nil
            local ok, c, t = pcall(spec.detect, obj)
            if ok then contested = c and true or false; taker = t end
        end
        out[#out + 1] = { key = key, contested = contested, taker = taker, note = spec.note }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- 模块可选查询：我这个表面现在被谁接管了？没被接管返回 nil。
--- 用它来"有依据地降级"（比如接管者已经把这个表面做得够好，我们让位），而不是盲目常驻。
function Coexist:ContestedBy(key)
    for _, e in ipairs(self:Scan()) do
        if e.key == key and e.contested then return e.taker end
    end
    return nil
end

return Coexist
