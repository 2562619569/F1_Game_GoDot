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
## 砂石/护栏/边坡一律锚"有效路缘"(急弯被退距场收拢后的实际路面边):
## 收拢区路面→砂石连续衔接,不再露草沟;护栏总退距(有效路缘+退距)≤ R-1.5。
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
const GRAVEL_DROP := 0.15           # 路肩总落差:路缘平接,护栏脚下最低(仍高于草平板 5cm)
const GRAVEL_BEVEL := 1.1           # 路肩陡段尺度:贴路缘 ~14% 斜面,1m 降 9.5cm,2m 外指数放缓
const BARRIER_COLLISION_H := 5.0   # 护栏碰撞墙总高:远超视觉护栏,防腾跃飞出
const BARRIER_COLLISION_SINK := 0.6  # 碰撞墙向下延伸(防起伏贴地处钻空)
const CORRIDOR_MARGIN := 0.6       # 护栏开缺:岔口走廊判定余量
const CORRIDOR_GRAVEL_MARGIN := 0.1  # 砂石路裁剪:贴辅路边缘留的缝
const CORRIDOR_OVERHEAD := 2.5     # 高出主路此值的辅路段视为高架(桥/飞坡),不阻断护栏
const CORRIDOR_CLEARANCE := 1.5    # 桥下净空:碰撞墙顶 ≤ 桥面 - 此值
const ROAD_INNER_RADIUS := 3.0     # 急弯内缘保留的最小半径(标线边线定位的退距场用)
const BARRIER_INNER_RADIUS := 1.5  # 护栏偏移线在弯心外保留的最小半径(同上,仅标线沿用)
const FAR_Y_SEP := 3.0             # 立体交叉垂向分离:高差 ≥ 此值视为上下两层
# --- 距离场等值线(路面/砂石/护栏的统一驱动,见 track_field.gd) ---
const FIELD_CELL := 1.0            # 值点阵格距:等值线精度(格距一半以内)
const SIMP_SURFACE := 0.15         # 表面等值线抽稀容差(路面/砂石共用同表,零缝)
const SIMP_WALL := 0.25            # 护栏等值线抽稀容差(独立竖面,可粗些)
const WALL_MIN_PERIM := 8.0        # 护栏环最小周长:腰部退化的碎环不立墙

# --- 高度路基边坡 ---
const APRON_SLOPE := 0.5           # 边坡坡度(1:2,每米高放 2 米宽)
const APRON_MIN_DROP := 0.35       # 路面高出草地平板该值才生成边坡截面
const APRON_MAX_RUN := 60.0        # 坡长上限(超高路堤坡脚截断,余下悬空由草地兜底)

var data: TrackData = null
var junctions: Array = []   # 岔口记录:[{s: 主路弧长, half: 沿主路断开半长}](测试用)
var dirt_corridors: Array = []  # 融合后 dirt 走廊(测试用,zfight 检查引用)
var field_main: TrackField = null  # 主路胶囊并集场(路面表面/砂石环带)
var field_all: TrackField = null   # 主路+分支并集场(护栏,绕开岔口)
var _region_cache := {}            # "field_id@level" → 简单多边形集合(同层复用)
var _fields := {}          # 退距场缓存(标线边线定位沿用):路由键 → {"road": …, "barrier": …}
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
	_region_cache = {}
	_road_mat = _mat(Color(0.22, 0.23, 0.26))
	_dirt_mat = _mat(Color(0.52, 0.40, 0.26), 1.0)
	_grass_mat = _mat(Color(0.30, 0.55, 0.28))
	_gravel_mat = _mat(GRAVEL_COLOR, 1.0)

	# --- 场构建(路面/砂石/护栏全部由等值线驱动,见 track_field.gd 头注释) ---
	var off := maxf(0.0, float(data.options.get("barrier_offset", 8.0)))
	var h := maxf(0.3, float(data.options.get("wall_height", 0.8)))
	var gw := maxf(0.0, float(data.options.get("gravel_width", off)))
	var walls_on := bool(data.options.get("walls", true))
	field_main = TrackField.new()
	field_main.add_route(data.main)
	field_all = TrackField.new()
	field_all.add_route(data.main)
	var blended: Array = []
	for route in data.routes:
		if String(route["surface"]) == "dirt":
			var b := _blend_dirt(route)
			blended.append(b)
			field_all.add_route(b)
	var reach := maxf(off, gw) + 2.0
	field_main.build_lattice(FIELD_CELL, reach)
	# 全量场复用主路场的点阵,只重扫分支段 band(全量点阵是构建大头)
	field_all.adopt_lattice(field_main, field_main.seg_count(), FIELD_CELL, reach)

	# --- 草地(先铺底) ---
	add_child(_build_grass())

	# --- 主路表面(等值线区域网格) ---
	add_child(_build_road_field())

	# --- 分支条带(岔口融合路由,表面在主路上方 +SEAM_KERF) ---
	for b in blended:
		add_child(_build_strip(b, "Dirt", _dirt_mat))
		dirt_corridors.append(_make_corridor(b))

	# --- 砂石环带 + 外围式低护栏 ---
	if walls_on and off > 0.05:
		if gw > 0.05:
			var gravel := _build_gravel_field(gw)
			if gravel != null:
				add_child(gravel)
		var walls := _build_walls_field(h, off)
		if walls != null:
			add_child(walls)

	# --- 高度路基边坡(整体平的图不生成,零回归) ---
	var apron := _build_aprons()
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

