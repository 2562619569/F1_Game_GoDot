# 引擎声采样库（占位）

`game/car/engine_audio_vns.gd`（VNS 移植组件）的默认音色，程序合成、无版权负担。

## 结构

- `acc_XXXX.wav` / `dec_XXXX.wav`：加速/减速库分层，文件名中的数字为录音参考转速，
  整段无缝循环（循环点由组件装配时写入，不依赖 import 设置）
- `shift_burble.wav`：换挡回火覆盖层（循环）
- `burble_N.wav` / `roar_N.wav` / `flutter_N.wav` / `redline_N.wav`：一次性事件音效
- `bank.json`：装配清单（分层文件 + 参考转速 + 事件音效列表）

## 再生成 / 换真实录音

```bash
python tools/audio_gen/make_engine_loops.py   # 幂等，已存在的 wav 不覆盖
```

换真实录音：按参考转速录制循环采样（无缝循环处理参见 VNS 原项目 README 的
Audacity 教程），替换同名文件或改 `bank.json` 后删旧 wav 重跑导入即可，组件代码不动。
新车种可整目录复制（如 `assets/audio/engine/v8/`），装配时传目录参数。
