#Requires -Version 5.1
<#
.SYNOPSIS
    PhotoSorter 端到端自测：造一批带 EXIF 的假照片，跑分类和去重，逐条断言结果。

.DESCRIPTION
    不联网、不依赖真实照片。每次运行都在临时目录里重建资料库，跑完默认清理。

    覆盖：
      * 设备 / 时间 / GPS 三层目录，以及各层缺失时落到「无数据」
      * 子目录里的文件也能被扫到
      * 待分类1 内部去重（副本移到 重复\）
      * 对比主目录去重（主目录优先，待分类里那份移到 重复\）
      * 主目录哈希缓存复用
      * 非照片/视频文件完全不被碰
      * 认不出格式（文本改名 .jpg、0 字节、残片 mp4）被移到 认不出格式\
      * 重复分类同一批文件时输出「跳过(已存在相同文件)」

.PARAMETER Keep
    跑完保留临时资料库，方便手工看结果。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#>
[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'src\lib\Common.ps1')

$TestRoot  = Join-Path $env:TEMP 'photosorter-tests'
$Inbox     = Join-Path $TestRoot '待分类1'
$Library   = Join-Path $TestRoot '主目录'
$Duplicate = Join-Path $TestRoot '重复'
$Unknown   = Join-Path $TestRoot '认不出格式'

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
    }
}

function Assert-PathExists {
    param([string]$Path, [string]$Message)
    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message ($Message + "  ($Path)")
}

function Assert-PathMissing {
    param([string]$Path, [string]$Message)
    Assert-True -Condition (-not (Test-Path -LiteralPath $Path)) -Message ($Message + "  ($Path)")
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    Assert-True -Condition ($Text -match [regex]::Escape($Pattern)) -Message $Message
}

# 以子进程方式跑真实脚本，模拟用户双击 bat 的效果
function Invoke-Script {
    param([string]$ScriptName, [string[]]$Arguments)

    $scriptPath = Join-Path $RepoRoot ('src\' + $ScriptName)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Root', $TestRoot) + $Arguments
    $out = & powershell @all 2>&1
    return ($out | Out-String)
}

# 以相对路径给测试照片写 EXIF：exiftool 在 Windows 上遇到命令行里的中文路径会报警，
# 切进目录后用文件名（全 ASCII）就干净了。
function Set-Exif {
    param([string]$RelativePath, [string[]]$Tags)
    Push-Location -LiteralPath $Inbox
    try { & $exifTool -overwrite_original -q @Tags $RelativePath } finally { Pop-Location }
}

# ---------------------------------------------------------------------------
# 造数据
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing

function New-Jpeg {
    param([string]$Path, [System.Drawing.Color]$Color, [int]$Width = 80, [int]$Height = 60)
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($Color)
    $g.FillEllipse([System.Drawing.Brushes]::Black, 5, 5, 20, 20)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g.Dispose(); $bmp.Dispose()
}

$exifTool = Get-ExifToolPath -RepoRoot $RepoRoot

if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
New-Item -ItemType Directory -Path $Inbox, (Join-Path $Inbox 'sub'), $Library -Force | Out-Null

Write-Host ''
Write-Host ('临时资料库：' + $TestRoot) -ForegroundColor Cyan
Write-Host ('ExifTool  ：' + $exifTool)

# 1) 佳能：设备 + 时间 + GPS
$canonFull = Join-Path $Inbox 'canon_full.jpg'
New-Jpeg -Path $canonFull -Color ([System.Drawing.Color]::FromArgb(200, 30, 30))
Set-Exif -RelativePath 'canon_full.jpg' -Tags @(
    '-Make=Canon', '-Model=Canon EOS R6',
    '-DateTimeOriginal=2024:05:10 14:23:01',
    '-GPSLatitude=31.2345', '-GPSLatitudeRef=N',
    '-GPSLongitude=121.4701', '-GPSLongitudeRef=E')

# 2) 佳能：有设备有时间，没有 GPS
$canonNoGps = Join-Path $Inbox 'canon_nogps.jpg'
New-Jpeg -Path $canonNoGps -Color ([System.Drawing.Color]::FromArgb(30, 160, 30))
Set-Exif -RelativePath 'canon_nogps.jpg' -Tags @(
    '-Make=Canon', '-Model=Canon EOS R6', '-DateTimeOriginal=2024:05:10 15:00:00')

