import AppKit
import IOKit
import ServiceManagement

// MARK: - 配置

enum Config {
    /// 刷新间隔（秒）。调大更省电，调小更灵敏。
    static let interval: TimeInterval = 2.0
    /// 磁盘用量每隔多少个刷新周期采样一次（磁盘变化慢，没必要每次都查）。
    static let diskEvery = 15
}

// MARK: - 四字符码工具

@inline(__always) func fourcc(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

func fourccString(_ v: UInt32) -> String {
    let b: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                      UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? ""
}

// MARK: - CPU 使用率（host_statistics，无内存分配）

let hostPort: host_t = mach_host_self()

final class CPUSampler {
    private var prev: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func sample() -> Double? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
                                          / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks 顺序：USER, SYSTEM, IDLE, NICE；计数器是 32 位累计值，
        // 必须先在 UInt32 域做模 2^32 差分再扩位，否则回绕时得到垃圾值
        let u = info.cpu_ticks.0, s = info.cpu_ticks.1
        let i = info.cpu_ticks.2, n = info.cpu_ticks.3
        defer { prev = (u, s, i, n) }
        guard let p = prev else { return nil }
        let du = UInt64(u &- p.user), ds = UInt64(s &- p.system)
        let di = UInt64(i &- p.idle), dn = UInt64(n &- p.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return nil }
        return Double(du + ds + dn) / Double(total) * 100.0
    }
}

// MARK: - 内存使用率（口径与活动监视器「已使用内存」一致）

let totalMemoryBytes: UInt64 = {
    var v: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &v, &len, nil, 0)
    return v
}()

func sampleMemory() -> Double? {
    guard totalMemoryBytes > 0 else { return nil }
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                      / MemoryLayout<integer_t>.stride)
    var vm = vm_statistics64_data_t()
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    // 口径与活动监视器「已使用内存」一致：App 内存（匿名页 − 可清除）+ 联动 + 被压缩
    let internalPages = UInt64(vm.internal_page_count)
    let purgeable = UInt64(vm.purgeable_count)
    let appPages = internalPages > purgeable ? internalPages - purgeable : 0
    let usedPages = appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
    let used = usedPages * UInt64(vm_page_size)
    return min(100.0, Double(used) / Double(totalMemoryBytes) * 100.0)
}

// MARK: - 磁盘使用率

func sampleDisk() -> Double? {
    let url = URL(fileURLWithPath: "/")
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                    .volumeAvailableCapacityForImportantUsageKey]),
          let total = v.volumeTotalCapacity, total > 0,
          let avail = v.volumeAvailableCapacityForImportantUsage
    else { return nil }
    return min(100.0, max(0.0, (1.0 - Double(avail) / Double(total)) * 100.0))
}

// MARK: - 网络速率（getifaddrs 累计字节差分）

final class NetSampler {
    /// 各接口上次的累计字节数（ifi_ibytes/ifi_obytes 是 32 位累计值，按接口做模 2^32 差分）
    private var prevCounters: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var prevTime: CFAbsoluteTime?

    /// 返回 (下行, 上行) 字节/秒
    func sample() -> (rx: Double, tx: Double)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            // en* 为物理网卡；utun*/ipsec* 为 VPN/代理隧道。
            // macOS 26 的 Wi-Fi 新数据通路（skywalk）不再把入站字节记入传统
            // if_data 计数器（netstat -ib 的 en0 Ibytes 恒为 0），而走代理时
            // 真实下行只在 utun 上可见，因此两组都要采。
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("ipsec")
            else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        let now = CFAbsoluteTimeGetCurrent()
        defer { prevCounters = current; prevTime = now }
        guard let pt = prevTime, now > pt else { return nil }
        var enRx: UInt64 = 0, enTx: UInt64 = 0
        var tunRx: UInt64 = 0, tunTx: UInt64 = 0
        var hasBaseline = false
        for (name, c) in current {
            guard let p = prevCounters[name] else { continue } // 新出现的接口本轮跳过
            hasBaseline = true
            let dr = UInt64(c.rx &- p.rx) // UInt32 环绕减法，回绕也能得到正确差值
            let dt = UInt64(c.tx &- p.tx)
            if name.hasPrefix("en") {
                enRx &+= dr; enTx &+= dt
            } else {
                tunRx &+= dr; tunTx &+= dt
            }
        }
        guard hasBaseline else { return nil }
        let dt = now - pt
        // 每个方向取物理网卡组与隧道组的较大值：走代理时同一流量会在两层各记
        // 一次（utun 明文 + en 密文），取 max 避免翻倍；en 的入站计数缺失时
        // 自动落到 utun 的数值；不开代理时 utun 无流量，回到 en 本身。
        return (Double(max(enRx, tunRx)) / dt, Double(max(enTx, tunTx)) / dt)
    }
}

