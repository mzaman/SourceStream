#!/usr/bin/env python3
"""
SourceStream Dashboard Server
SourceStream.app/Contents/Resources/server.py

Binds to 127.0.0.1:7474.
User data lives at ~/.sourcestream/ (never inside the app bundle).
Run via LaunchAgent (auto-starts at login) or via the app launcher.
"""

import http.server, json, os, subprocess, glob, datetime, socketserver, urllib.parse
from pathlib import Path

PORT      = 7474
APP_RES   = Path(__file__).parent          # …/SourceStream.app/Contents/Resources/
SS_DIR    = Path.home() / ".sourcestream"
CONF      = SS_DIR / "config" / "sourcestream.conf"
LOGS_DIR  = SS_DIR / "logs"
OUT_LOG   = LOGS_DIR / "backup.log"
ERR_LOG   = LOGS_DIR / "error.log"
STATUS    = SS_DIR / "status.json"
SCRIPT    = APP_RES / "backup_engine.sh"
def _find_gdrive() -> Path:
    """Auto-detect the Google Drive 'My Drive' folder for any user account."""
    cs = Path.home() / "Library/CloudStorage"
    if cs.is_dir():
        # Glob all GoogleDrive-* entries (handles any email address)
        for d in sorted(cs.glob("GoogleDrive-*")):
            candidate = d / "My Drive" / "Developer Backups"
            if (d / "My Drive").is_dir():
                return candidate
    # Legacy / older Drive versions
    for legacy in [
        Path.home() / "Google Drive" / "My Drive" / "Developer Backups",
        Path.home() / "Google Drive" / "Developer Backups",
    ]:
        if legacy.parent.is_dir():
            return legacy
    # Fallback — read from config (will be populated after first setup)
    return Path.home() / "Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"

GDRIVE = _find_gdrive()

MIME = {".html": "text/html", ".js": "application/javascript",
        ".css": "text/css", ".json": "application/json", ".ico": "image/x-icon"}

# ── Config ─────────────────────────────────────────────────────────────────────
def parse_conf():
    settings = {"DIRECT_TO_DRIVE": "true", "MAX_ARCHIVES_TO_KEEP": "3"}
    sources, dests = [], []
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
    except Exception:
        pass
    return settings, sources, dests


