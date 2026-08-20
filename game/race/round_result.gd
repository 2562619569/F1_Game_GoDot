class_name RoundResult
extends RefCounted
## 回合结算的纯数据：最终成绩 / 玩家名次 / 本回合积分 / 下回合发车位 / 冠军。
## build() 为纯函数（只读 RankReward / Round 配表与传入的历史积分，不写任何全局状态），
## 未来联机化或独立结算系统可直接复算/序列化本结构。

var results: Array = []  # 按名次 [{name, is_player, rank, time, dnf, progress, points}]
var player_rank := 1
var points := {}         # racer name -> 本回合积分（Round 表 points 列按名次）
var standings := []      # 决赛累计积分总排名 [{name, is_player, total, rank}]；非决赛为空
var next_grid := {}      # racer name -> 下回合发车位（倒序发车）
var champion := ""       # 决赛累计积分最高者（平分看决赛名次）；非决赛为空

## prior_points：结算前各车手累计积分（Match.points 快照）。
## 冠军不再由决赛名次单独决定：每回合按 Round 表积分累计，决赛行配高额
## 前倾分布（如 12|8|4|0），前面的回合落后也保有翻盘空间。
static func build(order: Array, is_final: bool, prior_points := {}) -> RoundResult:
	var res := RoundResult.new()
	var count := order.size()
	var totals := {}
	for i in count:
		var r: Racer = order[i]
		var rank := i + 1
		var pts := Match.round_points_for(rank)
		res.results.append({
			"name": r.name, "is_player": r.is_player, "rank": rank,
			"time": r.finish_time if r.finished else -1.0, "dnf": not r.finished,
			"progress": r.progress, "points": pts,
		})
		res.points[r.name] = pts
		totals[r.name] = int(prior_points.get(r.name, 0)) + pts
		# 倒序发车：名次越高，下回合发车位越靠后（RankReward 表格号 = 地图 8 格网格）
		res.next_grid[r.name] = Match.grid_for_rank(rank)
		if r.is_player:
			res.player_rank = rank
	if is_final:
		# 累计积分定总冠军；平分时决赛名次靠前者胜（决赛高分本身即翻盘来源，
		# 平分再让当场表现定序，全程规则可解释）
		for i in count:
			var r: Racer = order[i]
			res.standings.append({
				"name": r.name, "is_player": r.is_player,
				"total": int(totals[r.name]), "rank": 0, "round_rank": i + 1,
			})
		res.standings.sort_custom(func(a, b):
			if int(a.total) != int(b.total):
				return int(a.total) > int(b.total)
			return int(a.round_rank) < int(b.round_rank))
		for i in res.standings.size():
			res.standings[i]["rank"] = i + 1
		res.champion = String(res.standings[0].name)
	return res
