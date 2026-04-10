#!/usr/bin/env bash
# Build a release binary and wrap it into a minimal .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Marc's Social Loader"
BUNDLE_ID="local.marc.videodownloader"
BINARY="VideoDownloader"
BUILD_DIR=".build/release"
OUT_DIR="dist"
APP_DIR="$OUT_DIR/${APP_NAME}.app"

echo "→ Compiling release binary…"
swift build -c release

if [ ! -x "$BUILD_DIR/$BINARY" ]; then
  echo "Build failed: $BUILD_DIR/$BINARY not found"
  exit 1
fi

# ----- Icon handling --------------------------------------------------------
# Source icons live in "Icon Exports/". iOS icons are exported edge-to-edge
# (1024x1024 full-bleed) — but macOS icons use a specific template with
# ~100 px of transparent padding on each side, so the visible content area
# is 824x824 centered. Without the padding the icon looks ~25% larger than
# every other icon in the Dock.
#
# We pad the source PNGs to the macOS template first, then build the .icns
# and copy the padded variants into the bundle for the runtime Dock swap.

ICON_DIR="Icon Exports"
ICON_DEFAULT_SRC="$ICON_DIR/Icon-iOS-Default-1024x1024@1x.png"
ICON_DARK_SRC="$ICON_DIR/Icon-iOS-Dark-1024x1024@1x.png"
ICON_OUT="Resources/AppIcon.icns"

# Pad a 1024x1024 PNG to the macOS icon template (content inset to 824x824).
# Usage: pad_icon <input.png> <output.png>
pad_icon() {
  swift - "$1" "$2" <<'SWIFT_EOF'
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { exit(1) }
guard let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("Failed to load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let canvasSize: CGFloat = 1024
let contentSize: CGFloat = 824
let inset = (canvasSize - contentSize) / 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize),
    pixelsHigh: Int(canvasSize),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: canvasSize, height: canvasSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()
let targetRect = NSRect(x: inset, y: inset, width: contentSize, height: contentSize)
src.draw(in: targetRect,
         from: .zero,
         operation: .sourceOver,
         fraction: 1.0,
         respectFlipped: true,
         hints: [.interpolation: NSImageInterpolation.high])
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
SWIFT_EOF
}

# Build padded PNGs for both appearance variants (always regenerate — the
# step is fast and ensures the bundle is consistent with the sources).
PADDED_DEFAULT="Resources/.AppIcon-Default-padded.png"
PADDED_DARK="Resources/.AppIcon-Dark-padded.png"
if [ -f "$ICON_DEFAULT_SRC" ]; then
  echo "→ Padding Default icon to macOS template…"
  pad_icon "$ICON_DEFAULT_SRC" "$PADDED_DEFAULT"
fi
if [ -f "$ICON_DARK_SRC" ]; then
  echo "→ Padding Dark icon to macOS template…"
  pad_icon "$ICON_DARK_SRC" "$PADDED_DARK"
fi

# Build .icns from the padded Default icon.
if [ -f "$PADDED_DEFAULT" ]; then
  echo "→ Building AppIcon.icns…"
  ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16     "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_16x16.png"       >/dev/null
  sips -z 32 32     "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_16x16@2x.png"    >/dev/null
  sips -z 32 32     "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_32x32.png"       >/dev/null
  sips -z 64 64     "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_32x32@2x.png"    >/dev/null
  sips -z 128 128   "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_128x128.png"     >/dev/null
  sips -z 256 256   "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_128x128@2x.png"  >/dev/null
  sips -z 256 256   "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_256x256.png"     >/dev/null
  sips -z 512 512   "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_256x256@2x.png"  >/dev/null
  sips -z 512 512   "$PADDED_DEFAULT" --out "$ICONSET_DIR/icon_512x512.png"     >/dev/null
  cp                "$PADDED_DEFAULT"        "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUT"
  rm -rf "$(dirname "$ICONSET_DIR")"
fi

# ----- Dependency binaries --------------------------------------------------
# Ship yt-dlp and ffmpeg inside the bundle so users don't need Homebrew.
# Both are cached in Resources/bin/ so repeated builds don't re-download.

