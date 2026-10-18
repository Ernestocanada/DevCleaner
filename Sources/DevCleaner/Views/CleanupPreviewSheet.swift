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

    private var totalRecovery: Int64 {
        itemsToPreview.reduce(0) { $0 + $1.reclaimableSize }
    }

    private func bytesForRisk(_ risk: RiskLevel) -> Int64 {
        itemsToPreview.filter { $0.riskLevel == risk }.reduce(0) { $0 + $1.reclaimableSize }
    }

    private var safeOnlyItems: [CleanableItem] {
        itemsToPreview.filter { $0.riskLevel == .safe }
    }

    private var hasCautionItems: Bool {
        itemsToPreview.contains { $0.riskLevel == .caution }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.title)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup Preview & Safety Confirmation")
                        .font(.title3.bold())
                    Text("Selected items: \(itemsToPreview.count)  •  Estimated recovery: \(Formatters.bytes(totalRecovery))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Risk breakdown summary bar
            HStack(spacing: 16) {
                riskSummaryCard(risk: .safe, bytes: bytesForRisk(.safe))
                riskSummaryCard(risk: .review, bytes: bytesForRisk(.review))
                riskSummaryCard(risk: .caution, bytes: bytesForRisk(.caution))
            }

            Text("Affected paths and actions:")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            List(itemsToPreview) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        RiskBadgeView(risk: item.riskLevel)
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Formatters.bytes(item.reclaimableSize))
                            .font(.subheadline.monospacedDigit().bold())
                    }
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text("Impact: \(item.regenerationImpact)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if hasCautionItems {
                Toggle(isOn: $cautionConfirmed) {
                    Label("I understand that CAUTION items (such as Docker volumes) may permanently delete container volume data.", systemImage: "exclamationmark.triangle.fill")
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

                Button("Clean Selected (\(Formatters.bytes(totalRecovery)))") {
                    let targets = itemsToPreview
                    dismiss()
                    Task {
                        await viewModel.executeCleanup(for: targets)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(hasCautionItems ? .red : .accentColor)
                .disabled(itemsToPreview.isEmpty || (hasCautionItems && !cautionConfirmed))
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
    }

    private func riskSummaryCard(risk: RiskLevel, bytes: Int64) -> some View {
        HStack {
            RiskBadgeView(risk: risk)
            Spacer()
            Text(Formatters.bytes(bytes))
                .font(.headline.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
