import Darwin
import Foundation
import Testing
@testable import DSHControlCore

@Test func onlyAnExactOfferedSkillOptionSelectsNativeSkillAdmission() {
    #expect(UIController.offeredNativeSkill(.object(["id": .string("dsh-slash-option-skill-0")]), draft: "/ponytail-help ") == "ponytail-help")
    #expect(UIController.offeredNativeSkill(.object(["id": .string("dsh-slash-option-command-0")]), draft: "/help ") == nil)
    #expect(UIController.offeredNativeSkill(.object(["alreadySelected": .bool(true)]), draft: "/ponytail-help ") == nil)
    #expect(UIController.offeredNativeSkill(.object(["id": .string("dsh-slash-option-skill-0-extra")]), draft: "/ponytail-help ") == nil)
}

@Test func nativeFileReferenceCannotSatisfyUploadedAttachmentReadiness() throws {
    let state: JSONValue = .object(["attachmentCount": .number(0), "attachments": .array([]),
        "draft": .string("attachment-brief.md\n "), "references": .array([.object([
            "source": .string("reference"), "title": .string("attachment-brief.md"), "text": .string("attachment-brief.md")])])])
    #expect(UIController.nativeReferenceReady(state, name: "attachment-brief.md"))
    #expect(!UIController.nativeReferenceReady(state, name: "other.md"))
    do {
        _ = try UIController.stagedAttachmentReady(state, name: "attachment-brief.md")
        Issue.record("A native filesystem mention must not count as uploaded file bytes")
    } catch let error as ControlError {
        #expect(error.code == "native_file_reference")
        #expect(error.outcome == "unknown")
    }
    #expect(try UIController.stagedAttachmentReady(.object(["attachmentCount": .number(1), "attachments": .array([.object([
        "name": .string("brief.md"), "status": .string("ready")])])]), name: "brief.md"))
}

@Test func nativeFileMentionsUseReleasedPathGrammar() throws {
    #expect(try UIController.nativeFileMention(path: "/work/brief.md", cwd: "/work/") == "@brief.md")
    #expect(try UIController.nativeFileMention(path: "/elsewhere/a  b.md", cwd: "/work") == "@\"/elsewhere/a  b.md\"")
    #expect(throws: ControlError.self) { try UIController.nativeFileMention(path: "/work/a\"b.md", cwd: "/work") }
    #expect(throws: ControlError.self) { try UIController.nativeFileMention(path: "/work/a\nb.md", cwd: "/work") }
}

private func enhancementDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-enhancement-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func enhancementJSON(_ text: String) throws -> JSONValue {
    try JSONValue(parseData: Data(text.utf8))
}

private struct EnhancementSession {
    let home: URL
    let path: URL
    var store: SessionStore { SessionStore(home: home) }

    init() throws {
        home = try enhancementDirectory()
        let directory = home.appendingPathComponent("sessions/project/enhancement")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("session.v4.jsonl")
    }

