// 体积云天空：raymarch 3D 噪声（Horizon: Zero Dawn 手法, Schneider SIGGRAPH 2015）。
// 移植自 clayjohn/godot-volumetric-cloud-demo (MIT, clouds.gdshader)，
// https://github.com/clayjohn/godot-volumetric-cloud-demo
// 本项目改动（其余保持原实现便于日后同步上游）：
//   1. Preetham 解析大气替换为 WeatherEnv 天气预设的四色渐变天空
//      (sky_top/horizon/ground_horizon/ground_bottom uniform 注入，与
//      ProceduralSkyMaterial 同源配色，云天空与各天气地面美术一致)；
//   2. 云受光(直射/环境/地面反照)改从同一渐变取色，加 ambient_energy；
//   3. 太阳盘/光晕颜色取天气预设 sun 色。
// 性能：半/四分之一分辨率 pass raymarch（主天空半分辨率、反射四分之一），
// 输出经天空辐照度 cubemap，全天空每帧只算半分辨率一次。
shader_type sky;
render_mode use_half_res_pass, use_quarter_res_pass;

uniform sampler3D worlnoise : filter_linear_mipmap, repeat_enable;
uniform sampler3D perlworlnoise : filter_linear_mipmap, repeat_enable;
uniform sampler2D weathermap : filter_linear_mipmap, repeat_enable;

uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed : hint_range(0.0, 20.0) = 1.0;
uniform float cloud_density : hint_range(0.01, 0.2) = 0.05;
uniform float cloud_coverage : hint_range(0.1, 1.0) = 0.25;
uniform float cloud_time_offset : hint_range(0.0, 1000.0, 0.5) = 0.0;

// 天气配色（VolumetricClouds.make_sky 从 WeatherEnv 预设注入）
uniform vec4 sky_top_color : source_color = vec4(0.22, 0.48, 0.78, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.66, 0.78, 0.88, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.48, 0.55, 0.60, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.24, 0.28, 0.32, 1.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.97, 0.88, 1.0);
uniform vec4 ambient_color : source_color = vec4(0.6, 0.7, 0.85, 1.0);
uniform float sun_disk_scale : hint_range(0.0, 360.0) = 1.0;
uniform float exposure : hint_range(0.0, 128.0) = 1.0;
uniform float ambient_energy : hint_range(0.0, 4.0) = 1.0;

// Approximately earth sizes
const float g_radius = 6000000.0; //ground radius
const float sky_b_radius = 6001500.0;//bottom of cloud layer
const float sky_t_radius = 6004000.0;//top of cloud layer

const float SOL_SIZE = 0.00872663806;

const vec3 UP = vec3( 0.0, 1.0, 0.0 );

