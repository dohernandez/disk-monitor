import Cocoa
import SwiftUI
import ApplicationServices

// Uses Apple's Accessibility API to operate Search Privacy, never the private
// Spotlight database. Navigation reference and known limits: docs/SPOTLIGHT-AUTOMATION.md.
enum SpotlightPrivacyError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}
struct SpotlightPrivacySnapshot {
    let paths: Set<String>
    static func path(_ raw: String) -> String? {
        let value: String
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { value = url.path }
        else { value = raw }
        guard value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r") else { return nil }
        // APFS names are normalization-insensitive, and the folder chooser reports decomposed
        // (NFD) names; compare in one canonical (NFC) form.
        return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }
    // Every row must have an exact identity. A name such as "Caches" is ambiguous.
    init(rows: [[String]]) throws {
        var result = Set<String>()
        for row in rows {
            let identities = Set(row.compactMap(Self.path))
            guard identities.count == 1, let path = identities.first else {
                throw SpotlightPrivacyError.unavailable("macOS did not expose an exact folder path. Exclusion status is unknown; no further changes were made.")
            }
            result.insert(path)
        }
        paths = result
    }
    func matchesChange(from before: SpotlightPrivacySnapshot, path: String, excluded: Bool) -> Bool {
        guard let path = Self.path(path) else { return false }
        return paths == (excluded ? before.paths.union([path]) : before.paths.subtracting([path]))
    }
    func ancestor(of raw: String) -> String? {
        guard let path = Self.path(raw) else { return nil }
        return paths.filter { path != $0 && path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .sorted { $0.count > $1.count }.first
    }
    func covering(_ path: String) -> String? {
        guard let path = Self.path(path) else { return nil }
        return paths.filter { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .sorted { $0.count > $1.count }.first
    }
}

final class SpotlightPrivacyAutomation {
    private var process: NSRunningApplication?
    private var application: AXUIElement?
    private var openedSheet = false
    private let cancelled: () -> Bool
    // The exact exclusion list, read by the root scanner (Search Privacy rows show only names).
    // nil: add-only fallback, verified by row names.
    private let exactList: (() throws -> SpotlightPrivacySnapshot)?
    init(cancelled: @escaping () -> Bool = { false }, exactList: (() throws -> SpotlightPrivacySnapshot)? = nil) {
        self.cancelled = cancelled; self.exactList = exactList
    }
    // How System Settings is presented while a change is applied.
    // foreground: opened and activated for the whole change. brief: opened without activating;
    // activated only while the folder chooser needs keystrokes, then focus goes back, and
    // System Settings is left as it was (quit if this change launched it).
    // background and hidden never activate; they exist to record what macOS does not allow
    // (docs/SPOTLIGHT-AUTOMATION.md): no keystrokes reach the chooser, and a hidden app
    // does not present the Search Privacy sheet.
    enum Presentation: String { case foreground, background, hidden, brief }
    var presentation: Presentation = .brief
    // Adding needs keystrokes in the folder chooser. In the VM they were lost in 3 of 5 runs
    // unless System Settings stayed the active app for the whole add, so an add runs in the
    // foreground and is tidied up afterwards. Removing needs no keystrokes and stays in the background.
    private var foregroundAdd = false
    private var focusedAt: Date?
    private var previous: NSRunningApplication?
    private var launched = false
    private var hiddenBefore = false
    private var focused = false
    private(set) var presentationNotes: [String] = []
    private func fail(_ message: String) -> SpotlightPrivacyError { .unavailable(message) }
    private func check() throws {
        if cancelled() { throw fail("Operation stopped. Refresh to check the current macOS exclusions.") }
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func elements(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(5)
        while !queue.isEmpty {
            try check()
            let item = queue.removeFirst()
            guard !result.contains(where: { CFEqual($0, item) }) else { continue }
            guard Date() < deadline else { throw fail("Timed out reading the macOS controls.") }
            guard result.count < 1500 else { throw fail("The macOS controls could not be identified. No further changes were made.") }
            result.append(item); queue += elements(item)
        }
        return result
    }
    private func wait<T>(_ description: String, timeout: TimeInterval = 8, _ find: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try check()
            if let value = try find() { return value }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        throw fail("Timed out waiting for \(description). No change was confirmed.")
    }
    private func foreground() throws {
        try check()
        // Accessibility actions do not need System Settings in front; only keystrokes do.
        if presentation != .foreground && !focused { return }
        guard let process, NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier else {
            throw fail("System Settings lost focus. No change was confirmed; try again.")
        }
    }
    private func press(_ element: AXUIElement) throws {
        try foreground()
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw fail("macOS could not activate the requested control.") }
    }
    // The folder chooser runs in a separate service process, so keys posted to System
    // Settings' pid never reach it. Like System Events, post to the frontmost app, and
    // only after confirming System Settings is frontmost.
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        if presentation == .brief { try focus() }
        try foreground()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw fail("Could not send the folder-selection command.") }
        down.flags = flags; up.flags = flags
        if presentation == .background || presentation == .hidden {
            // Never activated: the only place to send keys is the Settings process itself.
            guard let process else { throw fail("Could not send the folder-selection command.") }
            down.postToPid(process.processIdentifier); up.postToPid(process.processIdentifier)
            return
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    // Keystrokes reach the folder chooser only while System Settings is the active app.
    private func focus() throws {
        guard !focused, let process, let application else { return }
        let started = Date()
        // Accessibility activation plus the AppKit request: either alone was not always enough
        // when System Settings was already running in the background.
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = DispatchQueue.main.sync { process.activate() }
        _ = try wait("System Settings to accept the folder path", timeout: 5) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
                && (self.attribute(application, kAXFrontmostAttribute) as? Bool) == true ? true : nil
        }
        if let window = windows().first {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        Thread.sleep(forTimeInterval: 0.4)
        focused = true; focusedAt = Date()
        presentationNotes.append(String(format: "activated in %.2fs", Date().timeIntervalSince(started)))
    }
    private func focusState() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        var role = "none"
        if let application, let element = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(element) == AXUIElementGetTypeID() {
            let node = unsafeBitCast(element, to: AXUIElement.self)
            role = string(node, kAXRoleAttribute) + "/" + string(node, kAXSubroleAttribute) + "/" + string(node, kAXIdentifierAttribute)
        }
        return "frontmost=\(front) focusedElement=\(role)"
    }
    private func unfocus() {
        guard focused else { return }
        focused = false
        guard let previous, !previous.isTerminated, let process else { return }
        DispatchQueue.main.sync {
            if previous.processIdentifier == ProcessInfo.processInfo.processIdentifier { NSApp.activate(ignoringOtherApps: true) }
            else { _ = previous.activate() }
        }
        let asked = Date()
        while NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier, Date().timeIntervalSince(asked) < 3 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let back = NSWorkspace.shared.frontmostApplication?.processIdentifier != process.processIdentifier
        presentationNotes.append(String(format: "focus %@ after %.2fs active", back ? "returned" : "NOT returned", Date().timeIntervalSince(focusedAt ?? asked)))
    }
    private func position(_ window: AXUIElement) -> CGPoint? {
        guard let value = attribute(window, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }
    private func openPane() throws {
        let url = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first { !$0.isTerminated }
        launched = running == nil; hiddenBefore = running?.isHidden ?? false
        previous = NSWorkspace.shared.frontmostApplication
        if presentation == .foreground {
            guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(url) }) else { throw fail("Could not open Spotlight settings.") }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = presentation == .hidden
        // A System Settings that is still quitting (for example after the previous change)
        // refuses the request; retry briefly.
        var opened = false
        for attempt in 0..<4 where !opened {
            try check()
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in failure = error; done.signal() }
            opened = done.wait(timeout: .now() + 10) == .success && failure == nil
        }
        guard opened else { throw fail("Could not open Spotlight settings.") }
    }
    // Leave System Settings as it was: quit it if this operation launched it, otherwise hide
    // it again if it was hidden. It stays on the Spotlight pane. No-op for the foreground mode.
    private func restore() {
        guard presentation != .foreground || foregroundAdd, let process else { return }
        unfocus()
        if launched {
            process.terminate()
            // Let it finish quitting so a following change starts from a clean state.
            let asked = Date()
            while !process.isTerminated, Date().timeIntervalSince(asked) < 4 { Thread.sleep(forTimeInterval: 0.05) }
            presentationNotes.append("quit System Settings (launched for this change)")
            return
        }
        if hiddenBefore { process.hide() } else if presentation == .hidden { process.unhide() }
    }
    private func url(_ element: AXUIElement) -> String? {
        (attribute(element, kAXURLAttribute) as? URL).flatMap { $0.isFileURL ? SpotlightPrivacySnapshot.path($0.path) : nil }
    }
    private func sheets(_ root: AXUIElement) throws -> [AXUIElement] {
        try descendants(root).dropFirst().filter { string($0, kAXRoleAttribute) == kAXSheetRole }
    }
    private func windows() -> [AXUIElement] { application.map { elements($0, kAXWindowsAttribute) } ?? [] }
    private func privacySheet() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw fail("Allow Disk Monitor in System Settings → Privacy & Security → Accessibility, then retry.") }
        try openPane()
        process = try wait("System Settings") {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first { !$0.isTerminated }
        }
        application = AXUIElementCreateApplication(process!.processIdentifier)
        AXUIElementSetMessagingTimeout(application!, 2)
        let window = try wait("Spotlight settings") { self.windows().first }
        // Never act on an unrelated sheet the user already had open.
        guard try sheets(window).isEmpty else { throw fail("Close the open dialog in System Settings, then retry.") }
        let button: AXUIElement = try wait("Search Privacy") {
            let nodes = try self.descendants(window)
            let named = nodes.filter { node in
                self.string(node, kAXRoleAttribute) == kAXButtonRole &&
                [kAXTitleAttribute, kAXDescriptionAttribute].contains { name in
                    ["Search Privacy", "Search Privacy…", "Spotlight Privacy", "Spotlight Privacy…"].contains(self.string(node, name))
                }
            }
            if named.count == 1 { return named[0] }
            // Sequoia's privacy button can be unnamed. Use the documented content
            // hierarchy only, and refuse ambiguous candidates instead of guessing.
            let groups = self.elements(window).filter { self.string($0, kAXRoleAttribute) == kAXGroupRole }
            guard groups.count == 1,
                  let split = self.elements(groups[0]).first(where: { self.string($0, kAXRoleAttribute) == kAXSplitGroupRole }) else { return nil }
            let sides = self.elements(split).filter { self.string($0, kAXRoleAttribute) == kAXGroupRole }
            guard sides.count == 2 else { return nil }
            let content = try self.descendants(sides[1])
            // Verify this is the Spotlight pane, not another settings category.
            guard self.string(window, kAXTitleAttribute) == "Spotlight" else { return nil }
            let unnamed = content.filter {
                self.string($0, kAXRoleAttribute) == kAXButtonRole && self.string($0, kAXTitleAttribute).isEmpty && self.string($0, kAXDescriptionAttribute) == "button"
            }
            return unnamed.count == 1 ? unnamed[0] : nil
        }
        try press(button); openedSheet = true
        return try wait("Search Privacy dialog") {
            let found = try self.sheets(window)
            return found.count == 1 ? found[0] : nil
        }
    }
    private func exclusionList(_ sheet: AXUIElement) throws -> AXUIElement {
        let lists = try descendants(sheet).filter { [kAXTableRole, kAXOutlineRole, kAXListRole].contains(string($0, kAXRoleAttribute)) }
        guard lists.count == 1 else { throw fail("This macOS Search Privacy layout is not supported yet. No further changes were made.") }
        return lists[0]
    }
    private func rows(_ sheet: AXUIElement) throws -> [AXUIElement] {
        guard let value = attribute(try exclusionList(sheet), kAXRowsAttribute) as? [AXUIElement] else {
            throw fail("macOS did not expose the complete exclusion list. Status is unknown.")
        }
        return value
    }
    private func rowIdentity(_ row: AXUIElement) throws -> [String] {
        try descendants(row).flatMap { node in
            [kAXURLAttribute, kAXValueAttribute, kAXHelpAttribute, kAXDescriptionAttribute].compactMap { name in
                if let url = attribute(node, name) as? URL { return url.isFileURL ? url.path : nil }
                return attribute(node, name) as? String
            }
        }
    }
    // The name a Search Privacy row shows (its only identity on macOS 15).
    private func rowName(_ row: AXUIElement) throws -> String? {
        let names = try descendants(row).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }.map { string($0, kAXValueAttribute) }
        return names.count == 1 ? names[0] : nil
    }
    private func snapshot(_ sheet: AXUIElement) throws -> SpotlightPrivacySnapshot {
        try SpotlightPrivacySnapshot(rows: rows(sheet).map { try rowIdentity($0) })
    }
    private func namedButton(_ root: AXUIElement, names: [String]) throws -> AXUIElement {
        let found = try descendants(root).filter {
            string($0, kAXRoleAttribute) == kAXButtonRole &&
                (names.contains(string($0, kAXTitleAttribute)) || names.contains(string($0, kAXDescriptionAttribute)))
        }
        guard found.count == 1 else { throw fail("The requested macOS control could not be identified unambiguously.") }
        return found[0]
    }
    // After a failure, close any chooser and the Search Privacy sheet this operation
    // opened, so System Settings is not left mid-dialog. Only while Settings is frontmost.
    private(set) var cleanupNotes: [String] = []
    #if DISK_MONITOR_TESTS
    // Test build diagnostic: the chooser's accessibility tree when finding the folder failed.
    private(set) var failureTree: [String] = []
    // Test build experiment: reach the folder with Accessibility actions only, no keystrokes.
    var walksChooser = false
    #endif
    private func closeOpened() {
        guard openedSheet else { return }
        closeSheets()
    }
    // Innermost first: Cancel a chooser, then Done on Search Privacy. Only while Settings is frontmost.
    func closeSheets() {
        for _ in 0..<4 {
            guard let window = windows().first, let open = try? sheets(window), let innermost = open.last else {
                cleanupNotes.append("no open dialogs"); return
            }
            let nested = (try? sheets(innermost)) ?? []
            guard nested.isEmpty else { cleanupNotes.append("unexpected nested dialog"); return }
            let buttonsGone = !controls(of: innermost).contains { string($0, kAXIdentifierAttribute) == "CancelButton" }
            if buttonsGone, (try? pathField(in: innermost)) ?? nil != nil {
                // Go to Folder replaces the chooser's buttons; Escape closes it.
                try? focus(); try? key(53); Thread.sleep(forTimeInterval: 0.6)
                cleanupNotes.append("closed Go to Folder"); continue
            }
            let buttons = (try? descendants(innermost).filter { string($0, kAXRoleAttribute) == kAXButtonRole }) ?? []
            func named(_ name: String) -> AXUIElement? { buttons.first { string($0, kAXTitleAttribute) == name || string($0, kAXDescriptionAttribute) == name } }
            let cancel = buttons.first { string($0, kAXIdentifierAttribute) == "CancelButton" }
            guard let button = cancel ?? named("Cancel") ?? named("Done") else { cleanupNotes.append("no Cancel/Done in the open dialog"); return }
            do { try press(button); cleanupNotes.append("closed a dialog") }
            catch { cleanupNotes.append("could not close: " + error.localizedDescription); return }
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
    #if DISK_MONITOR_TESTS
    // Test build: close dialogs left open in an already running System Settings.
    func closeLeftovers() -> [String] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return ["System Settings is not running"] }
        process = running
        application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application!, 2)
        _ = DispatchQueue.main.sync { running.activate() }
        guard (try? wait("System Settings in front") { NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier ? true : nil }) != nil else {
            return ["System Settings did not come to the front; nothing closed"]
        }
        closeSheets()
        return cleanupNotes
    }
    #endif
    func run(path: String? = nil, excluded: Bool = false) throws -> SpotlightPrivacySnapshot? {
        defer { restore() }
        do { return try operate(path: path, excluded: excluded) }
        catch { closeOpened(); throw error }
    }
    private func operate(path requested: String?, excluded: Bool) throws -> SpotlightPrivacySnapshot? {
        guard let exactList else { return try addByName(requested, excluded: excluded) }
        // Reading needs no System Settings window: the root list is exact. When the scanner
        // cannot answer, adding still works by name; checked state stays unknown.
        let before: SpotlightPrivacySnapshot
        do { before = try exactList() }
        catch { if excluded, requested != nil { return try addByName(requested, excluded: true) }; throw error }
        guard let requested, let path = SpotlightPrivacySnapshot.path(requested) else { return before }
        let covering = before.covering(path)
        if excluded && covering != nil || !excluded && covering == nil { return before }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if !excluded {
            guard before.ancestor(of: path) == nil, covering == path else {
                throw fail("This folder is excluded through a parent folder. Change the parent exclusion first.")
            }
            // Rows show only names, so a name shared by two excluded folders cannot be removed safely.
            guard before.paths.filter({ URL(fileURLWithPath: $0).lastPathComponent == name }).count == 1 else {
                throw fail("Two excluded folders are named “\(name)”. Remove this one in System Settings → Spotlight → Search Privacy.")
            }
        }
        if excluded && presentation == .brief { presentation = .foreground; foregroundAdd = true }
        let sheet = try privacySheet()
        if excluded { try addFolder(path, in: sheet) } else { try removeRow(named: name, in: sheet) }
        // macOS saves the list asynchronously; the root read is the persisted state.
        let after: SpotlightPrivacySnapshot
        do { after = try wait("macOS to save the exclusion change", timeout: 20) {
            guard try self.sheets(sheet).isEmpty else { return nil }
            let value = try exactList()
            return value.matchesChange(from: before, path: path, excluded: excluded) ? value : nil
        } } catch {
            // An add must leave exactly the requested path. Remove anything else it added.
            guard excluded, let now = try? exactList(), (try? sheets(sheet).isEmpty) == true else { throw error }
            let unexpected = now.paths.subtracting(before.paths).subtracting([path])
            guard !unexpected.isEmpty else { throw error }
            var kept: [String] = []
            for extra in unexpected.sorted() {
                let extraName = URL(fileURLWithPath: extra).lastPathComponent
                guard now.paths.filter({ URL(fileURLWithPath: $0).lastPathComponent == extraName }).count == 1,
                      (try? removeRow(named: extraName, in: sheet)) != nil,
                      (try? wait("macOS to undo the change", timeout: 10) { try exactList().paths.contains(extra) ? nil : true }) != nil else { kept.append(extra); continue }
            }
            throw fail(kept.isEmpty ? "macOS excluded a different folder; it was included again. Nothing changed."
                       : "macOS excluded a different folder: \(kept.joined(separator: ", ")). Remove it in System Settings → Spotlight → Search Privacy.")
        }
        try press(namedButton(sheet, names: ["Done"]))
        return after
    }
    // Fallback without the root list: add only, verified by the new row's name. Status stays unknown.
    private func addByName(_ requested: String?, excluded: Bool) throws -> SpotlightPrivacySnapshot? {
        guard excluded, let requested, let path = SpotlightPrivacySnapshot.path(requested) else {
            throw fail("Exact exclusions need Spotlight measurement turned on. Folders can still be added.")
        }
        if presentation == .brief { presentation = .foreground; foregroundAdd = true }
        let sheet = try privacySheet()
        let beforeNames = try rows(sheet).map { try rowName($0) }
        guard !beforeNames.contains(nil) else { throw fail("macOS did not show the exclusion list. No changes were made.") }
        try addFolder(path, in: sheet)
        let name = URL(fileURLWithPath: path).lastPathComponent
        _ = try wait("macOS to show the new exclusion", timeout: 20) { () -> Bool? in
            guard try self.sheets(sheet).isEmpty else { return nil }
            let names = try self.rows(sheet).map { try self.rowName($0) }
            return names.count == beforeNames.count + 1 && names.filter({ $0 == name }).count == beforeNames.filter({ $0 == name }).count + 1 ? true : nil
        }
        try press(namedButton(sheet, names: ["Done"]))
        return nil
    }
    private func removeRow(named name: String, in sheet: AXUIElement) throws {
        let matches = try rows(sheet).filter { try rowName($0) == name }
        guard matches.count == 1 else { throw fail("Could not identify the exact folder to remove. No changes were made.") }
        try foreground()
        let list = try exclusionList(sheet)
        guard AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [matches[0]] as CFArray) == .success,
              let selected = attribute(list, kAXSelectedRowsAttribute) as? [AXUIElement],
              selected.count == 1, CFEqual(selected[0], matches[0]) else {
            throw fail("macOS could not select only the requested folder. No exclusions were removed.")
        }
        try press(namedButton(sheet, names: ["Remove", "Remove selected item", "Remove selected items", "−", "-",
                                              "Remove the selected disk or folder to no longer exclude from indexing."]))
    }
    private func addFolder(_ path: String, in sheet: AXUIElement) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw fail("The folder no longer exists.") }
        try press(namedButton(sheet, names: ["Add", "Add a folder", "Add item", "+", "Add folder or a disk to exclude from indexing."]))
        let picker = try wait("folder chooser") {
            let children = try self.sheets(sheet)
            return children.count == 1 ? children[0] : nil
        }
        // Go to the parent, then select the exact folder row. Choosing the chooser's
        // current directory is never accepted as proof of selection.
        let target = URL(fileURLWithPath: path)
        // The chooser does not list hidden folders (e.g. ~/.cargo), so they cannot be selected in
        // their parent. Go into the folder itself and choose it as the chooser's current folder;
        // the exact list read afterwards is the proof, and anything else added is removed again.
        let hidden = target.lastPathComponent.hasPrefix(".") || ((try? target.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false)
        let parent = hidden ? path : target.deletingLastPathComponent().path
        var walked = false
        #if DISK_MONITOR_TESTS
        if walksChooser { try walk(to: path, in: picker); walked = true }
        #endif
        if !walked {
            try key(5, flags: [.maskCommand, .maskShift])
            let field: AXUIElement
            do { field = try wait("Go to Folder") {
                // Fast path: Go to Folder focuses its own text field. Scanning the whole chooser
                // takes seconds, and System Settings stays the active app meanwhile.
                if let app = self.application, let focus = self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID() {
                    let node = unsafeBitCast(focus, to: AXUIElement.self)
                    if [kAXTextFieldRole, kAXComboBoxRole].contains(self.string(node, kAXRoleAttribute)),
                       self.string(node, kAXSubroleAttribute) != kAXSearchFieldSubrole, self.url(node) == nil { return node }
                }
                if let known = try self.pathField(in: picker) { return known }
                let fields = try self.descendants(picker).filter {
                    [kAXTextFieldRole, kAXComboBoxRole].contains(self.string($0, kAXRoleAttribute))
                        && self.string($0, kAXSubroleAttribute) != kAXSearchFieldSubrole
                        && (self.attribute($0, kAXFocusedAttribute) as? Bool) == true
                }
                return fields.count == 1 ? fields[0] : nil
            } } catch { presentationNotes.append("at Go to Folder timeout: " + focusState()); throw error }
            try foreground()
            // The box is still appearing when its field is first found; text and Return sent
            // then are dropped. Let it settle before each.
            Thread.sleep(forTimeInterval: 0.5)
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, parent as CFString) == .success,
                  string(field, kAXValueAttribute) == parent else { throw fail("Could not enter the folder path. No exclusion was added.") }
            // A Return keystroke can be lost. Verify the chooser left Go to Folder at the
            // destination; if not, refocus the field and press Return again.
            var confirmed = false
            for attempt in 0..<3 where !confirmed {
                if attempt > 0 {
                    // Return goes to the chooser's Choose button once the box has closed, so
                    // press it again only while Go to Folder is provably still open.
                    guard try goToFolderOpen(in: picker) else { break }
                    try? focus()
                    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                Thread.sleep(forTimeInterval: 0.4)
                try key(36)
                confirmed = (try? wait("the folder path to be accepted", timeout: 4) { try self.chooser(picker, shows: parent) ? true : nil }) != nil
            }
            guard confirmed else { throw fail("macOS did not accept the folder path. No exclusion was added.") }
            unfocus()
        }
        if hidden && !walked {
            unfocus()
            _ = try wait("the folder in the chooser") { try self.chooser(picker, shows: path) ? true : nil }
            try pressChoose(in: picker)
            return
        }
        // List view exposes rows (AXRow). Icon view (AXCollectionList, github.com/TamaT-LLC/openpath/pull/64)
        // and column view (AXBrowser columns) expose plain AXLists of groups holding the AXURL item.
        // Select the exact item; the selection's identity is verified before Choose.
        let item: (element: AXUIElement, container: AXUIElement, attribute: String)
        do { item = try wait("the folder in the chooser") {
            let targets = try self.descendants(picker).filter { self.url($0) == path }
            guard targets.count == 1 else { return nil }
            var node = targets[0], previous = targets[0]
            for _ in 0..<8 {
                guard let parent = self.attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                previous = node; node = unsafeBitCast(parent, to: AXUIElement.self)
                if self.string(previous, kAXRoleAttribute) == kAXRowRole { return (previous, node, kAXSelectedRowsAttribute) }
                if self.string(node, kAXRoleAttribute) == kAXListRole {
                    return (previous, node, kAXSelectedChildrenAttribute)
                }
            }
            return nil
        } } catch {
            #if DISK_MONITOR_TESTS
            var lines: [String] = []; try? tree(picker, into: &lines); failureTree = lines
            #endif
            throw error
        }
        // Keystrokes are done; selecting and choosing are Accessibility actions.
        unfocus()
        try foreground()
        guard AXUIElementSetAttributeValue(item.container, item.attribute as CFString, [item.element] as CFArray) == .success else {
            throw fail("macOS could not select the folder. No exclusion was added.")
        }
        let selected: [AXUIElement] = try wait("the folder selection") {
            guard let items = self.attribute(item.container, item.attribute) as? [AXUIElement], items.count == 1, CFEqual(items[0], item.element) else { return nil }
            return items
        }
        let chosenPaths = try SpotlightPrivacySnapshot(rows: selected.map { try rowIdentity($0) }).paths
        guard chosenPaths == [path] else { throw fail("The selected folder does not match the requested path. No exclusion was added.") }
        try pressChoose(in: picker)
    }
    // Go to Folder is done when the chooser's buttons are back (they are replaced while the box
    // is open) and its location pop-up names the destination folder.
    private func chooser(_ picker: AXUIElement, shows folder: String) throws -> Bool {
        let nodes = controls(of: picker)
        guard nodes.contains(where: { string($0, kAXIdentifierAttribute) == "OKButton" }) else { return false }
        let name = URL(fileURLWithPath: folder).lastPathComponent.precomposedStringWithCanonicalMapping
        return nodes.contains { string($0, kAXIdentifierAttribute) == "where popup" && string($0, kAXValueAttribute).precomposedStringWithCanonicalMapping == name }
    }
    // The chooser's own controls (Choose, Cancel, location pop-up, Go to Folder field) sit within
    // two levels of the sheet. Scanning its whole file list on every poll takes seconds.
    private func controls(of picker: AXUIElement) -> [AXUIElement] {
        let first = elements(picker)
        return first + first.flatMap { elements($0) }
    }
    private func goToFolderOpen(in picker: AXUIElement) throws -> Bool {
        let nodes = controls(of: picker)
        return nodes.contains { string($0, kAXIdentifierAttribute) == "PathTextField" }
            && !nodes.contains { string($0, kAXIdentifierAttribute) == "OKButton" }
    }
    // The Go to Folder box (AXIdentifier "PathTextField") while it is open.
    private func pathField(in root: AXUIElement) throws -> AXUIElement? {
        controls(of: root).first { string($0, kAXIdentifierAttribute) == "PathTextField" }
    }
    private func pressChoose(in picker: AXUIElement) throws {
        let byIdentifier = controls(of: picker).filter { string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXIdentifierAttribute) == "OKButton" }
        let choose = byIdentifier.count == 1 ? byIdentifier[0] : try namedButton(picker, names: ["Choose", "Open"])
        guard (attribute(choose, kAXEnabledAttribute) as? Bool) == true else { throw fail("macOS did not enable Choose for this folder. No exclusion was added.") }
        try press(choose)
    }
}

