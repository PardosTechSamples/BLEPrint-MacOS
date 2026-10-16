import CLzma
import Foundation

/// Supvan / Katasymbol E10 (T10/T15 family) protocol: framing, job encoding and status parsing.
/// Ported from BLEPrint's supvan.py. The job encoding follows the MIT-licensed
/// khromov/supvan-katasymbol-printer-web-ui (© Katasymbol Web contributors).
public enum Supvan {
    public static let writeUUIDs = ["FFE9", "FEC1", "C302", "FF02", "2AF1"]
    public static let notifyUUIDs = ["FFE1", "FEC1", "C305", "FF01", "2AF0"]

    public static let BUF_FULL: UInt8 = 0x10, INQUIRY_STA: UInt8 = 0x11, START_PRINT: UInt8 = 0x13
    public static let STOP_PRINT: UInt8 = 0x14, RD_DEV_NAME: UInt8 = 0x16, STRD_MAT: UInt8 = 0x18
    public static let RETURN_MAT: UInt8 = 0x30, NEXT_ZIPPEDBULK: UInt8 = 0x5C
    public static let PAPER_BACK: UInt8 = 0xBA, SET_HEADRATE: UInt8 = 0xC9

    public static let headDots = 96, printDots = 88, dpmm = 8
    static let bytesPerColumn = 12, bufferLength = 4000, maxColumns = 332, leadColumns = 48

    // MARK: frames

    public static func commandFrame(_ cmd: UInt8, _ a: Int = 0, _ b: Int = 0) -> [UInt8] {
        var f: [UInt8] = [0x7E, 0x5A, 0x0C, 0x00, 0x10, 0x01, 0xAA, cmd, 0, 0, 0x00, 0x01,
                          UInt8(a & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF)]
        let s = f[10..<16].reduce(0) { $0 + Int($1) } & 0xFFFF
        f[8] = UInt8(s & 0xFF)
        f[9] = UInt8(s >> 8)
        return f
    }

    public static func dataFrames(_ stream: [UInt8]) -> [[UInt8]] {
        let count = (stream.count + 499) / 500
        return (0..<count).map { i in
            var f = [UInt8](repeating: 0, count: 512)
            f.replaceSubrange(0..<8, with: [0x7E, 0x5A, 0xFC, 0x01, 0x10, 0x02, 0xAA, 0xBB])
            f[10] = UInt8(i & 0xFF)
            f[11] = UInt8(count & 0xFF)
            let chunk = stream[(i * 500)..<min(stream.count, (i + 1) * 500)]
            f.replaceSubrange(12..<(12 + chunk.count), with: chunk)
            let s = f[10..<512].reduce(0) { $0 + Int($1) } & 0xFFFF
            f[8] = UInt8(s & 0xFF)
            f[9] = UInt8(s >> 8)
            return f
        }
    }

    // MARK: LZMA

