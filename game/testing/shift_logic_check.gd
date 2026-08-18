extends SceneTree
## 自动换挡决策自检（godot --headless -s 运行，不依赖 autoload）：
## 用简化纵向动力学（引擎扭矩 − 风阻 − 滚阻 − 坡度 − 制动）驱动真实 process_transmission()，
## 验证换挡决策的"聪明"程度：
## 1. 平地/长上坡全油门：每挡及时升挡，不贴红线渐近卡挡；
## 2. 部分油门巡航：升挡点随油门前移，不拖到红线；
## 3. 巡航地板油：触发 kickdown（降挡后不超转前提下）；
## 4. 制动级联：重刹从高速降挡到位、降后不超转，且出弯地板油时已在功率带；
## 5. 弯中抑制升挡：侧向速度大时保持挡位，回正后恢复升挡；
## 6. 曲线自适应：换挡表跟随扭矩曲线变化（峰值提前回落的曲线应更早升挡）。
##
## 运行：godot --headless -s game/testing/shift_logic_check.gd

const _DT := 1.0 / 60.0
const _AIR_RHO := 1.225
const _G := 9.8

var _v: Vehicle
var _fails := 0
var _quiet := false

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_v.freeze = true
	_v.set_physics_process(false)
	root.add_child(_v)

