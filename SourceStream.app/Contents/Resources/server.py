#!/usr/bin/env python3
"""
SourceStream Dashboard Server  v1.0.8
SourceStream.app/Contents/Resources/server.py

Binds to 127.0.0.1:7474.
User data lives at ~/.sourcestream/ (never inside the app bundle).
Run via LaunchAgent (auto-starts at login) or via the app launcher.
"""

import http.server, json, os, subprocess, glob, datetime, socketserver, urllib.parse, re, shutil, platform, sys
from pathlib import Path

APP_VERSION = "1.0.8"
PORT        = 7474
APP_RES     = Path(__file__).parent          # …/SourceStream.app/Contents/Resources/
SS_DIR      = Path.home() / ".sourcestream"
CONF        = SS_DIR / "config" / "sourcestream.conf"
LOGS_DIR    = SS_DIR / "logs"
OUT_LOG     = LOGS_DIR / "backup.log"
ERR_LOG     = LOGS_DIR / "error.log"
STATUS      = SS_DIR / "status.json"
NOTES_FILE  = SS_DIR / "notes.txt"
SCRIPT      = APP_RES / "backup_engine.sh"

MIME = {".html": "text/html", ".js": "application/javascript",
        ".css": "text/css", ".json": "application/json", ".ico": "image/x-icon"}


# ── Google Drive auto-detection ────────────────────────────────────────────────
def _find_gdrive() -> Path:
    """Auto-detect the Google Drive 'My Drive' folder for any user account."""
    cs = Path.home() / "Library/CloudStorage"
    if cs.is_dir():
        for d in sorted(cs.glob("GoogleDrive-*")):
            if (d / "My Drive").is_dir():
                return d / "My Drive" / "SourceStream Backups"
    for legacy in [
        Path.home() / "Google Drive" / "My Drive" / "SourceStream Backups",
        Path.home() / "Google Drive" / "SourceStream Backups",
    ]:
        if legacy.parent.is_dir():
            return legacy
    return Path.home() / "Library/CloudStorage/GoogleDrive/My Drive/SourceStream Backups"

GDRIVE = _find_gdrive()


# ── Config ─────────────────────────────────────────────────────────────────────
DEFAULT_SETTINGS = {
    "DIRECT_TO_DRIVE":     "true",
    "MAX_ARCHIVES_TO_KEEP": "3",
    "COMPRESSION_LEVEL":   "6",
    "ARCHIVE_PREFIX":      "{label}",
    "HOSTNAME_IN_NAME":    "false",
    "BACKUP_VERIFY":       "false",
    "ARCHIVE_FORMAT":      "tar.gz",
    "NOTIFY_ON_COMPLETE":  "false",
    "BACKUP_MODE":         "full",
}

def parse_conf():
    """Parse sourcestream.conf and return 5 values:
       settings, sources, dests, excludes, source_excludes

    source_excludes is a dict keyed by source path:
        {"/path/to/source": ["pattern1", "pattern2"]}

    Sources are returned as raw strings (may contain |keep=N as 3rd field).
    Global [excludes] section → excludes list.
    Per-source [excludes:/path] sections → source_excludes dict.
    """
    settings = dict(DEFAULT_SETTINGS)
    sources, dests, excludes = [], [], []
    source_excludes = {}   # {src_path: [patterns]}
    remote_dests = []      # ["s3://bucket/prefix|Label", ...]
    section = ""
    current_excl_src = ""  # used when section == "source_excludes"
    try:
        for line in CONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                inner = line[1:-1]
                # Check for [excludes:/path] style
                if inner.startswith("excludes:"):
                    section = "source_excludes"
                    current_excl_src = inner[len("excludes:"):]
                else:
                    section = inner
                    current_excl_src = ""
                continue
            if section == "settings" and "=" in line:
                k, v = line.split("=", 1)
                settings[k.strip()] = v.strip()
            elif section == "sources" and "|" in line:
                sources.append(line)
            elif section == "destinations" and "|" in line:
                dests.append(line)
            elif section == "excludes" and line:
                excludes.append(line)
            elif section == "remote_destinations" and line:
                if "|" in line:
                    remote_dests.append(line)
            elif section == "source_excludes" and line and current_excl_src:
                if current_excl_src not in source_excludes:
                    source_excludes[current_excl_src] = []
                source_excludes[current_excl_src].append(line)
    except Exception:
        pass
    return settings, sources, dests, excludes, source_excludes, remote_dests


def write_conf(settings, sources, dests, excludes=None, source_excludes=None, remote_dests=None):
    """Write config to disk.

    source_excludes: dict {"/path": ["pattern1", ...]}  — written as [excludes:/path] sections.
    remote_dests: list ["s3://bucket/prefix|Label", ...]  — written as [remote_destinations].
    """
    CONF.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# SourceStream Configuration",
        "# ~/.sourcestream/config/sourcestream.conf",
        "", "[settings]",
        *[f"{k}={v}" for k, v in settings.items()],
        "", "[sources]", *sources,
        "", "[destinations]", *dests,
    ]
    if excludes:
        lines += ["", "[excludes]", *excludes]
    # Write per-source excludes sections
    if source_excludes:
        for src_path, patterns in source_excludes.items():
            if patterns:
                lines += ["", f"[excludes:{src_path}]", *patterns]
    # Write remote destinations section
    if remote_dests:
        lines += ["", "[remote_destinations]", *remote_dests]
    lines.append("")
    CONF.write_text("\n".join(lines))


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def read_status():
    try:
        return json.loads(STATUS.read_text())
    except Exception:
        return {}


