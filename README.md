# Ethane-XVI-CH549

基于 **WCH CH549**（增强型 8051 内核）的 **Ethane-XVI** 16 键多功能宏键盘固件（Keil C51 工程）。

- **USB VID / PID**: `0x1A86` / `22660` (`0x5884`)
- **硬件配置**: 16 按键 + 1 摇杆（2 轴 ADC + 按压）+ 2 旋转编码器（含按压）+ 16 颗 WS2812 RGB + 系统状态 RGB + 蜂鸣器
- **多配置槽位**: 支持 8 套独立按键配置（每套 512B）与 8 套灯效配置（每套 256B）

---

## 目录结构

```text
Ethane-XVI-CH549/
├── Libraries/          # WCH CH549 外设驱动库（ADC/FlashRom/GPIO/PWM/Timer/DEBUG）
├── Project/
│   └── Ethane-XVI.uvproj   # Keil uVision C51 工程文件
├── User/
│   ├── main.c              # 主循环、外设初始化、版本号 FIRMWARE_VERSION
│   ├── CompositeHID.c/.h   # USB 复合 HID 设备与 Custom HID 通信协议
│   ├── BasicIO.c/.h        # 按键/旋钮/摇杆采样、XRAM 缓冲区布局、蜂鸣器
│   ├── ParaConfig.c/.h     # 异步 Flash 读写、全局参数管理与 Boot 跳转
│   ├── RgbDrv.c/.h         # WS2812 时序驱动与灯珠映射
│   ├── Diag.c/.h           # 看门狗与存储错误诊断统计
│   └── Alkane/             # 核心按键/摇杆/旋钮功能与灯效引擎
├── scripts/
│   ├── build.ps1           # 命令行无头构建 + 硬件内存边界校验
│   └── release.ps1         # 固件打包（dist/）+ Git tag 发布助手
├── README.md
└── CHANGELOG.md
```

---

## 构建与发布

### 环境要求
- Windows + **Keil C51**（uVision4 / `UV4.exe`）
- PowerShell 5.1 或 PowerShell 7+
- 烧录工具：**WCHISPTool**

构建脚本会自动探测常见 Keil 安装路径（`D:\Keil\UV4\UV4.exe`、`C:\Keil_v5\UV4\UV4.exe` 等），也可通过环境变量 `$env:KEIL_UV4` 或 `-Uv4Path` 指定。

### 本地一键构建

```powershell
# 增量编译 + 硬件内存边界检查
.\scripts\build.ps1

# 清理后全量重编
.\scripts\build.ps1 -Rebuild -Clean
```

构建脚本会在编译完成后自动解析 `Project/Listings/Ethane-XVI.map`，校验：
1. `CODE + CONST` 最高地址 `< 0xD800`（防止侵入诊断/配置 Flash 区）
2. 链接器分配的 `XDATA` 不越过 `0x0440`（防止覆盖 USB EP0/EP4 缓冲区），且全部 `XDATA <= 0x07FF`（CH549 2KB XRAM 上限）
3. `DATA` 使用量留足栈空间

产物位置：`Project/Output/Ethane-XVI.hex`（不纳入 Git 追踪）。

### 本地打包与发版

1. 修改 `User/main.c` 中的 `FIRMWARE_VERSION[4]` 以及文件头 `Version` 注释，并更新 `CHANGELOG.md`。
2. 提交所有源码修改：
   ```powershell
   git add -A
   git commit -m "Release v1.7.1.0"
   ```
3. 执行发布脚本：
   ```powershell
   # 仅在本地打包到 dist/v1.7.1.0/（适合发版前验证）
   .\scripts\release.ps1

   # 打包并创建 Git annotated tag (v1.7.1.0)
   .\scripts\release.ps1 -Tag

   # 打包、打 tag 并推送分支与 tag 到 origin
   .\scripts\release.ps1 -Tag -Push
   ```
4. 前往 GitHub Releases 新建对应 tag 的 Release，上传 `dist/vX.Y.Z.W/` 中的：
   - `Ethane-XVI-CH549-vX.Y.Z.W.hex`
   - `SHA256SUMS.txt`
   - 并将 `RELEASE_NOTES.md` 内容直接粘贴为发布说明。

---

## 硬件内存分区速查

### Flash 分区（64 KB）

