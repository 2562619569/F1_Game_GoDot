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
	ok(absf(data.length - 4533.6) < 2.0, "主路长度 %.1fm(含 36m 发车引道/8 格)" % data.length)
	ok(data.routes.size() == 3, "路由数 %d(主路+分支)" % data.routes.size())

	var anchor: float = float(data.grid_cfg.get("anchor_s", 0.0))
	ok(absf(anchor - 36.0) < 0.01, "发车引道 anchor_s=%.1f" % anchor)
	var p_leadin := data.point_at(0.0)
	ok(p_leadin.distance_to(Vector3(-9.214, 0, 34.801)) < 1.5, "point_at(0) 在引道尾端 %s" % [p_leadin])
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
			# 护栏锚有效路缘:总退距(有效路缘+退距)≤ R-1.5(收拢区护栏贴实际路面边,
			# 弯心不再强制断开;开缺由远端走廊判定,zfight 检查覆盖)
			var barrier_total := float(offsets[i]) + float(edges[i])
			var barrier_limit := float(main_radii[i]) - TrackBuilder.BARRIER_INNER_RADIUS
			if edges[i] > edge_limit + 0.001:
				road_edge_bad += 1
			if barrier_total > barrier_limit + 0.001:
				barrier_curve_bad += 1
	ok(road_edge_bad == 0, "急弯路面内缘不越过弯心(越界 %d)" % road_edge_bad)
	ok(barrier_curve_bad == 0, "急弯护栏总退距不越过弯心(越界 %d)" % barrier_curve_bad)

	# --- 退距场核心性质(Lipschitz 斜率 ≤1:弯内缘平滑收拢,领结在构造上不可能) ---
	var saw := PackedFloat32Array([8.0, 8.0, 0.0, 8.0, 8.0])
	var saw_s := PackedFloat32Array([0.0, 2.0, 4.0, 6.0, 8.0])
	var cone := TrackData.cone_smooth(saw, saw_s, 4.0)
	var cone_bad := 0
	for i in cone.size() - 1:
		if absf(float(cone[i + 1]) - float(cone[i])) \
				> float(saw_s[i + 1]) - float(saw_s[i]) + 0.001:
			cone_bad += 1
	ok(cone_bad == 0 and float(cone[2]) == 0.0,
			"锥形腐蚀斜率≤1 且坑底保留(肩部 %.2f,坑底 %.2f)" \
			% [float(cone[0]), float(cone[2])])
	var main_s_arr: PackedFloat32Array = data.main["s_arr"]
	var edge_lip_bad := 0
	for sgn: float in [1.0, -1.0]:
		var edges: PackedFloat32Array = builder._edge_offsets(data.main, sgn)
		for i in range(1, edges.size() - 1):
			if absf(float(edges[i + 1]) - float(edges[i])) \
					> float(main_s_arr[i + 1]) - float(main_s_arr[i]) + 0.001:
				edge_lip_bad += 1
	ok(edge_lip_bad == 0, "路缘有效半宽斜率≤1(弯内平滑收拢,越界 %d)" % edge_lip_bad)

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
	ok(builder.junctions.size() == 2, "岔口融合 %d 处(2 个 dirt 端头均衔主路)" % builder.junctions.size())

	# --- 外退式护栏:退离路缘 + 视觉低矮 + 碰撞面远高于视觉 ---
	# 急弯内侧按曲率收紧到 BARRIER_INNER_RADIUS,发卡弯 R<half 时必须收紧
	# 防偏移线自交);发卡弯附近最近投影会串到另一条腿,故另加主体占比断言
	var walls: StaticBody3D = builder.get_node_or_null("Walls") as StaticBody3D
	ok(walls != null, "护栏生成")
	if walls != null:
		var wmi: MeshInstance3D = walls.get_child(1)
		var wverts: PackedVector3Array = wmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		# 退距下限 0.3:急弯/邻腿贴近处按远端路面走廊收紧(可低至 OFFSET_SKIP=0.4),
		# 发卡弯汇合弯心整段不放;护栏与路面走廊的硬约束在"任何顶点不得在路面内"断言。
		# 退距按有效路缘分(急弯收拢区路面边 < 全宽半路面,护栏贴实际路面边)
		var wall_eff_l: PackedFloat32Array = builder._edge_offsets(data.main, 1.0)
		var wall_eff_r: PackedFloat32Array = builder._edge_offsets(data.main, -1.0)
		var setback_bad := 0
		var vis_bad := 0
		var near_off := 0
		for v in wverts:
			var lat: Dictionary = data.main_lateral(v)
			var ws := float(lat["s"])
			var wn := data.normal_at(ws)
			var wrel: Vector3 = v - (lat["foot"] as Vector3)
			var eff_arr := wall_eff_l if wrel.x * wn.x + wrel.z * wn.z >= 0.0 else wall_eff_r
			var sb: float = float(lat["dist"]) - data.field_at(eff_arr, ws)
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

	# --- 条带面绕序:Godot 正面=顺时针,几何叉积须与顶点法线反向 ---
	# 凹多边形碰撞默认不碰背面:左右镜像点序的条带在一侧法线朝下,
	# 渲染因 CULL_DISABLED 看得见、碰撞整体失效(车陷到草地板)——此处永久设防
	var wind_bad := 0
	var wind_total := 0
	for surf_group in ["Road", "Dirt", "Gravel"]:
		for n in get_tree().get_nodes_in_group(surf_group):
			for ch in n.get_children():
				if not (ch is MeshInstance3D):
					continue
				var w_arrays: Array = ch.mesh.surface_get_arrays(0)
				var w_v: PackedVector3Array = w_arrays[Mesh.ARRAY_VERTEX]
				var w_n: PackedVector3Array = w_arrays[Mesh.ARRAY_NORMAL]
				for t3 in range(0, w_v.size(), 3):
					wind_total += 1
					if (w_v[t3 + 1] - w_v[t3]).cross(w_v[t3 + 2] - w_v[t3]).dot(w_n[t3]) > 0.0001:
						wind_bad += 1
	ok(wind_total > 0 and wind_bad == 0,
			"全部条带面正面朝上(%d 面,背面 %d)" % [wind_total, wind_bad])

	# --- 左右路肩物理射线:有效路缘外 2m 从上往下打 ---
	# 命中 Grass(草平板)= 砂石无碰撞(背面 bug);合并区/岔口可为 Road/Dirt
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_world_3d().direct_space_state
	var eff_l_ray := builder._edge_offsets(data.main, 1.0)
	var eff_r_ray := builder._edge_offsets(data.main, -1.0)
	var ray_l_gravel := 0
	var ray_r_gravel := 0
	var ray_grass_pos := ""
	var ray_total := 0
	var s_ray := 60.0
	while s_ray < data.length - 30.0:
		var i_r := data.nearest_index(data.point_at(s_ray), -1)
		var nrm_r := TrackData._flat_normal(data.main["tans"][i_r])
		for side_r: float in [1.0, -1.0]:
			var eff_r2 := eff_l_ray if side_r > 0.0 else eff_r_ray
			var p_r: Vector3 = data.main["pts"][i_r] + nrm_r * (float(eff_r2[i_r]) + 2.0) * side_r
			var q := PhysicsRayQueryParameters3D.create(
					Vector3(p_r.x, p_r.y + 1.0, p_r.z), Vector3(p_r.x, p_r.y - 0.5, p_r.z))
			var hit := space.intersect_ray(q)
			ray_total += 1
			if hit.is_empty():
				continue
			var g0: Array = (hit["collider"] as CollisionObject3D).get_groups()
			var tag0 := str(g0[0]) if g0.size() > 0 else ""
			if tag0 == "Gravel":
				if side_r > 0.0:
					ray_l_gravel += 1
				else:
					ray_r_gravel += 1
			elif tag0 == "Grass":
				ray_grass_pos += "s=%.0f%s " % [s_ray, "L" if side_r > 0.0 else "R"]
		s_ray += 40.0
	ok(ray_grass_pos == "",
			"路肩物理射线无草平板穿透(%s / %d)" % [ray_grass_pos if ray_grass_pos != "" else "无", ray_total])
	ok(ray_l_gravel > ray_total * 0.6 and ray_r_gravel > ray_total * 0.6,
			"左右路肩物理射线均命中 Gravel(左 %d 右 %d / %d)" % [ray_l_gravel, ray_r_gravel, ray_total])

	var has_trimesh := false
	for group in ["Road", "Dirt"]:
		for n in get_tree().get_nodes_in_group(group):
			for c in n.get_children():
				if c is CollisionShape3D and c.shape is ConcavePolygonShape3D:
					has_trimesh = true
	ok(has_trimesh, "Trimesh 碰撞生成")

	# --- 高度支持:自身环线立交 / 坡顶标线 / 砂石路宽(合成数据,不动真实地图) ---
	_test_elevation()
	_finish()

