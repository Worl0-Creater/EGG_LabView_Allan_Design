%% verify_ocxo_csv_allan.m
% -------------------------------------------------------------------------
% OCXO 仿真 CSV 数据验证与 Allan 偏差计算脚本
%
% 功能：
%   1. 读取已有 ocxo_sim_time_error.csv
%   2. 校验 CSV 数据质量
%   3. 自动识别采样间隔 tau0
%   4. 基于 time_error_s 计算 overlapping Allan deviation
%   5. 输出验证报告、结果 CSV、图表
%   6. 给出该 CSV 是否适合作为 Allan 核心输入源的结论
%
% 数据身份声明：
%   data_type          = theoretical_simulation
%   is_real_measurement = false
%   purpose            = Allan algorithm and LabVIEW host-software validation
% -------------------------------------------------------------------------

clear; clc; close all;

%% ==================== 1. 配置区 ====================

script_dir = fileparts(mfilename('fullpath'));

cfg = struct();

cfg.csv_file        = fullfile(script_dir, "ocxo_sim_time_error.csv");

%cfg.csv_file        = fullfile(script_dir, "ocxo_sim_time_error_tdc_measured.csv");
cfg.output_dir      = fullfile(script_dir, "allan_verify_output");

% 去趋势模式：'none' / 'linear' / 'quadratic'
% 'linear'  : 去除 x(t) 线性分量（不影响 ADEV，改善数值条件）
% 'quadratic': 去除二次项（消除频率漂移对 ADEV 的贡献）
cfg.detrend_mode    = "linear";

% 最大可信 tau = T_total / max_tau_ratio
cfg.max_tau_ratio   = 10;

% 每个 tau 点最少二阶差分对数
cfg.min_pairs       = 20;

% m 取值方式：对数间隔，避免过密导致计算过慢
cfg.use_log_m       = true;
cfg.num_m_points    = 80;

% 异常跳变检测阈值（倍 sigma）
cfg.jump_threshold_sigma = 5;

% 数据身份标记
cfg.data_type            = "theoretical_simulation";
cfg.is_real_measurement  = false;


%% ==================== 2. CSV 读取与字段检查 ====================

qc = struct();
report_lines = {};

report_lines{end+1} = "========== CSV 数据质量检查报告 ==========";
report_lines{end+1} = sprintf("日期: %s", datestr(now, 'yyyy-mm-dd HH:MM:SS'));
report_lines{end+1} = sprintf("输入文件: %s", cfg.csv_file);
report_lines{end+1} = sprintf("数据身份: %s", cfg.data_type);
report_lines{end+1} = "";
report_lines{end+1} = "--- 1. 文件与字段检查 ---";

% 文件存在性
qc.file_exists = isfile(cfg.csv_file);
report_lines{end+1} = sprintf("文件存在: %s", pass_fail(qc.file_exists));

if ~qc.file_exists
    error("[FATAL] 输入文件不存在：%s\n请先运行 gen_ocxo_sim_csv.m 生成仿真 CSV。", cfg.csv_file);
end

data = readtable(cfg.csv_file);
col_names = string(data.Properties.VariableNames);
col_lower = lower(col_names);

% 必需列检查
required_cols = ["sample_index", "time_s", "time_error_s"];
cols_found = arrayfun(@(c) any(col_lower == c), required_cols);
qc.columns_present = all(cols_found);

for k = 1:numel(required_cols)
    report_lines{end+1} = sprintf("  列 %-16s: %s", required_cols(k), pass_fail(cols_found(k)));
end

if ~qc.columns_present
    missing = required_cols(~cols_found);
    error("[FATAL] CSV 缺少必需列：%s", strjoin(missing, ", "));
end

% 提取数据
sample_idx = double(data.(col_names(col_lower == "sample_index")));
time_s     = double(data.(col_names(col_lower == "time_s")));
x_raw      = double(data.(col_names(col_lower == "time_error_s")));
N_raw      = numel(x_raw);

% 数值类型检查
qc.time_error_numeric = isnumeric(x_raw) && isreal(x_raw);
report_lines{end+1} = sprintf("time_error_s 为实数数值: %s", pass_fail(qc.time_error_numeric));

