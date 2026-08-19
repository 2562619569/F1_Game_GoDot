class_name TrackBuilder
extends Node3D
## 编辑器 JSON(TrackData)→ 运行时赛道节点树(SurfaceTool 条带网格 + Trimesh 碰撞)。
## 产出与 track_test 同契约:setup(env) / FinishGate(Area3D) /
## main_route_points(n) / hazard_route_points(),可被 RaceManager 无缝使用。
## 碰撞体分组 = GEVP 表面键(wheel.gd 取第一个分组名):主路 Road、分支 Dirt、
## 砂石路肩 Gravel(低摩擦高滚阻惩罚)、草地 Grass。
##
## 主辅路衔接(岔口融合):dirt 端头若贴近主路,构建时做四件事——
## 宽度喇叭过渡 + 高度对齐主路 + 端帽延伸并推入主路路面之下(消除斜接缝),
## 并在岔口处断开路缘边线;辅路进入主路覆盖区的几何直接裁剪掉,
## 只在路缘缝口留微小缝阶——两套路面在任何像素都不共面,从根上杜绝重叠闪烁。
##
## 外退式护栏 + 砂石路肩:护栏不贴路缘,退到路缘外 barrier_offset 米处,
## 视觉高度仅 wall_height(低矮护栏);碰撞墙单独生成,远高于视觉并向下延伸,
## 防止车辆腾跃飞出。护栏与路缘之间铺砂石路肩(Gravel 表面,驶入即受罚)。
## 退距收紧(TrackData.allowance_field,详见 track_data.gd 顶部推导):
## 弯内侧的允许退距场 = max(R-margin,0) 经斜率≤1 锥形腐蚀——内缘既不越过
## 渐屈线(d·κ<1)也不折返(|Δd|≤Δs),领结四边形在构造上不可能;
## 发卡弯两腿/相邻路段贴近时再逐截面按远端路面走廊收紧,
## 两侧路面汇合处(真实发卡弯弯心)整段不放。
## 岔口处按辅路走廊(融合后 dirt 路面高度的覆盖区)自动开缺;
## 高架辅路(桥)不阻断护栏,但护栏碰撞墙在其下留净空。

const WALL_COLOR := Color(0.16, 0.17, 0.19)
const GRAVEL_COLOR := Color(0.60, 0.55, 0.45)
const LINE_COLOR := Color(0.88, 0.88, 0.88)

# 垂直分离:草地顶面低于所有路面;标线浮在路面之上。
# 辅路不再整体下压也不下沉,主路覆盖区内的辅路几何直接裁剪(见 _build_strip)
const GRASS_DROP := 0.2
const MARKING_LIFT := 0.04
# GB 5768 lane-divider convention: 6 m painted segment + 9 m gap.
const CENTER_DASH_LENGTH := 6.0
const CENTER_DASH_GAP := 9.0
const CENTER_DASH_PERIOD := CENTER_DASH_LENGTH + CENTER_DASH_GAP

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
const WALL_BREAK_MARGIN := 4.0      # 岔口处边线断开区在主路方向的外扩余量

# --- 外退式护栏 + 砂石路肩 ---
const GRAVEL_SEAM := 0.03          # 砂石路内缘低于主路面的缝阶(防共面闪烁)
const GRAVEL_SLOPE := 0.12         # 砂石路向外放坡至护栏脚下
const BARRIER_COLLISION_H := 5.0   # 护栏碰撞墙总高:远超视觉护栏,防腾跃飞出
const BARRIER_COLLISION_SINK := 0.6  # 碰撞墙向下延伸(防起伏贴地处钻空)
const CORRIDOR_MARGIN := 0.6       # 护栏开缺:岔口走廊判定余量
const CORRIDOR_GRAVEL_MARGIN := 0.1  # 砂石路裁剪:贴辅路边缘留的缝
const CORRIDOR_OVERHEAD := 2.5     # 高出主路此值的辅路段视为高架(桥/飞坡),不阻断护栏
const CORRIDOR_CLEARANCE := 1.5    # 桥下净空:碰撞墙顶 ≤ 桥面 - 此值
const ROAD_INNER_RADIUS := 3.0     # 急弯内缘保留的最小半径,防路面条带翻折/重叠
const BARRIER_INNER_RADIUS := 1.5  # 护栏偏移线在弯心外保留的最小半径
const OFFSET_SKIP := 0.4           # 退距被收紧到低于此值时该截面不放护栏/砂石(路面已汇合)
const FAR_S_EXCLUDE := 12.0        # 自身弯道近弧长段排除:护栏与自己路面天然重叠,不算冲突
const FAR_Y_SEP := 3.0             # 远端路面垂向分离:高差 ≥ 此值视为立体交叉,互不收紧/开缺
const FAR_MARGIN := 0.5            # 护栏线离任何远端路面截面的最小横向净距
const GRID_CELL := 16.0            # 主路段空间网格 cell(3×3 邻域覆盖 ≥ 最大半宽+净距)

