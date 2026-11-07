import Foundation

/// One-click hook setup for command-line agents. Only adds or removes handlers
/// tagged "# MoyuRelay"; every other setting is left as it was, and the file is
/// backed up before the first change. Never runs without an explicit click.
@MainActor
final class HookInstaller: ObservableObject {
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var displayName: String { self == .claude ? "Claude Code" : "Codex 命令行" }
        var events: [String] {
            switch self {
            case .claude: return ["UserPromptSubmit", "Stop", "Notification", "PostToolUse", "SessionEnd"]
            case .codex: return ["UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", "Interrupt", "SessionEnd"]
            }
        }
        var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(self == .claude ? ".claude" : ".codex") }
        var configURL: URL { directory.appendingPathComponent(self == .claude ? "settings.json" : "hooks.json") }
        var activationNote: String {
            self == .claude ? "新开会话后生效。" : "Codex 可能需要确认一次。"
        }
    }

    enum Status: Equatable { case notDetected, available, installed, broken }

    static let marker = " # MoyuRelay"
    /// Tagged handlers, plus untagged ones written by hand before one-click
    /// setup existed (`.../relayctl hook codex`). Nothing else is touched.
    private static let legacyPattern = try! NSRegularExpression(pattern: "relayctl'?\\s+hook\\s+(codex|claude)\\b")
    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix(marker)
            || legacyPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }
    @Published private(set) var statuses: [Agent: Status] = [:]
    @Published private(set) var message = ""
    private let dataDirectory: URL

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        refresh()
    }

    /// A copy outside the app bundle, so moving or updating the app never breaks
    /// a configured hook and its command line never changes.
    var stableRelayctl: URL { dataDirectory.appendingPathComponent("bin/relayctl") }

    var offers: [Agent] { Agent.allCases.filter { statuses[$0] == .available || statuses[$0] == .broken } }

    func refresh() {
        _ = try? refreshStableRelayctl()
        var next: [Agent: Status] = [:]
        for agent in Agent.allCases { next[agent] = status(of: agent) }
        statuses = next
    }

    func install(_ agent: Agent) {
        do {
            let executable = try refreshStableRelayctl()
            var root = try readConfig(agent)
            root = try merged(root, removingOursAndAdding: handlers(agent, executable: executable))
            try write(root, to: agent)
            message = "已接入 \(agent.displayName)。\(agent.activationNote)"
        } catch {
            message = "未能接入 \(agent.displayName)：\(error.localizedDescription)。配置未修改。"
        }
        refresh()
    }

    /// For app removal: strip every relay handler, report failures.
    func uninstallAll() -> [String] {
        var failures: [String] = []
        for agent in Agent.allCases where statuses[agent] == .installed || statuses[agent] == .broken {
            do {
                try write(try merged(try readConfig(agent), removingOursAndAdding: [:]), to: agent)
            } catch {
                failures.append(agent.displayName)
            }
        }
        refresh()
        return failures
    }

    func uninstall(_ agent: Agent) {
        do {
            let root = try merged(try readConfig(agent), removingOursAndAdding: [:])
            try write(root, to: agent)
            message = "已移除 \(agent.displayName)。"
        } catch {
            message = "未能移除：\(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Private

    private func status(of agent: Agent) -> Status {
        guard FileManager.default.fileExists(atPath: agent.directory.path) else { return .notDetected }
        guard let root = try? readConfig(agent), let hooks = root["hooks"] as? [String: Any] else { return .available }
        let commands = hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["command"] as? String }.filter(Self.isOurs)
        guard !commands.isEmpty else { return .available }
        // Healthy if every tagged command points at a relayctl that exists.
        let healthy = commands.allSatisfy { command in
            guard let path = Self.executablePath(in: command) else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return healthy ? .installed : .broken
    }

    @discardableResult
    private func refreshStableRelayctl() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayctl")
        let target = stableRelayctl
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            if FileManager.default.isExecutableFile(atPath: target.path) { return target }
            throw NSError(domain: "MoyuRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用内缺少 relayctl"])
        }
        if let current = try? Data(contentsOf: target), let fresh = try? Data(contentsOf: bundled), current == fresh {
            return target
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staging = target.deletingLastPathComponent().appendingPathComponent(".relayctl-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: bundled, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
        return target
    }

    private func handlers(_ agent: Agent, executable: URL) -> [String: [[String: Any]]] {
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' hook \(agent.rawValue)" + Self.marker
        var result: [String: [[String: Any]]] = [:]
        for event in agent.events {
            result[event] = [["hooks": [["type": "command", "command": command, "timeout": 2] as [String: Any]]]]
        }
        return result
    }

    private func readConfig(_ agent: Agent) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: agent.configURL.path) else { return [:] }
        let data = try Data(contentsOf: agent.configURL)
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MoyuRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "配置文件不是 JSON 对象"])
        }
        return root
    }

    /// Removes only our tagged handlers, then appends `additions`.
    private func merged(_ root: [String: Any], removingOursAndAdding additions: [String: [[String: Any]]]) throws -> [String: Any] {
        var root = root
        var hooks: [String: Any]
        if let existing = root["hooks"] {
            guard let dictionary = existing as? [String: Any] else {
                throw NSError(domain: "MoyuRelay", code: 3, userInfo: [NSLocalizedDescriptionKey: "现有 hooks 字段格式无法识别"])
            }
            hooks = dictionary
        } else { hooks = [:] }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                throw NSError(domain: "MoyuRelay", code: 4, userInfo: [NSLocalizedDescriptionKey: "现有 \(event) 设置格式无法识别"])
            }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                var group = group
                let remaining = handlers.filter { !(($0["command"] as? String).map(Self.isOurs) ?? false) }
                guard !remaining.isEmpty else { return nil }
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for (event, groups) in additions {
            hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    private func write(_ root: [String: Any], to agent: Agent) throws {
        let url = agent.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fm = FileManager.default
        var permissions: NSNumber = 0o600
        if fm.fileExists(atPath: url.path) {
            permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber) ?? 0o600
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".moyu-backup-" + Self.stamp() + "-" + UUID().uuidString.prefix(6))
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// First word of the command, honouring single quotes.
    private static func executablePath(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'") {
            let body = trimmed.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[..<end])
        }
        if trimmed.hasPrefix("/usr/bin/env") { return trimmed.split(separator: " ").first { $0.hasSuffix("relayctl") }.map(String.init) }
        return trimmed.split(separator: " ").first.map(String.init)
    }
}
