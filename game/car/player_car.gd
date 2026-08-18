class_name PlayerCar
extends Node3D
## 玩家赛车根节点：键盘输入（复用 GEVP 输入映射）+ 战术技能。
## 战术件配表驱动：effect = nitro_push / stealth / slow_spin，
## 弹药与冷却按 Part 表 cooldown / ammo / duration 每回合重置。

const KEY_LABELS := ["Q", "E"]

# 键盘输入整形：二值按键 ramp 成模拟量再喂给物理（Assetto Corsa 键盘模型：
# 油门建立 ~0.25s、释放更快；转向已由 GEVP steering_speed 平滑，不在此叠加）
const THROTTLE_RISE := 4.0
const THROTTLE_FALL := 10.0
const BRAKE_RISE := 6.0
const BRAKE_FALL := 10.0
# 倒挡闸门：GEVP 在 brake_input > 0.75 且车速 < 1 m/s 时自动挂倒挡，
# 键盘刹车恒为满值，弯中急刹掉速后会被误切倒挡；停稳后持续按住才放行
const REVERSE_HOLD_TIME := 0.3
const REVERSE_BRAKE_GATE := 0.7

var vehicle: Vehicle
var frozen := true
var race: RaceManager = null  # 注入用于火箭锁定；调试场景可为 null
var _throttle := 0.0
var _brake := 0.0
var _brake_hold := 0.0

var tactical: Array = []  # [{pid, cfg, ammo, cd_left}]
var stealth_left := 0.0
var nitro_left := 0.0
var nitro_power := 0.0
var _was_stealth := false
var _auto_follower: TrackFollower = null  # 冒烟测试自动驾驶

func setup(v: Vehicle, track_data: TrackData, race: RaceManager = null) -> void:
	vehicle = v
	self.race = race
	_auto_follower = TrackFollower.new(track_data, 0.0)
	tactical.clear()
	for cat in Match.FUNC_CATEGORIES:
		if Match.equipped.has(cat):
			var pid: int = Match.equipped[cat]
			tactical.append({"pid": pid, "cfg": Match.part_cfg(pid), "ammo": int(Match.part_cfg(pid).ammo), "cd_left": 0.0})

func _physics_process(delta: float) -> void:
	if vehicle == null:
		return
	if frozen:
		_throttle = 0.0
		_brake = 0.0
		_brake_hold = 0.0
		vehicle.throttle_input = 0.0
		vehicle.brake_input = 0.5
		vehicle.steering_input = 0.0
		vehicle.handbrake_input = 1.0
		return

	if Match.auto_test:  # 冒烟测试：自动驾驶沿赛道中心线
		_throttle = 0.0
		_brake = 0.0
		_brake_hold = 0.0
		_auto_follower.drive(vehicle)
	else:
		# 倒挡下油门/刹车按键互换（与 GEVP VehicleController 一致），整形跟随互换后的映射
		var reversing := vehicle.current_gear == -1
		var raw_throttle: float = Input.get_action_strength("Brakes" if reversing else "Throttle")
		var raw_brake: float = Input.get_action_strength("Throttle" if reversing else "Brakes")
		_throttle = _ramp(_throttle, pow(raw_throttle, 2.0), THROTTLE_RISE, THROTTLE_FALL, delta)
		_brake = _ramp(_brake, raw_brake, BRAKE_RISE, BRAKE_FALL, delta)

		var brake_out := _brake
		if not reversing and vehicle.speed < 1.5 and vehicle.local_velocity.z <= 0.1:
			# 前进/空挡且接近停稳：刹车先压在挂倒挡阈值之下，按满 REVERSE_HOLD_TIME 秒才放行
			if raw_brake > 0.5:
				_brake_hold += delta
				if _brake_hold < REVERSE_HOLD_TIME:
					brake_out = minf(brake_out, REVERSE_BRAKE_GATE)
			else:
				_brake_hold = 0.0
		else:
			_brake_hold = 0.0

		vehicle.throttle_input = _throttle
		vehicle.brake_input = brake_out
		vehicle.steering_input = Input.get_action_strength("Steer Left") - Input.get_action_strength("Steer Right")
		vehicle.handbrake_input = Input.get_action_strength("Handbrake")
		if Input.is_action_just_pressed("Tactical1"):
			fire(0)
		if Input.is_action_just_pressed("Tactical2"):
			fire(1)
		# R 倒转：失控/极端情况回到上一个检查点（限速/幽灵细则见 RaceManager.rewind_player）
		if Input.is_action_just_pressed("Rewind") and race != null:
			race.rewind_player()

	# ---- 技能状态机 ----
	for s in tactical:
		s.cd_left = maxf(0.0, s.cd_left - delta)

	if nitro_left > 0.0:
		nitro_left -= delta
		# 氮气推力：power 为推力倍率，作用在整车质量上
		vehicle.apply_central_force(-vehicle.global_transform.basis.z * nitro_power * vehicle.mass * 3.0)

	if stealth_left > 0.0:
		stealth_left -= delta
		_set_transparency(0.65)
		_was_stealth = true
	elif _was_stealth:
		_set_transparency(0.0)
		_was_stealth = false

func _ramp(value: float, target: float, rise: float, fall: float, delta: float) -> float:
	return move_toward(value, target, (rise if target > value else fall) * delta)

func fire(slot: int) -> void:
	if slot >= tactical.size():
		return
	var s: Dictionary = tactical[slot]
	if s.ammo <= 0:
		return
	if s.cd_left > 0.0:
		return
	s.ammo -= 1
	s.cd_left = float(s.cfg.cooldown)
	match String(s.cfg.effect):
		"nitro_push":
			nitro_left = float(s.cfg.duration)
			nitro_power = float(s.cfg.power)
		"stealth":
			stealth_left = float(s.cfg.duration)
		"slow_spin":
			if race == null:
				return  # 调试场景无 RaceManager，不可锁定
			var target := race.find_target_ahead(vehicle, Match.game_cfg("lock_ahead_range"))
			if target != null:
				target.vehicle.linear_velocity *= 0.45
				target.vehicle.angular_velocity += Vector3(0, float(s.cfg.power) * 0.12, 0)
		_:
			pass

func is_stealth() -> bool:
	return stealth_left > 0.0

## HUD 轮询用
func tactical_ui() -> Array:
	var out: Array = []
	for i in tactical.size():
		var s: Dictionary = tactical[i]
		out.append({
			"key": KEY_LABELS[i] if i < KEY_LABELS.size() else "-",
			"name": String(s.cfg.name),
			"ammo": s.ammo, "max_ammo": int(s.cfg.ammo),
			"cd": s.cd_left, "cd_max": float(s.cfg.cooldown),
		})
	return out

func _set_transparency(a: float) -> void:
	for child in vehicle.find_children("*", "GeometryInstance3D", true, false):
		child.transparency = a
