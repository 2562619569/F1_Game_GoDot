class_name CarMeshBuilder
extends RefCounted
## 「美术资源 → 车辆视觉」装配入口：
## 1. 轮位以轮毂为基准定义：hub.json 的 outer（原点→外盘面）齐 body_width 车身边线，
##    轮位 x = ±(body_width − hub.outer)，重定位物理轮挂点并挂载车壳模型；
##    无轮毂资产或缺 outer 元数据时退回胎侧齐边（body_width − tire.width/2）；
## 2. 轮位定了再套轮胎：轮毂原点=安装位直接对齐轮位；轮胎中线对齐轮毂桶身的
##    几何中线（hub.json 的 mid_x）——轮毂盘面深浅不一（sport/classic/aero 的
##    外盘面距原点 0.07~0.13 不等），若各件只按自身原点居中，盘面会被埋进胎内
##    呈内凹错位；刹车盘（art/brakes/<brake_id>/disc.glb，前/后轴各一款）原点
##    同为安装位，直接对齐；
## 3. tire.json 的 radius 在入树前写入 vehicle 的 front/rear_tire_radius，
##    由 initialize() 统一下发各物理轮——不能直写 wheel.tire_radius（会被 initialize 覆盖）。
## 真实轮件按「外侧朝 +X」建模：左侧轮位统一绕 Y 翻转 180°（轮胎对称无视觉差异，
## 轮毂盘面与刹车盘朝向因此左右正确）；刹车盘随悬挂与转向但不随轮自转（卡钳公转是穿帮），
## 挂在物理轮 RayCast3D 下的 BrakePivot，由 wheel.gd 每帧同步悬挂 y。
## 资产缺失/解析失败时保留 arcade_car.tscn 内嵌占位视觉并告警，仓库克隆无 art/ 也能运行。
## 轮件 GLB 交付不带贴图，挂载后统一替换引擎侧固定材质：磨砂黑轮毂 / 橡胶胎 /
## 亮面纯金属刹车盘（卡钳材质保留 GLB 原样），见 wheel_materials.gd。
## 坐标约定见 docs/美术资源与车辆结构.md（GLB 场景根空间 = VehicleRigidBody 子空间）。

## 未选外观件时的默认轮毂 / 未装轮胎改件时的原厂胎（占位资产兜底名）
const DEFAULT_HUB := "sport_v1"
const DEFAULT_TIRE := "stock_v1"

## 碰撞盒（贴地底盘低盒）：占位 demo 凸包只有 2.45×1.3×0.6，而真实车壳长 4.7+、
## 宽 2.1——车头 1m 多、两侧各 0.4m 无碰撞体（视觉穿墙），且高顶角远在质心之上
## （撞墙/车车刮蹭产生翻滚力矩而非横向推力，一顶就翻）。按车壳包围盒重建为低盒：
## 长宽贴合车身（各边内缩 COL_SKIN），盒底离地 COL_CLEARANCE（避让悬挂压缩行程，
## 不抢车轮接地），高度压到质心附近——上盖/车顶不参与碰撞（赛道墙 1.2m、接触
## 都在低处），换来撞击难以翻车。
const COL_CLEARANCE := 0.15
const COL_HEIGHT := 0.5
const COL_SKIN := 0.05
## 默认前/后刹车盘（真实资产，无对应占位；缺失时该侧不挂）
const DEFAULT_BRAKE_FRONT := "front_v1"
const DEFAULT_BRAKE_REAR := "rear_v1"

const _BodyAttitude := preload("res://game/car/body_attitude.gd")
const _BrakeLight := preload("res://game/car/brake_light.gd")
const _MaterialPresets := preload("res://game/car/material_presets.gd")
const _WheelMaterials := preload("res://game/car/wheel_materials.gd")

