# ModRacer 赛道编辑器配套服务:静态文件 + 地图 JSON 读写 API
# 一键启动(自动打开浏览器):
#     python tools/track_editor/server.py
# 不打开浏览器(仅起服务):
#     python tools/track_editor/server.py --no-browser
# 双击 file:// 打开编辑器时,API 会请求 http://localhost:8137(本服务须在跑),
# 服务未启动则编辑器自动进入离线模式(仅导入/导出下载)。
import json
import re
import socket
import sys
import threading
import time
import webbrowser
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

PORT = 8137
URL = "http://localhost:%d/tools/track_editor/index.html" % PORT
ROOT = Path(__file__).resolve().parent.parent.parent  # 项目根
DATA_DIR = ROOT / "game" / "race" / "tracks" / "data"


def port_in_use(port):
    # 主动连接探测:Windows 的 SO_REUSEADDR 允许重复绑定,靠 bind 异常检测不可靠
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    # ---- 基础 ----
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    # ---- GET: 静态文件 + /api/maps 列表 + /api/maps/<id> 单图 ----
    def do_GET(self):
        if self.path == "/api/maps":
            maps = []
            if DATA_DIR.is_dir():
                for f in sorted(DATA_DIR.glob("map_*.json")):
                    try:
                        d = json.loads(f.read_text(encoding="utf-8"))
                        baked = d.get("baked", {}).get("main", [])
                        maps.append({
                            "id": int(d.get("meta", {}).get("id", 0)),
                            "name": str(d.get("meta", {}).get("name", "")),
                            "length": round(float(baked[-1][7])) if baked else 0,
                        })
                    except (ValueError, KeyError, IndexError):
                        pass  # 跳过损坏文件
            return self._json(200, {"maps": maps})
        m = re.match(r"^/api/maps/(\d+)$", self.path)
        if m:
            f = DATA_DIR / ("map_%s.json" % m.group(1))
            if not f.is_file():
                return self._json(404, {"error": "map not found"})
            try:
                return self._json(200, json.loads(f.read_text(encoding="utf-8")))
            except ValueError:
                return self._json(400, {"error": "map json broken"})
        return super().do_GET()

    # ---- POST: /api/maps/<id> 写回地图 ----
    def do_POST(self):
        m = re.match(r"^/api/maps/(\d+)$", self.path)
        if not m:
            return self._json(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            if not isinstance(body, dict) or "routes" not in body or "baked" not in body:
                raise ValueError("缺少 routes/baked 字段")
        except (ValueError, json.JSONDecodeError) as e:
            return self._json(400, {"error": "bad json: %s" % e})
        # 文件 id 以 URL 为准,防止 meta 与目标文件错位
        body.setdefault("meta", {})["id"] = int(m.group(1))
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        target = DATA_DIR / ("map_%s.json" % m.group(1))
        target.write_text(json.dumps(body, indent=1, ensure_ascii=False), encoding="utf-8")
        print("[track_editor] saved %s" % target.relative_to(ROOT))
        return self._json(200, {"ok": True, "file": str(target.relative_to(ROOT)).replace("\\", "/")})


if __name__ == "__main__":
    no_browser = "--no-browser" in sys.argv
    if port_in_use(PORT):
        # 服务已在跑:直接打开页面复用现有实例
        print("端口 %d 已被占用:服务可能已在运行,直接打开页面" % PORT)
        if not no_browser:
            webbrowser.open(URL)
        raise SystemExit(0)
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    if not no_browser:
        threading.Thread(
            target=lambda: (time.sleep(0.6), webbrowser.open(URL)),
            daemon=True,
        ).start()
    print("ModRacer track editor -> %s  (Ctrl+C 退出)" % URL)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
