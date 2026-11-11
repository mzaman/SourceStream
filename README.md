# SourceStream

> **v1.0.15** — Native macOS backup app with menu bar agent, incremental backup,
> and cloud remote destinations (S3 / B2 / rclone).

[![Version](https://img.shields.io/badge/version-1.0.15-blue)](CHANGELOG.md)
[![macOS](https://img.shields.io/badge/macOS-12%2B-lightgrey)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Overview

SourceStream is a lightweight, fully self-contained macOS backup application.
It runs as a **LaunchAgent** (no Dock icon required), exposes a **local REST
API** at `http://127.0.0.1:7474`, and serves a single-page **dashboard** you
open in any browser. A native **menu bar agent** shows live status and lets you
trigger backups from the menu bar.

Backups are **tar.gz** or **zip** archives written to one or more local or
network destinations, with optional **upload to S3 / Backblaze B2 / rclone**
after each run.

---

## Features

| Feature | Since |
|---------|-------|
| Local backup to multiple destinations | 1.0.0 |
| Google Drive auto-detect | 1.0.2 |
| Per-source & global excludes | 1.0.5 |
| Per-source retention (keep N archives) | 1.0.5 |
| Archive format: tar.gz / zip / both | 1.0.5 |
| Schedule (cron / launchd) | 1.0.3 |
| Dry-run mode | 1.0.3 |
| App icon + light/dark theme | 1.0.7 |
| Notification & verify-after-backup toggles | 1.0.7 |
| **Menu bar agent** (NSStatusBar) | **1.0.15** |
| **Incremental backup** (mtime-sentinel) | **1.0.15** |
| **Remote destinations** (S3 / B2 / rclone) | **1.0.15** |

---

## Requirements

- macOS 12 Monterey or later
- Python 3.9+ (bundled with macOS)
- `bsdtar` (bundled with macOS via libarchive)
- **Menu bar agent only:** `pip3 install pyobjc-framework-Cocoa`
- **Remote S3:** `brew install awscli && aws configure`
- **Remote B2:** `brew install b2-tools && b2 authorize-account`
- **Remote rclone:** `brew install rclone && rclone config`

---

## Installation

### From DMG (recommended)

```bash
# Download SourceStream-1.0.15.dmg, then:
open SourceStream-1.0.15.dmg
# Drag SourceStream.app to /Applications, then:
bash /Applications/SourceStream.app/Contents/Resources/../../../install.sh
```

### From source

```bash
git clone https://github.com/yourname/SourceStream.git
cd SourceStream
bash build/install.sh
```

`install.sh` will:
1. Copy `SourceStream.app` to `/Applications`
2. Install and load `com.sourcestream.server.plist` LaunchAgent (auto-start at login)
3. Install `com.sourcestream.menubar.plist` LaunchAgent (if PyObjC available)
4. Migrate existing config keys
5. Compile the Desktop launcher
6. Run health check at `http://127.0.0.1:7474/api/health`

### Open Dashboard

```
open http://127.0.0.1:7474
```

Or click the **⚡ SourceStream** menu bar icon → **Open Dashboard**.

---

## Configuration

Config is stored at `~/.sourcestream/config/sourcestream.conf` — **never** inside
the app bundle. It is an INI-style file managed entirely through the dashboard.

### Example config

```ini
[settings]
MAX_ARCHIVES=10
ARCHIVE_FORMAT=tar
BACKUP_MODE=incremental
NOTIFY=true
VERIFY_AFTER_BACKUP=true

[sources]
/Users/alice/Documents|Documents|5
/Users/alice/Projects|Projects

[destinations]
/Volumes/MyDrive/Backups
/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/Backups

[excludes]
node_modules
.git
__pycache__
.DS_Store

[source_excludes]
Documents = Downloads, Trash
Projects = node_modules, dist, .next

[remote_destinations]
s3://my-bucket/sourcestream|AWS S3
rclone:gdrive:Backups|Google Drive (rclone)
```

### Source entry format

`path|label|retention` — `label` and `retention` are optional.

```
/Users/alice/Documents|Documents|5
```

Keeps 5 archives for this source (overrides global `MAX_ARCHIVES`).

---

## Backup Modes

### Full backup (default)

Every run archives **all files** in each source directory.

```ini
BACKUP_MODE=full
```

### Incremental backup

Only files **changed since the last run** are archived. Uses `--newer-mtime`
for tar and `find -newer` for zip. Skips the run entirely if nothing changed.

```ini
BACKUP_MODE=incremental
```

Manifests (last-backup sentinel files) are stored in `~/.sourcestream/manifests/`.

**Reset a manifest** (force full run next time):

```bash
curl -X POST http://127.0.0.1:7474/api/incremental/reset \
  -H "Content-Type: application/json" -d '{"label":"Documents"}'
```

Or use the **Reset** button on the dashboard Incremental panel.

---

## Remote Destinations

After every successful local backup, SourceStream can upload the archive to
cloud storage. Supported schemes:

| Scheme | CLI | Setup |
|--------|-----|-------|
| `s3://bucket/path` | `aws` | `brew install awscli` → `aws configure` |
| `b2://bucket/path` | `b2` | `brew install b2-tools` → `b2 authorize-account` |
| `rclone:remote:path` | `rclone` | `brew install rclone` → `rclone config` |

### Add via dashboard

Go to **☁️ Remote Dests** → enter URI and label → **Add Destination**.

### Add via API

```bash
curl -X POST http://127.0.0.1:7474/api/remote-dests/add \
  -H "Content-Type: application/json" \
  -d '{"uri":"s3://my-bucket/backups","label":"My S3"}'
```

### Test CLI availability

```bash
curl -X POST http://127.0.0.1:7474/api/remote-dests/test \
  -H "Content-Type: application/json" -d '{"scheme":"s3"}'
```

---

## Menu Bar Agent

The menu bar agent (`menubar_agent.py`) runs as a separate LaunchAgent
(`com.sourcestream.menubar.plist`) and shows live backup status in the macOS
menu bar.

**Icons:**
| Icon | Meaning |
|------|---------|
| ⚡ | Idle / ready |
| ⏳ | Backup running |
| ✅ | Last backup succeeded |
| ⚠️ | Last backup had warnings |
| 🔌 | Server offline |

**Menu items:** Run Backup · Cancel · Open Dashboard · Quit

### Install PyObjC

```bash
pip3 install pyobjc-framework-Cocoa
# Then restart the menu bar agent:
launchctl unload ~/Library/LaunchAgents/com.sourcestream.menubar.plist
launchctl load ~/Library/LaunchAgents/com.sourcestream.menubar.plist
```

---

## REST API

Base URL: `http://127.0.0.1:7474`

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | App version, uptime |
| GET | `/api/status` | Current backup status |
| GET | `/api/config` | Full config (settings, sources, dests, excludes, remote_destinations) |
| POST | `/api/config` | Save config |
| POST | `/api/backup/start` | Start a backup run |
| POST | `/api/backup/cancel` | Cancel running backup |
| GET | `/api/dry-run` | Count changed files without archiving |
| GET | `/api/archives` | List archives per destination |
| POST | `/api/archives/delete` | Delete an archive |
| GET | `/api/logs` | Last 200 lines of backup.log |
| GET | `/api/incremental/status` | Per-source manifest info |
| POST | `/api/incremental/reset` | Reset manifests (all or by label) |
| GET | `/api/remote-dests` | List remote destinations |
| POST | `/api/remote-dests/add` | Add remote destination |
| POST | `/api/remote-dests/remove` | Remove remote destination |
| POST | `/api/remote-dests/test` | Test CLI for scheme (s3/b2/rclone) |

---

## Architecture

```
SourceStream.app/
├── Contents/
│   ├── Info.plist                           # CFBundleVersion = 1.0.15
│   ├── MacOS/
│   │   └── SourceStream                     # Launcher shell script
│   ├── Library/
│   │   └── LaunchAgents/
│   │       ├── com.sourcestream.server.plist
│   │       └── com.sourcestream.menubar.plist
│   └── Resources/
│       ├── server.py          # HTTP server — 127.0.0.1:7474
│       ├── app.html           # Single-page dashboard (10 pages)
│       ├── backup_engine.sh   # Backup logic (bsdtar + zip)
│       ├── menubar_agent.py   # NSStatusBar agent (PyObjC)
│       └── AppIcon.icns

~/.sourcestream/
├── config/
│   └── sourcestream.conf      # User config (INI)
├── logs/
│   ├── backup.log
│   ├── server.log
│   └── menubar.log
├── manifests/
│   ├── Documents.manifest     # Last-backup timestamp
│   ├── Documents.mtime        # Sentinel file for --newer-mtime
│   └── ...
└── status.json                # Live backup progress
```

---

## Build DMG

```bash
cd /path/to/SourceStream
bash build/build_dmg.sh
# Output: dist/SourceStream-1.0.15.dmg
```

---

## Uninstall

```bash
bash "/Applications/SourceStream.app/Contents/Resources/../../../Uninstall SourceStream.sh"
```

This stops and removes both LaunchAgents, removes `/Applications/SourceStream.app`,
and optionally removes `~/.sourcestream/` user data.

---

## Key Constraints

- Port is always `127.0.0.1:7474` — never `0.0.0.0`
- Config is always `~/.sourcestream/config/sourcestream.conf` — never inside bundle
- bsdtar: `--exclude` flags placed **before** `-czf` (bsdtar requirement)
- `COPYFILE_DISABLE=1` always exported before `tar` calls
- `--format=gnutar --no-xattrs` to avoid macOS extended attribute errors
- tar exit code 1 = WARN (files changed during archiving is normal)
- Bash 3.2 compatible (no `readarray`, no `declare -A`)

---

## License

MIT © 2026 Masud Uz Zaman. See [LICENSE](LICENSE).
