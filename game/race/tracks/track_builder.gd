class_name TrackBuilder
extends Node3D
## 编辑器 JSON(TrackData)→ 运行时赛道节点树(SurfaceTool 条带网格 + Trimesh 碰撞)。
## 产出与 track_test 同契约:setup(env) / FinishGate(Area3D) /
## main_route_points(n) / hazard_route_points(),可被 RaceManager 无缝使用。
## 碰撞体分组 = GEVP 表面键(wheel.gd 取第一个分组名):主路 Road、分支 Dirt、草地 Grass。

const WALL_COLOR := Color(0.16, 0.17, 0.19)
const LINE_COLOR := Color(0.88, 0.88, 0.88)

# 垂直分离,避免与路面共面 z-fighting:草地顶面低于路面最低点,
# dirt 分支从主路下方穿过(衔接处主路盖在上面),标线浮在路面之上
const GRASS_DROP := 0.2
const DIRT_DROP := 0.08
const MARKING_LIFT := 0.04

var data: TrackData = null

var _road_mat: StandardMaterial3D
var _dirt_mat: StandardMaterial3D
var _grass_mat: StandardMaterial3D

func build(d: TrackData) -> void:
	data = d
	name = "TrackBuilt"
	_road_mat = _mat(Color(0.22, 0.23, 0.26))
	_dirt_mat = _mat(Color(0.52, 0.40, 0.26), 1.0)
	_grass_mat = _mat(Color(0.30, 0.55, 0.28))

	# --- 草地(先铺底) ---
	add_child(_build_grass())

	# --- 主路 + 分支 ---
	var road := _build_strip(data.main, "Road", _road_mat)
	add_child(road)
	for route in data.routes:
		if String(route["surface"]) == "dirt":
			add_child(_build_strip(route, "Dirt", _dirt_mat, DIRT_DROP))

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

func _build_strip(route: Dictionary, group: String, mat: StandardMaterial3D, drop := 0.0) -> Node3D:
	var pts: PackedVector3Array = route["pts"]
	var tans: PackedVector3Array = route["tans"]
	var widths: PackedFloat32Array = route["widths"]
	var s_arr: PackedFloat32Array = route["s_arr"]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var n := pts.size()
	for i in n:
		var side := TrackData._flat_normal(tans[i])
		var up := tans[i].cross(side).normalized()
		var w := widths[i] * 0.5
		var v := s_arr[i] / 4.0  # UV 纵向:4m 一个周期
		st.set_normal(up)
		st.set_uv(Vector2(0.0, v))
		st.add_vertex(pts[i] + side * w)
		st.set_normal(up)
		st.set_uv(Vector2(1.0, v))
		st.add_vertex(pts[i] - side * w)
	for i in n - 1:
		var a := i * 2
		st.add_index(a)
		st.add_index(a + 2)
		st.add_index(a + 1)
		st.add_index(a + 1)
		st.add_index(a + 2)
		st.add_index(a + 3)
	return _body_with_mesh(st.commit(), group, drop)

func _body_with_mesh(mesh: ArrayMesh, group: String, drop := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.add_to_group(group)
	body.position.y = -drop
	var col := CollisionShape3D.new()
	col.shape = mesh.create_trimesh_shape()
	body.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	return body

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
	var n := pts.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mat(WALL_COLOR, 0.95))
	var vcount := 0
	for sgn: float in [1.0, -1.0]:
		var start := vcount
		for i in n:
			var side := TrackData._flat_normal(tans[i])
			var edge := pts[i] + side * (widths[i] * 0.5 + 0.3) * sgn
			st.set_normal(side * sgn)
			st.add_vertex(edge)
			st.set_normal(side * sgn)
			st.add_vertex(edge + Vector3(0, h, 0))
			vcount += 2
		for i in n - 1:
			var a := start + i * 2
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
	# 边线:连续,宽 0.25,距路缘 0.4
	s = 0.0
	while s < data.length - 6.0:
		var w := data.width_at(s + 3.0) * 0.5 - 0.4
		_mark_quad(st, s, s + 6.0, 0.125, w, lift)
		_mark_quad(st, s, s + 6.0, 0.125, -w, lift)
		s += 6.0

	var mi := MeshInstance3D.new()
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
	var t := TrackData._flat_tangent(data.main["tans"][0])
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
