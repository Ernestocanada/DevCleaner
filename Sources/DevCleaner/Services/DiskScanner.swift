import Foundation
import Darwin

public struct DiskUsageInfo: Sendable, Equatable {
    public let logicalSize: Int64
    public let physicalSize: Int64
    public let lastModified: Date?
    public let fileCount: Int

    public init(logicalSize: Int64, physicalSize: Int64, lastModified: Date?, fileCount: Int = 0) {
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
        self.lastModified = lastModified
        self.fileCount = fileCount
    }

    public static let zero = DiskUsageInfo(logicalSize: 0, physicalSize: 0, lastModified: nil, fileCount: 0)
}

public final class DiskScanner: Sendable {
    public static let shared = DiskScanner()

    public init() {}

    /// Returns available free space on the user's home volume in bytes.
    public func freeDiskSpaceBytes() -> Int64 {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let standard = values.volumeAvailableCapacity {
                return Int64(standard)
            }
        } catch {
            // Fallback below
        }
        return 0
    }

    /// Returns filesystem device ID (`st_dev`) for a path without following symlinks.
    private func deviceID(forPath path: String) -> dev_t? {
        var st = stat()
        if lstat(path, &st) == 0 {
            return st.st_dev
        }
        return nil
    }

    /// Calculates logical and physical (allocated APFS/sparse) size of a file or directory,
    /// staying on the same filesystem (`du -x` equivalent) and never traversing symlinks or CoreDevice virtual mounts.
    /// If `minAgeDays` is provided, only counts top-level entries or files modified more than `minAgeDays` ago.
    public func measurePath(_ rawPath: String, minAgeDays: Int? = nil) -> DiskUsageInfo {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Explicitly ignore CoreDevice virtual filesystem or CoreSimulator mounted volumes
        if expanded.hasPrefix("\(home)/Library/Developer/CoreDevice") ||
           expanded.hasPrefix("/Library/Developer/CoreSimulator/Volumes") {
            return .zero
        }

        var rootStat = stat()
        guard lstat(expanded, &rootStat) == 0 else {
            return .zero
        }

        let rootDev = rootStat.st_dev
        let rootModDate = Date(timeIntervalSince1970: TimeInterval(rootStat.st_mtimespec.tv_sec))

        // If it's a single regular file (like Docker.raw)
        if (rootStat.st_mode & S_IFMT) == S_IFREG {
            let logical = Int64(rootStat.st_size)
            let physical = Int64(rootStat.st_blocks) * 512
            if let minDays = minAgeDays, minDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(minDays) * 86400)
                if rootModDate > cutoff {
                    return DiskUsageInfo(logicalSize: 0, physicalSize: 0, lastModified: rootModDate, fileCount: 0)
                }
            }
            return DiskUsageInfo(logicalSize: logical, physicalSize: physical, lastModified: rootModDate, fileCount: 1)
        }

        // If it's a symlink at root, do not follow
        if (rootStat.st_mode & S_IFMT) == S_IFLNK {
            return .zero
        }

        let cutoffDate: Date? = {
            if let days = minAgeDays, days > 0 {
                return Date().addingTimeInterval(-Double(days) * 86400)
            }
            return nil
        }()

        let rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return .zero
        }

        var totalLogical: Int64 = 0
        var totalPhysical: Int64 = 0
        var latestModified: Date? = rootModDate
        var count = 0
        var seenInodes = Set<UInt64>()

        for case let fileURL as URL in enumerator {
            let itemPath = fileURL.path

            // Never enter virtual CoreDevice or mounted simulator volumes
            if itemPath.hasPrefix("\(home)/Library/Developer/CoreDevice") ||
               itemPath.hasPrefix("/Library/Developer/CoreSimulator/Volumes") {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }

            if values.isSymbolicLink == true {
                continue
            }

            if values.isVolume == true {
                enumerator.skipDescendants()
                continue
            }

            // Ensure same filesystem device (`du -x` behavior) and deduplicate hardlinks via inode
            var itemStat = stat()
            if lstat(itemPath, &itemStat) == 0 {
                if itemStat.st_dev != rootDev {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isRegularFile == true {
                    if itemStat.st_nlink > 1 {
                        if seenInodes.contains(itemStat.st_ino) {
                            continue
                        }
                        seenInodes.insert(itemStat.st_ino)
                    }
                }
            }

            if let modDate = values.contentModificationDate {
                if latestModified == nil || modDate > latestModified! {
                    latestModified = modDate
                }
                if let cutoff = cutoffDate, values.isRegularFile == true, modDate > cutoff {
                    continue
                }
            }

            if values.isRegularFile == true {
                let logical = Int64(values.totalFileSize ?? values.fileSize ?? Int(itemStat.st_size))
                let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize
                let physical = allocated != nil ? Int64(allocated!) : (Int64(itemStat.st_blocks) * 512)

                totalLogical += logical
                totalPhysical += physical
                count += 1
            }
        }

        return DiskUsageInfo(
            logicalSize: totalLogical,
            physicalSize: totalPhysical,
            lastModified: latestModified,
            fileCount: count
        )
    }
}
