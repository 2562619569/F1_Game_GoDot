extends "res://addons/pro_vehicle_camera/pro_vehicle_camera.gd"
## Pro Vehicle Camera 的比赛相机封装（不改动上游算法结构）：
## 1. 旋转低通：键盘 A/D 是阶跃输入，打满转向后车身横摆很快，而上游每个物理帧
##    look_at 瞬时对准车身、过弯侧倾直接跟随转向量，视角会"啪"地跳变。这里在
##    上一帧朝向与上游新朝向之间做帧率无关的指数阻尼低通，抹平瞬时跳变；
##    位置牵引、动态 FOV、look_back 行为与上游完全一致。
## 2. 视角模式（camera_next 动作循环，Forza/GT 惯例）：追尾远 → 追尾近 →
##    引擎盖 → 保险杠。追尾走上游弹性牵引；引擎盖/保险杠为刚性锚定（自车
##    视觉 AABB 推导锚点，适配任意车壳/占位车），朝向随车身 + 环视偏移。
## 3. 环视：按住鼠标左键拖拽或手柄右摇杆（camera_look_* 动作）绕车环视，
##    松手指数回正；追尾模式旋转牵引方向（上游 orbit_yaw/orbit_pitch 钩子），
##    刚性模式直接旋转视线。
## 4. 持续震动源：高速路面/重刹/漂移侧滑的常驻微震（碰撞脉冲仍走
##    trigger_shake），shake_enabled 总开关同时门控两类（Game 表 cam_shake）。

## 朝向跟随刚度：越大越跟手，越小越"电影"（12 ≈ 80ms 时间常数）。
@export var rotation_damp := 12.0

@export_group("View Modes")
## 当前视角（ViewMode 枚举值），开局由 race_builder 决定，比赛中 camera_next 循环。
@export var view_mode: int = ViewMode.CHASE_FAR

@export_group("Orbit Look")
@export var orbit_mouse_sensitivity := 0.0032
@export var orbit_stick_sensitivity := 3.0
## 松手回正时间常数（1/s）：越大回弹越快。
@export var orbit_return_speed := 4.0
@export var orbit_pitch_min := -0.45
@export var orbit_pitch_max := 0.5

@export_group("Shake Sources")
## 总开关（race_builder 注入 Game 表 cam_shake）：门控脉冲与持续两类震屏。
@export var shake_enabled := true
## 各源增益（米/帧随机偏移幅度 @120Hz）：高速路面 / 重刹 / 漂移侧滑。
@export var shake_speed_gain := 0.010
@export var shake_brake_gain := 0.020
@export var shake_drift_gain := 0.022

enum ViewMode { CHASE_FAR, CHASE_NEAR, HOOD, BUMPER }

const VIEW_ORDER: Array[int] = [ViewMode.CHASE_FAR, ViewMode.CHASE_NEAR, ViewMode.HOOD, ViewMode.BUMPER]
## 追尾近档 = 远档的比例（GT/Forza 的 chase near/far 两档手感）。
const CHASE_NEAR_DISTANCE_SCALE := 0.72
const CHASE_NEAR_HEIGHT_SCALE := 0.8
## 刚性视角 FOV 略窄于追尾（bumper/hood 惯例 ~58° vs chase ~62° 的比例关系）。
const RIGID_FOV_MIN := 66.0
const RIGID_FOV_MAX := 74.0
## 引擎盖锚点：自车头沿车长向后收入的比例；保险杠锚点：探出车头皮肤的距离。
const HOOD_BACK_RATIO := 0.30
const RIGID_BUMPER_FORWARD := 0.10
## 无视觉网格（headless 探针等）时的近似车盒：中心对齐原点、贴地。
const RIGID_FALLBACK_SIZE := Vector3(1.9, 1.2, 4.4)
## 持续震动起震阈值：车速 28 m/s 起路面渐入；重刹要求 12 m/s 以上；侧滑 3 m/s 起。
const SHAKE_SPEED_ONSET := 28.0
const SHAKE_BRAKE_SPEED := 12.0
const SHAKE_DRIFT_SPEED := 8.0
const SHAKE_DRIFT_SLIP := 3.0
const STICK_DEADZONE := 0.15

var _prev_basis := Basis.IDENTITY

