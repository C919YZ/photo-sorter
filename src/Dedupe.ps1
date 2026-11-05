#Requires -Version 5.1
<#
.SYNOPSIS
    SHA-256 逐字节去重，两种模式：待分类1 内部去重 / 待分类1 对比主目录去重。

.DESCRIPTION
    Inbox   只比待分类1 内部：内容完全相同的只留 1 份，其余移到 重复\<时间戳>_inbox\
    Library 待分类1 对比主目录：主目录里已有相同内容的，把待分类1 那份移到
            重复\<时间戳>_library\（主目录那份不动）

    判定依据是 SHA-256 全文件哈希，不看文件名、大小、拍摄时间。
    先按文件大小分组，只有大小相同的才去算哈希 —— 大小不同内容必然不同，
    这一步能把几千张照片的哈希计算量压到几十次。

.PARAMETER Scope
    Inbox 或 Library。

.PARAMETER Root
    资料库根目录。不传则读 config.ps1。

.PARAMETER Preview
    只报告，不移动文件、不更新缓存、不写日志。

.PARAMETER ConfigPath
    配置文件路径，默认仓库根目录的 config.ps1。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Dedupe.ps1 -Scope Inbox

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Dedupe.ps1 -Scope Library -Preview
#>
[CmdletBinding()]
param(
    [ValidateSet('Inbox', 'Library')][string]$Scope = 'Inbox',
    [string]$Root,
    [switch]$Preview,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'src\lib\Common.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config.ps1' }
$cfg = Get-AppConfig -ConfigPath $ConfigPath

if (-not $Root) { $Root = $cfg.Root }

$Inbox     = Join-Path $Root $cfg.InboxFolderName
$Library   = Join-Path $Root $cfg.LibraryFolderName
$DupRoot   = Join-Path $Root $cfg.DuplicateFolderName
$CacheDir  = Join-Path $Root '.cache'
$LogDir    = Join-Path $Root '.logs'
$CacheFile = Join-Path $CacheDir 'library-hashes.csv'

if (-not (Test-Path -LiteralPath $Inbox)) {
    throw "找不到待分类文件夹：$Inbox"
}
if ($Scope -eq 'Library' -and -not (Test-Path -LiteralPath $Library)) {
    throw "找不到主目录：$Library（先跑一次 Classify.ps1）"
}

# 本次运行的重复文件夹：重复\20260101_120000_inbox
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$scopeTag = if ($Scope -eq 'Inbox') { 'inbox' } else { 'library' }
$DupDir = Join-Path $DupRoot ('{0}_{1}' -f $stamp, $scopeTag)

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ('dedupe_{0}_{1}.csv' -f $stamp, $scopeTag)
$log = New-Object System.Collections.Generic.List[object]

Write-Section ('PhotoSorter · 去重（' + $(if ($Scope -eq 'Inbox') { '待分类1 内部' } else { '待分类1 对比 主目录，主目录优先' }) + '）')
Write-Host (" 待分类1 : " + $Inbox)
if ($Scope -eq 'Library') { Write-Host (" 主目录  : " + $Library) }
Write-Host (" 重复夹  : " + $DupDir)
if ($Preview) { Write-Host ' 预览模式：不会移动任何文件' -ForegroundColor Yellow }

# ============================================================================
# 模式 A：待分类1 内部去重
# ============================================================================
if ($Scope -eq 'Inbox') {

    $files = Get-MediaFileList -Path $Inbox
    Show-IgnoredFiles -Path $Inbox -Title '待分类1'

    if ($files.Count -eq 0) {
        Write-Host '待分类1 里没有照片/视频，结束。' -ForegroundColor Yellow
        return
    }

    Write-Host ("待分类1 共 {0} 个媒体文件，按大小分组后计算哈希…" -f $files.Count)

    # 尺寸唯一的文件不可能重复，不参与哈希
    $sizeGroups = @($files | Group-Object Length | Where-Object { $_.Count -gt 1 })
    $hashCount = 0
    $dupCount = 0

    foreach ($group in $sizeGroups) {

        $hashed = foreach ($f in $group.Group) {
            $hashCount++
            Write-Progress -Activity '计算 SHA-256' -Status $f.Name `
                -PercentComplete (($hashCount / [math]::Max(1, $files.Count)) * 100)
            [pscustomobject]@{ File = $f; Hash = (Get-FileSha256 -Path $f.FullName) }
        }

        foreach ($hashGroup in ($hashed | Group-Object Hash)) {
            if ($hashGroup.Count -le 1) { continue }

            # 留哪份：文件名最短的（通常是没带 "- 副本" 的原件），同长比修改时间，再比路径
            $sorted = @($hashGroup.Group | Sort-Object `
                            @{Expression = { $_.File.Name.Length }},
                            @{Expression = { $_.File.LastWriteTimeUtc }},
                            @{Expression = { $_.File.FullName }})
            $keep = $sorted[0]
            Write-Host ('[保留] ' + $keep.File.FullName) -ForegroundColor Green

            for ($i = 1; $i -lt $sorted.Count; $i++) {
                $dup = $sorted[$i].File
                $dupCount++
                Write-Host ("[重复] {0}  (与 {1} 相同)" -f $dup.FullName, $keep.File.Name) -ForegroundColor DarkYellow
                $movedTo = ''
                if (-not $Preview) {
                    $movedTo = Move-ToUniquePath -SourceFile $dup.FullName -DestinationFolder $DupDir
                }
                $log.Add([pscustomobject]@{
                    模式 = 'Inbox'; SHA256 = $hashGroup.Name; 原路径 = $dup.FullName
                    重复于 = $keep.File.FullName; 移到 = $movedTo
                    时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                })
            }
        }
    }

    Write-Progress -Activity '计算 SHA-256' -Completed

    Write-Section '完成'
    Write-Host (" 共 {0} 个文件，计算了 {1} 个哈希，判定重复 {2} 个" -f $files.Count, $hashCount, $dupCount) -ForegroundColor Cyan
    if ($dupCount -gt 0) { Write-Host (" 重复文件已移到：" + $DupDir) -ForegroundColor Cyan }
    if ($Preview) { Write-Host ' （预览模式，实际没有移动）' -ForegroundColor Yellow }
}

