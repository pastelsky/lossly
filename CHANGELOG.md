# Changelog

All notable changes to Lossly will be documented here.

This project uses [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` → minor version bump
- `fix:` / `chore:` / `refactor:` → patch version bump
- `BREAKING CHANGE` in footer → major version bump

## [Unreleased]

### Added
- Auto mode with single quality slider (pngquant perceptual quantization)
- Manual mode with colors, speed, posterize, dithering, and lossless DEFLATE controls
- Two-stage compression pipeline: pngquant → oxipng
- Zoomable image canvas with pinch-to-zoom, pan, and zoom buttons
- Multiple background styles: checkerboard, solid colors, textures
- Smart export with source filename suffix (e.g. `logo-optimized.png`)
- Settings window with Auto/Light/Dark (Vibrant) theme switcher
- Bundled CLI tools: pngquant 3.0.4, oxipng 10.x (statically linked, no dependencies)
- CI/CD pipeline with automatic version bumping and GitHub Releases
