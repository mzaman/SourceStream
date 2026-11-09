#!/usr/bin/env python3
"""
SourceStream Dashboard Server  v1.0.3
SourceStream.app/Contents/Resources/server.py

Binds to 127.0.0.1:7474.
User data lives at ~/.sourcestream/ (never inside the app bundle).
Run via LaunchAgent (auto-starts at login) or via the app launcher.
"""

import http.server, json, os, subprocess, glob, datetime, socketserver, urllib.parse, re, shutil, platform, sys
from pathlib import Path

APP_VERSION = "1.0.3"
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
                return d / "My Drive" / "Developer Backups"
    for legacy in [
        Path.home() / "Google Drive" / "My Drive" / "Developer Backups",
        Path.home() / "Google Drive" / "Developer Backups",
    ]:
        if legacy.parent.is_dir():
            return legacy
    return Path.home() / "Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"

GDRIVE = _find_gdrive()


# ── Config ─────────────────────────────────────────────────────────────────────
DEFAULT_SETTINGS = {
    "DIRECT_TO_DRIVE":     "true",
    "MAX_ARCHIVES_TO_KEEP": "3",
    "COMPRESSION_LEVEL":   "6",
    "ARCHIVE_PREFIX":      "{label}",
    "HOSTNAME_IN_NAME":    "false",
    "BACKUP_VERIFY":       "false",
}

def parse_conf():
    settings = dict(DEFAULT_SETTINGS)
    sources, dests, excludes = [], [], []
    section = ""
    try:
        for line in CONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
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
    except Exception:
        pass
    return settings, sources, dests, excludes


def write_conf(settings, sources, dests, excludes=None):
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
            _, _src, _dst, _exc = parse_conf()
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
            try:    c["archive_count"] = len(list(drive_path.glob("*.tar.gz")))
            except: c["archive_count"] = 0
            c["conf_path"]    = str(CONF)
            c["logs_path"]    = str(LOGS_DIR)
            c["app_version"]  = "1.0.0"
            return self.jsend(c)

        if p == "/api/config":
            s, src, dst, exc = parse_conf()
            return self.jsend({
                "settings": s, "sources": src, "destinations": dst,
                "excludes": exc,
                "config_path": str(CONF),
                "logs_path": str(LOGS_DIR),
                "app_version": "1.0.0",
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
                lines = OUT_LOG.read_text().splitlines()[-150:]
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
            s, src, dst_entries, _exc = parse_conf()
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
            _, _src, dsts, _exc = parse_conf()
            dest_list = [(d.split("|")[0], d.split("|")[1] if "|" in d else "Drive") for d in dsts] \
                        if dsts else [(str(GDRIVE), "Google Drive")]
            try:
                for dest_path, dest_label in dest_list:
                    dest = Path(dest_path)
                    if not dest.is_dir():
                        continue
                    for f in sorted(dest.glob("*.tar.gz"),
                                    key=lambda x: x.stat().st_mtime, reverse=True):
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
            # Verifies a single archive is readable (tar -tzf)
            # Expects ?path= query parameter
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            arch_path = qs.get("path", [""])[0]
            if not arch_path or not Path(arch_path).exists():
                return self.jsend({"ok": False, "error": "File not found"})
            try:
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
            _, _src, dsts, _exc = parse_conf()
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
                    arc_sz = sum(f.stat().st_size for f in dest.glob("*.tar.gz") if f.exists()) \
                             if dest.is_dir() else 0
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

        if p == "/api/clear-tmp":
            files = glob.glob("/tmp/*.tar.gz")
            for f in files: os.remove(f)
            return self.jsend({"ok": True, "removed": len(files)})

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
            s, src, dst, exc = parse_conf()
            new_s = body.get("settings", {})
            s.update(new_s)
            write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/sources/add":
            s, src, dst, exc = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in src:
                src.append(e); write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/sources/remove":
            s, src, dst, exc = parse_conf()
            pv  = body.get("path", "")
            src = [x for x in src if not x.startswith(pv + "|")]
            write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/destinations/add":
            s, src, dst, exc = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in dst:
                dst.append(e); write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/destinations/remove":
            s, src, dst, exc = parse_conf()
            if len(dst) <= 1:
                return self.jsend({"ok": False, "error": "Cannot remove last destination"})
            pv  = body.get("path", "")
            dst = [x for x in dst if not x.startswith(pv + "|")]
            write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/excludes/add":
            s, src, dst, exc = parse_conf()
            pattern = body.get("pattern", "").strip()
            if pattern and pattern not in exc:
                exc.append(pattern); write_conf(s, src, dst, exc)
            return self.jsend({"ok": True})

        if p == "/api/excludes/remove":
            s, src, dst, exc = parse_conf()
            pattern = body.get("pattern", "").strip()
            exc = [x for x in exc if x != pattern]
            write_conf(s, src, dst, exc)
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
            s, src_entries, dsts, exc = parse_conf()
            source_path = body.get("source_path", "")
            results = []
            for entry in src_entries:
                src_path = entry.split("|")[0]
                src_label = entry.split("|")[1] if "|" in entry else src_path
                if source_path and src_path != source_path:
                    continue
                try:
                    r = sh(
                        f"find {repr(src_path)} -not -path '*/node_modules/*'"
                        " -not -path '*/vendor/*' -not -path '*/.gradle/*'"
                        " -not -path '*/build/intermediates/*' -not -path '*/.git/objects/pack/*'"
                        " -not -name '.DS_Store' -not -name '*.tar.gz'"
                        " -type f 2>/dev/null | wc -l",
                        shell=True
                    )
                    file_count = int(r.stdout.strip())
                    r2 = sh(["du", "-sh", src_path])
                    raw_size = r2.stdout.split()[0] if r2.returncode == 0 else "?"
                    results.append({
                        "label": src_label,
                        "path": src_path,
                        "files": file_count,
                        "raw_size": raw_size,
                        "would_archive": True,
                    })
                except Exception as e:
                    results.append({"label": src_label, "path": src_path, "error": str(e)})
            return self.jsend({"ok": True, "results": results})

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
