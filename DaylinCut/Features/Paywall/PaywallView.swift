import StoreKit
import SwiftUI

/// Daylin Cut Pro paywall backed by StoreKit 2 products.
struct PaywallView: View {
    let highlight: PurchaseManager.Feature?
    @Environment(PurchaseManager.self) private var purchases
    @State private var selectedID = "com.daylincut.pro.yearly"
    @State private var isPurchasing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                features
                plans
                purchaseButton
                if let error = purchases.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                footer
            }
            .padding(20)
        }
        .background(
            LinearGradient(colors: [Theme.pro.opacity(0.35), Theme.background], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .overlay(alignment: .topTrailing) {
            Button { purchases.isPaywallPresented = false } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .task { if purchases.products.isEmpty { await purchases.load() } }
        .onChange(of: purchases.isPro) { _, pro in if pro { purchases.isPaywallPresented = false } }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(colors: [Color(hex: "B784FF"), Color(hex: "FF5FA2")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.top, 30)
                .accessibilityHidden(true)
            Text("Daylin Cut Pro").font(.largeTitle.weight(.heavy))
            if let highlight {
                Label("\(highlight.title) is a Pro feature", systemImage: highlight.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.2), in: Capsule())
            } else {
                Text("Create without limits").font(.headline).foregroundStyle(.secondary)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(PurchaseManager.Feature.allCases) { f in
                HStack(spacing: 12) {
                    Image(systemName: f.symbol)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.opacity(f == highlight ? 0.45 : 0.18), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    Text(f.title).font(.body.weight(f == highlight ? .bold : .regular))
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityHidden(true)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var plans: some View {
        VStack(spacing: 10) {
            if purchases.products.isEmpty {
                if purchases.isLoading { ProgressView() } else {
                    Text("Subscriptions are unavailable right now.").foregroundStyle(.secondary)
                    Button("Retry") { Task { await purchases.load() } }
                }
            }
            ForEach(purchases.products.reversed(), id: \.id) { product in
                Button { selectedID = product.id } label: { planRow(product) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedID == product.id ? .isSelected : [])
            }
        }
    }

    private func planRow(_ product: Product) -> some View {
        let selected = selectedID == product.id
        return HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(product.displayName).font(.headline)
                Text(offerText(product)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(product.displayPrice).font(.headline)
                Text(periodText(product)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private var purchaseButton: some View {
        Button {
            guard let product = purchases.products.first(where: { $0.id == selectedID }) ?? purchases.products.first else { return }
            isPurchasing = true
            Task {
                await purchases.purchase(product)
                isPurchasing = false
            }
        } label: {
            Group {
                if isPurchasing { ProgressView().tint(.white) } else { Text(ctaTitle).font(.headline) }
            }
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(PillButtonStyle())
        .disabled(purchases.products.isEmpty || isPurchasing)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button("Restore purchases") { Task { await purchases.restore() } }.font(.footnote)
            Text("Subscriptions renew automatically until cancelled in Settings › Apple ID › Subscriptions. Payment is charged to your Apple ID at confirmation.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var ctaTitle: String {
        guard let product = purchases.products.first(where: { $0.id == selectedID }) else { return "Continue" }
        if let offer = product.subscription?.introductoryOffer {
            return offer.paymentMode == .freeTrial ? "Start free trial" : "Start Pro for only \(offer.displayPrice)"
        }
        return "Subscribe for \(product.displayPrice)"
    }

    private func offerText(_ product: Product) -> String {
        guard let offer = product.subscription?.introductoryOffer else { return product.description }
        let period = Self.describe(offer.period)
        switch offer.paymentMode {
        case .freeTrial: return "\(period) free, then \(product.displayPrice)\(periodText(product))"
        default: return "\(offer.displayPrice) for the first \(period)"
        }
    }

    private func periodText(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .year: return "/year"
        case .month: return "/month"
        case .week: return "/week"
        default: return "/day"
        }
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}
