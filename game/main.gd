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

func start_round() -> void:
	_clear_race()
	_clear_ui()  # 隐藏选车/局间界面，比赛期间只显示竞速 HUD
	race = RaceManager.new()
	world.add_child(race)
	race.setup(Match.round_index + 1)
	hud = HudScene.instantiate()
	hud.bind(race)  # 先绑定再入树（_ready 即可读比赛数据）
	ui.add_child(hud)
	race.round_ended.connect(_on_round_ended)
	flow_changed.emit("race")

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
