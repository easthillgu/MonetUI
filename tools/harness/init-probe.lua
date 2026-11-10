-- init-probe.lua
-- 启动前置层（Init.lua）的静态一致性回归桩。不依赖游戏：只读源码文本，
-- 钉住「加载顺序 / 部署清单 / 单一基线 / 污染判例」四件事。
--   lua tools/harness/init-probe.lua
--
-- 2026-11-10 判例：聊天框默认底边 145（暴雪预设）vs 动作条 31，需要 init
-- 在模块加载前统一基线；但 ChatFrame1 是 EditMode 系统帧，任何 SetPoint /
-- 写 systemInfo.isInDefaultPosition 都会把 secureexecuterange 带脏（HANDOFF §3.1）。

local function read(path)
    local f = assert(io.open(path, "rb"), "missing file: " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

-- 只留代码：注释里会引用判例原文（例如「不要对 ChatFrame1 ClearAllPoints」），
-- 直接全文搜会把「写着禁令的注释」误判成「违禁代码」。
local function stripComments(s)
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = (line:gsub("%-%-.*$", ""))
    end
    return table.concat(out, "\n")
end

local toc      = read("MonetUI.toc")
local init     = stripComments(read("Init.lua"))
local layout   = stripComments(read("Utils/Layout.lua"))
local core     = stripComments(read("Core.lua"))
local deploy   = read("tools/deploy-retail.ps1")
local synccheck = read("tools/sync-check.js")

local failed = 0
local function check(name, ok, detail)
    if ok then
        print("PASS  " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("  -> " .. detail) or ""))
    end
end

-- ① 加载顺序：Init.lua 必须在 Core.lua 之前（它要在 PLAYER_LOGIN 门闸上挂回调）。
-- TOC 注释里也写了「必须在 Core.lua 之前」，全文搜会先命中注释。只取加载行。
local loadLines = {}
for line in (toc .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
        loadLines[#loadLines + 1] = trimmed
    end
end
local order = table.concat(loadLines, "\n")
local iInit = order:find("Init.lua", 1, true)
local iCore = order:find("Core.lua", 1, true)
check("TOC: Init.lua 在 Core.lua 之前", iInit and iCore and iInit < iCore,
    "init=" .. tostring(iInit) .. " core=" .. tostring(iCore))

-- ② 部署清单：根目录新文件必须同步进 deploy 与 sync-check，否则客户端
--    TOC 指向的文件不存在 → 整个插件加载失败（2026-11-10 实测踩过）。
check("deploy-retail.ps1 清单含 Init.lua", deploy:find("'Init.lua'", 1, true) ~= nil)
check("sync-check.js 清单含 Init.lua", synccheck:find("'Init.lua'", 1, true) ~= nil)

-- ③ 单一基线：Init.SETUP.bottom 与 Utils/Layout.lua 的默认值必须是同一个数。
local setupBottom = tonumber(init:match("bottom%s*=%s*(%d+)"))
local layoutBottom = tonumber(layout:match("bottom%s*=%s*(%d+)"))
check("SETUP.bottom == Layout.bottom", setupBottom and layoutBottom and setupBottom == layoutBottom,
    "setup=" .. tostring(setupBottom) .. " layout=" .. tostring(layoutBottom))
check("Init 在加载期写回 ns.Layout.bottom",
    init:find("ns%.Layout%.bottom%s*=%s*self%.SETUP%.bottom") ~= nil
    and init:find("Init:ApplyStatic()", 1, true) ~= nil)

-- ④ 污染判例：不碰系统帧位置、不写编辑模式脏值。
check("不写 systemInfo.isInDefaultPosition", init:find("isInDefaultPosition%s*=") == nil)
check("不对 ChatFrame1 设位置",
    init:find("ChatFrame1[:%.]SetPoint") == nil
    and init:find("ClearAllPoints") == nil
    and init:find("SetClampRectInsets") == nil)
check("对齐只改 anchorInfo.offsetY 一条",
    init:find("chat%.anchorInfo%.offsetY%s*=%s*self%.SETUP%.bottom") ~= nil)
check("保存结果以 C_EditMode 读回为准",
    init:find("GetLayouts") ~= nil and init:find("persisted") ~= nil)

-- ⑤ 幂等 / 门闸 / 配置。
check("对齐标记只在保存成功时落地",
    init:find("db%.chatAligned%s*=%s*true") ~= nil
    and core:find("chatAligned%s*=%s*false") ~= nil)
check("Core 通过 Init:Run 放行模块",
    core:find("ns%.Init:Run%(Boot%)") ~= nil)
check("提供 /mui init status|run",
    core:find("command%s*==%s*\"init\"") ~= nil
    and core:find("/mui init status", 1, true) ~= nil)
check("自动对齐有次数上限与兜底",
    init:find("self%.attempts%s*>%s*2") ~= nil
    and init:find("PLAYER_ENTERING_WORLD", 1, true) ~= nil
    and init:find("C_Timer%.After%(3") ~= nil)

-- ⑥ 11-10 实机判例：布局被删 / 换账号后，存档里残留的 chatAligned=true 会让
--    init 永远跳过重建（表现：标记已对齐、lastAlign=未运行、聊天框回到 145）。
check("幂等 = 标记 + 布局仍在，且布局丢失时清标记重建",
    init:find("db%.chatAligned and HasAlignedLayout") ~= nil
    and init:find("db%.chatAligned%s*=%s*false") ~= nil
    and init:find("db%.chatAligned and layoutExists") ~= nil)
check("/mui init status 会报告对齐布局是否存在",
    init:find("HasAlignedLayout%(self%.SETUP%.chatLayoutName%)") ~= nil)

-- ⑦ 版本单一数据源：0.13.0 / 0.13.1 发版漏改 Core 的硬编码 0.12.0，
--    启动横幅与 /mui status 报旧版本。ns.version 必须从 TOC 元数据读。
check("ns.version 不硬编码，改从 TOC 读",
    core:find("ns%.version%s*=%s*\"") == nil
    and core:find("GetAddOnMetadata") ~= nil
    and core:find("@project%-version@") == nil)

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
