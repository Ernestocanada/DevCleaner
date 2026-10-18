import SwiftUI

public struct CleanupHistorySheet: View {
    @ObservedObject var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Local Cleanup History", systemImage: "clock.arrow.circlepath")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if viewModel.historyEntries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No cleanup actions recorded yet.")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("All scan operations are strictly read-only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(viewModel.historyEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(entry.success ? .green : .orange)
                            Text(entry.itemName)
                                .font(.subheadline.bold())
                            Text("(\(entry.category))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(Formatters.bytes(entry.bytesReclaimed))
                                .font(.subheadline.monospacedDigit().bold())
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("\(entry.actionDescription) — \(entry.path)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        if let msg = entry.message, !msg.isEmpty {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(entry.success ? .secondary : .orange)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 440)
    }
}

public struct SimulatorRuntimesSheet: View {
    @ObservedObject var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var runtimeToConfirmDelete: SimulatorRuntimeInfo? = nil

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulator Runtime Manager (Advanced)")
                        .font(.title3.bold())
                    Text("Mounted runtime images in /Library/Developer/CoreSimulator/Volumes. iOS 26.3 & iOS 27.0 are preserved by default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.orange)
                Text("STRONG WARNING: Deleting an iOS Simulator Runtime requires re-downloading 8–15 GB from Apple if you need to run simulators on that iOS version again. Never delete runtime folders manually in Finder.")
                    .font(.caption)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)

            List(viewModel.simulatorRuntimes) { rt in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(rt.name)
                                .font(.headline)
                            if rt.isPreservedByDefault {
                                Text("PRESERVED BY DEFAULT")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        }
                        Text("Identifier: \(rt.id) • Build \(rt.build)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        runtimeToConfirmDelete = rt
                    } label: {
                        Text("Delete via simctl...")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 640, height: 380)
        .alert(
            "Delete Simulator Runtime?",
            isPresented: Binding(
                get: { runtimeToConfirmDelete != nil },
                set: { if !$0 { runtimeToConfirmDelete = nil } }
            ),
            presenting: runtimeToConfirmDelete
        ) { rt in
            Button("Cancel", role: .cancel) { runtimeToConfirmDelete = nil }
            Button("Delete \(rt.name)", role: .destructive) {
                runtimeToConfirmDelete = nil
                Task {
                    await viewModel.deleteSimulatorRuntime(rt)
                }
            }
        } message: { rt in
            Text("Are you sure you want to run 'xcrun simctl runtime delete \(rt.id)'? You will have to re-download \(rt.name) in Xcode to use it again.")
        }
    }
}
