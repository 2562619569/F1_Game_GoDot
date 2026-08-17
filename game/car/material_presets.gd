class_name MaterialPresets
extends RefCounted
## 引擎侧预设材质球：按 body.json 的 material_presets 把车壳 GLB 中同名材质替换为引擎效果材质。
##   paint         车漆     — StandardMaterial3D 官方物理清漆，移植 three.js 官方示例
##                     webgl_materials_car 的车漆配方（MIT）：metalness 1.0 + roughness 0.5 +
##                     clearcoat 1.0 + clearcoatRoughness 0.03；金属漆亮片用 ORM 纹理
##                     （G 通道粗糙度噪声，官方材质特性，无自定义 shader）
##   piano_black   钢琴烤漆 — 车身黑色部件用：近黑基底层 + 近镜面清漆（同一官方清漆管线），
##                     高反差镜面黑
##   headlight_lens 大灯罩  — shaders/glass.gdshader（PBR Glass, CC0）：透明 + 菲涅尔边缘
##   glass         车玻璃  — 同上；按定义完全不透明（alpha 参数已废弃，强制 1）
## 编辑器暴露的参数：颜色 + 透明度（车漆/钢琴烤漆另有清漆）。车漆 glancing 掠射色随旧版自定义
## 着色器退役：three.js 配方为纯色金属清漆，该参数已不消费（编辑器仍可写，向后兼容）。
## GLB 实例间共享材质资源，替换用的材质按原材质一一复制绑定，多车互不影响。

const _GlassShader := preload("res://game/car/shaders/glass.gdshader")

## 金属亮片 ORM 纹理（全车共享；同步生成，无异步兜底问题）：
## R=1 无AO、G=粗糙度噪声 0.5..1（配 scalar 0.5 → 亮片处粗糙度最低降到 0.25）、B=1 全金属
static var _flake_orm: ImageTexture

static func _get_flake_orm() -> ImageTexture:
	if _flake_orm == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
		noise.frequency = 0.9   # 细粒噪声：配 uv1_scale=60 呈金属漆颗粒感
		var src := noise.get_image(256, 256)
		var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
		for y in 256:
			for x in 256:
				var v := clampf(src.get_pixel(x, y).r, 0.0, 1.0)
				img.set_pixel(x, y, Color(1.0, lerpf(0.5, 1.0, v), 1.0))
		_flake_orm = ImageTexture.create_from_image(img)
	return _flake_orm

## 各预设的参数默认值（编辑器生成 entry 时同构，保证两端一致）
const DEFAULT_PARAMS := {
	"paint": {"color": "#c23a2f", "glancing": "#2a0d0b", "clearcoat": 1.0},
	"piano_black": {"color": "#0a0a0c", "clearcoat": 1.0},
	"headlight_lens": {"color": "#ffffff", "alpha": 0.1},
	"glass": {"color": "#05060a"},
}

static func apply(body_visual: Node, presets: Dictionary) -> void:
	if presets.is_empty():
		return
	for key in presets:
		var entry: Variant = presets.get(key)
		if not (entry is Dictionary):
			continue
		# 绑定键二选一：material 按 GLB 材质名（可用逗号分隔多个），
		# node 按节点名（整块网格没分材质/材质未命名时用，如直接建模的风窗玻璃）。
		# 编辑器保存会把未设置项写成 null，非字符串一律按未绑定处理（str(null)="<null>"）
		var mat_raw: Variant = entry.get("material")
		var node_raw: Variant = entry.get("node")
		var mat_name := str(mat_raw) if mat_raw is String else ""
		var node_name := str(node_raw) if node_raw is String else ""
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

static func _build(key: String, entry: Dictionary) -> Material:
	var params: Dictionary = entry.get("params", {})
	var base: Color = Color.from_string(str(params.get("color", "")), Color.WHITE)
	match key:
		"paint":
			# three.js 官方 webgl_materials_car 车漆配方移植（MIT）：
			# MeshPhysicalMaterial{ color, metalness 1.0, roughness 0.5,
			#                       clearcoat 1.0, clearcoatRoughness 0.03 }
			# → Godot StandardMaterial3D 内置清漆（同一套分层物理 BRDF）。
			# 亮片：ORM 噪声粗糙度调制（官方特性）；三.js 示例另依赖 HDR 环境反射出质感。
			# https://github.com/mrdoob/three.js/blob/dev/examples/webgl_materials_car.html
			var m := StandardMaterial3D.new()
			m.resource_name = "car_paint"
			m.albedo_color = base
			m.metallic = 1.0
			m.roughness = 0.5
			m.orm_texture = _get_flake_orm()
			m.uv1_scale = Vector3(60.0, 60.0, 1.0)
			m.clearcoat_enabled = true
			m.clearcoat = clampf(float(params.get("clearcoat", 1.0)), 0.0, 1.0)
			m.clearcoat_roughness = 0.03
			return m
		"piano_black":
			# 钢琴烤漆（车身黑色部件）：近黑漆基底层 + 近镜面清漆，与车漆同一官方清漆管线，
			# 无金属无亮片——靠高反差镜面反射出「黑镜」质感（亮环境里尤其出效果）
			var pb := StandardMaterial3D.new()
			pb.resource_name = "piano_black"
			pb.albedo_color = base
			pb.metallic = 0.0
			pb.roughness = 0.4
			pb.clearcoat_enabled = true
			pb.clearcoat = clampf(float(params.get("clearcoat", 1.0)), 0.0, 1.0)
			pb.clearcoat_roughness = 0.02
			return pb
		"headlight_lens", "glass":
			# 车玻璃按定义完全不透明：alpha 参数已废弃强制 1；大灯罩保留可调透明度
			var alpha := 1.0 if key == "glass" else clampf(float(params.get("alpha", 0.1)), 0.0, 1.0)
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

## 在 body_visual 子树内按材质名找到所有表面并替换为 mat（同名共享一个实例，大小写不敏感精确→子串）。
## 替换用 surface_override_material 按实例覆盖：不动 GLB 导入的共享网格资源，
## 材质名保留在原材质上——多车装配各绑各的（不同车漆参数互不干扰），也不产生重复绑定告警
static func _bind_materials(body_visual: Node, wanted: String, mat: Material) -> int:
	var wanted_lower := wanted.to_lower()
	var bound := 0
	for mi in body_visual.find_children("*", "MeshInstance3D"):
		var mesh_mi := mi as MeshInstance3D
		var mesh := mesh_mi.mesh as ArrayMesh
		if not mesh:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i)
			if src == null:
				continue
			var name_lower := str(src.resource_name).to_lower()
			if name_lower != wanted_lower and not name_lower.contains(wanted_lower):
				continue
			mesh_mi.set_surface_override_material(i, mat)
			bound += 1
		var ov: Material = mesh_mi.material_override
		if ov and str(ov.resource_name).to_lower().contains(wanted_lower):
			mesh_mi.material_override = mat
			bound += 1
	return bound

## 在 body_visual 子树内按节点名找到网格并把全部表面替换为 mat
## （大小写不敏感精确→子串，与材质名匹配同规则；节点没分材质也能绑）
static func _bind_nodes(body_visual: Node, wanted: String, mat: Material) -> int:
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
			mesh_mi.set_surface_override_material(i, mat)
			bound += 1
	return bound
