extends Node3D
## 车轮印渲染目检+像素断言（需窗口模式，headless 无像素）：
##   godot --path . res://game/testing/skid_visual_check.tscn
## 平地路面上跑两段真实物理工况，把组件 journal 里的落段中点投影到屏幕，
## 断言对应像素显著暗于旁侧无印地面（旁侧参考 = 落段点沿行进法线偏 6m）——
## 整条链路（滑移检测→实例写入→shader→淡出→屏幕像素）的端到端验证，
## 不依赖 get_instance_transform（该回读 API 在 4.7.1 构建上恒返回单位变换，
## 不可用作断言依据）。截图存 shots/ 供人工目检。退出码 0/1。

const SKID := preload("res://game/car/skid_marks.gd")
const LATERAL_CLEAR := 6.0   # 旁侧参考点离车辙的横向距离（m，避开印迹）
const DARK_RATIO := 0.93     # 落段像素亮度须低于旁侧地面的 93%
const PASS_RATE := 0.7       # 采样点中达标的最低比例

var _v: Vehicle
var _cam: Camera3D
var _fails := 0

func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(300, 1, 300)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)
	# 视觉地面（CollisionShape 无网格，上面片没有参照物也无从对比）
	var gmesh := MeshInstance3D.new()
	var gbox := BoxMesh.new()
	gbox.size = Vector3(300, 1, 300)
	gmesh.mesh = gbox
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.42, 0.44, 0.47)
	gmesh.material_override = gmat
	gmesh.position = Vector3(0, -0.5, 0)
	add_child(gmesh)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.65, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.75, 0.8)
	env.ambient_light_energy = 1.0
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.0
	add_child(sun)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true

	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach(_v, "601", "sport_v1", "stock_v1")
	_v.position = Vector3(0, 0.6, 50)
	add_child(_v)
	var skid := SKID.new()
	skid.name = "SkidMarks"
	_v.add_child(skid)
	skid.setup(_v, {})
	skid.track_emissions = true
	_v.can_sleep = false
	_run()

func _skid() -> Node:
	return _v.get_node("SkidMarks")

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _reset(speed: float, pos: Vector3) -> void:
	_v.global_position = pos
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
	_v.handbrake_input = 0.0
	_v.steering_input = 0.0
	_v.motor_rpm = _v.max_rpm * 0.55

## 相机就位→等两帧绘制→返回视口图像（并存档）
func _frame(name: String, from: Vector3, at: Vector3) -> Image:
	_cam.global_position = from
	_cam.look_at(at, Vector3.UP)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := "res://game/testing/shots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join("%s.png" % name)
	img.save_png(ProjectSettings.globalize_path(path))
	print("[SKIDVIS] %s -> %s" % [path, img.get_size()])
	return img

