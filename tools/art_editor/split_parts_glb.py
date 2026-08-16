# -*- coding: utf-8 -*-
"""把美术交付的「组合零件包 GLB」拆分为单项资产并落位 art/ 目录。

源包内每个部件是一个根节点（轮毂/轮胎/刹车盘组合），本脚本把每个节点子树
导出为独立 GLB，并以**节点枢纽(pivot)为原点重锚**：几何按世界矩阵烘焙后
减去枢纽世界坐标 → 导出 glb 的原点即安装位，json 的 center = [0, 0, 0]，
与 car_mesh_builder 的 visual.position = -center 对齐逻辑配套：

  - 轮毂 / 刹车盘：枢纽 = 安装位（两者用同一安装坐标即正确相对位置）；
  - 轮胎：枢纽 = 轮心（轮心即轮宽中面），另测 radius/width 物理量写入 json。

落位规则（沿用占位资产的目录约定，model id 不变则配表无需改动）：
  - art/wheels/<model>/hub.glb  + hub.json   （覆盖占位，json 保留 id/name）
  - art/tires/<model>/tire.glb  + tire.json  （覆盖占位，radius/width 用实测值）
  - art/brakes/<model>/disc.glb + disc.json  （新部件类别）

用法：
  python tools/art_editor/split_parts_glb.py <源.glb> --analyze   # 只分析不写盘
  python tools/art_editor/split_parts_glb.py <源.glb>             # 拆分并落位
"""
import copy
import json
import math
import os
import struct
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "art"))
GENERATOR = "split_parts_glb.py"

# 源包节点名 → 目标资产。轮毂1 为默认款，落在默认槽位 sport_v1
# （配表 Cosmetic 701 = 默认外观 + CarMeshBuilder.DEFAULT_HUB）。
HUB_MAP = {
    "轮毂1": "sport_v1",    # 缝隙比 0.35：辐条款 → 默认轮毂
    "轮毂2": "classic_v1",  # 缝隙比 0.87：密辐条近盘面
    "轮毂3": "aero_v1",     # 缝隙比 0.98：全覆盖盘
}
TIRE_MAP = {"轮胎1": "stock_v1"}                       # 唯一轮胎 = 原厂默认胎
BRAKE_MAP = {"前刹车": "front_v1", "后刹车": "rear_v1"}
BRAKE_NAMES = {"front_v1": "Front Brake V1", "rear_v1": "Rear Brake V1"}

CTYPE = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
         5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
TYPE_N = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


# ---------------- glTF 基础 ----------------

def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, ver, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, "不是 GLB 文件"
    off, js, bins = 12, None, []
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            bins.append(chunk)
        off += 8 + clen
    assert js is not None and bins, "GLB 缺 JSON/BIN chunk"
    return js, bins[0]


def qmat(q):
    x, y, z, w = q
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def node_local(n):
    if "matrix" in n:
        m = n["matrix"]
        return [m[0:4], m[1:4], m[2:4], m[3:4]]
    t = n.get("translation", [0, 0, 0])
    r = qmat(n.get("rotation", [0, 0, 0, 1]))
    s = n.get("scale", [1, 1, 1])
    return [[r[i][j] * s[j] for j in range(3)] + [t[i]] for i in range(3)] + [[0, 0, 0, 1]]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def mat_point(m, p):
    return [m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3)]


