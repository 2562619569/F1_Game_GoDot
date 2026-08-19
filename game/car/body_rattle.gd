class_name BodyRattle
extends Node3D
## 砂石路面车身微抖（纯表现层，与操控/物理零耦合）：
## 挂在 BodyAttitude 姿态层与车壳 BodyVisual 之间，逐轮读 surface_type
## （wheel 按碰撞体所在表面组实时刷新）+ 车速，压砂石时给车壳叠加毫米级
## 高频抖动——竖直颠为主、带轻微横向晃/滚转/俯仰，多频正弦叠加 + 每实例
## 随机相位（多台车不同步）。强度 = 压砂石车轮占比 × 车速渐变（2 m/s 起抖、
## 10 m/s 满幅），缓入缓出与相机持续源同调型（attack 12 / release 5）。
## 只写自身本地 transform：碰撞体与悬挂射线挂在刚体上、不在本链下，物理零影响。

@export_group("幅度（满强度）")
## 竖直颠幅度（米）——砂石质感的主读向。
@export var vertical_amplitude := 0.004
## 横向晃幅度（米）。
@export var lateral_amplitude := 0.0016
## 滚转/俯仰微幅（弧度）。
@export var roll_amplitude := 0.0035
@export var pitch_amplitude := 0.0022

@export_group("缓入缓出（1/s）")
@export var attack := 12.0
@export var release := 5.0

## 起抖/满幅车速与表面组名：与 smooth_chase_camera 砂石震屏源同源调型。
const SPEED_ONSET := 2.0
const SPEED_FULL := 10.0
const GRAVEL_SURFACE := "Gravel"
## 各轴两路叠加频率（Hz），取互不成整数比的组合避免周期性拍节。
const FREQ_X := Vector2(8.7, 12.1)
const FREQ_Y := Vector2(11.3, 14.9)
const FREQ_PITCH := Vector2(10.2, 15.1)
const FREQ_ROLL := Vector2(9.4, 13.3)
## 强度低于该值视为停抖，直接归位（残余跳变 <4µm，不可见）。
const IDLE_EPSILON := 0.001

var _vehicle: Vehicle
var _wheels: Array[Wheel] = []
var _intensity := 0.0
var _time := 0.0
var _active := false
var _phases: PackedFloat32Array = []   # 4 轴 × 2 路，_ready 随机初始化

func _ready() -> void:
	var ancestor: Node = get_parent()
	while ancestor != null and not ancestor is Vehicle:
		ancestor = ancestor.get_parent()
	_vehicle = ancestor as Vehicle
	if _vehicle == null:
		push_warning("BodyRattle: 祖先链上没有 Vehicle，微抖层停用")
		set_process(false)
		return
	_wheels = [_vehicle.front_left_wheel, _vehicle.front_right_wheel,
			_vehicle.rear_left_wheel, _vehicle.rear_right_wheel]
	for i in 8:
		_phases.append(randf() * TAU)

func _process(delta: float) -> void:
	var target := _target_intensity()
	if target <= 0.0 and _intensity < IDLE_EPSILON:
		if _active:
			position = Vector3.ZERO
			rotation = Vector3.ZERO
			_intensity = 0.0
			_active = false
		return
	_active = true
	_time += delta
	var rate := attack if target > _intensity else release
	_intensity = lerpf(_intensity, target, 1.0 - exp(-rate * delta))
	position.x = lateral_amplitude * _intensity * _wave(_time, FREQ_X, 0)
	position.y = vertical_amplitude * _intensity * _wave(_time, FREQ_Y, 2)
	position.z = 0.0
	rotation.x = pitch_amplitude * _intensity * _wave(_time, FREQ_PITCH, 4)
	rotation.z = roll_amplitude * _intensity * _wave(_time, FREQ_ROLL, 6)

## 目标强度（0..1，纯函数）：砂石车轮占比 × 车速渐变。半边轮骑路肩只有一半。
func _target_intensity() -> float:
	if _vehicle == null or _wheels.is_empty():
		return 0.0
	var on_gravel := 0
	for w in _wheels:
		if is_instance_valid(w) and String(w.surface_type) == GRAVEL_SURFACE:
			on_gravel += 1
	if on_gravel == 0:
		return 0.0
	var spd := _vehicle.linear_velocity.length()
	if spd <= SPEED_ONSET:
		return 0.0
	var speed_factor := clampf((spd - SPEED_ONSET) / (SPEED_FULL - SPEED_ONSET), 0.0, 1.0)
	return float(on_gravel) / float(_wheels.size()) * speed_factor

## 两路不同频正弦叠加（峰值 ≤1），phase_base 为该轴在 _phases 中的起始下标。
func _wave(t: float, freqs: Vector2, phase_base: int) -> float:
	return 0.62 * sin(t * TAU * freqs.x + _phases[phase_base]) \
			+ 0.38 * sin(t * TAU * freqs.y + _phases[phase_base + 1])
