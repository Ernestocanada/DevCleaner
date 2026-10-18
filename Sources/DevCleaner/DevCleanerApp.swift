import SwiftUI
import AppKit

@main
public struct DevCleanerApp: App {
    @StateObject private var viewModel = CleanerViewModel()

    public init() {
        let args = CommandLine.arguments
        if args.contains("--generate-icons") {
            let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            do {
                try AppIconBranding.exportIconAssets(projectRoot: rootURL)
                print("Generated DevCleaner icon assets in \(rootURL.path)/Sources/DevCleaner/Resources")
                exit(0)
            } catch {
                fputs("Failed to generate icon assets: \(error)\n", stderr)
                exit(1)
            }
        }
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
                .frame(minWidth: 980, minHeight: 700)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.applicationIconImage = AppIconBranding.makeAppIconImage(pixelSize: 512)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentMinSize)
    }

    private static func runHeadlessReadOnlyReport() async {
        let vm = await MainActor.run { CleanerViewModel() }
        await vm.performScan()
        let recommendedAllAges = await MainActor.run { vm.selectedReclaimableBytes }
        let safeAllAges = await MainActor.run { vm.potentialBytes(for: .safe) }
        let reviewAllAges = await MainActor.run { vm.potentialBytes(for: .review) }
        let cautionAllAges = await MainActor.run { vm.potentialBytes(for: .caution) }
        let totalAllAges = await MainActor.run { vm.totalReclaimableBytes }
        let macOSAvailable = await MainActor.run { vm.macOSAvailableBytes }
        let physicalFree = await MainActor.run { vm.physicalFreeBytes }
        let allItems = await MainActor.run { vm.items }

        // Also compute 7-day Development Cleanup read-only estimate
        await MainActor.run { vm.ageFilter = .sevenDays }
        await vm.performScan()
        await MainActor.run { vm.selectRecommendedSafeItems() }
        let recommendedSevenDays = await MainActor.run { vm.selectedReclaimableBytes }

        print("=================================================================")
        print("DevCleaner Read-Only Scan Report (v1.4 Storage & Branding)")
        print("macOS Available:                   \(Formatters.bytes(macOSAvailable))")
        print("Physical Free:                     \(Formatters.bytes(physicalFree))")
        print("Potential Cleanup (All Ages):      \(Formatters.bytes(totalAllAges))")
        print("  - SAFE potential:                \(Formatters.bytes(safeAllAges))")
        print("  - REVIEW potential:              \(Formatters.bytes(reviewAllAges))")
        print("  - CAUTION potential:             \(Formatters.bytes(cautionAllAges))")
        print("Recommended Cleanup (SAFE, All):   \(Formatters.bytes(recommendedAllAges))")
        print("Development Cleanup (SAFE, >7d):   \(Formatters.bytes(recommendedSevenDays))")
        print("=================================================================")
        for cat in CleanerCategory.allCases {
            let catItems = allItems.filter { $0.category == cat }
            guard !catItems.isEmpty else { continue }
            let phys = catItems.reduce(0) { $0 + $1.physicalSize }
            let rec = catItems.filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
            print("\n[\(cat.rawValue)] — Disk Usage: \(Formatters.bytes(phys)) | Potential Cleanup: \(Formatters.bytes(rec))")
            for item in catItems {
                let sparseNote = item.hasSparseDifference ? " (Logical sparse: \(Formatters.bytes(item.logicalSize)))" : ""
                let activeNote = item.isRunningDependency ? " [ACTIVE PROCESS: \(item.runningProcessNames.joined(separator: ", "))]" : ""
                print("  • [\(item.riskLevel.rawValue)] \(item.name): \(Formatters.bytes(item.physicalSize))\(sparseNote) -> Potential: \(Formatters.bytes(item.reclaimableSize))\(activeNote)")
                print("      Target: \(item.exactCommandOrPathDescription)")
                if item.id.contains("-review-") {
                    print("      Reason: \(item.explanation)")
                }
            }
        }
        print("\n=================================================================")
    }
}
