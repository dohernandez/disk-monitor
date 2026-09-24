import Cocoa
import SwiftUI
import ServiceManagement

/// Main-thread owner of setup and the single authenticated scanner request.
/// Registration is always an explicit button action; automatic ticks never authorize.
final class SpotlightAccess: ObservableObject {
    @Published var title = "Set up protected-folder measurement"
    @Published var detail = ""
    @Published var busy = false
    @Published var cooldown = 0
    @Published var repair = false
    @Published var awaitingOff = false
    @Published var needsAccess = false
    @Published var packageValid = false
    @Published var registration: Int = 0
    @Published var automatic = false
    @Published var uncertain = false
    private let preferences: UserDefaults
    private let pendingKey = "spotlightPendingScanBoot"
    private var window: NSWindow?
    private var timer: Timer?
    private var completion: ((Measurement) -> Void)?
    private var last: Measurement?
    private var retryAt: TimeInterval = 0
    private var cancelling = false
    private var changingRegistration = false
    private var checkingStatus = false
    private var availabilityCallbacks: [() -> Void] = []
    private let operationOverride: ((String, @escaping (BridgeMessage) -> Void) -> Void)?
    private var measurementID = UUID()
    private var started: TimeInterval = 0
    private var measuring = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var host: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Scanner/Disk Monitor Scanner.app") }
    var canAutomaticallyMeasure: Bool {
        automatic && packageValid && registration == 1 && !repair && !awaitingOff && !needsAccess && !uncertain
    }
    init(preferences: UserDefaults, operation: ((String, @escaping (BridgeMessage) -> Void) -> Void)? = nil) {
        self.operationOverride = operation
        self.preferences = preferences
        automatic = preferences.bool(forKey: "spotlightAutomaticMeasurement")
        uncertain = ScannerRecovery.needsRecovery(pendingBoot: preferences.string(forKey: pendingKey), currentBoot: ScannerRecovery.bootSession())
        if !uncertain { preferences.removeObject(forKey: pendingKey) }
        // No registration, IPC, keychain access or scan at construction.
    }
    func refreshAvailability(completion: (() -> Void)? = nil) {
        if let completion { availabilityCallbacks.append(completion) }
        guard !checkingStatus else { return }
        checkingStatus = true
        run("status") { reply in
            self.checkingStatus = false
            self.packageValid = reply.event != "packageFailed"
            self.registration = reply.status ?? 0
            if !self.busy && self.window != nil { self.describeSetup() }
            let callbacks = self.availabilityCallbacks
            self.availabilityCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }
    /// Launch only the signed fixed-operation bridge. Never run a shell or pass paths.
    private func run(_ operation: String, receive: @escaping (BridgeMessage) -> Void) {
        if let operationOverride { operationOverride(operation, receive); return }
        let host = self.host
        DispatchQueue.global(qos: .utility).async {
            func deliver(_ message: BridgeMessage) { DispatchQueue.main.async { receive(message) } }
            do { try BundlePolicy.validate(at: host) }
            catch { deliver(BridgeMessage(event: "packageFailed", error: "Scanner package is unavailable or has an unexpected signature")); return }
            let process = Process()
            process.executableURL = host.appendingPathComponent("Contents/MacOS/Bridge")
            process.arguments = [operation]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let pipe = Pipe(); process.standardOutput = pipe
            do { try process.run() }
            catch { deliver(BridgeMessage(event: "launchFailed", error: "Cannot start signed scanner client")); return }
            var buffer = Data(); var sawFinal = false; var total = 0
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk); total += chunk.count
                guard buffer.count <= 4096, total <= 65536 else { process.terminate(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    guard line.count < 2048, let reply = try? JSONDecoder().decode(BridgeMessage.self, from: line) else {
                        process.terminate(); break
                    }
                    if ["result", "status", "launchFailed", "cancelRequested"].contains(reply.event) { sawFinal = true }
                    deliver(reply)
                }
            }
            process.waitUntilExit()
            if !sawFinal { deliver(BridgeMessage(event: "bridgeExited", error: "Scanner client stopped without a complete response")) }
        }
    }
    func openSetup() {
        refreshAvailability()
        if !busy { describeSetup() }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disk Monitor — protected-folder access"
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProtectedFolderSetup(access: self))
            self.window = window
        }
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        startTimer()
    }
    private func describeSetup() {
        if uncertain {
            title = "Restart your Mac before scanning again"
            detail = "The previous scanner request has no confirmed completion. Saved measurements are kept and new scans are paused. Restart your Mac to ensure the old scan has stopped; reopening Disk Monitor alone does not clear this state."
        } else if !packageValid {
            title = "Scanner unavailable in this build"
            detail = "This app does not contain a scanner signed with the expected release identity. Changing Full Disk Access will not repair this. Ordinary folder measurements remain available."
        } else if awaitingOff {
            title = "Turn off the previous background approval"
            detail = "In System Settings → General → Login Items & Extensions, turn OFF only Disk Monitor Scanner. Then return and choose ‘I turned it off’. Leave Full Disk Access unchanged."
        } else if repair {
            title = "Repair scanner after update"
            detail = "The scanner could not start. Repair unregisters it, then guides you through turning its background approval off and on. It does not start a scan or change disk permissions."
        } else if needsAccess {
            title = "Check protected-folder access"
            detail = "In System Settings → Privacy & Security → Full Disk Access, allow Disk Monitor Scanner if you choose. This grants broad disk access. Use Show scanner in Finder, then drag the selected scanner app into Full Disk Access. Reopen Disk Monitor afterward. Some system protections may still prevent measurement."
        } else if registration == 2 {
            title = "Approve the scanner in macOS"
            detail = "Open Login Items & Extensions and turn ON Disk Monitor Scanner under Allow in the Background. Return here afterward."
        } else if registration == 1 {
            title = "Verify the scanner"
            detail = "The helper is registered. Use Refresh on the Spotlight row to check its identity and request a read-only size measurement. Other folders never receive administrator access through this scanner."
        } else {
            title = "Set up protected-folder measurement"
            detail = "The optional administrator scanner measures only Spotlight’s index. Enable registers a background helper; macOS approval and Full Disk Access may be needed. No passwords are stored, and no monitored files or permissions are changed."
        }
    }
    func setAutomatic(_ enabled: Bool) {
        automatic = enabled
        preferences.set(enabled, forKey: "spotlightAutomaticMeasurement")
    }
    func openApproval() { SMAppService.openSystemSettingsLoginItems() }
    func revealScanner() { NSWorkspace.shared.activateFileViewerSelecting([host]) }
    func openDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func checkSetup() {
        guard !busy, !changingRegistration else { return }
        needsAccess = false; refreshAvailability(); describeSetup()
    }
    func register() {
        guard packageValid, !busy, !uncertain, !changingRegistration else { return }
        changingRegistration = true
        run("register") { reply in
            self.changingRegistration = false
            if let status = reply.status { self.registration = status }
            guard reply.status == 1 || reply.status == 2 else {
                self.title = "Registration failed"; self.detail = reply.error ?? "Scanner registration unavailable"; return
            }
            if self.awaitingOff && reply.status != 2 {
                self.unregister(forRepair: true); return
            }
            self.awaitingOff = false; self.describeSetup(); self.startTimer()
        }
    }
    func unregister(forRepair: Bool = false) {
        guard !busy, !uncertain, !changingRegistration else { return }
        changingRegistration = true
        run("unregister") { reply in
            self.changingRegistration = false
            if let error = reply.error { self.title = "Could not remove scanner"; self.detail = error; return }
            self.registration = reply.status ?? 0
            self.repair = false; self.awaitingOff = forRepair
            self.retryAt = 0; self.cooldown = 0
            if forRepair { self.describeSetup(); self.openApproval() }
            else {
                self.setAutomatic(false)
                self.title = "Scanner disabled"
                self.detail = "Background registration removed. Full Disk Access can be revoked separately in System Settings."
            }
        }
    }
    /// Caller owns the app's global scan slot. This never opens setup or requests approval.
    func measure(completion: @escaping (Measurement) -> Void) {
        guard !busy, !uncertain, packageValid, registration == 1, !repair, !awaitingOff, !needsAccess else {
            completion(.failed("Scanner setup required")); return
        }
        if now < retryAt, let last { completion(last); return }
        preferences.set(ScannerRecovery.bootSession() ?? "", forKey: pendingKey)
        guard preferences.synchronize() else {
            completion(.failed("Cannot save scanner recovery state; no measurement started")); return
        }
        busy = true; cancelling = false; uncertain = false; measuring = false
        self.completion = completion; measurementID = UUID()
        let token = measurementID
        started = now; title = "Starting scanner…"; detail = "Checking the signed helper. No measurement requested yet."
        startTimer()
        run("measure") { reply in
            guard self.busy, self.measurementID == token else { return }
            switch reply.event {
            case "measuring": self.measuring = true; self.started = self.now; self.title = "Measuring Spotlight"
            case "result":
                guard let result = reply.measurement,
                      result.finishedAt.timeIntervalSince1970.isFinite,
                      result.finishedAt <= Date().addingTimeInterval(5),
                      result.bytes == nil || result.bytes! >= 0 else {
                    self.finish(.failed("Invalid scanner response; saved size kept")); return
                }
                self.finish(self.cancelling ? .failed("Measurement cancelled") : result)
            case "packageFailed", "launchFailed":
                self.repair = true; self.finish(.failed(reply.error ?? "Scanner launch failed"))
            case "uncertain", "bridgeExited":
                self.uncertain = true; self.describeSetup()
            default: break
            }
        }
    }
    func cancel() {
        guard busy, !cancelling else { return }
        cancelling = true; title = "Stopping measurement…"
        detail = "Waiting for the owned scan to stop. No partial measurement will be saved."
        run("cancel") { _ in } // Only the original measurement reply confirms completion.
    }
    private func finish(_ result: Measurement) {
        measurementID = UUID()
        busy = false; uncertain = false
        preferences.removeObject(forKey: pendingKey)
        preferences.synchronize()
        let callback = completion; completion = nil
        last = result
        retryAt = now + max(0, min(60, 60 - Date().timeIntervalSince(result.finishedAt)))
        if let bytes = result.bytes {
            title = "Measurement complete"
            detail = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) + " • " + result.finishedAt.formatted() + ". Another measurement is available after the countdown."
        } else {
            title = result.error == "Measurement cancelled" ? "Measurement cancelled" : "Measurement did not complete"
            detail = result.error == "Measurement cancelled" ? "The scan stopped. Your previous complete measurement was kept." : (result.error ?? "Saved size kept")
            needsAccess = detail.contains("Full Disk Access")
        }
        if repair { describeSetup() }
        callback?(result)
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func tick() {
        cooldown = max(0, Int(ceil(retryAt - now)))
        if busy {
            if !measuring && now - started >= 15 {
                // Includes bridge startup; no claim that an unobserved request stopped.
                uncertain = true; describeSetup()
            } else if measuring && !cancelling && !uncertain {
                let elapsed = Int(now - started)
                detail = "\(elapsed / 60)m \(elapsed % 60)s elapsed. Scan budget: 15 minutes. No partial size is saved."
            }
        } else if registration == 2 && !awaitingOff && !changingRegistration {
            refreshAvailability()
        }
    }

}

