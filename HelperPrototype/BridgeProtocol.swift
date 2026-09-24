import Foundation

struct BridgeMessage: Codable {
    var event: String
    var status: Int? = nil
    var measurement: Measurement? = nil
    var error: String? = nil
}
