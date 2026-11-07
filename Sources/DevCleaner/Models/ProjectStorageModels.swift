import Foundation

public enum ProjectArtifactCategory: String, CaseIterable, Sendable, Identifiable {
    case cache = "Regenerable Cache"
    case build = "Build Output"
    case dependency = "Dependencies"
    case testArtifact = "Test & QA Artifact"
    case worktree = "Git / Claude Worktree"
    case protectedData = "Protected / Unverified Data"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .cache: return "internaldrive"
        case .build: return "hammer.fill"
        case .dependency: return "shippingbox.fill"
        case .testArtifact: return "checkmark.seal.fill"
        case .worktree: return "point.3.connected.trianglepath.dotted"
        case .protectedData: return "lock.shield.fill"
        }
    }
}

public struct ProjectArtifactEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectName: String
    public let projectRootPath: String
    public let name: String
    public let relativePath: String
    public let fullPath: String
    public let artifactCategory: ProjectArtifactCategory
    public let verifiedKind: VerifiedProjectArtifactKind?
    public let physicalBytes: Int64
    public let logicalBytes: Int64
    public let reclaimableBytes: Int64
    public let lastModified: Date?
    public let riskLevel: RiskLevel
    public let explanation: String
    public let deletionConsequence: String
    public let isRunningDependency: Bool
    public let runningProcessNames: [String]
    public let cleanableItem: CleanableItem

    public init(
        id: UUID = UUID(),
        projectName: String,
        projectRootPath: String,
        name: String,
        relativePath: String,
        fullPath: String,
        artifactCategory: ProjectArtifactCategory,
        verifiedKind: VerifiedProjectArtifactKind?,
        physicalBytes: Int64,
        logicalBytes: Int64,
        reclaimableBytes: Int64,
        lastModified: Date?,
        riskLevel: RiskLevel,
        explanation: String,
        deletionConsequence: String,
        isRunningDependency: Bool,
        runningProcessNames: [String],
        cleanableItem: CleanableItem
    ) {
        self.id = id
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.name = name
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.artifactCategory = artifactCategory
        self.verifiedKind = verifiedKind
        self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.lastModified = lastModified
        self.riskLevel = riskLevel
        self.explanation = explanation
        self.deletionConsequence = deletionConsequence
        self.isRunningDependency = isRunningDependency
        self.runningProcessNames = runningProcessNames
        self.cleanableItem = cleanableItem
    }
}

public struct ProjectStorageReport: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let totalPhysicalBytes: Int64
    public let totalLogicalBytes: Int64
    public let dependenciesBytes: Int64
    public let cachesBytes: Int64
    public let buildsBytes: Int64
    public let worktreesBytes: Int64
    public let protectedBytes: Int64
    public let safeRecoverableBytes: Int64
    public let reviewRecoverableBytes: Int64
    public let lastActivityDate: Date?
    public let overallRiskLevel: RiskLevel
    public let activeProcessNames: [String]
    public let projectTypeTags: [String]
    public let artifacts: [ProjectArtifactEntry]

    public var potentialRecoveryBytes: Int64 {
        safeRecoverableBytes + reviewRecoverableBytes
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        totalPhysicalBytes: Int64,
        totalLogicalBytes: Int64,
        dependenciesBytes: Int64,
        cachesBytes: Int64,
        buildsBytes: Int64,
        worktreesBytes: Int64,
        protectedBytes: Int64,
        safeRecoverableBytes: Int64,
        reviewRecoverableBytes: Int64,
        lastActivityDate: Date?,
        overallRiskLevel: RiskLevel,
        activeProcessNames: [String],
        projectTypeTags: [String],
        artifacts: [ProjectArtifactEntry]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.totalPhysicalBytes = totalPhysicalBytes
        self.totalLogicalBytes = totalLogicalBytes
        self.dependenciesBytes = dependenciesBytes
        self.cachesBytes = cachesBytes
        self.buildsBytes = buildsBytes
        self.worktreesBytes = worktreesBytes
        self.protectedBytes = protectedBytes
        self.safeRecoverableBytes = safeRecoverableBytes
        self.reviewRecoverableBytes = reviewRecoverableBytes
        self.lastActivityDate = lastActivityDate
        self.overallRiskLevel = overallRiskLevel
        self.activeProcessNames = activeProcessNames
        self.projectTypeTags = projectTypeTags
        self.artifacts = artifacts
    }
}

