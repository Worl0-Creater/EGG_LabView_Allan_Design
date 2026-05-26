%% simulate_tdc_measurement_chain.m
% -------------------------------------------------------------------------
% OCXO 测量链路仿真对比脚本
%
% 功能：
%   1. 读取已有 ocxo_sim_time_error.csv 中的理想仿真时间误差 x_true(t)
%   2. 构造三种测量链路模型：
%      - 50 MHz FPGA 粗时间戳 (tick = 20 ns)
%      - 200 MHz FPGA 粗时间戳 (tick = 5 ns)
%      - TDC 高分辨率测量链路 (LSB + jitter 可配置)
%   3. 对各链路计算 overlapping Allan deviation
%   4. 输出对比 CSV、图表、报告
%
% 目的：
%   为论文和工程说明提供理论依据：
%   50 MHz 粗计数不适合高性能 OCXO 短稳测量；
%   采用 TDC 或高分辨率时间误差采集链路更合理。
%
% 数据身份声明：
%   input_data_type   = theoretical_simulation
%   output_data_type  = measurement_chain_simulation
%   is_real_measurement = false
% -------------------------------------------------------------------------

clear; clc; close all;

%% ==================== 1. 配置区 ====================

script_dir = fileparts(mfilename('fullpath'));

cfg = struct();

cfg.csv_file   = fullfile(script_dir, "ocxo_sim_time_error.csv");
cfg.output_dir = fullfile(script_dir, "tdc_chain_sim_output");

% 50 MHz 粗计数链路
cfg.f_ref_50m   = 50e6;
cfg.tick_50m_s  = 1 / cfg.f_ref_50m;           % 20 ns

% 200 MHz 粗计数链路
cfg.f_ref_200m  = 200e6;
cfg.tick_200m_s = 1 / cfg.f_ref_200m;           % 5 ns

% TDC 高分辨率理论链路，用于 MATLAB/LabVIEW Allan VI 前仿真验证
cfg.tdc_lsb_s        = 10e-12;                  % 10 ps
cfg.tdc_jitter_rms_s = 5e-12;                   % 5 ps RMS

% TDC 设计目标（三级）
cfg.tdc_target_recommended_s = 6e-12;           % 推荐: <= 6 ps RMS
cfg.tdc_target_aggressive_s  = 3e-12;           % 激进: <= 3 ps RMS (需更优参数)
cfg.tdc_target_ultimate_s    = 1.5e-12;         % 极限理想: <= 1.5 ps RMS (理论参考)

% 随机种子
cfg.random_seed = 42;

% 去趋势模式
cfg.detrend_mode = "linear";

% Allan 计算参数
cfg.max_tau_ratio = 10;
cfg.min_pairs     = 20;
cfg.num_m_points  = 80;

% 数据身份标记
cfg.input_data_type    = "theoretical_simulation";
cfg.output_data_type   = "measurement_chain_simulation";
cfg.is_real_measurement = false;

fprintf("============================================================\n");
fprintf("  OCXO 测量链路仿真对比\n");
fprintf("  [THEORETICAL MEASUREMENT CHAIN SIMULATION]\n");
fprintf("============================================================\n\n");


%% ==================== 2. CSV 读取与检查 ====================

fprintf("[STEP 1] 读取输入 CSV ...\n");

% 文件存在性
if ~isfile(cfg.csv_file)
    error("[FATAL] 输入文件不存在：%s\n请先运行 gen_ocxo_sim_csv.m 生成仿真 CSV。", cfg.csv_file);
end
fprintf("  文件存在: PASS\n");

data = readtable(cfg.csv_file);
col_names = string(data.Properties.VariableNames);
col_lower = lower(col_names);

% 必需列检查
required_cols = ["sample_index", "time_s", "time_error_s"];
cols_found = arrayfun(@(c) any(col_lower == c), required_cols);
if ~all(cols_found)
    missing = required_cols(~cols_found);
    error("[FATAL] CSV 缺少必需列：%s", strjoin(missing, ", "));
end
fprintf("  必需列检查: PASS (sample_index, time_s, time_error_s)\n");

% 提取数据
sample_idx = double(data.(col_names(col_lower == "sample_index")));
time_s     = double(data.(col_names(col_lower == "time_s")));
x_true     = double(data.(col_names(col_lower == "time_error_s")));
N          = numel(x_true);

% time_s 单调递增
dt = diff(time_s);
if ~all(dt > 0)
    error("[FATAL] time_s 不是单调递增。");
end
fprintf("  time_s 单调递增: PASS\n");

% NaN / Inf 检查
n_nan = sum(isnan(x_true)) + sum(isnan(time_s));
n_inf = sum(isinf(x_true)) + sum(isinf(time_s));
if n_nan > 0 || n_inf > 0
    error("[FATAL] 数据包含 %d 个 NaN 和 %d 个 Inf。", n_nan, n_inf);
end
fprintf("  NaN/Inf 检查: PASS (NaN=%d, Inf=%d)\n", n_nan, n_inf);

% 空值检查
n_empty = sum(isnan(x_true) | isnan(time_s));
fprintf("  空值检查: PASS\n");

% tau0 自动识别
tau0    = median(dt);
fs      = 1 / tau0;
T_total = time_s(end) - time_s(1);

fprintf("  tau0 (自动检测): %.6e s (%.3f ms)\n", tau0, tau0*1e3);
fprintf("  N (样本数): %d\n", N);
fprintf("  T_total (总时长): %.3f s (%.2f min)\n", T_total, T_total/60);

