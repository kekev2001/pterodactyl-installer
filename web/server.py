#!/usr/bin/env python3
#
# ============================================================================
#
#   WiredHosting Panel Installer - webinstaller
#   https://wiredhosting.nl
#
#   Copyright (c) 2026 WiredHosting. Alle rechten voorbehouden.
#   Zie installer.sh voor de volledige copyrightvermelding.
#
# ============================================================================
#
#   Kleine HTTPS server zonder extra pakketten (alleen de Python standaard
#   bibliotheek, werkt vanaf Python 3.6). Serveert de wizard, controleert de
#   invoer via 'installer.sh --check' en start daarna 'installer.sh --config'.
#   De voortgang leest hij uit de @@-regels in het log.
#
#   Wordt gestart door install.sh, niet zelf draaien.
#
# ============================================================================

import argparse
import hmac
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse
from urllib.request import Request, urlopen

INSTALL_UNIT = "wiredhosting-install"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MAX_BODY = 64 * 1024

# Sluit vanzelf: een uur na afloop, of na 6 uur als er niets gestart is
IDLE_TIMEOUT = 6 * 3600
DONE_TIMEOUT = 3600

# Alleen deze sleutels gaan naar het config bestand van installer.sh
CONFIG_KEYS = [
    "INSTALL_MODE",
    "PANEL_DOMAIN_MODE", "FQDN", "USE_SSL",
    "ADMIN_EMAIL", "ADMIN_USER", "ADMIN_FIRST", "ADMIN_LAST", "ADMIN_PASS",
    "TIMEZONE", "PANEL_CHANNEL", "WINGS_CHANNEL",
    "DB_NAME", "DB_USER", "DB_PASS",
    "SETUP_DBHOST", "DBHOST_NAME", "DBHOST_FQDN", "DBADMIN_USER", "DBADMIN_HOST",
    "NODE_DOMAIN_MODE", "NODE_FQDN",
    "AUTO_NODE", "PANEL_URL", "PANEL_API_KEY",
    "NODE_NAME", "LOCATION_ID", "LOCATION_SHORT", "LOCATION_LONG", "ALLOC_PORTS",
    "NODE_MEM_MB", "NODE_DISK_MB", "NODE_DAEMON_PORT", "NODE_SFTP_PORT",
    "SETUP_FW",
]


