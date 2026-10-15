# 同机双实例联调（发现 + 聊天自测）：第二个实例带 LANCHAT_INSTANCE=2（独立身份）
# 和 LANCHAT_CHAT_PORT=45997（TCP 端口不能复用，否则第二个实例监听失败）。
# A 端要连 B，需要手动直连 B 的 IP:45997 或让 A 通过发现结果拨号。
# 用法: .\scripts\run_two_instances.ps1 [-WaitSeconds 20]
param([int]$WaitSeconds = 20)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$exe = "$root\build\windows\x64\runner\Release\rust_flutter_ui.exe"
if (-not (Test-Path $exe)) { throw '先构建：.\scripts\build_windows.ps1' }

$temp = $env:TEMP
Get-Process rust_flutter_ui -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$a = Start-Process $exe -PassThru
Start-Sleep -Seconds 3
$env:LANCHAT_INSTANCE = '2'
$env:LANCHAT_CHAT_PORT = '45997'
$b = Start-Process $exe -PassThru
Remove-Item Env:\LANCHAT_INSTANCE -ErrorAction SilentlyContinue
Remove-Item Env:\LANCHAT_CHAT_PORT -ErrorAction SilentlyContinue
Write-Host "实例 A pid=$($a.Id) / B pid=$($b.Id)（B：独立身份 + 聊天端口 45997）"

Start-Sleep -Seconds $WaitSeconds
foreach ($p in @($a, $b)) {
    Write-Host "=== pid $($p.Id) 启动诊断 ==="
    $diag = "$temp\lanchat_startup_diag_$($p.Id).txt"
    if (Test-Path $diag) {
        Get-Content $diag -Encoding UTF8 |
            Select-String -Pattern 'discovery_self|discovery_devices|chat_ready|chat_port|chat_conversations|chat_error' |
            Select-Object -Last 6 | ForEach-Object { $_.Line }
    } else {
        Write-Host '(无诊断文件)'
    }
}

Stop-Process -Id $a.Id, $b.Id -Force -ErrorAction SilentlyContinue
Write-Host '已结束两个实例。'
