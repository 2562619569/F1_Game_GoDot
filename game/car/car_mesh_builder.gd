class_name CarMeshBuilder
extends RefCounted
## 「美术资源 → 车辆视觉」装配入口：
## 1. 按 art/cars/<id>/body.json 的 wheel_positions 重定位 4 个物理轮挂点并挂载车壳模型；
## 2. 按 art/wheels/<id>/wheel.json 的 center 把轮毂模型对齐到各轮位（旋转围绕中心点）。
## 资产缺失/解析失败时保留 arcade_car.tscn 内嵌占位视觉并告警，仓库克隆无 art/ 也能运行。
## 坐标约定见 docs/美术资源与车辆结构.md（GLB 场景根空间 = VehicleRigidBody 子空间）。

## Car 表 id → 车壳资产 id（后续迁入配表 body_id 字段后移除本映射）
const BODY_BY_CAR := {
	601: "brute_power",
	602: "agile_sprinter",
	603: "all_rounder",
}
const DEFAULT_WHEEL := "sport_v1"

## body.json 轮位键 → [物理轮 RayCast3D, 视觉挂点 Node3D, 内嵌占位轮 mesh]
const SLOTS := {
	"front_left": ["WheelFrontLeft", "FrontLeftWheel", "wheel_frontLeft"],
	"front_right": ["WheelFrontRight", "FrontRightWheel", "wheel_frontRight"],
	"rear_left": ["WheelRearLeft", "RearLeftWheel", "wheel_backLeft"],
	"rear_right": ["WheelRearRight", "RearRightWheel", "wheel_backRight"],
}

## 按配表车型装配默认视觉；无映射或资产缺失时保留占位
static func attach_visual(v: Vehicle, car_id: int) -> bool:
	var body_id: String = BODY_BY_CAR.get(car_id, "")
	if body_id.is_empty():
		return false
	return attach(v, body_id, DEFAULT_WHEEL)

static func attach(v: Vehicle, body_id: String, wheel_id: String) -> bool:
	# --- 校验（全部通过前不改动任何节点，失败即完整回退占位视觉）---
	var body_meta := _load_json("res://art/cars/%s/body.json" % body_id)
	if body_meta.is_empty():
		push_warning("CarMeshBuilder: 缺少车壳元数据 art/cars/%s/body.json，使用占位视觉" % body_id)
		return false
	var body_path := "res://art/cars/%s/%s" % [body_id, body_meta.get("model", "body.glb")]
	if not ResourceLoader.exists(body_path):
		push_warning("CarMeshBuilder: 车壳模型缺失 %s，使用占位视觉" % body_path)
		return false
	var positions: Dictionary = body_meta.get("wheel_positions", {})
	for slot in SLOTS:
		if not (positions.get(slot) is Array and positions[slot].size() == 3):
			push_warning("CarMeshBuilder: 车壳 %s 的 wheel_positions.%s 缺失或不合法，使用占位视觉" % [body_id, slot])
			return false

	# 轮毂资产允许缺失：仅保留占位轮，车壳照常装配
	var wheel_meta := _load_json("res://art/wheels/%s/wheel.json" % wheel_id)
	var wheel_scene: PackedScene = null
	var center := Vector3.ZERO
	if not wheel_meta.is_empty():
		var wheel_path := "res://art/wheels/%s/%s" % [wheel_id, wheel_meta.get("model", "wheel.glb")]
		if ResourceLoader.exists(wheel_path):
			wheel_scene = load(wheel_path)
			center = _vec3(wheel_meta.get("center", [0.0, 0.0, 0.0]))
		else:
			push_warning("CarMeshBuilder: 轮毂模型缺失 %s，保留占位轮" % wheel_path)
	else:
		push_warning("CarMeshBuilder: 缺少轮毂元数据 art/wheels/%s/wheel.json，保留占位轮" % wheel_id)

	# --- 装配（须在车辆入树前调用：initialize() 会按轮位计算质心与悬挂射线）---
	var body_node: MeshInstance3D = v.get_node_or_null("body")
	if body_node:
		body_node.visible = false
		var spoiler := body_node.get_node_or_null("spoiler")
		if spoiler:
			spoiler.visible = false
	var body_visual: Node3D = load(body_path).instantiate()
	body_visual.name = "BodyVisual"
	v.add_child(body_visual)

	for slot in SLOTS:
		var names: Array = SLOTS[slot]
		var ray: Node3D = v.get_node(names[0])
		ray.position = _vec3(positions[slot])
		var wheel_node: Node3D = ray.get_node(names[1])
		var old_mesh: Node3D = wheel_node.get_node_or_null(names[2])
		if old_mesh:
			old_mesh.visible = false
		if wheel_scene:
			var wheel_visual: Node3D = wheel_scene.instantiate()
			wheel_visual.name = "WheelVisual"
			wheel_visual.position = -center
			wheel_node.add_child(wheel_visual)
			var wl := ray as Wheel
			if wl:
				wl.tire_radius = float(wheel_meta.get("radius", 0.3))
	return true

static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	return {}

static func _vec3(arr) -> Vector3:
	if arr is Array and arr.size() >= 3:
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO
