import Darwin
import Foundation

/// Controller-owned reservations and creation receipts. The caller holds MutationLock.
public struct SessionClaims {
    private let directory: URL

    public init(directory: URL) throws {
        try secureDirectory(directory)
        self.directory = directory
    }

    public func request(_ requestID: String) throws -> JSONValue? {
        try validateID(requestID)
        return try state()["requests"]?[requestID]
    }

    public func claim(_ sessionID: String) throws -> JSONValue? {
        try state()["claims"]?[sessionID]
    }

    /// Persist intent before the first GUI mutation, so interrupted creation is never repeated.
    public func prepare(requestID: String, signature: String) throws {
        try validateID(requestID)
        var value = try state().object!
        var requests = value["requests"]!.object!
        guard requests[requestID] == nil else { throw ControlError(code: "request_conflict", message: "Creation request already exists; inspect its saved result.", outcome: "unknown") }
        requests[requestID] = .object(["signature": .string(signature), "status": .string("prepared"), "outcome": .string("unknown")])
        value["requests"] = .object(requests)
        try save(.object(value))
    }

    public func reserve(sessionID: String, requestID: String, signature: String, title: String?, reused: Bool) throws -> JSONValue {
        var value = try state().object!
        var claims = value["claims"]!.object!
        var requests = value["requests"]!.object!
        guard claims[sessionID] == nil, requests[requestID]?["signature"]?.string == signature else {
            throw ControlError(code: "session_claimed", message: "This session is already reserved or the creation receipt changed.", outcome: "unknown")
        }
        let result: JSONValue = .object(["sessionId": .string(sessionID), "requestId": .string(requestID),
            "status": .string(reused ? "reused" : "created"), "outcome": .string("verified"),
            "pendingTitle": title.map(JSONValue.string) ?? .null, "titleStatus": .string(title == nil ? "none" : "pending")])
        claims[sessionID] = result
        requests[requestID] = .object(["signature": .string(signature), "status": .string("completed"), "outcome": .string("verified"), "result": result])
        value["claims"] = .object(claims); value["requests"] = .object(requests)
        try save(.object(value))
        return result
    }

    public func release(sessionID: String, requestID: String) throws -> JSONValue {
        var value = try state().object!
        var claims = value["claims"]!.object!
        guard let claim = claims[sessionID], claim["requestId"]?.string == requestID else {
            throw ControlError(code: "claim_owner", message: "Release requires the creation request ID that owns this reservation.")
        }
        claims[sessionID] = nil; value["claims"] = .object(claims)
        try save(.object(value))
        return .object(["sessionId": .string(sessionID), "status": .string("released"), "outcome": .string("verified")])
    }

    public func titleFinished(sessionID: String, status: String) throws {
        var value = try state().object!
        var claims = value["claims"]!.object!
        guard var claim = claims[sessionID]?.object else { return }
        claim["titleStatus"] = .string(status)
        claims[sessionID] = .object(claim); value["claims"] = .object(claims)
        try save(.object(value))
    }

    private func validateID(_ requestID: String) throws {
        guard (1...80).contains(requestID.utf8.count), requestID.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw ControlError(code: "invalid_request_id", message: "Request ID must contain 1–80 ASCII letters, digits, hyphens, or underscores") }
    }

    private func state() throws -> JSONValue {
        let path = directory.appendingPathComponent("session-claims.json").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return .object(["requests": .object([:]), "claims": .object([:])]) }
            throw ControlError(code: "claim_storage", message: "Cannot read session reservations", outcome: "unknown")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try checkFile(fd)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let value = try? JSONValue(parseData: data), let object = value.object,
              Set(object.keys) == ["requests", "claims"], let requests = value["requests"]?.object, let claims = value["claims"]?.object,
              requests.allSatisfy({ key, record in
                  (try? validateID(key)) != nil && record["signature"]?.string != nil &&
                  ["prepared", "completed"].contains(record["status"]?.string ?? "") &&
                  record["outcome"]?.string == (record["status"]?.string == "completed" ? "verified" : "unknown") &&
                  (record["status"]?.string != "completed" || (validClaim(record["result"], sessionID: record["result"]?["sessionId"]?.string ?? "") && record["result"]?["requestId"]?.string == key))
              }), claims.allSatisfy({ key, claim in
                  validClaim(claim, sessionID: key) && requests[claim["requestId"]?.string ?? ""]?["result"]?["sessionId"]?.string == key
              }) else { throw ControlError(code: "corrupt_claims", message: "Session reservations cannot be trusted", outcome: "unknown") }
        return value
    }

    private func validClaim(_ claim: JSONValue?, sessionID: String) -> Bool {
        guard let claim, let fields = claim.object,
              Set(fields.keys) == ["sessionId", "requestId", "status", "outcome", "pendingTitle", "titleStatus"],
              !sessionID.isEmpty, claim["sessionId"]?.string == sessionID,
              let requestID = claim["requestId"]?.string, (try? validateID(requestID)) != nil,
              ["created", "reused"].contains(claim["status"]?.string ?? ""), claim["outcome"]?.string == "verified",
              ["none", "pending", "applied", "skipped_user_title", "unknown"].contains(claim["titleStatus"]?.string ?? ""),
              claim["pendingTitle"] == .null || claim["pendingTitle"]?.string != nil else { return false }
        return true
    }

    private func save(_ value: JSONValue) throws {
        let data = try value.encoded()
        guard data.count <= 1_048_576 else { throw ControlError(code: "claim_storage", message: "Session reservations exceed the storage limit", outcome: "unknown") }
        // Inspect the destination before replacing it; symlinks and shared files are never accepted.
        _ = try state()
        let temporary = directory.appendingPathComponent(".claims-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlError(code: "claim_storage", message: "Cannot create reservation file", outcome: "unknown") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ControlError(code: "claim_storage", message: "Cannot write reservations", outcome: "unknown") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, directory.appendingPathComponent("session-claims.json").path) == 0 else {
            throw ControlError(code: "claim_storage", message: "Cannot publish reservations", outcome: "unknown")
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ControlError(code: "claim_storage", message: "Cannot open reservation directory", outcome: "unknown") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ControlError(code: "claim_storage", message: "Cannot sync reservation directory", outcome: "unknown") }
    }
}
