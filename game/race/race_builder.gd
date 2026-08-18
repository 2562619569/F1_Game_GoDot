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

const PLAYER_COLOR := Color(1.0, 0.85, 0.2)
const AI_COLORS := [Color(1.0, 0.3, 0.35), Color(0.3, 0.55, 1.0), Color(0.35, 0.85, 0.45)]

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

	# 碰撞震屏：PVC 自带 trigger_shake（无需另找模块），车身开启接触上报，
	# 按撞击相对速度映射强度/时长，轻蹭（<6 m/s）不触发；
	# cam_shake 总开关在相机内门控，脉冲与持续震动源一并生效/关闭
	var pv := player_racer.vehicle
	pv.contact_monitor = true
	pv.max_contacts_reported = 4
	pv.body_entered.connect(func(body: Node) -> void:
		var rel := pv.linear_velocity
		if body is RigidBody3D:
			rel -= body.linear_velocity
		var impact := rel.length()
		if impact > 6.0:
			cam.trigger_shake(clampf((impact - 6.0) / 40.0, 0.03, 0.3), 0.25))

	return {"track": track, "track_data": track_data, "racers": racers,
		"player_racer": player_racer, "player_torque": player_racer.vehicle.max_torque}

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
	CarMeshBuilder.attach_visual(v, cid, appearance)  # 美术装配，缺资源自动回退占位视觉
	# 出生即静态贴地（原为写死 0.95，各车壳挂点高度不同，倒计时冻结期间悬空坠落）。
	# 挂点 y 须在美术装配后读取：占位回退路径不写挂点，保留场景默认值。
	v.position = Vector3(0, _rest_height(v), 0)
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
