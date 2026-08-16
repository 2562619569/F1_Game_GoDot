class_name CarMeshBuilder
extends RefCounted
## 「美术资源 → 车辆视觉」装配入口：
## 1. 按 art/cars/<id>/body.json 的 body_width + 轮胎 width 齐边推导 4 个轮位，
##    重定位物理轮挂点并挂载车壳模型（轮位 x = ±(body_width − tire_width/2)）；
## 2. 每个轮位分别挂载轮毂（art/wheels/<hub_id>/hub.glb，纯外观件）与
##    轮胎（art/tires/<tire_id>/tire.glb，随轮胎改件换装），各按自己的 center 对齐；
## 3. tire.json 的 radius 在入树前写入 vehicle 的 front/rear_tire_radius，
##    由 initialize() 统一下发各物理轮——不能直写 wheel.tire_radius（会被 initialize 覆盖）。
## 资产缺失/解析失败时保留 arcade_car.tscn 内嵌占位视觉并告警，仓库克隆无 art/ 也能运行。
## 坐标约定见 docs/美术资源与车辆结构.md（GLB 场景根空间 = VehicleRigidBody 子空间）。

## 未选外观件时的默认轮毂 / 未装轮胎改件时的原厂胎（占位资产兜底名）
const DEFAULT_HUB := "sport_v1"
const DEFAULT_TIRE := "stock_v1"

const _BodyAttitude := preload("res://game/car/body_attitude.gd")
const _BrakeLight := preload("res://game/car/brake_light.gd")
const _MaterialPresets := preload("res://game/car/material_presets.gd")

## body.json 轮位键 → [物理轮 RayCast3D, 视觉挂点 Node3D, 内嵌占位轮 mesh]
const SLOTS := {
	"front_left": ["WheelFrontLeft", "FrontLeftWheel", "wheel_frontLeft"],
	"front_right": ["WheelFrontRight", "FrontRightWheel", "wheel_frontRight"],
	"rear_left": ["WheelRearLeft", "RearLeftWheel", "wheel_backLeft"],
	"rear_right": ["WheelRearRight", "RearRightWheel", "wheel_backRight"],
}

## 按配表车型 + 外观描述装配视觉；appearance 见 Match.appearance()：
## {"wheel": 轮毂资产id, "tire": 轮胎资产id, ...}，缺省项用默认轮毂 / 原厂胎。
## 未来外观项（车漆等）在本 dict 加 key 扩展，本签名不变。
static func attach_visual(v: Vehicle, car_id: int, appearance := {}) -> bool:
	var body_id := str(car_id)   # 目录名即配表 id
	return attach(v, body_id,
		appearance.get("wheel", DEFAULT_HUB),
		appearance.get("tire", DEFAULT_TIRE))