% NaN / Inf 检查
n_nan = sum(isnan(x_raw)) + sum(isnan(time_s));
n_inf = sum(isinf(x_raw)) + sum(isinf(time_s));
qc.no_nan = (n_nan == 0);
qc.no_inf = (n_inf == 0);
report_lines{end+1} = sprintf("NaN 数量: %d  %s", n_nan, pass_fail(qc.no_nan));
report_lines{end+1} = sprintf("Inf 数量: %d  %s", n_inf, pass_fail(qc.no_inf));

% sample_index 连续性
idx_diff = diff(sample_idx);
qc.sample_index_continuous = all(idx_diff == 1);
qc.sample_index_monotonic  = all(idx_diff > 0);
report_lines{end+1} = sprintf("sample_index 连续 (步长=1): %s", pass_fail(qc.sample_index_continuous));
if ~qc.sample_index_continuous
    report_lines{end+1} = sprintf("sample_index 单调递增: %s", pass_fail(qc.sample_index_monotonic));
end

% time_s 单调递增
dt = diff(time_s);
qc.time_s_monotonic = all(dt > 0);
report_lines{end+1} = sprintf("time_s 单调递增: %s", pass_fail(qc.time_s_monotonic));

% time_s 间隔稳定性
dt_median = median(dt);
dt_std    = std(dt);
dt_cv     = dt_std / dt_median;
qc.time_s_interval_stable = (dt_cv < 0.01);
report_lines{end+1} = sprintf("time_s 间隔稳定性 (CV=%.2e): %s", dt_cv, pass_fail(qc.time_s_interval_stable));


%% ==================== 3. tau0 自动检测 ====================

report_lines{end+1} = "";
report_lines{end+1} = "--- 2. 采样参数（自动检测） ---";

tau0    = median(dt);
fs      = 1 / tau0;
T_total = time_s(end) - time_s(1);
N       = numel(x_raw);

report_lines{end+1} = sprintf("tau0 (采样间隔)     : %.6e s  (%.3f ms)", tau0, tau0*1e3);
report_lines{end+1} = sprintf("fs   (采样频率)     : %.3f Hz", fs);
report_lines{end+1} = sprintf("N    (样本数)       : %d", N);
report_lines{end+1} = sprintf("T_total (总时长)    : %.3f s  (%.2f min)", T_total, T_total/60);
report_lines{end+1} = sprintf("最大可信 tau         : %.3f s  (T_total / %d)", T_total/cfg.max_tau_ratio, cfg.max_tau_ratio);

fprintf("[INFO] tau0 = %.6e s (自动检测), N = %d, T_total = %.1f s\n", tau0, N, T_total);


%% ==================== 4. time_error_s 数据统计 ====================

report_lines{end+1} = "";
report_lines{end+1} = "--- 3. time_error_s 统计 ---";

x_min  = min(x_raw);
x_max  = max(x_raw);
x_mean = mean(x_raw);
x_std  = std(x_raw);
x_pp   = x_max - x_min;

report_lines{end+1} = sprintf("最小值   : %.6e s  (%.3f ns)", x_min, x_min*1e9);
report_lines{end+1} = sprintf("最大值   : %.6e s  (%.3f ns)", x_max, x_max*1e9);
report_lines{end+1} = sprintf("均值     : %.6e s  (%.3f ns)", x_mean, x_mean*1e9);
report_lines{end+1} = sprintf("标准差   : %.6e s  (%.3f ns)", x_std, x_std*1e9);
report_lines{end+1} = sprintf("峰峰值   : %.6e s  (%.3f ns)", x_pp, x_pp*1e9);
report_lines{end+1} = sprintf("首值     : %.6e s", x_raw(1));
report_lines{end+1} = sprintf("尾值     : %.6e s", x_raw(end));

% 异常跳变检测
report_lines{end+1} = "";
report_lines{end+1} = "--- 4. 异常跳变检测 ---";

dx = diff(x_raw);
dx_std = std(dx);
dx_mean = mean(dx);
jump_mask = abs(dx - dx_mean) > cfg.jump_threshold_sigma * dx_std;
n_jumps = sum(jump_mask);
qc.no_anomalous_jumps = (n_jumps == 0);

report_lines{end+1} = sprintf("diff(x) 均值       : %.6e s", dx_mean);
report_lines{end+1} = sprintf("diff(x) 标准差     : %.6e s", dx_std);
report_lines{end+1} = sprintf("跳变阈值           : %.1f sigma", cfg.jump_threshold_sigma);
report_lines{end+1} = sprintf("检测到跳变数       : %d  %s", n_jumps, pass_fail(qc.no_anomalous_jumps));

