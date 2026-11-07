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
    public let reversibleTrashHandler: @Sendable (URL) throws -> URL?
    public let shellRunner: @Sendable (String, [String]) async -> ShellResult
    public let avdManagerResolver: @Sendable () -> String?
    public let npmCapabilitiesProvider: @Sendable () async -> NpmCapabilities
    public let npmLiveUseChecker: @Sendable (String) async -> NpmLiveUseState

    public init(
        validator: SafetyValidator = SafetyValidator(),
        freeSpaceProvider: @escaping @Sendable () -> Int64 = { DiskScanner.shared.freeDiskSpaceBytes() },
        processChecker: @escaping @Sendable (CleanerCategory) async -> [String] = { category in
            let snapshot = await ProcessMonitor.shared.captureSnapshot()
            return snapshot.matchingProcesses(for: category)
        },
        trashHandler: (@Sendable (URL) throws -> Void)? = nil,
        reversibleTrashHandler: (@Sendable (URL) throws -> URL?)? = nil,
        shellRunner: @escaping @Sendable (String, [String]) async -> ShellResult = { executable, arguments in
            await ShellRunner.shared.run(executable, arguments: arguments)
        },
        avdManagerResolver: (@Sendable () -> String?)? = nil,
        npmCapabilitiesProvider: (@Sendable () async -> NpmCapabilities)? = nil,
        npmLiveUseChecker: (@Sendable (String) async -> NpmLiveUseState)? = nil
    ) {
        self.validator = validator
        self.freeSpaceProvider = freeSpaceProvider
        self.processChecker = processChecker
        if let reversibleTrashHandler {
            self.reversibleTrashHandler = reversibleTrashHandler
            self.trashHandler = trashHandler ?? { url in _ = try reversibleTrashHandler(url) }
        } else if let trashHandler {
            self.trashHandler = trashHandler
            self.reversibleTrashHandler = { url in
                try trashHandler(url)
                return nil
            }
        } else {
            let defaultReversible: @Sendable (URL) throws -> URL? = { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return resulting as URL?
            }
            self.reversibleTrashHandler = defaultReversible
            self.trashHandler = { url in _ = try defaultReversible(url) }
        }
        self.shellRunner = shellRunner
        self.avdManagerResolver = avdManagerResolver ?? {
            AndroidCleaner.resolveAVDManagerBinary(homeDirectory: validator.homeDirectory)
        }
        let homeDir = validator.homeDirectory
        self.npmCapabilitiesProvider = npmCapabilitiesProvider ?? {
            await NpmCacheInspector.discoverCapabilities(homeDirectory: homeDir, shellRunner: shellRunner)
        }
        self.npmLiveUseChecker = npmLiveUseChecker ?? { cacheRoot in
            let snapshot = await ProcessMonitor.shared.captureSnapshot()
            return await NpmCacheInspector.inspectLiveUse(
                cacheRoot: cacheRoot,
                snapshot: snapshot,
                shellRunner: shellRunner,
                includeSystemQueries: true
            )
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

        case .moveToTrashVerifiedWorktreeArtifact(let rawPath, let worktreeRoot, let sourceRepoRoot, let expectedModifiedAt):
            // 1. Only SAFE worktree artifacts can be deleted
            guard item.riskLevel == .safe else {
                throw CleanerError.readOnlyItem("Worktree artifact '\(item.name)' is classified as \(item.riskLevel.rawValue) and cannot be deleted automatically.")
            }

            let normalizedWorktreeRoot = try validator.expandAndNormalize(worktreeRoot)

            // 2. Verify worktree Git metadata immediately before touching anything
            let wtVerification = SafetyValidator.verifyWorktreeGitMetadata(at: normalizedWorktreeRoot)
            guard wtVerification.isVerified else {
                throw SafetyError.unverifiedWorktree(normalizedWorktreeRoot)
            }

            // 3. Refresh git status --porcelain immediately before destructive operation
            let statusBefore = await shellRunner("/usr/bin/git", ["-C", normalizedWorktreeRoot, "status", "--porcelain"])
            guard statusBefore.isSuccess else {
                throw CleanerError.commandFailed("Unable to verify git status before cleaning worktree artifact.")
            }
            let parsedBefore = GitWorktreeAnalyzer.parseGitStatusPorcelainBranch(statusBefore.stdout, isDetached: false)
            if parsedBefore.modifiedCount > 0 || parsedBefore.stagedCount > 0 {
                throw CleanerError.readOnlyItem("Worktree has uncommitted tracked changes; refusing to clean artifact.")
            }

            // 4. Rerun full SafetyValidator pre-deletion check (canonical path containment, path identity, symlink escape, .env/db/cert/release protection, mtime check)
            let validatedPath = try validator.validateVerifiedWorktreeArtifactForDeletion(
                rawPath,
                worktreeRoot: worktreeRoot,
                sourceRepoRoot: sourceRepoRoot,
                expectedModifiedAt: expectedModifiedAt,
                checkSymlinksOnDisk: true
            )
            let relativePath = String(validatedPath.dropFirst(normalizedWorktreeRoot.count + 1))

            // 5. Refresh tracked and Git-ignored state immediately before trashing
            let lsRes = await shellRunner("/usr/bin/git", ["-C", normalizedWorktreeRoot, "ls-files", "--", relativePath])
            let hasTracked = lsRes.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains { !$0.isEmpty && ($0 == relativePath || $0.hasPrefix(relativePath + "/")) }
            if !lsRes.isSuccess || hasTracked {
                throw SafetyError.forbiddenFileOrComponent(validatedPath)
            }

            let visibleUntrackedBefore = GitWorktreeAnalyzer.extractUntrackedPaths(fromPorcelainStatus: statusBefore.stdout).contains { rawUntracked in
                let cleaned = rawUntracked.hasSuffix("/") ? String(rawUntracked.dropLast()) : rawUntracked
                return cleaned == relativePath || cleaned.hasPrefix(relativePath + "/") || relativePath.hasPrefix(cleaned + "/")
            }
            let ignoreRes = await shellRunner("/usr/bin/git", ["-C", normalizedWorktreeRoot, "check-ignore", "-q", "--", relativePath])
            if ignoreRes.exitCode != 0 || visibleUntrackedBefore {
                throw CleanerError.readOnlyItem("Worktree artifact '\(relativePath)' is not confirmed Git-ignored (Git: untracked); refusing automatic deletion.")
            }

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
            let trashedURL = try reversibleTrashHandler(url)
            let movedBytes = beforeUsage.physicalSize > 0 ? beforeUsage.physicalSize : item.reclaimableSize

            // 6. Fail closed: compare git status after moving artifact to Trash
            let statusAfter = await shellRunner("/usr/bin/git", ["-C", normalizedWorktreeRoot, "status", "--porcelain"])
            let statusPreserved = statusAfter.isSuccess && (statusBefore.stdout == statusAfter.stdout)

            if !statusPreserved {
                let rollbackOutcome = GitWorktreeAnalyzer.attemptTrashRollback(
                    trashedURL: trashedURL,
                    originalPath: validatedPath
                )
                let failureMessage: String
                switch rollbackOutcome {
                case .restored:
                    failureMessage = "Cleanup failed & rolled back: Git status changed unexpectedly after trashing '\(relativePath)'. Artifact was automatically restored to '\(validatedPath)'."
                case .destinationAlreadyExists(let trashPath):
                    let loc = trashPath ?? "macOS Trash"
                    failureMessage = "CAUTION — Git status changed unexpectedly after trashing '\(relativePath)'. Rollback was aborted because '\(validatedPath)' already exists on disk (never overwritten). The artifact remains in Trash at \(loc)."
                case .failedToRestore(let trashPath, let errDesc):
                    let loc = trashPath ?? "macOS Trash"
                    failureMessage = "CAUTION — Git status changed unexpectedly after trashing '\(relativePath)' and automatic restoration failed (\(errDesc)). The artifact remains in Trash at \(loc)."
                }
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .moveToTrash,
                    status: .failed,
                    message: failureMessage
                )
            }

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
                message: "Moved verified Git-ignored worktree artifact to macOS Trash (\(Formatters.bytes(movedBytes))). Git status verified unchanged."
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

            // If Xcode developer directory was recorded at scan time, revalidate `xcode-select -p` immediately before execution
            if let expectedXcodeDir = item.simulatorMetadata?.xcodeDeveloperDir, !expectedXcodeDir.isEmpty {
                let xcodeRes = await shellRunner("/usr/bin/xcode-select", ["-p"])
                let currentXcodeDir = xcodeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !xcodeRes.isSuccess || currentXcodeDir != expectedXcodeDir {
                    throw CleanerError.commandFailed(
                        "Active Xcode selection changed since scan (expected '\(expectedXcodeDir)', found '\(currentXcodeDir)'). Re-scan before deleting simulator \(udid)."
                    )
                }
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

            // Revalidate exact UDID, runtime, availability, and QA/favorite protection against scan-time metadata
            if let meta = item.simulatorMetadata {
                if meta.isFavorite {
                    throw CleanerError.readOnlyItem("Simulator '\(item.name)' is marked as Favorite and protected from deletion.")
                }
                if !meta.runtimeIdentifier.isEmpty &&
                   !targetDevice.runtimeIdentifier.isEmpty &&
                   meta.runtimeIdentifier != targetDevice.runtimeIdentifier {
                    throw CleanerError.commandFailed(
                        "Simulator \(udid) runtime changed since scan (\(meta.runtimeIdentifier) -> \(targetDevice.runtimeIdentifier)). Re-scan before deleting."
                    )
                }
                if meta.isAvailable != targetDevice.isAvailable {
                    throw CleanerError.commandFailed(
                        "Simulator \(udid) availability changed since scan (isAvailable: \(meta.isAvailable) -> \(targetDevice.isAvailable)). Re-scan before deleting."
                    )
                }
                let liveIsQADevice = SimulatorMetadata.isQADeviceName(targetDevice.name)
                if liveIsQADevice && !meta.isNamedQADevice {
                    throw CleanerError.commandFailed(
                        "Simulator \(udid) was renamed to QA/protected device '\(targetDevice.name)' since scan. Re-scan before deleting."
                    )
                }
            }

            // Strictly require Shutdown state (blocks Booted, Creating, Shutting Down, Booting, etc.)
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
            throw CleanerError.readOnlyItem(
                "Blanket deletion of unavailable simulators ('simctl delete unavailable') is disabled for safety. Select individual unavailable simulator devices for review."
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

        case .npmCacheCommand(let rawCacheRoot, let subcommand):
            let validatedCacheRoot = try NpmCacheInspector.validateAndCanonicalizeCacheRoot(
                rawCacheRoot,
                homeDirectory: validator.homeDirectory
            )
            let liveUse = await npmLiveUseChecker(validatedCacheRoot)
            if liveUse.hasAnyGlobalOrNpxUse {
                throw CleanerError.runningProcessActive(
                    appName: liveUse.primaryProcessLabel(),
                    categoryName: item.category.rawValue
                )
            }
            let caps = await npmCapabilitiesProvider()
            guard let npmBin = caps.npmBinaryPath, !npmBin.isEmpty else {
                throw CleanerError.commandFailed("Cleanup blocked: official 'npm' CLI was not found.")
            }
            let cacacheDir = "\(validatedCacheRoot)/_cacache"
            let scopedValidator = SafetyValidator(
                homeDirectory: validator.homeDirectory,
                additionalAllowedPrefixes: [cacacheDir, "\(validatedCacheRoot)/_npx", "\(validatedCacheRoot)/_logs"]
            )
            if FileManager.default.fileExists(atPath: cacacheDir) {
                try scopedValidator.validateSubtreeForDeletion(cacacheDir)
            }
            let res = await shellRunner(npmBin, subcommand + ["--cache", validatedCacheRoot])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .npmCommand,
                status: .cleaned,
                message: "Executed npm \(subcommand.joined(separator: " ")) --cache \(validatedCacheRoot)."
            )

        case .npmNpxRemoveKeys(let rawCacheRoot, let keys):
            guard !keys.isEmpty else {
                return CleanupResult(
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    action: .npmCommand,
                    status: .nothingEligible,
                    message: "No eligible npx keys to remove."
                )
            }
            let validatedCacheRoot = try NpmCacheInspector.validateAndCanonicalizeCacheRoot(
                rawCacheRoot,
                homeDirectory: validator.homeDirectory
            )
            let caps = await npmCapabilitiesProvider()
            guard caps.supportsSelectiveNpxRemoval, let npmBin = caps.npmBinaryPath, !npmBin.isEmpty else {
                throw CleanerError.readOnlyItem("Installed npm does not support selective npx-cache removal.")
            }
            let liveUse = await npmLiveUseChecker(validatedCacheRoot)
            if !liveUse.isDeterminedSafely || !liveUse.activeGlobalNpmProcesses.isEmpty ||
               keys.contains(where: { liveUse.isNpxKeyActive($0) }) {
                throw CleanerError.runningProcessActive(
                    appName: liveUse.primaryProcessLabel(forKeys: keys),
                    categoryName: item.category.rawValue
                )
            }
            let npxRoot = "\(validatedCacheRoot)/_npx"
            let scopedValidator = SafetyValidator(
                homeDirectory: validator.homeDirectory,
                additionalAllowedPrefixes: ["\(validatedCacheRoot)/_cacache", npxRoot, "\(validatedCacheRoot)/_logs"]
            )
            for key in keys {
                guard !key.isEmpty && !key.contains("/") && key != "." && key != ".." else {
                    throw SafetyError.containsParentTraversal(key)
                }
                let keyPath = "\(npxRoot)/\(key)"
                if FileManager.default.fileExists(atPath: keyPath) {
                    _ = try scopedValidator.validateForDeletion(keyPath)
                    let expectedMod = item.plan?.entries.first(where: { $0.name == key })?.lastModified ?? item.lastModified
                    try scopedValidator.validateNotModifiedSinceScan(keyPath, expectedModifiedAt: expectedMod)
                    try scopedValidator.validateSubtreeForDeletion(keyPath)
                }
            }
            let res = await shellRunner(npmBin, ["cache", "npx", "rm"] + keys + ["--cache", validatedCacheRoot])
            if !res.isSuccess {
                throw CleanerError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
            }
            let freeAfter = freeSpaceProvider()
            let freedDelta = max(0, freeAfter - freeBefore)
            return CleanupResult(
                processedBytes: item.reclaimableSize,
                movedToTrashBytes: 0,
                actuallyFreedBytes: freedDelta,
                action: .npmCommand,
                status: .cleaned,
                message: "Removed inactive npx cache environment(s) (\(keys.joined(separator: ", "))) via npm cache npx rm."
            )
        }
    }

    /// Authoritative batch execution helper for AI Worktree artifact candidates, delegating every destructive step through `execute(_:)`.
    public func executeWorktreeCandidates(_ candidates: [WorktreeArtifactCandidate]) async -> WorktreeCleanupReport {
        var cleanedPaths: [String] = []
        var reclaimedBytes: Int64 = 0
        var skippedItems: [WorktreeCleanupSkippedItem] = []
        var rolledBackPaths: [String] = []
        var failedItems: [WorktreeCleanupSkippedItem] = []
        var gitStatusPreserved = true
        var gitStatusDetails: [String: String] = [:]

        for candidate in candidates {
            guard candidate.classification == .safe, candidate.gitTrackingState == .ignored else {
                skippedItems.append(
                    WorktreeCleanupSkippedItem(
                        path: candidate.fullPath,
                        artifactName: candidate.relativePath,
                        worktreeName: candidate.worktreeName,
                        classification: candidate.classification,
                        reason: candidate.classificationReason
                    )
                )
                continue
            }

            let wtPath = URL(fileURLWithPath: candidate.worktreePath).standardizedFileURL.path
            let artPath = URL(fileURLWithPath: candidate.fullPath).standardizedFileURL.path

            let itemToExecute = CleanableItem(
                id: candidate.cleanableItem.id,
                name: candidate.cleanableItem.name,
                category: .aiWorktreeArtifacts,
                path: artPath,
                logicalSize: candidate.logicalBytes,
                physicalSize: candidate.physicalBytes,
                reclaimableSize: candidate.reclaimableBytes > 0 ? candidate.reclaimableBytes : candidate.physicalBytes,
                lastModified: candidate.lastModified,
                riskLevel: candidate.classification,
                explanation: candidate.classificationReason,
                deletionConsequence: candidate.cleanableItem.deletionConsequence,
                regenerationImpact: candidate.cleanableItem.regenerationImpact,
                isRunningDependency: false,
                actionType: .moveToTrashVerifiedWorktreeArtifact(
                    path: artPath,
                    worktreeRoot: wtPath,
                    sourceRepoRoot: candidate.repositoryPath,
                    expectedModifiedAt: candidate.lastModified
                )
            )

            do {
                let result = try await execute(itemToExecute)
                switch result.status {
                case .cleaned:
                    cleanedPaths.append(artPath)
                    reclaimedBytes += result.movedToTrashBytes > 0 ? result.movedToTrashBytes : candidate.physicalBytes
                    if gitStatusDetails[wtPath] == nil {
                        gitStatusDetails[wtPath] = "Unchanged"
                    }
                case .failed, .blocked:
                    gitStatusPreserved = false
                    let msg = result.message ?? "Cleanup failed for '\(candidate.relativePath)'."
                    gitStatusDetails[wtPath] = msg
                    if msg.contains("rolled back") {
                        rolledBackPaths.append(artPath)
                    }
                    let failedEntry = WorktreeCleanupSkippedItem(
                        path: artPath,
                        artifactName: candidate.relativePath,
                        worktreeName: candidate.worktreeName,
                        classification: .caution,
                        reason: msg
                    )
                    failedItems.append(failedEntry)
                    skippedItems.append(failedEntry)
                case .nothingEligible, .skipped:
                    break
                }
            } catch {
                skippedItems.append(
                    WorktreeCleanupSkippedItem(
                        path: artPath,
                        artifactName: candidate.relativePath,
                        worktreeName: candidate.worktreeName,
                        classification: .review,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return WorktreeCleanupReport(
            cleanedPaths: cleanedPaths,
            reclaimedBytes: reclaimedBytes,
            skippedItems: skippedItems,
            rolledBackPaths: rolledBackPaths,
            failedItems: failedItems,
            gitStatusPreserved: gitStatusPreserved,
            gitStatusDetails: gitStatusDetails
        )
    }
}
