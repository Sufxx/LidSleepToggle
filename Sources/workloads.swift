import Foundation

// Workload detection: which tracked tools are actually working right now.
//
// Claude Code is detected by file activity (claude-active.py reading session
// JSONL timestamps) because that survives long silent thinking pauses. Every
// other tool is detected from the process table with a %CPU threshold, so an
// idle `ollama serve` or an open editor doesn't hold the Mac awake forever.

struct WorkloadRule: Codable, Identifiable, Equatable {
    var name: String
    var patterns: [String]     // matched case-insensitively against the full argv
    var cpuThreshold: Int      // process-tree %CPU that counts as "working"
    var enabled: Bool
    var builtin: Bool

    var id: String { name }
}

// Thresholds are deliberately conservative for noisy names (node/python match a
// lot), and generous for tools that only run when you asked them to.
let builtinRules: [WorkloadRule] = [
    WorkloadRule(name: "Cursor",          patterns: ["cursor helper", "/cursor"],          cpuThreshold: 25, enabled: false, builtin: true),
    WorkloadRule(name: "Codex",           patterns: ["codex"],                             cpuThreshold: 10, enabled: true,  builtin: true),
    WorkloadRule(name: "Ollama",          patterns: ["ollama"],                            cpuThreshold: 15, enabled: true,  builtin: true),
    WorkloadRule(name: "Docker",          patterns: ["com.docker", "dockerd", "buildkit"], cpuThreshold: 20, enabled: true,  builtin: true),
    WorkloadRule(name: "Node / npm",      patterns: ["npm ", "vite", "webpack", "next-server", "esbuild"], cpuThreshold: 35, enabled: false, builtin: true),
    WorkloadRule(name: "Python / ML",     patterns: ["python", "python3"],                 cpuThreshold: 35, enabled: false, builtin: true),
    WorkloadRule(name: "Xcode / swiftc",  patterns: ["xcodebuild", "swift-frontend"],      cpuThreshold: 30, enabled: false, builtin: true),
    WorkloadRule(name: "ffmpeg",          patterns: ["ffmpeg"],                            cpuThreshold: 10, enabled: true,  builtin: true),
    WorkloadRule(name: "Rust / cargo",    patterns: ["cargo", "rustc"],                    cpuThreshold: 30, enabled: false, builtin: true),
    WorkloadRule(name: "Blender",         patterns: ["blender"],                           cpuThreshold: 15, enabled: false, builtin: true),
    WorkloadRule(name: "Handbrake",       patterns: ["handbrake"],                         cpuThreshold: 15, enabled: false, builtin: true),
]

struct ActiveWorkload: Identifiable, Equatable {
    var name: String
    var cpu: Double
    var procs: Int
    var id: String { name }
}

private struct ProcSample {
    let pid: Int32
    let cpu: Double
    let argv: String
}

// One `ps` sweep of every process, with our own helpers filtered out so the app
// can never detect itself as a workload.
private func sampleProcesses() -> [ProcSample] {
    let out = run("/bin/ps", ["-Ao", "pid=,pcpu=,args="]).output
    let selfPID = ProcessInfo.processInfo.processIdentifier
    var result: [ProcSample] = []
    result.reserveCapacity(400)
    for raw in out.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { continue }
        guard let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { continue }
        if pid == selfPID { continue }
        let argv = String(parts[2])
        // Skip our own moving parts: the detector, the CLI wrapper, this app.
        if argv.contains("claude-active.py") || argv.contains("LidSleepToggle") || argv.contains("lidkeep") {
            continue
        }
        result.append(ProcSample(pid: pid, cpu: cpu, argv: argv))
    }
    return result
}

func loadRules() -> [WorkloadRule] {
    guard let data = UserDefaults.standard.data(forKey: "workloadRules"),
          let saved = try? JSONDecoder().decode([WorkloadRule].self, from: data) else {
        return builtinRules
    }
    // Merge in any built-ins added by a newer build, preserving user toggles.
    var merged = saved
    for b in builtinRules where !saved.contains(where: { $0.name == b.name }) {
        merged.append(b)
    }
    return merged
}

func saveRules(_ rules: [WorkloadRule]) {
    if let data = try? JSONEncoder().encode(rules) {
        UserDefaults.standard.set(data, forKey: "workloadRules")
    }
}

// Every enabled rule whose matching processes exceed its CPU threshold.
func detectWorkloads(_ rules: [WorkloadRule]) -> [ActiveWorkload] {
    let enabled = rules.filter { $0.enabled }
    guard !enabled.isEmpty else { return [] }
    let procs = sampleProcesses()
    guard !procs.isEmpty else { return [] }

    var active: [ActiveWorkload] = []
    for rule in enabled {
        let needles = rule.patterns.map { $0.lowercased() }
        var total = 0.0
        var count = 0
        for p in procs {
            let hay = p.argv.lowercased()
            if needles.contains(where: { hay.contains($0) }) {
                total += p.cpu
                count += 1
            }
        }
        guard count > 0 else { continue }
        if total >= Double(rule.cpuThreshold) {
            active.append(ActiveWorkload(name: rule.name, cpu: total, procs: count))
        }
    }
    return active.sorted { $0.cpu > $1.cpu }
}

// MARK: - CLI holds
//
// `lidkeep -- <cmd>` drops a file named <pid>.hold in this directory and removes
// it on exit. The app treats any hold whose process is still alive as a reason
// to stay awake, in ANY mode. A crashed wrapper leaves a stale file, so holds
// are validated with kill(pid, 0) and swept.

struct Hold: Identifiable {
    let pid: Int32
    let label: String
    var id: Int32 { pid }
}

func ensureHoldsDir() {
    try? FileManager.default.createDirectory(atPath: holdsDir,
                                             withIntermediateDirectories: true)
}

func activeHolds() -> [Hold] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: holdsDir) else { return [] }
    var holds: [Hold] = []
    for f in files where f.hasSuffix(".hold") {
        let path = holdsDir + "/" + f
        guard let pid = Int32(f.replacingOccurrences(of: ".hold", with: "")) else {
            try? fm.removeItem(atPath: path); continue
        }
        // kill(pid, 0) == 0 means the process still exists.
        if kill(pid, 0) != 0 {
            try? fm.removeItem(atPath: path)   // sweep stale hold
            continue
        }
        let label = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "command"
        holds.append(Hold(pid: pid, label: label.isEmpty ? "command" : label))
    }
    return holds
}

// `lidkeep --sleep` leaves this flag so the Mac sleeps once the command exits.
func consumeSleepRequest() -> Bool {
    if FileManager.default.fileExists(atPath: sleepRequestPath) {
        try? FileManager.default.removeItem(atPath: sleepRequestPath)
        return true
    }
    return false
}

// Used by the watchdog: is a process matching this needle still alive?
func anyProcessMatching(_ needle: String) -> Bool {
    let n = needle.lowercased()
    return sampleProcesses().contains { $0.argv.lowercased().contains(n) }
}
