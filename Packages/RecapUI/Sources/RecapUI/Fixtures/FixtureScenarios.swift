import Foundation
import OSLog
import RecapAudio
import RecapCore

private let fixtureScenariosLog = Logger(subsystem: "com.gregfoster.recap", category: "FixtureScenarios")

/// Named `-fixtures <scenario>` graphs. `LaunchConfiguration` carries the raw
/// scenario string through unvalidated (it's a pure parse of launch
/// arguments); this is the one place that turns it into an actual `LibraryStore`
/// + `UpcomingStore` pair, so `AppStores.init` stays a thin dispatch.
///
/// Every scenario keeps the same ephemeral contract as `LibraryStore.fixture()`
/// today: no disk writes (aside from `FixtureAudio`'s throwaway temp folder),
/// no processing queue, in-memory only.
public enum FixtureScenario: String, CaseIterable, Sendable {
    /// Today's fixture set, unchanged: a handful of meetings spanning every
    /// status, one with playable audio + transcript + notes.
    case `default`
    /// First-run/empty library — onboarding already complete, nothing
    /// recorded yet, calendar not connected either (the agenda renders its
    /// "Connect your calendar" affordance).
    case empty
    /// First-run/empty library, but calendar access IS granted with events
    /// today — the Granola-style "always-available agenda" state: the
    /// Upcoming section renders above an otherwise-empty library, proving
    /// the agenda isn't gated on having recorded a meeting yet.
    case firstRunWithAgenda
    /// Calendar access granted, but nothing meeting-shaped left today — the
    /// explicit "No meetings on your calendar today" quiet state, distinct
    /// from `.empty`'s unauthorized affordance. Uses the `default` library
    /// (not empty) so this also proves the state renders above a populated
    /// meeting list, not just a fresh one.
    case noMeetingsToday
    /// 20+ meetings across many weeks and every status, several with
    /// transcripts + notes — exercises list grouping/perf.
    case busy
    /// A queue mid-flight: several meetings in in-progress/queued states so
    /// the list's per-row progress states render.
    case processing
    /// Failed/retry-able job states, including a meeting with a failed
    /// transcription.
    case error
    // TODO(phase-3x): give each of these its own dedicated fixture graph
    // once the corresponding redesigned surface lands; for now they reuse
    // the nearest existing scenario so the launch-arg name already resolves.
    /// Redesigned full-window recording view (`RecordingView` + the docked
    /// `SessionCapsule`). Dedicated graph: `FixtureScenarios.recordingSession(activeIn:)`
    /// builds a `MeetingSessionStore` mid-recording (synthetic zero-hardware
    /// recorder, canned levels, a couple of timed notes already saved) —
    /// `AppStores`'s `.fixtures` graph is the caller (mirrors how it already
    /// wires the `-soak` graph's synthetic session).
    case recording
    /// Redesigned first-run flow. TODO(phase-3x): dedicated graph.
    case firstRun
    /// Backup stuck/failing state. TODO(phase-3x): dedicated graph.
    case backupStuck
    /// A meeting recovered from a crash spool (`MeetingStatus.recovered`).
    /// TODO(phase-3x): dedicated graph.
    case recovered
    /// Transcription setup (model download) in progress. TODO(phase-3x): dedicated graph.
    case waitingForSetup
    /// A calendar meeting starting soon, for the "next meeting" banner.
    /// TODO(phase-3x): dedicated graph.
    case nextMeetingSoon

    /// Parses a raw `-fixtures <name>` scenario string. Unknown strings fall
    /// back to `.default` with a warning — a typo'd scenario name should
    /// never crash or silently boot a blank app.
    public init(rawScenario: String) {
        if let known = FixtureScenario(rawValue: rawScenario) {
            self = known
        } else {
            fixtureScenariosLog.warning("Unknown fixture scenario '\(rawScenario, privacy: .public)' — falling back to default")
            self = .default
        }
    }

