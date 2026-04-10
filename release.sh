#!/usr/bin/env bash
# release.sh — one-command release pipeline for Marc's Social Loader.
#
# What it does:
#   1. Bumps the version in Resources/Info.plist
#   2. Runs ./build.sh to produce dist/Marc's Social Loader.app
#   3. Packages the .app into a zip with `ditto` (preserves signatures)
#   4. Creates a git tag and pushes it
#   5. Creates a GitHub Release via `gh` and uploads the zip as an asset
#   6. Signs the zip with Sparkle's `sign_update`
#   7. Inserts a new <item> into docs/appcast.xml
#   8. Commits the version bump + appcast change and pushes to main
#
# Usage:
#   ./release.sh 1.1.0
#   ./release.sh 1.1.0 --notes "Added dark mode icons, fixed ffmpeg path bug"
#   ./release.sh 1.1.0 --notes-file CHANGELOG-1.1.0.md
#
# Requirements (one-time install):
#   brew install gh               # GitHub CLI
#   gh auth login                 # sign in
#   # Sparkle tools (sign_update) on PATH — see README.md
#
set -euo pipefail

cd "$(dirname "$0")"

# ----- Argument parsing -----------------------------------------------------

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [--notes \"…\"] [--notes-file path.md]"
  echo "Example: $0 1.1.0 --notes \"Added dark mode icons\""
  exit 1
fi

VERSION="$1"
shift

NOTES=""
NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes)      NOTES="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -n "$NOTES_FILE" ]; then
  if [ ! -f "$NOTES_FILE" ]; then
    echo "Notes file not found: $NOTES_FILE"
    exit 1
  fi
  NOTES=$(cat "$NOTES_FILE")
fi

# Basic semver check (allow trailing -beta etc.)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 1.0 or 1.2.3 (optionally 1.2.3-beta1)"
  exit 1
fi

# ----- Tool checks ----------------------------------------------------------

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1"
    [ -n "${2-}" ] && echo "  → $2"
    exit 1
  fi
}

need gh          "Install with: brew install gh && gh auth login"
need sign_update "Install Sparkle tools: https://github.com/sparkle-project/Sparkle/releases (put sign_update on your PATH)"
need create-dmg  "Install with: brew install create-dmg"
need ditto
need /usr/libexec/PlistBuddy

# gh authenticated?
if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is not authenticated. Run: gh auth login"
  exit 1
fi

# Working tree clean?
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes. Commit or stash them first:"
  git status --short
  exit 1
fi

# Derive GitHub user/repo from origin remote
REMOTE_URL=$(git remote get-url origin)
REPO_SLUG=$(echo "$REMOTE_URL" \
  | sed -E 's#^(git@github\.com:|https://github\.com/)##' \
  | sed -E 's#\.git$##')
if [ -z "$REPO_SLUG" ] || ! echo "$REPO_SLUG" | grep -q "/"; then
  echo "Couldn't parse GitHub user/repo from origin URL: $REMOTE_URL"
  exit 1
fi
echo "→ Repo: $REPO_SLUG"

# ----- Version bump ---------------------------------------------------------

