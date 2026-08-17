class_name CarStage
extends Node3D
## 通用 3D 车辆展台（摄影棚布光 + 环形幕布 + 中央转台）：
## 从 showroom 抽出的可复用组件，选车界面 / 局间整备 / 展示间共享同一套视觉。
## 场景结构（环境/地面/展台/相机）在 tscn 内搭建，脚本负责补齐资源与装配展车。
## 对外契约：car_shown(car_id) 信号 + show_car(car_id) / refresh_car() / car_ids() / current_car_id。
## framing 决定构图：CENTER 车辆居中；LEFT 视点右移让车落在画面左侧（右侧留给悬浮 UI）。

signal car_shown(car_id: int)

enum Framing { CENTER, LEFT }

@export var framing: Framing = Framing.CENTER
@export var drag_sensitivity := 0.01        # 每像素拖拽的旋转弧度
@export var focus_shift_m := 2.6            # LEFT 构图：视点沿相机右方向平移的米数

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const FOCUS := Vector3(0, 0.5, 0)           # 展车中心，所有棚灯/相机对准这里

## 摄影棚弧形幕布：暗灰哑光底色 + 以世界坐标 (‑7.8, 2.3, ‑7.8)（相机正对的车后墙面）
## 为中心的一枚柔光晕，代替纯黑虚空，给车身剪影一个有层次的背景
const BackdropShader := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 halo_center = vec3(-7.8, 2.3, -7.8);
uniform vec3 base_col = vec3(0.075, 0.080, 0.090);
uniform vec3 halo_col = vec3(0.200, 0.210, 0.230);
uniform float halo_radius = 9.0;
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
@onready var camera: Camera3D = $Camera3D

var current_car_id := 0
var _car: Vehicle = null        # 当前展车（静态道具：物理停用，拖拽纯旋转模型）
var _dragging := false

func _ready() -> void:
	_setup_world()
	_apply_framing()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		# 按住期间捕获鼠标：快速甩动时光标冲出窗口或扫过悬浮 UI 区
		# 会丢 motion 事件（表现为"拖不动"），捕获后事件只发给我们
		if _dragging:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _dragging and is_instance_valid(_car):
		_car.rotate_y(-event.relative.x * drag_sensitivity)

## 窗口失焦时按钮抬起事件可能丢失，这里补一次拖拽复位，避免鼠标永久被捕获
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_end_drag()

func _exit_tree() -> void:
	_end_drag()  # 展台随宿主界面关闭时确保释放鼠标

func _end_drag() -> void:
	_dragging = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ---------------- 展车装配 ----------------

## Car 表全部 id 升序（601~603，配表扩车自动生效）
func car_ids() -> Array[int]:
	var ids: Array[int] = []
	for cid in Settings.car.data.keys():
		ids.append(int(cid))
	ids.sort()
	return ids

## 切换展台车辆（保留当前朝向，首次展示车头正对相机）
func show_car(car_id: int) -> void:
	if not Settings.car.data.has(car_id):
		push_warning("CarStage: Car 表无 %d，忽略切换" % car_id)
		return
	var yaw := _car.rotation.y if is_instance_valid(_car) else deg_to_rad(225.0)
	_build_car(car_id, yaw)
	car_shown.emit(car_id)

## 改装/换装后重装配当前车（外观件跟随 Match.equipped / cosmetics 变化）
func refresh_car() -> void:
	if current_car_id == 0 or not Settings.car.data.has(current_car_id):
		return
	var yaw := _car.rotation.y if is_instance_valid(_car) else deg_to_rad(225.0)
	_build_car(current_car_id, yaw)

func _build_car(car_id: int, yaw: float) -> void:
	if is_instance_valid(_car):
		_car.queue_free()
	var v: Vehicle = CAR_SCENE.instantiate()
	# 车前向为 -Z，相机在 (+4.2, +4.2) 象限，yaw 225° 让车头正对相机
	v.rotation = Vector3(0, yaw, 0)
	CarBuilder.apply(v, Settings.car.data[car_id], Match.stats_for_car(car_id, Match.equipped), WeatherEnv.cfg(WeatherEnv.Type.SUNNY), 1.0)
	CarMeshBuilder.attach_visual(v, car_id, Match.appearance_for_car(car_id, Match.equipped))
	add_child(v)
	_car = v
	_make_static_display(v)
	current_car_id = car_id

## 展台不跑车辆物理：停掉 Vehicle 的悬挂/轮胎/传动/稳定计算并关掉重力，
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

# ---------------- 相机构图 ----------------

## 收窄视野出产品摄影感；LEFT 构图先把相机对中取得右方向，再把视点右移，
## 车辆随之落到画面左三分之一（右侧整块留给悬浮 UI）
func _apply_framing() -> void:
	camera.fov = 55.0
	camera.look_at(FOCUS)
	if framing == Framing.LEFT:
		var right := camera.global_transform.basis.x
		camera.look_at(FOCUS + right * focus_shift_m)

