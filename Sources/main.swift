import AppKit
import SwiftUI
import IOKit.ps

// LidSleepToggle — a menubar app that decides when your Mac is allowed to sleep
// with the lid closed (pmset `disablesleep`: 0 = sleeps when shut, 1 = stays awake).
//
// Modes:
//   normal  — sleeps on lid close
//   always  — stays awake with the lid closed until you stop it
//   auto    — stays awake WHILE tracked work is running (Claude Code, Docker,
//             Ollama, builds…), then lets the Mac sleep once it's done
//
// On top of the mode sits a Safety Governor that can veto any keep-awake hold:
// battery floor, critical battery (force sleep), thermal limit, charging-only,
// session timer, and offline-with-no-work. Safety always wins.
//
// `lidkeep -- <cmd>` holds the Mac awake for exactly one command, in any mode.

// ---- Private brightness control (internal display + keyboard) ----
private typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (UInt32, Float) -> Int32

@objc private protocol KBC {
    func setBrightness(_ b: Float, forKeyboard k: Int64) -> Bool
    func enableAutoBrightness(_ on: Bool, forKeyboard k: Int64)
    func isKeyboardBuiltIn(_ k: Int64) -> Bool
    func isBacklightSuppressedOnKeyboard(_ k: Int64) -> Bool
    func suspendIdleDimming(_ s: Bool, forKeyboard k: Int64)
}

final class Backlight {
    private var dsGet: DSGet?
    private var dsSet: DSSet?
    private var kb: KBC?
    private(set) var kbdID: Int64 = 0

    init() {
        if let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
           let g = dlsym(ds, "DisplayServicesGetBrightness"), let s = dlsym(ds, "DisplayServicesSetBrightness") {
            dsGet = unsafeBitCast(g, to: DSGet.self)
            dsSet = unsafeBitCast(s, to: DSSet.self)
        }
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        if let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let o = cls.init()
            kb = unsafeBitCast(o, to: KBC.self)
            if let ids = o.perform(Selector(("copyKeyboardBacklightIDs")))?.takeRetainedValue() as? [NSNumber] {
                for n in ids where kb!.isKeyboardBuiltIn(n.int64Value) { kbdID = n.int64Value; break }
                if kbdID == 0, let first = ids.first { kbdID = first.int64Value }
            }
        }
    }

    func displayBrightness() -> Float? {
        guard let g = dsGet else { return nil }
        var b: Float = -1
        return g(CGMainDisplayID(), &b) == 0 ? b : nil
    }
    func setDisplayBrightness(_ v: Float) { _ = dsSet?(CGMainDisplayID(), max(0, min(1, v))) }

    // We never dim the keyboard: the private API leaves the backlight in a stuck
    // "suppressed" state. This self-heals that if an older build set it.
    func healKeyboardIfSuppressed() {
        guard let kb = kb, kbdID != 0 else { return }
        if kb.isBacklightSuppressedOnKeyboard(kbdID) {
            kb.suspendIdleDimming(false, forKeyboard: kbdID)
            kb.enableAutoBrightness(true, forKeyboard: kbdID)
            _ = kb.setBrightness(0.5, forKeyboard: kbdID)
        }
    }
}

// Tuning defaults; each is overridable with `defaults write com.sufwan.lidsleeptoggle <key>`.
let cpuThresholdDefault = 40    // claude process-tree %CPU that counts as working
let maxAwakeHoursDefault = 8.0  // hard cap on any single hold
let idleFloorDefault = 120      // never sleep in under this (s)
let idleCeilDefault = 1200      // ceiling on the learned idle window (s)
let idleGapFactorDefault = 2.0
let batteryFloorDefault = 20    // release keep-awake at/below this % on battery
let batteryCriticalDefault = 10 // force sleep at/below this % on battery
let tempCeilingDefault = 95     // °C backstop, macOS thermalState can lag
let watchdogMinutesDefault = 20 // warn when a tracked agent goes silent this long
let offlineMinutesDefault = 15  // offline + idle + on battery for this long -> sleep