% time_error_s 统计
x_min  = min(x_true);
x_max  = max(x_true);
x_mean = mean(x_true);
x_std  = std(x_true);
x_pp   = x_max - x_min;

fprintf("  time_error_s 统计:\n");
fprintf("    min       = %.6e s (%.3f ns)\n", x_min, x_min*1e9);
fprintf("    max       = %.6e s (%.3f ns)\n", x_max, x_max*1e9);
fprintf("    mean      = %.6e s (%.3f ns)\n", x_mean, x_mean*1e9);
fprintf("    std       = %.6e s (%.3f ns)\n", x_std, x_std*1e9);
fprintf("    peak-peak = %.6e s (%.3f ns)\n", x_pp, x_pp*1e9);
fprintf("  CSV 读取: PASS\n\n");


%% ==================== 3. 构造测量链路模型 ====================

fprintf("[STEP 2] 构造测量链路模型 ...\n");

rng(cfg.random_seed);

% --- 3a. 50 MHz 粗计数测量模型 ---
x_50m_meas = round(x_true / cfg.tick_50m_s) * cfg.tick_50m_s;
e_50m = x_50m_meas - x_true;

e_50m_rms = sqrt(mean(e_50m.^2));
e_50m_pp  = max(e_50m) - min(e_50m);

fprintf("  50 MHz 粗计数链路:\n");
fprintf("    tick      = %.3e s (%.1f ns)\n", cfg.tick_50m_s, cfg.tick_50m_s*1e9);
fprintf("    误差 RMS  = %.3e s (%.3f ns)\n", e_50m_rms, e_50m_rms*1e9);
fprintf("    误差 P-P  = %.3e s (%.3f ns)\n", e_50m_pp, e_50m_pp*1e9);

% --- 3b. 200 MHz 粗计数测量模型 ---
x_200m_meas = round(x_true / cfg.tick_200m_s) * cfg.tick_200m_s;
e_200m = x_200m_meas - x_true;

e_200m_rms = sqrt(mean(e_200m.^2));
e_200m_pp  = max(e_200m) - min(e_200m);

fprintf("  200 MHz 粗计数链路:\n");
fprintf("    tick      = %.3e s (%.1f ns)\n", cfg.tick_200m_s, cfg.tick_200m_s*1e9);
fprintf("    误差 RMS  = %.3e s (%.3f ns)\n", e_200m_rms, e_200m_rms*1e9);
fprintf("    误差 P-P  = %.3e s (%.3f ns)\n", e_200m_pp, e_200m_pp*1e9);

% --- 3c. TDC 高分辨率测量模型 ---
quant_error_tdc = (rand(N, 1) - 0.5) * cfg.tdc_lsb_s;
jitter_tdc      = cfg.tdc_jitter_rms_s * randn(N, 1);
x_tdc_meas      = x_true + quant_error_tdc + jitter_tdc;
e_tdc           = x_tdc_meas - x_true;

e_tdc_rms = sqrt(mean(e_tdc.^2));
e_tdc_pp  = max(e_tdc) - min(e_tdc);
e_tdc_theory_rms = sqrt(cfg.tdc_lsb_s^2 / 12 + cfg.tdc_jitter_rms_s^2);

% 三级目标检查
tdc_pass_recommended = e_tdc_theory_rms <= cfg.tdc_target_recommended_s;
tdc_pass_aggressive  = e_tdc_theory_rms <= cfg.tdc_target_aggressive_s;
tdc_pass_ultimate    = e_tdc_theory_rms <= cfg.tdc_target_ultimate_s;

if tdc_pass_recommended
    tdc_target_status = "PASS";
else
    tdc_target_status = "FAIL";
end

fprintf("  TDC 高分辨率链路:\n");
fprintf("    LSB       = %.3e s (%.1f ps)\n", cfg.tdc_lsb_s, cfg.tdc_lsb_s*1e12);
fprintf("    jitter    = %.3e s (%.1f ps RMS)\n", cfg.tdc_jitter_rms_s, cfg.tdc_jitter_rms_s*1e12);
fprintf("    理论 RMS  = %.3e s (%.3f ps)  [sigma = sqrt(LSB^2/12 + jitter^2)]\n", e_tdc_theory_rms, e_tdc_theory_rms*1e12);
fprintf("    仿真 RMS  = %.3e s (%.3f ps)\n", e_tdc_rms, e_tdc_rms*1e12);
fprintf("    误差 P-P  = %.3e s (%.3f ps)\n", e_tdc_pp, e_tdc_pp*1e12);
fprintf("    推荐目标  <= %.1f ps : %s\n", cfg.tdc_target_recommended_s*1e12, string(tdc_pass_recommended));
fprintf("    激进目标  <= %.1f ps : %s\n", cfg.tdc_target_aggressive_s*1e12, string(tdc_pass_aggressive));
fprintf("    极限目标  <= %.1f ps : %s\n", cfg.tdc_target_ultimate_s*1e12, string(tdc_pass_ultimate));
fprintf("\n");


%% ==================== 4. 去趋势与 Allan deviation 计算 ====================

fprintf("[STEP 3] 计算 overlapping Allan deviation ...\n");

t_axis = (0:N-1).' * tau0;

