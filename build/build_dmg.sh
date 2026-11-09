#!/bin/bash
# ==============================================================================
# build_dmg.sh  —  SourceStream macOS DMG Builder
# Run from the project root:  bash build/build_dmg.sh
# Output: dist/SourceStream-1.0.0.dmg
#
# What the resulting DMG provides:
#   • SourceStream.app  — drag to /Applications (standard UX)
#   • Install SourceStream.command  — double-click installer (sets up
#       LaunchAgent, config dirs, Desktop launcher, cron) — preferred for
#       new installs
#   • Uninstall SourceStream.command — full cleanup
#   • README.txt — quick-start instructions shown in the DMG window
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

# ── 1. Pre-flight ──────────────────────────────────────────────────────────────
echo ""
echo "🔍 Pre-flight checks..."
[ ! -d "$APP_SRC" ] && { echo "❌ App bundle not found: $APP_SRC"; exit 1; }
python3 -m py_compile "$APP_SRC/Contents/Resources/server.py" \
    && echo "   ✅ server.py syntax OK"
bash -n "$APP_SRC/Contents/Resources/backup_engine.sh" \
    && echo "   ✅ backup_engine.sh syntax OK"
[ -f "$APP_SRC/Contents/Library/LaunchAgents/com.sourcestream.server.plist" ] \
    && echo "   ✅ LaunchAgent template present"

# ── 2. Permissions ────────────────────────────────────────────────────────────
echo ""
echo "🔑 Setting executable permissions..."
chmod +x "$APP_SRC/Contents/MacOS/$APP_NAME"
chmod +x "$APP_SRC/Contents/Resources/backup_engine.sh"
chmod +x "$APP_SRC/Contents/Resources/server.py"
echo "   ✅ Done"

# ── 3. Stage directory ────────────────────────────────────────────────────────
echo ""
echo "📦 Staging DMG contents..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ── 3a. App bundle ────────────────────────────────────────────────────────────
cp -r "$APP_SRC" "$STAGE_DIR/$APP_BUNDLE"
# Remove __pycache__ from staged bundle
find "$STAGE_DIR/$APP_BUNDLE" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$STAGE_DIR/$APP_BUNDLE" -name "*.pyc" -delete 2>/dev/null || true
echo "   ✅ App bundle staged"

# ── 3b. /Applications symlink (drag-install UX) ───────────────────────────────
ln -s /Applications "$STAGE_DIR/Applications"

# ── 3c. Install SourceStream.command ─────────────────────────────────────────
# This is the preferred first-run installer — sets up everything automatically.
# .command files open in Terminal when double-clicked in the DMG.
cat > "$STAGE_DIR/Install SourceStream.command" << 'INSTALLER'
#!/bin/bash
# ==============================================================================
# SourceStream First-Run Installer
# Double-click this file in the DMG to install and configure SourceStream.
# ==============================================================================
set -e
clear
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║   ⚡ SourceStream  —  First-Run Installer          ║"
echo "║   Developer Backup Utility  v1.0.0                 ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# ── Colours
GRN='\033[0;32m'; YLW='\033[0;33m'; RED='\033[0;31m'; BLU='\033[0;34m'; RST='\033[0m'
ok()  { echo -e "${GRN}  ✅ $*${RST}"; }
inf() { echo -e "${BLU}  →  $*${RST}"; }
wrn() { echo -e "${YLW}  ⚠️  $*${RST}"; }
err() { echo -e "${RED}  ❌ $*${RST}"; sleep 3; exit 1; }

# ── Locate ourselves (we are inside the mounted DMG) ──────────────────────────
DMG_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="$DMG_DIR/SourceStream.app"
[ -d "$SRC_APP" ] || err "Cannot find SourceStream.app next to this installer."

INSTALL_APP="/Applications/SourceStream.app"
SS_DIR="$HOME/.sourcestream"
LOGS_DIR="$SS_DIR/logs"
CONF_DIR="$SS_DIR/config"
CONF_FILE="$CONF_DIR/sourcestream.conf"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHAGENT="$LAUNCHAGENT_DIR/com.sourcestream.server.plist"
TEMPLATE_PLIST="$INSTALL_APP/Contents/Library/LaunchAgents/com.sourcestream.server.plist"
DESKTOP_APP="$HOME/Desktop/SourceStream.app"

echo "  Installing to: $INSTALL_APP"
echo "  User data at:  $SS_DIR"
echo ""

