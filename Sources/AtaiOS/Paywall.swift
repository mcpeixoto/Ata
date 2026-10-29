import StoreKit
import SwiftUI

/// Ata Pro: what it adds, what it costs and how it renews, with Restore and the
/// two links the App Store asks for. Shown when the free meetings run out, and
/// from Settings.
struct Paywall: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dismiss) private var dismiss

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://mcpeixoto.github.io/Ata/privacy/")!

    private var remaining: Int { FreeQuota.remaining(used: store.freeUsed) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AppGlyph(size: 72)
                        .padding(.top, 8)
                    VStack(spacing: 8) {
                        Text("Ata Pro")
                            .font(.largeTitle.bold())
                        Text(pro.isPro
                             ? L("You have Ata Pro. Thank you!")
                             : L("%d of %d free meetings left this month", remaining, FreeQuota.limit))
                            .font(.subheadline)
                            .foregroundStyle(remaining == 0 && !pro.isPro ? Color.orange : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Feature(symbol: "infinity", title: L("Unlimited meetings on iPhone"),
                                detail: L("Record and import as many as you like. Without Pro, 5 new meetings a month are free."))
                        Feature(symbol: "iphone", title: L("Transcribed on your iPhone"),
                                detail: L("Transcripts and voices are made on the device, with or without Pro."))
                        Feature(symbol: "laptopcomputer", title: L("Ata for Mac stays free"),
                                detail: L("Meetings recorded on your Mac never count, and the Mac app needs no subscription."))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if !pro.isPro { purchase }

                    if let message = pro.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 18) {
                        Link("Terms of Use", destination: Self.termsURL)
                        Link("Privacy Policy", destination: Self.privacyURL)
                    }
                    .font(.footnote)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
            }
        }
        .task {
            if pro.product == nil { await pro.load() }
        }
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    @ViewBuilder
    private var purchase: some View {
        VStack(spacing: 10) {
            Button {
                Task { await pro.purchase() }
            } label: {
                Group {
                    if pro.purchasing || (pro.loading && pro.priceText == nil) {
                        ProgressView().tint(.white)
                    } else if let price = pro.priceText {
                        Text(L("Subscribe for %@", price))
                    } else {
                        Text("Unavailable right now")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pro.priceText == nil || pro.purchasing)
            .accessibilityIdentifier("subscribe")

            if pro.unavailable && !pro.loading {
                Button("Try again") { Task { await pro.load() } }
                    .font(.subheadline)
            } else {
                Text("Renews monthly until cancelled. Cancel any time in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Restore Purchases") { Task { await pro.restore() } }
                .font(.subheadline)
                .disabled(pro.purchasing)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.meTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
