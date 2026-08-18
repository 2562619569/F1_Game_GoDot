class_name WeatherEnv
extends RefCounted
## 天气/环境预设 + 地图环境文件(map_<id>_env.json)的加载与合成。
## 配表 Map 表不再含天气列：每张地图的环境(天空/太阳/雾/环境光/辉光)存放在
## 与烘焙几何(map_<id>.json)分离的 env 文件里，由引擎内插件或手写编辑；
## 抓地力修正与地面着色仍取预设默认值(可被 env 文件同名键覆盖)。
## 运行时与 addons/map_env_editor 插件共用本文件，保证所见即所得。

enum Type { SUNNY, SANDSTORM, STORM, SNOW }

const ENV_DIR := "res://game/race/tracks/data"

## 完整环境描述：label/chip/advice 供 UI 展示；sky_*/sun/energy/pitch/yaw/
## fog*/ambient*/glow* 为环境表现；road/dirt/gravel/wet 为抓地修正；
## grass/road_c/dirt_c/gravel_c 为地面着色。env 文件同名键(JSON 数组表示颜色)
## 可直接覆盖除 label/chip/advice 外的键。
const DATA := {
	Type.SUNNY: {
		"label": "Sunny", "chip": Color(1.0, 0.83, 0.35),
		"sky_top": Color(0.22, 0.48, 0.78), "sky_horizon": Color(0.66, 0.78, 0.88),
		"sky_ground_horizon": Color(0.48, 0.55, 0.60), "sky_ground": Color(0.24, 0.28, 0.32),
		"sun": Color(1.0, 0.97, 0.88), "energy": 1.3, "pitch": -52.0, "yaw": -35.0,
		"fog": Color(0.75, 0.86, 0.96), "fog_density": 0.0035,
		"ambient": Color(0.6, 0.7, 0.85), "ambient_energy": 1.0,
		"glow": true, "glow_intensity": 0.5,
		"road": 1.0, "dirt": 1.0, "gravel": 1.0, "wet": false,
		"grass": Color(0.30, 0.55, 0.28), "road_c": Color(0.22, 0.23, 0.26), "dirt_c": Color(0.52, 0.40, 0.26),
		"gravel_c": Color(0.60, 0.55, 0.45),
		"advice": "Clear skies. Go full top speed build.",
	},
	Type.SANDSTORM: {
		"label": "Sandstorm", "chip": Color(0.90, 0.70, 0.35),
		"sky_top": Color(0.72, 0.58, 0.38), "sky_horizon": Color(0.86, 0.72, 0.50),
		"sky_ground_horizon": Color(0.74, 0.61, 0.42), "sky_ground": Color(0.45, 0.36, 0.24),
		"sun": Color(1.0, 0.85, 0.60), "energy": 1.0, "pitch": -58.0, "yaw": -50.0,
		"fog": Color(0.84, 0.72, 0.52), "fog_density": 0.012,
		"ambient": Color(0.8, 0.68, 0.5), "ambient_energy": 1.1,
		"glow": true, "glow_intensity": 0.3,
		"road": 0.95, "dirt": 1.05, "gravel": 0.95, "wet": false,
		"grass": Color(0.62, 0.52, 0.28), "road_c": Color(0.38, 0.33, 0.26), "dirt_c": Color(0.68, 0.52, 0.28),
		"gravel_c": Color(0.74, 0.62, 0.40),
		"advice": "Gravel canyon ahead. Rally tires + reinforced suspension.",
	},
	Type.STORM: {
		"label": "Storm", "chip": Color(0.35, 0.45, 0.95),
		"sky_top": Color(0.16, 0.19, 0.27), "sky_horizon": Color(0.38, 0.42, 0.50),
		"sky_ground_horizon": Color(0.30, 0.33, 0.40), "sky_ground": Color(0.12, 0.14, 0.18),
		"sun": Color(0.62, 0.68, 0.85), "energy": 0.75, "pitch": -60.0, "yaw": 20.0,
		"fog": Color(0.32, 0.38, 0.48), "fog_density": 0.005,
		"ambient": Color(0.4, 0.45, 0.58), "ambient_energy": 1.2,
		"glow": true, "glow_intensity": 0.45,
		"road": 0.76, "dirt": 0.88, "gravel": 0.82, "wet": true,
		"grass": Color(0.22, 0.38, 0.22), "road_c": Color(0.16, 0.17, 0.20), "dirt_c": Color(0.38, 0.31, 0.21),
		"gravel_c": Color(0.44, 0.41, 0.35),
		"advice": "Soaked tarmac. Rain tires + high-downforce wing.",
	},
	Type.SNOW: {
		"label": "Snow", "chip": Color(0.65, 0.85, 1.0),
		"sky_top": Color(0.72, 0.77, 0.85), "sky_horizon": Color(0.88, 0.90, 0.94),
		"sky_ground_horizon": Color(0.82, 0.84, 0.88), "sky_ground": Color(0.70, 0.73, 0.78),
		"sun": Color(0.90, 0.95, 1.0), "energy": 1.05, "pitch": -48.0, "yaw": -35.0,
		"fog": Color(0.86, 0.90, 0.98), "fog_density": 0.004,
		"ambient": Color(0.85, 0.88, 0.94), "ambient_energy": 1.1,
		"glow": true, "glow_intensity": 0.4,
		"road": 0.66, "dirt": 0.60, "gravel": 0.60, "wet": true,
		"grass": Color(0.88, 0.92, 0.98), "road_c": Color(0.55, 0.58, 0.64), "dirt_c": Color(0.72, 0.76, 0.84),
		"gravel_c": Color(0.72, 0.74, 0.78),
		"advice": "Packed ice. Grip is everything: all-terrain or rain tires.",
	},
}

