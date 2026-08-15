extends Node3D
## 展示间流程冒烟检查：大厅 → SHOWROOM 按钮 → 展示间 → 关闭按钮 → 返回大厅。

var failures := 0
var main: Node3D

func _ready() -> void:
	main = load("res://game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame

	_note(main.current_ui != null and main.current_ui.get("showroom_btn") != null, "初始为大厅且含 SHOWROOM 按钮")
	main.current_ui.get("showroom_btn").pressed.emit()
	await get_tree().process_frame
	_note(main.showroom != null, "点击 SHOWROOM 进入展示间")
	_note(main.current_ui == null, "进入展示间后大厅界面已清空")
	var close_btn: Button = main.showroom.get_node("UI/Root/CloseButton")
	close_btn.pressed.emit()
	await get_tree().process_frame
	_note(main.showroom == null and main.current_ui != null and main.current_ui.get("create_room_btn") != null, "关闭展示间返回大厅")

	print("[DONE] failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _note(ok: bool, what: String) -> void:
	if ok:
		print("[PASS] %s" % what)
	else:
		failures += 1
		print("[FAIL] %s" % what)
