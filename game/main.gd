extends Node3D
## 游戏流程总控（状态机）：
## LOBBY → ROOM(邀请) → CAR_SELECT(开局选车) → RACE ⇄ INTERMISSION(局间改装)
## → … × round_count … → FINAL(决赛) → FINAL_RESULT → LOBBY
##
## 所有界面为独立场景挂在 CanvasLayer 下，比赛世界挂在 World 下，
## 界面与数据解耦（数据在 Match autoload），便于后期替换美术/界面。

signal flow_changed(state: String)

const LobbyScene := preload("res://game/ui/lobby/lobby.tscn")
const RoomScene := preload("res://game/ui/room/room_invite.tscn")
const CarSelectScene := preload("res://game/ui/car_select/car_select.tscn")
const GarageScene := preload("res://game/ui/garage/intermission.tscn")
const HudScene := preload("res://game/ui/hud/race_hud.tscn")
const FinalScene := preload("res://game/ui/result/final_result.tscn")
const ShowroomScene := preload("res://game/ui/showroom/showroom.tscn")

@onready var world: Node3D = $World
@onready var ui: CanvasLayer = $UI

var current_ui: Node
var race: RaceManager
var hud: Control
var showroom: Node3D
var speed_motion_blur: SpeedMotionBlur

func _ready() -> void:
	show_lobby()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.is_action_pressed("DebugFinish"):
		if race != null and not race.ended:
			RaceDebug.finish_all(race)

# ---------------- 界面切换 ----------------

## 纯 Control 界面挂 UI 画布层；选车/局间为 3D 展台 + CanvasLayer 的混合场景，
## 直接挂主节点（自带相机，需要独占视口 —— 同展示间）
func _set_ui(c: Node) -> void:
	_clear_ui()
	current_ui = c
	if c is Control:
		ui.add_child(c)
	else:
		add_child(c)

func _clear_ui() -> void:
	if current_ui != null:
		current_ui.queue_free()
		current_ui = null

func show_lobby() -> void:
	_clear_race()
	_clear_showroom()
	Match.reset()
	var s := LobbyScene.instantiate()
	_set_ui(s)
	s.create_room_pressed.connect(show_room)
	s.showroom_pressed.connect(show_showroom)
	flow_changed.emit("lobby")

func show_room() -> void:
	var s := RoomScene.instantiate()
	_set_ui(s)
	s.play_pressed.connect(show_car_select)
	s.back_pressed.connect(show_lobby)
	flow_changed.emit("room")

func show_car_select() -> void:
	var s := CarSelectScene.instantiate()
	_set_ui(s)
	s.car_chosen.connect(func(cid: int):
		Match.car_id = cid
		start_round())
	flow_changed.emit("car_select")

# ---------------- 展示间（独立 3D 场景，关闭即返回大厅） ----------------

func show_showroom() -> void:
	_clear_ui()
	_clear_race()
	showroom = ShowroomScene.instantiate()
	add_child(showroom)  # 自带相机与 CanvasLayer UI，直接挂主节点
	showroom.close_requested.connect(show_lobby)
	flow_changed.emit("showroom")

func _clear_showroom() -> void:
	if showroom != null:
		showroom.queue_free()
		showroom = null

# ---------------- 回合循环 ----------------

## 车库→赛道过渡时长（秒）：相机飞行；两层过渡 shader 的 progress 与相机
## 缓动进度共用同一条曲线，相机没动效果不走
const GARAGE_TRANSITION_SEC := 3.5
const FINISH_SLOWMO_SCALE := 0.28
const FINISH_SLOWMO_REAL_SEC := 0.62
const FINISH_HOLD_REAL_SEC := 1.05
const RACE_TO_GARAGE_SEC := 2.0
const SweepShader := preload("res://game/shaders/garage_sweep.gdshader")
const ZoomRushShader := preload("res://game/shaders/zoom_rush.gdshader")
const SPEED_MOTION_BLUR := preload("res://game/race/speed_motion_blur.gd")

