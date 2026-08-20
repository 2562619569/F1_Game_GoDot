extends Node
## headless 自检：积分制总冠军（Round 表 points 列 + RoundResult / Match 积分链路）。
## 运行：godot --headless --path . res://game/testing/points_check.tscn
## 覆盖：配表积分列合法性（非负 / 决赛加码 / 翻盘代数成立）、名次→积分取值
## （超界 0 分）、RoundResult 按名次记分、决赛冠军 = 累计积分最高
## （翻盘成立 / 差距过大翻不动 / 平分决赛名次靠前）、commit_round 跨回合累计。

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[PTS] OK   | %s" % label)
	else:
		failures += 1
		print("[PTS] FAIL | %s" % label)

func _ready() -> void:
	print("========== POINTS CHECK ==========")
	_check_config()
	_check_points_for()
	_check_round_result()
	_check_comeback()
	_check_commit_accumulate()
	Match.reset()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[PTS] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

## 依次冲线的车手数组（名次 = 数组序）
func _racers(names: Array) -> Array:
	var order: Array = []
	for i in names.size():
		var r := Racer.new()
		r.name = names[i]
		r.is_player = names[i] == Match.PLAYER_NAME
		r.mark_finished(10.0 + float(i))
		order.append(r)
	return order

# ---------------- 配表 ----------------

func _check_config() -> void:
	var ok_rows := true
	var final_p1 := -1
	var normal_p1 := -1
	var normal_last := 0
	for row in Settings.round.data.values():
		var pts: Array = row.points
		if pts.is_empty():
			ok_rows = false
			continue
		for v in pts:
			if int(v) < 0:
				ok_rows = false
		if row.is_final:
			final_p1 = int(pts[0])
		else:
			normal_p1 = int(pts[0])
			normal_last = int(pts[pts.size() - 1])
	ok(ok_rows, "Round.points 每行非空且积分非负")
	ok(final_p1 > normal_p1 and final_p1 > 0,
			"决赛 P1 积分加码（%d > 常规 %d）" % [final_p1, normal_p1])
	# 翻盘代数：前面回合全垫底（最大分差 = (round_count-1)×(P1-末位)），
	# 决赛夺冠仍能反超 → 决赛 P1 分必须补得回最大分差
	var max_deficit := (Match.round_count() - 1) * (normal_p1 - normal_last)
	ok(final_p1 - normal_last > max_deficit,
			"全垫底者决赛夺冠可翻盘（决赛分差 %d > 前序最大分差 %d）"
			% [final_p1 - normal_last, max_deficit])

# ---------------- 名次 -> 积分取值 ----------------

func _check_points_for() -> void:
	Match.round_index = 1
	var p1: Array = Settings.round.data[1].points
	ok(Match.round_points_for(1) == int(p1[0]), "P1 积分取表首值（%d）" % int(p1[0]))
	ok(Match.round_points_for(0) == 0, "非法名次 0 → 0 分")
	ok(Match.round_points_for(p1.size() + 1) == 0, "名次超表长（%d）→ 0 分" % (p1.size() + 1))
	var pf: Array = Settings.round.data[Match.round_count()].points
	ok(Match.round_points_for(1, Match.round_count()) == int(pf[0]),
			"决赛行按回合号取值（P1 = %d）" % int(pf[0]))

# ---------------- RoundResult 记分 ----------------

func _check_round_result() -> void:
	Match.round_index = 1
	var order := _racers(["YOU", "RIVAL-1", "RIVAL-2", "RIVAL-3"])
	var res := RoundResult.build(order, false)
	var ok_pts := true
	for i in res.results.size():
		if int(res.results[i].points) != Match.round_points_for(i + 1):
			ok_pts = false
	ok(ok_pts, "results 条目按名次记分（%s）" % str(res.results.map(func(e): return int(e.points))))
	ok(res.points.size() == order.size(), "points 字典覆盖全部车手")
	ok(res.champion == "" and res.standings.is_empty(), "非决赛不产生冠军与总排名")

# ---------------- 决赛冠军 = 累计积分 ----------------

func _check_comeback() -> void:
	Match.round_index = Match.round_count()
	# 翻盘成立：RIVAL-1 三连胜积 9 分，YOU 全垫底 0 分；决赛 YOU P1 / RIVAL-1 垫底
	var order := _racers(["YOU", "RIVAL-2", "RIVAL-3", "RIVAL-1"])
	var res := RoundResult.build(order, true, {"YOU": 0, "RIVAL-1": 9})
	ok(res.champion == "YOU", "翻盘：0 分落后者决赛夺冠反超（12 > 9）")
	ok(int(res.standings[0].total) == 12 and int(res.standings[0].rank) == 1,
			"standings 按累计积分排序（榜首 %s）" % String(res.standings[0].name))
	# 翻不动：分差超过决赛可追回的额度
	var res2 := RoundResult.build(order, true, {"YOU": 0, "RIVAL-1": 13})
	ok(res2.champion == "RIVAL-1", "差距过大翻不动（13 > 决赛 12）")
	# 平分 tie-break：总分相同，决赛名次靠前者胜
	var order2 := _racers(["RIVAL-1", "YOU", "RIVAL-2", "RIVAL-3"])
	var res3 := RoundResult.build(order2, true, {"YOU": 8, "RIVAL-1": 4})
	ok(res3.champion == "RIVAL-1", "总分平分（16:16）时决赛名次靠前胜")

# ---------------- commit_round 跨回合累计 ----------------

func _check_commit_accumulate() -> void:
	Match.reset()
	Match.round_index = 1
	Match.commit_round(RoundResult.build(_racers(["YOU", "RIVAL-1", "RIVAL-2", "RIVAL-3"]), false))
	Match.round_index = 2
	Match.commit_round(RoundResult.build(_racers(["RIVAL-1", "YOU", "RIVAL-2", "RIVAL-3"]), false))
	ok(int(Match.points.get("YOU", -1)) == Match.round_points_for(1, 1) + Match.round_points_for(2, 2),
			"YOU 两回合累计积分正确（%d）" % int(Match.points.get("YOU", -1)))
	ok(Match.points.size() == 4, "累计积分覆盖全部 4 名车手")
	ok(int(Match.round_history[1][0].points) == Match.round_points_for(1, 2),
			"round_history 条目带本回合积分")
	ok(Match.champion == "", "非决赛提交不产生冠军")
