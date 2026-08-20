extends Node
## 整局比赛的全局状态（Autoload: Match）。
## 大厅 / 房间 / 选车 / 回合 / 局间整备共享的数据集中在这里，
## 界面场景只做展示与交互，方便后期替换 UI 而不动数据逻辑。
##
## 数据来源全部为 config/dist 配表（Settings autoload），
## 不在代码里硬编码赛制数值。

signal backpack_changed
signal equipped_changed
signal cosmetics_changed

const PLAYER_NAME := "YOU"
## AI 对手池：名字 / 底盘 / 强度系数（作用于扭矩，制造名次差异）。
## 底盘只有 601~603 三台玩家车，第 4 个起循环复用；强度递减制造梯队。
## 实际入座数量由 ai_count 决定（房间界面 +ADD AI 调整）。
const AI_DEFS := [
	{"name": "RIVAL-1", "car_id": 601, "skill": 1.0},
	{"name": "RIVAL-2", "car_id": 602, "skill": 0.93},
	{"name": "RIVAL-3", "car_id": 603, "skill": 0.87},
	{"name": "RIVAL-4", "car_id": 601, "skill": 0.82},
	{"name": "RIVAL-5", "car_id": 602, "skill": 0.78},
	{"name": "RIVAL-6", "car_id": 603, "skill": 0.74},
	{"name": "RIVAL-7", "car_id": 601, "skill": 0.70},
]

## Car 表 id 段边界：≥ 此值为 NPC 交通车专用段（race_builder.NPC_CAR_IDS），
## 不进玩家选车/展台（car_stage.car_ids 过滤）
const NPC_ID_BASE := 700

## 性能槽类别（受 perf_slots 限制）与功能槽类别（受 func_slots 限制）
const PERF_CATEGORIES := ["engine", "tires", "aero", "chassis"]
const FUNC_CATEGORIES := ["tactical"]

## 外观槽类别（纯外观件：不占性能/功能槽、不进掉落，默认全解锁）
const COSMETIC_CATEGORIES := ["wheel"]

## 改件稀有度颜色（UI 与掉落物共用）
const RARITY_COLORS := [
	Color(0, 0, 0),            # 占位
	Color(0.60, 0.63, 0.66),   # 1 普通
	Color(0.30, 0.80, 0.37),   # 2 优秀
	Color(0.18, 0.59, 0.95),   # 3 稀有
	Color(0.75, 0.33, 0.90),   # 4 史诗
]
const RARITY_NAMES := ["", "Common", "Rare", "Epic", "Legendary"]

# ---- 单局状态 ----
var car_id := 601                  # 玩家所选底盘（Car 表 id，601~ 段）
var backpack: Array = []           # 无限背包：拥有的改件 id 列表
var equipped := {}                 # category -> part_id（同类型唯一装配）
var cosmetics := {}                # category -> cosmetic_id（外观件装配，独立于 equipped）

var round_index := 0               # 当前回合序号（1~round_count）
var ai_count := 4                  # 房间当前入座 AI 数（player_max-1 为上限，reset 回默认 4）
var round_history: Array = []      # 每回合结算 [{name, is_player, rank, time, dnf, points}]
var points := {}                   # racer name -> 累计积分（Round 表按名次累加）
var next_grid := {}                # racer name -> 下回合发车位（1 = 最前）
var upcoming_map_id := 1           # 已预报的下回合地图（局间展示 + 下回合实际使用）
var champion := ""                 # 积分总冠军名（决赛后按累计积分定）

# ---- 测试辅助 ----
var auto_test := false             # 冒烟测试：玩家车自动驾驶
var intermission_sec_override := 0 # >0 时局间倒计时用该值（测试提速）

func reset() -> void:
	car_id = 601
	backpack = []
	equipped = {}
	cosmetics = {}
	round_index = 0
	ai_count = 4
	round_history = []
	points = {}
	next_grid = {}
	upcoming_map_id = _roll_map_for_round(1)
	champion = ""
	equipped_changed.emit()
	backpack_changed.emit()
	cosmetics_changed.emit()

