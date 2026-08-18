class_name RoundResult
extends RefCounted
## 回合结算的纯数据：最终成绩 / 玩家名次 / 下回合发车位 / 冠军。
## build() 为纯函数（只读 RankReward 配表，不写任何全局状态），
## 未来联机化或独立结算系统可直接复算/序列化本结构。

var results: Array = []  # 按名次 [{name, is_player, rank, time, dnf, progress}]
var player_rank := 1
var next_grid := {}      # racer name -> 下回合发车位（倒序发车）
var champion := ""       # 决赛第 1 名；非决赛为空

static func build(order: Array, is_final: bool) -> RoundResult:
	var res := RoundResult.new()
	var count := order.size()
	for i in count:
		var r: Racer = order[i]
		var rank := i + 1
		res.results.append({
			"name": r.name, "is_player": r.is_player, "rank": rank,
			"time": r.finish_time if r.finished else -1.0, "dnf": not r.finished,
			"progress": r.progress,
		})
		# 倒序发车：名次越高，下回合发车位越靠后（RankReward 表格号 = 地图 8 格网格）
		res.next_grid[r.name] = Match.grid_for_rank(rank)
		if r.is_player:
			res.player_rank = rank
	if is_final:
		res.champion = String(res.results[0].name)
	return res
