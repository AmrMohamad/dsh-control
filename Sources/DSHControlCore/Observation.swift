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
            let names: Set<String> = ["expect", "guard", "targetId", "appVersion", "session", "workspace", "draft", "composer", "running", "status", "turnState", "subagents", "subagentActivity", "queue", "model", "access", "usage", "capabilities", "viewKind", "surface", "displayedSessionId", "uiAvailable", "observation", "cursor", "pendingInteractions"]
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
                        "completionScope": .string("turn"),
                        "reply": try store.read(sessionID: sessionID, lastAssistant: true, turn: turn, full: true), "state": ObservationOutput.status(state)])
                }
                }
                if state["pendingApprovals"]?.array?.isEmpty == false || state["pendingQuestions"]?.array?.isEmpty == false {
                    return .object(["outcome": .string("blocked"), "reason": .string("recorded_pending_interaction"),
                        "completionScope": .string("turn"), "state": ObservationOutput.status(state)])
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

    /// Read-only, exact-session runtime observation. The closure receives the remaining wait budget
    /// and must use the bounded GUI inspect path, never a mutation, navigation or application API.
    public typealias IdleRuntimeObservation = (String, TimeInterval) async throws -> JSONValue

    /// Observed idle waits for a live-session quiescence signal and then returns the last turn
    /// attributable to the bound input. A recorded turn end alone is never treated as idle.
    /// Missing, external or otherwise unobservable child evidence is reported as unavailable
    /// rather than counted as zero active children.
    public static func waitForIdle(store: SessionStore, sessionID: String, inputID: String? = nil,
                                   turn requestedTurn: JSONValue? = nil, timeout: TimeInterval,
                                   retryTransient: Int = 3,
                                   runtime: IdleRuntimeObservation?) async throws -> JSONValue {
        guard let runtime else {
            throw ControlError(code: "idle_unavailable",
                message: "Observing idle needs a trusted, running GUI observation connection. The default exact-turn wait remains available without it.",
                outcome: "unknown")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var input = inputID
        var turn = requestedTurn
        var failures = 0
        var last: JSONValue = .null
        var lastRuntime: JSONValue = .null
        var scopedRuntimeObserved = false
        var runtimeAttempted = false
        while true {
            var candidate: JSONValue?
            var observedBusy = false
            var idleEvidenceIncomplete = false
            do {
                let state = try store.snapshot(sessionID: sessionID)
                last = state
                let stateCursor = state["cursor"]
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
                if state["pendingApprovals"]?.array?.isEmpty == false || state["pendingQuestions"]?.array?.isEmpty == false {
                    return .object(["outcome": .string("blocked"), "reason": .string("recorded_pending_interaction"),
                        "completionScope": .string("turn"), "until": .string("idle"), "state": ObservationOutput.status(state)])
                }
                let queue = state["queue"]?.object ?? [:]
                let queued = (queue["next-turn"]?.array?.count ?? 0) + (queue["next-step"]?.array?.count ?? 0)
                if state["running"] != .bool(false) || queued > 0 {
                    // Parent activity or queued input: observed busy, never idle.
                    observedBusy = true
                } else if let boundTurn = turn, let originalTurn = boundTurn.number {
                    var observed: JSONValue?
                    runtimeAttempted = true
                    do {
                        let value = try await runtime(sessionID, Self.remaining(until: deadline))
                        lastRuntime = value
                        observed = value
                    } catch let error as ControlError {
                        lastRuntime = .object(["error": .string(error.code), "message": .string(error.message)])
                    }
                    if let observed, observed["uiAvailable"]?.bool == true, observed["session"]?["id"]?.string == sessionID,
                       observed["guard"]?["conversationSession"] == nil || observed["guard"]?["conversationSession"] == .string(sessionID) {
                        scopedRuntimeObserved = true
                        if observed["pendingInteractions"]?.array?.isEmpty == false {
                            return .object(["outcome": .string("blocked"), "reason": .string("observed_pending_interaction"),
                                "completionScope": .string("turn"), "until": .string("idle"), "state": ObservationOutput.status(state)])
                        }
                        let children = childEvidence(known: state["subagents"]?.array ?? [], runtime: observed)
                        let phase = observed["guard"]?["contentPhase"]?.string
                        let settling = phase == "settling"
                        let loaded = observed["loaded"]?.bool != false && phase != "loading" && !settling
                        if settling || observed["running"]?.bool == true || children.running || children.blocked {
                            observedBusy = true
                        } else if !loaded || !children.complete || observed["running"]?.bool != false {
                            idleEvidenceIncomplete = true
                        } else if let reply = idleReplyTurn(state: state, originalTurn: originalTurn) {
                            if let boundary = reply.boundary {
                                throw ControlError(code: "scope_boundary",
                                    message: "A later human input started another turn. It is not part of this wait; no input was retried.",
                                    outcome: "unknown",
                                    details: .object(["boundary": boundary,
                                        "boundaryInputId": users.first { $0["turn"] == boundary["turn"] }?["inputId"] ?? .null,
                                        "turn": reply.turn, "completionScope": .string("turn"),
                                        "state": ObservationOutput.status(state)]))
                            }
                            // Durable history and pending state may have changed during runtime I/O.
                            // Publish only if the reply read and the checked snapshot share the opaque cursor.
                            let kind = reply.reason["kind"]?.string
                            let replyRead = try store.read(sessionID: sessionID, lastAssistant: true, turn: reply.turn, full: true)
                            // A partial final write can leave the committed cursor unchanged while the reread is
                            // pending; the current observation, running and queue fields must still authorize idle.
                            let rereadQueue = replyRead["queue"]?.object ?? [:]
                            let rereadQueued = (rereadQueue["next-turn"]?.array?.count ?? 0) + (rereadQueue["next-step"]?.array?.count ?? 0)
                            let rereadComplete = replyRead["observation"]?["complete"]?.bool == true
                                && replyRead["observation"]?["pendingTail"]?.bool != true
                                && replyRead["running"] == .bool(false) && rereadQueued == 0
                            if clock.now < deadline, stateCursor?.string != nil, replyRead["cursor"] == stateCursor, rereadComplete {
                                candidate = .object([
                                    "outcome": .string(kind == "completed" ? "settled" : "terminated"),
                                    "reason": reply.reason, "sessionId": .string(sessionID),
                                    "completionScope": .string("idle"), "turn": reply.turn,
                                    "originalTurn": boundTurn, "inputId": input.map(JSONValue.string) ?? .null,
                                    "reply": replyRead,
                                    "evidence": idleEvidence(state: state, observed: observed, children: children),
                                    "state": ObservationOutput.status(state)])
                            }
                        } else {
                            idleEvidenceIncomplete = true
                        }
                    }
                }
            } catch let error as ControlError {
                if ["session_pending", "session_not_found"].contains(error.code) {
                    last = .object(["pending": .string(error.code)])
                } else if error.code == "session_store_busy", failures < retryTransient {
                    failures += 1
                } else { throw ControlError(code: error.code, message: error.message, outcome: "unknown", details: error.details) }
            }
            if let candidate { return candidate }
            if clock.now >= deadline {
                let details = JSONValue.object(["completionScope": .string("idle"), "state": last, "runtime": lastRuntime])
                if runtimeAttempted && !scopedRuntimeObserved {
                    throw ControlError(code: "idle_unavailable",
                        message: "Live idle could not be established from supported, exact-session runtime evidence. No input was retried.",
                        outcome: "unknown", details: details)
                }
                if idleEvidenceIncomplete && !observedBusy {
                    throw ControlError(code: "idle_unavailable",
                        message: "Idle evidence was incomplete: unknown or unobservable child/runtime state is not counted as idle. No input was retried.",
                        outcome: "unknown", details: details)
                }
                throw ControlError(code: "wait_timeout",
                    message: "Observed activity did not reach idle before the deadline. No input was retried.",
                    outcome: "unknown", details: details)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Remaining budget for one observation; never a fresh per-observation timeout.
    private static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return max(0.001, seconds)
    }

    /// Select the last completed turn attributable to the original input, stopping at a later human turn.
    private static func idleReplyTurn(state: JSONValue, originalTurn: Double) -> (turn: JSONValue, reason: JSONValue, boundary: JSONValue?)? {
        let turns = (state["turns"]?.array ?? []).compactMap { row -> (number: Double, row: JSONValue)? in
            guard let number = row["turn"]?.number else { return nil }
            return (number, row)
        }.sorted { $0.number < $1.number }
        let users = (state["messages"]?.array ?? []).filter { $0["kind"]?.string == "user" }
        let humanTurns = Set(users.compactMap { $0["turn"]?.number })
        guard let original = turns.first(where: { $0.number == originalTurn }), original.row["ended"] == .bool(true),
              let originalReason = original.row["reason"], originalReason != .null else { return nil }
        let later = turns.filter { $0.number > originalTurn }
        let boundary = later.first { humanTurns.contains($0.number) }?.row
        let boundaryNumber = boundary?["turn"]?.number
        let inScope = later.filter { row in
            !humanTurns.contains(row.number) && (boundaryNumber.map { row.number < $0 } ?? true)
        }
        guard inScope.allSatisfy({ $0.row["ended"] == .bool(true) && $0.row["reason"] != nil && $0.row["reason"] != .null }) else { return nil }
        let selected = inScope.last?.row ?? original.row
        guard let selectedTurn = selected["turn"], let selectedReason = selected["reason"] else { return nil }
        return (selectedTurn, selectedReason, boundary)
    }

    private struct ChildEvidence {
        let complete: Bool
        let running: Bool
        let blocked: Bool
        let details: JSONValue
    }

    /// Live child evidence uses supported rendered indicators only. Catalog membership is not liveness.
    private static func childEvidence(known children: [JSONValue], runtime: JSONValue) -> ChildEvidence {
        let entries = children.compactMap { child -> (id: String, external: Bool)? in
            guard let id = child["id"]?.string else { return nil }
            return (id, child["mode"]?.string == "external")
        }
        let knownIDs = Set(entries.map(\.id))
        let external = entries.filter(\.external).map(\.id).sorted()
        var visibleIDs = Set<String>()
        var visibleRunning = false
        var visibleBlocked = false
        for child in runtime["subagents"]?.array ?? [] {
            // Presence alone is not observation: only an explicit loaded running/blocked/idle signal counts.
            guard let id = child["id"]?.string, knownIDs.contains(id), child["uiAvailable"]?.bool != false,
                  child["loaded"]?.bool != false else { continue }
            let status = child["status"]?.string
            let runningFlag = child["running"]?.bool
            let blocked = status == "blocked" || child["blocked"]?.bool == true
            let explicit = runningFlag != nil || status == "running" || status == "blocked"
            guard explicit, status != "unknown" else { continue }
            visibleIDs.insert(id)
            if runningFlag == true || status == "running" { visibleRunning = true }
            if blocked { visibleBlocked = true }
        }
        let missing = knownIDs.subtracting(visibleIDs).sorted()
        let activity = runtime["subagentActivity"]
        let aggregateAvailable = activity?["available"]?.bool == true
        let aggregateRunning = activity?["running"]?.bool == true
        let declared = activity?["declaredCount"]?.number
        var active = visibleRunning
        var complete: Bool
        var source: String
        if aggregateAvailable && aggregateRunning {
            // The displayed parent header is supported live evidence even for children absent from the catalog.
            active = true
            complete = false
            source = "aggregate_indicator"
        } else if entries.isEmpty {
            complete = true
            source = aggregateAvailable ? "aggregate_indicator" : "no_recorded_children"
        } else if !external.isEmpty {
            complete = false
            source = "external_child_unobservable"
        } else if aggregateAvailable {
            if let declared, declared >= Double(entries.count) {
                complete = !visibleBlocked
                source = "aggregate_indicator"
            } else if missing.isEmpty {
                complete = !visibleBlocked
                source = "rendered_sidebar_occurrences"
            } else {
                complete = false
                source = "aggregate_indicator_incomplete"
            }
        } else {
            complete = missing.isEmpty && !visibleRunning && !visibleBlocked
            source = "rendered_sidebar_occurrences"
        }
        let details = JSONValue.object([
            "known": .number(Double(entries.count)),
            "observed": .number(Double(visibleIDs.count)),
            "running": .bool(active),
            "blocked": .bool(visibleBlocked),
            "complete": .bool(complete),
            "source": .string(source),
            "missing": .array(missing.map(JSONValue.string)),
            "external": .array(external.map(JSONValue.string)),
            "aggregate": .object(["available": .bool(aggregateAvailable), "running": .bool(aggregateRunning),
                                  "declaredCount": declared.map { .number($0) } ?? .null]),
        ])
        return ChildEvidence(complete: complete, running: active, blocked: visibleBlocked, details: details)
    }

    private static func idleEvidence(state: JSONValue, observed: JSONValue, children: ChildEvidence) -> JSONValue {
        let queue = state["queue"]?.object ?? [:]
        return .object([
            "sources": .array([.string("released_v4_session_log"), .string("rendered_gui_occurrence")]),
            "durable": .object([
                "running": state["running"] ?? .null, "turnState": state["turnState"] ?? .null,
                "queuedInputs": .number(Double((queue["next-turn"]?.array?.count ?? 0) + (queue["next-step"]?.array?.count ?? 0))),
                "pendingInteractions": .number(Double((state["pendingApprovals"]?.array?.count ?? 0) + (state["pendingQuestions"]?.array?.count ?? 0)))]),
            "runtime": .object([
                "sessionId": observed["session"]?["id"] ?? .null, "uiAvailable": observed["uiAvailable"] ?? .null,
                "running": observed["running"] ?? .null,
                "pendingInteractions": .number(Double(observed["pendingInteractions"]?.array?.count ?? 0))]),
            "children": children.details,
            "coverage": .string("Observed idle for the exact session occurrence and its recorded direct children. External children, unrecorded descendants, child interactions that are not rendered, and later activity are not covered."),
        ])
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

public extension ControlError {
    /// A post-send wait failure keeps the already-verified send evidence; it never authorizes a resend.
    static func sendWaitFailure(_ error: Error, send: JSONValue) -> ControlError {
        let code: String, message: String
        if let error = error as? ControlError {
            code = error.code
            message = error.message
        } else if error is CancellationError {
            code = "cancelled"
            message = "The wait was cancelled after the send was verified. Read the existing receipt; do not resend."
        } else {
            code = "wait_failed"
            message = "The wait failed after the send was verified. Read the existing receipt; do not resend."
        }
        return ControlError(code: code, message: message, outcome: "unknown",
                            details: .object(["send": send, "waitError": .string(code)]))
    }
}
