<#
.SYNOPSIS
  MonetUI（及其同机插件）界面错误 / Taint 污染监控器。

.DESCRIPTION
  WoW 默认错误弹窗只显示第一行、不显示调用栈，且 taint 类报错（"界面动作执行失败 /
  Interface action failed because of an AddOn"）只在玩家做某个动作时才触发，极难定位，
  而且常常被误判成"我的插件"导致的。本脚本扫描客户端日志，把 taint 按插件分组、列出真正的
  报错来源（被拦截的动作、Lua 语法错误），直接告诉你"问题到底在哪"。

  三种模式：
    aggregate   (默认) 扫描整个 taint.log，给出全量聚合报告（首次排查用）。
    incremental 只扫描自上次运行以来的新增内容（靠状态文件记字节偏移）。
    watch       循环运行 incremental，每隔 -IntervalSec 秒打印一次新增。

.PARAMETER LogsDir      WoW 客户端 Logs 目录（默认自动探测 Forever 客户端）。
.PARAMETER SavedVars    MonetUI.lua 存档路径（默认自动探测）。
.PARAMETER Mode         aggregate | incremental | watch
.PARAMETER IntervalSec  watch 模式轮询间隔（秒）。
.PARAMETER StateFile    状态文件路径（记字节偏移 / 上次运行时间）。
.PARAMETER TopN         分组排行榜只显示前 N 条。
#>
param(
    [string]$LogsDir = "",
    [string]$SavedVars = "",
    [string]$Mode = "aggregate",
    [int]   $IntervalSec = 300,
    [string]$StateFile = "",
    [int]   $TopN = 12
)

$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# 路径自动探测
# ---------------------------------------------------------------------------
function Find-ForeverLogs {
    $candidates = @(
        "C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_forever_\Logs",
        "C:\Users\EastHillGu\Documents\Blizzards\WOWFOREVER\World of Warcraft\_retail_\Logs"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "taint.log")) { return $c }
    }
    $base = "C:\Users\EastHillGu\Documents\Blizzards"
    if (Test-Path $base) {
        $hit = Get-ChildItem -Path $base -Recurse -Filter "taint.log" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.DirectoryName }
    }
    return ""
}

function Find-SavedVars {
    param([string]$LogsDir)
    if ($LogsDir -and (Test-Path $LogsDir)) {
        $wf = Split-Path $LogsDir          # ...\_forever_
        $svRoot = Join-Path $wf "WTF\Account"
        if (Test-Path $svRoot) {
            $hit = Get-ChildItem -Path $svRoot -Recurse -Filter "MonetUI.lua" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return ""
}

if (-not $LogsDir) { $LogsDir = Find-ForeverLogs }
if (-not $SavedVars) { $SavedVars = Find-SavedVars $LogsDir }
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot ".monitor-state.json" }

$taintLog = Join-Path $LogsDir "taint.log"
$frameXmlLog = Join-Path $LogsDir "FrameXML.log"

if (-not (Test-Path $taintLog)) {
    Write-Host "找不到 taint.log：$taintLog" -ForegroundColor Red
    Write-Host "请用 -LogsDir 指定 WoW 客户端 Logs 目录。" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------------
$state = @{ taintOffset = 0; frameXmlOffset = 0; lastRun = $null }
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable } catch {}
    if ($null -eq $state) { $state = @{ taintOffset = 0; frameXmlOffset = 0; lastRun = $null } }
}
function Save-State { $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8 }

# ---------------------------------------------------------------------------
# taint.log 解析
#   顶级 taint 行:  "HH/MM/SS.mmm  Execution tainted by <addon> while <detail> - <file:line>"
#   顶级拦截行:    "HH/MM/SS.mmm  An attempt to ... was blocked because of taint from <addon> - <file:line>"
#   续行(每行都带时间戳,仅缩进更深): 调用栈帧
#   注意：taint.log 每一行都带时间戳，不能靠"是否以时间戳开头"区分顶级/续行，
#        只能靠是否含 "Execution tainted by" / "blocked" 关键字来判断。
# ---------------------------------------------------------------------------
$reEvent = [regex] 'Execution tainted by (?<addon>\S+) while (?<detail>.+?) - (?<loc>.+:\d+)\s*$'
$reBlock = [regex] '(because of taint|was blocked|Interface action failed because of an AddOn|ADDON_ACTION)'
$reBlockFrom = [regex] 'taint from (?<addon>\S+)'
$reBlockLoc  = [regex] ' - (?<loc>.+:\d+)\s*$'
$reTs        = [regex] '^(\d+/\d+ \d+:\d+:\d+\.\d+)'

