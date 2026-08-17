extends SceneTree
## 引擎声 VNS 移植自检（godot --headless -s 运行，不依赖 autoload）：
## 1. 装配：bank.json 加载出 7+7 分层、专属音频总线已建、循环点写入 AudioStreamWAV；
## 2. 扫转：1000→8500rpm，全程恰好激活相邻两层，恒功率交叉淡化角度与 RPM 插值一致，
##    层音高全程在 [0.01, 3]，且高转音高于低转；
## 3. 负载：满油门只有加速库出声，松油门减速库反超；
## 4. 滞回：跨层边界 ±120rpm 内的小幅摆动不换层，越过后才换；
## 5. 事件：换挡触发回火覆盖层+音高回落并按期衰减，油门急开/急收触发一次性采样
##    且冷却生效，收油回火与红线断油在固定种子下必然触发；
## 6. 熄火：turn_off 后层音量衰减到静音。
## 断言放在首帧 _process：-s 模式 _init 阶段 add_child 的 _ready 延迟到第一帧。

const _DT := 1.0 / 120.0
const _TOL := 0.02

var _comp: EngineAudioVNS
var _v: Vehicle
var _fails := 0

func _init() -> void:
	_v = load("res://addons/gevp/scenes/arcade_car.tscn").instantiate()
	_v.freeze = true
	root.add_child(_v)
	_comp = EngineAudioVNS.new()
	root.add_child(_comp)

