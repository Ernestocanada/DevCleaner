import Foundation

public struct DockerCLIStats: Sendable, Equatable {
    public var imagesTotalCount: Int
    public var imagesActiveCount: Int
    public var imagesSizeBytes: Int64
    public var imagesReclaimableBytes: Int64

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

    public static let zero = DockerCLIStats(
        imagesTotalCount: 0,
        imagesActiveCount: 0,
        imagesSizeBytes: 0,
        imagesReclaimableBytes: 0,
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
        buildCacheReclaimableBytes: 0
    )

    public init(
        imagesTotalCount: Int,
        imagesActiveCount: Int,
        imagesSizeBytes: Int64,
        imagesReclaimableBytes: Int64,
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
        buildCacheReclaimableBytes: Int64
    ) {
        self.imagesTotalCount = imagesTotalCount
        self.imagesActiveCount = imagesActiveCount
        self.imagesSizeBytes = imagesSizeBytes
        self.imagesReclaimableBytes = imagesReclaimableBytes
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
            let totalReclaimable = stats.imagesReclaimableBytes + stats.containersReclaimableBytes + stats.buildCacheReclaimableBytes
            statusDesc = "Docker Desktop is running (Images: \(stats.imagesTotalCount), Containers: \(stats.containersRunningCount) running / \(stats.containersStoppedCount) stopped, Volumes: \(stats.volumesTotalCount), Reclaimable SAFE: \(Formatters.bytes(totalReclaimable)))."
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

        let buildCacheReclaimable = stats?.buildCacheReclaimableBytes ?? 0
        let buildCacheTotal = stats?.buildCacheSizeBytes ?? 0
        let buildCacheDetail = stats != nil
            ? " (Total: \(Formatters.bytes(buildCacheTotal)) • Reclaimable: \(Formatters.bytes(buildCacheReclaimable)))"
            : ""

        let containersReclaimable = stats?.containersReclaimableBytes ?? 0
        let containersDetail = stats != nil
            ? " (\(stats!.containersStoppedCount) stopped / \(stats!.containersRunningCount) running • Reclaimable: \(Formatters.bytes(containersReclaimable)))"
            : ""

        let imagesReclaimable = stats?.imagesReclaimableBytes ?? 0
        let imagesTotal = stats?.imagesSizeBytes ?? 0
        let imagesDetail = stats != nil
            ? " (\(stats!.imagesTotalCount) images, \(Formatters.bytes(imagesTotal)) total • Reclaimable: \(Formatters.bytes(imagesReclaimable)))"
            : ""

        let volumesReclaimable = stats?.volumesReclaimableBytes ?? 0
        let volumesTotal = stats?.volumesSizeBytes ?? 0
        let volumesDetail = stats != nil
            ? " (\(stats!.volumesTotalCount) volumes, \(Formatters.bytes(volumesTotal)) total • Reclaimable: \(Formatters.bytes(volumesReclaimable)))"
            : ""

        let pruneSpecs: [(id: String, name: String, args: [String], risk: RiskLevel, reclaimable: Int64, desc: String)] = [
            (
                "docker-prune-build-cache",
                "Docker Build Cache (docker builder prune -f)\(buildCacheDetail)",
                ["builder", "prune", "-f"],
                (daemonRunning && buildCacheReclaimable > 0) ? .safe : .review,
                daemonRunning ? buildCacheReclaimable : 0,
                "Removes dangling BuildKit cache layers via official Docker CLI (`docker builder du` / `docker system df`).\(buildCacheDetail)"
            ),
            (
                "docker-prune-stopped-containers",
                "Docker Stopped Containers (docker container prune -f)\(containersDetail)",
                ["container", "prune", "-f"],
                (daemonRunning && containersReclaimable > 0) ? .safe : .review,
                daemonRunning ? containersReclaimable : 0,
                "Removes stopped containers via official Docker CLI (`docker container ls -a`).\(containersDetail)"
            ),
            (
                "docker-prune-dangling-images",
                "Docker Dangling / Unused Images (docker image prune -f)\(imagesDetail)",
                ["image", "prune", "-f"],
                (daemonRunning && imagesReclaimable > 0) ? .safe : .review,
                daemonRunning ? imagesReclaimable : 0,
                "Removes dangling container images via official Docker CLI (`docker image ls`).\(imagesDetail)"
            ),
            (
                "docker-prune-volumes",
                "Docker Unused Volumes (docker volume prune -f)\(volumesDetail)",
                ["volume", "prune", "-f"],
                .caution, // Volumes are ALWAYS CAUTION, never SAFE automatically
                daemonRunning ? volumesReclaimable : 0,
                "CAUTION: Permanently removes unused local Docker volumes (`docker volume ls`). May contain database or persistent container data.\(volumesDetail)"
            )
        ]

        for spec in pruneSpecs {
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
                    actionType: daemonRunning
                        ? .dockerPrune(subcommand: spec.args)
                        : .readOnlyInfo(reason: "Docker Desktop is not running. Start Docker to use CLI cleanup.")
                )
            )
        }

        return items
    }

    public static func fetchLiveDockerCLIStats(dockerBinary: String) async -> DockerCLIStats {
        async let dfRes = ShellRunner.shared.run(dockerBinary, arguments: ["system", "df", "--format", "{{json .}}"], timeoutSeconds: 8)
        async let psRes = ShellRunner.shared.run(dockerBinary, arguments: ["container", "ls", "-a", "--format", "{{.State}}"], timeoutSeconds: 5)
        async let imgRes = ShellRunner.shared.run(dockerBinary, arguments: ["image", "ls", "-q"], timeoutSeconds: 5)
        async let volRes = ShellRunner.shared.run(dockerBinary, arguments: ["volume", "ls", "-q"], timeoutSeconds: 5)
        async let builderRes = ShellRunner.shared.run(dockerBinary, arguments: ["builder", "du"], timeoutSeconds: 5)

        let (df, ps, img, vol, _) = await (dfRes, psRes, imgRes, volRes, builderRes)
        var stats = parseDockerSystemDFJSONLines(df.stdout)

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

    public static func parseDockerSystemDFJSONLines(_ output: String) -> DockerCLIStats {
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
                stats.buildCacheReclaimableBytes = reclaimableBytes
            }
        }
        return stats
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
