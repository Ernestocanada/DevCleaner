import Foundation
import AppKit

public enum MainAnalyzerTab: String, CaseIterable, Identifiable, Sendable {
    case systemAndTools = "System & Tools"
    case projectStorage = "Project Storage"
    case worktrees = "Worktrees"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .systemAndTools: return "externaldrive.fill.badge.checkmark"
        case .projectStorage: return "folder.fill.badge.gearshape"
        case .worktrees: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public final class AtomicCancellationFlag: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
public final class CleanerViewModel: ObservableObject {
    @Published public var selectedTab: MainAnalyzerTab = .systemAndTools
    @Published public var items: [CleanableItem] = []
    @Published public var selectedIDs: Set<String> = []
    @Published public var isScanning: Bool = false
    @Published public var isCleaning: Bool = false
    @Published public var lastScanDate: Date? = nil
    @Published public var storageMetrics: StorageMetrics = .zero
    @Published public var freeSpaceBytes: Int64 = 0
    @Published public var ageFilter: AgeFilter = .all
    @Published public var developmentModeActive: Bool = false
    @Published public var historyEntries: [CleanupHistoryEntry] = []
    @Published public var simulatorRuntimes: [SimulatorRuntimeInfo] = []
    @Published public var statusBannerMessage: String? = nil
    @Published public var lastCleanupSummary: CleanupBatchSummary? = nil

    // Project Storage Analyzer & Worktree Analyzer state
    @Published public var projectsRootPath: String = ProjectStorageAnalyzer.defaultDeveloperRoot
    @Published public var projectReports: [ProjectStorageReport] = []
    @Published public var projectSummary: ProjectStorageSummary = .empty
    @Published public var isScanningProjects: Bool = false
    @Published public var projectScanProgressText: String = ""
    @Published public var worktreeRecords: [GitWorktreeRecord] = []
    @Published public var isScanningWorktrees: Bool = false

    // Sheet states
    @Published public var showingPreviewSheet: Bool = false
    @Published public var showingHistorySheet: Bool = false
    @Published public var showingRuntimesSheet: Bool = false
    @Published public var itemForSingleClean: CleanableItem? = nil

    private var projectScanCancellation: AtomicCancellationFlag?
    private var projectScanTask: Task<Void, Never>?

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

    private let projectAnalyzer = ProjectStorageAnalyzer()
    private let worktreeAnalyzer = GitWorktreeAnalyzer()
    private let executor = CleanupExecutor()

    public init() {
        let metrics = DiskScanner.shared.currentStorageMetrics()
        self.storageMetrics = metrics
        self.freeSpaceBytes = metrics.macOSAvailableBytes
        self.historyEntries = CleanupHistoryStore.shared.loadEntries()
    }

    public var macOSAvailableBytes: Int64 {
        storageMetrics.macOSAvailableBytes
    }

    public var physicalFreeBytes: Int64 {
        storageMetrics.physicalFreeBytes
    }

    public var purgeableBytes: Int64 {
        storageMetrics.purgeableBytes
    }

    public var trashBytes: Int64 {
        storageMetrics.trashBytes
    }

    public var potentialCleanupBytes: Int64 {
        totalReclaimableBytes
    }

    public var selectedCleanupBytes: Int64 {
        selectedReclaimableBytes
    }

