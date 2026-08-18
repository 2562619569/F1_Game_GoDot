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

const COOLDOWN_SEC := 0.25  # 同车两次放大最小间隔（防弹球式连环补刀）
const R_Y_CLAMP := 0.15     # 力矩臂竖直分量上限：低盒「撞不翻」的设计不被俯仰放大破坏
const DEFAULT_STRENGTH := 0.6
const DEFAULT_MIN_SPEED := 2.0
const DEFAULT_MAX_SPEED := 25.0
const DEFAULT_YAW := 1.0

var strength := DEFAULT_STRENGTH  # 冲量倍率（×接近速度×折合质量）
var min_speed := DEFAULT_MIN_SPEED  # 接近速度死区（m/s），低于只走原始求解
var max_speed := DEFAULT_MAX_SPEED  # 参与计算的接近速度上限（m/s）
var yaw := DEFAULT_YAW            # 甩尾力矩倍率

var _v: Vehicle
var _half := Vector3.ZERO    # 碰撞盒半尺寸（本车局部）
var _box_ofs := Vector3.ZERO  # 碰撞盒中心（本车局部，含挂点 transform）
var _has_box := false
var _cooldown := 0.0
var _pre_vel := Vector3.ZERO  # 本车上一物理步（碰前）速度：body_entered 触发时
							  # 读到的已是本步解算后的速度，直接用会低估撞击
var hits := 0                 # 已放大次数（自检观测用）

func setup(v: Vehicle, cfg := {}) -> void:
	_v = v
	strength = float(cfg.get("strength", DEFAULT_STRENGTH))
	min_speed = float(cfg.get("min_speed", DEFAULT_MIN_SPEED))
	max_speed = float(cfg.get("max_speed", DEFAULT_MAX_SPEED))
	yaw = float(cfg.get("yaw", DEFAULT_YAW))
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
