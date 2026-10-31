import Foundation
import Testing
@testable import DSHControlCore

private struct StoreFixture {
    let home: URL
    let directory: URL
    var path: URL { directory.appendingPathComponent("session.v4.jsonl") }
    var store: SessionStore { SessionStore(home: home) }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-observer-" + UUID().uuidString)
        directory = home.appendingPathComponent("sessions/project/scratch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    func write(_ events: [(String, JSONValue)], id: String = "scratch", seeded: Bool = false, parent: String? = nil, origin: String? = nil) throws {
        try bytes(events, id: id, seeded: seeded, parent: parent, origin: origin).write(to: path)
    }

    func bytes(_ events: [(String, JSONValue)], id: String = "scratch", seeded: Bool = false, parent: String? = nil, origin: String? = nil) throws -> Data {
        var header: [String: JSONValue] = ["type": .string("session"), "version": .number(4), "id": .string(id), "createdAt": .number(1),
                                           "cwd": .string("/scratch"), "isSeeded": .bool(seeded), "delegationDepth": .number(origin == nil ? 0 : 1)]
        if let parent { header["parentSession"] = .string(parent) }
        if let origin { header["origin"] = .string(origin) }
        let rows = [JSONValue.object(header)] + events.enumerated().map { index, event in
            var row: [String: JSONValue] = ["type": .string(event.0), "seq": .number(Double(index)), "time": .number(Double(index + 2)), "data": event.1]
            if ["user/message", "assistant/message", "tool/result"].contains(event.0) { row["surfaceOp"] = .string("append") }
            return JSONValue.object(row)
        }
        return try rows.reduce(into: Data()) { result, row in result.append(try row.encoded()); result.append(10) }
    }
}

private func object(_ text: String) throws -> JSONValue { try JSONValue(parseData: Data(text.utf8)) }
private func human(_ id: String, _ body: String) -> JSONValue {
    .object(["role": .string("user"), "id": .string(id), "source": .object(["kind": .string("user")]),
             "content": .array([.object(["type": .string("text"), "text": .string(body)])])])
}
private func answer(_ body: String, turn: Double = 1, interrupted: Bool = false) -> JSONValue {
    var data: [String: JSONValue] = ["turn": .number(turn), "step": .number(1), "stream": .array([]),
             "message": .object(["role": .string("assistant"), "source": .object(["kind": .string("model")]), "id": .string("assistant"),
                                 "content": .array([.object(["type": .string("reasoning"), "text": .string("PRIVATE")]),
                                                    .object(["type": .string("text"), "text": .string(body)])])])]
    if interrupted { data["interrupted"] = .bool(true) }
    return .object(data)
}

