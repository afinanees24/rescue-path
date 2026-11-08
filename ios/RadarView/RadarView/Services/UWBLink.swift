import Foundation
import MultipeerConnectivity
import NearbyInteraction
import Observation
import simd

enum AppRole: String {
    case firefighter, beacon
}

/// Ultra Wideband ranging between the firefighter's phone and the beacon phone.
/// MultipeerConnectivity carries the NI discovery tokens (the firefighter browses and
/// invites; the beacon advertises and accepts), then NearbyInteraction streams
/// distance and direction several times a second.
@MainActor
@Observable
final class UWBLink: NSObject {
    /// Bonjour service type; must match NSBonjourServices (_ff-uwb._tcp / _ff-uwb._udp).
    nonisolated static let serviceType = "ff-uwb"

    enum Status: Equatable {
        case idle, unsupported, searching, connected, ranging

        var label: String {
            switch self {
            case .idle: "UWB OFF"
            case .unsupported: "NO UWB"
            case .searching: "SEARCHING"
            case .connected: "LINKED"
            case .ranging: "RANGING"
            }
        }
    }

    let role: AppRole
    private(set) var status: Status = .idle
    private(set) var peerName: String?
    /// Latest raw values (unsmoothed).
    private(set) var distance: Double?
    private(set) var bearing: Double?
    private(set) var rawDirection: SIMD3<Float>?
    private(set) var rawHorizontalAngle: Float?
    private(set) var lastUpdate: Date?
    private(set) var supportsDirection = false
    private(set) var cameraAssist = false
    private(set) var convergence = ""
    private(set) var lastError: String?
    /// Flip the camera-assisted horizontal angle if left/right comes out reversed on device.
    var flipHorizontalAngle = false

    /// Called on every NI update with (distance m, bearing deg); nil = not measured.
    @ObservationIgnored var onSample: (@MainActor (Double?, Double?) -> Void)?

    nonisolated(unsafe) private let myPeer: MCPeerID
    nonisolated(unsafe) private let mcSession: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var ni: NISession?
    @ObservationIgnored private var peerToken: NIDiscoveryToken?
    @ObservationIgnored private var running = false

    init(role: AppRole) {
        self.role = role
        let suffix = String(UUID().uuidString.prefix(4))
        myPeer = MCPeerID(displayName: (role == .beacon ? "BEACON-" : "FF-") + suffix)
        mcSession = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        mcSession.delegate = self
    }

    var isLinked: Bool { status == .connected || status == .ranging }

    /// True if an NI update arrived in the last `seconds`.
    func isFresh(now: Date, within seconds: TimeInterval = 1.5) -> Bool {
        guard let t = lastUpdate else { return false }
        return now.timeIntervalSince(t) < seconds
    }

