import Cocoa
import SwiftUI

enum PrivateReadings {
    static func protect(_ url: URL, directory: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else {
            if !directory && errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              directory ? (info.st_mode & S_IFMT) == S_IFDIR : ((info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1),
              fchmod(fd, directory ? 0o700 : 0o600) == 0 else {
            throw NSError(domain: "PrivateReadings", code: 1)
        }
    }
    static func prepare(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try protect(parent, directory: true)
        try protect(url, directory: false)
    }
    static func write(_ data: Data, to url: URL) throws {
        try prepare(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".readings-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

func launchDiagnostic(_ phase:String,_ item:NSStatusItem?=nil) {
    guard CommandLine.arguments.contains("--diagnostics") else {return}
    var fields:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"time":Date().description,"policy":NSApp.activationPolicy().rawValue]
    if let item=item {
        fields["visible"]=item.isVisible;fields["length"]=item.length
        fields["button"]=item.button != nil;fields["image"]=item.button?.image != nil
        fields["frame"]=item.button?.window.map {NSStringFromRect($0.frame)} ?? "none"
        fields["screen"]=item.button?.window?.screen.map {NSStringFromRect($0.frame)} ?? "none"
    }
    if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]),let line=String(data:data,encoding:.utf8) {
        let url=URL(fileURLWithPath:"/tmp/DiskMonitor-launch-diagnostic.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
        if let file=try? FileHandle(forWritingTo:url) {file.seekToEndOfFile();file.write(Data((line+"\n").utf8));try? file.close()}
    }
}


enum Palette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive(0xF6F7F9, 0x292D32)
    static let surface = adaptive(0xFFFFFF, 0x32373D)
    static let primary = adaptive(0x17212B, 0xD9DFE5)
    static let secondary = adaptive(0x515B66, 0xADB7C2)
    static let accent = adaptive(0x00685F, 0x83BDB0)
    static let warning = adaptive(0x934600, 0xDEB278)
    static let uncertainty = adaptive(0x806000, 0xE8CE72)
    static let critical = adaptive(0xB42318, 0xE68D89)
    static let button = Color(red: 0, green: 104.0 / 255, blue: 95.0 / 255)
}

func intervalText(_ seconds: Int) -> String { seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s" }
func sizeText(_ bytes: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .binary; f.allowedUnits = [.useGB, .useMB, .useKB]; return f.string(fromByteCount: bytes)
}
struct Reading: Codable { var bytes: Int64; var previous: Int64?; var date: Date; var incomplete: Bool? = nil; var scanError: String? = nil; var protectedOnly: Bool? = nil; var administratorMeasured: Bool? = nil; var missing: Bool? = nil }
struct Root: Codable, Identifiable { var path: String; var title: String; var id: String { path } }
struct Saved: Codable { var readings: [String: Reading]; var extras: [Root]; var projectPath: String? = nil; var excludedPaths: [String]? = nil; var projects: [Root]? = nil; var customCaches: [Root]? = nil; var largestCount: Int? = nil }
struct DiskAlert: Identifiable {
    let id: String
    let critical: Bool
    let title: String
    let detail: String
    let path: String?
    var measurementIssue = false
    var badgeLevel:Int {critical ? 3 : measurementIssue ? 1 : 2}
    var color:Color {critical ? Palette.critical : measurementIssue ? Palette.uncertainty : Palette.warning}
    var symbol:String {measurementIssue ? "questionmark.circle.fill" : "exclamationmark.circle.fill"}
}
func diskBadgeLevel(_ alerts:[DiskAlert])->Int {alerts.map(\.badgeLevel).max() ?? 0}

let gib: Int64 = 1_073_741_824
struct SpaceThresholds {
    var critical = 10
    var warning = 20
    static func valid(critical: Int, warning: Int) -> Bool { critical >= 1 && critical < warning && warning <= 100 }
    func bytes(_ percent: Int, capacity: Int64) -> Int64 {
        let total = max(0, capacity)
        return (total / 100) * Int64(percent) + (total % 100) * Int64(percent) / 100
    }
    func label(_ percent: Int, capacity: Int64) -> String {
        capacity > 0 ? "\(percent)% · \(sizeText(bytes(percent, capacity: capacity)))" : "\(percent)% · capacity unavailable"
    }
}
func diskSpaceAlert(free: Int64, capacity: Int64, thresholds: SpaceThresholds = SpaceThresholds()) -> DiskAlert? {
    guard capacity > 0 else { return DiskAlert(id: "space-unknown", critical: false, title: "Disk space unavailable", detail: "The latest free-space check failed. Try refreshing.", path: nil, measurementIssue: true) }
    let percent = Double(free) / Double(capacity) * 100
    guard percent < Double(thresholds.warning) else { return nil }
    let critical = percent < Double(thresholds.critical)
    return DiskAlert(id: "space", critical: critical, title: critical ? "Critically low disk space" : "Disk space running low", detail: "\(sizeText(free)) free · warning below \(thresholds.label(thresholds.warning, capacity: capacity)), critical below \(thresholds.label(thresholds.critical, capacity: capacity)).", path: nil)
}
enum FolderScanState { case idle, scanning, queued }
func isPermissionDiagnostic(_ text: String) -> Bool {
    text.hasPrefix("du: /") && (text.hasSuffix(": Operation not permitted") || text.hasSuffix(": Permission denied"))
}
struct ScanResult {
    var values: [String: Int64]; var error: String?
    var failures: [String:String] = [:]
    var unlocalized = true
    func protectedOnly(for path: String) -> Bool {
        guard error != nil, !unlocalized else { return false }
        let affected = failures.filter { $0.key == path || $0.key.hasPrefix(path + "/") || path.hasPrefix($0.key + "/") }.map(\.value)
        return !affected.isEmpty && affected.allSatisfy { $0.split(separator: "\n").allSatisfy { isPermissionDiagnostic(String($0)) } }
    }
    func error(for path:String)->String? {
        guard let error=error else {return nil}
        if unlocalized {return error}
        return failures.keys.sorted().filter { $0==path || $0.hasPrefix(path+"/") || path.hasPrefix($0+"/") }.compactMap {failures[$0]}.first
    }
}
func scopedScanResult(values:[String:Int64],root:String,detail:String)->ScanResult {
    var failures:[String:String]=[:];var unknown=false
    for line in detail.split(separator:"\n") {
        let text=String(line)
        guard text.hasPrefix("du: "),let delimiter=text.range(of:": ",options:.backwards),delimiter.lowerBound>=text.index(text.startIndex,offsetBy:4) else {unknown=true;continue}
        let path=String(text[text.index(text.startIndex,offsetBy:4)..<delimiter.lowerBound])
        guard path==root || path.hasPrefix(root+"/") else {unknown=true;continue}
        failures[path] = [failures[path], text].compactMap { $0 }.joined(separator: "\n")
    }
    return ScanResult(values:values,error:detail.isEmpty ? "Scan failed without diagnostic details" : String(detail.prefix(600)),failures:failures,unlocalized:unknown || failures.isEmpty)
}
func mergedReading(old:Reading?,bytes:Int64,error:String?,date:Date,protectedOnly:Bool = false)->Reading {
    if error != nil,let old=old,old.incomplete != true {return old}
    return Reading(bytes:bytes,previous:error==nil && old?.incomplete != true && old?.administratorMeasured != true && old?.missing != true ? old?.bytes : nil,date:date,incomplete:error != nil,scanError:error,protectedOnly:error != nil && protectedOnly)
}
// Only explicit absence is deletion evidence. EACCES/EPERM/I/O failures are unknown.
func confirmsMissingPath(status: Int32, error: Int32) -> Bool {
    status != 0 && (error == ENOENT || error == ENOTDIR)
}
func pathIsConfirmedMissing(_ path: String) -> Bool {
    var info = stat()
    let result = lstat(path, &info)
    let failure = errno
    return confirmsMissingPath(status: result, error: failure)
}
final class Scanner {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if p?.isRunning == true { p?.terminate() } }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func scan(_ path: String) -> ScanResult {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/du"); p.arguments = ["-k", "-d", "2", path]
        var environment=ProcessInfo.processInfo.environment;environment["LC_ALL"]="C";p.environment=environment
        let out = Pipe(); p.standardOutput = out
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: errURL) }
        guard let err = try? FileHandle(forWritingTo: errURL) else { return ScanResult(values: [:], error: "Cannot create scan log") }
        defer { try? err.close() }; p.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); return ScanResult(values: [:], error: "Cancelled") }
        process = p
        do { try p.run() } catch { process = nil; lock.unlock(); return ScanResult(values: [:], error: error.localizedDescription) }
        lock.unlock()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        // Cancelled scans are discarded; unreadable content is labelled as a lower bound.
        if isCancelled { return ScanResult(values: [:], error: "Cancelled") }
        var scanError: String?
        if p.terminationStatus != 0 {
            let detail = (try? String(contentsOf: errURL, encoding: .utf8)) ?? "Folder could not be read"
            scanError = detail
        }
        var values: [String: Int64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]) else { continue }
            values[String(line[line.index(after: tab)...])] = kb * 1024
        }
        if let detail=scanError {return scopedScanResult(values:values,root:path,detail:detail)}
        return ScanResult(values: values, error: nil)
    }
}
// Deliberately not a general privileged command runner. No caller-supplied paths,
// arguments, executable files or credentials cross this boundary.
enum SpotlightMeasurement {
    static let path = "/System/Volumes/Data/.Spotlight-V100"
    enum Outcome: Equatable { case measured(Int64), cancelled, failed }

}
final class Model: ObservableObject {
    @Published var readings: [String: Reading] = [:]
    @Published var extras: [Root] = []
    @Published var expanded: Set<String> = []
    @Published var childCache: [String: [Root]] = [:]
    @Published var loadingChildren: Set<String> = []
    @Published var childErrors: [String: String] = [:]
    @Published var revealPath: String?
    @Published var revealRequest = 0
    @Published var free: Int64 = 0
    @Published var capacity: Int64 = 0
    @Published var scanning = false
    @Published private(set) var administratorMeasurement = false
    @Published var status = "Preparing folder measurements…"
    @Published var activePath: String?
    @Published var queuedPaths: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var lastMeasuredAt: Date?
    let scanner = Scanner()
    lazy var spotlightAccess = SpotlightAccess(preferences: preferences)
    let home: String
    @Published var projects: [Root]?
    @Published var customCaches: [Root] = []
    @Published var largestCount = 5
    @Published var projectPath: String?
    @Published var excludedPaths: Set<String> = []
    var onStatus: (() -> Void)?
    var timer: Timer?
    var folderTimer: Timer?
    let preferences: UserDefaults
    @Published private(set) var spaceThresholds = SpaceThresholds()
    @Published private(set) var diskInterval = 30
    @Published private(set) var folderInterval = 300
    var project: Root {
        let path = projectPath ?? home + "/Documents/YeagerAI"
        return Root(path: path, title: "Projects · " + URL(fileURLWithPath: path).lastPathComponent)
    }
    var projectRoots: [Root] {
        if let projects = projects { return projects }
        return (projectPath != nil || readings[project.path] != nil) && !excludedPaths.contains(project.path) ? [project] : []
    }
    var trackedRoots: [Root] { projectRoots + caches + extras }
    func isTracked(_ path: String) -> Bool { trackedRoots.contains { path == $0.path || path.hasPrefix($0.path + "/") } }

