extends CanvasLayer
class_name SpeedMotionBlur
## Speed-driven scenery blur for racing cameras.
## The effect is radial and screen-space: the car and HUD stay readable while
## peripheral scenery stretches away from the camera's focus point.

const BLUR_SHADER := preload("res://game/shaders/speed_motion_blur.gdshader")

@export var speed_start := 32.0
@export var speed_full := 72.0
@export var max_strength := 0.075
@export var response := 7.0

var vehicle: Node3D
var camera: Camera3D
var _strength := 0.0
var _rect: ColorRect
var _material: ShaderMaterial

func _ready() -> void:
	layer = 1
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect = ColorRect.new()
	_rect.name = "SpeedMotionBlurRect"
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_material = ShaderMaterial.new()
	_material.shader = BLUR_SHADER
	_rect.material = _material
	add_child(_rect)
	_material.set_shader_parameter("center", Vector2(0.5, 0.5))
	_material.set_shader_parameter("strength", 0.0)

func setup(target_vehicle: Node3D, target_camera: Camera3D) -> void:
	vehicle = target_vehicle
	camera = target_camera

func _process(delta: float) -> void:
	if not is_instance_valid(vehicle) or not is_instance_valid(camera) \
			or not is_instance_valid(_material):
		_set_strength(0.0)
		return
	var speed := _vehicle_speed()
	var target := smoothstep(speed_start, speed_full, speed) * max_strength
	_strength = lerpf(_strength, target, 1.0 - exp(-response * delta))
	var viewport_size := get_viewport().get_visible_rect().size
	var focus := Vector2(0.5, 0.5)
	if viewport_size.x > 1.0 and viewport_size.y > 1.0:
		var projected := camera.unproject_position(vehicle.global_position + Vector3.UP * 0.45)
		focus = Vector2(projected.x / viewport_size.x, projected.y / viewport_size.y)
	_material.set_shader_parameter("center", focus)
	_material.set_shader_parameter("strength", _strength)

func _set_strength(value: float) -> void:
	_strength = value
	if is_instance_valid(_material):
		_material.set_shader_parameter("strength", value)

func _vehicle_speed() -> float:
	if "linear_velocity" in vehicle:
		return (vehicle.linear_velocity as Vector3).length()
	if "speed" in vehicle:
		return float(vehicle.speed)
	if "current_speed" in vehicle:
		return float(vehicle.current_speed)
	return 0.0
