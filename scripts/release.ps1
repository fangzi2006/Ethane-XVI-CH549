<#
.SYNOPSIS
    Local firmware release packager & Git tag helper for Ethane-XVI-CH549 with strict version uniqueness checks.
.DESCRIPTION
    1. Resolves target version from -Version, -Bump (major|minor|patch|build), or current User/main.c.
    2. Enforces version uniqueness & monotonicity against local Git tags, remote origin tags, and dist/.
    3. If -Version or -Bump is specified, updates User/main.c (FIRMWARE_VERSION, header Version & Date).
    4. Runs a clean full rebuild via scripts/build.ps1 (with hardware boundary checks).
    5. Stages versioned firmware artifacts, SHA256SUMS.txt, and RELEASE_NOTES.md in dist/vX.Y.Z.W/.
    6. Optionally commits the version bump (when bumped) and creates/pushes an annotated Git tag vX.Y.Z.W.
.EXAMPLE
    .\scripts\release.ps1
    .\scripts\release.ps1 -Bump build
    .\scripts\release.ps1 -Version 1.7.2.0 -Tag -Push
#>
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('major', 'minor', 'patch', 'build')]
    [string]$Bump,
    [switch]$Tag,
    [switch]$Push,
    [switch]$AllowDirty,
    [switch]$Force,
    [switch]$SkipRemoteCheck,
    [string]$Uv4Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Push) { $Tag = $true }
if ($Version -and $Bump) {
    throw "Specify either -Version or -Bump, not both."
}

$repoRoot  = Split-Path -Parent $PSScriptRoot
$mainCPath = Join-Path $repoRoot 'User\main.c'
$buildPs1  = Join-Path $PSScriptRoot 'build.ps1'