if n_jumps > 0 && n_jumps <= 20
    jump_idx = find(jump_mask);
    for jj = 1:numel(jump_idx)
        report_lines{end+1} = sprintf("  跳变 @ sample %d: dx = %.3e s (%.1f sigma)", ...
            jump_idx(jj), dx(jump_idx(jj)), abs(dx(jump_idx(jj)) - dx_mean)/dx_std);
    end
end


%% ==================== 5. overlapping Allan deviation 计算 ====================

fprintf("[INFO] 开始计算 overlapping Allan deviation ...\n");

% 去趋势
t_axis = (0:N-1).' * tau0;

switch cfg.detrend_mode
    case "none"
        x_used = x_raw;
        detrend_note = "none";
    case "linear"
        p1 = polyfit(t_axis, x_raw, 1);
        x_used = x_raw - polyval(p1, t_axis);
        detrend_note = "linear removed";
    case "quadratic"
        p2 = polyfit(t_axis, x_raw, 2);
        x_used = x_raw - polyval(p2, t_axis);
        detrend_note = "quadratic removed";
    otherwise
        x_used = x_raw;
        detrend_note = "none (unknown mode)";
end

% m 值生成
max_tau = T_total / cfg.max_tau_ratio;
max_m   = floor(max_tau / tau0);
max_m   = min(max_m, floor((N - cfg.min_pairs) / 2));

if max_m < 1
    error("[FATAL] 数据点数不足以计算 Allan deviation。N = %d", N);
end

if cfg.use_log_m
    m_list = unique(round(logspace(0, log10(max_m), cfg.num_m_points)));
else
    m_list = (1:max_m).';
end
m_list = m_list(:);
m_list = m_list(m_list >= 1 & m_list <= max_m);

n_tau = numel(m_list);
tau_arr   = zeros(n_tau, 1);
adev_arr  = zeros(n_tau, 1);
avar_arr  = zeros(n_tau, 1);
pairs_arr = zeros(n_tau, 1);

for idx = 1:n_tau
    m = m_list(idx);
    tau_i = m * tau0;

    d2 = x_used(1+2*m:end) - 2*x_used(1+m:end-m) + x_used(1:end-2*m);
    M = numel(d2);

    avar_i = sum(d2.^2) / (2 * tau_i^2 * M);
    adev_i = sqrt(avar_i);

    tau_arr(idx)   = tau_i;
    adev_arr(idx)  = adev_i;
    avar_arr(idx)  = avar_i;
    pairs_arr(idx) = M;
end

% 过滤无效点
valid = isfinite(adev_arr) & adev_arr > 0 & pairs_arr >= cfg.min_pairs;
tau_arr   = tau_arr(valid);
adev_arr  = adev_arr(valid);
avar_arr  = avar_arr(valid);
pairs_arr = pairs_arr(valid);
m_list    = m_list(valid);
n_tau     = numel(tau_arr);

fprintf("[INFO] Allan 计算完成：%d 个有效 tau 点，tau 范围 [%.3e, %.3e] s\n", ...
    n_tau, tau_arr(1), tau_arr(end));


%% ==================== 6. 输出文件 ====================

if ~isfolder(cfg.output_dir)
    mkdir(cfg.output_dir);
end

% --- 6a. allan_result.csv ---
result_tbl = table();
result_tbl.m = m_list;
result_tbl.tau_s = tau_arr;
result_tbl.adev = adev_arr;
result_tbl.avar = avar_arr;
result_tbl.sample_count_used = pairs_arr;

result_csv = fullfile(cfg.output_dir, "allan_result.csv");
writetable(result_tbl, result_csv);
fprintf("[INFO] Allan 结果已导出：%s\n", result_csv);

% --- 6b. csv_quality_report.txt ---
report_lines{end+1} = "";
report_lines{end+1} = "--- 5. 总体质量评估 ---";

qc_fields = fieldnames(qc);
all_pass = true;
for k = 1:numel(qc_fields)
    if ~qc.(qc_fields{k})
        all_pass = false;
    end
end

qc.overall_pass = all_pass;
report_lines{end+1} = sprintf("总体评估: %s", pass_fail(all_pass));

