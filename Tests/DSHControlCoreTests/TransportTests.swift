import Foundation
import Testing
@testable import DSHControlCore

@Test func jsonRoundTripAndSortedEncoding() throws {
    let value = try JSONValue(parseData: Data(#"{"z":[true,null,3.5],"a":"hello"}"#.utf8))
    #expect(value["a"]?.string == "hello")
    #expect(value["z"]?.array == [.bool(true), .null, .number(3.5)])
    #expect(String(decoding: try value.encoded(), as: UTF8.self) == #"{"a":"hello","z":[true,null,3.5]}"#)
    #expect(throws: (any Error).self) { try JSONValue(parseData: Data("invalid".utf8)) }
}

@Test func responsesMatchOnlyTheirCommand() throws {
    func decode(_ text: String) throws -> JSONValue? { try decodeCDPResponse(Data(text.utf8), id: 2) }
    #expect(try decode(#"{"method":"Runtime.consoleAPICalled","params":{}}"#) == nil)
    #expect(try decode(#"{"id":1,"result":{}}"#) == nil)
    #expect(try decode(#"{"id":2,"result":{"ok":true}}"#)?["ok"]?.bool == true)
    for text in ["no", "[]", "{}", #"{"id":"2","result":{}}"#, #"{"id":2,"error":{"code":-1}}"#, #"{"id":2}"#] {
        #expect(throws: ControlError.self) { try decode(text) }
    }
}

@Test func evaluationsRequireSerializableValueWithoutExceptions() throws {
    #expect(try evaluationValue(.object(["result": .object(["value": .null])])) == .null)
    #expect(throws: ControlError.self) { try evaluationValue(.object(["exceptionDetails": .object([:])])) }
    #expect(throws: ControlError.self) { try evaluationValue(.object(["result": .object(["type": .string("undefined")])])) }
}

@Test func socketMustIdentifyLocalPage() throws {
    for address in ["ws://example.com:9222/devtools/page/a", "http://127.0.0.1:9222/devtools/page/a", "ws://127.0.0.1:9222/devtools/browser/a", "ws://127.0.0.1/devtools/page/a", "ws://user@127.0.0.1:9222/devtools/page/a"] {
        #expect(throws: ControlError.self) { try CDP(socketURL: #require(URL(string: address))) }
    }
}

private actor PendingIO {
    private var continuation: CheckedContinuation<Int, Never>?
    private var cancelled = false

    func receive() async -> Int {
        if cancelled { return 0 }
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancel() {
        cancelled = true
        continuation?.resume(returning: 0)
        continuation = nil
    }

    var wasCancelled: Bool { cancelled }
}

@Test(.timeLimit(.minutes(1))) func deadlineCancelsIOBeforeWaitingForGroup() async throws {
    let io = PendingIO()
    do {
        _ = try await withDeadline(seconds: 0.01, cancel: { Task { await io.cancel() } }) {
            await io.receive()
        }
        Issue.record("Expected deadline failure")
    } catch let error as ControlError {
        #expect(error.code == "timeout")
    }
    #expect(await io.wasCancelled)
}

@Test func successfulDeadlineDoesNotCancelConnection() async throws {
    let io = PendingIO()
    let value = try await withDeadline(seconds: 1, cancel: { Task { await io.cancel() } }) { 42 }
    #expect(value == 42)
    #expect(await io.wasCancelled == false)
}
