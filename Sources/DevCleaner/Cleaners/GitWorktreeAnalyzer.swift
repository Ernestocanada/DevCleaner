import Foundation

public final class GitWorktreeAnalyzer: Sendable {
    public let shellRunner: @Sendable (String, [String]) async -> ShellResult

    public init(
        shellRunner: @escaping @Sendable (String, [String]) async -> ShellResult = { executable, arguments in
            await ShellRunner.shared.run(executable, arguments: arguments)
        }
    ) {
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
        snapshot: ActiveProcessSnapshot,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async -> [GitWorktreeRecord] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard let children = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

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

        for repoURL in sortedDirs {
            if shouldCancel?() == true || Task.isCancelled { break }
            let repoPath = repoURL.standardizedFileURL.path
            let listRes = await shellRunner("/usr/bin/git", ["-C", repoPath, "worktree", "list", "--porcelain"])
            guard listRes.isSuccess else { continue }

            let parsedList = Self.parsePorcelainWorktreeList(listRes.stdout)
            guard let mainWorktree = parsedList.first else { continue }
            let mainPath = URL(fileURLWithPath: mainWorktree.path).standardizedFileURL.path

            // Deduplicate if multiple directories in ~/Developer belong to the same main repository worktree group
            if seenMainWorktreePaths.contains(mainPath) {
                continue
            }
            seenMainWorktreePaths.insert(mainPath)

            let sourceProjectName = URL(fileURLWithPath: mainPath).lastPathComponent

            // Inspect all linked/secondary worktrees (index >= 1)
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
                    snapshot: snapshot,
                    shouldCancel: shouldCancel
                )
                records.append(record)
            }
        }

        records.sort { lhs, rhs in
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

    private func inspectSingleWorktree(
        wt: ParsedPorcelainWorktree,
        standardizedPath: String,
        sourceProjectName: String,
        sourceProjectPath: String,
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

        let shortCommit = wt.head.count > 8 ? String(wt.head.prefix(8)) : wt.head
        let branchLabel: String = {
            if let ref = wt.branchRef {
                if ref.hasPrefix("refs/heads/") {
                    return String(ref.dropFirst("refs/heads/".count))
                }
                return ref
            }
            if wt.isDetached {
                return "Detached HEAD (\(shortCommit))"
            }
            return shortCommit.isEmpty ? "Unknown" : shortCommit
        }()

        var physicalBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var nodeModulesBytes: Int64 = 0
        var buildAndCacheBytes: Int64 = 0
        var lastModified: Date?

        if existsOnDisk {
            // Measure heavy subdirectories inside the worktree first so we can report breakdown without double counting
            var subExcluded = Set<String>()
            let wtURL = URL(fileURLWithPath: standardizedPath)
            let nmURL = wtURL.appendingPathComponent("node_modules")
            if fm.fileExists(atPath: nmURL.path) {
                let nmPath = nmURL.standardizedFileURL.path
                let nmUsage = DiskScanner.shared.measurePath(nmPath, shouldCancel: shouldCancel)
                nodeModulesBytes = nmUsage.physicalSize
                physicalBytes += nmUsage.physicalSize
                logicalBytes += nmUsage.logicalSize
                lastModified = nmUsage.lastModified
                subExcluded.insert(nmPath)
            }

            for cacheDirName in [".next", ".expo", ".turbo", ".build", ".cache", "build", "dist"] {
                let cURL = wtURL.appendingPathComponent(cacheDirName)
                if fm.fileExists(atPath: cURL.path) {
                    let cPath = cURL.standardizedFileURL.path
                    let cUsage = DiskScanner.shared.measurePath(cPath, shouldCancel: shouldCancel)
                    buildAndCacheBytes += cUsage.physicalSize
                    physicalBytes += cUsage.physicalSize
                    logicalBytes += cUsage.logicalSize
                    if let mod = cUsage.lastModified, lastModified == nil || mod > lastModified! {
                        lastModified = mod
                    }
                    subExcluded.insert(cPath)
                }
            }

            let restUsage = DiskScanner.shared.measurePath(
                standardizedPath,
                excludedSubpaths: subExcluded,
                shouldCancel: shouldCancel
            )
            physicalBytes += restUsage.physicalSize
            logicalBytes += restUsage.logicalSize
            if let mod = restUsage.lastModified, lastModified == nil || mod > lastModified! {
                lastModified = mod
            }
        }

        // Query git status inside the worktree if it exists on disk
        var modifiedCount = 0
        var untrackedCount = 0
        var stagedCount = 0
        var sampleChangedFiles: [String] = []
        var remoteBranchStatus = existsOnDisk ? "No upstream tracking branch" : "Directory missing on disk"

        if existsOnDisk {
            let statusRes = await shellRunner("/usr/bin/git", ["-C", standardizedPath, "status", "--porcelain", "--branch"])
            if statusRes.isSuccess {
                let parsedStatus = Self.parseGitStatusPorcelainBranch(statusRes.stdout, isDetached: wt.isDetached)
                modifiedCount = parsedStatus.modifiedCount
                untrackedCount = parsedStatus.untrackedCount
                stagedCount = parsedStatus.stagedCount
                sampleChangedFiles = parsedStatus.sampleFiles
                remoteBranchStatus = parsedStatus.remoteStatus
            }
        }

        let hasUncommittedChanges = (modifiedCount + untrackedCount + stagedCount) > 0
        let activeProcesses = snapshot.matchingProcesses(forProjectPath: standardizedPath)
        let isInUse = !activeProcesses.isEmpty

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
            path: standardizedPath,
            originKind: originKind,
            headCommit: shortCommit,
            branchLabel: branchLabel,
            isDetached: wt.isDetached,
            physicalBytes: physicalBytes,
            logicalBytes: logicalBytes,
            nodeModulesBytes: nodeModulesBytes,
            buildAndCacheBytes: buildAndCacheBytes,
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
            lastModifiedDate: lastModified,
            workLossRisk: risk,
            riskExplanation: explanation
        )
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
            return (.caution, "HIGH RISK OF WORK LOSS: Contains uncommitted local changes (\(details.joined(separator: ", "))). Informative only.")
        }
        if !existsOnDisk && isPrunable {
            return (.review, "Worktree directory no longer exists on disk (marked prunable by Git). Informative only.")
        }
        if isDetached {
            return (.caution, "Detached HEAD worktree — commits or build state may not be on a named branch. Informative only.")
        }
        if remoteStatus.localizedCaseInsensitiveContains("ahead") || remoteStatus.localizedCaseInsensitiveContains("no remote") {
            return (.caution, "Branch has unpushed commits or no remote upstream (\(remoteStatus)). Informative only.")
        }
        return (.review, "Clean working tree (\(remoteStatus)), but worktrees are never auto-deleted. Inspect branch before manual git cleanup.")
    }
}
