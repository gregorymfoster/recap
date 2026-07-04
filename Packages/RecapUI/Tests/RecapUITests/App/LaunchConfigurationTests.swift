import Foundation
import Testing

@testable import RecapUI

@Suite("LaunchConfiguration parsing")
struct LaunchConfigurationTests {
    // MARK: Mode

    @Test func noArgumentsIsNormal() {
        let config = LaunchConfiguration(arguments: [])
        #expect(config.mode == .normal)
        #expect(config.route == nil)
        #expect(config.seedDir == nil)
        #expect(!config.showMenuBarContent)
        #expect(!config.showNudge)
    }

    @Test func unknownArgumentsAreIgnored() {
        let config = LaunchConfiguration(arguments: ["-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "whatever"])
        #expect(config == LaunchConfiguration(arguments: []))
    }

    @Test func fixturesAloneIsDefaultScenario() {
        let config = LaunchConfiguration(arguments: ["-fixtures"])
        #expect(config.mode == .fixtures(scenario: "default"))
    }

    @Test func fixturesWithScenarioName() {
        let config = LaunchConfiguration(arguments: ["-fixtures", "empty-library"])
        #expect(config.mode == .fixtures(scenario: "empty-library"))
    }

    @Test func fixturesFollowedByFlagIsDefaultScenario() {
        let config = LaunchConfiguration(arguments: ["-fixtures", "-show-menubar-content"])
        #expect(config.mode == .fixtures(scenario: "default"))
        #expect(config.showMenuBarContent)
    }

    @Test func soakAlone() {
        #expect(LaunchConfiguration(arguments: ["-soak"]).mode == .soak)
    }

    @Test func soakWinsOverFixturesRegardlessOfOrder() {
        #expect(LaunchConfiguration(arguments: ["-fixtures", "-soak"]).mode == .soak)
        #expect(LaunchConfiguration(arguments: ["-soak", "-fixtures"]).mode == .soak)
        #expect(LaunchConfiguration(arguments: ["-soak", "-fixtures", "named"]).mode == .soak)
    }

    // MARK: Debug-window flags

    @Test func showMenuBarContentFlag() {
        let config = LaunchConfiguration(arguments: ["-fixtures", "-show-menubar-content"])
        #expect(config.showMenuBarContent)
        #expect(config.opensMenuBarContentWindow)
    }

    @Test func showNudgeFlag() {
        let config = LaunchConfiguration(arguments: ["-fixtures", "-show-nudge"])
        #expect(config.showNudge)
        #expect(config.opensNudgePreviewWindow)
    }

    @Test func nudgePreviewRequiresFixtures() {
        // `-show-nudge` without `-fixtures` parses the flag but must not
        // open the debug window over a real library.
        let config = LaunchConfiguration(arguments: ["-show-nudge"])
        #expect(config.showNudge)
        #expect(!config.opensNudgePreviewWindow)
        #expect(!LaunchConfiguration(arguments: ["-soak", "-show-nudge"]).opensNudgePreviewWindow)
    }

    @Test func menuBarContentWindowDoesNotRequireFixtures() {
        // ui-smoke passes `-fixtures -show-menubar-content`, but the window
        // itself has never been fixtures-gated — preserve that.
        #expect(LaunchConfiguration(arguments: ["-show-menubar-content"]).opensMenuBarContentWindow)
    }

    // MARK: Window restoration

    @Test func onlyNormalModeRestoresWindowState() {
        #expect(LaunchConfiguration(arguments: []).restoresWindowState)
        #expect(!LaunchConfiguration(arguments: ["-fixtures"]).restoresWindowState)
        #expect(!LaunchConfiguration(arguments: ["-fixtures", "named"]).restoresWindowState)
        #expect(!LaunchConfiguration(arguments: ["-soak"]).restoresWindowState)
    }

    // MARK: -open route

    @Test func openLibrary() {
        #expect(LaunchConfiguration(arguments: ["-open", "library"]).route == .library(meetingID: nil))
    }

    @Test func openLibraryWithMeetingID() {
        let config = LaunchConfiguration(arguments: ["-open", "library/9C2A"])
        #expect(config.route == .library(meetingID: "9C2A"))
    }

    @Test func openSettings() {
        #expect(LaunchConfiguration(arguments: ["-open", "settings"]).route == .settings(tab: nil))
    }

    @Test func openSettingsWithTab() {
        #expect(LaunchConfiguration(arguments: ["-open", "settings/models"]).route == .settings(tab: "models"))
    }

    @Test func openSearch() {
        #expect(LaunchConfiguration(arguments: ["-open", "search:budget sync"]).route == .search(query: "budget sync"))
    }

    @Test func openWithMissingValueIsIgnored() {
        #expect(LaunchConfiguration(arguments: ["-open"]).route == nil)
        // A following flag is not a route value.
        let config = LaunchConfiguration(arguments: ["-open", "-fixtures"])
        #expect(config.route == nil)
        #expect(config.mode == .fixtures(scenario: "default"))
    }

    @Test func malformedRoutesParseAsNil() {
        for bad in ["", "libary", "library/", "library/a/b", "settings/", "search:", "meeting/123"] {
            #expect(LaunchConfiguration(arguments: ["-open", bad]).route == nil, "\(bad) should not parse")
        }
    }

    // MARK: Route(parsing:) directly

    @Test func routeParsingAllForms() {
        #expect(Route(parsing: "library") == .library(meetingID: nil))
        #expect(Route(parsing: "library/abc") == .library(meetingID: "abc"))
        #expect(Route(parsing: "settings") == .settings(tab: nil))
        #expect(Route(parsing: "settings/general") == .settings(tab: "general"))
        #expect(Route(parsing: "search:q") == .search(query: "q"))
        #expect(Route(parsing: "search:has:colons") == .search(query: "has:colons"))
    }

    @Test func routeParsingRejectsMalformed() {
        #expect(Route(parsing: "") == nil)
        #expect(Route(parsing: "search:") == nil)
        #expect(Route(parsing: "library/") == nil)
        #expect(Route(parsing: "settings/a/b") == nil)
        #expect(Route(parsing: "unknown") == nil)
        #expect(Route(parsing: "/library") == nil)
    }

    // MARK: -seed-dir

    @Test func seedDirParsesToFileURL() {
        let config = LaunchConfiguration(arguments: ["-seed-dir", "/tmp/seed"])
        #expect(config.seedDir == URL(fileURLWithPath: "/tmp/seed"))
    }

    @Test func seedDirMissingValueIsNil() {
        #expect(LaunchConfiguration(arguments: ["-seed-dir"]).seedDir == nil)
        #expect(LaunchConfiguration(arguments: ["-seed-dir", "-fixtures"]).seedDir == nil)
    }

    // MARK: Combinations

    @Test func everythingAtOnce() {
        let config = LaunchConfiguration(arguments: [
            "-fixtures", "two-speaker", "-show-menubar-content", "-show-nudge",
            "-open", "settings/models", "-seed-dir", "/tmp/seed", "-junk",
        ])
        #expect(config.mode == .fixtures(scenario: "two-speaker"))
        #expect(config.showMenuBarContent)
        #expect(config.showNudge)
        #expect(config.opensNudgePreviewWindow)
        #expect(config.route == .settings(tab: "models"))
        #expect(config.seedDir == URL(fileURLWithPath: "/tmp/seed"))
        #expect(!config.restoresWindowState)
    }

    @Test func scenarioValueIsNotSwallowedByOtherFlags() {
        // `-fixtures` must not consume `-open`'s value or vice versa.
        let config = LaunchConfiguration(arguments: ["-open", "library", "-fixtures", "-soak"])
        #expect(config.route == .library(meetingID: nil))
        #expect(config.mode == .soak)
    }
}
