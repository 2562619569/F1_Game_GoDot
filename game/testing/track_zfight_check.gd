extends SceneTree
## 临时校验:TrackBuilder 生成后道路/草地/dirt 的垂直分层(防 z-fighting)。运行:
## godot --headless --path . -s res://game/testing/track_zfight_check.gd

var failures := 0

func ok(cond: bool, label: String) -> void:
	if cond:
		print("[TRK] OK   | %s" % label)
	else:
		failures += 1
		print("[TRK] FAIL | %s" % label)

func _init() -> void:
	var data := TrackData.load_json("res://game/race/tracks/data/map_1.json")
	ok(data != null, "加载 map_1.json")
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)

	var road_y := 0.0
	var dirt_y := 0.0
	var grass: StaticBody3D = null
	for c in tb.get_children():
		if c is StaticBody3D:
			if c.name == "Grass":
				grass = c
			elif "Dirt" in c.get_groups():
				dirt_y = c.position.y
			elif "Road" in c.get_groups() and c.name != "Walls":
				road_y = c.position.y
	var grass_top: float = grass.position.y + 0.05  # 盒厚 0.1,顶面 = 中心 + 半高

	ok(absf(grass_top - road_y) >= 0.15, "草地顶面(%.2f)与路面(%.2f)至少分离 0.15m" % [grass_top, road_y])
	ok(absf(dirt_y - road_y) >= 0.05, "dirt(%.2f)与主路(%.2f)至少分离 0.05m" % [dirt_y, road_y])
	ok(grass_top < dirt_y and dirt_y < road_y, "分层顺序:草地 < dirt < 主路")

	print("[TRK] 结果: %s" % ("全部通过" if failures == 0 else "%d 项失败" % failures))
	quit(1 if failures > 0 else 0)
