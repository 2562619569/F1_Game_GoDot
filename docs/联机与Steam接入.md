# 联机与 Steam 接入

Steam 好友邀请 / 创建房间 / 加入 / 房主权威的开始广播等**房间层**流程已接入；
比赛内车辆状态同步（真联机竞速）是后续工作，见文末"边界与后续"。

## 组件结构

```
game/autoload/net.gd        Autoload「Net」：Steam 可用性检测、装配 session、
                            每帧泵送回调（run_callbacks）、转发好友加入请求
game/net/lobby_session.gd   LobbySession：房间状态机（传输层无关，可 headless 测试）
game/net/steam_bridge.gd    SteamNetBridge：GodotSteam v4.21 API 包装（动态调用）
game/net/offline_bridge.gd  OfflineNetBridge：离线兜底（等价原单机房间行为）
addons/godotsteam/          GodotSteam GDExtension（4.4 ABI 构建，实测 4.7.1 官方引擎可加载）
steam_appid.txt             480（Spacewar 测试 AppID；steamInitEx 也传同值双保险）
```

三套实现遵守同一 bridge 契约（见 lobby_session.gd 文件头注释），测试用
FakeTransport 回环即可覆盖全流程，不需要 Steam 客户端。

## 桥接选择规则（net.gd）

| 环境 | 结果 |
| --- | --- |
| 环境变量 `MODRACER_NET=offline` | 强制离线 |
| 环境变量 `MODRACER_NET=force_steam` | 强制尝试 Steam（headless 双进程诊断用） |
| headless（CI/回归） | 一律离线——**测试绝不真建 Steam 大厅** |
| 有窗口 | 自动：扩展已加载 + Steam 客户端在跑 → `steamInitEx(480, true)` |

初始化失败（未装扩展/未开客户端/未登录）自动降级离线，游戏保持完整单机可玩，
`Net.init_note` 记录降级原因。

## 大厅数据协议（房主可写、全员可读、后加入可回放）

| key | 值 | 说明 |
| --- | --- | --- |
| `game` | `ModRacer` | 房间标记（好友列表/未来服务器列表过滤） |
| `ai_count` | 整数 | AI 入座数（房主权威） |
| `state` | `room` / `starting` / `started` | 房间阶段；`starting`=开始广播波次 |

- 成员表 = Steam 大厅成员（加入顺序即座位序，P1=房主）。
- `state` 每进入一次 `starting` 波次各端恰好广播一次 `start_requested`
  （LobbySession 守卫自动去重；离开波次后守卫重置，允许下一波）。
- 房主离开 → Steam 自动迁移房主给最早成员 → 各端 `host_changed`，
  新房主继承加 AI / 开始权限。
- 富临场 `connect` = 大厅 id：好友 Steam 列表出现"加入游戏"按钮。

## 界面流程

- 大厅「创建房间」→ `Net.session.create_room()`（离线=本地房间；在线=Steam 大厅）
  → 房间界面显示真实入座 + `INVITE FRIENDS`（打开 Steam 覆盖层好友列表）。
- 好友接受邀请 / 好友列表"加入游戏" → `join_requested` → main.gd 只在
  大厅/房间界面放行加入（比赛中忽略，避免破坏整局流程）。
- 房主 `PLAY` → `state=starting` → 全员 `start_requested` → 进选车；
  客户端 PLAY 置灰显示 WAIT FOR HOST；AI 数按房主大厅数据下发到各端比赛。
- 比赛开跑（main.start_round）→ 房主 `mark_started()`：后加入者不再触发
  开始广播，只在房间等待下一波。

## 已实证结论（2026-08，本机 Steam 已登录实测）

1. **GDExtension 在官方 4.7.1 加载成功**：`godotsteam-4.21-gdextension-plugin-4.4`
   （win64）注册 Steam 类正常；新增/移动 .gdextension 后需 `--import` 重建
   extension_list 缓存才会被扫描。
2. **`embed_callbacks=true` 无效，必须每帧手动泵送**：`steamInitEx` 第二参传 true
   实测不驱动回调（lobby_created 永不回）；Net autoload `_process` 里
   `steam.call("run_callbacks")` 后 0.2s 内回包。
3. **真 Steam 双进程链路**：房主创建→写数据→客户端 joinLobby→读回数据
   （game/ai_count/owner 全对）→ lobby_updated 数据变更回调可达。
   （限制：同机同账号双进程时成员表按 Steam ID 去重只计 1 人；
   好友邀请/覆盖层需两账号真机验证。）
4. `steamInitEx(app_id, embed)` 参数序：**app_id 在第一位**（旧文档两参易混）；
   传 480 自动设环境，steam_appid.txt 只是双保险。

## 测试与诊断

```bash
# headless 回归（41 断言，无需 Steam）：离线兜底 + FakeTransport 三端全流程
"$GODOT" --headless --path . res://game/testing/net_lobby_check.tscn

# 真 Steam 双进程诊断（本机已登录 Steam 时；一次性探针写 /tmp 不入库）：
#   host:   -s net_steam_host_diag.gd   # 建房写 .steam_diag_lobby
#   client: -s net_steam_client_diag.gd # 轮询文件加入、读数据、等 starting
```

## 边界与后续

- **比赛内车辆同步未实现**：当前在线房间全员按房主 AI 数各自本地开跑，
  远端真人不在场上（`Match.commit_round` 预留了联机结算替换点，
  race_builder 的 `_make_racer` 是接远端车输入的落点）。
- 只装了 win64 扩展库；macOS/Linux 导出需补 addons/godotsteam 对应平台目录。
- 正式上架后：steam_appid.txt 与 `net.gd APP_ID` 换正式 AppID；
  覆盖层好友邀请在导出包+正式 AppID 下才对好友可见。
- 好友邀请按钮 v1 打开覆盖层好友列表；"向所有在线好友发邀请"（inviteUserToGame）
  与服务器浏览器（lobby_match_list）为后续增强。
