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
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://game/testing/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("showroom_check.png"))
	print("[SHOT] showroom_check -> %s" % dir.path_join("showroom_check.png"))
	print("[DONE] failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check_rotation() -> void:
	var table: Node3D = showroom.get_node("Turntable")
	var y0 := table.rotation.y
	await get_tree().create_timer(0.3).timeout
	_note(is_equal_approx(table.rotation.y, y0), "无输入时展台不自动旋转")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	showroom._unhandled_input(press)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(100, 0)
	showroom._unhandled_input(drag)
	var release := press.duplicate()
	release.pressed = false
	showroom._unhandled_input(release)
	_note(is_equal_approx(table.rotation.y, y0 - 100.0 * showroom.drag_sensitivity), "拖拽 100px 展台随之旋转")
	showroom._unhandled_input(press)  # 重新按下再反向拖拽
	drag.relative = Vector2(-50, 0)
	showroom._unhandled_input(drag)
	showroom._unhandled_input(release)
	_note(table.rotation.y > y0 - 100.0 * showroom.drag_sensitivity, "反向拖拽可回转")

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
	_note(live.size() == 1 and live[0] is Vehicle and live[0].freeze, "展台上有且仅有一辆冻结的 Vehicle")
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
	for c in showroom.get_node("Turntable").get_children():
		if not c.is_queued_for_deletion():
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
