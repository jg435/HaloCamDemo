//
//  StabilizationAgent.swift
//  SparkController
//
//  Smart stabilization agent that fuses IMU telemetry + video-frame optical flow
//  to hold the drone in a steady hover whenever no human is commanding it.
//
//  Priority hierarchy (highest → lowest):
//    1. Physical RC sticks  – agent yields immediately, firmware also overrides
//    2. Voice commands       – agent pauses for duration of command
//    3. AI stabilization     – PID + vision hover when idle
//

import Foundation
import UIKit
import Vision
import CoreImage
#if !targetEnvironment(simulator)
import DJISDK
#endif

// MARK: - PID Controller

struct PIDController {
    var kP: Float
    var kI: Float
    var kD: Float

    private var integral: Float = 0
    private var previousError: Float = 0
    private var previousTime: TimeInterval = 0

    let maxIntegral: Float = 10.0
    let outputClamp: Float = 1.0

    init(kP: Float, kI: Float, kD: Float) {
        self.kP = kP
        self.kI = kI
        self.kD = kD
    }

    mutating func update(error: Float, timestamp: TimeInterval) -> Float {
        let dt = previousTime > 0 ? Float(timestamp - previousTime) : 0.02
        guard dt > 0, dt < 1.0 else {
            previousTime = timestamp
            return 0
        }

        integral += error * dt
        integral = max(-maxIntegral, min(maxIntegral, integral))

        let derivative = (error - previousError) / dt
        previousError = error
        previousTime = timestamp

        let output = kP * error + kI * integral + kD * derivative
        return max(-outputClamp, min(outputClamp, output))
    }

    mutating func reset() {
        integral = 0
        previousError = 0
        previousTime = 0
    }
}

// MARK: - StabilizationAgent

final class StabilizationAgent: NSObject {

    // ── State ───────────────────────────────────────────────

    /// Whether the agent is logically enabled (user toggled ON)
    private(set) var isEnabled: Bool = false

    /// Set by DroneController when a voice command is executing
    var isVoiceCommandActive: Bool = false {
        didSet {
            if isVoiceCommandActive {
                yieldToHuman(reason: "voice command")
            } else if isEnabled {
                scheduleResume()
            }
        }
    }

    /// Updated by DroneController's RC delegate — true when any stick is off-center
    private(set) var isRCActive: Bool = false

    /// STOP state — agent is completely frozen, sends nothing, waits for RC input
    private(set) var isFrozen: Bool = false

    /// Callback for UI status updates
    var onStatusChanged: ((String) -> Void)?

    // ── Target hover state ──────────────────────────────────

    private var targetYaw: Double = 0
    private var targetAltitude: Double = 0

    // ── PID controllers (velocity-based: counter drift speed) ──

    private var vxPID = PIDController(kP: 0.35, kI: 0.04, kD: 0.15)
    private var vyPID = PIDController(kP: 0.35, kI: 0.04, kD: 0.15)
    private var yawPID   = PIDController(kP: 0.4, kI: 0.03, kD: 0.15)
    private var altPID   = PIDController(kP: 0.6, kI: 0.08, kD: 0.25)

    // ── Gains when vision positioning is available vs not ────
    private let gainsWithVision    = (kP: Float(0.5),  kI: Float(0.06), kD: Float(0.20))
    private let gainsWithoutVision = (kP: Float(0.35), kI: Float(0.04), kD: Float(0.15))

    // ── Vision drift ────────────────────────────────────────

    private var previousFrameImage: CIImage?
    private var visionDriftX: Float = 0
    private var visionDriftY: Float = 0
    private let visionWeight: Float = 0.25

    // ── Output limiting ─────────────────────────────────────
    /// Max pitch/roll command in m/s (virtual stick velocity mode)
    private let maxHorizontalSpeed: Float = 1.0

    // ── Control loop ────────────────────────────────────────

    private var controlTimer: Timer?
    private var latestTelemetry: TelemetryData?
    private var resumeWorkItem: DispatchWorkItem?

    /// Seconds to wait after RC sticks return to center before AI resumes
    private let rcCooldown: TimeInterval = 0.8

    // Deadbands
    private let attitudeDeadband: Double = 0.5   // degrees
    private let altitudeDeadband: Double = 0.15  // metres
    private let velocityDeadband: Float  = 0.05  // m/s

    /// RC stick deadband (out of ±660)
    private let rcStickThreshold: Int = 50

    // ── Whether the control loop is actively sending commands ──
    private var isControlLoopRunning: Bool { controlTimer != nil }

