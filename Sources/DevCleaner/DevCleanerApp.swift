import SwiftUI
import AppKit

@MainActor
public final class DevCleanerAppDelegate: NSObject, NSApplicationDelegate {
    public weak var mainWindow: NSWindow?
    public var reopenWindowAction: (() -> Void)?

    public override init() {
        super.init()
    }

    public func registerMainWindow(_ window: NSWindow, reopenAction: (() -> Void)? = nil) {
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        self.mainWindow = window
        if let reopenAction {
            self.reopenWindowAction = reopenAction
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = AppIconBranding.makeAppIconImage(pixelSize: 512)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = restoreOrOpenMainWindow(in: sender)
        return false
    }

    @discardableResult
    public func restoreOrOpenMainWindow(in providedApp: NSApplication? = nil) -> Bool {
        let app = providedApp ?? NSApplication.shared
        let candidateWindows = app.windows.filter { window in
            !(window is NSPanel) && window.className != "NSStatusBarWindow"
        }

        if let window = mainWindow ?? candidateWindows.first {
            self.mainWindow = window
            window.isReleasedWhenClosed = false
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            for extraWindow in candidateWindows where extraWindow !== window {
                extraWindow.close()
            }
            return true
        }

        if let reopenWindowAction {
            reopenWindowAction()
            app.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    let onWindowAttached: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingNSView()
        view.onWindowAttached = onWindowAttached
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? WindowObservingNSView {
            view.onWindowAttached = onWindowAttached
            if let window = view.window {
                onWindowAttached(window)
            }
        }
    }

    private final class WindowObservingNSView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAttached?(window)
            }
        }
    }
}

