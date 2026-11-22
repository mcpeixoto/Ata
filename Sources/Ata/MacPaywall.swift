#if os(macOS)
import SwiftUI

/// Ata Pro on the Mac. 440×560, the size the layout was written for.
/// While `AtaLicenceURL` is empty the purchase button and the key field stay
/// hidden, and the only route on screen is the iPhone subscription.
struct MacPaywall: View {
    static let width: CGFloat = 440
    static let height: CGFloat = 560

    /// A fixed paywall for the screenshots. The live window leaves this nil.
    struct Fixture {
        var usedMinutes: Int
        var isActive: Bool
        var licenceActive: Bool
        var showsPurchase: Bool

        static let limit = Fixture(usedMinutes: 300, isActive: false, licenceActive: false, showsPurchase: true)
        static let active = Fixture(usedMinutes: 300, isActive: true, licenceActive: true, showsPurchase: false)
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    @ObservedObject private var access = ProAccess.shared
    @ObservedObject private var licence = LicenceStore.shared
    var fixture: Fixture? = nil

    @State private var showKey = false
    @State private var key = ""
    @State private var showHow = false
    @State private var showEmail = false
    @State private var email = ""

    private var usedMinutes: Int { fixture?.usedMinutes ?? store.freeUsed }
    private var isActive: Bool { fixture?.isActive ?? access.isPro }
    private var licenceActive: Bool { fixture?.licenceActive ?? licence.isActive }
    private var showsPurchase: Bool { fixture?.showsPurchase ?? (MacProOffer.isConfigured && MacProOffer.displayPrice != nil) }
    private var notice: LicenceNotice? { fixture == nil ? licence.notice : nil }
    private var activating: Bool { fixture == nil && licence.activating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if !isActive {
                    QuotaMeter(usedMinutes: usedMinutes, limitMinutes: FreeQuota.limitMinutes)
                }
                features
                if !isActive { iphoneCard }
                if isActive {
                    activeBlock
                } else if showsPurchase {
                    purchase
                }
                if let notice, notice != .sent {
                    Banner(kind: .danger, mark: .symbol("exclamationmark.triangle.fill"),
                           title: Text(verbatim: notice.message))
                }
                if notice == .sent, let notice {
                    Text(verbatim: notice.message)
                        .ataCaption()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width, height: Self.height)
        .onAppear { if licence.revealKeyField { showKey = true } }
        .onChange(of: licence.revealKeyField) { _, on in
            if on { showKey = true }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            AppGlyph(size: 56)
            Text("Ata Pro")
                .ataLargeTitle()
            Text("Unlimited meetings on Mac and iPhone")
                .ataCallout()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            featureRow { Text("No monthly limit") }
            featureRow { Text("Still transcribed on your Mac, private") }
            featureRow { Text("One subscription, both devices") }
        }
    }

    private func featureRow<Label: View>(@ViewBuilder title: () -> Label) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "checkmark")
                .ataHeadline()
                .foregroundStyle(Theme.accent)
            title()
                .ataBody()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var iphoneCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Have Ata on iPhone?")
                .ataHeadline()
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text("Subscribe there; this Mac unlocks by itself through iCloud.")
                    .ataCallout()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                Button("How it works") { showHow.toggle() }
                    .buttonStyle(.plain)
                    .ataCallout()
                    .foregroundStyle(Theme.accent)
            }
            if showHow {
                Text("Subscribe in Ata on your iPhone. This Mac unlocks through iCloud, and stays unlocked for three days after that subscription ends.")
                    .ataCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var purchase: some View {
        VStack(spacing: Theme.Space.s) {
            if let price = MacProOffer.displayPrice, let url = MacProOffer.checkoutURL {
                Button {
                    openURL(url)
                } label: {
                    Text(L("Get Ata Pro for Mac — %@", price))
                        .ataHeadline()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Button {
                showKey.toggle()
            } label: {
                Text("I have a licence key")
                    .ataHeadline()
            }
            .buttonStyle(SecondaryButtonStyle())
            if showKey { keyField }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Licence key", text: $key)
                .textFieldStyle(.roundedBorder)
                .ataBody()
            Button {
                Task { await licence.activate(rawKey: key) }
            } label: {
                if activating {
                    ProgressView().controlSize(.small).tint(Theme.accentInk)
                } else {
                    Text("Activate").ataHeadline()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(activating)
            Button("Email me my key") { showEmail.toggle() }
                .buttonStyle(.plain)
                .ataCallout()
                .foregroundStyle(Theme.accent)
            if showEmail {
                TextField("Your email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .ataBody()
                Button {
                    Task { await licence.recover(email: email) }
                } label: {
                    Text("Send").ataHeadline()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var activeBlock: some View {
        VStack(spacing: Theme.Space.m) {
            Text("Ata Pro is active on this Mac")
                .ataHeadline()
                .frame(maxWidth: .infinity)
            if licenceActive {
                Button {
                    Task { await licence.deactivate() }
                } label: {
                    Text("Deactivate").ataHeadline()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if !isActive {
                Text(L("Resets on %@", resetText))
                    .ataCaption()
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .ataCaption()
                    .foregroundStyle(.secondary)
            }
            Button {
                WindowManager.shared.closePro()
            } label: {
                Text("Not now").ataCaption()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var resetText: String {
        MacProOffer.nextReset(now: Date()).formatted(.dateTime.day().month(.wide))
    }
}
#endif