public struct ProjectStorageSummary: Sendable, Equatable {
    public let rootDirectoryPath: String
    public let totalProjectsCount: Int
    public let totalProjectsPhysicalBytes: Int64
    public let regenerableCachesAndBuildsBytes: Int64
    public let reviewRequiredBytes: Int64
    public let worktreesBytes: Int64
    public let protectedDataBytes: Int64
    public var potentialRecoveryBytes: Int64 {
        regenerableCachesAndBuildsBytes + reviewRequiredBytes
    }

    public static let empty = ProjectStorageSummary(
        rootDirectoryPath: "",
        totalProjectsCount: 0,
        totalProjectsPhysicalBytes: 0,
        regenerableCachesAndBuildsBytes: 0,
        reviewRequiredBytes: 0,
        worktreesBytes: 0,
        protectedDataBytes: 0
    )

    public init(
        rootDirectoryPath: String,
        totalProjectsCount: Int,
        totalProjectsPhysicalBytes: Int64,
        regenerableCachesAndBuildsBytes: Int64,
        reviewRequiredBytes: Int64,
        worktreesBytes: Int64,
        protectedDataBytes: Int64
    ) {
        self.rootDirectoryPath = rootDirectoryPath
        self.totalProjectsCount = totalProjectsCount
        self.totalProjectsPhysicalBytes = totalProjectsPhysicalBytes
        self.regenerableCachesAndBuildsBytes = regenerableCachesAndBuildsBytes
        self.reviewRequiredBytes = reviewRequiredBytes
        self.worktreesBytes = worktreesBytes
        self.protectedDataBytes = protectedDataBytes
    }
}

public enum WorktreeOriginKind: String, Codable, Sendable, Equatable {
    case claudeWorktree = "Claude Worktree (.claude/worktrees)"
    case codexWorktree = "Codex Worktree (~/.codex/worktrees)"
    case gitLinkedWorktree = "Git Linked Worktree"

    public var shortAgentLabel: String {
        switch self {
        case .claudeWorktree: return "Claude"
        case .codexWorktree: return "Codex"
        case .gitLinkedWorktree: return "Git Worktree"
        }
    }
}

public enum WorktreeActivityState: String, Codable, CaseIterable, Sendable, Equatable {
    case recentlyUsed = "Active / Recently Used"
    case inactiveEligible = "Unused 7+ Days (Eligible)"
    case staleStrongCandidate = "Unused 14+ Days (Strong cleanup candidate)"
}

public enum WorktreeGitTrackingState: String, Codable, CaseIterable, Sendable, Equatable {
    case ignored = "Git: ignored"
    case untracked = "Git: untracked"
    case tracked = "Git: tracked"
}

public struct WorktreeInactivityConfig: Codable, Equatable, Sendable {
    public var inactiveDaysThreshold: Int
    public var strongCandidateDaysThreshold: Int
    public var minimumDaysForSafeClassification: Int

    public static let `default` = WorktreeInactivityConfig(
        inactiveDaysThreshold: 7,
        strongCandidateDaysThreshold: 14,
        minimumDaysForSafeClassification: 0
    )

