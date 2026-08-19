extends SceneTree
func _init() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)
	for c in tb.get_children():
		if not (c is StaticBody3D):
			continue
		for ch in c.get_children():
			if not (ch is MeshInstance3D):
				continue
			var a: Array = ch.mesh.surface_get_arrays(0)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var nn: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var bad := 0
			for k in range(0, v.size(), 3):
				if (v[k + 1] - v[k]).cross(v[k + 2] - v[k]).dot(nn[k]) <= 0.0:
					bad += 1
			print("[W] %s/%s 面 %d 背面 %d" % [c.name, ch.name, v.size() / 3, bad])
	quit()
