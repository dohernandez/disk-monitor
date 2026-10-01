// Spotlight exclusion test mode. Compiled only into test builds (task build:app -- --test,
// -D DISK_MONITOR_TESTS); release builds contain none of this code.
#if DISK_MONITOR_TESTS
import Cocoa
import ApplicationServices
import SwiftUI

// Development-only live validation (docs/SPOTLIGHT-AUTOMATION.md). Opens only the
// exclusion window with isolated preferences and readings: no status item, updater,
// scanner registration, scans or timers. Mutations are limited to disposable fixtures.
enum SpotlightExclusionHarness {
    static let flag = "--spotlight-exclusion-test"
    static let fixtures = ["duplicate-a/Cache", "duplicate-b/Cache", "folder with spaces", "Ünïcødé 文件夹", "excluded-parent", "excluded-parent/child", ".hidden-cache"]
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
        var testWindow: NSWindow?
        init(_ environment: Environment) { self.environment = environment }
        func applicationDidFinishLaunching(_ notification: Notification) {
            // The same inline Settings section the app shows, hosted in a test-only window.
            let controls = SpotlightExclusionControls.shared
            controls.mutationScope = environment.root
            controls.usesTestList = true; controls.exactList = SpotlightExclusionHarness.sudoList
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disk Monitor — Spotlight exclusions (test mode)"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SpotlightExclusionSettings(model: environment.model, controls: controls, expanded: true)
                .padding(16).font(.system(size: 11)).foregroundStyle(Palette.primary).background(Palette.background))
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            testWindow = window
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
            if CommandLine.arguments.contains(probeFlag) {
                let root = environment.root
                DispatchQueue.global(qos: .userInitiated).async {
                    runProbe(root: root, log: resultsURL)
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
            SpotlightExclusionControls.shared.cancel(); environment.cleanup()
        }
    }
    // Headless live run: each step goes through the same verified automation as the
    // window. Only fixture paths are touched; any fixture left excluded is removed at the end.
    static let scenarioFlag = "--run-scenarios"
    static let dumpFlag = "--dump-accessibility"
    static let closeFlag = "--close-dialogs"
    // Experiment: which presentations apply a change without showing System Settings.
    static let probeFlag = "--background-probe"
    // `--presentation foreground|background|hidden|brief` for --run-scenarios (default: brief, as in the app).
    static let presentationFlag = "--presentation"
    static var presentation: SpotlightPrivacyAutomation.Presentation {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: presentationFlag), index + 1 < arguments.count,
              let value = SpotlightPrivacyAutomation.Presentation(rawValue: arguments[index + 1]) else { return .brief }
        return value
    }
    static let settingsID = "com.apple.systempreferences"
    // Samples, every 30 ms, whether System Settings is the active app and whether one of its
    // windows (or the folder chooser service's) is on screen and inside a display.
    final class Visibility {
        private let lock = NSLock()
        private var running = true
        private(set) var frontmost = 0.0, listed = 0.0, visible = 0.0, area = 0.0
        private var owners = Set<String>()
        static func sample() -> (frontmost: Bool, listed: Bool, visible: Bool, owners: [String], area: Double) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == settingsID
            let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let mine = all.filter { window in
                let owner = window[kCGWindowOwnerName as String] as? String ?? ""
                return (window[kCGWindowLayer as String] as? Int) == 0 && (owner == "System Settings" || owner.contains("Open and Save Panel"))
            }
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            let screens = displays.map { CGDisplayBounds($0) }
            var area = 0.0
            for window in mine {
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                      (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
                for screen in screens { let shared = screen.intersection(rect); if !shared.isNull { area = max(area, Double(shared.width * shared.height)) } }
            }
            return (front, !mine.isEmpty, area > 0, mine.compactMap { $0[kCGWindowOwnerName as String] as? String }, area)
        }
        func start() {
            Thread.detachNewThread {
                var last = Date()
                while true {
                    Thread.sleep(forTimeInterval: 0.03)
                    self.lock.lock(); let active = self.running; self.lock.unlock()
                    guard active else { return }
                    let now = Date(), elapsed = now.timeIntervalSince(last); last = now
                    let state = Visibility.sample()
                    self.lock.lock()
                    if state.frontmost { self.frontmost += elapsed }
                    if state.listed { self.listed += elapsed }
                    if state.visible { self.visible += elapsed }
                    self.area = max(self.area, state.area)
                    self.owners.formUnion(state.owners)
                    self.lock.unlock()
                }
            }
        }
        func stop() -> String {
            lock.lock(); running = false; defer { lock.unlock() }
            return String(format: "settingsFrontmost=%.2fs windowListed=%.2fs windowVisible=%.2fs maxVisibleArea=%.0fpx2 owners=%@", frontmost, listed, visible, area, owners.sorted().description)
        }
    }
    static func settingsApp() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).first }
    static func quitSettings() {
        guard let app = settingsApp() else { return }
        app.terminate()
        for _ in 0..<50 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
        if !app.isTerminated { app.forceTerminate(); Thread.sleep(forTimeInterval: 0.5) }
    }
    static func runProbe(root: String, log url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try? FileHandle(forWritingTo: url)
        defer { try? handle?.close() }
        func write(_ line: String) { handle?.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)); print(line) }
        write("START probe macOS \(ProcessInfo.processInfo.operatingSystemVersionString) trusted=\(AXIsProcessTrusted()) root=\(root)")
        guard AXIsProcessTrusted() else { write("END not trusted"); return }
        typealias Mode = SpotlightPrivacyAutomation.Presentation
        func automation(_ mode: Mode, walk: Bool = false) -> SpotlightPrivacyAutomation {
            let value = SpotlightPrivacyAutomation(cancelled: stopped, exactList: sudoList)
            value.presentation = mode; value.walksChooser = walk
            return value
        }
        func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }
        func state() -> String {
            Thread.sleep(forTimeInterval: 1.0)
            let app = settingsApp()
            return "frontAfter=\(front()) settingsRunning=\(app != nil) settingsHidden=\(app?.isHidden ?? false)"
        }
        // One measured operation. `expect` is the exclusion state the exact list must show afterwards.
        // Like the app in use: Disk Monitor is the active app when a change starts.
        func activateSelf() {
            _ = DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
            for _ in 0..<30 where front() != Bundle.main.bundleIdentifier { Thread.sleep(forTimeInterval: 0.1) }
        }
        func measure(_ name: String, _ operation: SpotlightPrivacyAutomation, path: String, excluded: Bool) {
            activateSelf()
            let before = front()
            let sampler = Visibility(); sampler.start()
            var outcome: String
            do {
                let value = try operation.run(path: path, excluded: excluded)
                let ok = value.map { ($0.covering(path) != nil) == excluded } ?? false
                outcome = ok ? "WORKS" : "WRONG-RESULT"
            } catch { outcome = "FAILS: " + error.localizedDescription }
            let seen = sampler.stop()
            let listed = ((try? sudoList())?.covering(path) != nil)
            write("PROBE \(name): \(outcome); exactListExcluded=\(listed); \(seen); frontBefore=\(before) \(state())"
                  + " notes=\(operation.presentationNotes) cleanup=\(operation.cleanupNotes)")
        }
        // Known-good setup and cleanup use the visible foreground flow, outside any measurement.
        func ensure(_ path: String, excluded: Bool) {
            guard ((try? sudoList())?.covering(path) != nil) != excluded else { return }
            do { _ = try automation(.foreground).run(path: path, excluded: excluded) }
            catch { write("SETUP \(excluded ? "add" : "remove") failed for \(path): \(error.localizedDescription)") }
            quitSettings()
        }
        let spaces = root + "/folder with spaces"
        let visibleRoot = NSHomeDirectory() + "/DiskMonitorProbe"
        let visibleTarget = visibleRoot + "/visible target"
        try? FileManager.default.createDirectory(atPath: visibleTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: visibleRoot) }
        quitSettings()

        // 1. Is the pane reachable without activating / while hidden?
        for mode in [Mode.background, .hidden] {
            let before = front(); let sampler = Visibility(); sampler.start()
            let operation = automation(mode)
            let result = (try? operation.probeReach()) ?? "error opening"
            write("PROBE reach-\(mode.rawValue): \(result); \(sampler.stop()); frontBefore=\(before) \(state()) notes=\(operation.presentationNotes)")
            quitSettings()
        }
        // 2. Remove entirely without activating / while hidden.
        for mode in [Mode.background, .hidden] {
            ensure(spaces, excluded: true)
            measure("remove-\(mode.rawValue)", automation(mode), path: spaces, excluded: false)
            quitSettings()
        }
        // 3a. Add entirely without activating / while hidden (Go to Folder keys to the Settings pid).
        for mode in [Mode.background, .hidden] {
            ensure(spaces, excluded: false)
            measure("add-a-\(mode.rawValue)", automation(mode), path: spaces, excluded: true)
            quitSettings()
        }
        // 3b. Add with Accessibility navigation only: a visible folder, then a hidden one.
        ensure(spaces, excluded: false)
        measure("add-b-walk-visible-hidden", automation(.hidden, walk: true), path: visibleTarget, excluded: true)
        quitSettings()
        measure("add-b-walk-visible-background", automation(.background, walk: true), path: visibleTarget, excluded: true)
        quitSettings()
        ensure(visibleTarget, excluded: false)
        measure("add-b-walk-hiddenfolder-background", automation(.background, walk: true), path: spaces, excluded: true)
        quitSettings()
        // 3c. Activate only for the Go to Folder keystrokes.
        for mode in [Mode.brief] {
            ensure(spaces, excluded: false)
            measure("add-c-\(mode.rawValue)", automation(mode), path: spaces, excluded: true)
            quitSettings()
            ensure(spaces, excluded: true)
            measure("remove-\(mode.rawValue)", automation(mode), path: spaces, excluded: false)
            quitSettings()
        }
        // 4. System Settings already open on another pane and not active: is it left as it was?
        for mode in [Mode.brief] {
            ensure(spaces, excluded: false)
            _ = DispatchQueue.main.sync { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
            Thread.sleep(forTimeInterval: 3)
            _ = DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
            Thread.sleep(forTimeInterval: 1.5)
            measure("add-c-\(mode.rawValue)-settings-already-open", automation(mode), path: spaces, excluded: true)
            quitSettings()
            ensure(spaces, excluded: true)
            _ = DispatchQueue.main.sync { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
            Thread.sleep(forTimeInterval: 3)
            measure("remove-\(mode.rawValue)-settings-already-open", automation(mode), path: spaces, excluded: false)
            let after = settingsApp()
            write("PROBE state-after-\(mode.rawValue)-settings-already-open: running=\(after != nil) hidden=\(after?.isHidden ?? false)")
            quitSettings()
        }
        // Leave no fixture or probe folder excluded.
        for path in [spaces, visibleTarget] { ensure(path, excluded: false) }
        let leftover = ((try? sudoList())?.paths ?? []).filter { $0.hasPrefix(root + "/") || $0.hasPrefix(visibleRoot) }
        write((leftover.isEmpty ? "PASS" : "FAIL") + " no probe exclusions left: \(leftover.sorted())")
        write("END probe")
    }
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
        let mode = presentation
        write("START macOS \(info) locale \(Locale.current.identifier) trusted=\(AXIsProcessTrusted()) presentation=\(mode.rawValue) root=\(root)")
        func automation() -> SpotlightPrivacyAutomation {
            let value = SpotlightPrivacyAutomation(cancelled: stopped, exactList: sudoList)
            value.presentation = mode
            return value
        }
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
                write((ok ? "PASS " : "FAIL ") + name + ": \(value.paths.subtracting(initial.paths).sorted()) \(operation.presentationNotes)")
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
        // Hidden folders (like ~/.cargo) are not listed by the chooser.
        step("add hidden", fixture(".hidden-cache"), excluded: true)
        step("remove hidden", fixture(".hidden-cache"), excluded: false)
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
#endif
