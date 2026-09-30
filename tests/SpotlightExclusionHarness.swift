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
#endif
