//
//  PeerStreamService.swift
//  SparkController
//
//  Streams telemetry + low-res video frames to a nearby Mac via
//  Multipeer Connectivity (works over Bluetooth even while the iPhone's
//  WiFi is connected to the drone).
//
//  On the Mac side, run the companion receiver:
//    swift HaloCamReceiver/receiver.swift
//

import Foundation
import UIKit
import MultipeerConnectivity

final class PeerStreamService: NSObject {

    private let serviceType = "halocam-data"   // max 15 chars, lowercase + hyphens
    private let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?

    private(set) var isAdvertising = false

    var connectedPeerCount: Int { session?.connectedPeers.count ?? 0 }

    /// Status callback (main thread)
    var onStatusChanged: ((String) -> Void)?

    override init() {
        myPeerID = MCPeerID(displayName: UIDevice.current.name)
        super.init()
    }

    // MARK: - Public

    func startAdvertising() {
        guard !isAdvertising else { return }

        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        session?.delegate = self

        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["app": "HaloCam"], serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        isAdvertising = true
        print("[PeerStream] Advertising – waiting for laptop")
        onStatusChanged?("Stream: waiting…")
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        advertiser = nil
        session = nil
        isAdvertising = false
        print("[PeerStream] Stopped")
        onStatusChanged?("Stream: off")
    }

    /// Send a telemetry row (unreliable / UDP-like – low latency, may drop)
    func sendTelemetry(_ d: TelemetryData) {
        guard let s = session, !s.connectedPeers.isEmpty else { return }

        let ts = ProcessInfo.processInfo.systemUptime
        let line = String(format: "T,%.3f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.2f,%d,%d,%@,%@\n",
            ts, d.pitch, d.roll, d.yaw,
            d.velocityX, d.velocityY, d.velocityZ,
            d.altitude, d.gpsSignalLevel, d.satelliteCount,
            d.isFlying ? "1" : "0", d.flightMode)

        guard let data = line.data(using: .utf8) else { return }
        try? s.send(data, toPeers: s.connectedPeers, with: .unreliable)
    }

    /// Send a low-res JPEG thumbnail (reliable – guaranteed delivery)
    func sendFrame(_ image: UIImage) {
        guard let s = session, !s.connectedPeers.isEmpty else { return }

        // Downscale to 320×240 for Bluetooth bandwidth
        let size = CGSize(width: 320, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }

        guard let jpeg = thumb.jpegData(compressionQuality: 0.4) else { return }

        var payload = Data("F,".utf8)
        payload.append(jpeg)
        try? s.send(payload, toPeers: s.connectedPeers, with: .reliable)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerStreamService: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("[PeerStream] Invitation from \(peerID.displayName) – accepting")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[PeerStream] Advertise failed: \(error.localizedDescription)")
        onStatusChanged?("Stream: failed")
    }
}

// MARK: - MCSessionDelegate

extension PeerStreamService: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("[PeerStream] Connected: \(peerID.displayName)")
                self.onStatusChanged?("Stream: \(session.connectedPeers.count) peer(s)")
            case .connecting:
                break
            case .notConnected:
                print("[PeerStream] Disconnected: \(peerID.displayName)")
                let n = session.connectedPeers.count
                self.onStatusChanged?(n > 0 ? "Stream: \(n) peer(s)" : "Stream: no peers")
            @unknown default:
                break
            }
        }
    }

    // Unused – we only send, never receive
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
