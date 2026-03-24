//
//  LLMIntentResolver.swift
//  SparkController
//
//  Falls back to Claude (via OpenRouter) when keyword matching fails.
//  Sends the raw voice text and gets back structured drone intents.
//

import Foundation

final class LLMIntentResolver {

    // MARK: - Configuration

    /// OpenRouter API key. Set this before first use.
    /// You can set it at runtime:  LLMIntentResolver.shared.apiKey = "sk-or-..."
    static let shared = LLMIntentResolver()

    var apiKey: String = ""   // Set your OpenRouter key here or at runtime

    var model: String = "anthropic/claude-sonnet-4"

    /// Whether to include current telemetry in the prompt for context-aware commands
    var currentTelemetry: TelemetryData?

    /// Callback for status updates
    var onStatusChanged: ((String) -> Void)?

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // MARK: - System Prompt

    private var systemPrompt: String {
        var prompt = """
        You are a drone flight controller AI. The user gives you natural language commands \
        and you convert them into structured JSON actions for a DJI Spark drone.

        SAFETY RULES (never violate):
        - Maximum movement distance: 10 meters per command
        - Maximum altitude: 30 meters
        - Minimum altitude: 1 meter
        - If a command seems dangerous or unclear, return a "hover" intent instead
        - Never exceed these limits even if the user asks

        AVAILABLE INTENTS — return one or more as a JSON array:

        {"intent": "take_off"}
        {"intent": "land"}
        {"intent": "take_photo"}
        {"intent": "photo_position"}
        {"intent": "move", "direction": "<up|down|forward|backward|left|right>", "meters": <number>}
        {"intent": "rotate", "degrees": <number>}  // positive = clockwise, negative = counter-clockwise
        {"intent": "set_altitude", "meters": <number>}
        {"intent": "hover"}
        {"intent": "stab_off"}       // disable stabilization agent
        {"intent": "record"}         // toggle flight data recording on/off
        {"intent": "stream"}         // toggle peer video streaming on/off

        RESPONSE FORMAT — always return valid JSON with this structure:
        {
          "intents": [ ... one or more intent objects ... ],
          "explanation": "brief description of what you're doing"
        }

        EXAMPLES:
        User: "go up a bit and take a photo"
        {"intents": [{"intent": "move", "direction": "up", "meters": 2.0}, {"intent": "take_photo"}], "explanation": "Moving up 2m then taking a photo"}

        User: "turn around"
        {"intents": [{"intent": "rotate", "degrees": 180}], "explanation": "Rotating 180 degrees clockwise"}

        User: "go to 5 meters high"
        {"intents": [{"intent": "set_altitude", "meters": 5.0}], "explanation": "Setting altitude to 5 meters"}

        User: "move forward a little and then come back"
        {"intents": [{"intent": "move", "direction": "forward", "meters": 2.0}, {"intent": "move", "direction": "backward", "meters": 2.0}], "explanation": "Moving forward 2m then back 2m"}

        User: "do a panorama"
        {"intents": [{"intent": "take_photo"}, {"intent": "rotate", "degrees": 90}, {"intent": "take_photo"}, {"intent": "rotate", "degrees": 90}, {"intent": "take_photo"}, {"intent": "rotate", "degrees": 90}, {"intent": "take_photo"}], "explanation": "Taking 4 photos at 90 degree intervals for a panorama"}

        If the user says something completely unrelated to drone control, return:
        {"intents": [{"intent": "hover"}], "explanation": "Command not understood, hovering safely"}
        """

        if let t = currentTelemetry {
            prompt += """

            CURRENT DRONE STATE:
            - Altitude: \(String(format: "%.1f", t.altitude))m
            - Flying: \(t.isFlying)
            - Pitch: \(String(format: "%.1f", t.pitch))°, Roll: \(String(format: "%.1f", t.roll))°, Yaw: \(String(format: "%.1f", t.yaw))°
            - GPS signal: \(t.gpsSignalLevel), Satellites: \(t.satelliteCount)
            - Flight mode: \(t.flightMode)

            Use this state to make informed decisions (e.g., if already at 5m and user says "go higher", add a reasonable amount).
            """
        }

        return prompt
    }

