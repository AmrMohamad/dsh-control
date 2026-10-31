import Foundation

extension UIController {
    /// Navigate and configure through inspected GUI controls. The caller holds MutationLock.
    public mutating func navigation(command: String, request: JSONValue, store: SessionStore, claims: SessionClaims, application: HarnessApplication) async throws -> JSONValue {
        let command = ["select-session": "open-session", "set-access-mode": "set-access"][command] ?? command
        let expected = try request.requireString("expect")
        var sessionID = request["sessionId"]?.string ?? request["session"]?.string ?? request["id"]?.string
        let before = try await inspect(sessionID: ["set-model", "set-effort", "set-access"].contains(command) ? sessionID : nil)
        if sessionID == nil, ["set-model", "set-effort", "set-access"].contains(command) { sessionID = before["displayedSessionId"]?.string }
        let replayingCreation = try command == "new-session" && claims.request(request.requireString("requestId")) != nil
        guard replayingCreation || before["expect"]?.string == expected else { throw ControlError(code: "stale_state", message: "The app changed since inspection; inspect again before navigation", details: before) }
        if command == "release-session" {
            guard let sessionID else { throw ControlError(code: "invalid_request", message: "Release requires a session ID") }
            return try claims.release(sessionID: sessionID, requestID: request.requireString("requestId"))
        }
        if command == "new-session" { return try await createSession(request: request, before: before, store: store, claims: claims, application: application) }
        if command == "add-workspace" {
            let path = try NativePicker.canonicalDirectory(request["path"]?.string ?? request.requireString("cwd"))
            if let existing = try store.workspaces().first(where: { $0["path"]?.string == path.path }) {
                return .object(["status": .string("existing"), "outcome": .string("verified"), "workspace": existing])
            }
            let picker = NativePicker(application: application)
            let pid = try picker.preflight()
            var dispatched = false
            do {
                try await navigationClick(.object(["kind": .string("addWorkspace")]), dispatched: &dispatched)
                try await picker.choose(path: path, pid: pid, timeout: timeout)
                let deadline = Date().addingTimeInterval(timeout)
                repeat {
                    do {
                        let rows = try store.workspaces().filter { $0["path"]?.string == path.path }
                        if rows.count == 1 { return .object(["status": .string("added"), "outcome": .string("verified"), "workspace": rows[0]]) }
                    } catch let error as ControlError where ["workspace_store_pending", "session_store_busy"].contains(error.code) {
                        // The registry publishes a short-lived mutation marker before its completed record.
                    }
                    try await Task.sleep(for: .milliseconds(100))
                } while Date() < deadline
                throw ControlError(code: "workspace_unconfirmed", message: "Folder chooser completed but the exact workspace ID and directory were not observed", outcome: "unknown")
            } catch { throw navigationFailure(error, dispatched: dispatched) }
        }
        if command == "open-session" {
            let id: String
            if let sessionID { id = sessionID }
            else {
                let title = try request.requireString("title")
                let matches = try store.sessions().filter { $0["session"]?["title"]?.string == title }
                guard matches.count == 1, let match = matches[0]["session"]?["id"]?.string else {
                    throw ControlError(code: "ambiguous_session", message: "The title must identify exactly one session; use its ID")
                }
                id = match
            }
            var dispatched = false
            do {
                try await revealSidebar(dispatched: &dispatched)
                var state = try await inspect()
                var visible = try await navigationProbe(.object(["kind": .string("rowState"), "id": .string("session:" + id)]), state: state)
                if visible["present"]?.bool != true {
                    let session = try store.snapshot(sessionID: id)["session"]
                    if session?["sessionKind"]?.string == "subagent", let parentID = session?["parentSessionId"]?.string {
                        let catalog = try store.snapshot(sessionID: parentID)["subagents"]?.array ?? []
                        let label = try Self.uniqueSubagentLabel(sessionID: id, catalog: catalog)
                        if state["displayedSessionId"]?.string != parentID {
                            _ = try await navigation(command: "open-session", request: .object(["sessionId": .string(parentID), "expect": state["expect"]!]), store: store, claims: claims, application: application)
                            dispatched = true
                        }
                        try await navigationClick(.object(["kind": .string("subagentTrigger")]), dispatched: &dispatched, sessionID: parentID)
                        try await navigationClick(.object(["kind": .string("subagentRow"), "label": .string(label)]), dispatched: &dispatched, sessionID: parentID)
                        let after = try await navigationWait(sessionID: id) { $0["uiAvailable"]?.bool != false && $0["displayedSessionId"]?.string == id }
                        return .object(["outcome": .string("verified"), "sessionId": .string(id), "state": after])
                    }
                    if let cwd = session?["cwd"]?.string,
                       let workspace = try store.workspaces().first(where: { $0["path"]?.string == cwd }) {
                        try await revealWorkspace(workspace, store: store, dispatched: &dispatched)
                    }
                    state = try await inspect()
                    visible = try await navigationProbe(.object(["kind": .string("rowState"), "id": .string("session:" + id)]), state: state)
                }
                if visible["present"]?.bool == true {
                    try await navigationClick(.object(["kind": .string("session"), "id": .string(id)]), dispatched: &dispatched)
                } else {
                    let title = try Self.uniqueSearchTitle(sessionID: id, sessions: [store.snapshot(sessionID: id)])
                    try await navigationClick(.object(["kind": .string("sessionSearch")]), dispatched: &dispatched)
                    try await navigationClick(.object(["kind": .string("searchInput")]), dispatched: &dispatched)
                    try await key("a", code: "KeyA", virtualKey: 65, modifiers: 4, commands: ["selectAll"])
                    let query = Self.sessionSearchQuery(title)
                    try await type(query)
                    let deadline = Date().addingTimeInterval(timeout)
                    var found = false
                    repeat {
                        let state = try await inspect()
                        let results = try await navigationProbe(.object(["kind": .string("searchResultState"), "title": .string(title)]), state: state)
                        if results["matches"] == .number(1), results["query"]?.string == query { found = true; break }
                        try await Task.sleep(for: .milliseconds(100))
                    } while Date() < deadline
                    guard found else { throw ControlError(code: "session_search_unconfirmed", message: "The GUI search did not expose exactly one result with the session's unique title", outcome: "unknown") }
                    guard try Self.uniqueSearchTitle(sessionID: id, sessions: [store.snapshot(sessionID: id)]) == title else {
                        throw ControlError(code: "session_changed", message: "The session title changed during search", outcome: "unknown")
                    }
                    try await navigationClick(.object(["kind": .string("searchResult"), "title": .string(title)]), dispatched: &dispatched)
                }
                let after = try await navigationWait(sessionID: id) { $0["uiAvailable"]?.bool != false && $0["displayedSessionId"]?.string == id }
                return .object(["outcome": .string("verified"), "sessionId": .string(id), "state": after])
            } catch { throw navigationFailure(error, dispatched: dispatched) }
        }
        guard let sessionID, before["uiAvailable"]?.bool != false, before["displayedSessionId"]?.string == sessionID else {
            throw ControlError(code: "session_not_visible", message: "Select the exact session in the main conversation before configuring it")
        }
        var dispatched = false
        var modelVerified = false
        do {
            if command == "set-model" || command == "set-effort" {
                if command == "set-model" {
                    let model = try request.requireString("model")
                    let modelState = try await inspect(sessionID: sessionID)
                    if try await navigationProbe(.object(["kind": .string("modelValue")]), state: modelState)["open"]?.bool != true {
                        try await navigationClick(.object(["kind": .string("modelTrigger")]), dispatched: &dispatched, sessionID: sessionID)
                    }
                    try await navigationClick(.object(["kind": .string("modelPane")]), dispatched: &dispatched, sessionID: sessionID)
                    let provider: String
                    if let requested = request["provider"]?.string { provider = requested }
                    else {
                        let state = try await inspect(sessionID: sessionID)
                        let matches = try await navigationProbe(.object(["kind": .string("modelProviders"), "model": .string(model)]), state: state)["providers"]?.array ?? []
                        guard matches.count == 1, let exact = matches[0].string else { throw ControlError(code: "ambiguous_model", message: "Model ID must identify one offered provider; specify --provider") }
                        provider = exact
                    }
                    try await navigationClick(.object(["kind": .string("modelOption"), "provider": .string(provider), "model": .string(model)]), dispatched: &dispatched, sessionID: sessionID)
                    _ = try await navigationWaitProbe(sessionID: sessionID, selector: .object(["kind": .string("modelValue")]), fields: ["provider": .string(provider), "model": .string(model), "open": .bool(false)])
                    modelVerified = true
                }
                if let effort = request["effort"]?.string {
                    let label = try Self.effortLabel(effort)
                    let effortState = try await inspect(sessionID: sessionID)
                    if try await navigationProbe(.object(["kind": .string("modelValue")]), state: effortState)["open"]?.bool != true {
                        try await navigationClick(.object(["kind": .string("modelTrigger")]), dispatched: &dispatched, sessionID: sessionID)
                    }
                    try await navigationClick(.object(["kind": .string("effortPane")]), dispatched: &dispatched, sessionID: sessionID)
                    let choicesState = try await inspect(sessionID: sessionID)
                    let choices = try await navigationProbe(.object(["kind": .string("effortChoices")]), state: choicesState)["choices"]?.array ?? []
                    guard choices.contains(.string(label)) else {
                        throw ControlError(code: "unsupported_effort", message: "The selected model does not offer the requested reasoning effort", details: .object(["requested": .string(label), "available": .array(choices)]))
                    }
                    try await navigationClick(.object(["kind": .string("effortOption"), "label": .string(label)]), dispatched: &dispatched, sessionID: sessionID)
                    _ = try await navigationWaitProbe(sessionID: sessionID, selector: .object(["kind": .string("modelValue")]), fields: ["effort": .string(label), "open": .bool(false)])
                } else if command == "set-effort" { throw ControlError(code: "invalid_request", message: "Expected an effort field") }
            } else if command == "set-access" {
                let requestedAccess = try request["access"]?.string ?? request.requireString("mode")
                let access = ["danger-full-access": "full-access", "auto": "auto-review"][requestedAccess] ?? requestedAccess
                let labels = ["read-only": ["Read Only", "仅可查看"], "workspace-write": ["Workspace Write", "工作区内修改"],
                    "full-access": ["Full access", "完全权限"], "auto-review": ["Auto review", "自动审查"]]
                guard let names = labels[access] else { throw ControlError(code: "invalid_request", message: "Unsupported access mode") }
                let risky = ["full-access", "auto-review"].contains(access)
                guard !risky || request["confirmRisk"]?.bool == true else { throw ControlError(code: "risk_confirmation_required", message: "This access mode requires --confirm-risk") }
                let probe = try await navigationProbe(.object(["kind": .string("accessValue")]), state: before)
                if !names.contains(probe["label"]?.string ?? "") {
                    try await navigationClick(.object(["kind": .string("accessTrigger")]), dispatched: &dispatched, sessionID: sessionID)
                    try await navigationClick(.object(["kind": .string("accessOption"), "names": .array(names.map(JSONValue.string))]), dispatched: &dispatched, sessionID: sessionID)
                    if risky {
                        try await navigationClick(.object(["kind": .string("riskCheckbox"), "access": .string(access)]), dispatched: &dispatched, sessionID: sessionID)
                        try await navigationClick(.object(["kind": .string("riskConfirm"), "access": .string(access)]), dispatched: &dispatched, sessionID: sessionID)
                    }
                    let label = before["language"]?.string == "zh" ? names[1] : names[0]
                    _ = try await navigationWaitProbe(sessionID: sessionID, selector: .object(["kind": .string("accessValue")]), fields: ["label": .string(label)])
                }
            } else { throw ControlError(code: "invalid_command", message: "Unsupported navigation command") }
            return .object(["outcome": .string("verified"), "sessionId": .string(sessionID), "state": try await inspect(sessionID: sessionID)])
        } catch {
            let failure = navigationFailure(error, dispatched: dispatched)
            if modelVerified {
                throw ControlError(code: failure.code, message: "Model selection was verified; reasoning effort was not verified. " + failure.message,
                    outcome: "unknown", details: .object(["partial": .bool(true), "modelVerified": .bool(true), "effortVerified": .bool(false), "failure": .string(failure.code), "failureDetails": failure.details ?? .null]))
            }
            throw failure
        }
    }

