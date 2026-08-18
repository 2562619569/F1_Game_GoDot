extends Control
## 竞速 HUD：静态标签版式在 tscn 内编辑（%UniqueName 引用），
## 排名行与战术槽面板为代码动态生成。
## 排名行带换位动效：槽位由代码手动布局（非容器排布），行节点跨刷新复用，
## 换位时滑动到新槽位，名次变更的徽标弹跳放大并闪色（升位偏绿、降位偏红）。
## 对外契约：bind(manager: RaceManager)。

const ROW_STRIDE := 32.0  # 排名行距（24 行高 + 8 行距）
const SLIDE_SEC := 0.35   # 换位滑动时长

var manager: RaceManager

@onready var minimap: RaceMiniMap = %MiniMap
@onready var round_label: Label = %RoundLabel
@onready var timer_label: Label = %TimerLabel
@onready var standings_box: Control = %StandingsBox
@onready var countdown_label: Label = %CountdownLabel
@onready var speedometer: Speedometer = %Speedometer
@onready var tactical_box: HBoxContainer = %TacticalBox
@onready var toast_label: Label = %ToastLabel

var _rows := {}   # Racer -> 行节点：跨刷新复用，动效才不会被打断重建
var _ranks := {}  # Racer -> 上次名次：判定升/降位触发徽标动效

var _toast_left := 0.0
var _countdown_left := 0.0
var _finish_root: Control
var _finish_top: ColorRect
var _finish_bottom: ColorRect
var _finish_title: Label
var _finish_detail: Label

func bind(m: RaceManager) -> void:
	manager = m
	m.countdown_tick.connect(_on_countdown)
	m.standings_updated.connect(_on_standings)
	m.toast.connect(_on_toast)
	m.player_finished.connect(show_finish)

func _ready() -> void:
	_build_finish_overlay()
	minimap.bind(manager)
	if manager == null:
		return
	var info := manager.race_info()
	round_label.text = "ROUND %d/%d  ·  %s  ·  %s" % [
		info.round_idx, info.round_count, info.map_name, info.weather_label]

func _process(delta: float) -> void:
	if manager == null or manager.ended or manager.player_racer == null:
		return
	speedometer.set_values(manager.player_speed_kmh(), manager.player_gear(),
			manager.player_rpm(), manager.player_max_rpm())
	timer_label.text = "%d / %ds" % [roundi(manager.race_time), roundi(manager.time_limit_s())]

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
	var ui_data: Array = manager.player_tactical_ui()
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
	var first_fill := _rows.is_empty()
	# 下榜车手行移除（正常对局不会发生，防御处理）
	for r in _rows.keys():
		if order.find(r) < 0:
			_rows[r].queue_free()
			_rows.erase(r)
			_ranks.erase(r)
	for i in order.size():
		var r: Racer = order[i]
		var row: Control = _rows.get(r)
		if row == null:
			row = _make_standing_row(r)
			row.position = Vector2(0.0, _slot_y(i))
			standings_box.add_child(row)
			_rows[r] = row
			if not first_fill:
				row.modulate.a = 0.0
				create_tween().tween_property(row, "modulate:a", 1.0, 0.25)
		standings_box.move_child(row, i)
		_update_row(row, i + 1, r)

