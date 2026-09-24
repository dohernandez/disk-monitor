import Foundation
import ServiceManagement

// Signed, hardened client. Only Apple frameworks; no updater or plugin loading.
// The host app may request only these fixed operations, never paths or commands.
@main enum ScannerBridge {
    static var connection: NSXPCConnection?
    static var timer: Timer?
    static var connected = false
    static var deadlineReported = false
    static var started = ProcessInfo.processInfo.systemUptime
    static func emit(_ message: BridgeMessage) {
        guard let data = try? JSONEncoder().encode(message), data.count < 2048 else { exit(2) }
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func finish(_ message: BridgeMessage) -> Never {
        emit(message); exit(0)
    }
    static func main() {
        guard CommandLine.arguments.count == 2,
              ["status", "register", "unregister", "measure", "cancel"].contains(CommandLine.arguments[1]) else { exit(2) }
        let operation = CommandLine.arguments[1]
        let service = SMAppService.daemon(plistName: HelperIdentity.serviceID + ".plist")
        if operation == "status" { finish(BridgeMessage(event: "status", status: service.status.rawValue)) }
        if operation == "register" {
            do { try service.register(); finish(BridgeMessage(event: "status", status: service.status.rawValue)) }
            catch { finish(BridgeMessage(event: "status", status: service.status.rawValue, error: error.localizedDescription)) }
        }
        if operation == "unregister" {
            service.unregister { error in
                finish(BridgeMessage(event: "status", status: service.status.rawValue, error: error?.localizedDescription))
            }
            RunLoop.current.run(); exit(2)
        }
        let c = NSXPCConnection(machServiceName: HelperIdentity.serviceID, options: .privileged)
        c.setCodeSigningRequirement(HelperIdentity.requirement(HelperIdentity.serviceID))
        c.remoteObjectInterface = NSXPCInterface(with: SpotlightService.self)
        let lost = { DispatchQueue.main.async {
            if connected {
                // Do not report completion or exit as if the root child stopped.
                emit(BridgeMessage(event: "uncertain", error: "Scanner connection lost; completion unconfirmed"))
            } else { finish(BridgeMessage(event: "launchFailed", error: "Scanner could not connect")) }
        }
        }
        c.interruptionHandler = lost; c.invalidationHandler = lost
        connection = c; c.resume()
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in lost() } as! SpotlightService
        if operation == "cancel" {
            proxy.cancel { accepted in finish(BridgeMessage(event: "cancelRequested", status: accepted ? 1 : 0)) }
        } else {
            proxy.ping { version in DispatchQueue.main.async {
                guard version == 1 else { finish(BridgeMessage(event: "launchFailed", error: "Incompatible scanner")) }
                connected = true; started = ProcessInfo.processInfo.systemUptime
                emit(BridgeMessage(event: "measuring"))
                proxy.measure { data in DispatchQueue.main.async {
                    guard data.count < 1024, let result = try? JSONDecoder().decode(Measurement.self, from: data) else {
                        finish(BridgeMessage(event: "result", measurement: .failed("Invalid scanner response")))
                    }
                    finish(BridgeMessage(event: "result", measurement: result))
                } }
            } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if !connected && elapsed >= 10 { finish(BridgeMessage(event: "launchFailed", error: "Scanner connection timed out")) }
            if connected && elapsed >= 910 && !deadlineReported {
                deadlineReported = true
                proxy.cancel { _ in }
                emit(BridgeMessage(event: "uncertain", error: "Deadline passed; waiting for scanner cancellation"))
            }
        }
        RunLoop.current.run()
    }
}