    var defaultCacheOptions: [Root] { [
        Root(path: home + "/Library/Caches", title: "Library caches"),
        Root(path: home + "/go/pkg/mod", title: "Go modules"),
        Root(path: home + "/.cargo", title: "Cargo"),
        Root(path: home + "/.rustup", title: "Rust toolchains"),
        Root(path: home + "/.foundry/anvil/tmp", title: "Anvil temporary files"),
        Root(path: home + "/.claude/projects", title: "Claude session history"),
        Root(path: home + "/Library/Containers/com.docker.docker/Data/vms", title: "Docker VM storage"),
        Root(path: spotlightPath, title: "Spotlight index")
    ].filter { FileManager.default.fileExists(atPath: $0.path) || readings[$0.path] != nil }
    }
    var caches: [Root] {
        let custom = Set(customCaches.map(\.path))
        return defaultCacheOptions.filter { !excludedPaths.contains($0.path) && !projectRoots.map(\.path).contains($0.path) && !custom.contains($0.path) } + customCaches
    }
    let saveURL: URL
    let spotlightPath: String
    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, preferences: UserDefaults = .standard, saveURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DiskMonitor/readings.json"), spotlightPath: String = "/System/Volumes/Data/.Spotlight-V100") {
        self.spotlightPath = spotlightPath
        self.home = home
        self.saveURL = saveURL
        self.preferences = preferences
        let critical = preferences.object(forKey: "criticalFreePercent") as? Int ?? 10
        let warning = preferences.object(forKey: "warningFreePercent") as? Int ?? 20
        if SpaceThresholds.valid(critical: critical, warning: warning) { spaceThresholds = SpaceThresholds(critical: critical, warning: warning) }
        let disk = preferences.object(forKey: "diskRefreshSeconds") as? Int ?? 30
        let folder = preferences.object(forKey: "folderRefreshSeconds") as? Int ?? 300
        diskInterval = (5...3600).contains(disk) ? disk : 30
        folderInterval = (60...86400).contains(folder) ? folder : 300
        if (try? PrivateReadings.prepare(saveURL)) != nil, let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) { readings = saved.readings; extras = saved.extras; projectPath = saved.projectPath; excludedPaths = Set(saved.excludedPaths ?? []); projects = saved.projects; customCaches = saved.customCaches ?? []; largestCount = (1...50).contains(saved.largestCount ?? 5) ? (saved.largestCount ?? 5) : 5; status = "Showing saved folder measurements" }
        lastMeasuredAt = readings.values.map(\.date).max()
        refreshCapacity()
        scheduleTimers()
    }
    func scheduleTimers() {
        timer?.invalidate(); folderTimer?.invalidate()
        timer = Timer(timeInterval: TimeInterval(diskInterval), repeats: true) { [weak self] _ in self?.refreshCapacity() }
        folderTimer = Timer(timeInterval: TimeInterval(folderInterval), repeats: true) { [weak self] _ in self?.scanAllFolders() }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(folderTimer!, forMode: .common)
    }
    @discardableResult func configureIntervals(diskSeconds: Int, folderMinutes: Int) -> Bool {
        guard (5...3600).contains(diskSeconds), (1...1440).contains(folderMinutes) else { return false }
        diskInterval = diskSeconds; folderInterval = folderMinutes * 60
        preferences.set(diskInterval, forKey: "diskRefreshSeconds")
        preferences.set(folderInterval, forKey: "folderRefreshSeconds")
        scheduleTimers()
        return true
    }
    @discardableResult func configureSpaceThresholds(critical: Int, warning: Int) -> Bool {
        guard SpaceThresholds.valid(critical: critical, warning: warning) else { return false }
        spaceThresholds = SpaceThresholds(critical: critical, warning: warning)
        preferences.set(critical, forKey: "criticalFreePercent")
        preferences.set(warning, forKey: "warningFreePercent")
        onStatus?()
        return true
    }
    func scanAllFolders() {
        scan(trackedRoots)
    }
    func scanMissingRoots() {
        let roots = trackedRoots
        let missing = roots.filter { root in
            guard let reading = readings[root.path] else { return true }
            return Date().timeIntervalSince(reading.date) >= TimeInterval(folderInterval)
        }
        if !missing.isEmpty { scan(missing) }
    }
    func scanState(_ path: String) -> FolderScanState {
        guard scanning else { return .idle }
        func overlaps(_ other: String) -> Bool {
            path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
        }
        if let active = activePath, overlaps(active) { return .scanning }
        if queuedPaths.contains(where: overlaps) { return .queued }
        return .idle
    }
    @Published var protectedPaths: Set<String> = []
    func isProtected(_ path: String) -> Bool {
        if errors[path] != nil { return protectedPaths.contains(path) }
        return readings[path]?.protectedOnly == true
    }
    func measurementLabel(_ path: String) -> String {
        if !FileManager.default.fileExists(atPath: path) { return "Not found" }
        if let active = activePath, path == active || path.hasPrefix(active + "/") { return "Scanning…" }
        if queuedPaths.contains(path) { return "Queued…" }
        if isProtected(path) { return "Protected by macOS" }
        return errors[path] == nil ? "Not scanned" : "Unreadable"
    }
    private var checkingGrowthPaths = false
    func refreshMissingGrowthPaths() {
        guard !checkingGrowthPaths else { return }
        let snapshot = readings.filter { _, value in
            value.missing != true && value.incomplete != true && value.previous != nil && value.bytes - value.previous! >= 10 * gib
        }
        guard !snapshot.isEmpty else { return }
        checkingGrowthPaths = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let missing = snapshot.keys.filter(pathIsConfirmedMissing)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingGrowthPaths = false
                var changed = false
                for path in missing {
                    guard var current = self.readings[path], let checked = snapshot[path],
                          current.date == checked.date, current.bytes == checked.bytes,
                          current.previous == checked.previous else { continue }
                    // Keep the historical size/date, but end its growth comparison.
                    // A recreated folder needs a successful fresh baseline first.
                    current.missing = true; current.previous = nil
                    self.readings[path] = current; changed = true
                }
                if changed { self.save(); self.onStatus?() }
            }
        }
    }
    func refreshCapacity() {
        refreshMissingGrowthPaths()
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: home), let f = a[.systemFreeSize] as? NSNumber, let total = a[.systemSize] as? NSNumber {
            free = f.int64Value; capacity = total.int64Value
        } else { capacity = 0 }
        onStatus?()
    }
    var alerts: [DiskAlert] {
        var result: [DiskAlert] = []
        if let alert = diskSpaceAlert(free: free, capacity: capacity, thresholds: spaceThresholds) { result.append(alert) }
        let roots = trackedRoots
        for root in roots {
            let error = errors[root.path]
            if !isProtected(root.path) && ((error != nil && error != "Cancelled") || readings[root.path]?.incomplete == true) {
                result.append(DiskAlert(id: "scan:" + root.path, critical: false, title: "Incomplete scan · " + root.title, detail: error ?? readings[root.path]?.scanError ?? "Some contents could not be measured. Rescan the folder for specific error details.", path: root.path, measurementIssue: true))
            }
        }
        let growth = readings.filter { isTracked($0.key) && $0.value.missing != true && $0.value.incomplete != true && $0.value.previous != nil && $0.value.bytes - $0.value.previous! >= 10 * gib }.sorted {
            ($0.value.bytes - $0.value.previous!) > ($1.value.bytes - $1.value.previous!)
        }
        var selected: [String] = []
        for (path, reading) in growth {
            if selected.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) { continue }
            selected.append(path)
            result.append(DiskAlert(id: "growth:" + path, critical: false, title: "Large growth · " + URL(fileURLWithPath: path).lastPathComponent, detail: "+\(sizeText(reading.bytes - reading.previous!)) since its previous scan. Measured \(reading.date.formatted(date: .abbreviated, time: .shortened)).", path: path))
        }
        return result
    }
    func children(_ path: String) -> [Root] {
        (childCache[path] ?? []).sorted {
            let left = readings[$0.path]?.bytes ?? -1
            let right = readings[$1.path]?.bytes ?? -1
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left > right
        }
    }
    func loadChildren(_ path: String) {
        guard childCache[path] == nil, !loadingChildren.contains(path) else { return }
        loadingChildren.insert(path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var children: [Root] = []
            var failure: String?
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
                children = urls.filter {
                    guard let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                    return v.isDirectory == true && v.isSymbolicLink != true
                }.map { Root(path: $0.path, title: $0.lastPathComponent) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.childCache[path] = children
                self.childErrors[path] = failure
                self.loadingChildren.remove(path)
                // Loading never changes expansion state: a collapse must win over an in-flight read.
            }
        }
    }
    var largestFolders: [Root] {
        let projectPaths = projectRoots.map(\.path)
        let library = home + "/Library/Caches"
        var candidates = Set(readings.keys.filter {
            let parent = URL(fileURLWithPath: $0).deletingLastPathComponent().path
            let candidate = $0
            return projectPaths.contains { (parent == $0 && candidate != $0 + "/worktree") || parent == $0 + "/worktree" } || parent == library
        })
        for root in caches where root.path != library { candidates.insert(root.path) }
        for root in extras { candidates.insert(root.path) }
        let sorted = candidates.filter { readings[$0] != nil && readings[$0]?.missing != true && isTracked($0) }.sorted {
            let a = readings[$0]!.bytes, b = readings[$1]!.bytes
            return a == b ? $0 < $1 : a > b
        }
        var selected: [String] = []
        for path in sorted {
            if selected.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) { continue }
            selected.append(path)
            if selected.count == largestCount { break }
        }
        return selected.map { path in
            let title = caches.first(where: { $0.path == path })?.title ?? URL(fileURLWithPath: path).lastPathComponent
            return Root(path: path, title: title)
        }
    }
    func reveal(_ path: String) {
        let roots = trackedRoots
        guard let root = roots.filter({ path == $0.path || path.hasPrefix($0.path + "/") }).min(by: { $0.path.count < $1.path.count }) else { return }
        var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while ancestor == root.path || ancestor.hasPrefix(root.path + "/") {
            expanded.insert(ancestor); loadChildren(ancestor)
            if ancestor == root.path { break }
            ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
        }
        revealPath = path
        revealRequest += 1
    }
    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) }
        else { expanded.insert(path); loadChildren(path) }
    }
    func save() {
        do {
            try PrivateReadings.write(JSONEncoder().encode(Saved(readings: readings, extras: extras, projectPath: projectPath, excludedPaths: Array(excludedPaths).sorted(), projects: projects, customCaches: customCaches, largestCount: largestCount)), to: saveURL)
        } catch { status = "Could not save private folder measurements" }
    }
    func measureSpotlight() {
        guard spotlightPath == SpotlightMeasurement.path,
              trackedRoots.contains(where: { $0.path == SpotlightMeasurement.path }) else { return }
        refreshFolder(Root(path: SpotlightMeasurement.path, title: "Spotlight index"))
    }
    func refreshFolder(_ root: Root) {
        guard !scanning else { return }
        if root.path == SpotlightMeasurement.path {
            spotlightAccess.refreshAvailability()
            guard spotlightAccess.packageValid, spotlightAccess.registration == 1,
                  !spotlightAccess.repair, !spotlightAccess.needsAccess else {
                spotlightAccess.openSetup(); return
            }
        }
        scan([root], manualSpotlight: true)
    }
    func stopScan() { scanner.cancel(); if administratorMeasurement { spotlightAccess.cancel() } }
    func finishSpotlight(_ result: SpotlightMeasurement.Outcome) {
        let path = SpotlightMeasurement.path
        switch result {
        case .measured(let bytes):
            // Different traversal scope (-x, summary only): do not infer growth against
            // an ordinary recursive scan. Only this fixed root is updated.
            readings[path] = Reading(bytes: bytes, date: Date(), administratorMeasured: true)
            errors.removeValue(forKey: path); protectedPaths.remove(path)
            lastMeasuredAt = Date()
            status = "Spotlight measured · administrator access"
            save()
        case .cancelled: status = "Measurement cancelled · saved size kept"
        case .failed: status = "Spotlight measurement failed · saved size kept"
        }
        scanning = false; administratorMeasurement = false; activePath = nil; queuedPaths = []
        refreshCapacity(); onStatus?()
    }
    func scan(_ roots: [Root], manualSpotlight: Bool = false) {
        guard !scanning else { return }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { refreshMissingGrowthPaths(); status = "None of these folders exists"; return }
        let includesSpotlight = existing.contains { $0.path == SpotlightMeasurement.path }
        if includesSpotlight { spotlightAccess.refreshAvailability() }
        let useHelper = includesSpotlight && spotlightAccess.packageValid && spotlightAccess.registration == 1
            && !spotlightAccess.repair && !spotlightAccess.needsAccess
            && (manualSpotlight || spotlightAccess.canAutomaticallyMeasure)
        scanning = true; scanner.reset(); queuedPaths = Set(existing.map(\.path)); status = "Preparing scan…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var helperFailure: String?
            for (i, root) in existing.enumerated() {
                if self.scanner.isCancelled { break }
                DispatchQueue.main.async { self.activePath = root.path; self.queuedPaths.remove(root.path); self.status = "Scanning \(root.title) · \(i + 1)/\(existing.count)" }
                if root.path == SpotlightMeasurement.path {
                    guard useHelper else {
                        // Disabled/unconfigured is not evidence of a permission denial.
                        // Leave prior readings and error classification untouched.
                        helperFailure = "Spotlight setup or scheduled measurement is not enabled"
                        continue
                    }
                    let done = DispatchSemaphore(value: 0)
                    var measured: Measurement?
                    DispatchQueue.main.async {
                        guard !self.scanner.isCancelled else { done.signal(); return }
                        self.administratorMeasurement = true
                        self.spotlightAccess.measure { value in measured = value; done.signal() }
                    }
                    done.wait() // Only this worker waits; UI/XPC/cancellation stay on the main thread.
                    DispatchQueue.main.sync {
                        self.administratorMeasurement = false
                        guard !self.scanner.isCancelled, let result = measured else { return }
                        if result.error == "Measurement cancelled" { self.scanner.cancel(); return }
                        if let bytes = result.bytes {
                            // Reused cooldown results retain their real measurement date.
                            self.readings[root.path] = Reading(bytes: bytes, date: result.finishedAt, administratorMeasured: true)
                            self.errors.removeValue(forKey: root.path); self.protectedPaths.remove(root.path)
                            self.lastMeasuredAt = max(self.lastMeasuredAt ?? result.finishedAt, result.finishedAt)
                            self.save()
                        } else {
                            helperFailure = result.error ?? "Spotlight measurement failed"
                            self.errors[root.path] = helperFailure
                            if self.spotlightAccess.needsAccess { self.protectedPaths.insert(root.path) }
                            else { self.protectedPaths.remove(root.path) }
                        }
                        self.onStatus?()
                    }
                    continue
                }
                let result = self.scanner.scan(root.path)
                DispatchQueue.main.sync {
                    if result.error == "Cancelled" { return }
                    let affectedPaths = Set(result.values.keys).union(result.failures.keys).union([root.path])
                    self.protectedPaths = self.protectedPaths.filter { $0 != root.path && !$0.hasPrefix(root.path + "/") }
                    for path in affectedPaths {
                        if result.protectedOnly(for: path) { self.protectedPaths.insert(path) }
                        if let error = result.error(for: path) { self.errors[path] = error }
                        else { self.errors.removeValue(forKey: path) }
                    }
                    if let error = result.error { self.errors[root.path] = error }
                    else { self.errors.removeValue(forKey: root.path) }
                    for (path, bytes) in result.values {
                        let pathError=result.error(for:path)
                        if let pathError=pathError {self.errors[path]=pathError} else {self.errors.removeValue(forKey:path)}
                        self.readings[path]=mergedReading(old:self.readings[path],bytes:bytes,error:pathError,date:Date(),protectedOnly:result.protectedOnly(for:path))
                    }
                    if !result.values.isEmpty { self.lastMeasuredAt = Date() }
                    let cachedPaths = self.childCache.keys.filter { $0 == root.path || $0.hasPrefix(root.path + "/") }
                    for path in cachedPaths {
                        self.childCache.removeValue(forKey: path)
                        if self.expanded.contains(path) { self.loadChildren(path) }
                    }
                    self.save()
                    self.onStatus?()
                }
            }
            DispatchQueue.main.async {
                self.scanning = false; self.activePath = nil; self.queuedPaths = []; self.refreshCapacity()
                self.status = self.scanner.isCancelled ? "Scan stopped · previous readings kept" : helperFailure != nil ? "Spotlight needs attention · saved size kept" : "Scan finished · \(Date().formatted(date: .omitted, time: .shortened))"
            }
        }
    }
    func stopTracking(_ path: String) {
        projects = projectRoots.filter { $0.path != path }
        customCaches.removeAll { $0.path == path }
        excludedPaths.insert(path)
        extras.removeAll { $0.path == path }
        if project.path == path { projectPath = nil }
        save(); onStatus?()
    }
    func setProjects(_ path: String) {
        if project.path != path { excludedPaths.insert(project.path) }
        projectPath = path
        projects = [Root(path: path, title: "Projects · " + URL(fileURLWithPath: path).lastPathComponent)]
        customCaches.removeAll { $0.path == path }
        excludedPaths.remove(path)
        extras.removeAll { $0.path == path }
        save(); onStatus?()
    }
    func configureLargestCount(_ count: Int) {
        guard (1...50).contains(count) else { return }
        largestCount = count; save()
    }
    func addRoot(_ url: URL, asProject: Bool) {
        let current = projectRoots
        let root = Root(path: url.path, title: url.lastPathComponent)
        projects = current.filter { $0.path != url.path }
        customCaches.removeAll { $0.path == url.path }
        extras.removeAll { $0.path == url.path }
        excludedPaths.insert(url.path)
        if asProject { projects!.append(root) } else { customCaches.append(root) }
        save(); onStatus?()
    }
    func renameProject(_ path: String, title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        projects = projectRoots.map { $0.path == path ? Root(path: path, title: name) : $0 }
        save()
    }
    func chooseRoots(asProject: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = asProject ? "Add folders" : "Add cache folders"
        if panel.runModal() == .OK { for url in panel.urls { addRoot(url, asProject: asProject) } }
    }
    func chooseProjects() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK, let url = panel.url { setProjects(url.path) }
    }
    func addFolder(_ url: URL) {
        excludedPaths.remove(url.path)
        if !trackedRoots.contains(where: { $0.path == url.path }) { extras.append(Root(path: url.path, title: url.lastPathComponent)) }
        save(); onStatus?()
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.prompt = "Track folder"
        if panel.runModal() == .OK {
            for url in panel.urls { addFolder(url) }
            save()
        }
    }
}
struct ScanActivityIndicator: View {
    @ObservedObject var model: Model
    let path: String
    var body: some View {
        switch model.scanState(path) {
        case .scanning:
            ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
                .help("Scanning this folder or its contents…").accessibilityLabel("Scanning")
        case .queued:
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(width: 16, height: 16)
                .help("Queued for scanning").accessibilityLabel("Queued for scanning")
        case .idle:
            EmptyView()
        }
    }
}
struct FolderRow: View {
    @ObservedObject var model: Model
    let root: Root
    var depth: Int = 0
    @State private var confirmingMeasurement = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { model.toggle(root.path) } label: {
                HStack(spacing: 8) {
                Image(systemName: model.expanded.contains(root.path) ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 24)
                Image(systemName: depth == 0 ? "folder.fill" : "folder").foregroundStyle(depth == 0 ? Palette.accent : Palette.secondary)
                Text(root.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if model.errors[root.path] != nil { Image(systemName: model.isProtected(root.path) ? "lock" : "exclamationmark.circle").foregroundStyle(model.isProtected(root.path) ? Palette.secondary : Palette.warning).help(model.errors[root.path]!) }
                if let r = model.readings[root.path] {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text((r.incomplete == true ? "≥ " : "") + sizeText(r.bytes)).fontWeight(.medium).monospacedDigit()
                        if !FileManager.default.fileExists(atPath: root.path) { Text("Not found · saved size").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        if model.scanState(root.path) != .idle {
                            Text(model.scanState(root.path) == .scanning ? "Scanning…" : "Queued…").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                        }
                        if r.administratorMeasured == true { Text("Administrator · saved size").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        if r.incomplete == true { Text(model.isProtected(root.path) ? "Partial · protected contents" : "Partial · scan error").font(.system(size: 10)).foregroundStyle(Palette.warning).help(r.scanError ?? model.errors[root.path] ?? "Older partial reading. Rescan this folder for the specific error.") }
                        if let old = r.previous {
                            let delta = r.bytes - old
                            Text(delta == 0 ? "No change" : "\(delta > 0 ? "+" : "−")\(sizeText(abs(delta)))").font(.system(size: 10)).foregroundStyle(delta >= 10 * gib ? Palette.warning : Palette.secondary)
                        }
                    }.help("Measured \(r.date.formatted())\n\(root.path)")
                } else { Text(model.measurementLabel(root.path)).foregroundStyle(Palette.secondary).font(.system(size: 11)) }
                }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(model.expanded.contains(root.path) ? "Collapse" : "Expand") \(root.title)")
                if model.scanState(root.path) == .idle {
                    Button { model.refreshFolder(root) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 30, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.scanning).help("Scan this folder")
                } else {
                    ScanActivityIndicator(model: model, path: root.path).frame(width: 30, height: 36)
                }
            }
            .font(.system(size: 12)).padding(.leading, CGFloat(depth) * 14 + 8).padding(.trailing, 8)
            .background(model.revealPath == root.path ? Palette.accent.opacity(0.12) : depth == 0 ? Palette.surface : Color.clear)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path) }
                Button("Scan this folder") { model.refreshFolder(root) }.disabled(model.scanning)
                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(root.path, forType: .string) }
                if model.trackedRoots.contains(where: { $0.path == root.path }) { Button("Stop tracking") { model.stopTracking(root.path) } }
            }
            if root.path == SpotlightMeasurement.path {
                SpotlightStatus(access: model.spotlightAccess, scanning: model.scanning)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.expanded.contains(root.path) {
                let children = model.children(root.path)
                if children.isEmpty {
                    Text(model.loadingChildren.contains(root.path) ? "Loading folders…" : model.childErrors[root.path] != nil ? "Cannot read this folder" : "No subfolders")
                        .font(.caption).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(depth + 1) * 14 + 28).padding(.vertical, 6)
                }
                ForEach(children) { child in FolderRow(model: model, root: child, depth: depth + 1) }
            }
        }.id(root.path)
    }
}
struct LargestFolders: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("\(model.largestCount) LARGEST FOLDERS", systemImage: "chart.bar.xaxis").font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("From last scans").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            if model.largestFolders.isEmpty {
                Text("Scanning folders to find the largest…").font(.caption).foregroundStyle(Palette.secondary).padding(.vertical, 12)
            }
            ForEach(Array(model.largestFolders.enumerated()), id: \.element.path) { index, root in
                if let reading = model.readings[root.path] {
                    Button { model.reveal(root.path) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent).frame(width: 22, height: 22).background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(root.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    ScanActivityIndicator(model: model, path: root.path)
                                    Spacer()
                                    Text((reading.incomplete == true ? "≥ " : "") + sizeText(reading.bytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                }
                                HStack {
                                    Text(root.path.replacingOccurrences(of: model.home + "/", with: "~/")).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    if reading.incomplete == true { Text("Partial").foregroundStyle(Palette.warning) }
                                    else if let old = reading.previous, reading.bytes != old { Text("\(reading.bytes > old ? "+" : "−")\(sizeText(abs(reading.bytes - old)))").foregroundStyle(reading.bytes - old >= 10 * gib ? Palette.warning : Palette.secondary) }
                                }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
                                GeometryReader { g in
                                    Capsule().fill(Palette.accent.opacity(0.40)).frame(width: max(2, g.size.width * Double(reading.bytes) / Double(max(1, model.readings[model.largestFolders.first!.path]!.bytes))))
                                }.frame(height: 3)
                            }
                        }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Show in folder tree · measured \(reading.date.formatted())")
                }
            }
        }
    }
}
struct AlertPanel: View {
    @ObservedObject var model: Model
    var body: some View {
        if !model.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label("NEEDS ATTENTION", systemImage: diskBadgeLevel(model.alerts)==1 ? "questionmark.circle.fill" : "exclamationmark.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(diskBadgeLevel(model.alerts)==3 ? Palette.critical : diskBadgeLevel(model.alerts)==2 ? Palette.warning : Palette.uncertainty)
                ForEach(model.alerts) { alert in
                    Button {
                        if let path = alert.path { model.reveal(path) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName:alert.symbol).foregroundStyle(alert.color)
                                Text(alert.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if alert.path != nil { Image(systemName: "chevron.right").font(.system(size: 9)) }
                            }
                            Text(alert.detail).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(alert.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("Free-space alerts update every \(intervalText(model.diskInterval)). Growth and scan alerts update after folder scans.").font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            Divider().padding(.vertical, 3)
        }
    }
}
struct ProjectSettingRow: View {
    @ObservedObject var model: Model
    let root: Root
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Folder label", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { model.renameProject(root.path, title: name) }
                Button("Rename") { model.renameProject(root.path, title: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") { model.stopTracking(root.path) }
            }
            Text(root.path).font(.caption).foregroundStyle(Palette.secondary).textSelection(.enabled)
        }.onAppear { name = root.title }
    }
}
struct FolderSettings: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tracked folders").font(.headline)
            Stepper("Largest folders: \(model.largestCount)", value: Binding(get: {model.largestCount}, set: {model.configureLargestCount($0)}), in: 1...50)
            Text("Folder settings save immediately. Removing a folder stops tracking; it does not delete files or saved measurements.").font(.caption).foregroundStyle(Palette.secondary)
            Text("Folders").fontWeight(.semibold)
            ForEach(model.projectRoots) { root in ProjectSettingRow(model: model, root: root) }
            Button("Add folders…") { model.chooseRoots(asProject: true) }
            Divider()
            Text("Caches & tools").fontWeight(.semibold)
            ForEach(model.defaultCacheOptions.filter { candidate in !model.projectRoots.contains { $0.path == candidate.path } && !model.customCaches.contains { $0.path == candidate.path } }) { root in
                Toggle(root.title, isOn: Binding(get: {!model.excludedPaths.contains(root.path)}, set: {enabled in
                    if enabled {model.excludedPaths.remove(root.path);model.extras.removeAll {$0.path == root.path};model.save();model.onStatus?()}
                    else {model.stopTracking(root.path)}
                }))
            }
            ForEach(model.customCaches) { root in
                HStack { Text(root.title); Spacer(); Button("Remove") {model.stopTracking(root.path)} }.help(root.path)
            }
            Text("Some folders remain protected even with Full Disk Access. Use Spotlight’s “Protected-folder setup…” to enable its optional scanner. Other folders do not receive administrator access. See Info for general access guidance.").font(.caption).foregroundStyle(Palette.secondary)
            Button("Add cache folders…") {model.chooseRoots(asProject: false)}
        }.font(.system(size: 11))
    }
}
struct RefreshSettings: View {
    @ObservedObject var model: Model
    let close: () -> Void
    @State private var diskSeconds = ""
    @State private var folderMinutes = ""
    @State private var criticalPercent = ""
    @State private var warningPercent = ""
    @State private var thresholdValidation: String?
    @State private var validation: String?
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Settings", systemImage: "slider.horizontal.3").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Free disk space").font(.system(size: 13, weight: .medium))
                HStack {
                    Text("Check every")
                    TextField("30", text: $diskSeconds).textFieldStyle(.roundedBorder).frame(width: 80).accessibilityLabel("Free space interval in seconds")
                    Text("seconds")
                }.font(.system(size: 12))
                Text("Lightweight free-space check. Between 5 and 3,600 seconds.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Folder sizes").font(.system(size: 13, weight: .medium))
                HStack {
                    Text("Scan every")
                    TextField("5", text: $folderMinutes).textFieldStyle(.roundedBorder).frame(width: 80).accessibilityLabel("Folder scan interval in minutes")
                    Text("minutes")
                }.font(.system(size: 12))
                Text("Updates folder sizes, top five and growth alerts. Between 1 and 1,440 minutes. A refresh is skipped if a scan is running.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let validation = validation { Text(validation).font(.caption).foregroundStyle(Palette.critical) }
            HStack {
                Button("Save settings") {
                    guard let disk = Int(diskSeconds.trimmingCharacters(in: .whitespaces)), let folder = Int(folderMinutes.trimmingCharacters(in: .whitespaces)), model.configureIntervals(diskSeconds: disk, folderMinutes: folder) else {
                        validation = "Enter whole numbers within the ranges above."; return
                    }
                    close()
                }.buttonStyle(.borderedProminent).tint(Palette.button).foregroundStyle(.white)
            }
            Text("Changes apply immediately and are remembered after restart. The next refresh uses your new interval; an active scan continues.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            FolderSettings(model: model)
            Divider()
            UpdateSettings()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Free-space alerts").font(.system(size: 13, weight: .semibold))
                HStack {
                    Text("Red below")
                    TextField("10", text: $criticalPercent).textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel("Critical free-space percentage")
                    Text("% free")
                    if let value = Int(criticalPercent), (1...100).contains(value) {
                        Text(model.spaceThresholds.label(value, capacity: model.capacity)).foregroundStyle(Palette.secondary)
                    }
                }
                HStack {
                    Text("Orange below")
                    TextField("20", text: $warningPercent).textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel("Warning free-space percentage")
                    Text("% free")
                    if let value = Int(warningPercent), (1...100).contains(value) {
                        Text(model.spaceThresholds.label(value, capacity: model.capacity)).foregroundStyle(Palette.secondary)
                    }
                }
                Text("Whole percentages from 1 to 100. Red must be lower than orange. Amounts use the monitored volume’s capacity.").foregroundStyle(Palette.secondary)
                if let error = thresholdValidation { Text(error).foregroundStyle(Palette.critical) }
                Button("Save alert thresholds") {
                    guard let critical = Int(criticalPercent.trimmingCharacters(in: .whitespaces)), let warning = Int(warningPercent.trimmingCharacters(in: .whitespaces)), model.configureSpaceThresholds(critical: critical, warning: warning) else {
                        thresholdValidation = "Enter whole percentages: 1 ≤ red < orange ≤ 100."; return
                    }
                    thresholdValidation = nil
                }.buttonStyle(.borderedProminent).tint(Palette.button).foregroundStyle(.white)
                Text("Saved thresholds apply immediately and are remembered after restart.").foregroundStyle(Palette.secondary)
                Divider()
                Text("Alert legend").font(.system(size: 13, weight: .semibold))
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.critical).frame(width: 18)
                    Text("Red ! · Less than \(model.spaceThresholds.label(model.spaceThresholds.critical, capacity: model.capacity)) free.")
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.warning).frame(width: 18)
                    Text("Orange ! · Less than \(model.spaceThresholds.label(model.spaceThresholds.warning, capacity: model.capacity)) free, or folder growth of 10 GiB or more between scans.")
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(Palette.uncertainty).frame(width: 18)
                    Text("Yellow ? · Unexpected incomplete or failed measurement, or unavailable free-space reading. Protected folders alone do not trigger a badge.")
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "internaldrive").foregroundStyle(Palette.secondary).frame(width: 18)
                    Text("No badge · No active alerts.")
                }
                Text("Priority: red, then orange, then yellow. Click the menu bar icon to see the reason for an alert.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { diskSeconds = String(model.diskInterval); folderMinutes = String(model.folderInterval / 60); criticalPercent = String(model.spaceThresholds.critical); warningPercent = String(model.spaceThresholds.warning) }
    }
}
struct Dashboard: View {
    @ObservedObject var model: Model
    @State private var showingSettings = false
    @State private var showingInformation = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("DISK MONITOR", systemImage: "internaldrive").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    Spacer(); Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")).font(.system(size: 9, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.12), in: Capsule())
                }.foregroundStyle(.white.opacity(0.8))
                if !showingSettings && !showingInformation {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(sizeText(model.free)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("free").foregroundStyle(.white.opacity(0.7)); Spacer()
                }.foregroundStyle(.white)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(Color(red: 0.35, green: 0.88, blue: 0.75)).frame(width: g.size.width * max(0, min(1, Double(model.free) / Double(max(1, model.capacity)))))
                    }
                }.frame(height: 5)
                Text("\(sizeText(model.capacity)) volume · free space refreshes every \(intervalText(model.diskInterval))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                }
            }.padding(20).background(LinearGradient(colors: [Color(red: 0.07, green: 0.22, blue: 0.24), Color(red: 0.10, green: 0.32, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if showingSettings {
                RefreshSettings(model: model) { showingSettings = false }
            } else if showingInformation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("About these measurements").font(.headline).foregroundStyle(Palette.primary)
                        Text("Free space is a lightweight filesystem check. Folder scans walk directories in the background, one at a time. The two refresh intervals are separate.")
                        Text("The refresh arrow scans tracked folders. While scanning, it becomes a stop button. Completed readings are kept when you stop.")
                        Text("Folder sizes can overlap or share APFS storage and should not be added together. Partial readings show ≥; failed scans preserve earlier complete measurements.")
                        Text("The top five uses saved measurements. Expand a folder to explore it, use its refresh icon for deeper measurements, or right-click to open it in Finder.")
                        Text("The folder-plus icon adds a tracked folder. Settings contains refresh intervals and the alert legend. This app never deletes monitored files.")
                        Divider()
                        Text("Folders protected by macOS").font(.headline).foregroundStyle(Palette.primary)
                        Text("Protected by macOS means a permission restriction prevented a complete measurement; it does not mean the folder is empty. Partial · protected contents shows only the readable portion. Earlier complete sizes keep their original measurement date.")
                        Text("For any affected folder, check System Settings → Privacy & Security → Full Disk Access for Disk Monitor. If you choose to allow access, reopen the app and refresh that folder. Full Disk Access grants broad access and may not unlock every system-owned folder.")
                        Text("After an update, check access again if a folder becomes protected. Background scanner approval, Full Disk Access and administrator authorization are separate. Only follow the setup steps offered for that folder; a scanner launch failure is not fixed by changing disk access.")
                        Text("Adding a folder never grants administrator access. Some system folders need a separately supported measurement method and may remain protected. Disk Monitor never changes folder permissions or deletes monitored files.")
                    }.font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(20)
                }
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AlertPanel(model: model)
                    LargestFolders(model: model)
                    Divider().padding(.vertical, 3)
                    HStack { Text("FOLDERS").fontWeight(.semibold); Spacer(); Text("Size / change") }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    ForEach(model.projectRoots) { root in FolderRow(model: model, root: root) }
                    Button("Add folders…") { model.chooseRoots(asProject: true) }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 11))
                    Text("SHARED CACHES & TOOLS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.top, 4)
                    VStack(spacing: 1) { ForEach(model.caches) { root in FolderRow(model: model, root: root) } }
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(Palette.accent); Text("Nix store"); Spacer(); Text("Separate accounting").foregroundStyle(Palette.secondary)
                    }.font(.system(size: 12)).padding(8).help("Nix reclaimable-space inspection is not in this draft. Recursive folder sizes are not a reliable reclamation estimate.")
                    if !model.extras.isEmpty { Text("YOUR FOLDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary); ForEach(model.extras) { root in FolderRow(model: model, root: root) } }
                    Text("Folder sizes may overlap or share APFS storage. They are not summed. Expand folders to find growth; right-click to open in Finder.").font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }.padding(14)
            }
            .onChange(of: model.revealRequest) { _, _ in
                if let path = model.revealPath { DispatchQueue.main.async { withAnimation { proxy.scrollTo(path, anchor: .top) } } }
            }
            .onChange(of: model.loadingChildren) { _, loading in
                if loading.isEmpty, let path = model.revealPath { DispatchQueue.main.async { withAnimation { proxy.scrollTo(path, anchor: .top) } } }
            }
            }
            }
            if showingSettings || showingInformation {
                HStack {
                    Spacer()
                    Button("Back") { showingSettings = false; showingInformation = false }
                }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 8) {
                if model.scanning { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.system(size: 11)).lineLimit(1)
                    Text("Folders: every \(intervalText(model.folderInterval)) · Measured \(model.lastMeasuredAt?.formatted(date: .omitted, time: .shortened) ?? "not yet")")
                        .font(.system(size: 9)).foregroundStyle(Palette.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.choose() } label: { Image(systemName: "folder.badge.plus").frame(width: 22, height: 28) }.help("Add folder").accessibilityLabel("Add folder")
                Button { if model.scanning { model.stopScan() } else { model.scanAllFolders() } } label: {
                    Image(systemName: model.scanning ? "stop.circle" : "arrow.clockwise").frame(width: 22, height: 28)
                }.help(model.scanning ? "Stop scan" : "Scan now").accessibilityLabel(model.scanning ? "Stop scan" : "Scan now")
                Button { showingSettings = false; showingInformation.toggle() } label: { Image(systemName: "info.circle").frame(width: 22, height: 28) }.help("About measurements").accessibilityLabel("About measurements")
                Button { showingInformation = false; showingSettings.toggle() } label: { Image(systemName: "gearshape").frame(width: 22, height: 28) }.help("Settings").accessibilityLabel("Settings")
                Button { model.scanner.cancel(); NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 22, height: 28) }.disabled(model.administratorMeasurement).help("Quit Disk Monitor").accessibilityLabel("Quit Disk Monitor")
            }.buttonStyle(.plain).foregroundStyle(Palette.primary).padding(14)
        }.frame(width: 440, height: 690)
            .foregroundStyle(Palette.primary)
            .background(Palette.background)
            .preferredColorScheme(.dark)
    }
}
final class StatusBadgeView: NSView {
    var level = 0 { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        (level==3 ? NSColor.systemRed : level==2 ? NSColor.systemOrange : NSColor.systemYellow).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let text = NSAttributedString(string: level==1 ? "?" : "!", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: level==1 ? NSColor.black : NSColor.white])
        text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    let model = Model()
    var outsideClickMonitor: Any?
    var localEventMonitor: Any?
    let statusBadge = StatusBadgeView(frame: .zero)
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdates.shared.start { [weak self] in self?.model.scanning == true }
        launchDiagnostic("didFinish")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { launchDiagnostic("status",self.item) }
        NSApp.setActivationPolicy(.accessory)
        let autosaveName="DiskMonitor-status"
        let positionKey="NSStatusItem Preferred Position "+autosaveName
        if UserDefaults.standard.object(forKey:positionKey)==nil {
            UserDefaults.standard.set(0,forKey:positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName=autosaveName
        item.isVisible=true
        if let b = item.button { b.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Disk Monitor"); b.title = ""; b.target = self; b.action = #selector(toggle); b.toolTip = "Disk Monitor · click to inspect folders" }
        if let button = item.button {
            statusBadge.translatesAutoresizingMaskIntoConstraints = false
            statusBadge.setAccessibilityElement(false)
            button.addSubview(statusBadge)
            NSLayoutConstraint.activate([
                statusBadge.widthAnchor.constraint(equalToConstant: 13),
                statusBadge.heightAnchor.constraint(equalToConstant: 13),
                statusBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                statusBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 1)
            ])
        }
        model.onStatus = { [weak self] in self?.updateStatusIcon() }
        updateStatusIcon()
        popover.contentSize = NSSize(width: 440, height: 690); popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: Dashboard(model: model))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.model.scanMissingRoots() }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.toggle() } }
    }
    func updateStatusIcon() {
        guard let button = item?.button else { return }
        let alerts = model.alerts
        // AppKit tints the template for the menu bar, including wallpaper and appearance changes.
        // The colored badge is a separate, mouse-transparent overlay.
        let drive = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Disk Monitor")
        drive?.isTemplate = true
        button.image = drive
        button.title = ""
        statusBadge.isHidden = alerts.isEmpty
        statusBadge.level = diskBadgeLevel(alerts)
        guard !alerts.isEmpty else {
            button.toolTip = "Disk Monitor · \(sizeText(model.free)) free · no active alerts"
            button.setAccessibilityLabel(button.toolTip)
            return
        }
        button.toolTip = alerts.map(\.title).joined(separator: "\n") + "\nClick for details."
        button.setAccessibilityLabel("Disk Monitor: " + alerts.map(\.title).joined(separator: "; "))
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            model.refreshCapacity()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startDismissMonitors()
        }
    }
    func startDismissMonitors() {
        stopDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else if event.window !== self.popover.contentViewController?.view.window && event.window !== self.item.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
    }
    func stopDismissMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor = nil }
    }
    func popoverDidClose(_ notification: Notification) { stopDismissMonitors() }
    func applicationDidResignActive(_ notification: Notification) { popover.performClose(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.administratorMeasurement ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { stopDismissMonitors(); model.scanner.cancel() }
}
if CommandLine.arguments.contains("--scanner-package-self-test") {
    let host = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Scanner/Disk Monitor Scanner.app")
    do { try BundlePolicy.validate(at: host); print("PASS: nested scanner package and pinned signatures") }
    catch { fputs("Scanner package validation failed\n", stderr); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--updater-self-test") {
    precondition(Bundle.main.bundleIdentifier?.hasPrefix("local.monitor.updater-test.") == true, "Use the isolated updater fixture")
    _ = NSApplication.shared
    AppUpdates.shared.start { false }
    precondition(AppUpdates.shared.failure == nil, "Sparkle configuration must start successfully")
    precondition(!AppUpdates.shared.checks && !AppUpdates.shared.downloads)
    print("PASS: embedded Sparkle starts with automatic checks and downloads disabled")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    let scanWarning=DiskAlert(id:"scan:test",critical:false,title:"Scan",detail:"Denied",path:nil,measurementIssue:true)
    let spaceWarning=diskSpaceAlert(free:150*gib,capacity:1000*gib)!
    let criticalWarning=diskSpaceAlert(free:90*gib,capacity:1000*gib)!
    let growthWarning=DiskAlert(id:"growth:test",critical:false,title:"Growth",detail:"",path:nil)
    precondition(diskBadgeLevel([])==0 && diskBadgeLevel([scanWarning])==1)
    precondition(diskBadgeLevel([scanWarning,spaceWarning])==2)
    precondition(diskBadgeLevel([scanWarning,growthWarning])==2)
    precondition(diskBadgeLevel([spaceWarning,scanWarning,criticalWarning])==3)
    precondition(diskBadgeLevel([diskSpaceAlert(free:0,capacity:0)!])==1)
    let indexPath = SpotlightMeasurement.path
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("DiskMonitor-test-" + UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent("folder with spaces"), withIntermediateDirectories: true)
    try Data(repeating: 42, count: 1024 * 1024).write(to: root.appendingPathComponent("folder with spaces/sample"))
    let privateURL = root.appendingPathComponent("private/readings.json")
    try PrivateReadings.write(Data("keep".utf8), to: privateURL)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateURL.deletingLastPathComponent().path)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateURL.path)
    try PrivateReadings.prepare(privateURL)
    precondition((try! fm.attributesOfItem(atPath: privateURL.path)[.posixPermissions] as? Int) == 0o600)
    precondition((try! fm.attributesOfItem(atPath: privateURL.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
    precondition(try! Data(contentsOf: privateURL) == Data("keep".utf8))
    let outside = root.appendingPathComponent("outside.json")
    try Data("outside".utf8).write(to: outside)
    let link = privateURL.deletingLastPathComponent().appendingPathComponent("link.json")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    do { try PrivateReadings.write(Data("bad".utf8), to: link); preconditionFailure("Must reject links") } catch {}
    precondition(try! Data(contentsOf: outside) == Data("outside".utf8))
    let scoped=scopedScanResult(values:["/fixture":10,"/fixture/good":5],root:"/fixture",detail:"du: /fixture/bad/file: Permission denied\ndu: /fixture/vanished: No such file or directory\n")
    precondition(scoped.error(for:"/fixture") != nil && scoped.error(for:"/fixture/bad") != nil)
    precondition(scoped.error(for:"/fixture/good")==nil && scoped.error(for:"/fixture/bad-other")==nil)
    precondition(scopedScanResult(values:[:],root:"/fixture",detail:"du: unknown failure").error(for:"/fixture/good") != nil)
    let colon=scopedScanResult(values:[:],root:"/fixture",detail:"du: /fixture/name: with colon: Operation not permitted")
    precondition(colon.error(for:"/fixture/name: with colon") != nil && colon.error(for:"/fixture/good")==nil)
    let protectedResult = scopedScanResult(values: [:], root: "/fixture", detail: "du: /fixture/private: Operation not permitted\ndu: /fixture/other: Permission denied")
    precondition(protectedResult.protectedOnly(for: "/fixture"))
    precondition(!protectedResult.protectedOnly(for: "/fixture/good"))
    precondition(!scoped.protectedOnly(for: "/fixture"), "Mixed failures must keep warning")
    let repeated = scopedScanResult(values: [:], root: "/fixture", detail: "du: /fixture/private: Input/output error\ndu: /fixture/private: Permission denied")
    precondition(!repeated.protectedOnly(for: "/fixture"), "A later denial must not hide an earlier failure")
    precondition(!scopedScanResult(values: [:], root: "/fixture", detail: "unknown\ndu: /fixture/private: Permission denied").protectedOnly(for: "/fixture"))
    let complete=Reading(bytes:50,previous:40,date:Date())
    precondition(mergedReading(old:complete,bytes:20,error:"denied",date:Date()).bytes==50)
    let partial=mergedReading(old:nil,bytes:20,error:"denied",date:Date())
    precondition(partial.incomplete==true && partial.previous==nil && partial.scanError=="denied")
    let repaired=mergedReading(old:partial,bytes:30,error:nil,date:Date())
    precondition(repaired.incomplete==false && repaired.previous==nil && repaired.scanError==nil)
    let legacy=Data("{\"bytes\":10,\"date\":0,\"incomplete\":true}".utf8)
    let decodedLegacy=try JSONDecoder().decode(Reading.self,from:legacy)
    precondition(decodedLegacy.scanError==nil)
    let roundtrip=try JSONDecoder().decode(Reading.self,from:JSONEncoder().encode(partial))
    precondition(roundtrip.scanError=="denied")
    let portableHome = root.appendingPathComponent("portable-home")
    try fm.createDirectory(at: portableHome.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
    let portableURL = root.appendingPathComponent("portable-state/readings.json")
    let portable = Model(home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(portable.projectRoots.isEmpty && portable.caches.count == 1)
    portable.stopTracking(portable.caches[0].path)
    precondition(portable.trackedRoots.isEmpty)
    let selected = portableHome.appendingPathComponent("My Projects")
    portable.setProjects(selected.path)
    precondition(portable.projectRoots.first?.path == selected.path)
    portable.addFolder(selected)
    precondition(portable.trackedRoots.count == 1, "Do not duplicate Projects as an extra")
    let missing = portableHome.appendingPathComponent("missing-manual")
    portable.addFolder(missing)
    precondition(portable.measurementLabel(missing.path) == "Not found")
    portable.readings[selected.path] = Reading(bytes: 30*gib, previous: 0, date: Date())
    portable.save()
    let reopened = Model(home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(reopened.caches.isEmpty && reopened.project.path == selected.path && reopened.extras.count == 1)
    reopened.stopTracking(selected.path)
    precondition(reopened.projectRoots.isEmpty && reopened.readings[selected.path] != nil)
    precondition(!reopened.alerts.contains { $0.path == selected.path } && !reopened.largestFolders.contains { $0.path == selected.path })
    let oldSaved = Saved(readings: [portableHome.path + "/Documents/YeagerAI": complete], extras: [])
    try PrivateReadings.write(JSONEncoder().encode(oldSaved), to: portableURL)
    let migrated = Model(home: portableHome.path, saveURL: portableURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(migrated.projectRoots.count == 1 && migrated.readings[migrated.project.path]?.bytes == complete.bytes)
    migrated.setProjects(selected.path)
    migrated.stopTracking(selected.path)
    precondition(migrated.projectRoots.isEmpty, "Stopping a replacement must not resurrect legacy Projects")
    for fixtureModel in [portable, reopened, migrated] { fixtureModel.timer?.invalidate(); fixtureModel.folderTimer?.invalidate() }
    let multiURL = root.appendingPathComponent("multi-state/readings.json")
    let multi = Model(home: portableHome.path, saveURL: multiURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    let first = portableHome.appendingPathComponent("first")
    let second = portableHome.appendingPathComponent("second")
    multi.addRoot(first, asProject: true); multi.addRoot(second, asProject: true)
    multi.addRoot(first, asProject: true)
    precondition(multi.projectRoots.count == 2)
    multi.renameProject(first.path, title: "Work repositories")
    for i in 0..<8 {
        let parent = i < 4 ? first.path : second.path
        multi.readings[parent + "/repo-" + String(i)] = Reading(bytes: Int64(i+1)*gib, previous: nil, date: Date())
    }
    precondition(multi.largestFolders.count == 5)
    multi.configureLargestCount(8)
    precondition(multi.largestFolders.count == 8 && multi.largestFolders.first?.path == second.path + "/repo-7")
    multi.configureLargestCount(0);precondition(multi.largestCount == 8)
    multi.configureLargestCount(51);precondition(multi.largestCount == 8)
    let customCache = portableHome.appendingPathComponent("custom-cache")
    multi.addRoot(customCache, asProject: false)
    multi.readings[customCache.path] = Reading(bytes: 20*gib, previous: nil, date: Date())
    multi.save()
    let multiReloaded = Model(home: portableHome.path, saveURL: multiURL, spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(multiReloaded.largestCount == 8 && multiReloaded.projectRoots.count == 2)
    precondition(multiReloaded.projectRoots.contains { $0.title == "Work repositories" })
    precondition(multiReloaded.caches.contains { $0.path == customCache.path })
    precondition(multiReloaded.largestFolders.first?.path == customCache.path)
    multiReloaded.stopTracking(second.path)
    precondition(!multiReloaded.largestFolders.contains { $0.path.hasPrefix(second.path + "/") })
    precondition(multiReloaded.readings[second.path + "/repo-7"] != nil)
    multi.timer?.invalidate();multi.folderTimer?.invalidate();multiReloaded.timer?.invalidate();multiReloaded.folderTimer?.invalidate()
    precondition(confirmsMissingPath(status: -1, error: ENOENT))
    precondition(confirmsMissingPath(status: -1, error: ENOTDIR))
    for failure in [EACCES, EPERM, EIO] { precondition(!confirmsMissingPath(status: -1, error: failure)) }
    precondition(!confirmsMissingPath(status: 0, error: ENOENT))
    let deletedHome = root.appendingPathComponent("deleted-growth-fixture")
    let deletedFolder = deletedHome.appendingPathComponent("build-target")
    try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
    let deletedSuite = "DiskMonitor.deleted-test." + UUID().uuidString
    let deletedPrefs = UserDefaults(suiteName: deletedSuite)!
    defer { deletedPrefs.removePersistentDomain(forName: deletedSuite) }
    let deletedState = deletedHome.appendingPathComponent("state/readings.json")
    let deletedModel = Model(home: deletedHome.path, preferences: deletedPrefs, saveURL: deletedState, spotlightPath: deletedHome.appendingPathComponent("spotlight").path)
    deletedModel.timer?.invalidate(); deletedModel.folderTimer?.invalidate()
    deletedModel.projects = [Root(path: deletedHome.path, title: "Fixture")]
    let measuredAt = Date()
    deletedModel.readings[deletedFolder.path] = Reading(bytes: 30 * gib, previous: 10 * gib, date: measuredAt)
    precondition(deletedModel.alerts.contains { $0.id == "growth:" + deletedFolder.path })
    try FileManager.default.removeItem(at: deletedFolder)
    deletedModel.refreshMissingGrowthPaths()
    let deletionDeadline = Date().addingTimeInterval(5)
    while deletedModel.readings[deletedFolder.path]?.missing != true && Date() < deletionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(!deletedModel.alerts.contains { $0.id == "growth:" + deletedFolder.path })
    precondition(!deletedModel.largestFolders.contains { $0.path == deletedFolder.path })
    precondition(deletedModel.readings[deletedFolder.path]?.bytes == 30 * gib && deletedModel.readings[deletedFolder.path]?.date == measuredAt)
    let deletedReload = Model(home: deletedHome.path, preferences: deletedPrefs, saveURL: deletedState, spotlightPath: deletedHome.appendingPathComponent("spotlight").path)
    deletedReload.timer?.invalidate(); deletedReload.folderTimer?.invalidate()
    precondition(deletedReload.readings[deletedFolder.path]?.missing == true && deletedReload.readings[deletedFolder.path]?.previous == nil)
    precondition(!deletedReload.alerts.contains { $0.id == "growth:" + deletedFolder.path })
    try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: false)
    let rebased = mergedReading(old: deletedReload.readings[deletedFolder.path], bytes: 40 * gib, error: nil, date: Date())
    precondition(rebased.previous == nil && rebased.missing != true)
    let nextReading = mergedReading(old: rebased, bytes: 51 * gib, error: nil, date: Date())
    precondition(nextReading.previous == 40 * gib)
    let scanner = Scanner(), result = scanner.scan(root.path)
    precondition(result.error == nil && (result.values[root.path] ?? 0) >= 1024 * 1024)
    precondition(result.values[root.appendingPathComponent("folder with spaces").path] != nil)
    precondition(scanner.scan(root.appendingPathComponent("missing").path).error != nil)
    scanner.cancel(); precondition(scanner.scan(root.path).values.isEmpty)
    let model = Model(saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    model.toggle(root.path)
    precondition(model.loadingChildren.contains(root.path))
    model.toggle(root.path) // Collapse before the asynchronous directory read completes.
    let deadline = Date().addingTimeInterval(5)
    while model.loadingChildren.contains(root.path) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(!model.loadingChildren.contains(root.path))
    precondition(!model.expanded.contains(root.path), "Directory completion must not reopen a collapsed row")
    precondition(model.children(root.path).contains { $0.title == "folder with spaces" })
    model.toggle(root.path)
    precondition(model.expanded.contains(root.path) && !model.loadingChildren.contains(root.path), "Reopen must use cached directory entries")
    model.toggle(root.path)
    precondition(!model.expanded.contains(root.path))
    precondition(diskSpaceAlert(free: 200 * gib, capacity: 1000 * gib) == nil)
    precondition(diskSpaceAlert(free: 199 * gib, capacity: 1000 * gib)?.critical == false)
    precondition(diskSpaceAlert(free: 100 * gib, capacity: 1000 * gib)?.critical == false)
    precondition(diskSpaceAlert(free: 99 * gib, capacity: 1000 * gib)?.critical == true)
    precondition(diskSpaceAlert(free: 0, capacity: 0)?.id == "space-unknown")
    model.readings = [:]; model.errors = [:]; model.free = 400 * gib; model.capacity = 1000 * gib
    precondition(model.alerts.isEmpty)
    model.readings[model.project.path] = Reading(bytes: 30 * gib, previous: 10 * gib, date: Date())
    model.readings[model.project.path + "/child"] = Reading(bytes: 25 * gib, previous: 10 * gib, date: Date())
    precondition(model.alerts.filter { $0.id.hasPrefix("growth:") }.count == 1, "Parent and child growth must not duplicate alerts")
    model.readings = [model.project.path: Reading(bytes: 30 * gib, previous: nil, date: Date(), incomplete: true)]
    precondition(model.alerts.count == 1 && model.alerts[0].id.hasPrefix("scan:"))
    let protectedReading = mergedReading(old: nil, bytes: 10, error: "du: /fixture/private: Permission denied", date: Date(), protectedOnly: true)
    let savedProtected = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(protectedReading))
    model.readings = [model.project.path: savedProtected]
    precondition(model.alerts.isEmpty && savedProtected.incomplete == true && savedProtected.previous == nil)
    model.errors[model.project.path] = "Input/output error"
    precondition(model.alerts.count == 1, "Fresh unexpected error overrides saved protection")
    model.protectedPaths.insert(model.project.path)
    precondition(model.alerts.isEmpty)
    model.free = 150 * gib
    precondition(diskBadgeLevel(model.alerts) == 2, "Protected contents must not hide low space")
    model.free = 400 * gib
    model.protectedPaths = []
    model.readings = [:]; model.errors = [model.project.path: "Cancelled"]
    precondition(model.alerts.isEmpty, "User cancellation is not an alert")
    model.scanning = true
    model.activePath = "/fixture/active"
    model.queuedPaths = ["/fixture/waiting"]
    precondition(model.scanState("/fixture/active") == .scanning)
    precondition(model.scanState("/fixture/active/child") == .scanning)
    precondition(model.scanState("/fixture") == .scanning)
    precondition(model.scanState("/fixture/waiting") == .queued)
    precondition(model.scanState("/fixture/waiting/child") == .queued)
    precondition(model.scanState("/fixture/active-other") == .idle)
    model.scanning = false
    precondition(model.scanState("/fixture/active") == .idle)
    precondition(model.scanState("/fixture/waiting") == .idle)
    let suite = "DiskMonitorTests." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    let configured = Model(preferences: prefs, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(configured.diskInterval == 30 && configured.folderInterval == 300)
    precondition(configured.spaceThresholds.critical == 10 && configured.spaceThresholds.warning == 20)
    precondition(configured.configureSpaceThresholds(critical: 15, warning: 30))
    for (critical, warning) in [(0,20), (20,20), (30,20), (10,101), (-1,20)] {
        precondition(!configured.configureSpaceThresholds(critical: critical, warning: warning))
    }
    precondition(configured.spaceThresholds.critical == 15 && configured.spaceThresholds.warning == 30)
    for capacity: Int64 in [1000, 1000000, 1000 * gib] {
        precondition(diskSpaceAlert(free: capacity * 30 / 100, capacity: capacity, thresholds: configured.spaceThresholds) == nil)
        precondition(diskSpaceAlert(free: capacity * 15 / 100, capacity: capacity, thresholds: configured.spaceThresholds)?.critical == false)
        precondition(diskSpaceAlert(free: capacity * 14 / 100, capacity: capacity, thresholds: configured.spaceThresholds)?.critical == true)
    }
    precondition(SpaceThresholds().bytes(100, capacity: Int64.max) == Int64.max)
    precondition(SpaceThresholds().label(10, capacity: 0).contains("unavailable"))
    let oldDiskTimer = configured.timer!, oldFolderTimer = configured.folderTimer!
    precondition(configured.configureIntervals(diskSeconds: 45, folderMinutes: 7))
    precondition(!oldDiskTimer.isValid && !oldFolderTimer.isValid)
    precondition(configured.timer!.timeInterval == 45 && configured.folderTimer!.timeInterval == 420)
    precondition(!configured.configureIntervals(diskSeconds: 0, folderMinutes: 0))
    precondition(configured.diskInterval == 45 && configured.folderInterval == 420)
    let restored = Model(preferences: UserDefaults(suiteName: suite)!, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(restored.diskInterval == 45 && restored.folderInterval == 420)
    precondition(restored.spaceThresholds.critical == 15 && restored.spaceThresholds.warning == 30)
    prefs.set(90, forKey: "criticalFreePercent"); prefs.set(20, forKey: "warningFreePercent")
    let invalidThresholds = Model(preferences: prefs, saveURL: root.appendingPathComponent("state/readings.json"), spotlightPath: root.appendingPathComponent("spotlight-fixture").path)
    precondition(invalidThresholds.spaceThresholds.critical == 10 && invalidThresholds.spaceThresholds.warning == 20)
    invalidThresholds.timer?.invalidate(); invalidThresholds.folderTimer?.invalidate()
    configured.timer?.invalidate(); configured.folderTimer?.invalidate()
    restored.timer?.invalidate(); restored.folderTimer?.invalidate()
    prefs.removePersistentDomain(forName: suite)
    let spotlightFolder = root.appendingPathComponent("spotlight-fixture")
    try fm.createDirectory(at: spotlightFolder, withIntermediateDirectories: true)
    let spotlightState = root.appendingPathComponent("spotlight-state/readings.json")
    let spotlightModel = Model(home: portableHome.path, preferences: prefs, saveURL: spotlightState, spotlightPath: spotlightFolder.path)
    precondition(spotlightModel.caches.contains { $0.path == spotlightFolder.path && $0.title == "Spotlight index" })
    spotlightModel.readings[spotlightFolder.path] = Reading(bytes: 48*gib, date: Date())
    precondition(spotlightModel.largestFolders.contains { $0.path == spotlightFolder.path })
    spotlightModel.stopTracking(spotlightFolder.path)
    precondition(!spotlightModel.caches.contains { $0.path == spotlightFolder.path })
    let spotlightReloaded = Model(home: portableHome.path, preferences: prefs, saveURL: spotlightState, spotlightPath: spotlightFolder.path)
    precondition(spotlightReloaded.defaultCacheOptions.contains { $0.path == spotlightFolder.path })
    precondition(!spotlightReloaded.caches.contains { $0.path == spotlightFolder.path })
    precondition(spotlightReloaded.readings[spotlightFolder.path]?.bytes == 48*gib)
    // Fixture path injection must never turn this into arbitrary privileged scanning.
    spotlightModel.measureSpotlight()
    precondition(!spotlightModel.scanning)
    let prior = Reading(bytes: 12345, date: Date(timeIntervalSince1970: 100))
    spotlightModel.readings[indexPath] = prior
    spotlightModel.errors[indexPath] = "old protected result"
    spotlightModel.protectedPaths.insert(indexPath)
    for outcome in [SpotlightMeasurement.Outcome.cancelled, .failed] {
        spotlightModel.finishSpotlight(outcome)
        precondition(spotlightModel.readings[indexPath]?.bytes == prior.bytes)
        precondition(spotlightModel.readings[indexPath]?.date == prior.date)
        precondition(spotlightModel.errors[indexPath] == "old protected result")
        precondition(spotlightModel.protectedPaths.contains(indexPath))
        precondition(!spotlightModel.scanning && !spotlightModel.administratorMeasurement)
    }
    spotlightModel.finishSpotlight(.measured(98765))
    let authorized = spotlightModel.readings[indexPath]!
    precondition(authorized.bytes == 98765 && authorized.administratorMeasured == true && authorized.previous == nil)
    precondition(spotlightModel.errors[indexPath] == nil && !spotlightModel.protectedPaths.contains(indexPath))
    precondition(try! JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(authorized)).administratorMeasured == true)
    precondition(mergedReading(old: authorized, bytes: 111, error: "denied", date: Date()).bytes == 98765)
    precondition(mergedReading(old: authorized, bytes: 99999, error: nil, date: Date()).previous == nil)
    spotlightModel.timer?.invalidate(); spotlightModel.folderTimer?.invalidate()
    spotlightReloaded.timer?.invalidate(); spotlightReloaded.folderTimer?.invalidate()
    try fm.removeItem(at: root)
    print("PASS: scanner, folders, scan/queue states, alerts, configurable timers and preference persistence")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    launchDiagnostic("beforeRun")
    DispatchQueue.main.asyncAfter(deadline:.now()+3) {launchDiagnostic("runLoop",delegate.item)}
    withExtendedLifetime(delegate) { app.run() }
}
