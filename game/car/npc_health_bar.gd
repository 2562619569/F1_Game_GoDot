class_name NpcHealthBar
extends Node3D
## NPC 车顶血条（装配型，挂在 Vehicle 下，节点名固定 "HealthBar"）。
## 深色底片 + 彩色填充片双 QuadMesh，材质开 billboard 始终面向相机；
## 满血隐藏不挡视线，首次受击才出现，归零随撞爆整车退场一并销毁。
## 血量比例驱动填充片左端锚定缩放，配色绿→黄→红（无光照+自发光，
## 阴雨/夜景可读）。血量变化由 CarHealth.changed 信号驱动，无逐帧轮询。

const WIDTH := 1.15          # 底片总宽（m，约车宽量级）
const HEIGHT := 0.12         # 底片高（m）
const INSET := 0.03          # 填充片四边内缩（m），露出底片描边
const BAR_Y := 1.55          # 车体局部高度（车顶/队伍横幅之上）
const VIEW_RANGE := 80.0     # 距离裁剪（m）：远处只看车不见血条，省 clutter
const BG_COLOR := Color(0.04, 0.04, 0.06, 0.6)

var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _ratio := 1.0

func setup(v: Vehicle) -> void:
	position = Vector3(0, BAR_Y, 0)
	var bg := _make_quad("BarBg", Vector2(WIDTH, HEIGHT), BG_COLOR, false)
	add_child(bg)
	_fill = _make_quad("Fill", Vector2(WIDTH - INSET * 2.0, HEIGHT - INSET * 2.0),
			Color.GREEN, true)
	_fill.position.z = 0.004   # 压在底片之前，避免同层透明排序抖动
	add_child(_fill)
	_fill_mat = _fill.material_override as StandardMaterial3D
	_fill_mat.render_priority = 1  # 材质级排序：填充片盖在底片上（透明队列稳定）
	visible = false
	var health := v.get_node_or_null("CarHealth")
	if health is CarHealth:
		(health as CarHealth).changed.connect(_on_changed)

func _make_quad(node_name: String, size: Vector2, color: Color, glow: bool) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	var quad := QuadMesh.new()
	quad.size = size
	m.mesh = quad
	m.visibility_range_end = VIEW_RANGE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true   # 保留节点缩放（填充片靠 scale.x 表达血量）
	mat.albedo_color = color
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 1.4
	m.material_override = mat
	return m

func _on_changed(cur: float, max: float) -> void:
	_ratio = clampf(cur / maxf(max, 1.0), 0.0, 1.0)
	visible = _ratio > 0.0 and _ratio < 1.0
	var fw := WIDTH - INSET * 2.0
	_fill.scale.x = maxf(_ratio, 0.001)   # 0 缩放退化矩阵，归零反正已隐藏
	_fill.position.x = -fw * (1.0 - _ratio) * 0.5   # 左端锚定，从左往右掉
	var c := _ratio_color()
	_fill_mat.albedo_color = c
	_fill_mat.emission = c

## 比例配色：色相绿(0.33)→红(0) 线性，饱和度/亮度固定
func _ratio_color() -> Color:
	return Color.from_hsv(lerpf(0.0, 0.33, _ratio), 0.75, 1.0)
