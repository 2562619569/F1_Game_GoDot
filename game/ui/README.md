# UI 模板库

所有界面共用三层结构，新界面请按下述方式引用，不要在场景里手写颜色/样式盒。

## 三层结构

| 层 | 文件 | 作用 |
|---|---|---|
| 调色板 | `ui_style.gd` | 色值唯一来源（代码侧引用 `UIStyle.ACCENT` 等） |
| 全局主题 | `theme/modracer_theme.tres` | 按钮/面板/标签的样式盒、字号、类型变体；已在 project.godot 注册，所有 Control 自动生效 |
| 组件模板 | `components/*.tscn` | 编辑器里直接实例化的结构模板 |

主题由生成器产出（改完调色板后重新生成）：

```
godot --headless --script res://game/ui/theme/build_theme.gd
```

## 组件模板（components/）

| 模板 | 用途 |
|---|---|
| `button_primary.tscn` | 主操作按钮（青色底深色字）：CREATE ROOM / PLAY / SELECT / READY |
| `button_default.tscn` | 次要按钮（深色卡片底）：EXIT / BACK |
| `panel_card.tscn` | 卡片面板（圆角 + 描边）：玩家位、选车卡、整备三栏 |
| `backdrop.tscn` | 全屏背景色 |

场景中实例化后按需覆盖 `text` / `custom_minimum_size` / 字号即可，不要覆盖颜色和样式盒。

## 主题类型变体

标签颜色通过 `theme_type_variation` 引用（ inspectors → Theme Variations ）：

| 变体 | 颜色 | 典型用途 |
|---|---|---|
| `Accent` | 青色 | 标题、性能条 |
| `Warm` | 橙色 | 房间码、冠军、玩家高亮、Toast |
| `Dim` | 灰蓝 | 副标题、说明文字 |
| `Good` | 绿色 | 奖励、建议 |
| `Danger` | 红色 | 警示（预留） |

按钮变体：`Primary`（模板已带，一般不用手动设）。

默认值：Label 16 号白字黑描边，Button 18 号；特殊尺寸用 `theme_override_font_sizes` 覆盖。

## 代码中动态创建控件

全局主题自动生效，只需处理非默认部分：

```gdscript
var l := Label.new()
l.theme_type_variation = &"Warm"          # 角色变体
l.add_theme_font_size_override("font_size", 15)  # 非默认字号

var b := Button.new()   # 样式盒/字体自动来自主题，无需手工 stylebox
b.add_theme_color_override("font_color", Match.RARITY_COLORS[r])  # 动态色（稀有度）才覆盖
```

## 例外：动态色

稀有度色（`Match.RARITY_COLORS`）、天气提示色（`WeatherEnv.cfg().chip`）等运行时才能确定的颜色，
允许用 `add_theme_color_override` 在节点上覆盖。
