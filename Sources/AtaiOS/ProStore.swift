import StoreKit
import SwiftUI

/// Ata Pro: the monthly and yearly subscriptions that lift the iPhone's free
/// allowance (`FreeQuota`). Either one is Pro. The Mac never asks for a purchase
/// here; a refresh writes the entitlement's end into `ProMirror` so the Mac can
/// read it.
///
/// Whether you have it is cached, so a phone offline keeps what it paid for;
/// StoreKit corrects the cache whenever it answers. If neither product can be
/// loaded the paywall says so and offers to try again: nothing crashes, and
/// recording within the free allowance carries on as before.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    static let monthlyID = "ai.interactive.ata.pro.monthly"
    static let yearlyID = "ai.interactive.ata.pro.yearly"
    /// The original product. Callers that only know the one id still mean monthly.
    static let productID = monthlyID
    static let productIDs = [monthlyID, yearlyID]
    private static let cacheKey = "proActive"

    @Published private(set) var monthly: Product?
    @Published private(set) var yearly: Product?
    @Published private(set) var isPro: Bool
    /// The yearly introductory offer is still available to this Apple Account.
    /// `Product.SubscriptionInfo.isEligibleForIntroOffer` is async; this is the
    /// answer from the last `load()`.
    @Published private(set) var trialEligible = false
    @Published private(set) var loading = false
    /// Neither product loaded: no network, or not in the App Store yet.
    @Published private(set) var unavailable = false
    @Published private(set) var purchasing = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    private init() {
        // The cache is what an offline phone keeps. No expiration yet, so this
        // does not write the mirror: `0` there means not Pro.
        isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        ProAccess.shared.setStoreKit(active: isPro, expires: nil)
        if Snapshots.rendering {
            switch Snapshots.screen {
            case .paywall, .paywallLimit, .paywallMonthly:
                // The storekit file's yearly product carries the one-week trial.
                // A UI test never reaches StoreKit, so the fixture says it is open.
                trialEligible = true
            default:
                break
            }
        }
    }

    /// At launch: listen for renewals, refunds and purchases made elsewhere
    /// (another device, Ask to Buy, a code), then load the products and the entitlement.
    func start() {
        guard updates == nil else { return }
        updates = Task.detached {
            for await result in StoreKit.Transaction.updates {
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
            let found = try await Product.products(for: Self.productIDs)
            monthly = found.first { $0.id == Self.monthlyID }
            yearly = found.first { $0.id == Self.yearlyID }
            if let subscription = yearly?.subscription {
                trialEligible = await subscription.isEligibleForIntroOffer
            } else {
                trialEligible = false
            }
        } catch {
            NSLog("Ata: could not load Ata Pro: \(error.localizedDescription)")
        }
        unavailable = monthly == nil && yearly == nil
    }

    /// Whether a verified, unrevoked, unexpired Ata Pro transaction exists now.
    /// Monthly and yearly both count. The mirror is written from here, via
    /// `ProAccess`, so a Mac sees the new end the next time it reads `proUntil`.
    func refresh() async {
        var active = false
        var expires: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIDs.contains(t.productID),
                  t.revocationDate == nil else { continue }
            if let end = t.expirationDate, end < Date() { continue }
            active = true
            if let end = t.expirationDate, end > (expires ?? .distantPast) {
                expires = end
            }
        }
        // A verified entitlement with no end still has to mirror as Pro. `0`
        // is reserved for not Pro; both subscriptions always have a date.
        let mirrored = active ? (expires ?? .distantFuture) : nil
        setPro(active, expires: mirrored)
    }

    func purchase(_ product: Product) async {
        guard !purchasing else { return }
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
                let trial = Self.startedTrial(transaction)
                await transaction.finish()
                await refresh()
                if trial {
                    Funnel.count(.trialStarted)
                    if let days = Self.freeTrialDays(of: product), days > 2 {
                        let reminder = PlanMath.reminderDay(trialDays: days)
                        Notifier.shared.scheduleTrialReminder(fireAfterDays: reminder,
                                                              daysLeft: days - reminder,
                                                              price: product.displayPrice)
                    }
                } else if let plan = Self.plan(for: product.id) {
                    Funnel.count(.purchased(plan))
                }
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

    /// How much cheaper a year is than twelve months, from the loaded prices.
    /// Nil until both products have loaded, and when a year does not cost less.
    var savingsPercent: Int? {
        if let yearly, let monthly {
            return PlanMath.savingsPercent(yearly: yearly.price, monthly: monthly.price)
        }
        guard Snapshots.rendering else { return nil }
        return PlanMath.savingsPercent(yearly: Snapshots.yearlyDecimal, monthly: Snapshots.monthlyDecimal)
    }

    /// The introductory offer's length in days, when it is a free trial we can
    /// count in days. The snapshot fixture uses the storekit file's one week.
    var introductoryDays: Int {
        if let yearly, let days = Self.freeTrialDays(of: yearly) { return days }
        return Snapshots.rendering && trialEligible ? 7 : 0
    }

    func amount(for plan: Plan) -> String? {
        switch plan {
        case .monthly:
            if let monthly { return monthly.displayPrice }
        case .yearly:
            if let yearly { return yearly.displayPrice }
        case .lifetime:
            return nil
        }
        guard Snapshots.rendering else { return nil }
        switch plan {
        case .monthly: return Snapshots.format(Snapshots.monthlyDecimal)
        case .yearly: return Snapshots.format(Snapshots.yearlyDecimal)
        case .lifetime: return nil
        }
    }

    /// A twelfth of the yearly price, in that product's own currency format.
    func yearlyPerMonthAmount() -> String? {
        if let yearly {
            return (yearly.price / 12).formatted(yearly.priceFormatStyle)
        }
        guard Snapshots.rendering else { return nil }
        return Snapshots.format(Snapshots.yearlyDecimal / 12)
    }

    func periodName(for plan: Plan) -> String {
        let product: Product? = plan == .yearly ? yearly : monthly
        if let product, let period = product.subscription?.subscriptionPeriod {
            return Self.name(of: period)
        }
        switch plan {
        case .yearly: return L("year")
        case .monthly: return L("month")
        case .lifetime: return ""
        }
    }

    func product(for plan: Plan) -> Product? {
        switch plan {
        case .monthly: return monthly
        case .yearly: return yearly
        case .lifetime: return nil
        }
    }

    private func setPro(_ active: Bool, expires: Date?) {
        guard !Snapshots.rendering else { return }
        isPro = active
        UserDefaults.standard.set(active, forKey: Self.cacheKey)
        ProAccess.shared.setStoreKit(active: active, expires: expires)
    }

    private static func plan(for productID: String) -> Plan? {
        switch productID {
        case monthlyID: return .monthly
        case yearlyID: return .yearly
        default: return nil
        }
    }

    /// An introductory free trial. A pay-up-front or pay-as-you-go intro is a purchase.
    private static func startedTrial(_ transaction: StoreKit.Transaction) -> Bool {
        guard let offer = transaction.offer, offer.type == .introductory else { return false }
        return offer.paymentMode != .payAsYouGo && offer.paymentMode != .payUpFront
    }

    private static func freeTrialDays(of product: Product) -> Int? {
        guard let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return PlanMath.days(unit: PlanMath.Unit(offer.period.unit),
                              value: offer.period.value, count: offer.periodCount)
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

extension PlanMath.Unit {
    init(_ unit: Product.SubscriptionPeriod.Unit) {
        switch unit {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .year
        @unknown default: self = .day
        }
    }
}
