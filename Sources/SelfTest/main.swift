// Emits the encoders' output for deterministic inputs as JSON, so scripts/compare_python.py can check
// it byte-for-byte against the Python BLEPrint implementation.
import BLEPrintCore
import Foundation

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func pattern(_ w: Int, _ h: Int, _ f: (Int, Int) -> Bool) -> GrayImage {
    var img = GrayImage(width: w, height: h)
    for y in 0..<h { for x in 0..<w where f(x, y) { img[x, y] = 0 } }
    return img
}

import ImageIO
import UniformTypeIdentifiers
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    func save(_ img: GrayImage, _ name: String) {
        guard let cg = img.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        print(name, img.width, "x", img.height)
    }
    save(Render.supvanText("Hello E10!", lengthMM: nil), "sv_fit")
    save(Render.supvanText("{Name}\nSKU-1234", lengthMM: 40), "sv_fixed_2line")
    save(Render.supvanQR("https://pardostech.com", lengthMM: nil, showText: false), "sv_qr_only")
    save(Render.supvanQR("BLEPrint\nSKU-1234", lengthMM: nil, showText: true), "sv_qr_text")
    save(Render.nelkoText("Hello World!", headMM: 15, feedMM: 40).rotatedCW(), "nk_text_view")
    save(Render.nelkoQR("BLEPrint", headMM: 15, feedMM: 40, showText: true).rotatedCW(), "nk_qr_view")
    print("qr modules for pardostech:", Render.qrMatrix("https://pardostech.com")?.count ?? -1)
    exit(0)
}

if CommandLine.arguments.contains("--scan") || CommandLine.arguments.contains("--e10") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let found = try await BLE.shared.scan(seconds: 8)
            for d in found where d.brand != nil { print("FOUND", d.name, d.brand!.rawValue, d.rssi, "|", d.reason) }
            print("devices seen:", found.count)
            if let i = CommandLine.arguments.firstIndex(of: "--e10"), let dev = found.first(where: { $0.brand == .supvan }),
               let drv = makeDriver(for: dev) {
                print("connected:", try await drv.connect(log: { print($0) }))
                var p = PrintParams(); p.density = 4; p.continuous = true
                let text = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "Swift!"
                try await drv.printLabels([Render.supvanText(text, lengthMM: nil)], p, log: { print($0) },
                                          progress: { print("progress \($0)/\($1)") }, between: nil)
                print("PRINT DONE"); drv.disconnect()
            }
        } catch { print("ERROR:", error.localizedDescription) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--nelko-csv"), i + 1 < CommandLine.arguments.count {
    // Same as the app's "Print ALL rows" on a Nelko: CSV -> template -> one label per row.
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let csv = CSV.parse(try String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8))
            print("columns:", csv.columns, "rows:", csv.rows.count)
            let tmpl = "{Names}\n{Model}"
            let images = csv.rows.map { row -> GrayImage in
                var t = tmpl
                for c in csv.columns { t = t.replacingOccurrences(of: "{\(c)}", with: row[c] ?? "") }
                print("  label:", t.replacingOccurrences(of: "\n", with: " / "))
                return Render.nelkoText(t, headMM: 14, feedMM: 40)
            }
            let found = try await BLE.shared.scan(seconds: 8)
            guard let dev = found.first(where: { $0.brand == .nelko }), let drv = makeDriver(for: dev) as? NelkoDriver else {
                print("NO NELKO FOUND"); sem.signal(); return
            }
            print("connected:", try await drv.connect(log: { print($0) }), "|", dev.reason)
            let st = try await drv.status()
            print("status query ESC!? ->", st.map { String(format: "0x%02X", $0) } ?? "no reply (will use timed waits)")
            var p = PrintParams(); p.headMM = 14; p.feedMM = 40; p.density = 10; p.speed = 3
            let t0 = Date()
            try await drv.printLabels(images, p, log: { print($0) }, progress: { print("progress \($0)/\($1)") }, between: nil)
            print(String(format: "PRINT DONE in %.1f s", Date().timeIntervalSince(t0)))
            drv.disconnect()
        } catch { print("ERROR:", error.localizedDescription) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--nelko-ink") {
    let t = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "OMG"
    let img = Render.nelkoText(t, headMM: 14, feedMM: 40)
    if let b = img.inkBounds() { print("swift", img.width, img.height, b.x, b.y, b.w, b.h) }
    exit(0)
}

let label1 = pattern(400, 88) { x, y in x > 30 && (x * 7 + y * 13) % 29 < 9 }
let label2 = pattern(900, 88) { x, y in (x * 3 + y * 5) % 17 < 6 }
let job = Supvan.encodeJob([Supvan.raster(label1), Supvan.raster(label2)], density: 4)
var fixed = [UInt8](repeating: 0, count: 4000)
for i in 0..<4000 { fixed[i] = UInt8((i * 31 + i / 7) % 251) }
let nelkoImg = pattern(Nelko.printDots(15), Nelko.dots(40)) { x, y in (x + y * 3) % 11 < 4 }
let nelkoImg14 = pattern(Nelko.printDots(14), Nelko.dots(40)) { x, y in (x + y * 3) % 11 < 4 }

let out: [String: Any] = [
    "cmd": [hex(Supvan.commandFrame(0x11)), hex(Supvan.commandFrame(0x5C, 512, 3)), hex(Supvan.commandFrame(0xC9, 110))],
    "headrate": (1...7).map { Supvan.headRate($0) },
    "compress_fixed": hex(Supvan.compress(fixed)),
    "frames": Supvan.dataFrames(Supvan.compress(fixed)).map(hex),
    "job_buffers": job.buffers.map(hex),
    "job_streams": job.streams.map(hex),
    "job_per_label": job.perLabel,
    "job_back": job.backFrames,
    "tspl": hex(Nelko.tsplJob(nelkoImg, headMM: 15, feedMM: 40, gapMM: 2.0, density: 10, speed: 3)),
    "tspl_copies": hex(Nelko.tsplJob(nelkoImg14, headMM: 14, feedMM: 40, gapMM: 5.0, density: 10, speed: 3, copies: 3)),
]
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
