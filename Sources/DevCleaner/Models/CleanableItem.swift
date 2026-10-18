import Foundation

public enum RiskLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case safe = "SAFE"
    case review = "REVIEW"
    case caution = "CAUTION"
    case neverDelete = "NEVER DELETE"

    private var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .caution: return 2
        case .neverDelete: return 3
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public enum CleanerCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case xcode = "Xcode"
    case iosSimulators = "iOS Simulators"
    case android = "Android"
    case nodeNpm = "Node / npm"
    case gradle = "Gradle"
    case cocoapodsSwiftPM = "CocoaPods / SwiftPM"
    case homebrew = "Homebrew"
    case docker = "Docker"
    case claude = "Claude"
    case codex = "Codex"
    case googleAI = "Google AI local models"
    case generalCaches = "General developer caches"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .xcode: return "hammer.fill"
        case .iosSimulators: return "iphone"
        case .android: return "cpu"
        case .nodeNpm: return "shippingbox.fill"
        case .gradle: return "gearshape.2.fill"
        case .cocoapodsSwiftPM: return "cube.box.fill"
        case .homebrew: return "mug.fill"
        case .docker: return "server.rack"
        case .claude: return "sparkles"
        case .codex: return "terminal.fill"
        case .googleAI: return "brain.head.profile"
        case .generalCaches: return "folder.fill.badge.gearshape"
        }
    }
}

public enum CleanupActionType: Codable, Equatable, Sendable {
    case moveToTrash(path: String)
    case moveToTrashContents(directoryPath: String, minAgeDays: Int?)
    case simctlDeleteDevice(udid: String)
    case simctlDeleteUnavailable
    case simctlDeleteRuntime(identifier: String)
    case dockerPrune(subcommand: [String])
    case readOnlyInfo(reason: String)
}

public struct SimulatorMetadata: Codable, Equatable, Sendable {
    public let udid: String
    public let runtimeName: String
    public let state: String
    public let isAvailable: Bool
    public let lastUsedAt: Date?

    public init(udid: String, runtimeName: String, state: String, isAvailable: Bool, lastUsedAt: Date?) {
        self.udid = udid
        self.runtimeName = runtimeName
        self.state = state
        self.isAvailable = isAvailable
        self.lastUsedAt = lastUsedAt
    }
}

public struct CleanableItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: CleanerCategory
    public let path: String
    public let logicalSize: Int64
    public let physicalSize: Int64
    public let reclaimableSize: Int64
    public let lastModified: Date?
    public let riskLevel: RiskLevel
    public let explanation: String
    public let deletionConsequence: String
    public let regenerationImpact: String
    public let isRunningDependency: Bool
    public let runningProcessNames: [String]
    public let actionType: CleanupActionType
    public let simulatorMetadata: SimulatorMetadata?
    public let supportsAgeFilter: Bool

    public init(
        id: String,
        name: String,
        category: CleanerCategory,
        path: String,
        logicalSize: Int64,
        physicalSize: Int64,
        reclaimableSize: Int64,
        lastModified: Date?,
        riskLevel: RiskLevel,
        explanation: String,
        deletionConsequence: String,
        regenerationImpact: String,
        isRunningDependency: Bool,
        runningProcessNames: [String] = [],
        actionType: CleanupActionType,
        simulatorMetadata: SimulatorMetadata? = nil,
        supportsAgeFilter: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.path = path
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
        self.reclaimableSize = reclaimableSize
        self.lastModified = lastModified
        self.riskLevel = riskLevel
        self.explanation = explanation
        self.deletionConsequence = deletionConsequence
        self.regenerationImpact = regenerationImpact
        self.isRunningDependency = isRunningDependency
        self.runningProcessNames = runningProcessNames
        self.actionType = actionType
        self.simulatorMetadata = simulatorMetadata
        self.supportsAgeFilter = supportsAgeFilter
    }

    public var canBeSelected: Bool {
        guard riskLevel != .neverDelete else { return false }
        guard !isRunningDependency else { return false }
        if case .readOnlyInfo = actionType { return false }
        return reclaimableSize > 0 || actionType == .simctlDeleteUnavailable
    }

    public var hasSparseDifference: Bool {
        guard logicalSize > 0 && physicalSize > 0 else { return false }
        let diff = abs(logicalSize - physicalSize)
        return Double(diff) / Double(max(logicalSize, physicalSize)) > 0.20 && diff > 100 * 1024 * 1024
    }
}

public enum AgeFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .all: return "All ages"
        case .oneDay: return "Older than 1 day"
        case .sevenDays: return "Older than 7 days"
        case .thirtyDays: return "Older than 30 days"
        }
    }
}

public struct CleanupHistoryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let category: String
    public let itemName: String
    public let path: String
    public let bytesReclaimed: Int64
    public let actionDescription: String
    public let success: Bool
    public let message: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: String,
        itemName: String,
        path: String,
        bytesReclaimed: Int64,
        actionDescription: String,
        success: Bool,
        message: String? = nil
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.itemName = itemName
        self.path = path
        self.bytesReclaimed = bytesReclaimed
        self.actionDescription = actionDescription
        self.success = success
        self.message = message
    }
}

public struct SimulatorRuntimeInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let build: String
    public let isAvailable: Bool
    public let isPreservedByDefault: Bool

    public init(id: String, name: String, version: String, build: String, isAvailable: Bool, isPreservedByDefault: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.build = build
        self.isAvailable = isAvailable
        self.isPreservedByDefault = isPreservedByDefault
    }
}
