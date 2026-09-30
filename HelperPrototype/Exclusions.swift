import Foundation
import Darwin

// Read-only view of Spotlight's exclusion list for the Data volume. The list lives in a
// root-only file (/System/Volumes/Data/.Spotlight-V100/VolumeConfiguration.plist, key
// "Exclusions"); Search Privacy shows only folder names, so exact paths need this read.
// Fixed path, no caller input, no writes. Same ancestor checks as the size measurement.
enum SpotlightExclusionReader {
    static let file = SpotlightScanner.target + "/VolumeConfiguration.plist"
    static let maxBytes = 1 << 20, maxPaths = 200, maxPathBytes = 1024
    static func read() -> ExclusionList {
        guard geteuid() == 0 else { return .failed("Helper is not running as administrator") }
        guard SpotlightScanner.ancestors.allSatisfy({ SpotlightScanner.safeDirectory($0) }) else {
            return .failed("Access or safety check failed; verify the scanner’s Full Disk Access")
        }
        return read(file)
    }
    // Test seam: owner defaults to root; the XPC API cannot choose the path.
    static func read(_ path: String, owner: uid_t = 0) -> ExclusionList {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failed("Spotlight settings are unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0, info.st_size >= 0, info.st_size <= maxBytes else {
            return .failed("Spotlight settings failed a safety check")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { return .failed("Spotlight settings could not be read") }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maxBytes else { return .failed("Spotlight settings failed a safety check") }
        }
        return parse(data)
    }
    static func parse(_ data: Data) -> ExclusionList {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return .failed("Spotlight settings have an unexpected format") }
        // A volume that never had an exclusion may omit the key; any other type is unexpected.
        guard let value = root["Exclusions"] else { return ExclusionList(paths: [], readAt: Date(), error: nil) }
        guard let paths = value as? [String], paths.count <= maxPaths,
              paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= maxPathBytes && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else {
            return .failed("Spotlight settings have an unexpected format")
        }
        return ExclusionList(paths: paths, readAt: Date(), error: nil)
    }
}
