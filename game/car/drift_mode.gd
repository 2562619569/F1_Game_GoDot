class_name DriftMode
extends Node3D
## 玩家车漂移模式（装配型组件，挂在玩家 Vehicle 下，仅玩家挂载）。
## 手刹原生语义是「后轴大力刹车 + 关 ABS」：锁轮急减速，甩尾只是组合滑移的
## 副产品，高抓地胎（μ≈3）+ 滑移辅助 + 横摆稳定会把侧滑瞬间吃掉，转不成漂移。
## 本组件把空格重定义为「按住 = 漂移状态」：进入时温和化手刹力（起漂咬一下
## 而非急刹停死）、只压低后轴侧向抓地、放宽大角度打方向限制、横摆稳定退到
## 接近自旋才兜底，并在按下瞬间按当前转向补一记甩尾角冲量（NFS 式即时起漂）；
## 松开空格后不立即退出：根据当前侧滑姿态逐步恢复抓地，车身收稳后再退出。
##
## 触发读 vehicle.handbrake_input（PlayerCar 每帧在写，输入链零改动）：
## 发车 frozen 锁车虽然 handbrake=1 但车速≈0，速度门槛天然挡住，不会误入。
##
## 与 CollisionKick 失稳窗口**零参数交集**（刻意设计）：本组件只动
## max_handbrake_force / steering_slip_assist / stability_yaw_engage_angle /
## 后轮 lateral_grip_scale，绝不碰 countersteer_assist、stability_yaw_strength、
## coefficient_of_friction（后者独占）。两边同时生效（漂移中挨重撞）互不覆盖
## 对方的保存值，恢复时序无论怎样交错都不会互相写错。
## 参数由 race_builder 从 Game 表 drift_* 注入；缺省值与表内默认一致，自检可直接注入。

signal drift_changed(is_active: bool)

const DEFAULT_SPEED_MIN := 8.0     # 进入/维持漂移的最低车速（m/s）
const DEFAULT_BRAKE_SCALE := 0.35  # 漂移中手刹制动力缩放（1=原锁轮急刹）
const DEFAULT_REAR_GRIP := 0.62    # 漂移中后轮侧向抓地缩放（前轮不动保指向）
const DEFAULT_SLIP_ASSIST := 0.55  # 漂移中转向滑移辅助阈值（rad，放宽大角度打方向）
const DEFAULT_YAW_ENGAGE := 0.22   # 漂移中横摆稳定介入角（dot 域 ≈40°：限位最大漂移角，只兜接近自旋的旋转）
const DEFAULT_YAW_KICK := 0.25     # 起漂甩尾角速度增量（rad/s，按转向输入比例）
const ENTER_BRAKE := 0.5           # handbrake_input 高于该值视为按住
const EXIT_SPEED_FACTOR := 0.75    # 退出车速滞后（×speed_min），防边界抖动
const FORWARD_GATE := -0.5         # local_velocity.z 低于该值才算前进（GEVP 前进为 -Z）
const KICK_MIN_STEER := 0.1        # 起漂冲量要求的最小转向输入
const RELEASE_SETTLE_SLIP := 0.12  # 松手后允许退出的最大侧滑角（rad，约 7°）
const RELEASE_SETTLE_YAW := 0.45   # 松手后允许退出的最大横摆角速度（rad/s）
const RELEASE_BLEND_SLIP := 0.45   # 侧滑达到该角度时仍保持完整漂移参数（rad，约 26°）
const RELEASE_BLEND_YAW := 1.40    # 横摆达到该角速度时仍保持完整漂移参数（rad/s）

var speed_min := DEFAULT_SPEED_MIN
var brake_scale := DEFAULT_BRAKE_SCALE
var rear_grip := DEFAULT_REAR_GRIP
var slip_assist := DEFAULT_SLIP_ASSIST
var yaw_engage := DEFAULT_YAW_ENGAGE
var yaw_kick := DEFAULT_YAW_KICK

var _v: Vehicle
var active := false                # 自检观测用；状态切换只走组件内部
var recovering := false            # 松手后的姿态恢复阶段；仍保持漂移状态
var _saved_handbrake_force := 0.0
var _saved_slip_assist := 0.0
var _saved_yaw_engage := 0.0
var _saved_rear_scales: Array[float] = []

