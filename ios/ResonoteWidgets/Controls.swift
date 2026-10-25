import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen, and Action button: open capture for what's playing.
struct NoteControl: ControlWidget {
    static let kind = "dev.nmaass.resonote.note"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenResonoteIntent(target: .capture)) {
                Label("Note Song", systemImage: "music.note.list")
                    .controlWidgetActionHint("Note this song")
            }
        }
        .displayName("Note Song")
        .description("Write about what’s playing.")
    }
}

/// Control Center, Lock Screen, and Action button: listen with Shazam, then capture.
struct IdentifyControl: ControlWidget {
    static let kind = "dev.nmaass.resonote.identify"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenResonoteIntent(target: .identify)) {
                Label("Identify Song", systemImage: "shazam.logo")
                    .controlWidgetActionHint("Identify this song")
            }
        }
        .displayName("Identify Song")
        .description("Name the song playing nearby, then write about it.")
    }
}
