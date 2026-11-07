import Foundation

public final class GitWorktreeAnalyzer: Sendable {
    public let shellRunner: @Sendable (String, [String]) async -> ShellResult
    public let validator: SafetyValidator
    public let homeDirectory: String
    public let inactivityConfig: WorktreeInactivityConfig

    public init(
        validator: SafetyValidator = SafetyValidator(),
        inactivityConfig: WorktreeInactivityConfig = .default,
        shellRunner: @escaping @Sendable (String, [String]) async -> ShellResult = { executable, arguments in
            await ShellRunner.shared.run(executable, arguments: arguments)
        }
    ) {
        self.validator = validator
        self.homeDirectory = validator.homeDirectory
        self.inactivityConfig = inactivityConfig
        self.shellRunner = shellRunner
    }

    public struct ParsedPorcelainWorktree: Sendable, Equatable {
        public var path: String
        public var head: String = ""
        public var branchRef: String?
        public var isDetached: Bool = false
        public var isBare: Bool = false
        public var isLocked: Bool = false
        public var lockReason: String?
        public var isPrunable: Bool = false
        public var prunableReason: String?

        public init(path: String) {
            self.path = path
        }
    }

    /// Parses output of `git worktree list --porcelain`
    public static func parsePorcelainWorktreeList(_ output: String) -> [ParsedPorcelainWorktree] {
        var results: [ParsedPorcelainWorktree] = []
        var current: ParsedPorcelainWorktree?

        let lines = output.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if let entry = current {
                    results.append(entry)
                    current = nil
                }
                continue
            }

            if line.hasPrefix("worktree ") {
                if let entry = current {
                    results.append(entry)
                }
                let wtPath = String(line.dropFirst("worktree ".count))
                current = ParsedPorcelainWorktree(path: wtPath)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current?.branchRef = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "locked" {
                current?.isLocked = true
            } else if line.hasPrefix("locked ") {
                current?.isLocked = true
                current?.lockReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                current?.isPrunable = true
            } else if line.hasPrefix("prunable ") {
                current?.isPrunable = true
                current?.prunableReason = String(line.dropFirst("prunable ".count))
            }
        }

        if let entry = current {
            results.append(entry)
        }

