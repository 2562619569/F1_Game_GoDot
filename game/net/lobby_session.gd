class_name LobbySession
extends RefCounted
## 房间会话状态机（创建/加入/入座同步/房主迁移/开始广播），传输层无关：
## 通过 bridge 契约与外界通信，可挂 Steam 桥接（联机）或离线桥接（单机行为），
## 测试用 FakeTransport 回环即可 headless 验证全流程。
##
## bridge 契约（SteamNetBridge / OfflineNetBridge / 测试假件均须实现）：
##   属性：available: bool、my_id: int
##   方法：create_lobby(max) / join_lobby(id) / leave_lobby(id)
##         set_lobby_data(k,v)->bool / get_lobby_data(k)->String
##         set_member_data(k,v)->bool / get_member_data(id,k)->String
##         members()->Array[int]（按加入顺序）/ owner_id()->int
##         persona_name(id)->String / set_rich_presence(k,v) / invite_overlay()
##   信号：lobby_created(lobby_id)
##         lobby_join_result(lobby_id, ok, response)
##         lobby_updated()                 # 大厅/成员数据或房主变化（全量重读）
##         member_list_changed(id, change) # 1 进 2 退 3 掉线（触发全量重读）
##         persona_changed(id)             # 昵称信息到位（触发全量重读）
##
## 大厅数据协议（房主可写、全员可读、后加入者可回放）：
##   game   = "ModRacer"     房间标记（好友列表/未来服务器列表过滤）
##   ai_count = N            AI 入座数（房主权威）
##   state  = room|starting|started   房间阶段（starting = 广播开始）

signal joined(as_host: bool)
signal left_room()
signal seats_changed()
signal host_changed(new_host_id: int)
signal start_requested
signal net_error(text: String)

const MAX_SEATS := 8
const GAME_TAG := "ModRacer"
const KEY_GAME := "game"
const KEY_AI := "ai_count"
const KEY_STATE := "state"
const STATE_ROOM := "room"
const STATE_STARTING := "starting"
const STATE_STARTED := "started"

var transport
var offline_name := "YOU"

var active := false
var lobby_id := 0
var host_id := 0
var _online := false
var _last_state := ""
var _start_emitted := false
var _online_ai := 4

func _init(p_transport, p_offline_name := "YOU") -> void:
	transport = p_transport
	offline_name = p_offline_name
	_online = bool(transport.available)
	transport.lobby_created.connect(_on_lobby_created)
	transport.lobby_join_result.connect(_on_join_result)
	transport.lobby_updated.connect(_sync)
	transport.member_list_changed.connect(func(_id: int, _c: int): _sync())
	transport.persona_changed.connect(func(_id: int): _sync())

func online() -> bool:
	return _online

func my_id() -> int:
	return int(transport.my_id)

func is_host() -> bool:
	return active and host_id != 0 and host_id == my_id()

func my_name() -> String:
	if not _online:
		return offline_name
	var n := String(transport.persona_name(my_id()))
	return n if n != "" else offline_name

## 房内人类玩家（按加入顺序）：[{id, name, is_host, is_me}]
func players() -> Array:
	var out := []
	if not active:
		return out
	var ids: Array = transport.members()
	for i in ids.size():
		var id := int(ids[i])
		var n := String(transport.persona_name(id))
		if n == "" and id == my_id():
			n = offline_name
		out.append({"id": id, "name": n, "is_host": id == host_id, "is_me": id == my_id()})
	return out

## 当前 AI 入座数：离线取 Match.ai_count（保持单机原行为），在线读房主写的大厅数据
func ai_count() -> int:
	return Match.ai_count if not _online else _online_ai

## 房间界面座位行（人类 → AI → OPEN 补满 MAX_SEATS）：
##   {kind: human|ai|open, name, host, me}   离线 AI 沿用 AI_DEFS 名单保持原观感
func seat_rows() -> Array:
	var rows := []
	for p in players():
		rows.append({"kind": "human", "name": p.name, "host": p.is_host, "me": p.is_me})
	if _online:
		for i in ai_count():
			rows.append({"kind": "ai", "name": "AI-%d" % (i + 1)})
	else:
		for d in Match.active_ai_defs():
			rows.append({"kind": "ai", "name": String(d.name)})
	while rows.size() < MAX_SEATS:
		rows.append({"kind": "open", "name": ""})
	return rows

