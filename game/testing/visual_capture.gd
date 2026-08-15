extends Node
## 界面视觉捕获：窗口模式运行，逐步走完流程并对每个界面截图到
## game/testing/shots/，用于人工核对 UI 渲染（headless 无法截图）。

var main: Node

func _ready() -> void:
	_run()

func snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://game/testing/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(name + ".png")
	img.save_png(path)
	print("[SHOT] %s -> %s (%s)" % [name, path, img.get_size()])

func until(pred: Callable, timeout := 15.0) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return pred.call()

func _run() -> void:
	print("========== VISUAL CAPTURE START ==========")
	Match.auto_test = true
	Match.intermission_sec_override = 999.0
	main = preload("res://game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await snap("01_lobby")

	main.current_ui.create_room_btn.pressed.emit()
	await get_tree().process_frame
	await snap("02_room")

	main.current_ui.play_btn.pressed.emit()
	await get_tree().process_frame
	await snap("03_car_select")

	main.current_ui.card_buttons[0].pressed.emit()
	await until(func(): return main.race != null and main.race.racing, 10.0)
	await get_tree().create_timer(2.0).timeout
	await snap("04_race_hud")

	main.race.debug_spawn_loot_ahead()
	await until(func(): return Match.backpack.size() > 0, 20.0)
	main.race.debug_finish_all()
	await until(func(): return main.current_ui.name == "Intermission", 10.0)
	await get_tree().create_timer(0.5).timeout
	await snap("05_intermission")

	main.current_ui.ready_btn.pressed.emit()
	await until(func(): return main.race != null and main.race.round_idx == 2, 10.0)
	await until(func(): return main.race.racing, 10.0)
	await get_tree().create_timer(1.0).timeout
	await snap("06_round2_hud")

	while main.current_ui.name != "FinalResult":
		if main.race != null and not main.race.ended:
			main.race.debug_finish_all()
		await until(func(): return main.current_ui.name == "Intermission" or main.current_ui.name == "FinalResult", 10.0)
		if main.current_ui.name == "FinalResult":
			break
		main.current_ui.ready_btn.pressed.emit()
		await until(func(): return main.race != null and main.race.round_idx == 4, 10.0)
	await get_tree().create_timer(0.5).timeout
	await snap("07_final_result")

	main.current_ui.back_btn.pressed.emit()
	await get_tree().process_frame
	await snap("08_back_to_lobby")

	print("========== VISUAL CAPTURE DONE ==========")
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()
