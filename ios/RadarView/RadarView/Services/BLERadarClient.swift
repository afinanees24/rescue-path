import CoreBluetooth
import Foundation
import Observation

enum BLEState: Equatable {
    case idle, poweredOff, unauthorized, unsupported, scanning, connecting, connected, reconnecting

    var label: String {
        switch self {
        case .idle: "BLE idle"
        case .poweredOff: "Bluetooth off"
        case .unauthorized: "BLE not allowed"
        case .unsupported: "BLE unsupported"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        }
    }
}

/// CoreBluetooth central: finds the peripheral named "FF-RADAR", subscribes to its
/// notify characteristic and decodes each JSON notification into a `RadarFrame`.
/// Reconnects automatically when the link drops.
@MainActor
@Observable
final class BLERadarClient: NSObject {
    static let deviceName = "FF-RADAR"
    static let serviceUUID = CBUUID(string: "8E2F0001-6B1D-4C6A-9F3E-2A7C5D9B1E40")
    static let characteristicUUID = CBUUID(string: "8E2F0002-6B1D-4C6A-9F3E-2A7C5D9B1E40")

    private(set) var state: BLEState = .idle
    private(set) var connectedName: String?

    @ObservationIgnored var onFrame: (@MainActor (RadarFrame) -> Void)?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var buffer = Data()

    func start() {
        wantsRunning = true
        if central == nil {
            // Creating the manager triggers the Bluetooth permission prompt the first time.
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            resume()
        }
    }

    func stop() {
        wantsRunning = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        connectedName = nil
        buffer.removeAll()
        state = .idle
    }

    // MARK: - Internals

    private func resume() {
        guard wantsRunning, let central, central.state == .poweredOn else { return }
        if let p = peripheral {
            state = .reconnecting
            central.connect(p, options: nil)
        } else {
            state = .scanning
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func managerStateChanged(_ s: CBManagerState) {
        switch s {
        case .poweredOn: resume()
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: break
        }
    }

    private func discovered(_ p: CBPeripheral, name: String?) {
        guard wantsRunning, peripheral == nil, name == Self.deviceName else { return }
        central?.stopScan()
        peripheral = p
        connectedName = name
        p.delegate = self
        state = .connecting
        central?.connect(p, options: nil)
    }

    private func didConnect(_ p: CBPeripheral) {
        guard p === peripheral else { return }
        buffer.removeAll()
        p.discoverServices(nil)
    }

    private func linkLost(_ p: CBPeripheral) {
        guard p === peripheral else { return }
        buffer.removeAll()
        guard wantsRunning, let central else { state = .idle; return }
        // A pending connect never times out: iOS completes it as soon as the ESP32 is back.
        state = .reconnecting
        central.connect(p, options: nil)
    }

    private func servicesFound(_ p: CBPeripheral) {
        let services = p.services ?? []
        let preferred = services.filter { $0.uuid == Self.serviceUUID }
        for s in (preferred.isEmpty ? services : preferred) {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    private func characteristicsFound(_ p: CBPeripheral, service: CBService) {
        let chars = service.characteristics ?? []
        let match = chars.first { $0.uuid == Self.characteristicUUID }
            ?? chars.first { $0.properties.contains(.notify) }
        if let c = match { p.setNotifyValue(true, for: c) }
    }

    private func notifyStateChanged(_ c: CBCharacteristic) {
        if c.isNotifying { state = .connected }
    }

    private func received(_ data: Data) {
        // Normally one notification = one JSON object. If the MTU is small and the
        // object arrives in pieces, stitch them back together.
        if data.first == UInt8(ascii: "{") { buffer = data } else { buffer.append(data) }
        if let frame = RadarFrame.parse(buffer) {
            buffer.removeAll()
            onFrame?(frame)
        } else if buffer.count > 1024 {
            buffer.removeAll()
        }
    }
}

extension BLERadarClient: CBCentralManagerDelegate {
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
        MainActor.assumeIsolated { self.didConnect(peripheral) }
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

extension BLERadarClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.servicesFound(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { self.characteristicsFound(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { self.notifyStateChanged(characteristic) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { self.received(data) }
    }
}