    private mutating func createSession(request: JSONValue, before: JSONValue, store: SessionStore, claims: SessionClaims, application: HarnessApplication) async throws -> JSONValue {
        let requestID = try request.requireString("requestId")
        let title = request["title"]?.string
        if let title { guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 2000, !title.contains("\n") else {
            throw ControlError(code: "invalid_request", message: "Title must be nonempty, single-line, and at most 2000 UTF-8 bytes")
        } }
        let selectors = ["workspaceId", "workspace", "cwd"].filter { request[$0] != nil }
        guard selectors.count == 1 else { throw ControlError(code: "invalid_request", message: "Choose exactly one workspace ID, unique workspace title, or existing directory") }
        let canonicalPath = try request["cwd"]?.string.map { try NativePicker.canonicalDirectory($0).path }
        let selectorKey = selectors[0]
        let selectorValue = canonicalPath.map(JSONValue.string) ?? request[selectorKey]!
        let signature = try StateDigest.token(.object([selectorKey: selectorValue, "title": title.map(JSONValue.string) ?? .null]))
        if let receipt = try claims.request(requestID) {
            guard receipt["signature"]?.string == signature else { throw ControlError(code: "request_conflict", message: "Creation request ID belongs to different parameters", outcome: "unknown", details: receipt) }
            guard receipt["status"]?.string == "completed", let result = receipt["result"]?.object else { throw ControlError(code: "creation_uncertain", message: "Creation was already attempted; inspect existing sessions before choosing a new request ID", outcome: "unknown", details: receipt) }
            return .object(result.merging(["replayedReceipt": .bool(true)]) { _, new in new })
        }
        let workspaces = try store.workspaces()
        var matches: [JSONValue]
        if let id = request["workspaceId"]?.string { matches = workspaces.filter { $0["id"]?.string == id } }
        else if let title = request["workspace"]?.string { matches = workspaces.filter { $0["title"]?.string == title } }
        else { matches = workspaces.filter { $0["path"]?.string == canonicalPath } }
        guard matches.count == 1 || matches.isEmpty && canonicalPath != nil else {
            throw ControlError(code: "ambiguous_workspace", message: "Workspace selector must identify exactly one registered workspace")
        }
        try claims.prepare(requestID: requestID, signature: signature)
        var dispatched = false
        do {
            try await revealSidebar(dispatched: &dispatched)
            if matches.isEmpty, let canonicalPath {
                let current = try await inspect()
                let result = try await navigation(command: "add-workspace", request: .object(["path": .string(canonicalPath), "expect": current["expect"]!]), store: store, claims: claims, application: application)
                dispatched = true
                guard let workspace = result["workspace"] else { throw ControlError(code: "workspace_unconfirmed", message: "The GUI-added workspace was not verified", outcome: "unknown") }
                matches = [workspace]
            }
            guard let workspaceID = matches[0]["id"]?.string, let cwd = matches[0]["path"]?.string else {
                throw ControlError(code: "workspace_unconfirmed", message: "Workspace identity and directory are unavailable", outcome: "unknown")
            }
            try await revealWorkspace(matches[0], store: store, dispatched: &dispatched)
            let current = try await inspect()
            let oldRows = try await navigationProbe(.object(["kind": .string("sessionRows")]), state: current)["ids"]?.array ?? []
            // The product may reuse a provisional row. Inspect and reserve the resulting identity, never synthesize a prompt.
            try await navigationClick(.object(["kind": .string("workspaceNew"), "id": .string(workspaceID)]), dispatched: &dispatched)
            let after = try await navigationBlank(workspaceID: workspaceID)
            guard let id = after["displayedSessionId"]?.string else { throw ControlError(code: "session_unconfirmed", message: "New session identity was not observed", outcome: "unknown") }
            guard try claims.claim(id) == nil else { throw ControlError(code: "session_claimed", message: "The app reused a session reserved by another request", outcome: "unknown") }
            let blank = try await navigationProbe(.object(["kind": .string("blank"), "id": .string(id)]), state: after)
            guard blank["blank"]?.bool == true, blank["workspaceId"]?.string == workspaceID, after["attachmentCount"] == .number(0), after["draft"]?.string == "", after["running"]?.bool == false,
                  (after["messages"]?.array ?? []).isEmpty else { throw ControlError(code: "session_not_empty", message: "The selected session is not an empty, attachment-free provisional session", outcome: "unknown") }
            do {
                let durable = try store.snapshot(sessionID: id)
                guard durable["session"]?["cwd"]?.string == cwd, (durable["messages"]?.array ?? []).isEmpty, (durable["turns"]?.array ?? []).isEmpty,
                      durable["session"]?["title"] == .null else { throw ControlError(code: "session_not_empty", message: "Durable session data conflicts with the empty workspace session", outcome: "unknown") }
            } catch let error as ControlError where error.code == "session_not_found" {
                // A provisional GUI session may not have a durable log yet.
            }
            // Recheck after filesystem observation and before reserving the identity.
            let fresh = try await inspect(sessionID: id)
            guard fresh["expect"] == after["expect"], try await navigationProbe(.object(["kind": .string("blank"), "id": .string(id)]), state: fresh)["blank"]?.bool == true else {
                throw ControlError(code: "stale_state", message: "Provisional session changed before reservation", outcome: "unknown")
            }
            return try claims.reserve(sessionID: id, requestID: requestID, signature: signature, title: title, reused: oldRows.contains(.string(id)))
        } catch { throw navigationFailure(error, dispatched: dispatched) }
    }

