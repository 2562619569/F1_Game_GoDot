extends SceneTree
## 节点审计:逐 StaticBody3D 对比 可见网格三角形数 vs 碰撞形状面数,并按左右分桶。
## 直接回答:碰撞体是否丢了左侧砂石几何。

func _init() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)
	for c in tb.get_children():
		if not (c is StaticBody3D):
			continue
		var body := c as StaticBody3D
		var mesh_inst: MeshInstance3D = null
		var col_shape: CollisionShape3D = null
		for ch in body.get_children():
			if ch is MeshInstance3D:
				mesh_inst = ch
			elif ch is CollisionShape3D:
				col_shape = ch
		var mesh_tris := 0
		var mesh_y0 := 0
		if mesh_inst != null:
			var arrays: Array = mesh_inst.mesh.surface_get_arrays(0)
			mesh_tris = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		var faces := PackedVector3Array()
		if col_shape != null and col_shape.shape is ConcavePolygonShape3D:
			faces = (col_shape.shape as ConcavePolygonShape3D).get_faces()
		var col_tris := faces.size() / 3
		# 碰撞面按侧分桶
		var n_l := 0
		var n_r := 0
		for k in range(0, faces.size(), 3):
			var cen := (faces[k] + faces[k + 1] + faces[k + 2]) / 3.0
			var lat := data.main_lateral(cen)
			var nrm := data.normal_at(float(lat["s"]))
			var rel: Vector3 = cen - (lat["foot"] as Vector3)
			if rel.x * nrm.x + rel.z * nrm.z > 0.05:
				n_l += 1
			elif rel.x * nrm.x + rel.z * nrm.z < -0.05:
				n_r += 1
			else:
				pass
		print("[AUDIT] %s 组=%s 网格三角形 %d | 碰撞面三角形 %d(左 %d / 右 %d)" % [body.name,
				str(body.get_groups()), mesh_tris, col_tris, n_l, n_r])
	quit()