    public func performScan() async {
        guard !isScanning else { return }
        isScanning = true

        let currentFilter = ageFilter
        let snapshot = await ProcessMonitor.shared.captureSnapshot()
        let metrics = await Task.detached(priority: .userInitiated) {
            DiskScanner.shared.currentStorageMetrics()
        }.value

        let rootToScan = projectsRootPath
        let cancelFlag = AtomicCancellationFlag()
        self.projectScanCancellation = cancelFlag
        self.isScanningProjects = true
        self.isScanningWorktrees = true
        self.projectScanProgressText = "Scanning \(rootToScan)..."

        let pAnalyzer = self.projectAnalyzer
        let wAnalyzer = self.worktreeAnalyzer

        // Start Project Storage & Worktrees scan concurrently in the background
        let projectsTask = Task.detached(priority: .userInitiated) {
            await pAnalyzer.analyzeProjects(
                in: rootToScan,
                snapshot: snapshot,
                shouldCancel: { cancelFlag.isCancelled },
                onProgress: { index, total, projectName in
                    Task { @MainActor in
                        self.projectScanProgressText = "Analyzing project \(index)/\(total): \(projectName)..."
                    }
                }
            )
        }

        let worktreesTask = Task.detached(priority: .userInitiated) {
            await wAnalyzer.analyzeWorktrees(
                in: rootToScan,
                snapshot: snapshot,
                shouldCancel: { cancelFlag.isCancelled }
            )
        }

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

        let categoryOrder = CleanerCategory.allCases
        allScanned.sort { a, b in
            let idxA = categoryOrder.firstIndex(of: a.category) ?? 99
            let idxB = categoryOrder.firstIndex(of: b.category) ?? 99
            if idxA != idxB { return idxA < idxB }
            if a.riskLevel != b.riskLevel { return a.riskLevel < b.riskLevel }
            return a.physicalSize > b.physicalSize
        }

        let hadPriorSelection = !selectedIDs.isEmpty
        self.items = allScanned
        self.simulatorRuntimes = runtimes
        self.storageMetrics = metrics
        self.freeSpaceBytes = metrics.macOSAvailableBytes
        self.lastScanDate = Date()

        if !hadPriorSelection {
            selectRecommendedSafeItems()
        }

        let (pReports, pSummary) = await projectsTask.value
        let wRecords = await worktreesTask.value

        self.projectReports = pReports
        self.projectSummary = pSummary
        self.worktreeRecords = wRecords
        self.isScanningProjects = false
        self.isScanningWorktrees = false
        self.projectScanProgressText = ""

        // Append cleanable project artifact items so they integrate with selection & preview
        for report in pReports {
            for artifact in report.artifacts where artifact.reclaimableBytes > 0 {
                allScanned.append(artifact.cleanableItem)
            }
        }

        allScanned.sort { a, b in
            let idxA = categoryOrder.firstIndex(of: a.category) ?? 99
            let idxB = categoryOrder.firstIndex(of: b.category) ?? 99
            if idxA != idxB { return idxA < idxB }
            if a.riskLevel != b.riskLevel { return a.riskLevel < b.riskLevel }
            return a.physicalSize > b.physicalSize
        }

        self.items = allScanned
        let validSelectableIDs = Set(allScanned.filter { $0.canBeSelected }.map { $0.id })
        if !hadPriorSelection {
            selectRecommendedSafeItems()
        } else {
            selectedIDs = selectedIDs.intersection(validSelectableIDs)
        }

        isScanning = false
    }

    public func rescanProjectsOnly() async {
        guard !isScanningProjects else { return }
        let cancelFlag = AtomicCancellationFlag()
        self.projectScanCancellation = cancelFlag
        self.isScanningProjects = true
        self.isScanningWorktrees = true
        let rootToScan = projectsRootPath
        let snapshot = await ProcessMonitor.shared.captureSnapshot()
        let pAnalyzer = self.projectAnalyzer
        let wAnalyzer = self.worktreeAnalyzer

        let (pReports, pSummary) = await Task.detached(priority: .userInitiated) {
            await pAnalyzer.analyzeProjects(
                in: rootToScan,
                snapshot: snapshot,
                shouldCancel: { cancelFlag.isCancelled },
                onProgress: { index, total, projectName in
                    Task { @MainActor in
                        self.projectScanProgressText = "Analyzing project \(index)/\(total): \(projectName)..."
                    }
                }
            )
        }.value

        let wRecords = await Task.detached(priority: .userInitiated) {
            await wAnalyzer.analyzeWorktrees(
                in: rootToScan,
                snapshot: snapshot,
                shouldCancel: { cancelFlag.isCancelled }
            )
        }.value

        self.projectReports = pReports
        self.projectSummary = pSummary
        self.worktreeRecords = wRecords
        self.isScanningProjects = false
        self.isScanningWorktrees = false
        self.projectScanProgressText = ""

        // Replace .projectStorage items in self.items
        var nonProjectItems = self.items.filter { $0.category != .projectStorage }
        for report in pReports {
            for artifact in report.artifacts where artifact.reclaimableBytes > 0 {
                nonProjectItems.append(artifact.cleanableItem)
            }
        }
        self.items = nonProjectItems
    }

