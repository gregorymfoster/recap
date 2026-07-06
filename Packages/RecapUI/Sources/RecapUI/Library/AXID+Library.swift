import Foundation

/// Accessibility identifiers for the Library feature (meeting list, meeting
/// detail, transcript pane, search). See `AXID+Library.swift`'s siblings for
/// the global anchors (`.sidebar`, `.libraryList`, `.searchField`,
/// `.meetingRow(_:)`) already defined in `Shared/AccessibilityIdentifiers.swift`.
extension AXID {
    // MARK: Library toolbar

    /// The Library window toolbar's Record button (`LibraryView.recordButton`).
    public static let libraryRecordButton = AXID("library-record-button")

    /// The Library toolbar's sort/filter menu (`LibraryView.sortFilterMenu`).
    public static let librarySortFilterMenu = AXID("library-sort-filter-menu")

    // MARK: Library row context menu actions

    /// "Open" row context menu item (`LibraryView.rowContextMenu`).
    public static let libraryRowOpen = AXID("library-row-open")

    /// "Copy notes as Markdown" row context menu item.
    public static let libraryRowCopyNotes = AXID("library-row-copy-notes")

    /// "Reveal in Finder" row context menu item.
    public static let libraryRowReveal = AXID("library-row-reveal")

    /// "Rename…" row context menu item.
    public static let libraryRowRename = AXID("library-row-rename")

    /// "Re-transcribe" row context menu item. Also reused for the inline
    /// "Retry" link shown on a failed row's status (`MeetingStatusView`) —
    /// both trigger the same retranscribe action.
    public static let libraryRowRetranscribe = AXID("library-row-retranscribe")

    /// "Install model to transcribe" chip on a row needing a model
    /// (`MeetingStatusView.needsModelChip`).
    public static let rowInstallModelButton = AXID("library-row-install-model-button")

    /// "Move to Trash" row context menu item.
    public static let libraryRowTrash = AXID("library-row-trash")

    /// The rename alert's title text field (`RenameSheetModifier`).
    public static let libraryRenameField = AXID("library-rename-field")

    /// The rename alert's confirm button.
    public static let libraryRenameConfirm = AXID("library-rename-confirm")

    // MARK: Meeting detail

    /// The meeting detail editor pane container (notes/enhanced notes),
    /// left side of the split view (`MeetingDetailView.editor`).
    public static let detailPane = AXID("library-detail-pane")

    /// The transcript inspector pane container, right side of the split view
    /// when visible (`TranscriptPane`).
    public static let transcriptPane = AXID("library-transcript-pane")

    /// The enhanced-notes read-only rendering (`EnhancedNotesView`).
    public static let enhancedNotesView = AXID("library-enhanced-notes-view")

    /// The raw notes `TextEditor` (`MeetingDetailView.editor`).
    public static let notesEditor = AXID("library-notes-editor")

    /// Segmented "✨ Enhanced / My notes" toggle (`MeetingDetailView.notesModeToggle`).
    public static let notesModeToggle = AXID("library-notes-mode-toggle")

    /// "Undo" link in the enhanced-notes caption, switches back to My notes.
    public static let enhancedNotesUndoButton = AXID("library-enhanced-notes-undo-button")

    /// Toolbar "Copy notes"/"Copy summary" button (`MeetingDetailView.copyNotesButton`).
    public static let detailCopyNotesButton = AXID("library-detail-copy-notes-button")

    /// Toolbar transcript show/hide toggle (`MeetingDetailView.transcriptToggle`).
    public static let transcriptToggleButton = AXID("library-transcript-toggle-button")

    /// Live-meeting input-device picker (`MeetingDetailView.liveInputRow`).
    public static let liveInputDevicePicker = AXID("library-live-input-device-picker")

    /// The read-only detail-view title text (`MeetingDetailView.titleText`).
    /// Double-click reveals `.detailTitleField` for inline rename.
    public static let detailTitleText = AXID("library-detail-title-text")

    /// The detail-view title's inline rename `TextField`, shown in place of
    /// `.detailTitleText` while editing (`MeetingDetailView.titleText`).
    public static let detailTitleField = AXID("library-detail-title-field")

    // MARK: Player bar

    /// The player bar container docked at the bottom of the detail view
    /// (`PlayerBar`).
    public static let playerBar = AXID("library-player-bar")

    /// Play/pause button (`PlayerBar.playPauseButton`).
    public static let playerPlayPauseButton = AXID("library-player-play-pause-button")

    /// Scrubber slider (`PlayerBar` body).
    public static let playerScrubber = AXID("library-player-scrubber")

    /// Playback-rate cycling chip (`PlayerBar.rateChip`).
    public static let playerRateChip = AXID("library-player-rate-chip")

    // MARK: Transcript pane

    /// "Copy transcript" button in the transcript pane header.
    public static let transcriptCopyButton = AXID("library-transcript-copy-button")

    /// "Download" button shown when no streaming model is installed
    /// (`TranscriptPane.emptyState`).
    public static let transcriptDownloadModelButton = AXID("library-transcript-download-model-button")

    /// A speaker name label in a transcript row, keyed by the diarization
    /// speaker id (e.g. "S1") — tap opens the rename popover.
    public static func transcriptSpeakerLabel(_ speakerID: String) -> AXID {
        AXID("library-transcript-speaker-label-\(speakerID)")
    }

    /// The rename-speaker popover's text field.
    public static let transcriptSpeakerRenameField = AXID("library-transcript-speaker-rename-field")

    /// The rename-speaker popover's confirm button.
    public static let transcriptSpeakerRenameConfirm = AXID("library-transcript-speaker-rename-confirm")

    // MARK: Search

    /// The ⌘K search overlay's container (`SearchOverlay`).
    public static let searchOverlay = AXID("library-search-overlay")

    /// The search overlay's text field.
    public static let searchOverlayField = AXID("library-search-overlay-field")

    /// A single search result row, keyed by the hit's stable id.
    public static func searchHitRow(_ id: String) -> AXID { AXID("library-search-hit-row-\(id)") }

    // MARK: Upcoming section

    /// A single Upcoming (calendar) row's Record button, keyed by the
    /// event's stable id.
    public static func upcomingRecordButton(_ id: String) -> AXID {
        AXID("library-upcoming-record-button-\(id)")
    }
}
