-- release-dev-gate-probe.lua
-- 发布版 dev 门闸 / 启动提示 / 物理剥离链路的静态一致性回归桩。
--   lua tools/harness/release-dev-gate-probe.lua
--
-- 判据（11-10 作者指示）：dev 功能与开发期提示只在本地和仓库保留，发布包里
-- 不注册诊断命令、不打印自检提示、不含 DevTools.lua / Report.lua。

local function read(path)
    local f = assert(io.open(path, "rb"), "missing file: " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local passed, failed = 0, 0
local function check(name, ok, extra)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end
local function run(cmd)
    local h = assert(io.popen(cmd .. " 2>&1"))
    local out = h:read("*a") or ""
    local ok = h:close()
    return ok, out
end

local toc = read("MonetUI.toc")
local core = read("Core.lua")
local init = read("Init.lua")
local xml = read("Modules/Tools/Tools.xml")
local pkg = read(".pkgmeta")
local wf = read(".github/workflows/release.yml")
local strip = read("tools/strip-dev.js")
local deploy = read("tools/deploy-retail.ps1")
local sync = read("tools/sync-check.js")
local blocks = read("Modules/InfoBar/Blocks.lua")

-- ---------------------------------------------------------------------------
-- 1. dev 标记与运行期开关
-- ---------------------------------------------------------------------------
check("TOC 带 X-Dev-Build: dev（本地/仓库）", has(toc, "## X-Dev-Build: dev"))
check("TOC 不同时带 release 标记", not has(toc, "## X-Dev-Build: release"))
check("Core 从 TOC 元数据读 dev 标记",
    has(core, 'GetAddOnMetadata, ADDON_NAME, "X-Dev-Build"'))
check("取不到标记时默认关闭（fail-closed）",
    core:find("ns%.dev%s*=%s*%(ok and flag == \"dev\"%) and true or false") ~= nil)
check("DevPrint 只在 dev 版打印",
    has(core, "function ns:DevPrint(message)")
    and has(core, "if self.dev then self:Print(message) end"))
check("玩家向版本横幅仍用 ns:Print", has(core, 'ns:Print(string.format("v%s 已加载。'))

-- ---------------------------------------------------------------------------
-- 2. 诊断命令门闸 + 帮助文本分叉
-- ---------------------------------------------------------------------------
local devTable = core:match("local DEV_COMMANDS = {.-}") or ""
-- 表里每项是内嵌的 { ... }，非贪婪 `.-}` 会停在第一个内嵌表上；改按独立的收尾 `}` 行切。
local devSubTable = core:match("local DEV_SUBCOMMANDS = {(.-)\n}") or ""
check("DEV_COMMANDS 存在且列齐顶层诊断命令",
    devTable ~= ""
    and has(devTable, "scale = true, blocks = true, restrict = true, colors = true, lost = true,")
    and has(devTable, "compat = true, perf = true, report = true, devtools = true,"))
for _, keep in ipairs({ "status", "theme", "reset", "enable", "disable", "init" }) do
    check("玩家向顶层命令 " .. keep .. " 不在 DEV_COMMANDS 里",
        not devTable:find(keep .. "%s*=%s*true"))
end
check("DEV_SUBCOMMANDS 按模块精确匹配",
    devSubTable ~= ""
    and devSubTable:find("skins%s*=") ~= nil
    and has(devSubTable, "groupframes = { status=true }"))
check("不误伤 tweaks / bags 的玩家向子命令",
    not has(devSubTable, "tweaks") and not has(devSubTable, "bags"))
check("HandleSlash 开头有发布版拦截",
    core:find("local function HandleSlash.-if not ns%.dev then.-DEV_SUBCOMMANDS%[command%]") ~= nil)
check("PrintHelp 发布版提前 return", has(core, "if not ns.dev then return end"))
check("用法提示不再向发布版提 diagnose",
    has(core, 'if ns.dev and type(module.HandleCommand) == "function" then'))

-- ---------------------------------------------------------------------------
-- 3. 启动自检提示改 DevPrint（玩家主动命令输出仍走 Print）
-- ---------------------------------------------------------------------------
local prompts = {
    { "Core: 模块加载统计", core, 'self:DevPrint(string.format("已加载 %d/%d 个模块' },
    { "Core: UI 缩放固定", core, 'ns:DevPrint(string.format("UI 缩放：按 %d 高度固定' },
    { "Core: 客户端身份", core, 'ns:DevPrint("客户端：" .. ns:ClientIdentity())' },
    { "ActionBars: 动作条就绪", read("Modules/ActionBars/ActionBars.lua"), 'ns:DevPrint(("自绘动作条已就绪' },
    { "Skins: 美化窗口数", read("Modules/Skins/Skins.lua"), 'ns:DevPrint("界面美化已启用' },
    { "Nameplates: isSecure", read("Modules/Nameplates/Nameplates.lua"), 'ns:DevPrint(("|cffffa940姓名板有 %d 项' },
    { "Tweaks: 残留值", read("Modules/Tools/Tweaks.lua"), 'ns:DevPrint(("|cffffa940控制台优化：%d 条开关' },
    { "Tweaks: CVar 空转", read("Modules/Tools/Tweaks.lua"), 'ns:DevPrint(("|cffffa940控制台优化空转' },
    { "Skin:WarnOnce 静默但账本仍记", read("Utils/Skin.lua"),
      "rememberWarn(topic, message)" },
    { "Init: 自动对齐提示", init,
      'ns:DevPrint(string.format("启动设置：聊天框底边已与动作条对齐' },
    { "WhatsNew: 发布版不提 /mui report", read("Modules/Tools/WhatsNew.lua"),
      'ns.dev and "；出问题先跑' },
}
for _, p in ipairs(prompts) do check(p[1], has(p[2], p[3])) end
check("Skin:WarnOnce 走 DevPrint", has(read("Utils/Skin.lua"), "ns:DevPrint(message)"))
check("Init 的主动 Status 仍是 Print", has(init, 'ns:Print(string.format("|cffffd100启动设置|r'))

-- ---------------------------------------------------------------------------
-- 4. 发布链路：XML 标记 / .pkgmeta / workflow / 本地部署
-- ---------------------------------------------------------------------------
local devLines = 0
for line in (xml .. "\n"):gmatch("([^\n]*)\n") do
    if has(line, "<Script") and has(line, "<!-- DEV-ONLY -->") then devLines = devLines + 1 end
end
check("Tools.xml 恰好两行 DEV-ONLY Script", devLines == 2, "count=" .. devLines)
check("DEV-ONLY 标记只挂在两份 dev 文件上",
    has(xml, '<Script file="DevTools.lua"/><!-- DEV-ONLY -->')
    and has(xml, '<Script file="Report.lua"/><!-- DEV-ONLY -->'))
-- XML 注释里不能再嵌 <!--：否则客户端解析直接失败。
local commentBody = xml:match("<!%-%-%s*\n%s*加载顺序：(.-)%-%->") or ""
check("Tools.xml 大注释块存在且没有嵌套 <!--",
    commentBody ~= "" and not has(commentBody, "<!--"), commentBody:sub(1, 80))
check(".pkgmeta 物理排除两份 dev 文件",
    has(pkg, "Modules/Tools/DevTools.lua") and has(pkg, "Modules/Tools/Report.lua"))
check("tools/ 本身不进发布包", has(pkg, "  - tools"))
local guardAt = wf:find("Guard - TOC version must match the tag", 1, true)
local selfTestAt = wf:find("strip%-dev%.js %-%-self%-test", 1, false)
local stripAt = wf:find("node tools/strip%-dev%.js\r?\n", 1, false)
local packagerAt = wf:find("BigWigsMods/packager@v2", 1, true)
check("workflow 顺序：Guard → self-test → strip → packager",
    guardAt and selfTestAt and stripAt and packagerAt
    and guardAt < selfTestAt and selfTestAt < stripAt and stripAt < packagerAt)
check("strip 脚本有幂等防呆 / check / self-test",
    has(strip, "function verifyDevState") and has(strip, "function selfTest")
    and has(strip, "--check") and has(strip, "--self-test")
    and has(strip, "X-Dev-Build: release"))
check("本地部署仍递归复制 Modules（dev 文件留在本地）",
    has(deploy, "'Assets', 'Libs', 'Utils', 'Config', 'Modules'"))
check("sync-check 仍覆盖 Modules 目录", has(sync, "const DIRS = ['Assets', 'Libs', 'Utils', 'Config', 'Modules']"))
check("耐久度格不注册点击（与 infobar-durability-probe 交叉验证）",
    not has(blocks, 'onClick  = BlockClick("character")'))

-- ---------------------------------------------------------------------------
-- 5. 实跑两个只读模式：命令可用、且不改写仓库文件
-- ---------------------------------------------------------------------------
local okCheck, outCheck = run("node tools/strip-dev.js --check")
check("strip-dev --check 通过", okCheck == true and has(outCheck, "CHECK OK"), outCheck:sub(1, 160))
local okSelf, outSelf = run("node tools/strip-dev.js --self-test")
check("strip-dev --self-test 通过（dev→release 变换全过）",
    okSelf == true and has(outSelf, "SELF TEST OK"), outSelf:sub(1, 160))
check("两个只读模式没把 TOC 改成 release",
    has(read("MonetUI.toc"), "## X-Dev-Build: dev"))

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
