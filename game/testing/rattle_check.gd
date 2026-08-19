extends SceneTree
## 砂石车身微抖 body_rattle 自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配结构：BodyPivot → BodyRattle → BodyVisual 三层链就位；碰撞体/悬挂
##    射线不在 BodyRattle 链下（纯表现，物理零耦合）；
## 2. 全轮砂石 @20 m/s：强度缓入 ≈1，竖直颠主轴幅度达 2~4mm 且有上界，
##    横向/滚转不超配幅，z 向与 yaw 恒为零，刚体 transform 分毫不动；
## 3. 半边轮骑路肩 → 目标强度精确减半；车速 5 m/s → 0.375、低于 2 m/s → 0；
## 4. 回路面缓出：release 后强度归零、位姿精确复位（含 <1‰ 的 snap 归零）；
## 5. 两台车随机相位不同（多车不同步抖）。
## 车辆冻结 + 每帧手填 linear_velocity（与 camera_check 探针同法），
## 轮面直接写 wheel.surface_type（与相机砂石源同一数据缝），阶段按累计时间编排。

var checks := 0
var failures := 0
var _v: Vehicle
var _v2: Vehicle
var _r  # BodyRattle（untyped：动态调私有方法过静态检查）
var _r2

var _t := 0.0
var _phase := 0
var _speed := 20.0
var _done := false
var _max_y := 0.0
var _max_x := 0.0
var _max_roll := 0.0
var _max_z := 0.0
var _max_yaw := 0.0
var _base_xf := Transform3D.IDENTITY

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach_visual(_v, 601)
	root.add_child(_v)
	_v.freeze = true
	_v2 = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach_visual(_v2, 601)
	root.add_child(_v2)
	_v2.freeze = true

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[RATTLE] OK   | %s" % label)
	else:
		failures += 1
		print("[RATTLE] FAIL | %s" % label)

func _set_surfaces(v: Vehicle, surfaces: Array) -> void:
	var names := ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]
	for i in names.size():
		(v.get_node(names[i]) as Wheel).surface_type = String(surfaces[i])

func _process(delta: float) -> bool:
	if _done:
		return true
	_t += delta
	# 冻结刚体的速度属性每帧重填（headless 物理步可能回写）
	_v.linear_velocity = Vector3(0.0, 0.0, -_speed)
	_v2.linear_velocity = Vector3(0.0, 0.0, -_speed)

	match _phase:
		0:   # 结构（入树后首帧，_ready 已把四轮接线进 BodyRattle）
			_r = _v.get_node_or_null("BodyPivot/BodyRattle")
			_r2 = _v2.get_node_or_null("BodyPivot/BodyRattle")
			var visual: Node3D = _v.get_node_or_null("BodyPivot/BodyRattle/BodyVisual")
			ok(_r != null and visual != null and visual.get_parent() == _r
					and _r.get_parent() == _v.get_node("BodyPivot"),
					"assembly chain BodyPivot → BodyRattle → BodyVisual")
			ok(_r._wheels.size() == 4, "rattle wired to 4 wheels")
			ok(_r.find_children("*", "CollisionShape3D", true, false).is_empty()
					and _r.find_children("*", "RayCast3D", true, false).is_empty()
					and _v.find_children("*", "RayCast3D", true, false).size() >= 4,
					"collision & suspension rays stay off the rattle chain")
			ok(_r2 != null and _r._phases != _r2._phases,
					"two cars rattle out of phase (random per instance)")
			_set_surfaces(_v, ["Road", "Road", "Road", "Road"])
			_phase = 1
			_t = 0.0
		1:   # 路面巡航：应纹丝不动
			if _t >= 0.25:
				ok(_r._intensity == 0.0 and _r.position == Vector3.ZERO
						and _r.rotation == Vector3.ZERO,
						"on road at 20 m/s: body stays perfectly still")
				_set_surfaces(_v, ["Gravel", "Gravel", "Gravel", "Gravel"])
				_base_xf = _v.global_transform
				_max_y = 0.0
				_max_x = 0.0
				_max_roll = 0.0
				_max_z = 0.0
				_max_yaw = 0.0
				_phase = 2
				_t = 0.0
		2:   # 全轮砂石 @20 m/s：采样极值
			_max_y = maxf(_max_y, absf(_r.position.y))
			_max_x = maxf(_max_x, absf(_r.position.x))
			_max_roll = maxf(_max_roll, absf(_r.rotation.z))
			_max_z = maxf(_max_z, absf(_r.position.z))
			_max_yaw = maxf(_max_yaw, absf(_r.rotation.y))
			if _t >= 0.35:
				ok(_r._intensity > 0.95, "full gravel eases in (intensity %.3f)" % _r._intensity)
				ok(_max_y > 0.002 and _max_y < 0.0043,
						"vertical rattle 2~4mm (max %.4f m)" % _max_y)
				ok(_max_x < 0.0018 and _max_roll < 0.0037,
						"lateral/roll bounded (%.4f m / %.4f rad)" % [_max_x, _max_roll])
				ok(is_zero_approx(_max_z) and is_zero_approx(_max_yaw),
						"no longitudinal jitter, no yaw (%.5f / %.5f)" % [_max_z, _max_yaw])
				ok(_v.global_transform == _base_xf,
						"rigid body transform untouched while rattling")
				_set_surfaces(_v, ["Gravel", "Gravel", "Road", "Road"])
				_phase = 3
				_t = 0.0
		3:   # 半边轮骑路肩
			if _t >= 0.05:
				ok(_r._target_intensity() == 0.5,
						"half wheels on shoulder: target exactly 0.5 (%.3f)" % _r._target_intensity())
				_set_surfaces(_v, ["Gravel", "Gravel", "Gravel", "Gravel"])
				_speed = 5.0
				_phase = 4
				_t = 0.0
		4:   # 车速渐变
			if _t >= 0.05:
				ok(is_equal_approx(_r._target_intensity(), 0.375),
						"5 m/s eases to 0.375 (%.4f)" % _r._target_intensity())
				_speed = 1.5
				_phase = 5
				_t = 0.0
		5:
			if _t >= 0.05:
				ok(_r._target_intensity() == 0.0,
						"below onset 1.5 m/s: target silent on gravel")
				_set_surfaces(_v, ["Road", "Road", "Road", "Road"])
				_speed = 20.0
				_phase = 6
				_t = 0.0
		6:   # 回路面缓出（release 5/s → <1‰ 需 ~1.4s，随后 snap 归零）
			if _t >= 1.7:
				ok(_r._intensity == 0.0 and _r.position == Vector3.ZERO
						and _r.rotation == Vector3.ZERO,
						"back on road: eases out and pose resets exactly")
				print("========== RATTLE CHECK: %d checks, %d failures ==========" % [checks, failures])
				_done = true
				quit(1 if failures > 0 else 0)
	return false