# ============================================================================
# 模式 B：待分类1 对比主目录（主目录优先保留）
# ============================================================================
else {

    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    # ---- 1. 读缓存：相对路径 -> 大小 / 修改时间 / 哈希 ----
    $cache = @{}
    if (Test-Path -LiteralPath $CacheFile) {
        try {
            Import-Csv -LiteralPath $CacheFile -Encoding UTF8 | ForEach-Object {
                $cache[$_.RelPath] = [pscustomobject]@{
                    Size  = [int64]$_.Size
                    Ticks = [int64]$_.MTimeUtcTicks
                    Hash  = $_.Hash
                }
            }
        }
        catch {
            Write-Host '缓存文件损坏，本次重建。' -ForegroundColor Yellow
            $cache = @{}
        }
    }

    # ---- 2. 扫描主目录：没变过的直接复用缓存 ----
    $libraryFiles = Get-MediaFileList -Path $Library
    Write-Host ("主目录共 {0} 个媒体文件" -f $libraryFiles.Count)

    $libraryHashes = New-Object 'System.Collections.Generic.HashSet[string]'
    $librarySizes  = New-Object 'System.Collections.Generic.HashSet[long]'
    $newCache = New-Object System.Collections.Generic.List[object]
    $hashedLib = 0
    $reusedLib = 0

    foreach ($f in $libraryFiles) {
        $rel = $f.FullName.Substring($Library.Length).TrimStart('\')
        $hash = $null

        if ($cache.ContainsKey($rel)) {
            $c = $cache[$rel]
            if ($c.Size -eq $f.Length -and $c.Ticks -eq $f.LastWriteTimeUtc.Ticks) {
                $hash = $c.Hash
                $reusedLib++
            }
        }
        if (-not $hash) {
            Write-Progress -Activity '建立主目录哈希索引' -Status $f.Name
            $hash = Get-FileSha256 -Path $f.FullName
            $hashedLib++
        }

        [void]$libraryHashes.Add($hash)
        [void]$librarySizes.Add([int64]$f.Length)
        $newCache.Add([pscustomobject]@{
            Size = $f.Length
            MTimeUtcTicks = $f.LastWriteTimeUtc.Ticks
            Hash = $hash
            RelPath = $rel
        })
    }
    Write-Progress -Activity '建立主目录哈希索引' -Completed

    # 只写回当前仍存在的文件，手动删掉的条目会自动消失
    if (-not $Preview) {
        $newCache | Export-Csv -LiteralPath $CacheFile -NoTypeInformation -Encoding UTF8
    }

    Write-Host ("主目录哈希：复用 {0} 个，新算 {1} 个" -f $reusedLib, $hashedLib)
    if ($libraryHashes.Count -lt $libraryFiles.Count) {
        Write-Host ("注意：主目录内部已有 {0} 组重复内容（本脚本不动主目录）" -f `
                    ($libraryFiles.Count - $libraryHashes.Count)) -ForegroundColor Yellow
    }

    # ---- 3. 待分类1 逐个比对 ----
    $inboxFiles = Get-MediaFileList -Path $Inbox
    Show-IgnoredFiles -Path $Inbox -Title '待分类1'
    if ($inboxFiles.Count -eq 0) {
        Write-Host '待分类1 里没有照片/视频，结束。' -ForegroundColor Yellow
        return
    }

    $dupCount = 0
    $safeCount = 0
    $skipHash = 0

    foreach ($f in $inboxFiles) {
        # 大小不在主目录里 -> 必然不重复，省一次哈希
        if (-not $librarySizes.Contains([int64]$f.Length)) {
            $skipHash++
            $safeCount++
            continue
        }

        $hash = Get-FileSha256 -Path $f.FullName
        if ($libraryHashes.Contains($hash)) {
            $dupCount++
            Write-Host ('[主目录已有，移到重复] ' + $f.FullName) -ForegroundColor DarkYellow
            $movedTo = ''
            if (-not $Preview) {
                $movedTo = Move-ToUniquePath -SourceFile $f.FullName -DestinationFolder $DupDir
            }
            $log.Add([pscustomobject]@{
                模式 = 'Library'; SHA256 = $hash; 原路径 = $f.FullName
                重复于 = '（主目录）'; 移到 = $movedTo
                时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            })
        }
        else {
            $safeCount++
        }
    }

    Write-Section '完成'
    Write-Host (" 待分类1 共 {0} 个文件，{1} 个大小在主目录里出现过、需要算哈希" -f `
                $inboxFiles.Count, ($inboxFiles.Count - $skipHash)) -ForegroundColor Cyan
    Write-Host (" 判定重复 {0} 个，保留待分类 {1} 个" -f $dupCount, $safeCount) -ForegroundColor Cyan
    if ($dupCount -gt 0) { Write-Host (" 重复文件已移到：" + $DupDir) -ForegroundColor Cyan }
    if ($Preview) { Write-Host ' （预览模式，实际没有移动）' -ForegroundColor Yellow }
}

# ============================================================================
# 日志
# ============================================================================
if ($log.Count -gt 0 -and -not $Preview) {
    $log | Export-Csv -LiteralPath $LogFile -NoTypeInformation -Encoding UTF8
    Write-Host (" 日志：" + $LogFile)
}
