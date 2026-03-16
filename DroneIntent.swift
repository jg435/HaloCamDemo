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
        
        // Photo position / selfie pose
        if s.contains("photo position") ||
           s.contains("selfie position") ||
           s.contains("selfie mode") {
            return .photoPosition
        }
        
        // Take off
        if s.contains("take off") || s.contains("takeoff") || s.contains("lift off") || s.contains("launch") {
            return .takeOff
        }
        
        // Land
        if s.contains("land") {
            return .land
        }
        
        // Take a photo
        if s.contains("take a photo") ||
           s.contains("take photo") ||
           s.contains("take a picture") ||
           s.contains("take picture") ||
           s.contains("snapshot") {
            return .takePhoto
        }
        
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

