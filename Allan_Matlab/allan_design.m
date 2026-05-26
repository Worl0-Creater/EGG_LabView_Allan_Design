%% ocxo_10MHz_allan_offline_validation.m
% -------------------------------------------------------------------------
% 10 MHz OCXO 输入源 Allan 方差 / Allan 偏差 MATLAB 离线验证脚本
%
% 适用对象：
%   1) FPGA 上升沿时间戳采集数据；
%   2) 10 MHz OCXO 输入源；
%   3) 离线验证 FPGA 实时 Allan 方差计算结果；
%   4) 本科论文 / 工程论文 / 期刊演示代码。
%
% 核心公式：
%   tau = m * tau0
%
%   sigma_y^2(tau) =
%       1 / [2 * tau^2 * (N - 2m)] *
%       sum_{i=1}^{N-2m} (x_{i+2m} - 2*x_{i+m} + x_i)^2
%
% 其中：
%   x_i   : 时间误差 / 相位时间偏差，单位 s
%   tau0  : 基本采样间隔，若每个 10 MHz 上升沿采一次，则 tau0 = 100 ns
%   m     : 平均因子
%   tau   : Allan 平均时间
%
% 注意：
%   - 本脚本采用 overlapping Allan deviation；
%   - 默认保留原始频率漂移影响；
%   - 若用于论文，建议同时说明“是否去趋势”和“时间戳分辨率”。
% -------------------------------------------------------------------------

clear; clc; close all;

%% ===================== 1. 用户配置区 =====================

script_dir = fileparts(mfilename('fullpath'));

cfg = struct();

% 输入 OCXO 标称频率
cfg.f0 = 10e6;                 % 10 MHz
cfg.T0 = 1 / cfg.f0;           % 100 ns

% FPGA 时间戳参考时钟
cfg.f_ref = 50e6;              % ZYNQ-7020 板载 50 MHz
cfg.T_ref = 1 / cfg.f_ref;     % 20 ns

% 输入 CSV 文件
% 如果文件不存在，脚本会自动生成一组演示数据，方便先验证流程。
cfg.csv_file = fullfile(script_dir, "ocxo_sim_time_error.csv");
% cfg.csv_file = "fpga_ocxo_timestamp.csv";

% FPGA 时间戳计数器位宽
% 如果 timestamp_count 已经是 MATLAB 中连续展开后的绝对计数，可忽略。
cfg.counter_bits = 32;

% 是否处理计数器回绕
cfg.enable_counter_unwrap = true;

% 是否去除二次频率漂移
% false：保留 OCXO 长期漂移，适合展示真实测量结果；
% true ：去除 x(t) 中二次项，适合只观察短稳噪声。
cfg.remove_quadratic_drift = false;

% 是否对边沿序列抽取
% 例如每 1000 个 10 MHz 周期取一个点，则有效 tau0 = 1000 / 10 MHz = 100 us。
% 注意：抽取会丢失小 tau 信息。
cfg.edge_decimation = 1;

% Allan 计算中最少有效二阶差分数量
% 太少的点对应置信度很差，论文图中建议不要使用。
cfg.min_num_pairs = 20;

% m 的最大值比例
% N 为时间误差序列长度，要求 N - 2m > min_num_pairs。
cfg.max_m_fraction = 0.20;

% m 取值方式
% true  : 对数间隔，适合论文画 log-log Allan 曲线；
% false : 使用 1,2,3,... 连续 m，计算量较大。
cfg.use_log_m = true;

% 输出文件
cfg.out_csv = fullfile(script_dir, "allan_result_10MHz_OCXO.csv");
cfg.out_fig = fullfile(script_dir, "allan_deviation_10MHz_OCXO.png");


%% ===================== 2. 读取或生成数据 =====================

if isfile(cfg.csv_file)
    fprintf("[INFO] 读取输入文件：%s\n", cfg.csv_file);
    data = readtable(cfg.csv_file);
else
    fprintf("[WARN] 未找到输入文件：%s\n", cfg.csv_file);
    fprintf("[INFO] 自动生成一组 10 MHz OCXO 演示数据，用于验证脚本流程。\n");

    demo_N = 200000;           % 演示点数
    data = generate_demo_ocxo_data(demo_N, cfg);
    writetable(data, cfg.csv_file);
    fprintf("[INFO] 已生成演示 CSV：%s\n", cfg.csv_file);
end


%% ===================== 3. 构造时间误差 x_k =====================

[x_s, tau0_eff, meta] = build_time_error_sequence(data, cfg);

% 去除 NaN / Inf
valid = isfinite(x_s);
x_s = x_s(valid);

% 可选边沿抽取
if cfg.edge_decimation > 1
    x_s = x_s(1:cfg.edge_decimation:end);
    tau0_eff = tau0_eff * cfg.edge_decimation;
end

N = numel(x_s);

if N < 100
    error("有效时间误差点数太少：N = %d。请检查输入 CSV。", N);
end