    /// Builds this scenario's `LibraryStore`.
    @MainActor
    public var library: LibraryStore {
        switch self {
        case .default, .noMeetingsToday, .recording, .nextMeetingSoon: FixtureScenarios.defaultLibrary()
        case .empty, .firstRunWithAgenda, .firstRun: FixtureScenarios.emptyLibrary()
        case .busy: FixtureScenarios.busyLibrary()
        case .processing: FixtureScenarios.processingLibrary()
        case .error, .backupStuck: FixtureScenarios.errorLibrary()
        case .recovered: FixtureScenarios.recoveredLibrary()
        case .waitingForSetup: FixtureScenarios.waitingForSetupLibrary()
        }
    }

    /// Builds this scenario's `UpcomingStore`. `.empty` has no upcoming
    /// events and no calendar access, matching a bare first run (renders the
    /// "Connect your calendar" affordance). `.firstRunWithAgenda` swaps in
    /// the standard fixture events on top of that same empty library, so the
    /// always-available agenda is screenshottable without a recorded
    /// meeting. `.noMeetingsToday` is authorized but has zero events, so the
    /// agenda renders its explicit "No meetings on your calendar today"
    /// state instead. Every other scenario reuses the standard fixture events.
    @MainActor
    public var upcoming: UpcomingStore {
        switch self {
        case .empty: UpcomingStore(availability: { false }, provider: { _ in [] })
        case .noMeetingsToday: UpcomingStore(availability: { true }, provider: { _ in [] })
        case .firstRunWithAgenda: .fixture()
        default: .fixture()
        }
    }
}

/// Scenario factories. Internal helpers behind `FixtureScenario`'s computed
/// properties above — kept as free functions in one enum namespace so each
/// scenario's construction is easy to scan independently.
enum FixtureScenarios {
    /// A record-builder shared by every scenario: same shape as
    /// `LibraryStore.fixture()`'s local helper, hoisted here so `busy` can
    /// generate many meetings without duplicating the boilerplate.
    private static func record(
        _ title: String, now: Date, hoursAgo: Double, duration: TimeInterval,
        attendees: [String], status: MeetingStatus, subtitle: String? = nil
    ) -> MeetingRecord {
        MeetingRecord(
            meeting: Meeting(
                title: title, date: now.addingTimeInterval(-hoursAgo * 3_600),
                duration: duration, attendees: attendees, status: status,
                subtitle: subtitle
            ),
            folderURL: URL(filePath: "/dev/null")
        )
    }

    // MARK: default

