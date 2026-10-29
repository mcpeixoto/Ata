import StoreKit
import SwiftUI

/// Ata Pro: one auto-renewable subscription that lifts the iPhone's free
/// allowance (`FreeQuota`). The Mac never asks for it.
///
/// Whether you have it is cached, so a phone offline keeps what it paid for;
/// StoreKit corrects the cache whenever it answers. If the product cannot be
/// loaded the paywall says so and offers to try again: nothing crashes, and
/// recording within the free allowance carries on as before.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    static let productID = "ai.interactive.ata.pro.monthly"
    private static let cacheKey = "proActive"

    @Published private(set) var product: Product?
    @Published private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: ProStore.cacheKey)
    @Published private(set) var loading = false
    /// The product did not load: no network, or not in the App Store yet.
    @Published private(set) var unavailable = false
    @Published private(set) var purchasing = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    private init() {}

    /// At launch: listen for renewals, refunds and purchases made elsewhere
    /// (another device, Ask to Buy, a code), then load the product and the entitlement.
    func start() {
        guard updates == nil else { return }
        updates = Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await ProStore.shared.refresh()
            }
        }
        Task {
            await refresh()
            await load()
        }
    }

    func load() async {
        guard !loading, !Snapshots.rendering else { return }
        loading = true
        defer { loading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            NSLog("Ata: could not load Ata Pro: \(error.localizedDescription)")
        }
        unavailable = product == nil
    }

    /// Whether a verified, unrevoked, unexpired Ata Pro transaction exists now.
    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.productID == Self.productID,
                  t.revocationDate == nil else { continue }
            if let expires = t.expirationDate, expires < Date() { continue }
            active = true
        }
        setPro(active)
    }

    func purchase() async {
        guard let product, !purchasing else { return }
        purchasing = true
        defer { purchasing = false }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = L("The App Store could not confirm this purchase.")
                    return
                }
                await transaction.finish()
                await refresh()
            case .pending:
                message = L("Your purchase is waiting for approval. Ata Pro starts as soon as it is approved.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// "Restore Purchases": asks the App Store for this Apple Account's
    /// transactions. `StoreKit.AppStore`, because `AppStore` here is `PhoneStore`.
    func restore() async {
        purchasing = true
        defer { purchasing = false }
        message = nil
        do {
            try await StoreKit.AppStore.sync()
        } catch {
            message = error.localizedDescription
        }
        await refresh()
        if !isPro, message == nil {
            message = L("No Ata Pro subscription was found for this Apple Account.")
        }
    }

    private func setPro(_ active: Bool) {
        guard !Snapshots.rendering else { return }
        isPro = active
        UserDefaults.standard.set(active, forKey: Self.cacheKey)
    }

    /// "€2.99 / month", or nil until the product loads.
    var priceText: String? {
        guard let product else { return Snapshots.rendering ? Snapshots.price : nil }
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        return L("%@ / %@", product.displayPrice, Self.name(of: period))
    }

    private static func name(of period: Product.SubscriptionPeriod) -> String {
        switch (period.unit, period.value) {
        case (.month, 1): return L("month")
        case (.year, 1): return L("year")
        case (.week, 1): return L("week")
        case (.month, let n): return L("%d months", n)
        case (.year, let n): return L("%d years", n)
        case (.week, let n): return L("%d weeks", n)
        case (.day, let n): return n == 1 ? L("day") : L("%d days", n)
        @unknown default: return ""
        }
    }
}
