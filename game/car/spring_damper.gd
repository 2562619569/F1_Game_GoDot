class_name SpringDamper
extends RefCounted
## 精确弹簧阻尼器（帧率无关），算法出自 orangeduck《Spring-It-On: Spring-Roll-Call》
## https://theorangeduck.com/page/spring-roll-call
## 相比 lerp(x, t, k * delta)：任意 delta/参数下数值稳定，且速度连续，
## 目标突变时不会出现运动方向瞬跳，是姿态平滑"更自然"的关键。

const LN2_X4 := 4.0 * 0.6931471805599453

## 单步推进弹簧状态，返回 Vector2(x, v)。
## [code]frequency[/code] 响应频率（Hz），越大跟随越快；
## [code]damping_ratio[/code] 阻尼比：1.0 临界阻尼（最快无振荡），<1 欠阻尼（带一点弹性回摆）。
static func spring(x: float, v: float, goal: float,
		frequency: float, damping_ratio: float, dt: float) -> Vector2:
	if frequency <= 0.0 or dt <= 0.0:
		return Vector2(x, v)
	damping_ratio = clampf(damping_ratio, 0.05, 1.0)

	var s := TAU * frequency
	var y := s * damping_ratio
	var j0 := x - goal
	var j1 := v + j0 * y
	var eydt := exp(-y * dt)

	if damping_ratio < 0.999:
		# 欠阻尼：衰减振荡
		var w := s * sqrt(1.0 - damping_ratio * damping_ratio)
		var cos_wt := cos(w * dt)
		var sin_wt := sin(w * dt)
		# x(t) = e^{-yt} * (j0*cos(wt) + (j1/w)*sin(wt)) + goal
		var new_x := eydt * (j0 * cos_wt + (j1 / w) * sin_wt) + goal
		# dx/dt = e^{-yt} * ((j1 - y*j0)*cos(wt) - (w*j0 + j1*y/w)*sin(wt))
		var new_v := eydt * ((j1 - y * j0) * cos_wt - (w * j0 + (j1 * y) / w) * sin_wt)
		return Vector2(new_x, new_v)
	else:
		# 临界阻尼
		return Vector2(eydt * (j0 + j1 * dt) + goal, eydt * ((j1 - y * j0) - y * j1 * dt))

## halflife（半衰期，秒）→ 阻尼系数，供需要用半衰期直觉调参的场合
static func halflife_to_damping(halflife: float) -> float:
	if halflife <= 0.0:
		return 0.0
	return LN2_X4 / halflife
