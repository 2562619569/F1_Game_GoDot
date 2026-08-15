class_name BodyAttitude
extends Node3D
## 车身姿态视觉层：把"表现"与"操控"解耦的纯视觉增强。
## 挂在 Vehicle 刚体与车壳 BodyVisual 之间（本节点为刚体直接子节点，车壳挂在本节点下），
## 依据四轮悬挂压缩量（真实重量转移）计算俯仰/侧倾目标角，用帧率无关的
## 精确弹簧阻尼器（SpringDamper）平滑逼近，叠加在刚体物理旋转之上。
## 物理参数（刚度/防倾杆/质心）不受影响，操控手感零改动。
##
## 目标角计算（压缩量均为对静态载荷压缩量的超出部分，静载与腾空时目标为 0）：
##   roll  = roll_gain  * (左侧平均超出压缩 − 右侧平均超出压缩)
##   pitch = pitch_gain * (前轴平均超出压缩 − 后轴平均超出压缩)
## 左侧压缩多 → 车体向左倾（过弯向外侧倾，符合真实重量转移方向）；
## 前轴压缩多 → 点头（制动），后轴压缩多 → 抬头（加速）。

@export_group("增益（度/米压缩差）")
## 满压缩差（约 0.1m）对应的侧倾角。拟真参考：22 ≈ 满压缩 2° 出头
@export var roll_gain := 22.0
## 满压缩差对应的俯仰角。拟真参考：18 ≈ 制动满压缩 ~1.5°
@export var pitch_gain := 18.0

@export_group("弹簧（响应频率 Hz / 阻尼比）")
## 阻尼比 < 1 会带一点弹性回摆（车身的"悬垂感"），1.0 为最快无振荡
@export var roll_frequency := 2.2
@export var roll_damping_ratio := 0.9
@export var pitch_frequency := 2.0
@export var pitch_damping_ratio := 0.9

const _SpringDamper := preload("res://game/car/spring_damper.gd")

var _vehicle: Vehicle
var _wheels: Array[Wheel] = []
var _static_compressions: Array[float] = []

var _roll := 0.0
var _roll_vel := 0.0
var _pitch := 0.0
var _pitch_vel := 0.0

func _ready() -> void:
	_vehicle = get_parent() as Vehicle
	if not _vehicle:
		push_warning("BodyAttitude: 父节点不是 Vehicle，姿态层停用")
		set_process(false)
		return
	# 顺序：前左、前右、后左、后右（与下方静态压缩一一对应）
	_wheels = [_vehicle.front_left_wheel, _vehicle.front_right_wheel,
			_vehicle.rear_left_wheel, _vehicle.rear_right_wheel]
	_static_compressions = [
			_vehicle.front_spring_length * _vehicle.front_resting_ratio,
			_vehicle.front_spring_length * _vehicle.front_resting_ratio,
			_vehicle.rear_spring_length * _vehicle.rear_resting_ratio,
			_vehicle.rear_spring_length * _vehicle.rear_resting_ratio]

func _process(delta: float) -> void:
	# 压缩量超出静载部分；腾空/回弹时钳到 0，避免静态偏差和空中姿态
	var extras: Array[float] = []
	for i in _wheels.size():
		var w := _wheels[i]
		if not is_instance_valid(w):
			return
		var compression := w.spring_length - w.spring_current_length
		extras.append(maxf(compression - _static_compressions[i], 0.0))

	var front_avg := (extras[0] + extras[1]) * 0.5
	var rear_avg := (extras[2] + extras[3]) * 0.5
	var left_avg := (extras[0] + extras[2]) * 0.5
	var right_avg := (extras[1] + extras[3]) * 0.5

	var roll_target := deg_to_rad(roll_gain) * (left_avg - right_avg)
	var pitch_target := deg_to_rad(pitch_gain) * (front_avg - rear_avg)

	var roll_s := _SpringDamper.spring(_roll, _roll_vel, roll_target,
			roll_frequency, roll_damping_ratio, delta)
	_roll = roll_s.x
	_roll_vel = roll_s.y
	var pitch_s := _SpringDamper.spring(_pitch, _pitch_vel, pitch_target,
			pitch_frequency, pitch_damping_ratio, delta)
	_pitch = pitch_s.x
	_pitch_vel = pitch_s.y

	rotation.z = _roll
	rotation.x = _pitch