    public init(
        inactiveDaysThreshold: Int = 7,
        strongCandidateDaysThreshold: Int = 14,
        minimumDaysForSafeClassification: Int = 0
    ) {
        let inactive = max(1, inactiveDaysThreshold)
        self.inactiveDaysThreshold = inactive
        self.strongCandidateDaysThreshold = max(inactive, strongCandidateDaysThreshold)
        self.minimumDaysForSafeClassification = max(0, minimumDaysForSafeClassification)
    }
}

public enum WorktreeArtifactType: String, Codable, CaseIterable, Sendable, Equatable {
    case nodeModules = "node_modules"
    case nextBuild = ".next"
    case turboCache = ".turbo"
    case cache = ".cache"
    case distOutput = "dist"
    case buildOutput = "build"
    case frameworkCache = "Framework Build Cache"
    case typescriptMetadata = "TypeScript Metadata"
    case firebaseEmulatorCache = "Firebase Emulator Cache"
    case cocoaPods = "Pods"
    case swiftPMBuild = ".build"
    case gradleCache = ".gradle"
}

public struct WorktreeArtifactCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let repositoryName: String
    public let repositoryPath: String
    public let worktreeName: String
    public let worktreePath: String
    public let originKind: WorktreeOriginKind
    public let branchLabel: String
    public let artifactName: String
    public let relativePath: String
    public let fullPath: String
    public let artifactType: WorktreeArtifactType
    public let physicalBytes: Int64
    public let logicalBytes: Int64
    public let reclaimableBytes: Int64
    public let lastModified: Date?
    public let classification: RiskLevel
    public let classificationReason: String
    public let gitTrackingState: WorktreeGitTrackingState
    public let reproducibilitySource: String?
    public let isWorktreeDirty: Bool
    public let isWorktreeActiveOrRecent: Bool
    public let activityState: WorktreeActivityState
    public let cleanableItem: CleanableItem

    public var projectAndWorktreeDisplay: String {
        "\(repositoryName) / \(worktreeName)"
    }

    public var artifactAndSizeDisplay: String {
        "\(relativePath) — \(Formatters.bytes(physicalBytes))"
    }

    public init(
        id: String,
        repositoryName: String,
        repositoryPath: String,
        worktreeName: String,
        worktreePath: String,
        originKind: WorktreeOriginKind,
        branchLabel: String,
        artifactName: String,
        relativePath: String,
        fullPath: String,
        artifactType: WorktreeArtifactType,
        physicalBytes: Int64,
        logicalBytes: Int64,
        reclaimableBytes: Int64,
        lastModified: Date?,
        classification: RiskLevel,
        classificationReason: String,
        gitTrackingState: WorktreeGitTrackingState = .ignored,
        reproducibilitySource: String? = nil,
        isWorktreeDirty: Bool,
        isWorktreeActiveOrRecent: Bool,
        activityState: WorktreeActivityState,
        cleanableItem: CleanableItem
    ) {
        self.id = id
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.worktreeName = worktreeName
        self.worktreePath = worktreePath
        self.originKind = originKind
        self.branchLabel = branchLabel
        self.artifactName = artifactName
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.artifactType = artifactType
        self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.lastModified = lastModified
        self.classification = classification
        self.classificationReason = classificationReason
        self.gitTrackingState = gitTrackingState
        self.reproducibilitySource = reproducibilitySource
        self.isWorktreeDirty = isWorktreeDirty
        self.isWorktreeActiveOrRecent = isWorktreeActiveOrRecent
        self.activityState = activityState
        self.cleanableItem = cleanableItem
    }

    public static func == (lhs: WorktreeArtifactCandidate, rhs: WorktreeArtifactCandidate) -> Bool {
        lhs.id == rhs.id &&
        lhs.fullPath == rhs.fullPath &&
        lhs.physicalBytes == rhs.physicalBytes &&
        lhs.reclaimableBytes == rhs.reclaimableBytes &&
        lhs.classification == rhs.classification &&
        lhs.classificationReason == rhs.classificationReason &&
        lhs.gitTrackingState == rhs.gitTrackingState &&
        lhs.activityState == rhs.activityState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fullPath)
        hasher.combine(physicalBytes)
        hasher.combine(classification)
        hasher.combine(gitTrackingState)
    }
}

