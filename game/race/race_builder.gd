class_name RaceBuilder
extends RefCounted
## 回合世界的装配（从 RaceManager 拆出）：
## 赛道 + 天气环境 + 掉落 + 参赛车（含发车位计算）+ 跟随相机。
## 只负责搭建节点与连接信号回调，不持有回合运行状态。

const TRACK_SCENE := preload("res://game/race/tracks/track_test.tscn")
const LOOT_SCENE := preload("res://game/race/loot_pickup.tscn")
const CAR_SCENE := preload("res://addons/gevp/scenes/arcade_car.tscn")
const CAMERA_SCRIPT := preload("res://game/race/smooth_chase_camera.gd")
const ENGINE_SOUND := preload("res://addons/gevp/scenes/engine_sound.tscn")
const PLAYER_SCRIPT := preload("res://game/car/player_car.gd")
const AI_SCRIPT := preload("res://game/car/ai_racer.gd")
const NPC_SCRIPT := preload("res://game/car/npc_car.gd")
const COLLISION_KICK := preload("res://game/car/collision_kick.gd")

const PLAYER_COLOR := Color(1.0, 0.85, 0.2)
const AI_COLORS := [Color(1.0, 0.3, 0.35), Color(0.3, 0.55, 1.0), Color(0.35, 0.85, 0.45)]
const NPC_COLOR := Color(0.62, 0.62, 0.66)  # 交通车灰，与竞速车队伍色区分

## NPC 交通靶车底盘池（Car 表 701~ 段：参数与玩家车同源、美术 id 独立，
## art/cars 无对应目录时 CarMeshBuilder 自动回退占位视觉，后续按 adapt-car 接入）
const NPC_CAR_IDS := [701, 702, 703]

## 出生离地净空：车身抬到静态贴地位之上该高度，靠悬挂自由沉降落地。
## 与"出生即静态贴地"的差别：地图重烘焙后发车位与路面可能互嵌毫米级，
## 贴地出生在解冻瞬间会被求解器弹出冲量；抬高出生从分离状态落回，
## 任何嵌差都化为一次正常落地。生成后不冻结不锚固，落地即静置。
const SPAWN_DROP := 0.4

## 装配整场回合世界。finish_cb / loot_cb 为冲线与拾取信号回调（由 RaceManager 注入）。
## 环境取 race.env_cfg（地图 env 文件合成产物，见 WeatherEnv.load_map_env）。
## 返回 {track, track_data, racers, player_racer, player_torque}。
static func build(race: RaceManager, map_id: int, finish_cb: Callable, loot_cb: Callable) -> Dictionary:
	var env: Dictionary = race.env_cfg
	# --- 赛道 + 地图环境 ---
	var t := _load_track(race, map_id)
	var track: Node3D = t.track
	var track_data: TrackData = t.data
	track.setup(env)
	track.get_node("FinishGate").body_entered.connect(finish_cb)
	var we := WorldEnvironment.new()
	we.environment = WeatherEnv.make_env_cfg(env)
	race.add_child(we)
	var sun := DirectionalLight3D.new()
	WeatherEnv.setup_light_cfg(sun, env)
	race.add_child(sun)

	# --- 掉落 ---
	_spawn_loot(race, track, loot_cb)

	# --- 参赛车（含倒序发车位） ---
	var racers: Array[Racer] = []
	var player_racer := _spawn_racers(race, track, track_data, racers)

	# --- NPC 交通靶车（不占发车位、不参与排名，可被撞爆掉配件） ---
	_spawn_npcs(race, track, track_data, loot_cb)

	# --- 相机跟随玩家（Pro Vehicle Camera：弹性牵引+速度FOV+过弯侧倾+look_back，
	#     smooth_chase_camera 包一层旋转低通，并加视角模式循环/鼠标·手柄环视/持续震动源；
	#     参数走 Game 表 cam_*（策划可调），碰撞脉冲震屏接线见下） ---
	var cam := Camera3D.new()
	cam.set_script(CAMERA_SCRIPT)
	cam.follow_distance = Match.game_cfg("cam_chase_distance")
	cam.follow_height = Match.game_cfg("cam_chase_height")
	cam.speed = 20.0
	cam.maximum_fov = Match.game_cfg("cam_fov_max")
	cam.shake_enabled = Match.game_cfg("cam_shake") > 0.5
	race.add_child(cam)
	cam.global_position = player_racer.vehicle.global_position + Vector3(0, 3, 9)
	cam.follow_this = player_racer.vehicle

	# 碰撞震屏（Shaker 方向性脉冲，实现在 smooth_chase_camera.impact_kick）：
	# 车身开启接触上报（contact_monitor/max_contacts_reported 已由 CollisionKick
	# 统一开启，body_entered 是多播信号，本接线与冲击放大互不影响），按撞击
	# 相对速度映射严重度，轻蹭（<6 m/s）不触发；rel 是自车相对对方的速度，即
	# 指向撞击源，kick 取反方向——相机往被撞的反方向甩再回弹；
	# cam_shake 总开关在相机内门控，脉冲与持续微震一并生效/关闭
	var pv := player_racer.vehicle
	pv.body_entered.connect(func(body: Node) -> void:
		var rel := pv.linear_velocity
		if body is RigidBody3D:
			rel -= body.linear_velocity
		var impact := rel.length()
		if impact > 6.0:
			cam.impact_kick(-rel / maxf(impact, 0.001),
					clampf((impact - 6.0) / 34.0, 0.0, 1.0)))

	return {"track": track, "track_data": track_data, "racers": racers,
		"player_racer": player_racer, "player_torque": player_racer.vehicle.max_torque,
		"camera": cam, "env_node": we}