@Test func sessionStorePhysicalV4AdmissionAndLifecycle() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let before = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    let input = human("input-string-id", "hello\n world")
    let events: [(String, JSONValue)] = [
        ("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([input])])),
        ("turn/start", try object(#"{"turn":1}"#)),
        ("agent/inbox/spliced", try object(#"{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}"#)),
        ("user/message", input), ("assistant/message", answer("DONE")),
        ("turn/end", try object(#"{"turn":1,"reason":{"kind":"completed"}}"#))
    ]
    try fixture.write(events)
    let matched = try #require(try fixture.store.admission(sessionID: "scratch", after: before, digest: StateDigest.text("hello world")))
    #expect(matched["inputId"] == .string("input-string-id"))
    #expect(matched["turn"] == .number(1))
    #expect(matched["verifiedBy"] == .string("durable_user_message"))
    let snapshot = try fixture.store.snapshot(sessionID: "scratch")
    #expect(snapshot["running"] == .bool(false))
    #expect(snapshot["turnState"] == .string("ended"))
    #expect(snapshot["queue"]?["next-turn"] == .array([]))
    let read = try fixture.store.read(sessionID: "scratch", lastAssistant: true, full: true)
    #expect(read["messages"]?.array?.count == 1)
    #expect(read["messages"]?.array?.first?["body"] == .string("DONE"))
    #expect(read["events"] == nil)
    #expect(!(try String(decoding: read.encoded(), as: UTF8.self)).contains("PRIVATE"))
}

@Test func sessionStoreQueuedAdmissionAmbiguityAndCursorRewrite() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let before = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    let splice: JSONValue = .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([human("first", "same")])])
    try fixture.write([("agent/inbox/spliced", splice)])
    let one = try #require(try fixture.store.admission(sessionID: "scratch", after: before, digest: StateDigest.text("same")))
    #expect(one["verifiedBy"] == .string("durable_inbox"))
    #expect(one["turn"] == .null)
    let cursor = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    let second: JSONValue = .object(["target": .string("next-turn"), "start": .number(1), "inserted": .array([human("second", "same")])])
    try fixture.write([("agent/inbox/spliced", splice), ("agent/inbox/spliced", second)])
    #expect(throws: ControlError.self) { try fixture.store.admission(sessionID: "scratch", after: before, digest: StateDigest.text("same")) }
    try fixture.write([("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([human("changed", "same")])]))])
    #expect(throws: ControlError.self) { try fixture.store.admission(sessionID: "scratch", after: cursor, digest: StateDigest.text("same")) }
}

@Test func sessionStoreSeededForkDoesNotInheritHumanEvidenceOrBecomeSubagent() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([
        ("turn/start", try object(#"{"turn":1}"#)), ("user/message", human("ancestor", "inherited")),
        ("assistant/message", answer("ancestor reply")), ("turn/end", try object(#"{"turn":1,"reason":{"kind":"completed"}}"#)),
        ("subagent/catalog", try object(#"{"version":0,"childId":"ancestor-child","childCreatedAt":1,"mode":"one-shot"}"#)),
        ("session/end-seed", try object(#"{"inherited":true}"#))
    ], seeded: true, parent: "missing-ancestor")
    let snapshot = try fixture.store.snapshot(sessionID: "scratch")
    #expect(snapshot["messages"] == .array([]))
    #expect(snapshot["subagents"] == .array([]))
    #expect(snapshot["session"]?["sessionKind"] == .string("fork"))
    #expect(snapshot["session"]?["rootSessionId"] == .string("scratch"))
    #expect(snapshot["running"] == .null)
    #expect(try fixture.store.events(sessionID: "scratch").count == 1)
}

@Test func sessionStorePendingApprovalAndLatestSuccessfulHumanTurn() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([
        ("turn/start", try object(#"{"turn":1}"#)), ("user/message", human("one", "first")), ("assistant/message", answer("FIRST")),
        ("turn/end", try object(#"{"turn":1,"reason":{"kind":"completed"}}"#)),
        ("turn/start", try object(#"{"turn":2}"#)), ("user/message", human("two", "second")), ("assistant/message", answer("PARTIAL", turn: 2, interrupted: true)),
        ("approval/asked", try object(#"{"id":"approval","toolName":"bash"}"#))
    ])
    let snapshot = try fixture.store.snapshot(sessionID: "scratch")
    #expect(snapshot["turnState"] == .string("awaiting_approval_unconfirmed"))
    #expect(snapshot["running"] == .null)
    #expect(snapshot["pendingApprovals"]?.array?.count == 1)
    let result = try fixture.store.read(sessionID: "scratch", lastAssistant: true)
    #expect(result["messages"]?.array?.first?["text"] == .string("FIRST"))
    #expect(result["newerUnfinishedTurns"]?.array?.first?["turn"] == .number(2))
}

@Test func sessionStoreIncompleteTailIsPendingAndCompleteCorruptionFails() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    var bytes = try Data(contentsOf: fixture.path)
    bytes.append(Data(#"{"type":"turn/start""#.utf8))
    try bytes.write(to: fixture.path)
    #expect(try fixture.store.snapshot(sessionID: "scratch")["observation"]?["pendingTail"] == .bool(true))
    bytes.append(10); try bytes.write(to: fixture.path)
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
}

@Test func sessionStoreRequiredUnknownEventsAndMalformedProjectedFieldsReject() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([("future/required", .object([:]))])
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
    var rows = try fixture.bytes([])
    rows.append(try JSONValue.object(["type": .string("future/optional"), "seq": .number(0), "time": .number(1), "data": .array([.number(1)]), "ignorable": .bool(true)]).encoded())
    rows.append(10)
    try rows.write(to: fixture.path)
    #expect(try fixture.store.snapshot(sessionID: "scratch")["turnState"] == .string("unknown"))
    try fixture.write([("session/title", .object(["title": .number(1)]))])
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
    try fixture.write([("working-directory/change", .object(["cwd": .string("relative")]))])
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
}

@Test func sessionStoreSourceRangesDecodeAndRejectUnsafeExpansion() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let prefix = try fixture.bytes([
        ("user/message", human("first", "first")), ("user/message", human("second", "second")), ("user/message", human("third", "third"))
    ])
    func writeRanges(_ ranges: JSONValue) throws {
        var bytes = prefix
        bytes.append(try JSONValue.object(["type": .string("user/message"), "seq": .number(3), "time": .number(5),
                                           "data": human("summary", "summary"), "surfaceOp": .string("append"), "sourceEventSeqs": ranges]).encoded())
        bytes.append(10)
        try bytes.write(to: fixture.path)
    }
    try writeRanges(.array([.number(0), .array([.number(1), .number(2)])]))
    #expect(try fixture.store.events(sessionID: "scratch").last?["sourceEventSeqs"] == .array([.number(0), .number(1), .number(2)]))
    try writeRanges(.array([.number(2), .array([.number(0), .number(1)])]))
    #expect(throws: ControlError.self) { try fixture.store.events(sessionID: "scratch") }
    try writeRanges(.array([.array([.number(0), .number(2)]), .array([.number(0), .number(2)])]))
    #expect(throws: ControlError.self) { try fixture.store.events(sessionID: "scratch") }
}

@Test func sessionStoreNewestUnsupportedGenerationNeverFallsBack() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let future = fixture.directory.appendingPathComponent("session.v5.jsonl")
    try Data(contentsOf: fixture.path).write(to: future)
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
    try FileManager.default.removeItem(at: future)
    try Data(contentsOf: fixture.path).write(to: fixture.directory.appendingPathComponent("session.v04.jsonl"))
    #expect(try fixture.store.snapshot(sessionID: "scratch")["session"]?["id"] == .string("scratch"))
}

/// A standard single-segment raw-block Zstandard frame, independent of a compressor executable.
private func rawZstdFrame(_ input: Data) -> Data {
    precondition(input.count >= 256 && input.count < 65_792)
    let size = input.count - 256
    let block = input.count << 3 | 1
    return Data([0x28, 0xb5, 0x2f, 0xfd, 0x60, UInt8(size & 255), UInt8(size >> 8),
                 UInt8(block & 255), UInt8((block >> 8) & 255), UInt8((block >> 16) & 255)]) + input
}

@Test func sessionStoreZstdFramesAndIncompleteFinalFrame() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let bytes = try fixture.bytes([("session/title", .object(["title": .string(String(repeating: "test ", count: 30))]))])
    let frame = rawZstdFrame(bytes)
    let compressed = fixture.directory.appendingPathComponent("session.v4.jsonl.zstd")
    try (frame + Data([0x28, 0xb5, 0x2f])).write(to: compressed)
    let result = try fixture.store.snapshot(sessionID: "scratch")
    #expect(result["session"]?["title"]?.string == String(repeating: "test ", count: 30))
    #expect(result["observation"]?["pendingTail"] == .bool(true))
    try (frame + Data([0, 0, 0, 0])).write(to: compressed)
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
}

@Test func sessionStoreCompressedChecksumCorruptionIsNotPending() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    // Recorded from zstd 1.5.7: a released v4 header and session/title envelope, with checksum.
    var frame = try #require(Data(base64Encoded: "KLUv/QRY9QMAUkkbGoA5bf1GlEvY3fzQIibkaeiE7uB/ipiTFJUOxvM4r/rVKAzy2TnjYtoC5ytpbcgZcbX5atMexoOck21OWJi0eLh62q4KDed8/gVNh8+pQDbAeQf5xS9kc4IWF1KfM9kEt56weWGS6tXnN4u1EwQAIjq81gE9CLVF2yIGhzm0VQ=="))
    let compressed = fixture.directory.appendingPathComponent("session.v4.jsonl.zstd")
    try frame.write(to: compressed)
    #expect(try fixture.store.snapshot(sessionID: "scratch")["session"]?["title"] == .string("compressed"))
    frame[frame.count - 1] ^= 1
    try frame.write(to: compressed)
    #expect(throws: ControlError.self) { try fixture.store.snapshot(sessionID: "scratch") }
}

@Test func sessionStoreParentCatalogClassifiesChildAndForkLineageStops() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let parent = fixture.home.appendingPathComponent("sessions/project/parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let parentData = try fixture.bytes([
        ("subagent/catalog", try object(#"{"version":0,"childId":"scratch","childCreatedAt":1,"mode":"continuable","label":"Helper"}"#))
    ], id: "parent", parent: "fork-source")
    try parentData.write(to: parent.appendingPathComponent("session.v4.jsonl"))
    try fixture.write([], parent: "parent")
    let result = try fixture.store.snapshot(sessionID: "scratch")
    #expect(result["session"]?["sessionKind"] == .string("subagent"))
    #expect(result["session"]?["rootSessionId"] == .string("parent"))
}

@Test func sessionStoreCommandAdmissionRequiresHumanSourceAndExactRecordedArgs() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let cursor = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    try fixture.write([("command/run", try object(#"{"commandId":"command","name":"permission","args":" read-only","source":{"kind":"user"}}"#))])
    let result = try fixture.store.admission(sessionID: "scratch", after: cursor, digest: StateDigest.text("/permission read-only"), operation: "command")
    #expect(result?["commandId"] == .string("command"))
    #expect(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: StateDigest.text("/permission danger-full-access"), operation: "command") == nil)
}

@Test func sessionStoreExplicitOldAndFailedTurnsKeepTheirOwnReply() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([
        ("turn/start", try object(#"{"turn":1}"#)), ("user/message", human("one", "first")), ("assistant/message", answer("FIRST")),
        ("turn/end", try object(#"{"turn":1,"reason":{"kind":"completed"}}"#)),
        ("turn/start", try object(#"{"turn":2}"#)), ("user/message", human("two", "second")), ("assistant/message", answer("PARTIAL", turn: 2, interrupted: true)),
        ("turn/end", try object(#"{"turn":2,"reason":{"kind":"aborted","reason":{"kind":"legacy"}}}"#))
    ])
    #expect(try fixture.store.read(sessionID: "scratch", lastAssistant: true, turn: .number(1))["messages"]?.array?.first?["text"] == .string("FIRST"))
    let partial = try fixture.store.read(sessionID: "scratch", lastAssistant: true, turn: .number(2))
    #expect(partial["messages"]?.array?.first?["text"] == .string("PARTIAL"))
    #expect(partial["messages"]?.array?.first?["interrupted"] == .bool(true))
    #expect(partial["selectedTurn"]?["reason"]?["kind"] == .string("aborted"))
}

@Test func sessionStoreAdmissionReferencesRequireStructuredFileAndPreserveHash() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let cursor = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    let hash = StateDigest.text("file bytes")
    var input = human("input", "Read this file").object!
    input["content"] = .array([.object(["type": .string("text"), "text": .string("Read this file")]),
                               .object(["type": .string("file"), "attachment": .object(["attachmentId": .string("sha256:" + hash), "bytes": .number(10), "name": .string("notes.txt"), "data": .string("NEVER RETURN BYTES")])])])
    try fixture.write([("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([.object(input)])]))])
    let evidence = try #require(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: StateDigest.text("Read this file")))
    let ref = try #require(evidence["references"]?.array?.first)
    #expect(ref["type"] == .string("file"))
    #expect(ref["attachment"]?["attachmentId"] == .string("sha256:" + hash))
    #expect(ref["attachment"]?["bytes"] == .number(10))
    #expect(ref["attachment"]?["data"] == nil)
    #expect(evidence["text"] == nil)
    try fixture.write([("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([human("input", "Read this file")])]))])
    #expect(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: StateDigest.text("Read this file"))?["references"] == .array([]))
}

@Test func nativeReferenceAdmissionRequiresExactMentionWithoutClaimingUploadedBytes() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let cursor = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    let mention = "@\"/tmp/a  b.md\"", prompt = mention + " Follow the instructions."
    try fixture.write([("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([human("native", prompt)])]))])
    let digest = StateDigest.text(SessionStore.normalizedText(prompt))
    let admitted = try #require(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: digest, referenceMention: mention))
    #expect(admitted["references"]?.array?.first?["type"] == .string("native_file_reference"))
    #expect(admitted["references"]?.array?.first?["attachment"] == nil)
    #expect(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: digest, referenceMention: "@\"/tmp/a b.md\"") == nil)
}

@Test func nativeSkillAdmissionUsesDurableUserInputInsteadOfCommandRun() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write([])
    let cursor = try #require(try fixture.store.snapshot(sessionID: "scratch")["cursor"])
    try fixture.write([("agent/inbox/spliced", .object(["target": .string("next-turn"), "start": .number(0), "inserted": .array([human("skill-input", "/ponytail-help")])]))])
    let digest = StateDigest.text("/ponytail-help")
    let evidence = try #require(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: digest, operation: "skill"))
    #expect(evidence["inputId"] == .string("skill-input"))
    #expect(evidence["commandId"] == nil)
    #expect(try fixture.store.admission(sessionID: "scratch", after: cursor, digest: digest, operation: "command") == nil)
}

@Test func sessionStoreWorkspaceVersionAndMinimalProjection() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let storage = fixture.home.appendingPathComponent("storages")
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    let path = storage.appendingPathComponent("workspace.json")
    try Data(#"{"unit":{"name":"workspace","version":2},"global":{"workspaceIds":["w"]},"tables":{"workspaces":{"w":{"path":"/scratch","title":"Scratch","sessionIds":["private"]}}}}"#.utf8).write(to: path)
    #expect(try fixture.store.workspaces() == [.object(["id": .string("w"), "path": .string("/scratch"), "title": .string("Scratch")])])
    try Data(#"{"unit":{"name":"workspace","version":3},"global":{"workspaceIds":[]},"tables":{"workspaces":{}}}"#.utf8).write(to: path)
    #expect(throws: ControlError.self) { try fixture.store.workspaces() }
}

@Test func sessionStoreChangesOnlySuccessfulKnownToolDiffs() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let meta = try object(#"{"diffs":[{"path":"notes.txt","oldText":null,"newText":"hello"}]}"#)
    try fixture.write([
        ("tool/call", try object(#"{"turn":1,"step":1,"callId":"write","name":"write","arguments":"{}"}"#)),
        ("tool/result", .object(["turn": .number(1), "message": .object(["toolCallId": .string("write"), "isError": .bool(false)]), "meta": meta])),
        ("tool/result", .object(["turn": .number(1), "message": .object(["toolCallId": .string("unknown")]), "meta": meta])),
        ("tool/result", .object(["turn": .number(1), "message": .object(["toolCallId": .string("write"), "isError": .bool(true)]), "meta": meta]))
    ])
    let changes = try fixture.store.changes(sessionID: "scratch")
    #expect(changes["changes"]?.array?.count == 1)
    #expect(changes["changes"]?.array?.first?["newText"] == nil)
    #expect(changes["availability"] == .string("partial_tool_hunks"))
    #expect(try fixture.store.changes(sessionID: "scratch", includeDiff: true)["changes"]?.array?.first?["newText"] == .string("hello"))
}
