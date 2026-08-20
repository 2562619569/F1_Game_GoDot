extends Node
## 联机总装（Autoload: Net）。
## 职责：Steam 可用性检测 → 装配 LobbySession（Steam 桥接或离线兜底）；
## 转发好友"加入请求"（界面策略归 main.gd）。
##
## 桥接选择规则：
##   环境变量 MODRACER_NET=offline / force_steam 可强制（双进程联机诊断用）；
##   默认 headless（CI/回归测试）一律离线——测试绝不能真建 Spacewar 大厅；
##   有窗口时自动：扩展已加载 + Steam 客户端在跑 → steamInitEx(480, true)。
## 未初始化/未装扩展/未登录的环境自动退化为原单机行为（OfflineNetBridge）。

signal join_requested(lobby_id: int, friend_id: int)  # 好友接受邀请或好友列表"加入游戏"
signal invite_received(lobby_id: int, friend_id: int) # 收到邀请（接受动作在 Steam 覆盖层）

const APP_ID := 480  # Spacewar：Steamworks 官方测试 AppID，上架后换正式 AppID

var session: LobbySession
var steam_ready := false
var steam_persona := ""
var init_note := ""   # 离线原因（诊断用："Steam client not running" 等）
var _steam_bridge: SteamNetBridge

func _ready() -> void:
	var bridge := _make_bridge()
	session = LobbySession.new(bridge, player_name())
	if bridge is SteamNetBridge:
		_steam_bridge = bridge
		bridge.join_requested.connect(
			func(id: int, from: int): join_requested.emit(id, from))
		bridge.invite_received.connect(
			func(id: int, from: int): invite_received.emit(id, from))
	print("[NET] mode=%s steam_ready=%s note=%s" % [
		"steam" if steam_ready else "offline", steam_ready, init_note])

## Steam 回调靠每帧泵送驱动（embed_callbacks 实测无效，见 SteamNetBridge.pump）
func _process(_delta: float) -> void:
	if _steam_bridge != null:
		_steam_bridge.pump()

func player_name() -> String:
	return steam_persona if steam_persona != "" else Match.PLAYER_NAME

## 当前是否具备联机能力（UI 据此决定邀请按钮等显隐）
func online() -> bool:
	return steam_ready and session != null and session.online()

func _make_bridge() -> RefCounted:
	var forced := OS.get_environment("MODRACER_NET")
	if forced == "offline":
		init_note = "forced offline (MODRACER_NET)"
		return OfflineNetBridge.new()
	var want_steam := forced == "force_steam" or DisplayServer.get_name() != "headless"
	if not want_steam:
		init_note = "headless run"
		return OfflineNetBridge.new()
	if not ClassDB.class_exists("Steam"):
		init_note = "Steam extension not loaded"
		return OfflineNetBridge.new()
	var s = Engine.get_singleton("Steam")
	if not bool(s.call("isSteamRunning")):
		init_note = "Steam client not running"
		return OfflineNetBridge.new()
	# steamInitEx 传 app_id 自动设环境（steam_appid.txt 可省）；embed_callbacks=true
	# 由扩展内部泵回调。初始化失败（如未登录）返回非 0 status，安全降级。
	var res: Dictionary = s.call("steamInitEx", APP_ID, true)
	if int(res.get("status", -1)) != 0:
		init_note = "steamInitEx: " + String(res.get("verbal", "failed"))
		return OfflineNetBridge.new()
	steam_ready = true
	steam_persona = String(s.call("getPersonaName"))
	return SteamNetBridge.new(s)
