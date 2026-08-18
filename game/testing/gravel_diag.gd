extends SceneTree
## 只打印不断言:沿急弯段逐截面 dump 两侧护栏退距与砂石 quad 剔除情况,
## 用于排查"左右砂石路不一样"。用法:
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
	var off := maxf(0.0, float(data.options.get("barrier_offset", 8.0)))
	var offs_l := tb._offsets(1.0, off)
	var offs_r := tb._offsets(-1.0, off)
	var pts: PackedVector3Array = data.main["pts"]
	var widths: PackedFloat32Array = data.main["widths"]
	var radii: PackedFloat32Array = data.main["radii"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var n := pts.size()

	# 找急弯段(R<25)并按 s 分组打印
	print("[DIAG] n=%d off=%.1f  R<25 的截面(每 2 个采样打 1 行):" % [n, off])
	print("[DIAG] i     s      R     half  turn  offL   offR   <- 弯内侧标记")
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
		var inner := "L" if cross_sign < 0.0 else "R"  # cross>0 -> inner=-1(右) 见 _offsets
		if absf(cross_sign) < 1e-6:
			inner = "-"
		print("[DIAG] %4d %6.1f %5.1f %5.1f  %-3s  %5.2f  %5.2f" % [i, float(s_arr[i]), r,
			float(widths[i]) * 0.5, inner, float(offs_l[i]), float(offs_r[i])])

	# 复算 _build_gravel 的逐 quad 远端剔除:统计两侧被整块丢掉的 quad
	var tans: PackedVector3Array = data.main["tans"]
	for pair in [["L", 1.0, offs_l], ["R", -1.0, offs_r]]:
		var sgn: float = pair[1]
		var offs: PackedFloat32Array = pair[2]
		var kept: Array = []
		var dropped := 0
		var drawn := 0
		for i in n:
			if float(offs[i]) < 0.4:
				continue
			var side := TrackData._flat_normal(tans[i])
			var half: float = float(widths[i]) * 0.5
			var inner_p := pts[i] + side * half * sgn
			var outer_p := pts[i] + side * (half + float(offs[i])) * sgn
			kept.append([i, inner_p, outer_p])
		for k in kept.size() - 1:
			if int(kept[k + 1][0]) != int(kept[k][0]) + 1:
				continue
			var ia := int(kept[k][0])
			var ib := int(kept[k + 1][0])
			var mid: Vector3 = (kept[k][1] + kept[k][2] + kept[k + 1][1] + kept[k + 1][2]) * 0.25
			var s_mid := (float(s_arr[ia]) + float(s_arr[ib])) * 0.5
			if tb._hits_far_road(mid, s_mid):
				dropped += 1
			else:
				drawn += 1
		print("[DIAG] %s 侧: 画出 quad %d, 整块剔除 %d" % [pair[0], drawn, dropped])
	quit()