| 地址范围 | 大小 | 用途 | 宏定义 |
| --- | ---: | --- | --- |
| `0x0000 ~ 0xD7FF` | 54 KB | 固件代码与常量（CODE + CONST） | 上限 `DATA_DIAG_BASE` |
| `0xD800 ~ 0xD9FF` | 512 B | 诊断统计数据（当前使用 64B） | `DATA_DIAG_BASE` |
| `0xDA00 ~ 0xDBFF` | 512 B | 全局参数（摇杆校准/消抖/旋钮倍频） | `DATA_GLOB_BASE` |
| `0xDC00 ~ 0xE3FF` | 2 KB | 8 套灯效配置（256B × 8） | `DATA_LIGHT_BASE` |
| `0xE400 ~ 0xF3FF` | 4 KB | 8 套按键配置（512B × 8，倒序存放，含 1KB DataFlash） | `DATA_CFG_BASE` (`0xF200`) |
| `0xF400 ~ 0xFFFF` | 3 KB | WCH BootLoader & ConfigInfo（不可触碰） | 系统保留 |

### XRAM 分区（2 KB，`0x0000 ~ 0x07FF`）

| 地址范围 | 大小 | 用途 |
| --- | ---: | --- |
| `0x0000 ~ 0x043F` | 1088 B | 链接器分配的普通 XDATA 变量与 `_XDATA_GROUP_` |
| `0x0440 ~ 0x04FF` | 192 B | `Ep0Buffer`（EP0 + EP4 OUT + EP4 IN，共用 `UEP0_DMA`） |
| `0x0500 ~ 0x057F` | 128 B | `Ep1Buffer`（Custom HID EP1 OUT + IN） |
| `0x0580 ~ 0x05BF` | 64 B | `Ep2Buffer`（主 HID EP2 IN） |
| `0x05C0 ~ 0x05FF` | 64 B | `Ep3Buffer`（触摸 HID EP3 IN） |
| `0x0600 ~ 0x07FF` | 512 B | `FlashBuf`（Flash 读写缓冲） |

---

## USB 接口与 Custom HID 协议速查

### USB 接口分配

| Interface | 端点 | 用途 |
| --- | --- | --- |
| `0` | EP2 IN (22B) | 主 HID（Report ID 1=键盘, 2=鼠标, 4=媒体, 5=Dial） |
| `1` | EP3 IN (7B) | 独立触摸/指针 HID（Report ID 3） |
| `2` | EP4 IN/OUT (64B) | RGB 实时同步接口（兼容 SignalRGB，帧头 `0xA5 0x5A 0x03`） |
| `3` | EP1 IN/OUT (64B) | Custom HID 配置与诊断命令通道 |

### Custom HID 命令（EP1，64 字节包）

正常响应首字节为 `'R'` + 命令后 3 字节；若主循环正在处理异步操作（如 Flash 擦写），返回 `RBSY`；未知命令返回 `RINV`。

| 命令 | 说明 |
| --- | --- |
| `DKBC` + `'1'~'8'` | 下发按键配置（后续 8 包 × 64B = 512B） |
| `DLTC` + `'1'~'8'` | 下发灯效配置（后续 4 包 × 64B = 256B） |
| `BRKC` + `'1'~'8'` + `pkg(0~15)` | 分块回读按键配置（32B/包，共 16 包） |
| `BRLC` + `'1'~'8'` + `pkg(0~7)` | 分块回读灯效配置（32B/包，共 8 包） |
| `BCSI` | 读取当前生效配置槽位（返回 `'1'~'8'`） |
| `BCSC` + `'1'~'8'` | 切换当前生效配置槽位 |
| `BFWV` | 读取 4 字节固件版本号 |
| `BUID` | 读取 6 字节芯片唯一序列号 |
| `BIPT` | 实时读取摇杆 ADC、旋钮计数与按键位图 |
| `BGPM` | 读取 56 字节全局参数区 |
| `BDGC` | 读取 56 字节诊断统计数据 |
| `CKYT` / `CRKM` / `CRKZ` / `CECD` | 设置按键消抖 / 摇杆中位 / 摇杆范围 / 旋钮倍频 |
| `BBUZ` / `BBTV` | 进入蜂鸣器模式 / 发送音符与音量 |
| `BRST` / `BBOT` | 软复位 / 擦除首扇区进入 ISP Bootloader 准备状态 |

---

## 调试宏说明

- 如需开启串口/端点定时监测调试（`debugBuf` / `tickStart` / `PrintTest`），可在 Keil 工程 `C51 -> Preprocessor Symbols -> Define` 中添加 `ETHANE_DEBUG_PRINT`。默认关闭以节省 64B XRAM 与 6B DATA。