    /// Today's fixture set — moved verbatim from `LibraryStore.fixture()`,
    /// which now forwards here so there's exactly one definition.
    @MainActor
    static func defaultLibrary() -> LibraryStore {
        let now = Date.now
        var standup = record(
            "Weekly standup", now: now, hoursAgo: 6, duration: 900, attendees: ["Maya", "Sam"], status: .ready,
            subtitle: "Q3 draft shipped, onboarding usability pass assigned"
        )
        // Give just this one ready meeting a real audio file: every other
        // fixture record points at `/dev/null`, so pointing one meeting's
        // folder at a throwaway temp folder holding a short silent `.m4a`
        // keeps a finished-meeting fixture that models real audio on disk
        // (utterances span 0–38s below).
        if let audioFolder = FixtureAudio.makeSilentMeetingFolder(duration: 40) {
            standup.folderURL = audioFolder
        }
        // Canned transcript for the first ready meeting, so fixture runs can
        // exercise the transcript pane (avatars, speaker rename).
        let standupTranscript = Transcript(
            utterances: [
                Utterance(speakerID: "S1", start: 0, end: 6, text: "Morning everyone — quick roundtable, then the roadmap check-in."),
                Utterance(speakerID: "S2", start: 6, end: 14, text: "I shipped the Q3 draft yesterday. Feedback is due Friday, so please get comments in early."),
                Utterance(speakerID: "S1", start: 14, end: 21, text: "Will do. One flag: the onboarding revision still needs a second usability pass."),
                Utterance(speakerID: "S3", start: 21, end: 30, text: "I can take that — I have two sessions booked this week and can fold it in."),
                Utterance(speakerID: "S2", start: 30, end: 38, text: "Great. Last thing: performance regressions on older laptops. Sam follows up with numbers next week."),
            ],
            engine: "fixture", model: "fixture", language: "en"
        )
        // Canned raw + enhanced notes for the same meeting, so fixture runs
        // can exercise the ✨ Enhanced / My notes segmented control, the
        // enhanced-caption + Undo affordance, and EnhancedNotesView's
        // supported Markdown subset (design handoff v2 §8c).
        let standupNotes = """
        - Roundtable: Q3 draft, onboarding revision, perf regressions
        - Feedback due Friday
        """
        let standupEnhancedNotes = """
        ## Updates
        - Maya shipped the Q3 roadmap draft — feedback due **Friday**.
        - The onboarding revision still needs a second usability pass; Priya has two sessions booked this week.
        - Performance regressions on older laptops — Sam follows up with numbers next week.

        ## Action items
        - [ ] Sam shares performance regression numbers next week
        """
        return LibraryStore(
            fixtures: [
                record("Design sync — Q3 roadmap", now: now, hoursAgo: 0.5, duration: 1_453, attendees: ["Maya", "Sam", "Priya"], status: .transcribing(progress: 0.42)),
                record("Customer call — Meridian", now: now, hoursAgo: 3, duration: 1_800, attendees: ["Alex"], status: .queued),
                record("Budget review", now: now, hoursAgo: 4, duration: 1_320, attendees: ["Priya"], status: .needsModel),
                standup,
                record(
                    "1:1 with Sam", now: now, hoursAgo: 26, duration: 1_680, attendees: ["Sam"], status: .ready,
                    subtitle: "Promotion timeline agreed, mentorship pairing starts next sprint"
                ),
                record(
                    "Pricing brainstorm", now: now, hoursAgo: 30, duration: 2_400, attendees: ["Maya", "Alex", "Priya"], status: .ready,
                    subtitle: "Usage-based tier wins, enterprise floor set at 20 seats"
                ),
            ],
            transcripts: [standup.meeting.id: standupTranscript],
            notes: [standup.meeting.id: standupNotes],
            enhancedNotes: [standup.meeting.id: standupEnhancedNotes]
        )
    }

    // MARK: empty

    /// First-run/empty library: onboarding already complete (that's what
    /// `.ephemeralOnboarded()` on the settings side means), no meetings, no
    /// queue activity.
    @MainActor
    static func emptyLibrary() -> LibraryStore {
        LibraryStore(fixtures: [])
    }

    // MARK: busy

    /// 20+ meetings spread across many weeks with every status represented,
    /// several with transcripts + notes — exercises list grouping (by
    /// day/week sections) and scroll perf.
    @MainActor
    static func busyLibrary() -> LibraryStore {
        let now = Date.now
        let people = ["Maya", "Sam", "Priya", "Alex", "Jordan", "Rowan", "Casey", "Drew"]
        let titles = [
            "Weekly standup", "Design sync", "Customer call", "Budget review", "1:1", "Roadmap planning",
            "Retro", "Sprint demo", "Pricing brainstorm", "Onboarding review", "Incident postmortem",
            "Vendor check-in", "All-hands prep", "Hiring debrief", "Architecture review", "Support triage",
            "Marketing sync", "Board prep", "Partner call", "Offsite planning", "Q3 kickoff", "Security review",
        ]
        let statuses: [MeetingStatus] = [
            .ready, .ready, .ready, .queued, .transcribing(progress: 0.6), .needsModel,
            .error(message: "Transcription failed — model unavailable"), .ready,
        ]

        var meetings: [MeetingRecord] = []
        var transcripts: [UUID: Transcript] = [:]
        var notes: [UUID: String] = [:]
        var enhancedNotes: [UUID: String] = [:]

        for i in 0..<24 {
            let title = titles[i % titles.count]
            let status = statuses[i % statuses.count]
            let attendees = Array(people.shuffled().prefix(2 + i % 3))
            // Spread across ~10 weeks so grouping has many distinct buckets.
            let hoursAgo = Double(i) * 29 + Double(i % 5) * 3
            let rec = record(
                "\(title) #\(i + 1)", now: now, hoursAgo: hoursAgo, duration: TimeInterval(600 + (i % 6) * 420),
                attendees: attendees, status: status,
                subtitle: status == .ready ? "Notes captured, follow-ups assigned" : nil
            )
            meetings.append(rec)
            if status == .ready, i % 3 == 0 {
                transcripts[rec.meeting.id] = Transcript(
                    utterances: [
                        Utterance(speakerID: "S1", start: 0, end: 8, text: "Let's get started — quick rundown of where things stand."),
                        Utterance(speakerID: "S2", start: 8, end: 16, text: "On track. A couple of blockers to flag before we wrap."),
                    ],
                    engine: "fixture", model: "fixture", language: "en"
                )
                notes[rec.meeting.id] = "- Status update\n- Blockers flagged"
                enhancedNotes[rec.meeting.id] = "## Updates\n- Status is on track.\n\n## Action items\n- [ ] Follow up on blockers"
            }
        }

        return LibraryStore(
            fixtures: meetings,
            transcripts: transcripts,
            notes: notes,
            enhancedNotes: enhancedNotes
        )
    }

