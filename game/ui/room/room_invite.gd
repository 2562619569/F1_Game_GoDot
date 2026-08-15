extends Control
## 邀请界面：房间码 + 玩家位 + PLAY 开始游戏。
## 版式在 room_invite.tscn；脚本只生成房间码、填充玩家位文本并接线。
## 对外契约：play_pressed / back_pressed 信号 + play_btn / room_code_label。

signal play_pressed
signal back_pressed

@onready var room_code_label: Label = %RoomCodeLabel
@onready var play_btn: Button = %PlayButton
@onready var slots_box: HBoxContainer = %Slots

func _ready() -> void:
	room_code_label.text = "ROOM  %s" % _gen_room_code()
	# 玩家位：测试环境 YOU + 3 AI 自动入座
	var names := [Match.PLAYER_NAME + "\n(HOST)"]
	for d in Match.AI_DEFS:
		names.append(String(d.name) + "\n(AI · READY)")
	var cards := slots_box.get_children()
	for i in mini(names.size(), cards.size()):
		var l := cards[i].get_child(0) as Label
		if l != null:
			l.text = names[i]
	%InfoLabel.text = "%d sub-rounds · Loot & tune between rounds · Final round decides the champion" % Match.round_count()
	play_btn.pressed.connect(func(): play_pressed.emit())
	%BackButton.pressed.connect(func(): back_pressed.emit())

func _gen_room_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := "MR-"
	for i in 4:
		code += chars[randi() % chars.length()]
	return code