public struct WorktreeCleanupSkippedItem: Equatable, Sendable {
    public let path: String
    public let artifactName: String
    public let worktreeName: String
    public let classification: RiskLevel
    public let reason: String

    public init(
        path: String,
        artifactName: String,
        worktreeName: String,
        classification: RiskLevel,
        reason: String
    ) {
        self.path = path
        self.artifactName = artifactName
        self.worktreeName = worktreeName
        self.classification = classification
        self.reason = reason
    }
}

public struct WorktreeCleanupReport: Equatable, Sendable {
    public let cleanedPaths: [String]
    public let reclaimedBytes: Int64
    public let skippedItems: [WorktreeCleanupSkippedItem]
    public let rolledBackPaths: [String]
    public let failedItems: [WorktreeCleanupSkippedItem]
    public let gitStatusPreserved: Bool
    public let gitStatusDetails: [String: String]

    public init(
        cleanedPaths: [String],
        reclaimedBytes: Int64,
        skippedItems: [WorktreeCleanupSkippedItem],
        rolledBackPaths: [String] = [],
        failedItems: [WorktreeCleanupSkippedItem] = [],
        gitStatusPreserved: Bool,
        gitStatusDetails: [String: String] = [:]
    ) {
        self.cleanedPaths = cleanedPaths
        self.reclaimedBytes = reclaimedBytes
        self.skippedItems = skippedItems
        self.rolledBackPaths = rolledBackPaths
        self.failedItems = failedItems
        self.gitStatusPreserved = gitStatusPreserved
        self.gitStatusDetails = gitStatusDetails
    }
}

public struct WorktreeAnalysisSummary: Equatable, Sendable {
    public let claudeWorktreesCount: Int
    public let codexWorktreesCount: Int
    public let gitLinkedWorktreesCount: Int
    public let totalWorktreesCount: Int
    public let totalWorktreesPhysicalBytes: Int64
    public let regenerableBytes: Int64
    public let safeRegenerableBytes: Int64
    public let reviewRegenerableBytes: Int64
    public let activeWorktreesCount: Int
    public let inactiveWorktreesCount: Int
    public let strongCandidateWorktreesCount: Int
    public let totalCandidatesCount: Int
    public let safeCandidatesCount: Int
    public let reviewCandidatesCount: Int

    public var retainedBytes: Int64 {
        max(0, totalWorktreesPhysicalBytes - safeRegenerableBytes)
    }

    public static let empty = WorktreeAnalysisSummary(
        claudeWorktreesCount: 0,
        codexWorktreesCount: 0,
        gitLinkedWorktreesCount: 0,
        totalWorktreesCount: 0,
        totalWorktreesPhysicalBytes: 0,
        regenerableBytes: 0,
        safeRegenerableBytes: 0,
        reviewRegenerableBytes: 0,
        activeWorktreesCount: 0,
        inactiveWorktreesCount: 0,
        strongCandidateWorktreesCount: 0,
        totalCandidatesCount: 0,
        safeCandidatesCount: 0,
        reviewCandidatesCount: 0
    )

