import SwiftUI

public struct WorktreeAnalyzerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var searchText: String = ""

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    private var filteredRecords: [GitWorktreeRecord] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return viewModel.worktreeRecords
        }
        let q = searchText.lowercased()
        return viewModel.worktreeRecords.filter {
            $0.sourceProjectName.lowercased().contains(q) ||
            $0.path.lowercased().contains(q) ||
            $0.branchLabel.lowercased().contains(q) ||
            $0.originKind.rawValue.lowercased().contains(q)
        }
    }

    private var groupedByProject: [(projectName: String, projectPath: String, records: [GitWorktreeRecord])] {
        let grouped = Dictionary(grouping: filteredRecords, by: { $0.sourceProjectPath })
        return grouped.map { key, recs in
            (recs.first?.sourceProjectName ?? key, key, recs.sorted { $0.physicalBytes > $1.physicalBytes })
        }.sorted { lhs, rhs in
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

            if viewModel.isScanningWorktrees && viewModel.worktreeRecords.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Inspecting Git & Claude worktrees via `git worktree list --porcelain`...")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if filteredRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Git or Claude worktrees found")
                        .font(.headline)
                    Text("All inspected repositories only have their main working tree.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
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
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Git & Claude Worktree Analyzer — Read-Only Informative Mode")
                    .font(.subheadline.bold())
                Text("Inspected using official `git worktree list --porcelain` and `git status --porcelain --branch`. Automatic deletion (`git worktree remove/prune`, `git clean`, `git reset`) is strictly disabled to protect uncommitted changes, untracked files, detached HEAD commits, and branch work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Filter worktrees by project, branch, or path...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.06))
    }

    private var summaryRow: some View {
        let all = viewModel.worktreeRecords
        let totalBytes = all.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let claudeBytes = all.filter { $0.originKind == .claudeWorktree }.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let codexBytes = all.filter { $0.originKind == .codexWorktree }.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let dirtyCount = all.filter { $0.hasUncommittedChanges }.count
        let detachedOrLockedCount = all.filter { $0.isDetached || $0.isLocked }.count
        let prunableCount = all.filter { $0.isPrunable || !$0.existsOnDisk }.count

        return HStack(spacing: 12) {
            statBox(
                title: "Total Worktrees Storage",
                value: Formatters.bytes(totalBytes),
                subtitle: "\(all.count) linked worktrees across \(groupedByProject.count) repos",
                color: .primary
            )
            statBox(
                title: "Claude Worktrees (.claude)",
                value: Formatters.bytes(claudeBytes),
                subtitle: "\(all.filter { $0.originKind == .claudeWorktree }.count) worktrees in .claude/worktrees",
                color: .purple
            )
            statBox(
                title: "Codex Worktrees (~/.codex)",
                value: Formatters.bytes(codexBytes),
                subtitle: "\(all.filter { $0.originKind == .codexWorktree }.count) worktrees in ~/.codex/worktrees",
                color: .indigo
            )
            statBox(
                title: "Uncommitted / Dirty",
                value: "\(dirtyCount) worktrees",
                subtitle: "Modified, staged, or untracked files",
                color: dirtyCount > 0 ? .red : .green
            )
            statBox(
                title: "Detached / Locked / Prunable",
                value: "\(detachedOrLockedCount) / \(prunableCount)",
                subtitle: "Detached or locked: \(detachedOrLockedCount) • Prunable: \(prunableCount)",
                color: .orange
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
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

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(.purple)
                        Text("Original Project: \(projectName)")
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
                Text("Total Worktrees Size: \(Formatters.bytes(groupBytes))")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
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
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: wt.path).lastPathComponent)
                        .font(.system(size: 13, weight: .bold))
                    Text(wt.originKind.rawValue)
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

                    RiskBadgeView(risk: wt.workLossRisk)

                    if wt.isLocked {
                        Text("LOCKED")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.18)))
                            .foregroundStyle(.red)
                    }
                    if wt.isPrunable || !wt.existsOnDisk {
                        Text(wt.existsOnDisk ? "PRUNABLE" : "MISSING ON DISK (PRUNABLE)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(wt.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    Label(
                        wt.hasUncommittedChanges
                            ? "Local changes: \(wt.modifiedFilesCount) modified, \(wt.stagedFilesCount) staged, \(wt.untrackedFilesCount) untracked"
                            : "Working tree clean (0 uncommitted changes)",
                        systemImage: wt.hasUncommittedChanges ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(wt.hasUncommittedChanges ? .red : .green)

                    Text("Remote: \(wt.remoteBranchStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !wt.sampleChangedFiles.isEmpty {
                    Text("Modified/Untracked sample: \(wt.sampleChangedFiles.joined(separator: ", "))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(wt.riskExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.bytes(wt.physicalBytes))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                if wt.nodeModulesBytes > 0 || wt.buildAndCacheBytes > 0 {
                    HStack(spacing: 6) {
                        if wt.nodeModulesBytes > 0 {
                            Text("node_modules: \(Formatters.bytes(wt.nodeModulesBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if wt.buildAndCacheBytes > 0 {
                            Text("build/cache: \(Formatters.bytes(wt.buildAndCacheBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Informative Only (Protected)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let lastMod = wt.lastModifiedDate {
                    Text("Last activity: \(Formatters.relativeDate(lastMod))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 190, alignment: .trailing)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