function Parse-TaintLog {
    param([string]$Path, [long]$FromOffset, [bool]$Whole)
    $events = @(); $blocks = @()
    $cur = $null; $curBlock = $null

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if (-not $Whole -and $FromOffset -gt 0 -and $FromOffset -lt $fs.Length) {
        $fs.Seek($FromOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    } elseif (-not $Whole) {
        $fs.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null   # 日志被截断/轮转，从头扫
        $state.taintOffset = 0
    }
    $endOffset = $fs.Length
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)

    while (-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        $ev = $reEvent.Match($line)
        if ($ev.Success) {
            $cur = @{ addon = $ev.Groups['addon'].Value; detail = $ev.Groups['detail'].Value;
                      loc = $ev.Groups['loc'].Value; frames = @() }
            $events += $cur; $curBlock = $null; continue
        }
        if ($line -match $reBlock) {
            $ts = ""; $tm = $reTs.Match($line); if ($tm.Success) { $ts = $tm.Groups[1].Value }
            $from = ""; $fm = $reBlockFrom.Match($line); if ($fm.Success) { $from = $fm.Groups['addon'].Value }
            $loc = "";  $lm = $reBlockLoc.Match($line);  if ($lm.Success) { $loc = $lm.Groups['loc'].Value }
            $curBlock = @{ ts = $ts; addon = $from; loc = $loc; text = $line.Trim(); frames = @() }
            $blocks += $curBlock; $cur = $null; continue
        }
        # 其余都是调用栈帧（去掉行首时间戳前缀，便于分组）
        $trimmed = $line.Trim() -replace '^\d+/\d+ \d+:\d+:\d+\.\d+\s+', ''
        if ($trimmed -ne "") {
            if ($curBlock) { $curBlock.frames += $trimmed }
            elseif ($cur)  { $cur.frames += $trimmed }
        }
    }
    $sr.Close(); $fs.Close()
    return @{ events = $events; blocks = $blocks; endOffset = $endOffset }
}

