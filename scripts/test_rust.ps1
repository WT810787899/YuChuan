# Rust 核心层单元测试（T0.3 起每次改动 backend/ 后执行）
# PS 5.1 下 native 命令写 stderr 会被 $ErrorActionPreference='Stop' 当成终止错误
# （flutter/cargo 都会写 stderr），改为 Continue + 逐条检查 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location "$root\rust_builder"
$env:PATH = "C:\Users\81078\.cargo\bin;" + $env:PATH
& cargo test @args
if ($LASTEXITCODE -ne 0) { throw 'cargo test failed' }
