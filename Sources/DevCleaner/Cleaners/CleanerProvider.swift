import Foundation

public protocol CleanerProvider: Sendable {
    var category: CleanerCategory { get }
    func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem]
    func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult
}

public enum CleanerError: LocalizedError, Equatable {
    case neverDeleteItem(String)
    case runningProcessActive(appName: String, categoryName: String)
    case readOnlyItem(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .neverDeleteItem(let name):
            return "Cleanup blocked: '\(name)' is classified as NEVER DELETE."
        case .runningProcessActive(let appName, let categoryName):
            return "Cleanup blocked: Close \(appName) before cleaning \(categoryName) runtime data."
        case .readOnlyItem(let reason):
            return "This item cannot be deleted automatically: \(reason)"
        case .commandFailed(let msg):
            return "Cleanup command failed: \(msg)"
        }
    }
}

public struct CleanupExecutor: Sendable {
    public let validator: SafetyValidator
    public let freeSpaceProvider: @Sendable () -> Int64
    public let processChecker: @Sendable (CleanerCategory) async -> [String]
    public let trashHandler: @Sendable (URL) throws -> Void

    public init(
        validator: SafetyValidator = SafetyValidator(),
        freeSpaceProvider: @escaping @Sendable () -> Int64 = { DiskScanner.shared.freeDiskSpaceBytes() },
        processChecker: @escaping @Sendable (CleanerCategory) async -> [String] = { category in
            let snapshot = await ProcessMonitor.shared.captureSnapshot()
            return snapshot.matchingProcesses(for: category)
        },
        trashHandler: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.validator = validator
        self.freeSpaceProvider = freeSpaceProvider
        self.processChecker = processChecker
        self.trashHandler = trashHandler
    }

    public func execute(_ item: CleanableItem, ageFilter: AgeFilter = .all) async throws -> CleanupResult {
        // 1. NEVER DELETE items can never execute
        if item.riskLevel == .neverDelete {
            throw CleanerError.neverDeleteItem(item.name)
        }

        // 2. Check readOnlyInfo first
        if case .readOnlyInfo(let reason) = item.actionType {
            throw CleanerError.readOnlyItem(reason)
        }

        // 3. Check item-level running dependency
        if item.isRunningDependency {
            let appName = item.runningProcessNames.isEmpty ? item.category.rawValue : item.runningProcessNames.joined(separator: ", ")
            throw CleanerError.runningProcessActive(appName: appName, categoryName: item.category.rawValue)
        }

        // 4. Re-evaluate live running processes immediately before destructive execution
        // (For Docker CLI prune, Docker Desktop is required to be running, so only block non-prune actions)
        let isDockerCLIPrune: Bool = {
            if case .dockerPrune = item.actionType { return true }
            return false
        }()

        if !isDockerCLIPrune {
            let liveProcesses = await processChecker(item.category)
            if !liveProcesses.isEmpty {
                let appName = liveProcesses.joined(separator: ", ")
                throw CleanerError.runningProcessActive(appName: appName, categoryName: item.category.rawValue)
            }
        }

        let freeBefore = freeSpaceProvider()

        switch item.actionType {
        case .readOnlyInfo(let reason):
            throw CleanerError.readOnlyItem(reason)

        case .moveToTrash(let rawPath):
            let validatedPath = try validator.validateForDeletion(rawPath)
            try validator.validateSubtreeForDeletion(validatedPath)
            guard FileManager.default.fileExists(atPath: validatedPath) else {
                return CleanupResult(processedBytes: 0, movedToTrashBytes: 0, actuallyFreedBytes: 0, action: .moveToTrash)
            }
            let beforeUsage = DiskScanner.shared.measurePath(validatedPath)
            let url = URL(fileURLWithPath: validatedPath)
            try trashHandler(url)
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            let movedBytes = beforeUsage.physicalSize > 0 ? beforeUsage.physicalSize : item.reclaimableSize
            return CleanupResult(
                processedBytes: movedBytes,
                movedToTrashBytes: movedBytes,
                actuallyFreedBytes: freedDelta,
                action: .moveToTrash
            )

        case .moveToTrashContents(let directoryPath, let fixedAge):
            let validatedDir = try validator.validateForDeletion(directoryPath)
            guard FileManager.default.fileExists(atPath: validatedDir) else {
                return CleanupResult(processedBytes: 0, movedToTrashBytes: 0, actuallyFreedBytes: 0, action: .moveToTrash)
            }
            let dirURL = URL(fileURLWithPath: validatedDir, isDirectory: true)
            // Do NOT skip hidden files so we can inspect and block any hidden protected files (.git, .env, etc.)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

            // Pre-flight safety pass: ensure no child or nested descendant is a protected file (.git, .env, credentials) or escaping symlink
            for child in children {
                if child.lastPathComponent == ".DS_Store" { continue }
                let childValidated = try validator.validateForDeletion(child.path)
                try validator.validateSubtreeForDeletion(childValidated)
            }

            let effectiveDays = fixedAge ?? (ageFilter.rawValue > 0 ? ageFilter.rawValue : nil)
            let cutoff: Date? = effectiveDays != nil ? Date().addingTimeInterval(-Double(effectiveDays!) * 86400) : nil

            var movedBytes: Int64 = 0
            for child in children {
                if child.lastPathComponent == ".DS_Store" { continue }
                let childValidated = try validator.validateForDeletion(child.path)
                let usage = DiskScanner.shared.measurePath(childValidated)

                if let cutoffDate = cutoff {
                    let resourceMod = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let latestMod: Date? = {
                        switch (resourceMod, usage.lastModified) {
                        case let (a?, b?): return max(a, b)
                        case let (a?, nil): return a
                        case let (nil, b?): return b
                        case (nil, nil): return nil
                        }
                    }()
                    if let mod = latestMod, mod > cutoffDate {
                        // Preserve recent file/folder
                        continue
                    }
                }

                try trashHandler(URL(fileURLWithPath: childValidated))
                movedBytes += usage.physicalSize
            }

            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: movedBytes,
                movedToTrashBytes: movedBytes,
                actuallyFreedBytes: freedDelta,
                action: .moveToTrash
            )

        case .simctlDeleteDevice(let udid):
            guard UUID(uuidString: udid) != nil else {
                throw CleanerError.commandFailed("Invalid Simulator UDID: \(udid)")
            }
            if let simMeta = item.simulatorMetadata, simMeta.isBooted {
                throw CleanerError.runningProcessActive(appName: "Simulator (\(simMeta.state))", categoryName: item.category.rawValue)
            }
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "delete", udid])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete
            )

        case .simctlDeleteUnavailable:
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete
            )

        case .simctlDeleteRuntime(let identifier):
            let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", identifier])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete
            )

        case .dockerPrune(let subcommand):
            let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            guard let dockerBin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw CleanerError.commandFailed("Docker CLI not found.")
            }
            let res = await ShellRunner.shared.run(dockerBin, arguments: subcommand)
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .dockerPrune
            )
        }
    }
}
