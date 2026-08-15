extends Control
## 邀请界面：展示房间码与玩家位，PLAY 开始游戏（进入开局选车）。

signal play_pressed
signal back_pressed

var play_btn: Button
var room_code_label: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = UIStyle.BG.darkened(0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_CENTER)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 14)
	root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(root)

	var title := Label.new()
	title.text = "ROOM CREATED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(title, 40)
	root.add_child(title)

	var panel := PanelContainer.new()
	UIStyle.wrap(panel)
	root.add_child(panel)
	var margin := MarginContainer.new()
	UIStyle.margin_sep(margin)
	panel.add_child(margin)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	margin.add_child(inner)

	room_code_label = Label.new()
	room_code_label.text = "ROOM  %s" % _gen_room_code()
	room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.label(room_code_label, 30, UIStyle.ACCENT_WARM)
	inner.add_child(room_code_label)

	# 玩家位：测试环境 YOU + 3 AI 自动入座
	var slots := HBoxContainer.new()
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	slots.add_theme_constant_override("separation", 12)
	inner.add_child(slots)
	var names := [Match.PLAYER_NAME + "\n(HOST)"]
	for d in Match.AI_DEFS:
		names.append(String(d.name) + "\n(AI · READY)")
	for n in names:
		var c := PanelContainer.new()
		var box := panel_box_card()
		c.add_theme_stylebox_override("panel", box)
		slots.add_child(c)
		var l := Label.new()
		l.text = n
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UIStyle.label(l, 14)
		c.add_child(l)

	var info := Label.new()
	info.text = "%d sub-rounds · Loot & tune between rounds · Final round decides the champion"
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.dim(info, 14)
	root.add_child(info)
	info.text = info.text % [Match.round_count()]

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 16)
	root.add_child(gap)

	play_btn = Button.new()
	play_btn.text = "PLAY"
	play_btn.custom_minimum_size = Vector2(300, 64)
	UIStyle.style_button(play_btn, true)
	play_btn.pressed.connect(func(): play_pressed.emit())
	root.add_child(play_btn)

	var back := Button.new()
	back.text = "BACK TO LOBBY"
	back.custom_minimum_size = Vector2(300, 44)
	UIStyle.style_button(back)
	back.pressed.connect(func(): back_pressed.emit())
	root.add_child(back)

func _gen_room_code() -> String:
	var chars := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code := "MR-"
	for i in 4:
		code += chars[randi() % chars.length()]
	return code

func panel_box_card() -> StyleBoxFlat:
	return UIStyle.panel_box(UIStyle.BG_CARD)
