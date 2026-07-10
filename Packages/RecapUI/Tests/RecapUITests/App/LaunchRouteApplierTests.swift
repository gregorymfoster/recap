import Foundation
import Testing

@testable import RecapUI

@Suite("LaunchRouteAction.actions(for:resolveMeetingID:)")
struct LaunchRouteActionTests {
    @Test func nilRouteProducesNoActions() {
        #expect(LaunchRouteAction.actions(for: nil, resolveMeetingID: { _ in nil }) == [])
    }

    @Test func libraryWithNoMeetingIDShowsLibrary() {
        let actions = LaunchRouteAction.actions(for: .library(meetingID: nil), resolveMeetingID: { _ in nil })
        #expect(actions == [.showLibrary])
    }

    @Test func libraryWithResolvableMeetingIDSelectsIt() {
        let actions = LaunchRouteAction.actions(
            for: .library(meetingID: "abc"),
            resolveMeetingID: { raw in raw == "abc" ? "resolved-id" : nil }
        )
        #expect(actions == [.selectMeeting(id: "resolved-id")])
    }

    @Test func libraryWithUnresolvableMeetingIDFallsBackToShowLibrary() {
        let actions = LaunchRouteAction.actions(for: .library(meetingID: "missing"), resolveMeetingID: { _ in nil })
        #expect(actions == [.showLibrary])
    }

    @Test func settingsWithNoTabOpensSettingsWithNilSection() {
        let actions = LaunchRouteAction.actions(for: .settings(tab: nil), resolveMeetingID: { _ in nil })
        #expect(actions == [.openSettings(section: nil)])
    }

    @Test func settingsWithKnownTabOpensMappedSection() {
        let actions = LaunchRouteAction.actions(for: .settings(tab: "recording"), resolveMeetingID: { _ in nil })
        #expect(actions == [.openSettings(section: .audio)])
    }

    @Test func settingsWithUnknownTabOpensSettingsWithNilSection() {
        let actions = LaunchRouteAction.actions(for: .settings(tab: "nonexistent"), resolveMeetingID: { _ in nil })
        #expect(actions == [.openSettings(section: nil)])
    }

    @Test func allLegacyTabNamesMapToASection() {
        let expected: [String: AppRouter.SettingsSection] = [
            "general": .audio,
            "recording": .audio,
            "calendar": .audio,
            "privacy": .audio,
            "sync": .storage,
        ]
        for (tab, section) in expected {
            let actions = LaunchRouteAction.actions(for: .settings(tab: tab), resolveMeetingID: { _ in nil })
            #expect(actions == [.openSettings(section: section)])
        }
    }

    @Test func searchOpensOverlayWithQuery() {
        let actions = LaunchRouteAction.actions(for: .search(query: "standup"), resolveMeetingID: { _ in nil })
        #expect(actions == [.openSearch(query: "standup")])
    }
}

@Suite("LaunchRouteApplier single-shot application")
struct LaunchRouteApplierTests {
    @Test func nilRouteNeverProducesActions() {
        var applier = LaunchRouteApplier(route: nil)
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
    }

    @Test func appliesExactlyOnce() {
        var applier = LaunchRouteApplier(route: .library(meetingID: nil))
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [.showLibrary])
        // A second call (e.g. `.task` re-running) must be a no-op.
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
    }

    @Test func appliesSettingsRouteOnce() {
        var applier = LaunchRouteApplier(route: .settings(tab: "sync"))
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [.openSettings(section: .storage)])
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
    }

    @Test func appliesSearchRouteOnce() {
        var applier = LaunchRouteApplier(route: .search(query: "q"))
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [.openSearch(query: "q")])
        #expect(applier.applyOnce(resolveMeetingID: { _ in nil }) == [])
    }
}

@Suite("AppRouter.SettingsSection route-tab-name mapping")
struct SettingsSectionRouteTabNameTests {
    @Test func legacyTabNamesMapToSections() {
        #expect(AppRouter.SettingsSection(routeTabName: "general") == .audio)
        #expect(AppRouter.SettingsSection(routeTabName: "recording") == .audio)
        #expect(AppRouter.SettingsSection(routeTabName: "calendar") == .audio)
        #expect(AppRouter.SettingsSection(routeTabName: "privacy") == .audio)
        #expect(AppRouter.SettingsSection(routeTabName: "sync") == .storage)
    }

    @Test func nilOrUnknownTabNameMapsToNil() {
        #expect(AppRouter.SettingsSection(routeTabName: nil) == nil)
        #expect(AppRouter.SettingsSection(routeTabName: "nonexistent") == nil)
    }
}

@Suite("LaunchRouteMeetingResolver")
struct LaunchRouteMeetingResolverTests {
    @Test func firstAliasResolvesToFirstMeetingID() {
        let ids = ["id-1", "id-2", "id-3"]
        #expect(LaunchRouteMeetingResolver.resolve("first", meetingIDs: ids) == "id-1")
    }

    @Test func firstAliasWithEmptyLibraryResolvesToNil() {
        #expect(LaunchRouteMeetingResolver.resolve("first", meetingIDs: []) == nil)
    }

    @Test func exactUUIDMatchResolves() {
        let ids = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]
        #expect(LaunchRouteMeetingResolver.resolve("22222222-2222-2222-2222-222222222222", meetingIDs: ids) == ids[1])
    }

    @Test func matchIsCaseInsensitive() {
        let ids = ["ABCDEFAB-1111-1111-1111-111111111111"]
        #expect(LaunchRouteMeetingResolver.resolve("abcdefab-1111-1111-1111-111111111111", meetingIDs: ids) == ids[0])
    }

    @Test func unknownIDResolvesToNil() {
        let ids = ["11111111-1111-1111-1111-111111111111"]
        #expect(LaunchRouteMeetingResolver.resolve("does-not-exist", meetingIDs: ids) == nil)
    }
}
