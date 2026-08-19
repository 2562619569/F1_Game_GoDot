extends SceneTree
func _init() -> void:
	var data: TrackData = TrackData.load_json("res://game/race/tracks/data/map_1.json")
	print("[V] length=%.1f anchor=%s routes=%d" % [data.length, str(data.grid_cfg.get("anchor_s")), data.routes.size()])
	print("[V] p0=%s p_lead=%s pe=%s" % [str(data.start_point()), str(data.point_at(0.0)), str(data.point_at(data.length))])
	var tb := TrackBuilder.new()
	tb.build(data)
	root.add_child(tb)
	print("[V] junctions=%d" % tb.junctions.size())
	quit()