func setup(v: Vehicle, cfg := {}) -> void:
	_v = v
	speed_min = float(cfg.get("speed_min", DEFAULT_SPEED_MIN))
	brake_scale = float(cfg.get("brake_scale", DEFAULT_BRAKE_SCALE))
	rear_grip = float(cfg.get("rear_grip", DEFAULT_REAR_GRIP))
	slip_assist = float(cfg.get("slip_assist", DEFAULT_SLIP_ASSIST))
	yaw_engage = float(cfg.get("yaw_engage", DEFAULT_YAW_ENGAGE))
	yaw_kick = float(cfg.get("yaw_kick", DEFAULT_YAW_KICK))

func _physics_process(_delta: float) -> void:
	if _v == null:
		return
	var held := _v.handbrake_input > ENTER_BRAKE
	var forward := _v.local_velocity.z < FORWARD_GATE
	if active:
		# 掉速/失去前进方向是硬退出；松手则等待车身姿态收稳，避免瞬间拉正。
		if not forward or _v.speed < speed_min * EXIT_SPEED_FACTOR:
			_exit()
		elif not held:
			recovering = true
			var slip := _slip_angle()
			_apply_recovery(slip)
			if slip <= RELEASE_SETTLE_SLIP and absf(_v.angular_velocity.y) <= RELEASE_SETTLE_YAW:
				_exit()
		else:
			recovering = false
			_apply()  # 每帧幂等刷新，防外部组件中途写回漂移参数
	elif held and forward and _v.speed > speed_min:
		_enter()

func _enter() -> void:
	active = true
	_saved_handbrake_force = _v.max_handbrake_force
	_saved_slip_assist = _v.steering_slip_assist
	_saved_yaw_engage = _v.stability_yaw_engage_angle
	_saved_rear_scales.clear()
	for wheel in _v.rear_axle.wheels:
		_saved_rear_scales.append(wheel.lateral_grip_scale)
	_apply()
	# 起漂甩尾冲量：按下瞬间朝当前转向方向补角速度（乘转向输入取方向与比例），
	# 转动惯量按车体 y 主轴缩放，让 yaw_kick 语义稳定为「角速度增量 rad/s」
	if absf(_v.steering_input) >= KICK_MIN_STEER:
		_v.sleeping = false
		_v.apply_torque_impulse(Vector3(0.0, yaw_kick * _v.steering_input * _v.inertia.y, 0.0))
	drift_changed.emit(true)

func _apply() -> void:
	_apply_recovery(0.0)

func _apply_recovery(slip: float) -> void:
	# 侧滑越大，越保留漂移参数；姿态接近车头方向时再平滑恢复原值。
	var restore := 0.0
	if recovering:
		var slip_restore := 1.0 - clampf((slip - RELEASE_SETTLE_SLIP) / (RELEASE_BLEND_SLIP - RELEASE_SETTLE_SLIP), 0.0, 1.0)
		var yaw_restore := 1.0 - clampf((absf(_v.angular_velocity.y) - RELEASE_SETTLE_YAW) / (RELEASE_BLEND_YAW - RELEASE_SETTLE_YAW), 0.0, 1.0)
		restore = minf(slip_restore, yaw_restore)
	_v.max_handbrake_force = lerpf(_saved_handbrake_force * brake_scale, _saved_handbrake_force, restore)
	_v.steering_slip_assist = lerpf(slip_assist, _saved_slip_assist, restore)
	_v.stability_yaw_engage_angle = lerpf(yaw_engage, _saved_yaw_engage, restore)
	for i in _v.rear_axle.wheels.size():
		_v.rear_axle.wheels[i].lateral_grip_scale = lerpf(rear_grip, _saved_rear_scales[i], restore)

func _exit() -> void:
	active = false
	recovering = false
	_v.max_handbrake_force = _saved_handbrake_force
	_v.steering_slip_assist = _saved_slip_assist
	_v.stability_yaw_engage_angle = _saved_yaw_engage
	for i in _v.rear_axle.wheels.size():
		_v.rear_axle.wheels[i].lateral_grip_scale = _saved_rear_scales[i]
	drift_changed.emit(false)

func _slip_angle() -> float:
	var planar := Vector2(_v.local_velocity.x, _v.local_velocity.z)
	if planar.length_squared() < 0.01:
		return 0.0
	return absf(atan2(planar.x, -planar.y))
