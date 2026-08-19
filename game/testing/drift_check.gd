extends SceneTree
## 空格漂移模式自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配：DriftMode 挂载注入参数；组件代码缺省与 Game 表默认一致；
## 2. 门槛：低速（<speed_min）按住手刹不进入（发车 frozen 锁车速度≈0 同理由此防误触）；
## 3. 进入（真实物理）：20 m/s 前进 + 手刹 → 激活：手刹力 ×brake_scale、后轮
##    lateral_grip_scale=rear_grip（前轮不动保指向）、slip_assist/yaw_engage 放宽；
##    与 CollisionKick 失稳窗口零交集：countersteer_assist / stability_yaw_strength /
##    coefficient_of_friction 进漂移前后均不变；
## 4. 幂等刷新：漂移中外部把参数改走，一帧内被刷回漂移值；
## 5. 漂移真实发生：满转向 + 手刹持续 1.5s → 车身侧滑角峰值 >15°、车速 >8 m/s
##    （是滑行不是锁轮急刹）、不翻车；
## 6. 起漂甩尾冲量对照：yaw_kick 0.25 与 0 两轮同协议，起漂初期角速度显著更大
##    （转向本身也产生同向 ωy，故用对照差断言冲量贡献）；
## 7. 退出恢复：松开手刹 → 手刹力/滑移辅助/介入角/后轮侧向精确恢复原值，
##    drift_changed 信号成对触发；
## 8. 掉速自动退出：持续按住滑行减速，跌破 speed_min×0.75 后自动退出恢复。
## 输入直写 vehicle 输入变量（不走 Input/PlayerCar）；注意项目物理 120Hz，
## await physics_frame ×N ≈ N/120 秒。

const DRIFT := preload("res://game/car/drift_mode.gd")
## 与 Game 表 drift_* 保持同步（表改值后此处跟进；自检不依赖 autoload 读表）
const TEST_CFG := {"speed_min": 8.0, "brake_scale": 0.35, "rear_grip": 0.62,
		"slip_assist": 0.55, "yaw_engage": 0.22, "yaw_kick": 0.25}

const START_POS := Vector3(0, 0.6, 60.0)  # -Z 前进，400 地面跑道余量充足
const RUN_SPEED := 20.0

var _v: Vehicle
var _d: DriftMode
var _fails := 0
var _started := false
var _done := false
var _enter_sig := 0
var _exit_sig := 0

func _init() -> void:
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(400, 1, 400)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)

	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach(_v, "601", "sport_v1", "stock_v1")
	_v.position = START_POS
	_d = DRIFT.new()
	_d.name = "DriftMode"
	_v.add_child(_d)
	_d.setup(_v, TEST_CFG)
	root.add_child(_v)
	_v.can_sleep = false
	_d.drift_changed.connect(_on_drift_changed)

func _on_drift_changed(on: bool) -> void:
	if on:
		_enter_sig += 1
	else:
		_exit_sig += 1

func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return _done

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

## 每段开跑前复位车况：位置/姿态/速度清零、上帧位置同步（瞬移量会被当速度，
## process_drag 的二次方风阻当帧产生巨大冲量污染后续读数）、轮子预转到目标
## 车速（胎模型对静止轮有 ~8 m/s² 起转阻力，不预转就滑停）、离合分离
## （电机经离合的引擎制动不污染滑行减速）
func _reset_car(speed := RUN_SPEED) -> void:
	if _d.active:
		_d._exit()
	_v.global_position = START_POS
	_v.rotation = Vector3.ZERO
	_v.linear_velocity = Vector3(0, 0, -speed)
	_v.angular_velocity = Vector3.ZERO
	_v.previous_global_position = _v.global_position
	for wheel in _v.wheel_array:
		wheel.spin = speed / wheel.tire_radius
		wheel.previous_global_position = wheel.global_position
	_v.clutch_input = 1.0
	_v.throttle_input = 0.0
	_v.brake_input = 0.0
	# 预拉转速到功率带中段：真实玩家带速入漂，引擎已在转；怠速冷启的电机
	# 要先空转暖机半秒才接合出力，会低估漂移保速能力
	_v.motor_rpm = _v.max_rpm * 0.55

