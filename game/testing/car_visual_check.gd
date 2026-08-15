extends Node3D
## 装配视觉检查：静止摆放一辆带美术装配的车，固定相机截图到 shots/，
## 用于人工/自动化核对车壳与轮毂装配是否正确。

func _ready() -> void:
	Match.auto_test = true
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.17, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 1.0
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -35, 0)
	add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.34, 0.38)
	ground.material_override = mat
	add_child(ground)

	var v: Vehicle = preload("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	v.position = Vector3(0, 0.5, 0)
	CarBuilder.apply(v, Match.car_cfg(601), Match.get_stats(), "sunny", 1.0)
	var assembled := CarMeshBuilder.attach_visual(v, 601)
	add_child(v)
	v.freeze = true
	print("[CHECK] assembled=%s" % assembled)

	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(3.2, 1.8, 3.2)
	cam.look_at(Vector3(0, 0.45, 0))
	cam.current = true

	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://game/testing/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("car_visual_check.png"))
	print("[SHOT] car_visual_check -> %s" % dir.path_join("car_visual_check.png"))
	get_tree().quit()
