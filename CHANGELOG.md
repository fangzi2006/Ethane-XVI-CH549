# Changelog

All notable changes to **Ethane-XVI-CH549** are documented in this file.

## [1.7.1.0] - 2026-11-24

### Added
- Custom HID 新增配置与状态回读命令：
  - `BCSI`：读取当前生效配置槽位（`'1'~'8'`）
  - `BRKC`：按 32B/包（共 16 包）分块回读指定槽位按键配置
  - `BRLC`：按 32B/包（共 8 包）分块回读指定槽位灯效配置
- Custom HID 新增忙状态保护 `RBSY`：当主循环正在执行异步操作（如 Flash 擦写）时拒绝新命令，防止覆盖 `FlashBuf` 与 `asyncFlag`。
- 新增本地一键构建脚本 `scripts/build.ps1`（支持 Keil UV4 无头编译与 CH549 Flash/XRAM 硬件边界自动校验）。
- 新增本地固件打包发布脚本 `scripts/release.ps1`（生成版本化 `.hex`、`SHA256SUMS.txt`、`RELEASE_NOTES.md` 及可选 Git tag）。
- 新增 `README.md`、`CHANGELOG.md` 与 `.gitattributes`。

### Fixed
- 为跨 USB 中断与主循环共享的 `asyncFlag` 添加 `volatile` 修饰，消除编译器优化隐患。
- 将未启用的调试变量 `debugBuf[64]` 及 `tickStart`/`tickEnd`/`tickDif` 隔离到 `#ifdef ETHANE_DEBUG_PRINT` 后，释放 64B XRAM 与 6B DATA。

### Changed
- 停止 Git 追踪 Keil 个人状态文件（`.uvopt` / `.uvgui.*` / `.21431`）与编译产物 `Project/Output/Ethane-XVI.hex`，改为通过脚本构建与 Release 分发。

## [1.7.0.1] - 2026-11-20

### Fixed
- 修复编码器、180° 旋转键位映射、Dial 与蜂鸣器相关问题。
