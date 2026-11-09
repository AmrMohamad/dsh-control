import Foundation

/// One command's connection to the existing product page; no context or page is created.
public struct UIController {
    var cdp: CDP
    public let targetID: String
    public let version: String
    let timeout: TimeInterval

    public static func connect(application: HarnessApplication, port: Int, timeout: TimeInterval) async throws -> Self {
        try application.verifyListener(port: port)
        let commandTimeout = min(timeout, 10)  // per CDP command; `timeout` is the verification deadline
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = commandTimeout
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        // URLSession's request timer resets per received byte; bound the whole discovery instead.
        let data: Data, response: URLResponse
        do { (data, response) = try await withDeadline(seconds: commandTimeout, cancel: { session.invalidateAndCancel() }) { try await session.data(from: url) } }
        catch let error as ControlError { throw error }
        catch { throw ControlError(code: "discovery", message: "The local Chromium endpoint could not be read in time.") }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576 else {
            throw ControlError(code: "discovery", message: "The local Chromium endpoint did not return a bounded target list.")
        }
        let target = try selectProductTarget(JSONValue(parseData: data), port: port)
        return try Self(cdp: CDP(socketURL: target.socketURL, timeout: commandTimeout), targetID: target.id,
                        version: application.version, timeout: timeout)
    }

    public func close() { cdp.close() }

    public mutating func inspect(sessionID: String? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        var request: [String: JSONValue] = ["action": .string("inspect")]
        if let sessionID { request["sessionId"] = .string(sessionID) }
        var state = try Self.pageResult(try await page(request, timeout: timeout)).object ?? [:]
        guard let guardValue = state["guard"], guardValue.object != nil else {
            throw ControlError(code: "unsupported_ui", message: "The page did not return its observed UI identity.")
        }
        state["expect"] = state["uiAvailable"]?.bool == false ? .null : .string(try StateDigest.token(.object(["target": .string(targetID), "guard": guardValue])))
        state["targetId"] = .string(targetID)
        state["appVersion"] = .string(version)
        return .object(state)
    }

