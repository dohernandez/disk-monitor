// Kernel launch validation only: the scanner rejects this argument before any IPC or I/O.
import Foundation
import LightweightCodeRequirements
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Library/LaunchDaemons/local.darien.diskmonitor.scanner.service.plist"))
let values = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
let constraint = values["SpawnConstraint"] as! [String: Any]
let hash = constraint["cdhash"] as! Data
let identifier = constraint["signing-identifier"] as! String
let sip = Process()
sip.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
sip.arguments = ["status"]
let sipOutput = Pipe(); sip.standardOutput = sipOutput
try sip.run()
let sipData = sipOutput.fileHandleForReading.readDataToEndOfFile()
sip.waitUntilExit()
let sipDisabled = sip.terminationStatus == 0 && String(decoding: sipData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines) == "System Integrity Protection status: disabled."
var rejectionVerified = true
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
        if !matches && sipDisabled && process.terminationReason == .exit && process.terminationStatus == 1 {
            rejectionVerified = false
            print("SKIP: kernel rejection is not enforced on this SIP-disabled host; require live SIP-enabled acceptance")
            continue
        }
        precondition(matches ? (process.terminationReason == .exit && process.terminationStatus == 1)
                             : process.terminationReason == .uncaughtSignal,
                     "Constraint matches=\(matches), termination=\(process.terminationReason.rawValue), status=\(process.terminationStatus)")
    } catch {
        precondition(!matches, "Matching scanner constraint rejected: \(error)")
    }
}
print(rejectionVerified
    ? "PASS: kernel accepts matching scanner hash and rejects mismatched hash; no service or scan started"
    : "PASS: matching scanner launch only; kernel rejection was NOT verified")
