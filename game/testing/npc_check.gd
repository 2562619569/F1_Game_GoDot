extends Node3D
## headless 自检：NPC 交通靶车框架（配表 / 血量组件 / 碰撞伤害 / 撞爆掉落链路）。
## 运行：godot --headless --path . res://game/testing/npc_check.tscn
## 覆盖：
## 1. 配表：Car 表 701~703 NPC 段存在且物理参数与 601~603 逐项一致（同参数不同皮，
##    美术走占位回退），Game 表 npc_* 四项取值合法；
## 2. CarHealth 单元：扣血 / 累计承伤 / 负伤害忽略 / 归零只发一次 destroyed，
##    有效扣血发 changed(cur,max)、负伤与补刀不重发；
## 2b. 车顶血条（NpcHealthBar）：满血隐藏、受击出现、填充片左锚宽度=血量比例、
##     配色随比例绿→红、底/填充片 billboard+无光照自发光、归零隐藏；
## 3. 碰撞伤害（手动触发 CollisionKick._on_body_entered，同 bump_check 确定性验数学，
##    悬空消除胎阻污染）：玩家车（无 CarHealth）撞 NPC 只扣 NPC、伤害按施伤方
##    自身车速占对方最大血量的比例（100km/h 半血 / 200km/h 撞坏 / 过死区保底
##    1/4 × npc_damage_coeff；追尾移动 NPC 按表速不按相对速度）、轻蹭死区不扣、
##    冷却期不重复扣、NPC 撞玩家不掉自己的血、NPC 互撞双方各扣一次不重不漏；
## 4. 撞爆链路（完整装配 root + Vehicle + Kick + CarHealth + npc_car Driver）：
##    race_started 信号解冻后 NPC 确实开动；血量归零 → 整车退场 + 爆点生成
##    loot_pickup（id 在 Part 表）+ 爆炸粒子，玩家车组触发拾取收到 loot_cb。
## 注意项目物理 120Hz：await physics_frame × N ≈ N/120 秒。

const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const KICK := preload("res://game/car/collision_kick.gd")
const NPC_SCRIPT := preload("res://game/car/npc_car.gd")
## 与 Game 表 bump_* / npc_damage_coeff 保持同步（表改值后此处跟进；伤害断言按此复算）
const TEST_CFG := {"strength": 0.7, "min_speed": 2.0, "max_speed": 25.0, "yaw": 2.5,
		"destab_speed": 6.0, "destab_time": 1.0, "destab_grip": 0.40, "damage_coeff": 1.0}
const NPC_HP := 100.0

var _a: Vehicle   # 玩家角色车（无 CarHealth）
var _b: Vehicle   # NPC 角色车
var _c: Vehicle   # NPC 角色车（互撞段）
var _ka: CollisionKick
var _kb: CollisionKick
var _kc: CollisionKick
var _hb: CarHealth
var _hc: CarHealth

var checks := 0
var failures := 0

func ok(cond: bool, label: String, detail := "") -> void:
	checks += 1
	if cond:
		print("[NPC] OK   | %s %s" % [label, detail])
	else:
		failures += 1
		print("[NPC] FAIL | %s %s" % [label, detail])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	print("========== NPC CHECK ==========")
	seed(20260818)
	_check_tables()
	_check_health_unit()
	_check_health_bar()
	_check_type_rolls()
	_check_spawn_layout()
	await _check_collision_damage()
	await _check_destroy_chain()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[NPC] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

# ---------------- 1b. 类型抽样 / 密度随机 / 掉落梯度 ----------------

