//
//  DroneController.swift
//

import Foundation
import UIKit
#if !targetEnvironment(simulator)
import DJISDK
import DJIWidget
#endif

struct TelemetryData {
    var pitch: Double = 0
    var roll: Double = 0
    var yaw: Double = 0
    var velocityX: Float = 0
    var velocityY: Float = 0
    var velocityZ: Float = 0
    var altitude: Double = 0
    var gpsSignalLevel: Int = 0
    var satelliteCount: Int = 0
    var isFlying: Bool = false
    var flightMode: String = "Unknown"
    var isIMUPreheating: Bool = false
    var isVisionPositioning: Bool = false
    var ultrasonicHeight: Double = 0

    var driftSpeed: Float {
        sqrt(velocityX * velocityX + velocityY * velocityY)
    }
}

final class DroneController: NSObject {

    // MARK: - Callbacks

    var onCommandStarted: ((DroneIntent) -> Void)?
    var onCommandCompleted: ((DroneIntent, Error?) -> Void)?
    var onTelemetryUpdate: ((TelemetryData) -> Void)?

    // MARK: - Subsystems

    /// Smart hover agent (PID + vision). RC / voice always override.
    let stabilizationAgent = StabilizationAgent()

    /// Records telemetry CSV + JPEG frames to Documents/FlightData
    let flightDataRecorder = FlightDataRecorder()

    /// Streams telemetry + thumbnails to a laptop via Multipeer Connectivity
    let peerStreamService = PeerStreamService()

    // MARK: - Private

    private let photoDownloader = PhotoDownloader()
    private let videoFeedCapture = VideoFeedCapture()
    private var telemetryLogCounter: Int = 0

    /// Counter used to throttle video-frame snapshots for stabilization + recording
    private var frameSnapshotCounter: Int = 0

    /// Track whether recording should auto-start/stop with flight
    var autoRecordFlights: Bool = true

    /// Track flying state for auto-record
    private var wasFlying = false

    #if !targetEnvironment(simulator)
    private var lastCameraMode: DJICameraMode?
    #endif

    override init() {
        super.init()
        setupPhotoDownloader()
        setupVideoFeedCapture()
        setupCameraDelegate()
    }

