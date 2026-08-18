extends SceneTree
## 车-车碰撞冲击自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配：每台车挂 CollisionKick 后接触上报开启、碰撞盒（贴地低盒）被组件捕获；
## 2. 追尾（真实物理）：静止车被 10 m/s 追尾——被撞车被狠狠推离（求解器响应之外
##    还有放大冲量）、追尾车明显减速、双方均不翻车、双方组件各记账一次；
## 3. 轻蹭死区：接近速度 < bump_min_speed 只走原始求解，不放大（速度不变不记账）；
##    正常力度冲量幅值符合公式 Δv = strength×closing×μ/m；冷却期内重复触发只放大
##    一次；静态墙（非 Vehicle）直接忽略；
## 4. 甩尾：撞点落在碰撞盒角上（对方中心夹取到角点）→ 冲量力矩让车身绕 Y 甩开，
##    盒中心方向正撞则无旋转（力矩臂为零）；
## 5. 质量不对称：折合质量缩放让重车撞轻车时轻车 Δv 更大；双方各推自己、
##    总动量变化≈0（方向相反等值冲量）；
## 6. 幽灵：被撞车切到幽灵碰撞层（仅检测层+只撞世界）后，实车从其身位穿行，
##    双方零放大零位移——倒转复位保护不受冲击放大干扰。
## 手动触发段直接调 _on_body_entered（确定性验数学），双方的 _pre_vel 需手动同步
## （组件运行时是每物理步前自动记录的碰前速度）；冲量施加后要等一个物理帧再读
## 速度/角速度——当帧读到的还是上一步的缓存值。

const KICK := preload("res://game/car/collision_kick.gd")
const TEST_CFG := {"strength": 0.6, "min_speed": 2.0, "max_speed": 25.0, "yaw": 1.0}

var _a: Vehicle
var _b: Vehicle
var _ka: CollisionKick
var _kb: CollisionKick
var _fails := 0
var _started := false
var _done := false

func _init() -> void:
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(60, 1, 60)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)

	_a = _make_car(Vector3(0, 0.6, 0))
	_b = _make_car(Vector3(0, 0.6, -14.0))
	_ka = _a.get_node("CollisionKick") as CollisionKick
	_kb = _b.get_node("CollisionKick") as CollisionKick

func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return _done

func _make_car(pos: Vector3) -> Vehicle:
	var v: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach(v, "601", "sport_v1", "stock_v1")
	v.position = pos
	# 比赛层约定（Racer 头注释）：车体 layer=2|4、mask=1|2，与幽灵 layer=4/mask=1
	# 双向均不相交——幽灵测试按此约定验证穿行
	v.collision_layer = Racer.CAR_LAYER
	v.collision_mask = Racer.CAR_MASK
	var kick: CollisionKick = KICK.new()
	kick.name = "CollisionKick"
	v.add_child(kick)
	kick.setup(v, TEST_CFG)
	root.add_child(v)
	v.can_sleep = false  # 睡眠车被撞唤醒时序不确定，测试关睡眠保确定
	return v

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

