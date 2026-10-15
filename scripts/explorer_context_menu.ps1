<#
  雨传 · Windows 资源管理器右键菜单「通过雨传发送」安装。

  用 reg.exe 而非 New-Item：路径里的 * 会被 PowerShell 的
  提供程序当通配符处理，导致静默不写入（实测踩过）。reg.exe 按字面量。

  用 HKCU\Software\Classes：当前用户生效、**不需要管理员权限**，
  卸载即删键，可回滚。绿色版用户配合 uninstall_registry.bat 一键清理。
#>
param(
  [string]$ExePath = '',
  [switch]$Install,
  [switch]$Uninstall
)

# 注意：不能设 Stop —— reg.exe 查询不存在的键会写 stderr，
# 在 Stop 下会变成终止错误、把整个脚本静默打断（实测踩过）。
$ErrorActionPreference = 'Continue'

$ClassRoot = 'HKCU\Software\Classes'
$Targets = @(
  @{ Key = "$ClassRoot\*\shell\YuChuan.Send";           Verb = '通过雨传发送' },
  @{ Key = "$ClassRoot\Directory\shell\YuChuan.Send";   Verb = '通过雨传发送' }
)

function Remove-Keys {
  foreach ($t in $Targets) {
    & reg.exe query $t.Key 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      & reg.exe delete $t.Key /f 2>$null | Out-Null
      Write-Host ('  已移除 ' + $t.Key)
    }
  }
}

function Install-Keys {
  foreach ($t in $Targets) {
    # /ve = 默认值；/f = 静默确认
    & reg.exe add $t.Key /ve /t REG_SZ /d $t.Verb /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('写入失败：' + $t.Key) }
    & reg.exe add $t.Key /v MUIVerb /t REG_SZ /d $t.Verb /f 2>$null | Out-Null
    & reg.exe add $t.Key /v Icon /t REG_SZ /d $ExePath /f 2>$null | Out-Null
    # Player：多选时只拉起一个实例，由应用自己合并处理
    & reg.exe add $t.Key /v MultiSelectModel /t REG_SZ /d Player /f 2>$null | Out-Null
    $cmd = $t.Key + '\command'
    # reg.exe 会吃掉裸引号，必须用反斜杠引号转义，否则带空格的路径会断
    $val = '\"' + $ExePath + '\" \"%1\"'
    & reg.exe add $cmd /ve /t REG_SZ /d $val /f 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('写入 command 失败：' + $t.Key) }
    Write-Host ('  已写入 ' + $t.Key)
  }
}

if ($Uninstall) {
  Write-Host '移除雨传右键菜单…'
  Remove-Keys
  Write-Host '完成。'
  exit 0
}

if (-not $Install) {
  Write-Host '用法: .\explorer_context_menu.ps1 -ExePath <exe> -Install'
  Write-Host '     .\explorer_context_menu.ps1 -Uninstall'
  exit 1
}

if (-not $ExePath) { Write-Error '必须提供 -ExePath'; exit 1 }
if (-not (Test-Path $ExePath)) { Write-Error ('找不到 exe: ' + $ExePath); exit 1 }

Write-Host ('安装雨传右键菜单（目标：' + $ExePath + '）…')
Install-Keys
Write-Host '完成。文件右键在「显示更多选项」里；文件夹直接可见。'