// MARK: - System readings

struct Battery {
    var percent: Int = 100
    var charging: Bool = true
    var present: Bool = false
}

func batteryInfo() -> Battery {
    var b = Battery()
    guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return b }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any] else { continue }
        guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
        b.present = true
        b.percent = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
        b.charging = (d[kIOPSPowerSourceStateKey] as? String ?? "") == kIOPSACPowerValue
        return b
    }
    return b
}

enum ThermalLevel: Int {
    case normal = 0, warm = 1, hot = 2, critical = 3
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Critical"
        }
    }
}

func thermalLevel() -> ThermalLevel {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return .normal
    case .fair: return .warm
    case .serious: return .hot
    case .critical: return .critical
    @unknown default: return .normal
    }
}

struct AwakeItem: Identifiable {
    let id = UUID()
    let process: String
    let pid: String
    let kind: String
}

// Parses `pmset -g assertions` into the processes actively blocking sleep.
func awakeRadar() -> [AwakeItem] {
    let out = run(pmsetPath, ["-g", "assertions"]).output
    let blocking = ["PreventUserIdleSystemSleep", "PreventSystemSleep",
                    "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep"]
    var items: [AwakeItem] = []
    var seen = Set<String>()
    for raw in out.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("pid ") else { continue }
        guard let kind = blocking.first(where: { line.contains($0) }) else { continue }
        let afterPid = line.dropFirst(4)
        guard let paren = afterPid.firstIndex(of: "("), let close = afterPid.firstIndex(of: ")") else { continue }
        let pid = String(afterPid[afterPid.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        let proc = String(afterPid[afterPid.index(after: paren)..<close])
        let key = proc + kind
        if seen.contains(key) { continue }
        seen.insert(key)
        items.append(AwakeItem(process: proc, pid: pid, kind: kind))
    }
    return items
}

enum Mode: String, CaseIterable, Identifiable {
    case normal, always, auto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Sleep on Lid Close"
        case .always: return "Keep Awake"
        case .auto: return "Auto Mode"
        }
    }
    var symbol: String {
        switch self {
        case .normal: return "moon.fill"
        case .always: return "eye.fill"
        case .auto: return "wand.and.stars"
        }
    }
    var iconSymbol: String {
        switch self {
        case .normal: return "moon.fill"
        case .always: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }
    var hint: String {
        switch self {
        case .normal: return "Normal"
        case .always: return "Until stopped"
        case .auto: return "While work runs"
        }
    }
}

struct LogEvent: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
    let critical: Bool
}

// Seconds since the newest Claude session activity (-1 = none) and the claude
// process-tree %CPU. The app decides active/idle with an adaptive window.
func claudeSignals() -> (age: Int, cpu: Int) {
    let r = run(pythonPath, [detectorPath, "999999", "\(cfgInt("cpuThreshold", cpuThresholdDefault))"])
    var age = -1, cpu = 0
    for tok in r.output.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        if tok.hasPrefix("age=") { age = Int(tok.dropFirst(4)) ?? -1 }
        else if tok.hasPrefix("cpu=") { cpu = Int(tok.dropFirst(4)) ?? 0 }
    }
    return (age, cpu)
}

// MARK: - Shared state

final class AppState: ObservableObject {
    @Published var mode: Mode = .normal
    @Published var awake = false
    @Published var lidClosed = false
    @Published var battery = Battery()
    @Published var thermal: ThermalLevel = .normal
    @Published var tempC: Double?
    @Published var cpuUsage: Int?
    @Published var claudeAge = -1
    @Published var claudeCpu = 0
    @Published var window: Double = 120
    @Published var windowFixed = false
    @Published var radar: [AwakeItem] = []
    @Published var workloads: [ActiveWorkload] = []
    @Published var holds: [Hold] = []
    @Published var reasons: [String] = []
    @Published var vetoReason: String?
    @Published var expiresAt: Date?
    @Published var events: [LogEvent] = []
    @Published var online = true

