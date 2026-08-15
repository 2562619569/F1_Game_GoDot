extends Control
## 开局选车：3 张卡片版式在 tscn 内编辑，文字由脚本从 Car 表实时填充
## （配表改车不需要改场景）。
## 对外契约：car_chosen(car_id) 信号 + card_buttons（按 Car 表 id 升序，当前 601~603）。

signal car_chosen(car_id: int)

const BAR_ROWS := [
	{"cap": "TOP SPEED", "key": "top_speed", "max": 340.0},
	{"cap": "ACCEL", "key": "accel", "max": 10.0},
	{"cap": "HANDLING", "key": "handling", "max": 10.0},
	{"cap": "OFFROAD", "key": "grip_offroad", "max": 10.0},
]

var card_buttons: Array = []

func _ready() -> void:
	card_buttons = [%SelectButton1, %SelectButton2, %SelectButton3]
	var car_ids := Settings.car.data.keys()
	car_ids.sort()
	for i in card_buttons.size():
		var cid := int(car_ids[i])
		card_buttons[i].pressed.connect(func(): car_chosen.emit(cid))
		_fill_card(get_node("Root/Cards/Card%d" % (i + 1)), Settings.car.data[cid])

func _fill_card(card: Control, c: Dictionary) -> void:
	var box := card.get_node("Margin/VBox")
	(box.get_node("NameLabel") as Label).text = String(c.name)
	(box.get_node("DriveLabel") as Label).text = "%s  ·  %d kg" % [String(c.drive).to_upper(), int(c.weight)]
	var rows := (box.get_node("Bars") as VBoxContainer).get_children()
	for i in mini(rows.size(), BAR_ROWS.size()):
		var row: Array = rows[i].get_children()
		(row[0] as Label).text = String(BAR_ROWS[i].cap)
		var n := clampi(roundi(float(c[BAR_ROWS[i].key]) / float(BAR_ROWS[i].max) * 10.0), 0, 10)
		(row[1] as Label).text = "█".repeat(n) + "·".repeat(10 - n)
	(box.get_node("SlotsLabel") as Label).text = "SLOTS: %d PERF + %d FUNC" % [int(c.perf_slots), int(c.func_slots)]
	(box.get_node("DescLabel") as Label).text = String(c.desc)
