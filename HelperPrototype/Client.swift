import Cocoa
import ServiceManagement

@main final class Preview: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let label = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let primary = NSButton()
    let remove = NSButton(title: "Disable scanner", target: nil, action: nil)
    var connection: NSXPCConnection?
    var timer: Timer?
    var request = RequestState()
    var repairNeeded = false
    var repairAwaitingOff = false
    var cooldownUntil: TimeInterval = 0
    var busy = false
    var packageError: String?
    var needsAccess = false
    var stopping = false
    var returningFromSettings = false
    var statusTimer: Timer?
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var service: SMAppService { .daemon(plistName: HelperIdentity.serviceID + ".plist") }
    static func main() {
        if CommandLine.arguments.contains("--check-package") {
            do {
                try BundlePolicy.validate(at: Bundle.main.bundleURL)
                print("PASS: app and scanner package/signatures verified. No registration or scan performed.")
                return
            } catch { fputs("Package rejected: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let delegate = Preview()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disk Monitor Setup (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
        window.appearance = NSAppearance(named: .darkAqua)
        label.font = .boldSystemFont(ofSize: 19)
        detail.textColor = .secondaryLabelColor
        primary.target = self; primary.action = #selector(next)
        remove.target = self; remove.action = #selector(disable)
        let stack = NSStackView(views: [label, detail, primary, remove])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        do { try BundlePolicy.validate(at: Bundle.main.bundleURL) }
        catch { packageError = error.localizedDescription }
        showSetup()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            self.updateCooldown()
            guard self.returningFromSettings else { return }
            if self.service.status == .enabled && !self.needsAccess {
                self.returningFromSettings = false; self.showSetup()
            }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSetup() {
        guard !busy else { return }
        remove.isEnabled = service.status == .enabled || service.status == .requiresApproval
        primary.isEnabled = true
        if let packageError {
            label.stringValue = "Scanner package needs repair"
            detail.stringValue = packageError + ". No permission change will repair this package. No scan started."
            primary.title = "Unavailable"; primary.isEnabled = false
            return
        }
        if repairAwaitingOff {
            label.stringValue = "Renew background approval"
            detail.stringValue = "In System Settings → General → Login Items & Extensions, turn OFF only Disk Monitor Setup.app. Keep Full Disk Access unchanged. Then return here and choose ‘I turned it off’. Registration has been removed; no scan is running."
            primary.title = "I turned it off — register scanner"
            return
        }
        if repairNeeded {
            label.stringValue = "Scanner needs approval repair"
            detail.stringValue = "The scanner could not connect. After an update, macOS may retain approval for the previous executable. Repair removes this scanner’s registration and guides you through renewing its background approval. It does not change Full Disk Access or start a scan."
            primary.title = "Repair scanner after update…"
            return
        }
        if needsAccess {
            label.stringValue = "Allow access to the Spotlight index"
            detail.stringValue = "In System Settings → Privacy & Security → Full Disk Access, add this preview app and enable it. macOS grants broad disk access; this scanner only measures Spotlight. No passwords are stored. Then return here to verify access."
            primary.title = "Open Full Disk Access…"
            return
        }
        switch service.status {
        case .enabled:
            label.stringValue = "Verify the scanner"
            detail.stringValue = "Registration is enabled. The next step checks that the signed helper actually starts, then requests one read-only measurement. Large indexes can take up to 15 minutes. No files are changed or deleted."
            primary.title = "Verify and measure"
        case .requiresApproval:
            label.stringValue = "Approve the scanner in macOS"
            detail.stringValue = "Open Login Items & Extensions and allow this preview’s background scanner. Return here afterward; the next step appears when macOS reports approval."
            primary.title = "Open approval settings…"
        case .notRegistered, .notFound:
            label.stringValue = "Set up Spotlight measurement"
            detail.stringValue = "This isolated preview registers a background administrator helper. It accepts only a fixed Spotlight size check. You can remove it with Disable scanner. Full Disk Access may also be needed. No registration happens until you choose Enable."
            primary.title = "Enable scanner…"
        default:
            label.stringValue = "Scanner installation needs repair"
            detail.stringValue = "The helper is unavailable. Do not keep changing permissions. Disable the scanner and report this error; no measurement has started."
            primary.title = "Unavailable"; primary.isEnabled = false
        }
    }
    @objc func next() {
        guard !busy, packageError == nil else { return }
        if needsAccess {
            returningFromSettings = true
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            return
        }
        if repairNeeded { beginRepair(); return }
        if repairAwaitingOff {
            do {
                try service.register()
                guard service.status == .requiresApproval else {
                    detail.stringValue = "Background approval still appears enabled. Turn OFF Disk Monitor Setup.app in Login Items & Extensions before retrying. No measurement requested."
                    primary.isEnabled = false; remove.isEnabled = false
                    service.unregister { error in DispatchQueue.main.async {
                        self.primary.isEnabled = true
                        if let error { self.detail.stringValue = "Could not unregister scanner: " + error.localizedDescription }
                    } }
                    return
                }
                repairAwaitingOff = false
                returningFromSettings = true
                showSetup()
            } catch {
                if service.status == .requiresApproval {
                    repairAwaitingOff = false; returningFromSettings = true; showSetup()
                } else { detail.stringValue = "Registration failed: " + error.localizedDescription + ". No scan started." }
            }
            return
        }
        switch service.status {
        case .enabled: measure()
        case .requiresApproval:
            returningFromSettings = true; SMAppService.openSystemSettingsLoginItems()
        case .notRegistered, .notFound:
            guard BundlePolicy.canRegister(status: service.status.rawValue, packageValid: packageError == nil) else { return }
            do { try service.register(); showSetup() }
            catch {
                showSetup()
                if service.status != .requiresApproval {
                    label.stringValue = "Registration failed"
                    detail.stringValue = error.localizedDescription + " No scan started."
                }
            }
        default: showSetup()
        }
    }
    func updateCooldown() {
        guard !busy, !repairNeeded, !repairAwaitingOff, !needsAccess, cooldownUntil > 0 else { return }
        let seconds = max(0, Int(ceil(cooldownUntil - now)))
        primary.isEnabled = seconds == 0
        primary.title = seconds > 0 ? "Measure again in \(seconds)s" : "Verify and measure"
        if seconds == 0 { cooldownUntil = 0 }
    }
    func beginRepair() {
        guard !busy else { return }
        primary.isEnabled = false; remove.isEnabled = false
        service.unregister { error in DispatchQueue.main.async {
            if let error {
                self.detail.stringValue = "Could not unregister scanner: " + error.localizedDescription
                self.primary.isEnabled = true; self.remove.isEnabled = true
                return
            }
            self.repairNeeded = false; self.repairAwaitingOff = true
            self.cooldownUntil = 0; self.showSetup()
            SMAppService.openSystemSettingsLoginItems()
        } }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if returningFromSettings && needsAccess {
            returningFromSettings = false; needsAccess = false; showSetup()
        }
    }
    func finish(_ title: String, _ message: String, access: Bool = false) {
        request.finish(); timer?.invalidate(); timer = nil
        connection?.invalidate(); connection = nil
        busy = false; stopping = false; needsAccess = access
        remove.title = "Disable scanner"
        primary.isEnabled = true; remove.isEnabled = service.status != .notRegistered
        primary.title = access ? "Open Full Disk Access…" : "Verify and measure"
        label.stringValue = title; detail.stringValue = message
    }
    @objc func disable() {
        if busy {
            guard !stopping, let connection else { return }
            stopping = true; remove.isEnabled = false
            label.stringValue = "Stopping measurement…"
            detail.stringValue = "Cancellation requested. Waiting for the owned scan to stop; no partial size will be saved."
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? SpotlightService
            proxy?.cancel { _ in } // Only the measure reply confirms the scan exited.
            return
        }
        primary.isEnabled = false; remove.isEnabled = false
        service.unregister { error in DispatchQueue.main.async {
            if error == nil { self.repairNeeded = false; self.repairAwaitingOff = false; self.cooldownUntil = 0 }
            self.finish(error == nil ? "Scanner unregistered" : "Could not remove scanner", error?.localizedDescription ?? "Background registration removed. You can close this preview. Full Disk Access can be revoked separately in System Settings.")
            self.primary.title = "Enable scanner…"
        } }
    }
    func measure() {
        guard !busy, !repairNeeded, !repairAwaitingOff, now >= cooldownUntil, service.status == .enabled else { return }
        busy = true; primary.isEnabled = false; remove.isEnabled = false
        let id = request.begin(now: now)
        let c = NSXPCConnection(machServiceName: HelperIdentity.serviceID, options: .privileged)
        c.setCodeSigningRequirement(HelperIdentity.requirement(HelperIdentity.serviceID))
        c.remoteObjectInterface = NSXPCInterface(with: SpotlightService.self)
        let disconnected = { [weak self] in DispatchQueue.main.async {
            guard let self, self.request.accepts(id) else { return }
            self.finish("Scanner connection lost", "No complete size received. Disable the scanner before retrying; a disconnected scan may still be stopping.")
        } }
        c.interruptionHandler = disconnected; c.invalidationHandler = disconnected
        c.resume(); connection = c
        label.stringValue = "Starting scanner…"
        detail.stringValue = "Checking the signed helper. This must respond within 10 seconds; no scan has been requested."
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.request.accepts(id) else { return }
            if self.request.expired(now: self.now) {
                let connecting = self.request.phase == .connecting
                self.finish(connecting ? "Scanner could not start" : "Scanner stopped responding", connecting ? "No scan was requested. Disable the scanner and report this error. Changing disk permissions will not repair a launch failure." : "No complete size received within the scan deadline. Disable the scanner before retrying; do not treat this as zero usage.")
                if connecting { self.repairNeeded = true; self.showSetup() }
                return
            }
            if self.request.phase == .waiting && !self.stopping {
                let elapsed = Int(self.now - self.request.started)
                self.detail.stringValue = "Helper connected; measurement requested. \(elapsed / 60)m \(elapsed % 60)s elapsed. Scan budget: 15 minutes. No partial size is saved."
            }
        }
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in disconnected() } as! SpotlightService
        proxy.ping { version in DispatchQueue.main.async {
            guard self.request.accepts(id) else { return }
            guard version == 1 else { self.finish("Incompatible scanner", "Disable the scanner before replacing this preview."); return }
            guard self.request.connected(id, now: self.now) else { return }
            self.label.stringValue = "Measuring Spotlight"
            self.remove.title = "Cancel measurement"; self.remove.isEnabled = true
            proxy.measure { data in DispatchQueue.main.async {
                guard self.request.accepts(id) else { return }
                guard data.count < 1024, let result = try? JSONDecoder().decode(Measurement.self, from: data) else { self.finish("Invalid scanner response", "No size saved."); return }
                if let bytes = result.bytes {
                    guard bytes >= 0 else { self.finish("Invalid scanner response", "No size saved."); return }
                    self.cooldownUntil = self.now + max(0, min(60, 60 - Date().timeIntervalSince(result.finishedAt)))
                    self.finish("Measurement complete", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) + " • " + result.finishedAt.formatted() + ". Measurements are limited to one per minute. You can close this preview or disable its scanner.")
                    self.updateCooldown()
                } else {
                    let message = result.error ?? "No size returned"
                    self.finish(message == "Measurement cancelled" ? "Measurement cancelled" : "Measurement failed", message, access: message.contains("Full Disk Access"))
                }
            } }
        } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