## 赛道加载:map_id 有编辑器 JSON 则程序化生成,否则回退测试直线图
static func _load_track(race: RaceManager, map_id: int) -> Dictionary:
	var data: TrackData = null
	var path := "res://game/race/tracks/data/map_%d.json" % map_id
	if FileAccess.file_exists(path):
		data = TrackData.load_json(path)
	if data != null:
		var builder := TrackBuilder.new()
		race.add_child(builder)
		builder.build(data)
		return {"track": builder, "data": data}
	var track := TRACK_SCENE.instantiate()
	race.add_child(track)
	return {"track": track, "data": null}

static func _spawn_loot(race: RaceManager, track: Node3D, loot_cb: Callable) -> void:
	for route in ["main", "hazard"]:
		var pids: Array = Match.roll_route_drops(route)
		var pts: Array = track.main_route_points(pids.size()) if route == "main" else track.hazard_route_points()
		if pts.is_empty():
			continue
		for i in pids.size():
			if int(pids[i]) < 1:
				continue  # 类别缺失时 roll_part 的防御返回，跳过无效掉落
			var loot := LOOT_SCENE.instantiate()
			loot.position = pts[i % pts.size()]
			race.add_child(loot)
			loot.setup(int(pids[i]), route)
			loot.collected.connect(loot_cb)

static func _spawn_racers(race: RaceManager, track: Node3D, track_data: TrackData, racers: Array[Racer]) -> Racer:
	var grid := {}
	if Match.next_grid.is_empty():
		# 首回合默认：玩家杆位，AI 依次靠后
		grid[Match.PLAYER_NAME] = 1
		for i in Match.AI_DEFS.size():
			grid[Match.AI_DEFS[i].name] = i + 2
	else:
		grid = Match.next_grid.duplicate()
		var used := {}
		for g in grid.values():
			used[g] = true
		var free_no := 1
		for name_ in [Match.PLAYER_NAME] + Match.AI_DEFS.map(func(d): return d.name):
			if not grid.has(name_):
				while used.has(free_no):
					free_no += 1
				grid[name_] = free_no
				used[free_no] = true

	# 玩家
	var player := _make_racer(race, track_data, Match.PLAYER_NAME, Match.car_id, Match.get_stats(), grid[Match.PLAYER_NAME], 1.0, true, 0, Match.appearance())
	racers.append(player)

	# AI（随机装配 1~2 件改件制造差异）
	for i in Match.AI_DEFS.size():
		var d: Dictionary = Match.AI_DEFS[i]
		var eq := {}
		var cats := ["engine", "tires", "aero", "chassis"]
		cats.shuffle()
		for cat in cats.slice(0, randi_range(1, 2)):
			eq[cat] = Match.roll_part(cat, 2)
		if randf() < 0.5:
			eq["tactical"] = Match.roll_part("tactical", 2)
		var skill: float = d.skill + randf_range(-0.02, 0.02)
		racers.append(_make_racer(race, track_data, d.name, d.car_id, Match.stats_for_car(d.car_id, eq), grid[d.name], skill, false, i, Match.appearance_for_car(d.car_id, eq)))
	return player

