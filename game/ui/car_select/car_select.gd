extends Control
## 开局选车：从 Car 表渲染 3 款底盘卡片，选定后整局不可换底盘。

signal car_chosen(car_id: int)

var card_buttons: Array = []

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = UIStyle.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 60
	root.offset_right = -60
	root.offset_top = 40
	root.offset_bottom = -40
	root.add_theme_constant_override("separation", 24)
	add_child(root)

	var title := Label.new()
	title.text = "CHOOSE YOUR CHASSIS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(title, 36)
	root.add_child(title)

	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 24)
	cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cards)

	for cid in [1, 2, 3]:
		var c: Dictionary = Settings.car.data[cid]
		cards.add_child(_make_card(c))

func _make_card(c: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(300, 0)
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIStyle.wrap(card)

	var margin := MarginContainer.new()
	UIStyle.margin_sep(margin)
	card.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	var name_l := Label.new()
	name_l.text = String(c.name)
	UIStyle.title(name_l, 26, UIStyle.ACCENT_WARM)
	col.add_child(name_l)

	var drive := Label.new()
	drive.text = "%s  ·  %d kg" % [String(c.drive).to_upper(), int(c.weight)]
	UIStyle.dim(drive, 15)
	col.add_child(drive)

	col.add_child(_bar_row("TOP SPEED", float(c.top_speed), 340.0))
	col.add_child(_bar_row("ACCEL", float(c.accel), 10.0))
	col.add_child(_bar_row("HANDLING", float(c.handling), 10.0))
	col.add_child(_bar_row("OFFROAD", float(c.grip_offroad), 10.0))

	var slots := Label.new()
	slots.text = "SLOTS: %d PERF + %d FUNC" % [int(c.perf_slots), int(c.func_slots)]
	UIStyle.label(slots, 15, UIStyle.GOOD)
	col.add_child(slots)

	var desc := Label.new()
	desc.text = String(c.desc)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIStyle.dim(desc, 13)
	col.add_child(desc)

	var pick := Button.new()
	pick.text = "SELECT"
	pick.custom_minimum_size = Vector2(0, 52)
	UIStyle.style_button(pick, true)
	pick.pressed.connect(func(): car_chosen.emit(int(c.id)))
	col.add_child(pick)
	card_buttons.append(pick)

	return card

func _bar_row(caption: String, value: float, max_v: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var cap := Label.new()
	cap.text = caption
	cap.custom_minimum_size = Vector2(110, 0)
	UIStyle.dim(cap, 13)
	row.add_child(cap)
	var bar := Label.new()
	var n := clampi(roundi(value / max_v * 10.0), 0, 10)
	bar.text = "█".repeat(n) + "·".repeat(10 - n)
	UIStyle.label(bar, 14, UIStyle.ACCENT)
	row.add_child(bar)
	return row
