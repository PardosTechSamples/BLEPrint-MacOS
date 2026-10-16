import CoreBluetooth
import Foundation

public struct FoundDevice: Identifiable {
    public let id: UUID
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int
    public let brand: Brand?
    public let reason: String
    public let mac: String?
}

public enum BLEError: LocalizedError {
    case off(String), timeout(String), notFound(String), disconnected
    public var errorDescription: String? {
        switch self {
        case .off(let s): return s
        case .timeout(let s): return "Timed out: \(s)"
        case .notFound(let s): return s
        case .disconnected: return "The printer disconnected."
        }
    }
}

/// CoreBluetooth wrapped in async/await. One shared central; one connected peripheral at a time.
public final class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let shared = BLE()

    private let queue = DispatchQueue(label: "bleprint.ble")
    private var central: CBCentralManager!
    private var stateWaiters: [CheckedContinuation<Void, Error>] = []
    private var found: [UUID: FoundDevice] = [:]
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var discoverWaiter: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var readyWaiter: CheckedContinuation<Void, Never>?
    public private(set) var peripheral: CBPeripheral?
    public var onData: ((Data) -> Void)?
    public var onDisconnect: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: power state

    private func ready() async throws {
        if central.state == .poweredOn { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.central.state == .poweredOn { c.resume() } else { self.stateWaiters.append(c) }
            }
        }
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let waiters = stateWaiters
        switch c.state {
        case .poweredOn:
            stateWaiters = []; waiters.forEach { $0.resume() }
        case .unauthorized:
            stateWaiters = []; waiters.forEach { $0.resume(throwing: BLEError.off("Bluetooth permission was denied. Allow it in System Settings → Privacy & Security → Bluetooth.")) }
        case .poweredOff:
            stateWaiters = []; waiters.forEach { $0.resume(throwing: BLEError.off("Bluetooth is turned off.")) }
        default: break
        }
    }

    // MARK: scan

    public func scan(seconds: Double = 8) async throws -> [FoundDevice] {
        try await ready()
        queue.sync { found = [:] }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        central.stopScan()
        return queue.sync {
            found.values.sorted { ($0.brand == nil ? 1 : 0, -$0.rssi) < ($1.brand == nil ? 1 : 0, -$1.rssi) }
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let mfr = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let id = Detection.identify(name: name, manufacturerData: mfr, services: services)
        let prev = found[p.identifier]
        // keep the most informative sighting (named / recognised)
        if prev == nil || (prev!.brand == nil && id.brand != nil) || (prev!.name.isEmpty && !name.isEmpty) {
            found[p.identifier] = FoundDevice(id: p.identifier, peripheral: p, name: name, rssi: rssi.intValue,
                                              brand: id.brand, reason: id.reason, mac: id.mac)
        }
    }

    // MARK: connect

    public func connect(_ p: CBPeripheral, timeout: Double = 20) async throws {
        try await ready()
        if let old = peripheral, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        do {
            try await withTimeout(timeout, "connecting") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.queue.async { self.connectWaiter = c; self.central.connect(p) }
                }
            }
        } catch {
            queue.sync {
                connectWaiter?.resume(throwing: error); connectWaiter = nil
                central.cancelPeripheralConnection(p)
            }
            peripheral = nil
            throw error
        }
        try await withTimeout(15, "discovering services") {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.queue.async { self.discoverWaiter = c; p.discoverServices(nil) }
            }
        }
    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    public var isConnected: Bool { peripheral?.state == .connected }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connectWaiter?.resume(); connectWaiter = nil
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connectWaiter?.resume(throwing: error ?? BLEError.disconnected); connectWaiter = nil
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connectWaiter?.resume(throwing: BLEError.disconnected); connectWaiter = nil
        discoverWaiter?.resume(throwing: BLEError.disconnected); discoverWaiter = nil
        if p.identifier == peripheral?.identifier { onDisconnect?() }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        pendingServices = services.count
        if services.isEmpty { discoverWaiter?.resume(); discoverWaiter = nil }
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pendingServices -= 1
        if pendingServices <= 0 { discoverWaiter?.resume(); discoverWaiter = nil }
    }

    /// First characteristic whose short UUID is in `uuids` (in that order of preference).
    public func characteristic(_ uuids: [String]) -> CBCharacteristic? {
        let all = (peripheral?.services ?? []).flatMap { $0.characteristics ?? [] }
        // Compare CBUUIDs, not strings: under a custom 128-bit service CoreBluetooth spells 16-bit
        // characteristics out in full ("0000FFE9-0000-1000-8000-00805F9B34FB").
        for u in uuids { if let c = all.first(where: { $0.uuid == CBUUID(string: u) }) { return c } }
        return nil
    }

    /// What was discovered, for error messages: "service: char char …".
    public var discoveredSummary: String {
        (peripheral?.services ?? []).map { s in
            "\(s.uuid.uuidString): " + (s.characteristics ?? []).map(\.uuid.uuidString).joined(separator: " ")
        }.joined(separator: " | ")
    }

    public func subscribe(_ c: CBCharacteristic) { peripheral?.setNotifyValue(true, for: c) }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let v = c.value { onData?(v) }
    }

    // MARK: write

    public var maxWrite: Int { peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20 }

    /// Write without response, waiting for the radio when its buffer is full.
    public func write(_ data: [UInt8], to c: CBCharacteristic) async throws {
        guard let p = peripheral, p.state == .connected else { throw BLEError.disconnected }
        if !p.canSendWriteWithoutResponse {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                queue.async {
                    if p.canSendWriteWithoutResponse { k.resume() } else { self.readyWaiter = k }
                }
            }
        }
        p.writeValue(Data(data), for: c, type: .withoutResponse)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        readyWaiter?.resume(); readyWaiter = nil
    }
}

func withTimeout<T>(_ seconds: Double, _ what: String, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); throw BLEError.timeout(what) }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

public func sleep(ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
