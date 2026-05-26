%% gen_ocxo_sim_csv.m
% -------------------------------------------------------------------------
% CTI OSC5A2B02 10 MHz OCXO 仿真时间误差数据生成
%
% 输出：ocxo_sim_time_error.csv（方案A格式）+ metadata.json
% 用途：MATLAB Allan 偏差算法前仿真验证（本科毕设）
%
% 噪声模型：5 类功率律噪声 + 线性频率漂移
%   S_y(f) = h2*f^2 + h1*f + h0 + h_{-1}/f + h_{-2}/f^2
%
% Allan 偏差斜率对应关系：
%   White PM     → σ_y(τ) ∝ τ^{-1}
%   Flicker PM   → σ_y(τ) ∝ τ^{-1}  （本脚本合并入 White PM）
%   White FM     → σ_y(τ) ∝ τ^{-1/2}
%   Flicker FM   → σ_y(τ) ∝ τ^0     （flicker floor）
%   Random Walk  → σ_y(τ) ∝ τ^{+1/2}
%   Linear Drift → σ_y(τ) ∝ τ^{+1}
% -------------------------------------------------------------------------

clear; clc; close all;

script_dir = fileparts(mfilename('fullpath'));

%% ==================== 1. 仿真配置 ====================

f0      = 10e6;         % OCXO 标称频率 (Hz)
tau0    = 0.01;         % 采样间隔 (s)，10 ms
T_total = 10000;        % 总采集时长 (s)，约 2.8 小时
N       = round(T_total / tau0);

rng(42);                % 固定随机种子，保证结果可复现


%% ==================== 2. 噪声模型参数 ====================
% 所有参数均基于 CTI OSC5A2B02 datasheet 推导，来源标注在行尾。

% --- White FM: h0 ---
% datasheet: 短期稳定度 ≤ 0.05 ppb/s → σ_y(1s) ≈ 5e-11
% 关系：σ²_y(τ) = h0 / (2τ)
% 推导：h0 = 2τ × σ²_y(1s) = 2 × (5e-11)² = 5e-21
h0 = 5e-21;

% --- Flicker FM: h_{-1} ---
% 典型同等级 OCXO flicker floor σ_y ≈ 1e-11
% 关系：σ²_y = 2 ln(2) × h_{-1}
% 推导：h_{-1} = (1e-11)² / (2 × ln2) ≈ 7.2e-23
h_neg1 = 7.2e-23;

% --- Random Walk FM: h_{-2} ---
% 由相位噪声 1→10 Hz 区间 -40 dB/dec 斜率定性判定为 RWFM 主导。
% 选取保守值使 σ_y(1000s) RWFM 贡献约 2.6e-11。
% 关系：σ²_y(τ) = (2π²/3) × h_{-2} × τ
% 推导：h_{-2} = 3σ² / (2π²τ) ≈ 1e-25
h_neg2 = 1e-25;

% --- White PM: h2 ---
% datasheet: L(10 kHz) = -150 dBc/Hz
% 关系：S_φ = 2 × 10^(L/10) = 2e-15 rad²/Hz
%        h2 = S_φ / ν₀² = 2e-15 / (10e6)² = 2e-29
% Allan 贡献极小，包含仅为模型完整性。
h2 = 2e-29;

% --- 线性频率漂移 ---
% datasheet: 老化 ≤ 0.5 ppb/day（上电 30 天后 @ 25°C）
% D = Δy/Δt = 0.5e-9 / 86400 ≈ 5.79e-15 /s
D_drift = 0.5e-9 / 86400;


%% ==================== 3. 生成各噪声分量 ====================

t = (0:N-1).' * tau0;

% ---- (a) White FM ----
% y_wfm ~ N(0, h0/(2τ0))，x = cumsum(y) × τ0
sigma_wfm = sqrt(h0 / (2 * tau0));
y_wfm = sigma_wfm * randn(N, 1);
x_wfm = cumsum(y_wfm) * tau0;

% ---- (b) Flicker FM ----
% FFT 频域成形法：构造 S_y(f) = h_{-1}/f 的 y(t)，再积分得 x(t)
x_ffm = gen_flicker_fm_phase(N, tau0, h_neg1);

% ---- (c) Random Walk FM ----
% y_rwfm 是白噪声的累积和（布朗运动），再积分得 x
% 离散 PSD：S_y(f) ≈ σ²_step / (4π²f²τ0)
% 令其等于 h_{-2}/f²：σ_step = 2π√(h_{-2} × τ0)
sigma_rwfm_step = 2 * pi * sqrt(h_neg2 * tau0);
y_rwfm = cumsum(sigma_rwfm_step * randn(N, 1));
x_rwfm = cumsum(y_rwfm) * tau0;

