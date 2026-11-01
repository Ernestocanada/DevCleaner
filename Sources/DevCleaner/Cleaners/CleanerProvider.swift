import Foundation

public protocol CleanerProvider: Sendable {
    var category: CleanerCategory { get }
    func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem]
    func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult
}

public enum CleanerError: LocalizedError, Equatable {
    case neverDeleteItem(String)
    case runningProcessActive(appName: String, categoryName: String)
    case simulatorDeviceActive(deviceName: String, state: String)
    case readOnlyItem(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .neverDeleteItem(let name):
            return "Cleanup blocked: '\(name)' is classified as NEVER DELETE."
        case .runningProcessActive(let appName, let categoryName):
            return "Cleanup blocked: Close \(appName) before cleaning \(categoryName) runtime data."
        case .simulatorDeviceActive(let deviceName, _):
            return "Cleanup blocked: \(deviceName) is currently active.\nShut down this simulator before deleting it."
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
    public let shellRunner: @Sendable (String, [String]) async -> ShellResult
    public let avdManagerResolver: @Sendable () -> String?

    public init(
        validator: SafetyValidator = SafetyValidator(),
        freeSpaceProvider: @escaping @Sendable () -> Int64 = { DiskScanner.shared.freeDiskSpaceBytes() },
        processChecker: @escaping @Sendable (CleanerCategory) async -> [String] = { category in
            let snapshot = await ProcessMonitor.shared.captureSnapshot()
            return snapshot.matchingProcesses(for: category)
        },
        trashHandler: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        shellRunner: @escaping @Sendable (String, [String]) async -> ShellResult = { executable, arguments in
            await ShellRunner.shared.run(executable, arguments: arguments)
        },
        avdManagerResolver: (@Sendable () -> String?)? = nil
    ) {
        self.validator = validator
        self.freeSpaceProvider = freeSpaceProvider
        self.processChecker = processChecker
        self.trashHandler = trashHandler
        self.shellRunner = shellRunner
        self.avdManagerResolver = avdManagerResolver ?? {
            AndroidCleaner.resolveAVDManagerBinary(homeDirectory: validator.homeDirectory)
        }
    }

    public func execute(_ item: CleanableItem, ageFilter: AgeFilter = .all) async throws -> CleanupResult {
        // 1. NEVER DELETE items can never execute
        if item.riskLevel == .neverDelete {
            throw CleanerError.neverDeleteItem(item.name)
        }

        // 1b. Favorite simulators are strictly protected from deletion
        if item.simulatorMetadata?.isFavorite == true {
            throw CleanerError.readOnlyItem("Simulator '\(item.name)' is marked as Favorite and protected from deletion.")
        }

        // 2. Check readOnlyInfo first
        if case .readOnlyInfo(let reason) = item.actionType {
            throw CleanerError.readOnlyItem(reason)
        }

        let isPerDeviceSimulatorDelete: Bool = {
            if case .simctlDeleteDevice = item.actionType { return true }
            return false
        }()

        // 3. Check item-level running dependency (per-device simulator delete re-queries live simctl state below)
        if !isPerDeviceSimulatorDelete && item.isRunningDependency {
            let appName = item.runningProcessNames.isEmpty ? item.category.rawValue : item.runningProcessNames.joined(separator: ", ")
            throw CleanerError.runningProcessActive(appName: appName, categoryName: item.category.rawValue)
        }

        // 4. Re-evaluate live running processes immediately before destructive execution:
        //    - cache/runtime filesystem cleanup, simctlDeleteRuntime, and simctlDeleteUnavailable require category processes closed
        //    - simctlDeleteDevice validates only the selected UDID's current live state via simctl
        //    - dockerPrune uses Docker CLI against the running daemon
        let bypassesCategoryProcessBlocker: Bool = {
            switch item.actionType {
            case .dockerPrune, .simctlDeleteDevice:
                return true
            default:
                return false
            }
        }()

        if !bypassesCategoryProcessBlocker {
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
            try validator.validateNotModifiedSinceScan(validatedPath, expectedModifiedAt: item.lastModified)
            try validator.validateSubtreeForDeletion(validatedPath)
            guard FileManager.default.fileExists(atPath: validatedPath) else {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: "Nothing eligible for cleanup."
                )
            }
            let beforeUsage = DiskScanner.shared.measurePath(validatedPath)
            let url = URL(fileURLWithPath: validatedPath)
            try trashHandler(url)
            let movedBytes = beforeUsage.physicalSize > 0 ? beforeUsage.physicalSize : item.reclaimableSize
            if movedBytes == 0 {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: "Nothing eligible for cleanup."
                )
            }
            // Moving to Trash does not immediately free APFS disk blocks; never attribute background fluctuations
            return CleanupResult(
                processedBytes: movedBytes,
                movedToTrashBytes: movedBytes,
                actuallyFreedBytes: 0,
                action: .moveToTrash,
                status: .cleaned,
                message: "Moved to macOS Trash (\(Formatters.bytes(movedBytes))). Empty Trash to recover disk space."
            )

        case .moveToTrashVerifiedProjectArtifact(let rawPath, let projectRoot, let expectedModifiedAt):
            let validatedPath = try validator.validateVerifiedProjectArtifactForDeletion(
                rawPath,
                projectRoot: projectRoot,
                expectedModifiedAt: expectedModifiedAt,
                checkSymlinksOnDisk: true
            )
            guard FileManager.default.fileExists(atPath: validatedPath) else {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: "Nothing eligible for cleanup."
                )
            }
            let beforeUsage = DiskScanner.shared.measurePath(validatedPath)
            let url = URL(fileURLWithPath: validatedPath)
            try trashHandler(url)
            let movedBytes = beforeUsage.physicalSize > 0 ? beforeUsage.physicalSize : item.reclaimableSize
            if movedBytes == 0 {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: "Nothing eligible for cleanup."
                )
            }
            return CleanupResult(
                processedBytes: movedBytes,
                movedToTrashBytes: movedBytes,
                actuallyFreedBytes: 0,
                action: .moveToTrash,
                status: .cleaned,
                message: "Moved verified project artifact to macOS Trash (\(Formatters.bytes(movedBytes))). Empty Trash to recover disk space."
            )

        case .moveToTrashContents(let directoryPath, let fixedAge):
            let validatedDir = try validator.validateForDeletion(directoryPath)
            guard FileManager.default.fileExists(atPath: validatedDir) else {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: "Nothing eligible for cleanup."
                )
            }

            let dirURL = URL(fileURLWithPath: validatedDir, isDirectory: true)
            let topLevelChildren = (try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

            // Reject if any direct top-level file is itself a forbidden component (e.g. .env or .git placed directly in cache root)
            for child in topLevelChildren {
                if child.lastPathComponent == ".DS_Store" { continue }
                if validator.isForbiddenComponentName(child.lastPathComponent) {
                    throw SafetyError.forbiddenFileOrComponent(child.path)
                }
            }

            let effectiveFilter: AgeFilter = {
                if let d = fixedAge, let f = AgeFilter(rawValue: d) {
                    return f
                }
                return ageFilter
            }()

            let planner = CleanupPlanner(validator: validator)
            let plan = planner.planDirectoryContents(
                directoryPath: validatedDir,
                baseRisk: item.riskLevel,
                ageFilter: effectiveFilter,
                supportsAgeFilter: true,
                isRunningDependency: false
            )

            // If there are NO eligible entries and at least one protected/blocked entry, surface the SafetyError
            if plan.eligibleEntries.isEmpty, let firstProtected = plan.protectedOrReviewEntries.first {
                let childValidated = try validator.validateForDeletion(firstProtected.path)
                try validator.validateSubtreeForDeletion(childValidated)
            }

            if plan.eligibleEntries.isEmpty {
                let noOpMsg = effectiveFilter != .all
                    ? "Nothing eligible for cleanup with the current \(effectiveFilter.rawValue)-day filter."
                    : "Nothing eligible for cleanup."
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .nothingEligible,
                    message: noOpMsg
                )
            }

            var movedBytes: Int64 = 0
            for entry in plan.eligibleEntries {
                // Re-validate immediately prior to trashing each eligible child
                let childValidated = try validator.validateForDeletion(entry.path)
                let expectedChildMod = item.plan?.entries.first(where: { $0.path == entry.path })?.lastModified ?? item.lastModified
                try validator.validateNotModifiedSinceScan(childValidated, expectedModifiedAt: expectedChildMod)
                try validator.validateSubtreeForDeletion(childValidated)
                try trashHandler(URL(fileURLWithPath: childValidated))
                movedBytes += entry.physicalBytes
            }

            let skippedCount = plan.protectedOrReviewEntries.count
            let summaryMsg: String = {
                if skippedCount > 0 {
                    return "Moved \(Formatters.bytes(movedBytes)) to macOS Trash (\(skippedCount) entry skipped for review)."
                }
                return "Moved \(Formatters.bytes(movedBytes)) to macOS Trash. Empty Trash to recover disk space."
            }()

            // For moveToTrash operations, per-item actuallyFreedBytes is 0 (blocks are freed when Trash is emptied)
            return CleanupResult(
                processedBytes: movedBytes,
                movedToTrashBytes: movedBytes,
                actuallyFreedBytes: 0,
                action: .moveToTrash,
                status: movedBytes > 0 ? .cleaned : .nothingEligible,
                message: summaryMsg
            )

        case .simctlDeleteDevice(let udid):
            guard UUID(uuidString: udid) != nil else {
                throw CleanerError.commandFailed("Invalid Simulator UDID: \(udid)")
            }

            // Re-query simctl immediately before deletion — never infer state from earlier UI scan
            let listRes = await shellRunner("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
            guard listRes.isSuccess, let listData = listRes.stdout.data(using: .utf8) else {
                let detail = listRes.stderr.isEmpty ? listRes.stdout : listRes.stderr
                throw CleanerError.commandFailed("Unable to verify simulator state via simctl: \(detail)")
            }

            let liveDevice: SimulatorCleaner.LiveDeviceState?
            do {
                liveDevice = try SimulatorCleaner.lookupDeviceState(udid: udid, in: listData)
            } catch {
                throw CleanerError.commandFailed("Unable to parse simulator state from simctl: \(error.localizedDescription)")
            }

            guard let targetDevice = liveDevice else {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .simctlDelete,
                    status: .nothingEligible,
                    message: "Simulator \(udid) no longer exists (nothing eligible for deletion)."
                )
            }

            guard targetDevice.isShutdown else {
                let displayName = targetDevice.name.isEmpty ? item.name : targetDevice.name
                throw CleanerError.simulatorDeviceActive(deviceName: displayName, state: targetDevice.state)
            }

            let res = await shellRunner("/usr/bin/xcrun", ["simctl", "delete", udid])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete,
                status: .cleaned,
                message: "Deleted simulator \(targetDevice.name) (\(udid)) via simctl."
            )

        case .simctlDeleteUnavailable:
            let res = await shellRunner("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            let status: CleanupExecutionStatus = item.reclaimableSize > 0 ? .cleaned : .nothingEligible
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete,
                status: status,
                message: item.reclaimableSize > 0
                    ? "Removed unavailable simulators via simctl."
                    : "Nothing eligible for cleanup (0 unavailable simulator bytes)."
            )

        case .simctlDeleteRuntime(let identifier):
            let res = await shellRunner("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .simctlDelete,
                status: .cleaned,
                message: "Deleted simulator runtime \(identifier) via simctl."
            )

        case .avdManagerDelete(let avdName, let avdPath):
            guard AndroidCleaner.isValidAVDName(avdName) else {
                throw CleanerError.commandFailed("Invalid or unsafe Android AVD name: \(avdName)")
            }
            let expandedAVDPath = (avdPath as NSString).expandingTildeInPath
            if !expandedAVDPath.isEmpty {
                let avdURL = URL(fileURLWithPath: expandedAVDPath)
                if let pid = AndroidCleaner.activeLockPID(inAVDDirectory: avdURL) {
                    throw CleanerError.runningProcessActive(
                        appName: "Android emulator (PID \(pid))",
                        categoryName: item.category.rawValue
                    )
                }
            }
            guard let avdManagerBin = avdManagerResolver(), !avdManagerBin.isEmpty else {
                throw CleanerError.commandFailed(
                    "Cleanup blocked: Official 'avdmanager' tool was not found in the Android SDK. DevCleaner never deletes .avd directories manually."
                )
            }
            let res = await shellRunner(avdManagerBin, ["delete", "avd", "-n", avdName])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .avdManagerDelete,
                status: .cleaned,
                message: "Deleted Android AVD '\(avdName)' via official avdmanager."
            )

        case .dockerPrune(let subcommand):
            let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            guard let dockerBin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw CleanerError.commandFailed("Docker CLI not found.")
            }
            let res = await shellRunner(dockerBin, subcommand)
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .dockerPrune,
                status: .cleaned,
                message: "Executed docker \(subcommand.joined(separator: " "))."
            )
        }
    }
}