    // Settings (persisted)
    @Published var batteryFloor = batteryFloorDefault
    @Published var thermalGuard = true
    @Published var chargingOnly = false
    @Published var timerHours = 0
    @Published var preventDisplaySleep = false
    @Published var sleepWhenOffline = false
    @Published var watchdogEnabled = true
    @Published var watchdogMinutes = watchdogMinutesDefault
    @Published var rules: [WorkloadRule] = []
    @Published var ntfyTopic = ""
    @Published var webhookURL = ""
    @Published var pushWarnings = false

    // Dashboard
    @Published var sessionCount = 0
    @Published var totalAwake: TimeInterval = 0
    @Published var longestAwake: TimeInterval = 0
    @Published var recentSessions: [AwakeSession] = []

    var onSetMode: (Mode) -> Void = { _ in }
    var onSleepNow: () -> Void = {}
    var onSettingsChanged: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onOpenLog: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onTestAlert: () -> Void = {}
    var onInstallCLI: () -> Void = {}

    func loadSettings() {
        batteryFloor = cfgInt("batteryFloor", batteryFloorDefault)
        thermalGuard = cfgBool("thermalGuard", true)
        chargingOnly = cfgBool("chargingOnly", false)
        timerHours = UserDefaults.standard.integer(forKey: "timerHours")
        preventDisplaySleep = cfgBool("preventDisplaySleep", false)
        sleepWhenOffline = cfgBool("sleepWhenOffline", false)
        watchdogEnabled = cfgBool("watchdogEnabled", true)
        watchdogMinutes = cfgInt("watchdogMinutes", watchdogMinutesDefault)
        rules = loadRules()
        ntfyTopic = UserDefaults.standard.string(forKey: "ntfyTopic") ?? ""
        webhookURL = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
        pushWarnings = cfgBool("pushWarnings", false)
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(batteryFloor, forKey: "batteryFloor")
        d.set(thermalGuard, forKey: "thermalGuard")
        d.set(chargingOnly, forKey: "chargingOnly")
        d.set(timerHours, forKey: "timerHours")
        d.set(preventDisplaySleep, forKey: "preventDisplaySleep")
        d.set(sleepWhenOffline, forKey: "sleepWhenOffline")
        d.set(watchdogEnabled, forKey: "watchdogEnabled")
        d.set(watchdogMinutes, forKey: "watchdogMinutes")
        d.set(ntfyTopic, forKey: "ntfyTopic")
        d.set(webhookURL, forKey: "webhookURL")
        d.set(pushWarnings, forKey: "pushWarnings")
        saveRules(rules)
    }

