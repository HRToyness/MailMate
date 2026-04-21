import Foundation

enum Log {
    private static let maxBytes: UInt64 = 1_000_000
    private static let queue = DispatchQueue(label: "com.toynessit.MailMate.log")

    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs,
                                                 withIntermediateDirectories: true)
        return logs.appendingPathComponent("MailMate.log")
    }()

    private static let rotatedURL: URL = {
        fileURL.deletingPathExtension().appendingPathExtension("1.log")
    }()

    static func write(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }
}
