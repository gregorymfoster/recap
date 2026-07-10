import Foundation

/// Pure title-display logic for a recovered (crash-salvaged) meeting row
/// (`LibraryView.recoveredRow`). A recovered meeting's real title is shown
/// whenever it has one; an empty title or the meaningless placeholder new
/// recordings start with (`"Untitled meeting"`, see `AppStores.startRecording`
/// / `RecordingController.startRecording`) is swapped for the literal
/// "Recovered recording" so the row never reads as a blank or generic title.
public enum RecoveredRowTitle {
    static let placeholderTitle = "Untitled meeting"
    static let fallback = "Recovered recording"

    public static func display(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == placeholderTitle {
            return fallback
        }
        return title
    }
}
