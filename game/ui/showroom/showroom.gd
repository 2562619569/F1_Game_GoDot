extends Node3D
## 通用车辆展示间：中央展台展示当前车辆，按住左键拖拽可旋转展台，
## 底部一排按钮列出 Car 表全部车辆，点击即切换预览（左右方向键亦可循环切换）。
## 场景结构（灯光/地面/展台/相机/顶栏/底栏）在 tscn 内搭建，脚本只负责补齐资源、
## 生成按钮与装配车辆 —— 配表加车不需要改本场景。
## 对外契约：car_selected(car_id) / close_requested 信号 + show_car(car_id) / car_ids()。

signal car_selected(car_id: int)
signal close_requested

@export var drag_sensitivity := 0.01        # 每像素拖拽的旋转弧度
@export var initial_car_id := 0             # 0 = 取 Car 表最小 id

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const BUTTON_SCENE := preload("res://game/ui/components/button_default.tscn")

@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var ground: MeshInstance3D = $Ground
@onready var turntable: Node3D = $Turntable
@onready var camera: Camera3D = $Camera3D
@onready var car_name_label: Label = $UI/Root/CarName
@onready var car_desc_label: Label = $UI/Root/CarDesc
@onready var bottom_bar: HBoxContainer = $UI/Root/BottomBar
@onready var close_btn: Button = $UI/Root/CloseButton

var current_car_id := 0
var _group := ButtonGroup.new()
var _dragging := false

func _ready() -> void:
	_setup_world()
	_setup_buttons()
	close_btn.pressed.connect(_on_close)
	var first := initial_car_id if initial_car_id > 0 else car_ids()[0]
	show_car(first)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		turntable.rotate_y(-event.relative.x * drag_sensitivity)
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var ids := car_ids()
		var i := ids.find(current_car_id)
		if i < 0:
			i = 0
		var step := 1 if event.is_action_pressed("ui_right") else -1
		show_car(ids[wrapi(i + step, 0, ids.size())])

func _on_close() -> void:
	if close_requested.has_connections():
		close_requested.emit()
	else:
		get_tree().quit()  # 独立运行（未嵌入流程）时直接退出

## Car 表全部 id 升序（601~603，配表扩车自动生效）
func car_ids() -> Array[int]:
	var ids: Array[int] = []
	for cid in Settings.car.data.keys():
		ids.append(int(cid))
	ids.sort()
	return ids

## 切换展台车辆：重新装配美术与物理参数（冻结展示，不参与模拟）
func show_car(car_id: int) -> void:
	if not Settings.car.data.has(car_id):
		push_warning("Showroom: Car 表无 %d，忽略切换" % car_id)
		return
	current_car_id = car_id
	for child in turntable.get_children():
		child.queue_free()
	var v: Vehicle = CAR_SCENE.instantiate()
	v.position = Vector3(0, 0.5, 0)
	CarBuilder.apply(v, Settings.car.data[car_id], Match.get_stats(), "sunny", 1.0)
	CarMeshBuilder.attach_visual(v, car_id)
	turntable.add_child(v)
	v.freeze = true
	var cfg: Dictionary = Settings.car.data[car_id]
	car_name_label.text = "%s  ·  %s  ·  %d kg" % [cfg.name, String(cfg.drive).to_upper(), int(cfg.weight)]
	car_desc_label.text = String(cfg.desc)
	for b in bottom_bar.get_children():
		b.set_pressed_no_signal(int(b.get_meta(&"car_id")) == car_id)
	car_selected.emit(car_id)

# ---------------- 场景资源补齐（tscn 持结构，代码持资源） ----------------

func _setup_world() -> void:
	if world_env.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.15, 0.17, 0.2)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.5, 0.5, 0.55)
		env.ambient_light_energy = 1.0
		world_env.environment = env
	if ground.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(24, 24)
		ground.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.32, 0.34, 0.38)
		ground.material_override = mat
	camera.look_at(Vector3(0, 0.5, 0))

func _setup_buttons() -> void:
	for child in bottom_bar.get_children():
		child.queue_free()
	for cid in car_ids():
		var b: Button = BUTTON_SCENE.instantiate()
		b.text = String(Settings.car.data[cid].name)
		b.toggle_mode = true
		b.button_group = _group
		b.custom_minimum_size = Vector2(180, 52)
		b.add_theme_font_size_override("font_size", 18)
		b.set_meta(&"car_id", cid)
		b.pressed.connect(show_car.bind(cid))
		bottom_bar.add_child(b)
