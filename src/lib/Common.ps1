#Requires -Version 5.1
<#
================================================================================
 PhotoSorter · 共用函数库
 由 src\Classify.ps1 / src\Dedupe.ps1 通过 . (dot-source) 引入，不单独运行。

 约定：
   * 只用 PowerShell 5.1 自带语法（不依赖 PS7 的 ?? / 三元 / -Parallel）
   * 表达"读不到"时返回 $null 或空串，不 throw，由调用方决定怎么处理
   * 文件系统一律用 -LiteralPath，避免文件名里的 [ ] 被当成通配符
================================================================================
#>

# ----------------------------------------------------------------------------
# 常量：什么算"照片/视频"
# ----------------------------------------------------------------------------

# 参与扫描的扩展名（小写，带点）
$script:MediaExtensions = @(
    '.jpg', '.jpeg', '.heic', '.heif', '.png', '.webp', '.gif', '.bmp', '.tif', '.tiff',
    '.dng', '.cr2', '.cr3', '.nef', '.arw', '.raf', '.rw2', '.orf', '.srw',
    '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.3gp', '.mts', '.m2ts', '.wmv', '.flv', '.mpg', '.mpeg'
)

# exiftool 认出来的 FileType 白名单：MIMEType 缺失时用它兜底
$script:MediaFileTypes = @(
    'JPEG', 'PNG', 'GIF', 'BMP', 'TIFF', 'HEIC', 'HEIF', 'AVIF', 'WEBP', 'JXL',
    'MP4', 'MOV', 'M4V', 'AVI', 'MKV', 'WEBM', '3GP', '3G2', 'MTS', 'M2TS', 'WMV', 'FLV', 'MPG', 'MPEG',
    'CR2', 'CR3', 'NEF', 'ARW', 'RAF', 'RW2', 'ORF', 'SRW', 'DNG', 'PEF', 'X3F'
)

# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------

<#
 读取 config.ps1（一个直接 return 哈希表的脚本），与内置默认值合并。
 缺项自动用默认值补齐，所以 config.ps1 只写想改的键就行。
#>
function Get-AppConfig {
    param([string]$ConfigPath)

    $cfg = @{
        Root                = Join-Path $env:USERPROFILE 'Pictures\照片库'
        TimeGroup           = 'day'          # day | month | year
        ExifToolPath        = ''             # 空 = 自动查找
        InboxFolderName     = '待分类1'
        LibraryFolderName   = '主目录'
        DuplicateFolderName = '重复'
        UnknownFolderName   = '认不出格式'
        UnknownValue        = '无数据'        # 某一层取不到值时的文件夹名
    }

    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $user = & $ConfigPath
            if ($user -is [hashtable]) {
                foreach ($k in $user.Keys) { $cfg[$k] = $user[$k] }
            }
        }
        catch {
            Write-Host ("[警告] 读取配置失败，改用默认值：" + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    return $cfg
}

# ----------------------------------------------------------------------------
# ExifTool 定位
# ----------------------------------------------------------------------------

<#
 按优先级找 exiftool.exe：
   1. 配置里写死的 ExifToolPath
   2. PATH
   3. 仓库自带的 tools\exiftool\exiftool.exe
   4. 常见安装位置
 找不到就 throw —— 这个错误无法降级处理，必须让用户看见。
#>
function Get-ExifToolPath {
    param([string]$Configured, [string]$RepoRoot)

    $cands = New-Object System.Collections.Generic.List[string]
    if ($Configured) { $cands.Add($Configured) }

    foreach ($name in @('exiftool.exe', 'exiftool')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $cands.Add($cmd.Source) }
    }

    if ($RepoRoot) { $cands.Add((Join-Path $RepoRoot 'tools\exiftool\exiftool.exe')) }
    $cands.Add('C:\Users\c9195\Tools\exiftool\exiftool.exe')
    $cands.Add('C:\Windows\exiftool.exe')

    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }

    throw @"
