import Foundation

/// A desktop call app whose audio activity can signal "a meeting started"
/// (design mock 9b). Detection watches audio-activity *metadata* for these
/// bundle ids only — nothing is captured until the user records.
public struct CallApp: Identifiable, Hashable, Sendable {
    /// Canonical id — the primary bundle identifier. This is what
    /// `SettingsStore.disabledCallAppIDs` stores.
    public var id: String
    public var name: String
    /// Every bundle identifier this app ships under (e.g. Teams classic +
    /// new Teams), all mapping back to the one catalog entry.
    public var bundleIDs: [String]

    public init(id: String, name: String, bundleIDs: [String]) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
    }
}

/// The call apps Recap knows how to detect. Google Meet is absent
/// deliberately: it has no native macOS app, and flagging "a browser is
/// playing audio" would false-positive on every YouTube tab.
public enum CallAppCatalog {
    public static let apps: [CallApp] = [
        CallApp(id: "us.zoom.xos", name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        CallApp(
            id: "com.microsoft.teams2", name: "Microsoft Teams",
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]
        ),
        CallApp(id: "Cisco-Systems.Spark", name: "Webex", bundleIDs: ["Cisco-Systems.Spark"]),
        CallApp(id: "com.tinyspeck.slackmacgap", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        CallApp(id: "com.apple.FaceTime", name: "FaceTime", bundleIDs: ["com.apple.FaceTime"]),
        CallApp(id: "com.hammerandchisel.discord", name: "Discord", bundleIDs: ["com.hammerandchisel.discord"]),
    ]

    public static func app(forBundleID bundleID: String) -> CallApp? {
        apps.first { $0.bundleIDs.contains(bundleID) }
    }

    /// Bundle ids the audio monitor should watch, given the user's disabled
    /// set (which holds canonical `CallApp.id`s, not per-alias bundle ids).
    public static func enabledBundleIDs(disabledAppIDs: Set<String>) -> Set<String> {
        Set(apps.filter { !disabledAppIDs.contains($0.id) }.flatMap(\.bundleIDs))
    }
}
