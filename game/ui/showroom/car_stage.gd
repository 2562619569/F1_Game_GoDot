class_name CarStage
extends Node3D
## 通用 3D 车辆展台（工业车库布景 + 电影化棚灯）：
## 从 showroom 抽出的可复用组件，选车界面 / 局间整备 / 展示间共享同一套视觉。
## 场景结构（环境/地面/展台/相机）在 tscn 内搭建，脚本负责补齐资源与装配展车。
## 布景已烘焙为 tscn 实际节点（用 game/testing/car_stage_bake.tscn 生成，编辑器所见即所得）；
## _setup_world 只作兜底——节点被误删时按代码重建。改了布景代码后重跑烘焙场景同步进 tscn。
## PreviewCar601 是烘焙进去的编辑器预览车，_ready 时清掉，让位给 show_car 装配的真车。
## 对外契约：car_shown(car_id) 信号 + show_car(car_id) / refresh_car() / car_ids() / current_car_id。
## framing 决定构图：CENTER 车辆居中；LEFT 视点右移让车落在画面左侧（右侧留给悬浮 UI）。
## 默认展示角度由场景定义：Camera3D 的机位（位置/FOV 原样生效，运行时只补对焦朝向）
## 与 PreviewCar601 的朝向（_ready 读取后清掉预览车，真车首次展示沿用该朝向）；
## default_car_yaw_deg 只是烘焙时预览车的初始摆位与无预览车时的兜底。
## 车库后墙自动转到相机对侧，机位挪到哪个方向布景都成立。

signal car_shown(car_id: int)

enum Framing { CENTER, LEFT }

@export var framing: Framing = Framing.CENTER
@export var drag_sensitivity := 0.01        # 每像素拖拽的旋转弧度
@export var focus_shift_m := 2.6            # LEFT 构图：视点沿相机右方向平移的米数
@export var default_car_yaw_deg := 225.0    # 烘焙预览车的初始摆位；无预览车时的首展朝向兜底

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const FOCUS := Vector3(0, 0.65, 0)          # 展车中心，所有棚灯/相机对准这里
const BACKDROP_DIST := 6.79                 # 后墙离展车中心的距离，背对相机摆放
const DISPLAY_FLOOR_Y := 0.035

@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var ground: MeshInstance3D = $Ground
@onready var camera: Camera3D = $Camera3D

var current_car_id := 0
var interactive := true             # 过渡开始后忽略拖拽输入
var _car: Vehicle = null        # 当前展车（静态道具：物理停用，拖拽纯旋转模型）
var _default_yaw := 0.0         # 首展默认朝向（_ready 取自场景预览展车的实际旋转）
var _dragging := false

func _ready() -> void:
	# 场景里的预览展车定义默认展示角度：记下它的朝向再清掉，让位给 show_car
	# 装配的真车（首次展示沿用该朝向；没有预览车时退回 default_car_yaw_deg）
	_default_yaw = deg_to_rad(default_car_yaw_deg)
	for child in get_children():
		if child is Vehicle and not child.is_queued_for_deletion():
			_default_yaw = child.rotation.y
			child.queue_free()
			break
	_setup_world()
	_apply_framing()
	_orient_backdrop()

func _unhandled_input(event: InputEvent) -> void:
	if not interactive:
		return
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

## 玩家可选底盘 id 升序（601~603，配表扩车自动生效；NPC 交通车段 ≥700 不进展台）
func car_ids() -> Array[int]:
	var ids: Array[int] = []
	for cid in Settings.car.data.keys():
		if int(cid) < Match.NPC_ID_BASE:
			ids.append(int(cid))
	ids.sort()
	return ids

## 切换展台车辆（保留当前朝向，首次展示沿用场景预览车的默认朝向）
func show_car(car_id: int) -> void:
	if not Settings.car.data.has(car_id):
		push_warning("CarStage: Car 表无 %d，忽略切换" % car_id)
		return
	var yaw := _car.rotation.y if is_instance_valid(_car) else _default_yaw
	_build_car(car_id, yaw)
	car_shown.emit(car_id)

## 改装/换装后重装配当前车（外观件跟随 Match.equipped / cosmetics 变化）
func refresh_car() -> void:
	if current_car_id == 0 or not Settings.car.data.has(current_car_id):
		return
	var yaw := _car.rotation.y if is_instance_valid(_car) else _default_yaw
	_build_car(current_car_id, yaw)

