extends SceneTree
## headless 校验:TrackBuilder 主辅路岔口融合质量。运行:
## godot --headless --path . -s res://game/testing/track_zfight_check.gd
## 覆盖:辅路几何不得进入主路覆盖区(两路面无重叠像素 = 无 z-fighting)、
## 路缘缝口近齐平(仅 SEAM_KERB 缝阶)、护栏/砂石路肩在岔口走廊处开缺、
## 护栏退离路缘、砂石路肩夹在路缘与护栏之间且低于路面、辅路高于草面。

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

	# --- 岔口识别:map_1 两条 dirt 分支,当前共 2 个端头贴近主路 ---
	ok(tb.junctions.size() == 2, "岔口识别 %d 个(应为 2)" % tb.junctions.size())

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

	# --- 外退护栏:任何顶点不得落在路面走廊内(发卡弯两腿/汇合弯心不留墙) ---
	# 路面范围按有效路缘分(急弯收拢区路面边 < 全宽半路面,护栏贴实际路面边)
	var wall_bad := 0
	var on_road := 0
	var eff_l := tb._edge_offsets(data.main, 1.0)
	var eff_r := tb._edge_offsets(data.main, -1.0)
	if walls != null:
		var wmi: MeshInstance3D = walls.get_child(1)
		var wverts: PackedVector3Array = wmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in wverts:
			if tb._corridor_at(v, -0.3)["blocked"]:
				wall_bad += 1
			var lat := data.main_lateral(v)
			var ws := float(lat["s"])
			var wn := data.normal_at(ws)
			var wrel: Vector3 = v - (lat["foot"] as Vector3)
			var eff_arr := eff_l if wrel.x * wn.x + wrel.z * wn.z >= 0.0 else eff_r
			if float(lat["dist"]) < data.field_at(eff_arr, ws) - 0.15:
				on_road += 1
	ok(walls != null and wall_bad == 0, "护栏在岔口走廊断开(开口区残留顶点 %d)" % wall_bad)
	ok(walls != null and on_road == 0, "护栏不落入任何路面走廊(发卡弯邻腿/弯心,落上 %d)" % on_road)

	# --- 砂石路肩:夹在路缘与护栏之间,低于主路面,岔口走廊边缘精确裁剪 ---
	# 急弯窗(半径 <25m ±40m)内两腿路面汇合,内缘点投影到对面腿会让横向度量失真,
	# 该窗内不测下限(高度带与走廊裁剪仍测)
	var radii: PackedFloat32Array = data.main["radii"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var hairpins: Array = []
	for i in radii.size():
		if float(radii[i]) < 25.0:
			hairpins.append([float(s_arr[i]) - 40.0, float(s_arr[i]) + 40.0])
	var in_hp := func(s: float) -> bool:
		for wdw in hairpins:
			if s >= wdw[0] and s <= wdw[1]:
				return true
		return false
	var gravel: StaticBody3D = null
	for c in tb.get_children():
		if c is StaticBody3D and c.name == "Gravel":
			gravel = c
	var g_total := 0
	var g_bad := 0
	if gravel != null:
		var gmi: MeshInstance3D = gravel.get_child(1)
		var gverts: PackedVector3Array = gmi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		g_total = gverts.size()
		for v in gverts:
			var lat := data.main_lateral(v)
			var sb: float = float(lat["dist"]) - float(lat["half"])
			if not in_hp.call(float(lat["s"])) and (sb < -0.1 or sb > 9.5):
				g_bad += 1
			elif v.y > float(lat["road_y"]) - 0.005 or v.y < float(lat["road_y"]) - 0.3:
				g_bad += 1
			# 裁剪边线性插值在弯曲 dirt 边缘可浅穿 0.2~0.4m,穿透段被 dirt 表面
			# (高出砂石 3cm)覆盖,不可见无冲突;深穿(>0.5m)才是裁剪失败
			elif tb._corridor_at(v, -0.5)["blocked"]:
				g_bad += 1
	ok(gravel != null and g_total > 0, "砂石路肩生成(顶点 %d 个)" % g_total)
	ok(g_bad == 0, "砂石路肩在路缘~护栏带内、低于路面且贴走廊边裁剪(越界 %d)" % g_bad)

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
