#Requires -Version 5.1
<#
.SYNOPSIS
    打一个"下载解压就能用"的发行包（含 ExifTool），输出到 dist\。

.DESCRIPTION
    产物：
      dist\PhotoSorter-<版本>-win64\          解压后的目录
      dist\PhotoSorter-<版本>-win64.zip       上传到 GitHub Releases 的文件
      dist\SHA256.txt                         上面 zip 的校验值

    包里不含 config.ps1（那是每台机器自己的配置），不含 .cache / .logs / 测试数据。

.PARAMETER Version
    版本号，默认读 VERSION 文件。

.PARAMETER ExifToolSource
    要打包进去的 exiftool 目录，默认找 tools\exiftool 或本机安装位置。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-release.ps1
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$ExifToolSource
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

if (-not $Version) {
    $versionFile = Join-Path $RepoRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    else {
        $Version = '1.0.0'
    }
}

# ---- 找 exiftool ----
if (-not $ExifToolSource) {
    foreach ($cand in @(
            (Join-Path $RepoRoot 'tools\exiftool'),
            'C:\Users\c9195\Tools\exiftool')) {
        if (Test-Path -LiteralPath (Join-Path $cand 'exiftool.exe')) { $ExifToolSource = $cand; break }
    }
}
if (-not $ExifToolSource -or -not (Test-Path -LiteralPath (Join-Path $ExifToolSource 'exiftool.exe'))) {
    throw '找不到要打包的 exiftool 目录。用 -ExifToolSource 指定一个包含 exiftool.exe 的目录。'
}

$distRoot = Join-Path $RepoRoot 'dist'
$pkgName  = "PhotoSorter-$Version-win64"
$stage    = Join-Path $distRoot $pkgName
$zipPath  = Join-Path $distRoot ($pkgName + '.zip')

Write-Host ''
Write-Host ("打包版本：" + $Version) -ForegroundColor Cyan
Write-Host ("ExifTool：" + $ExifToolSource)

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# ---- 复制内容 ----
$files = @(
    'README.md', '使用说明.txt', 'RELEASE_NOTES.md', 'LICENSE', 'CHANGELOG.md', 'config.example.ps1'
)
foreach ($f in $files) {
    $src = Join-Path $RepoRoot $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $stage }
    else { Write-Host ("[跳过] 缺少 " + $f) -ForegroundColor Yellow }
}

foreach ($dir in @('src', 'bin', 'docs')) {
    $src = Join-Path $RepoRoot $dir
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $stage -Recurse
    }
}

# 包根目录也放一份入口，省得小白找不到 bin\
$rootLauncher = Join-Path $stage '0-开始.bat'
@'
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Menu.ps1" %*
echo.
pause
'@ | Set-Content -LiteralPath $rootLauncher -Encoding ASCII

# ---- 内置 ExifTool ----
$exifDest = Join-Path $stage 'tools\exiftool'
New-Item -ItemType Directory -Path $exifDest -Force | Out-Null
Copy-Item -Path (Join-Path $ExifToolSource '*') -Destination $exifDest -Recurse -Force

# ---- 清理不该进包的东西 ----
foreach ($junk in @('config.ps1', '.cache', '.logs', '重复', '认不出格式', 'dist', 'tests', '.git')) {
    $p = Join-Path $stage $junk
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Name -match '\.(tmp|cache)$' } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ---- 压缩 ----
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$sizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
"$hash  $pkgName.zip" | Set-Content -LiteralPath (Join-Path $distRoot 'SHA256.txt') -Encoding ASCII

Write-Host ''
Write-Host ("完成：" + $zipPath) -ForegroundColor Green
Write-Host ("大小：{0} MB" -f $sizeMB)
Write-Host ("SHA256：" + $hash)
Write-Host ''
Write-Host '上传到 GitHub Releases：Release tag 用 v' -NoNewline
Write-Host $Version -NoNewline
Write-Host '，把 dist\ 里的 zip 和 SHA256.txt 一起传上去。'
