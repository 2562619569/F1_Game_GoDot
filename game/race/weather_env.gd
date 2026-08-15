class_name WeatherEnv
extends RefCounted
## 天气词缀：环境表现（天空/雾/太阳）+ 表面摩擦修正。
## 数值集中在此，方便后期调表或接 Map 表扩展字段。
## 配表里的天气字符串只在入口用 id() 解析一次，之后全程传 Type 枚举。

enum Type { SUNNY, SANDSTORM, STORM, SNOW }

const DATA := {
	Type.SUNNY: {
		"label": "Sunny", "chip": Color(1.0, 0.83, 0.35),
		"bg": Color(0.55, 0.78, 0.96), "fog": Color(0.75, 0.86, 0.96),
		"sun": Color(1.0, 0.97, 0.88), "energy": 1.25,
		"road": 1.0, "dirt": 1.0, "wet": false,
		"grass": Color(0.30, 0.55, 0.28), "road_c": Color(0.22, 0.23, 0.26), "dirt_c": Color(0.52, 0.40, 0.26),
		"advice": "Clear skies. Go full top speed build.",
	},
	Type.SANDSTORM: {
		"label": "Sandstorm", "chip": Color(0.90, 0.70, 0.35),
		"bg": Color(0.82, 0.66, 0.42), "fog": Color(0.84, 0.72, 0.52),
		"sun": Color(1.0, 0.85, 0.60), "energy": 1.0,
		"road": 0.95, "dirt": 1.05, "wet": false,
		"grass": Color(0.62, 0.52, 0.28), "road_c": Color(0.38, 0.33, 0.26), "dirt_c": Color(0.68, 0.52, 0.28),
		"advice": "Gravel canyon ahead. Rally tires + reinforced suspension.",
	},
	Type.STORM: {
		"label": "Storm", "chip": Color(0.35, 0.45, 0.95),
		"bg": Color(0.22, 0.26, 0.34), "fog": Color(0.32, 0.38, 0.48),
		"sun": Color(0.62, 0.68, 0.85), "energy": 0.7,
		"road": 0.76, "dirt": 0.88, "wet": true,
		"grass": Color(0.22, 0.38, 0.22), "road_c": Color(0.16, 0.17, 0.20), "dirt_c": Color(0.38, 0.31, 0.21),
		"advice": "Soaked tarmac. Rain tires + high-downforce wing.",
	},
	Type.SNOW: {
		"label": "Snow", "chip": Color(0.65, 0.85, 1.0),
		"bg": Color(0.80, 0.86, 0.96), "fog": Color(0.86, 0.90, 0.98),
		"sun": Color(0.90, 0.95, 1.0), "energy": 1.0,
		"road": 0.66, "dirt": 0.60, "wet": true,
		"grass": Color(0.88, 0.92, 0.98), "road_c": Color(0.55, 0.58, 0.64), "dirt_c": Color(0.72, 0.76, 0.84),
		"advice": "Packed ice. Grip is everything: all-terrain or rain tires.",
	},
}

## 配表字符串 → 枚举的唯一解析口（未知值回退 SUNNY）
static func id(s: String) -> Type:
	match s:
		"sandstorm": return Type.SANDSTORM
		"storm": return Type.STORM
		"snow": return Type.SNOW
		_: return Type.SUNNY

static func cfg(weather: Type) -> Dictionary:
	return DATA.get(weather, DATA[Type.SUNNY])

## 表面摩擦修正（CarBuilder 应用到轮胎字典）
static func surface_mod(weather: Type) -> Dictionary:
	var c := cfg(weather)
	return {"Road": c.road, "Dirt": c.dirt, "wet": c.wet}

## 生成比赛用 Environment
static func make_env(weather: Type) -> Environment:
	var c := cfg(weather)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = c.bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = c.bg.lightened(0.15)
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_light_color = c.fog
	env.fog_density = 0.004 if weather != Type.SANDSTORM else 0.012
	return env

static func setup_light(light: DirectionalLight3D, weather: Type) -> void:
	var c := cfg(weather)
	light.light_color = c.sun
	light.light_energy = c.energy
	light.rotation_degrees = Vector3(-52, -35, 0)
	light.shadow_enabled = true
