//
//  DroneIntent.swift
//

import Foundation

enum DroneIntent {
    case takeOff
    case land
    case takePhoto
    case photoPosition
}

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

        print("[VoiceAgent] No match found")
        return nil
    }
}

// Optional: nicer debug description for the label
extension DroneIntent: CustomStringConvertible {
    var description: String {
        switch self {
        case .takeOff:        return "Take Off"
        case .land:           return "Land"
        case .takePhoto:      return "Take Photo"
        case .photoPosition:  return "Photo Position"
        }
    }
}