% ---- (d) White PM ----
% 直接加在时间误差 x(t) 上，PSD 为常数 S_x(f) = h2/(4π²)
% σ_x = √(h2 × f_h / (2π²))，f_h = 1/(2τ0)
f_h = 1 / (2 * tau0);
sigma_x_wpm = sqrt(h2 * f_h / (2 * pi^2));
x_wpm = sigma_x_wpm * randn(N, 1);

% ---- (e) 线性频率漂移 ----
% y(t) = D × t → x(t) = D × t² / 2
x_drift = 0.5 * D_drift * t.^2;


%% ==================== 4. 合成总时间误差 ====================

x_total = x_wfm + x_ffm + x_rwfm + x_wpm + x_drift;


%% ==================== 4.5 数据质量检查 ====================

n_nan = sum(isnan(x_total));
n_inf = sum(isinf(x_total));
if n_nan > 0 || n_inf > 0
    error("[ERROR] 生成数据包含 %d 个 NaN 和 %d 个 Inf，请检查噪声参数。", n_nan, n_inf);
end
fprintf("[CHECK] NaN = %d, Inf = %d, 数据完整性通过。\n", n_nan, n_inf);


%% ==================== 5. 导出 CSV ====================

out = table();
out.sample_index = (0:N-1).';
out.time_s = t;
out.time_error_s = x_total;

csv_file = fullfile(script_dir, "ocxo_sim_time_error.csv");
writetable(out, csv_file);

fprintf("[INFO] 仿真 CSV 已生成：%s\n", csv_file);
fprintf("[INFO] 样本数 N = %d，总时长 = %.0f s，tau0 = %.1f ms\n", N, T_total, tau0*1e3);


%% ==================== 6. 导出 metadata.json ====================

meta = struct();
meta.device_under_test = struct( ...
    "type",                "OCXO", ...
    "model",               "CTI OSC5A2B02", ...
    "nominal_frequency_hz", f0, ...
    "warmup_time_min",     60, ...
    "data_source",         "simulation" ...
);
meta.reference_source = struct( ...
    "type",               "ideal (simulation)", ...
    "nominal_frequency_hz", f0, ...
    "allan_stability",    "perfect (no contribution)" ...
);
meta.noise_model = struct( ...
    "h2_white_pm",         h2, ...
    "h0_white_fm",         h0, ...
    "h_neg1_flicker_fm",   h_neg1, ...
    "h_neg2_rwfm",         h_neg2, ...
    "D_drift_per_s",       D_drift, ...
    "generation_method",   "time-domain (WFM/RWFM/WPM) + FFT spectral shaping (FFM)" ...
);
meta.measurement_chain = struct( ...
    "method",              "time_error_s", ...
    "fpga_ref_clock_hz",   "N/A (simulation, ideal sampling)", ...
    "time_resolution_s",   "unlimited (simulation)", ...
    "gate_time_s",         "N/A", ...
    "tdc_lsb_s",           "N/A" ...
);
meta.environment = struct( ...
    "temperature_c",       "25 (simulation, constant)", ...
    "power_supply",        "ideal (simulation)", ...
    "shielding",           "N/A (simulation)", ...
    "location",            "MATLAB simulation" ...
);
meta.data = struct( ...
    "csv_file",          csv_file, ...
    "format",            "sample_index, time_s, time_error_s", ...
    "sample_interval_s", tau0, ...
    "sample_count",      N, ...
    "total_duration_s",  T_total, ...
    "random_seed",       42 ...
);
meta.expected_allan_deviation = struct( ...
    "tau_0p01s", "~5e-10 (White FM dominant)", ...
    "tau_1s",    "~5e-11 (White FM)", ...
    "tau_10s",   "~2e-11 (transition to flicker floor)", ...
    "tau_100s",  "~1.5e-11 (flicker floor + RWFM rising)", ...
    "tau_1000s", "~2.8e-11 (RWFM dominant)" ...
);

json_str = jsonencode(meta, "PrettyPrint", true);
fid = fopen(fullfile(script_dir, "metadata.json"), "w");
fprintf(fid, "%s", json_str);
fclose(fid);

fprintf("[INFO] 元数据已导出：metadata.json\n");


%% ==================== 7. 诊断图 ====================

