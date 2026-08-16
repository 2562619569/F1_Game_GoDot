@tool
extends EditorPlugin
## 地图环境编辑插件：Dock 面板选地图 → 调环境参数 → 3D 预览 → 写回 map_<id>_env.json。
## 环境数据由 WeatherEnv 统一合成，编辑器预览与比赛运行时渲染一致。

var _dock: Control

func _enter_tree() -> void:
	_dock = load("res://addons/map_env_editor/map_env_dock.gd").new()
	add_control_to_dock(DOCK_SLOT_LEFT_BR, _dock)

func _exit_tree() -> void:
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()
