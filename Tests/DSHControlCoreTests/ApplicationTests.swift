import Foundation
import Testing
@testable import DSHControlCore

struct ApplicationTests {
    private func target(url: String = "dsh-app://app/", socket: String = "ws://127.0.0.1:9222/devtools/page/page-1") -> JSONValue {
        .object(["type": .string("page"), "url": .string(url), "id": .string("page-1"), "webSocketDebuggerUrl": .string(socket)])
    }

    @Test func testSelectsOnlyExactProductPage() throws {
        let result = try selectProductTarget(.array([target(url: "devtools://devtools/"), target()]), port: 9222)
        #expect(result.id == "page-1")
        #expect(result.socketURL.absoluteString == "ws://127.0.0.1:9222/devtools/page/page-1")
        #expect(throws: (any Error).self) { try selectProductTarget(.array([]), port: 9222) }
        #expect(throws: (any Error).self) { try selectProductTarget(.array([target(), target()]), port: 9222) }
        for url in ["https://app/", "dsh-app://app/other", "dsh-app://app/?x=1"] {
            #expect(throws: (any Error).self) { try selectProductTarget(.array([target(url: url)]), port: 9222) }
        }
    }

    @Test func testRejectsForeignOrUnexpectedSockets() {
        for socket in [
            "ws://127.0.0.1:9223/devtools/page/page-1",
            "ws://localhost:9222/devtools/page/page-1",
            "ws://192.0.2.1:9222/devtools/page/page-1",
            "wss://127.0.0.1:9222/devtools/page/page-1",
            "ws://user@127.0.0.1:9222/devtools/page/page-1",
            "ws://127.0.0.1:9222/devtools/page/other",
            "ws://127.0.0.1:9222/devtools/page/page-1?q=1",
            "ws://127.0.0.1:9222/devtools/page/page-1#fragment",
        ] {
            #expect(throws: (any Error).self) { try selectProductTarget(.array([target(socket: socket)]), port: 9222) }
        }
        #expect(throws: (any Error).self) { try selectProductTarget(.array([target()]), port: 0) }
        #expect(throws: (any Error).self) { try selectProductTarget(.object([:]), port: 9222) }
    }

    @Test func testListenerParsingRetainsOwnershipAndRejectsPublicAddresses() throws {
        let listeners = try parseApplicationListeners("p123\nn127.0.0.1:9222\nn[::1]:9222\np456\nn*:9222\nn192.0.2.1:9222\n", port: 9222)
        #expect(listeners.map(\.pid) == [123, 123, 456, 456])
        #expect(listeners.map(\.loopback) == [true, true, false, false])
        #expect(try parseApplicationListeners("", port: 9222).isEmpty)
        #expect(throws: (any Error).self) { try parseApplicationListeners("n127.0.0.1:9222\n", port: 9222) }
        #expect(throws: (any Error).self) { try parseApplicationListeners("pnope\nn127.0.0.1:9222\n", port: 9222) }
        #expect(throws: (any Error).self) { try parseApplicationListeners("p123\n", port: 9222) }
    }

    @Test func testValidatesBundleMetadataAndExecutableContainment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Harness.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Harness")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        func write(_ identifier: String = "com.deepseek.dsh", executable name: String = "Harness") throws {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleExecutable": name, "CFBundleShortVersionString": "0.2.1-rc.2",
            ], format: .xml, options: 0)
            try data.write(to: plist)
        }
        #expect(throws: (any Error).self) { try HarnessApplication(bundleURL: bundle) }
        try write()
        #expect(try HarnessApplication(bundleURL: bundle).version == "0.2.1-rc.2")
        try write("other.app")
        #expect(throws: (any Error).self) { try HarnessApplication(bundleURL: bundle) }
        for name in ["", "../Harness", "missing"] {
            try write(executable: name)
            #expect(throws: (any Error).self) { try HarnessApplication(bundleURL: bundle) }
        }
        try write()
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(throws: (any Error).self) { try HarnessApplication(bundleURL: bundle) }
        try Data("invalid plist".utf8).write(to: plist)
        #expect(throws: (any Error).self) { try HarnessApplication(bundleURL: bundle) }
    }
}
