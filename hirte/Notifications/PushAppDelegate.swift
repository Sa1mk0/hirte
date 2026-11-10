import HerdrKit
import UIKit
import UserNotifications

/// What UIKit tells the app about notifications: the device token, and a notification arriving or
/// tapped. The notification center's delegate is set here, before launching ends, so a tap that
/// starts the app from cold is delivered too.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushController.shared.launched()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushController.shared.tokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushController.shared.registrationFailed(error)
    }

    // The notification center calls these on its own thread; the answer goes back on the main thread
    // (UIKit continues with state restoration from the completion and asserts on any other; the
    // async forms completed on a thread of the concurrency pool and crashed the app coming back from
    // the background).

    /// In front: no banner for the terminal that is on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let route = PushRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            completionHandler(PushController.shared.presents(route) ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let route = PushRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if tapped, let route { PushController.shared.open(route) }
            completionHandler()
        }
    }
}
