import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for activity in connectionOptions.userActivities {
      if activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL {
        CheckoutReturnLinkBridge.shared.receive(url)
      }
    }
    for context in connectionOptions.urlContexts {
      CheckoutReturnLinkBridge.shared.receive(context.url)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
      CheckoutReturnLinkBridge.shared.receive(url)
    }
    super.scene(scene, continue: userActivity)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts { CheckoutReturnLinkBridge.shared.receive(context.url) }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