## 合成 TrackData:直接给密集采样点(4 元素 baked),绕开编辑器烘焙
func _synth_track(routes_pts: Array, options: Dictionary, width: float) -> TrackData:
	var baked := {}
	var routes := []
	for r in routes_pts:
		var arr: Array = []
		for p in r["pts"]:
			arr.append([p.x, p.y, p.z, width])
		baked[r["id"]] = arr
		routes.append({"id": r["id"], "surface": r["surface"]})
	var d := {
		"meta": {"id": 99, "name": "synthetic"},
		"grid": {"count": 8, "row_gap": 8.0, "col_gap": 7.0, "first_row_offset": 6.0, "anchor_s": 0.0},
		"options": options,
		"routes": routes,
		"baked": baked,
	}
	var td := TrackData.new()
	td._from_dict(d)
	return td

## 环线:两条 200m 平行直道(z=0 与 z=-20,间距 20m)xz 上互相贴近,
## 右/左端半圆衔接。y2=0 为平图(两腿平面重叠,护栏按远端路面收紧);
## y2=6 为高架(返程腿高出 6m 跨越去程腿 → 立体交叉)
func _ring_pts(y2: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var x0 := -80.0
	var x1 := 120.0
	var zc := -10.0
	var rr := 10.0
	for x in range(int(x0), int(x1) + 1, 4):
		pts.append(Vector3(float(x), 0.0, 0.0))
	for k in range(1, 13):
		var th := PI * 0.5 - PI * float(k) / 12.0
		pts.append(Vector3(x1 + rr * cos(th), y2 * float(k) / 12.0, zc + rr * sin(th)))
	for x in range(int(x1) - 4, int(x0) - 1, -4):
		pts.append(Vector3(float(x), y2, -20.0))
	for k in range(1, 12):
		var th2 := -PI * 0.5 - PI * float(k) / 12.0
		pts.append(Vector3(x0 + rr * cos(th2), y2 * (1.0 - float(k) / 12.0), zc + rr * sin(th2)))
	return pts

## 直道中央抛物线驼峰(±16m 抬 4m):坡顶曲率大,未细分的 6m 标线长弦会切进路面
func _hump_pts() -> PackedVector3Array:
	var pts := PackedVector3Array()
	for x in range(-140, 141, 2):
		var xx := float(x)
		var y := 0.0
		if absf(xx) < 16.0:
			y = 4.0 * (1.0 - (xx / 16.0) * (xx / 16.0))
		pts.append(Vector3(xx, y, 0.0))
	return pts

func _test_elevation() -> void:
	var opts := {"walls": true, "wall_height": 0.8, "barrier_offset": 8.0, "gravel_width": 8.0, "sample_step": 2}
	var flat := _synth_track([{"id": "main", "surface": "road", "pts": _ring_pts(0.0)}], opts, 16.0)
	var elev := _synth_track([{"id": "main", "surface": "road", "pts": _ring_pts(6.0)}], opts, 16.0)
	ok(flat != null and elev != null, "高度合成数据构建(环线平/高架)")
	var ymax := -1e9
	for p in elev.main["pts"]:
		ymax = maxf(ymax, p.y)
	ok(ymax > 5.5 and ymax < 6.5, "高架腿高度 %.1fm" % ymax)

	var fb := TrackBuilder.new()
	add_child(fb)
	fb.build(flat)
	var eb := TrackBuilder.new()
	add_child(eb)
	eb.build(elev)
	ok(eb.get_node_or_null("Walls") != null and eb.get_node_or_null("Gravel") != null,
			"高架环线护栏+砂石生成")
	# 远端路面 y 分离:平图两腿贴近 → 护栏收紧;高架 Δy=6 ≥ 3 → 互不收紧
	var n_straight := 51   # 下直道采样数(x -80..120 步 4)
	var offs_f: PackedFloat32Array = fb._offsets(1.0, 8.0)
	var offs_e: PackedFloat32Array = eb._offsets(1.0, 8.0)
	var sum_flat := 0.0
	var sum_elev := 0.0
	for i in n_straight:
		sum_flat += float(offs_f[i])
		sum_elev += float(offs_e[i])
	ok(sum_elev / n_straight > 7.5, "桥上桥下护栏退距不收紧(均值 %.2fm)" % (sum_elev / n_straight))
	ok(sum_flat / n_straight < 6.0, "平图对照:贴近腿收紧(均值 %.2fm)" % (sum_flat / n_straight))

	# 桥下净空:下直道朝向桥一侧的碰撞墙顶被桥面压低(≤ 桥面6m - 净空1.5)
	var walls_e: StaticBody3D = eb.get_node_or_null("Walls")
	var col_under := 0
	var col_under_max := -1e9
	if walls_e != null:
		var faces: PackedVector3Array = (walls_e.get_child(0) as CollisionShape3D).shape.get_faces()
		for v in faces:
			if v.x > -60.0 and v.x < 110.0 and v.z > -18.0 and v.z < -14.0:
				col_under += 1
				col_under_max = maxf(col_under_max, v.y)
	ok(col_under > 60 and col_under_max < 4.7,
			"桥下护栏碰撞墙留净空(%d 顶点,顶高 %.2fm ≤ 4.5)" % [col_under, col_under_max])

	# 高度路基边坡:高架图生成,平图不生成(零回归);边坡不吞并桥下路面
	var apron_e: StaticBody3D = eb.get_node_or_null("GrassApron")
	var apron_f: StaticBody3D = fb.get_node_or_null("GrassApron")
	ok(apron_e != null and apron_f == null, "高架生成路基边坡,平图不生成")
	if apron_e != null:
		var av: PackedVector3Array = (apron_e.get_child(1) as MeshInstance3D) \
				.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var apron_over := 0
		var apron_low := 1e9
		for v in av:
			if v.x > -60.0 and v.x < 110.0 and absf(v.z) <= 8.0:
				apron_over += 1
				apron_low = minf(apron_low, v.y)
		ok(av.size() > 100, "路基边坡网格生成(%d 顶点)" % av.size())
		ok(apron_over == 0 or apron_low > 2.5,
				"边坡不吞并桥下路面(桥上范围内最低 %.2fm)" % apron_low)

	# --- 坡顶标线:细分后贴着路面折线,不切进凸竖曲线 ---
	var hump := _synth_track([{"id": "main", "surface": "road", "pts": _hump_pts()}], opts, 20.0)
	var hb := TrackBuilder.new()
	add_child(hb)
	hb.build(hump)
	var markings: MeshInstance3D = hb.get_node_or_null("Markings")
	ok(markings != null, "坡顶标线生成")
	if markings != null:
		var mv: PackedVector3Array = markings.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var below := 0
		var over_hump := 0
		for v in mv:
			var lat: Dictionary = hump.route_lateral(hump.main, v)
			if v.y < float(lat["road_y"]) + 0.02:
				below += 1
			if absf(v.x) < 15.0:
				over_hump += 1
		ok(over_hump > 50, "坡顶范围有标线顶点(%d)" % over_hump)
		ok(below == 0, "坡顶标线全部贴于路面之上(切入 %d/%d)" % [below, mv.size()])
	ok(hb.get_node_or_null("GrassApron") != null, "坡顶路基边坡生成")

	# --- 砂石路宽独立于护栏退距(gravel_width=4 < barrier_offset=8) ---
	var g_opts := {"walls": true, "wall_height": 0.8, "barrier_offset": 8.0, "gravel_width": 4.0, "sample_step": 2}
	var g_pts := PackedVector3Array()
	for z in range(0, -301, -3):
		g_pts.append(Vector3(0.0, 0.0, float(z)))
	var straight := _synth_track([{"id": "main", "surface": "road", "pts": g_pts}], g_opts, 20.0)
	var gb := TrackBuilder.new()
	add_child(gb)
	gb.build(straight)
	var gravel: StaticBody3D = gb.get_node_or_null("Gravel")
	ok(gravel != null, "窄砂石路肩生成")
	if gravel != null:
		var gv: PackedVector3Array = (gravel.get_child(1) as MeshInstance3D) \
				.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var max_sb := -1e9
		for v in gv:
			var lat: Dictionary = straight.main_lateral(v)
			max_sb = maxf(max_sb, float(lat["dist"]) - float(lat["half"]))
		ok(max_sb > 3.5 and max_sb < 4.6, "砂石外缘在路缘外 %.2fm(≈gravel_width=4)" % max_sb)
	var gwalls: StaticBody3D = gb.get_node_or_null("Walls")
	var gwall_ok := false
	if gwalls != null:
		var wv2: PackedVector3Array = (gwalls.get_child(1) as MeshInstance3D) \
				.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var sb_sum := 0.0
		for v in wv2:
			var lat: Dictionary = straight.main_lateral(v)
			sb_sum += float(lat["dist"]) - float(lat["half"])
		gwall_ok = sb_sum / wv2.size() > 7.0
	ok(gwall_ok, "护栏退距不受砂石宽度影响(仍 ≈8m)")

	fb.queue_free()
	eb.queue_free()
	hb.queue_free()
	gb.queue_free()

func _finish() -> void:
	print("========== %d checks, %d failures ==========" % [checks, failures])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if failures == 0 else 1)
