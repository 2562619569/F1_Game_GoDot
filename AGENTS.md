# AGENTS.md — ModRacer 项目工作约定

Godot 4.7 赛车整局循环项目（game/ 为游戏层，config/ 配表，tools/ 网页编辑器，docs/ 设计文档）。
新车美术接入走 `.agents/skills/adapt-car` skill；赛道编辑器、配表链路各有专门文档（docs/）。

## 测试流程（按改动范围分级，小改动走轻量级省时间）

**选择原则**：改完任何 `.gd` 默认先跑 L0（秒级）；能定位到改动模块就加跑 L1 对应项；
只有核心算法/整局流程改动或提交前才跑 L2 全量。截图类必须窗口模式（headless 无像素）。

```bash
GODOT="C:/Tools/Godot/Godot.exe"   # 4.7.1 stable，唯一可用引擎路径（E 盘旧路径已失效）
```

通用约定：
- 所有校验脚本以退出码 0/1 报结果，输出带 `[XXX]` 前缀的 PASS/FAIL 行；
- **新增 `.gd` 或 `class_name` 后**，先在同命令上加 `--import` 参数跑一次重建类缓存，
  否则 script_check 会误报 "Identifier not declared"（已实测踩过）；
- `-s` 型脚本（extends SceneTree，不加载 autoload）与场景型（.tscn）命令格式不同，勿混用。

### L0 轻量级 — 任何 game/ 或 config/ 下的 .gd 改动后必跑（秒级）

```bash
# 全工程 77 个脚本强制编译，解析/类型错误立即暴露，比冒烟快一个数量级
"$GODOT" --headless --path . res://game/testing/script_check.tscn
```

### L1 定向校验 — 按改动模块选跑（秒级 ~ 1 分钟）

| 改动范围 | 运行 | 耗时 |
| --- | --- | --- |
| vehicle.gd 自动换挡 | `-s game/testing/shift_logic_check.gd` 和 `-s game/testing/shift_rev_check.gd` | 秒级 |
| 轮胎物理模型 | `-s game/testing/tire_model_check.gd` | 秒级 |
| 车车碰撞 collision_kick | `-s game/testing/bump_check.gd` | 秒级 |
| 追逐相机 smooth_chase_camera | `-s game/testing/camera_check.gd` | ~16s |
| 引擎声 engine_audio_vns | `-s game/testing/engine_audio_check.gd` | 秒级 |
| 车辆美术装配/碰撞体重建 | `-s game/testing/collision_check.gd`、`-s game/testing/wheel_assembly_check.gd`；新车走 adapt-car skill | ~10s |
| R 倒转（rewind/幽灵） | `--path . res://game/testing/rewind_check.tscn` | ~1 分钟 |
| 发车网格/结算落库 | `--path . res://game/testing/grid_check.tscn` | 秒级 |
| 玩家车准备期轰油门/GO 弹射 | `--path . res://game/testing/launch_check.tscn` | ~15s |
| 掉落抽取（Loot 表语义） | `--path . res://game/testing/loot_roll_check.tscn` | 秒级 |
| 天气词缀 weather_env | `--headless --path . -s res://game/testing/env_check.gd` | 秒级 |
| 展厅 showroom | `--path . res://game/testing/showroom_check.tscn` 和 `showroom_flow_check.tscn` | 秒级 |
| HUD 排名动效 | `--path . res://game/testing/standings_anim_check.tscn` | ~2s |
| 赛道构建/地图 JSON | `--path . res://game/testing/track_build_test.tscn` 和 `-s res://game/testing/track_zfight_check.gd`（同 env_check 加 `--path .`） | 十几秒 |
| main.gd 流程/车库过渡 | `--path . res://game/testing/garage_transition_check.tscn` | 1-2 分钟 |
| 整局循环/配表联动 | `--path . res://game/testing/smoke_test.tscn`（48 断言，time_scale=3） | 分钟级 |

注：表中 `-s` 型完整命令为 `"$GODOT" --headless -s <路径>`（可不在项目目录跑）；
场景型为 `"$GODOT" --headless --path . <res:// 路径>`（须在项目根目录）。
发车出生几何排查用 `spawn_diag.tscn`（只打印不断言）。

### L2 全量回归 — 核心物理/赛道算法/流程改动或提交前

```bash
"$GODOT" --headless --path . res://game/testing/script_check.tscn        # L0
# -s 快速组：tire_model / bump / camera / engine_audio / shift_logic / shift_rev /
#           collision / wheel_assembly
# 场景组：track_build_test / track_zfight / grid_check / loot_roll_check /
#         env_check / standings_anim / showroom_check / showroom_flow_check
# 重头（按序）：rewind_check → garage_transition_check → smoke_test
node tools/track_editor/test_editor.mjs    # 仅当改过 tools/track_editor
```

历史基线（全绿时的项数，见 git 52531d5 / fcbf617）：
editor 27 / track_build 29 / grid 26 / rewind 56 / smoke 48。

### 截图目检类 — 必须窗口模式（headless 截图为空）

```bash
"$GODOT" --path . res://game/testing/track_junction_shot.tscn   # 岔口/发卡弯俯拍
"$GODOT" --path . res://game/testing/visual_capture.tscn        # UI 全流程 8 张截图
"$GODOT" --path . res://game/testing/car_visual_check.tscn      # 车辆装配+刹车灯
```

### 工具链（非测试，各有重跑时机）

| 时机 | 命令 |
| --- | --- |
| 改 ui_style.gd / 字体后 | `"$GODOT" --headless --script res://game/ui/theme/build_theme.gd` 重导 modracer_theme.tres |
| 改配表或导表脚本后 | `"$GODOT" --headless --path . res://config/verify/verify_config.tscn`，核对 verify_result.txt 末行 `VERIFY_OK` |
| 赛道烘焙算法升级后 | `node tools/track_editor/bake_sample.mjs <map.json>...` 重烘焙全部地图 |
| 展台布景改动后 | `"$GODOT" --headless --path . game/testing/car_stage_bake.tscn`（**会覆盖写 car_stage.tscn**） |

## 其他约定

- 提交信息用中文，写清改动点与验证结果（如 "rewind_check 56 项全绿，smoke 48/48"）；
- docs/配表工作流.md、docs/美术资源与车辆结构.md 是对应链路的详细规范，动配置/车辆前先读。