# 3) iPhone：有设备有 GPS，没有时间
$iphoneNoTime = Join-Path $Inbox 'iphone_notime.jpg'
New-Jpeg -Path $iphoneNoTime -Color ([System.Drawing.Color]::FromArgb(30, 30, 200))
Set-Exif -RelativePath 'iphone_notime.jpg' -Tags @(
    '-Make=Apple', '-Model=iPhone 13',
    '-GPSLatitude=22.5431', '-GPSLatitudeRef=N',
    '-GPSLongitude=114.0579', '-GPSLongitudeRef=E')

# 4) 什么元数据都没有
New-Jpeg -Path (Join-Path $Inbox 'plain.jpg') -Color ([System.Drawing.Color]::FromArgb(220, 220, 30))

# 5) 子目录里的照片（验证 -r 递归）
$nested = Join-Path $Inbox 'sub\nested.jpg'
New-Jpeg -Path $nested -Color ([System.Drawing.Color]::FromArgb(120, 0, 120))
Set-Exif -RelativePath 'sub\nested.jpg' -Tags @(
    '-Make=Canon', '-Model=Canon EOS R6', '-DateTimeOriginal=2024:05:12 09:30:00')

# 6) 完全相同的副本（测内部去重）
Copy-Item -LiteralPath $canonFull -Destination (Join-Path $Inbox 'canon_full - copy.jpg')

# 7) 非照片/视频
Set-Content -LiteralPath (Join-Path $Inbox 'note.txt') -Value 'text file' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Inbox '报价单.docx') -Value 'fake docx' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Inbox 'no-extension') -Value 'no ext' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Inbox 'sub\清单.md') -Value '# md' -Encoding UTF8

# 8) 认不出格式：文本改名 .jpg、0 字节、随机字节 mp4
Set-Content -LiteralPath (Join-Path $Inbox 'fake.jpg') -Value 'I am plain text' -Encoding UTF8
[System.IO.File]::WriteAllBytes((Join-Path $Inbox 'empty.jpg'), @())
$random = New-Object byte[] 8192
(New-Object System.Random(7)).NextBytes($random)
[System.IO.File]::WriteAllBytes((Join-Path $Inbox 'broken.mp4'), $random)

$sourceHash = Get-FileSha256 -Path $canonFull

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '>>> 1/4 待分类1 内部去重' -ForegroundColor Cyan
$out = Invoke-Script -ScriptName 'Dedupe.ps1' -Arguments @('-Scope', 'Inbox')

Assert-Match -Text $out -Pattern '判定重复 1 个' -Message '内部去重判定 1 个重复'
$dupBatches = @(Get-ChildItem -LiteralPath $Duplicate -Directory -ErrorAction SilentlyContinue)
Assert-True -Condition ($dupBatches.Count -eq 1) -Message '重复\ 下新建了一个批次目录'
Assert-PathMissing -Path (Join-Path $Inbox 'canon_full - copy.jpg') -Message '副本已从待分类1 移走'
Assert-PathExists  -Path $canonFull -Message '原件仍留在待分类1（复制模式）'
Assert-PathExists  -Path (Join-Path $Inbox 'fake.jpg') -Message '认不出格式的文件在去重阶段不动'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '>>> 2/4 分类到主目录' -ForegroundColor Cyan
$out = Invoke-Script -ScriptName 'Classify.ps1' -Arguments @()

Assert-PathExists -Path (Join-Path $Library 'Canon EOS R6\2024-05-10\N31.23_E121.47\canon_full.jpg') -Message '设备+时间+GPS 三层齐全'
Assert-PathExists -Path (Join-Path $Library 'Canon EOS R6\2024-05-10\无数据\canon_nogps.jpg') -Message '缺 GPS -> 地点层为无数据'
Assert-PathExists -Path (Join-Path $Library 'Apple iPhone 13\无数据\N22.54_E114.06\iphone_notime.jpg') -Message '缺时间 -> 时间层为无数据'
Assert-PathExists -Path (Join-Path $Library '无数据\无数据\无数据\plain.jpg') -Message '全缺 -> 三层都是无数据'
Assert-PathExists -Path (Join-Path $Library 'Canon EOS R6\2024-05-12\无数据\nested.jpg') -Message '子目录里的照片也扫到了'
Assert-PathExists -Path (Join-Path $Unknown 'fake.jpg') -Message 'text/plain 冒充的 jpg 进了 认不出格式'
Assert-PathExists -Path (Join-Path $Unknown 'empty.jpg') -Message '0 字节文件进了 认不出格式'
Assert-PathExists -Path (Join-Path $Unknown 'broken.mp4') -Message '残片 mp4 进了 认不出格式'
Assert-PathExists -Path (Join-Path $Inbox 'note.txt') -Message 'txt 留在待分类1 没动'
Assert-PathExists -Path (Join-Path $Inbox '报价单.docx') -Message 'docx 留在待分类1 没动'
Assert-PathExists -Path (Join-Path $Inbox 'no-extension') -Message '无扩展名文件留在待分类1 没动'

