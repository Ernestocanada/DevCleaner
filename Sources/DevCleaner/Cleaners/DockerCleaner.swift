import Foundation

public struct DockerCLIStats: Sendable, Equatable {
    public var imagesTotalCount: Int
    public var imagesActiveCount: Int
    public var imagesSizeBytes: Int64
    public var imagesReclaimableBytes: Int64
    public var danglingImagesCount: Int
    public var danglingImagesReclaimableBytes: Int64

    public var unusedNonDanglingImagesReclaimableBytes: Int64 {
        max(0, imagesReclaimableBytes - danglingImagesReclaimableBytes)
    }

    public var containersTotalCount: Int
    public var containersRunningCount: Int
    public var containersStoppedCount: Int
    public var containersSizeBytes: Int64
    public var containersReclaimableBytes: Int64

    public var volumesTotalCount: Int
    public var volumesActiveCount: Int
    public var volumesSizeBytes: Int64
    public var volumesReclaimableBytes: Int64

    public var buildCacheTotalCount: Int
    public var buildCacheActiveCount: Int
    public var buildCacheSizeBytes: Int64
    public var buildCacheReclaimableBytes: Int64
    public var buildCacheVerified: Bool

    public static let zero = DockerCLIStats(
        imagesTotalCount: 0,
        imagesActiveCount: 0,
        imagesSizeBytes: 0,
        imagesReclaimableBytes: 0,
        danglingImagesCount: 0,
        danglingImagesReclaimableBytes: 0,
        containersTotalCount: 0,
        containersRunningCount: 0,
        containersStoppedCount: 0,
        containersSizeBytes: 0,
        containersReclaimableBytes: 0,
        volumesTotalCount: 0,
        volumesActiveCount: 0,
        volumesSizeBytes: 0,
        volumesReclaimableBytes: 0,
        buildCacheTotalCount: 0,
        buildCacheActiveCount: 0,
        buildCacheSizeBytes: 0,
        buildCacheReclaimableBytes: 0,
        buildCacheVerified: false
    )

    public init(
        imagesTotalCount: Int,
        imagesActiveCount: Int,
        imagesSizeBytes: Int64,
        imagesReclaimableBytes: Int64,
        danglingImagesCount: Int = 0,
        danglingImagesReclaimableBytes: Int64 = 0,
        containersTotalCount: Int,
        containersRunningCount: Int,
        containersStoppedCount: Int,
        containersSizeBytes: Int64,
        containersReclaimableBytes: Int64,
        volumesTotalCount: Int,
        volumesActiveCount: Int,
        volumesSizeBytes: Int64,
        volumesReclaimableBytes: Int64,
        buildCacheTotalCount: Int,
        buildCacheActiveCount: Int,
        buildCacheSizeBytes: Int64,
        buildCacheReclaimableBytes: Int64,
        buildCacheVerified: Bool = true
    ) {
        self.imagesTotalCount = imagesTotalCount
        self.imagesActiveCount = imagesActiveCount
        self.imagesSizeBytes = imagesSizeBytes
        self.imagesReclaimableBytes = imagesReclaimableBytes
        self.danglingImagesCount = danglingImagesCount
        self.danglingImagesReclaimableBytes = danglingImagesReclaimableBytes
        self.containersTotalCount = containersTotalCount
        self.containersRunningCount = containersRunningCount
        self.containersStoppedCount = containersStoppedCount
        self.containersSizeBytes = containersSizeBytes
        self.containersReclaimableBytes = containersReclaimableBytes
        self.volumesTotalCount = volumesTotalCount
        self.volumesActiveCount = volumesActiveCount
        self.volumesSizeBytes = volumesSizeBytes
        self.volumesReclaimableBytes = volumesReclaimableBytes
        self.buildCacheTotalCount = buildCacheTotalCount
        self.buildCacheActiveCount = buildCacheActiveCount
        self.buildCacheSizeBytes = buildCacheSizeBytes
        self.buildCacheReclaimableBytes = buildCacheReclaimableBytes
        self.buildCacheVerified = buildCacheVerified
    }
}

