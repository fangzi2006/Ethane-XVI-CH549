<#
.SYNOPSIS
    Headless Keil C51 build script for Ethane-XVI-CH549 with hardware memory-boundary checks
    and automatic versioned output to dist/vX.Y.Z.W/.
.EXAMPLE
    .\scripts\build.ps1
    .\scripts\build.ps1 -Rebuild -Clean
    .\scripts\build.ps1 -NoDist
#>
[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$Clean,
    [switch]$AllowWarnings,
    [switch]$NoDist,
    [string]$Uv4Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Hardware & firmware memory boundaries (see User/Alkane/ALK_Def.h & User/BasicIO.h)
$CODE_LIMIT       = 0xD800  # DATA_DIAG_BASE (55,296 B usable CodeFlash before diag/config area)
$XRAM_LIMIT       = 0x0800  # CH549 on-chip XRAM = 2048 B (0x0000..0x07FF)
$XRAM_EP0_BASE    = 0x0440  # XBASE_EP0_BUF = XBASE_FLASH_BUF(1536) - 64*7 = 1088 (0x0440)
$DATA_WARN_LIMIT  = 112     # Safe DATA usage ceiling inside 128B direct RAM (256B IDATA total)

$repoRoot   = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $repoRoot 'Project'
$uvprojPath = Join-Path $projectDir 'Ethane-XVI.uvproj'
$outputDir  = Join-Path $projectDir 'Output'
$listDir    = Join-Path $projectDir 'Listings'
$hexPath    = Join-Path $outputDir 'Ethane-XVI.hex'
$mapPath    = Join-Path $listDir 'Ethane-XVI.map'
$logPath    = Join-Path $outputDir 'build.log'
$mainCPath  = Join-Path $repoRoot 'User\main.c'

function Find-Uv4 {
    param([string]$ExplicitPath)
    $candidates = @()
    if ($ExplicitPath) { $candidates += $ExplicitPath }
    if ($env:KEIL_UV4) { $candidates += $env:KEIL_UV4 }
    $candidates += @(
        'D:\Keil\UV4\UV4.exe',
        'C:\Keil_v5\UV4\UV4.exe',
        'C:\Keil\UV4\UV4.exe',
        'D:\Keil_v5\UV4\UV4.exe'
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    throw "Keil UV4.exe not found. Install Keil C51 or pass -Uv4Path / set `$env:KEIL_UV4."
}

function Get-FirmwareVersion {
    param([string]$FilePath)
    $content = Get-Content -LiteralPath $FilePath -Raw
    $m = [regex]::Match($content, 'FIRMWARE_VERSION\[4\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')
    if (-not $m.Success) {
        throw "Unable to parse FIRMWARE_VERSION[4] from $FilePath"
    }
    return "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value).$($m.Groups[4].Value)"
}

$uv4 = Find-Uv4 -ExplicitPath $Uv4Path
$fwVersion = Get-FirmwareVersion -FilePath $mainCPath

Write-Host "=== Ethane-XVI-CH549 Build ===" -ForegroundColor Cyan
Write-Host "Firmware Version : V$fwVersion"
Write-Host "Keil UV4         : $uv4"
Write-Host "Mode             : $(if ($Rebuild) { 'Rebuild (-r)' } else { 'Incremental (-b)' })"

if ($Clean) {
    Write-Host "Cleaning Output and Listings..."
    if (Test-Path $outputDir) { Get-ChildItem -LiteralPath $outputDir -Force | Remove-Item -Recurse -Force }
    if (Test-Path $listDir)   { Get-ChildItem -LiteralPath $listDir   -Force | Remove-Item -Recurse -Force }
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
New-Item -ItemType Directory -Path $listDir   -Force | Out-Null
if (Test-Path $logPath) { Remove-Item -LiteralPath $logPath -Force }

$buildFlag = if ($Rebuild) { '-r' } else { '-b' }
$uv4Args = @($buildFlag, "`"$uvprojPath`"", '-t', 'ETH', '-j0', '-o', "`"$logPath`"")

$proc = Start-Process -FilePath $uv4 -ArgumentList $uv4Args -Wait -PassThru -NoNewWindow
$exitCode = $proc.ExitCode

if (Test-Path $logPath) {
    Write-Host "`n--- Keil Build Output ---" -ForegroundColor DarkGray
    Get-Content -LiteralPath $logPath | ForEach-Object { Write-Host $_ }
    Write-Host "-------------------------`n" -ForegroundColor DarkGray
}

# UV4 exit codes: 0 = OK, 1 = Warnings only, 2 = Errors, 3 = Fatal error
if ($exitCode -ge 2) {
    throw "Keil build failed with exit code $exitCode."
}
if ($exitCode -eq 1 -and -not $AllowWarnings) {
    throw "Keil build finished with warnings (exit code 1). Fix warnings or pass -AllowWarnings."
}

if (-not (Test-Path -LiteralPath $hexPath)) {
    throw "Expected HEX artifact not found: $hexPath"
}
if (-not (Test-Path -LiteralPath $mapPath)) {
    throw "Expected MAP file not found: $mapPath"
}

# Parse Program Size & memory boundaries from Ethane-XVI.map
$mapLines = Get-Content -LiteralPath $mapPath
$sizeLine = ($mapLines | Select-String -Pattern 'Program Size:\s*data=([0-9.]+)\s+xdata=(\d+)\s+const=(\d+)\s+code=(\d+)' | Select-Object -Last 1)
if (-not $sizeLine) {
    throw "Failed to parse 'Program Size' from $mapPath"
}

$dataUsed  = [double]$sizeLine.Matches[0].Groups[1].Value
$xdataUsed = [int]$sizeLine.Matches[0].Groups[2].Value
$constUsed = [int]$sizeLine.Matches[0].Groups[3].Value
$codeUsed  = [int]$sizeLine.Matches[0].Groups[4].Value

# Scan exact segment end addresses for CODE/CONST and XDATA
$maxCodeEnd = 0
$maxXdataEnd = 0
$maxLinkerXdataEnd = 0
$inXdata = $false

foreach ($line in $mapLines) {
    if ($line -match 'X D A T A\s+M E M O R Y') { $inXdata = $true; continue }
    if ($line -match 'R E M O V E D\s+S E G M E N T S|S Y M B O L\s+T A B L E') { $inXdata = $false; continue }

    if (-not $inXdata) {
        if ($line -match '^\s*([0-9A-F]{6})H\s+([0-9A-F]{6})H\s+([0-9A-F]{6})H\s+\S+\s+\S+\s+(CODE|CONST)\s+') {
            $stopAddr = [Convert]::ToInt32($Matches[2], 16)
            if ($stopAddr -gt $maxCodeEnd) { $maxCodeEnd = $stopAddr }
        }
    } else {
        if ($line -match '^\s*([0-9A-F]{6})H\s+([0-9A-F]{6})H\s+([0-9A-F]{6})H\s+\S+\s+(\S+)\s+XDATA\s+(\S+)') {
            $startAddr = [Convert]::ToInt32($Matches[1], 16)
            $stopAddr  = [Convert]::ToInt32($Matches[2], 16)
            $reloc     = $Matches[4]
            if ($stopAddr -gt $maxXdataEnd) { $maxXdataEnd = $stopAddr }
            # Relocatable linker-placed XDATA (UNIT) must stay below XBASE_EP0_BUF (0x0440)
            if ($reloc -eq 'UNIT' -and $startAddr -lt $XRAM_EP0_BASE) {
                if ($stopAddr -gt $maxLinkerXdataEnd) { $maxLinkerXdataEnd = $stopAddr }
            }
        }
    }
}

$codeEndExclusive = $maxCodeEnd + 1
$codeFree         = $CODE_LIMIT - $codeEndExclusive
$xdataFreeBeforeEp0 = $XRAM_EP0_BASE - ($maxLinkerXdataEnd + 1)
$xdataTotalFree   = $XRAM_LIMIT - $xdataUsed
$hexInfo          = Get-Item -LiteralPath $hexPath
$hexHash          = (Get-FileHash -LiteralPath $hexPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "=== Hardware Resource Report ===" -ForegroundColor Cyan
Write-Host ("CODE+CONST : {0,6} B (max 0x{1:X4} / limit 0x{2:X4}, free {3} B)" -f ($codeUsed + $constUsed), $maxCodeEnd, ($CODE_LIMIT - 1), $codeFree)
Write-Host ("XDATA      : {0,6} B / {1} B (linker max 0x{2:X4} / EP0 base 0x{3:X4}, gap {4} B)" -f $xdataUsed, $XRAM_LIMIT, $maxLinkerXdataEnd, $XRAM_EP0_BASE, $xdataFreeBeforeEp0)
Write-Host ("DATA       : {0,6:N1} B / 128 B" -f $dataUsed)
Write-Host ("HEX Output : {0} ({1} bytes)" -f $hexPath, $hexInfo.Length)
Write-Host ("SHA-256    : {0}" -f $hexHash)

# Enforce hard hardware boundaries
$errors = @()
if ($codeEndExclusive -gt $CODE_LIMIT) {
    $errors += ("CODE+CONST overflow! Max address 0x{0:X4} collides with DATA_DIAG_BASE (0x{1:X4})." -f $maxCodeEnd, $CODE_LIMIT)
}
if ($maxXdataEnd -ge $XRAM_LIMIT) {
    $errors += ("XDATA overflow! Max address 0x{0:X4} exceeds CH549 2KB XRAM limit (0x07FF)." -f $maxXdataEnd)
}
if (($maxLinkerXdataEnd + 1) -gt $XRAM_EP0_BASE) {
    $errors += ("Linker XDATA overflow! Max address 0x{0:X4} overlaps USB EP0 buffer at 0x{1:X4}." -f $maxLinkerXdataEnd, $XRAM_EP0_BASE)
}
if ($dataUsed -gt $DATA_WARN_LIMIT) {
    Write-Warning ("DATA usage ({0:N1} B) exceeds safe threshold ({1} B); check stack headroom." -f $dataUsed, $DATA_WARN_LIMIT)
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Error $e }
    throw "Hardware memory-boundary verification failed!"
}

Write-Host "`nBuild & boundary checks PASSED." -ForegroundColor Green

$tagName     = "v$fwVersion"
$distDir     = Join-Path $repoRoot "dist\$tagName"
$hexFileName = "Ethane-XVI-CH549-$tagName.hex"
$distHexPath = Join-Path $distDir $hexFileName

if (-not $NoDist) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    Copy-Item -LiteralPath $hexPath -Destination $distHexPath -Force
    $checksumPath = Join-Path $distDir 'SHA256SUMS.txt'
    "$hexHash  $hexFileName" | Set-Content -LiteralPath $checksumPath -Encoding ASCII
    Write-Host "Dist Output: $distHexPath" -ForegroundColor Cyan
}

[PSCustomObject]@{
    Version            = $fwVersion
    TagName            = $tagName
    HexPath            = $hexPath
    DistDir            = $distDir
    DistHexPath        = $distHexPath
    HexFileName        = $hexFileName
    HexSize            = $hexInfo.Length
    Sha256             = $hexHash
    DataUsed           = $dataUsed
    XdataUsed          = $xdataUsed
    XdataGapBeforeEp0  = $xdataFreeBeforeEp0
    XdataTotalFree     = $xdataTotalFree
    CodeUsed           = $codeUsed
    ConstUsed          = $constUsed
    MaxCodeEnd         = $maxCodeEnd
    CodeFree           = $codeFree
}
