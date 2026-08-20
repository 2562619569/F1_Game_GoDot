extends Node
## L1 校验：体积云天空（clayjohn 移植 shader + 程序化噪声贴图 + 配表参数）。
## 场景型（autoload 可用）：Game 表 env_cloud_* 键、噪声贴图供给与
## 生成确定性、云材质参数(表值×天气预设修正)、WeatherEnv 云天空切换与旧路径回归。
## 运行: godot --headless --path . res://game/testing/env_cloud_check.tscn

var failures := 0

func ok(cond: bool, label: String) -> void:
	if cond:
		print("[CLOUD] OK   | %s" % label)
	else:
		failures += 1
		print("[CLOUD] FAIL | %s" % label)

func _ready() -> void:
	_check_config()
	_check_textures()
	_check_material()
	_check_env_switch()
	print("========== env_cloud_check: %d failures ==========" % failures)
	get_tree().quit(0 if failures == 0 else 1)

# ---------------- 配表 ----------------

func _check_config() -> void:
	var keys := {
		"env_clouds_enabled": 1.0, "env_cloud_coverage": 0.3,
		"env_cloud_density": 0.055, "env_cloud_wind": 2.5,
	}
	var all_present := true
	for key in keys:
		if absf(Match.game_cfg(key) - float(keys[key])) > 0.0001:
			all_present = false
			print("      缺失/不符: %s = %s（期望 %s）" % [key, Match.game_cfg(key), keys[key]])
	ok(all_present, "Game 表 env_cloud_* 4 键与入库默认值一致")
	ok(Match.game_cfg("env_cloud_coverage") >= 0.1 and Match.game_cfg("env_cloud_coverage") <= 1.0,
			"env_cloud_coverage 在 shader 值域 0.1~1")
	var cc := RaceBuilder._cloud_cfg(1)
	ok(cc["enabled"] == true and absf(float(cc["coverage"]) - 0.3) < 0.0001
			and absf(float(cc["offset"]) - 137.0) < 0.001,
			"RaceBuilder 云参数装配：总开关开 + 表值直通 + 按图错开 offset")

# ---------------- 噪声贴图 ----------------

func _check_textures() -> void:
	ok(CloudNoise.upstream_available(), "上游噪声贴图入库（clayjohn MIT，导入为 CompressedTexture3D）")
	var tex := CloudNoise.textures()
	var w = tex["worlnoise"]
	var p = tex["perlworlnoise"]
	var m = tex["weathermap"]
	ok(w != null and w.get_depth() == 32 and p != null and p.get_depth() == 128,
			"3D 贴图加载（worl 32³ / perl 128³）")
	ok(m != null and m.get_width() == 512, "天气图 512²")
	var w1 := CloudNoise.worlnoise(8)
	var w2 := CloudNoise.worlnoise(8)
	ok(w1.get_depth() == 8 and CloudNoise.weathermap(64) != null,
			"兜底即时生成路径可用（任意分辨率）")

func _check_material() -> void:
	var sunny := WeatherEnv.cfg(WeatherEnv.Type.SUNNY)
	var cfg := {"enabled": true, "coverage": 0.3, "density": 0.055, "wind": 2.5, "offset": 137.0}
	var mat := VolumetricClouds.make_material(sunny, cfg)
	ok(mat != null and mat.shader != null, "云 ShaderMaterial 装配（shader 加载成功）")
	ok(absf(float(mat.get_shader_parameter("cloud_coverage")) - VolumetricClouds.coverage_for("sunny", 0.3)) < 0.0001,
			"cloud_coverage uniform = 表值×预设修正")
	ok(VolumetricClouds.coverage_for("storm", 0.3) > VolumetricClouds.coverage_for("sunny", 0.3),
			"预设修正方向：风暴云量 > 晴天")
	ok(absf(VolumetricClouds.coverage_for("sunny", 0.3) - 0.3) < 0.0001,
			"晴天修正 = 1.0（不动表值）")
	var c := Color(mat.get_shader_parameter("sky_top_color"))
	ok(absf(c.r - sunny.sky_top.r) < 0.001 and absf(c.b - sunny.sky_top.b) < 0.001,
			"天空配色注入 = 天气预设（美术方向不变）")
	ok(absf(float(mat.get_shader_parameter("cloud_density")) - VolumetricClouds.density_for("sunny", 0.055)) < 0.0001,
			"cloud_density uniform = 表值×预设修正")
	ok(mat.get_shader_parameter("worlnoise") != null
			and mat.get_shader_parameter("perlworlnoise") != null
			and mat.get_shader_parameter("weathermap") != null,
			"三张噪声贴图 uniform 注入非空")

# ---------------- WeatherEnv 切换 ----------------

func _check_env_switch() -> void:
	var sunny := WeatherEnv.cfg(WeatherEnv.Type.SUNNY)
	var with_clouds: Environment = WeatherEnv.make_env_cfg(sunny,
			{"enabled": true, "coverage": 0.3, "density": 0.055, "wind": 2.5, "offset": 0.0})
	ok(with_clouds.sky.sky_material is ShaderMaterial,
			"make_env_cfg(clouds.enabled) → 云 ShaderMaterial 天空")
	ok(with_clouds.background_mode == Environment.BG_SKY and with_clouds.fog_enabled,
			"云天空环境其余键不变（BG_SKY + 雾仍开）")
	var legacy: Environment = WeatherEnv.make_env_cfg(sunny)
	ok(legacy.sky.sky_material is ProceduralSkyMaterial,
			"make_env_cfg() 缺省 → 旧 ProceduralSkyMaterial（编辑器/旧测试零改动）")
	var storm := WeatherEnv.resolve({"preset": "storm"})  # 运行时配置经 resolve 携带 preset 键
	var storm_env: Environment = WeatherEnv.make_env_cfg(storm,
			{"enabled": true, "coverage": 0.3, "density": 0.055, "wind": 2.5, "offset": 0.0})
	var storm_mat: ShaderMaterial = storm_env.sky.sky_material
	ok(absf(float(storm_mat.get_shader_parameter("cloud_coverage")) - clampf(0.3 * 2.4, 0.1, 1.0)) < 0.0001,
			"风暴天气云量修正生效（0.3×2.4=%.2f）" % clampf(0.3 * 2.4, 0.1, 1.0))
	var c2 := Color(storm_mat.get_shader_parameter("sky_top_color"))
	ok(absf(c2.r - storm.sky_top.r) < 0.001,
			"风暴配色注入云天空（暗色天顶）")
