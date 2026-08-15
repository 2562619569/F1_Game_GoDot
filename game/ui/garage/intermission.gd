extends Control
## 局间整备（战术改车）界面：GDD 五要素——
## 1. 本回合结算（名次 + 奖励改件）；
## 2. 下回合地图预报（名称/介绍/天气词缀 + 配装建议）；
## 3. 改件装配台（槽位 + 无限背包 + 同类唯一）；
## 4. 属性雷达图（改装前 vs 改装后，实际性能影响）；
## 5. 倒计时（intermission_sec，可提前 Ready）。

signal start_next_pressed

const CATEGORY_LABELS := {
	"engine": "ENGINE", "tires": "TIRES", "aero": "AERO", "chassis": "CHASSIS", "tactical": "TACTICAL",
}

var ready_btn: Button
var radar: Control
var time_left := 0.0
var countdown_label: Label
var slot_box: HBoxContainer
var backpack_grid: GridContainer
var hint_label: Label
var _toast_label: Label
var _toast_left := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	time_left = float(Match.intermission_sec_override) if Match.intermission_sec_override > 0 else Match.game_cfg("intermission_sec")

	var bg := ColorRect.new()
	bg.color = UIStyle.BG.darkened(0.05)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 30
	root.offset_right = -30
	root.offset_top = 20
	root.offset_bottom = -20
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var header := Label.new()
	header.text = "INTERMISSION  ·  ROUND %d / %d FINISHED" % [Match.round_index, Match.round_count()]
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.title(header, 28)
	root.add_child(header)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	root.add_child(cols)

	cols.add_child(_build_result_panel())
	cols.add_child(_build_garage_panel())
	cols.add_child(_build_next_panel())

	_toast_label = Label.new()
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast_label.offset_bottom = -120
	UIStyle.label(_toast_label, 20, UIStyle.ACCENT_WARM)
	_toast_label.text = ""
	add_child(_toast_label)

func _build_result_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.wrap(p)
	var m := MarginContainer.new()
	UIStyle.margin_sep(m)
	p.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	m.add_child(col)

	var t := Label.new()
	t.text = "ROUND RESULT"
	UIStyle.title(t, 20)
	col.add_child(t)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	for header in ["#", "DRIVER", "TIME"]:
		var h := Label.new()
		h.text = header
		UIStyle.dim(h, 13)
		grid.add_child(h)
	for e in _results:
		var rank := Label.new()
		rank.text = "P%d" % e.rank
		UIStyle.label(rank, 15, UIStyle.ACCENT_WARM if e.is_player else UIStyle.TEXT)
		grid.add_child(rank)
		var nm := Label.new()
		nm.text = String(e.name)
		UIStyle.label(nm, 15, UIStyle.ACCENT if e.is_player else UIStyle.TEXT)
		grid.add_child(nm)
		var tm := Label.new()
		tm.text = ("DNF" if e.dnf else "%.1fs" % e.time)
		UIStyle.dim(tm, 15)
		grid.add_child(tm)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	col.add_child(gap)

	var rt := Label.new()
	rt.text = "RANK REWARDS →"
	UIStyle.title(rt, 18, UIStyle.GOOD)
	col.add_child(rt)
	if _rewards.is_empty():
		var none := Label.new()
		none.text = "(no rewards)"
		UIStyle.dim(none, 14)
		col.add_child(none)
	for pid in _rewards:
		var part := Match.part_cfg(pid)
		var l := Label.new()
		l.text = "+ %s  [%s]" % [part.name, Match.RARITY_NAMES[int(part.rarity)]]
		UIStyle.label(l, 15, Match.RARITY_COLORS[int(part.rarity)])
		col.add_child(l)

	return p

var _results: Array = []
var _rewards: Array = []

func bind(results: Array, rewards: Array) -> void:
	_results = results
	_rewards = rewards

func _build_garage_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.custom_minimum_size = Vector2(420, 0)
	UIStyle.wrap(p)
	var m := MarginContainer.new()
	UIStyle.margin_sep(m)
	p.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	m.add_child(col)

	var t := Label.new()
	t.text = "LOADOUT  ·  %d PERF / %d FUNC SLOTS" % [Match.perf_slots(), Match.func_slots()]
	UIStyle.title(t, 20)
	col.add_child(t)

	slot_box = HBoxContainer.new()
	slot_box.add_theme_constant_override("separation", 8)
	col.add_child(slot_box)

	var bt := Label.new()
	bt.text = "BACKPACK (unlimited)"
	UIStyle.dim(bt, 14)
	col.add_child(bt)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 180)
	col.add_child(scroll)
	backpack_grid = GridContainer.new()
	backpack_grid.columns = 3
	backpack_grid.add_theme_constant_override("h_separation", 6)
	backpack_grid.add_theme_constant_override("v_separation", 6)
	backpack_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(backpack_grid)

	hint_label = Label.new()
	hint_label.text = "Click a part to equip / unequip. Same category replaces."
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIStyle.dim(hint_label, 12)
	col.add_child(hint_label)

	radar = preload("res://game/ui/garage/radar_chart.gd").new()
	radar.custom_minimum_size = Vector2(240, 220)
	radar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(radar)

	_refresh()
	return p

