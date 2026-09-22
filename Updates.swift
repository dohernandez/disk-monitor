import Cocoa
import SwiftUI
import Combine
import Sparkle

/// One updater per app; it starts only in the normal application lifecycle.
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var installTimer: Timer?
    private var busy: () -> Bool = { false }
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
            Button("Check for Updates…") { updates.check() }.disabled(!updates.ready)
            Toggle("Check for updates daily", isOn: Binding(get: { updates.checks }, set: { updates.setChecks($0) }))
            Toggle("Download and install updates automatically", isOn: Binding(get: { updates.downloads }, set: { updates.setDownloads($0) })).disabled(!updates.checks)
            Text("These choices save immediately. Automatic installation happens when the app quits; a requested restart waits for active measurements to finish. Updates and their feed must pass signature verification.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Checks contact GitHub. No folder measurements, token records, or system profile are sent.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = updates.lastCheck { Text("Last update check: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            if let failure = updates.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.font(.system(size: 11))
    }
}
