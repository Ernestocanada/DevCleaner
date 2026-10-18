import Foundation
import AppKit

@MainActor
public final class CleanerViewModel: ObservableObject {
    @Published public var items: [CleanableItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var isScanning: Bool = false
    @Published public var isCleaning: Bool = false
    @Published public var lastScanDate: Date? = nil
    @Published public var freeSpaceBytes: Int64 = 0
    @Published public var ageFilter: AgeFilter = .all
    @Published public var developmentModeActive: Bool = false
    @Published public var historyEntries: [CleanupHistoryEntry] = []
    @Published public var simulatorRuntimes: [SimulatorRuntimeInfo] = []
    @Published public var statusBannerMessage: String? = nil

    // Sheet states
    @Published public var showingPreviewSheet: Bool = false
    @Published public var showingHistorySheet: Bool = false
    @Published public var showingRuntimesSheet: Bool = false
    @Published public var itemForSingleClean: CleanableItem? = nil

    private let providers: [CleanerProvider] = [
        StandardCacheCleaner(category: .xcode),
        SimulatorCleaner(),
        AndroidCleaner(),
        StandardCacheCleaner(category: .nodeNpm),
        StandardCacheCleaner(category: .gradle),
        StandardCacheCleaner(category: .cocoapodsSwiftPM),
        StandardCacheCleaner(category: .homebrew),
        DockerCleaner(),
        AIToolsCleaner(category: .claude),
        AIToolsCleaner(category: .codex),
        AIToolsCleaner(category: .googleAI),
        StandardCacheCleaner(category: .generalCaches)
    ]

    private let executor = CleanupExecutor()

    public init() {
        self.freeSpaceBytes = DiskScanner.shared.freeDiskSpaceBytes()
        self.historyEntries = CleanupHistoryStore.shared.loadEntries()
    }

    public func performScan() async {
        guard !isScanning else { return }
        isScanning = true
        statusBannerMessage = nil

        let currentFilter = ageFilter
        let snapshot = await ProcessMonitor.shared.captureSnapshot()
        let freeBytes = DiskScanner.shared.freeDiskSpaceBytes()

        var allScanned: [CleanableItem] = []
        await withTaskGroup(of: [CleanableItem].self) { group in
            for provider in providers {
                group.addTask {
                    await provider.scan(snapshot: snapshot, ageFilter: currentFilter)
                }
            }
            for await result in group {
                allScanned.append(contentsOf: result)
            }
        }

        let simCleaner = SimulatorCleaner()
        let runtimes = await simCleaner.fetchRuntimes()

        // Sort items predictably by category order then physical size descending
        let categoryOrder = CleanerCategory.allCases
        allScanned.sort { a, b in
            let idxA = categoryOrder.firstIndex(of: a.category) ?? 99
            let idxB = categoryOrder.firstIndex(of: b.category) ?? 99
            if idxA != idxB { return idxA < idxB }
            return a.physicalSize > b.physicalSize
        }

        self.items = allScanned
        self.simulatorRuntimes = runtimes
        self.freeSpaceBytes = freeBytes
        self.lastScanDate = Date()

        // Keep valid selections or default to SAFE items if first scan
        let validSelectableIDs = Set(allScanned.filter { $0.canBeSelected }.map { $0.id })
        if selectedIDs.isEmpty {
            selectRecommendedSafeItems()
        } else {
            selectedIDs = selectedIDs.intersection(validSelectableIDs)
        }

        isScanning = false
    }

    public func selectRecommendedSafeItems() {
        developmentModeActive = false
        selectedIDs = Set(
            items
                .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                .map { $0.id }
        )
        statusBannerMessage = "Recommended SAFE cleanup selected (\(selectedItems.count) items, \(Formatters.bytes(selectedReclaimableBytes))). Review/Caution items and models are excluded."
    }

    public func activateDevelopmentCleanupMode(filter: AgeFilter = .sevenDays) {
        developmentModeActive = true
        if ageFilter != filter {
            ageFilter = filter
            Task {
                await performScan()
                self.selectedIDs = Set(
                    self.items
                        .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                        .map { $0.id }
                )
                self.statusBannerMessage = "Daily Development Cleanup (\(filter.title)): selected SAFE caches (\(Formatters.bytes(self.selectedReclaimableBytes)))."
            }
        } else {
            selectedIDs = Set(
                items
                    .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                    .map { $0.id }
            )
            statusBannerMessage = "Daily Development Cleanup (\(filter.title)): selected SAFE caches (\(Formatters.bytes(selectedReclaimableBytes)))."
        }
    }

    public func toggleSelection(for item: CleanableItem) {
        guard item.canBeSelected else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    public var totalReclaimableBytes: Int64 {
        items.filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
    }

    public var selectedItems: [CleanableItem] {
        items.filter { selectedIDs.contains($0.id) && $0.canBeSelected }
    }

    public var selectedReclaimableBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.reclaimableSize }
    }

