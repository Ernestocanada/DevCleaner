import XCTest
@testable import DevCleaner

final class CleanupHardeningTests: XCTestCase {
    private var tempHome: URL!
    private var tempTrash: URL!
    private var validator: SafetyValidator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DevCleanerTests-\(UUID().uuidString)", isDirectory: true)
        tempHome = base.appendingPathComponent("Home", isDirectory: true)
        tempTrash = base.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempTrash, withIntermediateDirectories: true)
        validator = SafetyValidator(homeDirectory: tempHome.path)
    }

    override func tearDownWithError() throws {
        if let root = tempHome?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helper to create test files

    private func createFile(relativeToHome relPath: String, sizeBytes: Int = 4096, modifiedDaysAgo: Double = 0) throws -> URL {
        let url = tempHome.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0xAB, count: sizeBytes)
        try data.write(to: url)
        if modifiedDaysAgo > 0 {
            let pastDate = Date().addingTimeInterval(-modifiedDaysAgo * 86400)
            try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        return url
    }

    private func makeIsolatedExecutor(
        simulatedFreeBefore: Int64 = 100_000_000_000,
        simulatedFreeAfter: Int64 = 100_000_000_000,
        activeProcesses: [CleanerCategory: [String]] = [:],
        shellRunner: (@Sendable (String, [String]) async -> ShellResult)? = nil,
        npmCapabilitiesProvider: (@Sendable () async -> NpmCapabilities)? = nil,
        npmLiveUseChecker: (@Sendable (String) async -> NpmLiveUseState)? = nil
    ) -> CleanupExecutor {
        let trashDir = self.tempTrash!
        let counter = LockCounter()
        return CleanupExecutor(
            validator: validator,
            freeSpaceProvider: {
                counter.next() == 0 ? simulatedFreeBefore : simulatedFreeAfter
            },
            processChecker: { category in
                activeProcesses[category] ?? []
            },
            trashHandler: { url in
                let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
            },
            shellRunner: shellRunner ?? { _, _ in
                ShellResult(exitCode: 1, stdout: "", stderr: "Unmocked shell command blocked in isolated unit test")
            },
            npmCapabilitiesProvider: npmCapabilitiesProvider,
            npmLiveUseChecker: npmLiveUseChecker
        )
    }

    // MARK: - 1. CleanupExecutor Tests

    func testAllowListedTemporaryCacheContentCanBeCleaned() async throws {
        let fileURL = try createFile(relativeToHome: "Library/Developer/Xcode/DerivedData/SampleApp-abc/Build/out.o", sizeBytes: 16384)
        let derivedDataDir = tempHome.appendingPathComponent("Library/Developer/Xcode/DerivedData").path

        let item = CleanableItem(
            id: "test-derived-data",
            name: "Xcode DerivedData",
            category: .xcode,
            path: derivedDataDir,
            logicalSize: 16384,
            physicalSize: 16384,
            reclaimableSize: 16384,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "Test DerivedData",
            deletionConsequence: "Moves to Trash",
            regenerationImpact: "Rebuilt",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: derivedDataDir, minAgeDays: nil)
        )

        let executor = makeIsolatedExecutor()
        let result = try await executor.execute(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Cache content should have been moved to simulated Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivedDataDir), "Root DerivedData folder itself should remain")
        XCTAssertGreaterThan(result.processedBytes, 0)
        XCTAssertEqual(result.processedBytes, result.movedToTrashBytes)
        XCTAssertEqual(result.action, .moveToTrash)
    }

    func testProtectedPathIsRejectedByExecutor() async throws {
        let projectFile = try createFile(relativeToHome: "Developer/MyApp/main.swift", sizeBytes: 1024)
        let projectDir = tempHome.appendingPathComponent("Developer/MyApp").path

        let forbiddenItem = CleanableItem(
            id: "bad-developer-item",
            name: "Forbidden Project",
            category: .generalCaches,
            path: projectDir,
            logicalSize: 1024,
            physicalSize: 1024,
            reclaimableSize: 1024,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrash(path: projectDir)
        )

        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(forbiddenItem)
            XCTFail("Expected SafetyError.forbiddenProtectedPath")
        } catch let error as SafetyError {
            guard case .forbiddenProtectedPath = error else {
                XCTFail("Unexpected SafetyError case: \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFile.path), "Protected source file must remain untouched")
    }

    func testParentTraversalIsRejectedByExecutor() async throws {
        let traversalPath = "\(tempHome.path)/Library/Developer/Xcode/DerivedData/../../../../Developer"
        let item = CleanableItem(
            id: "traversal-item",
            name: "Traversal Attempt",
            category: .xcode,
            path: traversalPath,
            logicalSize: 1024,
            physicalSize: 1024,
            reclaimableSize: 1024,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrash(path: traversalPath)
        )

        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(item)
            XCTFail("Expected SafetyError.containsParentTraversal")
        } catch let error as SafetyError {
            XCTAssertEqual(error, .containsParentTraversal(traversalPath))
        }
    }

    func testSymlinkEscapeIsRejectedByExecutor() async throws {
        let secretFile = try createFile(relativeToHome: "Documents/SecretNotes.txt", sizeBytes: 2048)
        let allowedCacheDir = tempHome.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedCacheDir, withIntermediateDirectories: true)

        let symlinkURL = allowedCacheDir.appendingPathComponent("escaped-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: secretFile.deletingLastPathComponent())

        let item = CleanableItem(
            id: "symlink-escape-item",
            name: "Homebrew Cache with Symlink Escape",
            category: .homebrew,
            path: allowedCacheDir.path,
            logicalSize: 2048,
            physicalSize: 2048,
            reclaimableSize: 2048,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: allowedCacheDir.path, minAgeDays: nil)
        )

        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(item)
            XCTFail("Expected symlinkTraversalRejected")
        } catch let error as SafetyError {
            guard case .symlinkTraversalRejected = error else {
                XCTFail("Expected symlinkTraversalRejected, got \(error)")
                return
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path), "Secret document outside allow-list must remain intact")
    }

    func testNeverDeleteCannotExecute() async throws {
        let cacheFile = try createFile(relativeToHome: "Library/Caches/Homebrew/bottle.tar.gz", sizeBytes: 4096)
        let neverDeleteItem = CleanableItem(
            id: "never-delete-test",
            name: "Protected SDK",
            category: .homebrew,
            path: cacheFile.path,
            logicalSize: 4096,
            physicalSize: 4096,
            reclaimableSize: 4096,
            lastModified: Date(),
            riskLevel: .neverDelete,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrash(path: cacheFile.path)
        )

        XCTAssertFalse(neverDeleteItem.canBeSelected)
        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(neverDeleteItem)
            XCTFail("Expected CleanerError.neverDeleteItem")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .neverDeleteItem("Protected SDK"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testRunningDependencyBlocksCleanupImmediatelyBeforeExecution() async throws {
        let claudeSimFile = try createFile(relativeToHome: "Library/Application Support/Claude/simulator-builds/build1/app.bin", sizeBytes: 8192)
        let simBuildsDir = tempHome.appendingPathComponent("Library/Application Support/Claude/simulator-builds").path

        // Simulate scenario: when scanned, isRunningDependency was false, but right before Clean is clicked, Claude was launched!
        let itemScannedWhileClosed = CleanableItem(
            id: "claude-sim-builds",
            name: "Claude Simulator Builds",
            category: .claude,
            path: simBuildsDir,
            logicalSize: 8192,
            physicalSize: 8192,
            reclaimableSize: 8192,
            lastModified: Date(),
            riskLevel: .review,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: simBuildsDir, minAgeDays: nil)
        )

        let executorWithLiveClaude = makeIsolatedExecutor(activeProcesses: [.claude: ["Claude"]])
        do {
            _ = try await executorWithLiveClaude.execute(itemScannedWhileClosed)
            XCTFail("Expected runningProcessActive when Claude opens after scan")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .runningProcessActive(appName: "Claude", categoryName: "Claude"))
            XCTAssertEqual(error.localizedDescription, "Cleanup blocked: Close Claude before cleaning Claude runtime data.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeSimFile.path), "File must not be deleted when Claude is running")
    }

    func testAgeFilteringPreservesRecentFilesAndCleansOldFiles() async throws {
        let oldFile = try createFile(relativeToHome: ".gradle/caches/old-module/jar1.jar", sizeBytes: 8192, modifiedDaysAgo: 15)
        let recentFile = try createFile(relativeToHome: ".gradle/caches/recent-module/jar2.jar", sizeBytes: 8192, modifiedDaysAgo: 2)
        let gradleCachesDir = tempHome.appendingPathComponent(".gradle/caches").path

        let item = CleanableItem(
            id: "gradle-caches",
            name: "Gradle Caches",
            category: .gradle,
            path: gradleCachesDir,
            logicalSize: 16384,
            physicalSize: 16384,
            reclaimableSize: 8192,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: gradleCachesDir, minAgeDays: nil),
            supportsAgeFilter: true
        )

        let executor = makeIsolatedExecutor()
        // Execute with 7-day filter
        let result = try await executor.execute(item, ageFilter: .sevenDays)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path), "15-day-old cache entry should be cleaned with 7-day filter")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path), "2-day-old cache entry must be preserved with 7-day filter")
        XCTAssertGreaterThan(result.movedToTrashBytes, 0)
    }

    func testHiddenProtectedFilesCannotAccidentallyBeRemoved() async throws {
        let normalCache = try createFile(relativeToHome: ".npm/_cacache/content-v2/blob1", sizeBytes: 4096)
        let hiddenEnv = try createFile(relativeToHome: ".npm/_cacache/.env", sizeBytes: 256)
        let hiddenGit = try createFile(relativeToHome: ".npm/_cacache/sub/.git/config", sizeBytes: 256)
        let cacacheDir = tempHome.appendingPathComponent(".npm/_cacache").path

        let item = CleanableItem(
            id: "npm-cacache",
            name: "npm Cache",
            category: .nodeNpm,
            path: cacacheDir,
            logicalSize: 4608,
            physicalSize: 4608,
            reclaimableSize: 4608,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: cacacheDir, minAgeDays: nil)
        )

        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(item)
            XCTFail("Expected SafetyError.forbiddenFileOrComponent when hidden .env or .git is inside directory")
        } catch let error as SafetyError {
            guard case .forbiddenFileOrComponent = error else {
                XCTFail("Expected forbiddenFileOrComponent, got \(error)")
                return
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenEnv.path), "Hidden .env must never be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenGit.path), "Hidden .git must never be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: normalCache.path), "Pre-flight check must abort before removing sibling files")
    }

    // MARK: - 2. Trash Semantics Tests

    func testTrashSemanticsSeparatesMovedToTrashFromActuallyFreed() async throws {
        _ = try createFile(relativeToHome: "Library/Caches/CocoaPods/Pods/Spec1.json", sizeBytes: 32768)
        let cocoapodsDir = tempHome.appendingPathComponent("Library/Caches/CocoaPods").path
        let measured = DiskScanner.shared.measurePath(cocoapodsDir)

        let item = CleanableItem(
            id: "cocoapods-cache",
            name: "CocoaPods Cache",
            category: .cocoapodsSwiftPM,
            path: cocoapodsDir,
            logicalSize: measured.logicalSize,
            physicalSize: measured.physicalSize,
            reclaimableSize: measured.physicalSize,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: cocoapodsDir, minAgeDays: nil)
        )

        // When moving to Trash on the same volume, macOS free disk space does not increase until Trash is emptied
        let executor = makeIsolatedExecutor(
            simulatedFreeBefore: 112_000_000_000,
            simulatedFreeAfter: 112_000_000_000
        )

        let result = try await executor.execute(item)
        XCTAssertEqual(result.processedBytes, measured.physicalSize)
        XCTAssertEqual(result.movedToTrashBytes, measured.physicalSize)
        XCTAssertEqual(result.actuallyFreedBytes, 0, "actuallyFreedBytes must never be fabricated when items are only moved to Trash")
        XCTAssertEqual(result.action, .moveToTrash)
    }

    // MARK: - 3. Simulator Tests (Fixture JSON)

    func testSimulatorFixtureParsingAndSafetyRules() async throws {
        let fixtureDevicesJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "83050079-F7C5-4F34-AD3A-E6CBF1130330",
                "name": "iPhone 18 Pro",
                "state": "Booted",
                "isAvailable": true,
                "dataPath": "/Users/ernesto/Library/Developer/CoreSimulator/Devices/83050079-F7C5-4F34-AD3A-E6CBF1130330/data",
                "dataPathSize": 5192871936,
                "logPathSize": 544768,
                "lastUsedAt": "2026-10-18T09:21:24Z"
              },
              {
                "udid": "54416380-36B7-4121-B0F2-3698F1D387B9",
                "name": "MoveTimer QA",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPath": "/Users/ernesto/Library/Developer/CoreSimulator/Devices/54416380-36B7-4121-B0F2-3698F1D387B9/data",
                "dataPathSize": 4096913408,
                "logPathSize": 516096,
                "lastUsedAt": "2026-10-17T10:14:46Z"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-25-0": [
              {
                "udid": "11111111-2222-3333-4444-555555555555",
                "name": "Orphaned iPhone",
                "state": "Shutdown",
                "isAvailable": false,
                "dataPathSize": 250000000,
                "logPathSize": 0
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let items = try SimulatorCleaner.parseDevicesJSON(fixtureDevicesJSON, homeDirectory: tempHome.path)

        // 1. Booted simulator => cannot clean, ACTIVE — protected
        let booted = try XCTUnwrap(items.first { $0.id.contains("83050079-F7C5-4F34-AD3A-E6CBF1130330") })
        XCTAssertTrue(booted.isRunningDependency)
        XCTAssertFalse(booted.canBeSelected)
        XCTAssertEqual(booted.reclaimableSize, 0)
        XCTAssertEqual(booted.simulatorMetadata?.displayBadgeText, "ACTIVE — protected")
        XCTAssertTrue(booted.explanation.contains("Deleting a simulator removes its apps and simulator-local data but does not remove your source code."))

        // 2. Shutdown simulator => REVIEW, selectable
        let shutdown = try XCTUnwrap(items.first { $0.id.contains("54416380-36B7-4121-B0F2-3698F1D387B9") })
        XCTAssertEqual(shutdown.riskLevel, .review)
        XCTAssertTrue(shutdown.canBeSelected)

        // 3. Unavailable simulator => NEVER automatic SAFE cleanup; enumerated individually as REVIEW
        XCTAssertNil(items.first { $0.id == "sim-delete-unavailable" }, "Blanket simctl delete unavailable item must NOT be exposed")

        let unavailableIndividual = try XCTUnwrap(items.first { $0.id.contains("11111111-2222-3333-4444-555555555555") })
        XCTAssertEqual(unavailableIndividual.riskLevel, .review, "Unavailable simulator must be REVIEW, never SAFE")
        XCTAssertTrue(unavailableIndividual.canBeSelected, "Shutdown unavailable simulator can be explicitly selected")
        XCTAssertEqual(unavailableIndividual.actionType, .simctlDeleteDevice(udid: "11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(
            CleanerViewModel.isEligibleForRecommendedSafeCleanup(unavailableIndividual),
            "Unavailable simulator must NEVER be included in automatic Recommended SAFE cleanup"
        )

        // 4. Runtimes mounted volumes => NEVER DELETE
        let runtimesMounted = try XCTUnwrap(items.first { $0.id == "sim-runtimes-preserved" })
        XCTAssertEqual(runtimesMounted.riskLevel, .neverDelete)
        XCTAssertFalse(runtimesMounted.canBeSelected)

        // 5. Malformed UDID => rejected by CleanupExecutor
        let malformedItem = CleanableItem(
            id: "bad-udid",
            name: "Malformed Sim",
            category: .iosSimulators,
            path: "",
            logicalSize: 100,
            physicalSize: 100,
            reclaimableSize: 100,
            lastModified: nil,
            riskLevel: .review,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .simctlDeleteDevice(udid: "../../not-a-uuid")
        )
        let executor = makeIsolatedExecutor()
        do {
            _ = try await executor.execute(malformedItem)
            XCTFail("Expected commandFailed for malformed UDID")
        } catch let error as CleanerError {
            guard case .commandFailed = error else {
                XCTFail("Expected commandFailed, got \(error)")
                return
            }
        }
    }

    func testSimulatorRuntimesPreservationAndCoreDeviceProtection() throws {
        let fixtureRuntimesJSON = """
        {
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
              "name": "iOS 26.3",
              "version": "26.3.1",
              "buildversion": "23D8133",
              "isAvailable": true
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
              "name": "iOS 27.0",
              "version": "27.0",
              "buildversion": "24A434",
              "isAvailable": true
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
              "name": "iOS 18.0",
              "version": "18.0",
              "buildversion": "22A3351",
              "isAvailable": true
            }
          ]
        }
        """.data(using: .utf8)!

        let runtimes = try SimulatorCleaner.parseRuntimesJSON(fixtureRuntimesJSON)
        let ios26_3 = try XCTUnwrap(runtimes.first { $0.name == "iOS 26.3" })
        let ios27_0 = try XCTUnwrap(runtimes.first { $0.name == "iOS 27.0" })
        let ios18_0 = try XCTUnwrap(runtimes.first { $0.name == "iOS 18.0" })

        XCTAssertTrue(ios26_3.isPreservedByDefault, "iOS 26.3 must be preserved by default")
        XCTAssertTrue(ios27_0.isPreservedByDefault, "iOS 27.0 must be preserved by default")
        XCTAssertFalse(ios18_0.isPreservedByDefault)

        // CoreDevice/DeviceFS and runtime mounted volumes must never be allowed in SafetyValidator
        XCTAssertFalse(validator.isSafeToDelete("\(tempHome.path)/Library/Developer/CoreDevice/DeviceFS", checkSymlinksOnDisk: false))
        XCTAssertFalse(validator.isSafeToDelete("/Library/Developer/CoreSimulator/Volumes/iOS_23D8133", checkSymlinksOnDisk: false))
    }

    // MARK: - 4. Docker Tests

    func testDockerRawProtectionSparseSizesAndDaemonState() async throws {
        let sparseUsage = DiskUsageInfo(
            logicalSize: 494_384_709_632, // ~494 GB logical
            physicalSize: 11_420_000_000, // ~11.4 GB physical
            lastModified: Date(),
            fileCount: 1
        )

        // When Docker is stopped (unavailable)
        let stoppedCleaner = DockerCleaner(
            homeDirectory: tempHome.path,
            executor: makeIsolatedExecutor(),
            daemonRunningOverride: false,
            diskUsageOverride: sparseUsage
        )
        let stoppedItems = await stoppedCleaner.scan(snapshot: .empty, ageFilter: .all)

        let rawItem = try XCTUnwrap(stoppedItems.first { $0.id == "docker-raw-disk" })
        XCTAssertEqual(rawItem.riskLevel, .neverDelete)
        XCTAssertFalse(rawItem.canBeSelected)
        XCTAssertEqual(rawItem.logicalSize, 494_384_709_632)
        XCTAssertEqual(rawItem.physicalSize, 11_420_000_000)
        XCTAssertTrue(rawItem.hasSparseDifference, "Sparse physical size and logical size must stay separate and flagged")

        // Prune actions must be disabled when Docker daemon is unavailable
        let pruneItemsWhenStopped = stoppedItems.filter { $0.id != "docker-raw-disk" }
        XCTAssertFalse(pruneItemsWhenStopped.isEmpty)
        for pruneItem in pruneItemsWhenStopped {
            XCTAssertFalse(pruneItem.canBeSelected, "Prune button must be disabled when Docker is not running: \(pruneItem.name)")
        }

        // Volume prune must remain CAUTION
        let volumePrune = try XCTUnwrap(stoppedItems.first { $0.id == "docker-prune-volumes" })
        XCTAssertEqual(volumePrune.riskLevel, .caution)

        // Direct deletion of Docker.raw must fail both SafetyValidator and CleanupExecutor
        let executor = makeIsolatedExecutor()
        XCTAssertFalse(validator.isSafeToDelete(rawItem.path, checkSymlinksOnDisk: false))
        do {
            _ = try await executor.execute(rawItem)
            XCTFail("Docker.raw must never be executable in CleanupExecutor")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .neverDeleteItem(rawItem.name))
        }
    }

    // MARK: - 5. Claude & Codex Tests

    func testClaudeAndCodexClassificationsAndRunningProtection() async throws {
        // Populate temporary Claude & Codex directories
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/Cache/data_0", sizeBytes: 4096)
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/Code Cache/js_0", sizeBytes: 4096)
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/GPUCache/gpu_0", sizeBytes: 4096)
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/simulator-builds/sim1/app", sizeBytes: 8192)
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img", sizeBytes: 16384)
        _ = try createFile(relativeToHome: "Library/Application Support/Claude/config.json", sizeBytes: 512)

        _ = try createFile(relativeToHome: ".cache/codex-runtimes/codex-primary-runtime/bin", sizeBytes: 8192)
        _ = try createFile(relativeToHome: "Library/Caches/Codex/Default/cache_0", sizeBytes: 4096)
        _ = try createFile(relativeToHome: "Library/Application Support/Codex/Cache/c_0", sizeBytes: 4096)
        _ = try createFile(relativeToHome: "Library/Application Support/Codex/artifact-sessions/s1", sizeBytes: 512)

        let claudeCleaner = AIToolsCleaner(category: .claude, homeDirectory: tempHome.path, executor: makeIsolatedExecutor())
        let codexCleaner = AIToolsCleaner(category: .codex, homeDirectory: tempHome.path, executor: makeIsolatedExecutor())

        // 1. Scan when Claude & Codex are NOT running
        let claudeIdleItems = await claudeCleaner.scan(snapshot: .empty, ageFilter: .all)
        let claudeCache = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-cache" })
        let claudeCodeCache = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-code-cache" })
        let claudeGPUCache = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-gpu-cache" })
        let claudeSimBuilds = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-simulator-builds" })
        let claudeVMBundles = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-vm-bundles" })
        let claudeSessions = try XCTUnwrap(claudeIdleItems.first { $0.id == "claude-sessions-config-keep" })

        XCTAssertEqual(claudeCache.riskLevel, .safe)
        XCTAssertEqual(claudeCodeCache.riskLevel, .safe)
        XCTAssertEqual(claudeGPUCache.riskLevel, .safe)
        XCTAssertEqual(claudeSimBuilds.riskLevel, .review)
        XCTAssertEqual(claudeVMBundles.riskLevel, .review)
        XCTAssertEqual(claudeVMBundles.reclaimableSize, 0, "Claude VM bundle actionable reclaim must be 0")
        XCTAssertGreaterThan(claudeVMBundles.physicalSize, 0, "Claude VM bundle occupied storage must be reported separately")
        XCTAssertFalse(claudeVMBundles.canBeSelected, "Claude VM bundle must be inventory-only and not selectable")
        XCTAssertFalse(
            CleanerViewModel.isEligibleForRecommendedSafeCleanup(claudeVMBundles),
            "Claude VM bundle must never be included in automatic SAFE cleanup"
        )
        if case .readOnlyInfo(let reason) = claudeVMBundles.actionType {
            XCTAssertTrue(reason.contains("sessiondata.img"))
        } else {
            XCTFail("Expected claudeVMBundles actionType to be .readOnlyInfo, got \(claudeVMBundles.actionType)")
        }
        XCTAssertTrue(claudeVMBundles.explanation.contains("Occupied:"))
        XCTAssertTrue(claudeVMBundles.explanation.contains("SAFE Reclaimable: 0 B"))
        XCTAssertTrue(claudeVMBundles.explanation.contains("sessiondata.img"))
        let vmExecutor = makeIsolatedExecutor()
        do {
            _ = try await vmExecutor.execute(claudeVMBundles)
            XCTFail("Claude VM bundle must be rejected by CleanupExecutor as read-only inventory")
        } catch let error as CleanerError {
            guard case .readOnlyItem = error else {
                XCTFail("Expected readOnlyItem for Claude VM bundle, got \(error)")
                return
            }
        }
        XCTAssertEqual(claudeSessions.riskLevel, .neverDelete)
        XCTAssertFalse(claudeSessions.canBeSelected)
        XCTAssertTrue(claudeSimBuilds.explanation.contains("These files can be regenerated, but Claude may need to rebuild or download them again."))

        // 2. Scan when Claude is running => all Claude items blocked from selection/cleanup
        let claudeRunningSnapshot = ActiveProcessSnapshot(activeLines: ["/Applications/Claude.app/Contents/MacOS/Claude"], runningAppNames: ["Claude"])
        let claudeActiveItems = await claudeCleaner.scan(snapshot: claudeRunningSnapshot, ageFilter: .all)
        for item in claudeActiveItems {
            XCTAssertFalse(item.canBeSelected, "Claude item \(item.name) must be blocked while Claude is running")
        }

        // 3. Verify Codex classifications
        let codexIdleItems = await codexCleaner.scan(snapshot: .empty, ageFilter: .all)
        let codexRuntimes = try XCTUnwrap(codexIdleItems.first { $0.id == "codex-runtimes-cache" })
        let codexSysCache = try XCTUnwrap(codexIdleItems.first { $0.id == "codex-library-cache" })
        let codexAppCache = try XCTUnwrap(codexIdleItems.first { $0.id == "codex-appsupport-cache" })
        let codexSessions = try XCTUnwrap(codexIdleItems.first { $0.id == "codex-sessions-keep" })

        XCTAssertEqual(codexRuntimes.riskLevel, .review)
        XCTAssertEqual(codexSysCache.riskLevel, .safe)
        XCTAssertEqual(codexAppCache.riskLevel, .safe)
        XCTAssertEqual(codexSessions.riskLevel, .neverDelete)
        XCTAssertFalse(codexSessions.canBeSelected)
    }

    // MARK: - 6. Regression Tests: Firebase Package Metadata vs Real Credentials in Subtree Scan

    func testExecutorCleansNpxAndGradleFirebasePackageMetadata() async throws {
        let npxSchemaFile = try createFile(
            relativeToHome: ".npm/_npx/8843fba6d2859245/node_modules/firebase-tools/schema/firebase-config.json",
            sizeBytes: 4096
        )
        let gradleEncoderFile = try createFile(
            relativeToHome: ".gradle/caches/9.3.1/transforms/07298d8900aeb663b234fa79a0c1cdfa/transformed/com.google.firebase.encoders.json",
            sizeBytes: 4096
        )

        let npxDir = tempHome.appendingPathComponent(".npm/_npx").path
        let gradleDir = tempHome.appendingPathComponent(".gradle/caches").path

        let npxItem = CleanableItem(
            id: "npm-npx",
            name: "npm _npx Temporary Packages",
            category: .nodeNpm,
            path: npxDir,
            logicalSize: 4096,
            physicalSize: 4096,
            reclaimableSize: 4096,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: npxDir, minAgeDays: nil)
        )

        let gradleItem = CleanableItem(
            id: "gradle-caches",
            name: "Gradle Build & Artifact Caches",
            category: .gradle,
            path: gradleDir,
            logicalSize: 4096,
            physicalSize: 4096,
            reclaimableSize: 4096,
            lastModified: Date(),
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashContents(directoryPath: gradleDir, minAgeDays: nil)
        )

        let executor = makeIsolatedExecutor()
        let npxResult = try await executor.execute(npxItem)
        let gradleResult = try await executor.execute(gradleItem)

        XCTAssertFalse(FileManager.default.fileExists(atPath: npxSchemaFile.path), "firebase-config.json schema in _npx must be cleaned without false positive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gradleEncoderFile.path), "com.google.firebase.encoders.json in Gradle cache must be cleaned without false positive")
        XCTAssertGreaterThan(npxResult.movedToTrashBytes, 0)
        XCTAssertGreaterThan(gradleResult.movedToTrashBytes, 0)
    }

    func testExecutorBlocksSubtreeWithExplicitCredentialFiles() async throws {
        let blockedFileNames = [
            "GoogleService-Info.plist",
            "google-services.json",
            "firebase-adminsdk-abc123.json",
            "application_default_credentials.json",
            "service-account.json",
            "credentials.json",
            "client_secret_123.json",
            ".env"
        ]

        let executor = makeIsolatedExecutor()

        for (index, fileName) in blockedFileNames.enumerated() {
            let subDirRel = ".npm/_npx/test-cred-\(index)"
            let credFileURL = try createFile(relativeToHome: "\(subDirRel)/nested/\(fileName)", sizeBytes: 512)
            let npxDir = tempHome.appendingPathComponent(".npm/_npx").path

            let item = CleanableItem(
                id: "npm-npx-\(index)",
                name: "npm _npx",
                category: .nodeNpm,
                path: npxDir,
                logicalSize: 512,
                physicalSize: 512,
                reclaimableSize: 512,
                lastModified: Date(),
                riskLevel: .safe,
                explanation: "",
                deletionConsequence: "",
                regenerationImpact: "",
                isRunningDependency: false,
                actionType: .moveToTrashContents(directoryPath: npxDir, minAgeDays: nil)
            )

            do {
                _ = try await executor.execute(item)
                XCTFail("Expected SafetyError.forbiddenFileOrComponent for \(fileName)")
            } catch let error as SafetyError {
                guard case .forbiddenFileOrComponent = error else {
                    XCTFail("Expected forbiddenFileOrComponent for \(fileName), got \(error)")
                    return
                }
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: credFileURL.path), "Credential file \(fileName) must remain untouched")
            try FileManager.default.removeItem(at: tempHome.appendingPathComponent(subDirRel))
        }
    }

    // MARK: - 7. v1.2 Regression Tests: Plan Alignment, Partial Cache Cleaning, Age-Filter Accuracy, No-Op & Free-Space Semantics

    func testAgeFilterEstimateMatchesExecutableBytesExactly() async throws {
        // Create a large recent cache child (~4.8 MB) modified 1 day ago, and a small old child (~200 KB) modified 10 days ago
        let recentChild = try createFile(
            relativeToHome: ".gradle/caches/modules-recent/big-recent.bin",
            sizeBytes: 4_800_000,
            modifiedDaysAgo: 1
        )
        let oldChild = try createFile(
            relativeToHome: ".gradle/caches/modules-old/small-old.bin",
            sizeBytes: 204_800,
            modifiedDaysAgo: 10
        )

        let executor = makeIsolatedExecutor()
        let gradleCleaner = StandardCacheCleaner(category: .gradle, homeDirectory: tempHome.path, executor: executor)

        // Scan with 7-day filter
        let scannedItems = await gradleCleaner.scan(snapshot: .empty, ageFilter: .sevenDays)
        let gradleItem = try XCTUnwrap(scannedItems.first { $0.id == "gradle-caches" })

        // Total physical size is ~5 MB, but reclaimableSize (Preview estimate) must be ~200 KB (the exact old child), NOT 5 MB
        XCTAssertGreaterThanOrEqual(gradleItem.physicalSize, 5_000_000)
        XCTAssertLessThan(gradleItem.reclaimableSize, 300_000, "Preview estimate must not show the full 5 MB directory when only ~200 KB is older than 7 days")
        XCTAssertGreaterThanOrEqual(gradleItem.reclaimableSize, 204_800)

        // Plan eligibleBytes must equal item.reclaimableSize AND executor processedBytes
        let plannedEligibleBytes = try XCTUnwrap(gradleItem.plan?.eligibleBytes)
        XCTAssertEqual(gradleItem.reclaimableSize, plannedEligibleBytes)

        let execResult = try await executor.execute(gradleItem, ageFilter: .sevenDays)
        XCTAssertEqual(execResult.processedBytes, gradleItem.reclaimableSize, "Executor processedBytes must exactly match Preview reclaimableSize")
        XCTAssertEqual(execResult.movedToTrashBytes, plannedEligibleBytes)
        XCTAssertEqual(execResult.status, .cleaned)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldChild.path), "Old child must be cleaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentChild.path), "Recent child must be preserved")
    }

    func testProtectedChildInDisposableCacheIsIsolatedAndSiblingsAreCleaned() async throws {
        // cache-A: SAFE
        let fileA = try createFile(
            relativeToHome: ".gradle/caches/cache-A/modules/pkgA.jar",
            sizeBytes: 16384
        )
        // cache-B: contains .env inside nested subtree
        let fileBEnv = try createFile(
            relativeToHome: ".gradle/caches/cache-B/transforms/bottleneck/.env",
            sizeBytes: 37
        )
        // cache-C: SAFE
        let fileC = try createFile(
            relativeToHome: ".gradle/caches/cache-C/modules/pkgC.jar",
            sizeBytes: 16384
        )

        // Verify .env inside cache remains strictly blocked by SafetyValidator
        XCTAssertFalse(validator.isSafeToDelete(fileBEnv.path, checkSymlinksOnDisk: false), ".env must remain strictly protected even inside caches")

        let executor = makeIsolatedExecutor()
        let gradleCleaner = StandardCacheCleaner(category: .gradle, homeDirectory: tempHome.path, executor: executor)
        let scannedItems = await gradleCleaner.scan(snapshot: .empty, ageFilter: .all)

        // Expect:
        // 1) Main SAFE item for gradle-caches containing eligible entries cache-A and cache-C only
        let safeCacheItem = try XCTUnwrap(scannedItems.first { $0.id == "gradle-caches" })
        XCTAssertEqual(safeCacheItem.riskLevel, .safe)
        XCTAssertTrue(safeCacheItem.canBeSelected)
        let eligibleNames = Set(safeCacheItem.plan?.eligibleEntries.map { $0.name } ?? [])
        XCTAssertEqual(eligibleNames, Set(["cache-A", "cache-C"]), "Recommended SAFE item must include cache-A and cache-C only")

        // 2) Isolated REVIEW item for cache-B (contains .env), not selectable by Recommended Cleanup
        let reviewChildItem = try XCTUnwrap(scannedItems.first { $0.id == "gradle-caches-review-cache-B" })
        XCTAssertEqual(reviewChildItem.riskLevel, .review)
        XCTAssertFalse(reviewChildItem.canBeSelected, "Protected child cache-B must not be selectable by Recommended Cleanup")
        XCTAssertTrue(reviewChildItem.explanation.contains("Contains protected-looking environment file"))

        // 3) Executing the SAFE item cleans cache-A and cache-C while preserving cache-B
        let result = try await executor.execute(safeCacheItem, ageFilter: .all)
        XCTAssertEqual(result.status, .cleaned)
        XCTAssertEqual(result.processedBytes, safeCacheItem.reclaimableSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path), "cache-A must be cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileC.path), "cache-C must be cleaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileBEnv.path), "cache-B containing .env must be preserved untouched")
    }

    func testNoOpCleanupWhenNothingEligibleReportsNothingEligibleStatus() async throws {
        // Only recent file (1 day old) exists, and we run with 7-day filter
        let recentFile = try createFile(
            relativeToHome: "Library/Caches/Homebrew/downloads/recent-bottle.tar.gz",
            sizeBytes: 8192,
            modifiedDaysAgo: 1
        )

        let executor = makeIsolatedExecutor()
        let brewCleaner = StandardCacheCleaner(category: .homebrew, homeDirectory: tempHome.path, executor: executor)
        let scannedItems = await brewCleaner.scan(snapshot: .empty, ageFilter: .sevenDays)
        let brewItem = try XCTUnwrap(scannedItems.first { $0.id == "homebrew-cache" })

        XCTAssertEqual(brewItem.reclaimableSize, 0)
        XCTAssertFalse(brewItem.canBeSelected, "0-byte eligible item must not be selectable")

        let result = try await executor.execute(brewItem, ageFilter: .sevenDays)
        XCTAssertEqual(result.status, .nothingEligible, "Zero-byte cleanup must report .nothingEligible, not .cleaned")
        XCTAssertEqual(result.processedBytes, 0)
        XCTAssertEqual(result.movedToTrashBytes, 0)
        XCTAssertTrue(result.message?.contains("Nothing eligible for cleanup") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
    }

    func testTrashOperationNeverFabricatesPerItemFreedSpaceFromAPFSFluctuations() async throws {
        _ = try createFile(relativeToHome: "Library/Caches/pip/wheels/pkg.whl", sizeBytes: 4096)

        // Simulate background APFS free-space fluctuation of +1.4 MB during a 4 KB moveToTrash operation
        let executor = makeIsolatedExecutor(
            simulatedFreeBefore: 100_000_000_000,
            simulatedFreeAfter: 100_001_400_000
        )
        let pipCleaner = StandardCacheCleaner(category: .generalCaches, homeDirectory: tempHome.path, executor: executor)
        let items = await pipCleaner.scan(snapshot: .empty, ageFilter: .all)
        let pipItem = try XCTUnwrap(items.first { $0.id == "pip-cache" })

        let result = try await executor.execute(pipItem, ageFilter: .all)
        XCTAssertEqual(result.status, .cleaned)
        XCTAssertGreaterThan(result.movedToTrashBytes, 0)
        XCTAssertEqual(result.actuallyFreedBytes, 0, "Per-item actuallyFreedBytes for moveToTrash must be 0 and never attribute unrelated APFS fluctuations")
    }

    // MARK: - 7. v1.3 Per-Device Simulator Execution Safety Tests

    func testShutdownSimulatorDeletableWhileAnotherSimulatorIsBooted() async throws {
        let fixtureJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "83050079-F7C5-4F34-AD3A-E6CBF1130330",
                "name": "iPhone 18 Pro",
                "state": "Booted",
                "isAvailable": true,
                "dataPath": "/Users/ernesto/Library/Developer/CoreSimulator/Devices/83050079-F7C5-4F34-AD3A-E6CBF1130330/data",
                "dataPathSize": 5192871936,
                "logPathSize": 544768
              },
              {
                "udid": "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD",
                "name": "iPhone 18 Pro Max",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPath": "/Users/ernesto/Library/Developer/CoreSimulator/Devices/D0DD3D55-733A-4D23-9A25-B310BDB9D0CD/data",
                "dataPathSize": 3339337728,
                "logPathSize": 49152
              }
            ]
          }
        }
        """

        let items = try SimulatorCleaner.parseDevicesJSON(fixtureJSON.data(using: .utf8)!, homeDirectory: tempHome.path)
        let shutdownTarget = try XCTUnwrap(items.first { $0.id == "sim-device-D0DD3D55-733A-4D23-9A25-B310BDB9D0CD" })
        let bootedOther = try XCTUnwrap(items.first { $0.id == "sim-device-83050079-F7C5-4F34-AD3A-E6CBF1130330" })

        XCTAssertEqual(shutdownTarget.riskLevel, .review)
        XCTAssertEqual(shutdownTarget.simulatorMetadata?.displayBadgeText, "SHUTDOWN")
        XCTAssertTrue(shutdownTarget.canBeSelected, "Shutdown simulator must remain selectable/cleanable when another simulator is Booted")
        XCTAssertFalse(bootedOther.canBeSelected, "Booted simulator must remain non-selectable")

        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            simulatedFreeBefore: 100_000_000_000,
            simulatedFreeAfter: 103_339_386_880,
            activeProcesses: [.iosSimulators: ["Simulator"]],
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: fixtureJSON, stderr: "")
                }
                if args == ["simctl", "delete", "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD"] {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Unexpected command: \(args)")
            }
        )

        let result = try await executor.execute(shutdownTarget)
        XCTAssertEqual(result.status, .cleaned)
        XCTAssertEqual(result.action, .simctlDelete)
        XCTAssertEqual(result.processedBytes, shutdownTarget.reclaimableSize)
        XCTAssertEqual(recorder.calls, [
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"],
            ["/usr/bin/xcrun", "simctl", "delete", "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD"]
        ])
    }

    func testBootedSimulatorDeletionIsBlocked() async throws {
        let fixtureJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD",
                "name": "iPhone 18 Pro Max",
                "state": "Booted",
                "isAvailable": true,
                "dataPathSize": 3339337728,
                "logPathSize": 49152
              }
            ]
          }
        }
        """

        let items = try SimulatorCleaner.parseDevicesJSON(fixtureJSON.data(using: .utf8)!, homeDirectory: tempHome.path)
        let bootedTarget = try XCTUnwrap(items.first { $0.id == "sim-device-D0DD3D55-733A-4D23-9A25-B310BDB9D0CD" })
        XCTAssertEqual(bootedTarget.simulatorMetadata?.displayBadgeText, "ACTIVE — protected")
        XCTAssertFalse(bootedTarget.canBeSelected)

        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            activeProcesses: [.iosSimulators: ["Simulator"]],
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: fixtureJSON, stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Should never call simctl delete on Booted device")
            }
        )

        do {
            _ = try await executor.execute(bootedTarget)
            XCTFail("Expected simulatorDeviceActive error for Booted target")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .simulatorDeviceActive(deviceName: "iPhone 18 Pro Max", state: "Booted"))
            XCTAssertEqual(
                error.localizedDescription,
                "Cleanup blocked: iPhone 18 Pro Max is currently active.\nShut down this simulator before deleting it."
            )
        }

        XCTAssertEqual(recorder.calls, [
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]
        ], "simctl delete must never be invoked for a Booted device")
    }

    func testTargetSimulatorChangesFromShutdownToBootedAfterScanIsBlockedByImmediateRecheck() async throws {
        let scanTimeJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD",
                "name": "iPhone 18 Pro Max",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3339337728,
                "logPathSize": 49152
              }
            ]
          }
        }
        """

        // User boots iPhone 18 Pro Max after scanning, before clicking Clean
        let executeTimeJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD",
                "name": "iPhone 18 Pro Max",
                "state": "Booted",
                "isAvailable": true,
                "dataPathSize": 3339337728,
                "logPathSize": 49152
              }
            ]
          }
        }
        """

        let scannedItems = try SimulatorCleaner.parseDevicesJSON(scanTimeJSON.data(using: .utf8)!, homeDirectory: tempHome.path)
        let scannedAsShutdown = try XCTUnwrap(scannedItems.first { $0.id == "sim-device-D0DD3D55-733A-4D23-9A25-B310BDB9D0CD" })
        XCTAssertFalse(scannedAsShutdown.isRunningDependency)
        XCTAssertTrue(scannedAsShutdown.canBeSelected)

        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            activeProcesses: [.iosSimulators: ["Simulator"]],
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: executeTimeJSON, stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Must never execute simctl delete when live recheck shows Booted")
            }
        )

        do {
            _ = try await executor.execute(scannedAsShutdown)
            XCTFail("Expected immediate recheck to block deletion when target became Booted after scan")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .simulatorDeviceActive(deviceName: "iPhone 18 Pro Max", state: "Booted"))
            XCTAssertEqual(
                error.localizedDescription,
                "Cleanup blocked: iPhone 18 Pro Max is currently active.\nShut down this simulator before deleting it."
            )
        }

        XCTAssertEqual(recorder.calls, [
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]
        ], "Executor must re-query simctl list devices -j and abort before simctl delete")
    }

    func testTargetSimulatorDisappearsBeforeExecutionReturnsGracefulNothingEligible() async throws {
        let scanTimeJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "D0DD3D55-733A-4D23-9A25-B310BDB9D0CD",
                "name": "iPhone 18 Pro Max",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 3339337728,
                "logPathSize": 49152
              }
            ]
          }
        }
        """

        let emptyDevicesJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": []
          }
        }
        """

        let scannedItems = try SimulatorCleaner.parseDevicesJSON(scanTimeJSON.data(using: .utf8)!, homeDirectory: tempHome.path)
        let targetItem = try XCTUnwrap(scannedItems.first { $0.id == "sim-device-D0DD3D55-733A-4D23-9A25-B310BDB9D0CD" })

        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: emptyDevicesJSON, stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Must not call simctl delete when device no longer exists")
            }
        )

        let result = try await executor.execute(targetItem)
        XCTAssertEqual(result.status, .nothingEligible)
        XCTAssertEqual(result.processedBytes, 0)
        XCTAssertEqual(result.actuallyFreedBytes, 0)
        XCTAssertEqual(recorder.calls, [
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]
        ])
    }

    func testMalformedSimulatorUDIDIsRejectedBeforeAnySimctlInvocation() async throws {
        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                return ShellResult(exitCode: 0, stdout: "{}", stderr: "")
            }
        )

        for invalidUDID in ["../../not-a-uuid", "not-a-valid-udid", "12345", ""] {
            let malformedItem = CleanableItem(
                id: "bad-udid-\(invalidUDID)",
                name: "Malformed Sim",
                category: .iosSimulators,
                path: "",
                logicalSize: 100,
                physicalSize: 100,
                reclaimableSize: 100,
                lastModified: nil,
                riskLevel: .review,
                explanation: "",
                deletionConsequence: "",
                regenerationImpact: "",
                isRunningDependency: false,
                actionType: .simctlDeleteDevice(udid: invalidUDID)
            )

            do {
                _ = try await executor.execute(malformedItem)
                XCTFail("Expected commandFailed for malformed UDID: \(invalidUDID)")
            } catch let error as CleanerError {
                guard case .commandFailed = error else {
                    XCTFail("Expected commandFailed, got \(error)")
                    return
                }
            }
        }

        XCTAssertTrue(recorder.calls.isEmpty, "No shell command may be executed when UDID is malformed")
    }

    func testRuntimeAndUnavailableDeletionProtectionsRemainUnchangedWhenSimulatorIsActive() async throws {
        let recorder = CommandRecorder()
        let executor = makeIsolatedExecutor(
            activeProcesses: [.iosSimulators: ["Simulator"]],
            shellRunner: { executable, args in
                recorder.record(executable: executable, arguments: args)
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let runtimeItem = CleanableItem(
            id: "sim-runtime-ios18",
            name: "Runtime iOS 18.0",
            category: .iosSimulators,
            path: "/Library/Developer/CoreSimulator/Volumes",
            logicalSize: 8_000_000_000,
            physicalSize: 8_000_000_000,
            reclaimableSize: 8_000_000_000,
            lastModified: nil,
            riskLevel: .caution,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .simctlDeleteRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        )

        do {
            _ = try await executor.execute(runtimeItem)
            XCTFail("Expected runningProcessActive when deleting a simulator runtime while Simulator is running")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .runningProcessActive(appName: "Simulator", categoryName: "iOS Simulators"))
        }

        let unavailableItem = CleanableItem(
            id: "sim-delete-unavailable",
            name: "Delete Unavailable Simulators",
            category: .iosSimulators,
            path: "\(tempHome.path)/Library/Developer/CoreSimulator/Devices",
            logicalSize: 250_000_000,
            physicalSize: 250_000_000,
            reclaimableSize: 250_000_000,
            lastModified: nil,
            riskLevel: .safe,
            explanation: "",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .simctlDeleteUnavailable
        )

        do {
            _ = try await executor.execute(unavailableItem)
            XCTFail("Expected runningProcessActive when running simctl delete unavailable while Simulator is running")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .runningProcessActive(appName: "Simulator", categoryName: "iOS Simulators"))
        }

        XCTAssertTrue(recorder.calls.isEmpty, "Neither runtime deletion nor unavailable deletion may execute while Simulator is active")

        // Even when Simulator is NOT active, blanket simctlDeleteUnavailable is permanently blocked
        let idleExecutor = makeIsolatedExecutor()
        do {
            _ = try await idleExecutor.execute(unavailableItem)
            XCTFail("Expected readOnlyItem for blanket simctlDeleteUnavailable even when Simulator is idle")
        } catch let error as CleanerError {
            guard case .readOnlyItem = error else {
                XCTFail("Expected readOnlyItem, got \(error)")
                return
            }
        }
    }

    func testUnavailableAndTransitionalSimulatorsAndExecutionRevalidation() async throws {
        let fixtureJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
              {
                "udid": "11111111-2222-3333-4444-555555555555",
                "name": "Unavailable iPhone 16",
                "state": "Shutdown",
                "isAvailable": false,
                "availabilityError": "runtime profile not found",
                "dataPathSize": 250000000,
                "logPathSize": 0
              },
              {
                "udid": "22222222-3333-4444-5555-666666666666",
                "name": "Transitional Creating Sim",
                "state": "Creating",
                "isAvailable": true,
                "dataPathSize": 120000000,
                "logPathSize": 0
              },
              {
                "udid": "33333333-4444-5555-6666-777777777777",
                "name": "Transitional Shutting Down Sim",
                "state": "Shutting Down",
                "isAvailable": false,
                "dataPathSize": 180000000,
                "logPathSize": 0
              },
              {
                "udid": "44444444-5555-6666-7777-888888888888",
                "name": "QA Regression iPhone",
                "state": "Shutdown",
                "isAvailable": false,
                "dataPathSize": 300000000,
                "logPathSize": 0
              }
            ]
          }
        }
        """

        let items = try SimulatorCleaner.parseDevicesJSON(
            fixtureJSON.data(using: .utf8)!,
            homeDirectory: tempHome.path,
            xcodeDeveloperDir: "/Applications/Xcode.app/Contents/Developer"
        )

        // 1. Unavailable Shutdown simulator => REVIEW, selectable, never in Recommended SAFE cleanup
        let unavailableShutdown = try XCTUnwrap(items.first { $0.id == "sim-device-11111111-2222-3333-4444-555555555555" })
        XCTAssertEqual(unavailableShutdown.riskLevel, .review)
        XCTAssertTrue(unavailableShutdown.canBeSelected)
        XCTAssertEqual(unavailableShutdown.reclaimableSize, 250_000_000)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(unavailableShutdown))
        XCTAssertEqual(unavailableShutdown.simulatorMetadata?.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-26-3")
        XCTAssertEqual(unavailableShutdown.simulatorMetadata?.availabilityError, "runtime profile not found")
        XCTAssertEqual(unavailableShutdown.simulatorMetadata?.xcodeDeveloperDir, "/Applications/Xcode.app/Contents/Developer")

        // 2. Transitional states (Creating, Shutting Down) => blocked from selection and deletion
        let creatingSim = try XCTUnwrap(items.first { $0.id == "sim-device-22222222-3333-4444-5555-666666666666" })
        let shuttingDownSim = try XCTUnwrap(items.first { $0.id == "sim-device-33333333-4444-5555-6666-777777777777" })
        for transitional in [creatingSim, shuttingDownSim] {
            XCTAssertTrue(transitional.isRunningDependency)
            XCTAssertFalse(transitional.canBeSelected)
            XCTAssertEqual(transitional.reclaimableSize, 0)
        }
        XCTAssertEqual(creatingSim.simulatorMetadata?.displayBadgeText, "ACTIVE (CREATING) — protected")
        XCTAssertEqual(shuttingDownSim.simulatorMetadata?.displayBadgeText, "ACTIVE (SHUTTING DOWN) — protected")

        // 3. QA device protection => flagged as QA device, riskLevel is REVIEW, never default-selected
        let qaSim = try XCTUnwrap(items.first { $0.id == "sim-device-44444444-5555-6666-7777-888888888888" })
        XCTAssertEqual(qaSim.simulatorMetadata?.isNamedQADevice, true)
        XCTAssertEqual(qaSim.riskLevel, .review)
        XCTAssertFalse(CleanerViewModel.isEligibleForRecommendedSafeCleanup(qaSim))

        // 4. Execution revalidation: if Xcode selection changes between scan and execution => blocked
        let xcodeMismatchExecutor = makeIsolatedExecutor(
            shellRunner: { exe, args in
                if exe == "/usr/bin/xcode-select" && args == ["-p"] {
                    return ShellResult(exitCode: 0, stdout: "/Applications/Xcode-Beta.app/Contents/Developer\n", stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Unexpected command")
            }
        )
        do {
            _ = try await xcodeMismatchExecutor.execute(unavailableShutdown)
            XCTFail("Expected Xcode selection mismatch to block unavailable simulator deletion")
        } catch let error as CleanerError {
            guard case .commandFailed(let details) = error else {
                XCTFail("Expected commandFailed for Xcode selection mismatch, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("Active Xcode selection changed since scan"))
        }

        // 5. Execution revalidation: if unavailable device becomes available after Xcode switch/runtime mount => blocked
        let becameAvailableJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
              {
                "udid": "11111111-2222-3333-4444-555555555555",
                "name": "Unavailable iPhone 16",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPathSize": 250000000,
                "logPathSize": 0
              }
            ]
          }
        }
        """
        let availabilityChangedExecutor = makeIsolatedExecutor(
            shellRunner: { exe, args in
                if exe == "/usr/bin/xcode-select" && args == ["-p"] {
                    return ShellResult(exitCode: 0, stdout: "/Applications/Xcode.app/Contents/Developer\n", stderr: "")
                }
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: becameAvailableJSON, stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Unexpected command")
            }
        )
        do {
            _ = try await availabilityChangedExecutor.execute(unavailableShutdown)
            XCTFail("Expected availability change to block simulator deletion")
        } catch let error as CleanerError {
            guard case .commandFailed(let details) = error else {
                XCTFail("Expected commandFailed for availability change, got \(error)")
                return
            }
            XCTAssertTrue(details.contains("availability changed since scan"))
        }

        // 6. Execution revalidation: when Xcode selection, UDID, runtime, availability, and Shutdown state all match => deletes via xcrun simctl delete <UDID>
        let recorder = CommandRecorder()
        let validDeleteExecutor = makeIsolatedExecutor(
            simulatedFreeBefore: 100_000_000_000,
            simulatedFreeAfter: 100_250_000_000,
            shellRunner: { exe, args in
                recorder.record(executable: exe, arguments: args)
                if exe == "/usr/bin/xcode-select" && args == ["-p"] {
                    return ShellResult(exitCode: 0, stdout: "/Applications/Xcode.app/Contents/Developer\n", stderr: "")
                }
                if args == ["simctl", "list", "devices", "-j"] {
                    return ShellResult(exitCode: 0, stdout: fixtureJSON, stderr: "")
                }
                if args == ["simctl", "delete", "11111111-2222-3333-4444-555555555555"] {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                return ShellResult(exitCode: 1, stdout: "", stderr: "Unexpected command")
            }
        )
        let deleteResult = try await validDeleteExecutor.execute(unavailableShutdown)
        XCTAssertEqual(deleteResult.status, .cleaned)
        XCTAssertEqual(deleteResult.action, .simctlDelete)
        XCTAssertEqual(recorder.calls, [
            ["/usr/bin/xcode-select", "-p"],
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"],
            ["/usr/bin/xcrun", "simctl", "delete", "11111111-2222-3333-4444-555555555555"]
        ])
    }

    func testNpmAndNpxHardeningAgainstActiveToolsAndCapabilities() async throws {
        // Populate two _npx environments and _cacache in default ~/.npm
        _ = try createFile(
            relativeToHome: ".npm/_cacache/content-v2/sha512/aa/bb/blob1",
            sizeBytes: 32768
        )
        _ = try createFile(
            relativeToHome: ".npm/_npx/8843fba6d2859245/node_modules/firebase-tools/bin/firebase.js",
            sizeBytes: 65536
        )
        _ = try createFile(
            relativeToHome: ".npm/_npx/deadbeef12345678/node_modules/cowsay/index.js",
            sizeBytes: 16384
        )
        let defaultCacheRoot = tempHome.appendingPathComponent(".npm").standardizedFileURL.path

        // Scenario 1: Unsupported selective npx removal (e.g. npm 10.9.9) => _npx is inventory-only
        let unsupportedCaps = NpmCapabilities(
            npmBinaryPath: "/opt/homebrew/bin/npm",
            version: "10.9.9",
            effectiveCacheRoot: defaultCacheRoot,
            supportsCacheVerify: true,
            supportsCacheClean: true,
            supportsSelectiveNpxRemoval: false
        )
        let idleState = NpmLiveUseState(
            isDeterminedSafely: true,
            activeGlobalNpmProcesses: [],
            activeNpxEnvironmentKeys: [],
            activeProcessesByNpxKey: [:]
        )

        let unsupportedCleaner = StandardCacheCleaner(
            category: .nodeNpm,
            homeDirectory: tempHome.path,
            executor: makeIsolatedExecutor(),
            npmCapabilitiesOverride: unsupportedCaps,
            npmLiveUseOverride: idleState
        )
        let unsupportedItems = await unsupportedCleaner.scan(snapshot: .empty, ageFilter: .all)

        let npxInventoryOnly = try XCTUnwrap(unsupportedItems.first { $0.id == "npm-npx" })
        XCTAssertEqual(npxInventoryOnly.riskLevel, .review)
        XCTAssertEqual(npxInventoryOnly.reclaimableSize, 0, "Unsupported selective npx removal must have 0 reclaimable bytes")
        XCTAssertFalse(npxInventoryOnly.canBeSelected, "Inventory-only _npx must not be selectable")
        if case .readOnlyInfo(let reason) = npxInventoryOnly.actionType {
            XCTAssertTrue(reason.contains("Installed npm does not support selective npx-cache removal"))
        } else {
            XCTFail("Expected .readOnlyInfo when selective npx removal is unsupported")
        }

        let verifyItem = try XCTUnwrap(unsupportedItems.first { $0.id == "npm-cache-verify" })
        XCTAssertEqual(verifyItem.riskLevel, .review)
        XCTAssertEqual(verifyItem.reclaimableSize, 0, "npm cache verify exact reclaim is unknown before execution")
        XCTAssertTrue(verifyItem.canBeSelected, "npm cache verify maintenance command can be selected when idle")
        XCTAssertFalse(
            CleanerViewModel.isEligibleForRecommendedSafeCleanup(verifyItem),
            "0-reclaim maintenance verify must not inflate automatic SAFE cleanup totals"
        )

        let forceCleanItem = try XCTUnwrap(unsupportedItems.first { $0.id == "npm-cacache" })
        XCTAssertEqual(forceCleanItem.riskLevel, .review, "Full npm cache clean --force requires explicit user intent (REVIEW)")

        // Scenario 2: Active npx environment (detected via descendant process tree & lsof open file/cwd) => blocked
        let snapshotWithActiveMcp = ActiveProcessSnapshot(
            activeLines: ["node \(defaultCacheRoot)/_npx/8843fba6d2859245/node_modules/.bin/firebase-mcp"],
            runningAppNames: ["node"]
        )
        let detectedLiveState = await NpmCacheInspector.inspectLiveUse(
            cacheRoot: defaultCacheRoot,
            snapshot: snapshotWithActiveMcp,
            shellRunner: { exe, _ in
                if exe == "/bin/ps" {
                    // Parent npx (pid 500) -> child node (pid 501)
                    let psOut = """
                      500     1 npx npx -y @firebase/mcp
                      501   500 node /usr/local/bin/node
                    """
                    return ShellResult(exitCode: 0, stdout: psOut, stderr: "")
                }
                if exe == "/usr/sbin/lsof" {
                    let lsofOut = """
                    p501
                    cnode
                    fcwd
                    n\(defaultCacheRoot)/_npx/8843fba6d2859245/node_modules/firebase-tools
                    """
                    return ShellResult(exitCode: 0, stdout: lsofOut, stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            },
            includeSystemQueries: true
        )
        XCTAssertTrue(detectedLiveState.hasAnyGlobalOrNpxUse)
        XCTAssertTrue(detectedLiveState.activeNpxEnvironmentKeys.contains("8843fba6d2859245"))

        let activeCleaner = StandardCacheCleaner(
            category: .nodeNpm,
            homeDirectory: tempHome.path,
            executor: makeIsolatedExecutor(),
            npmCapabilitiesOverride: unsupportedCaps,
            npmLiveUseOverride: detectedLiveState
        )
        let activeItems = await activeCleaner.scan(snapshot: snapshotWithActiveMcp, ageFilter: .all)
        let activeNpxItem = try XCTUnwrap(activeItems.first { $0.id == "npm-npx" })
        XCTAssertTrue(activeNpxItem.isRunningDependency)
        XCTAssertEqual(activeNpxItem.reclaimableSize, 0)
        XCTAssertFalse(activeNpxItem.canBeSelected)
        XCTAssertTrue(activeNpxItem.explanation.contains("Status: Active / Protected from cleanup"))

        // Scenario 3: Supported selective npx removal (`npm cache npx rm <key>`) with 1 active key and 1 inactive key
        let supportedCaps = NpmCapabilities(
            npmBinaryPath: "/opt/homebrew/bin/npm",
            version: "11.2.0",
            effectiveCacheRoot: defaultCacheRoot,
            supportsCacheVerify: true,
            supportsCacheClean: true,
            supportsSelectiveNpxRemoval: true
        )
        let partialActiveState = NpmLiveUseState(
            isDeterminedSafely: true,
            activeGlobalNpmProcesses: [],
            activeNpxEnvironmentKeys: ["8843fba6d2859245"],
            activeProcessesByNpxKey: ["8843fba6d2859245": ["node (PID 501)"]]
        )
        let selectiveCleaner = StandardCacheCleaner(
            category: .nodeNpm,
            homeDirectory: tempHome.path,
            executor: makeIsolatedExecutor(),
            npmCapabilitiesOverride: supportedCaps,
            npmLiveUseOverride: partialActiveState
        )
        let selectiveItems = await selectiveCleaner.scan(snapshot: .empty, ageFilter: .all)
        let selectiveNpxItem = try XCTUnwrap(selectiveItems.first { $0.id == "npm-npx" })
        XCTAssertEqual(selectiveNpxItem.riskLevel, .review)
        XCTAssertTrue(selectiveNpxItem.canBeSelected)
        XCTAssertEqual(
            selectiveNpxItem.actionType,
            .npmNpxRemoveKeys(cacheRoot: defaultCacheRoot, keys: ["deadbeef12345678"]),
            "Only the inactive npx key may be included; active key 8843fba6d2859245 must be excluded"
        )
        let activeKeyReviewItem = try XCTUnwrap(selectiveItems.first { $0.id == "npm-npx-active-8843fba6d2859245" })
        XCTAssertTrue(activeKeyReviewItem.isRunningDependency)
        XCTAssertFalse(activeKeyReviewItem.canBeSelected)
        XCTAssertEqual(activeKeyReviewItem.reclaimableSize, 0)

        // Scenario 4: Process starts between scan and execution => blocked by CleanupExecutor re-check
        let recorder = CommandRecorder()
        let raceBlockedExecutor = makeIsolatedExecutor(
            shellRunner: { exe, args in
                recorder.record(executable: exe, arguments: args)
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            },
            npmCapabilitiesProvider: { supportedCaps },
            npmLiveUseChecker: { _ in
                // Process started on deadbeef12345678 right after scan!
                NpmLiveUseState(
                    isDeterminedSafely: true,
                    activeGlobalNpmProcesses: [],
                    activeNpxEnvironmentKeys: ["deadbeef12345678"],
                    activeProcessesByNpxKey: ["deadbeef12345678": ["npx (PID 900)"]]
                )
            }
        )
        do {
            _ = try await raceBlockedExecutor.execute(selectiveNpxItem)
            XCTFail("Expected runningProcessActive when npx environment becomes active between scan and execution")
        } catch let error as CleanerError {
            guard case .runningProcessActive = error else {
                XCTFail("Expected runningProcessActive, got \(error)")
                return
            }
        }
        XCTAssertTrue(recorder.calls.isEmpty, "npm cache npx rm must never run when live re-check detects active process")

        // Also verify when inactive at execution time, `npm cache npx rm deadbeef12345678` executes cleanly
        let cleanExecExecutor = makeIsolatedExecutor(
            simulatedFreeBefore: 100_000_000_000,
            simulatedFreeAfter: 100_016_384,
            shellRunner: { exe, args in
                recorder.record(executable: exe, arguments: args)
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            },
            npmCapabilitiesProvider: { supportedCaps },
            npmLiveUseChecker: { _ in idleState }
        )
        let npxCleanResult = try await cleanExecExecutor.execute(selectiveNpxItem)
        XCTAssertEqual(npxCleanResult.status, .cleaned)
        XCTAssertEqual(npxCleanResult.action, .npmCommand)
        XCTAssertEqual(recorder.calls, [
            ["/opt/homebrew/bin/npm", "cache", "npx", "rm", "deadbeef12345678", "--cache", defaultCacheRoot]
        ])

        // Scenario 5: Alternate npm cache root discovery + validation against unsafe roots
        let altCacheDir = tempHome.appendingPathComponent(".cache/custom-npm-cache", isDirectory: true)
        _ = try createFile(relativeToHome: ".cache/custom-npm-cache/_cacache/blob", sizeBytes: 8192)
        let npmrcURL = tempHome.appendingPathComponent(".npmrc")
        try "cache=\(altCacheDir.path)\n".write(to: npmrcURL, atomically: true, encoding: .utf8)

        let discoveredAltCaps = await NpmCacheInspector.discoverCapabilities(
            homeDirectory: tempHome.path,
            environment: [:],
            npmBinaryResolver: { "/opt/homebrew/bin/npm" },
            shellRunner: { _, args in
                if args == ["cache", "--help"] {
                    return ShellResult(exitCode: 0, stdout: "npm cache clean\nnpm cache verify\n", stderr: "")
                }
                if args == ["--version"] {
                    return ShellResult(exitCode: 0, stdout: "10.9.9\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        XCTAssertEqual(discoveredAltCaps.effectiveCacheRoot, altCacheDir.standardizedFileURL.path)

        // Unsafe cache roots (project node_modules, .npmrc credentials file, home root) must be rejected
        XCTAssertThrowsError(
            try NpmCacheInspector.validateAndCanonicalizeCacheRoot(
                "\(tempHome.path)/Developer/my-app/node_modules",
                homeDirectory: tempHome.path
            )
        )
        XCTAssertThrowsError(
            try NpmCacheInspector.validateAndCanonicalizeCacheRoot(
                "\(tempHome.path)/.npmrc",
                homeDirectory: tempHome.path
            )
        )
        XCTAssertThrowsError(
            try NpmCacheInspector.validateAndCanonicalizeCacheRoot(
                tempHome.path,
                homeDirectory: tempHome.path
            )
        )
    }

    func testStorageMetricsAndAppIconBranding() throws {
        let metrics = DiskScanner.shared.currentStorageMetrics()
        XCTAssertGreaterThan(metrics.macOSAvailableBytes, 0, "macOSAvailableBytes must be > 0")
        XCTAssertGreaterThan(metrics.physicalFreeBytes, 0, "physicalFreeBytes must be > 0")
        XCTAssertGreaterThanOrEqual(
            metrics.macOSAvailableBytes,
            metrics.physicalFreeBytes,
            "macOS available capacity (which includes purgeable space) should be >= physically free SSD bytes"
        )

        let iconData = AppIconBranding.pngData(pixelSize: 256)
        XCTAssertNotNil(iconData, "AppIconBranding must generate valid PNG data")
        XCTAssertGreaterThan(iconData?.count ?? 0, 1024, "Generated icon PNG must be non-empty")
    }
}

private final class LockCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private var recorded: [[String]] = []
    private let lock = NSLock()

    func record(executable: String, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append([executable] + arguments)
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
