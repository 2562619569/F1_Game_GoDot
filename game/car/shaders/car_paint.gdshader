shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 车漆：godotshaders.com「Automotive Paint」（作者 ChefC，CC0，基于 Ben Cloward 教程），逻辑保持原版。
// 仅两处适配：flake_texture 由 material_presets.gd 运行时生成注入（非同步期间纯白兜底）；
// 采样器加 repeat_enable/hint_default_white 提示（UV*flake_scale 远超 0-1，需平铺）。

group_uniforms Base_Paint;
uniform vec3 facing_color : source_color = vec3(0.15, 0.5, 0.9);
uniform vec3 glancing_color : source_color = vec3(0.0, 0.05, 0.2);
uniform float fresnel_exponent : hint_range(0.1, 10.0) = 2.0;
uniform float paint_metallic : hint_range(0.0, 1.0) = 0.8;
uniform float paint_specular : hint_range(0.0, 1.0) = 0.5;

group_uniforms Metallic_Flakes;
uniform sampler2D flake_texture : repeat_enable, hint_default_white;
uniform float flake_scale : hint_range(1.0, 500.0) = 150.0;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.4;
uniform float flake_roughness : hint_range(0.0, 1.0) = 0.1;

group_uniforms Clear_Coat;
uniform float clearcoat_amount : hint_range(0.0, 1.0) = 1.0;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.02;

void fragment() {
	// Fresnel：正视 facing 色，掠射角混入 glancing 色
	float fresnel = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	fresnel = pow(fresnel, fresnel_exponent);

	ALBEDO = mix(facing_color, glancing_color, fresnel);
	METALLIC = paint_metallic;
	SPECULAR = paint_specular;

	// 金属闪烁（原版）：噪声连续调制粗糙度
	float flakes = texture(flake_texture, UV * flake_scale).r;
	ROUGHNESS = mix(base_roughness, flake_roughness, flakes);

	// 清漆层
	CLEARCOAT = clearcoat_amount;
	CLEARCOAT_ROUGHNESS = clearcoat_roughness;
}
