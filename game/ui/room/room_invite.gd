extends Control
## 邀请界面：房间码 + 8 个竖排玩家位 + ADD AI 加人机 + PLAY 开始游戏。
## 座位表来自 Net.session（离线 = 本地房间沿用 AI_DEFS 入座，观感与原版一致；
## 在线 = Steam 大厅好友按加入顺序入座 + 房主权威的 AI 数/开始权限）。
## 版式在 room_invite.tscn；对外契约：play_pressed / back_pressed 信号
## + play_btn / room_code_label / invite_btn（供 main / 冒烟测试驱动）。

signal play_pressed
signal back_pressed

@onready var room_code_label: Label = %RoomCodeLabel
@onready var play_btn: Button = %PlayButton
@onready var slots_box: VBoxContainer = %Slots
@onready var add_ai_btn: Button = %AddAiButton
@onready var seats_label: Label = %SeatsLabel
@onready var invite_btn: Button = %InviteButton
@onready var title_label: Label = %TitleLabel

func _ready() -> void:
	add_ai_btn.pressed.connect(_on_add_ai)
	invite_btn.pressed.connect(func(): Net.session.invite_friends())
	play_btn.pressed.connect(_on_play)
	%BackButton.pressed.connect(_on_back)
	%InfoLabel.text = "%d sub-rounds · Loot & tune between rounds · Points per finish, final pays extra for comebacks" % Match.round_count()
	Net.session.seats_changed.connect(_refresh_slots)
	Net.session.host_changed.connect(func(_h: int): _refresh_slots())
	Net.session.joined.connect(_on_joined)
	Net.session.net_error.connect(_on_net_error)
	_refresh_slots()

func _on_net_error(text: String) -> void:
	# 加入失败/权限不足等：大厅已不在（active=false）时明示，不留在空房间界面
	%InfoLabel.text = text
	if not Net.session.active:
		title_label.text = "JOIN FAILED"

func _on_joined(as_host: bool) -> void:
	title_label.text = "ROOM CREATED" if as_host else "JOINED ROOM"
	_refresh_slots()

## 房间码：在线 = Steam 大厅 id（好友覆盖层"加入游戏"即用此值）；
## 离线 = 本地随机码（保持原观感，冒烟测试断言 length > 8）
func _refresh_slots() -> void:
	if Net.session.online() and Net.session.lobby_id != 0:
		room_code_label.text = "ROOM  #%d" % Net.session.lobby_id
	elif room_code_label.text == "ROOM  MR-????":
		room_code_label.text = "ROOM  %s" % _gen_room_code()

	var taken := 0
	var rows_data: Array = Net.session.seat_rows()
	var rows := slots_box.get_children()
	for i in rows.size():
		var d: Dictionary = rows_data[i]
		var name_l: Label = rows[i].get_node("M/Row/NameLabel")
		var status_l: Label = rows[i].get_node("M/Row/StatusLabel")
		match String(d.kind):
			"human":
				var suffix := "  (YOU)" if d.me and Net.session.online() else ""
				name_l.text = "%s%s" % [d.name, suffix]
				status_l.text = "HOST" if d.host else "READY"
				rows[i].modulate = Color.WHITE
				taken += 1
			"ai":
				name_l.text = String(d.name)
				status_l.text = "AI · READY"
				rows[i].modulate = Color.WHITE
				taken += 1
			_:
				name_l.text = "—"
				status_l.text = "OPEN"
				rows[i].modulate = Color(1, 1, 1, 0.45)
	seats_label.text = "SEATS  %d / %d" % [taken, rows.size()]

	# 在线：邀请按钮可见；ADD AI 与 PLAY 仅房主可用（客户端等待房主）
	var online := Net.online()
	var is_host := Net.session.is_host()
	invite_btn.visible = online
	add_ai_btn.visible = not online or is_host
	add_ai_btn.disabled = taken >= rows.size()
	add_ai_btn.text = "ROOM FULL" if add_ai_btn.disabled else "+ ADD AI"
	if online and not is_host:
		play_btn.disabled = true
		play_btn.text = "WAIT FOR HOST"
	else:
		play_btn.disabled = false
		play_btn.text = "PLAY"

func _on_add_ai() -> void:
	Net.session.add_ai()

func _on_play() -> void:
	# 离线直通原流程；在线走房主权威广播（各端经 start_requested 进选车）
	if Net.session.active:
		Net.session.start_round()
	else:
		play_pressed.emit()

func _on_back() -> void:
	Net.session.leave_room()
	back_pressed.emit()

func _gen_room_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := "MR-"
	for i in 4:
		code += chars[randi() % chars.length()]
	return code
