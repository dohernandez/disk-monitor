import Foundation

final class Service: NSObject, SpotlightService {
    let queue = DispatchQueue(label: "SpotlightPreview.measurement")
    let lock = NSLock()
    var busy = false
    var last: Measurement?
    func ping(withReply reply: @escaping (Int) -> Void) { reply(1) }
    func measure(withReply reply: @escaping (Data) -> Void) {
        lock.lock()
        if busy {
            lock.unlock(); reply(try! JSONEncoder().encode(Measurement.failed("Measurement already running"))); return
        }
        if let last, Date().timeIntervalSince(last.finishedAt) < 60 {
            lock.unlock(); reply(try! JSONEncoder().encode(last)); return
        }
        busy = true; lock.unlock()
        queue.async {
            let result = SpotlightScanner().measure()
            self.lock.lock(); self.last = result; self.busy = false; self.lock.unlock()
            reply(try! JSONEncoder().encode(result))
        }
    }
}
final class Listener: NSObject, NSXPCListenerDelegate {
    let service = Service()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperIdentity.requirement(HelperIdentity.appID))
        connection.exportedInterface = NSXPCInterface(with: SpotlightService.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
@main enum Main {
    static func main() {
        guard CommandLine.arguments.count == 1, geteuid() == 0 else { exit(1) }
        let delegate = Listener()
        let listener = NSXPCListener(machServiceName: HelperIdentity.serviceID)
        listener.delegate = delegate
        withExtendedLifetime(delegate) { listener.resume(); RunLoop.current.run() }
    }
}
