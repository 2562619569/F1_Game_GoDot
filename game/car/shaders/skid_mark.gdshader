shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, unshaded;

// 极限工况车轮印材质（SkidMarks 组件专用）。
// 出生时刻/强度/淡出时长由 MultiMesh 实例 custom data 携带（4.7 内置名为 INSTANCE_CUSTOM）：
//   INSTANCE_CUSTOM.x = 出生时刻（s，组件时钟）  .y = 强度 [0,1]  .z = 该段淡出时长（s）
// u_time 由组件每渲染帧推进——淡出全程零回写（不逐帧改实例数据），
// 横向 UV 软边避免胎印生硬的方形边带。
// depth_draw_never：车印不写深度——段接缝楔形重叠、画圈/变道车辙交叉时，
// 重叠面片互相争深度会逐帧闪（实测根因）；只测深度（被路面/山体/车身正确
// 遮挡）不写深度，重叠区按实例顺序稳定叠加，视觉无闪。
uniform vec4 mark_color : source_color = vec4(0.05, 0.05, 0.06, 1.0);
uniform float lifetime : hint_range(1.0, 600.0) = 25.0;
uniform float peak_alpha : hint_range(0.0, 1.0) = 0.75;
uniform float u_time = 0.0;
// 渲染链路诊断：>0 时无视 custom data 与淡出，直接用该固定透明度
uniform float debug_flat_alpha = 0.0;

const float FADE_IN = 0.05;  // 淡入时长（s）：出生 ~1m 内显形，不能按寿命比例
                             // （25s×4% = 1 整秒，车都开出 20m 印还没显形）

varying float v_alpha;

void vertex() {
	float intensity = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	// 每段自带淡出时长（组件按落段速率算好，保证环形池覆写前必淡完）；
	// z≤0 视为缺省（直写探针/旧实例），退回 uniform lifetime
	float dur = INSTANCE_CUSTOM.z > 0.0 ? max(INSTANCE_CUSTOM.z, 0.1) : lifetime;
	float age = max(u_time - INSTANCE_CUSTOM.x, 0.0);
	// 寿命前段缓降、尾段收干净（平方曲线）
	float life = clamp(age / max(dur, 0.001), 0.0, 1.0);
	float fade = (1.0 - life * life) * smoothstep(0.0, FADE_IN, age);
	v_alpha = peak_alpha * intensity * fade;
}

void fragment() {
	// 横向软边。注意 smoothstep 要求 edge0 < edge1（反转区间是未定义行为，
	// 实测驱动会返回 ~0.15 常数把整片 alpha 压没——右侧衰减必须写成 1-正区间
	float edge = smoothstep(0.0, 0.18, UV.x) * (1.0 - smoothstep(0.82, 1.0, UV.x));
	ALBEDO = mark_color.rgb;
	ALPHA = (debug_flat_alpha <= 0.0 ? v_alpha : debug_flat_alpha) * edge;
}
