import SwiftUI
import UIKit

/// Presents the paywall above whatever is currently on screen.
/// SwiftUI's `.sheet` on the root cannot appear while a full-screen cover or
/// another sheet is showing, so the paywall is hosted in UIKit instead.
@MainActor
final class PaywallPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = PaywallPresenter()
    private weak var controller: UIViewController?
    private weak var purchases: PurchaseManager?

    func present(purchases: PurchaseManager) {
        guard controller == nil, let top = Self.topViewController() else { return }
        self.purchases = purchases
        let host = UIHostingController(rootView: PaywallView(highlight: purchases.paywallFeature).environment(purchases))
        host.modalPresentationStyle = .pageSheet
        host.presentationController?.delegate = self
        host.overrideUserInterfaceStyle = top.traitCollection.userInterfaceStyle
        controller = host
        top.present(host, animated: true)
    }

    func dismiss() {
        controller?.dismiss(animated: true)
        controller = nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        controller = nil
        purchases?.isPaywallPresented = false
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
