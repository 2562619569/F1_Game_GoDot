class_name PlayerCar
extends Node3D
## 玩家赛车根节点：键盘输入（复用 GEVP 输入映射）+ 战术技能。
## 战术件配表驱动：effect = nitro_push / stealth / slow_spin，
## 弹药与冷却按 Part 表 cooldown / ammo / duration 每回合重置。

const KEY_LABELS := ["Q", "E"]

var vehicle: Vehicle
var frozen := true
var race: RaceManager = null  # 注入用于火箭锁定；调试场景可为 null

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
		vehicle.throttle_input = 0.0
		vehicle.brake_input = 0.5
		vehicle.steering_input = 0.0
		vehicle.handbrake_input = 1.0
		return

	if Match.auto_test:  # 冒烟测试：自动驾驶沿赛道中心线
		_auto_follower.drive(vehicle)
	else:
		vehicle.throttle_input = pow(Input.get_action_strength("Throttle"), 2.0)
		vehicle.brake_input = Input.get_action_strength("Brakes")
		vehicle.steering_input = Input.get_action_strength("Steer Left") - Input.get_action_strength("Steer Right")
		vehicle.handbrake_input = Input.get_action_strength("Handbrake")
		if Input.is_action_just_pressed("Tactical1"):
			fire(0)
		if Input.is_action_just_pressed("Tactical2"):
			fire(1)
		# 倒挡逻辑（与 GEVP VehicleController 一致）
		if vehicle.current_gear == -1:
			vehicle.brake_input = Input.get_action_strength("Throttle")
			vehicle.throttle_input = Input.get_action_strength("Brakes")

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