# --- 高度路基边坡 ---
const APRON_SLOPE := 0.5           # 边坡坡度(1:2,每米高放 2 米宽)
const APRON_MIN_DROP := 0.35       # 路面高出草地平板该值才生成边坡截面
const APRON_MAX_RUN := 60.0        # 坡长上限(超高路堤坡脚截断,余下悬空由草地兜底)

var data: TrackData = null
var junctions: Array = []   # 岔口记录:[{s: 主路弧长, half: 沿主路断开半长}](测试用)
var dirt_corridors: Array = []  # 融合后 dirt 走廊(护栏/砂石路开缺依据,测试用)
var _fields := {}          # 退距场缓存:路由键 → {"road": …, "barrier": …}(与 pts 对齐)
var _road_grid: Dictionary = {}  # 主路段空间网格:Vector2i cell → PackedInt32Array(段索引)
var _rg_pts: PackedVector3Array    # 网格查询缓存(免每次字典取数组)
var _rg_widths: PackedFloat32Array
var _rg_s: PackedFloat32Array
var _rg_tans: PackedVector3Array

var _road_mat: StandardMaterial3D
var _dirt_mat: StandardMaterial3D
var _grass_mat: StandardMaterial3D
var _gravel_mat: StandardMaterial3D

func build(d: TrackData) -> void:
	data = d
	name = "TrackBuilt"
	junctions = []
	dirt_corridors = []
	_fields = {}
	_road_mat = _mat(Color(0.22, 0.23, 0.26))
	_dirt_mat = _mat(Color(0.52, 0.40, 0.26), 1.0)
	_grass_mat = _mat(Color(0.30, 0.55, 0.28))
	_gravel_mat = _mat(GRAVEL_COLOR, 1.0)

	# 远端路面网格(护栏退距收紧/路基边坡/桥下净空共用的空间索引)
	_build_road_grid()

	# --- 草地(先铺底) ---
	add_child(_build_grass())

	# --- 主路 + 分支(分支做岔口融合;走廊记录供护栏/砂石路开缺) ---
	var road := _build_strip(data.main, "Road", _road_mat)
	add_child(road)
	for route in data.routes:
		if String(route["surface"]) == "dirt":
			var blended := _blend_dirt(route)
			add_child(_build_strip(blended, "Dirt", _dirt_mat))
			dirt_corridors.append(_make_corridor(blended))

	# --- 砂石路肩 + 外退式低护栏(护栏退离路缘;碰撞面远高于视觉) ---
	var offs_l := PackedFloat32Array()
	var offs_r := PackedFloat32Array()
	if bool(data.options.get("walls", true)):
		var off := maxf(0.0, float(data.options.get("barrier_offset", 8.0)))
		var h := maxf(0.3, float(data.options.get("wall_height", 0.8)))
		# 砂石路宽独立于护栏退距(缺省回退退距值 = 旧行为:砂石铺满到护栏脚)
		var gw := maxf(0.0, float(data.options.get("gravel_width", off)))
		offs_l = _offsets(1.0, off)
		offs_r = _offsets(-1.0, off)
		if off > 0.05:
			var gravel := _build_gravel(gw, offs_l, offs_r)
			if gravel != null:
				add_child(gravel)
		var walls := _build_walls(h, offs_l, offs_r)
		if walls != null:
			add_child(walls)

	# --- 高度路基边坡(整体平的图不生成,零回归) ---
	var apron := _build_aprons(offs_l, offs_r)
	if apron != null:
		add_child(apron)

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
	var edge_l := _edge_offsets(route, 1.0)
	var edge_r := _edge_offsets(route, -1.0)

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
		var va := pts[i] + side * edge_l[i]
		var vb := pts[i] - side * edge_r[i]
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
			if not blended and poly.size() == 4:
				_emit_strip_quad(st, poly)
			else:
				for k in range(2, poly.size()):
					_add_strip_vert(st, poly[0])
					_add_strip_vert(st, poly[k])
					_add_strip_vert(st, poly[k - 1])
	return _body_with_mesh(st.commit(), group)

## 路由的允许退距场(缓存):road = 路缘退距(margin=ROAD_INNER_RADIUS),
## barrier = 护栏线总退距上限(margin=BARRIER_INNER_RADIUS,锚定全宽半路面)。
## 融合路由(_blend_dirt 产物)与原路由同 id 但几何不同,键上区分。
func _allow_fields(route: Dictionary) -> Dictionary:
	var key := String(route.get("id", "")) + ("|blended" if route.has("_blended") else "")
	if not _fields.has(key):
		_fields[key] = {
			"road": TrackData.allowance_field(route["radii"], route["s_arr"], ROAD_INNER_RADIUS),
			"barrier": TrackData.allowance_field(route["radii"], route["s_arr"], BARRIER_INNER_RADIUS),
		}
	return _fields[key]

