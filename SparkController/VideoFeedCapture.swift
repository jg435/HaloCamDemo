//
//  VideoFeedCapture.swift
//  SparkController
//
//  Photo capture with download to iPhone
//

import UIKit
import Photos
#if !targetEnvironment(simulator)
import DJISDK
#endif

final class VideoFeedCapture: NSObject {

    /// Called when a photo is saved to the photo library
    var onPhotoSaved: ((Error?) -> Void)?

    #if !targetEnvironment(simulator)
    private var mediaManager: DJIMediaManager?
    #endif

    override init() {
        super.init()
        print("[VideoFeed] VideoFeedCapture initialized")
    }

    func setupVideoFeed() {
        print("[VideoFeed] Setup called")
        #if !targetEnvironment(simulator)
        // Get media manager for downloading photos
        if let aircraft = DJISDKManager.product() as? DJIAircraft,
           let camera = aircraft.camera {
            mediaManager = camera.mediaManager
            print("[VideoFeed] Media manager obtained")
        }
        #endif
    }

    // MARK: - Capture

    func captureAndSave() {
        print("[VideoFeed] ========== CAPTURE REQUESTED ==========")

        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let camera = aircraft.camera else {
            print("[VideoFeed] No camera available")
            onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No camera available"]))
            return
        }

        print("[VideoFeed] Taking photo and downloading to iPhone...")

        // Take photo
        camera.setMode(.shootPhoto) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                print("[VideoFeed] setMode error: \(error.localizedDescription)")
            }

            camera.startShootPhoto { error in
                if let error = error {
                    print("[VideoFeed] Photo error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.onPhotoSaved?(error)
                    }
                } else {
                    print("[VideoFeed] Photo captured! Waiting for file to be written...")
                    // Wait longer for the photo to be fully written to storage
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        print("[VideoFeed] Starting download process...")
                        self.downloadLatestPhoto()
                    }
                }
            }
        }
        #else
        createAndSaveSimulatorImage()
        #endif
    }

    #if !targetEnvironment(simulator)
    private func downloadLatestPhoto() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let camera = aircraft.camera else {
            print("[VideoFeed] No camera for download")
            onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Camera not available for download"]))
            return
        }

        // Switch to media download mode
        camera.setMode(.mediaDownload) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                print("[VideoFeed] Failed to switch to download mode: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onPhotoSaved?(error)
                }
                return
            }

            print("[VideoFeed] Switched to media download mode")

            // Refresh file list
            guard let mediaManager = camera.mediaManager else {
                print("[VideoFeed] No media manager")
                DispatchQueue.main.async {
                    self.onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Media manager not available"]))
                }
                return
            }

            // Refresh file list from SD card
            print("[VideoFeed] Refreshing file list from SD card...")
            mediaManager.refreshFileList(of: .sdCard) { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    print("[VideoFeed] Failed to refresh SD card: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.onPhotoSaved?(error)
                    }
                    return
                }

                guard let files = mediaManager.sdCardFileListSnapshot(),
                      let latestFile = files.last else {
                    print("[VideoFeed] No files found on SD card")
                    DispatchQueue.main.async {
                        self.onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -4,
                            userInfo: [NSLocalizedDescriptionKey: "No photos found on SD card."]))
                    }
                    return
                }

                print("[VideoFeed] Found \(files.count) files, downloading latest: \(latestFile.fileName)")
                self.downloadFile(latestFile)
            }
        }
    }

    private func downloadFile(_ mediaFile: DJIMediaFile) {
        let fileName = mediaFile.fileName ?? "unknown"
        let fileSize = mediaFile.fileSizeInBytes
        print("[VideoFeed] Downloading: \(fileName) (\(fileSize) bytes expected)")

        var downloadedData = Data()
        var lastProgress: Int = 0

        mediaFile.fetchData(withOffset: 0, update: DispatchQueue.main) { [weak self] data, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[VideoFeed] Download error: \(error.localizedDescription)")
                self.onPhotoSaved?(error)
                return
            }

            if let data = data {
                downloadedData.append(data)
                // Log progress every 25%
                let progress = fileSize > 0 ? Int((Double(downloadedData.count) / Double(fileSize)) * 100) : 0
                if progress >= lastProgress + 25 {
                    print("[VideoFeed] Download progress: \(progress)% (\(downloadedData.count)/\(fileSize) bytes)")
                    lastProgress = progress
                }
            }

            if isComplete {
                print("[VideoFeed] Download complete! Size: \(downloadedData.count) bytes")
                self.saveDataToPhotoLibrary(downloadedData)

                // Switch back to photo mode
                if let aircraft = DJISDKManager.product() as? DJIAircraft,
                   let camera = aircraft.camera {
                    camera.setMode(.shootPhoto) { _ in
                        print("[VideoFeed] Switched back to photo mode")
                    }
                }
            }
        }
    }

    private func saveDataToPhotoLibrary(_ data: Data) {
        print("[VideoFeed] Saving to photo library...")

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }

            guard status == .authorized || status == .limited else {
                print("[VideoFeed] Photo library access denied")
                DispatchQueue.main.async {
                    self.onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("[VideoFeed] SUCCESS: Photo saved to iPhone!")
                        self.onPhotoSaved?(nil)
                    } else {
                        print("[VideoFeed] Failed to save: \(error?.localizedDescription ?? "unknown")")
                        self.onPhotoSaved?(error)
                    }
                }
            }
        }
    }
    #endif

    #if targetEnvironment(simulator)
    private func createAndSaveSimulatorImage() {
        let size = CGSize(width: 1920, height: 1080)
        UIGraphicsBeginImageContext(size)
        UIColor.darkGray.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let text = "Simulated Capture"
        text.draw(at: CGPoint(x: 100, y: 500), withAttributes: [
            .foregroundColor: UIColor.white,
            .font: UIFont.boldSystemFont(ofSize: 48)
        ])
        if let image = UIGraphicsGetImageFromCurrentImageContext() {
            saveImageToPhotoLibrary(image)
        }
        UIGraphicsEndImageContext()
    }

    private func saveImageToPhotoLibrary(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.onPhotoSaved?(NSError(domain: "VideoFeedCapture", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("[VideoFeed] Simulator photo saved!")
                        self.onPhotoSaved?(nil)
                    } else {
                        self.onPhotoSaved?(error)
                    }
                }
            }
        }
    }
    #endif
}
