@tool
extends Node3D
## 环境预览：用与运行时完全相同的装配（WeatherEnv 合成 + TrackBuilder 重建赛道）
## 展示当前参数效果。地图无几何 JSON 时退化为地面 + 方块示例场景。

var _env_node: WorldEnvironment
var _sun: DirectionalLight3D

func setup(map_id: int, cfg: Dictionary) -> void:
	_env_node = WorldEnvironment.new()
	add_child(_env_node)
	_sun = DirectionalLight3D.new()
	add_child(_sun)
	apply_env(cfg)

	var center := Vector3.ZERO
	var data := TrackData.load_json("res://game/race/tracks/data/map_%d.json" % map_id)
	if data != null:
		var tb := TrackBuilder.new()
		add_child(tb)
		tb.build(data)
		tb.setup(cfg)
		center = data.start_point() + data.tangent_at(0.0) * 20.0
	else:
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(120, 120)
		ground.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = cfg.road_c
		ground.material_override = mat
		add_child(ground)
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(6, 3, 12)
		box.mesh = bm
		box.position = Vector3(0, 1.5, 0)
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.8, 0.2, 0.15)
		bmat.metallic = 0.8
		bmat.roughness = 0.25
		box.material_override = bmat
		add_child(box)

	var cam: Camera3D = load("res://addons/map_env_editor/preview_camera.gd").new()
	cam.target = center + Vector3(0, 1.5, 0)
	cam.dist = 28.0
	add_child(cam)

## 参数变化时只刷新环境与太阳（赛道几何不变）
func apply_env(cfg: Dictionary) -> void:
	if _env_node != null:
		_env_node.environment = WeatherEnv.make_env_cfg(cfg)
	if _sun != null:
		WeatherEnv.setup_light_cfg(_sun, cfg)
