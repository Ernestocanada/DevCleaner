import Foundation

public struct SimulatorCleaner: CleanerProvider {
    public let category: CleanerCategory = .iosSimulators
    private let home: String
    private let executor: CleanupExecutor

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executor: CleanupExecutor = CleanupExecutor()
    ) {
        self.home = homeDirectory
        self.executor = executor
    }

    private struct SimctlDevicesResponse: Decodable {
        let devices: [String: [SimctlDevice]]
    }

    private struct SimctlDevice: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPath: String?
        let dataPathSize: Int64?
        let logPath: String?
        let logPathSize: Int64?
        let lastUsedAt: String?
    }

    private struct SimctlRuntimesResponse: Decodable {
        let runtimes: [SimctlRuntime]
    }

    private struct SimctlRuntime: Decodable {
        let identifier: String
        let name: String
        let version: String
        let buildversion: String?
        let isAvailable: Bool?
    }

    public func fetchRuntimes() async -> [SimulatorRuntimeInfo] {
        let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "list", "runtimes", "-j"])
        guard res.isSuccess, let data = res.stdout.data(using: .utf8),
              let parsed = try? Self.parseRuntimesJSON(data) else {
            return []
        }
        return parsed
    }

    public static func parseRuntimesJSON(_ data: Data) throws -> [SimulatorRuntimeInfo] {
        let decoded = try JSONDecoder().decode(SimctlRuntimesResponse.self, from: data)
        return decoded.runtimes.map { rt in
            let preserved = rt.name.contains("26.3") ||
                            rt.name.contains("27.0") ||
                            rt.version.hasPrefix("26.3") ||
                            rt.version.hasPrefix("27.0") ||
                            rt.identifier.contains("iOS-26-3") ||
                            rt.identifier.contains("iOS-27-0")
            return SimulatorRuntimeInfo(
                id: rt.identifier,
                name: rt.name,
                version: rt.version,
                build: rt.buildversion ?? "",
                isAvailable: rt.isAvailable ?? true,
                isPreservedByDefault: preserved
            )
        }
    }

    public static func formatRuntimeKey(_ key: String) -> String {
        if let range = key.range(of: "SimRuntime.") {
            let suffix = String(key[range.upperBound...])
            let parts = suffix.split(separator: "-")
            if parts.count >= 2 {
                let osName = parts[0]
                let ver = parts.dropFirst().joined(separator: ".")
                return "\(osName) \(ver)"
            }
            return suffix
        }
        return key
    }

    public static func parseDevicesJSON(_ data: Data, homeDirectory: String) throws -> [CleanableItem] {
        let decoded = try JSONDecoder().decode(SimctlDevicesResponse.self, from: data)
        let isoFormatter = ISO8601DateFormatter()
        var items: [CleanableItem] = []
        var unavailableCount = 0
        var unavailableBytes: Int64 = 0

        for (runtimeKey, devices) in decoded.devices {
            let runtimeLabel = formatRuntimeKey(runtimeKey)
            for dev in devices {
                let size = (dev.dataPathSize ?? 0) + (dev.logPathSize ?? 0)
                let isAvailable = dev.isAvailable ?? true
                if !isAvailable {
                    unavailableCount += 1
                    unavailableBytes += size
                }

                let isBooted = dev.state.caseInsensitiveCompare("Shutdown") != .orderedSame

                // List simulators that consume meaningful disk space (>10 MB), are booted, or are unavailable with data
                guard size > 10 * 1024 * 1024 || isBooted else { continue }

                let lastUsed: Date? = dev.lastUsedAt != nil ? isoFormatter.date(from: dev.lastUsedAt!) : nil
                let devicePath = dev.dataPath ?? "\(homeDirectory)/Library/Developer/CoreSimulator/Devices/\(dev.udid)/data"

                let meta = SimulatorMetadata(
                    udid: dev.udid,
                    runtimeName: runtimeLabel,
                    state: dev.state,
                    isAvailable: isAvailable,
                    lastUsedAt: lastUsed
                )

                // Unavailable/orphaned => SAFE; Shutdown => REVIEW; Booted => protected
                let itemRisk: RiskLevel = isAvailable ? .review : .safe
                let stateNote = isBooted ? "ACTIVE — protected (\(dev.state))" : (isAvailable ? dev.state : "Unavailable / Orphaned")

                items.append(
                    CleanableItem(
                        id: "sim-device-\(dev.udid)",
                        name: "\(dev.name) — \(runtimeLabel)",
                        category: .iosSimulators,
                        path: devicePath,
                        logicalSize: size,
                        physicalSize: size,
                        reclaimableSize: isBooted ? 0 : size,
                        lastModified: lastUsed,
                        riskLevel: itemRisk,
                        explanation: "Device: \(dev.name) • Runtime: \(runtimeLabel) • State: \(stateNote). Deleting a simulator removes its apps and simulator-local data but does not remove your source code.",
                        deletionConsequence: "Deletes this simulator device and its app sandbox data via official 'xcrun simctl delete \(dev.udid)'.",
                        regenerationImpact: "Simulator device can be recreated in Xcode if needed; installed simulator apps will need a fresh build.",
                        isRunningDependency: isBooted,
                        runningProcessNames: isBooted ? ["Simulator (\(dev.state))"] : [],
                        actionType: .simctlDeleteDevice(udid: dev.udid),
                        simulatorMetadata: meta
                    )
                )
            }
        }

        items.sort { $0.physicalSize > $1.physicalSize }

        items.insert(
            CleanableItem(
                id: "sim-delete-unavailable",
                name: "Delete Unavailable / Orphaned Simulators (\(unavailableCount) found)",
                category: .iosSimulators,
                path: "\(homeDirectory)/Library/Developer/CoreSimulator/Devices",
                logicalSize: unavailableBytes,
                physicalSize: unavailableBytes,
                reclaimableSize: unavailableBytes,
                lastModified: nil,
                riskLevel: .safe,
                explanation: "Orphaned simulator devices whose iOS/watchOS runtime is no longer installed. Deleting a simulator removes its apps and simulator-local data but does not remove your source code.",
                deletionConsequence: "Runs official 'xcrun simctl delete unavailable' to safely remove orphaned devices.",
                regenerationImpact: "None — these simulators cannot be booted with current Xcode runtimes.",
                isRunningDependency: false,
                runningProcessNames: [],
                actionType: .simctlDeleteUnavailable
            ),
            at: 0
        )

        items.append(
            CleanableItem(
                id: "sim-runtimes-preserved",
                name: "Installed Simulator Runtimes (iOS 26.3 & iOS 27.0 — PRESERVED)",
                category: .iosSimulators,
                path: "/Library/Developer/CoreSimulator/Volumes",
                logicalSize: 0,
                physicalSize: 0,
                reclaimableSize: 0,
                lastModified: nil,
                riskLevel: .neverDelete,
                explanation: "System-mounted simulator runtime images (iOS 26.3 & iOS 27.0). Protected by default and never deleted manually.",
                deletionConsequence: "Never deleted automatically. Use 'Advanced Runtime Manager' if you explicitly need to inspect or remove runtimes via simctl.",
                regenerationImpact: "Re-downloading an iOS runtime requires an 8–15 GB download in Xcode.",
                isRunningDependency: false,
                runningProcessNames: [],
                actionType: .readOnlyInfo(reason: "Mounted simulator runtime volumes are preserved by default.")
            )
        )

        return items
    }

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "-j"])
        guard res.isSuccess, let data = res.stdout.data(using: .utf8),
              let parsed = try? Self.parseDevicesJSON(data, homeDirectory: home) else {
            return []
        }
        return parsed
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