var _base_distance := 0.0   # race_builder 注入的追尾远档基准（_ready 捕获）
var _base_height := 0.0
var _chase_fov_min := 70.0
var _chase_fov_max := 79.0
var _rigid_anchor := Vector3.ZERO   # 引擎盖/保险杠：车身空间锚点
var _orbit_active := false   # 本物理帧有环视输入（无输入才回正）
var _mouse_drag := false
var _mouse_motion := Vector2.ZERO

func _ready() -> void:
	super()
	_base_distance = follow_distance
	_base_height = follow_height
	_chase_fov_min = minimum_fov
	_chase_fov_max = maximum_fov

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_drag = event.pressed
	elif event is InputEventMouseMotion and _mouse_drag:
		_mouse_motion += event.relative

func _physics_process(delta: float) -> void:
	if follow_this == null or Engine.is_editor_hint():
		return
	_prev_basis = global_transform.basis
	if InputMap.has_action("camera_next") and Input.is_action_just_pressed("camera_next"):
		cycle_view()
	_poll_orbit(delta)
	if _is_rigid():
		_rigid_update(delta)
	else:
		super(delta)   # 追尾：上游弹性牵引 + FOV + look_at + 侧倾 + 脉冲震屏
	var weight := 1.0 - exp(-rotation_damp * delta)
	global_transform.basis = _prev_basis.slerp(global_transform.basis, weight)
	_apply_continuous_shake(delta)

# ---------------- 视角模式 ----------------

func cycle_view() -> void:
	set_view(VIEW_ORDER[(VIEW_ORDER.find(view_mode) + 1) % VIEW_ORDER.size()])

func set_view(mode: int) -> void:
	view_mode = mode
	match view_mode:
		ViewMode.CHASE_NEAR:
			follow_distance = _base_distance * CHASE_NEAR_DISTANCE_SCALE
			follow_height = _base_height * CHASE_NEAR_HEIGHT_SCALE
			minimum_fov = _chase_fov_min
			maximum_fov = _chase_fov_max
		ViewMode.HOOD, ViewMode.BUMPER:
			_refresh_rigid_anchor()
			minimum_fov = RIGID_FOV_MIN
			maximum_fov = RIGID_FOV_MAX
		_:
			follow_distance = _base_distance
			follow_height = _base_height
			minimum_fov = _chase_fov_min
			maximum_fov = _chase_fov_max

func _is_rigid() -> bool:
	return view_mode == ViewMode.HOOD or view_mode == ViewMode.BUMPER

## 引擎盖/保险杠帧更新：位置刚性锚定车身（不做弹性牵引），朝向 = 车身朝向
## + look_back 翻转 + 环视偏移（俯仰绕自身 X 轴，orbit_pitch>0 为俯视）。
## 刚性视角不做过弯侧倾（hood cam 惯例不随转向滚转），脉冲震屏照常生效。
func _rigid_update(delta: float) -> void:
	var car := follow_this
	var car_basis := car.global_transform.basis
	global_position = car.global_position + car_basis * _rigid_anchor
	var yaw := orbit_yaw + (PI if _looking_back() else 0.0)
	var b := car_basis.rotated(Vector3.UP, yaw)
	global_transform.basis = b.rotated(b.x, -orbit_pitch)
	if enable_fov_warp:
		var target_fov: float = lerp(minimum_fov, maximum_fov,
				clampf(_car_speed() / top_speed_threshold, 0.0, 1.0))
		fov = lerp(fov, target_fov, fov_smooth_speed * delta)
	if _shake_timer > 0.0:
		_shake_timer -= delta
		global_position += Vector3(
			randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity, _shake_intensity))
		_shake_intensity = lerp(_shake_intensity, 0.0, delta * (1.0 / _shake_duration))

## 引擎盖/保险杠锚点：车辆视觉 AABB（车头 -Z）推导，适配各车壳与占位车；
## 队旗横幅（TeamBanner）是装饰件，不参与测盒。
func _refresh_rigid_anchor() -> void:
	var box := _vehicle_visual_aabb()
	if box.size.length() == 0.0:
		box = AABB(Vector3(-RIGID_FALLBACK_SIZE.x * 0.5, 0.0, -RIGID_FALLBACK_SIZE.z * 0.5), RIGID_FALLBACK_SIZE)
	var front := box.position.z
	if view_mode == ViewMode.BUMPER:
		_rigid_anchor = Vector3(0.0, box.position.y + box.size.y * 0.55, front - RIGID_BUMPER_FORWARD)
	else:
		_rigid_anchor = Vector3(0.0, box.position.y + box.size.y - 0.10, front + box.size.z * HOOD_BACK_RATIO)

