import Darwin
import Foundation
import Testing
@testable import DSHControlCore

private func safetyDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-safety-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

@Test func safetyCanonicalDigest() throws {
    let first = try JSONValue(parseData: Data(#"{"z":1,"a":{"y":2,"x":3}}"#.utf8))
    let second = try JSONValue(parseData: Data(#"{"a":{"x":3,"y":2},"z":1}"#.utf8))
    #expect(try StateDigest.token(first) == StateDigest.token(second))
    #expect(try StateDigest.token(first).count == 64)
    #expect(try StateDigest.token(first) != StateDigest.token(.null))
}

@Test func safetyReceiptLifecycleAndIdempotency() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipts = try SendReceipts(directory: directory)
    #expect(try receipts.lookup(requestID: "abc-123_A") == nil)
    let prepared = try receipts.prepare(requestID: "abc-123_A", signature: "digest", targetID: "target")
    #expect(prepared["status"]?.string == "prepared")
    #expect(prepared["outcome"]?.string == "unknown")
    #expect(try receipts.prepare(requestID: "abc-123_A", signature: "different", targetID: "other") == prepared)
    var finished = try #require(prepared.object)
    finished["status"] = .string("sent")
    finished["outcome"] = .string("verified")
    try receipts.finish(requestID: "abc-123_A", receipt: .object(finished))
    #expect(try receipts.lookup(requestID: "abc-123_A") == .object(finished))
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("abc-123_A.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    finished["targetId"] = .string("other")
    #expect(throws: ControlError.self) { try receipts.finish(requestID: "abc-123_A", receipt: .object(finished)) }
}

@Test func safetyContradictoryReceiptCannotClaimSuccessOrNonDispatch() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipts = try SendReceipts(directory: directory)
    let prepared = try receipts.prepare(requestID: "inconsistent", signature: "digest", targetID: "target")
    let path = directory.appendingPathComponent("inconsistent.json")
    for (status, outcome) in [("uncertain", "verified"), ("prepared", "not_performed"), ("sent", "unknown"), ("not_sent", "verified"), ("finished", "sent"), ("uncertain", "unkown")] {
        var value = try #require(prepared.object)
        value["status"] = .string(status)
        value["outcome"] = .string(outcome)
        try JSONValue.object(value).encoded().write(to: path)
        do {
            _ = try receipts.lookup(requestID: "inconsistent")
            Issue.record("Trusted inconsistent receipt \(status)/\(outcome)")
        } catch let error as ControlError {
            #expect(error.code == "corrupt_receipt" && error.outcome == "unknown")
        }
    }
}

@Test func safetyInvalidIDsAndCorruptRecordsFailClosed() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipts = try SendReceipts(directory: directory)
    for id in ["", "../escape", "a/b", "a.b", "a b", "é", String(repeating: "a", count: 81)] {
        #expect(throws: ControlError.self) { try receipts.lookup(requestID: id) }
        #expect(throws: ControlError.self) { try receipts.prepare(requestID: id, signature: "digest", targetID: "target") }
    }
    let corrupt = directory.appendingPathComponent("broken.json")
    try Data("invalid".utf8).write(to: corrupt)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
    #expect(throws: ControlError.self) { try receipts.lookup(requestID: "broken") }
    #expect(throws: ControlError.self) { try receipts.prepare(requestID: "broken", signature: "digest", targetID: "target") }
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "invalid")
    let prepared = try receipts.prepare(requestID: "clean", signature: "digest", targetID: "target")
    var extra = try #require(prepared.object)
    extra["prompt"] = .string("must not persist")
    #expect(throws: ControlError.self) { try receipts.finish(requestID: "clean", receipt: .object(extra)) }
}

@Test func safetyLockCompetesAndReleases() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var first: MutationLock? = try MutationLock(directory: directory)
    #expect(first != nil)
    do {
        _ = try MutationLock(directory: directory)
        Issue.record("Competing lock succeeded")
    } catch let error as ControlError {
        #expect(error.code == "busy")
    }
    first = nil
    let next = try MutationLock(directory: directory)
    withExtendedLifetime(next) {}
}

@Test func safetySymlinksAndPublicStorageAreRejected() throws {
    let directory = try safetyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let receipts = try SendReceipts(directory: directory)
    let target = directory.appendingPathComponent("target")
    try Data("private".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: target)
    #expect(throws: ControlError.self) { try receipts.lookup(requestID: "link") }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("mutation.lock"), withDestinationURL: target)
    #expect(throws: ControlError.self) { try MutationLock(directory: directory) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    #expect(throws: ControlError.self) { try SendReceipts(directory: directory) }
}
