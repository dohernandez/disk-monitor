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
        return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
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
    private let cancelled: () -> Bool
    init(cancelled: @escaping () -> Bool = { false }) { self.cancelled = cancelled }
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
    private func wait<T>(_ description: String, _ find: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(8)
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
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try foreground()
        guard let process, let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw fail("Could not send the folder-selection command.") }
        down.flags = flags; up.flags = flags
        down.postToPid(process.processIdentifier); up.postToPid(process.processIdentifier)
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
            let named = nodes.filter {
                self.string($0, kAXRoleAttribute) == kAXButtonRole &&
                ["Search Privacy", "Search Privacy…", "Spotlight Privacy", "Spotlight Privacy…"].contains(self.string($0, kAXTitleAttribute))
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
        try press(button)
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
    func run(path: String? = nil, excluded: Bool = false) throws -> SpotlightPrivacySnapshot {
        let sheet = try privacySheet()
        let before = try snapshot(sheet)
        guard let requested = path, let path = SpotlightPrivacySnapshot.path(requested) else {
            try press(namedButton(sheet, names: ["Done"])); return before
        }
        let covering = before.covering(path)
        if excluded && covering != nil || !excluded && covering == nil {
            try press(namedButton(sheet, names: ["Done"])); return before
        }
        if !excluded {
            guard before.ancestor(of: path) == nil, covering == path else {
                throw fail("This folder is excluded through a parent folder. Change the parent exclusion first.")
            }
            let matches = try rows(sheet).filter { try SpotlightPrivacySnapshot(rows: [rowIdentity($0)]).paths.contains(path) }
            guard matches.count == 1 else { throw fail("Could not identify the exact folder to remove. No changes were made.") }
            try foreground()
            let list = try exclusionList(sheet)
            guard AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [matches[0]] as CFArray) == .success,
                  let selected = attribute(list, kAXSelectedRowsAttribute) as? [AXUIElement],
                  selected.count == 1, CFEqual(selected[0], matches[0]) else {
                throw fail("macOS could not select only the requested folder. No exclusions were removed.")
            }
            try press(namedButton(sheet, names: ["Remove", "Remove selected item", "Remove selected items", "−", "-"]))
        } else {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw fail("The folder no longer exists.") }
            try press(namedButton(sheet, names: ["Add", "Add a folder", "Add item", "+"]))
            let picker = try wait("folder chooser") {
                let children = try self.sheets(sheet)
                return children.count == 1 ? children[0] : nil
            }
            try key(5, flags: [.maskCommand, .maskShift])
            let field: AXUIElement = try wait("Go to Folder") {
                guard let app = self.application, let focused = self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
                let element = unsafeBitCast(focused, to: AXUIElement.self)
                let dialogs = try self.sheets(picker)
                guard dialogs.count == 1, try self.descendants(dialogs[0]).contains(where: { CFEqual($0, element) }) else { return nil }
                return self.string(element, kAXRoleAttribute) == kAXTextFieldRole || self.string(element, kAXRoleAttribute) == kAXComboBoxRole ? element : nil
            }
            try foreground()
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFString) == .success else { throw fail("Could not enter the folder path.") }
            try key(36)
            let choose: AXUIElement = try wait("folder confirmation") {
                guard try self.sheets(picker).isEmpty else { return nil }
                guard let button = self.attribute(picker, kAXDefaultButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return nil }
                let element = unsafeBitCast(button, to: AXUIElement.self)
                return (self.attribute(element, kAXEnabledAttribute) as? Bool) == true ? element : nil
            }
            let selectedRows = try descendants(picker).filter {
                (attribute($0, kAXSelectedAttribute) as? Bool) == true
            }
            let chosenPaths: Set<String>
            if !selectedRows.isEmpty {
                chosenPaths = try SpotlightPrivacySnapshot(rows: selectedRows.map { try rowIdentity($0) }).paths
            } else { throw fail("macOS did not expose the selected folder's full path. No exclusion was added.") }
            guard chosenPaths == [path] else { throw fail("The selected folder does not match the requested path. No exclusion was added.") }
            try press(choose)
        }
        let after: SpotlightPrivacySnapshot = try wait("macOS to confirm the exclusion change") {
            guard try self.sheets(sheet).isEmpty else { return nil }
            let value = try self.snapshot(sheet)
            return value.matchesChange(from: before, path: path, excluded: excluded) ? value : nil
        }
        try press(namedButton(sheet, names: ["Done"]))
        let reopened = try privacySheet()
        let verified = try snapshot(reopened)
        try press(namedButton(reopened, names: ["Done"]))
        guard verified.paths == after.paths else { throw fail("macOS did not retain the expected exclusion change. Refresh and retry.") }
        return verified
    }
}

