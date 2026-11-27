// 生成 AppIcon.icns：深蓝渐变圆角方块 + 白色 CPU 芯片轮廓 + 绿色活动波形
// 用法：swift makeicon.swift <输出目录>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    // 留出 macOS 图标标准的透明边距（约 10%）
    let inset = s * 0.10
    let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = box.width * 0.2237
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.26, alpha: 1),
        ending: NSColor(calibratedRed: 0.15, green: 0.32, blue: 0.62, alpha: 1))
    gradient?.draw(in: squircle, angle: 90)

    let white = NSColor(calibratedWhite: 1, alpha: 0.92)
    let stroke = s * 0.030

    // CPU 芯片主体（居中圆角方形）
    let chipSize = s * 0.46
    let chip = NSRect(x: (s - chipSize) / 2, y: (s - chipSize) / 2,
                      width: chipSize, height: chipSize)
    let chipPath = NSBezierPath(roundedRect: chip, xRadius: s * 0.045, yRadius: s * 0.045)
    chipPath.lineWidth = stroke
    white.setStroke()
    chipPath.stroke()

    // 四边引脚（每边 3 根）
    let pinLen = s * 0.065
    let pinGap = chipSize / 4
    white.setStroke()
    for i in 1...3 {
        let offset = chip.minX + CGFloat(i) * pinGap
        for pin in [
            (NSPoint(x: offset, y: chip.maxY), NSPoint(x: offset, y: chip.maxY + pinLen)),
            (NSPoint(x: offset, y: chip.minY), NSPoint(x: offset, y: chip.minY - pinLen)),
            (NSPoint(x: chip.minX, y: offset), NSPoint(x: chip.minX - pinLen, y: offset)),
            (NSPoint(x: chip.maxX, y: offset), NSPoint(x: chip.maxX + pinLen, y: offset)),
        ] {
            let p = NSBezierPath()
            p.move(to: pin.0)
            p.line(to: pin.1)
            p.lineWidth = stroke
            p.lineCapStyle = .round
            p.stroke()
        }
    }

    // 芯片内部：绿色活动波形（心跳式折线）
    let wave = NSBezierPath()
    let midY = chip.midY
    let w = chip.width
    wave.move(to: NSPoint(x: chip.minX + w * 0.10, y: midY))
    wave.line(to: NSPoint(x: chip.minX + w * 0.32, y: midY))
    wave.line(to: NSPoint(x: chip.minX + w * 0.44, y: midY + chipSize * 0.22))
    wave.line(to: NSPoint(x: chip.minX + w * 0.58, y: midY - chipSize * 0.22))
    wave.line(to: NSPoint(x: chip.minX + w * 0.68, y: midY))
    wave.line(to: NSPoint(x: chip.minX + w * 0.90, y: midY))
    wave.lineWidth = s * 0.036
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    NSColor(calibratedRed: 0.35, green: 0.90, blue: 0.55, alpha: 1).setStroke()
    wave.stroke()

    return rep.representation(using: .png, properties: [:])
}

// iconset 所需的尺寸组合
let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let iconset = outDir + "/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for e in entries {
    guard let png = render(e.px) else { fatalError("渲染 \(e.px)px 失败") }
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(e.name).png"))
}
print("iconset 已生成：\(iconset)")
