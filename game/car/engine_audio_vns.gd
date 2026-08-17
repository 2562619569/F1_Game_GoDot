class_name EngineAudioVNS
extends Node3D
## 引擎声合成组件：ATG-Simulator「Vehicle Noise Synthesizer v1.9」(MIT, © Dan) 的 Godot 移植。
## 替代旧的单采样变调方案（gevp engine_sound.gd）。
##
## 算法（与原版语义一致）：
##  - 加速/减速两套按参考转速分层的循环采样库，任意转速只激活相邻两层，
##    恒功率 cos/sin 交叉淡化（cos²+sin²=1，无响度凹陷）；
##  - 邻对选择带「滞回 + 燃烧事件保持时长」：切层需越过 pair_hysteresis_rpm，
##    且保持时长按点火频率折算并向上取整到物理帧，避免高频抖层；
##  - 每层音高 = (窗口内转速 / 参考转速) × 全局曲线 + 油门贡献 + 换挡回落，软夹在窗口 ±20%；
##  - 油门开度经 load_crossover_point 平滑混合两库；RPM/油门/层音量/层音高各自指数平滑；
##  - 低通/高通/失真挂在专属音频总线，随负载（未平滑）与转速即时开合；
##  - 一次性事件：油门急开(进气吼)/急收(泄气)、换挡回火覆盖层、收油回火概率爆音、
##    红线断火声，全部带随机 pitch 与冷却节流。
## 未移植：chorus/reverb（原版默认强度 0）；Burst 多实例批计算（单实例 GDScript 足够）。
## 采样资产由 tools/audio_gen/make_engine_loops.py 生成，按 bank.json 装配；换真实录音
## 只需保持目录结构。循环点在装配时写入 AudioStreamWAV（不依赖 import 设置）。

const DEFAULT_BANK := "res://assets/audio/engine/default"
const _SHIFT_FADE := 0.02
const _BURBLE_POOL := 4
const _ROAR_POOL := 2
const _FLUTTER_POOL := 2
const _REDLINE_POOL := 3

enum _ShiftFade { IDLE, FADE_IN, SUSTAIN, FADE_OUT }

@export_group("主控")
@export var master_volume := 1.0
## 输出总增益（叠加在每层 dB 上），与旧实现 -16dB 听感衔接
@export var output_gain_db := -16.0
@export var idle_volume := 0.1
@export var max_volume_acc := 0.4
@export var max_volume_dcc := 0.1
@export var pitch_trim_acc := 0.0
@export var pitch_trim_dcc := 0.0
@export var engine_on := true

@export_group("采样库（按参考转速升序）")
@export var acc_clips: Array[AudioStream] = []
@export var acc_rpms: Array[float] = []
@export var dec_clips: Array[AudioStream] = []
@export var dec_rpms: Array[float] = []

@export_group("响应曲线（0..1 归一化转速）")
@export var pitch_curve: Curve
@export var volume_curve: Curve
@export var load_effectiveness_on_pitch := 0.05

@export_group("油门混合")
@export var load_crossover_point := 0.18
@export var load_blend_width := 0.10
@export var auto_blip := true

@export_group("平滑与配对")
@export var rpm_response_time := 0.035
@export var load_response_time := 0.04
@export var clip_volume_response_time := 0.05
@export var clip_pitch_response_time := 0.04
@export var pair_hysteresis_rpm := 120.0
@export var pair_hold_cycles := 0.5
## 转速超出当前邻对窗口外沿多少倍后强制换层并软夹音高（1.2 = ±20%）
@export_range(1.0, 2.0) var max_pitch_ratio_beyond_pair := 1.2

@export_group("燃烧（保持时长折算用）")
@export var cylinder_count := 4
@export var two_stroke := false

@export_group("滤波与失真（挂总线）")
@export var low_pass_curve: Curve
@export var distortion_curve: Curve
@export var low_pass_intensity := 0.5
@export var muffling_intensity := 0.5
@export var low_pass_strength := 0.0
@export var high_pass_strength := 0.0
@export var resonance_strength := 0.0
@export var distortion_intensity := 0.25
@export var distortion_strength := 0.0

@export_group("回火（收油爆音）")
@export var burble_clips: Array[AudioStream] = []
@export var enable_exhaust_burble := true
@export var burble_volume := 0.7
@export var burble_min_rpm := 3500.0
@export var burble_load_low := 0.0
@export var burble_load_high := 0.3
@export var burble_rpm_drop_threshold := 500.0
@export_range(0.0, 1.0) var burble_probability := 0.7
@export var burble_min_delay := 0.05
@export var burble_max_delay := 0.2
@export var burble_random_pitch_variation := 0.08
@export var burble_fade_rate := 40.0

@export_group("换挡（DCT 回火覆盖层）")
@export var shift_burble_clip: AudioStream
@export var shift_burble_volume := 0.7
@export var shift_burble_rpm_volume_influence := 0.5
@export var shift_burble_min_rpm := 2000.0
## 覆盖层时长：太短听不见，0.3~0.4s 是清晰可辨的换挡回火
@export var shift_burble_max_duration := 0.35
@export var shift_burble_base_pitch := 1.0
@export var shift_burble_pitch_variation := 0.06
## 换挡瞬间的音高回落量（VNS 由集成方写 shiftPitchOsc，此处自动等效）再按 decay 回零
@export var shift_pitch_dip := -0.15
@export var shift_pitch_decay := 0.6
## 换挡瞬间引擎层压低（模拟换挡断油），覆盖层结束后快速恢复
@export var shift_duck := 0.4

