class_name Racer
extends RefCounted
## 单个参赛车的回合内运行时状态（排名 / 冲线 / HUD 展示共用），
## 替代原先散落在 RaceManager 里的 racer 字典。

var name := ""
var is_player := false
var vehicle: Vehicle
var ctrl: Node3D
var finished := false
var finish_time := 0.0
var progress := 0.0  # 弧长进度（旧图 = -z）
var hint := -1       # progress_at 下次搜索的索引提示

func mark_finished(t: float) -> void:
	finished = true
	finish_time = t

## 跌落复位保护：拉回主路并清空速度
func recover_to(p: Vector3) -> void:
	vehicle.global_position = p
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
