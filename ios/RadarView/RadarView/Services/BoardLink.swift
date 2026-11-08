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
    let bytes: String
    let sent: Bool
}

/// Phone → bracelet command (Afin's firmware): exactly 2 bytes, written without response.
/// byte 0 = cue (0 off · 1 forward flutter · 2 stop · 3 turn), byte 1 = turn intensity 70–255.
/// Patterns run on the bracelet; it stops by itself after 2 s without a command.
struct BraceletCommand: Equatable, CustomStringConvertible {
    let cue: UInt8
    let param: UInt8

    var data: Data { Data([cue, param]) }
    var description: String { String(format: "%02X %02X", cue, param) }

    static let off = BraceletCommand(cue: 0, param: 0)
    static let forward = BraceletCommand(cue: 1, param: 0)
    static let stop = BraceletCommand(cue: 2, param: 0)
    static func turn(_ intensity: UInt8) -> BraceletCommand { BraceletCommand(cue: 3, param: intensity) }

}

/// Waist → phone, 10× per second: `{"us":87,"rp":1,"rd":230,"re":64}`.
/// Only `us` is used (ultrasonic cm, −1 = no echo); rp/rd/re are ignored.
struct WaistFrame: Decodable, Equatable {
    var us: Int

    private enum CodingKeys: String, CodingKey { case us }

    init(us: Int = -1) { self.us = us }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = (try? c.decodeIfPresent(Double.self, forKey: .us)) ?? nil
        us = v.map { Int($0.rounded()) } ?? -1
    }

    static func parse(_ data: Data) -> WaistFrame? {
        try? JSONDecoder().decode(WaistFrame.self, from: data)
    }
}

