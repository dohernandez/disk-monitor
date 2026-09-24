import Foundation
import Security

// A .notFound status alone cannot distinguish first setup from a broken bundle.
// Validate the fixed package and pinned signature before offering registration.
enum BundlePolicy {
    static func validateMetadata(at bundle: URL) throws {
        let info = try dictionary(bundle.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == HelperIdentity.containerID else { throw invalid("Unexpected app identity") }
        let plist = try dictionary(bundle.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperIdentity.serviceID + ".plist"))
        guard plist["Label"] as? String == HelperIdentity.serviceID,
              plist["BundleProgram"] as? String == "Contents/MacOS/Scanner",
              plist["Program"] == nil, plist["ProgramArguments"] == nil,
              plist["MachServices"] as? [String: Bool] == [HelperIdentity.serviceID: true] else {
            throw invalid("Scanner package configuration does not match this app")
        }
        guard !FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Library/Scanner").path) else {
            throw invalid("Obsolete nested scanner app is not supported")
        }
        for name in ["Scanner", HelperIdentity.clientName] {
            let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw invalid("Scanner executable is missing or not a regular executable")
            }
        }
        #if DISK_MONITOR
        guard plist["AssociatedBundleIdentifiers"] as? [String] == [HelperIdentity.containerID] else {
            throw invalid("Scanner must belong to Disk Monitor")
        }
        #endif
    }
    static func validate(at bundle: URL) throws {
        try validateMetadata(at: bundle)
        for (path, identifier) in [(bundle.appendingPathComponent("Contents/MacOS/" + HelperIdentity.clientName), HelperIdentity.appID), (bundle.appendingPathComponent("Contents/MacOS/Scanner"), HelperIdentity.serviceID)] {
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(HelperIdentity.requirement(identifier) as CFString, [], &requirement) == errSecSuccess,
                  let code, let requirement,
                  SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
                throw invalid("Scanner signature does not match the expected identity")
            }
        }
    }
    static func canRegister(status: Int, packageValid: Bool) -> Bool {
        packageValid && (status == 0 || status == 3) // notRegistered / notFound
    }
    private static func dictionary(_ url: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else { throw invalid("Invalid package property list") }
        return value
    }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "ScannerPackage", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
