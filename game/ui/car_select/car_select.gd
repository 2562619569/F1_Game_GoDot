extends Node3D
## 开局选车：CarStage 3D 展台居中展示 + 悬浮 UI。
## 车辆棚拍视觉与拖拽旋转在 car_stage.gd；本脚本从 Car 表实时填充规格面板文字、
## 生成底部底盘切换按钮（配表改车不需要改场景）。
## 对外契约：car_chosen(car_id) 信号 + card_buttons（底盘切换按钮，按 Car 表 id 升序）+ confirm_btn。

signal car_chosen(car_id: int)

const BAR_ROWS := [
	{"cap": "TOP SPEED", "key": "top_speed", "max": 340.0},
	{"cap": "ACCEL", "key": "accel", "max": 10.0},
	{"cap": "HANDLING", "key": "handling", "max": 10.0},
	{"cap": "OFFROAD", "key": "grip_offroad", "max": 10.0},
]

const BUTTON_SCENE := preload("res://game/ui/components/button_default.tscn")

@onready var stage: CarStage = $CarStage
@onready var car_name_label: Label = %CarName
@onready var car_sub_label: Label = %CarSub
@onready var bars: VBoxContainer = %Bars
@onready var slots_label: Label = %SlotsLabel
@onready var desc_label: Label = %DescLabel
@onready var bottom_bar: HBoxContainer = %BottomBar
@onready var confirm_btn: Button = %ConfirmButton

var card_buttons: Array = []
var _group := ButtonGroup.new()

func _ready() -> void:
	stage.car_shown.connect(_on_car_shown)
	_setup_switch_buttons()
	confirm_btn.pressed.connect(_confirm)
	stage.show_car(stage.car_ids()[0])

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var ids := stage.car_ids()
		var i := ids.find(stage.current_car_id)
		if i < 0:
			i = 0
		var step := 1 if event.is_action_pressed("ui_right") else -1
		stage.show_car(ids[wrapi(i + step, 0, ids.size())])

func _confirm() -> void:
	car_chosen.emit(stage.current_car_id)

func _on_car_shown(car_id: int) -> void:
	var c: Dictionary = Settings.car.data[car_id]
	car_name_label.text = String(c.name)
	car_sub_label.text = "%s  ·  %d kg" % [String(c.drive).to_upper(), int(c.weight)]
	var rows := bars.get_children()
	for i in mini(rows.size(), BAR_ROWS.size()):
		var row: Array = rows[i].get_children()
		(row[0] as Label).text = String(BAR_ROWS[i].cap)
		var n := clampi(roundi(float(c[BAR_ROWS[i].key]) / float(BAR_ROWS[i].max) * 10.0), 0, 10)
		(row[1] as Label).text = "█".repeat(n) + "·".repeat(10 - n)
	slots_label.text = "SLOTS: %d PERF + %d FUNC" % [int(c.perf_slots), int(c.func_slots)]
	desc_label.text = String(c.desc)
	for b in card_buttons:
		b.set_pressed_no_signal(int(b.get_meta(&"car_id")) == car_id)

func _setup_switch_buttons() -> void:
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
		card_buttons.append(b)