    func start() {
        guard !running else { return }
        running = true
        lastError = nil
        let caps = NISession.deviceCapabilities
        guard caps.supportsPreciseDistanceMeasurement else {
            status = .unsupported
            lastError = "This iPhone has no UWB chip"
            return
        }
        supportsDirection = caps.supportsDirectionMeasurement
        makeNISession()
        switch role {
        case .beacon:
            let a = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: ["role": "beacon"],
                                              serviceType: Self.serviceType)
            a.delegate = self
            a.startAdvertisingPeer()
            advertiser = a
        case .firefighter:
            let b = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
        }
        status = .searching
    }

    func stop() {
        running = false
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        mcSession.disconnect()
        ni?.invalidate()
        ni = nil
        peerToken = nil
        peerName = nil
        clearMeasurement()
        if status != .unsupported { status = .idle }
    }

    // MARK: - NI session

    private func makeNISession() {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = .main
        ni = s
        if peerToken != nil { runSession() }
        sendToken()
    }

    private func sendToken() {
        guard let token = ni?.discoveryToken, !mcSession.connectedPeers.isEmpty else { return }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try mcSession.send(data, toPeers: mcSession.connectedPeers, with: .reliable)
        } catch {
            lastError = "Token send failed: \(error.localizedDescription)"
        }
    }

    private func receivedToken(_ data: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else {
            lastError = "Bad token from peer"
            return
        }
        peerToken = token
        runSession()
    }

    private func runSession() {
        guard let ni, let peerToken else { return }
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        // Some newer iPhones only report direction with camera assistance.
        if role == .firefighter, !supportsDirection, NISession.deviceCapabilities.supportsCameraAssistance {
            config.isCameraAssistanceEnabled = true
            cameraAssist = true
        }
        ni.run(config)
    }

    private func clearMeasurement() {
        distance = nil
        bearing = nil
        rawDirection = nil
        rawHorizontalAngle = nil
        lastUpdate = nil
    }

    // MARK: - Event handlers (main actor)

    private func peerChanged(name: String, state: MCSessionState) {
        switch state {
        case .connected:
            peerName = name
            status = .connected
            sendToken()
        case .notConnected:
            guard name == peerName || peerName == nil else { return }
            peerName = nil
            peerToken = nil
            clearMeasurement()
            if running {
                status = .searching
                ni?.invalidate()
                makeNISession()
            }
        default:
            break
        }
    }

    private func update(distance d: Float?, direction: SIMD3<Float>?, horizontalAngle: Float?) {
        rawDirection = direction
        rawHorizontalAngle = horizontalAngle
        distance = d.map(Double.init)
        if let v = direction {
            // Phone frame: +x right, +y up, −z forward. 0° ahead, + right, − left.
            bearing = Double(atan2(v.x, -v.z)) * 180 / .pi
        } else if let h = horizontalAngle {
            bearing = Double(h) * 180 / .pi * (flipHorizontalAngle ? -1 : 1)
        } else {
            bearing = nil
        }
        lastUpdate = Date()
        status = .ranging
        onSample?(distance, bearing)
    }

    private func objectsRemoved(timeout: Bool) {
        clearMeasurement()
        if peerName != nil { status = .connected }
        if timeout { runSession() }
    }

    private func invalidated(_ message: String) {
        lastError = message
        clearMeasurement()
        guard running else { return }
        makeNISession()
    }

    private func setConvergence(_ text: String) { convergence = text }
    private func setError(_ text: String) { lastError = text }
}

// MARK: - NISessionDelegate (delegateQueue = main)

extension UWBLink: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let obj = nearbyObjects.first else { return }
        let d = obj.distance
        let dir = obj.direction
        let h = obj.horizontalAngle
        MainActor.assumeIsolated { self.update(distance: d, direction: dir, horizontalAngle: h) }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                             reason: NINearbyObject.RemovalReason) {
        let timeout = reason == .timeout
        MainActor.assumeIsolated { self.objectsRemoved(timeout: timeout) }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {}

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        MainActor.assumeIsolated { self.runSession() }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.invalidated(message) }
    }

    nonisolated func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence,
                             for object: NINearbyObject?) {
        let text: String
        switch convergence.status {
        case .converged: text = "CONVERGED"
        case .notConverged(let reasons):
            text = reasons.isEmpty ? "NOT CONVERGED" : reasons.compactMap { $0.localizedDescription }.joined(separator: ", ")
        case .unknown: text = "UNKNOWN"
        @unknown default: text = ""
        }
        MainActor.assumeIsolated { self.setConvergence(text) }
    }
}

// MARK: - Multipeer (callbacks arrive on background queues)

extension UWBLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        Task { @MainActor in self.peerChanged(name: name, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.receivedToken(data) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension UWBLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "beacon", mcSession.connectedPeers.isEmpty else { return }
        browser.invitePeer(peerID, to: mcSession, withContext: nil, timeout: 10)
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let message = "Browse failed: \(error.localizedDescription)"
        Task { @MainActor in self.setError(message) }
    }
}

extension UWBLink: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(mcSession.connectedPeers.isEmpty, mcSession)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let message = "Advertise failed: \(error.localizedDescription)"
        Task { @MainActor in self.setError(message) }
    }
}
