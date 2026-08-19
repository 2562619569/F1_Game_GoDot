extends Node3D
## headless 自检：准备期（frozen）轰油门拉转速 + GO 弹射起步（player_car 冻结分支）。
## 运行：godot --headless --path . res://game/testing/launch_check.tscn
## 覆盖：
##  1. 冻结期踩油门：motor_rpm 自由拉进红线区（离合分离空踩，扭矩不落地）；
##  2. 冻结期锁车：手刹+刹车下水平位移/车速近零，不偷跑；
##  3. GO 抬离合：clutch_input 归零、挂上前进挡，预拉转速落挡弹射；
##  4. 弹射收益：同点同车，预拉转速起步 2s 车速显著高于怠速起步对照；
##  5. 对照组冻结期不踩油门时转速维持怠速（无 creep）。
## 用 Input.action_press 模拟键盘油门（headless 可用），车走真实 PlayerCar 输入链。

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const PLAYER_SCRIPT := preload("res://game/car/player_car.gd")
const CAR_ID := 601
const PREP_SEC := 3.0   # 与 Game 表 start_countdown 一致的准备时长
const RUN_SEC := 2.0    # GO 后统一计时对比两车车速

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[LAUNCH] OK   | %s" % label)
	else:
		failures += 1
		print("[LAUNCH] FAIL | %s" % label)

func _ready() -> void:
	print("========== LAUNCH CHECK ==========")
	Match.auto_test = false
	var track := preload("res://game/race/tracks/track_test.tscn").instantiate()
	add_child(track)
	track.setup(WeatherEnv.cfg(WeatherEnv.Type.SUNNY))
	await get_tree().physics_frame

	# --- A：准备期轰油门 → GO 弹射 ---
	var a: Dictionary = _spawn_car()
	var av: Vehicle = a["v"]
	await _wait_ready(av)
	await _sim(0.5)   # 悬挂沉降静置
	var start_pos: Vector3 = av.global_position

	Input.action_press("Throttle")
	var max_rpm := 0.0
	var t := 0.0
	while t < PREP_SEC:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		max_rpm = maxf(max_rpm, av.motor_rpm)
	var disp := ((av.global_position - start_pos) * Vector3(1, 0, 1)).length()
	var prep_speed: float = av.linear_velocity.length()
	ok(max_rpm >= av.max_rpm * 0.75, "准备期踩油门把转速拉进红线区（peak %.0f / max %.0f）" % [max_rpm, av.max_rpm])
	ok(disp < 0.6, "准备期锁车不偷跑（水平位移 %.2fm）" % disp)
	ok(prep_speed < 1.2, "准备期车速近零（%.2f m/s）" % prep_speed)
	ok(av.clutch_input == 1.0, "准备期离合保持分离（空踩油门扭矩不落地）")

	a["ctrl"].frozen = false   # GO
	await _sim(0.1)
	ok(av.clutch_input == 0.0, "GO 抬离合（clutch_input 归零）")
	ok(av.current_gear >= 1, "GO 在前进挡上（gear=%d）" % av.current_gear)
	await _sim(RUN_SEC - 0.1)
	var speed_a: float = av.speed
	ok(speed_a >= 9.0, "预拉转速弹射 %.1fs 后车速 ≥ 9 m/s（实测 %.1f m/s / %.0f km/h）"
			% [RUN_SEC, speed_a, speed_a * 3.6])
	Input.action_release("Throttle")
	(a["root"] as Node3D).queue_free()
	await _sim(0.2)

	# --- B：对照组，怠速起步（GO 时刻才踩油门） ---
	var b: Dictionary = _spawn_car()
	var bv: Vehicle = b["v"]
	await _wait_ready(bv)
	await _sim(0.5)
	var idle_peak := 0.0
	t = 0.0
	while t < PREP_SEC:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		idle_peak = maxf(idle_peak, bv.motor_rpm)
	ok(idle_peak < bv.idle_rpm + 600.0, "对照组准备期维持怠速（peak %.0f）" % idle_peak)

	Input.action_press("Throttle")
	b["ctrl"].frozen = false   # GO
	await _sim(RUN_SEC)
	var speed_b: float = bv.speed
	ok(speed_a > speed_b + 1.5, "弹射收益：预拉转速 %.1f m/s > 怠速起步 %.1f m/s（+%.1f m/s）"
			% [speed_a, speed_b, speed_a - speed_b])
	Input.action_release("Throttle")
	(b["root"] as Node3D).queue_free()

	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[LAUNCH] %s (fails=%d)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)

func _spawn_car() -> Dictionary:
	var root := Node3D.new()
	root.position = Vector3(0, 0, -6)
	var v: Vehicle = CAR_SCENE.instantiate()
	v.position = Vector3(0, 0.95, 0)
	CarBuilder.apply(v, Match.car_cfg(CAR_ID), Match.get_stats(), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	root.add_child(v)
	add_child(root)
	var ctrl := Node3D.new()
	ctrl.set_script(PLAYER_SCRIPT)   # 入树前附加，否则 _physics_process 不启用
	root.add_child(ctrl)
	ctrl.setup(v, null)
	v.add_to_group("player_car")
	return {"root": root, "v": v, "ctrl": ctrl}

func _wait_ready(v: Vehicle) -> void:
	var t := 0.0
	while not v.is_ready and t < 3.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()

func _sim(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