## env 文件可覆盖的键(label/chip/advice 随预设，不接受覆盖)
const OVERLAY_KEYS := ["sky_top", "sky_horizon", "sky_ground_horizon", "sky_ground",
	"sun", "energy", "pitch", "yaw", "fog", "fog_density",
	"ambient", "ambient_energy", "glow", "glow_intensity",
	"road", "dirt", "gravel", "wet", "grass", "road_c", "dirt_c", "gravel_c"]

## 配表字符串 → 枚举的唯一解析口（未知值回退 SUNNY）
static func id(s: String) -> Type:
	match s:
		"sandstorm": return Type.SANDSTORM
		"storm": return Type.STORM
		"snow": return Type.SNOW
		_: return Type.SUNNY

static func preset_name(t: Type) -> String:
	match t:
		Type.SANDSTORM: return "sandstorm"
		Type.STORM: return "storm"
		Type.SNOW: return "snow"
		_: return "sunny"

static func cfg(weather: Type) -> Dictionary:
	return DATA.get(weather, DATA[Type.SUNNY])

## 表面摩擦修正（应用到轮胎字典）
static func surface_mod(weather: Type) -> Dictionary:
	var c := cfg(weather)
	return {"Road": c.road, "Dirt": c.dirt, "Gravel": c.gravel, "wet": c.wet}

## 同上，但作用于已合成的环境配置（地图 env 文件可能覆盖过 road/dirt/gravel/wet）
static func surface_mod_cfg(c: Dictionary) -> Dictionary:
	return {"Road": float(c.road), "Dirt": float(c.dirt), "Gravel": float(c.gravel), "wet": bool(c.wet)}

# ---------------- 地图 env 文件（与烘焙几何分离） ----------------

static func env_path(map_id: int) -> String:
	return "%s/map_%d_env.json" % [ENV_DIR, map_id]

## 加载地图环境并合成完整配置；无 env 文件回退 SUNNY 预设
static func load_map_env(map_id: int) -> Dictionary:
	var f := FileAccess.open(env_path(map_id), FileAccess.READ)
	if f == null:
		return resolve({})
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return resolve(parsed)
	push_warning("WeatherEnv: env 文件损坏，回退 SUNNY  %s" % env_path(map_id))
	return resolve({})

## 预设默认 + env 文件覆盖 → 完整环境配置（键同 DATA 条目，另含 "preset" 字符串）
static func resolve(d: Dictionary) -> Dictionary:
	var preset := String(d.get("preset", "sunny"))
	var out: Dictionary = cfg(id(preset)).duplicate()
	out["preset"] = preset_name(id(preset))
	for key in OVERLAY_KEYS:
		if d.has(key):
			out[key] = _json_value(d[key])
	return out

## 完整配置 → env 文件字典（颜色转 [r,g,b] 数组；label/chip/advice 不落盘）
static func to_json(c: Dictionary) -> Dictionary:
	var out := {"preset": String(c.get("preset", "sunny"))}
	for key in OVERLAY_KEYS:
		if c.has(key):
			var v = c[key]
			out[key] = [snappedf(v.r, 0.001), snappedf(v.g, 0.001), snappedf(v.b, 0.001)] if v is Color else v
	return out

static func _json_value(v):
	return Color(float(v[0]), float(v[1]), float(v[2])) if v is Array and v.size() >= 3 else v

# ---------------- 环境装配（运行时与编辑器插件共用） ----------------

## 由完整配置生成比赛用 Environment：程序化天空 + 天空环境光 + ACES + 雾(+辉光)
static func make_env_cfg(c: Dictionary) -> Environment:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = c.sky_top
	sky_mat.sky_horizon_color = c.sky_horizon
	sky_mat.ground_horizon_color = c.sky_ground_horizon
	sky_mat.ground_bottom_color = c.sky_ground
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = c.ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = bool(c.glow)
	env.glow_intensity = c.glow_intensity
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE   # 加色混合：刹车灯/灯罩泛光远看醒目
	env.glow_hdr_threshold = 1.0                                 # 只让 HDR 超亮像素(自发光件/太阳)泛光
	env.glow_bloom = 0.1                                         # 软化阈值拐点，光晕边缘过渡自然
	env.fog_enabled = true
	env.fog_light_color = c.fog
	env.fog_density = c.fog_density
	return env

## 由完整配置设置太阳光（角度/颜色/能量 + 软阴影调优）
static func setup_light_cfg(light: DirectionalLight3D, c: Dictionary) -> void:
	light.light_color = c.sun
	light.light_energy = c.energy
	light.rotation_degrees = Vector3(c.pitch, c.yaw, 0.0)
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_max_distance = 160.0

# ---------------- 兼容旧接口（直连预设） ----------------

static func make_env(weather: Type) -> Environment:
	return make_env_cfg(cfg(weather))

static func setup_light(light: DirectionalLight3D, weather: Type) -> void:
	setup_light_cfg(light, cfg(weather))
