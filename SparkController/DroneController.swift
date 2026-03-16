//
//  DroneController.swift
//

import Foundation
#if !targetEnvironment(simulator)
import DJISDK
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

    /// Called when a command starts executing
    var onCommandStarted: ((DroneIntent) -> Void)?

    /// Called when a command completes executing
    /// Parameters: (intent: DroneIntent, error: Error?)
    var onCommandCompleted: ((DroneIntent, Error?) -> Void)?

    /// Called at 10 Hz with live telemetry data
    var onTelemetryUpdate: ((TelemetryData) -> Void)?

    /// Photo downloader instance
    private let photoDownloader = PhotoDownloader()

    /// Log throttle — only print to console every N updates
    private var telemetryLogCounter: Int = 0

    /// Video feed capture instance (captures directly to iPhone, no SD card needed)
    private let videoFeedCapture = VideoFeedCapture()

    /// Track the last camera mode so we can restore it after download
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
        switch intent {
        case .takeOff:
            startTakeoff()
            
        case .land:
            startLanding()
            
        case .takePhoto:
            takePhotoOnce()
            
        case .photoPosition:
            runPhotoPositionRoutine()
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
                self.onCommandCompleted?(.takeOff, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No aircraft / flight controller"]))
            }
            return
        }
        
        fc.startTakeoff { error in
            DispatchQueue.main.async {
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
                self.onCommandCompleted?(.land, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No aircraft / flight controller"]))
            }
            return
        }
        
        fc.startLanding { error in
            DispatchQueue.main.async {
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
            self.onCommandCompleted?(.land, nil)
        }
        #endif
    }
    
    private func takePhotoOnce() {
        print("[TakePhoto] Starting takePhotoOnce() - capturing from video feed")
        DispatchQueue.main.async {
            self.onCommandStarted?(.takePhoto)
        }

        // Capture frame from video feed and save to iPhone (no SD card needed!)
        videoFeedCapture.captureAndSave()
    }
    
    // MARK: - Hard-coded "photo position" script
    
    /// Voice command: "photo position"
    /// Script:
    ///  - Take off
    ///  - Climb to ~3m
    ///  - Take a single photo
    ///  - Then hover
    private func runPhotoPositionRoutine() {
        DispatchQueue.main.async {
            self.onCommandStarted?(.photoPosition)
        }
        
        #if !targetEnvironment(simulator)
        guard let missionControl = DJISDKManager.missionControl() else {
            print("MissionControl unavailable")
            DispatchQueue.main.async {
                self.onCommandCompleted?(.photoPosition, NSError(domain: "DroneController", code: -1, userInfo: [NSLocalizedDescriptionKey: "MissionControl unavailable"]))
            }
            return
        }
        
        // Get current altitude to calculate target altitude
        // Default to 4.5m to ensure we go above typical table height (1.5m) + 3m target
        var targetAltitude: Double = 4.5
        if let aircraft = DJISDKManager.product() as? DJIAircraft,
           let fc = aircraft.flightController {
            // Try to access current altitude from flight controller state using KVC
            // This works across different DJI SDK versions
            if let state = fc.value(forKey: "state") as? DJIFlightControllerState {
                let currentAltitude = state.altitude
                // Calculate target altitude: ensure at least 3.0m from takeoff point
                // If already above 3m, add 3m more; otherwise go to 3m
                targetAltitude = max(currentAltitude + 3.0, 3.0)
                print("Current altitude: \(currentAltitude)m, Target altitude: \(targetAltitude)m")
            } else {
                // Fallback: use 4.5m to ensure we go above table height + reach 3m target
                print("Could not access flight controller state, using default target altitude: \(targetAltitude)m")
            }
        }
        
        // Stop and clear previous timeline if any
        missionControl.stopTimeline()
        missionControl.unscheduleEverything()
        
        var elements: [DJIMissionControlTimelineElement] = []
        
        // 1) Takeoff
        let takeoff = DJITakeOffAction()
        elements.append(takeoff)
        
        // 2) Go to target altitude (meters, absolute altitude relative to takeoff point)
        if let goToAltitude = DJIGoToAction(altitude: targetAltitude) {
            elements.append(goToAltitude)
        }
        
        // 3) Take a single photo
        let shootPhotoAction = DJIShootPhotoAction()
        elements.append(shootPhotoAction)
        
        missionControl.scheduleElements(elements)
        missionControl.startTimeline()
        
        // Note: Timeline execution is asynchronous and doesn't provide a simple completion callback
        // For now, we'll mark it as started. A more sophisticated implementation would track timeline state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Assume success after a short delay (timeline started successfully)
            // In a real implementation, you'd want to listen to timeline state changes
            self.onCommandCompleted?(.photoPosition, nil)
        }
        #else
        print("Photo position routine (simulator)")
        DispatchQueue.main.async {
            self.onCommandCompleted?(.photoPosition, nil)
        }
        #endif
    }
    
    // MARK: - Photo Download Setup
    
    private func setupPhotoDownloader() {
        photoDownloader.onPhotoSaved = { [weak self] error in
            if let error = error {
                print("Photo save error: \(error.localizedDescription)")
            } else {
                print("Photo saved to library successfully")
            }
        }
    }
    
    private func setupCameraDelegate() {
        #if !targetEnvironment(simulator)
        // Set up camera delegate when product connects
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

        // Setup video feed (simplified version - safe now)
        videoFeedCapture.setupVideoFeed()

        guard let aircraft = DJISDKManager.product() as? DJIAircraft else {
            print("[DroneController] No aircraft found")
            return
        }

        // Set up camera delegate
        if let camera = aircraft.camera {
            camera.delegate = self
            print("[DroneController] Camera delegate set")
        }

        // Set up flight controller delegate for telemetry
        // Components may not be ready immediately, so retry if needed
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
}

