%% ============================================================
%  gen_waveform_table_v1.m
%
%  功能：
%  1. 生成任意波形播表；
%  2. 导出 LabVIEW 易解析 CSV 文件；
%  3. 导出 FPGA / DAC 可用 HEX LUT 文件；
%
%  推荐用途：
%  MATLAB 生成信号源 → LabVIEW 读取显示 → FPGA/DAC 播表验证
%
%  作者：WenTongXue Project
%% ============================================================

clear; clc; close all;

%% ===================== 用户配置区 =====================

cfg.waveform = "sine";          % 可选："sine" / "square" / "triangle" / "sawtooth" / "multi_sine" / "custom"

cfg.sample_count = 512;         % 播表点数，建议 256 / 512 / 1024
cfg.output_frequency_hz = 100;  % 播放出来的目标波形频率
cfg.sample_rate_hz = cfg.sample_count * cfg.output_frequency_hz;

cfg.bits = 8;                   % DAC / LUT 位宽，8 表示 0~255
cfg.unsigned_output = true;     % true：输出 0~255；false：预留给有符号格式

cfg.amplitude = 1.0;            % 归一化幅值，建议 0~1
cfg.dc_offset = 0.0;            % 归一化直流偏置，通常为 0

cfg.csv_filename = "waveform_labview.csv";
cfg.hex_filename = "waveform_lut_hex.txt";

% 多音信号配置，仅在 cfg.waveform = "multi_sine" 时使用
cfg.multi_freq_ratio = [1, 3, 5];       % 相对基波的倍频
cfg.multi_amp        = [1, 0.3, 0.15];  % 各频率分量幅度

% 自定义波形，仅在 cfg.waveform = "custom" 时使用
% 输入 phase_norm，范围 [0, 1)
% 输出建议范围 [-1, 1]
custom_func = @(phase_norm) sin(2*pi*phase_norm) + 0.3*sin(2*pi*3*phase_norm);

%% ===================== 生成时间轴与相位 =====================

N  = cfg.sample_count;
fs = cfg.sample_rate_hz;
f0 = cfg.output_frequency_hz;

index = (0:N-1).';
time_s = index / fs;
phase_norm = index / N;     % 归一化相位，0 到 1，不包含 1

%% ===================== 生成归一化波形 =====================

switch lower(cfg.waveform)

    case "sine"
        x = sin(2*pi*phase_norm);

    case "square"
        x = ones(N, 1);
        x(phase_norm >= 0.5) = -1;

    case "triangle"
        % 三角波，范围 [-1, 1]
        x = 4 * abs(phase_norm - floor(phase_norm + 0.5)) - 1;

    case "sawtooth"
        % 锯齿波，范围 [-1, 1]
        x = 2 * phase_norm - 1;

    case "multi_sine"
        x = zeros(N, 1);
        for k = 1:length(cfg.multi_freq_ratio)
            x = x + cfg.multi_amp(k) * sin(2*pi*cfg.multi_freq_ratio(k)*phase_norm);
        end

        % 防止多音叠加后超过 [-1, 1]
        max_abs = max(abs(x));
        if max_abs > 0
            x = x / max_abs;
        end

    case "custom"
        x = custom_func(phase_norm);
        x = x(:);

        max_abs = max(abs(x));
        if max_abs > 0
            x = x / max_abs;
        end

    otherwise
        error("未知波形类型：%s", cfg.waveform);
end

%% ===================== 幅值与偏置处理 =====================

amplitude_norm = cfg.amplitude * x + cfg.dc_offset;

% 限幅到 [-1, 1]
amplitude_norm(amplitude_norm >  1) =  1;
amplitude_norm(amplitude_norm < -1) = -1;

%% ===================== 量化为 DAC 码值 =====================

code_max = 2^cfg.bits - 1;
code_min = 0;
code_mid = 2^(cfg.bits - 1);

if cfg.unsigned_output
    % [-1, 1] 映射到 [0, 2^bits - 1]
    code_dec = round((amplitude_norm + 1) / 2 * code_max);
else
    error("当前脚本主线先冻结为 unsigned 输出，适合 8-bit DAC / HEX LUT。");
end

code_dec(code_dec > code_max) = code_max;
code_dec(code_dec < code_min) = code_min;

%% ===================== 转换为 HEX 字符串 =====================

hex_width = ceil(cfg.bits / 4);
code_hex = strings(N, 1);

for i = 1:N
    code_hex(i) = upper(dec2hex(code_dec(i), hex_width));
end

%% ===================== 导出 LabVIEW 友好的 CSV =====================

fid = fopen(cfg.csv_filename, "w");

if fid < 0
    error("无法创建 CSV 文件：%s", cfg.csv_filename);
end

fprintf(fid, "# CSV_WAVEFORM_V1\n");
fprintf(fid, "# source=MATLAB\n");
fprintf(fid, "# waveform=%s\n", cfg.waveform);
fprintf(fid, "# signal_type=waveform_playback_table\n");
fprintf(fid, "# sample_count=%d\n", cfg.sample_count);
fprintf(fid, "# sample_rate_hz=%.12g\n", cfg.sample_rate_hz);
fprintf(fid, "# output_frequency_hz=%.12g\n", cfg.output_frequency_hz);
fprintf(fid, "# bits=%d\n", cfg.bits);
fprintf(fid, "# code_format=uint%d\n", cfg.bits);
fprintf(fid, "# code_min=%d\n", code_min);
fprintf(fid, "# code_mid=%d\n", code_mid);
fprintf(fid, "# code_max=%d\n", code_max);
fprintf(fid, "# x_unit=s\n");
fprintf(fid, "# y_unit=code\n");
fprintf(fid, "# columns=index,time_s,phase_norm,amplitude_norm,code_dec,code_hex\n");

fprintf(fid, "index,time_s,phase_norm,amplitude_norm,code_dec,code_hex\n");

for i = 1:N
    fprintf(fid, "%d,%.12f,%.12f,%.12f,%d,%s\n", ...
        index(i), time_s(i), phase_norm(i), amplitude_norm(i), code_dec(i), code_hex(i));
end

fclose(fid);

%% ===================== 导出 FPGA / DAC HEX LUT =====================

fid = fopen(cfg.hex_filename, "w");

if fid < 0
    error("无法创建 HEX 文件：%s", cfg.hex_filename);
end

for i = 1:N
    fprintf(fid, "%s\n", code_hex(i));
end

fclose(fid);

%% ===================== 本地预览 =====================

figure;
plot(time_s, amplitude_norm, "-o");
grid on;
xlabel("Time / s");
ylabel("Normalized Amplitude");
title("Generated Waveform");

figure;
plot(time_s, code_dec, "-o");
grid on;
xlabel("Time / s");
ylabel("DAC Code");
title("Quantized Waveform Code");

%% ===================== 命令行提示 =====================

fprintf("\n生成完成。\n");
fprintf("LabVIEW CSV 文件：%s\n", cfg.csv_filename);
fprintf("FPGA HEX LUT 文件：%s\n", cfg.hex_filename);
fprintf("波形类型：%s\n", cfg.waveform);
fprintf("采样点数：%d\n", cfg.sample_count);
fprintf("采样率：%.6f Hz\n", cfg.sample_rate_hz);
fprintf("输出波形频率：%.6f Hz\n", cfg.output_frequency_hz);
fprintf("量化位宽：%d bit\n", cfg.bits);
fprintf("码值范围：%d ~ %d\n", code_min, code_max);