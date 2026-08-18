class_name GhostStipple
extends RefCounted
## 回溯/跌落保护的幽灵视觉层：「间隔像素透明」（屏幕空间 Bayer 有序抖纹）。
## 旧方案是整身 GeometryInstance3D.transparency 半透明——alpha 混合对多网格
## 整车有内部排序与发糊问题；本方案把整车有效材质换成抖纹变体：按可见度
## 丢弃部分屏幕像素、其余保持不透明，颜色观感与源材质一致、只是更透。
##   BaseMaterial3D（车漆/轮件/刹车灯/横幅）→ ghost_stipple.gdshader 等价参数材质
##   ShaderMaterial（玻璃/灯罩）→ duplicate 后开 glass.gdshader 内建 ghost_stipple
## 替换经 material_override / surface_override_material 按实例覆盖，原值记账、
## restore 原样写回；不触碰 GLB 导入的共享网格资源，多车互不影响。
## apply 幂等：幽灵期间每物理帧重入（RaceManager 计时循环）直接跳过。

const _GhostStippleShader := preload("res://game/car/shaders/ghost_stipple.gdshader")

## 抖动格边长（屏幕像素）：与两个 shader 的 stipple_cell_px 默认值同步
const CELL_PX := 2.0
## 像素保留比例（0=全透 1=不透）：0.25 比 50% 棋盘更透，轮廓仍清晰
const VISIBILITY := 0.25

## 替换现场：[{mi: MeshInstance3D, override: 原 material_override（可为 null）,
##            surfaces: {表面下标: 原 surface_override（可为 null）}}]
var _saved: Array = []
## 源材质 → 抖纹变体（按对象引用作键；同源多表面/轮件共享单例只做一份，
## 随本实例存亡，不跨回合滞留已释放材质）
var _variants: Dictionary = {}

func is_active() -> bool:
	return not _saved.is_empty()

## 把 root 子树内全部网格的有效材质换成抖纹变体。
## 有效材质 = 实例 material_override（整实例生效，轮件/横幅用法），
## 否则按表面取 surface_override（车漆/刹车灯用法），再退到 GLB 内置表面材质。
func apply(root: Node3D) -> void:
	if is_active():
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		if mi.material_override != null:
			_saved.append({"mi": mi, "override": mi.material_override, "surfaces": {}})
			mi.material_override = _variant(mi.material_override)
			continue
		var surfaces := {}
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			if src == null:
				continue
			surfaces[i] = mi.get_surface_override_material(i)
			mi.set_surface_override_material(i, _variant(src))
		if not surfaces.is_empty():
			_saved.append({"mi": mi, "override": null, "surfaces": surfaces})

## 恢复替换前的材质现场（含把 override 清回 null）
func restore() -> void:
	for entry in _saved:
		var mi: MeshInstance3D = entry["mi"]
		if is_instance_valid(mi):
			mi.material_override = entry["override"]
			for i in entry["surfaces"]:
				mi.set_surface_override_material(i, entry["surfaces"][i])
	_saved.clear()
	_variants.clear()

## 源材质 → 抖纹变体。未知材质类型原样返回（无抖纹但不致错）。
func _variant(src: Material) -> Material:
	if _variants.has(src):
		return _variants[src]
	var out: Material = src
	if src is ShaderMaterial:
		var dup := (src as ShaderMaterial).duplicate() as ShaderMaterial
		dup.set_shader_parameter("ghost_stipple", 1.0)
		dup.set_shader_parameter("stipple_cell_px", CELL_PX)
		dup.set_shader_parameter("ghost_visibility", VISIBILITY)
		out = dup
	elif src is BaseMaterial3D:
		var b := src as BaseMaterial3D
		var sm := ShaderMaterial.new()
		sm.shader = _GhostStippleShader
		sm.set_shader_parameter("albedo", b.albedo_color)
		if b.albedo_texture != null:
			sm.set_shader_parameter("albedo_texture", b.albedo_texture)
		sm.set_shader_parameter("metallic", b.metallic)
		sm.set_shader_parameter("roughness", b.roughness)
		if b.clearcoat_enabled:
			sm.set_shader_parameter("clearcoat", b.clearcoat)
			sm.set_shader_parameter("clearcoat_roughness", b.clearcoat_roughness)
		if b.emission_enabled:
			sm.set_shader_parameter("emission_color", b.emission)
			sm.set_shader_parameter("emission_energy", b.emission_energy_multiplier)
		sm.set_shader_parameter("ghost_stipple", 1.0)
		sm.set_shader_parameter("stipple_cell_px", CELL_PX)
		sm.set_shader_parameter("ghost_visibility", VISIBILITY)
		out = sm
	_variants[src] = out
	return out

## 测试核对用：材质是否为抖纹生效的幽灵变体
static func is_stippled(m: Material) -> bool:
	if not (m is ShaderMaterial):
		return false
	var gate: Variant = (m as ShaderMaterial).get_shader_parameter("ghost_stipple")
	return gate is float and gate > 0.5