# ---------------- 场景资源补齐（tscn 持结构，代码持资源） ----------------

func _setup_world() -> void:
	if world_env.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.022, 0.027)   # 幕墙外的兜底色，接近墙基色
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.10, 0.12, 0.17)   # 冷调极弱环境补光，保住暗部细节
		env.ambient_light_energy = 0.35
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.glow_enabled = true                           # 刹车灯/展台发光环加色辉光
		env.glow_intensity = 0.6
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		env.glow_hdr_threshold = 1.0
		env.glow_bloom = 0.1
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
	_setup_softboxes()
	_setup_reflection_probe()
	_setup_ground_collision()
	_setup_platform()
	_setup_backdrop()

## 布光：车辆摄影棚灯组 —— Key 主灯（暖白柔光、唯一投影源）打亮车头车身，
## Fill 补灯（冷色弱光、无影）抬暗部，RimL/RimR 轮廓灯（背后两侧、窄光束）
## 勾出车侧剪影边缘，Top 顶灯给车顶一条高光。环境光压得很低，明暗对比靠灯组。
## 射灯刻意收着（能量低、锥角宽）：硬热点交给漆面反射会炸成光斑，
## 车身的高光线条由 _setup_softboxes 的长条柔光箱提供。
func _setup_lights() -> void:
	sun.visible = false                                 # 展厅不用日光，全部走棚灯
	if get_node_or_null("StudioLights") != null:
		return
	var rig := Node3D.new()
	rig.name = "StudioLights"
	add_child(rig)
	var key := _make_studio_spot("Key", Vector3(-5.0, 5.5, 5.0), Color(1.0, 0.97, 0.9), 4.5, 55.0, 20.0)
	key.shadow_enabled = true
	key.shadow_blur = 4.0                               # 柔光箱式的软阴影
	rig.add_child(key)
	rig.add_child(_make_studio_spot("Fill", Vector3(5.5, 3.0, 5.5), Color(0.72, 0.8, 1.0), 3.0, 65.0, 18.0))
	rig.add_child(_make_studio_spot("RimL", Vector3(-5.5, 3.5, -5.0), Color(0.8, 0.9, 1.0), 6.0, 32.0, 18.0))
	rig.add_child(_make_studio_spot("RimR", Vector3(5.5, 3.5, -5.0), Color(1.0, 0.93, 0.85), 6.0, 32.0, 18.0))
	rig.add_child(_make_studio_spot("Top", Vector3(0, 7.0, 0.6), Color(1.0, 1.0, 1.0), 2.5, 75.0, 16.0))

func _make_studio_spot(spot_name: String, pos: Vector3, color: Color, energy: float, angle_deg: float, range_m: float) -> SpotLight3D:
	var s := SpotLight3D.new()
	s.name = spot_name
	s.look_at_from_position(pos, FOCUS)                  # 未入树节点要用 look_at_from_position；一律指向展车中心
	s.light_color = color
	s.light_energy = energy
	s.spot_angle = angle_deg
	s.spot_range = range_m
	s.spot_angle_attenuation = 2.0                       # 光束边缘柔和衰减
	return s

## 顶部长条柔光箱：大面发光板不直接出光（无 GI），而是进反射探针与漆面反射——
## 金属清漆沿车身拉出连续的高光光带（汽车棚拍质感的核心来源），同时给朝前偏下的
## 面板（前保险杠等）提供可反射的亮面，消除「同材质面板整块发暗」的色差。
## 板背面对相机方向剔除不可见，画面里只见漆面上的反射不见白板本体。
func _setup_softboxes() -> void:
	if get_node_or_null("Softboxes") != null:
		return
	var rig := Node3D.new()
	rig.name = "Softboxes"
	add_child(rig)
	var along := Vector3(0.707, 0.0, 0.707)               # 车头朝向（展车 yaw 225°）
	var side_v := Vector3(-along.z, 0.0, along.x)         # 车身横向
	for side in [-1.0, 1.0]:
		var holder := Node3D.new()
		var pos: Vector3 = side_v * side * 1.8 + Vector3(0, 5.0, 0)
		holder.look_at_from_position(pos, FOCUS)                # -Z 指向展车；up=Y 时长度边自动沿车身
		var bar := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(7.0, 1.3)                   # 7m 沿车身、1.3m 横向的长条发光面
		bar.mesh = plane
		bar.rotation_degrees.x = -90.0                   # PlaneMesh +Y 法线转到 -Z，正对展车
		var mat := StandardMaterial3D.new()
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.98, 0.94)
		mat.emission_energy_multiplier = 3.5
		bar.material_override = mat
		holder.add_child(bar)
		rig.add_child(holder)

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
	var turntable := $Turntable
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
