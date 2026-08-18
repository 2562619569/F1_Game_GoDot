extends Node3D
## 主辅路岔口融合 + 发卡弯护栏目检:构建 map_1,岔口/急弯上方斜俯视截图到 shots/。
## 需窗口模式(headless 无像素):
##   godot --path . res://game/testing/track_junction_shot.tscn
## 核对点:岔口宽度喇叭过渡、路缘处无草缝/台阶、护栏与边线开缺、辅路藏入主路下;
## 发卡弯护栏按远端路面走廊收紧、汇合弯心不放墙、砂石路肩贴边不盖路面。

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
	var env := WeatherEnv.make_env_cfg(WeatherEnv.cfg(WeatherEnv.Type.SUNNY))
	env.fog_enabled = false  # 几何目检关雾,远端路面/护栏颜色不被洗白
	we.environment = env
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
		await _shot(cam, dir, "junction_%d" % i, data.point_at(float(j["s"])))

	# 发卡弯(半径 <20m)去重后逐个俯拍
	var radii: PackedFloat32Array = data.main["radii"]
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var hairpins: Array = []
	var last_s := -1e9
	for i in radii.size():
		if float(radii[i]) < 20.0 and float(s_arr[i]) - last_s > 80.0:
			hairpins.append(float(s_arr[i]))
			last_s = float(s_arr[i])
	for i in hairpins.size():
		await _shot(cam, dir, "hairpin_%d" % i, data.point_at(hairpins[i]))
	get_tree().quit()

func _shot(cam: Camera3D, dir: String, name: String, p: Vector3) -> void:
	cam.global_position = p + Vector3(0.0, 52.0, 38.0)
	cam.look_at(p, Vector3.UP)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := dir.path_join("%s.png" % name)
	img.save_png(ProjectSettings.globalize_path(path))
	print("[SHOT] %s -> %s" % [path, img.get_size()])
