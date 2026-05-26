%% tdc_allan_design.m
% -------------------------------------------------------------------------
% 10 MHz OCXO — TDC 高分辨率测量链路 Allan 方差验证脚本
%
% 测量模型：
%   x_tdc = x_true + uniform(-LSB/2, +LSB/2) + N(0, sigma_jitter)
%   理论总误差 RMS: sigma_total = sqrt(LSB^2/12 + sigma_jitter^2)
%
% 核心公式（overlapping Allan deviation）：
%   sigma_y^2(tau) =
%       sum( x(i+2m) - 2x(i+m) + x(i) )^2
%       / [ 2 * tau^2 * (N - 2m) ]
%
% 输入 CSV 支持列名：
%   time_error_s    — 直接作为 x_true（推荐）
%   timestamp_count — 50 MHz tick 转时间误差后叠加 TDC 噪声
%   period_count    — 周期计数积分后叠加 TDC 噪声
%   若 CSV 不存在，自动生成理想演示数据。
% -------------------------------------------------------------------------

clear; clc; close all;

%% ===================== 1. 用户配置区 =====================

script_dir = fileparts(mfilename('fullpath'));

cfg = struct();

% OCXO 标称频率
cfg.f0    = 10e6;
cfg.T0    = 1 / cfg.f0;          % 100 ns

% FPGA 参考时钟（仅用于 timestamp_count 转换）
cfg.f_ref = 50e6;
cfg.T_ref = 1 / cfg.f_ref;       % 20 ns

% TDC 参数（可配置）
cfg.tdc_lsb_s        = 10e-12;   % LSB = 10 ps
cfg.tdc_jitter_rms_s = 5e-12;    % jitter RMS = 5 ps

% 随机种子（固定保证可复现）
cfg.random_seed = 42;

% 输入 CSV（优先使用优化 TDC 链路的模拟测量输出）
cfg.csv_file = "D:\EG_FPGA_Project\Project\下位机模拟输出\优化tdc后\ocxo_sim_time_error_tdc_measured.csv";

% 计数器位宽（用于 timestamp_count 回绕处理）
cfg.counter_bits          = 32;
cfg.enable_counter_unwrap = true;

% 是否去除二次频率漂移
cfg.remove_quadratic_drift = false;

% 边沿抽取（1 = 不抽取）
cfg.edge_decimation = 1;

% Allan 计算参数
cfg.min_num_pairs  = 20;
cfg.max_m_fraction = 0.20;
cfg.use_log_m      = true;

% 输出文件
cfg.out_csv = fullfile(script_dir, "tdc_allan_result.csv");
cfg.out_fig = fullfile(script_dir, "tdc_allan_deviation.png");


%% ===================== 2. 读取或生成数据 =====================

if isfile(cfg.csv_file)
    fprintf("[INFO] 读取输入文件：%s\n", cfg.csv_file);
    data = readtable(cfg.csv_file);
else
    fprintf("[WARN] 未找到输入文件：%s\n", cfg.csv_file);
    fprintf("[INFO] 自动生成演示数据（理想时间误差，无粗量化）。\n");
    demo_N = 200000;
    data   = generate_demo_data(demo_N, cfg);
    writetable(data, cfg.csv_file);
    fprintf("[INFO] 已生成演示 CSV：%s\n", cfg.csv_file);
end


%% ===================== 3. 构造理想时间误差 x_true =====================

[x_true, tau0_eff, meta] = build_time_error_sequence(data, cfg);

valid  = isfinite(x_true);
x_true = x_true(valid);

if cfg.edge_decimation > 1
    x_true   = x_true(1:cfg.edge_decimation:end);
    tau0_eff = tau0_eff * cfg.edge_decimation;
end

N = numel(x_true);

if N < 100
    error("有效时间误差点数太少：N = %d。请检查输入 CSV。", N);
end

fprintf("\n========== 数据摘要 ==========\n");
fprintf("输入标称频率 f0        : %.6f MHz\n", cfg.f0 / 1e6);
fprintf("有效采样间隔 tau0_eff  : %.3e s\n", tau0_eff);
fprintf("有效数据点数 N         : %d\n", N);
fprintf("数据来源               : %s\n", meta.source_type);


%% ===================== 4. 叠加 TDC 测量噪声 =====================

rng(cfg.random_seed);

quant_noise  = (rand(N, 1) - 0.5) * cfg.tdc_lsb_s;
jitter_noise = cfg.tdc_jitter_rms_s * randn(N, 1);
x_tdc        = x_true + quant_noise + jitter_noise;

