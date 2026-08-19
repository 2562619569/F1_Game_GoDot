extends Node3D
## NPC 生成诊断（只打印不断言）：完整走 RaceManager.setup → RaceBuilder.build，
## 数 race 节点下 NPC-* 车数量、位置、血量、冻结态，对照 Game 表配置。
## 运行：godot --headless --path . res://game/testing/npc_diag.tscn

func _ready() -> void:
	var race := RaceManager.new()
	race.name = "Race"
	add_child(race)
	race.setup(1)  # 第 1 回合（地图取 Match.upcoming_map_id）
	await get_tree().physics_frame
	var names := []
	var npcs := []
	for c in race.get_children():
		names.append(String(c.name))
		if String(c.name).begins_with("NPC"):
			npcs.append(c)
	print("[DIAG] game_cfg: npc_count=%d npc_count_min=%d hp=%.0f speed=%.2f dmg=%.2f w=%.0f/%.0f/%.0f"
			% [int(Match.game_cfg("npc_count")), int(Match.game_cfg("npc_count_min")),
			Match.game_cfg("npc_hp"), Match.game_cfg("npc_speed_scale"),
			Match.game_cfg("npc_damage_coeff"), Match.game_cfg("npc_w_common"),
			Match.game_cfg("npc_w_rare"), Match.game_cfg("npc_w_elite")])
	print("[DIAG] map_id=%d track_data=%s race_children=%d" % [race.map_id,
			str(race.track_data != null), race.get_child_count()])
	print("[DIAG] race 子节点名 = %s" % ", ".join(names))
	var player: Node = race.player_racer.vehicle
	for c in npcs:
		var v: Vehicle = c.get_child(0)
		var h: CarHealth = v.get_node("CarHealth")
		var d: Node = c.get_node("Driver")
		print("[DIAG] %s pos=%s 玩家距=%.0fm hp=%.0f frozen=%s"
				% [String(c.name), c.global_position.round(),
				c.global_position.distance_to(player.global_position),
				h.hp, str(d.get("frozen"))])
	print("[DIAG] NPC 总数 = %d" % npcs.size())
	get_tree().quit(0)
