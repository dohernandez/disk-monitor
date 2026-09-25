// Kernel launch validation only: the scanner rejects this argument before any IPC or I/O.
import Foundation
import LightweightCodeRequirements
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Library/LaunchDaemons/local.darien.diskmonitor.scanner.service.plist"))
let values = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
let constraint = values["SpawnConstraint"] as! [String: Any]
let hash = constraint["cdhash"] as! Data
let identifier = constraint["signing-identifier"] as! String
for matches in [true, false] {
    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/Scanner")
    process.arguments = ["--launch-constraint-test"]
    process.launchRequirement = try LaunchCodeRequirement.allOf {
        SigningIdentifier(identifier)
        CodeDirectoryHash(matches ? hash : Data(repeating: 0, count: 20))
    }
    do {
        try process.run()
        process.waitUntilExit()
        precondition(matches ? (process.terminationReason == .exit && process.terminationStatus == 1)
                             : process.terminationReason == .uncaughtSignal)
    } catch {
        precondition(!matches, "Matching scanner constraint rejected: \(error)")
    }
}
print("PASS: kernel accepts matching scanner hash and rejects mismatched hash; no service or scan started")