var _garage_host: Node = null      # 过渡期间保留的选车/局间宿主场景（展台在其中）
var _finish_slowmo_active := false
var _finish_base_time_scale := 1.0

func start_round() -> void:
	_clear_race()
	var stage := _begin_garage_transition()
	if stage == null:
		_clear_ui()  # 无展台（如直连调用）：保持原硬切
	if stage != null:
		await get_tree().process_frame
	race = RaceManager.new()
	world.add_child(race)
	hud = HudScene.instantiate()
	hud.bind(race)  # 先绑定再入树（_ready 即可读比赛数据）
	race.round_ended.connect(_on_round_ended)
	race.player_finished.connect(_on_player_finished)
	if stage != null:
		# 无缝过渡：倒计时挂起，过渡相机接管视口，结束后交接追尾相机
		race.setup(Match.round_index + 1, true)
		hud.modulate.a = 0.0
		ui.add_child(hud)
		# 车先自由落地静置（生成后不冻结不锚固），起始机位按落定位取——
		# 飞行全程两层画面里的车才锁得住；车库界面淡出与落地同时进行
		race.settle_grid()
		_transition_garage_to_race_cinematic(stage)
	else:
		race.setup(Match.round_index + 1)
		ui.add_child(hud)
	_setup_speed_motion_blur()
	flow_changed.emit("race")

func _setup_speed_motion_blur() -> void:
	if speed_motion_blur != null:
		speed_motion_blur.queue_free()
		speed_motion_blur = null
	if not is_instance_valid(race) or race.chase_camera == null or race.player_racer == null:
		return
	speed_motion_blur = SPEED_MOTION_BLUR.new()
	add_child(speed_motion_blur)
	speed_motion_blur.setup(race.player_racer.vehicle, race.chase_camera)

## 从当前混合场景（开局选车 / 局间整备）取出展台进入过渡：
## 宿主 UI 立即失活淡出，宿主场景本体保留到过渡结束再释放。
## 返回 null 表示当前界面没有展台（非过渡路径）。
func _begin_garage_transition() -> CarStage:
	var host := current_ui
	if host == null or not ("stage" in host) or not (host.stage is CarStage):
		return null
	_garage_host = host
	host.stage.disable_interaction()
	current_ui = null
	for layer in host.find_children("*", "CanvasLayer", true, false):
		layer.process_mode = Node.PROCESS_MODE_DISABLED  # 按钮立刻不可点
		for c in layer.get_children():
			if c is Control:
				create_tween().tween_property(c, "modulate:a", 0.0, 0.18)
	return host.stage

