extends Node
## headless 自检：选车确认 → 车库到赛道的无缝过渡（分层渲染方案）。
## 运行：godot --headless --path . res://game/testing/garage_transition_check.tscn
## 覆盖：过渡期倒计时挂起且车不动（发车位变换逐帧不变）、车库展台搬入
## SubViewport 叠加层（独立世界、展车仍可见）、主视口追尾相机起始机位与
## 车库相机相对展车的位姿一致（两层画面里的车重合）、过渡结束后追尾相机
## 落在静止收敛位、车库层与宿主场景已释放、HUD 淡入、倒计时放行进入竞速、
## 局间整备 → 下一回合同路径。

var checks := 0
var failures := 0
var main: Node

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[GAR] OK   | %s" % label)
	else:
		failures += 1
		print("[GAR] FAIL | %s" % label)

func until(pred: Callable, timeout := 15.0) -> bool:
	var t := 0.0
	while t < timeout:
		if pred.call():
			return true
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return pred.call()

func _ready() -> void:
	print("========== GARAGE TRANSITION CHECK ==========")
	Engine.time_scale = 3.0
	Match.auto_test = true
	Match.intermission_sec_override = 999.0
	await _run()
	var pass_ := failures == 0
	print("========== %d checks, %d failures ==========" % [checks, failures])
	print("[GAR] %s (fails=%d)" % ["PASS" if pass_ else "FAIL", failures])
	get_tree().quit(0 if pass_ else 1)

