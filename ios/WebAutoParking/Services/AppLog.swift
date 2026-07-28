import Foundation

/// Append-only app log under Application Support (served on LAN when enabled).
enum AppLog {
    private static let queue = DispatchQueue(label: "com.webautoparking.app-log")
    private static let maxBytes = 256 * 1024
    private static var buffer = ""

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static var logURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        return dir.appendingPathComponent("latest.txt")
    }

    static func ensureReady() {
        queue.sync {
            ensureDirectoryLocked()
            guard !FileManager.default.fileExists(atPath: logURL.path) else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            appendLineLocked("Log ready (Parking \(version) build \(build))")
            appendLineLocked("path=\(logURL.path)")
            flushLocked()
        }
    }

    static func log(_ message: String) {
        queue.sync {
            ensureDirectoryLocked()
            truncateIfNeededLocked()
            appendLineLocked(message)
            flushLocked()
        }
    }

    /// Full log text for LAN `/` and `/logs.txt`.
    static func readAllText() -> String {
        queue.sync {
            flushLocked()
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8) else {
                return "(empty log)\n"
            }
            return text
        }
    }

    // MARK: - Private

    private static func appendLineLocked(_ message: String) {
        buffer += "\(isoFormatter.string(from: Date())) \(message)\n"
    }

    private static func ensureDirectoryLocked() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func flushLocked() {
        guard let data = buffer.data(using: .utf8), !data.isEmpty else { return }
        let url = logURL
        ensureDirectoryLocked()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            buffer = ""
        } catch {
            let note = "\(isoFormatter.string(from: Date())) LOG FLUSH FAILED: \(error.localizedDescription)\n"
            let fallback = (note.data(using: .utf8) ?? Data()) + data
            try? fallback.write(to: url, options: .atomic)
            buffer = ""
        }
    }

    private static func truncateIfNeededLocked() {
        let url = logURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let keep = String(text.suffix(maxBytes / 2))
        try? ("… truncated …\n" + keep).write(to: url, atomically: true, encoding: .utf8)
    }
}