## 无缝过渡（分层渲染，车全程不动、发车位也不动）：
## 1. 车库展台整体搬进独立 SubViewport（own_world_3d + transparent_bg），
##    自带环境/灯光在层内继续渲染；主视口渲染比赛世界，两层画面并存。
## 2. 主视口直接复用追尾相机：摆在"车库机位的等价位姿"（车库相机相对
##    展车的变换应用到比赛车发车位上），首帧两层画面里的车完全重合。
## 3. 车库层相机逐帧跟随主相机（把主相机位姿按 发车位→展车 的映射搬进
##    车库世界，FOV 同步）——飞行全程两层画面里的车严格锁定，车库墙随
##    视角正确扫过，交叉溶解任何时刻都严丝合缝，不依赖首帧换算的精度。
## 4. 相机向追尾静止收敛位飞行（位置插值 + 姿态 slerp + FOV 收敛，
##    QUINT 缓动）。组合过渡效果与相机共用同一缓动进度接力：车库层挂
##    光带扫描 shader（前段，扫过处溶解露出赛道、辉光贴车库边缘），
##    其上全屏径向变焦 shader（中后段，屏幕纹理放射拖影冲刺感）。
## 5. 结束：恢复追尾相机物理更新（终点即其静止牵引目标，零跳变），
##    HUD 淡入、倒计时放行、车库层与宿主场景释放。
func _transition_garage_to_race(stage: CarStage) -> void:
	var pv: Vehicle = race.player_racer.vehicle
	var spawn := pv.global_transform
	# 车库相机相对展车的位姿（含拖拽朝向）→ 应用到发车位 = 主视口起始机位
	var cam_rel := stage.display_car().global_transform.affine_inverse() * stage.camera.global_transform
	var start_xf := spawn * cam_rel
	var start_fov := stage.camera.fov

	# --- 车库入层：独立世界 + 透明背景，作为全屏叠加层盖在比赛画面上 ---
	stage.disable_interaction()
	var sub := SubViewport.new()
	sub.own_world_3d = true
	sub.transparent_bg = true
	sub.size = Vector2i(get_viewport().get_visible_rect().size)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	_garage_host.remove_child(stage)
	sub.add_child(stage)
	var overlay := CanvasLayer.new()
	overlay.layer = 10   # 盖住 3D 与淡出中的 HUD，低于弹窗类 UI 的常规层位
	add_child(overlay)
	var rect := TextureRect.new()
	rect.texture = sub.get_texture()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	# 光带扫描：扫过处车库层溶解露出赛道，辉光贴着车库几何边缘
	var sweep_mat := ShaderMaterial.new()
	sweep_mat.shader = SweepShader
	rect.material = sweep_mat
	overlay.add_child(rect)

	# 径向变焦（speed rush）：全屏屏幕纹理放射拖影，盖在车库层之上，
	# 中段起量呼应相机加速（扫描起步 → 变焦冲刺 的接力节奏）
	var rush_layer := CanvasLayer.new()
	rush_layer.layer = 11
	add_child(rush_layer)
	var rush_mat := ShaderMaterial.new()
	rush_mat.shader = ZoomRushShader
	var rush := ColorRect.new()
	rush.set_anchors_preset(Control.PRESET_FULL_RECT)
	rush.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rush.material = rush_mat
	rush_layer.add_child(rush)

	# --- 主视口相机：追尾相机暂停物理，从车库等价机位飞向静止收敛位 ---
	var cam := race.chase_camera
	var cam_pos := spawn.origin + spawn.basis.z * float(cam.follow_distance)
	cam_pos.y = spawn.origin.y + float(cam.follow_height)
	cam.look_at_from_position(cam_pos, spawn.origin, Vector3.UP)
	var end_xf := cam.global_transform
	var end_fov := float(cam.minimum_fov)
	cam.set_physics_process(false)
	cam.global_transform = start_xf
	cam.fov = start_fov
	cam.make_current()

	# 变焦拖影消失点 = 起始机位下车身在屏幕上的位置；宽高比纠正放射方向
	rush_mat.set_shader_parameter("center", cam.unproject_position(spawn.origin) / Vector2(sub.size))
	rush_mat.set_shader_parameter("aspect", sub.size.x / maxf(sub.size.y, 1.0))

	# 车库层相机锁定映射：车库相机 = 展车位姿 * 发车位⁻¹ * 主相机
	# （入层后取一次展车在层内世界的位姿作锚，之后每帧套用）
	var layer_car_xf := stage.display_car().global_transform
	var spawn_inv := spawn.affine_inverse()
	var layer_cam := stage.camera
	_sync_layer_camera(layer_cam, layer_car_xf, spawn_inv, cam)

	var tw := create_tween()
	tw.tween_method(func(w: float):
		var q := start_xf.basis.get_rotation_quaternion().slerp(
				end_xf.basis.get_rotation_quaternion(), w)
		cam.global_transform = Transform3D(Basis(q),
				start_xf.origin.lerp(end_xf.origin, w))
		cam.fov = lerpf(start_fov, end_fov, w)
		_sync_layer_camera(layer_cam, layer_car_xf, spawn_inv, cam)
		# 两个过渡 shader 与相机共用同一缓动进度：相机没动效果不走，
		# 扫描（前段）与变焦（中后段）接力，相机到位效果正好收干净
		sweep_mat.set_shader_parameter("progress", w)
		rush_mat.set_shader_parameter("progress", w), 0.0, 1.0, GARAGE_TRANSITION_SEC) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_finish_garage_transition.bind(sub, overlay, rush_layer))

