extends Node
## 联机房间流程 headless 校验（无 Steam 依赖）：
##   A. Net autoload 离线兜底 + OfflineBridge 房间行为（保持原单机语义）
##   B. FakeTransport 回环（模拟 Steam 大厅语义：成员列表/大厅数据/房主迁移）
##      驱动多个 LobbySession 实例，断言创建/加入/入座同步/AI 广播/
##      房主权威/开始广播/后加入回放/离开/房主迁移全链路
##   C. 房间界面接线（RoomInvite 在离线会话下可实例化渲染）
## 运行：--headless --path . res://game/testing/net_lobby_check.tscn
## 退出码 0/1，输出 [NETCHK] 前缀 PASS/FAIL。

var checks := 0
var failures := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("[NETCHK] OK   | %s" % label)
	else:
		failures += 1
		print("[NETCHK] FAIL | %s" % label)

# ================= FakeTransport 回环（模拟 Steam 后端） =================

## 模拟 Steam 大厅服务器：大厅仓库 + 事件路由（成员表/数据/房主按 Steam 语义）
class Hub:
	var lobbies := {}   # id -> {"data": {}, "members": Array[int], "owner": int}
	var peers := []     # 已注册的 FakeTransport
	var next_id := 109900

	func register(t) -> void:
		peers.append(t)

	func _others(except_id: int) -> Array:
		var out := []
		for p in peers:
			if p.my_id != except_id:
				out.append(p)
		return out

	func create(t) -> void:
		next_id += 1
		var lid := next_id
		lobbies[lid] = {"data": {}, "members": [t.my_id], "owner": t.my_id}
		t.lobby_created.emit(lid)                      # Steam: 先 lobby_created
		t.lobby_join_result.emit(lid, true, 1)         # 后 lobby_joined(自己)

	func join(t, lid: int) -> void:
		if not lobbies.has(lid):
			t.lobby_join_result.emit(lid, false, 2)    # DOESNT_EXIST
			return
		var l: Dictionary = lobbies[lid]
		l.members.append(t.my_id)
		t.lobby_join_result.emit(lid, true, 1)
		for p in _others(t.my_id):
			if p.lobby_id == lid:
				p.member_list_changed.emit(t.my_id, 1)  # ENTERED

	func set_data(from, lid: int, key: String, value: String) -> void:
		var l: Dictionary = lobbies.get(lid, {})
		if l.is_empty() or l.owner != from.my_id:
			return  # Steam：非房主写数据静默失败
		l.data[key] = value
		for p in peers:
			if p.lobby_id == lid:
				p.lobby_updated.emit()

	func leave(t, lid: int) -> void:
		var l: Dictionary = lobbies.get(lid, {})
		if l.is_empty():
			return
		l.members.erase(t.my_id)
		for p in _others(t.my_id):
			if p.lobby_id == lid:
				p.member_list_changed.emit(t.my_id, 2)  # LEFT
		if l.owner == t.my_id and not l.members.is_empty():
			l.owner = l.members[0]                       # Steam：房主迁移给最早成员
			for p in peers:
				if p.lobby_id == lid:
					p.lobby_updated.emit()

	func members(lid: int) -> Array:
		return (lobbies[lid].members as Array).duplicate() if lobbies.has(lid) else []

	func owner(lid: int) -> int:
		return int(lobbies[lid].owner) if lobbies.has(lid) else 0

	func data(lid: int, key: String) -> String:
		var l: Dictionary = lobbies.get(lid, {})
		return String(l.data.get(key, ""))

## 单端传输件：把 LobbySession 契约调用转给 Hub（同步回发，断言无需等待）
class FakeTransport:
	extends RefCounted
	signal lobby_created(lobby_id: int)
	signal lobby_join_result(lobby_id: int, ok: bool, response: int)
	signal lobby_updated
	signal member_list_changed(changed_id: int, change: int)
	signal persona_changed(id: int)
	signal join_requested(lobby_id: int, friend_id: int)
	signal invite_received(lobby_id: int, friend_id: int)

	var available := true
	var my_id: int
	var lobby_id := 0
	var hub: Hub
	var persona := ""

	func _init(p_hub: Hub, p_id: int, p_persona: String) -> void:
		hub = p_hub
		my_id = p_id
		persona = p_persona
		hub.register(self)

	func create_lobby(_max_members: int) -> void:
		hub.create(self)

	func join_lobby(id: int) -> void:
		hub.join(self, id)

	func leave_lobby(id: int) -> void:
		hub.leave(self, id)
		lobby_id = 0

	func set_lobby_data(key: String, value: String) -> bool:
		hub.set_data(self, lobby_id, key, value)
		return true

	func get_lobby_data(key: String) -> String:
		return hub.data(lobby_id, key)

	func set_member_data(_key: String, _value: String) -> bool:
		return true

	func get_member_data(_member_id: int, _key: String) -> String:
		return ""

	func members() -> Array:
		return hub.members(lobby_id)

	func owner_id() -> int:
		return hub.owner(lobby_id)

	func persona_name(id: int) -> String:
		return persona if id == my_id else _lookup(id)

	func _lookup(id: int) -> String:
		for p in hub.peers:
			if p.my_id == id:
				return p.persona
		return ""

	func set_rich_presence(_key: String, _value: String) -> void:
		pass

	func invite_overlay() -> void:
		pass

