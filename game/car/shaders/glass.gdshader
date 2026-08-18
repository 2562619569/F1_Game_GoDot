shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, blend_mix;

// 玻璃/灯罩：改编自 godotshaders.com「PBR Glass」（作者 aubrey，CC0）。
// 裁剪掉法线/粗糙度贴图通道，仅保留参数化 uniform；SPECULAR 透明补偿技巧仅 Forward+ 有效（本项目即 Forward+）。
// alpha=1 时为不透明（黑色车玻璃），alpha<1 时透明并显现菲涅尔边缘（大灯罩）。

group_uniforms albedo;
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 0.0);

group_uniforms roughness;
uniform float roughness : hint_range(0.0, 1.0) = 0.1;

group_uniforms misc;
uniform vec4 edge_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

group_uniforms ghost;
// 回溯幽灵「间隔像素透明」：GhostStipple 复制本材质时置 1，按 Bayer 抖动
// 丢弃像素（默认 0 = 关，常规模具不受影响；参数与 ghost_stipple.gdshader 联动）
uniform float ghost_stipple : hint_range(0.0, 1.0) = 0.0;
uniform float stipple_cell_px = 2.0;
uniform float ghost_visibility : hint_range(0.0, 1.0) = 1.0;

const float bayer4[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

float SchlickFresnel(float u) {
	float m = 1.0 - u;
	float m2 = m * m;
	return m2 * m2 * m;
}

void fragment() {
	if (ghost_stipple > 0.5) {
		vec2 cell = floor(FRAGCOORD.xy / max(stipple_cell_px, 1.0));
		ivec2 c = ivec2(int(mod(cell.x, 4.0)), int(mod(cell.y, 4.0)));
		if (ghost_visibility <= bayer4[c.y * 4 + c.x] / 16.0) {
			discard;
		}
	}
	float VdotN = dot(VIEW, NORMAL);
	float fresnel = clamp(SchlickFresnel(VdotN), 0.0, 1.0);

	// alpha 越低越透明：透明时正对处透出高光边缘色，掠射角呈实色边缘
	float a = mix(0.001, 1.0, albedo.a);
	ALPHA = mix(fresnel * edge_color.a, 1.0, a);
	ALBEDO = mix(edge_color.rgb * edge_color.a, albedo.rgb, a);

	ROUGHNESS = roughness;
	// 透明材质的高光能量补偿：0.5 * ALPHA^-0.5
	SPECULAR = 0.5 * inversesqrt(ALPHA);
}
