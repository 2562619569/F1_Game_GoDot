class_name CollisionKick
extends Node3D
## 车-车碰撞冲击放大（装配型组件，挂在参赛 Vehicle 下）。
## 纯刚体盒对撞的冲击被高抓地轮胎和横摆稳定系统瞬间吃掉——等质量对推无弹性、
## 横向 Δv 半秒内被胎侧向力抵消、被撞偏航立刻被稳定扭矩拉正，观感上「撞了没反应」。
## 本组件在 body_entered 时按两车碰前接近速度补一记冲量（叠加在求解器响应之上）：
##   线性 J = strength × min(closing, max_speed) × 折合质量 μ（重车撞轻车，轻车弹得更多）；
##   角量把冲量放到「对方中心在本车碰撞盒上的最近点」求力矩——角落撞击自然甩尾、
##   正侧/正尾撞击天然无旋转（与真实盒碰撞一致），yaw 倍率再放大甩尾感。
## 只放大车-车（对方是 Vehicle 才处理），撞墙/路面不掺和；每台车只给自己施冲量，
## 双方组件各发一次、方向相反，总动量守恒。轻蹭（< min_speed）与冷却期内不放大。
## 参数由 race_builder 从 Game 表 bump_* 注入；缺省值与表内默认一致，自检可直接注入。
##
## 碰撞伤害（npc_damage_coeff）：车-车碰撞除冲量外还按接近速度折算伤害，只结算到
## 对方车挂的 CarHealth 子节点（NPC 交通车才有；玩家/AI 赛车不挂 → 免疫）。每次
## 碰撞各车组件只给「对方」记一次伤害：玩家撞 NPC 由玩家侧组件扣 NPC 血，NPC 互撞
## 双方组件各扣对方一次，不重不漏。伤害与冲量共用同一死区/冷却/限速，重撞重扣。
##
## 失稳窗口（destab_*）：冲量本身只给得起 ~0.1s 的旋转——高抓地胎（μ≈3）+ 0.9
## 自动反打 + 横摆稳定会把甩尾角速度瞬间吃掉（实测 8 m/s 角撞 0.6s 仅偏转 1.8°），
## 加大冲量只是线性放大晃动幅度，转不成失控。因此重击（≥ destab_speed）时给
## 挨打方开一个随接近速度拉长的窗口：期内轮胎摩擦、countersteer_assist、横摆稳定
## 强度统一压低，让旋转活到轮胎真正重新咬合的那一刻；窗口到期恢复原值。主动
## 撞人方只拿 ATTACKER_SHARE 份额（撞人有代价但不至于自毁）。胎摩擦字典与轮子
## 共享引用，且轮子的 current_cof 只在表面切换时重读——两处必须同步刷。

const COOLDOWN_SEC := 0.25  # 同车两次放大最小间隔（防弹球式连环补刀）
const R_Y_CLAMP := 0.15     # 力矩臂竖直分量上限：低盒「撞不翻」的设计不被俯仰放大破坏
const DEFAULT_STRENGTH := 0.7
const DEFAULT_MIN_SPEED := 2.0
const DEFAULT_MAX_SPEED := 25.0
const DEFAULT_YAW := 2.5
const ATTACKER_SHARE := 0.3       # 撞人方的失稳窗口份额
const DESTAB_MIN_TIME := 0.4      # 失稳窗口时长下限（s）
const DESTAB_COUNTERSTEER := 0.2  # 窗口内 countersteer_assist 压到的不超过值
const DESTAB_STAB_SCALE := 0.3    # 窗口内横摆稳定强度缩放
const DEFAULT_DESTAB_SPEED := 6.0
const DEFAULT_DESTAB_TIME := 1.0
const DEFAULT_DESTAB_GRIP := 0.40
const DEFAULT_DAMAGE_COEFF := 1.5  # 每米/秒接近速度（超死区部分）折算的伤害

