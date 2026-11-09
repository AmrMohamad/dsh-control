import Foundation
import Darwin
import DSHControlCore

@main
struct CLI {
    static let help = """
    dsh-control <command> [options]
      --port N          Local Chromium debugger port (default 9222)
      --timeout SECONDS Verification/wait deadline (default 10; max 3600)
      --app PATH        Installed DeepSeek Harness.app
      --state-dir PATH  Private lock/receipt directory
      --dsh-home PATH   Read-only Harness observation root (default ~/.dsh)

    Observe: inspect [--compact] [--fields a,b] [--controls composer|sidebar|messages]
             read [--session ID] [--last-assistant] [--turn N|--since ANCHOR] [--full] [--out FILE]
             status --session ID; changes --session ID [--turn N] [--diff]
    Navigate: new-session --workspace NAME|--workspace-id ID|--cwd PATH [--title TITLE]
              select-session --id ID|--title TITLE; release-session --id ID
              add-workspace PATH; set-model --model ID [--provider ID] [--effort VALUE]
              set-access-mode --mode MODE [--confirm-risk]
    Mutations require --expect TOKEN. new-session/send/send-and-wait require --request-id ID.
    send [--file FILE] [--long-brief attach|reference] [--allow-slash] [--allow-references]
    send-and-wait uses the same send flags (plus --until idle), then waits without holding the mutation lock.
    wait --session ID [--request-id ID|--input-id ID|--turn N|--until idle] [--retry-transient N]
    Default waits settle the exact bound turn (completionScope "turn"). --until idle instead
    observes live parent, queued-input, interaction and known-child quiescence; it needs the
    trusted GUI debugger and reports completionScope "idle" with evidence and coverage.
    receipt --request-id ID [--reconcile]; cancel --expect TOKEN [--include-subagents]

    inspect/read/start/quit need no stdin. Other commands read one JSON object:
      draft    {"expect":"inspection token","text":"unsent text"}
      click    {"expect":"inspection token","ref":"control ref from inspect"}
      send     {"expect":"inspection token","requestId":"unique-send-id"}
      cancel   {"expect":"inspection token"}
      scroll   {"expect":"inspection token","direction":"up|down"}
      wait     {"anchor":"user node key","context":{...guard from send state...}}
      receipt  {"requestId":"unique-send-id"}

    Output is one versioned JSON object. Errors have code, message and outcome.
    start never restarts an already-running app. quit never force-kills it.
    send IDs are permanent deduplication keys: inspect uncertain outcomes; never retry them under a new ID automatically.
    """

    static func main() async {
        signal(SIGPIPE, SIG_IGN)  // a closed stdout must surface as a write error, not kill the process
        let payload: JSONValue
        var status: Int32 = 0
        do {
            payload = .object(["version": .number(1), "ok": .bool(true), "result": try await run(Array(CommandLine.arguments.dropFirst()))])
        } catch {
            let error = error as? ControlError ?? ControlError(code: "failure", message: String(describing: error))
            payload = .object(["version": .number(1), "ok": .bool(false), "error": .object([
                "code": .string(error.code), "message": .string(error.message),
                "outcome": .string(error.outcome), "details": error.details ?? .null,
            ])])
            status = error.outcome == "unknown" ? 3 : 2
        }
        do { try output(payload) } catch {
            // The command already ran; losing its report must never read as "not performed".
            fputs("{\"version\":1,\"ok\":false,\"error\":{\"code\":\"output_failed\",\"outcome\":\"unknown\",\"message\":\"The result could not be written to stdout; inspect state and read receipts before acting again.\"}}\n", stderr)
            status = 3
        }
        exit(status)
    }

