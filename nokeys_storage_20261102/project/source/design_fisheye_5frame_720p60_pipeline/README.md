# 720p60 标定版：固定曝光、四银行映射和 KEY0

本目录由项目根目录的 `HDMI_DDR3_OV5640_test_720p60_calibrated.pds` 使用。

已保留真实标定、五帧 DDR、A/B 图块缓存和 RGB565 双线性插值。
KEY0 为 C22、低电平有效，20 ms 消抖，RAW/COR/SPL 在 HDMI 帧边界切换。
同帧原图和矫正图成对锁定，避免采集覆盖正在显示的原始图。

详细操作见项目根目录的 `KEY0_DISPLAY_GUIDE.md`；
采集参数、映射和计时见 `UPGRADE_720P60_FIXED_BANKED.md`。
