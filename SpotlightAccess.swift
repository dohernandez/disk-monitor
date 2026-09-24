import Cocoa
import SwiftUI
import ServiceManagement

/// Main-thread owner of setup and the single authenticated scanner request.
/// The persisted Spotlight toggle owns registration; startup revalidates its access.
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
    @Published private(set) var enabled = false
    @Published private(set) var ready = false
    @Published private(set) var reconciling = false
    private var lifecycleCallbacks: [() -> Void] = []
    private var lifecycleRevision = 0
    private var activeRevision = 0
    private let presentSetupOverride: (() -> Void)?
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
        enabled && ready && packageValid && registration == 1 && !repair && !awaitingOff && !needsAccess && !uncertain
    }
    init(preferences: UserDefaults, operation: ((String, @escaping (BridgeMessage) -> Void) -> Void)? = nil, presentSetup: (() -> Void)? = nil) {
        self.presentSetupOverride = presentSetup
        self.operationOverride = operation
        self.preferences = preferences
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
                    if ["result", "status", "access", "launchFailed", "cancelRequested"].contains(reply.event) { sawFinal = true }
                    deliver(reply)
                }
            }
            process.waitUntilExit()
            if !sawFinal { deliver(BridgeMessage(event: "bridgeExited", error: "Scanner client stopped without a complete response")) }
        }
    }
    func openSetup() {
        if let presentSetupOverride { presentSetupOverride(); return }
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
            title = ready ? "Spotlight is ready" : "Checking Spotlight access"
            detail = "Spotlight uses your folder scan schedule. You can also use its refresh arrow. Turn off Spotlight in Settings to stop tracking and unregister its scanner."
        } else {
            title = enabled ? "Enabling Spotlight" : "Spotlight is disabled"
            detail = "The Spotlight toggle in Settings controls tracking and its background scanner together. No monitored files are changed or deleted."
        }
    }
    /// Called only from the Spotlight toggle, persisted startup intent, or an access retry.
    func setEnabled(_ value: Bool, completion: (() -> Void)? = nil) {
        enabled = value; ready = false; lifecycleRevision += 1
        if let completion { lifecycleCallbacks.append(completion) }
        reconcile()
    }
    private func reconcile() {
        guard !reconciling, !changingRegistration else { return }
        if busy && !uncertain {
            if !enabled { cancel() }
            return // finish() resumes the latest intent after owned cancellation completes.
        }
        reconciling = true; activeRevision = lifecycleRevision
        if (uncertain || awaitingOff) && enabled { finishReconciliation(showSetup: true); return }
        refreshAvailability {
            guard self.activeRevision == self.lifecycleRevision else { self.finishReconciliation(); return }
            guard self.packageValid else { self.finishReconciliation(showSetup: self.enabled); return }
            if !self.enabled {
                if self.registration == 0 || self.registration == 3 {
                    self.repair = false; self.awaitingOff = false; self.needsAccess = false
                    self.finishReconciliation(); self.window?.close()
                }
                else { self.removeRegistration() }
            } else if self.registration == 2 {
                self.startTimer(); self.finishReconciliation(showSetup: true)
            } else if self.registration == 1 {
                self.validateAccess()
            } else {
                self.run("register") { reply in
                    self.registration = reply.status ?? 0
                    if let error = reply.error {
                        self.title = "Could not enable Spotlight"; self.detail = error
                        self.finishReconciliation(showSetup: true, preserveMessage: true)
                    } else if self.activeRevision != self.lifecycleRevision {
                        self.finishReconciliation()
                    } else if self.registration == 1 { self.validateAccess() }
                    else { self.startTimer(); self.finishReconciliation(showSetup: true) }
                }
            }
        }
    }
    private func removeRegistration() {
        run("unregister") { reply in
            self.registration = reply.status ?? self.registration
            if let error = reply.error {
                self.title = "Could not disable Spotlight scanner"; self.detail = error
                self.finishReconciliation(showSetup: true, preserveMessage: true)
            } else {
                self.repair = false; self.awaitingOff = false; self.needsAccess = false
                self.retryAt = 0; self.cooldown = 0
                self.finishReconciliation()
                if !self.enabled { self.window?.close() }
            }
        }
    }
    private func validateAccess() {
        run("check") { reply in
            guard self.activeRevision == self.lifecycleRevision else { self.finishReconciliation(); return }
            self.needsAccess = reply.event == "access" && reply.status == 1
            self.repair = reply.event != "access"
            self.ready = reply.event == "access" && reply.status == 0
            if reply.event == "access" && reply.status != 0 && reply.status != 1 {
                self.title = "Spotlight safety check failed"
                self.detail = "The fixed index directory is unavailable or failed its safety checks. Changing Full Disk Access may not resolve this. Saved measurements are kept."
                self.finishReconciliation(showSetup: true, preserveMessage: true)
            } else { self.finishReconciliation(showSetup: !self.ready) }
        }
    }
    private func finishReconciliation(showSetup: Bool = false, preserveMessage: Bool = false) {
        reconciling = false
        if activeRevision != lifecycleRevision { reconcile(); return }
        if showSetup {
            if preserveMessage { presentWindow() } else { openSetup() }
        } else if window != nil { describeSetup() }
        let callbacks = lifecycleCallbacks; lifecycleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }
    private func presentWindow() {
        let savedTitle = title, savedDetail = detail
        openSetup(); title = savedTitle; detail = savedDetail
    }
    func openApproval() { SMAppService.openSystemSettingsLoginItems() }
    func revealScanner() { NSWorkspace.shared.activateFileViewerSelecting([host]) }
    func openDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func checkSetup() {
        guard !busy, !changingRegistration else { return }
        setEnabled(enabled)
    }
    func register() {
        guard enabled, packageValid, !busy, !uncertain, !changingRegistration else { return }
        changingRegistration = true
        run("register") { reply in
            self.changingRegistration = false
            if let status = reply.status { self.registration = status }
            if !self.enabled { self.reconcile(); return }
            guard reply.status == 1 || reply.status == 2 else {
                self.title = "Registration failed"; self.detail = reply.error ?? "Scanner registration unavailable"; return
            }
            if self.awaitingOff && reply.status != 2 {
                self.unregister(forRepair: true); return
            }
            self.awaitingOff = false; self.setEnabled(self.enabled); self.startTimer()
        }
    }
    func unregister(forRepair: Bool = false) {
        guard !busy, !uncertain, !changingRegistration else { return }
        changingRegistration = true
        run("unregister") { reply in
            self.changingRegistration = false
            if !self.enabled { self.reconcile(); return }
            if let error = reply.error { self.title = "Could not remove scanner"; self.detail = error; return }
            self.registration = reply.status ?? 0
            self.repair = false; self.awaitingOff = forRepair
            self.retryAt = 0; self.cooldown = 0
            if forRepair { self.describeSetup(); self.openApproval() }
            else {
                self.title = "Scanner disabled"
                self.detail = "Background registration removed. Full Disk Access can be revoked separately in System Settings."
            }
        }
    }
    /// Caller owns the app's global scan slot. This never opens setup or requests approval.
    func measure(completion: @escaping (Measurement) -> Void) {
        guard enabled, ready, !busy, !uncertain, packageValid, registration == 1, !repair, !awaitingOff, !needsAccess else {
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
        if lifecycleRevision != activeRevision || !enabled || !lifecycleCallbacks.isEmpty { reconcile() }
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
            if enabled && !reconciling {
                refreshAvailability {
                    if self.enabled && self.registration == 1 { self.setEnabled(true) }
                }
            }
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
            } else if access.reconciling {
                ProgressView("Checking Spotlight access…")
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
                    Text("Spotlight is enabled in Settings and uses the folder scan schedule.")
                    if access.cooldown > 0 { Text("Next measurement available in \(access.cooldown)s").monospacedDigit() }
                } else {
                    Button("Retry setup") { access.checkSetup() }
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
