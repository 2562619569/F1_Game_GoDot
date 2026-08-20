class_name TrackField
extends RefCounted

## 赛道平面符号距离场:路由折线 + 逐段半宽 = 变半径胶囊的并集。
##   F(p) = min_j ( ‖p - seg_j‖ - w_j ) ,F ≤ level 的闭区域即该层的实心带。
## 融并与避让在此表示下是构造性的:
##   - 自邻近(发卡弯两腿)时胶囊自然并成一片——弯心全铺装,不再需要逐截面
##     退距场/远端走廊/弧长排除等补丁(那些都是"逐截面侧向偏移"表示的先天裂缝);
##   - 等值线在两带贴拢的腰部自然合拢——护栏只在并集外围与内场孔洞上走,
##     两腿之间天然无墙;
##   - 一点到路面并集的净距就是场值本身,精确,无需逐截面探测。
## 高程:采样返回最近段的插值 y/s——路面/砂石/护栏的等值线顶点携带真实高度,
## 山坡全场自然跟随起伏;立体交叉(Δy ≥ Y_SEP)在平面场上表现为同一片并集
## (两腿贴近即融并),桥面下方由护栏碰撞墙的压顶逻辑留净空,不在场内分层。
##
## 两级结构:
##   1. 段空间网格(SEG_CELL):sample(p) 任意点的 F/y/s;
##   2. 值点阵(lattice):band 内角点求值一次,contours(level) 提取等值线环。

const SEG_CELL := 8.0    # 段空间网格:越小单格候选段越少(查询内循环越短),
                          # 标记半径由 reach+max_w+2 保证单格查询完备
const SEG_INV := 1.0 / SEG_CELL
const BIG := 1e6

var _sa := PackedVector2Array()   # 段端点 a(x,z)
var _sb := PackedVector2Array()
var _swa := PackedFloat32Array()  # 端点半宽
var _swb := PackedFloat32Array()
var _sya := PackedFloat32Array()  # 端点路面高度
var _syb := PackedFloat32Array()
var _sss := PackedFloat32Array()  # 段中点弧长
var _grid: Dictionary = {}        # Vector2i → PackedInt32Array(段索引)
var _max_w := 0.0
var _reach := 0.0                 # 建点阵时的查询层上限(标记半径由此推导)

# --- 值点阵(band 内角点缓存) ---
var _lat_cell := 1.0
var _lat_ox := 0.0
var _lat_oz := 0.0
var _lat_nx := 0
var _lat_nz := 0
var _lat_f := PackedFloat32Array()
var _lat_y := PackedFloat32Array()
var _lat_s := PackedFloat32Array()
var _lat_on := PackedByteArray()
var _cell_on := PackedByteArray()
var _active_cells := PackedInt32Array()  # band 内格子(等值线扫描只走这些)
var _loops_cache := {}          # level → surface_loops 结果(同层多处使用零重算)
var _force_mark := PackedInt32Array()  # adopt 重扫去重戳记(角点一轮只算一次)
var _force_tick := 0
var _q_f := 0.0                 # sample_set 输出(免字典分配,热路径用)
var _q_y := 0.0
var _q_s := 0.0

## 加入一条路由(pts/widths/s_arr 与 TrackData 同构)。add 完成后统一 build_lattice。
func add_route(route: Dictionary) -> void:
	var pts: PackedVector3Array = route["pts"]
	var ws: PackedFloat32Array = route["widths"]
	var ss: PackedFloat32Array = route["s_arr"]
	for i in pts.size() - 1:
		_sa.append(Vector2(pts[i].x, pts[i].z))
		_sb.append(Vector2(pts[i + 1].x, pts[i + 1].z))
		_swa.append(ws[i] * 0.5)
		_swb.append(ws[i + 1] * 0.5)
		_sya.append(pts[i].y)
		_syb.append(pts[i + 1].y)
		_sss.append((ss[i] + ss[i + 1]) * 0.5)
		_max_w = maxf(_max_w, maxf(ws[i], ws[i + 1]) * 0.5)