% 去趋势
switch cfg.detrend_mode
    case "none"
        x_ideal_dt = x_true;
        x_50m_dt   = x_50m_meas;
        x_200m_dt  = x_200m_meas;
        x_tdc_dt   = x_tdc_meas;
        detrend_note = "none";
    case "linear"
        p1 = polyfit(t_axis, x_true, 1);
        trend = polyval(p1, t_axis);
        x_ideal_dt = x_true    - trend;
        x_50m_dt   = x_50m_meas  - trend;
        x_200m_dt  = x_200m_meas - trend;
        x_tdc_dt   = x_tdc_meas  - trend;
        detrend_note = "linear removed (from ideal trend)";
    otherwise
        x_ideal_dt = x_true;
        x_50m_dt   = x_50m_meas;
        x_200m_dt  = x_200m_meas;
        x_tdc_dt   = x_tdc_meas;
        detrend_note = "none (unknown mode)";
end

% m 值生成
max_tau = T_total / cfg.max_tau_ratio;
max_m   = floor(max_tau / tau0);
max_m   = min(max_m, floor((N - cfg.min_pairs) / 2));

if max_m < 1
    error("[FATAL] 数据点数不足以计算 Allan deviation。N = %d", N);
end

m_list = unique(round(logspace(0, log10(max_m), cfg.num_m_points)));
m_list = m_list(:);
m_list = m_list(m_list >= 1 & m_list <= max_m);
n_tau  = numel(m_list);

tau_arr      = zeros(n_tau, 1);
adev_ideal   = zeros(n_tau, 1);
adev_50m     = zeros(n_tau, 1);
adev_200m    = zeros(n_tau, 1);
adev_tdc     = zeros(n_tau, 1);
pairs_arr    = zeros(n_tau, 1);

for idx = 1:n_tau
    m = m_list(idx);
    tau_i = m * tau0;

    % ideal
    d2 = x_ideal_dt(1+2*m:end) - 2*x_ideal_dt(1+m:end-m) + x_ideal_dt(1:end-2*m);
    M = numel(d2);
    adev_ideal(idx) = sqrt(sum(d2.^2) / (2 * tau_i^2 * M));

    % 50 MHz
    d2 = x_50m_dt(1+2*m:end) - 2*x_50m_dt(1+m:end-m) + x_50m_dt(1:end-2*m);
    adev_50m(idx) = sqrt(sum(d2.^2) / (2 * tau_i^2 * M));

    % 200 MHz
    d2 = x_200m_dt(1+2*m:end) - 2*x_200m_dt(1+m:end-m) + x_200m_dt(1:end-2*m);
    adev_200m(idx) = sqrt(sum(d2.^2) / (2 * tau_i^2 * M));

    % TDC
    d2 = x_tdc_dt(1+2*m:end) - 2*x_tdc_dt(1+m:end-m) + x_tdc_dt(1:end-2*m);
    adev_tdc(idx) = sqrt(sum(d2.^2) / (2 * tau_i^2 * M));

    tau_arr(idx)   = tau_i;
    pairs_arr(idx) = M;
end

% 过滤无效点
valid = isfinite(adev_ideal) & adev_ideal > 0 & pairs_arr >= cfg.min_pairs;
tau_arr    = tau_arr(valid);
adev_ideal = adev_ideal(valid);
adev_50m   = adev_50m(valid);
adev_200m  = adev_200m(valid);
adev_tdc   = adev_tdc(valid);
pairs_arr  = pairs_arr(valid);
m_list     = m_list(valid);
n_tau      = numel(tau_arr);

fprintf("  Allan 计算完成：%d 个有效 tau 点\n", n_tau);
fprintf("  tau 范围: [%.3e, %.3e] s\n", tau_arr(1), tau_arr(end));
fprintf("  ADEV ideal 范围: [%.3e, %.3e]\n", min(adev_ideal), max(adev_ideal));
fprintf("  ADEV 50MHz 范围: [%.3e, %.3e]\n", min(adev_50m), max(adev_50m));
fprintf("  ADEV 200MHz 范围: [%.3e, %.3e]\n", min(adev_200m), max(adev_200m));
fprintf("  ADEV TDC   范围: [%.3e, %.3e]\n", min(adev_tdc), max(adev_tdc));
fprintf("\n");


%% ==================== 5. 创建输出目录 ====================

if ~isfolder(cfg.output_dir)
    mkdir(cfg.output_dir);
end


%% ==================== 6. 输出 CSV 文件 ====================

fprintf("[STEP 4] 输出 CSV 文件 ...\n");

% --- 6a. measurement_chain_compare_allan.csv ---
allan_tbl = table();
allan_tbl.m          = m_list;
allan_tbl.tau_s      = tau_arr;
allan_tbl.adev_ideal = adev_ideal;
allan_tbl.adev_50m   = adev_50m;
allan_tbl.adev_200m  = adev_200m;
allan_tbl.adev_tdc   = adev_tdc;
allan_tbl.num_pairs  = pairs_arr;

allan_csv = fullfile(cfg.output_dir, "measurement_chain_compare_allan.csv");
writetable(allan_tbl, allan_csv);
fprintf("  已导出: %s\n", allan_csv);

% --- 6b. measurement_chain_error_stats.csv ---
chain_names      = ["ideal"; "50MHz_coarse"; "200MHz_coarse"; "TDC_high_res"];
resolution_s     = [0; cfg.tick_50m_s; cfg.tick_200m_s; cfg.tdc_lsb_s];
jitter_rms_s     = [0; 0; 0; cfg.tdc_jitter_rms_s];
error_theory_s   = [0; cfg.tick_50m_s/sqrt(12); cfg.tick_200m_s/sqrt(12); e_tdc_theory_rms];
error_rms_s      = [0; e_50m_rms; e_200m_rms; e_tdc_rms];
error_pp_s       = [0; e_50m_pp; e_200m_pp; e_tdc_pp];
comments      = [ ...
    "ideal x_true, no measurement error"; ...
    "round quantization at 20 ns tick"; ...
    "round quantization at 5 ns tick"; ...
    sprintf("LSB=%.0fps, jitter=%.0fps RMS, uniform+gaussian model", ...
        cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12) ...
];

