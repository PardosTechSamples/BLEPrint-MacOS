import AppKit
import CoreImage
import CoreText
import Foundation

/// Label rendering: text fitted by its real ink box, and QR codes. Mirrors bleprint.py, supvan.py
/// and qrlabel.py.
public enum Render {
    static let font = "Arial-BoldMT"

    /// Draw (multi-line, centred) text at `size` points and return just its ink, or nil if blank.
    static func inkText(_ text: String, size: CGFloat) -> GrayImage? {
        let ctFont = CTFontCreateWithName((NSFont(name: font, size: size)?.fontName ?? "Helvetica-Bold") as CFString, size, nil)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attr = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: ctFont, .foregroundColor: NSColor.black, .paragraphStyle: para,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                               CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        let pad = size
        let w = Int(ceil(fit.width + 2 * pad)), h = Int(ceil(fit.height + 2 * pad))
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: pad, y: pad, width: ceil(fit.width), height: ceil(fit.height)), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage(), let img = GrayImage(cgImage: cg), let b = img.inkBounds() else { return nil }
        return img.crop(x: b.x, y: b.y, w: b.w, h: b.h)
    }

    /// Largest rendering of `text` whose ink fits within maxW x maxH (font size capped at maxSize).
    public static func fittedText(_ text: String, maxW: Int, maxH: Int, maxSize: CGFloat = 400) -> GrayImage? {
        guard maxW > 2, maxH > 2, let probe = inkText(text, size: 100) else { return nil }
        var size = min(maxSize, 100 * min(CGFloat(maxW) / CGFloat(probe.width), CGFloat(maxH) / CGFloat(probe.height)))
        for _ in 0..<12 {
            guard size >= 4, let img = inkText(text, size: size) else { return nil }
            if img.width <= maxW && img.height <= maxH { return img }
            size *= 0.97
        }
        return nil
    }

    static func centered(_ ink: GrayImage?, in canvas: inout GrayImage) {
        guard let ink else { return }
        canvas.paste(ink, x: (canvas.width - ink.width) / 2, y: (canvas.height - ink.height) / 2)
    }

    // MARK: Nelko (TSPL): landscape canvas, rotated to head_dots wide x feed_dots tall

    /// Canvas = the 96 printable head dots (centred on the label) x the label length; text stays 6 dots
    /// inside the head and 2.25 mm from each end of the label.
    public static func nelkoText(_ text: String, headMM: Double, feedMM: Double) -> GrayImage {
        let hd = Nelko.printDots(headMM), fd = Nelko.dots(feedMM)
        var canvas = GrayImage(width: fd, height: hd)
        centered(fittedText(text, maxW: fd - 2 * Nelko.feedMarginDots, maxH: hd - 12, maxSize: 200), in: &canvas)
        return canvas.rotatedCCW()
    }

    public static func nelkoQR(_ text: String, headMM: Double, feedMM: Double, showText: Bool) -> GrayImage {
        qrLabel(text, height: Nelko.printDots(headMM), width: Nelko.dots(feedMM), margin: Nelko.feedMarginDots,
                showText: showText).rotatedCCW()
    }

    // MARK: Supvan (88 dots tall, width = length along the tape)

    /// lengthMM nil = fit the label to the text, edge to edge (1 mm margin each end).
    public static func supvanText(_ text: String, lengthMM: Double?) -> GrayImage {
        let h = Supvan.printDots, margin = 8
        if let lengthMM {
            var canvas = GrayImage(width: max(8, Int((lengthMM * 8).rounded())), height: h)
            centered(fittedText(text, maxW: canvas.width - 2 * margin, maxH: h - 2), in: &canvas)
            return canvas
        }
        guard let ink = fittedText(text, maxW: 8000, maxH: h - 2) else { return GrayImage(width: 16, height: h) }
        var canvas = GrayImage(width: ink.width + 2 * margin, height: h)
        centered(ink, in: &canvas)
        return canvas
    }

    public static func supvanQR(_ text: String, lengthMM: Double?, showText: Bool) -> GrayImage {
        qrLabel(text, height: Supvan.printDots, width: lengthMM.map { Int(($0 * 8).rounded()) }, showText: showText)
    }

    // MARK: QR

    static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    /// QR modules (true = dark), no quiet zone, error correction L.
    public static func qrMatrix(_ text: String) -> [[Bool]]? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data((text.isEmpty ? " " : text).utf8), forKey: "inputMessage")
        f.setValue("L", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent),
              let img = GrayImage(cgImage: cg), let b = img.inkBounds() else { return nil }
        let n = max(b.w, b.h)                       // the finder patterns span the whole symbol
        return (0..<n).map { y in (0..<n).map { x in img.isDark(b.x + x, b.y + y) } }
    }

    /// Square QR exactly `height` dots tall; modules are spread over the full height.
    public static func qrImage(_ text: String, height: Int) -> GrayImage {
        var img = GrayImage(width: height, height: height)
        guard let m = qrMatrix(text) else { return img }
        let n = m.count
        let edge = (0...n).map { Int((Double($0) * Double(height) / Double(n)).rounded(.toNearestOrEven)) }
        for y in 0..<n { for x in 0..<n where m[y][x] {
            img.fillRect(x: edge[x], y: edge[y], w: edge[x + 1] - edge[x], h: edge[y + 1] - edge[y])
        } }
        return img
    }

    /// QR on the left at full height, text on the right. width nil = fit to content.
    public static func qrLabel(_ text: String, height: Int, width: Int?, margin: Int = 8, gap: Int = 10,
                               showText: Bool = true) -> GrayImage {
        let t = text.trimmingCharacters(in: .newlines)
        let qr = qrImage(t, height: height)
        var ink: GrayImage?
        if showText && !t.isEmpty {
            let room = width.map { $0 - 2 * margin - qr.width - gap } ?? 8000
            if room > 16 { ink = fittedText(t, maxW: room, maxH: height - 4) }
        }
        let content = qr.width + (ink.map { gap + $0.width } ?? 0)
        let w = width.map { max($0, 8) } ?? content + 2 * margin
        var canvas = GrayImage(width: w, height: height)
        let x0 = (w - content) / 2
        canvas.paste(qr, x: x0, y: (height - qr.height) / 2)
        if let ink { canvas.paste(ink, x: x0 + qr.width + gap, y: (height - ink.height) / 2) }
        return canvas
    }
}
