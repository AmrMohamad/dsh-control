import Foundation

/// One validated command invocation; option flags and stdin are alternative request sources.
public struct CommandOptions {
    public let command: String
    public var port = 9222
    public var timeout: TimeInterval = 10
    public var app = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
    public var state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/dsh-control")
    public var home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
    public var request: JSONValue

    public static let allowed: [String: Set<String>] = [
        "inspect": ["session", "compact", "fields", "controls"],
        "read": ["session", "lastAssistant", "turn", "since", "full", "out"],
        "status": ["session"], "changes": ["session", "turn", "diff"],
        "draft": ["expect", "text", "session"], "click": ["expect", "ref", "session"],
        "send": ["expect", "requestId", "session", "file", "longBrief", "allowSlash", "allowReferences"],
        "send-and-wait": ["expect", "requestId", "session", "file", "longBrief", "allowSlash", "allowReferences", "retryTransient", "until"],
        "cancel": ["expect", "session", "includeSubagents"], "scroll": ["expect", "session", "direction"],
        "wait": ["session", "anchor", "context", "requestId", "turn", "inputId", "followSession", "retryTransient", "until"],
        "receipt": ["requestId", "reconcile"],
        "new-session": ["expect", "requestId", "workspace", "workspaceId", "cwd", "title"],
        "select-session": ["expect", "id", "title"], "release-session": ["expect", "id", "requestId"],
        "add-workspace": ["expect", "path"], "set-model": ["expect", "session", "model", "provider", "effort"],
        "set-access-mode": ["expect", "session", "mode", "confirmRisk"], "start": [], "quit": []
    ]
    private static let booleanFlags: [String: String] = [
        "--compact": "compact", "--full": "full", "--last-assistant": "lastAssistant", "--diff": "diff",
        "--reconcile": "reconcile", "--follow-session": "followSession", "--include-subagents": "includeSubagents",
        "--allow-slash": "allowSlash", "--allow-references": "allowReferences", "--confirm-risk": "confirmRisk"
    ]
    private static let valueFlags: [String: String] = [
        "--session": "session", "--expect": "expect", "--request-id": "requestId", "--text": "text", "--ref": "ref",
        "--direction": "direction", "--anchor": "anchor", "--input-id": "inputId", "--turn": "turn", "--since": "since",
        "--fields": "fields", "--controls": "controls", "--out": "out", "--file": "file", "--long-brief": "longBrief",
        "--retry-transient": "retryTransient", "--workspace": "workspace", "--workspace-id": "workspaceId", "--cwd": "cwd",
        "--title": "title", "--id": "id", "--model": "model", "--provider": "provider", "--effort": "effort", "--mode": "mode",
        "--until": "until"
    ]
    /// The only non-default wait boundary; absence keeps the exact-turn contract.
    public static let idleUntil = "idle"