func _index(reach: float) -> void:
	_grid = {}
	_reach = reach
	var mark := reach + _max_w + 2.0
	for j in _sa.size():
		var x0 := minf(_sa[j].x, _sb[j].x) - mark
		var x1 := maxf(_sa[j].x, _sb[j].x) + mark
		var z0 := minf(_sa[j].y, _sb[j].y) - mark
		var z1 := maxf(_sa[j].y, _sb[j].y) + mark
		var c0 := Vector2i(int(floor(x0 / SEG_CELL)), int(floor(z0 / SEG_CELL)))
		var c1 := Vector2i(int(floor(x1 / SEG_CELL)), int(floor(z1 / SEG_CELL)))
		for gx in range(c0.x, c1.x + 1):
			for gz in range(c0.y, c1.y + 1):
				var key := Vector2i(gx, gz)
				if not _grid.has(key):
					_grid[key] = PackedInt32Array()
				_grid[key].append(j)

## 任意点采样:{f: 到路面并集的符号距离(负=路面内), y: 最近处路面高度, s: 弧长}
## 热路径用 sample_set(成员变量输出,免每次字典分配)
func sample_set(x: float, z: float) -> void:
	var segs: PackedInt32Array = _grid.get(Vector2i(int(floorf(x / SEG_CELL)), int(floorf(z / SEG_CELL))), PackedInt32Array())
	var best_f := BIG
	var best_y := 0.0
	var best_s := 0.0
	var qx := x
	var qz := z
	for j in segs:
		var a := _sa[j]
		var ab := _sb[j] - a
		var L2 := ab.length_squared()
		var t := 0.5 if L2 < 1e-9 else clampf((qx - a.x) * ab.x + (qz - a.y) * ab.y, 0.0, L2) / L2
		var dx := a.x + ab.x * t - qx
		var dz := a.y + ab.y * t - qz
		var f := sqrt(dx * dx + dz * dz) - lerpf(_swa[j], _swb[j], t)
		if f < best_f:
			best_f = f
			best_y = lerpf(_sya[j], _syb[j], t)
			best_s = _sss[j]
	_q_f = best_f
	_q_y = best_y
	_q_s = best_s

func sample(x: float, z: float) -> Dictionary:
	sample_set(x, z)
	return {"f": _q_f, "y": _q_y, "s": _q_s}

func f_only(x: float, z: float) -> float:
	sample_set(x, z)
	return _q_f

## 上方路面的碰撞压顶:查询点上方 ≥ y_sep 且横向贴近(lateral 内)的最低路面高度;
## 无则 1e9。护栏碰撞墙顶 = 该值 - clearance(桥下留净空)
func overhead_cap(x: float, z: float, y_base: float, y_sep: float, lateral: float) -> float:
	var cap := 1e9
	var segs: PackedInt32Array = _grid.get(Vector2i(int(floor(x / SEG_CELL)), int(floor(z / SEG_CELL))), PackedInt32Array())
	var q := Vector2(x, z)
	for j in segs:
		var my := (_sya[j] + _syb[j]) * 0.5
		if my < y_base + y_sep:
			continue
		var a := _sa[j]
		var ab := _sb[j] - a
		var L2 := ab.length_squared()
		var t := 0.5 if L2 < 1e-9 else clampf((q - a).dot(ab) / L2, 0.0, 1.0)
		if (a + ab * t).distance_to(q) - lerpf(_swa[j], _swb[j], t) < lateral:
			cap = minf(cap, my)
	return cap

## 值点阵:格距 cell,band = 距任一段 reach + max_w + 2。band 外角点值恒为 BIG
## (等值线 ≤ reach,距 band 边 ≥ 2 格,环必闭合)
func build_lattice(cell: float, reach: float) -> void:
	_index(reach)
	_lat_cell = cell
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for key: Vector2i in _grid:
		lo = lo.min(Vector2(key.x, key.y) * SEG_CELL)
		hi = hi.max(Vector2(key.x + 1, key.y + 1) * SEG_CELL)
	_lat_ox = floorf(lo.x / cell) * cell
	_lat_oz = floorf(lo.y / cell) * cell
	_lat_nx = int(ceilf((hi.x - _lat_ox) / cell)) + 2
	_lat_nz = int(ceilf((hi.y - _lat_oz) / cell)) + 2
	var total := _lat_nx * _lat_nz
	_lat_f = PackedFloat32Array()
	_lat_f.resize(total)
	_lat_f.fill(BIG)
	_lat_y = PackedFloat32Array()
	_lat_y.resize(total)
	_lat_s = PackedFloat32Array()
	_lat_s.resize(total)
	_lat_on = PackedByteArray()
	_lat_on.resize(total)
	_cell_on = PackedByteArray()
	_cell_on.resize(total)
	_active_cells = PackedInt32Array()
	_mark_range(0, _sa.size() - 1, cell, reach + _max_w + 2.0, false, true)