## 刷新行内容并按需启动动效：换位滑动 + 名次变更徽标弹跳
func _update_row(row: Control, rank: int, r: Racer) -> void:
	var badge: Control = row.get_child(0)
	(badge.get_child(0) as Label).text = str(rank)
	(row.get_child(1) as Label).text = r.name + ("  ✔" if r.finished else "")
	var target_y := _slot_y(rank - 1)
	if absf(row.position.y - target_y) > 0.01:
		_restart_tween(row, &"slide_tween").tween_property(
				row, "position:y", target_y, SLIDE_SEC
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _ranks.has(r) and _ranks[r] != rank:
		_punch_badge(badge, rank < _ranks[r])
	_ranks[r] = rank

func _slot_y(idx: int) -> float:
	return idx * ROW_STRIDE

## 排名行：方形序号徽标 + 名字，玩家行橙色高亮
func _make_standing_row(r: Racer) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	row.add_child(_make_rank_badge(r.is_player))
	var l := Label.new()
	l.text = r.name
	l.add_theme_font_size_override("font_size", 15)
	if r.is_player:
		l.theme_type_variation = &"Warm"
	row.add_child(l)
	return row

## 方形序号徽标：玩家 = 橙底深字（呼应 Primary 按钮），AI = 卡片底白字
func _make_rank_badge(is_player: bool) -> PanelContainer:
	var box := StyleBoxFlat.new()
	if is_player:
		box.bg_color = UIStyle.ACCENT_WARM
		box.border_color = UIStyle.ACCENT_WARM
	else:
		box.bg_color = UIStyle.BG_CARD
		box.border_color = UIStyle.BG_CARD.lightened(0.08)
	box.border_width_left = 1
	box.border_width_right = 1
	box.border_width_top = 1
	box.border_width_bottom = 1
	box.corner_radius_top_left = 5
	box.corner_radius_top_right = 5
	box.corner_radius_bottom_left = 5
	box.corner_radius_bottom_right = 5
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(24, 24)
	badge.pivot_offset = Vector2(12, 12)
	badge.mouse_filter = MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", box)
	var num := Label.new()
	num.text = "0"
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num.add_theme_font_size_override("font_size", 14)
	if is_player:
		num.add_theme_color_override("font_color", Color("08131a"))
		num.add_theme_constant_override("outline_size", 0)
	badge.add_child(num)
	return badge

## 名次变更徽标动效：放大弹回 + 颜色闪动（升位偏绿、降位偏红）
func _punch_badge(badge: Control, improved: bool) -> void:
	var flash := Color.WHITE.lerp(UIStyle.GOOD if improved else UIStyle.DANGER, 0.6)
	var tw := _restart_tween(badge, &"punch_tween")
	tw.tween_property(badge, "scale", Vector2(1.35, 1.35), 0.12) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(badge, "modulate", flash, 0.12)
	tw.tween_property(badge, "scale", Vector2.ONE, 0.24) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(badge, "modulate", Color.WHITE, 0.24)

## 同一节点上的旧动效先杀再启，连续换位时避免 tween 叠加互相打架
func _restart_tween(obj: Object, key: StringName) -> Tween:
	if obj.has_meta(key):
		var old: Tween = obj.get_meta(key)
		if is_instance_valid(old):
			old.kill()
	var tw := create_tween()
	obj.set_meta(key, tw)
	return tw

func _on_toast(text: String) -> void:
	toast_label.text = text
	_toast_left = 2.5

func _build_finish_overlay() -> void:
	_finish_root = Control.new()
	_finish_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_finish_root.mouse_filter = MOUSE_FILTER_IGNORE
	_finish_root.visible = false
	add_child(_finish_root)

	_finish_top = ColorRect.new()
	_finish_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_finish_top.offset_top = -58.0
	_finish_top.offset_bottom = 0.0
	_finish_top.color = Color(0.01, 0.012, 0.014, 0.96)
	_finish_root.add_child(_finish_top)

	_finish_bottom = ColorRect.new()
	_finish_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_finish_bottom.offset_top = 0.0
	_finish_bottom.offset_bottom = 64.0
	_finish_bottom.color = Color(0.01, 0.012, 0.014, 0.96)
	_finish_root.add_child(_finish_bottom)

	_finish_title = Label.new()
	_finish_title.set_anchors_preset(Control.PRESET_CENTER)
	_finish_title.offset_left = -260.0
	_finish_title.offset_top = -66.0
	_finish_title.offset_right = 260.0
	_finish_title.offset_bottom = 24.0
	_finish_title.pivot_offset = Vector2(260.0, 45.0)
	_finish_title.text = "FINISH"
	_finish_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_finish_title.add_theme_font_size_override("font_size", 72)
	_finish_title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.36))
	_finish_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.82))
	_finish_title.add_theme_constant_override("outline_size", 8)
	_finish_root.add_child(_finish_title)

	_finish_detail = Label.new()
	_finish_detail.set_anchors_preset(Control.PRESET_CENTER)
	_finish_detail.offset_left = -240.0
	_finish_detail.offset_top = 24.0
	_finish_detail.offset_right = 240.0
	_finish_detail.offset_bottom = 60.0
	_finish_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_finish_detail.add_theme_font_size_override("font_size", 20)
	_finish_detail.add_theme_color_override("font_color", Color(0.9, 0.94, 0.96))
	_finish_detail.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	_finish_detail.add_theme_constant_override("outline_size", 5)
	_finish_root.add_child(_finish_detail)

func show_finish(rank: int, finish_time: float) -> void:
	_finish_root.visible = true
	_finish_detail.text = "P%d  /  %s" % [rank, _format_finish_time(finish_time)]
	_finish_top.offset_top = -58.0
	_finish_top.offset_bottom = 0.0
	_finish_bottom.offset_top = 0.0
	_finish_bottom.offset_bottom = 64.0
	_finish_title.modulate.a = 0.0
	_finish_title.scale = Vector2(0.92, 0.92)
	_finish_detail.modulate.a = 0.0
	var bars := create_tween().set_ignore_time_scale(true).set_parallel(true)
	bars.tween_property(_finish_top, "offset_top", 0.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	bars.tween_property(_finish_top, "offset_bottom", 58.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	bars.tween_property(_finish_bottom, "offset_top", -64.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	bars.tween_property(_finish_bottom, "offset_bottom", 0.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	var text_tw := create_tween().set_ignore_time_scale(true).set_parallel(true)
	text_tw.tween_property(_finish_title, "modulate:a", 1.0, 0.18).set_delay(0.08)
	text_tw.tween_property(_finish_title, "scale", Vector2.ONE, 0.32).set_delay(0.08) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	text_tw.tween_property(_finish_detail, "modulate:a", 1.0, 0.22).set_delay(0.18)

func dismiss_finish() -> void:
	if _finish_root == null or not _finish_root.visible:
		return
	var bars := create_tween().set_ignore_time_scale(true).set_parallel(true)
	bars.tween_property(_finish_top, "offset_top", -58.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	bars.tween_property(_finish_top, "offset_bottom", 0.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	bars.tween_property(_finish_bottom, "offset_top", 0.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	bars.tween_property(_finish_bottom, "offset_bottom", 64.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	bars.tween_property(_finish_title, "modulate:a", 0.0, 0.18)
	bars.tween_property(_finish_detail, "modulate:a", 0.0, 0.18)

func _format_finish_time(value: float) -> String:
	var minutes := int(value) / 60
	var seconds := fmod(value, 60.0)
	return "%d:%05.2f" % [minutes, seconds]