// MARK: - SMC 温度传感器

/// 与内核 AppleSMC 用户客户端约定的 80 字节参数结构（字段展平并显式补齐，与 C 布局一致）。
struct SMCParamStruct {
    var key: UInt32 = 0            // 0
    var versMajor: UInt8 = 0       // 4
    var versMinor: UInt8 = 0       // 5
    var versBuild: UInt8 = 0       // 6
    var versReserved: UInt8 = 0    // 7
    var versRelease: UInt16 = 0    // 8
    var pad0: UInt16 = 0           // 10
    var pLimitVersion: UInt16 = 0  // 12
    var pLimitLength: UInt16 = 0   // 14
    var cpuPLimit: UInt32 = 0      // 16
    var gpuPLimit: UInt32 = 0      // 20
    var memPLimit: UInt32 = 0      // 24
    var keyInfoDataSize: UInt32 = 0      // 28
    var keyInfoDataType: UInt32 = 0      // 32
    var keyInfoDataAttributes: UInt8 = 0 // 36
    var pad1: UInt8 = 0            // 37
    var pad2: UInt8 = 0            // 38
    var pad3: UInt8 = 0            // 39
    var result: UInt8 = 0          // 40
    var status: UInt8 = 0          // 41
    var data8: UInt8 = 0           // 42
    var pad4: UInt8 = 0            // 43
    var data32: UInt32 = 0         // 44
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)  // 48...80
}

final class SMC {
    private static let selectorHandleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyFromIndex: UInt8 = 8
    private static let cmdGetKeyInfo: UInt8 = 9
    private static let typeFLT = fourcc("flt ")
    private static let typeSP78 = fourcc("sp78")

    private var conn: io_connect_t = 0
    /// 启动时发现的 CPU 温度键（key, 类型, 数据长度）
    private var tempKeys: [(key: UInt32, type: UInt32, size: UInt32)] = []

    init?() {
        // 布局不符时直接终止（precondition 在 -O 下仍然生效，assert 会被编译掉）
        precondition(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct 布局不是 80 字节")
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { return nil }
        discoverTempKeys()
        if tempKeys.isEmpty {
            IOServiceClose(conn)
            conn = 0 // 防止 deinit 对已释放的端口名二次 IOServiceClose
            return nil
        }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, Self.selectorHandleYPCEvent,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: UInt32) -> (type: UInt32, size: UInt32)? {
        var inp = SMCParamStruct()
        inp.key = key
        inp.data8 = Self.cmdGetKeyInfo
        guard let out = call(&inp) else { return nil }
        return (out.keyInfoDataType, out.keyInfoDataSize)
    }

    /// 枚举全部 SMC 键，收集 Apple Silicon 的 CPU 温度传感器（Tp/Te/Tf 前缀，flt 类型）；
    /// 若一个都没有（Intel 机型），回退到 TC0P。
    private func discoverTempKeys() {
        var count: UInt32 = 0
        do { // 读 #KEY 得到键总数
            let keyKEY = fourcc("#KEY")
            guard let info = keyInfo(keyKEY), info.size == 4 else { return }
            var inp = SMCParamStruct()
            inp.key = keyKEY
            inp.keyInfoDataSize = info.size
            inp.data8 = Self.cmdReadKey
            guard let out = call(&inp) else { return }
            let b = out.bytes
            count = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
        }
        for i in 0..<count {
            var inp = SMCParamStruct()
            inp.data8 = Self.cmdGetKeyFromIndex
            inp.data32 = i
            guard let out = call(&inp) else { continue }
            let key = out.key
            let name = fourccString(key)
            guard name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Tf")
            else { continue }
            guard let info = keyInfo(key), info.type == Self.typeFLT, info.size == 4
            else { continue }
            tempKeys.append((key, info.type, info.size))
        }
        if tempKeys.isEmpty { // Intel 回退
            let tc0p = fourcc("TC0P")
            if let info = keyInfo(tc0p), info.type == Self.typeSP78, info.size == 2 {
                tempKeys.append((tc0p, info.type, info.size))
            }
        }
    }

    /// CPU 各温度传感器的平均值（摄氏度）
    func readCPUTemperature() -> Double? {
        var sum = 0.0
        var n = 0
        for (key, type, size) in tempKeys {
            var inp = SMCParamStruct()
            inp.key = key
            inp.keyInfoDataSize = size
            inp.data8 = Self.cmdReadKey
            guard let out = call(&inp) else { continue }
            let b = out.bytes
            let v: Double
            if type == Self.typeFLT {
                let bits = UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24
                v = Double(Float(bitPattern: bits))
            } else { // sp78：大端定点，高 8 位整数 + 低 8 位小数
                let raw = Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))
                v = Double(raw) / 256.0
            }
            if v > 1, v < 125 { sum += v; n += 1 }
        }
        guard n > 0 else { return nil }
        return sum / Double(n)
    }
}