    // MARK: processing

    /// A queue mid-flight: several meetings actively in-progress/queued so
    /// the list's per-row progress states have real work to show.
    @MainActor
    static func processingLibrary() -> LibraryStore {
        let now = Date.now
        let meetings = [
            record("Design sync — Q3 roadmap", now: now, hoursAgo: 0.1, duration: 1_453, attendees: ["Maya", "Sam"], status: .transcribing(progress: 0.15)),
            record("Customer call — Meridian", now: now, hoursAgo: 0.3, duration: 1_800, attendees: ["Alex"], status: .transcribing(progress: 0.72)),
            record("Budget review", now: now, hoursAgo: 0.5, duration: 1_320, attendees: ["Priya"], status: .queued),
            record("1:1 with Sam", now: now, hoursAgo: 0.6, duration: 900, attendees: ["Sam"], status: .queued),
            record("Weekly standup", now: now, hoursAgo: 0.8, duration: 900, attendees: ["Maya", "Sam"], status: .enhancing),
            record(
                "Pricing brainstorm", now: now, hoursAgo: 24, duration: 2_400, attendees: ["Maya", "Alex", "Priya"], status: .ready,
                subtitle: "Usage-based tier wins, enterprise floor set at 20 seats"
            ),
        ]
        return LibraryStore(fixtures: meetings)
    }

    // MARK: error

    /// Failed/retry-able job states: a meeting with a genuinely failed
    /// transcription and one blocked on a missing model (recoverable).
    @MainActor
    static func errorLibrary() -> LibraryStore {
        let now = Date.now
        let meetings = [
            record(
                "Customer call — Meridian", now: now, hoursAgo: 1, duration: 1_800, attendees: ["Alex"],
                status: .error(message: "Transcription failed — audio file corrupted")
            ),
            record(
                "Budget review", now: now, hoursAgo: 2, duration: 1_320, attendees: ["Priya"],
                status: .error(message: "Enhancement failed — Apple Intelligence unavailable")
            ),
            record("Design sync — Q3 roadmap", now: now, hoursAgo: 3, duration: 1_453, attendees: ["Maya", "Sam"], status: .needsModel),
            record(
                "1:1 with Sam", now: now, hoursAgo: 26, duration: 1_680, attendees: ["Sam"], status: .ready,
                subtitle: "Promotion timeline agreed, mentorship pairing starts next sprint"
            ),
        ]
        return LibraryStore(fixtures: meetings)
    }

    // MARK: recovered

    /// A meeting recovered from a crash spool (`MeetingStatus.recovered`),
    /// alongside a couple of ordinary ready meetings today — proves the
    /// recovered row's special layout AND `MeetingGrouping`'s "recovered
    /// sorts to the top of Today" ordering render together correctly.
    @MainActor
    static func recoveredLibrary() -> LibraryStore {
        let now = Date.now
        let meetings = [
            record("Weekly standup", now: now, hoursAgo: 2, duration: 0, attendees: ["Maya", "Sam"], status: .recovered),
            record(
                "Design sync — Q3 roadmap", now: now, hoursAgo: 5, duration: 1_453, attendees: ["Maya", "Sam", "Priya"],
                status: .ready, subtitle: "Q3 draft shipped, onboarding usability pass assigned"
            ),
            record(
                "1:1 with Sam", now: now, hoursAgo: 26, duration: 1_680, attendees: ["Sam"], status: .ready,
                subtitle: "Promotion timeline agreed, mentorship pairing starts next sprint"
            ),
        ]
        return LibraryStore(fixtures: meetings)
    }

