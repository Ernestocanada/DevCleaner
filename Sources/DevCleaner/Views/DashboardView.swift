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

            if viewModel.isScanning && viewModel.items.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Scanning developer caches & virtual devices (read-only)...")
                        .font(.headline)
                    Text("Staying on local APFS filesystem (du -x), ignoring virtual CoreDevice mounts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(CleanerCategory.allCases) { category in
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

    private func lastCleanupBanner(summary: CleanupBatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label("Last Cleanup Completed", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.green)

                Text("Processed: \(Formatters.bytes(summary.processedBytes))")
                    .font(.caption.monospacedDigit().bold())

                Text("Moved to Trash: \(Formatters.bytes(summary.movedToTrashBytes))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.blue)

                Text("Actually Freed Now: \(Formatters.bytes(summary.actuallyFreedBytes))")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.green)

                if summary.movedToTrashBytes > 0 {
                    Text("Empty the macOS Trash to recover the remaining disk space.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

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

    private var headerSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("DevCleaner")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Developer Storage Cleaner")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    HStack(spacing: 16) {
                        Label("Never touches ~/Developer or source code", systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        if let scanDate = viewModel.lastScanDate {
                            Text("Last scan: \(scanDate.formatted(date: .omitted, time: .standard))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 24) {
                    statMetric(
                        title: "Free Disk Space",
                        value: Formatters.bytes(viewModel.freeSpaceBytes),
                        color: .primary
                    )
                    statMetric(
                        title: "Potential Cleanup (Est.)",
                        value: Formatters.bytes(viewModel.totalReclaimableBytes),
                        color: .accentColor
                    )
                    statMetric(
                        title: "Selected",
                        value: Formatters.bytes(viewModel.selectedReclaimableBytes),
                        color: .green
                    )
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.performScan() }
                } label: {
                    Label(viewModel.isScanning ? "Scanning..." : "Scan Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isCleaning)

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
                    Label("Open Trash", systemImage: "trash")
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

    private func statMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
        }
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
        items.reduce(0) { $0 + $1.physicalSize }
    }

    private var totalPotentialCleanup: Int64 {
        items.filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
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
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
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
                            .background(sim.isBooted ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
                            .foregroundColor(sim.isBooted ? .green : .secondary)
                            .cornerRadius(4)
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

                        if let mod = item.lastModified {
                            Text("Last activity: \(Formatters.relativeDate(mod))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
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
                Button {
                    viewModel.inspectInFinder(item)
                } label: {
                    Label("Inspect", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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