    /// Apply a reserved title only immediately after a verified first human send. Failure never changes send success.
    public mutating func applyPendingTitle(sessionID: String, claims: SessionClaims, store: SessionStore = SessionStore()) async -> JSONValue {
        var dispatched = false
        do {
            guard let claim = try claims.claim(sessionID), claim["titleStatus"]?.string == "pending", let title = claim["pendingTitle"]?.string else {
                return .object(["status": .string("none")])
            }
            let before = try await inspect(sessionID: sessionID)
            guard before["displayedSessionId"]?.string == sessionID, before["uiAvailable"]?.bool != false else { return .object(["status": .string("pending"), "reason": .string("session_not_visible")]) }
            let durable = try store.snapshot(sessionID: sessionID)
            guard Self.canApplyPendingTitle(title: durable["session"]?["title"], events: try store.events(sessionID: sessionID)) else {
                try claims.titleFinished(sessionID: sessionID, status: "skipped_user_title")
                return .object(["status": .string("skipped_user_title")])
            }
            // The claim is consumed before input so a crash cannot repeat a potentially completed rename.
            try claims.titleFinished(sessionID: sessionID, status: "unknown")
            try await navigationClick(.object(["kind": .string("sessionMenu"), "id": .string(sessionID)]), dispatched: &dispatched, sessionID: sessionID)
            try await navigationClick(.object(["kind": .string("renameMenu")]), dispatched: &dispatched, sessionID: sessionID)
            try await navigationClick(.object(["kind": .string("renameInput")]), dispatched: &dispatched, sessionID: sessionID)
            try await key("a", code: "KeyA", virtualKey: 65, modifiers: 4, commands: ["selectAll"])
            try await type(title)
            let currentTitle = try store.snapshot(sessionID: sessionID)["session"]?["title"]
            guard Self.canApplyPendingTitle(title: currentTitle, events: try store.events(sessionID: sessionID)) else {
                try await key("Escape", code: "Escape", virtualKey: 27)
                try claims.titleFinished(sessionID: sessionID, status: "skipped_user_title")
                return .object(["status": .string("skipped_user_title")])
            }
            try await navigationClick(.object(["kind": .string("renameConfirm")]), dispatched: &dispatched, sessionID: sessionID)
            _ = try await navigationWaitProbe(sessionID: sessionID, selector: .object(["kind": .string("renameStatus"), "id": .string(sessionID)]), fields: ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines))])
            try claims.titleFinished(sessionID: sessionID, status: "applied")
            return .object(["status": .string("applied")])
        } catch {
            let failure = navigationFailure(error, dispatched: dispatched)
            return .object(["status": .string("unknown"), "code": .string(failure.code), "message": .string(failure.message)])
        }
    }

    static func canApplyPendingTitle(title: JSONValue?, events: [JSONValue]) -> Bool {
        if title == .null || title?.string == "" { return true }
        guard let lastTitle = events.last(where: { $0["type"]?.string == "session/title" })?["data"],
              lastTitle["title"] == title, let kind = lastTitle["source"]?["kind"]?.string else { return false }
        return ["fallback", "provider"].contains(kind)
    }

    static func effortLabel(_ effort: String) throws -> String {
        let labels = ["off": "Off", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Xhigh", "max": "Max", "default": "Default"]
        guard let label = labels[effort.lowercased()] else { throw ControlError(code: "invalid_request", message: "Unsupported reasoning effort") }
        return label
    }

    static func uniqueSearchTitle(sessionID: String, sessions: [JSONValue]) throws -> String {
        let target = sessions.filter { $0["session"]?["id"]?.string == sessionID }
        guard target.count == 1, let title = target[0]["session"]?["title"]?.string,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sessions.filter({ $0["session"]?["title"]?.string == title }).count == 1 else {
            throw ControlError(code: "ambiguous_session", message: "A hidden session needs a unique nonempty title for GUI search; reveal it manually when titles are missing or shared")
        }
        return title
    }

    static func sessionSearchQuery(_ title: String) -> String {
        var units = Array(title.utf16.filter { $0 != 0 }.prefix(500))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func uniqueSubagentLabel(sessionID: String, catalog: [JSONValue]) throws -> String {
        let matches = catalog.filter { $0["id"]?.string == sessionID && $0["mode"]?.string != "external" }
        guard matches.count == 1, let entry = matches.first else { throw ControlError(code: "subagent_unavailable", message: "The requested child is not a unique local catalog entry") }
        let label = entry["label"]?.string ?? sessionID
        guard !label.isEmpty, catalog.filter({ ($0["label"]?.string ?? $0["id"]?.string) == label }).count == 1 else {
            throw ControlError(code: "ambiguous_subagent", message: "The child label does not uniquely identify one catalog entry")
        }
        return label
    }

    private mutating func revealSidebar(dispatched: inout Bool) async throws {
        let state = try await inspect()
        let sidebar = try await navigationProbe(.object(["kind": .string("sidebarState")]), state: state)
        if sidebar["collapsed"]?.bool == true {
            try await navigationClick(.object(["kind": .string("sidebarOpen")]), dispatched: &dispatched)
        }
        let current = try await inspect()
        let search = try await navigationProbe(.object(["kind": .string("sidebarState")]), state: current)
        if search["searchOpen"]?.bool == true {
            try await navigationClick(.object(["kind": .string("searchClear")]), dispatched: &dispatched)
        }
    }

    private mutating func revealWorkspace(_ workspace: JSONValue, store: SessionStore, dispatched: inout Bool) async throws {
        guard let id = workspace["id"]?.string, let path = workspace["path"]?.string else {
            throw ControlError(code: "workspace_unconfirmed", message: "Workspace identity and directory are unavailable")
        }
        let ancestors = try store.workspaces().filter {
            guard let ancestor = $0["path"]?.string else { return false }
            return ancestor == path || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
        }.sorted { ($0["path"]?.string?.count ?? 0) < ($1["path"]?.string?.count ?? 0) }
        for ancestor in ancestors {
            guard let ancestorID = ancestor["id"]?.string else { continue }
            let state = try await inspect()
            let row = try await navigationProbe(.object(["kind": .string("rowState"), "id": .string("workspace:" + ancestorID)]), state: state)
            if row["present"]?.bool == true, row["expanded"]?.string == "false" {
                try await navigationClick(.object(["kind": .string("workspaceExpand"), "id": .string(ancestorID)]), dispatched: &dispatched)
            }
        }
        let state = try await inspect()
        let row = try await navigationProbe(.object(["kind": .string("rowState"), "id": .string("workspace:" + id)]), state: state)
        // A flat sidebar has no workspace rows; session selection can still use its search.
        if row["present"]?.bool == true, row["expanded"]?.string == "false" {
            throw ControlError(code: "workspace_unconfirmed", message: "The workspace did not remain expanded", outcome: "unknown")
        }
    }

    private func navigationFailure(_ error: any Error, dispatched: Bool) -> ControlError {
        let failure = error as? ControlError
        return ControlError(code: failure?.code ?? "navigation_failed", message: failure?.message ?? "GUI navigation failed", outcome: dispatched ? "unknown" : failure?.outcome ?? "not_performed", details: failure?.details)
    }

    private mutating func navigationClick(_ selector: JSONValue, dispatched: inout Bool, sessionID: String? = nil) async throws {
        var state = try await inspect(sessionID: sessionID)
        if let sessionID { guard state["displayedSessionId"]?.string == sessionID, state["uiAvailable"]?.bool != false else {
            throw ControlError(code: "session_changed", message: "The requested main conversation is no longer visible")
        } }
        if let kind = selector["kind"]?.string, ["workspaceNew", "sessionMenu"].contains(kind), let id = selector["id"]?.string {
            let key = (kind == "workspaceNew" ? "workspace:" : "session:") + id
            let row = try await navigationProbe(.object(["kind": .string("rowHit"), "key": .string(key)]), state: state)
            _ = try await cdp.call(method: "Input.dispatchMouseEvent", params: .object(["type": .string("mouseMoved"), "x": row["x"]!, "y": row["y"]!]))
            state = try await inspect(sessionID: sessionID)
        }
        let point = try await navigationProbe(selector, state: state)
        dispatched = true
        try await click(point)
        _ = try await cdp.evaluate(expression: "new Promise(r => setTimeout(() => r(true), 0))")
    }

    private mutating func navigationWait(sessionID: String?, predicate: (JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let state = try await inspect(sessionID: sessionID)
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw ControlError(code: "navigation_unconfirmed", message: "The GUI change could not be verified; no automatic retry was attempted", outcome: "unknown")
    }

    private mutating func navigationWaitProbe(sessionID: String, selector: JSONValue, fields: [String: JSONValue]) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let state = try await inspect(sessionID: sessionID)
            guard state["displayedSessionId"]?.string == sessionID, state["uiAvailable"]?.bool != false else {
                throw ControlError(code: "session_changed", message: "The requested main conversation changed during verification", outcome: "unknown")
            }
            let probe = try await navigationProbe(selector, state: state)
            if fields.allSatisfy({ probe[$0.key] == $0.value }), (state["dialogs"]?.array ?? []).isEmpty { return state }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw ControlError(code: "navigation_unconfirmed", message: "The GUI configuration could not be verified; no automatic retry was attempted", outcome: "unknown")
    }

    private mutating func navigationBlank(workspaceID: String) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let state = try await inspect()
            if let id = state["displayedSessionId"]?.string, state["uiAvailable"]?.bool != false,
               state["attachmentCount"] == .number(0), state["draft"]?.string == "", state["running"]?.bool == false,
               (state["messages"]?.array ?? []).isEmpty {
                do {
                    let blank = try await navigationProbe(.object(["kind": .string("blank"), "id": .string(id)]), state: state)
                    if blank["blank"]?.bool == true, blank["workspaceId"]?.string == workspaceID { return state }
                } catch let error as ControlError where ["ambiguous_control", "stale_state"].contains(error.code) {
                    // The selected occurrence can render before its sidebar row; poll observation only.
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw ControlError(code: "session_unconfirmed", message: "An empty session in the requested workspace was not observed; no automatic retry was attempted", outcome: "unknown")
    }

    private mutating func navigationProbe(_ selector: JSONValue, state: JSONValue) async throws -> JSONValue {
        let request: JSONValue = .object(["selector": selector, "guard": state["guard"] ?? .null, "sessionId": state["guard"]?["conversationSession"] ?? .null])
        let expression = "(\(Self.navigationScript))(\(String(decoding: try request.encoded(), as: UTF8.self)), \(PageAdapter.script))"
        return try Self.pageResult(try await cdp.evaluate(expression: expression))
    }

    private static let navigationScript = #"""
    async (request, inspect) => { try {
      const fail=(code,message)=>{throw {code,message}};
      const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
      const state=await inspect({action:'inspect',sessionId:request.sessionId});
      if(JSON.stringify(canonical(state.guard))!==JSON.stringify(canonical(request.guard))) fail('stale_state','The UI changed before input dispatch.');
      if(state.guard.url!=='dsh-app://app/'||!['en','zh'].includes(state.language))fail('unsupported_ui','Expected the Harness product page in a supported locale.');
      const shown=e=>e instanceof Element&&!e.closest('[hidden],[aria-hidden="true"],[inert]')&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
      const text=e=>(e?.innerText||e?.textContent||'').trim();
      const name=e=>e.getAttribute('aria-label')||text(e);
      const all=(s,root=document)=>[...root.querySelectorAll(s)].filter(shown);
      const one=(a)=>{if(a.length!==1)fail('ambiguous_control','Expected one visible control for the requested action.');return a[0]};
      const row=id=>one(all('[data-row-key]').filter(e=>e.getAttribute('data-row-key')===id));
      const buttons=(root=document)=>all('button,[role="button"]',root);
      const s=request.selector, kind=s.kind, zh=state.language==='zh';
      const main=()=>one(all('[data-conversation-session]').filter(e=>e.getAttribute('data-conversation-session')===state.displayedSessionId&&!e.closest('[data-sidebar-chat]')));
      const modelTrigger=()=>one(buttons(main()).filter(e=>/^(Select model(?:,|$)|选择模型|请选择模型)/.test(name(e))));
      const accessTrigger=()=>one(buttons(main()).filter(e=>/^(Access mode, current: |访问模式，当前：)/.test(name(e))));
      const ownedMenu=()=>{const trigger=modelTrigger(),id=trigger.getAttribute('aria-controls');if(!id)fail('menu_closed','Open the model menu first.');const menu=document.getElementById(id);if(!menu||!shown(menu))fail('menu_closed','The model-owned menu is unavailable.');return menu};
      let e;
      if(kind==='rowState'){const rows=all('[data-row-key]').filter(e=>e.getAttribute('data-row-key')===s.id);if(rows.length>1)fail('ambiguous_control','More than one row has the requested identity.');return {present:rows.length===1,expanded:rows[0]?.getAttribute('aria-expanded')||null}}
      if(kind==='sidebarState'){const open=buttons().filter(e=>['Open sidebar','打开侧边栏'].includes(name(e))),clear=buttons().filter(e=>['Clear search','清除搜索'].includes(name(e)));if(open.length>1||clear.length>1)fail('ambiguous_control','The sidebar state is ambiguous.');return {collapsed:open.length===1,searchOpen:clear.length===1}}
      if(kind==='sessionRows') return {ids:all('[data-row-key]').map(e=>e.getAttribute('data-row-key')).filter(k=>k.startsWith('session:')).map(k=>k.slice(8))};
      if(kind==='rowHit')e=row(s.key);
      else if(kind==='session')e=row('session:'+s.id);
      else if(kind==='sidebarOpen')e=one(buttons().filter(e=>['Open sidebar','打开侧边栏'].includes(name(e))));
      else if(kind==='workspaceExpand'){const r=row('workspace:'+s.id);if(r.getAttribute('aria-expanded')!=='false')fail('stale_state','The workspace is no longer collapsed.');e=r.children[2]||r;}
      else if(kind==='sessionSearch')e=one(buttons().filter(e=>['Search sessions','搜索会话'].includes(name(e))));
      else if(kind==='searchClear')e=one(buttons().filter(e=>['Clear search','清除搜索'].includes(name(e))));
      else if(kind==='searchInput')e=one(all('input').filter(e=>['Search session names','搜索会话名称'].includes(e.getAttribute('placeholder'))));
      else if(kind==='searchResult'||kind==='searchResultState'){
        const trees=all('[role="tree"]').filter(e=>['Search results','搜索结果'].includes(name(e)));
        if(trees.length>1)fail('ambiguous_control','More than one session-search result list is visible.');
        const matches=trees.length?all('[role="treeitem"]',trees[0]).filter(e=>text(e.children[0]?.children[1])===s.title&&!e.hasAttribute('aria-description')):[];
        if(kind==='searchResultState'){const input=all('input').filter(e=>['Search session names','搜索会话名称'].includes(e.getAttribute('placeholder')));return {matches:matches.length,query:input.length===1?input[0].value:null};}
        e=one(matches);
      }
      else if(kind==='workspaceNew')e=one(buttons(row('workspace:'+s.id)).filter(e=>/^(New session in |在“.*”中新建会话$)/.test(name(e))));
      else if(kind==='addWorkspace')e=one(buttons().filter(e=>['Add workspace','添加工作区'].includes(name(e))));
      else if(kind==='subagentTrigger'){const header=one(all('header').filter(e=>e.querySelector('[data-conversation-header-leading]')&&!e.closest('[data-sidebar-chat]')));e=one(buttons(header).filter(e=>e.getAttribute('aria-haspopup')==='tree'&&/^(\d+ subagents?(?: running)?|\d+ 个子智能体(?:，正在运行)?)$/.test(name(e))));}
      else if(kind==='subagentRow'){const tree=one(all('[role="tree"]').filter(e=>['Subagent sessions','子智能体会话'].includes(name(e))));e=one(all('[role="treeitem"]',tree).filter(e=>[...e.querySelectorAll('span')].some(n=>text(n)===s.label)));}
      else if(['blank','renameStatus'].includes(kind)){
        const r=row('session:'+s.id),actions=buttons(r),spans=[...r.children].filter(e=>e.tagName==='SPAN');
        const rail=all('[role="group"]',one(all('[data-composer-card]',main()))).filter(e=>['Pending attachments','待发送附件'].includes(name(e)));
        const titleNode=spans[1],ordered=all('[data-row-key]'),index=ordered.indexOf(r),group=ordered.slice(0,index).reverse().find(e=>e.getAttribute('data-row-key').startsWith('workspace:'));
        return {blank:actions.length===0&&rail.length===0,title:text(titleNode),workspaceId:group?.getAttribute('data-row-key').slice(10)||null};
      }
      else if(kind==='modelValue'){const t=modelTrigger(),m=t.querySelector('[data-model-id][data-provider-id]'),effort=[...t.children].filter(e=>e.tagName==='SPAN').at(-1);return {provider:m?.getAttribute('data-provider-id')||null,model:m?.getAttribute('data-model-id')||null,effort:text(effort),open:t.getAttribute('aria-expanded')==='true'}}
      else if(kind==='modelTrigger')e=modelTrigger();
      else if(kind==='modelPane')e=one(all('[role="menuitem"]',ownedMenu()).filter(e=>text(e).startsWith(zh?'模型':'Model')));
      else if(kind==='effortPane')e=one(all('[role="menuitem"]',ownedMenu()).filter(e=>text(e).startsWith(zh?'推理等级':'Effort')));
      else if(kind==='modelOption')e=one(all('[role="menuitemradio"]',ownedMenu()).filter(e=>[...e.querySelectorAll('[data-model-id]')].some(m=>m.getAttribute('data-model-id')===s.model&&m.getAttribute('data-provider-id')===s.provider)));
      else if(kind==='modelProviders')return {providers:[...new Set(all('[role="menuitemradio"]',ownedMenu()).flatMap(e=>[...e.querySelectorAll('[data-model-id]')].filter(m=>m.getAttribute('data-model-id')===s.model).map(m=>m.getAttribute('data-provider-id'))).filter(Boolean))]};
      else if(kind==='effortOption')e=one(all('[role="menuitemradio"]',ownedMenu()).filter(e=>text(e)===s.label));
      else if(kind==='effortChoices')return {choices:all('[role="menuitemradio"]',ownedMenu()).map(text)};
      else if(kind==='accessValue'){const t=accessTrigger();return {label:name(t).replace(/^(Access mode, current: |访问模式，当前：)/,'')}}
      else if(kind==='accessTrigger')e=accessTrigger();
      else if(kind==='accessOption'){const menus=all('[role="menu"]');const menu=one(menus);e=one(all('[role="menuitem"],[role="menuitemradio"]',menu).filter(e=>s.names.includes(text(e).replace(/\s+EXP$/,''))))}
      else if(kind==='riskCheckbox'||kind==='riskConfirm'){
        const d=one(all('[role="dialog"]')),auto=s.access==='auto-review',title=auto?(zh?'确认启用自动审查（实验）？':'Enable Auto review (experimental)?'):(zh?'确认启用完全权限？':'Enable Full access?');
        if(!text(d).includes(title))fail('wrong_dialog','The expected access risk dialog is not visible.');
        e=kind==='riskCheckbox'?one(all('input[type="checkbox"]',d)):one(buttons(d).filter(e=>name(e)===(auto?(zh?'启用自动审查':'Enable Auto review'):(zh?'启用完全权限':'Enable Full access'))));
        if(kind==='riskCheckbox'&&e.checked)fail('stale_state','The risk acknowledgement was changed by another actor.');
      }
      else if(kind==='sessionMenu')e=one(buttons(row('session:'+s.id)).filter(e=>/^(Session actions for |会话“)/.test(name(e))));
      else if(kind==='renameMenu')e=one(all('[role="menuitem"]').filter(e=>/^(Rename|重命名)(\s|$)/.test(text(e))));
      else if(kind==='renameInput'||kind==='renameConfirm'){
        const d=one(all('[role="dialog"]'));if(!text(d).includes(zh?'重命名会话':'Rename session'))fail('wrong_dialog','Expected the session rename dialog.');
        e=kind==='renameInput'?one(all('input',d).filter(e=>name(e)===(zh?'会话名称':'Session name'))):one(buttons(d).filter(e=>name(e)===(zh?'重命名':'Rename')));
      }
      else fail('invalid_command','Unknown navigation selector.');
      if(e.matches(':disabled,[aria-disabled="true"]'))fail('disabled','The requested control is disabled.');
      e.scrollIntoView({block:'nearest',inline:'nearest'});
      const r=e.getBoundingClientRect(),x=Math.max(0,Math.min(innerWidth-1,r.x+r.width/2)),y=Math.max(0,Math.min(innerHeight-1,r.y+r.height/2)),hit=document.elementFromPoint(x,y);
      if(!hit||!e.contains(hit))fail('obstructed','The requested control is covered.');
      return {x,y};
    }catch(error){return {error:{code:error.code||'navigation_probe',message:error.message||'Navigation inspection failed.'}}}}
    """#
}
