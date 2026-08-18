extends Control
class_name RaceMiniMap

const BACK_METERS := 100.0
const AHEAD_METERS := 180.0
const FADE_METERS := 28.0
const VIEW_DIAMETER_METERS := BACK_METERS + AHEAD_METERS
const ROUTE_WHITE := Color(1.0, 1.0, 1.0, 0.9)
const PLAYER_COLOR := Color(0.95, 0.08, 0.05, 1.0)

var manager: RaceManager
var _has_route := false
var _center_s := 0.0

func bind(m: RaceManager) -> void:
	manager = m
	_has_route = manager != null and manager.track_data != null
	queue_redraw()

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	clip_contents = true
	_has_route = manager != null and manager.track_data != null
	queue_redraw()

func _process(_delta: float) -> void:
	if manager == null:
		return
	if not _has_route:
		_has_route = manager.track_data != null
	queue_redraw()

func _progress_window() -> Array:
	var length := float(manager.track_data.length)
	var center_s := clampf(manager.player_racer.progress, 0.0, length)
	return [maxf(0.0, center_s - BACK_METERS), minf(length, center_s + AHEAD_METERS), center_s]

func _map_point(world: Vector3, focus: Vector3) -> Vector2:
	var scale := minf(size.x, size.y) / VIEW_DIAMETER_METERS
	return size * 0.5 + Vector2(world.x - focus.x, world.z - focus.z) * scale

func _fade_alpha(s: float, start_s: float, end_s: float) -> float:
	var from_start := clampf((s - start_s) / FADE_METERS, 0.0, 1.0)
	var to_end := clampf((end_s - s) / FADE_METERS, 0.0, 1.0)
	return minf(from_start, to_end)

func _draw_route_segment(start_s: float, end_s: float, focus: Vector3) -> void:
	if end_s <= start_s:
		return
	var sample_count := maxi(24, ceili((end_s - start_s) / 4.0))
	var previous := manager.track_data.point_at(start_s)
	for i in range(1, sample_count + 1):
		var s0 := lerpf(start_s, end_s, float(i - 1) / sample_count)
		var s1 := lerpf(start_s, end_s, float(i) / sample_count)
		var current := manager.track_data.point_at(s1)
		var p0 := _map_point(previous, focus)
		var p1 := _map_point(current, focus)
		var alpha := _fade_alpha((s0 + s1) * 0.5, start_s, end_s)
		draw_line(p0, p1, Color(ROUTE_WHITE, ROUTE_WHITE.a * alpha), 4.6, true)
		previous = current

func _draw() -> void:
	var center := size * 0.5
	if _has_route and manager != null and manager.player_racer != null:
		var window := _progress_window()
		var start_s: float = window[0]
		var end_s: float = window[1]
		var center_s: float = window[2]
		_center_s = center_s
		# Focus is the route centerline, so lateral car movement does not move the map.
		var focus := manager.track_data.point_at(center_s)
		_draw_route_segment(start_s, end_s, focus)
	else:
		var oval := PackedVector2Array()
		var radius := minf(size.x, size.y) * 0.5
		for i in 65:
			var a := TAU * float(i) / 64.0
			oval.append(center + Vector2(cos(a) * radius * 0.72, sin(a) * radius * 0.42))
		draw_polyline(oval, ROUTE_WHITE, 4.6, true)

	if manager == null or manager.player_racer == null:
		return
	# Follow the track tangent, independent of the car's lateral steering angle.
	var tangent := manager.track_data.tangent_at(_center_s)
	var forward := Vector2(tangent.x, tangent.z).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector2.UP
	var side := Vector2(-forward.y, forward.x)
	draw_colored_polygon(PackedVector2Array([
		center + forward * 8.5,
		center - forward * 4.5 + side * 3.7,
		center - forward * 4.5 - side * 3.7]), PLAYER_COLOR)
