extends Control
## 四维属性雷达图：极速 / 加速 / 铺装抓地 / 越野。
## 灰色多边形 = 底盘原值（改装前），青色 = 当前装配（改装后），
## 直观呈现改件的实际性能影响。

var base_stats := {}
var cur_stats := {}

const AXES := [
	{"key": "top_speed", "label": "SPD", "max": 340.0},
	{"key": "accel", "label": "ACC", "max": 12.0},
	{"key": "grip_road", "label": "ROAD", "max": 26.0},
	{"key": "grip_offroad", "label": "OFF", "max": 26.0},
]
const FILL := Color(0.22, 0.77, 0.81, 0.35)
const LINE := Color(0.22, 0.77, 0.81, 0.9)
const BASE_LINE := Color(0.62, 0.66, 0.72, 0.55)

func set_data(base: Dictionary, cur: Dictionary) -> void:
	base_stats = base
	cur_stats = cur
	queue_redraw()

func _axis_point(i: int, ratio: float) -> Vector2:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 26.0
	var angle := -PI / 2.0 + TAU * float(i) / float(AXES.size())
	return center + Vector2(cos(angle), sin(angle)) * radius * clampf(ratio, 0.05, 1.0)

func _poly(stats: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in AXES.size():
		var a: Dictionary = AXES[i]
		var v := 0.1
		if stats.has(a.key):
			v = float(stats[a.key]) / float(a.max)
		pts.append(_axis_point(i, v))
	return pts

func _draw() -> void:
	if base_stats.is_empty() or cur_stats.is_empty():
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 26.0

	# 网格
	for ring in [0.33, 0.66, 1.0]:
		var grid := PackedVector2Array()
		for i in AXES.size():
			var angle := -PI / 2.0 + TAU * float(i) / float(AXES.size())
			grid.append(center + Vector2(cos(angle), sin(angle)) * radius * ring)
		draw_colored_polygon(grid, Color(1, 1, 1, 0.03))
		draw_polyline(grid + PackedVector2Array([grid[0]]), Color(1, 1, 1, 0.12), 1.0)
	for i in AXES.size():
		draw_line(center, _axis_point(i, 1.0), Color(1, 1, 1, 0.12), 1.0)

	# 底盘原值（改装前对照）
	var base_poly := _poly(base_stats)
	draw_polyline(base_poly + PackedVector2Array([base_poly[0]]), BASE_LINE, 2.0, true)

	# 当前装配
	var cur_poly := _poly(cur_stats)
	draw_colored_polygon(cur_poly, FILL)
	draw_polyline(cur_poly + PackedVector2Array([cur_poly[0]]), LINE, 2.5, true)
	for p in cur_poly:
		draw_circle(p, 4.0, LINE)

	# 轴标签
	var font := ThemeDB.fallback_font
	for i in AXES.size():
		var a: Dictionary = AXES[i]
		var lp := _axis_point(i, 1.18)
		var text: String = a.label
		draw_string(font, lp - Vector2(font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, 14).x * 0.5, -6.0), text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(0.82, 0.88, 0.95))
