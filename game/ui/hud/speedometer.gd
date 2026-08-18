class_name Speedometer
extends Control

## Minimal translucent racing dash. The dial is intentionally drawn without a
## solid face so the road remains visible behind the instrument.
const START_ANGLE := deg_to_rad(118.0)
const SWEEP_ANGLE := deg_to_rad(242.0)
const TICK_COUNT := 28
const DIAL := Color(0.70, 0.78, 0.68, 0.29)
const DIAL_FAINT := Color(0.66, 0.75, 0.65, 0.11)
const RED := Color(0.96, 0.08, 0.22, 0.88)
const WHITE := Color(0.96, 0.98, 0.94, 0.96)
const DIM_WHITE := Color(0.75, 0.80, 0.72, 0.38)
const GREEN := Color(0.10, 1.0, 0.55, 0.96)
const GREEN_FAINT := Color(0.10, 0.85, 0.43, 0.25)

@onready var speed_value: Label = %SpeedValue
@onready var speed_leading: Label = %SpeedLeading
@onready var gear_value: Label = %GearValue

var _rpm := 0.0
var _max_rpm := 8000.0


func set_values(speed_kmh: int, gear: int, rpm: float, max_rpm: float) -> void:
	var display_speed := "%03d" % roundi(speed_kmh * 0.621371)
	speed_leading.text = display_speed.left(1)
	speed_value.text = display_speed.substr(1)
	gear_value.text = str(gear if gear != 0 else "N")
	_rpm = maxf(rpm, 0.0)
	_max_rpm = maxf(max_rpm, 1.0)
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	var center := size * 0.5
	var radius := side * 0.445
	var red_start := 6.2 / 7.0
	var red_angle := START_ANGLE + SWEEP_ANGLE * red_start
	var end_angle := START_ANGLE + SWEEP_ANGLE

	# A very light shadow and hairline ring are enough for contrast over scenery.
	draw_circle(center, radius + 4.0, Color(0.0, 0.02, 0.0, 0.07))
	draw_arc(center, radius, START_ANGLE, end_angle, 128, DIAL, 4.0, true)
	draw_arc(center, radius + 1.0, START_ANGLE, red_angle, 100, DIAL_FAINT, 3.0, true)
	draw_arc(center, radius + 1.0, red_angle, end_angle, 30, RED, 7.0, true)
	_draw_ticks(center, radius, red_start)

	# The grey carrier ring is deliberately broken; the pointer pivots from this
	# ring instead of displaying a central axle dot.
	draw_circle(center, 41.0, Color(0.01, 0.08, 0.03, 0.18))
	draw_arc(center, 50.0, deg_to_rad(138.0), deg_to_rad(318.0), 40,
			Color(0.45, 0.52, 0.42, 0.50), 3.0, true)
	draw_arc(center, 50.0, deg_to_rad(332.0), deg_to_rad(422.0), 32,
			Color(0.45, 0.52, 0.42, 0.50), 3.0, true)
	draw_arc(center, 40.0, 0.0, TAU, 48, GREEN_FAINT, 5.0, true)
	draw_arc(center, 35.0, 0.0, TAU, 48, GREEN, 3.0, true)
	_draw_needle(center, radius)


func _draw_ticks(center: Vector2, radius: float, red_start: float) -> void:
	var font := ThemeDB.fallback_font
	for i in TICK_COUNT + 1:
		var t := float(i) / float(TICK_COUNT)
		var angle := START_ANGLE + SWEEP_ANGLE * t
		var major := i % 4 == 0
		var tick_outer := radius - 5.0
		var tick_inner := radius - (18.0 if major else 10.0)
		var color := RED if t >= red_start else (DIAL if major else DIAL_FAINT)
		draw_line(_point(center, angle, tick_inner), _point(center, angle, tick_outer), color,
				3.0 if major else 1.5, true)
		if major:
			var label := str(i / 4)
			var label_center := _point(center, angle, radius - 35.0)
			draw_string(font, label_center + Vector2(-12.0, 5.0), label,
					HORIZONTAL_ALIGNMENT_CENTER, 24.0, 15,
					Color(0.88, 0.91, 0.85, 0.86) if t < red_start else RED)


func _draw_needle(center: Vector2, radius: float) -> void:
	var rpm_ratio := clampf(_rpm / _max_rpm, 0.0, 1.0)
	var angle := START_ANGLE + SWEEP_ANGLE * rpm_ratio
	var tip := _point(center, angle, radius - 29.0)
	var tail := _point(center, angle, 49.0)
	# Soft dark edge prevents the white pointer from disappearing on bright tracks.
	draw_line(tail, tip, Color(0.0, 0.0, 0.0, 0.24), 8.0, true)
	draw_line(tail, tip, WHITE, 4.0, true)


func _point(center: Vector2, angle: float, radius: float) -> Vector2:
	return center + Vector2(cos(angle), sin(angle)) * radius
