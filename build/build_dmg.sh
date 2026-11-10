#!/bin/bash
# ==============================================================================
# build_dmg.sh  —  SourceStream macOS DMG Builder
# Run from the project root:  bash build/build_dmg.sh
# Output: dist/SourceStream-1.0.11.dmg
#
# What the resulting DMG provides:
#   • SourceStream.app  — drag to /Applications (standard UX)
#   • Install SourceStream.command  — double-click installer (sets up
#       LaunchAgent, config dirs, Desktop launcher, cron) — preferred for
#       new installs AND updates/reinstalls (merges config safely)
#   • Uninstall SourceStream.command — full cleanup
#   • README.txt — quick-start instructions shown in the DMG window
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="SourceStream"
APP_BUNDLE="$APP_NAME.app"
VERSION="1.0.11"
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
chmod +x "$APP_SRC/Contents/Resources/menubar_agent.py"
echo "   ✅ Done"

echo ""
echo "🔏 Ad-hoc codesigning the app bundle..."
if command -v codesign &>/dev/null; then
    codesign --force --deep --sign - \
        "$APP_SRC" 2>/dev/null && \
        echo "   ✅ Ad-hoc signed (--sign -)" || \
        echo "   ⚠️  codesign failed — app will still work but Gatekeeper may prompt"
else
    echo "   ⚠️  codesign not found — skipping (Xcode Command Line Tools required)"
fi

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
# Works for fresh install AND update/reinstall (config is safely merged).
cat > "$STAGE_DIR/Install SourceStream.command" << 'INSTALLER'
#!/bin/bash
# ==============================================================================
# SourceStream Installer  v1.0.11
# Double-click this file in the DMG to install or update SourceStream.
# Safe for reinstalls — existing config is PRESERVED and new keys merged in.
# ==============================================================================
set -e
clear
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║   ⚡ SourceStream  —  Installer  v1.0.11           ║"
echo "║   Smart backups. Zero friction.                    ║"
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

# Detect update vs fresh install
IS_UPDATE=false
[ -d "$INSTALL_APP" ] && IS_UPDATE=true

if $IS_UPDATE; then
    echo "  Mode:          UPDATE (existing installation found)"
else
    echo "  Mode:          FRESH INSTALL"
fi
echo "  Installing to: $INSTALL_APP"
echo "  User data at:  $SS_DIR"
echo ""

# ── 1. Find Python 3 ──────────────────────────────────────────────────────────
inf "Locating Python 3..."
PYTHON_PATH=""
# Try Homebrew ARM → Homebrew Intel → pyenv → asdf → system
for p in \
    /opt/homebrew/bin/python3 \
    /opt/homebrew/opt/python@3.14/bin/python3.14 \
    /opt/homebrew/opt/python@3.13/bin/python3.13 \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/opt/python@3.11/bin/python3.11 \
    /usr/local/bin/python3 \
    "$HOME/.pyenv/shims/python3" \
    "$HOME/.asdf/shims/python3" \
    /usr/bin/python3; do
    if [ -x "$p" ]; then PYTHON_PATH="$p"; break; fi
done
# Final fallback
[ -z "$PYTHON_PATH" ] && PYTHON_PATH=$(command -v python3 2>/dev/null || true)
[ -n "$PYTHON_PATH" ] || err "Python 3 not found. Install via: brew install python3"
ok "Python: $PYTHON_PATH ($("$PYTHON_PATH" --version 2>&1))"

# ── 2. Stop any running servers ───────────────────────────────────────────────
inf "Stopping any existing SourceStream servers..."
launchctl unload "$LAUNCHAGENT" 2>/dev/null || true
launchctl unload "$LAUNCHAGENT_DIR/com.devvault.server.plist" 2>/dev/null || true
lsof -ti tcp:7474 | xargs kill -9 2>/dev/null || true
# Remove legacy DevVault agent
rm -f "$LAUNCHAGENT_DIR/com.devvault.server.plist"
sleep 1
ok "Port 7474 cleared"

