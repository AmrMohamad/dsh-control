import Foundation
import Darwin

extension SessionStore {
    func optionalSnapshot(sessionID: String) throws -> JSONValue? {
        do { return try snapshot(sessionID: sessionID) }
        catch let error as ControlError where ["session_not_found", "session_pending"].contains(error.code) { return nil }
    }

    func optionalAdmission(_ submission: JSONValue) throws -> JSONValue? {
        guard let id = submission["sessionId"]?.string, let cursor = submission["cursor"], cursor != .null,
              let digest = submission["digest"]?.string else { return nil }
        do {
            guard let evidence = try admission(sessionID: id, after: cursor, digest: digest, operation: submission["operation"]?.string ?? "send", referenceMention: submission["nativeFileReference"]?["mention"]?.string) else { return nil }
            if let files = submission["attachments"]?.array {
                let observed = evidence["references"]?.array ?? []
                guard files.allSatisfy({ file in observed.contains { ref in
                    ref["type"]?.string == "file" && ref["attachment"]?["attachmentId"]?.string == "sha256:" + (file["sha256"]?.string ?? "") && ref["attachment"]?["bytes"] == file["bytes"]
                } }) else { return nil }
            }
            return evidence
        }
        catch let error as ControlError where ["session_not_found", "session_pending", "session_store_busy"].contains(error.code) { return nil }
    }
}

/// Output selection does not alter the guarded state used to authorize GUI input.
public enum ObservationOutput {
    public static func inspect(_ state: JSONValue, compact: Bool = false, fields: String? = nil, controls: String? = nil) throws -> JSONValue {
        var value = state.object ?? [:]
        if let controls {
            guard ["composer", "sidebar", "messages"].contains(controls) else { throw ControlError(code: "usage", message: "Controls must be composer, sidebar or messages.") }
            value["controls"] = .array((value["controls"]?.array ?? []).filter { $0["group"]?.string == controls })
        }
        if compact {
            let names: Set<String> = ["expect", "guard", "targetId", "appVersion", "session", "workspace", "draft", "composer", "running", "status", "turnState", "subagents", "queue", "model", "access", "usage", "capabilities", "viewKind", "surface", "displayedSessionId", "uiAvailable", "observation", "cursor", "pendingInteractions"]
            value = value.filter { names.contains($0.key) }
            if let usage = value["usage"]?.array { value["usage"] = .object(["reportedMessages": .number(Double(usage.count)), "lastReported": usage.last ?? .null]) }
        }
        if let fields {
            let selected = fields.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !selected.isEmpty, selected.allSatisfy({ !$0.isEmpty && value[$0] != nil }) else {
                throw ControlError(code: "usage", message: "Fields must name existing top-level result fields.")
            }
            value = value.filter { selected.contains($0.key) }
        }
        return .object(value)
    }

    public static func status(_ state: JSONValue) -> JSONValue {
        let names: Set<String> = ["session", "workspace", "running", "turnState", "subagents", "queue", "usage", "model", "access", "observation", "cursor", "pendingInteractions"]
        var values = (state.object ?? [:]).filter { names.contains($0.key) }
        if let usage = values["usage"]?.array { values["usage"] = .object(["reportedMessages": .number(Double(usage.count)), "lastReported": usage.last ?? .null]) }
        values["turnCount"] = .number(Double(state["turns"]?.array?.count ?? 0))
        return .object(values)
    }

    /// Publish without replacing an existing destination; partial writes never become a successful report.
    public static func save(_ value: JSONValue, to url: URL) throws -> JSONValue {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".dsh-report-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlError(code: "output_file", message: "Cannot create report in the destination directory.") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        var data = try value.encoded(); data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ControlError(code: "output_file", message: "Report write failed.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, link(temporary.path, url.path) == 0 else {
            throw ControlError(code: "output_file", message: "Cannot publish report; destination may already exist.")
        }
        return .object(["out": .string(url.path), "bytes": .number(Double(data.count)), "session": value["session"] ?? .null,
                        "cursor": value["cursor"] ?? .null, "observation": value["observation"] ?? .null])
    }
}

