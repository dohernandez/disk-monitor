import Foundation
import Darwin

// All operations are metadata reads. Neither the helper nor du writes monitored files.
final class SpotlightScanner {
    static let scanTimeout: TimeInterval = 15 * 60
    static let target = "/System/Volumes/Data/.Spotlight-V100"
    static let ancestors = ["/", "/System", "/System/Volumes", "/System/Volumes/Data", target]
    static func safeDirectory(_ path: String, owner: uid_t = 0) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        errno = 0
        guard let acl = acl_get_fd(fd) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        // macOS returns 0 for an entry, -1 at end. Reject any extended ACL.
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
    // Fixed metadata-only preflight: 0 readable, 1 permission denied, 2 safety/unavailable.
    // No traversal, size measurement, credentials, or caller-selected path.
    static func accessStatus() -> Int {
        guard geteuid() == 0 else { return 2 }
        for path in ancestors {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return errno == EACCES || errno == EPERM ? 1 : 2 }
            close(fd)
            guard safeDirectory(path) else { return 2 }
        }
        return 0
    }
    static func parse(_ data: Data, expectedPath: String = target) -> Int64? {
        guard data.count < 256, let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == expectedPath, !fields[0].isEmpty,
              fields[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let kib = Int64(fields[0]), kib <= Int64.max / 1024 else { return nil }
        return kib * 1024
    }
    func measure(cancellation: ScanCancellation) -> Measurement {
        guard geteuid() == 0 else { return .failed("Helper is not running as administrator") }
        guard Self.ancestors.allSatisfy({ Self.safeDirectory($0) }) else {
            return .failed("Access or safety check failed; verify the scanner’s Full Disk Access")
        }
        return Self.runDU(Self.target, timeout: Self.scanTimeout, cancellation: cancellation)
    }
    // Internal test seam only. The XPC API cannot select a path or timeout.
    static func runDU(_ target: String, timeout: TimeInterval, cancellation: ScanCancellation = ScanCancellation()) -> Measurement {
        guard !cancellation.isCancelled else { return .failed("Measurement cancelled") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-P", "-x", "-s", "-k", target]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe
        let state = ProcessState(process)
        let deadline = DispatchWorkItem { state.timeout() }
        do { try process.run() } catch { return .failed("Cannot start system size check") }
        cancellation.attach { state.timeout() }
        defer { cancellation.detach() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // du -s emits one line for the fixed target. Still bound transport memory.
        var result = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 256), !chunk.isEmpty {
            if result.count + chunk.count > 255 { state.timeout(); break }
            result.append(chunk)
        }
        process.waitUntilExit()
        deadline.cancel()
        let timedOut = state.finish()
        if cancellation.isCancelled { return .failed("Measurement cancelled") }
        guard !timedOut, process.terminationReason == .exit, process.terminationStatus == 0,
              let bytes = parse(result, expectedPath: target) else {
            return .failed(timedOut ? "Measurement timed out" : "Size check failed; saved reading must be retained")
        }
        return Measurement(bytes: bytes, finishedAt: Date(), error: nil)
    }
}
private final class ProcessState {
    let process: Process
    let lock = NSLock()
    var finished = false
    var expired = false
    init(_ process: Process) { self.process = process }
    func timeout() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, process.isRunning else { return }
        expired = true
        // Kill only the owned child while Foundation still considers it running.
        process.terminate()
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        finished = true; return expired
    }
}

// Cancellation can be requested before the owned child has started. No PID supplied
// by a client is accepted; the action refers only to this measurement's Process.
final class ScanCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); cancelled = true; let callback = action; lock.unlock()
        callback?()
    }
    func attach(_ callback: @escaping () -> Void) {
        lock.lock(); action = callback; let alreadyCancelled = cancelled; lock.unlock()
        if alreadyCancelled { callback() }
    }
    func detach() { lock.lock(); action = nil; lock.unlock() }
}
