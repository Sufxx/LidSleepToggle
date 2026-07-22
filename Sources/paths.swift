import Foundation

// All on-disk locations. Everything lives under Application Support so the app
// is relocatable and contains no user-specific absolute paths.

let appSupportDir: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/LidSleepToggle"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

let logPath = appSupportDir + "/lidsleeptoggle.log"
let statsPath = appSupportDir + "/stats.json"
let holdsDir = appSupportDir + "/holds"
let sleepRequestPath = appSupportDir + "/sleep-when-done"

// The Claude activity detector ships inside the bundle; fall back to the source
// tree so `swiftc` dev builds still work without assembling a bundle.
let detectorPath: String = {
    if let res = Bundle.main.resourcePath {
        let bundled = res + "/claude-active.py"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
    }
    let dev = FileManager.default.currentDirectoryPath + "/claude-active.py"
    if FileManager.default.fileExists(atPath: dev) { return dev }
    return NSHomeDirectory() + "/Claude Agents/LidSleepToggle/claude-active.py"
}()

let pmsetPath = "/usr/bin/pmset"
let sudoPath = "/usr/bin/sudo"
let pythonPath = "/usr/bin/python3"

// MARK: - Core helpers

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
    // Keep the log from growing without bound.
    if let size = try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int,
       size > 2_000_000 {
        if let all = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let tail = all.suffix(400_000)
            try? tail.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() }
    catch { return (-1, "failed to launch \(launchPath): \(error)") }
    // Drain the pipe BEFORE waiting. Waiting first deadlocks as soon as the
    // child writes more than the 64K pipe buffer (e.g. `ps -Ao args=`).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// True when the Mac is currently set to stay awake with the lid closed.
func isKeepAwakeEnabled() -> Bool {
    // `pmset -g` reports this as "SleepDisabled"; `pmset -g custom` uses
    // "disablesleep". Accept either so the readback never silently fails.
    let result = run(pmsetPath, ["-g"])
    for line in result.output.split(separator: "\n") {
        let lower = line.lowercased()
        if lower.contains("sleepdisabled") || lower.contains("disablesleep") {
            return lower.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
    }
    return false
}

@discardableResult
func setKeepAwake(_ enabled: Bool) -> Bool {
    let value = enabled ? "1" : "0"
    let result = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", value])
    log("setKeepAwake(\(enabled)) exit=\(result.status) \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    return result.status == 0
}

func fmtDur(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    let m = s / 60, r = s % 60
    if m < 60 { return r == 0 ? "\(m)m" : "\(m)m\(r)s" }
    let h = m / 60, rm = m % 60
    return rm == 0 ? "\(h)h" : "\(h)h\(rm)m"
}

func cfgInt(_ key: String, _ fallback: Int) -> Int {
    let v = UserDefaults.standard.integer(forKey: key); return v > 0 ? v : fallback
}
func cfgDouble(_ key: String, _ fallback: Double) -> Double {
    let v = UserDefaults.standard.double(forKey: key); return v > 0 ? v : fallback
}
func cfgBool(_ key: String, _ fallback: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
}
