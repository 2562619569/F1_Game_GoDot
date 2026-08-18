shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// 幽灵抖纹材质：回溯/跌落保护的「间隔像素透明」——屏幕空间 Bayer 4x4 有序
// 抖动按可见度丢弃像素，其余像素保持原色不透明（不做 alpha 混合，无半透明
// 的排序与发糊问题；颜色观感与源材质一致，只是更透）。
// 由 GhostStipple 把 BaseMaterial3D 源材质（车漆/轮件/刹车灯/横幅）映射为
// 等价参数的抖纹材质；玻璃/灯罩走 glass.gdshader 内建的同名开关。

group_uniforms base;
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;

group_uniforms clearcoat;
uniform float clearcoat : hint_range(0.0, 1.0) = 0.0;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.03;

group_uniforms emission;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 0.0;

group_uniforms stipple;
// >0.5 启用抖纹；与 glass.gdshader 联动，测试按此参数识别幽灵变体
uniform float ghost_stipple : hint_range(0.0, 1.0) = 1.0;
// 抖动格边长（屏幕像素）：2px 在高分辨率下仍清晰可辨，1px 远看退化为灰
uniform float stipple_cell_px = 2.0;
// 像素保留比例（0=全透 1=不透）：0.25 = 每 4x4 像素块留 4 个，比棋盘 50% 更透
uniform float ghost_visibility : hint_range(0.0, 1.0) = 0.25;

const float bayer4[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void fragment() {
	if (ghost_stipple > 0.5) {
		vec2 cell = floor(FRAGCOORD.xy / max(stipple_cell_px, 1.0));
		ivec2 c = ivec2(int(mod(cell.x, 4.0)), int(mod(cell.y, 4.0)));
		if (ghost_visibility <= bayer4[c.y * 4 + c.x] / 16.0) {
			discard;
		}
	}
	ALBEDO = albedo.rgb * texture(albedo_texture, UV).rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	CLEARCOAT = clearcoat;
	CLEARCOAT_ROUGHNESS = clearcoat_roughness;
	EMISSION = emission_color.rgb * emission_energy;
}