# ── 1. Find Python 3 ──────────────────────────────────────────────────────────
inf "Locating Python 3..."
PYTHON_PATH=""
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$p" ]; then PYTHON_PATH="$p"; break; fi
done
[ -n "$PYTHON_PATH" ] || err "Python 3 not found. Install via: brew install python3"
ok "Python: $PYTHON_PATH"

# ── 2. Stop any running servers ───────────────────────────────────────────────
inf "Stopping any existing SourceStream / DevVault servers..."
launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_DIR/com.devvault.server.plist" 2>/dev/null || true
lsof -ti tcp:7474 | xargs kill -9 2>/dev/null || true
# Remove old DevVault agent entirely
rm -f "$LAUNCHAGENT_DIR/com.devvault.server.plist"
sleep 1
ok "Port 7474 cleared"

# ── 3. Copy .app to /Applications ────────────────────────────────────────────
inf "Installing SourceStream.app to /Applications..."
[ -d "$INSTALL_APP" ] && rm -rf "$INSTALL_APP"
cp -r "$SRC_APP" "$INSTALL_APP"
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
ok "App installed: $INSTALL_APP"

# ── 4. Create user data directories ──────────────────────────────────────────
inf "Creating user data directories..."
mkdir -p "$LOGS_DIR" "$CONF_DIR"
touch "$LOGS_DIR/server.log" "$LOGS_DIR/backup.log" "$LOGS_DIR/error.log"
ok "Data directory: $SS_DIR"

# ── 5. Write default config (preserve existing) ───────────────────────────────
if [ ! -f "$CONF_FILE" ]; then
    inf "Writing default config..."
    # Auto-detect Google Drive path
    GDRIVE_PATH=""
    for p in \
        "$HOME/Library/CloudStorage/GoogleDrive-"*"/My Drive" \
        "$HOME/Google Drive/My Drive" \
        "$HOME/Google Drive"; do
        if [ -d "$p" ]; then GDRIVE_PATH="$p/Developer Backups"; break; fi
    done
    [ -z "$GDRIVE_PATH" ] && GDRIVE_PATH="$HOME/Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"

    cat > "$CONF_FILE" << CONF
# SourceStream Configuration
# ~/.sourcestream/config/sourcestream.conf
# Managed by SourceStream Dashboard → Settings, or edit manually.
# Format:  section [settings] [sources] [destinations]
#          sources/destinations lines:  /absolute/path|Label

[settings]
DIRECT_TO_DRIVE=true
MAX_ARCHIVES_TO_KEEP=3

[sources]
$HOME/Developer|Developer

[destinations]
$GDRIVE_PATH|Google Drive
CONF
    ok "Default config written: $CONF_FILE"
else
    ok "Existing config preserved: $CONF_FILE"
fi

# ── 6. Stamp and install LaunchAgent ─────────────────────────────────────────
inf "Installing LaunchAgent (auto-start at login)..."
mkdir -p "$LAUNCHAGENT_DIR"
SERVER_PY="$INSTALL_APP/Contents/Resources/server.py"
RES_DIR="$INSTALL_APP/Contents/Resources"

sed \
    -e "s|__PYTHON__|$PYTHON_PATH|g" \
    -e "s|__SERVER_PY__|$SERVER_PY|g" \
    -e "s|__RES_DIR__|$RES_DIR|g" \
    -e "s|__LOGS_DIR__|$LOGS_DIR|g" \
    "$TEMPLATE_PLIST" > "$LAUNCHAGENT"
ok "LaunchAgent: $LAUNCHAGENT"

# ── 7. Load LaunchAgent ───────────────────────────────────────────────────────
inf "Starting server via LaunchAgent..."
launchctl load "$LAUNCHAGENT"
sleep 3
ok "Server started"