# ── 3. Copy .app to /Applications ────────────────────────────────────────────
inf "Installing SourceStream.app to /Applications..."
[ -d "$INSTALL_APP" ] && rm -rf "$INSTALL_APP"
cp -r "$SRC_APP" "$INSTALL_APP"
# Remove __pycache__ from installed copy
find "$INSTALL_APP" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$INSTALL_APP" -name "*.pyc" -delete 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
ok "App installed: $INSTALL_APP"

# ── 4. Create user data directories ──────────────────────────────────────────
inf "Creating user data directories..."
mkdir -p "$LOGS_DIR" "$CONF_DIR"
touch "$LOGS_DIR/server.log" "$LOGS_DIR/backup.log" "$LOGS_DIR/error.log"
ok "Data directory: $SS_DIR"

# ── 5. Config — fresh install or migrate existing ─────────────────────────────
# Auto-detect Google Drive path (supports any Google account email)
GDRIVE_PATH=""
for p in \
    "$HOME/Library/CloudStorage/GoogleDrive-"*"/My Drive" \
    "$HOME/Google Drive/My Drive" \
    "$HOME/Google Drive"; do
    if [ -d "$p" ]; then GDRIVE_PATH="$p/Developer Backups"; break; fi
done
[ -z "$GDRIVE_PATH" ] && GDRIVE_PATH="$HOME/Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"

if [ ! -f "$CONF_FILE" ]; then
    # ── Fresh install: write full config with all keys ─────────────────────────
    inf "Writing default config..."
    cat > "$CONF_FILE" << CONF
# SourceStream Configuration
# ~/.sourcestream/config/sourcestream.conf
# Managed by SourceStream Dashboard → Settings, or edit manually.
# Format: section headers [settings] [sources] [destinations] [excludes]
#         sources/destinations lines: /absolute/path|Label
#         excludes lines: pattern (one per line, supports wildcards)

[settings]
DIRECT_TO_DRIVE=true
MAX_ARCHIVES_TO_KEEP=3
COMPRESSION_LEVEL=6
ARCHIVE_PREFIX={label}
HOSTNAME_IN_NAME=false
BACKUP_VERIFY=false
ARCHIVE_FORMAT=zip

[sources]
$HOME/Developer|Developer

[destinations]
$GDRIVE_PATH|Google Drive

[excludes]
node_modules
.git
__pycache__
*.pyc
.DS_Store
.venv
venv
.env
*.log
*.tmp
Pods
.build
DerivedData
CONF
    ok "Default config written: $CONF_FILE"
else
    # ── Update/reinstall: inject only MISSING keys (never overwrite existing) ──
    inf "Existing config found — merging new settings keys..."
    "$PYTHON_PATH" - "$CONF_FILE" << 'PYEOF'
import sys, os, re

conf_path = sys.argv[1]
with open(conf_path, 'r') as f:
    lines = f.readlines()

content = ''.join(lines)

# Keys that must exist in [settings] with their defaults
REQUIRED_KEYS = {
    'DIRECT_TO_DRIVE':      'true',
    'MAX_ARCHIVES_TO_KEEP': '3',
    'COMPRESSION_LEVEL':    '6',
    'ARCHIVE_PREFIX':       '{label}',
    'HOSTNAME_IN_NAME':     'false',
    'BACKUP_VERIFY':        'false',
    'ARCHIVE_FORMAT':       'zip',
    'NOTIFY_ON_COMPLETE':   'true',
    'BACKUP_MODE':          'full',
}

# Find which keys are already present (case-insensitive)
existing_keys = set()
for line in lines:
    m = re.match(r'^\s*([A-Z_]+)\s*=', line)
    if m:
        existing_keys.add(m.group(1).upper())

missing = {k: v for k, v in REQUIRED_KEYS.items() if k not in existing_keys}
if not missing:
    print("  ✅ All settings keys present — no migration needed")
    sys.exit(0)

