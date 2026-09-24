import Cocoa
import SwiftUI
import ServiceManagement

/// Main-thread owner of setup and the single authenticated scanner request.
/// The persisted Spotlight toggle owns registration; startup revalidates its access.
final class SpotlightAccess: ObservableObject {
    @Published var title = "Spotlight access"
    @Published var detail = ""
    @Published var busy = false
    @Published var cooldown = 0
    @Published private(set) var failure: String?
    private var attemptedRecovery = false
    private var restartAfterPermission = false
    private var waitingForSettings = false
    private var activationObserver: NSObjectProtocol?
    var onReady: (() -> Void)?
    var onGeneralPermissionReturn: (() -> Void)?
    @Published private(set) var generalFolder: String?
    func openGeneralAccess(for name: String) { generalFolder = name; openSetup() }
    func closeGeneralAccess() { generalFolder = nil; window?.close() }
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
    private var checkingStatus = false
    private var availabilityCallbacks: [() -> Void] = []
    private let operationOverride: ((String, @escaping (BridgeMessage) -> Void) -> Void)?
    private var measurementID = UUID()
    private var started: TimeInterval = 0
    private var measuring = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var host: URL { Bundle.main.bundleURL }
    var canAutomaticallyMeasure: Bool {
        enabled && ready && packageValid && registration == 1 && failure == nil && !needsAccess && !uncertain
    }
    init(preferences: UserDefaults, operation: ((String, @escaping (BridgeMessage) -> Void) -> Void)? = nil, presentSetup: (() -> Void)? = nil) {
        self.presentSetupOverride = presentSetup
        self.operationOverride = operation
        self.preferences = preferences
        uncertain = ScannerRecovery.needsRecovery(pendingBoot: preferences.string(forKey: pendingKey), currentBoot: ScannerRecovery.bootSession())
        if !uncertain { preferences.removeObject(forKey: pendingKey) }
        if operation == nil {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.returnedToApp()
            }
        }
        // No registration, IPC, keychain access or scan at construction.
    }
    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        timer?.invalidate()
    }
    func returnedToApp() {
        if waitingForSettings, generalFolder != nil {
            waitingForSettings = false; onGeneralPermissionReturn?(); return
        }
        guard waitingForSettings, enabled, !busy, !reconciling, !uncertain else { return }
        waitingForSettings = false
        setEnabled(true)
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
            process.executableURL = host.appendingPathComponent("Contents/MacOS/" + HelperIdentity.clientName)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disk Monitor — folder access"
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProtectedFolderSetup(access: self))
            self.window = window
        }
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        startTimer()
    }
    private func describeSetup() {
        if let generalFolder {
            title = "Allow access to " + generalFolder
            detail = "Allow Disk Monitor in System Settings → Privacy & Security → Full Disk Access. Drag the app icon below into that list. Return to Disk Monitor to continue the requested scan. This grants broad disk access; some system restrictions may still apply."
        } else if uncertain {
            title = "Restart your Mac before scanning again"
            detail = "The previous scanner request has no confirmed completion. Saved measurements are kept and new scans are paused. Restart your Mac to ensure the old scan has stopped; reopening Disk Monitor alone does not clear this state."
        } else if !packageValid {
            title = "Scanner unavailable in this build"
            detail = "This app does not contain a scanner signed with the expected release identity. Changing Full Disk Access will not repair this. Ordinary folder measurements remain available."
        } else if let failure {
            title = "Spotlight is unavailable"
            detail = failure + ". Your saved measurement is kept. You can retry using Spotlight’s refresh arrow."
        } else if needsAccess {
            title = "Allow Spotlight measurement"
            detail = "In System Settings → Privacy & Security → Full Disk Access, allow Disk Monitor if you choose. This grants broad disk access. Drag the icon below into that list. Return to Disk Monitor afterward; it will check access and continue automatically. Some system protections may still prevent measurement."
        } else if registration == 2 {
            title = "Allow Spotlight measurement"
            detail = "Open Login Items & Extensions and turn ON Disk Monitor under Allow in the Background. This is Disk Monitor’s internal Spotlight scanner. Return to Disk Monitor to continue automatically."
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
        enabled = value; ready = false; failure = nil; attemptedRecovery = false; lifecycleRevision += 1
        if let completion { lifecycleCallbacks.append(completion) }
        reconcile()
    }
    private func reconcile() {
        guard !reconciling else { return }
        if busy && !uncertain {
            if !enabled { cancel() }
            return // finish() resumes the latest intent after owned cancellation completes.
        }
        reconciling = true; activeRevision = lifecycleRevision
        if uncertain && enabled { finishReconciliation(showSetup: true); return }
        refreshAvailability {
            guard self.activeRevision == self.lifecycleRevision else { self.finishReconciliation(); return }
            guard self.packageValid else { self.finishReconciliation(showSetup: self.enabled); return }
            if !self.enabled {
                if self.registration == 0 || self.registration == 3 {
                    self.failure = nil; self.needsAccess = false; self.restartAfterPermission = false; self.waitingForSettings = false
                    self.finishReconciliation(); self.window?.close()
                }
                else { self.removeRegistration() }
            } else if (self.registration == 1 || self.registration == 2) && !self.preferences.bool(forKey: "scannerRegisteredInMainBundle") {
                self.restartRegistration()
            } else if self.registration == 2 {
                self.startTimer(); self.finishReconciliation(showSetup: true)
            } else if self.registration == 1 {
                if self.restartAfterPermission { self.restartRegistration() }
                else { self.validateAccess() }
            } else {
                self.registerForCurrentIntent()
            }
        }
    }
    private func registerForCurrentIntent() {
        run("register") { reply in
            self.registration = reply.status ?? 0
            if self.activeRevision != self.lifecycleRevision {
                self.finishReconciliation()
            } else if let error = reply.error {
                if !self.attemptedRecovery { self.restartRegistration() }
                else { self.failure = error; self.finishReconciliation(showSetup: true) }
            } else if self.registration == 1 {
                self.preferences.set(true, forKey: "scannerRegisteredInMainBundle")
                self.validateAccess()
            } else if self.registration == 2 {
                self.preferences.set(true, forKey: "scannerRegisteredInMainBundle")
                self.startTimer(); self.finishReconciliation(showSetup: true)
            }
            else {
                self.failure = "macOS could not enable Spotlight measurement"
                self.finishReconciliation(showSetup: true)
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
                self.failure = nil; self.needsAccess = false; self.restartAfterPermission = false; self.waitingForSettings = false
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
            if reply.event == "launchFailed", !self.attemptedRecovery {
                self.restartRegistration(); return
            }
            self.failure = reply.event == "access" ? nil : (reply.error ?? "Could not connect to Spotlight")
            self.ready = reply.event == "access" && reply.status == 0
            if reply.event == "access" && reply.status != 0 && reply.status != 1 {
                self.title = "Spotlight safety check failed"
                self.detail = "The fixed index directory is unavailable or failed its safety checks. Changing Full Disk Access may not resolve this. Saved measurements are kept."
                self.finishReconciliation(showSetup: true, preserveMessage: true)
            } else { self.finishReconciliation(showSetup: !self.ready) }
        }
    }
    /// The preflight has not requested a measurement. Wait for this service's
    /// asynchronous removal before registering its bundled replacement, at most once.
    private func restartRegistration() {
        guard !busy, !uncertain else { finishReconciliation(); return }
        attemptedRecovery = true; restartAfterPermission = false
        run("unregister") { reply in
            self.registration = reply.status ?? self.registration
            if let error = reply.error {
                self.failure = error
                self.finishReconciliation(showSetup: true); return
            }
            guard self.enabled, self.activeRevision == self.lifecycleRevision else {
                self.finishReconciliation(); return
            }
            self.registerForCurrentIntent()
        }
    }
    private func finishReconciliation(showSetup: Bool = false, preserveMessage: Bool = false) {
        reconciling = false
        if activeRevision != lifecycleRevision { reconcile(); return }
        if showSetup {
            if preserveMessage { presentWindow() } else { openSetup() }
        } else if ready { window?.close() }
        else if window != nil { describeSetup() }
        if ready {
            waitingForSettings = false
            if last?.bytes == nil { last = nil; retryAt = 0; cooldown = 0 }
            onReady?()
        }
        let callbacks = lifecycleCallbacks; lifecycleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }
    private func presentWindow() {
        let savedTitle = title, savedDetail = detail
        openSetup(); title = savedTitle; detail = savedDetail
    }
    func willOpenPermissionSettings(fullDiskAccess: Bool = false) {
        waitingForSettings = true
        if fullDiskAccess && (generalFolder == nil || needsAccess) { restartAfterPermission = true }
    }
    func openApproval() {
        willOpenPermissionSettings()
        SMAppService.openSystemSettingsLoginItems()
    }
    var permissionIcon: NSImage { NSWorkspace.shared.icon(forFile: host.path) }
    func permissionDragItem() -> NSItemProvider {
        openDiskAccess()
        return NSItemProvider(object: host as NSURL)
    }
    func openDiskAccess() {
        willOpenPermissionSettings(fullDiskAccess: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func checkSetup() {
        guard !busy, !reconciling else { return }
        setEnabled(enabled)
    }
    /// Caller owns the app's global scan slot. This never opens setup or requests approval.
    func measure(completion: @escaping (Measurement) -> Void) {
        guard enabled, ready, !busy, !uncertain, packageValid, registration == 1, failure == nil, !needsAccess else {
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
                self.failure = reply.error ?? "Could not connect to Spotlight"; self.ready = false; self.finish(.failed(self.failure!))
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
            if needsAccess { ready = false }
        }
        if failure != nil { describeSetup() }
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
        } else if registration == 2 {
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
            if access.generalFolder != nil {
                HStack {
                    Image(nsImage: access.permissionIcon).resizable().frame(width: 48, height: 48)
                    Text("Disk Monitor").font(.body.bold())
                }.onDrag { access.permissionDragItem() }
                Button("Open Full Disk Access…") { access.openDiskAccess() }
            } else if access.uncertain {
                Text("You can quit Disk Monitor, then restart your Mac from the Apple menu.")
                Button("Quit Disk Monitor") { NSApp.terminate(nil) }
            } else if access.reconciling {
                ProgressView("Checking Spotlight access…")
            } else if access.busy {
                ProgressView()
                Button("Cancel measurement") { access.cancel() }
            } else if access.packageValid {
                if access.failure != nil {
                    Button("Retry") { access.checkSetup() }
                } else if access.needsAccess {
                    HStack {
                        Image(nsImage: access.permissionIcon).resizable().frame(width: 48, height: 48)
                        Text("Disk Monitor").font(.body.bold())
                    }
                    .onDrag { access.permissionDragItem() }
                    .accessibilityLabel("Drag Disk Monitor to Full Disk Access")
                    Button("Open Full Disk Access…") { access.openDiskAccess() }
                } else if access.registration == 2 {
                    Button("Open approval settings…") { access.openApproval() }
                } else if access.registration == 1 {
                    Text("Spotlight is enabled in Settings and uses the folder scan schedule.")
                    if access.cooldown > 0 { Text("Next measurement available in \(access.cooldown)s").monospacedDigit() }
                } else {
                    Button("Retry") { access.checkSetup() }
                }

            }
            Spacer()
            Text("Disk Monitor never changes or deletes monitored files.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(minWidth: 470, minHeight: 290).preferredColorScheme(.dark)
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
