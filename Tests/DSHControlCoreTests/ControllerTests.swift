import Foundation
import Testing
@testable import DSHControlCore

struct ControllerTests {
    private func identity(url: String = "u", epoch: Double = 1, rows: [String] = ["r"]) -> JSONValue {
        .object(["url": .string(url), "epoch": .number(epoch), "selectedRows": .array(rows.map(JSONValue.string))])
    }

    private func state(draft: String, messages: [(key: String, kind: String, text: String)], guardValue: JSONValue? = nil) -> JSONValue {
        .object(["guard": guardValue ?? identity(), "draft": .string(draft), "messages": .array(messages.map {
            .object(["key": .string($0.key), "kind": .string($0.kind), "text": .string($0.text + " 12:01 Copy"), "body": .string($0.text)])
        })])
    }

    @Test func sendConfirmedNeedsNewMatchingUserEchoAndEmptyComposer() {
        let old = [(key: "u1", kind: "user", text: "earlier")]
        let before = state(draft: "hello ", messages: old)
        #expect(UIController.sendConfirmed(before: before, after: state(draft: "", messages: old + [(key: "u2", kind: "user", text: "hello")])))
        // Not confirmed: composer still full, old echo reused, wrong kind, different text, or no draft to send.
        #expect(!UIController.sendConfirmed(before: before, after: state(draft: "hello", messages: old + [(key: "u2", kind: "user", text: "hello")])))
        #expect(!UIController.sendConfirmed(before: before, after: state(draft: "", messages: [(key: "u1", kind: "user", text: "hello")])))
        #expect(!UIController.sendConfirmed(before: before, after: state(draft: "", messages: old + [(key: "a1", kind: "assistant", text: "hello")])))
        #expect(!UIController.sendConfirmed(before: before, after: state(draft: "", messages: old + [(key: "u2", kind: "user", text: "other")])))
        #expect(!UIController.sendConfirmed(before: state(draft: "", messages: old), after: state(draft: "", messages: old + [(key: "u2", kind: "user", text: "")])))
    }

    @Test func sendConfirmedRejectsSubstringEchoAndTruncatedObservation() {
        let before = state(draft: "hello", messages: [])
        #expect(!UIController.sendConfirmed(before: before, after: state(draft: "", messages: [(key: "u", kind: "user", text: "hello world")])))
        let long = String(repeating: "a", count: 12_001)
        let truncated = JSONValue.object(["draft": .string(""), "messages": .array([
            .object(["key": .string("u"), "kind": .string("user"), "body": .string(String(long.prefix(12_000))), "bodyTruncated": .bool(true)])])])
        #expect(!UIController.sendConfirmed(before: state(draft: long, messages: []), after: truncated))
        #expect(UIController.sendConfirmed(before: state(draft: "a\n\nb", messages: []), after: state(draft: "", messages: [(key: "u", kind: "user", text: "a b")])))
    }

    @Test func sendConfirmedFailsSafeWithoutBodySlots() {
        let before = state(draft: "hello", messages: [])
        // Row text alone (with timestamp and Copy) is never compared; a missing body is unconfirmed.
        let rowOnly = JSONValue.object(["draft": .string(""), "messages": .array([
            .object(["key": .string("u"), "kind": .string("user"), "text": .string("hello"), "body": .null])])])
        #expect(!UIController.sendConfirmed(before: before, after: rowOnly))
        let multi = state(draft: "", messages: [(key: "u", kind: "user", text: "a\nb")])
        #expect(UIController.sendConfirmed(before: state(draft: "a\nb", messages: []), after: multi))
    }

    @Test func reloadEpochEndsWaitConversation() {
        let a = JSONValue.object(["url": .string("u"), "epoch": .number(1), "selectedRows": .array([]), "workspace": .array([]), "lastUser": .string("k")])
        #expect(UIController.sameIdentity(a, a))
        #expect(!UIController.sameIdentity(a, .object(["url": .string("u"), "epoch": .number(2), "selectedRows": .array([]), "workspace": .array([]), "lastUser": .string("k")])))
        #expect(UIController.sameIdentity(a, .object(["url": .string("u"), "epoch": .number(1), "selectedRows": .array([]), "workspace": .array([]), "lastUser": .null])))
    }

