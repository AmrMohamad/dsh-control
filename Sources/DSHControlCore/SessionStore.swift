import CSessionZstd
import Darwin
import Foundation

/// Read-only observation of the released v4 JSONL store; durable events do not establish runtime liveness.
public struct SessionStore: Sendable {
    private let home: URL
    // rc.3's native reader rejects unknown required events; only explicitly ignorable extensions may be skipped.
    private static let knownEvents = Set("""
        agent-preset/selected agent/inbox/spliced approval/asked approval/decided approval/policy assistant/attempt assistant/message
        command/done command/run compaction/end compaction/prune compaction/start compaction/summary deliverables/presented developer/message
        feedback/message-delete feedback/message-put feedback/record goal/change hook/invoked hook/result image/offload job/registered job/settled
        llm/retry llm/retry-started model/selection permission/preset plan/mode request/context request/header sandbox/mode schedule/change
        session-log-deepseek/delivery-accepted session/end-seed session/title session/title-llm-request step/end step/start subagent/catalog
        subagent/descriptor subagent/model-selection-policy system/message team/member team/message/delivered team/message/queued team/task todo/write
        tool-workflow/agent-end tool-workflow/agent-start tool-workflow/run-end tool-workflow/run-start tool/call tool/ptc-dispatch tool/ptc-dispatch-start
        tool/result turn/end turn/start user/message web/deepseek-search-llm-request working-directory/change workspace/changes
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")) {
        self.home = home
    }

    /// Normalize text exactly as the GUI receipt matcher does.
    public static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Return current durable facts for one exact session identity.
    public func snapshot(sessionID: String) throws -> JSONValue {
        let log = try load(sessionID: sessionID)
        var result = try project(log)
        var session = result["session"]!.object!
        var visited: Set<String> = [sessionID]
        var current = log
        var root = sessionID
        while let id = current.header["parentSession"]?.string {
            guard let ancestor = try find(sessionID: id) else {
                if current.header["origin"]?.string == "subagent" { root = "" }
                break
            }
            let ancestorLog = try decode(ancestor)
            _ = try project(ancestorLog)
            let catalogued = ancestorLog.ownEvents.contains { $0["type"]?.string == "subagent/catalog" && $0["data"]?["childId"] == current.header["id"] }
            guard current.header["origin"]?.string == "subagent" || catalogued else { break }
            if current.header["id"] == log.header["id"] { session["sessionKind"] = .string("subagent") }
            guard visited.insert(id).inserted else { throw failure("corrupt_session", "Session ancestry contains a cycle") }
            root = id
            current = ancestorLog
        }
        session["rootSessionId"] = root.isEmpty ? .null : .string(root)
        result["session"] = .object(session)
        return .object(result)
    }

    /// List session metadata without claiming that an open durable turn is running.
    public func sessions() throws -> [JSONValue] {
        var seen = Set<String>()
        return try artifacts().map { artifact in
            let log = try decode(artifact)
            guard let id = log.header["id"]?.string, seen.insert(id).inserted else { throw failure("ambiguous_session_store", "Session identity appears in multiple artifacts") }
            let value = try project(log)
            return .object(["session": value["session"]!, "turnState": value["turnState"]!,
                            "running": value["running"]!, "observation": value["observation"]!])
        }.sorted { ($0["session"]?["id"]?.string ?? "") < ($1["session"]?["id"]?.string ?? "") }
    }

    /// Read only workspace identity, directory, and title from the released JSON storage unit.
    public func workspaces() throws -> [JSONValue] {
        let path = home.appendingPathComponent("storages/workspace.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let value = try JSONValue(parseData: stableData(path))
        guard value["unit"]?["name"]?.string == "workspace", value["unit"]?["version"] == .number(2) else {
            throw failure("unsupported_workspace_store", "Expected workspace JSON unit version 2")
        }
        guard let records = value["tables"]?["workspaces"]?.object,
              let order = value["global"]?["workspaceIds"]?.array else {
            throw failure("corrupt_workspace_store", "Workspace records or display order are missing")
        }
        guard Set(order.compactMap(\.string)) == Set(records.keys), value["global"]?["pendingMutation"] == nil else {
            throw failure("workspace_store_pending", "Workspace registry has an unfinished mutation; observe it through the GUI")
        }
        var seen = Set<String>()
        return try order.map { item in
            guard let id = item.string, seen.insert(id).inserted,
                  let record = records[id], let path = record["path"]?.string, let title = record["title"]?.string else {
                throw failure("corrupt_workspace_store", "Workspace order refers to a missing or malformed record")
            }
            return .object(["id": .string(id), "path": .string(path), "title": .string(title)])
        }
    }

    /// Return native own-event envelopes; inherited seed history is excluded.
    public func events(sessionID: String) throws -> [JSONValue] {
        try load(sessionID: sessionID).ownEvents
    }

    /// Verify post-cursor input admission, including queued input, without dispatching anything.
    public func admission(sessionID: String, after cursor: JSONValue, digest: String, operation: String = "send", referenceMention: String? = nil) throws -> JSONValue? {
        let log = try load(sessionID: sessionID)
        _ = try project(log)
        let count = try cursorCount(cursor, in: log)
        var turn: JSONValue = .null
        var matches: [String: JSONValue] = [:]
        for event in log.ownEvents {
            let data = event["data"]!
            if event["type"]?.string == "turn/start" { turn = data["turn"] ?? .null }
            if event["type"]?.string == "turn/end" { turn = .null }
            guard (event["seq"]?.number ?? -1) >= Double(count) else { continue }
            switch event["type"]?.string {
            case "command/run" where operation == "command" && data["source"]?["kind"]?.string == "user":
                let command = "/" + (data["name"]?.string ?? "") + (data["args"]?.string ?? "")
                if StateDigest.text(Self.normalizedText(command)) == digest, let id = data["commandId"], let key = id.string {
                    matches[key] = .object(["commandId": id, "eventSeq": event["seq"]!, "verifiedBy": .string("durable_command")])
                }
            case "user/message" where operation != "command":
                if let match = admitted(data, event: event, digest: digest, turn: turn, source: "durable_user_message", referenceMention: referenceMention), let id = match["inputId"]?.string { matches[id] = match }
            case "agent/inbox/spliced" where operation != "command":
                for input in data["inserted"]?.array ?? [] {
                    if let match = admitted(input, event: event, digest: digest, turn: .null, source: "durable_inbox", referenceMention: referenceMention), let id = match["inputId"]?.string, matches[id] == nil { matches[id] = match }
                }
            default: break
            }
        }
        guard matches.count <= 1 else { throw failure("ambiguous_admission", "Multiple distinct matching inputs appeared after the cursor") }
        return matches.values.first
    }

    /// Read human and assistant text, optionally after a continuous-history cursor.
    public func read(sessionID: String, lastAssistant: Bool = false, turn: JSONValue? = nil, since: String? = nil, full: Bool = false) throws -> JSONValue {
        let log = try load(sessionID: sessionID)
        let count = try since.map { try cursorCount(.string($0), in: log) } ?? 0
        var result = try project(log)
        let projectedMessages = result["messages"]!.array!
        var messages = projectedMessages.filter {
            ($0["eventSeq"]?.number ?? -1) >= Double(count) && (turn == nil || $0["turn"] == turn)
        }
        if lastAssistant {
            let choice: (selected: JSONValue?, reply: JSONValue?, origin: Double?, input: String?)
            if let requested = turn {
                // An explicit turn is exact: it never follows forward to a continuation turn.
                choice = (result["turns"]!.array!.first { $0["turn"] == requested }, nil, nil, nil)
            } else {
                choice = latestReply(messages: projectedMessages, turns: result["turns"]!.array!)
            }
            let selectedTurn = choice.selected?["turn"]
            messages = selectedTurn.map { selected in Array(messages.filter { message in
                message["kind"]?.string == "assistant" && message["turn"] == selected
                    && (turn != nil || message["interrupted"] != .bool(true))
                    && !(message["text"]?.string ?? "").isEmpty
                    && (turn != nil || message["eventSeq"] == choice.reply?["eventSeq"])
            }.suffix(1)) } ?? []
            result["selectedTurn"] = choice.selected ?? .null
            result["replyAvailable"] = .bool(!messages.isEmpty)
            if turn == nil {
                result["originalTurn"] = choice.origin.map { .number($0) } ?? .null
                result["inputId"] = choice.input.map { .string($0) } ?? .null
            }
            let selectedNumber = selectedTurn?.number ?? -1
            result["newerUnfinishedTurns"] = .array(result["turns"]!.array!.filter {
                ($0["turn"]?.number ?? -1) > selectedNumber && $0["ended"] == .bool(false)
            })
        }
        if !full {
            messages = messages.map { message in
                var row = message.object!
                if let body = row["body"]?.string, body.count > 16_000 {
                    row["body"] = .string(String(body.prefix(16_000))); row["text"] = row["body"]; row["truncated"] = .bool(true)
                }
                return .object(row)
            }
        }
        result["messages"] = .array(messages)
        return .object(result)
    }

    /// Default `--last-assistant` selection: the latest eligible recorded reply in the episode opened
    /// by the latest completed human-origin turn. Its autonomous parent continuation turns belong to
    /// the same episode until the next human-origin turn starts another request. Selection uses IDs
    /// and event order only; a reply is eligible when it is non-interrupted assistant text on a
    /// completed turn and is preceded by an own human input from the origin turn. Without an
    /// attributable reply the origin turn stays selected with empty output, matching exact reads.
    private func latestReply(messages: [JSONValue], turns: [JSONValue]) -> (selected: JSONValue?, reply: JSONValue?, origin: Double?, input: String?) {
        let human = messages.filter { $0["kind"]?.string == "user" && $0["turn"]?.number != nil && $0["inputId"]?.string != nil }
        let humanTurns = Set(human.compactMap { $0["turn"]?.number })
        let ordered = turns.sorted { ($0["turn"]?.number ?? -1) < ($1["turn"]?.number ?? -1) }
        guard let originRow = ordered.last(where: { $0["reason"]?["kind"]?.string == "completed" && humanTurns.contains($0["turn"]?.number ?? -1) }),
              let origin = originRow["turn"]?.number else { return (nil, nil, nil, nil) }
        let boundary = ordered.compactMap { row -> Double? in
            guard let number = row["turn"]?.number, number > origin, humanTurns.contains(number) else { return nil }
            return number
        }.min()
        let episode = ordered.filter {
            guard let number = $0["turn"]?.number else { return false }
            return number >= origin && (boundary.map { number < $0 } ?? true)
        }
        let inputs = human.filter { $0["turn"]?.number == origin }
        var selected: JSONValue?
        var reply: JSONValue?
        for row in episode where row["reason"]?["kind"]?.string == "completed" {
            guard let message = messages.last(where: { $0["kind"]?.string == "assistant" && $0["turn"] == row["turn"]
                && $0["interrupted"] != .bool(true) && !($0["text"]?.string ?? "").isEmpty }) else { continue }
            // A reply recorded before every origin-turn human input cannot be attributed to one.
            guard inputs.contains(where: { ($0["eventSeq"]?.number ?? -1) <= (message["eventSeq"]?.number ?? -1) }) else { continue }
            selected = row
            reply = message
        }
        selected = selected ?? originRow
        let anchor = reply.flatMap { message in
            inputs.last { ($0["eventSeq"]?.number ?? -1) <= (message["eventSeq"]?.number ?? -1) }
        }
        // With no attributable reply, retain the episode's real origin input but never its text.
        let input = (anchor ?? inputs.last)?["inputId"]?.string
        return (selected, reply, origin, input)
    }

    /// Return filesystem tool metadata actually recorded for the selected turn; absence stays unavailable.
    public func changes(sessionID: String, turn: JSONValue? = nil, includeDiff: Bool = false) throws -> JSONValue {
        let log = try load(sessionID: sessionID)
        var writeCalls = Set<String>()
        for event in log.ownEvents where event["type"]?.string == "tool/call" {
            if ["write", "edit"].contains(event["data"]?["name"]?.string ?? ""), let id = event["data"]?["callId"]?.string { writeCalls.insert(id) }
        }
        let rows = log.ownEvents.flatMap { event -> [JSONValue] in
            guard event["type"]?.string == "tool/result", turn == nil || event["data"]?["turn"] == turn,
                  event["data"]?["error"] == nil, event["data"]?["message"]?["isError"] != .bool(true),
                  let callID = event["data"]?["message"]?["toolCallId"]?.string, writeCalls.contains(callID),
                  let diffs = event["data"]?["meta"]?["diffs"]?.array,
                  diffs.allSatisfy({ $0["path"]?.string != nil && ($0["oldText"] == .null || $0["oldText"]?.string != nil) && $0["newText"]?.string != nil }) else { return [] }
            return diffs.map { diff in
                var row: [String: JSONValue] = ["eventSeq": event["seq"]!, "turn": event["data"]?["turn"] ?? .null,
                                                "path": diff["path"]!, "source": .string("recorded_tool_hunk")]
                if includeDiff { row["oldText"] = diff["oldText"]; row["newText"] = diff["newText"] }
                return .object(row)
            }
        }
        return .object(["sessionId": .string(sessionID), "changes": .array(rows),
                        "availability": .string(rows.isEmpty ? "unavailable" : "partial_tool_hunks"),
                        "summaryAvailability": .string("unavailable_from_durable_log"),
                        "cursor": try cursor(log)])
    }

    private func admitted(_ input: JSONValue, event: JSONValue, digest: String, turn: JSONValue, source: String, referenceMention: String?) -> JSONValue? {
        guard input["source"]?["kind"]?.string == "user", let id = input["id"], id.string != nil,
              StateDigest.text(Self.normalizedText(text(input))) == digest else { return nil }
        if let referenceMention {
            let body = text(input)
            guard body.hasPrefix(referenceMention), body.dropFirst(referenceMention.count).first?.isWhitespace != false else { return nil }
        }
        let references = (input["content"]?.array ?? []).compactMap { part -> JSONValue? in
            guard let kind = part["type"]?.string, ["file", "image"].contains(kind), let attachment = part["attachment"]?.object,
                  let id = attachment["attachmentId"]?.string, integer(attachment["bytes"]) != nil else { return nil }
            if kind == "file" {
                let hash = String(id.dropFirst(7))
                guard id.hasPrefix("sha256:"), hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), attachment["name"]?.string != nil else { return nil }
            }
            let fields: Set<String> = kind == "file" ? ["attachmentId", "bytes", "name"] : ["attachmentId", "bytes", "name", "mediaType", "width", "height"]
            return .object(["type": .string(kind), "attachment": .object(attachment.filter { fields.contains($0.key) && ($0.value.string != nil || $0.value.number != nil) })])
        }
        let native = referenceMention.map { [JSONValue.object(["type": .string("native_file_reference"), "mention": .string($0)])] } ?? []
        return .object(["inputId": id, "turn": turn, "eventSeq": event["seq"]!, "verifiedBy": .string(source), "references": .array(references + native)])
    }

    private struct Artifact { let url: URL; let generation: Int }
    private struct Log {
        let artifact: Artifact
        let header: JSONValue
        let events: [JSONValue]
        let inherited: Int
        let pending: Bool
        var ownEvents: [JSONValue] { Array(events.dropFirst(inherited)) }
    }

    private func artifacts() throws -> [Artifact] {
        let root = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw failure("session_store_unavailable", "Cannot enumerate the configured session directory")
        }
        var groups: [String: [Artifact]] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, let generation = generation(url.lastPathComponent) else { continue }
            groups[url.deletingLastPathComponent().path, default: []].append(Artifact(url: url, generation: generation))
        }
        return groups.values.flatMap { values in
            let maximum = values.map(\.generation).max()!
            return values.filter { $0.generation == maximum }
        }
    }

    private func generation(_ name: String) -> Int? {
        let raw = name.hasSuffix(".zstd") ? String(name.dropLast(5)) : name
        if raw == "session.jsonl" { return 0 }
        guard raw.hasPrefix("session.v"), raw.hasSuffix(".jsonl") else { return nil }
        let digits = String(raw.dropFirst(9).dropLast(6))
        guard digits.first != "0", !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits) ?? Int.max
    }

    private func find(sessionID: String) throws -> Artifact? {
        guard !sessionID.isEmpty else { throw failure("invalid_session_id", "Session identity must not be empty") }
        let segment = sessionID == "." ? "~002E" : sessionID == ".." ? "~002E~002E" : sessionID.utf16.map { unit in
            if (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || [45, 46, 95].contains(unit) {
                return String(UnicodeScalar(unit)!)
            }
            return String(format: "~%04X", unit)
        }.joined()
        let candidates = try artifacts().filter { $0.url.deletingLastPathComponent().lastPathComponent == segment }
        guard candidates.count <= 1 else { throw failure("ambiguous_session_store", "Session identity appears in multiple current artifacts") }
        guard let artifact = candidates.first else { return nil }
        guard artifact.generation == 4 else { throw failure("unsupported_session_format", "Newest session generation is v\(artifact.generation); only released v4 is supported") }
        let data = try plaintext(artifact, headerOnly: true).data
        guard let line = data.split(separator: 10, omittingEmptySubsequences: false).first, !line.isEmpty else {
            throw failure("session_pending", "Session header has not completed")
        }
        guard let header = try? JSONValue(parseData: Data(line)), header["id"]?.string == sessionID else {
            throw failure("corrupt_session", "Session header does not match its canonical directory identity")
        }
        return artifact
    }

    private func load(sessionID: String) throws -> Log {
        guard let artifact = try find(sessionID: sessionID) else { throw failure("session_not_found", "No supported durable log for the exact session identity") }
        return try decode(artifact)
    }

    private func stableData(_ url: URL, headerOnly: Bool = false) throws -> Data {
        guard url.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/") else {
            throw failure("unsupported_storage", "Store entry must be a regular file inside the configured home")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure("session_store_unavailable", "Cannot open store entry for observation") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw failure("unsupported_storage", "Store entry must be a regular file")
        }
        var data = Data()
        if headerOnly {
            while !data.contains(10), let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 4_194_304 else { throw failure("corrupt_session", "Session header exceeds 4 MiB") }
            }
        } else { data = try handle.readToEnd() ?? Data() }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              headerOnly || data.count == after.st_size else { throw failure("session_store_busy", "Session store changed during observation; read again") }
        return data
    }

    private func plaintext(_ artifact: Artifact, headerOnly: Bool = false) throws -> (data: Data, pending: Bool) {
        let data = try stableData(artifact.url, headerOnly: headerOnly && artifact.url.pathExtension != "zstd")
        guard artifact.url.pathExtension == "zstd" else { return (data, false) }
        let bytes = [UInt8](data)
        var offset = 0
        var output = Data()
        while offset < bytes.count {
            let start = offset
            guard bytes.count - offset >= 4 else { return (output, true) }
            guard Array(bytes[offset..<(offset + 4)]) == [0x28, 0xb5, 0x2f, 0xfd] else { throw failure("corrupt_session", "Invalid Zstandard frame magic") }
            offset += 4
            guard offset < bytes.count else { return (output, true) }
            let descriptor = bytes[offset]; offset += 1
            guard descriptor & 0x18 == 0 else { throw failure("corrupt_session", "Reserved Zstandard header bits") }
            let sizeFlag = Int(descriptor >> 6)
            let single = descriptor & 0x20 != 0
            let dictionaryFlag = Int(descriptor & 3)
            let remaining = (single ? 0 : 1) + (dictionaryFlag == 3 ? 4 : dictionaryFlag) + (sizeFlag == 0 ? (single ? 1 : 0) : 1 << sizeFlag)
            guard bytes.count - offset >= remaining else { return (output, true) }
            offset += remaining
            while true {
                guard bytes.count - offset >= 3 else { return (output, true) }
                let header = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                offset += 3
                let kind = (header >> 1) & 3
                guard kind != 3 else { throw failure("corrupt_session", "Reserved Zstandard block type") }
                let length = kind == 1 ? 1 : header >> 3
                guard bytes.count - offset >= length else { return (output, true) }
                offset += length
                if header & 1 != 0 { break }
            }
            if descriptor & 4 != 0 {
                guard bytes.count - offset >= 4 else { return (output, true) }
                offset += 4
            }
            var decoded: UnsafeMutablePointer<UInt8>?
            var count = 0
            let status = bytes.withUnsafeBufferPointer { buffer in
                dsh_zstd_decode(buffer.baseAddress! + start, offset - start, &decoded, &count)
            }
            guard status == 0, let decoded else {
                throw failure(status == -1 ? "zstd_unavailable" : "corrupt_session", status == -1 ? "Install libzstd to observe compressed sessions" : "Zstandard frame failed decoding or checksum validation")
            }
            output.append(decoded, count: count)
            dsh_zstd_free(decoded)
            if headerOnly && output.contains(10) { return (output, false) }
        }
        return (output, false)
    }

    private func decode(_ artifact: Artifact) throws -> Log {
        guard artifact.generation == 4 else { throw failure("unsupported_session_format", "Newest session generation is v\(artifact.generation); only released v4 is supported") }
        let source = try plaintext(artifact)
        let lines = source.data.split(separator: 10, omittingEmptySubsequences: false)
        let completeLines = lines.dropLast()
        let pending = source.pending || (!source.data.isEmpty && source.data.last != 10)
        guard let first = completeLines.first else { throw failure("session_pending", "Session header has not been durably completed") }
        let header: JSONValue
        do { header = try JSONValue(parseData: Data(first)) }
        catch { throw failure("corrupt_session", "Session header is not valid JSON") }
        let required: Set<String> = ["type", "version", "id", "createdAt", "isSeeded", "delegationDepth"]
        let allowed = required.union(["cwd", "parentSession", "origin", "agentPreset"])
        guard let fields = header.object, required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: allowed),
              header["type"]?.string == "session", header["version"] == .number(4), header["id"]?.string != nil,
              integer(header["createdAt"]) != nil, integer(header["delegationDepth"]) != nil, header["isSeeded"]?.bool != nil,
              ["cwd", "parentSession", "agentPreset"].allSatisfy({ header[$0] == nil || header[$0]?.string != nil }),
              header["cwd"] == nil || header["cwd"]?.string?.hasPrefix("/") == true,
              header["origin"] == nil || header["origin"]?.string == "subagent" else {
            throw failure("corrupt_session", "Invalid released v4 physical header")
        }
        var events: [JSONValue] = []
        var cut: Int?
        for line in completeLines.dropFirst() {
            var event: JSONValue
            do { event = try JSONValue(parseData: Data(line)) }
            catch { throw failure("corrupt_session", "A complete session row is not valid JSON") }
            guard var record = event.object, event["type"]?.string != nil, integer(event["seq"]) == events.count,
                  let time = event["time"]?.number, time.isFinite, time.rounded() == time, abs(time) <= 9_007_199_254_740_991,
                  event["data"] != nil,
                  Set(record.keys).isSubset(of: ["type", "seq", "time", "data", "ignorable", "sourceEventSeqs", "surfaceOp"]),
                  event["ignorable"] == nil || event["ignorable"] == .bool(true) else {
                throw failure("corrupt_session", "Invalid event envelope or non-contiguous event sequence")
            }
            let type = event["type"]!.string!
            guard Self.knownEvents.contains(type) || event["ignorable"] == .bool(true) else {
                throw failure("unsupported_session_event", "Session contains a required event outside the released rc.3 vocabulary")
            }
            guard !Self.knownEvents.contains(type) || event["data"]?.object != nil else {
                throw failure("corrupt_session", "A released event payload must be an object")
            }
            if let ranges = event["sourceEventSeqs"] {
                guard let values = ranges.array else { throw failure("corrupt_session", "Invalid source-event ranges") }
                var expanded: [JSONValue] = []
                var hasRange = false
                for value in values {
                    if let pair = value.array {
                        guard pair.count == 2, let start = integer(pair[0]), let end = integer(pair[1]), start <= end,
                              end < events.count, end - start + 1 <= events.count - expanded.count else { throw failure("corrupt_session", "Invalid source-event range") }
                        hasRange = true
                        expanded += (start...end).map { .number(Double($0)) }
                    } else {
                        guard let index = integer(value), index < events.count, expanded.count < events.count else { throw failure("corrupt_session", "Invalid source-event reference") }
                        expanded.append(value)
                    }
                }
                guard Set(expanded.compactMap(\.number)).count == expanded.count else { throw failure("corrupt_session", "Duplicate source-event references") }
                if hasRange {
                    let numbers = expanded.compactMap(\.number)
                    guard zip(numbers, numbers.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { throw failure("corrupt_session", "Compressed source-event ranges must increase") }
                }
                record["sourceEventSeqs"] = .array(expanded)
                event = .object(record)
            }
            if event["type"]?.string == "session/end-seed", event["data"]?["inherited"] == .bool(true) { cut = events.count }
            events.append(event)
        }
        if header["isSeeded"] == .bool(true), cut == nil {
            if pending { throw failure("session_pending", "Inherited seed boundary has not completed") }
            throw failure("corrupt_session", "Seeded session lacks its inherited end-seed marker")
        }
        if header["isSeeded"] == .bool(false), cut != nil { throw failure("corrupt_session", "Unseeded session contains inherited history") }
        return Log(artifact: artifact, header: header, events: events, inherited: cut ?? 0, pending: pending)
    }

    private func cursor(_ log: Log) throws -> JSONValue {
        let value = JSONValue.object(["id": log.header["id"]!, "count": .number(Double(log.events.count)),
                                      "generation": .number(Double(log.artifact.generation)), "prefixHash": .string(try prefixHash(log, count: log.events.count))])
        return .string(try value.encoded().base64EncodedString())
    }

    private func prefixHash(_ log: Log, count: Int) throws -> String {
        try StateDigest.token(.array([log.header] + log.events.prefix(count)))
    }

    private func cursorCount(_ cursor: JSONValue, in log: Log) throws -> Int {
        guard let token = cursor.string, let bytes = Data(base64Encoded: token), let value = try? JSONValue(parseData: bytes),
              value["id"] == log.header["id"], value["generation"] == .number(Double(log.artifact.generation)),
              let count = integer(value["count"]), count <= log.events.count,
              value["prefixHash"]?.string == (try prefixHash(log, count: count)) else {
            throw failure("stale_cursor", "Cursor does not identify a continuous prefix of this session")
        }
        return count
    }

    private func project(_ log: Log) throws -> [String: JSONValue] {
        var title: JSONValue = .null
        var cwd = log.header["cwd"] ?? .null
        var turns: [JSONValue] = []
        var messages: [JSONValue] = []
        var subagents: [JSONValue] = []
        var queue: [String: [JSONValue]] = ["next-turn": [], "next-step": []]
        var approvals: [String: JSONValue] = [:]
        var questions: [String: JSONValue] = [:]
        var turn: JSONValue = .null
        var open = false
        var hasEnded = false
        var model: JSONValue = .null
        var access: [String: JSONValue] = [:]
        var usages: [JSONValue] = []
        var commands: [JSONValue] = []
        for event in log.ownEvents {
            let data = event["data"]!
            switch event["type"]?.string {
            case "session/title":
                guard data["title"]?.string != nil else { throw failure("corrupt_session", "Session title must be text") }
                title = data["title"]!
            case "working-directory/change":
                guard data["cwd"]?.string?.hasPrefix("/") == true else { throw failure("corrupt_session", "Working directory must be an absolute path") }
                cwd = data["cwd"]!
            case "turn/start":
                guard integer(data["turn"]) != nil, !open else { throw failure("corrupt_session", "Invalid or overlapping turn start") }
                turn = data["turn"]!; open = true
                turns.append(.object(["turn": turn, "ended": .bool(false), "reason": .null]))
            case "turn/end":
                guard integer(data["turn"]) != nil, data["reason"]?["kind"]?.string != nil else { throw failure("corrupt_session", "Invalid turn end") }
                if open {
                    guard data["turn"] == turn else { throw failure("corrupt_session", "Turn end does not match its opening") }
                    turns[turns.count - 1] = .object(["turn": turn, "ended": .bool(true), "reason": data["reason"]!])
                    hasEnded = true
                } else if !["forked", "interrupted"].contains(data["reason"]?["kind"]?.string ?? "") {
                    throw failure("corrupt_session", "Turn end has no matching start")
                }
                open = false; approvals.removeAll()
            case "user/message":
                guard data["id"]?.string != nil, data["content"]?.array != nil, data["source"]?["kind"]?.string != nil else {
                    throw failure("corrupt_session", "Malformed user message")
                }
                if data["source"]?["kind"]?.string == "user" {
                    messages.append(.object(["kind": .string("user"), "body": .string(text(data)), "text": .string(text(data)),
                                             "turn": open ? turn : .null, "inputId": data["id"]!, "eventSeq": event["seq"]!]))
                }
                if data["source"]?["kind"]?.string == "user-question-reply", let id = data["source"]?["callId"]?.string { questions[id] = nil }
            case "assistant/message":
                guard let message = data["message"], message["content"]?.array != nil, integer(data["turn"]) != nil else {
                    throw failure("corrupt_session", "Malformed assistant message")
                }
                messages.append(.object(["kind": .string("assistant"), "body": .string(text(message)), "text": .string(text(message)),
                                         "turn": data["turn"]!, "inputId": .null, "eventSeq": event["seq"]!, "interrupted": data["interrupted"] ?? .bool(false)]))
                if let usage = data["usage"] { usages.append(usage) }
            case "agent/inbox/spliced":
                guard let target = data["target"]?.string, var items = queue[target], let start = integer(data["start"]),
                      let inserted = data["inserted"]?.array, let removed = integer(data["removedCount"] ?? .number(0)),
                      start <= items.count, removed <= items.count - start,
                      inserted.allSatisfy({ $0["id"]?.string != nil && $0["role"]?.string == "user" && $0["content"]?.array != nil && $0["source"]?["kind"]?.string != nil }) else { throw failure("corrupt_session", "Invalid durable inbox splice") }
                items.replaceSubrange(start..<(start + removed), with: inserted)
                guard Set(items.compactMap { $0["id"]?.string }).count == items.count else { throw failure("corrupt_session", "Duplicate durable inbox input identity") }
                queue[target] = items
            case "subagent/catalog":
                guard let id = data["childId"]?.string, let mode = data["mode"]?.string,
                      let version = integer(data["version"]),
                      (version == 0 && ["one-shot", "continuable"].contains(mode)) || (version == 1 && ["one-shot", "continuable", "unknown"].contains(mode)) || (version == 2 && mode == "external") else { throw failure("unsupported_session_event", "Unrecognized subagent catalog entry") }
                subagents.append(.object(["id": .string(id), "label": data["label"] ?? .null, "mode": .string(mode), "state": .string("unconfirmed")]))
            case "approval/asked":
                guard let id = data["id"]?.string else { throw failure("corrupt_session", "Approval request lacks identity") }
                approvals[id] = data
            case "approval/decided": if let id = data["id"]?.string { approvals[id] = nil }
            case "tool/call" where data["name"]?.string == "ask_user_question":
                if let id = data["callId"]?.string { questions[id] = data }
            case "tool/result":
                if let id = data["message"]?["toolCallId"]?.string, questions[id] != nil {
                    let body = text(data["message"] ?? .null)
                    let pending = (try? JSONValue(parseData: Data(body.utf8)))?["pending"] == .bool(true)
                    if pending || data["error"]?["code"]?.string == "TOOL_OUTCOME_UNKNOWN" {
                        var question = questions[id]!.object!; question["state"] = .string("continued"); questions[id] = .object(question)
                    } else { questions[id] = nil }
                }
            case "model/selection": model = data
            case "request/header": if model == .null { model = data["header"]?["config"] ?? .null }
            case "permission/preset": access["preset"] = data["preset"]
            case "sandbox/mode": access["sandboxMode"] = data["mode"]
            case "approval/policy": access["approvalPolicy"] = data["policy"]
            case "command/run", "command/done": commands.append(event)
            default: break
            }
        }
        let state = !approvals.isEmpty ? "awaiting_approval_unconfirmed" : !questions.isEmpty ? "awaiting_question_unconfirmed" : open ? "open_unconfirmed" : hasEnded ? "ended" : "unknown"
        return [
            "session": .object(["id": log.header["id"]!, "cwd": cwd, "title": title,
                                 "parentSessionId": log.header["parentSession"] ?? .null, "rootSessionId": log.header["parentSession"] == nil ? log.header["id"]! : .null,
                                 "sessionKind": .string(log.header["origin"]?.string == "subagent" ? "subagent" : log.header["parentSession"] == nil ? "root" : "fork")]),
            "turnState": .string(state), "running": !log.pending && !open && hasEnded && queue.values.allSatisfy(\.isEmpty) && questions.isEmpty ? .bool(false) : .null,
            "messages": .array(messages), "turns": .array(turns), "subagents": .array(subagents),
            "queue": .object(queue.mapValues(JSONValue.array)), "usage": usages.isEmpty ? .null : .array(usages),
            "model": model, "access": .object(access), "commands": .array(commands),
            "pendingApprovals": .array(approvals.keys.sorted().map { approvals[$0]! }),
            "pendingQuestions": .array(questions.keys.sorted().map { questions[$0]! }),
            "pendingInteractions": .array(approvals.keys.sorted().map { .object(["kind": .string("approval"), "id": .string($0), "data": approvals[$0]!, "runtimeConfirmed": .bool(false)]) }
                + questions.keys.sorted().map { .object(["kind": .string("question"), "callId": .string($0), "data": questions[$0]!, "runtimeConfirmed": .bool(false)]) }),
            "cursor": try cursor(log), "observation": .object(["source": .string("released_v4_session_log"), "complete": .bool(!log.pending),
                "pendingTail": .bool(log.pending), "runtimeConfirmed": .bool(false), "inheritedEventCount": .number(Double(log.inherited))])
        ]
    }

    private func text(_ message: JSONValue) -> String {
        (message["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
    }

    private func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.number, number.isFinite, number >= 0, number <= 9_007_199_254_740_991, number.rounded() == number,
              number != 0 || number.sign == .plus else { return nil }
        return Int(number)
    }

    private func failure(_ code: String, _ message: String) -> ControlError { ControlError(code: code, message: message) }
}
