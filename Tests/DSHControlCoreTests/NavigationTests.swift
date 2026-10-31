import Darwin
import Foundation
import Testing
@testable import DSHControlCore

@Test func childNavigationRequiresUniqueLocalCatalogLabel() throws {
    func child(_ id: String, _ label: JSONValue, _ mode: String = "continuable") -> JSONValue {
        .object(["id": .string(id), "label": label, "mode": .string(mode)])
    }
    #expect(try UIController.uniqueSubagentLabel(sessionID: "c", catalog: [child("c", .string("Worker"))]) == "Worker")
    #expect(try UIController.uniqueSubagentLabel(sessionID: "c", catalog: [child("c", .null)]) == "c")
    #expect(throws: ControlError.self) { try UIController.uniqueSubagentLabel(sessionID: "c", catalog: [child("c", .string("Worker")), child("d", .string("Worker"))]) }
    #expect(throws: ControlError.self) { try UIController.uniqueSubagentLabel(sessionID: "c", catalog: [child("c", .string("Worker"), "external")]) }
}

private func claimsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-claims-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

@Test func creationReceiptsReserveExactlyOneSessionAndPreserveReplay() throws {
    let directory = try claimsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let claims = try SessionClaims(directory: directory)
    try claims.prepare(requestID: "request_1", signature: "signature")
    #expect(try claims.request("request_1")?["outcome"]?.string == "unknown")
    let result = try claims.reserve(sessionID: "s1", requestID: "request_1", signature: "signature", title: "Deferred title", reused: true)
    #expect(result["status"]?.string == "reused")
    #expect(try claims.request("request_1")?["result"] == result)
    #expect(throws: ControlError.self) { try claims.reserve(sessionID: "s1", requestID: "request_1", signature: "signature", title: nil, reused: false) }
    #expect(throws: ControlError.self) { try claims.release(sessionID: "s1", requestID: "someone_else") }
    try claims.titleFinished(sessionID: "s1", status: "skipped_user_title")
    #expect(try claims.claim("s1")?["titleStatus"]?.string == "skipped_user_title")
    _ = try claims.release(sessionID: "s1", requestID: "request_1")
    #expect(try claims.claim("s1") == nil)
    #expect(try claims.request("request_1")?["result"] == result)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("session-claims.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func claimStorageRejectsSymlinksCorruptionAndUnsafeIdentifiers() throws {
    let directory = try claimsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let claims = try SessionClaims(directory: directory)
    #expect(throws: ControlError.self) { try claims.prepare(requestID: "../escape", signature: "signature") }
    let target = directory.appendingPathComponent("foreign.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("session-claims.json"), withDestinationURL: target)
    #expect(throws: ControlError.self) { try claims.claim("s1") }
    try FileManager.default.removeItem(at: directory.appendingPathComponent("session-claims.json"))
    try Data(#"{"claims":{},"requests":{"x":{"status":"completed","outcome":"verified","signature":"x"}}}"#.utf8).write(to: directory.appendingPathComponent("session-claims.json"))
    chmod(directory.appendingPathComponent("session-claims.json").path, 0o600)
    #expect(throws: ControlError.self) { try claims.request("x") }
}

@Test func pickerRequiresExactSingleVisibleProcessAndCanonicalExistingDirectory() throws {
    #expect(try NativePicker.uniqueOwner(pids: [12], visiblePIDs: [12]) == 12)
    #expect(throws: ControlError.self) { try NativePicker.uniqueOwner(pids: [12, 13], visiblePIDs: [12]) }
    #expect(throws: ControlError.self) { try NativePicker.uniqueOwner(pids: [12], visiblePIDs: [13]) }
    let directory = try claimsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(try NativePicker.canonicalDirectory(link.path).path == directory.resolvingSymlinksInPath().path)
    #expect(throws: ControlError.self) { try NativePicker.canonicalDirectory("relative") }
    #expect(throws: ControlError.self) { try NativePicker.canonicalDirectory(directory.path + "\n") }
    #expect(throws: ControlError.self) { try NativePicker.canonicalDirectory(directory.appendingPathComponent("missing").path) }
}

@Test func reasoningEffortUsesAdvertisedShippedLabels() throws {
    #expect(try UIController.effortLabel("high") == "High")
    #expect(try UIController.effortLabel("xhigh") == "Xhigh")
    #expect(throws: ControlError.self) { try UIController.effortLabel("invented") }
}

@Test func pendingTitleReplacesOnlyEmptyOrLatestAutomaticTitle() {
    func event(_ kind: String) -> JSONValue {
        .object(["type": .string("session/title"), "data": .object(["title": .string("Automatic"), "source": .object(["kind": .string(kind)])])])
    }
    #expect(UIController.canApplyPendingTitle(title: .null, events: []))
    #expect(UIController.canApplyPendingTitle(title: .string(""), events: []))
    #expect(UIController.canApplyPendingTitle(title: .string("Automatic"), events: [event("fallback")]))
    #expect(UIController.canApplyPendingTitle(title: .string("Automatic"), events: [event("provider")]))
    for kind in ["manual", "user", "unknown"] {
        #expect(!UIController.canApplyPendingTitle(title: .string("Automatic"), events: [event("fallback"), event(kind)]))
    }
    #expect(!UIController.canApplyPendingTitle(title: .string("Changed"), events: [event("provider")]))
    #expect(!UIController.canApplyPendingTitle(title: .string("Automatic"), events: []))
}

@Test func hiddenSessionSearchRequiresOneExactIdentityAndUniqueNonemptyTitle() throws {
    func session(_ id: String, _ title: JSONValue) -> JSONValue {
        .object(["session": .object(["id": .string(id), "title": title])])
    }
    let target = session("exact", .string("Hidden session"))
    #expect(try UIController.uniqueSearchTitle(sessionID: "exact", sessions: [target, session("other", .string("Other"))]) == "Hidden session")
    #expect(throws: ControlError.self) { try UIController.uniqueSearchTitle(sessionID: "exact", sessions: [target, session("other", .string("Hidden session"))]) }
    #expect(throws: ControlError.self) { try UIController.uniqueSearchTitle(sessionID: "missing", sessions: [target]) }
    #expect(throws: ControlError.self) { try UIController.uniqueSearchTitle(sessionID: "exact", sessions: [session("exact", .null)]) }
    #expect(throws: ControlError.self) { try UIController.uniqueSearchTitle(sessionID: "exact", sessions: [session("exact", .string("  "))]) }
}

@Test func sessionSearchQueryRespectsReleasedWireLimitWithoutSplittingSurrogatePairs() {
    let title = String(repeating: "a", count: 499) + "😀" + "tail"
    #expect(UIController.sessionSearchQuery(title) == String(repeating: "a", count: 499))
    #expect(UIController.sessionSearchQuery("ab\0cd") == "abcd")
    #expect(UIController.sessionSearchQuery(String(repeating: "😀", count: 300)).utf16.count == 500)
}