## 把主相机位姿按 发车位→展车 映射搬进车库层并同步 FOV：
## 保证叠加层画面与主视口里的车逐帧严格重合
## Continuous presentation pass used by car select and intermission.
func _transition_garage_to_race_cinematic(stage: CarStage) -> void:
	var pv: Vehicle = race.player_racer.vehicle
	var spawn := pv.global_transform
	var cam_rel := stage.display_car().global_transform.affine_inverse() * stage.camera.global_transform
	var start_xf := spawn * cam_rel
	var start_fov := stage.camera.fov
	stage.disable_interaction()

	var sub := SubViewport.new()
	sub.own_world_3d = true
	sub.transparent_bg = true
	sub.size = Vector2i(get_viewport().get_visible_rect().size)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	_garage_host.remove_child(stage)
	sub.add_child(stage)
	var overlay := CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)
	var rect := TextureRect.new()
	rect.texture = sub.get_texture()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	overlay.add_child(rect)

	var rush_layer := CanvasLayer.new()
	rush_layer.layer = 11
	add_child(rush_layer)
	var rush_mat := ShaderMaterial.new()
	rush_mat.shader = ZoomRushShader
	var rush := ColorRect.new()
	rush.set_anchors_preset(Control.PRESET_FULL_RECT)
	rush.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rush.material = rush_mat
	rush_layer.add_child(rush)

	var cinematic := _make_transition_overlay()
	add_child(cinematic.layer)
	_set_transition_phase(cinematic.phase, cinematic.detail, cinematic.progress,
			"ENTERING GRID", "%s  /  ROUND %d" % [String(Settings.car.data[Match.car_id].name).to_upper(), Match.round_index], 0.0)

	var cam := race.chase_camera
	var cam_pos := spawn.origin + spawn.basis.z * float(cam.follow_distance)
	cam_pos.y = spawn.origin.y + float(cam.follow_height)
	cam.look_at_from_position(cam_pos, spawn.origin, Vector3.UP)
	var end_xf := cam.global_transform
	var end_fov := float(cam.minimum_fov)
	cam.set_physics_process(false)
	cam.global_transform = start_xf
	cam.fov = start_fov
	cam.make_current()
	rush_mat.set_shader_parameter("center", cam.unproject_position(spawn.origin) / Vector2(sub.size))
	rush_mat.set_shader_parameter("aspect", sub.size.x / maxf(sub.size.y, 1.0))

	var layer_car_xf := stage.display_car().global_transform
	var spawn_inv := spawn.affine_inverse()
	var layer_cam := stage.camera
	_sync_layer_camera(layer_cam, layer_car_xf, spawn_inv, cam)

	# Position, orientation, FOV, dissolve, blur and overlay all sample the same
	# progress. Hold the showroom composition briefly, then use a direct push to
	# the chase pose; no angle wrapping or lateral orbit is involved.
	var fixed_title := "ENTERING GRID"
	var fixed_detail := "%s  /  ROUND %d" % [String(Settings.car.data[Match.car_id].name).to_upper(), Match.round_index]
	# Preserve the showroom's actual visual focus when moving the camera to the
	# physical race car. The vehicle root is not the same point as the displayed
	# car's framed center, which otherwise makes the car sit low on the first beat.
	var display_car := stage.display_car()
	var display_focus := stage.to_global(Vector3(0.0, 0.65, 0.0))
	var focus_local := display_car.global_transform.affine_inverse() * display_focus
	var fixed_focus := spawn * focus_local
	var tracked_origin := spawn.origin
	var tw := create_tween()
	tw.tween_method(func(w: float):
		if not is_instance_valid(pv) or not is_instance_valid(cam) \
				or not is_instance_valid(layer_cam) or not is_instance_valid(rect):
			return
		var live_spawn := pv.global_transform
		# The race car is the subject during this opening beat. Follow its real
		# drop and rebound with a damped origin so the physical landing reads as
		# an intentional camera-follow moment instead of a detached background.
		tracked_origin = tracked_origin.lerp(live_spawn.origin, 0.32)
		var motion_w := _smoothstep(0.10, 1.0, w)
		var pos := start_xf.origin.lerp(end_xf.origin, motion_w)
		pos += tracked_origin - spawn.origin
		var tracked_focus := tracked_origin + live_spawn.basis * focus_local
		var focus_point := fixed_focus.lerp(tracked_focus, _smoothstep(0.04, 0.28, w))
		var focus_basis := Basis.looking_at(focus_point - pos, Vector3.UP)
		var path_basis := start_xf.basis.slerp(focus_basis, _smoothstep(0.10, 0.56, w))
		path_basis = path_basis.slerp(end_xf.basis, _smoothstep(0.82, 0.98, w))
		# The chase camera's first physics frame derives this exact target from the
		# live car transform. Blend into it near the end so enabling physics cannot
		# introduce a vertical or positional snap after the car settles on the grid.
		var handoff_pos := live_spawn.origin + live_spawn.basis.z * float(cam.follow_distance)
		handoff_pos.y = live_spawn.origin.y + float(cam.follow_height)
		var handoff_basis := Basis.looking_at(live_spawn.origin - handoff_pos, Vector3.UP)
		var handoff := _smoothstep(0.86, 1.0, w)
		pos = pos.lerp(handoff_pos, handoff)
		path_basis = path_basis.slerp(handoff_basis, handoff)
		var edge_blend := _smoothstep(0.0, 0.16, w) * (1.0 - _smoothstep(0.82, 1.0, w))
		cam.global_transform = Transform3D(path_basis, pos)
		cam.fov = _lerp_camera_fov(start_fov, end_fov, _smoothstep(0.08, 1.0, w))
		_sync_layer_camera(layer_cam, layer_car_xf, live_spawn.affine_inverse(), cam)
		var live_screen_center := cam.unproject_position(live_spawn.origin) / Vector2(sub.size)
		rush_mat.set_shader_parameter("center", live_screen_center)
		_set_transition_phase(cinematic.phase, cinematic.detail, cinematic.progress, fixed_title, fixed_detail, w)
		var top_y := lerpf(-48.0, 0.0, edge_blend)
		cinematic.top.offset_top = top_y
		cinematic.top.offset_bottom = top_y + 48.0
		var bottom_y := lerpf(0.0, -56.0, edge_blend)
		cinematic.bottom.offset_top = bottom_y
		cinematic.bottom.offset_bottom = bottom_y + 56.0
		cinematic.shade.modulate.a = edge_blend
		cinematic.phase.modulate.a = edge_blend
		cinematic.detail.modulate.a = edge_blend
		cinematic.progress_bg.modulate.a = edge_blend
		cinematic.progress.modulate.a = edge_blend
		rect.modulate.a = 1.0 - _smoothstep(0.02, 0.92, w)
		rush_mat.set_shader_parameter("progress", _smoothstep(0.12, 0.96, w)), 0.0, 1.0, GARAGE_TRANSITION_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_finish_cinematic_transition.bind(sub, overlay, rush_layer, cinematic.layer))

