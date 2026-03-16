//
//  PhotoDownloader.swift
//

import Foundation
import Photos
#if !targetEnvironment(simulator)
import DJISDK
#endif

final class PhotoDownloader {
    
    /// Called when a photo is successfully saved to the library
    var onPhotoSaved: ((Error?) -> Void)?
    
    /// Request photo library authorization
    func requestPhotoLibraryAuthorization(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    /// Download and save a photo from the drone
    func downloadAndSavePhoto(mediaFile: DJIMediaFile) {
        #if targetEnvironment(simulator)
        // Simulator: just report success
        print("Photo saved (simulator)")
        DispatchQueue.main.async {
            self.onPhotoSaved?(nil)
        }
        return
        #endif
        
        // Check if it's a photo
        guard mediaFile.mediaType == .JPEG else {
            print("Media file is not a JPEG photo: \(mediaFile.mediaType.rawValue)")
            DispatchQueue.main.async {
                self.onPhotoSaved?(NSError(domain: "PhotoDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "File is not a JPEG photo"]))
            }
            return
        }
        
        // Request authorization first
        requestPhotoLibraryAuthorization { [weak self] authorized in
            guard let self = self else { return }
            
            guard authorized else {
                print("Photo library access denied")
                DispatchQueue.main.async {
                    self.onPhotoSaved?(NSError(domain: "PhotoDownloader", code: -2, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"]))
                }
                return
            }
            
            // Download the photo data
            self.downloadPhotoData(mediaFile: mediaFile) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Download error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.onPhotoSaved?(error)
                    }
                    return
                }
                
                guard let data = data else {
                    let error = NSError(domain: "PhotoDownloader", code: -3, userInfo: [NSLocalizedDescriptionKey: "No photo data received"])
                    DispatchQueue.main.async {
                        self.onPhotoSaved?(error)
                    }
                    return
                }
                
                // Save to Photos library
                self.savePhotoToLibrary(data: data)
            }
        }
    }
    
    /// Download photo data from the drone
    private func downloadPhotoData(mediaFile: DJIMediaFile, completion: @escaping (Data?, Error?) -> Void) {
        var downloadedData = Data()
        var isComplete = false
        
        let updateQueue = DispatchQueue(label: "com.sparkcontroller.photodownload")
        
        mediaFile.fetchData(withOffset: 0, update: updateQueue) { data, complete, error in
            if let error = error {
                if !isComplete {
                    isComplete = true
                    completion(nil, error)
                }
                return
            }
            
            if let data = data {
                downloadedData.append(data)
            }
            
            if complete {
                isComplete = true
                completion(downloadedData, nil)
            }
        }
    }
    
    /// Save photo data to the Photos library
    private func savePhotoToLibrary(data: Data) {
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: nil)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    print("Photo saved to library successfully")
                    self?.onPhotoSaved?(nil)
                } else {
                    print("Failed to save photo: \(error?.localizedDescription ?? "Unknown error")")
                    self?.onPhotoSaved?(error ?? NSError(domain: "PhotoDownloader", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to save photo"]))
                }
            }
        }
    }
}

