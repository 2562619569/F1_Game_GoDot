# -*- coding: utf-8 -*-
"""确保 art/ 资产齐备（幂等补齐，可重复执行）。

以配表为唯一清单，对每项资产「缺啥补啥」：
  - 缺目录   → 创建目录
  - 缺 glb   → 生成占位几何；已有（如美术真实模型）则保留不覆盖
  - 缺 json  → 按对应 schema 补写（名字取配表）
清单来源：
  - 车壳：Car-car 表 → art/cars/<id>/（body.glb + body.json v2）
  - 轮毂：Cosmetic-cosmetic 表 category=wheel → art/wheels/<model>/（hub.glb + hub.json，纯外观）
  - 轮胎：Part-part 表 category=tires 的 model 列 → art/tires/<model>/（tire.glb + tire.json）
          另有原厂胎 stock_v1（不属于任何改件，未装配时的默认）
轮毂与轮胎分属两个 GLB：轮毂换装不碰物理，轮胎携带 radius/width 物理量。
本脚本自己生成的占位 glb 可安全升级（按 glTF generator 标记识别），美术文件永不覆盖。

配表新增车/轮毂/轮胎后重跑本脚本即可自动建目录与占位资产。
用法:  python tools/art_editor/make_placeholder_assets.py
"""
import json
import math
import os
import re
import struct

import openpyxl

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "art"))
XLSX_PATH = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "config", "data", "ModRacer.xlsx"))
CAR_SHEET = "Car-car"
COSMETIC_SHEET = "Cosmetic-cosmetic"
PART_SHEET = "Part-part"
GENERATOR = "make_placeholder_assets.py"

# ---------------- 几何 ----------------

