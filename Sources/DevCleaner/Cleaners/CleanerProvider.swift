import Foundation

public protocol CleanerProvider: Sendable {
    var category: CleanerCategory { get }
    func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem]
    func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> Int64
}

public enum CleanerError: LocalizedError {
    case runningProcessActive(String)
    case readOnlyItem(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runningProcessActive(let apps):
            return "Close application before cleaning (\(apps))."
        case .readOnlyItem(let reason):
            return "This item cannot be deleted automatically: \(reason)"
        case .commandFailed(let msg):
            return "Cleanup command failed: \(msg)"
        }
    }
}

public struct CleanupExecutor: Sendable {
    public let validator: SafetyValidator

    public init(validator: SafetyValidator = SafetyValidator()) {
        self.validator = validator
    }

    public func execute(_ item: CleanableItem, ageFilter: AgeFilter = .all) async throws -> Int64 {
        if item.isRunningDependency {
            let names = item.runningProcessNames.isEmpty ? item.category.rawValue : item.runningProcessNames.joined(separator: ", ")
            throw CleanerError.runningProcessActive(names)
        }

        switch item.actionType {
        case .readOnlyInfo(let reason):
            throw CleanerError.readOnlyItem(reason)

        case .moveToTrash(let rawPath):
            let validatedPath = try validator.validateForDeletion(rawPath)
            guard FileManager.default.fileExists(atPath: validatedPath) else {
                return 0
            }
            let beforeUsage = DiskScanner.shared.measurePath(validatedPath)
            let url = URL(fileURLWithPath: validatedPath)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return beforeUsage.physicalSize > 0 ? beforeUsage.physicalSize : item.reclaimableSize

        case .moveToTrashContents(let directoryPath, let fixedAge):
            let validatedDir = try validator.validateForDeletion(directoryPath)
            guard FileManager.default.fileExists(atPath: validatedDir) else {
                return 0
            }
            let dirURL = URL(fileURLWithPath: validatedDir, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let effectiveDays = fixedAge ?? (ageFilter.rawValue > 0 ? ageFilter.rawValue : nil)
            let cutoff: Date? = effectiveDays != nil ? Date().addingTimeInterval(-Double(effectiveDays!) * 86400) : nil

            var reclaimed: Int64 = 0
            for child in children {
                let childValidated = try validator.validateForDeletion(child.path)
                if let cutoffDate = cutoff {
                    let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
                    if let mod = values?.contentModificationDate, mod > cutoffDate {
                        continue
                    }
                }
                let usage = DiskScanner.shared.measurePath(childValidated)
                try FileManager.default.trashItem(at: URL(fileURLWithPath: childValidated), resultingItemURL: nil)
                reclaimed += usage.physicalSize
            }
            return reclaimed

        case .simctlDeleteDevice(let udid):
            // Verify UUID format strictly
            guard UUID(uuidString: udid) != nil else {
                throw CleanerError.commandFailed("Invalid Simulator UDID: \(udid)")
            }
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "delete", udid])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            return item.reclaimableSize

        case .simctlDeleteUnavailable:
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            return item.reclaimableSize

        case .simctlDeleteRuntime(let identifier):
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", identifier])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            return item.reclaimableSize

        case .dockerPrune(let subcommand):
            let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            guard let dockerBin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw CleanerError.commandFailed("Docker CLI not found.")
            }
            let res = await ShellRunner.shared.run(dockerBin, arguments: subcommand)
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            return item.reclaimableSize
        }
    }
}
