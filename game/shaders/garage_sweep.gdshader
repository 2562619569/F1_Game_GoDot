shader_type canvas_item;
// 车库→赛道过渡·光带扫描：斜向辉光光带从画面一侧扫过，扫过处车库层
// 溶解、露出底下的赛道画面（发车"闸门升起"的起步感）。
// progress 与相机飞行共用同一条缓动进度，相机没动光带不走。

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float sweep_done : hint_range(0.1, 1.0) = 0.45;   // 扫描在这个进度内完成
uniform vec2 sweep_dir = vec2(0.7071, 0.7071);            // 屏幕空间扫过方向
uniform vec4 band_color : source_color = vec4(1.0, 0.85, 0.5, 1.0);
uniform float band_width : hint_range(0.01, 0.3) = 0.10;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	float p = clamp(progress / sweep_done, 0.0, 1.0);
	// UV 投影到扫描方向，归一到 [0,1]；front 起点略微前移保证 p=0 全显、p=1 扫净
	float ext = abs(sweep_dir.x) + abs(sweep_dir.y);
	float q = dot(UV - vec2(0.5), normalize(sweep_dir)) / ext + 0.5;
	float front = p * (1.0 + band_width) - band_width * 0.5;
	float dist = q - front;
	float vis = smoothstep(0.0, band_width * 0.5, dist);
	// 辉光只叠在车库几何上（透明背景区域不发光），形成贴边光晕
	float glow = exp(-abs(dist) / max(band_width * 0.35, 1e-4));
	COLOR = vec4(col.rgb + band_color.rgb * glow * 1.6 * col.a, col.a * vis);
}
