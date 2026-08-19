extends SceneTree
## Pro Vehicle Camera（+smooth_chase_camera 旋转低通/视角模式/环视/震动源）自检：
## godot --headless -s game/testing/camera_check.gd 运行
## 1. 匀速直线（20 m/s，-Z 前进）：相机悬在车后（+Z 侧），高度≈follow_height；
## 2. 动态 FOV：中速抬升、高速逼近 maximum_fov；
## 3. look_back 动作：相机甩到车头侧，松开回到车尾侧；
## 4. impact_kick（Shaker 方向性脉冲）：幅度有上限、按严重度延长，沿撞击方向
##    快速甩出后小幅反弹并回落；
## 5. 转向方波（模拟键盘 A/D 阶跃）+ 急甩头：相机逐帧姿态变化被低通压住，
##    且静置后视线仍收敛于车身（平滑不牺牲跟随）；
## 6. 视角模式：cycle 到追尾近参数按比例收紧；引擎盖/保险杠刚性锚定车身
##    （车前/高于原点/偏移量精确等于锚点长度/视线随车头、look_back 后翻），
##    保险杠锚点比引擎盖更靠前更低；切回追尾远恢复基准参数；
## 7. 环视：orbit_look 侧向甩头后相机横移到车身侧，松手指数回正归零；
## 8. 持续震动源：巡航(20 m/s)三源全零；高速/重刹/侧滑三路各有正确主轴，
##    且缓入后的强度写入 Brownian 幅度、哑元上产生实际偏移；
## 9. 震动总开关：shake_enabled=false 时持续源幅度归零、impact_kick 被忽略。
## 目标用冻结刚体（可设 linear_velocity/steering/brake_input/local_velocity），
## physics_frame 回调晚于相机 _physics_process，故用 call_deferred 对齐
## "刚体先动、相机后读"的真实时序。探针无视觉网格，刚性锚点走回退车盒。
## 注意：转向方波阶段后车体残余偏航 ~1.25 rad，后续断言一律在车身空间做。

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
var _kick_dir := Vector3.ZERO
var _kick_peak := 0.0

func _init() -> void:
	delta_p = 1.0 / float(Engine.physics_ticks_per_second)
	target = RigidBody3D.new()
	target.freeze = true   # 冻结：位置/朝向由探针驱动，linear_velocity 手填
	var ts := GDScript.new()   # 挂 steering/brake_input/local_velocity 驱动侧倾与震动源
	ts.source_code = "extends RigidBody3D\nvar steering := 0.0\nvar brake_input := 0.0\nvar local_velocity := Vector3.ZERO\n"
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

## 相机位置在车身空间的坐标（x 右 / y 上 / z 车后）
func cam_local() -> Vector3:
	return target.global_transform.basis.inverse() * (cam.global_position - target.global_position)

func cam_view_dir() -> Vector3:
	return -cam.global_transform.basis.z