def write_conf(settings, sources, dests):
    CONF.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# SourceStream Configuration",
        "# ~/.sourcestream/config/sourcestream.conf",
        "", "[settings]",
        *[f"{k}={v}" for k, v in settings.items()],
        "", "[sources]", *sources,
        "", "[destinations]", *dests, "",
    ]
    CONF.write_text("\n".join(lines))


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def read_status():
    try:
        return json.loads(STATUS.read_text())
    except Exception:
        return {}


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
            # Read first destination from config (or fall back to auto-detected Drive)
            _, _src, _dst = parse_conf()
            drive_path = Path(_dst[0].split("|")[0]) if _dst else GDRIVE
            c["drive"]      = drive_path.is_dir()
            try:
                # crontab -l exits 1 with stderr noise on empty crontab — suppress stderr
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
            s, src, dst = parse_conf()
            return self.jsend({
                "settings": s, "sources": src, "destinations": dst,
                "config_path": str(CONF), "logs_path": str(LOGS_DIR),
                "app_version": "1.0.0",
            })

        if p == "/api/logs/output":
            try:    lines = OUT_LOG.read_text().splitlines()[-150:]
            except: lines = []
            return self.jsend({"lines": lines})

        if p == "/api/logs/error":
            try:    txt = ERR_LOG.read_text(); return self.jsend({"content": txt, "bytes": len(txt.encode())})
            except: return self.jsend({"content": "", "bytes": 0})

        if p == "/api/progress":
            s       = read_status()
            running = s.get("engine_status") == "running"
            result  = {
                "running":      running,
                "pct":          0,
                "current_mb":   0,
                "estimated_mb": s.get("estimated_size_mb", 0),
                "elapsed_sec":  0,
                "last_status":  s.get("last_run_status", ""),
            }
            if running:
                start = s.get("last_run_start", "")
                if start:
                    try:
                        d = datetime.datetime.fromisoformat(start.replace(" ", "T"))
                        result["elapsed_sec"] = int((datetime.datetime.now() - d).total_seconds())
                    except Exception:
                        pass
                ap = s.get("current_archive_path", "")
                em = s.get("estimated_size_mb", 0)
                if ap and os.path.exists(ap) and em > 0:
                    cur = int(os.path.getsize(ap) / 1024 / 1024)
                    result["current_mb"] = cur
                    result["pct"]        = min(99, int(cur / em * 100))
                elif result["elapsed_sec"] > 0 and em > 0:
                    est_sec       = max(60, em / 200 * 60)
                    result["pct"] = min(95, int(result["elapsed_sec"] / est_sec * 100))
            return self.jsend(result)

        if p == "/api/browse-folder":
            try:
                r = subprocess.run(
                    ["osascript", "-e",
                     'POSIX path of (choose folder with prompt "Select a folder:")'],
                    capture_output=True, text=True, timeout=60,
                )
                path_val = r.stdout.strip().rstrip("/")
                if path_val:
                    return self.jsend({"path": path_val, "name": Path(path_val).name})
                return self.jsend({"path": "", "name": ""})
            except Exception:
                return self.jsend({"path": "", "name": ""})

        if p == "/api/analyze":
            res = {}
            s, src, dst_entries = parse_conf()
            sources = [e.split("|")[0] for e in src] or [str(Path.home() / "Developer")]
            # Use first configured destination for drive stats (any user, any path)
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
                    "find " + " ".join(sources) +
                    r" -type d \( -name node_modules -o -name vendor -o -name .gradle \) 2>/dev/null | wc -l",
                    shell=True,
                ).stdout.strip()
                res["excluded_dirs"] = int(ec)
            except Exception:
                res["excluded_dirs"] = 0
            try:
                top = sh(
                    "du -sm " + " ".join(f'"{s}"/*' for s in sources) +
                    " 2>/dev/null | sort -rn | head -8",
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
            # Read destinations from config — works for any user's setup
            _, _src, dsts = parse_conf()
            # Fall back to auto-detected drive if config has no destinations yet
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
                            "size_mb":     int(st.st_size / 1024 / 1024),
                            "destination": dest_label,
                            "created":     created,
                        })
            except Exception:
                pass
            return self.jsend(archs)

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
            notify = body.get("notify", False)
            LOGS_DIR.mkdir(parents=True, exist_ok=True)
            if notify:
                wrapper = SS_DIR / "run_notify_wrapper.sh"
                wrapper.write_text(
                    "#!/bin/bash\n"
                    f"{SCRIPT} >> {OUT_LOG} 2>> {ERR_LOG}\n"
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
            files = glob.glob("/tmp/*_Backup_*.tar.gz")
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
            s, src, dst = parse_conf()
            s.update(body.get("settings", {}))
            write_conf(s, src, dst)
            return self.jsend({"ok": True})

        if p == "/api/sources/add":
            s, src, dst = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in src:
                src.append(e); write_conf(s, src, dst)
            return self.jsend({"ok": True})

        if p == "/api/sources/remove":
            s, src, dst = parse_conf()
            pv  = body.get("path", "")
            src = [x for x in src if not x.startswith(pv + "|")]
            write_conf(s, src, dst)
            return self.jsend({"ok": True})

        if p == "/api/destinations/add":
            s, src, dst = parse_conf()
            e = body.get("entry", "").strip()
            if e and "|" in e and e not in dst:
                dst.append(e); write_conf(s, src, dst)
            return self.jsend({"ok": True})

        if p == "/api/destinations/remove":
            s, src, dst = parse_conf()
            if len(dst) <= 1:
                return self.jsend({"ok": False, "error": "Cannot remove last destination"})
            pv  = body.get("path", "")
            dst = [x for x in dst if not x.startswith(pv + "|")]
            write_conf(s, src, dst)
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

