extends Node
## 把 CarStage 的运行时布景烘焙成 car_stage.tscn 实际节点（编辑器所见即所得）：
## 展开当前 tscn 里已烘焙的生成节点并清空资源 → 守卫判定"缺失"而按最新代码全量重建
## → 用 _build_car 走真实装配管线装一台 601 作编辑器预览（命名 PreviewCar601，
##    运行时被 CarStage._ready 清掉让位给真车）→ 递归设 owner 后 pack 覆写回 tscn。
## 布景/灯光/预览车代码改动后重跑本场景即可重新烘焙，可重复执行：
##   godot --headless --path . game/testing/car_stage_bake.tscn

const STAGE_SCENE := preload("res://game/ui/showroom/car_stage.tscn")
const PREVIEW_ID := 601

func _ready() -> void:
	var stage: CarStage = STAGE_SCENE.instantiate()
	# 保留用户在编辑器里转过的预览车朝向，重烘焙不重置摆位
	var old_preview := stage.get_node_or_null("PreviewCar601")
	var preview_yaw: float = old_preview.rotation.y if old_preview != null else deg_to_rad(stage.default_car_yaw_deg)
	# 先拆掉旧烘焙（未进树前直接 free，避免和 _ready 里的 queue_free 撞车）
	for node_name in ["StudioLights", "ReflectionProbe", "Backdrop", "FloorDetails", "AtmosphericHaze", "PreviewCar601"]:
		var old := stage.get_node_or_null(node_name)
		if old != null:
			old.free()
	var world_env: WorldEnvironment = stage.get_node("WorldEnvironment")
	world_env.environment = null
	world_env.camera_attributes = null
	var ground: MeshInstance3D = stage.get_node("Ground")
	var old_body := ground.get_node_or_null("GroundBody")
	if old_body != null:
		old_body.free()
	ground.mesh = null
	add_child(stage)   # _ready 内守卫全开，按当前代码重建布景并对焦相机
	stage._build_car(PREVIEW_ID, deg_to_rad(stage.default_car_yaw_deg))
	stage._car.name = "PreviewCar601"
	for n in stage.find_children("*", "Node", true, false):
		n.owner = stage
	var packed := PackedScene.new()
	var err := packed.pack(stage)
	if err != OK:
		print("[BAKE] pack 失败 err=%d" % err)
		get_tree().quit(1)
		return
	err = ResourceSaver.save(packed, "res://game/ui/showroom/car_stage.tscn")
	var count := packed.get_state().get_node_count()
	print("[BAKE] %s car_stage.tscn（含 PreviewCar%d，共 %d 个节点）" % [
		"已重烘焙" if err == OK else "保存失败 err=%d" % err, PREVIEW_ID, count])
	get_tree().quit(1 if err != OK else 0)
