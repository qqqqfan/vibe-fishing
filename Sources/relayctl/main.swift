import Foundation
import CryptoKit
import Darwin

// A tiny local hook sink. Never copy prompts, tool arguments, or transcripts to disk.
private enum BridgeError: Error { case invalidInput, unsafePath, io, busy, tooLarge }
private let inputLimit = 1_048_576
private let processStarted = Date().timeIntervalSince1970
private let terminalStates: Set<String> = ["completed", "failed", "cancelled"]
private let validStates: Set<String> = ["idle", "running", "needsInput", "completed", "failed", "cancelled", "unknown"]

private struct Event: Codable {
    let id: String
    let source: String
    let session_id: String
    let turn_id: String
    let state: String
    let timestamp: Double
}

private struct SessionMetadata: Codable {
    var turnID: String
    var state: String
    var lastTimestamp: Double
    var retiredTurnHashes: [String]
}

private func digest(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func identifier(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return value
}

private func readInput() throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.65
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw BridgeError.busy }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(remaining * 1_000))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw BridgeError.busy }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 { return result }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw BridgeError.io }
        guard result.count + count <= inputLimit else { throw BridgeError.tooLarge }
        result.append(contentsOf: buffer.prefix(count))
    }
}

private func ensureDirectory(_ path: String) throws {
    var details = stat()
    if lstat(path, &details) != 0 {
        guard errno == ENOENT else { throw BridgeError.io }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard lstat(path, &details) == 0 else { throw BridgeError.io }
    }
    guard (details.st_mode & S_IFMT) == S_IFDIR, details.st_uid == getuid() else { throw BridgeError.unsafePath }
    guard chmod(path, 0o700) == 0 else { throw BridgeError.io }
}

private func inboxPath() throws -> String {
    if let override = ProcessInfo.processInfo.environment["MOYU_RELAY_INBOX"] {
        guard override.hasPrefix("/"), !override.contains("\0") else { throw BridgeError.unsafePath }
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL.path
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MoyuRelay/inbox", isDirectory: true).path
}

private func writeAtomically<T: Encodable>(_ object: T, to destination: String) throws {
    let data = try JSONEncoder().encode(object)
    let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
    let temporary = parent + "/.tmp-" + UUID().uuidString
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw BridgeError.io }
    defer { close(fd); unlink(temporary) }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError.io }
            offset += count
        }
    }
    guard rename(temporary, destination) == 0 else { throw BridgeError.io }
}

private func readMetadata(_ path: String) throws -> SessionMetadata? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 && errno == ENOENT { return nil }
    guard fd >= 0 else { throw BridgeError.unsafePath }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, (details.st_mode & S_IFMT) == S_IFREG,
          details.st_uid == getuid(), details.st_size <= 131_072 else { throw BridgeError.unsafePath }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let data = try handle.readToEnd() ?? Data()
    // Corrupt metadata must not reset a live session and re-activate a stale turn.
    return try JSONDecoder().decode(SessionMetadata.self, from: data)
}

private func withSessionLock<T>(_ path: String, body: () throws -> T) throws -> T {
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw BridgeError.unsafePath }
    defer { close(fd) }
    var details = stat()
    guard fstat(fd, &details) == 0, (details.st_mode & S_IFMT) == S_IFREG,
          details.st_uid == getuid(), fchmod(fd, 0o600) == 0 else { throw BridgeError.unsafePath }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.15
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError.io }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeError.busy }
        usleep(1_000)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
}