    public func cancelProjectScan() {
        projectScanCancellation?.cancel()
        projectScanTask?.cancel()
        isScanningProjects = false
        isScanningWorktrees = false
        projectScanProgressText = "Scan cancelled by user."
    }

    public func chooseProjectsRootFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Developer Projects Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectsRootPath)
        if panel.runModal() == .OK, let url = panel.url {
            projectsRootPath = url.standardizedFileURL.path
            Task {
                await rescanProjectsOnly()
            }
        }
    }

    public func resetProjectsRootToDefault() {
        projectsRootPath = ProjectStorageAnalyzer.defaultDeveloperRoot
        Task {
            await rescanProjectsOnly()
        }
    }

    public func toggleSimulatorFavorite(udid: String) {
        _ = FavoriteSimulatorsStore.shared.toggleFavorite(udid: udid)
        selectedIDs.remove("sim-device-\(udid)")
        Task {
            let simCleaner = SimulatorCleaner()
            let snapshot = await ProcessMonitor.shared.captureSnapshot()
            let updatedSimItems = await simCleaner.scan(snapshot: snapshot, ageFilter: ageFilter)
            var updated = items.filter { $0.category != .iosSimulators }
            updated.append(contentsOf: updatedSimItems)
            let categoryOrder = CleanerCategory.allCases
            updated.sort { a, b in
                let idxA = categoryOrder.firstIndex(of: a.category) ?? 99
                let idxB = categoryOrder.firstIndex(of: b.category) ?? 99
                if idxA != idxB { return idxA < idxB }
                if a.riskLevel != b.riskLevel { return a.riskLevel < b.riskLevel }
                return a.physicalSize > b.physicalSize
            }
            self.items = updated
        }
    }

    public func selectRecommendedSafeItems() {
        developmentModeActive = false
        selectedIDs = Set(
            items
                .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                .map { $0.id }
        )
        statusBannerMessage = "Recommended SAFE cleanup selected (\(selectedItems.count) items, \(Formatters.bytes(selectedReclaimableBytes))). Review/Caution items, protected subtrees, simulators, VMs, and AI models are excluded."
    }

    public func selectSafeProjectArtifactsOnly() {
        let safeProjectIDs = items
            .filter { $0.category == .projectStorage && $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
            .map { $0.id }
        for id in safeProjectIDs {
            selectedIDs.insert(id)
        }
        statusBannerMessage = "Selected \(safeProjectIDs.count) verified SAFE project caches & builds."
    }

    public func clearProjectArtifactSelections() {
        let projectIDs = Set(items.filter { $0.category == .projectStorage }.map { $0.id })
        selectedIDs.subtract(projectIDs)
    }

    public var selectedProjectItems: [CleanableItem] {
        selectedItems.filter { $0.category == .projectStorage }
    }

    public var selectedProjectReclaimableBytes: Int64 {
        selectedProjectItems.reduce(0) { $0 + $1.reclaimableSize }
    }

    public func activateDevelopmentCleanupMode(filter: AgeFilter = .sevenDays) {
        developmentModeActive = true
        let targetFilter = (filter == .all) ? .sevenDays : filter
        if ageFilter != targetFilter {
            ageFilter = targetFilter
            Task {
                await performScan()
                self.selectedIDs = Set(
                    self.items
                        .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                        .map { $0.id }
                )
                self.statusBannerMessage = "Development Cleanup (\(targetFilter.title)): selected SAFE caches older than threshold (\(Formatters.bytes(self.selectedReclaimableBytes)))."
            }
        } else {
            selectedIDs = Set(
                items
                    .filter { $0.riskLevel == .safe && $0.canBeSelected && $0.reclaimableSize > 0 }
                    .map { $0.id }
            )
            statusBannerMessage = "Development Cleanup (\(targetFilter.title)): selected SAFE caches older than threshold (\(Formatters.bytes(selectedReclaimableBytes)))."
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

    public func potentialBytes(for risk: RiskLevel) -> Int64 {
        items.filter { $0.riskLevel == risk }.reduce(0) { $0 + $1.reclaimableSize }
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
        inspectPathInFinder(item.path)
    }

    public func inspectPathInFinder(_ rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
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

    public func openTrashInFinder() {
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(trashURL)
        } else {
            let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            NSWorkspace.shared.open(fallback)
        }
    }

    public func executeCleanup(for targetItems: [CleanableItem]) async {
        guard !targetItems.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        let overallFreeBefore = DiskScanner.shared.freeDiskSpaceBytes()
        var totalProcessed: Int64 = 0
        var totalMovedToTrash: Int64 = 0
        var successCount = 0
        var nothingEligibleCount = 0
        var failCount = 0
        var blockedMessages: [String] = []

        for item in targetItems {
            let latestSnapshot = await ProcessMonitor.shared.captureSnapshot()
            let activeProcs = latestSnapshot.matchingProcesses(for: item.category)
            let bypassesCategoryBlocker: Bool = {
                switch item.actionType {
                case .dockerPrune, .simctlDeleteDevice:
                    return true
                default:
                    return false
                }
            }()

            if !bypassesCategoryBlocker && (!activeProcs.isEmpty || item.isRunningDependency) {
                let procLabel = !activeProcs.isEmpty
                    ? activeProcs.joined(separator: ", ")
                    : (item.runningProcessNames.isEmpty ? item.category.rawValue : item.runningProcessNames.joined(separator: ", "))
                let msg = "Cleanup blocked: Close \(procLabel) before cleaning \(item.category.rawValue) runtime data."
                blockedMessages.append(msg)
                let entry = CleanupHistoryEntry(
                    category: item.category.rawValue,
                    itemName: item.name,
                    path: item.exactCommandOrPathDescription,
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    actionDescription: item.actionKind.rawValue,
                    status: .blocked,
                    success: false,
                    message: msg
                )
                CleanupHistoryStore.shared.appendEntry(entry)
                failCount += 1
                continue
            }

            do {
                let result = try await executor.execute(item, ageFilter: ageFilter)
                totalProcessed += result.processedBytes
                totalMovedToTrash += result.movedToTrashBytes

                if result.status == .nothingEligible {
                    nothingEligibleCount += 1
                    let noOpMsg = result.message ?? (ageFilter != .all
                        ? "Nothing eligible for cleanup with the current \(ageFilter.rawValue)-day filter."
                        : "Nothing eligible for cleanup.")
                    let entry = CleanupHistoryEntry(
                        category: item.category.rawValue,
                        itemName: item.name,
                        path: item.exactCommandOrPathDescription,
                        processedBytes: 0,
                        movedToTrashBytes: 0,
                        actuallyFreedBytes: 0,
                        actionDescription: result.action.rawValue,
                        status: .nothingEligible,
                        success: false,
                        message: noOpMsg
                    )
                    CleanupHistoryStore.shared.appendEntry(entry)
                } else {
                    successCount += 1
                    let note = result.message ?? "Moved to macOS Trash (\(Formatters.bytes(result.movedToTrashBytes))). Empty Trash to recover disk space."
                    let entry = CleanupHistoryEntry(
                        category: item.category.rawValue,
                        itemName: item.name,
                        path: item.exactCommandOrPathDescription,
                        processedBytes: result.processedBytes,
                        movedToTrashBytes: result.movedToTrashBytes,
                        actuallyFreedBytes: result.actuallyFreedBytes,
                        actionDescription: result.action.rawValue,
                        status: result.status,
                        success: true,
                        message: note
                    )
                    CleanupHistoryStore.shared.appendEntry(entry)
                    selectedIDs.remove(item.id)
                }
            } catch {
                failCount += 1
                let errText = error.localizedDescription
                blockedMessages.append(errText)
                let status: CleanupExecutionStatus = (error is CleanerError || error is SafetyError) ? .blocked : .failed
                let entry = CleanupHistoryEntry(
                    category: item.category.rawValue,
                    itemName: item.name,
                    path: item.exactCommandOrPathDescription,
                    processedBytes: 0,
                    movedToTrashBytes: 0,
                    actuallyFreedBytes: 0,
                    actionDescription: item.actionKind.rawValue,
                    status: status,
                    success: false,
                    message: errText
                )
                CleanupHistoryStore.shared.appendEntry(entry)
            }
        }

        let overallFreeAfter = DiskScanner.shared.freeDiskSpaceBytes()
        let observedDelta = max(0, overallFreeAfter - overallFreeBefore)

        self.lastCleanupSummary = CleanupBatchSummary(
            date: Date(),
            processedBytes: totalProcessed,
            movedToTrashBytes: totalMovedToTrash,
            observedSystemFreeSpaceDelta: observedDelta,
            succeededCount: successCount,
            nothingEligibleCount: nothingEligibleCount,
            failedOrBlockedCount: failCount,
            blockedMessages: blockedMessages
        )
        self.historyEntries = CleanupHistoryStore.shared.loadEntries()

        if !blockedMessages.isEmpty && successCount == 0 {
            self.statusBannerMessage = blockedMessages.first
        } else if successCount == 0 && nothingEligibleCount > 0 {
            self.statusBannerMessage = ageFilter != .all
                ? "Nothing eligible for cleanup with the current \(ageFilter.rawValue)-day filter."
                : "Nothing eligible for cleanup."
        } else {
            self.statusBannerMessage = "Cleanup completed — Processed: \(Formatters.bytes(totalProcessed)) • Moved to Trash: \(Formatters.bytes(totalMovedToTrash)) • Observed system free-space change: \(Formatters.bytes(observedDelta))."
        }

        await performScan()
    }

    public func deleteSimulatorRuntime(_ runtime: SimulatorRuntimeInfo) async {
        let latestSnapshot = await ProcessMonitor.shared.captureSnapshot()
        let activeProcs = latestSnapshot.matchingProcesses(for: .iosSimulators)
        if !activeProcs.isEmpty {
            let procLabel = activeProcs.joined(separator: ", ")
            let msg = "Cleanup blocked: Close \(procLabel) before cleaning \(CleanerCategory.iosSimulators.rawValue) runtime data."
            self.statusBannerMessage = msg
            let entry = CleanupHistoryEntry(
                category: CleanerCategory.iosSimulators.rawValue,
                itemName: "Runtime \(runtime.name)",
                path: "xcrun simctl runtime delete \(runtime.id)",
                processedBytes: 0,
                movedToTrashBytes: 0,
                actuallyFreedBytes: 0,
                actionDescription: CleanupResultAction.simctlDelete.rawValue,
                status: .blocked,
                success: false,
                message: msg
            )
            CleanupHistoryStore.shared.appendEntry(entry)
            self.historyEntries = CleanupHistoryStore.shared.loadEntries()
            return
        }

        let freeBefore = DiskScanner.shared.freeDiskSpaceBytes()
        let res = await ShellRunner.shared.run("/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", runtime.id])
        let freeAfter = DiskScanner.shared.freeDiskSpaceBytes()
        let delta = max(0, freeAfter - freeBefore)

        let entry = CleanupHistoryEntry(
            category: CleanerCategory.iosSimulators.rawValue,
            itemName: "Runtime \(runtime.name)",
            path: "xcrun simctl runtime delete \(runtime.id)",
            processedBytes: delta,
            movedToTrashBytes: 0,
            actuallyFreedBytes: delta,
            actionDescription: CleanupResultAction.simctlDelete.rawValue,
            status: res.isSuccess ? .cleaned : .failed,
            success: res.isSuccess,
            message: res.isSuccess ? "Runtime deleted via simctl" : res.stderr
        )
        CleanupHistoryStore.shared.appendEntry(entry)
        self.historyEntries = CleanupHistoryStore.shared.loadEntries()
        await performScan()
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
