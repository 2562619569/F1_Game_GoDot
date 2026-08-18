class_name TrackBuilder
extends Node3D
## 编辑器 JSON(TrackData)→ 运行时赛道节点树(SurfaceTool 条带网格 + Trimesh 碰撞)。
## 产出与 track_test 同契约:setup(env) / FinishGate(Area3D) /
## main_route_points(n) / hazard_route_points(),可被 RaceManager 无缝使用。
## 碰撞体分组 = GEVP 表面键(wheel.gd 取第一个分组名):主路 Road、分支 Dirt、草地 Grass。
##
## 主辅路衔接(岔口融合):dirt 端头若贴近主路,构建时做四件事——
## 宽度喇叭过渡 + 高度对齐主路 + 端帽延伸并推入主路路面之下(消除斜接缝),
## 并在岔口处断开主路侧墙与路缘边线;辅路进入主路覆盖区的几何直接裁剪掉,
## 只在路缘缝口留微小缝阶——两套路面在任何像素都不共面,从根上杜绝重叠闪烁。

const WALL_COLOR := Color(0.16, 0.17, 0.19)
const LINE_COLOR := Color(0.88, 0.88, 0.88)

# 垂直分离:草地顶面低于所有路面;标线浮在路面之上。
# 辅路不再整体下压也不下沉,主路覆盖区内的辅路几何直接裁剪(见 _build_strip)
const GRASS_DROP := 0.2
const MARKING_LIFT := 0.04

# --- 主辅路衔接参数 ---
const JUNCTION_ATTACH_DIST := 8.0   # 端头超出主路路缘此距离视为独立路段,不做衔接
const JUNCTION_BLEND := 14.0        # 衔接融合区长度(m):宽度喇叭 + 高度对齐
const JUNCTION_FLARE := 16.0        # 喇叭口目标宽度(不超过主路宽 85%,作者手调更宽则尊重)
const JUNCTION_EXT_MARGIN := 2.5    # 端头至少深入主路路面内该距离(把端帽藏进裁剪区)
const JUNCTION_EXT_MAX := 12.0      # 端头向主路内延伸上限
const JUNCTION_EXT_STEP := 1.5      # 延伸探测步长
const JUNCTION_CAP_INSET := 1.5     # 端帽角点离主路路缘的最小内深
const JUNCTION_CAP_PUSH := 8.0      # 端帽角点向路内推入上限
const SEAM_KERB := 0.03             # 裁剪缝口处辅路低于主路面的缝阶(防共线边闪烁)
const SEAM_BIAS := 0.03             # 裁剪边界目标:路缘外此距离(抵消弦弧差,保证零重叠)
const OVERPASS_CLEAR := 0.3         # 高出主路面此值的辅路视为立体交叉(桥),不裁剪
const WALL_BREAK_MARGIN := 4.0      # 岔口处墙体/边线断开区在主路方向的外扩余量

var data: TrackData = null
var junctions: Array = []   # 岔口记录:[{s: 主路弧长, half: 沿主路断开半长}](测试用)

var _road_mat: StandardMaterial3D
var _dirt_mat: StandardMaterial3D
var _grass_mat: StandardMaterial3D

func build(d: TrackData) -> void:
	data = d
	name = "TrackBuilt"
	junctions = []
	_road_mat = _mat(Color(0.22, 0.23, 0.26))
	_dirt_mat = _mat(Color(0.52, 0.40, 0.26), 1.0)
	_grass_mat = _mat(Color(0.30, 0.55, 0.28))

	# --- 草地(先铺底) ---
	add_child(_build_grass())

	# --- 主路 + 分支(分支做岔口融合) ---
	var road := _build_strip(data.main, "Road", _road_mat)
	add_child(road)
	for route in data.routes:
		if String(route["surface"]) == "dirt":
			add_child(_build_strip(_blend_dirt(route), "Dirt", _dirt_mat))

	# --- 侧墙(仅主路,沿用路面边缘) ---
	if bool(data.options.get("walls", true)):
		add_child(_build_walls(float(data.options.get("wall_height", 1.2))))

	# --- 路面标线(中心虚线 + 边线) ---
	add_child(_build_markings())

	# --- 起点柱 + 终点门 ---
	_build_start_posts()
	_build_finish_gate()

