shader_type canvas_item;
// 车库→赛道过渡·径向变焦（speed rush）：全屏读屏幕纹理做放射拖影，
// 像猛踩油门冲出发车位；强度随缓动进度先扬后抑（中段峰值、两端归零），
// 与相机 QUINT 加减速段呼应。

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec2 center = vec2(0.5, 0.42);          // 拖影消失点（车身屏幕位置）
uniform float strength : hint_range(0.0, 0.2) = 0.055;
uniform float start : hint_range(0.0, 0.9) = 0.18;  // 扫描中段才起量，两效果接力
uniform float aspect : hint_range(0.5, 4.0) = 1.78;

void fragment() {
	float w = clamp((progress - start) / max(1.0 - start, 1e-3), 0.0, 1.0);
	float s = sin(w * 3.14159265);
	float amt = strength * s * pow(s, 0.5);
	vec2 dir = (UV - center) * vec2(aspect, 1.0);
	vec4 acc = vec4(0.0);
	for (int i = 0; i < 12; i++) {
		float t = float(i) / 11.0;
		acc += texture(screen_tex, UV - dir * amt * t / vec2(aspect, 1.0));
	}
	COLOR = acc / 12.0;
}