# ---------------------------------------------------------------------------
# 执行一次扫描并出报告
# ---------------------------------------------------------------------------
function Scan-Once {
    param([bool]$Incremental)

    $whole = -not $Incremental
    $fromTaint = if ($Incremental) { [long]$state.taintOffset } else { 0 }
    $fromFrame = if ($Incremental) { [long]$state.frameXmlOffset } else { 0 }

    $t = Parse-TaintLog -Path $taintLog -FromOffset $fromTaint -Whole $whole

    $frameErrors = @()
    if (Test-Path $frameXmlLog) {
        $fa = [System.IO.File]::Open($frameXmlLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if (-not $whole -and $fromFrame -gt 0 -and $fromFrame -lt $fa.Length) { $fa.Seek($fromFrame, [System.IO.SeekOrigin]::Begin) | Out-Null }
        $sr2 = New-Object System.IO.StreamReader($fa, [System.Text.Encoding]::UTF8)
        while (-not $sr2.EndOfStream) { $l = $sr2.ReadLine(); if ($l.Trim() -ne "") { $frameErrors += $l.Trim() } }
        $sr2.Close(); $fa.Close()
    }

    # 分组
    $byAddon = @{}
    foreach ($e in $t.events) { $byAddon[$e.addon] = ([int]$byAddon[$e.addon]) + 1 }
    $monetOwned   = $t.events | Where-Object { $_.addon -eq "MonetUI" }
    $monetInStack = $t.events | Where-Object { $_.addon -ne "MonetUI" -and ($_.frames -match "MonetUI") }
    $byBlockAddon = @{}
    foreach ($b in $t.blocks) { $k = if ($b.addon) { $b.addon } else { "?" }; $byBlockAddon[$k] = ([int]$byBlockAddon[$k]) + 1 }

    # ---- 报告 ----
    $now = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
    $scope = if ($Incremental) { "增量（自 $($state.lastRun) 以来）" } else { "全量" }
    Write-Host ""
    Write-Host "====== MonetUI 界面错误 / Taint 监控报告 ======" -ForegroundColor Cyan
    Write-Host "生成时间 : $now   模式: $scope"
    Write-Host "日志目录 : $LogsDir"
    if ($t.events.Count -gt 0) {
        $firstEv = $t.events[0]; $lastEv = $t.events[-1]
        Write-Host "日志时段 : 见下方统计（共 $($t.events.Count) 条 taint 事件）"
    }
    Write-Host ""

    # [0] 源头按插件
    Write-Host "[0] Taint 源头（按插件分组，Top $TopN）" -ForegroundColor Yellow
    $byAddon.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopN | ForEach-Object {
        $mark = if ($_.Key -eq "MonetUI") { "   <-- 本插件" } else { "" }
        Write-Host ("    {0,8} x {1}{2}" -f $_.Value, $_.Key, $mark)
    }
    Write-Host ""

    # [1] 被拦截的动作（玩家真正看到的"界面错误"）
    Write-Host "[1] 动作被拦截（玩家可见的界面错误）：$($t.blocks.Count) 条" -ForegroundColor $(if ($t.blocks.Count -gt 0) { "Red" } else { "Green" })
    if ($t.blocks.Count -gt 0) {
        Write-Host "  -- 按来源插件 --" -ForegroundColor DarkGray
        $byBlockAddon.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("    {0,6} x 来自 {1}" -f $_.Value, $_.Key)
        }
        Write-Host "  -- 样本 --" -ForegroundColor DarkGray
        $t.blocks | Select-Object -First 3 | ForEach-Object {
            Write-Host ("    [{0}] {1}" -f $_.ts, $_.text)
            $_.frames | Select-Object -First 5 | ForEach-Object { Write-Host ("          {0}" -f $_) }
        }
    }
    Write-Host ""

    # [2] MonetUI 自身直接污染
    Write-Host "[2] MonetUI 自身直接污染：$($monetOwned.Count) 条" -ForegroundColor $(if ($monetOwned.Count -gt 0) { "Yellow" } else { "Green" })
    foreach ($e in $monetOwned) {
        Write-Host ("    reading: {0}" -f $e.detail)
        $e.frames | Select-Object -First 5 | ForEach-Object { Write-Host ("        {0}" -f $_) }
    }
    Write-Host ""

    # [3] MonetUI 帧被卷入他人污染栈
    Write-Host "[3] MonetUI 帧被卷入他人污染栈：$($monetInStack.Count) 条" -ForegroundColor DarkGray
    Write-Host "    （多因 DragDrop 的 DropCatcher 用 ActionBarButtonTemplate，被动作条拼写高亮刷新一并扫到）" -ForegroundColor DarkGray
    if ($monetInStack.Count -gt 0) {
        $byForeign = @{}
        foreach ($e in $monetInStack) { $byForeign[$e.addon] = ([int]$byForeign[$e.addon]) + 1 }
        $byForeign.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object {
            Write-Host ("    {0,7} x 来自 {1}" -f $_.Value, $_.Key)
        }
    }
    Write-Host ""

    # [4] FrameXML Lua 错误
    Write-Host "[4] FrameXML Lua / XML 错误：$($frameErrors.Count) 条" -ForegroundColor $(if ($frameErrors.Count -gt 0) { "Red" } else { "Green" })
    foreach ($fe in $frameErrors) { Write-Host ("    {0}" -f $fe) }
    Write-Host ""

    # [5] 存档内诊断
    Write-Host "[5] 存档内诊断 (SavedVariables)" -ForegroundColor DarkGray
    if (Test-Path $SavedVars) {
        $sv = Get-Content $SavedVars -Raw
        $hasErr = $sv -match '\["errorLog"\]'; $hasCompat = $sv -match '\["compatReport"\]'; $hasBlocks = $sv -match 'boolBlocks'
        Write-Host ("    errorLog(插件内错误账): {0}" -f $(if ($hasErr) { "存在" } else { "无" }))
        Write-Host ("    compatReport(兼容性)   : {0}" -f $(if ($hasCompat) { "存在" } else { "无" }))
        Write-Host ("    Secrets.BoolBlocks     : {0}" -f $(if ($hasBlocks) { "存在" } else { "无" }))
    } else {
        Write-Host "    未找到存档：$SavedVars" -ForegroundColor Yellow
    }
    Write-Host ""

    # 更新状态
    $state.taintOffset = $t.endOffset
    $state.frameXmlOffset = if (Test-Path $frameXmlLog) { (Get-Item $frameXmlLog).Length } else { 0 }
    $state.lastRun = $now
    Save-State
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
if ($Mode -eq "watch") {
    Write-Host "进入看守模式，每 $IntervalSec 秒检查一次（Ctrl+C 退出）。状态文件：$StateFile" -ForegroundColor Cyan
    while ($true) { Scan-Once -Incremental $true; Start-Sleep -Seconds $IntervalSec }
} elseif ($Mode -eq "incremental") {
    Scan-Once -Incremental $true
} else {
    Scan-Once -Incremental $false
}