## 超段步进标记:相邻段(采样间距 2m)的 band 框重叠 ~95%,逐段在 1m 点阵上
## 标记全是重复扫描;~10 段并一个超段,取端点包络 ±band 一次展开,
## 总迭代与标记面积降一个数量级(包络对弯曲链路略宽,角点求值只多 ~15%)。
## 两阶段:标记+收集待求值角点(单线程,轻),角点求值分块并行(独立索引写入,
## 数组不 resize 时多线程按下标写是安全的;_grid 只读)。
## force=true 时角点强制重求值(adopt 叠加新段用,量小走单线程)
func _mark_range(j_first: int, j_last: int, cell: float, band: float, force: bool, parallel := false) -> void:
	var stride := 10
	var nx := _lat_nx
	var pending := PackedInt32Array()
	var j0 := j_first
	while j0 <= j_last:
		var jn := mini(j0 + stride, j_last)
		var x0 := _sa[j0].x
		var x1 := _sb[j0].x
		var z0 := _sa[j0].y
		var z1 := _sb[j0].y
		for j in range(j0, jn + 1):
			x0 = minf(x0, minf(_sa[j].x, _sb[j].x))
			x1 = maxf(x1, maxf(_sa[j].x, _sb[j].x))
			z0 = minf(z0, minf(_sa[j].y, _sb[j].y))
			z1 = maxf(z1, maxf(_sa[j].y, _sb[j].y))
		var i0 := maxi(0, int(floorf((x0 - band - _lat_ox) / cell)))
		var i1 := mini(nx - 2, int(ceilf((x1 + band - _lat_ox) / cell)))
		var k0 := maxi(0, int(floorf((z0 - band - _lat_oz) / cell)))
		var k1 := mini(_lat_nz - 2, int(ceilf((z1 + band - _lat_oz) / cell)))
		for iz in range(k0, k1 + 1):
			var row := iz * nx
			for ix in range(i0, i1 + 1):
				var ci := row + ix
				if _cell_on[ci] == 0:
					_cell_on[ci] = 1
					_active_cells.append(ci)
				if force:
					_eval_corner_force(ci)
					_eval_corner_force(ci + 1)
					_eval_corner_force(ci + nx)
					_eval_corner_force(ci + nx + 1)
				else:
					if _lat_on[ci] != 2:
						_lat_on[ci] = 2
						pending.append(ci)
					var c1i := ci + 1
					if _lat_on[c1i] != 2:
						_lat_on[c1i] = 2
						pending.append(c1i)
					var c3i := ci + nx
					if _lat_on[c3i] != 2:
						_lat_on[c3i] = 2
						pending.append(c3i)
					var c2i := c3i + 1
					if _lat_on[c2i] != 2:
						_lat_on[c2i] = 2
						pending.append(c2i)
		j0 = jn + 1
	if pending.is_empty():
		return
	if parallel and pending.size() > 8192:
		var n_chunks := clampi(int(ceilf(pending.size() / 2048.0)), 2, 64)
		var group := WorkerThreadPool.add_group_task(func(tid: int) -> void:
			var per := int(ceilf(pending.size() / float(n_chunks)))
			var lo := tid * per
			var hi := mini(lo + per, pending.size())
			for k in range(lo, hi):
				_corner_eval_threaded(pending[k])
		, n_chunks, -1, true, "track_field lattice eval")
		WorkerThreadPool.wait_for_group_task_completion(group)
	else:
		for ci in pending:
			_corner_eval_threaded(ci)

