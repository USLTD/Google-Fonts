# Google Fonts Scoop Bucket

[![Tests](https://github.com/USLTD/Google-Fonts/actions/workflows/ci.yml/badge.svg)](https://github.com/USLTD/Google-Fonts/actions/workflows/ci.yml)
[![Update Manifests](https://github.com/USLTD/Google-Fonts/actions/workflows/update-manifests.yml/badge.svg)](https://github.com/USLTD/Google-Fonts/actions/workflows/update-manifests.yml)

A [Scoop](https://scoop.sh) bucket for installing Google Fonts on Windows.

This bucket automatically tracks fonts from the official [Google Fonts repository](https://github.com/google/fonts) and generates Scoop manifests for easy installation.

## Features

- **500+ Font Families**: Access to all open-source fonts from Google Fonts
- **Automatic Updates**: Manifests are automatically generated and updated weekly
- **Easy Installation**: Install any Google Font with a single command
- **Automatic Font Registration**: Fonts are automatically registered in Windows

## Installation

First, add this bucket to your Scoop installation:

```pwsh
scoop bucket add google-fonts https://github.com/USLTD/Google-Fonts
```

Then install any font:

```pwsh
scoop install google-fonts/roboto
scoop install google-fonts/opensans
scoop install google-fonts/montserrat
```

## Available Fonts

Browse available fonts in the [bucket directory](./bucket) or on the [Google Fonts website](https://fonts.google.com/).

## How It Works

This repository uses an optimized PowerShell script ([`scripts/Generate-Manifests.ps1`](./scripts/Generate-Manifests.ps1)) to:

1. Fetch font metadata from the Google Fonts GitHub repository
2. Use **incremental updates** to only process fonts that have changed
3. **Cache API responses** to minimize GitHub API calls (24-hour cache)
4. Download font files and calculate their SHA256 hashes
5. Generate Scoop manifests with proper font names from metadata (not directory names)
6. Automatically register fonts in Windows registry

### Font Naming

The script uses the **actual font name** from the Google Fonts metadata (e.g., "Roboto Mono") rather than the directory name (e.g., "robotomono"). This ensures font names match exactly what you see on Google Fonts.

### Resource Efficiency

To minimize the burden on GitHub's infrastructure, the script implements:

- **Incremental updates**: Only processes fonts that have been updated since last run
- **API response caching**: Caches responses for 24 hours to avoid redundant API calls
- **Rate limiting**: Monitors API usage and slows down when approaching limits
- **Batch processing**: Workflow defaults to processing 100 fonts per run
- **Smart detection**: Checks commit dates to skip unchanged fonts

The weekly automated workflow runs in incremental mode, typically updating only 5-15 fonts per run, making minimal API calls (typically 10-30 per run vs 1000+ for full regeneration).

A GitHub Action workflow runs weekly to keep fonts up to date.

## Contributing

To add or update fonts, you can:

1. **Automatic**: Wait for the weekly automated update (incremental mode - updates only changed fonts)
2. **Manual**: Run the generation script locally:
   ```pwsh
   # Incremental update (only changed fonts) - default
   .\scripts\Generate-Manifests.ps1

   # Force regenerate all fonts
   .\scripts\Generate-Manifests.ps1 -FullRegeneration

   # Generate manifests for specific fonts only
   .\scripts\Generate-Manifests.ps1 -FontFilter "roboto"

   # Process first 50 fonts only
   .\scripts\Generate-Manifests.ps1 -MaxFonts 50
   ```
3. **GitHub Actions**: Manually trigger the [Update Manifests workflow](./.github/workflows/update-manifests.yml) with custom parameters

## License

The scripts and manifests in this repository are available under the [Unlicense](LICENSE).

Individual fonts are licensed under their respective licenses (typically OFL-1.1). See each font's manifest for specific license information.