func _make_transition_overlay() -> Dictionary:
	var layer := CanvasLayer.new()
	layer.layer = 12
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.0, 0.0, 0.0, 0.12)
	shade.modulate.a = 0.0
	root.add_child(shade)
	var top := ColorRect.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = -48.0
	top.offset_bottom = 0.0
	top.color = Color(0.015, 0.018, 0.02, 0.94)
	root.add_child(top)
	var bottom := ColorRect.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = 0.0
	bottom.offset_bottom = 56.0
	bottom.color = Color(0.015, 0.018, 0.02, 0.94)
	root.add_child(bottom)
	var phase := Label.new()
	phase.position = Vector2(42, 15)
	phase.add_theme_font_size_override("font_size", 18)
	phase.add_theme_color_override("font_color", Color(1.0, 0.82, 0.34))
	phase.modulate.a = 0.0
	root.add_child(phase)
	var detail := Label.new()
	detail.position = Vector2(42, 67)
	detail.add_theme_font_size_override("font_size", 12)
	detail.add_theme_color_override("font_color", Color(0.68, 0.72, 0.76))
	detail.modulate.a = 0.0
	root.add_child(detail)
	var bg := ColorRect.new()
	bg.position = Vector2(42, 102)
	bg.size = Vector2(190, 3)
	bg.color = Color(0.22, 0.25, 0.28, 0.9)
	bg.modulate.a = 0.0
	root.add_child(bg)
	var progress := ColorRect.new()
	progress.position = Vector2(42, 102)
	progress.size = Vector2(0, 3)
	progress.color = Color(1.0, 0.82, 0.34, 1.0)
	progress.modulate.a = 0.0
	root.add_child(progress)
	return {"layer": layer, "root": root, "shade": shade, "top": top,
			"bottom": bottom, "phase": phase, "detail": detail,
			"progress_bg": bg, "progress": progress}

