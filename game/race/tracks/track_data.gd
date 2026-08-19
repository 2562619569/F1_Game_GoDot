class_name TrackData
extends RefCounted
## HTML 赛道编辑器(tools/track_editor/index.html)导出 JSON 的运行时数据 + 几何查询。
## baked 采样点为紧凑数组 [x,y,z, width](每点 4 元素,编辑器烘焙);切线、弧长、
## 曲率半径由 Godot 加载时按编辑器同公式重建,保证所见即所得。
## 坐标系与编辑器一致:x 右,z 向前(-z 为起始前进方向),y 高度。

const LOOT_Y := 0.9        # 掉落物悬浮高度(路面之上)
const LOOKAHEAD_VSHIFT := 0.55  # AI 前瞻时间(秒)对应距离系数

var meta := {"id": 0, "name": ""}
var grid_cfg := {"count": 8, "row_gap": 8.0, "col_gap": 7.0, "first_row_offset": 6.0}
var options := {"walls": true, "wall_height": 0.8, "barrier_offset": 8.0, "gravel_width": 8.0, "sample_step": 2}
var routes: Array = []   # [{id, surface, pts, tans, widths, s_arr, radii}]
var main: Dictionary = {}
var length := 0.0
## 检查点弧长序列(R 倒转复位目标):首点=起点线,间隔来自 Game 表
## checkpoint_interval,build_checkpoints 按 RaceManager 注入的间隔生成
var checkpoints := PackedFloat32Array()
## 起点线采样索引:编辑器烘焙时主路前插了发车引道(发车网格要落在铺装上),
## 真正的起点线在 grid.anchor_s 处,发车位/起点柱/AI 车道都锚定在那里。
var start_idx := 0

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
			route["widths"].append(a[3])
		if route["pts"].size() < 2:
			continue
		_compute_tans_s(route)
		_compute_radii(route)
		routes.append(route)
		if route["surface"] == "road":
			main = route
	var s_arr: PackedFloat32Array = main.get("s_arr", PackedFloat32Array())
	if s_arr.size() > 0:
		length = s_arr[s_arr.size() - 1]
	# 起点线锚点:吸附到 s 最接近 anchor_s 的采样(旧图无 anchor_s 时留在 0)
	var anchor: float = float(grid_cfg.get("anchor_s", 0.0))
	while start_idx + 1 < s_arr.size() \
			and absf(s_arr[start_idx + 1] - anchor) < absf(s_arr[start_idx] - anchor):
		start_idx += 1

## 切线(中心差分,与编辑器 bakeRoute 同公式)+ 逐点弧长累加
func _compute_tans_s(route: Dictionary) -> void:
	var pts: PackedVector3Array = route["pts"]
	var n := pts.size()
	var tans := PackedVector3Array()
	var s_arr := PackedFloat32Array()
	tans.resize(n)
	s_arr.resize(n)
	for i in n:
		var a := pts[maxi(i - 1, 0)]
		var b := pts[mini(i + 1, n - 1)]
		var d := b - a
		var L := d.length()
		tans[i] = d / L if L > 1e-4 else Vector3(0.0, 0.0, -1.0)
		s_arr[i] = 0.0 if i == 0 else s_arr[i - 1] + pts[i - 1].distance_to(pts[i])
	route["tans"] = tans
	route["s_arr"] = s_arr

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
		# cross is twice the triangle area; circumradius = abc / (4A).
		radii[i] = minf(9999.0, la * lb * lc / (2.0 * absf(cross)))
	route["radii"] = radii

## ---------------- 曲率退距场(赛道面/护栏/路缘共用几何核心) ----------------
## 偏移曲线理论:中心线曲率 κ 处按距离 d 做法线偏移,内侧 d·κ ≥ 1 时偏移线
## 越过渐屈线(evolute)发生折返(领结四边形);此外 d 的变化率 |Δd| > |Δs| 时
## 内缘沿轨道方向的行进速度超过中心线,同样折返。两个条件合成一个充分约束:
## d(s) ≤ A(s) 且 A 满足 Lipschitz 斜率 ≤1——即"允许退距场"。
## 锥形腐蚀(1-D 距离变换的双向 min 传播)恰好给出满足该约束的最大场:
## A(s) = min_j (raw(j) + |s - j|),O(n) 两趟扫描,天然左右对称。

