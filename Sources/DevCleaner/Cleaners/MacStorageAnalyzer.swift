import Foundation

public struct MacStorageAnalyzer: Sendable {
    private let home: String
    private let planner: CleanupPlanner
    private let validator: SafetyValidator

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = homeDirectory
        let v = SafetyValidator(homeDirectory: homeDirectory)
        self.validator = v
        self.planner = CleanupPlanner(validator: v)
    }

    private struct AppSupportSpec {
        let idPrefix: String
        let appDisplayName: String
        let dirName: String
        let processNames: [String]
        let commandTokens: [String]
        let safeCacheSubdirs: [String]
        let protectedExplanation: String
        let macCategoryForCaches: MacStorageCategory
    }

    private var appSupportSpecs: [AppSupportSpec] {
        [
            AppSupportSpec(
                idPrefix: "vscode",
                appDisplayName: "VS Code",
                dirName: "Code",
                processNames: ["Visual Studio Code", "Code"],
                commandTokens: ["Visual Studio Code.app", "/Code.app/"],
                safeCacheSubdirs: [
                    "Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                    "GraphiteDawnCache", "GPUPersistentCache", "ShaderCache",
                    "CachedData", "CachedExtensionVSIXs", "logs", "Crashpad"
                ],
                protectedExplanation: "VS Code User settings, keybindings, snippets, globalStorage, workspaceStorage, and WebStorage.",
                macCategoryForCaches: .applicationCaches
            ),
            AppSupportSpec(
                idPrefix: "antigravity",
                appDisplayName: "Google Antigravity",
                dirName: "Antigravity",
                processNames: ["Antigravity"],
                commandTokens: ["Antigravity.app"],
                safeCacheSubdirs: [
                    "Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                    "GraphiteDawnCache", "GPUPersistentCache", "ShaderCache",
                    "CachedData", "CachedExtensionVSIXs", "logs", "Crashpad"
                ],
                protectedExplanation: "Antigravity User settings, workspace state, Partitions, and extensions state.",
                macCategoryForCaches: .aiTools
            ),
            AppSupportSpec(
                idPrefix: "cursor",
                appDisplayName: "Cursor IDE",
                dirName: "Cursor",
                processNames: ["Cursor"],
                commandTokens: ["/Cursor.app/"],
                safeCacheSubdirs: [
                    "Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                    "GraphiteDawnCache", "GPUPersistentCache", "ShaderCache",
                    "CachedData", "CachedExtensionVSIXs", "logs", "Crashpad"
                ],
                protectedExplanation: "Cursor User configuration, workspaceStorage, globalStorage, and AI editor state.",
                macCategoryForCaches: .applicationCaches
            ),
            AppSupportSpec(
                idPrefix: "notion",
                appDisplayName: "Notion",
                dirName: "Notion",
                processNames: ["Notion"],
                commandTokens: ["Notion.app"],
                safeCacheSubdirs: [
                    "Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                    "GraphiteDawnCache", "GPUPersistentCache", "ShaderCache",
                    "logs", "Crashpad"
                ],
                protectedExplanation: "Notion local SQLite databases (notion.db), Partitions, offline workspace pages, and login state.",
                macCategoryForCaches: .applicationCaches
            )
        ]
    }

    public func scanAdditionalMacStorageItems(
        snapshot: ActiveProcessSnapshot,
        ageFilter: AgeFilter,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []
        let appSupportRoot = "\(home)/Library/Application Support"
        let minDays = ageFilter != .all ? ageFilter.rawValue : nil

        // 1. Inspect Code, Antigravity, Cursor, Notion in ~/Library/Application Support
        for spec in appSupportSpecs {
            if shouldCancel() { return items }
            let appDir = "\(appSupportRoot)/\(spec.dirName)"
            guard FileManager.default.fileExists(atPath: appDir) else { continue }

            let activeProcs = snapshot.matchingProcesses(forAppNames: spec.processNames, commandTokens: spec.commandTokens)
            let isRunning = !activeProcs.isEmpty
            var excludedSubpaths = Set<String>()

            for sub in spec.safeCacheSubdirs {
                let subPath = "\(appDir)/\(sub)"
                guard FileManager.default.fileExists(atPath: subPath) else { continue }
                excludedSubpaths.insert(URL(fileURLWithPath: subPath).standardizedFileURL.path)

                let usage = DiskScanner.shared.measurePath(subPath)
                guard usage.physicalSize > 0 else { continue }

                let plan = planner.planDirectoryContents(
                    directoryPath: subPath,
                    baseRisk: .safe,
                    ageFilter: ageFilter,
                    supportsAgeFilter: true,
                    isRunningDependency: false
                )

                let slug = sub.lowercased().replacingOccurrences(of: " ", with: "-")
                items.append(
                    CleanableItem(
                        id: "appsupport-\(spec.idPrefix)-\(slug)",
                        name: "\(spec.appDisplayName) \(sub) (Application Support/\(spec.dirName)/\(sub))",
                        category: .generalCaches,
                        path: subPath,
                        logicalSize: usage.logicalSize,
                        physicalSize: usage.physicalSize,
                        reclaimableSize: isRunning ? 0 : plan.eligibleBytes,
                        lastModified: plan.latestModified ?? usage.lastModified,
                        riskLevel: .safe,
                        explanation: "Verified regenerable \(sub) folder inside ~/Library/Application Support/\(spec.dirName)/\(sub). User configuration, workspaces, and databases are preserved.",
                        deletionConsequence: "Moves eligible cache files in \(spec.dirName)/\(sub) to macOS Trash. Blocked while \(spec.appDisplayName) is running.",
                        regenerationImpact: "Automatically regenerated by \(spec.appDisplayName).",
                        isRunningDependency: isRunning,
                        runningProcessNames: activeProcs,
                        actionType: .moveToTrashContents(directoryPath: subPath, minAgeDays: minDays),
                        supportsAgeFilter: true,
                        plan: plan,
                        requiresRedownload: false,
                        affectsSessionsOrConfig: false
                    )
                )
            }

            let protectedUsage = DiskScanner.shared.measurePath(appDir, excludedSubpaths: excludedSubpaths)
            if protectedUsage.physicalSize > 0 {
                items.append(
                    CleanableItem(
                        id: "appsupport-\(spec.idPrefix)-protected",
                        name: "\(spec.appDisplayName) Workspace, Databases & Settings (Protected)",
                        category: .generalCaches,
                        path: appDir,
                        logicalSize: protectedUsage.logicalSize,
                        physicalSize: protectedUsage.physicalSize,
                        reclaimableSize: 0,
                        lastModified: protectedUsage.lastModified,
                        riskLevel: .neverDelete,
                        explanation: spec.protectedExplanation,
                        deletionConsequence: "Protected: Never deleted automatically.",
                        regenerationImpact: "Preserves your \(spec.appDisplayName) configuration, extensions, databases, and active sessions.",
                        isRunningDependency: isRunning,
                        runningProcessNames: activeProcs,
                        actionType: .readOnlyInfo(reason: "\(spec.appDisplayName) application data and settings are strictly protected."),
                        requiresRedownload: false,
                        affectsSessionsOrConfig: true
                    )
                )
            }
        }

        // 2. Inspect ~/Library/Application Support/Google (GoogleUpdater/crx_cache is SAFE; Chrome & DriveFS are PROTECTED)
        let googleAppSupport = "\(appSupportRoot)/Google"
        if !shouldCancel(), FileManager.default.fileExists(atPath: googleAppSupport) {
            var googleExcluded = Set<String>()
            let crxCachePath = "\(googleAppSupport)/GoogleUpdater/crx_cache"
            if FileManager.default.fileExists(atPath: crxCachePath) {
                googleExcluded.insert(URL(fileURLWithPath: crxCachePath).standardizedFileURL.path)
                let crxUsage = DiskScanner.shared.measurePath(crxCachePath)
                if crxUsage.physicalSize > 0 {
                    let plan = planner.planDirectoryContents(
                        directoryPath: crxCachePath,
                        baseRisk: .safe,
                        ageFilter: ageFilter,
                        supportsAgeFilter: true,
                        isRunningDependency: false
                    )
                    items.append(
                        CleanableItem(
                            id: "appsupport-google-crx-cache",
                            name: "Google Updater CRX Package Cache (GoogleUpdater/crx_cache)",
                            category: .generalCaches,
                            path: crxCachePath,
                            logicalSize: crxUsage.logicalSize,
                            physicalSize: crxUsage.physicalSize,
                            reclaimableSize: plan.eligibleBytes,
                            lastModified: plan.latestModified ?? crxUsage.lastModified,
                            riskLevel: .safe,
                            explanation: "Cached component update packages in ~/Library/Application Support/Google/GoogleUpdater/crx_cache.",
                            deletionConsequence: "Moves cached GoogleUpdater CRX archives to macOS Trash. Never touches Chrome profiles or DriveFS.",
                            regenerationImpact: "Automatically re-downloaded by GoogleUpdater if needed.",
                            isRunningDependency: false,
                            runningProcessNames: [],
                            actionType: .moveToTrashContents(directoryPath: crxCachePath, minAgeDays: minDays),
                            supportsAgeFilter: true,
                            plan: plan,
                            requiresRedownload: false,
                            affectsSessionsOrConfig: false
                        )
                    )
                }
            }

            let googleProtectedUsage = DiskScanner.shared.measurePath(googleAppSupport, excludedSubpaths: googleExcluded)
            if googleProtectedUsage.physicalSize > 0 {
                items.append(
                    CleanableItem(
                        id: "appsupport-google-protected",
                        name: "Google Chrome Profiles & DriveFS Data (Protected)",
                        category: .generalCaches,
                        path: googleAppSupport,
                        logicalSize: googleProtectedUsage.logicalSize,
                        physicalSize: googleProtectedUsage.physicalSize,
                        reclaimableSize: 0,
                        lastModified: googleProtectedUsage.lastModified,
                        riskLevel: .neverDelete,
                        explanation: "Google Chrome user profiles, DriveFS state, and application settings in ~/Library/Application Support/Google.",
                        deletionConsequence: "Protected: Never deleted.",
                        regenerationImpact: "Contains user browser profiles and Google Drive state.",
                        isRunningDependency: false,
                        runningProcessNames: [],
                        actionType: .readOnlyInfo(reason: "Google Chrome and DriveFS data are strictly protected."),
                        requiresRedownload: false,
                        affectsSessionsOrConfig: true
                    )
                )
            }
        }

        // 3. Inspect ~/Library/Application Support/OutSystems (PROTECTED)
        let outsystemsPath = "\(appSupportRoot)/OutSystems"
        if !shouldCancel(), FileManager.default.fileExists(atPath: outsystemsPath) {
            let osUsage = DiskScanner.shared.measurePath(outsystemsPath)
            if osUsage.physicalSize > 0 {
                items.append(
                    CleanableItem(
                        id: "appsupport-outsystems-protected",
                        name: "OutSystems ServiceStudio & ODC Studio Data (Protected)",
                        category: .generalCaches,
                        path: outsystemsPath,
                        logicalSize: osUsage.logicalSize,
                        physicalSize: osUsage.physicalSize,
                        reclaimableSize: 0,
                        lastModified: osUsage.lastModified,
                        riskLevel: .neverDelete,
                        explanation: "OutSystems ServiceStudio 11 and ODC Studio local ReferenceCache, Templates, Keys, and Settings in ~/Library/Application Support/OutSystems.",
                        deletionConsequence: "Protected: Never deleted automatically.",
                        regenerationImpact: "Preserves OutSystems IDE keys, settings, and module reference data.",
                        isRunningDependency: false,
                        runningProcessNames: [],
                        actionType: .readOnlyInfo(reason: "OutSystems IDE state and keys are protected."),
                        requiresRedownload: false,
                        affectsSessionsOrConfig: true
                    )
                )
            }
        }

        // 4. Inspect ~/Library/Logs/{Antigravity,GitHubCopilot} (SAFE)
        for logSpec in [
            (id: "logs-antigravity", name: "Antigravity Diagnostic Logs (~/Library/Logs/Antigravity)", sub: "Library/Logs/Antigravity", procs: ["Antigravity"]),
            (id: "logs-github-copilot", name: "GitHub Copilot Diagnostic Logs (~/Library/Logs/GitHubCopilot)", sub: "Library/Logs/GitHubCopilot", procs: ["Xcode", "Visual Studio Code"])
        ] {
            let logPath = "\(home)/\(logSpec.sub)"
            guard FileManager.default.fileExists(atPath: logPath) else { continue }
            let usage = DiskScanner.shared.measurePath(logPath)
            guard usage.physicalSize > 0 else { continue }
            let activeProcs = snapshot.matchingProcesses(forAppNames: logSpec.procs)
            let isRunning = !activeProcs.isEmpty
            let plan = planner.planDirectoryContents(
                directoryPath: logPath,
                baseRisk: .safe,
                ageFilter: ageFilter,
                supportsAgeFilter: true,
                isRunningDependency: false
            )
            items.append(
                CleanableItem(
                    id: logSpec.id,
                    name: logSpec.name,
                    category: .generalCaches,
                    path: logPath,
                    logicalSize: usage.logicalSize,
                    physicalSize: usage.physicalSize,
                    reclaimableSize: isRunning ? 0 : plan.eligibleBytes,
                    lastModified: plan.latestModified ?? usage.lastModified,
                    riskLevel: .safe,
                    explanation: "Diagnostic log files inside ~/\(logSpec.sub).",
                    deletionConsequence: "Moves eligible log files to macOS Trash.",
                    regenerationImpact: "Recreated automatically when logging events.",
                    isRunningDependency: isRunning,
                    runningProcessNames: activeProcs,
                    actionType: .moveToTrashContents(directoryPath: logPath, minAgeDays: minDays),
                    supportsAgeFilter: true,
                    plan: plan
                )
            )
        }

        return items
    }

    /// Deduplicates items by ID and ensures no child directory is double-counted inside a non-excluding parent directory.
    public static func deduplicateItems(_ items: [CleanableItem]) -> [CleanableItem] {
        var seenIDs = Set<String>()
        var uniqueByID: [CleanableItem] = []
        for item in items {
            guard !seenIDs.contains(item.id) else { continue }
            seenIDs.insert(item.id)
            uniqueByID.append(item)
        }

        // Track cleanable (non-readOnlyInfo) directory paths so identical paths are never counted twice
        var seenCleanablePaths = Set<String>()
        var result: [CleanableItem] = []
        for item in uniqueByID {
            let stdPath = URL(fileURLWithPath: (item.path as NSString).expandingTildeInPath).standardizedFileURL.path
            let isReadOnlyRemainder: Bool = {
                if case .readOnlyInfo = item.actionType { return true }
                if case .dockerPrune = item.actionType { return true }
                if case .simctlDeleteUnavailable = item.actionType { return true }
                return false
            }()

            if !isReadOnlyRemainder && !stdPath.isEmpty {
                if seenCleanablePaths.contains(stdPath) {
                    continue
                }
                seenCleanablePaths.insert(stdPath)
            }
            result.append(item)
        }
        return result
    }

    public static func macCategory(for item: CleanableItem) -> MacStorageCategory {
        if item.id.hasPrefix("appsupport-antigravity-") || item.id == "logs-antigravity" || item.id == "logs-github-copilot" {
            return item.riskLevel == .neverDelete ? .other : .aiTools
        }
        if item.id.hasPrefix("appsupport-") {
            return item.riskLevel == .neverDelete ? .other : .applicationCaches
        }
        switch item.category {
        case .claude, .codex, .googleAI:
            return .aiTools
        case .xcode, .iosSimulators:
            return .xcodeAndSimulators
        case .android:
            return .android
        case .docker:
            return .docker
        case .nodeNpm, .gradle, .cocoapodsSwiftPM, .homebrew:
            return .packageManagers
        case .generalCaches:
            switch item.id {
            case "openai-atlas-cache", "openai-chat-cache", "gemini-macos-cache", "antigravity-cache", "antigravity-updater-cache":
                return .aiTools
            case "pip-cache":
                return .packageManagers
            case "puppeteer-cache", "playwright-cache", "playwright-go-cache", "firebase-emulators-cache", "firebase-non-emulator-protected", "dotslash-cache", "react-native-cache":
                return .developerTools
            default:
                return .applicationCaches
            }
        case .projectStorage:
            return .developerTools
        }
    }

    public func buildSummary(
        providerItems: [CleanableItem],
        additionalItems: [CleanableItem],
        projectSummary: ProjectStorageSummary,
        projectsRootPath: String
    ) -> MacStorageSummary {
        // Filter out per-artifact .projectStorage items (since projectSummary represents ~/Developer without double counting)
        // and filter out system-mounted /Library/Developer/CoreSimulator/Volumes (`sim-runtimes-preserved`) and virtual `xcode-coredevice-virtual-fs` from physical storage sums
        let nonProjectProviderItems = providerItems.filter { $0.category != .projectStorage }
        let deduplicated = Self.deduplicateItems(nonProjectProviderItems + additionalItems)

        // Exclude system-mounted volumes (/Library/...) & 0-byte virtual mounts from user Mac Storage physical accounting
        let countableItems = deduplicated.filter { item in
            item.id != "sim-runtimes-preserved" && item.id != "xcode-coredevice-virtual-fs"
        }

        // Create a read-only summary row for ~/Developer projects inside Developer Tools category
        let projectsOverviewItem = CleanableItem(
            id: "mac-storage-developer-projects-overview",
            name: "Developer Projects (\(projectsRootPath)) — \(projectSummary.totalProjectsCount) projects",
            category: .projectStorage,
            path: projectsRootPath,
            logicalSize: projectSummary.totalProjectsPhysicalBytes,
            physicalSize: projectSummary.totalProjectsPhysicalBytes,
            reclaimableSize: projectSummary.potentialRecoveryBytes,
            lastModified: nil,
            riskLevel: .neverDelete,
            explanation: "Aggregated ~/Developer footprint (\(projectSummary.totalProjectsCount) projects): SAFE regenerable caches/builds \(Formatters.bytes(projectSummary.regenerableCachesAndBuildsBytes)) • REVIEW dependencies \(Formatters.bytes(projectSummary.reviewRequiredBytes)) • Worktrees \(Formatters.bytes(projectSummary.worktreesBytes)) • Protected source/git \(Formatters.bytes(projectSummary.protectedDataBytes)). Manage individual projects in the Project Storage tab.",
            deletionConsequence: "Read-only summary in Mac Storage tab. Select individual project artifacts in the Project Storage tab.",
            regenerationImpact: "Source code, .git repositories, and worktrees are strictly protected.",
            isRunningDependency: false,
            runningProcessNames: [],
            actionType: .readOnlyInfo(reason: "Use the Project Storage tab to inspect and clean individual project build caches.")
        )

        var groupedDict: [MacStorageCategory: [CleanableItem]] = [:]
        for cat in MacStorageCategory.allCases {
            groupedDict[cat] = []
        }
        for item in countableItems {
            let cat = Self.macCategory(for: item)
            groupedDict[cat, default: []].append(item)
        }
        if projectSummary.totalProjectsPhysicalBytes > 0 {
            groupedDict[.developerTools, default: []].insert(projectsOverviewItem, at: 0)
        }

        let groups: [MacStorageCategoryGroup] = MacStorageCategory.allCases.compactMap { cat in
            let list = (groupedDict[cat] ?? []).sorted { a, b in
                if a.id == "mac-storage-developer-projects-overview" { return true }
                if b.id == "mac-storage-developer-projects-overview" { return false }
                if a.riskLevel != b.riskLevel { return a.riskLevel < b.riskLevel }
                return a.physicalSize > b.physicalSize
            }
            guard !list.isEmpty else { return nil }

            if cat == .developerTools && projectSummary.totalProjectsPhysicalBytes > 0 {
                let nonOverview = list.filter { $0.id != "mac-storage-developer-projects-overview" }
                let phys = nonOverview.reduce(Int64(0)) { $0 + $1.physicalSize } + projectSummary.totalProjectsPhysicalBytes
                let safe = nonOverview.filter { $0.riskLevel == .safe }.reduce(Int64(0)) { $0 + $1.reclaimableSize } + projectSummary.regenerableCachesAndBuildsBytes
                let review = nonOverview.filter { $0.riskLevel == .review }.reduce(Int64(0)) { $0 + $1.reclaimableSize } + projectSummary.reviewRequiredBytes
                let caution = nonOverview.filter { $0.riskLevel == .caution }.reduce(Int64(0)) { $0 + $1.reclaimableSize }
                let prot = max(0, phys - (safe + review + caution))
                return MacStorageCategoryGroup(
                    category: cat,
                    items: list,
                    totalPhysicalBytes: phys,
                    safeReclaimableBytes: safe,
                    reviewReclaimableBytes: review,
                    cautionReclaimableBytes: caution,
                    protectedBytes: prot
                )
            } else {
                return MacStorageCategoryGroup(category: cat, items: list)
            }
        }

        let totalDevBytes = groups.reduce(Int64(0)) { $0 + $1.totalPhysicalBytes }
        let safeBytes = groups.reduce(Int64(0)) { $0 + $1.safeReclaimableBytes }
        let reviewBytes = groups.reduce(Int64(0)) { $0 + $1.reviewReclaimableBytes }
        let cautionBytes = groups.reduce(Int64(0)) { $0 + $1.cautionReclaimableBytes }
        let protectedBytes = max(0, totalDevBytes - (safeBytes + reviewBytes + cautionBytes))

        // Compute mutually exclusive Section 12 domain breakdown (sums to totalDevBytes without double counting)
        let devProjectsBytes = projectSummary.totalProjectsPhysicalBytes
        let aiToolsBytes = countableItems.filter { Self.macCategory(for: $0) == .aiTools }.reduce(Int64(0)) { $0 + $1.physicalSize }
        let simulatorsBytes = countableItems.filter {
            $0.category == .iosSimulators || $0.id.hasPrefix("android-avd-")
        }.reduce(Int64(0)) { $0 + $1.physicalSize }
        let dockerBytes = countableItems.filter { $0.category == .docker }.reduce(Int64(0)) { $0 + $1.physicalSize }
        let androidSDKBytes = countableItems.filter {
            $0.category == .android && !$0.id.hasPrefix("android-avd-")
        }.reduce(Int64(0)) { $0 + $1.physicalSize }
        let cachesBytes = countableItems.filter { item in
            let cat = Self.macCategory(for: item)
            return cat == .packageManagers || cat == .applicationCaches ||
                (cat == .developerTools && item.id != "mac-storage-developer-projects-overview") ||
                (item.category == .xcode && item.riskLevel == .safe)
        }.reduce(Int64(0)) { $0 + $1.physicalSize }

        let accountedDomains = devProjectsBytes + aiToolsBytes + simulatorsBytes + dockerBytes + androidSDKBytes + cachesBytes
        let otherDevDataBytes = max(0, totalDevBytes - accountedDomains)

        let roots = buildInspectedRoots(
            countableItems: countableItems,
            projectSummary: projectSummary,
            projectsRootPath: projectsRootPath
        )

        return MacStorageSummary(
            totalDeveloperStorageBytes: totalDevBytes,
            safeCleanupBytes: safeBytes,
            reviewCleanupBytes: reviewBytes,
            cautionCleanupBytes: cautionBytes,
            protectedBytes: protectedBytes,
            developerProjectsBytes: devProjectsBytes,
            aiToolsBytes: aiToolsBytes,
            simulatorsBytes: simulatorsBytes,
            dockerBytes: dockerBytes,
            androidSDKBytes: androidSDKBytes,
            cachesBytes: cachesBytes,
            otherDeveloperDataBytes: otherDevDataBytes,
            categoryGroups: groups,
            inspectedRoots: roots
        )
    }

    private func buildInspectedRoots(
        countableItems: [CleanableItem],
        projectSummary: ProjectStorageSummary,
        projectsRootPath: String
    ) -> [MacStorageRootInfo] {
        let specs: [(id: String, display: String, fullPath: String, note: String)] = [
            ("root-library-caches", "~/Library/Caches", "\(home)/Library/Caches", "Explicit per-tool rules only (never rm -rf ~/Library/Caches/*)"),
            ("root-app-support", "~/Library/Application Support", "\(home)/Library/Application Support", "Only verified subcaches are SAFE; sessions, databases & configs are PROTECTED"),
            ("root-library-developer", "~/Library/Developer", "\(home)/Library/Developer", "Xcode DerivedData, DocumentationCache, Archives & CoreSimulator devices"),
            ("root-library-containers", "~/Library/Containers", "\(home)/Library/Containers", "Docker Desktop VM container (never deleted directly; uses official Docker CLI)"),
            ("root-library-logs", "~/Library/Logs", "\(home)/Library/Logs", "Diagnostic logs for Xcode, CoreSimulator, Claude, Codex, Antigravity & Copilot"),
            ("root-dot-cache", "~/.cache", "\(home)/.cache", "Codex runtimes, Puppeteer browsers, Firebase emulators, Node Corepack & pkg"),
            ("root-dot-npm", "~/.npm", "\(home)/.npm", "npm _cacache, _npx temporary packages & debug logs"),
            ("root-dot-gradle", "~/.gradle", "\(home)/.gradle", "Gradle build caches & daemon logs"),
            ("root-dot-android", "~/.android", "\(home)/.android", "Android Virtual Devices (AVD) & ~/.android/cache"),
            ("root-android-sdk", "~/Library/Android/sdk", "\(home)/Library/Android/sdk", "Android SDK platforms, NDK, system-images & sdk/.temp"),
            ("root-developer-projects", "~/Developer", projectsRootPath, "Developer project workspaces, regenerable build caches, dependencies & worktrees")
        ]

        return specs.map { spec in
            let stdPrefix = URL(fileURLWithPath: (spec.fullPath as NSString).expandingTildeInPath).standardizedFileURL.path
            let exists = FileManager.default.fileExists(atPath: stdPrefix)

            if spec.id == "root-developer-projects" {
                return MacStorageRootInfo(
                    id: spec.id,
                    displayPath: spec.display,
                    fullPath: stdPrefix,
                    exists: exists,
                    physicalBytes: projectSummary.totalProjectsPhysicalBytes,
                    safeReclaimableBytes: projectSummary.regenerableCachesAndBuildsBytes,
                    reviewReclaimableBytes: projectSummary.reviewRequiredBytes,
                    protectedBytes: projectSummary.protectedDataBytes + projectSummary.worktreesBytes,
                    note: spec.note
                )
            }

            let matching = countableItems.filter { item in
                let p = URL(fileURLWithPath: (item.path as NSString).expandingTildeInPath).standardizedFileURL.path
                return p == stdPrefix || p.hasPrefix(stdPrefix + "/")
            }
            let phys = matching.reduce(Int64(0)) { $0 + $1.physicalSize }
            let safe = matching.filter { $0.riskLevel == .safe }.reduce(Int64(0)) { $0 + $1.reclaimableSize }
            let review = matching.filter { $0.riskLevel == .review }.reduce(Int64(0)) { $0 + $1.reclaimableSize }
            let prot = max(0, phys - (safe + review))

            return MacStorageRootInfo(
                id: spec.id,
                displayPath: spec.display,
                fullPath: stdPrefix,
                exists: exists,
                physicalBytes: phys,
                safeReclaimableBytes: safe,
                reviewReclaimableBytes: review,
                protectedBytes: prot,
                note: spec.note
            )
        }
    }
}