func _on_phys() -> void:
	# ---- 阶段编排 ----
	_v_speed = 45.0 if tick >= 945 else (40.0 if tick >= 252 and tick < 380 else 20.0)
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

	# ---- 4. 碰撞脉冲（Shaker 方向性 kick）。先核对正式参数的量级/时长，
	# 再把测试时长压到 0.12s；headless 中组件 timer 约半速推进，确保在 400
	# 起的平滑测量窗口前结束 ----
	if tick == 372:
		ok(cam.kick_position_max <= 0.08 and cam.kick_position_min >= 0.004,
				"impact displacement bounded (%.3f..%.3f m)" % [cam.kick_position_min, cam.kick_position_max])
		ok(cam.kick_duration_min >= 0.24 and cam.kick_duration_max >= 0.40,
				"impact recovery lasts by severity (%.2f..%.2f s)" % [cam.kick_duration_min, cam.kick_duration_max])
		cam.kick_duration_min = 0.12
		cam.kick_duration_max = 0.12
		_kick_dir = Vector3(0.5, 0.1, 0.8).normalized()
		cam.impact_kick(_kick_dir, 0.3)
		ok(cam._shaker._external_shakes.size() == 1,
				"impact queues one overriding pulse")
	if tick >= 372 and tick < 398:
		var local_kick_dir := (cam.global_transform.basis.inverse() * _kick_dir).normalized()
		_kick_peak = maxf(_kick_peak, cam._shake_target.position.dot(local_kick_dir))
	if tick == 398:
		ok(_kick_peak > 0.005 and _kick_peak < 0.05,
				"impact kick is directional and restrained (peak %.3f m)" % _kick_peak)
		ok(cam._shake_target.position.length() < 0.003,
				"impact kick decays to zero (%.4f m)" % cam._shake_target.position.length())

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

	# ---- 7. 视角模式：追尾近 → 引擎盖 → 保险杠 → 追尾远 ----
	if tick == 560:
		cam.cycle_view()
		ok(cam.view_mode == cam.ViewMode.CHASE_NEAR, "cycle_view: CHASE_FAR → CHASE_NEAR")
		ok(absf(cam.follow_distance - 6.5 * 0.72) < 0.01 and absf(cam.follow_height - 2.6 * 0.8) < 0.01,
				"CHASE_NEAR scales distance/height (%.2f/%.2f)" % [cam.follow_distance, cam.follow_height])
	if tick == 600:
		cam.cycle_view()
		ok(cam.view_mode == cam.ViewMode.HOOD, "cycle_view: CHASE_NEAR → HOOD")
		ok(cam._rigid_anchor.y > 0.5 and cam._rigid_anchor.z < -0.5,
				"hood anchor above origin & front half (%s)" % cam._rigid_anchor)
		var anchor_len: float = cam._rigid_anchor.length()
		ok(anchor_len > 0.8, "fallback box gives sane hood anchor (%.2f m)" % anchor_len)
	if tick == 640:
		var rel := cam.global_position - target.global_position
		var fwd := -target.global_transform.basis.z
		ok(rel.dot(fwd) > 0.5, "hood cam rides in front of car (%.2f m along fwd)" % rel.dot(fwd))
		ok(cam_local().y > 0.5, "hood cam above car origin (%.2f m)" % cam_local().y)
		ok(cam_view_dir().angle_to(fwd) < 0.15,
				"hood cam looks along car forward (%.3f rad)" % cam_view_dir().angle_to(fwd))
		# 相机帧读的是上一次 _move 后的车位（一帧滞后），对齐后再比锚点长度
		var car_prev := target.global_position - target.linear_velocity * delta_p
		var off := (cam.global_position - car_prev).length()
		ok(absf(off - cam._rigid_anchor.length()) < 1e-3,
				"hood cam rigidly anchored (offset %.4f == anchor %.4f)" % [off, cam._rigid_anchor.length()])
	if tick == 650:
		var hood_anchor: Vector3 = cam._rigid_anchor
		cam.cycle_view()
		ok(cam.view_mode == cam.ViewMode.BUMPER, "cycle_view: HOOD → BUMPER")
		ok(cam._rigid_anchor.z < hood_anchor.z and cam._rigid_anchor.y < hood_anchor.y,
				"bumper anchor farther forward & lower than hood (%s vs %s)" % [cam._rigid_anchor, hood_anchor])
	if tick == 660:
		Input.action_press("look_back")
	if tick == 690:
		var back := target.global_transform.basis.z
		ok(cam_view_dir().angle_to(back) < 0.2,
				"look_back flips rigid view backward (%.3f rad)" % cam_view_dir().angle_to(back))
		Input.action_release("look_back")
		cam.cycle_view()   # BUMPER → CHASE_FAR
	if tick == 740:
		ok(absf(cam.follow_distance - 6.5) < 0.01 and absf(cam.follow_height - 2.6) < 0.01,
				"cycle back to CHASE_FAR restores base params (%.2f/%.2f)" % [cam.follow_distance, cam.follow_height])
	if tick == 795:
		ok(cam_local().z > 3.0, "camera recovers behind car after cycle (%.2f m)" % cam_local().z)

	# ---- 8. 环视与回正 ----
	if tick == 800:
		cam.orbit_look(1.5, 0.3)
		ok(absf(cam.orbit_yaw + 1.5) < 1e-3 and absf(cam.orbit_pitch - 0.3) < 1e-3,
				"orbit_look applies yaw/pitch (%.2f/%.2f)" % [cam.orbit_yaw, cam.orbit_pitch])
	if tick == 820:
		ok(absf(cam_local().x) > 3.0, "orbit swings camera to car side (%.2f m lateral)" % cam_local().x)
		ok(cam.orbit_yaw < -0.4 and cam.orbit_yaw > -1.4,
				"orbit holds while untouched, decays gently (%.2f)" % cam.orbit_yaw)
	if tick == 935:
		ok(absf(cam.orbit_yaw) < 0.05 and absf(cam.orbit_pitch) < 0.02,
				"orbit springs back to zero (%.4f/%.4f)" % [cam.orbit_yaw, cam.orbit_pitch])
		ok(cam_local().z > 3.0, "camera back behind car after orbit (%.2f m)" % cam_local().z)

	# ---- 9. 持续震动源 ----
	if tick == 945:
		ok(cam._continuous_shake_intensity() == 0.0, "cruise 20 m/s: no continuous shake")
		target.brake_input = 1.0
		target.local_velocity = Vector3(6.0, 0.0, -20.0)
		var sources: Vector3 = cam._continuous_shake_sources()
		ok(sources.x == 0.0 and sources.y > 0.0 and sources.z > 0.0,
				"brake+drift remain separate sources (%s)" % sources)
		var brake_pos: Vector3 = cam._rumble_position_amplitude(Vector3(0.0, sources.y, 0.0))
		var brake_rot: Vector3 = cam._rumble_rotation_amplitude(Vector3(0.0, sources.y, 0.0))
		ok(brake_pos.y > brake_pos.x and brake_rot.x > brake_rot.z,
				"brake rumble favors vertical motion and pitch")
		var drift_pos: Vector3 = cam._rumble_position_amplitude(Vector3(0.0, 0.0, sources.z))
		var drift_rot: Vector3 = cam._rumble_rotation_amplitude(Vector3(0.0, 0.0, sources.z))
		ok(drift_pos.x > drift_pos.y and drift_rot.z > drift_rot.x,
				"drift rumble favors lateral motion and roll")
		target.brake_input = 0.0
		target.local_velocity = Vector3.ZERO
	if tick == 950:
		var speed_sources: Vector3 = cam._continuous_shake_sources()
		ok(speed_sources.x > 0.002 and speed_sources.x <= 0.004
				and speed_sources.y == 0.0 and speed_sources.z == 0.0,
				"high speed road rumble stays subtle (%s)" % speed_sources)
		ok(cam._rumble_pos.amplitude.y > cam._rumble_pos.amplitude.x
				and cam._rumble_pos.amplitude.length() < 0.005,
				"road texture favors vertical motion after easing (%s)" % cam._rumble_pos.amplitude)
		ok(cam._shake_target.position.length() > 1e-6,
				"brownian rumble reaches shake target (%.4f m)" % cam._shake_target.position.length())

	# ---- 10. 震动总开关 ----
	if tick == 960:
		cam.set_view(cam.ViewMode.HOOD)
		cam.shake_enabled = false
		target.brake_input = 1.0
		target.local_velocity = Vector3(6.0, 0.0, -20.0)
	if tick == 965:
		var car_prev := target.global_position - target.linear_velocity * delta_p
		var off := (cam.global_position - car_prev).length()
		ok(absf(off - cam._rigid_anchor.length()) < 1e-3,
				"shake off: rigid cam stays exactly on anchor (%.6f)" % off)
		# 门控断言：impact_kick 被 shake_enabled 直接拒绝，不产生外挂震动
		cam.impact_kick(Vector3.RIGHT, 0.3)
		ok(cam._shaker._external_shakes.is_empty(),
				"shake off: impact_kick ignored (no external queued)")
	if tick == 969:
		ok(cam._shake_target.position.length() < 1e-6,
				"shake off: shake target stays zero (%.7f)" % cam._shake_target.position.length())
		cam.shake_enabled = true
		target.brake_input = 0.0
		target.local_velocity = Vector3.ZERO

	if tick == 970:
		print("========== CAMERA CHECK: %d checks, %d failures ==========" % [checks, failures])
		quit(1 if failures > 0 else 0)

	tick += 1

func _move() -> void:
	if _yaw_rate != 0.0:
		target.global_rotation.y += _yaw_rate * delta_p
	target.global_position += -target.global_transform.basis.z * _v_speed * delta_p
	target.linear_velocity = -target.global_transform.basis.z * _v_speed
	target.steering = _steer
