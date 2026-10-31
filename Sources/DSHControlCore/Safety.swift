import CryptoKit
import Darwin
import Foundation

/// Stable digest of a JSON value, independent of object key insertion order.
public enum StateDigest {
    public static func token(_ value: JSONValue) throws -> String {
        SHA256.hash(data: try value.encoded()).map { String(format: "%02x", $0) }.joined()
    }

    public static func text(_ value: String) -> String {
        bytes(Data(value.utf8))
    }
    public static func bytes(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
}

/// Nonblocking process lock. Closing the descriptor, including on a crash, releases ownership.
public final class MutationLock {
    private let descriptor: Int32

    public init(directory: URL) throws {
        try secureDirectory(directory)
        let descriptor = Darwin.open(directory.appendingPathComponent("mutation.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw storageError("Cannot open mutation lock") }
        do {
            try checkFile(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw ControlError(code: "busy", message: "Another mutation is in progress") }
                throw storageError("Cannot acquire mutation lock")
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// Durable send outcomes; callers hold MutationLock across lookup, prepare, send, and finish.
public struct SendReceipts {
    private let directory: URL
    private let fields: Set<String> = ["requestId", "signature", "targetId", "status", "outcome", "time"]

    public init(directory: URL) throws {
        try secureDirectory(directory)
        self.directory = directory
    }

    public func lookup(requestID: String) throws -> JSONValue? {
        let url = try path(requestID)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw storageError("Cannot read send receipt", outcome: "unknown")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try checkFile(descriptor)
        let value: JSONValue
        do {
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw storageError("Send receipt exceeds size limit") }
            value = try JSONValue(parseData: data)
        } catch {
            throw ControlError(code: "corrupt_receipt", message: "Stored send receipt cannot be trusted", outcome: "unknown")
        }
        try validate(value, requestID: requestID)
        return value
    }

    /// Existing request IDs return their saved receipt and must never be dispatched again.
    public func prepare(requestID: String, signature: String, targetID: String, submission: JSONValue? = nil) throws -> JSONValue {
        if let existing = try lookup(requestID: requestID) { return existing }
        var values: [String: JSONValue] = [
            "requestId": .string(requestID), "signature": .string(signature), "targetId": .string(targetID),
            "status": .string("prepared"), "outcome": .string("unknown"),
            "time": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if let submission { values["version"] = .number(2); values["submission"] = submission }
        let record = JSONValue.object(values)
        try validate(record, requestID: requestID)
        if try !write(record, to: path(requestID), exclusively: true) {
            guard let existing = try lookup(requestID: requestID) else { throw storageError("Send receipt disappeared", outcome: "unknown") }
            return existing
        }
        return record
    }

    public func finish(requestID: String, receipt: JSONValue) throws {
        try validate(receipt, requestID: requestID)
        guard let previous = try lookup(requestID: requestID),
              previous["signature"] == receipt["signature"], previous["targetId"] == receipt["targetId"],
              previous["version"] == receipt["version"], previous["submission"] == receipt["submission"],
              previous["status"]?.string != "sent" || receipt["status"]?.string == "sent",
              previous["status"]?.string != "uncertain" || receipt["status"]?.string != "not_sent" else {
            throw ControlError(code: "receipt_mismatch", message: "Receipt does not match its prepared send", outcome: "unknown")
        }
        _ = try write(receipt, to: path(requestID), exclusively: false)
    }

    private func path(_ requestID: String) throws -> URL {
        guard (1...80).contains(requestID.utf8.count), requestID.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw ControlError(code: "invalid_request_id", message: "Request ID must contain 1–80 ASCII letters, digits, hyphens, or underscores") }
        return directory.appendingPathComponent(requestID + ".json")
    }

    private func validate(_ receipt: JSONValue, requestID: String) throws {
        let outcomes = ["prepared": "unknown", "sent": "verified", "uncertain": "unknown", "not_sent": "not_performed"]
        guard let object = receipt.object,
              fields.allSatisfy({ object[$0]?.string != nil }), receipt["requestId"]?.string == requestID,
              let status = receipt["status"]?.string, outcomes[status] == receipt["outcome"]?.string else {
            throw ControlError(code: "corrupt_receipt", message: "Receipt fields are invalid", outcome: "unknown")
        }
        if receipt["version"] == nil {
            guard Set(object.keys) == fields else { throw ControlError(code: "corrupt_receipt", message: "Legacy receipt fields are invalid", outcome: "unknown") }
            return
        }
        let extra: Set<String> = ["version", "submission", "verification"]
        guard receipt["version"] == .number(2), Set(object.keys).isSubset(of: fields.union(extra)),
              let submission = receipt["submission"], submission.object != nil,
              submission["sessionId"]?.string?.isEmpty == false,
              submission["operation"]?.string?.isEmpty == false,
              let digest = submission["digest"]?.string, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              submission["cursor"] != nil,
              receipt["verification"] == nil || receipt["verification"]?.object != nil else {
            throw ControlError(code: "corrupt_receipt", message: "Version 2 receipt evidence is invalid", outcome: "unknown")
        }
    }

    private func write(_ receipt: JSONValue, to destination: URL, exclusively: Bool) throws -> Bool {
        let data = try receipt.encoded()
        guard data.count <= 65_536 else { throw storageError("Send receipt exceeds size limit", outcome: "unknown") }
        let temporary = directory.appendingPathComponent(".receipt-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw storageError("Cannot create send receipt", outcome: "unknown") }
        defer { Darwin.close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw storageError("Cannot write send receipt", outcome: "unknown") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw storageError("Cannot sync send receipt", outcome: "unknown") }
        if exclusively {
            guard link(temporary.path, destination.path) == 0 else {
                if errno == EEXIST { return false }
                throw storageError("Cannot publish send receipt", outcome: "unknown")
            }
        } else {
            guard rename(temporary.path, destination.path) == 0 else { throw storageError("Cannot update send receipt", outcome: "unknown") }
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw storageError("Cannot open receipt directory", outcome: "unknown") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw storageError("Cannot sync receipt directory", outcome: "unknown") }
        return true
    }
}

func secureDirectory(_ directory: URL) throws {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
        throw storageError("Cannot create private storage directory")
    }
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0 else {
        throw ControlError(code: "unsafe_storage", message: "Storage must be an owner-only directory without a symlink")
    }
}

func checkFile(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
        throw ControlError(code: "unsafe_storage", message: "Storage file must be regular, owner-only, and unlinked elsewhere", outcome: "unknown")
    }
}

func storageError(_ message: String, outcome: String = "not_performed") -> ControlError {
    ControlError(code: "storage_failure", message: message, outcome: outcome)
}
