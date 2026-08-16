extends SceneTree
## 轮毂/轮胎/刹车盘拆分装配自检（godot --headless -s 运行，不依赖 autoload）：
## 1. aero_v1 轮毂 + offroad_v1 轮胎 → 每轮位应各有 1 个 HubVisual/TireVisual，
##    胎半径经 front/rear_tire_radius 由 initialize() 下发到各物理轮；
## 2. 默认外观（sport_v1 真轮毂 + stock_v1 真胎 + 前/后刹车盘）→ 每轮位另有
##    1 个 BrakeVisual，挂在物理轮射线下的 BrakePivot（不随轮自转），
##    左侧轮位外观件绕 Y 翻转 180°，真实胎半径 0.341 下发物理轮；
## 3. 不存在的轮毂/轮胎/刹车盘 id → 全缺回退，内嵌占位轮保持可见。

func _init() -> void:
	var v: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	var ok: bool = CarMeshBuilder.attach_visual(v, 601, {"wheel": "aero_v1", "tire": "offroad_v1"})
	root.add_child(v)   # 入树触发 _ready → initialize() 下发轮径
	var hubs := v.find_children("HubVisual", "Node3D", true, false).size()
	var tires := v.find_children("TireVisual", "Node3D", true, false).size()
	var fl := v.get_node("WheelFrontLeft") as Wheel
	var pass1 := ok and hubs == 4 and tires == 4 and is_equal_approx(fl.tire_radius, 0.3)
	print("[WHEELCHECK] split_assembly attach=%s hub_visual=%d tire_visual=%d wheel_radius=%.2f -> %s" % [
		ok, hubs, tires, fl.tire_radius, "PASS" if pass1 else "FAIL"])

	var v1: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	var ok1: bool = CarMeshBuilder.attach_visual(v1, 601)
	root.add_child(v1)
	var discs := v1.find_children("BrakeVisual", "Node3D", true, false).size()
	var fl_disc := v1.get_node_or_null("WheelFrontLeft/BrakePivot/BrakeVisual")
	var rr_disc := v1.get_node_or_null("WheelRearRight/BrakePivot/BrakeVisual")
	var fl_hub := v1.get_node("WheelFrontLeft/FrontLeftWheel/HubVisual") as Node3D
	var fr_hub := v1.get_node("WheelFrontRight/FrontRightWheel/HubVisual") as Node3D
	var fl1 := v1.get_node("WheelFrontLeft") as Wheel
	var ph1: Node3D = v1.get_node("WheelFrontLeft/FrontLeftWheel/wheel_frontLeft")
	# 刹车盘挂点已接线（随悬挂/转向不随自转）；左侧翻转 PI、右侧不翻；
	# 半径断言到 vehicle 导出变量为止（wheel 级下发要 CarBuilder.apply 设好
	# 表面参数后 initialize() 才执行，-s 模式无 autoload 不走那条链）；
	# 齐边轮位 x = ±(body_width 0.94 − 实测胎宽 0.2976/2)；
	# 真实轮件挂上后内嵌占位轮必须隐藏（否则灰色圆柱罩住真实轮毂）；
	# 轮件固定材质已替换：轮毂磨砂黑金属 / 胎橡胶 / 盘亮面金属，卡钳保留 GLB 材质
	var mats_ok := _check_wheel_materials(v1)
	var pass2 := ok1 and discs == 4 and fl_disc != null and rr_disc != null \
			and fl1.static_visual != null and fl1.static_visual.name == "BrakePivot" \
			and is_equal_approx(fl_hub.rotation.y, PI) and is_zero_approx(fr_hub.rotation.y) \
		and is_equal_approx(v1.front_tire_radius, 0.341) \
		and is_equal_approx(fl1.position.x, -(0.94 - 0.2976 * 0.5)) \
		and not ph1.visible and mats_ok
	print("[WHEELCHECK] brakes_default attach=%s brake_visual=%d pivot_wired=%s left_flip=%.1f right_flip=%.1f veh_radius=%.3f wheel_x=%.4f placeholder_hidden=%s mats_ok=%s -> %s" % [
		ok1, discs, fl1.static_visual != null, fl_hub.rotation.y, fr_hub.rotation.y,
		v1.front_tire_radius, fl1.position.x, not ph1.visible, mats_ok, "PASS" if pass2 else "FAIL"])

	var v2: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	var ok2: bool = CarMeshBuilder.attach_visual(v2, 601,
			{"wheel": "ghost", "tire": "ghost", "brake_front": "ghost", "brake_rear": "ghost"})
	root.add_child(v2)
	var ph: Node3D = v2.get_node("WheelFrontLeft/FrontLeftWheel/wheel_frontLeft")
	var pass3 := ok2 and ph.visible
	print("[WHEELCHECK] missing_fallback attach=%s placeholder_visible=%s -> %s" % [
		ok2, ph.visible, "PASS" if pass3 else "FAIL"])
	quit(0 if pass1 and pass2 and pass3 else 1)

## 轮件固定材质断言：轮毂 override 磨砂黑金属、胎 override 橡胶、
## 盘表面 override 亮面金属且卡钳表面（kaqian 材质名）保留 GLB 原样
func _check_wheel_materials(v: Vehicle) -> bool:
	var fl_wheel := v.get_node("WheelFrontLeft/FrontLeftWheel")
	var hub_mi := (fl_wheel.get_node("HubVisual").find_children("*", "MeshInstance3D")[0]) as MeshInstance3D
	var tire_mi := (fl_wheel.get_node("TireVisual").find_children("*", "MeshInstance3D")[0]) as MeshInstance3D
	var hub_mat := hub_mi.material_override as StandardMaterial3D
	var tire_mat := tire_mi.material_override as StandardMaterial3D
	if hub_mat == null or tire_mat == null:
		return false
	if not is_equal_approx(hub_mat.metallic, 1.0) or not is_equal_approx(hub_mat.roughness, 0.65):
		return false
	if not is_zero_approx(tire_mat.metallic) or not is_equal_approx(tire_mat.roughness, 0.9):
		return false
	var disc_mi := (v.get_node("WheelFrontLeft/BrakePivot/BrakeVisual")
			.find_children("*", "MeshInstance3D")[0]) as MeshInstance3D
	var disc_ok := false
	var caliper_kept := false
	for i in disc_mi.mesh.get_surface_count():
		var ov: Material = disc_mi.get_surface_override_material(i)
		var src: Material = disc_mi.mesh.surface_get_material(i)
		if ov is StandardMaterial3D and is_equal_approx((ov as StandardMaterial3D).metallic, 1.0) \
				and is_equal_approx((ov as StandardMaterial3D).roughness, 0.15):
			disc_ok = true   # 盘面已换亮面金属
		if ov == null and src != null and "kaqian" in str(src.resource_name).to_lower():
			caliper_kept = true   # 卡钳未动
	return disc_ok and caliper_kept
