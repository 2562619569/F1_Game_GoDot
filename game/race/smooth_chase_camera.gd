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
## 4. 震动走原版 Shaker 插件（addons/shaker，MIT，未改上游一行）：持续微震
##    （高速路面/重刹/漂移侧滑/砂石路面）= 组件常驻 Brownian 随机游走 preset；碰撞
##    脉冲 = impact_kick 方向性曲线甩动 + 白噪声旋转混乱。相机每物理帧被
##    PVC/刚性锚定全量重写 transform，直接以相机为抖动目标会冲掉组件的
##    "撤销上次偏移+叠加新偏移"差分机制，故组件 custom_target 指向哑元
##    节点，物理帧末尾把哑元偏移叠到全局位姿（旧 _apply_continuous_shake
##    的注入槽位）。shake_enabled 总开关同时门控两类（Game 表 cam_shake）。

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
## 各源最大量级（米）：路面是细碎纵向纹理，制动偏点头，漂移偏横摆。
@export var shake_speed_gain := 0.004
@export var shake_brake_gain := 0.006
@export var shake_drift_gain := 0.008
## 砂石路：不问车速门槛、低速就颠，是最强的一路持续源（按车轮压砂石占比 ×
## 车速渐变，骑上路肩半边轮只有一半强度）。
@export var shake_gravel_gain := 0.010
## 持续源缓入快、缓出慢，避免踩刹车/结束漂移时震动硬切。
@export var shake_attack := 12.0
@export var shake_release := 5.0

@export_group("Impact Kick")
## 碰撞严重度 0..1 映射的位移与时长。轻碰只提示，重撞才有完整回弹。
@export var kick_position_min := 0.006
@export var kick_position_max := 0.075
@export var kick_duration_min := 0.28
@export var kick_duration_max := 0.52
## 方向性转动与残余随机扰动（插件内部还会乘 PI/2 转为弧度）。
@export var kick_rot_gain := 0.16
@export var kick_chaos_gain := 0.025

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
## 持续震动起震阈值：车速 28 m/s 起路面渐入；重刹要求 12 m/s 以上；侧滑 3 m/s 起；
## 砂石 2 m/s 起颠、10 m/s 到满幅（停在路上不抖，低速碾过也有感）。
const SHAKE_SPEED_ONSET := 28.0
const SHAKE_BRAKE_SPEED := 12.0
const SHAKE_DRIFT_SPEED := 8.0
const SHAKE_DRIFT_SLIP := 3.0
const SHAKE_GRAVEL_ONSET := 2.0
const SHAKE_GRAVEL_FULL := 10.0
## 砂石表面组名（track_builder 铺砂石路肩时加的 collision group，同 wheel 表面字典键）。
const GRAVEL_SURFACE := "Gravel"
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
var _shaker: ShakerComponent3D = null   # Shaker 组件（抖哑元，见 _build_shaker）
var _shake_target: Node3D = null   # 哑元：本地 transform 只被 Shaker 写，相机每帧读
var _rumble_pos: ShakerTypeBrownianShake3D = null   # 持续微震两路游走，幅度由物理帧实时写
var _rumble_rot: ShakerTypeBrownianShake3D = null
var _rumble_levels := Vector3.ZERO   # x=高速路感，y=制动，z=漂移（均为米量级）
var _gravel_pos: ShakerTypeBrownianShake3D = null   # 砂石两路：更高 roughness 才有粗粝颠簸
var _gravel_rot: ShakerTypeBrownianShake3D = null
var _gravel_level := 0.0   # 砂石源强度（米量级），同样走缓入缓出

func _ready() -> void:
	super()
	_base_distance = follow_distance
	_base_height = follow_height
	_chase_fov_min = minimum_fov
	_chase_fov_max = maximum_fov
	_build_shaker()

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
	_apply_shake(delta)

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
## 刚性视角不做过弯侧倾（hood cam 惯例不随转向滚转），震动走 _apply_shake。
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

# ---------------- Shaker 震动（原版插件，未改上游） ----------------