@export_group("油门体（急开/急收）")
@export var intake_roar_clips: Array[AudioStream] = []
@export var throttle_flutter_clips: Array[AudioStream] = []
@export var intake_roar_volume := 0.6
@export var throttle_flutter_volume := 0.5
@export var throttle_body_pitch_variation := 0.05
@export var throttle_body_cooldown := 0.08

@export_group("红线断油")
@export var redline_clips: Array[AudioStream] = []
@export var enable_redline_effect := true
@export var redline_volume := 0.6
@export var redline_min_rpm := 7000.0
@export var redline_max_rpm := 0.0
@export var redline_base_pitch := 1.0
@export var redline_pitch_variation := 0.05
@export var redline_min_delay := 0.05
@export var redline_max_delay := 0.2

# ---- 运行时状态 ----
var _vehicle: Vehicle
var _manual_rpm := 1000.0
var _manual_load := 0.0
var _idle_rpm := 1000.0
var _max_rpm := 8000.0
var _time := 0.0
var _smoothed_rpm := 1000.0
var _smoothed_load := 0.0
var _prev_smoothed_rpm := 1000.0
var _prev_smoothed_load := 0.0
var _shift_pitch_osc := 0.0
var _non_decelerate_mode := false

var _acc_layers: Array = []   # [{player, ref, lo, hi, vol_off, pitch_off, vol, pitch, _target_vol, _target_pitch}]
var _dec_layers: Array = []
var _acc_state := {"initialized": false, "low": 0, "high": 0, "hold_until": 0.0}
var _dec_state := {"initialized": false, "low": 0, "high": 0, "hold_until": 0.0}

var _bus_index := -1
var _fx_low_pass: AudioEffectLowPassFilter
var _fx_high_pass: AudioEffectHighPassFilter
var _fx_distortion: AudioEffectDistortion

var _burble_pool: Array[AudioStreamPlayer3D] = []
var _roar_pool: Array[AudioStreamPlayer3D] = []
var _flutter_pool: Array[AudioStreamPlayer3D] = []
var _redline_pool: Array[AudioStreamPlayer3D] = []
var _next_burble_time := 0.0
var _next_redline_time := 0.0
var _next_throttle_body_time := 0.0

var _shift_player: AudioStreamPlayer3D
var _shift_fade := _ShiftFade.IDLE
var _shift_stop_time := 0.0
var _shift_target_volume := 0.0
var _shift_fade_start_volume := 0.0
var _shift_fade_start_time := 0.0

var _prev_throttle_input := 0.0
var _prev_gear := 0
var _duck_gain := 1.0
var _rng := RandomNumberGenerator.new()
## 事件触发计数（供 headless 自检断言）
var _diag := {"roar": 0, "flutter": 0, "burble": 0, "redline": 0, "shift": 0}

## 装配入口：挂到 Vehicle 下并加载采样库；失败返回 false（调用方回退旧引擎声）。
## bank.json 结构见 tools/audio_gen/make_engine_loops.py。
func setup(v: Vehicle, bank_dir := DEFAULT_BANK) -> bool:
	_vehicle = v
	_rng.randomize()
	if not _load_bank(bank_dir):
		return false
	_idle_rpm = maxf(v.idle_rpm, 1.0)
	_max_rpm = maxf(maxf(v.max_rpm, 1.0), _highest_clip_rpm())
	if redline_max_rpm <= 0.0:
		redline_max_rpm = _max_rpm
	redline_min_rpm = maxf(redline_min_rpm, v.max_rpm * 0.97)
	_build_default_curves()
	_build_runtime()
	return true

## 无车辆的手动驱动（展厅/测试用）：直接给定转速与负载
func set_engine_state(rpm: float, load: float, on := true) -> void:
	_manual_rpm = rpm
	_manual_load = clampf(load, 0.0, 1.0)
	engine_on = on

func on_throttle_tip_in(throttle_value: float, rpm: float, engine_load: float) -> void:
	if intake_roar_clips.is_empty() or not engine_on:
		return
	var coeff := throttle_value * maxf(0.5, engine_load)
	if coeff <= 0.001 or _time < _next_throttle_body_time:
		return
	var src := _free_source(_roar_pool)
	if src == null:
		return
	src.stream = intake_roar_clips[_rng.randi() % intake_roar_clips.size()]
	src.set_meta("vol", intake_roar_volume * coeff)
	src.volume_db = linear_to_db(maxf(intake_roar_volume * coeff, 0.001)) + output_gain_db
	src.pitch_scale = clampf(1.0 + _normalized_rpm(rpm) * 0.2
			+ _rng.randf_range(-throttle_body_pitch_variation, throttle_body_pitch_variation), 0.01, 4.0)
	src.play()
	_next_throttle_body_time = _time + throttle_body_cooldown
	_diag["roar"] += 1