## 权重抽样与密度滚取的分布验证 + 三类型撞爆掉落稀有度统计梯度
func _check_type_rolls() -> void:
	# 类型抽样：2000 次对照权重复算（容差与 loot_roll_check 同口径 4%）
	var weights := [Match.game_cfg("npc_w_common"), Match.game_cfg("npc_w_rare"),
		Match.game_cfg("npc_w_elite")]
	var total: float = weights[0] + weights[1] + weights[2]
	var cnt := [0, 0, 0]
	for i in 2000:
		cnt[RaceBuilder._roll_npc_type(weights)] += 1
	var dist_ok := true
	for i in 3:
		if absf(cnt[i] / 2000.0 - float(weights[i]) / total) > 0.04:
			dist_ok = false
	ok(dist_ok, "类型抽样分布符合权重（2000 次容差 4%）",
			"%d/%d/%d" % [cnt[0], cnt[1], cnt[2]])
	ok(cnt[0] > cnt[1] and cnt[1] > cnt[2], "common 出现最多、elite 最少",
			"%d > %d > %d" % [cnt[0], cnt[1], cnt[2]])

	# 密度随机：200 次全部落在 [min,max] 且取值确有变化
	var hi := int(Match.game_cfg("npc_count"))
	var lo := clampi(int(Match.game_cfg("npc_count_min")), 0, hi)
	var seen := {}
	var in_range := true
	for i in 200:
		var c := RaceBuilder._roll_npc_count()
		if c < lo or c > hi:
			in_range = false
		seen[c] = true
	ok(in_range, "密度滚取全部在 [%d, %d] 区间内" % [lo, hi], str(seen.keys()))
	ok(seen.size() >= 2, "每回合密度确实随机（出现 ≥2 种取值）", str(seen.keys()))

	# 掉落梯度：各类型路线 800 件抽样，平均稀有度严格递增
	var avg := {}
	for r in ["npc_common", "npc_rare", "npc_elite"]:
		var s := 0.0
		var n := 0
		for i in 800:
			var pids: Array = Match.roll_route_drops(r)
			if not pids.is_empty() and int(pids[0]) >= 1:
				s += float(Settings.part.data[int(pids[0])].rarity)
				n += 1
		avg[r] = s / maxf(n, 1.0)
	ok(avg["npc_elite"] > avg["npc_rare"] and avg["npc_rare"] > avg["npc_common"],
			"撞爆掉落平均稀有度梯度：common < rare < elite",
			"%.2f < %.2f < %.2f" % [avg["npc_common"], avg["npc_rare"], avg["npc_elite"]])

# ---------------- 1. 配表 ----------------

