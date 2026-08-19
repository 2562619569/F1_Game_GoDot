class_name TrackFollower
extends RefCounted
## 样条路径跟随控制器:AI 对手与冒烟测试自动驾驶共用。
## 前瞻目标点 + 转向角 P / 侧滑速度 D + 前方曲率限速。
## 无 TrackData(旧版直线图)时退化为原直线车道保持。

const TURN_GAIN := 1.5       # 转向角比例增益
const SLIDE_DAMP := 0.10     # 侧滑速度阻尼
const LOOK_TIME := 0.55      # 前瞻时间(秒)
const LOOK_MIN := 8.0
const LOOK_MAX := 35.0

var data: TrackData = null
var lane := 0.0              # 相对中心线横向偏移(目标车道)
var speed_scale := 1.0       # 目标速度缩放(1=全力;NPC 交通车 <1 慢速巡航)
var _idx := 0                # 最近样条索引缓存

func _init(d: TrackData = null, lane_off := 0.0, spd_scale := 1.0) -> void:
	data = d
	lane = lane_off
	speed_scale = spd_scale

## 每物理帧把控制量写入车辆
func drive(v: Vehicle) -> void:
	if data == null:
		v.throttle_input = 1.0
		v.brake_input = 0.0
		v.handbrake_input = 0.0
		v.steering_input = clampf(
			v.global_position.x * 0.045 + v.linear_velocity.x * 0.10, -1.0, 1.0)
		return

	var pos := v.global_position
	_idx = data.nearest_index(pos, _idx)
	var s_arr: PackedFloat32Array = data.main["s_arr"]
	var s_here: float = s_arr[_idx]
	var speed := maxf(v.speed, 1.0)
	var look := clampf(speed * LOOK_TIME, LOOK_MIN, LOOK_MAX)

	# 前瞻目标点(带车道偏移)
	var target := data.point_at(s_here + look) + data.normal_at(s_here + look) * lane

	# 转向:车头 → 目标角(P)+ 侧滑阻尼(D)
	var fwd := -v.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3(0, 0, -1)
	var to := target - pos
	to.y = 0.0
	to = to.normalized() if to.length() > 1e-4 else fwd
	var ang: float = fwd.signed_angle_to(to, Vector3.UP)
	var side := data.normal_at(s_here)
	var side_vel: float = v.linear_velocity.dot(side)
	v.steering_input = clampf(ang * TURN_GAIN - side_vel * SLIDE_DAMP, -1.0, 1.0)

	# 曲率限速:前方窗口最小半径 → 目标速度闭环(再乘 speed_scale 得本车目标巡航速度)
	var vmax: float = data.corner_speed(s_here + 5.0, look + 15.0) * speed_scale
	if speed > vmax + 2.0:
		v.throttle_input = 0.0
		v.brake_input = clampf((speed - vmax) * 0.15, 0.0, 1.0)
	else:
		v.throttle_input = 1.0
		v.brake_input = 0.0
	v.handbrake_input = 0.0