    // MARK: waitingForSetup

    /// Transcription setup (model download) in progress: meetings parked on
    /// `.needsModel` whose row copy is derived from
    /// `TranscriptionSetupStore.phase` — `AppStores` overrides that store's
    /// phase to `.downloading` for this scenario (there's no real download
    /// happening in fixture mode).
    @MainActor
    static func waitingForSetupLibrary() -> LibraryStore {
        let now = Date.now
        let meetings = [
            record("Design sync — Q3 roadmap", now: now, hoursAgo: 0.2, duration: 1_453, attendees: ["Maya", "Sam"], status: .needsModel),
            record("Customer call — Meridian", now: now, hoursAgo: 0.5, duration: 1_800, attendees: ["Alex"], status: .needsModel),
            record(
                "1:1 with Sam", now: now, hoursAgo: 24, duration: 1_680, attendees: ["Sam"], status: .ready,
                subtitle: "Promotion timeline agreed, mentorship pairing starts next sprint"
            ),
        ]
        return LibraryStore(fixtures: meetings)
    }

    // MARK: recording

    /// A `MeetingSessionStore` that looks mid-recording without touching any
    /// hardware — the `-fixtures recording` scenario's session graph, so
    /// `RecordingView` + the docked `SessionCapsule` (and, trivially, the
    /// `-show-menubar-content` recording popover) have something real to
    /// render for screenshots.
    ///
    /// Reuses the exact same synthetic-recorder seam the `-soak` launch mode
    /// already relies on (`SyntheticMicSource`/`SyntheticSystemAudioSource`
    /// feeding a real `MeetingRecorder`, see `AppStores.init(configuration:)`)
    /// rather than inventing a second one — no mic/system-audio TCC prompt,
    /// no real capture. `MeetingSessionStore.setLevelsForFixtures(_:)` then
    /// paints canned bars over the synthetic recorder's all-silence levels
    /// stream, so the meter isn't just a flat line in a screenshot, and a
    /// couple of timed notes are saved up front so the notes list isn't
    /// empty either.
    ///
    /// `AppStores`'s `.fixtures` graph is expected to call this (in place of
    /// a bare `MeetingSessionStore()`) whenever `scenario == .recording`,
    /// passing the same `library` it builds from `FixtureScenario.library`.
    @MainActor
    static func recordingSession(activeIn library: LibraryStore) -> MeetingSessionStore {
        let session = MeetingSessionStore(makeRecorder: {
            MeetingRecorder(mic: SyntheticMicSource(), makeSystemTap: { SyntheticSystemAudioSource() })
        })
        guard var record = library.startNewMeeting(title: "Design sync — Q3 roadmap", attendees: ["Maya", "Sam", "Priya"]) else {
            return session
        }
        // Fixture-mode `startNewMeeting` points every record at `/dev/null`
        // (no `LibraryStorage` to create a real folder) — fine for records
        // that never actually record, but `MeetingRecorder.start(writingTo:)`
        // needs a real, writable `audio.m4a` path to open an `AVAudioFile`
        // for. Same throwaway-temp-folder spirit as `FixtureAudio`/the
        // `-soak` graph's temp root, just without pre-filled audio content
        // since the (synthetic) recorder writes it live.
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapFixtureRecording-\(UUID().uuidString)", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)) != nil {
            record.folderURL = folderURL
        }
        Task { @MainActor in
            await session.start(record: record, engine: nil, includeSystemAudio: true, includeMic: true)
            session.setLevelsForFixtures([0.2, 0.55, 0.8, 0.35, 0.65, 0.3, 0.9, 0.45, 0.6, 0.25, 0.7, 0.4, 0.55, 0.3, 0.6, 0.35])
            library.addTimedNote("Follow up on Q3 roadmap numbers with Sam", at: 45, in: record)
            library.addTimedNote("Ask Priya about the onboarding usability pass timeline", at: 132, in: record)
        }
        return session
    }
}
