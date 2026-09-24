import Foundation

// Generated Identity.swift contains only a public certificate fingerprint.
enum HelperIdentity {
    static let appID = "local.darien.diskmonitor.spotlight-preview"
    static let serviceID = "local.darien.diskmonitor.spotlight-preview.scanner"
    static func requirement(_ identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor = H\"\(signingCertificateSHA1)\""
    }
}
@objc protocol SpotlightService {
    // No paths, commands, credentials, output locations or scan options accepted.
    // Authentication-only handshake: no scan or filesystem access.
    func ping(withReply reply: @escaping (Int) -> Void)
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
