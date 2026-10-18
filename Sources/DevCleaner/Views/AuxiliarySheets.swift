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
                Button {
                    viewModel.openTrashInFinder()
                } label: {
                    Label("Open Trash in Finder", systemImage: "trash")
                }
                .buttonStyle(.bordered)

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
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(entry.success ? .green : .orange)
                            Text(entry.itemName)
                                .font(.subheadline.bold())
                            Text("(\(entry.category))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 16) {
                            Text("Action: \(entry.actionDescription)")
                                .font(.caption.weight(.semibold))
                            Text("Processed: \(Formatters.bytes(entry.processedBytes))")
                                .font(.caption.monospacedDigit())
                            Text("Moved to Trash: \(Formatters.bytes(entry.movedToTrashBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.blue)
                            Text("Disk Freed Delta: \(Formatters.bytes(entry.actuallyFreedBytes))")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundColor(.green)
                        }

                        Text(entry.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        if let msg = entry.message, !msg.isEmpty {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(entry.success ? .secondary : .orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(width: 740, height: 480)
    }
}

public struct SimulatorRuntimesSheet: View {
    @ObservedObject var viewModel: CleanerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRuntimeID: String? = nil
    @State private var runtimeToConfirmDelete: SimulatorRuntimeInfo? = nil

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    private var selectedRuntime: SimulatorRuntimeInfo? {
        viewModel.simulatorRuntimes.first { $0.id == selectedRuntimeID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Simulator Runtime Manager")
                        .font(.title3.bold())
                    Text("Mounted runtime images in /Library/Developer/CoreSimulator/Volumes. iOS 26.3 & iOS 27.0 are PRESERVED by default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.orange)
                Text("STRONG WARNING: Deleting an iOS Simulator Runtime requires re-downloading 8–15 GB from Apple if you need to run simulators on that iOS version again. Never delete runtime folders manually in Finder. Runtimes are never included in Recommended or Development Cleanup.")
                    .font(.caption)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)

            Text("Step 1: Explicitly select a runtime below:")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            List(viewModel.simulatorRuntimes, selection: $selectedRuntimeID) { rt in
                HStack {
                    Image(systemName: selectedRuntimeID == rt.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedRuntimeID == rt.id ? .accentColor : .secondary)
                        .onTapGesture {
                            selectedRuntimeID = rt.id
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(rt.name)
                                .font(.headline)
                            if rt.isPreservedByDefault {
                                Text("PRESERVED")
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
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRuntimeID = rt.id
                }
                .padding(.vertical, 4)
            }

            HStack {
                if let sel = selectedRuntime {
                    Text("Selected: \(sel.name) (\(sel.id))")
                        .font(.caption.weight(.medium))
                } else {
                    Text("No runtime selected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    if let sel = selectedRuntime {
                        runtimeToConfirmDelete = sel
                    }
                } label: {
                    if let sel = selectedRuntime {
                        Text("Remove \(sel.name) via simctl...")
                    } else {
                        Text("Select a Runtime to Remove...")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedRuntime == nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 420)
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
                selectedRuntimeID = nil
                Task {
                    await viewModel.deleteSimulatorRuntime(rt)
                }
            }
        } message: { rt in
            Text("Confirm destructive removal of runtime '\(rt.name)' via 'xcrun simctl runtime delete \(rt.id)'. You will have to re-download \(rt.name) (8–15 GB) in Xcode if needed again.")
        }
    }
}
