extends Node3D
## 通用车辆展示间：中央展台展示当前车辆，按住左键拖拽可旋转展台，
## 底部一排按钮列出 Car 表全部车辆，点击即切换预览（左右方向键亦可循环切换）。
## 场景结构（灯光/地面/展台/相机/顶栏/底栏）在 tscn 内搭建，脚本只负责补齐资源、
## 生成按钮与装配车辆 —— 配表加车不需要改本场景。
## 对外契约：car_selected(car_id) / close_requested 信号 + show_car(car_id) / car_ids()。

signal car_selected(car_id: int)
signal close_requested

@export var drag_sensitivity := 0.01        # 每像素拖拽的旋转弧度
@export var initial_car_id := 0             # 0 = 取 Car 表最小 id

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const BUTTON_SCENE := preload("res://game/ui/components/button_default.tscn")

@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var ground: MeshInstance3D = $Ground
@onready var turntable: Node3D = $Turntable
@onready var camera: Camera3D = $Camera3D
@onready var car_name_label: Label = $UI/Root/CarName
@onready var car_desc_label: Label = $UI/Root/CarDesc
@onready var bottom_bar: HBoxContainer = $UI/Root/BottomBar
@onready var close_btn: Button = $UI/Root/CloseButton

var current_car_id := 0
var _car: Vehicle = null        # 当前展车（自由刚体，落在展台上）
var _group := ButtonGroup.new()
var _dragging := false

func _ready() -> void:
	_setup_world()
	_setup_buttons()
	close_btn.pressed.connect(_on_close)
	var first := initial_car_id if initial_car_id > 0 else car_ids()[0]
	show_car(first)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging and is_instance_valid(_car):
		# 刚体不宜挂在旋转的父节点下，改为绕自身中心旋转车体（转台效果）
		_car.rotate_y(-event.relative.x * drag_sensitivity)
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var ids := car_ids()
		var i := ids.find(current_car_id)
		if i < 0:
			i = 0
		var step := 1 if event.is_action_pressed("ui_right") else -1
		show_car(ids[wrapi(i + step, 0, ids.size())])

func _on_close() -> void:
	if close_requested.has_connections():
		close_requested.emit()
	else:
		get_tree().quit()  # 独立运行（未嵌入流程）时直接退出

## Car 表全部 id 升序（601~603，配表扩车自动生效）
func car_ids() -> Array[int]:
	var ids: Array[int] = []
	for cid in Settings.car.data.keys():
		ids.append(int(cid))
	ids.sort()
	return ids

## 切换展台车辆：重新装配美术与物理参数，不冻结，让车落到展台上自然沉降
func show_car(car_id: int) -> void:
	if not Settings.car.data.has(car_id):
		push_warning("Showroom: Car 表无 %d，忽略切换" % car_id)
		return
	current_car_id = car_id
	if is_instance_valid(_car):
		_car.queue_free()
	var v: Vehicle = CAR_SCENE.instantiate()
	v.position = Vector3(0, 1.0, 0)
	CarBuilder.apply(v, Settings.car.data[car_id], Match.get_stats(), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	CarMeshBuilder.attach_visual(v, car_id, Match.appearance())
	add_child(v)
	_car = v
	var cfg: Dictionary = Settings.car.data[car_id]
	car_name_label.text = "%s  ·  %s  ·  %d kg" % [cfg.name, String(cfg.drive).to_upper(), int(cfg.weight)]
	car_desc_label.text = String(cfg.desc)
	for b in bottom_bar.get_children():
		b.set_pressed_no_signal(int(b.get_meta(&"car_id")) == car_id)
	car_selected.emit(car_id)

# ---------------- 场景资源补齐（tscn 持结构，代码持资源） ----------------

func _setup_world() -> void:
	if world_env.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.82, 0.85, 0.88)   # 明亮极简：浅灰蓝底
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.85, 0.87, 0.9)
		env.ambient_light_energy = 1.0
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.glow_enabled = true                           # 刹车灯/发光件微辉光
		env.glow_intensity = 0.2
		env.ssao_enabled = true                           # 车轮/展台接地暗影
		env.ssao_intensity = 1.5
		env.ssao_radius = 0.8
		env.ssr_enabled = true                            # 抛光地板反射车身
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.fog_enabled = true                            # 淡雾把地板边缘融进背景
		env.fog_light_color = Color(0.82, 0.85, 0.88)
		env.fog_density = 0.035
		world_env.environment = env
	if ground.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(24, 24)
		ground.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.68, 0.70, 0.73)       # 浅灰抛光地坪
		mat.roughness = 0.08
		mat.metallic = 0.2
		ground.material_override = mat
	_setup_lights()
	_setup_reflection_probe()
	_setup_ground_collision()
	_setup_platform()
	camera.fov = 55.0                                    # 收窄视野出产品摄影感
	camera.look_at(Vector3(0, 0.5, 0))

