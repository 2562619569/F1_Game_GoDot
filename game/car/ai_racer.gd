extends Node3D
## AI 对手：全程油门 + 横向 PD 控制保持在指定车道。
## 强度由 race_manager 通过 CarBuilder torque_scale 调制。

var vehicle: Vehicle
var frozen := true
var lane_x := 0.0

func setup(v: Vehicle, lane: float) -> void:
	vehicle = v
	lane_x = lane

func _physics_process(_delta: float) -> void:
	if vehicle == null or frozen:
		return
	vehicle.throttle_input = 1.0
	vehicle.brake_input = 0.0
	vehicle.handbrake_input = 0.0
	var err: float = vehicle.global_position.x - lane_x
	vehicle.steering_input = clampf(err * 0.045 + vehicle.linear_velocity.x * 0.10, -1.0, 1.0)