final class SpotlightExclusionControls: ObservableObject {
    @Published private(set) var snapshot: SpotlightPrivacySnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var status = "Refresh to read the current macOS exclusions."
    @Published private(set) var trusted = AXIsProcessTrusted()
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
        guard trusted else { error = "Allow Disk Monitor in Accessibility, then retry."; return }
        lock.lock(); stopRequested = false; lock.unlock()
        busy = true; error = nil
        status = path.map { excluded ? "Excluding \(URL(fileURLWithPath: $0).lastPathComponent)…" : "Including \(URL(fileURLWithPath: $0).lastPathComponent) in Spotlight…" } ?? "Reading macOS exclusions…"
        queue.async {
            let outcome = Result { try SpotlightPrivacyAutomation(cancelled: { self.isCancelled() }).run(path: path, excluded: excluded) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .success(let value):
                    self.snapshot = value; self.status = "Last checked at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
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
                            } else { Label(root.title + " · Unknown", systemImage: "questionmark.square").foregroundStyle(Palette.secondary) }
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
            }.disabled(controls.busy || controls.snapshot == nil)
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
            editor.show(model: environment.model)
            editor.window?.title = "Disk Monitor — Spotlight exclusions (test mode)"
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
    static var resultsURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DiskMonitor-exclusion-results.log") }
    private static let stop = NSLock()
    private static var stopping = false
    private static func stopped() -> Bool { stop.lock(); defer { stop.unlock() }; return stopping }
    static func runScenarios(root: String, log url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try? FileHandle(forWritingTo: url)
        defer { try? handle?.close() }
        func write(_ line: String) { handle?.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)); print(line) }
        let info = ProcessInfo.processInfo.operatingSystemVersionString
        write("START macOS \(info) locale \(Locale.current.identifier) trusted=\(AXIsProcessTrusted()) root=\(root)")
        func automation() -> SpotlightPrivacyAutomation { SpotlightPrivacyAutomation(cancelled: stopped) }
        func fixture(_ name: String) -> String { root + "/" + name }
        guard AXIsProcessTrusted() else {
            do { _ = try automation().run(); write("FAIL denied: read succeeded without Accessibility") }
            catch { write("PASS denied: \(error.localizedDescription)") }
            write("END denied-only"); return
        }
        var initial: SpotlightPrivacySnapshot
        do { initial = try automation().run(); write("PASS read: \(initial.paths.count) existing exclusions") }
        catch { write("FAIL read: \(error.localizedDescription)"); write("END"); return }
        guard initial.paths.allSatisfy({ !$0.hasPrefix(root + "/") }) else {
            write("FAIL precondition: fixtures already excluded; remove them first"); write("END"); return
        }
        var current = initial, failures = 0
        func step(_ name: String, _ path: String, excluded: Bool, blocked: Bool = false, check: (SpotlightPrivacySnapshot) -> Bool = { _ in true }) {
            guard failures == 0, !stopped() else { return }
            guard path.hasPrefix(root + "/") else { failures += 1; write("FAIL \(name): outside fixtures"); return }
            do {
                let value = try automation().run(path: path, excluded: excluded)
                let ok = !blocked && (value.covering(path) != nil) == excluded && check(value)
                write((ok ? "PASS " : "FAIL ") + name + ": \(value.paths.subtracting(initial.paths).sorted())")
                if !ok { failures += 1 }; current = value
            } catch {
                write((blocked ? "PASS " : "FAIL ") + name + ": " + error.localizedDescription)
                if !blocked { failures += 1 }
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
            var final = try automation().run()
            for path in final.paths.filter({ $0.hasPrefix(root + "/") }).sorted(by: { $0.count > $1.count }) where !stopped() {
                do { final = try automation().run(path: path, excluded: false); write("CLEANUP removed \(path)") }
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
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
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
