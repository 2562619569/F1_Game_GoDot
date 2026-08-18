extends SceneTree
## 临时校验：WeatherEnv env 文件合成/序列化/回退。运行：
## godot --headless --path . -s res://game/testing/env_check.gd

var failures := 0

func ok(cond: bool, label: String) -> void:
	if cond:
		print("[ENV] OK   | %s" % label)
	else:
		failures += 1
		print("[ENV] FAIL | %s" % label)

func _init() -> void:
	# 预设默认
	var c1 := WeatherEnv.resolve({})
	ok(String(c1.preset) == "sunny", "空 env 回退 sunny")
	ok(absf(float(c1.energy) - 1.3) < 0.01, "sunny 默认太阳强度 1.3")

	# 覆盖 + 未知预设回退
	var c2 := WeatherEnv.resolve({"preset": "storm", "energy": 0.5, "fog_density": 0.009, "sky_top": [0.1, 0.2, 0.3]})
	ok(absf(float(c2.energy) - 0.5) < 1e-6, "覆盖太阳强度")
	ok(absf(float(c2.fog_density) - 0.009) < 1e-9, "覆盖雾密度")
	ok(c2.sky_top is Color and absf(c2.sky_top.r - 0.1) < 1e-6, "JSON 数组转 Color")
	ok(bool(c2.wet) == true, "storm 预设湿滑标记带出")
	ok(String(c2.label) == "Storm", "label 随预设")
	var c3 := WeatherEnv.resolve({"preset": "不存在的"})
	ok(String(c3.preset) == "sunny", "未知预设回退 sunny")

	# 地图 env 文件
	for pair in [[1, "sunny"], [2, "sandstorm"], [3, "storm"], [4, "snow"]]:
		var cm := WeatherEnv.load_map_env(pair[0])
		ok(String(cm.preset) == pair[1], "map_%d env=%s" % [pair[0], cm.preset])
	ok(String(WeatherEnv.load_map_env(99).preset) == "sunny", "无 env 文件回退 sunny")

	# 序列化回路
	var j := WeatherEnv.to_json(c2)
	ok(j.has("preset") and String(j.preset) == "storm", "to_json 保留 preset")
	ok(j.sky_top is Array and absf(float(j.sky_top[1]) - 0.2) < 0.001, "to_json Color 转数组")
	var back := WeatherEnv.resolve(j)
	ok(absf(float(back.energy) - 0.5) < 1e-6, "序列化回路不丢覆盖值")

	# 环境装配（headless 下属性赋值应全部成功）
	var env := WeatherEnv.make_env_cfg(c2)
	ok(env.background_mode == Environment.BG_SKY, "make_env_cfg 天空背景")
	ok(env.tonemap_mode == Environment.TONE_MAPPER_ACES, "ACES 色调映射")
	ok(env.fog_enabled and absf(env.fog_density - 0.009) < 1e-9, "雾参数")
	ok(env.ssao_enabled, "SSAO 开启")
	ok(absf(env.fog_aerial_perspective - 0.75) < 1e-6, "空气透视 0.75")
	ok(env.sky.radiance_size == Sky.RADIANCE_SIZE_512, "天空辐照 512")
	var light := DirectionalLight3D.new()
	WeatherEnv.setup_light_cfg(light, c2)
	ok(absf(light.rotation_degrees.x - float(c2.pitch)) < 0.01, "太阳俯仰应用")
	ok(light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS, "四分裂阴影")
	ok(light.directional_shadow_blend_splits, "分割带混合")

	print("========== env_check: %d failures ==========" % failures)
	quit(0 if failures == 0 else 1)