stats_tbl = table(chain_names, resolution_s, jitter_rms_s, error_theory_s, error_rms_s, error_pp_s, comments, ...
    'VariableNames', {'chain_name', 'resolution_s', 'jitter_rms_s', ...
                      'error_theory_rms_s', 'error_rms_s', 'error_peak_to_peak_s', 'comment'});

stats_csv = fullfile(cfg.output_dir, "measurement_chain_error_stats.csv");
writetable(stats_tbl, stats_csv);
fprintf("  已导出: %s\n", stats_csv);

% --- 6c. ocxo_sim_time_error_tdc_measured.csv ---
tdc_out = table();
tdc_out.sample_index             = sample_idx;
tdc_out.time_s                   = time_s;
tdc_out.time_error_s             = x_true;
tdc_out.time_error_tdc_meas_s    = x_tdc_meas;

tdc_csv = fullfile(cfg.output_dir, "ocxo_sim_time_error_tdc_measured.csv");
writetable(tdc_out, tdc_csv);
fprintf("  已导出: %s\n", tdc_csv);
fprintf("\n");


%% ==================== 7. 输出图像文件 ====================

fprintf("[STEP 5] 输出图像 ...\n");

% --- 7a. measurement_error_compare.png ---
fig1 = figure("Color", "w", "Position", [100 100 1100 650], "Visible", "off");

n_plot = min(N, 5000);

subplot(3, 1, 1);
plot(time_s(1:n_plot), e_50m(1:n_plot) * 1e9, "Color", [0.8 0.2 0.2], "LineWidth", 0.5);
ylabel("error / ns");
title("50 MHz Coarse Timestamp Quantization Error (tick = 20 ns)");
grid on;
ylim_50m = max(abs(e_50m(1:n_plot))) * 1e9 * 1.2;
ylim([-ylim_50m, ylim_50m]);
set(gca, "FontName", "Times New Roman", "FontSize", 10);

subplot(3, 1, 2);
plot(time_s(1:n_plot), e_200m(1:n_plot) * 1e9, "Color", [0.2 0.5 0.8], "LineWidth", 0.5);
ylabel("error / ns");
title("200 MHz Coarse Timestamp Quantization Error (tick = 5 ns)");
grid on;
ylim_200m = max(abs(e_200m(1:n_plot))) * 1e9 * 1.2;
ylim([-ylim_200m, ylim_200m]);
set(gca, "FontName", "Times New Roman", "FontSize", 10);

subplot(3, 1, 3);
plot(time_s(1:n_plot), e_tdc(1:n_plot) * 1e12, "Color", [0.1 0.6 0.3], "LineWidth", 0.5);
xlabel("time / s");
ylabel("error / ps");
title(sprintf("TDC High-Resolution Error (LSB=%.0f ps, jitter=%.0f ps RMS)", ...
    cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12));
grid on;
set(gca, "FontName", "Times New Roman", "FontSize", 10);

sgtitle("[THEORETICAL MEASUREMENT CHAIN SIMULATION] Measurement Error Comparison", ...
    "FontSize", 13, "FontWeight", "bold", "Interpreter", "none");

exportgraphics(fig1, fullfile(cfg.output_dir, "measurement_error_compare.png"), "Resolution", 300);
fprintf("  已导出: measurement_error_compare.png\n");
close(fig1);

% --- 7b. allan_compare_measurement_chain.png ---
fig2 = figure("Color", "w", "Position", [100 100 1000 650], "Visible", "off");

loglog(tau_arr, adev_ideal, "o-", "LineWidth", 1.5, "MarkerSize", 4, ...
    "Color", [0.0 0.0 0.0], "DisplayName", "Ideal (x_{true})");
hold on;
loglog(tau_arr, adev_50m, "s-", "LineWidth", 1.2, "MarkerSize", 4, ...
    "Color", [0.8 0.2 0.2], "DisplayName", "50 MHz coarse (tick=20ns)");
loglog(tau_arr, adev_200m, "d-", "LineWidth", 1.2, "MarkerSize", 4, ...
    "Color", [0.2 0.5 0.8], "DisplayName", "200 MHz coarse (tick=5ns)");
loglog(tau_arr, adev_tdc, "^-", "LineWidth", 1.2, "MarkerSize", 4, ...
    "Color", [0.1 0.6 0.3], "DisplayName", ...
    sprintf("TDC (LSB=%.0fps, jitter=%.0fps)", cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12));

% 量化噪声底限参考线 (independent white PM approximation: sigma_y ~ delta/(2*tau))
tau_ref = [tau_arr(1), tau_arr(end)];
q_floor_50m  = cfg.tick_50m_s  ./ (2 * tau_ref);
q_floor_200m = cfg.tick_200m_s ./ (2 * tau_ref);
loglog(tau_ref, q_floor_50m, "--", "Color", [0.8 0.2 0.2 0.4], "LineWidth", 0.8, ...
    "DisplayName", "50MHz quant. floor (\Delta/2\tau)");
loglog(tau_ref, q_floor_200m, "--", "Color", [0.2 0.5 0.8 0.4], "LineWidth", 0.8, ...
    "DisplayName", "200MHz quant. floor (\Delta/2\tau)");

