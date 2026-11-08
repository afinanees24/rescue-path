import Foundation
import os

/// Step-by-step connection logging. Each line goes to:
/// - the unified log (Console.app, subsystem com.firefighterhaptics.RadarView, category UWB),
/// - stderr, so `devicectl ... --console` shows it while plugged in,
/// - Documents/uwb-log.txt in the app container, so a walk test can be read afterwards
///   (`xcrun devicectl device copy from --domain-type appDataContainer ...`).
enum Log {
    private static let uwbLogger = Logger(subsystem: "com.firefighterhaptics.RadarView", category: "UWB")
    private static let queue = DispatchQueue(label: "com.firefighterhaptics.RadarView.log")
    nonisolated(unsafe) private static var file: FileHandle?

    static let fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("uwb-log.txt")

    /// Start a fresh log file for this launch.
    static func startFile() {
        queue.sync {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            file = try? FileHandle(forWritingTo: fileURL)
        }
    }

    static func uwb(_ role: AppRole, _ message: String) {
        let tag = role == .beacon ? "BEACON" : "FF"
        uwbLogger.notice("[\(tag, privacy: .public)] \(message, privacy: .public)")
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let line = Data("[UWB \(tag) \(stamp)] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        queue.async { file?.write(line) }
    }
}