    /// Execute a mutation only against the inspected state. The caller holds the process lock.
    public mutating func mutate(command: String, request: JSONValue, receipts: SendReceipts,
                                store: SessionStore? = nil, signatureOverride: String? = nil, preparedReceipt: JSONValue? = nil) async throws -> JSONValue {
        let expected = try request.requireString("expect")
        let requestID = command == "send" ? try request.requireString("requestId") : nil
        let signature = try signatureOverride ?? StateDigest.token(.object(["command": .string(command), "expect": .string(expected)]))
        if preparedReceipt == nil, let requestID, let existing = try receipts.lookup(requestID: requestID) {
            guard existing["signature"]?.string == signature else {
                throw ControlError(code: "request_conflict", message: "This send ID belongs to a different inspected state. Read its receipt; do not send again.", outcome: "unknown", details: existing)
            }
            return try Self.replayResult(existing)
        }
        let before = try await inspect(sessionID: request["session"]?.string)
        guard before["expect"]?.string == expected else {
            throw ControlError(code: "stale_state", message: "The app changed since inspection; no input was dispatched.", details: before)
        }
        guard let guardValue = before["guard"] else { throw ControlError(code: "unsupported_ui", message: "No UI identity was observed.") }
        var preparation: [String: JSONValue] = ["action": .string("prepare"), "guard": guardValue, "purpose": .string(command)]
        let sessionID = before["session"]?["id"]?.string ?? guardValue["conversationSession"]?.string
        if let sessionID { preparation["sessionId"] = .string(sessionID) }
        preparation["allowSlash"] = request["allowSlash"] ?? .bool(false)
        preparation["allowReferences"] = request["allowReferences"] ?? .bool(false)
        if command == "click" { preparation["ref"] = .string(try request.requireString("ref")) }
        if command == "scroll" {
            let direction = try request.requireString("direction")
            guard ["up", "down"].contains(direction) else { throw ControlError(code: "invalid_request", message: "Scroll direction must be up or down.") }
            preparation["action"] = .string("scroll")
            preparation["direction"] = .string(direction)
        }
        let replacement = command == "draft"
            ? try request.requireString("text", allowEmpty: true).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : nil
        if let replacement, replacement.utf8.count > 200_000 {
            throw ControlError(code: "invalid_request", message: "Draft exceeds 200000 UTF-8 bytes.")
        }
        if command == "send" { try Self.requireVerifiableSend(before["draft"]?.string ?? "") }
        var submission: JSONValue? = preparedReceipt?["submission"]
        if command == "send", submission == nil, let sessionID {
            let cursor = try store?.optionalSnapshot(sessionID: sessionID)?["cursor"] ?? .null
            submission = .object(["sessionId": .string(sessionID), "cursor": cursor,
                "digest": .string(StateDigest.text(Self.normalized(before["draft"]?.string ?? ""))), "operation": .string("send")])
        }
        var record: JSONValue? = preparedReceipt
        var dispatched = preparedReceipt != nil
        do {
            if command == "scroll" {
                dispatched = true
                let value = try await page(preparation)
                dispatched = value["error"] == nil
                _ = try Self.pageResult(value)
            } else {
                var point = try Self.pageResult(try await page(preparation))
                if let requestID {
                    record = try receipts.prepare(requestID: requestID, signature: signature, targetID: targetID, submission: submission)
                    // Receipt I/O may outlast a UI change: validate again immediately before dispatch.
                    point = try Self.pageResult(try await page(preparation))
                }
                dispatched = true
                try await click(point)
                if let replacement {
                    try await key("a", code: "KeyA", virtualKey: 65, modifiers: 4, commands: ["selectAll"])
                    // Lexical learns the new selection from an async selectionchange; text inserted before it lands is dropped.
                    let readiness = try Self.pageResult(try await page(["action": .string("selectionReady"),
                        "sessionId": sessionID.map(JSONValue.string) ?? .null, "guard": guardValue]))
                    guard readiness["ready"]?.bool == true else {
                        throw ControlError(code: "selection_timeout", message: "The editor did not confirm its selection; inspect the draft before repeating.", outcome: "unknown")
                    }
                    if replacement.isEmpty { try await key("Backspace", code: "Backspace", virtualKey: 8) }
                    else { try await type(replacement) }
                }
            }
            let deadline = Date().addingTimeInterval(timeout)
            var after = try await inspect(sessionID: sessionID)
            while true {
                let evidence: JSONValue?
                if command == "send", let store, let submission, submission["cursor"] != .null {
                    evidence = try store.optionalAdmission(submission)
                } else { evidence = nil }
                // Text commands confirm only in the conversation they were inspected in.
                if ["draft", "send", "cancel"].contains(command), evidence == nil, !Self.sameIdentity(before["guard"], after["guard"]) {
                    throw ControlError(code: "conversation_changed", message: "The displayed conversation changed after input was dispatched.", outcome: "unknown", details: after)
                }
                let verified: Bool
                switch command {
                case "draft": verified = Self.sameDraft(after["draft"]?.string, replacement)
                case "send": verified = evidence != nil || submission?["attachments"] == nil && submission?["operation"]?.string == "send" && before["references"]?.array?.isEmpty != false && Self.sendConfirmed(before: before, after: after)
                case "cancel": verified = after["running"]?.bool == false
                case "click", "scroll": verified = after["expect"] != before["expect"] || after["controls"] != before["controls"] || command == "scroll"
                default: throw ControlError(code: "invalid_command", message: "Unsupported UI mutation.")
                }
                if verified {
                    if let requestID, var updated = record?.object {
                        updated["status"] = .string("sent"); updated["outcome"] = .string("verified")
                        if updated["version"] != nil { updated["verification"] = evidence ?? Self.echoEvidence(before: before, after: after) }
                        try receipts.finish(requestID: requestID, receipt: .object(updated))
                        return .object(["outcome": .string("verified"), "receipt": .object(updated), "state": after,
                            "binding": .object(["sessionId": sessionID.map(JSONValue.string) ?? .null,
                                "turn": updated["verification"]?["turn"] ?? .null, "inputId": updated["verification"]?["inputId"] ?? .null])])
                    }
                    return .object(["outcome": .string("verified"), "state": after])
                }
                if Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
                after = try await inspect(sessionID: sessionID)
            }
            throw ControlError(code: "unverified", message: "Input was dispatched but its result was not confirmed. Inspect before taking another action.", outcome: "unknown", details: after)
        } catch {
            if let requestID, var updated = record?.object {
                updated["status"] = .string(dispatched ? "uncertain" : "not_sent")
                updated["outcome"] = .string(dispatched ? "unknown" : "not_performed")
                do { try receipts.finish(requestID: requestID, receipt: .object(updated)) }
                catch { throw ControlError(code: "receipt_write", message: "Send outcome could not be saved; its prepared receipt remains uncertain.", outcome: "unknown") }
            }
            let failure = error as? ControlError
            throw ControlError(code: failure?.code ?? "transport", message: failure?.message ?? "UI command failed.",
                               outcome: dispatched ? "unknown" : (failure?.outcome ?? "not_performed"), details: failure?.details)
        }
    }

