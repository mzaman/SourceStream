#!/bin/bash
# ==============================================================================
# install.sh — SourceStream Installer / Updater
# /path/to/SourceStream/build/install.sh
#
# Safe to run repeatedly:
#   • First install  → writes fresh config with auto-detected Google Drive
#   • Re-install / Update → preserves existing config; merges any NEW settings keys
#   • Never deletes ~/.sourcestream/ data, logs, or existing archives
# ==============================================================================
set -e

APP_NAME="SourceStream"
APP_VERSION="1.0.14"
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
echo "╔══════════════════════════════════════════╗"
echo "║   ⚡ SourceStream Installer v$APP_VERSION      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

IS_UPDATE=false
[ -d "$INSTALL_APP" ] && IS_UPDATE=true

# ── 1. Verify source bundle ───────────────────────────────────────────────────
[ -d "$SRC_APP" ] || err "Source bundle not found: $SRC_APP"
inf "Source: $SRC_APP"

# ── 2. Find Python ────────────────────────────────────────────────────────────
PYTHON_PATH=""
for p in \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3 \
    "$HOME/.pyenv/shims/python3" \
    "$HOME/.asdf/shims/python3"; do
    [ -x "$p" ] && PYTHON_PATH="$p" && break
done
[ -n "$PYTHON_PATH" ] || err "Python 3 not found. Install via Homebrew: brew install python3"
ok "Python: $PYTHON_PATH  ($(${PYTHON_PATH} --version 2>&1))"

# ── 3. Stop old servers ───────────────────────────────────────────────────────
inf "Stopping any running SourceStream / DevVault servers..."
launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_DIR/com.devvault.server.plist" 2>/dev/null || true
lsof -ti tcp:7474 | xargs kill -9 2>/dev/null || true
sleep 1

# Remove legacy DevVault LaunchAgent
[ -f "$LAUNCHAGENT_DIR/com.devvault.server.plist" ] && {
    rm "$LAUNCHAGENT_DIR/com.devvault.server.plist"
    wrn "Removed old DevVault LaunchAgent"
}

# ── 4. Copy .app to /Applications ────────────────────────────────────────────
inf "$( $IS_UPDATE && echo 'Updating' || echo 'Installing' ) $APP_BUNDLE to $INSTALL_DIR..."
rm -rf "$INSTALL_APP"
cp -r "$SRC_APP" "$INSTALL_APP"
chmod +x "$INSTALL_APP/Contents/MacOS/$APP_NAME"
chmod +x "$INSTALL_APP/Contents/Resources/backup_engine.sh"
chmod +x "$INSTALL_APP/Contents/Resources/server.py"
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
# Remove any cached Python bytecode from the installed copy
find "$INSTALL_APP" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$INSTALL_APP" -name "*.pyc" -delete 2>/dev/null || true
ok "App $( $IS_UPDATE && echo 'updated' || echo 'installed' ): $INSTALL_APP"

# ── 5. Create user data directories (never destructive) ───────────────────────
mkdir -p "$LOGS_DIR" "$CONF_DIR"
touch "$LOGS_DIR/server.log" "$LOGS_DIR/backup.log" "$LOGS_DIR/error.log"
ok "Data directories: $SS_DIR"

# ── 6. Config — write fresh OR migrate existing ───────────────────────────────
# Default settings keys and values (single source of truth)
declare -A DEFAULT_SETTINGS
DEFAULT_SETTINGS[DIRECT_TO_DRIVE]="true"
DEFAULT_SETTINGS[MAX_ARCHIVES_TO_KEEP]="3"
DEFAULT_SETTINGS[COMPRESSION_LEVEL]="6"
DEFAULT_SETTINGS[ARCHIVE_PREFIX]="{label}"
DEFAULT_SETTINGS[HOSTNAME_IN_NAME]="false"
DEFAULT_SETTINGS[BACKUP_VERIFY]="false"
DEFAULT_SETTINGS[ARCHIVE_FORMAT]="tar.gz"
DEFAULT_SETTINGS[NOTIFY_ON_COMPLETE]="false"

