import SwiftUI
import WidgetKit

/// Everything the widget extension offers. Order sets the order in the widget and
/// controls galleries.
@main
struct ResonoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NoteControl()
        IdentifyControl()
    }
}
