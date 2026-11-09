#!/bin/bash
# ==============================================================================
# install.sh — SourceStream Installer
# /Users/masud/Developer/SourceStream/build/install.sh
#
# Installs SourceStream to /Applications, sets up LaunchAgent, and places
# a launcher on the Desktop. Safe to run again for updates.
# ==============================================================================
set -e

APP_NAME="SourceStream"
APP_BUNDLE="SourceStream.app"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_APP="$SRC_DIR/$APP_BUNDLE"
INSTALL_DIR="/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_BUNDLE"
SS_DIR="$HOME/.sourcestream"
LOGS_DIR="$SS_DIR/logs"
CONF_DIR="$SS_DIR/config"
CONF_FILE="$CONF_DIR/sourcestream.conf"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHAGENT="$LAUNCHAGENT_DIR/com.sourcestream.server.plist"
DESKTOP_APP="$HOME/Desktop/$APP_BUNDLE"
TEMPLATE_PLIST="$SRC_APP/Contents/Library/LaunchAgents/com.sourcestream.server.plist"

# ── Colours ───────────────────────────────────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[0;33m'; RED='\033[0;31m'; BLU='\033[0;34m'; RST='\033[0m'
ok()  { echo -e "${GRN}  ✅ $*${RST}"; }
inf() { echo -e "${BLU}  ℹ️  $*${RST}"; }
wrn() { echo -e "${YLW}  ⚠️  $*${RST}"; }
err() { echo -e "${RED}  ❌ $*${RST}"; exit 1; }

echo ""
echo "╔════════════════════════════════════════╗"
echo "║   ⚡ SourceStream Installer v1.0.0     ║"
echo "╚════════════════════════════════════════╝"
echo ""

# ── 1. Verify source bundle exists ────────────────────────────────────────────
[ -d "$SRC_APP" ] || err "Source bundle not found: $SRC_APP"
inf "Source: $SRC_APP"

# ── 2. Find Python ────────────────────────────────────────────────────────────
PYTHON_PATH=""
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -x "$p" ]; then PYTHON_PATH="$p"; break; fi
done
[ -n "$PYTHON_PATH" ] || err "Python 3 not found. Install via Homebrew: brew install python3"
ok "Python: $PYTHON_PATH"

# ── 3. Stop old server(s) ────────────────────────────────────────────────────
inf "Stopping any running SourceStream / DevVault servers..."
launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_DIR/com.devvault.server.plist" 2>/dev/null || true
lsof -ti tcp:7474 | xargs kill -9 2>/dev/null || true
sleep 1

# ── 4. Remove old DevVault LaunchAgent if present ────────────────────────────
if [ -f "$LAUNCHAGENT_DIR/com.devvault.server.plist" ]; then
    rm "$LAUNCHAGENT_DIR/com.devvault.server.plist"
    wrn "Removed old DevVault LaunchAgent"
fi

# ── 5. Copy .app to /Applications ────────────────────────────────────────────
inf "Installing $APP_BUNDLE to $INSTALL_DIR..."
if [ -d "$INSTALL_APP" ]; then
    inf "Existing installation found — updating..."
    rm -rf "$INSTALL_APP"
fi
cp -r "$SRC_APP" "$INSTALL_APP"
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
ok "App installed: $INSTALL_APP"

# ── 6. Create user data directories ──────────────────────────────────────────
mkdir -p "$LOGS_DIR" "$CONF_DIR"
touch "$LOGS_DIR/server.log" "$LOGS_DIR/backup.log" "$LOGS_DIR/error.log"
ok "Data directories: $SS_DIR"

# ── 7. Write default config (preserve existing) ───────────────────────────────
if [ ! -f "$CONF_FILE" ]; then
    cat > "$CONF_FILE" << 'CONF'
# SourceStream Configuration
# ~/.sourcestream/config/sourcestream.conf
# Managed by SourceStream Dashboard or edited manually.

[settings]
DIRECT_TO_DRIVE=true
MAX_ARCHIVES_TO_KEEP=3

[sources]
/Users/masud/Developer|Developer

[destinations]
/Users/masud/Library/CloudStorage/GoogleDrive-umasud.zmn@gmail.com/My Drive/Developer Backups|Google Drive
CONF
    ok "Default config written: $CONF_FILE"
else
    ok "Config preserved: $CONF_FILE"
fi

# ── 8. Stamp and install LaunchAgent ─────────────────────────────────────────
SERVER_PY="$INSTALL_APP/Contents/Resources/server.py"
RES_DIR="$INSTALL_APP/Contents/Resources"

mkdir -p "$LAUNCHAGENT_DIR"
sed \
    -e "s|__PYTHON__|$PYTHON_PATH|g" \
    -e "s|__SERVER_PY__|$SERVER_PY|g" \
    -e "s|__RES_DIR__|$RES_DIR|g" \
    -e "s|__LOGS_DIR__|$LOGS_DIR|g" \
    "$TEMPLATE_PLIST" > "$LAUNCHAGENT"
ok "LaunchAgent written: $LAUNCHAGENT"

# ── 9. Load LaunchAgent ───────────────────────────────────────────────────────
launchctl load "$LAUNCHAGENT"
sleep 2
if launchctl list | grep -q "com.sourcestream.server"; then
    ok "LaunchAgent loaded — server starting..."
else
    wrn "LaunchAgent may not have loaded. Check: launchctl list | grep sourcestream"
fi

# ── 10. Build Desktop launcher ────────────────────────────────────────────────
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
    /usr/libexec/PlistBuddy -c "Set :CFBundleName SourceStream" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SourceStream" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null
    xattr -dr com.apple.quarantine "$DESKTOP_APP" 2>/dev/null || true
    ok "Desktop launcher: $DESKTOP_APP"
else
    wrn "Could not compile Desktop launcher — open manually: open -na 'Google Chrome' --args --app=http://127.0.0.1:7474/"
fi

# ── 11. Health check ──────────────────────────────────────────────────────────
sleep 2
echo ""
echo "── Health check ─────────────────────────────────────────────"
HEALTH=$(curl -s --max-time 5 "http://127.0.0.1:7474/api/health" 2>/dev/null)
if echo "$HEALTH" | grep -q "app_version"; then
    ok "Server is live at http://127.0.0.1:7474/"
    echo "$HEALTH" | python3 -m json.tool 2>/dev/null | grep -E "conf_path|drive|cron|app_version" | sed 's/^/     /'
else
    wrn "Server health check failed — check: tail -20 $LOGS_DIR/server.log"
fi

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  ✅ SourceStream installed successfully!               ║"
echo "║                                                        ║"
echo "║  🖥  Double-click ~/Desktop/SourceStream.app to open  ║"
echo "║  🌐  Or visit: http://127.0.0.1:7474/                 ║"
echo "║  📁  User data: ~/.sourcestream/                      ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