func _build_car(car_id: int, yaw: float) -> void:
	if is_instance_valid(_car):
		_car.queue_free()
	var v: Vehicle = CAR_SCENE.instantiate()
	# 车前向为 -Z；默认 yaw 让车头正对默认机位，机位/朝向都在编辑器里可调
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
	# 落座高度：让较低的前/后轴轮胎底面贴住混凝土地坪。
	var front_bottom := v.front_left_wheel.position.y \
			- v.front_spring_length * v.front_resting_ratio - v.front_tire_radius
	var rear_bottom := v.rear_left_wheel.position.y \
			- v.rear_spring_length * v.rear_resting_ratio - v.rear_tire_radius
	v.position = Vector3(0, DISPLAY_FLOOR_Y - maxf(front_bottom, rear_bottom), 0)

# ---------------- 相机构图 ----------------

## 相机位置/FOV 完全由 tscn 的 Camera3D 节点决定（编辑器里直接摆机位），这里只补对焦：
## 居中看车并微俯。LEFT 构图先把相机对中取得右方向，再把视点右移，
## 车辆随之落到画面左三分之一（右侧整块留给悬浮 UI）
func _apply_framing() -> void:
	camera.look_at(FOCUS)
	if framing == Framing.LEFT:
		var right := camera.global_transform.basis.x
		camera.look_at(FOCUS + right * focus_shift_m)

# ---------------- 车库→赛道无缝过渡 ----------------

## 当前展车（过渡对齐时读它的全局变换；车库整体搬入 SubViewport 后继续展示）
func display_car() -> Vehicle:
	return _car

## 过渡开始：停掉拖拽交互，鼠标可见
func disable_interaction() -> void:
	interactive = false
	_end_drag()

func enable_interaction() -> void:
	interactive = true

# ---------------- 场景资源补齐（tscn 持结构，代码持资源） ----------------

func _setup_world() -> void:
	if world_env.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.006, 0.007, 0.008)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.18, 0.19, 0.20)   # 中性弱补光，只保住暗部材质
		env.ambient_light_energy = 0.56
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.tonemap_exposure = 1.42
		env.glow_enabled = true
		env.glow_intensity = 0.22
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		env.glow_hdr_threshold = 1.25
		env.glow_bloom = 0.03
		env.ssao_enabled = true
		env.ssao_intensity = 3.2
		env.ssao_radius = 1.4
		env.ssil_enabled = true
		env.ssil_intensity = 0.7
		# Transparent SubViewports disable SSR. Keep the showroom on the same
		# rendering path from its first frame so reparenting cannot change it.
		env.ssr_enabled = false
		env.fog_enabled = true
		env.fog_light_color = Color(0.025, 0.026, 0.027)
		env.fog_density = 0.006
		# Low-density volumetric haze catches the practical lights without veiling the car.
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.009
		env.volumetric_fog_albedo = Color(0.30, 0.31, 0.32)
		env.volumetric_fog_emission = Color(0.008, 0.007, 0.006)
		env.volumetric_fog_emission_energy = 0.35
		env.volumetric_fog_length = 18.0
		env.volumetric_fog_detail_spread = 2.5
		env.adjustment_enabled = true
		env.adjustment_brightness = 1.02
		env.adjustment_contrast = 1.08
		env.adjustment_saturation = 0.94
		world_env.environment = env
	if ground.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(24, 24)
		ground.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.13, 0.13, 0.125)      # 深灰旧混凝土，不抢车漆高光
		mat.roughness = 0.84
		mat.metallic = 0.0
		ground.material_override = mat
	_setup_lights()
	_setup_reflection_probe()
	_setup_ground_collision()
	_setup_platform()
	_setup_backdrop()
	_setup_floor_details()
	_setup_camera_post()
	_setup_haze()

## Transparent SubViewports do not support camera DoF. Leaving it disabled in
## the showroom avoids an exposure/focus pop when the transition starts.
func _setup_camera_post() -> void:
	world_env.camera_attributes = null