// MARK: - 格式化

func pctString(_ v: Double?) -> String {
    guard let v else { return "--" }
    return "\(Int(min(100, max(0, v)).rounded()))%"
}

func tempString(_ v: Double?) -> String {
    guard let v else { return "--" }
    return "\(Int(v.rounded()))°C"
}

func speedString(_ bps: Double?) -> String {
    guard let bps else { return "-- K/s" }
    // 宽度有上界：每档 <100 显示一位小数（"99.9"），100–999 取整（"999"），≥1000 进下一档
    func fmt(_ v: Double, _ unit: String) -> String {
        v < 100 ? String(format: "%.1f %@/s", v, unit) : String(format: "%.0f %@/s", v, unit)
    }
    let k = max(0, bps) / 1024.0
    if k < 1000 { return fmt(k, "K") }
    let m = k / 1024.0
    if m < 1000 { return fmt(m, "M") }
    return fmt(m / 1024.0, "G")
}

// MARK: - 菜单栏块视图

enum UI {
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    static let netFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    /// 块内左右留白；块与块的间距由系统菜单栏控制（各块是独立状态项）
    static let hPad: CGFloat = 0
    static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: valueFont, .foregroundColor: NSColor.labelColor,
    ]
    static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont, .foregroundColor: NSColor.labelColor,
    ]
    static let netAttrs: [NSAttributedString.Key: Any] = [
        .font: netFont, .foregroundColor: NSColor.labelColor,
    ]

    static func measure(_ s: String, _ f: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: f]).size().width
    }
}

/// 基类：翻转坐标 + 点击透传给 NSStatusBarButton（让系统菜单/拖动正常工作）
class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// 当前内容所需宽度；状态项长度随之自适应，消除定宽模板的空隙
    var desiredWidth: CGFloat { bounds.width }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }
    override init(frame: NSRect) { super.init(frame: frame) }
}

/// 上排数值 + 下排标签的块（CPU / MEM / SSD / SEN）
final class StatBlockView: PassthroughView {
    private let label: String
    private var value = "--"
    let blockWidth: CGFloat

