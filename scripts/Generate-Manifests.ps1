#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates Scoop manifests for Google Fonts.

.DESCRIPTION
    This script fetches font metadata from the Google Fonts GitHub repository
    and generates Scoop manifest files for each font family.

.PARAMETER OutputPath
    The directory where manifest files will be generated. Defaults to ../bucket

.PARAMETER FontFilter
    Optional filter to generate manifests for specific fonts only.

.EXAMPLE
    .\Generate-Manifests.ps1
    Generates manifests for all Google Fonts

.EXAMPLE
    .\Generate-Manifests.ps1 -FontFilter "roboto"
    Generates manifest for Roboto font only
#>

param(
    [string]$OutputPath = "$PSScriptRoot/../bucket",
    [string]$FontFilter = ""
)

$ErrorActionPreference = 'Stop'

# GitHub API base URL for Google Fonts repository
$GitHubAPI = "https://api.github.com/repos/google/fonts"
$RawContentBase = "https://raw.githubusercontent.com/google/fonts/main"

function Get-GoogleFonts {
    <#
    .SYNOPSIS
    Fetches list of font directories from Google Fonts repository
    #>
    Write-Host "Fetching font list from Google Fonts repository..." -ForegroundColor Cyan

    try {
        # Fetch list of fonts from the OFL directory
        $response = Invoke-RestMethod -Uri "$GitHubAPI/contents/ofl" -Method Get
        $fonts = $response | Where-Object { $_.type -eq "dir" }

        Write-Host "Found $($fonts.Count) fonts in OFL directory" -ForegroundColor Green
        return $fonts
    }
    catch {
        Write-Error "Failed to fetch font list: $_"
        exit 1
    }
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
        $content = Invoke-RestMethod -Uri $metadataUrl -Method Get
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

    # Parse basic info from metadata
    $name = if ($Metadata -match 'name:\s*"([^"]+)"') { $Matches[1] } else { $FontName }
    $designer = if ($Metadata -match 'designer:\s*"([^"]+)"') { $Matches[1] } else { "Unknown" }
    $license = if ($Metadata -match 'license:\s*"([^"]+)"') { $Matches[1] } else { "OFL-1.1" }
    $category = if ($Metadata -match 'category:\s*"([^"]+)"') { $Matches[1] } else { "SANS_SERIF" }

    # Get all font files
    $fontFiles = @()
    $pattern = 'filename:\s*"([^"]+\.ttf)"'
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

    # Create manifest object
    $manifest = [ordered]@{
        version      = "latest"
        description  = "$name font family designed by $designer"
        homepage     = "https://fonts.google.com/specimen/$($name -replace ' ', '+')"
        license      = $license
        url          = $urls
        hash         = @()
        installer    = @{
            script = @(
                '$fontFiles = Get-ChildItem "$dir" -Filter "*.ttf"',
                'foreach ($file in $fontFiles) {',
                '    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $file.Name.Replace($file.Extension, " (TrueType)") -Value $file.Name -Force | Out-Null',
                '    Copy-Item $file.FullName -Destination "$env:windir\Fonts" -Force',
                '}'
            )
        }
        uninstaller  = @{
            script = @(
                "`$fontFiles = @(" + (($fontFiles | ForEach-Object { "`"$_`"" }) -join ', ') + ")",
                "foreach (`$file in `$fontFiles) {",
                "    `$fontName = [System.IO.Path]::GetFileNameWithoutExtension(`$file)",
                "    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Name `"`$fontName (TrueType)`" -ErrorAction SilentlyContinue",
                "    Remove-Item `"`$env:windir\Fonts\`$file`" -Force -ErrorAction SilentlyContinue",
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

    $manifestPath = Join-Path $OutputPath "$FontName.json"
    $json = $Manifest | ConvertTo-Json -Depth 10 -Compress:$false
    Set-Content -Path $manifestPath -Value $json -Encoding UTF8
    Write-Host "  Created: $manifestPath" -ForegroundColor Green
}

# Main script
Write-Host "`n=== Google Fonts Manifest Generator ===" -ForegroundColor Cyan
Write-Host "Output directory: $OutputPath`n" -ForegroundColor Cyan

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "Created output directory: $OutputPath" -ForegroundColor Yellow
}

# Get list of fonts
$fonts = Get-GoogleFonts

# Filter fonts if specified
if ($FontFilter) {
    $fonts = $fonts | Where-Object { $_.name -like "*$FontFilter*" }
    Write-Host "Filtered to $($fonts.Count) fonts matching '$FontFilter'" -ForegroundColor Yellow
}

# Generate manifests
$successCount = 0
$skipCount = 0
$failCount = 0

foreach ($font in $fonts) {
    $fontName = $font.name
    Write-Host "`nProcessing: $fontName" -ForegroundColor Cyan

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
Write-Host "Skipped: $skipCount fonts" -ForegroundColor Yellow
Write-Host "Failed: $failCount fonts" -ForegroundColor Red
Write-Host "`nDone!" -ForegroundColor Cyan
