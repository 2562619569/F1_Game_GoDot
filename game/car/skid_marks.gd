class_name SkidMarks
extends Node
## 极限工况车轮印（装配型组件，挂在 Vehicle 名下，玩家/AI/NPC 通用）。
## 触发直接读各轮滑移量（Wheel 每物理帧已算好，本组件零物理改动）：
## - slip_vector.x 侧滑角（漂移/甩尾的横向滑动）
## - slip_vector.y 纵滑率（刹车抱死为正、烧胎打滑为大负）
## 任一超过配表阈值即在轮触点沿接触路径铺一段贴地面片：
## 世界空间 MultiMesh 环形缓冲（挂车位父节点，不随车体物理移动），
## 宽度=胎宽、沿表面法线抬高防 z-fight；强度按超出阈值倍数映射，
## 出生时刻/强度/淡出时长写进实例 custom data，由 skid_mark.gdshader 按 u_time
## 差值淡出——淡出全程不回写实例缓冲，环形池用尽后覆写最旧段。
## 淡出时长按落段速率自适应（见 _update_fade_cap）：保证段被覆写前必然淡完，
## 回绕不闪断；面片不写深度（shader depth_draw_never），段接缝楔形重叠与
## 画圈/变道车辙交叉只稳定叠色、不逐帧争深度闪烁。
## 未超阈值即断笔：ABS 脉冲式抱死留下断续印，持续滑动连成实线；
## 表面区分浓淡（Road 全浓、土/砂石减淡、草地不留印）。
## 参数由 race_builder 从 Game 表 skid_* 注入；缺省与表内默认一致，自检可直接注入。

const SKID_SHADER := preload("res://game/car/shaders/skid_mark.gdshader")

const DEFAULT_LAT_SLIP := 0.20  # 侧滑角阈值（rad ≈11.5°：正常过弯 3~8° 不触发）
const DEFAULT_LON_SLIP := 0.20  # 纵滑率阈值（抱死→|v|/(1+|v|)≈0.8+；巡航滚动 ≈0.02）
const DEFAULT_LIFETIME := 25.0  # 车轮印淡出时长上限（s）：实际每段按落段速率自适应
const DEFAULT_ALPHA := 0.75     # 满强度不透明度
const DEFAULT_GAP := 0.35       # 最小分段长（m）：触点移动超过该距离才铺新段
const DEFAULT_POOL := 4096      # 环形缓冲段数（四轮共享）：四轮同滑 ≈358m / 单轮 1.4km

const MAX_SEG := 2.5            # 段长上限（m）：腾空/传送/倒转复位视为断笔，不连接
const LIFT := 0.05              # 沿表面法线抬高（m）：须高于路面标线层(MARKING_LIFT
                                # 0.04)，车印压过标线可见；防与路面 z-fight
const INTENSITY_MIN := 0.5      # 刚过阈值的基准浓度（再按超出倍数升到 1.0）
const INTENSITY_GAIN := 0.5     # 超出阈值每 1 倍增加的浓度（1.5×阈值即满浓）
const MIN_FADE := 2.0           # 自适应淡出时长下限（s）：池再紧张也保底可见
const RATE_MARGIN := 1.3        # 落段速率估计余量倍数：速率突增时防覆写未淡完的段
const RATE_FLOOR := 8.0         # 速率估计保底（段/s）：间歇落段时不过早收缩时长
const RATE_TAU := 0.5           # 速率 EMA 时间常数（s）
const PEAK_HALF_LIFE := 2.0     # 峰值速率半衰期（s）：估计升快降慢，盖住突发滑移
const SURFACE_TINT := {"Road": 1.0, "Dirt": 0.65, "Gravel": 0.6, "Grass": 0.0}
## 测试观测：开启后每次落段记录 {wheel, p0, p1, t, intensity}（上限 4096 条）
const DEBUG_LOG_MAX := 4096

var lat_slip := DEFAULT_LAT_SLIP
var lon_slip := DEFAULT_LON_SLIP
var lifetime := DEFAULT_LIFETIME
var alpha := DEFAULT_ALPHA
var gap := DEFAULT_GAP
var pool := DEFAULT_POOL

var track_emissions := false     # 自检用：记录每次落段（见 emissions）
var emissions: Array[Dictionary] = []

