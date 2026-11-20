/// Features that need a capability a lean "core" build leaves out.
///
/// `ResonoteCore.xcodeproj` (generated from `project-core.yml`) compiles the app alone
/// with `RESONOTE_CORE` and no entitlements, so it signs with any Apple ID: no widgets,
/// share extension, ShazamKit (Identify), Journaling Suggestions, or App Group. The full
/// `Resonote.xcodeproj` leaves the flag unset and everything on.
enum AppFeatures {
    #if RESONOTE_CORE
    static let identify = false
    static let journalingSuggestions = false
    #else
    static let identify = true
    static let journalingSuggestions = true
    #endif
}