    func addEvent(_ text: String, critical: Bool = false) {
        events.insert(LogEvent(at: Date(), text: text, critical: critical), at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    var pill: String {
        if vetoReason != nil { return "Held" }
        if awake { return "Awake" }
        return mode == .auto ? "Watching" : "Ready"
    }
    var pillColor: Color {
        if vetoReason != nil { return .orange }
        if awake { return .yellow }
        return .green
    }
    var detail: String {
        if let v = vetoReason { return v }
        if !holds.isEmpty {
            return "Awake · \(holds.count) command\(holds.count == 1 ? "" : "s") running"
        }
        switch mode {
        case .normal:
            return "Idle · your Mac sleeps normally"
        case .always:
            if let e = expiresAt {
                return "Awake · \(fmtDur(max(0, Int(e.timeIntervalSinceNow)))) left on timer"
            }
            return "Awake · held until you stop it"
        case .auto:
            let w = windowFixed ? fmtDur(Int(window)) : "\(fmtDur(Int(window))) adaptive"
            if awake {
                return "Awake · \(reasons.joined(separator: ", ")) · \(w)"
            }
            if claudeAge < 0 && workloads.isEmpty { return "Watching · nothing running · \(w)" }
            return "Watching · quiet \(fmtDur(max(0, claudeAge))) · \(w)"
        }
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    let state = AppState()
    var settingsWindow: NSWindow?

    var mode: Mode = .normal
    var monitorTimer: Timer?
    var safetyTimer: Timer?
    var uiTimer: Timer?
    var autoAwakeSince: Date?
    var lastSet: Bool?
    var animTimer: Timer?
    var animPhase: Double = 0
    // Adaptive idle-window learning.
    var prevAge = -1
    var peakAge = 0
    var recentGaps: [(len: Double, at: Date)] = []
    var currentWindow: Double = 120
    var lastAge = -1
    var lastCpu = 0
    var lidTimer: Timer?
    var prevLidClosed = false
    let backlight = Backlight()
    var dimmed = false
    var savedDisplay: Float?
    let sensors = ThermalSensors()
    let cpuMonitor = CPUMonitor()
    let stats = Stats()
    let notifier = Notifier()
    let displayAssertion = DisplayAssertion()
    var vetoNotified = false
    var expiresAt: Date?
    var watchdogFired = false
    var idleSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("app launched")
        ensureHoldsDir()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        state.loadSettings()
        wireCallbacks()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(state: state))
        // Without this the popover is anchored at a stale size and then grows
        // upward, off the top of the screen.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "normal") ?? .normal
        state.mode = mode

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.mode == .auto { self.runAutoCheck() } else { self.updateUI() }
        }

        // Recover from a run that was killed while the display was dimmed.
        if UserDefaults.standard.bool(forKey: "dimmed") {
            let sd = Float(UserDefaults.standard.double(forKey: "savedDisplay"))
            savedDisplay = sd >= 0 ? sd : nil
            dimmed = true
            restoreBrightness()
        }
        backlight.healKeyboardIfSuppressed()

        // Crash guard: a previous run that died holding the Mac awake would leave
        // disablesleep stuck at 1 forever.
        if mode == .normal && isKeepAwakeEnabled() {
            log("crash guard: disablesleep=1 with mode=normal, restoring")
            state.addEvent("Restored normal sleep after unclean exit", critical: true)
            setKeepAwake(false)
        }

        prevLidClosed = lidClosed()
        lidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkLid()
        }
        RunLoop.main.add(lidTimer!, forMode: .common)