func _run() -> void:
	main = preload("res://game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	main.current_ui.create_room_btn.pressed.emit()
	await get_tree().process_frame
	main.current_ui.play_btn.pressed.emit()
	await get_tree().process_frame
	ok(main.current_ui.name == "CarSelect", "car select shown")

	# 过渡前捕获：车库相机相对展车的位姿（含拖拽朝向）
	var stage: CarStage = main.current_ui.get_node("CarStage")
	var car_xf := stage.display_car().global_transform
	var cam_xf := stage.camera.global_transform

	# ---- 确认选车：过渡应立即开始（比赛建立 + 倒计时挂起 + 车库入层） ----
	main.current_ui.confirm_btn.pressed.emit()
	await get_tree().process_frame
	ok(main.race != null and main.race.round_idx == 1, "round 1 built on confirm")
	ok(main.race.countdown_hold, "countdown held during transition")
	ok(main.current_ui == null, "car select UI detached from ui tracking")
	ok(main._garage_host != null, "garage host kept alive for transition")

	# ---- 分层结构：车库在 SubViewport 叠加层里继续渲染 ----
	var sub: SubViewport = null
	for c in main.get_children():
		if c is SubViewport:
			sub = c
	ok(sub != null and sub.own_world_3d, "garage moved into own-world SubViewport")
	var moved_stage := sub.get_node_or_null("CarStage") if sub != null else null
	ok(moved_stage == stage, "CarStage reparented into SubViewport")
	ok(stage.display_car().visible, "display car stays visible in garage layer")
	var overlay := null
	for c in main.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == 10:
			overlay = c
	ok(overlay != null and overlay.get_child_count() == 1, "garage overlay layer composited full-screen")
	# 组合过渡 shader：车库层光带扫描 + 全屏径向变焦（盖在其上）
	var sweep_mat: ShaderMaterial = (overlay.get_child(0) as Control).material as ShaderMaterial \
			if overlay != null and overlay.get_child(0) is Control else null
	ok(sweep_mat != null and sweep_mat.shader.resource_path.ends_with("garage_sweep.gdshader"),
			"garage layer uses sweep shader")
	var rush_layer := null
	for c in main.get_children():
		if c is CanvasLayer and (c as CanvasLayer).layer == 11:
			rush_layer = c
	ok(rush_layer != null and rush_layer.get_child_count() == 1
			and (rush_layer.get_child(0) as Control).material is ShaderMaterial,
			"full-screen zoom-rush layer above garage layer")

	# ---- 主视口相机：起始机位 = 车库相机位姿应用到发车位（两层车重合） ----
	var pv: Vehicle = main.race.player_racer.vehicle
	var spawn := pv.global_transform
	var expected := spawn * car_xf.affine_inverse() * cam_xf
	var cam: Camera3D = main.race.chase_camera
	ok(cam != null and cam.is_current(), "chase camera is current from transition start")
	ok(cam.global_position.distance_to(expected.origin) < 0.05,
			"start pose matches garage viewpoint (d=%.3fm)" % cam.global_position.distance_to(expected.origin))
	var qd := cam.global_transform.basis.get_rotation_quaternion().angle_to(
			expected.basis.get_rotation_quaternion())
	ok(qd < 0.02, "start orientation matches garage viewpoint (angle=%.3frad)" % qd)

	# ---- 过渡期：车不动 + 倒计时挂起 + 车库层相机逐帧锁定主相机 ----
	for i in 20:
		await get_tree().physics_frame
	ok(pv.freeze, "player car frozen during transition")
	ok(pv.global_position.distance_to(spawn.origin) < 0.01, "player car did not move")
	ok(main.race.countdown_left >= float(Match.game_cfg("start_countdown")) - 1.0,
			"countdown not ticking while held")
	var layer_car_xf: Transform3D = moved_stage.display_car().global_transform
	var expect_layer: Transform3D = layer_car_xf * spawn.affine_inverse() * cam.global_transform
	ok(moved_stage.camera.global_position.distance_to(expect_layer.origin) < 0.05,
			"garage layer camera locked to main camera (d=%.3fm)" \
					% moved_stage.camera.global_position.distance_to(expect_layer.origin))
	ok(absf(moved_stage.camera.fov - cam.fov) < 0.01, "garage layer FOV synced")
	var sweep_progress := float(sweep_mat.get_shader_parameter("progress"))
	await get_tree().create_timer(0.15).timeout
	var sweep_progress2 := float(sweep_mat.get_shader_parameter("progress")) \
			if is_instance_valid(sweep_mat) else 1.0
	ok(sweep_progress >= 0.0 and sweep_progress2 > sweep_progress,
			"transition shader progress advances with camera flight (%.2f -> %.2f)" \
					% [sweep_progress, sweep_progress2])

	# ---- 过渡结束：车库层释放、追尾相机在收敛位、HUD 淡入、倒计时放行 ----
	ok(await until(func(): return not main.race.countdown_hold), "countdown released after transition")
	ok(main._garage_host == null, "garage host freed after transition")
	var layer_gone := true
	for c in main.get_children():
		if c is SubViewport or (c is CanvasLayer and ((c as CanvasLayer).layer == 10 or (c as CanvasLayer).layer == 11)):
			layer_gone = false
	ok(layer_gone, "garage SubViewport/overlay/rush layers freed after transition")
	var dist := float(cam.follow_distance)
	var height := float(cam.follow_height)
	var rest := spawn.origin + Vector3(spawn.basis.z.x, 0, spawn.basis.z.z).normalized() * dist
	rest.y = spawn.origin.y + height
	ok(cam.global_position.distance_to(rest) < 1.5,
			"chase camera near resting pose (d=%.2fm)" % cam.global_position.distance_to(rest))
	ok(main.hud != null and await until(func(): return main.hud != null and main.hud.modulate.a > 0.5, 3.0),
			"HUD faded in")
	ok(await until(func(): return main.race.racing), "race actually starts (countdown completes)")

	# ---- 局间整备 → 下一回合同样走过渡 ----
	preload("res://game/testing/race_debug.gd").finish_all(main.race)
	ok(await until(func(): return main.current_ui != null and main.current_ui.name != "CarSelect", 30.0),
			"intermission shown after round")
	if main.current_ui != null and main.current_ui.name != "CarSelect":
		main.current_ui.start_next_pressed.emit()
		await get_tree().process_frame
		ok(main.race != null and main.race.round_idx == 2 and main.race.countdown_hold,
				"round 2 transition holds countdown too")
		ok(await until(func(): return not main.race.countdown_hold), "round 2 countdown released")
