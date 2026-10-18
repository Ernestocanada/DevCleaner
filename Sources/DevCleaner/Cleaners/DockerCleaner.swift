import Foundation

public struct DockerCleaner: CleanerProvider {
    public let category: CleanerCategory = .docker
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let executor = CleanupExecutor()

    public init() {}

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        var items: [CleanableItem] = []
        let containerRoot = "\(home)/Library/Containers/com.docker.docker"
        let rawFile = "\(containerRoot)/Data/vms/0/data/Docker.raw"

        let hasContainer = FileManager.default.fileExists(atPath: containerRoot)
        guard hasContainer else { return [] }

        let usage: DiskUsageInfo
        let targetPath: String
        if FileManager.default.fileExists(atPath: rawFile) {
            usage = DiskScanner.shared.measurePath(rawFile)
            targetPath = rawFile
        } else {
            usage = DiskScanner.shared.measurePath(containerRoot)
            targetPath = containerRoot
        }

        // Check if Docker daemon is reachable
        let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        let dockerBin = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        var daemonRunning = false

        if let bin = dockerBin {
            let infoRes = await ShellRunner.shared.run(bin, arguments: ["info", "--format", "{{.ServerVersion}}"], timeoutSeconds: 5)
            daemonRunning = infoRes.isSuccess && !infoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // 1. Report Docker.raw sparse file storage (NEVER DELETE directly)
        let statusDesc = daemonRunning ? "Docker Desktop is running." : "Docker Desktop is stopped (daemon offline). Start Docker Desktop to enable CLI prune commands."
        items.append(
            CleanableItem(
                id: "docker-raw-disk",
                name: "Docker Desktop VM Disk (Docker.raw)",
                category: .docker,
                path: targetPath,
                logicalSize: usage.logicalSize,
                physicalSize: usage.physicalSize,
                reclaimableSize: 0,
                lastModified: usage.lastModified,
                riskLevel: .neverDelete,
                explanation: "APFS sparse virtual disk used by Docker Desktop Linux VM. Logical capacity is \(ByteCountFormatter.string(fromByteCount: usage.logicalSize, countStyle: .file)), while actual physical SSD blocks used are \(ByteCountFormatter.string(fromByteCount: usage.physicalSize, countStyle: .file)). \(statusDesc)",
                deletionConsequence: "Protected: Never delete Docker.raw directly. Use official Docker CLI prune actions below when Docker is running.",
                regenerationImpact: "Managed by Docker Desktop.",
                isRunningDependency: false,
                runningProcessNames: [],
                actionType: .readOnlyInfo(reason: "Docker.raw must never be deleted directly.")
            )
        )

        // 2. Official Docker cleanup commands (enabled when Docker daemon is running; disabled info when stopped)
        let pruneSpecs: [(id: String, name: String, args: [String], risk: RiskLevel, desc: String)] = [
            (
                "docker-prune-build-cache",
                "Docker Build Cache (docker builder prune -f)",
                ["builder", "prune", "-f"],
                .review,
                "Removes dangling buildkit cache layers via official Docker CLI."
            ),
            (
                "docker-prune-containers-images",
                "Docker Stopped Containers & Dangling Images (docker system prune -f)",
                ["system", "prune", "-f"],
                .review,
                "Removes stopped containers, unused networks, and dangling images via official Docker CLI."
            ),
            (
                "docker-prune-volumes",
                "Docker Unused Volumes (docker volume prune -f)",
                ["volume", "prune", "-f"],
                .caution,
                "CAUTION: Permanently removes unused local Docker volumes (may contain database data)."
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
                    deletionConsequence: "Executes 'docker \(spec.args.joined(separator: " "))'.",
                    regenerationImpact: "Container images or build cache layers will be pulled/rebuilt on next docker build/run.",
                    isRunningDependency: false,
                    runningProcessNames: [],
                    actionType: daemonRunning ? .dockerPrune(subcommand: spec.args) : .readOnlyInfo(reason: "Docker Desktop is not running. Start Docker to use CLI cleanup.")
                )
            )
        }

        return items
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> Int64 {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
