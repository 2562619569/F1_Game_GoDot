class_name TrackData
extends RefCounted
## HTML 赛道编辑器(tools/track_editor/index.html)导出 JSON 的运行时数据 + 几何查询。
## baked 采样点为紧凑数组 [x,y,z, tx,ty,tz, width, s](每点 8 元素,编辑器烘焙),
## Godot 直接消费烘焙点、不重新采样样条,保证所见即所得。
## 坐标系与编辑器一致:x 右,z 向前(-z 为起始前进方向),y 高度。

const LOOT_Y := 0.9        # 掉落物悬浮高度(路面之上)
const LOOKAHEAD_VSHIFT := 0.55  # AI 前瞻时间(秒)对应距离系数

var meta := {"id": 0, "name": ""}
var grid_cfg := {"count": 4, "row_gap": 8.0, "col_gap": 7.0, "first_row_offset": 6.0}
var options := {"walls": true, "wall_height": 1.2}
var routes: Array = []   # [{id, surface, pts, tans, widths, s_arr, radii}]
var main: Dictionary = {}
var length := 0.0

static func load_json(path: String) -> TrackData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("TrackData: 无法打开 %s" % path)
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary) or not parsed.has("baked"):
		push_error("TrackData: JSON 结构不合法 %s" % path)
		return null
	var d := TrackData.new()
	d._from_dict(parsed)
	if d.main.is_empty():
		push_error("TrackData: 缺少 road 主路 %s" % path)
		return null
	return d

func _from_dict(d: Dictionary) -> void:
	meta = d.get("meta", {})
	grid_cfg = d.get("grid", grid_cfg)
	options = d.get("options", options)
	var baked: Dictionary = d.get("baked", {})
	for r in d.get("routes", []):
		var rid := String(r.get("id", ""))
		if not baked.has(rid):
			continue
		var route := {
			"id": rid,
			"surface": String(r.get("surface", "road")),
			"pts": PackedVector3Array(),
			"tans": PackedVector3Array(),
			"widths": PackedFloat32Array(),
			"s_arr": PackedFloat32Array(),
			"radii": PackedFloat32Array(),
		}
		for p in baked[rid]:
			var a: Array = p
			route["pts"].append(Vector3(a[0], a[1], a[2]))
			route["tans"].append(Vector3(a[3], a[4], a[5]))
			route["widths"].append(a[6])
			route["s_arr"].append(a[7])
		if route["pts"].size() < 2:
			continue
		_compute_radii(route)
		routes.append(route)
		if route["surface"] == "road":
			main = route
	var s_arr: PackedFloat32Array = main.get("s_arr", PackedFloat32Array())
	if s_arr.size() > 0:
		length = s_arr[s_arr.size() - 1]

## 平面(xz)三点曲率半径,∞ 记 9999
func _compute_radii(route: Dictionary) -> void:
	var pts: PackedVector3Array = route["pts"]
	var radii := PackedFloat32Array()
	radii.resize(pts.size())
	radii.fill(9999.0)
	for i in range(1, pts.size() - 1):
		var a := pts[i - 1]
		var b := pts[i]
		var c := pts[i + 1]
		var cross := (b.x - a.x) * (c.z - b.z) - (b.z - a.z) * (c.x - b.x)
		if absf(cross) < 1e-6:
			continue
		var la := Vector2(b.x - a.x, b.z - a.z).length()
		var lb := Vector2(c.x - b.x, c.z - b.z).length()
		var lc := Vector2(a.x - c.x, a.z - c.z).length()
		if la < 1e-4 or lb < 1e-4:
			continue
		radii[i] = minf(9999.0, la * lb * lc / absf(cross))
	route["radii"] = radii

static func _flat_tangent(t: Vector3) -> Vector3:
	var v := Vector3(t.x, 0.0, t.z)
	return v.normalized() if v.length() > 1e-4 else Vector3(0.0, 0.0, -1.0)

static func _flat_normal(t: Vector3) -> Vector3:
	## up × tangent(平面左法线)
	var f := _flat_tangent(t)
	return Vector3(f.z, 0.0, -f.x)

func route_length(route: Dictionary) -> float:
	var s_arr: PackedFloat32Array = route["s_arr"]
	return s_arr[s_arr.size() - 1] if s_arr.size() > 0 else 0.0

## ---------------- 定位 / 进度 ----------------

## 最近样条索引;hint>=0 时窗口搜索,离太远(>60m)自动全局重搜
func nearest_index(pos: Vector3, hint: int, route: Dictionary = {}) -> int:
	var rt: Dictionary = route if not route.is_empty() else main
	var pts: PackedVector3Array = rt["pts"]
	var n := pts.size()
	if n == 0:
		return -1
	var lo := 0
	var hi := n - 1
	if hint >= 0:
		lo = maxi(0, hint - 30)
		hi = mini(n - 1, hint + 60)
	var best := -1
	var best_d := 1e18
	for i in range(lo, hi + 1):
		var dd: float = pos.distance_squared_to(pts[i])
		if dd < best_d:
			best_d = dd
			best = i
	if best_d > 3600.0 and (lo > 0 or hi < n - 1):
		return nearest_index(pos, -1, rt)
	return best

## 排名进度:返回 [s, 最近索引](索引作下次 hint)
func progress_at(pos: Vector3, hint: int) -> Array:
	var idx := nearest_index(pos, hint)
	if idx < 0:
		return [0.0, -1]
	var s_arr: PackedFloat32Array = main["s_arr"]
	return [s_arr[idx], idx]

