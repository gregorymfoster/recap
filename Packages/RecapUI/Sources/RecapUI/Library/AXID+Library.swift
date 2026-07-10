import Foundation
import RecapCore

/// Accessibility identifiers for the Library feature (meeting list, meeting
/// detail, transcript pane, search). See this file's siblings for the global
/// anchors (`.libraryList`, `.searchField`, `.meetingRow(_:)`) already
/// defined in `Shared/AccessibilityIdentifiers.swift`.
extension AXID {
    // MARK: Library toolbar

    /// The Library window toolbar's Record button (`LibraryView.recordButton`).
    public static let libraryRecordButton = AXID("library-record-button")

    /// The Library window toolbar's "Recording · MM:SS" pill, shown instead
    /// of `.libraryRecordButton` while a recording is in progress
    /// (`LibraryView.recordingIndicatorButton`).
    public static let libraryRecordingIndicatorButton = AXID("library-recording-indicator-button")

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

    /// The read-only detail-view title text (`MeetingDetailView.titleText`).
    /// Double-click reveals `.detailTitleField` for inline rename.
    public static let detailTitleText = AXID("library-detail-title-text")

    /// The detail-view title's inline rename `TextField`, shown in place of
    /// `.detailTitleText` while editing (`MeetingDetailView.titleText`).
    public static let detailTitleField = AXID("library-detail-title-field")
    /// Persistent recovery card shown for a completed meeting with one or
    /// more recoverable pipeline/export issues.
    public static let processingIssueCard = AXID("library-processing-issue-card")
    public static func processingIssueRetryButton(_ issue: ProcessingIssue) -> AXID {
        AXID("library-processing-issue-retry-\(issue.rawValue)")
    }
    public static func processingIssueCopyCodeButton(_ issue: ProcessingIssue) -> AXID {
        AXID("library-processing-issue-copy-code-\(issue.rawValue)")
    }

    // MARK: Transcript pane

    /// "Copy transcript" button in the transcript pane header.
    public static let transcriptCopyButton = AXID("library-transcript-copy-button")

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

    // MARK: Library footer, banner, and detail edge states

    /// The Library window's footer (backup status + related affordances).
    public static let libraryFooter = AXID("library-footer")

    /// The Library footer's backup-status summary.
    public static let libraryBackupStatus = AXID("library-backup-status")

    /// "Fix backup" link shown in the footer when backups are stuck.
    public static let libraryFixBackupLink = AXID("library-fix-backup-link")

    /// The "next meeting starting soon" banner above the Library list.
    public static let nextMeetingBanner = AXID("library-next-meeting-banner")

    /// The next-meeting banner's Record button.
    public static let bannerRecordButton = AXID("library-banner-record-button")

    /// Meeting detail's "backed up" status indicator.
    public static let detailBackedUpStatus = AXID("library-detail-backed-up-status")

    /// The collapsible summary/notes disclosure in meeting detail.
    public static let summaryDisclosure = AXID("library-summary-disclosure")

    /// The meeting detail loading skeleton, shown before content is ready.
    public static let detailSkeleton = AXID("library-detail-skeleton")
}