# ── 8. Seed status.json (so dashboard cards show data immediately) ─────────────
inf "Seeding initial status file..."
DEST_PATH="${GDRIVE_PATH:-$HOME/Library/CloudStorage/GoogleDrive/My Drive/Developer Backups}"
ARCH_COUNT=0; TOTAL_MB=0; FREE_MB=0
if [ -d "$DEST_PATH" ]; then
    ARCH_COUNT=$(ls "$DEST_PATH/"*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_MB=$(du -sm "$DEST_PATH" 2>/dev/null | awk '{print $1}')
    FREE_MB=$(df -k "$DEST_PATH" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
fi
TS=$(date +"%Y-%m-%d %H:%M:%S")
cat > "$SS_DIR/status.json" << JSON
{
  "last_updated": "$TS",
  "engine_status": "idle",
  "last_run_status": "",
  "last_run_start": "",
  "last_run_end": "",
  "last_run_duration_min": 0,
  "current_archive_path": "",
  "estimated_size_mb": 0,
  "sources": [
    {"name":"Developer","path":"$HOME/Developer","raw_mb":0,"archive_mb":0,"status":"ready"}
  ],
  "destinations": [
    {"label":"Google Drive","path":"$DEST_PATH","archive_count":${ARCH_COUNT},"total_mb":${TOTAL_MB:-0},"free_mb":${FREE_MB:-0},"status":"$([ -d "$DEST_PATH" ] && echo online || echo offline)"}
  ],
  "archives": [],
  "cron_schedule": "",
  "next_backup": "Not scheduled",
  "direct_to_drive": true,
  "max_archives_to_keep": 3,
  "ssd_footprint_mode": "1x (Direct)",
  "recent_log": ["SourceStream installed $TS. Click Run Backup to start."],
  "error_log_bytes": 0,
  "pid": null
}
JSON
ok "Status file seeded"

# ── 9. Build Desktop launcher ─────────────────────────────────────────────────
inf "Creating Desktop launcher..."
rm -rf "$DESKTOP_APP" /tmp/sourcestream_launcher.applescript /tmp/SourceStream_compiled.app
cat > /tmp/sourcestream_launcher.applescript << 'ASCRIPT'
set serverPort to 7474
set serverURL to "http://127.0.0.1:" & serverPort & "/"
set plistPath to (POSIX path of (path to home folder)) & "Library/LaunchAgents/com.sourcestream.server.plist"

set serverUp to false
try
    set curlResult to do shell script "curl -s --max-time 3 http://127.0.0.1:" & serverPort & "/api/health 2>/dev/null"
    if curlResult contains "app_version" then set serverUp to true
end try

if not serverUp then
    try
        do shell script "launchctl load " & quoted form of plistPath & " 2>/dev/null; sleep 2"
    end try
    try
        set curlResult to do shell script "curl -s --max-time 4 http://127.0.0.1:" & serverPort & "/api/health 2>/dev/null"
        if curlResult contains "app_version" then set serverUp to true
    end try
end if

if serverUp then
    try
        do shell script "open -na 'Google Chrome' --args --app=" & serverURL & " --window-size=1400,860 --window-position=60,40 --no-first-run --disable-extensions 2>/dev/null"
    on error
        open location serverURL
    end try
else
    display dialog "SourceStream server is not responding." & linefeed & linefeed & "To fix, run in Terminal:" & linefeed & "launchctl load ~/Library/LaunchAgents/com.sourcestream.server.plist" with title "SourceStream" buttons {"OK"} default button "OK" with icon caution
end if
ASCRIPT

osacompile -o /tmp/SourceStream_compiled.app /tmp/sourcestream_launcher.applescript 2>/dev/null
if [ -d /tmp/SourceStream_compiled.app ]; then
    cp -r /tmp/SourceStream_compiled.app "$DESKTOP_APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName SourceStream" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SourceStream" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$DESKTOP_APP" 2>/dev/null || true
    ok "Desktop launcher: ~/Desktop/SourceStream.app"
else
    wrn "Could not build Desktop launcher — open manually: http://127.0.0.1:7474/"
fi

# ── 10. Health check ──────────────────────────────────────────────────────────
echo ""
inf "Running health check..."
sleep 1
HEALTH=$(curl -s --max-time 6 "http://127.0.0.1:7474/api/health" 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "app_version"; then
    ok "Server is live at http://127.0.0.1:7474/"
else
    wrn "Server health check timed out — it may still be starting. Check:"
    echo "     tail -20 $LOGS_DIR/server.log"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅ SourceStream installed successfully!                   ║"
echo "║                                                            ║"
echo "║  🖥  Double-click ~/Desktop/SourceStream.app to open      ║"
echo "║  🌐  Or browse to: http://127.0.0.1:7474/                 ║"
echo "║  📁  Your data:    ~/.sourcestream/                       ║"
echo "║  📅  Set a schedule in Dashboard → Schedule page          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Auto-open the dashboard
sleep 1
open "http://127.0.0.1:7474/" 2>/dev/null || true

echo "  (This window can now be closed)"
sleep 5
INSTALLER
chmod +x "$STAGE_DIR/Install SourceStream.command"
echo "   ✅ Install SourceStream.command staged"

# ── 3d. Uninstall SourceStream.command ───────────────────────────────────────
cat > "$STAGE_DIR/Uninstall SourceStream.command" << 'UNINSTALLER'
#!/bin/bash
clear
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ⚡ SourceStream  —  Uninstaller             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  This will remove:"
echo "    /Applications/SourceStream.app"
echo "    ~/Library/LaunchAgents/com.sourcestream.server.plist"
echo "    ~/Desktop/SourceStream.app"
echo "    Crontab entry for backup_engine"
echo ""
echo "  Your backups in Google Drive are NOT touched."
echo "  Your config and logs in ~/.sourcestream/ are NOT deleted"
echo "  (delete manually if you want a clean slate)."
echo ""
read -p "  Type 'uninstall' to confirm: " CONFIRM
if [ "$CONFIRM" != "uninstall" ]; then
    echo "  Cancelled."; sleep 2; exit 0
fi

echo ""

# Stop server
launchctl unload ~/Library/LaunchAgents/com.sourcestream.server.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.devvault.server.plist 2>/dev/null || true
lsof -ti tcp:7474 | xargs kill -9 2>/dev/null || true
echo "  ✅ Server stopped"

# Remove LaunchAgent(s)
rm -f ~/Library/LaunchAgents/com.sourcestream.server.plist
rm -f ~/Library/LaunchAgents/com.devvault.server.plist
echo "  ✅ LaunchAgents removed"

# Remove app
rm -rf /Applications/SourceStream.app
echo "  ✅ /Applications/SourceStream.app removed"

# Remove Desktop launcher
rm -rf ~/Desktop/SourceStream.app ~/Desktop/"Backup Control Wizard.app"
echo "  ✅ Desktop launchers removed"

# Remove cron
(crontab -l 2>/dev/null | grep -v backup_engine | grep -v sourcestream | grep -v devvault) | crontab - 2>/dev/null || true
echo "  ✅ Crontab entries removed"

echo ""
echo "  SourceStream has been uninstalled."
echo "  Your data remains at: ~/.sourcestream/"
echo ""
sleep 3
UNINSTALLER
chmod +x "$STAGE_DIR/Uninstall SourceStream.command"
echo "   ✅ Uninstall SourceStream.command staged"

# ── 3e. README.txt ────────────────────────────────────────────────────────────
{
printf '%s\n' \
    'SourceStream  --  Developer Backup Utility  v1.0.0' \
    '====================================================' \
    '' \
    'QUICK INSTALL (Recommended)' \
    '----------------------------' \
    '1. Double-click "Install SourceStream.command" in this window' \
    '2. A Terminal opens and runs the full installer automatically' \
    '3. When done, ~/Desktop/SourceStream.app opens the dashboard' \
    '' \
    'MANUAL INSTALL' \
    '--------------' \
    '1. Drag SourceStream.app -> Applications folder (shortcut on the right)' \
    '2. Open Terminal and run:' \
    '     /Applications/SourceStream.app/Contents/MacOS/SourceStream' \
    '3. The launcher sets up everything on first run' \
    '' \
    'WHAT GETS INSTALLED' \
    '-------------------' \
    '  /Applications/SourceStream.app         -- the app bundle' \
    '  ~/Library/LaunchAgents/                -- server auto-starts at login' \
    '  ~/.sourcestream/config/                -- your config (preserved on update)' \
    '  ~/.sourcestream/logs/                  -- backup and server logs' \
    '  ~/Desktop/SourceStream.app             -- one-click dashboard launcher' \
    '' \
    'DASHBOARD' \
    '---------' \
    'http://127.0.0.1:7474/' \
    '  (or double-click ~/Desktop/SourceStream.app)' \
    '' \
    'UNINSTALL' \
    '---------' \
    'Double-click "Uninstall SourceStream.command" in this window.' \
    '' \
    'SUPPORT' \
    '-------' \
    'Logs: ~/.sourcestream/logs/'
} > "$STAGE_DIR/README.txt"
echo "   ✅ README.txt staged"

# ── 4. Build DMG ──────────────────────────────────────────────────────────────
echo ""
echo "💿 Building DMG..."
rm -f "$DMG_OUT"
hdiutil create \
    -volname "SourceStream" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -o "$DMG_OUT"

# Clean up stage
rm -rf "$STAGE_DIR"

SIZE=$(du -sh "$DMG_OUT" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ DMG built: $DMG_OUT"
echo "   Size: $SIZE"
echo ""
echo "   DMG contains:"
echo "     • SourceStream.app            — drag to /Applications"
echo "     • Install SourceStream.command — preferred: double-click to fully install"
echo "     • Uninstall SourceStream.command"
echo "     • README.txt"
echo ""
echo "   To install:  open $DMG_OUT"
echo "                then double-click 'Install SourceStream.command'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
