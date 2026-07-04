import CoreGraphics
import Foundation

/// Persists the floating capsule's dragged position across launches.
/// `SettingsStore` is a different agent's owned file, so this is a small
/// standalone UserDefaults-backed store dedicated to the one CGPoint, using
/// the same flat-key/optional convention as `SettingsStore`'s other
/// UserDefaults-backed properties (see `preferredInputUID`): two `Double`
/// keys, `nil` when either is missing, `removeObject` to reset.
@MainActor
public final class FloatingIndicatorPositionStore {
    private let defaults: UserDefaults
    private static let xKey = "floatingCapsulePositionX"
    private static let yKey = "floatingCapsulePositionY"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last position the user dragged the capsule to, or nil if it's
    /// never been moved (or a value only partially wrote, e.g. an
    /// interrupted defaults sync).
    public var position: CGPoint? {
        get {
            guard
                defaults.object(forKey: Self.xKey) != nil,
                defaults.object(forKey: Self.yKey) != nil
            else { return nil }
            let x = defaults.double(forKey: Self.xKey)
            let y = defaults.double(forKey: Self.yKey)
            return CGPoint(x: x, y: y)
        }
        set {
            if let newValue {
                defaults.set(newValue.x, forKey: Self.xKey)
                defaults.set(newValue.y, forKey: Self.yKey)
            } else {
                defaults.removeObject(forKey: Self.xKey)
                defaults.removeObject(forKey: Self.yKey)
            }
        }
    }
}
