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
    case projectStorage = "Project Storage"

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
        case .projectStorage: return "folder.badge.gearshape"
        }
    }
}

public enum CleanupActionType: Codable, Equatable, Sendable {
    case moveToTrash(path: String)
    case moveToTrashContents(directoryPath: String, minAgeDays: Int?)
    case moveToTrashVerifiedProjectArtifact(path: String, projectRoot: String, expectedModifiedAt: Date?)
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

public enum CleanupExecutionStatus: String, Codable, Equatable, Sendable {
    case cleaned = "Cleaned"
    case skipped = "Skipped"
    case blocked = "Blocked"
    case failed = "Failed"
    case nothingEligible = "Nothing Eligible"
}

public enum CleanupEligibility: String, Codable, Equatable, Sendable {
    case eligible = "ELIGIBLE"
    case protected = "PROTECTED"
    case runningProcess = "RUNNING PROCESS"
    case tooRecent = "TOO RECENT"
    case requiresReview = "REQUIRES REVIEW"
}

public struct CleanupPlanEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let physicalBytes: Int64
    public let logicalBytes: Int64
    public let lastModified: Date?
    public let action: CleanupActionType
    public let risk: RiskLevel
    public let eligibility: CleanupEligibility
    public let reason: String?

    public init(
        name: String,
        path: String,
        physicalBytes: Int64,
        logicalBytes: Int64 = 0,
        lastModified: Date? = nil,
        action: CleanupActionType,
        risk: RiskLevel,
        eligibility: CleanupEligibility,
        reason: String? = nil
    ) {
        self.name = name
        self.path = path
        self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes == 0 ? physicalBytes : logicalBytes
        self.lastModified = lastModified
        self.action = action
        self.risk = risk
        self.eligibility = eligibility
        self.reason = reason
    }
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public let entries: [CleanupPlanEntry]

    public init(entries: [CleanupPlanEntry]) {
        self.entries = entries
    }

    public var eligibleEntries: [CleanupPlanEntry] {
        entries.filter { $0.eligibility == .eligible }
    }

    public var protectedOrReviewEntries: [CleanupPlanEntry] {
        entries.filter { $0.eligibility == .protected || $0.eligibility == .requiresReview }
    }

    public var tooRecentEntries: [CleanupPlanEntry] {
        entries.filter { $0.eligibility == .tooRecent }
    }

    public var runningProcessEntries: [CleanupPlanEntry] {
        entries.filter { $0.eligibility == .runningProcess }
    }

    public var eligibleBytes: Int64 {
        eligibleEntries.reduce(0) { $0 + $1.physicalBytes }
    }

    public var protectedOrReviewBytes: Int64 {
        protectedOrReviewEntries.reduce(0) { $0 + $1.physicalBytes }
    }

    public var tooRecentBytes: Int64 {
        tooRecentEntries.reduce(0) { $0 + $1.physicalBytes }
    }

    public var totalPhysicalBytes: Int64 {
        entries.reduce(0) { $0 + $1.physicalBytes }
    }

    public var totalLogicalBytes: Int64 {
        entries.reduce(0) { $0 + $1.logicalBytes }
    }

    public var latestModified: Date? {
        entries.compactMap { $0.lastModified }.max()
    }
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public let processedBytes: Int64
    public let movedToTrashBytes: Int64
    public let actuallyFreedBytes: Int64
    public let action: CleanupResultAction
    public let status: CleanupExecutionStatus
    public let message: String?

    public init(
        processedBytes: Int64,
        movedToTrashBytes: Int64,
        actuallyFreedBytes: Int64,
        action: CleanupResultAction,
        status: CleanupExecutionStatus = .cleaned,
        message: String? = nil
    ) {
        self.processedBytes = processedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.actuallyFreedBytes = actuallyFreedBytes
        self.action = action
        self.status = status
        self.message = message
    }
}

public struct CleanupBatchSummary: Equatable, Sendable {
    public let date: Date
    public let processedBytes: Int64
    public let movedToTrashBytes: Int64
    public let observedSystemFreeSpaceDelta: Int64
    public let succeededCount: Int
    public let nothingEligibleCount: Int
    public let failedOrBlockedCount: Int
    public let blockedMessages: [String]

