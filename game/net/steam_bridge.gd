class_name SteamNetBridge
extends RefCounted
## Steam 桥接（LobbySession 契约实现）：包装 GodotSteam 单例（v4.21 API）。
## 全部动态调用（steam.call / 信号名字符串 connect），扩展未加载时本文件仍可编译。
## API/信号签名核对自 godotsteam-docs classes/{main,matchmaking,friends,user}.md：
##   steamInitEx(app_id, embed_callbacks) → {status(0=OK), verbal}
##   lobby_created(connect, lobby)          lobby==0 即失败
##   lobby_joined(lobby_id, permissions, locked, response)  response 1=成功
##   lobby_data_update(success, lobby_id, member_id)
##   lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state)
##   lobby_invite(inviter, lobby, game) / join_requested(lobby, steam_id)
##   persona_state_change(steam_id, flags)

signal lobby_created(lobby_id: int)
signal lobby_join_result(lobby_id: int, ok: bool, response: int)
signal lobby_updated
signal member_list_changed(changed_id: int, change: int)
signal persona_changed(id: int)
signal join_requested(lobby_id: int, friend_id: int)
signal invite_received(lobby_id: int, friend_id: int)

const LOBBY_TYPE_PUBLIC := 2                # k_ELobbyTypePublic
const CHAT_ROOM_ENTER_RESPONSE_SUCCESS := 1 # k_EChatRoomEnterResponseSuccess
const STATE_ENTERED := 0x1                  # k_EChatMemberStateChangeEntered
const STATE_LEFT := 0x2                     # k_EChatMemberStateChangeLeft
const RESULT_OK := 1                        # k_EResultOK（lobby_created connect 参数）

var available := true
var my_id := 0
var steam: Object

var lobby_id := 0

func _init(p_steam: Object) -> void:
	steam = p_steam
	my_id = int(steam.call("getSteamID"))
	steam.connect("lobby_created", _on_lobby_created)
	steam.connect("lobby_joined", _on_lobby_joined)
	steam.connect("lobby_data_update", _on_lobby_data_update)
	steam.connect("lobby_chat_update", _on_lobby_chat_update)
	steam.connect("lobby_invite", _on_lobby_invite)
	steam.connect("join_requested", _on_join_requested)
	steam.connect("persona_state_change", _on_persona_change)

# ---------------- 回调泵送 ----------------

## embed_callbacks 实测在 GDExtension 下不生效：须每帧手动泵送，
## 否则 lobby_created 等信号永不回调（已实测：泵送后 0.2s 回包）
func pump() -> void:
	steam.call("run_callbacks")

# ---------------- 房间操作 ----------------

func create_lobby(max_members: int) -> void:
	steam.call("createLobby", LOBBY_TYPE_PUBLIC, max_members)

func join_lobby(id: int) -> void:
	steam.call("joinLobby", id)

func leave_lobby(id: int) -> void:
	if id == 0:
		return  # 未入会（离线路径的清理调用）
	steam.call("leaveLobby", id)
	if lobby_id == id:
		lobby_id = 0
	steam.call("setRichPresence", "connect", "")

func set_lobby_data(key: String, value: String) -> bool:
	if lobby_id == 0:
		return false
	return bool(steam.call("setLobbyData", lobby_id, key, value))

func get_lobby_data(key: String) -> String:
	if lobby_id == 0:
		return ""
	return String(steam.call("getLobbyData", lobby_id, key))

func set_member_data(key: String, value: String) -> bool:
	if lobby_id == 0:
		return false
	return bool(steam.call("setLobbyMemberData", lobby_id, key, value))

func get_member_data(member_id: int, key: String) -> String:
	if lobby_id == 0:
		return ""
	return String(steam.call("getLobbyMemberData", lobby_id, member_id, key))

## 成员 id 列表（按加入顺序）：Steam 按 index 遍历
func members() -> Array:
	var out := []
	if lobby_id == 0:
		return out
	var n := int(steam.call("getNumLobbyMembers", lobby_id))
	for i in n:
		out.append(int(steam.call("getLobbyMemberByIndex", lobby_id, i)))
	return out

func owner_id() -> int:
	if lobby_id == 0:
		return 0
	return int(steam.call("getLobbyOwner", lobby_id))

func persona_name(id: int) -> String:
	if id == my_id:
		return String(steam.call("getPersonaName"))
	return String(steam.call("getFriendPersonaName", id))

## connect 键 = 好友列表显示"加入游戏"（值 = 大厅 id）
func set_rich_presence(key: String, value: String) -> void:
	steam.call("setRichPresence", key, value)

## 打开 Steam 覆盖层好友列表（点击好友 → 邀请/加入）
func invite_overlay() -> void:
	steam.call("activateGameOverlay", "friends")

# ---------------- Steam 信号 → 契约信号 ----------------

func _on_lobby_created(_connect: int, lobby: int) -> void:
	if lobby == 0:
		lobby_join_result.emit(0, false, _connect)
		return
	lobby_id = lobby
	lobby_created.emit(lobby)

func _on_lobby_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		lobby_join_result.emit(id, false, response)
		return
	lobby_id = id
	lobby_join_result.emit(id, true, response)

func _on_lobby_data_update(_success: bool, id: int, _member_id: int) -> void:
	if id == lobby_id:
		lobby_updated.emit()

func _on_lobby_chat_update(id: int, changed_id: int, _maker: int, chat_state: int) -> void:
	if id != lobby_id:
		return
	var change := STATE_ENTERED if (chat_state & STATE_ENTERED) != 0 else STATE_LEFT
	member_list_changed.emit(changed_id, change)

func _on_lobby_invite(inviter: int, lobby: int, _game: int) -> void:
	invite_received.emit(lobby, inviter)

func _on_join_requested(lobby: int, steam_id: int) -> void:
	join_requested.emit(lobby, steam_id)

func _on_persona_change(id: int, _flags: int) -> void:
	persona_changed.emit(id)
