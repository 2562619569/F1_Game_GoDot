extends SceneTree
## 车-车碰撞冲击自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配：每台车挂 CollisionKick 后接触上报开启、碰撞盒（贴地低盒）被组件捕获；
## 2. 追尾（真实物理）：静止车被 10 m/s 追尾——被撞车被狠狠推离（求解器响应之外
##    还有放大冲量）、追尾车明显减速、双方均不翻车、双方组件各记账一次；
## 3. 轻蹭死区：接近速度 < bump_min_speed 只走原始求解，不放大（速度不变不记账）；
##    正常力度冲量幅值符合公式 Δv = strength×closing×μ/m；冷却期内重复触发只放大
##    一次；静态墙（非 Vehicle）直接忽略。（悬空验纯数学：复位抬高到轮胎离地，
##    否则一帧胎阻即可污染读数——旧版在地面跑导致 5 项误报）
## 4. 甩尾+失稳窗口（手动触发，被撞车带 25 m/s 巡航速度）：重击角落撞→被撞车
##    ωy 起得来、失稳窗口开启（胎摩擦/自动反打被压低）、0.6s 内甩出失控级偏航
##    （>25°，撞前角速度 ~0.1s 就被回稳系统吃掉，不开窗口到不了这个量级）、
##    窗口到期参数恢复、数秒内旋转收敛、不翻车；正后方撞击无偏航（力矩臂为零）；
## 5. 质量不对称：折合质量缩放让重车撞轻车时轻车 Δv 更大；双方各推自己、
##    总动量变化≈0（方向相反等值冲量）；
## 6. 幽灵：被撞车切到幽灵碰撞层（仅检测层+只撞世界）后，实车从其身位穿行，
##    双方零放大零位移——倒转复位保护不受冲击放大干扰。（实车出发前把轮子
##    预转到位：胎模型对静止轮的起转阻力 ~8 m/s²，不预转 1.6s 内就滑停）
## 手动触发段直接调 _on_body_entered（确定性验数学），双方的 _pre_vel 需手动同步
## （组件运行时是每物理步前自动记录的碰前速度）；冲量施加后要等一个物理帧再读
## 速度/角速度——当帧读到的还是上一步的缓存值。
## 注意项目物理为 120Hz：await physics_frame ×N ≈ N/120 秒（注释里的秒数按此换算）。

const KICK := preload("res://game/car/collision_kick.gd")
## 与 Game 表 bump_* 保持同步（表改值后此处跟进；自检不依赖 autoload 读表）
const TEST_CFG := {"strength": 0.7, "min_speed": 2.0, "max_speed": 25.0, "yaw": 2.5,
		"destab_speed": 6.0, "destab_time": 1.0, "destab_grip": 0.40}

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
	gb.size = Vector3(400, 1, 400)  # 甩尾段被撞车 25 m/s 巡航，需要足够跑道
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

