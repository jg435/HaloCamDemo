//
//  DroneIntent.swift
//

import Foundation

// MARK: - Move Direction

enum MoveDirection: String, Codable, CaseIterable {
    case up, down, forward, backward, left, right
}

// MARK: - Drone Intent

enum DroneIntent {
    // ── Original keyword-matched intents ──
    case takeOff
    case land
    case takePhoto
    case photoPosition

    // ── New LLM-resolved intents ──
    case move(direction: MoveDirection, meters: Double)
    case rotate(degrees: Double)        // positive = clockwise
    case setAltitude(meters: Double)
    case hover

    // ── System toggle intents ──
    case stabOff
    case record
    case stream
}

// MARK: - Keyword Parser (fast, no network)

struct DroneIntentParser {

    static func parse(text: String) -> DroneIntent? {
        let s = text.lowercased()
        print("[VoiceAgent] Parsing text: '\(text)' -> lowercased: '\(s)'")

        // Photo position / selfie pose
        if s.contains("photo position") ||
           s.contains("selfie position") ||
           s.contains("selfie mode") {
            print("[VoiceAgent] Matched: photoPosition")
            return .photoPosition
        }

        // Take off
        if s.contains("take off") || s.contains("takeoff") || s.contains("lift off") || s.contains("launch") {
            print("[VoiceAgent] Matched: takeOff")
            return .takeOff
        }

        // Land
        if s.contains("land") {
            print("[VoiceAgent] Matched: land")
            return .land
        }

        // Take a photo
        if s.contains("take a photo") ||
           s.contains("take photo") ||
           s.contains("take a picture") ||
           s.contains("take picture") ||
           s.contains("snapshot") {
            print("[VoiceAgent] Matched: takePhoto")
            return .takePhoto
        }

        // Hover / stay / hold
        if s.contains("hover") || s.contains("stay") || s.contains("hold position") {
            print("[VoiceAgent] Matched: hover")
            return .hover
        }

        // Stabilization off
        if s.contains("stab off") || s.contains("stabilization off") || s.contains("stabilisation off") {
            print("[VoiceAgent] Matched: stabOff")
            return .stabOff
        }

        // Record (toggle)
        if s.contains("record") || s.contains("rec") || s.contains("start recording") || s.contains("stop recording") {
            print("[VoiceAgent] Matched: record")
            return .record
        }

        // Stream (toggle)
        if s.contains("stream") || s.contains("start stream") || s.contains("stop stream") {
            print("[VoiceAgent] Matched: stream")
            return .stream
        }

        print("[VoiceAgent] No keyword match")
        return nil
    }
}

// MARK: - CustomStringConvertible

extension DroneIntent: CustomStringConvertible {
    var description: String {
        switch self {
        case .takeOff:                      return "Take Off"
        case .land:                         return "Land"
        case .takePhoto:                    return "Take Photo"
        case .photoPosition:                return "Photo Position"
        case .move(let dir, let m):         return "Move \(dir.rawValue) \(String(format: "%.1f", m))m"
        case .rotate(let deg):              return "Rotate \(String(format: "%.0f", deg))°"
        case .setAltitude(let m):           return "Go to \(String(format: "%.1f", m))m"
        case .hover:                        return "Hover"
        case .stabOff:                      return "Stabilization Off"
        case .record:                       return "Toggle Recording"
        case .stream:                       return "Toggle Stream"
        }
    }
}
