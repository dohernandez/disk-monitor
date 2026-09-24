import Foundation
import Security

@main enum Tests {
    static func main() throws {
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
        let result = SpotlightScanner.runDU(root.path, timeout: 10)
        precondition(result.error == nil && result.bytes! >= 1024 * 1024 && result.bytes! < 2 * 1024 * 1024, "Must not follow link into /System")
        precondition(SpotlightScanner.runDU(root.appendingPathComponent("missing").path, timeout: 10).bytes == nil)
        print("PASS: policy syntax, strict totals, directory ownership/mode/link checks, real fixture du and failure preservation contract")
    }
}