## 弯内侧有效半宽(逐采样,与 pts 对齐):min(半宽, 允许退距场)。
## 急弯半径可小于半宽,全宽法线偏移会越过弯心把条带翻折;只收内缘,
## 外缘(凸侧)偏移永不折返保持全宽。退距场经 Lipschitz 锥形腐蚀,
## 内缘在弯前平滑收拢、弯心处收至弯心点,不再有逐点硬夹的台阶/锯齿。
func _edge_offsets(route: Dictionary, sgn: float) -> PackedFloat32Array:
	var pts: PackedVector3Array = route["pts"]
	var widths: PackedFloat32Array = route["widths"]
	var field: PackedFloat32Array = _allow_fields(route)["road"]
	var n := pts.size()
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(widths[i]) * 0.5
		if i == 0 or i == n - 1:
			continue
		var cross := _turn_cross(pts[i - 1], pts[i], pts[i + 1])
		if absf(cross) < 1e-6:
			continue
		# _flat_normal is expressed in x/z (z points forward as -z), so the
		# signed x/z cross has the opposite sign from the inward normal side.
		var inner := -1.0 if cross > 0.0 else 1.0
		if sgn == inner:
			out[i] = minf(out[i], float(field[i]))
	return out

func _turn_cross(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (b.x - a.x) * (c.z - b.z) - (b.z - a.z) * (c.x - b.x)

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

## 条带四边形固定绕序发射。内缘退距经 Lipschitz 收紧后,相邻截面左右顶点
## 恒保持横向次序,领结(对角自交)在构造上不可能——不再需要换对角线兜底;
## 发卡弯弯心处截面完全收拢时四边形退化为线,按面积阈值跳过。
## 绕序符号按截面法向逐四边形校验(侧向向量连续无翻转,符号恒一致)。
func _emit_strip_quad(st: SurfaceTool, quad: Array) -> void:
	var p0: Vector3 = quad[0]["p"]
	var p1: Vector3 = quad[1]["p"]
	var p2: Vector3 = quad[2]["p"]
	var nrm: Vector3 = ((quad[0]["nrm"] as Vector3) + (quad[2]["nrm"] as Vector3)).normalized()
	var s := (p2 - p0).cross(p1 - p0).dot(nrm)
	if absf(s) < 0.0001:
		return
	if s < 0.0:
		_emit_strip_tri(st, quad[0], quad[2], quad[1])
		_emit_strip_tri(st, quad[0], quad[3], quad[2])
	else:
		_emit_strip_tri(st, quad[0], quad[1], quad[2])
		_emit_strip_tri(st, quad[0], quad[2], quad[3])

func _emit_strip_tri(st: SurfaceTool, a: Dictionary, b: Dictionary, c: Dictionary) -> void:
	_add_strip_vert(st, a)
	_add_strip_vert(st, b)
	_add_strip_vert(st, c)

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

## 弧长 s 是否落在任一岔口断开区(路缘边线开缺;护栏/砂石路开缺改按走廊判定)
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

## ---------------- 高度路基边坡 ----------------

## 有高度的路由从路侧放坡到草地平板顶面(1:2 坡),高架路不再悬空、洼路不埋进平板。
## 内缘贴砂石外缘/护栏脚(主路)或路缘外 0.5m(辅路);坡脚遇垂向贴近的远端路面
## 自动收短(桥侧坡不吞并桥下车道);整体平的图完全不生成(零回归)。
## 坡脚截断/岔口走廊开缺留下的敞口由下方草地平板兜底,不露空腔。
func _build_aprons(offs_l: PackedFloat32Array, offs_r: PackedFloat32Array) -> StaticBody3D:
	var y_min := 1e9
	for route in data.routes:
		var pts0: PackedVector3Array = route["pts"]
		for p in pts0:
			y_min = minf(y_min, p.y)
	var slab_top := y_min - GRASS_DROP - 0.02
	var walls_on := bool(data.options.get("walls", true))
	var off := maxf(0.0, float(data.options.get("barrier_offset", 8.0)))
	var gw := maxf(0.0, float(data.options.get("gravel_width", off)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_grass_mat)
	var quads := 0
	for route in data.routes:
		var pts: PackedVector3Array = route["pts"]
		var tans: PackedVector3Array = route["tans"]
		var widths: PackedFloat32Array = route["widths"]
		var s_arr: PackedFloat32Array = route["s_arr"]
		var n := pts.size()
		var is_main := String(route["surface"]) == "road"
		var elevated := false
		for i in n:
			if pts[i].y - slab_top > APRON_MIN_DROP + GRASS_DROP:
				elevated = true
				break
		if not elevated:
			continue
		for sgn: float in [1.0, -1.0]:
			var kept: Array = []   # [截面索引, 内缘顶点, 坡脚顶点]
			for i in n:
				var drop: float = pts[i].y - slab_top
				if drop <= APRON_MIN_DROP:
					continue
				var side := TrackData._flat_normal(tans[i])
				var half: float = widths[i] * 0.5
				var inner_off := half + 0.5
				if is_main and walls_on and off > 0.05:
					var w_off: float = float(offs_l[i] if sgn > 0.0 else offs_r[i])
					inner_off = half + maxf(minf(gw, w_off), 0.3)
				var inner := pts[i] + side * inner_off * sgn
				inner.y = pts[i].y - 0.14
				var want: float = minf((inner.y - slab_top) / APRON_SLOPE, APRON_MAX_RUN)
				var run := _apron_run_limit(float(s_arr[i]), want, inner, side, sgn)
				if run < 1.0:
					continue
				var outer := inner + side * run * sgn
				outer.y = maxf(slab_top, inner.y - run * APRON_SLOPE)
				kept.append([i, inner, outer])
			for k in kept.size() - 1:
				if int(kept[k + 1][0]) != int(kept[k][0]) + 1:
					continue
				var a: Array = kept[k]
				var b: Array = kept[k + 1]
				var mid: Vector3 = (a[1] + a[2] + b[1] + b[2]) * 0.25
				if bool(_corridor_at(mid, 0.0)["blocked"]):
					continue  # 岔口走廊内不开坡(会埋掉辅路口)
				_strip_quad(st, a[1], a[2], b[2], b[1], Vector3.UP)
				quads += 1
	if quads == 0:
		return null
	var body := _body_with_mesh(st.commit(), "Grass")
	body.name = "GrassApron"
	return body

## 坡长收短:坡脚(沿坡线下滑到 inner.y - run×APRON_SLOPE)不得落入任何垂向贴近的
## 远端主路路面。梯子试探 + 二分,同 _far_road_limit 思路,只是探测点带坡度高度
func _apron_run_limit(s_own: float, want: float, inner: Vector3, side: Vector3, sgn: float) -> float:
	if want <= 1.0:
		return want
	var probe := func(run: float) -> bool:
		var p := inner + side * run * sgn
		p.y = inner.y - run * APRON_SLOPE
		return _hits_far_road(p, s_own)
	if not probe.call(want):
		return want
	var lo := 0.0
	for cand: float in [12.0, 8.0, 4.0, 2.0]:
		if cand >= want:
			continue
		if not probe.call(cand):
			lo = cand
			break
	var hi := want
	for k in 4:
		var mid := (lo + hi) * 0.5
		if probe.call(mid):
			hi = mid
		else:
			lo = mid
	return lo

## ---------------- 岔口走廊(护栏/砂石路开缺依据) ----------------

## 融合后 dirt 路由 → 走廊段集合。路面高度的路段在岔口处阻断护栏与砂石路;
## 高架段(桥/飞坡,高出主路 CORRIDOR_OVERHEAD 以上)不阻断,但其高度用于
## 压低护栏碰撞墙顶(桥下留 CORRIDOR_CLEARANCE 净空)。
func _make_corridor(route: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = route["pts"]
	var widths: PackedFloat32Array = route["widths"]
	var segs: Array = []
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	var reach := 0.0
	for i in pts.size() - 1:
		var half := maxf(widths[i], widths[i + 1]) * 0.5
		segs.append({"a": pts[i], "b": pts[i + 1], "half": half,
			"my": (pts[i].y + pts[i + 1].y) * 0.5})
		lo = lo.min(Vector2(pts[i].x, pts[i].z))
		hi = hi.max(Vector2(pts[i].x, pts[i].z))
		reach = maxf(reach, half)
	return {"segs": segs, "lo": lo, "hi": hi, "reach": reach + 1.0}

## 点相对岔口走廊的状态:blocked = 与路面高度的辅路重叠(护栏/砂石路断开);
## cap = 上方高架辅路允许的碰撞墙顶(绝对高度,无高架则 1e9)
func _corridor_at(p: Vector3, margin: float) -> Dictionary:
	var blocked := false
	var cap := 1e9
	var q := Vector2(p.x, p.z)
	for cor in dirt_corridors:
		var m: float = float(cor["reach"]) + margin
		var clo: Vector2 = cor["lo"]
		var chi: Vector2 = cor["hi"]
		if q.x < clo.x - m or q.x > chi.x + m or q.y < clo.y - m or q.y > chi.y + m:
			continue
		for seg in cor["segs"]:
			if _seg_dist(q, seg["a"], seg["b"]) < float(seg["half"]) + margin:
				var sy: float = float(seg["my"])
				if sy < p.y + CORRIDOR_OVERHEAD:
					blocked = true
				else:
					cap = minf(cap, sy - CORRIDOR_CLEARANCE)
	return {"blocked": blocked, "cap": cap}

func _seg_dist(q: Vector2, a: Vector3, b: Vector3) -> float:
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var L2 := ab.length_squared()
	if L2 < 1e-8:
		return q.distance_to(Vector2(a.x, a.z))
	var t := clampf((q - Vector2(a.x, a.z)).dot(ab) / L2, 0.0, 1.0)
	return (Vector2(a.x, a.z) + ab * t).distance_to(q)

## 点相对岔口走廊(仅路面高度的辅路)的侵入深度:正 = 走廊内(砂石裁掉),负 = 外。
## 砂石路肩用它与 _clip_oc 做多边形裁剪,边缘贴合辅路真实边界(无阶梯/草缝)
func _corridor_oc(p: Vector3, margin: float) -> float:
	var depth := -1e9
	var q := Vector2(p.x, p.z)
	for cor in dirt_corridors:
		var m: float = float(cor["reach"]) + margin
		var clo: Vector2 = cor["lo"]
		var chi: Vector2 = cor["hi"]
		if q.x < clo.x - m or q.x > chi.x + m or q.y < clo.y - m or q.y > chi.y + m:
			continue
		for seg in cor["segs"]:
			if float(seg["my"]) >= p.y + CORRIDOR_OVERHEAD:
				continue
			depth = maxf(depth, float(seg["half"]) + margin - _seg_dist(q, seg["a"], seg["b"]))
	return depth

## 多边形按"走廊外"(oc ≤ 0)裁剪,交点线性插值;同 _clip_to_road 的思路。
## 插值初值在弯曲的 dirt 边缘可偏差半米,再二分精化到贴边(伸入 ≤5cm 隐形区,
## 该 5cm 在 dirt 表面下方 3cm,被完全覆盖——砂石与辅路零缝衔接)
func _clip_oc(poly: Array) -> Array:
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
			var p: Vector3 = (c["p"] as Vector3).lerp(nb["p"], t)
			p = _snap_to_corridor_edge(p, c["p"] if oc_c <= 0.0 else nb["p"])
			out.append({"p": p, "oc": 0.0})
	return out

## 把裁剪交点 guess(走廊内)精化到 dirt 边缘外 ≤5cm:kept(外侧)与 guess 间二分,
## 取最深的安全点。目标函数用 margin=-0.05(允许伸入 5cm,由 dirt 表面覆盖)
func _snap_to_corridor_edge(guess: Vector3, kept: Vector3) -> Vector3:
	if _corridor_oc(guess, -0.05) <= 0.0:
		return guess
	if _corridor_oc(kept, -0.05) > 0.0:
		return kept
	var lo := kept   # 走廊外(g ≤ 0)
	var hi := guess  # 走廊内(g > 0)
	for k in 5:
		var mid := lo.lerp(hi, 0.5)
		if _corridor_oc(mid, -0.05) > 0.0:
			hi = mid
		else:
			lo = mid
	return lo

## 护栏退距沿主路逐截面计算,两步收紧:
## 1) 曲率收紧:弯内侧护栏线总偏移(全宽半路面 + 退距)≤ 允许退距场
##    (margin=BARRIER_INNER_RADIUS,与旧逐点公式 R-half-1.5 等价的场化形式),
##    场自带 Lipschitz 平滑——替代旧的"逐点硬夹 + 5 点滑动平均",左右对称无台阶;
##    外侧(凸侧)偏移永不折返,保持全退距;
## 2) 距离感知:发卡弯两腿/相邻路段贴近时,曲率还很大护栏就已经立在对面腿的路面上了
##    (map_1 实测侵入 7m)。逐截面把护栏线往回收到不落入任何远端路面走廊
##    (|Δs|>FAR_S_EXCLUDE 的截面横向 dist ≥ half+FAR_MARGIN),梯子试探 + 二分细化;
##    收到 OFFSET_SKIP 以下说明两侧路面已汇合(真实发卡弯弯心本就是全铺装),不放护栏。
func _offsets(sgn: float, off: float) -> PackedFloat32Array:
	var pts: PackedVector3Array = data.main["pts"]
	var widths: PackedFloat32Array = data.main["widths"]
	var n := pts.size()
	var field: PackedFloat32Array = _allow_fields(data.main)["barrier"]
	var out := PackedFloat32Array()
	out.resize(n)
	out.fill(off)
	for i in range(1, n - 1):
		var cross := _turn_cross(pts[i - 1], pts[i], pts[i + 1])
		if absf(cross) < 1e-6:
			continue
		var inner := -1.0 if cross > 0.0 else 1.0
		if sgn != inner:
			continue
		out[i] = minf(off, maxf(0.0, float(field[i]) - float(widths[i]) * 0.5))
	# 距离感知收紧(只减不增,收紧后的值仍满足曲率安全)。
	# 冲突只发生在两腿贴近的短弧段内:粗扫(步长 3)定位冲突带,带内才逐截面梯子,
	# 查询量降一个量级(每回合构建赛道都要跑,调试版 GDScript 必须省着调用)
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var suspect := PackedByteArray()
	suspect.resize(n)
	suspect.fill(0)
	for i in range(0, n, 3):
		if _hits_far_road(_barrier_point(i, sgn, out[i]), float(s_arr[i])):
			for k in range(maxi(0, i - 8), mini(n, i + 9)):
				suspect[k] = 1
	for i in n:
		if suspect[i] == 1:
			out[i] = _far_road_limit(i, sgn, out[i], float(s_arr[i]))
	# 远端收紧留下的一格深坑(相邻 8m 中夹 0m)按斜率 ≤1 锥形铺开,
	# 开缺边沿不结针尖;只降不升,安全约束不破
	return TrackData.cone_smooth(out, s_arr, 4.0)

## 梯子试探 + 二分:返回 ≤ want 的最大安全退距
func _far_road_limit(i: int, sgn: float, want: float, s_own: float) -> float:
	if want <= OFFSET_SKIP or not _hits_far_road(_barrier_point(i, sgn, want), s_own):
		return want
	var lo := -1.0
	for cand: float in [4.0, 2.0, 1.0, 0.0]:
		var safe_cand := minf(cand, want)
		if not _hits_far_road(_barrier_point(i, sgn, safe_cand), s_own):
			lo = safe_cand
			break
	if lo < 0.0:
		return 0.0
	var hi := want
	for k in 4:
		var mid := (lo + hi) * 0.5
		if _hits_far_road(_barrier_point(i, sgn, mid), s_own):
			hi = mid
		else:
			lo = mid
	return lo

## 截面 i 侧向 sgn、退距 off_v 处的护栏线点
func _barrier_point(i: int, sgn: float, off_v: float) -> Vector3:
	var side := TrackData._flat_normal(_rg_tans[i])
	return _rg_pts[i] + side * (float(_rg_widths[i]) * 0.5 + off_v) * sgn

## 主路折线段按中点塞进空间网格(查询只看 3×3 邻域,段长 2m 时覆盖 ≥16m)
func _build_road_grid() -> void:
	_road_grid = {}
	_rg_pts = data.main["pts"]
	_rg_widths = data.main["widths"]
	_rg_s = data.main["s_arr"]
	_rg_tans = data.main["tans"]
	var pts := _rg_pts
	for i in pts.size() - 1:
		var key := Vector2i(int(floor((pts[i].x + pts[i + 1].x) * 0.5 / GRID_CELL)), \
				int(floor((pts[i].z + pts[i + 1].z) * 0.5 / GRID_CELL)))
		if not _road_grid.has(key):
			_road_grid[key] = PackedInt32Array()
		_road_grid[key].append(i)

## 点是否落入任一远端路面走廊(近弧长段排除:护栏与自己/相邻截面天然贴近,不算冲突;
## 垂向分离:高差 ≥ FAR_Y_SEP 视为立体交叉,桥上桥下互不算冲突——护栏/砂石各自保留)。
## 段级盒预筛先行(内联比较,免 _seg_dist 函数调用),调试版 GDScript 下查询便宜一个量级
func _hits_far_road(p: Vector3, s_own: float) -> bool:
	var cx := int(floor(p.x / GRID_CELL))
	var cz := int(floor(p.z / GRID_CELL))
	var qx := p.x
	var qz := p.z
	for gx in range(cx - 1, cx + 2):
		for gz in range(cz - 1, cz + 2):
			var segs: PackedInt32Array = _road_grid.get(Vector2i(gx, gz), PackedInt32Array())
			for i in segs:
				var a: Vector3 = _rg_pts[i]
				var b: Vector3 = _rg_pts[i + 1]
				if absf((a.y + b.y) * 0.5 - p.y) >= FAR_Y_SEP:
					continue
				if absf(float(_rg_s[i]) - s_own) <= FAR_S_EXCLUDE \
						and absf(float(_rg_s[i + 1]) - s_own) <= FAR_S_EXCLUDE:
					continue
				var r := float(_rg_widths[i]) * 0.5 + FAR_MARGIN
				if (qx < a.x - r and qx < b.x - r) or (qx > a.x + r and qx > b.x + r) \
						or (qz < a.z - r and qz < b.z - r) or (qz > a.z + r and qz > b.z + r):
					continue
				if _seg_dist(Vector2(qx, qz), a, b) < r:
					return true
	return false

## 自身环线高架:查询点上方若有远端主路截面(高出 ≥ FAR_Y_SEP 且横向贴近),
## 返回其中最低的"桥面高度 - CORRIDOR_CLEARANCE"(桥下碰撞墙顶上限);
## 无高架返回 1e9
func _main_overhead_cap(p: Vector3, s_own: float) -> float:
	var cap := 1e9
	var cx := int(floor(p.x / GRID_CELL))
	var cz := int(floor(p.z / GRID_CELL))
	for gx in range(cx - 1, cx + 2):
		for gz in range(cz - 1, cz + 2):
			var segs: PackedInt32Array = _road_grid.get(Vector2i(gx, gz), PackedInt32Array())
			for i in segs:
				var a: Vector3 = _rg_pts[i]
				var b: Vector3 = _rg_pts[i + 1]
				var sy: float = (a.y + b.y) * 0.5
				if sy < p.y + FAR_Y_SEP:
					continue
				if absf(float(_rg_s[i]) - s_own) <= FAR_S_EXCLUDE \
						and absf(float(_rg_s[i + 1]) - s_own) <= FAR_S_EXCLUDE:
					continue
				var r := float(_rg_widths[i]) * 0.5 + FAR_MARGIN
				if (p.x < a.x - r and p.x < b.x - r) or (p.x > a.x + r and p.x > b.x + r) \
						or (p.z < a.z - r and p.z < b.z - r) or (p.z > a.z + r and p.z > b.z + r):
					continue
				if _seg_dist(Vector2(p.x, p.z), a, b) < r:
					cap = minf(cap, sy - CORRIDOR_CLEARANCE)
	return cap

## ---------------- 砂石路肩(路缘 → 砂石外缘,Gravel 表面惩罚) ----------------

## 砂石外缘 = min(gravel_width, 护栏退距收紧值)——砂石路宽独立可调,永不越过护栏线。
## 岔口处砂石 quad 按辅路走廊做精确多边形裁剪(边缘贴合辅路真实边界);
## 退距被收紧到 OFFSET_SKIP 以下的截面(汇合弯心)整段不放
func _build_gravel(gw: float, offs_l: PackedFloat32Array, offs_r: PackedFloat32Array) -> StaticBody3D:
	var pts: PackedVector3Array = data.main["pts"]
	var tans: PackedVector3Array = data.main["tans"]
	var widths: PackedFloat32Array = data.main["widths"]
	var n := pts.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_gravel_mat)
	var quads := 0
	for sgn: float in [1.0, -1.0]:
		var offs := offs_l if sgn > 0.0 else offs_r
		var kept: Array = []   # [截面索引, {p,oc} 内缘, {p,oc} 外缘]
		for i in n:
			var g_off: float = minf(gw, float(offs[i]))
			if g_off < OFFSET_SKIP:
				continue
			var side := TrackData._flat_normal(tans[i])
			var half: float = widths[i] * 0.5
			var inner := pts[i] + side * half * sgn
			var outer := pts[i] + side * (half + g_off) * sgn
			inner.y -= GRAVEL_SEAM
			outer.y -= GRAVEL_SLOPE
			kept.append([i,
				{"p": inner, "oc": _corridor_oc(inner, CORRIDOR_GRAVEL_MARGIN)},
				{"p": outer, "oc": _corridor_oc(outer, CORRIDOR_GRAVEL_MARGIN)}])
		for k in kept.size() - 1:
			if int(kept[k + 1][0]) != int(kept[k][0]) + 1:
				continue
			var ia := int(kept[k][0])
			var ib := int(kept[k + 1][0])
			var gravel_mid: Vector3 = (kept[k][1]["p"] + kept[k][2]["p"] \
					+ kept[k + 1][1]["p"] + kept[k + 1][2]["p"]) * 0.25
			var gravel_s := (float(data.main["s_arr"][ia]) + float(data.main["s_arr"][ib])) * 0.5
			if _hits_far_road(gravel_mid, gravel_s):
				continue
			var poly := _clip_oc([kept[k][1], kept[k][2], kept[k + 1][2], kept[k + 1][1]])
			if poly.size() < 3:
				continue
			for t in range(2, poly.size()):
				for corner in [poly[0], poly[t], poly[t - 1]]:
					st.set_normal(Vector3.UP)
					st.add_vertex(corner["p"])
			quads += 1
	if quads == 0:
		return null
	var body := _body_with_mesh(st.commit(), "Gravel")
	body.name = "Gravel"
	return body

## ---------------- 外退式低护栏(碰撞面远高于视觉) ----------------

## 视觉:路缘外 off 米处的低矮竖直条带(高 h);
## 碰撞:同一条线上从视觉顶再向上延伸到 BARRIER_COLLISION_H 并向下沉
## BARRIER_COLLISION_SINK——车撞上/腾跃砸到的是隐形高墙,飞不出去。
## 岔口走廊处整体开缺;高架桥下碰撞墙顶压到桥面以下留净空
## (辅路走廊与自身环线高架桥面都算);退距被收紧到 OFFSET_SKIP 以下的截面不放。
func _build_walls(h: float, offs_l: PackedFloat32Array, offs_r: PackedFloat32Array) -> StaticBody3D:
	var pts: PackedVector3Array = data.main["pts"]
	var tans: PackedVector3Array = data.main["tans"]
	var widths: PackedFloat32Array = data.main["widths"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var n := pts.size()
	var vis := SurfaceTool.new()
	vis.begin(Mesh.PRIMITIVE_TRIANGLES)
	vis.set_material(_mat(WALL_COLOR, 0.95))
	var col := SurfaceTool.new()
	col.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for sgn: float in [1.0, -1.0]:
		var offs := offs_l if sgn > 0.0 else offs_r
		var kept: Array = []   # [截面索引, 基点, 法线, 碰撞墙顶绝对高度]
		for i in n:
			if offs[i] < OFFSET_SKIP:
				continue  # 两侧路面已汇合(发卡弯心),不放护栏
			var side := TrackData._flat_normal(tans[i])
			var base := pts[i] + side * (widths[i] * 0.5 + offs[i]) * sgn
			base.y -= GRAVEL_SLOPE
			var cor := _corridor_at(base, CORRIDOR_MARGIN)
			if bool(cor["blocked"]):
				continue
			# 桥下净空:辅路走廊 cap 与自身环线高架桥面取更 低 者
			var cap: float = minf(float(cor["cap"]), _main_overhead_cap(base, float(s_arr[i])))
			var col_h: float = minf(BARRIER_COLLISION_H, cap - base.y)
			if col_h < h + 0.2:
				continue  # 高架太低贴住护栏,视同岔口开缺
			kept.append([i, base, side * sgn, base.y + col_h])
		for k in kept.size() - 1:
			if int(kept[k + 1][0]) != int(kept[k][0]) + 1:
				continue
			var a: Array = kept[k]
			var b: Array = kept[k + 1]
			var wall_mid: Vector3 = (a[1] + b[1]) * 0.5
			var wall_s := (float(s_arr[int(a[0])]) + float(s_arr[int(b[0])])) * 0.5
			if _hits_far_road(wall_mid, wall_s):
				continue
			var nrm: Vector3 = a[2]
			_strip_quad(vis, a[1], a[1] + Vector3(0, h, 0),
					b[1] + Vector3(0, h, 0), b[1], nrm)
			_strip_quad(col, a[1] - Vector3(0, BARRIER_COLLISION_SINK, 0),
					Vector3(a[1].x, a[3], a[1].z),
					Vector3(b[1].x, b[3], b[1].z),
					b[1] - Vector3(0, BARRIER_COLLISION_SINK, 0), nrm)
			quads += 1
	if quads == 0:
		return null
	var body := StaticBody3D.new()
	body.name = "Walls"
	body.add_to_group("Road")  # 贴墙摩擦按路面(GEVP 取第一个分组名)
	var cshape := CollisionShape3D.new()
	cshape.shape = col.commit().create_trimesh_shape()
	body.add_child(cshape)
	var mi := MeshInstance3D.new()
	mi.mesh = vis.commit()
	body.add_child(mi)
	return body

func _strip_quad(st: SurfaceTool, bl: Vector3, tl: Vector3, tr: Vector3, br: Vector3, nrm: Vector3) -> void:
	for p in [bl, tl, tr, bl, tr, br]:
		st.set_normal(nrm)
		st.add_vertex(p)

## ---------------- 标线(中心虚线 + 边线) ----------------

func _build_markings() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := _mat(LINE_COLOR, 0.8)
	st.set_material(mat)
	var lift := MARKING_LIFT

	# 中心虚线:12m 周期画 6m,宽 0.3
	var s := 0.0
	while s < data.length - CENTER_DASH_LENGTH:
		_mark_quad(st, s, s + CENTER_DASH_LENGTH, 0.15, 0, lift)
		s += CENTER_DASH_PERIOD
	# 边线:连续,宽 0.25,距路缘 0.4;岔口处断开(给辅路留出开口)。
	# 横向位置按有效半宽取(急弯内缘被退距场收拢后,全宽位置会画到草地/砂石上);
	# 收拢到不足 0.3m 处不再画边线(弯心本就是全铺装汇合区)
	s = 0.0
	var edge_l := _edge_offsets(data.main, 1.0)
	var edge_r := _edge_offsets(data.main, -1.0)
	while s < data.length - 6.0:
		if not _in_junction_mouth(s + 3.0):
			var sm := s + 3.0
			var wl := data.field_at(edge_l, sm) - 0.4
			var wr := data.field_at(edge_r, sm) - 0.4
			if wl > 0.3:
				_mark_quad(st, s, s + 6.0, 0.125, wl, lift)
			if wr > 0.3:
				_mark_quad(st, s, s + 6.0, 0.125, -wr, lift)
		s += 6.0

	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = st.commit()
	return mi

var _vcount := 0  # 标线网格手动维护的顶点计数

## 沿中心线 s0→s1、横向 offset 处画一条标线 quad(offset 0 = 中心)。
## 按 ≤2m 细分跟随路面折线弦:6m 单根长弦在凸竖曲线(坡顶)上会切进路面下方
func _mark_quad(st: SurfaceTool, s0: float, s1: float, half_w: float, offset: float, lift: float) -> void:
	var steps := maxi(1, int(ceilf((s1 - s0) / 2.0)))
	var prev := _mark_row(s0, half_w, offset, lift)
	for k in range(1, steps + 1):
		var row := _mark_row(s0 + (s1 - s0) * float(k) / float(steps), half_w, offset, lift)
		var a := _vcount
		for p in [prev[0], prev[1], row[0], row[1]]:
			st.set_normal(Vector3.UP)
			st.add_vertex(p)
			_vcount += 1
		st.add_index(a)
		st.add_index(a + 2)
		st.add_index(a + 1)
		st.add_index(a + 1)
		st.add_index(a + 2)
		st.add_index(a + 3)
		prev = row

## 标线截面两顶点(横向 offset±half_w,路面折线弦上抬 lift)
func _mark_row(s: float, half_w: float, offset: float, lift: float) -> Array:
	var p := data.point_at(s) + Vector3(0, lift, 0)
	var n := data.normal_at(s)
	return [p + n * (offset - half_w), p + n * (offset + half_w)]

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
	# 只认车辆检测层:车体物理层剥离后(幽灵复位)冲线判定仍有效
	gate.collision_mask = Racer.LAYER_CAR_DETECT
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
	_gravel_mat.albedo_color = env.get("gravel_c", GRAVEL_COLOR)
	if bool(env.get("wet", false)):
		_road_mat.roughness = 0.22
		_road_mat.metallic = 0.25
		_dirt_mat.roughness = 0.55
		_gravel_mat.roughness = 0.75
	else:
		_road_mat.roughness = 0.9
		_road_mat.metallic = 0.0
		_dirt_mat.roughness = 1.0
		_gravel_mat.roughness = 1.0

func main_route_points(count: int) -> Array:
	return data.main_route_points(count)

func hazard_route_points() -> Array:
	return data.hazard_route_points()
