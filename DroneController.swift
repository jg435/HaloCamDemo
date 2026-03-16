//
//  DroneController.swift
//

import Foundation
#if !targetEnvironment(simulator)
import DJISDK
#endif

final class DroneController {
    
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
        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            print("No aircraft / flight controller")
            return
        }
        
        fc.startTakeoff { error in
            if let error = error {
                print("Takeoff error: \(error.localizedDescription)")
            } else {
                print("Takeoff started")
            }
        }
        #else
        print("Takeoff (simulator)")
        #endif
    }
    
    private func startLanding() {
        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let fc = aircraft.flightController else {
            print("No aircraft / flight controller")
            return
        }
        
        fc.startLanding { error in
            if let error = error {
                print("Landing error: \(error.localizedDescription)")
            } else {
                print("Landing started")
            }
        }
        #else
        print("Landing (simulator)")
        #endif
    }
    
    private func takePhotoOnce() {
        #if !targetEnvironment(simulator)
        guard let aircraft = DJISDKManager.product() as? DJIAircraft,
              let camera = aircraft.camera else {
            print("No aircraft / camera")
            return
        }
        
        // Ensure camera is in photo mode
        camera.setMode(.shootPhoto) { error in
            if let error = error {
                print("setMode error: \(error.localizedDescription)")
                return
            }
            
            camera.startShootPhoto { error in
                if let error = error {
                    print("startShootPhoto error: \(error.localizedDescription)")
                } else {
                    print("Photo captured")
                }
            }
        }
        #else
        print("Take photo (simulator)")
        #endif
    }
    
    // MARK: - Hard-coded "photo position" script
    
    /// Voice command: "photo position"
    /// Script:
    ///  - Take off
    ///  - Climb to ~3m
    ///  - Take a single photo
    ///  - Then hover
    private func runPhotoPositionRoutine() {
        #if !targetEnvironment(simulator)
        guard let missionControl = DJISDKManager.missionControl() else {
            print("MissionControl unavailable")
            return
        }
        
        // Stop and clear previous timeline if any
        missionControl.stopTimeline()
        missionControl.unscheduleEverything()
        
        var elements: [DJIMissionControlTimelineElement] = []
        
        // 1) Takeoff
        let takeoff = DJITakeOffAction()
        elements.append(takeoff)
        
        // 2) Go to fixed altitude (meters, relative to takeoff)
        let goToAltitude = DJIGoToAction(altitude: 3.0)
        if let goToAltitude = DJIGoToAction(altitude: 3.0) {
            elements.append(goToAltitude)
        }
        // 3) Take a single photo
        let shootPhotoAction = DJIShootPhotoAction()
        elements.append(shootPhotoAction)
        
        missionControl.scheduleElements(elements)
        missionControl.startTimeline()
        #else
        print("Photo position routine (simulator)")
        #endif
    }
}

