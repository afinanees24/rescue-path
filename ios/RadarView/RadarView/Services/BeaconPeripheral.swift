import CoreBluetooth
import Foundation
import Observation

/// BEACON side of the token exchange: a BLE peripheral advertising service …def9.
///   …defA  read (+ notify) = this phone's archived NI discovery token. Long reads are
///          served by offset. A 1-byte notification tells the firefighter it changed.
///   …defB  write = the firefighter's archived token (long write, with response).
@MainActor
@Observable
final class BeaconPeripheral: NSObject {
    nonisolated static let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef9")
    nonisolated static let tokenUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdefa")
    nonisolated static let peerTokenUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdefb")

    /// "OFF", "ADVERTISING", "FIREFIGHTER CONNECTED", "BT OFF", "BT DENIED"
    private(set) var state = "OFF"
    private(set) var tokenReads = 0
    private(set) var peerTokensReceived = 0

    @ObservationIgnored var onPeerToken: (@MainActor (Data) -> Void)?
    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var tokenChar: CBMutableCharacteristic?
    @ObservationIgnored private var serviceAdded = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var localToken: Data?

    func start() {
        running = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        } else {
            setUp()
        }
    }

    func stop() {
        running = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        serviceAdded = false
        tokenChar = nil
        subscribers = 0
        state = "OFF"
    }

    /// Publish this phone's (new) token; tells a connected firefighter to re-read it.
    func updateLocalToken(_ data: Data) {
        let changed = localToken != data
        localToken = data
        log("token ready (\(data.count) bytes)\(changed && subscribers > 0 ? ", notifying firefighter" : "")")
        if changed, let manager, let tokenChar, subscribers > 0 {
            manager.updateValue(Data([1]), for: tokenChar, onSubscribedCentrals: nil)
        }
    }

    // MARK: - Internals

    private func setUp() {
        guard running, let manager, manager.state == .poweredOn, !serviceAdded else { return }
        let token = CBMutableCharacteristic(type: Self.tokenUUID, properties: [.read, .notify],
                                            value: nil, permissions: [.readable])
        let peer = CBMutableCharacteristic(type: Self.peerTokenUUID, properties: [.write],
                                           value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [token, peer]
        tokenChar = token
        manager.add(service)
        serviceAdded = true
    }

    private func stateChanged(_ s: CBManagerState) {
        switch s {
        case .poweredOn:
            setUp()
        case .poweredOff:
            state = "BT OFF"; serviceAdded = false
        case .unauthorized:
            state = "BT DENIED"
        default:
            break
        }
    }

    private func serviceReady(_ error: Error?) {
        if let error {
            log("ERROR adding BLE service: \(error.localizedDescription)")
            serviceAdded = false
            return
        }
        manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                   CBAdvertisementDataLocalNameKey: "FF-BEACON"])
        state = "ADVERTISING"
        log("BLE advertising …def9")
    }

    private func handleRead(_ request: CBATTRequest) {
        guard request.characteristic.uuid == Self.tokenUUID, let token = localToken else {
            manager?.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= token.count else {
            manager?.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = token.subdata(in: request.offset..<token.count)
        manager?.respond(to: request, withResult: .success)
        if request.offset == 0 {
            tokenReads += 1
            log("firefighter read our token")
        }
    }

    private func handleWrites(_ requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == Self.peerTokenUUID }) else {
            manager?.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        // Long (prepared) writes arrive as several requests with offsets.
        var data = Data()
        for r in requests.sorted(by: { $0.offset < $1.offset }) {
            guard let v = r.value else { continue }
            if data.count < r.offset { data.append(Data(count: r.offset - data.count)) }
            data.replaceSubrange(r.offset..<min(data.count, r.offset + v.count), with: v)
        }
        manager?.respond(to: first, withResult: .success)
        peerTokensReceived += 1
        log("firefighter wrote its token (\(data.count) bytes)")
        onPeerToken?(data)
    }

    private func subscriptionChanged(_ delta: Int) {
        subscribers = max(0, subscribers + delta)
        state = subscribers > 0 ? "FIREFIGHTER CONNECTED" : "ADVERTISING"
        log(subscribers > 0 ? "firefighter subscribed" : "firefighter unsubscribed")
    }

    nonisolated private func log(_ message: String) { Log.uwb(.beacon, "BLE: " + message) }
}

extension BeaconPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let s = peripheral.state
        MainActor.assumeIsolated { self.stateChanged(s) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.serviceReady(error) }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { log("ERROR advertising: \(error.localizedDescription)") }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated { self.handleRead(request) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated { self.handleWrites(requests) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { self.subscriptionChanged(1) }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated { self.subscriptionChanged(-1) }
    }
}
