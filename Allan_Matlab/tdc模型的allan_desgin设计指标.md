目标：高分辨率理论 TDC 测量链路，用于 Allan VI 算法验证，不代表真实下位机硬件。

采样间隔 tau0:
  10 ms

TDC 时间分辨率 LSB:
  推荐值：10 ps


TDC 随机 jitter RMS:
  推荐值：5 ps

TDC 总时间误差 RMS:
  推荐目标：<= 6 ps
  激进目标：<= 3 ps
  极限理想目标：<= 1.5 ps

误差模型:

  x_meas = x_true + uniform(-LSB/2, +LSB/2) + N(0, sigma_jitter)

总 RMS 校验:
  sigma_total = sqrt(LSB^2 / 12 + sigma_jitter^2)