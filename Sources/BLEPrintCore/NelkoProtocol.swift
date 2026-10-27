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
    /// Gap between labels on the P21's standard 14 x 40 mm "GAP" rolls (Nelko model data: defaultGap 5).
    /// TSPL feeds label length + gap after each print, so a wrong gap shifts every following label.
    public static let defaultGapMM = 5.0
    /// ESC ! ? — one status byte back (0 = ready). Same bytes as the vendor SDK's getPrinterStatus.
    public static let statusQuery: [UInt8] = [0x1B, 0x21, 0x3F, 0x0D, 0x0A]
    /// Sent once after the last label of a batch, like the vendor SDK's printAllEnd.
    public static let allEnd: [UInt8] = Array("ALLEND\r\n".utf8)

    /// TSPL status byte -> error text, or nil when the printer can carry on.
    public static func statusError(_ s: UInt8) -> String? {
        if s & 0x01 != 0 { return "Print head is open" }
        if s & 0x40 != 0 { return "Cover is open" }
        if s & 0x02 != 0 { return "Paper jam" }
        if s & 0x04 != 0 { return "Out of labels" }
        if s & 0x80 != 0 { return "Printer error" }
        return nil
    }
    /// True while the printer is still printing or paused.
    public static func statusBusy(_ s: UInt8) -> Bool { s & 0x30 != 0 }

    public static func dots(_ mm: Double) -> Int { Int((mm * dpi / 25.4).rounded(.toNearestOrEven)) }
    /// Dots used across the head for a label `mm` wide.
    public static func printDots(_ mm: Double) -> Int { min(dots(mm), headDots) }

    /// Python's str(float): "15.0", "2.5".
    static func pyFloat(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(format: "%.1f", v) : "\(v)" }

    /// One TSPL job for a bitmap that is printDots(headMM) wide x feed_dots tall (already rotated for the head).
    /// `copies` identical labels come from one job (`PRINT n`), as the vendor SDK does.
    public static func tsplJob(_ img: GrayImage, headMM: Double, feedMM: Double, gapMM: Double = defaultGapMM,
                               density: Int = 10, speed: Int = 3, copies: Int = 1, threshold: UInt8 = 128) -> [UInt8] {
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
        // No SIZE / GAP: the P21 reads the loaded roll (RFID-tagged) and sets label size and gap itself.
        // Sending our own values overrode that, and a wrong gap shifted every label after the first.
        line("DIRECTION 0,0")
        line("REFERENCE 0,0")
        line("DENSITY \(density)")
        line("SPEED \(speed)")
        line("CLS")
        job += Array("BITMAP 0,0,\(widthBytes),\(feedDots),0,".utf8)
        job += raster
        job += Array("\r\n".utf8)
        line("PRINT \(max(1, copies))")
        return job
    }
}
