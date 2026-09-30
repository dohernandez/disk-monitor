import Foundation

// Signed, hardened client. Only Apple frameworks; no updater or plugin loading.
// The host app may request only these fixed operations, never paths or commands.
@main enum ScannerBridge {
    static var connection: NSXPCConnection?
    static var timer: Timer?
    static var connected = false
    static var deadlineReported = false
    static var started = ProcessInfo.processInfo.systemUptime
    static func emit(_ message: BridgeMessage) {
        // Bounded transport: 200 paths of at most 1024 bytes each, plus envelope.
        guard let data = try? JSONEncoder().encode(message), data.count < 262_144 else { exit(2) }
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func finish(_ message: BridgeMessage) -> Never {
        emit(message); exit(0)
    }
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--bundle-self-test"] {
            guard Bundle.main.bundleIdentifier == HelperIdentity.containerID else { exit(1) }
            print("PASS: scanner client belongs to Disk Monitor's main bundle")
            return // No service object, IPC, registration or permission access.
        }
        guard CommandLine.arguments.count == 2,
              ["measure", "cancel", "check", "exclusions"].contains(CommandLine.arguments[1]) else { exit(2) }
        let operation = CommandLine.arguments[1]
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
                guard version == 2 || version == 3 else { finish(BridgeMessage(event: "launchFailed", error: "Incompatible scanner")) }
                if operation == "exclusions" {
                    guard version >= 3 else { finish(BridgeMessage(event: "exclusions", exclusions: .failed("Scanner update required"))) }
                    proxy.exclusions { data in DispatchQueue.main.async {
                        guard data.count < 250_000, let list = try? JSONDecoder().decode(ExclusionList.self, from: data) else {
                            finish(BridgeMessage(event: "exclusions", exclusions: .failed("Invalid scanner response")))
                        }
                        finish(BridgeMessage(event: "exclusions", exclusions: list))
                    } }
                    return
                }
                if operation == "check" {
                    proxy.checkAccess { status in DispatchQueue.main.async {
                        finish(BridgeMessage(event: "access", status: status))
                    } }
                    return
                }
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