function Parse-Version4 {
    param([string]$Text)
    $clean = $Text.Trim().TrimStart('v', 'V')
    $m = [regex]::Match($clean, '^(\d+)\.(\d+)\.(\d+)\.(\d+)$')
    if (-not $m.Success) {
        throw "Invalid version '$Text'. Expected 4-part format A.B.C.D (each 0..255)."
    }
    $parts = @(
        [int]$m.Groups[1].Value,
        [int]$m.Groups[2].Value,
        [int]$m.Groups[3].Value,
        [int]$m.Groups[4].Value
    )
    foreach ($p in $parts) {
        if ($p -lt 0 -or $p -gt 255) {
            throw "Version segment '$p' in '$clean' out of range (UINT8C requires 0..255)."
        }
    }
    return [PSCustomObject]@{
        Major = $parts[0]
        Minor = $parts[1]
        Patch = $parts[2]
        Build = $parts[3]
        Text  = "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
        Obj   = [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
    }
}

# 1. Read current version from User/main.c
$mainContent = Get-Content -LiteralPath $mainCPath -Raw
$mVer = [regex]::Match($mainContent, 'FIRMWARE_VERSION\[4\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')
if (-not $mVer.Success) {
    throw "Unable to parse FIRMWARE_VERSION[4] from $mainCPath"
}
$currentVer = Parse-Version4 "$($mVer.Groups[1].Value).$($mVer.Groups[2].Value).$($mVer.Groups[3].Value).$($mVer.Groups[4].Value)"

# Determine target version
$targetVer = $currentVer
$needsBumpWrite = $false
if ($Version) {
    $targetVer = Parse-Version4 $Version
    $needsBumpWrite = ($targetVer.Text -ne $currentVer.Text)
} elseif ($Bump) {
    switch ($Bump) {
        'major' { $targetVer = Parse-Version4 "$($currentVer.Major + 1).0.0.0" }
        'minor' { $targetVer = Parse-Version4 "$($currentVer.Major).$($currentVer.Minor + 1).0.0" }
        'patch' { $targetVer = Parse-Version4 "$($currentVer.Major).$($currentVer.Minor).$($currentVer.Patch + 1).0" }
        'build' { $targetVer = Parse-Version4 "$($currentVer.Major).$($currentVer.Minor).$($currentVer.Patch).$($currentVer.Build + 1)" }
    }
    $needsBumpWrite = $true
} else {
    $mHeader = [regex]::Match($mainContent, '\*\s*Version\s*:\s*V([0-9.]+)')
    if ($mHeader.Success -and $mHeader.Groups[1].Value -ne $currentVer.Text) {
        throw "Version mismatch in User/main.c: header says V$($mHeader.Groups[1].Value), FIRMWARE_VERSION says V$($currentVer.Text)."
    }
}

$fwVersion = $targetVer.Text
$tagName   = "v$fwVersion"
$distDir   = Join-Path $repoRoot "dist\$tagName"

Push-Location $repoRoot
try {
    # 2. Enforce strict version uniqueness & monotonicity across local tags, remote tags, and dist/
    $allTags = @()
    $localTags = @(git tag -l 'v*' | Where-Object { $_ -and $_.Trim() -ne '' })
    $allTags += $localTags

    if (-not $SkipRemoteCheck) {
        try {
            $remoteLines = @(git ls-remote --tags --refs origin 'refs/tags/v*' 2>$null)
            foreach ($line in $remoteLines) {
                if ($line -match 'refs/tags/(v\S+)$') {
                    $allTags += $Matches[1]
                }
            }
        } catch {
            Write-Warning "Could not query remote tags on 'origin' (offline?). Checking local tags only."
        }
    }

    $allTags = @($allTags | Sort-Object -Unique)

    if ($allTags -contains $tagName) {
        throw "Version '$tagName' already exists in Git tags! Version numbers must be unique. Use -Bump build|patch|minor|major or -Version X.Y.Z.W."
    }

    $maxExisting = $null
    foreach ($t in $allTags) {
        if ($t -match '^v(\d+\.\d+\.\d+\.\d+)$') {
            $parsed = Parse-Version4 $Matches[1]
            if (-not $maxExisting -or $parsed.Obj -gt $maxExisting.Obj) {
                $maxExisting = $parsed
            }
        }
    }
    if ($maxExisting -and $targetVer.Obj -le $maxExisting.Obj) {
        throw "Target version V$fwVersion must be strictly greater than latest released tag v$($maxExisting.Text). Use -Bump or a higher -Version."
    }

    $releaseNotesMarker = Join-Path $distDir 'RELEASE_NOTES.md'
    if ((Test-Path -LiteralPath $releaseNotesMarker) -and -not $Force) {
        throw "Release package already exists: $distDir. Bump the version to keep releases unique, or pass -Force to overwrite an untagged local package."
    }

    # 3. Check Git working tree before modifying User/main.c
    $gitStatus = @(git status --porcelain)
    $isDirty   = ($gitStatus.Count -gt 0)
    if ($isDirty) {
        if ($Tag -and -not $AllowDirty) {
            throw "Working tree has uncommitted changes. Commit your changes before tagging, or pass -AllowDirty."
        }
        Write-Warning "Working tree has uncommitted changes; packaging current local tree."
    }

    # 4. Update User/main.c if -Version or -Bump changed the version
    if ($needsBumpWrite) {
        $today = Get-Date -Format 'yyyy/MM/dd'
        $updated = $mainContent
        $updated = [regex]::Replace(
            $updated,
            '(\*\s*Version\s*:\s*V)[0-9.]+',
            "`${1}$fwVersion",
            1
        )
        $updated = [regex]::Replace(
            $updated,
            '(\*\s*Date\s*:\s*)[0-9/]+',
            "`${1}$today",
            1
        )
        $updated = [regex]::Replace(
            $updated,
            'FIRMWARE_VERSION\[4\]\s*=\s*\{\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\}',
            "FIRMWARE_VERSION[4] = {$($targetVer.Major),$($targetVer.Minor),$($targetVer.Patch),$($targetVer.Build)}",
            1
        )
        [System.IO.File]::WriteAllText($mainCPath, $updated, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Updated User/main.c version: V$($currentVer.Text) -> V$fwVersion" -ForegroundColor Yellow

        if ($Tag -and -not $isDirty) {
            git add User/main.c
            git commit -m "Bump firmware version to V$fwVersion"
        } else {
            $isDirty = $true
        }
    }

    $commitSha = (git rev-parse --short HEAD).Trim()
    $branch    = (git rev-parse --abbrev-ref HEAD).Trim()

    # 5. Clean full rebuild
    $buildArgs = @{ Rebuild = $true; Clean = $true }
    if ($Uv4Path) { $buildArgs['Uv4Path'] = $Uv4Path }
    $buildResult = & $buildPs1 @buildArgs

    # 6. Stage release artifacts in dist/vX.Y.Z.W/
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

    # 7. Optional Git tag & push
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