var _v: Vehicle
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _elapsed := 0.0             # 组件时钟：出生时刻与 shader u_time 同源
var _cursor := 0                # 环形缓冲写指针
var _written := 0               # 累计落段数（测试观测；> pool 即发生过回绕）
var _states: Array[Dictionary] = []
var _seg_accum := 0             # 本渲染帧落段数（喂速率 EMA）
var _rate := 0.0                # 落段速率 EMA（段/s）
var _rate_peak := 0.0           # 缓降峰值速率（段/s）：估计取 max(EMA, 峰值半衰)
var _fade_cap := DEFAULT_LIFETIME  # 当前新段的淡出时长（s，出生时定格进实例）

## 挂载点约定：Vehicle 必须已在树内（本组件把面片挂到 v 的父节点——
## 回合中的 racer/NPC 根节点是静止的世界锚，车体物理移动不带走胎印）
func setup(v: Vehicle, cfg := {}) -> void:
	_v = v
	lat_slip = float(cfg.get("lat_slip", DEFAULT_LAT_SLIP))
	lon_slip = float(cfg.get("lon_slip", DEFAULT_LON_SLIP))
	lifetime = float(cfg.get("lifetime", DEFAULT_LIFETIME))
	alpha = float(cfg.get("alpha", DEFAULT_ALPHA))
	gap = float(cfg.get("gap", DEFAULT_GAP))
	pool = maxi(int(cfg.get("pool", DEFAULT_POOL)), 4)
	_build()

func _build() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(1, 1)  # 单位面片，实例变换里按 胎宽×段长 缩放
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = plane
	mm.instance_count = pool
	mm.visible_instance_count = 0
	_mm = mm
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "SkidMarks"
	_mmi.multimesh = mm
	# top_level：忽略父节点变换。挂点是车位父节点（racer/NPC 根），它带发车位
	# 平移与朝向旋转，而实例变换写的是世界坐标——不隔离会被二次变换甩离赛道
	# （测试场景父节点恰为单位变换，headless 数据自检测不出该错位）
	_mmi.top_level = true
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	_mat.shader = SKID_SHADER
	_mat.set_shader_parameter("mark_color", Color(0.05, 0.05, 0.06, 1.0))
	_mat.set_shader_parameter("lifetime", lifetime)
	_mat.set_shader_parameter("peak_alpha", alpha)
	_mmi.material_override = _mat
	# 面片是单位尺寸，按 mesh AABB 剔除会误杀全场铺开的实例，包围盒放大兜底
	_mmi.custom_aabb = AABB(Vector3(-3000, -500, -3000), Vector3(6000, 1000, 6000))
	_v.get_parent().add_child(_mmi)

func _exit_tree() -> void:
	# 面片挂在车位父节点名下（不随车销毁），组件自身退出时须一并回收
	if _mmi:
		_mmi.queue_free()

func _process(delta: float) -> void:
	_elapsed += delta
	if _mat:
		_mat.set_shader_parameter("u_time", _elapsed)
	_update_fade_cap(delta)

## 按落段速率自适应新段淡出时长：环形池回绕周期 = pool/速率，淡出时长必须
## ≤ 回绕周期，段被覆写前才必然已淡到 0（否则最旧段在 ~满浓度时整段消失=闪断）。
## 速率估计升快降慢（EMA + 峰值半衰 × 余量）：覆盖"漂移中速率突增"的场景——
## 估计偏高只是印子淡得快点，估计偏低才会闪断，宁可高估。时长在落段时刻定格
## 进实例 custom data，已落段不随速率回落被"复活"或跳变
func _update_fade_cap(delta: float) -> void:
	if delta > 0.0:
		var inst := float(_seg_accum) / delta
		_rate = lerpf(_rate, inst, clampf(delta / RATE_TAU, 0.0, 1.0))
		_seg_accum = 0
	_rate_peak = maxf(_rate, _rate_peak * pow(0.5, delta / PEAK_HALF_LIFE))
	var est := _rate_peak * RATE_MARGIN + RATE_FLOOR
	_fade_cap = clampf(pool / est, minf(MIN_FADE, lifetime), lifetime)

