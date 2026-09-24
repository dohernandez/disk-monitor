import Foundation

/// A new boot is the only local evidence that an orphaned scan cannot still run.
enum ScannerRecovery {
    static func needsRecovery(pendingBoot: String?, currentBoot: String?) -> Bool {
        guard let pendingBoot else { return false }
        guard let currentBoot, !currentBoot.isEmpty, !pendingBoot.isEmpty else { return true }
        return pendingBoot == currentBoot
    }

    static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