$txtInLibrary = @(Get-ChildItem -LiteralPath $Library -Recurse -File |
                  Where-Object { @('.txt', '.docx', '.md') -contains $_.Extension.ToLower() })
Assert-True -Condition ($txtInLibrary.Count -eq 0) -Message '主目录里一个非媒体文件都没有'

$copiedHash = Get-FileSha256 -Path (Join-Path $Library 'Canon EOS R6\2024-05-10\N31.23_E121.47\canon_full.jpg')
Assert-True -Condition ($copiedHash -eq $sourceHash) -Message '复制后 SHA-256 与原文件一致（去重的前提）'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '>>> 3/4 再跑一次分类（应全部跳过，不产生副本）' -ForegroundColor Cyan
$before = @(Get-ChildItem -LiteralPath $Library -Recurse -File).Count
$out = Invoke-Script -ScriptName 'Classify.ps1' -Arguments @()
$after = @(Get-ChildItem -LiteralPath $Library -Recurse -File).Count

Assert-Match -Text $out -Pattern '跳过(已存在相同文件)' -Message '输出里出现「跳过(已存在相同文件)」'
Assert-True -Condition ($before -eq $after) -Message '重复分类没有增加文件'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '>>> 4/4 新一批：对比主目录去重' -ForegroundColor Cyan

# 清空待分类1（模拟用户手动删除），再放入：主目录已有的那份 + 一张全新照片
Get-ChildItem -LiteralPath $Inbox -Force | Remove-Item -Recurse -Force

Copy-Item -LiteralPath (Join-Path $Library 'Canon EOS R6\2024-05-10\N31.23_E121.47\canon_full.jpg') `
          -Destination (Join-Path $Inbox 'wechat-saved.jpg')

$newPhoto = Join-Path $Inbox 'new_june.jpg'
New-Jpeg -Path $newPhoto -Color ([System.Drawing.Color]::FromArgb(10, 200, 200))
Set-Exif -RelativePath 'new_june.jpg' -Tags @(
    '-Make=Canon', '-Model=Canon EOS R6', '-DateTimeOriginal=2024:06:01 09:10:11')

$out = Invoke-Script -ScriptName 'Dedupe.ps1' -Arguments @('-Scope', 'Library')
Assert-Match -Text $out -Pattern '判定重复 1 个' -Message '跨库去重判定 1 个重复'
Assert-PathMissing -Path (Join-Path $Inbox 'wechat-saved.jpg') -Message '与主目录重复的那份已移走'
Assert-PathExists  -Path (Join-Path $Library 'Canon EOS R6\2024-05-10\N31.23_E121.47\canon_full.jpg') -Message '主目录那份没被动'
Assert-PathExists  -Path $newPhoto -Message '全新照片留在待分类1'

$out = Invoke-Script -ScriptName 'Dedupe.ps1' -Arguments @('-Scope', 'Library')
Assert-Match -Text $out -Pattern '判定重复 0 个' -Message '重复跑一次不再有重复'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------------------'
if ($script:Failed -eq 0) {
    Write-Host (" 全部通过：{0} 项断言" -f $script:Passed) -ForegroundColor Green
}
else {
    Write-Host (" 失败 {0} 项 / 通过 {1} 项" -f $script:Failed, $script:Passed) -ForegroundColor Red
}
Write-Host '------------------------------------------------------------'

if ($Keep) {
    Write-Host ('临时资料库保留在：' + $TestRoot)
}
else {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
