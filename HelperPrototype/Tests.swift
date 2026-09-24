import Foundation
import Security

@main enum Tests {
    static func main() throws {
        precondition(!ScannerRecovery.needsRecovery(pendingBoot: nil, currentBoot: "boot-a"))
        precondition(ScannerRecovery.needsRecovery(pendingBoot: "boot-a", currentBoot: "boot-a"))
        precondition(!ScannerRecovery.needsRecovery(pendingBoot: "boot-a", currentBoot: "boot-b"))
        precondition(ScannerRecovery.needsRecovery(pendingBoot: "boot-a", currentBoot: nil))
        precondition(ScannerRecovery.needsRecovery(pendingBoot: "", currentBoot: "boot-b"))
        precondition(BundlePolicy.canRegister(status: 0, packageValid: true))
        precondition(BundlePolicy.canRegister(status: 3, packageValid: true))
        for state in [0, 1, 2, 3, 999] { precondition(!BundlePolicy.canRegister(status: state, packageValid: false)) }
        for state in [1, 2, 999] { precondition(!BundlePolicy.canRegister(status: state, packageValid: true)) }
        var request = RequestState()
        let old = request.begin(now: 0)
        precondition(!request.expired(now: 9.99) && request.expired(now: 10))
        request.finish()
        precondition(!request.connected(old, now: 11) && !request.accepts(old))
        let current = request.begin(now: 20)
        precondition(!request.connected(old, now: 21))
        precondition(request.connected(current, now: 21))
        precondition(!request.expired(now: 930) && request.expired(now: 931))
        request.finish()
        precondition(!request.accepts(current) && !request.expired(now: 9999))
        var requirement: SecRequirement?
        precondition(SecRequirementCreateWithString(HelperIdentity.requirement(HelperIdentity.appID) as CFString, [], &requirement) == errSecSuccess)
        let target = SpotlightScanner.target
        precondition(SpotlightScanner.parse(Data("12\t\(target)\n".utf8)) == 12288)
        for input in ["-1\t\(target)", "9223372036854775807\t\(target)", "12\t/tmp/other", "12\t\(target)\nerror", "12\t\(target)/child", String(repeating: "x", count: 300)] {
            precondition(SpotlightScanner.parse(Data(input.utf8)) == nil)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Spotlight-helper-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let package = root.appendingPathComponent("Fixture.app")
        let daemonDir = package.appendingPathComponent("Contents/Library/LaunchDaemons")
        let macos = package.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": HelperIdentity.containerID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: package.appendingPathComponent("Contents/Info.plist"))
        let executable = macos.appendingPathComponent("Scanner")
        try Data("fixture only".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = macos.appendingPathComponent(HelperIdentity.clientName)
        try Data("fixture client".utf8).write(to: client)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        let plistURL = daemonDir.appendingPathComponent(HelperIdentity.serviceID + ".plist")
        var daemon: [String: Any] = ["Label": HelperIdentity.serviceID, "BundleProgram": "Contents/MacOS/Scanner", "MachServices": [HelperIdentity.serviceID: true], "AssociatedBundleIdentifiers": [HelperIdentity.containerID]]
        func writeDaemon() throws { try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0).write(to: plistURL) }
        try writeDaemon()
        try BundlePolicy.validateMetadata(at: package)
        do { try BundlePolicy.validate(at: package); preconditionFailure("Unsigned package accepted") } catch {}
        daemon["BundleProgram"] = "/bin/sh"; try writeDaemon()
        do { try BundlePolicy.validateMetadata(at: package); preconditionFailure("Unexpected program accepted") } catch {}
        daemon["BundleProgram"] = "Contents/MacOS/Scanner"; try writeDaemon()
        try fm.removeItem(at: executable)
        try fm.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
        do { try BundlePolicy.validateMetadata(at: package); preconditionFailure("Linked executable accepted") } catch {}
        precondition(SpotlightScanner.safeDirectory(root.path, owner: getuid()))
        precondition(!SpotlightScanner.safeDirectory(root.path, owner: getuid() + 1))
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        precondition(!SpotlightScanner.safeDirectory(root.path, owner: getuid()))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let acl = Process(); acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow read", root.path]
        try acl.run(); acl.waitUntilExit(); precondition(acl.terminationStatus == 0)
        precondition(!SpotlightScanner.safeDirectory(root.path, owner: getuid()))
        let clear = Process(); clear.executableURL = URL(fileURLWithPath: "/bin/chmod")
        clear.arguments = ["-N", root.path]
        try clear.run(); clear.waitUntilExit(); precondition(clear.terminationStatus == 0)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/System")
        precondition(!SpotlightScanner.safeDirectory(link.path))
        try Data(repeating: 1, count: 1024 * 1024).write(to: root.appendingPathComponent("sample"))
        let cancelled = ScanCancellation(); cancelled.cancel()
        let cancelledResult = SpotlightScanner.runDU(root.path, timeout: 10, cancellation: cancelled)
        precondition(cancelledResult.bytes == nil && cancelledResult.error == "Measurement cancelled")
        var cancellationCalls = 0
        cancelled.attach { cancellationCalls += 1 }
        precondition(cancellationCalls == 1, "Cancellation before process attachment must not be lost")
        cancelled.detach(); cancelled.cancel(); precondition(cancellationCalls == 1)
        let result = SpotlightScanner.runDU(root.path, timeout: 10)
        precondition(result.error == nil && result.bytes! >= 1024 * 1024 && result.bytes! < 2 * 1024 * 1024, "Must not follow link into /System")
        precondition(SpotlightScanner.runDU(root.appendingPathComponent("missing").path, timeout: 10).bytes == nil)
        print("PASS: policy syntax, strict totals, directory ownership/mode/link checks, real fixture du and failure preservation contract")
    }
}