## 任意逐采样标量场的锥形腐蚀 + 软化:
## 1) 双向 min 传播(|Δ| ≤ Δs)——斜率 ≤1 的最大保形变换;
## 2) ±soft_m 弧长三角窗加权平均(软化 45° 坡肩折角),再与原场取 min(只软不升,
##    软化永不越过原始上限,安全约束不破);
## 3) 再补一次 min 传播:min(软化值, 原值) 在窗边缘理论上可产生斜率 >1 的段,
##    重传播将其剪平,最终返回值严格满足 Lipschitz 斜率 ≤1。
static func cone_smooth(field: PackedFloat32Array, s_arr: PackedFloat32Array, \
		soft_m := 4.0) -> PackedFloat32Array:
	var n := field.size()
	var out := field.duplicate()
	for i in range(1, n):
		out[i] = minf(out[i], out[i - 1] + (float(s_arr[i]) - float(s_arr[i - 1])))
	for i in range(n - 2, -1, -1):
		out[i] = minf(out[i], out[i + 1] + (float(s_arr[i + 1]) - float(s_arr[i])))
	if soft_m <= 0.0 or n < 3:
		return out
	var span := float(s_arr[n - 1] - s_arr[0])
	var step := span / float(n - 1) if n > 1 else 1.0
	var win := maxi(1, int(ceilf(soft_m / maxf(step, 0.25))))
	var soft := PackedFloat32Array()
	soft.resize(n)
	for i in n:
		var acc := 0.0
		var wsum := 0.0
		for k in range(maxi(i - win, 0), mini(i + win + 1, n)):
			var d := absf(float(s_arr[k]) - float(s_arr[i]))
			if d > soft_m:
				continue
			var w := 1.0 - d / soft_m
			acc += float(out[k]) * w
			wsum += w
		soft[i] = minf(acc / wsum if wsum > 0.0 else float(out[i]), float(out[i]))
	for i in range(1, n):
		soft[i] = minf(soft[i], soft[i - 1] + (float(s_arr[i]) - float(s_arr[i - 1])))
	for i in range(n - 2, -1, -1):
		soft[i] = minf(soft[i], soft[i + 1] + (float(s_arr[i + 1]) - float(s_arr[i])))
	return soft

## 曲率半径 → 允许退距场:raw = max(R - margin, 0),再锥形腐蚀 + 软化。
## margin 是弯心保留半径(路缘 ROAD_INNER_RADIUS / 护栏 BARRIER_INNER_RADIUS)。
static func allowance_field(radii: PackedFloat32Array, s_arr: PackedFloat32Array, \
		margin: float, soft_m := 4.0) -> PackedFloat32Array:
	var n := radii.size()
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		raw[i] = maxf(float(radii[i]) - margin, 0.0)
	return cone_smooth(raw, s_arr, soft_m)

## 任意点相对主路的横向信息(辅路岔口融合/护栏开缺等均用它),字段见 route_lateral
func main_lateral(pos: Vector3) -> Dictionary:
	return route_lateral(main, pos)

## 任意点相对某条路由的横向信息(xz 投影到最近段求精确垂距)。
## 返回 {dist: 到中心线垂距(非负), half: 垂足处半宽, road_y: 垂足处路面高度,
##       s: 垂足弧长, foot: 垂足坐标}。辅路岔口融合(TrackBuilder)用。
func route_lateral(route: Dictionary, pos: Vector3) -> Dictionary:
	var pts: PackedVector3Array = route["pts"]
	var n := pts.size()
	if n == 0:
		return {"dist": 1e9, "half": 12.0, "road_y": 0.0, "s": 0.0, "foot": Vector3.ZERO}
	var widths: PackedFloat32Array = route["widths"]
	var s_arr: PackedFloat32Array = route["s_arr"]
	var idx := nearest_index(pos, -1, route)
	var best_d := 1e18
	var best_a := idx
	var best_b := idx
	var best_t := 0.0
	for i in range(maxi(idx - 1, 0), mini(idx + 1, n - 2) + 1):
		var pa := pts[i]
		var ab := Vector2(pts[i + 1].x - pa.x, pts[i + 1].z - pa.z)
		var L2 := ab.length_squared()
		if L2 < 1e-8:
			continue
		var t := clampf(Vector2(pos.x - pa.x, pos.z - pa.z).dot(ab) / L2, 0.0, 1.0)
		var proj := Vector2(pa.x, pa.z) + ab * t
		var d := proj.distance_to(Vector2(pos.x, pos.z))
		if d < best_d:
			best_d = d
			best_a = i
			best_b = i + 1
			best_t = t
	var a := pts[best_a]
	var b := pts[best_b]
	var foot := a.lerp(b, best_t)
	return {
		"dist": best_d,
		"half": lerpf(widths[best_a], widths[best_b], best_t) * 0.5,
		"road_y": lerpf(a.y, b.y, best_t),
		"s": lerpf(s_arr[best_a], s_arr[best_b], best_t),
		"foot": foot,
	}

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