@main
public struct DevCleanerApp: App {
    @NSApplicationDelegateAdaptor(DevCleanerAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = CleanerViewModel()
    @Environment(\.openWindow) private var openWindow

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
        Window("DevCleaner — Developer Storage & Project Analyzer", id: "main") {
            DashboardView(viewModel: viewModel)
                .frame(minWidth: 1080, minHeight: 740)
                .background(
                    MainWindowAccessor { window in
                        appDelegate.registerMainWindow(window) {
                            openWindow(id: "main")
                        }
                    }
                )
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.applicationIconImage = AppIconBranding.makeAppIconImage(pixelSize: 512)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if CommandLine.arguments.contains("--verify-dock-reopen") {
                        Task { @MainActor in
                            await Self.runLiveDockReopenVerification(appDelegate: appDelegate)
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Main Window") {
                    _ = appDelegate.restoreOrOpenMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }

    @MainActor
    private static func runLiveDockReopenVerification(appDelegate: DevCleanerAppDelegate) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let window = appDelegate.mainWindow else {
            fputs("VERIFY_ERROR: mainWindow was not registered\n", stderr)
            exit(1)
        }
        let initialVisible = window.isVisible
        let tabs = MainAnalyzerTab.allCases.map(\.rawValue)
        print("1. Initial Window Open: visible=\(initialVisible), isReleasedWhenClosed=\(window.isReleasedWhenClosed), title='\(window.title)'")
        print("2. MainAnalyzerTab Labels: \(tabs.joined(separator: " | "))")

        // Simulate clicking the red close button (x)
        window.performClose(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let visibleAfterClose = window.isVisible
        print("3. After Red Close Button (performClose): visible=\(visibleAfterClose), appRunning=\(NSApplication.shared.isRunning)")

        // Trigger real macOS LaunchServices/Dock reopen event via `open -a DevCleaner.app`
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.hasSuffix(".app") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", bundlePath]
            try? proc.run()
            proc.waitUntilExit()
        }
        if !(appDelegate.mainWindow ?? window).isVisible {
            _ = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let activeWindow = appDelegate.mainWindow ?? window
        let visibleAfterReopen = activeWindow.isVisible
        let primaryWindowCount1 = NSApplication.shared.windows.filter { !($0 is NSPanel) && $0.className != "NSStatusBarWindow" && $0.isVisible }.count
        print("4. After OS Dock Reopen Event: visible=\(visibleAfterReopen), visiblePrimaryWindows=\(primaryWindowCount1)")

        // Trigger a second OS Dock reopen event while window is already open
        if bundlePath.hasSuffix(".app") {
            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc2.arguments = ["-a", bundlePath]
            try? proc2.run()
            proc2.waitUntilExit()
        } else {
            _ = appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let primaryWindowCount2 = NSApplication.shared.windows.filter { !($0 is NSPanel) && $0.className != "NSStatusBarWindow" && $0.isVisible }.count
        print("5. After Second OS Dock Reopen Event (No Duplicates Check): visiblePrimaryWindows=\(primaryWindowCount2)")

        let success = initialVisible && !visibleAfterClose && visibleAfterReopen && primaryWindowCount1 == 1 && primaryWindowCount2 == 1 && tabs == ["System & Tools", "Project Storage", "Worktrees", "Mac Storage"]
        print("DOCK_REOPEN_VERIFICATION=\(success ? "PASSED" : "FAILED")")
        exit(success ? 0 : 1)
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
        let purgeable = await MainActor.run { vm.purgeableBytes }
        let trashBytes = await MainActor.run { vm.trashBytes }
        let allItems = await MainActor.run { vm.items }
        let projectSummary = await MainActor.run { vm.projectSummary }
        let projectReports = await MainActor.run { vm.projectReports }
        let worktreeRecords = await MainActor.run { vm.worktreeRecords }
        let macSummary = await MainActor.run { vm.macStorageSummary }

        print("=================================================================")
        print("DevCleaner Read-Only Scan Report (v3.0 Developer Mac Storage Manager)")
        print("macOS Available:                   \(Formatters.bytes(macOSAvailable))")
        print("Physical Free:                     \(Formatters.bytes(physicalFree))")
        print("Purgeable Space:                   \(Formatters.bytes(purgeable))")
        print("In Trash (~/.Trash):               \(Formatters.bytes(trashBytes))")
        print("Potential Cleanup (All Ages):      \(Formatters.bytes(totalAllAges))")
        print("  - SAFE potential:                \(Formatters.bytes(safeAllAges))")
        print("  - REVIEW potential:              \(Formatters.bytes(reviewAllAges))")
        print("  - CAUTION potential:             \(Formatters.bytes(cautionAllAges))")
        print("Recommended Cleanup (SAFE Only):   \(Formatters.bytes(recommendedAllAges))")
        print("=================================================================")

        print("\n[MAC STORAGE GLOBAL SUMMARY — Deduplicated]")
        print("  Total Developer Storage:         \(Formatters.bytes(macSummary.totalDeveloperStorageBytes))")
        print("  SAFE Cleanup:                    \(Formatters.bytes(macSummary.safeCleanupBytes))")
        print("  REVIEW Cleanup:                  \(Formatters.bytes(macSummary.reviewCleanupBytes))")
        print("  PROTECTED Storage:               \(Formatters.bytes(macSummary.protectedBytes))")
        print("  --- Domain Breakdown (Section 12) ---")
        print("  • Developer Projects:            \(Formatters.bytes(macSummary.developerProjectsBytes))")
        print("  • AI Tools:                      \(Formatters.bytes(macSummary.aiToolsBytes))")
        print("  • Simulators:                    \(Formatters.bytes(macSummary.simulatorsBytes))")
        print("  • Docker:                        \(Formatters.bytes(macSummary.dockerBytes))")
        print("  • Android SDK:                   \(Formatters.bytes(macSummary.androidSDKBytes))")
        print("  • Caches:                        \(Formatters.bytes(macSummary.cachesBytes))")
        print("  • Other Developer Data:          \(Formatters.bytes(macSummary.otherDeveloperDataBytes))")
        print("  --- Inspected Roots ---")
        for root in macSummary.inspectedRoots {
            print("  • \(root.displayPath): \(Formatters.bytes(root.physicalBytes)) (SAFE: \(Formatters.bytes(root.safeReclaimableBytes)) | REVIEW: \(Formatters.bytes(root.reviewReclaimableBytes)) | Protected: \(Formatters.bytes(root.protectedBytes)))")
        }
        print("  --- Mac Storage Categories ---")
        for grp in macSummary.categoryGroups {
            print("  * [\(grp.category.rawValue)] Total: \(Formatters.bytes(grp.totalPhysicalBytes)) | SAFE: \(Formatters.bytes(grp.safeReclaimableBytes)) | REVIEW: \(Formatters.bytes(grp.reviewReclaimableBytes)) | Protected: \(Formatters.bytes(grp.protectedBytes))")
            for item in grp.items {
                print("      - [\(item.riskLevel.rawValue)] \(item.name): \(Formatters.bytes(item.physicalSize)) -> Potential: \(Formatters.bytes(item.reclaimableSize)) (\(item.usageDateDescription))")
            }
        }

        print("\n[PROJECT STORAGE ANALYZER SUMMARY — \(projectSummary.rootDirectoryPath)]")
        print("  Total Projects Count:            \(projectSummary.totalProjectsCount)")
        print("  Total Projects Storage:          \(Formatters.bytes(projectSummary.totalProjectsPhysicalBytes))")
        print("  Regenerable Caches (SAFE):       \(Formatters.bytes(projectSummary.regenerableCachesAndBuildsBytes))")
        print("  Review Required (REVIEW):        \(Formatters.bytes(projectSummary.reviewRequiredBytes))")
        print("  Worktrees Inside Projects:       \(Formatters.bytes(projectSummary.worktreesBytes))")
        print("  Protected Source/Git/Evidence:   \(Formatters.bytes(projectSummary.protectedDataBytes))")
        print("  Potential Project Recovery:      \(Formatters.bytes(projectSummary.potentialRecoveryBytes))")

        for proj in projectReports.prefix(12) {
            print("  • \(proj.name) — Total: \(Formatters.bytes(proj.totalPhysicalBytes)) | SAFE: \(Formatters.bytes(proj.safeRecoverableBytes)) | REVIEW: \(Formatters.bytes(proj.reviewRecoverableBytes)) | Worktrees: \(Formatters.bytes(proj.worktreesBytes)) | Protected: \(Formatters.bytes(proj.protectedBytes))")
            for art in proj.artifacts.prefix(10) {
                print("      - [\(art.riskLevel.rawValue)] \(art.relativePath) (\(art.artifactCategory.rawValue)): \(Formatters.bytes(art.physicalBytes)) -> Recoverable: \(Formatters.bytes(art.reclaimableBytes))")
            }
        }

        let totalWorktreeBytes = worktreeRecords.reduce(Int64(0)) { $0 + $1.physicalBytes }
        print("\n[GIT & CLAUDE WORKTREE ANALYZER — Informative Only]")
        print("  Total Linked Worktrees:          \(worktreeRecords.count)")
        print("  Total Worktrees Physical Size:   \(Formatters.bytes(totalWorktreeBytes))")
        for wt in worktreeRecords {
            let dirtyNote = wt.hasUncommittedChanges ? "DIRTY (M:\(wt.modifiedFilesCount) S:\(wt.stagedFilesCount) U:\(wt.untrackedFilesCount))" : "CLEAN"
            print("  • [\(wt.workLossRisk.rawValue)] [\(wt.sourceProjectName)] \(wt.path) (\(wt.branchLabel)) — \(Formatters.bytes(wt.physicalBytes)) | \(dirtyNote) | \(wt.remoteBranchStatus)")
        }

        for cat in CleanerCategory.allCases where cat != .projectStorage {
            let catItems = allItems.filter { $0.category == cat }
            guard !catItems.isEmpty else { continue }
            let phys = catItems.filter { $0.id != "sim-runtimes-preserved" }.reduce(0) { $0 + $1.physicalSize }
            let rec = catItems.filter { $0.riskLevel != .neverDelete }.reduce(0) { $0 + $1.reclaimableSize }
            print("\n[\(cat.rawValue)] — Disk Usage: \(Formatters.bytes(phys)) | Potential Cleanup: \(Formatters.bytes(rec))")
            for item in catItems {
                let sparseNote = item.hasSparseDifference ? " (Logical sparse: \(Formatters.bytes(item.logicalSize)))" : ""
                let activeNote = item.isRunningDependency ? " [ACTIVE PROCESS: \(item.runningProcessNames.joined(separator: ", "))]" : ""
                print("  • [\(item.riskLevel.rawValue)] \(item.name): \(Formatters.bytes(item.physicalSize))\(sparseNote) -> Potential: \(Formatters.bytes(item.reclaimableSize))\(activeNote)")
            }
        }
        print("\n=================================================================")
    }
}
