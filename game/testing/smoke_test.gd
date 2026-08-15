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
	ok(main.current_ui.card_buttons.size() == 3, "3 chassis cards from Car table")

	# ---- 4. 选车 → 回合1 ----
	main.current_ui.card_buttons[0].pressed.emit()
	await get_tree().process_frame
	ok(main.race != null and main.race.round_idx == 1, "round 1 started")
	ok(main.current_ui == null, "car select UI hidden during race")
	ok(main.race.racers.size() == 4, "4 racers on grid (1 player + 3 AI)")
	var pv: Vehicle = main.race.player_racer.vehicle
	ok(pv.is_in_group("player_car"), "player car in player_car group")
	var torque_r1: float = main.race.player_torque_applied
	ok(torque_r1 > 100.0, "Car table physics applied (torque=%.0f NM)" % torque_r1)
	ok(main.hud != null, "race HUD bound")

	# ---- 5. 倒计时 → GO → 物理运转 ----
	await until(func(): return main.race.racing, 8.0)
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

	# ---- 7. 完赛 → 局间整备 ----
	RaceDebug.finish_all(main.race)
	await until(func(): return main.current_ui != null and main.current_ui.name == "Intermission", 10.0)
	ok(main.current_ui.name == "Intermission", "round ended -> intermission garage")
	ok(main.hud == null, "race HUD hidden during intermission")
	ok(main.current_ui._results.size() == 4, "round result lists 4 racers")
	ok(main.current_ui._rewards.size() >= 1, "rank rewards granted (%d parts)" % main.current_ui._rewards.size())

	# ---- 8. 局间改装：装上引擎件，属性应提升 ----
	await get_tree().create_timer(0.3).timeout
	var garage: Control = main.current_ui
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