var strength := DEFAULT_STRENGTH  # 冲量倍率（×接近速度×折合质量）
var min_speed := DEFAULT_MIN_SPEED  # 接近速度死区（m/s），低于只走原始求解
var max_speed := DEFAULT_MAX_SPEED  # 参与计算的接近速度上限（m/s）
var yaw := DEFAULT_YAW            # 甩尾力矩倍率
var destab_speed := DEFAULT_DESTAB_SPEED  # 触发失稳窗口的接近速度（m/s）
var destab_time := DEFAULT_DESTAB_TIME    # 失稳窗口时长上限（s）
var destab_grip := DEFAULT_DESTAB_GRIP    # 窗口内轮胎摩擦缩放
var damage_coeff := DEFAULT_DAMAGE_COEFF  # 碰撞伤害系数（对有 CarHealth 的对方车）

var _v: Vehicle
var _half := Vector3.ZERO    # 碰撞盒半尺寸（本车局部）
var _box_ofs := Vector3.ZERO  # 碰撞盒中心（本车局部，含挂点 transform）
var _has_box := false
var _cooldown := 0.0
var _pre_vel := Vector3.ZERO  # 本车上一物理步（碰前）速度：body_entered 触发时
							  # 读到的已是本步解算后的速度，直接用会低估撞击
var hits := 0                 # 已放大次数（自检观测用）
var damage_dealt := 0.0       # 已结算给对方车的伤害（自检观测用）
var _destab_left := 0.0       # 失稳窗口剩余时间（s，自检观测用）
var _destab_saved := false    # 窗口开启时是否已备份原稳定性参数
var _saved_countersteer := 0.0
var _saved_yaw_strength := 0.0
var _saved_cof := {}          # 原轮胎摩擦表快照（字典与轮子共享引用，须复制）

func setup(v: Vehicle, cfg := {}) -> void:
	_v = v
	strength = float(cfg.get("strength", DEFAULT_STRENGTH))
	min_speed = float(cfg.get("min_speed", DEFAULT_MIN_SPEED))
	max_speed = float(cfg.get("max_speed", DEFAULT_MAX_SPEED))
	yaw = float(cfg.get("yaw", DEFAULT_YAW))
	destab_speed = float(cfg.get("destab_speed", DEFAULT_DESTAB_SPEED))
	destab_time = float(cfg.get("destab_time", DEFAULT_DESTAB_TIME))
	destab_grip = float(cfg.get("destab_grip", DEFAULT_DESTAB_GRIP))
	damage_coeff = float(cfg.get("damage_coeff", DEFAULT_DAMAGE_COEFF))
	# body_entered 依赖接触上报（玩家的相机震屏接线另在 race_builder 单独连）
	v.contact_monitor = true
	v.max_contacts_reported = 4
	v.body_entered.connect(_on_body_entered)
	# 撞点按 CarMeshBuilder 重建的贴地底盘低盒取；占位凸包路径无盒 → 只给线性冲量
	var col := v.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		_half = (col.shape as BoxShape3D).size * 0.5
		_box_ofs = col.transform.origin
		_has_box = true

func _physics_process(_delta: float) -> void:
	if _v == null:
		return
	_pre_vel = _v.linear_velocity
	_cooldown = maxf(0.0, _cooldown - _delta)
	if _destab_left > 0.0:
		_destab_left -= _delta
		if _destab_left <= 0.0:
			_restore_stability()