PLIST="Resources/Info.plist"
PB="/usr/libexec/PlistBuddy"
CURRENT_BUILD=$("$PB" -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "→ Bumping Info.plist: $VERSION (build $NEW_BUILD)"
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
"$PB" -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

# ----- Build ----------------------------------------------------------------

echo "→ Building app…"
./build.sh >/dev/null

APP_DIR="dist/Marc's Social Loader.app"
if [ ! -d "$APP_DIR" ]; then
  echo "Build did not produce $APP_DIR"
  exit 1
fi

# ----- Package --------------------------------------------------------------

ZIP_NAME="Marcs-Social-Loader-${VERSION}.zip"
ZIP_PATH="dist/${ZIP_NAME}"
echo "→ Packaging ${ZIP_NAME}…"
(
  cd dist
  rm -f "$ZIP_NAME"
  ditto -c -k --sequesterRsrc --keepParent \
    "Marc's Social Loader.app" "$ZIP_NAME"
)
ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
echo "  size: $(( ZIP_SIZE / 1024 / 1024 )) MB"

# ----- DMG installer --------------------------------------------------------
# Build a polished drag-to-Applications DMG for first-time installs.
# Sparkle keeps using the .zip for in-place updates (faster, no mount).

DMG_NAME="Marcs-Social-Loader-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"
echo "→ Building ${DMG_NAME}…"
(
  cd dist
  rm -f "$DMG_NAME"
  create-dmg \
    --volname "Marc's Social Loader" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "Marc's Social Loader.app" 175 190 \
    --hide-extension "Marc's Social Loader.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    "$DMG_NAME" \
    "Marc's Social Loader.app" >/dev/null
)
DMG_SIZE=$(stat -f%z "$DMG_PATH")
echo "  size: $(( DMG_SIZE / 1024 / 1024 )) MB"

# ----- Sign with Sparkle ----------------------------------------------------

echo "→ Signing zip with Sparkle EdDSA key…"
# sign_update prints something like:
#   sparkle:edSignature="xxxx" length="12345"
SIGN_OUTPUT=$(sign_update "$ZIP_PATH")
EDSIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ -z "$EDSIG" ] || [ -z "$LENGTH" ]; then
  echo "sign_update did not return a signature. Output was:"
  echo "$SIGN_OUTPUT"
  exit 1
fi

# ----- Git tag + commit -----------------------------------------------------

echo "→ Committing version bump…"
git add "$PLIST"
git commit -m "Release $VERSION"

TAG="v$VERSION"
git tag -a "$TAG" -m "Release $VERSION"
git push origin main
git push origin "$TAG"

# ----- GitHub release -------------------------------------------------------

echo "→ Creating GitHub release $TAG…"
if [ -n "$NOTES" ]; then
  printf '%s' "$NOTES" | gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" \
    --title "$VERSION" --notes-file -
else
  gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" \
    --title "$VERSION" --generate-notes
fi

DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/${ZIP_NAME}"
FEED_URL="https://$(echo "$REPO_SLUG" | cut -d/ -f1).github.io/$(echo "$REPO_SLUG" | cut -d/ -f2)/appcast.xml"

# ----- Update docs/appcast.xml ---------------------------------------------

mkdir -p docs
APPCAST="docs/appcast.xml"

if [ ! -f "$APPCAST" ]; then
  echo "→ Creating fresh $APPCAST"
  cat > "$APPCAST" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Marc's Social Loader</title>
        <link>$FEED_URL</link>
        <description>Updates for Marc's Social Loader</description>
        <language>en</language>
        <!-- RELEASES -->
    </channel>
</rss>
XML
fi

# Build the new <item> block
PUBDATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
# Escape notes for XML/CDATA — CDATA already handles most things, but make
# sure we don't accidentally close the CDATA section.
ESCAPED_NOTES=$(printf '%s' "${NOTES:-Version $VERSION}" | sed 's|\]\]>|]]]]><![CDATA[>|g')

NEW_ITEM=$(cat <<XML
        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[$ESCAPED_NOTES]]></description>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$NEW_BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                sparkle:version="$NEW_BUILD"
                sparkle:shortVersionString="$VERSION"
                length="$LENGTH"
                type="application/octet-stream"
                sparkle:edSignature="$EDSIG" />
        </item>
        <!-- RELEASES -->
XML
)

# Insert the new <item> at the <!-- RELEASES --> marker, making it the
# newest entry. Sparkle picks the highest sparkle:version automatically,
# order in the file is mostly for humans.
python3 - <<PY
import re, pathlib
p = pathlib.Path("$APPCAST")
text = p.read_text()
new_item = """$NEW_ITEM"""
text = text.replace("<!-- RELEASES -->", new_item, 1)
p.write_text(text)
PY

echo "→ Committing appcast update…"
git add "$APPCAST"
git commit -m "Appcast: add $VERSION"
git push origin main

# ----- Done -----------------------------------------------------------------

cat <<EOF

✓ Release $VERSION published

  Download: $DOWNLOAD_URL
  Appcast:  $FEED_URL

Users on older versions will see the update within 24 hours, or immediately
when they click "Nach Updates suchen…" in the menu.

EOF
