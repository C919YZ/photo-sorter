#Requires -Version 5.1
<#
.SYNOPSIS
    给不想敲命令的人准备的中文菜单：内部去重 / 分类 / 对比主目录 / 预览 / 退出。

.DESCRIPTION
    只做参数拼装和循环，真正的逻辑仍然在 Classify.ps1 / Dedupe.ps1 里。
    所以在菜单里看到的输出和双击 bat 完全一致。

.PARAMETER ConfigPath
    配置文件路径，默认仓库根目录的 config.ps1。
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'src\lib\Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config.ps1' }
$cfg = Get-AppConfig -ConfigPath $ConfigPath

$Root   = $cfg.Root
$Inbox  = Join-Path $Root $cfg.InboxFolderName

function Show-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '    PhotoSorter · 照片整理工具' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ("    资料库  : " + $Root)
    Write-Host ("    待分类1 : " + $Inbox)
    $mediaCount = @(Get-MediaFileList -Path $Inbox).Count
    if (Test-Path -LiteralPath $Inbox) {
        Write-Host ("    当前有  : {0} 个照片/视频待处理" -f $mediaCount) -ForegroundColor $(if ($mediaCount -gt 0) { 'Yellow' } else { 'DarkGray' })
    }
    else {
        Write-Host '    注意    : 待分类1 还不存在，运行任意一项会自动创建' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '    1  待分类1 内部去重          （同一批里内容相同的只留一份）'
    Write-Host '    2  分类到主目录              （复制，源文件保留）'
    Write-Host '    3  对比主目录去重            （主目录已有的，从待分类里挑出来）'
    Write-Host '    4  预览分类结果              （只显示会分到哪，不动文件）'
    Write-Host '    5  打开资料库文件夹'
    Write-Host '    6  查看使用说明'
    Write-Host '    0  退出'
    Write-Host ''
}

function Invoke-ToolScript {
    param([string]$ScriptName, [string[]]$Arguments)

    $path = Join-Path $RepoRoot ('src\' + $ScriptName)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $path @Arguments
}

# 首次运行时把资料库骨架建好，避免"找不到待分类文件夹"
if (-not (Test-Path -LiteralPath $Root)) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
}

while ($true) {

    Show-Header
    $choice = Read-Host '    请输入数字后回车'

    switch ($choice.Trim()) {

        '1' {
            if (-not (Test-Path -LiteralPath $Inbox)) { New-Item -ItemType Directory -Path $Inbox -Force | Out-Null }
            Invoke-ToolScript -ScriptName 'Dedupe.ps1' -Arguments @('-Scope', 'Inbox')
        }
        '2' {
            if (-not (Test-Path -LiteralPath $Inbox)) { New-Item -ItemType Directory -Path $Inbox -Force | Out-Null }
            Invoke-ToolScript -ScriptName 'Classify.ps1' -Arguments @()
        }
        '3' {
            Invoke-ToolScript -ScriptName 'Dedupe.ps1' -Arguments @('-Scope', 'Library')
        }
        '4' {
            Invoke-ToolScript -ScriptName 'Classify.ps1' -Arguments @('-Preview')
        }
        '5' {
            if (Test-Path -LiteralPath $Root) { Start-Process explorer.exe $Root }
            continue
        }
        '6' {
            $readme = Join-Path $RepoRoot 'README.md'
            if (Test-Path -LiteralPath $readme) { Start-Process notepad.exe $readme }
            continue
        }
        '0' { return }
        default {
            Write-Host '    没有这个选项，请重新输入。' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
    }

    Write-Host ''
    Read-Host '    按回车返回菜单' | Out-Null
}
