# Monitoring

轻量级 macOS 菜单栏系统监控（Apple Silicon / Intel 通用，无第三方依赖，单文件 Swift）。

菜单栏显示 5 个**相互独立**的状态项，各自可单独 Cmd+拖动排序、拖出菜单栏移除（位置与可见性自动记忆），但同属一个应用：

```
24%   79%   44%   61°C   ↑60.4 K/s
CPU   MEM   SSD   SEN    ↓9.2 K/s
```

- **CPU**：总体使用率（`host_statistics`，无堆分配）
- **MEM**：口径与活动监视器「已使用内存」一致（App 内存 + 联动 + 被压缩）
- **SSD**：启动卷已用百分比（可清除空间按可用计，与访达一致）
- **SEN**：CPU 温度传感器平均值（直接读 SMC，自动适配 M1–M4 的 Tp/Te/Tf 键；Intel 回退 TC0P）
- **↑/↓**：网络上/下行速率。统计 en*（物理网卡）与 utun*/ipsec*（VPN/代理隧道）两组接口，
  每个方向取两组的较大值：走代理时同一流量在两层各记一次，取 max 避免翻倍；
  macOS 26 的 Wi-Fi 新数据通路不再维护物理网卡的入站字节计数（`netstat -ib` 的 en0
  Ibytes 恒为 0），此时下行自动落到隧道接口的数值。计数按接口做模 2³² 差分，回绕不出错。

各状态项宽度随内容自适应，不留多余空隙；块与块之间的间隔是 macOS 的系统级菜单栏间距（所有应用一致）。

## 低资源占用设计

- 默认 2 秒刷新一次，带 500ms leeway 允许系统合并定时器唤醒（`Sources/main.swift` 中 `Config.interval` 可调）
- 息屏/锁屏自动暂停采样，亮屏恢复；全部状态项被拖出菜单栏时不采样
- 磁盘用量每 30 秒才查一次（变化慢）
- 数值未变化的块跳过重绘
- 无 Dock 图标（LSUIElement），纯 AppKit 手绘视图，无 SwiftUI 运行时开销

## 构建与安装

```sh
./build.sh
rm -rf /Applications/Monitoring.app && cp -R build/Monitoring.app /Applications/
open /Applications/Monitoring.app
```

应用带图标（CPU 芯片 + 活动波形），安装后可在「应用程序」文件夹 / 启动台中找到。

开机自启动：点击任意菜单栏状态项 → 勾选「开机自启动」（也可在 系统设置 → 通用 → 登录项 中添加）。

退出：点击任意一个状态项 → 退出。若全部状态项都被拖出菜单栏，重新打开应用会自动恢复显示。

网络测速：点击任意状态项 → 网络测速，弹窗依次测试延迟（Cloudflare ping 3 次平均）、下行（10MB）、上行（5MB），完成后结果停留 5 秒自动关闭。

图标源文件在 `tools/makeicon.swift`，重新生成：`swift tools/makeicon.swift . && iconutil -c icns AppIcon.iconset -o AppIcon.icns`。