## NPC 三类型掉落路线：结构 + 递进关系（稀有度越来越好、刷新概率越来越低）
func _check_tables() -> void:
	var fields := ["drive", "top_speed", "accel", "handling", "weight", "perf_slots",
			"func_slots", "grip_road", "grip_offroad", "max_torque", "max_rpm",
			"final_drive", "gear_ratios", "front_torque_split", "max_steering_angle",
			"steering_speed", "brake_force_multiplier", "coefficient_of_drag",
			"frontal_area", "front_weight_distribution",
			"center_of_gravity_height_offset", "inertia_multiplier"]
	for i in 3:
		var npc_id := 701 + i
		ok(Settings.car.data.has(npc_id), "Car 表存在 NPC 车段 %d" % npc_id)
		if not Settings.car.data.has(npc_id):
			continue
		var diffs := []
		for f in fields:
			if Settings.car.data[npc_id][f] != Settings.car.data[601 + i][f]:
				diffs.append(f)
		ok(diffs.is_empty(), "NPC %d 物理参数与玩家车 %d 逐项一致" % [npc_id, 601 + i],
				", ".join(diffs))
	var hi := int(Match.game_cfg("npc_count"))
	var lo := int(Match.game_cfg("npc_count_min"))
	ok(hi >= 1 and lo >= 0 and lo <= hi, "密度随机区间合法 [npc_count_min, npc_count]",
			"[%d, %d]" % [lo, hi])
	ok(Match.game_cfg("npc_hp") > 0.0, "npc_hp > 0", "= %.0f" % Match.game_cfg("npc_hp"))
	ok(Match.game_cfg("npc_speed_scale") > 0.0 and Match.game_cfg("npc_speed_scale") <= 1.0,
			"npc_speed_scale 在 (0,1]", "= %.2f" % Match.game_cfg("npc_speed_scale"))
	ok(Match.game_cfg("npc_damage_coeff") > 0.0, "npc_damage_coeff > 0",
			"= %.2f" % Match.game_cfg("npc_damage_coeff"))
	var wc := Match.game_cfg("npc_w_common")
	var wr := Match.game_cfg("npc_w_rare")
	var we := Match.game_cfg("npc_w_elite")
	ok(wc > 0.0 and wr > 0.0 and we > 0.0, "三类型刷新权重均 > 0",
			"= %.0f/%.0f/%.0f" % [wc, wr, we])
	ok(wc > wr and wr > we, "刷新概率随类型递减（common > rare > elite）",
			"%.0f > %.0f > %.0f" % [wc, wr, we])
	var lw := {}
	for row in Settings.loot.data.values():
		lw[String(row.route)] = row
	for r in ["npc_common", "npc_rare", "npc_elite"]:
		if lw.has(r):
			ok(int(lw[r].drop_count) == 1, "%s 单次撞爆掉 1 件" % r)
		else:
			ok(false, "Loot 表存在 %s 掉落路线" % r)
	ok(_hi_share(lw, "npc_elite") > _hi_share(lw, "npc_rare")
			and _hi_share(lw, "npc_rare") > _hi_share(lw, "npc_common"),
			"掉落稀有度越来越好（r3+r4 权重占比递增）",
			"%.2f < %.2f < %.2f" % [_hi_share(lw, "npc_common"), _hi_share(lw, "npc_rare"), _hi_share(lw, "npc_elite")])
	var has_all := lw.has("npc_common") and lw.has("npc_rare") and lw.has("npc_elite")
	ok(has_all and int(lw["npc_elite"].guarantee_rarity) > int(lw["npc_rare"].guarantee_rarity)
			and int(lw["npc_rare"].guarantee_rarity) > int(lw["npc_common"].guarantee_rarity),
			"掉落保底稀有度随类型递增",
			"%d < %d < %d" % [int(lw["npc_common"].guarantee_rarity),
					int(lw["npc_rare"].guarantee_rarity), int(lw["npc_elite"].guarantee_rarity)])

## 某路线 r3+r4 权重占总量比例（越高掉落越好）
func _hi_share(lw: Dictionary, route: String) -> float:
	if not lw.has(route):
		return -1.0
	var w: PackedStringArray = String(lw[route].rarity_weights).split("|", false)
	if w.size() != 4:
		return -1.0
	var total := 0.0
	for x in w:
		total += float(x)
	return (float(w[2]) + float(w[3])) / total if total > 0.0 else -1.0

# ---------------- 1c. 全赛道分布与生成数量（真实地图 + 整场装配） ----------------

## 分布铺满主路（首台越过发车区且不深藏、尾台不越线、跨度够大）+ 整场装配数量落在密度区间
func _check_spawn_layout() -> void:
	var path := "res://game/race/tracks/data/map_1.json"
	if not FileAccess.file_exists(path):
		ok(false, "map_1.json 存在（分布断言依赖真实赛道）")
		return
	var data := TrackData.load_json(path)
	var hi := int(Match.game_cfg("npc_count"))
	var lo := int(Match.game_cfg("npc_count_min"))
	var n := randi_range(lo, hi)
	var s_min := INF
	var s_max := -INF
	for i in n:
		var spot: Dictionary = RaceBuilder._npc_spot(null, data, i, n)
		var idx: int = data.nearest_index(spot.pos, 0)
		var s: float = data.main["s_arr"][idx]
		s_min = minf(s_min, s)
		s_max = maxf(s_max, s)
	ok(s_min >= RaceBuilder.NPC_SPAWN_MIN_S - 1.0, "首台越过发车区净距",
			"s=%.0f ≥ %.0f" % [s_min, RaceBuilder.NPC_SPAWN_MIN_S])
	ok(s_min <= data.length * 0.15, "首台不深藏（≤15%L）", "s=%.0f L=%.0f" % [s_min, data.length])
	ok(s_max <= data.length * 0.96, "尾台不越过 95%L", "s=%.0f L=%.0f" % [s_max, data.length])
	ok(s_max - s_min >= data.length * 0.7, "分布铺满赛道主干（跨度≥70%L）",
			"span=%.0f L=%.0f" % [s_max - s_min, data.length])

	# 整场装配：真实 build 链路的生成数量落在随机密度区间
	var race := RaceManager.new()
	add_child(race)
	race.setup(1)
	var cnt := 0
	for c in race.get_children():
		if c.name.begins_with("NPC"):
			cnt += 1
	ok(cnt >= lo and cnt <= hi, "整场装配 NPC 数量在密度区间",
			"%d ∈ [%d, %d]" % [cnt, lo, hi])
	var bars := 0
	for c in race.get_children():
		if c.name.begins_with("NPC"):
			for cc in c.get_children():
				if cc is Vehicle and cc.get_node_or_null("HealthBar") != null:
					bars += 1
	ok(bars == cnt, "整场装配 NPC 全挂车顶血条", "%d/%d" % [bars, cnt])
	race.free()