## ---------------- 距离场等值线生成(路面/砂石/护栏) ----------------

## 主路表面:F ≤ 0 实心带的等值线区域网格。发卡弯两腿贴近处胶囊自然并成一片
## ——弯心全铺装,无翻折、无收拢(旧逐截面侧向偏移表示的根本缺陷随之消失)
func _build_road_field() -> StaticBody3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_road_mat)
	var polys := _region_simple_polys(field_main, 0.0)
	var tris := _emit_region_tris(st, polys, func(p: Vector2) -> float:
		field_main.sample_set(p.x, p.y)
		return field_main._q_y)
	if tris == 0:
		return null
	return _body_with_mesh(st.commit(), "Road")

## 砂石环带:F ∈ (0, gw] 的环形区域(level gw 实心带挖去主路路面)。
## 两腿贴近时环带在腰部连通成整片围场——融并缝天然封死,不露草沟。
## 内缘与主路面平接:共用同一份路缘等值线顶点(零缝零重叠)。高度走
## _gravel_drop 剖面——近路缘陡降成斜面路肩,2m 外放缓到护栏脚下;
## 车轮上路/下路都是一阶连续坡面,无台阶不弹飞。
## 剖面按分带等值线(0→0.5→2→gw)分环带 triangulate:环带网格只在外圈
## 和内圈有顶点,8m 大三角的线性插值会把陡段抹平;分带让 0.5m/2m 等
## 高线携带真实剖面高度,相邻带共享同一份轮廓顶点,零缝零重叠。
## 岔口不做几何裁剪:dirt 覆盖区内的砂石按 f_all 整体下沉 ≥4cm(高度分离,
## 永不共面),被 dirt 表面完全覆盖——缝阶零露草、无 z-fight,也无需布尔
func _build_gravel_field(gw: float) -> StaticBody3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_gravel_mat)
	var bands: Array = [0.0, 0.5, 2.0, maxf(2.5, gw)]
	if gw <= 2.0:
		bands = [0.0, gw * 0.3, gw]
	var y_fn := func(p: Vector2) -> float:
		field_main.sample_set(p.x, p.y)
		var rm_y := field_main._q_y
		var rm_f := field_main._q_f
		var fa: float = field_all.f_only(p.x, p.y)
		var sink := 0.0
		if fa < 0.0:
			# 岔口下沉:贴走廊边就沉足 4cm(高度分离余量),深处沉 6cm
			sink = maxf(0.04, 0.06 * clampf(-fa / 0.4, 0.0, 1.0))
		return rm_y - _gravel_drop(rm_f) - sink
	var tris := 0
	for k in bands.size() - 1:
		if bands[k + 1] <= bands[k] + 0.05:
			continue
		var outer_polys: Array = _region_simple_polys(field_main, bands[k + 1])
		var inner_polys: Array = _region_simple_polys(field_main, bands[k], false)
		var final: Array = []
		for poly0 in outer_polys:
			var poly: PackedVector2Array = poly0
			var holes: Array = []
			for cutter0 in inner_polys:
				var cutter: PackedVector2Array = cutter0
				# 内层等值线顶点按构造全在外层盘内,任一采样顶点命中即归属;
				# 弦中点在蜿蜒大环上可能落进港湾草地岛,不可用作探针
				var mine := false
				for c in range(0, cutter.size(), 8):
					if TrackField.point_in_polygon(cutter[c], poly):
						mine = true
						break
				if mine:
					holes.append(cutter)
			final.append(_bridge_holes(poly, holes))
		tris += _emit_region_tris(st, final, y_fn)
	if tris == 0:
		return null
	var body := _body_with_mesh(st.commit(), "Gravel")
	body.name = "Gravel"
	return body