func _cubic_bezier(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u * u + b * 3.0 * u * u * t + c * 3.0 * u * t * t + d * t * t * t

func _lerp_camera_fov(from_deg: float, to_deg: float, t: float) -> float:
	var from_focal := 1.0 / tan(deg_to_rad(from_deg) * 0.5)
	var to_focal := 1.0 / tan(deg_to_rad(to_deg) * 0.5)
	var focal := lerpf(from_focal, to_focal, t)
	return rad_to_deg(2.0 * atan(1.0 / maxf(focal, 0.0001)))

func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
	var x := clampf((value - edge_a) / maxf(edge_b - edge_a, 0.0001), 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func _set_transition_phase(phase: Label, detail: Label, progress: ColorRect,
		title: String, subtitle: String, amount: float) -> void:
	phase.text = title
	detail.text = subtitle
	progress.size.x = 190.0 * clampf(amount, 0.0, 1.0)

func _finish_cinematic_transition(sub: SubViewport, overlay: CanvasLayer,
		rush_layer: CanvasLayer, cinematic: CanvasLayer) -> void:
	if is_instance_valid(hud):
		create_tween().tween_property(hud, "modulate:a", 1.0, 0.6)
	if is_instance_valid(_garage_host):
		_garage_host.queue_free()
	_garage_host = null
	_safe_queue_free(rush_layer)
	_safe_queue_free(overlay)
	_safe_queue_free(cinematic)
	_safe_queue_free(sub)
	if not is_instance_valid(race) or race.chase_camera == null:
		return
	var cam := race.chase_camera
	cam.set_physics_process(true)
	race.begin_countdown()

func _sync_layer_camera(layer_cam: Camera3D, layer_car_xf: Transform3D,
		spawn_inv: Transform3D, cam: Camera3D) -> void:
	layer_cam.global_transform = layer_car_xf * spawn_inv * cam.global_transform
	layer_cam.fov = cam.fov

func _finish_garage_transition(sub: SubViewport, overlay: CanvasLayer, rush_layer: CanvasLayer) -> void:
	if is_instance_valid(hud):
		create_tween().tween_property(hud, "modulate:a", 1.0, 0.6)
	if is_instance_valid(_garage_host):
		_garage_host.queue_free()
	_garage_host = null
	_safe_queue_free(rush_layer)
	_safe_queue_free(overlay)
	_safe_queue_free(sub)
	if not is_instance_valid(race) or race.chase_camera == null:
		return
	# 终点即追尾相机静止时的牵引目标：恢复物理更新后无跳变；
	# 首帧 _prev_basis 取当前位姿，低通从终点继续，衔接平滑
	var cam := race.chase_camera
	cam.set_physics_process(true)
	race.begin_countdown()

func _safe_queue_free(node: Node) -> void:
	if is_instance_valid(node):
		node.queue_free()

func _on_player_finished(_rank: int, _finish_time: float) -> void:
	if _finish_slowmo_active:
		return
	_finish_slowmo_active = true
	_finish_base_time_scale = Engine.time_scale
	Engine.time_scale = _finish_base_time_scale * FINISH_SLOWMO_SCALE

	var cam := race.chase_camera if is_instance_valid(race) else null
	var fov_warp_was_enabled := false
	if is_instance_valid(cam):
		if "enable_fov_warp" in cam:
			fov_warp_was_enabled = bool(cam.get("enable_fov_warp"))
			cam.set("enable_fov_warp", false)
		var start_fov := cam.fov
		var fov_tw := create_tween().set_ignore_time_scale(true)
		fov_tw.tween_property(cam, "fov", start_fov + 4.0, 0.09) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		fov_tw.tween_property(cam, "fov", maxf(float(cam.minimum_fov) - 3.0, 54.0), 0.46) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	await get_tree().create_timer(FINISH_SLOWMO_REAL_SEC, true, false, true).timeout
	Engine.time_scale = _finish_base_time_scale
	_finish_slowmo_active = false
	if is_instance_valid(cam) and "enable_fov_warp" in cam:
		cam.set("enable_fov_warp", fov_warp_was_enabled)

func _on_round_ended(results: Array, rewards: Array) -> void:
	# Keep the finish beat short even while the world is running in slow motion.
	await get_tree().create_timer(FINISH_HOLD_REAL_SEC, true, false, true).timeout
	if Match.round_cfg().is_final:
		_clear_race()
		show_final_result()
		return
	var s := GarageScene.instantiate()
	s.bind(results, rewards)  # 先绑定数据再入树（_ready 时渲染）
	s.start_next_pressed.connect(start_round)
	await _transition_race_to_garage(s)
	flow_changed.emit("intermission")

func _transition_race_to_garage(garage: Node3D) -> void:
	if not is_instance_valid(race) or race.chase_camera == null \
			or race.player_racer == null or race.player_racer.vehicle == null \
			or not is_instance_valid(race.player_racer.vehicle) \
			or garage.get_node_or_null("CarStage") == null:
		_clear_race()
		_set_ui(garage)
		return

	var garage_ui := garage.get_node("UI") as CanvasLayer
	var stage := garage.get_node("CarStage") as CarStage
	var stage_cam_node := stage.get_node("Camera3D") as Camera3D
	var race_cam_for_hold: Camera3D = race.chase_camera
	# The race camera must stop at the exact handoff pose. Letting its chase
	# solver keep running underneath the garage layer creates a second motion
	# during the crossfade and makes the endpoint feel like it turns twice.
	race_cam_for_hold.set_physics_process(false)
	garage_ui.visible = false
	garage.process_mode = Node.PROCESS_MODE_DISABLED
	stage_cam_node.current = false
	add_child(garage)
	stage.disable_interaction()

	var garage_cam_xf := stage.camera.global_transform
	var garage_fov := stage.camera.fov
	var stage_local_xf := stage.transform
	var sub := SubViewport.new()
	sub.own_world_3d = true
	sub.transparent_bg = false
	sub.size = Vector2i(get_viewport().get_visible_rect().size)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	garage.remove_child(stage)
	sub.add_child(stage)
	stage.transform = stage_local_xf
	stage.camera.make_current()

	var overlay := CanvasLayer.new()
	overlay.layer = 20
	add_child(overlay)
	var rect := TextureRect.new()
	rect.texture = sub.get_texture()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_STOP
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.modulate.a = 0.0
	overlay.add_child(rect)

	await get_tree().process_frame
	if not is_instance_valid(race) or not is_instance_valid(stage):
		return
	if is_instance_valid(hud) and hud.has_method("dismiss_finish"):
		hud.dismiss_finish()

	var pv: Vehicle = race.player_racer.vehicle
	var race_cam: Camera3D = race.chase_camera
	var layer_car_xf := stage.display_car().global_transform
	var race_car_xf := pv.global_transform
	var start_xf := layer_car_xf * race_car_xf.affine_inverse() * race_cam.global_transform
	var start_fov := race_cam.fov
	stage.camera.global_transform = start_xf
	stage.camera.fov = start_fov
	var focus := stage.to_global(Vector3(0.0, 0.65, 0.0))

	var tw := create_tween().set_ignore_time_scale(true)
	tw.tween_method(func(w: float):
		if not is_instance_valid(pv) or not is_instance_valid(race_cam) \
				or not is_instance_valid(stage) or not is_instance_valid(rect):
			return
		# Phase A keeps the garage car pixel-aligned with the live race car while
		# only the environment crossfades. Phase B starts after the garage is fully
		# opaque and carries that same car into the final workshop composition.
		var matched_xf := layer_car_xf * pv.global_transform.affine_inverse() \
				* race_cam.global_transform
		var camera_w := _smoothstep(0.42, 1.0, w)
		var travel := garage_cam_xf.origin - matched_xf.origin
		var control_a := matched_xf.origin + travel * 0.3 + Vector3.UP * 0.18
		var control_b := matched_xf.origin + travel * 0.78 + Vector3.UP * 0.08
		var pos := _cubic_bezier(matched_xf.origin, control_a, control_b,
				garage_cam_xf.origin, camera_w)
		var look_basis := Basis.looking_at(focus - pos, Vector3.UP)
		var basis := matched_xf.basis.slerp(look_basis, _smoothstep(0.0, 0.72, camera_w))
		basis = basis.slerp(garage_cam_xf.basis, _smoothstep(0.82, 1.0, camera_w))
		stage.camera.global_transform = Transform3D(basis, pos)
		stage.camera.fov = _lerp_camera_fov(start_fov, garage_fov, camera_w)
		rect.modulate.a = _smoothstep(0.0, 0.42, w), 0.0, 1.0, RACE_TO_GARAGE_SEC) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

	stage.camera.global_transform = garage_cam_xf
	stage.camera.fov = garage_fov
	_clear_race()
	await get_tree().process_frame
	sub.remove_child(stage)
	garage.add_child(stage)
	stage.transform = stage_local_xf
	stage.camera.make_current()
	current_ui = garage
	garage.process_mode = Node.PROCESS_MODE_INHERIT
	garage_ui.visible = true
	stage.enable_interaction()
	var garage_root := garage_ui.get_node_or_null("Root") as Control
	if garage_root != null:
		garage_root.modulate.a = 0.0
		create_tween().set_ignore_time_scale(true).tween_property(
				garage_root, "modulate:a", 1.0, 0.42)
	await RenderingServer.frame_post_draw
	overlay.queue_free()
	sub.queue_free()

func show_final_result() -> void:
	_clear_race()
	var s := FinalScene.instantiate()
	_set_ui(s)
	s.back_pressed.connect(show_lobby)
	flow_changed.emit("final_result")

func _clear_race() -> void:
	if speed_motion_blur != null:
		speed_motion_blur.queue_free()
		speed_motion_blur = null
	if race != null:
		race.queue_free()
		race = null
	if hud != null:
		hud.queue_free()
		hud = null
