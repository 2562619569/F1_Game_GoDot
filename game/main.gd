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
const SweepShader := preload("res://game/shaders/garage_sweep.gdshader")
const ZoomRushShader := preload("res://game/shaders/zoom_rush.gdshader")

var _garage_host: Node = null      # 过渡期间保留的选车/局间宿主场景（展台在其中）

func start_round() -> void:
	_clear_race()
	var stage := _begin_garage_transition()
	if stage == null:
		_clear_ui()  # 无展台（如直连调用）：保持原硬切
	race = RaceManager.new()
	world.add_child(race)
	hud = HudScene.instantiate()
	hud.bind(race)  # 先绑定再入树（_ready 即可读比赛数据）
	race.round_ended.connect(_on_round_ended)
	if stage != null:
		# 无缝过渡：倒计时挂起，过渡相机接管视口，结束后交接追尾相机
		race.setup(Match.round_index + 1, true)
		hud.modulate.a = 0.0
		ui.add_child(hud)
		_transition_garage_to_race(stage)
	else:
		race.setup(Match.round_index + 1)
		ui.add_child(hud)
	flow_changed.emit("race")

## 从当前混合场景（开局选车 / 局间整备）取出展台进入过渡：
## 宿主 UI 立即失活淡出，宿主场景本体保留到过渡结束再释放。
## 返回 null 表示当前界面没有展台（非过渡路径）。
func _begin_garage_transition() -> CarStage:
	var host := current_ui
	if host == null or not ("stage" in host) or not (host.stage is CarStage):
		return null
	_garage_host = host
	current_ui = null
	for layer in host.find_children("*", "CanvasLayer", true, false):
		layer.process_mode = Node.PROCESS_MODE_DISABLED  # 按钮立刻不可点
		for c in layer.get_children():
			if c is Control:
				create_tween().tween_property(c, "modulate:a", 0.0, 0.35)
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
func _sync_layer_camera(layer_cam: Camera3D, layer_car_xf: Transform3D,
		spawn_inv: Transform3D, cam: Camera3D) -> void:
	layer_cam.global_transform = layer_car_xf * spawn_inv * cam.global_transform
	layer_cam.fov = cam.fov

func _finish_garage_transition(sub: SubViewport, overlay: CanvasLayer, rush_layer: CanvasLayer) -> void:
	if is_instance_valid(hud):
		create_tween().tween_property(hud, "modulate:a", 1.0, 0.6)
	if _garage_host != null:
		_garage_host.queue_free()
		_garage_host = null
	rush_layer.queue_free()
	overlay.queue_free()
	sub.queue_free()
	if not is_instance_valid(race) or race.chase_camera == null:
		return
	# 终点即追尾相机静止时的牵引目标：恢复物理更新后无跳变；
	# 首帧 _prev_basis 取当前位姿，低通从终点继续，衔接平滑
	var cam := race.chase_camera
	cam.set_physics_process(true)
	race.begin_countdown()

func _on_round_ended(results: Array, rewards: Array) -> void:
	# 等待 HUD 显示最后一帧结算提示后切界面
	await get_tree().create_timer(1.2).timeout
	# 局间是 3D 展台场景，需要独占相机与环境，回合世界（含 HUD）先撤下
	_clear_race()
	if Match.round_cfg().is_final:
		show_final_result()
		return
	var s := GarageScene.instantiate()
	s.bind(results, rewards)  # 先绑定数据再入树（_ready 时渲染）
	_set_ui(s)
	s.start_next_pressed.connect(start_round)
	flow_changed.emit("intermission")

func show_final_result() -> void:
	_clear_race()
	var s := FinalScene.instantiate()
	_set_ui(s)
	s.back_pressed.connect(show_lobby)
	flow_changed.emit("final_result")

func _clear_race() -> void:
	if race != null:
		race.queue_free()
		race = null
	if hud != null:
		hud.queue_free()
		hud = null