        // The governor runs in every mode, including `normal`, so CLI holds and
        // safety limits are always honoured.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.safetyCheck()
        }
        RunLoop.main.add(safetyTimer!, forMode: .common)

        _ = cpuMonitor.usage()  // prime the tick baseline
        displayAssertion.set(state.preventDisplaySleep)
        applyMode(animated: false)
    }

    func wireCallbacks() {
        state.onSetMode = { [weak self] m in self?.setMode(m) }
        state.onSleepNow = { [weak self] in self?.sleepNow() }
        state.onSettingsChanged = { [weak self] in
            guard let self = self else { return }
            self.state.saveSettings()
            self.displayAssertion.set(self.state.preventDisplaySleep)
            self.safetyCheck()
            self.refreshState()
        }
        state.onRefresh = { [weak self] in self?.refreshState() }
        state.onOpenLog = { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        state.onTestAlert = { [weak self] in self?.notifier.sendTest() }
        state.onInstallCLI = { [weak self] in self?.installCLI() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if dimmed { restoreBrightness() }
        displayAssertion.set(false)
        stats.end(by: "app quit")
        // Never leave the Mac unable to sleep because we went away.
        if isKeepAwakeEnabled() {
            log("terminating while awake -> restoring normal sleep")
            setKeepAwake(false)
        }
    }

    // MARK: - Status item / popover

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showFallbackMenu(); return }
        if popover.isShown { closePopover() } else { openPopover() }
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        refreshState()
        // Resolve the real content size BEFORE anchoring and clamp it to the
        // screen, so the popover can never overflow above the menubar.
        if let host = popover.contentViewController {
            host.view.layoutSubtreeIfNeeded()
            var size = host.view.fittingSize
            if let screen = button.window?.screen ?? NSScreen.main {
                let maxH = screen.visibleFrame.height - 16
                if size.height > maxH { size.height = maxH }
            }
            if size.width > 0 && size.height > 0 { popover.contentSize = size }
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
    }

    func closePopover() {
        popover.performClose(nil)
        uiTimer?.invalidate(); uiTimer = nil
    }

    func popoverDidClose(_ notification: Notification) {
        uiTimer?.invalidate(); uiTimer = nil
    }

    // Right-click escape hatch so the app stays controllable if the panel ever
    // misbehaves.
    func showFallbackMenu() {
        let menu = NSMenu()
        for m in Mode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (mode == m) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let sleep = NSMenuItem(title: "Sleep Now", action: #selector(sleepNowMenu), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func pickFromMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) { setMode(m) }
    }
    @objc func sleepNowMenu() { sleepNow() }
    @objc func openSettingsMenu() { openSettings() }

    func openSettings() {
        closePopover()
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(state: state))
        let w = NSWindow(contentViewController: host)
        w.title = "LidSleepToggle Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 520, height: 460))
        w.center()
        w.isReleasedWhenClosed = false
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - Mode selection

    func setMode(_ m: Mode) {
        mode = m
        state.mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        log("mode -> \(m.rawValue)")
        state.addEvent("Switched to \(m.title)")
        let hours = state.timerHours
        expiresAt = (m != .normal && hours > 0) ? Date().addingTimeInterval(Double(hours) * 3600) : nil
        vetoNotified = false
        applyMode(animated: true)
    }

    func applyMode(animated: Bool) {
        stopMonitor()
        autoAwakeSince = nil
        switch mode {
        case .normal: applyDesired(false, reasons: [])
        case .always: applyDesired(true, reasons: ["Keep Awake"])
        case .auto:
            monitorTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.runAutoCheck()
            }
            RunLoop.main.add(monitorTimer!, forMode: .common)
            runAutoCheck()
        }
        if animated { pulseThenSettle() } else { updateUI() }
    }

    func stopMonitor() { monitorTimer?.invalidate(); monitorTimer = nil }

    // MARK: - Safety governor

    // A human reason why a keep-awake hold must NOT be held right now, or nil.
    func safetyVeto() -> String? {
        let b = batteryInfo()
        if state.chargingOnly && b.present && !b.charging {
            return "On battery — charging-only is on"
        }
        if b.present && !b.charging {
            let crit = cfgInt("batteryCritical", batteryCriticalDefault)
            if b.percent <= crit { return "Battery \(b.percent)% — critical" }
            if b.percent <= state.batteryFloor { return "Battery \(b.percent)% — below \(state.batteryFloor)% floor" }
        }
        if state.thermalGuard {
            if thermalLevel() == .critical { return "Mac is critically hot" }
            if let t = sensors.hottest(), t >= Double(cfgInt("tempCeiling", tempCeilingDefault)) {
                return "CPU at \(Int(t.rounded()))°C"
            }
        }
        if let e = expiresAt, Date() >= e { return "Session timer finished" }
        return nil
    }

    // Single choke point: every keep-awake decision passes through the governor.
    func applyDesired(_ wantAwake: Bool, reasons: [String]) {
        var awake = wantAwake
        let veto = safetyVeto()
        if awake, let reason = veto {
            awake = false
            if !vetoNotified {
                vetoNotified = true
                log("SAFETY VETO: \(reason)")
                state.addEvent("Released keep-awake — \(reason)", critical: true)
                notifier.send(title: "Keep-awake released", body: reason,
                              event: "safety_veto", level: .critical)
                let b = batteryInfo()
                if b.present && !b.charging && b.percent <= cfgInt("batteryCritical", batteryCriticalDefault) {
                    setKeepAwake(false); lastSet = false
                    log("critical battery -> sleepnow")
                    run(pmsetPath, ["sleepnow"])
                }
            }
        }
        if veto == nil { vetoNotified = false }
        state.vetoReason = veto
        state.reasons = awake ? reasons : []
        setDesired(awake, reasons: reasons)
    }

    // The governor tick: runs in every mode.
    func safetyCheck() {
        if let e = expiresAt, Date() >= e {
            expiresAt = nil
            log("session timer expired -> normal")
            state.addEvent("Session timer finished — normal sleep restored")
            notifier.send(title: "Timer finished", body: "Normal sleep restored.",
                          event: "timer", level: .warning)
            setMode(.normal)
            return
        }

        // CLI holds win in every mode, including `normal`.
        let holds = activeHolds()
        state.holds = holds
        if !holds.isEmpty {
            let labels = holds.map { $0.label }
            applyDesired(true, reasons: labels)
            updateUI()
            return
        }
        // A hold that just ended may have asked for sleep.
        if consumeSleepRequest() {
            log("lidkeep --sleep: command finished, sleeping")
            state.addEvent("Command finished — sleeping the Mac")
            notifier.send(title: "Command finished", body: "Sleeping the Mac as requested.",
                          event: "run_command_done", level: .warning)
            sleepNow()
            return
        }

        switch mode {
        case .normal: applyDesired(false, reasons: [])
        case .always: applyDesired(true, reasons: ["Keep Awake"])
        case .auto: break   // runAutoCheck drives this
        }
        checkOfflineSleep()
        updateUI()
    }

    // Optional rule: on battery, offline and with no tracked work, let it sleep.
    func checkOfflineSleep() {
        guard state.sleepWhenOffline, mode != .normal else { idleSince = nil; return }
        let b = batteryInfo()
        let online = isOnline()
        state.online = online
        let working = !state.reasons.isEmpty
        guard b.present && !b.charging && !online && !working else { idleSince = nil; return }
        if idleSince == nil { idleSince = Date() }
        let mins = cfgInt("offlineMinutes", offlineMinutesDefault)
        if let since = idleSince, Date().timeIntervalSince(since) >= Double(mins) * 60 {
            idleSince = nil
            log("offline + idle + on battery for \(mins)m -> sleeping")
            state.addEvent("Offline with no work — slept the Mac", critical: true)
            notifier.send(title: "Sleeping your Mac",
                          body: "Offline on battery with no tracked work for \(mins) minutes.",
                          event: "offline_sleep", level: .critical)
            sleepNow()
        }
    }

    func sleepNow() {
        closePopover()
        log("sleep now requested")
        state.addEvent("Sleep Now")
        if isKeepAwakeEnabled() { setKeepAwake(false); lastSet = false }
        stats.end(by: "sleep now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            run(pmsetPath, ["sleepnow"])
        }
    }

    // MARK: - Auto loop

    func runAutoCheck() {
        let (age, cpu) = claudeSignals()
        let cpuThresh = cfgInt("cpuThreshold", cpuThresholdDefault)
        let floorS = cfgDouble("idleFloorSeconds", Double(idleFloorDefault))

        // Learn pause lengths: when activity resumes (age drops), the pause that
        // just ended was ~peakAge long, so remember it and don't mistake a
        // similar future pause for "work finished".
        if age >= 0 {
            if prevAge >= 0 && age < prevAge - 2 {
                if Double(peakAge) >= floorS / 2 { recentGaps.append((Double(peakAge), Date())) }
                peakAge = age
            } else {
                peakAge = max(peakAge, age)
            }
            prevAge = age
        }
        let cutoff = Date().addingTimeInterval(-90 * 60)
        recentGaps.removeAll { $0.at < cutoff }
        if recentGaps.count > 30 { recentGaps.removeFirst(recentGaps.count - 30) }

        let fixed = cfgInt("idleWindowSeconds", 0)
        if fixed > 0 {
            currentWindow = Double(fixed)
        } else {
            let ceilS = cfgDouble("idleCeilSeconds", Double(idleCeilDefault))
            let factor = cfgDouble("idleGapFactor", idleGapFactorDefault)
            let maxGap = recentGaps.map { $0.len }.max() ?? 0
            currentWindow = min(max(floorS, factor * maxGap), ceilS)
        }

        // Reason 1: Claude Code, by file activity or CPU.
        var reasons: [String] = []
        let claudeActive = (age >= 0 && Double(age) < currentWindow) || (cpu >= cpuThresh)
        if claudeActive { reasons.append("Claude") }

        // Reason 2: every other tracked workload, by process + CPU.
        let workloads = detectWorkloads(state.rules)
        state.workloads = workloads
        reasons.append(contentsOf: workloads.map { $0.name })

        // Reason 3: an explicit `lidkeep` hold.
        let holds = activeHolds()
        state.holds = holds
        reasons.append(contentsOf: holds.map { $0.label })

        var desired = !reasons.isEmpty
        if desired {
            if autoAwakeSince == nil { autoAwakeSince = Date() }
            let maxAwake = cfgDouble("maxAwakeHours", maxAwakeHoursDefault)
            if let since = autoAwakeSince, Date().timeIntervalSince(since) >= maxAwake * 3600 {
                desired = false  // hard cap
                reasons = []
            }
        } else {
            autoAwakeSince = nil
        }

        lastAge = age; lastCpu = cpu
        runWatchdog(age: age, claudeActive: claudeActive)
        log("auto: age=\(age)s cpu=\(cpu)% window=\(Int(currentWindow))s reasons=[\(reasons.joined(separator: ","))] -> awake=\(desired)")
        applyDesired(desired, reasons: reasons)
        checkOfflineSleep()
        updateUI()
    }

    // Warn when a tracked agent has gone silent but is still running: usually it
    // is waiting on input rather than working.
    func runWatchdog(age: Int, claudeActive: Bool) {
        guard state.watchdogEnabled else { return }
        let limit = cfgInt("watchdogMinutes", watchdogMinutesDefault) * 60
        if age >= 0 && age >= limit && anyProcessMatching("claude") {
            if !watchdogFired {
                watchdogFired = true
                let msg = "Claude has been quiet for \(fmtDur(age)) — it may be waiting on your input."
                log("watchdog: \(msg)")
                state.addEvent(msg, critical: true)
                notifier.send(title: "Agent may be stuck", body: msg,
                              event: "watchdog", level: .critical)
            }
        } else if claudeActive || age < limit {
            watchdogFired = false
        }
    }

    // Only calls pmset when the value actually needs to change.
    func setDesired(_ awake: Bool, reasons: [String]) {
        if lastSet != awake {
            if setKeepAwake(awake) {
                lastSet = awake
                if awake {
                    stats.begin(reason: reasons.isEmpty ? mode.title : reasons.joined(separator: ", "))
                    state.addEvent("Keeping awake — \(reasons.joined(separator: ", "))")
                } else {
                    stats.end(by: state.vetoReason ?? "work finished")
                    state.addEvent("Released keep-awake")
                }
            }
        } else if awake {
            stats.begin(reason: reasons.joined(separator: ", "))
        }
    }

    // MARK: - Lid / display power

    func lidClosed() -> Bool {
        let r = run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"])
        return r.output.contains("\"AppleClamshellState\" = Yes")
    }

    func checkLid() {
        let closed = lidClosed()
        if closed && isKeepAwakeEnabled() {
            if !dimmed {
                savedDisplay = backlight.displayBrightness()
                let d = UserDefaults.standard
                d.set(true, forKey: "dimmed")
                d.set(Double(savedDisplay ?? -1), forKey: "savedDisplay")
                dimmed = true
                log("lid closed while awake -> display brightness 0 (was \(savedDisplay ?? -1))")
            }
            // Re-assert: with the lid shut the ambient sensor is covered and
            // auto-brightness tries to crank it back up.
            backlight.setDisplayBrightness(0)
        } else if dimmed {
            restoreBrightness()
        }
        prevLidClosed = closed
    }

    func restoreBrightness() {
        backlight.setDisplayBrightness(savedDisplay ?? 0.5)  // never leave it black
        log("restored display brightness -> \(savedDisplay ?? 0.5)")
        dimmed = false
        let d = UserDefaults.standard
        d.removeObject(forKey: "dimmed"); d.removeObject(forKey: "savedDisplay")
        savedDisplay = nil
    }

    // MARK: - CLI installer

    func installCLI() {
        let binDir = NSHomeDirectory() + "/.local/bin"
        try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let dest = binDir + "/lidkeep"
        let script = """
        #!/bin/bash
        # lidkeep — hold the Mac awake for exactly one command, then let it sleep.
        #   lidkeep -- npm run build
        #   lidkeep --sleep -- python train.py     (sleep the Mac when it finishes)
        set -uo pipefail
        HOLDS="$HOME/Library/Application Support/LidSleepToggle/holds"
        FLAG="$HOME/Library/Application Support/LidSleepToggle/sleep-when-done"
        SLEEP_AFTER=0
        while [ $# -gt 0 ]; do
          case "$1" in
            --sleep) SLEEP_AFTER=1; shift ;;
            --) shift; break ;;
            -h|--help) echo "usage: lidkeep [--sleep] -- <command>"; exit 0 ;;
            *) break ;;
          esac
        done
        if [ $# -eq 0 ]; then echo "usage: lidkeep [--sleep] -- <command>" >&2; exit 2; fi
        mkdir -p "$HOLDS"
        HOLD="$HOLDS/$$.hold"
        printf '%s' "$(basename "$1")" > "$HOLD"
        cleanup() { rm -f "$HOLD"; }
        trap cleanup EXIT INT TERM
        "$@"
        STATUS=$?
        if [ "$SLEEP_AFTER" = "1" ]; then : > "$FLAG"; fi
        exit $STATUS
        """
        do {
            try script.write(toFile: dest, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            log("installed CLI at \(dest)")
            state.addEvent("Installed lidkeep CLI to ~/.local/bin")
            notifier.send(title: "lidkeep installed",
                          body: "Run: lidkeep -- npm run build (ensure ~/.local/bin is on your PATH)",
                          event: "cli_installed", level: .critical)
        } catch {
            log("CLI install failed: \(error)")
            state.addEvent("Failed to install lidkeep CLI", critical: true)
        }
    }

    // MARK: - UI

    func refreshState() {
        state.battery = batteryInfo()
        state.thermal = thermalLevel()
        state.tempC = sensors.hottest()
        if let c = cpuMonitor.usage() { state.cpuUsage = c }
        state.lidClosed = prevLidClosed
        state.claudeAge = lastAge
        state.claudeCpu = lastCpu
        state.window = currentWindow
        state.windowFixed = cfgInt("idleWindowSeconds", 0) > 0
        state.awake = isKeepAwakeEnabled()
        state.mode = mode
        state.expiresAt = expiresAt
        state.holds = activeHolds()
        if popover.isShown || settingsWindow?.isVisible == true {
            state.radar = awakeRadar()
            state.sessionCount = stats.recent().count
            state.totalAwake = stats.totalAwake()
            state.longestAwake = stats.longest()
            state.recentSessions = Array(stats.recent().prefix(12))
        }
    }

    func updateUI() {
        refreshState()
        renderIcon(awake: state.awake)
    }

    func renderIcon(awake: Bool) {
        guard animTimer == nil, let button = statusItem.button else { return }
        button.title = ""
        if state.vetoReason != nil {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            if let img = NSImage(systemSymbolName: "exclamationmark.shield.fill",
                                 accessibilityDescription: "held off for safety")?.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
                return
            }
        }
        if awake {
            let name = mode == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
            if let img = (NSImage(systemSymbolName: name, accessibilityDescription: "staying awake")
                            ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "staying awake"))?
                .withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
                return
            }
            button.title = "⚡"
        } else {
            if let img = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "sleeps on lid close") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "☾"
            }
        }
    }

    // Brief sweep confirming a mode change registered.
    func pulseThenSettle() {
        animTimer?.invalidate()
        animPhase = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self = self, let button = self.statusItem.button else { t.invalidate(); return }
            self.animPhase += 0.1
            if self.animPhase >= 1.0 {
                t.invalidate()
                self.animTimer = nil
                self.updateUI()
                return
            }
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
            if let img = NSImage(systemSymbolName: "rays", variableValue: self.animPhase,
                                 accessibilityDescription: "switching")?.withSymbolConfiguration(cfg) {
                img.isTemplate = false
                button.image = img
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