func on_throttle_tip_out(rpm: float, _engine_load: float) -> void:
	if throttle_flutter_clips.is_empty() or not engine_on:
		return
	if _time < _next_throttle_body_time:
		return
	var src := _free_source(_flutter_pool)
	if src == null:
		return
	src.stream = throttle_flutter_clips[_rng.randi() % throttle_flutter_clips.size()]
	src.set_meta("vol", throttle_flutter_volume)
	src.volume_db = linear_to_db(maxf(throttle_flutter_volume, 0.001)) + output_gain_db
	src.pitch_scale = clampf(1.0 + _normalized_rpm(rpm) * 0.3
			+ _rng.randf_range(-throttle_body_pitch_variation, throttle_body_pitch_variation), 0.01, 4.0)
	src.play()
	_next_throttle_body_time = _time + throttle_body_cooldown
	_diag["flutter"] += 1

func on_gear_shift() -> void:
	_diag["shift"] += 1
	_shift_pitch_osc = shift_pitch_dip
	if shift_burble_clip == null or not engine_on:
		return
	# VNS OnGearShift：覆盖层音量随换挡时转速（min→max 映射 0..1）线性抬升
	var normalized := _inv_lerp(maxf(shift_burble_min_rpm, 1.0), maxf(shift_burble_min_rpm + 1.0, _max_rpm), _smoothed_rpm)
	var rpm_vol_scale := lerpf(1.0 - shift_burble_rpm_volume_influence, 1.0, normalized)
	_shift_target_volume = shift_burble_volume * rpm_vol_scale
	_shift_player.stream = shift_burble_clip
	_shift_player.volume_db = -80.0
	_shift_player.pitch_scale = clampf(shift_burble_base_pitch
			+ _rng.randf_range(-shift_burble_pitch_variation, shift_burble_pitch_variation), 0.01, 3.0)
	_shift_player.play()
	_shift_stop_time = _time + shift_burble_max_duration
	_begin_shift_fade(_ShiftFade.FADE_IN, 0.0)

func turn_on() -> void:
	engine_on = true

func turn_off() -> void:
	engine_on = false

func _physics_process(delta: float) -> void:
	if _bus_index < 0:
		return   # setup 未完成（总线未建）前不参与处理
	var rpm := _vehicle.motor_rpm if _vehicle else _manual_rpm
	var load := clampf(_vehicle.throttle_amount if _vehicle else _manual_load, 0.0, 1.0)
	if _vehicle:
		# 油门急开/急收与换挡的自动检测（VNS 由集成方调用，这里等效内置）
		var ti := _vehicle.throttle_input
		if _prev_throttle_input < 0.15 and ti >= 0.15:
			on_throttle_tip_in(ti, rpm, load)
		elif _prev_throttle_input > 0.5 and ti <= 0.5:
			on_throttle_tip_out(rpm, load)
		_prev_throttle_input = ti
		if _vehicle.current_gear != _prev_gear:
			_prev_gear = _vehicle.current_gear
			on_gear_shift()
	tick(rpm, load, delta)

