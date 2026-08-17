extends Node3D
## 主辅路岔口融合目检:构建 map_1,在每个岔口上方斜俯视截图到 shots/。
## 需窗口模式(headless 无像素):
##   godot --path . res://game/testing/track_junction_shot.tscn
## 核对点:岔口宽度喇叭过渡、路缘处无草缝/台阶、墙体与边线开缺、辅路藏入主路下。

func _ready() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	if data == null:
		print("[SHOT] map_1 加载失败")
		get_tree().quit(1)
		return
	var tb := TrackBuilder.new()
	add_child(tb)
	tb.build(data)
	tb.setup(WeatherEnv.cfg(WeatherEnv.Type.SUNNY))

	var we := WorldEnvironment.new()
	we.environment = WeatherEnv.make_env_cfg(WeatherEnv.cfg(WeatherEnv.Type.SUNNY))
	add_child(we)
	var sun := DirectionalLight3D.new()
	WeatherEnv.setup_light_cfg(sun, WeatherEnv.cfg(WeatherEnv.Type.SUNNY))
	add_child(sun)

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	await get_tree().process_frame

	var dir := "res://game/testing/shots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for i in tb.junctions.size():
		var j: Dictionary = tb.junctions[i]
		var p: Vector3 = data.point_at(float(j["s"]))
		cam.global_position = p + Vector3(0.0, 52.0, 38.0)
		cam.look_at(p, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := dir.path_join("junction_%d.png" % i)
		img.save_png(ProjectSettings.globalize_path(path))
		print("[SHOT] %s -> %s" % [path, img.get_size()])
	get_tree().quit()
