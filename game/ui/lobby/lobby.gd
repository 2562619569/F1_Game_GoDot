extends Control
## 大厅：创建房间入口。
## 版式在 lobby.tscn 内编辑（编辑器 2D 视图），本脚本只做按钮接线；
## 对外契约：信号 create_room_pressed + 变量 create_room_btn（供 main/冒烟测试）。

signal create_room_pressed

@onready var create_room_btn: Button = %CreateRoomButton
@onready var exit_btn: Button = %ExitButton

func _ready() -> void:
	create_room_btn.pressed.connect(func(): create_room_pressed.emit())
	exit_btn.pressed.connect(func(): get_tree().quit())