    // MARK: - Public API

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        resetPIDs()
        print("[StabAgent] Enabled – will activate on next idle telemetry")
        onStatusChanged?("STAB ON")
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        isFrozen = false
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        stopControlLoop()
        #if !targetEnvironment(simulator)
        disableVirtualSticks()
        #endif
        print("[StabAgent] Disabled")
        onStatusChanged?("STAB OFF")
    }

    /// STOP — immediately cease all AI commands. Drone falls back to its
    /// built-in flight controller hover. Stays frozen until RC sticks move.
    func freeze() {
        isFrozen = true
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        stopControlLoop()
        resetPIDs()
        previousFrameImage = nil
        visionDriftX = 0
        visionDriftY = 0
        #if !targetEnvironment(simulator)
        disableVirtualSticks()
        #endif
        print("[StabAgent] FROZEN — waiting for RC input")
        onStatusChanged?("STOPPED — waiting for RC")
    }

    // MARK: RC Input (called by DroneController)

    /// Called at ~10 Hz by the DJIRemoteControllerDelegate with current stick state.
    #if !targetEnvironment(simulator)
    func onRCStickUpdate(leftStick: DJIStick, rightStick: DJIStick) {
        let moving = abs(Int(leftStick.horizontalPosition))  > rcStickThreshold
                  || abs(Int(leftStick.verticalPosition))    > rcStickThreshold
                  || abs(Int(rightStick.horizontalPosition)) > rcStickThreshold
                  || abs(Int(rightStick.verticalPosition))   > rcStickThreshold

        if moving && !isRCActive {
            // RC just became active — unfreeze if frozen
            isRCActive = true
            if isFrozen {
                isFrozen = false
                print("[StabAgent] Unfrozen by RC input")
            }
            yieldToHuman(reason: "RC sticks")
        } else if !moving && isRCActive {
            // RC sticks returned to center
            isRCActive = false
            if isEnabled {
                scheduleResume()
            }
        }
    }
    #endif

    // MARK: Telemetry + Video Feeds

    /// Called at 10 Hz by DroneController
    func onTelemetryUpdate(_ telemetry: TelemetryData) {
        latestTelemetry = telemetry

        guard isEnabled, canStabilize, telemetry.isFlying else { return }

        if controlTimer == nil {
            captureTargetState(telemetry)
            startControlLoop()
        }
    }

    /// Called when a decoded video frame is available
    func onVideoFrame(_ image: UIImage) {
        guard isEnabled, canStabilize else { return }
        detectVisualDrift(image)
    }

    // MARK: - Internal Helpers

    /// True only when no human is commanding the drone and not frozen
    private var canStabilize: Bool {
        !isFrozen && !isRCActive && !isVoiceCommandActive
    }

    private func yieldToHuman(reason: String) {
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        stopControlLoop()
        resetPIDs()
        previousFrameImage = nil
        visionDriftX = 0
        visionDriftY = 0
        #if !targetEnvironment(simulator)
        disableVirtualSticks()
        #endif
        print("[StabAgent] Yielded to \(reason)")
        onStatusChanged?("STAB: \(reason) override")
    }

    /// Resume after a cooldown so we don't instantly fight the pilot
    private func scheduleResume() {
        resumeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isEnabled, self.canStabilize else { return }
            print("[StabAgent] Resuming – re-locking target on next telemetry")
            self.onStatusChanged?("STAB ON")
            // controlTimer is nil, so next telemetry will re-lock and restart
        }
        resumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + rcCooldown, execute: item)
    }

    // MARK: - Control Loop

    private func captureTargetState(_ t: TelemetryData) {
        targetYaw      = t.yaw
        targetAltitude = t.altitude
        print("[StabAgent] Target locked – Yaw:\(String(format: "%.1f", targetYaw))° Alt:\(String(format: "%.1f", targetAltitude))m")
    }

    private func startControlLoop() {
        #if !targetEnvironment(simulator)
        enableVirtualSticks { [weak self] ok in
            guard let self = self, ok else {
                print("[StabAgent] Failed to enable virtual sticks")
                self?.onStatusChanged?("STAB: VS failed")
                return
            }
            DispatchQueue.main.async {
                guard self.canStabilize else { return }
                print("[StabAgent] VS ON – control loop at 20 Hz")
                self.controlTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    self?.controlLoopTick()
                }
            }
        }
        #else
        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.controlLoopTick()
        }
        #endif
    }

    private func stopControlLoop() {
        controlTimer?.invalidate()
        controlTimer = nil
    }

    private func controlLoopTick() {
        // Double-check priority before every tick
        guard canStabilize, let t = latestTelemetry, t.isFlying else { return }

        let now = ProcessInfo.processInfo.systemUptime

        // ── Adapt gains based on vision availability ──
        let gains = t.isVisionPositioning ? gainsWithVision : gainsWithoutVision
        vxPID.kP = gains.kP; vxPID.kI = gains.kI; vxPID.kD = gains.kD
        vyPID.kP = gains.kP; vyPID.kI = gains.kI; vyPID.kD = gains.kD

        // ── Velocity-based error (target = 0 m/s = hover) ──
        // vx > 0 = forward drift → need negative pitch to counter
        // vy > 0 = rightward drift → need negative roll to counter
        var vxErr = -t.velocityX
        var vyErr = -t.velocityY

        // Blend optical flow drift when vision is available
        if t.isVisionPositioning {
            vxErr += visionDriftY * visionWeight
            vyErr += visionDriftX * visionWeight
        }

        var yawErr = Float(targetYaw - t.yaw)
        var altErr = Float(targetAltitude - t.altitude)

        // Normalize yaw to [-180, 180]
        while yawErr >  180 { yawErr -= 360 }
        while yawErr < -180 { yawErr += 360 }

        // Deadband — don't fight noise
        if abs(vxErr) < velocityDeadband { vxErr = 0 }
        if abs(vyErr) < velocityDeadband { vyErr = 0 }
        if abs(Double(yawErr)) < attitudeDeadband { yawErr = 0 }
        if abs(Double(altErr)) < altitudeDeadband { altErr = 0 }

        // All within deadband? Don't send anything.
        if vxErr == 0, vyErr == 0, yawErr == 0, altErr == 0 {
            return
        }

        var pitchCmd    = vxPID.update(error: vxErr, timestamp: now)
        var rollCmd     = vyPID.update(error: vyErr, timestamp: now)
        let yawCmd      = yawPID.update(error: yawErr, timestamp: now)
        let throttleCmd = altPID.update(error: altErr, timestamp: now)

        // Clamp horizontal speed
        pitchCmd = max(-maxHorizontalSpeed, min(maxHorizontalSpeed, pitchCmd))
        rollCmd  = max(-maxHorizontalSpeed, min(maxHorizontalSpeed, rollCmd))

        #if !targetEnvironment(simulator)
        sendVirtualStickCommand(
            pitch:    pitchCmd,
            roll:     rollCmd,
            yaw:      yawCmd * 30,
            throttle: throttleCmd * 2
        )
        #endif
    }

    // MARK: - Vision Drift Detection

    private func detectVisualDrift(_ image: UIImage) {
        guard let ciImage = CIImage(image: image) else { return }
        guard let previous = previousFrameImage else {
            previousFrameImage = ciImage
            return
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: ciImage)
        let handler = VNImageRequestHandler(ciImage: previous, options: [:])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try handler.perform([request])
                if let result = request.results?.first as? VNImageTranslationAlignmentObservation {
                    self?.visionDriftX = Float(result.alignmentTransform.tx) * 0.01
                    self?.visionDriftY = Float(result.alignmentTransform.ty) * 0.01
                }
            } catch { /* degrade to IMU-only */ }
            self?.previousFrameImage = ciImage
        }
    }

    // MARK: - DJI Virtual Stick Helpers

    #if !targetEnvironment(simulator)
    private func enableVirtualSticks(completion: @escaping (Bool) -> Void) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            completion(false)
            return
        }
        fc.setVirtualStickModeEnabled(true) { error in
            if let error = error {
                print("[StabAgent] VS enable error: \(error.localizedDescription)")
                completion(false)
            } else {
                fc.rollPitchControlMode      = .velocity
                fc.yawControlMode             = .angularVelocity
                fc.verticalControlMode        = .velocity
                fc.rollPitchCoordinateSystem  = .body
                completion(true)
            }
        }
    }

    private func disableVirtualSticks() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else { return }
        fc.setVirtualStickModeEnabled(false, withCompletion: nil)
    }

    private func sendVirtualStickCommand(pitch: Float, roll: Float, yaw: Float, throttle: Float) {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else { return }
        let cmd = DJIVirtualStickFlightControlData(
            pitch: pitch, roll: roll, yaw: yaw, verticalThrottle: throttle
        )
        fc.send(cmd, withCompletion: nil)
    }
    #endif

    // MARK: - Helpers

    private func resetPIDs() {
        vxPID.reset()
        vyPID.reset()
        yawPID.reset()
        altPID.reset()
    }
}