## lobby_created / join_result 是两条独立信号，transport.lobby_id 要在两条路上都登记
func _hook_transport_ids(t: FakeTransport) -> void:
	t.lobby_created.connect(func(id: int): t.lobby_id = id)
	t.lobby_join_result.connect(func(id: int, ok: bool, _r: int):
		if ok:
			t.lobby_id = id)

# ================= 测试主体 =================

func _ready() -> void:
	_run()
	get_tree().quit(1 if failures > 0 else 0)

func _run() -> void:
	print("========== NET LOBBY CHECK ==========")
	_part_a_offline()
	_part_b_loopback()
	_part_c_room_ui()
	print("[NETCHK] checks=%d failures=%d" % [checks, failures])

# ---- A. 离线兜底（headless 环境 Net 必须离线，行为等价原单机） ----
func _part_a_offline() -> void:
	ok(Net.session != null, "Net autoload session exists")
	ok(not Net.online(), "headless run is offline")
	ok(Net.session.my_name() == Match.PLAYER_NAME, "offline name is player name")

	var joined_flags := {"host": false}
	Net.session.joined.connect(func(as_host: bool): joined_flags.host = as_host, CONNECT_ONE_SHOT)
	Net.session.create_room()
	ok(joined_flags.host, "offline create -> joined(as_host)")
	ok(Net.session.active and Net.session.is_host(), "offline creator is host")

	var rows: Array = Net.session.seat_rows()
	ok(rows.size() == LobbySession.MAX_SEATS, "seat rows fill to 8 (got %d)" % rows.size())
	var ai_n := 0
	var human_n := 0
	for r in rows:
		if r.kind == "ai":
			ai_n += 1
		elif r.kind == "human":
			human_n += 1
	ok(human_n == 1, "one human seat (player)")
	ok(ai_n == 4, "default 4 AI seats (got %d)" % ai_n)
	ok(String(rows[0].name) == Match.PLAYER_NAME and rows[0].host, "P1 is local player/host")

	Net.session.add_ai()
	ok(Match.ai_count == 5, "offline add_ai writes Match.ai_count (5)")
	ok(Net.session.seat_rows()[5].kind == "ai", "6th row now AI")

	var starts := {"n": 0}
	Net.session.start_requested.connect(func(): starts.n += 1, CONNECT_ONE_SHOT)
	Net.session.start_round()
	ok(starts.n == 1, "offline start_round broadcasts start_requested once")
	Net.session.leave_room()
	ok(not Net.session.active, "leave_room deactivates")

	var errors := {"n": 0}
	Net.session.net_error.connect(func(_t: String): errors.n += 1, CONNECT_ONE_SHOT)
	ok(not Net.session.join_room(123456), "offline join rejected")
	ok(errors.n == 1, "offline join reports net_error")

