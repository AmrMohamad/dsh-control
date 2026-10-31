import AppKit
import Darwin
import Foundation

/// Validates the installed product before inspecting or changing its lifecycle.
public struct HarnessApplication: Sendable {
    public let bundleURL: URL
    public let version: String
    private let executableURL: URL
    private let identifier = "com.deepseek.dsh"

    public init(bundleURL: URL = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")) throws {
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.deepseek.dsh",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
              !name.contains("/"), name != ".", name != "..",
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw ControlError(code: "invalid_application", message: "Bundle is not a valid DeepSeek Harness installation")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard executable.path.hasPrefix(bundle.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ControlError(code: "invalid_application", message: "Application executable is missing or outside the bundle")
        }
        self.bundleURL = bundle
        self.executableURL = executable
        self.version = version
    }

    public func runningPIDs() -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).compactMap { app in
            guard !app.isTerminated,
                  app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == bundleURL,
                  app.executableURL?.resolvingSymlinksInPath().standardizedFileURL == executableURL else { return nil }
            return app.processIdentifier
        }
    }

    /// Refuses foreign owners and listeners reachable outside loopback.
    public func verifyListener(port: Int) throws {
        let owners = Set(runningPIDs())
        let listeners = try listeners(port: port)
        guard !listeners.isEmpty, listeners.allSatisfy({ owners.contains($0.pid) && $0.loopback }) else {
            throw ControlError(code: "untrusted_listener", message: "CDP port must be loopback-only and owned by this exact application")
        }
    }

    public func start(port: Int, timeout: TimeInterval) async throws -> JSONValue {
        try validateApplicationTimeout(timeout)
        if !runningPIDs().isEmpty {
            if try listeners(port: port).isEmpty { return status("requires_restart") }
            try verifyListener(port: port)
            return status("already_running")
        }
        guard try listeners(port: port).isEmpty else {
            throw ControlError(code: "port_in_use", message: "Requested CDP port is already in use")
        }
        _ = try applicationCommand("/usr/bin/open", ["-a", bundleURL.path, "--args", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=\(port)"])
        let deadline = Date().addingTimeInterval(timeout)
        // The launch already happened: any failure from here on leaves the outcome unknown.
        do {
            repeat {
                if try !listeners(port: port).isEmpty {
                    try verifyListener(port: port)
                    return status("started")
                }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < deadline
        } catch let error as ControlError {
            throw ControlError(code: error.code, message: error.message, outcome: "unknown", details: error.details)
        } catch {
            throw ControlError(code: "start_interrupted", message: "Launch was requested but verification was interrupted", outcome: "unknown")
        }
        throw ControlError(code: "start_timeout", message: "Launch requested but the verified CDP listener did not become ready", outcome: "unknown")
    }

    /// Requests normal termination only; an unresponsive application is left running.
    public func quit(timeout: TimeInterval) async throws -> JSONValue {
        try validateApplicationTimeout(timeout)
        let pids = Set(runningPIDs())
        if pids.isEmpty { return status("not_running") }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) where pids.contains(app.processIdentifier) {
            _ = app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Set(runningPIDs()).isDisjoint(with: pids) { return status("quit") }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return .object(["status": .string("quit_pending"), "approval_required": .bool(true)])
    }

    private func status(_ value: String) -> JSONValue {
        .object(["status": .string(value), "version": .string(version)])
    }

    private func listeners(port: Int) throws -> [ApplicationListener] {
        guard (1...65535).contains(port) else { throw ControlError(code: "invalid_port", message: "Port must be between 1 and 65535") }
        let output = try applicationCommand("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"], allowEmpty: true)
        return try parseApplicationListeners(output, port: port)
    }
}

struct ApplicationListener {
    let pid: Int32
    let loopback: Bool
}

/// lsof field output keeps process ownership separate from display names.
func parseApplicationListeners(_ output: String, port: Int) throws -> [ApplicationListener] {
    var pid: Int32?
    var listeners: [ApplicationListener] = []
    for line in output.split(separator: "\n") {
        if line.first == "p" {
            pid = Int32(line.dropFirst())
            guard pid != nil else { throw ControlError(code: "listener_inspection_failed", message: "Invalid listener process identifier") }
        } else if line.first == "n" {
            guard let pid else { throw ControlError(code: "listener_inspection_failed", message: "Listener has no process owner") }
            let address = String(line.dropFirst())
            listeners.append(ApplicationListener(pid: pid, loopback: address == "127.0.0.1:\(port)" || address == "[::1]:\(port)"))
        }
    }
    guard output.isEmpty || !listeners.isEmpty else {
        throw ControlError(code: "listener_inspection_failed", message: "Listener inspection returned no socket addresses")
    }
    return listeners
}

private func validateApplicationTimeout(_ timeout: TimeInterval) throws {
    guard timeout.isFinite, timeout > 0, timeout <= 3600 else {
        throw ControlError(code: "invalid_timeout", message: "Timeout must be greater than zero and at most 3600 seconds")
    }
}

/// Only fixed system utilities are used, with bounded waiting and no shell.
private func applicationCommand(_ path: String, _ arguments: [String], allowEmpty: Bool = false) throws -> String {
    let process = Process()
    let pipe = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = errors
    try process.run()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { usleep(10_000) }
    if process.isRunning {
        process.terminate()
        usleep(50_000)
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        throw ControlError(code: "system_command_timeout", message: "System utility did not complete in time")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 || (allowEmpty && process.terminationStatus == 1 && data.isEmpty),
          diagnostics.isEmpty,
          let output = String(data: data, encoding: .utf8) else {
        throw ControlError(code: "system_command_failed", message: "System utility could not inspect or control the application")
    }
    return output
}

/// Selects one product page and validates its advertised socket before attachment.
public func selectProductTarget(_ targets: JSONValue, port: Int) throws -> (id: String, socketURL: URL) {
    guard (1...65535).contains(port), let list = targets.array else {
        throw ControlError(code: "invalid_targets", message: "Expected a CDP target list and valid port")
    }
    let pages = list.filter { $0["type"]?.string == "page" && $0["url"]?.string == "dsh-app://app/" }
    guard pages.count == 1, let page = pages.first,
          let id = page["id"]?.string, !id.isEmpty,
          id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
          let raw = page["webSocketDebuggerUrl"]?.string,
          let socket = URL(string: raw), let parts = URLComponents(url: socket, resolvingAgainstBaseURL: false),
          parts.scheme == "ws", parts.host == "127.0.0.1", parts.port == port,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.percentEncodedPath == "/devtools/page/\(id)" else {
        throw ControlError(code: "invalid_product_target", message: "Expected exactly one product page with a matching loopback CDP socket")
    }
    return (id, socket)
}
