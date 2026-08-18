class_name RaceDebug
extends RefCounted
## 测试辅助（从 RaceManager 拆出）：冒烟测试与调试按键专用。

const LOOT_SCENE := preload("res://game/race/loot_pickup.tscn")

## 在玩家前方 25m 生成一个必经掉落（冒烟测试拾取验证）
static func spawn_loot_ahead(race: RaceManager) -> void:
	var loot := LOOT_SCENE.instantiate()
	var v: Vehicle = race.player_racer.vehicle
	loot.position = race.track_data.point_ahead(v.global_position, 25.0) if race.track_data != null else Vector3(v.global_position.x, 0.9, v.global_position.z - 25.0)
	race.add_child(loot)
	loot.setup(Match.roll_part("engine", 1), "main")
	loot.collected.connect(race._on_loot_collected)

## 全部立即完赛（名次按当前进度交错），驱动回合结束
static func finish_all(race: RaceManager) -> void:
	if race.ended:
		return
	var order := race.compute_order()
	for i in order.size():
		if not order[i].finished:
			order[i].mark_finished(race.race_time + 0.1 * i)
	if race.player_racer != null:
		var player_rank := order.find(race.player_racer) + 1
		race.player_finished.emit(player_rank, race.race_time)
	race._end_round()
