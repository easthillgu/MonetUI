-- childrenof-probe.lua
-- 用 Utils/Widget.lua 里的真实实现验证 GetChildren 唯一漏斗：多返回值必须整组收进表，
-- forbidden 对象（读子级会抛）与缺方法的对象都不能把调用方带崩。
--   lua tools/harness/childrenof-probe.lua

local root = arg[1] or "."
local fh = assert(io.open(root .. "/Utils/Widget.lua", "rb"))
local src = fh:read("*a")
fh:close()

local a = assert(src:find("local function captureChildren", 1, true), "captureChildren 不见了")
local b = assert(src:find("function Widget:ChildrenOf", 1, true), "Widget:ChildrenOf 不见了")
local c = assert(src:find("\nend", b, true), "Widget:ChildrenOf 没有收尾")
local block = src:sub(a, c + 3)

local Widget = {}
local env = setmetatable({ Widget = Widget }, { __index = _G })
local chunk, err = load(block, "Widget.ChildrenOf", "t", env)
assert(chunk, "取出来的片段加载失败: " .. tostring(err))
chunk()

local failures = 0
local function check(label, ok)
    if not ok then failures = failures + 1 end
    print((ok and "  [OK]   " or "  [FAIL] ") .. label)
end

local a1, a2, a3 = {}, {}, {}
local frame = {
    GetChildren = function() return a1, a2, a3 end,
}
local ok, kids = Widget:ChildrenOf(frame)
check("多返回值整组收进表", ok and type(kids) == "table" and #kids == 3
    and kids[1] == a1 and kids[2] == a2 and kids[3] == a3)

local forbidden = {
    GetChildren = function() error("forbidden", 0) end,
}
local ok2, kids2 = Widget:ChildrenOf(forbidden)
check("读不出来时返回 false, nil（不抛）", ok2 == false and kids2 == nil)

local ok3, kids3 = Widget:ChildrenOf({})
check("没有 GetChildren 时返回 false, nil", ok3 == false and kids3 == nil)

local ok4, kids4 = Widget:ChildrenOf(nil)
check("nil 对象返回 false, nil", ok4 == false and kids4 == nil)

print(failures == 0 and "全部通过" or (failures .. " 项未通过"))
os.exit(failures == 0 and 0 or 1)
