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
        #expect(blocked["outcome"] == .string("blocked"))
        #expect(blocked["state"]?["pendingInteractions"]?.array?.first?["runtimeConfirmed"] == .bool(false))
        try fixture.write(fixture.turn(1, input: "target", reply: "PARTIAL", reason: "interrupted"))
        let terminated = try await SessionWaiter.wait(store: fixture.store, sessionID: "enhancement", inputID: "target", timeout: 0)
        #expect(terminated["outcome"] == .string("terminated"))
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
}
