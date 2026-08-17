class_name Speedometer
extends Control

const SCALE_MAX_RPM := 10000.0
const START_ANGLE := deg_to_rad(140.0)
const SWEEP_ANGLE := deg_to_rad(260.0)
const FACE := Color(0.025, 0.04, 0.065, 0.82)
const RING := Color(0.9, 0.97, 1.0, 0.92)
const RING_DIM := Color(0.39, 0.57, 0.65, 0.32)
const CYAN := Color(0.22, 0.82, 0.86, 0.9)
const RED := Color(1.0, 0.22, 0.32, 0.98)
const TEXT := Color(0.91, 0.96, 1.0, 0.96)

@onready var speed_value: Label = %SpeedValue
@onready var gear_value: Label = %GearValue

var _rpm := 0.0
var _max_rpm := 8000.0


func set_values(speed_kmh: int, gear: int, rpm: float, max_rpm: float) -> void:
	speed_value.text = str(speed_kmh)
	gear_value.text = str(gear)
	_rpm = maxf(rpm, 0.0)
	_max_rpm = maxf(max_rpm, 1.0)
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	var center := size * 0.5
	var radius := side * 0.43
	var red_start := clampf((_max_rpm * 0.82) / SCALE_MAX_RPM, 0.58, 0.72)
	var red_angle := START_ANGLE + SWEEP_ANGLE * red_start
	var end_angle := START_ANGLE + SWEEP_ANGLE

	# Dark translucent face keeps the dial readable without hiding the road.
	draw_circle(center, radius + 8.0, Color(0.02, 0.06, 0.09, 0.32))
	draw_circle(center, radius - 2.0, FACE)
	draw_arc(center, radius + 3.0, START_ANGLE, end_angle, 96, RING_DIM, 10.0, true)
	draw_arc(center, radius + 3.0, START_ANGLE, red_angle, 72, Color(0.76, 0.94, 1.0, 0.18), 8.0, true)
	draw_arc(center, radius + 3.0, START_ANGLE, red_angle, 72, RING, 3.0, true)
	draw_arc(center, radius + 3.0, red_angle, end_angle, 36, Color(1.0, 0.14, 0.27, 0.22), 12.0, true)
	draw_arc(center, radius + 3.0, red_angle, end_angle, 36, RED, 4.0, true)

	_draw_ticks(center, radius, red_start)
	_draw_needle(center, radius)


func _draw_ticks(center: Vector2, radius: float, red_start: float) -> void:
	var font := ThemeDB.fallback_font
	for i in 41:
		var t := float(i) / 40.0
		var angle := START_ANGLE + SWEEP_ANGLE * t
		var major := i % 4 == 0
		var tick_outer := radius - 5.0
		var tick_inner := radius - (16.0 if major else 10.0)
		var color := RED if t >= red_start else Color(0.86, 0.95, 1.0, 0.9)
		draw_line(_point(center, angle, tick_inner), _point(center, angle, tick_outer), color,
				3.0 if major else 1.2, true)
		if major:
			var label := str(i / 4)
			var label_center := _point(center, angle, radius - 31.0)
			var label_width := 30.0
			draw_string(font, label_center + Vector2(-label_width * 0.5, 5.0), label,
					HORIZONTAL_ALIGNMENT_CENTER, label_width, 14, TEXT)


func _draw_needle(center: Vector2, radius: float) -> void:
	var rpm_ratio := clampf(_rpm / SCALE_MAX_RPM, 0.0, 1.0)
	var angle := START_ANGLE + SWEEP_ANGLE * rpm_ratio
	var tip := _point(center, angle, radius - 36.0)
	var tail := _point(center, angle + PI, 16.0)
	draw_line(tail, tip, Color(1.0, 0.16, 0.28, 0.18), 8.0, true)
	draw_line(tail, tip, RED, 2.5, true)
	draw_circle(center, 7.0, Color(0.04, 0.07, 0.1, 1.0))
	draw_circle(center, 4.0, Color(0.92, 0.98, 1.0, 1.0))
	draw_arc(center, 10.0, 0.0, TAU, 24, CYAN, 1.5, true)


func _point(center: Vector2, angle: float, radius: float) -> Vector2:
	return center + Vector2(cos(angle), sin(angle)) * radius
