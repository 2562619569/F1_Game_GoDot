extends Node3D
## 通用车辆展示间：CarStage 3D 展台 + 悬浮 UI（车名/描述/底部切换按钮）。
## 3D 棚拍视觉与展车装配在 car_stage.gd，本脚本只做 UI 接线与左右方向键循环切换
## —— 配表加车不需要改本场景。
## 对外契约：car_selected(car_id) / close_requested 信号 + show_car(car_id) / car_ids()。

signal car_selected(car_id: int)
signal close_requested

@export var initial_car_id := 0             # 0 = 取 Car 表最小 id
@export var drag_sensitivity := 0.01        # 透传给展台：每像素拖拽的旋转弧度

const BUTTON_SCENE := preload("res://game/ui/components/button_default.tscn")

@onready var stage: CarStage = $CarStage
@onready var car_name_label: Label = $UI/Root/CarName
@onready var car_desc_label: Label = $UI/Root/CarDesc
@onready var bottom_bar: HBoxContainer = $UI/Root/BottomBar
@onready var close_btn: Button = $UI/Root/CloseButton

var current_car_id := 0
var _group := ButtonGroup.new()

func _ready() -> void:
	stage.drag_sensitivity = drag_sensitivity
	stage.car_shown.connect(_on_car_shown)
	_setup_buttons()
	close_btn.pressed.connect(_on_close)
	var first := initial_car_id if initial_car_id > 0 else stage.car_ids()[0]
	stage.show_car(first)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var ids := stage.car_ids()
		var i := ids.find(stage.current_car_id)
		if i < 0:
			i = 0
		var step := 1 if event.is_action_pressed("ui_right") else -1
		stage.show_car(ids[wrapi(i + step, 0, ids.size())])

func _on_close() -> void:
	if close_requested.has_connections():
		close_requested.emit()
	else:
		get_tree().quit()  # 独立运行（未嵌入流程）时直接退出

func car_ids() -> Array[int]:
	return stage.car_ids()

func show_car(car_id: int) -> void:
	stage.show_car(car_id)

func _on_car_shown(car_id: int) -> void:
	current_car_id = car_id
	var cfg: Dictionary = Settings.car.data[car_id]
	car_name_label.text = "%s  ·  %s  ·  %d kg" % [cfg.name, String(cfg.drive).to_upper(), int(cfg.weight)]
	car_desc_label.text = String(cfg.desc)
	for b in bottom_bar.get_children():
		b.set_pressed_no_signal(int(b.get_meta(&"car_id")) == car_id)
	car_selected.emit(car_id)

func _setup_buttons() -> void:
	for child in bottom_bar.get_children():
		child.queue_free()
	for cid in stage.car_ids():
		var b: Button = BUTTON_SCENE.instantiate()
		b.text = String(Settings.car.data[cid].name)
		b.toggle_mode = true
		b.button_group = _group
		b.custom_minimum_size = Vector2(180, 52)
		b.add_theme_font_size_override("font_size", 18)
		b.set_meta(&"car_id", cid)
		b.pressed.connect(stage.show_car.bind(cid))
		bottom_bar.add_child(b)
