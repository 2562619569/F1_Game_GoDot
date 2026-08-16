class_name RaceManager
extends Node3D
## 单回合编排器：倒计时 → 竞速（弧长进度/实时排名/跌落保护）→ 冲线 → 结算。
## 职责拆分：世界装配在 RaceBuilder，结算数据在 RoundResult（由 Match.commit_round
## 提交全局状态），测试辅助在 RaceDebug。所有数值取自 Settings 配表。

signal countdown_tick(label: String)
signal race_started
signal loot_collected(part_id: int)
signal standings_updated(order: Array)
signal toast(text: String)
signal round_ended(results: Array, rewards: Array)

var round_idx := 1
var map_id := 1
var env_cfg := {}                      # 地图环境完整配置(WeatherEnv.load_map_env 产物)
var weather: WeatherEnv.Type = WeatherEnv.Type.SUNNY  # 预设枚举(env_cfg.preset 派生,兼容旧引用)
var racers: Array[Racer] = []
var player_racer: Racer = null
var track: Node3D
var track_data: TrackData = null  # 编辑器 JSON 赛道(为 null = 旧版 track_test 直线图)
var race_time := 0.0
var countdown_left := 0.0
var racing := false
var ended := false
var player_torque_applied := 0.0  # 测试观测：玩家车实际应用的扭矩

var _standings_acc := 0.0

func setup(idx: int) -> void:
	round_idx = idx
	Match.round_index = idx
	map_id = Match.upcoming_map_id
	env_cfg = WeatherEnv.load_map_env(map_id)  # 环境来自地图 env 文件，缺文件回退 SUNNY
	weather = WeatherEnv.id(String(env_cfg.preset))

	var out := RaceBuilder.build(self, map_id, _on_finish_body, _on_loot_collected)
	track = out.track
	track_data = out.track_data
	racers = out.racers
	player_racer = out.player_racer
	player_torque_applied = out.player_torque

	# --- 倒计时（车辆冻结） ---
	countdown_left = Match.game_cfg("start_countdown")
	for r in racers:
		r.vehicle.freeze = true
	countdown_tick.emit(str(int(ceili(countdown_left))))

# ---------------- 主循环 ----------------

func _physics_process(delta: float) -> void:
	if ended:
		return
	if countdown_left > 0.0:
		var prev := countdown_left
		countdown_left -= delta
		var prev_i := int(ceili(prev))
		var now_i := int(ceili(countdown_left))
		if now_i != prev_i:
			countdown_tick.emit(str(now_i) if now_i > 0 else "GO!")
		if countdown_left <= 0.0:
			racing = true
			race_started.emit()
			for r in racers:
				r.vehicle.freeze = false
				r.ctrl.frozen = false
		return
	if not racing:
		return

	race_time += delta
	var limit := float(Match.round_cfg().time_limit)
	for r in racers:
		if track_data != null:
			# 曲线赛道:弧长进度(索引作下次搜索 hint)
			var pr: Array = track_data.progress_at(r.vehicle.global_position, r.hint)
			r.progress = pr[0]
			r.hint = int(pr[1])
		else:
			r.progress = -r.vehicle.global_position.z
		# 跌落保护：掉出赛道拉回主路
		if r.vehicle.global_position.y < -15.0:
			var rp: Vector3 = track_data.reset_point(r.vehicle.global_position) if track_data != null else Vector3(0, 1.2, r.vehicle.global_position.z)
			r.recover_to(rp)

	_standings_acc += delta
	if _standings_acc >= 0.5:
		_standings_acc = 0.0
		standings_updated.emit(compute_order())

	if race_time >= limit:
		_end_round()

func _on_finish_body(body: Node3D) -> void:
	for r in racers:
		if r.vehicle == body and not r.finished:
			r.mark_finished(race_time)
			var order := compute_order()
			var pos := order.find(r) + 1
			toast.emit("%s finished  P%d  (%.1fs)" % [r.name, pos, race_time])
			standings_updated.emit(order)
			if racers.all(func(x): return x.finished):
				_end_round()
			return

# ---------------- 排名 / 结算 ----------------

func compute_order() -> Array:
	var arr := racers.duplicate()
	arr.sort_custom(func(a, b):
		if a.finished and b.finished:
			return a.finish_time < b.finish_time
		if a.finished != b.finished:
			return a.finished
		return a.progress > b.progress)
	return arr

func _end_round() -> void:
	if ended:
		return
	ended = true
	racing = false
	var res := RoundResult.build(compute_order(), bool(Match.round_cfg().is_final))
	var rewards: Array = Match.commit_round(res)
	if res.champion != "":
		toast.emit("CHAMPION: %s" % res.champion)
	round_ended.emit(res.results, rewards)

## 火箭锁定：找前方最近车辆（隐身免锁定）;前方 = 弧长进度领先
func find_target_ahead(from: Vehicle, range_m: float) -> Racer:
	var my_prog := 0.0
	for r in racers:
		if r.vehicle == from:
			my_prog = r.progress
			break
	var best: Racer = null
	var best_dp := 1e9
	for r in racers:
		if r.vehicle == from:
			continue
		var stealth := false
		if r.ctrl.has_method("is_stealth"):
			stealth = bool(r.ctrl.is_stealth())
		if stealth:
			continue
		var dp: float = r.progress - my_prog
		if dp > 1.0 and dp <= range_m and dp < best_dp:
			best_dp = dp
			best = r
	return best

func _on_loot_collected(pid: int) -> void:
	Match.add_to_backpack(pid)
	loot_collected.emit(pid)
	var p := Match.part_cfg(pid)
	toast.emit("+ %s  [%s]" % [p.name, Match.RARITY_NAMES[int(p.rarity)]])

# ---------------- HUD 只读接口 ----------------
## HUD 不直达 racers / vehicle / ctrl 内部结构，也不读 Match 配表，只走以下接口。

func race_info() -> Dictionary:
	var map := Match.map_cfg(map_id)
	return {
		"round_idx": round_idx, "round_count": Match.round_count(),
		"map_name": String(map.name),
		"weather_label": String(env_cfg.get("label", "Sunny")),
	}

func player_speed_kmh() -> int:
	return roundi(player_racer.vehicle.speed * 3.6)

func player_gear() -> int:
	return maxi(0, player_racer.vehicle.current_gear)

func time_limit_s() -> float:
	return float(Match.round_cfg().time_limit)

func player_tactical_ui() -> Array:
	return player_racer.ctrl.tactical_ui()
