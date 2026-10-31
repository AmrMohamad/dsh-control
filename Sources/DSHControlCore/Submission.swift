import Foundation

extension UIController {
    /// Staging is reversible; every potentially executing trigger pick is protected by a durable receipt.
    public mutating func submit(request: JSONValue, receipts: SendReceipts, store: SessionStore) async throws -> JSONValue {
        let expected = try request.requireString("expect")
        let requestID = try request.requireString("requestId")
        var values = request.object!
        var signatureValue: [String: JSONValue] = ["command": .string("send"), "expect": .string(expected)]
        var file: (url: URL, data: Data, text: String)?
        if let path = request["file"]?.string {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) } catch { throw ControlError(code: "input_file", message: "Cannot read brief file.") }
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_777_217) ?? Data()
            guard data.count <= 16_777_216, let text = String(data: data, encoding: .utf8) else { throw ControlError(code: "input_file", message: "Brief must be valid UTF-8 and at most 16 MiB.") }
            file = (url, data, text)
            signatureValue["fileDigest"] = .string(StateDigest.bytes(data))
            signatureValue["longBrief"] = request["longBrief"] ?? .null
        }
        let signature = try StateDigest.token(.object(signatureValue))
        if let existing = try receipts.lookup(requestID: requestID) {
            guard existing["signature"]?.string == signature else { throw ControlError(code: "request_conflict", message: "This ID already belongs to another inspected submission. Read its receipt; do not resend.", outcome: "unknown", details: existing) }
            return try Self.replayResult(existing)
        }
        var state = try await inspect(sessionID: request["session"]?.string)
        guard state["expect"]?.string == expected else { throw ControlError(code: "stale_state", message: "The app changed before staging; no input was dispatched.", details: state) }
        guard let sessionID = state["session"]?["id"]?.string else { throw ControlError(code: "session_unavailable", message: "An exact GUI session is required before sending.") }
        var attachments: JSONValue?
        var nativeReference: JSONValue?
        var serializedDraft: String?
        if let file {
            guard state["draft"]?.string?.isEmpty != false, state["attachmentCount"]?.number == 0,
                  state["commands"]?.array?.isEmpty != false, state["references"]?.array?.isEmpty != false else {
                throw ControlError(code: "draft_conflict", message: "The composer already contains content; preserve it before --file.")
            }
            let text: String
            if request["longBrief"]?.string == "reference" {
                guard file.url.pathExtension.lowercased() == "md", let cwd = try store.optionalSnapshot(sessionID: sessionID)?["session"]?["cwd"]?.string else {
                    throw ControlError(code: "reference_context_unavailable", message: "Native Markdown references require a durable session with a known working directory.")
                }
                let path = file.url.standardizedFileURL.resolvingSymlinksInPath()
                let mention = try Self.nativeFileMention(path: path.path, cwd: cwd)
                let digest = StateDigest.bytes(file.data)
                try await attach(file: path, sessionID: sessionID, expected: state, nativeReference: true)
                state = try await inspect(sessionID: sessionID)
                guard Self.nativeReferenceReady(state, name: path.lastPathComponent) else {
                    throw ControlError(code: "reference_unverified", message: "The native file reference changed before instruction staging.", outcome: "unknown")
                }
                let refs = state["references"]
                let instruction = "Follow the instructions in the referenced Markdown file."
                let point = try Self.pageResult(try await page(["action": .string("prepare"), "purpose": .string("draft"), "guard": state["guard"]!, "sessionId": .string(sessionID)]))
                try await click(point)
                try await key("ArrowDown", code: "ArrowDown", virtualKey: 40, modifiers: 4, commands: ["moveToEndOfDocument"])
                let ready = try Self.pageResult(try await page(["action": .string("appendReady"), "guard": state["guard"]!, "sessionId": .string(sessionID)]))
                guard ready["ready"]?.bool == true else { throw ControlError(code: "selection_timeout", message: "The composer did not confirm a caret after the file reference.", outcome: "unknown") }
                try await type("\n" + instruction)
                state = try await inspect(sessionID: sessionID)
                guard state["references"] == refs, Self.normalized(state["draft"]?.string ?? "") == Self.normalized(path.lastPathComponent + " " + instruction),
                      try Self.localFileDigest(path) == digest else {
                    throw ControlError(code: "reference_unverified", message: "The staged reference, instruction, or local file bytes changed; nothing was sent.", outcome: "unknown")
                }
                nativeReference = .object(["path": .string(path.path), "mention": .string(mention), "localSHA256": .string(digest), "localBytes": .number(Double(file.data.count)), "verification": .string("durable_text_reference_only")])
                serializedDraft = mention + " " + instruction
                values["allowReferences"] = .bool(true)
                values["expect"] = state["expect"]!
                text = ""
            } else if file.text.utf16.count > Self.maxVerifiableSend {
                guard request["longBrief"]?.string == "attach", file.url.pathExtension.lowercased() == "md" else {
                    throw ControlError(code: "unsupported_length", message: "Use --long-brief attach with a Markdown file for a brief over 12000 UTF-16 units.")
                }
                let digest = StateDigest.bytes(file.data)
                try await attach(file: file.url, sessionID: sessionID, expected: state)
                attachments = .array([.object(["sha256": .string(digest), "bytes": .number(Double(file.data.count)), "name": .string(file.url.lastPathComponent)])])
                text = "Follow the instructions in the attached Markdown brief \(file.url.lastPathComponent). Brief SHA-256: \(digest)."
                state = try await inspect(sessionID: sessionID)
            } else { text = file.text }
            if nativeReference == nil {
                let draft = JSONValue.object(["expect": state["expect"]!, "text": .string(text), "session": .string(sessionID)])
                _ = try await mutate(command: "draft", request: draft, receipts: receipts, store: store)
                state = try await inspect(sessionID: sessionID)
                values["expect"] = state["expect"]!
            }
        }
        let draft = state["draft"]?.string ?? ""
        let slash = draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") || state["commands"]?.array?.isEmpty == false
        let references = draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") || state["references"]?.array?.isEmpty == false
        guard !slash || request["allowSlash"]?.bool == true, !references || values["allowReferences"]?.bool == true else {
            throw ControlError(code: "unsupported_command", message: "Intentional commands/references require --allow-slash/--allow-references.")
        }
        guard slash || references || attachments != nil else {
            return try await mutate(command: "send", request: .object(values), receipts: receipts, store: store, signatureOverride: signature)
        }
        let offered = slash ? try await triggerPoint(draft: draft, sessionID: sessionID, expected: state) : .null
        let nativeSkill = Self.offeredNativeSkill(offered, draft: draft)
        let cursor = try store.optionalSnapshot(sessionID: sessionID)?["cursor"] ?? .null
        var submission: [String: JSONValue] = ["sessionId": .string(sessionID), "cursor": cursor,
            "digest": .string(StateDigest.text(Self.normalized(serializedDraft ?? draft))), "operation": .string(nativeSkill != nil ? "skill" : slash ? "command" : "send")]
        if let nativeSkill { submission["skill"] = .string(nativeSkill) }
        if let attachments { submission["attachments"] = attachments }
        if let nativeReference { submission["nativeFileReference"] = nativeReference }
        let prepared = try receipts.prepare(requestID: requestID, signature: signature, targetID: targetID, submission: .object(submission))
        do {
            if slash || references {
                let picked = try await triggerPoint(draft: draft, sessionID: sessionID, expected: state)
                guard Self.offeredNativeSkill(picked, draft: draft) == nativeSkill else {
                    throw ControlError(code: "stale_state", message: "The offered skill changed before selection.", outcome: "unknown")
                }
                if picked["selectionRequired"]?.bool == true {
                    throw ControlError(code: "selection_required", message: "Trigger selection is missing or ambiguous; inspect the offered GUI choices. This request ID must not be replayed.", outcome: "unknown", details: picked)
                }
                if picked["x"] != nil { try await click(picked) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                repeat {
                    if let evidence = try store.optionalAdmission(.object(submission)) {
                        var record = prepared.object!
                        record["status"] = .string("sent"); record["outcome"] = .string("verified"); record["verification"] = evidence
                        try receipts.finish(requestID: requestID, receipt: .object(record))
                        return .object(["outcome": .string("verified"), "receipt": .object(record), "binding": .object(["sessionId": .string(sessionID)]), "state": try await inspect(sessionID: sessionID)])
                    }
                    state = try await inspect(sessionID: sessionID)
                    if state["menus"]?.number == 0 { break }
                    try await Task.sleep(for: .milliseconds(100))
                } while ContinuousClock.now < deadline
                if references, state["references"]?.array?.isEmpty != false {
                    throw ControlError(code: "selection_required", message: "The GUI did not expose a verifiable reference selection.", outcome: "unknown", details: state)
                }
                if let nativeSkill {
                    guard state["commands"]?.array?.isEmpty != false,
                          (state["draft"]?.string ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) == "/" + nativeSkill else {
                        throw ControlError(code: "selection_required", message: "The selected skill did not remain the expected ordinary prompt.", outcome: "unknown", details: state)
                    }
                } else if slash, state["commands"]?.array?.isEmpty != false {
                    throw ControlError(code: "selection_required", message: "The command may have executed or opened another chooser. Reconcile this receipt before any further submission.", outcome: "unknown", details: state)
                }
            }
            values["expect"] = state["expect"]!
            values["session"] = .string(sessionID)
            return try await mutate(command: "send", request: .object(values), receipts: receipts, store: store, signatureOverride: signature, preparedReceipt: prepared)
        } catch {
            if var record = try receipts.lookup(requestID: requestID)?.object, record["status"]?.string != "sent" {
                record["status"] = .string("uncertain"); record["outcome"] = .string("unknown")
                try receipts.finish(requestID: requestID, receipt: .object(record))
            }
            let failure = error as? ControlError
            throw ControlError(code: failure?.code ?? "submission_failed", message: failure?.message ?? "Submission could not be verified.", outcome: "unknown", details: failure?.details)
        }
    }

    static func offeredNativeSkill(_ selection: JSONValue, draft: String) -> String? {
        guard let id = selection["id"]?.string, id.range(of: "^dsh-slash-option-skill-[0-9]+$", options: .regularExpression) != nil,
              let token = draft.split(whereSeparator: \.isWhitespace).first, token.hasPrefix("/"), token.count > 1 else { return nil }
        return String(token.dropFirst())
    }

    private mutating func attach(file: URL, sessionID: String, expected: JSONValue, nativeReference: Bool = false) async throws {
        let current = try await inspect(sessionID: sessionID)
        guard current["expect"] == expected["expect"] else { throw ControlError(code: "stale_state", message: "The app changed before attachment staging.") }
        let id = String(decoding: try JSONValue.string(sessionID).encoded(), as: UTF8.self)
        let expression = """
        (()=>{const roots=[...document.querySelectorAll('[data-conversation-content][data-conversation-session]')].filter(e=>e.getAttribute('data-conversation-session')===\(id)&&!e.closest('[data-sidebar-chat]'));if(roots.length!==1)return null;const r=roots[0],a=[...r.querySelectorAll('input[type=file]')].filter(e=>e.closest('[data-conversation-content]')===r&&!e.disabled);return a.length===1?a[0]:null})()
        """
        let result = try await cdp.call(method: "Runtime.evaluate", params: .object(["expression": .string(expression), "objectGroup": .string("dsh-file-input")]))
        guard let objectID = result["result"]?["objectId"]?.string else { throw ControlError(code: "unsupported_ui", message: "One enabled GUI file input is required.") }
        _ = try await cdp.call(method: "DOM.getDocument", params: .object(["depth": .number(0)]))
        let node = try await cdp.call(method: "DOM.requestNode", params: .object(["objectId": .string(objectID)]))
        guard let nodeID = node["nodeId"], nodeID.number != 0 else { throw ControlError(code: "unsupported_ui", message: "The GUI file input was not resolved.") }
        do {
            _ = try await cdp.call(method: "DOM.setFileInputFiles", params: .object(["nodeId": nodeID, "files": .array([.string(file.path)])]))
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            repeat {
                let state = try await inspect(sessionID: sessionID)
                if nativeReference {
                    if Self.nativeReferenceReady(state, name: file.lastPathComponent) { return }
                } else if try Self.stagedAttachmentReady(state, name: file.lastPathComponent) { return }
                if state["attachments"]?.array?.contains(where: { $0["status"]?.string == "error" }) == true { break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            throw ControlError(code: "attachment_unverified", message: "The attachment was selected but upload readiness was not verified.", outcome: "unknown")
        } catch let error as ControlError { throw ControlError(code: error.code, message: error.message, outcome: "unknown", details: error.details) }
    }

    static func nativeReferenceReady(_ state: JSONValue, name: String) -> Bool {
        let refs = state["references"]?.array ?? []
        return refs.count == 1 && refs[0]["source"]?.string == "reference" && refs[0]["title"]?.string == name
            && Self.normalized(state["draft"]?.string ?? "") == Self.normalized(name) && state["attachmentCount"]?.number == 0
            && state["commands"]?.array?.isEmpty != false
    }

    static func nativeFileMention(path: String, cwd: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0 == "\"" }) else {
            throw ControlError(code: "invalid_path", message: "The native file-reference grammar cannot represent this path.")
        }
        let root = cwd.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return relative.contains(where: \.isWhitespace) ? "@\"" + relative + "\"" : "@" + relative
    }

    private static func localFileDigest(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16_777_217) ?? Data()
        guard data.count <= 16_777_216 else { throw ControlError(code: "input_file", message: "Brief exceeds 16 MiB.") }
        return StateDigest.bytes(data)
    }

    static func stagedAttachmentReady(_ state: JSONValue, name: String) throws -> Bool {
        if state["references"]?.array?.contains(where: { $0["source"]?.string == "reference" && $0["title"]?.string == name }) == true {
            throw ControlError(code: "native_file_reference", message: "The desktop inserted a filesystem reference instead of uploading file bytes. The chip is preserved and nothing was sent; --long-brief attach requires a byte attachment.", outcome: "unknown")
        }
        guard let item = state["attachments"]?.array?.first else { return false }
        return state["attachmentCount"]?.number == 1 && item["name"]?.string == name && item["status"]?.string == "ready"
    }

    private mutating func triggerPoint(draft: String, sessionID: String, expected: JSONValue) async throws -> JSONValue {
        let fresh = try await inspect(sessionID: sessionID)
        guard fresh["expect"] == expected["expect"] else { throw ControlError(code: "stale_state", message: "The trigger menu changed before selection.") }
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let wanted = String(decoding: try JSONValue.string(String(token.dropFirst())).encoded(), as: UTF8.self)
        return try await cdp.evaluate(expression: """
        (()=>{const shown=e=>e.getClientRects().length>0&&!e.closest('[hidden],[inert],[aria-hidden=true]');const menus=[...document.querySelectorAll('[data-trigger-menu]')].filter(shown);if(!menus.length)return {alreadySelected:true};const options=menus.flatMap(e=>[...e.querySelectorAll('[role=option]')]).filter(shown);const a=options.filter(e=>[...e.querySelectorAll('span')].some(s=>s.textContent.trim().replace(/^[/@]/,'')===\(wanted)));if(a.length!==1)return {selectionRequired:true,options:options.map(e=>({id:e.id,text:e.innerText}))};const e=a[0];e.scrollIntoView({block:'nearest'});const r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;if(!e.contains(document.elementFromPoint(x,y)))return {selectionRequired:true};return {x,y,id:e.id}})()
        """)
    }

    public mutating func cancelFamily(request: JSONValue, receipts: SendReceipts, store: SessionStore, claims: SessionClaims, application: HarnessApplication) async throws -> JSONValue {
        let initial = try await inspect(sessionID: request["session"]?.string)
        guard initial["expect"]?.string == request["expect"]?.string, let root = initial["session"]?["id"]?.string else { throw ControlError(code: "stale_state", message: "Cancellation target changed.") }
        let children = try store.snapshot(sessionID: root)["subagents"]?.array ?? []
        var results: [JSONValue] = []
        for (index, id) in ([root] + children.compactMap { $0["id"]?.string }).enumerated() {
            do {
                var state = try await inspect(sessionID: id)
                if state["uiAvailable"]?.bool == false {
                    let selected = try await navigation(command: "open-session", request: .object(["expect": try await inspect()["expect"]!, "sessionId": .string(id)]), store: store, claims: claims, application: application)
                    _ = selected; state = try await inspect(sessionID: id)
                }
                if state["running"]?.bool == true {
                    let stopped = try await mutate(command: "cancel", request: .object(["expect": state["expect"]!, "session": .string(id)]), receipts: receipts, store: store)
                    results.append(.object(["sessionId": .string(id), "result": stopped]))
                } else { results.append(.object(["sessionId": .string(id), "outcome": .string(state["uiAvailable"]?.bool == true ? "observed_idle" : "unavailable")])) }
            } catch let error as ControlError {
                results.append(.object(["sessionId": .string(id), "code": .string(error.code), "outcome": .string(error.outcome)]))
                if index == 0 { break }
            }
        }
        return .object(["outcome": .string("partial"), "sessions": .array(results), "coverage": .string("known direct children only; new, external and unobserved descendants may remain active")])
    }
}
