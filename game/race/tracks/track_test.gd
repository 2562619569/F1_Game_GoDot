extends Node3D
## 基础测试赛道（A→B 点对点冲刺）：
## - 主路：Road 组，双向车道宽 24m，随机散落基础改件；
## - 高危分支：Dirt 组，右侧绕行 + 飞坡，必出高稀有度改件；
## - 起点排位区 z≈0，终点门 z=-500。
## 后期正式地图替换：实现同名的 finish_z / main_route_points /
## hazard_route_points / setup(env) 接口即可无缝换图。

const FINISH_Z := -500.0
const MAIN_LOOT_Z_FROM := -70.0
const MAIN_LOOT_Z_TO := -480.0
## 高危分支固定掉落点（避开飞坡区 z∈[-219,-245]）
const HAZARD_LOOT_POINTS := [
	Vector3(20, 0.9, -165),
	Vector3(20, 0.9, -205),
	Vector3(20, 0.9, -270),
]

func setup(env: Dictionary) -> void:
	($Road/Mesh.material_override as StandardMaterial3D).albedo_color = env.road_c
	if bool(env.get("wet", false)):
		($Road/Mesh.material_override as StandardMaterial3D).roughness = 0.22
		($Road/Mesh.material_override as StandardMaterial3D).metallic = 0.25
	else:
		($Road/Mesh.material_override as StandardMaterial3D).roughness = 0.9
		($Road/Mesh.material_override as StandardMaterial3D).metallic = 0.0
	for path in ["BranchMid", "BranchEntry", "BranchExit", "Ramp"]:
		(get_node(path + "/Mesh").material_override as StandardMaterial3D).albedo_color = env.dirt_c
	($BaseGrass/Mesh.material_override as StandardMaterial3D).albedo_color = env.grass

func get_finish_z() -> float:
	return FINISH_Z

## 主路掉落点：均匀铺开 + 抖动
func main_route_points(count: int) -> Array:
	var pts: Array = []
	for i in count:
		var t := (float(i) + 0.5) / float(count)
		var z: float = lerpf(MAIN_LOOT_Z_FROM, MAIN_LOOT_Z_TO, t) + randf_range(-10.0, 10.0)
		var x: float = randf_range(-9.0, 9.0)
		pts.append(Vector3(x, 0.9, z))
	return pts

func hazard_route_points() -> Array:
	return HAZARD_LOOT_POINTS.duplicate()