if [ ! -f "$CONF_FILE" ]; then
    # ── Fresh install: auto-detect Google Drive and write default config ───────
    GDRIVE_PATH=""
    if [ -d "$HOME/Library/CloudStorage" ]; then
        for d in "$HOME/Library/CloudStorage/GoogleDrive-"*/; do
            [ -d "${d}My Drive" ] && { GDRIVE_PATH="${d}My Drive/Developer Backups"; break; }
        done
    fi
    [ -z "$GDRIVE_PATH" ] && [ -d "$HOME/Google Drive/My Drive" ] && \
        GDRIVE_PATH="$HOME/Google Drive/My Drive/Developer Backups"
    [ -z "$GDRIVE_PATH" ] && \
        GDRIVE_PATH="$HOME/Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"

    cat > "$CONF_FILE" << CONF
# SourceStream Configuration  —  v${APP_VERSION}
# ~/.sourcestream/config/sourcestream.conf
# Managed by SourceStream Dashboard or edited manually.

[settings]
DIRECT_TO_DRIVE=true
MAX_ARCHIVES_TO_KEEP=3
COMPRESSION_LEVEL=6
ARCHIVE_PREFIX={label}
HOSTNAME_IN_NAME=false
BACKUP_VERIFY=false
ARCHIVE_FORMAT=tar.gz

[sources]
$HOME/Developer|Developer

[destinations]
$GDRIVE_PATH|Google Drive

[excludes]
CONF
    ok "Default config written: $CONF_FILE"
    inf "Auto-detected destination: $GDRIVE_PATH"
else
    # ── Update install: merge new keys without touching existing values ────────
    inf "Existing config found — merging new settings keys..."
    MERGED=0

    # Read existing settings keys from the config
    EXISTING_KEYS=$(awk '/^\[settings\]/{f=1;next} f && /^\[/{f=0} f && /=/{print $1}' \
                    FS='=' "$CONF_FILE" | tr -d ' ')

    # Find where [settings] section ends (line before next [section])
    SETTINGS_END=$(awk '/^\[settings\]/{f=1;next} f && /^\[/{print NR;exit}' "$CONF_FILE")
    [ -z "$SETTINGS_END" ] && SETTINGS_END=$(wc -l < "$CONF_FILE")

    # Inject each missing key at SETTINGS_END
    INJECT_LINES=""
    for KEY in DIRECT_TO_DRIVE MAX_ARCHIVES_TO_KEEP COMPRESSION_LEVEL ARCHIVE_PREFIX HOSTNAME_IN_NAME BACKUP_VERIFY ARCHIVE_FORMAT NOTIFY_ON_COMPLETE BACKUP_MODE; do
        if ! echo "$EXISTING_KEYS" | grep -q "^${KEY}$"; then
            VAL="${DEFAULT_SETTINGS[$KEY]}"
            INJECT_LINES="${INJECT_LINES}${KEY}=${VAL}\n"
            MERGED=$((MERGED+1))
        fi
    done

    if [ -n "$INJECT_LINES" ]; then
        # Insert missing lines before the SETTINGS_END line
        python3 - "$CONF_FILE" "$SETTINGS_END" "$INJECT_LINES" << 'PYEOF'
import sys
path, end_line, inject = sys.argv[1], int(sys.argv[2])-1, sys.argv[3]
lines = open(path).readlines()
to_add = [l+'\n' for l in inject.rstrip('\\n').split('\\n') if l]
lines = lines[:end_line] + to_add + lines[end_line:]
open(path, 'w').writelines(lines)
PYEOF
    fi

    # Ensure [excludes] section exists
    if ! grep -q "^\[excludes\]" "$CONF_FILE"; then
        printf '\n[excludes]\n' >> "$CONF_FILE"
        MERGED=$((MERGED+1))
    fi

    if [ "$MERGED" -gt 0 ]; then
        ok "Config migrated: $MERGED new keys added (existing values preserved)"
    else
        ok "Config up-to-date: $CONF_FILE"
    fi
fi

# ── 7. Stamp and install LaunchAgent ─────────────────────────────────────────
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