# ---------------- 2. CarHealth 单元 ----------------

func _check_health_unit() -> void:
	var h := CarHealth.new()
	add_child(h)
	h.setup(NPC_HP)
	ok(h.hp == NPC_HP and h.hp_max == NPC_HP and h.alive(), "setup 后满血存活")
	var fired := [0]  # 数组容器：GDScript lambda 按值捕获局部变量，裸 int 计数不生效
	h.destroyed.connect(func(_n): fired[0] += 1)
	var fired_chg := [0, -1.0, 0.0]  # [次数, 最近 cur, 最近 max]
	h.changed.connect(func(c: float, m: float):
		fired_chg[0] += 1
		fired_chg[1] = c
		fired_chg[2] = m)
	h.take_damage(30.0)
	ok(h.hp == 70.0 and h.damage_taken == 30.0, "扣血并累计承伤", "hp=%.0f taken=%.0f" % [h.hp, h.damage_taken])
	ok(fired_chg[0] == 1 and fired_chg[1] == 70.0 and fired_chg[2] == NPC_HP,
			"有效扣血发 changed(70, 100)", "n=%d cur=%.0f max=%.0f" % [fired_chg[0], fired_chg[1], fired_chg[2]])
	h.take_damage(-5.0)
	ok(h.hp == 70.0, "负伤害忽略", "hp=%.0f" % h.hp)
	ok(fired_chg[0] == 1, "负伤害不发 changed", "n=%d" % fired_chg[0])
	h.take_damage(999.0)
	ok(h.hp == 0.0 and not h.alive() and fired[0] == 1, "归零发一次 destroyed", "hp=%.0f fired=%d" % [h.hp, fired[0]])
	ok(fired_chg[0] == 2 and fired_chg[1] == 0.0, "归零发 changed(0, 100)",
			"n=%d cur=%.0f" % [fired_chg[0], fired_chg[1]])
	h.take_damage(10.0)
	ok(fired[0] == 1, "死后补刀不重发 destroyed", "fired=%d" % fired[0])
	ok(fired_chg[0] == 2, "死后补刀不重发 changed", "n=%d" % fired_chg[0])
	h.queue_free()

# ---------------- 2b. 车顶血条 ----------------