public struct DockerCleaner: CleanerProvider {
    public let category: CleanerCategory = .docker
    private let home: String
    private let executor: CleanupExecutor
    private let daemonRunningOverride: Bool?
    private let diskUsageOverride: DiskUsageInfo?
    private let cliStatsOverride: DockerCLIStats?

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executor: CleanupExecutor = CleanupExecutor(),
        daemonRunningOverride: Bool? = nil,
        diskUsageOverride: DiskUsageInfo? = nil,
        cliStatsOverride: DockerCLIStats? = nil
    ) {
        self.home = homeDirectory
        self.executor = executor
        self.daemonRunningOverride = daemonRunningOverride
        self.diskUsageOverride = diskUsageOverride
        self.cliStatsOverride = cliStatsOverride
    }

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let containerRoot = "\(home)/Library/Containers/com.docker.docker"
        let rawFile = "\(containerRoot)/Data/vms/0/data/Docker.raw"

        let hasContainer = diskUsageOverride != nil || FileManager.default.fileExists(atPath: containerRoot)
        guard hasContainer else { return [] }

        let usage: DiskUsageInfo
        let targetPath: String
        if let overrideUsage = diskUsageOverride {
            usage = overrideUsage
            targetPath = rawFile
        } else if FileManager.default.fileExists(atPath: rawFile) {
            usage = DiskScanner.shared.measurePath(rawFile)
            targetPath = rawFile
        } else {
            usage = DiskScanner.shared.measurePath(containerRoot)
            targetPath = containerRoot
        }

        let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        let dockerBin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })

        let daemonRunning: Bool
        if let overrideDaemon = daemonRunningOverride {
            daemonRunning = overrideDaemon
        } else if let bin = dockerBin {
            let infoRes = await ShellRunner.shared.run(bin, arguments: ["info", "--format", "{{.ServerVersion}}"], timeoutSeconds: 5)
            daemonRunning = infoRes.isSuccess && !infoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            daemonRunning = false
        }

        let stats: DockerCLIStats?
        if let overrideStats = cliStatsOverride {
            stats = daemonRunning ? overrideStats : nil
        } else if daemonRunning, let bin = dockerBin {
            stats = await Self.fetchLiveDockerCLIStats(dockerBinary: bin)
        } else {
            stats = nil
        }

        let statusDesc: String
        if daemonRunning, let stats {
            let verifiedBuildCacheReclaimable = stats.buildCacheVerified ? stats.buildCacheReclaimableBytes : 0
            let safeReclaimable = stats.danglingImagesReclaimableBytes + stats.containersReclaimableBytes + verifiedBuildCacheReclaimable
            statusDesc = "Docker Desktop is running (Images: \(stats.imagesTotalCount) [\(stats.danglingImagesCount) dangling], Containers: \(stats.containersRunningCount) running / \(stats.containersStoppedCount) stopped, Volumes: \(stats.volumesTotalCount), Reclaimable SAFE: \(Formatters.bytes(safeReclaimable)))."
        } else if daemonRunning {
            statusDesc = "Docker Desktop is running."
        } else {
            statusDesc = "Docker Desktop is stopped (daemon offline). Start Docker Desktop to inspect images/containers/volumes/build-cache and enable CLI prune commands."
        }

        items.append(
            CleanableItem(
                id: "docker-raw-disk",
                name: "Docker Desktop VM Disk (Docker.raw — NEVER DELETE DIRECTLY)",
                category: .docker,
                path: targetPath,
                logicalSize: usage.logicalSize,
                physicalSize: usage.physicalSize,
                reclaimableSize: 0,
                lastModified: usage.lastModified,
                riskLevel: .neverDelete,
                explanation: "APFS sparse virtual disk used by Docker Desktop Linux VM. Physical disk usage: \(ByteCountFormatter.string(fromByteCount: usage.physicalSize, countStyle: .file)) • Logical sparse size: \(ByteCountFormatter.string(fromByteCount: usage.logicalSize, countStyle: .file)). \(statusDesc)",
                deletionConsequence: "NEVER DELETE DIRECTLY: Deleting Docker.raw destroys your entire Docker VM. Use official Docker CLI prune actions below when Docker is running.",
                regenerationImpact: "Managed by Docker Desktop.",
                isRunningDependency: false,
                runningProcessNames: [],
                actionType: .readOnlyInfo(reason: "Docker.raw must never be deleted directly.")
            )
        )

        let buildCacheVerified = stats?.buildCacheVerified ?? false
        let buildCacheReclaimable = (daemonRunning && buildCacheVerified) ? (stats?.buildCacheReclaimableBytes ?? 0) : 0
        let buildCacheTotal = stats?.buildCacheSizeBytes ?? 0
        let buildCacheDetail: String = {
            guard stats != nil else { return "" }
            if buildCacheVerified {
                return " (Total: \(Formatters.bytes(buildCacheTotal)) • Reclaimable by prune: \(Formatters.bytes(buildCacheReclaimable)))"
            } else {
                return " (Total: \(Formatters.bytes(buildCacheTotal)) • Exact safe reclaimable size unverified)"
            }
        }()
        let buildCacheExplanation: String = {
            if !daemonRunning || stats != nil && buildCacheVerified {
                return "Removes only non-in-use, unshared BuildKit cache layers that `docker builder prune -f` actually removes.\(buildCacheDetail)"
            } else {
                return "REVIEW: Exact safe reclaimable size for `docker builder prune -f` could not be verified from `docker builder du`. DevCleaner does not fall back to `docker system df` build-cache estimates for SAFE cleanup.\(buildCacheDetail)"
            }
        }()
        let buildCacheAction: CleanupActionType = {
            guard daemonRunning else {
                return .readOnlyInfo(reason: "Docker Desktop is not running. Start Docker to use CLI cleanup.")
            }
            guard buildCacheVerified else {
                return .readOnlyInfo(reason: "Exact safe reclaimable build-cache size could not be verified via 'docker builder du'.")
            }
            return .dockerPrune(subcommand: ["builder", "prune", "-f"])
        }()

        let containersReclaimable = stats?.containersReclaimableBytes ?? 0
        let containersDetail = stats != nil
            ? " (\(stats!.containersStoppedCount) stopped / \(stats!.containersRunningCount) running • Reclaimable: \(Formatters.bytes(containersReclaimable)))"
            : ""

        let danglingImagesCount = stats?.danglingImagesCount ?? 0
        let danglingImagesReclaimable = stats?.danglingImagesReclaimableBytes ?? 0
        let danglingImagesDetail = stats != nil
            ? " (\(danglingImagesCount) dangling images • Reclaimable: \(Formatters.bytes(danglingImagesReclaimable)))"
            : ""

        let unusedNonDanglingReclaimable = stats?.unusedNonDanglingImagesReclaimableBytes ?? 0
        let totalUnusedImagesReclaimable = stats?.imagesReclaimableBytes ?? 0
        let imagesTotal = stats?.imagesSizeBytes ?? 0
        let unusedImagesDetail = stats != nil
            ? " (\(stats!.imagesTotalCount) images, \(Formatters.bytes(imagesTotal)) total • Unused beyond dangling: \(Formatters.bytes(unusedNonDanglingReclaimable)) • Total unused with -a: \(Formatters.bytes(totalUnusedImagesReclaimable)))"
            : ""

        let volumesReclaimable = stats?.volumesReclaimableBytes ?? 0
        let volumesTotal = stats?.volumesSizeBytes ?? 0
        let volumesDetail = stats != nil
            ? " (\(stats!.volumesTotalCount) volumes, \(Formatters.bytes(volumesTotal)) total • Reclaimable: \(Formatters.bytes(volumesReclaimable)))"
            : ""

        let pruneSpecs: [(id: String, name: String, args: [String], risk: RiskLevel, reclaimable: Int64, desc: String, requiresRedownload: Bool, customAction: CleanupActionType?)] = [
            (
                "docker-prune-build-cache",
                "Docker Build Cache (docker builder prune -f)\(buildCacheDetail)",
                ["builder", "prune", "-f"],
                (daemonRunning && buildCacheVerified && buildCacheReclaimable > 0) ? .safe : .review,
                buildCacheReclaimable,
                buildCacheExplanation,
                false,
                buildCacheAction
            ),
            (
                "docker-prune-stopped-containers",
                "Docker Stopped Containers (docker container prune -f)\(containersDetail)",
                ["container", "prune", "-f"],
                (daemonRunning && containersReclaimable > 0) ? .safe : .review,
                daemonRunning ? containersReclaimable : 0,
                "Removes stopped containers via official Docker CLI (`docker container ls -a`).\(containersDetail)",
                false,
                nil
            ),
            (
                "docker-prune-dangling-images",
                "Docker Dangling Images (docker image prune -f)\(danglingImagesDetail)",
                ["image", "prune", "-f"],
                (daemonRunning && danglingImagesReclaimable > 0) ? .safe : .review,
                daemonRunning ? danglingImagesReclaimable : 0,
                "SAFE: Removes only untagged/dangling container images (`docker image ls -f dangling=true`). Tagged unused images are preserved.\(danglingImagesDetail)",
                false,
                nil
            ),
            (
                "docker-prune-unused-images",
                "Docker Unused Non-Dangling Images (docker image prune -a -f)\(unusedImagesDetail)",
                ["image", "prune", "-a", "-f"],
                .review, // Always REVIEW: removes tagged images not currently used by any container
                daemonRunning ? unusedNonDanglingReclaimable : 0,
                "REVIEW: Removes unused container images beyond dangling ones (`docker image prune -a -f`). Re-pulling base images will require a network download.\(unusedImagesDetail)",
                true,
                nil
            ),
            (
                "docker-prune-volumes",
                "Docker Unused Volumes (docker volume prune -f)\(volumesDetail)",
                ["volume", "prune", "-f"],
                .caution, // Volumes are ALWAYS CAUTION, never SAFE automatically
                daemonRunning ? volumesReclaimable : 0,
                "CAUTION: Permanently removes unused local Docker volumes (`docker volume ls`). May contain database or persistent container data.\(volumesDetail)",
                false,
                nil
            )
        ]

        for spec in pruneSpecs {
            let resolvedAction: CleanupActionType = spec.customAction ?? (
                daemonRunning
                    ? .dockerPrune(subcommand: spec.args)
                    : .readOnlyInfo(reason: "Docker Desktop is not running. Start Docker to use CLI cleanup.")
            )
            items.append(
                CleanableItem(
                    id: spec.id,
                    name: spec.name,
                    category: .docker,
                    path: containerRoot,
                    logicalSize: 0,
                    physicalSize: 0,
                    reclaimableSize: spec.reclaimable,
                    lastModified: usage.lastModified,
                    riskLevel: spec.risk,
                    explanation: daemonRunning ? spec.desc : "\(spec.desc) (Requires Docker Desktop running)",
                    deletionConsequence: "Executes official 'docker \(spec.args.joined(separator: " "))'.",
                    regenerationImpact: "Container images or build cache layers will be pulled/rebuilt on next docker build/run.",
                    isRunningDependency: false,
                    runningProcessNames: [],
                    actionType: resolvedAction,
                    requiresRedownload: spec.requiresRedownload
                )
            )
        }

        return items
    }

    public static func fetchLiveDockerCLIStats(
        dockerBinary: String,
        runner: (@Sendable (String, [String]) async -> ShellResult)? = nil
    ) async -> DockerCLIStats {
        let exec: @Sendable (String, [String], TimeInterval) async -> ShellResult = { bin, args, timeout in
            if let runner {
                return await runner(bin, args)
            }
            return await ShellRunner.shared.run(bin, arguments: args, timeoutSeconds: timeout)
        }

        async let dfRes = exec(dockerBinary, ["system", "df", "--format", "{{json .}}"], 8)
        async let danglingRes = exec(dockerBinary, ["image", "ls", "-f", "dangling=true", "--format", "{{.ID}}\t{{.Size}}"], 5)
        async let psRes = exec(dockerBinary, ["container", "ls", "-a", "--format", "{{.State}}"], 5)
        async let imgRes = exec(dockerBinary, ["image", "ls", "-q"], 5)
        async let volRes = exec(dockerBinary, ["volume", "ls", "-q"], 5)
        async let builderJSONRes = exec(dockerBinary, ["builder", "du", "--format", "{{json .}}"], 5)

        let (df, dangling, ps, img, vol, builderJSON) = await (dfRes, danglingRes, psRes, imgRes, volRes, builderJSONRes)
        let builderOutput: String?
        if builderJSON.isSuccess && !builderJSON.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            builderOutput = builderJSON.stdout
        } else {
            let builderTable = await exec(dockerBinary, ["builder", "du"], 5)
            builderOutput = builderTable.isSuccess ? builderTable.stdout : nil
        }

        var stats = parseDockerSystemDFJSONLines(
            df.stdout,
            danglingImagesOutput: dangling.isSuccess ? dangling.stdout : nil,
            builderDUOutput: builderOutput
        )

        if ps.isSuccess {
            let states = ps.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
            if !states.isEmpty {
                let running = states.filter { $0 == "running" }.count
                let stopped = states.count - running
                stats.containersTotalCount = states.count
                stats.containersRunningCount = running
                stats.containersStoppedCount = stopped
            }
        }
        if img.isSuccess {
            let ids = Set(img.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if !ids.isEmpty && stats.imagesTotalCount == 0 {
                stats.imagesTotalCount = ids.count
            }
        }
        if vol.isSuccess {
            let vols = Set(vol.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if !vols.isEmpty && stats.volumesTotalCount == 0 {
                stats.volumesTotalCount = vols.count
            }
        }
        return stats
    }

    public static func parseDockerSystemDFJSONLines(
        _ output: String,
        danglingImagesOutput: String? = nil,
        builderDUOutput: String? = nil
    ) -> DockerCLIStats {
        var stats = DockerCLIStats.zero
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let typeName = (dict["Type"] as? String ?? "").lowercased()
            let totalCount = Int(String(describing: dict["TotalCount"] ?? "0")) ?? 0
            let activeCount = Int(String(describing: dict["Active"] ?? "0")) ?? 0
            let sizeBytes = parseDockerSizeString(dict["Size"] as? String ?? "0B")
            let reclaimableBytes = parseDockerSizeString(dict["Reclaimable"] as? String ?? "0B")

            if typeName.contains("image") {
                stats.imagesTotalCount = totalCount
                stats.imagesActiveCount = activeCount
                stats.imagesSizeBytes = sizeBytes
                // Note: docker system df "Images" Reclaimable includes all unused images (dangling + tagged unused).
                // Dangling-only bytes for `docker image prune -f` come from `docker image ls -f dangling=true`.
                stats.imagesReclaimableBytes = reclaimableBytes
            } else if typeName.contains("container") {
                stats.containersTotalCount = totalCount
                stats.containersRunningCount = activeCount
                stats.containersStoppedCount = max(0, totalCount - activeCount)
                stats.containersSizeBytes = sizeBytes
                stats.containersReclaimableBytes = reclaimableBytes
            } else if typeName.contains("volume") {
                stats.volumesTotalCount = totalCount
                stats.volumesActiveCount = activeCount
                stats.volumesSizeBytes = sizeBytes
                stats.volumesReclaimableBytes = reclaimableBytes
            } else if typeName.contains("build") {
                stats.buildCacheTotalCount = totalCount
                stats.buildCacheActiveCount = activeCount
                stats.buildCacheSizeBytes = sizeBytes
                // Do NOT fall back to `docker system df` build-cache reclaimable bytes for SAFE cleanup.
                // Reclaimable bytes remain 0 and unverified until `docker builder du` is parsed reliably.
                stats.buildCacheReclaimableBytes = 0
                stats.buildCacheVerified = false
            }
        }

        if let danglingImagesOutput {
            let parsedDangling = parseDockerDanglingImagesOutput(danglingImagesOutput)
            stats.danglingImagesCount = parsedDangling.count
            if stats.imagesReclaimableBytes > 0 {
                stats.danglingImagesReclaimableBytes = min(stats.imagesReclaimableBytes, parsedDangling.bytes)
            } else {
                stats.danglingImagesReclaimableBytes = parsedDangling.bytes
                stats.imagesReclaimableBytes = max(stats.imagesReclaimableBytes, parsedDangling.bytes)
            }
        }

        if let builderDUOutput, let builderPruneBytes = parseDockerBuilderDUOutput(builderDUOutput) {
            stats.buildCacheReclaimableBytes = builderPruneBytes
            stats.buildCacheVerified = true
        } else {
            stats.buildCacheReclaimableBytes = 0
            stats.buildCacheVerified = false
        }

        return stats
    }

    /// Parses `docker image ls -f dangling=true --format "{{.ID}}\t{{.Size}}"` (or JSON lines) deduplicating by image ID.
    public static func parseDockerDanglingImagesOutput(_ output: String) -> (count: Int, bytes: Int64) {
        var seenIDs = Set<String>()
        var totalBytes: Int64 = 0

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("{"),
               let data = line.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let id = (dict["ID"] as? String ?? UUID().uuidString).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                let sizeStr = dict["Size"] as? String ?? "0B"
                totalBytes += parseDockerSizeString(sizeStr)
                continue
            }

            let lower = line.lowercased()
            if lower.hasPrefix("repository") || lower.hasPrefix("image id") {
                continue
            }

            let tabParts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if tabParts.count >= 2 {
                let id = tabParts[0]
                guard !id.isEmpty, !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                totalBytes += parseDockerSizeString(tabParts[1])
            } else {
                let wsParts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if wsParts.count >= 2 {
                    let id = wsParts[0]
                    let sizeCandidate = wsParts.last ?? "0B"
                    guard !id.isEmpty, !seenIDs.contains(id) else { continue }
                    seenIDs.insert(id)
                    totalBytes += parseDockerSizeString(sizeCandidate)
                }
            }
        }

        return (seenIDs.count, totalBytes)
    }

    /// Parses `docker builder du` output (JSON lines or tabular) and returns only the bytes that `docker builder prune -f` will actually remove (Reclaimable == true, InUse == false, Shared == false).
    /// Returns `nil` if the output is empty, malformed, or in an unsupported format.
    public static func parseDockerBuilderDUOutput(_ output: String) -> Int64? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var parsedAnyRecord = false
        var sawTableHeader = false
        var reclaimableBytes: Int64 = 0

        for line in lines {
            if line.hasPrefix("{") {
                guard let data = line.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = dict["ID"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let rawSize = dict["Size"] as? String else {
                    return nil
                }
                let hasReclaimableOrInUse = (dict["Reclaimable"] != nil) || (dict["InUse"] != nil)
                guard hasReclaimableOrInUse else { return nil }

                let cleanSize = rawSize.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidDockerSizeString(cleanSize) else { return nil }

                guard let inUse = parseStrictBool(dict["InUse"], defaultIfNil: false),
                      let reclaimable = parseStrictBool(dict["Reclaimable"], defaultIfNil: true),
                      let shared = parseStrictBool(dict["Shared"], defaultIfNil: false) else {
                    return nil
                }

                parsedAnyRecord = true
                if reclaimable && !inUse && !shared && !rawSize.hasSuffix("*") {
                    reclaimableBytes += parseDockerSizeString(cleanSize)
                }
                continue
            }

            let lower = line.lowercased()
            if (lower.hasPrefix("id ") || lower.hasPrefix("id\t")) && lower.contains("reclaimable") && lower.contains("size") {
                sawTableHeader = true
                continue
            }
            if lower.hasPrefix("reclaimable:") || lower.hasPrefix("total:") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count == 2, isValidDockerSizeString(parts[1]) else {
                    return nil
                }
                continue
            }

            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 3 else { return nil }
            let reclaimableCol = cols[1].lowercased()
            let sizeCol = cols[2]
            guard reclaimableCol == "true" || reclaimableCol == "false" || reclaimableCol == "true*" else {
                return nil
            }
            let cleanSizeCol = sizeCol.replacingOccurrences(of: "*", with: "")
            guard isValidDockerSizeString(cleanSizeCol) else {
                return nil
            }

            parsedAnyRecord = true
            // Exclude "true*" or size ending with "*" (shared cache not removed by default prune)
            if reclaimableCol == "true" && !sizeCol.hasSuffix("*") {
                reclaimableBytes += parseDockerSizeString(cleanSizeCol)
            }
        }

        return (parsedAnyRecord || sawTableHeader) ? reclaimableBytes : nil
    }

    private static func parseStrictBool(_ raw: Any?, defaultIfNil: Bool) -> Bool? {
        guard let raw else { return defaultIfNil }
        if let b = raw as? Bool { return b }
        let str = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if str == "true" { return true }
        if str == "false" { return false }
        return nil
    }

    public static func isValidDockerSizeString(_ raw: String) -> Bool {
        let mainPart = raw.split(separator: " ").first.map(String.init) ?? raw
        let trimmed = mainPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var numberStr = ""
        var unitStr = ""
        var seenLetter = false
        for ch in trimmed {
            if ch.isNumber || ch == "." {
                if seenLetter { return false }
                numberStr.append(ch)
            } else if ch.isLetter {
                seenLetter = true
                unitStr.append(ch)
            } else {
                return false
            }
        }
        guard Double(numberStr) != nil else { return false }
        let unit = unitStr.uppercased()
        return ["B", "KB", "KIB", "MB", "MIB", "GB", "GIB", "TB", "TIB"].contains(unit)
    }

    public static func parseDockerSizeString(_ raw: String) -> Int64 {
        // Examples: "2.45GB (50%)", "412.3MB", "15.2kB", "0B", "1.25GiB"
        let mainPart = raw.split(separator: " ").first.map(String.init) ?? raw
        let trimmed = mainPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var numberStr = ""
        var unitStr = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." {
                numberStr.append(ch)
            } else if ch.isLetter {
                unitStr.append(ch)
            }
        }
        guard let value = Double(numberStr), value > 0 else { return 0 }
        let unit = unitStr.uppercased()
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "KB", "KIB": multiplier = 1_000
        case "MB", "MIB": multiplier = 1_000_000
        case "GB", "GIB": multiplier = 1_000_000_000
        case "TB", "TIB": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
