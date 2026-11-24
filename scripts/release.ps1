<#
.SYNOPSIS
    Local firmware release packager & Git tag helper for Ethane-XVI-CH549.
.DESCRIPTION
    1. Verifies version consistency in User/main.c (single source of truth).
    2. Runs a clean full rebuild via scripts/build.ps1 (with hardware boundary checks).
    3. Stages versioned firmware artifacts, SHA256SUMS.txt, and RELEASE_NOTES.md in dist/vX.Y.Z.W/.
    4. Optionally creates and pushes an annotated Git tag vX.Y.Z.W.
.EXAMPLE
    .\scripts\release.ps1
    .\scripts\release.ps1 -Tag
    .\scripts\release.ps1 -Tag -Push
#>
[CmdletBinding()]
param(
    [switch]$Tag,
    [switch]$Push,
    [switch]$AllowDirty,
    [string]$Uv4Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Push) { $Tag = $true }

$repoRoot  = Split-Path -Parent $PSScriptRoot
$mainCPath = Join-Path $repoRoot 'User\main.c'
$buildPs1  = Join-Path $PSScriptRoot 'build.ps1'

# 1. Validate version consistency in User/main.c
$mainContent = Get-Content -LiteralPath $mainCPath -Raw
$mVer = [regex]::Match($mainContent, 'FIRMWARE_VERSION\[4\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')
if (-not $mVer.Success) {
    throw "Unable to parse FIRMWARE_VERSION[4] from $mainCPath"
}
$fwVersion = "$($mVer.Groups[1].Value).$($mVer.Groups[2].Value).$($mVer.Groups[3].Value).$($mVer.Groups[4].Value)"
$tagName   = "v$fwVersion"

$mHeader = [regex]::Match($mainContent, '\*\s*Version\s*:\s*V([0-9.]+)')
if ($mHeader.Success -and $mHeader.Groups[1].Value -ne $fwVersion) {
    throw "Version mismatch in User/main.c: header says V$($mHeader.Groups[1].Value), FIRMWARE_VERSION says V$fwVersion."
}

# 2. Check Git state
Push-Location $repoRoot
try {
    $gitStatus = @(git status --porcelain)
    $isDirty   = ($gitStatus.Count -gt 0)
    $commitSha = (git rev-parse --short HEAD).Trim()
    $branch    = (git rev-parse --abbrev-ref HEAD).Trim()

    if ($isDirty) {
        if ($Tag -and -not $AllowDirty) {
            throw "Working tree has uncommitted changes. Commit your changes before tagging, or pass -AllowDirty."
        }
        Write-Warning "Working tree has uncommitted changes; packaging current local tree."
    }

    if ($Tag) {
        $existingTag = git tag -l $tagName
        if ($existingTag) {
            throw "Git tag '$tagName' already exists. Bump FIRMWARE_VERSION in User/main.c first."
        }
    }

    # 3. Clean full rebuild
    $buildArgs = @{ Rebuild = $true; Clean = $true }
    if ($Uv4Path) { $buildArgs['Uv4Path'] = $Uv4Path }
    $buildResult = & $buildPs1 @buildArgs

    # 4. Stage release artifacts in dist/vX.Y.Z.W/
    $distDir    = Join-Path $repoRoot "dist\$tagName"
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null

    $hexFileName = "Ethane-XVI-CH549-$tagName.hex"
    $destHexPath = Join-Path $distDir $hexFileName
    Copy-Item -LiteralPath $buildResult.HexPath -Destination $destHexPath -Force

    $checksumPath = Join-Path $distDir 'SHA256SUMS.txt'
    "$($buildResult.Sha256)  $hexFileName" | Set-Content -LiteralPath $checksumPath -Encoding ASCII

    $buildDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $dirtyNote = if ($isDirty) { ' (dirty working tree)' } else { '' }
    $notesPath = Join-Path $distDir 'RELEASE_NOTES.md'
    $notes = @"
# Ethane-XVI-CH549 $tagName

- **Version**: V$fwVersion
- **Git Commit**: ``$commitSha`` on ``$branch``$dirtyNote
- **Build Date**: $buildDate
- **Target MCU**: WCH CH549 (Keil C51)

## Firmware Artifact

| File | Size | SHA-256 |
| --- | ---: | --- |
| ``$hexFileName`` | $($buildResult.HexSize) bytes | ``$($buildResult.Sha256)`` |

## Resource Usage

| Region | Used | Limit | Remaining |
| --- | ---: | ---: | ---: |
| CODE + CONST | $($buildResult.CodeUsed + $buildResult.ConstUsed) B (max ``0x$($buildResult.MaxCodeEnd.ToString('X4'))``) | 55,296 B (``0xD800``) | $($buildResult.CodeFree) B |
| XDATA (total) | $($buildResult.XdataUsed) B | 2,048 B (``0x0800``) | $($buildResult.XdataTotalFree) B (gap before EP0: $($buildResult.XdataGapBeforeEp0) B) |
| DATA | $($buildResult.DataUsed) B | 128 B | $([math]::Round(128 - $buildResult.DataUsed, 1)) B |

## Flashing (WCHISPTool)

1. Put the Ethane-XVI keyboard into ISP Bootloader mode (via host software ``BBOT`` command or hardware boot pin).
2. Open **WCHISPTool**, select **CH549** -> **USB Download**.
3. Load ``$hexFileName`` and flash.
"@
    $notes | Set-Content -LiteralPath $notesPath -Encoding UTF8

    # 5. Optional Git tag & push
    if ($Tag) {
        git tag -a $tagName -m "Release $tagName"
        Write-Host "Created Git tag: $tagName" -ForegroundColor Green
        if ($Push) {
            git push origin HEAD
            git push origin $tagName
            Write-Host "Pushed branch '$branch' and tag '$tagName' to origin." -ForegroundColor Green
        }
    }

    Write-Host "`n=== Release Package Ready ===" -ForegroundColor Cyan
    Write-Host "Directory : $distDir"
    Write-Host "Artifacts : $hexFileName, SHA256SUMS.txt, RELEASE_NOTES.md"
    Write-Host "Next step : Create a GitHub Release for '$tagName' and upload the files in $distDir"
}
finally {
    Pop-Location
}
