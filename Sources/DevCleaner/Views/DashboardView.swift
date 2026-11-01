import SwiftUI

public struct DashboardView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var expandedCategories: Set<CleanerCategory> = Set(CleanerCategory.allCases)

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            tabSelectorBar
            Divider()

            if let summary = viewModel.lastCleanupSummary {
                lastCleanupBanner(summary: summary)
                Divider()
            } else if let banner = viewModel.statusBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(banner)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        viewModel.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            switch viewModel.selectedTab {
            case .systemAndTools:
                systemAndToolsContent
            case .projectStorage:
                ProjectStorageAnalyzerView(viewModel: viewModel)
            case .worktrees:
                WorktreeAnalyzerView(viewModel: viewModel)
            case .macStorage:
                MacStorageAnalyzerView(viewModel: viewModel)
            }

            Divider()
            footerBar
        }
        .sheet(isPresented: $viewModel.showingPreviewSheet) {
            CleanupPreviewSheet(
                viewModel: viewModel,
                itemsToPreview: viewModel.selectedItems
            )
        }
        .sheet(item: $viewModel.itemForSingleClean) { singleItem in
            CleanupPreviewSheet(
                viewModel: viewModel,
                itemsToPreview: [singleItem]
            )
        }
        .sheet(isPresented: $viewModel.showingHistorySheet) {
            CleanupHistorySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingRuntimesSheet) {
            SimulatorRuntimesSheet(viewModel: viewModel)
        }
        .task {
            if viewModel.lastScanDate == nil {
                await viewModel.performScan()
            }
        }
    }

    private var tabSelectorBar: some View {
        HStack(spacing: 10) {
            ForEach(MainAnalyzerTab.allCases) { tab in
                let isSelected = viewModel.selectedTab == tab
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.iconName)
                        Text(tab.rawValue)
                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                        if tab == .projectStorage && viewModel.projectSummary.totalProjectsCount > 0 {
                            Text("\(viewModel.projectSummary.totalProjectsCount) • \(Formatters.bytes(viewModel.projectSummary.totalProjectsPhysicalBytes))")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.15)))
                        } else if tab == .worktrees && !viewModel.worktreeRecords.isEmpty {
                            let wtBytes = viewModel.worktreeRecords.reduce(Int64(0)) { $0 + $1.physicalBytes }
                            Text("\(viewModel.worktreeRecords.count) • \(Formatters.bytes(wtBytes))")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.15)))
                        } else if tab == .macStorage && viewModel.macStorageSummary.totalDeveloperStorageBytes > 0 {
                            Text(Formatters.bytes(viewModel.macStorageSummary.totalDeveloperStorageBytes))
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.15)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(isSelected ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var systemAndToolsContent: some View {
        if viewModel.isScanning && viewModel.items.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                ProgressView()
                    .scaleEffect(1.2)
                Text("Scanning developer caches, projects & virtual devices (read-only)...")
                    .font(.headline)
                Text("Staying on local APFS filesystem (st_dev check), deduplicating hardlinks, ignoring virtual CoreDevice mounts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(CleanerCategory.allCases.filter { $0 != .projectStorage }) { category in
                        let catItems = viewModel.items(for: category)
                        if !catItems.isEmpty {
                            CategoryCardView(
                                category: category,
                                items: catItems,
                                isExpanded: expandedCategories.contains(category),
                                onToggleExpand: {
                                    if expandedCategories.contains(category) {
                                        expandedCategories.remove(category)
                                    } else {
                                        expandedCategories.insert(category)
                                    }
                                },
                                viewModel: viewModel
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func lastCleanupBanner(summary: CleanupBatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                if summary.succeededCount == 0 && summary.nothingEligibleCount > 0 {
                    Label("Nothing Eligible for Cleanup", systemImage: "minus.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                } else {
                    Label("Last Cleanup Completed", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }

                Text("Processed: \(Formatters.bytes(summary.processedBytes))")
                    .font(.caption.monospacedDigit().bold())

                Text("Moved to Trash: \(Formatters.bytes(summary.movedToTrashBytes))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.blue)

                Text("Observed system free-space change: \(Formatters.bytes(summary.observedSystemFreeSpaceDelta))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    viewModel.openTrashInFinder()
                } label: {
                    Label("Show Trash in Finder", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.lastCleanupSummary = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Text("This free-space value is system-wide and may include unrelated APFS/macOS activity.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if summary.movedToTrashBytes > 0 {
                    Text("•  Empty the macOS Trash to recover the remaining disk space.")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.primary)
                }
            }

            if !summary.blockedMessages.isEmpty {
                ForEach(summary.blockedMessages, id: \.self) { msg in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(msg)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.08))
    }

    private static let storageMetricsHelpText = """
macOS Available includes purgeable storage that macOS can reclaim automatically.
Physical Free is the SSD space that is actually empty right now.
Purgeable is the difference (macOS Available − Physical Free).
In Trash shows items in ~/.Trash waiting to be permanently emptied.
"""

    @State private var showingStorageHelpPopover: Bool = false

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    DevCleanerBrandIconView(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("DevCleaner")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("Developer Storage & Project Analyzer")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 14) {
                            Label("Safety First: Verified Rules Only • Protects Code, Git, Certs & Sessions", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            if let scanDate = viewModel.lastScanDate {
                                Text("Last scan: \(scanDate.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .top, spacing: 16) {
                        statMetric(
                            title: "macOS Available",
                            value: Formatters.bytes(viewModel.macOSAvailableBytes),
                            color: .primary,
                            helpText: "Storage macOS says is available for important usage (includes purgeable space)."
                        )
                        statMetric(
                            title: "Physical Free",
                            value: Formatters.bytes(viewModel.physicalFreeBytes),
                            color: .secondary,
                            helpText: "Storage physically free on the SSD right now (excluding purgeable space)."
                        )
                        statMetric(
                            title: "Purgeable",
                            value: Formatters.bytes(viewModel.purgeableBytes),
                            color: .secondary,
                            helpText: "Purgeable APFS space managed by macOS (macOS Available minus Physical Free)."
                        )
                        statMetric(
                            title: "In Trash",
                            value: Formatters.bytes(viewModel.trashBytes),
                            color: viewModel.trashBytes > 0 ? .orange : .secondary,
                            helpText: "Space currently occupied by files in ~/.Trash (not yet freed on SSD)."
                        )
                        statMetric(
                            title: "Potential Cleanup",
                            value: Formatters.bytes(viewModel.potentialCleanupBytes),
                            color: .accentColor,
                            helpText: "Estimated developer cache and build storage eligible for cleanup."
                        )
                        statMetric(
                            title: "Selected",
                            value: Formatters.bytes(viewModel.selectedCleanupBytes),
                            color: .green,
                            helpText: "Currently selected items ready for preview and cleanup."
                        )

                        Button {
                            showingStorageHelpPopover.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        .help(Self.storageMetricsHelpText)
                        .popover(isPresented: $showingStorageHelpPopover, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Understanding macOS Storage Metrics")
                                    .font(.caption.bold())
                                Text("• macOS Available includes purgeable storage that macOS can reclaim automatically.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• Physical Free is the SSD space that is actually empty right now.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• In Trash shows files moved to ~/.Trash that still occupy blocks until Trash is emptied.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .frame(width: 340)
                        }
                    }

                    Text("macOS Available includes purgeable storage. Physical Free is actual empty SSD space. Moving to Trash frees blocks after Trash is emptied.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .help(Self.storageMetricsHelpText)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.performScan() }
                } label: {
                    Label(viewModel.isScanning ? "Scan Again" : "Scan Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCleaning)

                Button {
                    viewModel.selectRecommendedSafeItems()
                } label: {
                    Label("Recommended Cleanup (SAFE Only)", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button {
                    viewModel.activateDevelopmentCleanupMode(filter: viewModel.ageFilter == .all ? .sevenDays : viewModel.ageFilter)
                } label: {
                    Label("Development Cleanup", systemImage: "wrench.and.screwdriver.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Picker("Age Filter:", selection: $viewModel.ageFilter) {
                    ForEach(AgeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: viewModel.ageFilter) { _, _ in
                    Task { await viewModel.performScan() }
                }

                Spacer()

                Button {
                    viewModel.openTrashInFinder()
                } label: {
                    Label("Open Trash (\(Formatters.bytes(viewModel.trashBytes)))", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.showingHistorySheet = true
                } label: {
                    Label("Cleanup History (\(viewModel.historyEntries.count))", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func statMetric(title: String, value: String, color: Color, helpText: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
        }
        .help(helpText)
    }

    private var footerBar: some View {
        HStack {
            HStack(spacing: 14) {
                Text("Selected: \(viewModel.selectedItems.count) items")
                    .font(.subheadline.weight(.medium))
                Text("SAFE: \(Formatters.bytes(viewModel.selectedBytes(for: .safe)))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
                Text("REVIEW: \(Formatters.bytes(viewModel.selectedBytes(for: .review)))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.orange)
                Text("CAUTION: \(Formatters.bytes(viewModel.selectedBytes(for: .caution)))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.red)
            }

            Spacer()

            Button("Clear Selection") {
                viewModel.selectedIDs.removeAll()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(viewModel.selectedIDs.isEmpty)

            Button {
                viewModel.showingPreviewSheet = true
            } label: {
                Label("Clean Selected (\(Formatters.bytes(viewModel.selectedReclaimableBytes)))", systemImage: "trash.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isScanning || viewModel.isCleaning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

public struct CategoryCardView: View {
    let category: CleanerCategory
    let items: [CleanableItem]
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @ObservedObject var viewModel: CleanerViewModel

    private var totalPhysical: Int64 {
        // For iOS Simulators, exclude the system-mounted runtime volume size from the ~/Library/Developer/CoreSimulator/Devices physical total if needed, or sum all items
        items.filter { $0.id != "sim-runtimes-preserved" }.reduce(0) { $0 + $1.physicalSize }
    }

    private var totalPotentialCleanup: Int64 {
        items.filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
    }

    private var groupedSimulatorItems: [(runtimeName: String, devices: [CleanableItem])] {
        let deviceItems = items.filter { $0.simulatorMetadata != nil }
        let grouped = Dictionary(grouping: deviceItems) { $0.simulatorMetadata?.runtimeName ?? "Other" }
        return grouped.map { key, list in
            (key, list.sorted { $0.physicalSize > $1.physicalSize })
        }.sorted { lhs, rhs in
            lhs.runtimeName.localizedStandardCompare(rhs.runtimeName) == .orderedDescending
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                        Image(systemName: category.iconName)
                            .foregroundColor(.accentColor)
                            .font(.headline)
                        Text(category.rawValue)
                            .font(.headline)
                    }
                }
                .buttonStyle(.plain)

                if let activeProcs = items.first?.runningProcessNames, !activeProcs.isEmpty, category != .iosSimulators {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Cleanup blocked: Close \(activeProcs.joined(separator: ", ")) before cleaning")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14))
                    .cornerRadius(6)
                }

                Spacer()

                if category == .iosSimulators {
                    Button("Advanced: Manage Runtimes") {
                        viewModel.showingRuntimesSheet = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                Text("Disk Usage: \(Formatters.bytes(totalPhysical))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)

                Text("Potential Cleanup: \(Formatters.bytes(totalPotentialCleanup))")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundColor(totalPotentialCleanup > 0 ? .primary : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            if isExpanded {
                Divider()
                if category == .iosSimulators {
                    simulatorGroupedContent
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            CleanableItemRow(item: item, viewModel: viewModel)
                            if item.id != items.last?.id {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var simulatorGroupedContent: some View {
        let nonDeviceTop = items.filter { $0.simulatorMetadata == nil && $0.id == "sim-delete-unavailable" }
        let nonDeviceBottom = items.filter { $0.simulatorMetadata == nil && $0.id != "sim-delete-unavailable" }

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(nonDeviceTop) { item in
                CleanableItemRow(item: item, viewModel: viewModel)
                Divider()
            }

            ForEach(groupedSimulatorItems, id: \.runtimeName) { group in
                let groupBytes = group.devices.reduce(Int64(0)) { $0 + $1.physicalSize }
                HStack {
                    Image(systemName: "iphone.gen3")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Text("Runtime Group: \(group.runtimeName)")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Text("(\(group.devices.count) simulators • \(Formatters.bytes(groupBytes)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.06))

                Divider()

                ForEach(group.devices) { simItem in
                    CleanableItemRow(item: simItem, viewModel: viewModel)
                    Divider()
                        .padding(.leading, 36)
                }
            }

            ForEach(nonDeviceBottom) { item in
                CleanableItemRow(item: item, viewModel: viewModel)
            }
        }
    }
}

public struct CleanableItemRow: View {
    let item: CleanableItem
    @ObservedObject var viewModel: CleanerViewModel

    private var isSelected: Bool {
        viewModel.selectedIDs.contains(item.id)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in viewModel.toggleSelection(for: item) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!item.canBeSelected)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    RiskBadgeView(risk: item.riskLevel)

                    if let sim = item.simulatorMetadata {
                        Text(sim.displayBadgeText)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                sim.isBooted
                                    ? Color.green.opacity(0.18)
                                    : (sim.isFavorite ? Color.yellow.opacity(0.22) : Color.secondary.opacity(0.15))
                            )
                            .foregroundColor(
                                sim.isBooted
                                    ? .green
                                    : (sim.isFavorite ? .orange : .secondary)
                            )
                            .cornerRadius(4)

                        Text(sim.recommendationBadgeText)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                sim.recommendationBadgeText == "KEEP"
                                    ? Color.green.opacity(0.15)
                                    : (sim.recommendationBadgeText == "REVIEW" ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.15))
                            )
                            .foregroundColor(
                                sim.recommendationBadgeText == "KEEP"
                                    ? .green
                                    : (sim.recommendationBadgeText == "REVIEW" ? .orange : .secondary)
                            )
                            .cornerRadius(4)

                        if !item.name.contains(sim.deviceModel) {
                            Text("Model: \(sim.deviceModel)")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                .foregroundStyle(.secondary)
                        }

                        if !sim.installedAppNames.isEmpty {
                            Text("\(sim.installedAppNames.count) app\(sim.installedAppNames.count == 1 ? "" : "s") installed")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                                .foregroundStyle(.blue)
                        } else if sim.hasLocalData {
                            Text("Contains local data")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.12)))
                                .foregroundStyle(.purple)
                        } else {
                            Text("No user apps")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if item.category == .claude || item.category == .codex {
                        if item.requiresRedownload {
                            Text("Requires Re-download")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                                .foregroundStyle(.orange)
                        }
                        if !item.affectsSessionsOrConfig && item.riskLevel != .neverDelete {
                            Text("Sessions & Config Safe")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                                .foregroundStyle(.green)
                        }
                    }

                    if item.isRunningDependency && item.simulatorMetadata == nil {
                        let procText = item.runningProcessNames.isEmpty ? item.category.rawValue : item.runningProcessNames.joined(separator: ", ")
                        Text("Close \(procText) before cleaning")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if item.hasSparseDifference {
                            HStack(spacing: 6) {
                                Text("Physical disk usage: \(Formatters.bytes(item.physicalSize))")
                                    .font(.subheadline.monospacedDigit().bold())
                                Text("(Logical sparse size: \(Formatters.bytes(item.logicalSize)))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        } else if item.physicalSize > 0 {
                            HStack(spacing: 6) {
                                Text(Formatters.bytes(item.physicalSize))
                                    .font(.subheadline.monospacedDigit().bold())
                                if item.reclaimableSize != item.physicalSize && item.riskLevel != .neverDelete {
                                    Text("(Potential: \(Formatters.bytes(item.reclaimableSize)))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.accentColor)
                                }
                            }
                        } else {
                            Text("—")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text(item.usageDateDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text(item.exactCommandOrPathDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                Text(item.explanation)
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.85))

                HStack(spacing: 12) {
                    Text("Action: \(item.deletionConsequence)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Impact: \(item.regenerationImpact)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if let sim = item.simulatorMetadata {
                        Button {
                            viewModel.toggleSimulatorFavorite(udid: sim.udid)
                        } label: {
                            Image(systemName: sim.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(sim.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(sim.isFavorite ? "Unmark Favorite Simulator" : "Mark Simulator as Favorite (protected from cleanup)")
                    }

                    Button {
                        viewModel.inspectInFinder(item)
                    } label: {
                        Label("Inspect", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if item.riskLevel != .neverDelete {
                    Button {
                        viewModel.itemForSingleClean = item
                    } label: {
                        Label("Clean", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!item.canBeSelected || viewModel.isCleaning)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
