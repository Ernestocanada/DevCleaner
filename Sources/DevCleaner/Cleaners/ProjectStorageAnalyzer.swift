import Foundation

public final class ProjectStorageAnalyzer: Sendable {
    public let validator: SafetyValidator

    public init(validator: SafetyValidator = SafetyValidator()) {
        self.validator = validator
    }

    public static var defaultDeveloperRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
    }

    public func analyzeProjects(
        in rootPath: String = ProjectStorageAnalyzer.defaultDeveloperRoot,
        snapshot: ActiveProcessSnapshot,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async -> (reports: [ProjectStorageReport], summary: ProjectStorageSummary) {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return ([], ProjectStorageSummary.empty)
        }

        let projectDirectories = discoverProjectDirectories(at: rootURL)
        let totalCount = projectDirectories.count
        var reports: [ProjectStorageReport] = []
        reports.reserveCapacity(totalCount)

        for (index, projectURL) in projectDirectories.enumerated() {
            if shouldCancel?() == true || Task.isCancelled {
                break
            }
            onProgress?(index + 1, totalCount, projectURL.lastPathComponent)
            if let report = analyzeSingleProject(
                at: projectURL,
                snapshot: snapshot,
                shouldCancel: shouldCancel
            ) {
                reports.append(report)
            }
        }

        reports.sort { lhs, rhs in
            if lhs.totalPhysicalBytes != rhs.totalPhysicalBytes {
                return lhs.totalPhysicalBytes > rhs.totalPhysicalBytes
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let totalPhysical = reports.reduce(Int64(0)) { $0 + $1.totalPhysicalBytes }
        let totalSafe = reports.reduce(Int64(0)) { $0 + $1.safeRecoverableBytes }
        let totalReview = reports.reduce(Int64(0)) { $0 + $1.reviewRecoverableBytes }
        let totalWorktrees = reports.reduce(Int64(0)) { $0 + $1.worktreesBytes }
        let totalProtected = reports.reduce(Int64(0)) { $0 + $1.protectedBytes }

        let summary = ProjectStorageSummary(
            rootDirectoryPath: rootURL.path,
            totalProjectsCount: reports.count,
            totalProjectsPhysicalBytes: totalPhysical,
            regenerableCachesAndBuildsBytes: totalSafe,
            reviewRequiredBytes: totalReview,
            worktreesBytes: totalWorktrees,
            protectedDataBytes: totalProtected
        )

        return (reports, summary)
    }

    private func discoverProjectDirectories(at rootURL: URL) -> [URL] {
        let fm = FileManager.default
        // Check if rootURL itself is a single project directory rather than a workspace container
        let rootProjectMarkers = [".git", "package.json", "Package.swift", "Podfile", "build.gradle", "build.gradle.kts"]
        let isSingleProjectRoot = rootProjectMarkers.contains {
            fm.fileExists(atPath: rootURL.appendingPathComponent($0).path)
        }
        if isSingleProjectRoot && rootURL.lastPathComponent != "Developer" {
            return [rootURL]
        }

        guard let children = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.filter { url in
            guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true,
                  vals.isSymbolicLink != true else {
                return false
            }
            return true
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func analyzeSingleProject(
        at projectURL: URL,
        snapshot: ActiveProcessSnapshot,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) -> ProjectStorageReport? {
        if shouldCancel?() == true { return nil }

        let projectPath = projectURL.standardizedFileURL.path
        let projectName = projectURL.lastPathComponent
        let activeProcesses = snapshot.matchingProcesses(forProjectPath: projectPath)
        let isProjectBusy = !activeProcesses.isEmpty

        let projectTags = detectProjectTypeTags(at: projectURL)
        var artifacts: [ProjectArtifactEntry] = []
        var excludedFromProtectedScan = Set<String>()

        // 1. Check .claude/worktrees inside the project first (so we never treat files inside worktrees as top-level project caches)
        let claudeWorktreesURL = projectURL.appendingPathComponent(".claude/worktrees")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: claudeWorktreesURL.path, isDirectory: &isDir), isDir.boolValue {
            let wtPath = claudeWorktreesURL.standardizedFileURL.path
            let usage = DiskScanner.shared.measurePath(wtPath, shouldCancel: shouldCancel)
            excludedFromProtectedScan.insert(wtPath)
            if usage.physicalSize > 0 {
                let relPath = ".claude/worktrees"
                let explanation = "Claude Code isolated git worktrees. Inspected in the Git & Claude Worktree Analyzer."
                let consequence = "Protected in this phase. Never deleted automatically to prevent loss of uncommitted branch work."
                let item = CleanableItem(
                    id: "proj-\(projectName)-worktrees",
                    name: "\(projectName) — \(relPath)",
                    category: .projectStorage,
                    path: wtPath,
                    logicalSize: usage.logicalSize,
                    physicalSize: usage.physicalSize,
                    reclaimableSize: 0,
                    lastModified: usage.lastModified,
                    riskLevel: .caution,
                    explanation: explanation,
                    deletionConsequence: consequence,
                    regenerationImpact: "Protected worktrees are never deleted automatically.",
                    isRunningDependency: isProjectBusy,
                    runningProcessNames: activeProcesses,
                    actionType: .readOnlyInfo(reason: "Git/Claude worktrees are strictly informative in this phase to protect local branches and uncommitted changes.")
                )
                artifacts.append(
                    ProjectArtifactEntry(
                        projectName: projectName,
                        projectRootPath: projectPath,
                        name: "Claude Worktrees (.claude/worktrees)",
                        relativePath: relPath,
                        fullPath: wtPath,
                        artifactCategory: .worktree,
                        verifiedKind: nil,
                        physicalBytes: usage.physicalSize,
                        logicalBytes: usage.logicalSize,
                        reclaimableBytes: 0,
                        lastModified: usage.lastModified,
                        riskLevel: .caution,
                        explanation: explanation,
                        deletionConsequence: consequence,
                        isRunningDependency: isProjectBusy,
                        runningProcessNames: activeProcesses,
                        cleanableItem: item
                    )
                )
            }
        }

        // 2. Selectively inspect <project>/.cache if present
        let dotCacheURL = projectURL.appendingPathComponent(".cache")
        if FileManager.default.fileExists(atPath: dotCacheURL.path, isDirectory: &isDir), isDir.boolValue {
            let dotCachePath = dotCacheURL.standardizedFileURL.path
            excludedFromProtectedScan.insert(dotCachePath)
            let dotCacheEntries = inspectDotCacheDirectory(
                at: dotCacheURL,
                projectURL: projectURL,
                projectName: projectName,
                isProjectBusy: isProjectBusy,
                activeProcesses: activeProcesses,
                shouldCancel: shouldCancel
            )
            artifacts.append(contentsOf: dotCacheEntries)
        }

        // 3. Discover candidate build/cache/dependency directories in the project (excluding .git, .claude, .cache)
        let candidateURLs = discoverProjectCandidateDirectories(
            in: projectURL,
            alreadyExcluded: excludedFromProtectedScan
        )

        for candidateURL in candidateURLs {
            if shouldCancel?() == true { return nil }
            let candidatePath = candidateURL.standardizedFileURL.path
            // Skip if already inside an excluded ancestor
            if excludedFromProtectedScan.contains(where: { candidatePath == $0 || candidatePath.hasPrefix($0 + "/") }) {
                continue
            }

            let usage = DiskScanner.shared.measurePath(candidatePath, shouldCancel: shouldCancel)
            excludedFromProtectedScan.insert(candidatePath)
            guard usage.physicalSize > 0 else { continue }

            let entry = buildProjectArtifactEntry(
                for: candidateURL,
                usage: usage,
                projectURL: projectURL,
                projectName: projectName,
                isProjectBusy: isProjectBusy,
                activeProcesses: activeProcesses
            )
            artifacts.append(entry)
        }

        // 4. Measure remaining project files (source code, .git, configs, assets) in a single pass excluding already-measured subtrees
        let remainingUsage = DiskScanner.shared.measurePath(
            projectPath,
            excludedSubpaths: excludedFromProtectedScan,
            shouldCancel: shouldCancel
        )

        // Sort artifacts by physical size descending
        artifacts.sort { $0.physicalBytes > $1.physicalBytes }

        var dependenciesBytes: Int64 = 0
        var cachesBytes: Int64 = 0
        var buildsBytes: Int64 = 0
        var worktreesBytes: Int64 = 0
        var protectedArtifactBytes: Int64 = 0
        var safeRecoverableBytes: Int64 = 0
        var reviewRecoverableBytes: Int64 = 0
        var latestDate: Date? = remainingUsage.lastModified

        for artifact in artifacts {
            if let mod = artifact.lastModified {
                if latestDate == nil || mod > latestDate! {
                    latestDate = mod
                }
            }
            switch artifact.artifactCategory {
            case .dependency:
                dependenciesBytes += artifact.physicalBytes
            case .cache:
                cachesBytes += artifact.physicalBytes
            case .build, .testArtifact:
                buildsBytes += artifact.physicalBytes
            case .worktree:
                worktreesBytes += artifact.physicalBytes
            case .protectedData:
                protectedArtifactBytes += artifact.physicalBytes
            }

            if artifact.reclaimableBytes > 0 {
                switch artifact.riskLevel {
                case .safe:
                    safeRecoverableBytes += artifact.reclaimableBytes
                case .review, .caution:
                    reviewRecoverableBytes += artifact.reclaimableBytes
                case .neverDelete:
                    break
                }
            }
        }

        let protectedBytes = remainingUsage.physicalSize + protectedArtifactBytes
        let totalPhysicalBytes = remainingUsage.physicalSize + artifacts.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let totalLogicalBytes = remainingUsage.logicalSize + artifacts.reduce(Int64(0)) { $0 + $1.logicalBytes }

        let overallRisk: RiskLevel = {
            if safeRecoverableBytes > 0 {
                return .safe
            }
            if reviewRecoverableBytes > 0 {
                return .review
            }
            if worktreesBytes > 0 || protectedArtifactBytes > 0 {
                return .caution
            }
            return .neverDelete
        }()

        return ProjectStorageReport(
            name: projectName,
            path: projectPath,
            totalPhysicalBytes: totalPhysicalBytes,
            totalLogicalBytes: totalLogicalBytes,
            dependenciesBytes: dependenciesBytes,
            cachesBytes: cachesBytes,
            buildsBytes: buildsBytes,
            worktreesBytes: worktreesBytes,
            protectedBytes: protectedBytes,
            safeRecoverableBytes: safeRecoverableBytes,
            reviewRecoverableBytes: reviewRecoverableBytes,
            lastActivityDate: latestDate,
            overallRiskLevel: overallRisk,
            activeProcessNames: activeProcesses,
            projectTypeTags: projectTags,
            artifacts: artifacts
        )
    }

    // MARK: - Selective .cache Inspection

    private func inspectDotCacheDirectory(
        at dotCacheURL: URL,
        projectURL: URL,
        projectName: String,
        isProjectBusy: Bool,
        activeProcesses: [String],
        shouldCancel: (@Sendable () -> Bool)?
    ) -> [ProjectArtifactEntry] {
        var entries: [ProjectArtifactEntry] = []
        var verifiedSubpaths = Set<String>()
        let projectPath = projectURL.standardizedFileURL.path
        let dotCachePath = dotCacheURL.standardizedFileURL.path

        // Walk up to depth 4 inside .cache to identify verified regenerable subdirectories vs protected evidence/configs
        let candidateURLs = discoverVerifiedSubdirectoriesInsideDotCache(
            dotCacheURL: dotCacheURL,
            projectPath: projectPath
        )

        for candidateURL in candidateURLs {
            if shouldCancel?() == true { break }
            let candidatePath = candidateURL.standardizedFileURL.path
            if verifiedSubpaths.contains(where: { candidatePath == $0 || candidatePath.hasPrefix($0 + "/") }) {
                continue
            }
            let usage = DiskScanner.shared.measurePath(candidatePath, shouldCancel: shouldCancel)
            verifiedSubpaths.insert(candidatePath)
            guard usage.physicalSize > 0 else { continue }

            let entry = buildProjectArtifactEntry(
                for: candidateURL,
                usage: usage,
                projectURL: projectURL,
                projectName: projectName,
                isProjectBusy: isProjectBusy,
                activeProcesses: activeProcesses
            )
            entries.append(entry)
        }

        // Measure all remaining files/folders inside .cache that were NOT verified as cleanable
        let remainingDotCacheUsage = DiskScanner.shared.measurePath(
            dotCachePath,
            excludedSubpaths: verifiedSubpaths,
            shouldCancel: shouldCancel
        )
        if remainingDotCacheUsage.physicalSize > 0 {
            let relPath = relativePath(of: dotCacheURL, from: projectURL)
            let explanation = "Unverified or protected files inside \(relPath) (e.g. stage evidence, QA screenshots, certificates, .env configs, release APK/AAB bundles, or custom scripts)."
            let consequence = "Protected from cleanup. Kept intact to preserve test evidence, certificates, and project state."
            let item = CleanableItem(
                id: "proj-\(projectName)-dotcache-protected",
                name: "\(projectName) — \(relPath) (Protected Evidence & Configs)",
                category: .projectStorage,
                path: dotCachePath,
                logicalSize: remainingDotCacheUsage.logicalSize,
                physicalSize: remainingDotCacheUsage.physicalSize,
                reclaimableSize: 0,
                lastModified: remainingDotCacheUsage.lastModified,
                riskLevel: .caution,
                explanation: explanation,
                deletionConsequence: consequence,
                regenerationImpact: "Contains protected evidence, certificates, or unverified files.",
                isRunningDependency: isProjectBusy,
                runningProcessNames: activeProcesses,
                actionType: .readOnlyInfo(reason: "Contains unverified .cache data, stage evidence, or configuration files; preserved for safety.")
            )
            entries.append(
                ProjectArtifactEntry(
                    projectName: projectName,
                    projectRootPath: projectPath,
                    name: ".cache (Protected Evidence, Certs & Unverified Data)",
                    relativePath: "\(relPath) [protected subset]",
                    fullPath: dotCachePath,
                    artifactCategory: .protectedData,
                    verifiedKind: nil,
                    physicalBytes: remainingDotCacheUsage.physicalSize,
                    logicalBytes: remainingDotCacheUsage.logicalSize,
                    reclaimableBytes: 0,
                    lastModified: remainingDotCacheUsage.lastModified,
                    riskLevel: .caution,
                    explanation: explanation,
                    deletionConsequence: consequence,
                    isRunningDependency: isProjectBusy,
                    runningProcessNames: activeProcesses,
                    cleanableItem: item
                )
            )
        }

        return entries
    }

    private func discoverVerifiedSubdirectoriesInsideDotCache(
        dotCacheURL: URL,
        projectPath: String
    ) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        func scanDirectory(_ dirURL: URL, depth: Int) {
            guard depth <= 4 else { return }
            let dirPath = dirURL.standardizedFileURL.path
            if dirURL != dotCacheURL,
               SafetyValidator.verifyCleanableProjectArtifact(at: dirPath, projectRoot: projectPath) != nil {
                results.append(dirURL)
                return // Do not recurse into an already-verified cleanable directory
            }

            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            let sortedChildren = children.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }

            for childURL in sortedChildren {
                guard let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      vals.isDirectory == true,
                      vals.isSymbolicLink != true else {
                    continue
                }
                scanDirectory(childURL, depth: depth + 1)
            }
        }

        scanDirectory(dotCacheURL, depth: 0)
        return results
    }

    // MARK: - Candidate Discovery in Project Tree

    private func discoverProjectCandidateDirectories(
        in projectURL: URL,
        alreadyExcluded: Set<String>
    ) -> [URL] {
        let fm = FileManager.default
        let targetNames: Set<String> = [
            ".next",
            ".expo",
            ".turbo",
            ".metro",
            ".metro-cache",
            ".parcel-cache",
            ".eslintcache",
            ".build",
            ".gradle",
            "node_modules",
            "Pods",
            "build",
            "dist",
            "DerivedData"
        ]

        var results: [URL] = []

        func walk(_ currentURL: URL, depth: Int) {
            guard depth <= 3 else { return }
            let currentPath = currentURL.standardizedFileURL.path
            if alreadyExcluded.contains(currentPath) {
                return
            }

            guard let children = try? fm.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                return
            }

            let sortedChildren = children.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }

            for childURL in sortedChildren {
                let name = childURL.lastPathComponent
                if name == ".git" || name == ".DS_Store" || name == ".claude" {
                    continue
                }
                let childPath = childURL.standardizedFileURL.path
                if alreadyExcluded.contains(childPath) {
                    continue
                }

                guard let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      vals.isDirectory == true,
                      vals.isSymbolicLink != true else {
                    continue
                }

                if name == ".cache" {
                    // Nested .cache in subpackage or stage
                    if SafetyValidator.verifyCleanableProjectArtifact(at: childPath, projectRoot: projectURL.standardizedFileURL.path) != nil {
                        results.append(childURL)
                    } else {
                        let nestedVerified = discoverVerifiedSubdirectoriesInsideDotCache(
                            dotCacheURL: childURL,
                            projectPath: projectURL.standardizedFileURL.path
                        )
                        if !nestedVerified.isEmpty {
                            results.append(contentsOf: nestedVerified)
                        } else {
                            results.append(childURL)
                        }
                    }
                    continue
                }

                if targetNames.contains(name) || name.hasSuffix(".xcresult") {
                    results.append(childURL)
                    continue // Do not recurse inside node_modules, .next, Pods, build, etc.
                }

                // Recurse into workspace subdirectories (e.g. ios, android, apps/*, packages/*)
                walk(childURL, depth: depth + 1)
            }
        }

        walk(projectURL, depth: 1)
        return results
    }

    // MARK: - Artifact Classification & Verification

    private func buildProjectArtifactEntry(
        for artifactURL: URL,
        usage: DiskUsageInfo,
        projectURL: URL,
        projectName: String,
        isProjectBusy: Bool,
        activeProcesses: [String]
    ) -> ProjectArtifactEntry {
        let projectPath = projectURL.standardizedFileURL.path
        let artifactPath = artifactURL.standardizedFileURL.path
        let relPath = relativePath(of: artifactURL, from: projectURL)
        let sanitizedRelID = relPath.replacingOccurrences(of: "/", with: "-")

        let verifiedKind = SafetyValidator.verifyCleanableProjectArtifact(
            at: artifactPath,
            projectRoot: projectPath
        )

        if let kind = verifiedKind {
            // Also verify that subtree does not contain unexpected forbidden files (e.g., .env or certs placed inside a build dir)
            let isSubtreeClean = (try? validator.validateVerifiedProjectArtifactForDeletion(
                artifactPath,
                projectRoot: projectPath,
                expectedModifiedAt: nil,
                checkSymlinksOnDisk: true
            )) != nil

            if isSubtreeClean {
                let meta = metadata(for: kind, relativePath: relPath)
                let item = CleanableItem(
                    id: "proj-\(projectName)-\(sanitizedRelID)",
                    name: "\(projectName) — \(relPath)",
                    category: .projectStorage,
                    path: artifactPath,
                    logicalSize: usage.logicalSize,
                    physicalSize: usage.physicalSize,
                    reclaimableSize: usage.physicalSize,
                    lastModified: usage.lastModified,
                    riskLevel: meta.risk,
                    explanation: meta.explanation,
                    deletionConsequence: "Moves verified project artifact \(relPath) to macOS Trash.",
                    regenerationImpact: meta.consequence,
                    isRunningDependency: isProjectBusy,
                    runningProcessNames: activeProcesses,
                    actionType: .moveToTrashVerifiedProjectArtifact(
                        path: artifactPath,
                        projectRoot: projectPath,
                        expectedModifiedAt: usage.lastModified
                    ),
                    requiresRedownload: meta.requiresRedownload,
                    affectsSessionsOrConfig: false
                )

                return ProjectArtifactEntry(
                    projectName: projectName,
                    projectRootPath: projectPath,
                    name: "\(kind.rawValue) (\(relPath))",
                    relativePath: relPath,
                    fullPath: artifactPath,
                    artifactCategory: meta.category,
                    verifiedKind: kind,
                    physicalBytes: usage.physicalSize,
                    logicalBytes: usage.logicalSize,
                    reclaimableBytes: usage.physicalSize,
                    lastModified: usage.lastModified,
                    riskLevel: meta.risk,
                    explanation: meta.explanation,
                    deletionConsequence: meta.consequence,
                    isRunningDependency: isProjectBusy,
                    runningProcessNames: activeProcesses,
                    cleanableItem: item
                )
            }
        }

        // Unverified directory (e.g. unverified `dist`, `build`, `.cache`, or directory containing protected files)
        let explanation = "Directory '\(relPath)' could not be verified as a purely regenerable cache or contains protected files."
        let consequence = "Automatic cleanup is disabled for safety. Inspect manually in Finder before removing."
        let item = CleanableItem(
            id: "proj-\(projectName)-unverified-\(sanitizedRelID)",
            name: "\(projectName) — \(relPath) (Review / Unverified)",
            category: .projectStorage,
            path: artifactPath,
            logicalSize: usage.logicalSize,
            physicalSize: usage.physicalSize,
            reclaimableSize: 0,
            lastModified: usage.lastModified,
            riskLevel: .caution,
            explanation: explanation,
            deletionConsequence: consequence,
            regenerationImpact: "Protected against automatic deletion.",
            isRunningDependency: isProjectBusy,
            runningProcessNames: activeProcesses,
            actionType: .readOnlyInfo(reason: "Unverified folder structure or contains protected files; automatic deletion is blocked.")
        )

        return ProjectArtifactEntry(
            projectName: projectName,
            projectRootPath: projectPath,
            name: "Unverified Directory (\(relPath))",
            relativePath: relPath,
            fullPath: artifactPath,
            artifactCategory: .protectedData,
            verifiedKind: nil,
            physicalBytes: usage.physicalSize,
            logicalBytes: usage.logicalSize,
            reclaimableBytes: 0,
            lastModified: usage.lastModified,
            riskLevel: .caution,
            explanation: explanation,
            deletionConsequence: consequence,
            isRunningDependency: isProjectBusy,
            runningProcessNames: activeProcesses,
            cleanableItem: item
        )
    }

    private func metadata(
        for kind: VerifiedProjectArtifactKind,
        relativePath: String
    ) -> (category: ProjectArtifactCategory, risk: RiskLevel, explanation: String, consequence: String, requiresRedownload: Bool) {
        switch kind {
        case .nextBuild:
            return (
                .build,
                .safe,
                "Verified Next.js build & webpack/turbopack cache at \(relativePath).",
                "Next.js will rebuild .next automatically on the next `next dev` or `next build`.",
                false
            )
        case .expoCache:
            return (
                .cache,
                .safe,
                "Verified Expo bundler & prebuild cache at \(relativePath).",
                "Expo will regenerate .expo automatically on the next `npx expo start`.",
                false
            )
        case .turboCache:
            return (
                .cache,
                .safe,
                "Verified Turborepo task cache at \(relativePath).",
                "Turborepo will re-run cached tasks locally on next build.",
                false
            )
        case .metroCache:
            return (
                .cache,
                .safe,
                "Verified React Native Metro bundler cache at \(relativePath).",
                "Metro will rebuild its JS transformation cache on next start.",
                false
            )
        case .parcelOrLinterCache:
            return (
                .cache,
                .safe,
                "Verified bundler/linter cache at \(relativePath).",
                "Regenerated automatically on next build or lint run.",
                false
            )
        case .swiftPMBuild:
            return (
                .build,
                .safe,
                "Verified Swift Package Manager build directory at \(relativePath).",
                "SwiftPM will recompile and re-resolve packages on next `swift build` or `swift test`.",
                false
            )
        case .gradleProjectCache:
            return (
                .cache,
                .safe,
                "Verified project-local Gradle cache at \(relativePath).",
                "Gradle will recreate project metadata and task state on next Android build.",
                false
            )
        case .gradleBuildOutput:
            return (
                .build,
                .safe,
                "Verified Android / Gradle build intermediates & outputs at \(relativePath).",
                "Gradle will recompile Android targets on the next build.",
                false
            )
        case .xcodeDerivedData:
            return (
                .build,
                .safe,
                "Verified local Xcode DerivedData build tree at \(relativePath) (Info.plist + Build/ModuleCache).",
                "Xcode / xcodebuild will recompile intermediates and index data on next build.",
                false
            )
        case .xcodeSymrootBuild:
            return (
                .build,
                .safe,
                "Verified local Xcode SYMROOT/OBJROOT build intermediates at \(relativePath) (XCBuildData).",
                "Xcode / xcodebuild will regenerate compiled intermediates on next build.",
                false
            )
        case .localPackageManagerCache:
            return (
                .cache,
                .safe,
                "Verified local package manager cache at \(relativePath) (npm/pnpm/corepack/yarn store).",
                "Package manager will re-fetch or re-link cached tarballs on next install.",
                true
            )
        case .xcresultBundle:
            return (
                .testArtifact,
                .review,
                "Verified Xcode test/run result bundle at \(relativePath).",
                "Removes test run logs, screenshots, and diagnostics inside this .xcresult bundle.",
                false
            )
        case .tarballCache:
            return (
                .cache,
                .review,
                "Verified cached package archive tarballs (.tgz) at \(relativePath).",
                "Removes local packed .tgz archives; may need to re-pack or re-download if referenced by scripts.",
                true
            )
        case .nodeModules:
            return (
                .dependency,
                .review,
                "Verified Node.js dependency tree at \(relativePath).",
                "Requires running `npm install`, `pnpm install`, or `yarn` before building or running the project.",
                true
            )
        case .cocoaPods:
            return (
                .dependency,
                .review,
                "Verified iOS CocoaPods dependency directory at \(relativePath).",
                "Requires running `pod install` inside ios/ before building the iOS workspace.",
                true
            )
        }
    }

    private func detectProjectTypeTags(at projectURL: URL) -> [String] {
        let fm = FileManager.default
        var tags: [String] = []
        if fm.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path) {
            tags.append("SwiftPM")
        }
        if fm.fileExists(atPath: projectURL.appendingPathComponent("next.config.js").path) ||
           fm.fileExists(atPath: projectURL.appendingPathComponent("next.config.mjs").path) ||
           fm.fileExists(atPath: projectURL.appendingPathComponent("next.config.ts").path) {
            tags.append("Next.js")
        }
        if fm.fileExists(atPath: projectURL.appendingPathComponent("app.json").path) ||
           fm.fileExists(atPath: projectURL.appendingPathComponent(".expo").path) {
            tags.append("Expo / RN")
        }
        if fm.fileExists(atPath: projectURL.appendingPathComponent("ios").path) {
            tags.append("iOS")
        }
        if fm.fileExists(atPath: projectURL.appendingPathComponent("android").path) {
            tags.append("Android")
        }
        if tags.isEmpty && fm.fileExists(atPath: projectURL.appendingPathComponent("package.json").path) {
            tags.append("Node.js")
        }
        return tags
    }

    private func relativePath(of childURL: URL, from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let childPath = childURL.standardizedFileURL.path
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        return childURL.lastPathComponent
    }
}
