import Foundation
import Darwin

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

        // 1. Android SDK & NDK / System Images / Emulator Breakdown (NEVER DELETE automatically)
        let sdkPath = "\(home)/Library/Android/sdk"
        if FileManager.default.fileExists(atPath: sdkPath) {
            var sdkExcluded = Set<String>()

            // 1a. Temporary SDK installer cache (~/Library/Android/sdk/.temp) -> SAFE if non-empty
            let sdkTempPath = "\(sdkPath)/.temp"
            if FileManager.default.fileExists(atPath: sdkTempPath) {
                sdkExcluded.insert(URL(fileURLWithPath: sdkTempPath).standardizedFileURL.path)
                let tempUsage = DiskScanner.shared.measurePath(sdkTempPath)
                if tempUsage.physicalSize > 0 {
                    let minDays = ageFilter != .all ? ageFilter.rawValue : nil
                    let plan = planner.planDirectoryContents(
                        directoryPath: sdkTempPath,
                        baseRisk: .safe,
                        ageFilter: ageFilter,
                        supportsAgeFilter: true,
                        isRunningDependency: false
                    )
                    items.append(
                        CleanableItem(
                            id: "android-sdk-temp",
                            name: "Android SDK Temporary Download Cache (sdk/.temp)",
                            category: .android,
                            path: sdkTempPath,
                            logicalSize: tempUsage.logicalSize,
                            physicalSize: tempUsage.physicalSize,
                            reclaimableSize: plan.eligibleBytes,
                            lastModified: plan.latestModified ?? tempUsage.lastModified,
                            riskLevel: .safe,
                            explanation: "Temporary staging/download files created by Android SDK Manager inside ~/Library/Android/sdk/.temp.",
                            deletionConsequence: "Moves temporary staging files in sdk/.temp to macOS Trash.",
                            regenerationImpact: "Recreated automatically during SDK updates.",
                            isRunningDependency: isEmulatorRunning,
                            runningProcessNames: runningProcs,
                            actionType: .moveToTrashContents(directoryPath: sdkTempPath, minAgeDays: minDays),
                            supportsAgeFilter: true,
                            plan: plan
                        )
                    )
                }
            }

            // 1b. System Images (~/Library/Android/sdk/system-images) -> REVIEW / manage through SDK Manager (never delete manually)
            let sysImagesPath = "\(sdkPath)/system-images"
            if FileManager.default.fileExists(atPath: sysImagesPath) {
                sdkExcluded.insert(URL(fileURLWithPath: sysImagesPath).standardizedFileURL.path)
                let sysUsage = DiskScanner.shared.measurePath(sysImagesPath)
                if sysUsage.physicalSize > 0 {
                    let versions = Self.listSubdirectoryNames(at: sysImagesPath)
                    let versionNote = versions.isEmpty ? "" : " Installed: \(versions.joined(separator: ", "))."
                    items.append(
                        CleanableItem(
                            id: "android-system-images-keep",
                            name: "Android System Images (\(versions.isEmpty ? "system-images" : versions.joined(separator: ", "))) — Manage via SDK Manager",
                            category: .android,
                            path: sysImagesPath,
                            logicalSize: sysUsage.logicalSize,
                            physicalSize: sysUsage.physicalSize,
                            reclaimableSize: 0,
                            lastModified: sysUsage.lastModified,
                            riskLevel: .review,
                            explanation: "Installed Android Emulator system images.\(versionNote) Manage through Android Studio SDK Manager (`sdkmanager`). Never deleted manually by DevCleaner.",
                            deletionConsequence: "Read-only / Review: Never deleted manually. Use Android Studio SDK Manager (`sdkmanager`) to remove unused system images.",
                            regenerationImpact: "Re-downloading a system image requires a 1.5–3 GB download.",
                            isRunningDependency: isEmulatorRunning,
                            runningProcessNames: runningProcs,
                            actionType: .readOnlyInfo(reason: "Android system images are managed via Android Studio SDK Manager (`sdkmanager`)."),
                            requiresRedownload: true
                        )
                    )
                }
            }

            // 1c. NDK Installations (~/Library/Android/sdk/ndk) -> NEVER DELETE automatically
            let ndkPath = "\(sdkPath)/ndk"
            if FileManager.default.fileExists(atPath: ndkPath) {
                sdkExcluded.insert(URL(fileURLWithPath: ndkPath).standardizedFileURL.path)
                let ndkUsage = DiskScanner.shared.measurePath(ndkPath)
                if ndkUsage.physicalSize > 0 {
                    let ndkVersions = Self.listSubdirectoryNames(at: ndkPath)
                    let vLabel = ndkVersions.isEmpty ? "NDK" : "NDK \(ndkVersions.joined(separator: ", "))"
                    items.append(
                        CleanableItem(
                            id: "android-ndk-keep",
                            name: "Android \(vLabel) (Keep)",
                            category: .android,
                            path: ndkPath,
                            logicalSize: ndkUsage.logicalSize,
                            physicalSize: ndkUsage.physicalSize,
                            reclaimableSize: 0,
                            lastModified: ndkUsage.lastModified,
                            riskLevel: .neverDelete,
                            explanation: "Installed Native Development Kit toolchains (\(vLabel)) used by React Native / C++ native builds.",
                            deletionConsequence: "Protected: Never deleted automatically. Manage NDK versions via Android Studio SDK Manager.",
                            regenerationImpact: "Removing NDK breaks native C++/JSI compilation until re-downloaded (~1.8 GB).",
                            isRunningDependency: isEmulatorRunning,
                            runningProcessNames: runningProcs,
                            actionType: .readOnlyInfo(reason: "Android NDK installations are preserved by design."),
                            requiresRedownload: true
                        )
                    )
                }
            }

            // 1d. Remaining Core Android SDK (emulator, build-tools, platforms, platform-tools) -> NEVER DELETE automatically
            let usage = DiskScanner.shared.measurePath(sdkPath, excludedSubpaths: sdkExcluded)
            let platforms = Self.listSubdirectoryNames(at: "\(sdkPath)/platforms")
            let buildTools = Self.listSubdirectoryNames(at: "\(sdkPath)/build-tools")
            var details: [String] = []
            if !platforms.isEmpty { details.append("Platforms: \(platforms.joined(separator: ", "))") }
            if !buildTools.isEmpty { details.append("Build-Tools: \(buildTools.joined(separator: ", "))") }
            let detailSuffix = details.isEmpty ? "" : " (\(details.joined(separator: " • ")))"

            items.append(
                CleanableItem(
                    id: "android-sdk-keep",
                    name: "Android SDK Core, Platforms & Emulator (Keep)",
                    category: .android,
                    path: sdkPath,
                    logicalSize: usage.logicalSize,
                    physicalSize: usage.physicalSize,
                    reclaimableSize: 0,
                    lastModified: usage.lastModified,
                    riskLevel: .neverDelete,
                    explanation: "Core Android SDK platforms, build-tools, platform-tools, and emulator binaries\(detailSuffix).",
                    deletionConsequence: "Preserved (Android SDK = keep). Manage individual SDK components inside Android Studio SDK Manager.",
                    regenerationImpact: "Would require re-downloading Android SDK components.",
                    isRunningDependency: isEmulatorRunning,
                    runningProcessNames: runningProcs,
                    actionType: .readOnlyInfo(reason: "Android SDK is preserved by design."),
                    requiresRedownload: true
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

                let avdMeta = Self.parseAVDConfig(at: entry)
                let liveLockPID = Self.activeLockPID(inAVDDirectory: entry)
                let hasLiveLock = liveLockPID != nil
                let active = isEmulatorRunning || hasLiveLock
                var activeNames = runningProcs
                if let pid = liveLockPID, !activeNames.contains(where: { $0.contains("AVD Lock") }) {
                    activeNames.append("Android emulator (PID \(pid))")
                }

                let metaSummary = [avdMeta.displayName, avdMeta.androidVersionLabel, avdMeta.abi]
                    .compactMap { $0 }
                    .joined(separator: " • ")
                let metaPrefix = metaSummary.isEmpty ? "" : "[\(metaSummary)] "

                let avdAction: CleanupActionType = Self.isValidAVDName(avdName)
                    ? .avdManagerDelete(avdName: avdName, avdPath: entry.path)
                    : .readOnlyInfo(reason: "AVD name contains invalid characters for official avdmanager CLI deletion.")

                items.append(
                    CleanableItem(
                        id: "android-avd-\(avdName)",
                        name: "AVD Device: \(avdName)",
                        category: .android,
                        path: entry.path,
                        logicalSize: usage.logicalSize,
                        physicalSize: usage.physicalSize,
                        reclaimableSize: active || !Self.isValidAVDName(avdName) ? 0 : usage.physicalSize,
                        lastModified: usage.lastModified,
                        riskLevel: .review,
                        explanation: "\(metaPrefix)Android Virtual Device disk image, userdata, and snapshots (\(avdName).avd). Review before deleting via `avdmanager delete avd -n \(avdName)`.",
                        deletionConsequence: "Deletes this AVD and its .ini metadata via official 'avdmanager delete avd -n \(avdName)'. Never deletes .avd folders manually; blocked while emulator/qemu is running.",
                        regenerationImpact: "Requires recreating the virtual device in Android Studio Device Manager and re-installing test apps.",
                        isRunningDependency: active,
                        runningProcessNames: activeNames,
                        actionType: avdAction
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

    public static func isValidAVDName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, trimmed.count <= 128 else {
            return false
        }
        guard !name.contains(".."), !name.contains("/"), !name.contains("\\"), !name.hasPrefix("-") else {
            return false
        }
        return name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    public static func resolveAVDManagerBinary(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        customCandidates: [String]? = nil
    ) -> String? {
        let fm = FileManager.default
        if let customCandidates {
            return customCandidates.first { candidate in
                !candidate.contains("..") && fm.isExecutableFile(atPath: candidate)
            }
        }

        let sdkPath = "\(homeDirectory)/Library/Android/sdk"
        var candidates: [String] = [
            "\(sdkPath)/cmdline-tools/latest/bin/avdmanager"
        ]

        let cmdlineToolsRoot = "\(sdkPath)/cmdline-tools"
        if let toolVersions = try? fm.contentsOfDirectory(atPath: cmdlineToolsRoot) {
            for version in toolVersions.sorted().reversed() where version != "latest" && !version.hasPrefix(".") {
                candidates.append("\(cmdlineToolsRoot)/\(version)/bin/avdmanager")
            }
        }

        candidates.append(contentsOf: [
            "\(sdkPath)/tools/bin/avdmanager",
            "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/avdmanager",
            "/usr/local/share/android-commandlinetools/cmdline-tools/latest/bin/avdmanager",
            "/opt/homebrew/bin/avdmanager",
            "/usr/local/bin/avdmanager"
        ])

        return candidates.first { candidate in
            !candidate.contains("..") && fm.isExecutableFile(atPath: candidate)
        }
    }

    public static func activeLockPID(inAVDDirectory avdURL: URL) -> Int32? {
        for lockName in ["hardware-qemu.ini.lock", "multiinstance.lock"] {
            let lockURL = avdURL.appendingPathComponent(lockName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDir) else { continue }
            let pidFileURL = isDir.boolValue ? lockURL.appendingPathComponent("pid") : lockURL
            if let content = try? String(contentsOf: pidFileURL, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed), pid > 0 {
                    // Check if process is actually alive
                    if kill(pid, 0) == 0 {
                        return pid
                    }
                }
            }
        }
        return nil
    }

    public static func parseAVDConfig(at avdURL: URL) -> (displayName: String?, androidVersionLabel: String?, abi: String?) {
        let configURL = avdURL.appendingPathComponent("config.ini")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return (nil, nil, nil)
        }
        var displayName: String?
        var androidVersionLabel: String?
        var abi: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let parts = rawLine.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1]
            if key == "avd.ini.displayname" && !val.isEmpty {
                displayName = val
            } else if key == "abi.type" && !val.isEmpty {
                abi = val
            } else if key.hasPrefix("image.sysdir") {
                // e.g. system-images/android-36.1/google_apis_playstore/arm64-v8a/
                let comps = val.split(separator: "/").map(String.init)
                if let apiComp = comps.first(where: { $0.hasPrefix("android-") }) {
                    let apiNum = String(apiComp.dropFirst("android-".count))
                    androidVersionLabel = "API \(apiNum)"
                }
            }
        }
        return (displayName, androidVersionLabel, abi)
    }

    private static func listSubdirectoryNames(at path: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? url.lastPathComponent : nil
        }.sorted()
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
