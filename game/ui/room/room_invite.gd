extends Control
## 邀请界面：房间码 + 8 个竖排玩家位 + ADD AI 加人机 + PLAY 开始游戏。
## 版式在 room_invite.tscn；脚本只生成房间码、按 Match 入座状态刷新玩家位并接线。
## 对外契约：play_pressed / back_pressed 信号 + play_btn / room_code_label。

signal play_pressed
signal back_pressed

@onready var room_code_label: Label = %RoomCodeLabel
@onready var play_btn: Button = %PlayButton
@onready var slots_box: VBoxContainer = %Slots
@onready var add_ai_btn: Button = %AddAiButton
@onready var seats_label: Label = %SeatsLabel

func _ready() -> void:
	room_code_label.text = "ROOM  %s" % _gen_room_code()
	_refresh_slots()
	add_ai_btn.pressed.connect(_on_add_ai)
	%InfoLabel.text = "%d sub-rounds · Loot & tune between rounds · Points per finish, final pays extra for comebacks" % Match.round_count()
	play_btn.pressed.connect(func(): play_pressed.emit())
	%BackButton.pressed.connect(func(): back_pressed.emit())

## 刷新 8 个座位：P1 恒为玩家，其后按 Match.ai_count 入座 AI，剩余显示半透明空位
func _refresh_slots() -> void:
	var ai := Match.active_ai_defs()
	var rows := slots_box.get_children()
	for i in rows.size():
		var name_l: Label = rows[i].get_node("M/Row/NameLabel")
		var status_l: Label = rows[i].get_node("M/Row/StatusLabel")
		if i == 0:
			name_l.text = Match.PLAYER_NAME
			status_l.text = "HOST"
			rows[i].modulate = Color.WHITE
		elif i - 1 < ai.size():
			name_l.text = String(ai[i - 1].name)
			status_l.text = "AI · READY"
			rows[i].modulate = Color.WHITE
		else:
			name_l.text = "—"
			status_l.text = "OPEN"
			rows[i].modulate = Color(1, 1, 1, 0.45)
	var seats := 1 + ai.size()
	seats_label.text = "SEATS  %d / %d" % [seats, rows.size()]
	add_ai_btn.disabled = seats >= rows.size()
	add_ai_btn.text = "ROOM FULL" if add_ai_btn.disabled else "+ ADD AI"

func _on_add_ai() -> void:
	Match.ai_count += 1
	_refresh_slots()

func _gen_room_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := "MR-"
	for i in 4:
		code += chars[randi() % chars.length()]
	return code
