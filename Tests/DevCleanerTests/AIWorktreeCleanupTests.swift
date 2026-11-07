import XCTest
@testable import DevCleaner

final class AIWorktreeCleanupTests: XCTestCase {
    private var tempRoot: URL!
    private var tempHome: URL!
    private var tempDevRoot: URL!
    private var tempCodexRoot: URL!
    private var tempTrash: URL!
    private var validator: SafetyValidator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DevCleanerAIWorktreeTests-\(UUID().uuidString)", isDirectory: true)
        tempHome = tempRoot.appendingPathComponent("Home", isDirectory: true)
        tempDevRoot = tempHome.appendingPathComponent("Developer", isDirectory: true)
        tempCodexRoot = tempHome.appendingPathComponent(".codex/worktrees", isDirectory: true)
        tempTrash = tempRoot.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDevRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCodexRoot, withIntermediateDirectories: true)
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

    /// Creates a synthetic verified Git worktree fixture with valid `.git` file pointing to `<mainRepo>/.git/worktrees/<name>`
    private func createVerifiedWorktreeFixture(
        mainRepoURL: URL,
        worktreeURL: URL,
        worktreeID: String,
        branchName: String = "claude/feature-test",
        headSHA: String = "1111111122222222333333334444444455555555",
        isLocked: Bool = false
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mainRepoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeFile(mainRepoURL, ".git/HEAD", textContent: "ref: refs/heads/main\n")

        let wtMetaDir = mainRepoURL.appendingPathComponent(".git/worktrees/\(worktreeID)", isDirectory: true)
        try fm.createDirectory(at: wtMetaDir, withIntermediateDirectories: true)
        try writeFile(wtMetaDir, "HEAD", textContent: "ref: refs/heads/\(branchName)\n")
        try writeFile(wtMetaDir, "commondir", textContent: "../..\n")
        try writeFile(wtMetaDir, "gitdir", textContent: "\(worktreeURL.appendingPathComponent(".git").path)\n")
        if isLocked {
            try writeFile(wtMetaDir, "locked", textContent: "active session\n")
        }

        try fm.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try writeFile(worktreeURL, ".git", textContent: "gitdir: \(wtMetaDir.path)\n")
    }

    // MARK: - 1. Claude, Codex & Registered Git Worktree Detection (Verified via Git Metadata)

    func testClaudeCodexAndRegisteredGitWorktreeDetectionAndMetadataVerification() async throws {
        // 1. Main repo `coparentia-web` with a Claude worktree at `.claude/worktrees/revenuecat-sandbox`
        let coparentiaRepo = tempDevRoot.appendingPathComponent("coparentia-web", isDirectory: true)
        let claudeWT = coparentiaRepo.appendingPathComponent(".claude/worktrees/revenuecat-sandbox", isDirectory: true)
        try createVerifiedWorktreeFixture(
            mainRepoURL: coparentiaRepo,
            worktreeURL: claudeWT,
            worktreeID: "revenuecat-sandbox",
            branchName: "claude/revenuecat-sandbox"
        )
        try writeFile(claudeWT, "package.json", textContent: "{\"name\":\"coparentia-web\"}")
        try writeFile(claudeWT, "package-lock.json", textContent: "{\"lockfileVersion\":3}")
        try writeFile(claudeWT, "node_modules/pkg-a/index.js", sizeBytes: 32768)

        // Fake folder inside `.claude/worktrees/not-a-worktree` WITHOUT `.git` metadata (must be ignored!)
        let fakeClaudeDir = coparentiaRepo.appendingPathComponent(".claude/worktrees/not-a-worktree", isDirectory: true)
        try writeFile(fakeClaudeDir, "node_modules/pkg/index.js", sizeBytes: 16384)
        XCTAssertFalse(SafetyValidator.verifyWorktreeGitMetadata(at: fakeClaudeDir.path).isVerified)

        // Main repo itself must NOT be treated as a worktree
        XCTAssertFalse(SafetyValidator.verifyWorktreeGitMetadata(at: coparentiaRepo.path).isVerified)

        // 2. Codex worktree at `~/.codex/worktrees/fast-job-intake/field-service-app`
        let fieldServiceRepo = tempDevRoot.appendingPathComponent("field-service-app", isDirectory: true)
        let codexWT = tempCodexRoot.appendingPathComponent("fast-job-intake/field-service-app", isDirectory: true)
        try createVerifiedWorktreeFixture(
            mainRepoURL: fieldServiceRepo,
            worktreeURL: codexWT,
            worktreeID: "fast-job-intake",
            branchName: "codex/fast-job-intake"
        )
        try writeFile(codexWT, "package.json", textContent: "{\"name\":\"field-service-app\"}")
        try writeFile(codexWT, "pnpm-lock.yaml", textContent: "lockfileVersion: '9.0'")
        try writeFile(codexWT, "node_modules/pkg-b/index.js", sizeBytes: 24576)

        // 3. Registered Git linked worktree at `~/Developer/field-service-app-localfirst`
        let linkedWT = tempDevRoot.appendingPathComponent("field-service-app-localfirst", isDirectory: true)
        try createVerifiedWorktreeFixture(
            mainRepoURL: fieldServiceRepo,
            worktreeURL: linkedWT,
            worktreeID: "field-service-app-localfirst",
            branchName: "feat/localfirst"
        )
        try writeFile(linkedWT, "package.json", textContent: "{\"name\":\"field-service-app\"}")
        try writeFile(linkedWT, "pnpm-lock.yaml", textContent: "lockfileVersion: '9.0'")
        try writeFile(linkedWT, ".next/server/app.js", sizeBytes: 16384)

        let coparentiaPath = coparentiaRepo.standardizedFileURL.path
        let claudeWTPath = claudeWT.standardizedFileURL.path
        let fieldServicePath = fieldServiceRepo.standardizedFileURL.path
        let linkedWTPath = linkedWT.standardizedFileURL.path

        let tenDaysAgoEpoch = Int(Date().addingTimeInterval(-10 * 86400).timeIntervalSince1970)

        let analyzer = GitWorktreeAnalyzer(
            validator: validator,
            shellRunner: { _, args in
                if args.contains("worktree") && args.contains("list") {
                    if args.contains(coparentiaPath) {
                        let out = """
                        worktree \(coparentiaPath)
                        HEAD 1111111122222222333333334444444455555555
                        branch refs/heads/main

                        worktree \(claudeWTPath)
                        HEAD aaaaaaaa22222222333333334444444455555555
                        branch refs/heads/claude/revenuecat-sandbox
                        """
                        return ShellResult(exitCode: 0, stdout: out, stderr: "")
                    }
                    if args.contains(fieldServicePath) || args.contains(linkedWTPath) {
                        let out = """
                        worktree \(fieldServicePath)
                        HEAD 2222222233333333444444445555555566666666
                        branch refs/heads/main

                        worktree \(linkedWTPath)
                        HEAD bbbbbbbb22222222333333334444444455555555
                        branch refs/heads/feat/localfirst
                        """
                        return ShellResult(exitCode: 0, stdout: out, stderr: "")
                    }
                }
                if args.contains("status") {
                    return ShellResult(exitCode: 0, stdout: "## main...origin/main\n", stderr: "")
                }
                if args.contains("log") {
                    return ShellResult(exitCode: 0, stdout: "\(tenDaysAgoEpoch)\n", stderr: "")
                }
                if args.contains("ls-files") {
                    return ShellResult(exitCode: 0, stdout: "package.json\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let records = await analyzer.analyzeWorktrees(
            in: tempDevRoot.path,
            codexWorktreesRoot: tempCodexRoot.path,
            snapshot: .empty
        )

        XCTAssertEqual(records.count, 3, "Must detect Claude, Codex, and registered Git worktrees while ignoring unverified folders")
        let summary = WorktreeAnalysisSummary.from(records: records)
        XCTAssertEqual(summary.claudeWorktreesCount, 1)
        XCTAssertEqual(summary.codexWorktreesCount, 1)
        XCTAssertEqual(summary.gitLinkedWorktreesCount, 1)
        XCTAssertGreaterThan(summary.regenerableBytes, 0)
        XCTAssertEqual(summary.safeRegenerableBytes, summary.regenerableBytes)

        let claudeRecord = try XCTUnwrap(records.first { $0.originKind == .claudeWorktree })
        XCTAssertEqual(claudeRecord.sourceProjectName, "coparentia-web")
        XCTAssertEqual(claudeRecord.worktreeName, "revenuecat-sandbox")
        let claudeNM = try XCTUnwrap(claudeRecord.artifactCandidates.first { $0.relativePath == "node_modules" })
        XCTAssertEqual(claudeNM.projectAndWorktreeDisplay, "coparentia-web / revenuecat-sandbox")
        XCTAssertEqual(claudeNM.classification, .safe)
        XCTAssertEqual(claudeNM.gitTrackingState, .ignored)
        XCTAssertEqual(claudeNM.classificationReason, "Git-ignored dependency directory; reproducible from package-lock.json")

        let codexRecord = try XCTUnwrap(records.first { $0.originKind == .codexWorktree })
        XCTAssertEqual(codexRecord.sourceProjectName, "field-service-app")
        XCTAssertEqual(codexRecord.worktreeName, "fast-job-intake")

        let linkedRecord = try XCTUnwrap(records.first { $0.originKind == .gitLinkedWorktree })
        XCTAssertEqual(linkedRecord.worktreeName, "field-service-app-localfirst")
    }

    // MARK: - 2. Artifact Classifications: node_modules, .next, .turbo, build/dist/cache, .tsbuildinfo, Firebase Emulators

    func testArtifactClassificationsSafeVsReview() throws {
        let repo = tempDevRoot.appendingPathComponent("web-suite", isDirectory: true)
        let wtClean = repo.appendingPathComponent(".claude/worktrees/clean-wt", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtClean, worktreeID: "clean-wt")

        // Setup project configs in clean-wt
        try writeFile(
            wtClean,
            "package.json",
            textContent: """
            {
              "name": "web-suite",
              "scripts": {
                "build": "next build && tsc"
              }
            }
            """
        )
        try writeFile(wtClean, "package-lock.json", textContent: "{\"lockfileVersion\": 3}")
        try writeFile(wtClean, "next.config.mjs", textContent: "export default {}")
        try writeFile(wtClean, "turbo.json", textContent: "{}")
        try writeFile(wtClean, "tsconfig.json", textContent: "{}")
        try writeFile(wtClean, "firebase.json", textContent: "{}")

        // 1. node_modules with lockfile -> SAFE
        try writeFile(wtClean, "node_modules/react/index.js", sizeBytes: 16384)
        let nmMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtClean.appendingPathComponent("node_modules").path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(nmMatch.artifactType, .nodeModules)
        XCTAssertEqual(nmMatch.classification, .safe)
        XCTAssertTrue(nmMatch.reason.contains("package-lock.json"))

        // 2. .next with next.config.mjs -> SAFE
        try writeFile(wtClean, ".next/static/chunks/main.js", sizeBytes: 16384)
        let nextMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtClean.appendingPathComponent(".next").path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(nextMatch.artifactType, .nextBuild)
        XCTAssertEqual(nextMatch.classification, .safe)

        // 3. .turbo with turbo.json -> SAFE
        try writeFile(wtClean, ".turbo/cache/hash1.tar.zst", sizeBytes: 8192)
        let turboMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtClean.appendingPathComponent(".turbo").path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(turboMatch.artifactType, .turboCache)
        XCTAssertEqual(turboMatch.classification, .safe)

        // 4. dist / build with tsconfig.json & build script -> SAFE
        try writeFile(wtClean, "dist/index.js", sizeBytes: 8192)
        let distMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtClean.appendingPathComponent("dist").path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(distMatch.artifactType, .distOutput)
        XCTAssertEqual(distMatch.classification, .safe)

        // 5. Generated TypeScript metadata (tsconfig.tsbuildinfo) -> SAFE
        let tsBuildInfoURL = try writeFile(wtClean, "tsconfig.tsbuildinfo", sizeBytes: 4096)
        let tsMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: tsBuildInfoURL.path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(tsMatch.artifactType, .typescriptMetadata)
        XCTAssertEqual(tsMatch.classification, .safe)

        // 6. Downloadable Firebase emulator cache (.cache/firebase/emulators) -> SAFE
        try writeFile(wtClean, ".cache/firebase/emulators/cloud-firestore-emulator-v1.19.0.jar", sizeBytes: 16384)
        let fbMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtClean.appendingPathComponent(".cache/firebase/emulators").path,
            worktreeRoot: wtClean.path
        ))
        XCTAssertEqual(fbMatch.artifactType, .firebaseEmulatorCache)
        XCTAssertEqual(fbMatch.classification, .safe)

        // 7. Worktree WITHOUT lockfile or build script -> node_modules, build, dist, and unknown .cache must be REVIEW
        let wtUnverified = repo.appendingPathComponent(".claude/worktrees/unverified-wt", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtUnverified, worktreeID: "unverified-wt")
        try writeFile(wtUnverified, "package.json", textContent: "{\"name\":\"bare-pkg\"}")
        try writeFile(wtUnverified, "node_modules/pkg/index.js", sizeBytes: 8192)
        try writeFile(wtUnverified, "build/custom.bin", sizeBytes: 8192)
        try writeFile(wtUnverified, "dist/bundle.js", sizeBytes: 8192)
        try writeFile(wtUnverified, ".cache/custom-mystery-folder/data.bin", sizeBytes: 8192)

        let nmNoLock = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtUnverified.appendingPathComponent("node_modules").path,
            worktreeRoot: wtUnverified.path
        ))
        XCTAssertEqual(nmNoLock.classification, .review, "node_modules without lockfile must be classified as REVIEW")

        let buildNoConfig = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtUnverified.appendingPathComponent("build").path,
            worktreeRoot: wtUnverified.path
        ))
        XCTAssertEqual(buildNoConfig.classification, .review, "Arbitrary build folder without build config/script must be REVIEW")

        let distNoConfig = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtUnverified.appendingPathComponent("dist").path,
            worktreeRoot: wtUnverified.path
        ))
        XCTAssertEqual(distNoConfig.classification, .review, "Arbitrary dist folder without build config/script must be REVIEW")

        let mysteryCache = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: wtUnverified.appendingPathComponent(".cache").path,
            worktreeRoot: wtUnverified.path
        ))
        XCTAssertEqual(mysteryCache.classification, .review, "Unverified .cache folder must be REVIEW")
    }

    // MARK: - 3. Protection of .env*, Databases, Migrations, Uploads, Credentials, Certificates & QA Evidence

    func testEnvDatabaseCredentialsAndProtectedDataAreNeverClassifiedSafeOrDeleted() throws {
        let repo = tempDevRoot.appendingPathComponent("secure-app", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/wt-secure", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "wt-secure")
        try writeFile(wt, "package.json", textContent: "{\"name\":\"secure-app\",\"scripts\":{\"build\":\"tsc\"}}")
        try writeFile(wt, "package-lock.json", textContent: "{}")
        try writeFile(wt, "tsconfig.json", textContent: "{}")

        // 1. Direct .env* files in worktree root are rejected by SafetyValidator
        let envLocal = try writeFile(wt, ".env.local", textContent: "API_SECRET=xyz")
        XCTAssertNil(validator.inspectWorktreeArtifactSafety(at: envLocal.path, worktreeRoot: wt.path))
        XCTAssertThrowsError(try validator.validateVerifiedWorktreeArtifactForDeletion(envLocal.path, worktreeRoot: wt.path))

        // 2. A build directory containing a hidden .env.production file -> downgraded to REVIEW and blocked from deletion
        let buildWithEnv = wt.appendingPathComponent("build", isDirectory: true)
        try writeFile(buildWithEnv, "index.js", sizeBytes: 4096)
        try writeFile(buildWithEnv, ".env.production", textContent: "PROD_KEY=123")

        let buildEnvMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: buildWithEnv.path, worktreeRoot: wt.path))
        XCTAssertEqual(buildEnvMatch.classification, .review)
        XCTAssertTrue(buildEnvMatch.reason.contains(".env.production"))
        XCTAssertThrowsError(try validator.validateVerifiedWorktreeArtifactForDeletion(buildWithEnv.path, worktreeRoot: wt.path))

        // 3. A dist directory containing a SQLite database (.sqlite / .db) or migrations or uploads -> REVIEW & blocked
        let distWithDB = wt.appendingPathComponent("dist", isDirectory: true)
        try writeFile(distWithDB, "bundle.js", sizeBytes: 4096)
        try writeFile(distWithDB, "local.sqlite3", sizeBytes: 4096)

        let distDBMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: distWithDB.path, worktreeRoot: wt.path))
        XCTAssertEqual(distDBMatch.classification, .review)
        XCTAssertThrowsError(try validator.validateVerifiedWorktreeArtifactForDeletion(distWithDB.path, worktreeRoot: wt.path))

        // 4. A .cache directory containing QA evidence or certificates -> REVIEW & blocked
        let cacheWithEvidence = wt.appendingPathComponent(".cache", isDirectory: true)
        try writeFile(cacheWithEvidence, "qa-evidence/screenshot.png", sizeBytes: 4096)
        let cacheEvMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: cacheWithEvidence.path, worktreeRoot: wt.path))
        XCTAssertEqual(cacheEvMatch.classification, .review)
        XCTAssertThrowsError(try validator.validateVerifiedWorktreeArtifactForDeletion(cacheWithEvidence.path, worktreeRoot: wt.path))
    }

    // MARK: - 4. Symlink Escape & Path Containment Protection

    func testSymlinkEscapeAndPathContainmentProtection() throws {
        let repo = tempDevRoot.appendingPathComponent("symlink-repo", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/wt-symlink", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "wt-symlink")
        try writeFile(wt, "package.json", textContent: "{\"name\":\"symlink-repo\"}")
        try writeFile(wt, "package-lock.json", textContent: "{}")

        // Create an outside directory that must NEVER be touched
        let outsideSecretDir = tempRoot.appendingPathComponent("OutsideSecretData", isDirectory: true)
        let secretFile = try writeFile(outsideSecretDir, "secret.txt", textContent: "DO NOT DELETE")

        // 1. Worktree root itself must NEVER be allowed for deletion
        XCTAssertThrowsError(
            try validator.validateVerifiedWorktreeArtifactForDeletion(wt.path, worktreeRoot: wt.path)
        ) { error in
            guard case SafetyError.forbiddenProtectedPath = error else {
                XCTFail("Expected forbiddenProtectedPath when attempting to delete worktree root itself, got \(error)")
                return
            }
        }

        // 2. Path outside worktree root or containing `..` parent traversal must be rejected
        XCTAssertThrowsError(
            try validator.validateVerifiedWorktreeArtifactForDeletion(
                "\(wt.path)/../OutsideSecretData",
                worktreeRoot: wt.path
            )
        ) { error in
            guard case SafetyError.containsParentTraversal = error else {
                XCTFail("Expected containsParentTraversal, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(
            try validator.validateVerifiedWorktreeArtifactForDeletion(
                outsideSecretDir.path,
                worktreeRoot: wt.path
            )
        )

        // 3. Top-level artifact that is itself a symlink pointing outside worktree -> REVIEW & rejected
        let nextSymlink = wt.appendingPathComponent(".next")
        try FileManager.default.createSymbolicLink(at: nextSymlink, withDestinationURL: outsideSecretDir)
        let topSymlinkMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: nextSymlink.path, worktreeRoot: wt.path))
        XCTAssertEqual(topSymlinkMatch.classification, .review)
        XCTAssertThrowsError(
            try validator.validateVerifiedWorktreeArtifactForDeletion(nextSymlink.path, worktreeRoot: wt.path)
        ) { error in
            guard case SafetyError.symlinkTraversalRejected = error else {
                XCTFail("Expected symlinkTraversalRejected, got \(error)")
                return
            }
        }

        // 4. Nested symlink inside `node_modules` escaping outside the worktree -> REVIEW & rejected
        let nmDir = wt.appendingPathComponent("node_modules", isDirectory: true)
        try writeFile(nmDir, "valid-pkg/index.js", sizeBytes: 4096)
        let escapingLink = nmDir.appendingPathComponent("valid-pkg/escape-link")
        try FileManager.default.createSymbolicLink(atPath: escapingLink.path, withDestinationPath: "../../../../../OutsideSecretData")

        let nestedEscapeMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: nmDir.path, worktreeRoot: wt.path))
        XCTAssertEqual(nestedEscapeMatch.classification, .review, "Nested symlink escaping worktree must downgrade artifact to REVIEW")
        XCTAssertThrowsError(
            try validator.validateVerifiedWorktreeArtifactForDeletion(nmDir.path, worktreeRoot: wt.path)
        ) { error in
            guard case SafetyError.symlinkTraversalRejected = error else {
                XCTFail("Expected symlinkTraversalRejected for nested escaping symlink, got \(error)")
                return
            }
        }

        // 5. Internal relative symlink that stays strictly INSIDE the worktree (e.g. node_modules/.bin/cli -> ../valid-pkg/index.js) IS allowed
        try FileManager.default.removeItem(at: escapingLink)
        let binDir = nmDir.appendingPathComponent(".bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let internalLink = binDir.appendingPathComponent("valid-cli")
        try FileManager.default.createSymbolicLink(atPath: internalLink.path, withDestinationPath: "../valid-pkg/index.js")

        let validInternalSymlinkMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(at: nmDir.path, worktreeRoot: wt.path))
        XCTAssertEqual(validInternalSymlinkMatch.classification, .safe, "Internal symlink within worktree boundary should be SAFE")
        XCTAssertNoThrow(try validator.validateVerifiedWorktreeArtifactForDeletion(nmDir.path, worktreeRoot: wt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))
    }

    // MARK: - 5. Tracked-File Protection, Dirty-Worktree Behavior & Inactivity Thresholds

    func testTrackedFileProtectionDirtyWorktreeAndInactivityThresholds() async throws {
        let repo = tempDevRoot.appendingPathComponent("monorepo-app", isDirectory: true)
        let wtCleanStale = repo.appendingPathComponent(".claude/worktrees/stale-clean", isDirectory: true)
        let wtDirty = repo.appendingPathComponent(".claude/worktrees/dirty-wt", isDirectory: true)
        let wtTrackedDist = repo.appendingPathComponent(".claude/worktrees/tracked-dist-wt", isDirectory: true)

        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtCleanStale, worktreeID: "stale-clean")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtDirty, worktreeID: "dirty-wt")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtTrackedDist, worktreeID: "tracked-dist-wt")

        for wt in [wtCleanStale, wtDirty, wtTrackedDist] {
            try writeFile(wt, "package.json", textContent: "{\"name\":\"monorepo\",\"scripts\":{\"build\":\"tsc\"}}")
            try writeFile(wt, "package-lock.json", textContent: "{}")
            try writeFile(wt, "tsconfig.json", textContent: "{}")
            try writeFile(wt, "node_modules/lodash/index.js", sizeBytes: 16384)
            try writeFile(wt, "dist/bundle.js", sizeBytes: 8192)
        }

        // Backdate files in wtCleanStale to 16 days ago (> 14d strong candidate threshold)
        let sixteenDaysAgo = Date().addingTimeInterval(-16 * 86400)
        try FileManager.default.setAttributes([.modificationDate: sixteenDaysAgo], ofItemAtPath: wtCleanStale.path)
        let sixteenDaysAgoEpoch = Int(sixteenDaysAgo.timeIntervalSince1970)
        let oneDayAgoEpoch = Int(Date().addingTimeInterval(-1 * 86400).timeIntervalSince1970)

        let repoPath = repo.standardizedFileURL.path
        let stalePath = wtCleanStale.standardizedFileURL.path
        let dirtyPath = wtDirty.standardizedFileURL.path
        let trackedPath = wtTrackedDist.standardizedFileURL.path

        let analyzer = GitWorktreeAnalyzer(
            validator: validator,
            shellRunner: { _, args in
                if args.contains("worktree") && args.contains("list") {
                    let out = """
                    worktree \(repoPath)
                    HEAD 1111111122222222333333334444444455555555
                    branch refs/heads/main

                    worktree \(stalePath)
                    HEAD aaaaaaaa22222222333333334444444455555555
                    branch refs/heads/claude/stale-clean

                    worktree \(dirtyPath)
                    HEAD bbbbbbbb22222222333333334444444455555555
                    branch refs/heads/claude/dirty-wt

                    worktree \(trackedPath)
                    HEAD cccccccc22222222333333334444444455555555
                    branch refs/heads/claude/tracked-dist
                    """
                    return ShellResult(exitCode: 0, stdout: out, stderr: "")
                }
                if args.contains("status") {
                    if args.contains(dirtyPath) {
                        return ShellResult(
                            exitCode: 0,
                            stdout: "## claude/dirty-wt\n M src/index.ts\n?? src/new_untracked.ts\n",
                            stderr: ""
                        )
                    }
                    return ShellResult(exitCode: 0, stdout: "## branch\n", stderr: "")
                }
                if args.contains("log") {
                    if args.contains(stalePath) {
                        return ShellResult(exitCode: 0, stdout: "\(sixteenDaysAgoEpoch)\n", stderr: "")
                    }
                    return ShellResult(exitCode: 0, stdout: "\(oneDayAgoEpoch)\n", stderr: "")
                }
                if args.contains("ls-files") {
                    if args.contains(trackedPath) {
                        // Simulate `dist/bundle.js` being tracked by Git!
                        return ShellResult(exitCode: 0, stdout: "package.json\ndist/bundle.js\n", stderr: "")
                    }
                    return ShellResult(exitCode: 0, stdout: "package.json\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        // Backdate all files inside wtCleanStale so lastModified is also 16 days ago
        let staleAllURLs = (FileManager.default.enumerator(at: wtCleanStale, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for fileURL in staleAllURLs {
            try? FileManager.default.setAttributes([.modificationDate: sixteenDaysAgo], ofItemAtPath: fileURL.path)
        }

        let records = await analyzer.analyzeWorktrees(in: tempDevRoot.path, snapshot: .empty)
        XCTAssertEqual(records.count, 3)

        // 1. Clean Stale worktree (16 days old) -> activityState == .staleStrongCandidate, artifacts are SAFE
        let staleRec = try XCTUnwrap(records.first { $0.path == stalePath })
        XCTAssertFalse(staleRec.isActiveOrRecent)
        XCTAssertEqual(staleRec.activityState, .staleStrongCandidate)
        XCTAssertTrue(staleRec.artifactCandidates.allSatisfy { $0.classification == .safe })

        // 2. Dirty worktree -> all artifacts conservatively classified as REVIEW
        let dirtyRec = try XCTUnwrap(records.first { $0.path == dirtyPath })
        XCTAssertTrue(dirtyRec.hasUncommittedChanges)
        XCTAssertTrue(dirtyRec.isActiveOrRecent)
        XCTAssertTrue(dirtyRec.artifactCandidates.allSatisfy { $0.classification == .review })
        XCTAssertTrue(dirtyRec.artifactCandidates.allSatisfy { $0.reclaimableBytes == 0 })
        XCTAssertTrue(dirtyRec.artifactCandidates.first?.classificationReason.contains("uncommitted changes") == true)

        // 3. Worktree with tracked file inside `dist/bundle.js` -> `dist` is classified as REVIEW, while untracked `node_modules` is SAFE
        let trackedRec = try XCTUnwrap(records.first { $0.path == trackedPath })
        let trackedDistCand = try XCTUnwrap(trackedRec.artifactCandidates.first { $0.relativePath == "dist" })
        let untrackedNMCand = try XCTUnwrap(trackedRec.artifactCandidates.first { $0.relativePath == "node_modules" })
        XCTAssertEqual(trackedDistCand.classification, .review, "dist containing a Git-tracked file must be REVIEW")
        XCTAssertTrue(trackedDistCand.classificationReason.contains("Git-tracked file"))
        XCTAssertEqual(untrackedNMCand.classification, .safe, "Untracked node_modules in same clean worktree remains SAFE")
    }

    // MARK: - 6. Real Git Repository & Worktree End-to-End Cleanup Preserving Git Status & Calculating Exact Reclaimed Size

    func testEndToEndCleanupReclaimsExactSpaceAndPreservesGitStatusAndWorktreeRegistration() async throws {
        // Create a real Git repository and a real linked worktree using `/usr/bin/git`
        let mainRepo = tempDevRoot.appendingPathComponent("real-git-project", isDirectory: true)
        try FileManager.default.createDirectory(at: mainRepo, withIntermediateDirectories: true)

        func runGit(_ dir: URL, _ args: [String]) async throws -> String {
            let res = await ShellRunner.shared.run("/usr/bin/git", arguments: ["-C", dir.path] + args)
            XCTAssertTrue(res.isSuccess, "git \(args.joined(separator: " ")) failed: \(res.stderr)")
            return res.stdout
        }

        _ = try await runGit(mainRepo, ["init", "-b", "main"])
        _ = try await runGit(mainRepo, ["config", "user.email", "test@example.com"])
        _ = try await runGit(mainRepo, ["config", "user.name", "Test User"])

        try writeFile(
            mainRepo,
            ".gitignore",
            textContent: """
            node_modules/
            .next/
            .turbo/
            .cache/
            tsconfig.tsbuildinfo
            .env*
            """
        )
        try writeFile(mainRepo, "package.json", textContent: "{\"name\":\"real-git-project\",\"scripts\":{\"build\":\"next build\"}}")
        try writeFile(mainRepo, "package-lock.json", textContent: "{\"lockfileVersion\":3}")
        try writeFile(mainRepo, "next.config.mjs", textContent: "export default {}")
        try writeFile(mainRepo, "tsconfig.json", textContent: "{}")
        let trackedSourceFile = try writeFile(mainRepo, "src/index.ts", textContent: "export const hello = 'world';\n")

        _ = try await runGit(mainRepo, ["add", "."])
        _ = try await runGit(mainRepo, ["commit", "-m", "Initial commit"])

        // Create a real Claude worktree via `git worktree add`
        let claudeWT = mainRepo.appendingPathComponent(".claude/worktrees/feature-cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeWT.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await runGit(mainRepo, ["worktree", "add", "-b", "claude/feature-cleanup", claudeWT.path, "main"])

        // Populate worktree with:
        // - Protected .env.local file (must survive)
        // - SAFE regenerable artifacts: node_modules, .next, tsconfig.tsbuildinfo
        // - REVIEW unverified artifact: build/custom-unverified.bin (no Gradle/Xcode marker and build not verified for custom.bin without tsconfig? Wait: tsconfig exists, so let's use `.cache/unverified-data/blob.bin` as REVIEW!)
        let wtEnvFile = try writeFile(claudeWT, ".env.local", textContent: "STRIPE_SECRET=sk_test_12345\n")
        let nmFile = try writeFile(claudeWT, "node_modules/next/dist/server.js", sizeBytes: 65536)
        let nextFile = try writeFile(claudeWT, ".next/cache/webpack/chunk.pack", sizeBytes: 32768)
        let tsBuildInfo = try writeFile(claudeWT, "tsconfig.tsbuildinfo", sizeBytes: 8192)
        let unverifiedCacheFile = try writeFile(claudeWT, ".cache/custom-mystery/data.bin", sizeBytes: 16384)

        let statusBeforeCleanup = try await runGit(claudeWT, ["status", "--porcelain"])
        XCTAssertEqual(statusBeforeCleanup, "", "Worktree git status should be completely clean before cleanup")

        let analyzer = GitWorktreeAnalyzer(validator: validator)
        let records = await analyzer.analyzeWorktrees(in: tempDevRoot.path, snapshot: .empty)
        let wtRecord = try XCTUnwrap(records.first { $0.worktreeName == "feature-cleanup" })

        let safeCandidates = wtRecord.artifactCandidates.filter { $0.classification == .safe }
        let reviewCandidates = wtRecord.artifactCandidates.filter { $0.classification == .review }

        XCTAssertEqual(Set(safeCandidates.map(\.relativePath)), Set(["node_modules", ".next", "tsconfig.tsbuildinfo"]))
        XCTAssertTrue(reviewCandidates.contains { $0.relativePath.hasPrefix(".cache") })

        let expectedSafeBytes = safeCandidates.reduce(Int64(0)) { $0 + $1.physicalBytes }
        XCTAssertGreaterThan(expectedSafeBytes, 0)

        // Pass ALL candidates (both SAFE and REVIEW) to cleanWorktreeArtifacts — it must delete ONLY SAFE and skip REVIEW
        let trashDir = self.tempTrash!
        let report = await analyzer.cleanWorktreeArtifacts(
            candidates: wtRecord.artifactCandidates,
            trashHandler: { url in
                let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
            }
        )

        // Verify exact reclaimed bytes and skipped items
        XCTAssertEqual(report.reclaimedBytes, expectedSafeBytes, "Reclaimed bytes must match exact physical size of cleaned SAFE artifacts")
        XCTAssertEqual(report.cleanedPaths.count, 3)
        XCTAssertEqual(report.skippedItems.count, reviewCandidates.count, "REVIEW candidates must be skipped and reported")
        XCTAssertTrue(report.gitStatusPreserved, "Git status must be verified preserved after cleanup")

        // Verify SAFE artifacts were removed from worktree
        XCTAssertFalse(FileManager.default.fileExists(atPath: nmFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tsBuildInfo.path))

        // Verify REVIEW artifact, .env.local, tracked source code, worktree root, and .git registration remain untouched!
        XCTAssertTrue(FileManager.default.fileExists(atPath: unverifiedCacheFile.path), "REVIEW artifact must not be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtEnvFile.path), ".env.local must never be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeWT.appendingPathComponent("src/index.ts").path), "Source files must never be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackedSourceFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeWT.appendingPathComponent(".git").path), "Worktree .git file must remain intact")

        // Verify `git status --porcelain` and `git worktree list` after cleanup are 100% unchanged
        let statusAfterCleanup = try await runGit(claudeWT, ["status", "--porcelain"])
        XCTAssertEqual(statusAfterCleanup, statusBeforeCleanup, "git status --porcelain must be identical after cleanup")

        let wtListAfter = try await runGit(mainRepo, ["worktree", "list", "--porcelain"])
        XCTAssertTrue(wtListAfter.contains(claudeWT.standardizedFileURL.path), "Worktree registration must remain intact")
    }

    // MARK: - 7. CleanupExecutor Worktree Action Execution & Safety Blocks

    func testCleanupExecutorWorktreeArtifactExecutionAndSafetyBlocks() async throws {
        let repo = tempDevRoot.appendingPathComponent("executor-repo", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/exec-wt", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "exec-wt")
        try writeFile(wt, "package.json", textContent: "{\"name\":\"executor-repo\"}")
        try writeFile(wt, "package-lock.json", textContent: "{\"lockfileVersion\":3}")
        let nmFile = try writeFile(wt, "node_modules/pkg/index.js", sizeBytes: 16384)
        let nmPath = wt.appendingPathComponent("node_modules").path

        let trashDir = self.tempTrash!
        let executor = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            trashHandler: { url in
                let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
            },
            shellRunner: { _, args in
                if args.contains("ls-files") {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        // 1. REVIEW worktree item must be blocked by CleanupExecutor even if passed `.moveToTrashVerifiedWorktreeArtifact`
        let reviewItem = CleanableItem(
            id: "worktree-artifact-review-test",
            name: "executor-repo / exec-wt — node_modules",
            category: .aiWorktreeArtifacts,
            path: nmPath,
            logicalSize: 16384,
            physicalSize: 16384,
            reclaimableSize: 16384,
            lastModified: nil,
            riskLevel: .review,
            explanation: "Needs review",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashVerifiedWorktreeArtifact(
                path: nmPath,
                worktreeRoot: wt.path,
                sourceRepoRoot: repo.path,
                expectedModifiedAt: nil
            )
        )
        do {
            _ = try await executor.execute(reviewItem)
            XCTFail("Expected CleanerError.readOnlyItem for REVIEW worktree artifact")
        } catch is CleanerError {
            // Expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nmFile.path))

        // 2. SAFE worktree item succeeds and moves only the verified artifact to Trash
        let safeItem = CleanableItem(
            id: "worktree-artifact-safe-test",
            name: "executor-repo / exec-wt — node_modules",
            category: .aiWorktreeArtifacts,
            path: nmPath,
            logicalSize: 16384,
            physicalSize: 16384,
            reclaimableSize: 16384,
            lastModified: nil,
            riskLevel: .safe,
            explanation: "Untracked dependency directory; reproducible from package-lock.json",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashVerifiedWorktreeArtifact(
                path: nmPath,
                worktreeRoot: wt.path,
                sourceRepoRoot: repo.path,
                expectedModifiedAt: nil
            )
        )
        let res = try await executor.execute(safeItem)
        XCTAssertEqual(res.status, .cleaned)
        XCTAssertGreaterThan(res.movedToTrashBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nmFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent("package.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent(".git").path))
    }

    // MARK: - 8. Regression Test: Tightened build/dist Classification & apps/mobile/ios/build Protection

    func testTightenedBuildAndDistClassificationAndIosBuildRegression() throws {
        let repo = tempDevRoot.appendingPathComponent("field-service-app", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/iphone-latest", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "iphone-latest")

        // Root has package.json with build script AND tsconfig.json
        try writeFile(
            wt,
            "package.json",
            textContent: """
            {
              "name": "field-service-app",
              "scripts": {
                "build": "tsc"
              }
            }
            """
        )
        try writeFile(wt, "tsconfig.json", textContent: "{\"compilerOptions\":{\"outDir\":\"dist\"}}")

        // 1. Real-world regression case: `apps/mobile/ios/build` inside a monorepo that has a root `tsconfig.json`
        let iosDir = wt.appendingPathComponent("apps/mobile/ios", isDirectory: true)
        try writeFile(iosDir, "Podfile", textContent: "platform :ios, '15.1'")
        try writeFile(iosDir, "Podfile.lock", textContent: "PODS:")
        try FileManager.default.createDirectory(at: iosDir.appendingPathComponent("FieldService.xcodeproj"), withIntermediateDirectories: true)
        try writeFile(iosDir, "build/generated/ios/ReactCodegen.podspec", sizeBytes: 8192)

        let iosBuildMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: iosDir.appendingPathComponent("build").path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(
            iosBuildMatch.classification,
            .review,
            "apps/mobile/ios/build must NOT become SAFE merely because a tsconfig.json exists in the project root"
        )
        XCTAssertThrowsError(try validator.validateVerifiedWorktreeArtifactForDeletion(
            iosDir.appendingPathComponent("build").path,
            worktreeRoot: wt.path
        ))

        // 2. Generic `tsconfig.json` ALONE (without a package.json build/compile/bundle script) must NOT make `build` or `dist` SAFE
        let subPkgWithoutBuildScript = wt.appendingPathComponent("packages/tsconfig-only", isDirectory: true)
        try writeFile(subPkgWithoutBuildScript, "package.json", textContent: "{\"name\":\"@app/tsconfig-only\",\"scripts\":{\"test\":\"vitest\"}}")
        try writeFile(subPkgWithoutBuildScript, "tsconfig.json", textContent: "{}")
        try writeFile(subPkgWithoutBuildScript, "build/index.js", sizeBytes: 4096)
        try writeFile(subPkgWithoutBuildScript, "dist/index.js", sizeBytes: 4096)

        let buildTsconfigOnly = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: subPkgWithoutBuildScript.appendingPathComponent("build").path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(buildTsconfigOnly.classification, .review, "tsconfig.json alone without a build script must NOT classify build as SAFE")

        let distTsconfigOnly = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: subPkgWithoutBuildScript.appendingPathComponent("dist").path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(distTsconfigOnly.classification, .review, "tsconfig.json alone without a build script must NOT classify dist as SAFE")

        // 3. Recognized Xcode build directory (with XCBuildData + Intermediates.noindex + Build/Products) IS SAFE when unsigned intermediates
        let validXcodeBuild = iosDir.appendingPathComponent("XcodeDerivedBuild/build", isDirectory: true)
        try writeFile(validXcodeBuild, "XCBuildData/build.db", sizeBytes: 4096)
        try writeFile(validXcodeBuild, "Intermediates.noindex/Pods.build/Debug-iphonesimulator/obj.o", sizeBytes: 4096)
        try writeFile(validXcodeBuild, "Build/Products/Debug-iphonesimulator/ libPods.a", sizeBytes: 4096)
        let validXcodeMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: validXcodeBuild.path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(validXcodeMatch.classification, .safe)

        // 4. Protected release/signing/symbol artifacts inside `build` (.xcarchive, .ipa, signed .app, .dSYM, DistributionSummary.plist) are NEVER SAFE
        let signedAppBuild = wt.appendingPathComponent("packages/signed-app/build", isDirectory: true)
        try writeFile(signedAppBuild, "XCBuildData/manifest.json", sizeBytes: 1024)
        try writeFile(signedAppBuild, "Intermediates.noindex/intermediate.o", sizeBytes: 1024)
        try writeFile(signedAppBuild, "Build/Products/Release-iphoneos/MyApp.app/_CodeSignature/CodeResources", sizeBytes: 2048)
        let signedAppMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: signedAppBuild.path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(signedAppMatch.classification, .review, "Signed .app inside build must never be automatically classified SAFE")

        let dsymBuild = wt.appendingPathComponent("packages/dsym-app/build", isDirectory: true)
        try writeFile(dsymBuild, "XCBuildData/manifest.json", sizeBytes: 1024)
        try writeFile(dsymBuild, "Intermediates.noindex/intermediate.o", sizeBytes: 1024)
        try writeFile(dsymBuild, "Build/Products/Release-iphoneos/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp", sizeBytes: 4096)
        let dsymMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: dsymBuild.path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(dsymMatch.classification, .review, ".dSYM bundle inside build must never be automatically classified SAFE")

        let archiveBuild = wt.appendingPathComponent("packages/archive-app/build", isDirectory: true)
        try writeFile(archiveBuild, "XCBuildData/manifest.json", sizeBytes: 1024)
        try writeFile(archiveBuild, "Intermediates.noindex/intermediate.o", sizeBytes: 1024)
        try writeFile(archiveBuild, "MyApp.xcarchive/Info.plist", sizeBytes: 1024)
        let archiveMatch = try XCTUnwrap(validator.inspectWorktreeArtifactSafety(
            at: archiveBuild.path,
            worktreeRoot: wt.path
        ))
        XCTAssertEqual(archiveMatch.classification, .review, ".xcarchive inside build must never be automatically classified SAFE")
    }

    // MARK: - 9. Git Ignored vs Visible Untracked vs Tracked Semantics

    func testGitIgnoredVsVisibleUntrackedVsTrackedSemantics() async throws {
        let repo = tempDevRoot.appendingPathComponent("git-semantics-repo", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/wt-git-states", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "wt-git-states")

        try writeFile(wt, "package.json", textContent: "{\"name\":\"git-semantics-repo\",\"scripts\":{\"build\":\"tsc\"}}")
        try writeFile(wt, "package-lock.json", textContent: "{\"lockfileVersion\":3}")
        try writeFile(wt, "tsconfig.json", textContent: "{}")

        // 1. node_modules -> Git: ignored
        try writeFile(wt, "node_modules/pkg/index.js", sizeBytes: 16384)
        // 2. build -> visible untracked (`?? build/` in git status, NOT ignored by .gitignore)
        try writeFile(wt, "build/index.js", sizeBytes: 8192)
        // 3. dist -> tracked by Git (`dist/bundle.js` in git ls-files)
        try writeFile(wt, "dist/bundle.js", sizeBytes: 8192)

        let repoPath = repo.standardizedFileURL.path
        let wtPath = wt.standardizedFileURL.path
        let tenDaysAgoEpoch = Int(Date().addingTimeInterval(-10 * 86400).timeIntervalSince1970)

        let analyzer = GitWorktreeAnalyzer(
            validator: validator,
            shellRunner: { _, args in
                if args.contains("worktree") && args.contains("list") {
                    let out = """
                    worktree \(repoPath)
                    HEAD 1111111122222222333333334444444455555555
                    branch refs/heads/main

                    worktree \(wtPath)
                    HEAD aaaaaaaa22222222333333334444444455555555
                    branch refs/heads/claude/wt-git-states
                    """
                    return ShellResult(exitCode: 0, stdout: out, stderr: "")
                }
                if args.contains("status") {
                    // `build/` appears as visible untracked (`??`) in `git status --porcelain`
                    return ShellResult(exitCode: 0, stdout: "## claude/wt-git-states\n?? build/\n", stderr: "")
                }
                if args.contains("log") {
                    return ShellResult(exitCode: 0, stdout: "\(tenDaysAgoEpoch)\n", stderr: "")
                }
                if args.contains("ls-files") {
                    if args.last == "dist" {
                        return ShellResult(exitCode: 0, stdout: "dist/bundle.js\n", stderr: "")
                    }
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                if args.contains("check-ignore") {
                    if args.last == "node_modules" {
                        return ShellResult(exitCode: 0, stdout: "node_modules\n", stderr: "")
                    }
                    // `build` is NOT ignored -> exitCode 1
                    return ShellResult(exitCode: 1, stdout: "", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let records = await analyzer.analyzeWorktrees(in: tempDevRoot.path, snapshot: .empty)
        let record = try XCTUnwrap(records.first)

        // Ignored node_modules => SAFE with `Git: ignored`
        let nmCand = try XCTUnwrap(record.artifactCandidates.first { $0.relativePath == "node_modules" })
        XCTAssertEqual(nmCand.gitTrackingState, .ignored)
        XCTAssertEqual(nmCand.gitTrackingState.rawValue, "Git: ignored")
        XCTAssertEqual(nmCand.classification, .safe)

        // Visible untracked build => REVIEW with `Git: untracked`
        let buildCand = try XCTUnwrap(record.artifactCandidates.first { $0.relativePath == "build" })
        XCTAssertEqual(buildCand.gitTrackingState, .untracked)
        XCTAssertEqual(buildCand.gitTrackingState.rawValue, "Git: untracked")
        XCTAssertEqual(buildCand.classification, .review, "Visible untracked build directory must default to REVIEW")
        XCTAssertTrue(buildCand.classificationReason.contains("Git: untracked"))

        // Tracked dist => REVIEW with `Git: tracked`
        let distCand = try XCTUnwrap(record.artifactCandidates.first { $0.relativePath == "dist" })
        XCTAssertEqual(distCand.gitTrackingState, .tracked)
        XCTAssertEqual(distCand.gitTrackingState.rawValue, "Git: tracked")
        XCTAssertEqual(distCand.classification, .review, "Tracked content must never be SAFE")
        XCTAssertTrue(distCand.classificationReason.contains("Git: tracked"))
    }

    // MARK: - 10. Fail-Closed Git Status Verification & Reversible Trash Rollback

    func testFailClosedPostCleanGitStatusVerificationAndReversibleTrashRollback() async throws {
        let repo = tempDevRoot.appendingPathComponent("rollback-repo", isDirectory: true)
        let wt = repo.appendingPathComponent(".claude/worktrees/rollback-wt", isDirectory: true)
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wt, worktreeID: "rollback-wt")
        try writeFile(wt, "package.json", textContent: "{\"name\":\"rollback-repo\"}")
        try writeFile(wt, "package-lock.json", textContent: "{\"lockfileVersion\":3}")

        let nmDir = wt.appendingPathComponent("node_modules", isDirectory: true)
        let nmFile = try writeFile(nmDir, "pkg/index.js", sizeBytes: 16384)
        let trashDir = self.tempTrash!

        // Case 1: Unexpected Git status change after moving to Trash -> Rollback succeeds & cleanup is NOT reported as successful
        final class StatusSequenceCounter: @unchecked Sendable {
            var count = 0
        }
        let counter1 = StatusSequenceCounter()

        let executorRollbackSuccess = CleanupExecutor(
            validator: validator,
            freeSpaceProvider: { 100_000_000_000 },
            processChecker: { _ in [] },
            reversibleTrashHandler: { url in
                let dest = trashDir.appendingPathComponent("rollback-1-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            },
            shellRunner: { _, args in
                if args.contains("status") && args.contains("--porcelain") {
                    counter1.count += 1
                    if counter1.count == 1 {
                        // Before trashing: clean status
                        return ShellResult(exitCode: 0, stdout: "", stderr: "")
                    } else {
                        // After trashing: unexpected tracked file deletion appeared in git status!
                        return ShellResult(exitCode: 0, stdout: " D node_modules/tracked-secret.js\n", stderr: "")
                    }
                }
                if args.contains("ls-files") {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                if args.contains("check-ignore") {
                    return ShellResult(exitCode: 0, stdout: "node_modules\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let safeItem = CleanableItem(
            id: "worktree-artifact-safe-rollback",
            name: "rollback-repo / rollback-wt — node_modules",
            category: .aiWorktreeArtifacts,
            path: nmDir.path,
            logicalSize: 16384,
            physicalSize: 16384,
            reclaimableSize: 16384,
            lastModified: nil,
            riskLevel: .safe,
            explanation: "Git-ignored dependency directory; reproducible from package-lock.json",
            deletionConsequence: "",
            regenerationImpact: "",
            isRunningDependency: false,
            actionType: .moveToTrashVerifiedWorktreeArtifact(
                path: nmDir.path,
                worktreeRoot: wt.path,
                sourceRepoRoot: repo.path,
                expectedModifiedAt: nil
            )
        )

        let rollbackResult = try await executorRollbackSuccess.execute(safeItem)
        XCTAssertEqual(rollbackResult.status, .failed, "Unexpected git status change must NOT be reported as .cleaned")
        XCTAssertEqual(rollbackResult.movedToTrashBytes, 0)
        XCTAssertTrue(rollbackResult.message?.contains("rolled back") == true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nmFile.path),
            "Rollback must automatically restore the trashed artifact to its original path"
        )

        // Case 2: Unexpected Git status change when rollback destination ALREADY exists on disk -> NEVER overwrite newly recreated path; report CAUTION & Trash location
        let counter2 = StatusSequenceCounter()
        let recreatedMarkerText = "NEWLY_RECREATED_AFTER_TRASH_DO_NOT_OVERWRITE"

        let analyzerCollision = GitWorktreeAnalyzer(
            validator: validator,
            shellRunner: { _, args in
                if args.contains("status") && args.contains("--porcelain") {
                    counter2.count += 1
                    if counter2.count == 1 {
                        return ShellResult(exitCode: 0, stdout: "", stderr: "")
                    } else {
                        return ShellResult(exitCode: 0, stdout: " M package.json\n", stderr: "")
                    }
                }
                if args.contains("ls-files") {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                if args.contains("check-ignore") {
                    return ShellResult(exitCode: 0, stdout: "node_modules\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let candidate = WorktreeArtifactCandidate(
            id: safeItem.id,
            repositoryName: "rollback-repo",
            repositoryPath: repo.path,
            worktreeName: "rollback-wt",
            worktreePath: wt.path,
            originKind: .claudeWorktree,
            branchLabel: "claude/rollback",
            artifactName: "node_modules",
            relativePath: "node_modules",
            fullPath: nmDir.path,
            artifactType: .nodeModules,
            physicalBytes: 16384,
            logicalBytes: 16384,
            reclaimableBytes: 16384,
            lastModified: nil,
            classification: .safe,
            classificationReason: "Git-ignored dependency directory; reproducible from package-lock.json",
            gitTrackingState: .ignored,
            reproducibilitySource: "package-lock.json",
            isWorktreeDirty: false,
            isWorktreeActiveOrRecent: false,
            activityState: .staleStrongCandidate,
            cleanableItem: safeItem
        )

        let expectedTrashDest = trashDir.appendingPathComponent("rollback-collision-node_modules")
        let collisionReport = await analyzerCollision.cleanWorktreeArtifacts(
            candidates: [candidate],
            reversibleTrashHandler: { url in
                try FileManager.default.moveItem(at: url, to: expectedTrashDest)
                // Simulate a concurrent process recreating `node_modules/recreated.txt` before rollback runs
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try recreatedMarkerText.write(
                    to: url.appendingPathComponent("recreated.txt"),
                    atomically: true,
                    encoding: .utf8
                )
                return expectedTrashDest
            }
        )

        XCTAssertFalse(collisionReport.gitStatusPreserved)
        XCTAssertEqual(collisionReport.reclaimedBytes, 0, "Failed post-clean verification must report 0 reclaimed bytes")
        XCTAssertTrue(collisionReport.cleanedPaths.isEmpty)
        XCTAssertEqual(collisionReport.failedItems.count, 1)

        // Verify newly recreated path was NOT overwritten
        let survivingText = try String(contentsOf: nmDir.appendingPathComponent("recreated.txt"), encoding: .utf8)
        XCTAssertEqual(survivingText, recreatedMarkerText, "Rollback must never overwrite a newly recreated path")

        // Verify original artifact remains in Trash and user is clearly told where it is
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedTrashDest.appendingPathComponent("pkg/index.js").path))
        let failureReason = try XCTUnwrap(collisionReport.failedItems.first?.reason)
        XCTAssertTrue(failureReason.contains("CAUTION"))
        XCTAssertTrue(failureReason.contains(expectedTrashDest.path))
    }

    // MARK: - 11. Meaningful Activity Calculation (Git-Driven Signals Without Recursive Walk)

    func testMeaningfulActivityCalculationIgnoresGeneratedArtifactChurn() async throws {
        let repo = tempDevRoot.appendingPathComponent("activity-repo", isDirectory: true)
        let wtTouchedNodeModules = repo.appendingPathComponent(".claude/worktrees/wt-touched-nm", isDirectory: true)
        let wtModifiedSource = repo.appendingPathComponent(".claude/worktrees/wt-modified-src", isDirectory: true)
        let wtUntrackedSource = repo.appendingPathComponent(".claude/worktrees/wt-untracked-src", isDirectory: true)
        let wtRunningProcess = repo.appendingPathComponent(".claude/worktrees/wt-running-proc", isDirectory: true)
        let wtLocked = repo.appendingPathComponent(".claude/worktrees/wt-locked", isDirectory: true)

        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtTouchedNodeModules, worktreeID: "wt-touched-nm")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtModifiedSource, worktreeID: "wt-modified-src")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtUntrackedSource, worktreeID: "wt-untracked-src")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtRunningProcess, worktreeID: "wt-running-proc")
        try createVerifiedWorktreeFixture(mainRepoURL: repo, worktreeURL: wtLocked, worktreeID: "wt-locked", isLocked: true)

        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)
        let thirtyDaysAgoEpoch = Int(thirtyDaysAgo.timeIntervalSince1970)

        for wt in [wtTouchedNodeModules, wtModifiedSource, wtUntrackedSource, wtRunningProcess, wtLocked] {
            let pkgURL = try writeFile(wt, "package.json", textContent: "{\"name\":\"activity-repo\"}")
            let lockURL = try writeFile(wt, "package-lock.json", textContent: "{\"lockfileVersion\":3}")
            let srcURL = try writeFile(wt, "src/index.ts", textContent: "export const x = 1;\n")
            let nmURL = try writeFile(wt, "node_modules/pkg/index.js", sizeBytes: 16384)

            // Backdate all files to 30 days ago initially
            for url in [pkgURL, lockURL, srcURL, nmURL, wt.appendingPathComponent(".git")] {
                try FileManager.default.setAttributes([.modificationDate: thirtyDaysAgo], ofItemAtPath: url.path)
            }
        }

        // 1. In `wtTouchedNodeModules`, touch `node_modules/pkg/index.js` and `.next/cache/webpack.bin` to NOW
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: wtTouchedNodeModules.appendingPathComponent("node_modules/pkg/index.js").path
        )
        let nextCacheFile = try writeFile(wtTouchedNodeModules, ".next/cache/webpack.bin", sizeBytes: 4096)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: nextCacheFile.path)

        // 2. In `wtModifiedSource`, modify tracked `src/index.ts` to NOW (reported by git status)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: wtModifiedSource.appendingPathComponent("src/index.ts").path
        )

        // 3. In `wtUntrackedSource`, create visible untracked `src/new_feature.ts` at NOW (reported by git status)
        let untrackedSrcURL = try writeFile(wtUntrackedSource, "src/new_feature.ts", textContent: "export const y = 2;\n")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: untrackedSrcURL.path)

        let repoPath = repo.standardizedFileURL.path
        let nmWTPath = wtTouchedNodeModules.standardizedFileURL.path
        let srcWTPath = wtModifiedSource.standardizedFileURL.path
        let untrackedWTPath = wtUntrackedSource.standardizedFileURL.path
        let runWTPath = wtRunningProcess.standardizedFileURL.path
        let lockedWTPath = wtLocked.standardizedFileURL.path

        let analyzer = GitWorktreeAnalyzer(
            validator: validator,
            shellRunner: { _, args in
                if args.contains("worktree") && args.contains("list") {
                    let out = """
                    worktree \(repoPath)
                    HEAD 1111111122222222333333334444444455555555
                    branch refs/heads/main

                    worktree \(nmWTPath)
                    HEAD aaaaaaaa22222222333333334444444455555555
                    branch refs/heads/claude/wt-touched-nm

                    worktree \(srcWTPath)
                    HEAD bbbbbbbb22222222333333334444444455555555
                    branch refs/heads/claude/wt-modified-src

                    worktree \(untrackedWTPath)
                    HEAD dddddddd22222222333333334444444455555555
                    branch refs/heads/claude/wt-untracked-src

                    worktree \(runWTPath)
                    HEAD cccccccc22222222333333334444444455555555
                    branch refs/heads/claude/wt-running-proc

                    worktree \(lockedWTPath)
                    HEAD eeeeeeee22222222333333334444444455555555
                    branch refs/heads/claude/wt-locked
                    locked reason-in-progress
                    """
                    return ShellResult(exitCode: 0, stdout: out, stderr: "")
                }
                if args.contains("status") {
                    if args.contains(srcWTPath) {
                        return ShellResult(exitCode: 0, stdout: "## claude/wt-modified-src\n M src/index.ts\n", stderr: "")
                    }
                    if args.contains(untrackedWTPath) {
                        return ShellResult(exitCode: 0, stdout: "## claude/wt-untracked-src\n?? src/new_feature.ts\n", stderr: "")
                    }
                    return ShellResult(exitCode: 0, stdout: "## main\n", stderr: "")
                }
                if args.contains("log") {
                    // Last git commit in all worktrees was 30 days ago
                    return ShellResult(exitCode: 0, stdout: "\(thirtyDaysAgoEpoch)\n", stderr: "")
                }
                if args.contains("ls-files") {
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
                if args.contains("check-ignore") {
                    return ShellResult(exitCode: 0, stdout: "node_modules\n.next\n", stderr: "")
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        // Simulate a running process inside `wtRunningProcess`
        let snapshotWithRunningWT = ActiveProcessSnapshot(
            activeLines: ["node \(runWTPath)/node_modules/.bin/next dev"],
            runningAppNames: ["node"]
        )

        let records = await analyzer.analyzeWorktrees(
            in: tempDevRoot.path,
            referenceDate: now,
            snapshot: snapshotWithRunningWT
        )

        // 1. Touching node_modules / .next does NOT make an old worktree recent
        let nmRec = try XCTUnwrap(records.first { $0.path == nmWTPath })
        XCTAssertGreaterThanOrEqual(nmRec.inactiveDays, 29, "Touching node_modules/.next must NOT reset meaningful inactivity days")
        XCTAssertFalse(nmRec.isActiveOrRecent, "Touching node_modules/.next alone must NOT make an old worktree appear newly active")
        XCTAssertEqual(nmRec.activityState, .staleStrongCandidate)

        // 2. Tracked source modification reported by Git DOES make the worktree recent
        let srcRec = try XCTUnwrap(records.first { $0.path == srcWTPath })
        XCTAssertEqual(srcRec.inactiveDays, 0, "Modifying a tracked source/config file must update lastMeaningfulActivityDate")
        XCTAssertTrue(srcRec.isActiveOrRecent, "Worktree with recent tracked source file modification must be marked active/recent")
        XCTAssertEqual(srcRec.activityState, .recentlyUsed)

        // 3. Meaningful visible untracked source/config file reported by Git DOES make the worktree recent
        let untrackedRec = try XCTUnwrap(records.first { $0.path == untrackedWTPath })
        XCTAssertEqual(untrackedRec.inactiveDays, 0, "Visible untracked source/config file must update lastMeaningfulActivityDate")
        XCTAssertTrue(untrackedRec.isActiveOrRecent, "Worktree with recent visible untracked source file must be marked active/recent")
        XCTAssertEqual(untrackedRec.activityState, .recentlyUsed)

        // 4. Running process and locked worktree remain active/protected
        let runRec = try XCTUnwrap(records.first { $0.path == runWTPath })
        XCTAssertTrue(runRec.isInUseByProcess)
        XCTAssertTrue(runRec.isActiveOrRecent, "Worktree with running process must remain active/protected")
        XCTAssertTrue(runRec.artifactCandidates.allSatisfy { $0.classification == .review }, "Running worktree artifacts must be REVIEW")

        let lockedRec = try XCTUnwrap(records.first { $0.path == lockedWTPath })
        XCTAssertTrue(lockedRec.isLocked)
        XCTAssertTrue(lockedRec.isActiveOrRecent, "Locked worktree must remain active/protected")
        XCTAssertEqual(lockedRec.activityState, .recentlyUsed)
        XCTAssertTrue(lockedRec.artifactCandidates.allSatisfy { $0.classification == .review }, "Locked worktree artifacts must be REVIEW")
    }
}
