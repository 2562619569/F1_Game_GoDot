@tool
extends VBoxContainer
## 地图环境 Dock：地图下拉 + 预设下拉 + 参数控件（太阳/天空/雾/环境光/辉光），
## 任何改动即时刷新 3D 预览窗口；保存时经 WeatherEnv.to_json 写回 map_<id>_env.json。

const PRESETS := ["sunny", "sandstorm", "storm", "snow"]
const PRESET_LABELS := ["Sunny 晴", "Sandstorm 沙暴", "Storm 暴雨", "Snow 冰雪"]

var _map_id := 0
var _current := {}          # 原始 env 覆盖键（未合成）
var _maps: Array = []       # [{id, label}]
var _syncing := false       # 控件回填时不触发写入

var _map_btn: OptionButton
var _preset_btn: OptionButton
var _status: Label
var _value_labels := {}     # key -> Label（滑杆数值显示）
var _sliders := {}          # key -> HSlider
var _pickers := {}          # key -> ColorPickerButton
var _glow_check: CheckBox

var _preview_window: Window
var _preview: Node3D

func _ready() -> void:
	custom_minimum_size = Vector2(320, 0)
	_build_ui()
	_scan_maps()
	_select_map(0)

# ---------------- UI 搭建 ----------------

func _build_ui() -> void:
	var title := Label.new()
	title.text = "地图环境"
	title.add_theme_font_size_override("font_size", 16)
	add_child(title)

	var map_row := HBoxContainer.new()
	add_child(map_row)
	var map_label := Label.new()
	map_label.text = "地图"
	map_label.custom_minimum_size = Vector2(72, 0)
	map_row.add_child(map_label)
	_map_btn = OptionButton.new()
	_map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_btn.item_selected.connect(_select_map)
	map_row.add_child(_map_btn)

	var preset_row := HBoxContainer.new()
	add_child(preset_row)
	var preset_label := Label.new()
	preset_label.text = "预设"
	preset_label.custom_minimum_size = Vector2(72, 0)
	preset_row.add_child(preset_label)
	_preset_btn = OptionButton.new()
	_preset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in PRESET_LABELS.size():
		_preset_btn.add_item(PRESET_LABELS[i], i)
	_preset_btn.item_selected.connect(_select_preset)
	preset_row.add_child(_preset_btn)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	box.add_child(_section("太阳"))
	box.add_child(_color_row("颜色", "sun"))
	box.add_child(_slider_row("强度", "energy", 0.1, 3.0, 0.05))
	box.add_child(_slider_row("俯仰°", "pitch", -80.0, -10.0, 1.0))
	box.add_child(_slider_row("方位°", "yaw", -180.0, 180.0, 1.0))

	box.add_child(_section("天空"))
	box.add_child(_color_row("顶部色", "sky_top"))
	box.add_child(_color_row("地平线色", "sky_horizon"))

	box.add_child(_section("雾"))
	box.add_child(_color_row("颜色", "fog"))
	box.add_child(_slider_row("密度", "fog_density", 0.0, 0.03, 0.0005))

	box.add_child(_section("环境光"))
	box.add_child(_slider_row("强度", "ambient_energy", 0.0, 2.0, 0.05))

	box.add_child(_section("辉光"))
	var glow_row := HBoxContainer.new()
	box.add_child(glow_row)
	var glow_label := Label.new()
	glow_label.text = "启用"
	glow_label.custom_minimum_size = Vector2(96, 0)
	glow_row.add_child(glow_label)
	_glow_check = CheckBox.new()
	_glow_check.toggled.connect(func(v: bool): _set_key("glow", v))
	glow_row.add_child(_glow_check)
	box.add_child(_slider_row("强度", "glow_intensity", 0.0, 1.0, 0.01))

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	add_child(btns)
	var preview_btn := Button.new()
	preview_btn.text = "3D 预览"
	preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_btn.pressed.connect(_toggle_preview)
	btns.add_child(preview_btn)
	var save_btn := Button.new()
	save_btn.text = "保存 env"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_save)
	btns.add_child(save_btn)

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
	return l

