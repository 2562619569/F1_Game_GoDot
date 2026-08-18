class_name Racer
extends RefCounted
## 单个参赛车的回合内运行时状态（排名 / 冲线 / HUD 展示共用），
## 替代原先散落在 RaceManager 里的 racer 字典。

## 物理分层约定（值 = Godot collision_layer 位值）：
## 1 = 世界（路面/护栏/道具等静态体）；2 = 车辆物理体（车-车碰撞）；
## 4 = 车辆检测层（FinishGate/掉落物等 Area 只认这一层，幽灵中也不失效）。
## 车体 layer = 2|4、mask = 1|2；幽灵（倒转复位）时 layer = 4、mask = 1，
## 即只与世界碰撞、穿过且不被其他车撞到，但冲线/拾取检测不受影响。
const LAYER_WORLD := 1
const LAYER_CAR := 2
const LAYER_CAR_DETECT := 4
const CAR_LAYER := LAYER_CAR | LAYER_CAR_DETECT
const CAR_MASK := LAYER_WORLD | LAYER_CAR

## 幽灵视觉透明度（区别于隐身 0.65，半透明=复位保护提示）
const GHOST_ALPHA := 0.5

var name := ""
var is_player := false
var vehicle: Vehicle
var ctrl: Node3D
var finished := false
var finish_time := 0.0
var progress := 0.0  # 弧长进度（旧图 = -z）
var hint := -1       # progress_at 下次搜索的索引提示
var cp_reached := 0  # 已通过的最后一个检查点下标（0 = 起点线，只进不退）
var ghost_left := 0.0  # 幽灵剩余秒数（>0 = 半透明且无车-车碰撞）

func mark_finished(t: float) -> void:
	finished = true
	finish_time = t

## 检查点推进：进度越过下一个检查点弧长即记账（倒转/倒车不会回退）
func update_checkpoints(td: TrackData) -> void:
	var cps: PackedFloat32Array = td.checkpoints
	while cp_reached + 1 < cps.size() and progress >= cps[cp_reached + 1]:
		cp_reached += 1

## R 倒转复位：传送到检查点姿态（路面上方悬空、车头对齐切线、横纵姿态清零），
## 清空速度并作废进度搜索 hint（强制下次全局重搜）。
## 速度清零后车身会进入休眠、悬在落点上不沉降，须显式唤醒
func rewind_to(pose: Dictionary) -> void:
	if pose.is_empty():
		return
	vehicle.global_position = pose["pos"]
	vehicle.global_rotation = Vector3(0.0, pose["yaw"], 0.0)
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false
	hint = -1

## 跌落复位保护：拉回主路并清空速度（同样唤醒，防悬空休眠）
func recover_to(p: Vector3) -> void:
	vehicle.global_position = p
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.sleeping = false

## 幽隐切换：碰撞层/mask + 整车半透明（含轮件/灯罩等全部 GeometryInstance3D）
func apply_ghost(on: bool) -> void:
	if on:
		vehicle.collision_layer = LAYER_CAR_DETECT
		vehicle.collision_mask = LAYER_WORLD
		_set_alpha(GHOST_ALPHA)
	else:
		vehicle.collision_layer = CAR_LAYER
		vehicle.collision_mask = CAR_MASK
		_set_alpha(0.0)

func _set_alpha(a: float) -> void:
	for child in vehicle.find_children("*", "GeometryInstance3D", true, false):
		child.transparency = a
