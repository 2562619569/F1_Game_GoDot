extends SceneTree
## 轮毂/轮胎/刹车盘拆分装配自检（godot --headless -s 运行，不依赖 autoload）：
## 1. aero_v1 轮毂 + offroad_v1 轮胎 → 每轮位应各有 1 个 HubVisual/TireVisual，
##    胎半径经 front/rear_tire_radius 由 initialize() 下发到各物理轮；
## 2. 默认外观（sport_v1 真轮毂 + stock_v1 真胎 + 前/后刹车盘）→ 每轮位另有
##    1 个 BrakeVisual，挂在物理轮射线下的 BrakePivot（不随轮自转），
##    左侧轮位外观件绕 Y 翻转 180°，真实胎半径 0.341 下发物理轮；
## 3. 不存在的轮毂/轮胎/刹车盘 id → 全缺回退，内嵌占位轮保持可见。
## 断言放在首帧 _process：-s 模式 _init 阶段 add_child 的 _ready（→initialize）
## 延迟到第一帧才执行，同步读会拿到未经初始化的值。

var _v: Vehicle
var _v1: Vehicle
var _v2: Vehicle
var _ok: bool
var _ok1: bool
var _ok2: bool
var _checked := false

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_ok = CarMeshBuilder.attach_visual(_v, 601, {"wheel": "aero_v1", "tire": "offroad_v1"})
	root.add_child(_v)   # 入树触发 _ready → initialize() 下发轮径
	_v1 = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_ok1 = CarMeshBuilder.attach_visual(_v1, 601)
	root.add_child(_v1)
	_v2 = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_ok2 = CarMeshBuilder.attach_visual(_v2, 601,
			{"wheel": "ghost", "tire": "ghost", "brake_front": "ghost", "brake_rear": "ghost"})
	root.add_child(_v2)

func _process(_delta: float) -> bool:
	if _checked:
		return false
	_checked = true

	var hubs := _v.find_children("HubVisual", "Node3D", true, false)
	var tires := _v.find_children("TireVisual", "Node3D", true, false)
	var fl := _v.get_node("WheelFrontLeft") as Wheel
	# aero_v1 outer=0.1327：轮位 x = ±(0.94 − 0.1327)，换轮毂轮位随盘面深浅走
	var pass1 := _ok and hubs.size() == 4 and tires.size() == 4 \
			and is_equal_approx(fl.tire_radius, 0.3) \
			and is_equal_approx(fl.position.x, -(0.94 - 0.1327))
	print("[WHEELCHECK] split_assembly attach=%s hub_visual=%d tire_visual=%d wheel_radius=%.2f wheel_x=%.4f -> %s" % [
		_ok, hubs.size(), tires.size(), fl.tire_radius, fl.position.x, "PASS" if pass1 else "FAIL"])

	var discs := _v1.find_children("BrakeVisual", "Node3D", true, false)
	var fl_disc := _v1.get_node_or_null("WheelFrontLeft/BrakePivot/BrakeVisual")
	var rr_disc := _v1.get_node_or_null("WheelRearRight/BrakePivot/BrakeVisual")
	var fl_hub := _v1.get_node("WheelFrontLeft/FrontLeftWheel/HubVisual") as Node3D
	var fr_hub := _v1.get_node("WheelFrontRight/FrontRightWheel/HubVisual") as Node3D
	var fr_tire := _v1.get_node("WheelFrontRight/FrontRightWheel/TireVisual") as Node3D
	var fl1 := _v1.get_node("WheelFrontLeft") as Wheel
	var ph1: Node3D = _v1.get_node("WheelFrontLeft/FrontLeftWheel/wheel_frontLeft")
	# 刹车盘挂点已接线（随悬挂/转向不随自转）；左侧翻转 PI、右侧不翻；
	# 轮位以轮毂为基准：x = ±(body_width 0.94 − sport_v1 outer 0.0919)，外盘面齐边；
	# 套胎：胎中线对齐轮毂桶身几何中线（mid_x=−0.041 在原点内侧，
	# 右侧 local.x = −tire.center + mid_x = −0.041，左胎因 sign_x 翻转为 +0.041）；
	# 「标定即静态位」：initialize() 把挂点 y 抬高静态下垂量（前 0.15×(1−0.5)=0.075），
	# 挂点 y = 标定 0.19 + 0.075 = 0.265，静止轮心恰落回标定值；
	# 真实轮件挂上后内嵌占位轮必须隐藏（否则灰色圆柱罩住真实轮毂）；
	# 轮件固定材质已替换：轮毂磨砂黑金属 / 胎橡胶 / 盘亮面金属，卡钳保留 GLB 材质
	var mats_ok := _check_wheel_materials(_v1)
	var pass2 := _ok1 and discs.size() == 4 and fl_disc != null and rr_disc != null \
			and fl1.static_visual != null and fl1.static_visual.name == "BrakePivot" \
			and is_equal_approx(fl_hub.rotation.y, PI) and is_zero_approx(fr_hub.rotation.y) \
			and is_zero_approx(fl_hub.position.length()) \
			and is_equal_approx(_v1.front_tire_radius, 0.341) \
			and is_equal_approx(fl1.position.x, -(0.94 - 0.0919)) \
			and is_equal_approx(fr_tire.position.x, -0.041) \
			and is_equal_approx(fl1.position.y, 0.19 + 0.15 * (1.0 - 0.5)) \
			and not ph1.visible and mats_ok
	print("[WHEELCHECK] brakes_default attach=%s brake_visual=%d pivot_wired=%s left_flip=%.1f right_flip=%.1f veh_radius=%.3f wheel_x=%.4f wheel_y=%.4f tire_mid=%.4f placeholder_hidden=%s mats_ok=%s -> %s" % [
		_ok1, discs.size(), fl1.static_visual != null, fl_hub.rotation.y, fr_hub.rotation.y,
		_v1.front_tire_radius, fl1.position.x, fl1.position.y, fr_tire.position.x, not ph1.visible, mats_ok,
		"PASS" if pass2 else "FAIL"])

	var ph: Node3D = _v2.get_node("WheelFrontLeft/FrontLeftWheel/wheel_frontLeft")
	var pass3 := _ok2 and ph.visible
	print("[WHEELCHECK] missing_fallback attach=%s placeholder_visible=%s -> %s" % [
		_ok2, ph.visible, "PASS" if pass3 else "FAIL"])
	quit(0 if pass1 and pass2 and pass3 else 1)
	return true

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