BIN_CACHE="Resources/bin"
mkdir -p "$BIN_CACHE"

# yt-dlp: official universal2 macOS binary from GitHub releases.
YTDLP_CACHE="$BIN_CACHE/yt-dlp"
if [ ! -f "$YTDLP_CACHE" ]; then
  echo "→ Downloading yt-dlp standalone binary…"
  curl -fL --progress-bar \
    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" \
    -o "$YTDLP_CACHE"
  chmod +x "$YTDLP_CACHE"
fi

# ffmpeg: static arm64 build from evermeet.cx.
FFMPEG_CACHE="$BIN_CACHE/ffmpeg"
if [ ! -f "$FFMPEG_CACHE" ]; then
  echo "→ Downloading ffmpeg static binary…"
  TMP=$(mktemp -d)
  curl -fL --progress-bar \
    "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" \
    -o "$TMP/ffmpeg.zip"
  unzip -q "$TMP/ffmpeg.zip" -d "$TMP"
  mv "$TMP/ffmpeg" "$FFMPEG_CACHE"
  chmod +x "$FFMPEG_CACHE"
  rm -rf "$TMP"
fi

# ----- Bundle assembly ------------------------------------------------------

echo "→ Assembling .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$BINARY" "$APP_DIR/Contents/MacOS/$BINARY"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Copy Sparkle.framework into Contents/Frameworks. SwiftPM drops the
# framework next to the binary during `swift build`; at runtime macOS
# expects it under Contents/Frameworks for a proper .app bundle.
SPARKLE_FW="$BUILD_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  mkdir -p "$APP_DIR/Contents/Frameworks"
  rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  # Tell the main binary where to look for frameworks inside the .app.
  # SwiftPM's default rpath is @executable_path/ (i.e. Contents/MacOS/),
  # but inside a real .app bundle frameworks live in Contents/Frameworks.
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_DIR/Contents/MacOS/$BINARY" 2>/dev/null || true
fi

if [ -f "$ICON_OUT" ]; then
  cp "$ICON_OUT" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# Copy the padded per-appearance PNGs so IconController can runtime-swap
# the Dock icon at the correct macOS template size.
if [ -f "$PADDED_DEFAULT" ]; then
  cp "$PADDED_DEFAULT" "$APP_DIR/Contents/Resources/AppIcon-Light.png"
fi
if [ -f "$PADDED_DARK" ]; then
  cp "$PADDED_DARK" "$APP_DIR/Contents/Resources/AppIcon-Dark.png"
fi

# Copy the bundled yt-dlp / ffmpeg binaries into the app's Resources/bin/.
mkdir -p "$APP_DIR/Contents/Resources/bin"
cp "$YTDLP_CACHE"  "$APP_DIR/Contents/Resources/bin/yt-dlp"
cp "$FFMPEG_CACHE" "$APP_DIR/Contents/Resources/bin/ffmpeg"
chmod +x "$APP_DIR/Contents/Resources/bin/yt-dlp"
chmod +x "$APP_DIR/Contents/Resources/bin/ffmpeg"

# Strip extended attributes from the whole bundle. iCloud Drive (where
# this project lives) sprinkles xattrs on files, and codesign refuses to
# sign anything carrying "resource fork, Finder information, or similar
# detritus". xattr -cr recursively clears them.
xattr -cr "$APP_DIR" 2>/dev/null || true

# Ad-hoc sign the whole bundle recursively. --deep walks every nested
# framework / XPC service / helper app and signs each with the same
# ad-hoc identity, so Sparkle's update helpers can launch correctly
# at runtime. (--deep is "deprecated" for real distribution builds
# but still the simplest reliable option for ad-hoc dev signing.)
codesign --force --deep --sign - --timestamp=none "$APP_DIR" 2>/dev/null || true

# Touch the bundle so the Finder / Dock pick up the new icon immediately
# instead of showing the cached generic one.
touch "$APP_DIR"

echo "✓ Built $APP_DIR"
echo
echo "Start per Doppelklick im Finder, oder:"
echo "  open \"$APP_DIR\""
