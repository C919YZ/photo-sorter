#Requires -Version 5.1
<#
.SYNOPSIS
    按 EXIF 把待分类1 里的照片/视频【复制】到 主目录\<设备>\<时间>\<地点>\

.DESCRIPTION
    结构固定三层，任何一层取不到就写"无数据"，保证目录深浅一致。

    扩展名像照片、内容却不是的（文本改名成 .jpg、下坏的残片、0 字节文件）
    不会进主目录，会被移到 主目录 同级的「认不出格式」文件夹。
    不是照片/视频的文件（txt / docx / 无扩展名 …）一个都不碰，只列出来提醒。

    复制而不是移动：源文件留在待分类1，由用户确认后自己删。
    拷贝用 Copy-Item 原样搬字节，不改元数据 —— 这是后续 SHA-256 去重能对上的前提。

.PARAMETER Root
    资料库根目录，下面应该有 待分类1 / 主目录。不传则读 config.ps1。

.PARAMETER TimeGroup
    时间层粒度：day(2024-05-10) / month(2024-05) / year(2024)。

.PARAMETER Preview
    只打印会分到哪，不复制、不移动、不写日志。

.PARAMETER ConfigPath
    配置文件路径，默认仓库根目录的 config.ps1。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Classify.ps1 -Preview

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Classify.ps1 -TimeGroup month
#>
[CmdletBinding()]
param(
    [string]$Root,
    [ValidateSet('day', 'month', 'year')][string]$TimeGroup,
    [switch]$Preview,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'src\lib\Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config.ps1' }
$cfg = Get-AppConfig -ConfigPath $ConfigPath

if (-not $Root)      { $Root = $cfg.Root }
if (-not $TimeGroup) { $TimeGroup = $cfg.TimeGroup }

$Inbox   = Join-Path $Root $cfg.InboxFolderName
$Library = Join-Path $Root $cfg.LibraryFolderName
$Unknown = Join-Path $Root $cfg.UnknownFolderName
$LogDir  = Join-Path $Root '.logs'
$NA      = $cfg.UnknownValue

if (-not (Test-Path -LiteralPath $Inbox)) {
    throw "找不到待分类文件夹：$Inbox"
}

$ExifTool = Get-ExifToolPath -Configured $cfg.ExifToolPath -RepoRoot $RepoRoot

Write-Section 'PhotoSorter · 分类'
Write-Host (" 待分类1 : " + $Inbox)
Write-Host (" 主目录  : " + $Library)
Write-Host (" 时间粒度: " + $TimeGroup)
Write-Host (" ExifTool: " + $ExifTool)
if ($Preview) { Write-Host ' 预览模式：不会复制、不会移动' -ForegroundColor Yellow }

# ============================================================================
# 1. 让 exiftool 输出 JSON
# ============================================================================
$jsonPath = Join-Path $env:TEMP ('photosorter_' + [guid]::NewGuid().ToString('N') + '.json')
$errPath  = [System.IO.Path]::ChangeExtension($jsonPath, '.err')

$tagList = @(
    'FileType', 'MIMEType',
    'Make', 'Model',
    'DateTimeOriginal', 'CreateDate', 'MediaCreateDate', 'TrackCreateDate', 'CreationDate',
    'GPSLatitude', 'GPSLongitude', 'GPSCoordinates'
)

$argList = @('-j', '-G0', '-f', '-n', '-r', '-charset', 'exiftool=UTF8', '-charset', 'filename=UTF8')
foreach ($t in $tagList) { $argList += ('-' + $t) }
foreach ($e in ($script:MediaExtensions | ForEach-Object { $_.TrimStart('.') })) {
    $argList += '-ext'; $argList += $e
}
$argList += '.'

# 两个 Windows 上的坑都在这一行里解决：
#  1) 用 cmd 重定向把 JSON 写成文件 —— PS 5.1 捕获原生命令 stdout 时按控制台代码页(GB2312)
#     解码，中文文件名必然乱码；写进文件再按 UTF-8 读就没这个问题。
#  2) 参数用 "." 而不是中文绝对路径 —— exiftool 在 Windows 上会对命令行里的中文文件名
#     报 "FileName encoding must be specified"。先切进待分类1 再扫 "." 就绕开了。
$cmdLine = '"' + $ExifTool + '" ' + ($argList -join ' ') + ' > "' + $jsonPath + '" 2> "' + $errPath + '"'
Write-Host ''
Write-Host '读取元数据…'
Push-Location -LiteralPath $Inbox
try { $null = cmd /c $cmdLine } finally { Pop-Location }

if (-not (Test-Path -LiteralPath $jsonPath)) {
    throw 'exiftool 没有产生输出，检查是否被杀毒软件拦截。'
}

