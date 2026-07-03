import CoreGraphics
import Foundation
import Testing
@testable import RecapUI

@MainActor
@Suite struct FloatingIndicatorPositionStoreTests {
    static func ephemeralSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: "recap.tests.floatingindicatorposition")!
        suite.removePersistentDomain(forName: "recap.tests.floatingindicatorposition")
        return suite
    }

    @Test func defaultsToNilWhenNeverSet() {
        let store = FloatingIndicatorPositionStore(defaults: Self.ephemeralSuite())
        #expect(store.position == nil)
    }

    @Test func roundTripsThroughUserDefaults() {
        let defaults = Self.ephemeralSuite()
        let store = FloatingIndicatorPositionStore(defaults: defaults)
        store.position = CGPoint(x: 1200, y: 40)

        let reopened = FloatingIndicatorPositionStore(defaults: defaults)
        #expect(reopened.position == CGPoint(x: 1200, y: 40))
    }

    @Test func settingBackToNilRemovesBothStoredKeys() {
        let defaults = Self.ephemeralSuite()
        let store = FloatingIndicatorPositionStore(defaults: defaults)
        store.position = CGPoint(x: 1200, y: 40)
        store.position = nil

        #expect(defaults.object(forKey: "floatingCapsulePositionX") == nil)
        #expect(defaults.object(forKey: "floatingCapsulePositionY") == nil)
        let reopened = FloatingIndicatorPositionStore(defaults: defaults)
        #expect(reopened.position == nil)
    }

    /// Only one of the two keys present (e.g. an interrupted write) must not
    /// synthesize a half-valid point.
    @Test func partiallyWrittenKeysReadAsNil() {
        let defaults = Self.ephemeralSuite()
        defaults.set(1200.0, forKey: "floatingCapsulePositionX")
        let store = FloatingIndicatorPositionStore(defaults: defaults)
        #expect(store.position == nil)
    }
}
