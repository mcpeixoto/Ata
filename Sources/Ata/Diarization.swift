import Foundation

/// Which `Diarizer` Ata uses. Nil until an on-device engine is wired in.
enum Diarization {
    static var current: Diarizer? { nil }
}
