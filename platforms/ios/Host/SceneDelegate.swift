import UIKit

/// iOS 27 requires scenes for apps linked against its SDK. The window and file
/// delivery belong to the connected scene, not the process-wide app delegate.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingDocument: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowApplication, let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = LianaPalette.ink
        window.rootViewController = ViewController()
        self.window = window
        pendingDocument = connectionOptions.urlContexts.first(where: { $0.url.isFileURL })?.url
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) { deliverPendingDocument() }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first(where: { $0.url.isFileURL })?.url else { return }
        pendingDocument = url
        if scene.activationState == .foregroundActive { deliverPendingDocument() }
    }

    private func deliverPendingDocument() {
        guard let url = pendingDocument, let controller = window?.rootViewController as? ViewController else { return }
        pendingDocument = nil
        // Avoid presenting a navigation controller before the new scene's root
        // controller has joined a visible window, including cold file launches.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller else { return }
            if controller.viewIfLoaded?.window != nil { controller.showMacLink(file: url) }
            else { self.pendingDocument = url }
        }
    }
}
