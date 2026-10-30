<#
  tools/gimp-render.ps1 —— 跑 GIMP 的 Python-Fu 批处理脚本，等它出图，然后收摊。

  为什么要有这个壳：
    * GIMP 3.2 的 `python-fu-eval` 批处理跑完不会自己退出（`Gimp.quit()` 已废弃，
      脚本里调 `os._exit()` 只会让插件崩掉，进程照样挂着）；
    * 所以这里改成：后台起 gimp-console → 盯着输出文件出现并停止增长 → 强杀进程。
    * 直接 `gimp-console -i -b ...` 会把进程挂住直到超时，浪费几分钟。

  用法：
    powershell -File tools/gimp-render.ps1 -Script tools/gimp-addon-icon.py -Out $env:TEMP\monet_addon_icon.png
#>
param(
  [Parameter(Mandatory = $true)][string]$Script,
  [Parameter(Mandatory = $true)][string]$Out,
  [int]$TimeoutSec = 900
)

$gimp = 'C:\Users\EastHillGu\Documents\GreenAPPS\GIMPPortable\App\gimp\bin\gimp-console-3.2.exe'
if (-not (Test-Path $gimp)) { Write-Error "gimp not found: $gimp"; exit 1 }
if (-not (Test-Path $Script)) { Write-Error "script not found: $Script"; exit 1 }

$scriptFull = (Resolve-Path $Script).Path
if (Test-Path $Out) { Remove-Item $Out -Force }

$argStr = '-i --batch-interpreter=python-fu-eval -b "import runpy; runpy.run_path(r''{0}'', run_name=''__main__'', init_globals=globals())"' -f $scriptFull
$p = Start-Process -FilePath $gimp -ArgumentList $argStr -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$last = -1
$stable = 0
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  if (Test-Path $Out) {
    $len = (Get-Item $Out).Length
    if ($len -gt 0 -and $len -eq $last) { $stable++ } else { $stable = 0 }
    $last = $len
    if ($stable -ge 2) { break }
  }
  if ($p.HasExited) { break }
}
Start-Sleep -Milliseconds 800
Get-Process gimp-console* -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not (Test-Path $Out)) {
  Write-Error "渲染失败：没有产出 $Out"
  exit 2
}
Write-Output "rendered $Out ($((Get-Item $Out).Length) bytes)"
