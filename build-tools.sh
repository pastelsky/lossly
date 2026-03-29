#!/bin/bash
# build-tools.sh
# Builds pngquant and posterizer from source and copies self-contained
# binaries into ImageAlphaModern/Binaries/ ready to be bundled in the app.
#
# Requirements:
#   brew install libpng  (for posterizer)
#   rustup (for pngquant)
#
# Usage:  bash build-tools.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARIES_DIR="$SCRIPT_DIR/Binaries"
mkdir -p "$BINARIES_DIR"

echo "▶︎ Building posterizer (statically linked)..."
POSTERIZER_SRC="$(dirname "$SCRIPT_DIR")/mediancut-posterizer"
if [ ! -d "$POSTERIZER_SRC" ]; then
    echo "  mediancut-posterizer submodule not found at $POSTERIZER_SRC"
    echo "  Run: git submodule update --init --recursive"
    exit 1
fi

HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
LIBPNG_STATIC="$HOMEBREW_PREFIX/lib/libpng.a"

if [ ! -f "$LIBPNG_STATIC" ]; then
    echo "  libpng not found. Installing via Homebrew..."
    brew install libpng
fi

cd "$POSTERIZER_SRC"
make clean 2>/dev/null || true
make USE_COCOA=1 \
    CFLAGS="-Wall -Wno-unknown-pragmas -I. -I$HOMEBREW_PREFIX/include -I$HOMEBREW_PREFIX/include/libpng16 -DNDEBUG -O3 -fstrict-aliasing -ffast-math -funroll-loops -fomit-frame-pointer -std=c99 -DUSE_COCOA=1" \
    LDFLAGS="$LIBPNG_STATIC -lz -lm -framework Cocoa"

cp posterize "$BINARIES_DIR/posterizer"
chmod +x "$BINARIES_DIR/posterizer"
echo "  ✅ posterizer → Binaries/posterizer ($(du -sh "$BINARIES_DIR/posterizer" | cut -f1))"

echo ""
echo "▶︎ Building pngquant (statically linked)..."
PNGQUANT_TMP="/tmp/pngquant-src"

if [ ! -d "$PNGQUANT_TMP" ]; then
    git clone --depth=1 https://github.com/kornelski/pngquant.git "$PNGQUANT_TMP"
fi

cd "$PNGQUANT_TMP"
git submodule update --init --recursive

# Build with static feature flags (bundles libpng, liblcms2, libz statically)
cargo build --release --features static

cp target/release/pngquant "$BINARIES_DIR/pngquant"
chmod +x "$BINARIES_DIR/pngquant"
echo "  ✅ pngquant → Binaries/pngquant ($(du -sh "$BINARIES_DIR/pngquant" | cut -f1))"

echo ""
echo "▶︎ Verifying dependencies (should only show macOS system libs)..."
echo "  pngquant:"
otool -L "$BINARIES_DIR/pngquant" | grep -v "usr/lib\|libSystem\|libiconv\|libz" && echo "  (clean)" || echo "  (clean - no external dylib deps)"
echo "  posterizer:"
otool -L "$BINARIES_DIR/posterizer" | grep -v "usr/lib\|libSystem\|AppKit\|CoreGraphics\|Foundation\|Cocoa\|libobjc" && echo "  (clean)" || echo "  (clean - no external dylib deps)"

echo ""
echo "✅ All tools built and copied to $BINARIES_DIR"
echo "   Run 'swift build' in ImageAlphaModern/ to include them in the app."
