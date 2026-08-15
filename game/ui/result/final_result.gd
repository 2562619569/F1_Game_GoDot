extends Control
## 终局结算：冠军与静态框架在 tscn 内编辑，各回合名次总表由代码生成
## （数据来自 Match.round_history）。
## 对外契约：back_pressed 信号 + back_btn。

signal back_pressed

@onready var champion_label: Label = %ChampionLabel
@onready var table_grid: GridContainer = %TableGrid
@onready var back_btn: Button = %BackButton

func _ready() -> void:
	champion_label.text = "🏆  CHAMPION: %s  🏆" % (Match.champion if Match.champion != "" else "—")
	back_btn.pressed.connect(func(): back_pressed.emit())
	if Match.round_history.is_empty():
		return

	var names: Array = []
	for e in Match.round_history[0]:
		names.append(e.name)
	table_grid.columns = names.size() + 1

	var corner := Label.new()
	table_grid.add_child(corner)
	for n in names:
		var h := Label.new()
		h.text = String(n)
		UIStyle.title(h, 17, UIStyle.ACCENT if n == Match.PLAYER_NAME else UIStyle.TEXT)
		table_grid.add_child(h)

	for ri in Match.round_history.size():
		var rl := Label.new()
		rl.text = "ROUND %d" % (ri + 1)
		UIStyle.dim(rl, 15)
		table_grid.add_child(rl)
		for n in names:
			var rank := "-"
			for e in Match.round_history[ri]:
				if e.name == n:
					rank = "P%d" % e.rank
			var cell := Label.new()
			cell.text = rank
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UIStyle.label(cell, 16, UIStyle.ACCENT_WARM if n == Match.PLAYER_NAME else UIStyle.TEXT)
			table_grid.add_child(cell)