## 布光：Sun 主光（浅暖白）+ Fill 补光（冷色、无阴影）柔化暗部
func _setup_lights() -> void:
	sun.light_color = Color(1.0, 0.98, 0.95)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	if get_node_or_null("Fill") != null:
		return
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-30, 150, 0)
	fill.light_color = Color(0.85, 0.9, 1.0)
	fill.light_energy = 0.35
	fill.shadow_enabled = false
	add_child(fill)

## 反射探针：金属漆/玻璃/抛光地板获得真实环境反射（静态展厅烘焙一次够用）
func _setup_reflection_probe() -> void:
	if get_node_or_null("ReflectionProbe") != null:
		return
	var probe := ReflectionProbe.new()
	probe.name = "ReflectionProbe"
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.size = Vector3(24, 10, 24)
	probe.position = Vector3(0, 4, 0)
	probe.box_projection = true
	add_child(probe)

## 地面静态碰撞：车万一滑出展台也不会无限坠落
func _setup_ground_collision() -> void:
	if ground.get_node_or_null(^"GroundBody") != null:
		return
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	body.add_child(shape)
	ground.add_child(body)

## 中央展台：带碰撞的矮圆柱（白色低粗糙度），车直接落到台面上；侧缘一圈发光环
func _setup_platform() -> void:
	if turntable.get_child_count() > 0:
		return
	var body := StaticBody3D.new()
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 3.0
	cylinder.bottom_radius = 3.0
	cylinder.height = 0.3
	mesh.mesh = cylinder
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.86, 0.88)
	mat.roughness = 0.1
	mat.metallic = 0.1
	mesh.material_override = mat
	var ring := MeshInstance3D.new()
	ring.name = "GlowRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 3.05
	torus.outer_radius = 3.13
	ring.mesh = torus
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(1, 1, 1)
	rmat.emission_enabled = true
	rmat.emission = Color(1, 1, 1)
	rmat.emission_energy_multiplier = 1.6
	ring.material_override = rmat
	ring.position = Vector3(0, -0.16, 0)  # 贴地环绕展台侧缘
	var shape := CollisionShape3D.new()
	shape.shape = CylinderShape3D.new()
	shape.shape.radius = 3.0
	shape.shape.height = 0.3
	body.add_child(mesh)
	body.add_child(ring)
	body.add_child(shape)
	body.position = Vector3(0, 0.15, 0)  # 台面在 y=0.3
	turntable.add_child(body)

func _setup_buttons() -> void:
	for child in bottom_bar.get_children():
		child.queue_free()
	for cid in car_ids():
		var b: Button = BUTTON_SCENE.instantiate()
		b.text = String(Settings.car.data[cid].name)
		b.toggle_mode = true
		b.button_group = _group
		b.custom_minimum_size = Vector2(180, 52)
		b.add_theme_font_size_override("font_size", 18)
		b.set_meta(&"car_id", cid)
		b.pressed.connect(show_car.bind(cid))
		bottom_bar.add_child(b)