// From: https://www.shadertoy.com/view/4sfGzS credit to iq
float hash(vec3 p) {
	p  = fract( p * 0.3183099 + 0.1 );
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// Utility function that maps a value from one range to another.
float remap(float originalValue,  float originalMin, float originalMax, float newMin, float newMax) {
	return newMin + (((originalValue - originalMin) / (originalMax - originalMin)) * (newMax - newMin));
}

// Phase function
float henyey_greenstein(float cos_theta, float g) {
	const float k = 0.0795774715459;
	return k * (1.0 - g * g) / (pow(1.0 + g * g - 2.0 * g * cos_theta, 1.5));
}

// 四色渐变天空（不含太阳盘）：既是天空底色，也是云受光的照明采样源。
// 曲线与 ProceduralSkyMaterial 同构：天顶/地平线 pow 渐变 + 地面侧两色。
vec3 sky_gradient(vec3 eye_dir) {
	vec3 dir = normalize(eye_dir);
	float up = pow(clamp(dir.y, 0.0, 1.0), 0.42);
	float down = pow(clamp(-dir.y, 0.0, 1.0), 0.42);
	vec3 above = mix(sky_horizon_color.rgb, sky_top_color.rgb, up);
	vec3 below = mix(ground_horizon_color.rgb, ground_bottom_color.rgb, down);
	return mix(above, below, smoothstep(0.08, -0.08, dir.y)) * exposure;
}

// 天空底色 = 渐变 + 太阳光晕(广角瓣,超亮部分交给 glow 泛光) + HDR 太阳盘
vec3 atmosphere(vec3 eye_dir) {
	vec3 col = sky_gradient(eye_dir);
	vec3 ldir = normalize(LIGHT0_DIRECTION);
	float cos_theta = dot(normalize(eye_dir), ldir);
	col += sun_color.rgb * LIGHT0_COLOR * max(LIGHT0_ENERGY, 0.0) * 0.06 * pow(max(cos_theta, 0.0), 12.0);
	float sunAngularDiameterCos = cos(SOL_SIZE * sun_disk_scale);
	float sunAngularDiameterCos2 = cos(SOL_SIZE * sun_disk_scale * 0.5);
	float sundisk = smoothstep(sunAngularDiameterCos, sunAngularDiameterCos2, cos_theta);
	col += sun_color.rgb * LIGHT0_COLOR * sundisk * 2.0 * max(LIGHT0_ENERGY, 0.0);
	return col;
}

float GetHeightFractionForPoint(float inPosition) {
	float height_fraction = (inPosition -  sky_b_radius) / (sky_t_radius - sky_b_radius);
	return clamp(height_fraction, 0.0, 1.0);
}

vec4 mixGradients(float cloudType){
	const vec4 STRATUS_GRADIENT = vec4(0.02f, 0.05f, 0.09f, 0.11f);
	const vec4 STRATOCUMULUS_GRADIENT = vec4(0.02f, 0.2f, 0.48f, 0.625f);
	const vec4 CUMULUS_GRADIENT = vec4(0.01f, 0.0625f, 0.78f, 1.0f);
	float stratus = 1.0f - clamp(cloudType * 2.0f, 0.0, 1.0);
	float stratocumulus = 1.0f - abs(cloudType - 0.5f) * 2.0f;
	float cumulus = clamp(cloudType - 0.5f, 0.0, 1.0) * 2.0f;
	return STRATUS_GRADIENT * stratus + STRATOCUMULUS_GRADIENT * stratocumulus + CUMULUS_GRADIENT * cumulus;
}

float densityHeightGradient(float heightFrac, float cloudType) {
	vec4 cloudGradient = mixGradients(cloudType);
	return smoothstep(cloudGradient.x, cloudGradient.y, heightFrac) - smoothstep(cloudGradient.z, cloudGradient.w, heightFrac);
}

float intersectSphere(vec3 pos, vec3 dir, float r) {
    float a = dot(dir, dir);
    float b = 2.0 * dot(dir, pos);
    float c = dot(pos, pos) - (r * r);
	float d = sqrt((b*b) - 4.0*a*c);
	float p = -b - d;
	float p2 = -b + d;
    return max(p, p2) / (2.0 * a);
}

// Returns density at a given point
// Heavily based on method from Schneider
float density(vec3 pip, vec3 weather, float mip) {
	float time = TIME;
	vec3 p = pip;
	float height_fraction = GetHeightFractionForPoint(length(p));
	p.xz += time * 20.0 * normalize(wind_direction) * wind_speed * 0.6;
	vec4 n = textureLod(perlworlnoise, p.xyz * 0.00008, mip - 2.0);
	float fbm = n.g * 0.625 + n.b * 0.25 + n.a * 0.125;
	float g = densityHeightGradient(height_fraction, weather.r);
	float base_cloud = remap(n.r, -(1.0 - fbm), 1.0, 0.0, 1.0);
	float weather_coverage = cloud_coverage * weather.b;
	base_cloud = remap(base_cloud * g, 1.0 - (weather_coverage), 1.0, 0.0, 1.0);
	base_cloud *= weather_coverage;
	p.xz -= time * normalize(wind_direction) * 40.0;
	p.y -= time * 40.0;
	vec3 hn = textureLod(worlnoise, p * 0.001, mip).rgb;
	float hfbm = hn.r * 0.625 + hn.g * 0.25 + hn.b * 0.125;
	hfbm = mix(hfbm, 1.0 - hfbm, clamp(height_fraction * 4.0, 0.0, 1.0));
	base_cloud = remap(base_cloud, hfbm * 0.4 * height_fraction, 1.0, 0.0, 1.0);
	return pow(clamp(base_cloud, 0.0, 1.0), (1.0 - height_fraction) * 0.8 + 0.5);
}

vec4 march(vec3 pos,  vec3 end, vec3 dir, int depth) {
	const vec3 RANDOM_VECTORS[6] = {vec3( 0.38051305f,  0.92453449f, -0.02111345f),vec3(-0.50625799f, -0.03590792f, -0.86163418f),vec3(-0.32509218f, -0.94557439f,  0.01428793f),vec3( 0.09026238f, -0.27376545f,  0.95755165f),vec3( 0.28128598f,  0.42443639f, -0.86065785f),vec3(-0.16852403f,  0.14748697f,  0.97460106f)};
	float T = 1.0;
	float alpha = 0.0;
	float ss = length(dir);
	dir = normalize(dir);
	vec3 p = pos + dir * hash(pos * 10.0) * ss;
	const float t_dist = sky_t_radius - sky_b_radius;
	float lss = (t_dist / 36.0);
	vec3 ldir = normalize(LIGHT0_DIRECTION);
	vec3 L = vec3(0.0);
	int count=0;
	float t = 1.0;
	float costheta = dot(ldir, dir);
	// Stack multiple phase functions to emulate some backscattering
	float phase = max(max(henyey_greenstein(costheta, 0.6), henyey_greenstein(costheta, (0.4 - 1.4 * ldir.y))), henyey_greenstein(costheta, -0.2));
	// Precalculate sun and ambient colors
	// （改）：直射光取太阳色×能量（HDR，天空渐变色在阴天预设下过暗，会让云整体
	// 发黑）；环境/地面反照取预设 ambient 与地平线色，不再走解析大气采样
	vec3 atmosphere_sun = sun_color.rgb * LIGHT0_COLOR * max(LIGHT0_ENERGY, 0.0) * ss * 0.45;
	vec3 atmosphere_ambient = ambient_color.rgb * ambient_energy;
	vec3 atmosphere_ground = ground_horizon_color.rgb * 0.8;

	const float weather_scale = 0.00006;
	float time = TIME * 0.001 + 0.005 * cloud_time_offset;
	vec2 weather_pos = time * normalize(wind_direction) * wind_speed;

	for (int i = 0; i < depth; i++) {
		p += dir * ss;
		vec3 weather_sample = texture(weathermap, p.xz * weather_scale + 0.5 + weather_pos).xyz;
		float height_fraction = GetHeightFractionForPoint(length(p));

		t = density(p, weather_sample, 0.0);
		float dt = exp(-cloud_density * t * ss);
		T *= dt;
		vec3 lp = p;
		float lt = 1.0;
		float cd = 0.0;

		if (t > 0.0) { //calculate lighting, but only when we are in the cloud
			float lheight_fraction = 0.0;
			for (int j = 0; j < 6; j++) {
				lp += (ldir + RANDOM_VECTORS[j] * float(j)) * lss;
				lheight_fraction = GetHeightFractionForPoint(length(lp));
				vec3 lweather = texture(weathermap, lp.xz * weather_scale + 0.5 + weather_pos).xyz;
				lt = density(lp, lweather, float(j));
				cd += lt;
			}

			// Take a single distant sample
			lp = p + ldir * 18.0 * lss;
			lheight_fraction = GetHeightFractionForPoint(length(lp));
			vec3 lweather = texture(weathermap, lp.xz * weather_scale + 0.5).xyz;
			lt = pow(density(lp, lweather, 5.0), (1.0 - lheight_fraction) * 0.8 + 0.5);
			cd += lt;

			// captures the direct lighting from the sun
			float beers = exp(-cloud_density * cd * lss);
			float beers2 = exp(-cloud_density * cd * lss * 0.25) * 0.7;
			float beers_total = max(beers, beers2);

			vec3 ambient = mix(atmosphere_ground, vec3(1.0), smoothstep(0.0, 1.0, height_fraction)) * cloud_density * mix(atmosphere_ambient, vec3(1.0), 0.4) * (LIGHT0_DIRECTION.y);
			alpha += (1.0 - dt) * (1.0 - alpha);
			L += (ambient + beers_total * atmosphere_sun * phase * alpha) * T * t;
		}
	}
	return clamp(vec4(L, alpha), 0.0, 1.0);
}

void sky() {
	vec3 dir = EYEDIR;

	vec4 col = vec4(0.0);
	if (dir.y > 0.0) {
		vec3 camPos = vec3(0.0, g_radius, 0.0);
		vec3 start = camPos + dir * intersectSphere(camPos, dir, sky_b_radius);
		vec3 end = camPos + dir * intersectSphere(camPos, dir, sky_t_radius);
		float shelldist = (length(end - start));
		// Take fewer steps towards horizon
		float steps = (mix(96.0, 54.0, clamp(dot(dir, vec3(0.0, 1.0, 0.0)), 0.0, 1.0)));
		vec3 raystep = dir * shelldist / steps;
		vec4 volume = march(start, end, raystep, int(steps));
		vec3 background = atmosphere(dir);
		// Draw cloud shape
		col = vec4(background * (1.0 - volume.a) + volume.xyz, 1.0);
		// Blend distant clouds into the sky
		col.xyz = mix(clamp(col.xyz, vec3(0.0), vec3(1.0)), clamp(background, vec3(0.0), vec3(1.0)), smoothstep(0.6, 1.0, 1.0 - dir.y));
	} else {
		col = vec4(atmosphere(dir), 1.0);
	}

	// Draw to quarter res buffer for reflections
	// Draw to half res buffer for main sky
	if (AT_QUARTER_RES_PASS && AT_CUBEMAP_PASS) {
		COLOR = col.xyz;
		ALPHA = 1.0;
	} else if (AT_HALF_RES_PASS && !AT_CUBEMAP_PASS) {
		COLOR = col.xyz;
		ALPHA = 1.0;
	} else if (AT_CUBEMAP_PASS) {
		COLOR = QUARTER_RES_COLOR.rgb;
	} else {
		COLOR = HALF_RES_COLOR.rgb; // Change to col.rgb for full resolution
	}
}
