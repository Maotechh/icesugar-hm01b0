# iCESugar HM01B0

由 **[Maotechh](https://github.com/Maotechh)** 维护的开源 FPGA 摄像头采集项目。
使用 **iCESugar v1.5 / iCE40UP5K-SG48** 读取 **16-pin Arducam HM01B0**，
在 **NVIDIA DGX Spark / Ubuntu 24.04 ARM64** 上完成综合、布局布线、烧录和图像接收。

[English](README.md) · [接线表](docs/wiring.md) · [工具链安装](docs/toolchain.md) ·
[验证记录](docs/validation.md) · [串口协议](docs/protocol.md)

## 项目内容

- Verilog 实现 I2C 配置、四位像素拼接、行帧检查、128 KiB SPRAM 缓冲和串口发送。
- 主机只用 Python 标准库，输出 RAW、JSON、320×240 PNG/PGM，无需 pip。
- 使用 Yosys、nextpnr-ice40、IceStorm；无 GUI、IDE、SoC 框架或 Python HDL。
- 使用 Yosys CXXRTL 和系统 C++ 编译器测试，无需额外仿真器。

这是**单帧采集**，不是实时视频：115200 波特率传输一帧约需 7 秒。
传输期间传感器仍可能输出帧，但 FPGA 不采集这些中间帧。

## 快速使用

先核对[接线和电压说明](docs/wiring.md)，再按[安装文档](docs/toolchain.md)安装基础构建依赖。
摄像头 **D1 接 P2_1（FPGA 46 脚）**，两个 UART 跳帽均需安装。
**模组自带 24 MHz 晶振，FPGA 不可驱动 XCLK。** VCC 接 3.3 V，I2C 不另加 3.3 V 上拉。

```sh
git clone https://github.com/Maotechh/icesugar-hm01b0.git
cd icesugar-hm01b0
make toolchain
make all
make test
```

默认从锁定版本的源码构建 ARM64 工具，安装到项目 `work/toolchain`，不覆盖系统工具。
布局布线使用 `--up5k --package sg48 --freq 48`，时序失败会中止。

确认 iCELink 挂载点后烧录，**此板内置烧录器不是 FTDI iceprog**：

```sh
ICELINK_MOUNT="/media/$(id -un)/iCELink"
findmnt --mountpoint "$ICELINK_MOUNT"
# 仅在确认上面的挂载点确为 iCELink 后继续。
cp build/camera.bin "$ICELINK_MOUNT/camera.bin"
sync -f "$ICELINK_MOUNT"
```

必须等复制和同步完成，确认卷内没有 `FAIL.TXT`，再运行串口命令。
不同桌面环境的挂载路径可能不同。烧录完成后虚拟磁盘中的 `.bin` 消失属于正常现象。

先跑测试图案，再拍真实图像：

```sh
python3 host/camera.py status
python3 host/camera.py probe
python3 host/camera.py configure --pattern walking
python3 host/camera.py capture --mode 0 --walking --count 10
python3 host/camera.py configure --pattern image
python3 host/camera.py capture --mode 0 --count 1
python3 host/camera.py standby
```

图片保存在 `outputs/时间戳/`。存在异常时保留 RAW/JSON、返回错误并停止，不静默丢帧或重试。
有多个串口时，用 `python3 host/camera.py --port /dev/ttyACM0 status` 显式指定。
请通过系统串口权限机制获得访问权限，不要用 `sudo` 采图或将设备改成全员可写。

## 已验证范围

现有固件完成测试图案逐字节检查、真实画面检查、待机恢复、错误边沿拒收、毛刺注入仿真和
48 MHz 时序检查。具体数量和固件散列见[验证记录](docs/validation.md)。
实拍中未见错行、撕裂或像素块错位，但仍可能有噪声和局部过曝。

当前仅验证了与 UC-805/B0315 原理图匹配的模组。`0x1012=0` 用于消除同步偏移；
`0x3052` 写 `0x50` 后读 `0xD0` 是实测模组行为，不代表所有版本均相同。
PCLK 保持不超过 6 MHz。CRC 校验覆盖 FPGA 到主机链路，不是任意电气故障的保证。

## 参与贡献

欢迎在 [Maotechh/icesugar-hm01b0](https://github.com/Maotechh/icesugar-hm01b0)
提交 Issue、兼容性测试结果或 PR。请提供板卡版本、工具版本、复现命令，并区分仿真和实测。
不要上传私人照片、凭据或本机标识。详见 [贡献指南](CONTRIBUTING.md)。

项目使用 [MIT 许可证](LICENSE)，保留 [OpenMV 原始许可](LICENSES/OpenMV.txt)。