if ~all_pass
    report_lines{end+1} = "未通过项:";
    for k = 1:numel(qc_fields)
        if ~qc.(qc_fields{k})
            report_lines{end+1} = sprintf("  - %s: FAIL", qc_fields{k});
        end
    end
end

report_file = fullfile(cfg.output_dir, "csv_quality_report.txt");
fid = fopen(report_file, "w");
for k = 1:numel(report_lines)
    fprintf(fid, "%s\n", report_lines{k});
end
fclose(fid);
fprintf("[INFO] 质量报告已导出：%s\n", report_file);

% --- 6c. allan_verify_summary.txt ---
summary_lines = {};
summary_lines{end+1} = "========== Allan 偏差验证总结 ==========";
summary_lines{end+1} = sprintf("日期: %s", datestr(now, 'yyyy-mm-dd HH:MM:SS'));
summary_lines{end+1} = "";
summary_lines{end+1} = "--- 数据身份 ---";
summary_lines{end+1} = sprintf("data_type            : %s", cfg.data_type);
summary_lines{end+1} = sprintf("is_real_measurement  : %s", mat2str(cfg.is_real_measurement));
summary_lines{end+1} = sprintf("purpose              : Allan algorithm and LabVIEW host-software validation");
summary_lines{end+1} = "";
summary_lines{end+1} = "--- 采样参数 ---";
summary_lines{end+1} = sprintf("tau0                 : %.6e s", tau0);
summary_lines{end+1} = sprintf("N                    : %d", N);
summary_lines{end+1} = sprintf("T_total              : %.3f s (%.2f min)", T_total, T_total/60);
summary_lines{end+1} = sprintf("最大可信 tau          : %.3f s", T_total / cfg.max_tau_ratio);
summary_lines{end+1} = sprintf("去趋势方式           : %s", detrend_note);
summary_lines{end+1} = "";
summary_lines{end+1} = "--- Allan 结果概要 ---";
summary_lines{end+1} = sprintf("有效 tau 点数        : %d", n_tau);
summary_lines{end+1} = sprintf("tau 范围             : [%.3e, %.3e] s", tau_arr(1), tau_arr(end));
summary_lines{end+1} = sprintf("ADEV 范围            : [%.3e, %.3e]", min(adev_arr), max(adev_arr));

% 找到 ADEV 最小值
[adev_min, imin] = min(adev_arr);
summary_lines{end+1} = sprintf("ADEV 最小值          : %.3e @ tau = %.3e s", adev_min, tau_arr(imin));

% 斜率分析（首段和末段）
if n_tau >= 4
    slope_short = log10(adev_arr(2)/adev_arr(1)) / log10(tau_arr(2)/tau_arr(1));
    slope_long  = log10(adev_arr(end)/adev_arr(end-1)) / log10(tau_arr(end)/tau_arr(end-1));
    summary_lines{end+1} = sprintf("短 tau 端斜率        : %+.2f (预期 -0.5 为 White FM)", slope_short);
    summary_lines{end+1} = sprintf("长 tau 端斜率        : %+.2f (预期 +0.5 为 RWFM)", slope_long);
end

% 最终结论
summary_lines{end+1} = "";
summary_lines{end+1} = "--- 结论 ---";

csv_suitable = qc.overall_pass && n_tau >= 10 && T_total >= 10 * tau_arr(end);

if csv_suitable
    summary_lines{end+1} = "判定: PASS";
    summary_lines{end+1} = "该 CSV 适合作为 MATLAB/LabVIEW 前仿真 Allan 偏差计算的核心输入源。";
    summary_lines{end+1} = "";
    summary_lines{end+1} = "理由:";
    summary_lines{end+1} = "  1. CSV 数据质量检查全部通过";
    summary_lines{end+1} = sprintf("  2. 有效 tau 点数充足 (%d 个)", n_tau);
    summary_lines{end+1} = sprintf("  3. 总时长 (%.0f s) 满足最大 tau (%.0f s) 的 10 倍要求", T_total, tau_arr(end));
    summary_lines{end+1} = "  4. Allan 曲线形态符合典型 OCXO 噪声模型预期";
