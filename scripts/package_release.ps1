# 打包发布产物：Windows 便携版 zip + 安卓安装包。
#
# 用法：
#   .\scripts\package_release.ps1                 # 版本取 pubspec.yaml
#   .\scripts\package_release.ps1 -Version 1.0.1
#
# 前置：先跑过构建
#   .\scripts\build_windows.ps1     # 产出 build\windows\x64\runner\Release\
#   .\scripts\build_apk.ps1         # 产出 build\app\outputs\flutter-apk\app-release.apk
#
# 为什么在这里把 exe 改名成「雨传.exe」：
#   CMake 的 target 名不支持非 ASCII（写 "雨传" 会直接报
#   `Cannot specify compile definitions for target "雨传" which is not built`），
#   所以构建产物是 ASCII 的 YuChuan.exe，发布时再改成中文名。
#   改名不影响运行：runner 是按自身所在目录去找 data\ 和各个 dll 的。

param(
    [string]$Version = "",
    [string]$DistDir = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ---- 版本号：默认读 pubspec.yaml 的 version（去掉 +build 后缀）----
if (-not $Version) {
    $line = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $line) { throw "pubspec.yaml 里读不到 version" }
    $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0]
}
Write-Host "版本：$Version"

$stageName = "雨传"
$exeAscii = "YuChuan.exe"
$exeCjk = "雨传.exe"

# ---- 校验前置产物 ----
$winRel = "build\windows\x64\runner\Release"
if (-not (Test-Path "$winRel\$exeAscii")) {
    throw "找不到 $winRel\$exeAscii —— 先跑 .\scripts\build_windows.ps1"
}
$apkSrc = "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apkSrc)) {
    throw "找不到 $apkSrc —— 先跑 .\scripts\build_apk.ps1"
}

# ---- 暂存 Windows 便携版 ----
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$stage = Join-Path $DistDir $stageName
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Recurse -Force "$winRel\*" $stage

# exe 改中文名
Move-Item -Force (Join-Path $stage $exeAscii) (Join-Path $stage $exeCjk)

# 附一份使用说明，便携版解压后一眼能看到
$readme = @"
雨传 YuChuan $Version · Windows 便携版

直接双击「$exeCjk」运行，无需安装。
整个文件夹可以放到任意位置（U 盘也行），删掉即卸载。

同一局域网内打开手机端雨传，两端会自动互相发现，配对一次即可互传文件。
"@
Set-Content -Path (Join-Path $stage "使用说明.txt") -Value $readme -Encoding UTF8

# ---- 打 zip ----
# 产物文件名必须是 **纯 ASCII**：GitHub Release 的资源名会把非 ASCII 字符丢掉
# （实测：curl 正确发出 ?name=%E9%9B%A8%E4%BC%A0-probe.txt，GitHub 存下来却是
#  "-probe.txt"）。所以下载文件名用 YuChuan-*，
# 而 zip **内部**仍然是「雨传\雨传.exe」，解压后看到的还是中文名，不影响使用。
$zip = Join-Path $DistDir "YuChuan-$Version-windows-portable.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

# ---- 安卓安装包 ----
$apkDst = Join-Path $DistDir "YuChuan-$Version-android.apk"
Copy-Item -Force $apkSrc $apkDst

# ---- 汇报 ----
Write-Host ""
Write-Host "产物："
foreach ($f in @($zip, $apkDst)) {
    $i = Get-Item $f
    Write-Host ("  {0}  {1:N2} MB" -f $i.Name, ($i.Length / 1MB))
}
Write-Host ""
Write-Host "zip 内含顶层目录：$stageName\"
Get-ChildItem $stage | ForEach-Object { Write-Host "  $($_.Name)" }
