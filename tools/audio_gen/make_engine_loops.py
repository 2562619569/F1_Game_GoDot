# -*- coding: utf-8 -*-
"""生成引擎声分层采样占位资产（幂等，可重复执行）。

为 VNS 移植组件（game/car/engine_audio_vns.gd）生成整套占位音色：
  - 加速库 acc_XXXX.wav / 减速库 dec_XXXX.wav：按参考转速分层、整段无缝循环
  - 一次性音效：回火 burble_N / 换挡回火 shift_burble（循环，爆音从 0ms 起）/ 进气吼 roar_N /
    油门泄气 flutter_N / 红线断油 redline_N
  - bank.json：分层清单（文件名 + 参考转速 + 事件音效列表），组件按清单装配

合成模型（比谐波堆叠更像引擎的物理近似）：
  点火脉冲串（带 ±0.4% 点火抖动 + 分缸幅度不均）激励一组固定共振峰
  （排气主管/歧管/机械高频，即与转速无关的形态音色），叠加连续点火基频
  与低通风噪。各层共振频率随机 ±6% 去相关，避免交叉淡化时两层拍频。
  循环无缝：脉冲按环形缓冲写入（尾部绕回开头），噪声用超采样交叉淡化。
后续可换真实录音：保持文件名与 bank.json 结构即可，无需改组件代码。
用法:  python tools/audio_gen/make_engine_loops.py [--out assets/audio/engine/default]
"""
import argparse
import json
import math
import os
import random
import struct
import wave

SR = 44100
CYL = 4            # 四缸四冲程：每曲轴转 2 次点火
RPM_GRID = [1000, 2000, 3000, 4500, 6000, 7500, 8500]
LOOP_SECONDS = 1.4
XFADE = 2048       # 噪声段首尾等功率交叠长度（采样点），保证循环无缝

# 共振峰：f=频率 q=共振强度 g=增益 win=衰减窗长（秒）。各层随机微调去相关。
RESONANCES = [
    {"f": 150.0, "q": 5.0, "g": 0.85, "win": 0.10},   # 排气主管
    {"f": 430.0, "q": 7.0, "g": 0.45, "win": 0.06},   # 排气歧管
    {"f": 980.0, "q": 9.0, "g": 0.28, "win": 0.045},  # 机械高频
]
ACC_BRIGHT = {"f": 2000.0, "q": 11.0, "g": 0.20, "win": 0.035}  # 高转嘶亮（仅加速库）

rng = random.Random(20260817)


def _soft_clip(x):
    return math.tanh(x * 1.2) / math.tanh(1.2)


def _write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))


def _emit(out_dir, name, samples, force):
    """占位音效幂等写出：已有文件（可能是真实录音）不覆盖。"""
    path = os.path.join(out_dir, name)
    if force or not os.path.exists(path):
        _write_wav(path, samples)


def _lp_noise(n, cutoff):
    """低通白噪声。多生成 XFADE 个尾样本，把「循环结束后」的素材等功率混入
    开头：final[0] == out[n]，与 final[n-1] == out[n-1] 天然连续，接缝零跳变。"""
    total = n + XFADE
    alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff / SR)
    out = [0.0] * total
    y = 0.0
    for i in range(total):
        y += alpha * (rng.uniform(-1.0, 1.0) - y)
        out[i] = y
    head = out[:XFADE]
    for i in range(XFADE):
        t = (i + 0.5) / XFADE
        w = 0.5 * (1.0 - math.cos(math.pi * t))          # 0→1 等功率窗
        out[i] = head[i] * w + out[n + i] * math.sqrt(1.0 - w * w)
    return out[:n]


def _add_kernel(buf, s0, g, ker):
    """把核环形写入缓冲（尾部绕回开头，保证循环无缝）。"""
    T = len(buf)
    L = len(ker)
    end = s0 + L
    if end <= T:
        buf[s0:end] = [a + g * b for a, b in zip(buf[s0:end], ker)]
    else:
        n1 = T - s0
        buf[s0:] = [a + g * b for a, b in zip(buf[s0:], ker[:n1])]
        n2 = end - T
        buf[:n2] = [a + g * b for a, b in zip(buf[:n2], ker[n1:])]


def _kernel(freq, q, win, phase):
    """衰减正弦核：点火脉冲激励共振峰的时域响应。"""
    n = int(win * SR)
    tau = q / (math.pi * freq)          # 包络时间常数
    decay = math.exp(-1.0 / (SR * tau))
    e = 1.0
    out = [0.0] * n
    w = 2.0 * math.pi * freq / SR
    for i in range(n):
        out[i] = e * math.sin(w * i + phase)
        e *= decay
    return out