    private func setupVideoFeedCapture() {
        videoFeedCapture.onPhotoSaved = { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    print("[TakePhoto] Video feed capture error: \(error.localizedDescription)")
                    self.onCommandCompleted?(.takePhoto, error)
                } else {
                    print("[TakePhoto] Photo saved to iPhone!")
                    self.onCommandCompleted?(.takePhoto, nil)
                }
            }
        }
    }

    // MARK: - Public entry point from voice layer

    func handle(intent: DroneIntent) {
        // Tell stabilization agent a voice command is executing
        stabilizationAgent.isVoiceCommandActive = true

        switch intent {
        case .takeOff:
            startTakeoff()
        case .land:
            startLanding()
        case .takePhoto:
            takePhotoOnce()
        case .photoPosition:
            runPhotoPositionRoutine()
        case .move(let direction, let meters):
            executeMove(direction: direction, meters: meters)
        case .rotate(let degrees):
            executeRotate(degrees: degrees)
        case .setAltitude(let meters):
            executeSetAltitude(meters: meters)
        case .hover:
            executeHover()
        case .stabOff:
            executeStabOff()
        case .record:
            executeToggleRecording()
        case .stream:
            executeToggleStream()
        }
    }

    /// Handle a sequence of intents from the LLM (executes one after another)
    func handleSequence(_ intents: [DroneIntent]) {
        guard !intents.isEmpty else { return }
        var remaining = intents
        let first = remaining.removeFirst()

        // Save the original completion handler
        let originalCompletion = onCommandCompleted

        if remaining.isEmpty {
            // Last intent — use normal handling
            handle(intent: first)
        } else {
            // Chain: execute first, then recurse on completion
            onCommandCompleted = { [weak self] intent, error in
                guard let self = self else { return }
                // Restore and forward
                self.onCommandCompleted = originalCompletion
                originalCompletion?(intent, error)

                if error == nil {
                    // Small delay between chained commands
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.handleSequence(remaining)
                    }
                }
            }
            handle(intent: first)
        }
    }

    // MARK: - Basic actions

    private func startTakeoff() {
        DispatchQueue.main.async {
            self.onCommandStarted?(.takeOff)
        }

        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            print("No aircraft / flight controller")
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(.takeOff, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No aircraft / flight controller"]))
            }
            return
        }

        fc.startTakeoff { error in
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                if let error = error {
                    print("Takeoff error: \(error.localizedDescription)")
                    self.onCommandCompleted?(.takeOff, error)
                } else {
                    print("Takeoff started")
                    self.onCommandCompleted?(.takeOff, nil)
                }
            }
        }
        #else
        print("Takeoff (simulator)")
        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(.takeOff, nil)
        }
        #endif
    }

    private func startLanding() {
        DispatchQueue.main.async {
            self.onCommandStarted?(.land)
        }

        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            print("No aircraft / flight controller")
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(.land, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No aircraft / flight controller"]))
            }
            return
        }

        fc.startLanding { error in
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                if let error = error {
                    print("Landing error: \(error.localizedDescription)")
                    self.onCommandCompleted?(.land, error)
                } else {
                    print("Landing started")
                    self.onCommandCompleted?(.land, nil)
                }
            }
        }
        #else
        print("Landing (simulator)")
        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(.land, nil)
        }
        #endif
    }

    private func takePhotoOnce() {
        print("[TakePhoto] Starting takePhotoOnce() - capturing from video feed")
        DispatchQueue.main.async {
            self.onCommandStarted?(.takePhoto)
        }
        // Voice-command flag cleared in the onPhotoSaved callback
        videoFeedCapture.onPhotoSaved = { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                if let error = error {
                    print("[TakePhoto] Video feed capture error: \(error.localizedDescription)")
                    self.onCommandCompleted?(.takePhoto, error)
                } else {
                    print("[TakePhoto] Photo saved to iPhone!")
                    self.onCommandCompleted?(.takePhoto, nil)
                }
            }
        }
        videoFeedCapture.captureAndSave()
    }

    // MARK: - Photo position routine

    private func runPhotoPositionRoutine() {
        DispatchQueue.main.async {
            self.onCommandStarted?(.photoPosition)
        }

        #if !targetEnvironment(simulator)
        guard let missionControl = DJISDKManager.missionControl() else {
            print("MissionControl unavailable")
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(.photoPosition, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "MissionControl unavailable"]))
            }
            return
        }

        var targetAltitude: Double = 4.5
        if let aircraft = DJISDKManager.product() as? DJIAircraft,
           let fc = aircraft.flightController {
            if let state = fc.value(forKey: "state") as? DJIFlightControllerState {
                let currentAltitude = state.altitude
                targetAltitude = max(currentAltitude + 3.0, 3.0)
                print("Current altitude: \(currentAltitude)m, Target altitude: \(targetAltitude)m")
            } else {
                print("Could not access flight controller state, using default target altitude: \(targetAltitude)m")
            }
        }

        missionControl.stopTimeline()
        missionControl.unscheduleEverything()

        var elements: [DJIMissionControlTimelineElement] = []

        let takeoff = DJITakeOffAction()
        elements.append(takeoff)

        if let goToAltitude = DJIGoToAction(altitude: targetAltitude) {
            elements.append(goToAltitude)
        }

        let shootPhotoAction = DJIShootPhotoAction()
        elements.append(shootPhotoAction)

        missionControl.scheduleElements(elements)
        missionControl.startTimeline()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(.photoPosition, nil)
        }
        #else
        print("Photo position routine (simulator)")
        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(.photoPosition, nil)
        }
        #endif
    }

    // MARK: - Movement commands (LLM-enabled)

    /// Move in a direction for a given distance using virtual sticks.
    /// Uses velocity mode: sends a velocity command for `distance / speed` seconds.
    private func executeMove(direction: MoveDirection, meters: Double) {
        let intent = DroneIntent.move(direction: direction, meters: meters)
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        let speed: Float = 1.0  // m/s — safe, steady speed
        let duration = meters / Double(speed)

        // Map direction to virtual stick axes (body frame)
        // pitch > 0 = forward, roll > 0 = right, throttle > 0 = up
        var pitch: Float = 0, roll: Float = 0, yaw: Float = 0, throttle: Float = 0
        switch direction {
        case .forward:  pitch = speed
        case .backward: pitch = -speed
        case .right:    roll = speed
        case .left:     roll = -speed
        case .up:       throttle = speed
        case .down:     throttle = -speed
        }

        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(intent, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No flight controller"]))
            }
            return
        }

        fc.setVirtualStickModeEnabled(true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.stabilizationAgent.isVoiceCommandActive = false
                    self.onCommandCompleted?(intent, error)
                }
                return
            }

            fc.rollPitchControlMode = .velocity
            fc.yawControlMode = .angularVelocity
            fc.verticalControlMode = .velocity
            fc.rollPitchCoordinateSystem = .body

            print("[Move] \(direction.rawValue) \(meters)m at \(speed) m/s for \(String(format: "%.1f", duration))s")

            // Send commands at 20 Hz for the computed duration
            let cmd = DJIVirtualStickFlightControlData(pitch: pitch, roll: roll, yaw: yaw, verticalThrottle: throttle)
            var elapsed: TimeInterval = 0
            let interval: TimeInterval = 0.05

            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
                elapsed += interval
                if elapsed >= duration {
                    timer.invalidate()
                    // Send zero to stop
                    let stop = DJIVirtualStickFlightControlData(pitch: 0, roll: 0, yaw: 0, verticalThrottle: 0)
                    fc.send(stop, withCompletion: nil)
                    fc.setVirtualStickModeEnabled(false, withCompletion: nil)
                    print("[Move] Complete")
                    DispatchQueue.main.async {
                        self.stabilizationAgent.isVoiceCommandActive = false
                        self.onCommandCompleted?(intent, nil)
                    }
                } else {
                    fc.send(cmd, withCompletion: nil)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        #else
        print("[Move] \(direction.rawValue) \(meters)m (simulator)")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
        #endif
    }

    /// Rotate by a given number of degrees using virtual stick yaw.
    private func executeRotate(degrees: Double) {
        let intent = DroneIntent.rotate(degrees: degrees)
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        let angularSpeed: Float = 30.0  // °/s — smooth rotation
        let duration = abs(degrees) / Double(angularSpeed)
        let yawRate = degrees > 0 ? angularSpeed : -angularSpeed

        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(intent, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No flight controller"]))
            }
            return
        }

        fc.setVirtualStickModeEnabled(true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.stabilizationAgent.isVoiceCommandActive = false
                    self.onCommandCompleted?(intent, error)
                }
                return
            }

            fc.rollPitchControlMode = .velocity
            fc.yawControlMode = .angularVelocity
            fc.verticalControlMode = .velocity
            fc.rollPitchCoordinateSystem = .body

            print("[Rotate] \(degrees)° at \(angularSpeed)°/s for \(String(format: "%.1f", duration))s")

            let cmd = DJIVirtualStickFlightControlData(pitch: 0, roll: 0, yaw: yawRate, verticalThrottle: 0)
            var elapsed: TimeInterval = 0
            let interval: TimeInterval = 0.05

            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
                elapsed += interval
                if elapsed >= duration {
                    timer.invalidate()
                    let stop = DJIVirtualStickFlightControlData(pitch: 0, roll: 0, yaw: 0, verticalThrottle: 0)
                    fc.send(stop, withCompletion: nil)
                    fc.setVirtualStickModeEnabled(false, withCompletion: nil)
                    print("[Rotate] Complete")
                    DispatchQueue.main.async {
                        self.stabilizationAgent.isVoiceCommandActive = false
                        self.onCommandCompleted?(intent, nil)
                    }
                } else {
                    fc.send(cmd, withCompletion: nil)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        #else
        print("[Rotate] \(degrees)° (simulator)")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
        #endif
    }

    /// Set altitude using DJIGoToAction.
    private func executeSetAltitude(meters: Double) {
        let intent = DroneIntent.setAltitude(meters: meters)
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        #if !targetEnvironment(simulator)
        guard let missionControl = DJISDKManager.missionControl() else {
            DispatchQueue.main.async {
                self.stabilizationAgent.isVoiceCommandActive = false
                self.onCommandCompleted?(intent, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "MissionControl unavailable"]))
            }
            return
        }

        missionControl.stopTimeline()
        missionControl.unscheduleEverything()

        if let goTo = DJIGoToAction(altitude: meters) {
            missionControl.scheduleElements([goTo])
            missionControl.startTimeline()
            print("[Altitude] Going to \(meters)m")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
        #else
        print("[Altitude] \(meters)m (simulator)")
        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
        #endif
    }

    /// Just hover — stop any movement, let the agent or FC hold position.
    private func executeHover() {
        let intent = DroneIntent.hover
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        #if !targetEnvironment(simulator)
        if let aircraft = DJISDKManager.product() as? DJIAircraft,
           let fc = aircraft.flightController {
            // Disable virtual sticks so the built-in FC takes over
            fc.setVirtualStickModeEnabled(false, withCompletion: nil)
        }
        #endif

        print("[Hover] Holding position")
        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
    }

    // MARK: - System Toggles

    private func executeStabOff() {
        let intent = DroneIntent.stabOff
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        stabilizationAgent.disable()
        print("[StabOff] Stabilization disabled")

        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
    }

    private func executeToggleRecording() {
        let intent = DroneIntent.record
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        if flightDataRecorder.isRecording {
            flightDataRecorder.stopRecording()
            print("[Record] Recording stopped")
        } else {
            flightDataRecorder.startRecording()
            print("[Record] Recording started")
        }

        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
    }

    private func executeToggleStream() {
        let intent = DroneIntent.stream
        DispatchQueue.main.async { self.onCommandStarted?(intent) }

        if peerStreamService.isAdvertising {
            peerStreamService.stopAdvertising()
            print("[Stream] Streaming stopped")
        } else {
            peerStreamService.startAdvertising()
            print("[Stream] Streaming started")
        }

        DispatchQueue.main.async {
            self.stabilizationAgent.isVoiceCommandActive = false
            self.onCommandCompleted?(intent, nil)
        }
    }

    // MARK: - Photo Download Setup

    private func setupPhotoDownloader() {
        photoDownloader.onPhotoSaved = { error in
            if let error = error {
                print("Photo save error: \(error.localizedDescription)")
            } else {
                print("Photo saved to library successfully")
            }
        }
    }

    private func setupCameraDelegate() {
        #if !targetEnvironment(simulator)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(productConnected),
            name: .productConnected,
            object: nil
        )
        #endif
    }

    @objc private func productConnected() {
        #if !targetEnvironment(simulator)
        print("[DroneController] Product connected")

        videoFeedCapture.setupVideoFeed()

        guard let aircraft = DJISDKManager.product() as? DJIAircraft else {
            print("[DroneController] No aircraft found")
            return
        }

        if let camera = aircraft.camera {
            camera.delegate = self
            print("[DroneController] Camera delegate set")
        }

        // Remote controller delegate for RC-stick priority
        if let rc = aircraft.remoteController {
            rc.delegate = self
            print("[DroneController] RC delegate set — stick priority active")
        }

        setupFlightControllerDelegate(aircraft: aircraft, retries: 5)
        #endif
    }

    #if !targetEnvironment(simulator)
    private func setupFlightControllerDelegate(aircraft: DJIAircraft, retries: Int) {
        if let fc = aircraft.flightController {
            fc.delegate = self
            print("[DroneController] Flight controller delegate set — telemetry active")
        } else if retries > 0 {
            print("[DroneController] Flight controller not ready, retrying in 1s... (\(retries) left)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self,
                      let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
                self.setupFlightControllerDelegate(aircraft: aircraft, retries: retries - 1)
            }
        } else {
            print("[DroneController] ERROR: Flight controller never became available")
        }
    }
    #endif

    // MARK: - Video frame snapshot (for stabilization + recording)

    /// Called by MainViewController when a decoded video frame is available.
    func onDecodedVideoFrame() {
        frameSnapshotCounter += 1
        // Snapshot every 5th frame (~2 Hz at 10 fps decode rate) for perf
        guard frameSnapshotCounter % 5 == 0 else { return }

        #if !targetEnvironment(simulator)
        DJIVideoPreviewer.instance()?.snapshotPreview { [weak self] snapshot in
            guard let self = self, let snapshot = snapshot else { return }
            self.handleSnapshot(snapshot)
        }
        #else
        // Simulator: dummy image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240))
        let snapshot = renderer.image { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        handleSnapshot(snapshot)
        #endif
    }

    private func handleSnapshot(_ snapshot: UIImage) {
        // Feed to stabilization agent
        stabilizationAgent.onVideoFrame(snapshot)

        // Feed to recorder (only at the configured interval)
        if flightDataRecorder.shouldCaptureFrame() {
            flightDataRecorder.recordVideoFrame(snapshot)
        }

        // Stream to laptop
        if peerStreamService.connectedPeerCount > 0, frameSnapshotCounter % 30 == 0 {
            peerStreamService.sendFrame(snapshot)
        }
    }
}

