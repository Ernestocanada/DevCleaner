import Foundation

public final class FavoriteSimulatorsStore: @unchecked Sendable {
    public static let shared = FavoriteSimulatorsStore()
    private let defaultsKey = "DevCleaner.FavoriteSimulatorUDIDs"
    private let lock = NSLock()

    public init() {}

    public func favoriteUDIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let list = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Set(list)
    }

    public func isFavorite(udid: String) -> Bool {
        favoriteUDIDs().contains(udid)
    }

    @discardableResult
    public func toggleFavorite(udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        let nowFavorite: Bool
        if current.contains(udid) {
            current.remove(udid)
            nowFavorite = false
        } else {
            current.insert(udid)
            nowFavorite = true
        }
        UserDefaults.standard.set(Array(current).sorted(), forKey: defaultsKey)
        return nowFavorite
    }
}

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
        let deviceTypeIdentifier: String?
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

    public struct LiveDeviceState: Equatable, Sendable {
        public let udid: String
        public let name: String
        public let state: String
        public let isAvailable: Bool

        public init(udid: String, name: String, state: String, isAvailable: Bool) {
            self.udid = udid
            self.name = name
            self.state = state
            self.isAvailable = isAvailable
        }

        /// True only when the simulator's live state is strictly "Shutdown" (not Booted, Booting, Shutting Down, etc.).
        public var isShutdown: Bool {
            state.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Shutdown") == .orderedSame
        }
    }

    public static func lookupDeviceState(udid: String, in data: Data) throws -> LiveDeviceState? {
        let decoded = try JSONDecoder().decode(SimctlDevicesResponse.self, from: data)
        for (_, devices) in decoded.devices {
            if let match = devices.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) {
                return LiveDeviceState(
                    udid: match.udid,
                    name: match.name,
                    state: match.state,
                    isAvailable: match.isAvailable ?? true
                )
            }
        }
        return nil
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

    public static func formatDeviceTypeIdentifier(_ identifier: String?, fallbackName: String) -> String {
        guard let identifier, !identifier.isEmpty else {
            return fallbackName
        }
        if let range = identifier.range(of: "SimDeviceType.") {
            let suffix = String(identifier[range.upperBound...])
            return suffix.replacingOccurrences(of: "-", with: " ")
        }
        return fallbackName
    }

    public static func detectInstalledApps(inDataPath dataPath: String) -> [String] {
        let fm = FileManager.default
        let appsRoot = URL(fileURLWithPath: dataPath).appendingPathComponent("Containers/Bundle/Application")
        guard let uuidDirs = try? fm.contentsOfDirectory(
            at: appsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var appNames: [String] = []
        for uuidDir in uuidDirs {
            guard let children = try? fm.contentsOfDirectory(
                at: uuidDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where child.pathExtension == "app" {
                appNames.append(child.deletingPathExtension().lastPathComponent)
            }
        }
        return Array(Set(appNames)).sorted()
    }

    public static func parseDevicesJSON(
        _ data: Data,
        homeDirectory: String,
        favoriteUDIDs: Set<String> = []
    ) throws -> [CleanableItem] {
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
                guard size > 0 || isBooted || !isAvailable else { continue }

                let lastUsed: Date? = dev.lastUsedAt != nil ? isoFormatter.date(from: dev.lastUsedAt!) : nil
                let devicePath = dev.dataPath ?? "\(homeDirectory)/Library/Developer/CoreSimulator/Devices/\(dev.udid)/data"
                let installedApps = detectInstalledApps(inDataPath: devicePath)
                let hasLocalData = !installedApps.isEmpty || size > 100 * 1024 * 1024
                let isFavorite = favoriteUDIDs.contains(dev.udid)
                let modelLabel = formatDeviceTypeIdentifier(dev.deviceTypeIdentifier, fallbackName: dev.name)

                let meta = SimulatorMetadata(
                    udid: dev.udid,
                    deviceModel: modelLabel,
                    runtimeName: runtimeLabel,
                    state: dev.state,
                    isAvailable: isAvailable,
                    lastUsedAt: lastUsed,
                    installedAppNames: installedApps,
                    hasLocalData: hasLocalData,
                    isFavorite: isFavorite
                )

                // Unavailable/orphaned => SAFE; Shutdown => REVIEW; Booted or Favorite => protected
                let itemRisk: RiskLevel = isAvailable ? .review : .safe
                let stateNote: String = {
                    if isBooted { return "ACTIVE — protected (\(dev.state))" }
                    if isFavorite { return "FAVORITE — protected" }
                    return isAvailable ? dev.state : "Unavailable / Orphaned"
                }()

                let availabilityText = isAvailable ? "Available" : "Unavailable"

                let appsSummary: String = {
                    if !installedApps.isEmpty {
                        return " Installed apps (\(installedApps.count)): \(installedApps.joined(separator: ", "))."
                    }
                    if hasLocalData {
                        return " Contains local simulator container data."
                    }
                    return " No installed user apps detected (clean template state)."
                }()

                let reclaimable: Int64 = (isBooted || isFavorite) ? 0 : size

                items.append(
                    CleanableItem(
                        id: "sim-device-\(dev.udid)",
                        name: "\(dev.name) — \(runtimeLabel)",
                        category: .iosSimulators,
                        path: devicePath,
                        logicalSize: size,
                        physicalSize: size,
                        reclaimableSize: reclaimable,
                        lastModified: lastUsed,
                        lastUsed: lastUsed,
                        riskLevel: itemRisk,
                        explanation: "Model: \(modelLabel) • Device: \(dev.name) • Runtime: \(runtimeLabel) • State: \(stateNote) (\(availabilityText)) • Recommendation: \(meta.recommendationBadgeText).\(appsSummary) Deleting a simulator removes its apps and simulator-local data but does not remove your source code.",
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

        items.sort { lhs, rhs in
            if lhs.physicalSize != rhs.physicalSize {
                return lhs.physicalSize > rhs.physicalSize
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

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
                explanation: "System-mounted simulator runtime images (iOS 26.3 & iOS 27.0) in /Library/Developer/CoreSimulator (~19.6 GB managed by macOS/Xcode). Protected by default and never deleted manually.",
                deletionConsequence: "Never deleted automatically. Use 'Advanced Runtime Manager' if you explicitly need to inspect or remove runtimes via simctl.",
                regenerationImpact: "Re-downloading an iOS runtime requires an 8–15 GB download in Xcode.",
                isRunningDependency: false,
                runningProcessNames: [],
                actionType: .readOnlyInfo(reason: "Mounted simulator runtime volumes are preserved by default."),
                requiresRedownload: true
            )
        )

        return items
    }

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "-j"])
        let favs = FavoriteSimulatorsStore.shared.favoriteUDIDs()
        guard res.isSuccess, let data = res.stdout.data(using: .utf8),
              let parsed = try? Self.parseDevicesJSON(data, homeDirectory: home, favoriteUDIDs: favs) else {
            return []
        }
        return parsed
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
