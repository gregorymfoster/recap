import Foundation

/// Pure decision logic for `-open <route>`: given the parsed `Route` and the
/// bit of store state a decision depends on, what actions should run. Kept
/// framework-free (no SwiftUI, no `AppStores`) so it's directly unit
/// testable — the house pattern of extracting pure logic out of
/// framework-coupled types. `RootView`'s `.task` glue calls this once and
/// executes whatever actions come back; see `LaunchRouteApplier` below for
/// the thin stateful wrapper that makes application idempotent/single-shot.
public enum LaunchRouteAction: Equatable, Sendable {
    /// Select the Library section with no meeting open (`route == .library(nil)`
    /// or a `library/<id>` route whose id didn't resolve to a meeting).
    case showLibrary
    /// Select the Library section and open one meeting.
    case selectMeeting(id: String)
    /// Open the Settings window, optionally preselecting a tab. `tab == nil`
    /// when the route didn't name one, or named one that doesn't exist.
    case openSettings(tab: SettingsTab?)
    /// Open the ⌘K search overlay prefilled with `query` and focus it.
    case openSearch(query: String)

    /// Pure translation of a parsed `Route` into the actions that apply it.
    /// `resolveMeetingID` maps a route's raw meeting-id string (fixture IDs
    /// are random UUIDs per launch, so `-open library/first` is a stable
    /// alias — see `LaunchConfiguration`'s doc comment) to a real meeting id
    /// drawn from current store state; returning `nil` falls back to
    /// `.showLibrary` rather than silently doing nothing, so a stale/unknown
    /// id still lands the user somewhere sensible.
    public static func actions(
        for route: Route?,
        resolveMeetingID: (String) -> String?
    ) -> [LaunchRouteAction] {
        guard let route else { return [] }
        switch route {
        case .library(meetingID: nil):
            return [.showLibrary]
        case .library(meetingID: let rawID?):
            if let resolved = resolveMeetingID(rawID) {
                return [.selectMeeting(id: resolved)]
            }
            return [.showLibrary]
        case .settings(tab: let rawTab):
            return [.openSettings(tab: rawTab.flatMap(SettingsTab.init(rawValue:)))]
        case .search(query: let query):
            return [.openSearch(query: query)]
        }
    }
}

/// Which Settings tab to preselect. Raw values are the `-open settings/<tab>`
/// route's tab names (lowercase, matching the tab labels) — see
/// `SettingsWindowView`'s `TabView(selection:)`.
public enum SettingsTab: String, Equatable, Sendable, CaseIterable {
    case general
    case recording
    case calendar
    case sync
    case privacy
}

/// Single-shot application of `-open <route>` to a `LibraryStore` id lookup,
/// so `AppStores.launchRoute` gets applied exactly once even though
/// `RootView`'s `.task` can in principle re-run (e.g. view identity churn).
/// Not `@MainActor`/`@Observable` — it's plain state guarding a pure
/// decision, driven from `RootView`'s `.task` which is already on the
/// main actor.
public struct LaunchRouteApplier {
    private var applied = false
    public let route: Route?

    public init(route: Route?) {
        self.route = route
    }

    /// Returns the actions to run the first time this is called, and `[]`
    /// every time after — callers don't need their own "have I run yet"
    /// bookkeeping.
    public mutating func applyOnce(resolveMeetingID: (String) -> String?) -> [LaunchRouteAction] {
        guard !applied, route != nil else { return [] }
        applied = true
        return LaunchRouteAction.actions(for: route, resolveMeetingID: resolveMeetingID)
    }
}

/// Resolves `-open library/<id>` route values against a library's current
/// meetings: real ids match a `MeetingRecord.meeting.id.uuidString` (case
/// insensitive is intentionally NOT applied — ids are canonical
/// `UUID.uuidString`s) exactly; the literal alias `"first"` is a stable
/// stand-in for the first fixture meeting, since fixture meeting ids are
/// random `UUID()`s generated fresh every launch and so aren't usable
/// directly from a fixed `-open` invocation (see `LibraryStore.fixture()`
/// and `Meeting.init(id:)`'s default).
public enum LaunchRouteMeetingResolver {
    public static func resolve(_ rawID: String, meetingIDs: [String]) -> String? {
        if rawID == "first" {
            return meetingIDs.first
        }
        return meetingIDs.first { $0.caseInsensitiveCompare(rawID) == .orderedSame }
    }
}
