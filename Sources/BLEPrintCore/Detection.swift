import Foundation

public enum Brand: String, CaseIterable, Identifiable {
    case nelko, supvan
    public var id: String { rawValue }
    public var displayName: String { self == .nelko ? "Nelko" : "Supvan" }
    public var modelName: String { self == .nelko ? "Nelko P21" : "Supvan E10" }

    public var supportsContinuous: Bool { self == .supvan }
    public var supportsFitLength: Bool { self == .supvan }
    public var pauseBetweenLabels: Bool { self == .supvan }
    public var usesGapSpeed: Bool { self == .nelko }
    public var densityRange: ClosedRange<Int> { self == .nelko ? 0...15 : 1...7 }
    public var defaultDensity: Int { self == .nelko ? 10 : 4 }
    public var fixedHeadMM: Double? { self == .supvan ? 12 : nil }
    public var continuousNote: String {
        self == .nelko
            ? "Continuous printing is disabled on the Nelko P21 until it has been tested."
            : "Send every label in one job so they print back to back on the tape. Without it, BLEPrint pauses after each label so you can cut it."
    }
}

/// Brand detection from a BLE advertisement, strongest signal first:
/// 1. MAC prefix (OUI). macOS hides MAC addresses, but both printers advertise their own MAC in the
///    last 6 bytes of the manufacturer data (that is how the vendor SDKs read it too).
/// 2. Advertised name.  3. Advertised GATT services.
public enum Detection {
    /// A4:93:40 = Beijing Supvan Information Technology (IEEE MA-L).
    /// BE:C0:11 = Nelko P21 prefix (locally administered, so not in the IEEE registry).
    public static let ouiTable: [String: (Brand, String)] = [
        "A49340": (.supvan, "Beijing Supvan Information Technology (IEEE OUI)"),
        "BEC011": (.nelko, "Nelko P21 vendor prefix (locally administered, not IEEE-registered)"),
    ]

    public static func mac(fromManufacturerData data: Data?) -> String? {
        guard let d = data, d.count >= 6 else { return nil }
        return d.suffix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static func identify(name: String, manufacturerData: Data?, services: [String]) -> (brand: Brand?, reason: String, mac: String?) {
        if let mac = mac(fromManufacturerData: manufacturerData),
           let hit = ouiTable[String(mac.replacingOccurrences(of: ":", with: "").prefix(6))] {
            return (hit.0, "MAC \(mac) — \(hit.1)", mac)
        }
        if name.uppercased().hasPrefix("P21") { return (.nelko, "name “\(name)”", nil) }
        if name.range(of: #"^T0\d{3}[A-Z0-9]{6,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return (.supvan, "name “\(name)”", nil)
        }
        for s in services.map({ $0.uppercased() }) {
            if s == "FF00" || s == "0000FF00-0000-1000-8000-00805F9B34FB" { return (.nelko, "service FF00", nil) }
            if s.hasPrefix("0000E0FF-3C17") { return (.supvan, "service E0FF", nil) }
        }
        return (nil, "", nil)
    }
}
