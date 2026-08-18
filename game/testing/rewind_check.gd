extends Node
## headless 自检：R 倒转（检查点生成 / 限速闸门 / 传送姿态 / 幽灵分层 / 跌落保护共享幽灵）。
## 运行：godot --headless --path . res://game/testing/rewind_check.tscn
## 覆盖：
## 1. Game 表三键（checkpoint_interval / rewind_speed_limit / rewind_ghost_sec）+ 输入映射；
## 2. TrackData.build_checkpoints 在 map_1~4 上：首点=起点线、间隔精确、尾缘余量、
##    严格递增、复位落点在路面内、零间隔守卫、幂等重建；
## 3. 真实回合世界集成：碰撞层约定（车=车层|检测层、mask=世界|车；终点门/掉落物只认
##    检测层——幽灵复位中冲线/拾取不失效）、倒计时拒绝、超速拒绝、低速传送
##    （位置/姿态/速度清零/hint 作废）、检查点推进记账、幽灵间隔像素抖纹与分层到时恢复、
##    冲线后拒绝、跌落保护同样给幽灵。

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[REWIND] OK   | %s" % label)
	else:
		failures += 1
		print("[REWIND] FAIL | %s" % label)

func until(pred: Callable, timeout := 10.0) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return pred.call()

func _ready() -> void:
	print("========== REWIND CHECK ==========")
	_check_config()
	_check_track_checkpoints()
	await _check_race_integration()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[REWIND] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

# ---------------- 配表与输入 ----------------

func _check_config() -> void:
	ok(Match.game_cfg("checkpoint_interval") == 100.0, "Game.checkpoint_interval = 100m")
	ok(Match.game_cfg("rewind_speed_limit") == 20.0, "Game.rewind_speed_limit = 20 m/s")
	ok(Match.game_cfg("rewind_ghost_sec") == 5.0, "Game.rewind_ghost_sec = 5s")
	ok(InputMap.has_action("Rewind"), "输入映射存在 Rewind 动作（R 键）")

# ---------------- 检查点几何（纯 TrackData） ----------------

func _check_track_checkpoints() -> void:
	for mid in range(1, 5):
		var path := "res://game/race/tracks/data/map_%d.json" % mid
		if not FileAccess.file_exists(path):
			ok(false, "map_%d 缺少赛道数据 %s" % [mid, path])
			continue
		var td: TrackData = TrackData.load_json(path)
		if td == null:
			ok(false, "map_%d 赛道数据解析失败" % mid)
			continue
		td.build_checkpoints(100.0)
		var cps: PackedFloat32Array = td.checkpoints
		ok(cps.size() >= 2, "map_%d 生成 %d 个检查点（含起点线）" % [mid, cps.size()])

		var s0: float = td.main["s_arr"][td.start_idx]
		ok(absf(cps[0] - s0) < 0.01, "map_%d CP0 = 起点线采样(%.1f)" % [mid, cps[0]])

		var spacing_ok := true
		var on_pavement := true
		for i in cps.size():
			if i > 0 and absf(cps[i] - cps[i - 1] - 100.0) > 0.01:
				spacing_ok = false
			var lat: Dictionary = td.main_lateral(td.checkpoint_pose(i)["pos"])
			if float(lat["dist"]) >= float(lat["half"]):
				on_pavement = false
		ok(spacing_ok, "map_%d 检查点间隔精确 100m 且严格递增" % mid)
		ok(on_pavement, "map_%d 全部复位落点在路面内" % mid)
		ok(cps[cps.size() - 1] < td.length, "map_%d 末检查点在终点前(%.1f < %.1f)" % [mid, cps[cps.size() - 1], td.length])

		# 守卫与幂等：零间隔清空；50m 重建变密；100m 重建还原
		td.build_checkpoints(0.0)
		ok(td.checkpoints.is_empty() and td.checkpoint_pose(0).is_empty(), "map_%d 零间隔守卫（无检查点时姿态返回空）" % mid)
		td.build_checkpoints(50.0)
		var n50 := td.checkpoints.size()
		td.build_checkpoints(100.0)
		ok(n50 > td.checkpoints.size() and td.checkpoints.size() == cps.size(), "map_%d 幂等重建（50m %d 个 → 100m %d 个）" % [mid, n50, td.checkpoints.size()])

# ---------------- 真实回合世界集成 ----------------