tdc_theory_rms = sqrt(cfg.tdc_lsb_s^2 / 12 + cfg.tdc_jitter_rms_s^2);
tdc_sim_rms    = sqrt(mean((x_tdc - x_true).^2));

fprintf("\n========== TDC 测量链路 ==========\n");
fprintf("TDC LSB                : %.3e s (%.1f ps)\n", cfg.tdc_lsb_s, cfg.tdc_lsb_s*1e12);
fprintf("TDC jitter RMS         : %.3e s (%.1f ps)\n", cfg.tdc_jitter_rms_s, cfg.tdc_jitter_rms_s*1e12);
fprintf("理论总误差 RMS         : %.3e s (%.3f ps)  [sqrt(LSB^2/12 + jitter^2)]\n", tdc_theory_rms, tdc_theory_rms*1e12);
fprintf("仿真总误差 RMS         : %.3e s (%.3f ps)\n", tdc_sim_rms, tdc_sim_rms*1e12);


%% ===================== 5. 去趋势 =====================

t  = (0:N-1).' * tau0_eff;
p1 = polyfit(t, x_tdc, 1);
x_detrend = x_tdc - polyval(p1, t);

if cfg.remove_quadratic_drift
    p2     = polyfit(t, x_detrend, 2);
    x_used = x_detrend - polyval(p2, t);
    drift_note = "quadratic drift removed";
else
    x_used     = x_detrend;
    drift_note = "linear offset removed only";
end

fprintf("去趋势方式             : %s\n", drift_note);


%% ===================== 6. 计算 overlapping Allan deviation =====================

[tau, avar, adev, num_pairs, m_list] = overlapping_adev_from_phase( ...
    x_used, tau0_eff, cfg.min_num_pairs, cfg.max_m_fraction, cfg.use_log_m);

adev_std_approx = adev ./ sqrt(num_pairs);


%% ===================== 7. 结果导出 =====================

result = table();
result.m               = m_list(:);
result.tau_s           = tau(:);
result.allan_variance  = avar(:);
result.allan_deviation = adev(:);
result.num_pairs       = num_pairs(:);
result.adev_std_approx = adev_std_approx(:);

writetable(result, cfg.out_csv);
fprintf("\n[INFO] Allan 结果已导出：%s\n", cfg.out_csv);


%% ===================== 8. 画图 =====================

figure("Color", "w");

loglog(tau, adev, "^-", "LineWidth", 1.2, "MarkerSize", 4, ...
    "Color", [0.1 0.6 0.3]);
grid on;
xlabel("\tau / s", "Interpreter", "tex");
ylabel("\sigma_y(\tau)", "Interpreter", "tex");
title("10 MHz OCXO — TDC高分辨率测量链路 Allan 方差", "Interpreter", "none");

subtitle_text = sprintf( ...
    "TDC LSB=%.0fps, jitter=%.0fps RMS, theory RMS=%.2fps | tau0=%.3es, N=%d | %s", ...
    cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12, tdc_theory_rms*1e12, ...
    tau0_eff, N, drift_note);
subtitle(subtitle_text, "Interpreter", "none");

set(gca, "FontName", "Times New Roman", "FontSize", 11);

exportgraphics(gcf, cfg.out_fig, "Resolution", 300);
fprintf("[INFO] Allan 曲线已导出：%s\n", cfg.out_fig);


%% ===================== 9. 结果预览 =====================

fprintf("\n========== Allan 结果预览 ==========\n");
disp(result(1:min(10, height(result)), :));

fprintf("\n========== 工程提醒 ==========\n");
fprintf("1. TDC 理论总误差 RMS = sqrt(LSB^2/12 + jitter^2) = %.3f ps\n", tdc_theory_rms*1e12);
fprintf("2. 当前 LSB=%.0fps, jitter=%.0fps RMS，可在配置区调整。\n", ...
    cfg.tdc_lsb_s*1e12, cfg.tdc_jitter_rms_s*1e12);
fprintf("3. 若需更换输入数据，修改 cfg.csv_file 指向实际 CSV。\n");
fprintf("4. FPGA 在线结果应与本脚本在相同 tau0、相同 m、相同去趋势策略下比较。\n");


%% ========================================================================
%                              本地函数区
% ========================================================================

