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

public enum CleanupResultAction: String, Codable, Equatable, Sendable {
    case moveToTrash = "Move to Trash"
    case simctlDelete = "simctl delete"
    case dockerPrune = "Docker prune"
    case none = "None"
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let processedBytes: Int64
    public let movedToTrashBytes: Int64
    public let actuallyFreedBytes: Int64
    public let action: CleanupResultAction

    public init(
        processedBytes: Int64,
        movedToTrashBytes: Int64,
        actuallyFreedBytes: Int64,
        action: CleanupResultAction
    ) {
        self.processedBytes = processedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.actuallyFreedBytes = actuallyFreedBytes
        self.action = action
    }
}

public struct CleanupBatchSummary: Equatable, Sendable {
    public let date: Date
    public let processedBytes: Int64
    public let movedToTrashBytes: Int64
    public let actuallyFreedBytes: Int64
    public let succeededCount: Int
    public let failedOrBlockedCount: Int
    public let blockedMessages: [String]

    public init(
        date: Date = Date(),
        processedBytes: Int64,
        movedToTrashBytes: Int64,
        actuallyFreedBytes: Int64,
        succeededCount: Int,
        failedOrBlockedCount: Int,
        blockedMessages: [String] = []
    ) {
        self.date = date
        self.processedBytes = processedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.actuallyFreedBytes = actuallyFreedBytes
        self.succeededCount = succeededCount
        self.failedOrBlockedCount = failedOrBlockedCount
        self.blockedMessages = blockedMessages
    }
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

    public var isBooted: Bool {
        state.caseInsensitiveCompare("Shutdown") != .orderedSame
    }

    public var displayBadgeText: String {
        if !isAvailable {
            return "UNAVAILABLE"
        }
        if isBooted {
            return "ACTIVE — protected"
        }
        return state.uppercased()
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
        if case .dockerPrune = actionType { return true }
        return reclaimableSize > 0 || actionType == .simctlDeleteUnavailable
    }

    public var hasSparseDifference: Bool {
        guard logicalSize > 0 && physicalSize > 0 else { return false }
        let diff = abs(logicalSize - physicalSize)
        return Double(diff) / Double(max(logicalSize, physicalSize)) > 0.20 && diff > 100 * 1024 * 1024
    }

    public var actionKind: CleanupResultAction {
        switch actionType {
        case .moveToTrash, .moveToTrashContents:
            return .moveToTrash
        case .simctlDeleteDevice, .simctlDeleteUnavailable, .simctlDeleteRuntime:
            return .simctlDelete
        case .dockerPrune:
            return .dockerPrune
        case .readOnlyInfo:
            return .none
        }
    }

    public var exactCommandOrPathDescription: String {
        switch actionType {
        case .moveToTrash(let p):
            return p
        case .moveToTrashContents(let dir, let days):
            if let d = days, d > 0 {
                return "\(dir)/* (older than \(d) days)"
            }
            return "\(dir)/*"
        case .simctlDeleteDevice(let udid):
            return "xcrun simctl delete \(udid)"
        case .simctlDeleteUnavailable:
            return "xcrun simctl delete unavailable"
        case .simctlDeleteRuntime(let id):
            return "xcrun simctl runtime delete \(id)"
        case .dockerPrune(let args):
            return "docker \(args.joined(separator: " "))"
        case .readOnlyInfo:
            return path
        }
    }
}

public enum AgeFilter: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case all = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oneDay: return "Older than 1 day"
        case .sevenDays: return "Older than 7 days"
        case .thirtyDays: return "Older than 30 days"
        case .all: return "All ages"
        }
    }
}

public struct CleanupHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let category: String
    public let itemName: String
    public let path: String
    public let processedBytes: Int64
    public let movedToTrashBytes: Int64
    public let actuallyFreedBytes: Int64
    public let actionDescription: String
    public let success: Bool
    public let message: String?

    public var bytesReclaimed: Int64 {
        actuallyFreedBytes > 0 ? actuallyFreedBytes : processedBytes
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: String,
        itemName: String,
        path: String,
        processedBytes: Int64,
        movedToTrashBytes: Int64,
        actuallyFreedBytes: Int64,
        actionDescription: String,
        success: Bool,
        message: String? = nil
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.itemName = itemName
        self.path = path
        self.processedBytes = processedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.actuallyFreedBytes = actuallyFreedBytes
        self.actionDescription = actionDescription
        self.success = success
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case id, date, category, itemName, path
        case processedBytes, movedToTrashBytes, actuallyFreedBytes, bytesReclaimed
        case actionDescription, success, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(Date.self, forKey: .date)
        self.category = try container.decode(String.self, forKey: .category)
        self.itemName = try container.decode(String.self, forKey: .itemName)
        self.path = try container.decode(String.self, forKey: .path)
        let legacyBytes = try container.decodeIfPresent(Int64.self, forKey: .bytesReclaimed) ?? 0
        self.processedBytes = try container.decodeIfPresent(Int64.self, forKey: .processedBytes) ?? legacyBytes
        self.movedToTrashBytes = try container.decodeIfPresent(Int64.self, forKey: .movedToTrashBytes) ?? legacyBytes
        self.actuallyFreedBytes = try container.decodeIfPresent(Int64.self, forKey: .actuallyFreedBytes) ?? 0
        self.actionDescription = try container.decode(String.self, forKey: .actionDescription)
        self.success = try container.decode(Bool.self, forKey: .success)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(category, forKey: .category)
        try container.encode(itemName, forKey: .itemName)
        try container.encode(path, forKey: .path)
        try container.encode(processedBytes, forKey: .processedBytes)
        try container.encode(movedToTrashBytes, forKey: .movedToTrashBytes)
        try container.encode(actuallyFreedBytes, forKey: .actuallyFreedBytes)
        try container.encode(actionDescription, forKey: .actionDescription)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(message, forKey: .message)
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