# Find the [settings] section and inject missing keys after it
new_lines = []
in_settings = False
injected = False
for line in lines:
    new_lines.append(line)
    if re.match(r'^\[settings\]', line.strip()):
        in_settings = True
    elif in_settings and not injected and re.match(r'^\[', line.strip()):
        # We hit the next section — inject before it
        for k, v in missing.items():
            new_lines.insert(-1, f"{k}={v}\n")
        injected = True
        in_settings = False

# If [settings] was last section or no next section found
if in_settings and not injected:
    for k, v in missing.items():
        new_lines.append(f"{k}={v}\n")
    injected = True

# If [settings] section doesn't exist at all, prepend it
if not injected:
    header = ["[settings]\n"] + [f"{k}={v}\n" for k, v in missing.items()] + ["\n"]
    new_lines = header + new_lines

# Ensure [excludes] section exists
if '[excludes]' not in content:
    new_lines.append("\n[excludes]\n")
    new_lines.append("node_modules\n")
    new_lines.append(".git\n")
    new_lines.append("__pycache__\n")
    new_lines.append("*.pyc\n")
    new_lines.append(".DS_Store\n")
    print(f"  → Added [excludes] section with defaults")

with open(conf_path, 'w') as f:
    f.writelines(new_lines)

print(f"  → Injected missing keys: {list(missing.keys())}")
print("  ✅ Config migration complete — existing values preserved")
PYEOF
    ok "Config migration done: $CONF_FILE"
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
DEST_PATH="${GDRIVE_PATH}"
ARCH_COUNT=0; TOTAL_MB=0; FREE_MB=0
if [ -d "$DEST_PATH" ]; then
    ARCH_COUNT=$(ls "$DEST_PATH/"*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_MB=$(du -sm "$DEST_PATH" 2>/dev/null | awk '{print $1}')
    FREE_MB=$(df -k "$DEST_PATH" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
fi
TS=$(date +"%Y-%m-%d %H:%M:%S")
mkdir -p "$SS_DIR"
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
  "recent_log": ["SourceStream $( $IS_UPDATE && echo 'updated' || echo 'installed' ) $TS. Click Run Backup to start."],
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

-- Check if server is already up
set serverUp to false
try
    set curlResult to do shell script "curl -s --max-time 3 http://127.0.0.1:" & serverPort & "/api/health 2>/dev/null"
    if curlResult contains "app_version" then set serverUp to true
end try

-- Try to start it if not up
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
    -- Try Chrome → Chromium → Brave → Edge → default browser
    set appOpened to false
    repeat with browserInfo in {{"Google Chrome", "Google Chrome"}, {"Chromium", "Chromium"}, {"Brave Browser", "Brave Browser"}, {"Microsoft Edge", "Microsoft Edge"}}
        set bName to item 1 of browserInfo
        try
            do shell script "open -na " & quoted form of bName & " --args --app=" & serverURL & " --window-size=1340,860 --window-position=60,40 --no-first-run --disable-extensions 2>/dev/null"
            set appOpened to true
            exit repeat
        end try
    end repeat
    if not appOpened then
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
    ok "Desktop launcher: ~/Desktop/SourceStream.app"
else
    wrn "Could not build Desktop launcher — open manually: http://127.0.0.1:7474/"
fi

# ── 10. Health check ──────────────────────────────────────────────────────────
echo ""
inf "Running health check..."
sleep 1
HEALTH=$(curl -s --max-time 8 "http://127.0.0.1:7474/api/health" 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "app_version"; then
    ok "Server is live at http://127.0.0.1:7474/"
else
    wrn "Server health check timed out — it may still be starting. Check:"
    echo "     tail -20 $LOGS_DIR/server.log"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
if $IS_UPDATE; then
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅ SourceStream updated to v1.0.11 successfully!          ║"
echo "║                                                            ║"
echo "║  Your config and data were PRESERVED.                     ║"
echo "║  New settings keys were merged in automatically.          ║"
echo "╚════════════════════════════════════════════════════════════╝"
else
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ✅ SourceStream v1.0.11 installed successfully!           ║"
echo "║                                                            ║"
echo "║  🖥  Double-click ~/Desktop/SourceStream.app to open      ║"
echo "║  🌐  Or browse to: http://127.0.0.1:7474/                 ║"
echo "║  📁  Your data:    ~/.sourcestream/                       ║"
echo "║  📅  Set a schedule in Dashboard → Schedule page          ║"
echo "╚════════════════════════════════════════════════════════════╝"
fi
echo ""

# ── Full Disk Access prompt ───────────────────────────────────────────────────
# SourceStream needs Full Disk Access to back up Photos, Mail, Messages and
# other protected system folders. Prompt the user now so backups work fully.
echo ""
inf "Requesting Full Disk Access permission..."
_FDA_RESULT=$(osascript 2>/dev/null <<'APPLESCRIPT'
display dialog "SourceStream needs Full Disk Access to back up all your files, including Photos, Mail, and Messages." & return & return & "To grant access:" & return & "  1. Click 'Open Privacy Settings'" & return & "  2. Click the '+' button" & return & "  3. Add SourceStream from your Applications folder" & return & "  4. Enable the toggle next to SourceStream" & return & return & "You can skip this now and do it later in:" & return & "System Settings → Privacy & Security → Full Disk Access" with title "SourceStream — Permission Required" buttons {"Skip for Now", "Open Privacy Settings"} default button "Open Privacy Settings" with icon caution
APPLESCRIPT
)
if echo "$_FDA_RESULT" | grep -q "Open Privacy Settings"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
    echo "   ↗  Opened System Settings → Full Disk Access"
    echo "      Add SourceStream from Applications, then return here."
    sleep 3
else
    wrn "Full Disk Access skipped — some protected files may not be backed up."
    wrn "You can grant it later: System Settings → Privacy & Security → Full Disk Access"
fi
echo ""

# Auto-open the dashboard
sleep 1
# Try Chrome app-mode first, fall back to default browser
_OPENED=0
for _B in "Google Chrome" "Chromium" "Brave Browser" "Microsoft Edge"; do
    if open -na "$_B" --args --app=http://127.0.0.1:7474/ --window-size=1340,860 --no-first-run --disable-extensions 2>/dev/null; then
        _OPENED=1; break
    fi
done
[ $_OPENED -eq 0 ] && open "http://127.0.0.1:7474/" 2>/dev/null || true

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
echo "║   ⚡ SourceStream  —  Uninstaller            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  This will remove:"
echo "    /Applications/SourceStream.app"
echo "    ~/Library/LaunchAgents/com.sourcestream.server.plist"
echo "    ~/Desktop/SourceStream.app"
echo "    Crontab entry for backup_engine / sourcestream"
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
    'SourceStream  --  Smart backups. Zero friction.  v1.0.11' \
    '=========================================================' \
    '' \
    'QUICK INSTALL (Recommended)' \
    '----------------------------' \
    '1. Double-click "Install SourceStream.command" in this window' \
    '2. A Terminal opens and runs the full installer automatically' \
    '3. When done, ~/Desktop/SourceStream.app opens the dashboard' \
    '' \
    'UPDATE / REINSTALL' \
    '------------------' \
    'Run "Install SourceStream.command" again — it safely detects an' \
    'existing install and merges new config keys WITHOUT overwriting' \
    'your existing settings, sources, destinations, or cron schedule.' \
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
    'CONFIG FILE' \
    '-----------' \
    '~/.sourcestream/config/sourcestream.conf' \
    'All settings, sources, destinations, and exclude patterns.' \
    'Edit via Dashboard → Settings, or directly in any text editor.' \
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
mkdir -p "$DIST_DIR"
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
echo "     • SourceStream.app                  — drag to /Applications"
echo "     • Install SourceStream.command       — preferred: double-click to fully install"
echo "     • Uninstall SourceStream.command     — full cleanup"
echo "     • README.txt"
echo ""
echo "   To install:  open $DMG_OUT"
echo "                then double-click 'Install SourceStream.command'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