# ---------------- 配表读取 ----------------

func game_cfg(key: String) -> float:
	for row in Settings.game.data.values():
		if row.key == key:
			return row.value
	push_warning("Game 表缺少 key: %s" % key)
	return 0.0

func round_count() -> int:
	return int(game_cfg("round_count"))

## 房间当前实际入座的 AI 定义（AI_DEFS 前 ai_count 个），
## race_builder / 房间界面共用，改 ai_count 后取到的名单即时变化。
func active_ai_defs() -> Array:
	return AI_DEFS.slice(0, clampi(ai_count, 0, AI_DEFS.size()))

func car_cfg(cid := car_id) -> Dictionary:
	return Settings.car.data[cid]

func round_cfg(idx := round_index) -> Dictionary:
	return Settings.round.data[clampi(idx, 1, round_count())]

## 名次 -> 本回合积分（Round 表 points 列，索引 = 名次-1）。
## 名次超出表长度（如 8 车满编配 4 位表）或非法名次按 0 分处理。
func round_points_for(rank: int, idx := round_index) -> int:
	if rank < 1:
		return 0
	var arr: Array = round_cfg(idx).points
	if rank > arr.size():
		return 0
	return int(arr[rank - 1])

## 累计积分快照：RoundResult.build 计算决赛冠军时传入（保持其纯函数性）
func points_snapshot() -> Dictionary:
	return points.duplicate()

func map_cfg(mid: int) -> Dictionary:
	return Settings.map.data[mid]

func part_cfg(pid: int) -> Dictionary:
	return Settings.part.data[pid]

## 为某回合从 map_pool 随机选图
func _roll_map_for_round(idx: int) -> int:
	var pool: PackedStringArray = String(round_cfg(idx).map_pool).split("|")
	var pick := pool[randi() % pool.size()] if pool.size() > 0 else "1"
	return int(pick)

## 回合结束后滚动"下回合地图预报"（决赛后不再滚动）
func roll_upcoming_map() -> void:
	var next_idx := round_index + 1
	if next_idx <= round_count():
		upcoming_map_id = _roll_map_for_round(next_idx)

# ---------------- 背包 / 装配 ----------------

func add_to_backpack(pid: int) -> void:
	backpack.append(pid)
	backpack_changed.emit()

## 槽位限制：性能件数 ≤ perf_slots，功能件数 ≤ func_slots
func can_equip(pid: int) -> bool:
	var p := part_cfg(pid)
	if FUNC_CATEGORIES.has(p.category):
		return _count_in(FUNC_CATEGORIES) < func_slots()
	return _count_in(PERF_CATEGORIES) < perf_slots()

func equip_part(pid: int) -> void:
	var p := part_cfg(pid)
	if not can_equip(pid) and not equipped.has(p.category):
		return  # 槽位已满且该类别未占用
	equipped[p.category] = pid
	equipped_changed.emit()

func unequip_category(category: String) -> void:
	if equipped.erase(category):
		equipped_changed.emit()

func perf_slots() -> int:
	return int(car_cfg().perf_slots)

func func_slots() -> int:
	return int(car_cfg().func_slots)

func _count_in(cats: Array) -> int:
	var n := 0
	for c in cats:
		if equipped.has(c):
			n += 1
	return n

# ---------------- 外观件（纯装饰，不占改件槽） ----------------

func cosmetic_cfg(cid: int) -> Dictionary:
	return Settings.cosmetic.data[cid]

## 类别默认外观件 id（该类别最小 id，即建表首行）
func default_cosmetic_id(category: String) -> int:
	var best := -1
	for c in Settings.cosmetic.data.values():
		if c.category == category and (best < 0 or c.id < best):
			best = c.id
	return best

## 类别当前外观件 id（未选择时取默认）
func cosmetic_id(category: String) -> int:
	return cosmetics.get(category, default_cosmetic_id(category))