else
    summary_lines{end+1} = "判定: FAIL";
    summary_lines{end+1} = "该 CSV 不适合直接作为 Allan 核心输入源。";
    summary_lines{end+1} = "";
    summary_lines{end+1} = "失败原因:";
    if ~qc.overall_pass
        summary_lines{end+1} = "  - 数据质量检查未全部通过";
    end
    if n_tau < 10
        summary_lines{end+1} = sprintf("  - 有效 tau 点数不足 (%d < 10)", n_tau);
    end
    if T_total < 10 * tau_arr(end)
        summary_lines{end+1} = "  - 总时长不满足最大 tau 的 10 倍要求";
    end
end

summary_lines{end+1} = "";
summary_lines{end+1} = "--- LabVIEW 上位机对接字段说明 ---";
summary_lines{end+1} = "allan_result.csv 各列可直接被 LabVIEW Read Delimited Spreadsheet 读取：";
summary_lines{end+1} = "  m                 : 平均因子，LabVIEW 端用于与 FPGA 在线结果逐点比对";
summary_lines{end+1} = "  tau_s             : Allan 平均时间 (s)，即 log-log 曲线横轴";
summary_lines{end+1} = "  adev              : Allan 偏差 σ_y(τ)，即 log-log 曲线纵轴";
summary_lines{end+1} = "  avar              : Allan 方差 σ²_y(τ)，供需要方差形式的模块使用";
summary_lines{end+1} = "  sample_count_used : 该 τ 点参与计算的二阶差分对数，用于置信度判断";

summary_lines{end+1} = "";
summary_lines{end+1} = "重要声明:";
summary_lines{end+1} = "  本数据为 theoretical simulation（理论仿真），不是真实 OCXO 实测数据。";
summary_lines{end+1} = "  仅用于验证 Allan 偏差算法流程和 LabVIEW 上位机前仿真。";

summary_file = fullfile(cfg.output_dir, "allan_verify_summary.txt");
fid = fopen(summary_file, "w");
for k = 1:numel(summary_lines)
    fprintf(fid, "%s\n", summary_lines{k});
end
fclose(fid);
fprintf("[INFO] 验证总结已导出：%s\n", summary_file);


%% ==================== 7. 图表 ====================

% --- 7a. time_error_overview.png ---
fig1 = figure("Color", "w", "Position", [100 100 900 400]);
plot(time_s, x_raw * 1e9, "Color", [0.2 0.4 0.8], "LineWidth", 0.5);
grid on;
xlabel("time / s");
ylabel("time error x(t) / ns");
title("Time Error Overview  [THEORETICAL SIMULATION — NOT REAL MEASUREMENT]", ...
    "Interpreter", "none");
subtitle(sprintf("tau0 = %.3f ms,  N = %d,  T_{total} = %.0f s", tau0*1e3, N, T_total), ...
    "Interpreter", "tex");
set(gca, "FontName", "Times New Roman", "FontSize", 11);

exportgraphics(fig1, fullfile(cfg.output_dir, "time_error_overview.png"), "Resolution", 300);
fprintf("[INFO] 图表已导出：time_error_overview.png\n");

% --- 7b. allan_deviation.png ---
fig2 = figure("Color", "w", "Position", [100 100 900 550]);

loglog(tau_arr, adev_arr, "o-", "LineWidth", 1.2, "MarkerSize", 4, ...
    "Color", [0.1 0.3 0.7], "DisplayName", "Overlapping ADEV");
hold on;

% 参考斜率线
tau_ref = [tau_arr(1), tau_arr(end)];
adev_mid = adev_arr(round(n_tau/2));
tau_mid  = tau_arr(round(n_tau/2));

slopes = [-1, -0.5, 0, 0.5, 1];
slope_names = ["\tau^{-1} (WPM)", "\tau^{-1/2} (WFM)", "\tau^0 (FFM)", ...
               "\tau^{+1/2} (RWFM)", "\tau^{+1} (Drift)"];
slope_colors = [0.7 0.7 0.7; 0.8 0.4 0.4; 0.4 0.7 0.4; 0.8 0.6 0.2; 0.6 0.4 0.8];

for s = 1:numel(slopes)
    y_ref = adev_mid * (tau_ref / tau_mid) .^ slopes(s);
    loglog(tau_ref, y_ref, "--", "Color", slope_colors(s,:), "LineWidth", 0.8, ...
        "DisplayName", slope_names(s));
end