    public init(
        claudeWorktreesCount: Int,
        codexWorktreesCount: Int,
        gitLinkedWorktreesCount: Int,
        totalWorktreesCount: Int,
        totalWorktreesPhysicalBytes: Int64,
        regenerableBytes: Int64,
        safeRegenerableBytes: Int64,
        reviewRegenerableBytes: Int64,
        activeWorktreesCount: Int,
        inactiveWorktreesCount: Int,
        strongCandidateWorktreesCount: Int,
        totalCandidatesCount: Int,
        safeCandidatesCount: Int,
        reviewCandidatesCount: Int
    ) {
        self.claudeWorktreesCount = claudeWorktreesCount
        self.codexWorktreesCount = codexWorktreesCount
        self.gitLinkedWorktreesCount = gitLinkedWorktreesCount
        self.totalWorktreesCount = totalWorktreesCount
        self.totalWorktreesPhysicalBytes = totalWorktreesPhysicalBytes
        self.regenerableBytes = regenerableBytes
        self.safeRegenerableBytes = safeRegenerableBytes
        self.reviewRegenerableBytes = reviewRegenerableBytes
        self.activeWorktreesCount = activeWorktreesCount
        self.inactiveWorktreesCount = inactiveWorktreesCount
        self.strongCandidateWorktreesCount = strongCandidateWorktreesCount
        self.totalCandidatesCount = totalCandidatesCount
        self.safeCandidatesCount = safeCandidatesCount
        self.reviewCandidatesCount = reviewCandidatesCount
    }

    public static func from(records: [GitWorktreeRecord]) -> WorktreeAnalysisSummary {
        let claudeCount = records.filter { $0.originKind == .claudeWorktree }.count
        let codexCount = records.filter { $0.originKind == .codexWorktree }.count
        let linkedCount = records.filter { $0.originKind == .gitLinkedWorktree }.count
        let totalPhys = records.reduce(Int64(0)) { $0 + $1.physicalBytes }
        let regen = records.reduce(Int64(0)) { $0 + $1.regenerableBytes }
        let safeRegen = records.reduce(Int64(0)) { $0 + $1.safeRegenerableBytes }
        let reviewRegen = records.reduce(Int64(0)) { $0 + $1.reviewRegenerableBytes }
        let activeCount = records.filter { $0.isActiveOrRecent }.count
        let inactiveCount = records.filter { !$0.isActiveOrRecent }.count
        let strongCount = records.filter { $0.activityState == .staleStrongCandidate }.count
        let allCandidates = records.flatMap { $0.artifactCandidates }
        let safeCandidates = allCandidates.filter { $0.classification == .safe }.count
        let reviewCandidates = allCandidates.filter { $0.classification != .safe }.count

        return WorktreeAnalysisSummary(
            claudeWorktreesCount: claudeCount,
            codexWorktreesCount: codexCount,
            gitLinkedWorktreesCount: linkedCount,
            totalWorktreesCount: records.count,
            totalWorktreesPhysicalBytes: totalPhys,
            regenerableBytes: regen,
            safeRegenerableBytes: safeRegen,
            reviewRegenerableBytes: reviewRegen,
            activeWorktreesCount: activeCount,
            inactiveWorktreesCount: inactiveCount,
            strongCandidateWorktreesCount: strongCount,
            totalCandidatesCount: allCandidates.count,
            safeCandidatesCount: safeCandidates,
            reviewCandidatesCount: reviewCandidates
        )
    }
}