找不到 exiftool.exe。请任选一种方式：
  1) 从 https://exiftool.org/ 下载 Windows 版，解压到仓库的 tools\exiftool\ 下
  2) 装好后把路径写进 config.ps1 的 ExifToolPath
已尝试：$($cands -join ' | ')
"@
}

# ----------------------------------------------------------------------------
# 哈希
# ----------------------------------------------------------------------------

<#
 计算 SHA-256，返回 64 位大写十六进制字符串。
 流式读取，几个 GB 的视频也不会吃内存；
 FileShare.ReadWrite 让别的程序正在读同一文件时不至于失败。
#>
function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = $null
    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $bytes = $sha.ComputeHash($fs)
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
    }
    finally {
        if ($fs) { $fs.Dispose() }
        $sha.Dispose()
    }
}

# 同名冲突时判断两个文件内容是否一致（先比长度，再比哈希）
function Test-SameContent {
    param([string]$A, [string]$B)

    $fa = Get-Item -LiteralPath $A
    $fb = Get-Item -LiteralPath $B
    if ($fa.Length -ne $fb.Length) { return $false }
    return ((Get-FileSha256 $A) -eq (Get-FileSha256 $B))
}

# ----------------------------------------------------------------------------
# EXIF 取值与格式化
# ----------------------------------------------------------------------------

<#
 从 exiftool -j 的单个对象里按标签名取值。
 同一个标签可能出现在不同组（EXIF:Make / QuickTime:Model / Keys:Make），
 所以用"以 :标签名 结尾"匹配；-f 模式下缺失标签是 "-"，当空处理。
 $Names 的顺序就是优先级顺序。
#>
function Get-ExifField {
    param($InputObject, [string[]]$Names)

    foreach ($n in $Names) {
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($p.Name -eq $n -or $p.Name.EndsWith(':' + $n)) {
                $v = "$($p.Value)".Trim()
                if ($v -ne '' -and $v -ne '-' -and
                    $v -ne '0000:00:00 00:00:00' -and $v -ne '0000:00:00') {
                    return $v
                }
            }
        }
    }
    return ''
}

<#
 文件夹名净化：去掉 Windows 非法字符、压缩空白、去掉结尾的点和空格、限长 60。
 全空则返回 fallback（默认"无数据"）。
#>
function ConvertTo-SafeFolderName {
    param([string]$Name, [string]$Fallback = '无数据')

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Fallback }
    $s = $Name -replace '[\x00-\x1F<>:"/\\|?*]', '_'
    $s = $s -replace '\s+', ' '
    $s = $s.Trim().TrimEnd('.')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim() }
    if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
    return $s
}

<#
 EXIF 时间字符串 -> 时间文件夹名。
 支持 "2024:05:10 14:23:01" 和 "2024-05-10T14:23:01+08:00" 两种写法。
 年份不在 1900..2100、月日越界一律当无数据（相机没设时间会出现 1970/2000 之类）。
#>
function ConvertTo-TimeFolder {
    param([string]$Value, [string]$Mode = 'day', [string]$Fallback = '无数据')

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    if ($Value -notmatch '^(\d{4})[:\-](\d{2})[:\-](\d{2})') { return $Fallback }

    $y = [int]$matches[1]; $m = [int]$matches[2]; $d = [int]$matches[3]
    if ($y -lt 1900 -or $y -gt 2100 -or $m -lt 1 -or $m -gt 12 -or $d -lt 1 -or $d -gt 31) {
        return $Fallback
    }
    switch ($Mode) {
        'year'  { return ('{0:D4}' -f $y) }
        'month' { return ('{0:D4}-{1:D2}' -f $y, $m) }
        default { return ('{0:D4}-{1:D2}-{2:D2}' -f $y, $m, $d) }
    }
}

