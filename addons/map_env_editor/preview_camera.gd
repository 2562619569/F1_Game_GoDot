@tool
extends Camera3D
## 预览窗口环绕相机：左键拖拽旋转，滚轮缩放；未交互时缓慢自转展示。

var target := Vector3.ZERO
var dist := 28.0
var yaw := 0.6
var pitch := 0.35
var _auto := true

func _ready() -> void:
	current = true
	_update()

func _process(delta: float) -> void:
	if _auto:
		yaw += delta * 0.15
		_update()

func _input(event: InputEvent) -> void:
	if not _mouse_inside():
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_auto = false
		yaw -= event.relative.x * 0.006
		pitch = clampf(pitch + event.relative.y * 0.004, 0.08, 1.4)
		_update()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist * 0.9, 4.0, 200.0)
			_update()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist * 1.1, 4.0, 200.0)
			_update()

func _mouse_inside() -> bool:
	var vp := get_viewport()
	var m := vp.get_mouse_position()
	return m.x >= 0.0 and m.y >= 0.0 and m.x < float(vp.size.x) and m.y < float(vp.size.y)

func _update() -> void:
	var pos := target + Vector3(
		dist * cos(pitch) * sin(yaw),
		dist * sin(pitch),
		dist * cos(pitch) * cos(yaw))
	look_at_from_position(pos, target, Vector3.UP)
