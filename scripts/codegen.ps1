# 重新生成 flutter_rust_bridge 桥接代码（修改 rust_builder/src/api 后执行）
# 用法: .\scripts\codegen.ps1
# PS 5.1 下 native 命令写 stderr 会被 $ErrorActionPreference='Stop' 当成终止错误
# （flutter/cargo 都会写 stderr），改为 Continue + 逐条检查 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# 环境：PATH / 镜像
$env:PATH = "C:\Users\81078\.cargo\bin;C:\flutter\bin;" + $env:PATH
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

# 版本锁：flutter_rust_bridge 必须与 codegen 精确一致（PLAN 风险13）
$pubspec = Get-Content "$root\pubspec.yaml" -Raw
if ($pubspec -notmatch 'flutter_rust_bridge:\s*2\.8\.0') {
    throw 'pubspec.yaml 中 flutter_rust_bridge 必须锁定 2.8.0'
}
$ver = & flutter_rust_bridge_codegen --version 2>&1 | Out-String
if ($ver -notmatch '2\.8\.0') {
    throw "codegen 版本不是 2.8.0: $ver  (cargo install flutter_rust_bridge_codegen --version 2.8.0 --locked)"
}

& flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

& flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
if ($LASTEXITCODE -ne 0) { throw 'codegen failed' }

Write-Host 'codegen OK'
