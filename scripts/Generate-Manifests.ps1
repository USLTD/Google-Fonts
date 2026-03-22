#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates Scoop manifests for Google Fonts.

.DESCRIPTION
    This script fetches font metadata from the Google Fonts GitHub repository
    and generates Scoop manifest files for each font family. It supports
    incremental updates to minimize API calls and resource usage.

.PARAMETER OutputPath
    The directory where manifest files will be generated. Defaults to ../bucket

.PARAMETER FontFilter
    Optional filter to generate manifests for specific fonts only.

.PARAMETER FullRegeneration
    Force regeneration of all fonts, ignoring incremental updates. Default: $false

.PARAMETER MaxFonts
    Maximum number of fonts to process (0 = all). Default: 0

.PARAMETER CacheDir
    Directory for caching API responses. Default: .cache

.EXAMPLE
    .\Generate-Manifests.ps1
    Generates manifests for all Google Fonts (incremental mode)

.EXAMPLE
    .\Generate-Manifests.ps1 -FontFilter "roboto" -FullRegeneration
    Force regenerates manifest for Roboto font family

.EXAMPLE
    .\Generate-Manifests.ps1 -MaxFonts 50
    Process only first 50 fonts incrementally
#>

param(
    [string]$OutputPath = "$PSScriptRoot/../bucket",
    [string]$FontFilter = "",
    [switch]$FullRegeneration,
    [int]$MaxFonts = 0,
    [string]$CacheDir = "$PSScriptRoot/../.cache"
)

$ErrorActionPreference = 'Stop'

# Incremental update is enabled by default unless -FullRegeneration is specified
$IncrementalUpdate = -not $FullRegeneration

# GitHub API base URL for Google Fonts repository
$GitHubAPI = "https://api.github.com/repos/google/fonts"
$RawContentBase = "https://raw.githubusercontent.com/google/fonts/main"

# Rate limiting configuration
$script:APICallCount = 0
$script:APICallLimit = 60  # GitHub API rate limit per hour for unauthenticated requests
$script:LastAPICallTime = Get-Date

function Write-Progress-Status {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host $Message -ForegroundColor $Color
}

function Ensure-CacheDirectory {
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        Write-Progress-Status "Created cache directory: $CacheDir" -Color Yellow
    }
}

function Get-CachedAPIResponse {
    param(
        [string]$Url,
        [int]$CacheHours = 24
    )

    $cacheFile = Join-Path $CacheDir ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Url)) + ".json")

    if (Test-Path $cacheFile) {
        $cacheInfo = Get-Item $cacheFile
        if ((Get-Date) -lt $cacheInfo.LastWriteTime.AddHours($CacheHours)) {
            Write-Verbose "Using cached response for: $Url"
            return Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
    }

    # Rate limiting
    $script:APICallCount++
    if ($script:APICallCount -gt ($script:APICallLimit - 10)) {
        Write-Warning "Approaching API rate limit. Slowing down..."
        Start-Sleep -Seconds 2
    }

    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get
        $response | ConvertTo-Json -Depth 10 | Set-Content $cacheFile
        return $response
    }
    catch {
        if (Test-Path $cacheFile) {
            Write-Warning "API call failed, using stale cache: $_"
            return Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
        throw
    }
}

function Get-GoogleFonts {
    <#
    .SYNOPSIS
    Fetches list of font directories from Google Fonts repository
    #>
    Write-Progress-Status "Fetching font list from Google Fonts repository..."

    try {
        # Fetch list of fonts from the OFL directory
        $response = Get-CachedAPIResponse -Url "$GitHubAPI/contents/ofl"
        $fonts = $response | Where-Object { $_.type -eq "dir" }

        Write-Progress-Status "Found $($fonts.Count) fonts in OFL directory" -Color Green
        return $fonts
    }
    catch {
        Write-Error "Failed to fetch font list: $_"
        exit 1
    }
}

function Get-FontLastCommitDate {
    param([string]$FontName)

    $url = "$GitHubAPI/commits?path=ofl/$FontName&per_page=1"
    try {
        $commit = Get-CachedAPIResponse -Url $url -CacheHours 1
        if ($commit -and $commit.Count -gt 0) {
            return [DateTime]$commit[0].commit.author.date
        }
    }
    catch {
        Write-Verbose "Could not get commit date for $FontName"
    }
    return $null
}