# ── 8. Load server LaunchAgent ────────────────────────────────────────────────
launchctl load "$LAUNCHAGENT" 2>/dev/null || true
sleep 2
if launchctl list 2>/dev/null | grep -q "com.sourcestream.server"; then
    ok "LaunchAgent loaded — server starting..."
else
    wrn "LaunchAgent may not have loaded. Check: launchctl list | grep sourcestream"
fi

# ── 8b. Install Menu Bar Agent LaunchAgent ────────────────────────────────────
MENUBAR_TEMPLATE="$INSTALL_APP/Contents/Library/LaunchAgents/com.sourcestream.menubar.plist"
MENUBAR_PLIST="$LAUNCHAGENT_DIR/com.sourcestream.menubar.plist"
MENUBAR_PY="$INSTALL_APP/Contents/Resources/menubar_agent.py"

if [ -f "$MENUBAR_TEMPLATE" ] && [ -f "$MENUBAR_PY" ]; then
    sed \
        -e "s|__PYTHON__|$PYTHON_PATH|g" \
        -e "s|__MENUBAR_PY__|$MENUBAR_PY|g" \
        -e "s|__RES_DIR__|$RES_DIR|g" \
        -e "s|__LOGS_DIR__|$LOGS_DIR|g" \
        "$MENUBAR_TEMPLATE" > "$MENUBAR_PLIST"
    # Only load if PyObjC/AppKit is available
    if "$PYTHON_PATH" -c "import AppKit" 2>/dev/null; then
        launchctl load "$MENUBAR_PLIST" 2>/dev/null || true
        ok "Menu bar agent installed (PyObjC detected)"
    else
        ok "Menu bar agent plist installed — PyObjC not found, skipping load"
        inf "  To enable: pip3 install pyobjc-framework-Cocoa  then reopen SourceStream"
    fi
fi

# ── 9. Build Desktop launcher ────────────────────────────────────────────────
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
    -- Try Chrome app-mode first, then Edge, then Brave, then default browser
    set launched to false
    repeat with chromePath in {"/Applications/Google Chrome.app", "/Applications/Microsoft Edge.app", "/Applications/Brave Browser.app", "/Applications/Chromium.app"}
        if not launched then
            try
                set chromeBin to POSIX path of (chromePath as text) & "Contents/MacOS/" & (do shell script "ls " & quoted form of POSIX path of (chromePath as text) & "Contents/MacOS/")
                do shell script quoted form of chromeBin & " --app=" & serverURL & " --window-size=1340,860 --window-position=60,40 --no-first-run --disable-extensions 2>/dev/null &"
                set launched to true
            end try
        end if
    end repeat
    if not launched then
        open location serverURL
    end if
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
    ok "Desktop launcher: $DESKTOP_APP"
else
    wrn "Could not compile Desktop launcher — open manually: open -na 'Google Chrome' --args --app=http://127.0.0.1:7474/"
fi

# ── 10. Health check ─────────────────────────────────────────────────────────
sleep 2
echo ""
echo "── Health check ──────────────────────────────────────────────"
HEALTH=$(curl -s --max-time 5 "http://127.0.0.1:7474/api/health" 2>/dev/null)
if echo "$HEALTH" | grep -q "app_version"; then
    ok "Server is live at http://127.0.0.1:7474/"
    echo "$HEALTH" | python3 -m json.tool 2>/dev/null \
        | grep -E '"(conf_path|drive|cron|app_version|ssd_free_gb)"' \
        | sed 's/^/     /'
else
    wrn "Server health check failed — check: tail -20 $LOGS_DIR/server.log"
fi

echo ""
if $IS_UPDATE; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SourceStream updated to v${APP_VERSION} successfully!       ║"
    echo "║                                                            ║"
    echo "║  Your config and backups are fully preserved.              ║"
    echo "║  🌐  Dashboard: http://127.0.0.1:7474/                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
else
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✅ SourceStream v${APP_VERSION} installed successfully!         ║"
    echo "║                                                            ║"
    echo "║  🖥  Double-click ~/Desktop/SourceStream.app to open      ║"
    echo "║  🌐  Or visit: http://127.0.0.1:7474/                    ║"
    echo "║  📁  User data: ~/.sourcestream/                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
fi
echo ""