## 主光模拟车库高窗射入的暖白光，窄顶灯拉车顶高光；冷色弱补光仅托住背光面。
## 只有主光和顶灯投影，让车辆、轮胎和周边道具形成清晰接地关系。
func _setup_lights() -> void:
	sun.visible = false                                 # 展厅不用日光，全部走棚灯
	if get_node_or_null("StudioLights") != null:
		return
	var rig := Node3D.new()
	rig.name = "StudioLights"
	add_child(rig)
	var key := _make_studio_spot("Key", Vector3(-3.8, 7.2, 5.8), Color(1.0, 0.97, 0.91), 6.8, 52.0, 22.0)
	key.shadow_enabled = true
	key.shadow_blur = 2.2
	rig.add_child(key)
	rig.add_child(_make_studio_spot("Fill", Vector3(6.5, 3.0, 4.5), Color(0.72, 0.79, 0.86), 4.6, 72.0, 18.0))
	rig.add_child(_make_studio_spot("WarmRim", Vector3(-4.5, 4.0, -4.0), Color(1.0, 0.70, 0.44), 2.8, 38.0, 16.0))
	var top := _make_studio_spot("Top", Vector3(-1.8, 7.5, -1.2), Color(1.0, 0.96, 0.88), 2.2, 54.0, 14.0)
	top.shadow_enabled = true
	top.shadow_blur = 3.5
	rig.add_child(top)
	rig.add_child(_make_studio_spot("WallWash", Vector3(2.5, 4.8, -1.0), Color(0.76, 0.76, 0.72), 7.5, 68.0, 15.0, Vector3(-4.5, 2.5, -4.5)))
	rig.add_child(_make_studio_spot("FloorPool", Vector3(5.5, 7.0, 1.0), Color(0.78, 0.82, 0.84), 2.8, 42.0, 18.0, Vector3(1.5, 0.0, -0.8)))

func _make_studio_spot(spot_name: String, pos: Vector3, color: Color, energy: float, angle_deg: float, range_m: float, target := FOCUS) -> SpotLight3D:
	var s := SpotLight3D.new()
	s.name = spot_name
	s.look_at_from_position(pos, target)
	s.light_color = color
	s.light_energy = energy
	s.spot_angle = angle_deg
	s.spot_range = range_m
	s.spot_angle_attenuation = 1.8
	return s

## 反射探针：金属漆/玻璃/抛光地板获得真实环境反射（静态展厅烘焙一次够用）
func _setup_reflection_probe() -> void:
	if get_node_or_null("ReflectionProbe") != null:
		return
	var probe := ReflectionProbe.new()
	probe.name = "ReflectionProbe"
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.size = Vector3(20, 9, 20)
	probe.position = Vector3(0, 3.5, 0)
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

## 保留 Turntable 容器以兼容宿主场景；车辆直接停在车库地面，不再使用发光圆台。
func _setup_platform() -> void:
	pass

## 后墙背对相机摆放：机位在编辑器里挪到任意方向，运行时布景都自动转到车的另一侧
## （编辑器里挪完机位可手动转 Backdrop 节点预览对齐效果）。
func _orient_backdrop() -> void:
	var backdrop := get_node_or_null("Backdrop")
	if backdrop == null:
		return
	var dir := Vector2(camera.position.x, camera.position.z)
	if dir.length_squared() < 0.001:
		dir = Vector2(1.0, 1.0)   # 相机几乎在车正上方时退回默认 (+X,+Z) 象限
	dir = dir.normalized()
	backdrop.rotation.y = atan2(dir.x, dir.y)
	backdrop.position = Vector3(-dir.x * BACKDROP_DIST, 0.0, -dir.y * BACKDROP_DIST)

## 工业车库后墙：深色波纹钢板、立柱、桁架和顶灯。道具全部放在车辆后方，
## 既形成参考图里的工作间纵深，又不会遮挡展车和底部操作区域。
func _setup_backdrop() -> void:
	if get_node_or_null("Backdrop") != null:
		return
	var backdrop := Node3D.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)
	var wall := _box(backdrop, "Wall", Vector3(0, 3.0, 0), Vector3(17.0, 6.0, 0.24), Color(0.085, 0.083, 0.077), 0.88)
	var wall_mat := wall.material_override as StandardMaterial3D
	wall_mat.emission_enabled = true
	wall_mat.emission = Color(0.018, 0.018, 0.016)
	wall_mat.emission_energy_multiplier = 1.0
	# Corrugated ribs make the wall readable without a texture asset.
	for x in range(-32, 33):
		_box(backdrop, "Rib", Vector3(x * 0.25, 3.0, 0.15), Vector3(0.035, 5.7, 0.06), Color(0.13, 0.128, 0.118), 0.72, 0.15)
	for x in [-7.2, -3.6, 0.0, 3.6, 7.2]:
		_box(backdrop, "Column", Vector3(x, 3.05, 0.48), Vector3(0.20, 6.1, 0.22), Color(0.035, 0.034, 0.031), 0.55, 0.65)
		_box(backdrop, "Brace", Vector3(x + 0.85, 3.5, 0.53), Vector3(2.0, 0.10, 0.10), Color(0.03, 0.029, 0.027), 0.6, 0.6, Vector3(0, 0, 38))
		_box(backdrop, "Brace", Vector3(x + 0.85, 2.1, 0.53), Vector3(2.0, 0.10, 0.10), Color(0.03, 0.029, 0.027), 0.6, 0.6, Vector3(0, 0, -38))
	_box(backdrop, "TopBeam", Vector3(0, 5.65, 1.9), Vector3(17.0, 0.22, 0.28), Color(0.025, 0.024, 0.022), 0.55, 0.7)
	for x in [-5.5, -1.8, 1.8, 5.5]:
		_box(backdrop, "CeilingBeam", Vector3(x, 5.45, 3.8), Vector3(0.18, 0.20, 7.6), Color(0.025, 0.024, 0.022), 0.6, 0.7)
	_setup_garage_props(backdrop)

