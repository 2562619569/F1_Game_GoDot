class_name OfflineNetBridge
extends RefCounted
## 离线桥接（LobbySession 契约实现）：Steam 不可用时的兜底——
## 扩展缺失 / Steam 客户端未运行 / headless 测试环境。
## 行为保持原单机房间：创建即入座（虚拟大厅 id=0）、无法加入、数据落本地字典。

signal lobby_created(lobby_id: int)
signal lobby_join_result(lobby_id: int, ok: bool, response: int)
signal lobby_updated
signal member_list_changed(changed_id: int, change: int)
signal persona_changed(id: int)
signal join_requested(lobby_id: int, friend_id: int)
signal invite_received(lobby_id: int, friend_id: int)

const LOCAL_ID := 1001  # 本地玩家虚拟 Steam id

var available := false
var my_id := LOCAL_ID

var _in_room := false
var _data := {}

func create_lobby(_max_members: int) -> void:
	if _in_room:
		return
	_in_room = true
	_data = {}
	lobby_created.emit(0)
	lobby_join_result.emit(0, true, 0)

func join_lobby(_lobby_id: int) -> void:
	lobby_join_result.emit(0, false, -1)

func leave_lobby(_lobby_id: int) -> void:
	_in_room = false
	_data = {}

func set_lobby_data(key: String, value: String) -> bool:
	_data[key] = value
	return true

func get_lobby_data(key: String) -> String:
	return String(_data.get(key, ""))

func set_member_data(_key: String, _value: String) -> bool:
	return true

func get_member_data(_member_id: int, _key: String) -> String:
	return ""

func members() -> Array:
	return [LOCAL_ID] if _in_room else []

func owner_id() -> int:
	return LOCAL_ID if _in_room else 0

func persona_name(_id: int) -> String:
	return ""

func set_rich_presence(_key: String, _value: String) -> void:
	pass

func invite_overlay() -> void:
	pass