## 车身侧滑角 β = atan2(vx, -vz)：车头指向与行进方向的夹角，漂移主指标
func _slip_angle() -> float:
	return absf(atan2(_v.local_velocity.x, -_v.local_velocity.z))

func _run() -> void:
	await _frames(120)  # 出生抬高自由沉降，悬挂静置后再开测

	# ---- 1. 装配与参数注入 ----
	_expect(_v.get_node_or_null("DriftMode") is DriftMode, "车挂有 DriftMode")
	_expect(_d.speed_min == 8.0 and _d.brake_scale == 0.35 and _d.rear_grip == 0.62
			and _d.slip_assist == 0.55 and _d.yaw_engage == 0.22 and _d.yaw_kick == 0.25,
			"setup 注入漂移参数")
	_expect(DriftMode.DEFAULT_SPEED_MIN == 8.0 and DriftMode.DEFAULT_BRAKE_SCALE == 0.35
			and DriftMode.DEFAULT_REAR_GRIP == 0.62 and DriftMode.DEFAULT_SLIP_ASSIST == 0.55
			and DriftMode.DEFAULT_YAW_ENGAGE == 0.22 and DriftMode.DEFAULT_YAW_KICK == 0.25,
			"组件代码缺省与 Game 表默认一致")

	var hb0 := _v.max_handbrake_force
	var slip0 := _v.steering_slip_assist
	var yaw0 := _v.stability_yaw_engage_angle
	var cs0 := _v.countersteer_assist
	var yaws0 := _v.stability_yaw_strength
	var cof0: float = _v.coefficient_of_friction["Road"]

	# ---- 2. 低速门槛 ----
	_reset_car(5.0)
	_v.handbrake_input = 1.0
	await _frames(30)
	_expect(not _d.active, "低速（5 m/s < speed_min）按住手刹不进入", "speed=%.2f" % _v.speed)
	_expect(absf(_v.steering_slip_assist - slip0) < 0.001
			and absf(_v.max_handbrake_force - hb0) < 0.001, "未进入时不改任何参数")
	_v.handbrake_input = 0.0

	# ---- 3. 进入 + 参数快照 + 零交集 ----
	_reset_car()
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	await _frames(6)
	_expect(_d.active, "20 m/s 前进按手刹进入漂移", "speed=%.2f" % _v.speed)
	_expect(absf(_v.max_handbrake_force - hb0 * 0.35) < 0.001, "漂移中手刹力 ×brake_scale",
			"%.3f→%.3f" % [hb0, _v.max_handbrake_force])
	_expect(absf(_v.steering_slip_assist - 0.55) < 0.001, "转向滑移辅助放宽到 drift 值")
	_expect(absf(_v.stability_yaw_engage_angle - 0.22) < 0.001, "横摆稳定介入角放宽")
	_expect(absf(_v.rear_axle.wheels[0].lateral_grip_scale - 0.62) < 0.001 and
			absf(_v.rear_axle.wheels[1].lateral_grip_scale - 0.62) < 0.001,
			"后轮侧向抓地压低（两轮）")
	_expect(absf(_v.front_axle.wheels[0].lateral_grip_scale - 1.0) < 0.001 and
			absf(_v.front_axle.wheels[1].lateral_grip_scale - 1.0) < 0.001,
			"前轮侧向抓地不动（保指向）")
	_expect(absf(_v.countersteer_assist - cs0) < 0.001
			and absf(_v.stability_yaw_strength - yaws0) < 0.001
			and absf(float(_v.coefficient_of_friction["Road"]) - cof0) < 0.001,
			"不碰 CollisionKick 失稳参数集（零交集）")

	# ---- 4. 幂等刷新 ----
	_v.steering_slip_assist = 0.15
	await _frames(2)
	_expect(absf(_v.steering_slip_assist - 0.55) < 0.001, "外部改走参数一帧内刷回漂移值")

	# ---- 5. 漂移真实发生（1.5s，玩家协议：满舵起漂 → 收舵 hold 住动力滑胎） ----
	_v.clutch_input = 0.0
	_v.throttle_input = 0.7
	var peak := 0.0
	for i in 180:
		if i == 36:  # 0.3s 起漂后收舵：靠反打辅助 + 介入角限位维持漂移
			_v.steering_input = 0.35
		await physics_frame
		peak = maxf(peak, _slip_angle())
	print("[DRIFT] 1.5s 峰值侧滑角=%.1f° 末角=%.1f° 车速=%.2f m/s"
			% [rad_to_deg(peak), rad_to_deg(_slip_angle()), _v.speed])
	_expect(peak > deg_to_rad(15.0), "满转向+手刹起漂甩出侧滑角（>15°）",
			"peak=%.1f°" % rad_to_deg(peak))
	_expect(_v.speed > 8.0, "漂移保持车速不刹停（1.5s 后 >8 m/s）", "v=%.2f" % _v.speed)
	_expect(_slip_angle() > deg_to_rad(8.0), "1.5s 末仍处于滑移状态（侧滑角 >8°）",
			"β=%.1f°" % rad_to_deg(_slip_angle()))
	_expect(_v.global_transform.basis.y.dot(Vector3.UP) > 0.7, "漂移不翻车")

	# ---- 6. 起漂甩尾冲量对照 ----
	var with_kick: float = await _kick_run(0.25)
	var no_kick: float = await _kick_run(0.0)
	print("[DRIFT] 起漂 0.1s ωy：有冲量=%.3f 无冲量=%.3f" % [with_kick, no_kick])
	_expect(with_kick > no_kick + 0.08 and with_kick > 0.0,
			"起漂冲量朝转向方向补角速度（左打正 ωy）")

	# ---- 7. 退出恢复 ----
	_reset_car()
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	await _frames(6)
	_expect(_d.active, "复位后再入漂移（退出恢复段准备）")
	_v.handbrake_input = 0.0
	await _frames(6)
	_expect(not _d.active, "松开手刹退出漂移")
	_expect(absf(_v.max_handbrake_force - hb0) < 0.001
			and absf(_v.steering_slip_assist - slip0) < 0.001
			and absf(_v.stability_yaw_engage_angle - yaw0) < 0.001,
			"退出精确恢复手刹力/滑移辅助/介入角")
	_expect(absf(_v.rear_axle.wheels[0].lateral_grip_scale - 1.0) < 0.001
			and absf(_v.rear_axle.wheels[1].lateral_grip_scale - 1.0) < 0.001,
			"退出恢复后轮侧向抓地")
	_expect(_enter_sig == _exit_sig, "drift_changed 信号成对触发",
			"enter=%d exit=%d" % [_enter_sig, _exit_sig])

	# ---- 8. 掉速自动退出 ----
	_reset_car()
	_v.steering_input = 0.0
	_v.handbrake_input = 1.0
	await _frames(6)
	_expect(_d.active, "按住手刹再次进入（掉速段准备）")
	var exited := false
	for i in 960:  # 8s 预算：0.35 手刹 + 漂移侧向磨滑把 20 m/s 拖到 6 以下
		await physics_frame
		if not _d.active:
			exited = true
			break
	_expect(exited and _v.speed < 8.0, "持续按住滑行掉速自动退出（<speed_min×0.75）",
			"v=%.2f" % _v.speed)

	_done = true
	print("[DRIFT] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)

## 起漂冲量对照段：复位 → 满左转 + 手刹起漂，激活后第 12 帧（0.1s）读 ωy。
## 有无冲量两轮同协议，差值即冲量贡献
func _kick_run(kick: float) -> float:
	_reset_car()
	_d.yaw_kick = kick
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	var entered := false
	for i in 10:
		await physics_frame
		if _d.active:
			entered = true
			break
	if not entered:
		return -999.0
	await _frames(12)
	var wy := _v.angular_velocity.y
	_v.handbrake_input = 0.0
	_d.yaw_kick = float(TEST_CFG["yaw_kick"])
	return wy

func _expect(cond: bool, label: String, detail := "") -> void:
	if cond:
		print("[DRIFT] OK   %s %s" % [label, detail])
	else:
		_fails += 1
		print("[DRIFT] FAIL %s %s" % [label, detail])