/// A wait follows durable input identity and never takes the GUI mutation lock.
public enum SessionWaiter {
    public static func wait(store: SessionStore, sessionID: String, inputID: String? = nil, turn requestedTurn: JSONValue? = nil, commandID: String? = nil,
                            timeout: TimeInterval, retryTransient: Int = 3) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var input = inputID
        var turn = requestedTurn
        var failures = 0
        var last: JSONValue = .null
        while true {
            do {
                let state = try store.snapshot(sessionID: sessionID)
                last = state
                if let commandID, let finished = state["commands"]?.array?.first(where: { $0["type"]?.string == "command/done" && $0["data"]?["commandId"]?.string == commandID }) {
                    return .object(["outcome": .string("command_settled"), "commandId": .string(commandID),
                        "result": finished["data"] ?? .null, "state": ObservationOutput.status(state)])
                }
                if commandID == nil {
                let users = (state["messages"]?.array ?? []).filter { $0["kind"]?.string == "user" }
                if let input, let turn, let message = users.first(where: { $0["inputId"]?.string == input }), message["turn"] != .null, message["turn"] != turn {
                    throw ControlError(code: "invalid_anchor", message: "Input and turn refer to different work.", outcome: "unknown")
                }
                if input != nil && requestedTurn != nil && !users.contains(where: { $0["inputId"]?.string == input && $0["turn"] == turn }) {
                    throw ControlError(code: "invalid_anchor", message: "The requested input does not identify this turn.", outcome: "unknown")
                }
                if input == nil && turn == nil { input = users.last?["inputId"]?.string }
                if turn == nil, let input {
                    turn = users.first { $0["inputId"]?.string == input }?["turn"]
                    if turn == .null { turn = nil }
                }
                if let turn, let result = state["turns"]?.array?.first(where: { $0["turn"] == turn && $0["ended"]?.bool == true }) {
                    return .object(["outcome": .string(result["reason"]?["kind"]?.string == "completed" ? "settled" : "terminated"),
                        "reason": result["reason"] ?? .null, "sessionId": .string(sessionID), "turn": turn,
                        "reply": try store.read(sessionID: sessionID, lastAssistant: true, turn: turn, full: true), "state": ObservationOutput.status(state)])
                }
                }
                if state["pendingApprovals"]?.array?.isEmpty == false || state["pendingQuestions"]?.array?.isEmpty == false {
                    return .object(["outcome": .string("blocked"), "reason": .string("recorded_pending_interaction"), "state": ObservationOutput.status(state)])
                }
            } catch let error as ControlError {
                if ["session_pending", "session_not_found"].contains(error.code) {
                    last = .object(["pending": .string(error.code)])
                } else if error.code == "session_store_busy", failures < retryTransient {
                    failures += 1
                } else { throw ControlError(code: error.code, message: error.message, outcome: "unknown", details: error.details) }
            }
            if clock.now >= deadline {
                throw ControlError(code: "wait_timeout", message: "The bound turn has not been confirmed terminal. No input was retried.", outcome: "unknown", details: last)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

extension SendReceipts {
    /// Caller holds MutationLock only for this small evidence update, never throughout a long wait.
    public func reconcile(requestID: String, store: SessionStore, stateDirectory: URL? = nil) throws -> JSONValue {
        guard let record = try lookup(requestID: requestID) else { return .object(["receipt": .null]) }
        guard record["version"] == .number(2), let submission = record["submission"],
              ["prepared", "uncertain"].contains(record["status"]?.string ?? "") else {
            return .object(["receipt": record, "reconciled": .bool(false), "reason": .string("no_reconcilable_evidence")])
        }
        guard let evidence = try store.optionalAdmission(submission) else {
            return .object(["receipt": record, "reconciled": .bool(false), "reason": .string("matching_admission_not_observed")])
        }
        let lock = try stateDirectory.map { try MutationLock(directory: $0) }
        defer { withExtendedLifetime(lock) {} }
        if let current = try lookup(requestID: requestID), current["status"]?.string == "sent" {
            return .object(["receipt": current, "reconciled": .bool(true)])
        }
        var values = record.object!
        values["status"] = .string("sent"); values["outcome"] = .string("verified"); values["verification"] = evidence
        let updated = JSONValue.object(values)
        try finish(requestID: requestID, receipt: updated)
        return .object(["receipt": updated, "reconciled": .bool(true)])
    }
}
