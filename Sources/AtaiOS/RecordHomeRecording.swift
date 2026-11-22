import SwiftUI

/// The Record tab while recording, paused or saving: the timer leads and the
/// same button stops it. No recents and no free minutes here.
struct RecordHomeRecording: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var live = PhoneLive.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The Mac popover uses 30 pt rounded semibold. On the phone the same
    /// face starts at 56 and grows with the Large Title text size.
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 56

    var body: some View {
        // The column is centred while it fits. Past that, the same column
        // scrolls, so the largest text sizes are never clipped.
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var paused: Bool { store.phase == .interrupted }
    private var stopping: Bool { store.phase == .stopping }

    private var content: some View {
        VStack(spacing: Theme.Space.xl) {
            Text(verbatim: Transcriber.timestamp(Int(live.elapsed * 1000)))
                // Not an ataFont: the timer is display type, scaled by @ScaledMetric above.
                .font(.system(size: timerSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(paused ? Theme.warning : Color.primary)
                .contentTransition(.numericText())

            status

            LevelMeter(level: live.level, tint: paused ? Theme.warning : Theme.recordingSolid)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Space.m) {
                HeroRecordButton(size: 132, state: stopping ? .busy : .recording) { store.toggleRecording() }
                    .disabled(stopping)
                    .accessibilityLabel(L("Stop recording"))
                    .sensoryFeedback(.impact, trigger: store.isRecording)
                if stopping {
                    Text("Saving…")
                        .ataHeadline()
                        .foregroundStyle(.secondary)
                }
            }

            if paused {
                interrupted
            } else if !stopping {
                bookmarkButton
            }

            messages
        }
        .frame(maxWidth: .infinity)
    }

    private var status: some View {
        ViewThatFits(in: .horizontal) {
            statusLine
            VStack(spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    statusDot
                    Text(paused ? L("Paused") : L("Recording"))
                        .fontWeight(.semibold)
                }
                Label(store.mode.title, systemImage: store.mode.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(paused ? Theme.warning : Theme.recordingSolid)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Space.s) {
            statusDot
            Text(paused ? L("Paused") : L("Recording"))
                .fontWeight(.semibold)
            Text(verbatim: "·").foregroundStyle(.secondary)
            Label(store.mode.title, systemImage: store.mode.symbol)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var statusDot: some View {
        Circle()
            .fill(paused ? Theme.warning : Theme.recordingSolid)
            .frame(width: 8, height: 8)
    }

    private var bookmarkButton: some View {
        VStack(spacing: Theme.Space.s) {
            Button { store.addBookmark() } label: {
                Label("Mark this moment", systemImage: "bookmark.fill")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            if !store.bookmarks.isEmpty {
                Text(L("Moments marked: %d", store.bookmarks.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var interrupted: some View {
        VStack(spacing: Theme.Space.s) {
            Label {
                Text("Paused: another app is using the microphone.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "pause.circle.fill")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.warning)
            Button("Resume") { store.resumeRecording() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let warning = store.warning {
            Text(warning)
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = store.lastError {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(Theme.danger)
        }
    }
}
