shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 center = vec2(0.5);
uniform float strength : hint_range(0.0, 0.12) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 offset = uv - center;
	float radius = length(offset);
	// Preserve the car and vanishing point; peripheral scenery carries speed.
	float edge_mask = smoothstep(0.08, 0.82, radius);
	float amount = strength * edge_mask;
	vec4 color = vec4(0.0);
	const int SAMPLE_COUNT = 7;
	for (int i = 0; i < SAMPLE_COUNT; i++) {
		float t = (float(i) / float(SAMPLE_COUNT - 1)) - 0.5;
		color += texture(screen_texture, uv - offset * amount * t);
	}
	COLOR = color / float(SAMPLE_COUNT);
}
