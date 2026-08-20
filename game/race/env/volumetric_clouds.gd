class_name VolumetricClouds
extends RefCounted
## 体积云天空装配：clayjohn 移植 shader(cloud_sky.gdshader) + CloudNoise 噪声贴图。
## 天空四色/太阳色/环境光取 WeatherEnv 天气预设（与 ProceduralSkyMaterial 同源配色，
## 换云天空不换美术方向）；云参数 = Game 表 env_cloud_* 全局值 × 天气预设修正
## （风暴云厚云密、晴天云疏、沙暴近无云）。
## 性能：sky shader 半/四分之一分辨率 pass raymarch，天空辐照度 cubemap 复用，
## 主画面仅半分辨率一次 raymarch（clayjohn 演示同管线）。

const SHADER := preload("res://game/race/env/cloud_sky.gdshader")

## 天气预设对云量/云厚的修正（乘在 Game 表全局值上）
const PRESET_MOD := {
	"sunny": {"coverage": 1.0, "density": 1.0},
	"sandstorm": {"coverage": 0.45, "density": 0.85},
	"storm": {"coverage": 2.4, "density": 1.7},
	"snow": {"coverage": 1.7, "density": 1.25},
}

## 由天气配置 + 云参数(coverage/density/wind，Game 表全局值)生成体积云 Sky。
## c 为 WeatherEnv.resolve 的完整环境配置；缺 preset 按晴天。
static func make_sky(c: Dictionary, cfg: Dictionary) -> Sky:
	var mat := make_material(c, cfg)
	var sky := Sky.new()
	sky.sky_material = mat
	return sky

static func make_material(c: Dictionary, cfg: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	apply_params(mat, c, cfg)
	var tex: Dictionary = CloudNoise.textures()
	mat.set_shader_parameter("worlnoise", tex["worlnoise"])
	mat.set_shader_parameter("perlworlnoise", tex["perlworlnoise"])
	mat.set_shader_parameter("weathermap", tex["weathermap"])
	return mat

## uniform 注入（天空配色 ← 天气预设；云参数 ← 表值 × 预设修正）
static func apply_params(mat: ShaderMaterial, c: Dictionary, cfg: Dictionary) -> void:
	var preset := String(c.get("preset", "sunny"))
	var mod: Dictionary = PRESET_MOD.get(preset, PRESET_MOD["sunny"])
	mat.set_shader_parameter("sky_top_color", Color(c.sky_top))
	mat.set_shader_parameter("sky_horizon_color", Color(c.sky_horizon))
	mat.set_shader_parameter("ground_horizon_color", Color(c.sky_ground_horizon))
	mat.set_shader_parameter("ground_bottom_color", Color(c.sky_ground))
	mat.set_shader_parameter("sun_color", Color(c.sun))
	mat.set_shader_parameter("ambient_color", Color(c.get("ambient", Color(0.6, 0.7, 0.85))))
	mat.set_shader_parameter("ambient_energy", float(c.get("ambient_energy", 1.0)))
	mat.set_shader_parameter("cloud_coverage", coverage_for(preset, float(cfg.get("coverage", 0.3))))
	mat.set_shader_parameter("cloud_density", clampf(
			float(cfg.get("density", 0.05)) * float(mod["density"]), 0.01, 0.2))
	mat.set_shader_parameter("wind_speed", clampf(float(cfg.get("wind", 2.0)), 0.0, 20.0))
	mat.set_shader_parameter("wind_direction", Vector2(1.0, 0.0))
	mat.set_shader_parameter("cloud_time_offset", float(cfg.get("offset", 0.0)))

## 覆盖度终值 = 全局基础值 × 预设修正，钳到 shader 值域
static func coverage_for(preset: String, base: float) -> float:
	var mod: Dictionary = PRESET_MOD.get(preset, PRESET_MOD["sunny"])
	return clampf(base * float(mod["coverage"]), 0.1, 1.0)

static func density_for(preset: String, base: float) -> float:
	var mod: Dictionary = PRESET_MOD.get(preset, PRESET_MOD["sunny"])
	return clampf(base * float(mod["density"]), 0.01, 0.2)
