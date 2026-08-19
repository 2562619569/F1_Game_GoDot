extends Node3D
## NPC 交通靶车驾驶（挂在车根节点下，与 ai_racer 同位的 Driver 角色）：
## - 样条跟随巡航（TrackFollower，速度乘 npc_speed_scale 慢速行驶）；
## - 血量由车体下 "CarHealth" 子节点承载（race_builder 装配），碰撞伤害由
##   CollisionKick 结算，玩家/AI 赛车不挂该组件天然免疫；
## - 类型（common/rare/elite）由 race_builder 按 Game 表权重抽定并注入 drop_route，
##   被撞爆（CarHealth.destroyed）按该路线滚掉落（Loot 表 npc_* 行：稀有度权重
##   越好的类型越高、刷新概率越低），走 loot_pickup 同一拾取链路
##   （loot_cb 由 race_builder 注入）+ 一次性自发光碎片粒子，随后整车退场。
## 不参与排名/检查点/发车网格，也不进 RaceManager.racers（解冻走 race_started 信号）。

const LOOT_SCENE := preload("res://game/race/loot_pickup.tscn")
const EXPLODE_COLORS := [Color(1.0, 0.45, 0.1), Color(1.0, 0.75, 0.2), Color(0.9, 0.2, 0.15)]
const SHARD_LIFETIME := 1.2   # 碎片粒子寿命（s），粒子节点随之自清理

var vehicle: Vehicle
var frozen := true
var drop_route := "npc_common"
var loot_cb: Callable
var _follower: TrackFollower

func setup(v: Vehicle, data: TrackData, lane: float, speed_scale: float,
		race: RaceManager, cb: Callable, route := "npc_common") -> void:
	vehicle = v
	drop_route = route
	loot_cb = cb
	_follower = TrackFollower.new(data, lane, speed_scale)
	var health := v.get_node_or_null("CarHealth")
	if health is CarHealth:
		(health as CarHealth).destroyed.connect(_on_destroyed)
	# NPC 不在 racers 名单里，GO 解冻改由比赛开始信号驱动
	race.race_started.connect(_unfreeze)

func _unfreeze() -> void:
	frozen = false
	if vehicle != null:
		vehicle.sleeping = false  # 静置休眠的车 apply_force 不唤醒（同 GO 发车处理）

func _physics_process(_delta: float) -> void:
	if vehicle == null or frozen:
		return
	_follower.drive(vehicle)

## 撞爆：掉落 > 特效 > 退场。掉落先于特效生成，两者都在车体销毁前取好世界坐标。
func _on_destroyed(_car: Node) -> void:
	var pos := vehicle.global_position
	_spawn_loot(pos)
	_spawn_explosion(pos)
	vehicle.get_parent().queue_free()  # 车根 Node3D（含车体与本驱动）整体退场

## 撞爆掉落：按本车类型的 Loot 路线滚（npc_common/rare/elite 各有稀有度权重与
## 保底，取首件）；类别缺失的防御返回（pid<1）跳过不补偿
func _spawn_loot(pos: Vector3) -> void:
	var pids: Array = Match.roll_route_drops(drop_route)
	if pids.is_empty() or int(pids[0]) < 1:
		return
	var loot := LOOT_SCENE.instantiate()
	loot.position = pos + Vector3(0, 0.2, 0)  # 车原点离地≈静止高度，微抬避开路面嵌合
	vehicle.get_parent().get_parent().add_child(loot)  # 挂到 race 节点（车根即将销毁）
	loot.setup(int(pids[0]), drop_route)
	if loot_cb.is_valid():
		loot.collected.connect(loot_cb)

## 一次性自发光碎片爆散：黑体升温配色的方块碎片 + 短促点光，寿命到自清理。
## headless 下粒子无渲染但节点照常驱动，不阻塞校验。
func _spawn_explosion(pos: Vector3) -> void:
	var host := vehicle.get_parent().get_parent()
	var parts := GPUParticles3D.new()
	parts.position = pos
	parts.one_shot = true
	parts.explosiveness = 1.0
	parts.amount = 24
	var proc := ParticleProcessMaterial.new()
	proc.direction = Vector3.UP
	proc.spread = 65.0
	proc.initial_velocity_min = 5.0
	proc.initial_velocity_max = 11.0
	proc.gravity = Vector3(0, -14, 0)
	proc.scale_min = 0.5
	proc.scale_max = 1.0
	parts.process_material = proc
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.22, 0.22, 0.22)
	var mat := StandardMaterial3D.new()
	var c: Color = EXPLODE_COLORS[randi() % EXPLODE_COLORS.size()]
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 2.5
	mesh.material = mat
	parts.draw_passes = 1
	parts.draw_pass_1 = mesh  # 碎片绘制网格（draw_pass_1，非 CPUParticles 的 mesh 属性）
	var light := OmniLight3D.new()
	light.light_color = c
	light.omni_range = 7.0
	light.light_energy = 3.0
	parts.add_child(light)
	host.add_child(parts)
	parts.emitting = true
	var tw := parts.create_tween()  # 入树后创建，否则无 SceneTree 可挂
	tw.tween_interval(SHARD_LIFETIME)
	tw.tween_callback(parts.queue_free)
