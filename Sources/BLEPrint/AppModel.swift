import AppKit
import BLEPrintCore
import SwiftUI

enum PrintMode: Int, CaseIterable, Identifiable {
    case text, qrText, qrOnly
    var id: Int { rawValue }
    var title: String { ["Text", "QR code + text", "QR code only"][rawValue] }
}

@MainActor
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    // printer
    @Published var brand: Brand = Brand(rawValue: UserDefaults.standard.string(forKey: "brand") ?? "") ?? .nelko {
        didSet { defaults.set(brand.rawValue, forKey: "brand"); applyBrand() }
    }
    @Published var device: FoundDevice?
    @Published var connected = false
    @Published var connDetail = ""
    @Published var busy = false
    var driver: PrinterDriver?

    // scan
    @Published var showScan = false
    @Published var scanning = false
    @Published var scanResults: [FoundDevice] = []
    @Published var showAllDevices = false

    // settings
    @Published var headMM = 14.0 { didSet { refreshPreview() } }
    @Published var feedMM = 40.0 { didSet { refreshPreview() } }
    @Published var gapMM = Nelko.defaultGapMM          // P21 14 x 40 mm rolls have a 5 mm gap
    @Published var density = 10
    @Published var speed = 3
    @Published var copies = 1
    @Published var fitLength = UserDefaults.standard.object(forKey: "fitLength") as? Bool ?? true {
        didSet { defaults.set(fitLength, forKey: "fitLength"); refreshPreview() }
    }
    @Published var continuous = false
    @Published var mode: PrintMode = PrintMode(rawValue: UserDefaults.standard.integer(forKey: "printMode")) ?? .text {
        didSet { defaults.set(mode.rawValue, forKey: "printMode"); refreshPreview() }
    }

    // data
    @Published var template = "{Name}\n{SKU}" { didSet { refreshPreview() } }
    @Published var columns: [String] = []
    @Published var rows: [[String: String]] = []
    @Published var current = 0 { didSet { refreshPreview() } }
    @Published var csvName = "No CSV loaded"

    // output
    @Published var preview: CGImage?
    @Published var log: [String] = ["Ready. Find your printer, open a CSV, edit the template, preview, then print."]
    @Published var progress = (value: 0, total: 1)
    @Published var confirmPrintAll = false
    @Published var pause: (done: Int, total: Int)?
    private var pauseContinuation: CheckedContinuation<Bool, Never>?

    init() {
        applyBrand()
        BLE.shared.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.connected = false
                self.connDetail = ""
                self.say("Printer disconnected.")
            }
        }
    }

    // MARK: brand-aware settings

    var fitActive: Bool { brand.supportsFitLength && fitLength }
    var continuousActive: Bool { brand.supportsContinuous && continuous }

    func applyBrand() {
        if !brand.densityRange.contains(density) { density = brand.defaultDensity }
        if let fixed = brand.fixedHeadMM { headMM = fixed } else if headMM == 12 { headMM = 14 }   // P21 default roll: 14 x 40 mm
        if !brand.supportsContinuous { continuous = false }
        refreshPreview()
    }

    // MARK: rendering

    func text(for index: Int) -> String {
        var t = template.trimmingCharacters(in: .newlines)
        if rows.indices.contains(index) {
            for c in columns { t = t.replacingOccurrences(of: "{\(c)}", with: rows[index][c] ?? "") }
        }
        return t.isEmpty ? "Hello World!" : t
    }

    func render(_ index: Int) -> GrayImage {
        let t = text(for: index)
        switch brand {
        case .nelko:
            return mode == .text ? Render.nelkoText(t, headMM: headMM, feedMM: feedMM)
                : Render.nelkoQR(t, headMM: headMM, feedMM: feedMM, showText: mode == .qrText)
        case .supvan:
            let length: Double? = fitActive ? nil : feedMM
            return mode == .text ? Render.supvanText(t, lengthMM: length)
                : Render.supvanQR(t, lengthMM: length, showText: mode == .qrText)
        }
    }

    func refreshPreview() {
        let img = render(current)
        preview = (brand == .nelko ? img.rotatedCW() : img).cgImage   // show it reading left to right
    }

    // MARK: log

    func say(_ s: String) {
        log.append(s)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: CSV

    func openCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parsed = CSV.parse(try String(contentsOf: url, encoding: .utf8))
            columns = parsed.columns
            rows = parsed.rows
            csvName = "\(url.lastPathComponent)  (\(rows.count) rows)"
            say("Loaded \(rows.count) rows · columns: \(columns.joined(separator: ", "))")
            current = 0
        } catch {
            say("✖ Could not read CSV: \(error.localizedDescription)")
        }
    }

    func insertColumn(_ c: String) { template += "{\(c)}" }

    func go(_ delta: Int) {
        guard !rows.isEmpty else { return }
        current = max(0, min(rows.count - 1, current + delta))
    }

    // MARK: Bluetooth

    func scan() {
        scanning = true
        say("Searching for Bluetooth devices (8 s)…")
        Task {
            do {
                let found = try await BLE.shared.scan(seconds: 8)
                scanResults = found
                say("Found \(found.count) devices, \(found.filter { $0.brand != nil }.count) supported printer(s).")
            } catch { say("✖ \(error.localizedDescription)") }
            scanning = false
        }
    }

    func connect(_ d: FoundDevice) {
        guard let brand = d.brand, let drv = makeDriver(for: d) else { return }
        showScan = false
        device = d
        self.brand = brand
        say("Selected \(d.name) — \(brand.displayName) (detected by \(d.reason))")
        busy = true
        Task {
            do {
                connDetail = try await drv.connect(log: { [weak self] m in Task { @MainActor in self?.say(m) } })
                driver = drv
                connected = true
                say("Connected to \(d.name) (\(drv.label)).")
            } catch { say("✖ \(error.localizedDescription)") }
            busy = false
        }
    }

    func toggleConnection() {
        if connected {
            driver?.disconnect()
            driver = nil
            connected = false
            connDetail = ""
            say("Disconnected.")
        } else if let d = device {
            connect(d)
        } else {
            showScan = true
            scan()
        }
    }

    // MARK: printing

    var params: PrintParams {
        var p = PrintParams()
        p.headMM = headMM; p.feedMM = feedMM; p.gapMM = gapMM
        p.density = density; p.speed = speed; p.copies = max(1, copies)
        p.continuous = continuousActive; p.fitLength = fitActive
        return p
    }

    func printCurrent() {
        let img = render(current)
        say("Printing row \(current + 1) ×\(max(1, copies))\(continuousActive ? " (continuous)" : "")…")
        run(Array(repeating: img, count: max(1, copies)))
    }

    func printAll() {
        var images: [GrayImage] = []
        for i in rows.indices { images += Array(repeating: render(i), count: max(1, copies)) }
        say("Batch printing \(rows.count) rows (\(images.count) labels)\(continuousActive ? " as one continuous job" : "")…")
        run(images)
    }

    private func run(_ images: [GrayImage]) {
        guard connected, let drv = driver else {
            say("Not connected — use Find printer… first.")
            return
        }
        busy = true
        let p = params
        let pauses = brand.pauseBetweenLabels && !p.continuous && images.count > 1
        Task {
            do {
                try await drv.printLabels(images, p,
                                          log: { [weak self] m in Task { @MainActor in self?.say(m) } },
                                          progress: { [weak self] v, t in Task { @MainActor in self?.progress = (v, max(1, t)) } },
                                          between: pauses ? { [weak self] done, total in await self?.askToContinue(done, total) ?? false } : nil)
                say("Done.")
            } catch { say("✖ \(error.localizedDescription)") }
            busy = false
        }
    }

    func askToContinue(_ done: Int, _ total: Int) async -> Bool {
        NSSound.beep()
        return await withCheckedContinuation { c in
            pauseContinuation = c
            pause = (done, total)
        }
    }

    func answerPause(_ goOn: Bool) {
        if let p = pause { say("  label \(p.done)/\(p.total) done — \(goOn ? "continuing" : "stopped by user")") }
        pause = nil
        pauseContinuation?.resume(returning: goOn)
        pauseContinuation = nil
    }
}
