import SwiftUI
import AppKit

@main
public struct DevCleanerApp: App {
    @StateObject private var viewModel = CleanerViewModel()

    public init() {
        // Support "--cli-report" flag to run a headless read-only scan and print the report to stdout
        let args = CommandLine.arguments
        if args.contains("--cli-report") {
            Task {
                await Self.runHeadlessReadOnlyReport()
                exit(0)
            }
            RunLoop.main.run()
        }
    }

    public var body: some Scene {
        WindowGroup("DevCleaner — Developer Storage Cleaner") {
            DashboardView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentMinSize)
    }

    private static func runHeadlessReadOnlyReport() async {
        let vm = await MainActor.run { CleanerViewModel() }
        await vm.performScan()
        await MainActor.run {
            print("=================================================================")
            print("DevCleaner Read-Only Scan Report")
            print("Free Disk Space:       \(Formatters.bytes(vm.freeSpaceBytes))")
            print("Potential Reclaimable: \(Formatters.bytes(vm.totalReclaimableBytes))")
            print("Recommended (SAFE):    \(Formatters.bytes(vm.selectedReclaimableBytes))")
            print("=================================================================")
            for cat in CleanerCategory.allCases {
                let catItems = vm.items(for: cat)
                guard !catItems.isEmpty else { continue }
                let phys = vm.categoryTotalPhysical(for: cat)
                let rec = vm.categoryReclaimable(for: cat)
                print("\n[\(cat.rawValue)] — Disk Usage: \(Formatters.bytes(phys)) | Reclaimable: \(Formatters.bytes(rec))")
                for item in catItems {
                    let sparseNote = item.hasSparseDifference ? " (Logical sparse: \(Formatters.bytes(item.logicalSize)))" : ""
                    let activeNote = item.isRunningDependency ? " [ACTIVE PROCESS: \(item.runningProcessNames.joined(separator: ", "))]" : ""
                    print("  • [\(item.riskLevel.rawValue)] \(item.name): \(Formatters.bytes(item.physicalSize))\(sparseNote) -> Reclaimable: \(Formatters.bytes(item.reclaimableSize))\(activeNote)")
                    print("      Path: \(item.path)")
                }
            }
            print("\n=================================================================")
        }
    }
}
