extends Node3D
## headless 验证:TrackData 解析 + TrackBuilder 构建(编辑器 JSON 管线)。
## 运行:godot --headless --path . res://game/testing/track_build_test.tscn

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[TB] OK   | %s" % label)
	else:
		failures += 1
		print("[TB] FAIL | %s" % label)

func _ready() -> void:
	print("========== TRACK BUILD TEST ==========")
	var data := TrackData.load_json("res://game/race/tracks/data/map_1.json")
	ok(data != null, "JSON 加载")
	if data == null:
		_finish()
		return
	ok(absf(data.length - 4146.4) < 2.0, "主路长度 %.1fm(含 36m 发车引道/8 格)" % data.length)
	ok(data.routes.size() == 3, "路由数 %d(主路+分支)" % data.routes.size())

	var anchor: float = float(data.grid_cfg.get("anchor_s", 0.0))
	ok(absf(anchor - 36.0) < 0.01, "发车引道 anchor_s=%.1f" % anchor)
	var p_leadin := data.point_at(0.0)
	ok(p_leadin.distance_to(Vector3(0, 0, 36)) < 1.5, "point_at(0) 在引道尾端 %s" % [p_leadin])
	var p0 := data.start_point()
	ok(p0.distance_to(Vector3(0, 0, 0)) < 1.0, "起点线在 (0,0,0) %s" % [p0])
	var pe := data.point_at(data.length)
	ok(absf(pe.x - 901.207) < 2.0 and absf(pe.z + 267.257) < 2.0, "point_at(L) 在终点 %s" % [pe])

	var pr: Array = data.progress_at(p_leadin, -1)
	ok(float(pr[0]) < 1.0, "引道尾端进度 ≈ 0(%.2f)" % float(pr[0]))
	var mid := data.point_at(data.length * 0.5)
	var pm: Array = data.progress_at(mid, -1)
	ok(absf(float(pm[0]) - data.length * 0.5) < 3.0, "中点进度 ≈ L/2(%.1f)" % float(pm[0]))

	var fwd := data.tangent_at(anchor)
	var g1 := data.grid_position(1)
	var d1 := g1.distance_to(p0)
	ok(d1 > 2.0 and d1 < 15.0, "1 号发车位在起点线附近 %s" % [g1])
	var g8 := data.grid_position(8)
	var back1: float = (g1 - p0).dot(fwd)
	var back8: float = (g8 - p0).dot(fwd)
	ok(back8 < back1 - 6.0, "8 号发车位在 1 号后方(%.1f < %.1f)" % [back8, back1])
	for g_no in [1, 8]:
		var lat: Dictionary = data.main_lateral(data.grid_position(g_no))
		ok(float(lat["dist"]) < float(lat["half"]),
				"发车位 %d 在路面内(%.1f < %.1f)" % [g_no, float(lat["dist"]), float(lat["half"])])

	var cs := data.corner_speed(0.0, 50.0)
	ok(cs > 10.0 and cs <= 55.0, "corner_speed 合理 %.1f" % cs)

	var mpts := data.main_route_points(6)
	ok(mpts.size() == 6, "主路掉落点 6 个")
	var hpts := data.hazard_route_points()
	ok(hpts.size() >= 3, "高危掉落点 %d 个" % hpts.size())

	var fwd_check := data.tangent_at(0.0)
	ok(fwd_check.z < -0.5, "起点切线朝 -z(%.2f)" % fwd_check.z)

	# --- 构建节点树 ---
	var builder := TrackBuilder.new()
	add_child(builder)
	builder.build(data)
	builder.setup(WeatherEnv.cfg(WeatherEnv.Type.SUNNY))

	# 三点半径公式与急弯条带安全约束。
	var radius_route := {"pts": PackedVector3Array([
		Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0)])}
	data._compute_radii(radius_route)
	var unit_radii: PackedFloat32Array = radius_route["radii"]
	ok(absf(unit_radii[1] - 1.0) < 0.001, "三点曲率半径公式 R=1 (%.3f)" % unit_radii[1])

	var road_edge_bad := 0
	var barrier_curve_bad := 0
	var barrier_curve_skips := 0
	var main_pts: PackedVector3Array = data.main["pts"]
	var main_widths: PackedFloat32Array = data.main["widths"]
	var main_radii: PackedFloat32Array = data.main["radii"]
	for sgn: float in [1.0, -1.0]:
		var edges: PackedFloat32Array = builder._edge_offsets(data.main, sgn)
		var offsets: PackedFloat32Array = builder._offsets(sgn, 8.0)
		for i in range(1, main_pts.size() - 1):
			var cross: float = builder._turn_cross(main_pts[i - 1], main_pts[i], main_pts[i + 1])
			var inner := -1.0 if cross > 0.0 else 1.0
			if absf(cross) < 1e-6 or sgn != inner:
				continue
			var edge_limit := maxf(0.0, float(main_radii[i]) - TrackBuilder.ROAD_INNER_RADIUS)
			var barrier_limit := maxf(0.0, float(main_radii[i]) \
					- float(main_widths[i]) * 0.5 - TrackBuilder.BARRIER_INNER_RADIUS)
			if edges[i] > edge_limit + 0.001:
				road_edge_bad += 1
			if offsets[i] > barrier_limit + 0.001:
				barrier_curve_bad += 1
			if barrier_limit < TrackBuilder.OFFSET_SKIP and offsets[i] < TrackBuilder.OFFSET_SKIP:
				barrier_curve_skips += 1
	ok(road_edge_bad == 0, "急弯路面内缘不越过弯心(越界 %d)" % road_edge_bad)
	ok(barrier_curve_bad == 0 and barrier_curve_skips > 0,
			"急弯护栏不越过弯心且极小弯心断开(越界 %d,断开采样 %d)" \
			% [barrier_curve_bad, barrier_curve_skips])

	var road_winding_bad := 0
	var road_triangles := 0
	for road_node in get_tree().get_nodes_in_group("Road"):
		if road_node.name == "Walls" or road_node.get_child_count() < 2:
			continue
		var road_mi := road_node.get_child(1) as MeshInstance3D
		if road_mi == null:
			continue
		var arrays := road_mi.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var winding_sign := 0.0
		for i in range(0, vertices.size(), 3):
			var signed_area := (vertices[i + 1] - vertices[i]).cross(vertices[i + 2] - vertices[i]).dot(normals[i])
			if absf(signed_area) < 0.0001:
				road_winding_bad += 1
			elif winding_sign == 0.0:
				winding_sign = signf(signed_area)
			elif signf(signed_area) != winding_sign:
				road_winding_bad += 1
			road_triangles += 1
		break
	ok(road_triangles > 0 and road_winding_bad == 0,
			"主路条带无退化/翻面三角形(%d 面,异常 %d)" % [road_triangles, road_winding_bad])

	# map_2/map_4 contain the sampled tight turns that previously emitted a
	# bow-tie triangle. Keep them in the regression suite as well as map_1.
	for map_id in [2, 3, 4]:
		var extra_data := TrackData.load_json("res://game/race/tracks/data/map_%d.json" % map_id)
		var extra_builder := TrackBuilder.new()
		add_child(extra_builder)
		extra_builder.build(extra_data)
		var extra_road := extra_builder.get_child(1) as StaticBody3D
		var extra_mesh := (extra_road.get_child(1) as MeshInstance3D).mesh
		var extra_arrays := extra_mesh.surface_get_arrays(0)
		var extra_vertices: PackedVector3Array = extra_arrays[Mesh.ARRAY_VERTEX]
		var extra_normals: PackedVector3Array = extra_arrays[Mesh.ARRAY_NORMAL]
		var extra_bad := 0
		var extra_sign := 0.0
		for i in range(0, extra_vertices.size(), 3):
			var extra_area := (extra_vertices[i + 1] - extra_vertices[i]).cross(\
					extra_vertices[i + 2] - extra_vertices[i]).dot(extra_normals[i])
			if absf(extra_area) < 0.0001:
				extra_bad += 1
			elif extra_sign == 0.0:
				extra_sign = signf(extra_area)
			elif signf(extra_area) != extra_sign:
				extra_bad += 1
		ok(extra_bad == 0, "map_%d 主路急弯无翻面三角形(%d 面,异常 %d)" % \
				[map_id, extra_vertices.size() / 3, extra_bad])
		extra_builder.queue_free()
	ok(builder.get_node_or_null("FinishGate") != null, "FinishGate 生成")
	ok(get_tree().get_nodes_in_group("Road").size() >= 2, "Road 组 %d 个(路面+护栏)" % get_tree().get_nodes_in_group("Road").size())
	ok(get_tree().get_nodes_in_group("Dirt").size() >= 1, "Dirt 组 %d 个" % get_tree().get_nodes_in_group("Dirt").size())
	ok(get_tree().get_nodes_in_group("Grass").size() >= 1, "Grass 组 %d 个" % get_tree().get_nodes_in_group("Grass").size())
	ok(get_tree().get_nodes_in_group("Gravel").size() >= 1, "Gravel 组 %d 个(砂石路肩)" % get_tree().get_nodes_in_group("Gravel").size())
	ok(builder.junctions.size() == 4, "岔口融合 %d 处(4 个 dirt 端头均衔主路)" % builder.junctions.size())

	# --- 外退式护栏:退离路缘 + 视觉低矮 + 碰撞面远高于视觉 ---
	# 急弯内侧按曲率收紧到 BARRIER_INNER_RADIUS,发卡弯 R<half 时必须收紧
	# 防偏移线自交);发卡弯附近最近投影会串到另一条腿,故另加主体占比断言
	var walls: StaticBody3D = builder.get_node_or_null("Walls") as StaticBody3D
	ok(walls != null, "护栏生成")
	if walls != null:
		var wmi: MeshInstance3D = walls.get_child(1)
		var wverts: PackedVector3Array = wmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		# 退距下限 0.3:急弯/邻腿贴近处按远端路面走廊收紧(可低至 OFFSET_SKIP=0.4),
		# 发卡弯汇合弯心整段不放;护栏与路面走廊的硬约束在"任何顶点不得在路面内"断言
		var setback_bad := 0
		var vis_bad := 0
		var near_off := 0
		for v in wverts:
			var lat: Dictionary = data.main_lateral(v)
			var sb: float = float(lat["dist"]) - float(lat["half"])
			var vh: float = v.y - float(lat["road_y"])
			if sb < 0.3 or sb > 11.0:
				setback_bad += 1
			if sb >= 6.5 and sb <= 9.5:
				near_off += 1
			if vh < -0.3 or vh > 0.95:
				vis_bad += 1
		ok(wverts.size() > 0 and setback_bad == 0, "护栏退距带 0.3~11m(越界 %d/%d)" % [setback_bad, wverts.size()])
		ok(near_off > wverts.size() * 0.85, "护栏主体退距 ≈8m(%.0f%% 在 6.5~9.5m)" % (100.0 * near_off / wverts.size()))
		ok(vis_bad == 0, "视觉护栏低矮(≤0.95m,越界 %d)" % vis_bad)
		var wshape: ConcavePolygonShape3D = (walls.get_child(0) as CollisionShape3D).shape
		var col_top := -1e9
		for v in wshape.get_faces():
			var lat: Dictionary = data.main_lateral(v)
			col_top = maxf(col_top, v.y - float(lat["road_y"]))
		ok(col_top > 3.5, "护栏碰撞墙远高于视觉(碰撞顶高 %.1fm vs 视觉 0.8m)" % col_top)

	var has_trimesh := false
	for group in ["Road", "Dirt"]:
		for n in get_tree().get_nodes_in_group(group):
			for c in n.get_children():
				if c is CollisionShape3D and c.shape is ConcavePolygonShape3D:
					has_trimesh = true
	ok(has_trimesh, "Trimesh 碰撞生成")
	_finish()

func _finish() -> void:
	print("========== %d checks, %d failures ==========" % [checks, failures])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if failures == 0 else 1)
