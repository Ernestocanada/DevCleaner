import XCTest
@testable import DevCleaner

final class ProjectAndWorktreeAnalyzerTests: XCTestCase {
    private var tempRoot: URL!
    private var tempHome: URL!
    private var tempDevRoot: URL!
    private var tempTrash: URL!
    private var validator: SafetyValidator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DevCleanerProjectAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        tempHome = tempRoot.appendingPathComponent("Home", isDirectory: true)
        tempDevRoot = tempHome.appendingPathComponent("Developer", isDirectory: true)
        tempTrash = tempRoot.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDevRoot, withIntermediateDirectories: true)
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
    private func writeFile(_ base: URL, _ relativePath: String, sizeBytes: Int = 4096, textContent: String? = nil) throws -> URL {
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let textContent {
            try textContent.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let data = Data(repeating: 0x5A, count: sizeBytes)
            try data.write(to: url)
        }
        return url
    }

    // MARK: - 1. Selective .cache Classification & Zero Double-Counting Tests

    func testSelectiveDotCacheDistinguishesSafeReviewAndProtectedWithoutDeletingRootCache() async throws {
        let proj = tempDevRoot.appendingPathComponent("field-service-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)

        // Root project source & git
        try writeFile(proj, ".git/HEAD", textContent: "ref: refs/heads/main\n")
        try writeFile(proj, "package.json", textContent: "{\"name\": \"field-service-synthetic\"}")
        try writeFile(proj, "src/index.ts", sizeBytes: 8192)

        // 1. SAFE package caches inside .cache
        try writeFile(proj, ".cache/npm/_cacache/content-v2/sha512/blob1", sizeBytes: 16384)
        try writeFile(proj, ".cache/pnpm/store/v3/files/blob2", sizeBytes: 16384)
        try writeFile(proj, ".cache/corepack/v1/yarn/4.0.0.tgz", sizeBytes: 8192)

        // 2. SAFE verified local Xcode DerivedData inside .cache/m03/mobile
        try writeFile(proj, ".cache/m03/mobile/info.plist", textContent: "<plist></plist>")
        try writeFile(proj, ".cache/m03/mobile/Build/Intermediates.noindex/App.o", sizeBytes: 32768)
        try writeFile(proj, ".cache/m03/mobile/ModuleCache.noindex/mod.pcm", sizeBytes: 8192)

        // 3. SAFE verified local Xcode SYMROOT inside .cache/m03/module-build
        try writeFile(proj, ".cache/m03/module-build/XCBuildData/build.db", sizeBytes: 8192)
        try writeFile(proj, ".cache/m03/module-build/Pods.build/Debug/Pod.o", sizeBytes: 16384)

        // 4. SAFE verified Android Gradle build inside .cache/p10-native/android-before/app/build
        try writeFile(proj, ".cache/p10-native/android-before/app/build.gradle", textContent: "plugins {}")
        try writeFile(proj, ".cache/p10-native/android-before/app/build/intermediates/dex/classes.dex", sizeBytes: 24576)

        // 5. REVIEW items inside .cache: validation/node_modules, .xcresult, tarballs
        try writeFile(proj, ".cache/validation/package.json", textContent: "{}")
        try writeFile(proj, ".cache/validation/node_modules/pkg/index.js", sizeBytes: 16384)
        try writeFile(proj, ".cache/p25-native/ios/TestRun.xcresult/Info.plist", textContent: "<plist></plist>")
        try writeFile(proj, ".cache/p25-native/ios/TestRun.xcresult/Data/result.bin", sizeBytes: 16384)
        try writeFile(proj, ".cache/tarballs/app-pack-1.0.0.tgz", sizeBytes: 8192)

        // 6. PROTECTED evidence, TLS certificates, .env, and release APK inside .cache
        let envFile = try writeFile(proj, ".cache/p01.env", textContent: "SECRET=123")
        let certFile = try writeFile(proj, ".cache/p26-https/ca.pem", textContent: "-----BEGIN CERTIFICATE-----")
        let mobileConfigFile = try writeFile(proj, ".cache/p26-https/ca.mobileconfig", textContent: "<plist></plist>")
        let evidenceFile = try writeFile(proj, ".cache/p08-evidence/report.json", sizeBytes: 8192)
        let releaseAPK = try writeFile(proj, ".cache/p27-release/JobFlow-release.apk", sizeBytes: 16384)

        let analyzer = ProjectStorageAnalyzer(validator: validator)
        let (reports, summary) = await analyzer.analyzeProjects(in: tempDevRoot.path, snapshot: .empty)

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)

        // Verify exact accounting without double counting
        let fullProjectMeasurement = DiskScanner.shared.measurePath(proj.path)
        XCTAssertEqual(
            report.totalPhysicalBytes,
            fullProjectMeasurement.physicalSize,
            "Project totalPhysicalBytes must match single-pass physical size without double counting"
        )
        let sumOfBuckets = report.cachesBytes + report.buildsBytes + report.dependenciesBytes + report.worktreesBytes + report.protectedBytes
        XCTAssertEqual(
            report.totalPhysicalBytes,
            sumOfBuckets,
            "Sum of caches + builds + dependencies + worktrees + protected must equal totalPhysicalBytes"
        )
        XCTAssertEqual(summary.totalProjectsPhysicalBytes, report.totalPhysicalBytes)

        // Verify SAFE items
        let safePaths = Set(report.artifacts.filter { $0.riskLevel == .safe && $0.reclaimableBytes > 0 }.map { $0.relativePath })
        XCTAssertTrue(safePaths.contains(".cache/npm"))
        XCTAssertTrue(safePaths.contains(".cache/pnpm"))
        XCTAssertTrue(safePaths.contains(".cache/corepack"))
        XCTAssertTrue(safePaths.contains(".cache/m03/mobile"))
        XCTAssertTrue(safePaths.contains(".cache/m03/module-build"))
        XCTAssertTrue(safePaths.contains(".cache/p10-native/android-before/app/build"))

        // Verify REVIEW items
        let reviewPaths = Set(report.artifacts.filter { $0.riskLevel == .review && $0.reclaimableBytes > 0 }.map { $0.relativePath })
        XCTAssertTrue(reviewPaths.contains(".cache/validation/node_modules"))
        XCTAssertTrue(reviewPaths.contains(".cache/p25-native/ios/TestRun.xcresult"))
        XCTAssertTrue(reviewPaths.contains(".cache/tarballs"))

        // Verify .cache root itself is NEVER offered as a deletable item, and protected subset has reclaimableBytes == 0
        let protectedSubset = try XCTUnwrap(report.artifacts.first { $0.relativePath == ".cache [protected subset]" })
        XCTAssertEqual(protectedSubset.reclaimableBytes, 0)
        XCTAssertFalse(protectedSubset.cleanableItem.canBeSelected)

        // Execute cleanup of SAFE items only and verify all protected files & REVIEW items remain untouched
        let trashDir = self.tempTrash!
        let executor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { url in
                let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
            },
            shellRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") }
        )

        for artifact in report.artifacts where artifact.riskLevel == .safe {
            let res = try await executor.execute(artifact.cleanableItem)
            XCTAssertEqual(res.status, .cleaned)
        }

        // Protected files must still exist on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: certFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mobileConfigFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: releaseAPK.path))
    }

    // MARK: - 2. Unverified Build/Dist/Cache Folders & Modified-Since-Scan Safety Tests

    func testUnverifiedBuildAndDistDirectoriesAreBlockedFromAutomaticDeletion() async throws {
        let proj = tempDevRoot.appendingPathComponent("custom-app", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try writeFile(proj, "package.json", textContent: "{\"name\": \"custom-app\"}")
        try writeFile(proj, "next.config.mjs", textContent: "export default {}")

        // 1. Verified .next build cache
        let nextFile = try writeFile(proj, ".next/cache/webpack/bundle.js", sizeBytes: 16384)
        // 2. Unverified `dist` directory (could contain committed static assets)
        let distFile = try writeFile(proj, "dist/release-bundle.js", sizeBytes: 16384)
        // 3. Unverified `build` directory without Gradle or Xcode SYMROOT markers
        let customBuildFile = try writeFile(proj, "build/custom-output.bin", sizeBytes: 16384)

        let analyzer = ProjectStorageAnalyzer(validator: validator)
        let (reports, _) = await analyzer.analyzeProjects(in: tempDevRoot.path, snapshot: .empty)
        let report = try XCTUnwrap(reports.first)

        let nextArtifact = try XCTUnwrap(report.artifacts.first { $0.relativePath == ".next" })
        XCTAssertEqual(nextArtifact.riskLevel, .safe)
        XCTAssertGreaterThan(nextArtifact.reclaimableBytes, 0)
        XCTAssertTrue(nextArtifact.cleanableItem.canBeSelected)

        let distArtifact = try XCTUnwrap(report.artifacts.first { $0.relativePath == "dist" })
        XCTAssertEqual(distArtifact.reclaimableBytes, 0, "Unverified dist folder must have 0 reclaimableBytes")
        XCTAssertFalse(distArtifact.cleanableItem.canBeSelected, "Unverified dist folder must not be selectable")

        let buildArtifact = try XCTUnwrap(report.artifacts.first { $0.relativePath == "build" })
        XCTAssertEqual(buildArtifact.reclaimableBytes, 0, "Unverified build folder without Gradle/Xcode markers must have 0 reclaimableBytes")
        XCTAssertFalse(buildArtifact.cleanableItem.canBeSelected)

        // Even if someone attempts to force-execute deletion of unverified dist/ or build/, SafetyValidator blocks it
        XCTAssertThrowsError(
            try validator.validateVerifiedProjectArtifactForDeletion(
                proj.appendingPathComponent("dist").path,
                projectRoot: proj.path
            )
        ) { error in
            guard case SafetyError.unverifiedProjectArtifact = error else {
                XCTFail("Expected SafetyError.unverifiedProjectArtifact, got \(error)")
                return
            }
        }

        // Verify modifiedSinceScan protection on .next
        let oldTimestamp = Date().addingTimeInterval(-3600)
        XCTAssertThrowsError(
            try validator.validateVerifiedProjectArtifactForDeletion(
                proj.appendingPathComponent(".next").path,
                projectRoot: proj.path,
                expectedModifiedAt: oldTimestamp
            )
        ) { error in
            guard case SafetyError.modifiedSinceScan = error else {
                XCTFail("Expected SafetyError.modifiedSinceScan, got \(error)")
                return
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: nextFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: distFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: customBuildFile.path))
    }

    // MARK: - 3. Git & Claude Worktree Analyzer Tests (Informative Only)

    func testGitWorktreePorcelainAndStatusParsingProtectsDirtyDetachedAndLockedWorktrees() throws {
        let samplePorcelain = """
        worktree /Users/ernesto/Developer/coparentia-web
        HEAD 1111111122222222333333334444444455555555
        branch refs/heads/main

        worktree /Users/ernesto/Developer/coparentia-web/.claude/worktrees/agent-dirty
        HEAD aaaaaaaa22222222333333334444444455555555
        branch refs/heads/claude/feature-ui

        worktree /Users/ernesto/Developer/BuildGetcoparentia/.claude/worktrees/infallible-moore
        HEAD bbbbbbbb22222222333333334444444455555555
        detached
        locked active agent session

        worktree /private/tmp/coparentia-missing
        HEAD cccccccc22222222333333334444444455555555
        branch refs/heads/temp-branch
        prunable gitdir file points to non-existent location
        """

        let parsed = GitWorktreeAnalyzer.parsePorcelainWorktreeList(samplePorcelain)
        XCTAssertEqual(parsed.count, 4)

        XCTAssertEqual(parsed[1].path, "/Users/ernesto/Developer/coparentia-web/.claude/worktrees/agent-dirty")
        XCTAssertEqual(parsed[1].branchRef, "refs/heads/claude/feature-ui")
        XCTAssertFalse(parsed[1].isDetached)

        XCTAssertTrue(parsed[2].isDetached)
        XCTAssertTrue(parsed[2].isLocked)
        XCTAssertEqual(parsed[2].lockReason, "active agent session")

        XCTAssertTrue(parsed[3].isPrunable)

        let dirtyStatusOutput = """
        ## claude/feature-ui...origin/claude/feature-ui [ahead 2]
         M src/App.tsx
        A  src/NewComponent.tsx
        ?? src/untracked.ts
        """
        let statusParsed = GitWorktreeAnalyzer.parseGitStatusPorcelainBranch(dirtyStatusOutput, isDetached: false)
        XCTAssertEqual(statusParsed.modifiedCount, 1)
        XCTAssertEqual(statusParsed.stagedCount, 1)
        XCTAssertEqual(statusParsed.untrackedCount, 1)
        XCTAssertTrue(statusParsed.remoteStatus.contains("ahead 2"))

        // Dirty worktree => CAUTION, never SAFE
        let (dirtyRisk, _) = GitWorktreeAnalyzer.evaluateWorkLossRisk(
            existsOnDisk: true,
            isLocked: false,
            lockReason: nil,
            isInUse: false,
            activeProcesses: [],
            hasUncommittedChanges: true,
            modifiedCount: 1,
            untrackedCount: 1,
            stagedCount: 1,
            isDetached: false,
            remoteStatus: statusParsed.remoteStatus,
            isPrunable: false
        )
        XCTAssertEqual(dirtyRisk, .caution)
        XCTAssertNotEqual(dirtyRisk, .safe)

        // Locked worktree => NEVER DELETE
        let (lockedRisk, _) = GitWorktreeAnalyzer.evaluateWorkLossRisk(
            existsOnDisk: true,
            isLocked: true,
            lockReason: "active agent session",
            isInUse: false,
            activeProcesses: [],
            hasUncommittedChanges: false,
            modifiedCount: 0,
            untrackedCount: 0,
            stagedCount: 0,
            isDetached: true,
            remoteStatus: "Detached HEAD",
            isPrunable: false
        )
        XCTAssertEqual(lockedRisk, .neverDelete)
    }

    // MARK: - 4. Simulator Favorites, Installed Apps & Android AVD Stale Lock Tests

    func testSimulatorFavoritesAndInstalledAppsDetection() throws {
        let simUDID = "83050079-F7C5-4F34-AD3A-E6CBF1130330"
        let simDataDir = tempHome.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(simUDID)/data")
        try writeFile(simDataDir, "Containers/Bundle/Application/UUID-1/FieldService.app/Info.plist", textContent: "<plist></plist>")
        try writeFile(simDataDir, "Containers/Bundle/Application/UUID-2/CoParentia.app/Info.plist", textContent: "<plist></plist>")

        let fixtureJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {
                "udid": "\(simUDID)",
                "name": "iPhone 18 Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "dataPath": "\(simDataDir.path)",
                "dataPathSize": 6300000000,
                "logPathSize": 500000
              }
            ]
          }
        }
        """.data(using: .utf8)!

        // When marked as Favorite, simulator must be protected (reclaimableSize == 0, canBeSelected == false)
        let favItems = try SimulatorCleaner.parseDevicesJSON(
            fixtureJSON,
            homeDirectory: tempHome.path,
            favoriteUDIDs: [simUDID]
        )
        let favSim = try XCTUnwrap(favItems.first { $0.id == "sim-device-\(simUDID)" })
        XCTAssertEqual(favSim.simulatorMetadata?.installedAppNames, ["CoParentia", "FieldService"])
        XCTAssertEqual(favSim.simulatorMetadata?.isFavorite, true)
        XCTAssertEqual(favSim.simulatorMetadata?.displayBadgeText, "FAVORITE — protected")
        XCTAssertEqual(favSim.reclaimableSize, 0)
        XCTAssertFalse(favSim.canBeSelected, "Favorite simulator must be protected from selection")
    }

    func testAndroidAVDStaleLockPIDIsNotFalselyBlockedWhileLivePIDIsProtected() throws {
        let avdDir = tempHome.appendingPathComponent(".android/avd/medium_phone.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdDir, withIntermediateDirectories: true)
        try writeFile(
            avdDir,
            "config.ini",
            textContent: """
            avd.ini.displayname=Medium Phone
            abi.type=arm64-v8a
            image.sysdir.1=system-images/android-36.1/google_apis_playstore/arm64-v8a/
            """
        )

        let parsedConfig = AndroidCleaner.parseAVDConfig(at: avdDir)
        XCTAssertEqual(parsedConfig.displayName, "Medium Phone")
        XCTAssertEqual(parsedConfig.androidVersionLabel, "API 36.1")
        XCTAssertEqual(parsedConfig.abi, "arm64-v8a")

        // Stale PID that does not exist (999999)
        try writeFile(avdDir, "hardware-qemu.ini.lock/pid", textContent: "999999")
        XCTAssertNil(AndroidCleaner.activeLockPID(inAVDDirectory: avdDir), "Stale lock PID must not be treated as active")

        // Live PID (current test process PID)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        try writeFile(avdDir, "hardware-qemu.ini.lock/pid", textContent: "\(currentPID)")
        XCTAssertEqual(AndroidCleaner.activeLockPID(inAVDDirectory: avdDir), currentPID, "Live lock PID must be detected as active")
    }

    // MARK: - 5. Claude Old Tool Versions & Codex Runtime Metadata Tests

    func testClaudeSupersededVersionAndCodexRuntimeMetadataHandling() async throws {
        // Claude active v2.1.308 vs superseded v2.1.304
        try writeFile(tempHome, "Library/Application Support/Claude/claude-code-vm/.sdk-version", textContent: "2.1.308\n")
        try writeFile(tempHome, "Library/Application Support/Claude/claude-code/2.1.304/claude", sizeBytes: 16384)
        try writeFile(tempHome, "Library/Application Support/Claude/claude-code/2.1.308/claude", sizeBytes: 16384)

        // Codex runtime containing .NET git-credential-manager.runtimeconfig.json (must NOT be flagged as credential)
        try writeFile(
            tempHome,
            ".cache/codex-runtimes/codex-primary-runtime/git-credential-manager.runtimeconfig.json",
            textContent: "{}"
        )
        try writeFile(
            tempHome,
            ".cache/codex-runtimes/codex-runtime-install-12345/git-credential-manager.deps.json",
            textContent: "{}"
        )

        let claudeCleaner = AIToolsCleaner(category: .claude, homeDirectory: tempHome.path)
        let claudeItems = await claudeCleaner.scan(snapshot: .empty, ageFilter: .all)

        let oldVersion = try XCTUnwrap(claudeItems.first { $0.id == "claude-code-old-2.1.304" })
        let activeVersion = try XCTUnwrap(claudeItems.first { $0.id == "claude-code-active-2.1.308" })

        XCTAssertEqual(oldVersion.riskLevel, .safe, "Superseded Claude Code version verified by .sdk-version must be classified as SAFE")
        XCTAssertGreaterThan(oldVersion.reclaimableSize, 0)
        XCTAssertEqual(activeVersion.riskLevel, .neverDelete)
        XCTAssertEqual(activeVersion.reclaimableSize, 0)
        XCTAssertFalse(activeVersion.canBeSelected)

        let codexCleaner = AIToolsCleaner(category: .codex, homeDirectory: tempHome.path)
        let codexItems = await codexCleaner.scan(snapshot: .empty, ageFilter: .all)
        let runtimesItem = try XCTUnwrap(codexItems.first { $0.id == "codex-runtimes-cache" })
        XCTAssertEqual(runtimesItem.plan?.eligibleEntries.count, 2, "Both codex-primary-runtime and codex-runtime-install-* should be eligible in REVIEW plan without false-positive credential block")
    }

    // MARK: - 6. Interface Tabs & Dock Reopen Window Lifecycle Tests

    @MainActor
    func testMainAnalyzerTabsAndDockReopenWindowLifecycle() throws {
        // Verify exact tab labels required by UI specification
        XCTAssertEqual(
            MainAnalyzerTab.allCases.map(\.rawValue),
            ["System & Tools", "Project Storage", "Worktrees", "Mac Storage"]
        )

        let delegate = DevCleanerAppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

        var reopenCallbackCount = 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        delegate.registerMainWindow(window) {
            reopenCallbackCount += 1
        }
        XCTAssertFalse(window.isReleasedWhenClosed, "Main window must retain instance when closed so Dock click can restore it")

        // Simulate closing window with red button (x)
        window.close()
        XCTAssertFalse(window.isVisible)

        // Simulate clicking Dock icon (applicationShouldHandleReopen)
        let shouldCreateDefaultWindow = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertFalse(shouldCreateDefaultWindow, "Delegate must return false after restoring window to prevent duplicate windows")
        XCTAssertTrue(window.isVisible, "Closed main window must become visible again on Dock click")
        XCTAssertEqual(reopenCallbackCount, 0, "Existing retained window should be restored directly without spawning a new window")
    }
}