static func attach(v: Vehicle, body_id: String, hub_id: String, tire_id: String) -> bool:
	# --- 校验（全部通过前不改动任何节点，失败即完整回退占位视觉）---
	var body_meta := _load_json("res://art/cars/%s/body.json" % body_id)
	if body_meta.is_empty():
		push_warning("CarMeshBuilder: 缺少车壳元数据 art/cars/%s/body.json，使用占位视觉" % body_id)
		return false
	var body_path := "res://art/cars/%s/%s" % [body_id, body_meta.get("model", "body.glb")]
	if not ResourceLoader.exists(body_path):
		push_warning("CarMeshBuilder: 车壳模型缺失 %s，使用占位视觉" % body_path)
		return false
	var body_width: float = float(body_meta.get("body_width", 0.0))
	var front_axle: Variant = body_meta.get("front_axle")
	var rear_axle: Variant = body_meta.get("rear_axle")
	if body_width <= 0.0 or not _axle_ok(front_axle) or not _axle_ok(rear_axle):
		push_warning("CarMeshBuilder: 车壳 %s 的 body_width / front_axle / rear_axle 缺失或不合法，使用占位视觉" % body_id)
		return false

	# 轮毂/轮胎资产各自允许缺失：只挂存在的一侧，两侧全缺才保留占位轮
	var hub := _load_wheel_part("wheels", hub_id, "hub.json", "HubVisual")
	var tire := _load_wheel_part("tires", tire_id, "tire.json", "TireVisual")

	# --- 装配（须在车辆入树前调用：initialize() 会按轮位计算质心与悬挂射线）---
	var body_node: MeshInstance3D = v.get_node_or_null("body")
	if body_node:
		body_node.visible = false
		var spoiler := body_node.get_node_or_null("spoiler")
		if spoiler:
			spoiler.visible = false
	# 车壳挂在 BodyAttitude 姿态层下：pitch/roll 视觉增强叠加在刚体物理旋转之上
	var body_pivot: Node3D = _BodyAttitude.new()
	body_pivot.name = "BodyPivot"
	v.add_child(body_pivot)
	var body_visual: Node3D = load(body_path).instantiate()
	body_visual.name = "BodyVisual"
	body_pivot.add_child(body_visual)

	# 刹车灯：body.json 的 materials.brake_light 按材质名点亮（未标记则自动跳过；
	# headlight / body 标记暂只存元数据，后续做车灯/车漆逻辑时消费）
	var mats_meta: Dictionary = body_meta.get("materials") if body_meta.get("materials") is Dictionary else {}
	var brake_light := _BrakeLight.new()
	brake_light.name = "BrakeLight"
	body_visual.add_child(brake_light)
	brake_light.setup(v, body_visual, mats_meta)

	# 预设材质球（车漆/大灯罩/车玻璃）：按 material_presets 把同名材质替换为社区效果 ShaderMaterial
	var presets_meta: Dictionary = body_meta.get("material_presets") \
			if body_meta.get("material_presets") is Dictionary else {}
	_MaterialPresets.apply(body_visual, presets_meta)

	# 齐边推导用胎宽；胎半径写入 vehicle 导出变量（入树前），由 initialize() 下发各物理轮
	var tire_width: float = tire.get("width", 0.2)
	v.front_tire_radius = tire.get("radius", 0.3)
	v.rear_tire_radius = tire.get("radius", 0.3)

	var half_axle_x := body_width - tire_width * 0.5
	for slot in SLOTS:
		var names: Array = SLOTS[slot]
		var ray: Node3D = v.get_node(names[0])
		var axle: Dictionary = front_axle if slot.begins_with("front") else rear_axle
		var sign_x := -1.0 if slot.ends_with("left") else 1.0
		ray.position = Vector3(sign_x * half_axle_x, float(axle["y"]), float(axle["z"]))
		var wheel_node: Node3D = ray.get_node(names[1])
		var old_mesh: Node3D = wheel_node.get_node_or_null(names[2])
		if old_mesh:
			old_mesh.visible = hub.scene != null or tire.scene != null
		for part in [hub, tire]:
			if part.scene == null:
				continue
			var visual: Node3D = part.scene.instantiate()
			visual.name = part.node_name
			visual.position = -part.center
			wheel_node.add_child(visual)
	return true

## 读取 wheels/<id>/hub.json 或 tires/<id>/tire.json 一侧的资产描述：
## {scene: PackedScene(缺失为 null), center: Vector3, radius: float, width: float}
static func _load_wheel_part(dir: String, asset_id: String, json_name: String, node_name: String) -> Dictionary:
	var out := {"scene": null, "center": Vector3.ZERO, "radius": 0.3, "width": 0.2, "node_name": node_name}
	var meta := _load_json("res://art/%s/%s/%s" % [dir, asset_id, json_name])
	if meta.is_empty():
		push_warning("CarMeshBuilder: 缺少元数据 art/%s/%s/%s，该侧保留占位" % [dir, asset_id, json_name])
		return out
	var path := "res://art/%s/%s/%s" % [dir, asset_id, meta.get("model", json_name.trim_suffix(".json") + ".glb")]
	if not ResourceLoader.exists(path):
		push_warning("CarMeshBuilder: 模型缺失 %s，该侧保留占位" % path)
		return out
	out.scene = load(path)
	out.center = _vec3(meta.get("center", [0.0, 0.0, 0.0]))
	out.radius = float(meta.get("radius", 0.3))
	out.width = float(meta.get("width", 0.2))
	return out

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

static func _axle_ok(a: Variant) -> bool:
	return a is Dictionary and a.has("y") and a.has("z") \
		and (a["y"] is float or a["y"] is int) and (a["z"] is float or a["z"] is int)