## 砂石路肩高度剖面:路缘平接(0)→ 近缘陡降(斜面路肩,贴缘 ~14%)→
## 指数放缓到护栏脚下(总落差 GRAVEL_DROP)。一阶连续无折点,护栏基座同用
func _gravel_drop(f: float) -> float:
	return GRAVEL_DROP * (1.0 - exp(-maxf(0.0, f) / GRAVEL_BEVEL))

## 外围式低护栏:field_all 的 F = off 等值线环(外环 + 内场孔洞环都立墙)。
## 两腿贴近处环在腰部合拢——腿间天然无墙(融并围场);岔口被分支胶囊撑开,
## 等值线绕行即天然开缺。视觉矮墙高 h,碰撞面从视觉顶延伸到 BARRIER_COLLISION_H,
## 遇上方路面(立体交叉/高架分支)压顶留 CORRIDOR_CLEARANCE 净空
func _build_walls_field(h: float, off: float) -> StaticBody3D:
	var vis := SurfaceTool.new()
	vis.begin(Mesh.PRIMITIVE_TRIANGLES)
	vis.set_material(_mat(WALL_COLOR, 0.95))
	var col := SurfaceTool.new()
	col.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for L in field_all.surface_loops(off):
		var loop: PackedVector2Array = _simplify_loop(L["pts"], SIMP_WALL)
		if loop.size() < 3 or _perimeter(loop) < WALL_MIN_PERIM:
			continue
		# 环法线统一朝场值低侧(路面侧):车从路面侧撞墙是正面。
		# 等值线环旋向全局一致,取 loop[0] 处定向,整环按同侧手性推法线
		var d0 := (loop[1] - loop[0]).normalized()
		var left := Vector2(-d0.y, d0.x)
		var pm := (loop[0] + loop[1]) * 0.5
		var left_inside := field_all.f_only(pm.x + left.x * 0.5, pm.y + left.y * 0.5) \
				< field_all.f_only(pm.x - left.x * 0.5, pm.y - left.y * 0.5)
		for k in loop.size():
			var a2: Vector2 = loop[k]
			var b2: Vector2 = loop[(k + 1) % loop.size()]
			field_all.sample_set(a2.x, a2.y)
			var base_a := Vector3(a2.x, field_all._q_y - _gravel_drop(off), a2.y)
			field_all.sample_set(b2.x, b2.y)
			var base_b := Vector3(b2.x, field_all._q_y - _gravel_drop(off), b2.y)
			var dir := (b2 - a2).normalized()
			var n2 := Vector2(-dir.y, dir.x)
			if not left_inside:
				n2 = -n2
			var nrm := Vector3(n2.x, 0.0, n2.y)
			var mid := (base_a + base_b) * 0.5
			var cap: float = minf(
				float(_corridor_at(mid, CORRIDOR_MARGIN)["cap"]),
				field_all.overhead_cap(mid.x, mid.z, mid.y, FAR_Y_SEP, off + 1.0) - CORRIDOR_CLEARANCE)
			var col_h: float = minf(BARRIER_COLLISION_H, cap - mid.y)
			if col_h < h + 0.2:
				continue  # 高架太低贴住护栏,视同开缺
			_strip_quad(vis, base_a, base_a + Vector3(0, h, 0),
					base_b + Vector3(0, h, 0), base_b, nrm)
			_strip_quad(col, base_a - Vector3(0, BARRIER_COLLISION_SINK, 0),
					Vector3(base_a.x, base_a.y + col_h, base_a.z),
					Vector3(base_b.x, base_b.y + col_h, base_b.z),
					base_b - Vector3(0, BARRIER_COLLISION_SINK, 0), nrm)
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
	mi.material_override = null
	body.add_child(mi)
	return body

## 简单多边形 + 内部孔洞环 → 单一简单多边形(零宽桥缝):每个孔洞与当前
## 边界取最近顶点对,孔洞沿该缝逆序缝入。引擎 exclude_polygons 的输出是
## 对称差偶奇环组,不带孔洞语义,逐片耳切会把孔洞填实(砂石环带挖路面
## 曾因此整片塌成路面下的平板);桥缝是带孔多边形三角化的标准做法,
## 退化缝三角由 _emit_region_tris 的零面积过滤跳过。
## 外环统一逆时针,孔洞统一顺时针(缝入方向即正确)
func _bridge_holes(outer: PackedVector2Array, holes: Array) -> PackedVector2Array:
	if holes.is_empty():
		return outer
	var poly := outer.duplicate()
	for hole0 in holes:
		var hole: PackedVector2Array = hole0
		if _signed_area(hole) > 0.0:
			hole = hole.duplicate()
			hole.reverse()
		var bi := -1
		var bj := -1
		var best := 1e18
		for i in poly.size():
			for j in hole.size():
				var d: float = poly[i].distance_squared_to(hole[j])
				if d < best:
					best = d
					bi = i
					bj = j
		var merged := PackedVector2Array()
		for k in bi + 1:
			merged.append(poly[k])
		var hn := hole.size()
		for k in hn:
			merged.append(hole[wrapi(bj + k, 0, hn)])
		merged.append(hole[bj])
		for k in range(bi, poly.size()):
			merged.append(poly[k])
		poly = merged
	return poly

