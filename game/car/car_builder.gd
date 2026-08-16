class_name CarBuilder
extends RefCounted
## 「配表 → 车辆物理」的唯一入口：
## 1. Car 表的物理基础参数直接写入 GEVP Vehicle 导出变量；
## 2. 改件合成属性（Match.get_stats）按映射规则调制物理参数；
## 3. 地图环境（env 配置）修正路面摩擦。
## 换底盘/改数值只需改表；换物理插件只需改本文件。

## 改件属性 → GEVP 参数的映射系数（正为加成）
const K_ACCEL_TORQUE := 0.02        # accel +1 → 扭矩 +2%
const K_TOPSPEED_RPM := 0.008       # top_speed +1 → 红线转速 +0.8%
const K_TOPSPEED_DRAG := 0.003      # top_speed +1 → 风阻 -0.3%
const K_GRIP_ROAD := 0.025          # grip_road +1 → 铺装摩擦 +2.5%
const K_GRIP_OFFROAD := 0.030       # grip_offroad +1 → 越野摩擦 +3%
const K_GRIP_WET := 0.04            # grip_wet +1 → 湿滑路面摩擦 +4%
const K_AERO_DRAG := 0.004          # aero +1（下压力）→ 风阻 +0.4%（负 aero 即低阻）
const K_AERO_GRIP := 0.02           # aero +1 → 高速抓地（简化为摩擦加成）
const K_AERO_STAB := 0.15           # aero +1 → 横摆稳定强度
const K_LANDING_BUMP := 0.03        # landing +1 → 缓冲止点/落地稳定 +3%
const K_LANDING_UPRIGHT := 0.06     # landing +1 → 空中回正弹簧 +6%

static func apply(v: Vehicle, cfg: Dictionary, stats: Dictionary, env: Dictionary, torque_scale := 1.0) -> void:
	# --- 底盘基础参数（Car 表，字段名与 vehicle.gd 导出变量一一对应）---
	v.vehicle_mass = maxf(500.0, float(cfg.weight) + stats.mass)
	v.max_torque = float(cfg.max_torque) * (1.0 + stats.accel * K_ACCEL_TORQUE) * torque_scale
	v.max_rpm = float(cfg.max_rpm) * (1.0 + stats.top_speed * K_TOPSPEED_RPM)
	v.final_drive = float(cfg.final_drive)
	var gears: Array[float] = []
	for g in cfg.gear_ratios:
		gears.append(float(g))
	v.gear_ratios = gears
	v.front_torque_split = float(cfg.front_torque_split)
	v.max_steering_angle = deg_to_rad(float(cfg.max_steering_angle))
	v.steering_speed = float(cfg.steering_speed)
	v.brake_force_multiplier = float(cfg.brake_force_multiplier)
	v.front_weight_distribution = float(cfg.front_weight_distribution)
	v.center_of_gravity_height_offset = float(cfg.center_of_gravity_height_offset)
	v.inertia_multiplier = float(cfg.inertia_multiplier)
	v.coefficient_of_drag = maxf(0.12, float(cfg.coefficient_of_drag) + stats.aero * K_AERO_DRAG)

	# --- 轮胎（表面键固定 Road/Dirt/Grass，与赛道碰撞体分组对应）---
	var w := WeatherEnv.surface_mod_cfg(env)
	var road: float = 3.0 * (1.0 + stats.grip_road * K_GRIP_ROAD) * w.Road
	var dirt: float = 2.4 * (1.0 + stats.grip_offroad * K_GRIP_OFFROAD) * w.Dirt
	var grass: float = 2.0 * (1.0 + stats.grip_offroad * K_GRIP_OFFROAD * 0.6)
	if w.wet:  # 雨胎只在湿滑天气生效
		road += stats.grip_wet * K_GRIP_WET
		dirt += stats.grip_wet * 0.02
		grass += stats.grip_wet * 0.02
	var downforce := maxf(0.0, stats.aero)
	road += downforce * K_AERO_GRIP
	dirt += downforce * K_AERO_GRIP * 0.5
	grass += downforce * K_AERO_GRIP * 0.25
	v.coefficient_of_friction = {"Road": road, "Dirt": dirt, "Grass": grass}
	v.tire_stiffnesses = {
		"Road": 10.0 * (1.0 + stats.grip_road * 0.01),
		"Dirt": 0.5 * (1.0 + stats.grip_offroad * 0.01),
		"Grass": 0.5,
	}
	v.rolling_resistance = {
		"Road": 1.0 * (1.0 - downforce * 0.01),
		"Dirt": 2.0 * (1.0 - stats.grip_offroad * 0.01),
		"Grass": 4.0,
	}

	# --- 悬挂 / 稳定性 ---
	var land: float = 1.0 + stats.landing * K_LANDING_BUMP
	v.front_bump_stop_multiplier *= land
	v.rear_bump_stop_multiplier *= land
	v.stability_upright_spring = 1.0 + stats.landing * K_LANDING_UPRIGHT
	v.stability_yaw_strength = 6.0 + downforce * K_AERO_STAB

## 车顶识别色块（测试素材：区分玩家/AI）
static func add_team_banner(v: Vehicle, color: Color) -> void:
	var m := MeshInstance3D.new()
	m.name = "TeamBanner"
	var box := BoxMesh.new()
	box.size = Vector3(0.55, 0.22, 0.85)
	m.mesh = box
	m.position = Vector3(0, 1.02, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	m.material_override = mat
	v.add_child(m)