def _engine_loop(rpm, dec):
    """单个转速层的无缝循环。"""
    f_fire = rpm / 60.0 * CYL / 2.0
    n_events = max(8, int(round(LOOP_SECONDS * f_fire)))
    if n_events % 2:
        n_events += 1                   # 保证 f_fire/2 半频分量也是整周期
    T = int(round(n_events / f_fire * SR))
    brightness = (rpm - RPM_GRID[0]) / float(RPM_GRID[-1] - RPM_GRID[0])

    res = []
    for r in RESONANCES:
        res.append({**r, "ker": _kernel(r["f"] * rng.uniform(0.94, 1.06),
                                        r["q"], r["win"], 0.0)})
    if not dec and brightness > 0.3:
        r = ACC_BRIGHT
        res.append({**r, "ker": _kernel(r["f"] * rng.uniform(0.94, 1.06),
                                        r["q"], r["win"], 0.0),
                    "g": r["g"] * brightness})

    buf = [0.0] * T
    for k in range(n_events):
        # 点火抖动 ±0.4% + 分缸幅度不均（偶数缸偏弱）= 引擎的粗糙感
        t_k = k / f_fire * (1.0 + rng.uniform(-0.004, 0.004))
        amp = 1.0 + rng.uniform(-0.15, 0.15)
        if k % 2 == 0:
            amp *= 0.82
        s0 = int(t_k * SR) % T
        for r in res:
            g = r["g"] * amp
            if dec and r["f"] > 300.0:
                g *= 0.35               # 减速库高共振峰收暗
            _add_kernel(buf, s0, g, r["ker"])

    # 连续点火基频 + 少量 2/3 次谐波（低转咬劲），整周期 → 循环无缝
    ph1 = rng.uniform(0.0, 2.0 * math.pi)
    ph2 = rng.uniform(0.0, 2.0 * math.pi)
    ph3 = rng.uniform(0.0, 2.0 * math.pi)
    sub_gain = 0.30 if dec else 0.22
    for i in range(T):
        t = i / float(SR)
        buf[i] += sub_gain * math.sin(2.0 * math.pi * f_fire * t + ph1) \
                + 0.6 * sub_gain * math.sin(4.0 * math.pi * f_fire * t + ph2) \
                + 0.35 * sub_gain * math.sin(6.0 * math.pi * f_fire * t + ph3) \
                + 0.35 * sub_gain * math.sin(math.pi * f_fire * t + ph2)

    # 进气/排气风噪
    noise_amt = (0.08 + 0.28 * brightness) * (0.45 if dec else 1.0)
    noise = _lp_noise(T, 300.0 + 2600.0 * brightness)
    for i in range(T):
        buf[i] += noise[i] * noise_amt * 3.0

    # 慢速颤动（整周期正弦，保持循环连续）
    for i in range(T):
        t = i / float(T)
        buf[i] *= 1.0 + 0.05 * math.sin(2.0 * math.pi * 3.0 * t) \
                       + 0.04 * math.sin(2.0 * math.pi * 7.0 * t + 1.3)

    rms = math.sqrt(sum(v * v for v in buf) / T)
    gain = (0.20 if dec else 0.27) / max(rms, 1e-9)
    return [_soft_clip(v * gain) for v in buf]


def _pop(knock_hz, thump=False):
    """单个回火/换挡爆音：低频闷响 + 短促敲击 + 噪声tick。"""
    n = int(SR * (0.06 if thump else 0.035))
    out = [0.0] * n
    y = 0.0
    for i in range(n):
        t = i / float(SR)
        if thump:
            out[i] = 0.85 * math.sin(2.0 * math.pi * knock_hz * t) * math.exp(-t * 40.0)
        else:
            out[i] = 0.5 * math.sin(2.0 * math.pi * knock_hz * t) * math.exp(-t * 90.0)
        y += 0.25 * (rng.uniform(-1.0, 1.0) - y)
        out[i] += y * math.exp(-t * 140.0) * (2.5 if thump else 1.5)
    return out