struct ProtectedFolderSetup: View {
    @ObservedObject var access: SpotlightAccess
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(access.title).font(.title2.bold())
            Text(access.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if access.uncertain {
                Text("You can quit Disk Monitor, then restart your Mac from the Apple menu.")
                Button("Quit Disk Monitor") { NSApp.terminate(nil) }
            } else if access.busy {
                ProgressView()
                Button("Cancel measurement") { access.cancel() }
            } else if access.packageValid {
                if access.awaitingOff {
                    Button("Open approval settings…") { access.openApproval() }
                    Button("I turned it off — register scanner") { access.register() }
                } else if access.repair {
                    Button("Repair scanner after update…") { access.unregister(forRepair: true) }
                } else if access.needsAccess {
                    Button("Show scanner in Finder") { access.revealScanner() }
                    Button("Open Full Disk Access…") { access.openDiskAccess() }
                    Button("Check setup again") { access.checkSetup() }
                } else if access.registration == 2 {
                    Button("Open approval settings…") { access.openApproval() }
                } else if access.registration == 1 {
                    Text("Return to the Spotlight row and use Refresh to verify and measure.")
                    Toggle("Measure Spotlight during scheduled folder scans", isOn: Binding(get: { access.automatic }, set: { access.setAutomatic($0) }))
                    if access.cooldown > 0 { Text("Next measurement available in \(access.cooldown)s").monospacedDigit() }
                } else {
                    Button("Enable scanner…") { access.register() }
                }
                if access.registration == 1 || access.registration == 2 {
                    Button("Disable scanner") { access.unregister() }
                }
            }
            Spacer()
            Text("Other protected folders: see Info → Folders protected by macOS. This administrator helper accepts only the fixed Spotlight index path.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 520, minHeight: 370).preferredColorScheme(.dark)
    }
}

struct SpotlightStatus: View {
    @ObservedObject var access: SpotlightAccess
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if access.uncertain { Text("Scanner completion unconfirmed · restart your Mac").fixedSize(horizontal: false, vertical: true) }
            else if access.busy { Text(access.title + " · " + access.detail).fixedSize(horizontal: false, vertical: true) }
            else if access.cooldown > 0 { Text("Recent measurement · next scan in \(access.cooldown)s").monospacedDigit() }
        }.buttonStyle(.borderless).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .trailing)
    }
}