func set_cosmetic(category: String, cid: int) -> void:
	if not Settings.cosmetic.data.has(cid) or Settings.cosmetic.data[cid].category != category:
		push_warning("Match: %d 不是 %s 类外观件，忽略" % [cid, category])
		return
	if cosmetics.get(category, -1) == cid:
		return
	cosmetics[category] = cid
	cosmetics_changed.emit()

## 统一外观描述（CarMeshBuilder.attach_visual 消费）：
##   wheel = 轮毂资产 id；tire = 轮胎资产 id（已装轮胎改件的 model 列，未装 = 原厂胎）。
##   轮毂优先级：玩家已选外观件 > Car 配表 wheel 列（各车默认轮毂）> DEFAULT_HUB 兜底。
##   未来车漆/尾翼等外观项在本 dict 加 key 扩展，下游签名不变。
## hub_model 传空串 = 按上述优先级取默认；AI 侧用 appearance_for_car 取其车型默认。
func appearance(eq := equipped, hub_model := "") -> Dictionary:
	if hub_model == "":
		if cosmetics.has("wheel"):
			hub_model = String(cosmetic_cfg(cosmetics["wheel"]).model)
		else:
			hub_model = default_hub_for_car(car_id)
	var tire_model := String(CarMeshBuilder.DEFAULT_TIRE)
	if eq.has("tires"):
		var m := String(part_cfg(eq["tires"]).model)
		if m != "":
			tire_model = m
	return {"wheel": hub_model, "tire": tire_model}

## AI 车辆外观：胎模跟随其随机装配，轮毂用其车型默认（Car 配表 wheel 列）
func appearance_for_car(cid: int, eq: Dictionary) -> Dictionary:
	return appearance(eq, default_hub_for_car(cid))

## 车型默认轮毂：Car 配表 wheel 列，空串/缺失回退 CarMeshBuilder.DEFAULT_HUB
func default_hub_for_car(cid: int) -> String:
	var w := String(car_cfg(cid).get("wheel", ""))
	return w if w != "" else String(CarMeshBuilder.DEFAULT_HUB)

# ---------------- 属性合成（底盘 + 已装备改件） ----------------

## 返回展示/物理共用的属性表：
## top_speed / accel / grip_road / grip_offroad / grip_wet / aero / landing / mass
func get_stats() -> Dictionary:
	return stats_for_car(car_id, equipped)

func stats_for_car(cid: int, eq: Dictionary) -> Dictionary:
	var c := car_cfg(cid)
	var s := {
		"top_speed": float(c.top_speed), "accel": float(c.accel),
		"grip_road": float(c.grip_road) * 2.0, "grip_offroad": float(c.grip_offroad) * 2.0,
		"grip_wet": 0.0, "aero": 0.0, "landing": 0.0, "mass": 0.0,
	}
	for pid in eq.values():
		var p := part_cfg(pid)
		s.top_speed += p.top_speed
		s.accel += p.accel
		s.grip_road += p.grip_road
		s.grip_offroad += p.grip_offroad
		s.grip_wet += p.grip_wet
		s.aero += p.aero
		s.landing += p.landing
		s.mass += p.mass
	return s

## 仅底盘属性（雷达图里的"改装前"对照）
func base_stats() -> Dictionary:
	return stats_for_car(car_id, {})

# ---------------- 掉落 / 奖励 ----------------

## 按权重抽稀有度（weights 对应 rarity 1~4），带保底
func roll_rarity(rarity_weights: Array, guarantee := 0) -> int:
	var total := 0.0
	for w in rarity_weights:
		total += w
	var roll := randf() * total
	var rarity := 1
	var acc := 0.0
	for i in rarity_weights.size():
		acc += rarity_weights[i]
		if roll <= acc:
			rarity = i + 1
			break
	return maxi(rarity, guarantee)