# ── Common folder suggestions ──────────────────────────────────────────────────
COMMON_FOLDERS = [
    ("~/Developer",   "Developer"),
    ("~/Projects",    "Projects"),
    ("~/Code",        "Code"),
    ("~/Sites",       "Sites"),
    ("~/Work",        "Work"),
    ("~/repos",       "Repos"),
    ("~/src",         "Source"),
    ("~/Documents",   "Documents"),
    ("~/Desktop",     "Desktop"),
    ("~/Downloads",   "Downloads"),
    ("~/Pictures",    "Pictures"),
    ("~/Music",       "Music"),
    ("~/Movies",      "Movies"),
]

def suggest_folders():
    """Return common folders that actually exist on this machine."""
    suggestions = []
    for rel, label in COMMON_FOLDERS:
        path = Path(rel.replace("~", str(Path.home())))
        if path.is_dir():
            # Estimate size (fast: just check it exists, don't du)
            suggestions.append({"path": str(path), "label": label})
    return suggestions


# ── Handler ────────────────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass

    def cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def jsend(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.cors()
        self.end_headers()
        self.wfile.write(body)

    def fsend(self, path: Path):
        if not path.exists():
            self.send_response(404); self.end_headers(); return
        data = path.read_bytes()
        ct = MIME.get(path.suffix, "text/plain")
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(data)))
        self.cors(); self.end_headers(); self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(200); self.cors(); self.end_headers()

    # ── GET ───────────────────────────────────────────────────────────────────
    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path.rstrip("/")

        if p in ("", "/", "/app"):
            return self.fsend(APP_RES / "app.html")
        if p == "/status.json":
            return self.fsend(STATUS)

        if p == "/api/health":
            c = {}
            c["script"]     = os.access(str(SCRIPT), os.X_OK)
            _, _src, _dst, _exc, _src_exc, _ = parse_conf()
            drive_path = Path(_dst[0].split("|")[0]) if _dst else GDRIVE
            c["drive"]      = drive_path.is_dir()
            try:
                result = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
                cl = result.stdout
                c["cron"]       = "backup_engine" in cl or "sourcestream" in cl
                c["cron_clean"] = ">/dev/null" not in cl
                c["cron_entry"] = next(
                    (l for l in cl.splitlines() if "backup_engine" in l or "sourcestream" in l),
                    "not set"
                )
            except Exception:
                c["cron"] = False; c["cron_clean"] = True; c["cron_entry"] = "not set"
            st = os.statvfs("/")
            c["ssd_free_gb"] = round(st.f_bavail * st.f_frsize / 1e9, 1)
            try:
                ps = sh(["pgrep", "-f", "backup_engine.sh"]).stdout.strip()
                c["running"] = bool(ps)
                c["pid"]     = ps.split()[0] if ps else None
            except Exception:
                c["running"] = False; c["pid"] = None
            try:    c["error_bytes"] = ERR_LOG.stat().st_size
            except: c["error_bytes"] = 0
            # Count all supported archive formats
            try:
                arc_count = 0
                for pattern in ["*.tar.gz", "*.tar.bz2", "*.tar.xz", "*.zip"]:
                    arc_count += len(list(drive_path.glob(pattern)))
                c["archive_count"] = arc_count
            except: c["archive_count"] = 0
            c["conf_path"]    = str(CONF)
            c["logs_path"]    = str(LOGS_DIR)
            c["app_version"]  = APP_VERSION
            return self.jsend(c)

        if p == "/api/config":
            s, src, dst, exc, src_exc, rem = parse_conf()
            return self.jsend({
                "settings": s, "sources": src, "destinations": dst,
                "excludes": exc,
                "source_excludes": src_exc,
                "remote_destinations": rem,
                "config_path": str(CONF),
                "logs_path": str(LOGS_DIR),
                "app_version": APP_VERSION,
            })

        if p == "/api/progress":
            d = read_status()
            running = d.get("engine_status") == "running"
            cur_mb  = 0
            if running and d.get("current_archive_path"):
                try: cur_mb = int(Path(d["current_archive_path"]).stat().st_size / 1024 / 1024)
                except: pass
            est_mb  = int(d.get("estimated_size_mb", 0))
            pct     = min(99, int(cur_mb / est_mb * 100)) if est_mb > 0 and cur_mb > 0 else (50 if running else 0)
            elapsed = 0
            if running and d.get("last_run_start"):
                try:
                    t0 = datetime.datetime.strptime(d["last_run_start"], "%Y-%m-%d %H:%M:%S")
                    elapsed = int((datetime.datetime.now() - t0).total_seconds())
                except: pass
            return self.jsend({
                "running":      running,
                "pct":          pct,
                "current_mb":   cur_mb,
                "estimated_mb": est_mb,
                "elapsed_sec":  elapsed,
                "last_status":  d.get("last_run_status", ""),
            })

        if p == "/api/logs/output":
            try:
                qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                n_lines = int(qs.get('lines', [200])[0])
                lines = OUT_LOG.read_text().splitlines()[-n_lines:]
                return self.jsend({"lines": lines, "bytes": OUT_LOG.stat().st_size})
            except:
                return self.jsend({"lines": [], "bytes": 0})

        if p == "/api/logs/error":
            try:
                content = ERR_LOG.read_text()
                return self.jsend({"content": content, "bytes": ERR_LOG.stat().st_size})
            except:
                return self.jsend({"content": "", "bytes": 0})

        if p == "/api/browse-folder":
            try:
                r = subprocess.run(
                    ["osascript", "-e",
                     'tell application "Finder" to set f to choose folder\n'
                     'return POSIX path of f'],
                    capture_output=True, text=True, timeout=60,
                )
                path_val = r.stdout.strip().rstrip("/")
                if path_val:
                    return self.jsend({"path": path_val, "name": Path(path_val).name})
                return self.jsend({"path": "", "name": ""})
            except Exception:
                return self.jsend({"path": "", "name": ""})

        if p == "/api/suggest-folders":
            return self.jsend(suggest_folders())

        if p == "/api/analyze":
            res = {}
            s, src, dst_entries, _exc, _src_exc, _ = parse_conf()
            sources = [e.split("|")[0] for e in src] or [str(Path.home() / "Developer")]
            drive_path_analyze = Path(dst_entries[0].split("|")[0]) if dst_entries else GDRIVE
            try:
                total_kb = 0
                for sp in sources:
                    dk = sh(["du", "-sk", sp]).stdout.split()
                    if dk: total_kb += int(dk[0])
                res["raw_mb"] = total_kb // 1024
                res["est_mb"] = total_kb // 4 // 1024
            except Exception:
                res["raw_mb"] = 0; res["est_mb"] = 0
            try:
                df  = sh(["df", "-k", str(drive_path_analyze)]).stdout.splitlines()[1].split()
                res["drive_free_mb"]  = int(df[3]) // 1024
                res["drive_total_mb"] = int(df[1]) // 1024
            except Exception:
                res["drive_free_mb"] = 0; res["drive_total_mb"] = 0
            try:
                ec = sh(
                    "find " + " ".join(f'"{s}"' for s in sources) +
                    r" -type d \( -name node_modules -o -name vendor -o -name .gradle \) 2>/dev/null | wc -l",
                    shell=True,
                ).stdout.strip()
                res["excluded_dirs"] = int(ec)
            except Exception:
                res["excluded_dirs"] = 0
            try:
                top = sh(
                    "du -sm " + " ".join(f'"{s}"/*' for s in sources) +
                    " 2>/dev/null | sort -rn | head -10",
                    shell=True,
                ).stdout
                res["top_folders"] = [
                    {"size_mb": int(l.split()[0]), "name": l.split()[1].split("/")[-1]}
                    for l in top.strip().splitlines() if l
                ]
            except Exception:
                res["top_folders"] = []
            return self.jsend(res)

        if p == "/api/archives":
            archs = []
            _, _src, dsts, _exc, _src_exc, _ = parse_conf()
            dest_list = [(d.split("|")[0], d.split("|")[1] if "|" in d else "Drive") for d in dsts] \
                        if dsts else [(str(GDRIVE), "Google Drive")]
            try:
                for dest_path, dest_label in dest_list:
                    dest = Path(dest_path)
                    if not dest.is_dir():
                        continue
                    # Collect all supported archive formats
                    all_archives = []
                    for pattern in ["*.tar.gz", "*.tar.bz2", "*.tar.xz", "*.zip"]:
                        all_archives.extend(dest.glob(pattern))
                    for f in sorted(all_archives, key=lambda x: x.stat().st_mtime, reverse=True):
                        st      = f.stat()
                        created = datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
                        archs.append({
                            "name":        f.name,
                            "path":        str(f),
                            "size_mb":     int(st.st_size / 1024 / 1024),
                            "destination": dest_label,
                            "dest_path":   dest_path,
                            "created":     created,
                        })
            except Exception:
                pass
            return self.jsend(archs)

        if p == "/api/archive-verify":
            # Verifies a single archive is readable — detects format from extension
            # Expects ?path= query parameter
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            arch_path = qs.get("path", [""])[0]
            if not arch_path or not Path(arch_path).exists():
                return self.jsend({"ok": False, "error": "File not found"})
            try:
                if arch_path.endswith(".tar.bz2"):
                    r = sh(["tar", "-tjf", arch_path])
                elif arch_path.endswith(".tar.xz"):
                    r = sh(["tar", "-tJf", arch_path])
                elif arch_path.endswith(".zip"):
                    r = sh(["unzip", "-t", arch_path])
                else:
                    r = sh(["tar", "-tzf", arch_path])
                count = len(r.stdout.splitlines())
                ok = r.returncode == 0 and count > 0
                return self.jsend({"ok": ok, "entries": count,
                                   "error": r.stderr.strip() if not ok else ""})
            except Exception as e:
                return self.jsend({"ok": False, "error": str(e)})

        if p == "/api/cron":
            try:
                result = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
                cl    = result.stdout
                entry = next(
                    (l for l in cl.splitlines() if "backup_engine" in l or "sourcestream" in l), ""
                )
                return self.jsend({"entry": entry})
            except Exception:
                return self.jsend({"entry": ""})

        if p == "/api/version":
            return self.jsend({
                "version":     APP_VERSION,
                "python":      sys.executable,
                "python_ver":  platform.python_version(),
                "script":      str(SCRIPT),
                "conf":        str(CONF),
                "logs":        str(LOGS_DIR),
                "macos":       platform.mac_ver()[0],
                "hostname":    platform.node().split(".")[0],
            })

        if p == "/api/notes":
            try:    return self.jsend({"content": NOTES_FILE.read_text()})
            except: return self.jsend({"content": ""})

        if p == "/api/disk-usage":
            res = {}
            try:
                st    = os.statvfs("/")
                total = st.f_blocks * st.f_frsize
                free  = st.f_bavail * st.f_frsize
                used  = total - free
                res["ssd"] = {
                    "total_gb": round(total / 1e9, 1),
                    "used_gb":  round(used  / 1e9, 1),
                    "free_gb":  round(free  / 1e9, 1),
                    "pct_used": round(used / total * 100, 1) if total else 0,
                }
            except Exception:
                res["ssd"] = {}
            _, _src, dsts, _exc, _src_exc, _ = parse_conf()
            dest_list = [(d.split("|")[0], d.split("|")[1] if "|" in d else "Drive") for d in dsts] \
                        if dsts else [(str(GDRIVE), "Google Drive")]
            drives = []
            for dest_path, dest_label in dest_list:
                dest = Path(dest_path)
                try:
                    st    = os.statvfs(str(dest.anchor))
                    total = st.f_blocks * st.f_frsize
                    free  = st.f_bavail * st.f_frsize
                    used  = total - free
                    arc_sz = 0
                    if dest.is_dir():
                        for pattern in ["*.tar.gz", "*.tar.bz2", "*.tar.xz", "*.zip"]:
                            arc_sz += sum(f.stat().st_size for f in dest.glob(pattern) if f.exists())
                    drives.append({
                        "label":      dest_label,
                        "path":       dest_path,
                        "online":     dest.parent.is_dir() or dest.is_dir(),
                        "total_gb":   round(total / 1e9, 1),
                        "used_gb":    round(used  / 1e9, 1),
                        "free_gb":    round(free  / 1e9, 1),
                        "pct_used":   round(used / total * 100, 1) if total else 0,
                        "archive_gb": round(arc_sz / 1e9, 2),
                    })
                except Exception:
                    drives.append({"label": dest_label, "path": dest_path, "online": False})
            res["drives"] = drives
            return self.jsend(res)

        if p == "/api/backup-history":
            history = []
            try:
                lines = OUT_LOG.read_text().splitlines()
                run = None
                for line in lines:
                    if "SourceStream Backup Engine starting" in line:
                        if run:
                            history.append(run)
                        ts = line[1:20] if line.startswith("[") else ""
                        run = {"start": ts, "end": "", "status": "unknown",
                               "sources": [], "duration_min": 0, "errors": 0}
                    elif run:
                        if "ERROR" in line:
                            run["errors"] += 1
                            run["status"] = "error"
                        elif "SUCCESS" in line and "concluded" in line:
                            run["status"] = "success" if run["errors"] == 0 else "warn"
                            run["end"] = line[1:20] if line.startswith("[") else ""
                        elif "Source:" in line and "→" in line:
                            src = line.split("Source:")[-1].strip().split("→")[0].strip()
                            if src and src not in run["sources"]:
                                run["sources"].append(src)
                if run:
                    history.append(run)
            except Exception:
                pass
            fmt = "%Y-%m-%d %H:%M:%S"
            for r in history:
                try:
                    t0 = datetime.datetime.strptime(r["start"], fmt)
                    t1 = datetime.datetime.strptime(r["end"],   fmt)
                    r["duration_min"] = max(0, round((t1 - t0).total_seconds() / 60, 1))
                except Exception:
                    pass
            return self.jsend(list(reversed(history[-30:])))



        if p == "/api/incremental/status":
            """Return per-source incremental manifest info."""
            s, src_entries, _, _, _, _ = parse_conf()
            manifest_dir = SS_DIR / "manifests"
            manifest_dir.mkdir(parents=True, exist_ok=True)
            info = []
            for entry in src_entries:
                src_path  = entry.split("|")[0]
                src_label = entry.split("|")[1] if "|" in entry else src_path
                safe      = "".join(c for c in src_label if c.isalnum() or c in "_-")[:60]
                manifest_f = manifest_dir / (safe + ".manifest")
                mtime_f    = manifest_dir / (safe + ".mtime")
                last_backup_ts = manifest_f.read_text().strip() if manifest_f.exists() else None
                info.append({
                    "label":        src_label,
                    "path":         src_path,
                    "last_backup":  last_backup_ts,
                    "has_manifest": mtime_f.exists(),
                })
            return self.jsend({
                "ok":     True,
                "mode":   s.get("BACKUP_MODE", "full"),
                "sources": info,
            })

        if p == "/api/remote-dests":
            """List all configured remote destinations."""
            s, src, dst, exc, src_exc, rem = parse_conf()
            remotes = []
            for entry in rem:
                uri   = entry.split("|")[0]
                label = entry.split("|")[1] if "|" in entry else uri
                scheme = uri.split("://")[0] if "://" in uri else uri.split(":")[0]
                remotes.append({"uri": uri, "label": label, "scheme": scheme})
            return self.jsend({"ok": True, "remotes": remotes})


        if p == "/api/source-sizes":
            """Return disk size (du -sh) for each configured source folder."""
            _, src_entries, _, _, _, _ = parse_conf()
            results = []
            for entry in src_entries:
                parts    = entry.split("|")
                src_path = parts[0].strip()
                label    = parts[1].strip() if len(parts) > 1 else src_path
                p_obj    = Path(src_path)
                try:
                    out  = sh(["du", "-sk", src_path]).stdout.strip()
                    kb   = int(out.split()[0]) if out else 0
                    mb   = round(kb / 1024, 1)
                    gb   = round(kb / 1048576, 2)
                    size_str = f"{gb} GB" if gb >= 1 else f"{mb} MB"
                    results.append({
                        "label":     label,
                        "path":      src_path,
                        "exists":    p_obj.is_dir(),
                        "size_mb":   mb,
                        "size_gb":   gb,
                        "size_str":  size_str,
                    })
                except Exception:
                    results.append({"label": label, "path": src_path,
                                    "exists": p_obj.is_dir(), "size_mb": 0,
                                    "size_gb": 0, "size_str": "?"})
            total_mb = sum(r["size_mb"] for r in results)
            total_gb = round(total_mb / 1024, 2)
            return self.jsend({
                "ok": True,
                "sources": results,
                "total_str": f"{total_gb} GB" if total_gb >= 1 else f"{round(total_mb,1)} MB",
            })

        if p == "/api/next-run":
            """Return next scheduled backup time from launchd plist or cron."""
            import datetime, subprocess, re as _re
            result = {"source": None, "next": None, "schedule_str": None}
            # 1. Try launchd StartCalendarInterval
            plist_path = Path.home() / "Library/LaunchAgents/com.sourcestream.server.plist"
            try:
                txt = plist_path.read_text() if plist_path.exists() else ""
                # Look for StartCalendarInterval Hour/Minute in plist
                hour_m   = _re.search(r"<key>Hour</key>\s*<integer>(\d+)</integer>", txt)
                minute_m = _re.search(r"<key>Minute</key>\s*<integer>(\d+)</integer>", txt)
                if hour_m and minute_m:
                    h, m = int(hour_m.group(1)), int(minute_m.group(1))
                    now  = datetime.datetime.now()
                    nxt  = now.replace(hour=h, minute=m, second=0, microsecond=0)
                    if nxt <= now:
                        nxt += datetime.timedelta(days=1)
                    diff = nxt - now
                    hh, rem = divmod(int(diff.total_seconds()), 3600)
                    mm = rem // 60
                    result = {
                        "source":       "launchd",
                        "next":         nxt.strftime("%Y-%m-%d %H:%M"),
                        "schedule_str": f"Daily at {h:02d}:{m:02d}",
                        "in_hours":     hh,
                        "in_minutes":   mm,
                        "countdown":    f"{hh}h {mm}m" if hh else f"{mm}m",
                    }
                    return self.jsend(result)
            except Exception:
                pass
            # 2. Fall back to crontab
            try:
                cl = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True).stdout
                entry = next(
                    (l for l in cl.splitlines() if "backup_engine" in l or "sourcestream" in l), "")
                if entry:
                    fields = entry.split()
                    cron_min  = fields[0] if fields[0] != "*" else "0"
                    cron_hour = fields[1] if len(fields) > 1 and fields[1] != "*" else None
                    if cron_hour and cron_min.isdigit() and cron_hour.isdigit():
                        h, m = int(cron_hour), int(cron_min)
                        now  = datetime.datetime.now()
                        nxt  = now.replace(hour=h, minute=m, second=0, microsecond=0)
                        if nxt <= now:
                            nxt += datetime.timedelta(days=1)
                        diff = nxt - now
                        hh, rem = divmod(int(diff.total_seconds()), 3600)
                        mm = rem // 60
                        result = {
                            "source":       "cron",
                            "next":         nxt.strftime("%Y-%m-%d %H:%M"),
                            "schedule_str": f"Cron: {entry.split(None, 5)[0:5]}",
                            "in_hours":     hh,
                            "in_minutes":   mm,
                            "countdown":    f"{hh}h {mm}m" if hh else f"{mm}m",
                        }
                        return self.jsend(result)
            except Exception:
                pass
            return self.jsend({"ok": True, "source": None, "next": None,
                                "countdown": None, "schedule_str": "No schedule set"})

        if p == "/api/archive-trend":
            """Return per-day total archive size across all destinations for trending."""
            import datetime, re as _re
            _, _src, dsts, _exc, _src_exc, _ = parse_conf()
            dest_paths = [d.split("|")[0] for d in dsts] if dsts else [str(GDRIVE)]
            # Collect all archives with their size + date
            day_sizes = {}   # "YYYY-MM-DD" → total bytes
            for dest_path in dest_paths:
                dest = Path(dest_path)
                if not dest.is_dir():
                    continue
                for f in dest.iterdir():
                    if f.suffix in (".gz", ".zip") and f.stat().st_size > 0:
                        try:
                            # Try to parse date from filename YYYYMMDD_HHMMSS
                            m = _re.search(r"(\d{8})_\d{6}", f.name)
                            if m:
                                d = m.group(1)
                                day = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
                            else:
                                day = datetime.datetime.fromtimestamp(
                                    f.stat().st_mtime).strftime("%Y-%m-%d")
                            day_sizes[day] = day_sizes.get(day, 0) + f.stat().st_size
                        except Exception:
                            pass
            # Sort and return last 30 days
            trend = sorted(
                [{"date": k, "size_mb": round(v / 1048576, 1)} for k, v in day_sizes.items()],
                key=lambda x: x["date"]
            )[-30:]
            return self.jsend({"ok": True, "trend": trend})

        # Static fallback
        fp = APP_RES / p.lstrip("/")
        if fp.exists() and fp.is_file(): return self.fsend(fp)
        self.send_response(404); self.end_headers()

    # ── POST ──────────────────────────────────────────────────────────────────
    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path.rstrip("/")
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n)) if n else {}

        if p == "/api/run-backup":
            notify      = body.get("notify", False)
            source_path = body.get("source_path", "")   # optional: single-source backup
            LOGS_DIR.mkdir(parents=True, exist_ok=True)

            env = os.environ.copy()
            if source_path:
                # Pass a single-source override to the engine via env var
                env["SS_SINGLE_SOURCE"] = source_path

            if notify:
                wrapper = SS_DIR / "run_notify_wrapper.sh"
                wrapper.write_text(
                    "#!/bin/bash\n"
                    + (f"export SS_SINGLE_SOURCE={repr(source_path)}\n" if source_path else "")
                    + f"{SCRIPT} >> {OUT_LOG} 2>> {ERR_LOG}\n"
                    "STATUS=$?\n"
                    'if [ $STATUS -eq 0 ]; then\n'
                    '  MSG="✅ Backup finished. Archive on Google Drive."\n'
                    'else\n'
                    '  MSG="⚠️ Backup finished with errors. Check the error log."\n'
                    'fi\n'
                    'osascript -e "display notification \\"$MSG\\" with title \\"SourceStream\\" sound name \\"Glass\\""\n'
                )
                wrapper.chmod(0o755)
                subprocess.Popen(
                    ["bash", str(wrapper)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            else:
                subprocess.Popen(
                    [str(SCRIPT)],
                    stdout=open(str(OUT_LOG), "a"),
                    stderr=open(str(ERR_LOG), "a"),
                    env=env,
                )
            return self.jsend({"ok": True})

        if p == "/api/kill-backup":
            sh(["pkill", "-TERM", "-f", "backup_engine.sh"])
            sh(["pkill", "-TERM", "-f", "tar.*czf.*Backup"])
            try:
                s = read_status(); s["engine_status"] = "idle"
                STATUS.write_text(json.dumps(s, indent=2))
            except Exception:
                pass
            return self.jsend({"ok": True})

        if p == "/api/archive-delete":
            arch_path = body.get("path", "").strip()
            p_obj = Path(arch_path)
            # Safety: only allow deleting files inside configured destination dirs
            s2, src2, dst2, exc2, src_exc2, _ = parse_conf()
            allowed_roots = [Path(e.split("|")[0]) for e in dst2 if "|" in e]
            if not arch_path or not p_obj.exists():
                return self.jsend({"ok": False, "error": "File not found"})
            if not any(str(p_obj).startswith(str(r)) for r in allowed_roots):
                return self.jsend({"ok": False, "error": "Path outside configured destinations — blocked"})
            try:
                p_obj.unlink()
                return self.jsend({"ok": True})
            except Exception as e:
                return self.jsend({"ok": False, "error": str(e)})

        if p == "/api/clear-tmp":
            removed = 0
            for pat in ["/tmp/*.tar.gz", "/tmp/*.tar.bz2", "/tmp/*.tar.xz", "/tmp/*.zip"]:
                for f in glob.glob(pat):
                    try: os.remove(f); removed += 1
                    except OSError: pass
            return self.jsend({"ok": True, "removed": removed})

        if p == "/api/clear-errors":
            try:
                ERR_LOG.write_text("")
                return self.jsend({"ok": True})
            except Exception as e:
                return self.jsend({"ok": False, "error": str(e)})

        if p == "/api/rotate-logs":
            try:
                lines = OUT_LOG.read_text().splitlines()[-100:]
                ts    = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                OUT_LOG.write_text("\n".join(lines) + f"\n[{ts}] INFO: Logs rotated.\n")
                ERR_LOG.write_text("")
                return self.jsend({"ok": True})
            except Exception as e:
                return self.jsend({"ok": False, "error": str(e)})

        if p == "/api/config":
            s, src, dst, exc, src_exc, _ = parse_conf()
            new_s = body.get("settings", {})
            s.update(new_s)
            # Merge source_excludes from body if provided
            body_src_exc = body.get("source_excludes")
            if isinstance(body_src_exc, dict):
                src_exc.update(body_src_exc)
            write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/sources/add":
            s, src, dst, exc, src_exc, _ = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in src:
                src.append(e); write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/sources/remove":
            s, src, dst, exc, src_exc, _ = parse_conf()
            pv  = body.get("path", "")
            src = [x for x in src if not x.startswith(pv + "|")]
            write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/sources/update":
            # Replace one source entry: {"old_path": "/old", "new_entry": "/new|Label|keep=5"}
            s, src, dst, exc, src_exc, _ = parse_conf()
            old_path  = body.get("old_path", "").strip()
            new_entry = body.get("new_entry", "").strip()
            if old_path and new_entry:
                src = [new_entry if x.startswith(old_path + "|") else x for x in src]
                write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/destinations/add":
            s, src, dst, exc, src_exc, _ = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in dst:
                dst.append(e); write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/destinations/remove":
            s, src, dst, exc, src_exc, _ = parse_conf()
            if len(dst) <= 1:
                return self.jsend({"ok": False, "error": "Cannot remove last destination"})
            pv  = body.get("path", "")
            dst = [x for x in dst if not x.startswith(pv + "|")]
            write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/excludes/add":
            s, src, dst, exc, src_exc, _ = parse_conf()
            pattern = body.get("pattern", "").strip()
            if pattern and pattern not in exc:
                exc.append(pattern); write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/excludes/remove":
            s, src, dst, exc, src_exc, _ = parse_conf()
            pattern = body.get("pattern", "").strip()
            exc = [x for x in exc if x != pattern]
            write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/excludes/add-bulk":
            # Body: {"patterns": ["p1", "p2", "p3"]}
            s, src, dst, exc, src_exc, _ = parse_conf()
            patterns = body.get("patterns", [])
            added = 0
            for pat in patterns:
                pat = pat.strip() if isinstance(pat, str) else ""
                if pat and pat not in exc:
                    exc.append(pat)
                    added += 1
            write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True, "added": added})

        if p == "/api/source-excludes/set":
            # Body: {"source_path": "/path", "patterns": ["p1", "p2"]}
            # Replaces ALL per-source excludes for that path
            s, src, dst, exc, src_exc, _ = parse_conf()
            src_path = body.get("source_path", "").strip()
            patterns = [p.strip() for p in body.get("patterns", []) if isinstance(p, str) and p.strip()]
            if src_path:
                src_exc[src_path] = patterns
                write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/source-excludes/add":
            # Body: {"source_path": "/path", "pattern": "p1"}
            s, src, dst, exc, src_exc, _ = parse_conf()
            src_path = body.get("source_path", "").strip()
            pattern  = body.get("pattern", "").strip()
            if src_path and pattern:
                if src_path not in src_exc:
                    src_exc[src_path] = []
                if pattern not in src_exc[src_path]:
                    src_exc[src_path].append(pattern)
                write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/source-excludes/add-bulk":
            # Body: {"source_path": "/path", "patterns": ["p1", "p2"]}
            s, src, dst, exc, src_exc, _ = parse_conf()
            src_path = body.get("source_path", "").strip()
            patterns = body.get("patterns", [])
            added = 0
            if src_path:
                if src_path not in src_exc:
                    src_exc[src_path] = []
                for pat in patterns:
                    pat = pat.strip() if isinstance(pat, str) else ""
                    if pat and pat not in src_exc[src_path]:
                        src_exc[src_path].append(pat)
                        added += 1
                write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True, "added": added})

        if p == "/api/source-excludes/remove":
            # Body: {"source_path": "/path", "pattern": "p1"}
            s, src, dst, exc, src_exc, _ = parse_conf()
            src_path = body.get("source_path", "").strip()
            pattern  = body.get("pattern", "").strip()
            if src_path and src_path in src_exc:
                src_exc[src_path] = [x for x in src_exc[src_path] if x != pattern]
                write_conf(s, src, dst, exc, src_exc)
            return self.jsend({"ok": True})

        if p == "/api/schedule":
            expr = body.get("expr", "").strip()
            script_path = str(SCRIPT)
            if not expr:
                sh("(crontab -l 2>/dev/null | grep -v backup_engine | grep -v sourcestream) | crontab -", shell=True)
            else:
                line = f"{expr} {script_path}"
                sh(
                    f"(crontab -l 2>/dev/null | grep -v backup_engine | grep -v sourcestream; "
                    f"echo {repr(line)}) | crontab -",
                    shell=True,
                )
            return self.jsend({"ok": True})

        if p == "/api/notes":
            note = body.get("content", "")
            try:
                NOTES_FILE.parent.mkdir(parents=True, exist_ok=True)
                NOTES_FILE.write_text(note)
                return self.jsend({"ok": True})
            except Exception as e:
                return self.jsend({"ok": False, "error": str(e)})

        if p == "/api/dry-run":
            """Simulate a backup — count files that WOULD be archived without writing."""
            s, src_entries, dsts, exc, src_exc, _ = parse_conf()
            source_path = body.get("source_path", "")
            results = []
            for entry in src_entries:
                src_path = entry.split("|")[0]
                src_label = entry.split("|")[1] if "|" in entry else src_path
                if source_path and src_path != source_path:
                    continue
                try:
                    # Build find exclusions from user's global excludes + common defaults
                    _skip_defaults = ["node_modules", "vendor", ".gradle", "build/intermediates",
                                      ".git/objects/pack", "__pycache__", "DerivedData",
                                      ".venv", "venv", "Pods"]
                    _user_excl = [p for p in exc if p and not p.startswith("#")]
                    _all_skip  = _skip_defaults + _user_excl
                    _find_excl = " ".join("-not -path '*/" + p.strip("*") + "/*'" for p in _all_skip)
                    r = sh(
                        f"find {repr(src_path)} {_find_excl}"
                        " -not -name '.DS_Store' -not -name '*.tar.gz'"
                        " -not -name '*.tar.bz2' -not -name '*.tar.xz' -not -name '*.zip'"
                        " -type f 2>/dev/null | wc -l",
                        shell=True
                    )
                    file_count = int(r.stdout.strip())
                    r2 = sh(["du", "-sh", src_path])
                    raw_size = r2.stdout.split()[0] if r2.returncode == 0 else "?"
                    # Incremental: add changed file count and last-backup time
                    safe_label = "".join(c for c in src_label if c.isalnum() or c in "_-")[:60]
                    manifest_f = SS_DIR / "manifests" / (safe_label + ".manifest")
                    mtime_f    = SS_DIR / "manifests" / (safe_label + ".mtime")
                    last_backup_ts = manifest_f.read_text().strip() if manifest_f.exists() else None
                    changed_files = None
                    if mtime_f.exists() and s.get("BACKUP_MODE") == "incremental":
                        rc = sh(
                            "find " + repr(src_path) + " -newer " + repr(str(mtime_f)) +
                            " -not -name \'.DS_Store\' -type f 2>/dev/null | wc -l",
                            shell=True
                        )
                        try:
                            changed_files = int(rc.stdout.strip())
                        except Exception:
                            changed_files = None
                    results.append({
                        "label": src_label,
                        "path": src_path,
                        "files": file_count,
                        "raw_size": raw_size,
                        "would_archive": True,
                        "last_incremental_backup": last_backup_ts,
                        "changed_files": changed_files,
                    })
                except Exception as e:
                    results.append({"label": src_label, "path": src_path, "error": str(e)})
            return self.jsend({"ok": True, "results": results})

        if p == "/api/incremental/status":
            """Return per-source incremental manifest info."""
            s, src_entries, _, _, _, _ = parse_conf()
            manifest_dir = SS_DIR / "manifests"
            manifest_dir.mkdir(parents=True, exist_ok=True)
            info = []
            for entry in src_entries:
                src_path  = entry.split("|")[0]
                src_label = entry.split("|")[1] if "|" in entry else src_path
                safe      = "".join(c for c in src_label if c.isalnum() or c in "_-")[:60]
                manifest_f = manifest_dir / (safe + ".manifest")
                mtime_f    = manifest_dir / (safe + ".mtime")
                last_backup_ts = manifest_f.read_text().strip() if manifest_f.exists() else None
                info.append({
                    "label":        src_label,
                    "path":         src_path,
                    "last_backup":  last_backup_ts,
                    "has_manifest": mtime_f.exists(),
                })
            return self.jsend({
                "ok":     True,
                "mode":   s.get("BACKUP_MODE", "full"),
                "sources": info,
            })

        if p == "/api/incremental/reset":
            """Reset (delete) the incremental manifest for one or all sources."""
            src_label = body.get("label", "").strip()
            manifest_dir = SS_DIR / "manifests"
            manifest_dir.mkdir(parents=True, exist_ok=True)
            removed = []
            if src_label:
                safe = "".join(c for c in src_label if c.isalnum() or c in "_-")[:60]
                for suffix in [".manifest", ".mtime"]:
                    fp = manifest_dir / (safe + suffix)
                    if fp.exists():
                        fp.unlink()
                        removed.append(fp.name)
            else:
                for f in list(manifest_dir.glob("*.manifest")) + list(manifest_dir.glob("*.mtime")):
                    f.unlink(missing_ok=True)
                    removed.append(f.name)
            return self.jsend({"ok": True, "removed": removed})

        # ── Remote Destinations (S3 / B2 / rclone) ────────────────────────────

        if p == "/api/remote-dests":
            """List all configured remote destinations."""
            s, src, dst, exc, src_exc, rem = parse_conf()
            remotes = []
            for entry in rem:
                uri   = entry.split("|")[0]
                label = entry.split("|")[1] if "|" in entry else uri
                scheme = uri.split("://")[0] if "://" in uri else uri.split(":")[0]
                remotes.append({"uri": uri, "label": label, "scheme": scheme})
            return self.jsend({"ok": True, "remotes": remotes})

        if p == "/api/remote-dests/add":
            """Add a remote destination. Body: {uri, label}"""
            s, src, dst, exc, src_exc, rem = parse_conf()
            uri   = body.get("uri", "").strip()
            label = body.get("label", "").strip()
            if not uri or not label:
                return self.jsend({"ok": False, "error": "uri and label required"})
            # Validate scheme
            if not any(uri.startswith(p) for p in ["s3://", "b2://", "rclone:"]):
                return self.jsend({"ok": False, "error": "URI must start with s3://, b2://, or rclone:"})
            entry = f"{uri}|{label}"
            if entry not in rem:
                rem.append(entry)
                write_conf(s, src, dst, exc, src_exc, rem)
            return self.jsend({"ok": True})

        if p == "/api/remote-dests/remove":
            """Remove a remote destination. Body: {uri}"""
            s, src, dst, exc, src_exc, rem = parse_conf()
            uri = body.get("uri", "").strip()
            rem = [e for e in rem if e.split("|")[0] != uri]
            write_conf(s, src, dst, exc, src_exc, rem)
            return self.jsend({"ok": True})

        if p == "/api/remote-dests/test":
            """Test CLI availability for a given scheme. Body: {scheme}"""
            scheme = body.get("scheme", "").strip().lower()
            cli_map = {
                "s3":     ("aws",    ["aws", "--version"]),
                "b2":     ("b2",     ["b2", "version"]),
                "rclone": ("rclone", ["rclone", "version", "--check"]),
            }
            if scheme not in cli_map:
                return self.jsend({"ok": False, "error": f"Unknown scheme '{scheme}'"})
            cli_name, cmd = cli_map[scheme]
            r = sh(cmd)
            if r.returncode == 0:
                version = (r.stdout or r.stderr).splitlines()[0][:80]
                return self.jsend({"ok": True, "cli": cli_name, "version": version})
            else:
                return self.jsend({
                    "ok": False,
                    "cli": cli_name,
                    "error": f"{cli_name} not found or not configured",
                    "install": {
                        "s3": "brew install awscli  →  aws configure",
                        "b2": "brew install b2-tools  →  b2 authorize-account",
                        "rclone": "brew install rclone  →  rclone config",
                    }.get(scheme, ""),
                })


        self.send_response(404); self.end_headers()


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    CONF.parent.mkdir(parents=True, exist_ok=True)
    print(f"⚡ SourceStream server  →  http://127.0.0.1:{PORT}/")
    print(f"   Config : {CONF}")
    print(f"   Logs   : {LOGS_DIR}")
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
