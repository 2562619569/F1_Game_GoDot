extends Node3D
## 聚焦调试：最小环境验证 CarBuilder + 玩家车在测试赛道上能否行驶。

func _ready() -> void:
	Match.auto_test = true
	var track := preload("res://game/race/tracks/track_test.tscn").instantiate()
	add_child(track)
	track.setup("sunny")

	var root := Node3D.new()
	root.position = Vector3(0, 0, -6)
	var v: Vehicle = preload("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	v.position = Vector3(0, 0.95, 0)
	CarBuilder.apply(v, Match.car_cfg(1), Match.get_stats(), "sunny", 1.0)
	root.add_child(v)
	add_child(root)

	var ctrl := Node3D.new()
	ctrl.set_script(preload("res://game/car/player_car.gd"))
	root.add_child(ctrl)
	ctrl.setup(v, self)
	v.add_to_group("player_car")
	ctrl.frozen = false  # 直接发车

	var t := 0.0
	while t < 6.0:
		await get_tree().create_timer(1.0).timeout
		t += 1.0
		print("[DBG] t=%.0f speed=%.2f gear=%d rpm=%.0f throttle_in=%.2f ready=%s pos=%s" % [
			t, v.speed, v.current_gear, v.motor_rpm, v.throttle_input, v.is_ready, v.global_position])
	get_tree().quit()