## 组件挂在相机下但不以相机为目标：相机 transform 每物理帧被 PVC 牵引/
## 刚性锚定全量重写，会冲掉组件"撤销上次偏移+叠加新偏移"的差分；改为
## custom_target 指向哑元节点，两条震动通道（常驻 preset + 外挂脉冲）都
## 累加在哑元的本地 position/rotation 上，相机在物理帧末尾统一读取叠加。
func _build_shaker() -> void:
	_shake_target = Node3D.new()
	_shake_target.name = "ShakeTarget"
	add_child(_shake_target)
	_shaker = ShakerComponent3D.new()
	_shaker.name = "Shaker"
	_shaker.custom_target = true
	_shaker.Targets = [_shake_target]
	_shaker.duration = 0.0   # 常驻无限循环
	_shaker.intensity = 1.0   # 固定 1：外挂脉冲强度 = ext.intensity×组件intensity×包络，
	                         # 若用组件intensity 承载微震强度会把碰撞 kick 稀释掉
	_rumble_pos = ShakerTypeBrownianShake3D.new()
	_rumble_pos.roughness = Vector3(0.6, 0.5, 0.4)
	_rumble_pos.persistence = Vector3.ONE * 0.93
	_rumble_pos.amplitude = Vector3.ZERO   # 强度由物理帧实时写入
	_rumble_rot = ShakerTypeBrownianShake3D.new()
	_rumble_rot.roughness = Vector3(0.4, 0.3, 0.5)
	_rumble_rot.persistence = Vector3.ONE * 0.95
	_rumble_rot.amplitude = Vector3.ZERO
	# 砂石路面是高频粗粝颠簸，与高速路感的顺滑游走性格不同：独立一对通道，
	# roughness 加大、persistence 收低（步子大、忘得快 = 更"咯咯楞楞"）。
	_gravel_pos = ShakerTypeBrownianShake3D.new()
	_gravel_pos.roughness = Vector3(1.2, 1.5, 1.0)
	_gravel_pos.persistence = Vector3.ONE * 0.82
	_gravel_pos.amplitude = Vector3.ZERO
	_gravel_rot = ShakerTypeBrownianShake3D.new()
	_gravel_rot.roughness = Vector3(0.9, 0.6, 1.1)
	_gravel_rot.persistence = Vector3.ONE * 0.86
	_gravel_rot.amplitude = Vector3.ZERO
	var preset := ShakerPreset3D.new()
	preset.PositionShake = [_rumble_pos, _gravel_pos]
	preset.RotationShake = [_rumble_rot, _gravel_rot]
	_shaker.shakerPreset = preset
	add_child(_shaker)
	_shaker.play_shake()

## 碰撞脉冲：world_dir 是被撞后的甩出方向（世界系），severity 为 0..1。
## 曲线快速到峰、轻微反向回弹后慢收尾；新碰撞覆盖旧脉冲，避免接触事件叠加爆幅。
func impact_kick(world_dir: Vector3, severity: float) -> void:
	if not shake_enabled or _shaker == null:
		return
	var world_kick_dir := world_dir.normalized()
	if world_kick_dir.length_squared() < 0.25:
		return
	var shaped_severity := pow(clampf(severity, 0.0, 1.0), 0.75)
	var strength := lerpf(kick_position_min, kick_position_max, shaped_severity)
	var duration := lerpf(kick_duration_min, kick_duration_max, shaped_severity)
	# 哑元存本地偏移，最终经相机 basis 转回世界；方向也先转到相机本地。
	var dir := (global_transform.basis.inverse() * world_kick_dir).normalized()
	var preset := ShakerPreset3D.new()
	var kick := _impact_curve(dir * strength)
	# 侧撞以滚转为主、正撞以俯仰为主，方向和车身受力保持一致。
	var recoil_axis := Vector3(-dir.z, dir.y * 0.2, dir.x)
	var recoil := _impact_curve(recoil_axis * strength * kick_rot_gain)
	var chaos := ShakerTypeRandom3D.new()
	chaos.amplitude = Vector3.ONE * (strength * kick_chaos_gain)
	preset.PositionShake = [kick]
	preset.RotationShake = [recoil, chaos]
	# override 只决定本帧混合方式，不会移除列表里的旧项；显式清空可避免
	# “重撞后紧接轻碰”结束时，尚未到期的旧重撞短暂重新出现。
	_shaker._external_shakes.clear()
	_shaker.shake(preset, ShakerComponent3D.ShakeAddMode.override,
			duration, 1.0 / duration, 1.0, 0.12, 0.45)

