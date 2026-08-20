extends Control
## 终局结算：冠军与静态框架在 tscn 内编辑，各回合名次/积分总表由代码生成
## （数据来自 Match.round_history / Match.points）。
## 列序 = 最终累计积分排名（冠军在最左），行末 TOTAL 行给出总积分。
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

	# 列序 = 累计积分排名：总分高在前，平分看最后回合名次（与冠军判定一致）
	var totals := {}
	for ri in Match.round_history.size():
		for e in Match.round_history[ri]:
			totals[e.name] = int(totals.get(e.name, 0)) + int(e.points)
	var last_rank := {}
	for e in Match.round_history[Match.round_history.size() - 1]:
		last_rank[e.name] = int(e.rank)
	var names: Array = last_rank.keys()
	names.sort_custom(func(a, b):
		if int(totals[a]) != int(totals[b]):
			return int(totals[a]) > int(totals[b])
		return int(last_rank[a]) < int(last_rank[b]))
	table_grid.columns = names.size() + 1

	var corner := Label.new()
	table_grid.add_child(corner)
	for n in names:
		table_grid.add_child(_label(String(n), 17, &"Accent" if n == Match.PLAYER_NAME else &""))

	for ri in Match.round_history.size():
		table_grid.add_child(_label("ROUND %d" % (ri + 1), 15, &"Dim"))
		for n in names:
			var rank := "-"
			var pts := 0
			for e in Match.round_history[ri]:
				if e.name == n:
					rank = "P%d" % e.rank
					pts = int(e.points)
			var cell := _label("%s  +%d" % [rank, pts], 16, &"Warm" if n == Match.PLAYER_NAME else &"")
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			table_grid.add_child(cell)

	table_grid.add_child(_label("TOTAL", 15, &"Dim"))
	for n in names:
		var cell := _label("%d pts" % int(totals[n]), 17,
				&"Warm" if n == Match.champion else (&"Accent" if n == Match.PLAYER_NAME else &""))
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		table_grid.add_child(cell)

## 动态生成表格标签：字号覆盖主题默认 16，variation 引用主题角色变体
func _label(text: String, size: int, variation := &"") -> Label:
	var l := Label.new()
	l.text = text
	if variation != &"":
		l.theme_type_variation = variation
	l.add_theme_font_size_override("font_size", size)
	return l
