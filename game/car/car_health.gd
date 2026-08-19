class_name CarHealth
extends Node
## 车辆血量组件（装配型，挂在 Vehicle 下，节点名固定 "CarHealth"）。
## 挂了才有可被撞损的血量：NPC 交通车挂、玩家/AI 赛车不挂 → 天然免疫碰撞伤害。
## 伤害入口是 CollisionKick（车-车碰撞按接近速度折算），归零 emit destroyed（只发
## 一次）；销毁表现与掉落由挂载方（npc_car.gd）接信号处理，本组件不自杀不刷特效。

signal destroyed(car: Node)

var hp := 100.0
var hp_max := 100.0
var damage_taken := 0.0  # 累计承伤（自检观测用）

func setup(max_hp: float) -> void:
	hp_max = maxf(max_hp, 1.0)
	hp = hp_max

func alive() -> bool:
	return hp > 0.0

## 负伤害与死后补刀直接忽略；归零当帧发 destroyed，重复调用不重发
func take_damage(amount: float) -> void:
	if hp <= 0.0 or amount <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	damage_taken += amount
	if hp <= 0.0:
		destroyed.emit(get_parent())