    func write(_ events: [(String, JSONValue)]) throws {
        let header = try enhancementJSON(#"{"type":"session","version":4,"id":"enhancement","createdAt":1,"cwd":"/scratch","isSeeded":false,"delegationDepth":0}"#)
        var bytes = try header.encoded(); bytes.append(10)
        for (index, event) in events.enumerated() {
            var row: [String: JSONValue] = ["type": .string(event.0), "seq": .number(Double(index)), "time": .number(Double(index + 2)), "data": event.1]
            if ["user/message", "assistant/message"].contains(event.0) { row["surfaceOp"] = .string("append") }
            bytes.append(try JSONValue.object(row).encoded()); bytes.append(10)
        }
        try bytes.write(to: path)
    }

    func turn(_ number: Int, input: String, reply: String, reason: String? = "completed") -> [(String, JSONValue)] {
        let turn = JSONValue.number(Double(number))
        var events: [(String, JSONValue)] = [
            ("turn/start", .object(["turn": turn])),
            ("user/message", .object(["role": .string("user"), "id": .string(input), "source": .object(["kind": .string("user")]),
                "content": .array([.object(["type": .string("text"), "text": .string("question " + input)])])])),
            ("assistant/message", .object(["turn": turn, "step": .number(1), "stream": .array([]),
                "message": .object(["role": .string("assistant"), "id": .string("answer-" + input), "source": .object(["kind": .string("model")]),
                    "content": .array([.object(["type": .string("text"), "text": .string(reply)])])])]))
        ]
        if let reason { events.append(("turn/end", .object(["turn": turn, "reason": .object(["kind": .string(reason)])]))) }
        return events
    }

    /// A child/agent-driven turn has no human-sourced user message, so it continues the bound input.
    func continuation(_ number: Int, reply: String, reason: String? = "completed") -> [(String, JSONValue)] {
        let turn = JSONValue.number(Double(number))
        var events: [(String, JSONValue)] = [
            ("turn/start", .object(["turn": turn])),
            ("user/message", .object(["role": .string("user"), "id": .string("child-message-" + reply), "source": .object(["kind": .string("agent")]),
                "content": .array([.object(["type": .string("text"), "text": .string("child report " + reply)])])])),
            ("assistant/message", .object(["turn": turn, "step": .number(1), "stream": .array([]),
                "message": .object(["role": .string("assistant"), "id": .string("answer-" + reply), "source": .object(["kind": .string("model")]),
                    "content": .array([.object(["type": .string("text"), "text": .string(reply)])])])]))
        ]
        if let reason { events.append(("turn/end", .object(["turn": turn, "reason": .object(["kind": .string(reason)])]))) }
        return events
    }

    func childCatalog(_ childID: String, mode: String = "one-shot") -> (String, JSONValue) {
        ("subagent/catalog", .object(["version": .number(mode == "external" ? 2 : 0), "childId": .string(childID),
                                      "childCreatedAt": .number(1), "mode": .string(mode), "label": .string("Helper")]))
    }
}

/// A synthetic inspect-shaped observation for the exact session; never a mutation request.
private func idleRuntimeState(_ sessionID: String, running: Bool = false, status: String? = nil,
                              subagents: [JSONValue] = [], aggregate: JSONValue? = nil,
                              pendingInteractions: [JSONValue] = [], uiAvailable: Bool = true,
                              observedSessionID: String? = nil, contentPhase: String? = "active",
                              loaded: Bool = true) -> JSONValue {
    let id = observedSessionID ?? sessionID
    return .object([
        "uiAvailable": .bool(uiAvailable),
        "loaded": .bool(loaded),
        "session": .object(["id": .string(id)]),
        "guard": .object(["conversationSession": .string(id), "contentPhase": contentPhase.map(JSONValue.string) ?? .null]),
        "running": .bool(running),
        "status": .string(status ?? (running ? "running" : "idle")),
        "pendingInteractions": .array(pendingInteractions),
        "subagents": .array(subagents),
        "subagentActivity": aggregate ?? .object(["available": .bool(false), "running": .bool(false), "declaredCount": .null]),
    ])
}

private func idleChild(_ id: String, status: String) -> JSONValue {
    .object(["id": .string(id), "status": .string(status), "running": .bool(status == "running"),
             "blocked": .bool(status == "blocked"), "loaded": .bool(true), "uiAvailable": .bool(true)])
}

private func idleAggregate(running: Bool, count: Int) -> JSONValue {
    .object(["available": .bool(true), "running": .bool(running), "declaredCount": .number(Double(count))])
}

@Suite struct EnhancementTests {
    @Test func requestFlagsAndStdinAreAlternativeSources() throws {
        let stdin = Data(#"{"session":"scratch","compact":true}"#.utf8)
        let options = try CommandOptions(arguments: ["inspect", "--port", "9333", "--timeout", "0.5"], stdin: stdin)
        #expect(options.port == 9333 && options.timeout == 0.5)
        #expect(options.request["session"] == .string("scratch"))
        #expect(options.request["compact"] == .bool(true))
        #expect(throws: ControlError.self) { try CommandOptions(arguments: ["inspect", "--session", "scratch"], stdin: stdin) }
        for text in ["[]", "null", #"{"session":"scratch","unknown":true}"#, #"{"compact":"true"}"#, #"{"session":false}"#] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: ["inspect"], stdin: Data(text.utf8)) }
        }
        #expect(throws: ControlError.self) { try CommandOptions(arguments: ["status", "--compact"]) }
        #expect(throws: ControlError.self) { try CommandOptions(arguments: ["inspect", "--session", "a", "--session", "b"]) }
    }

    @Test func booleanAndIntegerFieldsDoNotCoerceOtherJSONTypes() throws {
        for text in [#"{"full":1}"#, #"{"full":null}"#, #"{"turn":true}"#, #"{"turn":"1"}"#, #"{"turn":1.5}"#, #"{"turn":-1}"#, #"{"turn":1000001}"#] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: ["read"], stdin: Data(text.utf8)) }
        }
        let zero = try CommandOptions(arguments: ["read", "--turn", "0", "--full"])
        #expect(zero.request["turn"] == .number(0) && zero.request["full"] == .bool(true))
        let upper = try CommandOptions(arguments: ["wait"], stdin: Data(#"{"turn":1000000,"retryTransient":0}"#.utf8))
        #expect(upper.request["turn"] == .number(1_000_000))
        for value in ["true", "-1", "1.5", "1000001"] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: ["wait", "--turn", value]) }
        }
    }

