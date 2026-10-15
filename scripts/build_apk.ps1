# 构建 Android ARM APK（本项目只发布 arm64-v8a）
# 前置: Android SDK(%LOCALAPPDATA%\Android\Sdk) + NDK 27 + Rust aarch64-linux-android target
# 用法: .\scripts\build_apk.ps1            # Debug（T0.1 冒烟 / 日常验证）
#       .\scripts\build_apk.ps1 -Release   # Release（交付）
# PS 5.1 下 native 命令写 stderr 会被 $ErrorActionPreference='Stop' 当成终止错误
# （flutter/cargo 都会写 stderr），改为 Continue + 逐条检查 $LASTEXITCODE。
param([switch]$Release)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$env:PATH = "C:\flutter\bin;C:\Users\81078\.cargo\bin;" + $env:PATH
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_NDK_HOME = "$sdk\ndk\27.0.12077973"

if (-not (Test-Path "$sdk\cmdline-tools\latest\bin\sdkmanager.bat")) {
    throw "Android SDK 未安装: $sdk"
}
if (-not (Test-Path 'android')) {
    Write-Host '== android/ 不存在，执行 flutter create =='
    & flutter create --platforms=android --project-name rust_flutter_ui .
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
}

# 只打 arm64-v8a（真机主架构）：省去 x86/x86_64/armeabi 三个架构，APK 明显变小。
# 模拟器调试请临时在 android/app/build.gradle.kts 的 abiFilters 加回 "x86_64"。
$mode = if ($Release) { '--release' } else { '--debug' }
& flutter build apk $mode --target-platform=android-arm64
if ($LASTEXITCODE -ne 0) { throw "flutter build apk $mode failed" }

# 校验产物 ABI —— cargokit 只写本次架构的 jniLibs，从不清理上一次构建残留的其它架构目录，
# 于是 APK 里会混进 armeabi-v7a / x86_64 的 librust_flutter_ui_native.so（却没有配套的
# libflutter.so / libapp.so）。32 位 ARM 真机会判定「兼容」并安装，启动即崩。
# android/app/build.gradle.kts 的 ndk.abiFilters 是拦截点，这里做端到端复核。
$apk = "$root\build\app\outputs\flutter-apk\app-" + $(if ($Release) { 'release' } else { 'debug' }) + ".apk"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
$abis = @($zip.Entries | Where-Object { $_.FullName -like 'lib/*/*' } |
    ForEach-Object { ($_.FullName -split '/')[1] } | Sort-Object -Unique)
$zip.Dispose()
if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') {
    throw "APK ABI 校验失败，期望仅 arm64-v8a，实际: $($abis -join ', ')"
}

Write-Host "OK: $apk  (ABI: $($abis -join ', '))"