    static func run(_ arguments: [String]) async throws -> JSONValue {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            return .object(["help": .string(help)])
        }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = isatty(STDIN_FILENO) == 0 && poll(&descriptor, 1, 0) > 0
        let input = ready ? FileHandle.standardInput.readData(ofLength: 1_048_577) : nil
        let options = try CommandOptions(arguments: arguments, stdin: input)
        let command = options.command
        let request = options.request
        let store = SessionStore(home: options.home)
        if command == "receipt" {
            let receipts = try SendReceipts(directory: options.state.appendingPathComponent("receipts"))
            let id = try request.requireString("requestId")
            if request["reconcile"]?.bool == true { return try receipts.reconcile(requestID: id, store: store, stateDirectory: options.state) }
            return .object(["receipt": try receipts.lookup(requestID: id) ?? .null])
        }
        if ["read", "status", "changes"].contains(command), let id = request["session"]?.string {
            return try observed(command: command, request: request, sessionID: id, store: store)
        }
        if command == "wait", let id = request["session"]?.string, request["until"]?.string != CommandOptions.idleUntil {
            return try await wait(request: request, sessionID: id, options: options, store: store)
        }
        let idleWait = command == "wait" && request["until"]?.string == CommandOptions.idleUntil
        let idleDeadline = idleWait ? ContinuousClock.now.advanced(by: .seconds(options.timeout)) : nil
        let application: HarnessApplication
        do { application = try HarnessApplication(bundleURL: options.app) }
        catch let error as ControlError where idleWait { throw Self.idleUnavailable(error) }
        if command == "start" || command == "quit" {
            let lock = try MutationLock(directory: options.state)
            defer { withExtendedLifetime(lock) {} }
            let result = try await command == "start" ? application.start(port: options.port, timeout: options.timeout) : application.quit(timeout: options.timeout)
            if result["status"]?.string == "requires_restart" {
                throw ControlError(code: "requires_restart", message: "The app is running without the debugger. Normal restart requires authorization.", details: result)
            }
            return result
        }
        var controller: UIController
        do { controller = try await UIController.connect(application: application, port: options.port, timeout: Self.remaining(idleDeadline) ?? options.timeout) }
        catch let error as ControlError where idleWait { throw Self.idleUnavailable(error) }
        defer { controller.close() }
        if ["inspect", "read", "status", "changes"].contains(command) {
            var state = try await controller.inspect(sessionID: request["session"]?.string)
            let id = state["session"]?["id"]?.string
            if command != "inspect" {
                guard let id else { throw ControlError(code: "session_unavailable", message: "No exact session is displayed; select one or provide --session.") }
                return try observed(command: command, request: request, sessionID: id, store: store)
            }
            if let id {
                do {
                    let durable = try store.snapshot(sessionID: id)
                    var values = state.object!
                    for name in ["turnState", "queue", "usage", "model", "access", "observation", "cursor"] { values[name] = durable[name] }
                    var session = values["session"]?.object ?? [:]
                    for (key, value) in durable["session"]?.object ?? [:] { session[key] = value }
                    values["session"] = .object(session)
                    if let cwd = session["cwd"]?.string { values["workspace"] = try store.workspaces().first { $0["path"]?.string == cwd } ?? .null }
                    let visible = state["subagents"]?.array ?? []
                    let known = durable["subagents"]?.array ?? []
                    values["subagents"] = .array(known.map { child in
                        guard let id = child["id"]?.string, let live = visible.first(where: { $0["id"]?.string == id }) else { return child }
                        return .object((child.object ?? [:]).merging(live.object ?? [:]) { _, observed in observed })
                    } + visible.filter { child in !known.contains { $0["id"] == child["id"] } })
                    state = .object(values)
                } catch let error as ControlError {
                    var values = state.object!
                    values["observation"] = .object(["source": .string("gui"), "logUnavailable": .string(error.code)])
                    state = .object(values)
                }
            }
            return try ObservationOutput.inspect(state, compact: request["compact"]?.bool == true, fields: request["fields"]?.string, controls: request["controls"]?.string)
        }
        if command == "wait" {
            let untilIdle = request["until"]?.string == CommandOptions.idleUntil
            let runtime: SessionWaiter.IdleRuntimeObservation? = untilIdle
                ? { sessionID, remaining in try await controller.inspect(sessionID: sessionID, timeout: remaining) } : nil
            if let id = request["session"]?.string {
                return try await wait(request: request, sessionID: id, options: options, store: store,
                                      runtime: runtime, deadline: idleDeadline)
            }
            guard let context = request["context"], context.object != nil else { throw ControlError(code: "invalid_request", message: "Wait needs --session ID or the legacy anchor/context request.") }
            if let id = context["conversationSession"]?.string {
                var values = request.object!; values["session"] = .string(id)
                let anchor = request["anchor"]?.string
                let state = try await controller.inspect(sessionID: id)
                guard let anchor, context["lastUser"]?.string == anchor,
                      state["guard"]?["conversationSession"] == context["conversationSession"],
                      state["guard"]?["epoch"] == context["epoch"],
                      let row = state["messages"]?.array?.first(where: { $0["key"]?.string == anchor && $0["kind"]?.string == "user" }),
                      let text = row["turn"]?.string, let turn = Double(text), turn >= 0, turn.rounded() == turn else {
                    throw ControlError(code: "invalid_anchor", message: "The legacy user anchor cannot be resolved in its bound session. Use the send receipt; do not infer the latest turn.", outcome: "unknown")
                }
                values["turn"] = .number(turn)
                return try await wait(request: .object(values), sessionID: id, options: options, store: store,
                                      runtime: runtime, deadline: idleDeadline)
            }
            return try await controller.wait(anchor: request.requireString("anchor"), context: context, timeout: options.timeout)
        }
        let receipts = try SendReceipts(directory: options.state.appendingPathComponent("receipts"))
        let claims = try SessionClaims(directory: options.state.appendingPathComponent("claims"))
        let result: JSONValue
        do {
            let lock = try MutationLock(directory: options.state)
            defer { withExtendedLifetime(lock) {} }
            if ["new-session", "select-session", "release-session", "add-workspace", "set-model", "set-access-mode"].contains(command) {
                var values = request.object!
                if let id = values["id"] { values["sessionId"] = id }
                if let access = values["mode"] { values["access"] = access }
                let alias = command == "select-session" ? "open-session" : command == "set-access-mode" ? "set-access" : command
                return try await controller.navigation(command: alias, request: .object(values), store: store, claims: claims, application: application)
            }
            if command == "send" || command == "send-and-wait" {
                var sent = try await controller.submit(request: request, receipts: receipts, store: store)
                if let id = sent["binding"]?["sessionId"]?.string, sent["receipt"]?["submission"]?["operation"]?.string != "command" {
                    var values = sent.object!
                    let title = await controller.applyPendingTitle(sessionID: id, claims: claims, store: store)
                    values["title"] = title
                    do {
                        if title["status"]?.string != "pending", let claim = try claims.claim(id), let owner = claim["requestId"]?.string {
                            _ = try claims.release(sessionID: id, requestID: owner)
                        }
                    } catch {
                        values["claimWarning"] = .string("Submission is verified; reservation release was not confirmed.")
                    }
                    sent = .object(values)
                }
                result = sent
            } else if command == "cancel", request["includeSubagents"]?.bool == true {
                result = try await controller.cancelFamily(request: request, receipts: receipts, store: store, claims: claims, application: application)
            } else { result = try await controller.mutate(command: command, request: request, receipts: receipts, store: store) }
        }
        if command != "send-and-wait" { return result }
        guard let receipt = result["receipt"], let id = result["binding"]?["sessionId"]?.string ?? receipt["submission"]?["sessionId"]?.string else {
            throw ControlError(code: "wait_unavailable", message: "Send was verified but no session binding is available. Read its receipt; do not resend.", outcome: "unknown", details: result)
        }
        var values = request.object!
        values["requestId"] = receipt["requestId"]
        let runtime: SessionWaiter.IdleRuntimeObservation? = request["until"]?.string == CommandOptions.idleUntil
            ? { sessionID, remaining in try await controller.inspect(sessionID: sessionID, timeout: remaining) } : nil
        do {
            let waited = try await wait(request: .object(values), sessionID: id, options: options, store: store, runtime: runtime)
            return .object(["send": result, "wait": waited])
        } catch {
            throw ControlError.sendWaitFailure(error, send: result)
        }
    }

    static func observed(command: String, request: JSONValue, sessionID: String, store: SessionStore) throws -> JSONValue {
        let value: JSONValue
        if command == "status" { value = ObservationOutput.status(try store.snapshot(sessionID: sessionID)) }
        else if command == "changes" { value = try store.changes(sessionID: sessionID, turn: request["turn"], includeDiff: request["diff"]?.bool == true) }
        else { value = try store.read(sessionID: sessionID, lastAssistant: request["lastAssistant"]?.bool == true, turn: request["turn"], since: request["since"]?.string, full: request["full"]?.bool == true || request["out"] != nil) }
        if let out = request["out"]?.string { return try ObservationOutput.save(value, to: URL(fileURLWithPath: out)) }
        return value
    }

    static func wait(request: JSONValue, sessionID: String, options: CommandOptions, store: SessionStore,
                     runtime: SessionWaiter.IdleRuntimeObservation? = nil,
                     deadline: ContinuousClock.Instant? = nil) async throws -> JSONValue {
        let untilIdle = request["until"]?.string == CommandOptions.idleUntil
        let waitDeadline = deadline ?? (untilIdle ? ContinuousClock.now.advanced(by: .seconds(options.timeout)) : nil)
        var input = request["inputId"]?.string
        var turn = request["turn"]
        if let id = request["requestId"]?.string {
            let receipts = try SendReceipts(directory: options.state.appendingPathComponent("receipts"))
            guard let receipt = try receipts.lookup(requestID: id), receipt["status"]?.string == "sent", receipt["submission"]?["sessionId"]?.string == sessionID else {
                throw ControlError(code: "invalid_anchor", message: "Wait request does not have a verified receipt for this session.", outcome: "unknown")
            }
            input = receipt["verification"]?["inputId"]?.string
            turn = receipt["verification"]?["turn"]
            if receipt["submission"]?["operation"]?.string == "command", let commandID = receipt["verification"]?["commandId"]?.string {
                if untilIdle {
                    throw ControlError(code: "invalid_request", message: "Idle waiting needs a model-turn receipt; this receipt is a command completion with no continuation turn. No input was retried.",
                                       outcome: "unknown", details: receipt)
                }
                return try await SessionWaiter.wait(store: store, sessionID: sessionID, commandID: commandID, timeout: options.timeout, retryTransient: Int(request["retryTransient"]?.number ?? 3))
            }
            if input == nil && turn == nil, let submission = receipt["submission"], let evidence = try store.admission(sessionID: sessionID, after: submission["cursor"] ?? .null, digest: submission.requireString("digest"), operation: submission["operation"]?.string ?? "send") {
                input = evidence["inputId"]?.string; turn = evidence["turn"]
            }
            if turn == .null { turn = nil }
            guard input != nil || turn != nil else { throw ControlError(code: "invalid_anchor", message: "Submission is verified but its durable turn is not yet identified. Read/reconcile the receipt; do not resend.", outcome: "unknown", details: receipt) }
        }
        if untilIdle {
            return try await SessionWaiter.waitForIdle(store: store, sessionID: sessionID, inputID: input, turn: turn,
                                                       timeout: Self.remaining(waitDeadline) ?? options.timeout,
                                                       retryTransient: Int(request["retryTransient"]?.number ?? 3), runtime: runtime)
        }
        return try await SessionWaiter.wait(store: store, sessionID: sessionID, inputID: input, turn: turn, timeout: options.timeout, retryTransient: Int(request["retryTransient"]?.number ?? 3))
    }

    /// Remaining time before one absolute deadline; never a fresh per-observation budget.
    static func remaining(_ deadline: ContinuousClock.Instant?) -> TimeInterval? {
        guard let deadline else { return nil }
        let duration = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return max(0.001, seconds)
    }

    static func idleUnavailable(_ error: ControlError) -> ControlError {
        ControlError(code: "idle_unavailable",
                     message: "Idle waiting requires a trusted, running GUI observation connection. \(error.message)",
                     outcome: "unknown", details: .object(["cause": .string(error.code)]))
    }

    static func output(_ value: JSONValue) throws {
        var data = try value.encoded()
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
