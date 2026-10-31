<#
make-lane.ps1 —— 多 harness 车道创建器（工作流详见 docs/MULTI-HARNESS.md）

用法（在仓库任意位置）：
  powershell -File tools\make-lane.ps1 -Name qoder -Task auras-refactor
  powershell -File tools\make-lane.ps1 -Name wb     -Task stripe-textures

做什么：
  1. git worktree add ..\MonetUI-lane-<Name>（分支 lane/<Name>-<Task>）
  2. 拷贝未跟踪的记忆文件：AGENTS.md / TODO.md / MonetUI.md（.gitignore 把它们排除，
     worktree 里天然没有，不补 = harness 失忆）
  3. junction 只读共享件：docs\api、tools\node_modules、Assets\Textures.bak
  4. 打印该车道的人工配置提醒

硬规则：车道不配 wuxian MCP、不跑 deploy-retail.ps1、不 push。
实机验证（deploy / reload / logs / snap / taint.log / SavedVariables 账本）只归集成道
（主目录 + opencode），见 docs/MULTI-HARNESS.md 的独占资源表。
#>
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [Parameter(Mandatory = $true)][string]$Task
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot            # 仓库根（tools\..）
$lane = Join-Path (Split-Path -Parent $root) "MonetUI-lane-$Name"
$branch = "lane/$Name-$Task"

if (Test-Path $lane) { throw "车道已存在：$lane（先 git worktree remove `"$lane`" 再建）" }

git -C $root worktree add $lane -b $branch
if ($LASTEXITCODE -ne 0) { throw "git worktree add 失败（分支 $branch 是否已存在？）" }

# ---- 拷贝未跟踪的记忆文件：各车道各自演进，合并时由集成道带回 ----
foreach ($f in 'AGENTS.md', 'TODO.md', 'MonetUI.md') {
  $src = Join-Path $root $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $lane $f) }
}

# ---- junction：只读共享件，不复制、三家车道事实一致 ----
$junctions = @(
  'docs\api',             # API 快照（api-lookup/api-audit 的数据源，事实必须一致）
  'tools\node_modules',   # npm 依赖（@napi-rs/canvas / wow-blp-web）
  'Assets\Textures.bak'   # audit-pixels.js 的反例库
)
foreach ($k in $junctions) {
  $target = Join-Path $root $k
  $link   = Join-Path $lane $k
  if ((Test-Path $target) -and -not (Test-Path $link)) {
    $parent = Split-Path -Parent $link
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "junction: $k -> $target"
  }
}

Write-Host ""
Write-Host "车道就绪：$lane（分支 $branch）"
Write-Host "接下来人工完成（详见 docs/MULTI-HARNESS.md）："
Write-Host "  Qoder CN  ：用 Qoder 打开 $lane；MCP 不配 wuxian；权限/Hooks 里禁跑 deploy-retail.ps1"
Write-Host "  WorkBuddy ：settings.json 沙箱写白名单只加 $lane；mcp.json 不配 wuxian"
Write-Host "  闸门      ：node tools/api-audit.js（HARD 清零）；动材质另跑 node tools/audit-pixels.js"
Write-Host "  完成      ：本地 commit 到 lane 分支，不 push；合并与实机验证走集成道（opencode）"
