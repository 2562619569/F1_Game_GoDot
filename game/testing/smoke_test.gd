extends Node
## 完整循环冒烟测试（无人工操作）：
## 大厅 → 创建房间(邀请界面) → PLAY → 选车 → 回合1（发车/行驶/拾取）
## → 局间整备（结算/奖励/改装/雷达图）→ 回合2（验证改装物理生效）
## → 快速跑完 4 回合 → 决赛冠军 → 返回大厅。
##
## 运行方式：以本场景启动游戏即可（编辑器 F6 或命令行）。

var checks := 0
var failures := 0
var main: Node

func _ready() -> void:
	_run()

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[SMOKE] OK   | %s" % label)
	else:
		failures += 1
		print("[SMOKE] FAIL | %s" % label)

func until(pred: Callable, timeout := 15.0) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return pred.call()

func _run() -> void:
	print("========== ModRacer SMOKE TEST START ==========")
	Engine.time_scale = 3.0               # 3 倍速推进（物理仍 60Hz，断言按游戏时间）
	Match.auto_test = true                 # 玩家车自动驾驶
	Match.intermission_sec_override = 999.0  # 局间不自动跳转，由测试驱动

	main = preload("res://game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame

	# ---- 1. 大厅 ----
	ok(main.current_ui != null and main.current_ui.name == "Lobby", "lobby shown on start")
	ok(main.current_ui.create_room_btn != null, "lobby has CREATE ROOM button")
	main.current_ui.create_room_btn.pressed.emit()
	await get_tree().process_frame

	# ---- 2. 邀请界面 ----
	ok(main.current_ui.name == "RoomInvite", "create room -> invite screen")
	ok(main.current_ui.room_code_label.text.length() > 8, "room code shown: %s" % main.current_ui.room_code_label.text)

	# ---- 3. PLAY → 选车 ----
	main.current_ui.play_btn.pressed.emit()
	await get_tree().process_frame
	ok(main.current_ui.name == "CarSelect", "play -> car select")
	ok(main.current_ui.card_buttons.size() == 3, "3 chassis switch buttons from Car table")
	ok(main.current_ui.get_node_or_null("CarStage") != null, "car select embeds 3D car stage")

	# ---- 4. 选车 → 回合1（先切到底盘 601 预览，再确认） ----
	main.current_ui.card_buttons[0].pressed.emit()
	await get_tree().process_frame
	ok(main.current_ui.stage.current_car_id == 601, "chassis button previews 601 on stage")
	main.current_ui.confirm_btn.pressed.emit()
	await get_tree().process_frame
	ok(main.race != null and main.race.round_idx == 1, "round 1 started")
	ok(main.current_ui == null, "car select UI hidden during race")
	ok(main.race.countdown_hold, "garage->race seamless transition holds countdown")
	ok(main.race.racers.size() == 4, "4 racers on grid (1 player + 3 AI)")
	var pv: Vehicle = main.race.player_racer.vehicle
	ok(pv.is_in_group("player_car"), "player car in player_car group")
	var torque_r1: float = main.race.player_torque_applied
	ok(torque_r1 > 100.0, "Car table physics applied (torque=%.0f NM)" % torque_r1)
	ok(main.hud != null, "race HUD bound")

	# ---- 4.5 发车落地：出生抬高（SPAWN_DROP）自由沉降，不冻结不锚固 ----
	var grounded := await until(func():
		for r in main.race.racers:
			if r.vehicle.get_wheel_contact_count() < 4:
				return false
		return true, 8.0)
	ok(grounded, "all racers settled on grid (4/4 wheel contact, physics live)")
	ok(not pv.freeze, "no freeze/anchor after spawn (cars rest on suspension)")

	# ---- 5. 倒计时 → GO → 物理运转（落地 + 过渡 + 倒计时，留足余量） ----
	await until(func(): return main.race.racing, 12.0)
	ok(main.race.racing, "countdown done, race live")
	await get_tree().create_timer(4.0).timeout
	ok(pv.speed > 3.0, "player vehicle physically moving (%.1f m/s)" % pv.speed)
	var ai_moved := false
	for r in main.race.racers:
		if not r.is_player and r.progress > 10.0:
			ai_moved = true
	ok(ai_moved, "AI racers moving along track")

	# ---- 6. 掉落拾取 ----
	var backpack_before := Match.backpack.size()
	RaceDebug.spawn_loot_ahead(main.race)
	await until(func(): return Match.backpack.size() > backpack_before, 25.0)
	ok(Match.backpack.size() > backpack_before, "loot picked up into backpack (now %d parts)" % Match.backpack.size())

	# ---- 6.5 R 倒转：检查点记账 → 低速传送 + 幽灵 → 超速拒绝（幽灵中做闸门，
	#      玩家已传送至路面中心，不受自动驾驶卡死位置/AI 干扰）→ 到期恢复 ----
	# 冻结 AI 车流：速度闸门断言依赖玩家车速稳定，AI 追尾会造成偶发干扰
	for r in main.race.racers:
		if not r.is_player:
			r.vehicle.freeze = true
	var pr: Racer = main.race.player_racer
	var td: TrackData = main.race.track_data
	pr.progress = td.checkpoints[2] + 1.0
	pr.update_checkpoints(td)
	ok(pr.cp_reached == 2, "checkpoint pass recorded while racing (cp=2)")
	pv.linear_velocity = Vector3.ZERO
	pv.angular_velocity = Vector3.ZERO
	await until(func(): return pv.speed < 20.0, 5.0)
	ok(pv.speed < 20.0, "below speed limit before rewind (%.1f m/s)" % pv.speed)
	var pose := td.checkpoint_pose(pr.cp_reached)
	main.race.rewind_player()
	ok(pv.global_position.distance_to(pose["pos"]) < 3.0, "rewind teleported to last checkpoint")
	ok(pr.ghost_left > 0.0 and pv.collision_layer == Racer.LAYER_CAR_DETECT
			and pv.collision_mask == Racer.LAYER_WORLD, "ghost mode on (translucent, no car collision)")
	# 幽灵保护下沿切线加速到 30 m/s：路面中心 + AI 已冻结且无车-车碰撞，读数稳定
	pv.linear_velocity = pv.global_transform.basis * Vector3(0, 0, -30.0)
	for i in 3:
		await get_tree().physics_frame
	ok(pv.speed > 20.0, "rewind gate: car above speed limit (%.1f m/s)" % pv.speed)
	var pos_fast := pv.global_position
	main.race.rewind_player()
	ok(pv.global_position.distance_to(pos_fast) < 0.5 and pr.ghost_left > 0.0,
			"rewind rejected above speed limit (ghost state untouched)")
	pv.linear_velocity = Vector3.ZERO
	pv.angular_velocity = Vector3.ZERO
	await until(func(): return pv.speed < 20.0, 5.0)
	var pose2 := td.checkpoint_pose(pr.cp_reached)
	main.race.rewind_player()
	ok(pv.global_position.distance_to(pose2["pos"]) < 3.0, "rewind again after slowing down")
	# 倒转点可能与冻结的 AI 重叠，到期推迟机制会等分离——冻结车不会动，主动挪开
	for r in main.race.racers:
		if not r.is_player and r.vehicle.global_position.distance_to(pv.global_position) < 8.0:
			r.vehicle.global_position += Vector3(20.0, 0.0, 0.0)
	await until(func(): return pr.ghost_left <= 0.0, 12.0)
	ok(pv.collision_layer == Racer.CAR_LAYER and pv.collision_mask == Racer.CAR_MASK,
			"ghost expired after %.0fs, car collision restored" % Match.game_cfg("rewind_ghost_sec"))

	# ---- 7. 完赛 → 局间整备 ----
	RaceDebug.finish_all(main.race)
	await until(func(): return main.current_ui != null and main.current_ui.name == "Intermission", 10.0)
	ok(main.current_ui.name == "Intermission", "round ended -> intermission garage")
	ok(main.hud == null, "race HUD hidden during intermission")
	ok(main.race == null, "race world cleared for 3D stage camera")
	ok(main.current_ui.get_node_or_null("CarStage") != null, "intermission embeds 3D car stage")
	ok(main.current_ui.stage.current_car_id == Match.car_id, "stage shows player chassis %d" % Match.car_id)
	ok(main.current_ui._results.size() == 4, "round result lists 4 racers")
	ok(main.current_ui._rewards.size() >= 1, "rank rewards granted (%d parts)" % main.current_ui._rewards.size())

	# ---- 8. 局间改装：装上引擎件，属性应提升 ----
	await get_tree().create_timer(0.3).timeout
	var garage: Node3D = main.current_ui
	ok(garage.backpack_grid.get_child_count() == Match.backpack.size(), "backpack items rendered")
	var engine_pid := -1
	for pid in Match.backpack:
		if Match.part_cfg(pid).category == "engine":
			engine_pid = pid
			break
	ok(engine_pid > 0, "engine part available (id=%d)" % engine_pid)
	if engine_pid > 0:
		var stats_before: Dictionary = Match.get_stats().duplicate()
		Match.equip_part(engine_pid)
		garage._refresh()
		var stats_after: Dictionary = Match.get_stats()
		ok(float(stats_after.accel) > float(stats_before.accel), "combined stats raised (ACC %.1f -> %.1f)" % [float(stats_before.accel), float(stats_after.accel)])
		ok(int(Match.equipped.get("engine", -1)) == engine_pid, "equip recorded in Match.equipped")

	# ---- 9. Ready → 回合2，改装必须真实改变车辆物理 ----
	garage.ready_btn.pressed.emit()
	await until(func(): return main.race != null and main.race.round_idx == 2, 10.0)
	ok(main.race.round_idx == 2, "intermission READY -> round 2 started")
	ok(main.current_ui == null, "intermission UI hidden during race")

	# ---- 9.5 回合2倒序发车：网格号互异、出生点不重叠（防全员同格堆叠生成） ----
	for i in 10:
		await get_tree().physics_frame
	var grid_ids: Array = []
	for r in main.race.racers:
		grid_ids.append(int(Match.next_grid.get(r.name, -1)))
	var grid_uniq := {}
	for g in grid_ids:
		grid_uniq[g] = true
	ok(grid_ids.size() == 4 and not grid_ids.has(-1) and grid_uniq.size() == 4,
			"round 2 grid numbers all distinct: %s" % str(grid_ids))
	var spawn_apart := true
	for i in main.race.racers.size():
		for j in range(i + 1, main.race.racers.size()):
			if main.race.racers[i].vehicle.global_position.distance_squared_to(
					main.race.racers[j].vehicle.global_position) < 4.0:
				spawn_apart = false
	ok(spawn_apart, "round 2 spawn positions >=2m apart (no same-slot pile-up)")

	var torque_r2: float = main.race.player_torque_applied
	ok(torque_r2 > torque_r1 * 1.01, "engine mod raised REAL vehicle torque (%.0f -> %.0f NM)" % [torque_r1, torque_r2])

	# ---- 10. 快速跑完剩余回合直至决赛 ----
	var guard := 0
	while guard < 12:
		guard += 1
		if main.race != null and not main.race.ended:
			RaceDebug.finish_all(main.race)
		await until(func(): return main.current_ui != null and (main.current_ui.name == "Intermission" or main.current_ui.name == "FinalResult"), 10.0)
		if main.current_ui.name == "FinalResult":
			break
		main.current_ui.ready_btn.pressed.emit()
		await until(func(): return main.race != null and main.race.round_idx == 4, 10.0)
	ok(main.current_ui.name == "FinalResult", "final round ended -> final result screen")
	ok(Match.champion != "", "champion decided: %s" % Match.champion)
	ok(Match.round_history.size() == 4, "4 sub-rounds recorded in history")

	# ---- 11. 返回大厅，状态复位 ----
	main.current_ui.back_btn.pressed.emit()
	await get_tree().process_frame
	ok(main.current_ui.name == "Lobby", "back to lobby for a fresh match")
	ok(Match.round_index == 0 and Match.backpack.is_empty(), "match state reset")

	print("========== %d checks, %d failures ==========" % [checks, failures])
	if failures == 0:
		print("[SMOKE] ALL PASS")
	else:
		print("[SMOKE] FAILED")
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if failures == 0 else 1)
