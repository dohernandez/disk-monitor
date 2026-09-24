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
    var busy = false
    var needsAccess = false
    var returningFromSettings = false
    var statusTimer: Timer?
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var service: SMAppService { .daemon(plistName: HelperIdentity.serviceID + ".plist") }
    static func main() {
        let delegate = Preview()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Disk Monitor — helper setup preview"
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
        showSetup()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.returningFromSettings, !self.busy else { return }
            if self.service.status == .enabled && !self.needsAccess {
                self.returningFromSettings = false; self.showSetup()
            }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSetup() {
        guard !busy else { return }
        remove.isEnabled = service.status != .notRegistered
        primary.isEnabled = true
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
        case .notRegistered:
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
        guard !busy else { return }
        if needsAccess {
            returningFromSettings = true
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            return
        }
        switch service.status {
        case .enabled: measure()
        case .requiresApproval:
            returningFromSettings = true; SMAppService.openSystemSettingsLoginItems()
        case .notRegistered:
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
    func applicationDidBecomeActive(_ notification: Notification) {
        if returningFromSettings && needsAccess {
            returningFromSettings = false; needsAccess = false; showSetup()
        }
    }
    func finish(_ title: String, _ message: String, access: Bool = false) {
        request.finish(); timer?.invalidate(); timer = nil
        connection?.invalidate(); connection = nil
        busy = false; needsAccess = access
        primary.isEnabled = true; remove.isEnabled = service.status != .notRegistered
        primary.title = access ? "Open Full Disk Access…" : "Verify and measure"
        label.stringValue = title; detail.stringValue = message
    }
    @objc func disable() {
        guard !busy else { return }
        primary.isEnabled = false; remove.isEnabled = false
        service.unregister { error in DispatchQueue.main.async {
            self.finish(error == nil ? "Scanner unregistered" : "Could not remove scanner", error?.localizedDescription ?? "Background registration removed. You can close this preview. Full Disk Access can be revoked separately in System Settings.")
            self.primary.title = "Enable scanner…"
        } }
    }
    func measure() {
        guard !busy, service.status == .enabled else { return }
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
                return
            }
            if self.request.phase == .waiting {
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
            proxy.measure { data in DispatchQueue.main.async {
                guard self.request.accepts(id) else { return }
                guard data.count < 1024, let result = try? JSONDecoder().decode(Measurement.self, from: data) else { self.finish("Invalid scanner response", "No size saved."); return }
                if let bytes = result.bytes {
                    guard bytes >= 0 else { self.finish("Invalid scanner response", "No size saved."); return }
                    self.finish("Measurement complete", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) + " • " + result.finishedAt.formatted() + ". You can close this preview or disable its scanner.")
                } else {
                    let message = result.error ?? "No size returned"
                    self.finish("Measurement failed", message, access: message.contains("Full Disk Access"))
                }
            } }
        } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
