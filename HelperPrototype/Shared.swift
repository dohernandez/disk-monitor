import Foundation

// Generated Identity.swift contains only a public certificate fingerprint.
enum HelperIdentity {
    #if DISK_MONITOR
    static let containerID = "local.darien.diskmonitor"
    static let clientName = "ScannerBridge"
    static let appID = "local.darien.diskmonitor.scanner"
    static let serviceID = "local.darien.diskmonitor.scanner.service"
    #else
    static let containerID = "local.darien.diskmonitor.spotlight-setup"
    static let clientName = "Bridge"
    static let appID = "local.darien.diskmonitor.spotlight-setup"
    static let serviceID = "local.darien.diskmonitor.spotlight-setup.scanner"
    #endif
    static func requirement(_ identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor = H\"\(signingCertificateSHA1)\""
    }
}
@objc protocol SpotlightService {
    // No paths, commands, credentials, output locations or scan options accepted.
    // Authentication-only handshake: no scan or filesystem access.
    func cancel(withReply reply: @escaping (Bool) -> Void)
    func ping(withReply reply: @escaping (Int) -> Void)
    func checkAccess(withReply reply: @escaping (Int) -> Void)
    func measure(withReply reply: @escaping (Data) -> Void)
}
struct Measurement: Codable {
    var bytes: Int64?
    var finishedAt: Date
    var error: String?
    static func failed(_ reason: String) -> Measurement {
        Measurement(bytes: nil, finishedAt: Date(), error: reason)
    }
}
