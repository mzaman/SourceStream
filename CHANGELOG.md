# Changelog

All notable changes to SourceStream are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) · Versioning: [SemVer](https://semver.org/)

---

## [1.0.0] — 2026-11-09

### Added
- **Native macOS `.app` bundle** (`SourceStream.app`) with proper `Info.plist`
  - `LSUIElement = YES` — runs as background agent with no Dock icon
  - Proper `CFBundleIdentifier`: `com.sourcestream.app`
- **Distributable `SourceStream-1.0.0.dmg`** with drag-to-Applications UX
  - Automated `build/build_dmg.sh` pipeline with pre-flight syntax checks
- **Full-featured dark-themed web dashboard** (7 pages at `http://127.0.0.1:7474/`)
  - 📊 Dashboard: live status cards, progress ring, archive list, activity log
  - 🚀 Run Backup: animated shimmer progress bar with %, MB display, cancel button
  - 🗄 Archives: sortable table with size, age, destination columns
  - 📋 Logs: tabbed output/error log viewer with auto-refresh
  - 🏥 Health Check: script/drive/cron/SSD status grid with badges
  - ⏰ Schedule: preset buttons + custom cron expression editor
  - ⚙️ Settings: source/destination manager with 📂 native browse buttons
- **LaunchAgent** (`com.sourcestream.server.plist`) for auto-start at login
  - `KeepAlive = true` — server restarts automatically on crash
  - Stamped with real Python and server paths on first launch
- **Real-time backup progress** polling `/api/progress` every 2 seconds
  - File-size growth tracking via `os.path.getsize()` on the live archive file
  - Fallback elapsed-time estimation (~200 MB/min compressed throughput)
  - Buttons disabled while backup runs; re-enabled on completion
- **Folder browse buttons** via macOS native `osascript choose folder`
  - Auto-fills label field from folder basename
- **macOS Glass notification** on backup completion (opt-in via "Run + Notify")
- **Complete uninstaller** (`build/Uninstall SourceStream.sh`)
  - Removes LaunchAgent, cron entry, app bundle
  - Optionally removes `~/.sourcestream/` user data

### Fixed
- **bsdtar socket archiving** — `--format=gnutar` avoids "pax format cannot archive socket" on `.git/fsmonitor--daemon.ipc`
- **Extended attribute errors** — `--no-xattrs` suppresses "Could not pack extended attributes: Operation not supported"
- **`--exclude` flag order** — macOS bsdtar requires all `--exclude` before `-czf`; reordered correctly
- **AppleScript `PORT` keyword collision** — `PORT` is reserved in AppleScript (`«class ppor»` error); renamed to `serverPort`
- **Tar exit-code semantics** — exit 1 means files changed during archiving (normal for live git repos); treated as WARN not ERROR
- **`fsmonitor` socket exclusion** — added `--exclude="*.ipc"` to TAR_EXCLUDES
- **Server path typo** — removed broken `Out_log_fallback` walrus-operator syntax from previous session

### Architecture
- User data at `~/.sourcestream/` (preserved across app bundle updates)
- Config: `~/.sourcestream/config/sourcestream.conf`
- Logs: `~/.sourcestream/logs/{backup,error,server}.log`
- Server binds to `127.0.0.1:7474` only — not network-exposed
- Zero SSD footprint in direct mode (streams tar directly to Drive filesystem mount)
- Multi-source, multi-destination with automatic staging fallback
- Retention policy: keeps N most recent archives, prunes oldest automatically

---

## [Unreleased]

### Planned
- Code-signing support (`codesign --deep`) for Gatekeeper compatibility
- `pkg` installer alternative to DMG
- Multiple Google Drive accounts support
- S3 / Backblaze B2 destination support
- Incremental backup mode (rsync-style, without rsync)
- Menu bar icon (NSStatusItem) via PyObjC