    /// .lzma "alone" stream as the printer expects: props 0x5D, 8 KB dictionary, known size, then
    /// raw LZMA1 data (lc3 lp0 pb2, nice_len 128 on top of preset 6, same as Python's lzma module).
    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var opt = lzma_options_lzma()
        _ = lzma_lzma_preset(&opt, 6)
        opt.dict_size = 8192
        opt.lc = 3
        opt.lp = 0
        opt.pb = 2
        opt.nice_len = 128
        var raw = [UInt8]()
        withUnsafeMutablePointer(to: &opt) { optPtr in
            var filters = [lzma_filter(id: 0x4000_0000_0000_0001, options: UnsafeMutableRawPointer(optPtr)),  // LZMA_FILTER_LZMA1
                           lzma_filter(id: UInt64.max, options: nil)]                                         // LZMA_VLI_UNKNOWN
            var strm = lzma_stream()
            guard lzma_raw_encoder(&strm, &filters) == LZMA_OK else { return }
            defer { lzma_end(&strm) }
            var out = [UInt8](repeating: 0, count: input.count * 2 + 1024)
            input.withUnsafeBufferPointer { inBuf in
                out.withUnsafeMutableBufferPointer { outBuf in
                    strm.next_in = inBuf.baseAddress
                    strm.avail_in = inBuf.count
                    strm.next_out = outBuf.baseAddress
                    strm.avail_out = outBuf.count
                    while lzma_code(&strm, LZMA_FINISH) == LZMA_OK {}
                }
            }
            raw = Array(out[0..<Int(strm.total_out)])
        }
        var header: [UInt8] = [0x5D]
        withUnsafeBytes(of: UInt32(8192).littleEndian) { header += $0 }
        withUnsafeBytes(of: UInt64(input.count).littleEndian) { header += $0 }
        return header + raw
    }

    /// iOS T15Transfer: avoid AA <BB|06|C7|07> where a 128-byte BLE write's frame marker would sit.
    static func avoidFrameMarkers(_ buf: inout [UInt8], _ stream: [UInt8]) -> [UInt8] {
        let hits = [0x7A, 0xFA, 0x17A].filter { $0 + 1 < stream.count && stream[$0] == 0xAA && [0xBB, 0x06, 0xC7, 0x07].contains(stream[$0 + 1]) }
        guard !hits.isEmpty else { return stream }
        for i in hits { buf[i] = buf[i] &+ 1 }
        return compress(buf)
    }

    // MARK: image -> columns -> job

    /// Grayscale label (width = length along the tape, up to 88 rows tall) -> 12-byte head columns.
    public static func raster(_ img: GrayImage, rows: Int = printDots) -> [[UInt8]] {
        var src = img
        if src.height > rows { src = src.crop(x: 0, y: (src.height - rows) / 2, w: src.width, h: rows) }
        let yOff = (headDots - src.height) / 2
        return (0..<src.width).map { x in
            var col = [UInt8](repeating: 0, count: bytesPerColumn)
            for r in 0..<src.height where src.isDark(x, r) {
                let y = yOff + r
                if y >= 0 && y < headDots { col[y >> 3] |= UInt8(1 << (y & 7)) }
            }
            return col
        }
    }

    public struct Job {
        public var buffers: [[UInt8]] = []
        public var streams: [[UInt8]] = []
        public var perLabel: [Int] = []
        public var backFrames = 0
    }

    public static func encodeJob(_ labels: [[[UInt8]]], density: Int = 4, dieCut: Bool = false, paperGap: Double = 3,
                                 cutMode: Int = 0, avoidMarkers: Bool = true) -> Job {
        var buf = [UInt8](repeating: 0, count: bufferLength)
        var job = Job()
        for (n, rawCols) in labels.enumerated() {
            let cols = rawCols.isEmpty ? [[UInt8](repeating: 0, count: bytesPerColumn)] : rawCols
            let last = n == labels.count - 1
            let cut = cutMode == 2 ? 2 : (cutMode == 0 && last ? 1 : 0)
            let total = cols.count
            func inked(_ i: Int) -> Bool { i >= 0 && i < total && cols[i].contains { $0 != 0 } }
            var current = 0, left = total, count = 0
            while current != total {
                var skip = 0, pageStart = false, pageEnd = false
                if current == 0 {
                    pageStart = true
                    if n == 0 {
                        let limit = dieCut ? Int((6.5 - paperGap) * 8) : leadColumns
                        var i = 0
                        while i < limit && !inked(i) { i += 1 }
                        if i > 0 { i -= 1 }
                        skip = i >= limit ? limit - 1 : i
                        job.backFrames = skip >= limit - 1 ? 0 : limit - skip
                        skip = max(0, min(skip, total - 1))
                        current = skip
                    }
                }
                left -= skip
                let ncols: Int
                if left > maxColumns {
                    left -= maxColumns
                    ncols = maxColumns
                } else {
                    pageEnd = true
                    ncols = left
                }
                for k in 0..<ncols {
                    if current < total {
                        buf.replaceSubrange((14 + k * bytesPerColumn)..<(14 + (k + 1) * bytesPerColumn), with: cols[current])
                    }
                    current += 1
                }
                current = min(current, total)
                buf[2] = (pageStart ? 0x02 : 0) | (pageEnd ? 0x04 : 0) | (pageEnd && last ? 0x08 : 0) | UInt8((cut & 7) << 4)
                buf[3] = UInt8(((density << 2) | (1 << 4)) & 0xFF)
                buf[4] = UInt8(ncols & 0xFF); buf[5] = UInt8((ncols >> 8) & 0xFF); buf[6] = UInt8(bytesPerColumn)
                buf[8] = 1; buf[9] = 0; buf[10] = 1; buf[11] = 0; buf[12] = UInt8(skip & 0xFF); buf[13] = 0
                let length = ncols * bytesPerColumn + 14
                var s = buf[2..<14].reduce(0) { $0 + Int($1) }
                if length >= 256 { for k in 1...(length / 256) { s += Int(buf[k * 256 - 1]) } }
                buf[0] = UInt8(s & 0xFF)
                buf[1] = UInt8((s >> 8) & 0xFF)
                var stream = compress(buf)
                if avoidMarkers { stream = avoidFrameMarkers(&buf, stream) }
                job.buffers.append(buf)
                job.streams.append(stream)
                count += 1
            }
            job.perLabel.append(count)
        }
        return job
    }

    /// Density 1...7 -> 0xC9 argument (80...140), float32 maths like the iOS app.
    public static func headRate(_ density: Int) -> Int {
        let a = Float(Float(density - 1) / 10)
        return Int(Float(Float(a + Float(0.8)) * Float(100)))
    }

    // MARK: status

    public struct Status {
        public var bufferFull = false, busy = false, printing = false, coverOpen = false, charging = false
        public var pagesPrinted = 0
        public var batteryVolts: Double?
        public var error: String?
    }

    public static func parseStatus(_ f: [UInt8]) -> Status {
        guard f.count >= 20 else { return Status(error: "Short status reply") }
        let b = Array(f[14..<20])
        var s = Status()
        s.bufferFull = b[0] & 0x01 != 0
        s.busy = b[1] & 0x04 != 0
        s.printing = b[2] & 0x40 != 0
        s.coverOpen = b[2] & 0x08 != 0
        s.charging = b[2] & 0x10 != 0
        s.pagesPrinted = Int(b[4]) | Int(b[5]) << 8
        if f.count >= 26 { s.batteryVolts = (Double(Int(f[24]) | Int(f[25]) << 8) / 10).rounded() / 100 }
        if b[2] & 0x08 != 0 { s.error = "Cover is open" }
        else if b[3] & 0x01 != 0 || b[0] & 0x02 != 0 { s.error = "No label detected" }
        else if b[0] & 0x04 != 0 { s.error = "Labels used up" }
        else if b[0] & 0x10 != 0 { s.error = "Label tape is not installed" }
        return s
    }
}
