extends Control
## 局间整备（战术改车）：三栏框架版式在 tscn 内编辑；
## 结算表/奖励列表由代码渲染，装配槽位、背包格子、雷达图数据驱动刷新。
## 对外契约：start_next_pressed 信号 + ready_btn / backpack_grid / bind() / _refresh()。

signal start_next_pressed

const CATEGORY_LABELS := {
	"engine": "ENGINE", "tires": "TIRES", "aero": "AERO", "chassis": "CHASSIS", "tactical": "TACTICAL",
}

@onready var header: Label = %Header
@onready var results_grid: GridContainer = %ResultsGrid
@onready var rewards_box: VBoxContainer = %RewardsBox
@onready var garage_title: Label = %GarageTitle
@onready var slot_box: HBoxContainer = %SlotBox
@onready var backpack_grid: GridContainer = %BackpackGrid
@onready var hint_label: Label = %HintLabel
@onready var radar: Control = %Radar
@onready var next_title: Label = %NextTitle
@onready var map_name: Label = %MapName
@onready var weather_chip: Label = %WeatherChip
@onready var map_desc: Label = %MapDesc
@onready var advice_label: Label = %Advice
@onready var countdown_label: Label = %CountdownLabel
@onready var ready_btn: Button = %ReadyButton
@onready var toast_label: Label = %ToastLabel

var time_left := 0.0
var _toast_left := 0.0
var _results: Array = []
var _rewards: Array = []

## main 在入树前调用（只存数据，渲染在 _ready）
func bind(results: Array, rewards: Array) -> void:
	_results = results
	_rewards = rewards

func _ready() -> void:
	time_left = float(Match.intermission_sec_override) if Match.intermission_sec_override > 0 else Match.game_cfg("intermission_sec")
	header.text = "INTERMISSION  ·  ROUND %d / %d FINISHED" % [Match.round_index, Match.round_count()]
	garage_title.text = "LOADOUT  ·  %d PERF / %d FUNC SLOTS" % [Match.perf_slots(), Match.func_slots()]
	ready_btn.pressed.connect(func(): start_next_pressed.emit())
	_render_results()
	_render_next()
	_refresh()

# ---------------- 静态数据渲染 ----------------

## 动态生成单元格：默认样式来自全局主题，仅覆盖非默认字号/颜色
func _cell(text: String, font_size := 16, color := UIStyle.TEXT) -> Label:
	var l := Label.new()
	l.text = text
	if font_size != 16:
		l.add_theme_font_size_override("font_size", font_size)
	if color != UIStyle.TEXT:
		l.add_theme_color_override("font_color", color)
	return l

func _render_results() -> void:
	for c in results_grid.get_children():
		c.queue_free()
	for h in ["#", "DRIVER", "TIME"]:
		results_grid.add_child(_cell(h, 13, UIStyle.TEXT_DIM))
	for e in _results:
		results_grid.add_child(_cell("P%d" % e.rank, 15, UIStyle.ACCENT_WARM if e.is_player else UIStyle.TEXT))
		results_grid.add_child(_cell(String(e.name), 15, UIStyle.ACCENT if e.is_player else UIStyle.TEXT))
		results_grid.add_child(_cell("DNF" if e.dnf else "%.1fs" % e.time, 15, UIStyle.TEXT_DIM))

	for c in rewards_box.get_children():
		c.queue_free()
	if _rewards.is_empty():
		rewards_box.add_child(_cell("(no rewards)", 14, UIStyle.TEXT_DIM))
	for pid in _rewards:
		var part := Match.part_cfg(pid)
		rewards_box.add_child(_cell("+ %s  [%s]" % [part.name, Match.RARITY_NAMES[int(part.rarity)]], 15, Match.RARITY_COLORS[int(part.rarity)]))

func _render_next() -> void:
	next_title.text = "NEXT ROUND  ·  %s" % String(Match.round_cfg(Match.round_index + 1).name).to_upper()
	var map := Match.map_cfg(Match.upcoming_map_id)
	map_name.text = String(map.name)
	var wcfg := WeatherEnv.cfg(WeatherEnv.id(String(map.weather)))
	weather_chip.text = "[ %s ]" % wcfg.label
	weather_chip.add_theme_color_override("font_color", wcfg.chip)
	map_desc.text = String(map.desc)
	advice_label.text = "» " + String(wcfg.advice)

# ---------------- 装配台（数据驱动） ----------------

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

	radar.set_data(Match.base_stats(), Match.get_stats())

func _toast(text: String) -> void:
	toast_label.text = text
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
			toast_label.text = ""