# ---- B. 回环：三端全流程（房主 H + 好友 A + 后加入 B） ----
func _part_b_loopback() -> void:
	var hub := Hub.new()
	var th := FakeTransport.new(hub, 111, "HOSTMAN")
	var ta := FakeTransport.new(hub, 222, "ALPHA")
	var tb := FakeTransport.new(hub, 333, "BRAVO")
	_hook_transport_ids(th)
	_hook_transport_ids(ta)
	_hook_transport_ids(tb)
	var sh := LobbySession.new(th)
	var sa := LobbySession.new(ta)
	var sb := LobbySession.new(tb)

	# 创建
	var h_joined := {"v": false}
	sh.joined.connect(func(_h: bool): h_joined.v = true, CONNECT_ONE_SHOT)
	sh.create_room()
	ok(h_joined.v, "host joined own lobby")
	ok(sh.active and sh.is_host(), "creator is host")
	ok(th.get_lobby_data(LobbySession.KEY_GAME) == LobbySession.GAME_TAG, "lobby data game tag written")
	ok(th.get_lobby_data(LobbySession.KEY_AI) == "4", "lobby data ai_count default 4")
	ok(th.get_lobby_data(LobbySession.KEY_STATE) == LobbySession.STATE_ROOM, "lobby data state=room")

	# 好友 A 加入（模拟接受邀请后 joinLobby）
	sa.join_room(sh.lobby_id)
	ok(sa.active and not sa.is_host(), "friend joined as client")
	ok(sh.players().size() == 2, "host sees 2 members")
	var names := []
	for p in sh.players():
		names.append(p.name)
	ok(names.has("ALPHA") and names.has("HOSTMAN"), "host sees persona names: %s" % str(names))
	ok(String(sh.seat_rows()[0].name) == "HOSTMAN" and String(sh.seat_rows()[1].name) == "ALPHA",
			"seats in join order (host first)")

	# 房主加 AI → A 收到数据变更同步
	sh.add_ai()
	ok(sa.ai_count() == 5, "client synced host ai_count=5")

	# 客户端加 AI 被拒（房主权威）
	var denied := {"n": 0}
	sa.net_error.connect(func(_t: String): denied.n += 1, CONNECT_ONE_SHOT)
	sa.add_ai()
	ok(denied.n == 1 and sa.ai_count() == 5, "client add_ai denied, count unchanged")

	# 房主开始 → 全员收到 start_requested（含房主自己）
	var h_start := {"n": 0}
	var a_start := {"n": 0}
	sh.start_requested.connect(func(): h_start.n += 1, CONNECT_ONE_SHOT)
	sa.start_requested.connect(func(): a_start.n += 1, CONNECT_ONE_SHOT)
	sh.start_round()
	ok(h_start.n == 1, "host got start broadcast")
	ok(a_start.n == 1, "client got start broadcast")

	# 后加入者 B 回放 starting 状态（跟上开局）
	var b_start := {"n": 0}
	sb.start_requested.connect(func(): b_start.n += 1, CONNECT_ONE_SHOT)
	sb.join_room(sh.lobby_id)
	ok(sb.active, "late joiner entered")
	ok(b_start.n == 1, "late joiner replays start state")

	# 开跑后房主标记 started：后续状态波次守卫重置（允许下一波开始）
	sh.mark_started()
	ok(tb.get_lobby_data(LobbySession.KEY_STATE) == LobbySession.STATE_STARTED,
			"host marked state=started")

	# A 离开 → 房主成员表更新
	sa.leave_room()
	ok(sh.players().size() == 2, "host seat table after friend left (host+late)")

	# 房主离开 → 房主迁移给最早成员 B；B 能开始（第二波 starting）
	var b_host := {"n": 0}
	sb.host_changed.connect(func(_h: int): b_host.n += 1, CONNECT_ONE_SHOT)
	sh.leave_room()
	ok(not sh.active, "host left")
	ok(sb.is_host(), "ownership migrated to earliest member")
	ok(b_host.n == 1, "migrated client got host_changed")
	var b_start2 := {"n": 0}
	sb.start_requested.connect(func(): b_start2.n += 1, CONNECT_ONE_SHOT)
	sb.start_round()
	ok(b_start2.n == 1, "new host can start (second wave after started)")

	# 加入不存在的大厅 → 失败回执
	sb.leave_room()
	var sc_session := LobbySession.new(FakeTransport.new(hub, 444, "CHARLIE"))
	var fail_err := {"n": 0}
	sc_session.net_error.connect(func(_t: String): fail_err.n += 1, CONNECT_ONE_SHOT)
	sc_session.join_room(987654)
	ok(fail_err.n == 1, "join missing lobby reports error")

# ---- C. 房间界面接线（离线会话下实例化渲染无脚本错误） ----
func _part_c_room_ui() -> void:
	Net.session.create_room()
	var room := preload("res://game/ui/room/room_invite.tscn").instantiate()
	add_child(room)
	var rows: Array = room.slots_box.get_children()
	var p1_text: String = rows[0].get_node("M/Row/NameLabel").text
	ok(p1_text == Match.PLAYER_NAME, "room UI P1 renders local player (got '%s')" % p1_text)
	ok(room.room_code_label.text.length() > 8, "room code label populated: %s" % room.room_code_label.text)
	ok(room.invite_btn.visible == false, "invite button hidden offline")
	ok(not room.play_btn.disabled and room.play_btn.text == "PLAY", "offline PLAY enabled")
	room.queue_free()
	Net.session.leave_room()
