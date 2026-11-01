import SwiftUI

public struct MacStorageAnalyzerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var expandedCategories: Set<MacStorageCategory> = Set(MacStorageCategory.allCases)
    @State private var showingInspectedRoots: Bool = false
    @State private var selectedCategoryFilter: MacStorageCategory? = nil
    @State private var searchText: String = ""

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    private var summary: MacStorageSummary {
        viewModel.macStorageSummary
    }

    private var filteredGroups: [MacStorageCategoryGroup] {
        summary.categoryGroups.compactMap { group in
            if let catFilter = selectedCategoryFilter, group.category != catFilter {
                return nil
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return group }
            let matchedItems = group.items.filter { item in
                item.name.lowercased().contains(q) ||
                item.path.lowercased().contains(q) ||
                item.explanation.lowercased().contains(q) ||
                group.category.rawValue.lowercased().contains(q)
            }
            guard !matchedItems.isEmpty else { return nil }
            return MacStorageCategoryGroup(category: group.category, items: matchedItems)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            summaryBanner
            Divider()
            domainBreakdownBar
            Divider()
            controlsToolbar
            Divider()

            if showingInspectedRoots {
                inspectedRootsSection
                Divider()
            }

            if viewModel.isScanningMacStorage && summary.categoryGroups.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Analyzing Developer Mac Storage across known roots (read-only)...")
                        .font(.headline)
                    Text("Inspecting ~/Library/Caches, ~/Library/Application Support, ~/Library/Developer, ~/.cache, ~/.npm, ~/.gradle, ~/.android & ~/Developer without touching /System, Keychains, Mail, Photos, or iCloud.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 680)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(filteredGroups) { group in
                            MacStorageCategoryCard(
                                group: group,
                                isExpanded: expandedCategories.contains(group.category),
                                onToggleExpand: {
                                    if expandedCategories.contains(group.category) {
                                        expandedCategories.remove(group.category)
                                    } else {
                                        expandedCategories.insert(group.category)
                                    }
                                },
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var summaryBanner: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "Total Developer Storage",
                value: Formatters.bytes(summary.totalDeveloperStorageBytes),
                subtitle: "Deduplicated across all developer roots",
                icon: "internaldrive.fill",
                color: .primary
            )
            summaryCard(
                title: "Safe Cleanup",
                value: Formatters.bytes(summary.safeCleanupBytes),
                subtitle: "Verified regenerable caches & logs",
                icon: "checkmark.shield.fill",
                color: .green
            )
            summaryCard(
                title: "Review",
                value: Formatters.bytes(summary.reviewCleanupBytes),
                subtitle: "Simulators, VMs, runtimes, browsers & deps",
                icon: "eye.trianglebadge.exclamationmark.fill",
                color: .orange
            )
            summaryCard(
                title: "Protected",
                value: Formatters.bytes(summary.protectedBytes),
                subtitle: "Code, sessions, SDKs, Docker VM & DBs",
                icon: "lock.fill",
                color: .secondary
            )
            summaryCard(
                title: "Physical Free",
                value: Formatters.bytes(viewModel.physicalFreeBytes),
                subtitle: "macOS Available: \(Formatters.bytes(viewModel.macOSAvailableBytes))",
                icon: "externaldrive.fill.badge.checkmark",
                color: .accentColor
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    private func summaryCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundColor(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var domainBreakdownBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text("Global Breakdown (Zero Double-Counting):")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                domainPill(label: "Developer Projects", bytes: summary.developerProjectsBytes, color: .blue)
                domainPill(label: "AI Tools", bytes: summary.aiToolsBytes, color: .purple)
                domainPill(label: "Simulators", bytes: summary.simulatorsBytes, color: .indigo)
                domainPill(label: "Android SDK", bytes: summary.androidSDKBytes, color: .teal)
                domainPill(label: "Docker", bytes: summary.dockerBytes, color: .cyan)
                domainPill(label: "Caches", bytes: summary.cachesBytes, color: .green)
                domainPill(label: "Other Developer Data", bytes: summary.otherDeveloperDataBytes, color: .secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func domainPill(label: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
            Text(Formatters.bytes(bytes))
                .font(.caption.monospacedDigit().bold())
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.1)))
    }

    private var controlsToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter Mac Storage items, paths, or tools...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 240)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))

            Picker("Category:", selection: $selectedCategoryFilter) {
                Text("All Categories (\(summary.categoryGroups.count))").tag(MacStorageCategory?.none)
                ForEach(MacStorageCategory.allCases) { cat in
                    Text(cat.rawValue).tag(MacStorageCategory?.some(cat))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 210)

            Button {
                showingInspectedRoots.toggle()
            } label: {
                Label(
                    showingInspectedRoots ? "Hide Inspected Roots" : "Inspected Roots (\(summary.inspectedRoots.count))",
                    systemImage: "folder.badge.questionmark"
                )
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if viewModel.isScanningProjects || viewModel.isScanningMacStorage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.projectScanProgressText.isEmpty ? "Updating Mac Storage..." : viewModel.projectScanProgressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                if expandedCategories.count == MacStorageCategory.allCases.count {
                    expandedCategories.removeAll()
                } else {
                    expandedCategories = Set(MacStorageCategory.allCases)
                }
            } label: {
                Text(expandedCategories.count == MacStorageCategory.allCases.count ? "Collapse All" : "Expand All")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var inspectedRootsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Safe Scope: Inspected Developer Roots Only — Never scans /System, /Applications, Keychains, Mail, Photos, or iCloud",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption.bold())
                .foregroundColor(.green)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10)], spacing: 8) {
                ForEach(summary.inspectedRoots) { root in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: root.exists ? "folder.fill" : "folder.badge.minus")
                            .foregroundColor(root.exists ? .accentColor : .secondary)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(root.displayPath)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                Spacer()
                                Text(root.exists ? Formatters.bytes(root.physicalBytes) : "Not present")
                                    .font(.caption.monospacedDigit().bold())
                            }
                            Text(root.note)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            if root.exists && (root.safeReclaimableBytes > 0 || root.reviewReclaimableBytes > 0) {
                                HStack(spacing: 8) {
                                    if root.safeReclaimableBytes > 0 {
                                        Text("SAFE: \(Formatters.bytes(root.safeReclaimableBytes))")
                                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                            .foregroundColor(.green)
                                    }
                                    if root.reviewReclaimableBytes > 0 {
                                        Text("REVIEW: \(Formatters.bytes(root.reviewReclaimableBytes))")
                                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.04))
    }
}

