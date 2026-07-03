import Testing
@testable import RecapUI

/// `CompletionNotifier.body` / `.durationLabel` — the pure copy-formatting
/// logic behind the "‹meeting› is ready" notification body (design spec 8f):
/// "Transcribed and enhanced · 15m" vs "Transcribed · 15m" depending on
/// whether enhancement produced notes.
@MainActor
@Suite struct CompletionNotifierTests {
    @Test func bodyMentionsEnhancementWhenNotesExist() {
        #expect(CompletionNotifier.body(duration: 900, hasEnhancedNotes: true) == "Transcribed and enhanced · 15m")
    }

    @Test func bodyOmitsEnhancementWhenNoEnhancedNotes() {
        #expect(CompletionNotifier.body(duration: 900, hasEnhancedNotes: false) == "Transcribed · 15m")
    }

    @Test func bodyDropsDurationSeparatorWhenDurationIsZero() {
        #expect(CompletionNotifier.body(duration: 0, hasEnhancedNotes: true) == "Transcribed and enhanced")
    }

    @Test func durationLabelFormatsHoursAndMinutes() {
        #expect(CompletionNotifier.durationLabel(seconds: 3900) == "1h 5m")
    }

    @Test func durationLabelFormatsMinutesOnly() {
        #expect(CompletionNotifier.durationLabel(seconds: 300) == "5m")
    }

    @Test func durationLabelIsEmptyForZeroOrNegative() {
        #expect(CompletionNotifier.durationLabel(seconds: 0).isEmpty)
        #expect(CompletionNotifier.durationLabel(seconds: -5).isEmpty)
    }
}