## 角点求值(线程安全):只读 _grid,按下标写 _lat_*;不碰 sample_set 的成员输出
func _corner_eval_threaded(ci: int) -> void:
	var x := _lat_ox + (ci % _lat_nx) * _lat_cell
	var z := _lat_oz + floori(ci / float(_lat_nx)) * _lat_cell
	var segs: PackedInt32Array = _grid.get(Vector2i(floori(x * SEG_INV), floori(z * SEG_INV)), PackedInt32Array())
	var best_f := BIG
	var best_y := 0.0
	var best_s := 0.0
	for j in segs:
		var a := _sa[j]
		var abx := _sb[j].x - a.x
		var abz := _sb[j].y - a.y
		var L2 := abx * abx + abz * abz
		var t := 0.5 if L2 < 1e-9 else clampf((x - a.x) * abx + (z - a.y) * abz, 0.0, L2) / L2
		var dx := a.x + abx * t - x
		var dz := a.y + abz * t - z
		var f := sqrt(dx * dx + dz * dz) - _swa[j] + (_swb[j] - _swa[j]) * t
		if f < best_f:
			best_f = f
			best_y = _sya[j] + (_syb[j] - _sya[j]) * t
			best_s = _sss[j]
	_lat_f[ci] = best_f
	_lat_y[ci] = best_y
	_lat_s[ci] = best_s
	_lat_on[ci] = 1

## 复用 base 场的点阵,只对 added_from 之后新增的段重扫 band:
## 拷贝 base 的角点值/活动格(角点级数组的 memcpy),新增段 band 内角点
## 强制重求值(本场空间索引含全部段,求值天然含新段)——
## 全量点阵是构建的大头,主路+分支场省掉一整份
func adopt_lattice(base: TrackField, added_from: int, cell: float, reach: float) -> void:
	_index(reach)
	_lat_cell = base._lat_cell
	_lat_ox = base._lat_ox
	_lat_oz = base._lat_oz
	_lat_nx = base._lat_nx
	_lat_nz = base._lat_nz
	_reach = reach
	_lat_f = base._lat_f.duplicate()
	_lat_y = base._lat_y.duplicate()
	_lat_s = base._lat_s.duplicate()
	_lat_on = base._lat_on.duplicate()
	_cell_on = base._cell_on.duplicate()
	_active_cells = base._active_cells.duplicate()
	_force_tick = 1
	if _force_mark.size() != _lat_nx * _lat_nz:
		_force_mark = PackedInt32Array()
		_force_mark.resize(_lat_nx * _lat_nz)
	_mark_range(added_from, _sa.size() - 1, cell, reach + _max_w + 2.0, true)

func seg_count() -> int:
	return _sa.size()

func _eval_corner_force(ci: int) -> void:
	if _force_mark[ci] == _force_tick:
		return
	_force_mark[ci] = _force_tick
	_corner_eval_threaded(ci)