% TDC 噪声底限 (total RMS / tau)
q_floor_tdc = e_tdc_theory_rms ./ tau_ref;
loglog(tau_ref, q_floor_tdc, "--", "Color", [0.1 0.6 0.3 0.4], "LineWidth", 0.8, ...
    "DisplayName", sprintf("TDC noise floor (%.1fps/\\tau)", e_tdc_theory_rms*1e12));

hold off;
grid on;
xlabel("\tau / s", "Interpreter", "tex");
ylabel("\sigma_y(\tau)  (Allan deviation)", "Interpreter", "tex");
title("[THEORETICAL MEASUREMENT CHAIN SIMULATION] Allan Deviation Comparison", ...
    "Interpreter", "none", "FontSize", 12);
subtitle(sprintf("tau0=%.0fms, N=%d, T=%.0fs, detrend=%s", ...
    tau0*1e3, N, T_total, detrend_note), "Interpreter", "none");
legend("Location", "southwest", "FontSize", 8);
set(gca, "FontName", "Times New Roman", "FontSize", 11);

exportgraphics(fig2, fullfile(cfg.output_dir, "allan_compare_measurement_chain.png"), "Resolution", 300);
fprintf("  已导出: allan_compare_measurement_chain.png\n");
close(fig2);

% --- 7c. time_error_tdc_vs_ideal.png ---
fig3 = figure("Color", "w", "Position", [100 100 1000 700], "Visible", "off");

n_plot2 = min(N, 10000);

subplot(3, 1, 1);
plot(time_s(1:n_plot2), x_true(1:n_plot2) * 1e9, "Color", [0 0 0], "LineWidth", 0.5);
ylabel("x(t) / ns");
title("Ideal Time Error x_{true}(t)");
grid on;
set(gca, "FontName", "Times New Roman", "FontSize", 10);

subplot(3, 1, 2);
plot(time_s(1:n_plot2), x_tdc_meas(1:n_plot2) * 1e9, "Color", [0.1 0.6 0.3], "LineWidth", 0.5);
ylabel("x(t) / ns");
title(sprintf("TDC Measured Time Error (LSB=%.0f ps, jitter=%.0f ps RMS)", ...
    cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12));
grid on;
set(gca, "FontName", "Times New Roman", "FontSize", 10);

subplot(3, 1, 3);
diff_tdc = (x_tdc_meas(1:n_plot2) - x_true(1:n_plot2)) * 1e12;
plot(time_s(1:n_plot2), diff_tdc, "Color", [0.6 0.3 0.7], "LineWidth", 0.5);
xlabel("time / s");
ylabel("difference / ps");
title("TDC Measurement Error (x_{TDC} - x_{true})");
grid on;
set(gca, "FontName", "Times New Roman", "FontSize", 10);

sgtitle("[THEORETICAL MEASUREMENT CHAIN SIMULATION] TDC vs Ideal Time Error", ...
    "FontSize", 13, "FontWeight", "bold", "Interpreter", "none");

exportgraphics(fig3, fullfile(cfg.output_dir, "time_error_tdc_vs_ideal.png"), "Resolution", 300);
fprintf("  已导出: time_error_tdc_vs_ideal.png\n");
close(fig3);
fprintf("\n");


%% ==================== 8. 输出报告文件 ====================

fprintf("[STEP 6] 输出报告 ...\n");

report = {};
report{end+1} = "==========================================================================";
report{end+1} = "  OCXO 测量链路仿真对比报告";
report{end+1} = "  [THEORETICAL MEASUREMENT CHAIN SIMULATION]";
report{end+1} = "==========================================================================";
report{end+1} = sprintf("日期: %s", datestr(now, 'yyyy-mm-dd HH:MM:SS'));
report{end+1} = "";

report{end+1} = "--- 1. 输入文件 ---";
report{end+1} = sprintf("input_file           : %s", cfg.csv_file);
report{end+1} = "";

report{end+1} = "--- 2. 数据身份声明 ---";
report{end+1} = sprintf("input_data_type      : %s", cfg.input_data_type);
report{end+1} = sprintf("output_data_type     : %s", cfg.output_data_type);
report{end+1} = sprintf("is_real_measurement  : %s", mat2str(cfg.is_real_measurement));
report{end+1} = "NOTE: All output data is THEORETICAL SIMULATION, NOT real OCXO measurement.";
report{end+1} = "NOTE: This is a THEORETICAL TDC measurement chain for MATLAB/LabVIEW Allan VI validation.";
report{end+1} = "NOTE: It is NOT real TDC hardware measurement data.";
report{end+1} = "";

report{end+1} = "--- 3. 采样参数 ---";
report{end+1} = sprintf("tau0                 : %.6e s (%.3f ms)", tau0, tau0*1e3);
report{end+1} = sprintf("N (样本数)           : %d", N);
report{end+1} = sprintf("T_total (总时长)     : %.3f s (%.2f min, %.2f hr)", ...
    T_total, T_total/60, T_total/3600);
report{end+1} = sprintf("去趋势模式           : %s", detrend_note);
report{end+1} = "";

