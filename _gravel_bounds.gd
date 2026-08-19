extends SceneTree

func _init() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)
	var gravel: StaticBody3D = null
	for c in tb.get_children():
		if c is StaticBody3D and String(c.name) == "Gravel":
			gravel = c
	var arrays: Array = (gravel.get_child(1) as MeshInstance3D).mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var hist := {}
	var y_min := 1e9
	var y_max := -1e9
	var sb_l_min := 1e9
	for k in range(0, vs.size(), 3):
		var cen := (vs[k] + vs[k + 1] + vs[k + 2]) / 3.0
		var lat := data.main_lateral(cen)
		var s := float(lat["s"])
		var nrm := data.normal_at(s)
		var rel: Vector3 = cen - (lat["foot"] as Vector3)
		if rel.x * nrm.x + rel.z * nrm.z <= 0.05:
			continue
		var bucket := int(s / 500.0) * 500
		hist[bucket] = int(hist.get(bucket, 0)) + 1
		y_min = minf(y_min, cen.y)
		y_max = maxf(y_max, cen.y)
		sb_l_min = minf(sb_l_min, float(lat["dist"]) - float(lat["half"]))
	print("[G] 左侧砂石 y %+.2f~%+.2f, 侧向最小 %.1f" % [y_min, y_max, sb_l_min])
	var keys := hist.keys()
	keys.sort()
	for b in keys:
		print("[G] 左侧砂石 s %d~%d: %d 个三角形" % [b, b + 500, int(hist[b])])
	quit()
