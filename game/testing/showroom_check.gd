extends Node3D
## 展示间自动化检查：加载 showroom，核对初始车辆/按钮生成/切换逻辑/非法 id 回退、
## 手动旋转（无自动旋转、拖拽生效）、关闭信号，截图到 shots/ 供人工核对。

var failures := 0
var showroom: Node3D

func _ready() -> void:
	showroom = load("res://game/ui/showroom/showroom.tscn").instantiate()
	add_child(showroom)
	_check_initial()
	showroom.show_car(602)
	_check_switch(602)
	showroom.show_car(603)
	_check_switch(603)
	showroom.show_car(999)
	_note(showroom.current_car_id == 603, "非法 id 999 被忽略，仍展示 603")
	showroom.show_car(601)
	await _check_rotation()
	_check_close()

	await get_tree().create_timer(0.8).timeout
	# headless 模式 frame_post_draw 不触发会永久挂起，用短定时器兜底（截图为空图，仅窗口模式出真实像素）
	if DisplayServer.get_name() == "headless":
		await get_tree().create_timer(0.1).timeout
	else:
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://game/testing/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	if img == null:
		print("[SHOT] headless 空渲染器无像素，跳过截图")  # 防止 null 中断协程导致 quit 不执行
	else:
		img.save_png(dir.path_join("showroom_check.png"))
		print("[SHOT] showroom_check -> %s" % dir.path_join("showroom_check.png"))
	print("[DONE] failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check_rotation() -> void:
	# 角度差一律 wrapf 到 (-PI, PI] 再比较：出生 yaw 225° 落在欧拉角 ±180° 分支
	# 翻转区，rotation.y 会在等价表示间跳变（3.93 ↔ -2.36），直接比原始值会误报
	var stage: CarStage = showroom.stage
	var y0: float = stage._car.rotation.y   # 展车在展台组件名下
	await get_tree().create_timer(0.3).timeout
	_note(absf(wrapf(stage._car.rotation.y - y0, -PI, PI)) < 0.01, "无输入时车辆不自动旋转")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	stage._unhandled_input(press)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(100, 0)
	stage._unhandled_input(drag)
	var release := press.duplicate()
	release.pressed = false
	stage._unhandled_input(release)
	_note(absf(wrapf(stage._car.rotation.y - y0 + 100.0 * stage.drag_sensitivity, -PI, PI)) < 0.01, "拖拽 100px 车辆随之旋转")
	stage._unhandled_input(press)  # 重新按下再反向拖拽
	drag.relative = Vector2(-50, 0)
	stage._unhandled_input(drag)
	stage._unhandled_input(release)
	_note(wrapf(stage._car.rotation.y - y0, -PI, PI) > -100.0 * stage.drag_sensitivity, "反向拖拽可回转")
	_note(not stage._car.is_physics_processing(), "展车物理已停用（纯视觉道具，旋转不溜车）")
	_note(stage._car.linear_velocity.length() < 0.001, "展车静止：速度为零")
	_note(stage._car.position.y > 0.0 and stage._car.position.y < 0.7, "展车摆放在落座高度（车库地坪上方）")

func _check_close() -> void:
	var state := {"closed": false}
	showroom.close_requested.connect(func(): state["closed"] = true)
	var btn: Button = showroom.get_node("UI/Root/CloseButton")
	_note(btn != null and btn.text.contains("CLOSE"), "右上角存在关闭按钮")
	btn.pressed.emit()
	_note(state["closed"], "点击关闭按钮发出 close_requested")

func _check_initial() -> void:
	_note(showroom.current_car_id == 601, "初始展示 Car 表最小 id 601")
	var live := _live_cars()
	_note(live.size() == 1 and live[0] is Vehicle and not live[0].is_physics_processing(), "展台上有且仅有一辆展车（物理已停用）")
	_note(showroom.stage.get_node_or_null("Backdrop/Wall") != null, "工业车库背景墙已生成")
	var bar: HBoxContainer = showroom.get_node("UI/Root/BottomBar")
	_note(bar.get_children().size() == Settings.car.data.size(), "底部按钮数 = Car 表车辆数")
	_note(_pressed_id() == 601, "当前 601 对应按钮为按下态")
	_note(showroom.get_node("UI/Root/CarName").text.contains("Brute Power"), "车名标签显示 Brute Power")

func _check_switch(cid: int) -> void:
	var name_by_id := {602: "Agile Sprinter", 603: "All-Rounder"}
	_note(showroom.current_car_id == cid, "切换后 current_car_id = %d" % cid)
	_note(_live_cars().size() == 1, "切换后展台仅一辆车（旧车已清理）")
	_note(_pressed_id() == cid, "切换后 %d 按钮为按下态" % cid)
	_note(showroom.get_node("UI/Root/CarName").text.contains(name_by_id[cid]), "车名标签更新为 %s" % name_by_id[cid])

func _live_cars() -> Array:
	var out: Array = []
	for c in showroom.stage.get_children():   # 展车挂在展台组件名下
		if c is Vehicle and not c.is_queued_for_deletion():
			out.append(c)
	return out

func _pressed_id() -> int:
	for b in showroom.get_node("UI/Root/BottomBar").get_children():
		if b.button_pressed:
			return int(b.get_meta(&"car_id"))
	return 0

func _note(ok: bool, what: String) -> void:
	if ok:
		print("[PASS] %s" % what)
	else:
		failures += 1
		print("[FAIL] %s" % what)
