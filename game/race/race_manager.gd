class_name RaceManager
extends Node3D
## 单回合比赛总控：
## 搭建赛道 / 天气 / 掉落 / 参赛车（倒序发车位），
## 倒计时发车 → 实时排名 → 冲线判定 → 回合结算（奖励 + 下回合发车位）。
## 所有数值取自 Settings 配表。

signal countdown_tick(label: String)
signal race_started
signal loot_collected(part_id: int)
signal standings_updated(order: Array)
signal toast(text: String)
signal round_ended(results: Array, rewards: Array)

const TRACK_SCENE := preload("res://game/race/tracks/track_test.tscn")
const LOOT_SCENE := preload("res://game/race/loot_pickup.tscn")
const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const CAMERA_SCRIPT := preload("res://addons/gevp/scripts/camera.gd")
const ENGINE_SOUND := preload("res://addons/gevp/scenes/engine_sound.tscn")
const PLAYER_SCRIPT := preload("res://game/car/player_car.gd")
const AI_SCRIPT := preload("res://game/car/ai_racer.gd")

const PLAYER_COLOR := Color(1.0, 0.85, 0.2)
const AI_COLORS := [Color(1.0, 0.3, 0.35), Color(0.3, 0.55, 1.0), Color(0.35, 0.85, 0.45)]

var round_idx := 1
var map_id := 1
var weather := "sunny"
var racers: Array = []  # {name, is_player, vehicle, ctrl, finished, finish_time, progress}
var player_racer := {}
var track: Node3D
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
	weather = String(Match.map_cfg(map_id).weather)

	# --- 赛道 + 环境 ---
	track = TRACK_SCENE.instantiate()
	add_child(track)
	track.setup(weather)
	track.get_node("FinishGate").body_entered.connect(_on_finish_body)
	var we := WorldEnvironment.new()
	we.environment = WeatherEnv.make_env(weather)
	add_child(we)
	var sun := DirectionalLight3D.new()
	WeatherEnv.setup_light(sun, weather)
	add_child(sun)

	# --- 掉落 ---
	_spawn_loot()

	# --- 参赛车（含倒序发车位） ---
	_spawn_racers()

	# --- 相机跟随玩家 ---
	var cam := Camera3D.new()
	cam.set_script(CAMERA_SCRIPT)
	cam.follow_distance = 6.5
	cam.follow_height = 2.6
	cam.speed = 30.0
	add_child(cam)
	cam.global_position = player_racer.vehicle.global_position + Vector3(0, 3, 9)
	cam.follow_this = player_racer.vehicle

	# --- 倒计时（车辆冻结） ---
	countdown_left = Match.game_cfg("start_countdown")
	for r in racers:
		r.vehicle.freeze = true
	countdown_tick.emit(str(int(ceili(countdown_left))))

func _spawn_loot() -> void:
	for route in ["main", "hazard"]:
		var pids: Array = Match.roll_route_drops(route)
		var pts: Array = track.main_route_points(pids.size()) if route == "main" else track.hazard_route_points()
		for i in pids.size():
			var loot := LOOT_SCENE.instantiate()
			loot.position = pts[i % pts.size()]
			add_child(loot)
			loot.setup(pids[i], route)
			loot.collected.connect(_on_loot_collected)

func _spawn_racers() -> void:
	var grid := {}
	if Match.next_grid.is_empty():
		# 首回合默认：玩家杆位，AI 依次靠后
		grid[Match.PLAYER_NAME] = 1
		for i in Match.AI_DEFS.size():
			grid[Match.AI_DEFS[i].name] = i + 2
	else:
		grid = Match.next_grid.duplicate()
		var used := {}
		for g in grid.values():
			used[g] = true
		var free_no := 1
		for name_ in [Match.PLAYER_NAME] + Match.AI_DEFS.map(func(d): return d.name):
			if not grid.has(name_):
				while used.has(free_no):
					free_no += 1
				grid[name_] = free_no
				used[free_no] = true

	# 玩家
	var pstats := Match.get_stats()
	player_racer = _make_racer(Match.PLAYER_NAME, Match.car_id, pstats, grid[Match.PLAYER_NAME], 1.0, true)
	racers.append(player_racer)
	player_torque_applied = player_racer.vehicle.max_torque

	# AI（随机装配 1~2 件改件制造差异）
	for i in Match.AI_DEFS.size():
		var d: Dictionary = Match.AI_DEFS[i]
		var eq := {}
		var cats := ["engine", "tires", "aero", "chassis"]
		cats.shuffle()
		for cat in cats.slice(0, randi_range(1, 2)):
			eq[cat] = Match.roll_part(cat, 2)
		if randf() < 0.5:
			eq["tactical"] = Match.roll_part("tactical", 2)
		var skill: float = d.skill + randf_range(-0.02, 0.02)
		racers.append(_make_racer(d.name, d.car_id, Match.stats_for_car(d.car_id, eq), grid[d.name], skill, false, i))

