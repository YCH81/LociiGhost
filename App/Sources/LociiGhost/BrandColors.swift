import SwiftUI

/// Brand palette extracted from the LociiGhost AppIcon master
/// (sage-green paper plane + warm linen background).
///
/// Use these anywhere the UI should feel like it belongs to the
/// same visual world as the app icon. Apply
/// `.tint(appState.appearanceMode.tint)` at the WindowGroup
/// root so SwiftUI-default tinted controls (Toggle, Picker,
/// `.borderedProminent` Button, ProgressView) pick it up
/// automatically through the environment.
extension Color {
    /// Primary brand accent — mid sage, matches the paper plane's
    /// dominant tone. The default "the app's green".
    static let lociSage      = Color(red: 0.596, green: 0.671, blue: 0.545)  // #98AB8B

    /// Deeper sage for hover / pressed / active states and any time
    /// the primary `lociSage` needs slightly more weight on a light
    /// surface.
    static let lociSageDark  = Color(red: 0.494, green: 0.580, blue: 0.447)  // #7E9472

    /// Pale sage for subtle hover backgrounds, soft selection
    /// highlights, faint borders — anywhere the primary sage would
    /// be too saturated.
    static let lociSageLight = Color(red: 0.780, green: 0.823, blue: 0.706)  // #C7D2B4

    /// Warm linen off-white — the icon master's background. Useful
    /// for sheet headers / cards where the system default surface
    /// feels too plain. Avoid as a full-screen background; the
    /// system colour adapts to dark mode and this doesn't.
    static let lociCream     = Color(red: 0.961, green: 0.949, blue: 0.926)  // #F5F2EC

    /// Warm deep ink for primary text on cream surfaces. Use `.primary`
    /// when the surface is a system default so dark-mode contrast
    /// stays correct; reach for this only when you've explicitly
    /// painted onto `lociCream`.
    static let lociInk       = Color(red: 0.180, green: 0.165, blue: 0.157)  // #2E2A28
}
