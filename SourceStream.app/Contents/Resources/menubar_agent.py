#!/usr/bin/env python3
"""
SourceStream Menu Bar Agent  v1.0.8
SourceStream.app/Contents/Resources/menubar_agent.py

Native macOS menu bar icon using only stdlib (AppKit via PyObjC which ships
with macOS). No third-party dependencies.

Shows:
  • Live backup status (idle / running / error) in the menu bar icon label
  • Last backup time and result
  • Run Backup Now / Cancel
  • Open Dashboard (opens http://127.0.0.1:7474/ in browser)
  • Schedule summary
  • Quick toggles for key settings

Launched by: com.sourcestream.menubar LaunchAgent (KeepAlive=false,
             RunAtLoad=true) so it appears at login.

Falls back gracefully if PyObjC / AppKit is unavailable (logs and exits).
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────
PORT        = 7474
API_BASE    = f"http://127.0.0.1:{PORT}"
SS_DIR      = Path.home() / ".sourcestream"
STATUS_JSON = SS_DIR / "status.json"
LOG_DIR     = SS_DIR / "logs"
APP_RES     = Path(__file__).parent   # …/SourceStream.app/Contents/Resources/
SCRIPT      = APP_RES / "backup_engine.sh"
POLL_SEC    = 15   # how often to refresh status when idle
POLL_RUN    = 3    # how often to refresh while backup is running

# ── Status icons (text-based, no image required) ──────────────────────────────
ICON_IDLE    = "⚡"
ICON_RUNNING = "⏳"
ICON_OK      = "✅"
ICON_ERROR   = "⚠️"
ICON_OFFLINE = "🔌"


# ─────────────────────────────────────────────────────────────────────────────
# API helpers
# ─────────────────────────────────────────────────────────────────────────────

def _api_get(endpoint: str, timeout: int = 5) -> dict:
    try:
        with urllib.request.urlopen(f"{API_BASE}{endpoint}", timeout=timeout) as r:
            return json.loads(r.read())
    except Exception:
        return {}


def _api_post(endpoint: str, body: dict | None = None, timeout: int = 10) -> dict:
    try:
        data = json.dumps(body or {}).encode()
        req  = urllib.request.Request(
            f"{API_BASE}{endpoint}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _server_alive() -> bool:
    return bool(_api_get("/api/health"))


def _get_status() -> dict:
    return _api_get("/api/status") or {}


# ─────────────────────────────────────────────────────────────────────────────
# PyObjC / AppKit guard
# ─────────────────────────────────────────────────────────────────────────────

def _require_appkit():
    """Return (NSStatusBar, NSMenu, NSMenuItem, NSApp, NSObject) or None."""
    try:
        import AppKit
        import Foundation
        import objc
        return AppKit, Foundation, objc
    except ImportError:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# Menu bar implementation (PyObjC)
# ─────────────────────────────────────────────────────────────────────────────

def run_menu_bar():
    """Run the native NSStatusBar menu bar agent via PyObjC."""
    mods = _require_appkit()
    if mods is None:
        print("[SourceStream menubar] PyObjC not available — menu bar agent cannot start.")
        print("  Install: pip3 install pyobjc-framework-Cocoa")
        sys.exit(0)   # exit cleanly so LaunchAgent doesn't loop

    AppKit, Foundation, objc = mods

    class SourceStreamApp(AppKit.NSObject):
        """Cocoa delegate / controller for the status bar item."""

        def applicationDidFinishLaunching_(self, _notification):
            self._backup_running = False
            self._last_status    = "unknown"
            self._server_up      = False

            # Status bar item
            self._status_item = (
                AppKit.NSStatusBar.systemStatusBar()
                .statusItemWithLength_(AppKit.NSVariableStatusItemLength)
            )
            self._status_item.setHighlightMode_(True)

            # Build initial menu
            self._build_menu()
            self._update_icon()

            # Start background polling thread
            t = threading.Thread(target=self._poll_loop, daemon=True)
            t.start()

        # ── Menu construction ─────────────────────────────────────────────────

        def _build_menu(self):
            menu = AppKit.NSMenu.alloc().init()

            # Status line (non-clickable header)
            self._status_item_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "⚡ SourceStream", None, ""
            )
            self._status_item_mi.setEnabled_(False)
            menu.addItem_(self._status_item_mi)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # Last backup info
            self._last_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Last backup: —", None, ""
            )
            self._last_mi.setEnabled_(False)
            menu.addItem_(self._last_mi)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # Actions
            run_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "▶  Run Backup Now", "runBackup:", ""
            )
            run_mi.setTarget_(self)
            menu.addItem_(run_mi)
            self._run_mi = run_mi

            cancel_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "⏹  Cancel Backup", "cancelBackup:", ""
            )
            cancel_mi.setTarget_(self)
            cancel_mi.setEnabled_(False)
            menu.addItem_(cancel_mi)
            self._cancel_mi = cancel_mi

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            open_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "🌐  Open Dashboard", "openDashboard:", ""
            )
            open_mi.setTarget_(self)
            menu.addItem_(open_mi)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            # View logs
            logs_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "📋  View Logs", "openLogs:", ""
            )
            logs_mi.setTarget_(self)
            menu.addItem_(logs_mi)

            # Preferences shortcut
            prefs_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "⚙️  Preferences", "openPrefs:", ""
            )
            prefs_mi.setTarget_(self)
            menu.addItem_(prefs_mi)

            menu.addItem_(AppKit.NSMenuItem.separatorItem())

            quit_mi = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Quit Menu Bar Agent", "quitAgent:", "q"
            )
            quit_mi.setTarget_(self)
            menu.addItem_(quit_mi)

            self._status_item.setMenu_(menu)

        # ── Icon / label update ───────────────────────────────────────────────

        def _update_icon(self, state: str = "idle"):
            icon_map = {
                "running": ICON_RUNNING,
                "error":   ICON_ERROR,
                "offline": ICON_OFFLINE,
                "ok":      ICON_OK,
                "idle":    ICON_IDLE,
            }
            icon = icon_map.get(state, ICON_IDLE)
            # Use button title for text-only icon (works without image asset)
            btn = self._status_item.button()
            if btn:
                btn.setTitle_(icon)

        def _update_menu_state(self, status_data: dict):
            st     = status_data.get("status", "unknown")
            last_t = status_data.get("last_run_at", "") or status_data.get("last_backup", "")
            is_running = (st == "running")

            self._backup_running = is_running
            self._last_status    = st

            # Header
            label = f"⚡ SourceStream  [{st}]"
            self._status_item_mi.setTitle_(label)

            # Last backup line
            if last_t:
                self._last_mi.setTitle_(f"Last: {last_t[:16]}  ({st})")
            else:
                self._last_mi.setTitle_("Last backup: never")

            # Run / cancel buttons
            self._run_mi.setEnabled_(not is_running and self._server_up)
            self._cancel_mi.setEnabled_(is_running)

            # Icon
            if not self._server_up:
                self._update_icon("offline")
            elif is_running:
                self._update_icon("running")
            elif st in ("error", "ERROR"):
                self._update_icon("error")
            elif st in ("SUCCESS", "success", "ok"):
                self._update_icon("ok")
            else:
                self._update_icon("idle")

        # ── Background polling ────────────────────────────────────────────────

        def _poll_loop(self):
            while True:
                self._server_up = _server_alive()
                if self._server_up:
                    data = _get_status()
                    # Update UI on main thread
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "applyStatus:", data, False
                    )
                else:
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "applyStatus:", {}, False
                    )
                interval = POLL_RUN if self._backup_running else POLL_SEC
                time.sleep(interval)

        def applyStatus_(self, data):
            """Called on main thread with fresh status dict."""
            self._update_menu_state(data)

        # ── Actions ───────────────────────────────────────────────────────────

        def runBackup_(self, _sender):
            """Trigger a full backup via API (non-blocking)."""
            def _run():
                result = _api_post("/api/run-backup", {"notify": True})
                ok = result.get("ok", False)
                msg = "Backup started." if ok else f"Could not start: {result.get('error','?')}"
                self._notify("SourceStream", msg)
            threading.Thread(target=_run, daemon=True).start()
            # Immediately flip icon to running so it feels responsive
            self._update_icon("running")
            self._run_mi.setEnabled_(False)
            self._cancel_mi.setEnabled_(True)

        def cancelBackup_(self, _sender):
            """Cancel the running backup."""
            def _cancel():
                _api_post("/api/cancel-backup")
            threading.Thread(target=_cancel, daemon=True).start()
            self._update_icon("idle")

        def openDashboard_(self, _sender):
            subprocess.Popen(["open", f"{API_BASE}/"])

        def openLogs_(self, _sender):
            """Open the Dashboard at the Logs panel."""
            subprocess.Popen(["open", f"{API_BASE}/#logs"])

        def openPrefs_(self, _sender):
            """Open the Dashboard at the Preferences panel."""
            subprocess.Popen(["open", f"{API_BASE}/#prefs"])

        def quitAgent_(self, _sender):
            AppKit.NSApp.terminate_(None)

        # ── Helpers ───────────────────────────────────────────────────────────

        def _notify(self, title: str, msg: str):
            """Send a macOS notification via osascript."""
            try:
                subprocess.Popen(
                    ["osascript", "-e",
                     f'display notification "{msg}" with title "{title}" sound name "Glass"'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
            except Exception:
                pass

    # ── Bootstrap NSApp ───────────────────────────────────────────────────────
    app  = AppKit.NSApplication.sharedApplication()
    app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)  # no Dock icon
    delegate = SourceStreamApp.alloc().init()
    app.setDelegate_(delegate)
    app.run()


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    run_menu_bar()

