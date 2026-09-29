import Cocoa
import SwiftUI
import Combine
import Sparkle

/// One updater per app; it starts only in the normal application lifecycle.
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdates()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var installTimer: Timer?
    private var busy: () -> Bool = { false }
    var onChange: (() -> Void)?
    @Published private(set) var pendingVersion: String? { didSet { onChange?() } }
    @Published private(set) var installsOnQuit = false
    var supportsGentleScheduledUpdateReminders: Bool { true }
    var pendingTitle: String? {
        pendingVersion.map { "Disk Monitor " + $0 + (installsOnQuit ? " · ready to install on quit" : " · update available") }
    }
    func recordPending(_ version: String, onQuit: Bool = false) {
        if pendingVersion != version { installsOnQuit = false }
        installsOnQuit = installsOnQuit || onQuit
        pendingVersion = version
        failure = nil
    }
    func clearPending() { installsOnQuit = false; pendingVersion = nil }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        recordPending(update.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { recordPending(item.displayVersionString) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { failure = nil; if !installsOnQuit { clearPending() } }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        recordPending(item.displayVersionString, onQuit: true)
        return false // Sparkle retains installation and scheduling ownership.
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { clearPending() }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let issue = error as NSError
        if issue.domain != SUSparkleErrorDomain || issue.code != SUError.noUpdateError.rawValue { failure = "Update failed: " + error.localizedDescription }
    }
    @Published private(set) var ready = false
    @Published private(set) var checks = false
    @Published private(set) var downloads = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var failure: String?
    func start(busy: @escaping () -> Bool) {
        self.busy = busy
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$ready)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$downloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        do { try updater.start() } catch { failure = "Updates unavailable: " + error.localizedDescription }
    }
    func testReminderCallbacks() {
        let updater = controller.updater
        recordPending("2.0", onQuit: true)
        updaterDidNotFindUpdate(updater)
        precondition(installsOnQuit && pendingVersion == "2.0")
        self.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        precondition(failure == nil)
        self.updater(updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: -1009))
        precondition(failure != nil && pendingVersion == "2.0")
        recordPending("2.1"); updaterDidNotFindUpdate(updater)
        precondition(failure == nil && pendingVersion == nil)
        precondition(responds(to: NSSelectorFromString("updater:userDidMakeChoice:forUpdate:state:")))
        precondition(responds(to: NSSelectorFromString("updater:willInstallUpdateOnQuit:immediateInstallationBlock:")))
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func check() { controller.checkForUpdates(nil) }
    func setChecks(_ value: Bool) { controller.updater.automaticallyChecksForUpdates = value }
    func setDownloads(_ value: Bool) { controller.updater.automaticallyDownloadsUpdates = value }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy() else { return false }
        installTimer?.invalidate()
        installTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self, !self.busy() else { return }
            timer.invalidate(); self.installTimer = nil; installHandler()
        }
        return true
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App updates").font(.system(size: 13, weight: .semibold))
            Text("Installed version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Preview")).font(.caption).foregroundStyle(.secondary)
            if let title = updates.pendingTitle { Text(title).foregroundStyle(.blue) }
            Button(updates.pendingVersion == nil ? "Check for Updates…" : "Show Update…") { updates.check() }.disabled(!updates.ready)
            Toggle("Check for updates daily", isOn: Binding(get: { updates.checks }, set: { updates.setChecks($0) }))
            Toggle("Download and install updates automatically", isOn: Binding(get: { updates.downloads }, set: { updates.setDownloads($0) })).disabled(!updates.checks)
            Text("These choices save immediately. Automatic installation happens when the app quits; a requested restart waits for active measurements to finish. Updates and their feed must pass signature verification.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Checks contact GitHub. No folder measurements, token records, or system profile are sent.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = updates.lastCheck { Text("Last update check: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            if let failure = updates.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.font(.system(size: 11))
    }
}

struct PendingUpdateNotice: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        if let title = updates.pendingTitle {
            Button { updates.check() } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(title).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                }.padding(10).background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!updates.ready).accessibilityLabel(title + ". Show update")
        }
    }
}
