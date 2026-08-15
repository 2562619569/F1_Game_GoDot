extends Control
## 终局结算：决赛冠军加冕 + 各回合名次总表，返回大厅开启新的一局。

signal back_pressed

var back_btn: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = UIStyle.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 80
	root.offset_right = -80
	root.offset_top = 30
	root.offset_bottom = -30
	root.add_theme_constant_override("separation", 14)
	add_child(root)

	var title := Label.new()
	title.text = "FINAL SHOWDOWN COMPLETE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(title, 34)
	root.add_child(title)

	var champ := Label.new()
	champ.text = "🏆  CHAMPION: %s  🏆" % (Match.champion if Match.champion != "" else "—")
	champ.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(champ, 44, UIStyle.ACCENT_WARM)
	root.add_child(champ)

	var note := Label.new()
	note.text = "First across the line in the final round takes the crown."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.dim(note, 14)
	root.add_child(note)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	root.add_child(gap)

	# 各回合名次总表
	var names: Array = []
	for e in Match.round_history[0] if Match.round_history.size() > 0 else []:
		names.append(e.name)
	var grid := GridContainer.new()
	grid.columns = names.size() + 1
	grid.add_theme_constant_override("h_separation", 26)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(grid)

	var corner := Label.new()
	corner.text = ""
	grid.add_child(corner)
	for n in names:
		var h := Label.new()
		h.text = String(n)
		UIStyle.title(h, 17, UIStyle.ACCENT if n == Match.PLAYER_NAME else UIStyle.TEXT)
		grid.add_child(h)

	for ri in Match.round_history.size():
		var round_results: Array = Match.round_history[ri]
		var rl := Label.new()
		rl.text = "ROUND %d" % (ri + 1)
		UIStyle.dim(rl, 15)
		grid.add_child(rl)
		for n in names:
			var cell := Label.new()
			var rank := "-"
			for e in round_results:
				if e.name == n:
					rank = "P%d" % e.rank
			cell.text = rank
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UIStyle.label(cell, 16, UIStyle.ACCENT_WARM if n == Match.PLAYER_NAME else UIStyle.TEXT)
			grid.add_child(cell)

	var gap2 := Control.new()
	gap2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(gap2)

	back_btn = Button.new()
	back_btn.text = "BACK TO LOBBY  ·  NEW MATCH"
	back_btn.custom_minimum_size = Vector2(360, 60)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UIStyle.style_button(back_btn, true)
	back_btn.pressed.connect(func(): back_pressed.emit())
	root.add_child(back_btn)
