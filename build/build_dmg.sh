#!/bin/bash
# ==============================================================================
# build_dmg.sh  —  SourceStream macOS DMG Builder
# Run from the project root: bash build/build_dmg.sh
# Output: dist/SourceStream-1.0.dmg
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="SourceStream"
APP_BUNDLE="$APP_NAME.app"
VERSION="1.0.0"
DMG_NAME="$APP_NAME-$VERSION"
DIST_DIR="$PROJECT_DIR/dist"
STAGE_DIR="$DIST_DIR/stage"
APP_SRC="$PROJECT_DIR/$APP_BUNDLE"
DMG_OUT="$DIST_DIR/$DMG_NAME.dmg"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚡ SourceStream DMG Builder  v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1 ── Pre-flight checks ────────────────────────────────────────────────────────
echo ""
echo "🔍 Pre-flight checks..."
[ ! -d "$APP_SRC" ] && { echo "❌ App bundle not found: $APP_SRC"; exit 1; }
python3 -m py_compile "$APP_SRC/Contents/Resources/server.py" && echo "   ✅ server.py syntax OK"
bash -n "$APP_SRC/Contents/Resources/backup_engine.sh" && echo "   ✅ backup_engine.sh syntax OK"

# 2 ── Set permissions ──────────────────────────────────────────────────────────
echo ""
echo "🔑 Setting executable permissions..."
chmod +x "$APP_SRC/Contents/MacOS/$APP_NAME"
chmod +x "$APP_SRC/Contents/Resources/backup_engine.sh"
chmod +x "$APP_SRC/Contents/Resources/server.py"
echo "   ✅ Done"

# 3 ── Stage directory ─────────────────────────────────────────────────────────
echo ""
echo "📦 Staging..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$DIST_DIR"

# Copy app bundle
cp -r "$APP_SRC" "$STAGE_DIR/$APP_BUNDLE"

# Add /Applications symlink for drag-install UX
ln -s /Applications "$STAGE_DIR/Applications"

# Add uninstaller
cp "$PROJECT_DIR/build/Uninstall SourceStream.sh" "$STAGE_DIR/" 2>/dev/null || true

echo "   ✅ Staged to $STAGE_DIR"

# 4 ── Create DMG ──────────────────────────────────────────────────────────────
echo ""
echo "💿 Building DMG..."
rm -f "$DMG_OUT"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -o "$DMG_OUT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ DMG built: $DMG_OUT"
echo "   Size: $(du -sh "$DMG_OUT" | cut -f1)"
echo ""
echo "   To distribute: share $DMG_NAME.dmg"
echo "   To install:    Open DMG → drag SourceStream.app to Applications"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

