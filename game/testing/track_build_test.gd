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
	ok(absf(data.length - 4130.4) < 2.0, "主路长度 %.1fm(含 20m 发车引道)" % data.length)
	ok(data.routes.size() == 3, "路由数 %d(主路+分支)" % data.routes.size())

	var anchor: float = float(data.grid_cfg.get("anchor_s", 0.0))
	ok(absf(anchor - 20.0) < 0.01, "发车引道 anchor_s=%.1f" % anchor)
	var p_leadin := data.point_at(0.0)
	ok(p_leadin.distance_to(Vector3(0, 0, 20)) < 1.5, "point_at(0) 在引道尾端 %s" % [p_leadin])
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
	var g4 := data.grid_position(4)
	var back1: float = (g1 - p0).dot(fwd)
	var back4: float = (g4 - p0).dot(fwd)
	ok(back4 < back1 - 6.0, "4 号发车位在 1 号后方(%.1f < %.1f)" % [back4, back1])
	for g_no in [1, 4]:
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
	ok(builder.get_node_or_null("FinishGate") != null, "FinishGate 生成")
	ok(get_tree().get_nodes_in_group("Road").size() >= 2, "Road 组 %d 个(路面+墙)" % get_tree().get_nodes_in_group("Road").size())
	ok(get_tree().get_nodes_in_group("Dirt").size() >= 1, "Dirt 组 %d 个" % get_tree().get_nodes_in_group("Dirt").size())
	ok(get_tree().get_nodes_in_group("Grass").size() >= 1, "Grass 组 %d 个" % get_tree().get_nodes_in_group("Grass").size())
	ok(builder.junctions.size() == 4, "岔口融合 %d 处(4 个 dirt 端头均衔主路)" % builder.junctions.size())
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