func _build_next_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.wrap(p)
	var m := MarginContainer.new()
	UIStyle.margin_sep(m)
	p.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	m.add_child(col)

	var t := Label.new()
	t.text = "NEXT ROUND  ·  %s" % String(Match.round_cfg(Match.round_index + 1).name).to_upper()
	UIStyle.title(t, 20)
	col.add_child(t)

	var map := Match.map_cfg(Match.upcoming_map_id)
	var name_l := Label.new()
	name_l.text = String(map.name)
	UIStyle.title(name_l, 24, UIStyle.ACCENT_WARM)
	col.add_child(name_l)

	var wcfg := WeatherEnv.cfg(String(map.weather))
	var chip := Label.new()
	chip.text = "[ %s ]" % wcfg.label
	UIStyle.label(chip, 18, wcfg.chip)
	col.add_child(chip)

	var desc := Label.new()
	desc.text = String(map.desc)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIStyle.dim(desc, 14)
	col.add_child(desc)

	var advice := Label.new()
	advice.text = "» " + String(wcfg.advice)
	advice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIStyle.label(advice, 14, UIStyle.GOOD)
	col.add_child(advice)

	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(gap)

	countdown_label = Label.new()
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.label(countdown_label, 34, UIStyle.ACCENT)
	countdown_label.text = "%.0f" % time_left
	col.add_child(countdown_label)

	ready_btn = Button.new()
	ready_btn.text = "READY  ·  START NEXT ROUND"
	ready_btn.custom_minimum_size = Vector2(0, 56)
	UIStyle.style_button(ready_btn, true)
	ready_btn.pressed.connect(func(): start_next_pressed.emit())
	col.add_child(ready_btn)

	return p

func _refresh() -> void:
	if slot_box == null:
		return
	for c in slot_box.get_children():
		c.queue_free()
	for cat in CATEGORY_LABELS.keys():
		var b := Button.new()
		var equipped := Match.equipped.has(cat)
		b.text = "%s\n%s" % [CATEGORY_LABELS[cat], Match.part_cfg(Match.equipped[cat]).name if equipped else "— empty —"]
		b.custom_minimum_size = Vector2(150, 56)
		UIStyle.style_button(b)
		b.disabled = not equipped
		if equipped:
			var pid: int = Match.equipped[cat]
			var pc := Match.part_cfg(pid)
			b.add_theme_color_override("font_color", Match.RARITY_COLORS[int(pc.rarity)])
			b.pressed.connect(func():
				Match.unequip_category(cat)
				_toast("Unequipped: %s" % pc.name)
				_refresh())
		slot_box.add_child(b)

	for c in backpack_grid.get_children():
		c.queue_free()
	for pid in Match.backpack:
		var pc := Match.part_cfg(pid)
		var b := Button.new()
		var is_eq: bool = Match.equipped.get(pc.category, -1) == pid
		b.text = String(pc.name) + ("  ✓" if is_eq else "")
		b.tooltip_text = "%s\n%s\nRarity %d\nSPD%+.0f ACC%+.0f ROAD%+.0f OFF%+.0f WET%+.0f AERO%+.0f LAND%+.0f MASS%+d" % [
			pc.name, CATEGORY_LABELS[pc.category], pc.rarity,
			pc.top_speed, pc.accel, pc.grip_road, pc.grip_offroad, pc.grip_wet, pc.aero, pc.landing, pc.mass]
		b.custom_minimum_size = Vector2(130, 40)
		UIStyle.style_button(b)
		b.add_theme_color_override("font_color", Match.RARITY_COLORS[int(pc.rarity)])
		var cat: String = pc.category
		b.pressed.connect(func():
			if is_eq:
				Match.unequip_category(cat)
				_toast("Unequipped: %s" % pc.name)
			elif Match.equipped.has(cat) or Match.can_equip(pid):
				Match.equip_part(pid)
				_toast("Equipped: %s" % pc.name)
			else:
				_toast("All slots full for this part type!")
			_refresh())
		backpack_grid.add_child(b)

	if radar != null:
		radar.set_data(Match.base_stats(), Match.get_stats())

func _toast(text: String) -> void:
	_toast_label.text = text
	_toast_left = 2.0

func _process(delta: float) -> void:
	if time_left > 0.0:
		time_left -= delta
		countdown_label.text = "%.0f" % maxf(0.0, time_left)
		if time_left <= 0.0:
			start_next_pressed.emit()
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			_toast_label.text = ""