$raw = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8
Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue

# exiftool 解析失败的文件不会出现在 JSON 里，单独提示一下
if (Test-Path -LiteralPath $errPath) {
    $errs = @(Get-Content -LiteralPath $errPath -Encoding UTF8 | Where-Object { $_ -match '^(Error|Warning)' })
    if ($errs.Count -gt 0) {
        Write-Host ("注意：exiftool 报了 {0} 条错误，涉及的文件读不出元数据：" -f $errs.Count) -ForegroundColor Yellow
        $errs | Select-Object -First 10 | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor Yellow }
    }
    Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
}

# 注意：PowerShell 5.1 里 @($raw | ConvertFrom-Json) 会把整个数组再套一层
#（结果 Count 永远是 1、元素是数组），必须分成两句写。
$items = $raw | ConvertFrom-Json
if ($null -eq $items) { $items = @() }
elseif ($items -isnot [System.Array]) { $items = @($items) }

Show-IgnoredFiles -Path $Inbox -Title '待分类1'

if ($items.Count -eq 0) {
    Write-Host '待分类1 里没有可识别的照片/视频。' -ForegroundColor Yellow
    return
}

# ============================================================================
# 2. 逐个算目标目录并复制
# ============================================================================
if (-not (Test-Path -LiteralPath $Library)) {
    New-Item -ItemType Directory -Path $Library -Force | Out-Null
}

$copied = 0
$skipped = 0
$renamed = 0
$failed = 0
$unknownCount = 0
$deviceStats = @{}
$log = New-Object System.Collections.Generic.List[object]
$seen = New-Object 'System.Collections.Generic.HashSet[string]'

