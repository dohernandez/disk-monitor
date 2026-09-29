import Cocoa
import ServiceManagement

/// The access and measurement flow for every tracked folder. Native macOS prompts
/// result from accessing the requested data; no custom setup windows are created.
final class FolderAccess {
    enum Check: Equatable { case available, permissionRequired, failed(String) }
    enum Requirement: Equatable { case fileAccess, backgroundApproval, failed(String) }
    enum Activity: Equatable {
        case checking, ready, connecting, scanning, verified(Date), stopped, attention(String)
        var priority: Int {
            switch self {
            case .attention: return 0
            case .scanning: return 1
            case .connecting: return 2
            case .checking: return 3
            case .ready: return 4
            case .stopped: return 5
            case .verified: return 6
            }
        }
        var title: String {
            switch self {
            case .checking: return "Checking folder access…"
            case .ready: return "Access check passed"
            case .connecting: return "Connecting to folder reader…"
            case .scanning: return "Scan in progress"
            case .verified: return "Scan succeeded · access verified"
            case .stopped: return "Scan stopped"
            case .attention: return "Folder access needs attention"
            }
        }
        var detail: String {
            switch self {
            case .checking: return "Testing access for this app session."
            case .ready: return "Folder is readable; a complete scan has not yet been verified."
            case .connecting: return "Waiting for the reader to respond; scanning is not yet confirmed."
            case .scanning: return "Scan result pending; complete access is not yet verified."
            case .verified(let date): return "Successful scan at " + date.formatted(date: .omitted, time: .shortened) + "."
            case .stopped: return "This scan did not verify complete folder access."
            case .attention(let reason): return reason
            }
        }
    }
    struct Observation: Identifiable {
        let root: Root
        let activity: Activity
        var id: String { root.path }
    }
    // Current-session evidence only. Saved sizes and macOS toggle state cannot prove access.
    private var observations: [String: Observation] = [:]
    func accessObservations(for roots: [Root]) -> [Observation] {
        observations.values.filter { observation in
            roots.contains { observation.id == $0.path || observation.id.hasPrefix($0.path + "/") }
        }.map { observation in
            if PrivilegedFolderReader.supports(observation.id), reader.uncertain {
                return Observation(root: observation.root, activity: .attention("Scanner connection or completion is unconfirmed. Restart your Mac before retrying."))
            }
            return observation
        }.sorted {
            $0.activity.priority == $1.activity.priority ? $0.root.title < $1.root.title : $0.activity.priority < $1.activity.priority
        }
    }
    private func observe(_ root: Root, _ activity: Activity, protected: Bool = false) {
        guard protected || observations[root.path] != nil || PrivilegedFolderReader.supports(root.path)
                || root.path.hasSuffix("/Library/Caches") else { return }
        observations[root.path] = Observation(root: root, activity: activity)
        onChange?()
    }
    struct Result {
        var scan: ScanResult
        var date: Date
        var elevated: Bool = false
    }
    private let reader: PrivilegedFolderReader
    private let probe: (String) -> Check
    private var pending: [String: Root] = [:]
    private var revisions: [String: Int] = [:]
    private(set) var failedBeforeScan: Set<String> = []
    private(set) var requirements: [String: Requirement] = [:]
    private var waitingForSettings = false
    private var reviewingFullDiskAccess = false
    private var fullDiskAccessReviewPaths: Set<String> = []
    static let fullDiskAccessInstructions = "Allow Disk Monitor in Full Disk Access. If macOS offers Quit & Reopen, choose it. If access is still blocked and macOS did not restart the app, quit Disk Monitor using the power button, then open it again. Access is checked at startup; some system restrictions may still apply."
    static let restartAdvice = "If you enabled Full Disk Access, quit and reopen Disk Monitor to apply it, then retry. Use macOS’s Quit & Reopen if offered, or the app’s power button to quit."
    func restartGuidance(for path: String) -> String? {
        guard fullDiskAccessReviewPaths.contains(path) else { return nil }
        switch requirements[path] {
        case .fileAccess, .failed: return Self.restartAdvice
        default: return nil
        }
    }
    private var activationObserver: NSObjectProtocol?
    var onGranted: (([Root]) -> Void)?
    var onChange: (() -> Void)?
    var permissionRequests: [Root] {
        pending.values.filter { requirements[$0.path] == .fileAccess || requirements[$0.path] == .backgroundApproval }.sorted { $0.title < $1.title }
    }
    struct PermissionGroup: Identifiable {
        let requirement: Requirement
        let roots: [Root]
        var id: String { requirement == .backgroundApproval ? "backgroundApproval" : "fileAccess" }
    }
    var permissionGroups: [PermissionGroup] {
        let requests = permissionRequests
        return [Requirement.backgroundApproval, .fileAccess].compactMap { requirement in
            let roots = requests.filter { requirements[$0.path] == requirement }
            return roots.isEmpty ? nil : PermissionGroup(requirement: requirement, roots: roots)
        }
    }
    var uncertain: Bool { reader.uncertain }
    var busy: Bool { reader.busy }
    init(preferences: UserDefaults = .standard, reader: PrivilegedFolderReader? = nil,
         probe: @escaping (String) -> Check = FolderAccess.checkDirectory) {
        self.reader = reader ?? PrivilegedFolderReader(preferences: preferences)
        self.probe = probe
        self.reader.onReady = { [weak self] in
            guard let self else { return }
            let ready = self.pending.values.filter { PrivilegedFolderReader.supports($0.path) }
            for root in ready { self.pending.removeValue(forKey: root.path); self.requirements.removeValue(forKey: root.path); self.failedBeforeScan.remove(root.path); self.fullDiskAccessReviewPaths.remove(root.path) }
            for root in ready { self.observe(root, .ready) }
            if !ready.isEmpty { self.onGranted?(Array(ready)) }
            self.onChange?()
        }
        self.reader.onChange = { [weak self] in self?.onChange?() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.returnedFromSettings() }
    }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    static func checkDirectory(_ path: String) -> Check {
        func readable(_ directoryPath: String) -> Check {
            guard let directory = opendir(directoryPath) else {
                let code = errno
                return code == EACCES || code == EPERM ? .permissionRequired : .failed(String(cString: strerror(code)))
            }
            defer { closedir(directory) }
            errno = 0
            _ = readdir(directory)
            let code = errno
            if code != 0 { return code == EACCES || code == EPERM ? .permissionRequired : .failed(String(cString: strerror(code))) }
            return .available
        }
        let root = readable(path)
        guard root == .available else { return root }
        // Library/Caches itself can be readable while protected cache directories
        // beneath it are not. Probe immediate directories, without walking their trees.
        if path.hasSuffix("/Library/Caches") {
            do {
                let children = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath:path), includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                for child in children {
                    let values = try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true {
                        let check = readable(child.path)
                        if check != .available { return check }
                    }
                }
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError { return .permissionRequired }
                return .failed(error.localizedDescription)
            }
        }
        return .available
    }
    /// Startup and tracking changes reconcile resource ownership, not a second toggle.
    func synchronize(_ roots: [Root], checkingAccess: Bool = false, completion: @escaping () -> Void = {}) {
        if checkingAccess { for root in roots where !PrivilegedFolderReader.supports(root.path) { cancel(root.path) } }
        for root in roots where checkingAccess || PrivilegedFolderReader.supports(root.path) { observe(root, .checking) }
        reader.setEnabled(roots.contains { PrivilegedFolderReader.supports($0.path) }) {
            self.prepare(checkingAccess ? roots : roots.filter { PrivilegedFolderReader.supports($0.path) }, requestIfNeeded: false) { _ in completion() }
        }
    }
    func cancel(_ path: String) { observations.removeValue(forKey: path); fullDiskAccessReviewPaths.remove(path); failedBeforeScan.remove(path); revisions[path, default: 0] += 1; pending.removeValue(forKey: path); requirements.removeValue(forKey: path) }
    func cancelPending() {
        let previous = observations
        for path in Array(revisions.keys) { cancel(path) }; pending.removeAll()
        // Cancelling requests cannot turn an unconfirmed operation into successful access.
        // Keep its evidence visible; untracked roots are filtered at presentation time.
        observations = previous.mapValues { observation in
            switch observation.activity {
            case .checking, .connecting, .scanning: return Observation(root: observation.root, activity: .stopped)
            default: return observation
            }
        }
        onChange?()
    }
    func cancelMeasurement() { reader.cancel() }
    func prepare(_ roots: [Root], requestIfNeeded: Bool, onChecking: @escaping (Root) -> Void = { _ in }, completion: @escaping ([Root]) -> Void) {
        var allowed: [Root] = []
        let tokens = Dictionary(roots.map { root in
            if revisions[root.path] == nil { revisions[root.path] = 0 }
            return (root.path, revisions[root.path]!)
        }, uniquingKeysWith: { first, _ in first })
        func next(_ index: Int) {
            guard index < roots.count else { self.onChange?(); completion(allowed); return }
            let root = roots[index]
            guard self.revisions[root.path] == tokens[root.path] else { next(index + 1); return }
            onChecking(root)
            if PrivilegedFolderReader.supports(root.path) || requestIfNeeded || self.pending[root.path] == nil { self.observe(root, .checking) }
            func finish(_ requirement: Requirement?) {
                guard self.revisions[root.path] == tokens[root.path] else { next(index + 1); return }
                if case .failed = requirement { self.failedBeforeScan.insert(root.path) }
                else { self.failedBeforeScan.remove(root.path) }
                if let requirement { self.requirements[root.path] = requirement; self.pending[root.path] = root }
                else { self.requirements.removeValue(forKey: root.path); self.pending.removeValue(forKey: root.path); self.fullDiskAccessReviewPaths.remove(root.path); allowed.append(root) }
                self.observeRequirement(root, requirement)
                next(index + 1)
            }
            // Capability selection is internal; both readers return to this same gate.
            if PrivilegedFolderReader.supports(root.path) {
                if self.reader.canAutomaticallyMeasure { finish(nil) }
                else if requestIfNeeded {
                    self.reader.setEnabled(true) { finish(self.privilegedRequirement()) }
                } else { finish(self.privilegedRequirement()) }
            } else {
                if !requestIfNeeded, self.pending[root.path] != nil { next(index + 1); return }
                DispatchQueue.global(qos: .utility).async {
                    let check = self.probe(root.path)
                    DispatchQueue.main.async {
                        switch check {
                        case .available: finish(nil)
                        case .permissionRequired: finish(.fileAccess)
                        case .failed(let error): finish(.failed(error))
                        }
                    }
                }
            }
        }
        next(0)
    }
    private func observeRequirement(_ root: Root, _ requirement: Requirement?) {
        switch requirement {
        case .fileAccess: observe(root, .attention("Full Disk Access is required. If already enabled, quit and reopen Disk Monitor, then retry."), protected: true)
        case .backgroundApproval: observe(root, .attention("Background approval is required in Login Items & Extensions."), protected: true)
        case .failed(let error): observe(root, .attention(error + " If permissions are enabled, quit and reopen Disk Monitor, then retry."))
        case nil: observe(root, .ready)
        }
    }
    private func privilegedRequirement() -> Requirement? {
        if reader.canAutomaticallyMeasure { return nil }
        if reader.needsBackgroundApproval { return .backgroundApproval }
        if reader.needsAccess { return .fileAccess }
        return .failed(reader.failure ?? (reader.uncertain ? "Previous scan completion is unconfirmed; restart your Mac" : "Folder reader is unavailable"))
    }
    /// Called with the app's single scan slot held. No UI, shell or arbitrary
    /// privileged path is exposed to the model or its scan loop.
    func measure(_ root: Root, scanner: Scanner, completion: @escaping (Result) -> Void) {
        failedBeforeScan.remove(root.path)
        func finish(_ result: Result) {
            if result.scan.error == "Cancelled" { self.observe(root, .stopped) }
            else if let error = result.scan.error { self.observe(root, .attention(error)) }
            else if result.scan.values[root.path] != nil { self.observe(root, .verified(result.date)) }
            else { self.observe(root, .attention("No complete folder measurement was returned.")) }
            completion(result)
        }
        if PrivilegedFolderReader.supports(root.path) {
            observe(root, .connecting)
            reader.measure(onStarted: { [weak self] in self?.observe(root, .scanning) }) { value in
                if value.error != nil, value.error != "Measurement cancelled", let requirement = self.privilegedRequirement() {
                    self.requirements[root.path] = requirement; self.pending[root.path] = root; self.onChange?()
                }
                let error = value.error == "Measurement cancelled" ? "Cancelled" : value.error
                finish(Result(scan: ScanResult(values: value.bytes.map { [root.path: $0] } ?? [:], error: error), date: value.finishedAt, elevated: true))
            }
        } else {
            observe(root, .scanning)
            DispatchQueue.global(qos: .utility).async {
                let result = scanner.scan(root.path)
                DispatchQueue.main.async { finish(Result(scan: result, date: Date())) }
            }
        }
    }
    func reportDenied(_ root: Root) { pending[root.path] = root; requirements[root.path] = .fileAccess; observeRequirement(root, .fileAccess); onChange?() }
    func openSettings(for root: Root) {
        willOpenSettings(fullDiskAccess: requirements[root.path] != .backgroundApproval)
        if requirements[root.path] == .backgroundApproval { SMAppService.openSystemSettingsLoginItems() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    }
    func willOpenSettings(fullDiskAccess: Bool = false) {
        waitingForSettings = true
        reviewingFullDiskAccess = fullDiskAccess
    }
    func returnedFromSettings() {
        guard waitingForSettings else { return }; waitingForSettings = false
        let roots = Array(pending.values)
        // Settings is not an approval API. Remember only that FDA was reviewed,
        // never infer that it was granted or that a restart is definitely required.
        if reviewingFullDiskAccess { fullDiskAccessReviewPaths.formUnion(roots.map(\.path)) }
        reviewingFullDiskAccess = false
        for root in roots { observe(root, .checking) }
        onChange?()
        let ordinary = roots.filter { !PrivilegedFolderReader.supports($0.path) }
        // The reader's onReady callback owns resuming elevated requests exactly once.
        // Do not submit them again through the settings-return completion.
        if roots.contains(where: { PrivilegedFolderReader.supports($0.path) }) {
            reader.accessSettingsChanged { [weak self] in
                guard let self else { return }
                for root in roots where PrivilegedFolderReader.supports(root.path) && self.pending[root.path] != nil {
                    let requirement = self.privilegedRequirement()
                    self.requirements[root.path] = requirement
                    if case .failed = requirement { self.failedBeforeScan.insert(root.path) }
                    else { self.failedBeforeScan.remove(root.path) }
                    self.observeRequirement(root, requirement)
                }
                self.onChange?()
            }
        }
        prepare(ordinary, requestIfNeeded: true) { [weak self] allowed in
            if !allowed.isEmpty { self?.onGranted?(allowed) }
        }
    }
}