func _mat(c: Color, rough := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

## ---------------- 路面条带(网格 + Trimesh 碰撞) ----------------

## route 可携带融合产物:_blended(主路覆盖区内几何被裁剪,辅路精确止于路缘)、
## _cap_front/_cap_back(端帽两角绝对坐标,替代端截面常规展开,封死斜接缝)
func _build_strip(route: Dictionary, group: String, mat: StandardMaterial3D) -> StaticBody3D:
	var pts: PackedVector3Array = route["pts"]
	var tans: PackedVector3Array = route["tans"]
	var widths: PackedFloat32Array = route["widths"]
	var s_arr: PackedFloat32Array = route["s_arr"]
	var cap_f: Array = route.get("_cap_front", [])
	var cap_b: Array = route.get("_cap_back", [])

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var n := pts.size()
	var blended := route.has("_blended")

	# 逐截面展开左右顶点;oc < 0 = 不与主路重叠(保留),> 0 = 主路覆盖区内(裁剪)
	var lefts: Array = []
	var rights: Array = []
	for i in n:
		var side := TrackData._flat_normal(tans[i])
		var up := tans[i].cross(side).normalized()
		var w := widths[i] * 0.5
		var va := pts[i] + side * w
		var vb := pts[i] - side * w
		if i == 0 and cap_f.size() == 2:
			va = cap_f[0]
			vb = cap_f[1]
		if i == n - 1 and cap_b.size() == 2:
			va = cap_b[0]
			vb = cap_b[1]
		var v := s_arr[i] / 4.0  # UV 纵向:4m 一个周期
		lefts.append({"p": va, "uv": Vector2(0.0, v), "nrm": up,
			"oc": _overlap(va) if blended else -1.0})
		rights.append({"p": vb, "uv": Vector2(1.0, v), "nrm": up,
			"oc": _overlap(vb) if blended else -1.0})

	# 逐四边形裁剪发射(融合路由在主路覆盖区被裁掉,任何像素只剩一个路面)。
	# 喇叭口宽截面按 ≤4m 分列细分:长边线性插值会偏离弯曲路缘,细列让交点贴住真实边界
	for i in n - 1:
		var cols := 1
		if blended:
			cols = maxi(1, int(ceilf(maxf(widths[i], widths[i + 1]) / 4.0)))
		for j in cols:
			var f0 := float(j) / float(cols)
			var f1 := float(j + 1) / float(cols)
			var quad := [
				_lerp_corner(lefts[i], rights[i], f0),
				_lerp_corner(lefts[i], rights[i], f1),
				_lerp_corner(lefts[i + 1], rights[i + 1], f1),
				_lerp_corner(lefts[i + 1], rights[i + 1], f0),
			]
			if blended:
				for qd in quad:
					qd["oc"] = _overlap(qd["p"])  # 细分点重算真实覆盖值,不用插值
			var poly := _clip_to_road(quad) if blended else quad
			for k in range(2, poly.size()):
				_add_strip_vert(st, poly[0])
				_add_strip_vert(st, poly[k])
				_add_strip_vert(st, poly[k - 1])
	return _body_with_mesh(st.commit(), group)

func _lerp_corner(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	return {
		"p": (a["p"] as Vector3).lerp(b["p"], f),
		"uv": (a["uv"] as Vector2).lerp(b["uv"], f),
		"nrm": (a["nrm"] as Vector3).lerp(b["nrm"], f).normalized(),
		"oc": 0.0,
	}

func _add_strip_vert(st: SurfaceTool, d: Dictionary) -> void:
	st.set_normal(d["nrm"])
	st.set_uv(d["uv"])
	st.add_vertex(d["p"])

## 顶点相对主路覆盖区的裁剪值:负 = 保留(覆盖区外,或高出路面的立体交叉桥),
## 正 = 处于主路路面覆盖之下,应裁剪
func _overlap(v: Vector3) -> float:
	var lat := data.main_lateral(v)
	var inside := float(lat["half"]) - float(lat["dist"])
	if inside <= 0.0:
		return inside
	return inside if v.y < float(lat["road_y"]) + OVERPASS_CLEAR else -inside

func _inside_depth(v: Vector3) -> float:
	var lat := data.main_lateral(v)
	return float(lat["half"]) - float(lat["dist"])

## 四边形按"主路覆盖区外"(oc ≤ 0)裁剪,返回保留多边形;
## 裁剪交点迭代逼近真实路缘(SEAM_BIAS 外侧),压 SEAM_KERB 缝阶,与主路面永不共面
func _clip_to_road(poly: Array) -> Array:
	var out: Array = []
	var m := poly.size()
	for k in m:
		var c: Dictionary = poly[k]
		var nb: Dictionary = poly[(k + 1) % m]
		var oc_c := float(c["oc"])
		var oc_n := float(nb["oc"])
		if oc_c <= 0.0:
			out.append(c)
		if (oc_c <= 0.0) != (oc_n <= 0.0):
			var t := oc_c / (oc_c - oc_n)
			var p: Vector3 = c["p"].lerp(nb["p"], t)
			var kept: Vector3 = c["p"] if oc_c <= 0.0 else nb["p"]
			p = _snap_to_seam(p, kept)
			var lat := data.main_lateral(p)
			p.y = float(lat["road_y"]) - SEAM_KERB
			out.append({
				"p": p,
				"uv": (c["uv"] as Vector2).lerp(nb["uv"], t),
				"nrm": (c["nrm"] as Vector3).lerp(nb["nrm"], t).normalized(),
				"oc": 0.0,
			})
	return out

## 把裁剪交点 guess(线性插值,路缘弯曲时会偏进覆盖区)精化到"路缘外 SEAM_BIAS"处:
## 在 guess(覆盖侧)与保留端点(外侧)间二分;保留端已贴近路缘则直接取保留端。
## 返回点保证在真实路缘外侧 ≥ SEAM_BIAS-ε,主辅路几何零重叠
func _snap_to_seam(guess: Vector3, kept: Vector3) -> Vector3:
	if _inside_depth(guess) + SEAM_BIAS <= 0.0:
		return guess
	if _inside_depth(kept) + SEAM_BIAS > 0.0:
		return kept
	var lo := kept   # 路缘外侧(h ≤ 0)
	var hi := guess  # 覆盖侧(h > 0)
	for k in 7:
		var mid := lo.lerp(hi, 0.5)
		if _inside_depth(mid) + SEAM_BIAS > 0.0:
			hi = mid
		else:
			lo = mid
	return lo

func _body_with_mesh(mesh: ArrayMesh, group: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.add_to_group(group)
	var col := CollisionShape3D.new()
	col.shape = mesh.create_trimesh_shape()
	body.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	return body

## ---------------- 主辅路衔接(岔口融合) ----------------

## dirt 路由的构建副本:两端贴近主路时做端头延伸 + 宽度喇叭 + 高度对齐 +
## 端帽推入主路。原路由不动(玩法查询仍用原始数据);
## 主路覆盖区的裁剪见 _build_strip / _clip_to_road。
func _blend_dirt(route: Dictionary) -> Dictionary:
	var rt: Dictionary = route.duplicate(true)
	var attached := [false, false]  # [首端, 尾端] 是否衔接主路
	var road_ys := [0.0, 0.0]       # 对应主路路面高度
	var mouth_ws := [0.0, 0.0]      # 喇叭口宽度
	var pts: PackedVector3Array = rt["pts"]
	var widths: PackedFloat32Array = rt["widths"]
	var tans: PackedVector3Array = rt["tans"]

	for end_i in 2:
		var is_front := end_i == 0
		var ei := 0 if is_front else pts.size() - 1
		var lat := data.main_lateral(pts[ei])
		var half := float(lat["half"])
		if float(lat["dist"]) > half + JUNCTION_ATTACH_DIST:
			continue
		attached[end_i] = true
		road_ys[end_i] = float(lat["road_y"])
		# 喇叭口目标宽度:窄口抬到 JUNCTION_FLARE,不超过主路宽 85%;作者手调更宽则尊重
		mouth_ws[end_i] = maxf(widths[ei], minf(JUNCTION_FLARE, half * 2.0 * 0.85))
		# 端头沿切线延伸进主路(每步重投影,深度达标即停;越走越浅说明快穿到另一侧,不再伸)
		var dir := (-TrackData._flat_tangent(tans[0])) if is_front else TrackData._flat_tangent(tans[tans.size() - 1])
		var inside := half - float(lat["dist"])
		var p := pts[ei]
		for k in int(JUNCTION_EXT_MAX / JUNCTION_EXT_STEP):
			var cand := p + dir * JUNCTION_EXT_STEP
			var l2 := data.main_lateral(cand)
			var dep := float(l2["half"]) - float(l2["dist"])
			if dep < inside - 0.05:
				break
			p = cand
			inside = dep
			var pe := Vector3(cand.x, float(l2["road_y"]), cand.z)
			if is_front:
				pts.insert(0, pe)
				widths.insert(0, mouth_ws[end_i])
			else:
				pts.append(pe)
				widths.append(mouth_ws[end_i])
			if dep >= JUNCTION_EXT_MARGIN:
				break
		# 融合区:从端头向内 JUNCTION_BLEND 米,宽度喇叭张开 + 高度对齐主路(平滑混合)
		var mouth_w: float = mouth_ws[end_i]
		var ry: float = road_ys[end_i]
		var travelled := 0.0
		var i := 0
		var step := 1
		if not is_front:
			i = pts.size() - 1
			step = -1
		while i >= 0 and i < pts.size():
			var u := 1.0 - travelled / JUNCTION_BLEND
			var ss := smoothstep(0.0, 1.0, u)
			widths[i] = lerpf(widths[i], mouth_w, ss)
			var pp := pts[i]
			pp.y = lerpf(pp.y, ry, ss)
			pts[i] = pp
			var nxt := i + step
			if nxt < 0 or nxt >= pts.size():
				break
			travelled += pts[i].distance_to(pts[nxt])
			if travelled >= JUNCTION_BLEND:
				break
			i = nxt
		# 记录岔口(主路方向位置 + 断开半长),供墙体/边线开缺
		junctions.append({"s": float(lat["s"]), "half": mouth_w * 0.5 + WALL_BREAK_MARGIN})

	rt["pts"] = pts
	rt["widths"] = widths
	data._compute_tans_s(rt)
	data._compute_radii(rt)

	# 端帽:两角按喇叭口展开,再各自推入主路路面内 ≥ JUNCTION_CAP_INSET;
	# 端帽整体处于覆盖区,会在 _build_strip 的裁剪中移除——它的作用是把辅路
	# 可见边界顶到主路路缘上,斜接口不再留楔形缝
	tans = rt["tans"]
	for end_i in 2:
		if not attached[end_i]:
			continue
		var is_front := end_i == 0
		var ei := 0 if is_front else pts.size() - 1
		var tdir := (-TrackData._flat_tangent(tans[0])) if is_front else TrackData._flat_tangent(tans[tans.size() - 1])
		var nrm := TrackData._flat_normal(tdir)
		var cap_y := pts[ei].y
		var cap: Array = []
		for sgn: float in [1.0, -1.0]:
			var c: Vector3 = pts[ei] + nrm * (float(mouth_ws[end_i]) * 0.5 * sgn)
			c.y = cap_y
			var lc := data.main_lateral(c)
			var over := float(lc["dist"]) - (float(lc["half"]) - JUNCTION_CAP_INSET)
			if over > 0.0:
				var inward := (Vector2(float(lc["foot"].x), float(lc["foot"].z)) - Vector2(c.x, c.z)).normalized()
				c += Vector3(inward.x, 0.0, inward.y) * minf(over, JUNCTION_CAP_PUSH)
			cap.append(c)
		rt["_cap_front" if is_front else "_cap_back"] = cap

	# 主路覆盖区的裁剪在 _build_strip 里按四边形进行(_clip_to_road / _overlap)
	rt["_blended"] = true
	return rt

## 弧长 s 是否落在任一岔口断开区(墙体/边线开缺)
func _in_junction_mouth(s: float) -> bool:
	for j in junctions:
		if absf(s - float(j["s"])) < float(j["half"]):
			return true
	return false

## ---------------- 草地 ----------------

func _build_grass() -> StaticBody3D:
	var x0 := 1e9
	var x1 := -1e9
	var z0 := 1e9
	var z1 := -1e9
	var y_min := 1e9
	for route in data.routes:
		var pts: PackedVector3Array = route["pts"]
		for p in pts:
			x0 = minf(x0, p.x)
			x1 = maxf(x1, p.x)
			z0 = minf(z0, p.z)
			z1 = maxf(z1, p.z)
			y_min = minf(y_min, p.y)
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var w := (x1 - x0) + 160.0
	var d := (z1 - z0) + 160.0

	var body := StaticBody3D.new()
	body.name = "Grass"
	body.add_to_group("Grass")
	body.position = Vector3(cx, y_min - GRASS_DROP - 0.05, cz)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(w, 0.1, d)
	col.shape = shape
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w, 0.1, d)
	bm.material = _grass_mat
	mi.mesh = bm
	body.add_child(mi)
	return body

## ---------------- 侧墙(竖直条带) ----------------

func _build_walls(h: float) -> Node3D:
	var pts: PackedVector3Array = data.main["pts"]
	var tans: PackedVector3Array = data.main["tans"]
	var widths: PackedFloat32Array = data.main["widths"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var n := pts.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(WALL_COLOR, 0.95))
	var vcount := 0
	for sgn: float in [1.0, -1.0]:
		var kept := {}  # 保留截面索引 → 顶点基址(岔口内截面整体跳过,墙留出开口)
		for i in n:
			if _in_junction_mouth(s_arr[i]):
				continue
			var side := TrackData._flat_normal(tans[i])
			var edge := pts[i] + side * (widths[i] * 0.5 + 0.3) * sgn
			kept[i] = vcount
			st.set_normal(side * sgn)
			st.add_vertex(edge)
			st.set_normal(side * sgn)
			st.add_vertex(edge + Vector3(0, h, 0))
			vcount += 2
		for i in n - 1:
			if not (kept.has(i) and kept.has(i + 1)):
				continue
			var a: int = kept[i]
			st.add_index(a)
			st.add_index(a + 2)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(a + 2)
			st.add_index(a + 3)
	var mesh := st.commit()
	var body := StaticBody3D.new()
	body.name = "Walls"
	body.add_to_group("Road")  # 贴墙摩擦按路面(GEVP 取第一个分组名)
	var col := CollisionShape3D.new()
	col.shape = mesh.create_trimesh_shape()
	body.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	return body

## ---------------- 标线(中心虚线 + 边线) ----------------

func _build_markings() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := _mat(LINE_COLOR, 0.8)
	st.set_material(mat)
	var lift := MARKING_LIFT

	# 中心虚线:12m 周期画 6m,宽 0.3
	var s := 0.0
	while s < data.length - 6.0:
		_mark_quad(st, s + 0.0, s + 6.0, 0.15, 0, lift)
		s += 12.0
	# 边线:连续,宽 0.25,距路缘 0.4;岔口处断开(给辅路留出开口)
	s = 0.0
	while s < data.length - 6.0:
		if not _in_junction_mouth(s + 3.0):
			var w := data.width_at(s + 3.0) * 0.5 - 0.4
			_mark_quad(st, s, s + 6.0, 0.125, w, lift)
			_mark_quad(st, s, s + 6.0, 0.125, -w, lift)
		s += 6.0

	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = st.commit()
	return mi

var _vcount := 0  # 标线网格手动维护的顶点计数

## 沿中心线 s0→s1、横向 offset 处画一条标线 quad(offset 0 = 中心)
func _mark_quad(st: SurfaceTool, s0: float, s1: float, half_w: float, offset: float, lift: float) -> void:
	var p0 := data.point_at(s0) + Vector3(0, lift, 0)
	var p1 := data.point_at(s1) + Vector3(0, lift, 0)
	var n0 := data.normal_at(s0)
	var n1 := data.normal_at(s1)
	var a := _vcount
	for p in [p0 + n0 * (offset - half_w), p0 + n0 * (offset + half_w), p1 + n1 * (offset - half_w), p1 + n1 * (offset + half_w)]:
		st.set_normal(Vector3.UP)
		st.add_vertex(p)
		_vcount += 1
	st.add_index(a)
	st.add_index(a + 2)
	st.add_index(a + 1)
	st.add_index(a + 1)
	st.add_index(a + 2)
	st.add_index(a + 3)

## ---------------- 起点 / 终点 ----------------

func _build_start_posts() -> void:
	var p := data.start_point()
	var t := TrackData._flat_tangent(data.main["tans"][data.start_idx])
	var n := Vector3(t.z, 0.0, -t.x)
	var w := data.width_at(0.0) * 0.5 + 1.0
	for sgn: float in [1.0, -1.0]:
		var post := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.6, 5.0, 0.6)
		bm.material = _mat(Color(0.2, 0.75, 0.35))
		post.mesh = bm
		post.position = p + n * w * sgn + Vector3(0, 2.5, 0)
		add_child(post)

func _build_finish_gate() -> void:
	var p := data.finish_point()
	var t := data.finish_tangent()
	var n := Vector3(t.z, 0.0, -t.x)
	var w := data.width_at(data.length) * 0.5 + 1.5
	var yaw := atan2(-t.x, -t.z)

	# 门柱 + 横梁(纯视觉)
	for sgn: float in [1.0, -1.0]:
		var post := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.8, 6.0, 0.8)
		bm.material = _mat(Color(0.9, 0.9, 0.92))
		post.mesh = bm
		post.position = p + n * w * sgn + Vector3(0, 3.0, 0)
		add_child(post)
	var beam := MeshInstance3D.new()
	var bmm := BoxMesh.new()
	bmm.size = Vector3(w * 2.0, 0.8, 0.8)
	bmm.material = _mat(Color(0.9, 0.9, 0.92))
	beam.mesh = bmm
	beam.position = p + Vector3(0, 6.0, 0)
	beam.rotation.y = yaw
	add_child(beam)

	# 终点判定区(Area3D,与 track_test 的 FinishGate 同契约)
	var gate := Area3D.new()
	gate.name = "FinishGate"
	gate.position = p + Vector3(0, 2.5, 0)
	gate.rotation.y = yaw
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(w * 2.0, 5.0, 4.0)
	col.shape = shape
	gate.add_child(col)
	add_child(gate)

## ---------------- 契约接口(同 track_test) ----------------

## env = WeatherEnv 合成的完整环境配置：着色随地面色键；wet 时降粗糙度出湿面反光
func setup(env: Dictionary) -> void:
	_road_mat.albedo_color = env.road_c
	_dirt_mat.albedo_color = env.dirt_c
	_grass_mat.albedo_color = env.grass
	if bool(env.get("wet", false)):
		_road_mat.roughness = 0.22
		_road_mat.metallic = 0.25
		_dirt_mat.roughness = 0.55
	else:
		_road_mat.roughness = 0.9
		_road_mat.metallic = 0.0
		_dirt_mat.roughness = 1.0

func main_route_points(count: int) -> Array:
	return data.main_route_points(count)

func hazard_route_points() -> Array:
	return data.hazard_route_points()
