extends Control
## 临时探针：房间界面竖排 8 座位布局截图目检 + 座位文本真值打印（用后即删）。

const RoomScene := preload("res://game/ui/room/room_invite.tscn")

func _ready() -> void:
	var room := RoomScene.instantiate()
	add_child(room)
	await get_tree().create_timer(0.3).timeout
	_dump("default")
	_shot("room_invite_default")
	for i in 3:
		room.get_node("%AddAiButton").pressed.emit()
		await get_tree().process_frame
	_dump("full")
	_shot("room_invite_full")
	get_tree().quit()

func _dump(tag: String) -> void:
	var room := get_child(0)
	print("[ROOM] %s seats=%s btn=%s disabled=%s" % [tag,
		room.get_node("%SeatsLabel").text,
		room.get_node("%AddAiButton").text,
		room.get_node("%AddAiButton").disabled])
	for row in room.get_node("%Slots").get_children():
		print("[ROOM]   %s | %s | %s" % [row.get_node("M/Row/PosLabel").text,
			row.get_node("M/Row/NameLabel").text,
			row.get_node("M/Row/StatusLabel").text])

func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "res://game/testing/shots/%s.png" % tag
	img.save_png(ProjectSettings.globalize_path(path))
	print("[SHOT] %s %s" % [path, img.get_size()])
