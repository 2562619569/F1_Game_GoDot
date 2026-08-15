extends Node
## 整局比赛的全局状态（Autoload: Match）。
## 大厅 / 房间 / 选车 / 回合 / 局间整备共享的数据集中在这里，
## 界面场景只做展示与交互，方便后期替换 UI 而不动数据逻辑。
##
## 数据来源全部为 config/dist 配表（Settings autoload），
## 不在代码里硬编码赛制数值。

signal backpack_changed
signal equipped_changed

const PLAYER_NAME := "YOU"
## AI 对手：名字 / 底盘 / 强度系数（作用于扭矩，制造名次差异）
const AI_DEFS := [
	{"name": "RIVAL-1", "car_id": 1, "skill": 1.0},
	{"name": "RIVAL-2", "car_id": 2, "skill": 0.93},
	{"name": "RIVAL-3", "car_id": 3, "skill": 0.87},
]

## 性能槽类别（受 perf_slots 限制）与功能槽类别（受 func_slots 限制）
const PERF_CATEGORIES := ["engine", "tires", "aero", "chassis"]
const FUNC_CATEGORIES := ["tactical"]

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
var car_id := 1                    # 玩家所选底盘（Car 表 id）
var backpack: Array = []           # 无限背包：拥有的改件 id 列表
var equipped := {}                 # category -> part_id（同类型唯一装配）

var round_index := 0               # 当前回合序号（1~round_count）
var round_history: Array = []      # 每回合结算 [{name, is_player, rank, time, dnf}]
var next_grid := {}                # racer name -> 下回合发车位（1 = 最前）
var upcoming_map_id := 1           # 已预报的下回合地图（局间展示 + 下回合实际使用）
var champion := ""                 # 决赛冠军名

# ---- 测试辅助 ----
var auto_test := false             # 冒烟测试：玩家车自动驾驶
var intermission_sec_override := 0 # >0 时局间倒计时用该值（测试提速）

func reset() -> void:
	car_id = 1
	backpack = []
	equipped = {}
	round_index = 0
	round_history = []
	next_grid = {}
	upcoming_map_id = _roll_map_for_round(1)
	champion = ""
	equipped_changed.emit()
	backpack_changed.emit()

# ---------------- 配表读取 ----------------

func game_cfg(key: String) -> float:
	for row in Settings.game.data.values():
		if row.key == key:
			return row.value
	push_warning("Game 表缺少 key: %s" % key)
	return 0.0

func round_count() -> int:
	return int(game_cfg("round_count"))

func car_cfg(cid := car_id) -> Dictionary:
	return Settings.car.data[cid]

func round_cfg(idx := round_index) -> Dictionary:
	return Settings.round.data[clampi(idx, 1, round_count())]

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

## 在类别池里按稀有度抽一件（稀有度不足时向上取最近的）
func roll_part(category: String, min_rarity := 1) -> int:
	var candidates: Array = []
	var fallback: Array = []
	for p in Settings.part.data.values():
		if p.category == category:
			fallback.append(p.id)
			if p.rarity >= min_rarity:
				candidates.append(p.id)
	var pool := candidates if candidates.size() > 0 else fallback
	return pool.pick_random()

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

## 回合结算：按 RankReward 表给玩家发奖励改件，返回 [改件id]
func grant_rank_rewards(rank: int) -> Array:
	if not Settings.rank_reward.data.has(rank):
		return []
	var rr: Dictionary = Settings.rank_reward.data[rank]
	var out: Array = []
	var cats: PackedStringArray = "engine|tires|aero|chassis|tactical".split("|")
	for i in int(rr.reward_count):
		# 类别随机（含战术件），稀有度保底取表值
		var pid := roll_part(cats[randi() % cats.size()], int(rr.reward_rarity_min))
		# 若保底稀有度抽不到则向上取最近稀有度的件已在 roll_part 内处理
		out.append(pid)
		add_to_backpack(pid)
	return out

## 名次 -> 下回合发车位（倒序发车：第 1 名发最后）
func grid_for_rank(rank: int, racer_count: int) -> int:
	if Settings.rank_reward.data.has(rank):
		return clampi(int(Settings.rank_reward.data[rank].grid_next), 1, racer_count)
	return rank