static func _make_racer(race: RaceManager, track_data: TrackData, rname: String, cid: int, stats: Dictionary, grid_no: int, torque_scale: float, is_player: bool, ai_idx := 0, appearance := {}) -> Racer:
	var root := Node3D.new()
	root.name = rname
	var v: Vehicle = CAR_SCENE.instantiate()
	root.position = _grid_position(track_data, grid_no)
	if track_data != null:
		root.rotation.y = track_data.grid_heading(grid_no)  # 车头朝起点切线
	CarBuilder.apply(v, Match.car_cfg(cid), stats, race.env_cfg, torque_scale)
	# 物理分层（约定见 Racer 头注释）：车体在车辆层+检测层，撞世界也撞车；
	# 倒转/跌落复位幽灵时由 Racer.apply_ghost 切到仅检测层
	v.collision_layer = Racer.CAR_LAYER
	v.collision_mask = Racer.CAR_MASK
	CarMeshBuilder.attach_visual(v, cid, appearance)  # 美术装配，缺资源自动回退占位视觉
	# 车-车碰撞冲击放大（Game 表 bump_* 可调）：双方各挂一份、各推自己一记，
	# 撞点夹取进碰撞盒求力矩 → 角落撞甩尾、正撞硬推；重击另开失稳窗口
	# （被撞车回稳系统短暂降压，见 collision_kick.gd）
	var kick := COLLISION_KICK.new()
	kick.name = "CollisionKick"
	v.add_child(kick)
	kick.setup(v, {
		"strength": Match.game_cfg("bump_strength"),
		"min_speed": Match.game_cfg("bump_min_speed"),
		"max_speed": Match.game_cfg("bump_max_speed"),
		"yaw": Match.game_cfg("bump_yaw"),
		"destab_speed": Match.game_cfg("bump_destab_speed"),
		"destab_time": Match.game_cfg("bump_destab_time"),
		"destab_grip": Match.game_cfg("bump_destab_grip"),
	})
	# 出生抬高 SPAWN_DROP（见常量注释）：挂点 y 须在美术装配后读取，
	# 占位回退路径不写挂点，保留场景默认值。
	v.position = Vector3(0, _rest_height(v) + SPAWN_DROP, 0)
	root.add_child(v)
	race.add_child(root)
	CarBuilder.add_team_banner(v, PLAYER_COLOR if is_player else AI_COLORS[ai_idx % AI_COLORS.size()])

	# 注意：脚本必须在入树前附加，否则 _physics_process 不会被启用
	var ctrl := Node3D.new()
	ctrl.name = "Driver"
	if is_player:
		ctrl.set_script(PLAYER_SCRIPT)
	else:
		ctrl.set_script(AI_SCRIPT)
	root.add_child(ctrl)
	if is_player:
		v.add_to_group("player_car")
		ctrl.setup(v, track_data, race)
		_attach_engine_audio(v)
	else:
		ctrl.setup(v, track_data, _grid_lane(track_data, grid_no))
	var r := Racer.new()
	r.name = rname
	r.is_player = is_player
	r.vehicle = v
	r.ctrl = ctrl
	return r

## NPC 交通靶车生成（Game 表 npc_count/npc_hp/npc_speed_scale 可调）：
## 沿主路中后段均匀铺开，避开头部发车区；数量为 0 时整段跳过（配表可一键关闭）
static func _spawn_npcs(race: RaceManager, track: Node3D, track_data: TrackData, loot_cb: Callable) -> void:
	var count := int(Match.game_cfg("npc_count"))
	if count <= 0:
		return
	var hp := Match.game_cfg("npc_hp")
	var speed_scale := Match.game_cfg("npc_speed_scale")
	for i in count:
		var cid: int = NPC_CAR_IDS[i % NPC_CAR_IDS.size()]
		var spot := _npc_spot(track, track_data, i, count)
		_make_npc(race, track_data, cid, spot, hp, speed_scale, loot_cb)

## NPC 出生点：有赛道数据 = 主路弧长 [0.2L, 0.92L] 均匀取点 + 横向随机车道，
## 车头朝路线切线；兜底直线图复用主路 loot 点（贴地、朝 -z）
static func _npc_spot(track: Node3D, track_data: TrackData, i: int, count: int) -> Dictionary:
	if track_data != null:
		var t := (float(i) + 0.5) / float(count)
		var s := lerpf(track_data.length * 0.2, track_data.length * 0.92, t)
		var lane := randf_range(-0.3, 0.3) * track_data.width_at(s)
		var pos: Vector3 = track_data.point_at(s) + track_data.normal_at(s) * lane
		var tang: Vector3 = track_data.point_at(s + 2.0) - track_data.point_at(maxf(s - 2.0, 0.0))
		return {"pos": pos, "yaw": atan2(-tang.x, -tang.z), "lane": lane}
	var pts: Array = track.main_route_points(count)
	var p: Vector3 = pts[i % pts.size()]
	return {"pos": Vector3(p.x, 0.0, p.z), "yaw": 0.0, "lane": p.x}