func _process(_delta: float) -> bool:
	_check_flat_wot()
	_check_hill_wot()
	_check_part_throttle()
	_check_kickdown()
	_check_brake_cascade()
	_check_corner_hold()
	_check_curve_adaptive()
	_check_antihunt()
	print("[SHIFTLOGIC] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
	return true

func _expect(cond: bool, label: String, detail := "") -> void:
	if not cond:
		_fails += 1
		print("[SHIFTLOGIC] FAIL %s %s" % [label, detail])

# ---------------- 仿真内核 ----------------

## 应用 Car 表整车参数（镜像 CarBuilder.apply 的动力相关字段）
func _setup(cid: int) -> void:
	var cfg: Dictionary = load("res://config/dist/ModRacer/car.gd").new().data[cid]
	_v.vehicle_mass = maxf(500.0, float(cfg.weight))
	_v.max_torque = float(cfg.max_torque)
	_v.max_rpm = float(cfg.max_rpm)
	_v.final_drive = float(cfg.final_drive)
	var gears: Array[float] = []
	for g in cfg.gear_ratios:
		gears.append(float(g))
	_v.gear_ratios = gears
	_v.coefficient_of_drag = float(cfg.coefficient_of_drag)
	_v.frontal_area = float(cfg.frontal_area)
	_v.current_gear = 0
	_v.requested_gear = 0
	_v.is_shifting = false
	_v.is_up_shifting = false
	_v.delta_time = 0.0
	_v.last_shift_delta_time = 0.0
	_v.brake_input = 0.0
	_v.motor_rpm = _v.clutch_out_rpm + 200.0   # 起步前空挡转速，触发挂 1 挡

func _wheel_radius() -> float:
	if _v.average_drive_wheel_radius > 0.0:
		return _v.average_drive_wheel_radius
	var r := 0.0
	for wheel in _v.drive_wheels:
		r += wheel.tire_radius
	return r / maxf(1.0, float(_v.drive_wheels.size())) if r > 0.0 else 0.34

## 单步纵向仿真。brake_decel 为施加的制动力加速度（m/s²），lateral 为侧向速度
## （模拟弯中状态，供弯中抑制升挡逻辑读取）。返回 {accel=…, prev_gear_rpm=…}
func _sim_step(v_speed: float, throttle: float, grade: float, r: float,
		brake_decel := 0.0, lateral := 0.0) -> Dictionary:
	var ratio := _v.get_gear_ratio(_v.current_gear)
	var matched := absf(ratio) * (v_speed / r) * (60.0 / TAU)
	if _v.current_gear > 0 and not _v.is_shifting:
		_v.motor_rpm = maxf(matched, _v.idle_rpm)
	elif _v.is_shifting:
		_v.motor_rpm = lerpf(_v.motor_rpm, maxf(matched, _v.idle_rpm), 1.0 - exp(-_DT / 0.1))
	# 车轮自旋取无滑移口径（平地抓地充足），喂给 get_drivetrain_spin()
	for wheel in _v.drive_wheels:
		wheel.spin = v_speed / r
	_v.speed = v_speed
	_v.local_velocity.z = -v_speed   # 前进为 -Z
	_v.local_velocity.x = lateral    # 侧向速度（弯中状态）
	_v.throttle_input = throttle
	_v.throttle_amount = throttle    # 稳态油门（process_throttle 平滑后的口径）
	_v.brake_input = 1.0 if brake_decel > 0.0 else 0.0
	_v.brake_amount = clampf(brake_decel / 10.0, 0.0, 1.0)   # 踏板深度（级联武装用）
	_v.delta_time += _DT
	var prev_gear_rpm := 0.0
	if _v.current_gear - 1 > 0:
		prev_gear_rpm = _v.get_gear_ratio(_v.current_gear - 1) * (v_speed / r) * (60.0 / TAU)
	_v.process_transmission()

	var force := 0.0
	if _v.current_gear > 0 and not _v.is_shifting:
		force = _v.get_torque_at_rpm(_v.motor_rpm) * throttle * absf(ratio) / r
	var drag := 0.5 * _AIR_RHO * v_speed * v_speed * _v.frontal_area * _v.coefficient_of_drag
	var rr := (0.005 + 0.5 * (0.01 + 0.0095 * pow(v_speed * 0.036, 2))) * _v.vehicle_mass * _G
	var accel := (force - drag - rr - _v.vehicle_mass * _G * grade) / _v.vehicle_mass - brake_decel
	return {"accel": accel, "prev_gear_rpm": prev_gear_rpm}

## 跑一段场景，记录换挡事件与"加速停滞且未换挡"窗口
func _run(seconds: float, throttle: float, grade: float) -> Dictionary:
	var r := _wheel_radius()
	var v_speed := 0.0
	var events: Array[Dictionary] = []
	var last_gear := 0
	var stall_frames := 0
	var worst_stall := 0.0
	var worst_stall_gear := 0
	var worst_stall_prev_rpm := 0.0
	for i in int(round(seconds / _DT)):
		var out := _sim_step(v_speed, throttle, grade, r)
		v_speed = maxf(0.0, v_speed + out.accel * _DT)
		if _v.current_gear != last_gear:
			## 记录换挡瞬间"原挡位"的几何转速（升挡点口径），完成帧的 motor_rpm
			## 正在向新挡位回落，不能当换挡点用
			var shift_rpm := absf(_v.get_gear_ratio(last_gear)) * (v_speed / r) * (60.0 / TAU)
			events.append({
				"t": i * _DT, "gear": _v.current_gear,
				"speed": v_speed, "rpm": shift_rpm,
			})
			last_gear = _v.current_gear
			stall_frames = 0
		var top_gear := _v.current_gear >= _v.gear_ratios.size()
		if out.accel < 0.15 and _v.current_gear > 0 and not top_gear and not _v.is_shifting:
			stall_frames += 1
			if stall_frames * _DT > worst_stall:
				worst_stall = stall_frames * _DT
				worst_stall_gear = _v.current_gear
				worst_stall_prev_rpm = out.prev_gear_rpm
		else:
			stall_frames = 0
	return {
		"events": events, "speed": v_speed, "gear": _v.current_gear,
		"rpm": _v.motor_rpm, "worst_stall": worst_stall,
		"worst_stall_gear": worst_stall_gear, "worst_stall_prev_rpm": worst_stall_prev_rpm,
	}

# ---------------- 场景断言 ----------------

func _check_flat_wot() -> void:
	_setup(601)
	var res := _run(60.0, 1.0, 0.0)
	if not _quiet:
		for e in res.events:
			print("[SHIFTLOGIC] WOT601 t=%5.1fs -> G%d  v=%6.1f m/s (%3.0f km/h)  rpm=%5.0f/%.0f"
					% [e.t, e.gear, e.speed, e.speed * 3.6, e.rpm, _v.max_rpm])
		print("[SHIFTLOGIC] WOT601 end: v=%.1f km/h gear=%d rpm=%.0f stall=%.1fs@g%d"
				% [res.speed * 3.6, res.gear, res.rpm, res.worst_stall, res.worst_stall_gear])
	_expect(res.gear >= _v.gear_ratios.size(), "平地全油门应升满到顶挡",
			"end gear=%d/%d" % [res.gear, _v.gear_ratios.size()])
	_expect(res.worst_stall < 2.0, "平地全油门不得长时间停滞不换挡",
			"stall=%.1fs in G%d (prev_gear_rpm=%.0f)" % [res.worst_stall, res.worst_stall_gear, res.worst_stall_prev_rpm])
	if res.events.size() >= 3:
		var up_at := {}
		for e in res.events:
			if not up_at.has(e.gear):
				up_at[e.gear] = e.rpm
		_expect(up_at.get(2, 0.0) < _v.max_rpm * 0.85, "1 挡应短换挡（低挡推力过剩）",
				"1->2 at %.0f rpm (%.0f%%)" % [up_at.get(2, 0.0), up_at.get(2, 0.0) / _v.max_rpm * 100.0])
		_expect(up_at.get(3, 0.0) < _v.max_rpm * 0.88, "2 挡应短换挡",
				"2->3 at %.0f rpm (%.0f%%)" % [up_at.get(3, 0.0), up_at.get(3, 0.0) / _v.max_rpm * 100.0])
		_expect(up_at.get(4, 0.0) >= _v.max_rpm * 0.9, "3 挡以上应用满交点（高挡推力稀缺）",
				"3->4 at %.0f rpm (%.0f%%)" % [up_at.get(4, 0.0), up_at.get(4, 0.0) / _v.max_rpm * 100.0])

## 长上坡：5 挡的阻力平衡点贴在红线下方，严格 ">max_rpm" 永远差一点 → 卡挡。
func _check_hill_wot() -> void:
	_setup(601)
	var res := _run(50.0, 1.0, 0.07)
	if not _quiet:
		for e in res.events:
			print("[SHIFTLOGIC] HILL601 t=%5.1fs -> G%d  v=%6.1f m/s (%3.0f km/h)  rpm=%5.0f/%.0f"
					% [e.t, e.gear, e.speed, e.speed * 3.6, e.rpm, _v.max_rpm])
		print("[SHIFTLOGIC] HILL601 end: v=%.1f km/h gear=%d rpm=%.0f stall=%.1fs@g%d prev_rpm=%.0f"
				% [res.speed * 3.6, res.gear, res.rpm, res.worst_stall, res.worst_stall_gear, res.worst_stall_prev_rpm])
	_expect(res.worst_stall < 2.0, "长上坡全油门不得卡在非顶挡不换挡",
			"stall=%.1fs in G%d (prev_gear_rpm=%.0f, 降挡后不超转应踢降)" % [res.worst_stall, res.worst_stall_gear, res.worst_stall_prev_rpm])

func _check_part_throttle() -> void:
	_setup(601)
	var res := _run(25.0, 0.5, 0.0)
	var first_up: Dictionary = {}
	for e in res.events:
		if e.gear > 1:
			first_up = e
			break
	if not _quiet and first_up.size() > 0:
		print("[SHIFTLOGIC] HALF601 first upshift at rpm=%.0f/%.0f (%.0f%%)"
				% [first_up.rpm, _v.max_rpm, first_up.rpm / _v.max_rpm * 100.0])
	var detail := "no upshift"
	if first_up.size() > 0:
		detail = "first upshift rpm=%.0f (%.0f%%)" % [first_up.rpm, first_up.rpm / _v.max_rpm * 100.0]
	_expect(first_up.size() > 0 and first_up.rpm < _v.max_rpm * 0.9,
			"半油门升挡点应明显低于红线", detail)

func _check_kickdown() -> void:
	_setup(601)
	var r := _wheel_radius()
	# 直接放到 4 挡、降挡后转速 0.85 红线（不超转）的巡航点，消除挡位漂移
	_v.current_gear = 4
	var v_speed := r * (0.85 * _v.max_rpm) / (60.0 / TAU) / _v.get_gear_ratio(3)
	# 阶段一：小油门巡航 2 秒稳定（此点升挡线之上、降挡线之上，应保持 4 挡）
	var cruise_gear := 0
	var cruise_rpm := 0.0
	var prev_gear_rpm := 0.0
	for i in int(round(2.0 / _DT)):
		var out := _sim_step(v_speed, 0.45, 0.0, r)
		v_speed = maxf(0.0, v_speed + out.accel * _DT)
		cruise_gear = _v.current_gear
		cruise_rpm = _v.motor_rpm
		prev_gear_rpm = out.prev_gear_rpm
	# 阶段二：地板油 3 秒，应发生 kickdown（前提：降挡后不超转）
	var gear_before := _v.current_gear
	var kicked := false
	for i in int(round(3.0 / _DT)):
		_sim_step(v_speed, 1.0, 0.0, r)
		if _v.current_gear < gear_before:
			kicked = true
			break
	if not _quiet:
		print("[SHIFTLOGIC] KICK601 cruise G%d rpm=%.0f prev_rpm=%.0f -> floored: kicked=%s"
				% [cruise_gear, cruise_rpm, prev_gear_rpm, kicked])
	var top_gear := cruise_gear >= _v.gear_ratios.size()
	if not top_gear and prev_gear_rpm < _v.max_rpm * 0.95:
		_expect(kicked, "地板油应触发 kickdown 降挡",
				"cruise G%d rpm=%.0f prev_rpm=%.0f" % [cruise_gear, cruise_rpm, prev_gear_rpm])

## 重刹应级联降挡（降后不超转），且刹车松开地板油时发动机已在功率带
func _check_brake_cascade() -> void:
	_setup(601)
	var r := _wheel_radius()
	var v_speed := 0.0
	# 全油门拉到高速（顶挡）
	for i in int(round(35.0 / _DT)):
		v_speed = maxf(0.0, v_speed + _sim_step(v_speed, 1.0, 0.0, r).accel * _DT)
	var gear_before_brake := _v.current_gear
	# 8 m/s² 重刹到 24 m/s（预算 8s：级联线随目标挡变化，交叉点比旧固定线更晚）
	var downs := 0
	var over_rev := false
	var upshifted := false
	for i in int(round(8.0 / _DT)):
		if v_speed <= 24.0:
			break
		var before := _v.current_gear
		_sim_step(v_speed, 0.0, 0.0, r, 8.0)
		v_speed = maxf(0.0, v_speed - 8.0 * _DT)
		if _v.current_gear < before:
			downs += 1
			if _v.motor_rpm > _v.max_rpm:
				over_rev = true
		elif _v.current_gear > before:
			upshifted = true
	# 松刹滑行 0.5s：等最后一降完成、转速贴合（1s 换挡冷却挡住滑行早升挡）
	for i in int(round(0.5 / _DT)):
		_sim_step(v_speed, 0.0, 0.0, r)
	var rpm_at_floor := _v.motor_rpm
	# 刹车一松立即地板油：应已在功率带（级联降到高转速挡），无需等踢降
	for i in int(round(1.0 / _DT)):
		_sim_step(v_speed, 1.0, 0.0, r)
	if not _quiet:
		print("[SHIFTLOGIC] BRAKE601 G%d->G%d downs=%d rpm_at_floor=%.0f/%.0f over_rev=%s upshifted=%s"
				% [gear_before_brake, _v.current_gear, downs, rpm_at_floor, _v.max_rpm, over_rev, upshifted])
	_expect(downs >= 2, "重刹应级联降挡（至少两连降）", "downs=%d" % downs)
	_expect(not over_rev, "级联降挡后不得超转", "motor_rpm=%.0f" % _v.motor_rpm)
	_expect(not upshifted, "制动中不得升挡", "")
	_expect(rpm_at_floor >= _v.max_rpm * 0.7, "出弯地板油时应已在功率带",
			"rpm=%.0f (%.0f%%)" % [rpm_at_floor, rpm_at_floor / _v.max_rpm * 100.0])

## 侧向速度大（弯中）应保持挡位，回正后恢复升挡
func _check_corner_hold() -> void:
	_setup(601)
	var r := _wheel_radius()
	var v_speed := 0.0
	# 全油门拉到 4 挡且当前挡几何转速逼近升挡线（0.9 红线）。
	# 用几何转速而非 motor_rpm 判定：换挡完成帧 motor_rpm 仍是旧挡值，会误触发。
	for i in int(round(20.0 / _DT)):
		v_speed = maxf(0.0, v_speed + _sim_step(v_speed, 1.0, 0.0, r).accel * _DT)
		var ideal_now := absf(_v.get_gear_ratio(_v.current_gear)) * (v_speed / r) * (60.0 / TAU)
		if _v.current_gear >= 4 and not _v.is_shifting and ideal_now >= _v.max_rpm * 0.9:
			break
	var hold_gear := _v.current_gear
	# 注入侧向速度 1.5s：期间升挡条件应满足（转速冲过升挡线）但挡位保持
	var max_ideal := 0.0
	for i in int(round(1.5 / _DT)):
		var out := _sim_step(v_speed, 1.0, 0.0, r, 0.0, 6.0)
		v_speed = maxf(0.0, v_speed + out.accel * _DT)
		max_ideal = maxf(max_ideal, absf(_v.get_gear_ratio(_v.current_gear)) * (v_speed / r) * (60.0 / TAU))
	var held := _v.current_gear == hold_gear
	# 回正后 2.5s 内应恢复升挡
	var resumed := false
	for i in int(round(2.5 / _DT)):
		var out := _sim_step(v_speed, 1.0, 0.0, r)
		v_speed = maxf(0.0, v_speed + out.accel * _DT)
		if _v.current_gear > hold_gear:
			resumed = true
			break
	if not _quiet:
		print("[SHIFTLOGIC] CORNER601 hold G%d held=%s max_ideal=%.0f/%.0f resumed=%s"
				% [hold_gear, held, max_ideal, _v.max_rpm, resumed])
	_expect(held, "弯中应保持挡位不升挡", "gear %d -> %d" % [hold_gear, _v.current_gear])
	_expect(max_ideal >= _v.max_rpm * 0.95, "弯中窗口内升挡条件应确实满足（否则测试无效）",
			"max_ideal=%.0f line=%.0f" % [max_ideal, _v.max_rpm * 0.95])
	_expect(resumed, "回正后应恢复升挡", "")

## 换挡表应跟随扭矩曲线：峰值提前回落的曲线，低挡升挡点应明显前移
func _check_curve_adaptive() -> void:
	_setup(601)
	var stock_curve: Curve = _v.torque_curve
	var r := _wheel_radius()
	_v._ensure_shift_schedule()
	var stock: Array[float] = _v._auto_upshift_rpms.duplicate()
	# 换一条峰在 0.6、0.8 后骤降到 0.3 的"馒头曲线"
	var peaky := Curve.new()
	peaky.add_point(Vector2(0.0, 0.5))
	peaky.add_point(Vector2(0.6, 1.0))
	peaky.add_point(Vector2(0.8, 0.3))
	peaky.add_point(Vector2(1.0, 0.25))
	_v.torque_curve = peaky
	_v._ensure_shift_schedule()
	var adaptive: Array[float] = _v._auto_upshift_rpms.duplicate()
	# 还原曲线：_v 是共享实例，污染会串场到后续场景
	_v.torque_curve = stock_curve
	_v._ensure_shift_schedule()
	if not _quiet:
		print("[SHIFTLOGIC] CURVE stock=%s peaky=%s (rpm)"
				% [stock.map(func(x: float) -> int: return roundi(x)), adaptive.map(func(x: float) -> int: return roundi(x))])
	_expect(absf(stock[0] / _v.max_rpm - 0.75) < 0.02, "1 挡用短换挡封顶",
			"stock[0]=%.0f" % stock[0])
	_expect(stock[2] >= _v.max_rpm * 0.94, "原厂曲线 3 挡交点贴红线（封顶 0.95）",
			"stock[2]=%.0f" % stock[2])
	_expect(adaptive[0] < _v.max_rpm * 0.85, "馒头曲线 1 挡升挡点应显著前移",
			"adaptive[0]=%.0f (%.0f%%)" % [adaptive[0], adaptive[0] / _v.max_rpm * 100.0])

## 防振荡：转速贴着踢降/级联边界 + 输入微抖（油门跨阈值、点刹）不得来回换挡
func _check_antihunt() -> void:
	# 场景1：2 挡巡航，降挡后转速（1 挡口径）= 0.70 红线，恰好卡在旧踢降线
	# （0.95×目标挡线=0.779）之下的雷区；油门以 0.5s 周期在 1.0/0.80 间抖动
	# （反复跨过踢降阈值 0.85），车速钉死不动 → 不应发生任何换挡。
	_setup(601)
	var r := _wheel_radius()
	_v.current_gear = 2
	var v_speed := r * (0.70 * _v.max_rpm) / (60.0 / TAU) / _v.get_gear_ratio(1)
	var shifts := 0
	var last_gear := _v.current_gear
	for i in int(round(6.0 / _DT)):
		var throttle := 1.0 if fmod(i * _DT, 1.0) < 0.5 else 0.80
		_sim_step(v_speed, throttle, 0.0, r)   # 车速钉死：只考察决策，不考察动力学
		if _v.current_gear != last_gear:
			shifts += 1
			last_gear = _v.current_gear
	if not _quiet:
		print("[SHIFTLOGIC] ANTIHUNT throttle-wiggle shifts=%d (G2 @prev 0.70 redline)" % shifts)
	_expect(shifts == 0, "油门在踢降阈值附近抖动不得触发换挡", "shifts=%d" % shifts)

	# 场景2：4 挡 45 m/s 巡航，轻点刹（踏板 0.2，不足以武装级联）与回油交替，
	# 6 个周期 → 至多一次升挡、不得降挡（旧逻辑：点刹级联降挡↔回油升挡往复）。
	_setup(601)
	_v.current_gear = 4
	v_speed = 45.0
	var ups := 0
	var downs := 0
	last_gear = _v.current_gear
	for i in int(round(7.2 / _DT)):
		var braking := fmod(i * _DT, 1.2) < 0.4
		var out := _sim_step(v_speed, 0.0 if braking else 0.6, 0.0, r, 2.0 if braking else 0.0)
		v_speed = maxf(20.0, v_speed + out.accel * _DT)
		if _v.current_gear != last_gear:
			if not _quiet:
				print("[SHIFTLOGIC]   feather t=%.1f %d->%d v=%.1f rpm=%.0f" % [i * _DT, last_gear, _v.current_gear, v_speed, _v.motor_rpm])
			if _v.current_gear > last_gear:
				ups += 1
			else:
				downs += 1
			last_gear = _v.current_gear
	if not _quiet:
		print("[SHIFTLOGIC] ANTIHUNT brake-feather ups=%d downs=%d (G4 @45m/s, pedal 0.2)" % [ups, downs])
	_expect(downs == 0, "轻点刹不得触发级联降挡", "downs=%d" % downs)
	_expect(ups <= 1, "点刹往复中至多一次升挡", "ups=%d" % ups)