## NpcHealthBar 表现单元：出现/隐藏时机、填充几何（左锚宽度=比例）、配色梯度、
## 材质朝向（billboard 面向相机 + 无光照自发光保证阴雨/夜景可读）
func _check_health_bar() -> void:
	var v := _make_vehicle(Vector3(20, 1.8, 0), true)  # 悬空纯验表现，同步断言不落物理
	var bar := NpcHealthBar.new()
	bar.name = "HealthBar"
	v.add_child(bar)
	bar.setup(v)
	var fill: MeshInstance3D = bar.get_node("Fill")
	var mat := fill.material_override as StandardMaterial3D
	var bg_mat := (bar.get_node("BarBg") as MeshInstance3D).material_override as StandardMaterial3D
	var fw := NpcHealthBar.WIDTH - NpcHealthBar.INSET * 2.0

	ok(v.get_node_or_null("HealthBar") == bar, "血条挂在车体 HealthBar 位")
	ok(bar.visible == false, "满血时血条隐藏")
	ok(mat.billboard_mode == BaseMaterial3D.BILLBOARD_ENABLED
			and bg_mat.billboard_mode == BaseMaterial3D.BILLBOARD_ENABLED,
			"底片/填充片均 billboard 朝相机")
	ok(mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and mat.emission_enabled,
			"填充片无光照 + 自发光")

	var h := v.get_node("CarHealth") as CarHealth
	h.take_damage(30.0)
	ok(bar.visible == true, "受击后血条出现")
	ok(absf(fill.scale.x - 0.7) < 0.01, "填充宽度 = 血量比例", "= %.2f" % fill.scale.x)
	ok(absf(fill.position.x - (-fw * 0.15)) < 0.005, "填充片左端锚定（居中向右收）",
			"x=%.3f 期望 %.3f" % [fill.position.x, -fw * 0.15])
	var c70 := mat.albedo_color
	ok(c70.g > c70.r and c70.b < c70.r, "70% 血配色偏绿黄", "(%.2f, %.2f, %.2f)" % [c70.r, c70.g, c70.b])
	h.take_damage(50.0)  # → 剩 20%
	ok(absf(fill.scale.x - 0.2) < 0.01, "连续受击填充跟随（20%）", "= %.2f" % fill.scale.x)
	var c20 := mat.albedo_color
	ok(c20.r > c20.g, "20% 血配色转红", "(%.2f, %.2f, %.2f)" % [c20.r, c20.g, c20.b])
	h.take_damage(999.0)
	ok(bar.visible == false, "归零后血条隐藏（随后撞爆整车退场）")
	v.queue_free()

# ---------------- 3. 碰撞伤害（手动触发，悬空验数学） ----------------