    public init(arguments: [String], stdin: Data? = nil) throws {
        guard let command = arguments.first, let allowed = Self.allowed[command] else { throw ControlError(code: "usage", message: "Unknown command. Run dsh-control --help.") }
        self.command = command
        var values: [String: JSONValue] = [:]
        var seen = Set<String>()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ControlError(code: "usage", message: "Repeated option: \(flag).") }
            if let key = Self.booleanFlags[flag] { values[key] = .bool(true); index += 1; continue }
            if command == "add-workspace", !flag.hasPrefix("-"), values["path"] == nil {
                values["path"] = .string(flag); index += 1; continue
            }
            guard index + 1 < arguments.count else { throw ControlError(code: "usage", message: "Option requires a value: \(flag).") }
            let value = arguments[index + 1]
            switch flag {
            case "--port":
                guard let number = Int(value), (1...65535).contains(number) else { throw ControlError(code: "usage", message: "Port must be 1–65535.") }
                port = number
            case "--timeout":
                guard let number = Double(value), number.isFinite, number > 0, number <= 3600 else { throw ControlError(code: "usage", message: "Timeout must be positive and at most 3600 seconds.") }
                timeout = number
            case "--app": app = URL(fileURLWithPath: value)
            case "--state-dir": state = URL(fileURLWithPath: value)
            case "--dsh-home": home = URL(fileURLWithPath: value)
            default:
                guard let key = Self.valueFlags[flag] else { throw ControlError(code: "usage", message: "Unknown option: \(flag).") }
                if ["turn", "retryTransient"].contains(key) {
                    guard let number = Int(value), number >= 0, number <= 1_000_000 else { throw ControlError(code: "usage", message: "\(flag) requires a nonnegative bounded integer.") }
                    values[key] = .number(Double(number))
                } else { values[key] = .string(value) }
            }
            index += 2
        }
        if let stdin, !stdin.isEmpty {
            guard values.isEmpty, stdin.count <= 1_048_576, let decoded = try? JSONValue(parseData: stdin), let object = decoded.object else {
                throw ControlError(code: "invalid_request", message: "Use one JSON object (at most 1 MiB) or request flags, not both.")
            }
            values = object
        }
        guard Set(values.keys).isSubset(of: allowed) else { throw ControlError(code: "invalid_request", message: "Unknown fields for \(command): \(Set(values.keys).subtracting(allowed).sorted().joined(separator: ", ")).") }
        for (key, value) in values {
            if Self.booleanFlags.values.contains(key) {
                guard value.bool != nil else { throw ControlError(code: "invalid_request", message: "\(key) must be boolean.") }
            } else if ["turn", "retryTransient"].contains(key) {
                guard let number = value.number, number >= 0, number <= 1_000_000, number.rounded() == number else { throw ControlError(code: "invalid_request", message: "\(key) must be a nonnegative integer.") }
            } else if key == "context" {
                guard value.object != nil else { throw ControlError(code: "invalid_request", message: "context must be a guard object.") }
            } else if value.string == nil { throw ControlError(code: "invalid_request", message: "\(key) must be a string.") }
        }
        let required: [String: [String]] = ["draft": ["expect", "text"], "click": ["expect", "ref"], "send": ["expect", "requestId"], "send-and-wait": ["expect", "requestId"], "cancel": ["expect"], "scroll": ["expect", "direction"], "receipt": ["requestId"], "new-session": ["expect", "requestId"], "select-session": ["expect"], "release-session": ["expect", "id", "requestId"], "add-workspace": ["expect", "path"], "set-model": ["expect", "model"], "set-access-mode": ["expect", "mode"]]
        for key in required[command] ?? [] {
            guard let value = values[key]?.string, key == "text" || !value.isEmpty else { throw ControlError(code: "invalid_request", message: "Missing string field: \(key).") }
        }
        guard values["turn"] == nil || values["since"] == nil else { throw ControlError(code: "usage", message: "--turn and --since are mutually exclusive.") }
        if let until = values["until"] {
            guard until.string == Self.idleUntil else { throw ControlError(code: "invalid_request", message: "until supports only \"idle\".") }
            guard values["turn"] == nil else { throw ControlError(code: "usage", message: "An exact --turn cannot also wait for idle; choose one completion scope.") }
            if command == "wait", values["session"] == nil {
                guard let bound = values["context"]?["conversationSession"]?.string, !bound.isEmpty else {
                    throw ControlError(code: "usage", message: "--until idle requires --session ID or a legacy context with a nonempty conversationSession.")
                }
            }
        }
        if command == "wait" {
            let selectors = ["requestId", "inputId", "turn"].filter { values[$0] != nil }
            guard selectors.count <= 1 else { throw ControlError(code: "usage", message: "Choose one wait selector: requestId, inputId or turn.") }
        }
        guard values["longBrief"] == nil || ["attach", "reference"].contains(values["longBrief"]?.string ?? "") && values["file"] != nil else { throw ControlError(code: "usage", message: "--long-brief attach|reference requires --file.") }
        self.request = .object(values)
    }
}
