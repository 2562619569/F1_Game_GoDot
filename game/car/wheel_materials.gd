class_name WheelMaterials
extends RefCounted
## 引擎侧轮件固定材质：轮件 GLB 交付不带贴图（灰模），运行时统一替换——
##   轮胎   橡胶    — albedo 取实测橡胶反射率 0.023 略提亮（纯黑会丢高光细节），
##                    金属度 0、高粗糙漫反射（胎面磨损橡胶 0.8–0.95）
##   轮毂   磨砂黑  — 深底色金属（0.6–0.8 粗糙的暗金属）：只有边缘反射环境，
##                    呈粉末涂装的磨砂质感；底色同样避开纯黑
##   刹车盘 亮面纯金属 — 不锈钢 F0 实测值 (0.669, 0.639, 0.598)、低粗糙镜面
##                    反射（抛光摩擦面 0.1–0.2），金属度 1 纯金属
## 参数来源：physicallybased.info 实测库 + PBR 材质工作流通识（见各常量注释）。
## 卡钳保留 GLB 原材质不改：按材质名识别（kaqian / 卡钳 / caliper）。
## 三材质为全车共享单例；替换用 material_override / surface_override_material，
## 不改动 GLB 导入的共享网格资源，多车实例互不影响。

## 卡钳材质名识别（GLB 内材质名：kaqian / kaqian.001 …，大小写不敏感）
const CALIPER_HINTS := ["kaqian", "卡钳", "caliper"]

static var _tire_mat: StandardMaterial3D
static var _hub_mat: StandardMaterial3D
static var _disc_mat: StandardMaterial3D

static func apply_tire(root: Node) -> void:
	_override_all(root, get_tire_mat())

static func apply_hub(root: Node) -> void:
	_override_all(root, get_hub_mat())

static func apply_disc(root: Node) -> void:
	## 只替换盘面表面；卡钳表面（按 GLB 材质名识别）保留原样
	for mi in root.find_children("*", "MeshInstance3D"):
		var mesh_mi := mi as MeshInstance3D
		if mesh_mi.mesh == null:
			continue
		for i in mesh_mi.mesh.get_surface_count():
			var src: Material = mesh_mi.mesh.surface_get_material(i)
			if src != null and is_caliper(str(src.resource_name)):
				continue
			mesh_mi.set_surface_override_material(i, get_disc_mat())

static func is_caliper(mat_name: String) -> bool:
	if mat_name.is_empty():
		return false
	var lower := mat_name.to_lower()
	return lower.contains(CALIPER_HINTS[0]) or lower.contains(CALIPER_HINTS[1]) \
			or lower.contains(CALIPER_HINTS[2])

static func get_tire_mat() -> StandardMaterial3D:
	if _tire_mat == null:
		_tire_mat = StandardMaterial3D.new()
		_tire_mat.resource_name = "wheel_tire_rubber"
		_tire_mat.albedo_color = Color(0.028, 0.028, 0.028)
		_tire_mat.metallic = 0.0
		_tire_mat.roughness = 0.9
	return _tire_mat

static func get_hub_mat() -> StandardMaterial3D:
	if _hub_mat == null:
		_hub_mat = StandardMaterial3D.new()
		_hub_mat.resource_name = "wheel_hub_matte_black"
		_hub_mat.albedo_color = Color(0.045, 0.045, 0.05)
		_hub_mat.metallic = 1.0
		_hub_mat.roughness = 0.65
	return _hub_mat

static func get_disc_mat() -> StandardMaterial3D:
	if _disc_mat == null:
		_disc_mat = StandardMaterial3D.new()
		_disc_mat.resource_name = "wheel_disc_polished_steel"
		_disc_mat.albedo_color = Color(0.669, 0.639, 0.598)
		_disc_mat.metallic = 1.0
		_disc_mat.roughness = 0.15
	return _disc_mat

static func _override_all(root: Node, mat: Material) -> void:
	for mi in root.find_children("*", "MeshInstance3D"):
		(mi as GeometryInstance3D).material_override = mat