func _impact_curve(amplitude: Vector3) -> ShakerTypeCurve3D:
	var shake_curve := ShakerTypeCurve3D.new()
	shake_curve.loop = false
	# 每轴必须独享 Curve；插件 setter 会连接 changed，共享会重复连接报错。
	var curves: Array[Curve] = [Curve.new(), Curve.new(), Curve.new()]
	for shape: Curve in curves:
		shape.add_point(Vector2(0.0, 0.0))
		shape.add_point(Vector2(0.12, 1.0))
		shape.add_point(Vector2(0.42, 0.32))
		shape.add_point(Vector2(0.70, -0.10))
		shape.add_point(Vector2(1.0, 0.0))
	shake_curve.curve_x = curves[0]
	shake_curve.curve_y = curves[1]
	shake_curve.curve_z = curves[2]
	shake_curve.amplitude = amplitude
	return shake_curve

## 三路持续源（纯函数，自检用）：x=高速路感，y=制动，z=漂移。
func _continuous_shake_sources() -> Vector3:
	var v := follow_this
	var spd := _car_speed()
	var sources := Vector3.ZERO
	if spd > SHAKE_SPEED_ONSET:
		sources.x = shake_speed_gain * clampf((spd - SHAKE_SPEED_ONSET) / 20.0, 0.0, 1.0)
	if "brake_input" in v and spd > SHAKE_BRAKE_SPEED:
		sources.y = shake_brake_gain * float(v.brake_input) * clampf(spd / 30.0, 0.0, 1.0)
	if "local_velocity" in v and spd > SHAKE_DRIFT_SPEED:
		var slip := absf(float(v.local_velocity.x))
		if slip > SHAKE_DRIFT_SLIP:
			sources.z = shake_drift_gain * clampf((slip - SHAKE_DRIFT_SLIP) / 6.0, 0.0, 1.0)
	return sources

func _continuous_shake_intensity() -> float:
	var sources := _continuous_shake_sources()
	return sources.x + sources.y + sources.z

## 压在砂石上的车轮占比（0..1）：前/后轴车轮逐个读 surface_type（wheel 按碰撞体
## 所在表面组实时刷新）；无 axle 结构的探针目标安全返回 0。骑砂石路肩只压到
## 半边轮，就只给一半强度。
func _gravel_wheel_weight() -> float:
	var v := follow_this
	if v == null or not ("front_axle" in v and "rear_axle" in v):
		return 0.0
	var total := 0
	var on_gravel := 0
	for axle in [v.front_axle, v.rear_axle]:
		if axle == null:
			continue
		for wheel in axle.wheels:
			total += 1
			if String(wheel.surface_type) == GRAVEL_SURFACE:
				on_gravel += 1
	return float(on_gravel) / float(total) if total > 0 else 0.0

## 砂石源强度（纯函数，自检用）：gain × 车轮占比 × 车速渐变，2 m/s 起颠、
## 10 m/s 满幅——砂石不像高速路感要等 28 m/s，低速碾过就有感。
func _gravel_shake_level() -> float:
	var weight := _gravel_wheel_weight()
	if weight <= 0.0:
		return 0.0
	var spd := _car_speed()
	if spd <= SHAKE_GRAVEL_ONSET:
		return 0.0
	var speed_factor := clampf((spd - SHAKE_GRAVEL_ONSET) / (SHAKE_GRAVEL_FULL - SHAKE_GRAVEL_ONSET), 0.0, 1.0)
	return shake_gravel_gain * weight * speed_factor

func _gravel_position_amplitude(level: float) -> Vector3:
	# 竖直颠为主、带点横向晃；z 同样不抖（近贴视角下前后抖会拍出车头闪动）。
	return Vector3(0.6, 1.4, 0.0) * level