## s → 区间 [i-1, i] 与插值系数
func _window(s: float, route: Dictionary) -> Array:
	var s_arr: PackedFloat32Array = route["s_arr"]
	var rl := route_length(route)
	s = clampf(s, 0.0, rl)
	var lo := 0
	var hi := s_arr.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if s_arr[mid] < s:
			lo = mid + 1
		else:
			hi = mid
	var i := maxi(lo, 1)
	var s0: float = s_arr[i - 1]
	var s1: float = s_arr[i]
	var t := 0.0 if s1 <= s0 else (s - s0) / (s1 - s0)
	return [i, t]

func _index_at(s: float) -> int:
	var s_arr: PackedFloat32Array = main["s_arr"]
	var lo := 0
	var hi := s_arr.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if s_arr[mid] < s:
			lo = mid + 1
		else:
			hi = mid
	return lo

func point_at(s: float, route: Dictionary = {}) -> Vector3:
	var rt: Dictionary = route if not route.is_empty() else main
	var pts: PackedVector3Array = rt["pts"]
	if pts.size() == 0:
		return Vector3.ZERO
	var w := _window(s, rt)
	return pts[w[0] - 1].lerp(pts[w[0]], w[1])

func tangent_at(s: float, route: Dictionary = {}) -> Vector3:
	var rt: Dictionary = route if not route.is_empty() else main
	var tans: PackedVector3Array = rt["tans"]
	if tans.size() == 0:
		return Vector3(0.0, 0.0, -1.0)
	var w := _window(s, rt)
	return tans[w[0] - 1].lerp(tans[w[0]], w[1]).normalized()

func normal_at(s: float, route: Dictionary = {}) -> Vector3:
	return _flat_normal(tangent_at(s, route))

func width_at(s: float, route: Dictionary = {}) -> float:
	var rt: Dictionary = route if not route.is_empty() else main
	var widths: PackedFloat32Array = rt["widths"]
	if widths.size() == 0:
		return 24.0
	var w := _window(s, rt)
	return lerpf(widths[w[0] - 1], widths[w[0]], w[1])

## AI 限速:窗口内最小曲率半径 → 目标速度(≈ sqrt(μgR),μ≈1.2)
func corner_speed(s_from: float, span: float) -> float:
	var radii: PackedFloat32Array = main["radii"]
	if radii.size() == 0:
		return 55.0
	var min_r := 9999.0
	var start := _index_at(clampf(s_from, 0.0, length))
	var end := mini(radii.size(), start + int(span / 2.0) + 1)
	for i in range(start, end):
		min_r = minf(min_r, radii[i])
	return clampf(sqrt(11.8 * min_r), 11.0, 55.0)

## ---------------- 发车网格(与编辑器 gridSlots 同公式) ----------------

func grid_position(grid_no: int) -> Vector3:
	var p0: Vector3 = main["pts"][0]
	var t0 := _flat_tangent(main["tans"][0])
	var n0 := Vector3(t0.z, 0.0, -t0.x)
	var row := (grid_no - 1) / 2
	var side := -1.0 if grid_no % 2 == 1 else 1.0
	var back: float = float(grid_cfg.get("first_row_offset", 6.0)) + float(row) * float(grid_cfg.get("row_gap", 8.0))
	return p0 - t0 * back + n0 * (side * float(grid_cfg.get("col_gap", 7.0)) * 0.5)

## 车头朝向(弧度,绕 y):节点 -Z 对齐起点切线
func grid_heading(_grid_no: int) -> float:
	var t: Vector3 = main["tans"][0]
	return atan2(-t.x, -t.z)

## AI 车道:相对中心线横向偏移(单号左、双号右)
func grid_lane(grid_no: int) -> float:
	var side := -1.0 if grid_no % 2 == 1 else 1.0
	return side * float(grid_cfg.get("col_gap", 7.0)) * 0.5

## ---------------- 掉落 / 辅助 ----------------

## 主路掉落点:均匀铺开 + 沿途抖动(替代直线版 main_route_points)
func main_route_points(count: int) -> Array:
	var out: Array = []
	for i in count:
		var t := (float(i) + 0.5) / float(count)
		var s := lerpf(length * 0.12, length * 0.95, t) + randf_range(-8.0, 8.0)
		var lateral := randf_range(-0.35, 0.35) * width_at(s)
		out.append(point_at(s) + normal_at(s) * lateral + Vector3(0, LOOT_Y, 0))
	return out

## 高危分支掉落点:每条 Dirt 分支 3 点;无分支时主路尾部兜底
func hazard_route_points() -> Array:
	var out: Array = []
	for route in routes:
		if String(route["surface"]) != "dirt":
			continue
		var rl := route_length(route)
		for frac in [0.3, 0.55, 0.8]:
			var s := rl * float(frac)
			out.append(point_at(s, route) + normal_at(s, route) * randf_range(-2.0, 2.0) + Vector3(0, LOOT_Y, 0))
	if out.is_empty():
		for frac in [0.6, 0.75, 0.9]:
			out.append(point_at(length * float(frac)) + Vector3(0, LOOT_Y, 0))
	return out

## 前方 dist 米处的路面点(debug_spawn_loot_ahead 用)
func point_ahead(pos: Vector3, dist: float) -> Vector3:
	var idx := nearest_index(pos, -1)
	var s_arr: PackedFloat32Array = main["s_arr"]
	return point_at(s_arr[idx] + dist) + Vector3(0, LOOT_Y, 0)

## 跌落保护:投影回中心线最近点上方
func reset_point(pos: Vector3) -> Vector3:
	var idx := nearest_index(pos, -1)
	var pts: PackedVector3Array = main["pts"]
	return pts[idx] + Vector3(0, 1.2, 0)

func start_point() -> Vector3:
	return main["pts"][0]

func finish_point() -> Vector3:
	var pts: PackedVector3Array = main["pts"]
	return pts[pts.size() - 1]

func finish_tangent() -> Vector3:
	return _flat_tangent(main["tans"][main["tans"].size() - 1])
