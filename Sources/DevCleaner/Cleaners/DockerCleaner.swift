import Foundation

public struct DockerCleaner: CleanerProvider {
    public let category: CleanerCategory = .docker
    private let home: String
    private let executor: CleanupExecutor
    private let daemonRunningOverride: Bool?
    private let diskUsageOverride: DiskUsageInfo?

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executor: CleanupExecutor = CleanupExecutor(),
        daemonRunningOverride: Bool? = nil,
        diskUsageOverride: DiskUsageInfo? = nil
    ) {
        self.home = homeDirectory
        self.executor = executor
        self.daemonRunningOverride = daemonRunningOverride
        self.diskUsageOverride = diskUsageOverride
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

        let daemonRunning: Bool
        if let overrideDaemon = daemonRunningOverride {
            daemonRunning = overrideDaemon
        } else {
            let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            if let bin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                let infoRes = await ShellRunner.shared.run(bin, arguments: ["info", "--format", "{{.ServerVersion}}"], timeoutSeconds: 5)
                daemonRunning = infoRes.isSuccess && !infoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                daemonRunning = false
            }
        }

        let statusDesc = daemonRunning
            ? "Docker Desktop is running."
            : "Docker Desktop is stopped (daemon offline). Start Docker Desktop to enable CLI prune commands."

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

        let pruneSpecs: [(id: String, name: String, args: [String], risk: RiskLevel, desc: String)] = [
            (
                "docker-prune-build-cache",
                "Docker Build Cache (docker builder prune -f)",
                ["builder", "prune", "-f"],
                .review,
                "Removes dangling BuildKit cache layers via official Docker CLI."
            ),
            (
                "docker-prune-stopped-containers",
                "Docker Stopped Containers (docker container prune -f)",
                ["container", "prune", "-f"],
                .review,
                "Removes stopped containers via official Docker CLI."
            ),
            (
                "docker-prune-dangling-images",
                "Docker Dangling / Unused Images (docker image prune -f)",
                ["image", "prune", "-f"],
                .review,
                "Removes dangling container images via official Docker CLI."
            ),
            (
                "docker-prune-volumes",
                "Docker Unused Volumes (docker volume prune -f)",
                ["volume", "prune", "-f"],
                .caution,
                "CAUTION: Permanently removes unused local Docker volumes (may contain database or persistent container data)."
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
                    reclaimableSize: daemonRunning ? 1 : 0,
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

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
