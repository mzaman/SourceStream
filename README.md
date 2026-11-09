# SourceStream

> **Zero-SSD-bloat developer backup utility for macOS.**  
> Compress your code environments, strip build noise, and stream clean archives directly to Google Drive — with no permanent local disk usage.

[![macOS](https://img.shields.io/badge/macOS-12%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Python](https://img.shields.io/badge/Python-3.9%2B-blue?logo=python)](https://python.org)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-purple)](CHANGELOG.md)

---

## ✨ What It Does

SourceStream recursively compresses your developer folders (e.g. `~/Developer`) while **automatically excluding** all build artifacts, caches, and package directories that can be restored:

| Excluded (saves 60–90% size) | Kept (your real work) |
|---|---|
| `node_modules/`, `vendor/`, `bower_components/` | Source code |
| `.gradle/caches/`, `build/intermediates/` | Config files |
| `storage/framework/`, `Library/Caches/` | Git history |
| `*.tar.gz`, `*.zip` | Database seeds |
| `.git/objects/pack`, `*.ipc` | Documentation |

**Result:** A `~20 GB` developer folder typically archives to `~9 GB` (~55% reduction before cache exclusions).

---

## 🏗 Architecture

```
SourceStream.app/Contents/
├── MacOS/
│   └── SourceStream           ← Launcher: starts server, opens Chrome dashboard
├── Resources/
│   ├── backup_engine.sh       ← Core tar/gzip compression engine (Bash)
│   ├── server.py              ← REST API server (port 7474, localhost only)
│   └── app.html               ← Web dashboard SPA (dark theme, 7 pages)
└── Library/LaunchAgents/
    └── com.sourcestream.server.plist   ← LaunchAgent template

User data (preserved across app updates):
~/.sourcestream/
├── config/
│   └── sourcestream.conf      ← INI config: sources, destinations, settings
├── logs/
│   ├── backup.log             ← Backup engine output
│   ├── error.log              ← Errors and bsdtar warnings
│   └── server.log             ← Dashboard server log
└── status.json                ← Live backup status (polled by dashboard)
```

---

## 📦 Installation

### Option A — DMG Installer (recommended)

1. Download `SourceStream-1.0.0.dmg` from [Releases](../../releases)
2. Open the DMG
3. Drag **SourceStream.app** → **Applications**
4. Double-click `SourceStream` from Applications or Spotlight
5. The dashboard opens in Chrome automatically at `http://127.0.0.1:7474/`

### Option B — Build from Source

```bash
git clone https://github.com/yourusername/SourceStream.git
cd SourceStream
bash build/build_dmg.sh       # → dist/SourceStream-1.0.0.dmg
```

**Requirements:**
- macOS 12 Monterey or later
- Python 3.9+ (`/opt/homebrew/bin/python3` or `/usr/bin/python3`)
- Google Chrome (dashboard opens in app-mode)
- Google Drive desktop app (for direct-to-drive streaming)

---

## 🚀 Usage

### Open Dashboard
Double-click `SourceStream.app` → opens the live web dashboard

| Page | Purpose |
|------|---------|
| 📊 Dashboard | Live status, last run time, archive list, activity log |
| 🚀 Run Backup | Manual trigger with real-time progress bar |
| 🗄 Archives | Browse all archives: name, size, age, destination |
| 📋 Logs | Full output log and error log viewer |
| 🏥 Health Check | Verify drive mount, cron, permissions, free space |
| ⏰ Schedule | Set weekly/daily automated backup schedule |
| ⚙️ Settings | Add/remove source folders and destinations |

### Manual CLI Trigger

```bash
/Applications/SourceStream.app/Contents/Resources/backup_engine.sh
```

### Configuration File (`~/.sourcestream/config/sourcestream.conf`)

```ini
[settings]
DIRECT_TO_DRIVE=true        # 1× SSD usage — streams tar directly to Drive
MAX_ARCHIVES_TO_KEEP=3      # Retention count (0 = keep forever)

[sources]
/Users/masud/Developer|Developer    # /full/path|Display Label

[destinations]
/path/to/Google Drive/Developer Backups|Google Drive
```

---

## ⚙️ How It Works

### Compression Strategy

```
Direct mode (DIRECT_TO_DRIVE=true + single destination):
  Source ──► tar/gzip ──► Drive mount path
  SSD peak: ~0 bytes  ✅  (streams directly — no local copy)

Staging mode (multiple destinations OR DIRECT_TO_DRIVE=false):
  Source ──► tar/gzip ──► /tmp ──► copy to each destination ──► rm /tmp
  SSD peak: 1× compressed archive size
```

### macOS bsdtar — Key Flags

```bash
tar \
  --exclude="node_modules" \  # ← all --exclude flags MUST come before -czf
  --format=gnutar \           # ← avoids pax format; pax can't archive sockets
  --no-xattrs \               # ← skips macOS extended attributes
  -czf archive.tar.gz \
  source/
```

### Archive Naming Convention

```
{Label}_Backup_{YYYYMMDD_HHMMSS}.tar.gz
# e.g. Developer_Backup_20261109_230001.tar.gz
```

Each run creates a **new timestamped archive**. Previous archives are retained up to `MAX_ARCHIVES_TO_KEEP`, then oldest are pruned automatically.

### Progress Tracking

The dashboard polls `/api/progress` every 2 seconds while a backup runs:
1. **Primary:** reads `os.path.getsize()` on the live growing `.tar.gz` file
2. **Fallback:** estimates from elapsed time vs. ~200 MB/min compressed throughput

---

## 🔒 Security

- Server binds to `127.0.0.1:7474` only — **never exposed to your local network**
- No telemetry, no external network calls
- Config and logs in `~/.sourcestream/` — your data, your machine only
- `LSUIElement = YES` in `Info.plist` — no Dock icon, no visible app window

---

## 🗑 Uninstall

**Complete removal:**
```bash
bash "/Applications/SourceStream.app/Contents/build/Uninstall SourceStream.sh"
```

This removes:
- `/Applications/SourceStream.app`
- `~/Library/LaunchAgents/com.sourcestream.server.plist`
- Cron entry for `backup_engine.sh`
- Optionally: `~/.sourcestream/` (config + logs — you are prompted)

---

## 🛠 Development

### Project Structure

```
SourceStream/
├── SourceStream.app/           ← Native macOS app bundle
│   └── Contents/
│       ├── Info.plist          ← Bundle identity, LSUIElement
│       ├── MacOS/
│       │   └── SourceStream    ← Launcher (Bash stub)
│       ├── Resources/
│       │   ├── app.html        ← Dashboard SPA
│       │   ├── server.py       ← REST API (Python 3)
│       │   └── backup_engine.sh← Backup engine (Bash)
│       └── Library/LaunchAgents/
│           └── com.sourcestream.server.plist
├── build/
│   ├── build_dmg.sh            ← Automated DMG builder
│   └── Uninstall SourceStream.sh
├── dist/                       ← Built output (gitignored)
├── CHANGELOG.md
├── LICENSE
└── README.md
```

### Commands

```bash
# Syntax checks
python3 -m py_compile SourceStream.app/Contents/Resources/server.py
bash -n SourceStream.app/Contents/Resources/backup_engine.sh

# Start dev server
cd SourceStream.app/Contents/Resources && python3 server.py

# Build DMG
bash build/build_dmg.sh
```

### Git Branching Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Stable tagged releases |
| `develop` | Integration — merges feature branches here first |
| `feature/*` | New features (branch from `develop`) |
| `fix/*` | Bug fixes (branch from `develop` or `main`) |
| `release/*` | Release candidates (branch from `develop`) |

```bash
# Start a new feature
git checkout develop
git checkout -b feature/my-feature

# Merge back when done
git checkout develop
git merge --no-ff feature/my-feature
```

---

## 📋 Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full history.

---

## 📄 License

MIT © 2026 [Md. Masud Uz Zaman](https://github.com/mzaman)
