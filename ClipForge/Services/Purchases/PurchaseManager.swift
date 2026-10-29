import Foundation
import Observation
import StoreKit

// MARK: - PurchaseManager

/// StoreKit 2 subscriptions for ClipForge Pro.
/// Pro unlocks: 4K export, watermark removal, AI ultra HD, Smart HDR, advanced AI tools.
@MainActor
@Observable
final class PurchaseManager {

    static let productIDs = ["com.clipforge.pro.monthly", "com.clipforge.pro.yearly"]

    enum Feature: String, CaseIterable, Identifiable {
        case export4K, noWatermark, ultraHD, smartHDR, advancedAI
        var id: String { rawValue }
        var title: String {
            switch self {
            case .export4K: return "Export in 4K"
            case .noWatermark: return "No watermark"
            case .ultraHD: return "AI ultra HD"
            case .smartHDR: return "Smart HDR"
            case .advancedAI: return "Advanced AI tools"
            }
        }
        var symbol: String {
            switch self {
            case .export4K: return "4k.tv"
            case .noWatermark: return "drop.degreesign.slash"
            case .ultraHD: return "sparkles.tv"
            case .smartHDR: return "sun.max.trianglebadge.exclamationmark"
            case .advancedAI: return "wand.and.stars"
            }
        }
    }

    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isLoading = false
    var lastError: String?
    /// Presented by the root view when a gated feature is tapped.
    var paywallFeature: Feature?
    var isPaywallPresented = false

    var isPro: Bool { !purchasedProductIDs.isEmpty }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
        Task { await self.load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var ids = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil,
               t.expirationDate.map({ $0 > .now }) ?? true {
                ids.insert(t.productID)
            }
        }
        purchasedProductIDs = ids
    }

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase could not be verified."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                isPaywallPresented = false
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro { lastError = "No active subscription was found for this Apple ID." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns true when the feature is available; otherwise shows the paywall.
    func require(_ feature: Feature) -> Bool {
        if isPro { return true }
        paywallFeature = feature
        isPaywallPresented = true
        return false
    }

    func presentPaywall() {
        paywallFeature = nil
        isPaywallPresented = true
    }

    var monthly: Product? { products.first { $0.id == "com.clipforge.pro.monthly" } }
    var yearly: Product? { products.first { $0.id == "com.clipforge.pro.yearly" } }

    /// "Start Pro for only …" price: the monthly intro offer when there is one.
    var startPriceText: String {
        monthly?.subscription?.introductoryOffer?.displayPrice ?? monthly?.displayPrice ?? "$1.99"
    }
}
