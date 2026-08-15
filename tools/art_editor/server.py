"""One-click HTTP server for tools/art_editor.

Usage:
    python tools/art_editor/server.py           # serve and open browser
    python tools/art_editor/server.py --no-browser
"""
import json
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
from urllib.parse import urlsplit

PORT = 8138
ROOT = Path(__file__).resolve().parent.parent.parent
URL = "http://localhost:%d/tools/art_editor/index.html" % PORT

CAR_SHEET = "Car-car"
XLSX_PATH = ROOT / "config" / "data" / "ModRacer.xlsx"


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

    def end_headers(self):
        # 开发工具不缓存：避免改完 app.js/index.html 后浏览器继续跑旧代码
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        # 编辑器车辆清单：读配表 Car-car 表（URL 含 query 时只比对 path 段）
        if urlsplit(self.path).path == "/api/cars":
            self._send_json(self._api_cars())
            return
        super().do_GET()  # 静态文件（含 art/manifest.json）走原逻辑

    def do_POST(self):
        # 编辑器自动保存：body 为 {path, text}，仅允许写 art/ 下的 .json（防止路径穿越）
        if urlsplit(self.path).path == "/api/save":
            self._api_save()
            return
        self._send_json({"error": "not found"}, 404)

    def _api_save(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as e:
            self._send_json({"error": "请求体解析失败: %s" % e}, 400)
            return
        rel = data.get("path", "")
        text = data.get("text")
        if not isinstance(text, str):
            self._send_json({"error": "缺少 text"}, 400)
            return
        # 安全校验：path 相对 art/（编辑器传的即 cars/<id>/body.json 等），拒绝穿越/非 json
        try:
            art_root = (ROOT / "art").resolve()
            p = (art_root / rel).resolve()
            if rel.startswith(("..", "/", "\\")) or p.suffix != ".json" or not p.is_relative_to(art_root):
                self._send_json({"error": "非法路径: %s" % rel}, 403)
                return
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8")
        except Exception as e:
            self._send_json({"error": "写入失败: %s" % e}, 500)
            return
        self._send_json({"ok": True, "path": rel})

    def _api_cars(self):
        cars = []
        try:
            import openpyxl
            wb = openpyxl.load_workbook(XLSX_PATH, read_only=True, data_only=True)
            ws = wb[CAR_SHEET]
            rows = ws.iter_rows(values_only=True)
            next(rows); next(rows); next(rows)  # 跳过 类型/中文注释/字段名 三行表头
            for r in rows:
                if r is None or r[0] in (None, ""):  # 跳过空行
                    continue
                cars.append({"id": str(r[0]), "name": str(r[1] or "")})
            wb.close()
        except ImportError:
            return {"error": "openpyxl 未安装，请 pip install openpyxl"}
        except Exception as e:
            return {"error": "读取配表失败: %s" % e}
        return {"cars": cars}

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


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
