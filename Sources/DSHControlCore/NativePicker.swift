import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Native folder selection is restricted to one visible window owned by the verified application.
struct NativePicker {
    let application: HarnessApplication

    static func canonicalDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw ControlError(code: "invalid_path", message: "Workspace path must be an absolute directory path without control characters")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw ControlError(code: "invalid_path", message: "Workspace directory does not exist")
        }
        return url
    }

    static func uniqueOwner(pids: [Int32], visiblePIDs: Set<Int32>) throws -> Int32 {
        guard pids.count == 1, let pid = pids.first, visiblePIDs.contains(pid) else {
            throw ControlError(code: "picker_owner", message: "Expected one verified Harness process with an on-screen window")
        }
        return pid
    }

    /// Run before opening the chooser; never request privileges or dismiss an existing dialog.
    func preflight() throws -> Int32 {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw ControlError(code: "accessibility_required", message: "Native folder selection requires existing Accessibility and event-posting permission")
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid() else {
            throw ControlError(code: "interactive_desktop_unavailable", message: "Native folder selection requires this user's interactive console")
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = Set(windows.compactMap { info -> Int32? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0 else { return nil }
            return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        })
        let pid = try Self.uniqueOwner(pids: application.runningPIDs(), visiblePIDs: visible)
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5) == .success else {
            throw ControlError(code: "accessibility_unavailable", message: "The owned app did not accept a bounded Accessibility request")
        }
        guard try dialogs(app).isEmpty else {
            throw ControlError(code: "existing_chooser", message: "An existing native dialog makes folder selection ambiguous; close it manually")
        }
        return pid
    }

    /// The caller has just clicked Add workspace. Any failure after that click remains uncertain.
    func choose(path: URL, pid: Int32, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let app = AXUIElementCreateApplication(pid)
        let chooser = try await wait(deadline: deadline, phase: "chooser") {
            let candidates = try dialogs(app).filter { node in
                let names = try descendants(node).filter { string($0, kAXRoleAttribute) == kAXButtonRole }.map { string($0, kAXTitleAttribute) }
                return names.contains(where: { ["Open", "选择", "打开"].contains($0) }) && names.contains(where: { ["Cancel", "取消"].contains($0) })
            }
            guard candidates.count <= 1 else { throw ControlError(code: "ambiguous_chooser", message: "More than one owned folder chooser is visible", outcome: "unknown") }
            return candidates.first
        }
        try verifyOwner(chooser, pid: pid)
        guard let running = NSRunningApplication(processIdentifier: pid) else {
            throw ControlError(code: "picker_owner", message: "The owned chooser process disappeared", outcome: "unknown")
        }
        if !running.isActive { _ = running.activate(options: [.activateIgnoringOtherApps]) }
        _ = AXUIElementPerformAction(chooser, kAXRaiseAction as CFString)
        _ = try await wait(deadline: deadline, phase: "chooser_focus") {
            guard running.isActive, let focused = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            var node = unsafeDowncast(focused, to: AXUIElement.self)
            for _ in 0..<32 {
                if CFEqual(node, chooser) { return chooser }
                guard let parent = value(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                node = unsafeDowncast(parent, to: AXUIElement.self)
            }
            return nil
        }
        try postKey(pid: pid, code: 5, flags: [.maskCommand, .maskShift])
        let field = try await wait(deadline: deadline, phase: "go_to_folder") {
            guard let focused = value(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let field = unsafeDowncast(focused, to: AXUIElement.self)
            var owner: pid_t = 0
            guard AXUIElementGetPid(field, &owner) == .success, owner == pid else { return nil }
            return string(field, kAXIdentifierAttribute) == "PathTextField" && string(field, kAXRoleAttribute) == kAXTextFieldRole && enabled(field) ? field : nil
        }
        try verifyOwner(field, pid: pid)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path.path as CFString) == .success,
              string(field, kAXValueAttribute) == path.path else {
            throw ControlError(code: "picker_path", message: "The chooser did not accept the exact requested directory", outcome: "unknown")
        }
        let goButtons = try dialogs(app).filter { string($0, kAXIdentifierAttribute) == "GoToWindow" }.flatMap { try descendants($0) }.filter { string($0, kAXRoleAttribute) == kAXButtonRole && ["Go", "前往"].contains(string($0, kAXTitleAttribute)) && enabled($0) }
        guard goButtons.count <= 1, string(field, kAXValueAttribute) == path.path else {
            throw ControlError(code: "picker_path", message: "The exact Go to Folder path became ambiguous", outcome: "unknown")
        }
        if let go = goButtons.first {
            try verifyOwner(go, pid: pid)
            guard AXUIElementPerformAction(go, kAXPressAction as CFString) == .success else {
                throw ControlError(code: "picker_path", message: "The owned Go button could not be activated", outcome: "unknown")
            }
        } else {
            // Only the verified owned path field may receive Enter.
            guard let focused = value(app, kAXFocusedUIElementAttribute), CFEqual(focused, field) else {
                throw ControlError(code: "picker_focus", message: "The verified Go to Folder field no longer owns keyboard focus", outcome: "unknown")
            }
            try postKey(pid: pid, code: 36, flags: [])
        }
        let open = try await wait(deadline: deadline, phase: "directory_confirmation") {
            let nodes = try descendants(chooser)
            let editingPath = nodes.contains { string($0, kAXRoleAttribute) == kAXTextFieldRole && string($0, kAXValueAttribute) == path.path }
            let locationVerified = nodes.contains { node in
                ["AXURL", "AXDocument"].contains { attribute in
                    let location = value(node, attribute) as? URL ?? URL(string: string(node, attribute))
                    guard let location, location.isFileURL else { return false }
                    return location.standardizedFileURL.resolvingSymlinksInPath().path == path.path
                }
            } || nodes.contains { string($0, kAXIdentifierAttribute) == "where popup" && string($0, kAXValueAttribute) == path.lastPathComponent }
            // Current NSSavePanel omits its directory URL; verified absolute Go input plus the acknowledged location identifies it.
            guard !editingPath, locationVerified else { return nil }
            let buttons = nodes.filter { string($0, kAXRoleAttribute) == kAXButtonRole && ["Open", "选择", "打开"].contains(string($0, kAXTitleAttribute)) && enabled($0) }
            return buttons.count == 1 ? buttons[0] : nil
        }
        try verifyOwner(open, pid: pid)
        guard AXUIElementPerformAction(open, kAXPressAction as CFString) == .success else {
            throw ControlError(code: "picker_open", message: "The verified chooser could not confirm Open", outcome: "unknown")
        }
    }

    private func postKey(pid: Int32, code: CGKeyCode, flags: CGEventFlags) throws {
        guard application.runningPIDs() == [pid], NSRunningApplication(processIdentifier: pid)?.isActive == true,
              try dialogs(AXUIElementCreateApplication(pid)).count > 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ControlError(code: "picker_owner", message: "The chooser process changed before keyboard input", outcome: "unknown")
        }
        down.flags = flags; up.flags = flags
        if code == 5 {
            guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                  let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true),
                  let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false),
                  let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
                throw ControlError(code: "picker_input", message: "Native modifier events could not be created", outcome: "unknown")
            }
            commandDown.type = .flagsChanged; commandDown.flags = .maskCommand
            shiftDown.type = .flagsChanged; shiftDown.flags = [.maskCommand, .maskShift]
            shiftUp.type = .flagsChanged; shiftUp.flags = .maskCommand
            commandUp.type = .flagsChanged; commandUp.flags = []
            for event in [commandDown, shiftDown, down, up, shiftUp, commandUp] { event.post(tap: .cghidEventTap) }
            return
        }
        // NSSavePanel ignores postToPid on current macOS; ownership and foreground checks precede native input.
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func verifyOwner(_ element: AXUIElement, pid: Int32) throws {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid, application.runningPIDs() == [pid] else {
            throw ControlError(code: "picker_owner", message: "Native picker ownership changed", outcome: "unknown", details: .object([
                "expectedPid": .number(Double(pid)), "observedPid": .number(Double(owner)),
                "role": .string(string(element, kAXRoleAttribute)), "identifier": .string(string(element, kAXIdentifierAttribute))]))
        }
    }

    private func wait(deadline: Date, phase: String, probe: () throws -> AXUIElement?) async throws -> AXUIElement {
        repeat {
            if let value = try probe() { return value }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw ControlError(code: "picker_timeout", message: "Native folder selection could not verify \(phase); no automatic retry was attempted", outcome: "unknown", details: .object(["phase": .string(phase)]))
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        if let url = value(element, attribute) as? URL { return url.absoluteString }
        return value(element, attribute) as? String ?? ""
    }

    private func enabled(_ element: AXUIElement) -> Bool { value(element, kAXEnabledAttribute) as? Bool == true }

    private func descendants(_ root: AXUIElement, deadline: Date = Date().addingTimeInterval(2)) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            guard Date() < deadline else { throw ControlError(code: "picker_timeout", message: "Native Accessibility inspection exceeded its bounded scan") }
            if result.contains(where: { CFEqual($0, node) }) { continue }
            guard result.count < 4096, depth < 32 else { throw ControlError(code: "picker_tree", message: "Native picker accessibility tree exceeded inspection bounds", outcome: "unknown") }
            result.append(node)
            // The chooser is native; traversing the Electron transcript makes preflight proportional to chat history.
            if ["AXWebArea", "AXHTMLArea", "AXOutline", "AXTable", "AXBrowser"].contains(string(node, kAXRoleAttribute)) { continue }
            let children = (value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []) + (value(node, "AXSheets") as? [AXUIElement] ?? [])
            for child in children where !result.contains(where: { CFEqual($0, child) }) { pending.append((child, depth + 1)) }
        }
        return result
    }

    private func dialogs(_ app: AXUIElement) throws -> [AXUIElement] {
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            throw ControlError(code: "accessibility_unavailable", message: "The owned application's native windows could not be inspected")
        }
        // AppKit publishes sheets on their window; the web document is irrelevant to native chooser ownership.
        let nodes = windows.flatMap { window in [window] + (value(window, "AXSheets") as? [AXUIElement] ?? []) + (value(window, kAXChildrenAttribute) as? [AXUIElement] ?? []) }
        return nodes.filter { node in
            string(node, kAXRoleAttribute) == kAXSheetRole || ["AXDialog", "AXSystemDialog"].contains(string(node, kAXSubroleAttribute))
        }.reduce(into: []) { result, node in if !result.contains(where: { CFEqual($0, node) }) { result.append(node) } }
    }
}
