extends Node
## headless 自检：随机部件奖励方块的掉落抽取与 Loot 配表语义。
## 运行：godot --headless --path . res://game/testing/loot_roll_check.tscn
## 覆盖：roll_rarity 权重/保底、roll_part 稀有度夹档、roll_route_drops 抽样
## （数量/类别池/保底/分布对独立复算期望）、Loot 表结构一致性。

var checks := 0
var failures := 0

const SAMPLE := 2000
const TOL := 0.04

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[LOOT] OK   | %s" % label)
	else:
		failures += 1
		print("[LOOT] FAIL | %s" % label)

func _ready() -> void:
	print("========== LOOT ROLL CHECK ==========")
	seed(20260818)  # 固定种子，结果可复现
	_check_tables()
	_check_roll_rarity()
	_check_roll_part()
	_check_route_drops()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[LOOT] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

# ---------------- Loot 表结构一致性 ----------------

func _check_tables() -> void:
	var routes := {}
	for rule in Settings.loot.data.values():
		var route := String(rule.route)
		routes[route] = true
		var w: PackedStringArray = String(rule.rarity_weights).split("|", false)
		ok(w.size() == 4, "%s rarity_weights 恰 4 段（实际 %d）" % [route, w.size()])
		var total := 0.0
		for s in w:
			total += float(s)
		ok(total > 0.0, "%s 权重总和 %.1f > 0" % [route, total])
		var cats: PackedStringArray = String(rule.category_pool).split("|", false)
		var cat_ok := not cats.is_empty()
		for c in cats:
			if _category_max_rarity(String(c)) <= 0:
				cat_ok = false
		ok(cat_ok, "%s category_pool 类别均在 Part 表（%s）" % [route, cats])
		# 保底若超过池内某类别最高稀有度，夹档也保不住，视为配表错误
		var g := int(rule.guarantee_rarity)
		var feasible := true
		for c in cats:
			if _category_max_rarity(String(c)) < g:
				feasible = false
		ok(feasible, "%s guarantee=%d 不超过池内各类别最高稀有度" % [route, g])
	ok(routes.has("main") and routes.has("hazard"), "main/hazard 规则齐全：%s" % str(routes.keys()))

func _category_max_rarity(category: String) -> int:
	var max_r := 0
	for p in Settings.part.data.values():
		if p.category == category:
			max_r = maxi(max_r, int(p.rarity))
	return max_r

## 复刻 roll_part 的候选规则（r>=min 均匀，空池夹到类别最高档），返回候选稀有度列表，
## 作为独立于 Match 抽取代码的对照 oracle。
func _candidate_rarities(category: String, min_rarity: int) -> Array:
	var pool: Array = []
	for p in Settings.part.data.values():
		if p.category == category and int(p.rarity) >= min_rarity:
			pool.append(int(p.rarity))
	if pool.is_empty():
		var max_r := _category_max_rarity(category)
		for p in Settings.part.data.values():
			if p.category == category and int(p.rarity) == max_r:
				pool.append(int(p.rarity))
	return pool

# ---------------- roll_rarity 单元 ----------------

func _check_roll_rarity() -> void:
	var only3 := true
	var lifted := true
	var only1 := true
	for i in 200:
		only3 = only3 and Match.roll_rarity([0.0, 0.0, 10.0, 0.0]) == 3
		lifted = lifted and Match.roll_rarity([10.0, 10.0, 10.0, 10.0], 4) == 4
		only1 = only1 and Match.roll_rarity([10.0, 0.0, 0.0, 0.0]) == 1
	ok(only3, "roll_rarity 单档权重恒出该档（3）")
	ok(lifted, "roll_rarity 保底抬到 4")
	ok(only1, "roll_rarity 首档权重恒出 1")

# ---------------- roll_part 单元 ----------------

func _check_roll_part() -> void:
	var aero := true
	var tires := true
	for i in 100:
		aero = aero and Match.roll_part("aero", 3) == 302   # 尾翼最高 r2，夹档只出 302
		tires = tires and Match.roll_part("tires", 99) == 204
	ok(aero, "roll_part(aero,3) 空回退夹档到 302（r2）")
	ok(tires, "roll_part(tires,99) 空回退夹档到 204（r3）")
	var missing := true
	for i in 10:
		missing = missing and Match.roll_part("no_such_cat", 1) == 0
	ok(missing, "未知类别返回 0（防御）")

# ---------------- roll_route_drops 抽样 ----------------

func _check_route_drops() -> void:
	for route in ["main", "hazard"]:
		var rule: Dictionary = {}
		for r in Settings.loot.data.values():
			if String(r.route) == route:
				rule = r
		if rule.is_empty():
			continue
		var cats: PackedStringArray = String(rule.category_pool).split("|", false)
		var count := int(rule.drop_count)
		var guarantee := int(rule.guarantee_rarity)
		var rarity_count := {}
		var count_ok := true
		var pool_ok := true
		var guarantee_ok := true
		var total := 0
		for i in SAMPLE:
			var pids: Array = Match.roll_route_drops(route)
			count_ok = count_ok and pids.size() == count
			for pid in pids:
				var p: Dictionary = Settings.part.data[pid]
				pool_ok = pool_ok and cats.has(String(p.category))
				guarantee_ok = guarantee_ok and int(p.rarity) >= guarantee
				rarity_count[int(p.rarity)] = int(rarity_count.get(int(p.rarity), 0)) + 1
				total += 1
		ok(count_ok, "%s 每次掉落 %d 件" % [route, count])
		ok(pool_ok, "%s 掉落类别均在 category_pool 内" % route)
		ok(guarantee_ok, "%s 掉落稀有度全部 >= 保底 %d" % [route, guarantee])
		var expect := _expected_shares(rule)
		var dist_ok := true
		var detail := ""
		for k in [1, 2, 3, 4]:
			var got := float(rarity_count.get(k, 0)) / float(total)
			if absf(got - float(expect[k])) > TOL:
				dist_ok = false
			detail += "r%d %.1f%%/%.1f%% " % [k, got * 100.0, float(expect[k]) * 100.0]
		ok(dist_ok, "%s 稀有度分布符合权重复算（实/期 %s容差 %.0f%%）" % [route, detail, TOL * 100.0])

## 独立复算各稀有度出现概率：权重抽稀有度（保底抬底）→ 类别均匀 → 类别内候选均匀（空池夹档）
func _expected_shares(rule: Dictionary) -> Dictionary:
	var w: PackedStringArray = String(rule.rarity_weights).split("|", false)
	var total_w := 0.0
	for s in w:
		total_w += float(s)
	var g := int(rule.guarantee_rarity)
	var cats: PackedStringArray = String(rule.category_pool).split("|", false)
	var final_p := [0.0, 0.0, 0.0, 0.0]
	for k in 4:
		if k + 1 < g:
			continue  # 低于保底的概率并入保底档
		var p := float(w[k]) / total_w
		if k + 1 == g:
			for j in g - 1:
				p += float(w[j]) / total_w
		final_p[k] = p
	var share := {1: 0.0, 2: 0.0, 3: 0.0, 4: 0.0}
	for k in 4:
		if final_p[k] <= 0.0:
			continue
		for c in cats:
			var pool: Array = _candidate_rarities(String(c), k + 1)
			for r in pool:
				share[int(r)] += final_p[k] / float(cats.size()) / float(pool.size())
	return share