func _setup_garage_props(backdrop: Node3D) -> void:
	var metal := Color(0.07, 0.07, 0.065)
	# Left tire rack and stacked tires.
	for x in [-6.0, -3.7]:
		_box(backdrop, "RackPost", Vector3(x, 1.6, 0.85), Vector3(0.12, 3.2, 0.12), metal, 0.55, 0.7)
	for y in [0.45, 1.45, 2.45]:
		_box(backdrop, "RackShelf", Vector3(-4.85, y, 0.85), Vector3(2.5, 0.10, 0.75), metal, 0.6, 0.65)
		for x in [-5.65, -5.05, -4.45, -3.85]:
			_tire(backdrop, Vector3(x, y + 0.34, 0.86), 0.36)
	# Right workbench, cupboards and warm wooden crates.
	_box(backdrop, "BenchTop", Vector3(4.7, 1.0, 1.15), Vector3(4.4, 0.18, 1.15), Color(0.19, 0.095, 0.045), 0.72)
	for x in [2.8, 4.7, 6.6]:
		_box(backdrop, "BenchLeg", Vector3(x, 0.48, 1.15), Vector3(0.14, 0.95, 0.14), metal, 0.55, 0.7)
	for item in [Vector3(3.0, 1.42, 0.85), Vector3(4.1, 1.28, 1.1), Vector3(5.7, 1.45, 0.9)]:
		_box(backdrop, "Crate", item, Vector3(0.85, 0.65, 0.7), Color(0.22, 0.105, 0.045), 0.82)
	# Wall shelves and boxes break up the large dark background.
	for y in [2.2, 3.35, 4.5]:
		_box(backdrop, "WallShelf", Vector3(5.2, y, 0.62), Vector3(3.6, 0.10, 0.55), metal, 0.58, 0.7)
	for p in [Vector3(4.1, 2.58, 0.63), Vector3(5.15, 2.62, 0.63), Vector3(6.0, 3.72, 0.63), Vector3(4.55, 4.87, 0.63)]:
		_box(backdrop, "StorageBox", p, Vector3(0.75, 0.62, 0.5), Color(0.11, 0.12, 0.115), 0.8)
	# Three practical ceiling strips are visible reflections and motivate the top light.
	for x in [-3.6, 0.0, 3.6]:
		var fixture := _box(backdrop, "Practical", Vector3(x, 5.25, 2.0), Vector3(2.0, 0.08, 0.30), Color(0.9, 0.73, 0.48), 0.35)
		var mat := fixture.material_override as StandardMaterial3D
		mat.emission_enabled = true
		mat.emission = Color(0.92, 0.90, 0.84)
		mat.emission_energy_multiplier = 0.08 if is_zero_approx(x) else 0.45
	for p in [Vector3(-3.6, 4.85, 1.8), Vector3(3.6, 4.85, 1.8)]:
		var practical_light := OmniLight3D.new()
		practical_light.name = "PracticalGlow"
		practical_light.position = p
		practical_light.light_color = Color(1.0, 0.72, 0.42)
		practical_light.light_energy = 0.55
		practical_light.omni_range = 4.5
		practical_light.omni_attenuation = 1.7
		backdrop.add_child(practical_light)

## Sparse, slow smoke stays behind the car and gives the light pools a little movement.
func _setup_haze() -> void:
	if get_node_or_null("AtmosphericHaze") != null:
		return
	var haze := Node3D.new()
	haze.name = "AtmosphericHaze"
	add_child(haze)
	_add_smoke_emitter(haze, Vector3(-3.8, 0.65, -3.6), Vector3(2.2, 0.65, 1.7), 10)
	_add_smoke_emitter(haze, Vector3(3.0, 0.85, -4.2), Vector3(1.8, 0.8, 1.4), 7)

