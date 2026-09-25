import Cocoa
import ServiceManagement

/// Internal fixed-target privileged I/O. No windows, permission UI or folder selection.
/// FolderAccess owns the public access/scan flow; this transport never accepts arbitrary paths.
final class PrivilegedFolderReader {
    var busy = false
    private(set) var failure: String?
    private var restartAfterPermission = false
    var onReady: (() -> Void)?
    var onChange: (() -> Void)?
    static func supports(_ path: String) -> Bool { path == "/System/Volumes/Data/.Spotlight-V100" }
    var needsAccess = false
    var packageValid = false
    var registration: Int = 0
    private(set) var enabled = false
    private(set) var ready = false
    private(set) var reconciling = false
    private var lifecycleCallbacks: [() -> Void] = []
    private var lifecycleRevision = 0
    private var activeRevision = 0
    var uncertain = false
    static var currentRegistrationIdentity: String {
        Bundle.main.bundleURL.standardizedFileURL.path + "#" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    }
    private let registrationIdentity: String
    private let preferences: UserDefaults
    private let pendingKey = "spotlightPendingScanBoot"
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
    init(preferences: UserDefaults, registrationIdentity: String = PrivilegedFolderReader.currentRegistrationIdentity, operation: ((String, @escaping (BridgeMessage) -> Void) -> Void)? = nil) {
        self.registrationIdentity = registrationIdentity
        self.operationOverride = operation
        self.preferences = preferences
        uncertain = ScannerRecovery.needsRecovery(pendingBoot: preferences.string(forKey: pendingKey), currentBoot: ScannerRecovery.bootSession())
        if !uncertain { preferences.removeObject(forKey: pendingKey) }
        // No registration, IPC, keychain access or scan at construction.
    }
    deinit {
        timer?.invalidate()
    }
    func refreshAvailability(completion: (() -> Void)? = nil) {
        if let completion { availabilityCallbacks.append(completion) }
        guard !checkingStatus else { return }
        checkingStatus = true
        run("status") { reply in
            self.checkingStatus = false
            self.packageValid = reply.event != "packageFailed"
            self.registration = reply.status ?? 0
            let callbacks = self.availabilityCallbacks
            self.availabilityCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }
    /// Register from DiskMonitor itself so SMAppService records the containing app's
    /// process identity. Only authenticated scanner IPC runs in the hardened bridge.
    private func run(_ operation: String, receive: @escaping (BridgeMessage) -> Void) {
        if let operationOverride { operationOverride(operation, receive); return }
        let host = self.host
        DispatchQueue.global(qos: .utility).async {
            func deliver(_ message: BridgeMessage) { DispatchQueue.main.async { receive(message) } }
            do { try BundlePolicy.validate(at: host) }
            catch { deliver(BridgeMessage(event: "packageFailed", error: "Scanner package is unavailable or has an unexpected signature")); return }
            if ["status", "register", "unregister"].contains(operation) {
                let service = SMAppService.daemon(plistName: HelperIdentity.serviceID + ".plist")
                func reply(_ error: Error? = nil) {
                    let error = error as NSError?
                    deliver(BridgeMessage(event: "status", status: service.status.rawValue,
                                          error: error?.localizedDescription,
                                          errorDomain: error?.domain, errorCode: error?.code))
                }
                switch operation {
                case "register":
                    do { try service.register(); reply() } catch { reply(error) }
                case "unregister": service.unregister { reply($0) }
                default: reply()
                }
                return
            }
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
    /// FolderAccess supplies whether the current tracked roots need this capability.
    func setEnabled(_ value: Bool, completion: (() -> Void)? = nil) {
        enabled = value; ready = false; failure = nil; lifecycleRevision += 1
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
        if uncertain && enabled { finishReconciliation(); return }
        refreshAvailability {
            guard self.activeRevision == self.lifecycleRevision else { self.finishReconciliation(); return }
            guard self.packageValid else { self.finishReconciliation(); return }
            if !self.enabled {
                if self.registration == 0 || self.registration == 3 {
                    self.failure = nil; self.needsAccess = false; self.restartAfterPermission = false
                    self.finishReconciliation(); self.onChange?()
                }
                else { self.removeRegistration() }
            } else if (self.registration == 1 || self.registration == 2) && (!self.preferences.bool(forKey: "scannerClientIdentityV2") || self.preferences.string(forKey: "scannerRegisteredAppBuild") != self.registrationIdentity) {
                self.restartRegistration()
            } else if self.registration == 2 {
                self.startTimer(); self.finishReconciliation()
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
            } else if self.registration == 2 {
                self.preferences.set(true, forKey: "scannerClientIdentityV2")
                self.preferences.set(self.registrationIdentity, forKey: "scannerRegisteredAppBuild")
                self.failure = nil; self.startTimer(); self.finishReconciliation()
            } else if let error = reply.error {
                self.failure = error; self.finishReconciliation()
            } else if self.registration == 1 {
                self.preferences.set(true, forKey: "scannerClientIdentityV2")
                self.preferences.set(self.registrationIdentity, forKey: "scannerRegisteredAppBuild")
                self.validateAccess()
            }
            else {
                self.failure = "macOS could not enable the folder reader"
                self.finishReconciliation()
            }
        }
    }
    private func removeRegistration() {
        run("unregister") { reply in
            self.registration = reply.status ?? self.registration
            if let error = reply.error {
                self.failure = error
                self.finishReconciliation()
            } else {
                self.failure = nil; self.needsAccess = false; self.restartAfterPermission = false
                self.retryAt = 0
                self.finishReconciliation()
                if !self.enabled { self.onChange?() }
            }
        }
    }
    private func validateAccess() {
        run("check") { reply in
            guard self.activeRevision == self.lifecycleRevision else { self.finishReconciliation(); return }
            self.needsAccess = reply.event == "access" && reply.status == 1
            self.failure = reply.event == "access" ? nil : (reply.error ?? "Could not connect to the folder reader")
            self.ready = reply.event == "access" && reply.status == 0
            if reply.event == "access" && reply.status != 0 && reply.status != 1 {
                self.failure = "The requested directory is unavailable or failed its safety checks"
                self.finishReconciliation()
            } else { self.finishReconciliation() }
        }
    }
    /// The preflight has not requested a measurement. Wait for this service's
    /// asynchronous removal before registering its bundled replacement, at most once.
    private func restartRegistration() {
        guard !busy, !uncertain else { finishReconciliation(); return }
        restartAfterPermission = false
        run("unregister") { reply in
            self.registration = reply.status ?? self.registration
            if let error = reply.error {
                self.failure = error
                self.finishReconciliation(); return
            }
            guard self.enabled, self.activeRevision == self.lifecycleRevision else {
                self.finishReconciliation(); return
            }
            self.registerForCurrentIntent()
        }
    }
    private func finishReconciliation() {
        reconciling = false
        if activeRevision != lifecycleRevision { reconcile(); return }
        onChange?()
        if ready {
            if last?.bytes == nil { last = nil; retryAt = 0 }
            onReady?()
        }
        let callbacks = lifecycleCallbacks; lifecycleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }
    func accessSettingsChanged(completion: @escaping () -> Void) {
        guard enabled, !busy, !uncertain else { completion(); return }
        // Approval polling may already be checking the newly approved service.
        // Join that check rather than exposing its temporary not-ready state.
        if reconciling { lifecycleCallbacks.append(completion); return }
        restartAfterPermission = needsAccess
        setEnabled(true, completion: completion)
    }
    var activity: String? {
        if uncertain { return "Scan completion unconfirmed · restart your Mac" }
        if busy { return cancelling ? "Stopping measurement…" : "Measuring folder…" }
        let remaining = max(0, Int(ceil(retryAt - now)))
        return remaining > 0 ? "Recent measurement · next scan in \(remaining)s" : nil
    }
    /// Caller owns the app's global scan slot. This never opens setup or requests approval.
    func measure(completion: @escaping (Measurement) -> Void) {
        guard enabled, ready, !busy, !uncertain, packageValid, registration == 1, failure == nil, !needsAccess else {
            completion(.failed("Folder access is required")); return
        }
        if now < retryAt, let last { completion(last); return }
        preferences.set(ScannerRecovery.bootSession() ?? "", forKey: pendingKey)
        guard preferences.synchronize() else {
            completion(.failed("Cannot save scanner recovery state; no measurement started")); return
        }
        busy = true; cancelling = false; uncertain = false; measuring = false
        self.completion = completion; measurementID = UUID()
        let token = measurementID
        started = now
        startTimer()
        run("measure") { reply in
            guard self.busy, self.measurementID == token else { return }
            switch reply.event {
            case "measuring": self.measuring = true; self.started = self.now
            case "result":
                guard let result = reply.measurement,
                      result.finishedAt.timeIntervalSince1970.isFinite,
                      result.finishedAt <= Date().addingTimeInterval(5),
                      result.bytes == nil || result.bytes! >= 0 else {
                    self.finish(.failed("Invalid scanner response; saved size kept")); return
                }
                self.finish(self.cancelling ? .failed("Measurement cancelled") : result)
            case "packageFailed", "launchFailed":
                self.failure = reply.error ?? "Could not connect to the folder reader"; self.ready = false; self.finish(.failed(self.failure!))
            case "uncertain", "bridgeExited":
                self.uncertain = true; self.onChange?()
            default: break
            }
        }
    }
    func cancel() {
        guard busy, !cancelling else { return }
        cancelling = true
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
        if result.bytes == nil {
            needsAccess = result.error?.contains("Full Disk Access") == true
            if needsAccess { ready = false }
        }
        onChange?()
        callback?(result)
        if lifecycleRevision != activeRevision || !enabled || !lifecycleCallbacks.isEmpty { reconcile() }
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func tick() {
        if busy || now < retryAt + 1 { onChange?() }
        if busy {
            if !measuring && now - started >= 15 {
                // Includes bridge startup; no claim that an unobserved request stopped.
                uncertain = true; onChange?()
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
