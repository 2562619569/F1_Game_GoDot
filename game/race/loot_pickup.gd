extends Area3D
## 赛道掉落物：按稀有度着色旋转浮动，玩家车（player_car 组）触碰即拾取。
## 战术武器类掉落用不同形状区分。

signal collected(part_id: int)

var part_id := 101
var route := "main"
var _mesh: MeshInstance3D
var _light: OmniLight3D
var _t := 0.0

func setup(pid: int, r: String) -> void:
	part_id = pid
	route = r
	var p := Match.part_cfg(pid)
	var color: Color = Match.RARITY_COLORS[clampi(int(p.rarity), 1, 4)]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.2
	_mesh = $Mesh
	if p.category == "tactical":  # 战术件：八面没有，用拉长盒子示意弹药箱
		_mesh.scale = Vector3(1.2, 0.6, 1.2)
	_mesh.material_override = mat
	_light = $Glow
	_light.light_color = color
	_light.omni_range = 3.0 + int(p.rarity)

func _ready() -> void:
	($Shape.shape as SphereShape3D).radius = Match.game_cfg("loot_pick_radius")
	body_entered.connect(_on_body)
	monitoring = true

func _on_body(body: Node3D) -> void:
	if not body.is_in_group("player_car"):
		return
	collected.emit(part_id)
	queue_free()

func _process(delta: float) -> void:
	_t += delta
	_mesh.rotate_y(delta * 2.2)
	_mesh.position.y = 0.8 + sin(_t * 2.0) * 0.15