function Test-ManifestNeedsUpdate {
    param(
        [string]$FontName,
        [string]$OutputPath
    )

    $manifestPath = Join-Path $OutputPath "$FontName.json"

    if (-not (Test-Path $manifestPath)) {
        return $true
    }

    # Check if font has been updated since manifest was created
    $manifestDate = (Get-Item $manifestPath).LastWriteTime
    $lastCommitDate = Get-FontLastCommitDate -FontName $FontName

    if ($lastCommitDate -and $lastCommitDate -gt $manifestDate) {
        Write-Verbose "Font $FontName has updates since manifest was created"
        return $true
    }

    return $false
}

function Get-FontMetadata {
    <#
    .SYNOPSIS
    Fetches and parses METADATA.pb file for a font
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FontName
    )

    $metadataUrl = "$RawContentBase/ofl/$FontName/METADATA.pb"

    try {
        # Use cache for metadata (24 hour cache)
        $cacheFile = Join-Path $CacheDir "metadata_$FontName.txt"
        if ((Test-Path $cacheFile) -and ((Get-Item $cacheFile).LastWriteTime -gt (Get-Date).AddHours(-24))) {
            $content = Get-Content $cacheFile -Raw
        }
        else {
            $content = Invoke-RestMethod -Uri $metadataUrl -Method Get
            $content | Set-Content $cacheFile
        }
        return $content
    }
    catch {
        Write-Warning "Could not fetch metadata for $FontName`: $_"
        return $null
    }
}

