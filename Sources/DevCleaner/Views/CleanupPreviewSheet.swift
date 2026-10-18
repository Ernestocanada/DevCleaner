import SwiftUI

public struct CleanupPreviewSheet: View {
    @ObservedObject var viewModel: CleanerViewModel
    let itemsToPreview: [CleanableItem]
    @Environment(\.dismiss) private var dismiss
    @State private var cautionConfirmed: Bool = false

    public init(viewModel: CleanerViewModel, itemsToPreview: [CleanableItem]) {
        self.viewModel = viewModel
        self.itemsToPreview = itemsToPreview
    }

    private var totalProcessing: Int64 {
        itemsToPreview.reduce(0) { $0 + $1.reclaimableSize }
    }

    private func bytesForRisk(_ risk: RiskLevel) -> Int64 {
        itemsToPreview.filter { $0.riskLevel == risk }.reduce(0) { $0 + $1.reclaimableSize }
    }

    private var tooRecentPreservedBytes: Int64 {
        itemsToPreview.compactMap { $0.plan?.tooRecentBytes }.reduce(0, +)
    }

    private var protectedSkippedItemsInScope: [CleanableItem] {
        let previewCategories = Set(itemsToPreview.map { $0.category })
        return viewModel.items.filter { item in
            previewCategories.contains(item.category) &&
            item.id.contains("-review-") &&
            item.riskLevel == .review
        }
    }

    private var protectedSkippedBytes: Int64 {
        protectedSkippedItemsInScope.reduce(0) { $0 + $1.physicalSize }
    }

    private var safeOnlyItems: [CleanableItem] {
        itemsToPreview.filter { $0.riskLevel == .safe && $0.reclaimableSize > 0 }
    }

    private var hasCautionItems: Bool {
        itemsToPreview.contains { $0.riskLevel == .caution }
    }

    private var hasTrashItems: Bool {
        itemsToPreview.contains { $0.actionKind == .moveToTrash }
    }

    private var trashCount: Int {
        itemsToPreview.filter { $0.actionKind == .moveToTrash }.count
    }

    private var simctlCount: Int {
        itemsToPreview.filter { $0.actionKind == .simctlDelete }.count
    }

    private var dockerCount: Int {
        itemsToPreview.filter { $0.actionKind == .dockerPrune }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.title)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLEANUP PREVIEW")
                        .font(.title3.bold())
                    Text("\(itemsToPreview.count) selected items  •  Potential processing: \(Formatters.bytes(totalProcessing))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                planStatusCard(title: "ELIGIBLE SAFE", bytes: bytesForRisk(.safe), color: .green)
                if bytesForRisk(.review) > 0 || bytesForRisk(.caution) > 0 {
                    planStatusCard(title: "ELIGIBLE REVIEW/CAUTION", bytes: bytesForRisk(.review) + bytesForRisk(.caution), color: .orange)
                }
                planStatusCard(title: "REVIEW / BLOCKED (Skipped)", bytes: protectedSkippedBytes, color: .orange)
                planStatusCard(title: "TOO RECENT (Preserved)", bytes: tooRecentPreservedBytes, color: .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if trashCount > 0 {
                        actionPill(label: "Move to Trash: \(trashCount)", icon: "trash", color: .blue)
                    }
                    if simctlCount > 0 {
                        actionPill(label: "simctl delete: \(simctlCount)", icon: "iphone.slash", color: .purple)
                    }
                    if dockerCount > 0 {
                        actionPill(label: "Docker prune: \(dockerCount)", icon: "server.rack", color: .orange)
                    }
                }

                if hasTrashItems {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("These files will be moved to macOS Trash. Disk space may not be fully recovered until Trash is emptied.")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)

            Text("Planned actions and eligibility breakdown:")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            List {
                Section("ELIGIBLE FOR EXECUTION (\(Formatters.bytes(totalProcessing)))") {
                    ForEach(itemsToPreview) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                RiskBadgeView(risk: item.riskLevel)
                                Text("ELIGIBLE")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundColor(.green)
                                    .cornerRadius(4)
                                Text(item.actionKind.rawValue)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Formatters.bytes(item.reclaimableSize))
                                    .font(.subheadline.monospacedDigit().bold())
                            }
                            Text(item.exactCommandOrPathDescription)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            if let plan = item.plan {
                                Text("Planned eligible entries: \(plan.eligibleEntries.count) (\(Formatters.bytes(plan.eligibleBytes)))" + (plan.tooRecentEntries.isEmpty ? "" : " • Preserved too recent: \(plan.tooRecentEntries.count) (\(Formatters.bytes(plan.tooRecentBytes)))"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Impact: \(item.regenerationImpact)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !protectedSkippedItemsInScope.isEmpty {
                    Section("REVIEW / BLOCKED — Skipped Automatically (\(Formatters.bytes(protectedSkippedBytes)))") {
                        ForEach(protectedSkippedItemsInScope) { skipped in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    RiskBadgeView(risk: .review)
                                    Text("SKIPPED")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.16))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                    Text(skipped.name)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(Formatters.bytes(skipped.physicalSize))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Text(skipped.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(skipped.explanation)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .frame(minHeight: 230)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if hasCautionItems {
                Toggle(isOn: $cautionConfirmed) {
                    Label("I confirm executing CAUTION actions (such as Docker volume prune), which may permanently delete container volume data.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.callout.bold())
                }
                .toggleStyle(.checkbox)
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !safeOnlyItems.isEmpty && safeOnlyItems.count < itemsToPreview.count {
                    Button("Clean Safe Items (\(Formatters.bytes(bytesForRisk(.safe))))") {
                        let targets = safeOnlyItems
                        dismiss()
                        Task {
                            await viewModel.executeCleanup(for: targets)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Button("Clean Selected (\(Formatters.bytes(totalProcessing)))") {
                    let targets = itemsToPreview
                    dismiss()
                    Task {
                        await viewModel.executeCleanup(for: targets)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(hasCautionItems ? .red : .accentColor)
                .disabled(itemsToPreview.isEmpty || totalProcessing == 0 || (hasCautionItems && !cautionConfirmed))
            }
        }
        .padding(20)
        .frame(width: 740, height: 580)
    }

    private func planStatusCard(title: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(Formatters.bytes(bytes))
                .font(.headline.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func actionPill(label: String, icon: String, color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}