func _gravel_rotation_amplitude(level: float) -> Vector3:
	# 主俯仰（点头颠）、次滚转、轻微偏航。
	return Vector3(0.45, 0.10, 0.28) * level

func _rumble_position_amplitude(levels: Vector3) -> Vector3:
	# 路面以纵向细碎跳动为主，制动抖在竖直方向，漂移集中于横向。
	return Vector3(levels.x * 0.25 + levels.y * 0.12 + levels.z,
			levels.x + levels.y * 0.70 + levels.z * 0.30, 0.0)

func _rumble_rotation_amplitude(levels: Vector3) -> Vector3:
	# 制动主俯仰(X)，漂移主滚转(Z)；高速仅保留极轻的全向车身纹理。
	return Vector3(levels.x * 0.05 + levels.y * 0.32,
			levels.x * 0.025 + levels.z * 0.05,
			levels.x * 0.04 + levels.z * 0.34)

## 物理帧末尾：持续源强度写入两路 Brownian 的幅度（x/y 抖、z 不抖——
## 近贴车身/保险杠视角下前后抖会拍出车头闪动，旧版同款约定），砂石源同法
## 写入自己的通道，再把哑元上累积的震动偏移/旋转叠到相机全局位姿——
## PVC 牵引/刚性锚定先写基准，震动只做叠加，与旧 _apply_continuous_shake
## 同一注入槽位。
func _apply_shake(delta: float) -> void:
	if _shaker == null:
		return
	var target_levels := _continuous_shake_sources() if shake_enabled else Vector3.ZERO
	var gravel_target := _gravel_shake_level() if shake_enabled else 0.0
	if not shake_enabled:
		_rumble_levels = Vector3.ZERO
		_gravel_level = 0.0
	else:
		_rumble_levels.x = _smooth_rumble(_rumble_levels.x, target_levels.x, delta)
		_rumble_levels.y = _smooth_rumble(_rumble_levels.y, target_levels.y, delta)
		_rumble_levels.z = _smooth_rumble(_rumble_levels.z, target_levels.z, delta)
		_gravel_level = _smooth_rumble(_gravel_level, gravel_target, delta)
	var pos_amplitude := _rumble_position_amplitude(_rumble_levels)
	var rot_amplitude := _rumble_rotation_amplitude(_rumble_levels)
	if not _rumble_pos.amplitude.is_equal_approx(pos_amplitude):
		_rumble_pos.amplitude = pos_amplitude
	if not _rumble_rot.amplitude.is_equal_approx(rot_amplitude):
		_rumble_rot.amplitude = rot_amplitude
	var gravel_pos_amplitude := _gravel_position_amplitude(_gravel_level)
	var gravel_rot_amplitude := _gravel_rotation_amplitude(_gravel_level)
	if not _gravel_pos.amplitude.is_equal_approx(gravel_pos_amplitude):
		_gravel_pos.amplitude = gravel_pos_amplitude
	if not _gravel_rot.amplitude.is_equal_approx(gravel_rot_amplitude):
		_gravel_rot.amplitude = gravel_rot_amplitude
	global_position += global_transform.basis * _shake_target.position
	var r := _shake_target.rotation
	if r != Vector3.ZERO:
		global_transform.basis = global_transform.basis \
				.rotated(Vector3.RIGHT, r.x).rotated(Vector3.UP, r.y) \
				.rotated(Vector3.BACK, r.z)

func _smooth_rumble(current: float, target_value: float, delta: float) -> float:
	var rate := shake_attack if target_value > current else shake_release
	return lerpf(current, target_value, 1.0 - exp(-rate * delta))

func _car_speed() -> float:
	if "linear_velocity" in follow_this:
		return follow_this.linear_velocity.length()
	if "current_speed" in follow_this:
		return follow_this.current_speed
	return 0.0

func _looking_back() -> bool:
	return enable_look_back and InputMap.has_action(look_back_action) \
			and Input.is_action_pressed(look_back_action)
