extends SceneTree
## 碰撞体检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配美术后碰撞体应从 demo 占位凸包（2.45×1.3×0.6，车头/车尾/两侧大片
##    无碰撞区）重建为贴地底盘低盒：长宽贴合真实车壳包围盒、盒底离地 ~0.15、
##    盒高 0.5 且远低于车顶；
## 2. 撞墙：全油门冲静止墙，车头抵墙停下（不穿墙、停车位置与车壳长度吻合，
##    旧占位凸包会多扎进墙 ~1.1m），车身不被顶翻；
## 3. 防翻：静止接地状态横滚 35°，接地防翻应在数秒内把车身拉回水平。

var _v: Vehicle
var _fails := 0
var _t := 0.0
var _phase := 0
var _wall_face_z := -5.5

func _init() -> void:
	# 地面 + 墙（Road 表面组：GEVP 轮胎表面检测按组名取）
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(80, 1, 80)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)

	var wall := StaticBody3D.new()
	wall.add_to_group("Road")
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(8, 3, 1)
	ws.shape = wb
	wall.add_child(ws)
	wall.position = Vector3(0, 1.5, _wall_face_z - 0.5)
	root.add_child(wall)

	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_v.position = Vector3(0, 0.6, 0)
	var assembled: bool = CarMeshBuilder.attach(_v, "601", "sport_v1", "stock_v1")
	root.add_child(_v)
	_check_shape(assembled)

func _process(delta: float) -> bool:
	_t += delta
	match _phase:
		0:
			_v.throttle_input = 1.0   # 全油门冲墙（车头朝 -Z）
			if _t > 4.0:
				var z := _v.global_position.z
				var up := _v.global_transform.basis.y.dot(Vector3.UP)
				print("[COLLIDE] 撞墙停车 z=%.2f（墙面 %.2f + 盒前伸 ~2.33）up=%.2f" % [z, _wall_face_z, up])
				_expect(z > _wall_face_z + 1.9, "不穿墙（车头停在墙面）", "z=%.2f" % z)
				_expect(z < _wall_face_z + 2.9, "停车位置贴合车壳长度（占位凸包会扎进墙 ~1.1m）", "z=%.2f" % z)
				_expect(up > 0.7, "撞墙不被顶翻", "up=%.2f" % up)
				_phase = 1
				# 防翻测试：另起空地，静止接地横滚 35°
				_v.throttle_input = 0.0
				_v.linear_velocity = Vector3.ZERO
				_v.angular_velocity = Vector3.ZERO
				_v.global_position = Vector3(6, 0.6, 0)
				_v.rotation = Vector3(0, 0, deg_to_rad(35.0))
		1:
			if _t > 9.0:
				var up := _v.global_transform.basis.y.dot(Vector3.UP)
				print("[COLLIDE] 横滚 35° 后 5s up=%.2f" % up)
				_expect(up > 0.9, "接地侧倾 35° 数秒内回正", "up=%.2f" % up)
				_phase = 2
				print("[COLLIDE] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
				quit(0 if _fails == 0 else 1)
	return _phase == 2

func _check_shape(assembled: bool) -> void:
	_expect(assembled, "601 美术装配成功")
	var col := _v.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not col.shape is BoxShape3D:
		_expect(false, "碰撞体重建为贴地底盘低盒", "shape=%s" % [col.shape if col else "无节点"])
		return
	var box: BoxShape3D = col.shape
	# 601 实测车壳包围盒：宽 2.114 / 长 4.759 / 顶 1.283；前轴 y=0.19，胎半径 0.341
	var ground := 0.19 - 0.341
	var bottom := col.transform.origin.y - box.size.y * 0.5
	var top := col.transform.origin.y + box.size.y * 0.5
	_expect(absf(box.size.x - 2.014) < 0.1, "盒宽贴合车壳（±0.05 内缩）", "w=%.3f" % box.size.x)
	_expect(absf(box.size.z - 4.659) < 0.15, "盒长贴合车壳（±0.05 内缩）", "l=%.3f" % box.size.z)
	_expect(absf(bottom - ground - 0.15) < 0.05, "盒底离地 0.15（避让悬挂压缩）", "clear=%.3f" % (bottom - ground))
	_expect(top - ground < 0.7, "盒高贴地低矮（0.5）", "h_above_ground=%.3f" % (top - ground))
	_expect(top < 1.283 - 0.3, "盒顶远低于车顶（接触点压到质心附近）", "top=%.3f roof=1.283" % top)

func _expect(cond: bool, label: String, detail := "") -> void:
	if not cond:
		_fails += 1
		print("[COLLIDE] FAIL %s %s" % [label, detail])
