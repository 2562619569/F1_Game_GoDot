class_name GhostStipple
extends RefCounted
## 回溯/跌落保护的幽灵视觉层：「间隔像素透明」+ 全车整体化。
## 旧方案是整身 GeometryInstance3D.transparency 半透明——alpha 混合对多网格
## 整车有内部排序与发糊问题；上一版抖纹逐材质保留原样，镂空后透出各部件
## 杂色叠层、观感零碎。本版给整车每个网格设 material_override = 同一个
## 幽灵材质（统一颜色 + 屏幕空间棋盘 discard），全车呈单色镂空的整体幽灵。
## material_override 整实例生效，直接盖住车漆/玻璃/轮件/刹车灯等全部
## 表面覆盖与 GLB 内置材质（均不动、不复制）；原 override 记账、恢复时
## 原样写回，多车互不影响。
## apply 幂等：幽灵期间每物理帧重入（RaceManager 计时循环）直接跳过。

const _GhostStippleShader := preload("res://game/car/shaders/ghost_stipple.gdshader")

## 棋盘格边长（屏幕像素）：与 shader 的 stipple_cell_px 默认值同步
const CELL_PX := 2.0
## 幽灵统一色（淡青）+ 轻微自发光（暗处/远看仍可辨识）
const GHOST_COLOR := Color(0.66, 0.85, 1.0)
const EMISSION_ENERGY := 0.4

var _ghost_mat: ShaderMaterial
## 替换现场：[{mi: MeshInstance3D, override: 原 material_override（可为 null）}]
var _saved: Array = []

func is_active() -> bool:
	return not _saved.is_empty()

## 把 root 子树内全部网格整体换成幽灵材质
func apply(root: Node3D) -> void:
	if is_active():
		return
	if _ghost_mat == null:
		_ghost_mat = ShaderMaterial.new()
		_ghost_mat.shader = _GhostStippleShader
		_ghost_mat.set_shader_parameter("ghost_color", GHOST_COLOR)
		_ghost_mat.set_shader_parameter("emission_energy", EMISSION_ENERGY)
		_ghost_mat.set_shader_parameter("ghost_stipple", 1.0)
		_ghost_mat.set_shader_parameter("stipple_cell_px", CELL_PX)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		_saved.append({"mi": mi, "override": mi.material_override})
		mi.material_override = _ghost_mat

## 恢复替换前的材质现场（含把 override 清回 null）
func restore() -> void:
	for entry in _saved:
		var mi: MeshInstance3D = entry["mi"]
		if is_instance_valid(mi):
			mi.material_override = entry["override"]
	_saved.clear()

## 测试核对用：材质是否为抖纹生效的幽灵材质
static func is_stippled(m: Material) -> bool:
	if not (m is ShaderMaterial):
		return false
	var gate: Variant = (m as ShaderMaterial).get_shader_parameter("ghost_stipple")
	return gate is float and gate > 0.5
