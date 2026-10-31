import Foundation

/// A sequential connection to one local Chromium page. Closing never closes the browser.
public struct CDP {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let timeout: TimeInterval
    private var nextID = 0

    public init(socketURL: URL, timeout: TimeInterval = 10) throws {
        guard socketURL.scheme == "ws", socketURL.host == "127.0.0.1",
              let port = socketURL.port, (1...65535).contains(port),
              socketURL.user == nil, socketURL.password == nil,
              socketURL.query == nil, socketURL.fragment == nil,
              socketURL.path.hasPrefix("/devtools/page/"),
              socketURL.path.count > "/devtools/page/".count,
              timeout.isFinite, timeout > 0, timeout <= 3600 else {
            throw ControlError(code: "invalid_endpoint", message: "Expected a loopback Chromium page WebSocket and a positive deadline of at most one hour.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.timeout = timeout
        socket.resume()
    }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public mutating func call(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let request = try JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": params]).encoded()
        let socket = socket
        let session = session
        let cancel: @Sendable () -> Void = {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            return try await withDeadline(seconds: timeout, cancel: cancel) {
                try await socket.send(.string(String(decoding: request, as: UTF8.self)))
                while true {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw ControlError(code: "protocol", message: "Unsupported Chromium message.")
                    }
                    if let result = try decodeCDPResponse(data, id: id) { return result }
                }
            }
        } catch let error as ControlError {
            throw error
        } catch {
            cancel()
            throw ControlError(code: "transport", message: "Chromium transport failed.")
        }
    }

    public mutating func evaluate(expression: String) async throws -> JSONValue {
        let response = try await call(method: "Runtime.evaluate", params: .object([
            "expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(true),
        ]))
        return try evaluationValue(response)
    }
}

/// Notifications and replies for other command IDs do not complete the current command.
func decodeCDPResponse(_ data: Data, id: Int) throws -> JSONValue? {
    let response: JSONValue
    do { response = try JSONValue(parseData: data) }
    catch { throw ControlError(code: "protocol", message: "Chromium returned invalid JSON.") }
    guard response.object != nil else { throw ControlError(code: "protocol", message: "Chromium returned a non-object message.") }
    guard let responseID = response["id"] else {
        guard response["method"]?.string != nil else { throw ControlError(code: "protocol", message: "Chromium message has no command ID or notification method.") }
        return nil
    }
    guard case .number(let number) = responseID, number.isFinite, number.rounded() == number else {
        throw ControlError(code: "protocol", message: "Chromium returned an invalid command ID.")
    }
    guard number == Double(id) else { return nil }
    if response["error"] != nil { throw ControlError(code: "protocol", message: "Chromium rejected the command.") }
    guard let result = response["result"], result.object != nil else {
        throw ControlError(code: "protocol", message: "Chromium response has no result object.")
    }
    return result
}

func evaluationValue(_ response: JSONValue) throws -> JSONValue {
    guard response["exceptionDetails"] == nil else {
        throw ControlError(code: "evaluation", message: "Page evaluation raised an exception.")
    }
    guard let value = response["result"]?["value"] else {
        throw ControlError(code: "evaluation", message: "Page evaluation did not return a JSON value.")
    }
    return value
}

/// Cancel the underlying I/O before the task group waits for its losing child.
func withDeadline<T: Sendable>(seconds: TimeInterval, cancel: @escaping @Sendable () -> Void,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ControlError(code: "timeout", message: "Chromium command deadline expired.")
            }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return result
            } catch {
                cancel()
                group.cancelAll()
                throw error
            }
        }
    } onCancel: { cancel() }
}
