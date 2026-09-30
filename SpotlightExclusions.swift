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
        throw fail("Timed out waiting for \(description). Refresh to check the current exclusions.")
    }
    private func foreground() throws {
        try check()
        guard let process, NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier else {
            throw fail("System Settings lost focus. Refresh to check the current exclusions before retrying.")
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
        try foreground()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw fail("Could not send the folder-selection command.") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
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
        let opened = DispatchQueue.main.sync {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
        }
        guard opened else { throw fail("Could not open Spotlight settings.") }
        process = try wait("System Settings") {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
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
    #endif
    private func closeOpened() {
        guard openedSheet else { return }
        closeSheets()
    }
    // Innermost first: Cancel a chooser, then Done on Search Privacy. Only while Settings is frontmost.
    func closeSheets() {
        for _ in 0..<3 {
            guard let window = windows().first, let open = try? sheets(window), let innermost = open.last else {
                cleanupNotes.append("no open dialogs"); return
            }
            let nested = (try? sheets(innermost)) ?? []
            guard nested.isEmpty else { cleanupNotes.append("unexpected nested dialog"); return }
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
        let sheet = try privacySheet()
        if excluded { try addFolder(path, in: sheet) } else { try removeRow(named: name, in: sheet) }
        // macOS saves the list asynchronously; the root read is the persisted state.
        let after: SpotlightPrivacySnapshot = try wait("macOS to save the exclusion change", timeout: 20) {
            guard try self.sheets(sheet).isEmpty else { return nil }
            let value = try exactList()
            return value.matchesChange(from: before, path: path, excluded: excluded) ? value : nil
        }
        try press(namedButton(sheet, names: ["Done"]))
        return after
    }
    // Fallback without the root list: add only, verified by the new row's name. Status stays unknown.
    private func addByName(_ requested: String?, excluded: Bool) throws -> SpotlightPrivacySnapshot? {
        guard excluded, let requested, let path = SpotlightPrivacySnapshot.path(requested) else {
            throw fail("Exact exclusions need Spotlight measurement turned on. Folders can still be added.")
        }
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
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try key(5, flags: [.maskCommand, .maskShift])
        let field: AXUIElement = try wait("Go to Folder") {
            let fields = try self.descendants(picker).filter {
                [kAXTextFieldRole, kAXComboBoxRole].contains(self.string($0, kAXRoleAttribute))
                    && self.string($0, kAXSubroleAttribute) != kAXSearchFieldSubrole
                    && (self.attribute($0, kAXFocusedAttribute) as? Bool) == true
            }
            return fields.count == 1 ? fields[0] : nil
        }
        try foreground()
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, parent as CFString) == .success,
              string(field, kAXValueAttribute) == parent else { throw fail("Could not enter the folder path. No exclusion was added.") }
        try key(36)
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
        let byIdentifier = try descendants(picker).filter { string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXIdentifierAttribute) == "OKButton" }
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
    init(previewSnapshot: SpotlightPrivacySnapshot? = nil) {
        if let previewSnapshot { snapshot = previewSnapshot; trusted = true; status = "Example exclusions · preview data" }
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
    func set(_ path: String, excluded: Bool) { perform(path: path, excluded: excluded) }
    private func perform(path: String? = nil, excluded: Bool = false) {
        guard !busy else { return }
        #if DISK_MONITOR_TESTS
        if let path, !permits(path) { error = "Test mode only changes the disposable fixture folders."; return }
        #endif
        trusted = AXIsProcessTrusted()
        // Reading the exact list needs no Accessibility; changing it does.
        guard trusted || (path == nil && exactList != nil) else { error = "Allow Disk Monitor in Accessibility, then retry."; return }
        lock.lock(); stopRequested = false; lock.unlock()
        busy = true; error = nil
        status = path.map { excluded ? "Excluding \(URL(fileURLWithPath: $0).lastPathComponent)…" : "Including \(URL(fileURLWithPath: $0).lastPathComponent) in Spotlight…" } ?? "Reading macOS exclusions…"
        queue.async {
            let provider = self.exactList
            let outcome = Result { try SpotlightPrivacyAutomation(cancelled: { self.isCancelled() }, exactList: provider).run(path: path, excluded: excluded) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .success(let value):
                    self.snapshot = value
                    self.status = value == nil ? "Added in Search Privacy. Turn on Spotlight measurement to see exact exclusions."
                        : "Last checked at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                    if !self.isCancelled(), NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                        SpotlightExclusionWindow.shared.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
                    }
                case .failure(let failure):
                    self.snapshot = nil; self.status = "Exclusion status is unknown."; self.error = failure.localizedDescription
                }
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

final class SpotlightExclusionWindow: NSWindowController, NSWindowDelegate {
    static let shared = SpotlightExclusionWindow()
    let controls = SpotlightExclusionControls()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Disk Monitor — Spotlight exclusions"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 400)
        super.init(window: window); window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(model: Model) {
        if window?.isVisible != true { controls.invalidate() }
        var testList = false
        #if DISK_MONITOR_TESTS
        testList = controls.usesTestList
        #endif
        if !testList { controls.exactList = SpotlightExclusionControls.scannerList(model.folderAccess) }
        window?.contentView = NSHostingView(rootView: SpotlightExclusionEditor(model: model, controls: controls))
        if window?.isVisible != true { window?.center() }
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { controls.cancel() }
}
struct SpotlightExclusionEditor: View {
    @ObservedObject var model: Model
    @ObservedObject var controls: SpotlightExclusionControls
    var folders: [Root] {
        var seen = Set<String>()
        let other = (controls.snapshot?.paths.sorted() ?? []).map { Root(path: $0, title: URL(fileURLWithPath: $0).lastPathComponent) }
        return (model.spotlightSuggestedCaches + model.spotlightCustomSuggestions.map { Root(path: $0, title: URL(fileURLWithPath: $0).lastPathComponent) } + other)
            .filter { seen.insert($0.path).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exclude folders from Spotlight").font(.title2.bold())
            Text("Checked folders are excluded from Spotlight search. Disk Monitor continues measuring them.")
            Text("Changes open and control macOS Search Privacy. Keep System Settings in front while an operation runs.").font(.callout).foregroundStyle(Palette.secondary)
            if !controls.trusted { Text("Allow Disk Monitor to operate Spotlight’s Search Privacy controls.").font(.callout) }
            HStack {
                if !controls.trusted { Button("Allow Accessibility…") { controls.requestAccess() } }
                Button("Refresh exclusions") { controls.refresh() }.disabled(controls.busy)
                if controls.busy { ProgressView().controlSize(.small); Button("Stop") { controls.cancel() } }
            }
            Text(controls.status).font(.callout).foregroundStyle(Palette.secondary)
            if let error = controls.error { Text(error).foregroundStyle(Palette.uncertainty).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(folders) { root in
                        let covering = controls.snapshot?.covering(root.path)
                        let ancestor = controls.snapshot?.ancestor(of: root.path)
                        VStack(alignment: .leading, spacing: 3) {
                            if controls.snapshot != nil {
                                Toggle(root.title, isOn: Binding(get: { covering != nil }, set: { controls.set(root.path, excluded: $0) }))
                                    .toggleStyle(.checkbox).disabled(controls.busy || ancestor != nil)
                            } else {
                                HStack {
                                    Label(root.title + " · Unknown", systemImage: "questionmark.square").foregroundStyle(Palette.secondary)
                                    Button("Exclude") { controls.set(root.path, excluded: true) }.disabled(controls.busy || !controls.trusted)
                                }
                            }
                            Text(root.path).font(.caption).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            if let ancestor { Text("Excluded through \(ancestor). Change the parent exclusion to include this folder.").font(.caption).foregroundStyle(Palette.secondary) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Exclude another folder…") {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.prompt = "Exclude from Spotlight"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard SpotlightSuggestions.normalized(url.path, indexPath: model.spotlightPath) != nil else {
                    controls.report("The Spotlight index cannot be added here."); return
                }
                model.addSpotlightSuggestions([url]); controls.set(url.path, excluded: true)
            }.disabled(controls.busy || !controls.trusted)
        }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controls.refreshPermission() }
        .padding(20).frame(minWidth: 440, minHeight: 360).foregroundStyle(Palette.primary).background(Palette.background)
    }
}
