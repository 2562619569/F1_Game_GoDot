extends SceneTree
## 全局主题生成器：从 UIStyle 调色板构建 modracer_theme.tres。
## 改完 ui_style.gd 后在项目根目录运行：
##   godot --headless --script res://game/ui/theme/build_theme.gd
## 生成的 .tres 是各界面引用的最终资源（也可在编辑器里继续微调）。

const THEME_PATH := "res://game/ui/theme/modracer_theme.tres"
const Palette := preload("res://game/ui/ui_style.gd")

func _initialize() -> void:
	var t := Theme.new()

	# ---- Label 基础样式（所有标签默认：正文白 + 黑色描边） ----
	t.set_color("font_color", "Label", Palette.TEXT)
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.6))
	t.set_constant("outline_size", "Label", 4)
	t.set_font_size("font_size", "Label", 16)

	# 标签角色变体：节点上设 theme_type_variation 即引用
	_variation(t, "Accent", "Label")
	t.set_color("font_color", "Accent", Palette.ACCENT)
	_variation(t, "Warm", "Label")
	t.set_color("font_color", "Warm", Palette.ACCENT_WARM)
	_variation(t, "Dim", "Label")
	t.set_color("font_color", "Dim", Palette.TEXT_DIM)
	_variation(t, "Good", "Label")
	t.set_color("font_color", "Good", Palette.GOOD)
	_variation(t, "Danger", "Label")
	t.set_color("font_color", "Danger", Palette.DANGER)

	# ---- Button 默认样式（深色卡片按钮） ----
	_button_styles(t, "Button", Palette.BG_CARD, Palette.TEXT)
	t.set_color("font_disabled_color", "Button", Palette.TEXT_DIM * 0.6)
	t.set_font_size("font_size", "Button", 18)

	# 主操作按钮变体：青色底 + 深色字
	_variation(t, "Primary", "Button")
	_button_styles(t, "Primary", Palette.ACCENT, Color("08131a"))

	# ---- PanelContainer 卡片面板 ----
	t.set_stylebox("panel", "PanelContainer", _panel_box(Palette.BG_PANEL))

	var err := ResourceSaver.save(t, THEME_PATH)
	if err != OK:
		push_error("Theme save failed: %s" % err)
		quit(1)
	else:
		print("Theme written: %s" % THEME_PATH)
		quit(0)

func _variation(t: Theme, name: String, base: String) -> void:
	t.set_type_variation(StringName(name), StringName(base))

## normal/hover/pressed/disabled 四态样式盒（圆角卡片 + 同色系描边）
func _button_styles(t: Theme, type: String, bg: Color, font: Color) -> void:
	t.set_stylebox("normal", type, _panel_box(bg))
	t.set_stylebox("hover", type, _panel_box(bg.lightened(0.12)))
	t.set_stylebox("pressed", type, _panel_box(bg.darkened(0.15)))
	t.set_stylebox("disabled", type, _panel_box(bg.darkened(0.35)))
	t.set_stylebox("focus", type, StyleBoxEmpty.new())
	t.set_color("font_color", type, font)
	t.set_color("font_hover_color", type, font)
	t.set_color("font_pressed_color", type, font)
	t.set_color("font_focus_color", type, font)

func _panel_box(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = 10
	s.corner_radius_top_right = 10
	s.corner_radius_bottom_left = 10
	s.corner_radius_bottom_right = 10
	s.border_width_bottom = 2
	s.border_width_top = 2
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_color = bg.lightened(0.08)
	return s
