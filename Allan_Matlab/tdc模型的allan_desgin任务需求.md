# ClaudeAgent 任务 Prompt：理论 TDC 测量链路 Allan VI 验证脚本优化

## 任务目标

基于现有 MATLAB 脚本 `simulate_tdc_measurement_chain.m` 优化理论 TDC 测量链路仿真。

该脚本用于生成带测量误差的时间误差序列，并验证 LabVIEW Allan VI 的 Allan 方差计算、曲线显示和数据存储流程。

注意：该 TDC 链路是高分辨率理论模型，不代表真实下位机硬件实现，也不得在报告中描述为真实实测 TDC 数据。

## 输入对象

- 输入信号对象：10 MHz OCXO 标准数字方波
- 输入数据文件：`ocxo_sim_time_error.csv`
- 输入字段要求：
  - `sample_index`
  - `time_s`
  - `time_error_s`

## 基础采样定义

- 基础采样间隔：`tau0 = 10 ms`
- 含义：每隔 10 ms 输出一个时间误差样本 `x[k]`
- 输出样本用于：
  - Allan 方差计算
  - Allan 曲线显示
  - LabVIEW Allan VI 数据存储验证
  - 理论测量链路合理性对比

## TDC 目标指标

默认推荐参数：

```text
TDC LSB              = 10 ps
TDC jitter RMS       = 5 ps
TDC total error RMS  ≈ 5.77 ps
```

误差模型：

```text
x_meas = x_true + uniform(-LSB/2, +LSB/2) + N(0, sigma_jitter)
```

总时间误差 RMS 理论校验：

```text
sigma_total = sqrt(LSB^2 / 12 + sigma_jitter^2)
            = sqrt(10^2 / 12 + 5^2) ps
            ≈ 5.77 ps
```

## 设计定位

- 推荐链路目标：`sigma_total <= 6 ps`，当前 `10 ps / 5 ps` 参数组合必须满足。
- 激进目标：`sigma_total <= 3 ps`，不由当前默认参数支撑，只作为更高性能理论链路扩展目标。
- 极限理想目标：`sigma_total <= 1.5 ps`，不由当前默认参数支撑，只作为极限理论链路扩展目标。
- 当前重点：优先服务 MATLAB / LabVIEW Allan VI 前仿真，不考虑下位机 FPGA/TDC 真实实现约束。

## 需要修改的 MATLAB 脚本

文件：

```text
simulate_tdc_measurement_chain.m
```

必须完成：

1. 将默认 TDC 参数改为：

```matlab
cfg.tdc_lsb_s        = 10e-12;
cfg.tdc_jitter_rms_s = 5e-12;
```

2. 保留现有三类测量链路对比：

```text
50 MHz coarse timestamp
200 MHz coarse timestamp
TDC high-resolution theoretical chain
```

3. 保留现有 TDC 误差模型：

```matlab
quant_error_tdc = (rand(N, 1) - 0.5) * cfg.tdc_lsb_s;
jitter_tdc      = cfg.tdc_jitter_rms_s * randn(N, 1);
x_tdc_meas      = x_true + quant_error_tdc + jitter_tdc;
```

4. 在终端摘要和报告文件中明确输出：

```text
TDC LSB
TDC jitter RMS
TDC theoretical total RMS
TDC measured error RMS
推荐链路目标 sigma_total <= 6 ps 是否满足
```

5. 报告中必须明确写入：

```text
This is a THEORETICAL TDC measurement chain for MATLAB/LabVIEW Allan VI validation.
It is NOT real TDC hardware measurement data.
```

6. 更新旧结论，避免继续出现：

```text
TDC RMS ~60 ps
TDC resolution ~100 ps
```

应改为基于当前参数自动输出，或明确写成：

```text
TDC resolution = 10 ps
TDC total RMS ≈ 5.77 ps
```

## 输出文件要求

保持现有输出文件结构：

```text
tdc_chain_sim_output/measurement_chain_compare_allan.csv
tdc_chain_sim_output/measurement_chain_error_stats.csv
tdc_chain_sim_output/ocxo_sim_time_error_tdc_measured.csv
tdc_chain_sim_output/measurement_error_compare.png
tdc_chain_sim_output/allan_compare_measurement_chain.png
tdc_chain_sim_output/time_error_tdc_vs_ideal.png
tdc_chain_sim_output/tdc_chain_sim_report.txt
```

## 验收标准

运行脚本后应满足：

```text
TDC LSB                  = 10 ps
TDC jitter RMS           = 5 ps
TDC theoretical RMS      ≈ 5.77 ps
TDC measured error RMS   接近 5.77 ps
推荐目标 <= 6 ps          PASS
```

Allan 曲线要求：

- `tau = 0.01 s` 附近，TDC Allan 噪声底应明显低于旧 `100 ps / 50 ps` 模型。
- `tau >= 0.1 s` 后，TDC Allan 曲线应更接近 ideal Allan 曲线。
- 50 MHz 与 200 MHz 粗时间戳链路继续作为反例对照。

## 交付要求

请直接修改 `simulate_tdc_measurement_chain.m`，不要新建替代脚本。

修改完成后运行脚本，检查：

- MATLAB 无报错
- CSV 正常输出
- PNG 正常输出
- `tdc_chain_sim_report.txt` 中参数、RMS 和声明均正确
- 终端摘要中的 TDC RMS 约为 `5.77 ps`
