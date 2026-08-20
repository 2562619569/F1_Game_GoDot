extends SceneTree
## 只打印不断言:沿急弯段逐截面 dump 两侧有效路缘,以及砂石环带/护栏等值线的
## 采样净距,用于排查"左右砂石路不一样/护栏立错位置"。用法:
##   godot --headless -s game/testing/gravel_diag.gd

const MAP := "res://game/race/tracks/data/map_1.json"

func _init() -> void:
	var data: TrackData = TrackData.load_json(MAP)
	if data == null:
		print("[DIAG] map load fail")
		quit(1)
		return
	var tb := TrackBuilder.new()
	tb.build(data)
	var pts: PackedVector3Array = data.main["pts"]
	var widths: PackedFloat32Array = data.main["widths"]
	var radii: PackedFloat32Array = data.main["radii"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var n := pts.size()
	var eff_l: PackedFloat32Array = tb._edge_offsets(data.main, 1.0)
	var eff_r: PackedFloat32Array = tb._edge_offsets(data.main, -1.0)

	# 找急弯段(R<25)并按 s 分组打印
	print("[DIAG] n=%d  R<25 的截面(每 2 个采样打 1 行):" % n)
	print("[DIAG] i     s      R     half  turn  effL   effR   <- 弯内侧标记")
	var in_arc := false
	for i in n:
		var r := float(radii[i])
		if r >= 25.0:
			in_arc = false
			continue
		if not in_arc:
			print("[DIAG] ---- 急弯段开始 ----")
			in_arc = true
		if i % 2 != 0:
			continue
		var cross_sign := 0.0
		if i > 0 and i < n - 1:
			cross_sign = tb._turn_cross(pts[i - 1], pts[i], pts[i + 1])
		var inner := "L" if cross_sign < 0.0 else "R"  # cross>0 -> inner=-1(右) 见 _edge_offsets
		if absf(cross_sign) < 1e-6:
			inner = "-"
		print("[DIAG] %4d %6.1f %5.1f %5.1f  %-3s  %5.2f  %5.2f" % [i, float(s_arr[i]), r,
			float(widths[i]) * 0.5, inner, float(eff_l[i]), float(eff_r[i])])

	# 砂石/护栏网格顶点的场净距分布:护栏应全部 ≈ off,砂石环带夹在 0 与 gw 之间
	var off := maxf(0.0, float(data.options.get("barrier_offset", 8.0)))
	var gw := maxf(0.0, float(data.options.get("gravel_width", off)))
	for pair in [["Walls", off], ["Gravel", gw]]:
		var node: Node3D = tb.get_node_or_null(pair[0])
		if node == null or node.get_child_count() < 2:
			print("[DIAG] %s: 无" % pair[0])
			continue
		var verts: PackedVector3Array = (node.get_child(1) as MeshInstance3D) \
				.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var want: float = pair[1]
		var best := 1e9
		var worst := -1e9
		var outside := 0
		var seen := {}
		for v in verts:
			var key := "%.2f|%.2f" % [v.x, v.z]
			if seen.has(key):
				continue
			seen[key] = true
			var f := tb.field_main.f_only(v.x, v.z)
			best = minf(best, f)
			worst = maxf(worst, f)
			if f > want + 0.8:
				outside += 1
		print("[DIAG] %s: 去重顶点 %d, 场值范围 [%.2f, %.2f](参考层 %.1f, 超出 %d)" % [
			pair[0], seen.size(), best, worst, want, outside])
	quit()