<#
 GPS 十进制度 -> 地点文件夹名，四舍五入到 2 位小数（约 1km 网格）。
 31.2345 / 121.4701 -> N31.23_E121.47
 用网格而不是精确坐标，是为了让同一地点反复拍摄能落进同一个文件夹。
#>
function Format-GpsFolder {
    param([double]$Latitude, [double]$Longitude)

    $ns = if ($Latitude -ge 0) { 'N' } else { 'S' }
    $ew = if ($Longitude -ge 0) { 'E' } else { 'W' }
    $la = [math]::Round([math]::Abs($Latitude), 2)
    $lo = [math]::Round([math]::Abs($Longitude), 2)
    return ('{0}{1:0.00}_{2}{3:0.00}' -f $ns, $la, $ew, $lo)
}

<#
 解析视频里的 GPSCoordinates 字符串：
   31 deg 14' 4.20" N, 121 deg 28' 12.36" E
 返回 @(纬度, 经度)，解析失败返回 $null。
#>
function ConvertFrom-GpsString {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $ms = [regex]::Matches($Text, '(\d+(?:\.\d+)?)\s*deg\s*(\d+(?:\.\d+)?)\s*''\s*(\d+(?:\.\d+)?)"?\s*([NSEW])')
    if ($ms.Count -lt 2) { return $null }

    $values = @()
    foreach ($m in $ms) {
        $v = [double]$m.Groups[1].Value + ([double]$m.Groups[2].Value / 60) + ([double]$m.Groups[3].Value / 3600)
        if ($m.Groups[4].Value -eq 'S' -or $m.Groups[4].Value -eq 'W') { $v = -$v }
        $values += $v
    }
    return @($values[0], $values[1])
}

# ----------------------------------------------------------------------------
# 文件清单
# ----------------------------------------------------------------------------

# 递归列出照片/视频
function Get-MediaFileList {
    param([string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $script:MediaExtensions -contains $_.Extension.ToLower() })
}

# 递归列出"不是照片/视频"的文件（只用于提示，不参与任何操作）
function Get-NonMediaFileList {
    param([string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $script:MediaExtensions -notcontains $_.Extension.ToLower() })
}

# ----------------------------------------------------------------------------
# 文件搬运
# ----------------------------------------------------------------------------

<#
 移动文件到目标文件夹，重名自动加 _1 _2 _3，绝不覆盖。
 返回最终落地路径。
#>
function Move-ToUniquePath {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$DestinationFolder
    )

    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
    $ext  = [System.IO.Path]::GetExtension($SourceFile)
    $target = Join-Path $DestinationFolder ($name + $ext)

    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $DestinationFolder ('{0}_{1}{2}' -f $name, $i, $ext)
        $i++
    }

    Move-Item -LiteralPath $SourceFile -Destination $target
    return $target
}

# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------

# 统一的段落标题
function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    if ($Title) { Write-Host " $Title" -ForegroundColor Cyan }
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
}

<#
 提示"待分类1 里这些文件不会被处理"。
 不移动、不改名，只列出来 —— 用户清空待分类1 之前应该知道会丢什么。
#>
function Show-IgnoredFiles {
    param([string]$Path, [string]$Title)

    $others = Get-NonMediaFileList -Path $Path
    if ($others.Count -eq 0) { return }

    Write-Host ("提示：{0} 里有 {1} 个非照片/视频文件，不会被处理：" -f $Title, $others.Count) -ForegroundColor DarkGray
    $others | Select-Object -First 15 | ForEach-Object {
        $rel = $_.FullName.Substring($Path.Length).TrimStart('\')
        Write-Host ('   - ' + $rel) -ForegroundColor DarkGray
    }
    if ($others.Count -gt 15) {
        Write-Host ('   … 另有 {0} 个' -f ($others.Count - 15)) -ForegroundColor DarkGray
    }
    Write-Host '   （清空待分类1 之前留个心眼：这些文件不会进主目录）' -ForegroundColor DarkGray
}
