extends SceneTree
## 一次性实验（跑完即删）：验证 Godot 碰撞对是单向还是双向层匹配。
## 场景：A(layer=1,mask=1) 冲向 B——B 三种层配置分别试：
##   1) layer=4, mask=1（幽灵配置）  2) layer=3, mask=3（正常车）  3) layer=4, mask=1 但 A=layer3/mask3
## 观察 B 是否被推动 / body_entered 是否触发。

var _t := 0.0
var _case := 0
var _a: RigidBody3D
var _b: RigidBody3D
var _hits := 0

func _init() -> void:
	_make_ground()
	_a = _make_box(Vector3(0, 0.6, 8))
	_b = _make_box(Vector3(0, 0.6, 0))
	_b.body_entered.connect(func(_n): _hits += 1)

func _make_ground() -> void:
	var g := StaticBody3D.new()
	var s := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(40, 1, 40)
	s.shape = b
	g.add_child(s)
	g.position = Vector3(0, -0.5, 0)
	root.add_child(g)

func _make_box(pos: Vector3) -> RigidBody3D:
	var r := RigidBody3D.new()
	var s := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(1, 0.5, 1)
	s.shape = b
	r.add_child(s)
	r.position = pos
	r.gravity_scale = 0.0  # 悬空对撞：排除地面摩擦干扰
	r.can_sleep = false
	root.add_child(r)
	return r

func _process(delta: float) -> bool:
	_t += delta
	if _case == 0:
		_setup_case(4, 1, 1, 1, "A(1/1) vs B(4/1) 幽灵式")
		_case = 1
	elif _case == 1 and _t > 1.2:
		_report()
		_setup_case(3, 3, 1, 1, "A(1/1) vs B(3/3) 正常车")
		_case = 2
	elif _case == 2 and _t > 2.4:
		_report()
		_setup_case(4, 1, 3, 3, "A(3/3) vs B(4/1) 比赛幽灵")
		_case = 3
	elif _case == 3 and _t > 3.6:
		_report()
		print("[PROBE] done")
		quit(0)
	return false

func _setup_case(b_layer: int, b_mask: int, a_layer: int, a_mask: int, label: String) -> void:
	_b.collision_layer = b_layer
	_b.collision_mask = b_mask
	_a.collision_layer = a_layer
	_a.collision_mask = a_mask
	_a.global_position = Vector3(0, 0.6, 8)
	_b.global_position = Vector3(0, 0.6, 0)
	_a.linear_velocity = Vector3.ZERO
	_b.linear_velocity = Vector3.ZERO
	_a.linear_velocity = Vector3(0, 0, -8)
	_hits = 0
	_t = 0.0
	print("[PROBE] ---- %s" % label)

func _report() -> void:
	print("[PROBE] A.z=%.2f B.z=%.2f |vB|=%.2f hits=%d -> %s"
			% [_a.global_position.z, _b.global_position.z, _b.linear_velocity.length(), _hits,
			"碰撞" if _hits > 0 or absf(_b.global_position.z) > 0.2 else "无碰撞"])