func _process(_delta: float) -> bool:
	_check_setup()
	_check_sweep()
	_check_load_blend()
	_check_hysteresis()
	_check_events()
	_check_off()
	print("[ENGINEAUDIO] %s (fails=%d)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
	return true

func _expect(cond: bool, label: String, detail := "") -> void:
	if not cond:
		_fails += 1
		print("[ENGINEAUDIO] FAIL %s %s" % [label, detail])

## 模拟运行 seconds 秒（120Hz 物理拍）
func _run(rpm: float, load: float, seconds: float) -> void:
	var steps := int(round(seconds / _DT))
	for i in steps:
		_comp.tick(rpm, load, _DT)

func _check_setup() -> void:
	var ok := _comp.setup(_v)
	_comp.set_physics_process(false)   # 测试手动驱动 tick，避免物理帧并发干扰
	_comp.seed_rng(20260817)
	var bus_name: String = _comp._acc_layers[0]["player"].bus
	var wav := _comp.acc_clips[0] as AudioStreamWAV
	_expect(ok, "装配成功")
	_expect(_comp.acc_clips.size() == 7 and _comp.dec_clips.size() == 7, "采样库 7+7",
			"acc=%d dec=%d" % [_comp.acc_clips.size(), _comp.dec_clips.size()])
	_expect(bus_name.begins_with("VNSEngine_")
			and AudioServer.get_bus_index(bus_name) >= 0, "专属总线", bus_name)
	_expect(wav != null and wav.loop_mode == AudioStreamWAV.LOOP_FORWARD and wav.loop_end > 0,
			"循环点写入", "mode=%s end=%d" % [wav.loop_mode, wav.loop_end if wav else -1])
	_expect(is_equal_approx(_comp._max_rpm, 8500.0), "max_rpm 取分层上限", str(_comp._max_rpm))

func _check_sweep() -> void:
	var pitch_min := INF
	var pitch_max := -INF
	var steps := int(3.0 / _DT)
	for i in steps:
		var rpm := lerpf(1000.0, 8500.0, float(i) / float(steps - 1))
		_comp.tick(rpm, 1.0, _DT)
		for a in _comp.debug_info()["acc_active"]:
			pitch_min = minf(pitch_min, a["pitch"])
			pitch_max = maxf(pitch_max, a["pitch"])
	_expect(pitch_min >= 0.01 and pitch_max <= 3.0, "层音高在 [0.01,3]",
			"min=%.3f max=%.3f" % [pitch_min, pitch_max])
	_expect(pitch_max > pitch_min, "音高随转速上扬", "min=%.3f max=%.3f" % [pitch_min, pitch_max])
	# 稳定点检查：切换后的旧层已按响应时间衰减完，应恰好只剩相邻两层，
	# 且恒功率交叉淡化角 atan2(g_hi,g_lo) 等于 RPM 在两参考层间的插值角
	for rpm in [2750.0, 5250.0, 7750.0]:
		_run(rpm, 1.0, 0.5)   # 0.5s 让大转速跳变穿越过的旧层彻底衰减
		var info := _comp.debug_info()
		var active: Array = info["acc_active"]
		_expect(active.size() == 2, "稳定后恰好相邻两层 @%d" % rpm,
				"active=%s pair=%s" % [str(active.map(func(a): return a["ref"])), str(info["acc_pair"])])
		if active.size() == 2 and rpm < 7000.0:
			# 恒功率角度仅在增益未触顶时成立；高转低层会被 max_volume_acc 钳制（VNS 同款语义）
			var t := clampf((info["rpm"] - active[0]["ref"]) / (active[1]["ref"] - active[0]["ref"]), 0.0, 1.0)
			var angle := atan2(active[1]["vol"], active[0]["vol"])
			_expect(absf(angle - t * PI * 0.5) < 0.15, "交叉淡化角度随 RPM 插值 @%d" % rpm,
					"angle=%.3f expect=%.3f" % [angle, t * PI * 0.5])
		if rpm >= 7000.0:
			_expect(active[0]["vol"] <= _comp.max_volume_acc + 0.005, "高转层音量被库上限钳制 @%d" % rpm,
					"vol=%.3f cap=%.3f" % [active[0]["vol"], _comp.max_volume_acc])

func _check_load_blend() -> void:
	_run(5000.0, 1.0, 1.0)
	var full := _comp.debug_info()
	_run(5000.0, 0.0, 1.0)
	var coast := _comp.debug_info()
	var acc_full := _sum_vol(full, "acc_active")
	var dec_full := _sum_vol(full, "dec_active")
	var acc_coast := _sum_vol(coast, "acc_active")
	var dec_coast := _sum_vol(coast, "dec_active")
	_expect(acc_full > 0.05 and dec_full < _TOL, "满油门走加速库", "acc=%.3f dec=%.3f" % [acc_full, dec_full])
	_expect(dec_coast > 0.02 and acc_coast < dec_coast, "松油门减速库反超", "acc=%.3f dec=%.3f" % [acc_coast, dec_coast])

func _check_hysteresis() -> void:
	_run(4600.0, 1.0, 0.5)
	var before: Array = _comp.debug_info()["acc_pair"]
	# 4600↔4410：跨越 4500 层边界但未越 120rpm 滞回带，邻对保持不变
	for i in 6:
		_run(4410.0 if i % 2 == 0 else 4600.0, 1.0, 0.04)
	var during: Array = _comp.debug_info()["acc_pair"]
	_expect(before == during, "滞回带内不换层", "%s -> %s" % [str(before), str(during)])
	_run(4300.0, 1.0, 0.2)
	var after: Array = _comp.debug_info()["acc_pair"]
	_expect(after != before and after[0] < before[0], "越滞回带后换层", "%s -> %s" % [str(before), str(after)])

func _check_events() -> void:
	_run(6000.0, 0.8, 0.5)
	var base_shift: int = _comp.debug_info()["diag"]["shift"]
	var pre_vol := _sum_vol(_comp.debug_info(), "acc_active")
	_comp.on_gear_shift()
	var shifted := _comp.debug_info()
	_expect(shifted["diag"]["shift"] == base_shift + 1, "换挡计数")
	_expect(shifted["shift_fade"] != 0, "换挡回火覆盖层启动", "fade=%s" % shifted["shift_fade"])
	_expect(absf(shifted["pitch_osc"] - _comp.shift_pitch_dip) < 0.001, "换挡音高回落", str(shifted["pitch_osc"]))
	_run(6000.0, 0.8, 0.06)
	var ducked := _sum_vol(_comp.debug_info(), "acc_active")
	_expect(ducked < pre_vol * 0.8, "换挡 duck 压低引擎层", "pre=%.3f ducked=%.3f" % [pre_vol, ducked])
	_expect(db_to_linear(_comp._shift_player.volume_db - _comp.output_gain_db) > 0.3,
			"覆盖层音量到达目标", "vol=%.3f" % db_to_linear(_comp._shift_player.volume_db - _comp.output_gain_db))
	_run(6000.0, 0.8, 0.8)
	_expect(absf(_comp.debug_info()["pitch_osc"]) < 0.001, "换挡音高回落衰减归零")
	_expect(_sum_vol(_comp.debug_info(), "acc_active") > pre_vol * 0.9, "duck 释放引擎层恢复")

	var base_roar: int = _comp.debug_info()["diag"]["roar"]
	_comp.on_throttle_tip_in(1.0, 4000.0, 0.8)
	_expect(_comp.debug_info()["diag"]["roar"] == base_roar + 1, "油门急开触发进气吼")
	var base_flutter: int = _comp.debug_info()["diag"]["flutter"]
	_comp.on_throttle_tip_out(4000.0, 0.2)
	_expect(_comp.debug_info()["diag"]["flutter"] == base_flutter, "冷却期内泄气被节流")
	_run(5000.0, 0.5, 0.2)
	_comp.on_throttle_tip_out(5000.0, 0.3)
	_expect(_comp.debug_info()["diag"]["flutter"] == base_flutter + 1, "冷却期后泄气触发")

	var base_burble: int = _comp.debug_info()["diag"]["burble"]
	_run(6000.0, 0.1, 1.5)   # 负载 0.1 落在回火窗口 [0, 0.3)，转速 ≥ 3500
	_expect(_comp.debug_info()["diag"]["burble"] > base_burble, "收油回火触发",
			str(_comp.debug_info()["diag"]["burble"]))

	_run(8500.0, 1.0, 0.6)   # 转速顶到分层上限 ≥ redline_min
	_expect(_comp.debug_info()["diag"]["redline"] > 0, "红线断油触发",
			str(_comp.debug_info()["diag"]["redline"]))

func _check_off() -> void:
	_comp.turn_off()
	_run(5000.0, 1.0, 1.0)
	var info := _comp.debug_info()
	_expect(_sum_vol(info, "acc_active") < _TOL and _sum_vol(info, "dec_active") < _TOL, "熄火后静音")

func _sum_vol(info: Dictionary, key: String) -> float:
	var total := 0.0
	for a in info[key]:
		total += a["vol"]
	return total
