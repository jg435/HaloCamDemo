#!/usr/bin/env swift
//
//  HaloCam Flight Data Receiver
//
//  Connects to the HaloCam iOS app via Multipeer Connectivity (Bluetooth/WiFi Direct)
//  and logs telemetry + video frames to disk in real time.
//
//  Usage:
//    cd HaloCamReceiver
//    swift receiver.swift [output_dir]
//
//  The script discovers the iPhone automatically. Telemetry is printed to stdout
//  and saved as CSV. JPEG frames are saved to an output directory.
//

import Foundation
import MultipeerConnectivity

// MARK: - Config

let serviceType = "halocam-data"
let outputDir: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "flight_data_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))"

// Create output dirs
let framesDir = "\(outputDir)/frames"
try? FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)

// CSV file
let csvPath = "\(outputDir)/telemetry.csv"
FileManager.default.createFile(atPath: csvPath, contents: "timestamp,pitch,roll,yaw,vx,vy,vz,alt,gps,sats,flying,mode\n".data(using: .utf8))
let csvHandle = FileHandle(forWritingAtPath: csvPath)!
csvHandle.seekToEndOfFile()

var frameCount = 0

print("HaloCam Receiver")
print("Output: \(outputDir)/")
print("Searching for HaloCam device...")
print("")

// MARK: - Receiver

class Receiver: NSObject, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    var session: MCSession!
    var browser: MCNearbyServiceBrowser!

    func start() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self

        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    // MARK: Browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        print("Found: \(peerID.displayName) – inviting...")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost: \(peerID.displayName)")
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            print("Connected to \(peerID.displayName)")
            print("Receiving telemetry...\n")
            print("  timestamp    pitch   roll    yaw     vx      vy      vz     alt   gps sats fly mode")
            print("  " + String(repeating: "-", count: 90))
        case .connecting:
            print("Connecting to \(peerID.displayName)...")
        case .notConnected:
            print("Disconnected from \(peerID.displayName)")
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let str = String(data: data.prefix(2), encoding: .utf8) else { return }

        if str.hasPrefix("T,") {
            // Telemetry line
            if let line = String(data: data, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = trimmed.dropFirst(2) // remove "T,"

                // Write to CSV
                if let csvData = "\(parts)\n".data(using: .utf8) {
                    csvHandle.write(csvData)
                }

                // Print to console (formatted)
                let cols = parts.split(separator: ",")
                if cols.count >= 12 {
                    let formatted = String(format: "  %-10s %+6s %+6s %+6s  %+6s %+6s %+6s %5s  %2s  %3s  %3s  %s",
                        String(cols[0]).padding(toLength: 10, withPad: " ", startingAt: 0) as NSString,
                        String(cols[1]) as NSString,
                        String(cols[2]) as NSString,
                        String(cols[3]) as NSString,
                        String(cols[4]) as NSString,
                        String(cols[5]) as NSString,
                        String(cols[6]) as NSString,
                        String(cols[7]) as NSString,
                        String(cols[8]) as NSString,
                        String(cols[9]) as NSString,
                        String(cols[10]) as NSString,
                        String(cols[11]) as NSString)
                    print(formatted)
                }
            }
        } else if str.hasPrefix("F,") {
            // Frame JPEG
            let jpegData = data.dropFirst(2)
            frameCount += 1
            let path = "\(framesDir)/frame_\(String(format: "%05d", frameCount)).jpg"
            try? jpegData.write(to: URL(fileURLWithPath: path))
            print("  [Frame \(frameCount) saved: \(jpegData.count) bytes]")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Main

let receiver = Receiver()
receiver.start()

// Keep running
print("Press Ctrl+C to stop.\n")
RunLoop.current.run()
