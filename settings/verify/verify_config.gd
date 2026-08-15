extends Node

func _ready() -> void:
	var lines: Array[String] = []
	var car = Settings.car.data[1]
	lines.append("[car] %s drive=%s top_speed=%s slots=%s+%s grip=%s/%s" % [car.name, car.drive, car.top_speed, car.perf_slots, car.func_slots, car.grip_road, car.grip_offroad])
	lines.append("[car.physics] torque=%sNM rpm=%s final=%s gears=%s split=%s steer=%sdeg" % [car.max_torque, car.max_rpm, car.final_drive, car.gear_ratios.size(), car.front_torque_split, car.max_steering_angle])
	var part = Settings.part.data[501]
	lines.append("[part] %s rarity=%s cd=%ss ammo=%s effect=%s power=%s" % [part.name, part.rarity, part.cooldown, part.ammo, part.effect, part.power])
	var map = Settings.map.data[3]
	lines.append("[map] %s weather=%s desc=%s" % [map.name, map.weather, map.desc])
	var game_v = {}
	for id in Settings.game.data:
		game_v[Settings.game.data[id].key] = Settings.game.data[id].value
	lines.append("[game] round_count=%s intermission=%ss players=%s" % [game_v.get("round_count"), game_v.get("intermission_sec"), game_v.get("player_max")])
	var round = Settings.round.data[4]
	lines.append("[round] %s is_final=%s time_limit=%ss map_pool=%s" % [round.name, round.is_final, round.time_limit, round.map_pool])
	var loot = Settings.loot.data[2]
	lines.append("[loot] route=%s drops=%s weights=%s guarantee=%s" % [loot.route, loot.drop_count, loot.rarity_weights, loot.guarantee_rarity])
	var rr = Settings.rank_reward.data[1]
	lines.append("[rank_reward] 第1名 奖励%d件 稀有度≥%s 下回合%s号发车位" % [rr.reward_count, rr.reward_rarity_min, rr.grid_next])
	lines.append("VERIFY_OK rows: car=%d part=%d map=%d game=%d round=%d loot=%d rank_reward=%d" % [
		Settings.car.data.size(), Settings.part.data.size(), Settings.map.data.size(),
		Settings.game.data.size(), Settings.round.data.size(), Settings.loot.data.size(), Settings.rank_reward.data.size()])
	for l in lines:
		print(l)
	var f = FileAccess.open("res://settings/verify/verify_result.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	get_tree().quit(0)