#if DISK_MONITOR_TESTS
// Test build diagnostic: records how this macOS exposes the Spotlight pane and the
// Search Privacy sheet. It opens the sheet and closes it with Done; no list changes.
extension SpotlightPrivacyAutomation {
    private func describe(_ element: AXUIElement) -> String {
        var fields = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute, kAXValueAttribute, kAXURLAttribute].compactMap { name -> String? in
            guard let value = attribute(element, name) else { return nil }
            let text = (value as? URL)?.absoluteString ?? (value as? String) ?? (CFGetTypeID(value) == CFBooleanGetTypeID() ? "\(value)" : nil)
            return text.map { name + "=" + String($0.prefix(160)).debugDescription }
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String], !names.isEmpty { fields.append("actions=\(names)") }
        return fields.joined(separator: " ")
    }
    private func tree(_ root: AXUIElement, into lines: inout [String], depth: Int = 0) throws {
        try check()
        guard lines.count < 3000, depth < 40 else { return }
        lines.append(String(repeating: "  ", count: depth) + describe(root))
        for child in elements(root) { try tree(child, into: &lines, depth: depth + 1) }
    }
    // Experiment: can the pane be opened and its Search Privacy button found in this presentation?
    func probeReach() throws -> String {
        defer { restore() }
        try openPane()
        process = try wait("System Settings") { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first }
        application = AXUIElementCreateApplication(process!.processIdentifier)
        AXUIElementSetMessagingTimeout(application!, 2)
        guard let window = try? wait("Spotlight settings", timeout: 6, { self.windows().first }) else {
            return "no accessibility window (app hidden=\(process!.isHidden))"
        }
        let buttons: Int = (try? wait("Search Privacy", timeout: 6) { () -> Int? in
            let found = try self.descendants(window).filter { node in
                self.string(node, kAXRoleAttribute) == kAXButtonRole && ["Search Privacy…", "Search Privacy"].contains(self.string(node, kAXDescriptionAttribute))
            }
            return found.isEmpty ? nil : found.count
        }) ?? 0
        return "window=\(string(window, kAXTitleAttribute).debugDescription) searchPrivacyButtons=\(buttons) hidden=\(process!.isHidden) position=\(position(window).map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")"
    }
    // Experiment: enter folders with AXOpen instead of Go to Folder. Hidden folders are not
    // listed by the chooser, so this cannot reach them.
    func walk(to path: String, in picker: AXUIElement) throws {
        var last: String?
        for _ in 0..<16 {
            let nodes = try descendants(picker)
            if nodes.filter({ url($0) == path }).count == 1 { presentationNotes.append("walk reached the folder"); return }
            let ancestors = nodes.compactMap { node -> (AXUIElement, String)? in
                guard let item = url(node), item != path, path.hasPrefix(item == "/" ? "/" : item + "/") else { return nil }
                return (node, item)
            }
            if let best = ancestors.max(by: { $0.1.count < $1.1.count }), best.1 != last {
                if AXUIElementPerformAction(best.0, "AXOpen" as CFString) == .success {
                    presentationNotes.append("walk AXOpen \(best.1)")
                } else {
                    // Column view drills into a folder when it is selected.
                    var node = best.0, selected = false
                    for _ in 0..<8 {
                        guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                        let container = unsafeBitCast(parent, to: AXUIElement.self)
                        let name = string(node, kAXRoleAttribute) == kAXRowRole ? kAXSelectedRowsAttribute : string(container, kAXRoleAttribute) == kAXListRole ? kAXSelectedChildrenAttribute : nil
                        if let name { selected = AXUIElementSetAttributeValue(container, name as CFString, [node] as CFArray) == .success; break }
                        node = container
                    }
                    guard selected else { throw fail("walk: AXOpen and selection both failed at \(best.1)") }
                    presentationNotes.append("walk selected \(best.1) (AXOpen refused)")
                }
                last = best.1; Thread.sleep(forTimeInterval: 0.8); continue
            }
            if last == nil {
                let home = NSHomeDirectory()
                let label = path.hasPrefix(home + "/") ? URL(fileURLWithPath: home).lastPathComponent : FileManager.default.displayName(atPath: "/")
                let cells = nodes.filter { cell in
                    string(cell, kAXRoleAttribute) == kAXCellRole && elements(cell).contains { string($0, kAXRoleAttribute) == kAXStaticTextRole && string($0, kAXValueAttribute) == label }
                }
                guard cells.count == 1, AXUIElementPerformAction(cells[0], "AXOpen" as CFString) == .success else {
                    throw fail("walk: no sidebar entry “\(label)” (found \(cells.count))")
                }
                last = "sidebar:" + label; presentationNotes.append("walk opened sidebar \(label)"); Thread.sleep(forTimeInterval: 0.8); continue
            }
            throw fail("walk: the next folder toward \(path) is not listed in the chooser after \(last ?? "start") (hidden folder?)")
        }
        throw fail("walk: gave up")
    }
    func dump() throws -> [String] {
        guard AXIsProcessTrusted() else { throw fail("Not trusted for Accessibility.") }
        let opened = DispatchQueue.main.sync { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!) }
        guard opened else { throw fail("Could not open Spotlight settings.") }
        process = try wait("System Settings") { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first }
        application = AXUIElementCreateApplication(process!.processIdentifier)
        AXUIElementSetMessagingTimeout(application!, 2)
        let window = try wait("Spotlight settings") { self.windows().first(where: { self.string($0, kAXTitleAttribute) == "Spotlight" }) }
        Thread.sleep(forTimeInterval: 1)
        var lines = ["== windows: " + windows().map { string($0, kAXTitleAttribute).debugDescription }.joined(separator: ", "), "== Spotlight window"]
        try tree(window, into: &lines)
        let candidates = try descendants(window).filter { node in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].contains { string(node, $0).localizedCaseInsensitiveContains("privacy") }
                && string(node, kAXRoleAttribute) == kAXButtonRole
        }
        lines.append("== privacy button candidates: \(candidates.count)")
        guard candidates.count == 1, try sheets(window).isEmpty else { return lines }
        try press(candidates[0]); openedSheet = true
        let sheet: AXUIElement = try wait("Search Privacy dialog") { let found = try self.sheets(window); return found.count == 1 ? found[0] : nil }
        Thread.sleep(forTimeInterval: 1)
        lines.append("== Search Privacy sheet")
        try tree(sheet, into: &lines)
        do { try press(namedButton(sheet, names: ["Done"])); lines.append("== closed with Done") }
        catch { closeOpened(); lines.append("== Done not found; closed what was open") }
        return lines
    }
}
#endif

