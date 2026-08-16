extends SceneTree
## 轮毂/轮胎拆分装配自检（godot --headless -s 运行，不依赖 autoload）：
## 1. aero_v1 轮毂 + offroad_v1 轮胎 → 每轮位应各有 1 个 HubVisual/TireVisual，
##    胎半径经 front/rear_tire_radius 由 initialize() 下发到各物理轮；
## 2. 不存在的轮毂/轮胎 id → 两侧占位回退，内嵌占位轮保持可见。

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

	var v2: Vehicle = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	var ok2: bool = CarMeshBuilder.attach_visual(v2, 601, {"wheel": "ghost", "tire": "ghost"})
	root.add_child(v2)
	var ph: Node3D = v2.get_node("WheelFrontLeft/FrontLeftWheel/wheel_frontLeft")
	var pass2 := ok2 and ph.visible
	print("[WHEELCHECK] missing_fallback attach=%s placeholder_visible=%s -> %s" % [
		ok2, ph.visible, "PASS" if pass2 else "FAIL"])
	quit(0 if pass1 and pass2 else 1)
