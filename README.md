# Lossly

**Lossly** is a native macOS app for lossy PNG compression. It uses a perceptual quantization pipeline to dramatically reduce PNG file sizes with minimal visible quality loss.

In loving memory of [ImageAlpha](https://pngmini.com) by Kornel Lesiński — the original inspiration for this project.

![Lossly Screenshot](docs/screenshot.png)

## Features

- **Auto mode** — single quality slider; pngquant finds the minimum palette automatically
- **Manual mode** — full control over colors, speed, posterize, dithering, and lossless DEFLATE repack
- **Two-stage pipeline** — pngquant (lossy) → oxipng (lossless DEFLATE repack)
- **Live preview** — zoom, pan, and toggle between original and optimized
- **Multiple backgrounds** — checkerboard, solid colors, and texture patterns to visualize transparency
- **Smart export** — saves with source filename suffix (e.g. `logo-optimized.png`)
- **Native macOS** — built with SwiftUI, NavigationSplitView, NSScrollView, macOS 14+

## How it Works

1. **pngquant** reduces the image to an 8-bit palette using variance-minimization + K-means Voronoi iteration in premultiplied alpha color space
2. **oxipng** losslessly repacks the DEFLATE stream for additional 10–20% savings
3. Typical results: **60–80% file size reduction** with no visible quality difference

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (arm64) — Intel universal build coming soon

## Installation

> **Note**: Lossly is not yet notarized with Apple. If macOS says "app is damaged", run:
> ```bash
> xattr -cr /Applications/Lossly.app
> ```
> This safely removes the quarantine flag added when downloading from the internet.



### Download (Recommended)
Download the latest release from the [Releases page](../../releases).

**Note on Gatekeeper:** If macOS blocks the app on first launch, run this command to allow it:
```bash
xattr -cr Lossly.app
```
Then try opening it again.

### Build from Source
```bash
git clone https://github.com/yourusername/lossly.git
cd lossly

# Install xcodegen if needed
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Open in Xcode
open Lossly.xcodeproj
```

Then build and run with **⌘R**.

## Bundled Tools

All CLI tools are statically linked and bundled inside the app — no Homebrew or external dependencies required.

| Tool | Version | Purpose |
|------|---------|---------|
| [pngquant](https://pngquant.org) | 3.0.4 | Lossy palette quantization |
| [oxipng](https://github.com/shssoichiro/oxipng) | 10.x | Lossless DEFLATE repack |

## Building CLI Tools from Source

```bash
# pngquant (requires Rust)
bash build-tools.sh
```

See `build-tools.sh` for the full build script.

## License

MIT License — see [LICENSE](LICENSE)

## Credits

- [pngquant](https://pngquant.org) by Kornel Lesiński
- [libimagequant](https://github.com/ImageOptim/libimagequant) by Kornel Lesiński
- [oxipng](https://github.com/shssoichiro/oxipng) by Joshua Holmer
