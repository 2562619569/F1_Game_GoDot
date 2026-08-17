extends SceneTree
## headless 校验:TrackBuilder 主辅路岔口融合质量。运行:
## godot --headless --path . -s res://game/testing/track_zfight_check.gd
## 覆盖:辅路与主路重叠区的垂直分层(缝口齐平/深处下沉防 z-fighting)、
## 岔口墙体与路缘边线断开、辅路端帽(防斜接楔形缝)推入主路路面内。

var failures := 0

func ok(cond: bool, label: String) -> void:
	if cond:
		print("[TRK] OK   | %s" % label)
	else:
		failures += 1
		print("[TRK] FAIL | %s" % label)

func _init() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	ok(data != null, "加载 map_1.json")
	if data == null:
		_finish()
		return
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)

	# --- 岔口识别:map_1 两条 dirt 分支共 4 个端头均贴近主路 ---
	ok(tb.junctions.size() == 4, "岔口识别 %d 个(应为 4)" % tb.junctions.size())

	var grass: StaticBody3D = null
	var walls: StaticBody3D = null
	var markings: MeshInstance3D = null
	var dirt_bodies: Array = []
	for c in tb.get_children():
		if c is StaticBody3D:
			if c.name == "Grass":
				grass = c
			elif c.name == "Walls":
				walls = c
			elif c.is_in_group("Dirt"):
				dirt_bodies.append(c)
		elif c is MeshInstance3D and c.name == "Markings":
			markings = c
	var grass_top: float = grass.position.y + 0.05  # 盒厚 0.1,顶面 = 中心 + 半高

	# --- 辅路分层:按深入主路程度分类 ---
	var seam_bad := 0    # 缝口带(路缘 ±0.6m):与主路面差应 ≤ 7cm(近齐平)
	var deep_bad := 0    # 深入路面 ≥ 0.6m:应沉到主路面下 ≥ 4cm(防 z-fighting)
	var below_grass := 0  # 任意辅路顶点不得低于草面
	var total := 0
	var first_last: Array = []  # 各 dirt 端帽角点(防斜接缝)
	for c in dirt_bodies:
		var mi: MeshInstance3D = c.get_child(1)
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		total += verts.size()
		first_last.append_array([verts[0], verts[1], verts[verts.size() - 2], verts[verts.size() - 1]])
		for v in verts:
			var lat := data.main_lateral(v)
			var inside := float(lat["half"]) - float(lat["dist"])
			var road_y := float(lat["road_y"])
			if inside > 0.6:
				if v.y > road_y - 0.04:
					deep_bad += 1
			elif inside > -0.6 and absf(v.y - road_y) > 0.07:
				seam_bad += 1
			if v.y < grass_top + 0.02:
				below_grass += 1
	ok(total > 0, "辅路网格顶点 %d 个" % total)
	ok(seam_bad == 0, "缝口带与主路面近齐平(±0.07m),越界 %d" % seam_bad)
	ok(deep_bad == 0, "重叠深处沉入主路面下 ≥4cm,越界 %d" % deep_bad)
	ok(below_grass == 0, "辅路整体高于草面(越界 %d)" % below_grass)

	# --- 端帽角点:必须推入主路路面内 ≥1m(斜接口不留楔形草缝) ---
	var cap_bad := 0
	for v in first_last:
		var lat := data.main_lateral(v)
		if float(lat["half"]) - float(lat["dist"]) < 1.0:
			cap_bad += 1
	ok(cap_bad == 0, "端帽角点深入主路 ≥1m(越界 %d)" % cap_bad)

	# --- 墙体在岔口断开:墙顶点不得出现在岔口开口区 ---
	var wall_bad := 0
	if walls != null:
		var wmi: MeshInstance3D = walls.get_child(1)
		var wverts: PackedVector3Array = wmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in wverts:
			var lat := data.main_lateral(v)
			var s := float(lat["s"])
			for j in tb.junctions:
				if absf(s - float(j["s"])) < float(j["half"]) - 1.5:
					wall_bad += 1
					break
	ok(walls != null and wall_bad == 0, "墙体在岔口断开(开口区残留顶点 %d)" % wall_bad)

	# --- 路缘边线在岔口断开(中心虚线保留,按横向位置过滤) ---
	var line_bad := 0
	if markings != null:
		var lverts: PackedVector3Array = markings.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in lverts:
			var lat := data.main_lateral(v)
			var s := float(lat["s"])
			var off := absf(float(lat["dist"]))
			if off < float(lat["half"]) - 1.2:
				continue  # 中心虚线一带,不检
			for j in tb.junctions:
				if absf(s - float(j["s"])) < float(j["half"]) - 3.5:
					line_bad += 1
					break
	ok(markings != null and line_bad == 0, "路缘边线在岔口断开(开口区残留 %d)" % line_bad)

	_finish()

func _finish() -> void:
	print("[TRK] 结果: %s" % ("全部通过" if failures == 0 else "%d 项失败" % failures))
	quit(1 if failures > 0 else 0)
