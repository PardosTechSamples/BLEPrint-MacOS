import CoreBluetooth
import Foundation

public struct PrintParams {
    public var headMM = 14.0, feedMM = 40.0, gapMM = Nelko.defaultGapMM
    public var density = 10, speed = 3, copies = 1
    public var continuous = false, fitLength = false
    public init() {}
}

public typealias Log = (String) -> Void
public typealias Progress = (Int, Int) -> Void
/// Called after each label except the last when labels go out one at a time; return false to stop.
public typealias Between = (Int, Int) async -> Bool

public protocol PrinterDriver: AnyObject {
    var brand: Brand { get }
    var label: String { get }
    func connect(log: @escaping Log) async throws -> String
    func disconnect()
    func printLabels(_ images: [GrayImage], _ p: PrintParams, log: @escaping Log, progress: @escaping Progress,
                     between: Between?) async throws
}

public func makeDriver(for device: FoundDevice) -> PrinterDriver? {
    switch device.brand {
    case .nelko: return NelkoDriver(device)
    case .supvan: return SupvanDriver(device)
    case nil: return nil
    }
}

public enum PrinterError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Nelko P21 (TSPL)

public final class NelkoDriver: PrinterDriver {
    public let brand = Brand.nelko
    public var label = "Nelko P21"
    let device: FoundDevice
    let ble = BLE.shared
    var writeChar: CBCharacteristic?
    private let lock = NSLock()
    private var rx = [UInt8]()

    init(_ d: FoundDevice) { device = d }

    public func connect(log: @escaping Log) async throws -> String {
        try await ble.connect(device.peripheral)
        guard let w = ble.characteristic([Nelko.write]), let n = ble.characteristic([Nelko.notify]) else {
            throw PrinterError.message("This doesn't look like a Nelko P21 (service FF00 not found). Found: \(ble.discoveredSummary)")
        }
        writeChar = w
        ble.onData = { [weak self] d in
            guard let self else { return }
            self.lock.lock(); self.rx += d; self.lock.unlock()
        }
        ble.subscribe(n)
        return "\(label) · MTU \(ble.maxWrite + 3)"
    }

    public func disconnect() { ble.disconnect() }

    func send(_ data: [UInt8]) async throws {
        guard let w = writeChar else { throw BLEError.disconnected }
        let chunk = max(20, ble.maxWrite)
        var i = 0
        while i < data.count {
            try await ble.write(Array(data[i..<min(data.count, i + chunk)]), to: w)
            await sleep(ms: 10)                    // gentle pacing, as the vendor SDK does
            i += chunk
        }
    }

    private func clearRx() { lock.lock(); rx = []; lock.unlock() }
    private func firstRx() -> UInt8? { lock.lock(); defer { lock.unlock() }; return rx.first }

    /// One status byte from ESC ! ?, or nil if the printer doesn't answer.
    public func status(timeout: Double = 1.0) async throws -> UInt8? {
        clearRx()
        try await send(Nelko.statusQuery)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = firstRx() { return first }
            await sleep(ms: 20)
        }
        return nil
    }

    /// Wait until the printer has finished the labels already sent. Polls ESC ! ? when the printer
    /// answers it; otherwise waits about as long as `labels` labels take to print.
    func waitUntilIdle(labels: Int, _ p: PrintParams) async throws {
        let estimate = max(1.2, p.feedMM / 25 + 0.9) * Double(max(1, labels))
        guard var s = try await status() else {
            await sleep(ms: Int(estimate * 1000))
            return
        }
        let deadline = Date().addingTimeInterval(estimate + 30)
        while Nelko.statusBusy(s) && Date() < deadline {
            await sleep(ms: 300)
            s = try await status() ?? 0
        }
        if let e = Nelko.statusError(s) { throw PrinterError.message(e) }
    }

    public func printLabels(_ images: [GrayImage], _ p: PrintParams, log: @escaping Log, progress: @escaping Progress,
                            between: Between?) async throws {
        // Runs of identical labels (copies) become one job with PRINT n, like the vendor app.
        var runs: [(img: GrayImage, count: Int)] = []
        for img in images {
            if let last = runs.last, last.img == img { runs[runs.count - 1].count += 1 } else { runs.append((img, 1)) }
        }
        progress(0, images.count)
        var done = 0, previous = 0
        for run in runs {
            if done > 0 { try await waitUntilIdle(labels: previous, p) }
            try await send(Nelko.tsplJob(run.img, headMM: p.headMM, feedMM: p.feedMM, gapMM: p.gapMM,
                                         density: p.density, speed: p.speed, copies: run.count))
            done += run.count
            previous = run.count
            progress(done, images.count)
            log(run.count > 1 ? "  sent \(run.count) copies (\(done)/\(images.count))" : "  sent \(done)/\(images.count)")
        }
        try await waitUntilIdle(labels: previous, p)
        try await send(Nelko.allEnd)
    }
}

