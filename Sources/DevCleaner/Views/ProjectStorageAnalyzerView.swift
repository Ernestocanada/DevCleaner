import SwiftUI

public struct ProjectStorageAnalyzerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var showOnlyRecoverable: Bool = false

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    private var filteredProjects: [ProjectStorageReport] {
        viewModel.projectReports.filter { report in
            if showOnlyRecoverable && report.potentialRecoveryBytes == 0 && report.worktreesBytes == 0 {
                return false
            }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                let query = searchText.lowercased()
                let matchesName = report.name.lowercased().contains(query)
                let matchesPath = report.path.lowercased().contains(query)
                let matchesArtifact = report.artifacts.contains {
                    $0.relativePath.lowercased().contains(query) || $0.name.lowercased().contains(query)
                }
                return matchesName || matchesPath || matchesArtifact
            }
            return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            analyzerHeaderBar
            Divider()
            summaryMetricsRow
            Divider()

            if viewModel.isScanningProjects && viewModel.projectReports.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text(viewModel.projectScanProgressText.isEmpty ? "Analyzing projects..." : viewModel.projectScanProgressText)
                        .font(.headline)
                    Button("Cancel Scan") {
                        viewModel.cancelProjectScan()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if filteredProjects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No matching projects found in \(viewModel.projectsRootPath)")
                        .font(.headline)
                    Text("Try clearing the search filter or selecting another developer directory.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredProjects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            if expandedProjectIDs.isEmpty {
                for top in viewModel.projectReports.prefix(3) where top.potentialRecoveryBytes > 0 {
                    expandedProjectIDs.insert(top.id)
                }
            }
        }
    }

    private var analyzerHeaderBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(.blue)
                    Text("Project Storage Analyzer")
                        .font(.headline)
                    Text("(\(viewModel.projectSummary.totalProjectsCount) projects)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.projectsRootPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button("Choose Folder...") {
                viewModel.chooseProjectsRootFolder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if viewModel.projectsRootPath != ProjectStorageAnalyzer.defaultDeveloperRoot {
                Button("Reset to ~/Developer") {
                    viewModel.resetProjectsRootToDefault()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }

            if viewModel.isScanningProjects {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.projectScanProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel") {
                        viewModel.cancelProjectScan()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            Spacer()

            Toggle("With Recoverable / Worktrees Only", isOn: $showOnlyRecoverable)
                .toggleStyle(.checkbox)
                .font(.caption)

            TextField("Filter project or artifact (.cache, .next, node_modules)...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button {
                viewModel.selectSafeProjectArtifactsOnly()
            } label: {
                Label("Select SAFE Caches", systemImage: "checkmark.shield.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var summaryMetricsRow: some View {
        let s = viewModel.projectSummary
        return HStack(spacing: 12) {
            metricBox(
                title: "Total Projects Storage",
                value: Formatters.bytes(s.totalProjectsPhysicalBytes),
                subtitle: "\(s.totalProjectsCount) projects measured",
                color: .primary,
                icon: "internaldrive.fill"
            )
            metricBox(
                title: "Regenerable Caches",
                value: Formatters.bytes(s.regenerableCachesAndBuildsBytes),
                subtitle: "Verified SAFE (.next, .expo, DerivedData, caches)",
                color: .green,
                icon: "checkmark.shield.fill"
            )
            metricBox(
                title: "Review Required",
                value: Formatters.bytes(s.reviewRequiredBytes),
                subtitle: "node_modules, Pods, .xcresult bundles",
                color: .orange,
                icon: "exclamationmark.triangle.fill"
            )
            metricBox(
                title: "Protected Data",
                value: Formatters.bytes(s.protectedDataBytes + s.worktreesBytes),
                subtitle: "Source, .git, worktrees (\(Formatters.bytes(s.worktreesBytes))), evidence",
                color: .secondary,
                icon: "lock.shield.fill"
            )
            metricBox(
                title: "Potential Recovery",
                value: Formatters.bytes(s.potentialRecoveryBytes),
                subtitle: "Selected in Projects: \(Formatters.bytes(viewModel.selectedProjectReclaimableBytes))",
                color: .blue,
                icon: "arrow.3.trianglepath"
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func metricBox(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func projectCard(_ project: ProjectStorageReport) -> some View {
        let isExpanded = expandedProjectIDs.contains(project.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if isExpanded {
                        expandedProjectIDs.remove(project.id)
                    } else {
                        expandedProjectIDs.insert(project.id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(project.name)
                                    .font(.system(size: 15, weight: .bold))
                                ForEach(project.projectTypeTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                                        .foregroundStyle(.blue)
                                }
                                RiskBadgeView(risk: project.overallRiskLevel)
                                if !project.activeProcessNames.isEmpty {
                                    Text("IN USE: \(project.activeProcessNames.joined(separator: ", "))")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(project.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Category breakdown pills
                HStack(spacing: 10) {
                    if project.cachesBytes > 0 {
                        breakdownPill(label: "Caches", bytes: project.cachesBytes, color: .green)
                    }
                    if project.buildsBytes > 0 {
                        breakdownPill(label: "Builds", bytes: project.buildsBytes, color: .teal)
                    }
                    if project.dependenciesBytes > 0 {
                        breakdownPill(label: "Deps", bytes: project.dependenciesBytes, color: .orange)
                    }
                    if project.worktreesBytes > 0 {
                        breakdownPill(label: "Worktrees", bytes: project.worktreesBytes, color: .purple)
                    }
                    breakdownPill(label: "Protected", bytes: project.protectedBytes, color: .secondary)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total: \(Formatters.bytes(project.totalPhysicalBytes))")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    HStack(spacing: 6) {
                        if project.safeRecoverableBytes > 0 {
                            Text("SAFE: \(Formatters.bytes(project.safeRecoverableBytes))")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if project.reviewRecoverableBytes > 0 {
                            Text("Review: \(Formatters.bytes(project.reviewRecoverableBytes))")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        Text("• \(Formatters.relativeDate(project.lastActivityDate))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 190, alignment: .trailing)

                Button {
                    viewModel.inspectPathInFinder(project.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal project in Finder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            if isExpanded {
                Divider()
                if project.artifacts.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.secondary)
                        Text("No separate cache, build, or dependency directories detected — 100% protected project files (\(Formatters.bytes(project.protectedBytes))).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(project.artifacts) { artifact in
                            artifactRow(artifact)
                            if artifact.id != project.artifacts.last?.id {
                                Divider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func breakdownPill(label: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Formatters.bytes(bytes))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(0.08))
        )
    }

    private func artifactRow(_ artifact: ProjectArtifactEntry) -> some View {
        let item = artifact.cleanableItem
        let isSelected = viewModel.selectedIDs.contains(item.id)

        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in viewModel.toggleSelection(for: item) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!item.canBeSelected)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: artifact.artifactCategory.iconName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(artifact.name)
                        .font(.system(size: 13, weight: .semibold))
                    RiskBadgeView(risk: artifact.riskLevel)
                    Text(artifact.artifactCategory.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                    if item.requiresRedownload {
                        Text("Requires Re-install / Download")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .foregroundStyle(.orange)
                    }
                }

                Text(artifact.fullPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(artifact.explanation)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.85))

                Text("Impact: \(artifact.deletionConsequence)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.bytes(artifact.physicalBytes))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if artifact.reclaimableBytes > 0 {
                    Text("Recoverable: \(Formatters.bytes(artifact.reclaimableBytes))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(artifact.riskLevel == .safe ? .green : .orange)
                } else {
                    Text("Protected (0 B)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Modified: \(Formatters.relativeDate(artifact.lastModified))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140, alignment: .trailing)

            HStack(spacing: 6) {
                Button {
                    viewModel.inspectPathInFinder(artifact.fullPath)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")

                if item.canBeSelected {
                    Button("Clean...") {
                        viewModel.itemForSingleClean = item
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