## marching squares 提取 level 等值线,缝合成闭合环(PackedVector2Array 列表)。
## 鞍点(case 5/10)用四角均值消歧。环方向一致(外环/内环旋向相反),旋向语义
## 由调用方按需使用;此处只保证几何正确
func contours(level: float) -> Array:
	var base_h := _lat_nx * _lat_nz
	var cross: Dictionary = {}     # edge_key → Vector2 交点
	var adj: Dictionary = {}       # edge_key → PackedInt32Array(邻接 edge_key)
	var link := func(ea: int, eb: int, pa: Vector2, pb: Vector2) -> void:
		if not cross.has(ea):
			cross[ea] = pa
		if not cross.has(eb):
			cross[eb] = pb
		if not adj.has(ea):
			adj[ea] = PackedInt32Array()
		adj[ea].append(eb)
		if not adj.has(eb):
			adj[eb] = PackedInt32Array()
		adj[eb].append(ea)
	# 只扫活动格(band 内,build_lattice 已收集);角点值读取内联(函数调用开销可观)
	var cell_sz := _lat_cell
	var ox := _lat_ox
	var oz := _lat_oz
	var cross_pt := func(va: float, pb_x: float, pb_z: float, ax: float, az: float, vb: float) -> Vector2:
		var d := vb - va
		var t := 0.5 if absf(d) < 1e-9 else clampf(-va / d, 0.0, 1.0)
		return Vector2(ax + (pb_x - ax) * t, az + (pb_z - az) * t)
	for c0_raw in _active_cells:
		var c0: int = c0_raw
		var c1 := c0 + 1
		var c3 := c0 + _lat_nx
		var c2 := c3 + 1
		var v0 := (_lat_f[c0] if _lat_on[c0] == 1 else BIG) - level
		var v1 := (_lat_f[c1] if _lat_on[c1] == 1 else BIG) - level
		var v2 := (_lat_f[c2] if _lat_on[c2] == 1 else BIG) - level
		var v3 := (_lat_f[c3] if _lat_on[c3] == 1 else BIG) - level
		var b := 0
		if v0 < 0.0: b += 1
		if v1 < 0.0: b += 2
		if v2 < 0.0: b += 4
		if v3 < 0.0: b += 8
		if b == 0 or b == 15:
			continue
		var ix := c0 % _lat_nx
		var iz := int((c0 - ix) / float(_lat_nx))
		var e0 := c0                       # 底边 key = h(ix,iz)
		var e1 := base_h + c1              # 右边 key = v(ix+1,iz)
		var e2 := c3                       # 顶边 key = h(ix,iz+1)
		var e3 := base_h + c0              # 左边 key = v(ix,iz)
		var px := ox + ix * cell_sz
		var pz := oz + iz * cell_sz
		var pe0: Vector2 = cross_pt.call(v0, px + cell_sz, pz, px, pz, v1)
		var pe1: Vector2 = cross_pt.call(v1, px + cell_sz, pz + cell_sz, px + cell_sz, pz, v2)
		var pe2: Vector2 = cross_pt.call(v3, px + cell_sz, pz + cell_sz, px, pz + cell_sz, v2)
		var pe3: Vector2 = cross_pt.call(v0, px, pz + cell_sz, px, pz, v3)
		match b:
			1, 14: link.call(e3, e0, pe3, pe0)
			2, 13: link.call(e0, e1, pe0, pe1)
			3, 12: link.call(e3, e1, pe3, pe1)
			4, 11: link.call(e1, e2, pe1, pe2)
			6, 9: link.call(e0, e2, pe0, pe2)
			7, 8: link.call(e3, e2, pe3, pe2)
			5:
				# 鞍点:c0/c2 在内 vs c1/c3 在内,按四角均值选配对
				var center := (v0 + v1 + v2 + v3) * 0.25
				if center < 0.0:
					link.call(e3, e0, pe3, pe0)
					link.call(e1, e2, pe1, pe2)
				else:
					link.call(e0, e1, pe0, pe1)
					link.call(e3, e2, pe3, pe2)
			10:
				var center10 := (v0 + v1 + v2 + v3) * 0.25
				if center10 < 0.0:
					link.call(e0, e1, pe0, pe1)
					link.call(e3, e2, pe3, pe2)
				else:
					link.call(e3, e0, pe3, pe0)
					link.call(e1, e2, pe1, pe2)
	# 缝合:从未用交点出发沿邻接走环
	var used: Dictionary = {}
	var loops: Array = []
	for ekey: int in cross:
		if used.has(ekey):
			continue
		var pts := PackedVector2Array()
		var cur := ekey
		while not used.has(cur):
			used[cur] = true
			pts.append(cross[cur])
			var nb: PackedInt32Array = adj.get(cur, PackedInt32Array())
			var nxt := -1
			for cand in nb:
				if not used.has(cand):
					nxt = cand
					break
			if nxt < 0:
				break
			cur = nxt
		if pts.size() >= 3:
			loops.append(pts)
	return loops

## level 层的实心带环集合,标注外环/内环(草地岛):嵌套深度奇偶判定。
## 同层结果缓存(路面/砂石多处共用同层等值线)
func surface_loops(level: float) -> Array:
	if _loops_cache.has(level):
		return _loops_cache[level]
	var loops := contours(level)
	var out: Array = []
	for L in loops:
		var depth := 0
		var probe: Vector2 = (L[0] + L[L.size() / 2]) * 0.5
		for L2 in loops:
			if L2 == L:
				continue
			if point_in_polygon(probe, L2):
				depth += 1
		out.append({"pts": L, "hole": depth % 2 == 1})
	_loops_cache[level] = out
	return out

static func point_in_polygon(q: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi := poly[i]
		var pj := poly[j]
		if (pi.y > q.y) != (pj.y > q.y) \
				and q.x < (pj.x - pi.x) * (q.y - pi.y) / (pj.y - pi.y) + pi.x:
			inside = not inside
		j = i
	return inside
