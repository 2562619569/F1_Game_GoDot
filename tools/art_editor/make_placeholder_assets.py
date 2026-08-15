# -*- coding: utf-8 -*-
"""生成占位美术资产到 F1/art/（不入库），用于编辑器与运行时装配的端到端联调。

用法:  python tools/art_editor/make_placeholder_assets.py
产出:
  art/cars/<id>/body.glb + body.json   （三台车壳，轮距/轴距略有差异）
  art/wheels/sport_v1/wheel.glb + wheel.json（轮毂中心点故意偏移 (0.05, 0.02, -0.03)，
                                   用于验证「中心点对齐轮位」的对齐逻辑）
"""
import json
import math
import os
import struct

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "art"))

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
        materials.append({
            "name": name,
            "pbrMetallicRoughness": {
                "baseColorFactor": [color[0], color[1], color[2], 1.0],
                "metallicFactor": 0.1, "roughnessFactor": 0.8,
            },
        })
        primitives.append({"attributes": {"POSITION": pa, "NORMAL": na}, "indices": ia, "material": len(materials) - 1})

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

CARS = {
    "brute_power": {
        "name": "Brute Power",
        "color": [0.75, 0.22, 0.2],
        "hull": ((0, 0.62, 0), (1.7, 0.55, 3.8)),
        "cabin": ((0, 0.98, 0.25), (1.3, 0.4, 1.5)),
        "track": 0.82, "axle_f": -1.25, "axle_r": 1.25,
    },
    "agile_sprinter": {
        "name": "Agile Sprinter",
        "color": [0.2, 0.42, 0.8],
        "hull": ((0, 0.55, 0), (1.6, 0.45, 3.4)),
        "cabin": ((0, 0.86, 0.1), (1.25, 0.35, 1.5)),
        "track": 0.78, "axle_f": -1.05, "axle_r": 1.05,
    },
    "all_rounder": {
        "name": "All-Rounder",
        "color": [0.25, 0.6, 0.3],
        "hull": ((0, 0.6, 0), (1.75, 0.6, 3.6)),
        "cabin": ((0, 0.99, 0.2), (1.35, 0.42, 1.6)),
        "track": 0.84, "axle_f": -1.15, "axle_r": 1.15,
    },
}

def main():
    for car_id, c in CARS.items():
        d = os.path.join(ROOT, "cars", car_id)
        os.makedirs(d, exist_ok=True)
        glb = build_glb([
            ("hull", box(*c["hull"]), c["color"]),
            ("cabin", box(*c["cabin"]), [0.12, 0.13, 0.16]),
        ])
        with open(os.path.join(d, "body.glb"), "wb") as f:
            f.write(glb)
        body_json = {
            "version": 1,
            "id": car_id,
            "name": c["name"],
            "model": "body.glb",
            "wheel_positions": {
                "front_left": [-c["track"], 0.35, c["axle_f"]],
                "front_right": [c["track"], 0.35, c["axle_f"]],
                "rear_left": [-c["track"], 0.35, c["axle_r"]],
                "rear_right": [c["track"], 0.35, c["axle_r"]],
            },
        }
        with open(os.path.join(d, "body.json"), "w", encoding="utf-8") as f:
            json.dump(body_json, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("cars/%s/body.glb (%d B)" % (car_id, len(glb)))

    d = os.path.join(ROOT, "wheels", "sport_v1")
    os.makedirs(d, exist_ok=True)
    glb = build_glb([
        ("tire", cylinder_x(WHEEL_CENTER, 0.3, 0.1, 16), [0.09, 0.09, 0.11]),
        ("hub", box(WHEEL_CENTER, (0.22, 0.34, 0.34)), [0.75, 0.77, 0.8]),
    ])
    with open(os.path.join(d, "wheel.glb"), "wb") as f:
        f.write(glb)
    wheel_json = {
        "version": 1,
        "id": "sport_v1",
        "name": "运动轮毂V1",
        "model": "wheel.glb",
        "center": WHEEL_CENTER,
        "radius": 0.3,
        "width": 0.2,
    }
    with open(os.path.join(d, "wheel.json"), "w", encoding="utf-8") as f:
        json.dump(wheel_json, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wheels/sport_v1/wheel.glb (%d B)" % len(glb))

    # HTTP 联调模式清单（tools/art_editor/index.html?art=/art/ 使用）
    files = []
    for car_id in CARS:
        files += ["cars/%s/body.glb" % car_id, "cars/%s/body.json" % car_id]
    files += ["wheels/sport_v1/wheel.glb", "wheels/sport_v1/wheel.json"]
    with open(os.path.join(ROOT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"files": files}, f, indent=2)
        f.write("\n")
    print("manifest.json (%d files)" % len(files))

if __name__ == "__main__":
    main()