## body.json 轮位键 → [物理轮 RayCast3D, 视觉挂点 Node3D, 内嵌占位轮 mesh]
const SLOTS := {
	"front_left": ["WheelFrontLeft", "FrontLeftWheel", "wheel_frontLeft"],
	"front_right": ["WheelFrontRight", "FrontRightWheel", "wheel_frontRight"],
	"rear_left": ["WheelRearLeft", "RearLeftWheel", "wheel_backLeft"],
	"rear_right": ["WheelRearRight", "RearRightWheel", "wheel_backRight"],
}

## 按配表车型 + 外观描述装配视觉；appearance 见 Match.appearance()：
## {"wheel": 轮毂资产id, "tire": 轮胎资产id, ...}，缺省项用默认轮毂 / 原厂胎 /
## 前后默认刹车盘。未来外观项（车漆等）在本 dict 加 key 扩展，本签名不变。
static func attach_visual(v: Vehicle, car_id: int, appearance := {}) -> bool:
	var body_id := str(car_id)   # 目录名即配表 id
	return attach(v, body_id,
			appearance.get("wheel", DEFAULT_HUB),
			appearance.get("tire", DEFAULT_TIRE),
			appearance.get("brake_front", DEFAULT_BRAKE_FRONT),
			appearance.get("brake_rear", DEFAULT_BRAKE_REAR))

static func attach(v: Vehicle, body_id: String, hub_id: String, tire_id: String,
		brake_front_id := DEFAULT_BRAKE_FRONT, brake_rear_id := DEFAULT_BRAKE_REAR) -> bool:
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

	# 轮毂/轮胎/刹车盘资产各自允许缺失：只挂存在的一侧，全缺才保留占位轮
	var hub := _load_wheel_part("wheels", hub_id, "hub.json", "HubVisual")
	var tire := _load_wheel_part("tires", tire_id, "tire.json", "TireVisual")
	var brake_front := _load_wheel_part("brakes", brake_front_id, "disc.json", "BrakeVisual")
	var brake_rear := _load_wheel_part("brakes", brake_rear_id, "disc.json", "BrakeVisual")

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


	# 齐边推导：优先轮毂外盘面（outer），无轮毂资产或缺元数据时退回胎侧（胎宽/2）；
	# 胎半径写入 vehicle 导出变量（入树前），由 initialize() 下发各物理轮
	var tire_width: float = tire.get("width", 0.2)
	v.front_tire_radius = tire.get("radius", 0.3)
	v.rear_tire_radius = tire.get("radius", 0.3)

	# 碰撞体：demo 占位凸包 → 按真实车壳包围盒重建的贴地底盘低盒
	# （须在胎半径写入后：盒底离地量以真实胎半径推算地面高度）
	_setup_collision(v, body_visual, v.front_tire_radius, float(front_axle["y"]))

	var hub_outer: float = hub.get("outer", 0.0)
	if hub.scene == null or hub_outer <= 0.0:
		hub_outer = tire_width * 0.5
	var hub_mid: float = hub.get("mid_x", 0.0)

	var half_axle_x := body_width - hub_outer
	for slot in SLOTS:
		var names: Array = SLOTS[slot]
		var ray: Node3D = v.get_node(names[0])
		var axle: Dictionary = front_axle if slot.begins_with("front") else rear_axle
		var sign_x := -1.0 if slot.ends_with("left") else 1.0
		ray.position = Vector3(sign_x * half_axle_x, float(axle["y"]), float(axle["z"]))
		var wheel_node: Node3D = ray.get_node(names[1])
		var old_mesh: Node3D = wheel_node.get_node_or_null(names[2])
		var brake := brake_front if slot.begins_with("front") else brake_rear
		if old_mesh:
			# 全缺才保留占位轮：任一真实轮件（轮毂/轮胎/刹车盘）挂上即隐藏占位
			old_mesh.visible = hub.scene == null and tire.scene == null \
					and brake.scene == null
		# 左侧轮位绕 Y 翻转 180°（轮件按外侧朝 +X 建模，翻转后左右盘面朝向正确）
		var side_flip := PI if sign_x < 0.0 else 0.0
		for part in [hub, tire]:
			if part.scene == null:
				continue
			var visual: Node3D = part.scene.instantiate()
			visual.name = part.node_name
			var local: Vector3 = -part.center
			if part == tire:
				# 套胎：胎中线对齐轮毂桶身几何中线（part 空间 +X 为外侧，随左右翻转）
				local.x += sign_x * hub_mid
			visual.position = local
			visual.rotation.y = side_flip
			wheel_node.add_child(visual)
			# 轮件 GLB 交付无贴图，挂上后统一替换为引擎侧固定材质（磨砂黑轮毂/橡胶胎）
			if part == hub:
				_WheelMaterials.apply_hub(visual)
			else:
				_WheelMaterials.apply_tire(visual)
		# 刹车盘（含卡钳）随悬挂与转向但不随轮自转：挂在物理轮下的 BrakePivot，
		# wheel.gd 每帧把悬挂 y 同步给它（卡钳随轮自转公转是明显穿帮）
		var wheel := ray as Wheel
		if brake.scene != null and wheel != null:
			var pivot := Node3D.new()
			pivot.name = "BrakePivot"
			pivot.rotation.y = side_flip
			ray.add_child(pivot)
			wheel.static_visual = pivot
			var disc: Node3D = brake.scene.instantiate()
			disc.name = brake.node_name
			disc.position = -brake.center
			pivot.add_child(disc)
			# 盘面固定亮面纯金属，卡钳材质保留 GLB 原样
			_WheelMaterials.apply_disc(disc)
	return true