fprintf("\n========== 数据摘要 ==========\n");
fprintf("输入标称频率 f0        : %.6f MHz\n", cfg.f0 / 1e6);
fprintf("FPGA 参考时钟 f_ref    : %.6f MHz\n", cfg.f_ref / 1e6);
fprintf("FPGA 时间戳分辨率      : %.3f ns\n", cfg.T_ref * 1e9);
fprintf("有效采样间隔 tau0_eff  : %.3e s\n", tau0_eff);
fprintf("有效数据点数 N         : %d\n", N);
fprintf("数据来源               : %s\n", meta.source_type);

if strcmp(meta.source_type, "timestamp_count")
    fprintf("时间戳首值             : %.0f tick\n", meta.first_count);
    fprintf("时间戳末值             : %.0f tick\n", meta.last_count);
end

% 去除常数项和一次项不会影响 Allan 方差，主要用于改善数值显示
t = (0:N-1).' * tau0_eff;
p1 = polyfit(t, x_s, 1);
x_detrend_linear = x_s - polyval(p1, t);

if cfg.remove_quadratic_drift
    p2 = polyfit(t, x_detrend_linear, 2);
    x_used = x_detrend_linear - polyval(p2, t);
    drift_note = "quadratic drift removed";
else
    x_used = x_detrend_linear;
    drift_note = "linear offset removed only";
end

fprintf("去趋势方式             : %s\n", drift_note);


%% ===================== 4. 计算 overlapping Allan deviation =====================

[tau, avar, adev, num_pairs, m_list] = overlapping_adev_from_phase( ...
    x_used, tau0_eff, cfg.min_num_pairs, cfg.max_m_fraction, cfg.use_log_m);

% 计算近似误差条
% 说明：这是工程演示级近似，不等价于严格噪声类型相关置信区间。
adev_std_approx = adev ./ sqrt(num_pairs);


%% ===================== 5. 结果导出 =====================

result = table();
result.m = m_list(:);
result.tau_s = tau(:);
result.allan_variance = avar(:);
result.allan_deviation = adev(:);
result.num_pairs = num_pairs(:);
result.adev_std_approx = adev_std_approx(:);

writetable(result, cfg.out_csv);
fprintf("\n[INFO] Allan 结果已导出：%s\n", cfg.out_csv);


%% ===================== 6. 画图 =====================

figure("Color", "w");

loglog(tau, adev, "o-", "LineWidth", 1.2, "MarkerSize", 4);
grid on;
xlabel("\tau / s", "Interpreter", "tex");
ylabel("\sigma_y(\tau)", "Interpreter", "tex");
title("10 MHz OCXO Overlapping Allan Deviation", "Interpreter", "none");

subtitle_text = sprintf( ...
    "f0 = %.3f MHz, f_{ref} = %.3f MHz, tau0 = %.3e s, N = %d, %s", ...
    cfg.f0/1e6, cfg.f_ref/1e6, tau0_eff, N, drift_note);

subtitle(subtitle_text, "Interpreter", "tex");

set(gca, "FontName", "Times New Roman", "FontSize", 11);

exportgraphics(gcf, cfg.out_fig, "Resolution", 300);
fprintf("[INFO] Allan 曲线已导出：%s\n", cfg.out_fig);


%% ===================== 7. 基本一致性检查 =====================

fprintf("\n========== Allan 结果预览 ==========\n");
disp(result(1:min(10, height(result)), :));

fprintf("\n========== 工程提醒 ==========\n");
fprintf("1. 若 FPGA 只使用 50 MHz 时间戳直接采 10 MHz 上升沿，单点时间量化为 20 ns。\n");
fprintf("2. 10 MHz 周期为 100 ns，仅 5 个 50 MHz tick，原始周期分辨率较粗。\n");
fprintf("3. 因此该脚本可严谨验证 Allan 算法链路，但若要表征高性能 OCXO 的真实短稳，建议使用更高分辨率计时链路、门控计数、TDC 或相位比较方案。\n");
fprintf("4. FPGA 在线结果应与本脚本在相同 tau0、相同 m、相同去趋势策略下比较。\n");


%% ========================================================================
%                              本地函数区
% ========================================================================

function data = generate_demo_ocxo_data(N, cfg)
    % 生成演示数据：模拟 10 MHz OCXO 上升沿时间戳
    %
    % 注意：
    %   该函数只用于验证处理流程，不代表真实 OCXO 噪声模型。
    %   真实投稿数据应来自 FPGA / 频率计 / 相位噪声仪 / 时间间隔计。

    f0 = cfg.f0;
    T0 = 1 / f0;

    k = (0:N-1).';

    % 构造简单分数频率噪声
    % white FM 量级，演示用
    rng(1);
    sigma_y_white = 2e-10;
    y_white = sigma_y_white * randn(N, 1);

    % 加一点慢漂移，演示 OCXO 长期漂移趋势
    drift_rate = 2e-13;  % 每秒量级，演示值
    t = k * T0;
    y_drift = drift_rate * t;

    y = y_white + y_drift;

    % 由分数频率积分得到时间误差 x(t)
    x_s = cumsum(y) * T0;

    % 理想上升沿时间 + 时间误差
    timestamp_s = k * T0 + x_s;

    % 量化到 FPGA 参考时钟 tick
    timestamp_count = round(timestamp_s / cfg.T_ref);

    data = table();
    data.edge_index = k;
    data.timestamp_count = timestamp_count;
