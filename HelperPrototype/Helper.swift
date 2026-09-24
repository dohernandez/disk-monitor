import Foundation

final class Service: NSObject, SpotlightService {
    let queue = DispatchQueue(label: "SpotlightPreview.measurement")
    let lock = NSLock()
    var busy = false
    var last: Measurement?
    var cancellation: ScanCancellation?
    func cancel(withReply reply: @escaping (Bool) -> Void) {
        lock.lock(); let current = cancellation; lock.unlock()
        current?.cancel(); reply(current != nil)
    }
    func ping(withReply reply: @escaping (Int) -> Void) { reply(1) }
    func measure(withReply reply: @escaping (Data) -> Void) {
        lock.lock()
        if busy {
            lock.unlock(); reply(try! JSONEncoder().encode(Measurement.failed("Measurement already running"))); return
        }
        if let last, Date().timeIntervalSince(last.finishedAt) < 60 {
            lock.unlock(); reply(try! JSONEncoder().encode(last)); return
        }
        let cancellation = ScanCancellation()
        self.cancellation = cancellation; busy = true; lock.unlock()
        queue.async {
            let result = SpotlightScanner().measure(cancellation: cancellation)
            self.lock.lock(); self.last = result; self.busy = false; self.cancellation = nil; self.lock.unlock()
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
        NSLog("Spotlight scanner started (build %@)", scannerBuildNumber)
        let delegate = Listener()
        let listener = NSXPCListener(machServiceName: HelperIdentity.serviceID)
        listener.delegate = delegate
        withExtendedLifetime(delegate) { listener.resume(); RunLoop.current.run() }
    }
}
