extends "res://addons/pro_vehicle_camera/pro_vehicle_camera.gd"
## Pro Vehicle Camera 的旋转平滑封装（不改动上游源码）：
## 键盘 A/D 是阶跃输入，打满转向后车身横摆很快，而上游每个物理帧
## look_at 瞬时对准车身、过弯侧倾直接跟随转向量，视角会"啪"地跳变。
## 这里在上一帧朝向与上游新朝向之间做帧率无关的指数阻尼低通，
## 抹平瞬时跳变；位置牵引、动态 FOV、look_back 行为与上游完全一致。

## 朝向跟随刚度：越大越跟手，越小越"电影"（12 ≈ 80ms 时间常数）。
@export var rotation_damp := 12.0

var _prev_basis := Basis.IDENTITY

func _physics_process(delta: float) -> void:
	_prev_basis = global_transform.basis
	super(delta)
	var weight := 1.0 - exp(-rotation_damp * delta)
	global_transform.basis = _prev_basis.slerp(global_transform.basis, weight)