    @Test func waitSelectorsAndReadRangesRejectConflicts() {
        for arguments in [
            ["wait", "--input-id", "input", "--turn", "1"],
            ["wait", "--request-id", "request", "--input-id", "input"],
            ["wait", "--request-id", "request", "--turn", "1"],
            ["read", "--turn", "1", "--since", "cursor"]
        ] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: arguments) }
        }
        #expect(throws: ControlError.self) {
            try CommandOptions(arguments: ["wait"], stdin: Data(#"{"inputId":"input","turn":1}"#.utf8))
        }
    }

    @Test func projectionsPreserveGuardAndDoNotChangeAuthorizingState() throws {
        let guardValue = try enhancementJSON(#"{"epoch":1,"conversationSession":"exact","draft":"unsent","attachments":["a"]}"#)
        let expect = try StateDigest.token(.object(["target": .string("page"), "guard": guardValue]))
        let state: JSONValue = .object(["expect": .string(expect), "guard": guardValue, "draft": .string("unsent"),
            "messages": .array([.string("large")]), "controls": .array([
                .object(["group": .string("composer"), "ref": .string("send")]),
                .object(["group": .string("sidebar"), "ref": .string("session")])])])
        let compact = try ObservationOutput.inspect(state, compact: true)
        #expect(compact["expect"] == state["expect"] && compact["guard"] == guardValue)
        #expect(compact["messages"] == nil && compact["controls"] == nil)
        let selected = try ObservationOutput.inspect(state, fields: "expect,guard,draft")
        #expect(Set(selected.object?.keys.map { $0 } ?? []) == Set(["expect", "guard", "draft"]))
        #expect(selected["guard"] == guardValue && selected["expect"] == state["expect"])
        let controls = try ObservationOutput.inspect(state, controls: "composer")
        #expect(controls["controls"]?.array?.count == 1)
        #expect(state["controls"]?.array?.count == 2 && state["messages"] == .array([.string("large")]))
        for fields in ["", "guard,", "missing"] {
            #expect(throws: ControlError.self) { try ObservationOutput.inspect(state, fields: fields) }
        }
        #expect(throws: ControlError.self) { try ObservationOutput.inspect(state, compact: true, fields: "messages") }
        #expect(throws: ControlError.self) { try ObservationOutput.inspect(state, controls: "all") }
    }

    @Test func fullUnicodeReportIsOwnerOnlyAndNeverReplacesExistingDestination() throws {
        let directory = try enhancementDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("report.json")
        let body = String(repeating: "مرحبا 👩🏽‍💻 e\u{301}\n", count: 2_000)
        let value: JSONValue = .object(["session": .object(["id": .string("scratch")]), "cursor": .string("cursor"), "body": .string(body)])
        let result = try ObservationOutput.save(value, to: path)
        var expected = try value.encoded(); expected.append(10)
        #expect(try Data(contentsOf: path) == expected)
        #expect(result["bytes"] == .number(Double(expected.count)))
        #expect(try JSONValue(parseData: Data(contentsOf: path))["body"] == .string(body))
        var info = stat()
        #expect(lstat(path.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600 && info.st_uid == getuid() && info.st_nlink == 1)
        #expect(throws: ControlError.self) { try ObservationOutput.save(.null, to: path) }
        #expect(try Data(contentsOf: path) == expected)
        let symlink = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: path)
        #expect(throws: ControlError.self) { try ObservationOutput.save(.null, to: symlink) }
        #expect(try Data(contentsOf: path) == expected)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == path.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["linked.json", "report.json"])
    }

    @Test func v2ReceiptSubmissionIsImmutableAndRequestIDIsPermanent() throws {
        let directory = try enhancementDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = try SendReceipts(directory: directory)
        let submission: JSONValue = .object(["sessionId": .string("exact"), "cursor": .string("before"),
            "digest": .string(StateDigest.text("private prompt")), "operation": .string("send")])
        let prepared = try receipts.prepare(requestID: "permanent", signature: "signature", targetID: "page", submission: submission)
        #expect(prepared["version"] == .number(2) && prepared["submission"] == submission)
        for (key, replacement) in [("sessionId", JSONValue.string("other")), ("cursor", .string("later")),
                                    ("digest", .string(StateDigest.text("other"))), ("operation", .string("command"))] {
            var changedSubmission = try #require(submission.object)
            changedSubmission[key] = replacement
            var changed = try #require(prepared.object)
            changed["submission"] = .object(changedSubmission)
            #expect(throws: ControlError.self) { try receipts.finish(requestID: "permanent", receipt: .object(changed)) }
        }
        var sent = try #require(prepared.object)
        sent["status"] = .string("sent"); sent["outcome"] = .string("verified")
        sent["verification"] = .object(["inputId": .string("input"), "turn": .number(1)])
        try receipts.finish(requestID: "permanent", receipt: .object(sent))
        #expect(try receipts.prepare(requestID: "permanent", signature: "other", targetID: "other", submission: .null) == .object(sent))
        #expect(try receipts.lookup(requestID: "permanent") == .object(sent))
        #expect(!(try String(decoding: Data(contentsOf: directory.appendingPathComponent("permanent.json")), as: UTF8.self)).contains("private prompt"))
        for (status, outcome) in [("prepared", "unknown"), ("uncertain", "unknown"), ("not_sent", "not_performed")] {
            var regressed = sent; regressed["status"] = .string(status); regressed["outcome"] = .string(outcome)
            #expect(throws: ControlError.self) { try receipts.finish(requestID: "permanent", receipt: .object(regressed)) }
        }
    }

    @Test func uncertainReceiptCannotBecomeNonDispatchAndLegacyRemainsReadable() throws {
        let directory = try enhancementDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = try SendReceipts(directory: directory)
        let legacy = try receipts.prepare(requestID: "legacy", signature: "signature", targetID: "page")
        #expect(legacy["version"] == nil && legacy["submission"] == nil)
        var record = try #require(legacy.object)
        record["status"] = .string("uncertain"); record["outcome"] = .string("unknown")
        try receipts.finish(requestID: "legacy", receipt: .object(record))
        let uncertain = JSONValue.object(record)
        record["status"] = .string("not_sent"); record["outcome"] = .string("not_performed")
        #expect(throws: ControlError.self) { try receipts.finish(requestID: "legacy", receipt: .object(record)) }
        #expect(try receipts.lookup(requestID: "legacy") == uncertain)
        #expect(try receipts.prepare(requestID: "legacy", signature: "changed", targetID: "changed") == uncertain)
        record["status"] = .string("sent"); record["outcome"] = .string("verified")
        try receipts.finish(requestID: "legacy", receipt: .object(record))
        #expect(try UIController.replayResult(.object(record))["replayedReceipt"] == .bool(true))
    }

    @Test func waiterReturnsReplyForExactOlderInputAndExplicitTurn() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") + fixture.turn(2, input: "second", reply: "SECOND"))
        for (input, turn) in [("first" as String?, nil as JSONValue?), (nil, JSONValue.number(1))] {
            let result = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: input, turn: turn, timeout: 0)
            #expect(result["outcome"] == .string("settled") && result["turn"] == .number(1))
            #expect(result["completionScope"] == .string("turn"))
            #expect(result["reply"]?["messages"]?.array?.first?["body"] == .string("FIRST"))
        }
    }

    @Test func waiterNeverUsesAnotherInputsTerminalTurn() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") + fixture.turn(2, input: "target", reply: "PARTIAL", reason: nil))
        let before = try Data(contentsOf: fixture.path)
        for input in ["target", "missing"] {
            do {
                _ = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: input, timeout: 0)
                Issue.record("Settled unfinished or missing input \(input)")
            } catch let error as ControlError {
                #expect(error.code == "wait_timeout" && error.outcome == "unknown")
            }
        }
        do {
            _ = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: "target", turn: .number(1), timeout: 0)
            Issue.record("Settled a turn that does not belong to the requested input")
        } catch let error as ControlError {
            #expect(error.outcome == "unknown")
        }
        #expect(try Data(contentsOf: fixture.path) == before)
    }

    @Test func waiterReportsRecordedInteractionAndTerminalFailureSeparately() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "target", reply: "PARTIAL", reason: nil) + [
            ("approval/asked", .object(["id": .string("approval"), "toolName": .string("bash")]))
        ])
        let blocked = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: "target", timeout: 0)
        #expect(blocked["outcome"] == .string("blocked") && blocked["completionScope"] == .string("turn"))
        #expect(blocked["state"]?["pendingInteractions"]?.array?.first?["runtimeConfirmed"] == .bool(false))
        try fixture.write(fixture.turn(1, input: "target", reply: "PARTIAL", reason: "interrupted"))
        let terminated = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: "target", timeout: 0)
        #expect(terminated["outcome"] == .string("terminated") && terminated["completionScope"] == .string("turn"))
        #expect(terminated["reason"]?["kind"] == .string("interrupted"))
    }

    @Test func fullSessionReadPreservesUnicodeBeyondCompactLimit() throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let body = String(repeating: "🧪مرحباe\u{301}", count: 4_000)
        try fixture.write(fixture.turn(1, input: "unicode", reply: body))
        let compact = try fixture.store.read(sessionID: "enhancement", lastAssistant: true)
        #expect(compact["messages"]?.array?.first?["truncated"] == .bool(true))
        let full = try fixture.store.read(sessionID: "enhancement", lastAssistant: true, full: true)
        #expect(full["messages"]?.array?.first?["body"] == .string(body))
        let output = fixture.home.appendingPathComponent("full.json")
        _ = try ObservationOutput.save(full, to: output)
        let saved = try JSONValue(parseData: Data(contentsOf: output))
        #expect(saved["messages"]?.array?.first?["body"] == .string(body))
    }

    @Test func commandWaitRequiresItsOwnCompletion() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let run: JSONValue = .object(["commandId": .string("target"), "name": .string("help"), "args": .string(""), "source": .object(["kind": .string("user")])])
        try fixture.write([("command/run", run), ("command/done", .object(["commandId": .string("other")]))])
        do {
            _ = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", commandID: "target", timeout: 0)
            Issue.record("Accepted another command's completion")
        } catch let error as ControlError { #expect(error.code == "wait_timeout") }
        try fixture.write([("command/run", run), ("command/done", .object(["commandId": .string("target")]))])
        let result = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", commandID: "target", timeout: 0)
        #expect(result["outcome"] == .string("command_settled"))
        #expect(result["commandId"] == .string("target"))
    }

    @Test func idleWaitReturnsContinuationTurnNotTheInitialParentSummary() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") + fixture.continuation(2, reply: "CONTINUATION"))
        let result = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 5,
            runtime: { id, _ in idleRuntimeState(id) })
        #expect(result["outcome"] == .string("settled"))
        #expect(result["completionScope"] == .string("idle"))
        #expect(result["turn"] == .number(2))
        #expect(result["originalTurn"] == .number(1))
        #expect(result["inputId"] == .string("first"))
        #expect(result["reply"]?["messages"]?.array?.first?["body"] == .string("CONTINUATION"))
        #expect(result["evidence"]?["children"]?["complete"] == .bool(true))
        #expect(result["evidence"]?["coverage"]?.string?.contains("Observed idle") == true)
    }

    @Test func idleWaitReportsTerminatedContinuationTurn() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") +
            fixture.continuation(2, reply: "PARTIAL", reason: "interrupted"))
        let result = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 5,
            runtime: { id, _ in idleRuntimeState(id) })
        #expect(result["outcome"] == .string("terminated") && result["completionScope"] == .string("idle"))
        #expect(result["turn"] == .number(2) && result["reason"]?["kind"] == .string("interrupted"))
    }

    @Test func idleWaitDoesNotSettleWhenParentTurnEndedButRuntimeIsActive() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, running: true) })
            Issue.record("Reported idle while the parent runtime was running")
        } catch let error as ControlError {
            #expect(error.code == "wait_timeout" && error.outcome == "unknown")
        }
    }

    @Test func idleWaitDoesNotSettleWhileTheParentContentIsSettling() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, contentPhase: "settling") })
            Issue.record("Reported idle while the displayed content was still settling")
        } catch let error as ControlError { #expect(error.code == "wait_timeout") }
    }

    @Test func idleWaitDoesNotSettleWhileAKnownChildIsActive() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write([fixture.childCatalog("child")] + fixture.turn(1, input: "first", reply: "FIRST"))
        for runtime in [
            idleRuntimeState("enhancement", subagents: [idleChild("child", status: "running")], aggregate: idleAggregate(running: true, count: 1)),
            idleRuntimeState("enhancement", subagents: [idleChild("child", status: "blocked")], aggregate: idleAggregate(running: false, count: 1)),
        ] {
            do {
                _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                    runtime: { _, _ in runtime })
                Issue.record("Reported idle while a known child was active")
            } catch let error as ControlError { #expect(error.code == "wait_timeout") }
        }
    }

    @Test func idleWaitHonorsAggregateChildActivityAbsentFromTheCatalog() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, aggregate: idleAggregate(running: true, count: 2)) })
            Issue.record("Ignored the displayed aggregate child-running indicator")
        } catch let error as ControlError { #expect(error.code == "wait_timeout") }
    }

    @Test func idleWaitUsesSupportedAggregateChildEvidenceAndRejectsMissingEvidence() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write([fixture.childCatalog("child")] + fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id) })
            Issue.record("Treated an unobservable known child as zero active children")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable") }
        let settled = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 5,
            runtime: { id, _ in idleRuntimeState(id, aggregate: idleAggregate(running: false, count: 1)) })
        #expect(settled["outcome"] == .string("settled"))
        #expect(settled["evidence"]?["children"]?["source"] == .string("aggregate_indicator"))
        #expect(settled["evidence"]?["children"]?["complete"] == .bool(true))
        #expect(settled["reply"]?["messages"]?.array?.first?["body"] == .string("FIRST"))
    }

    @Test func idleWaitNeverTreatsAnExternalChildAsObservedIdle() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write([fixture.childCatalog("external-child", mode: "external")] + fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, aggregate: idleAggregate(running: false, count: 1)) })
            Issue.record("Counted an external child's liveness as zero")
        } catch let error as ControlError {
            #expect(error.code == "idle_unavailable")
            #expect(error.details?["state"]?["subagents"]?.array?.first?["mode"] == .string("external"))
        }
    }

    @Test func idleWaitDoesNotCountUnknownChildObservationAsIdle() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write([fixture.childCatalog("child")] + fixture.turn(1, input: "first", reply: "FIRST"))
        let unknown: JSONValue = .object(["id": .string("child"), "status": .string("unknown"), "uiAvailable": .bool(true)])
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, subagents: [unknown]) })
            Issue.record("Treated a present-but-unknown child as observed idle")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable") }
    }

    @Test func idleWaitDoesNotAuthorizeIdleFromAnUnloadedParentOccurrence() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, loaded: false) })
            Issue.record("Trusted an unloaded parent occurrence as observed idle")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable") }
    }

    @Test func idleWaitReobservesWhenTheDurableCursorChangedDuringRuntimeIO() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let initial = fixture.turn(1, input: "first", reply: "FIRST")
        let extended = initial + fixture.continuation(2, reply: "CONTINUATION")
        try fixture.write(initial)
        var calls = 0
        let result = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 5,
            runtime: { id, _ in
                calls += 1
                if calls == 1 { try fixture.write(extended) }
                return idleRuntimeState(id)
            })
        #expect(calls >= 2)
        #expect(result["outcome"] == .string("settled"))
        #expect(result["turn"] == .number(2))
        #expect(result["reply"]?["messages"]?.array?.first?["body"] == .string("CONTINUATION"))
    }

    @Test func idleWaitDoesNotPublishFromAStaleCursorWithAPendingTail() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        var calls = 0
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0.5,
                runtime: { id, _ in
                    calls += 1
                    if calls == 1 {
                        // A partial final record leaves the committed cursor unchanged but makes the reread pending.
                        let handle = try FileHandle(forWritingTo: fixture.path)
                        _ = try handle.seekToEnd()
                        try handle.write(contentsOf: Data(#"{"type":"turn/start""#.utf8))
                        try handle.close()
                    }
                    return idleRuntimeState(id)
                })
            Issue.record("Published idle from a reread whose incomplete tail left running unknown")
        } catch let error as ControlError {
            #expect(error.code == "wait_timeout" && error.outcome == "unknown")
        }
        #expect(calls == 1)
        #expect(try fixture.store.snapshot(sessionID: "enhancement")["observation"]?["pendingTail"] == .bool(true))
    }

    @Test func idleWaitNeverPublishesAnObservationAfterTheDeadline() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0.05,
                runtime: { id, _ in
                    try await Task.sleep(for: .milliseconds(200))
                    return idleRuntimeState(id)
                })
            Issue.record("Published an idle observation obtained after the deadline")
        } catch let error as ControlError {
            #expect(error.code == "wait_timeout" && error.outcome == "unknown")
        }
    }

    @Test func idleWaitDoesNotObserveAViewThatSwitchedSessions() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id, observedSessionID: "another-session") })
            Issue.record("Treated another conversation's idle state as this session's")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable" && error.outcome == "unknown") }
    }

    @Test func idleWaitReportsUnavailableRuntimeInsteadOfFallingBackToTurnSettled() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0, runtime: nil)
            Issue.record("Fell back to recorded turn completion without runtime evidence")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable" && error.outcome == "unknown") }
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { _, _ -> JSONValue in throw ControlError(code: "transport", message: "closed") })
            Issue.record("Invented idle from a failed runtime observation")
        } catch let error as ControlError { #expect(error.code == "idle_unavailable") }
    }

    @Test func idleWaitConsidersQueuedInputAndPendingInteractions() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        let queued: JSONValue = .object(["role": .string("user"), "id": .string("follow-up"), "source": .object(["kind": .string("user")]),
            "content": .array([.object(["type": .string("text"), "text": .string("later")])])])
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") +
            [("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([queued])]))])
        var runtimeCalls = 0
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in runtimeCalls += 1; return idleRuntimeState(id) })
            Issue.record("Reported idle with queued input")
        } catch let error as ControlError { #expect(error.code == "wait_timeout") }
        #expect(runtimeCalls == 0)
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") + [
            ("approval/asked", .object(["id": .string("approval"), "toolName": .string("bash")]))])
        let blocked = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
            runtime: { id, _ in idleRuntimeState(id) })
        #expect(blocked["outcome"] == .string("blocked") && blocked["completionScope"] == .string("turn"))
        #expect(blocked["until"] == .string("idle"))
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        let observed = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
            runtime: { id, _ in idleRuntimeState(id, pendingInteractions: [.object(["kind": .string("approval"), "key": .string("live")])]) })
        #expect(observed["outcome"] == .string("blocked") && observed["reason"] == .string("observed_pending_interaction"))
        #expect(observed["until"] == .string("idle"))
    }

    @Test func idleWaitIdentifiesALaterHumanTurnAsOutOfScope() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST") + fixture.turn(2, input: "follow-up", reply: "LATER"))
        do {
            _ = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 0,
                runtime: { id, _ in idleRuntimeState(id) })
            Issue.record("Returned a later human request as this input's completion")
        } catch let error as ControlError {
            #expect(error.code == "scope_boundary" && error.outcome == "unknown")
            #expect(error.details?["boundary"]?["turn"] == .number(2))
            #expect(error.details?["boundaryInputId"] == .string("follow-up"))
            #expect(error.details?["turn"] == .number(1))
        }
    }

    @Test func idleObservationIsReadOnlyAndKeepsTheSendEvidenceContract() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        let before = try Data(contentsOf: fixture.path)
        var observedSessions: [String] = []
        let result = try await SessionWaiter.waitForIdle(store: fixture.store, sessionID: "enhancement", inputID: "first", timeout: 5,
            runtime: { id, _ in observedSessions.append(id); return idleRuntimeState(id) })
        #expect(result["outcome"] == .string("settled"))
        #expect(observedSessions == ["enhancement"])
        #expect(try Data(contentsOf: fixture.path) == before)
        let send: JSONValue = .object(["outcome": .string("verified"), "receipt": .object(["requestId": .string("send-1")])])
        let failure = ControlError.sendWaitFailure(ControlError(code: "wait_timeout", message: "late", outcome: "unknown"), send: send)
        #expect(failure.code == "wait_timeout" && failure.outcome == "unknown" && failure.details?["send"] == send)
        #expect(failure.details?["waitError"] == .string("wait_timeout"))
        let cancelled = ControlError.sendWaitFailure(CancellationError(), send: send)
        #expect(cancelled.code == "cancelled" && cancelled.outcome == "unknown" && cancelled.details?["send"] == send)
    }

    @Test func idleWaitRemainsCancellable() async throws {
        let fixture = try EnhancementSession(); defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.write(fixture.turn(1, input: "first", reply: "FIRST"))
        let store = fixture.store
        let task = Task {
            try await SessionWaiter.waitForIdle(store: store, sessionID: "enhancement", inputID: "first", timeout: 30,
                runtime: { id, _ in idleRuntimeState(id, running: true) })
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; Issue.record("Idle wait ignored cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func untilIdleIsValidatedBeforeAnyAppEffect() throws {
        let wait = try CommandOptions(arguments: ["wait", "--session", "s", "--until", "idle"])
        #expect(wait.request["until"] == .string("idle"))
        let legacy = try CommandOptions(arguments: ["wait"],
            stdin: Data(#"{"until":"idle","context":{"conversationSession":"s"}}"#.utf8))
        #expect(legacy.request["until"] == .string("idle"))
        for text in [#"{"until":"idle","context":{}}"#, #"{"until":"idle","context":{"conversationSession":""}}"#,
                     #"{"until":"idle","context":{"lastUser":"u"}}"#, #"{"until":"idle"}"#] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: ["wait"], stdin: Data(text.utf8)) }
        }
        let sendWait = try CommandOptions(arguments: ["send-and-wait", "--expect", "e", "--request-id", "r", "--until", "idle"])
        #expect(sendWait.request["until"] == .string("idle"))
        for arguments in [
            ["wait", "--session", "s", "--until", "busy"],
            ["wait", "--session", "s", "--until", "idle", "--turn", "1"],
            ["wait", "--until", "idle"],
            ["send-and-wait", "--expect", "e", "--request-id", "r", "--until", "later"],
            ["send", "--expect", "e", "--request-id", "r", "--until", "idle"],
        ] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: arguments) }
        }
        for text in [#"{"until":1}"#, #"{"until":true}"#, #"{"until":"idle","turn":1}"#] {
            #expect(throws: ControlError.self) { try CommandOptions(arguments: ["wait", "--session", "s"], stdin: Data(text.utf8)) }
        }
    }
}
