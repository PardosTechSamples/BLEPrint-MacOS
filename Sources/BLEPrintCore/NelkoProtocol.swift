import Foundation

/// Nelko P21 (JieLi-based) label printer: TSPL text commands over BLE service FF00
/// (write FF02, notify FF01). Ported from BLEPrint's bleprint.py.
public enum Nelko {
    public static let service = "FF00", write = "FF02", notify = "FF01"
    public static let dpi = 203.0
    /// The P21's print head is 12 mm = 96 dots wide (Nelko model data: maxWidth 12, dpi 203), centred
    /// on 14-15 mm labels. Bitmaps wider than this are cut off by the printer.
    public static let headDots = 96
    /// Along the feed only part of the label is printable (40 mm label -> 35.5 mm): keep 2.25 mm clear.
    public static let feedMarginDots = 18

    public static func dots(_ mm: Double) -> Int { Int((mm * dpi / 25.4).rounded(.toNearestOrEven)) }
    /// Dots used across the head for a label `mm` wide.
    public static func printDots(_ mm: Double) -> Int { min(dots(mm), headDots) }

    /// Python's str(float): "15.0", "2.5".
    static func pyFloat(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(format: "%.1f", v) : "\(v)" }

    /// One TSPL job for a bitmap that is printDots(headMM) wide x feed_dots tall (already rotated for the head).
    public static func tsplJob(_ img: GrayImage, headMM: Double, feedMM: Double, gapMM: Double = 2.0,
                               density: Int = 10, speed: Int = 3, threshold: UInt8 = 128) -> [UInt8] {
        let headDots = printDots(headMM), feedDots = dots(feedMM)
        let widthBytes = (headDots + 7) / 8
        var raster = [UInt8]()
        raster.reserveCapacity(widthBytes * feedDots)
        for y in 0..<feedDots {
            for xb in 0..<widthBytes {
                var byte: UInt8 = 0
                for bit in 0..<8 {
                    let x = xb * 8 + bit
                    var white: UInt8 = 1                       // TSPL: 1 = dot NOT printed
                    if x < headDots && x < img.width && y < img.height { white = img[x, y] < threshold ? 0 : 1 }
                    byte = (byte << 1) | white
                }
                raster.append(byte)
            }
        }
        var job = [UInt8]()
        func line(_ s: String) { job += Array((s + "\r\n").utf8) }
        line("SIZE \(pyFloat(headMM)) mm,\(pyFloat(feedMM)) mm")
        line("GAP \(String(format: "%.1f", gapMM)) mm,0 mm")
        line("DIRECTION 0,0")
        line("REFERENCE 0,0")
        line("DENSITY \(density)")
        line("SPEED \(speed)")
        line("CLS")
        job += Array("BITMAP 0,0,\(widthBytes),\(feedDots),0,".utf8)
        job += raster
        job += Array("\r\n".utf8)
        line("PRINT 1")
        return job
    }
}