// MARK: - DJICameraDelegate

#if !targetEnvironment(simulator)
extension DroneController: DJICameraDelegate {
    
    func camera(_ camera: DJICamera, didGenerateNewMediaFile newMedia: DJIMediaFile) {
        print("New media file generated: \(newMedia.fileName ?? "unknown")")
        
        // Only process JPEG photos
        guard newMedia.mediaType == .JPEG else {
            print("Skipping non-JPEG media: \(newMedia.mediaType.rawValue)")
            return
        }
        
        // Download and save the photo
        downloadAndSavePhoto(mediaFile: newMedia)
    }
    
    private func downloadAndSavePhoto(mediaFile: DJIMediaFile) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let camera = aircraft.camera else {
            print("No camera available for download")
            return
        }
        
        // Save current camera mode
        camera.getModeWithCompletion { [weak self] mode, error in
            guard let self = self else { return }

            if error == nil {
                self.lastCameraMode = mode
            }

            // Switch to MediaDownload mode if not already
            if mode != .mediaDownload {
                camera.setMode(.mediaDownload) { error in
                    if let error = error {
                        print("Failed to switch to MediaDownload mode: \(error.localizedDescription)")
                        // Try downloading anyway - some cameras might work
                        self.photoDownloader.downloadAndSavePhoto(mediaFile: mediaFile)
                    } else {
                        print("Switched to MediaDownload mode")
                        // Download the photo
                        self.photoDownloader.downloadAndSavePhoto(mediaFile: mediaFile)
                        
                        // Restore previous mode after a delay
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
                // Already in MediaDownload mode
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

        // Log to console every ~1 second (every 10th callback at 10Hz)
        telemetryLogCounter += 1
        if telemetryLogCounter >= 10 {
            telemetryLogCounter = 0
            let drift = String(format: "%.2f", telemetry.driftSpeed)
            print("[Telemetry] P:\(String(format: "%+.1f", telemetry.pitch))° R:\(String(format: "%+.1f", telemetry.roll))° Y:\(String(format: "%+.1f", telemetry.yaw))° | Vel: \(drift) m/s | Alt: \(String(format: "%.1f", telemetry.altitude))m | GPS:\(telemetry.gpsSignalLevel) Sat:\(telemetry.satelliteCount) | Vision:\(telemetry.isVisionPositioning ? "ON" : "OFF") | Mode:\(telemetry.flightMode)")
        }

        DispatchQueue.main.async {
            self.onTelemetryUpdate?(telemetry)
        }
    }

    func flightController(_ fc: DJIFlightController, didUpdate imuState: DJIIMUState) {
        let gyroState = imuState.gyroscopeState
        let accelState = imuState.accelerometerState
        let calState = imuState.calibrationState

        // Only log if something is unusual
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
#endif

