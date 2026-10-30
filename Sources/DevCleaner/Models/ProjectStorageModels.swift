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

public enum WorktreeOriginKind: String, Sendable, Equatable {
    case claudeWorktree = "Claude Worktree (.claude/worktrees)"
    case codexWorktree = "Codex Worktree (~/.codex/worktrees)"
    case gitLinkedWorktree = "Git Linked Worktree"
}

public struct GitWorktreeRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceProjectName: String
    public let sourceProjectPath: String
    public let path: String
    public let originKind: WorktreeOriginKind
    public let headCommit: String
    public let branchLabel: String
    public let isDetached: Bool
    public let physicalBytes: Int64
    public let logicalBytes: Int64
    public let nodeModulesBytes: Int64
    public let buildAndCacheBytes: Int64
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
    public let lastModifiedDate: Date?
    public let workLossRisk: RiskLevel
    public let riskExplanation: String

    public init(
        id: UUID = UUID(),
        sourceProjectName: String,
        sourceProjectPath: String,
        path: String,
        originKind: WorktreeOriginKind,
        headCommit: String,
        branchLabel: String,
        isDetached: Bool,
        physicalBytes: Int64,
        logicalBytes: Int64,
        nodeModulesBytes: Int64,
        buildAndCacheBytes: Int64,
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
        lastModifiedDate: Date?,
        workLossRisk: RiskLevel,
        riskExplanation: String
    ) {
        self.id = id
        self.sourceProjectName = sourceProjectName
        self.sourceProjectPath = sourceProjectPath
        self.path = path
        self.originKind = originKind
        self.headCommit = headCommit
        self.branchLabel = branchLabel
        self.isDetached = isDetached
        self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes
        self.nodeModulesBytes = nodeModulesBytes
        self.buildAndCacheBytes = buildAndCacheBytes
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
        self.lastModifiedDate = lastModifiedDate
        self.workLossRisk = workLossRisk
        self.riskExplanation = riskExplanation
    }
}