## 占位 demo 凸包 → 贴地底盘低盒。地面高度 = 前轴 y − 胎半径（静态悬挂压缩后
## 车身原点到地面的距离，与 vehicle.initialize() 的轮位抬升推导一致）。
static func _setup_collision(v: Vehicle, body_visual: Node3D, tire_radius: float, front_axle_y: float) -> void:
	var bounds := _scene_aabb(body_visual)
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return   # 车壳无可测网格：保留占位凸包（与占位视觉本来就配套）
	var ground_y := front_axle_y - tire_radius
	var size := Vector3(
			maxf(0.8, bounds.size.x - COL_SKIN * 2.0),
			COL_HEIGHT,
			maxf(1.6, bounds.size.z - COL_SKIN * 2.0))
	var col := v.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null:
		col = CollisionShape3D.new()
		col.name = "CollisionShape3D"
		v.add_child(col)
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.transform = Transform3D(Basis(), Vector3(bounds.get_center().x,
			ground_y + COL_CLEARANCE + size.y * 0.5, bounds.get_center().z))

## 节点子树的本地包围盒（车身 GLB 入树前量尺寸用）：
## 逐 MeshInstance3D 的 mesh.get_aabb() 按累积 transform 变换后取并集，
## 无可见网格时返回负 size，由调用方识别。
static func _scene_aabb(root_node: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var stack: Array = [[root_node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node := top[0] as Node3D
		var xf: Transform3D = top[1] * node.transform
		if node is MeshInstance3D and node.visible and node.mesh != null:
			var mesh_aabb: AABB = xf * node.mesh.get_aabb()
			bounds = mesh_aabb if not has_bounds else bounds.merge(mesh_aabb)
			has_bounds = true
		for child in node.get_children():
			if child is Node3D:
				stack.append([child, xf])
	return bounds

## 读取 wheels/<id>/hub.json 或 tires/<id>/tire.json 一侧的资产描述：
## {scene: PackedScene(缺失为 null), center: Vector3, radius: float, width: float,
##  outer: float(原点→外盘面，仅轮毂), mid_x: float(原点→桶身几何中线，仅轮毂)}
static func _load_wheel_part(dir: String, asset_id: String, json_name: String, node_name: String) -> Dictionary:
	var out := {"scene": null, "center": Vector3.ZERO, "radius": 0.3, "width": 0.2,
			"outer": 0.0, "mid_x": 0.0, "node_name": node_name}
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
	out.outer = float(meta.get("outer", 0.0))
	out.mid_x = float(meta.get("mid_x", 0.0))
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