def _make_one_shots(out_dir, force=False):
    files = {"burble": [], "roar": [], "flutter": [], "redline": []}
    for idx in range(3):
        # 收油回火：3~6 个爆音，幅度递减 + 噪底
        buf = []
        pops = rng.randint(3, 6)
        for j in range(pops):
            p = _pop(rng.uniform(70.0, 130.0), thump=(j % 2 == 0))
            buf += [v * (1.0 - 0.12 * j) for v in p]
            buf += [0.0] * int(SR * rng.uniform(0.02, 0.05))
        name = "burble_%d.wav" % idx
        _emit(out_dir, name, [_soft_clip(v) for v in buf], force)
        files["burble"].append(name)
    for idx in range(2):
        # 进气吼：噪声涌起 + 上扫音调，快攻击慢衰减
        n = int(SR * 0.35)
        buf = [0.0] * n
        f_sw = rng.uniform(100.0, 160.0)
        y = 0.0
        for i in range(n):
            t = i / float(SR)
            env = min(1.0, t / 0.03) * math.exp(-t * 7.0)
            sweep = f_sw * (1.0 + 0.7 * t / 0.35)
            y += 0.10 * (rng.uniform(-1.0, 1.0) - y)
            s = 0.35 * math.sin(2.0 * math.pi * sweep * t) + 0.2 * math.sin(4.0 * math.pi * sweep * t)
            buf[i] = _soft_clip(env * (s + y * 3.5))
        name = "roar_%d.wav" % idx
        _emit(out_dir, name, buf, force)
        files["roar"].append(name)
    for idx in range(2):
        # 油门泄气：30Hz 斩波噪声嘶声
        n = int(SR * 0.22)
        buf = [0.0] * n
        y = 0.0
        for i in range(n):
            t = i / float(SR)
            chop = 0.5 + 0.5 * math.sin(2.0 * math.pi * 30.0 * t)
            y += 0.12 * (rng.uniform(-1.0, 1.0) - y)
            env = min(1.0, t / 0.02) * math.exp(-t * 14.0)
            buf[i] = _soft_clip(y * 5.0 * chop * env)
        name = "flutter_%d.wav" % idx
        _emit(out_dir, name, buf, force)
        files["flutter"].append(name)
    for idx in range(2):
        # 红线断油：16Hz 断续 + 噪声
        n = int(SR * 0.3)
        buf = [0.0] * n
        for i in range(n):
            t = i / float(SR)
            chop = 1.0 if math.sin(2.0 * math.pi * 16.0 * t) > 0 else 0.12
            s = 0.3 * math.sin(2.0 * math.pi * 220.0 * t) + 0.2 * math.sin(2.0 * math.pi * 440.0 * t)
            buf[i] = _soft_clip(chop * (s + rng.uniform(-1, 1) * 0.3) * 0.9)
        name = "redline_%d.wav" % idx
        _emit(out_dir, name, buf, force)
        files["redline"].append(name)
    # 换挡回火覆盖层：0.5s 循环，爆音从 0ms 起每 22~34ms 一个（保证任何截取窗口都有爆音）
    T = int(SR * 0.5)
    buf = [0.0] * T
    cursor = 0
    while cursor < T:
        p = _pop(rng.uniform(75.0, 115.0), thump=True)
        _add_kernel(buf, cursor % T, 1.0, p)
        cursor += int(SR * rng.uniform(0.022, 0.034))
    peak = max(abs(v) for v in buf)
    buf = [v * (0.88 / peak) for v in buf]
    name = "shift_burble.wav"
    _emit(out_dir, name, buf, force)
    files["shift_burble"] = name
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("assets", "audio", "engine", "default"))
    ap.add_argument("--force", action="store_true", help="覆盖已有 wav（默认幂等保留，换真实录音后不被覆盖）")
    args = ap.parse_args()
    out_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", args.out))
    os.makedirs(out_dir, exist_ok=True)

    bank = {"sample_rate": SR, "cylinders": CYL, "idle_rpm": RPM_GRID[0], "max_rpm": RPM_GRID[-1],
            "acc": [], "dec": [], "generator": "make_engine_loops.py"}
    for tag, dec in (("acc", False), ("dec", True)):
        for rpm in RPM_GRID:
            name = "%s_%04d.wav" % (tag, rpm)
            path = os.path.join(out_dir, name)
            if args.force or not os.path.exists(path):
                _write_wav(path, _engine_loop(rpm, dec))
            bank[tag].append({"file": name, "rpm": rpm})
    bank.update(_make_one_shots(out_dir, args.force))

    with open(os.path.join(out_dir, "bank.json"), "w", encoding="utf-8") as f:
        json.dump(bank, f, ensure_ascii=False, indent=2)
    print("engine loops -> %s (%d acc / %d dec layers)" %
          (out_dir, len(bank["acc"]), len(bank["dec"])))


if __name__ == "__main__":
    main()
