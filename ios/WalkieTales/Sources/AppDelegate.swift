import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = Store.root // make sure Documents/Cards exists so it shows in the Files app
        let w = TouchWindow(frame: UIScreen.main.bounds)
        let vc = PlayerViewController()
        w.player = vc
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        app.beginReceivingRemoteControlEvents()
        return true
    }

    func applicationWillResignActive(_ app: UIApplication) { Player.shared.savePosition() }
}
