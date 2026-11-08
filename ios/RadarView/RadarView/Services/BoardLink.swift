import CoreBluetooth
import Foundation
import Observation

/// The three ESP32 boards, by their advertised BLE names.
enum BoardRole: String, CaseIterable, Identifiable {
    case waist = "Waist"
    case left = "Bracelet-L"
    case right = "Bracelet-R"

    var id: String { rawValue }
    var short: String {
        switch self {
        case .waist: "W"
        case .left: "L"
        case .right: "R"
        }
    }
}

enum Side: CaseIterable, Hashable {
    case left, right
    var board: BoardRole { self == .left ? .left : .right }
    var short: String { self == .left ? "L" : "R" }
}

/// One bracelet write attempt, for the [LOG] sheet.
struct CommandLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let side: Side
    let cmd: BuzzCommand
    let sent: Bool
}

/// Phone → bracelet command: exactly 2 bytes.
/// byte 0 = motor intensity 0–255, byte 1 = duration in 10 ms units.
struct BuzzCommand: Equatable, CustomStringConvertible {
    let intensity: UInt8
    let duration: UInt8

    var data: Data { Data([intensity, duration]) }
    var description: String { String(format: "%02X %02X", intensity, duration) }

    /// FF 32: full power for half a second.
    static let test = BuzzCommand(intensity: 0xFF, duration: 0x32)
}

/// Waist → phone, 10× per second: `{"us":87,"rp":1,"rd":230,"re":64}`
struct WaistFrame: Decodable, Equatable {
    /// Ultrasonic distance in cm; -1 = no echo.
    var us: Int
    /// Radar present, 0/1.
    var rp: Int
    /// Radar distance in cm.
    var rd: Int
    /// Radar energy 0–100.
    var re: Int

    private enum CodingKeys: String, CodingKey { case us, rp, rd, re }

    init(us: Int = -1, rp: Int = 0, rd: Int = 0, re: Int = 0) {
        self.us = us
        self.rp = rp
        self.rd = rd
        self.re = re
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys, _ fallback: Int) -> Int {
            guard let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil else { return fallback }
            return Int(v.rounded())
        }
        us = int(.us, -1)
        rp = int(.rp, 0)
        rd = int(.rd, 0)
        re = int(.re, 0)
    }

    static func parse(_ data: Data) -> WaistFrame? {
        try? JSONDecoder().decode(WaistFrame.self, from: data)
    }
}

/// BLE central for the waist unit and both bracelets (Afin's contract).
/// Scans for the shared service, connects to all three by name, subscribes to the
/// waist stream, writes 2-byte buzz commands without response, holds strong
/// references to every peripheral and characteristic, and reconnects on disconnect.
@MainActor
@Observable
final class BoardLink: NSObject {
    static let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    static let writeUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")
    static let notifyUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")

    /// "ON", "OFF", "DENIED", "UNSUPPORTED", "…"
    private(set) var bluetooth = "…"
    /// Boards whose characteristic is discovered (bracelet: writable; waist: notifying).
    private(set) var ready: Set<BoardRole> = []
    private(set) var waist: WaistFrame?
    private(set) var waistRaw = ""
    private(set) var waistRate: Double = 0
    private(set) var writes = 0
    private(set) var droppedWrites = 0
    /// Last command actually sent to each bracelet.
    private(set) var lastSent: [Side: CommandLogEntry] = [:]
    /// Recent write attempts, newest first.
    private(set) var commandLog: [CommandLogEntry] = []

    @ObservationIgnored private(set) var waistUpdatedAt: Date?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [BoardRole: CBPeripheral] = [:]
    @ObservationIgnored private var writeChars: [BoardRole: CBCharacteristic] = [:]
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var frameTimes: [Date] = []

    func isReady(_ role: BoardRole) -> Bool { ready.contains(role) }

    /// Latest raw ultrasonic reading if it is fresh (< 1 s old); -1 = no echo.
    func currentUS(now: Date) -> Int? {
        guard let w = waist, let t = waistUpdatedAt, now.timeIntervalSince(t) < 1 else { return nil }
        return w.us
    }

    /// Latest waist frame if it is fresh (< 1 s old).
    func freshWaist(now: Date) -> WaistFrame? {
        guard let t = waistUpdatedAt, now.timeIntervalSince(t) < 1 else { return nil }
        return waist
    }