## 核心一拍（VNS 的 CalculateAsync + ProcessAudioFrame 合并）；测试直接调用以脱离物理帧
func tick(rpm: float, load: float, delta: float) -> void:
	if not engine_on:
		_fade_all_to_silence(delta)
		return
	var raw_rpm := maxf(rpm, 0.0)
	var raw_load := clampf(load, 0.0, 1.0)
	_time += delta
	var rpm_alpha := _smoothing_alpha(rpm_response_time, delta)
	var load_alpha := _smoothing_alpha(load_response_time, delta)
	_prev_smoothed_rpm = _smoothed_rpm
	_prev_smoothed_load = _smoothed_load
	# 平滑目标直接取原始值（_load 等价 VNS 的 filterLoad 路径，另存原始负载供滤波用）
	_smoothed_rpm = lerpf(_smoothed_rpm, raw_rpm, rpm_alpha)
	_smoothed_load = lerpf(_smoothed_load, raw_load, load_alpha)
	_raw_load = raw_load
	_shift_pitch_osc = move_toward(_shift_pitch_osc, 0.0, shift_pitch_decay * delta)
	# 换挡覆盖层激活期间压低引擎层（模拟断油），响应略慢于覆盖层淡入
	var duck_target := shift_duck if _shift_fade != _ShiftFade.IDLE else 1.0
	_duck_gain = lerpf(_duck_gain, duck_target, _smoothing_alpha(0.04, delta))

	var clamped_rpm := clampf(_smoothed_rpm, 0.0, maxf(1.0, _max_rpm))
	var normalized := _normalized_rpm(clamped_rpm)
	var curve_pitch := pitch_curve.sample_baked(normalized)
	var final_pitch := maxf(0.01, curve_pitch + _smoothed_load * load_effectiveness_on_pitch + _shift_pitch_osc)

	var half_width := maxf(0.005, load_blend_width * 0.5)
	var start := clampf(load_crossover_point - half_width, 0.0, 1.0)
	var end := clampf(load_crossover_point + half_width, 0.0, 1.0)
	var t_load := _inv_lerp(start, end, _smoothed_load)
	var acc_blend := t_load * t_load * (3.0 - 2.0 * t_load)
	if auto_blip:
		var rpm_jump_up := _prev_smoothed_rpm + 75.0 < clamped_rpm
		var snapped_idle := clamped_rpm <= maxf(1.0, _idle_rpm) and _prev_smoothed_rpm > clamped_rpm + 75.0
		if rpm_jump_up or snapped_idle:
			acc_blend = 1.0

	var rpm_volume := volume_curve.sample_baked(normalized)
	var idle_bias := lerpf(idle_volume, 1.0, normalized)
	var final_acc_vol := clampf(acc_blend * rpm_volume * idle_bias, 0.0, 1.0)
	var final_dec_vol := clampf((1.0 - acc_blend) * rpm_volume * idle_bias, 0.0, 1.0)
	if _non_decelerate_mode:
		final_acc_vol = clampf(maxf(final_acc_vol, final_dec_vol), 0.0, 1.0)
		final_dec_vol = 0.0
	if clamped_rpm <= maxf(1.0, _idle_rpm):
		final_acc_vol = maxf(final_acc_vol, idle_volume)

	_evaluate_bank(_acc_layers, _acc_state, true, final_pitch, final_acc_vol, clamped_rpm, max_volume_acc, pitch_trim_acc)
	_evaluate_bank(_dec_layers, _dec_state, false, final_pitch, final_dec_vol, clamped_rpm, max_volume_dcc, pitch_trim_dcc)
	# 换挡 duck 乘在库上限之后：高负载层增益已顶到 max_volume_acc 时，乘基础增益会被钳制遮蔽
	for layer in _acc_layers + _dec_layers:
		layer["_target_vol"] = float(layer["_target_vol"]) * _duck_gain
	_apply_bank_slew(_acc_layers, delta)
	_apply_bank_slew(_dec_layers, delta)
	_apply_bus_effects(normalized)
	_update_burble(delta, clamped_rpm)
	_update_redline(clamped_rpm)
	_update_shift_overlay()

## 供测试/调试读取内部状态
func debug_info() -> Dictionary:
	var info := {
		"rpm": _smoothed_rpm, "load": _smoothed_load, "time": _time,
		"pitch_osc": _shift_pitch_osc,
		"acc_pair": [_acc_state["low"], _acc_state["high"]],
		"dec_pair": [_dec_state["low"], _dec_state["high"]],
		"diag": _diag.duplicate(), "shift_fade": _shift_fade,
		"acc_active": [], "dec_active": [],
	}
	for layer in _acc_layers:
		if layer["vol"] > 0.001:
			info["acc_active"].append({"ref": layer["ref"], "vol": layer["vol"], "pitch": layer["pitch"]})
	for layer in _dec_layers:
		if layer["vol"] > 0.001:
			info["dec_active"].append({"ref": layer["ref"], "vol": layer["vol"], "pitch": layer["pitch"]})
	return info

## 固定随机种子（测试用；生产在 setup 里 randomize）
func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value

var _raw_load := 0.0

# ---------------- 装配 ----------------