        return results
    }

    public func analyzeWorktrees(
        in rootPath: String = ProjectStorageAnalyzer.defaultDeveloperRoot,
        codexWorktreesRoot: String? = nil,
        inactivityConfig: WorktreeInactivityConfig? = nil,
        referenceDate: Date = Date(),
        snapshot: ActiveProcessSnapshot = .empty,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async -> [GitWorktreeRecord] {
        let fm = FileManager.default
        let effectiveConfig = inactivityConfig ?? self.inactivityConfig
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let children = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var seenMainWorktreePaths = Set<String>()
        var seenWorktreePaths = Set<String>()
        var records: [GitWorktreeRecord] = []

        let sortedDirs = children.filter { url in
            guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true,
                  vals.isSymbolicLink != true else {
                return false
            }
            return fm.fileExists(atPath: url.appendingPathComponent(".git").path)
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        // 1. Discover registered Git worktrees via `git worktree list --porcelain` (deduplicating repository families)
        for repoURL in sortedDirs {
            if shouldCancel?() == true || Task.isCancelled { break }
            let repoPath = repoURL.standardizedFileURL.path

            // Fast pre-check: if this directory is itself a linked worktree whose main repo was already scanned, skip redundant `git worktree list`
            let meta = SafetyValidator.verifyWorktreeGitMetadata(at: repoPath)
            if let sourceRepo = meta.sourceRepoPath, seenMainWorktreePaths.contains(sourceRepo) {
                continue
            }

            let listRes = await shellRunner("/usr/bin/git", ["-C", repoPath, "worktree", "list", "--porcelain"])
            guard listRes.isSuccess else { continue }

            let parsedList = Self.parsePorcelainWorktreeList(listRes.stdout)
            guard let mainWorktree = parsedList.first else { continue }
            let mainPath = URL(fileURLWithPath: mainWorktree.path).standardizedFileURL.path

            if seenMainWorktreePaths.contains(mainPath) {
                continue
            }
            seenMainWorktreePaths.insert(mainPath)

            let sourceProjectName = URL(fileURLWithPath: mainPath).lastPathComponent

            for wt in parsedList.dropFirst() {
                if shouldCancel?() == true || Task.isCancelled { break }
                let wtStandardizedPath = URL(fileURLWithPath: wt.path).standardizedFileURL.path
                if seenWorktreePaths.contains(wtStandardizedPath) {
                    continue
                }
                seenWorktreePaths.insert(wtStandardizedPath)

                let record = await inspectSingleWorktree(
                    wt: wt,
                    standardizedPath: wtStandardizedPath,
                    sourceProjectName: sourceProjectName,
                    sourceProjectPath: mainPath,
                    isFromPorcelainList: true,
                    inactivityConfig: effectiveConfig,
                    referenceDate: referenceDate,
                    snapshot: snapshot,
                    shouldCancel: shouldCancel
                )
                records.append(record)
            }
        }

        // 2. Discover `.claude/worktrees/*` inside projects in `rootPath` that were not already listed
        for projURL in children {
            if shouldCancel?() == true || Task.isCancelled { break }
            guard let vals = try? projURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true,
                  vals.isSymbolicLink != true else {
                continue
            }
            let claudeWorktreesDir = projURL.appendingPathComponent(".claude/worktrees", isDirectory: true)
            guard fm.fileExists(atPath: claudeWorktreesDir.path),
                  let wtDirs = try? fm.contentsOfDirectory(
                      at: claudeWorktreesDir,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            let projPath = projURL.standardizedFileURL.path
            let projName = projURL.lastPathComponent

            for wtURL in wtDirs {
                if shouldCancel?() == true || Task.isCancelled { break }
                let wtStandardizedPath = wtURL.standardizedFileURL.path
                if seenWorktreePaths.contains(wtStandardizedPath) {
                    continue
                }
                let verification = SafetyValidator.verifyWorktreeGitMetadata(at: wtStandardizedPath)
                guard verification.isVerified else { continue }
                seenWorktreePaths.insert(wtStandardizedPath)

                let sourceRepoPath = verification.sourceRepoPath ?? projPath
                let sourceRepoName = URL(fileURLWithPath: sourceRepoPath).lastPathComponent.isEmpty
                    ? projName
                    : URL(fileURLWithPath: sourceRepoPath).lastPathComponent

                let wt = await buildPorcelainEntryFromDiskOrGit(at: wtStandardizedPath, gitDirPath: verification.gitDirPath)
                let record = await inspectSingleWorktree(
                    wt: wt,
                    standardizedPath: wtStandardizedPath,
                    sourceProjectName: sourceRepoName,
                    sourceProjectPath: sourceRepoPath,
                    isFromPorcelainList: false,
                    inactivityConfig: effectiveConfig,
                    referenceDate: referenceDate,
                    snapshot: snapshot,
                    shouldCancel: shouldCancel
                )
                records.append(record)
            }
        }

        // 3. Discover `~/.codex/worktrees/*` (supports both depth-1 `~/.codex/worktrees/<wt>` and depth-2 `~/.codex/worktrees/<slug>/<repo>`)
        let effectiveCodexRoot = codexWorktreesRoot ?? "\(homeDirectory)/.codex/worktrees"
        let codexRootURL = URL(fileURLWithPath: effectiveCodexRoot).standardizedFileURL
        if fm.fileExists(atPath: codexRootURL.path),
           let level1Dirs = try? fm.contentsOfDirectory(
               at: codexRootURL,
               includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
               options: [.skipsHiddenFiles]
           ) {
            for level1URL in level1Dirs {
                if shouldCancel?() == true || Task.isCancelled { break }
                guard let l1Vals = try? level1URL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      l1Vals.isDirectory == true,
                      l1Vals.isSymbolicLink != true else {
                    continue
                }
                let l1Path = level1URL.standardizedFileURL.path
                let l1Verification = SafetyValidator.verifyWorktreeGitMetadata(at: l1Path)
                if l1Verification.isVerified {
                    if !seenWorktreePaths.contains(l1Path) {
                        seenWorktreePaths.insert(l1Path)
                        let srcPath = l1Verification.sourceRepoPath ?? l1Path
                        let srcName = URL(fileURLWithPath: srcPath).lastPathComponent
                        let wt = await buildPorcelainEntryFromDiskOrGit(at: l1Path, gitDirPath: l1Verification.gitDirPath)
                        let record = await inspectSingleWorktree(
                            wt: wt,
                            standardizedPath: l1Path,
                            sourceProjectName: srcName,
                            sourceProjectPath: srcPath,
                            isFromPorcelainList: false,
                            inactivityConfig: effectiveConfig,
                            referenceDate: referenceDate,
                            snapshot: snapshot,
                            shouldCancel: shouldCancel
                        )
                        records.append(record)
                    }
                    continue
                }

                // Check depth 2: ~/.codex/worktrees/<task-slug>/<repo-name>
                guard let level2Dirs = try? fm.contentsOfDirectory(
                    at: level1URL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for level2URL in level2Dirs {
                    if shouldCancel?() == true || Task.isCancelled { break }
                    let l2Path = level2URL.standardizedFileURL.path
                    if seenWorktreePaths.contains(l2Path) {
                        continue
                    }
                    let l2Verification = SafetyValidator.verifyWorktreeGitMetadata(at: l2Path)
                    guard l2Verification.isVerified else { continue }
                    seenWorktreePaths.insert(l2Path)

                    let srcPath = l2Verification.sourceRepoPath ?? l2Path
                    let srcName = URL(fileURLWithPath: srcPath).lastPathComponent
                    let wt = await buildPorcelainEntryFromDiskOrGit(at: l2Path, gitDirPath: l2Verification.gitDirPath)
                    let record = await inspectSingleWorktree(
                        wt: wt,
                        standardizedPath: l2Path,
                        sourceProjectName: srcName,
                        sourceProjectPath: srcPath,
                        isFromPorcelainList: false,
                        inactivityConfig: effectiveConfig,
                        referenceDate: referenceDate,
                        snapshot: snapshot,
                        shouldCancel: shouldCancel
                    )
                    records.append(record)
                }
            }
        }

        records.sort { lhs, rhs in
            if lhs.regenerableBytes != rhs.regenerableBytes {
                return lhs.regenerableBytes > rhs.regenerableBytes
            }
            if lhs.physicalBytes != rhs.physicalBytes {
                return lhs.physicalBytes > rhs.physicalBytes
            }
            if lhs.sourceProjectName != rhs.sourceProjectName {
                return lhs.sourceProjectName.localizedCaseInsensitiveCompare(rhs.sourceProjectName) == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        return records
    }

    private func buildPorcelainEntryFromDiskOrGit(
        at worktreePath: String,
        gitDirPath: String?
    ) async -> ParsedPorcelainWorktree {
        var entry = ParsedPorcelainWorktree(path: worktreePath)
        let fm = FileManager.default
        if let gitDirPath {
            let gitDirURL = URL(fileURLWithPath: gitDirPath)
            if fm.fileExists(atPath: gitDirURL.appendingPathComponent("locked").path) {
                entry.isLocked = true
                entry.lockReason = (try? String(contentsOf: gitDirURL.appendingPathComponent("locked"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let headURL = gitDirURL.appendingPathComponent("HEAD")
            if let headRaw = try? String(contentsOf: headURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                if headRaw.hasPrefix("ref: ") {
                    let ref = String(headRaw.dropFirst("ref: ".count))
                    entry.branchRef = ref
                } else {
                    entry.head = headRaw
                    entry.isDetached = true
                }
            }
        }
        if entry.head.isEmpty {
            let headRes = await shellRunner("/usr/bin/git", ["-C", worktreePath, "rev-parse", "HEAD"])
            if headRes.isSuccess {
                entry.head = headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return entry
    }

    private static func deriveWorktreeDisplayName(path: String, originKind: WorktreeOriginKind) -> String {
        let url = URL(fileURLWithPath: path)
        if originKind == .codexWorktree, let range = path.range(of: "/.codex/worktrees/") {
            let remainder = String(path[range.upperBound...])
            let parts = remainder.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                return parts[0]
            } else if let first = parts.first {
                return first
            }
        }
        return url.lastPathComponent
    }

    private func inspectSingleWorktree(
        wt: ParsedPorcelainWorktree,
        standardizedPath: String,
        sourceProjectName: String,
        sourceProjectPath: String,
        isFromPorcelainList: Bool,
        inactivityConfig: WorktreeInactivityConfig,
        referenceDate: Date,
        snapshot: ActiveProcessSnapshot,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> GitWorktreeRecord {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let existsOnDisk = fm.fileExists(atPath: standardizedPath, isDirectory: &isDir) && isDir.boolValue

        let originKind: WorktreeOriginKind = {
            if standardizedPath.contains("/.claude/worktrees/") {
                return .claudeWorktree
            }
            if standardizedPath.contains("/.codex/worktrees/") {
                return .codexWorktree
            }
            return .gitLinkedWorktree
        }()

        let worktreeName = Self.deriveWorktreeDisplayName(path: standardizedPath, originKind: originKind)
        let metadataCheck = SafetyValidator.verifyWorktreeGitMetadata(
            at: standardizedPath,
            isRegisteredLinkedWorktree: isFromPorcelainList
        )
        let isVerifiedWorktree = existsOnDisk && metadataCheck.isVerified

        let shortCommit = wt.head.count > 8 ? String(wt.head.prefix(8)) : wt.head
        let branchLabel: String = {
            if let ref = wt.branchRef {
                if ref.hasPrefix("refs/heads/") {
                    return String(ref.dropFirst("refs/heads/".count))
                }
                return ref
            }
            if wt.isDetached {
                return shortCommit.isEmpty ? "Detached HEAD" : "Detached HEAD (\(shortCommit))"
            }
            return shortCommit.isEmpty ? "Unknown" : shortCommit
        }()

        // Query git status and last commit timestamp if the worktree exists on disk
        var modifiedCount = 0
        var untrackedCount = 0
        var stagedCount = 0
        var sampleChangedFiles: [String] = []
        var remoteBranchStatus = existsOnDisk ? "No upstream tracking branch" : "Directory missing on disk"
        var rawStatusPorcelain: String = ""
        var rawUntrackedPaths: [String] = []
        var lastCommitDate: Date? = nil

        if existsOnDisk {
            let statusRes = await shellRunner("/usr/bin/git", ["-C", standardizedPath, "status", "--porcelain", "--branch"])
            if statusRes.isSuccess {
                rawStatusPorcelain = statusRes.stdout
                let parsedStatus = Self.parseGitStatusPorcelainBranch(statusRes.stdout, isDetached: wt.isDetached)
                modifiedCount = parsedStatus.modifiedCount
                untrackedCount = parsedStatus.untrackedCount
                stagedCount = parsedStatus.stagedCount
                sampleChangedFiles = parsedStatus.sampleFiles
                remoteBranchStatus = parsedStatus.remoteStatus
                rawUntrackedPaths = Self.extractUntrackedPaths(fromPorcelainStatus: statusRes.stdout)
            }

            let logRes = await shellRunner("/usr/bin/git", ["-C", standardizedPath, "log", "-1", "--format=%ct"])
            if logRes.isSuccess,
               let ts = TimeInterval(logRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
               ts > 0 {
                lastCommitDate = Date(timeIntervalSince1970: ts)
            } else if let gitDir = metadataCheck.gitDirPath {
                let headURL = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
                if let vals = try? headURL.resourceValues(forKeys: [.contentModificationDateKey]) {
                    lastCommitDate = vals.contentModificationDate
                }
            }
        }

        let activeProcesses = snapshot.matchingProcesses(forProjectPath: standardizedPath)
        let isInUse = !activeProcesses.isEmpty

        // Discover candidate regenerable paths inside the worktree
        let discoveredCandidatePaths = existsOnDisk
            ? discoverCandidateArtifactPaths(in: standardizedPath, shouldCancel: shouldCancel)
            : []

        let discoveredRelPathsSet: Set<String> = Set(discoveredCandidatePaths.compactMap { fullPath in
            guard fullPath.hasPrefix(standardizedPath + "/") else { return nil }
            return String(fullPath.dropFirst(standardizedPath.count + 1))
        })

        // Determine if any untracked file in `git status --porcelain` is outside the discovered regenerable artifacts
        let untrackedOutsideArtifactsCount = rawUntrackedPaths.filter { untrackedRel in
            let cleaned = untrackedRel.hasSuffix("/") ? String(untrackedRel.dropLast()) : untrackedRel
            return !discoveredRelPathsSet.contains(where: { candRel in
                cleaned == candRel || cleaned.hasPrefix(candRel + "/") || candRel.hasPrefix(cleaned + "/")
            })
        }.count

        let hasUncommittedSourceChanges = (modifiedCount + stagedCount + untrackedOutsideArtifactsCount) > 0
        let hasUncommittedChanges = (modifiedCount + untrackedCount + stagedCount) > 0

        // Measure discovered candidates first and exclude directory candidates from the remainder measurement to guarantee zero double-counting
        var physicalBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var nodeModulesBytes: Int64 = 0
        var buildAndCacheBytes: Int64 = 0
        var lastModified: Date? = nil
        var meaningfulModifiedDate: Date? = nil
        var subExcluded = Set<String>()
        var subExcludedDirs = Set<String>()
        var regularFileCandidatesPhysical: Int64 = 0
        var regularFileCandidatesLogical: Int64 = 0
        var measuredCandidates: [(fullPath: String, relPath: String, usage: DiskUsageInfo)] = []

        if existsOnDisk {
            for candPath in discoveredCandidatePaths {
                if shouldCancel?() == true || Task.isCancelled { break }
                guard fullPathIsNotInsideAlreadyMeasured(candPath, measuredSet: subExcluded) else {
                    continue
                }
                var candIsDir: ObjCBool = false
                _ = fm.fileExists(atPath: candPath, isDirectory: &candIsDir)
                let usage = DiskScanner.shared.measurePath(candPath, shouldCancel: shouldCancel)
                subExcluded.insert(candPath)
                if candIsDir.boolValue {
                    subExcludedDirs.insert(candPath)
                } else {
                    regularFileCandidatesPhysical += usage.physicalSize
                    regularFileCandidatesLogical += usage.logicalSize
                }
                physicalBytes += usage.physicalSize
                logicalBytes += usage.logicalSize
                if let mod = usage.lastModified, lastModified == nil || mod > lastModified! {
                    lastModified = mod
                }
                let relPath = String(candPath.dropFirst(standardizedPath.count + 1))
                let name = URL(fileURLWithPath: candPath).lastPathComponent
                if name == "node_modules" || name == "Pods" {
                    nodeModulesBytes += usage.physicalSize
                } else {
                    buildAndCacheBytes += usage.physicalSize
                }
                if usage.physicalSize > 0 {
                    measuredCandidates.append((candPath, relPath, usage))
                }
            }

            let restUsage = DiskScanner.shared.measurePath(
                standardizedPath,
                excludedSubpaths: subExcludedDirs,
                shouldCancel: shouldCancel
            )
            physicalBytes += max(0, restUsage.physicalSize - regularFileCandidatesPhysical)
            logicalBytes += max(0, restUsage.logicalSize - regularFileCandidatesLogical)
            meaningfulModifiedDate = Self.latestGitDrivenMeaningfulModificationDate(
                in: standardizedPath,
                porcelainStatus: rawStatusPorcelain,
                excludedRelativeCandidatePaths: discoveredRelPathsSet
            )
            if let mod = meaningfulModifiedDate, lastModified == nil || mod > lastModified! {
                lastModified = mod
            }
            if let commitMod = lastCommitDate, lastModified == nil || commitMod > lastModified! {
                lastModified = commitMod
            }
        }

        // Compute meaningful activity date using commit timestamp and non-artifact source/config modification date
        // (never relying on atime and never letting generated cache/dependency churn make an old worktree appear active)
        let lastMeaningfulActivityDate: Date? = {
            if let commitDate = lastCommitDate, let modDate = meaningfulModifiedDate {
                return max(commitDate, modDate)
            }
            return lastCommitDate ?? meaningfulModifiedDate
        }()

        let inactiveDays: Int = {
            guard let actDate = lastMeaningfulActivityDate else {
                return inactivityConfig.inactiveDaysThreshold
            }
            let seconds = max(0, referenceDate.timeIntervalSince(actDate))
            return Int(seconds / 86400)
        }()

        let isActiveOrRecent = isInUse || wt.isLocked || hasUncommittedSourceChanges || (lastMeaningfulActivityDate != nil && inactiveDays < inactivityConfig.inactiveDaysThreshold)

        let activityState: WorktreeActivityState = {
            if isActiveOrRecent {
                return .recentlyUsed
            }
            if inactiveDays >= inactivityConfig.strongCandidateDaysThreshold {
                return .staleStrongCandidate
            }
            return .inactiveEligible
        }()

        // Classify each discovered artifact candidate (SAFE vs REVIEW) with targeted Git tracked/ignored/untracked verification
        var candidates: [WorktreeArtifactCandidate] = []
        for entry in measuredCandidates {
            guard let safetyMatch = validator.inspectWorktreeArtifactSafety(
                at: entry.fullPath,
                worktreeRoot: standardizedPath
            ) else {
                continue
            }

            // 1. Targeted tracked-file check via `git ls-files -- <relPath>`
            var trackedFileInsideCandidate: String? = nil
            let lsRes = await shellRunner("/usr/bin/git", ["-C", standardizedPath, "ls-files", "--", entry.relPath])
            if lsRes.isSuccess {
                for rawLine in lsRes.stdout.components(separatedBy: .newlines) {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if trimmed == entry.relPath || trimmed.hasPrefix(entry.relPath + "/") {
                        trackedFileInsideCandidate = trimmed
                        break
                    }
                }
            }

            // 2. Targeted Git-ignore vs visible-untracked (`??`) check
            let isVisibleUntrackedInStatus = rawUntrackedPaths.contains { untrackedRel in
                let cleaned = untrackedRel.hasSuffix("/") ? String(untrackedRel.dropLast()) : untrackedRel
                return cleaned == entry.relPath || cleaned.hasPrefix(entry.relPath + "/") || entry.relPath.hasPrefix(cleaned + "/")
            }

            let gitTrackingState: WorktreeGitTrackingState
            if trackedFileInsideCandidate != nil {
                gitTrackingState = .tracked
            } else if isVisibleUntrackedInStatus {
                gitTrackingState = .untracked
            } else {
                let ignoreRes = await shellRunner("/usr/bin/git", ["-C", standardizedPath, "check-ignore", "-q", "--", entry.relPath])
                if ignoreRes.exitCode == 0 {
                    gitTrackingState = .ignored
                } else {
                    gitTrackingState = .untracked
                }
            }

            let finalClassification: RiskLevel
            let finalReason: String

            if !isVerifiedWorktree {
                finalClassification = .review
                finalReason = "Directory could not be verified as a Git worktree via Git metadata"
            } else if let trackedFile = trackedFileInsideCandidate {
                finalClassification = .review
                finalReason = "Contains Git-tracked file (\(trackedFile)) [Git: tracked]; never deleted to preserve repository state"
            } else if gitTrackingState != .ignored {
                finalClassification = .review
                if safetyMatch.classification == .safe {
                    finalReason = "Visible untracked '\(entry.relPath)' is not ignored by Git (Git: untracked); classified as REVIEW"
                } else {
                    finalReason = "\(safetyMatch.reason) (Git: untracked)"
                }
            } else if wt.isLocked {
                finalClassification = .review
                let lockNote = wt.lockReason.map { " (\($0))" } ?? ""
                finalReason = "Worktree is locked\(lockNote); classified as REVIEW"
            } else if isInUse {
                finalClassification = .review
                finalReason = "Worktree is in use by \(activeProcesses.joined(separator: ", ")); classified as REVIEW"
            } else if hasUncommittedSourceChanges {
                finalClassification = .review
                var details: [String] = []
                if modifiedCount > 0 { details.append("\(modifiedCount) modified") }
                if stagedCount > 0 { details.append("\(stagedCount) staged") }
                if untrackedOutsideArtifactsCount > 0 { details.append("\(untrackedOutsideArtifactsCount) untracked") }
                finalReason = "Worktree has uncommitted changes (\(details.joined(separator: ", "))); classified as REVIEW to protect active work"
            } else if safetyMatch.classification != .safe {
                finalClassification = .review
                finalReason = safetyMatch.reason
            } else if inactivityConfig.minimumDaysForSafeClassification > 0 && inactiveDays < inactivityConfig.minimumDaysForSafeClassification {
                finalClassification = .review
                finalReason = "Worktree was active \(inactiveDays)d ago (minimum \(inactivityConfig.minimumDaysForSafeClassification)d inactivity required); classified as REVIEW"
            } else {
                finalClassification = .safe
                finalReason = safetyMatch.reason
            }

            let isSafe = (finalClassification == .safe)
            let reclaimable = isSafe ? entry.usage.physicalSize : 0
            let slug = "\(sourceProjectName)-\(worktreeName)-\(entry.relPath)"
                .lowercased()
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: ".", with: "")
            let itemID = isSafe ? "worktree-artifact-safe-\(slug)" : "worktree-artifact-review-\(slug)"

            let actionType: CleanupActionType = isSafe
                ? .moveToTrashVerifiedWorktreeArtifact(
                    path: entry.fullPath,
                    worktreeRoot: standardizedPath,
                    sourceRepoRoot: sourceProjectPath,
                    expectedModifiedAt: entry.usage.lastModified
                )
                : .readOnlyInfo(reason: finalReason)

            let cleanableItem = CleanableItem(
                id: itemID,
                name: "\(sourceProjectName) / \(worktreeName) — \(entry.relPath)",
                category: .aiWorktreeArtifacts,
                path: entry.fullPath,
                logicalSize: entry.usage.logicalSize,
                physicalSize: entry.usage.physicalSize,
                reclaimableSize: reclaimable,
                lastModified: entry.usage.lastModified,
                lastUsed: lastMeaningfulActivityDate,
                riskLevel: finalClassification,
                explanation: finalReason,
                deletionConsequence: isSafe
                    ? "Moves verified Git-ignored worktree artifact (\(entry.relPath)) to macOS Trash while preserving the worktree, branch, commits, and Git status."
                    : "Classified as REVIEW: \(finalReason). Skipped automatically during cleanup.",
                regenerationImpact: safetyMatch.reproducibilitySource.map { "Reproducible from \($0)." }
                    ?? "Requires manual verification before removal.",
                isRunningDependency: isInUse,
                runningProcessNames: activeProcesses,
                actionType: actionType
            )

            candidates.append(
                WorktreeArtifactCandidate(
                    id: itemID,
                    repositoryName: sourceProjectName,
                    repositoryPath: sourceProjectPath,
                    worktreeName: worktreeName,
                    worktreePath: standardizedPath,
                    originKind: originKind,
                    branchLabel: branchLabel,
                    artifactName: URL(fileURLWithPath: entry.fullPath).lastPathComponent,
                    relativePath: entry.relPath,
                    fullPath: entry.fullPath,
                    artifactType: safetyMatch.artifactType,
                    physicalBytes: entry.usage.physicalSize,
                    logicalBytes: entry.usage.logicalSize,
                    reclaimableBytes: reclaimable,
                    lastModified: entry.usage.lastModified,
                    classification: finalClassification,
                    classificationReason: finalReason,
                    gitTrackingState: gitTrackingState,
                    reproducibilitySource: safetyMatch.reproducibilitySource,
                    isWorktreeDirty: hasUncommittedSourceChanges,
                    isWorktreeActiveOrRecent: isActiveOrRecent,
                    activityState: activityState,
                    cleanableItem: cleanableItem
                )
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.classification != rhs.classification {
                return lhs.classification < rhs.classification
            }
            if lhs.physicalBytes != rhs.physicalBytes {
                return lhs.physicalBytes > rhs.physicalBytes
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }

        let regenerableBytes = candidates.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let safeRegenerableBytes = candidates.filter { $0.classification == .safe }.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let reviewRegenerableBytes = candidates.filter { $0.classification != .safe }.reduce(Int64(0)) { $0 + $1.physicalBytes }

        let (risk, explanation) = Self.evaluateWorkLossRisk(
            existsOnDisk: existsOnDisk,
            isLocked: wt.isLocked,
            lockReason: wt.lockReason,
            isInUse: isInUse,
            activeProcesses: activeProcesses,
            hasUncommittedChanges: hasUncommittedChanges,
            modifiedCount: modifiedCount,
            untrackedCount: untrackedCount,
            stagedCount: stagedCount,
            isDetached: wt.isDetached,
            remoteStatus: remoteBranchStatus,
            isPrunable: wt.isPrunable
        )

        return GitWorktreeRecord(
            sourceProjectName: sourceProjectName,
            sourceProjectPath: sourceProjectPath,
            worktreeName: worktreeName,
            path: standardizedPath,
            originKind: originKind,
            isVerifiedWorktree: isVerifiedWorktree,
            headCommit: shortCommit,
            branchLabel: branchLabel,
            isDetached: wt.isDetached,
            physicalBytes: physicalBytes,
            logicalBytes: logicalBytes,
            nodeModulesBytes: nodeModulesBytes,
            buildAndCacheBytes: buildAndCacheBytes,
            regenerableBytes: regenerableBytes,
            safeRegenerableBytes: safeRegenerableBytes,
            reviewRegenerableBytes: reviewRegenerableBytes,
            existsOnDisk: existsOnDisk,
            hasUncommittedChanges: hasUncommittedChanges,
            modifiedFilesCount: modifiedCount,
            untrackedFilesCount: untrackedCount,
            stagedFilesCount: stagedCount,
            sampleChangedFiles: sampleChangedFiles,
            remoteBranchStatus: remoteBranchStatus,
            isLocked: wt.isLocked,
            lockReason: wt.lockReason,
            isPrunable: wt.isPrunable,
            prunableReason: wt.prunableReason,
            isInUseByProcess: isInUse,
            activeProcessNames: activeProcesses,
            lastCommitDate: lastCommitDate,
            lastModifiedDate: lastModified,
            lastActivityDate: lastMeaningfulActivityDate,
            lastMeaningfulActivityDate: lastMeaningfulActivityDate,
            inactiveDays: inactiveDays,
            isActiveOrRecent: isActiveOrRecent,
            activityState: activityState,
            workLossRisk: risk,
            riskExplanation: explanation,
            artifactCandidates: candidates
        )
    }

    private func fullPathIsNotInsideAlreadyMeasured(_ candidatePath: String, measuredSet: Set<String>) -> Bool {
        for existing in measuredSet {
            if candidatePath == existing || candidatePath.hasPrefix(existing + "/") {
                return false
            }
        }
        return true
    }

    /// Computes the latest modification timestamp across meaningful Git-reported changed or visible-untracked project files
    /// without recursively traversing the repository. For a clean worktree with no meaningful local changes, returns `nil`
    /// so `lastCommitDate` serves as the primary activity timestamp.
    public static func latestGitDrivenMeaningfulModificationDate(
        in worktreePath: String,
        porcelainStatus: String,
        excludedRelativeCandidatePaths: Set<String>
    ) -> Date? {
        let generatedArtifactNames: Set<String> = [
            "node_modules", ".next", ".turbo", "dist", "build", ".expo", ".nuxt",
            ".svelte-kit", ".astro", ".vite", ".parcel-cache", ".eslintcache",
            ".metro", ".metro-cache", ".angular", ".docusaurus", "Pods", ".build",
            ".gradle", ".cache", ".tsbuildinfo", ".DS_Store", ".git"
        ]

        var candidateRelPaths: [String] = []
        for rawLine in porcelainStatus.components(separatedBy: .newlines) {
            guard rawLine.count >= 4, !rawLine.hasPrefix("## ") else { continue }
            var pathPart = String(rawLine.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let arrowRange = pathPart.range(of: " -> ") {
                pathPart = String(pathPart[arrowRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if pathPart.hasPrefix("\"") && pathPart.hasSuffix("\"") && pathPart.count >= 2 {
                pathPart = String(pathPart.dropFirst().dropLast())
            }
            if pathPart.hasSuffix("/") {
                pathPart = String(pathPart.dropLast())
            }
            guard !pathPart.isEmpty else { continue }

            // Exclude discovered generated/cache candidate paths
            let isExcludedCandidate = excludedRelativeCandidatePaths.contains { cand in
                pathPart == cand || pathPart.hasPrefix(cand + "/") || cand.hasPrefix(pathPart + "/")
            }
            if isExcludedCandidate { continue }

            // Exclude generated artifact path components
            let parts = pathPart.split(separator: "/").map(String.init)
            if parts.contains(where: { generatedArtifactNames.contains($0) || $0.hasSuffix(".tsbuildinfo") }) {
                continue
            }

            candidateRelPaths.append(pathPart)
        }

        guard !candidateRelPaths.isEmpty else {
            return nil
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var latest: Date? = nil

        func recordMod(_ d: Date?) {
            guard let d else { return }
            if latest == nil || d > latest! {
                latest = d
            }
        }

        func inspectBoundedUntrackedDir(_ dirURL: URL, depth: Int, budget: inout Int) {
            guard depth <= 3, budget > 0 else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { return }
            for childURL in children {
                guard budget > 0 else { return }
                let name = childURL.lastPathComponent
                if generatedArtifactNames.contains(name) || name.hasSuffix(".tsbuildinfo") { continue }
                guard let vals = try? childURL.resourceValues(forKeys: keys), vals.isSymbolicLink != true else { continue }
                budget -= 1
                recordMod(vals.contentModificationDate)
                if vals.isDirectory == true {
                    inspectBoundedUntrackedDir(childURL, depth: depth + 1, budget: &budget)
                }
            }
        }

        for rel in candidateRelPaths {
            let targetURL = rootURL.appendingPathComponent(rel)
            if let vals = try? targetURL.resourceValues(forKeys: keys), vals.isSymbolicLink != true {
                recordMod(vals.contentModificationDate)
                if vals.isDirectory == true {
                    var budget = 48
                    inspectBoundedUntrackedDir(targetURL, depth: 1, budget: &budget)
                }
            } else {
                // If a tracked file was deleted in the working tree (` D path`), check parent directory mtime
                let parentURL = targetURL.deletingLastPathComponent()
                if let pVals = try? parentURL.resourceValues(forKeys: [.contentModificationDateKey]) {
                    recordMod(pVals.contentModificationDate)
                }
            }
        }

        return latest
    }

    /// Discovers candidate regenerable artifact paths inside a worktree up to subproject depth 3 without descending into heavy artifact folders.
    private func discoverCandidateArtifactPaths(
        in worktreePath: String,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
        var results: [String] = []

        let directArtifactDirNames: Set<String> = [
            "node_modules",
            ".next",
            ".turbo",
            "dist",
            "build",
            ".expo",
            ".nuxt",
            ".svelte-kit",
            ".astro",
            ".vite",
            ".parcel-cache",
            ".eslintcache",
            ".metro",
            ".metro-cache",
            ".angular",
            ".docusaurus",
            "Pods",
            ".build",
            ".gradle",
            ".tsbuildinfo"
        ]

        let skippedDescentNames: Set<String> = directArtifactDirNames.union([
            ".git", ".claude", ".codex", "src", "public", "assets", "migrations", "uploads", "vendor"
        ])

        func inspectDirectory(_ dirURL: URL, depth: Int) {
            if shouldCancel?() == true || Task.isCancelled { return }
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else {
                return
            }

            let sorted = children.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for childURL in sorted {
                let name = childURL.lastPathComponent
                if name == ".DS_Store" || name == ".git" { continue }

                let childPath = childURL.standardizedFileURL.path
                let vals = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymlink = vals?.isSymbolicLink == true
                let isDir = vals?.isDirectory == true

                // 1. Check TypeScript .tsbuildinfo files or directories
                if name.hasSuffix(".tsbuildinfo") || name == ".tsbuildinfo" {
                    results.append(childPath)
                    continue
                }

                // 2. Check direct artifact directory names (including symlinks with these names so they get flagged as REVIEW)
                if directArtifactDirNames.contains(name) && (isDir || isSymlink) {
                    results.append(childPath)
                    continue
                }

                // 3. Check .firebase/emulators
                if name == ".firebase" && isDir && !isSymlink {
                    let emulatorsURL = childURL.appendingPathComponent("emulators")
                    if fm.fileExists(atPath: emulatorsURL.path) {
                        results.append(emulatorsURL.standardizedFileURL.path)
                    }
                    continue
                }

                // 4. Check .cache selectively (including verified nested build/DerivedData/emulator directories up to depth 3 inside .cache)
                if name == ".cache" && (isDir || isSymlink) {
                    if isSymlink {
                        results.append(childPath)
                        continue
                    }
                    let dotCacheMatch = validator.inspectWorktreeArtifactSafety(at: childPath, worktreeRoot: worktreePath)
                    if dotCacheMatch?.classification == .safe {
                        results.append(childPath)
                        continue
                    }

                    let cacheChildren = (try? fm.contentsOfDirectory(
                        at: childURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    var matchedAnyInCache = false

                    for subURL in cacheChildren.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        let subName = subURL.lastPathComponent
                        let subPath = subURL.standardizedFileURL.path
                        if subName == "firebase" {
                            let fbEmulators = subURL.appendingPathComponent("emulators")
                            if fm.fileExists(atPath: fbEmulators.path) {
                                results.append(fbEmulators.standardizedFileURL.path)
                                matchedAnyInCache = true
                                continue
                            }
                        }
                        if let subMatch = validator.inspectWorktreeArtifactSafety(at: subPath, worktreeRoot: worktreePath),
                           subMatch.classification == .safe {
                            results.append(subPath)
                            matchedAnyInCache = true
                            continue
                        }
                        // Check one level deeper inside `.cache/<group>/<target>` for verified Xcode DerivedData / SYMROOT / Gradle builds
                        let nestedDirs = (try? fm.contentsOfDirectory(
                            at: subURL,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        var matchedNestedSafe = false
                        for nestedURL in nestedDirs {
                            let nestedPath = nestedURL.standardizedFileURL.path
                            if SafetyValidator.verifyCleanableProjectArtifact(at: nestedPath, projectRoot: worktreePath) != nil {
                                results.append(nestedPath)
                                matchedNestedSafe = true
                                matchedAnyInCache = true
                            }
                        }
                        if !matchedNestedSafe {
                            results.append(subPath)
                            matchedAnyInCache = true
                        }
                    }
                    if !matchedAnyInCache {
                        results.append(childPath)
                    }
                    continue
                }

                // 5. Descend into subproject / workspace containers up to depth 3
                if isDir && !isSymlink && depth < 3 && !skippedDescentNames.contains(name) && !name.hasPrefix(".") {
                    inspectDirectory(childURL, depth: depth + 1)
                }
            }
        }

        inspectDirectory(rootURL, depth: 0)
        return results
    }

    // MARK: - Safe Cleanup Execution for Worktree Artifacts

    /// Safely cleans only `SAFE` worktree artifacts by delegating to `CleanupExecutor` (the single authoritative destructive execution path).
    /// Preserves the worktree itself, tracked files, branches, commits, and `git status`, failing closed with automatic rollback if `git status` changes unexpectedly.
    public func cleanWorktreeArtifacts(
        candidates: [WorktreeArtifactCandidate],
        trashHandler: (@Sendable (URL) throws -> Void)? = nil,
        reversibleTrashHandler: (@Sendable (URL) throws -> URL?)? = nil
    ) async -> WorktreeCleanupReport {
        let executor = CleanupExecutor(
            validator: self.validator,
            processChecker: { _ in [] },
            trashHandler: trashHandler,
            reversibleTrashHandler: reversibleTrashHandler,
            shellRunner: self.shellRunner
        )
        return await executor.executeWorktreeCandidates(candidates)
    }

    public enum TrashRollbackOutcome: Equatable, Sendable {
        case restored
        case destinationAlreadyExists(trashPath: String?)
        case failedToRestore(trashPath: String?, errorDescription: String)
    }

    /// Attempts to restore an item from `trashedURL` back to `originalPath` if post-clean verification fails.
    /// Never overwrites `originalPath` if a file or directory has already been recreated there.
    public static func attemptTrashRollback(
        trashedURL: URL?,
        originalPath: String
    ) -> TrashRollbackOutcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: originalPath) {
            return .destinationAlreadyExists(trashPath: trashedURL?.path)
        }
        guard let trashedURL else {
            return .failedToRestore(trashPath: nil, errorDescription: "Resulting Trash URL was not available")
        }
        guard fm.fileExists(atPath: trashedURL.path) else {
            return .failedToRestore(trashPath: trashedURL.path, errorDescription: "Trashed item no longer exists at \(trashedURL.path)")
        }
        do {
            try fm.moveItem(at: trashedURL, to: URL(fileURLWithPath: originalPath))
            return .restored
        } catch {
            return .failedToRestore(trashPath: trashedURL.path, errorDescription: error.localizedDescription)
        }
    }

    /// Verifies that `git status --porcelain` after cleanup matches `beforePorcelain` (accounting for any untracked `??` entries that were the cleaned artifacts themselves).
    public static func isGitStatusPreserved(
        beforePorcelain: String,
        afterPorcelain: String,
        cleanedRelativePaths: [String]
    ) -> Bool {
        if beforePorcelain == afterPorcelain {
            return true
        }
        func normalizeLines(_ raw: String, excludingUntrackedRels: [String]) -> [String] {
            raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { line in
                    guard !line.isEmpty, !line.hasPrefix("## ") else { return false }
                    if line.hasPrefix("?? ") {
                        let rawPath = String(line.dropFirst(3))
                        let cleaned = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
                        if excludingUntrackedRels.contains(where: { rel in
                            cleaned == rel || cleaned.hasPrefix(rel + "/") || rel.hasPrefix(cleaned + "/")
                        }) {
                            return false
                        }
                    }
                    return true
                }
        }
        let expectedRemaining = normalizeLines(beforePorcelain, excludingUntrackedRels: cleanedRelativePaths)
        let actualRemaining = normalizeLines(afterPorcelain, excludingUntrackedRels: [])
        return expectedRemaining == actualRemaining
    }

    public static func extractUntrackedPaths(fromPorcelainStatus output: String) -> [String] {
        var result: [String] = []
        for line in output.components(separatedBy: .newlines) where line.hasPrefix("?? ") && line.count > 3 {
            result.append(String(line.dropFirst(3)))
        }
        return result
    }

    public static func parseGitStatusPorcelainBranch(
        _ output: String,
        isDetached: Bool
    ) -> (modifiedCount: Int, untrackedCount: Int, stagedCount: Int, sampleFiles: [String], remoteStatus: String) {
        var modifiedCount = 0
        var untrackedCount = 0
        var stagedCount = 0
        var sampleFiles: [String] = []
        var remoteStatus = isDetached ? "Detached HEAD (no upstream branch)" : "Local branch only (no remote tracking)"

        let lines = output.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                if header.contains("...") {
                    let parts = header.components(separatedBy: "...")
                    let rightSide = parts.count > 1 ? parts[1] : ""
                    if rightSide.contains("[") {
                        remoteStatus = "Tracking \(rightSide)"
                    } else {
                        remoteStatus = "Up to date with \(rightSide)"
                    }
                } else if header.contains("HEAD (no branch)") {
                    remoteStatus = "Detached HEAD (no upstream branch)"
                } else {
                    remoteStatus = "Local branch (\(header)) — no remote upstream"
                }
                continue
            }

            guard line.count >= 3 else { continue }
            let idxStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            let filePath = String(line.dropFirst(3))

            if idxStatus == "?" && workTreeStatus == "?" {
                untrackedCount += 1
            } else {
                if idxStatus != " " && idxStatus != "?" {
                    stagedCount += 1
                }
                if workTreeStatus != " " && workTreeStatus != "?" {
                    modifiedCount += 1
                }
            }
            if sampleFiles.count < 5 {
                sampleFiles.append(filePath)
            }
        }

        return (modifiedCount, untrackedCount, stagedCount, sampleFiles, remoteStatus)
    }

    public static func evaluateWorkLossRisk(
        existsOnDisk: Bool,
        isLocked: Bool,
        lockReason: String?,
        isInUse: Bool,
        activeProcesses: [String],
        hasUncommittedChanges: Bool,
        modifiedCount: Int,
        untrackedCount: Int,
        stagedCount: Int,
        isDetached: Bool,
        remoteStatus: String,
        isPrunable: Bool
    ) -> (RiskLevel, String) {
        if isLocked {
            let reason = lockReason.map { " (\($0))" } ?? ""
            return (.neverDelete, "Locked git worktree\(reason). Protected against removal.")
        }
        if isInUse {
            return (.neverDelete, "Currently in use by \(activeProcesses.joined(separator: ", ")).")
        }
        if hasUncommittedChanges {
            var details: [String] = []
            if modifiedCount > 0 { details.append("\(modifiedCount) modified") }
            if stagedCount > 0 { details.append("\(stagedCount) staged") }
            if untrackedCount > 0 { details.append("\(untrackedCount) untracked") }
            return (.caution, "HIGH RISK OF WORK LOSS: Contains uncommitted local changes (\(details.joined(separator: ", "))). Worktree itself is never deleted; regenerable artifacts require review.")
        }
        if !existsOnDisk && isPrunable {
            return (.review, "Worktree directory no longer exists on disk (marked prunable by Git). Informative only.")
        }
        if isDetached {
            return (.caution, "Detached HEAD worktree — commits or build state may not be on a named branch. Worktree itself is preserved; only verified SAFE regenerable artifacts can be cleaned.")
        }
        if remoteStatus.localizedCaseInsensitiveContains("ahead") || remoteStatus.localizedCaseInsensitiveContains("no remote") {
            return (.caution, "Branch has unpushed commits or no remote upstream (\(remoteStatus)). Worktree and Git history are preserved; only verified SAFE regenerable artifacts can be cleaned.")
        }
        return (.review, "Clean working tree (\(remoteStatus)). Worktree itself is never auto-deleted; verified SAFE regenerable artifacts inside can be cleaned safely.")
    }
}
