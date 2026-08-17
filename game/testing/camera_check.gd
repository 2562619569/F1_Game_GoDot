extends SceneTree
## Pro Vehicle Camera（+smooth_chase_camera 旋转低通）自检：
## godot --headless -s game/testing/camera_check.gd 运行
## 1. 匀速直线（20 m/s，-Z 前进）：相机悬在车后（+Z 侧），高度≈follow_height；
## 2. 动态 FOV：中速抬升、高速逼近 maximum_fov；
## 3. look_back 动作：相机甩到车头侧，松开回到车尾侧；
## 4. trigger_shake：震屏计时器启动且不报错；
## 5. 转向方波（模拟键盘 A/D 阶跃）+ 急甩头：相机逐帧姿态变化被低通压住，
##    且静置后视线仍收敛于车身（平滑不牺牲跟随）。
## 目标用冻结刚体（可设 linear_velocity/steering），physics_frame 回调晚于
## 相机 _physics_process，故用 call_deferred 对齐"刚体先动、相机后读"的真实时序。

var checks := 0
var failures := 0
var target: RigidBody3D
var cam: Camera3D
var tick := 0
var delta_p := 1.0 / 60.0

var _v_speed := 20.0
var _yaw_rate := 0.0
var _steer := 0.0

var _last_roll := 0.0
var _last_fwd := Vector3.FORWARD
var _have_meas := false
var max_roll_step := 0.0
var max_fwd_step := 0.0

func _init() -> void:
	delta_p = 1.0 / float(Engine.physics_ticks_per_second)
	target = RigidBody3D.new()
	target.freeze = true   # 冻结：位置/朝向由探针驱动，linear_velocity 手填
	var ts := GDScript.new()   # 挂 steering 属性以触发上游过弯侧倾分支
	ts.source_code = "extends RigidBody3D\nvar steering := 0.0\n"
	ts.reload()
	target.set_script(ts)
	root.add_child(target)
	cam = load("res://game/race/smooth_chase_camera.gd").new()
	cam.follow_this = target
	cam.follow_distance = 6.5
	cam.follow_height = 2.6
	cam.speed = 20.0
	root.add_child(cam)
	if not InputMap.has_action("look_back"):
		InputMap.add_action("look_back")
	physics_frame.connect(_on_phys)

func ok(cond : bool, label : String) -> void:
	checks += 1
	if cond:
		print("[CAM ] OK   | %s" % label)
	else:
		failures += 1
		print("[CAM ] FAIL | %s" % label)

func horiz_dist() -> float:
	var v := cam.global_position - target.global_position
	v.y = 0.0
	return v.length()

func _on_phys() -> void:
	# ---- 阶段编排 ----
	_v_speed = 40.0 if tick >= 252 and tick < 380 else 20.0
	_yaw_rate = 2.5 if tick >= 460 and tick < 520 else 0.0
	_steer = 1.0 if tick >= 400 and tick < 430 else 0.0
	_move.call_deferred()

	# ---- 1. 直线匀速 ----
	if tick == 120:
		ok(cam.global_position.z > target.global_position.z, "camera trails behind car (+Z side)")
		var d := horiz_dist()
		ok(d > 5.0 and d < 9.5, "follow distance ≈ %.2f (6.5 + motion lag)" % d)
		ok(absf(cam.global_position.y - target.global_position.y - 2.6) < 0.3,
				"camera height ≈ %.2f (want 2.6)" % (cam.global_position.y - target.global_position.y))
		ok(cam.fov > 74.0, "dynamic FOV at 20 m/s (%.1f, want ≈77.5)" % cam.fov)

	# ---- 2. look_back ----
	if tick == 130:
		Input.action_press("look_back")
	if tick == 250:
		ok(cam.global_position.z < target.global_position.z, "look_back swings camera to front (-Z side)")
		var d := horiz_dist()
		ok(d > 4.0 and d < 11.0, "look_back keeps distance sane (%.2f)" % d)
		Input.action_release("look_back")

	# ---- 3. 高速回位 + FOV ----
	if tick == 370:
		ok(cam.global_position.z > target.global_position.z, "camera returns behind after look_back")
		ok(cam.fov > 80.0, "FOV near max at 40 m/s (%.1f, want ≈85)" % cam.fov)

	# ---- 4. 震屏 ----
	if tick == 380:
		cam.trigger_shake(0.3, 0.15)
	if tick == 381:
		ok(cam._shake_timer > 0.0, "trigger_shake starts shake timer")

	# ---- 5. 平滑性测量：转向方波 + 急甩头（跳过震屏期） ----
	if tick >= 400 and tick <= 549:
		var fwd := -cam.global_transform.basis.z
		var roll := cam.global_transform.basis.get_euler().z
		if _have_meas:
			max_roll_step = maxf(max_roll_step, absf(roll - _last_roll))
			max_fwd_step = maxf(max_fwd_step, _last_fwd.angle_to(fwd))
		_last_roll = roll
		_last_fwd = fwd
		_have_meas = true
	if tick == 550:
		ok(max_roll_step < 0.005, "banking roll low-passed: max Δroll/tick %.4f rad (<0.005, 无低通时≈0.017)" % max_roll_step)
		ok(max_fwd_step < 0.06, "yaw whip low-passed: max Δfwd/tick %.4f rad (<0.06)" % max_fwd_step)

	# ---- 6. 平滑不牺牲跟随：静置后视线收敛于车身 ----
	if tick == 555:
		var dir := (target.global_position - cam.global_position).normalized()
		var aim := -cam.global_transform.basis.z
		ok(dir.angle_to(aim) < 0.2, "camera still aims at car after settle (%.3f rad)" % dir.angle_to(aim))
		print("========== CAMERA CHECK: %d checks, %d failures ==========" % [checks, failures])
		quit(1 if failures > 0 else 0)

	tick += 1

func _move() -> void:
	if _yaw_rate != 0.0:
		target.global_rotation.y += _yaw_rate * delta_p
	target.global_position += -target.global_transform.basis.z * _v_speed * delta_p
	target.linear_velocity = -target.global_transform.basis.z * _v_speed
	target.steering = _steer
