class_name MaterialPresets
extends RefCounted
## 引擎侧预设材质球：按 body.json 的 material_presets 把车壳 GLB 中同名材质替换为社区效果材质。
##   paint         车漆     — shaders/car_paint.gdshader（Automotive Paint, CC0）：fresnel 混色 + 金属闪烁 + 清漆
##   headlight_lens 大灯罩  — shaders/glass.gdshader（PBR Glass, CC0）：透明 + 菲涅尔边缘
##   glass         车玻璃  — 同上，默认近黑不透明
## 编辑器暴露的参数：颜色 + 透明度（车漆另有 金属闪烁/清漆）。
## GLB 实例间共享材质资源，替换用的 ShaderMaterial 按原材质一一复制绑定，多车互不影响。

const _PaintShader := preload("res://game/car/shaders/car_paint.gdshader")
const _GlassShader := preload("res://game/car/shaders/glass.gdshader")

## 各预设的参数默认值（编辑器生成 entry 时同构，保证两端一致）
const DEFAULT_PARAMS := {
	"paint": {"color": "#c23a2f", "flake_amount": 0.5, "clearcoat": 1.0},
	"headlight_lens": {"color": "#ffffff", "alpha": 0.35},
	"glass": {"color": "#05060a", "alpha": 1.0},
}

static func apply(body_visual: Node, presets: Dictionary) -> void:
	if presets.is_empty():
		return
	for key in presets:
		var entry: Variant = presets.get(key)
		if not (entry is Dictionary):
			continue
		var mat_name := str(entry.get("material", ""))
		if mat_name.is_empty():
			continue
		var sm := _build(str(key), entry)
		if sm == null:
			continue
		var bound := _bind_materials(body_visual, mat_name, sm)
		if bound == 0:
			push_warning("MaterialPresets: 车壳中未找到预设 %s 的材质「%s」，跳过" % [key, mat_name])

static func _build(key: String, entry: Dictionary) -> ShaderMaterial:
	var params: Dictionary = entry.get("params", {})
	var base: Color = Color.from_string(str(params.get("color", "")), Color.WHITE)
	match key:
		"paint":
			var glancing := base.darkened(0.65)
			var sm := ShaderMaterial.new()
			sm.shader = _PaintShader
			sm.set_shader_parameter("facing_color", Vector3(base.r, base.g, base.b))
			sm.set_shader_parameter("glancing_color", Vector3(glancing.r, glancing.g, glancing.b))
			sm.set_shader_parameter("flake_amount", clampf(float(params.get("flake_amount", 0.5)), 0.0, 1.0))
			sm.set_shader_parameter("clearcoat_amount", clampf(float(params.get("clearcoat", 1.0)), 0.0, 1.0))
			return sm
		"headlight_lens", "glass":
			var alpha := clampf(float(params.get("alpha", 1.0 if key == "glass" else 0.35)), 0.0, 1.0)
			var sm2 := ShaderMaterial.new()
			sm2.shader = _GlassShader
			sm2.set_shader_parameter("albedo", Color(base.r, base.g, base.b, alpha))
			if key == "headlight_lens":
				sm2.set_shader_parameter("roughness", 0.06)
				sm2.set_shader_parameter("edge_color", Color(0.9, 0.95, 1.0, 0.9))
			else:
				# 黑玻璃：近黑主体 + 略亮的边缘反射
				sm2.set_shader_parameter("roughness", 0.08)
				var edge := base.lightened(0.18)
				sm2.set_shader_parameter("edge_color", Color(edge.r, edge.g, edge.b, 1.0))
			return sm2
	return null

## 在 body_visual 子树内按材质名找到所有表面并替换为 shader_mat（同名共享一个实例，大小写不敏感精确→子串）
static func _bind_materials(body_visual: Node, wanted: String, shader_mat: ShaderMaterial) -> int:
	var wanted_lower := wanted.to_lower()
	var bound := 0
	for mi in body_visual.find_children("*", "MeshInstance3D"):
		var mesh := mi.mesh as ArrayMesh
		if not mesh:
			continue
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat == null:
				continue
			var name_lower := str(mat.resource_name).to_lower()
			if name_lower != wanted_lower and not name_lower.contains(wanted_lower):
				continue
			mesh.surface_set_material(i, shader_mat)
			bound += 1
		var ov: Material = mi.material_override
		if ov and str(ov.resource_name).to_lower().contains(wanted_lower):
			mi.material_override = shader_mat
			bound += 1
	return bound