report{end+1} = "--- 4. 测量链路参数 ---";
report{end+1} = "";
report{end+1} = "  [50 MHz 粗计数链路]";
report{end+1} = sprintf("    f_ref            : %.0f MHz", cfg.f_ref_50m / 1e6);
report{end+1} = sprintf("    tick             : %.3e s (%.1f ns)", cfg.tick_50m_s, cfg.tick_50m_s*1e9);
report{end+1} = sprintf("    模型             : x_meas = round(x_true / tick) * tick");
report{end+1} = "";
report{end+1} = "  [200 MHz 粗计数链路]";
report{end+1} = sprintf("    f_ref            : %.0f MHz", cfg.f_ref_200m / 1e6);
report{end+1} = sprintf("    tick             : %.3e s (%.1f ns)", cfg.tick_200m_s, cfg.tick_200m_s*1e9);
report{end+1} = sprintf("    模型             : x_meas = round(x_true / tick) * tick");
report{end+1} = "";
report{end+1} = "  [TDC 高分辨率链路]";
report{end+1} = sprintf("    TDC LSB          : %.3e s (%.1f ps)", cfg.tdc_lsb_s, cfg.tdc_lsb_s*1e12);
report{end+1} = sprintf("    TDC jitter RMS   : %.3e s (%.1f ps)", cfg.tdc_jitter_rms_s, cfg.tdc_jitter_rms_s*1e12);
report{end+1} = sprintf("    模型             : x_meas = x_true + uniform(-LSB/2,+LSB/2) + N(0,sigma_jitter)");
report{end+1} = sprintf("    理论公式         : sigma_total = sqrt(LSB^2/12 + sigma_jitter^2)");
report{end+1} = sprintf("                     = sqrt(%.1f^2/12 + %.1f^2) ps", cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12);
report{end+1} = sprintf("                     = %.3f ps", e_tdc_theory_rms*1e12);
report{end+1} = "";
report{end+1} = "    设计目标（三级）:";
report{end+1} = sprintf("      推荐   <= %.1f ps : %s", cfg.tdc_target_recommended_s*1e12, string(tdc_pass_recommended));
report{end+1} = sprintf("      激进   <= %.1f ps : %s  (需更优 LSB/jitter 参数)", cfg.tdc_target_aggressive_s*1e12, string(tdc_pass_aggressive));
report{end+1} = sprintf("      极限   <= %.1f ps : %s  (理论参考)", cfg.tdc_target_ultimate_s*1e12, string(tdc_pass_ultimate));
report{end+1} = "";

report{end+1} = "--- 5. 测量误差统计 ---";
report{end+1} = "";
report{end+1} = sprintf("  %-20s  %14s  %14s", "链路", "误差 RMS", "误差 Peak-Peak");
report{end+1} = sprintf("  %-20s  %14s  %14s", "----", "--------", "--------------");
report{end+1} = sprintf("  %-20s  %14s  %14s", "Ideal", "0", "0");
report{end+1} = sprintf("  %-20s  %11.3e s  %11.3e s", "50 MHz coarse", e_50m_rms, e_50m_pp);
report{end+1} = sprintf("  %-20s  %11.3e s  %11.3e s", "200 MHz coarse", e_200m_rms, e_200m_pp);
report{end+1} = sprintf("  %-20s  %11.3e s  %11.3e s", "TDC high-res", e_tdc_rms, e_tdc_pp);
report{end+1} = "";
report{end+1} = sprintf("  50 MHz 量化误差 RMS (理论) : tick/sqrt(12) = %.3e s (%.3f ns)", ...
    cfg.tick_50m_s/sqrt(12), cfg.tick_50m_s/sqrt(12)*1e9);
report{end+1} = sprintf("  200 MHz 量化误差 RMS (理论): tick/sqrt(12) = %.3e s (%.3f ns)", ...
    cfg.tick_200m_s/sqrt(12), cfg.tick_200m_s/sqrt(12)*1e9);
report{end+1} = sprintf("  TDC 总误差 RMS (理论)      : sqrt(LSB^2/12 + sigma^2) = %.3e s (%.3f ps)", ...
    e_tdc_theory_rms, e_tdc_theory_rms*1e12);
report{end+1} = sprintf("  TDC 总误差 RMS (仿真)      : %.3e s (%.3f ps)", e_tdc_rms, e_tdc_rms*1e12);
report{end+1} = "";
report{end+1} = "  TDC 三级目标检查:";
report{end+1} = sprintf("    推荐 <= %.1f ps : theoretical RMS %.3f ps -> %s", ...
    cfg.tdc_target_recommended_s*1e12, e_tdc_theory_rms*1e12, string(tdc_pass_recommended));
report{end+1} = sprintf("    激进 <= %.1f ps : theoretical RMS %.3f ps -> %s", ...
    cfg.tdc_target_aggressive_s*1e12, e_tdc_theory_rms*1e12, string(tdc_pass_aggressive));
report{end+1} = sprintf("    极限 <= %.1f ps : theoretical RMS %.3f ps -> %s", ...
    cfg.tdc_target_ultimate_s*1e12, e_tdc_theory_rms*1e12, string(tdc_pass_ultimate));
report{end+1} = "";

report{end+1} = "--- 6. Allan 偏差对比 ---";
report{end+1} = "";
report{end+1} = sprintf("  有效 tau 点数      : %d", n_tau);
report{end+1} = sprintf("  tau 范围           : [%.3e, %.3e] s", tau_arr(1), tau_arr(end));
report{end+1} = "";

% 选取几个代表性 tau 点输出比较
check_taus = [0.01, 0.1, 1, 10, 100];
report{end+1} = sprintf("  %-10s  %-12s  %-12s  %-12s  %-12s", ...
    "tau (s)", "ADEV ideal", "ADEV 50MHz", "ADEV 200MHz", "ADEV TDC");
