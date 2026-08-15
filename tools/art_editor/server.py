"""One-click HTTP server for tools/art_editor.

Usage:
    python tools/art_editor/server.py           # serve and open browser
    python tools/art_editor/server.py --no-browser
"""
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8138
ROOT = Path(__file__).resolve().parent.parent.parent
URL = "http://localhost:%d/tools/art_editor/index.html" % PORT


def port_responding():
    # Only treat the port as healthy when it actually answers HTTP.
    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:%d/tools/art_editor/index.html" % PORT,
            timeout=0.8,
        ) as r:
            return r.status == 200
    except Exception:
        return False


def kill_port_owner():
    # Port is occupied but not responding; terminate only PIDs on this port.
    try:
        out = subprocess.check_output(
            ["netstat", "-ano", "-p", "tcp"],
            stderr=subprocess.STDOUT,
            text=True,
        )
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 5 and parts[1].endswith(":%d" % PORT):
                if parts[3] != "LISTENING":
                    continue
                pid = int(parts[-1])
                if pid <= 0:
                    continue
                try:
                    os.kill(pid, signal.SIGTERM)
                except Exception:
                    try:
                        subprocess.run(["taskkill", "/F", "/PID", str(pid)], check=False)
                    except Exception:
                        pass
        time.sleep(0.4)
    except Exception:
        pass


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)


if __name__ == "__main__":
    no_browser = "--no-browser" in sys.argv
    if port_responding():
        if not no_browser:
            webbrowser.open(URL)
        raise SystemExit(0)
    kill_port_owner()
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        print("Port %d is occupied but not responding; clearing stale listener..." % PORT)
        kill_port_owner()
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    if not no_browser:
        threading.Thread(
            target=lambda: (time.sleep(0.6), webbrowser.open(URL)),
            daemon=True,
        ).start()
    print("ModRacer art editor -> %s  (Ctrl+C to quit)" % URL)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