func _make_racer(rname: String, cid: int, stats: Dictionary, grid_no: int, torque_scale: float, is_player: bool, ai_idx := 0) -> Dictionary:
	var root := Node3D.new()
	root.name = rname
	var v: Vehicle = CAR_SCENE.instantiate()
	var gpos := _grid_position(grid_no)
	root.position = gpos
	v.position = Vector3(0, 0.95, 0)
	CarBuilder.apply(v, Match.car_cfg(cid), stats, weather, torque_scale)
	CarMeshBuilder.attach_visual(v, cid)  # 美术装配，缺资源自动回退占位视觉
	root.add_child(v)
	add_child(root)
	CarBuilder.add_team_banner(v, PLAYER_COLOR if is_player else AI_COLORS[ai_idx % AI_COLORS.size()])

	# 注意：脚本必须在入树前附加，否则 _physics_process 不会被启用
	var ctrl := Node3D.new()
	ctrl.name = "Driver"
	if is_player:
		ctrl.set_script(PLAYER_SCRIPT)
	else:
		ctrl.set_script(AI_SCRIPT)
	root.add_child(ctrl)
	if is_player:
		v.add_to_group("player_car")
		ctrl.setup(v, self)
		var snd := ENGINE_SOUND.instantiate()
		snd.max_db = -16.0
		snd.vehicle = v  # engine_sound.gd 导出类型是 Vehicle 节点
		v.add_child(snd)
	else:
		ctrl.setup(v, gpos.x)
	return {"name": rname, "is_player": is_player, "vehicle": v, "ctrl": ctrl,
		"finished": false, "finish_time": 0.0, "progress": 0.0}

func _grid_position(grid_no: int) -> Vector3:
	var z := -6.0 + float(grid_no - 1) * 8.0
	var x := -3.5 if grid_no % 2 == 1 else 3.5
	return Vector3(x, 0, z)

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
		r.progress = -r.vehicle.global_position.z
		# 跌落保护：掉出赛道拉回主路
		if r.vehicle.global_position.y < -15.0:
			r.vehicle.global_position = Vector3(0, 1.2, r.vehicle.global_position.z)
			r.vehicle.linear_velocity = Vector3.ZERO
			r.vehicle.angular_velocity = Vector3.ZERO

	_standings_acc += delta
	if _standings_acc >= 0.5:
		_standings_acc = 0.0
		standings_updated.emit(compute_order())

	if race_time >= limit:
		_end_round()

func _on_finish_body(body: Node3D) -> void:
	for r in racers:
		if r.vehicle == body and not r.finished:
			r.finished = true
			r.finish_time = race_time
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
	var order := compute_order()
	var results: Array = []
	for i in order.size():
		var r: Dictionary = order[i]
		var rank := i + 1
		var entry := {"name": r.name, "is_player": r.is_player, "rank": rank,
			"time": r.finish_time if r.finished else -1.0, "dnf": not r.finished,
			"progress": r.progress}
		results.append(entry)
		# 倒序发车：名次越高，下回合发车位越靠后（RankReward 表）
		Match.next_grid[r.name] = Match.grid_for_rank(rank, racers.size())

	var player_rank := 1
	for e in results:
		if e.is_player:
			player_rank = e.rank
	var rewards: Array = Match.grant_rank_rewards(player_rank)
	Match.round_history.append(results)
	Match.roll_upcoming_map()
	# 决赛：结算第 1 名即总冠军（正常流程 = 第一个冲线者）
	if Match.round_cfg().is_final and Match.champion == "":
		Match.champion = String(results[0].name)
		toast.emit("CHAMPION: %s" % Match.champion)
	round_ended.emit(results, rewards)

## 火箭锁定：找前方最近车辆（隐身免锁定）
func find_target_ahead(from: Vehicle, range_m: float):
	var best = null
	var best_dz := 1e9
	for r in racers:
		if r.vehicle == from:
			continue
		var stealth := false
		if r.ctrl.has_method("is_stealth"):
			stealth = bool(r.ctrl.is_stealth())
		if stealth:
			continue
		var dz: float = from.global_position.z - r.vehicle.global_position.z
		if dz > 1.0 and dz <= range_m and dz < best_dz:
			best_dz = dz
			best = r
	return best

func _on_loot_collected(pid: int) -> void:
	Match.add_to_backpack(pid)
	loot_collected.emit(pid)
	var p := Match.part_cfg(pid)
	toast.emit("+ %s  [%s]" % [p.name, Match.RARITY_NAMES[int(p.rarity)]])

# ---------------- 测试辅助 ----------------

## 在玩家前方 25m 生成一个必经掉落（冒烟测试拾取验证）
func debug_spawn_loot_ahead() -> void:
	var loot := LOOT_SCENE.instantiate()
	var v: Vehicle = player_racer.vehicle
	loot.position = Vector3(v.global_position.x, 0.9, v.global_position.z - 25.0)
	add_child(loot)
	loot.setup(Match.roll_part("engine", 1), "main")
	loot.collected.connect(_on_loot_collected)

## 全部立即完赛（名次按当前进度交错），驱动回合结束
func debug_finish_all() -> void:
	if ended:
		return
	var order := compute_order()
	for i in order.size():
		if not order[i].finished:
			order[i].finished = true
			order[i].finish_time = race_time + 0.1 * i
	_end_round()
