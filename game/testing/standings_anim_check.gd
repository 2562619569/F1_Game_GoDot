extends Node
## headless 自检：HUD 排名行动效（换位滑动 + 徽标弹跳闪色）。
## 运行：godot --headless --path . res://game/testing/standings_anim_check.tscn
## 直接实例化 race_hud.tscn，用假 Racer 序列驱动 _on_standings：
## 首帧直落槽位 / 行节点跨刷新复用 / 换位滑动到位 / 徽标弹跳回落复色 /
## 未换位行不动 / 中途上榜淡入、下榜收起 / 冲线勾更新 / 玩家行高亮。

var checks := 0
var failures := 0
var hud: Control

func _ready() -> void:
	_run()

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[STAND] OK   | %s" % label)
	else:
		failures += 1
		print("[STAND] FAIL | %s" % label)

func _fake(racer_name: String, is_player := false) -> Racer:
	var r := Racer.new()
	r.name = racer_name
	r.is_player = is_player
	return r

func _badge_text(row: Control) -> String:
	return (row.get_child(0).get_child(0) as Label).text

func _run() -> void:
	print("========== STANDINGS ANIM CHECK START ==========")
	hud = preload("res://game/ui/hud/race_hud.tscn").instantiate()
	add_child(hud)
	await get_tree().process_frame
	var box: Control = hud.standings_box

	# ---- 首次填充：直落槽位，无动画 ----
	var a := _fake("Alice")
	var b := _fake("Bob", true)
	var c := _fake("Carol")
	var d := _fake("Dave")
	hud._on_standings([a, b, c, d])
	await get_tree().process_frame
	ok(box.get_child_count() == 4, "rows built for 4 racers")
	var row_a: Control = hud._rows[a]
	var row_b: Control = hud._rows[b]
	var row_c: Control = hud._rows[c]
	var row_d: Control = hud._rows[d]
	var badge_a: Control = row_a.get_child(0)
	var badge_b: Control = row_b.get_child(0)
	var badge_c: Control = row_c.get_child(0)
	var badge_d: Control = row_d.get_child(0)
	ok(absf(row_a.position.y - 0.0) < 0.01 and absf(row_d.position.y - 96.0) < 0.01,
			"first fill places rows directly at slots (no slide-in)")
	ok(_badge_text(row_a) == "1" and _badge_text(row_d) == "4",
			"badge numbers match rank order")
	ok((row_b.get_child(1) as Label).theme_type_variation == &"Warm",
			"player row name uses Warm highlight")

	# ---- 换位：Bob 超过 Alice（B,A,C,D），采样徽标弹跳峰值 ----
	hud._on_standings([b, a, c, d])
	var peak := 1.0
	for i in 30:
		await get_tree().process_frame
		peak = maxf(peak, maxf(badge_a.scale.x, badge_b.scale.x))
	ok(peak > 1.1, "changed-rank badges punch above 1.1x (peak %.2f)" % peak)
	ok(badge_c.scale == Vector2.ONE and badge_d.scale == Vector2.ONE,
			"unchanged rows stay put (no punch)")
	ok(hud._rows[a] == row_a and hud._rows[b] == row_b,
			"row nodes reused across refresh (not rebuilt)")
	await get_tree().create_timer(0.8).timeout
	ok(_badge_text(row_b) == "1" and _badge_text(row_a) == "2",
			"badge numbers updated after swap")
	ok(absf(row_b.position.y - 0.0) < 0.5 and absf(row_a.position.y - 32.0) < 0.5,
			"swapped rows slid to new slots (bob=%.1f alice=%.1f)"
			% [row_b.position.y, row_a.position.y])
	ok(badge_a.scale.is_equal_approx(Vector2.ONE) and badge_b.scale.is_equal_approx(Vector2.ONE),
			"badge scale settles back to 1.0")
	ok(badge_a.modulate.is_equal_approx(Color.WHITE),
			"badge flash tint returns to white")

	# ---- 中途上下榜：Eve 上榜淡入、Dave 下榜收起、其余滑位 ----
	var e := _fake("Eve")
	hud._on_standings([b, e, a, c])
	var row_e: Control = hud._rows[e]
	ok(row_e.modulate.a < 0.5, "late-joining row fades in from transparent")
	await get_tree().create_timer(0.8).timeout
	ok(row_e.modulate.a >= 0.99, "late-joining row reaches full opacity")
	ok(not is_instance_valid(row_d) and box.get_child_count() == 4,
			"dropped racer row freed (4 rows remain)")
	ok(absf(row_e.position.y - 32.0) < 0.5 and absf(row_a.position.y - 64.0) < 0.5
			and absf(row_c.position.y - 96.0) < 0.5,
			"remaining rows slid to close the gap")

	# ---- 冲线标记：Carol 冲线，名字带勾 ----
	c.finished = true
	hud._on_standings([b, e, a, c])
	await get_tree().process_frame
	ok((row_c.get_child(1) as Label).text.contains("✔"),
			"finished racer name shows check mark")

	print("========== STANDINGS ANIM CHECK %s (%d checks, %d failed) =========="
			% ["PASS" if failures == 0 else "FAIL", checks, failures])
	get_tree().quit(1 if failures > 0 else 0)