private func hook(_ source: String) throws {
    guard source == "codex" || source == "claude" else { throw BridgeError.invalidInput }
    let data = try readInput()
    guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = identifier(input["hook_event_name"]),
          let session = identifier(input["session_id"]) else { throw BridgeError.invalidInput }

    // agent_type alone can also describe Claude's main --agent; agent_id identifies children.
    guard !name.hasPrefix("Subagent"), input["agent_id"] == nil || input["agent_id"] is NSNull,
          input["agent_transcript_path"] == nil || input["agent_transcript_path"] is NSNull else { return }
    let mapping = ["UserPromptSubmit": "running", "Stop": "completed", "PermissionRequest": "needsInput",
                   "Notification": "needsInput",
                   "Interrupt": "cancelled", "StopFailure": "failed", "SessionEnd": "cancelled", "PostToolUse": "running"]
    guard let nextState = mapping[name] else { return }
    guard !(source == "codex" && name == "StopFailure"), !(source == "claude" && name == "Interrupt") else { return }
    let explicitTurn = identifier(input["turn_id"]) ?? (source == "claude" ? identifier(input["prompt_id"]) : nil)
    let inbox = try inboxPath()
    try ensureDirectory(inbox)
    let metadataDirectory = inbox + "/.state"
    try ensureDirectory(metadataDirectory)
    let key = digest(source + "\0" + session)
    try withSessionLock(metadataDirectory + "/" + key + ".lock") {
        let metadataPath = metadataDirectory + "/" + key + ".json"
        var previous = try readMetadata(metadataPath)
        if let previous, processStarted < previous.lastTimestamp { return }

        var turn = explicitTurn
        if name == "UserPromptSubmit" {
            // Codex's root turn ID is required; never infer a root turn from a tool event.
            if source == "codex" && turn == nil { return }
            if turn == nil { turn = UUID().uuidString }
        } else {
            guard let prior = previous else { return }
            if let turn, turn != prior.turnID { return }
            turn = prior.turnID
            if terminalStates.contains(prior.state) { return }
            if name == "PostToolUse" && prior.state != "needsInput" { return }
        }
        guard let turn else { return }
        let turnHash = digest(turn)
        if name == "UserPromptSubmit", let prior = previous {
            if prior.retiredTurnHashes.contains(turnHash) || prior.turnID == turn { return }
        }
        if previous?.turnID == turn && previous?.state == nextState { return }
        var retired = previous?.retiredTurnHashes ?? []
        if let prior = previous, prior.turnID != turn { retired.append(digest(prior.turnID)) }
        retired = Array(retired.suffix(256))
        let timestamp = max(Date().timeIntervalSince1970, (previous?.lastTimestamp ?? 0) + 0.000001)
        previous = SessionMetadata(turnID: turn, state: nextState, lastTimestamp: timestamp, retiredTurnHashes: retired)
        try writeAtomically(previous!, to: metadataPath)
        let event = Event(id: UUID().uuidString, source: source, session_id: session,
                          turn_id: turn, state: nextState, timestamp: timestamp)
        try writeAtomically(event, to: inbox + "/" + event.id + ".json")
    }
}

private func emit(_ args: [String]) throws {
    guard args.count == 8 else { throw BridgeError.invalidInput }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: args.count, by: 2) { values[args[index]] = args[index + 1] }
    // Any agent that can run a command at turn start and end can bridge here.
    guard let source = identifier(values["--source"]), let state = values["--state"], validStates.contains(state),
          let session = identifier(values["--session"]), let turn = identifier(values["--turn"]) else { throw BridgeError.invalidInput }
    let inbox = try inboxPath()
    try ensureDirectory(inbox)
    let event = Event(id: UUID().uuidString, source: source, session_id: session,
                      turn_id: turn, state: state, timestamp: Date().timeIntervalSince1970)
    try writeAtomically(event, to: inbox + "/" + event.id + ".json")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "hook" {
    // A hook is observational: failures must never block or approve Agent work.
    do {
        guard arguments.count == 2 else { throw BridgeError.invalidInput }
        try hook(arguments[1])
    } catch { /* Deliberately do not echo input or paths into the Agent transcript. */ }
    print("{}")
    exit(0)
} else if arguments.first == "emit" {
    do { try emit(Array(arguments.dropFirst())); print("{}") }
    catch { fputs("relayctl: invalid event or unavailable inbox\n", stderr); exit(1) }
} else {
    print("relayctl hook codex|claude\nrelayctl emit --source <name> --state running|completed|needsInput|failed|cancelled --session <id> --turn <id>")
    exit(arguments.isEmpty || arguments.first == "--help" ? 0 : 1)
}
