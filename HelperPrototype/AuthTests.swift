import Foundation

final class FixtureService: NSObject, SpotlightService {
    let lock = NSLock()
    var count = 0
    func cancel(withReply reply: @escaping (Bool) -> Void) { reply(false) }
    func ping(withReply reply: @escaping (Int) -> Void) { reply(2) }
    func checkAccess(withReply reply: @escaping (Int) -> Void) { reply(0) }
    func measure(withReply reply: @escaping (Data) -> Void) {
        lock.lock(); count += 1; lock.unlock()
        reply(Data("fixture".utf8))
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class FixtureListener: NSObject, NSXPCListenerDelegate {
    let service = FixtureService()
    let requirement: String
    init(_ requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: SpotlightService.self)
        connection.exportedObject = service
        connection.resume(); return true
    }
}
final class ResultBox {
    let lock = NSLock()
    var finished = false
    var success = false
    func finish(_ value: Bool) { lock.lock(); finished = true; success = value; lock.unlock() }
    var value: (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (finished, success) }
}
@main enum AuthTests {
    static func check(clientID: String, serverID: String, allowed: Bool) {
        let delegate = FixtureListener(HelperIdentity.requirement(clientID))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate; listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.setCodeSigningRequirement(HelperIdentity.requirement(serverID))
        connection.remoteObjectInterface = NSXPCInterface(with: SpotlightService.self)
        connection.resume()
        let result = ResultBox()
        let remote = connection.remoteObjectProxyWithErrorHandler { error in fputs("XPC error: \(error)\n", stderr); result.finish(false) } as! SpotlightService
        remote.measure { data in result.finish(data == Data("fixture".utf8)) }
        let deadline = Date().addingTimeInterval(5)
        while !result.value.0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        fputs("Case client=\(clientID) server=\(serverID) expected=\(allowed) result=\(result.value) calls=\(delegate.service.calls)\n", stderr)
        precondition(result.value.0 && result.value.1 == allowed)
        if clientID != HelperIdentity.appID { precondition(delegate.service.calls == 0) }
        connection.invalidate(); listener.invalidate()
    }
    static func main() {
        check(clientID: HelperIdentity.appID, serverID: HelperIdentity.appID, allowed: true)
        check(clientID: "local.untrusted", serverID: HelperIdentity.appID, allowed: false)
        check(clientID: HelperIdentity.appID, serverID: "local.untrusted", allowed: false)
        print("PASS: real loopback XPC permits pinned identity, rejects wrong clients before service invocation and rejects replies from wrong servers")
    }
}