    func start() {
        running = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfNeeded()
        }
    }

    func stop() {
        running = false
        central?.stopScan()
        for p in peripherals.values { central?.cancelPeripheralConnection(p) }
        peripherals.removeAll()
        writeChars.removeAll()
        notifyChar = nil
        ready.removeAll()
        waist = nil
        waistUpdatedAt = nil
        frameTimes.removeAll()
        waistRate = 0
    }

    /// Write one 2-byte command to a bracelet with `.withoutResponse`.
    /// Returns false (and drops it) if that bracelet isn't connected or its queue is full.
    @discardableResult
    func write(_ cmd: BuzzCommand, to side: Side) -> Bool {
        let role = side.board
        guard let p = peripherals[role], p.state == .connected, let c = writeChars[role],
              p.canSendWriteWithoutResponse else {
            droppedWrites += 1
            logCommand(CommandLogEntry(time: Date(), side: side, cmd: cmd, sent: false))
            return false
        }
        p.writeValue(cmd.data, for: c, type: .withoutResponse)
        writes += 1
        let entry = CommandLogEntry(time: Date(), side: side, cmd: cmd, sent: true)
        lastSent[side] = entry
        logCommand(entry)
        return true
    }

    private func logCommand(_ e: CommandLogEntry) {
        commandLog.insert(e, at: 0)
        if commandLog.count > 120 { commandLog.removeLast(commandLog.count - 120) }
    }

    /// Recompute the waist update rate (call regularly).
    func refreshRate(now: Date) {
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        let rate = Double(frameTimes.count) / 2
        if abs(rate - waistRate) >= 0.5 || (rate == 0 && waistRate != 0) { waistRate = rate }
    }

    // MARK: - Internals

    private func role(of p: CBPeripheral) -> BoardRole? {
        peripherals.first { $0.value === p }?.key
    }

    private func scanIfNeeded() {
        guard running, let central, central.state == .poweredOn else { return }
        if BoardRole.allCases.allSatisfy({ peripherals[$0] != nil }) {
            central.stopScan()
        } else if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    private func managerStateChanged(_ s: CBManagerState) {
        switch s {
        case .poweredOn:
            bluetooth = "ON"
            // Re-issue pending connects for boards we already know, then scan for the rest.
            for p in peripherals.values where p.state != .connected { central?.connect(p, options: nil) }
            scanIfNeeded()
        case .poweredOff: bluetooth = "OFF"; ready.removeAll()
        case .unauthorized: bluetooth = "DENIED"
        case .unsupported: bluetooth = "UNSUPPORTED"
        default: bluetooth = "…"
        }
    }

    private func discovered(_ p: CBPeripheral, name: String?) {
        guard running, let name, let role = BoardRole(rawValue: name), peripherals[role] == nil else { return }
        peripherals[role] = p          // strong reference, or iOS drops the connection
        p.delegate = self
        central?.connect(p, options: nil)
        scanIfNeeded()
    }

    private func connected(_ p: CBPeripheral) {
        p.discoverServices([Self.serviceUUID])
    }

    private func linkLost(_ p: CBPeripheral) {
        guard let role = role(of: p) else { return }
        ready.remove(role)
        writeChars[role] = nil
        if role == .waist {
            notifyChar = nil
            waist = nil
            waistUpdatedAt = nil
        }
        // A pending connect never times out: iOS completes it when the board is back.
        if running { central?.connect(p, options: nil) }
    }

    private func servicesFound(_ p: CBPeripheral) {
        for s in p.services ?? [] where s.uuid == Self.serviceUUID {
            p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        }
    }

    private func characteristicsFound(_ p: CBPeripheral, service: CBService) {
        guard let role = role(of: p) else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.writeUUID, role != .waist {
                writeChars[role] = c
                ready.insert(role)
            } else if c.uuid == Self.notifyUUID, role == .waist {
                notifyChar = c
                p.setNotifyValue(true, for: c)
            }
        }
    }

    private func notifyStateChanged(_ p: CBPeripheral, _ c: CBCharacteristic) {
        if c.uuid == Self.notifyUUID, c.isNotifying, role(of: p) == .waist { ready.insert(.waist) }
    }

    private func received(_ data: Data) {
        guard let frame = WaistFrame.parse(data) else { return }
        let now = Date()
        waist = frame
        waistRaw = String(decoding: data, as: UTF8.self)
        waistUpdatedAt = now
        frameTimes.append(now)
    }
}

extension BoardLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        MainActor.assumeIsolated { self.managerStateChanged(s) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        MainActor.assumeIsolated { self.discovered(peripheral, name: name) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.connected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.linkLost(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.linkLost(peripheral) }
    }
}

extension BoardLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.servicesFound(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { self.characteristicsFound(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { self.notifyStateChanged(peripheral, characteristic) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            if uuid == BoardLink.notifyUUID { self.received(data) }
        }
    }
}