func _make_car(pos: Vector3, mass := 1500.0) -> Vehicle:
	var v: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach(v, "601", "sport_v1", "stock_v1")
	v.vehicle_mass = mass  # 须在 add_child 触发 initialize 前设定（运行时改 mass 有引擎坑，见第 4 段注释）
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
	# y=1.8 抬离地面真悬空：段的注释本来就按「悬空验纯数学」设计，但旧版复位
	# 高度停在触地静置位，一帧胎阻就污染读数（轻蹭段实测被吃掉 0.76 m/s）
	_reset_pair(Vector3(3, 1.8, 0), Vector3(-3, 1.8, 0))
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
	# Δv = strength×closing×μ/m = 0.7×8×750/1500 = 2.8（余量吸收数值噪声）
	_expect(dv1 > 2.4 and dv1 < 3.3, "放大冲量幅值符合公式（Δv≈2.8）", "dv=%.3f" % dv1)
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

	# ---- 3. 甩尾 + 失稳窗口（被撞车带巡航速度，撞后角） ----
	_reset_pair(Vector3(-2.5, 0.6, 13.8), Vector3(0, 0.6, 10.0))
	await _frames(60)  # 落地静置（甩尾要在胎阻下显形才算数）
	_a.global_position = _b.global_position + Vector3(-2.5, 0, 3.8)  # B 后左角外 ~0.5m
	var n_hat := (_b.global_position - _a.global_position)
	n_hat.y = 0.0
	n_hat = n_hat.normalized()  # A→B 推力方向（水平投影，与组件内取法一致）
	_kb._pre_vel = Vector3(0, 0, -25.0)        # B 巡航 25 m/s
	_ka._pre_vel = _kb._pre_vel + n_hat * 8.0  # A 追撞后左角，接近速度 8 m/s
	_b.linear_velocity = _kb._pre_vel
	_a.linear_velocity = _ka._pre_vel
	var cof0: float = _b.coefficient_of_friction["Road"]
	var yaw0 := _b.rotation.y
	_kb._on_body_entered(_a)
	# A 改慢速跟随：消除追击分量，本次甩尾只由手动触发的冲量驱动
	_a.linear_velocity = Vector3(0, 0, -20.0)
	await physics_frame
	_expect(_kb._destab_left > 0.3, "重击触发被撞车失稳窗口", "left=%.2fs" % _kb._destab_left)
	_expect(_ka._destab_left < _kb._destab_left, "撞人方窗口份额更小（0.3）",
			"A=%.2fs B=%.2fs" % [_ka._destab_left, _kb._destab_left])
	_expect(_b.countersteer_assist <= CollisionKick.DESTAB_COUNTERSTEER + 0.01,
			"窗口内自动反打被压低", "cs=%.2f" % _b.countersteer_assist)
	_expect(float(_b.coefficient_of_friction["Road"]) < cof0 * 0.6,
			"窗口内轮胎摩擦被压低", "Road=%.2f（原 %.2f）" % [_b.coefficient_of_friction["Road"], cof0])
	var wy := _b.angular_velocity.y
	_expect(absf(wy) > 0.5, "后角撞击给出可观初始偏航（|ωy|>0.5）", "ωy=%.2f" % wy)
	await _frames(72)  # 0.6s @120Hz
	var dyaw := absf(angle_difference(_b.rotation.y, yaw0))
	_expect(dyaw > deg_to_rad(25.0), "0.6s 内甩出失控级偏航（>25°）", "%.1f°" % rad_to_deg(dyaw))
	# 窗口到期恢复参数，旋转随后收敛，不翻车
	var restored := false
	for i in 90:  # 窗口 ≤1s + 边际
		await physics_frame
		if _kb._destab_left <= 0.0:
			restored = true
			break
	_expect(restored, "失稳窗口到期", "")
	_expect(absf(_b.countersteer_assist - 0.9) < 0.01 and
			absf(float(_b.coefficient_of_friction["Road"]) - cof0) < 0.01,
			"窗口到期恢复自动反打与胎摩擦",
			"cs=%.2f Road=%.2f" % [_b.countersteer_assist, _b.coefficient_of_friction["Road"]])
	var settled := false
	for i in 210:  # 再给 3.5s 收敛预算
		await physics_frame
		if absf(_b.angular_velocity.y) < 0.15:
			settled = true
			break
	_expect(settled, "窗口到期后偏航角速度收敛（|ωy|<0.15）", "")
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

	# ---- 4. 质量不对称 + 动量守恒（手动触发，悬空验纯数学） ----
	# 不复用 _a/_b 运行时改质量：vehicle.gd 首帧设过自定义 inertia 后，改 mass
	# 无论经节点属性、重设 inertia 还是直推 PhysicsServer，服务器端 inv_mass 都
	# 不刷新（冲量按旧质量积分）——专建两车在 initialize 前设 vehicle_mass
	var heavy := _make_car(Vector3(3, 1.8, 0), 2200.0)
	var light := _make_car(Vector3(-3, 1.8, 0), 900.0)
	var kh := heavy.get_node("CollisionKick") as CollisionKick
	var kl := light.get_node("CollisionKick") as CollisionKick
	await _frames(2)  # 服务器端质量要等首个物理帧的 inertia 推送才同步，否则按默认 1kg 积分
	heavy.linear_velocity = Vector3(-10.0, 0, 0)
	light.linear_velocity = Vector3.ZERO
	kh._pre_vel = Vector3(-10.0, 0, 0)
	kl._pre_vel = Vector3.ZERO
	heavy.linear_velocity = Vector3(-10.0, 0, 0)
	light.linear_velocity = Vector3.ZERO
	var p0 := heavy.linear_velocity * heavy.mass + light.linear_velocity * light.mass
	kh._on_body_entered(light)
	kl._on_body_entered(heavy)
	await physics_frame
	var dv_a := heavy.linear_velocity.x + 10.0
	var dv_b := light.linear_velocity.x  # B 从 0 起步（被推离 A，符号为负）
	var p1 := heavy.linear_velocity * heavy.mass + light.linear_velocity * light.mass
	_expect(absf(dv_b) > absf(dv_a) * 1.5, "轻车被撞 Δv 明显大于重车（折合质量缩放）",
			"dvA=%.2f dvB=%.2f" % [dv_a, dv_b])
	# 守恒只验水平 x 分量：两车间一帧内重力贡献 y 动量 ~253（3100kg×g/120Hz）。
	# 阈值 30 ≈ 冲量的 0.7%——非物理帧内施加冲量、下一帧读数带 ~0.3% 边界噪声
	# （jA/jB 各偏 4~15 N·s，幅值断言已锁公式，这里只防单边漏发/双发）
	_expect(absf((p1 - p0).x) < 30.0, "双方冲量等值反向，总动量守恒（水平分量）",
			"|Δpx|=%.2f" % absf((p1 - p0).x))
	heavy.queue_free()
	light.queue_free()

	# ---- 5. 幽灵穿行（真实物理） ----
	_reset_pair(Vector3(0, 0.6, 8.0), Vector3(0, 0.6, 0.0))
	await _frames(160)  # 充分静置：0.6 落到静置位 ~0.15 有弹跳，残弹会让幽灵车漂移
	_b.collision_layer = Racer.LAYER_CAR_DETECT  # 幽灵：仅检测层 + 只撞世界
	_b.collision_mask = Racer.LAYER_WORLD
	_b.linear_velocity = Vector3.ZERO  # 清掉残余弹跳速度
	var b0 := _b.global_position.z
	var hits0 := _ka.hits + _kb.hits
	# 轮子预转到位（自由滚动）+ 切断离合：A 的电机还带着第 1 段追尾的高转速，
	# 离合接合会产生 ~8 m/s² 引擎制动，走不满穿行里程
	for wheel in _a.wheel_array:
		wheel.spin = 12.0 / wheel.tire_radius
	_a.clutch_input = 1.0
	_a.linear_velocity = Vector3(0, 0, -12.0)
	_ka._pre_vel = Vector3(0, 0, -12.0)
	await _frames(200)  # 1.67s @120Hz：-12 m/s 走 ~19m（0.8s 只够 9m）
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
		# 瞬移后同步上帧位置：否则车体把瞬移量当速度（local_velocity 峰值可达
		# 数千 m/s），process_drag 的二次方风阻当帧产生巨大冲量污染后续读数
		v.previous_global_position = v.global_position
		for wheel in v.wheel_array:
			wheel.previous_global_position = wheel.global_position
		k._cooldown = 0.0
		k._pre_vel = Vector3.ZERO
		k.hits = 0

func _expect(cond: bool, label: String, detail := "") -> void:
	if cond:
		print("[BUMP] OK   %s %s" % [label, detail])
	else:
		_fails += 1
		print("[BUMP] FAIL %s %s" % [label, detail])
