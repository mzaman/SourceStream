# Changelog — SourceStream

All notable changes to this project will be documented in this file.
Format follows [Conventional Commits](https://www.conventionalcommits.org/).

---

## [1.0.14] — 2026-11-12

### Fixed
- **Scheduling shows "cron not set"** — LaunchAgent sandbox cannot read user crontab.
  Now uses a dedicated `com.sourcestream.backup.plist` with `StartCalendarInterval`.
  `/api/schedule` writes/reads launchd plist; `/api/health` checks plist first, falls
  back to crontab. Schedule now persists and shows correctly after app restart.
- **Archive size always "0 MB"** — `int()` rounded small archives (<1 MB) to zero.
  Now returns both `size_bytes` (int) and `size_mb` (float, 2 decimal places).
  Frontend uses `fmtBytes()` for accurate B/KB/MB/GB display.

### Added
- **Archive table: sortable columns** — click Name / Size / Created / Age headers to
  toggle ascending / descending order.
- **Archive table: pagination** — 10 / 25 / 50 / All per page; Prev / Next / page-number
  buttons. Preserves sort state across page changes.
- **Reveal in Finder** — 📂 button per archive row opens Finder via `open -R` through
  new POST `/api/archive-reveal` endpoint.
- **Policies page** — Kopia-inspired policy system:
  - Global Policy (`*`) covers all sources and cannot be deleted.
  - Per-path policies inherit from Global; only explicitly set fields are stored.
  - Sections: Retention, Files, Error Handling, Compression, Scheduling, Actions.
  - Unset fields show "Defined by [Global Policy]"; set fields show "Defined by this policy".
  - Stored as `[policy:PATH]` sections in `~/.sourcestream/config/sourcestream.conf`.
  - APIs: `GET /api/policies`, `GET /api/policies/resolve?path=`,
    `POST /api/policies/save`, `POST /api/policies/delete`.
- **`fmtBytes()` utility** — displays archive sizes as B / KB / MB / GB.

### Changed
- Bumped `APP_VERSION` to 1.0.14 across server, menubar agent, Info.plist, installer,
  build script, README, and CHANGELOG.

---


## [1.0.13] — 2026-11-11

### Fixed
- **Archive page empty** — Python 3.12+ `UnboundLocalError` on `datetime` module name.
  Local `import datetime` inside `/api/next-run` and `/api/archive-trend` handlers
  shadowed the module-level `datetime` import, causing `/api/archives` to silently
  return `[]`. Fixed by removing redundant local imports (module-level import used
  throughout the method).
- **Zip output flooding log** — Added `-q` (quiet) flag to both `zip` invocations in
  `backup_engine.sh`. `adding: ...` lines no longer written to `backup.log`.
- **Default archive format** — `DEFAULT_SETTINGS` in `server.py` now correctly defaults
  to `zip` (was `tar.gz`), matching the actual engine default and config.

### Changed
- Bumped `APP_VERSION` to `1.0.13` in `server.py`, `menubar_agent.py`, `Info.plist`,
  `build/build_dmg.sh`, `build/install.sh`, and `README.md`.

---

## [1.0.12] — 2026-11-11

### Fixed
- **Retention pruned NEWEST archive** — `ls -1t | head -n EXCESS` returned the most
  recent archives; changed to `ls -1t | tail -n EXCESS` to correctly remove oldest.
- **"tar exit 1" message shown for zip runs** — log message is now format-aware
  (`zip exit 1` shown for zip archives, `tar exit 1` for tar).

---

## [1.0.11] — 2026-11-11

### Fixed
- **EXIT trap deleted successful archives** — `STAGE_PATH` was never removed from
  `_PARTIAL_FILES` on success; added explicit removal so trap only cleans up
  genuinely partial (failed) archives.
- **Full Disk Access prompt at install** — `build_dmg.sh` installer now shows an
  `osascript` dialog with an "Open Privacy Settings" button after setup.
- **`Developer Backups` hardcoded** — renamed to `SourceStream Backups` in engine,
  server, and config migration.
- **Archive format default** — changed engine default from `tar.gz` to `zip`; updated
  installer config and migration script.
- **Build script version** — `build_dmg.sh` and `install.sh` bumped to 1.0.11.

---

## [1.0.10] — 2026-11-11

### Fixed
- **`.fcpcache → .` symlink infinite loop** — `zip -r` followed the `.fcpcache`
  symlink recursively. Fixed with `zip -r -y` (store symlinks) + `find -P` +
  `--exclude=".fcpcache"`.
- **Permission denied silent** — engine now shows `osascript` dialog with
  "Open Privacy Settings" button when a source folder is inaccessible.
- **Double log lines** — `log_msg`/`log_err` used `tee -a OUTPUT_LOG` while the
  wrapper also redirected stdout to the log; removed the redundant `tee`.

---

## [1.0.9] — 2026-11-11

### Fixed
- **`Movies}_...zip` stray `}` in archive name** — `${ARCHIVE_PREFIX:-{label}}`
  Bash 3.2 expansion ambiguity; fixed with explicit empty-check guard (`_PFX`).

---

## [1.0.8] — 2026-11-11

### Added
- **Menu Bar Agent** (`menubar_agent.py`) — native macOS NSStatusBar agent via
  PyObjC/AppKit. Shows ⚡/⏳/✅/⚠️/🔌 icon, Run Backup / Cancel / Open Dashboard
  menu items. No Dock icon (`NSApplicationActivationPolicyAccessory`). Exits
  gracefully if PyObjC is unavailable.
- `com.sourcestream.menubar.plist` LaunchAgent — auto-starts menu bar agent
  at login (KeepAlive=false). Logs to `~/.sourcestream/logs/menubar.log`.
- **Incremental backup mode** — mtime-sentinel based changed-file detection.
  Uses `--newer-mtime` for tar and `find -newer` for zip. Skips backup if no
  files changed since last run. Manifests stored in `~/.sourcestream/manifests/`.
- **Remote Destinations** — upload archives to S3/B2/rclone after each local
  backup. Schemes: `s3://`, `b2://`, `rclone:`. Upload via `aws s3 cp`,
  `b2 file upload-file`, or `rclone copy`. Graceful fallback if CLI not found.
- `[remote_destinations]` config section in `sourcestream.conf`.
- API endpoints: `/api/incremental/status` (GET), `/api/incremental/reset` (POST),
  `/api/remote-dests` (GET), `/api/remote-dests/add` (POST),
  `/api/remote-dests/remove` (POST), `/api/remote-dests/test` (POST).
- Dashboard "☁️ Remote Dests" page — list, add, remove remotes; CLI setup guide.
- Dashboard Incremental Backup panel — per-source manifest status and reset buttons.
- Backup Mode selector (Full / Incremental) in Preferences.
- `BACKUP_MODE` key added to config and migration list.
- `install.sh` step 8b: installs `com.sourcestream.menubar.plist`.
- `build_dmg.sh` now `chmod +x`s `menubar_agent.py`.

### Fixed
- `parse_conf()` returns 6 values (adds `remote_dests`); all 20+ call sites updated.
- `/api/remote-dests` and `/api/incremental/status` correctly placed in `do_GET`.
- `_CodeSignature/` added to `.gitignore` — auto-generated by codesign, never commit.

---

## [1.0.7] — 2026-11-10

### Added
- Custom app icon (`AppIcon.icns`) — lightning bolt in blue gradient.
- Light/dark theme toggle (☀️/🌙) persisted to `localStorage`.
- Notification toggle (🔔/🔕) in Settings — controls macOS `osascript` alerts.
- Verify-after-backup toggle — runs `bsdtar -tzf` on each archive and reports
  integrity result.
- Clear-errors button on Health page — wipes `error_log.txt`.

### Fixed
- Icon correctly embedded in `Info.plist` via `CFBundleIconFile`.
- Ad-hoc codesign in `build_dmg.sh` hardened with `--deep` flag.

---

## [1.0.6] — 2026-11-10

### Fixed
- Archive format selection (tar.gz / zip / both) — zip branch previously skipped
  when only `zip` was selected; fixed with explicit format guard.
- Delete archive button (🗑️) now works for both `.tar.gz` and `.zip` extensions.
- `COPYFILE_DISABLE=1` exported before all tar/zip calls to suppress macOS metadata.

### Added
- "Both" archive format — produces `.tar.gz` and `.zip` side-by-side.
- Delete archive endpoint (`/api/archives/delete`) with confirmation dialog.

---

## [1.0.5] — 2026-11-10

### Added
- **Per-source retention** — each source can override the global `MAX_ARCHIVES`
  with its own `retention` pipe-field (`path|label|retention`).
- **Bulk excludes** — multiple paths in the global `[excludes]` section.
- **Per-source excludes** — `[source_excludes]` section with
  `source_label = path1, path2` format.
- **Archive format selection** — `ARCHIVE_FORMAT` setting (`tar`, `zip`, `both`).
- Global and per-source exclude policies in dashboard Settings page.
- `parse_conf()` returns `excludes` and `source_excludes` lists.
- `write_conf()` accepts and persists both exclude sections.

### Fixed
- Integer safety: all shell numeric vars passed through `tr -cd '0-9'` and
  `$(( ${VAR:-0} + 0 ))` to prevent arithmetic errors from embedded newlines.
- bsdtar: `--exclude` flags always placed before `-czf` per bsdtar requirement.
- `COPYFILE_DISABLE=1` exported at top of `backup_engine.sh` (was missing).

---

## [1.0.4] — 2026-11-09

### Added
- `build/build_dmg.sh` version bump automation.
- Destinations count badge on Archives page.

### Fixed
- DMG build failing on missing `hdiutil` output path.

---

## [1.0.3] — 2026-11-09

### Added
- Schedule page with cron expression builder and launchd plist generation.
- Dry-run mode — counts files to archive without writing; endpoint `/api/dry-run`.
- Cancel backup button — kills the running `backup_engine.sh` PID.

### Fixed
- `/api/status` polling skipped while a backup is not running (saves CPU).
- Status badge correctly shows ⏳ during backup and ✅/⚠️ after.

---

## [1.0.2] — 2026-11-09

### Added
- **Multiple destinations** — `[destinations]` section supports one path per line;
  archive is copied to each after the primary backup.
- Google Drive auto-detect via `GoogleDrive-*/My Drive` glob.
- Archives page with size, date, download link, per-destination listing.
- Health page — shows disk usage per destination, error log tail.
- Logs page — streams `backup.log` tail via `/api/logs`.

### Fixed
- Server no longer hardcodes "Developer_Backup" label — derives from source label.
- `backup_engine.sh` exits cleanly when no sources are configured.

---

## [1.0.1] — 2026-11-09

### Fixed
- **Critical**: Killed old `com.devvault.server` LaunchAgent that was stealing
  port 7474 and serving stale DevVault HTML/config — root cause of "offline after
  refresh" and old branding showing in dashboard.
- **LaunchAgent plist** was pointing to `/Applications/SourceStream.app` before
  the app was installed there; corrected to point to dev path
  `~/Developer/SourceStream/SourceStream.app` during development.
- **Config file** `~/.sourcestream/config/sourcestream.conf` had old DevVault
  header comments; replaced with SourceStream-branded headers.
- **Dashboard cards** were empty because `status.json` didn't exist; seeded with
  real archive data from Google Drive.
- **Desktop launcher** rebuilt as proper compiled AppleScript `.app` (old
  "Backup Control Wizard.app" removed).

### Added
- `build/install.sh` — full installer: copies to `/Applications`, stamps and
  loads LaunchAgent, compiles Desktop launcher, runs health check.
- LaunchAgent template now uses `__RES_DIR__` placeholder (alongside existing
  `__PYTHON__`, `__SERVER_PY__`, `__LOGS_DIR__`).
- Desktop `SourceStream.app` auto-starts server via LaunchAgent if not running,
  then opens dashboard in Chrome app-mode (1400×860 window).

---

## [1.0.0] — 2026-11-09

### Added
- Initial SourceStream app bundle (`SourceStream.app`).
- Python REST server (`server.py`) binding `127.0.0.1:7474`.
- Full-featured dark dashboard (`app.html`) with 7 pages:
  Dashboard, Run Backup, Archives, Logs, Health, Schedule, Settings.
- Backup engine (`backup_engine.sh`) with gnutar format, xattr stripping,
  socket exclusion, and progress tracking to `status.json`.
- LaunchAgent (`com.sourcestream.server.plist`) with KeepAlive.
- DMG builder (`build/build_dmg.sh`).
- Uninstall script (`build/Uninstall SourceStream.sh`).
- Git repo with branches: main, develop, feature/icon-and-codesigning,
  feature/menu-bar-agent, feature/incremental-backup, feature/s3-b2-destinations,
  fix/gatekeeper-quarantine.
- README, LICENSE (MIT), .gitignore, .gitattributes, CHANGELOG.

### Key Decisions
- Config at `~/.sourcestream/config/sourcestream.conf` (never inside bundle).
- Port `127.0.0.1:7474` (never 0.0.0.0).
- bsdtar `--format=gnutar --no-xattrs --exclude=*.ipc` to avoid macOS socket errors.
- tar exit 1 treated as WARN (files changed during archiving = normal for live repos).
- AppleScript uses `serverPort` variable (not `PORT` — reserved keyword).