// MARK: - Supvan E10 (T10/T15)

public final class SupvanDriver: PrinterDriver {
    public let brand = Brand.supvan
    public var label = "Supvan E10"
    let device: FoundDevice
    let ble = BLE.shared
    var writeChar: CBCharacteristic?
    private let lock = NSLock()
    private var pending = [UInt8]()
    private var frames = [[UInt8]]()
    private var received = 0
    public var media = (dieCut: false, gap: 3.0, widthMM: 0, lengthMM: 0)

    init(_ d: FoundDevice) { device = d }

    public func connect(log: @escaping Log) async throws -> String {
        try await ble.connect(device.peripheral)
        guard let w = ble.characteristic(Supvan.writeUUIDs), let n = ble.characteristic(Supvan.notifyUUIDs) else {
            throw PrinterError.message("This doesn't look like a Supvan printer (no FFE9/FFE1 characteristics). Found: \(ble.discoveredSummary)")
        }
        writeChar = w
        ble.onData = { [weak self] d in self?.receive([UInt8](d)) }
        ble.subscribe(n)
        await sleep(ms: 300)
        do {
            let model = try await name()
            label = "Supvan \(model)"
            let s = try await status()
            try await readMedia()
            log("\(model): battery \(s.batteryVolts.map { String(format: "%.2f", $0) } ?? "?") V, tape \(media.widthMM) mm "
                + (media.dieCut ? "die-cut" : "continuous") + (s.error.map { " — \($0)" } ?? ""))
        } catch { log("(status read failed: \(error.localizedDescription))") }
        return label
    }

    public func disconnect() { ble.disconnect() }

    // MARK: framing

    private func receive(_ chunk: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        received += chunk.count
        var buf = pending + chunk
        var i = 0
        while true {
            while i + 1 < buf.count && !(buf[i] == 0x7E && buf[i + 1] == 0x5A) { i += 1 }
            if i + 4 > buf.count { break }
            let total = (Int(buf[i + 2]) | Int(buf[i + 3]) << 8) + 4
            if total < 8 || total > 2048 { i += 1; continue }
            if i + total > buf.count { break }
            frames.append(Array(buf[i..<(i + total)]))
            i += total
        }
        buf.removeFirst(i)
        pending = buf
    }

