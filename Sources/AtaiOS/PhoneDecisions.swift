import Foundation

/// Why a new recording did not start: this month's free minutes are used.
/// The words Siri speaks are `errorDescription`, added where the app can see `L()`.
enum FreeQuotaError: Error, Equatable {
    case limitReached
}

/// The gate at the start of a recording. At the free limit it throws and does
/// not record.
enum RecordingStart {
    /// `usedMinutes` is compared with `limitMinutes`, which the app passes as
    /// `FreeQuota.limitMinutes`. The default is that same 300, so a caller
    /// that only has the minutes still gates on the free tier. This file is
    /// compiled into the iPhone unit tests without the meeting model, so it
    /// cannot name `FreeQuota` itself.
    static func begin(usedMinutes: Int, isPro: Bool, limitMinutes: Int = 300,
                      record: () throws -> Void) throws {
        try begin(needsPro: !isPro && usedMinutes >= limitMinutes, record: record)
    }

    static func begin(needsPro: Bool, record: () throws -> Void) throws {
        if needsPro { throw FreeQuotaError.limitReached }
        try record()
    }
}

/// The share-inbox paywall. Once a launch, and only while files are waiting
/// at the free limit. The files stay in the inbox either way.
enum InboxOffer {
    static func shouldPresent(alreadyOffered: Bool, atLimit: Bool, pending: Int) -> Bool {
        !alreadyOffered && atLimit && pending > 0
    }
}

/// Whether a blocked start may arm the paywall or the microphone message.
/// Arming either while Ata stays in the background makes the sheet appear
/// later, with nothing to explain it.
enum BlockedStartPresentation: Equatable {
    case showNow
    case doNotArm
}

/// The microphone message goes away once permission is granted. Any other
/// error on the Record tab stays until the next attempt.
enum MicDenial {
    static func shouldClear(granted: Bool, showingDenial: Bool) -> Bool {
        granted && showingDenial
    }
}

/// "No meetings yet" covers the import row and the waiting-for-engine row
/// when it is drawn on top of an empty list.
enum MeetingsPlaceholder {
    static func shown(meetings: Int, importing: Int, waitingForEngine: Bool) -> Bool {
        meetings == 0 && importing == 0 && !waitingForEngine
    }
}

/// The iPhone's first-run steps, in the order the dots show them.
/// Raw values are stored in `Pref.onboardingStep`, so the order is the storage.
enum OnboardingFlow {
    enum Step: Int, CaseIterable, Equatable {
        case welcome, useCase, permissions, you, tryIt, pro
    }

    /// The step after `from`, or nil when onboarding is over.
    ///
    /// Saying a sentence is skipped until the microphone is granted: there is
    /// nothing to record. A product that failed to load does not skip the last
    /// step; that step just has nothing to sell.
    static func next(from step: Step, micGranted: Bool, productLoaded: Bool) -> Step? {
        switch step {
        case .welcome: return .useCase
        case .useCase: return .permissions
        case .permissions: return .you
        case .you: return micGranted ? .tryIt : .pro
        case .tryIt: return .pro
        case .pro:
            if productLoaded { return nil }
            return nil
        }
    }

    /// Back, skipping the try-it step the same way `next` does.
    static func previous(from step: Step, micGranted: Bool) -> Step? {
        switch step {
        case .welcome: return nil
        case .useCase: return .welcome
        case .permissions: return .useCase
        case .you: return .permissions
        case .tryIt: return .you
        case .pro: return micGranted ? .tryIt : .you
        }
    }
}

/// What someone said they record most, and the defaults that choice writes.
/// Work and interviews leave the recording mode alone, so call mode stays off.
enum UseCase: String, CaseIterable, Equatable {
    case work, classes, interviews, personal

    struct Defaults: Equatable {
        /// `MeetingCategory.rawValue`.
        var category: String
        /// `RecordingMode.rawValue`. Nil does not change the mode.
        var mode: String?
    }

    var defaults: Defaults {
        switch self {
        case .work, .interviews:
            return Defaults(category: "work", mode: nil)
        case .classes, .personal:
            return Defaults(category: "personal", mode: "inPerson")
        }
    }

    var symbol: String {
        switch self {
        case .work: return "briefcase.fill"
        case .classes: return "graduationcap.fill"
        case .interviews: return "mic.fill"
        case .personal: return "house.fill"
        }
    }
}

enum BlockedStart {
    static func presentation(appIsActive: Bool, becomingForeground: Bool) -> BlockedStartPresentation {
        if appIsActive || becomingForeground { return .showNow }
        return .doNotArm
    }
}

/// Which Pro prompt, if any, should be shown for what just happened.
///
/// The caller stores the dates and the counts. This only decides. `limit` and
/// `feature` are never held back. `eightyPercent` is an inline banner, once
/// each calendar month. `firstTranscript` is the only modal this applies the
/// three-day cap to, and it stays quiet on a day the App Store review prompt
/// (Track 9) already asked.
enum ProPrompt: Equatable {
    case eightyPercent
    case firstTranscript
    case limit
    case feature(Feature)

