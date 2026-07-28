import WidgetKit
import SwiftUI
import AppIntents

// iOS 18 Control Center / Lock Screen control: a single big button that sleeps
// the Mac. This is the "phone out of pocket, one tap, Mac sleeps" path.

@available(iOS 18.0, *)
struct LidControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LidControl") {
            ControlWidgetButton(action: SleepMacIntent()) {
                Label("Sleep My Mac", systemImage: "powersleep")
            }
        }
        .displayName("Sleep My Mac")
        .description("Put your Mac to sleep from Control Center.")
    }
}
