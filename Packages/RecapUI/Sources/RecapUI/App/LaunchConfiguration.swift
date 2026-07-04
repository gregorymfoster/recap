import Foundation

/// Pure, testable parse of the app's launch arguments — the single place the
/// launch-argument grammar is defined. The app shell parses `CommandLine`
/// exactly once and hands the result to `AppStores`/scenes; nothing in this
/// type touches `ProcessInfo` (house rule: launch args only, and the value
/// type stays a pure function of its input).
///
/// Grammar (unknown arguments are ignored):
/// - `-fixtures` — fixture graph, scenario "default".
/// - `-fixtures <name>` — fixture graph with a named scenario, when the next
///   argument doesn't start with "-". Only "default" behavior exists today;
///   the scenario string is carried for the fixture-scenarios work.
/// - `-soak` — soak-test graph. Wins over `-fixtures` when both are passed
///   (soak is driven by `Scripts/soak-test.sh` and must never silently run
///   the fixtures graph instead — a soak sample of fixture data would be
///   meaningless).
/// - `-open <route>` — parsed into `route` and applied once at launch by
///   `RootView`/`LaunchRouteApplier` after the store graph and main window
///   exist.
/// - `-seed-dir <path>` — parsed into `seedDir` but not yet consumed
///   (seeded-state sibling work consumes it).
/// - `-show-menubar-content` — open the menu-bar-content debug window.
/// - `-show-nudge` — open the nudge-preview debug window (fixtures only; see
///   `opensNudgePreviewWindow`).
public struct LaunchConfiguration: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case normal
        case fixtures(scenario: String)
        case soak
    }

    public var mode: Mode
    /// Parsed from `-open <route>`. Inert for now — not yet applied anywhere.
    public var route: Route?
    /// Parsed from `-seed-dir <path>`. Inert for now — not yet consumed.
    public var seedDir: URL?
    public var showMenuBarContent: Bool
    public var showNudge: Bool

    /// Parses launch arguments (without the executable path, i.e.
    /// `CommandLine.arguments.dropFirst()` — a leading executable path is
    /// harmless either way since unknown arguments are ignored).
    public init(arguments: [String]) {
        var mode: Mode = .normal
        var sawSoak = false
        var route: Route?
        var seedDir: URL?
        var showMenuBarContent = false
        var showNudge = false

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            /// The next argument, when it exists and is a value rather than
            /// another flag. Consuming it advances past it.
            func valueArgument() -> String? {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return nil }
                index = next
                return arguments[next]
            }
            switch argument {
            case "-fixtures":
                let scenario = valueArgument() ?? "default"
                if !sawSoak { mode = .fixtures(scenario: scenario) }
            case "-soak":
                sawSoak = true
                mode = .soak
            case "-open":
                if let value = valueArgument() {
                    route = Route(parsing: value)
                }
            case "-seed-dir":
                if let value = valueArgument() {
                    seedDir = URL(fileURLWithPath: value)
                }
            case "-show-menubar-content":
                showMenuBarContent = true
            case "-show-nudge":
                showNudge = true
            default:
                break  // Unknown arguments (including system/Xcode ones) are ignored.
            }
            index = arguments.index(after: index)
        }

        self.mode = mode
        self.route = route
        self.seedDir = seedDir
        self.showMenuBarContent = showMenuBarContent
        self.showNudge = showNudge
    }

    // MARK: Derived launch decisions (pure, so they're testable)

    /// Whether the nudge-preview debug window should open at launch:
    /// `-show-nudge` is a fixtures-only debug hook (the window stacks
    /// fixture nudge states; it must never appear over a real library).
    public var opensNudgePreviewWindow: Bool {
        if case .fixtures = mode { return showNudge }
        return false
    }

    /// Whether the menu-bar-content debug window should open at launch.
    public var opensMenuBarContentWindow: Bool { showMenuBarContent }

    /// Whether SwiftUI scene restoration should run. Fixtures and soak
    /// launches must always boot into a deterministic single-window state —
    /// restoring stale window state from a prior (possibly normal-mode)
    /// launch would resurrect stray debug/duplicate windows over fixture
    /// data.
    public var restoresWindowState: Bool { mode == .normal }
}

/// A launch route parsed from `-open <route>`, carried on
/// `AppStores.launchRoute` and applied once by `RootView` via
/// `LaunchRouteApplier`/`LaunchRouteAction`.
///
/// Forms: `library`, `library/<meeting-id>` (fixture meeting ids are random
/// per launch — `library/first` is a stable alias for the first meeting in
/// `-fixtures` mode), `settings`, `settings/<tab>` (tab names match
/// `SettingsTab`'s raw values: general/recording/calendar/sync/privacy),
/// `search:<query>`. Anything else (including empty path/query components)
/// fails the parse.
public enum Route: Equatable, Sendable {
    case library(meetingID: String?)
    case settings(tab: String?)
    case search(query: String)

    public init?(parsing string: String) {
        if string.hasPrefix("search:") {
            let query = String(string.dropFirst("search:".count))
            guard !query.isEmpty else { return nil }
            self = .search(query: query)
            return
        }
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let detail: String?
        if parts.count == 2 {
            guard !parts[1].isEmpty, !parts[1].contains("/") else { return nil }
            detail = String(parts[1])
        } else {
            detail = nil
        }
        switch parts.first {
        case "library": self = .library(meetingID: detail)
        case "settings": self = .settings(tab: detail)
        default: return nil
        }
    }
}