## level 层实心带 → 简单多边形集合(外环挖去内部草地岛,孔洞桥缝后逐片耳切)。
## cut_islands=false 时只返回外环(草地岛不挖):作带间切割体用时,内层实心带
## 的草地岛本就属于环带区域(f > 内层 level),挖了反而错。
## 外环/内环统一逆时针定向;同层等值线在路面/砂石两处使用完全一致
## (同点阵同抽稀),边界顶点逐点重合,层间零缝。结果按 (field, level) 缓存
func _region_simple_polys(field: TrackField, level: float, cut_islands := true) -> Array:
	var key := "%d@%.2f@%d" % [field.get_instance_id(), level, 1 if cut_islands else 0]
	if _region_cache.has(key):
		return _region_cache[key]
	var loops: Array = field.surface_loops(level)
	var polys: Array = []
	for L in loops:
		if L["hole"]:
			continue
		var outer: PackedVector2Array = _simplify_loop(L["pts"], SIMP_SURFACE)
		if outer.size() < 3:
			continue
		if _signed_area(outer) < 0.0:
			outer.reverse()
		if not cut_islands:
			polys.append(outer)
			continue
		var holes: Array = []
		for L2 in loops:
			if not L2["hole"]:
				continue
			var hole: PackedVector2Array = _simplify_loop(L2["pts"], SIMP_SURFACE)
			if hole.size() < 3:
				continue
			var probe: Vector2 = (hole[0] + hole[hole.size() / 2]) * 0.5
			if not TrackField.point_in_polygon(probe, outer):
				continue  # 属于别的块的内环
			holes.append(hole)
		polys.append(_bridge_holes(outer, holes))
	_region_cache[key] = polys
	return polys

## 简单多边形集合 → 三角形(引擎耳切)。y_fn 逐顶点取高度;
## 绕序逐三角校正为 Godot 正面朝上,退化三角跳过
func _emit_region_tris(st: SurfaceTool, polys: Array, y_fn: Callable) -> int:
	var tris := 0
	for poly in polys:
		var idx: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
		if idx.is_empty():
			continue  # 数值退化环,区域由相邻环覆盖
		for t in range(0, idx.size(), 3):
			var pa: Vector2 = poly[idx[t]]
			var pb: Vector2 = poly[idx[t + 1]]
			var pc: Vector2 = poly[idx[t + 2]]
			var cross := (pb - pa).cross(pc - pa)
			if absf(cross) < 1e-7:
				continue
			if cross < 0.0:
				var tmp := pb
				pb = pc
				pc = tmp
			var va := Vector3(pa.x, y_fn.call(pa), pa.y)
			var vb := Vector3(pb.x, y_fn.call(pb), pb.y)
			var vc := Vector3(pc.x, y_fn.call(pc), pc.y)
			for v in [va, vb, vc]:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(0.5, 0.0))
				st.add_vertex(v)
			tris += 1
	return tris