## 像素断言：journal 每个落段中点投影处取 5x5 最暗像素，与旁侧 LATERAL_CLEAR
## 米处地面亮度对比；车体附近的段（投影进车身像素）跳过
func _assert_darker(img: Image, label: String, skip_near_car: Vector3) -> void:
	var emissions: Array[Dictionary] = _skid().emissions
	var hits := 0
	var sampled := 0
	var skip_car := 0
	var skip_behind := 0
	for i in emissions.size():
		if i % 3 != 0:  # 采样降频（每 3 段取 1）
			continue
		var e := emissions[i]
		var mid := ((e.p0 as Vector3) + (e.p1 as Vector3)) * 0.5
		if mid.distance_to(skip_near_car) < 6.0:
			skip_car += 1
			continue
		if _cam.is_position_behind(mid):
			skip_behind += 1
			continue
		# 旁侧参考：沿段方向的法线偏移（地面上的无印区）
		var seg_dir := (e.p1 as Vector3 - e.p0 as Vector3).normalized()
		var side := seg_dir.cross(Vector3.UP).normalized()
		var ref_p := mid + side * LATERAL_CLEAR
		if _cam.is_position_behind(ref_p):
			ref_p = mid - side * LATERAL_CLEAR
		var sp := _cam.unproject_position(mid)
		var rp := _cam.unproject_position(ref_p)
		# 出屏/出图的样本按跳过处理（取景没盖到 ≠ 没渲染）
		if not _in_frame(img, sp) or not _in_frame(img, rp):
			continue
		var mark_lum := _min_lum(img, sp)
		var ref_lum := _avg_lum(img, rp)
		sampled += 1
		if ref_lum > 0.0 and mark_lum < ref_lum * DARK_RATIO:
			hits += 1
		elif sampled - hits <= 8:  # 失败样本明细（前 8 个）
			print("[SKIDVIS]   未达标样本 mid=%s sp=(%.0f,%.0f) mark=%.3f ref=%.3f"
					% [mid, sp.x, sp.y, mark_lum, ref_lum])
	var rate := float(hits) / maxf(sampled, 1)
	print("[SKIDVIS] %s：落段像素暗于旁侧地面 %d/%d（%.0f%%，需 ≥%.0f%%）跳过=近车%d/背向%d"
			% [label, hits, sampled, rate * 100, PASS_RATE * 100, skip_car, skip_behind])
	if not (sampled > 0 and rate >= PASS_RATE):
		_fails += 1
		print("[SKIDVIS] FAIL %s（像素断言未达标）" % label)

func _in_frame(img: Image, sp: Vector2) -> bool:
	return sp.x >= 4 and sp.y >= 4 and sp.x < img.get_width() - 4 and sp.y < img.get_height() - 4

func _min_lum(img: Image, sp: Vector2) -> float:
	var best := 1.0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var x := int(sp.x) + dx
			var y := int(sp.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				return 1.0  # 出屏该样本作废（返回极值使其不计入达标）
			best = minf(best, img.get_pixel(x, y).get_luminance())
	return best

func _avg_lum(img: Image, sp: Vector2) -> float:
	var sum := 0.0
	var n := 0
	for dy in range(-4, 5, 2):
		for dx in range(-4, 5, 2):
			var x := int(sp.x) + dx
			var y := int(sp.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				return 0.0
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(n, 1)

func _expect(cond: bool, label: String) -> void:
	if cond:
		print("[SKIDVIS] OK   %s" % label)
	else:
		_fails += 1
		print("[SKIDVIS] FAIL %s" % label)

func _run() -> void:
	await _frames(120)  # 落地静置

	# ---- 段 1：重刹拖印（26 m/s 直线重刹） ----
	_reset(26.0, Vector3(0, 0.6, 40))
	_v.clutch_input = 0.0
	_v.throttle_input = 0.5
	await _frames(40)
	_v.throttle_input = 0.0
	_v.brake_input = 1.0
	await _frames(150)
	_v.brake_input = 0.0
	await _frames(20)
	var stop := _v.global_position
	var w1: int = _skid().debug_state().written
	print("[SKIDVIS] 刹车段落段 written=%d" % w1)
	_expect(w1 > 30, "重刹抱死落印（>30 段）")
	var img1 := await _frame("skid_brake_top", stop + Vector3(0, 18, 12), stop)
	_assert_darker(img1, "刹车拖印", stop)
	_skid().emissions.clear()  # 段 2 重新从零统计

	# ---- 段 2：漂移画圈（满舵手刹持续滑） ----
	_reset(20.0, Vector3(0, 0.6, -10))
	_v.clutch_input = 0.0
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	_v.throttle_input = 0.35
	await _frames(200)  # ~1.7s
	var car := _v.global_position
	var w2: int = _skid().debug_state().written
	print("[SKIDVIS] 漂移段落段 written=%d" % w2)
	_expect(w2 - w1 > 50, "漂移侧滑落印（>50 段）")
	var img2 := await _frame("skid_drift_top", car + Vector3(0, 22, 10), car)
	_assert_darker(img2, "漂移车辙", car)

	print("[SKIDVIS] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)
