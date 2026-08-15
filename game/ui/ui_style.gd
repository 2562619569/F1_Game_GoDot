class_name UIStyle
extends RefCounted
## 统一 UI 风格助手：所有界面共用，后期可整体替换为 Theme 资源。
## 极简 Lowpoly 风：深色底 + 青色强调 + 稀有度色。

const BG := Color("0e131b")
const BG_PANEL := Color("182130")
const BG_CARD := Color("212d40")
const BG_HOVER := Color("2a3a52")
const ACCENT := Color("39c5cf")
const ACCENT_WARM := Color("ffb03a")
const TEXT := Color("e8edf4")
const TEXT_DIM := Color("8fa0b5")
const DANGER := Color("ff5a6e")
const GOOD := Color("58d68d")

static func panel_box(bg := BG_PANEL, radius := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.border_width_bottom = 2
	s.border_width_top = 2
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_color = bg.lightened(0.08)
	return s

static func style_button(b: Button, primary := false) -> void:
	var normal := panel_box(ACCENT if primary else BG_CARD)
	var hover := panel_box((ACCENT if primary else BG_CARD).lightened(0.12))
	var pressed := panel_box((ACCENT if primary else BG_CARD).darkened(0.15))
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color("08131a") if primary else TEXT)
	b.add_theme_color_override("font_hover_color", Color("08131a") if primary else TEXT)
	b.add_theme_color_override("font_pressed_color", Color("08131a") if primary else TEXT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM * 0.6)
	b.add_theme_font_size_override("font_size", 18)

static func label(l: Label, size := 16, color := TEXT) -> void:
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_font_size_override("font_size", size)

static func title(l: Label, size := 30, color := ACCENT) -> void:
	label(l, size, color)

static func dim(l: Label, size := 13) -> void:
	label(l, size, TEXT_DIM)

static func wrap(p: PanelContainer) -> void:
	p.add_theme_stylebox_override("panel", panel_box())

static func margin_sep(m: MarginContainer) -> void:
	m.add_theme_constant_override("margin_left", 16)
	m.add_theme_constant_override("margin_right", 16)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 12)

## 稀有度色块标签（背包/奖励列表用）
static func rarity_chip(rarity: int) -> Color:
	return Match.RARITY_COLORS[clampi(rarity, 1, 4)]