    public var actuallyFreedBytes: Int64 {
        observedSystemFreeSpaceDelta
    }

    public init(
        date: Date = Date(),
        processedBytes: Int64,
        movedToTrashBytes: Int64,
        observedSystemFreeSpaceDelta: Int64,
        succeededCount: Int,
        nothingEligibleCount: Int = 0,
        failedOrBlockedCount: Int,
        blockedMessages: [String] = []
    ) {
        self.date = date
        self.processedBytes = processedBytes
        self.movedToTrashBytes = movedToTrashBytes
        self.observedSystemFreeSpaceDelta = observedSystemFreeSpaceDelta
        self.succeededCount = succeededCount
        self.nothingEligibleCount = nothingEligibleCount
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
    public let installedAppNames: [String]
    public let hasLocalData: Bool
    public let isFavorite: Bool

    public init(
        udid: String,
        runtimeName: String,
        state: String,
        isAvailable: Bool,
        lastUsedAt: Date?,
        installedAppNames: [String] = [],
        hasLocalData: Bool = false,
        isFavorite: Bool = false
    ) {
        self.udid = udid
        self.runtimeName = runtimeName
        self.state = state
        self.isAvailable = isAvailable
        self.lastUsedAt = lastUsedAt
        self.installedAppNames = installedAppNames
        self.hasLocalData = hasLocalData
        self.isFavorite = isFavorite
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
        if isFavorite {
            return "FAVORITE — protected"
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
    public let plan: CleanupPlan?
    public let requiresRedownload: Bool
    public let affectsSessionsOrConfig: Bool

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
        supportsAgeFilter: Bool = false,
        plan: CleanupPlan? = nil,
        requiresRedownload: Bool = false,
        affectsSessionsOrConfig: Bool = false
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
        self.plan = plan
        self.requiresRedownload = requiresRedownload
        self.affectsSessionsOrConfig = affectsSessionsOrConfig
    }

    public var canBeSelected: Bool {
        guard riskLevel != .neverDelete else { return false }
        guard !isRunningDependency else { return false }
        if simulatorMetadata?.isFavorite == true { return false }
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
        case .moveToTrash, .moveToTrashContents, .moveToTrashVerifiedProjectArtifact:
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
        case .moveToTrashVerifiedProjectArtifact(let p, _, _):
            return p
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
    public let status: CleanupExecutionStatus
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
        status: CleanupExecutionStatus? = nil,
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
        if let explicitStatus = status {
            self.status = explicitStatus
        } else if !success {
            self.status = .failed
        } else if processedBytes == 0 && movedToTrashBytes == 0 {
            self.status = .nothingEligible
        } else {
            self.status = .cleaned
        }
        self.success = success
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case id, date, category, itemName, path
        case processedBytes, movedToTrashBytes, actuallyFreedBytes, bytesReclaimed
        case actionDescription, status, success, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(Date.self, forKey: .date)
        self.category = try container.decode(String.self, forKey: .category)
        self.itemName = try container.decode(String.self, forKey: .itemName)
        self.path = try container.decode(String.self, forKey: .path)
        let legacyBytes = try container.decodeIfPresent(Int64.self, forKey: .bytesReclaimed) ?? 0
        let proc = try container.decodeIfPresent(Int64.self, forKey: .processedBytes) ?? legacyBytes
        let trashed = try container.decodeIfPresent(Int64.self, forKey: .movedToTrashBytes) ?? legacyBytes
        self.processedBytes = proc
        self.movedToTrashBytes = trashed
        self.actuallyFreedBytes = try container.decodeIfPresent(Int64.self, forKey: .actuallyFreedBytes) ?? 0
        self.actionDescription = try container.decode(String.self, forKey: .actionDescription)
        let succ = try container.decode(Bool.self, forKey: .success)
        self.success = succ
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        if let decodedStatus = try container.decodeIfPresent(CleanupExecutionStatus.self, forKey: .status) {
            self.status = decodedStatus
        } else if !succ {
            self.status = .failed
        } else if proc == 0 && trashed == 0 {
            self.status = .nothingEligible
        } else {
            self.status = .cleaned
        }
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
        try container.encode(status, forKey: .status)
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