# ---------------- 房间生命周期 ----------------

## 创建房间：异步，结果经 lobby_created / lobby_join_result 回来后 joined 发出
func create_room() -> void:
	if active:
		return
	transport.create_lobby(MAX_SEATS)

func join_room(id: int) -> bool:
	if active:
		return false
	if not _online:
		net_error.emit("offline mode: cannot join remote lobby")
		return false
	transport.join_lobby(id)
	return true

func leave_room() -> void:
	if not active:
		return
	active = false
	# 两类桥接都要通知（离线桥接借此复位内部状态）
	transport.leave_lobby(lobby_id)
	lobby_id = 0
	host_id = 0
	_last_state = ""
	_start_emitted = false
	_online_ai = 4
	left_room.emit()

# ---------------- 房间操作 ----------------

## 打开 Steam 好友覆盖层（邀请/加入入口；离线空操作）
func invite_friends() -> void:
	if _online and active:
		transport.invite_overlay()

## 加 AI 座（房主权威）：在线写大厅数据广播；离线直写 Match（原单机行为）
func add_ai() -> void:
	if not active:
		return
	if _online:
		if not is_host():
			net_error.emit("only the host can add AI")
			return
		_online_ai = clampi(_online_ai + 1, 0, MAX_SEATS - players().size())
		transport.set_lobby_data(KEY_AI, str(_online_ai))
	else:
		Match.ai_count = clampi(Match.ai_count + 1, 0, AI_SEATS_MAX)
		seats_changed.emit()

const AI_SEATS_MAX := MAX_SEATS - 1  # 至少留玩家一个人类座

## 开始比赛（房主）：在线写 state=starting，各端收到后发 start_requested；
## 离线直接发。每波 starting 只广播一次，离开该波次后守卫重置（允许下一波）
func start_round() -> void:
	if not active:
		return
	if _online:
		if not is_host():
			net_error.emit("only the host can start")
			return
		transport.set_lobby_data(KEY_STATE, STATE_STARTING)
	else:
		_last_state = STATE_STARTING
		_emit_start_if_needed()

## 比赛真正开跑后由房主标记：后加入者不再触发开始广播，只在房间等待
func mark_started() -> void:
	if _online and active and is_host():
		transport.set_lobby_data(KEY_STATE, STATE_STARTED)

func _emit_start_if_needed() -> void:
	if _last_state != STATE_STARTING:
		_start_emitted = false  # 不在 starting 波次：重置守卫，下一波可再广播
		return
	if not _start_emitted:
		_start_emitted = true
		start_requested.emit()

# ---------------- bridge 事件 ----------------

func _on_lobby_created(id: int) -> void:
	# 房主引导房间数据（加入回调 lobby_entered 前后皆可，数据对后加入者可回放）
	if _online:
		transport.set_lobby_data(KEY_GAME, GAME_TAG)
		transport.set_lobby_data(KEY_AI, str(_online_ai))
		transport.set_lobby_data(KEY_STATE, STATE_ROOM)
		transport.set_rich_presence("connect", str(id))

func _on_join_result(id: int, ok: bool, response: int) -> void:
	if not ok:
		net_error.emit("join lobby failed (response=%d)" % response)
		return
	active = true
	lobby_id = id
	host_id = transport.owner_id()
	_start_emitted = false
	if _online:
		transport.set_rich_presence("connect", str(id))
		# 加入时房主数据可能已写：回放状态（房主中途开始，后加入者直接跟上）
		_online_ai = _read_ai_data()
		_last_state = String(transport.get_lobby_data(KEY_STATE))
	joined.emit(is_host())
	_emit_start_if_needed()
	seats_changed.emit()

func _read_ai_data() -> int:
	var s := String(transport.get_lobby_data(KEY_AI))
	return clampi(int(s), 0, MAX_SEATS) if s.is_valid_int() else 4

## 全量重读并对齐本地状态（bridge 任一变更信号触发）：
## 漏事件/乱序都能收敛，代价只是幂等重绘
func _sync() -> void:
	if not active or not _online:
		return
	var new_host := int(transport.owner_id())
	var host_swapped := new_host != host_id and host_id != 0
	host_id = new_host
	_online_ai = _read_ai_data()
	_last_state = String(transport.get_lobby_data(KEY_STATE))
	_emit_start_if_needed()
	if host_swapped:
		host_changed.emit(host_id)
	seats_changed.emit()
