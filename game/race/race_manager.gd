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
signal player_finished(rank: int, finish_time: float)
signal round_ended(results: Array, rewards: Array)

var round_idx := 1
var map_id := 1
var env_cfg := {}                      # 地图环境完整配置(WeatherEnv.load_map_env 产物)
var weather: WeatherEnv.Type = WeatherEnv.Type.SUNNY  # 预设枚举(env_cfg.preset 派生,兼容旧引用)
var racers: Array[Racer] = []
var player_racer: Racer = null
var track: Node3D
var track_data: TrackData = null  # 编辑器 JSON 赛道(为 null = 旧版 track_test 直线图)
var chase_camera: Camera3D = null  # 追尾相机（车库过渡交接用）
var env_node: WorldEnvironment = null  # 比赛环境（车库过渡的环境插值目标）
var race_time := 0.0
var countdown_left := 0.0
var countdown_hold := false        # 车库→赛道相机过渡期挂起倒计时（车保持冻结）
var racing := false
var ended := false
var player_torque_applied := 0.0  # 测试观测：玩家车实际应用的扭矩

var _standings_acc := 0.0

func setup(idx: int, hold_countdown := false) -> void:
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
	chase_camera = out.camera
	env_node = out.env_node
	if track_data != null:
		# R 倒转检查点：地图加载后按配表间隔沿主路生成
		track_data.build_checkpoints(Match.game_cfg("checkpoint_interval"))

	# --- 倒计时（只冻结车辆控制；车体出生抬高后已自由落地静置，不再冻结锚固） ---
	countdown_hold = hold_countdown
	countdown_left = Match.game_cfg("start_countdown")
	if not countdown_hold:
		countdown_tick.emit(str(int(ceili(countdown_left))))

## 车库→赛道过渡完成后放行倒计时（首个 tick 补发，HUD 计数不缺拍）
func begin_countdown() -> void:
	if not countdown_hold or racing or ended:
		return
	countdown_hold = false
	countdown_tick.emit(str(int(ceili(countdown_left))))

## 发车落地等待：出生抬高（RaceBuilder.SPAWN_DROP）的车靠悬挂自由沉降，
## 全部车接地且近乎静止后返回。车库过渡的起始机位须按落定位取——
## 飞行全程两层画面里的车才锁得住。超时兜底放行不阻塞流程；
## 落地后不锚固，车全程以物理静置在发车位上。
const GRID_SETTLE_SEC := 3.0
const GRID_SETTLE_CALM_FRAMES := 10

func settle_grid() -> void:
	var calm := 0
	var t := 0.0
	while t < GRID_SETTLE_SEC and calm < GRID_SETTLE_CALM_FRAMES:
		var still := true
		for r in racers:
			if r.vehicle.get_wheel_contact_count() < 3 or r.vehicle.linear_velocity.length() > 0.3:
				still = false
				break
		calm = calm + 1 if still else 0
		await get_tree().physics_frame
		t += get_physics_process_delta_time()

# ---------------- 主循环 ----------------

func _physics_process(delta: float) -> void:
	if ended:
		return
	if countdown_hold:
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
				r.ctrl.frozen = false
				# 静置超时的车会休眠且 apply_force 不唤醒（同 rewind_to），GO 须显式唤醒
				r.vehicle.sleeping = false
		return
	if not racing:
		return

	race_time += delta
	var limit := float(Match.round_cfg().time_limit)
	var rewind_ghost_sec := float(Match.game_cfg("rewind_ghost_sec"))
	for r in racers:
		if track_data != null:
			# 曲线赛道:弧长进度(索引作下次搜索 hint)
			var pr: Array = track_data.progress_at(r.vehicle.global_position, r.hint)
			r.progress = pr[0]
			r.hint = int(pr[1])
			r.update_checkpoints(track_data)
		else:
			r.progress = -r.vehicle.global_position.z
		# 跌落保护：掉出赛道拉回主路并给幽灵（复位点可能有车流经过）
		if r.vehicle.global_position.y < -15.0:
			var rp: Vector3 = track_data.reset_point(r.vehicle.global_position) if track_data != null else Vector3(0, 1.2, r.vehicle.global_position.z)
			r.recover_to(rp)
			r.ghost_left = maxf(r.ghost_left, rewind_ghost_sec)
			r.apply_ghost(true)
		# 幽灵计时：半透明 + 无车-车碰撞；到期时若与其他车仍重叠（幽灵期间
		# 对方可穿行甚至停进幽灵车位），推迟恢复实体，避免穿透求解把双方弹飞
		if r.ghost_left > 0.0:
			r.ghost_left -= delta
			if r.ghost_left <= 0.0:
				if _ghost_blocked(r):
					r.ghost_left = 0.1  # 仍在重叠：续幽灵，分离后下一轮到期再恢复
				else:
					r.apply_ghost(false)
			else:
				r.apply_ghost(true)

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
			if r.is_player:
				player_finished.emit(pos, race_time)
				# 玩家冲线即结束本回合；未冲线的 AI 按当前进度记为 DNF，
				# 不再让玩家等待整场队列跑完才进入改装。
				_end_round()
				return
			if racers.all(func(x): return x.finished):
				_end_round()
			return

## R 倒转复位：限速闸门（Game 表 rewind_speed_limit，m/s）+ 未冲线 +
## 有检查点数据才放行；复位到已通过的最后一个检查点并进入幽灵
## （半透明 + 无车-车碰撞 rewind_ghost_sec 秒，穿车流复位不被撞飞）。
func rewind_player() -> void:
	if player_racer == null or track_data == null or track_data.checkpoints.is_empty():
		return
	if not racing or player_racer.finished:
		return
	if player_racer.vehicle.speed >= Match.game_cfg("rewind_speed_limit"):
		toast.emit("REWIND: slow down first (< %d m/s)" % int(Match.game_cfg("rewind_speed_limit")))
		return
	var cp := player_racer.cp_reached
	player_racer.rewind_to(track_data.checkpoint_pose(cp))
	player_racer.ghost_left = maxf(player_racer.ghost_left, float(Match.game_cfg("rewind_ghost_sec")))
	player_racer.apply_ghost(true)
	toast.emit("REWIND -> CP%d" % cp)

## 幽灵退出前的重叠探测：以略小于车壳的盒在车位查询其他车体。
## 幽灵车自身无碰撞、随时可驶离，重叠方驶开或幽灵车移开都会解除，不会死锁
func _ghost_blocked(r: Racer) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.6, 1.2, 3.8)
	q.shape = box
	q.transform = r.vehicle.global_transform
	q.collision_mask = Racer.LAYER_CAR
	q.exclude = [r.vehicle.get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 4).size() > 0

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

func player_rpm() -> float:
	return player_racer.vehicle.motor_rpm

func player_max_rpm() -> float:
	return player_racer.vehicle.max_rpm

func time_limit_s() -> float:
	return float(Match.round_cfg().time_limit)

func player_tactical_ui() -> Array:
	return player_racer.ctrl.tactical_ui()