function ConvertTo-ScoopManifest {
    <#
    .SYNOPSIS
    Converts font metadata to Scoop manifest format
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FontName,

        [Parameter(Mandatory = $true)]
        [string]$Metadata
    )

    # Parse basic info from metadata - use actual font name from metadata
    $name = if ($Metadata -match 'name:\s*"([^"]+)"') { $Matches[1] } else { $FontName }
    $designer = if ($Metadata -match 'designer:\s*"([^"]+)"') { $Matches[1] } else { "Unknown" }
    $license = if ($Metadata -match 'license:\s*"([^"]+)"') { $Matches[1] } else { "OFL-1.1" }
    $category = if ($Metadata -match 'category:\s*"([^"]+)"') { $Matches[1] } else { "SANS_SERIF" }

    # Get all font files with their metadata
    $fontFiles = @()
    $pattern = 'fonts\s*\{[^}]+filename:\s*"([^"]+\.ttf)"[^}]+\}'
    $matches = [regex]::Matches($Metadata, $pattern)
    foreach ($match in $matches) {
        $fontFiles += $match.Groups[1].Value
    }

    if ($fontFiles.Count -eq 0) {
        Write-Warning "No font files found for $FontName"
        return $null
    }

    # Build URL list
    $urls = @()
    foreach ($file in $fontFiles) {
        $urls += "$RawContentBase/ofl/$FontName/$file"
    }

    # Normalize font name for homepage (remove spaces, handle special chars)
    $homePageName = $name -replace ' ', '+'

    # Create manifest object
    $manifest = [ordered]@{
        version      = "latest"
        description  = "$name font family designed by $designer"
        homepage     = "https://fonts.google.com/specimen/$homePageName"
        license      = $license
        url          = $urls
        hash         = @()
        installer    = @{
            script = @(
                'if ($global) {',
                '    $fontInstallDir = "$env:windir\Fonts"',
                '    $registryRoot = "HKLM"',
                '} else {',
                '    $fontInstallDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"',
                '    $registryRoot = "HKCU"',
                '    if (-not (Test-Path $fontInstallDir)) {',
                '        New-Item -ItemType Directory -Path $fontInstallDir -Force | Out-Null',
                '        # Set ACL permissions for user font directory',
                '        $acl = Get-Acl $fontInstallDir',
                '        $acl.SetAccessRuleProtection($false, $true)',
                '        # Add permissions for All Application Packages',
                '        $rule1 = New-Object System.Security.AccessControl.FileSystemAccessRule("S-1-15-2-1", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")',
                '        $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule("S-1-15-2-2", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")',
                '        $acl.AddAccessRule($rule1)',
                '        $acl.AddAccessRule($rule2)',
                '        Set-Acl -Path $fontInstallDir -AclObject $acl',
                '    }',
                '}',
                '$registryKey = "${registryRoot}:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"',
                '$fontFiles = Get-ChildItem "$dir" -Filter "*.ttf"',
                'foreach ($file in $fontFiles) {',
                '    $fontName = $file.Name.Replace($file.Extension, " (TrueType)")',
                '    if ($global) {',
                '        $fontValue = $file.Name',
                '    } else {',
                '        $fontValue = "$fontInstallDir\$($file.Name)"',
                '    }',
                '    try {',
                '        New-ItemProperty -Path $registryKey -Name $fontName -Value $fontValue -Force -ErrorAction Stop | Out-Null',
                '        Copy-Item $file.FullName -Destination "$fontInstallDir\$($file.Name)" -Force -ErrorAction Stop',
                '        Write-Host "Installed: $($file.Name)" -ForegroundColor Green',
                '    } catch {',
                '        Write-Host "Failed to install $($file.Name): $_" -ForegroundColor Red',
                '        throw',
                '    }',
                '}'
            )
        }
        uninstaller  = @{
            script = @(
                "if (`$global) {",
                "    `$fontInstallDir = `"`$env:windir\Fonts`"",
                "    `$registryRoot = `"HKLM`"",
                "} else {",
                "    `$fontInstallDir = `"`$env:LOCALAPPDATA\Microsoft\Windows\Fonts`"",
                "    `$registryRoot = `"HKCU`"",
                "}",
                "`$registryKey = `"`${registryRoot}:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`"",
                "`$fontFiles = @(" + (($fontFiles | ForEach-Object { "`"$_`"" }) -join ', ') + ")",
                "",
                "# Pre-uninstall: Check if any font files are locked",
                "`$lockedFonts = @()",
                "foreach (`$file in `$fontFiles) {",
                "    `$fontPath = Join-Path `$fontInstallDir `$file",
                "    if (Test-Path `$fontPath) {",
                "        try {",
                "            # Test if file is locked by attempting to rename it",
                "            `$testPath = `$fontPath + '.test'",
                "            Rename-Item -Path `$fontPath -NewName `$testPath -ErrorAction Stop",
                "            Rename-Item -Path `$testPath -NewName `$fontPath -ErrorAction Stop",
                "        } catch {",
                "            `$lockedFonts += `$file",
                "        }",
                "    }",
                "}",
                "",
                "if (`$lockedFonts.Count -gt 0) {",
                "    Write-Host `"`" -ForegroundColor Red",
                "    Write-Host `"ERROR: Cannot uninstall fonts - some files are currently in use:`" -ForegroundColor Red",
                "    foreach (`$font in `$lockedFonts) {",
                "        Write-Host `"  - `$font`" -ForegroundColor Yellow",
                "    }",
                "    Write-Host `"`" -ForegroundColor Red",
                "    Write-Host `"REASON: The fonts are currently being used by one or more applications.`" -ForegroundColor Red",
                "    Write-Host `"SOLUTION: Please close all applications that may be using these fonts`" -ForegroundColor Cyan",
                "    Write-Host `"          (e.g., text editors, IDEs, Office applications, design tools)`" -ForegroundColor Cyan",
                "    Write-Host `"          and try again.`" -ForegroundColor Cyan",
                "    Write-Host `"`" -ForegroundColor Red",
                "    exit 1",
                "}",
                "",
                "# Perform uninstallation",
                "`$failedRemovals = @()",
                "foreach (`$file in `$fontFiles) {",
                "    `$fontName = [System.IO.Path]::GetFileNameWithoutExtension(`$file) + `" (TrueType)`"",
                "    `$fontPath = Join-Path `$fontInstallDir `$file",
                "    ",
                "    # Remove registry entry",
                "    try {",
                "        Remove-ItemProperty -Path `$registryKey -Name `$fontName -ErrorAction Stop",
                "        Write-Host `"Removed registry entry: `$fontName`" -ForegroundColor Gray",
                "    } catch {",
                "        if (`$_.Exception.Message -notlike '*does not exist*') {",
                "            Write-Host `"Warning: Could not remove registry entry for `$fontName: `$(`$_.Exception.Message)`" -ForegroundColor Yellow",
                "            `$failedRemovals += `$file",
                "        }",
                "    }",
                "    ",
                "    # Remove font file",
                "    try {",
                "        if (Test-Path `$fontPath) {",
                "            Remove-Item `$fontPath -Force -ErrorAction Stop",
                "            Write-Host `"Removed font file: `$file`" -ForegroundColor Gray",
                "        }",
                "    } catch {",
                "        Write-Host `"Warning: Could not remove font file `$file: `$(`$_.Exception.Message)`" -ForegroundColor Yellow",
                "        `$failedRemovals += `$file",
                "    }",
                "}",
                "",
                "if (`$failedRemovals.Count -gt 0) {",
                "    Write-Host `"`" -ForegroundColor Yellow",
                "    Write-Host `"Some fonts could not be fully removed. You may need to restart your computer.`" -ForegroundColor Yellow",
                "} else {",
                "    Write-Host `"`" -ForegroundColor Green",
                "    Write-Host `"Fonts uninstalled successfully.`" -ForegroundColor Green",
                "    Write-Host `"Note: A computer restart may be required for all applications to reflect the changes.`" -ForegroundColor Cyan",
                "}"
            )
        }
        checkver     = @{
            url   = "$GitHubAPI/commits?path=ofl/$FontName&per_page=1"
            regex = '"sha":\s*"([a-f0-9]{7})'
        }
        autoupdate   = @{
            url = $urls
        }
    }

    # Calculate hashes for all URLs
    Write-Host "  Calculating hashes for $($urls.Count) files..." -ForegroundColor Gray
    foreach ($url in $urls) {
        try {
            $tempFile = New-TemporaryFile
            Invoke-WebRequest -Uri $url -OutFile $tempFile -ErrorAction Stop
            $hash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
            $manifest.hash += $hash
            Remove-Item $tempFile -Force
        }
        catch {
            Write-Warning "  Could not download/hash $url`: $_"
            return $null
        }
    }

    return $manifest
}

function Save-Manifest {
    <#
    .SYNOPSIS
    Saves manifest to JSON file
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FontName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    # Use directory name for manifest filename (lowercase, consistent)
    $manifestPath = Join-Path $OutputPath "$FontName.json"
    $json = $Manifest | ConvertTo-Json -Depth 10 -Compress:$false
    Set-Content -Path $manifestPath -Value $json -Encoding UTF8
    Write-Host "  Created: $manifestPath" -ForegroundColor Green
}

# Main script
Write-Host "`n=== Google Fonts Manifest Generator ===" -ForegroundColor Cyan
Write-Host "Output directory: $OutputPath" -ForegroundColor Cyan
Write-Host "Incremental mode: $IncrementalUpdate" -ForegroundColor Cyan
if ($MaxFonts -gt 0) {
    Write-Host "Max fonts to process: $MaxFonts" -ForegroundColor Cyan
}
Write-Host ""

# Ensure directories exist
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Progress-Status "Created output directory: $OutputPath" -Color Yellow
}

Ensure-CacheDirectory

# Get list of fonts
$fonts = Get-GoogleFonts

# Filter fonts if specified
if ($FontFilter) {
    $fonts = $fonts | Where-Object { $_.name -like "*$FontFilter*" }
    Write-Progress-Status "Filtered to $($fonts.Count) fonts matching '$FontFilter'" -Color Yellow
}

# Limit number of fonts if specified
if ($MaxFonts -gt 0 -and $fonts.Count -gt $MaxFonts) {
    $fonts = $fonts | Select-Object -First $MaxFonts
    Write-Progress-Status "Limited to first $MaxFonts fonts" -Color Yellow
}

# Generate manifests
$successCount = 0
$skipCount = 0
$failCount = 0
$unchangedCount = 0

foreach ($font in $fonts) {
    $fontName = $font.name
    Write-Host "`nProcessing: $fontName" -ForegroundColor Cyan

    # Check if update is needed (incremental mode)
    if ($IncrementalUpdate -and -not (Test-ManifestNeedsUpdate -FontName $fontName -OutputPath $OutputPath)) {
        Write-Host "  Skipping (no changes detected)" -ForegroundColor Gray
        $unchangedCount++
        continue
    }

    # Get font metadata
    $metadata = Get-FontMetadata -FontName $fontName
    if (-not $metadata) {
        Write-Warning "Skipping $fontName - no metadata found"
        $skipCount++
        continue
    }

    # Convert to Scoop manifest
    $manifest = ConvertTo-ScoopManifest -FontName $fontName -Metadata $metadata
    if (-not $manifest) {
        Write-Warning "Failed to generate manifest for $fontName"
        $failCount++
        continue
    }

    # Save manifest
    Save-Manifest -FontName $fontName -Manifest $manifest -OutputPath $OutputPath
    $successCount++
}

# Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Successfully generated: $successCount manifests" -ForegroundColor Green
if ($IncrementalUpdate) {
    Write-Host "Unchanged (skipped): $unchangedCount fonts" -ForegroundColor Gray
}
Write-Host "Skipped: $skipCount fonts" -ForegroundColor Yellow
Write-Host "Failed: $failCount fonts" -ForegroundColor Red
Write-Host "API calls made: $script:APICallCount" -ForegroundColor Cyan
Write-Host "`nDone!" -ForegroundColor Cyan