public struct MacStorageCategoryCard: View {
    let group: MacStorageCategoryGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @ObservedObject var viewModel: CleanerViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                        Image(systemName: group.category.iconName)
                            .foregroundColor(.accentColor)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.category.rawValue)
                                .font(.headline)
                            Text(group.category.subtitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 12) {
                    if group.safeReclaimableBytes > 0 {
                        Text("SAFE: \(Formatters.bytes(group.safeReclaimableBytes))")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundColor(.green)
                    }
                    if group.reviewReclaimableBytes > 0 {
                        Text("REVIEW: \(Formatters.bytes(group.reviewReclaimableBytes))")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundColor(.orange)
                    }
                    if group.protectedBytes > 0 {
                        Text("Protected: \(Formatters.bytes(group.protectedBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Text("Total: \(Formatters.bytes(group.totalPhysicalBytes))")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        if item.id == "mac-storage-developer-projects-overview" {
                            developerProjectsOverviewRow(item: item)
                        } else {
                            CleanableItemRow(item: item, viewModel: viewModel)
                        }
                        if item.id != group.items.last?.id {
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

    private func developerProjectsOverviewRow(item: CleanableItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill.badge.gearshape")
                .foregroundColor(.accentColor)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text("DEDUPLICATED OVERVIEW")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                    Spacer()
                    Text(Formatters.bytes(item.physicalSize))
                        .font(.subheadline.monospacedDigit().bold())
                    if item.reclaimableSize > 0 {
                        Text("(Potential: \(Formatters.bytes(item.reclaimableSize)))")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.accentColor)
                    }
                }

                Text(item.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(item.explanation)
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.85))
            }

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    viewModel.selectedTab = .projectStorage
                } label: {
                    Label("Open Project Storage", systemImage: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.inspectPathInFinder(item.path)
                } label: {
                    Label("Inspect", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