    /// Wait never locks out cancel. Missing result evidence is unverified, even when the UI is idle.
    public mutating func wait(anchor: String, context: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = try await inspect()
            guard Self.sameIdentity(context, state["guard"]) else {
                throw ControlError(code: "conversation_changed", message: "The displayed conversation changed while waiting.", details: state)
            }
            if state["status"]?.string == "blocked" {
                return .object(["outcome": .string("blocked"), "completionScope": .string("turn"), "state": state])
            }
            let messages = state["messages"]?.array ?? []
            if state["running"]?.bool == false, Self.completed(messages: messages, anchor: anchor) {
                return .object(["outcome": .string("settled"), "completionScope": .string("turn"), "state": state])
            }
            if Date() >= deadline {
                throw ControlError(code: "wait_timeout", message: "A final result was not confirmed in the rendered UI. No prompt was retried.", outcome: "unknown", details: state)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// A stored receipt succeeds only if verified; otherwise its stored outcome is surfaced and nothing is redispatched.
    static func replayResult(_ existing: JSONValue) throws -> JSONValue {
        guard existing["status"]?.string == "sent", existing["outcome"]?.string == "verified" else {
            throw ControlError(code: "replayed_receipt", message: "This send ID already has a receipt that is not verified. Do not send again.",
                               outcome: existing["outcome"]?.string == "not_performed" ? "not_performed" : "unknown", details: existing)
        }
        return .object(["replayedReceipt": .bool(true), "receipt": existing])
    }

    /// The anchor user row has a nonempty turn, and another row of that same turn holds a nonempty response.
    static func completed(messages: [JSONValue], anchor: String) -> Bool {
        guard let user = messages.first(where: { $0["key"]?.string == anchor && $0["kind"]?.string == "user" }),
              let turn = user["turn"]?.string, !turn.isEmpty else { return false }
        return messages.contains { $0["turn"]?.string == turn && $0["key"] != user["key"] &&
            ($0["answer"]?.bool == true || $0["part"]?.string == "response") && !($0["text"]?.string ?? "").isEmpty }
    }

    /// Workspace and lastUser legitimately change when a first send materializes a session, so they are not identity.
    static func sameIdentity(_ before: JSONValue?, _ after: JSONValue?) -> Bool {
        guard let before, let after else { return false }
        return ["url", "epoch", "selectedRows", "conversationSession", "surface"].allSatisfy { before[$0] == after[$0] }
    }

    public static func sendConfirmed(before: JSONValue, after: JSONValue) -> Bool {
        guard sameIdentity(before["guard"], after["guard"]) else { return false }
        let oldKeys = Set((before["messages"]?.array ?? []).compactMap { $0["key"]?.string })
        let draft = normalized(before["draft"]?.string ?? "")
        return !draft.isEmpty && after["draft"]?.string == "" && (after["messages"]?.array ?? []).contains {
            $0["kind"]?.string == "user" && !oldKeys.contains($0["key"]?.string ?? "") && $0["bodyTruncated"]?.bool != true
                && ($0["body"]?.string).map(normalized) == draft
        }
    }

    static func echoEvidence(before: JSONValue, after: JSONValue) -> JSONValue {
        let oldKeys = Set((before["messages"]?.array ?? []).compactMap { $0["key"]?.string })
        let row = (after["messages"]?.array ?? []).first { $0["kind"]?.string == "user" && !oldKeys.contains($0["key"]?.string ?? "") && ($0["body"]?.string).map(normalized) == normalized(before["draft"]?.string ?? "") }
        var evidence: [String: JSONValue] = ["verifiedBy": .string("transcript_match"), "anchor": row?["key"] ?? .null]
        // rc.3's Context key is kind.length + ':' + kind + the exact input identity.
        if let key = row?["key"]?.string, key.hasPrefix("13:input-message"), key.count > 16 {
            evidence["inputId"] = .string(String(key.dropFirst(16)))
        }
        if let turn = row?["turn"]?.string, let number = Double(turn) { evidence["turn"] = .number(number) }
        return .object(evidence)
    }

    static let maxVerifiableSend = 12000

    /// Observed user bodies are cut at 12000 UTF-16 units, so a longer send could never be verified.
    static func requireVerifiableSend(_ draft: String) throws {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= maxVerifiableSend else {
            throw ControlError(code: "unsupported_length", message: "Drafts over \(maxVerifiableSend) UTF-16 units cannot be verified after sending; no input was dispatched.")
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The page reports a whitespace-only draft as empty and renders a trailing line break as two newlines.
    static func sameDraft(_ observed: String?, _ requested: String?) -> Bool {
        guard let observed, let requested else { return false }
        if requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return observed.isEmpty }
        return observed == requested || (requested.hasSuffix("\n") && observed == requested + "\n")
    }

    mutating func page(_ request: [String: JSONValue], timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await cdp.evaluate(expression: "(\(PageAdapter.script))(\(String(decoding: try JSONValue.object(request).encoded(), as: UTF8.self)))", timeout: timeout)
    }

    static func pageResult(_ value: JSONValue) throws -> JSONValue {
        if let error = value["error"] {
            throw ControlError(code: error["code"]?.string ?? "ui_error", message: error["message"]?.string ?? "DOM adapter failed.")
        }
        return value
    }

    mutating func click(_ point: JSONValue) async throws {
        guard case .number(let x) = point["x"], case .number(let y) = point["y"], x.isFinite, y.isFinite else {
            throw ControlError(code: "unsupported_ui", message: "The control did not provide a verified hit target.")
        }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            _ = try await cdp.call(method: "Input.dispatchMouseEvent", params: .object([
                "type": .string(type), "x": .number(x), "y": .number(y),
                "button": .string(type == "mouseMoved" ? "none" : "left"), "clickCount": .number(type == "mouseMoved" ? 0 : 1),
            ]))
        }
    }

    /// Shift+Enter is this build's line break (the composer's Enter handler yields on Shift); Enter would submit.
    mutating func type(_ text: String) async throws {
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { try await key("Enter", code: "Enter", virtualKey: 13, modifiers: 8) }
            if !line.isEmpty { _ = try await cdp.call(method: "Input.insertText", params: .object(["text": .string(String(line))])) }
        }
    }

    mutating func key(_ key: String, code: String, virtualKey: Double, modifiers: Double = 0, commands: [String] = []) async throws {
        var params: [String: JSONValue] = ["type": .string("keyDown"), "key": .string(key), "code": .string(code),
            "windowsVirtualKeyCode": .number(virtualKey), "modifiers": .number(modifiers)]
        if !commands.isEmpty { params["commands"] = .array(commands.map(JSONValue.string)) }
        _ = try await cdp.call(method: "Input.dispatchKeyEvent", params: .object(params))
        params["type"] = .string("keyUp"); params.removeValue(forKey: "commands")
        _ = try await cdp.call(method: "Input.dispatchKeyEvent", params: .object(params))
    }
}

public extension JSONValue {
    func requireString(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = self[key]?.string, allowEmpty || !value.isEmpty else {
            throw ControlError(code: "invalid_request", message: "Expected a string field: \(key).")
        }
        return value
    }
}