    @Test func adapterRefusalMeansNothingWasDispatched() throws {
        let refusal = JSONValue.object(["error": .object(["code": .string("unsupported_ui"), "message": .string("No scroll area")])])
        do { _ = try UIController.pageResult(refusal); Issue.record("Accepted refused action") }
        catch let error as ControlError { #expect(error.code == "unsupported_ui" && error.outcome == "not_performed") }
        let success = JSONValue.object(["scrolled": .bool(true)])
        #expect(try UIController.pageResult(success) == success)
    }

    @Test func sendConfirmedRequiresSameConversationIdentity() {
        let before = state(draft: "hello", messages: [])
        let echo = [(key: "u2", kind: "user", text: "hello")]
        #expect(UIController.sendConfirmed(before: before, after: state(draft: "", messages: echo)))
        for other in [identity(url: "x"), identity(epoch: 2), identity(rows: ["s"])] {
            #expect(!UIController.sendConfirmed(before: before, after: state(draft: "", messages: echo, guardValue: other)))
        }
        #expect(!UIController.sameIdentity(nil, identity()))
        // Workspace and lastUser may change when a new session materializes.
        var moved = identity().object ?? [:]
        moved["workspace"] = .array([.string("w")]); moved["lastUser"] = .string("k")
        #expect(UIController.sameIdentity(identity(), .object(moved)))
    }

    @Test func verifiedEchoRetainsExactInputIdentityBeforeDurableFlush() {
        let before = state(draft: "hello", messages: [])
        let after = state(draft: "", messages: [(key: "13:input-messageopaque:input-id", kind: "user", text: "hello")])
        #expect(UIController.sendConfirmed(before: before, after: after))
        #expect(UIController.echoEvidence(before: before, after: after)["inputId"] == .string("opaque:input-id"))
    }

    @Test func replayedReceiptSucceedsOnlyWhenVerified() throws {
        func receipt(_ outcome: String) -> JSONValue {
            .object(["status": .string(outcome == "verified" ? "sent" : outcome == "not_performed" ? "not_sent" : "uncertain"), "outcome": .string(outcome)])
        }
        #expect(try UIController.replayResult(receipt("verified"))["replayedReceipt"]?.bool == true)
        for (outcome, expected) in [("unknown", "unknown"), ("not_performed", "not_performed")] {
            do { _ = try UIController.replayResult(receipt(outcome)); Issue.record("replayed \(outcome)") }
            catch let error as ControlError { #expect(error.code == "replayed_receipt" && error.outcome == expected && error.details == receipt(outcome)) }
        }
        #expect(throws: ControlError.self) { try UIController.replayResult(.object(["status": .string("prepared")])) }
        #expect(throws: ControlError.self) { try UIController.replayResult(.object(["status": .string("uncertain"), "outcome": .string("verified")])) }
    }

    @Test func completionNeedsNonemptyMatchingTurnAndResponse() {
        func row(_ key: String, turn: JSONValue, answer: Bool = false, part: String? = nil, text: String = "t") -> JSONValue {
            .object(["key": .string(key), "kind": .string(key == "u" ? "user" : "assistant-step"), "turn": turn, "answer": .bool(answer), "part": part.map(JSONValue.string) ?? .null, "text": .string(text)])
        }
        let turn = JSONValue.string("t1")
        #expect(UIController.completed(messages: [row("u", turn: turn), row("a", turn: turn, answer: true)], anchor: "u"))
        #expect(UIController.completed(messages: [row("u", turn: turn), row("a", turn: turn, part: "response")], anchor: "u"))
        // Null/missing turns must not match each other; old answers from other turns do not settle.
        #expect(!UIController.completed(messages: [row("u", turn: .null), row("a", turn: .null, answer: true)], anchor: "u"))
        #expect(!UIController.completed(messages: [row("u", turn: .string("")), row("a", turn: .string(""), answer: true)], anchor: "u"))
        #expect(!UIController.completed(messages: [row("u", turn: turn), row("a", turn: .string("t0"), answer: true)], anchor: "u"))
        #expect(!UIController.completed(messages: [row("u", turn: turn), row("a", turn: turn, part: "thinking")], anchor: "u"))
        #expect(!UIController.completed(messages: [row("u", turn: turn), row("a", turn: turn, answer: true, text: "")], anchor: "u"))
        #expect(!UIController.completed(messages: [row("a", turn: turn, answer: true)], anchor: "u"))
        #expect(!UIController.completed(messages: [row("reasoning", turn: turn), row("a", turn: turn, answer: true)], anchor: "reasoning"))
    }

    @Test func overlongSendIsRejectedBeforeAnyInput() {
        #expect(throws: ControlError.self) { try UIController.requireVerifiableSend(String(repeating: "a", count: 12_001)) }
        #expect(throws: Never.self) { try UIController.requireVerifiableSend(" " + String(repeating: "a", count: 12_000) + "\n") }
    }

    @Test func requireStringRejectsMissingWrongTypeAndEmpty() throws {
        let request = JSONValue.object(["a": .string("x"), "empty": .string(""), "n": .number(1)])
        #expect(try request.requireString("a") == "x")
        #expect(try request.requireString("empty", allowEmpty: true) == "")
        for key in ["empty", "n", "missing"] {
            #expect(throws: ControlError.self) { try request.requireString(key) }
        }
    }
}
