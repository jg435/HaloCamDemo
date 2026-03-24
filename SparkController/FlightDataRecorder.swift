//
//  FlightDataRecorder.swift
//  SparkController
//
//  Records telemetry (CSV) and video frames (JPEG) during flight sessions.
//  Data is saved to the app's Documents/FlightData directory and is
//  accessible via the iOS Files app (UIFileSharingEnabled).
//

import Foundation
import UIKit

final class FlightDataRecorder {

    // MARK: - State

    private(set) var isRecording = false

    /// Callback for UI status updates
    var onStatusChanged: ((String) -> Void)?

    /// Current session directory
    private(set) var sessionDirectory: URL?

    // File I/O
    private var telemetryHandle: FileHandle?
    private var frameCount: Int = 0
    private var telemetryCount: Int = 0

    /// Save a JPEG frame every N telemetry ticks (at 10 Hz: 30 → every 3 s)
    var frameInterval: Int = 30

    private var sessionStart: TimeInterval = 0

    // MARK: - Public API

    func startRecording() {
        guard !isRecording else { return }

        guard let dir = createSessionDirectory() else {
            print("[Recorder] Failed to create session directory")
            onStatusChanged?("REC: dir failed")
            return
        }

        sessionDirectory = dir
        sessionStart = ProcessInfo.processInfo.systemUptime
        frameCount = 0
        telemetryCount = 0

        // Create CSV with header
        let csv = dir.appendingPathComponent("telemetry.csv")
        let header = "t,pitch,roll,yaw,vx,vy,vz,alt,gps,sats,flying,mode,imuPreheat,vision,ultrasonic,drift\n"
        FileManager.default.createFile(atPath: csv.path, contents: header.data(using: .utf8))
        telemetryHandle = FileHandle(forWritingAtPath: csv.path)
        telemetryHandle?.seekToEndOfFile()

        isRecording = true
        print("[Recorder] Recording → \(dir.lastPathComponent)")
        onStatusChanged?("REC")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        telemetryHandle?.closeFile()
        telemetryHandle = nil
        writeSessionSummary()

        let name = sessionDirectory?.lastPathComponent ?? "?"
        print("[Recorder] Stopped – \(name) | \(telemetryCount) rows, \(frameCount) frames")
        onStatusChanged?("REC stopped (\(frameCount) frames)")
        sessionDirectory = nil
    }

    /// Append a telemetry row (called at 10 Hz)
    func recordTelemetry(_ d: TelemetryData) {
        guard isRecording, let h = telemetryHandle else { return }

        let t = ProcessInfo.processInfo.systemUptime - sessionStart
        let row = String(format: "%.3f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.2f,%d,%d,%@,%@,%@,%@,%.2f,%.3f\n",
            t, d.pitch, d.roll, d.yaw,
            d.velocityX, d.velocityY, d.velocityZ,
            d.altitude, d.gpsSignalLevel, d.satelliteCount,
            d.isFlying ? "1" : "0", d.flightMode,
            d.isIMUPreheating ? "1" : "0", d.isVisionPositioning ? "1" : "0",
            d.ultrasonicHeight, d.driftSpeed)

        if let data = row.data(using: .utf8) { h.write(data) }
        telemetryCount += 1
    }

    /// Save a JPEG frame (call only when `shouldCaptureFrame()` returns true)
    func recordVideoFrame(_ image: UIImage) {
        guard isRecording, let dir = sessionDirectory else { return }
        frameCount += 1

        let framesDir = dir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let elapsed = ProcessInfo.processInfo.systemUptime - sessionStart
        let name = String(format: "frame_%05d_t%.2f.jpg", frameCount, elapsed)
        let path = framesDir.appendingPathComponent(name)

        DispatchQueue.global(qos: .utility).async {
            if let jpeg = image.jpegData(compressionQuality: 0.7) {
                try? jpeg.write(to: path)
            }
        }
    }

    /// Returns true every `frameInterval` telemetry ticks
    func shouldCaptureFrame() -> Bool {
        guard isRecording else { return false }
        return telemetryCount % frameInterval == 0
    }

    // MARK: - Session management

    /// Lists previous sessions (newest first) with name, date, size
    static func listSessions() -> [(name: String, date: Date, size: String)] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let root = docs.appendingPathComponent("FlightData")
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }

        return items.compactMap { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date  = attrs?[.creationDate] as? Date ?? Date()
            let bytes = Self.directorySize(url)
            let size  = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return (name: url.lastPathComponent, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Private

    private func createSessionDirectory() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let root = docs.appendingPathComponent("FlightData")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = root.appendingPathComponent("flight_\(fmt.string(from: Date()))")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("[Recorder] mkdir error: \(error)")
            return nil
        }
    }

    private func writeSessionSummary() {
        guard let dir = sessionDirectory else { return }
        let dur = ProcessInfo.processInfo.systemUptime - sessionStart
        let json = """
        {
          "start": "\(ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -dur)))",
          "durationSec": \(String(format: "%.1f", dur)),
          "telemetryRows": \(telemetryCount),
          "frames": \(frameCount),
          "frameInterval": \(frameInterval)
        }
        """
        try? json.data(using: .utf8)?.write(to: dir.appendingPathComponent("session_info.json"))
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in en {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }
}