    init(label: String, valueTemplate: String) {
        self.label = label
        // 初始宽度用样板串估计，之后随实际内容自适应
        blockWidth = ceil(max(UI.measure(valueTemplate, UI.valueFont),
                              UI.measure(label, UI.labelFont))) + UI.hPad * 2
        super.init(frame: NSRect(x: 0, y: 0, width: blockWidth,
                                 height: NSStatusBar.system.thickness))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var desiredWidth: CGFloat {
        ceil(max(UI.measure(value, UI.valueFont),
                 UI.measure(label, UI.labelFont))) + UI.hPad * 2
    }

    func set(value v: String) {
        if v != value {
            value = v
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let va = NSAttributedString(string: value, attributes: UI.valueAttrs)
        let vs = va.size()
        va.draw(at: NSPoint(x: (w - vs.width) / 2, y: 1))
        // 标签底部对齐（按实测行高定位，字号调整也不会溢出）
        let la = NSAttributedString(string: label, attributes: UI.labelAttrs)
        let ls = la.size()
        la.draw(at: NSPoint(x: (w - ls.width) / 2, y: h - ls.height - 1))
    }
}

/// 上行/下行两行网速块
final class NetBlockView: PassthroughView {
    private var up = "↑-- K/s"
    private var down = "↓-- K/s"
    let blockWidth: CGFloat

    init() {
        // speedString 最宽输出是 "99.9 X/s" 或 "999 X/s"，取两者较大者定宽
        blockWidth = ceil(max(UI.measure("↓99.9 K/s", UI.netFont),
                              UI.measure("↓999 K/s", UI.netFont))) + UI.hPad * 2
        super.init(frame: NSRect(x: 0, y: 0, width: blockWidth,
                                 height: NSStatusBar.system.thickness))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var desiredWidth: CGFloat {
        ceil(max(UI.measure(up, UI.netFont),
                 UI.measure(down, UI.netFont))) + UI.hPad * 2
    }

    func set(up u: String, down d: String) {
        if u != up || d != down {
            up = u
            down = d
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let lineH = h / 2
        func drawLine(_ s: String, yTop: CGFloat) {
            let a = NSAttributedString(string: s, attributes: UI.netAttrs)
            let size = a.size()
            a.draw(at: NSPoint(x: (w - size.width) / 2, y: yTop + (lineH - size.height) / 2))
        }
        drawLine(up, yTop: 0)
        drawLine(down, yTop: lineH)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// (状态项, 对应视图)；顺序即创建顺序
    private var pairs: [(item: NSStatusItem, view: PassthroughView)] = []
    private var timer: DispatchSourceTimer?
    private var timerSuspended = false

    private let cpuSampler = CPUSampler()
    private let netSampler = NetSampler()
    private let smc = SMC()
    private var tickCount = 0
    private var cachedDisk: Double?

    private var cpuView: StatBlockView!
    private var memView: StatBlockView!
    private var ssdView: StatBlockView!
    private var senView: StatBlockView!
    private var netView: NetBlockView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        cpuView = StatBlockView(label: "CPU", valueTemplate: "100%")
        memView = StatBlockView(label: "MEM", valueTemplate: "100%")
        ssdView = StatBlockView(label: "SSD", valueTemplate: "100%")
        senView = StatBlockView(label: "SEN", valueTemplate: "100°C")
        netView = NetBlockView()

        // 每个块是独立 NSStatusItem：可单独 Cmd+拖动排序、拖出菜单栏移除，
        // 位置/可见性经 autosaveName 持久化。新建项出现在已有项左侧，
        // 故倒序创建得到 CPU MEM SSD SEN NET 的从左到右初始顺序。
        pairs = [
            (makeItem(netView, autosave: "Monitoring.NET", accessibility: "网络速率"), netView),
            (makeItem(senView, autosave: "Monitoring.SEN", accessibility: "CPU 温度"), senView),
            (makeItem(ssdView, autosave: "Monitoring.SSD", accessibility: "磁盘使用率"), ssdView),
            (makeItem(memView, autosave: "Monitoring.MEM", accessibility: "内存使用率"), memView),
            (makeItem(cpuView, autosave: "Monitoring.CPU", accessibility: "CPU 使用率"), cpuView),
        ]
        // 防呆：若上次全部被拖出菜单栏，重启时全部恢复，避免应用无处可退出
        if pairs.allSatisfy({ !$0.item.isVisible }) {
            pairs.forEach { $0.item.isVisible = true }
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Config.interval,
                   leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.update() }
        t.resume()
        timer = t

        // 息屏/锁屏时暂停采样，省电；亮屏后恢复
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.setTimerPaused(true)
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.setTimerPaused(false)
        }
    }

    private func makeItem(_ view: PassthroughView, autosave: String,
                          accessibility: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: view.frame.width)
        item.autosaveName = autosave
        item.behavior = .removalAllowed
        if let button = item.button {
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            button.setAccessibilityLabel(accessibility)
        }
        let menu = NSMenu()
        menu.delegate = self
        let launch = NSMenuItem(title: "开机自启动",
                                action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        menu.addItem(launch)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        return item
    }

    // 打开菜单时刷新「开机自启动」勾选状态
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(toggleLaunchAtLogin(_:)) }?
            .state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("切换开机自启动失败: \(error)")
        }
    }

    private func setTimerPaused(_ paused: Bool) {
        guard paused != timerSuspended, let timer else { return }
        timerSuspended = paused
        if paused { timer.suspend() } else { timer.resume() }
    }

    private func update() {
        // 全部块都被拖出菜单栏时不采样
        guard pairs.contains(where: { $0.item.isVisible }) else { return }
        cpuView.set(value: pctString(cpuSampler.sample()))
        memView.set(value: pctString(sampleMemory()))
        if tickCount % Config.diskEvery == 0 { cachedDisk = sampleDisk() }
        ssdView.set(value: pctString(cachedDisk))
        senView.set(value: tempString(smc?.readCPUTemperature()))
        let net = netSampler.sample()
        netView.set(up: "↑" + speedString(net?.tx), down: "↓" + speedString(net?.rx))
        tickCount += 1
        // 宽度随内容自适应
        for (item, view) in pairs {
            let w = view.desiredWidth
            if abs(item.length - w) > 0.5 { item.length = w }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
