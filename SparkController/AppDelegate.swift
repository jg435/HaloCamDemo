import UIKit
#if !targetEnvironment(simulator)
import DJISDK
#endif

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = MainViewController()
        window?.makeKeyAndVisible()

        #if !targetEnvironment(simulator)
        DJISDKManager.registerApp(with: self)
        #else
        print("Running in Simulator - DJI SDK disabled")
        #endif

        return true
    }
}

#if !targetEnvironment(simulator)
// MARK: - DJI SDK Manager Delegate
extension AppDelegate: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        if let error = error {
            print("SDK Registration Error: \(error.localizedDescription)")
        } else {
            print("SDK Registered Successfully")
            DJISDKManager.startConnectionToProduct()
        }
    }

    func productConnected(_ product: DJIBaseProduct?) {
        print("Product Connected: \(product?.model ?? "Unknown")")
        NotificationCenter.default.post(name: .productConnected, object: product)
    }

    func productDisconnected() {
        print("Product Disconnected")
        NotificationCenter.default.post(name: .productDisconnected, object: nil)
    }

    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {}
}
#endif

extension Notification.Name {
    static let productConnected = Notification.Name("ProductConnected")
    static let productDisconnected = Notification.Name("ProductDisconnected")
}