report{end+1} = sprintf("  %-10s  %-12s  %-12s  %-12s  %-12s", ...
    "------", "----------", "----------", "-----------", "--------");
for ct = check_taus
    [~, ci] = min(abs(tau_arr - ct));
    if abs(tau_arr(ci) - ct) / ct < 0.5
        report{end+1} = sprintf("  %-10.3f  %-12.3e  %-12.3e  %-12.3e  %-12.3e", ...
            tau_arr(ci), adev_ideal(ci), adev_50m(ci), adev_200m(ci), adev_tdc(ci));
    end
end
report{end+1} = "";

report{end+1} = "--- 7. 各测量链对 Allan 曲线的影响分析 ---";
report{end+1} = "";
report{end+1} = "  [50 MHz 粗计数链路]";
report{end+1} = "    - 时间分辨率 20 ns 远大于 OCXO 短期时间误差量级 (~ps 到 ~ns)";
report{end+1} = "    - 量化误差主导短 tau 区间，Allan 曲线在短 tau 端被量化噪声抬高";
report{end+1} = "    - 无法区分 OCXO 本征噪声与测量系统量化噪声";
report{end+1} = "    - 结论：不适合高性能 OCXO 短稳表征";
report{end+1} = "";
report{end+1} = "  [200 MHz 粗计数链路]";
report{end+1} = "    - 时间分辨率 5 ns 比 50 MHz 改善 4 倍";
report{end+1} = "    - 短 tau 区间量化噪声仍然显著";
report{end+1} = "    - 属于粗时间戳方案，分辨率仍不足以表征高性能 OCXO";
report{end+1} = "    - 结论：比 50 MHz 有改善，但仍属于粗时间戳方案";
report{end+1} = "";
report{end+1} = "  [TDC 高分辨率链路]";
report{end+1} = sprintf("    - 时间分辨率 %.1f ps，远优于粗计数方案", cfg.tdc_lsb_s*1e12);
report{end+1} = sprintf("    - 理论总时间误差 RMS %.3f ps", e_tdc_theory_rms*1e12);
report{end+1} = sprintf("    - 推荐目标 <= %.1f ps: %s | 激进 <= %.1f ps: %s | 极限 <= %.1f ps: %s", ...
    cfg.tdc_target_recommended_s*1e12, string(tdc_pass_recommended), ...
    cfg.tdc_target_aggressive_s*1e12, string(tdc_pass_aggressive), ...
    cfg.tdc_target_ultimate_s*1e12, string(tdc_pass_ultimate));
report{end+1} = "    - Allan 曲线更接近理想曲线，适合 LabVIEW Allan VI 前仿真验证";
report{end+1} = "    - 能够准确反映 OCXO 本征噪声特性";
report{end+1} = "    - 结论：测量链路分辨率更合理，适合生成 time_error_s 输入";
report{end+1} = "";

report{end+1} = "--- 8. 结论 ---";
report{end+1} = "";
report{end+1} = sprintf("  1. 50 MHz 粗计数会显著引入量化误差 (仿真 RMS %.3f ns, 理论 %.3f ns)，", ...
    e_50m_rms*1e9, cfg.tick_50m_s/sqrt(12)*1e9);
report{end+1} = "     不适合高性能 OCXO 短稳表征。";
report{end+1} = "";
report{end+1} = sprintf("  2. 200 MHz 可以改善粗计数分辨率 (仿真 RMS %.3f ns, 理论 %.3f ns)，", ...
    e_200m_rms*1e9, cfg.tick_200m_s/sqrt(12)*1e9);
report{end+1} = "     但仍属于粗时间戳方案，分辨率不足。";
report{end+1} = "";
report{end+1} = sprintf("  3. TDC / 高分辨率理论时间间隔测量链路 (RMS ~%.3f ps)", ...
    e_tdc_theory_rms*1e12);
report{end+1} = "     更适合生成 time_error_s 输入，";
report{end+1} = "     测量链路分辨率与 OCXO 本征噪声匹配。";
report{end+1} = "";
report{end+1} = "  4. 当前结果只用于 MATLAB/LabVIEW 前仿真和测量链路合理性说明，";
report{end+1} = "     不是真实实测数据。";
report{end+1} = "";

report{end+1} = "--- 9. 输出文件清单 ---";
report{end+1} = "";
report{end+1} = sprintf("  measurement_chain_compare_allan.csv   : Allan 对比数据");
report{end+1} = sprintf("  measurement_chain_error_stats.csv     : 各链路误差统计");
report{end+1} = sprintf("  ocxo_sim_time_error_tdc_measured.csv  : TDC 模拟测量结果 (可作为 LabVIEW 输入)");
report{end+1} = sprintf("  measurement_error_compare.png         : 测量误差时域对比");
report{end+1} = sprintf("  allan_compare_measurement_chain.png   : Allan 偏差对比曲线");
report{end+1} = sprintf("  time_error_tdc_vs_ideal.png           : TDC 与理想时间误差对比");
report{end+1} = sprintf("  tdc_chain_sim_report.txt              : 本报告");
report{end+1} = "";
report{end+1} = "==========================================================================";
report{end+1} = "  DISCLAIMER: This is a THEORETICAL MEASUREMENT CHAIN SIMULATION.";
report{end+1} = "  All data is generated from simulation models, NOT real measurement.";
report{end+1} = "  Do NOT claim TDC simulation data as real TDC measurement.";
report{end+1} = "==========================================================================";

report_file = fullfile(cfg.output_dir, "tdc_chain_sim_report.txt");
fid = fopen(report_file, "w");
for k = 1:numel(report)
    fprintf(fid, "%s\n", report{k});