final class SpotlightExclusionControls: ObservableObject {
    static let shared = SpotlightExclusionControls()
    @Published private(set) var activePath: String?
    @Published private(set) var snapshot: SpotlightPrivacySnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "Refresh to read the current macOS exclusions."
    @Published private(set) var trusted = AXIsProcessTrusted()
    // Exact list from the root scanner; set by the window. Test builds may supply their own.
    var exactList: (() throws -> SpotlightPrivacySnapshot)?
    #if DISK_MONITOR_TESTS
    var usesTestList = false
    #endif
    static func scannerList(_ access: FolderAccess) -> () throws -> SpotlightPrivacySnapshot {
        return {
            precondition(!Thread.isMainThread, "The scanner reply arrives on the main thread")
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<[String], SpotlightPrivacyError>?
            DispatchQueue.main.async { access.readSpotlightExclusions { result = $0; semaphore.signal() } }
            guard semaphore.wait(timeout: .now() + 20) == .success, let result else {
                throw SpotlightPrivacyError.unavailable("The Spotlight scanner did not answer. Exclusion status is unknown.")
            }
            return try SpotlightPrivacySnapshot(rows: try result.get().map { [$0] })
        }
    }
    private var preview = false
    init(previewSnapshot: SpotlightPrivacySnapshot? = nil) {
        if let previewSnapshot { snapshot = previewSnapshot; trusted = true; preview = true; status = "Example exclusions · preview data" }
    }
    private let queue = DispatchQueue(label: "DiskMonitor.SpotlightExclusions")
    private let lock = NSLock()
    private var stopRequested = false
    func cancel() { lock.lock(); stopRequested = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }
    func refreshPermission() { trusted = AXIsProcessTrusted() }
    func invalidate() {
        guard !busy else { return }
        snapshot = nil; error = nil; status = "Refresh to read the current macOS exclusions."
        refreshPermission()
    }
    func report(_ message: String) { error = message }
    #if DISK_MONITOR_TESTS
    // Test build only: changes outside this folder are refused before any Accessibility call.
    var mutationScope: String?
    func permits(_ path: String) -> Bool {
        guard let scope = mutationScope.flatMap(SpotlightPrivacySnapshot.path) else { return true }
        guard let path = SpotlightPrivacySnapshot.path(path) else { return false }
        return path.hasPrefix(scope + "/")
    }
    #endif
    func refresh() { perform() }
    // Reads the exact list each time Settings opens (a root read; no System Settings window).
    func attach(_ model: Model) {
        guard !preview else { return }
        var testList = false
        #if DISK_MONITOR_TESTS
        testList = usesTestList
        #endif
        if !testList { exactList = SpotlightExclusionControls.scannerList(model.folderAccess) }
        refreshPermission()
        if !busy { refresh() }
    }
    // done(true) only after the exact list confirmed the change.
    func set(_ path: String, excluded: Bool, done: ((Bool) -> Void)? = nil) { perform(path: path, excluded: excluded, done: done) }
    private func perform(path: String? = nil, excluded: Bool = false, done: ((Bool) -> Void)? = nil) {
        guard !busy else { done?(false); return }
        #if DISK_MONITOR_TESTS
        if let path, !permits(path) { error = "Test mode only changes the disposable fixture folders."; return }
        #endif
        trusted = AXIsProcessTrusted()
        // Reading the exact list needs no Accessibility; changing it does.
        guard trusted || (path == nil && exactList != nil) else { error = "Allow Disk Monitor in Accessibility, then retry."; return }
        lock.lock(); stopRequested = false; lock.unlock()
        busy = true; error = nil; activePath = path
        status = path.map { excluded ? "Excluding \(URL(fileURLWithPath: $0).lastPathComponent)…" : "Including \(URL(fileURLWithPath: $0).lastPathComponent) in Spotlight…" } ?? "Reading macOS exclusions…"
        queue.async {
            let provider = self.exactList
            let outcome = Result { try SpotlightPrivacyAutomation(cancelled: { self.isCancelled() }, exactList: provider).run(path: path, excluded: excluded) }
            DispatchQueue.main.async {
                self.busy = false; self.activePath = nil
                switch outcome {
                case .success(let value):
                    self.snapshot = value
                    self.status = value == nil ? "Added in Search Privacy. Turn on Spotlight measurement to see exact exclusions."
                        : "Last checked at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                    // Adding needs System Settings active for a few seconds, which closes the popover.
                    if path != nil, !self.isCancelled() {
                        NSApp.activate(ignoringOtherApps: true)
                        NotificationCenter.default.post(name: .diskMonitorReopenPopover, object: nil)
                    }
                case .failure(let failure):
                    self.snapshot = nil; self.status = "Exclusion status is unknown."; self.error = failure.localizedDescription
                    // Keep showing the real state: read the exact list again (no System Settings).
                    if path != nil, let provider {
                        self.queue.async {
                            let current = try? provider()
                            DispatchQueue.main.async { if !self.busy { self.snapshot = current } }
                        }
                    }
                }
                if case .success(let value?) = outcome, let path { done?((value.covering(path) != nil) == excluded) } else { done?(false) }
            }
        }
    }
    #if DISK_MONITOR_TESTS
    static func selfTest() throws {
        let value = try SpotlightPrivacySnapshot(rows: [["Caches", "file:///tmp/example%20cache"], ["/tmp/parent"]])
        precondition(value.covering("/tmp/parent/child") != nil)
        precondition(value.covering("/tmp/parent-other") == nil)
        precondition(value.paths.count == 2)
        let nested = try SpotlightPrivacySnapshot(rows: [["/tmp/parent"], ["/tmp/parent/child"]])
        precondition(nested.covering("/tmp/parent/child") == SpotlightPrivacySnapshot.path("/tmp/parent/child"))
        precondition(nested.ancestor(of: "/tmp/parent/child") == SpotlightPrivacySnapshot.path("/tmp/parent"))
        let added = try SpotlightPrivacySnapshot(rows: [["/tmp/parent"], ["/tmp/example cache"], ["/tmp/new"]])
        precondition(added.matchesChange(from: value, path: "/tmp/new", excluded: true))
        precondition(value.matchesChange(from: added, path: "/tmp/new", excluded: false))
        precondition(!added.matchesChange(from: value, path: "/tmp/wrong", excluded: true))
        let unrelatedRemoved = try SpotlightPrivacySnapshot(rows: [["/tmp/new"]])
        precondition(!unrelatedRemoved.matchesChange(from: value, path: "/tmp/new", excluded: true))
        let empty = try SpotlightPrivacySnapshot(rows: []); precondition(empty.paths.isEmpty)
        precondition(SpotlightPrivacySnapshot.path("/tmp/U\u{0308}ni") == SpotlightPrivacySnapshot.path("/tmp/\u{00DC}ni"), "Decomposed and composed names are the same folder")
        for rows in [[["Caches"]], [["/tmp/a", "/tmp/b"]], [["https://example.com"]]] {
            do { _ = try SpotlightPrivacySnapshot(rows: rows); preconditionFailure("Unknown/ambiguous identities cannot mean unchecked") }
            catch is SpotlightPrivacyError { }
        }
    }
    #endif
}