public struct GitWorktreeRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceProjectName: String
    public let sourceProjectPath: String
    public let worktreeName: String
    public let path: String
    public let originKind: WorktreeOriginKind
    public let isVerifiedWorktree: Bool
    public let headCommit: String
    public let branchLabel: String
    public let isDetached: Bool
    public let physicalBytes: Int64
    public let logicalBytes: Int64
    public let nodeModulesBytes: Int64
    public let buildAndCacheBytes: Int64
    public let regenerableBytes: Int64
    public let safeRegenerableBytes: Int64
    public let reviewRegenerableBytes: Int64
    public let existsOnDisk: Bool
    public let hasUncommittedChanges: Bool
    public let modifiedFilesCount: Int
    public let untrackedFilesCount: Int
    public let stagedFilesCount: Int
    public let sampleChangedFiles: [String]
    public let remoteBranchStatus: String
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let prunableReason: String?
    public let isInUseByProcess: Bool
    public let activeProcessNames: [String]
    public let lastCommitDate: Date?
    public let lastModifiedDate: Date?
    public let lastActivityDate: Date?
    public let lastMeaningfulActivityDate: Date?
    public let inactiveDays: Int
    public let isActiveOrRecent: Bool
    public let activityState: WorktreeActivityState
    public let workLossRisk: RiskLevel
    public let riskExplanation: String
    public let artifactCandidates: [WorktreeArtifactCandidate]

    public var retainedBytes: Int64 {
        max(0, physicalBytes - safeRegenerableBytes)
    }

    public init(
        id: UUID = UUID(),
        sourceProjectName: String,
        sourceProjectPath: String,
        worktreeName: String? = nil,
        path: String,
        originKind: WorktreeOriginKind,
        isVerifiedWorktree: Bool = true,
        headCommit: String,
        branchLabel: String,
        isDetached: Bool,
        physicalBytes: Int64,
        logicalBytes: Int64,
        nodeModulesBytes: Int64,
        buildAndCacheBytes: Int64,
        regenerableBytes: Int64? = nil,
        safeRegenerableBytes: Int64 = 0,
        reviewRegenerableBytes: Int64 = 0,
        existsOnDisk: Bool,
        hasUncommittedChanges: Bool,
        modifiedFilesCount: Int,
        untrackedFilesCount: Int,
        stagedFilesCount: Int,
        sampleChangedFiles: [String],
        remoteBranchStatus: String,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        prunableReason: String?,
        isInUseByProcess: Bool,
        activeProcessNames: [String],
        lastCommitDate: Date? = nil,
        lastModifiedDate: Date?,
        lastActivityDate: Date? = nil,
        lastMeaningfulActivityDate: Date? = nil,
        inactiveDays: Int = 0,
        isActiveOrRecent: Bool = false,
        activityState: WorktreeActivityState = .inactiveEligible,
        workLossRisk: RiskLevel,
        riskExplanation: String,
        artifactCandidates: [WorktreeArtifactCandidate] = []
    ) {
        self.id = id
        self.sourceProjectName = sourceProjectName
        self.sourceProjectPath = sourceProjectPath
        self.worktreeName = worktreeName ?? URL(fileURLWithPath: path).lastPathComponent
        self.path = path
        self.originKind = originKind
        self.isVerifiedWorktree = isVerifiedWorktree
        self.headCommit = headCommit
        self.branchLabel = branchLabel
        self.isDetached = isDetached
        self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes
        self.nodeModulesBytes = nodeModulesBytes
        self.buildAndCacheBytes = buildAndCacheBytes
        self.regenerableBytes = regenerableBytes ?? (nodeModulesBytes + buildAndCacheBytes)
        self.safeRegenerableBytes = safeRegenerableBytes
        self.reviewRegenerableBytes = reviewRegenerableBytes
        self.existsOnDisk = existsOnDisk
        self.hasUncommittedChanges = hasUncommittedChanges
        self.modifiedFilesCount = modifiedFilesCount
        self.untrackedFilesCount = untrackedFilesCount
        self.stagedFilesCount = stagedFilesCount
        self.sampleChangedFiles = sampleChangedFiles
        self.remoteBranchStatus = remoteBranchStatus
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
        self.isInUseByProcess = isInUseByProcess
        self.activeProcessNames = activeProcessNames
        self.lastCommitDate = lastCommitDate
        self.lastModifiedDate = lastModifiedDate
        let resolvedMeaningful = lastMeaningfulActivityDate ?? lastActivityDate ?? lastCommitDate ?? lastModifiedDate
        self.lastActivityDate = resolvedMeaningful
        self.lastMeaningfulActivityDate = resolvedMeaningful
        self.inactiveDays = inactiveDays
        self.isActiveOrRecent = isActiveOrRecent
        self.activityState = activityState
        self.workLossRisk = workLossRisk
        self.riskExplanation = riskExplanation
        self.artifactCandidates = artifactCandidates
    }
}