/// BLE central for the waist unit and both bracelets (Afin's contract).
/// Scans for the shared service, connects to all three by name, subscribes to the
/// waist stream, writes 2-byte cue commands without response, holds strong
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
    /// When each bracelet last acknowledged a with-response write (test panel ✓), and any error.
    private(set) var lastAck: [Side: Date] = [:]
    private(set) var lastWriteError: [Side: String] = [:]
    /// Recent write attempts, newest first.
    private(set) var commandLog: [CommandLogEntry] = []

    // Beacon phone (token exchange over …def9)
    enum BeaconState: String {
        case none = "NOT FOUND", connecting = "CONNECTING", connected = "CONNECTED",
             tokenRead = "TOKEN READ", exchanged = "TOKENS EXCHANGED"
    }
    private(set) var beaconState: BeaconState = .none
    /// Smoothed RSSI of the beacon link (dBm).
    private(set) var beaconRSSI: Double?
    private(set) var tokenReads = 0
    private(set) var tokenWrites = 0
    /// Called with the beacon's archived NI token after each read of …defA.
    @ObservationIgnored var onBeaconToken: (@MainActor (Data) -> Void)?
    /// This phone's current archived NI token (written to …defB).
    @ObservationIgnored var localToken: (@MainActor () -> Data?)?

    @ObservationIgnored private(set) var waistUpdatedAt: Date?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [BoardRole: CBPeripheral] = [:]
    @ObservationIgnored private var writeChars: [BoardRole: CBCharacteristic] = [:]
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var frameTimes: [Date] = []
    /// When each bracelet last went down (or we started looking for it).
    @ObservationIgnored private var downSince: [BoardRole: Date] = [:]
    @ObservationIgnored private var beacon: CBPeripheral?
    @ObservationIgnored private var beaconTokenChar: CBCharacteristic?
    @ObservationIgnored private var beaconWriteChar: CBCharacteristic?
    @ObservationIgnored private var lastRSSIRequest: Date = .distantPast

    func isReady(_ role: BoardRole) -> Bool { ready.contains(role) }

    /// The bracelet firmware only advertises once at boot, so a bracelet that has been
    /// unreachable for a while has to be power-cycled (the waist re-advertises by itself).
    func needsPowerCycle(_ role: BoardRole, now: Date) -> Bool {
        guard role != .waist, !isReady(role), let t = downSince[role] else { return false }
        return now.timeIntervalSince(t) > 8
    }

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
        let t = Date()
        for role in [BoardRole.left, .right] where !isReady(role) && downSince[role] == nil { downSince[role] = t }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfNeeded()
        }
    }

    var beaconConnected: Bool { beacon?.state == .connected && beaconTokenChar != nil }

    /// Rough distance from the beacon link's RSSI (log-distance model), meters.
    var beaconDistanceEstimate: Double? {
        guard beaconConnected, let rssi = beaconRSSI else { return nil }
        let txPowerAt1m = -59.0, pathLoss = 2.2
        return min(60, max(1, pow(10, (txPowerAt1m - rssi) / (10 * pathLoss))))
    }

    /// Re-read the beacon's token (e.g. after its NI session restarted).
    func refreshBeaconToken() {
        guard let p = beacon, p.state == .connected, let c = beaconTokenChar else { return }
        p.readValue(for: c)
    }

    /// Write this phone's token to the beacon (long write, with response).
    func sendLocalToken() {
        guard let p = beacon, p.state == .connected, let c = beaconWriteChar,
              let data = localToken?() else { return }
        p.writeValue(data, for: c, type: .withResponse)
        log("writing our token to beacon (\(data.count) bytes)")
    }

    /// [SCAN]: drop the beacon link and find it again.
    func restartBeacon() {
        if let p = beacon { central?.cancelPeripheralConnection(p) }
        beacon = nil
        beaconTokenChar = nil
        beaconWriteChar = nil
        beaconState = .none
        beaconRSSI = nil
        central?.stopScan()
        scanIfNeeded()
    }

    func stop() {
        running = false
        central?.stopScan()
        if let p = beacon { central?.cancelPeripheralConnection(p) }
        beacon = nil
        beaconTokenChar = nil
        beaconWriteChar = nil
        beaconState = .none
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

    /// Write one 2-byte command to a bracelet, normally `.withoutResponse`. With `acknowledged`
    /// it uses `.withResponse` (the firmware accepts both) so the board's reply can be shown.
    /// Returns false (and drops it) if that bracelet isn't connected or its queue is full.
    @discardableResult
    func write(_ cmd: BraceletCommand, to side: Side, acknowledged: Bool = false) -> Bool {
        writeBytes(cmd.data, label: cmd.description, to: side, acknowledged: acknowledged)
    }

    private func writeBytes(_ data: Data, label: String, to side: Side, acknowledged: Bool) -> Bool {
        let role = side.board
        guard let p = peripherals[role], p.state == .connected, let c = writeChars[role],
              acknowledged || p.canSendWriteWithoutResponse else {
            droppedWrites += 1
            logCommand(CommandLogEntry(time: Date(), side: side, bytes: label, sent: false))
            log("bracelet \(side.short) \(label) DROPPED")
            return false
        }
        p.writeValue(data, for: c, type: acknowledged ? .withResponse : .withoutResponse)
        writes += 1
        log("bracelet \(side.short) \(label)")
        let entry = CommandLogEntry(time: Date(), side: side, bytes: label, sent: true)
        lastSent[side] = entry
        logCommand(entry)
        return true
    }

    private func logCommand(_ e: CommandLogEntry) {
        commandLog.insert(e, at: 0)
        if commandLog.count > 120 { commandLog.removeLast(commandLog.count - 120) }
    }

    /// Recompute the waist update rate and poll the beacon RSSI (call regularly).
    func refreshRate(now: Date) {
        if let p = beacon, p.state == .connected, now.timeIntervalSince(lastRSSIRequest) >= 0.5 {
            lastRSSIRequest = now
            p.readRSSI()
        }
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
        if BoardRole.allCases.allSatisfy({ peripherals[$0] != nil }), beacon?.state == .connected {
            central.stopScan()
        } else if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.serviceUUID, BeaconPeripheral.serviceUUID], options: nil)
        }
    }

    private func managerStateChanged(_ s: CBManagerState) {
        switch s {
        case .poweredOn:
            bluetooth = "ON"
            // Re-issue pending connects for boards we already know, then scan for the rest.
            for p in peripherals.values where p.state != .connected { central?.connect(p, options: nil) }
            if let b = beacon, b.state != .connected { central?.connect(b, options: nil) }
            scanIfNeeded()
        case .poweredOff: bluetooth = "OFF"; ready.removeAll()
        case .resetting:
            // Bluetooth restarted: every peripheral object is invalid, start over.
            bluetooth = "…"
            peripherals.removeAll()
            writeChars.removeAll()
            notifyChar = nil
            ready.removeAll()
            waist = nil
            waistUpdatedAt = nil
            beacon = nil
            beaconTokenChar = nil
            beaconWriteChar = nil
            beaconState = .none
            beaconRSSI = nil
        case .unauthorized: bluetooth = "DENIED"
        case .unsupported: bluetooth = "UNSUPPORTED"
        default: bluetooth = "…"
        }
    }

    private func discovered(_ p: CBPeripheral, name: String?, isBeacon: Bool) {
        guard running else { return }
        if isBeacon {
            if let old = beacon {
                // Accept a re-advertising beacon (new peripheral object) if the old link is down.
                guard old !== p, old.state != .connected else { return }
                central?.cancelPeripheralConnection(old)
                beaconTokenChar = nil
                beaconWriteChar = nil
                log("beacon re-appeared as a new peripheral — switching to it")
            }
            beacon = p
            p.delegate = self
            beaconState = .connecting
            log("beacon phone found (\(name ?? "unnamed")), connecting")
            central?.connect(p, options: nil)
            scanIfNeeded()
            return
        }
        guard let name, let role = BoardRole(rawValue: name), peripherals[role] == nil else { return }
        peripherals[role] = p          // strong reference, or iOS drops the connection
        p.delegate = self
        central?.connect(p, options: nil)
        scanIfNeeded()
    }

    private func connected(_ p: CBPeripheral) {
        if p === beacon {
            beaconState = .connected
            log("beacon BLE connected")
            p.discoverServices([BeaconPeripheral.serviceUUID])
            scanIfNeeded()                   // stop scanning once everything is connected
            return
        }
        p.discoverServices([Self.serviceUUID])
    }

    private func linkLost(_ p: CBPeripheral) {
        if p === beacon {
            beaconTokenChar = nil
            beaconWriteChar = nil
            beaconState = .connecting
            beaconRSSI = nil
            log("beacon BLE link lost — reconnecting")
            if running {
                central?.connect(p, options: nil)
                scanIfNeeded()               // also watch for it re-advertising
            }
            return
        }
        guard let role = role(of: p) else { return }
        ready.remove(role)
        writeChars[role] = nil
        if role == .waist {
            notifyChar = nil
            waist = nil
            waistUpdatedAt = nil
        }
        if role != .waist { downSince[role] = Date() }
        // A pending connect never times out: iOS completes it when the board advertises again.
        // The waist re-advertises itself; a bracelet only does at boot (see needsPowerCycle).
        if running { central?.connect(p, options: nil) }
    }

    private func servicesFound(_ p: CBPeripheral) {
        if p === beacon {
            let found = (p.services ?? []).filter { $0.uuid == BeaconPeripheral.serviceUUID }
            for s in found {
                p.discoverCharacteristics([BeaconPeripheral.tokenUUID, BeaconPeripheral.peerTokenUUID], for: s)
            }
            if found.isEmpty {
                // The beacon app may still be re-adding its service: try again shortly.
                log("beacon service not there yet — retrying")
                Task { @MainActor [weak self, weak p] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, let p, p === self.beacon, p.state == .connected, self.beaconTokenChar == nil else { return }
                    p.discoverServices([BeaconPeripheral.serviceUUID])
                }
            }
            return
        }
        for s in p.services ?? [] where s.uuid == Self.serviceUUID {
            p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        }
    }

    private func characteristicsFound(_ p: CBPeripheral, service: CBService) {
        if p === beacon {
            for c in service.characteristics ?? [] {
                if c.uuid == BeaconPeripheral.tokenUUID { beaconTokenChar = c }
                if c.uuid == BeaconPeripheral.peerTokenUUID { beaconWriteChar = c }
            }
            if let c = beaconTokenChar {
                p.setNotifyValue(true, for: c)       // 1-byte "token changed" signal
                p.readValue(for: c)                  // long read handled by CoreBluetooth
            }
            return
        }
        guard let role = role(of: p) else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.writeUUID, role != .waist {
                writeChars[role] = c
                ready.insert(role)
                downSince[role] = nil
            } else if c.uuid == Self.notifyUUID, role == .waist {
                notifyChar = c
                p.setNotifyValue(true, for: c)
            }
        }
    }

    private func notifyStateChanged(_ p: CBPeripheral, _ c: CBCharacteristic) {
        if c.uuid == Self.notifyUUID, c.isNotifying, role(of: p) == .waist { ready.insert(.waist) }
    }

    private func beaconValue(_ data: Data) {
        guard data.count > 16 else {
            log("beacon says its token changed — re-reading")
            refreshBeaconToken()
            return
        }
        tokenReads += 1
        beaconState = .tokenRead
        log("read beacon token (\(data.count) bytes)")
        onBeaconToken?(data)
        sendLocalToken()
    }

    private func tokenReadFailed(_ error: Error) {
        log("ERROR reading beacon token: \(error.localizedDescription) — watchdog will retry")
    }

    /// The beacon's GATT service changed (its app restarted): rediscover the characteristics.
    private func servicesChanged(_ p: CBPeripheral, _ invalidated: [CBUUID]) {
        // Removal lists the service; the later re-add arrives with an empty list.
        guard p === beacon, invalidated.contains(BeaconPeripheral.serviceUUID) || beaconTokenChar == nil else { return }
        beaconTokenChar = nil
        beaconWriteChar = nil
        beaconState = .connecting
        log("beacon service changed — rediscovering")
        p.discoverServices([BeaconPeripheral.serviceUUID])
    }

    private func braceletWriteAcked(_ p: CBPeripheral, _ error: Error?) {
        guard let role = role(of: p), let side = Side.allCases.first(where: { $0.board == role }) else { return }
        if let error {
            lastWriteError[side] = error.localizedDescription
            log("ERROR bracelet \(side.short) write: \(error.localizedDescription)")
        } else {
            lastWriteError[side] = nil
            lastAck[side] = Date()
        }
    }

    private func tokenWritten(_ error: Error?) {
        if let error {
            log("ERROR writing our token to beacon: \(error.localizedDescription)")
            return
        }
        tokenWrites += 1
        beaconState = .exchanged
        log("our token written to beacon — tokens exchanged")
    }

    private func rssiRead(_ rssi: Double) {
        guard rssi < 0, rssi > -110 else { return }
        beaconRSSI = beaconRSSI.map { $0 + (rssi - $0) * 0.25 } ?? rssi
    }

    nonisolated private func log(_ message: String) { Log.uwb(.firefighter, "BLE: " + message) }

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
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isBeacon = services.contains(BeaconPeripheral.serviceUUID)
        MainActor.assumeIsolated { self.discovered(peripheral, name: name, isBeacon: isBeacon) }
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
        let uuid = characteristic.uuid
        if let error {
            if uuid == BeaconPeripheral.tokenUUID { MainActor.assumeIsolated { self.tokenReadFailed(error) } }
            return
        }
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated {
            if uuid == BoardLink.notifyUUID { self.received(data) }
            else if uuid == BeaconPeripheral.tokenUUID { self.beaconValue(data) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            if uuid == BeaconPeripheral.peerTokenUUID { self.tokenWritten(error) }
            else if uuid == BoardLink.writeUUID { self.braceletWriteAcked(peripheral, error) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let uuids = invalidatedServices.map(\.uuid)
        MainActor.assumeIsolated { self.servicesChanged(peripheral, uuids) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let v = RSSI.doubleValue
        MainActor.assumeIsolated { self.rssiRead(v) }
    }
}
