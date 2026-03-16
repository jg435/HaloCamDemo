//
//  VoiceCommandController.swift
//

import Foundation
import Speech
import AVFoundation

final class VoiceCommandController: NSObject {
    
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioSession = AVAudioSession.sharedInstance()
    
    /// Called on main thread when we successfully map a command.
    /// Parameters: (rawText: String, intent: DroneIntent)
    var onIntentDetected: ((String, DroneIntent) -> Void)?
    
    private(set) var isListening: Bool = false
    private var isStopping: Bool = false
    
    // MARK: - Public
    
    func startListening() {
        if isListening { return }
        
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            guard status == .authorized else {
                print("Speech recognition not authorized: \(status.rawValue)")
                return
            }
            
            DispatchQueue.main.async {
                do {
                    try self.startRecognitionSession()
                    self.isListening = true
                } catch {
                    print("Failed to start recognition session: \(error)")
                    self.isListening = false
                }
            }
        }
    }
    
    func stopListening() {
        if !isListening { return }
        
        // Mark that we're stopping - this tells the completion handler to process any result
        isStopping = true
        
        // Stop capturing new audio
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Signal that no more audio is coming - this triggers finalization
        recognitionRequest?.endAudio()
        
        // DON'T cancel the task here - let it finalize naturally
        // The completion handler will clean up when it gets the final result
        isListening = false
    }
    
    // MARK: - Private
    
    private func startRecognitionSession() throws {
        // Cleanup any existing session
        recognitionTask?.cancel()
        recognitionTask = nil
        isStopping = false
        
        // Configure audio session for recording
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceCommandController",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = false
        
        let inputNode = audioEngine.inputNode
        
        // Ensure no duplicate taps
        inputNode.removeTap(onBus: 0)
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer, _) in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            // Process result if it's final OR if we're stopping (even if not marked final)
            if let result = result {
                let text = result.bestTranscription.formattedString
                
                if result.isFinal {
                    self.handleRecognizedText(text)
                } else if self.isStopping && !text.isEmpty {
                    // We stopped listening, so process this as the final result
                    self.handleRecognizedText(text)
                }
            }
            
            // Handle errors - but also check if we got a result even if not final
            if let error = error {
                print("Recognition error: \(error.localizedDescription)")
                // Even on error, try to process any text we got
                if let result = result, !result.bestTranscription.formattedString.isEmpty {
                    self.handleRecognizedText(result.bestTranscription.formattedString)
                }
            }
            
            // Clean up when we get a final result, error, or when we've stopped listening
            let shouldCleanup = error != nil || (result?.isFinal ?? false) || self.isStopping
            
            if shouldCleanup {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.isListening = false
                self.isStopping = false
                
                do {
                    try self.audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    print("Failed to deactivate audio session: \(error)")
                }
            }
        }
    }
    
    private func handleRecognizedText(_ text: String) {
        print("Recognized: \(text)")
        if let intent = DroneIntentParser.parse(text: text) {
            DispatchQueue.main.async {
                self.onIntentDetected?(text, intent)
            }
        } else {
            print("No intent matched for: \(text)")
        }
    }
}