func _slider_row(label_text: String, key: String, lo: float, hi: float, step: float) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(96, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = (lo + hi) * 0.5
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(90, 0)
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size = Vector2(52, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	s.value_changed.connect(func(val: float):
		if not _syncing:
			_set_key(key, val)
		v.text = "%.3f" % val if step < 0.1 else "%.0f" % val)
	_sliders[key] = s
	_value_labels[key] = v
	return row

func _color_row(label_text: String, key: String) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(96, 0)
	row.add_child(l)
	var p := ColorPickerButton.new()
	p.custom_minimum_size = Vector2(60, 24)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.color_changed.connect(func(c: Color):
		if not _syncing:
			_set_key(key, c))
	_pickers[key] = p
	return row

# ---------------- 地图列表 / 数据 ----------------

## 扫描 data 目录：地图几何(map_<id>.json)与 env(map_<id>_env.json)任一存在即列出
func _scan_maps() -> void:
	_maps = []
	var ids := {}
	var names := {}
	var dir := DirAccess.open("res://game/race/tracks/data")
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if f.begins_with("map_") and f.ends_with(".json"):
				var id_str := f.get_file().substr(4).split("_")[0]
				var is_env := f.ends_with("_env.json")
				if not is_env and id_str.is_valid_int():
					ids[int(id_str)] = true
					var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://game/race/tracks/data/" + f))
					if parsed is Dictionary and parsed.get("meta", {}).has("name"):
						names[int(id_str)] = String(parsed["meta"]["name"])
			f = dir.get_next()
		dir.list_dir_end()
	# env 文件也纳入（有 env 无几何的地图仍可调环境）
	for ef in DirAccess.get_files_at("res://game/race/tracks/data"):
		if ef.begins_with("map_") and ef.ends_with("_env.json"):
			var id_str := ef.substr(4).split("_")[0]
			if id_str.is_valid_int():
				ids[int(id_str)] = true
	for id_ in ids:
		_maps.append({"id": id_, "label": "map_%d%s" % [id_, "  " + String(names.get(id_, "")) if names.has(id_) else ""]})
	_maps.sort_custom(func(a, b): return a.id < b.id)
	_map_btn.clear()
	for m in _maps:
		_map_btn.add_item(m.label)

func _select_map(idx: int) -> void:
	if idx < 0 or idx >= _maps.size():
		return
	_map_id = int(_maps[idx].id)
	var raw := {}
	var path := WeatherEnv.env_path(_map_id)
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			raw = parsed
	_current = raw
	_refresh_controls()
	_refresh_preview()
	_status.text = "已载入 map_%d%s" % [_map_id, "（无 env 文件，用预设默认）" if raw.is_empty() else ""]

func _select_preset(idx: int) -> void:
	if _syncing or _map_id == 0:
		return
	_current = {"preset": PRESETS[idx]}
	_refresh_controls()
	_refresh_preview()

## 控件 ← 当前合成配置（_syncing 防回填触发写入）
func _refresh_controls() -> void:
	_syncing = true
	var c := WeatherEnv.resolve(_current)
	_preset_btn.selected = maxi(0, PRESETS.find(String(c.preset)))
	for key in _sliders:
		_sliders[key].set_value_no_signal(float(c[key]))
		var step: float = _sliders[key].step
		_value_labels[key].text = "%.3f" % _sliders[key].value if step < 0.1 else "%.0f" % _sliders[key].value
	for key in _pickers:
		_pickers[key].color = c[key]
	_glow_check.set_pressed_no_signal(bool(c.glow))
	_syncing = false

func _set_key(key: String, value) -> void:
	_current[key] = value
	_refresh_preview()

# ---------------- 预览 ----------------

func _toggle_preview() -> void:
	if _preview_window != null and is_instance_valid(_preview_window):
		_preview_window.queue_free()
		_preview_window = null
		_preview = null
		return
	if _map_id == 0:
		return
	_preview_window = Window.new()
	_preview_window.title = "环境预览 · map_%d" % _map_id
	_preview_window.size = Vector2i(1024, 640)
	_preview_window.wrap_controls = true
	var holder := SubViewportContainer.new()
	holder.stretch = true
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_window.add_child(holder)
	var vp := SubViewport.new()
	holder.add_child(vp)
	_preview = load("res://addons/map_env_editor/env_preview.gd").new()
	vp.add_child(_preview)
	add_child(_preview_window)
	_preview_window.popup_centered()
	_preview.setup(_map_id, WeatherEnv.resolve(_current))

func _refresh_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.apply_env(WeatherEnv.resolve(_current))

# ---------------- 保存 ----------------

func _save() -> void:
	if _map_id == 0:
		return
	var path := WeatherEnv.env_path(_map_id)
	var json := JSON.stringify(WeatherEnv.to_json(WeatherEnv.resolve(_current)), "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status.text = "保存失败：%s" % path
		return
	f.store_string(json + "\n")
	f.close()
	_status.text = "已保存 %s" % path
	print("[map_env_editor] saved %s" % path)
