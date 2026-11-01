import Foundation

public enum MacStorageCategory: String, CaseIterable, Identifiable, Sendable {
    case aiTools = "AI Tools"
    case xcodeAndSimulators = "Xcode & Simulators"
    case android = "Android"
    case docker = "Docker"
    case packageManagers = "Package Managers"
    case applicationCaches = "Application Caches"
    case developerTools = "Developer Tools"
    case other = "Other"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .aiTools: return "sparkles.rectangle.stack.fill"
        case .xcodeAndSimulators: return "iphone.gen3"
        case .android: return "cpu.fill"
        case .docker: return "shippingbox.and.arrow.backward.fill"
        case .packageManagers: return "shippingbox.fill"
        case .applicationCaches: return "internaldrive.fill"
        case .developerTools: return "hammer.fill"
        case .other: return "folder.badge.gearshape"
        }
    }

    public var subtitle: String {
        switch self {
        case .aiTools:
            return "Claude, Codex, Google AI models, VM bundles, simulator-builds & verified AI caches"
        case .xcodeAndSimulators:
            return "Xcode DerivedData, DocumentationCache, DeviceSupport, Archives & CoreSimulator devices"
        case .android:
            return "Android SDK, NDK, Emulator System Images, AVD virtual devices & ~/.android/cache"
        case .docker:
            return "Docker Desktop sparse VM disk (Docker.raw) & official CLI prune targets"
        case .packageManagers:
            return "npm, pnpm, Yarn, Corepack, Gradle, CocoaPods, SwiftPM, Homebrew & pip caches"
        case .applicationCaches:
            return "Verified subcaches in ~/Library/Caches, ~/Library/Application Support & ~/Library/Logs"
        case .developerTools:
            return "Puppeteer/Playwright browsers, Firebase emulators, DotSlash, React Native, IDE data & ~/Developer projects"
        case .other:
            return "Protected workspace databases, desktop app partitions & non-deletable developer state"
        }
    }
}

public struct MacStorageRootInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayPath: String
    public let fullPath: String
    public let exists: Bool
    public let physicalBytes: Int64
    public let safeReclaimableBytes: Int64
    public let reviewReclaimableBytes: Int64
    public let protectedBytes: Int64
    public let note: String

    public init(
        id: String,
        displayPath: String,
        fullPath: String,
        exists: Bool,
        physicalBytes: Int64,
        safeReclaimableBytes: Int64,
        reviewReclaimableBytes: Int64,
        protectedBytes: Int64,
        note: String
    ) {
        self.id = id
        self.displayPath = displayPath
        self.fullPath = fullPath
        self.exists = exists
        self.physicalBytes = physicalBytes
        self.safeReclaimableBytes = safeReclaimableBytes
        self.reviewReclaimableBytes = reviewReclaimableBytes
        self.protectedBytes = protectedBytes
        self.note = note
    }
}

public struct MacStorageCategoryGroup: Identifiable, Sendable, Equatable {
    public var id: String { category.rawValue }
    public let category: MacStorageCategory
    public let items: [CleanableItem]
    public let totalPhysicalBytes: Int64
    public let safeReclaimableBytes: Int64
    public let reviewReclaimableBytes: Int64
    public let cautionReclaimableBytes: Int64
    public let protectedBytes: Int64

    public var totalReclaimableBytes: Int64 {
        safeReclaimableBytes + reviewReclaimableBytes + cautionReclaimableBytes
    }

    public init(
        category: MacStorageCategory,
        items: [CleanableItem],
        totalPhysicalBytes: Int64? = nil,
        safeReclaimableBytes: Int64? = nil,
        reviewReclaimableBytes: Int64? = nil,
        cautionReclaimableBytes: Int64? = nil,
        protectedBytes: Int64? = nil
    ) {
        self.category = category
        self.items = items
        let physical = totalPhysicalBytes ?? items.reduce(0) { $0 + $1.physicalSize }
        let safe = safeReclaimableBytes ?? items.filter { $0.riskLevel == .safe }.reduce(0) { $0 + $1.reclaimableSize }
        let review = reviewReclaimableBytes ?? items.filter { $0.riskLevel == .review }.reduce(0) { $0 + $1.reclaimableSize }
        let caution = cautionReclaimableBytes ?? items.filter { $0.riskLevel == .caution }.reduce(0) { $0 + $1.reclaimableSize }
        let reclaimable = safe + review + caution
        self.totalPhysicalBytes = physical
        self.safeReclaimableBytes = safe
        self.reviewReclaimableBytes = review
        self.cautionReclaimableBytes = caution
        self.protectedBytes = protectedBytes ?? max(0, physical - reclaimable)
    }
}

public struct MacStorageSummary: Sendable, Equatable {
    public let totalDeveloperStorageBytes: Int64
    public let safeCleanupBytes: Int64
    public let reviewCleanupBytes: Int64
    public let cautionCleanupBytes: Int64
    public let protectedBytes: Int64

    // High-level mutually exclusive domain breakdown (Section 12)
    public let developerProjectsBytes: Int64
    public let aiToolsBytes: Int64
    public let simulatorsBytes: Int64
    public let dockerBytes: Int64
    public let androidSDKBytes: Int64
    public let cachesBytes: Int64
    public let otherDeveloperDataBytes: Int64

    public let categoryGroups: [MacStorageCategoryGroup]
    public let inspectedRoots: [MacStorageRootInfo]

    public static let empty = MacStorageSummary(
        totalDeveloperStorageBytes: 0,
        safeCleanupBytes: 0,
        reviewCleanupBytes: 0,
        cautionCleanupBytes: 0,
        protectedBytes: 0,
        developerProjectsBytes: 0,
        aiToolsBytes: 0,
        simulatorsBytes: 0,
        dockerBytes: 0,
        androidSDKBytes: 0,
        cachesBytes: 0,
        otherDeveloperDataBytes: 0,
        categoryGroups: [],
        inspectedRoots: []
    )

    public init(
        totalDeveloperStorageBytes: Int64,
        safeCleanupBytes: Int64,
        reviewCleanupBytes: Int64,
        cautionCleanupBytes: Int64,
        protectedBytes: Int64,
        developerProjectsBytes: Int64,
        aiToolsBytes: Int64,
        simulatorsBytes: Int64,
        dockerBytes: Int64,
        androidSDKBytes: Int64,
        cachesBytes: Int64,
        otherDeveloperDataBytes: Int64,
        categoryGroups: [MacStorageCategoryGroup],
        inspectedRoots: [MacStorageRootInfo]
    ) {
        self.totalDeveloperStorageBytes = totalDeveloperStorageBytes
        self.safeCleanupBytes = safeCleanupBytes
        self.reviewCleanupBytes = reviewCleanupBytes
        self.cautionCleanupBytes = cautionCleanupBytes
        self.protectedBytes = protectedBytes
        self.developerProjectsBytes = developerProjectsBytes
        self.aiToolsBytes = aiToolsBytes
        self.simulatorsBytes = simulatorsBytes
        self.dockerBytes = dockerBytes
        self.androidSDKBytes = androidSDKBytes
        self.cachesBytes = cachesBytes
        self.otherDeveloperDataBytes = otherDeveloperDataBytes
        self.categoryGroups = categoryGroups
        self.inspectedRoots = inspectedRoots
    }
}
