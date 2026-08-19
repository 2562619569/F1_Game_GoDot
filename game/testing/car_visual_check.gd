extends Node3D
## 装配视觉检查：静止摆放带美术装配的车，固定相机截图到 shots/，
## 用于人工/自动化核对车壳与轮毂装配是否正确。
## 602 占位车的 body.json 已标记 materials，另拍刹车 off/on 两张验证刹车灯高亮。

const SHOTS_DIR := "res://game/testing/shots"

func _ready() -> void:
	Match.auto_test = true
	# 环境与展厅同款：明亮极简 + ACES + 辉光 + SSAO + 反射探针
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.82, 0.85, 0.88)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.87, 0.9)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_bloom = 0.1
	env.ssao_enabled = true
	env.ssao_intensity = 1.5
	env.ssao_radius = 0.8
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -35, 0)
	sun.light_color = Color(1.0, 0.98, 0.95)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var probe := ReflectionProbe.new()
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.size = Vector3(20, 10, 20)
	probe.position = Vector3(3, 4, 0)
	probe.box_projection = true
	add_child(probe)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.68, 0.70, 0.73)
	mat.roughness = 0.08
	mat.metallic = 0.2
	ground.material_override = mat
	add_child(ground)

	var v: Vehicle = preload("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	v.position = Vector3(0, 0.5, 0)
	CarBuilder.apply(v, Match.car_cfg(601), Match.get_stats(), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	var assembled := CarMeshBuilder.attach_visual(v, 601)
	add_child(v)
	v.freeze = true
	print("[CHECK] assembled(601)=%s" % assembled)

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true

	await snap(cam, Vector3(3.2, 1.8, 3.2), Vector3(0, 0.45, 0), "car_visual_check.png")

	# 刹车灯：冻结车也照常跑 _physics_process，brake_amount 会向 brake_input 爬升
	var v2: Vehicle = preload("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	v2.position = Vector3(6.0, 0.5, 0)
	CarBuilder.apply(v2, Match.car_cfg(602), Match.get_stats(), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	var assembled2 := CarMeshBuilder.attach_visual(v2, 602)
	add_child(v2)
	v2.freeze = true
	print("[CHECK] assembled(602)=%s" % assembled2)

	await snap(cam, Vector3(8.4, 1.0, 3.0), Vector3(6.0, 0.55, 0.2), "car_brake_off.png")
	v2.brake_input = 1.0
	await get_tree().create_timer(0.8).timeout
	# 刹车灯逻辑校验（headless 也可验证）：brake_amount 已爬满，自发光应接近满刹车亮度
	var bl := v2.get_node_or_null("BodyPivot/BodyRattle/BodyVisual/BrakeLight") as BrakeLight
	print("[CHECK] brake_light=%s" % (bl.debug_info() if bl else "缺失"))
	await snap(cam, Vector3(8.4, 1.0, 3.0), Vector3(6.0, 0.55, 0.2), "car_brake_on.png")
	get_tree().quit()

func _after_draw() -> void:
	# headless 模式 frame_post_draw 不触发会永久挂起，用短定时器兜底（截图为空图，仅窗口模式出真实像素）
	if DisplayServer.get_name() == "headless":
		await get_tree().create_timer(0.1).timeout
	else:
		await RenderingServer.frame_post_draw

func snap(cam: Camera3D, pos: Vector3, look_target: Vector3, file: String) -> void:
	cam.position = pos
	cam.look_at(look_target)
	await get_tree().create_timer(0.3).timeout
	await _after_draw()
	await _after_draw()
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return   # headless 空渲染器无像素，跳过截图（窗口模式正常出图）
	var dir := ProjectSettings.globalize_path(SHOTS_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join(file))
	print("[SHOT] %s -> %s" % [file, dir.path_join(file)])
