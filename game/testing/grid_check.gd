extends Node
## headless 自检：倒序发车位（地图编辑器定义的满编 8 格网格 + RankReward 表格号直用）。
## 运行：godot --headless --path . res://game/testing/grid_check.tscn
## 覆盖：grid_for_rank 在满编网格上互异且倒序（第 1 名末位）、车数不足时后格留空
## 而非折叠（全员同格 = "第二小回合全部车辆生成在一个位置"的回归）、
## RoundResult.next_grid 落库互异、各地图 8 格发车格几何互异/在路面内/与表满编一致。

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[GRID] OK   | %s" % label)
	else:
		failures += 1
		print("[GRID] FAIL | %s" % label)

func _ready() -> void:
	print("========== GRID CHECK ==========")
	_check_grid_for_rank()
	_check_round_result()
	_check_map_grids()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[GRID] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

func _full_grid() -> int:
	var full := 0
	for rr in Settings.rank_reward.data.values():
		full = maxi(full, int(rr.grid_next))
	return full

# ---------------- 名次 -> 网格号映射 ----------------

func _check_grid_for_rank() -> void:
	var full := _full_grid()
	ok(full >= 2, "RankReward.grid_next 构成满编网格（max=%d）" % full)

	# 满编：名次 1..full 的格号互异（同格 = 下回合堆叠生成）
	var grids: Array = []
	for rank in full:
		grids.append(Match.grid_for_rank(rank + 1))
	var uniq := {}
	for g in grids:
		uniq[g] = true
	ok(uniq.size() == full, "满编 %d 车格号互异 %s" % [full, str(grids)])
	ok(Match.grid_for_rank(1) == full, "第 1 名发满编末位 %d 号" % full)

	# 回归样本：当前表 4 车制拿到 [8,7,6,5]（后 4 格），靠后格子空着、互不重叠
	var g4: Array = []
	for rank in 4:
		g4.append(Match.grid_for_rank(rank + 1))
	ok(str(g4) == str([8, 7, 6, 5]), "4 车占满编后 4 格 [8,7,6,5]（实际 %s）" % str(g4))

	# 表外名次兜底保持倒序语义（第 1 名 ≠ 杆位）
	var beyond := full + 1
	if not Settings.rank_reward.data.has(beyond):
		ok(Match.grid_for_rank(1) == full and Match.grid_for_rank(beyond) == 1,
				"表外名次兜底仍倒序（首名末位、末名杆位）")

# ---------------- 结算落库 ----------------

func _check_round_result() -> void:
	var order: Array = []
	var names := ["YOU", "RIVAL-1", "RIVAL-2", "RIVAL-3"]
	for i in names.size():
		var r := Racer.new()
		r.name = names[i]
		r.is_player = i == 0
		r.mark_finished(10.0 + float(i))   # 依次冲线：名次 = 数组序
		order.append(r)
	var res := RoundResult.build(order, false)
	var grids: Array = res.next_grid.values()
	var uniq := {}
	for g in grids:
		uniq[g] = true
	ok(res.next_grid.size() == 4, "next_grid 覆盖全部 4 名车手")
	ok(uniq.size() == 4, "next_grid 格号互异 %s（无同格堆叠）" % str(grids))
	ok(res.player_rank == 1, "玩家名次识别（P1）")
	ok(res.champion == "", "非决赛不产生冠军")
	var final := RoundResult.build(order, true)
	ok(final.champion == "YOU", "决赛冠军 = 累计积分最高（无历史分时 = 第 1 名）")

# ---------------- 地图发车格几何 ----------------

func _check_map_grids() -> void:
	var full := _full_grid()
	for mid in range(1, 5):
		var path := "res://game/race/tracks/data/map_%d.json" % mid
		if not FileAccess.file_exists(path):
			ok(false, "map_%d 缺少赛道数据 %s" % [mid, path])
			continue
		var td: TrackData = TrackData.load_json(path)
		if td == null:
			ok(false, "map_%d 赛道数据解析失败" % mid)
			continue
		var count := int(td.grid_cfg.get("count", 0))
		var col_gap := float(td.grid_cfg.get("col_gap", 7.0))
		ok(count >= full, "map_%d 发车格 %d ≥ 表满编 %d（表内格号都有实位）" % [mid, count, full])

		var min_dist := 1e9
		var all_apart := true
		var on_pavement := true
		for i in count:
			var pi: Vector3 = td.grid_position(i + 1)
			for j in range(i + 1, count):
				var d: float = pi.distance_to(td.grid_position(j + 1))
				min_dist = minf(min_dist, d)
				if d < col_gap * 0.5:
					all_apart = false
			var lat: Dictionary = td.main_lateral(pi)
			if float(lat["dist"]) >= float(lat["half"]):
				on_pavement = false
		ok(all_apart, "map_%d %d 格互异且最小间距 %.1fm ≥ col_gap/2（%.1fm）"
				% [mid, count, min_dist, col_gap * 0.5])
		ok(on_pavement, "map_%d 全部 %d 格都在路面内（发车引道覆盖最后排）" % [mid, count])

		var lanes := {}
		for gno in count:
			lanes[td.grid_lane(gno + 1)] = true
		ok(lanes.size() == 2, "map_%d AI 车道左右分布（%s）" % [mid, str(lanes.keys())])
