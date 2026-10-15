# 创建 GitHub Release 并上传 dist/ 下的发布产物。
#
# 用法：
#   .\scripts\publish_release.ps1                    # 版本取 pubspec.yaml
#   .\scripts\publish_release.ps1 -Version 1.0.1
#   .\scripts\publish_release.ps1 -DryRun            # 只看要做什么，不调 API
#
# 凭据：走 git 已保存的凭据（git credential fill），不在这里存 token。
# 本机没装 gh CLI，所以直接用 GitHub REST API。

param(
    [string]$Version = "",
    [string]$Repo = "WT810787899/YuChuan",
    [string]$DistDir = "dist",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $Version) {
    $line = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $line) { throw "pubspec.yaml 里读不到 version" }
    $Version = ($line.Matches[0].Groups[1].Value -split '\+')[0]
}
$tag = "v$Version"

$assets = @(
    (Join-Path $DistDir "YuChuan-$Version-windows-portable.zip"),
    (Join-Path $DistDir "YuChuan-$Version-android.apk")
)
$assets = $assets | Where-Object { Test-Path $_ }
if (-not $assets) { throw "dist/ 下没有找到 $Version 的产物 —— 先跑 .\scripts\package_release.ps1" }

Write-Host "仓库 : $Repo"
Write-Host "标签 : $tag"
Write-Host "产物 :"
$assets | ForEach-Object { Write-Host ("  {0}  {1:N2} MB" -f (Split-Path $_ -Leaf), ((Get-Item $_).Length / 1MB)) }

if ($DryRun) { Write-Host "`n-DryRun：不调用 API。"; return }

# ---- 取凭据（git 已保存的 GitHub token）----
$cred = "protocol=https`nhost=github.com`n`n" | git credential fill
$token = ($cred | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
if (-not $token) { throw "拿不到 GitHub 凭据：先 git push 一次让凭据助手记住，或改用 PAT。" }

$headers = @{
    Authorization          = "token $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "YuChuan-release-script"
}

# ---- 确保 tag 已推送 ----
# 注意：git 把进度写到 stderr，而本脚本开头设了 ErrorActionPreference=Stop，
# 不吞掉 stderr 的话 PowerShell 会把「正常进度」当错误直接中断脚本。
$localTag = git tag -l $tag 2>&1
if (-not $localTag) {
    git tag -a $tag -m "雨传 YuChuan $tag" 2>&1 | Out-Null
    git push origin $tag 2>&1 | Out-Null
    Write-Host "已创建并推送标签 $tag"
} else {
    Write-Host "标签 $tag 已存在"
}

# ---- 建 Release（已存在就复用）----
$body = @"
## 雨传 YuChuan $Version

一个局域网聊天 / 传文件工具。轻松解决传文件和文字的繁琐操作，摆脱其他臃肿的软件、繁琐的操作和网络的限制。

### 下载

> 资源文件名用 ``YuChuan-`` 前缀是**被迫**的：GitHub Release 会把资源名里的非 ASCII
> 字符丢掉（``雨传-x.zip`` 会变成 ``-x.zip``），所以下载名只能用 ASCII。
> 解压后里面仍然是 ``雨传\雨传.exe``，不影响使用。

| 文件 | 说明 |
|---|---|
| ``YuChuan-$Version-windows-portable.zip`` | **Windows 便携版**：解压后进 ``雨传\`` 双击 ``雨传.exe`` 即用，免安装；整个文件夹可放 U 盘 |
| ``YuChuan-$Version-android.apk`` | **Android 安装版**：传到手机点击安装（需允许「安装未知来源应用」） |

### 这一版能做什么

- **发现与配对**：同一局域网自动发现设备，配对双端弹窗确认，无需登录/扫码
- **聊天**：文字、图片、文件、文件夹混排显示；链接可点；双击文字气泡即复制
- **传文件**：拖拽 / 粘贴 / 系统分享均可；大文件显示进度，支持暂停 · 继续 · 取消 · 重试
- **断点续传**：中断后从已接收位置继续
- **离线发送**：对方不在线时排队，上线后自动补发
- **文件 TAB**：独立文件页，图标/列表视图、排序、筛选、PC 框选、批量操作
- **打开方式**：调起系统程序列表，可选「始终 / 仅一次」并记住
- **后台保活**：安卓切后台不断开
- **外观**：主题色、壁纸（不透明度/模糊度）、深浅色独立记忆

### 平台

- Windows 10/11 x64
- Android arm64-v8a

详细功能见 [README](https://github.com/$Repo/blob/main/README.md)，架构见 [ARCHITECTURE.md](https://github.com/$Repo/blob/main/ARCHITECTURE.md)。
"@

$existing = $null
try {
    $existing = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers -Method Get
} catch {
    $existing = $null
}

if ($existing) {
    Write-Host "Release $tag 已存在（id=$($existing.id)），直接补传产物"
    $release = $existing
} else {
    $payload = @{
        tag_name         = $tag
        name             = "雨传 YuChuan $tag"
        body             = $body
        draft            = $false
        prerelease       = $false
    } | ConvertTo-Json -Depth 5
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Headers $headers -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType "application/json; charset=utf-8"
    Write-Host "已创建 Release：$($release.html_url)"
}

# ---- 上传产物（同名已存在则先删掉再传）----
$uploadBase = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets"
$existingAssets = @()
try { $existingAssets = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/$($release.id)/assets" -Headers $headers -Method Get) } catch { }

foreach ($path in $assets) {
    $name = Split-Path $path -Leaf
    $dup = $existingAssets | Where-Object { $_.name -eq $name }
    if ($dup) {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/assets/$($dup.id)" -Headers $headers -Method Delete | Out-Null
        Write-Host "  已删除同名旧产物：$name"
    }
    # 用 curl.exe 而不是 Invoke-RestMethod 上传。
    # 原因：文件名含中文，Invoke-RestMethod 解析带 %XX 的 URI 时会把 CJK 段丢掉，
    # 传上去变成 "-1.0.0-windows-portable.zip"；curl 原样发送 query，
    # GitHub 自己解码，中文名能保住。
    $encoded = [System.Uri]::EscapeDataString($name)
    $url = "$uploadBase`?name=$encoded"
    $raw = & curl.exe -sS -X POST `
        -H "Authorization: token $token" `
        -H "Accept: application/vnd.github+json" `
        -H "X-GitHub-Api-Version: 2022-11-28" `
        -H "Content-Type: application/octet-stream" `
        --data-binary "@$path" $url 2>&1
    $json = $raw | ConvertFrom-Json
    if ($json.name -ne $name) {
        throw "上传后名字不对：期望 '$name'，实际 '$($json.name)'"
    }
    Write-Host ("  已上传 {0}  ({1:N2} MB)" -f $json.name, ($json.size / 1MB))
}

Write-Host ""
Write-Host "完成：$($release.html_url)"
