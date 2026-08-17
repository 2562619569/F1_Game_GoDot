extends SceneTree
## 升挡转速下坠自检（godot --headless -s 运行，不依赖 autoload）：
## 换挡窗口内 motor_rpm 应按指数收敛到新挡位的轮速匹配转速（升挡可听的转速回落），
## 而不是贴着红线保持、等离合重新接合后才被拽下来：
## 1. 升挡窗口：0.15s 转速已显著下坠，0.30s（=shift_time）收敛到新挡匹配转速附近；
## 2. 非升挡窗口（降挡/空挡滑移）：窗口内只有引擎拖拽，转速不发生快速下坠。

const _DT := 1.0 / 120.0

var _v: Vehicle
var _fails := 0

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_v.freeze = true
	root.add_child(_v)

func _process(_delta: float) -> bool:
	_v.set_physics_process(false)   # 手动驱动 process_motor，避免物理帧覆盖 speed
	_check_upshift_fall()
	_check_non_upshift_hold()
	print("[SHIFTREV] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
	return true

func _expect(cond: bool, label: String, detail := "") -> void:
	if not cond:
		_fails += 1
		print("[SHIFTREV] FAIL %s %s" % [label, detail])

## 齿轮 from_gear 在红线转速下对应的车速，与升入 to_gear 后的轮速匹配转速
func _matched_rpm(from_gear: int, to_gear: int, rpm: float) -> float:
	var wheel_spin := rpm / (_v.gear_ratios[from_gear - 1] * _v.final_drive * (60.0 / TAU))
	_v.speed = wheel_spin * _v.average_drive_wheel_radius
	return _v.gear_ratios[to_gear - 1] * _v.final_drive * wheel_spin * (60.0 / TAU)

## 驱动 process_motor 秒数，返回结束时 motor_rpm
func _run_motor(seconds: float) -> float:
	for i in int(round(seconds / _DT)):
		_v.process_motor(_DT)
	return _v.motor_rpm

func _check_upshift_fall() -> void:
	var target := _matched_rpm(3, 4, _v.max_rpm)
	_v.throttle_amount = 0.0   # 换挡断油（process_throttle 在窗口内做的事）
	_v.clutch_amount = 1.0     # 换挡离合分离（shift() 在窗口内做的事）
	_v.current_gear = 3
	_v.requested_gear = 4
	_v.is_shifting = true
	_v.is_up_shifting = true
	_v.motor_rpm = _v.max_rpm
	var gap := _v.max_rpm - target
	var mid := _run_motor(0.15)
	var end := _run_motor(0.15)
	_expect(mid < _v.max_rpm - gap * 0.5, "换挡前半程转速已显著下坠",
			"0.15s: %.0f→%.0f" % [_v.max_rpm, mid])
	_expect(absf(end - target) < gap * 0.25, "换挡结束收敛到新挡匹配转速",
			"0.30s: %.0f target=%.0f" % [end, target])
	_v.is_shifting = false
	_v.is_up_shifting = false

func _check_non_upshift_hold() -> void:
	_v.motor_rpm = _v.max_rpm
	_v.is_shifting = true
	_v.is_up_shifting = false   # 降挡/摘挡窗口：不应触发升挡下坠
	var end := _run_motor(0.3)
	_expect(end > _v.max_rpm - 800.0, "非升挡窗口转速不被快速下拽",
			"0.30s: %.0f→%.0f" % [_v.max_rpm, end])
	_v.is_shifting = false
