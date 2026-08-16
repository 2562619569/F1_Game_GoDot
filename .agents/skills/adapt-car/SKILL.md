---
name: adapt-car
description: 适配/接入车辆美术资产时使用。触发场景：新车 body.glb 接入、组合零件包拆分落位、车壳材质绑定（车漆/大灯罩/玻璃/刹车灯/高位刹车灯）对不上名、灯不亮、占位轮未隐藏、灯罩灰蒙蒙、多车材质串色、适配后验证与提交。覆盖 GLB 解剖、body.json 编写、配表默认轮毂、headless 验证全流程。
---

# 车辆美术资产适配指南

新车壳 GLB（`art/cars/<id>/body.glb`）或轮件组合包交付后，按本流程把资产接进装配系统。
完整规范见 `docs/美术资源与车辆结构.md`；本 skill 是操作手册 + 踩坑记录。

**关键前提：`art/` 整目录在 .gitignore 里不入库**——body.json 等适配配置换机即丢。
适配完成后：代码/文档改动提交 git；`art/` 下的绑定关系在总结中明确列出（换机按本 skill 重做）。

## 流程

### 1. 轮件组合包拆分（仅整包交付时）

美术交付「轮毂/轮胎/刹车盘组合 GLB」时先拆分落位（源包每个部件一个根节点，
脚本按节点枢纽重锚原点并覆盖 `art/` 占位资产）：

```bash
python tools/art_editor/split_parts_glb.py <源.glb> --analyze   # 先看分析
python tools/art_editor/split_parts_glb.py <源.glb>             # 拆分落位
```

节点名映射：轮毂1→sport_v1、轮毂2→classic_v1、轮毂3→aero_v1、轮胎1→stock_v1、
前刹车→front_v1、后刹车→rear_v1（改映射编辑脚本顶部 HUB_MAP 等）。
车壳 body.glb 是独立文件直接放 `art/cars/<id>/`，不走拆分。

轮件材质无需适配：运行时 `game/car/wheel_materials.gd` 统一替换为引擎固定材质
（磨砂黑轮毂/橡胶胎/亮面金属刹车盘）；**卡钳按材质名 kaqian/卡钳/caliper 保留 GLB 原样**，
新资产保持这个命名约定。

### 2. 解剖车壳 GLB

列出节点、材质、每个 mesh 表面用哪个材质——适配就是把这些名写进 body.json：

```bash
python -c "
import json, sys
sys.path.insert(0, 'tools/art_editor')
from split_parts_glb import read_glb
g, b = read_glb('art/cars/<id>/body.glb')
print('nodes:', [(i, n.get('name')) for i, n in enumerate(g.get('nodes', []))])
for i, m in enumerate(g.get('materials', [])):
    print('mat[%d]' % i, m.get('name'), m.get('pbrMetallicRoughness', {}).get('baseColorFactor'))
for mi, m in enumerate(g.get('meshes', [])):
    print('mesh[%d] prims->mat:' % mi, [p.get('material') for p in m['primitives']])
"
```

找这些角色的材质：车身漆（BODY 类节点大网格）、前灯反光碗、刹车灯/高位刹车灯
（红色 baseColor）、前/后灯罩（带 alpha 的透明材质）、车玻璃（可能**整块没材质**）。

### 3. 写 body.json

`art/cars/<id>/body.json` 两块语义（对照 `art/cars/601`、`602` 实例）：

**materials（语义标记）**：
- `headlight` / `body`：仅元数据（后续车灯/车漆逻辑消费），名字对上即可
- `brake_light`：刹车灯，**逗号分隔多个材质名**（尾灯 + 高位刹车灯各一个，如 602 的
  `"材质.009, 材质.010"`）；运行时复制材质、常亮红光 0.4、刹车升至 3.0

**material_presets（引擎效果替换）**，槽位 paint / headlight_lens / glass，每条绑定键二选一：