    public func selectedBytes(for risk: RiskLevel) -> Int64 {
        selectedItems.filter { $0.riskLevel == risk }.reduce(0) { $0 + $1.reclaimableSize }
    }

    public func items(for category: CleanerCategory) -> [CleanableItem] {
        items.filter { $0.category == category }
    }

    public func categoryTotalPhysical(for category: CleanerCategory) -> Int64 {
        items(for: category).reduce(0) { $0 + $1.physicalSize }
    }

    public func categoryReclaimable(for category: CleanerCategory) -> Int64 {
        items(for: category).filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
    }

    public func inspectInFinder(_ item: CleanableItem) {
        let expanded = (item.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    public func executeCleanup(for targetItems: [CleanableItem]) async {
        guard !targetItems.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        // Re-verify process snapshot right before executing
        let latestSnapshot = await ProcessMonitor.shared.captureSnapshot()

        var totalReclaimed: Int64 = 0
        var successCount = 0
        var failCount = 0

        for item in targetItems {
            let activeProcs = latestSnapshot.matchingProcesses(for: item.category)
            if !activeProcs.isEmpty || item.isRunningDependency {
                let msg = "Skipped: Close active application (\(activeProcs.joined(separator: ", "))) before cleaning."
                let entry = CleanupHistoryEntry(
                    category: item.category.rawValue,
                    itemName: item.name,
                    path: item.path,
                    bytesReclaimed: 0,
                    actionDescription: describeAction(item.actionType),
                    success: false,
                    message: msg
                )
                CleanupHistoryStore.shared.appendEntry(entry)
                failCount += 1
                continue
            }

            do {
                let bytes = try await executor.execute(item, ageFilter: ageFilter)
                totalReclaimed += bytes
                successCount += 1
                let entry = CleanupHistoryEntry(
                    category: item.category.rawValue,
                    itemName: item.name,
                    path: item.path,
                    bytesReclaimed: bytes,
                    actionDescription: describeAction(item.actionType),
                    success: true,
                    message: "Successfully cleaned"
                )
                CleanupHistoryStore.shared.appendEntry(entry)
                selectedIDs.remove(item.id)
            } catch {
                failCount += 1
                let entry = CleanupHistoryEntry(
                    category: item.category.rawValue,
                    itemName: item.name,
                    path: item.path,
                    bytesReclaimed: 0,
                    actionDescription: describeAction(item.actionType),
                    success: false,
                    message: error.localizedDescription
                )
                CleanupHistoryStore.shared.appendEntry(entry)
            }
        }

        self.historyEntries = CleanupHistoryStore.shared.loadEntries()
        self.statusBannerMessage = "Cleanup finished: reclaimed \(Formatters.bytes(totalReclaimed)) (\(successCount) succeeded, \(failCount) skipped/failed)."
        await performScan()
    }

    public func deleteSimulatorRuntime(_ runtime: SimulatorRuntimeInfo) async {
        let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", runtime.id])
        let entry = CleanupHistoryEntry(
            category: CleanerCategory.iosSimulators.rawValue,
            itemName: "Runtime \(runtime.name)",
            path: "/Library/Developer/CoreSimulator/Volumes",
            bytesReclaimed: 0,
            actionDescription: "xcrun simctl runtime delete \(runtime.id)",
            success: res.isSuccess,
            message: res.isSuccess ? "Runtime deleted" : res.stderr
        )
        CleanupHistoryStore.shared.appendEntry(entry)
        self.historyEntries = CleanupHistoryStore.shared.loadEntries()
        await performScan()
    }

    private func describeAction(_ action: CleanupActionType) -> String {
        switch action {
        case .moveToTrash:
            return "Move to Trash"
        case .moveToTrashContents(_, let days):
            if let d = days { return "Move contents older than \(d)d to Trash" }
            return "Move cache contents to Trash"
        case .simctlDeleteDevice(let udid):
            return "xcrun simctl delete \(udid)"
        case .simctlDeleteUnavailable:
            return "xcrun simctl delete unavailable"
        case .simctlDeleteRuntime(let id):
            return "xcrun simctl runtime delete \(id)"
        case .dockerPrune(let args):
            return "docker \(args.joined(separator: " "))"
        case .readOnlyInfo:
            return "Read-only info"
        }
    }
}

public enum Formatters {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func relativeDate(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
