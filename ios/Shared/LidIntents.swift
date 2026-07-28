import AppIntents
import WidgetKit

// App Intents power three things at once: interactive buttons inside the widget,
// the iOS 18 Control Center control, and "Hey Siri, sleep my Mac".

struct SleepMacIntent: AppIntent {
    static var title: LocalizedStringResource = "Sleep My Mac"
    static var description = IntentDescription("Tell the Mac to restore normal sleep and sleep now.")
    // Runs in the background without opening the app — ideal for a bag.
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        _ = await LidClient.send(.sleep)
        // Give the Mac a moment to publish its new state, then refresh widgets.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct SetModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Mac Lid Mode"
    static var openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: LidModeAppEnum

    init() {}
    init(mode: LidModeAppEnum) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        let cmd: LidCommand
        switch mode {
        case .normal: cmd = .modeNormal
        case .always: cmd = .modeAlways
        case .auto:   cmd = .modeAuto
        }
        _ = await LidClient.send(cmd)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

enum LidModeAppEnum: String, AppEnum {
    case normal, always, auto
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lid Mode")
    static var caseDisplayRepresentations: [LidModeAppEnum: DisplayRepresentation] = [
        .normal: "Sleep on Lid Close",
        .always: "Keep Awake",
        .auto:   "Auto Mode",
    ]
}

// Manual widget refresh button.
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Mac Status"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        _ = await LidClient.send(.status)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
