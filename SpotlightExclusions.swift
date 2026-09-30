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
    // Test mode diagnostic: the chooser's accessibility tree when finding the folder failed.
    private(set) var failureTree: [String] = []
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
    // Test mode: close dialogs left open in an already running System Settings.
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
        } } catch { var lines: [String] = []; try? tree(picker, into: &lines); failureTree = lines; throw error }
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

// Test mode diagnostic: records how this macOS exposes the Spotlight pane and the
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

final class SpotlightExclusionControls: ObservableObject {
    @Published private(set) var snapshot: SpotlightPrivacySnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "Refresh to read the current macOS exclusions."
    @Published private(set) var trusted = AXIsProcessTrusted()
    // Exact list from the root scanner; set by the window. Tests may supply their own.
    var exactList: (() throws -> SpotlightPrivacySnapshot)?
    var usesTestList = false
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
    // Test mode only: changes outside this folder are refused before any Accessibility call.
    var mutationScope: String?
    func permits(_ path: String) -> Bool {
        guard let scope = mutationScope.flatMap(SpotlightPrivacySnapshot.path) else { return true }
        guard let path = SpotlightPrivacySnapshot.path(path) else { return false }
        return path.hasPrefix(scope + "/")
    }
    func refresh() { perform() }
    func set(_ path: String, excluded: Bool) { perform(path: path, excluded: excluded) }
    private func perform(path: String? = nil, excluded: Bool = false) {
        guard !busy else { return }
        if let path, !permits(path) { error = "Test mode only changes the disposable fixture folders."; return }
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
        if !controls.usesTestList { controls.exactList = SpotlightExclusionControls.scannerList(model.folderAccess) }
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

// Development-only live validation (docs/SPOTLIGHT-AUTOMATION.md). Opens only the
// exclusion window with isolated preferences and readings: no status item, updater,
// scanner registration, scans or timers. Mutations are limited to disposable fixtures.
enum SpotlightExclusionHarness {
    static let flag = "--spotlight-exclusion-test"
    static let fixtures = ["duplicate-a/Cache", "duplicate-b/Cache", "folder with spaces", "Ünïcødé 文件夹", "excluded-parent", "excluded-parent/child"]
    static func requested(_ arguments: [String]) -> Bool { arguments.contains(flag) }
    static var defaultRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-exclusion-fixtures") }
    struct Environment {
        let root: String
        let suite: String
        let state: URL
        let model: Model
        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: state)
        }
    }
    // Fixture folders are kept between runs: a leftover exclusion can be removed next time.
    static func prepare(root: URL) throws -> Environment {
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType, type != .typeDirectory {
            throw SpotlightPrivacyError.unavailable("The fixture location is not a plain folder: \(root.path)")
        }
        for name in fixtures {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw SpotlightPrivacyError.unavailable("A fixture is not a plain folder: \(url.path)")
            }
        }
        guard let resolved = SpotlightPrivacySnapshot.path(root.path) else { throw SpotlightPrivacyError.unavailable("Invalid fixture location.") }
        let suite = "local.darien.diskmonitor.exclusion-test." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { throw SpotlightPrivacyError.unavailable("Could not create test preferences.") }
        // Only this unique suite is written; cleanup removes it. Registered defaults would leak process-wide.
        preferences.set(fixtures.map { resolved + "/" + $0 }, forKey: SpotlightSuggestions.preferenceKey)
        let state = fm.temporaryDirectory.appendingPathComponent("DiskMonitor-exclusion-state-" + UUID().uuidString)
        let model = Model(nixStorePath: state.appendingPathComponent("missing-nix").path, home: state.path, preferences: preferences,
                          saveURL: state.appendingPathComponent("readings.json"), spotlightPath: state.appendingPathComponent("missing-index").path)
        model.timer?.invalidate(); model.folderTimer?.invalidate(); model.timer = nil; model.folderTimer = nil
        return Environment(root: resolved, suite: suite, state: state, model: model)
    }
    final class Delegate: NSObject, NSApplicationDelegate {
        let environment: Environment
        init(_ environment: Environment) { self.environment = environment }
        func applicationDidFinishLaunching(_ notification: Notification) {
            let editor = SpotlightExclusionWindow.shared
            editor.controls.mutationScope = environment.root
            editor.controls.usesTestList = true; editor.controls.exactList = SpotlightExclusionHarness.sudoList
            editor.show(model: environment.model)
            editor.window?.title = "Disk Monitor — Spotlight exclusions (test mode)"
            if CommandLine.arguments.contains(closeFlag) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let notes = SpotlightPrivacyAutomation(cancelled: stopped).closeLeftovers()
                    FileManager.default.createFile(atPath: resultsURL.path, contents: Data(("CLOSE " + notes.joined(separator: "; ") + "\n").utf8), attributes: [.posixPermissions: 0o600])
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                return
            }
            if CommandLine.arguments.contains(dumpFlag) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let lines: [String]
                    do { lines = try SpotlightPrivacyAutomation(cancelled: stopped).dump() } catch { lines = ["FAIL dump: " + error.localizedDescription] }
                    FileManager.default.createFile(atPath: dumpURL.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600])
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                return
            }
            guard CommandLine.arguments.contains(scenarioFlag) else { return }
            let root = environment.root
            DispatchQueue.global(qos: .userInitiated).async {
                runScenarios(root: root, log: resultsURL)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationWillTerminate(_ notification: Notification) {
            stop.lock(); stopping = true; stop.unlock()
            SpotlightExclusionWindow.shared.controls.cancel(); environment.cleanup()
        }
    }
    // Headless live run: each step goes through the same verified automation as the
    // window. Only fixture paths are touched; any fixture left excluded is removed at the end.
    static let scenarioFlag = "--run-scenarios"
    static let dumpFlag = "--dump-accessibility"
    static let closeFlag = "--close-dialogs"
    static var dumpURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-exclusion-accessibility.txt") }
    static var resultsURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-exclusion-results.log") }
    private static let stop = NSLock()
    private static var stopping = false
    private static func stopped() -> Bool { stop.lock(); defer { stop.unlock() }; return stopping }
    // Test-only exact list: the same file the root scanner reads, via non-interactive sudo
    // (the test VM's admin has it). The scanner's own reader is covered by its fixtures.
    static func sudoList() throws -> SpotlightPrivacySnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/bin/cat", "/System/Volumes/Data/.Spotlight-V100/VolumeConfiguration.plist"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 1 << 20,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SpotlightPrivacyError.unavailable("Test exclusion list could not be read (sudo -n).")
        }
        guard let value = plist["Exclusions"] else { return try SpotlightPrivacySnapshot(rows: []) }
        guard let paths = value as? [String] else { throw SpotlightPrivacyError.unavailable("Unexpected exclusion list format.") }
        return try SpotlightPrivacySnapshot(rows: paths.map { [$0] })
    }
    static func runScenarios(root: String, log url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try? FileHandle(forWritingTo: url)
        defer { try? handle?.close() }
        func write(_ line: String) { handle?.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)); print(line) }
        let info = ProcessInfo.processInfo.operatingSystemVersionString
        write("START macOS \(info) locale \(Locale.current.identifier) trusted=\(AXIsProcessTrusted()) root=\(root)")
        func automation() -> SpotlightPrivacyAutomation { SpotlightPrivacyAutomation(cancelled: stopped, exactList: sudoList) }
        func fixture(_ name: String) -> String { root + "/" + name }
        guard AXIsProcessTrusted() else {
            do { _ = try automation().run(path: fixture("folder with spaces"), excluded: true); write("FAIL denied: change attempted without Accessibility") }
            catch { write("PASS denied: \(error.localizedDescription)") }
            write("END denied-only"); return
        }
        var initial: SpotlightPrivacySnapshot
        do {
            guard let value = try automation().run() else { write("FAIL read: exact list unavailable"); write("END"); return }
            initial = value; write("PASS read: \(initial.paths.count) existing exclusions")
        }
        catch { write("FAIL read: \(error.localizedDescription)"); write("END"); return }
        guard initial.paths.allSatisfy({ !$0.hasPrefix(root + "/") }) else {
            write("FAIL precondition: fixtures already excluded; remove them first"); write("END"); return
        }
        var current = initial, failures = 0
        func step(_ name: String, _ path: String, excluded: Bool, blocked: Bool = false, check: (SpotlightPrivacySnapshot) -> Bool = { _ in true }) {
            guard failures == 0, !stopped() else { return }
            guard path.hasPrefix(root + "/") else { failures += 1; write("FAIL \(name): outside fixtures"); return }
            let operation = automation()
            do {
                guard let value = try operation.run(path: path, excluded: excluded) else { failures += 1; write("FAIL " + name + ": exact list unavailable"); return }
                let ok = !blocked && (value.covering(path) != nil) == excluded && check(value)
                write((ok ? "PASS " : "FAIL ") + name + ": \(value.paths.subtracting(initial.paths).sorted())")
                if !ok { failures += 1 }; current = value
            } catch {
                write((blocked ? "PASS " : "FAIL ") + name + ": " + error.localizedDescription
                      + (operation.cleanupNotes.isEmpty ? "" : " [cleanup: " + operation.cleanupNotes.joined(separator: "; ") + "]"))
                if !blocked { failures += 1 }
                if !operation.failureTree.isEmpty { write("CHOOSER TREE AT FAILURE:\n" + operation.failureTree.joined(separator: "\n")) }
            }
        }
        let spaces = fixture("folder with spaces"), a = fixture("duplicate-a/Cache"), b = fixture("duplicate-b/Cache")
        let unicode = fixture("Ünïcødé 文件夹"), parent = fixture("excluded-parent"), child = fixture("excluded-parent/child")
        step("add spaces", spaces, excluded: true)
        step("add duplicate-a/Cache only", a, excluded: true) { $0.covering(b) == nil }
        step("remove duplicate-a/Cache", a, excluded: false) { $0.covering(b) == nil }
        step("add unicode", unicode, excluded: true)
        step("remove unicode", unicode, excluded: false)
        step("add parent", parent, excluded: true)
        let beforeChild = current.paths
        step("child already covered: no change", child, excluded: true) { $0.paths == beforeChild }
        step("remove child blocked by parent", child, excluded: false, blocked: true)
        step("remove parent", parent, excluded: false)
        step("remove spaces", spaces, excluded: false)
        // Restore: remove only fixture entries that are still excluded, whatever failed above.
        do {
            guard var final = try automation().run() else { throw SpotlightPrivacyError.unavailable("exact list unavailable") }
            for path in final.paths.filter({ $0.hasPrefix(root + "/") }).sorted(by: { $0.count > $1.count }) where !stopped() {
                do { final = try automation().run(path: path, excluded: false) ?? final; write("CLEANUP removed \(path)") }
                catch { write("CLEANUP FAILED \(path): \(error.localizedDescription)") }
            }
            let restored = final.paths == initial.paths
            write((restored ? "PASS" : "FAIL") + " final list equals initial list")
            if !restored { failures += 1 }
        } catch { write("FAIL final read: \(error.localizedDescription)"); failures += 1 }
        write("END failures=\(failures)")
    }
    static func run() -> Never {
        let app = NSApplication.shared
        let environment: Environment
        do { environment = try prepare(root: defaultRoot) }
        catch { fputs("Spotlight exclusion test setup failed: \(error.localizedDescription)\n", stderr); exit(1) }
        print("Spotlight exclusion test mode. Fixtures: \(environment.root)")
        let delegate = Delegate(environment)
        app.delegate = delegate
        // `kill -TERM <pid>` quits through the delegate so isolated state is cleaned up.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        app.setActivationPolicy(.regular)
        withExtendedLifetime((delegate, termination)) { app.run() }
        exit(0)
    }
    static func selfTest() throws {
        precondition(requested(["DiskMonitor", flag]) && !requested(["DiskMonitor", "--show"]))
        let deniedLog = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-harness-log-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: deniedLog) }
        if !AXIsProcessTrusted() {
            runScenarios(root: "/nonexistent-fixtures", log: deniedLog)
            let text = (try? String(contentsOf: deniedLog, encoding: .utf8)) ?? ""
            precondition(text.contains("PASS denied") && !text.contains("FAIL"), "Without Accessibility the run stops before any change")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-harness-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try prepare(root: root)
        defer { environment.cleanup() }
        let model = environment.model
        precondition(model.timer == nil && model.folderTimer == nil && !model.scanning, "Test mode must not schedule refreshes or scans")
        precondition(model.trackedRoots.isEmpty, "Test mode must not track real folders")
        precondition(model.saveURL.path.hasPrefix(environment.state.path) && !FileManager.default.fileExists(atPath: model.saveURL.path))
        precondition(model.preferences !== UserDefaults.standard && environment.suite != Bundle.main.bundleIdentifier)
        precondition(model.spotlightCustomSuggestions == fixtures.map { environment.root + "/" + $0 })
        precondition(UserDefaults.standard.stringArray(forKey: SpotlightSuggestions.preferenceKey) != model.spotlightCustomSuggestions, "Fixtures stay out of the app's own preferences")
        let controls = SpotlightExclusionControls()
        controls.mutationScope = environment.root
        precondition(controls.permits(environment.root + "/folder with spaces") && controls.permits(environment.root + "/excluded-parent/child"))
        precondition(!controls.permits(environment.root) && !controls.permits(environment.root + "-other") && !controls.permits("/tmp") && !controls.permits(environment.root + "/../x"))
        controls.set("/tmp", excluded: true)
        precondition(!controls.busy && controls.error != nil, "Out-of-scope changes are refused before automation")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: FileManager.default.temporaryDirectory)
        do { _ = try prepare(root: root); preconditionFailure("A linked fixture location must be refused") } catch is SpotlightPrivacyError { }
        environment.cleanup()
        precondition(UserDefaults.standard.persistentDomain(forName: environment.suite) == nil && !FileManager.default.fileExists(atPath: environment.state.path), "Cleanup removes isolated state")
    }
}
