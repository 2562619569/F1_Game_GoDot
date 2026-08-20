extends SceneTree
## 极限工况车轮印自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配：缺省与 Game 表 skid_* 同源（直读 dist 表 + race_builder 接线扫描）、
##    setup 注入、材质参数（lifetime/alpha）与初始可见数 0；
## 2. 巡航不落印：轮速同步滑移 ≈0，任何轮都不超阈值；
## 3. 重刹抱死落印：ABS 脉冲式断续印（强度 ∈[0.35,1]、出生时刻单调、段长合法）；
## 4. 漂移侧滑连续落印：后轮手刹锁滑，段与段首尾相接成连续车辙；
## 5. 世界空间固定：车开走后已落段实例变换不变（印不随车动）；
## 6. 烧胎打滑落印：大扭矩弹射，纵滑为大负（打滑方向）；
## 7. 草地不留印：轮面命中 Grass 组、强度表面系数 0，零落段；
## 8. 腾空断笔：空中零落段，落地后不跨缝连接（新段 p0 距腾空前 p1 > 段长上限）；
## 9. 环形回绕：pool=48 写满后覆写最旧（visible 停在 pool、cursor=written%pool）；
## 10. 自适应淡出时长：低速/间歇落段时新段淡出=lifeime 上限；持续高密度落段
##     （pool=48 应力态）新段淡出收缩到 MIN_FADE 下限——段被覆写前必淡完，回绕不闪断；
## 11. shader 时钟推进（u_time > 0，出生时刻同源）。
## 输入直写 vehicle 输入变量；物理 120Hz，await physics_frame ×N ≈ N/120 秒。

const SKID := preload("res://game/car/skid_marks.gd")
## 与 Game 表 skid_* 保持同步（表改值后此处跟进；自检不依赖 autoload 读表）
const TEST_CFG := {"lat_slip": 0.2, "lon_slip": 0.2, "lifetime": 25.0,
		"alpha": 0.75, "gap": 0.35, "pool": 4096.0}

const START_POS := Vector3(0, 0.6, 60.0)  # -Z 前进
const GRASS_POS := Vector3(250, 0.6, 0.0)  # 草地覆盖层 x∈[150,350]
const RUN_SPEED := 20.0

var _v: Vehicle
var _skid: SkidMarks
var _anchor: Node3D
var _fails := 0
var _started := false
var _done := false

func _init() -> void:
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(400, 1, 400)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)
	# 草地：1cm 高的 Grass 覆盖层（射线从上命中即判草面）
	var grass := StaticBody3D.new()
	grass.add_to_group("Grass")
	var cs := CollisionShape3D.new()
	var cb := BoxShape3D.new()
	cb.size = Vector3(200, 1, 400)
	cs.shape = cb
	grass.add_child(cs)
	grass.position = Vector3(250, -0.49, 0)
	root.add_child(grass)

	# 车挂在带平移+旋转的父节点下（仿真 racer 根节点：发车位平移 + 朝向）。
	# 面片实例变换是世界坐标，若未隔离父变换（top_level），会被二次变换甩离
	# 触点——本项正是实装中发现的游戏内不可见根因，headless 数据自检必测
	_anchor = Node3D.new()
	_anchor.name = "Anchor"
	_anchor.position = Vector3(100, 0, 50)
	_anchor.rotation.y = deg_to_rad(90.0)
	root.add_child(_anchor)

	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach(_v, "601", "sport_v1", "stock_v1")
	_v.position = START_POS
	_anchor.add_child(_v)
	_skid = SKID.new()
	_skid.name = "SkidMarks"
	_v.add_child(_skid)
	_skid.setup(_v, TEST_CFG)
	_skid.track_emissions = true
	_v.can_sleep = false

func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return _done

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

## 每段开跑前复位车况（同 drift_check：瞬移量会被当速度、轮胎静止有起转阻力，
## 须同步上帧位置 + 预转轮 + 离合分离），另清空全部输入
func _reset_car(speed := RUN_SPEED, pos := START_POS) -> void:
	_v.global_position = pos
	_v.global_rotation = Vector3.ZERO  # 世界姿态归零（父锚点带旋转，局部归零会横置车速方向）
	_v.linear_velocity = Vector3(0, 0, -speed)
	_v.angular_velocity = Vector3.ZERO
	_v.previous_global_position = _v.global_position
	for wheel in _v.wheel_array:
		wheel.spin = speed / wheel.tire_radius
		wheel.previous_global_position = wheel.global_position
	_v.clutch_input = 1.0
	_v.throttle_input = 0.0
	_v.brake_input = 0.0
	_v.handbrake_input = 0.0
	_v.steering_input = 0.0
	_v.motor_rpm = _v.max_rpm * 0.55

