import Foundation

// MARK: - Fixtures

extension LibraryStore {
    /// Sample library matching the states in design mock 1c. Equivalent to
    /// `FixtureScenario.default.library` — kept as a standalone entry point
    /// since it's the one every preview/test in this package already calls.
    /// See `FixtureScenarios.swift` for this and every other named
    /// `-fixtures <scenario>` graph.
    public static func fixture() -> LibraryStore {
        FixtureScenarios.defaultLibrary()
    }

    /// Fixture-only override for `rootUnreachable`, so the `rootUnreachable`
    /// `-fixtures` scenario can render the Library's "can't find your
    /// folder" banner without a real vanished folder behind it. Mirrors
    /// `BackupStatusStore.setStateForFixtures(_:)`'s pattern. No production
    /// graph calls this.
    public func setRootUnreachableForFixtures(_ value: Bool) {
        rootUnreachable = value
    }
}
