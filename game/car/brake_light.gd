class_name BrakeLight
extends Node3D
## 刹车灯视觉层：按 body.json 的 materials.brake_light 在车壳 GLB 中按材质名找到刹车灯网格，
## 复制材质并点亮红色自发光（未刹车时保持示宽灯微亮），刹车时经弹簧阻尼平滑升至高亮，
## 并在灯组包围盒中心挂一盏红色 OmniLight3D 增强可见度。纯表现层，不改任何物理量。
## GLB 实例间共享材质资源，必须 duplicate 出每车独立副本，否则多车互相串色。

@export_group("发光")
@export var brake_color := Color(1.0, 0.08, 0.05)
## 未刹车时的示位灯亮度（0 = 熄灭）
@export var idle_energy := 0.15
## 满刹车时的自发光强度
@export var braking_energy := 2.5

@export_group("弹簧（响应频率 Hz / 阻尼比）")
@export var frequency := 10.0
@export var damping_ratio := 1.0

@export_group("附加点光")
@export var light_gain := 0.8

const _SpringDamper := preload("res://game/car/spring_damper.gd")

var _vehicle: Vehicle
var _materials: Array[StandardMaterial3D] = []
var _light: OmniLight3D
var _energy := 0.0
var _energy_vel := 0.0

## 由 CarMeshBuilder 在装配时调用；body_visual 为本节点父节点（材质在其中查找）。
## materials_meta 为 body.json 的 materials 字段；brake_light 为空或找不到材质则自动移除本节点。
func setup(v: Vehicle, body_visual: Node, materials_meta: Dictionary) -> void:
	_vehicle = v
	var wanted := str(materials_meta.get("brake_light", "")).strip_edges()
	if wanted.is_empty():
		_detach("body.json 未标记刹车灯材质")
		return
	_collect(body_visual, wanted)
	if _materials.is_empty():
		_detach("车壳中未找到刹车灯材质「%s」" % wanted)
		return
	for m in _materials:
		m.emission_enabled = true
		m.emission = brake_color
		m.emission_energy_multiplier = idle_energy
	_energy = idle_energy
	_light = _make_light()

func _process(delta: float) -> void:
	if not _vehicle:
		return
	# 刹车量取脚刹与手刹的较大者（手刹同样点亮刹车灯）
	var amount: float = maxf(_vehicle.brake_amount, _vehicle.handbrake_input)
	var target: float = idle_energy + amount * (braking_energy - idle_energy)
	var s := _SpringDamper.spring(_energy, _energy_vel, target, frequency, damping_ratio, delta)
	_energy = s.x
	_energy_vel = s.y
	for m in _materials:
		m.emission_energy_multiplier = _energy
	if _light:
		_light.light_energy = maxf(0.0, (_energy - idle_energy) * light_gain)

## 供测试场景核对状态（材质命中数 / 当前自发光强度 / 是否挂了点光）
func debug_info() -> Dictionary:
	return {"materials": _materials.size(), "energy": _energy, "light": _light != null}

## 在 body_visual 子树内按材质名收集网格表面材质（大小写不敏感精确匹配，退化到子串匹配）。
## 每个原材质只复制一份；用 surface_set_material 写回，避免改动共享的原资源。
func _collect(body_visual: Node, wanted: String) -> void:
	var wanted_lower := wanted.to_lower()
	var duplicates := {}   # 原材质 instance_id -> 副本（多表面/多网格共享同一副本）
	for mi in body_visual.find_children("*", "MeshInstance3D"):
		var mesh := mi.mesh as ArrayMesh
		var any_hit := false
		if mesh:
			for i in mesh.get_surface_count():
				var dup := _dup_if_match(mesh.surface_get_material(i), wanted_lower, duplicates)
				if dup:
					mesh.surface_set_material(i, dup)
					any_hit = true
		var ov := _dup_if_match(mi.material_override, wanted_lower, duplicates)
		if ov:
			mi.material_override = ov
			any_hit = true
		if any_hit:
			_track_bounds(body_visual, mi)

func _dup_if_match(mat: Material, wanted_lower: String, duplicates: Dictionary) -> StandardMaterial3D:
	if mat == null or not (mat is StandardMaterial3D):
		return null
	# Material 是 Resource，名字属性为 resource_name（Node 才是 name）
	var name_lower := str(mat.resource_name).to_lower()
	if name_lower != wanted_lower and not name_lower.contains(wanted_lower):
		return null
	var id := mat.get_instance_id()
	if not duplicates.has(id):
		var dup := mat.duplicate() as StandardMaterial3D
		duplicates[id] = dup
		_materials.append(dup)
	return duplicates[id]

var _bounds: AABB

func _track_bounds(ancestor: Node, mi: MeshInstance3D) -> void:
	# 车辆入树前装配，global_transform 不可用：沿父链拼出相对 ancestor 的局部变换
	var xf := Transform3D.IDENTITY
	var cur: Node3D = mi
	while cur and cur != ancestor:
		xf = cur.transform * xf
		cur = cur.get_parent() as Node3D
	var aabb := xf * mi.get_aabb()
	if _bounds.size == Vector3.ZERO:
		_bounds = aabb
	else:
		_bounds = _bounds.merge(aabb)

func _make_light() -> OmniLight3D:
	# BrakeLight 是 body_visual 直接子节点，灯组包围盒中心即本节点原点，灯挂本节点名下随之移动
	position = _bounds.get_center()
	var light := OmniLight3D.new()
	light.name = "Glow"
	light.light_color = brake_color
	light.omni_range = maxf(0.6, _bounds.size.length() * 0.9)
	light.light_energy = 0.0
	light.shadow_enabled = false
	add_child(light)
	return light

func _detach(reason: String) -> void:
	push_warning("BrakeLight: " + reason + "，刹车灯停用")
	set_process(false)
	queue_free()