extension Notification.Name {
    // Applying a change activates System Settings, which closes the popover; reopen it after.
    static let diskMonitorReopenPopover = Notification.Name("DiskMonitorReopenPopover")
}

// Inline in Settings with the same FolderChecklist as "Caches & tools": default folders as
// checkboxes, added folders with Remove. Checked means excluded from Spotlight; the state
// comes from the root scanner's exact list. Added folders are excluded when added.
struct SpotlightExclusionSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var controls: SpotlightExclusionControls
    // Collapsed by default, as before; the exact list is read when the section opens.
    @State private var expanded: Bool
    init(model: Model, controls: SpotlightExclusionControls = .shared, expanded: Bool = false) {
        self.model = model; self.controls = controls; _expanded = State(initialValue: expanded)
    }
    var added: [Root] {
        let defaults = Set(model.spotlightSuggestedCaches.map(\.path))
        return model.spotlightCustomSuggestions.filter { !defaults.contains($0) }
            .map { Root(path: $0, title: URL(fileURLWithPath: $0).lastPathComponent) }
    }
    // Only an explicit exclusion of this folder is undone; one excluded through a parent
    // folder stays excluded and is just dropped from the list.
    func remove(_ path: String) {
        let explicit = controls.snapshot?.covering(path) == SpotlightPrivacySnapshot.path(path) && controls.snapshot?.ancestor(of: path) == nil
        guard explicit, controls.trusted else { model.removeSpotlightSuggestion(path); return }
        controls.set(path, excluded: false) { ok in if ok { model.removeSpotlightSuggestion(path) } }
    }
    var notice: String? {
        if let error = controls.error { return error }
        if controls.snapshot == nil { return controls.busy ? "Reading Spotlight exclusions…" : "Spotlight exclusions are unknown." }
        if !controls.trusted { return "Allow Disk Monitor to change Spotlight settings." }
        return nil
    }
    var body: some View {
        DisclosureGroup("Spotlight exclusions", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                FolderChecklist(
                    defaults: model.spotlightSuggestedCaches,
                    isOn: { controls.snapshot?.covering($0.path) != nil }, setOn: { controls.set($0.path, excluded: $1) },
                    disabled: { controls.snapshot == nil || controls.busy || !controls.trusted || controls.snapshot?.ancestor(of: $0.path) != nil },
                    added: added, remove: { remove($0.path) }, removeDisabled: controls.busy || controls.snapshot == nil,
                    caption: "Checked folders are hidden from Spotlight search; sizes are still measured. Changing one briefly opens System Settings to apply it.",
                    notice: notice, noticeAction: controls.trusted ? nil : ("Allow…", { controls.requestAccess() }),
                    addTitle: "Add folders…", addDisabled: controls.busy || controls.snapshot == nil || !controls.trusted, add: chooseFolder)
            }
            .padding(.top, 6)
            .onAppear { controls.attach(model) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controls.refreshPermission() }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Exclude from Spotlight"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SpotlightSuggestions.normalized(url.path, indexPath: model.spotlightPath) != nil else {
            controls.report("The Spotlight index cannot be excluded here."); return
        }
        model.addSpotlightSuggestions([url]); controls.set(url.path, excluded: true)
    }
}