## 闭合环 Douglas-Peucker 抽稀:取 x 两极点为锚把环拆成两段链分别化简再拼回
func _simplify_loop(pts: PackedVector2Array, eps: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 8:
		return pts
	var i_min := 0
	var i_max := 0
	for i in n:
		if pts[i].x < pts[i_min].x:
			i_min = i
		if pts[i].x > pts[i_max].x:
			i_max = i
	var chain := func(a0: int, a1: int) -> PackedVector2Array:
		var arr := PackedVector2Array()
		var i := a0
		while true:
			arr.append(pts[i])
			if i == a1:
				break
			i = (i + 1) % n
		return arr
	var first := _dp_simplify(chain.call(i_min, i_max), eps)
	var second := _dp_simplify(chain.call(i_max, i_min), eps)
	var out := PackedVector2Array()
	out.append_array(first)
	out.append_array(second.slice(1, second.size() - 1))  # 去掉与前段重复的两端锚
	return out if out.size() >= 3 else pts

func _dp_simplify(pts: PackedVector2Array, eps: float) -> PackedVector2Array:
	var n := pts.size()
	if n <= 2:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var lo: int = seg[0]
		var hi: int = seg[1]
		var a := pts[lo]
		var ab := pts[hi] - a
		var L2 := ab.length_squared()
		var dmax := -1.0
		var imax := -1
		for i in range(lo + 1, hi):
			var d := 0.0
			if L2 < 1e-9:
				d = pts[i].distance_to(a)
			else:
				var t := clampf((pts[i] - a).dot(ab) / L2, 0.0, 1.0)
				d = (a + ab * t).distance_to(pts[i])
			if d > dmax:
				dmax = d
				imax = i
		if dmax > eps:
			keep[imax] = 1
			stack.append([lo, imax])
			stack.append([imax, hi])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out

func _signed_area(poly: PackedVector2Array) -> float:
	var s := 0.0
	var n := poly.size()
	for i in n:
		var j := (i + 1) % n
		s += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return s * 0.5

func _perimeter(poly: PackedVector2Array) -> float:
	var s := 0.0
	var n := poly.size()
	for i in n:
		s += poly[i].distance_to(poly[(i + 1) % n])
	return s

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
## 内缘贴砂石外缘等值线(主路,场解 F=min(gw,off);两腿贴近处随并集外推)或路缘外
## 0.5m(辅路);坡脚遇垂向贴近的远端路面自动收短(桥侧坡不吞并桥下车道);
## 整体平的图完全不生成(零回归)。坡脚截断/岔口走廊开缺留下的敞口由下方草地
## 平板兜底,不露空腔。
func _build_aprons() -> StaticBody3D:
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
			var eff: PackedFloat32Array = _edge_offsets(route, sgn)
			var kept: Array = []   # [截面索引, 内缘顶点, 坡脚顶点]
			for i in n:
				var drop: float = pts[i].y - slab_top
				if drop <= APRON_MIN_DROP:
					continue
				var side := TrackData._flat_normal(tans[i])
				var inner_off := float(eff[i]) + 0.5
				if is_main and walls_on and off > 0.05:
					inner_off = _solve_iso_t(pts[i], side, sgn, minf(gw, off),
							float(eff[i]) + minf(gw, off) + 12.0)
					if inner_off < 0.0:
						continue  # 融并腰部整片是砂石围场(F 峰值 < target),无边坡可放
				var inner := pts[i] + side * inner_off * sgn
				inner.y = pts[i].y - 0.14
				var want: float = minf((inner.y - slab_top) / APRON_SLOPE, APRON_MAX_RUN)
				var run := _apron_run_limit(want, inner, side, sgn)
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

## 沿截面法线解 F = target 的距离(主路内缘锚定砂石外缘等值线)。
## 先向外扫描定界再二分;融并腰部 F 峰值低于 target 时无解,返回 -1
func _solve_iso_t(p: Vector3, side: Vector3, sgn: float, target: float, t_hi: float) -> float:
	var lo := 0.0
	var hi := -1.0
	var t := 1.0
	while t <= t_hi:
		var q := p + side * t * sgn
		if field_main.f_only(q.x, q.z) >= target:
			hi = t
			break
		lo = t
		t += 1.0
	if hi < 0.0:
		return -1.0
	for k in 4:
		var mid := (lo + hi) * 0.5
		var q := p + side * mid * sgn
		if field_main.f_only(q.x, q.z) < target:
			lo = mid
		else:
			hi = mid
	return hi

## 坡长收短:坡脚(沿坡线下滑到 inner.y - run×APRON_SLOPE)不得落入任何垂向贴近的
## 路面并集(场探测,梯子试探 + 二分,同旧 _far_road_limit 思路)
func _apron_run_limit(want: float, inner: Vector3, side: Vector3, sgn: float) -> float:
	if want <= 1.0:
		return want
	var probe := func(run: float) -> bool:
		var p := inner + side * run * sgn
		p.y = inner.y - run * APRON_SLOPE
		return field_all.f_only(p.x, p.z) < 0.3
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

## 竖直/放坡条带 quad:绕序按期望法线自修正(左右两侧镜像点序会导致左墙从路面侧
## 撞是背面——凹多边形碰撞默认不碰背面,左墙左坡将无碰撞)。
## Godot 正面 = 顺时针:三角形叉积与期望法线反向(dot < 0)
func _strip_quad(st: SurfaceTool, bl: Vector3, tl: Vector3, tr: Vector3, br: Vector3, nrm: Vector3) -> void:
	if (tl - bl).cross(tr - bl).dot(nrm) > 0.0:
		var tmp := bl
		bl = br
		br = tmp
		var tmp2 := tl
		tl = tr
		tr = tmp2
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
