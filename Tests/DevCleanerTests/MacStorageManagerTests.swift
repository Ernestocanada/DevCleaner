import XCTest
@testable import DevCleaner

final class MacStorageManagerTests: XCTestCase {
    private var tempRoot: URL!
    private var tempHome: URL!
    private var tempTrash: URL!
    private var validator: SafetyValidator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DevCleanerMacStorageTests-\(UUID().uuidString)", isDirectory: true)
        tempHome = tempRoot.appendingPathComponent("Home", isDirectory: true)
        tempTrash = tempRoot.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempTrash, withIntermediateDirectories: true)
        validator = SafetyValidator(homeDirectory: tempHome.path)
    }

    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ relPath: String, sizeBytes: Int = 4096, textContent: String? = nil, modifiedDaysAgo: Double = 0) throws -> URL {
        let url = tempHome.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let textContent {
            try textContent.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let data = Data(repeating: 0x42, count: sizeBytes)
            try data.write(to: url)
        }
        if modifiedDaysAgo > 0 {
            let past = Date().addingTimeInterval(-modifiedDaysAgo * 86400)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        return url
    }

    // MARK: - 1. SafetyValidator Protected Paths, Firebase Credentials, Release APK/IPA & Xcode Archives

    func testSafetyValidatorBlocksWholeAppSupportFoldersAndSensitiveArtifacts() {
        let blockedPaths = [
            "~/Library/Application Support/Claude",
            "~/Library/Application Support/Codex",
            "~/Library/Application Support/Code",
            "~/Library/Application Support/Code/User/settings.json",
            "~/Library/Application Support/Antigravity",
            "~/Library/Application Support/Antigravity/User/state.vscdb",
            "~/Library/Application Support/Cursor",
            "~/Library/Application Support/Cursor/User/settings.json",
            "~/Library/Application Support/Notion",
            "~/Library/Application Support/Notion/notion.db",
            "~/Library/Application Support/Notion/Partitions",
            "~/Library/Application Support/Google",
            "~/Library/Application Support/Google/Chrome",
            "~/Library/Application Support/Google/DriveFS",
            "~/Library/Application Support/OutSystems",
            "~/Library/Developer/Xcode/Archives",
            "~/Library/Developer/Xcode/Archives/2026-10-30/MyApp.xcarchive",
            "~/Library/Developer/Xcode/UserData",
            "~/Library/Android/sdk",
            "~/Library/Android/sdk/ndk",
            "~/Library/Android/sdk/system-images",
            "~/Library/Android/sdk/platforms",
            "~/Library/Containers/com.docker.docker",
            "~/.cache/firebase",
            "~/.cache/firebase/emulators/firebase-adminsdk-prod.json",
            "~/.cache/firebase/emulators/service-account.json",
            "~/.cache/firebase/emulators/GoogleService-Info.plist",
            "~/.cache/firebase/emulators/google-services.json",
            "~/.cache/firebase/emulators/application_default_credentials.json",
            "~/Library/Caches/com.openai.atlas/App-release.apk",
            "~/Library/Caches/com.openai.atlas/AppStoreBuild.ipa"
        ]

        for path in blockedPaths {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Path must be strictly blocked by SafetyValidator: \(path)"
            )
            XCTAssertThrowsError(try validator.validateForDeletion(path, checkSymlinksOnDisk: false))
        }

        // Verify allow-listed subcaches ARE permitted
        let allowedSubcaches = [
            "~/Library/Caches/com.openai.atlas",
            "~/Library/Caches/dotslash",
            "~/Library/Caches/com.google.antigravity",
            "~/Library/Caches/com.google.GeminiMacOS",
            "~/Library/Caches/antigravity-updater",
            "~/Library/Caches/notion-updater",
            "~/Library/Caches/ms-playwright-go",
            "~/Library/Caches/ReactNative",
            "~/Library/Caches/pnpm",
            "~/Library/Caches/node-gyp",
            "~/Library/Caches/com.openai.chat",
            "~/.cache/puppeteer",
            "~/.cache/firebase/emulators",
            "~/.cache/node",
            "~/.cache/pkg",
            "~/Library/Developer/Xcode/DocumentationCache",
            "~/Library/Application Support/Code/Cache",
            "~/Library/Application Support/Code/CachedExtensionVSIXs",
            "~/Library/Application Support/Antigravity/CachedData",
            "~/Library/Application Support/Cursor/Cache",
            "~/Library/Application Support/Notion/Cache",
            "~/Library/Application Support/Google/GoogleUpdater/crx_cache"
        ]

        for path in allowedSubcaches {
            XCTAssertTrue(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Allow-listed subcache should be permitted: \(path)"
            )
        }
    }

    // MARK: - 2. Puppeteer, Firebase & ~/Library/Caches Explicit Rules

    func testPuppeteerFirebaseAndLibraryCachesExplicitClassifications() async throws {
        // Puppeteer browsers
        try writeFile(".cache/puppeteer/chrome/mac_arm-156.0.8078.47/Google Chrome for Testing.app/bin", sizeBytes: 16384)
        try writeFile(".cache/puppeteer/chrome-headless-shell/mac_arm-156.0.8078.47/shell", sizeBytes: 8192)

        // Firebase emulators + a credential file inside ~/.cache/firebase root
        try writeFile(".cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar", sizeBytes: 16384)
        let firebaseDebugLog = try writeFile(".cache/firebase/firebase-debug.log", sizeBytes: 2048)

        // Library/Caches explicit tools
        try writeFile("Library/Caches/com.openai.atlas/browser-data/Cache/data_1", sizeBytes: 8192)
        try writeFile("Library/Caches/dotslash/bin1", sizeBytes: 8192)
        try writeFile("Library/Caches/com.google.antigravity/ShipIt/update.pkg", sizeBytes: 8192)
        try writeFile("Library/Caches/com.google.GeminiMacOS/fsCachedData/f1", sizeBytes: 8192)
        try writeFile("Library/Caches/antigravity-updater/pending/update.zip", sizeBytes: 8192)
        try writeFile("Library/Caches/notion-updater/pending/notion.zip", sizeBytes: 8192)
        try writeFile("Library/Caches/ms-playwright-go/1.50.0/node", sizeBytes: 8192)
        try writeFile("Library/Caches/ReactNative/hermes.tar.gz", sizeBytes: 8192)
        try writeFile("Library/Caches/com.openai.chat/Data/cache.db", sizeBytes: 8192)

        let generalCleaner = StandardCacheCleaner(category: .generalCaches, homeDirectory: tempHome.path)
        let items = await generalCleaner.scan(snapshot: .empty, ageFilter: .all)

        let puppeteer = try XCTUnwrap(items.first { $0.id == "puppeteer-cache" })
        XCTAssertEqual(puppeteer.riskLevel, .review)
        XCTAssertEqual(puppeteer.deletionConsequence, "Browser binaries will need to be downloaded again.")
        XCTAssertTrue(puppeteer.explanation.contains("chrome/mac_arm-156.0.8078.47"))
        XCTAssertTrue(puppeteer.explanation.contains("chrome-headless-shell/mac_arm-156.0.8078.47"))

        let firebaseEmulators = try XCTUnwrap(items.first { $0.id == "firebase-emulators-cache" })
        XCTAssertEqual(firebaseEmulators.riskLevel, .review)
        XCTAssertGreaterThan(firebaseEmulators.reclaimableSize, 0)

        let firebaseProtected = try XCTUnwrap(items.first { $0.id == "firebase-non-emulator-protected" })
        XCTAssertEqual(firebaseProtected.riskLevel, .neverDelete)
        XCTAssertEqual(firebaseProtected.reclaimableSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firebaseDebugLog.path))

        for safeID in [
            "openai-atlas-cache", "dotslash-cache", "antigravity-cache",
            "gemini-macos-cache", "antigravity-updater-cache", "notion-updater-cache",
            "react-native-cache", "openai-chat-cache"
        ] {
            let item = try XCTUnwrap(items.first { $0.id == safeID }, "Missing expected item \(safeID)")
            XCTAssertEqual(item.riskLevel, .safe)
            XCTAssertGreaterThan(item.reclaimableSize, 0)
        }

        let playwrightGo = try XCTUnwrap(items.first { $0.id == "playwright-go-cache" })
        XCTAssertEqual(playwrightGo.riskLevel, .review)
    }

    // MARK: - 3. Application Support Subcache vs Protected Data & Zero Double-Counting

    func testApplicationSupportSplitsSafeSubcachesFromProtectedDataWithoutDoubleCounting() throws {
        // VS Code: 16 KB SAFE Cache + 16 KB SAFE CachedExtensionVSIXs + 32 KB Protected User/WebStorage
        try writeFile("Library/Application Support/Code/Cache/c1", sizeBytes: 16384)
        try writeFile("Library/Application Support/Code/CachedExtensionVSIXs/ext1.vsix", sizeBytes: 16384)
        try writeFile("Library/Application Support/Code/User/globalStorage/state.vscdb", sizeBytes: 16384)
        try writeFile("Library/Application Support/Code/WebStorage/ws1", sizeBytes: 16384)

        // Notion: 8 KB SAFE Cache + 32 KB Protected Partitions/notion.db
        try writeFile("Library/Application Support/Notion/Cache/n1", sizeBytes: 8192)
        try writeFile("Library/Application Support/Notion/notion.db", sizeBytes: 16384)
        try writeFile("Library/Application Support/Notion/Partitions/p1", sizeBytes: 16384)

        // OutSystems: 16 KB Protected ServiceStudio
        try writeFile("Library/Application Support/OutSystems/ServiceStudio/Settings.xml", sizeBytes: 16384)

        let macAnalyzer = MacStorageAnalyzer(homeDirectory: tempHome.path)
        let items = macAnalyzer.scanAdditionalMacStorageItems(snapshot: .empty, ageFilter: .all)

        let vscodeCache = try XCTUnwrap(items.first { $0.id == "appsupport-vscode-cache" })
        let vscodeVsix = try XCTUnwrap(items.first { $0.id == "appsupport-vscode-cachedextensionvsixs" })
        let vscodeProtected = try XCTUnwrap(items.first { $0.id == "appsupport-vscode-protected" })

        XCTAssertEqual(vscodeCache.riskLevel, .safe)
        XCTAssertEqual(vscodeVsix.riskLevel, .safe)
        XCTAssertEqual(vscodeProtected.riskLevel, .neverDelete)
        XCTAssertEqual(vscodeProtected.reclaimableSize, 0)

        let totalCodeOnDisk = DiskScanner.shared.measurePath(tempHome.appendingPathComponent("Library/Application Support/Code").path).physicalSize
        XCTAssertEqual(
            vscodeCache.physicalSize + vscodeVsix.physicalSize + vscodeProtected.physicalSize,
            totalCodeOnDisk,
            "VS Code subcaches + protected remainder must equal exact disk usage without double counting"
        )

        // When VS Code is running, its subcaches must be blocked (isRunningDependency == true, reclaimableSize == 0)
        let runningVSCodeSnapshot = ActiveProcessSnapshot(activeLines: [], runningAppNames: ["Visual Studio Code"])
        let activeItems = macAnalyzer.scanAdditionalMacStorageItems(snapshot: runningVSCodeSnapshot, ageFilter: .all)
        let activeVSCodeCache = try XCTUnwrap(activeItems.first { $0.id == "appsupport-vscode-cache" })
        XCTAssertTrue(activeVSCodeCache.isRunningDependency)
        XCTAssertEqual(activeVSCodeCache.reclaimableSize, 0)
        XCTAssertFalse(activeVSCodeCache.canBeSelected)
    }

    // MARK: - 4. Docker CLI Stats Parsing & Volume Protection

    func testDockerCLIStatsParsingAndVolumeProtection() async throws {
        let dfOutput = """
        {"Active":"1","Reclaimable":"1.5GB (50%)","Size":"3GB","TotalCount":"4","Type":"Images"}
        {"Active":"0","Reclaimable":"250MB (100%)","Size":"250MB","TotalCount":"2","Type":"Containers"}
        {"Active":"1","Reclaimable":"800MB (40%)","Size":"2GB","TotalCount":"3","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"500MB","Size":"500MB","TotalCount":"12","Type":"Build Cache"}
        """

        let stats = DockerCleaner.parseDockerSystemDFJSONLines(dfOutput)
        XCTAssertEqual(stats.imagesTotalCount, 4)
        XCTAssertEqual(stats.imagesReclaimableBytes, 1_500_000_000)
        XCTAssertEqual(stats.containersTotalCount, 2)
        XCTAssertEqual(stats.containersStoppedCount, 2)
        XCTAssertEqual(stats.containersReclaimableBytes, 250_000_000)
        XCTAssertEqual(stats.volumesTotalCount, 3)
        XCTAssertEqual(stats.volumesReclaimableBytes, 800_000_000)
        XCTAssertEqual(stats.buildCacheReclaimableBytes, 500_000_000)

        let runningCleaner = DockerCleaner(
            homeDirectory: tempHome.path,
            daemonRunningOverride: true,
            diskUsageOverride: DiskUsageInfo(logicalSize: 64_000_000_000, physicalSize: 11_260_000_000, lastModified: Date(), fileCount: 1),
            cliStatsOverride: stats
        )
        let items = await runningCleaner.scan(snapshot: .empty, ageFilter: .all)

        let buildCache = try XCTUnwrap(items.first { $0.id == "docker-prune-build-cache" })
        let containers = try XCTUnwrap(items.first { $0.id == "docker-prune-stopped-containers" })
        let images = try XCTUnwrap(items.first { $0.id == "docker-prune-dangling-images" })
        let volumes = try XCTUnwrap(items.first { $0.id == "docker-prune-volumes" })

        XCTAssertEqual(buildCache.riskLevel, .safe)
        XCTAssertEqual(buildCache.reclaimableSize, 500_000_000)
        XCTAssertEqual(containers.riskLevel, .safe)
        XCTAssertEqual(containers.reclaimableSize, 250_000_000)
        XCTAssertEqual(images.riskLevel, .safe)
        XCTAssertEqual(images.reclaimableSize, 1_500_000_000)

        // Volumes must NEVER be SAFE automatically
        XCTAssertEqual(volumes.riskLevel, .caution)
        XCTAssertNotEqual(volumes.riskLevel, .safe)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(volumes))
    }

    // MARK: - 5. Simulator Model, Last Used & Recommendation Badge Tests

    func testSimulatorDeviceModelLastUsedAndRecommendationBadges() throws {
        let recentDateISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400)) // 3 days ago -> KEEP
        let oldDateISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-72 * 86400))   // 72 days ago -> REVIEW

        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "11111111-1111-1111-1111-111111111111",
                "name": "iPhone 18 Pro",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 4200000000,
                "logPathSize": 0,
                "lastUsedAt": "\(recentDateISO)"
              },
              {
                "udid": "22222222-2222-2222-2222-222222222222",
                "name": "iPhone 16e",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16e",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3800000000,
                "logPathSize": 0,
                "lastUsedAt": "\(oldDateISO)"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let items = try SimulatorCleaner.parseDevicesJSON(json, homeDirectory: tempHome.path)
        let recentSim = try XCTUnwrap(items.first { $0.id == "sim-device-11111111-1111-1111-1111-111111111111" })
        let oldSim = try XCTUnwrap(items.first { $0.id == "sim-device-22222222-2222-2222-2222-222222222222" })

        XCTAssertEqual(recentSim.simulatorMetadata?.deviceModel, "iPhone 18 Pro")
        XCTAssertEqual(recentSim.simulatorMetadata?.recommendationBadgeText, "KEEP")
        XCTAssertNotNil(recentSim.lastUsed)
        XCTAssertTrue(recentSim.usageDateDescription.hasPrefix("Last used:"))

        XCTAssertEqual(oldSim.simulatorMetadata?.deviceModel, "iPhone 16e")
        XCTAssertEqual(oldSim.simulatorMetadata?.recommendationBadgeText, "REVIEW")
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(recentSim))
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(oldSim))
    }

    // MARK: - 6. Path Modified After Scan Protection in CleanupExecutor

    func testExecutorBlocksItemModifiedAfterScanTimestamp() async throws {
        let cacheFile = try writeFile("Library/Caches/dotslash/tool-bin", sizeBytes: 4096)
        let dotslashDir = tempHome.appendingPathComponent("Library/Caches/dotslash").path

        // Item scanned with lastModified 1 hour in the past, while file on disk was just modified now
        let staleTimestamp = Date().addingTimeInterval(-3600)
        let item = CleanableItem(
            id: "dotslash-cache",
            name: "DotSlash Cache",
            category: .generalCaches,
            path: dotslashDir,
            logicalSize: 4096,
            physicalSize: 4096,
            reclaimableSize: 4096,
            lastModified: staleTimestamp,
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrash(path: dotslashDir)
        )

        let trashDir = self.tempTrash!
        let executor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { url in
                let dest = trashDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
            },
            shellRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") }
        )

        do {
            _ = try await executor.execute(item)
            XCTFail("Expected SafetyError.modifiedSinceScan when file was modified after scan")
        } catch let error as SafetyError {
            guard case .modifiedSinceScan = error else {
                XCTFail("Expected SafetyError.modifiedSinceScan, got \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path), "Modified file must not be moved to Trash")
    }

    // MARK: - 7. Mac Storage Global Summary Deduplication & Recommended Clean Exclusions

    func testMacStorageSummaryZeroDoubleCountingAndRecommendedCleanExclusions() throws {
        try writeFile("Library/Application Support/Claude/Cache/c1", sizeBytes: 8192)
        try writeFile("Library/Application Support/Claude/vm_bundles/vm.img", sizeBytes: 16384)
        try writeFile("Library/Application Support/Claude/simulator-builds/b1", sizeBytes: 16384)
        try writeFile(".cache/codex-runtimes/r1", sizeBytes: 16384)

        let claudeCacheItem = CleanableItem(
            id: "claude-cache",
            name: "Claude Cache",
            category: .claude,
            path: "\(tempHome.path)/Library/Application Support/Claude/Cache",
            logicalSize: 8192,
            physicalSize: 8192,
            reclaimableSize: 8192,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: "\(tempHome.path)/Library/Application Support/Claude/Cache", minAgeDays: nil)
        )

        let duplicateClaudeCacheItem = CleanableItem(
            id: "claude-cache-duplicate-id",
            name: "Claude Cache Duplicate Path",
            category: .generalCaches,
            path: "\(tempHome.path)/Library/Application Support/Claude/Cache",
            logicalSize: 8192,
            physicalSize: 8192,
            reclaimableSize: 8192,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: "\(tempHome.path)/Library/Application Support/Claude/Cache", minAgeDays: nil)
        )

        let deduplicated = MacStorageAnalyzer.deduplicateItems([claudeCacheItem, duplicateClaudeCacheItem])
        XCTAssertEqual(deduplicated.count, 1, "Identical cleanable paths must be deduplicated so they are never counted twice")

        let pSummary = ProjectStorageSummary(
            rootDirectoryPath: "\(tempHome.path)/Developer",
            totalProjectsCount: 2,
            totalProjectsPhysicalBytes: 50_000_000,
            regenerableCachesAndBuildsBytes: 20_000_000,
            reviewRequiredBytes: 10_000_000,
            worktreesBytes: 5_000_000,
            protectedDataBytes: 15_000_000
        )

        let macAnalyzer = MacStorageAnalyzer(homeDirectory: tempHome.path)
        let macSummary = macAnalyzer.buildSummary(
            providerItems: [claudeCacheItem, duplicateClaudeCacheItem],
            additionalItems: [],
            projectSummary: pSummary,
            projectsRootPath: "\(tempHome.path)/Developer"
        )

        let domainSum = macSummary.developerProjectsBytes
            + macSummary.aiToolsBytes
            + macSummary.simulatorsBytes
            + macSummary.dockerBytes
            + macSummary.androidSDKBytes
            + macSummary.cachesBytes
            + macSummary.otherDeveloperDataBytes

        XCTAssertEqual(
            macSummary.totalDeveloperStorageBytes,
            domainSum,
            "Domain breakdown in MacStorageSummary must sum to totalDeveloperStorageBytes without double counting"
        )

        // Verify Recommended Clean eligibility rules
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(claudeCacheItem))

        let nodeModulesItem = CleanableItem(
            id: "proj-node-modules",
            name: "node_modules",
            category: .projectStorage,
            path: "\(tempHome.path)/Developer/MyApp/node_modules",
            logicalSize: 1000,
            physicalSize: 1000,
            reclaimableSize: 1000,
            lastModified: Date(),
            riskLevel: .safe, // Even if mislabeled .safe, path check must block node_modules
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrash(path: "\(tempHome.path)/Developer/MyApp/node_modules")
        )
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(nodeModulesItem), "node_modules must never be included in Recommended Clean")
    }
}