    private func clear() { lock.lock(); frames = []; pending = []; lock.unlock() }
    private func takeFrame(_ cmd: UInt8) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        while !frames.isEmpty {
            let f = frames.removeFirst()
            if f.count > 7 && f[7] == cmd { return f }
        }
        return nil
    }
    private var receivedCount: Int { lock.lock(); defer { lock.unlock() }; return received }

    @discardableResult
    func command(_ cmd: UInt8, _ a: Int = 0, _ b: Int = 0, timeout: Double = 4, retry: Bool = false) async throws -> [UInt8] {
        guard let w = writeChar else { throw BLEError.disconnected }
        for _ in 0..<(retry ? 2 : 1) {
            clear()
            try await ble.write(Supvan.commandFrame(cmd, a, b), to: w)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let f = takeFrame(cmd) { return f }
                await sleep(ms: 10)
            }
        }
        throw BLEError.timeout(String(format: "no reply to command 0x%02X", cmd))
    }

    func status() async throws -> Supvan.Status { Supvan.parseStatus(try await command(Supvan.INQUIRY_STA, retry: true)) }

    func name() async throws -> String {
        let f = try await command(Supvan.RD_DEV_NAME)
        let tail = f.count > 22 ? Array(f[22...]) : []
        return String(decoding: tail.prefix { $0 != 0 }, as: UTF8.self)
    }

    func readMedia() async throws {
        let f = try await command(Supvan.RETURN_MAT)
        let type = f.count > 39 ? f[39] : 0, gap = f.count > 42 ? Int(f[42]) : 0
        media = (type == 1 || type == 129, Double(gap > 8 ? 3 : gap), f.count > 40 ? min(15, Int(f[40])) : 0, f.count > 41 ? Int(f[41]) : 0)
        _ = try? await command(Supvan.STRD_MAT, timeout: 1)
    }

    func sendStream(_ stream: [UInt8]) async throws {
        guard let w = writeChar else { throw BLEError.disconnected }
        let frames = Supvan.dataFrames(stream)
        try await command(Supvan.NEXT_ZIPPEDBULK, 512, frames.count)
        for f in frames {
            clear()
            let before = receivedCount
            for o in stride(from: 0, to: 512, by: 128) {         // iOS app: four 128-byte writes ~10 ms apart
                try await ble.write(Array(f[o..<o + 128]), to: w)
                await sleep(ms: 10)
            }
            let deadline = Date().addingTimeInterval(2)
            while receivedCount == before && Date() < deadline { await sleep(ms: 10) }
            if receivedCount == before { throw PrinterError.message("The printer did not acknowledge the print data.") }
        }
        await sleep(ms: 50)
        try await command(Supvan.BUF_FULL, 0)
    }

    /// Print labels as ONE continuous job.
    func printJob(_ images: [GrayImage], density: Int, log: Log, progress: Progress) async throws {
        let job = Supvan.encodeJob(images.map { Supvan.raster($0) }, density: density, dieCut: media.dieCut,
                                   paperGap: media.gap == 0 ? 3 : media.gap)
        var s = try await status()
        for _ in 0..<30 where s.busy { await sleep(ms: 200); s = try await status() }
        if let e = s.error { throw PrinterError.message(e) }
        _ = try? await command(Supvan.SET_HEADRATE, Supvan.headRate(density))
        try await command(Supvan.START_PRINT, 0)
        do {
            for _ in 0..<30 { await sleep(ms: 200); s = try await status(); if s.printing { break } }
            if !s.printing { throw PrinterError.message("The printer did not start printing.") }
            _ = try? await command(Supvan.PAPER_BACK, job.backFrames)
            var n = 0
            for (li, count) in job.perLabel.enumerated() {
                progress(li, job.perLabel.count)
                for _ in 0..<count {
                    while true {
                        await sleep(ms: 20)
                        s = try await status()
                        if let e = s.error { throw PrinterError.message(e) }
                        if !s.busy && !s.printing { throw PrinterError.message("Printing was stopped on the printer.") }
                        if !s.bufferFull { break }
                    }
                    try await sendStream(job.streams[n])
                    n += 1
                }
            }
            for _ in 0..<1200 { await sleep(ms: 100); s = try await status(); if !s.printing && !s.busy { break } }
            progress(job.perLabel.count, job.perLabel.count)
        } catch {
            _ = try? await command(Supvan.STOP_PRINT)
            throw error
        }
    }

    public func printLabels(_ images: [GrayImage], _ p: PrintParams, log: @escaping Log, progress: @escaping Progress,
                            between: Between?) async throws {
        let density = min(7, max(1, p.density))
        if p.continuous {
            log("job: \(images.count) label(s) in one continuous job")
            try await printJob(images, density: density, log: log, progress: progress)
            return
        }
        progress(0, images.count)
        for (i, img) in images.enumerated() {
            try await printJob([img], density: density, log: log, progress: { _, _ in })
            progress(i + 1, images.count)
            log("  printed \(i + 1)/\(images.count)")
            if let between, i + 1 < images.count, !(await between(i + 1, images.count)) {
                log("Stopped after \(i + 1) of \(images.count) labels.")
                return
            }
        }
    }
}