def _sub(a, b): return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
def _cross(u, v): return [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
def _dot(a, b): return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
def _norm(v):
    l = math.sqrt(_dot(v, v)) or 1.0
    return [v[0]/l, v[1]/l, v[2]/l]

def _tri(v0, v1, v2, center, pos, nrm, idx):
    """按凸体中心自动修正绕向，保证法线朝外。"""
    c = [(v0[i]+v1[i]+v2[i])/3.0 for i in range(3)]
    n = _norm(_cross(_sub(v1, v0), _sub(v2, v0)))
    if _dot(n, _sub(c, center)) < 0:
        v1, v2 = v2, v1
        n = [-n[0], -n[1], -n[2]]
    base = len(pos)
    pos += [v0, v1, v2]
    nrm += [n, n, n]
    idx += [base, base + 1, base + 2]

def box(center, size):
    cx, cy, cz = center; sx, sy, sz = [s/2.0 for s in size]
    v = [[cx+dx*sx, cy+dy*sy, cz+dz*sz] for dz in (-1, 1) for dy in (-1, 1) for dx in (-1, 1)]
    # v 索引: z*4 + y*2 + x
    quads = [
        (0, 1, 3, 2), (4, 6, 7, 5),   # -Z / +Z
        (0, 4, 5, 1), (2, 3, 7, 6),   # -Y / +Y
        (0, 2, 6, 4), (1, 5, 7, 3),   # -X / +X
    ]
    pos, nrm, idx = [], [], []
    for q in quads:
        _tri(v[q[0]], v[q[1]], v[q[2]], center, pos, nrm, idx)
        _tri(v[q[0]], v[q[2]], v[q[3]], center, pos, nrm, idx)
    return pos, nrm, idx

def cylinder_x(center, radius, half_w, segments=16):
    """轴向 = X 的圆柱（轮毂），center 为轴心。"""
    pos, nrm, idx = [], [], []
    ring = []
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        ring.append((radius * math.cos(a), radius * math.sin(a)))
    for i in range(segments):
        j = (i + 1) % segments
        y0, z0 = ring[i]; y1, z1 = ring[j]
        l0 = [center[0]-half_w, center[1]+y0, center[2]+z0]
        l1 = [center[0]-half_w, center[1]+y1, center[2]+z1]
        r0 = [center[0]+half_w, center[1]+y0, center[2]+z0]
        r1 = [center[0]+half_w, center[1]+y1, center[2]+z1]
        _tri(l0, l1, r1, center, pos, nrm, idx)
        _tri(l0, r1, r0, center, pos, nrm, idx)
    cl = [center[0]-half_w, center[1], center[2]]
    cr = [center[0]+half_w, center[1], center[2]]
    for i in range(segments):
        j = (i + 1) % segments
        y0, z0 = ring[i]; y1, z1 = ring[j]
        _tri(cl, [cl[0], center[1]+y1, center[2]+z1], [cl[0], center[1]+y0, center[2]+z0], center, pos, nrm, idx)
        _tri(cr, [cr[0], center[1]+y0, center[2]+z0], [cr[0], center[1]+y1, center[2]+z1], center, pos, nrm, idx)
    return pos, nrm, idx

# ---------------- GLB ----------------

def build_glb(parts):
    """parts: [(name, (pos, nrm, idx), base_color_rgb)] → 单 mesh 多 primitive。"""
    bin_data = bytearray()
    accessors, views, materials = [], [], []

    def add_view(data, target):
        off = len(bin_data)
        while off % 4:
            bin_data.append(0); off += 1
        bin_data.extend(data)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    primitives = []
    mat_lookup = {}   # 同名部件共享材质（如左右大灯）
    for name, (pos, nrm, idx), color in parts:
        pv = add_view(struct.pack("<%df" % (len(pos)*3), *[c for p in pos for c in p]), 34962)
        nv = add_view(struct.pack("<%df" % (len(nrm)*3), *[c for p in nrm for c in p]), 34962)
        iv = add_view(struct.pack("<%dH" % len(idx), *idx), 34963)
        accessors.append({
            "bufferView": pv, "componentType": 5126, "count": len(pos), "type": "VEC3",
            "min": [min(p[i] for p in pos) for i in range(3)],
            "max": [max(p[i] for p in pos) for i in range(3)],
        })
        pa = len(accessors) - 1
        accessors.append({"bufferView": nv, "componentType": 5126, "count": len(nrm), "type": "VEC3"})
        na = len(accessors) - 1
        accessors.append({"bufferView": iv, "componentType": 5123, "count": len(idx), "type": "SCALAR"})
        ia = len(accessors) - 1
        if name not in mat_lookup:
            mat_lookup[name] = len(materials)
            materials.append({
                "name": name,
                "pbrMetallicRoughness": {
                    "baseColorFactor": [color[0], color[1], color[2], 1.0],
                    "metallicFactor": 0.1, "roughnessFactor": 0.8,
                },
            })
        primitives.append({"attributes": {"POSITION": pa, "NORMAL": na}, "indices": ia, "material": mat_lookup[name]})

    while len(bin_data) % 4:
        bin_data.append(0)

    gltf = {
        "asset": {"version": "2.0", "generator": "make_placeholder_assets.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": parts[0][0]}],
        "meshes": [{"primitives": primitives, "name": parts[0][0]}],
        "materials": materials,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(bin_data)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(bin_data)
    out = struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    out += struct.pack("<II", len(bin_data), 0x004E4942) + bytes(bin_data)
    return out

# ---------------- 资产定义 ----------------

WHEEL_CENTER = [0.05, 0.02, -0.03]   # 故意偏移，验证中心点对齐

HEADLIGHT_COLOR = [0.95, 0.9, 0.7]
BRAKE_LIGHT_COLOR = [0.5, 0.04, 0.04]

# 与 art_editor 的 MAT_AUTORULES 保持一致：材质名 → 语义槽位
AUTO_RULES = [
    ("brake_light", re.compile(r"brake|tail|stop|刹车", re.I)),
    ("headlight", re.compile(r"head|lamp|大灯", re.I)),
    ("body", re.compile(r"hull|body|paint|chassis|车身|车体", re.I)),
]

# 预设材质球（引擎效果）默认参数：与 app.js PRESET_DEFAULT_PARAMS / material_presets.gd 同构
PRESET_DEFAULT_PARAMS = {
    "paint": {"color": "#c23a2f", "glancing": "#2a0d0b", "clearcoat": 1.0},
    "headlight_lens": {"color": "#ffffff", "alpha": 0.1},
    "glass": {"color": "#05060a", "alpha": 1.0},
}
PRESET_AUTO_RULES = [
    ("paint", re.compile(r"paint|车漆|漆|hull|body", re.I)),
    ("headlight_lens", re.compile(r"lens|灯罩|罩|cover", re.I)),
    ("glass", re.compile(r"glass|玻璃", re.I)),
]

def read_gltf_chunk(path):
    """读 GLB 的 JSON chunk，失败返回 None。"""
    try:
        with open(path, "rb") as f:
            data = f.read()
        if len(data) < 20 or data[:4] != b"glTF":
            return None
        js_len, js_type = struct.unpack_from("<II", data, 12)
        if js_type != 0x4E4F534A or 20 + js_len > len(data):
            return None
        return json.loads(data[20:20 + js_len].decode("utf-8"))
    except Exception:
        return None

def read_glb_generator(path):
    gltf = read_gltf_chunk(path)
    return (gltf or {}).get("asset", {}).get("generator", "")

def read_glb_material_names(path):
    return [m.get("name", "") for m in (read_gltf_chunk(path) or {}).get("materials", [])]

def auto_map_materials(names):
    """按 AUTO_RULES 把 GLB 材质名映射到 headlight/brake_light/body 槽位（未命中为 None）。"""
    out = {"headlight": None, "brake_light": None, "body": None}
    used = set()
    for slot, rx in AUTO_RULES:
        for n in names:
            if n and n not in used and rx.search(n):
                out[slot] = n
                used.add(n)
                break
    return out

def auto_map_presets(names):
    """按 PRESET_AUTO_RULES 映射预设材质球（车漆/大灯罩/车玻璃），参数取默认值；未绑定为 None。"""
    out = {}
    used = set()
    for slot, rx in PRESET_AUTO_RULES:
        for n in names:
            if n and n not in used and rx.search(n):
                out[slot] = {"material": n, "params": dict(PRESET_DEFAULT_PARAMS[slot])}
                used.add(n)
                break
    return {"paint": out.get("paint"), "headlight_lens": out.get("headlight_lens"), "glass": out.get("glass")}

def car_glb_parts(t):
    """按几何模板产出占位车壳部件：车体/座舱 + 车头大灯 + 车尾刹车灯。"""
    (hx, hy, hz), (sx, sy, sz) = t["hull"]
    light_y = hy + sy * 0.05
    light_x = sx * 0.28
    head_z = hz - sz / 2 + 0.045   # 微嵌入车头面（车头朝 -Z）
    tail_z = hz + sz / 2 - 0.045
    head_size = (sx * 0.18, 0.12, 0.09)
    tail_size = (sx * 0.24, 0.1, 0.09)
    return [
        ("hull", box(*t["hull"]), t["color"]),
        ("cabin", box(*t["cabin"]), [0.12, 0.13, 0.16]),
        ("headlight", box((-light_x, light_y, head_z), head_size), HEADLIGHT_COLOR),
        ("headlight", box((light_x, light_y, head_z), head_size), HEADLIGHT_COLOR),
        ("brake_light", box((-light_x, light_y, tail_z), tail_size), BRAKE_LIGHT_COLOR),
        ("brake_light", box((light_x, light_y, tail_z), tail_size), BRAKE_LIGHT_COLOR),
    ]

# 几何模板以配表 Car-car 的 id（字符串）为 key；无模板的配表车用 DEFAULT_GEOM 兜底。
# body_width 为车体最宽处半宽；axle_f/axle_r 为前后轴 z。
DEFAULT_GEOM = {
    "color": [0.5, 0.5, 0.55],
    "hull": ((0, 0.6, 0), (1.6, 0.5, 3.5)),
    "cabin": ((0, 0.9, 0.15), (1.2, 0.35, 1.4)),
    "body_width": 0.9, "axle_f": -1.15, "axle_r": 1.15,
}
CAR_GEOM = {
    "601": {
        "color": [0.75, 0.22, 0.2],
        "hull": ((0, 0.62, 0), (1.7, 0.55, 3.8)),
        "cabin": ((0, 0.98, 0.25), (1.3, 0.4, 1.5)),
        "body_width": 0.92, "axle_f": -1.25, "axle_r": 1.25,
    },
    "602": {
        "color": [0.2, 0.42, 0.8],
        "hull": ((0, 0.55, 0), (1.6, 0.45, 3.4)),
        "cabin": ((0, 0.86, 0.1), (1.25, 0.35, 1.5)),
        "body_width": 0.88, "axle_f": -1.05, "axle_r": 1.05,
    },
    "603": {
        "color": [0.25, 0.6, 0.3],
        "hull": ((0, 0.6, 0), (1.75, 0.6, 3.6)),
        "cabin": ((0, 0.99, 0.2), (1.35, 0.42, 1.6)),
        "body_width": 0.94, "axle_f": -1.15, "axle_r": 1.15,
    },
}

def load_cars_from_config():
    """读配表 Car-car 表，返回 [{id:'601', name:'Brute Power'}, ...]（id 为字符串）。"""
    return _load_rows(CAR_SHEET, lambda r: {"id": str(r[0]), "name": str(r[1] or "")})


def load_cosmetic_wheels():
    """读外观件表 category=wheel 的行，返回 [{id, name, model}, ...]。"""
    return _load_rows(COSMETIC_SHEET, lambda r: (
        {"id": r[0], "name": str(r[1] or ""), "model": str(r[4] or "")}
        if r[2] == "wheel" else None))


def load_tire_parts():
    """读改件表 category=tires 且 model 非空的行，返回 [{id, name, model}, ...]。"""
    return _load_rows(PART_SHEET, lambda r: (
        {"id": r[0], "name": str(r[1] or ""), "model": str(r[_HEADER["model"]] or "")}
        if r[2] == "tires" and r[_HEADER["model"]] not in (None, "") else None))


_HEADER = {}   # 最近一次读取的表头字段名 -> 列下标

def _load_rows(sheet, make_row):
    """通用读表：跳过三行表头后逐行交给 make_row，返回 None 的行被过滤。"""
    global _HEADER
    wb = openpyxl.load_workbook(XLSX_PATH, read_only=True, data_only=True)
    try:
        ws = wb[sheet]
        rows = ws.iter_rows(values_only=True)
        next(rows); next(rows)  # 跳过 类型/中文注释 两行
        header = next(rows)
        _HEADER = {name: i for i, name in enumerate(header)}
        out = []
        for r in rows:
            if r is None or r[0] in (None, ""):
                continue
            item = make_row(r)
            if item is not None:
                out.append(item)
        return out
    finally:
        wb.close()

def _ensure_car(car_id, car_name):
    """确保 art/cars/<id>/ 齐备：缺目录建目录，缺 body.glb 生成占位，缺 body.json 补齐 v2。"""
    t = CAR_GEOM.get(car_id, DEFAULT_GEOM)
    d = os.path.join(ROOT, "cars", car_id)
    os.makedirs(d, exist_ok=True)

    glb_path = os.path.join(d, "body.glb")
    glb = build_glb(car_glb_parts(t))
    if not os.path.exists(glb_path):
        with open(glb_path, "wb") as f:
            f.write(glb)
        print("cars/%s/body.glb 生成占位 (%d B)" % (car_id, len(glb)))
    elif read_glb_generator(glb_path) == GENERATOR and open(glb_path, "rb").read() != glb:
        # 本脚本生成的旧占位可安全升级（含大灯/刹车灯材质）；美术文件不在此列
        with open(glb_path, "wb") as f:
            f.write(glb)
        print("cars/%s/body.glb 占位升级 (%d B)" % (car_id, len(glb)))
    else:
        print("cars/%s/body.glb 已存在，保留" % car_id)

    json_path = os.path.join(d, "body.json")
    if not os.path.exists(json_path):
        body_json = {
            "version": 2,
            "id": car_id,
            "name": car_name,
            "model": "body.glb",
            "body_width": t["body_width"],
            "front_axle": {"y": 0.35, "z": t["axle_f"]},
            "rear_axle": {"y": 0.35, "z": t["axle_r"]},
            "materials": auto_map_materials(read_glb_material_names(glb_path)),
            "material_presets": auto_map_presets(read_glb_material_names(glb_path)),
        }
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(body_json, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("cars/%s/body.json 补齐" % car_id)
        return
    with open(json_path, "r", encoding="utf-8") as f:
        body_json = json.load(f)
    if "materials" in body_json and "material_presets" in body_json:
        print("cars/%s/body.json 已存在，保留" % car_id)
        return
    # 增量补写：只加缺失的 materials / material_presets 键（按 GLB 实际材质名自动映射），其余字段原样
    names = read_glb_material_names(glb_path)
    changed = []
    if "materials" not in body_json:
        mapped = auto_map_materials(names)
        if any(mapped.values()):
            body_json["materials"] = mapped
            changed.append("materials=%s" % sorted(k for k, v in mapped.items() if v))
    if "material_presets" not in body_json:
        presets = auto_map_presets(names)
        if any(presets.values()):
            body_json["material_presets"] = presets
            changed.append("material_presets=%s" % sorted(k for k, v in presets.items() if v))
    if not changed:
        print("cars/%s/body.json 已存在（GLB 材质无法自动识别，请在编辑器中标记）" % car_id)
        return
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(body_json, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("cars/%s/body.json 增量补写 %s" % (car_id, ", ".join(changed)))


# ---------------- 轮毂 / 轮胎占位 ----------------

# 轮胎占位参数：颜色/圆柱分段数（光滑度≈胎种）/胎宽做视觉区分。
# radius 统一 0.30（装配链路已支持按胎配半径，但占位阶段不扰动既有驾驶手感）。
TIRE_RADIUS = 0.30
TIRE_GEOM = {
    "stock_v1":      {"color": [0.09, 0.09, 0.11], "segments": 16, "width": 0.20, "name": "Stock Tires"},
    "slick_v1":      {"color": [0.04, 0.04, 0.05], "segments": 24, "width": 0.20},   # 光头胎最光滑
    "offroad_v1":    {"color": [0.16, 0.12, 0.08], "segments": 8,  "width": 0.26},   # 粗块棱面
    "rain_v1":       {"color": [0.07, 0.08, 0.11], "segments": 16, "width": 0.22},
    "allterrain_v1": {"color": [0.12, 0.12, 0.11], "segments": 12, "width": 0.24},
}


def hub_glb_parts(model):
    """轮毂占位造型（多 primitive）；尺寸须落在胎内径内（胎 r=0.30）。"""
    if model == "classic_v1":   # 十字辐条 + 毂帽
        return [
            ("spoke", box(WHEEL_CENTER, (0.20, 0.36, 0.08)), [0.82, 0.72, 0.35]),
            ("spoke", box(WHEEL_CENTER, (0.20, 0.08, 0.36)), [0.82, 0.72, 0.35]),
            ("cap", cylinder_x(WHEEL_CENTER, 0.07, 0.11, 12), [0.30, 0.28, 0.24]),
        ]
    if model == "aero_v1":      # 平滑全覆盖盘
        return [
            ("cover", cylinder_x(WHEEL_CENTER, 0.24, 0.09, 24), [0.16, 0.17, 0.20]),
            ("cap", cylinder_x(WHEEL_CENTER, 0.05, 0.12, 12), [0.55, 0.57, 0.62]),
        ]
    # 默认（sport_v1 及配表新增未登记款）：方盒辐条
    return [("hub", box(WHEEL_CENTER, (0.22, 0.34, 0.34)), [0.75, 0.77, 0.8])]


def _ensure_hub(model, name):
    """确保 art/wheels/<model>/ 齐备：hub.glb 纯外观（无物理量）。"""
    d = os.path.join(ROOT, "wheels", model)
    os.makedirs(d, exist_ok=True)
    _ensure_glb(os.path.join(d, "hub.glb"), build_glb(hub_glb_parts(model)),
                "wheels/%s/hub.glb" % model)
    json_path = os.path.join(d, "hub.json")
    if not os.path.exists(json_path):
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"version": 1, "id": model, "name": name, "model": "hub.glb",
                       "center": WHEEL_CENTER}, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("wheels/%s/hub.json 补齐" % model)
    else:
        print("wheels/%s/hub.json 已存在，保留" % model)


def _ensure_tire(model, name):
    """确保 art/tires/<model>/ 齐备：tire.glb + 胎物理量（radius/width）。"""
    p = TIRE_GEOM.get(model, TIRE_GEOM["stock_v1"])
    d = os.path.join(ROOT, "tires", model)
    os.makedirs(d, exist_ok=True)
    glb = build_glb([("tire", cylinder_x(WHEEL_CENTER, TIRE_RADIUS, p["width"] / 2.0, p["segments"]), p["color"])])
    _ensure_glb(os.path.join(d, "tire.glb"), glb, "tires/%s/tire.glb" % model)
    json_path = os.path.join(d, "tire.json")
    if not os.path.exists(json_path):
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({"version": 1, "id": model, "name": name, "model": "tire.glb",
                       "center": WHEEL_CENTER, "radius": TIRE_RADIUS, "width": p["width"]},
                      f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("tires/%s/tire.json 补齐" % model)
    else:
        print("tires/%s/tire.json 已存在，保留" % model)


def _ensure_glb(path, glb, label):
    """占位 GLB 的幂等写入：缺失生成；本脚本生成的旧占位可升级；美术文件不覆盖。"""
    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.write(glb)
        print("%s 生成占位 (%d B)" % (label, len(glb)))
    elif read_glb_generator(path) == GENERATOR and open(path, "rb").read() != glb:
        with open(path, "wb") as f:
            f.write(glb)
        print("%s 占位升级 (%d B)" % (label, len(glb)))
    else:
        print("%s 已存在，保留" % label)


def main():
    cfg = load_cars_from_config()
    for c in cfg:
        _ensure_car(c["id"], c["name"])

    # 轮毂：以外观件表 wheel 类别为清单（纯外观，默认全解锁）
    hubs = load_cosmetic_wheels()
    for h in hubs:
        _ensure_hub(h["model"], h["name"])

    # 轮胎：改件胎以 Part 表 tires 的 model 列为清单，另有原厂胎（非改件）
    tires = load_tire_parts() + [{"id": 0, "name": TIRE_GEOM["stock_v1"]["name"], "model": "stock_v1"}]
    for t in tires:
        _ensure_tire(t["model"], t["name"])

    # 清理旧版「hub+tire 合并」占位（wheel.glb/wheel.json，已不被装配代码读取；
    # 仅删本脚本生成的占位，美术做的同名文件不动）
    legacy_dir = os.path.join(ROOT, "wheels", "sport_v1")
    legacy_glb = os.path.join(legacy_dir, "wheel.glb")
    if os.path.exists(legacy_glb) and read_glb_generator(legacy_glb) == GENERATOR:
        os.remove(legacy_glb)
        legacy_json = os.path.join(legacy_dir, "wheel.json")
        if os.path.exists(legacy_json):
            os.remove(legacy_json)
        print("wheels/sport_v1/ 旧版合并占位已清理（wheel.glb/wheel.json）")

    # HTTP 联调模式清单：列配表所有车的 body 与全部轮毂/轮胎（确保齐全后都在）
    files = []
    for c in cfg:
        files += ["cars/%s/body.glb" % c["id"], "cars/%s/body.json" % c["id"]]
    for h in hubs:
        files += ["wheels/%s/hub.glb" % h["model"], "wheels/%s/hub.json" % h["model"]]
    for t in tires:
        files += ["tires/%s/tire.glb" % t["model"], "tires/%s/tire.json" % t["model"]]
    with open(os.path.join(ROOT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"files": files}, f, indent=2)
        f.write("\n")
    print("manifest.json (%d files)" % len(files))

if __name__ == "__main__":
    main()
