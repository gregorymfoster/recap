import SwiftUI

/// Accessibility identifiers for shared, cross-feature surfaces: the toast
/// overlay and the reusable copy-to-clipboard button.
extension AXID {
    /// The toast overlay's floating banner container (`ToastOverlay`'s
    /// `ToastBanner`), present only while a toast is showing.
    public static let toastOverlay = AXID("toast-overlay")

    /// A "Copy" chip (`CopyButton`) — shared across transcript/notes/toolbar
    /// call sites, so this id is not unique per-instance. Prefer scoping
    /// lookups by surrounding container when multiple copy buttons are on
    /// screen at once.
    public static let copyButton = AXID("copy-button")
}