func _load_bank(bank_dir: String) -> bool:
	var json_path := bank_dir.path_join("bank.json")
	if not FileAccess.file_exists(json_path):
		push_warning("EngineAudioVNS: 缺少 %s" % json_path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if not parsed is Dictionary:
		push_warning("EngineAudioVNS: bank.json 解析失败 %s" % bank_dir)
		return false
	var bank: Dictionary = parsed
	acc_clips.clear()
	acc_rpms.clear()
	dec_clips.clear()
	dec_rpms.clear()
	if not _load_bank_entries(bank.get("acc", []), acc_clips, acc_rpms, bank_dir):
		return false
	_load_bank_entries(bank.get("dec", []), dec_clips, dec_rpms, bank_dir)
	burble_clips = _load_clip_array(bank, "burble", bank_dir)
	intake_roar_clips = _load_clip_array(bank, "roar", bank_dir)
	throttle_flutter_clips = _load_clip_array(bank, "flutter", bank_dir)
	redline_clips = _load_clip_array(bank, "redline", bank_dir)
	if bank.has("shift_burble"):
		var s = load(bank_dir.path_join(bank["shift_burble"]))
		if s is AudioStream:
			_make_loopable(s)
			shift_burble_clip = s
	if acc_clips.is_empty():
		push_warning("EngineAudioVNS: 加速库为空 %s" % bank_dir)
		return false
	cylinder_count = maxi(1, int(bank.get("cylinders", cylinder_count)))
	return true

func _load_bank_entries(entries: Array, clips: Array[AudioStream], rpms: Array[float], bank_dir: String) -> bool:
	for entry in entries:
		var stream = load(bank_dir.path_join(entry["file"]))
		if not stream is AudioStream:
			push_warning("EngineAudioVNS: 采样缺失 %s/%s" % [bank_dir, entry["file"]])
			return false
		_make_loopable(stream)
		clips.append(stream)
		rpms.append(float(entry["rpm"]))
	return true

func _load_clip_array(bank: Dictionary, key: String, bank_dir: String) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for f in bank.get(key, []):
		var s = load(bank_dir.path_join(f))
		if s is AudioStream:
			out.append(s)
	return out

## 循环点写进资源本身，不依赖 .import 的 loop 设置（默认是关的）
func _make_loopable(stream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		var bytes_per_frame := 2
		if wav.format == AudioStreamWAV.FORMAT_8_BITS:
			bytes_per_frame = 1
		elif wav.format == AudioStreamWAV.FORMAT_IMA_ADPCM:
			bytes_per_frame = 0
		wav.loop_end = wav.data.size() / bytes_per_frame if bytes_per_frame > 0 else -1

func _build_default_curves() -> void:
	if pitch_curve == null:
		pitch_curve = _curve([0.0, 1.0], [1.0, 1.0])
	if volume_curve == null:
		volume_curve = _curve([0.0, 1.0], [0.5, 1.0])
	if distortion_curve == null:
		distortion_curve = _curve([0.0, 0.7, 1.0], [0.0, 0.3, 0.5])
	if low_pass_curve == null:
		low_pass_curve = _curve([0.0, 1.0], [800.0, 22000.0])

func _curve(xs: Array, ys: Array) -> Curve:
	var c := Curve.new()
	for i in xs.size():
		c.add_point(Vector2(xs[i], ys[i]))
	return c

func _build_runtime() -> void:
	_non_decelerate_mode = dec_clips.is_empty()
	_smoothed_rpm = _manual_rpm
	_smoothed_load = _manual_load
	_prev_smoothed_rpm = _smoothed_rpm
	_prev_smoothed_load = _smoothed_load
	_build_bus()   # 总线先建，播放器才能挂上去
	_acc_layers = _build_bank_layers(acc_clips, acc_rpms, "Acc")
	_dec_layers = _build_bank_layers(dec_clips, dec_rpms, "Dec")
	_burble_pool = _build_pool("Burble", _BURBLE_POOL)
	_roar_pool = _build_pool("Roar", _ROAR_POOL)
	_flutter_pool = _build_pool("Flutter", _FLUTTER_POOL)
	_redline_pool = _build_pool("Redline", _REDLINE_POOL)
	_shift_player = _make_player("ShiftOverlay")

func _build_bank_layers(clips: Array[AudioStream], rpms: Array[float], prefix: String) -> Array:
	var layers: Array = []
	for i in clips.size():
		var player := _make_player("%s%d" % [prefix, i])
		player.stream = clips[i]
		player.volume_db = -80.0
		player.play()
		layers.append({
			"player": player, "ref": maxf(1.0, rpms[i] if i < rpms.size() else 1000.0),
			"lo": 1.0, "hi": 1.0, "vol_off": 0.0, "pitch_off": 0.0,
			"vol": 0.0, "pitch": 1.0, "_target_vol": 0.0, "_target_pitch": 1.0,
		})
	return layers

func _build_pool(prefix: String, count: int) -> Array[AudioStreamPlayer3D]:
	var pool: Array[AudioStreamPlayer3D] = []
	for i in count:
		var p := _make_player("%s%d" % [prefix, i])
		p.volume_db = -80.0
		pool.append(p)
	return pool

func _make_player(player_name: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = player_name
	# 总增益统一走 output_gain_db，max_db 放宽避免钳制层音量
	p.max_db = 6.0
	p.unit_size = 6.0
	p.attenuation_filter_cutoff_hz = 20000.0
	if _bus_index >= 0:
		p.bus = AudioServer.get_bus_name(_bus_index)
	add_child(p)
	return p

func _build_bus() -> void:
	_bus_index = AudioServer.bus_count
	AudioServer.add_bus(_bus_index)
	AudioServer.set_bus_name(_bus_index, "VNSEngine_%d" % get_instance_id())
	AudioServer.set_bus_send(_bus_index, "Master")
	_fx_high_pass = AudioEffectHighPassFilter.new()
	_fx_low_pass = AudioEffectLowPassFilter.new()
	_fx_distortion = AudioEffectDistortion.new()
	_fx_distortion.mode = AudioEffectDistortion.MODE_CLIP
	_fx_distortion.post_gain = -6.0
	AudioServer.add_bus_effect(_bus_index, _fx_high_pass)
	AudioServer.add_bus_effect(_bus_index, _fx_low_pass)
	AudioServer.add_bus_effect(_bus_index, _fx_distortion)

func _exit_tree() -> void:
	if _bus_index >= 0 and _bus_index < AudioServer.bus_count:
		AudioServer.remove_bus(_bus_index)
	_bus_index = -1

# ---------------- 每拍计算（VNS EvaluateBankTargets / FindStableNeighbourPair） ----------------

func _evaluate_bank(layers: Array, state: Dictionary, is_acc: bool, final_pitch: float,
		bank_final_vol: float, clamped_rpm: float, bank_volume_limit: float, bank_pitch_trim: float) -> void:
	for layer in layers:
		layer["_target_vol"] = 0.0
		layer["_target_pitch"] = 1.0
	if layers.is_empty():
		return
	# VNS loadGain：负载抬升本库增益（加速库随油门升，减速库随松油升），下限 0.1
	var load_gain_raw := lerpf(0.1, 1.0, _smoothed_load if is_acc else 1.0 - _smoothed_load)
	var base_gain := master_volume * bank_final_vol * maxf(0.0, load_gain_raw)
	var pair := _find_stable_pair(layers, state, clamped_rpm)
	var lo: int = pair.x
	var hi: int = pair.y
	var stretch := maxf(1.0, max_pitch_ratio_beyond_pair)
	var pitch_rpm := _clamp_pair_pitch_rpm(clamped_rpm, layers[lo]["ref"], layers[hi]["ref"], stretch)
	if lo == hi:
		var single: Dictionary = layers[lo]
		var g := base_gain * maxf(0.0, 1.0 + single["vol_off"])
		if bank_volume_limit > 0.0:
			g = minf(g, bank_volume_limit)
		single["_target_vol"] = g
		single["_target_pitch"] = _layer_pitch(single, pitch_rpm, final_pitch, bank_pitch_trim)
		return
	var t := _inv_lerp(layers[lo]["ref"], layers[hi]["ref"], clamped_rpm)
	var angle := t * PI * 0.5
	var g_lo := base_gain * cos(angle) * maxf(0.0, 1.0 + layers[lo]["vol_off"])
	var g_hi := base_gain * sin(angle) * maxf(0.0, 1.0 + layers[hi]["vol_off"])
	if bank_volume_limit > 0.0:
		g_lo = minf(g_lo, bank_volume_limit)
		g_hi = minf(g_hi, bank_volume_limit)
	layers[lo]["_target_vol"] = g_lo
	layers[hi]["_target_vol"] = g_hi
	layers[lo]["_target_pitch"] = _layer_pitch(layers[lo], pitch_rpm, final_pitch, bank_pitch_trim)
	layers[hi]["_target_pitch"] = _layer_pitch(layers[hi], pitch_rpm, final_pitch, bank_pitch_trim)

func _layer_pitch(layer: Dictionary, pitch_rpm: float, final_pitch: float, bank_pitch_trim: float) -> float:
	var ratio_pitch: float = (pitch_rpm / float(layer["ref"])) * final_pitch
	var progress := clampf((pitch_rpm - _idle_rpm) / maxf(1.0, _max_rpm - _idle_rpm), 0.0, 1.0)
	var hi_lo_mul := lerpf(layer["lo"], layer["hi"], progress)
	return clampf(ratio_pitch * hi_lo_mul + bank_pitch_trim + layer["pitch_off"], 0.01, 3.0)

## 滞回 + 燃烧保持 + 越窗强切（原版 FindStableNeighbourPair 逐行移植）
func _find_stable_pair(layers: Array, state: Dictionary, clamped_rpm: float) -> Vector2i:
	var count := layers.size()
	if count == 1:
		if not state["initialized"]:
			state["initialized"] = true
			state["low"] = 0
			state["high"] = 0
			state["hold_until"] = _time + _hold_duration()
		return Vector2i(0, 0)
	var ideal := _find_immediate_pair(layers, clamped_rpm)
	var cur_lo: int = state["low"] if state["low"] < count else count - 1
	var cur_hi: int = state["high"] if state["high"] < count else count - 1
	var stretch := maxf(1.0, max_pitch_ratio_beyond_pair)

	if not state["initialized"]:
		state["initialized"] = true
		state["low"] = ideal.x
		state["high"] = ideal.y
		state["hold_until"] = _time + _hold_duration()
		return ideal

	var wants_switch := ideal.x != cur_lo or ideal.y != cur_hi
	var in_hold: bool = _time < float(state["hold_until"])
	var step_gap: int = maxi(absi(ideal.y - cur_hi), absi(ideal.x - cur_lo))
	var multi_step_behind := step_gap > 1
	var stretch_escape := false
	if in_hold or wants_switch:
		var pair_min := minf(layers[cur_lo]["ref"], layers[cur_hi]["ref"])
		var pair_max := maxf(layers[cur_lo]["ref"], layers[cur_hi]["ref"])
		stretch_escape = clamped_rpm > pair_max * stretch or clamped_rpm < pair_min / stretch
	var force_ideal := multi_step_behind or stretch_escape
	if in_hold and not force_ideal:
		return Vector2i(cur_lo, cur_hi)
	var passes_hysteresis := false
	if wants_switch:
		if ideal.y > cur_hi:
			passes_hysteresis = clamped_rpm > layers[cur_hi]["ref"] + pair_hysteresis_rpm
		elif ideal.y < cur_hi:
			passes_hysteresis = clamped_rpm < layers[cur_lo]["ref"] - pair_hysteresis_rpm
		else:
			passes_hysteresis = true
	if wants_switch and (passes_hysteresis or force_ideal):
		state["low"] = ideal.x
		state["high"] = ideal.y
		state["hold_until"] = _time + _hold_duration()
		return ideal
	return Vector2i(cur_lo, cur_hi)

func _find_immediate_pair(layers: Array, clamped_rpm: float) -> Vector2i:
	var count := layers.size()
	for i in count - 1:
		if clamped_rpm >= layers[i]["ref"] and clamped_rpm <= layers[i + 1]["ref"]:
			return Vector2i(i, i + 1)
	if clamped_rpm < layers[0]["ref"]:
		return Vector2i(0, 0)
	if clamped_rpm > layers[count - 1]["ref"]:
		return Vector2i(count - 1, count - 1)
	# 兜底：最近邻
	var best := INF
	var pick := 0
	for i in count:
		var d := absf(layers[i]["ref"] - clamped_rpm)
		if d < best:
			best = d
			pick = i
	return Vector2i(pick, pick)

## 保持时长 = pair_hold_cycles 个燃烧事件，向上取整到物理帧（0 表示禁用）
func _hold_duration() -> float:
	var ft := 1.0 / maxf(1.0, float(Engine.physics_ticks_per_second))
	var cevpr := float(cylinder_count) if two_stroke else cylinder_count / 2.0
	if cevpr <= 0.0 or _smoothed_rpm <= 0.0 or pair_hold_cycles <= 0.0:
		return 0.0
	var raw := pair_hold_cycles / (_smoothed_rpm / 60.0 * cevpr)
	return ceilf(raw / ft) * ft

func _clamp_pair_pitch_rpm(clamped_rpm: float, pair_lo_ref: float, pair_hi_ref: float, stretch: float) -> float:
	var min_ref := maxf(1.0, minf(pair_lo_ref, pair_hi_ref))
	var max_ref := maxf(min_ref, maxf(pair_lo_ref, pair_hi_ref))
	return clampf(clamped_rpm, min_ref / stretch, max_ref * stretch)

# ---------------- 应用到播放器 ----------------

func _apply_bank_slew(layers: Array, delta: float) -> void:
	var vol_alpha := _smoothing_alpha(clip_volume_response_time, delta)
	var pitch_alpha := _smoothing_alpha(clip_pitch_response_time, delta)
	for layer in layers:
		layer["vol"] = lerpf(layer["vol"], layer["_target_vol"], vol_alpha)
		layer["pitch"] = lerpf(layer["pitch"], layer["_target_pitch"], pitch_alpha)
		var p: AudioStreamPlayer3D = layer["player"]
		p.volume_db = maxf(linear_to_db(maxf(layer["vol"], 0.00001)) + output_gain_db, -80.0)
		p.pitch_scale = layer["pitch"]

func _apply_bus_effects(normalized: float) -> void:
	if _bus_index < 0:
		return
	# 低通/高通用未平滑负载：油门突变时频谱立刻开合（VNS 同款策略）
	var filter_load := clampf(_raw_load, 0.0, 1.0)
	var lp_curve_value := clampf(low_pass_curve.sample_baked(filter_load), 500.0, 22000.0)
	var lp_mix := clampf(maxf(low_pass_intensity, low_pass_strength + muffling_intensity), 0.0, 1.0)
	var hp_rpm_term := normalized * normalized
	var hp_load_scale := lerpf(0.35, 1.0, filter_load)
	var hp_amount := clampf(hp_rpm_term * hp_load_scale * high_pass_strength, 0.0, 1.0)
	var res_shape := sin(normalized * PI)
	_fx_low_pass.cutoff_hz = lerpf(22000.0, lp_curve_value, lp_mix)
	_fx_low_pass.resonance = lerpf(1.0, 8.0, clampf(res_shape * resonance_strength, 0.0, 1.0))
	_fx_high_pass.cutoff_hz = lerpf(10.0, 1800.0, hp_amount)
	_fx_high_pass.resonance = lerpf(1.0, 2.2, hp_amount)
	var dist_drive := distortion_curve.sample_baked(normalized) * (filter_load + 0.5)
	_fx_distortion.drive = clampf(dist_drive * distortion_intensity * (1.0 + distortion_strength), 0.0, 1.0)

func _fade_all_to_silence(delta: float) -> void:
	var vol_alpha := _smoothing_alpha(clip_volume_response_time, delta)
	for layer in _acc_layers + _dec_layers:
		layer["vol"] = lerpf(layer["vol"], 0.0, vol_alpha)
		(layer["player"] as AudioStreamPlayer3D).volume_db = \
				maxf(linear_to_db(maxf(layer["vol"], 0.00001)) + output_gain_db, -80.0)
	if _shift_player and _shift_player.playing:
		_shift_player.stop()
		_shift_fade = _ShiftFade.IDLE

# ---------------- 一次性事件（VNS UpdateBurble / UpdateRedlineEffect / DCT 覆盖层） ----------------

func _update_burble(delta: float, clamped_rpm: float) -> void:
	for p in _burble_pool:
		if p.playing:
			# VNS 对线性音量按 fade_rate 衰减；用 meta 存线性音量再换算 dB
			var vol := maxf(0.0, float(p.get_meta("vol", 0.0)) - burble_fade_rate * delta)
			p.set_meta("vol", vol)
			p.volume_db = maxf(linear_to_db(maxf(vol, 0.00001)) + output_gain_db, -80.0)
	if not enable_exhaust_burble or burble_clips.is_empty() or _time < _next_burble_time or not engine_on:
		return
	var rpm_ok := clamped_rpm >= burble_min_rpm
	var load_ok := _smoothed_load >= burble_load_low and _smoothed_load < burble_load_high
	var rpm_drop_ok := burble_rpm_drop_threshold > 0.0 and (_prev_smoothed_rpm - _smoothed_rpm) >= burble_rpm_drop_threshold
	if not (rpm_ok and (load_ok or rpm_drop_ok)):
		return
	if _rng.randf() > burble_probability:
		_next_burble_time = _time + _rng.randf_range(burble_min_delay, burble_max_delay)
		return
	var src := _free_source(_burble_pool)
	if src == null:
		return
	src.stream = burble_clips[_rng.randi() % burble_clips.size()]
	src.set_meta("vol", burble_volume)
	src.volume_db = linear_to_db(maxf(burble_volume, 0.001)) + output_gain_db
	src.pitch_scale = clampf(1.0 + _rng.randf_range(-burble_random_pitch_variation, burble_random_pitch_variation), 0.01, 4.0)
	src.play()
	_diag["burble"] += 1
	_next_burble_time = _time + _rng.randf_range(burble_min_delay, burble_max_delay)

func _update_redline(clamped_rpm: float) -> void:
	if not enable_redline_effect or redline_clips.is_empty() or not engine_on:
		return
	var ceiling := redline_max_rpm if redline_max_rpm > 0.0 else _max_rpm
	if clamped_rpm < redline_min_rpm or clamped_rpm > ceiling or _time < _next_redline_time:
		return
	var src := _free_source(_redline_pool)
	if src == null:
		return
	src.stream = redline_clips[_rng.randi() % redline_clips.size()]
	src.set_meta("vol", redline_volume)
	src.volume_db = linear_to_db(maxf(redline_volume, 0.001)) + output_gain_db
	src.pitch_scale = clampf(redline_base_pitch
			+ _rng.randf_range(-redline_pitch_variation, redline_pitch_variation), 0.01, 4.0)
	src.play()
	_diag["redline"] += 1
	_next_redline_time = _time + _rng.randf_range(redline_min_delay, redline_max_delay)

func _update_shift_overlay() -> void:
	if _shift_player == null:
		return
	_update_shift_fade()
	if not _shift_player.playing:
		return
	if _time >= _shift_stop_time:
		if _shift_fade != _ShiftFade.FADE_OUT:
			_begin_shift_fade(_ShiftFade.FADE_OUT, db_to_linear(_shift_player.volume_db))
		return
	# 30ms 宽限后：油门重新踩下（原始负载上跳）立即掐断覆盖层
	var elapsed := _time - (_shift_stop_time - shift_burble_max_duration)
	if elapsed > 0.03:
		if _raw_load - _prev_smoothed_load > 0.05 and _shift_fade != _ShiftFade.FADE_OUT:
			_begin_shift_fade(_ShiftFade.FADE_OUT, db_to_linear(_shift_player.volume_db))

func _update_shift_fade() -> void:
	if _shift_fade == _ShiftFade.IDLE:
		return
	var t := clampf((_time - _shift_fade_start_time) / _SHIFT_FADE, 0.0, 1.0)
	match _shift_fade:
		_ShiftFade.FADE_IN:
			_shift_player.volume_db = linear_to_db(maxf(lerpf(_shift_fade_start_volume, _shift_target_volume, t), 0.00001)) + output_gain_db
			if t >= 1.0:
				_shift_fade = _ShiftFade.SUSTAIN
		_ShiftFade.SUSTAIN:
			_shift_player.volume_db = linear_to_db(maxf(_shift_target_volume, 0.00001)) + output_gain_db
		_ShiftFade.FADE_OUT:
			_shift_player.volume_db = linear_to_db(maxf(lerpf(_shift_fade_start_volume, 0.0, t), 0.00001)) + output_gain_db
			if t >= 1.0:
				_shift_player.stop()
				_shift_player.volume_db = -80.0
				_shift_fade = _ShiftFade.IDLE

func _begin_shift_fade(state: int, from_volume: float) -> void:
	_shift_fade = state
	_shift_fade_start_volume = from_volume
	_shift_fade_start_time = _time

func _free_source(pool: Array[AudioStreamPlayer3D]) -> AudioStreamPlayer3D:
	if pool.is_empty():
		return null
	for p in pool:
		if not p.playing:
			return p
	var quietest := pool[0]
	for p in pool:
		if p.volume_db < quietest.volume_db:
			quietest = p
	return quietest

# ---------------- 工具 ----------------

func _smoothing_alpha(response_time: float, delta: float) -> float:
	if response_time < 0.0001:
		return 1.0
	return 1.0 - exp(-delta / response_time)

func _inv_lerp(a: float, b: float, t: float) -> float:
	if b - a < 0.00001:
		return 0.0
	return clampf((t - a) / (b - a), 0.0, 1.0)

func _normalized_rpm(rpm: float) -> float:
	return _inv_lerp(maxf(0.0, _idle_rpm), maxf(_idle_rpm + 1.0, _max_rpm), rpm)

func _highest_clip_rpm() -> float:
	var highest := 0.0
	for rpm in acc_rpms + dec_rpms:
		highest = maxf(highest, rpm)
	return highest