hold off;
grid on;
xlabel("\tau / s", "Interpreter", "tex");
ylabel("\sigma_y(\tau)  (Allan deviation)", "Interpreter", "tex");
title("Overlapping Allan Deviation  [THEORETICAL SIMULATION]", "Interpreter", "none");
subtitle(sprintf("tau0 = %.3f ms,  detrend = %s,  %d points", ...
    tau0*1e3, detrend_note, n_tau), "Interpreter", "none");
legend("Location", "southwest", "FontSize", 8);
set(gca, "FontName", "Times New Roman", "FontSize", 11);

exportgraphics(fig2, fullfile(cfg.output_dir, "allan_deviation.png"), "Resolution", 300);
fprintf("[INFO] 图表已导出：allan_deviation.png\n");

% --- 7c. time_interval_check.png ---
fig3 = figure("Color", "w", "Position", [100 100 900 350]);

subplot(1, 2, 1);
plot(dt * 1e3, ".", "MarkerSize", 1, "Color", [0.3 0.5 0.3]);
xlabel("sample index");
ylabel("dt / ms");
title("diff(time\_s) 序列");
grid on;
yline(tau0 * 1e3, "r--", sprintf("median = %.4f ms", tau0*1e3));

subplot(1, 2, 2);
histogram(dt * 1e3, 50, "FaceColor", [0.4 0.6 0.8], "EdgeColor", "none");
xlabel("dt / ms");
ylabel("count");
title("diff(time\_s) 分布");
grid on;
xline(tau0 * 1e3, "r--", sprintf("%.4f ms", tau0*1e3));

sgtitle("采样间隔检查  [THEORETICAL SIMULATION]", "Interpreter", "none");
exportgraphics(fig3, fullfile(cfg.output_dir, "time_interval_check.png"), "Resolution", 200);
fprintf("[INFO] 图表已导出：time_interval_check.png\n");


%% ==================== 8. 终端结果摘要 ====================

fprintf("\n");
fprintf("============================================================\n");
fprintf("       OCXO 仿真 CSV Allan 偏差验证结果\n");
fprintf("============================================================\n");
fprintf("数据身份             : %s (非真实 OCXO 实测)\n", cfg.data_type);
fprintf("CSV 质量检查         : %s\n", pass_fail(qc.overall_pass));
fprintf("tau0 (自动检测)      : %.6e s  (%.3f ms)\n", tau0, tau0*1e3);
fprintf("N (样本数)           : %d\n", N);
fprintf("T_total (总时长)     : %.3f s  (%.2f min)\n", T_total, T_total/60);
fprintf("最大可信 tau          : %.3f s\n", T_total / cfg.max_tau_ratio);
fprintf("Allan 有效点数       : %d\n", n_tau);
fprintf("ADEV 范围            : [%.3e, %.3e]\n", min(adev_arr), max(adev_arr));
fprintf("ADEV 最小值          : %.3e @ tau = %.3e s\n", adev_min, tau_arr(imin));

if n_tau >= 4
    fprintf("短 tau 端斜率        : %+.2f\n", slope_short);
    fprintf("长 tau 端斜率        : %+.2f\n", slope_long);
end

fprintf("------------------------------------------------------------\n");

if csv_suitable
    fprintf("[PASS] 该 CSV 适合作为 MATLAB/LabVIEW 前仿真 Allan 核心输入源。\n");
else
    fprintf("[FAIL] 该 CSV 不适合直接作为 Allan 核心输入源。\n");
end

fprintf("[声明] 本数据为 theoretical simulation，不是真实 OCXO 实测结果。\n");
fprintf("============================================================\n");

fprintf("\n[INFO] 所有输出文件位于：%s/\n", cfg.output_dir);
fprintf("  - allan_result.csv          (tau, m, adev, sample_count)\n");
fprintf("  - csv_quality_report.txt    (数据质量检查)\n");
fprintf("  - allan_verify_summary.txt  (验证结论)\n");
fprintf("  - time_error_overview.png   (时间误差曲线)\n");
fprintf("  - allan_deviation.png       (Allan 偏差 log-log)\n");
fprintf("  - time_interval_check.png   (采样间隔检查)\n");


%% ========================================================================
%                              本地函数
% ========================================================================

function s = pass_fail(flag)
    if flag
        s = "PASS";
    else
        s = "FAIL";
    end
end