    // MARK: - Public API

    /// Resolve a natural language command into one or more DroneIntents.
    /// Calls Claude via OpenRouter. Returns on main thread.
    func resolve(text: String, completion: @escaping ([DroneIntent], String?) -> Void) {
        guard !apiKey.isEmpty else {
            print("[LLM] No API key set — cannot resolve")
            onStatusChanged?("LLM: no API key")
            DispatchQueue.main.async {
                completion([], "No OpenRouter API key configured")
            }
            return
        }

        print("[LLM] Resolving: \"\(text)\"")
        onStatusChanged?("LLM: thinking...")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.1,
            "max_tokens": 512
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("HaloCamDemo/1.0", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("HaloCam Drone Controller", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 15

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[LLM] JSON encode error: \(error)")
            DispatchQueue.main.async { completion([], error.localizedDescription) }
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[LLM] Network error: \(error.localizedDescription)")
                self?.onStatusChanged?("LLM: network error")
                DispatchQueue.main.async { completion([], error.localizedDescription) }
                return
            }

            guard let data = data else {
                print("[LLM] No data")
                DispatchQueue.main.async { completion([], "No data received") }
                return
            }

            // Parse OpenRouter response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "?"
                print("[LLM] Unexpected response: \(raw)")
                self?.onStatusChanged?("LLM: bad response")
                DispatchQueue.main.async { completion([], "Unexpected API response") }
                return
            }

            print("[LLM] Raw response: \(content)")

            // Parse the JSON intents from Claude's response
            let (intents, explanation) = Self.parseIntents(from: content)
            print("[LLM] Parsed \(intents.count) intent(s): \(intents.map(\.description))")
            self?.onStatusChanged?("LLM: \(explanation ?? "done")")

            DispatchQueue.main.async {
                completion(intents, explanation)
            }
        }.resume()
    }

    // MARK: - Response Parsing

    /// Extract the JSON from Claude's response (handles markdown code blocks too)
    private static func parseIntents(from content: String) -> ([DroneIntent], String?) {
        // Strip markdown code fences if present
        var jsonStr = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.hasPrefix("```") {
            // Remove ```json and closing ```
            let lines = jsonStr.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            jsonStr = filtered.joined(separator: "\n")
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentList = json["intents"] as? [[String: Any]] else {
            print("[LLM] Failed to parse JSON from: \(content)")
            return ([.hover], "Failed to parse response")
        }

        let explanation = json["explanation"] as? String

        var intents: [DroneIntent] = []
        for item in intentList {
            guard let intentType = item["intent"] as? String else { continue }

            switch intentType {
            case "take_off":
                intents.append(.takeOff)
            case "land":
                intents.append(.land)
            case "take_photo":
                intents.append(.takePhoto)
            case "photo_position":
                intents.append(.photoPosition)
            case "hover":
                intents.append(.hover)
            case "move":
                if let dirStr = item["direction"] as? String,
                   let dir = MoveDirection(rawValue: dirStr),
                   let meters = item["meters"] as? Double {
                    // Clamp to safety limits
                    let safe = min(max(meters, 0.5), 10.0)
                    intents.append(.move(direction: dir, meters: safe))
                }
            case "rotate":
                if let degrees = item["degrees"] as? Double {
                    let safe = min(max(degrees, -360), 360)
                    intents.append(.rotate(degrees: safe))
                }
            case "set_altitude":
                if let meters = item["meters"] as? Double {
                    let safe = min(max(meters, 1.0), 30.0)
                    intents.append(.setAltitude(meters: safe))
                }
            case "stab_off":
                intents.append(.stabOff)
            case "record":
                intents.append(.record)
            case "stream":
                intents.append(.stream)
            default:
                print("[LLM] Unknown intent type: \(intentType)")
            }
        }

        if intents.isEmpty {
            intents.append(.hover)
        }

        return (intents, explanation)
    }
}
