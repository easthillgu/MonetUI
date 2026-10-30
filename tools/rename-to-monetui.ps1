<#
.SYNOPSIS
  把重构仓"转正"为 MonetUI，旧版目录改名封存。

.DESCRIPTION
  1) <dev>\MonetUI          -> <dev>\MonetUI-archive   （旧版，停在 cb7d932，留存不再开发）
  2) <dev>\MonetUI-refactor -> <dev>\MonetUI           （本仓，转正）

  为什么不能边开发边跑：Windows 不允许重命名"正被某个进程当工作目录"的文件夹，
  而 OpenCode 桌面版会给每个会话拉一组 MCP 辅助进程（hated-wow / wuxian / context-mode），
  它们的工作目录就是会话目录：
    * 旧版目录被**另一个 OpenCode 窗口/标签**（那个老项目的会话）占着；
    * 本仓目录被**当前窗口**自己的辅助进程占着。
  所以：**完全退出 OpenCode 桌面版**，在任意普通终端（工作目录不要在这两个文件夹里）运行本脚本，
  跑完重新打开本仓（此时已叫 MonetUI）。

  脚本会先扫一遍"谁把工作目录指向这两个文件夹"：有人占着就列出来并退出（exit 2），
  一个都不改 —— 绝不半途改名。脚本自己会复制到 %TEMP% 再执行，避免锁住要改名的目录。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File "C:\Users\EastHillGu\Documents\wowaddonsdev\MonetUI-refactor\tools\rename-to-monetui.ps1"

.EXAMPLE
  # 先看会发生什么，不动盘
  powershell -ExecutionPolicy Bypass -File .\tools\rename-to-monetui.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DevRoot
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 自搬运
# 脚本文件就在要改名的目录里：复制到 %TEMP% 并以 dev 根目录为工作目录重跑一次。
$dev = if ($DevRoot) { $DevRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

if (-not $env:MUI_RENAME_RELOCATED) {
    $here = (Get-Location).Path
    foreach ($p in @((Join-Path $dev 'MonetUI'), (Join-Path $dev 'MonetUI-refactor'))) {
        if ($here.StartsWith($p.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "当前终端的工作目录在 $p 里，它自己就会锁住这个文件夹。" -ForegroundColor Yellow
            Write-Host "先 `Set-Location '$dev'`（或任何这两个文件夹以外的地方）再跑。" -ForegroundColor Yellow
            exit 2
        }
    }
    $tmp = Join-Path $env:TEMP 'mui-rename-to-monetui.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $tmp -Force -WhatIf:$false
    $exe = (Get-Process -Id $PID).Path
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -DevRoot "{1}"' -f $tmp, $dev
    if ($WhatIfPreference) { $argList += ' -WhatIf' }
    $env:MUI_RENAME_RELOCATED = '1'
    $child = Start-Process -FilePath $exe -WorkingDirectory $dev -NoNewWindow -Wait -PassThru -ArgumentList $argList
    exit $child.ExitCode
}

# ---------------------------------------------------------------- 找占用者
function Get-LockingProcess {
    param([string]$Path)

    $needle = $Path.TrimEnd('\') + '\'
    $code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MuiProcCwd {
    [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr R2; public IntPtr R3; public IntPtr Pid; public IntPtr R4; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out int read);
    public static string Get(int pid) {
        IntPtr h = OpenProcess(0x0410, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            var pbi = new PBI(); int ret;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
            byte[] buf = new byte[8];
            if (!ReadProcessMemory(h, (IntPtr)((long)pbi.Peb + 0x20), buf, 8, out ret)) return null;
            IntPtr pp = (IntPtr)BitConverter.ToInt64(buf, 0);
            byte[] ub = new byte[16];
            if (!ReadProcessMemory(h, (IntPtr)((long)pp + 0x38), ub, 16, out ret)) return null;
            int len = BitConverter.ToUInt16(ub, 0);
            if (len <= 0 || len > 4096) return null;
            byte[] sb = new byte[len];
            if (!ReadProcessMemory(h, (IntPtr)BitConverter.ToInt64(ub, 8), sb, len, out ret)) return null;
            return Encoding.Unicode.GetString(sb);
        } finally { CloseHandle(h); }
    }
}
'@
    if (-not ('MuiProcCwd' -as [type])) { Add-Type -TypeDefinition $code -Language CSharp }

    Get-Process | Where-Object { $_.Id -ne $PID } | ForEach-Object {
        $cwd = $null
        try { $cwd = [MuiProcCwd]::Get($_.Id) } catch { }
        if ($cwd -and $cwd.StartsWith($needle, [StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; Cwd = $cwd }
        }
    }
}

# ---------------------------------------------------------------- 目标路径
$old = Join-Path $dev 'MonetUI'            # 旧版（待封存）
$ref = Join-Path $dev 'MonetUI-refactor'   # 本仓（待转正）
$arc = Join-Path $dev 'MonetUI-archive'    # 旧版的新名字

if (-not (Test-Path (Join-Path $ref 'MonetUI.toc'))) {
    if (Test-Path (Join-Path $old 'MonetUI.toc')) {
        Write-Host "看起来已经转过正（$old 就是本仓，没有 $ref）。无需再跑。" -ForegroundColor DarkGray
        exit 0
    }
    Write-Host "找不到 $ref\MonetUI.toc —— 目录结构不对，停止。" -ForegroundColor Red
    exit 1
}

$blockers = @()
foreach ($p in @($ref, $old)) {
    if (Test-Path $p) { $blockers += Get-LockingProcess -Path $p }
}
if ($blockers.Count -gt 0) {
    Write-Host "这些进程把目标目录当工作目录，Windows 会拒绝改名：" -ForegroundColor Yellow
    $blockers | Sort-Object Cwd, Id | Format-Table Id, Name, Cwd -AutoSize | Out-String | Write-Host
    Write-Host "→ 完全退出 OpenCode 桌面版（所有窗口/标签）后，再跑一次这个脚本。" -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------- 动手
if (Test-Path $old) {
    if (Test-Path $arc) {
        Write-Host "$arc 已经存在 —— 上次可能跑过一半。先人工确认（删掉或改名）再来。" -ForegroundColor Red
        exit 1
    }
    if ($PSCmdlet.ShouldProcess($old, 'rename -> MonetUI-archive')) {
        Rename-Item -LiteralPath $old -NewName 'MonetUI-archive'
        Write-Host "旧版封存：MonetUI -> MonetUI-archive" -ForegroundColor Green
    }
} else {
    Write-Host "跳过封存：$old 不存在（可能已封存过）。" -ForegroundColor DarkGray
}

if (Test-Path $ref) {
    if (Test-Path $old) {
        Write-Host "$old 仍存在，目标名字被占，停止（不覆盖任何东西）。" -ForegroundColor Red
        exit 1
    }
    if ($PSCmdlet.ShouldProcess($ref, 'rename -> MonetUI')) {
        Rename-Item -LiteralPath $ref -NewName 'MonetUI'
        Write-Host "转正完成：MonetUI-refactor -> MonetUI" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host "下一步：重新打开 OpenCode，工作目录选 $old" -ForegroundColor Cyan
Write-Host "  照旧三闸门：node tools/api-audit.js -> powershell -File tools/deploy-retail.ps1 -> node tools/sync-check.js" -ForegroundColor DarkGray
