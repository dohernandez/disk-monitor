import Cocoa

/// One gate for every folder. Unknown errors are not permission denials.
final class FolderAccess {
    enum Check: Equatable { case available, permissionRequired, failed(String) }
    private let spotlight: SpotlightAccess
    private let probe: (String) -> Check
    private var deniedPaths: [String: [String]] = [:]
    private var pending: [String: Root] = [:]
    private var revisions: [String: Int] = [:]
    var onGranted: (([Root]) -> Void)?
    init(spotlight: SpotlightAccess, probe: @escaping (String) -> Check = FolderAccess.checkDirectory) {
        self.spotlight = spotlight; self.probe = probe
        spotlight.onReady = { [weak self] in
            guard let self else { return }
            if let root = self.pending.removeValue(forKey: SpotlightMeasurement.path) { self.onGranted?([root]) }
            self.recheckPending()
        }
        spotlight.onGeneralPermissionReturn = { [weak self] in
            guard let self else { return }
            self.recheckPending()
            if self.spotlight.enabled && !self.spotlight.canAutomaticallyMeasure { self.spotlight.checkSetup() }
        }
    }
    static func checkDirectory(_ path: String) -> Check {
        guard let directory = opendir(path) else {
            let code = errno
            return code == EACCES || code == EPERM ? .permissionRequired : .failed(String(cString: strerror(code)))
        }
        closedir(directory)
        return .available
    }
    func cancel(_ path: String) { revisions[path, default: 0] += 1; pending.removeValue(forKey: path) }
    func cancelPending() { for path in Array(revisions.keys) { cancel(path) }; pending.removeAll() }
    func prepare(_ roots: [Root], requestIfNeeded: Bool, completion: @escaping ([Root]) -> Void) {
        var allowed: [Root] = []
        let tokens = Dictionary(roots.map { root in
            if revisions[root.path] == nil { revisions[root.path] = 0 }
            return (root.path, revisions[root.path]!)
        }, uniquingKeysWith: { first, _ in first })
        func next(_ index: Int) {
            guard index < roots.count else { completion(allowed); return }
            let root = roots[index]
            func finish(_ available: Bool) {
                guard self.revisions[root.path] == tokens[root.path] else { next(index + 1); return }
                if available { allowed.append(root); self.pending.removeValue(forKey: root.path) }
                next(index + 1)
            }
            guard self.revisions[root.path] == tokens[root.path] else { next(index + 1); return }
            if root.path == SpotlightMeasurement.path {
                if self.spotlight.canAutomaticallyMeasure { finish(true) }
                else {
                    self.pending[root.path] = root
                    if requestIfNeeded { self.spotlight.setEnabled(true) { finish(self.spotlight.canAutomaticallyMeasure) } }
                    else { finish(false) }
                }
                return
            }
            let paths = self.deniedPaths[root.path] ?? [root.path]
            DispatchQueue.global(qos: .utility).async {
                let checks = paths.map(self.probe)
                DispatchQueue.main.async {
                    guard self.revisions[root.path] == tokens[root.path] else { finish(false); return }
                    if checks.allSatisfy({ $0 == .available }) {
                        self.deniedPaths.removeValue(forKey: root.path); finish(true)
                    } else {
                        if checks.contains(.permissionRequired) {
                            self.pending[root.path] = root
                            if requestIfNeeded { self.spotlight.openGeneralAccess(for: root.title) }
                        }
                        finish(false)
                    }
                }
            }
        }
        next(0)
    }
    /// Descendant permissions are discovered by the scan; recheck those exact
    /// directories before resuming, rather than assuming an accessible root is enough.
    func reportDenied(_ root: Root, paths: [String], requestIfNeeded: Bool) {
        deniedPaths[root.path] = paths.isEmpty ? [root.path] : paths
        pending[root.path] = root
        if requestIfNeeded { spotlight.openGeneralAccess(for: root.title) }
    }
    private func recheckPending() {
        let roots = Array(pending.values).filter { $0.path != SpotlightMeasurement.path }
        prepare(roots, requestIfNeeded: false) { [weak self] allowed in
            guard let self, !allowed.isEmpty else { return }
            self.spotlight.closeGeneralAccess()
            self.onGranted?(allowed)
        }
    }
}
