#!/bin/bash
# ==============================================================================
# Uninstall SourceStream.sh
# Double-click to run, or: bash "Uninstall SourceStream.sh"
# ==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑  SourceStream Uninstaller"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Confirm
read -r -p "This will remove SourceStream from your Mac. Continue? [y/N] " CONFIRM
[[ "$CONFIRM" != [yY] ]] && { echo "Cancelled."; exit 0; }

PLIST="$HOME/Library/LaunchAgents/com.sourcestream.server.plist"
APP="/Applications/SourceStream.app"

# 1 ── Stop and remove LaunchAgent ─────────────────────────────────────────────
echo ""
echo "⏹  Stopping background server..."
launchctl unload "$PLIST" 2>/dev/null && echo "   ✅ LaunchAgent unloaded" || echo "   ✓  (not running)"
rm -f "$PLIST" && echo "   ✅ Plist removed"

# 2 ── Remove cron entry ────────────────────────────────────────────────────────
echo ""
echo "⏰ Removing cron entry..."
(crontab -l 2>/dev/null | grep -v "backup_engine\|sourcestream") | crontab -
echo "   ✅ Cron entry removed"

# 3 ── Kill any running server/backup processes ─────────────────────────────────
pkill -f "server.py" 2>/dev/null || true
pkill -f "backup_engine.sh" 2>/dev/null || true
echo "   ✅ Background processes stopped"

# 4 ── Remove app bundle ────────────────────────────────────────────────────────
echo ""
echo "🗑  Removing /Applications/SourceStream.app..."
if [ -d "$APP" ]; then
    rm -rf "$APP" && echo "   ✅ App removed"
else
    echo "   ✓  (not installed in /Applications)"
fi

# 5 ── Optionally remove user data ─────────────────────────────────────────────
echo ""
read -r -p "Also delete logs and configuration? (~/.sourcestream/) [y/N] " DEL_DATA
if [[ "$DEL_DATA" == [yY] ]]; then
    rm -rf "$HOME/.sourcestream"
    echo "   ✅ User data removed (~/.sourcestream/)"
else
    echo "   ✓  Config and logs preserved at ~/.sourcestream/"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ SourceStream has been uninstalled."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

