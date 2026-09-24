import Foundation

// Main-thread request state. Uses monotonic uptime, independent of wall-clock changes.
struct RequestState {
    enum Phase: Equatable { case idle, connecting, waiting, finished }
    private(set) var phase: Phase = .idle
    private(set) var id = UUID()
    private(set) var started: TimeInterval = 0
    mutating func begin(now: TimeInterval) -> UUID {
        id = UUID(); phase = .connecting; started = now; return id
    }
    mutating func connected(_ token: UUID, now: TimeInterval) -> Bool {
        guard token == id, phase == .connecting else { return false }
        phase = .waiting; started = now; return true
    }
    func accepts(_ token: UUID) -> Bool {
        token == id && (phase == .connecting || phase == .waiting)
    }
    func expired(now: TimeInterval) -> Bool {
        switch phase {
        case .connecting: return now - started >= 10
        case .waiting: return now - started >= 15 * 60 + 10
        default: return false
        }
    }
    mutating func finish() { phase = .finished; id = UUID() }
}