func _count_emissions(wheel_idx := -1) -> int:
	if wheel_idx < 0:
		return _skid.emissions.size()
	var n := 0
	for e in _skid.emissions:
		if e.wheel == wheel_idx:
			n += 1
	return n

func _run() -> void:
	await _frames(120)  # 出生抬高自由沉降，悬挂静置后再开测

	# ---- 1. 装配与参数 ----
	_expect(_v.get_node_or_null("SkidMarks") is SkidMarks, "车挂有 SkidMarks")
	_expect(_skid.lat_slip == 0.2 and _skid.lon_slip == 0.2 and _skid.lifetime == 25.0
			and _skid.alpha == 0.75 and _skid.gap == 0.35 and _skid.pool == 4096,
			"setup 注入车轮印参数")
	_expect(SkidMarks.DEFAULT_LAT_SLIP == 0.2 and SkidMarks.DEFAULT_LON_SLIP == 0.2
			and SkidMarks.DEFAULT_LIFETIME == 25.0 and SkidMarks.DEFAULT_ALPHA == 0.75
			and SkidMarks.DEFAULT_GAP == 0.35 and SkidMarks.DEFAULT_POOL == 4096,
			"组件代码缺省与 Game 表默认一致")
	var st := _skid.debug_state()
	_expect(st.lifetime == 25.0 and st.alpha == 0.75 and st.visible == 0 and st.written == 0,
			"材质参数注入且初始可见段数 0")
	_expect(_anchor.get_node("SkidMarks") is MultiMeshInstance3D,
			"面片挂车位父节点（racer 根同位）且 top_level 隔离其变换")
	# Game 表同源：直读导出表（无 autoload）
	var table: Dictionary = load("res://config/dist/ModRacer/game.gd").new().data
	var want := {"skid_lat_slip": 0.2, "skid_lon_slip": 0.2, "skid_lifetime": 25.0,
			"skid_alpha": 0.75, "skid_gap": 0.35, "skid_pool": 4096.0}
	var hits := 0
	var ok := true
	for row in table.values():
		var k := String(row.key)
		if k.begins_with("skid_"):
			hits += 1
			if not is_equal_approx(float(row.value), float(want[k])):
				ok = false
	_expect(ok and hits == 6, "Game 表 skid_* 六键与组件默认同源", "hits=%d" % hits)
	# race_builder 接线：1 处定义 + racer/NPC 两处调用
	var src := FileAccess.get_file_as_string("res://game/race/race_builder.gd")
	_expect(src.count("_attach_skid_marks(") == 3 and src.contains("SKID_MARKS :="),
			"race_builder 对竞速车与 NPC 均装配车轮印")

	# ---- 2. 巡航不落印 ----
	_reset_car()
	await _frames(90)
	_expect(_skid.debug_state().written == 0, "轮速同步巡航不落印",
			"written=%d" % _skid.debug_state().written)

	# ---- 3. 重刹抱死（ABS 脉冲 → 断续印） ----
	_skid.emissions.clear()
	_reset_car(30.0)
	_v.brake_input = 1.0
	await _frames(180)
	var n_brake := _count_emissions()
	var inten_ok := true
	var t_ok := true
	var seg_ok := true
	var dur_ok := true
	var last_t := -1.0
	for e in _skid.emissions:
		inten_ok = inten_ok and e.intensity >= 0.499 and e.intensity <= 1.001
		t_ok = t_ok and e.t >= last_t
		last_t = e.t
		var seg_len := (e.p1 as Vector3).distance_to(e.p0 as Vector3)
		seg_ok = seg_ok and seg_len >= 0.349 and seg_len <= SkidMarks.MAX_SEG + 0.001
		dur_ok = dur_ok and e.dur >= SkidMarks.MIN_FADE - 0.01 and e.dur <= 25.0 + 0.01
	print("[SKID] 重刹 1.5s 落段=%d（ABS 脉冲断续）" % n_brake)
	_expect(n_brake > 8, "重刹抱死落印（>8 段）", "n=%d" % n_brake)
	_expect(inten_ok, "落段强度 ∈ [0.35,1]（阈值基准 + 超出倍数）")
	_expect(t_ok, "出生时刻单调不减（淡出时钟同源）")
	_expect(seg_ok, "段长 ∈ [gap, MAX_SEG]")
	_expect(dur_ok, "每段淡出时长 ∈ [MIN_FADE, lifetime]（覆写前必淡完）")
	_expect(not _skid.emissions.is_empty() and is_equal_approx(_skid.emissions[0].dur, 25.0),
			"低速率起步时新段淡出 = lifetime 上限（自适应不误收缩）",
			"dur=%.2f" % _skid.emissions[0].dur)

	# ---- 4. 漂移侧滑连续落印（后轮锁滑车辙） ----
	_skid.emissions.clear()
	_reset_car()
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	_v.clutch_input = 0.0
	_v.throttle_input = 0.3
	await _frames(240)  # 2s
	var n_rl := _count_emissions(2)
	var n_rr := _count_emissions(3)
	print("[SKID] 漂移 2s 后轮落段 L=%d R=%d" % [n_rl, n_rr])
	_expect(n_rl + n_rr > 20, "漂移侧滑落印（后轮 >20 段）", "L=%d R=%d" % [n_rl, n_rr])
	# 同轮相邻段首尾相接率：emit 后笔尖=段尾，下段必从笔尖起（断笔处除外）
	var chained := 0
	var pairs := 0
	for w in [2, 3]:
		var prev: Dictionary = {}
		for e in _skid.emissions:
			if e.wheel != w:
				continue
			if not prev.is_empty():
				pairs += 1
				if (e.p0 as Vector3) == (prev.p1 as Vector3):
					chained += 1
			prev = e
	_expect(pairs > 0 and chained >= pairs * 0.6, "段与段首尾相接成连续车辙（≥60%）",
			"%d/%d" % [chained, pairs])
	# ---- 4b. top_level 隔离父变换（实装不可见的根因回归） ----
	# 注：get_instance_transform 在本 4.7.1 构建上恒返回单位变换（坏 getter），
	# 实例数据的落点正确性由窗口模式 skid_visual_check 的像素断言端到端验证
	var mmi4: MultiMeshInstance3D = _anchor.get_node("SkidMarks")
	_expect(mmi4.top_level and mmi4.global_transform.origin.is_equal_approx(Vector3.ZERO)
			and absf(mmi4.global_position.x - _anchor.global_position.x) > 50.0,
			"面片节点隔离父变换（top_level：父带平移+旋转，自身世界变换仍为单位）",
			"mmi=%s anchor=%s" % [mmi4.global_position, _anchor.global_position])

	# ---- 5. 世界空间固定（面片锚不随车动；实例级回读 getter 在本构建不可用，锚级验证） ----
	var gp0: Transform3D = (_anchor.get_node("SkidMarks") as Node3D).global_transform
	_v.handbrake_input = 0.0
	_v.steering_input = 0.0
	_v.throttle_input = 0.6
	await _frames(90)
	var gp1: Transform3D = (_anchor.get_node("SkidMarks") as Node3D).global_transform
	_expect(gp0 == gp1 and gp0.origin.is_equal_approx(Vector3.ZERO), "车开走后胎印锚不动（世界空间固定）")

	# ---- 6. 烧胎打滑（纵滑大负） ----
	_skid.emissions.clear()
	var before: int = _skid.debug_state().written
	_reset_car(3.0)
	_v.max_torque = 3000.0  # 弹射大扭矩突破 μ≈2 的抓地（表值 300 巡航够用）
	_v.clutch_input = 0.0
	_v.throttle_input = 1.0
	await _frames(90)
	_v.max_torque = 300.0
	print("[SKID] 烧胎 0.75s 落段=%d" % _count_emissions())
	_expect(_skid.debug_state().written - before > 5, "烧胎打滑落印（大负纵滑）",
			"n=%d" % (_skid.debug_state().written - before))

	# ---- 7. 草地不留印 ----
	_skid.emissions.clear()
	before = _skid.debug_state().written
	_reset_car(15.0, GRASS_POS)
	_v.steering_input = 0.4
	_v.handbrake_input = 1.0
	await _frames(60)
	_expect(_v.rear_axle.wheels[0].surface_type == "Grass", "轮面命中 Grass 表面组",
			"surface=%s" % _v.rear_axle.wheels[0].surface_type)
	_expect(_skid.debug_state().written == before, "草地滑移不留印（表面系数 0）",
			"+%d" % (_skid.debug_state().written - before))

	# ---- 8. 腾空断笔 ----
	_skid.emissions.clear()
	_reset_car(18.0)
	_v.steering_input = 0.5
	_v.handbrake_input = 1.0
	await _frames(90)  # 先在路面滑出几段（出生抬高自由沉降约 27 帧，留足锁滑窗口）
	var ground_n := _count_emissions()
	var last_p1: Vector3 = _skid.emissions.back().p1 if ground_n > 0 else Vector3.ZERO
	_expect(ground_n > 0, "腾空前先落段（断笔对照准备）", "n=%d" % ground_n)
	_v.global_position += Vector3(0, 2.0, -25.0)  # 传送进空中：轮全离地
	_v.previous_global_position = _v.global_position
	for wheel in _v.wheel_array:
		wheel.previous_global_position = wheel.global_position
	await _frames(10)
	var air_n := _count_emissions() - ground_n
	_expect(air_n == 0, "腾空零落段", "+%d" % air_n)
	for i in 180:  # 等落地后继续锁滑出段
		await physics_frame
		if _count_emissions() > ground_n:
			break
	# journal 按时间追加：腾空后的第一条在 ground_n + air_n 处
	var idx_new := ground_n + air_n
	var first_new: Dictionary = {}
	if _skid.emissions.size() > idx_new:
		first_new = _skid.emissions[idx_new]
	if not first_new.is_empty():
		var gap0 := (first_new.p0 as Vector3).distance_to(last_p1)
		_expect(gap0 > SkidMarks.MAX_SEG, "落地后不跨缝连接（新段起笔远离腾空前段尾）",
				"gap=%.2fm" % gap0)
	else:
		_expect(false, "落地后恢复落段", "无新段")

	# ---- 9. 环形回绕（pool=48 覆写最旧） ----
	_skid.track_emissions = false
	_skid.queue_free()  # _exit_tree 回收世界层面片
	await _frames(2)
	var skid2 := SKID.new()
	skid2.name = "SkidMarks2"
	_v.add_child(skid2)
	var cfg2 := TEST_CFG.duplicate()
	cfg2.pool = 48.0
	skid2.setup(_v, cfg2)
	skid2.track_emissions = true
	_skid = skid2
	_reset_car(16.0)
	_v.steering_input = 1.0
	_v.handbrake_input = 1.0
	_v.clutch_input = 0.0
	_v.throttle_input = 0.3
	var wrapped := false
	for i in 600:  # 5s 预算绕圈
		await physics_frame
		if skid2.debug_state().written > 48:
			wrapped = true
			break
	var st9 := skid2.debug_state()
	_expect(wrapped, "环形池写满后继续落段（>pool）", "written=%d" % st9.written)
	_expect(st9.visible == 48 and st9.cursor == st9.written % 48,
			"回绕状态：visible 停在 pool、cursor=written%%pool",
			"vis=%d cur=%d w=%d" % [st9.visible, st9.cursor, st9.written])
	_expect(st9.u_time > 0.0, "shader 淡出时钟推进（u_time>0）")

	# ---- 10. 自适应淡出时长（pool=48 应力态：淡出收缩到下限） ----
	await _frames(180)  # 持续滑移，速率 EMA/峰值收敛
	var em10: Array[Dictionary] = skid2.emissions
	var dur_last: float = em10.back().dur if not em10.is_empty() else -1.0
	_expect(em10.size() > 48 and is_equal_approx(dur_last, SkidMarks.MIN_FADE),
			"持续高密度落段时新段淡出收缩到 MIN_FADE（段被覆写前淡完，回绕不闪断）",
			"n=%d dur=%.2f rate=%.0f" % [em10.size(), dur_last, skid2.debug_state().rate])

	_done = true
	print("[SKID] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)

func _expect(cond: bool, label: String, detail := "") -> void:
	if cond:
		print("[SKID] OK   %s %s" % [label, detail])
	else:
		_fails += 1
		print("[SKID] FAIL %s %s" % [label, detail])
