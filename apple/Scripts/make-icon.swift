// make-icon.swift — генератор иконки приложения Chronica (без внешних зависимостей).
//
// Запускается интерпретатором Swift из `make-icon.sh`:
//     swift make-icon.swift <output-iconset-dir>
// и рисует все PNG для .iconset (16…512@2x) через CoreGraphics + ImageIO.
// Сборку .icns делает `iconutil` в make-icon.sh.
//
// Дизайн (согласован с apple/Sources/Chronica/Design/Theme.swift):
//   • тёмная скруглённая плитка в стиле macOS Big Sur — суперэллипс
//     («squircle»), 824×824 внутри канвы 1024×1024, вертикальный градиент
//     surface2 → bgSidebar, мягкая тень и hairline-рамка white@10%;
//   • глиф: три вертикальных штриха-«звуковая волна» цветом textPrimary
//     (#F2F2F7) + маленькая точка-«запись» цветом semRec (#FF453A).
// Три штриха, а не пять, — сознательно: на 16 pt пять штрихов сливаются
// в серое пятно, три читаются.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Палитра (значения из Theme.swift)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let tileTop = rgb(0x2E2E32)      // Theme.Color.surface2
let tileBottom = rgb(0x141416)   // чуть темнее Theme.Color.bgSidebar (#161618)
let hairline = rgb(0xFFFFFF, 0.10)
let glyphColor = rgb(0xF2F2F7)   // Theme.Color.textPrimary
let recColor = rgb(0xFF453A)     // Theme.Color.semRec — «запись»

// MARK: - Геометрия

/// Суперэллипс |x/a|^n + |y/b|^n = 1 — форма плитки macOS Big Sur.
/// n = 5 даёт скругление, визуально совпадающее с системными иконками.
func squirclePath(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let theta = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(theta), st = sin(theta)
        let x = cx + a * CGFloat(copysign(pow(abs(Double(ct)), 2 / Double(n)), Double(ct)))
        let y = cy + b * CGFloat(copysign(pow(abs(Double(st)), 2 / Double(n)), Double(st)))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Отрисовка

func drawIcon(size px: Int) -> CGImage? {
    let s = CGFloat(px)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: px, height: px,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Плитка: 824/1024 канвы, по центру (сетка иконок Big Sur).
    let t = s * 824.0 / 1024.0
    let tileRect = CGRect(x: (s - t) / 2, y: (s - t) / 2, width: t, height: t)
    let tile = squirclePath(in: tileRect)

    // Мягкая тень под плиткой (в CG ось Y направлена вверх).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.024, color: rgb(0x000000, 0.45))
    ctx.addPath(tile)
    ctx.setFillColor(tileBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Градиентная заливка плитки (сверху светлее).
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [tileTop, tileBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
            end: CGPoint(x: tileRect.midX, y: tileRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Hairline-рамка по контуру плитки (ощущение стекла из Theme).
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(hairline)
    ctx.setLineWidth(max(0.5, s * 0.005))
    ctx.strokePath()
    ctx.restoreGState()

    // Глиф: три штриха + точка «запись», единым блоком по центру плитки.
    let cx = tileRect.midX, cy = tileRect.midY
    let barW = 0.115 * t
    let gap = 0.078 * t
    let dotR = 0.075 * t
    let dotGap = 0.085 * t
    let heights: [CGFloat] = [0.32, 0.58, 0.44].map { $0 * t }

    let barsW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let totalW = barsW + dotGap + 2 * dotR
    var x = cx - totalW / 2

    ctx.setFillColor(glyphColor)
    for h in heights {
        let bar = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2,
                           cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }
    let barsRight = x - gap

    ctx.setFillColor(recColor)
    let dot = CGRect(x: barsRight + dotGap, y: cy - dotR,
                     width: 2 * dotR, height: 2 * dotR)
    ctx.addPath(CGPath(ellipseIn: dot, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create PNG destination: \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot write PNG: \(url.path)"])
    }
}

// MARK: - Точка входа

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output-iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Полный набор для .icns: (имя в iconset, размер в пикселях).
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in variants {
    guard let image = drawIcon(size: px) else {
        FileHandle.standardError.write("error: cannot render \(px)px\n".data(using: .utf8)!)
        exit(1)
    }
    try writePNG(image, to: outDir.appendingPathComponent(name))
    print("  \(name) (\(px)×\(px))")
}