figure("Color", "w", "Position", [100 100 1200 800]);

subplot(3, 2, 1);
plot(t, x_wfm * 1e9, "Color", [0.2 0.4 0.8]);
title("White FM"); ylabel("x / ns"); grid on;

subplot(3, 2, 2);
plot(t, x_ffm * 1e9, "Color", [0.8 0.3 0.2]);
title("Flicker FM"); ylabel("x / ns"); grid on;

subplot(3, 2, 3);
plot(t, x_rwfm * 1e9, "Color", [0.1 0.6 0.3]);
title("Random Walk FM"); ylabel("x / ns"); grid on;

subplot(3, 2, 4);
plot(t, x_wpm * 1e15, "Color", [0.6 0.2 0.6]);
title("White PM"); ylabel("x / fs"); grid on;

subplot(3, 2, 5);
plot(t, x_drift * 1e9, "Color", [0.9 0.5 0.1]);
title("Linear Drift"); ylabel("x / ns"); xlabel("t / s"); grid on;

subplot(3, 2, 6);
plot(t, x_total * 1e9, "Color", [0 0 0]);
title("Total x(t)"); ylabel("x / ns"); xlabel("t / s"); grid on;

sgtitle(sprintf("CTI OSC5A2B02 仿真时间误差分量 (tau0=%.0fms, T=%.0fs)", ...
    tau0*1e3, T_total), "FontSize", 13);
exportgraphics(gcf, fullfile(script_dir, "sim_noise_components.png"), "Resolution", 200);
fprintf("[INFO] 噪声分量图已导出：sim_noise_components.png\n");


%% ==================== 8. 快速 Allan 验证 ====================

fprintf("\n========== 快速 Allan 验证 ==========\n");

p1 = polyfit(t, x_total, 1);
x_detrend = x_total - polyval(p1, t);

m_check = [1, 10, 100, 1000, 10000, 100000];
m_check = m_check(m_check < N/3);

fprintf("%10s  %12s  %12s\n", "tau (s)", "ADEV", "expected slope");
for idx = 1:numel(m_check)
    m = m_check(idx);
    tau_i = m * tau0;
    d2 = x_detrend(1+2*m:end) - 2*x_detrend(1+m:end-m) + x_detrend(1:end-2*m);
    M = numel(d2);
    adev_i = sqrt(sum(d2.^2) / (2 * tau_i^2 * M));
    fprintf("%10.3f  %12.3e  ", tau_i, adev_i);

    if idx > 1
        slope = log10(adev_i / adev_prev) / log10(tau_i / tau_prev);
        fprintf("slope = %+.2f", slope);
    end
    fprintf("\n");
    adev_prev = adev_i;
    tau_prev = tau_i;
end

fprintf("\n[INFO] 全部完成。请在 MATLAB 中运行 allan_design.m 进行完整 Allan 分析。\n");
fprintf("[INFO] allan_design.m 已配置为读取 ocxo_sim_time_error.csv。\n");


%% ========================================================================
%                              本地函数
% ========================================================================

function x_ffm = gen_flicker_fm_phase(N, tau0, h_neg1)
% FFT 频域成形法生成 Flicker FM 噪声对应的时间误差 x(t)
%
% 步骤：
%   1. 在频域构造 S_y(f) = h_{-1}/f 的分数频率噪声 y(t)
%   2. 对 y(t) 积分得到时间误差 x(t) = cumsum(y)*tau0
%
% 幅度推导：
%   PSD 定义：S_y(f_k) = 2τ0/N_fft × |Y[k]/N_fft|² × N_fft²  (MATLAB 单边)
%            → |Y[k]|² = S_y(f_k) × N_fft / (2τ0)
%   对 S_y = h_{-1}/f：|Y[k]| = √(h_{-1}/f_k × N_fft/(2τ0))

    N_fft = 2^nextpow2(2 * N);
    df    = 1 / (N_fft * tau0);
    n_pos = N_fft / 2 - 1;
    f     = (1:n_pos).' * df;

    A = sqrt(h_neg1 ./ f * N_fft / (2 * tau0));

    Z = (randn(n_pos, 1) + 1i * randn(n_pos, 1)) / sqrt(2);
    Y_pos = A .* Z;

    Y = zeros(N_fft, 1);
    Y(2:N_fft/2)         = Y_pos;
    Y(N_fft/2+2:N_fft)   = conj(Y_pos(end:-1:1));

    y = real(ifft(Y));
    y = y(1:N);

    x_ffm = cumsum(y) * tau0;
end
