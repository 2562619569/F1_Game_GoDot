extends Control
## 大厅：创建房间入口。

signal create_room_pressed

var create_room_btn: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = UIStyle.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 18)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(center)

	var title := Label.new()
	title.text = "MODRACER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(title, 64, UIStyle.ACCENT)
	center.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Arcade Racing · Session-based Roguelite Tuning"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.dim(subtitle, 18)
	center.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 40)
	center.add_child(gap)

	create_room_btn = Button.new()
	create_room_btn.text = "CREATE ROOM"
	create_room_btn.custom_minimum_size = Vector2(340, 68)
	UIStyle.style_button(create_room_btn, true)
	create_room_btn.pressed.connect(func(): create_room_pressed.emit())
	center.add_child(create_room_btn)

	var exit_btn := Button.new()
	exit_btn.text = "EXIT"
	exit_btn.custom_minimum_size = Vector2(340, 48)
	UIStyle.style_button(exit_btn)
	exit_btn.pressed.connect(func(): get_tree().quit())
	center.add_child(exit_btn)

	var footer := Label.new()
	footer.text = "WASD Drive · SPACE Handbrake · Q/E Tactical · F10 Debug Finish"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_bottom = -16
	footer.offset_top = -44
	UIStyle.dim(footer, 14)
	add_child(footer)