    /// Same raw values as `ProFeature`. Named here so this file stays free of
    /// the app target: the unit tests compile it on its own.
    enum Feature: String, Equatable, CaseIterable {
        case askMeetings
        case customTemplates
        case documentExport
    }

    enum Event: Equatable {
        /// Record home. `alreadyThisMonth` is the banner having been shown in
        /// this calendar month.
        case eightyPercent(alreadyThisMonth: Bool)
        /// A transcript finished. `reviewPromptToday` is Track 9's review ask.
        case firstTranscript(foreground: Bool, recording: Bool, celebrated: Bool, reviewPromptToday: Bool)
        case limit
        case feature(Feature)
    }

    /// How long the first-transcript sheet waits after the transcript finishes.
    static let firstTranscriptDelay: TimeInterval = 2
    /// At most one modal prompt per this long, apart from `limit` and `feature`.
    static let modalGap: TimeInterval = 3 * 24 * 60 * 60
    /// `yyyy-MM` of the month the eighty-percent banner was shown.
    static let eightyPercentMonthKey = "proPromptEightyPercentMonth"
    /// `yyyy-MM-dd` Track 9 writes when it asks for an App Store review.
    static let reviewPromptDayKey = "reviewPromptDay"

    static func due(used: Int, limit: Int, isPro: Bool, lastShown: Date?, count: Int,
                    event: Event, now: Date = Date()) -> ProPrompt? {
        if isPro { return nil }
        switch event {
        case .limit:
            return .limit
        case .feature(let feature):
            return .feature(feature)
        case .eightyPercent(let already):
            guard !already, reachedEighty(used: used, limit: limit), used < limit else { return nil }
            return .eightyPercent
        case .firstTranscript(let foreground, let recording, let celebrated, let reviewToday):
            guard foreground, !recording, !celebrated, !reviewToday else { return nil }
            guard !modalCoolingDown(lastShown: lastShown, count: count, now: now) else { return nil }
            return .firstTranscript
        }
    }

    /// 80% of the allowance, the same line the quota bar turns amber on.
    static func reachedEighty(used: Int, limit: Int) -> Bool {
        guard limit > 0, used > 0 else { return false }
        return used * 5 >= limit * 4
    }

    /// A recorded modal (`count` > 0) whose `lastShown` is under three days ago.
    /// A count of zero means nothing was shown, so a leftover date does not block.
    static func modalCoolingDown(lastShown: Date?, count: Int, now: Date) -> Bool {
        guard count > 0, let lastShown else { return false }
        return now.timeIntervalSince(lastShown) < modalGap
    }

    static func monthID(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func dayID(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The yearly saving and the trial's day numbers, from the two prices and the
/// introductory period. No currency and no fixed 46.
enum PlanMath {
    enum Unit { case day, week, month, year }

    static func savingsPercent(yearly: Decimal, monthly: Decimal) -> Int? {
        guard monthly > 0 else { return nil }
        let full = monthly * 12
        guard full > yearly else { return nil }
        var ratio = ((full - yearly) / full) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &ratio, 0, .plain)
        let percent = NSDecimalNumber(decimal: rounded).intValue
        return percent > 0 ? percent : nil
    }

    /// A week is seven days. Months and years are not a day count.
    static func days(unit: Unit, value: Int, count: Int) -> Int? {
        let each: Int
        switch unit {
        case .day: each = 1
        case .week: each = 7
        case .month, .year: return nil
        }
        let total = each * value * count
        return total > 0 ? total : nil
    }

    /// Day 5 of a 7-day trial: the reminder goes out two days before it ends.
    static func reminderDay(trialDays: Int) -> Int {
        guard trialDays > 2 else { return max(trialDays, 1) }
        return trialDays - 2
    }
}

/// What happens to the transcription queue when a recording starts or stops,
/// and when iOS ends the background task. Both pauses cancel the running job;
/// that cancellation saves the meeting back as pending. Stopping resumes the queue.
enum RecordingQueue {
    enum Event: Equatable {
        case recordingWillStart
        case recordingStopped
        case backgroundExpired
    }

    struct Decision: Equatable {
        var queuePaused: Bool
        var cancelJob: Bool
        /// The in-flight meeting goes back to pending. Cancelling the job does it.
        var savesMeetingAsPending: Bool
    }

    static func decide(_ event: Event, jobRunning: Bool) -> Decision {
        switch event {
        case .recordingWillStart, .backgroundExpired:
            return Decision(queuePaused: true, cancelJob: jobRunning, savesMeetingAsPending: jobRunning)
        case .recordingStopped:
            return Decision(queuePaused: false, cancelJob: false, savesMeetingAsPending: false)
        }
    }
}
