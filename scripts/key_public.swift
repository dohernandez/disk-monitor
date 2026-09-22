import Foundation
import CryptoKit
// Seeds arrive over stdin, never argv or logs. Verification needs only public data.
do {
    if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--verify" {
        guard let publicData = Data(base64Encoded: CommandLine.arguments[3]), let signature = Data(base64Encoded: CommandLine.arguments[4]) else { exit(1) }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(key.isValidSignature(signature, for: data) ? 0 : 1)
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: input, encoding: .utf8), let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(1) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch { exit(1) }
