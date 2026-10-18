import Foundation

public struct AndroidCleaner: CleanerProvider {
    public let category: CleanerCategory = .android
    private let home: String
    private let executor: CleanupExecutor
    private let planner: CleanupPlanner

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executor: CleanupExecutor? = nil
    ) {
        self.home = homeDirectory
        let validator = SafetyValidator(homeDirectory: homeDirectory)
        self.executor = executor ?? CleanupExecutor(validator: validator)
        self.planner = CleanupPlanner(validator: validator)
    }

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let runningProcs = snapshot.matchingProcesses(for: .android)
        let isEmulatorRunning = !runningProcs.isEmpty

        // 1. Android SDK (Keep - NEVER DELETE automatically)
        let sdkPath = "\(home)/Library/Android/sdk"
        if FileManager.default.fileExists(atPath: sdkPath) {
            let usage = DiskScanner.shared.measurePath(sdkPath)
            items.append(
                CleanableItem(
                    id: "android-sdk-keep",
                    name: "Android SDK (Keep)",
                    category: .android,
                    path: sdkPath,
                    logicalSize: usage.logicalSize,
                    physicalSize: usage.physicalSize,
                    reclaimableSize: 0,
                    lastModified: usage.lastModified,
                    riskLevel: .neverDelete,
                    explanation: "Core Android SDK platforms, build-tools, NDK, and system images.",
                    deletionConsequence: "Preserved (Android SDK = keep). Manage individual SDK platforms inside Android Studio SDK Manager.",
                    regenerationImpact: "Would require re-downloading Android SDK components.",
                    isRunningDependency: isEmulatorRunning,
                    runningProcessNames: runningProcs,
                    actionType: .readOnlyInfo(reason: "Android SDK is preserved by design.")
                )
            )
        }

        // 2. Individual Android Virtual Devices (AVD) in ~/.android/avd
        let avdRoot = "\(home)/.android/avd"
        if FileManager.default.fileExists(atPath: avdRoot) {
            let avdURL = URL(fileURLWithPath: avdRoot, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: avdURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in contents where entry.pathExtension == "avd" {
                let avdName = entry.deletingPathExtension().lastPathComponent
                let usage = DiskScanner.shared.measurePath(entry.path)
                guard usage.physicalSize > 0 else { continue }

                let hasLock = FileManager.default.fileExists(atPath: entry.appendingPathComponent("hardware-qemu.ini.lock").path) ||
                              FileManager.default.fileExists(atPath: entry.appendingPathComponent("multiinstance.lock").path)
                let active = isEmulatorRunning || hasLock
                var activeNames = runningProcs
                if hasLock && !activeNames.contains("Android emulator (AVD Lock)") {
                    activeNames.append("Android emulator (AVD Lock)")
                }

                items.append(
                    CleanableItem(
                        id: "android-avd-\(avdName)",
                        name: "AVD Device: \(avdName)",
                        category: .android,
                        path: entry.path,
                        logicalSize: usage.logicalSize,
                        physicalSize: usage.physicalSize,
                        reclaimableSize: active ? 0 : usage.physicalSize,
                        lastModified: usage.lastModified,
                        riskLevel: .review,
                        explanation: "Android Virtual Device disk image, userdata, and snapshots (\(avdName).avd).",
                        deletionConsequence: "Moves \(avdName).avd to macOS Trash. Never allowed while emulator/qemu is running.",
                        regenerationImpact: "Requires recreating the virtual device in Android Studio Device Manager.",
                        isRunningDependency: active,
                        runningProcessNames: activeNames,
                        actionType: .moveToTrash(path: entry.path)
                    )
                )
            }
        }

        // 3. ~/.android/cache if present
        let androidCache = "\(home)/.android/cache"
        if FileManager.default.fileExists(atPath: androidCache) {
            let totalUsage = DiskScanner.shared.measurePath(androidCache, minAgeDays: nil)
            if totalUsage.physicalSize > 0 {
                let minDays = ageFilter != .all ? ageFilter.rawValue : nil
                let plan = planner.planDirectoryContents(
                    directoryPath: androidCache,
                    baseRisk: .safe,
                    ageFilter: ageFilter,
                    supportsAgeFilter: true,
                    isRunningDependency: false
                )
                items.append(
                    CleanableItem(
                        id: "android-dot-cache",
                        name: "Android Tooling Cache (~/.android/cache)",
                        category: .android,
                        path: androidCache,
                        logicalSize: totalUsage.logicalSize,
                        physicalSize: totalUsage.physicalSize,
                        reclaimableSize: plan.eligibleBytes,
                        lastModified: plan.latestModified ?? totalUsage.lastModified,
                        riskLevel: .safe,
                        explanation: "Temporary cache files inside ~/.android/cache.",
                        deletionConsequence: "Moves eligible cached files inside ~/.android/cache to macOS Trash.",
                        regenerationImpact: "Automatically regenerated by Android tools.",
                        isRunningDependency: isEmulatorRunning,
                        runningProcessNames: runningProcs,
                        actionType: .moveToTrashContents(directoryPath: androidCache, minAgeDays: minDays),
                        supportsAgeFilter: true,
                        plan: plan
                    )
                )
            }
        }

        return items
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
