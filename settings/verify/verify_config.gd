extends Node

func _ready() -> void:
	var lines: Array[String] = []
	var car = Settings.car.data[1]
	lines.append("[car] %s drive=%s top_speed=%s slots=%s+%s" % [car.name, car.drive, car.top_speed, car.perf_slots, car.func_slots])
	var part = Settings.part.data[501]
	lines.append("[part] %s rarity=%s cd=%ss ammo=%s" % [part.name, part.rarity, part.cooldown, part.ammo])
	var map = Settings.map.data[3]
	lines.append("[map] %s terrain=%s weather=%s hazard_branch=%s" % [map.name, map.terrain, map.weather, map.hazard_branch])
	lines.append("VERIFY_OK rows: car=%d part=%d map=%d" % [Settings.car.data.size(), Settings.part.data.size(), Settings.map.data.size()])
	for l in lines:
		print(l)
	var f = FileAccess.open("res://settings/verify/verify_result.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines))
	get_tree().quit(0)
