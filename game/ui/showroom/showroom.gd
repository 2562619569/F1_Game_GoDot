extends Node3D
## 通用车辆展示间：中央展台展示当前车辆，按住左键拖拽可旋转展台，
## 底部一排按钮列出 Car 表全部车辆，点击即切换预览（左右方向键亦可循环切换）。
## 场景结构（灯光/地面/展台/背景幕/相机/顶栏/底栏）在 tscn 内搭建，脚本只负责补齐资源、
## 生成按钮与装配车辆 —— 配表加车不需要改本场景。
## 对外契约：car_selected(car_id) / close_requested 信号 + show_car(car_id) / car_ids()。

signal car_selected(car_id: int)
signal close_requested

@export var drag_sensitivity := 0.01        # 每像素拖拽的旋转弧度
@export var initial_car_id := 0             # 0 = 取 Car 表最小 id

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const BUTTON_SCENE := preload("res://game/ui/components/button_default.tscn")

## 摄影棚弧形幕布：暗灰哑光底色 + 以世界坐标 (‑7.8, 2.3, ‑7.8)（相机正对的车后墙面）
## 为中心的一枚柔光晕，代替纯黑虚空，给车身剪影一个有层次的背景
const BackdropShader := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 halo_center = vec3(-7.8, 2.3, -7.8);
uniform vec3 base_col = vec3(0.055, 0.060, 0.068);
uniform vec3 halo_col = vec3(0.170, 0.180, 0.200);
uniform float halo_radius = 7.5;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float t = 1.0 - smoothstep(0.0, halo_radius, distance(world_pos, halo_center));
	t = pow(t, 1.4);
	ALBEDO = base_col;
	EMISSION = halo_col * t;
	ROUGHNESS = 0.9;
}
"""

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
var _car: Vehicle = null        # 当前展车（静态道具：物理停用，拖拽纯旋转模型）
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
		# 按住期间捕获鼠标：快速甩动时光标冲出窗口或扫过底部按钮区
		# 会丢 motion 事件（表现为"拖不动"），捕获后事件只发给我们
		if _dragging:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _dragging and is_instance_valid(_car):
		_car.rotate_y(-event.relative.x * drag_sensitivity)
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var ids := car_ids()
		var i := ids.find(current_car_id)
		if i < 0:
			i = 0
		var step := 1 if event.is_action_pressed("ui_right") else -1
		show_car(ids[wrapi(i + step, 0, ids.size())])

## 窗口失焦时按钮抬起事件可能丢失，这里补一次拖拽复位，避免鼠标永久被捕获
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_end_drag()

func _exit_tree() -> void:
	_end_drag()  # 展示间被关闭时确保释放鼠标

func _end_drag() -> void:
	_dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

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

## 切换展台车辆：装配美术后立即转为静态道具（物理全停），直接摆放落座姿态
func show_car(car_id: int) -> void:
	if not Settings.car.data.has(car_id):
		push_warning("Showroom: Car 表无 %d，忽略切换" % car_id)
		return
	current_car_id = car_id
	if is_instance_valid(_car):
		_car.queue_free()
	var v: Vehicle = CAR_SCENE.instantiate()
	# 车前向为 -Z，相机在 (+4.2, +4.2) 象限，yaw 225° 让车头正对相机
	v.rotation = Vector3(0, deg_to_rad(225.0), 0)
	CarBuilder.apply(v, Settings.car.data[car_id], Match.get_stats(), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	CarMeshBuilder.attach_visual(v, car_id, Match.appearance())
	add_child(v)
	_car = v
	_make_static_display(v)
	var cfg: Dictionary = Settings.car.data[car_id]
	car_name_label.text = "%s  ·  %s  ·  %d kg" % [cfg.name, String(cfg.drive).to_upper(), int(cfg.weight)]
	car_desc_label.text = String(cfg.desc)
	for b in bottom_bar.get_children():
		b.set_pressed_no_signal(int(b.get_meta(&"car_id")) == car_id)
	car_selected.emit(car_id)

## 展示间不跑车辆物理：停掉 Vehicle 的悬挂/轮胎/传动/稳定计算并关掉重力，
## 车身按静态悬挂参数直接摆到落座高度，轮子视觉放到静载压缩位置。
## 之后拖拽旋转的就是一个纯视觉道具 —— 没有轮胎侧向力，天然不溜车，
## 也不依赖刚体 freeze 行为（此前冻结路径在不同环境下表现不稳定）。
func _make_static_display(v: Vehicle) -> void:
	v.set_physics_process(false)
	v.gravity_scale = 0.0
	v.linear_velocity = Vector3.ZERO
	v.angular_velocity = Vector3.ZERO
	for w in v.wheel_array:
		var resting := v.front_resting_ratio if v.front_axle.wheels.has(w) else v.rear_resting_ratio
		w.spring_current_length = w.spring_length * resting
	# 落座高度：台面 y=0.3 + 让较低的前/后轴轮胎底面正好贴台
	var front_bottom := v.front_left_wheel.position.y \
			- v.front_spring_length * v.front_resting_ratio - v.front_tire_radius
	var rear_bottom := v.rear_left_wheel.position.y \
			- v.rear_spring_length * v.rear_resting_ratio - v.rear_tire_radius
	v.position = Vector3(0, 0.3 - maxf(front_bottom, rear_bottom), 0)

# ---------------- 场景资源补齐（tscn 持结构，代码持资源） ----------------

func _setup_world() -> void:
	if world_env.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.022, 0.027)   # 幕墙外的兜底色，接近墙基色
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.10, 0.12, 0.17)   # 冷调极弱环境补光，保住暗部细节
		env.ambient_light_energy = 0.25
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.glow_enabled = true                           # 刹车灯/发光件微辉光
		env.glow_intensity = 0.4
		env.ssao_enabled = true                           # 车轮/展台接地暗影
		env.ssao_intensity = 2.0
		env.ssao_radius = 0.8
		env.ssr_enabled = true                            # 抛光地板反射车身
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.fog_enabled = true                            # 淡雾柔化墙地接缝与纵深
		env.fog_light_color = Color(0.03, 0.034, 0.04)
		env.fog_density = 0.015
		world_env.environment = env
	if ground.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(24, 24)
		ground.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.02, 0.021, 0.026)     # 黑色抛光棚地，靠反射和光池塑形
		mat.roughness = 0.05
		mat.metallic = 0.8
		ground.material_override = mat
	_setup_lights()
	_setup_reflection_probe()
	_setup_ground_collision()
	_setup_platform()
	_setup_backdrop()
	camera.fov = 55.0                                    # 收窄视野出产品摄影感
	camera.look_at(Vector3(0, 0.5, 0))

## 布光：车辆摄影棚灯组 —— Key 主灯（暖白柔光、唯一投影源）打亮车头车身，
## Fill 补灯（冷色弱光、无影）抬暗部，RimL/RimR 轮廓灯（背后两侧、窄光束）
## 勾出车侧剪影边缘，Top 顶灯给车顶一条高光。环境光压得很低，明暗对比靠灯组。
func _setup_lights() -> void:
	sun.visible = false                                 # 展厅不用日光，全部走棚灯
	if get_node_or_null("StudioLights") != null:
		return
	var rig := Node3D.new()
	rig.name = "StudioLights"
	add_child(rig)
	var key := _make_studio_spot("Key", Vector3(-5.0, 5.5, 5.0), Color(1.0, 0.97, 0.9), 6.0, 42.0, 20.0)
	key.shadow_enabled = true
	key.shadow_blur = 3.0                               # 柔光箱式的软阴影
	rig.add_child(key)
	rig.add_child(_make_studio_spot("Fill", Vector3(5.5, 3.0, 5.5), Color(0.72, 0.8, 1.0), 2.0, 55.0, 18.0))
	rig.add_child(_make_studio_spot("RimL", Vector3(-5.5, 3.5, -5.0), Color(0.8, 0.9, 1.0), 9.0, 26.0, 18.0))
	rig.add_child(_make_studio_spot("RimR", Vector3(5.5, 3.5, -5.0), Color(1.0, 0.93, 0.85), 9.0, 26.0, 18.0))
	rig.add_child(_make_studio_spot("Top", Vector3(0, 7.0, 0.6), Color(1.0, 1.0, 1.0), 3.0, 65.0, 16.0))

func _make_studio_spot(spot_name: String, pos: Vector3, color: Color, energy: float, angle_deg: float, range_m: float) -> SpotLight3D:
	var s := SpotLight3D.new()
	s.name = spot_name
	s.look_at_from_position(pos, Vector3(0, 0.5, 0))     # 未入树节点要用 look_at_from_position；一律指向展车中心
	s.light_color = color
	s.light_energy = energy
	s.spot_angle = angle_deg
	s.spot_range = range_m
	s.spot_angle_attenuation = 2.0                       # 光束边缘柔和衰减
	return s

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

## 中央展台：带碰撞的矮圆柱（深色石墨低粗糙度），车直接落到台面上；侧缘一圈发光环
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
	mat.albedo_color = Color(0.05, 0.052, 0.06)        # 石墨展台，暗棚里靠灯光勾形
	mat.roughness = 0.12
	mat.metallic = 0.4
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
	rmat.emission = Color(1, 0.98, 0.94)
	rmat.emission_energy_multiplier = 2.0
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

## 环形背景幕布（cyc 墙）：直径 22m 的开口圆柱围住全场，墙基贴合地面。
## 墙面自身近黑哑光，唯一读得出来的层次是车后那枚烘焙进 shader 的柔光晕，
## 棚灯余光扫过时墙面另有极弱的受光渐变，地板 SSR 会把光晕映回地面。
func _setup_backdrop() -> void:
	if get_node_or_null("Backdrop") != null:
		return
	var backdrop := Node3D.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)
	var wall := MeshInstance3D.new()
	wall.name = "Wall"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 11.0
	cylinder.bottom_radius = 11.0
	cylinder.height = 8.0
	cylinder.radial_segments = 64
	wall.mesh = cylinder
	wall.position = Vector3(0, 4.0, 0)
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = BackdropShader
	mat.shader = shader
	wall.material_override = mat
	backdrop.add_child(wall)

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
