shader_type spatial;

// 幽灵抖纹材质：回溯/跌落保护期整车统一使用（全车一个材质一种颜色 = 整体透明
// 观感：镂空像素透出的是背景与同色内层，不显车漆/轮件/玻璃的杂色叠层）。
// 「间隔像素透明」：屏幕空间棋盘格丢弃一半像素，其余保持不透明
// （不做 alpha 混合，无半透明的排序与发糊问题）。

group_uniforms color;
uniform vec4 ghost_color : source_color = vec4(0.66, 0.85, 1.0, 1.0);
uniform float emission_energy : hint_range(0.0, 4.0) = 0.4;
uniform float metallic : hint_range(0.0, 1.0) = 0.1;
uniform float roughness : hint_range(0.0, 1.0) = 0.45;

group_uniforms stipple;
// >0.5 启用棋盘 discard；测试按此参数识别幽灵材质
uniform float ghost_stipple : hint_range(0.0, 1.0) = 1.0;
// 棋盘格边长（屏幕像素）：2px 在高分辨率下仍清晰可辨，1px 远看退化为灰
uniform float stipple_cell_px = 2.0;

void fragment() {
	if (ghost_stipple > 0.5 && mod(floor(FRAGCOORD.x / stipple_cell_px) + floor(FRAGCOORD.y / stipple_cell_px), 2.0) < 0.5) {
		discard;
	}
	ALBEDO = ghost_color.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = ghost_color.rgb * emission_energy;
}