func _check_race_integration() -> void:
	Match.upcoming_map_id = 1
	var race := RaceManager.new()
	add_child(race)
	race.setup(1)
	var td: TrackData = race.track_data
	var pr: Racer = race.player_racer
	var pv: Vehicle = pr.vehicle

	# 装配注入：RaceManager.setup 按配表间隔生成
	ok(td.checkpoints.size() >= 2, "回合装配自动生成检查点(%d 个)" % td.checkpoints.size())

	# 碰撞层约定：车=车层|检测层、mask=世界|车；终点门只认检测层
	var layers_ok := true
	for r in race.racers:
		if r.vehicle.collision_layer != Racer.CAR_LAYER or r.vehicle.collision_mask != Racer.CAR_MASK:
			layers_ok = false
	ok(layers_ok, "全部赛车 layer=%d mask=%d（撞世界也撞车）" % [Racer.CAR_LAYER, Racer.CAR_MASK])
	ok((race.track.get_node("FinishGate") as Area3D).collision_mask == Racer.LAYER_CAR_DETECT,
			"终点门只认车辆检测层（幽灵冲线不失效）")

	# 掉落物 Area 同样只认检测层（幽灵中拾取不失效）
	RaceDebug.spawn_loot_ahead(race)
	var loot := race.get_child(race.get_child_count() - 1) as Area3D
	ok(loot != null and loot.collision_mask == Racer.LAYER_CAR_DETECT, "掉落物只认车辆检测层")

	# 倒计时中拒绝
	var spawn_pos := pv.global_position
	race.rewind_player()
	ok(pv.global_position.distance_to(spawn_pos) < 0.01 and pr.ghost_left == 0.0, "倒计时中拒绝倒转")

	await until(func(): return race.racing, 10.0)
	ok(race.racing, "GO 发车")
	# 冻结 AI 车流：玩家全程静止测试，避免 AI 追尾干扰速度/位置断言
	for r in race.racers:
		if not r.is_player:
			r.vehicle.freeze = true

	# 低速倒转（起步静止）→ 记账 CP3 并传送：CP3 在主路中段，远离起点线引道
	# 接缝（该处几何在并行迭代中不稳定），后续速度/姿态断言都在稳定路面进行。
	# 等残速衰减：出生网格与并行重烘焙路面互嵌时，GO 解冻瞬间求解器会弹出
	# 冲量（实测初速 ~24 m/s，数帧内衰减），until 等待而非固定帧数
	pv.linear_velocity = Vector3.ZERO
	pv.angular_velocity = Vector3.ZERO
	await until(func(): return pv.speed < 20.0, 5.0)
	pr.progress = td.checkpoints[3] + 1.0
	pr.update_checkpoints(td)
	ok(pr.cp_reached == 3, "检查点记账推进到 3（只进不退）")
	var mat_before := _first_effective_material(pv)
	race.rewind_player()
	var pose3: Dictionary = td.checkpoint_pose(3)
	ok(pv.global_position.distance_to(pose3["pos"]) < 3.0, "倒转传送回 CP3")
	ok(pr.ghost_left > 4.9, "幽灵计时启动(%.1fs)" % pr.ghost_left)
	ok(pv.collision_layer == Racer.LAYER_CAR_DETECT and pv.collision_mask == Racer.LAYER_WORLD,
			"幽灵分层：仅检测层 + 只撞世界（无车-车碰撞）")
	var mat_during: Material = _first_effective_material(pv)
	ok(mat_during != null and GhostStipple.is_stippled(mat_during) and mat_during != mat_before,
			"幽灵间隔像素抖纹（保留原色，材质换为抖纹变体）")
	ok(pr.hint == -1, "进度搜索 hint 已作废（下次全局重搜）")

	# 幽灵保护下超速闸门：CP3 路面中心 + AI 冻结 + 无车-车碰撞，速度读数稳定
	pv.linear_velocity = pv.global_transform.basis * Vector3(0, 0, -30.0)
	for i in 3:
		await get_tree().physics_frame
	ok(pv.speed > 20.0, "超速工况建立(%.1f m/s)" % pv.speed)
	var pos_fast := pv.global_position
	race.rewind_player()
	ok(pv.global_position.distance_to(pos_fast) < 0.5 and pr.ghost_left > 0.0,
			"速度 ≥ %.0f m/s 拒绝倒转（幽灵状态不受影响）" % Match.game_cfg("rewind_speed_limit"))

	# 歪斜姿态后再次低速倒转：位置 + 朝向 + 横纵姿态复位
	pv.linear_velocity = Vector3.ZERO
	pv.angular_velocity = Vector3.ZERO
	await until(func(): return pv.speed < 20.0, 5.0)
	pv.global_rotation = Vector3(0.4, float(pose3["yaw"]) + PI * 0.5, -0.3)
	race.rewind_player()
	ok(pv.global_position.distance_to(pose3["pos"]) < 3.0, "再次倒转传送回 CP3")
	var yaw_err := absf(angle_difference(pv.global_rotation.y, float(pose3["yaw"])))
	ok(yaw_err < 0.05 and absf(pv.global_rotation.x) < 0.01 and absf(pv.global_rotation.z) < 0.01,
			"姿态复位（横滚/俯仰清零，车头对齐切线，误差 %.3f rad）" % yaw_err)

	# 幽灵到时恢复碰撞与材质现场：physics_frame 信号先于本帧 _physics_process 回调，
	# 从 process 上下文切入会少计一拍，留 6 帧余量（0.02s 到期 + restore）
	pr.ghost_left = 0.02
	for i in 6:
		await get_tree().physics_frame
	ok(pr.ghost_left <= 0.0 and pv.collision_layer == Racer.CAR_LAYER and pv.collision_mask == Racer.CAR_MASK,
			"幽灵到期恢复碰撞层")
	ok(_first_effective_material(pv) == mat_before, "幽灵到期恢复原材质（抖纹变体撤下）")

	# 到期时与他车重叠：推迟退出幽灵（防穿透求解把双方弹飞），分离后才恢复
	pr.ghost_left = 1.0
	pr.apply_ghost(true)
	var blocker: Vehicle = null
	for r in race.racers:
		if not r.is_player:
			blocker = r.vehicle
			break
	blocker.global_position = pv.global_position + Vector3(0.6, 0.0, 0.3)
	pr.ghost_left = 0.02
	for i in 8:
		await get_tree().physics_frame
	ok(pr.ghost_left > 0.0 and pv.collision_layer == Racer.LAYER_CAR_DETECT,
			"到期时与他车重叠：推迟退出幽灵(ghost=%.2f)" % pr.ghost_left)
	blocker.global_position += Vector3(30.0, 0.0, 0.0)
	for i in 24:
		await get_tree().physics_frame
	ok(pr.ghost_left <= 0.0 and pv.collision_layer == Racer.CAR_LAYER,
			"重叠分离后幽灵恢复实体")

	# 冲线后拒绝
	pr.mark_finished(race.race_time)
	pv.linear_velocity = Vector3.ZERO
	for i in 2:
		await get_tree().physics_frame
	var pos_fin := pv.global_position
	race.rewind_player()
	ok(pv.global_position.distance_to(pos_fin) < 0.5 and pr.ghost_left <= 0.0, "冲线后拒绝倒转")
	pr.finished = false

	# 跌落保护：拉回主路并同样给幽灵
	pv.global_position.y = -20.0
	for i in 3:
		await get_tree().physics_frame
	ok(pv.global_position.y > -1.0, "跌落拉回主路(y=%.1f)" % pv.global_position.y)
	ok(pr.ghost_left > 0.0 and pv.collision_layer == Racer.LAYER_CAR_DETECT
			and GhostStipple.is_stippled(_first_effective_material(pv)), "跌落保护同样进入幽灵（抖纹生效）")
	pr.ghost_left = 0.02
	for i in 6:
		await get_tree().physics_frame
	ok(pv.collision_layer == Racer.CAR_LAYER, "跌落幽灵到期恢复")
	ok(not GhostStipple.is_stippled(_first_effective_material(pv)), "跌落幽灵到期抖纹撤下")

## 与 GhostStipple.apply 同规则的取材：树序首个网格的有效材质
## （material_override → 表面 override → GLB 内置表面材质），无网格返回 null
func _first_effective_material(root: Node3D) -> Material:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		if mi.material_override != null:
			return mi.material_override
		for i in mi.mesh.get_surface_count():
			var m: Material = mi.get_surface_override_material(i)
			if m == null:
				m = mi.mesh.surface_get_material(i)
			if m != null:
				return m
	return null
