// Génère l'icône de View 3D (icon.icns + docs/icon.png) avec CoreGraphics.
// Usage : swift Tools/make_icon.swift <dossier_sortie_iconset> <icon.png 1024>
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
}

func polygon(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
}

func draw(_ ctx: CGContext) {
    // --- Fond : carré arrondi dégradé ---
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 190, cornerHeight: 190, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x0A1540, 0.45))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x2A47C9)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x7DB0FF), rgb(0x3A62E6), rgb(0x1E2FA6)], [0, 0.5, 1]),
                           start: CGPoint(x: 300, y: 924), end: CGPoint(x: 740, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // lueur douce en haut
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 420, y: 880), startRadius: 0,
                           endCenter: CGPoint(x: 420, y: 880), endRadius: 560, options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()

    // --- Cube isométrique ---
    let cx: CGFloat = 512, cy: CGFloat = 505, R: CGFloat = 252
    let k: CGFloat = 0.8660254
    let T = CGPoint(x: cx, y: cy + R), UR = CGPoint(x: cx + R * k, y: cy + R / 2)
    let LR = CGPoint(x: cx + R * k, y: cy - R / 2), B = CGPoint(x: cx, y: cy - R)
    let LL = CGPoint(x: cx - R * k, y: cy - R / 2), UL = CGPoint(x: cx - R * k, y: cy + R / 2)
    let C = CGPoint(x: cx, y: cy)

    // ombre portée du cube
    func ring(front: Bool) {
        let rx: CGFloat = 372, ry: CGFloat = 128, rot: CGFloat = -0.40
        let path = CGMutablePath()
        let n = 90
        for i in 0...n {
            let t = (front ? CGFloat.pi : 0) + CGFloat.pi * CGFloat(i) / CGFloat(n)
            let x = rx * cos(t), y = ry * sin(t)
            let p = CGPoint(x: cx + x * cos(rot) - y * sin(rot), y: cy + x * sin(rot) + y * cos(rot))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.saveGState()
        if front { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: rgb(0x0A1540, 0.45)) }
        ctx.addPath(path)
        ctx.setLineWidth(38); ctx.setLineCap(.butt); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFD25E), rgb(0xFF8A1F)], [0, 1]),
                               start: CGPoint(x: cx - 380, y: cy + 160), end: CGPoint(x: cx + 380, y: cy - 160), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    ring(front: false)

    // ombre du cube
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0x0A1540, 0.55))
    ctx.addPath(polygon([T, UR, LR, B, LL, UL])); ctx.setFillColor(rgb(0x8FB0F2)); ctx.fillPath()
    ctx.restoreGState()

    func face(_ pts: [CGPoint], _ top: UInt32, _ bottom: UInt32) {
        let cen = CGPoint(x: pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count),
                          y: pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count))
        let inset = pts.map { CGPoint(x: cen.x + ($0.x - cen.x) * 0.925, y: cen.y + ($0.y - cen.y) * 0.925) }
        ctx.saveGState()
        let path = polygon(inset)
        ctx.addPath(path); ctx.setLineWidth(26); ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.replacePathWithStrokedPath()
        ctx.addPath(path)
        ctx.clip()
        let minY = pts.map { $0.y }.min()!, maxY = pts.map { $0.y }.max()!
        ctx.drawLinearGradient(gradient([rgb(top), rgb(bottom)], [0, 1]),
                               start: CGPoint(x: cen.x, y: maxY), end: CGPoint(x: cen.x, y: minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        // bord arrondi : on trace le contour dans la même couleur moyenne
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(26); ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgb(bottom)); ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(top), rgb(bottom)], [0, 1]),
                               start: CGPoint(x: cen.x, y: maxY), end: CGPoint(x: cen.x, y: minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    face([UL, C, B, LL], 0xE3ECFF, 0xB9CDF8)          // gauche
    face([C, UR, LR, B], 0x9DBBF5, 0x6E92E8)          // droite
    face([T, UR, C, UL], 0xFFFFFF, 0xEAF1FF)          // dessus

    ring(front: true)

    // petite étincelle
    ctx.saveGState()
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    let sp = CGPoint(x: 735, y: 790)
    let star = CGMutablePath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        let r: CGFloat = i % 2 == 0 ? 46 : 10
        let p = CGPoint(x: sp.x + r * cos(a), y: sp.y + r * sin(a))
        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
    }
    star.closeSubpath()
    ctx.addPath(star); ctx.fillPath()
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make_icon <iconset_dir> <icon.png>"); exit(1) }
let dir = args[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { try! render(size: px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png")) }
try! render(size: 1024).write(to: URL(fileURLWithPath: args[2]))
print("ok")