| 键 | 匹配方式 | 用途 |
| --- | --- | --- |
| `material` | GLB 材质名，精确→子串（大小写不敏感），可逗号分隔多个 | 常规：材质已命名 |
| `node` | 节点名（同匹配规则），绑该网格全部表面 | 整块网格无材质/未命名（如 602 风窗「车玻璃」） |

推荐参数：paint 用美术 baseColor 取色 + 深色 glancing；headlight_lens
`color #141414, alpha 0.1`（透明塑料感）；glass `color #05060a, alpha 1`。

物理字段 `body_width / front_axle / rear_axle` 用 art_editor 网页编辑器标定
（`python tools/art_editor/server.py` → localhost:8138）。

### 4. 配表默认轮毂（可选）

各车默认轮毂在 Car 配表 `wheel` 列（`config/data/ModRacer.xlsx`，改后同步
`config/dist/ModRacer/car.gd`）。运行时优先级：玩家已选外观件 > Car.wheel >
CarMeshBuilder.DEFAULT_HUB（sport_v1）。

### 5. headless 验证

先跑装配探针（存成临时脚本用完即删），检查绑定与告警：

```gdscript
extends SceneTree
func _init() -> void:
	var v: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	CarMeshBuilder.attach_visual(v, <id>)
	root.add_child(v)
	for mi in v.get_node("BodyPivot/BodyVisual").find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null: continue
		for i in m.get_surface_count():
			var src: Material = m.surface_get_material(i)
			var ov: Material = (mi as MeshInstance3D).get_surface_override_material(i)
			var base := "<无材质>" if src == null else str(src.resource_name)
			if ov != null:
				print("%s surf%d [%s] -> %s" % [mi.name, i, base, ov.get_class()])
	var bl: Node = v.get_node_or_null("BodyPivot/BodyVisual/BrakeLight")
	print("brake_light:", bl.debug_info() if bl else "缺失")
	quit(0)
```

```bash
C:/Tools/Godot/Godot.exe --headless -s <探针.gd>
```

再跑既有自检（`game/testing/`）：

```bash
C:/Tools/Godot/Godot.exe --headless -s game/testing/wheel_assembly_check.gd
C:/Tools/Godot/Godot.exe --headless res://game/testing/car_visual_check.tscn   # 场景型，不能 -s
```

**通过标准**：无 CarMeshBuilder / BrakeLight / MaterialPresets 告警；paint/lens/glass
各表面有 override；brake_light materials 数量与预期一致（含高位刹车灯）；
wheel_assembly_check 三项 PASS。

### 6. 提交

代码与文档改动正常提交。`art/` 下改动（body.json 绑定、拆分落位的 glb）不入库，
在提交信息/总结里写明「art/ 本地适配：……」留痕。

## 踩坑记录（都真踩过）

1. **名字匹配是「精确→子串」**：写「车灯罩」会同时命中「后车灯罩」（可一次绑一族灯罩，
   是特性）；但 `材质.00x` 系列互相近似，**绝不能用子串**，用逗号逐个精确列出。
2. **改共享网格必串色**：GLB 导入的 ArrayMesh 被所有车实例共享，按车改材质必须
   `surface_override_material` / `material_override`，直改 `mesh.surface_set_material`
   会让所有车的刹车灯跟着最后装配那辆走（brake_light.gd、material_presets.gd 均已改对，
   新代码照抄这个模式）。
3. **占位轮隐藏条件**：任一真实轮件挂上即隐藏内嵌占位轮，全缺才保留（car_mesh_builder
   有断言，改装配逻辑后必跑 wheel_assembly_check）。
4. **灯罩灰蒙蒙** = alpha 过高（旧默认 0.35）+ 边缘色不随基色；现体系 alpha 0.1 +
   边缘跟随基色提亮，别回退。
5. **风窗等无材质网格渲染成白块**：用 material_presets 的 `node` 键绑。
6. 交付 GLB 材质可能带怪值（KHR specularColorFactor 2.0 等）——被 preset/固定材质
   override 替换的表面无影响，未替换表面留意。
7. 场景型测试脚本（依赖 Match 等 autoload）必须按场景跑，`-s` 会编译报错。
