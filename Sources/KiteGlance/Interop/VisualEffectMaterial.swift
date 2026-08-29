import AppKit

/// Picks the right `NSVisualEffectView` material for the macOS release the
/// app is running on.
///
/// On macOS 26 (Tahoe) `.hudWindow` is replaced by `.glass` -- the system
/// draws Liquid Glass instead of the legacy blur, which gives a
/// noticeably crisper material in the rounded corners and along the
/// shadow. The widget is otherwise identical: the SwiftUI hierarchy
/// above the effect view paints the same pixels, the vibrancy sampler
/// reads what's behind the window the same way, the shadow falls the
/// same way. So this is just a single property assignment gated on
/// availability.
///
/// On macOS 15-25 the `.glass` symbol doesn't exist; `#available` keeps
/// the older `.hudWindow` path. The widget still looks correct on every
/// release, just with a different blur material under the same
/// SwiftUI rendering.
extension NSVisualEffectView {
    /// The "subtle, frosted-glass" material to use for the widget and
    /// Settings backdrop. `.glass` is the macOS 26 replacement for
    /// `.hudWindow`; on older releases the helper falls through.
    static var widgetMaterial: NSVisualEffectView.Material {
        if #available(macOS 26.0, *) {
            return .glass
        }
        return .hudWindow
    }
}
