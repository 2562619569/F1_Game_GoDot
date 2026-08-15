extends Control
## 竞速 HUD：回合/地图/天气、实时排名、倒计时、速度挡位、
## 战术技能（弹药/冷却）、拾取与冲线提示。

var manager: RaceManager

var round_label: Label
var timer_label: Label
var standings_box: VBoxContainer
var countdown_label: Label
var speed_label: Label
var tactical_box: HBoxContainer
var toast_label: Label

var _toast_left := 0.0
var _countdown_left := 0.0

func bind(m: RaceManager) -> void:
	manager = m
	m.countdown_tick.connect(_on_countdown)
	m.standings_updated.connect(_on_standings)
	m.toast.connect(_on_toast)

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if manager == null:
		return

	var map := Match.map_cfg(manager.map_id)
	round_label = _mk_label("ROUND %d/%d  ·  %s  ·  %s" % [
		manager.round_idx, Match.round_count(), map.name, WeatherEnv.cfg(String(map.weather)).label], 17)
	round_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	round_label.offset_left = 16
	round_label.offset_top = 12
	add_child(round_label)

	timer_label = _mk_label("", 17, UIStyle.ACCENT_WARM)
	timer_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	timer_label.offset_right = -16
	timer_label.offset_top = 12
	timer_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(timer_label)

	standings_box = VBoxContainer.new()
	standings_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	standings_box.offset_right = -16
	standings_box.offset_top = 44
	standings_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(standings_box)

	countdown_label = _mk_label("", 90, UIStyle.ACCENT)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	countdown_label.pivot_offset = Vector2(50, 50)  # 相对偏移占位
	add_child(countdown_label)

	speed_label = _mk_label("", 24)
	speed_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	speed_label.offset_left = 16
	speed_label.offset_bottom = -16
	speed_label.offset_top = -60
	add_child(speed_label)

	tactical_box = HBoxContainer.new()
	tactical_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	tactical_box.offset_right = -16
	tactical_box.offset_bottom = -16
	tactical_box.add_theme_constant_override("separation", 10)
	tactical_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(tactical_box)

	toast_label = _mk_label("", 22, UIStyle.ACCENT_WARM)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	toast_label.offset_bottom = -140
	add_child(toast_label)

func _mk_label(text: String, font_size := 16, color := UIStyle.TEXT) -> Label:
	var l := Label.new()
	l.text = text
	UIStyle.label(l, font_size, color)
	return l

func _process(delta: float) -> void:
	if manager == null or manager.ended:
		return
	var v: Vehicle = manager.player_racer.vehicle
	speed_label.text = "%d km/h   G%d" % [roundi(v.speed * 3.6), maxi(0, v.current_gear)]
	var limit := float(Match.round_cfg().time_limit)
	timer_label.text = "%d / %ds" % [roundi(manager.race_time), roundi(limit)]

	if _countdown_left > 0.0:
		_countdown_left -= delta
		if _countdown_left <= 0.0:
			countdown_label.text = ""
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			toast_label.text = ""

	_refresh_tactical()

func _refresh_tactical() -> void:
	var ui_data: Array = manager.player_racer.ctrl.tactical_ui()
	if tactical_box.get_child_count() != ui_data.size():
		for c in tactical_box.get_children():
			c.queue_free()
		for i in ui_data.size():
			tactical_box.add_child(_mk_tactical_panel())
	for i in ui_data.size():
		var panel: PanelContainer = tactical_box.get_child(i)
		var l: Label = panel.get_child(0)
		var d: Dictionary = ui_data[i]
		var cd_txt := "" if d.cd <= 0.0 else "  CD %.0fs" % d.cd
		l.text = "[%s] %s  ●%d/%d%s" % [d.key, d.name, d.ammo, d.max_ammo, cd_txt]

func _mk_tactical_panel() -> PanelContainer:
	var p := PanelContainer.new()
	UIStyle.wrap(p)
	var l := _mk_label("", 14, UIStyle.ACCENT)
	p.add_child(l)
	return p

func _on_countdown(text: String) -> void:
	countdown_label.text = text
	_countdown_left = 1.2

func _on_standings(order: Array) -> void:
	for c in standings_box.get_children():
		c.queue_free()
	for i in order.size():
		var r: Dictionary = order[i]
		var l := _mk_label("P%d  %s%s" % [i + 1, r.name, "  ✔" if r.finished else ""], 15)
		if r.is_player:
			l.add_theme_color_override("font_color", UIStyle.ACCENT_WARM)
		standings_box.add_child(l)

func _on_toast(text: String) -> void:
	toast_label.text = text
	_toast_left = 2.5