func _physics_process(_delta: float) -> void:
	if _v == null or _mm == null:
		return
	# 轮组状态懒绑定：vehicle.initialize() 在 _ready 才填 wheel_array，
	# 组件可能挂得比它早（-s 自检里 root 未 ready，_ready 会推迟到首帧）
	if _states.is_empty():
		if _v.wheel_array.is_empty():
			return
		for wheel in _v.wheel_array:
			_states.append({"has": false, "point": Vector3.ZERO})
	for i in _v.wheel_array.size():
		_track_wheel(_v.wheel_array[i], i)

func _track_wheel(w: Wheel, idx: int) -> void:
	var st := _states[idx]
	if not w.is_colliding():
		st.has = false  # 腾空断笔：落地点不与起飞点连段
		return
	var intensity := _intensity(w)
	if intensity <= 0.0:
		st.has = false  # 未超阈值断笔（ABS 脉冲间隙 → 断续印；草地直接无印）
		return
	var p := w.last_collision_point
	if not st.has:
		st.has = true
		st.point = p
		return
	var seg := p.distance_to(st.point)
	if seg < gap:
		return
	if seg > MAX_SEG:
		st.point = p  # 大跳变（传送/倒转复位）只挪笔不画
		return
	_emit(st.point, p, w.last_collision_normal, intensity, idx, w)
	st.point = p

## 滑移强度 → 落印浓度：两向滑移各按阈值归一取大者，超出的倍数线性升浓；
## 表面系数为 0（草地）直接返回 0 不落印
func _intensity(w: Wheel) -> float:
	var lat := absf(w.slip_vector.x) / maxf(lat_slip, 0.001)
	var lon := absf(w.slip_vector.y) / maxf(lon_slip, 0.001)
	var over := maxf(lat, lon) - 1.0
	if over <= 0.0:
		return 0.0
	var surf := float(SURFACE_TINT.get(w.surface_type, 1.0))
	if surf <= 0.0:
		return 0.0
	return clampf(INTENSITY_MIN + over * INTENSITY_GAIN, INTENSITY_MIN, 1.0) * surf

## 在 p0→p1 之间铺一段贴地面片：局部 Z 沿行进方向、Y 沿表面法线，
## X = Y×Z（右手系），原点取段中点沿法线抬 LIFT
func _emit(p0: Vector3, p1: Vector3, normal: Vector3, intensity: float, wheel_idx: int, w: Wheel) -> void:
	var dir := p1 - p0
	var length := dir.length()
	dir /= length
	var up := normal.normalized()
	var side := up.cross(dir)
	if side.length_squared() < 0.000001:
		return  # 法线与行进方向共线（贴墙滑），基退化，跳过该段
	var basis := Basis(side, up, dir).orthonormalized()
	var width := 0.22  # 探针直写时的缺省胎宽（正常路径由 w.tire_width 提供）
	if w:
		width = clampf(w.tire_width / 1000.0, 0.12, 0.4) * 0.9
	basis.x *= width
	basis.z *= length
	_mm.set_instance_transform(_cursor, Transform3D(basis, (p0 + p1) * 0.5 + up * LIFT))
	_mm.set_instance_custom_data(_cursor, Color(_elapsed, intensity, _fade_cap, 0.0))
	_seg_accum += 1
	_cursor = (_cursor + 1) % pool
	_written += 1
	if _written <= pool:
		_mm.visible_instance_count = _written
	if track_emissions:
		if emissions.size() >= DEBUG_LOG_MAX:
			emissions.pop_front()
		emissions.append({"wheel": wheel_idx, "p0": p0, "p1": p1,
				"t": _elapsed, "intensity": intensity, "dur": _fade_cap})

## 自检观测：落段进度、材质参数与自适应淡出状态
func debug_state() -> Dictionary:
	return {"written": _written, "cursor": _cursor,
			"visible": _mm.visible_instance_count if _mm else 0,
			"u_time": _elapsed,
			"lifetime": _mat.get_shader_parameter("lifetime") if _mat else 0.0,
			"alpha": _mat.get_shader_parameter("peak_alpha") if _mat else 0.0,
			"rate": _rate, "rate_peak": _rate_peak, "fade_cap": _fade_cap}

## 自检直写一段面片（绕开车况物理，纯渲染链路验证用）
func _emit_for_probe(p0: Vector3, p1: Vector3, normal: Vector3) -> void:
	if _mm == null:
		return
	_emit(p0, p1, normal, 1.0, 0, null)
