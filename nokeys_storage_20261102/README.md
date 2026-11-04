# 稳视 · 20261102 版工程与正式报告

本包对应 `calibrated_6mm_nokeys_storage_20261102`。

- 工程：`project/HDMI_DDR3_OV5640_test_720p60_pipeline.pds`
- 位流：`project/fisheye5_calibrated_6mm_nokeys_storage_20261102.sbit`
- 网页：`project/比赛版_启动网页.cmd`
- 重建：`project/比赛版_重建固件.cmd`
- 最终报告：`reports/`

## 最终报告

| 文件 | 内容 |
|---|---|
| synthesis.snr | 本版综合报告 |
| device_map.dmr | 本版技术映射报告 |
| place_route.prr | 本版最终布局布线资源报告 |
| timing_final.rtr | 本版最终独立时序报告 |
| build_result.json | 对应该位流的构建记录 |
| io_audit.json | 保留引脚位置与电气属性核对 |
| release_summary.json | 本次整理的版本与文件核对 |

布局布线结果：LUT 24,331；FF 28,999；DRM 32；APM 58；分布式 RAM 426。
最终时序为 All Constraints Met。源位流 SHA256：`788e841d71df6e9eb3a959c987d022fd7817b8095d4668b9d90ab3e0bb388229`。

## 工程使用

保持解压后的目录结构。PDS 版本为 2022.2-SP6.4，目标 PG2L100H / FBG676 / -6。
工程路径采用英文文件夹名，源文件和 IP 全部保留，网页控制、模型及功能代码也随工程提供。
Python 依赖见 project/requirements_windows.txt、requirements_tools.txt；换电脑可先运行“比赛版_配置本机环境.cmd”。

重建脚本使用 `project/release_support/` 中的本版约束快照和校验记录，映射后恢复 25 处固定布局。
构建辅助脚本已适配精简目录，不再依赖历史源码或位流备份包。HDL、IP、固件、网页及主机功能代码未改动。
修改 HDL 后需重新仿真并更新对应源文件校验记录；本包附带的记录只对应所提供的源码。
本次为文件整理，没有新增上板验证。

完整性检查：用 Python 执行 project/check_package.py。运行或重建后生成的新文件不属于原始提交清单。
