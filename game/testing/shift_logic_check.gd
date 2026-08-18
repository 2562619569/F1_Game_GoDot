extends SceneTree
## 自动换挡决策自检（godot --headless -s 运行，不依赖 autoload）：
## 用简化纵向动力学（引擎扭矩 − 风阻 − 滚阻 − 坡度）驱动真实 process_transmission()，
## 验证三类场景下换挡决策不会"卡挡"：
## 1. 平地全油门：每一挡（含末前一挡）都能及时升挡，不允许长时间"加速停滞且不换挡"
##    —— 尤其 601 的 5 挡阻力平衡点贴在红线下方，">max_rpm" 严格比较永远不满足；
## 2. 部分油门巡航：升挡点应随油门深度前移（小油门早升挡），不 dragged 到红线才换；
## 3. 巡航中突然地板油：应触发 kickdown 降挡（在降挡后不超转的前提下）。
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

## 单步纵向仿真。返回 {accel=…, prev_gear_rpm=…}（换挡决策所用口径）
func _sim_step(v_speed: float, throttle: float, grade: float, r: float) -> Dictionary:
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
	_v.throttle_input = throttle
	_v.throttle_amount = throttle    # 稳态油门（process_throttle 平滑后的口径）
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
	var accel := (force - drag - rr - _v.vehicle_mass * _G * grade) / _v.vehicle_mass
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
			events.append({
				"t": i * _DT, "gear": _v.current_gear,
				"speed": v_speed, "rpm": _v.motor_rpm,
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