end


function [x_s, tau0_eff, meta] = build_time_error_sequence(data, cfg)
    % 从 CSV 表构造时间误差 x_k，单位 s

    names = string(data.Properties.VariableNames);
    names_lower = lower(names);

    meta = struct();

    if any(names_lower == "time_error_s")
        col = names(names_lower == "time_error_s");
        x_s = data.(col);
        x_s = double(x_s(:));

        if any(names_lower == "time_s")
            t_col = names(names_lower == "time_s");
            t_s = double(data.(t_col));
            tau0_eff = median(diff(t_s));
        else
            tau0_eff = cfg.T0;
        end

        meta.source_type = "time_error_s";

    elseif any(names_lower == "timestamp_count")
        col = names(names_lower == "timestamp_count");
        count_raw = double(data.(col));
        count_raw = count_raw(:);

        if cfg.enable_counter_unwrap
            count = unwrap_counter(count_raw, cfg.counter_bits);
        else
            count = count_raw;
        end

        t_meas = count * cfg.T_ref;

        % 理想 10 MHz 上升沿时间
        k = (0:numel(t_meas)-1).';
        t_ideal = k * cfg.T0;

        % 时间误差 x_k
        x_s = t_meas - t_ideal;

        tau0_eff = cfg.T0;
        meta.source_type = "timestamp_count";
        meta.first_count = count(1);
        meta.last_count = count(end);

    elseif any(names_lower == "period_count")
        col = names(names_lower == "period_count");
        period_count = double(data.(col));
        period_count = period_count(:);

        period_s = period_count * cfg.T_ref;

        % 相邻周期误差 e_i = T_i - T0
        period_error_s = period_s - cfg.T0;

        % 时间误差 x_k 是周期误差的累积
        x_s = [0; cumsum(period_error_s)];

        tau0_eff = cfg.T0;
        meta.source_type = "period_count";

    else
        error("CSV 中未找到支持的列名。需要 timestamp_count、period_count 或 time_error_s。");
    end
end


function count_unwrapped = unwrap_counter(count_raw, counter_bits)
    % 处理无符号计数器回绕
    %
    % 输入：
    %   count_raw     : 原始计数值
    %   counter_bits  : 计数器位宽
    %
    % 输出：
    %   count_unwrapped : 展开后的连续计数值

    modulus = 2^counter_bits;
    count_raw = double(count_raw(:));

    d = diff(count_raw);

    % 假设正常相邻差值远小于 modulus/2
    wrap_pos = d < -modulus/2;
    wrap_neg = d >  modulus/2;

    correction = zeros(size(count_raw));
    correction(2:end) = cumsum(wrap_pos) * modulus - cumsum(wrap_neg) * modulus;

    count_unwrapped = count_raw + correction;
end


function [tau, avar, adev, num_pairs, m_list] = overlapping_adev_from_phase( ...
    x_s, tau0, min_num_pairs, max_m_fraction, use_log_m)

    % 使用时间误差 x_s 计算 overlapping Allan variance / deviation
    %
    % 公式：
    %   sigma_y^2(tau) =
    %       sum( x(i+2m) - 2x(i+m) + x(i) )^2
    %       / [ 2 * (m*tau0)^2 * (N - 2m) ]

    x_s = double(x_s(:));
    N = numel(x_s);

    max_m_by_fraction = floor(N * max_m_fraction);
    max_m_by_pairs = floor((N - min_num_pairs) / 2);
    max_m = max(1, min(max_m_by_fraction, max_m_by_pairs));

    if max_m < 1
        error("数据点数不足，无法计算 Allan deviation。N = %d", N);
    end

    if use_log_m
        raw_m = unique(round(logspace(0, log10(max_m), 80)));
        m_list = raw_m(raw_m >= 1);
    else
        m_list = (1:max_m).';
    end

    tau = zeros(numel(m_list), 1);
    avar = zeros(numel(m_list), 1);
    adev = zeros(numel(m_list), 1);
    num_pairs = zeros(numel(m_list), 1);

    for idx = 1:numel(m_list)
        m = m_list(idx);

        d2 = x_s(1+2*m:end) - 2*x_s(1+m:end-m) + x_s(1:end-2*m);

        M = numel(d2);
        tau_i = m * tau0;

        avar_i = sum(d2.^2) / (2 * tau_i^2 * M);
        adev_i = sqrt(avar_i);

        tau(idx) = tau_i;
        avar(idx) = avar_i;
        adev(idx) = adev_i;
        num_pairs(idx) = M;
    end

    valid = isfinite(adev) & adev > 0 & num_pairs >= min_num_pairs;

    tau = tau(valid);
    avar = avar(valid);
    adev = adev(valid);
    num_pairs = num_pairs(valid);
    m_list = m_list(valid);
end