import Foundation

/// Whether this process is the dev-variant build (bundle id suffix ".dev").
/// Debug builds ship as "Recap Dev" (com.gregfoster.recap.dev) so a laptop
/// can run a prod install and a dev build with fully separate TCC grants,
/// UserDefaults, meetings folder, and search index.
public enum AppIdentity {
    public static var isDevBuild: Bool { isDev(bundleIdentifier: Bundle.main.bundleIdentifier) }

    /// Pure, testable core.
    static func isDev(bundleIdentifier: String?) -> Bool { bundleIdentifier?.hasSuffix(".dev") == true }
}
