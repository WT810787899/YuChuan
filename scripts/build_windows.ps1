# 构建 Windows Release（cargokit 会自动 cargo build --release）
# 用法: .\scripts\build_windows.ps1
# PS 5.1 下 native 命令写 stderr 会被 $ErrorActionPreference='Stop' 当成终止错误
# （flutter/cargo 都会写 stderr），改为 Continue + 逐条检查 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$env:PATH = "C:\flutter\bin;C:\Users\81078\.cargo\bin;" + $env:PATH
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

& dart analyze lib
if ($LASTEXITCODE -ne 0) { throw 'dart analyze failed' }

# 运行中的实例会锁死 exe（LNK1104），先关掉
Get-Process rust_flutter_ui -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 1

& flutter build windows
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

Write-Host "OK: $root\build\windows\x64\runner\Release\雨传.exe"
