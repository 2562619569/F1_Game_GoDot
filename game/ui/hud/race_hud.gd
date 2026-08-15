extends Control
## 竞速 HUD：静态标签版式在 tscn 内编辑（%UniqueName 引用），
## 排名行与战术槽面板为代码动态生成。
## 对外契约：bind(manager: RaceManager)。

var manager: RaceManager

@onready var round_label: Label = %RoundLabel
@onready var timer_label: Label = %TimerLabel
@onready var standings_box: VBoxContainer = %StandingsBox
@onready var countdown_label: Label = %CountdownLabel
@onready var speed_label: Label = %SpeedLabel
@onready var tactical_box: HBoxContainer = %TacticalBox
@onready var toast_label: Label = %ToastLabel

var _toast_left := 0.0
var _countdown_left := 0.0

func bind(m: RaceManager) -> void:
	manager = m
	m.countdown_tick.connect(_on_countdown)
	m.standings_updated.connect(_on_standings)
	m.toast.connect(_on_toast)

func _ready() -> void:
	if manager == null:
		return
	var map := Match.map_cfg(manager.map_id)
	round_label.text = "ROUND %d/%d  ·  %s  ·  %s" % [
		manager.round_idx, Match.round_count(), map.name, WeatherEnv.cfg(String(map.weather)).label]

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
			var p := PanelContainer.new()
			var l := Label.new()
			l.theme_type_variation = &"Accent"
			l.add_theme_font_size_override("font_size", 14)
			p.add_child(l)
			tactical_box.add_child(p)
	for i in ui_data.size():
		var panel: PanelContainer = tactical_box.get_child(i)
		var l: Label = panel.get_child(0)
		var d: Dictionary = ui_data[i]
		var cd_txt := "" if d.cd <= 0.0 else "  CD %.0fs" % d.cd
		l.text = "[%s] %s  ●%d/%d%s" % [d.key, d.name, d.ammo, d.max_ammo, cd_txt]

func _on_countdown(text: String) -> void:
	countdown_label.text = text
	_countdown_left = 1.2

func _on_standings(order: Array) -> void:
	for c in standings_box.get_children():
		c.queue_free()
	for i in order.size():
		var r: Dictionary = order[i]
		var l := Label.new()
		l.text = "P%d  %s%s" % [i + 1, r.name, "  ✔" if r.finished else ""]
		l.add_theme_font_size_override("font_size", 15)
		if r.is_player:
			l.theme_type_variation = &"Warm"
		standings_box.add_child(l)

func _on_toast(text: String) -> void:
	toast_label.text = text
	_toast_left = 2.5
