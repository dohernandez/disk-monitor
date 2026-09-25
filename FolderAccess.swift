import Cocoa
import ServiceManagement

/// The access and measurement flow for every tracked folder. Native macOS prompts
/// result from accessing the requested data; no custom setup windows are created.
final class FolderAccess {
    enum Check: Equatable { case available, permissionRequired, failed(String) }
    enum Requirement: Equatable { case fileAccess, backgroundApproval, failed(String) }
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
    private var activationObserver: NSObjectProtocol?
    var onGranted: (([Root]) -> Void)?
    var onChange: (() -> Void)?
    var permissionRequests: [Root] {
        pending.values.filter { requirements[$0.path] == .fileAccess || requirements[$0.path] == .backgroundApproval }.sorted { $0.title < $1.title }
    }
    var uncertain: Bool { reader.uncertain }
    var busy: Bool { reader.busy }
    func activity(for root: Root) -> String? { PrivilegedFolderReader.supports(root.path) ? reader.activity : nil }
    init(preferences: UserDefaults = .standard, reader: PrivilegedFolderReader? = nil,
         probe: @escaping (String) -> Check = FolderAccess.checkDirectory) {
        self.reader = reader ?? PrivilegedFolderReader(preferences: preferences)
        self.probe = probe
        self.reader.onReady = { [weak self] in
            guard let self else { return }
            let ready = self.pending.values.filter { PrivilegedFolderReader.supports($0.path) }
            for root in ready { self.pending.removeValue(forKey: root.path); self.requirements.removeValue(forKey: root.path); self.failedBeforeScan.remove(root.path) }
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
        reader.setEnabled(roots.contains { PrivilegedFolderReader.supports($0.path) }) {
            self.prepare(checkingAccess ? roots : roots.filter { PrivilegedFolderReader.supports($0.path) }, requestIfNeeded: false) { _ in completion() }
        }
    }
    func cancel(_ path: String) { failedBeforeScan.remove(path); revisions[path, default: 0] += 1; pending.removeValue(forKey: path); requirements.removeValue(forKey: path) }
    func cancelPending() { for path in Array(revisions.keys) { cancel(path) }; pending.removeAll() }
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
            func finish(_ requirement: Requirement?) {
                guard self.revisions[root.path] == tokens[root.path] else { next(index + 1); return }
                if case .failed = requirement { self.failedBeforeScan.insert(root.path) }
                else { self.failedBeforeScan.remove(root.path) }
                if let requirement { self.requirements[root.path] = requirement; self.pending[root.path] = root }
                else { self.requirements.removeValue(forKey: root.path); self.pending.removeValue(forKey: root.path); allowed.append(root) }
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
    private func privilegedRequirement() -> Requirement? {
        if reader.canAutomaticallyMeasure { return nil }
        if reader.registration == 2 { return .backgroundApproval }
        if reader.needsAccess { return .fileAccess }
        return .failed(reader.failure ?? (reader.uncertain ? "Previous scan completion is unconfirmed; restart your Mac" : "Folder reader is unavailable"))
    }
    /// Called with the app's single scan slot held. No UI, shell or arbitrary
    /// privileged path is exposed to the model or its scan loop.
    func measure(_ root: Root, scanner: Scanner, completion: @escaping (Result) -> Void) {
        failedBeforeScan.remove(root.path)
        if PrivilegedFolderReader.supports(root.path) {
            reader.measure { value in
                if value.error != nil, value.error != "Measurement cancelled", let requirement = self.privilegedRequirement() {
                    self.requirements[root.path] = requirement; self.pending[root.path] = root; self.onChange?()
                }
                let error = value.error == "Measurement cancelled" ? "Cancelled" : value.error
                completion(Result(scan: ScanResult(values: value.bytes.map { [root.path: $0] } ?? [:], error: error), date: value.finishedAt, elevated: true))
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                let result = scanner.scan(root.path)
                DispatchQueue.main.async { completion(Result(scan: result, date: Date())) }
            }
        }
    }
    func reportDenied(_ root: Root) { pending[root.path] = root; requirements[root.path] = .fileAccess; onChange?() }
    func openSettings(for root: Root) {
        willOpenSettings()
        if requirements[root.path] == .backgroundApproval { SMAppService.openSystemSettingsLoginItems() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    }
    func willOpenSettings() { waitingForSettings = true }
    func returnedFromSettings() {
        guard waitingForSettings else { return }; waitingForSettings = false
        let roots = Array(pending.values)
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
                }
                self.onChange?()
            }
        }
        prepare(ordinary, requestIfNeeded: true) { [weak self] allowed in
            if !allowed.isEmpty { self?.onGranted?(allowed) }
        }
    }
}