class App:
    def __init__(self, args):
        self.args = args
        with open(args.token_file) as f:
            self.token = f.read().strip()
        self.installer = os.path.join(args.app_dir, "installer.sh")
        self.index = os.path.join(args.app_dir, "web", "index.html")
        self.log = os.path.join(args.state_dir, "install.log")
        self.config = os.path.join(args.state_dir, "config.env")
        self.lock = threading.Lock()
        self.started = time.time()
        self.install_started = None
        self.finished_at = None
        self.proc = None
        self.info = None
        self.versions = {}
        threading.Thread(target=self.fetch_versions, daemon=True).start()
        threading.Thread(target=self.watchdog, daemon=True).start()

    # ------------------------------------------------------------------
    #  Hulpjes
    # ------------------------------------------------------------------
    def run(self, cmd, timeout=120):
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout

    def get_info(self):
        if self.info is None:
            info = {}
            try:
                _, out = self.run(["/bin/bash", self.installer, "--info"], timeout=60)
                for line in out.splitlines():
                    if line.startswith("@@INFO|"):
                        parts = line.split("|", 2)
                        if len(parts) == 3:
                            info[parts[1]] = parts[2]
            except Exception as e:  # noqa
                info["error"] = str(e)
            self.info = info
        data = dict(self.info)
        data["versions"] = self.versions
        data["port"] = self.args.port
        return data

    def fetch_versions(self):
        def tags(repo):
            req = Request("https://api.github.com/repos/pterodactyl/%s/releases?per_page=50" % repo,
                          headers={"User-Agent": "wiredhosting-installer",
                                   "Accept": "application/vnd.github+json"})
            with urlopen(req, timeout=10) as r:
                return [x.get("tag_name", "") for x in json.loads(r.read().decode())]

        def first(lst, pattern):
            for t in lst:
                if re.match(pattern, t):
                    return t
            return ""

        try:
            panel = tags("panel")
            self.versions["panel_v1"] = first(panel, r"^v?1\.\d+\.\d+$")
            self.versions["panel_v2"] = first(panel, r"^v?2\.\d+\.\d+")
        except Exception:
            pass
        try:
            self.versions["wings"] = first(tags("wings"), r"^v?1\.\d+\.\d+$")
        except Exception:
            pass

    def write_config(self, path, cfg):
        lines = ["# Gemaakt door de WiredHosting webinstaller"]
        for key in CONFIG_KEYS:
            val = cfg.get(key, "")
            if isinstance(val, bool):
                val = "1" if val else "0"
            val = "" if val is None else str(val).strip()
            if any(c in val for c in "\r\n\0"):
                raise ValueError("Ongeldige invoer in %s" % key)
            if len(val) > 512:
                raise ValueError("Te lange invoer in %s" % key)
            lines.append("%s=%s" % (key, shlex.quote(val)))
        lines.append("WEBINSTALLER_PORT=%s" % shlex.quote(str(self.args.port)))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(lines) + "\n")

    def check(self, cfg):
        tmp = os.path.join(self.args.state_dir, "config.check.env")
        try:
            self.write_config(tmp, cfg)
        except ValueError as e:
            return [{"field": "", "message": str(e)}]
        try:
            _, out = self.run(["/bin/bash", self.installer, "--check", "--config", tmp], timeout=60)
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        errors = []
        ok = False
        for line in out.splitlines():
            if line.startswith("@@ERR|"):
                parts = line.split("|", 2)
                errors.append({"field": parts[1] if len(parts) > 1 else "",
                               "message": parts[2] if len(parts) > 2 else line})
            elif line.strip() == "@@OK":
                ok = True
        if not ok and not errors:
            tail = "\n".join(ANSI.sub("", out).strip().splitlines()[-5:])
            errors.append({"field": "", "message": "Controle mislukt: " + (tail or "onbekende fout")})
        return errors

    # ------------------------------------------------------------------
    #  Installatie starten en volgen
    # ------------------------------------------------------------------
    def unit_active(self):
        if self.proc is not None:
            return self.proc.poll() is None
        try:
            rc = subprocess.call(["systemctl", "is-active", "--quiet", INSTALL_UNIT])
            return rc == 0
        except OSError:
            return False

    def start_install(self, cfg):
        with self.lock:
            st = self.parse_log()
            if st["state"] == "running":
                return "Er loopt al een installatie."
            errors = self.check(cfg)
            if errors:
                return errors
            if os.path.exists(self.log):
                os.replace(self.log, self.log + ".prev")
            self.write_config(self.config, cfg)
            fd = os.open(self.log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)

            # Eigen systemd unit: de installatie loopt door als de webinstaller
            # of de SSH sessie stopt.
            inner = 'exec /bin/bash "$0" --config "$1" >>"$2" 2>&1'
            cmd = ["systemd-run", "--unit=" + INSTALL_UNIT, "--collect", "--quiet",
                   "--setenv=HOME=/root", "--setenv=LANG=C.UTF-8",
                   "/bin/bash", "-c", inner, self.installer, self.config, self.log]
            subprocess.call(["systemctl", "reset-failed", INSTALL_UNIT],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started = False
            try:
                started = subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
            except OSError:
                started = False
            if not started:
                env = dict(os.environ, HOME="/root", LANG="C.UTF-8")
                logf = open(self.log, "ab")
                self.proc = subprocess.Popen(["/bin/bash", self.installer, "--config", self.config],
                                             stdout=logf, stderr=subprocess.STDOUT,
                                             stdin=subprocess.DEVNULL, env=env,
                                             start_new_session=True)
            self.install_started = time.time()
            return None

    def parse_log(self, since=0):
        res = {"state": "idle", "plan": [], "step": 0, "total": 0, "label": "",
               "error": "", "log": [], "next": since, "panel_url": "",
               "credentials": "", "summary": ""}
        if not os.path.exists(self.log):
            return res
        try:
            with open(self.log, "r", errors="replace") as f:
                raw = f.read()
        except OSError:
            return res

        log_lines = []
        summary = None
        exit_code = None
        done = False
        cred_file = ""
        for line in ANSI.sub("", raw).splitlines():
            if line.startswith("@@"):
                parts = line[2:].split("|")
                kind = parts[0]
                if kind == "PLAN":
                    res["plan"] = parts[1:]
                    res["total"] = len(res["plan"])
                elif kind == "STEP" and len(parts) >= 4:
                    res["step"] = int(parts[1])
                    res["total"] = int(parts[2])
                    res["label"] = "|".join(parts[3:])
                elif kind == "FAIL" and not res["error"]:
                    res["error"] = "|".join(parts[1:])
                elif kind == "DONE":
                    done = True
                elif kind == "EXIT":
                    try:
                        exit_code = int(parts[1])
                    except (IndexError, ValueError):
                        exit_code = 1
                elif kind == "RESULT" and len(parts) >= 3:
                    if parts[1] == "panel_url":
                        res["panel_url"] = parts[2]
                    elif parts[1] == "cred_file":
                        cred_file = parts[2]
                elif kind == "SUMMARY":
                    summary = []
                continue
            log_lines.append(line)
            if summary is not None:
                summary.append(line)

        res["log"] = log_lines[since:]
        res["next"] = len(log_lines)

        if done and exit_code in (None, 0):
            res["state"] = "done"
        elif exit_code is not None or res["error"]:
            res["state"] = "failed"
        elif self.unit_active() or (self.install_started and time.time() - self.install_started < 10):
            res["state"] = "running"
        else:
            res["state"] = "failed"
            res["error"] = res["error"] or "De installer is onverwacht gestopt."

        if res["state"] == "done":
            if summary:
                res["summary"] = "\n".join(summary).strip()
            if cred_file and os.path.isfile(cred_file):
                try:
                    with open(cred_file, "r", errors="replace") as f:
                        res["credentials"] = f.read()
                except OSError:
                    pass
        if res["state"] in ("done", "failed") and self.finished_at is None:
            self.finished_at = time.time()
        return res

    # ------------------------------------------------------------------
    #  Afsluiten
    # ------------------------------------------------------------------
    def shutdown(self, delay=1.0):
        def go():
            time.sleep(delay)
            try:
                subprocess.call(["/bin/bash", os.path.join(self.args.app_dir, "install.sh"), "--cleanup"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
            except Exception:
                pass
            os._exit(0)
        threading.Thread(target=go, daemon=True).start()

    def watchdog(self):
        while True:
            time.sleep(30)
            try:
                st = self.parse_log()["state"]
            except Exception:
                continue
            now = time.time()
            if st in ("done", "failed") and self.finished_at and now - self.finished_at > DONE_TIMEOUT:
                self.shutdown(0)
            elif st == "idle" and now - self.started > IDLE_TIMEOUT:
                self.shutdown(0)


class Handler(BaseHTTPRequestHandler):
    server_version = "WiredHosting"
    sys_version = ""
    timeout = 30
    app = None  # type: App

    def log_message(self, fmt, *args):
        # geen querystring (token) in de logs
        sys.stderr.write("%s %s\n" % (self.command, urlparse(self.path).path))

    def headers_common(self, ctype, length):
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                         "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                         "connect-src 'self'; frame-ancestors 'none'")

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.headers_common("application/json; charset=utf-8", len(body))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        tok = self.headers.get("X-Install-Token", "")
        if tok and hmac.compare_digest(tok, self.app.token):
            return True
        self.send_json(401, {"error": "Ongeldige of verlopen link. Gebruik de link uit je SSH sessie."})
        return False

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return data if isinstance(data, dict) else None

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            try:
                with open(self.app.index, "rb") as f:
                    body = f.read()
            except OSError:
                self.send_error(500)
                return
            self.send_response(200)
            self.headers_common("text/html; charset=utf-8", len(body))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.headers_common("text/plain", len(body))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/info":
            if self.authed():
                self.send_json(200, self.app.get_info())
        elif path == "/api/status":
            if self.authed():
                since = 0
                q = urlparse(self.path).query
                m = re.search(r"(?:^|&)since=(\d+)", q)
                if m:
                    since = int(m.group(1))
                self.send_json(200, self.app.parse_log(since))
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if not self.authed():
            return
        if path == "/api/check":
            cfg = self.read_json()
            if cfg is None:
                self.send_json(400, {"error": "Ongeldige aanvraag."})
                return
            self.send_json(200, {"errors": self.app.check(cfg)})
        elif path == "/api/install":
            cfg = self.read_json()
            if cfg is None:
                self.send_json(400, {"error": "Ongeldige aanvraag."})
                return
            res = self.app.start_install(cfg)
            if res is None:
                self.send_json(200, {"ok": True})
            elif isinstance(res, list):
                self.send_json(200, {"errors": res})
            else:
                self.send_json(409, {"error": res})
        elif path == "/api/shutdown":
            if self.app.parse_log()["state"] == "running":
                self.send_json(409, {"error": "De installatie loopt nog, wacht tot hij klaar is."})
                return
            self.send_json(200, {"ok": True})
            self.app.shutdown()
        else:
            self.send_error(404)


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8443)
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--token-file", required=True)
    p.add_argument("--app-dir", required=True)
    p.add_argument("--state-dir", required=True)
    args = p.parse_args()

    Handler.app = App(args)
    httpd = Server(("", args.port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.options |= getattr(ssl, "OP_NO_TLSv1", 0) | getattr(ssl, "OP_NO_TLSv1_1", 0)
    ctx.load_cert_chain(args.cert, args.key)
    # handshake pas in de thread van het verzoek, zodat een trage client
    # de rest niet blokkeert
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    sys.stderr.write("WiredHosting webinstaller luistert op poort %d\n" % args.port)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
