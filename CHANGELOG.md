# Changelog — SourceStream

All notable changes to this project will be documented in this file.
Format follows [Conventional Commits](https://www.conventionalcommits.org/).

---

## [1.0.1] — 2026-11-09

### Fixed
- **Critical**: Killed old `com.devvault.server` LaunchAgent that was stealing
  port 7474 and serving stale DevVault HTML/config — root cause of "offline after
  refresh" and old branding showing in dashboard
- **LaunchAgent plist** was pointing to `/Applications/SourceStream.app` before
  the app was installed there; corrected to point to dev path
  `~/Developer/SourceStream/SourceStream.app` during development
- **Config file** `~/.sourcestream/config/sourcestream.conf` had old DevVault
  header comments; replaced with SourceStream-branded headers
- **Dashboard cards** were empty because `status.json` didn't exist; seeded with
  real archive data from Google Drive
- **Desktop launcher** rebuilt as proper compiled AppleScript `.app` (old
  "Backup Control Wizard.app" removed)

### Added
- `build/install.sh` — full installer: copies to `/Applications`, stamps and
  loads LaunchAgent, compiles Desktop launcher, runs health check
- LaunchAgent template now uses `__RES_DIR__` placeholder (alongside existing
  `__PYTHON__`, `__SERVER_PY__`, `__LOGS_DIR__`)
- Desktop `SourceStream.app` auto-starts server via LaunchAgent if not running,
  then opens dashboard in Chrome app-mode (1400×860 window)

---

## [1.0.0] — 2026-11-09

### Added
- Initial SourceStream app bundle (`SourceStream.app`)
- Python REST server (`server.py`) binding `127.0.0.1:7474`
- Full-featured dark dashboard (`app.html`) with 7 pages:
  Dashboard, Run Backup, Archives, Logs, Health, Schedule, Settings
- Backup engine (`backup_engine.sh`) with gnutar format, xattr stripping,
  socket exclusion, and progress tracking to `status.json`
- LaunchAgent (`com.sourcestream.server.plist`) with KeepAlive
- DMG builder (`build/build_dmg.sh`)
- Uninstall script (`build/Uninstall SourceStream.sh`)
- Git repo with branches: main, develop, feature/icon-and-codesigning,
  feature/menu-bar-agent, feature/incremental-backup, feature/s3-b2-destinations,
  fix/gatekeeper-quarantine
- README, LICENSE (MIT), .gitignore, .gitattributes, CHANGELOG

### Key Decisions
- Config at `~/.sourcestream/config/sourcestream.conf` (never inside bundle)
- Port `127.0.0.1:7474` (never 0.0.0.0)
- bsdtar `--format=gnutar --no-xattrs --exclude=*.ipc` to avoid macOS socket errors
- tar exit 1 treated as WARN (files changed during archiving = normal for live repos)
- AppleScript uses `serverPort` variable (not `PORT` — reserved keyword)