func _vehicle_visual_aabb() -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var stack: Array = [[follow_this, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node := top[0] as Node3D
		var xf: Transform3D = top[1] * node.transform
		if node is MeshInstance3D and node.visible and node.mesh != null \
				and not String(node.name).begins_with("TeamBanner"):
			var mesh_aabb: AABB = xf * node.mesh.get_aabb()
			bounds = mesh_aabb if not has_bounds else bounds.merge(mesh_aabb)
			has_bounds = true
		for c in node.get_children():
			if c is Node3D:
				stack.append([c, xf])
	return bounds

# ---------------- 环视输入与回正 ----------------

func _poll_orbit(delta: float) -> void:
	_orbit_active = false
	if _mouse_motion != Vector2.ZERO:
		orbit_look(_mouse_motion.x * orbit_mouse_sensitivity, _mouse_motion.y * orbit_mouse_sensitivity)
		_mouse_motion = Vector2.ZERO
	if InputMap.has_action("camera_look_left") and InputMap.has_action("camera_look_right") \
			and InputMap.has_action("camera_look_up") and InputMap.has_action("camera_look_down"):
		var stick := Input.get_vector("camera_look_left", "camera_look_right",
				"camera_look_up", "camera_look_down")
		if stick.length() > STICK_DEADZONE:
			orbit_look(stick.x * orbit_stick_sensitivity * delta, stick.y * orbit_stick_sensitivity * delta)
	if not _orbit_active:
		var w := 1.0 - exp(-orbit_return_speed * delta)
		orbit_yaw = lerpf(orbit_yaw, 0.0, w)
		orbit_pitch = lerpf(orbit_pitch, 0.0, w)

## 环视增量（弧度/像素语义同鼠标 motion：右拖/上推为正）。
## 拖右 = 视线右移（相机绕到车左侧），拖下/下推 = 相机抬高俯视（编辑器
## 预览相机同款约定）。任何途径的输入都会推迟回正。
func orbit_look(yaw_delta: float, pitch_delta: float) -> void:
	orbit_yaw -= yaw_delta
	orbit_pitch = clampf(orbit_pitch + pitch_delta, orbit_pitch_min, orbit_pitch_max)
	_orbit_active = true

# ---------------- 持续震动源 ----------------

func trigger_shake(intensity: float, duration: float) -> void:
	if not shake_enabled:
		return
	super(intensity, duration)

## 常驻微震强度（纯函数，自检用）：高速路面 + 重刹 + 漂移侧滑三源叠加，
## 量级 ~0.05m（碰撞脉冲 0.03~0.3m 的下限以下，只做肌理不做事件感）。
func _continuous_shake_intensity() -> float:
	var v := follow_this
	var spd := _car_speed()
	var inten := 0.0
	if spd > SHAKE_SPEED_ONSET:
		inten += shake_speed_gain * clampf((spd - SHAKE_SPEED_ONSET) / 20.0, 0.0, 1.0)
	if "brake_input" in v and spd > SHAKE_BRAKE_SPEED:
		inten += shake_brake_gain * float(v.brake_input) * clampf(spd / 30.0, 0.0, 1.0)
	if "local_velocity" in v and spd > SHAKE_DRIFT_SPEED:
		var slip := absf(float(v.local_velocity.x))
		if slip > SHAKE_DRIFT_SLIP:
			inten += shake_drift_gain * clampf((slip - SHAKE_DRIFT_SLIP) / 6.0, 0.0, 1.0)
	return inten

func _apply_continuous_shake(_delta: float) -> void:
	if not shake_enabled:
		return
	var inten := _continuous_shake_intensity()
	if inten <= 0.0:
		return
	# 只做横纵向抖动：z 向前后抖在近贴车身/保险杠视角下会拍出车头闪动
	global_position += Vector3(randf_range(-inten, inten), randf_range(-inten, inten), 0.0)

func _car_speed() -> float:
	if "linear_velocity" in follow_this:
		return follow_this.linear_velocity.length()
	if "current_speed" in follow_this:
		return follow_this.current_speed
	return 0.0

func _looking_back() -> bool:
	return enable_look_back and InputMap.has_action(look_back_action) \
			and Input.is_action_pressed(look_back_action)