func _check_collision_damage() -> void:
	_make_ground()
	_a = _make_vehicle(Vector3(3, 1.8, 0), false)
	_b = _make_vehicle(Vector3(-3, 1.8, 0), true)
	_c = _make_vehicle(Vector3(-9, 1.8, 0), true)
	_ka = _a.get_node("CollisionKick") as CollisionKick
	_kb = _b.get_node("CollisionKick") as CollisionKick
	_kc = _c.get_node("CollisionKick") as CollisionKick
	_hb = _b.get_node("CarHealth") as CarHealth
	_hc = _c.get_node("CarHealth") as CarHealth
	await _frames(2)  # 服务器端 inertia 同步（同 bump_check 质量段注释）

	# 玩家撞 NPC：closing 8 m/s = 28.8 km/h → 保底档，伤害 = 100 × 25% × 1.0 = 25
	# 手动触发前双方组件的 _pre_vel 都要归位（运行时由每物理步自动记录，测试须
	# 手动同步，否则上一场景的旧速度串进本场景的接近速度）
	_reset_kick(_ka, Vector3(-8.0, 0, 0))
	_reset_kick(_kb, Vector3.ZERO)
	_ka._on_body_entered(_b)
	ok(_hb.hp == NPC_HP - 25.0, "玩家撞 NPC 按公式扣血（保底 1/4 = 25 点）", "hp=%.1f" % _hb.hp)
	ok(_ka.damage_dealt == 25.0, "攻击方记账 damage_dealt", "= %.1f" % _ka.damage_dealt)
	ok(_a.get_node_or_null("CarHealth") == null, "玩家车无 CarHealth（结构免疫）")
	ok(_hb.hp == NPC_HP - 25.0, "玩家撞 NPC 后玩家方无血量变化（无组件可扣）")

	# 冷却期内重复触发：伤害不再结算
	_ka._pre_vel = Vector3(-8.0, 0, 0)
	_ka._on_body_entered(_b)
	ok(_hb.hp == NPC_HP - 25.0, "冷却期内不重复扣血", "hp=%.1f" % _hb.hp)

	# NPC 撞玩家：伤害只记对方，玩家无组件 → NPC 自己也不掉血（不掉自己的血）
	_reset_kick(_kb, Vector3(8.0, 0, 0))
	_reset_kick(_ka, Vector3.ZERO)
	_kb._on_body_entered(_a)
	ok(_hb.hp == NPC_HP - 25.0 and _kb.damage_dealt == 0.0, "NPC 撞玩家双方均不掉血",
			"hpB=%.1f dealt=%.1f" % [_hb.hp, _kb.damage_dealt])

	# 轻蹭死区：closing 1.5 < bump_min_speed → 整段跳过
	_reset_kick(_ka, Vector3(-1.5, 0, 0))
	_reset_kick(_kb, Vector3.ZERO)
	_ka._on_body_entered(_b)
	ok(_hb.hp == NPC_HP - 25.0 and _ka.damage_dealt == 0.0, "轻蹭死区不扣血", "hp=%.1f" % _hb.hp)

	# NPC 互撞：双方组件各给对方记一次，各扣保底 25
	_reset_kick(_kb, Vector3(-8.0, 0, 0))  # B 向 C 逼近
	_reset_kick(_kc, Vector3.ZERO)
	_kb._on_body_entered(_c)
	_kc._on_body_entered(_b)
	ok(_hc.hp == NPC_HP - 25.0 and _kb.damage_dealt == 25.0, "NPC 互撞 B 扣 C 一次",
			"hpC=%.1f" % _hc.hp)
	ok(_hb.hp == NPC_HP - 50.0 and _kc.damage_dealt == 25.0, "NPC 互撞 C 扣 B 一次（互伤不重不漏）",
			"hpB=%.1f" % _hb.hp)

	# 追尾移动 NPC：B 以 50km/h 同向逃逸、玩家 100km/h 追上（closing 只剩 50km/h
	# 但过死区），伤害仍按施伤方表速 100km/h = 半血 50 点 → B 50 血直接撞坏。
	# 锁定「按表速不按相对速度」语义：按 closing 结算只会扣保底 25
	_reset_kick(_ka, Vector3(-100.0 / 3.6, 0, 0))
	_reset_kick(_kb, Vector3(-50.0 / 3.6, 0, 0))
	_ka._on_body_entered(_b)
	ok(_hb.hp == 0.0 and not _hb.alive() and absf(_ka.damage_dealt - NPC_HP * 0.5) < 0.01,
			"追尾 50km/h 的 NPC 仍按自身 100km/h 表速扣半血", "hpB=%.1f dealt=%.1f" % [_hb.hp, _ka.damage_dealt])

	# 速度比例档位（拿残血 75 的 C 验）：100km/h 一击恰好半血 50 → 剩 25；
	# 200km/h 比例满格 → 一下撞坏归零（浮点除乘回 100 有 ulp 误差，容差比较）
	_reset_kick(_ka, Vector3(-100.0 / 3.6, 0, 0))
	_reset_kick(_kc, Vector3.ZERO)
	_ka._on_body_entered(_c)
	ok(absf(_hc.hp - NPC_HP * 0.25) < 0.01 and absf(_ka.damage_dealt - NPC_HP * 0.5) < 0.01,
			"100km/h 一击扣一半（50 点）", "hpC=%.1f dealt=%.1f" % [_hc.hp, _ka.damage_dealt])
	_reset_kick(_ka, Vector3(-200.0 / 3.6, 0, 0))
	_ka._on_body_entered(_c)
	ok(_hc.hp == 0.0 and not _hc.alive(), "200km/h 一下撞坏", "hpC=%.1f" % _hc.hp)

	_a.queue_free()
	_b.queue_free()
	_c.queue_free()

## 地面（甩开一段距离，悬空段不接触；驾驶段在远处落地跑）
func _make_ground() -> void:
	var ground := StaticBody3D.new()
	ground.add_to_group("Road")
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(400, 1, 400)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)

