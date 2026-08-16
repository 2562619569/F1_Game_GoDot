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

## 金属闪烁噪声（voronoi，全车共享；异步生成，就绪前 hint_default_white 兜底）
static var _flake_tex: NoiseTexture2D

static func _get_flake_texture() -> NoiseTexture2D:
	if _flake_tex == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
		noise.frequency = 0.9   # 细粒噪声：配原版 flake_scale=150 呈金属漆颗粒感
		_flake_tex = NoiseTexture2D.new()
		_flake_tex.width = 256
		_flake_tex.height = 256
		_flake_tex.noise = noise
	return _flake_tex

## 各预设的参数默认值（编辑器生成 entry 时同构，保证两端一致）
const DEFAULT_PARAMS := {
	"paint": {"color": "#c23a2f", "glancing": "#2a0d0b", "clearcoat": 1.0},
	"headlight_lens": {"color": "#ffffff", "alpha": 0.1},
	"glass": {"color": "#05060a", "alpha": 1.0},
}

static func apply(body_visual: Node, presets: Dictionary) -> void:
	if presets.is_empty():
		return
	for key in presets:
		var entry: Variant = presets.get(key)
		if not (entry is Dictionary):
			continue
		# 绑定键二选一：material 按 GLB 材质名（可用逗号分隔多个），
		# node 按节点名（整块网格没分材质/材质未命名时用，如直接建模的风窗玻璃）
		var mat_name := str(entry.get("material", ""))
		var node_name := str(entry.get("node", ""))
		if mat_name.is_empty() and node_name.is_empty():
			continue
		var sm := _build(str(key), entry)
		if sm == null:
			continue
		var bound := 0
		if not mat_name.is_empty():
			for m in mat_name.split(","):
				bound += _bind_materials(body_visual, m.strip_edges(), sm)
		if not node_name.is_empty():
			for n in node_name.split(","):
				bound += _bind_nodes(body_visual, n.strip_edges(), sm)
		if bound == 0:
			push_warning("MaterialPresets: 车壳中未找到预设 %s 的材质「%s」/节点「%s」，跳过" % [
				key, mat_name, node_name])

static func _build(key: String, entry: Dictionary) -> ShaderMaterial:
	var params: Dictionary = entry.get("params", {})
	var base: Color = Color.from_string(str(params.get("color", "")), Color.WHITE)
	match key:
		"paint":
			# 原版双色：facing 正视主色 + glancing 掠射色
			var glancing := Color.from_string(str(params.get("glancing", "")), base.darkened(0.65))
			var sm := ShaderMaterial.new()
			sm.shader = _PaintShader
			sm.set_shader_parameter("facing_color", Vector3(base.r, base.g, base.b))
			sm.set_shader_parameter("glancing_color", Vector3(glancing.r, glancing.g, glancing.b))
			sm.set_shader_parameter("flake_texture", _get_flake_texture())
			sm.set_shader_parameter("clearcoat_amount", clampf(float(params.get("clearcoat", 1.0)), 0.0, 1.0))
			return sm
		"headlight_lens", "glass":
			var alpha := clampf(float(params.get("alpha", 0.1 if key == "headlight_lens" else 1.0)), 0.0, 1.0)
			var sm2 := ShaderMaterial.new()
			sm2.shader = _GlassShader
			sm2.set_shader_parameter("albedo", Color(base.r, base.g, base.b, alpha))
			if key == "headlight_lens":
				# 透明塑料：低透明度残留 + 略高于玻璃的粗糙度；
				# 边缘反光色跟随基色提亮（深色基色呈烟熏灯罩，浅色近白反光），
				# 不再硬编码亮蓝白——那是灯罩灰蒙蒙的来源
				sm2.set_shader_parameter("roughness", 0.1)
				var lens_edge := base.lightened(0.5)
				sm2.set_shader_parameter("edge_color", Color(lens_edge.r, lens_edge.g, lens_edge.b, 0.85))
			else:
				# 黑玻璃：近黑主体 + 略亮的边缘反射
				sm2.set_shader_parameter("roughness", 0.08)
				var edge := base.lightened(0.18)
				sm2.set_shader_parameter("edge_color", Color(edge.r, edge.g, edge.b, 1.0))
			return sm2
	return null

## 在 body_visual 子树内按材质名找到所有表面并替换为 shader_mat（同名共享一个实例，大小写不敏感精确→子串）。
## 替换用 surface_override_material 按实例覆盖：不动 GLB 导入的共享网格资源，
## 材质名保留在原材质上——多车装配各绑各的（不同车漆参数互不干扰），也不产生重复绑定告警
static func _bind_materials(body_visual: Node, wanted: String, shader_mat: ShaderMaterial) -> int:
	var wanted_lower := wanted.to_lower()
	var bound := 0
	for mi in body_visual.find_children("*", "MeshInstance3D"):
		var mesh_mi := mi as MeshInstance3D
		var mesh := mesh_mi.mesh as ArrayMesh
		if not mesh:
			continue
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat == null:
				continue
			var name_lower := str(mat.resource_name).to_lower()
			if name_lower != wanted_lower and not name_lower.contains(wanted_lower):
				continue
			mesh_mi.set_surface_override_material(i, shader_mat)
			bound += 1
		var ov: Material = mesh_mi.material_override
		if ov and str(ov.resource_name).to_lower().contains(wanted_lower):
			mesh_mi.material_override = shader_mat
			bound += 1
	return bound

## 在 body_visual 子树内按节点名找到网格并把全部表面替换为 shader_mat
## （大小写不敏感精确→子串，与材质名匹配同规则；节点没分材质也能绑）
static func _bind_nodes(body_visual: Node, wanted: String, shader_mat: ShaderMaterial) -> int:
	var wanted_lower := wanted.to_lower()
	var bound := 0
	for mi in body_visual.find_children("*", "MeshInstance3D"):
		var name_lower := str(mi.name).to_lower()
		if name_lower != wanted_lower and not name_lower.contains(wanted_lower):
			continue
		var mesh_mi := mi as MeshInstance3D
		var mesh := mesh_mi.mesh as ArrayMesh
		if not mesh:
			continue
		for i in mesh.get_surface_count():
			mesh_mi.set_surface_override_material(i, shader_mat)
			bound += 1
	return bound
