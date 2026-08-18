extends Node
## 临时诊断：发车位出生几何 + 解冻瞬间是否弹飞。
## 运行：godot --headless --path . res://game/testing/spawn_diag.tscn

func _ready() -> void:
	await get_tree().process_frame
	for map_id in range(1, 5):
		await _diag_map(map_id)
	get_tree().quit(0)

func _diag_map(map_id: int) -> void:
	print("\n========== MAP %d ==========" % map_id)
	Match.reset()
	Match.upcoming_map_id = map_id
	var race := RaceManager.new()
	add_child(race)
	race.setup(1)
	await get_tree().physics_frame
	await get_tree().physics_frame

	# 出生几何：轮射线原点到路面的实际竖直间隙（正 = 悬空，负 = 车轮埋进路面）
	var space: PhysicsDirectSpaceState3D = race.get_world_3d().direct_space_state
	for r in race.racers:
		var v: Vehicle = r.vehicle
		var line := "%-9s spawn_y=%+.3f rest_h=%+.3f" % [r.name, v.global_position.y, v.position.y]
		for w in v.wheel_array:
			var from: Vector3 = w.global_position
			var q := PhysicsRayQueryParameters3D.create(
					from + Vector3.UP * 0.5, from + Vector3.DOWN * 3.0, 0xFFFFFFFF)
			q.exclude = [v.get_rid()]
			var hit: Dictionary = space.intersect_ray(q)
			var clearance: float = (from.y - float(hit.position.y)) if hit.has("position") else NAN
			line += " | %s attach_y=%+.3f clear=%+.3f" % [w.name.replace("Wheel", ""), w.position.y, clearance]
		print(line)

	# 解冻弹飞观测：把倒计时直接清零放行（等价 GO），逐帧记录最大速度/最高弹起
	race.countdown_left = 0.0001
	var max_speed := 0.0
	var max_y := -1e9
	var worst := ""
	for i in 240:
		await get_tree().physics_frame
		for r in race.racers:
			var v: Vehicle = r.vehicle
			if v.speed > max_speed:
				max_speed = v.speed
				worst = r.name
			max_y = maxf(max_y, v.global_position.y)
	print("AFTER UNFREEZE: max_speed=%.1f m/s (%s)  max_y=%.2f  racing=%s"
			% [max_speed, worst, max_y, str(race.racing)])
	for r in race.racers:
		var v: Vehicle = r.vehicle
		print("  %-9s pos=%s vel=%.1f" % [r.name,
				v.global_position.snapped(Vector3.ONE * 0.1), v.linear_velocity.length()])
	race.queue_free()
	await get_tree().process_frame