func _add_smoke_emitter(parent: Node3D, pos: Vector3, extents: Vector3, particle_count: int) -> void:
	var particles := GPUParticles3D.new()
	particles.name = "Smoke"
	particles.position = pos
	particles.amount = particle_count
	particles.lifetime = 12.0
	particles.randomness = 0.65
	particles.preprocess = 12.0
	particles.fixed_fps = 20
	particles.visibility_aabb = AABB(-extents * 2.5, extents * 5.0)

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	process.direction = Vector3(0.12, 1.0, -0.08)
	process.spread = 38.0
	process.gravity = Vector3(0, 0.025, 0)
	process.initial_velocity_min = 0.035
	process.initial_velocity_max = 0.11
	process.scale_min = 0.75
	process.scale_max = 2.1
	var life_gradient := Gradient.new()
	life_gradient.offsets = PackedFloat32Array([0.0, 0.15, 0.7, 1.0])
	life_gradient.colors = PackedColorArray([
		Color(0.30, 0.32, 0.34, 0.0),
		Color(0.30, 0.32, 0.34, 0.045),
		Color(0.25, 0.27, 0.29, 0.02),
		Color(0.22, 0.24, 0.26, 0.0),
	])
	var life_ramp := GradientTexture1D.new()
	life_ramp.gradient = life_gradient
	process.color_ramp = life_ramp
	particles.process_material = process

	var radial_gradient := Gradient.new()
	radial_gradient.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	radial_gradient.colors = PackedColorArray([
		Color(1, 1, 1, 0.24),
		Color(1, 1, 1, 0.08),
		Color(1, 1, 1, 0.0),
	])
	var smoke_texture := GradientTexture2D.new()
	smoke_texture.gradient = radial_gradient
	smoke_texture.width = 64
	smoke_texture.height = 64
	smoke_texture.fill = GradientTexture2D.FILL_RADIAL
	smoke_texture.fill_from = Vector2(0.5, 0.5)
	smoke_texture.fill_to = Vector2(1.0, 0.5)
	var smoke_mat := StandardMaterial3D.new()
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_mat.billboard_keep_scale = true
	smoke_mat.vertex_color_use_as_albedo = true
	smoke_mat.albedo_texture = smoke_texture
	var quad := QuadMesh.new()
	quad.size = Vector2(1.35, 1.35)
	quad.material = smoke_mat
	particles.draw_pass_1 = quad
	parent.add_child(particles)

func _setup_floor_details() -> void:
	if get_node_or_null("FloorDetails") != null:
		return
	var details := Node3D.new()
	details.name = "FloorDetails"
	add_child(details)
	# Concrete expansion joints and faded bay markings.
	for offset in [-4.0, 0.0, 4.0]:
		_box(details, "Joint", Vector3(offset, 0.012, 0), Vector3(0.025, 0.018, 18.0), Color(0.025, 0.025, 0.024), 1.0)
		_box(details, "Joint", Vector3(0, 0.013, offset), Vector3(18.0, 0.018, 0.025), Color(0.025, 0.025, 0.024), 1.0)
	for offset in [-2.9, 2.9]:
		_box(details, "BayMark", Vector3(offset, 0.018, -0.3), Vector3(0.09, 0.025, 7.5), Color(0.32, 0.30, 0.23), 0.88)
	# Broad translucent-looking stains are matte geometry, intentionally very subtle.
	_box(details, "Stain", Vector3(-2.4, 0.019, 2.7), Vector3(2.8, 0.02, 1.1), Color(0.075, 0.07, 0.06), 1.0, 0.0, Vector3(0, 18, 0))
	_box(details, "Stain", Vector3(3.2, 0.019, -1.8), Vector3(1.6, 0.02, 2.4), Color(0.065, 0.066, 0.063), 1.0, 0.0, Vector3(0, -22, 0))

func _box(parent: Node, node_name: String, pos: Vector3, size: Vector3, color: Color, roughness := 0.8, metallic := 0.0, rotation_deg := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = pos
	instance.rotation_degrees = rotation_deg
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	instance.material_override = mat
	parent.add_child(instance)
	return instance

func _tire(parent: Node, pos: Vector3, radius: float) -> void:
	var tire := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius * 0.55
	mesh.outer_radius = radius
	mesh.rings = 16
	mesh.ring_segments = 12
	tire.mesh = mesh
	tire.position = pos
	tire.rotation_degrees.z = 90.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.018, 0.017, 0.015)
	mat.roughness = 0.95
	tire.material_override = mat
	parent.add_child(tire)
