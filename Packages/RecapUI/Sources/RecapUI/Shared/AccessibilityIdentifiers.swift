import SwiftUI

/// Stable accessibility identifiers for agent-driven UI automation (AX tree).
/// Add per-feature IDs in an `AXID+<Feature>.swift` extension file inside that
/// feature's folder — never raw strings at the call site.
///
/// Naming convention: raw strings are kebab-case. Non-global IDs are prefixed
/// by feature (e.g. "settings-general-tab", "recording-stop-button"). Dynamic
/// rows use a stable prefix plus a stable id suffix — see `meetingRow(_:)`
/// below for the pattern.
public struct AXID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

extension View {
    /// Tags this view in the accessibility tree so ax-probe / UI automation
    /// can find it regardless of layout or copy changes.
    public func axID(_ id: AXID) -> some View {
        accessibilityIdentifier(id.raw)
    }

    /// Conditional form for repeated rows where only selected items expose a
    /// stable automation target.
    @ViewBuilder public func axID(_ id: AXID?) -> some View {
        if let id {
            accessibilityIdentifier(id.raw)
        } else {
            self
        }
    }
}

// MARK: - Global anchors

/// App-global anchors used across features. Per-feature IDs belong in an
/// `AXID+<Feature>.swift` file inside that feature's folder instead.
extension AXID {
    /// The main sidebar navigation list (`Sidebar`).
    public static let sidebar = AXID("sidebar")

    /// The Library screen's meeting list container (`LibraryView`).
    public static let libraryList = AXID("library-list")

    /// The Library toolbar's search entry point, which opens the ⌘K search
    /// overlay (`LibraryView.searchField`).
    public static let searchField = AXID("search-field")
    /// Sidebar's Models navigation row.
    public static let sidebarModels = AXID("sidebar-models")

    /// The menu bar extra's popover content root (`MenuBarContent`).
    public static let menuBarContent = AXID("menu-bar-content")

    /// A single row in the library meeting list, keyed by a stable id (e.g.
    /// the meeting's own id) rather than title/position so automation
    /// survives renames and reordering.
    public static func meetingRow(_ id: String) -> AXID { AXID("meeting-row-\(id)") }
}
