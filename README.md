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

This repository uses a PowerShell script ([`scripts/Generate-Manifests.ps1`](./scripts/Generate-Manifests.ps1)) to:

1. Fetch font metadata from the Google Fonts GitHub repository
2. Download font files and calculate their hashes
3. Generate Scoop manifest files with proper installation scripts
4. Automatically register fonts in Windows registry

A GitHub Action workflow runs weekly to keep fonts up to date.

## Contributing

To add or update fonts, you can:

1. **Automatic**: Wait for the weekly automated update
2. **Manual**: Run the generation script locally:
   ```pwsh
   # Generate manifests for all fonts
   .\scripts\Generate-Manifests.ps1

   # Generate manifests for specific fonts only
   .\scripts\Generate-Manifests.ps1 -FontFilter "roboto"
   ```
3. **GitHub Actions**: Manually trigger the [Update Manifests workflow](./.github/workflows/update-manifests.yml)

## License

The scripts and manifests in this repository are available under the [Unlicense](LICENSE).

Individual fonts are licensed under their respective licenses (typically OFL-1.1). See each font's manifest for specific license information.