// MARK: - DJICameraDelegate

#if !targetEnvironment(simulator)
extension DroneController: DJICameraDelegate {

    func camera(_ camera: DJICamera, didGenerateNewMediaFile newMedia: DJIMediaFile) {
        print("New media file generated: \(newMedia.fileName ?? "unknown")")

        guard newMedia.mediaType == .JPEG else {
            print("Skipping non-JPEG media: \(newMedia.mediaType.rawValue)")
            return
        }

        downloadAndSavePhoto(mediaFile: newMedia)
    }

    private func downloadAndSavePhoto(mediaFile: DJIMediaFile) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let camera = aircraft.camera else {
            print("No camera available for download")
            return
        }

        camera.getModeWithCompletion { [weak self] mode, error in
            guard let self = self else { return }

            if error == nil {
                self.lastCameraMode = mode
            }

            if mode != .mediaDownload {
                camera.setMode(.mediaDownload) { error in
                    if let error = error {
                        print("Failed to switch to MediaDownload mode: \(error.localizedDescription)")
                        self.photoDownloader.downloadAndSavePhoto(mediaFile: mediaFile)
                    } else {
                        print("Switched to MediaDownload mode")
                        self.photoDownloader.downloadAndSavePhoto(mediaFile: mediaFile)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            if let previousMode = self.lastCameraMode {
                                camera.setMode(previousMode) { error in
                                    if let error = error {
                                        print("Failed to restore camera mode: \(error.localizedDescription)")
                                    } else {
                                        print("Restored camera mode to \(previousMode.rawValue)")
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                self.photoDownloader.downloadAndSavePhoto(mediaFile: mediaFile)
            }
        }
    }
}

// MARK: - DJIFlightControllerDelegate (Telemetry)

extension DroneController: DJIFlightControllerDelegate {

    func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
        var telemetry = TelemetryData()
        telemetry.pitch = state.attitude.pitch
        telemetry.roll = state.attitude.roll
        telemetry.yaw = state.attitude.yaw
        telemetry.velocityX = state.velocityX
        telemetry.velocityY = state.velocityY
        telemetry.velocityZ = state.velocityZ
        telemetry.altitude = state.altitude
        telemetry.gpsSignalLevel = Int(state.gpsSignalLevel.rawValue)
        telemetry.satelliteCount = Int(state.satelliteCount)
        telemetry.isFlying = state.isFlying
        telemetry.flightMode = describeFlightMode(state.flightMode)
        telemetry.isIMUPreheating = state.isIMUPreheating
        telemetry.isVisionPositioning = state.isVisionPositioningSensorBeingUsed
        telemetry.ultrasonicHeight = state.ultrasonicHeightInMeters

        // Console log every ~1 s
        telemetryLogCounter += 1
        if telemetryLogCounter >= 10 {
            telemetryLogCounter = 0
            let drift = String(format: "%.2f", telemetry.driftSpeed)
            print("[Telemetry] P:\(String(format: "%+.1f", telemetry.pitch))° R:\(String(format: "%+.1f", telemetry.roll))° Y:\(String(format: "%+.1f", telemetry.yaw))° | Vel: \(drift) m/s | Alt: \(String(format: "%.1f", telemetry.altitude))m | GPS:\(telemetry.gpsSignalLevel) Sat:\(telemetry.satelliteCount) | Vision:\(telemetry.isVisionPositioning ? "ON" : "OFF") | Mode:\(telemetry.flightMode)")
        }

        // ── Feed subsystems ──

        // 1. Stabilization agent
        stabilizationAgent.onTelemetryUpdate(telemetry)

        // 2. Flight data recorder
        flightDataRecorder.recordTelemetry(telemetry)

        // 3. Peer streaming
        peerStreamService.sendTelemetry(telemetry)

        // 4. Auto-record: start on takeoff, stop on landing
        if autoRecordFlights {
            if telemetry.isFlying && !wasFlying {
                flightDataRecorder.startRecording()
            } else if !telemetry.isFlying && wasFlying {
                flightDataRecorder.stopRecording()
            }
        }
        wasFlying = telemetry.isFlying

        // 5. Trigger frame snapshot (uses DJIVideoPreviewer on main thread)
        DispatchQueue.main.async {
            self.onDecodedVideoFrame()
        }

        DispatchQueue.main.async {
            self.onTelemetryUpdate?(telemetry)
        }
    }

    func flightController(_ fc: DJIFlightController, didUpdate imuState: DJIIMUState) {
        let gyroState = imuState.gyroscopeState
        let accelState = imuState.accelerometerState
        let calState = imuState.calibrationState

        if gyroState != .normalBias || accelState != .normalBias {
            print("[IMU] Gyro:\(describeIMUSensorState(gyroState)) Accel:\(describeIMUSensorState(accelState)) Cal:\(describeCalibrationState(calState))")
        }
    }

    private func describeFlightMode(_ mode: DJIFlightMode) -> String {
        switch mode {
        case .manual: return "Manual"
        case .atti: return "ATTI"
        case .attiCourseLock: return "ATTI-CL"
        case .gpsAtti: return "GPS-ATTI"
        case .gpsCourseLock: return "GPS-CL"
        case .gpsHomeLock: return "GPS-HL"
        case .gpsHotPoint: return "HotPoint"
        case .assistedTakeoff: return "AssistedTakeoff"
        case .autoTakeoff: return "AutoTakeoff"
        case .autoLanding: return "AutoLanding"
        case .goHome: return "GoHome"
        case .joystick: return "Joystick"
        case .gpsWaypoint: return "Waypoint"
        case .gpsFollowMe: return "FollowMe"
        case .draw: return "Draw"
        case .activeTrack: return "ActiveTrack"
        case .tapFly: return "TapFly"
        case .gpsSport: return "Sport"
        case .gpsNovice: return "Novice"
        case .motorsJustStarted: return "MotorsStarted"
        case .confirmLanding: return "ConfirmLanding"
        case .terrainFollow: return "TerrainFollow"
        case .tripod: return "Tripod"
        case .activeTrackSpotlight: return "Spotlight"
        case .unknown: return "Unknown"
        @unknown default: return "Other(\(mode.rawValue))"
        }
    }

    private func describeIMUSensorState(_ state: DJIIMUSensorState) -> String {
        switch state {
        case .disconnected: return "DISCONNECTED"
        case .calibrating: return "CALIBRATING"
        case .calibrationFailed: return "CAL_FAILED"
        case .dataException: return "DATA_ERROR"
        case .warmingUp: return "WARMING_UP"
        case .inMotion: return "IN_MOTION"
        case .normalBias: return "OK"
        case .mediumBias: return "MEDIUM_BIAS"
        case .largeBias: return "LARGE_BIAS"
        @unknown default: return "UNKNOWN"
        }
    }

    private func describeCalibrationState(_ state: DJIIMUCalibrationState) -> String {
        switch state {
        case .none: return "None"
        case .calibrating: return "Calibrating"
        case .successful: return "Success"
        case .failed: return "FAILED"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - DJIRemoteControllerDelegate (RC stick priority)

extension DroneController: DJIRemoteControllerDelegate {

    func remoteController(_ rc: DJIRemoteController, didUpdate state: DJIRCHardwareState) {
        stabilizationAgent.onRCStickUpdate(
            leftStick: state.leftStick,
            rightStick: state.rightStick
        )
    }
}
#endif
