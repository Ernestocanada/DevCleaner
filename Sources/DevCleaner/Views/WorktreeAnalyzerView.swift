import SwiftUI

public struct WorktreeAnalyzerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var searchText: String = ""
    @State private var filterClassification: String = "ALL"

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    private var filteredRecords: [GitWorktreeRecord] {
        let base = viewModel.worktreeRecords
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return base.filter { record in
            let matchesQuery: Bool = {
                guard !q.isEmpty else { return true }
                if record.sourceProjectName.lowercased().contains(q) ||
                    record.worktreeName.lowercased().contains(q) ||
                    record.path.lowercased().contains(q) ||
                    record.branchLabel.lowercased().contains(q) ||
                    record.originKind.rawValue.lowercased().contains(q) {
                    return true
                }
                return record.artifactCandidates.contains {
                    $0.relativePath.lowercased().contains(q) ||
                    $0.artifactType.rawValue.lowercased().contains(q) ||
                    $0.classificationReason.lowercased().contains(q)
                }
            }()
            guard matchesQuery else { return false }

            switch filterClassification {
            case "SAFE":
                return record.artifactCandidates.contains { $0.classification == .safe }
            case "REVIEW":
                return record.artifactCandidates.contains { $0.classification == .review }
            case "STALE":
                return !record.isActiveOrRecent
            default:
                return true
            }
        }
    }

    private var groupedByProject: [(projectName: String, projectPath: String, records: [GitWorktreeRecord])] {
        let grouped = Dictionary(grouping: filteredRecords, by: { $0.sourceProjectPath })
        return grouped.map { key, recs in
            (recs.first?.sourceProjectName ?? key, key, recs.sorted {
                if $0.regenerableBytes != $1.regenerableBytes {
                    return $0.regenerableBytes > $1.regenerableBytes
                }
                return $0.physicalBytes > $1.physicalBytes
            })
        }.sorted { lhs, rhs in
            let lRegen = lhs.records.reduce(Int64(0)) { $0 + $1.regenerableBytes }
            let rRegen = rhs.records.reduce(Int64(0)) { $0 + $1.regenerableBytes }
            if lRegen != rRegen { return lRegen > rRegen }
            let lBytes = lhs.records.reduce(Int64(0)) { $0 + $1.physicalBytes }
            let rBytes = rhs.records.reduce(Int64(0)) { $0 + $1.physicalBytes }
            if lBytes != rBytes { return lBytes > rBytes }
            return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            informativeBanner
            Divider()
            summaryRow
            Divider()
            actionToolbar
            Divider()

            if viewModel.isScanningWorktrees && viewModel.worktreeRecords.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Inspecting Claude, Codex & Git worktrees and verifying regenerable artifacts...")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if filteredRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No matching AI or Git worktrees found")
                        .font(.headline)
                    Text("All inspected repositories only have their main working tree or no items match the current filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(groupedByProject, id: \.projectPath) { group in
                            projectWorktreeGroupCard(
                                projectName: group.projectName,
                                projectPath: group.projectPath,
                                records: group.records
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var informativeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Worktree Dependencies & Build Artifacts")
                    .font(.subheadline.bold())
                Text("Detects regenerable dependencies (`node_modules`, `Pods`) and build caches (`.next`, `.turbo`, `.cache`, `dist`, `build`, `.tsbuildinfo`, Firebase emulators) inside verified Claude Code, Codex, and Git worktrees. Worktrees themselves, branches, commits, tracked files, `.env*`, databases, and credentials are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Filter by repo, worktree, or artifact...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.06))
    }

    private var summaryRow: some View {
        let summary = viewModel.worktreeSummary
        let cfg = viewModel.worktreeInactivityConfig

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI Worktree Dependencies & Build Artifacts", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Stale guidance: unused \(cfg.inactiveDaysThreshold)+ days eligible for SAFE artifact cleanup • \(cfg.strongCandidateDaysThreshold)+ days highlighted as strong cleanup candidates (artifacts only; worktrees are never deleted)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                statBox(
                    title: "SAFE Reclaimable",
                    value: Formatters.bytes(summary.safeRegenerableBytes),
                    subtitle: "\(summary.safeCandidatesCount) verified Git-ignored artifacts",
                    color: summary.safeRegenerableBytes > 0 ? .green : .primary
                )
                statBox(
                    title: "Needs Review",
                    value: Formatters.bytes(summary.reviewRegenerableBytes),
                    subtitle: "\(summary.reviewCandidatesCount) unverified / untracked / dirty",
                    color: summary.reviewRegenerableBytes > 0 ? .orange : .secondary
                )
                statBox(
                    title: "Worktree Footprint",
                    value: Formatters.bytes(summary.totalWorktreesPhysicalBytes),
                    subtitle: "Retained / non-SAFE: \(Formatters.bytes(summary.retainedBytes))",
                    color: .primary
                )
                statBox(
                    title: "Claude & Codex",
                    value: "\(summary.claudeWorktreesCount) / \(summary.codexWorktreesCount)",
                    subtitle: summary.gitLinkedWorktreesCount > 0
                        ? "+ \(summary.gitLinkedWorktreesCount) registered Git linked"
                        : "Claude / Codex worktrees",
                    color: .purple
                )
                statBox(
                    title: "Active / Inactive",
                    value: "\(summary.activeWorktreesCount) / \(summary.inactiveWorktreesCount)",
                    subtitle: "Strong cleanup candidates (\(cfg.strongCandidateDaysThreshold)+d): \(summary.strongCandidateWorktreesCount)",
                    color: summary.strongCandidateWorktreesCount > 0 ? .orange : .blue
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var actionToolbar: some View {
        let cfg = viewModel.worktreeInactivityConfig
        let safeBytes = viewModel.worktreeSummary.safeRegenerableBytes
        let selectedWtBytes = viewModel.selectedWorktreeReclaimableBytes

        return HStack(spacing: 10) {
            Button {
                viewModel.selectSafeWorktreeArtifacts(inactiveOnly: true)
            } label: {
                Label("Select Inactive SAFE (\(cfg.inactiveDaysThreshold)+d)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
            .disabled(safeBytes == 0 || viewModel.isCleaning)

            Button {
                viewModel.selectStrongCandidateWorktreeArtifacts()
            } label: {
                Label("Select Strong cleanup candidates (stale \(cfg.strongCandidateDaysThreshold)+d artifacts)", systemImage: "flame.fill")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.worktreeSummary.strongCandidateWorktreesCount == 0 || viewModel.isCleaning)
            .help("Selects only verified SAFE artifacts inside stale worktrees; never deletes the worktree itself.")

            Button {
                viewModel.selectSafeWorktreeArtifacts(inactiveOnly: false)
            } label: {
                Label("Select All SAFE (\(Formatters.bytes(safeBytes)))", systemImage: "checklist")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(safeBytes == 0 || viewModel.isCleaning)

            if selectedWtBytes > 0 {
                Button("Clear Worktree Selection (\(Formatters.bytes(selectedWtBytes)))") {
                    viewModel.clearWorktreeArtifactSelections()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Filter:", selection: $filterClassification) {
                Text("All Worktrees").tag("ALL")
                Text("Has SAFE Artifacts").tag("SAFE")
                Text("Needs Review").tag("REVIEW")
                Text("Inactive (\(cfg.inactiveDaysThreshold)+d)").tag("STALE")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 175)

            Menu {
                Button("Default: 7d eligible / 14d strong") {
                    viewModel.updateWorktreeInactivityThreshold(inactiveDays: 7, strongDays: 14)
                }
                Button("Conservative: 14d eligible / 30d strong") {
                    viewModel.updateWorktreeInactivityThreshold(inactiveDays: 14, strongDays: 30)
                }
                Button("Aggressive: 3d eligible / 7d strong") {
                    viewModel.updateWorktreeInactivityThreshold(inactiveDays: 3, strongDays: 7)
                }
            } label: {
                Label("Stale Threshold (\(cfg.inactiveDaysThreshold)d / \(cfg.strongCandidateDaysThreshold)d)", systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func statBox(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
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

    private func projectWorktreeGroupCard(
        projectName: String,
        projectPath: String,
        records: [GitWorktreeRecord]
    ) -> some View {
        let groupBytes = records.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let groupSafeBytes = records.reduce(Int64(0)) { $0 + $1.safeRegenerableBytes }
        let groupReviewBytes = records.reduce(Int64(0)) { $0 + $1.reviewRegenerableBytes }
        let groupRetainedBytes = max(0, groupBytes - groupSafeBytes)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(.purple)
                        Text("Repository: \(projectName)")
                            .font(.system(size: 15, weight: .bold))
                        Text("\(records.count) worktree\(records.count == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.14)))
                            .foregroundStyle(.purple)
                    }
                    Text(projectPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("SAFE reclaimable: \(Formatters.bytes(groupSafeBytes)) • Needs Review: \(Formatters.bytes(groupReviewBytes))")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(groupSafeBytes > 0 ? .green : .primary)
                    Text("Total footprint: \(Formatters.bytes(groupBytes)) • Retained after SAFE cleanup: \(Formatters.bytes(groupRetainedBytes))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                ForEach(records) { wt in
                    worktreeRow(wt)
                    if wt.id != records.last?.id {
                        Divider()
                            .padding(.leading, 16)
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

    private func worktreeRow(_ wt: GitWorktreeRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(wt.sourceProjectName) / \(wt.worktreeName)")
                            .font(.system(size: 13, weight: .bold))
                        Text(wt.originKind.shortAgentLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.12)))
                            .foregroundStyle(.purple)

                        HStack(spacing: 4) {
                            Image(systemName: wt.isDetached ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(wt.branchLabel)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(wt.isDetached ? Color.orange.opacity(0.16) : Color.blue.opacity(0.12)))
                        .foregroundStyle(wt.isDetached ? .orange : .blue)

                        activityStateBadge(for: wt)

                        if wt.isLocked {
                            Text("LOCKED")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.18)))
                                .foregroundStyle(.red)
                        }
                    }

                    Text(wt.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        Label(
                            wt.hasUncommittedChanges
                                ? "Dirty working tree: \(wt.modifiedFilesCount) modified, \(wt.stagedFilesCount) staged, \(wt.untrackedFilesCount) untracked"
                                : "Clean working tree (0 uncommitted changes)",
                            systemImage: wt.hasUncommittedChanges ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(wt.hasUncommittedChanges ? .orange : .green)

                        if let commitDate = wt.lastCommitDate {
                            Text("Last commit: \(Formatters.relativeDate(commitDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let actDate = wt.lastActivityDate {
                            Text("Last activity: \(Formatters.relativeDate(actDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Remote: \(wt.remoteBranchStatus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Total footprint: \(Formatters.bytes(wt.physicalBytes))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("SAFE reclaimable: \(Formatters.bytes(wt.safeRegenerableBytes)) • Needs Review: \(Formatters.bytes(wt.reviewRegenerableBytes))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(wt.safeRegenerableBytes > 0 ? .green : .secondary)
                    Text("Retained after SAFE cleanup: \(Formatters.bytes(wt.retainedBytes))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if wt.existsOnDisk {
                    Button {
                        viewModel.inspectPathInFinder(wt.path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal worktree in Finder")
                }
            }

            if !wt.artifactCandidates.isEmpty {
                VStack(spacing: 6) {
                    ForEach(wt.artifactCandidates) { candidate in
                        candidateArtifactRow(candidate)
                    }
                }
                .padding(.leading, 8)
            } else {
                Text("No large regenerable build or dependency artifacts detected inside this worktree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func activityStateBadge(for wt: GitWorktreeRecord) -> some View {
        let (label, color): (String, Color) = {
            switch wt.activityState {
            case .recentlyUsed:
                return ("Active / Recent (\(wt.inactiveDays)d)", .blue)
            case .inactiveEligible:
                return ("Unused \(wt.inactiveDays)d • Eligible for SAFE artifact cleanup", .green)
            case .staleStrongCandidate:
                return ("Unused \(wt.inactiveDays)d • Strong cleanup candidate (artifacts)", .orange)
            }
        }()

        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func candidateArtifactRow(_ candidate: WorktreeArtifactCandidate) -> some View {
        let isSelected = viewModel.selectedIDs.contains(candidate.id)
        let isSelectable = candidate.cleanableItem.canBeSelected
        let gitStateColor: Color = {
            switch candidate.gitTrackingState {
            case .ignored: return .green
            case .untracked: return .orange
            case .tracked: return .red
            }
        }()

        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in viewModel.toggleSelection(for: candidate.cleanableItem) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isSelectable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(candidate.projectAndWorktreeDisplay)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(candidate.artifactAndSizeDisplay)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))

                    Text(candidate.artifactType.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)

                    Text(candidate.gitTrackingState.rawValue)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(gitStateColor.opacity(0.14)))
                        .foregroundStyle(gitStateColor)

                    RiskBadgeView(risk: candidate.classification)
                }

                Text(candidate.classificationReason)
                    .font(.caption)
                    .foregroundStyle(candidate.classification == .safe ? Color.primary.opacity(0.85) : Color.orange)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    viewModel.inspectPathInFinder(candidate.fullPath)
                } label: {
                    Label("Inspect", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if candidate.classification == .safe && isSelectable {
                    Button {
                        viewModel.itemForSingleClean = candidate.cleanableItem
                    } label: {
                        Label("Clean", systemImage: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(viewModel.isCleaning)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(candidate.classification == .safe ? Color.green.opacity(0.22) : Color.orange.opacity(0.22), lineWidth: 1)
        )
    }
}
