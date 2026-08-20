class_name CloudNoise
extends RefCounted
## 体积云 shader(cloud_sky.gdshader)的噪声贴图供给。
## 首选：clayjohn/godot-volumetric-cloud-demo (MIT) 的原版三张贴图——经导入系统
## 变成 CompressedTexture3D(条带图 + 3d_texture importer，带引擎生成的正确 3D mip)。
## 必须用导入管线：实测 4.7 下运行时 ImageTexture3D 在 sky shader 里采样恒为黑
## (spatial 管道正常)，只有导入的 CompressedTexture3D 能在天空绑上。
## 兜底：FastNoiseLite 即时生成(确定性 seed；仅 spatial 管道可用，天空不显示，
## 保证表驱动装配/校验不断链)。
##   worlnoise    3D RGB ：三倍频 Worley —— 云体形态湍流
##   perlworlnoise 3D RGBA：r=Perlin-Worley 基础云场，gba=三倍频 Worley
##   weathermap   2D RGBA：r=云型，b=覆盖度

const TEX_DIR := "res://game/race/env/textures"
const WORL_PATH := TEX_DIR + "/worlnoise.bmp"
const PERL_PATH := TEX_DIR + "/perlworlnoise.tga"
const WEATHER_PATH := TEX_DIR + "/weather.bmp"

const WORL_SEED := 20260811
const PERL_SEED := 20260812
const WEATHER_SEED := 20260813

const WORL_RES := 32
const PERL_RES := 64
const WEATHER_RES := 256

## 三张贴图就绪（键 worlnoise/perlworlnoise/weathermap）：
## 优先上游导入贴图（天空可渲染），缺失时即时生成兜底。
static func textures() -> Dictionary:
	var out := {}
	if ResourceLoader.exists(WORL_PATH):
		out["worlnoise"] = load(WORL_PATH)
	if ResourceLoader.exists(PERL_PATH):
		out["perlworlnoise"] = load(PERL_PATH)
	if ResourceLoader.exists(WEATHER_PATH):
		out["weathermap"] = load(WEATHER_PATH)
	if not out.has("worlnoise"):
		out["worlnoise"] = worlnoise()
	if not out.has("perlworlnoise"):
		out["perlworlnoise"] = perlworlnoise()
	if not out.has("weathermap"):
		out["weathermap"] = weathermap()
	return out

## 贴图来自上游演示(非即时生成)——供校验区分数据来源
static func upstream_available() -> bool:
	return ResourceLoader.exists(WORL_PATH) and ResourceLoader.exists(PERL_PATH) \
			and ResourceLoader.exists(WEATHER_PATH)

# ---------------- 兜底即时生成（FastNoiseLite，确定性 seed） ----------------

static func worlnoise(res := WORL_RES, seed := WORL_SEED) -> ImageTexture3D:
	var cell := _cell_noise(seed)
	var slices: Array[Image] = []
	slices.resize(res)
	for z in res:
		var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
		for y in res:
			for x in res:
				var f := 0.06
				img.set_pixel(x, y, Color(
						_worley(cell, x, y, z, f),
						_worley(cell, x, y, z, f * 2.0),
						_worley(cell, x, y, z, f * 4.0), 1.0))
		slices[z] = img
	return _tex3d(slices)

static func perlworlnoise(res := PERL_RES, seed := PERL_SEED) -> ImageTexture3D:
	var cell := _cell_noise(seed)
	var perlin := _make_noise(seed + 1)
	perlin.frequency = 0.12
	var slices: Array[Image] = []
	slices.resize(res)
	for z in res:
		var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
		for y in res:
			for x in res:
				var f := 0.06
				var g := _worley(cell, x, y, z, f)
				var b := _worley(cell, x, y, z, f * 2.0)
				var a := _worley(cell, x, y, z, f * 4.0)
				var wfbm := g * 0.625 + b * 0.25 + a * 0.125
				var p := clampf(0.5 + 0.5 * perlin.get_noise_3d(x, y, z), 0.0, 1.0)
				var r := clampf((p - (wfbm - 1.0)) / (1.0 - (wfbm - 1.0)), 0.0, 1.0)
				img.set_pixel(x, y, Color(r, g, b, a))
		slices[z] = img
	return _tex3d(slices)

static func weathermap(res := WEATHER_RES, seed := WEATHER_SEED) -> ImageTexture:
	var n := _make_noise(seed)
	var n2 := _make_noise(seed + 2)
	n.frequency = 0.012
	n2.frequency = 0.02
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	for y in res:
		for x in res:
			var cov := 0.5 + 0.5 * smoothstep(0.30, 0.75, 0.5 + 0.5 * n.get_noise_2d(x, y))
			var typ := clampf(0.5 + 0.35 * n2.get_noise_2d(x + 77.0, y - 31.0), 0.0, 1.0)
			img.set_pixel(x, y, Color(typ, 0.0, cov, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func _worley(n: FastNoiseLite, x: float, y: float, z: float, freq: float) -> float:
	n.frequency = freq
	return clampf(1.0 - n.get_noise_3d(x, y, z), 0.0, 1.0)

static func _make_noise(seed: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.domain_warp_enabled = true
	n.domain_warp_amplitude = 0.3
	return n

static func _cell_noise(seed: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	n.domain_warp_enabled = true
	n.domain_warp_amplitude = 0.4
	return n

## use_mipmaps 必须 false：引擎对 3D 切片按 2D 逐片生成 mip，尺寸链错配，
## 真渲染器(Vulkan)报 "Missing Images"（headless 假驱动不校验所以测试不炸）
static func _tex3d(slices: Array[Image]) -> ImageTexture3D:
	var tex := ImageTexture3D.new()
	var err := tex.create(slices[0].get_format(), slices[0].get_width(),
			slices[0].get_height(), slices.size(), false, slices)
	if err != OK:
		push_error("CloudNoise: ImageTexture3D 创建失败 %s" % err)
	return tex
