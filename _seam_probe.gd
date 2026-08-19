extends Node3D
## 决定性实验(一次运行出全部结论):
## 1) 构建后立即读 Gravel 形状:总面数/左面数/左右面积分布;
## 2) 记录 6 个左面质心 + 3 个右面质心(坐标来自形状自身);
## 3) 逐物理帧复查形状面数,并对记录质心打射线(打印命中体与高度)。

func _ready() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	var tb := TrackBuilder.new()
	add_child(tb)
	tb.build(data)
	var gravel: StaticBody3D = null
	for c in tb.get_children():
		if c is StaticBody3D and String(c.name) == "Gravel":
			gravel = c
	var shape: ConcavePolygonShape3D = null
	for ch in gravel.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape is ConcavePolygonShape3D:
			shape = (ch as CollisionShape3D).shape
	var faces := shape.get_faces()
	var left_c := []
	var right_c := []
	var l_area0 := 0.0
	var l_arean := 0
	var r_area0 := 0.0
	for k in range(0, faces.size(), 3):
		var cen := (faces[k] + faces[k + 1] + faces[k + 2]) / 3.0
		var area := (faces[k + 1] - faces[k]).cross(faces[k + 2] - faces[k]).length() * 0.5
		var lat := data.main_lateral(cen)
		var nrm := data.normal_at(float(lat["s"]))
		var rel: Vector3 = cen - (lat["foot"] as Vector3)
		var sd := rel.x * nrm.x + rel.z * nrm.z
		if sd > 0.05:
			if area < 0.01:
				l_arean += 1
			l_area0 = maxf(l_area0, 0.0)
			if left_c.size() < 6 and fmod(k, 400.0) < 3.0:
				left_c.append(cen)
		elif sd < -0.05:
			r_area0 = maxf(r_area0, 0.0)
			if right_c.size() < 3 and fmod(k, 400.0) < 3.0:
				right_c.append(cen)
	print("[D] 构建即读:总面 %d | 左质心样例 %d 右 %d | 左零面积面 %d" % [faces.size() / 3,
			left_c.size(), right_c.size(), l_arean])
	for fr in 3:
		await get_tree().physics_frame
		var space := get_world_3d().direct_space_state
		var fc := shape.get_faces().size() / 3
		var msg := ""
		for cen in left_c:
			msg += _ray(space, cen, "L")
		for cen in right_c:
			msg += _ray(space, cen, "R")
		print("[D] 帧%d 形状面 %d | %s" % [fr, fc, msg])
	get_tree().quit()

func _ray(space: PhysicsDirectSpaceState3D, p: Vector3, tag: String) -> String:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(p.x, p.y + 1.0, p.z), Vector3(p.x, p.y - 1.0, p.z))
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return "%s未中 " % tag
	var gs: Array = (hit["collider"] as CollisionObject3D).get_groups()
	return "%s%+.2f(%s) " % [tag, (hit["position"] as Vector3).y - p.y,
			str(gs[0]) if gs.size() > 0 else "?"]