def mat3_transpose_inv(m):
    """3x3 逆的转置（法线变换矩阵），m 为 4x4 的左上 3x3。"""
    a, b, c = m[0][0], m[0][1], m[0][2]
    d, e, f = m[1][0], m[1][1], m[1][2]
    g, h, i = m[2][0], m[2][1], m[2][2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(det) < 1e-12:
        return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    inv = [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
           [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
           [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    return [[inv[j][i] for j in range(3)] for i in range(3)]


def norm3(v):
    l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) or 1.0
    return [v[0] / l, v[1] / l, v[2] / l]


def world_matrix(g, ni):
    """根到节点的世界矩阵。"""
    chain = []
    while ni is not None:
        chain.append(ni)
        ni = g["nodes"][ni].get("_parent")
    m = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    for idx in reversed(chain):
        m = mat_mul(m, node_local(g["nodes"][idx]))
    return m


def index_parents(g):
    for i, n in enumerate(g["nodes"]):
        for c in n.get("children", []):
            g["nodes"][c]["_parent"] = i


def read_accessor(g, bin_data, ai):
    """解出 accessor 全部元素（tuple 列表），处理 byteStride 交错。"""
    acc = g["accessors"][ai]
    assert "sparse" not in acc, "暂不支持 sparse accessor"
    fmt, sz = CTYPE[acc["componentType"]]
    n = TYPE_N[acc["type"]]
    bv = g["bufferViews"][acc["bufferView"]]
    stride = bv.get("byteStride", 0) or sz * n
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    end = "<" + fmt * n
    return [struct.unpack_from(end, bin_data, base + i * stride) for i in range(acc["count"])]


def raw_elements(g, bin_data, ai):
    """按元素原样拷贝字节（尊重 stride），用于无需变换的属性/索引。"""
    acc = g["accessors"][ai]
    fmt, sz = CTYPE[acc["componentType"]]
    n = TYPE_N[acc["type"]]
    elem = sz * n
    bv = g["bufferViews"][acc["bufferView"]]
    stride = bv.get("byteStride", 0) or elem
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return [bytes(bin_data[base + i * stride: base + i * stride + elem]) for i in range(acc["count"])]


# ---------------- 导出器 ----------------

class GlbWriter:
    """攒 accessors/bufferViews/materials，写单 BIN chunk 的 GLB。"""

    def __init__(self, src_g, src_bin):
        self.g = {
            "asset": {"version": "2.0", "generator": GENERATOR},
            "scene": 0,
            "scenes": [{"nodes": [0]}],
            "nodes": [], "meshes": [], "materials": [],
            "accessors": [], "bufferViews": [],
        }
        self.bin = bytearray()
        self.src = src_g
        self.src_bin = src_bin
        self.mat_map = {}       # 源材质索引 → 新索引
        self.tex_map = {}
        self.img_map = {}
        self.samp_map = {}

    def _view(self, payload, align, target=None):
        off = len(self.bin)
        while off % align:
            self.bin.append(0)
            off += 1
        self.bin.extend(payload)
        view = {"buffer": 0, "byteOffset": off, "byteLength": len(payload)}
        if target:
            view["target"] = target
        self.g["bufferViews"].append(view)
        return len(self.g["bufferViews"]) - 1

    def add_floats(self, values, atype, target=34962):
        data = struct.pack("<%df" % len(values), *values)
        acc = {"bufferView": self._view(data, 4, target), "componentType": 5126,
               "count": len(values) // TYPE_N[atype], "type": atype}
        self.g["accessors"].append(acc)
        return len(self.g["accessors"]) - 1

    def add_raw(self, elements, component_type, atype, target):
        data = b"".join(elements)
        _, sz = CTYPE[component_type]
        acc = {"bufferView": self._view(data, max(sz, 2), target), "componentType": component_type,
               "count": len(elements), "type": atype}
        self.g["accessors"].append(acc)
        return len(self.g["accessors"]) - 1

    def add_material(self, src_idx):
        if src_idx in self.mat_map:
            return self.mat_map[src_idx]
        mat = copy.deepcopy(self.src["materials"][src_idx])

        def remap(d):
            # 材质里形如 *Texture 的 dict 都带 index 指向 textures
            for k, v in d.items():
                if isinstance(v, dict):
                    if "index" in v and k.endswith("Texture"):
                        v["index"] = self.add_texture(v["index"])
                    remap(v)

        remap(mat)
        self.g["materials"].append(mat)
        self.mat_map[src_idx] = len(self.g["materials"]) - 1
        return self.mat_map[src_idx]

    def add_texture(self, src_idx):
        if src_idx in self.tex_map:
            return self.tex_map[src_idx]
        tex = copy.deepcopy(self.src["textures"][src_idx])
        if "sampler" in tex:
            si = tex["sampler"]
            if si not in self.samp_map:
                self.samp_map[si] = len(self.g.setdefault("samplers", []))
                self.g["samplers"].append(copy.deepcopy(self.src["samplers"][si]))
            tex["sampler"] = self.samp_map[si]
        img_src = tex.get("source")
        if img_src is not None:
            if img_src not in self.img_map:
                img = copy.deepcopy(self.src["images"][img_src])
                if "bufferView" in img:
                    bv = self.src["bufferViews"][img["bufferView"]]
                    off, ln = bv.get("byteOffset", 0), bv["byteLength"]
                    img["bufferView"] = self._view(bytes(self.src_bin[off: off + ln]), 1)
                self.g.setdefault("images", []).append(img)
                self.img_map[img_src] = len(self.g["images"]) - 1
            tex["source"] = self.img_map[img_src]
        self.g.setdefault("textures", []).append(tex)
        self.tex_map[src_idx] = len(self.g["textures"]) - 1
        return self.tex_map[src_idx]

    def add_mesh_node(self, name, primitives):
        self.g["meshes"].append({"name": name, "primitives": primitives})
        self.g["nodes"].append({"name": name, "mesh": len(self.g["meshes"]) - 1})

    def build(self):
        """序列化为 GLB 字节（不落盘，由调用方决定覆盖策略）。"""
        used = [e for e in self.src.get("extensionsUsed", [])]
        if used:
            self.g["extensionsUsed"] = used
        while len(self.bin) % 4:
            self.bin.append(0)
        self.g["buffers"] = [{"byteLength": len(self.bin)}]
        js = json.dumps(self.g, separators=(",", ":")).encode("utf-8")
        while len(js) % 4:
            js += b" "
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        out = struct.pack("<III", 0x46546C67, 2, total)
        out += struct.pack("<II", len(js), 0x4E4F534A) + js
        out += struct.pack("<II", len(self.bin), 0x004E4942) + bytes(self.bin)
        return out


def add_baked_primitives(w, src_g, src_bin, root_ni):
    """收集 root 子树全部 mesh primitive，几何烘焙「世界矩阵 − 根枢纽」。

    返回 (primitives, 统计信息)。"""
    root_w = world_matrix(src_g, root_ni)
    pivot = [root_w[0][3], root_w[1][3], root_w[2][3]]   # 根枢纽世界坐标
    prims, stats = [], {"min": [1e30] * 3, "max": [-1e30] * 3,
                        "r_max": 0.0, "r_min": 1e30, "verts": 0}

    def visit(ni):
        n = src_g["nodes"][ni]
        if "mesh" in n:
            wm = world_matrix(src_g, ni)
            nmat = mat3_transpose_inv(wm)
            for prim in src_g["meshes"][n["mesh"]]["primitives"]:
                attrs_out = {}
                for name, ai in prim["attributes"].items():
                    if name == "POSITION":
                        pts = [mat_point(wm, p) for p in read_accessor(src_g, src_bin, ai)]
                        pts = [[p[k] - pivot[k] for k in range(3)] for p in pts]
                        flat = [c for p in pts for c in p]
                        acc_i = w.add_floats(flat, "VEC3")
                        mn = [min(p[k] for p in pts) for k in range(3)]
                        mx = [max(p[k] for p in pts) for k in range(3)]
                        w.g["accessors"][acc_i]["min"] = mn
                        w.g["accessors"][acc_i]["max"] = mx
                        attrs_out["POSITION"] = acc_i
                        stats["verts"] += len(pts)
                        for k in range(3):
                            stats["min"][k] = min(stats["min"][k], mn[k])
                            stats["max"][k] = max(stats["max"][k], mx[k])
                        for p in pts:
                            r = math.hypot(p[1], p[2])
                            stats["r_max"] = max(stats["r_max"], r)
                            stats["r_min"] = min(stats["r_min"], r)
                    elif name == "NORMAL":
                        ns = [norm3([sum(nmat[i][j] * v[j] for j in range(3)) for i in range(3)])
                              for v in read_accessor(src_g, src_bin, ai)]
                        attrs_out["NORMAL"] = w.add_floats([c for n in ns for c in n], "VEC3")
                    elif name == "TANGENT":
                        ts = read_accessor(src_g, src_bin, ai)
                        out = []
                        for t in ts:
                            rt = [sum(wm[i][j] * t[j] for j in range(3)) for i in range(3)]
                            rt = norm3(rt) + [t[3]]
                            out += rt
                        attrs_out["TANGENT"] = w.add_floats(out, "VEC4")
                    else:   # TEXCOORD_n / COLOR_n 等原样拷贝
                        acc = src_g["accessors"][ai]
                        attrs_out[name] = w.add_raw(raw_elements(src_g, src_bin, ai),
                                                    acc["componentType"], acc["type"], 34962)
                prim_out = {"attributes": attrs_out}
                if "indices" in prim:
                    acc = src_g["accessors"][prim["indices"]]
                    prim_out["indices"] = w.add_raw(raw_elements(src_g, src_bin, prim["indices"]),
                                                    acc["componentType"], "SCALAR", 34963)
                if "material" in prim:
                    prim_out["material"] = w.add_material(prim["material"])
                if "mode" in prim:
                    prim_out["mode"] = prim["mode"]
                if "targets" in prim:
                    raise AssertionError("暂不支持 morph targets")
                prims.append(prim_out)
        for c in n.get("children", []):
            visit(c)

    visit(root_ni)
    return prims, stats


# ---------------- 分析与样式识别 ----------------

def classify_hub(src_g, src_bin, root_ni):
    """按「每个方位角的最大半径 r_max(θ)」的形态识别占位槽位样式：
    aero 全覆盖盘 → r_max 处处接近 R；classic 十字辐条 → 存在深缝（r_max 掉到
    毂帽半径附近）；sport 方盒辐条 → r_max 在 R 与 R/√2 之间波动、无深缝。"""
    pts = []
    root_w = world_matrix(src_g, root_ni)
    pivot = [root_w[0][3], root_w[1][3], root_w[2][3]]

    def visit(ni):
        n = src_g["nodes"][ni]
        if "mesh" in n:
            w = world_matrix(src_g, ni)
            for prim in src_g["meshes"][n["mesh"]]["primitives"]:
                ai = prim["attributes"].get("POSITION")
                if ai is not None:
                    for p in read_accessor(src_g, src_bin, ai):
                        q = mat_point(w, p)
                        pts.append([q[k] - pivot[k] for k in range(3)])
        for c in n.get("children", []):
            visit(c)

    visit(root_ni)
    rmax = {}
    for p in pts:
        r = math.hypot(p[1], p[2])
        if r < 1e-4:
            continue
        theta = int(math.atan2(p[2], p[1]) / math.pi * 36) % 72   # 5° 一格
        rmax[theta] = max(rmax.get(theta, 0.0), r)
    if not rmax:
        return "sport_v1", 0.0, 0.0
    big = max(rmax.values())
    small = min(rmax.values())
    ratio = small / big if big else 0.0
    style = "aero_v1" if ratio > 0.8 else ("classic_v1" if ratio < 0.45 else "sport_v1")
    return style, ratio, big


def fmt_stats(stats):
    size = [stats["max"][k] - stats["min"][k] for k in range(3)]
    ctr = [(stats["min"][k] + stats["max"][k]) / 2 for k in range(3)]
    return ("AABB size=[%.4f %.4f %.4f] center=[%.4f %.4f %.4f] r_out=%.4f r_in=%.4f verts=%d"
            % (size[0], size[1], size[2], ctr[0], ctr[1], ctr[2],
               stats["r_max"], stats["r_min"], stats["verts"]))


def update_json(path, updates):
    with open(path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    meta.update(updates)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return meta


def write_json(path, meta):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")


def replace_glb(path, blob):
    """覆盖占位 glb（打印被替换文件的 generator 便于追溯）。"""
    old_gen = ""
    if os.path.exists(path):
        try:
            with open(path, "rb") as f:
                d = f.read()
            if d[:4] == b"glTF":
                clen, ctype = struct.unpack_from("<II", d, 12)
                if ctype == 0x4E4F534A:
                    old_gen = json.loads(d[20:20 + clen]).get("asset", {}).get("generator", "")
        except Exception:
            pass
        os.remove(path)
    with open(path, "wb") as f:
        f.write(blob)
    return old_gen


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    analyze_only = "--analyze" in sys.argv
    src_path = args[0]
    g, bin_data = read_glb(src_path)
    index_parents(g)
    print("源包: %s (%s)" % (src_path, g.get("asset", {}).get("generator", "")))

    by_name = {n.get("name", ""): i for i, n in enumerate(g["nodes"])}
    plan = []
    for node_name in list(HUB_MAP) + list(TIRE_MAP) + list(BRAKE_MAP):
        if node_name not in by_name:
            print("!! 源包缺少节点 %r，跳过" % node_name)
            continue
        kind = "hub" if node_name in HUB_MAP else ("tire" if node_name in TIRE_MAP else "brake")
        model = (HUB_MAP if kind == "hub" else TIRE_MAP if kind == "tire" else BRAKE_MAP)[node_name]
        plan.append((kind, node_name, model))

    results = {}
    for kind, node_name, model in plan:
        ni = by_name[node_name]
        w = GlbWriter(g, bin_data)
        prims, stats = add_baked_primitives(w, g, bin_data, ni)
        w.add_mesh_node({"hub": "hub", "tire": "tire", "brake": "disc"}[kind], prims)
        results[node_name] = (w, stats, kind, model)
        extra = ""
        if kind == "hub":
            style, ratio, big = classify_hub(g, bin_data, ni)
            extra = " | 辐条样式≈%s (缝隙比 r_min/r_max=%.2f)" % (style, ratio)
        print("  [%s] %s -> %s %s%s" % (kind, node_name, model, fmt_stats(stats), extra))

    if analyze_only:
        return

    print("\n落位：")
    for kind, node_name, model in plan:
        w, stats, _, _ = results[node_name]
        if kind == "hub":
            d = os.path.join(ROOT, "wheels", model)
            glb, jsn = os.path.join(d, "hub.glb"), os.path.join(d, "hub.json")
            blob = w.build()
            old = replace_glb(glb, blob)
            meta = update_json(jsn, {"center": [0.0, 0.0, 0.0]})
            print("  wheels/%s/hub.glb %dB（替换 %s）+ hub.json center=0 id=%s name=%s"
                  % (model, len(blob), old or "无", meta["id"], meta.get("name", "")))
        elif kind == "tire":
            d = os.path.join(ROOT, "tires", model)
            glb, jsn = os.path.join(d, "tire.glb"), os.path.join(d, "tire.json")
            blob = w.build()
            old = replace_glb(glb, blob)
            radius = round(stats["r_max"], 4)
            width = round(stats["max"][0] - stats["min"][0], 4)
            meta = update_json(jsn, {"center": [0.0, 0.0, 0.0], "radius": radius, "width": width})
            print("  tires/%s/tire.glb %dB（替换 %s）+ tire.json radius=%.4f width=%.4f"
                  % (model, len(blob), old or "无", radius, width))
        else:
            d = os.path.join(ROOT, "brakes", model)
            os.makedirs(d, exist_ok=True)
            glb, jsn = os.path.join(d, "disc.glb"), os.path.join(d, "disc.json")
            blob = w.build()
            old = replace_glb(glb, blob)
            write_json(jsn, {"version": 1, "id": model, "name": BRAKE_NAMES[model],
                             "model": "disc.glb", "center": [0.0, 0.0, 0.0]})
            print("  brakes/%s/disc.glb %dB（新建%s）+ disc.json center=0"
                  % (model, len(blob), "，替换 " + old if old else ""))
    print("完成。")


if __name__ == "__main__":
    main()
