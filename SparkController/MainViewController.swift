import UIKit
#if !targetEnvironment(simulator)
import DJISDK
import DJIWidget
#endif

class MainViewController: UIViewController {

    #if targetEnvironment(simulator)
    private var isSimulatedConnected = false
    private var isFlying = false
    #endif

    private let voiceController = VoiceCommandController()
    private let droneController = DroneController()
    private var latestTelemetry: TelemetryData?
    private var videoFrameCount = 0

    /// Video preview view for capturing photos from the video feed
    private let videoPreviewView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Disconnected"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .systemRed
        return label
    }()

    private let takeoffButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("TAKEOFF", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        button.backgroundColor = .systemGreen
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        return button
    }()

    private let landButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("LAND", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        return button
    }()

    private let micButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("HOLD TO SPEAK", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        button.backgroundColor = .systemPurple
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        return button
    }()

    private let telemetryLabel: UILabel = {
        let label = UILabel()
        label.text = "Telemetry: waiting for connection..."
        label.textAlignment = .left
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    // ── New controls ──

    private let stabButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("STAB OFF", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .systemGray
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()

    private let recordButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("REC", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .systemGray
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()

    private let stopAgentButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("STOP", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .systemRed
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()

    private let streamButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("STREAM", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .systemGray
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()

    private let agentStatusLabel: UILabel = {
        let label = UILabel()
        label.text = ""
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
        setupVoiceControl()
        setupAgentCallbacks()

        #if targetEnvironment(simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.simulateConnection()
        }
        #endif
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        videoPreviewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoPreviewView)

        // Bottom row: STAB / STOP / REC / STREAM
        let bottomRow = UIStackView(arrangedSubviews: [stabButton, stopAgentButton, recordButton, streamButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.distribution = .fillEqually

        #if targetEnvironment(simulator)
        let simLabel = UILabel()
        simLabel.text = "SIMULATOR MODE"
        simLabel.font = .systemFont(ofSize: 12, weight: .bold)
        simLabel.textColor = .systemOrange
        simLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [simLabel, statusLabel, micButton, takeoffButton, landButton, bottomRow, agentStatusLabel])
        #else
        let stack = UIStackView(arrangedSubviews: [statusLabel, micButton, takeoffButton, landButton, bottomRow, agentStatusLabel])
        #endif

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        telemetryLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(telemetryLabel)

        NSLayoutConstraint.activate([
            videoPreviewView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            videoPreviewView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            videoPreviewView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            videoPreviewView.heightAnchor.constraint(equalToConstant: 150),

            stack.topAnchor.constraint(equalTo: videoPreviewView.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            micButton.heightAnchor.constraint(equalToConstant: 60),
            takeoffButton.heightAnchor.constraint(equalToConstant: 60),
            landButton.heightAnchor.constraint(equalToConstant: 60),
            bottomRow.heightAnchor.constraint(equalToConstant: 40),

            telemetryLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            telemetryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            telemetryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        view.bringSubviewToFront(stack)

        micButton.addTarget(self, action: #selector(micButtonTouchDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micButtonTouchUp), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(micButtonTouchUp), for: .touchUpOutside)
        takeoffButton.addTarget(self, action: #selector(takeoff), for: .touchUpInside)
        landButton.addTarget(self, action: #selector(land), for: .touchUpInside)
        stabButton.addTarget(self, action: #selector(toggleStabilization), for: .touchUpInside)
        stopAgentButton.addTarget(self, action: #selector(stopAgent), for: .touchUpInside)
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        streamButton.addTarget(self, action: #selector(toggleStreaming), for: .touchUpInside)

        setupVideoPreviewer()
    }

    private func setupVideoPreviewer() {
        #if !targetEnvironment(simulator)
        DJIVideoPreviewer.instance()?.setView(videoPreviewView)
        DJIVideoPreviewer.instance()?.type = .autoAdapt
        DJIVideoPreviewer.instance()?.enableHardwareDecode = true
        print("[MainVC] Video previewer view set (waiting for product connection to start)")
        #else
        print("[MainVC] Simulator mode - video previewer disabled")
        #endif
    }

    private func resetVideoPreviewer() {
        #if !targetEnvironment(simulator)
        DJIVideoPreviewer.instance()?.unSetView()
        DJISDKManager.videoFeeder()?.primaryVideoFeed.remove(self)
        print("[MainVC] Video previewer reset")
        #endif
    }

    private func setupVoiceControl() {
        // ── Keyword match (fast, free) ──
        voiceController.onIntentDetected = { [weak self] rawText, intent in
            guard let self = self else { return }
            self.statusLabel.text = "Heard: \(rawText)"

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.statusLabel.text = "Command: \(intent)"
            }

            self.droneController.handle(intent: intent)
        }

        // ── LLM fallback (Claude via OpenRouter) ──
        voiceController.onUnmatchedText = { [weak self] rawText in
            guard let self = self else { return }
            self.statusLabel.text = "Heard: \(rawText)"
            self.agentStatusLabel.text = "Asking Claude..."

            let resolver = LLMIntentResolver.shared
            // Give the LLM current telemetry for context
            resolver.currentTelemetry = self.latestTelemetry

            resolver.resolve(text: rawText) { [weak self] intents, explanation in
                guard let self = self else { return }

                if intents.isEmpty {
                    self.statusLabel.text = "Could not understand: \(rawText)"
                    self.agentStatusLabel.text = explanation ?? ""
                    return
                }

                let desc = intents.map(\.description).joined(separator: " → ")
                self.statusLabel.text = "AI: \(desc)"
                self.agentStatusLabel.text = explanation ?? ""

                if intents.count == 1 {
                    self.droneController.handle(intent: intents[0])
                } else {
                    self.droneController.handleSequence(intents)
                }
            }
        }

        droneController.onCommandStarted = { [weak self] intent in
            guard let self = self else { return }
            self.statusLabel.text = "Executing: \(intent)..."
        }

        droneController.onCommandCompleted = { [weak self] intent, error in
            guard let self = self else { return }
            if let error = error {
                self.statusLabel.text = "Error: \(intent) - \(error.localizedDescription)"
            } else {
                self.statusLabel.text = "Completed: \(intent)"
            }
        }

        droneController.onTelemetryUpdate = { [weak self] t in
            guard let self = self else { return }
            self.latestTelemetry = t
            let drift = String(format: "%.2f", t.driftSpeed)
            let driftColor = t.driftSpeed > 0.3 ? " !!!" : ""
            self.telemetryLabel.text = """
            Pitch:\(String(format: "%+.1f", t.pitch))° Roll:\(String(format: "%+.1f", t.roll))° Yaw:\(String(format: "%+.1f", t.yaw))°
            Drift: \(drift) m/s\(driftColor)  Alt: \(String(format: "%.1f", t.altitude))m
            GPS:\(t.gpsSignalLevel) Sats:\(t.satelliteCount) Vision:\(t.isVisionPositioning ? "ON" : "OFF")
            Mode:\(t.flightMode) \(t.isIMUPreheating ? "IMU PREHEATING" : "")
            """
            self.telemetryLabel.textColor = t.driftSpeed > 0.3 ? .systemOrange : .secondaryLabel
        }
    }

    // MARK: - Agent / Recorder / Stream callbacks

    private func setupAgentCallbacks() {
        droneController.stabilizationAgent.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.agentStatusLabel.text = status
            }
        }

        droneController.flightDataRecorder.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.updateRecordButtonAppearance()
                self?.agentStatusLabel.text = status
            }
        }

        droneController.peerStreamService.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.updateStreamButtonAppearance()
                self?.agentStatusLabel.text = status
            }
        }

        LLMIntentResolver.shared.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.agentStatusLabel.text = status
            }
        }
    }

    // MARK: - New button actions

    @objc private func toggleStabilization() {
        let agent = droneController.stabilizationAgent
        if agent.isEnabled {
            agent.disable()
            stabButton.setTitle("STAB OFF", for: .normal)
            stabButton.backgroundColor = .systemGray
        } else {
            agent.enable()
            stabButton.setTitle("STAB ON", for: .normal)
            stabButton.backgroundColor = .systemTeal
        }
    }

    @objc private func stopAgent() {
        droneController.stabilizationAgent.freeze()
    }

    @objc private func toggleRecording() {
        let rec = droneController.flightDataRecorder
        if rec.isRecording {
            rec.stopRecording()
        } else {
            rec.startRecording()
        }
        updateRecordButtonAppearance()
    }

    @objc private func toggleStreaming() {
        let svc = droneController.peerStreamService
        if svc.isAdvertising {
            svc.stopAdvertising()
        } else {
            svc.startAdvertising()
        }
        updateStreamButtonAppearance()
    }

    private func updateRecordButtonAppearance() {
        let recording = droneController.flightDataRecorder.isRecording
        recordButton.setTitle(recording ? "STOP" : "REC", for: .normal)
        recordButton.backgroundColor = recording ? .systemRed : .systemGray
    }

    private func updateStreamButtonAppearance() {
        let adv = droneController.peerStreamService.isAdvertising
        let peers = droneController.peerStreamService.connectedPeerCount
        if adv && peers > 0 {
            streamButton.setTitle("LIVE \(peers)", for: .normal)
            streamButton.backgroundColor = .systemIndigo
        } else if adv {
            streamButton.setTitle("WAIT...", for: .normal)
            streamButton.backgroundColor = .systemOrange
        } else {
            streamButton.setTitle("STREAM", for: .normal)
            streamButton.backgroundColor = .systemGray
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(productConnected), name: .productConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(productDisconnected), name: .productDisconnected, object: nil)
    }

    #if targetEnvironment(simulator)
    private func simulateConnection() {
        isSimulatedConnected = true
        statusLabel.text = "Connected: Spark (Simulated)"
        statusLabel.textColor = .systemGreen
    }
    #endif

    @objc private func productConnected(_ notification: Notification) {
        DispatchQueue.main.async {
            #if targetEnvironment(simulator)
            self.statusLabel.text = "Connected: Spark (Simulated)"
            #else
            let product = notification.object as? DJIBaseProduct
            self.statusLabel.text = "Connected: \(product?.model ?? "Aircraft")"

            // Reset and restart video pipeline
            DJIVideoPreviewer.instance()?.setView(self.videoPreviewView)
            DJISDKManager.videoFeeder()?.primaryVideoFeed.add(self, with: nil)
            DJIVideoPreviewer.instance()?.frameControlHandler = self
            DJIVideoPreviewer.instance()?.start()
            print("[MainVC] Video previewer started — feeder: \(DJISDKManager.videoFeeder() != nil)")
            #endif
            self.statusLabel.textColor = .systemGreen
        }
    }

    @objc private func productDisconnected() {
        DispatchQueue.main.async {
            self.statusLabel.text = "Disconnected"
            self.statusLabel.textColor = .systemRed
            self.resetVideoPreviewer()
        }
    }

    deinit {
        resetVideoPreviewer()
    }

    #if !targetEnvironment(simulator)
    private var flightController: DJIFlightController? {
        let aircraft = DJISDKManager.product() as? DJIAircraft
        return aircraft?.flightController
    }
    #endif

    @objc private func takeoff() {
        #if targetEnvironment(simulator)
        guard isSimulatedConnected else {
            showAlert("Not Connected", message: "Connect to your Spark first")
            return
        }
        if isFlying {
            showAlert("Already Flying", message: "Spark is already in the air")
            return
        }
        isFlying = true
        showAlert("Takeoff", message: "Spark is taking off! (Simulated)")
        #else
        guard let fc = flightController else {
            showAlert("Not Connected", message: "Connect to your Spark first")
            return
        }

        fc.startTakeoff { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showAlert("Takeoff Failed", message: error.localizedDescription)
                } else {
                    self.showAlert("Takeoff", message: "Spark is taking off!")
                }
            }
        }
        #endif
    }

    @objc private func land() {
        #if targetEnvironment(simulator)
        guard isSimulatedConnected else {
            showAlert("Not Connected", message: "Connect to your Spark first")
            return
        }
        if !isFlying {
            showAlert("Not Flying", message: "Spark is already on the ground")
            return
        }
        isFlying = false
        showAlert("Landing", message: "Spark is landing! (Simulated)")
        #else
        guard let fc = flightController else {
            showAlert("Not Connected", message: "Connect to your Spark first")
            return
        }

        fc.startLanding { error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showAlert("Landing Failed", message: error.localizedDescription)
                } else {
                    self.showAlert("Landing", message: "Spark is landing!")
                }
            }
        }
        #endif
    }

    @objc private func micButtonTouchDown(_ sender: UIButton) {
        statusLabel.text = "Listening..."
        voiceController.startListening()
    }

    @objc private func micButtonTouchUp(_ sender: UIButton) {
        voiceController.stopListening()
        statusLabel.text = "Stopped listening"
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - DJI Video Feed

#if !targetEnvironment(simulator)
extension MainViewController: DJIVideoFeedListener {
    func videoFeed(_ videoFeed: DJIVideoFeed, didUpdateVideoData videoData: Data) {
        videoFrameCount += 1
        if videoFrameCount % 100 == 1 {
            print("[MainVC] Video data received: \(videoData.count) bytes (frame #\(videoFrameCount))")
        }
        videoData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = UnsafeMutablePointer<UInt8>(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
            DJIVideoPreviewer.instance()?.push(bytes, length: Int32(videoData.count))
        }
    }
}

extension MainViewController: DJIVideoPreviewerFrameControlDelegate {
    func parseDecodingAssistInfo(withBuffer buffer: UnsafeMutablePointer<UInt8>!, length: Int32, assistInfo: UnsafeMutablePointer<DJIDecodingAssistInfo>!) -> Bool {
        return DJISDKManager.videoFeeder()?.primaryVideoFeed.parseDecodingAssistInfo(withBuffer: buffer, length: length, assistInfo: assistInfo) ?? false
    }

    func isNeedFitFrameWidth() -> Bool {
        return true
    }

    func syncDecoderStatus(_ isNormal: Bool) {
        DJISDKManager.videoFeeder()?.primaryVideoFeed.syncDecoderStatus(isNormal)
    }

    func decodingDidSucceed(withTimestamp timestamp: UInt32) {
        DJISDKManager.videoFeeder()?.primaryVideoFeed.decodingDidSucceed(withTimestamp: UInt(timestamp))
    }

    func decodingDidFail() {
        DJISDKManager.videoFeeder()?.primaryVideoFeed.decodingDidFail()
    }
}
#endif
