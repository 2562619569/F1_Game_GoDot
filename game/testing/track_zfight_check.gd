extends SceneTree
## headless 校验:TrackBuilder 主辅路岔口融合质量。运行:
## godot --headless --path . -s res://game/testing/track_zfight_check.gd
## 覆盖:辅路几何不得进入主路覆盖区(两路面无重叠像素 = 无 z-fighting)、
## 路缘缝口近齐平(仅 SEAM_KERB 缝阶)、岔口墙体与路缘边线断开、辅路高于草面。

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

	# --- 辅路几何与主路零重叠:主路覆盖区内(低于路面 OVERPASS_CLEAR)不得有顶点 ---
	var inside_bad := 0    # 覆盖区内残留顶点(= 重叠 = 会闪烁)
	var seam_bad := 0      # 缝口带(路缘 ±0.6m):应近齐平(≤ 主路面下 ~7cm)
	var below_grass := 0   # 任意辅路顶点不得低于草面
	var total := 0
	for c in dirt_bodies:
		var mi: MeshInstance3D = c.get_child(1)
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		total += verts.size()
		for v in verts:
			var lat := data.main_lateral(v)
			var inside := float(lat["half"]) - float(lat["dist"])
			var road_y := float(lat["road_y"])
			if inside > 0.25:
				if v.y < road_y + 0.3:
					inside_bad += 1  # 覆盖区内低几何 = 与主路重叠;高出路面的桥不算
			elif inside > -0.6 and absf(v.y - road_y) > 0.07:
				seam_bad += 1
			if v.y < grass_top + 0.02:
				below_grass += 1
	ok(total > 0, "辅路网格顶点 %d 个" % total)
	ok(inside_bad == 0, "主路覆盖区内无辅路几何(零重叠),残留 %d" % inside_bad)
	ok(seam_bad == 0, "缝口带近齐平(±0.07m),越界 %d" % seam_bad)
	ok(below_grass == 0, "辅路整体高于草面(越界 %d)" % below_grass)

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
