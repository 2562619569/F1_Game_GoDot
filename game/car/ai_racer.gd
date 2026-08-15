extends Node3D
## AI 对手：样条路径跟随（前瞻 + 曲率限速，见 TrackFollower），
## 强度由 race_manager 通过 CarBuilder torque_scale 调制。

var vehicle: Vehicle
var frozen := true
var _follower: TrackFollower

func setup(v: Vehicle, data: TrackData, lane: float) -> void:
	vehicle = v
	_follower = TrackFollower.new(data, lane)

func _physics_process(_delta: float) -> void:
	if vehicle == null or frozen:
		return
	_follower.drive(vehicle)