func _run() -> void:
	await _frames(120)  # 出生抬高自由沉降，悬挂静置后再开测
	_check_setup()

	# ---- 1. 追尾（真实物理） ----
	_a.linear_velocity = Vector3(0, 0, -10.0)
	var waited := 0
	while waited < 240 and _b.linear_velocity.length() <= 1.0:
		await physics_frame
		waited += 1
	await _frames(21)  # 撞后 0.35s：让冲量效果显形（轮胎抵消一部分）
	_expect(_b.linear_velocity.length() > 1.0, "追尾确实发生", "vB=%.2f" % _b.linear_velocity.z)
	_check_rear_hit()

	# ---- 2. 轻蹭死区 / 冲量幅值 / 冷却 / 撞墙（手动触发，一帧后读数） ----
	_reset_pair(Vector3(3, 0.6, 0), Vector3(-3, 0.6, 0))  # 悬空分离，验纯数学
	_ka._pre_vel = Vector3(-1.0, 0, 0)
	_a.linear_velocity = Vector3(-1.0, 0, 0)
	_ka._on_body_entered(_b)
	await physics_frame
	_expect(absf(_a.linear_velocity.x + 1.0) < 0.05, "轻蹭（<2 m/s）不放大，速度不变",
			"vx=%.3f" % _a.linear_velocity.x)
	_expect(_ka.hits == 0, "轻蹭不记账", "hits=%d" % _ka.hits)

	_ka._pre_vel = Vector3(-8.0, 0, 0)
	_a.linear_velocity = Vector3(-8.0, 0, 0)
	_ka._on_body_entered(_b)
	await physics_frame
	var dv1 := _a.linear_velocity.x + 8.0
	_ka._on_body_entered(_b)  # 冷却期内：应被拦截
	await physics_frame
	var dv2 := _a.linear_velocity.x + 8.0
	# Δv = strength×closing×μ/m = 0.6×8×750/1500 = 2.4
	_expect(dv1 > 2.0 and dv1 < 2.8, "放大冲量幅值符合公式（Δv≈2.4）", "dv=%.3f" % dv1)
	_expect(absf(dv2 - dv1) < 0.05, "冷却期内重复触发不二次放大", "dv=%.3f->%.3f" % [dv1, dv2])
	_expect(_ka.hits == 1, "冷却内只记账一次", "hits=%d" % _ka.hits)

	_ka._pre_vel = Vector3(-8.0, 0, 0)
	_a.linear_velocity = Vector3(-8.0, 0, 0)
	var wall := StaticBody3D.new()
	root.add_child(wall)
	_ka._on_body_entered(wall)
	await physics_frame
	_expect(absf(_a.linear_velocity.x + 8.0) < 0.05, "撞墙（非车体）不放大",
			"vx=%.3f" % _a.linear_velocity.x)
	wall.queue_free()

	# ---- 3. 甩尾（角撞出转，正撞无转） ----
	_reset_pair(Vector3(6, 0.6, 0), Vector3(0, 0.6, 0))
	await _frames(60)  # B 落地静置（甩尾要在胎阻下显形才算数）
	var to_a := Vector3(-2.5, 0, -3.8)  # B 的前左角外（盒间隙 ~0.5m 不产生真实接触）
	_a.global_position = _b.global_position + to_a
	_a.linear_velocity = -to_a.normalized() * 8.0
	_ka._pre_vel = _a.linear_velocity  # B 的 handler 会交叉读本值
	_kb._pre_vel = Vector3.ZERO
	var yaw0 := _b.rotation.y
	_kb._on_body_entered(_a)
	_a.linear_velocity = Vector3.ZERO  # 手动验数学：真实求解不介入本次
	await physics_frame
	var wy := _b.angular_velocity.y
	_expect(absf(wy) > 0.15, "角落撞击产生偏航角速度（|ωy|>0.15）", "ωy=%.2f" % wy)
	await _frames(35)
	var dyaw := absf(_b.rotation.y - yaw0)
	_expect(dyaw > deg_to_rad(5.0), "0.6s 内甩出可见偏航（>5°）", "%.1f°" % rad_to_deg(dyaw))
	_expect(_b.global_transform.basis.y.dot(Vector3.UP) > 0.7, "甩尾不翻车", "")

	# 正后方对照：撞点夹取到盒中心面 → 力矩臂纯俯仰、无偏航分量
	_reset_pair(Vector3(0, 0.6, 0), Vector3(0, 0.6, -14.0))  # 悬空即可，一帧内无胎阻干扰
	var back := Vector3(0, 0, 5.0)
	_a.global_position = _b.global_position + back
	_a.linear_velocity = -back.normalized() * 8.0
	_ka._pre_vel = _a.linear_velocity
	_kb._pre_vel = Vector3.ZERO
	_kb._on_body_entered(_a)
	_a.linear_velocity = Vector3.ZERO
	await physics_frame
	_expect(absf(_b.angular_velocity.y) < 0.05, "正后方撞击无偏航（力矩臂为零）",
			"ωy=%.3f" % _b.angular_velocity.y)

	# ---- 4. 质量不对称 + 动量守恒（手动触发，一帧后读数） ----
	_reset_pair(Vector3(3, 0.6, 0), Vector3(-3, 0.6, 0))
	_a.mass = 2200.0  # 重车 A
	_b.mass = 900.0   # 轻车 B
	_ka._pre_vel = Vector3(-10.0, 0, 0)
	_kb._pre_vel = Vector3.ZERO
	_a.linear_velocity = Vector3(-10.0, 0, 0)
	_b.linear_velocity = Vector3.ZERO
	var p0 := _a.linear_velocity * _a.mass + _b.linear_velocity * _b.mass
	_ka._on_body_entered(_b)
	_kb._on_body_entered(_a)
	await physics_frame
	var dv_a := _a.linear_velocity.x + 10.0
	var dv_b := _b.linear_velocity.x  # B 从 0 起步
	var p1 := _a.linear_velocity * _a.mass + _b.linear_velocity * _b.mass
	_expect(dv_b > dv_a * 1.5, "轻车被撞 Δv 明显大于重车（折合质量缩放）",
			"dvA=%.2f dvB=%.2f" % [dv_a, dv_b])
	_expect((p1 - p0).length() < 1.0, "双方冲量等值反向，总动量守恒",
			"|Δp|=%.2f" % (p1 - p0).length())
	_a.mass = _a.vehicle_mass
	_b.mass = _b.vehicle_mass

	# ---- 5. 幽灵穿行（真实物理） ----
	_reset_pair(Vector3(0, 0.6, 8.0), Vector3(0, 0.6, 0.0))
	await _frames(40)
	_b.collision_layer = Racer.LAYER_CAR_DETECT  # 幽灵：仅检测层 + 只撞世界
	_b.collision_mask = Racer.LAYER_WORLD
	var b0 := _b.global_position.z
	var hits0 := _ka.hits + _kb.hits
	_a.linear_velocity = Vector3(0, 0, -12.0)
	_ka._pre_vel = Vector3(0, 0, -12.0)
	await _frames(96)
	print("[BUMP] 幽灵穿行后 A.z=%.2f B.z=%.2f |vB|=%.2f hits=%d"
			% [_a.global_position.z, _b.global_position.z, _b.linear_velocity.length(),
			_ka.hits + _kb.hits])
	_expect(_a.global_position.z < -6.0, "实车从幽灵车身位穿过（无实体阻挡）",
			"zA=%.2f" % _a.global_position.z)
	_expect(absf(_b.global_position.z - b0) < 0.1 and _b.linear_velocity.length() < 0.5,
			"幽灵车零位移零冲击", "zB=%.2f v=%.2f" % [_b.global_position.z, _b.linear_velocity.length()])
	_expect(_ka.hits + _kb.hits == hits0, "幽灵接触不触发放大", "hits=%d" % (_ka.hits + _kb.hits))

	_done = true
	print("[BUMP] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)

func _check_setup() -> void:
	for pair in [[_a, _ka, "A"], [_b, _kb, "B"]]:
		var v: Vehicle = pair[0]
		var k: CollisionKick = pair[1]
		_expect(v.get_node_or_null("CollisionKick") is CollisionKick,
				"%s 车挂有 CollisionKick" % pair[2])
		_expect(v.contact_monitor and v.max_contacts_reported >= 4,
				"%s 车接触上报开启" % pair[2])
		_expect(k._has_box, "%s 车碰撞盒被组件捕获（甩尾力矩可用）" % pair[2])

func _check_rear_hit() -> void:
	var vb := _b.linear_velocity.z  # 被撞车前进方向速度（<0 为 -Z）
	var va := _a.linear_velocity.z
	var up_a := _a.global_transform.basis.y.dot(Vector3.UP)
	var up_b := _b.global_transform.basis.y.dot(Vector3.UP)
	print("[BUMP] 追尾后 vB=%.2f vA=%.2f upA=%.2f upB=%.2f hitsA=%d hitsB=%d"
			% [vb, va, up_a, up_b, _ka.hits, _kb.hits])
	_expect(vb < -6.0, "被撞车被狠狠推离（|vB|>=6 m/s，含轮胎抵消余量）", "vB=%.2f" % vb)
	_expect(va > vb + 3.0 and va > -6.0, "追尾车明显减速", "vA=%.2f" % va)
	_expect(up_a > 0.7 and up_b > 0.7, "双方均不被撞翻", "upA=%.2f upB=%.2f" % [up_a, up_b])
	_expect(_ka.hits >= 1 and _kb.hits >= 1, "双方组件各放大一次", "hitsA=%d hitsB=%d" % [_ka.hits, _kb.hits])

## 复位两车到指定位置并清速度/冷却/记账
func _reset_pair(pa: Vector3, pb: Vector3) -> void:
	for pair in [[_a, _ka, pa], [_b, _kb, pb]]:
		var v: Vehicle = pair[0]
		var k: CollisionKick = pair[1]
		v.global_position = pair[2]
		v.rotation = Vector3.ZERO
		v.linear_velocity = Vector3.ZERO
		v.angular_velocity = Vector3.ZERO
		k._cooldown = 0.0
		k._pre_vel = Vector3.ZERO
		k.hits = 0

func _expect(cond: bool, label: String, detail := "") -> void:
	if cond:
		print("[BUMP] OK   %s %s" % [label, detail])
	else:
		_fails += 1
		print("[BUMP] FAIL %s %s" % [label, detail])