## 逐采样标量场(退距场/有效半宽等)按弧长插值
func field_at(values: PackedFloat32Array, s: float, route: Dictionary = {}) -> float:
	var rt: Dictionary = route if not route.is_empty() else main
	var w := _window(s, rt)
	return lerpf(float(values[w[0] - 1]), float(values[w[0]]), float(w[1]))

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
	var p0: Vector3 = main["pts"][start_idx]
	var t0 := _flat_tangent(main["tans"][start_idx])
	var n0 := Vector3(t0.z, 0.0, -t0.x)
	var row := (grid_no - 1) / 2
	var side := -1.0 if grid_no % 2 == 1 else 1.0
	var back: float = float(grid_cfg.get("first_row_offset", 6.0)) + float(row) * float(grid_cfg.get("row_gap", 8.0))
	return p0 - t0 * back + n0 * (side * float(grid_cfg.get("col_gap", 7.0)) * 0.5)

## 车头朝向(弧度,绕 y):节点 -Z 对齐起点切线
func grid_heading(_grid_no: int) -> float:
	var t: Vector3 = main["tans"][start_idx]
	return atan2(-t.x, -t.z)

## AI 车道:相对中心线横向偏移(单号左、双号右)
func grid_lane(grid_no: int) -> float:
	var side := -1.0 if grid_no % 2 == 1 else 1.0
	return side * float(grid_cfg.get("col_gap", 7.0)) * 0.5

## ---------------- 检查点(R 倒转复位用) ----------------

const CHECKPOINT_DROP_Y := 1.2  # 复位落点在路面之上的悬空量(与 reset_point 一致,落地自沉降)
const CHECKPOINT_TAIL_MARGIN := 10.0  # 距终点不足该值不再生成检查点(冲线前无倒转价值)

## 按配表间隔沿主路生成检查点弧长序列:首点=起点线(start_idx 采样),之后每隔
## interval 米一个,直到终点前 CHECKPOINT_TAIL_MARGIN。地图加载后由 RaceManager
## 注入间隔(Game 表 checkpoint_interval),幂等可重建。
func build_checkpoints(interval: float) -> void:
	checkpoints = PackedFloat32Array()
	if interval <= 0.0 or length <= 0.0:
		return
	var s_arr: PackedFloat32Array = main["s_arr"]
	var s0: float = s_arr[start_idx]
	checkpoints.append(s0)
	var s := s0 + interval
	while s < length - CHECKPOINT_TAIL_MARGIN:
		checkpoints.append(s)
		s += interval

## 检查点复位姿态:{pos: 路面上方悬空点, yaw: 车头朝向弧长切线, s: 弧长}。
## 未生成检查点时返回空 dict,调用方须判空。
func checkpoint_pose(idx: int) -> Dictionary:
	if checkpoints.is_empty():
		return {}
	var i := clampi(idx, 0, checkpoints.size() - 1)
	var s: float = checkpoints[i]
	var t := tangent_at(s)
	return {
		"pos": point_at(s) + Vector3(0, CHECKPOINT_DROP_Y, 0),
		"yaw": atan2(-t.x, -t.z),
		"s": s,
	}

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
	return main["pts"][start_idx]

func finish_point() -> Vector3:
	var pts: PackedVector3Array = main["pts"]
	return pts[pts.size() - 1]

func finish_tangent() -> Vector3:
	return _flat_tangent(main["tans"][main["tans"].size() - 1])
