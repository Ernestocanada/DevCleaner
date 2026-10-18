import Foundation

public struct CleanupPlanner: Sendable {
    public let validator: SafetyValidator

    public init(validator: SafetyValidator = SafetyValidator()) {
        self.validator = validator
    }

    /// Evaluates immediate children of an allow-listed disposable cache directory using the exact same
    /// SafetyValidator subtree inspection and AgeFilter threshold used by both scanning/preview and execution.
    public func eligibleChildren(
        directory: URL,
        ageFilter: AgeFilter,
        supportsAgeFilter: Bool = true,
        baseRisk: RiskLevel = .safe,
        isRunningDependency: Bool = false
    ) -> [CleanupPlanEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: []
        )) ?? []

        let effectiveDays: Int? = (supportsAgeFilter && ageFilter != .all) ? ageFilter.rawValue : nil
        let cutoffDate: Date? = effectiveDays != nil ? Date().addingTimeInterval(-Double(effectiveDays!) * 86400) : nil

        var entries: [CleanupPlanEntry] = []

        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" { continue }

            let usage = DiskScanner.shared.measurePath(child.path, minAgeDays: nil)

            // 1. Validate child path & recursive subtree using SafetyValidator
            do {
                let validatedChildPath = try validator.validateForDeletion(child.path)
                try validator.validateSubtreeForDeletion(validatedChildPath)

                // 2. Check running dependency
                if isRunningDependency {
                    entries.append(
                        CleanupPlanEntry(
                            name: name,
                            path: validatedChildPath,
                            physicalBytes: usage.physicalSize,
                            logicalBytes: usage.logicalSize,
                            lastModified: usage.lastModified,
                            action: .moveToTrash(path: validatedChildPath),
                            risk: baseRisk,
                            eligibility: .runningProcess,
                            reason: "Close active application before cleaning."
                        )
                    )
                    continue
                }

                // 3. Check age filter
                if let cutoff = cutoffDate {
                    if let mod = usage.lastModified, mod > cutoff {
                        entries.append(
                            CleanupPlanEntry(
                                name: name,
                                path: validatedChildPath,
                                physicalBytes: usage.physicalSize,
                                logicalBytes: usage.logicalSize,
                                lastModified: usage.lastModified,
                                action: .moveToTrash(path: validatedChildPath),
                                risk: baseRisk,
                                eligibility: .tooRecent,
                                reason: "Modified within the last \(effectiveDays!) day(s)."
                            )
                        )
                        continue
                    }
                }

                // 4. Eligible for cleanup
                entries.append(
                    CleanupPlanEntry(
                        name: name,
                        path: validatedChildPath,
                        physicalBytes: usage.physicalSize,
                        logicalBytes: usage.logicalSize,
                        lastModified: usage.lastModified,
                        action: .moveToTrash(path: validatedChildPath),
                        risk: baseRisk,
                        eligibility: .eligible,
                        reason: nil
                    )
                )
            } catch let safetyErr as SafetyError {
                let reason = Self.describeSafetyBlock(safetyErr)
                entries.append(
                    CleanupPlanEntry(
                        name: name,
                        path: child.path,
                        physicalBytes: usage.physicalSize,
                        logicalBytes: usage.logicalSize,
                        lastModified: usage.lastModified,
                        action: .readOnlyInfo(reason: reason),
                        risk: .review,
                        eligibility: .protected,
                        reason: reason
                    )
                )
            } catch {
                let reason = error.localizedDescription
                entries.append(
                    CleanupPlanEntry(
                        name: name,
                        path: child.path,
                        physicalBytes: usage.physicalSize,
                        logicalBytes: usage.logicalSize,
                        lastModified: usage.lastModified,
                        action: .readOnlyInfo(reason: reason),
                        risk: .review,
                        eligibility: .protected,
                        reason: reason
                    )
                )
            }
        }

        // Sort entries by physical size descending
        entries.sort { $0.physicalBytes > $1.physicalBytes }
        return entries
    }

    public func planDirectoryContents(
        directoryPath: String,
        baseRisk: RiskLevel = .safe,
        ageFilter: AgeFilter = .all,
        supportsAgeFilter: Bool = true,
        isRunningDependency: Bool = false
    ) -> CleanupPlan {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let entries = eligibleChildren(
            directory: dirURL,
            ageFilter: ageFilter,
            supportsAgeFilter: supportsAgeFilter,
            baseRisk: baseRisk,
            isRunningDependency: isRunningDependency
        )
        return CleanupPlan(entries: entries)
    }

    public static func describeSafetyBlock(_ error: SafetyError) -> String {
        switch error {
        case .forbiddenFileOrComponent(let p):
            let fileName = URL(fileURLWithPath: p).lastPathComponent
            if fileName == ".env" || fileName.hasPrefix(".env.") {
                return "Contains protected-looking environment file (\(fileName)). Automatic SAFE cleanup skipped this cache entry."
            }
            return "Contains protected-looking file (\(fileName)). Automatic SAFE cleanup skipped this cache entry."
        case .symlinkTraversalRejected(let detail):
            return "Contains symbolic link escaping allow-list (\(detail)). Automatic SAFE cleanup skipped this cache entry."
        default:
            return error.localizedDescription
        }
    }
}