func _on_body_entered(body: Node) -> void:
	if body == _v or not body is Vehicle:
		return  # 只放大车-车：墙/道具/掉落物走原始求解
	if _cooldown > 0.0:
		return
	var other := body as Vehicle  # 转型后才有 global_position/mass 的静态类型
	var n := _v.global_position - other.global_position
	n.y = 0.0  # 水平投影：冲击不带竖直分量，不把车拍离地
	if n.length_squared() < 0.0001:
		return
	n = n.normalized()
	# 接近速率：n 是「对方→自己」方向，彼此靠近时相对速度在 n 上的投影为负，
	# 取负得正的接近速率。对方速度同样优先取碰前值（对方也挂本组件时各存各的，
	# 双端读数一致）
	var other_pre := other.linear_velocity
	var other_kick := other.get_node_or_null("CollisionKick")
	if other_kick is CollisionKick:
		other_pre = (other_kick as CollisionKick)._pre_vel
	var closing := -(_pre_vel - other_pre).dot(n)
	if closing < min_speed:
		return
	var vc := minf(closing, max_speed)
	var mu := _v.mass * other.mass / (_v.mass + other.mass)  # 折合质量
	var j := strength * vc * mu
	_v.sleeping = false
	_v.apply_central_impulse(n * j)
	if _has_box:
		# 撞点 = 对方中心夹取进本车碰撞盒（车局部）；冲量绕质心的力矩即甩尾/点头
		var local := _v.to_local(other.global_position)
		var p := Vector3(clampf(local.x - _box_ofs.x, -_half.x, _half.x),
				clampf(local.y - _box_ofs.y, -_half.y, _half.y),
				clampf(local.z - _box_ofs.z, -_half.z, _half.z)) + _box_ofs
		var r := p - _v.center_of_mass
		r.y = clampf(r.y, -R_Y_CLAMP, R_Y_CLAMP)
		var f := _v.global_transform.basis.inverse() * (n * j)  # 冲量转本车局部
		_v.apply_torque_impulse(_v.global_transform.basis * (r.cross(f)) * yaw)
	_cooldown = COOLDOWN_SEC
	hits += 1
	if closing >= destab_speed:
		_apply_destab(closing, n, other_pre)
	# 碰撞伤害：只结算到对方车的 CarHealth（挂载约定见 npc_car.gd）；
	# closing 已过 min_speed 死区，伤害 = 系数 × 超死区接近速度（沿用 max_speed 封顶）
	var health := other.get_node_or_null("CarHealth")
	if health is CarHealth and damage_coeff > 0.0:
		var dmg := damage_coeff * maxf(0.0, vc - min_speed)
		if dmg > 0.0:
			damage_dealt += dmg
			(health as CarHealth).take_damage(dmg)

## 失稳窗口开启/续期：时长在 [DESTAB_MIN_TIME, destab_time] 间随超出阈值的接近
## 速度线性拉长；谁朝对方逼近得快谁是撞人方，挨打方拿全窗口、撞人方按份额打折。
## 参数只备份一次（窗口内重复挨撞只续时长），到期由 _physics_process 恢复。
func _apply_destab(closing: float, n: Vector3, other_pre: Vector3) -> void:
	var self_toward := -_pre_vel.dot(n)   # 本车逼近对方的分速
	var other_toward := other_pre.dot(n)  # 对方逼近本车的分速
	var share := ATTACKER_SHARE if self_toward > other_toward else 1.0
	var dur := lerpf(DESTAB_MIN_TIME, destab_time,
			clampf((closing - destab_speed) / 9.0, 0.0, 1.0)) * share
	if dur <= _destab_left:
		return
	if not _destab_saved:
		_destab_saved = true
		_saved_countersteer = _v.countersteer_assist
		_saved_yaw_strength = _v.stability_yaw_strength
		_saved_cof = _v.coefficient_of_friction.duplicate()
		_v.countersteer_assist = minf(_saved_countersteer, DESTAB_COUNTERSTEER)
		_v.stability_yaw_strength = _saved_yaw_strength * DESTAB_STAB_SCALE
		for k in _saved_cof:
			_v.coefficient_of_friction[k] = float(_saved_cof[k]) * destab_grip
		for wheel in _v.wheel_array:
			wheel.current_cof *= destab_grip  # 缓存与字典同步，见头注释
	_destab_left = dur

## 窗口到期：恢复被压低的稳定性参数；current_cof 按轮子当前表面从快照重取
func _restore_stability() -> void:
	_destab_left = 0.0
	if not _destab_saved:
		return
	_destab_saved = false
	_v.countersteer_assist = _saved_countersteer
	_v.stability_yaw_strength = _saved_yaw_strength
	for k in _saved_cof:
		_v.coefficient_of_friction[k] = _saved_cof[k]
	for wheel in _v.wheel_array:
		if _saved_cof.has(wheel.surface_type):
			wheel.current_cof = float(_saved_cof[wheel.surface_type])
