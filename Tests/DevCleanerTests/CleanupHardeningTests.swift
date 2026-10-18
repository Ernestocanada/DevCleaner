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
        activeProcesses: [CleanerCategory: [String]] = [:]
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
            }
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

        // 3. Unavailable simulator => SAFE using official simctl operation
        let unavailableBulk = try XCTUnwrap(items.first { $0.id == "sim-delete-unavailable" })
        XCTAssertEqual(unavailableBulk.riskLevel, .safe)
        XCTAssertEqual(unavailableBulk.actionType, .simctlDeleteUnavailable)
        XCTAssertEqual(unavailableBulk.reclaimableSize, 250_000_000)

        let unavailableIndividual = try XCTUnwrap(items.first { $0.id.contains("11111111-2222-3333-4444-555555555555") })
        XCTAssertEqual(unavailableIndividual.riskLevel, .safe)

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