function data = generate_demo_data(N, cfg)
    % 生成演示数据：理想时间误差序列（不含粗量化）
    T0 = cfg.T0;
    k  = (0:N-1).';
    t  = k * T0;

    rng(1);
    sigma_y_white = 2e-10;
    y_white = sigma_y_white * randn(N, 1);

    drift_rate = 2e-13;
    y_drift    = drift_rate * t;

    y   = y_white + y_drift;
    x_s = cumsum(y) * T0;

    data = table();
    data.sample_index = k;
    data.time_s       = t;
    data.time_error_s = x_s;
end


function [x_s, tau0_eff, meta] = build_time_error_sequence(data, cfg)
    % 从 CSV 表构造时间误差 x_k，单位 s
    names       = string(data.Properties.VariableNames);
    names_lower = lower(names);
    meta        = struct();

    if any(names_lower == "time_error_s")
        col  = names(names_lower == "time_error_s");
        x_s  = double(data.(col(1))(:));

        if any(names_lower == "time_s")
            t_col    = names(names_lower == "time_s");
            t_s      = double(data.(t_col(1)));
            tau0_eff = median(diff(t_s));
        else
            tau0_eff = cfg.T0;
        end
        meta.source_type = "time_error_s";

    elseif any(names_lower == "timestamp_count")
        col       = names(names_lower == "timestamp_count");
        count_raw = double(data.(col(1))(:));

        if cfg.enable_counter_unwrap
            count = unwrap_counter(count_raw, cfg.counter_bits);
        else
            count = count_raw;
        end

        t_meas   = count * cfg.T_ref;
        k        = (0:numel(t_meas)-1).';
        t_ideal  = k * cfg.T0;
        x_s      = t_meas - t_ideal;
        tau0_eff = cfg.T0;
        meta.source_type = "timestamp_count";

    elseif any(names_lower == "period_count")
        col          = names(names_lower == "period_count");
        period_count = double(data.(col(1))(:));
        period_s     = period_count * cfg.T_ref;
        period_error = period_s - cfg.T0;
        x_s          = [0; cumsum(period_error)];
        tau0_eff     = cfg.T0;
        meta.source_type = "period_count";

    else
        error("CSV 中未找到支持的列名。需要 timestamp_count、period_count 或 time_error_s。");
    end
end


function count_unwrapped = unwrap_counter(count_raw, counter_bits)
    modulus   = 2^counter_bits;
    count_raw = double(count_raw(:));
    d         = diff(count_raw);
    wrap_pos  = d < -modulus/2;
    wrap_neg  = d >  modulus/2;
    correction = zeros(size(count_raw));
    correction(2:end) = cumsum(wrap_pos) * modulus - cumsum(wrap_neg) * modulus;
    count_unwrapped = count_raw + correction;
end


function [tau, avar, adev, num_pairs, m_list] = overlapping_adev_from_phase( ...
    x_s, tau0, min_num_pairs, max_m_fraction, use_log_m)

    x_s  = double(x_s(:));
    N    = numel(x_s);

    max_m_by_fraction = floor(N * max_m_fraction);
    max_m_by_pairs    = floor((N - min_num_pairs) / 2);
    max_m             = max(1, min(max_m_by_fraction, max_m_by_pairs));

    if max_m < 1
        error("数据点数不足，无法计算 Allan deviation。N = %d", N);
    end

    if use_log_m
        raw_m  = unique(round(logspace(0, log10(max_m), 80)));
        m_list = raw_m(raw_m >= 1);
    else
        m_list = (1:max_m).';
    end

    tau       = zeros(numel(m_list), 1);
    avar      = zeros(numel(m_list), 1);
    adev      = zeros(numel(m_list), 1);
    num_pairs = zeros(numel(m_list), 1);

    for idx = 1:numel(m_list)
        m     = m_list(idx);
        d2    = x_s(1+2*m:end) - 2*x_s(1+m:end-m) + x_s(1:end-2*m);
        M     = numel(d2);
        tau_i = m * tau0;

        avar_i = sum(d2.^2) / (2 * tau_i^2 * M);

        tau(idx)       = tau_i;
        avar(idx)      = avar_i;
        adev(idx)      = sqrt(avar_i);
        num_pairs(idx) = M;
    end

    valid     = isfinite(adev) & adev > 0 & num_pairs >= min_num_pairs;
    tau       = tau(valid);
    avar      = avar(valid);
    adev      = adev(valid);
    num_pairs = num_pairs(valid);
    m_list    = m_list(valid);
end

