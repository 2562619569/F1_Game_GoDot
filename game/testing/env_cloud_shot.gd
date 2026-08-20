extends Node3D
## 体积云天空调试截图：晴天/风暴两种天气各截一张（生产链路 make_env_cfg）。
## 需窗口模式(headless 无像素): godot --path . res://game/testing/env_cloud_shot.tscn
## 核对点: 云形层次/光照方向、天气配色(晴蓝/风暴灰暗)与太阳方向一致、
## 天空不被雾洗白(fog_sky_affect=0)、无 shader 编译错误。
## 注意：天气图云区有方向性，单方向构图可能对准晴区——
## 目检时若某张无云，先转相机角度再下结论。

func _ready() -> void:
	var we := WorldEnvironment.new()
	add_child(we)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 6, 0)

	var dir := "res://game/testing/shots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# 两个朝向：正上方与演示同款朝向（后者是已知云区方向，防"晴区假阴性"）
	var shots := [
		["cloud_sunny", "sunny", -60.0, 0.0],
		["cloud_sunny_e", "sunny", -25.0, 210.0],
		["cloud_storm", "storm", -60.0, 0.0],
		["cloud_storm_e", "storm", -25.0, 210.0],
	]
	for shot in shots:
		var env_cfg := WeatherEnv.resolve({"preset": shot[1]})
		WeatherEnv.setup_light_cfg(sun, env_cfg)
		we.environment = WeatherEnv.make_env_cfg(env_cfg, {
			"enabled": true, "coverage": 0.3, "density": 0.055, "wind": 2.5, "offset": 137.0})
		cam.rotation_degrees = Vector3(shot[2], shot[3], 0.0)
		for i in 20:   # 等天空辐照度 cubemap 增量更新
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := dir.path_join("%s.png" % shot[0])
		img.save_png(ProjectSettings.globalize_path(path))
		print("[SHOT] %s -> %s" % [path, img.get_size()])
	get_tree().quit()