## 在类别池里按稀有度抽一件（类别内稀有度不足时向下夹到该类别最高档，
## 使 Loot 表的 guarantee_rarity 保底不会被回退打破）
func roll_part(category: String, min_rarity := 1) -> int:
	var candidates: Array = []
	for p in Settings.part.data.values():
		if p.category == category and p.rarity >= min_rarity:
			candidates.append(p.id)
	if candidates.is_empty():
		candidates = _parts_at_max_rarity(category)
	if candidates.is_empty():
		push_warning("Part 表缺少类别: %s" % category)
		return 0
	return candidates.pick_random()

## 类别内最高稀有度档的全部部件 id（roll_part 空回退夹档用）
func _parts_at_max_rarity(category: String) -> Array:
	var max_r := 0
	for p in Settings.part.data.values():
		if p.category == category:
			max_r = maxi(max_r, int(p.rarity))
	var out: Array = []
	for p in Settings.part.data.values():
		if p.category == category and int(p.rarity) == max_r and max_r > 0:
			out.append(p.id)
	return out

## 按 Loot 表生成一条路线的掉落改件 id 列表
func roll_route_drops(route: String) -> Array:
	for rule in Settings.loot.data.values():
		if rule.route != route:
			continue
		var w_parts: PackedStringArray = String(rule.rarity_weights).split("|", false)
		var weights: Array = []
		for s in w_parts:
			weights.append(float(s))
		var cats: PackedStringArray = String(rule.category_pool).split("|", false)
		var out: Array = []
		for i in int(rule.drop_count):
			var rarity := roll_rarity(weights, int(rule.guarantee_rarity))
			out.append(roll_part(cats[randi() % cats.size()], rarity))
		return out
	push_warning("Loot 表缺少路线: %s" % route)
	return []

## 回合结算：按 RankReward 表计算奖励改件列表（纯计算，不入包）
func compute_rank_rewards(rank: int) -> Array:
	if not Settings.rank_reward.data.has(rank):
		return []
	var rr: Dictionary = Settings.rank_reward.data[rank]
	var out: Array = []
	var cats: PackedStringArray = "engine|tires|aero|chassis|tactical".split("|")
	for i in int(rr.reward_count):
		# 类别随机（含战术件），稀有度保底取表值
		out.append(roll_part(cats[randi() % cats.size()], int(rr.reward_rarity_min)))
	return out

## 回合结算：计算并发放奖励改件到背包，返回 [改件id]
func grant_rank_rewards(rank: int) -> Array:
	var out := compute_rank_rewards(rank)
	for pid in out:
		add_to_backpack(pid)
	return out

## 回合结算的唯一写入口：RaceManager 产出 RoundResult 后由这里提交到全局状态
## （发车位 / 奖励入包 / 积分累计 / 回合历史 / 下回合地图 / 冠军）。
## 未来联机或独立结算系统只需替换本方法，RaceManager 不再直写这些字段。
func commit_round(res: RoundResult) -> Array:
	next_grid = res.next_grid.duplicate()
	var rewards := compute_rank_rewards(res.player_rank)
	for pid in rewards:
		add_to_backpack(pid)
	for e in res.results:
		points[e.name] = int(points.get(e.name, 0)) + int(e.points)
	round_history.append(res.results)
	roll_upcoming_map()
	if res.champion != "" and champion == "":
		champion = res.champion
	return rewards

## 名次 -> 下回合发车位（倒序发车：第 1 名发最后）。
## 发车格是地图编辑器定义的满编网格（grid.count=8，与 player_max / RankReward
## 行数一致）：grid_next 直接就是格号（1=杆位，表内最大值=末位），车数不足时
## 靠后的格子空着。不按实际车数折叠/钳制——旧钳制曾把 8/7/6/5 全压到 4 号位，
## 造成下回合全员同格堆叠生成。
func grid_for_rank(rank: int) -> int:
	var full := 0
	for rr in Settings.rank_reward.data.values():
		full = maxi(full, int(rr.grid_next))
	if Settings.rank_reward.data.has(rank):
		return clampi(int(Settings.rank_reward.data[rank].grid_next), 1, full)
	return clampi(full - rank + 1, 1, full)
