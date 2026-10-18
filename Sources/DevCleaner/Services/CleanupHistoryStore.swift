import Foundation

public final class CleanupHistoryStore: @unchecked Sendable {
    public static let shared = CleanupHistoryStore()

    private let fileURL: URL
    private let lock = NSLock()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("DevCleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cleanup_history.json")
    }

    public func loadEntries() -> [CleanupHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CleanupHistoryEntry].self, from: data)) ?? []
    }

    public func appendEntry(_ entry: CleanupHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }

        var current: [CleanupHistoryEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            current = (try? decoder.decode([CleanupHistoryEntry].self, from: data)) ?? []
        }

        current.insert(entry, at: 0)
        if current.count > 500 {
            current = Array(current.prefix(500))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let encoded = try? encoder.encode(current) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }
}
