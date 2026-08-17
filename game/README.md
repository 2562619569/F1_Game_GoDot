# game/ — ModRacer 游戏层

依据《[ModRacer 核心策划案 GDD](../docs/game-design/ModRacer-核心策划案-GDD初稿.md)》实现的整局循环：

```
大厅 Lobby ──创建房间──▶ 邀请界面 Room ──PLAY──▶ 开局选车 CarSelect
     ▲                                              │
     │                                        回合1..4（Race）
     │                                              │
返回大厅 ◀── 终局结算 FinalResult ◀──┐   局间整备 Intermission
   (新的一局)                        └──(非决赛)──改装+雷达图+下回合情报
```

## 目录结构（按"方便后期替换"分层）

```
game/
├── main.tscn / main.gd        # 流程状态机（UI 层 CanvasLayer + 比赛层 World）
├── autoload/match.gd          # Match：整局状态（选车/背包/装配/回合/名次）。
│                              #   数据中枢，界面只做展示 —— 换 UI 不用动它
├── car/
│   ├── car_builder.gd         # 配表 → GEVP Vehicle 物理参数的唯一映射入口。
│   │                          #   Car 表基础参数 + 改件加成 + 天气修正。
│   │                          #   换物理插件/调改装手感只改这里
│   ├── player_car.gd          # 玩家输入 + 战术技能（火箭/隐身/氮气，表驱动）
│   ├── ai_racer.gd            # AI 对手（车道保持 + 强度系数）
│   └── engine_audio_vns.gd    # 引擎声合成（VNS 移植）：加速/减速双采样库按 RPM
│                              #   分层恒功率交叉淡化 + 换挡回火/收油回火/红线断油
│                              #   事件音效。采样资产与参数见 assets/audio/engine/
├── race/
│   ├── race_manager.gd        # 单回合总控：赛道/天气/掉落/发车位/排名/结算
│   ├── weather_env.gd         # 天气词缀：环境表现 + 表面摩擦修正 + 配装建议
│   ├── loot_pickup.tscn/.gd   # 掉落物（稀有度配色，玩家触碰拾取）
│   └── tracks/track_test.tscn/.gd
│                              # 基础测试赛道：A→B 主路 + 高危分支(飞坡)。
│                              #   换正式地图：实现 finish_z / main_route_points /
│                              #   hazard_route_points / setup(weather) 四个接口
├── ui/                        # 每个界面独立文件夹（tscn 可直接换皮）
│   ├── ui_style.gd            # 统一样式（可整体替换为 Theme 资源）
│   ├── lobby/                 # 大厅：CREATE ROOM
│   ├── room/                  # 邀请界面：房间码 + 玩家位 + PLAY
│   ├── car_select/            # 开局选车：Car 表渲染 3 款底盘卡片
│   ├── garage/                # 局间整备：结算/奖励/装配台/背包/雷达图/情报
│   │   └── radar_chart.gd     # 四维雷达图（改装前灰 vs 改装后青）
│   ├── hud/                   # 竞速 HUD：排名/倒计时/速度/战术弹药/提示
│   └── result/                # 终局结算：冠军 + 各回合名次总表
└── testing/
    ├── smoke_test.tscn/.gd    # 全循环冒烟测试（29 项断言，见下）
    └── debug_drive.tscn/.gd   # 单车驾驶最小调试场景
```

## 数据流（全配表驱动，无硬编码数值）

- **底盘物理**：`Settings.car`（Car-car 表，字段与 `addons/gevp/scripts/vehicle.gd`
  导出变量一一对应）→ `CarBuilder.apply()`
- **改件**：`Settings.part`（效果/稀有度/属性/弹药CD）→ `Match.get_stats()` 合成
  → `CarBuilder` 调制扭矩/转速/风阻/摩擦/悬挂
- **赛制**：`Settings.round`（4 回合、决赛）+ `Settings.game`（倒计时/局间时长/
  锁定距离/拾取半径）+ `Settings.rank_reward`（前排奖励 + 倒序发车位）
- **掉落**：`Settings.loot`（主路/高危分支 权重与保底）
- **地图**：`Settings.map`（名称/介绍/天气词缀 → 天气影响摩擦与配装建议）

## 战术技能（Part 表 effect 字段）

| effect | 键位 | 效果 |
| --- | --- | --- |
| `nitro_push` | Q | 按功率×车重持续推力 |
| `stealth` | Q | 半透明 + 免火箭锁定 |
| `slow_spin` | Q | 锁定前方 `lock_ahead_range` 内最近车，减速打转 |

## 操作

- 驾驶：W/S 油门刹车、A/D 转向、Space 手刹（GEVP 原生输入映射）
- 战术件：Q（首个功能槽）
- F10：调试立即完赛（测试用）

## 测试

```bash
# 全循环冒烟测试（大厅→房间→play→4回合→改装生效→冠军→回大厅，29 断言）
"E:/godot/godot-4.7.1/Godot_v4.7.1-stable_win64.exe" --headless --path . \
    res://game/testing/smoke_test.tscn

# 引擎声 VNS 移植自检（分层交叉淡化/滞回/事件音效，-s 模式不依赖 autoload）
"C:/Tools/Godot/Godot.exe" --headless -s game/testing/engine_audio_check.gd

# 升挡转速下坠自检（换挡窗口内 motor_rpm 收敛到新挡匹配转速）
"C:/Tools/Godot/Godot.exe" --headless -s game/testing/shift_rev_check.gd

# 碰撞体检（美术装配后碰撞体重建为贴地底盘低盒 + 撞墙不穿不翻 + 接地防翻回正）
"C:/Tools/Godot/Godot.exe" --headless -s game/testing/collision_check.gd

# 首次添加新脚本后需重建类缓存：
# 同上命令加 --import 参数先跑一次
```

冒烟测试中 `Match.auto_test = true` 让玩家车自动驾驶，
`Match.intermission_sec_override` 缩短局间等待；两者仅供测试外壳使用。