end
fclose(fid);
fprintf("  已导出: %s\n\n", report_file);


%% ==================== 9. 终端结果摘要 ====================

fprintf("============================================================\n");
fprintf("       测量链路仿真对比结果摘要\n");
fprintf("       [THEORETICAL MEASUREMENT CHAIN SIMULATION]\n");
fprintf("============================================================\n");
fprintf("CSV 读取                 : PASS\n");
fprintf("tau0 (自动检测)          : %.6e s (%.3f ms)\n", tau0, tau0*1e3);
fprintf("N (样本数)               : %d\n", N);
fprintf("T_total (总时长)         : %.3f s (%.2f hr)\n", T_total, T_total/3600);
fprintf("------------------------------------------------------------\n");
fprintf("50 MHz 量化分辨率        : %.3e s (%.1f ns)\n", cfg.tick_50m_s, cfg.tick_50m_s*1e9);
fprintf("200 MHz 量化分辨率       : %.3e s (%.1f ns)\n", cfg.tick_200m_s, cfg.tick_200m_s*1e9);
fprintf("TDC LSB                  : %.3e s (%.1f ps)\n", cfg.tdc_lsb_s, cfg.tdc_lsb_s*1e12);
fprintf("TDC jitter RMS           : %.3e s (%.1f ps)\n", cfg.tdc_jitter_rms_s, cfg.tdc_jitter_rms_s*1e12);
fprintf("TDC theoretical RMS      : %.3e s (%.3f ps)\n", e_tdc_theory_rms, e_tdc_theory_rms*1e12);
fprintf("TDC target RMS (推荐)     : <= %.1f ps : %s\n", cfg.tdc_target_recommended_s*1e12, string(tdc_pass_recommended));
fprintf("TDC target RMS (激进)     : <= %.1f ps : %s\n", cfg.tdc_target_aggressive_s*1e12, string(tdc_pass_aggressive));
fprintf("TDC target RMS (极限)     : <= %.1f ps : %s\n", cfg.tdc_target_ultimate_s*1e12, string(tdc_pass_ultimate));
fprintf("------------------------------------------------------------\n");
fprintf("50 MHz 误差 RMS          : %.3e s (%.3f ns)\n", e_50m_rms, e_50m_rms*1e9);
fprintf("200 MHz 误差 RMS         : %.3e s (%.3f ns)\n", e_200m_rms, e_200m_rms*1e9);
fprintf("TDC 误差 RMS             : %.3e s (%.3f ps)\n", e_tdc_rms, e_tdc_rms*1e12);
fprintf("TDC 推荐目标检查         : %s (theoretical %.3f ps <= %.1f ps)\n", ...
    tdc_target_status, e_tdc_theory_rms*1e12, cfg.tdc_target_recommended_s*1e12);
fprintf("TDC 激进目标检查         : %s (theoretical %.3f ps <= %.1f ps)\n", ...
    string(tdc_pass_aggressive), e_tdc_theory_rms*1e12, cfg.tdc_target_aggressive_s*1e12);
fprintf("TDC 极限目标检查         : %s (theoretical %.3f ps <= %.1f ps)\n", ...
    string(tdc_pass_ultimate), e_tdc_theory_rms*1e12, cfg.tdc_target_ultimate_s*1e12);
fprintf("------------------------------------------------------------\n");
fprintf("Allan 对比结果文件       : %s\n", allan_csv);
fprintf("TDC 模拟测量 CSV         : %s\n", tdc_csv);
fprintf("Allan 对比图             : %s\n", fullfile(cfg.output_dir, "allan_compare_measurement_chain.png"));
fprintf("------------------------------------------------------------\n");

% 判断 TDC 输出是否适合作为 LabVIEW 高分辨率测量链路模拟输入
tdc_suitable = (e_tdc_rms < cfg.tick_50m_s / 10);
if tdc_suitable
    fprintf("LabVIEW 高分辨率模拟输入 : 适合\n");
    fprintf("  文件: %s\n", tdc_csv);
    fprintf("  理由: TDC 误差 RMS (%.1f ps) 远小于 50 MHz tick (20 ns)\n", e_tdc_rms*1e12);
else
    fprintf("LabVIEW 高分辨率模拟输入 : 不适合 (TDC 误差过大)\n");
end

fprintf("------------------------------------------------------------\n");
fprintf("[声明] 本数据为 theoretical measurement chain simulation，\n");
fprintf("       不是真实 OCXO 实测结果，也不是真实 TDC 实测数据。\n");
fprintf("       仅用于 MATLAB/LabVIEW Allan VI 前仿真和测量链路合理性说明。\n");
fprintf("============================================================\n");

fprintf("\n[INFO] 所有输出文件位于: %s/\n", cfg.output_dir);
fprintf("  - measurement_chain_compare_allan.csv   (Allan 对比数据)\n");
fprintf("  - measurement_chain_error_stats.csv     (误差统计)\n");
fprintf("  - ocxo_sim_time_error_tdc_measured.csv  (TDC 模拟测量, 可作为 LabVIEW 输入)\n");
fprintf("  - measurement_error_compare.png         (误差对比图)\n");
fprintf("  - allan_compare_measurement_chain.png   (Allan 对比图)\n");
fprintf("  - time_error_tdc_vs_ideal.png           (TDC vs ideal 对比)\n");
fprintf("  - tdc_chain_sim_report.txt              (仿真报告)\n");
fprintf("\n[DONE] 测量链路仿真对比完成。\n");