## NPC 单车装配：与 _make_racer 同款物理/视觉/冲击链路，差异：
## - 挂 CarHealth（可被撞损，CollisionKick 按接近速度结算伤害）；
## - Driver 换 npc_car.gd（慢速巡航 + 撞爆掉落），不建 Racer（不排名不解冻依赖）
static func _make_npc(race: RaceManager, track_data: TrackData, cid: int, spot: Dictionary, hp: float, speed_scale: float, loot_cb: Callable) -> void:
	var root := Node3D.new()
	root.name = "NPC-%d" % cid
	var v: Vehicle = CAR_SCENE.instantiate()
	root.position = spot.pos
	root.rotation.y = spot.yaw
	CarBuilder.apply(v, Match.car_cfg(cid), Match.stats_for_car(cid, {}), race.env_cfg, 1.0)
	v.collision_layer = Racer.CAR_LAYER
	v.collision_mask = Racer.CAR_MASK
	CarMeshBuilder.attach_visual(v, cid, {})  # 70x 段暂无美术 → 占位视觉
	var kick := COLLISION_KICK.new()
	kick.name = "CollisionKick"
	v.add_child(kick)
	kick.setup(v, {
		"strength": Match.game_cfg("bump_strength"),
		"min_speed": Match.game_cfg("bump_min_speed"),
		"max_speed": Match.game_cfg("bump_max_speed"),
		"yaw": Match.game_cfg("bump_yaw"),
		"destab_speed": Match.game_cfg("bump_destab_speed"),
		"destab_time": Match.game_cfg("bump_destab_time"),
		"destab_grip": Match.game_cfg("bump_destab_grip"),
		"damage_coeff": Match.game_cfg("npc_damage_coeff"),
	})
	var health := CarHealth.new()
	health.name = "CarHealth"
	v.add_child(health)
	health.setup(hp)
	v.position = Vector3(0, _rest_height(v) + SPAWN_DROP, 0)
	root.add_child(v)
	race.add_child(root)
	CarBuilder.add_team_banner(v, NPC_COLOR)
	# 脚本须在入树前附加（同 _make_racer），否则 _physics_process 不启用
	var ctrl := Node3D.new()
	ctrl.name = "Driver"
	ctrl.set_script(NPC_SCRIPT)
	root.add_child(ctrl)
	ctrl.setup(v, track_data, spot.lane, speed_scale, race, loot_cb)

## 玩家车引擎声：VNS 合成组件（多 RPM 分层交叉淡化 + 事件音效），
## 采样库缺失时回退 GEVP 自带单采样变调，保证不出无声车
static func _attach_engine_audio(v: Vehicle) -> void:
	var snd := EngineAudioVNS.new()
	snd.position = Vector3(0, 0.6, 0)
	v.add_child(snd)
	if snd.setup(v):
		return
	snd.queue_free()
	var fallback := ENGINE_SOUND.instantiate()
	fallback.max_db = -16.0
	fallback.vehicle = v  # engine_sound.gd 导出类型是 Vehicle 节点
	v.add_child(fallback)

## 车身原点静止贴地高度：静止时轮心恰落回挂点 y（body.json 标定，
## vehicle.initialize() 的挂点抬升与静态压缩抵消），地面在挂点 y − 胎半径，
## 故原点离地 = 胎半径 − 挂点 y（前后轴取平均）。推导与
## car_mesh_builder._setup_collision 的 ground_y 同源。留 1cm 余量：
## 轮射线恰触地时 is_colliding 处于端点边界，浮点误差可能判空。
static func _rest_height(v: Vehicle) -> float:
	return ((v.front_tire_radius - v.front_left_wheel.position.y)
			+ (v.rear_tire_radius - v.rear_left_wheel.position.y)) * 0.5 + 0.01

static func _grid_position(track_data: TrackData, grid_no: int) -> Vector3:
	if track_data != null:
		return track_data.grid_position(grid_no)
	var z := -6.0 + float(grid_no - 1) * 8.0
	var x := -3.5 if grid_no % 2 == 1 else 3.5
	return Vector3(x, 0, z)

## AI 车道:有赛道数据 = 中心线横向偏移;旧图 = 世界 x
static func _grid_lane(track_data: TrackData, grid_no: int) -> float:
	if track_data != null:
		return track_data.grid_lane(grid_no)
	return -3.5 if grid_no % 2 == 1 else 3.5
