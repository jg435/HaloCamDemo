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

    /// Video preview view for capturing photos from the video feed
    private let videoPreviewView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false  // Don't intercept touches
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
        button.setTitle("🎤 HOLD TO SPEAK", for: .normal)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
        setupVoiceControl()

        #if targetEnvironment(simulator)
        // Auto-connect in simulator after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.simulateConnection()
        }
        #endif
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Add video preview at the top
        videoPreviewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoPreviewView)

        #if targetEnvironment(simulator)
        let simLabel = UILabel()
        simLabel.text = "SIMULATOR MODE"
        simLabel.font = .systemFont(ofSize: 12, weight: .bold)
        simLabel.textColor = .systemOrange
        simLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [simLabel, statusLabel, micButton, takeoffButton, landButton])
        #else
        let stack = UIStackView(arrangedSubviews: [statusLabel, micButton, takeoffButton, landButton])
        #endif

        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        telemetryLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(telemetryLabel)

        NSLayoutConstraint.activate([
            // Video preview at top (smaller height)
            videoPreviewView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            videoPreviewView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            videoPreviewView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            videoPreviewView.heightAnchor.constraint(equalToConstant: 150),

            // Stack below preview
            stack.topAnchor.constraint(equalTo: videoPreviewView.bottomAnchor, constant: 30),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 200),
            micButton.heightAnchor.constraint(equalToConstant: 60),
            takeoffButton.widthAnchor.constraint(equalToConstant: 200),
            takeoffButton.heightAnchor.constraint(equalToConstant: 60),
            landButton.widthAnchor.constraint(equalToConstant: 200),
            landButton.heightAnchor.constraint(equalToConstant: 60),

            // Telemetry below buttons
            telemetryLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            telemetryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            telemetryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        // Ensure buttons are above preview
        view.bringSubviewToFront(stack)

        micButton.addTarget(self, action: #selector(micButtonTouchDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micButtonTouchUp), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(micButtonTouchUp), for: .touchUpOutside)
        takeoffButton.addTarget(self, action: #selector(takeoff), for: .touchUpInside)
        landButton.addTarget(self, action: #selector(land), for: .touchUpInside)

        // Setup video previewer
        setupVideoPreviewer()
    }

    private func setupVideoPreviewer() {
        #if !targetEnvironment(simulator)
        DJIVideoPreviewer.instance()?.setView(videoPreviewView)
        DJIVideoPreviewer.instance()?.enableHardwareDecode = true
        DJIVideoPreviewer.instance()?.start()
        print("[MainVC] Video previewer started")
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
        voiceController.onIntentDetected = { [weak self] rawText, intent in
            guard let self = self else { return }
            // Show raw recognized text first
            self.statusLabel.text = "Heard: \(rawText)"

            // After a brief delay, show the parsed intent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.statusLabel.text = "Command: \(intent)"
            }

            // Execute the command
            self.droneController.handle(intent: intent)
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
            // Start receiving video feed
            DJISDKManager.videoFeeder()?.primaryVideoFeed.add(self, with: nil)
            DJIVideoPreviewer.instance()?.frameControlHandler = self
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
