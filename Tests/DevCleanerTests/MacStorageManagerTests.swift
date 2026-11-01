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
            "~/.android/avd",
            "~/.android/avd/medium_phone.avd",
            "~/Library/Containers/com.docker.docker",
            "~/.cache/firebase",
            "~/.cache/firebase/emulators/firebase-adminsdk-prod.json",
            "~/.cache/firebase/emulators/service-account.json",
            "~/.cache/firebase/emulators/GoogleService-Info.plist",
            "~/.cache/firebase/emulators/google-services.json",
            "~/.cache/firebase/emulators/application_default_credentials.json",
            "~/Library/Caches/com.openai.atlas",
            "~/Library/Caches/com.openai.atlas/browser-data",
            "~/Library/Caches/com.openai.atlas/browser-data/host",
            "~/Library/Caches/com.openai.atlas/browser-data/host/user-123",
            "~/Library/Caches/com.openai.atlas/org.sparkle-project.Sparkle",
            "~/Library/Caches/com.openai.atlas/com.apple.e5rt.e5bundlecache",
            "~/Library/Caches/com.openai.atlas/io.sentry",
            "~/Library/Caches/com.openai.atlas/Cache.db",
            "~/Library/Caches/com.openai.atlas/Cache/App-release.apk",
            "~/Library/Caches/com.openai.atlas/Cache/AppStoreBuild.ipa",
            "~/Library/Caches/Google",
            "~/Library/Caches/Google/Chrome",
            "~/Library/Caches/Google/Chrome/Default",
            "~/Library/Caches/Google/UnknownTool"
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
            "~/Library/Caches/com.openai.atlas/Cache",
            "~/Library/Caches/com.openai.atlas/Code Cache",
            "~/Library/Caches/com.openai.atlas/GPUCache",
            "~/Library/Caches/com.openai.atlas/com.onevcat.Kingfisher.ImageCache",
            "~/Library/Caches/com.openai.atlas/browser-data/host/login-staging-123/Cache",
            "~/Library/Caches/com.openai.atlas/browser-data/host/login-staging-123/Code Cache",
            "~/Library/Caches/com.openai.atlas/browser-data/host/user-abc/Cache",
            "~/Library/Caches/com.openai.atlas/browser-data/host/user-abc/Code Cache",
            "~/Library/Caches/Google/Cache",
            "~/Library/Caches/Google/Chrome/Default/Cache",
            "~/Library/Caches/Google/Chrome/Default/Code Cache",
            "~/Library/Caches/Google/Chrome/Default/GPUCache",
            "~/Library/Caches/Google/Chrome/Default/image_cache",
            "~/Library/Caches/Google/Chrome/Profile 1/Cache",
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

    // MARK: - 2. Puppeteer, Firebase & Narrowed ~/Library/Caches Explicit Rules

    func testPuppeteerFirebaseAndLibraryCachesExplicitClassifications() async throws {
        // Puppeteer browsers
        try writeFile(".cache/puppeteer/chrome/mac_arm-156.0.8078.47/Google Chrome for Testing.app/bin", sizeBytes: 16384)
        try writeFile(".cache/puppeteer/chrome-headless-shell/mac_arm-156.0.8078.47/shell", sizeBytes: 8192)

        // Firebase emulators + a credential file inside ~/.cache/firebase root
        try writeFile(".cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar", sizeBytes: 16384)
        let firebaseDebugLog = try writeFile(".cache/firebase/firebase-debug.log", sizeBytes: 2048)

        // OpenAI Atlas: verified subcaches + unverified Sparkle & E5RT children
        try writeFile("Library/Caches/com.openai.atlas/browser-data/host/login-staging-abc/Cache/data_1", sizeBytes: 8192)
        try writeFile("Library/Caches/com.openai.atlas/browser-data/host/user-xyz/Code Cache/js_1", sizeBytes: 8192)
        try writeFile("Library/Caches/com.openai.atlas/com.onevcat.Kingfisher.ImageCache/img_1", sizeBytes: 8192)
        let sparkleFile = try writeFile("Library/Caches/com.openai.atlas/org.sparkle-project.Sparkle/PersistentDownloads/update.dmg", sizeBytes: 8192)
        let e5rtFile = try writeFile("Library/Caches/com.openai.atlas/com.apple.e5rt.e5bundlecache/model.bundle", sizeBytes: 8192)

        // Google Caches: verified Chrome profile subcaches + unverified sibling
        try writeFile("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/f_001", sizeBytes: 8192)
        try writeFile("Library/Caches/Google/Chrome/Default/Code Cache/js/idx", sizeBytes: 8192)
        let googleUnverifiedFile = try writeFile("Library/Caches/Google/UnknownGoogleService/state.db", sizeBytes: 8192)

        // Other Library/Caches explicit tools
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

        // Verify Atlas verified subcaches are SAFE and eligible for Recommended Clean
        let atlasLoginCache = try XCTUnwrap(items.first { $0.id == "openai-atlas-cache-browser-data-host-login-staging-abc-cache" })
        let atlasUserCodeCache = try XCTUnwrap(items.first { $0.id == "openai-atlas-cache-browser-data-host-user-xyz-code-cache" })
        let atlasKingfisher = try XCTUnwrap(items.first { $0.id == "openai-atlas-cache-com-onevcat-kingfisher-imagecache" })
        for verifiedAtlas in [atlasLoginCache, atlasUserCodeCache, atlasKingfisher] {
            XCTAssertEqual(verifiedAtlas.riskLevel, .safe)
            XCTAssertGreaterThan(verifiedAtlas.reclaimableSize, 0)
            XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(verifiedAtlas))
        }

        // Verify Atlas unverified children (Sparkle, e5bundlecache) are REVIEW, non-selectable, 0 reclaimable, and NEVER in Recommended Clean
        let atlasUnverified = try XCTUnwrap(items.first { $0.id == "openai-atlas-unverified-review" })
        XCTAssertEqual(atlasUnverified.riskLevel, .review)
        XCTAssertEqual(atlasUnverified.reclaimableSize, 0)
        XCTAssertFalse(atlasUnverified.canBeSelected)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(atlasUnverified))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sparkleFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: e5rtFile.path))

        // Verify Google verified Chrome subcaches are SAFE and unverified data is REVIEW (never in Recommended Clean)
        let googleDefaultCache = try XCTUnwrap(items.first { $0.id == "google-caches-chrome-default-cache" })
        let googleDefaultCodeCache = try XCTUnwrap(items.first { $0.id == "google-caches-chrome-default-code-cache" })
        XCTAssertEqual(googleDefaultCache.riskLevel, .safe)
        XCTAssertEqual(googleDefaultCodeCache.riskLevel, .safe)
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(googleDefaultCache))

        let googleUnverified = try XCTUnwrap(items.first { $0.id == "google-caches-unverified-review" })
        XCTAssertEqual(googleUnverified.riskLevel, .review)
        XCTAssertEqual(googleUnverified.reclaimableSize, 0)
        XCTAssertFalse(googleUnverified.canBeSelected)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(googleUnverified))
        XCTAssertTrue(FileManager.default.fileExists(atPath: googleUnverifiedFile.path))

        for safeID in [
            "dotslash-cache", "antigravity-cache",
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

    // MARK: - 4. Docker CLI Stats Parsing, Command Semantics & Volume Protection

    func testDockerCLIStatsParsingAndVolumeProtection() async throws {
        let dfOutput = """
        {"Active":"1","Reclaimable":"1.5GB (50%)","Size":"3GB","TotalCount":"4","Type":"Images"}
        {"Active":"0","Reclaimable":"250MB (100%)","Size":"250MB","TotalCount":"2","Type":"Containers"}
        {"Active":"1","Reclaimable":"800MB (40%)","Size":"2GB","TotalCount":"3","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"500MB","Size":"500MB","TotalCount":"12","Type":"Build Cache"}
        """

        // Dangling images output (`docker image ls -f dangling=true`): 300MB across 2 dangling images (plus a duplicate tag line for sha256:aaa)
        let danglingOutput = """
        sha256:aaa111\t200MB
        sha256:aaa111\t200MB
        sha256:bbb222\t100MB
        """

        // Builder du output (`docker builder du --format "{{json .}}"`): 350MB reclaimable & not in-use/shared, 150MB shared or in-use
        let builderDUOutput = """
        {"ID":"b1","Reclaimable":true,"Shared":false,"InUse":false,"Size":"200MB"}
        {"ID":"b2","Reclaimable":true,"Shared":false,"InUse":false,"Size":"150MB"}
        {"ID":"b3","Reclaimable":true,"Shared":true,"InUse":false,"Size":"100MB"}
        {"ID":"b4","Reclaimable":false,"Shared":false,"InUse":true,"Size":"50MB"}
        """

        let stats = DockerCleaner.parseDockerSystemDFJSONLines(
            dfOutput,
            danglingImagesOutput: danglingOutput,
            builderDUOutput: builderDUOutput
        )
        XCTAssertEqual(stats.imagesTotalCount, 4)
        XCTAssertEqual(stats.imagesReclaimableBytes, 1_500_000_000)
        XCTAssertEqual(stats.danglingImagesCount, 2)
        XCTAssertEqual(stats.danglingImagesReclaimableBytes, 300_000_000)
        XCTAssertEqual(stats.unusedNonDanglingImagesReclaimableBytes, 1_200_000_000)
        XCTAssertEqual(stats.containersTotalCount, 2)
        XCTAssertEqual(stats.containersStoppedCount, 2)
        XCTAssertEqual(stats.containersReclaimableBytes, 250_000_000)
        XCTAssertEqual(stats.volumesTotalCount, 3)
        XCTAssertEqual(stats.volumesReclaimableBytes, 800_000_000)
        XCTAssertEqual(stats.buildCacheReclaimableBytes, 350_000_000)

        let runningCleaner = DockerCleaner(
            homeDirectory: tempHome.path,
            daemonRunningOverride: true,
            diskUsageOverride: DiskUsageInfo(logicalSize: 64_000_000_000, physicalSize: 11_260_000_000, lastModified: Date(), fileCount: 1),
            cliStatsOverride: stats
        )
        let items = await runningCleaner.scan(snapshot: .empty, ageFilter: .all)

        let rawDisk = try XCTUnwrap(items.first { $0.id == "docker-raw-disk" })
        let buildCache = try XCTUnwrap(items.first { $0.id == "docker-prune-build-cache" })
        let containers = try XCTUnwrap(items.first { $0.id == "docker-prune-stopped-containers" })
        let danglingImages = try XCTUnwrap(items.first { $0.id == "docker-prune-dangling-images" })
        let unusedImages = try XCTUnwrap(items.first { $0.id == "docker-prune-unused-images" })
        let volumes = try XCTUnwrap(items.first { $0.id == "docker-prune-volumes" })

        // Docker.raw is strictly NEVER DELETE
        XCTAssertEqual(rawDisk.riskLevel, .neverDelete)
        XCTAssertEqual(rawDisk.reclaimableSize, 0)
        XCTAssertFalse(rawDisk.canBeSelected)

        // Build cache SAFE item matches actual `docker builder prune -f` removable bytes (350 MB, not 500 MB)
        XCTAssertEqual(buildCache.riskLevel, .safe)
        XCTAssertEqual(buildCache.reclaimableSize, 350_000_000)
        XCTAssertEqual(buildCache.actionType, .dockerPrune(subcommand: ["builder", "prune", "-f"]))
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(buildCache))

        // Stopped containers SAFE item matches `docker container prune -f` (250 MB)
        XCTAssertEqual(containers.riskLevel, .safe)
        XCTAssertEqual(containers.reclaimableSize, 250_000_000)
        XCTAssertEqual(containers.actionType, .dockerPrune(subcommand: ["container", "prune", "-f"]))
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(containers))

        // Dangling images SAFE item matches `docker image prune -f` (300 MB dangling only, NOT 1.5 GB total unused)
        XCTAssertEqual(danglingImages.riskLevel, .safe)
        XCTAssertEqual(danglingImages.reclaimableSize, 300_000_000)
        XCTAssertEqual(danglingImages.actionType, .dockerPrune(subcommand: ["image", "prune", "-f"]))
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(danglingImages))

        // Unused non-dangling images item uses `docker image prune -a -f`, is REVIEW, and reports the 1.2 GB beyond dangling
        XCTAssertEqual(unusedImages.riskLevel, .review)
        XCTAssertEqual(unusedImages.reclaimableSize, 1_200_000_000)
        XCTAssertEqual(unusedImages.actionType, .dockerPrune(subcommand: ["image", "prune", "-a", "-f"]))
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(unusedImages))

        // Volumes must NEVER be SAFE automatically
        XCTAssertEqual(volumes.riskLevel, .caution)
        XCTAssertEqual(volumes.reclaimableSize, 800_000_000)
        XCTAssertEqual(volumes.actionType, .dockerPrune(subcommand: ["volume", "prune", "-f"]))
        XCTAssertNotEqual(volumes.riskLevel, .safe)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(volumes))

        // When `docker system df` is parsed WITHOUT `docker image ls -f dangling=true` or `docker builder du`,
        // both danglingImagesReclaimableBytes and buildCacheReclaimableBytes are conservatively 0 and buildCacheVerified is false.
        let dfOnlyStats = DockerCleaner.parseDockerSystemDFJSONLines(dfOutput)
        XCTAssertEqual(dfOnlyStats.danglingImagesReclaimableBytes, 0)
        XCTAssertEqual(dfOnlyStats.unusedNonDanglingImagesReclaimableBytes, 1_500_000_000)
        XCTAssertEqual(dfOnlyStats.buildCacheReclaimableBytes, 0)
        XCTAssertFalse(dfOnlyStats.buildCacheVerified)
    }

    func testDockerBuilderCacheUnverifiedMalformedAndCommandFailureFallbacks() async throws {
        let dfOutputWith500MBBuildCache = """
        {"Active":"1","Reclaimable":"1.5GB (50%)","Size":"3GB","TotalCount":"4","Type":"Images"}
        {"Active":"0","Reclaimable":"250MB (100%)","Size":"250MB","TotalCount":"2","Type":"Containers"}
        {"Active":"1","Reclaimable":"800MB (40%)","Size":"2GB","TotalCount":"3","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"500MB","Size":"500MB","TotalCount":"12","Type":"Build Cache"}
        """
        let danglingOutput = "sha256:aaa111\t300MB\n"
        let mockDisk = DiskUsageInfo(logicalSize: 64_000_000_000, physicalSize: 11_260_000_000, lastModified: Date(), fileCount: 1)

        // 1. Valid `docker builder du` -> exact SAFE reclaimable bytes (only confirmed removable bytes, not 500MB from system df)
        let validTabularBuilderDU = """
        ID                                              RECLAIMABLE   SIZE      LAST ACCESSED
        cache001                                        true          180MB     2 days ago
        cache002                                        true*         200MB*    3 days ago
        cache003                                        false         120MB     1 hour ago
        Reclaimable: 180MB
        Total: 500MB
        """
        let validStats = DockerCleaner.parseDockerSystemDFJSONLines(
            dfOutputWith500MBBuildCache,
            danglingImagesOutput: danglingOutput,
            builderDUOutput: validTabularBuilderDU
        )
        XCTAssertTrue(validStats.buildCacheVerified)
        XCTAssertEqual(validStats.buildCacheReclaimableBytes, 180_000_000)

        let validItems = await DockerCleaner(
            homeDirectory: tempHome.path,
            daemonRunningOverride: true,
            diskUsageOverride: mockDisk,
            cliStatsOverride: validStats
        ).scan(snapshot: .empty, ageFilter: .all)
        let validBuildCacheItem = try XCTUnwrap(validItems.first { $0.id == "docker-prune-build-cache" })
        XCTAssertEqual(validBuildCacheItem.riskLevel, .safe)
        XCTAssertEqual(validBuildCacheItem.reclaimableSize, 180_000_000)
        XCTAssertTrue(validBuildCacheItem.canBeSelected)
        XCTAssertTrue(CleanerViewModel.isEligibleForRecommendedSafeCleanup(validBuildCacheItem))

        // 2. Malformed / unsupported `docker builder du` output -> REVIEW + 0 reclaimable + non-selectable
        for malformedOutput in [
            "{\"unexpected\":\"json_without_id_or_size\"}",
            "{\"ID\":\"b1\",\"Reclaimable\":true,\"Size\":\"not_a_size\"}",
            "ID RECLAIMABLE SIZE\ncache1 maybe unknown_size",
            "UNSUPPORTED BUILDER DU FORMAT 500MB"
        ] {
            XCTAssertNil(DockerCleaner.parseDockerBuilderDUOutput(malformedOutput), "Malformed builder du output must return nil: \(malformedOutput)")
            let malformedStats = DockerCleaner.parseDockerSystemDFJSONLines(
                dfOutputWith500MBBuildCache,
                danglingImagesOutput: danglingOutput,
                builderDUOutput: malformedOutput
            )
            XCTAssertFalse(malformedStats.buildCacheVerified)
            XCTAssertEqual(malformedStats.buildCacheReclaimableBytes, 0, "Must never fall back to 500MB from docker system df")

            let malformedItems = await DockerCleaner(
                homeDirectory: tempHome.path,
                daemonRunningOverride: true,
                diskUsageOverride: mockDisk,
                cliStatsOverride: malformedStats
            ).scan(snapshot: .empty, ageFilter: .all)
            let buildCacheItem = try XCTUnwrap(malformedItems.first { $0.id == "docker-prune-build-cache" })
            XCTAssertEqual(buildCacheItem.riskLevel, .review)
            XCTAssertEqual(buildCacheItem.reclaimableSize, 0)
            XCTAssertFalse(buildCacheItem.canBeSelected)
            XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(buildCacheItem))
            XCTAssertTrue(buildCacheItem.explanation.contains("could not be verified"))
        }

        // 3. `docker builder du` command failure -> REVIEW + 0 reclaimable + non-selectable
        let commandFailureStats = await DockerCleaner.fetchLiveDockerCLIStats(
            dockerBinary: "/mock/bin/docker",
            runner: { _, args in
                if args.prefix(2) == ["system", "df"] {
                    return ShellResult(exitCode: 0, stdout: dfOutputWith500MBBuildCache, stderr: "")
                }
                if args.prefix(2) == ["image", "ls"] && args.contains("dangling=true") {
                    return ShellResult(exitCode: 0, stdout: danglingOutput, stderr: "")
                }
                if args.prefix(2) == ["builder", "du"] {
                    return ShellResult(exitCode: 1, stdout: "", stderr: "failed to query buildkit du")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        XCTAssertFalse(commandFailureStats.buildCacheVerified)
        XCTAssertEqual(commandFailureStats.buildCacheReclaimableBytes, 0)
        XCTAssertEqual(commandFailureStats.buildCacheSizeBytes, 500_000_000)

        let failureItems = await DockerCleaner(
            homeDirectory: tempHome.path,
            daemonRunningOverride: true,
            diskUsageOverride: mockDisk,
            cliStatsOverride: commandFailureStats
        ).scan(snapshot: .empty, ageFilter: .all)
        let failedBuildCacheItem = try XCTUnwrap(failureItems.first { $0.id == "docker-prune-build-cache" })
        XCTAssertEqual(failedBuildCacheItem.riskLevel, .review)
        XCTAssertEqual(failedBuildCacheItem.reclaimableSize, 0)
        XCTAssertFalse(failedBuildCacheItem.canBeSelected)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(failedBuildCacheItem))
        XCTAssertTrue(failedBuildCacheItem.explanation.contains("could not be verified"))

        // 4. `docker system df` showing reclaimable bytes must NOT promote build cache to SAFE when builder data is unverified
        let unverifiedDFStats = DockerCleaner.parseDockerSystemDFJSONLines(dfOutputWith500MBBuildCache, danglingImagesOutput: danglingOutput, builderDUOutput: nil)
        let unverifiedItems = await DockerCleaner(
            homeDirectory: tempHome.path,
            daemonRunningOverride: true,
            diskUsageOverride: mockDisk,
            cliStatsOverride: unverifiedDFStats
        ).scan(snapshot: .empty, ageFilter: .all)
        let unverifiedBuildCacheItem = try XCTUnwrap(unverifiedItems.first { $0.id == "docker-prune-build-cache" })
        XCTAssertEqual(unverifiedBuildCacheItem.riskLevel, .review)
        XCTAssertEqual(unverifiedBuildCacheItem.reclaimableSize, 0)
        XCTAssertFalse(unverifiedBuildCacheItem.canBeSelected)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(unverifiedBuildCacheItem))
    }

    // MARK: - 5. Simulator Model, Last Used & 30-Day Recommendation Threshold Tests

    func testSimulatorDeviceModelLastUsedAndRecommendationBadges() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let day3ISO = iso.string(from: now.addingTimeInterval(-3 * 86400))   // 3 days  -> KEEP
        let day20ISO = iso.string(from: now.addingTimeInterval(-20 * 86400)) // 20 days -> KEEP
        let day30ISO = iso.string(from: now.addingTimeInterval(-30 * 86400)) // 30 days -> KEEP
        let day31ISO = iso.string(from: now.addingTimeInterval(-31 * 86400)) // 31 days -> REVIEW
        let day45ISO = iso.string(from: now.addingTimeInterval(-45 * 86400)) // 45 days -> REVIEW

        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "11111111-1111-1111-1111-111111111111",
                "name": "iPhone 18 Pro (3d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 4200000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day3ISO)"
              },
              {
                "udid": "22222222-2222-2222-2222-222222222222",
                "name": "iPhone 18 (20d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3900000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day20ISO)"
              },
              {
                "udid": "33333333-3333-3333-3333-333333333333",
                "name": "iPhone 17 Pro (30d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3700000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day30ISO)"
              },
              {
                "udid": "44444444-4444-4444-4444-444444444444",
                "name": "iPhone 16e (31d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16e",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3600000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day31ISO)"
              },
              {
                "udid": "55555555-5555-5555-5555-555555555555",
                "name": "iPhone 15 (45d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3500000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day45ISO)"
              },
              {
                "udid": "66666666-6666-6666-6666-666666666666",
                "name": "iPhone SE (Unknown Usage)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3100000000,
                "logPathSize": 0
              },
              {
                "udid": "77777777-7777-7777-7777-777777777777",
                "name": "iPhone 18 Pro Max (Booted 45d)",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max",
                "state": "Booted",
                "isAvailable": true,
                "dataPathSize": 4500000000,
                "logPathSize": 0,
                "lastUsedAt": "\(day45ISO)"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let items = try SimulatorCleaner.parseDevicesJSON(json, homeDirectory: tempHome.path)
        let sim3d = try XCTUnwrap(items.first { $0.id == "sim-device-11111111-1111-1111-1111-111111111111" })
        let sim20d = try XCTUnwrap(items.first { $0.id == "sim-device-22222222-2222-2222-2222-222222222222" })
        let sim30d = try XCTUnwrap(items.first { $0.id == "sim-device-33333333-3333-3333-3333-333333333333" })
        let sim31d = try XCTUnwrap(items.first { $0.id == "sim-device-44444444-4444-4444-4444-444444444444" })
        let sim45d = try XCTUnwrap(items.first { $0.id == "sim-device-55555555-5555-5555-5555-555555555555" })
        let simUnknown = try XCTUnwrap(items.first { $0.id == "sim-device-66666666-6666-6666-6666-666666666666" })
        let simBooted = try XCTUnwrap(items.first { $0.id == "sim-device-77777777-7777-7777-7777-777777777777" })

        XCTAssertEqual(sim3d.simulatorMetadata?.deviceModel, "iPhone 18 Pro")
        XCTAssertEqual(sim3d.simulatorMetadata?.recommendationBadgeText, "KEEP")
        XCTAssertEqual(sim20d.simulatorMetadata?.recommendationBadgeText, "KEEP")
        XCTAssertEqual(sim30d.simulatorMetadata?.recommendationBadgeText, "KEEP")
        XCTAssertEqual(sim31d.simulatorMetadata?.recommendationBadgeText, "REVIEW")
        XCTAssertEqual(sim45d.simulatorMetadata?.recommendationBadgeText, "REVIEW")
        XCTAssertEqual(simUnknown.simulatorMetadata?.recommendationBadgeText, "REVIEW")
        XCTAssertEqual(simBooted.simulatorMetadata?.recommendationBadgeText, "KEEP")

        // Favorite simulator is always KEEP even when older than 30 days
        let favMeta = SimulatorMetadata(
            udid: "88888888-8888-8888-8888-888888888888",
            deviceModel: "iPhone 16",
            runtimeName: "iOS 26.3",
            state: "Shutdown",
            isAvailable: true,
            lastUsedAt: now.addingTimeInterval(-90 * 86400),
            isFavorite: true
        )
        XCTAssertEqual(favMeta.recommendationBadge(referenceDate: now), "KEEP")

        // Unavailable simulator preserves UNAVAILABLE badge
        let unavailMeta = SimulatorMetadata(
            udid: "99999999-9999-9999-9999-999999999999",
            deviceModel: "iPhone 14",
            runtimeName: "iOS 17.0",
            state: "Shutdown",
            isAvailable: false,
            lastUsedAt: now.addingTimeInterval(-3 * 86400),
            isFavorite: false
        )
        XCTAssertEqual(unavailMeta.recommendationBadge(referenceDate: now), "UNAVAILABLE")

        // Simulator deletion continues to use official xcrun simctl
        XCTAssertEqual(sim31d.actionType, .simctlDeleteDevice(udid: "44444444-4444-4444-4444-444444444444"))
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(sim3d))
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(sim31d))
    }

    // MARK: - 5b. Official Android AVD Deletion (`avdmanager delete avd -n <AVD_NAME>`) Tests

    func testAndroidAVDUsesOfficialAVDManagerAndNeverFallsBackToManualDirectoryDeletion() async throws {
        // Create a mock AVD directory and .ini file in tempHome/.android/avd
        let avdFile = try writeFile(".android/avd/medium_phone.avd/userdata-qemu.img", sizeBytes: 32768)
        try writeFile(
            ".android/avd/medium_phone.avd/config.ini",
            textContent: "avd.ini.displayname=Medium Phone\nabi.type=arm64-v8a\nimage.sysdir.1=system-images/android-36.1/google_apis_playstore/arm64-v8a/\n"
        )
        let iniFile = try writeFile(".android/avd/medium_phone.ini", textContent: "path=\(tempHome.path)/.android/avd/medium_phone.avd\n")

        // 1. Validate AVD name sanitization
        XCTAssertTrue(AndroidCleaner.isValidAVDName("medium_phone"))
        XCTAssertTrue(AndroidCleaner.isValidAVDName("Pixel_9_Pro_API_36.1-ext"))
        XCTAssertFalse(AndroidCleaner.isValidAVDName(""))
        XCTAssertFalse(AndroidCleaner.isValidAVDName("../medium_phone"))
        XCTAssertFalse(AndroidCleaner.isValidAVDName("foo/bar"))
        XCTAssertFalse(AndroidCleaner.isValidAVDName("-n"))
        XCTAssertFalse(AndroidCleaner.isValidAVDName("name with spaces"))

        // 2. Scan with AndroidCleaner: AVD must be REVIEW, never in Recommended Clean, and use .avdManagerDelete
        let cleaner = AndroidCleaner(homeDirectory: tempHome.path)
        let items = await cleaner.scan(snapshot: .empty, ageFilter: .all)
        let avdItem = try XCTUnwrap(items.first { $0.id == "android-avd-medium_phone" })

        XCTAssertEqual(avdItem.riskLevel, .review)
        XCTAssertTrue(avdItem.path.hasSuffix("/.android/avd/medium_phone.avd"))
        XCTAssertEqual(avdItem.actionType, .avdManagerDelete(avdName: "medium_phone", avdPath: avdItem.path))
        XCTAssertEqual(avdItem.exactCommandOrPathDescription, "avdmanager delete avd -n medium_phone")
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(avdItem))

        final class AVDTestRecorder: @unchecked Sendable {
            var trashCalled = false
            var executedCommand: [String] = []
        }
        let recorder = AVDTestRecorder()

        // 3. When avdmanager is unavailable, execution is BLOCKED and NEVER deletes .avd directory manually
        let missingToolExecutor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { _ in recorder.trashCalled = true },
            shellRunner: { _, _ in
                XCTFail("shellRunner must not be called when avdmanager is missing")
                return ShellResult(exitCode: 1, stdout: "", stderr: "")
            },
            avdManagerResolver: { nil }
        )

        do {
            _ = try await missingToolExecutor.execute(avdItem)
            XCTFail("Expected CleanerError.commandFailed when avdmanager is unavailable")
        } catch let error as CleanerError {
            guard case .commandFailed(let msg) = error else {
                XCTFail("Expected CleanerError.commandFailed, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("avdmanager"))
        }
        XCTAssertFalse(recorder.trashCalled, "Must never fall back to moving .avd directory to Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: avdFile.path), "AVD userdata image must remain untouched when avdmanager is unavailable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iniFile.path))

        // 4. When emulator process is active immediately before deletion, execution is BLOCKED
        let activeProcessExecutor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { cat in cat == .android ? ["qemu-system-aarch64"] : [] },
            trashHandler: { _ in recorder.trashCalled = true },
            shellRunner: { _, _ in
                XCTFail("shellRunner must not be called when emulator is running")
                return ShellResult(exitCode: 1, stdout: "", stderr: "")
            },
            avdManagerResolver: { "/mock/sdk/cmdline-tools/latest/bin/avdmanager" }
        )
        do {
            _ = try await activeProcessExecutor.execute(avdItem)
            XCTFail("Expected runningProcessActive when emulator process is active")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .runningProcessActive(appName: "qemu-system-aarch64", categoryName: "Android"))
        }

        // 5. When live hardware-qemu.ini.lock has an active PID (current test process PID), execution is BLOCKED
        let lockFile = try writeFile(".android/avd/medium_phone.avd/hardware-qemu.ini.lock", textContent: "\(getpid())\n")
        let lockExecutor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { _ in recorder.trashCalled = true },
            shellRunner: { _, _ in
                XCTFail("shellRunner must not be called when AVD lock PID is alive")
                return ShellResult(exitCode: 1, stdout: "", stderr: "")
            },
            avdManagerResolver: { "/mock/sdk/cmdline-tools/latest/bin/avdmanager" }
        )
        do {
            _ = try await lockExecutor.execute(avdItem)
            XCTFail("Expected runningProcessActive when lock PID is active")
        } catch let error as CleanerError {
            guard case .runningProcessActive(let appName, _) = error else {
                XCTFail("Expected runningProcessActive, got \(error)")
                return
            }
            XCTAssertTrue(appName.contains("PID"))
        }
        try FileManager.default.removeItem(at: lockFile)

        // 6. When avdmanager is available and AVD is inactive, executes `avdmanager delete avd -n medium_phone`
        let mockAVDManagerPath = "/mock/sdk/cmdline-tools/latest/bin/avdmanager"
        let validExecutor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { _ in recorder.trashCalled = true },
            shellRunner: { exe, args in
                recorder.executedCommand = [exe] + args
                return ShellResult(exitCode: 0, stdout: "AVD 'medium_phone' deleted.", stderr: "")
            },
            avdManagerResolver: { mockAVDManagerPath }
        )
        let result = try await validExecutor.execute(avdItem)
        XCTAssertEqual(result.status, .cleaned)
        XCTAssertEqual(result.action, .avdManagerDelete)
        XCTAssertEqual(recorder.executedCommand, [mockAVDManagerPath, "delete", "avd", "-n", "medium_phone"])
        XCTAssertFalse(recorder.trashCalled)
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