func _make_vehicle(pos: Vector3, with_health: bool) -> Vehicle:
	var v: Vehicle = CAR_SCENE.instantiate()
	CarMeshBuilder.attach(v, "601", "sport_v1", "stock_v1")
	v.position = pos
	v.collision_layer = Racer.CAR_LAYER
	v.collision_mask = Racer.CAR_MASK
	var kick: CollisionKick = KICK.new()
	kick.name = "CollisionKick"
	v.add_child(kick)
	kick.setup(v, TEST_CFG)
	if with_health:
		var h := CarHealth.new()
		h.name = "CarHealth"
		v.add_child(h)
		h.setup(NPC_HP)
	add_child(v)
	v.can_sleep = false
	return v

## 复位组件冷却/记账并注入指定碰前速度（手动触发场景须双方都归位，见段注释）
func _reset_kick(k: CollisionKick, pre: Vector3) -> void:
	k._cooldown = 0.0
	k._pre_vel = pre
	k.damage_dealt = 0.0

# ---------------- 4. 撞爆链路（完整装配） ----------------

func _check_destroy_chain() -> void:
	var host := Node3D.new()
	host.name = "NPCHost"
	add_child(host)
	var race_stub := RaceManager.new()  # 仅作 race_started 信号源，不入树
	var drops: Array = []

	var root := Node3D.new()
	root.name = "NPC-701"
	var v: Vehicle = CAR_SCENE.instantiate()
	CarMeshBuilder.attach_visual(v, 701, {})  # 70x 无美术目录 → 占位回退路径一并验证
	v.collision_layer = Racer.CAR_LAYER
	v.collision_mask = Racer.CAR_MASK
	var kick: CollisionKick = KICK.new()
	kick.name = "CollisionKick"
	v.add_child(kick)
	kick.setup(v, TEST_CFG)
	var health := CarHealth.new()
	health.name = "CarHealth"
	v.add_child(health)
	health.setup(30.0)
	v.position = Vector3(0, 0.6, 0)
	root.position = Vector3(30, 0, 0)
	root.add_child(v)
	host.add_child(root)
	var ctrl := Node3D.new()
	ctrl.name = "Driver"
	ctrl.set_script(NPC_SCRIPT)
	root.add_child(ctrl)
	ctrl.setup(v, null, 2.0, 0.45, race_stub, func(pid: int): drops.append(pid), "npc_elite")

	ok(ctrl.frozen == true, "装配后冻结待发车")
	race_stub.race_started.emit()
	await _frames(90)  # 0.75s @120Hz：直线模式全油门起步
	ok(ctrl.frozen == false and v.linear_velocity.length() > 0.5,
			"race_started 解冻后 NPC 开动", "v=%.2f m/s" % v.linear_velocity.length())

	health.take_damage(999.0)
	await _frames(3)  # 让 queue_free 落账、loot/粒子入树
	ok(not is_instance_valid(root) or not root.is_inside_tree(), "撞爆后整车退场")
	var loot: Node = null
	var boomed := false
	for c in host.get_children():
		if c is Area3D:
			loot = c
		if c is GPUParticles3D:
			boomed = true
	ok(loot != null, "爆点生成掉落物")
	ok(boomed, "爆点生成爆炸粒子")
	if loot != null:
		ok(Settings.part.data.has(int(loot.part_id)), "掉落 id 在 Part 表", "= %d" % int(loot.part_id))
		ok(int(Settings.part.data[int(loot.part_id)].rarity) >= 2,
				"掉落稀有度符合 npc_elite 保底（≥2）",
				"rarity=%d" % int(Settings.part.data[int(loot.part_id)].rarity))
		# 玩家车组拾取：直接驱动 loot 的 body 入口（player_car 组才收）
		var player_body := StaticBody3D.new()
		player_body.add_to_group("player_car")
		add_child(player_body)
		loot._on_body(player_body)
		ok(drops.size() == 1 and Settings.part.data.has(int(drops[0])),
				"玩家组拾取触发 loot_cb", "pid=%s" % str(drops))
		player_body.queue_free()
	race_stub.free()
