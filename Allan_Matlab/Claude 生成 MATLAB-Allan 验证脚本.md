

【任务目标】
基于已有 CSV 输入源 `ocxo_sim_time_error.csv`，编写一份 MATLAB 验证脚本，用于验证这份“基于 OCXO datasheet 约束的仿真 time_error_s 数据”能否作为 MATLAB / LabVIEW 前仿真中的 Allan 偏差计算核心输入源。

注意：本任务不是生成真实 OCXO 实测数据，也不是重新生成仿真 CSV。本任务只做：
1. 读取已有 CSV；
2. 校验 CSV 数据质量；
3. 从 time_s 自动识别采样间隔 tau0；
4. 基于 time_error_s 计算 overlapping Allan deviation；
5. 输出 tau 数组、adev 数组；
6. 生成必要的验证图和验证报告；
7. 给出该 CSV 是否适合作为 LabVIEW/MATLAB Allan 核心输入源的结论。

【输入文件】
CSV 文件名：
`ocxo_sim_time_error.csv`

CSV 字段格式应为：
sample_index,time_s,time_error_s

字段含义：
- sample_index：样本编号；
- time_s：采样时刻，单位 s；
- time_error_s：时间误差 / 相位时间偏差 x(t)，单位 s。

【数据身份边界】
该 CSV 是 theoretical_simulation / synthetic time-error data。
它不是 real OCXO measurement。
脚本、注释、报告中必须明确：
- data_type = theoretical_simulation
- is_real_measurement = false
- purpose = Allan algorithm and LabVIEW host-software validation
不得写成真实 OCXO 实测数据。

【必须实现的脚本功能】
请新建 MATLAB 脚本：
`verify_ocxo_csv_allan.m`

脚本必须包含以下模块：

1. 配置区
   - csv_file = "ocxo_sim_time_error.csv"
   - output_dir = "allan_verify_output"
   - 是否去趋势 detrend_enable，可配置；
   - 最大 tau 限制，例如 max_tau_ratio = 10，表示最大可信 tau 不超过总时长 / 10；
   - m 值生成方式：对数间隔，避免 m 过密导致计算过慢。

2. CSV 读取与字段检查
   必须检查：
   - 文件是否存在；
   - 是否包含 sample_index、time_s、time_error_s 三列；
   - 是否存在 NaN / Inf / 空值；
   - sample_index 是否连续或至少单调；
   - time_s 是否单调递增；
   - time_s 间隔是否基本稳定；
   - time_error_s 是否为数值列，单位按秒处理。

3. tau0 自动检测
   - 使用 median(diff(time_s)) 自动识别 tau0；
   - 输出 tau0；
   - 输出采样频率 fs = 1/tau0；
   - 输出总时长 T_total；
   - 输出样本数 N；
   - 不允许硬编码 tau0 = 100 ns 或 10 ms，必须从 CSV 自动识别。

4. time_error_s 数据统计
   输出：
   - min / max / mean / std；
   - 峰峰值；
   - 首尾值；
   - 是否存在明显异常跳变；
   - 可选：用 diff(time_error_s) 检查异常尖峰。

5. overlapping Allan deviation 计算
   使用相位时间误差 x(t) 形式的 overlapping Allan deviation：

   对于 m：
   tau = m * tau0

   d2 = x(i + 2m) - 2*x(i + m) + x(i)

   sigma_y(tau) = sqrt( sum(d2.^2) / (2 * tau^2 * M) )

   其中 M = N - 2m。

   注意：
   - x 使用 time_error_s；
   - tau 单位为 s；
   - adev 为无量纲分数频率稳定度；
   - m 必须满足 2m < N；
   - 最大 tau 建议不超过 T_total / 10。

6. 输出结果文件
   在 `allan_verify_output` 文件夹中输出：
   - `allan_result.csv`，至少包含 tau_s, m, adev, sample_count_used；
   - `csv_quality_report.txt`，记录输入检查结果、tau0、N、T_total、异常情况；
   - `allan_verify_summary.txt`，给出最终判断：该 CSV 是否适合作为 Allan 核心输入源；
   - 图像文件：
     1. `time_error_overview.png`：time_error_s 随 time_s 的曲线；
     2. `allan_deviation.png`：loglog(tau, adev)；
     3. 可选：`time_interval_check.png`：diff(time_s) 检查图。

7. 图像要求
   - time_error 图的纵轴可自动换算为 ns 显示，但计算必须使用秒；
   - Allan 图横轴 tau / s，纵轴 Allan deviation；
   - Allan 图使用 loglog；
   - 标题中注明 theoretical simulation，不是真实测量。

8. 结果解释
   脚本运行末尾需要在命令行打印：
   - CSV 是否通过质量检查；
   - tau0；
   - N；
   - T_total；
   - 最大可信 tau；
   - Allan 结果点数；
   - 是否适合作为 MATLAB/LabVIEW 前仿真 Allan 输入源；
   - 明确声明不是真实 OCXO 实测结果。

【禁止事项】
禁止：
1. 不要重新生成 ocxo_sim_time_error.csv；
2. 不要声称数据是真实 OCXO 实测数据；
3. 不要把任务扩展到真实硬件采集链路；
4. 不要修改无关文件；
5. 不要把 tau0 写死；
6. 不要只画图不输出 tau/adev 数组；
7. 不要只给解释不给完整 MATLAB 脚本。

【交付物】
请最终交付：
1. 完整 `verify_ocxo_csv_allan.m` 脚本；
2. 说明如何运行；
3. 说明运行后应该生成哪些文件；
4. 说明如何判断脚本成功；
5. 如果你发现当前 CSV 不适合作为 Allan 输入源，请明确指出失败原因和最小修改建议。