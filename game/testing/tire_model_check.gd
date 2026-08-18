extends SceneTree
## 轮胎模型自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 峰值滑移角区间：新刚度标度（Road 0.3）下 2° 未饱和、16° 接近完全饱和、
##    曲线单调不减——存在可感知的渐进抓地区（旧标度 Road 10 在 ~0.4° 就饱和，
##    抓地是开关式的）；若刚度被改回旧量级，本组断言失败；
## 2. 载荷敏感性：μ 随载荷递减（2× 载荷显著降 μ）、载荷转移净损失（弯中
##    1.5R+0.5R 的轴容量低于 2R）、绝对基准（1.2R 轴 μ 低于 0.8R 轴）——
##    防倾杆/前后配重/制动载荷转移因此重新成为推头-甩尾的调校手段；
## 3. 边界安全：Fz→0 与 100× 平均轮载不产生 NaN/INF（载荷比值有夹紧）。
## 采样参数镜像 car_builder 零改件基线：cof Road 3.0、stiffness Road 0.3。

const _DT := 1.0 / 120.0
const _FWD := 20.0  # 采样车速 m/s

var _v: Vehicle
var _w: Wheel
var _R := 0.0  # 整车平均轮载（static_load_reference）
var _fails := 0

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_v.freeze = true
	_v.coefficient_of_friction = {"Road": 3.0, "Dirt": 2.4, "Grass": 2.0}
	_v.tire_stiffnesses = {"Road": 0.3, "Dirt": 0.2, "Grass": 0.15}
	_v.contact_patch = 0.2
	root.add_child(_v)

func _process(_delta: float) -> bool:
	# _init 里 add_child 不会立刻触发 _ready（SceneTree 脚本特性），
	# 首帧手动补 initialize（幂等守卫，避免 _ready 后到造成双次初始化）
	if not _v.is_ready:
		_v.initialize()
	_w = _v.front_left_wheel
	_R = _w.static_load_reference
	_check_params_pushed()
	_check_slip_curve()
	_check_load_sensitivity()
	_check_edges()
	print("[TIRE] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
	return true

func _expect(cond: bool, label: String, detail := "") -> void:
	if not cond:
		_fails += 1
		print("[TIRE] FAIL %s %s" % [label, detail])

## 纯侧偏采样：给定侧偏角与垂载，返回该轮侧向力。
## 轮速匹配前进分量（cos 分量）→ slip.y ≈ 0，只保留纯侧偏工况。
func _lat_force(slip_deg: float, fz: float) -> float:
	var slip := deg_to_rad(slip_deg)
	_w.spring_force = fz
	_w.applied_torque = 0.0
	_w.local_velocity = Vector3(-sin(slip) * _FWD, 0.0, -cos(slip) * _FWD)
	_w.spin = cos(slip) * _FWD / _w.tire_radius
	_w.process_tires(false, _DT)
	return absf(_w.force_vector.x)

func _check_params_pushed() -> void:
	_expect(absf(_w.load_sensitivity - _v.tire_load_sensitivity) < 1e-6,
			"载荷敏感性指数下推到轮", "%.3f vs %.3f" % [_w.load_sensitivity, _v.tire_load_sensitivity])
	_expect(absf(_R - _v.vehicle_mass * 9.8 / 4.0) < 1.0,
			"归一基准 = 整车平均轮载", "%.1f vs %.1f" % [_R, _v.vehicle_mass * 9.8 / 4.0])
	_expect(absf(_w.current_tire_stiffness - (1000000.0 + 8000000.0 * 0.3)) < 1.0,
			"Road 刚度按下推字典标定", "%.0f" % _w.current_tire_stiffness)

func _check_slip_curve() -> void:
	var f2 := _lat_force(2.0, _R)
	var f4 := _lat_force(4.0, _R)
	var f6 := _lat_force(6.0, _R)
	var f16 := _lat_force(16.0, _R)
	var f45 := _lat_force(45.0, _R)
	_expect(f2 < 0.5 * f45, "2° 未饱和（存在渐进区）", "f2=%.0f f45=%.0f" % [f2, f45])
	_expect(f4 < 0.6 * f45, "4° 仍在渐进区", "f4=%.0f f45=%.0f" % [f4, f45])
	_expect(f16 >= 0.82 * f45, "16° 接近完全饱和", "f16=%.0f f45=%.0f" % [f16, f45])
	_expect(f2 <= f4 and f6 <= f16 and f16 <= f45 + 1.0, "曲线单调不减（无峰值后骤跌）",
			"%.0f %.0f %.0f %.0f %.0f" % [f2, f4, f6, f16, f45])

func _check_load_sensitivity() -> void:
	var f1 := _lat_force(20.0, _R)
	var f2x := _lat_force(20.0, 2.0 * _R)
	var fhi := _lat_force(20.0, 1.5 * _R)
	var flo := _lat_force(20.0, 0.5 * _R)
	var fheavy := _lat_force(20.0, 1.2 * _R)
	var flight := _lat_force(20.0, 0.8 * _R)
	_expect(f2x / (2.0 * _R) < 0.93 * f1 / _R, "μ 随载荷递减（2× 载荷）",
			"μ2R=%.3f μR=%.3f" % [f2x / (2.0 * _R), f1 / _R])
	_expect(fhi + flo < 0.99 * 2.0 * f1, "载荷转移净损失（弯中轴容量下降）",
			"1.5R+0.5R=%.0f vs 2R=%.0f" % [fhi + flo, 2.0 * f1])
	_expect(flight / (0.8 * _R) > fheavy / (1.2 * _R), "绝对基准：重轴 μ 低于轻轴",
			"μ0.8R=%.3f μ1.2R=%.3f" % [flight / (0.8 * _R), fheavy / (1.2 * _R)])

func _check_edges() -> void:
	var fz0 := _lat_force(20.0, 0.0)
	var fz100 := _lat_force(20.0, 100.0 * _R)
	_expect(is_finite(fz0) and fz0 >= 0.0 and is_finite(fz100),
			"Fz→0 与 100× 载荷无 NaN/INF", "fz0=%.2f fz100=%.0f" % [fz0, fz100])