Write-Host ''
foreach ($item in $items) {

    $src = "$($item.SourceFile)"
    if ($src.StartsWith('./') -or $src.StartsWith('.\')) { $src = $src.Substring(2) }
    if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path $Inbox $src }
    if (-not (Test-Path -LiteralPath $src)) { continue }
    [void]$seen.Add($src)

    # --- 是不是真的照片/视频 ---
    $fileType = Get-ExifField -InputObject $item -Names @('FileType')
    $mime     = Get-ExifField -InputObject $item -Names @('MIMEType')
    $isMedia  = ($mime -match '^(image|video)/') -or
                ($fileType -ne '' -and $script:MediaFileTypes -contains $fileType)

    if (-not $isMedia) {
        $unknownCount++
        $reason = if ($mime) { $mime } else { '未知' }
        $movedTo = ''
        if (-not $Preview) { $movedTo = Move-ToUniquePath -SourceFile $src -DestinationFolder $Unknown }
        Write-Host ("[认不出格式({0})，已移出] {1}  ->  {2}" -f $reason, [System.IO.Path]::GetFileName($src),
                    $(if ($Preview) { $Unknown } else { $movedTo })) -ForegroundColor DarkYellow
        $log.Add([pscustomobject]@{
            源文件 = $src; 目标 = $movedTo; 设备 = ''; 时间 = ''; 地点 = ''
            EXIF时间 = ''; 动作 = "认不出格式($reason)，已移出"
        })
        continue
    }

    # --- 设备：Make + Model，Model 已包含厂商时不再重复拼 ---
    $make  = Get-ExifField -InputObject $item -Names @('Make')
    $model = Get-ExifField -InputObject $item -Names @('Model')
    if ($model -and $make -and -not $model.StartsWith($make, [System.StringComparison]::OrdinalIgnoreCase)) {
        $deviceRaw = "$make $model"
    }
    elseif ($model) { $deviceRaw = $model }
    elseif ($make)  { $deviceRaw = $make }
    else            { $deviceRaw = '' }
    $device = ConvertTo-SafeFolderName -Name $deviceRaw -Fallback $NA

    # --- 时间：按优先级取第一个有值的 EXIF 时间 ---
    $dateValue = Get-ExifField -InputObject $item -Names @(
        'DateTimeOriginal', 'CreateDate', 'MediaCreateDate', 'TrackCreateDate', 'CreationDate')
    $timeFolder = ConvertTo-TimeFolder -Value $dateValue -Mode $TimeGroup -Fallback $NA

    # --- 地点：GPS 十进制度优先，退而求其次解析 GPSCoordinates 字符串（手机视频常见）---
    $lat = 0.0; $lon = 0.0; $hasGps = $false
    $latText = Get-ExifField -InputObject $item -Names @('GPSLatitude')
    $lonText = Get-ExifField -InputObject $item -Names @('GPSLongitude')
    if ($latText -and $lonText) {
        $parsedLat = 0.0; $parsedLon = 0.0
        if ([double]::TryParse($latText, [ref]$parsedLat) -and [double]::TryParse($lonText, [ref]$parsedLon)) {
            if (-not ($parsedLat -eq 0 -and $parsedLon -eq 0)) {
                $lat = $parsedLat; $lon = $parsedLon; $hasGps = $true
            }
        }
    }
    if (-not $hasGps) {
        $gpsText = Get-ExifField -InputObject $item -Names @('GPSCoordinates')
        if ($gpsText) {
            $pair = ConvertFrom-GpsString -Text $gpsText
            if ($pair) { $lat = $pair[0]; $lon = $pair[1]; $hasGps = $true }
        }
    }
    $locationFolder = if ($hasGps) { Format-GpsFolder -Latitude $lat -Longitude $lon } else { $NA }

    # --- 落盘 ---
    $destDir = Join-Path (Join-Path (Join-Path $Library $device) $timeFolder) $locationFolder
    $fileName = [System.IO.Path]::GetFileName($src)
    $target = Join-Path $destDir $fileName
    $action = ''

    try {
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        if (Test-Path -LiteralPath $target) {
            if (Test-SameContent -A $src -B $target) {
                $action = '跳过(已存在相同文件)'
                $skipped++
            }
            else {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $ext  = [System.IO.Path]::GetExtension($fileName)
                $i = 1
                while (Test-Path -LiteralPath $target) {
                    $target = Join-Path $destDir ('{0}_{1}{2}' -f $base, $i, $ext)
                    $i++
                }
                $action = '复制(同名加序号)'
                $renamed++
            }
        }
        else {
            $action = '复制'
        }

        if ($action -eq '复制' -or $action -eq '复制(同名加序号)') {
            if (-not $Preview) { Copy-Item -LiteralPath $src -Destination $target }
            $copied++
        }

        $relative = $target.Substring($Library.Length).TrimStart('\')
        Write-Host ("[{0}] {1}" -f $action, $relative) -ForegroundColor $(if ($action -like '跳过*') { 'DarkGray' } else { 'Gray' })

        if (-not $deviceStats.ContainsKey($device)) { $deviceStats[$device] = 0 }
        $deviceStats[$device]++

        $log.Add([pscustomobject]@{
            源文件 = $src; 目标 = $target; 设备 = $device; 时间 = $timeFolder
            地点 = $locationFolder; EXIF时间 = $dateValue; 动作 = $action
        })
    }
    catch {
        $failed++
        Write-Host ("[失败] {0} -> {1}" -f $src, $_.Exception.Message) -ForegroundColor Red
    }
}

# ============================================================================
# 3. 完全读不出来的文件（0 字节、残片）也移出去
# ============================================================================
$leftover = @(Get-MediaFileList -Path $Inbox | Where-Object { -not $seen.Contains($_.FullName) })
foreach ($f in $leftover) {
    $unknownCount++
    $movedTo = ''
    if (-not $Preview) { $movedTo = Move-ToUniquePath -SourceFile $f.FullName -DestinationFolder $Unknown }
    Write-Host ("[读不出，已移出] {0}  ->  {1}" -f $f.Name, $(if ($Preview) { $Unknown } else { $movedTo })) -ForegroundColor DarkYellow
    $log.Add([pscustomobject]@{
        源文件 = $f.FullName; 目标 = $movedTo; 设备 = ''; 时间 = ''; 地点 = ''
        EXIF时间 = ''; 动作 = '读不出(已移出)'
    })
}

# ============================================================================
# 4. 汇总
# ============================================================================
Write-Section '完成'
Write-Host (" 处理 {0} 个文件：复制 {1}，跳过 {2}，同名加序号 {3}，失败 {4}" -f `
           $items.Count, $copied, $skipped, $renamed, $failed) -ForegroundColor Cyan
if ($unknownCount -gt 0) {
    Write-Host (" 认不出格式/读不出：{0} 个，已移到 {1}" -f $unknownCount, $Unknown) -ForegroundColor Yellow
}
if ($deviceStats.Count -gt 0) {
    Write-Host ' 按设备：'
    foreach ($k in ($deviceStats.Keys | Sort-Object)) {
        Write-Host ("   {0,-40} {1,5}" -f $k, $deviceStats[$k])
    }
}
if ($Preview) { Write-Host ' （预览模式：没有真正复制）' -ForegroundColor Yellow }

if ($log.Count -gt 0 -and -not $Preview) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $logFile = Join-Path $LogDir ('classify_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $log | Export-Csv -LiteralPath $logFile -NoTypeInformation -Encoding UTF8
    Write-Host (" 日志：" + $logFile)
}
