import Foundation

public enum SafetyError: LocalizedError, Equatable {
    case emptyOrInvalidPath
    case containsParentTraversal(String)
    case symlinkTraversalRejected(String)
    case forbiddenProtectedPath(String)
    case forbiddenFileOrComponent(String)
    case notInExplicitAllowList(String)
    case virtualOrMountedFilesystem(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOrInvalidPath:
            return "Path is empty or invalid."
        case .containsParentTraversal(let p):
            return "Path rejected due to parent directory traversal ('..'): \(p)"
        case .symlinkTraversalRejected(let p):
            return "Path rejected because it traverses or points to an unexpected symbolic link target: \(p)"
        case .forbiddenProtectedPath(let p):
            return "SAFETY BLOCK: Path is inside a protected user or project directory: \(p)"
        case .forbiddenFileOrComponent(let p):
            return "SAFETY BLOCK: Path contains protected source, git, credential, or environment data: \(p)"
        case .notInExplicitAllowList(let p):
            return "SAFETY BLOCK: Path is outside the explicit allow-list of cleanable developer caches: \(p)"
        case .virtualOrMountedFilesystem(let p):
            return "SAFETY BLOCK: Path is a virtual or system-mounted filesystem and must never be deleted: \(p)"
        }
    }
}

public struct SafetyValidator: Sendable {
    public let homeDirectory: String

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        if homeDirectory.hasSuffix("/") && homeDirectory.count > 1 {
            self.homeDirectory = String(homeDirectory.dropLast())
        } else {
            self.homeDirectory = homeDirectory
        }
    }

    /// Explicitly forbidden path prefixes (relative to home or absolute)
    public var forbiddenPrefixes: [String] {
        [
            "\(homeDirectory)/Developer",
            "\(homeDirectory)/.ssh",
            "\(homeDirectory)/.gnupg",
            "\(homeDirectory)/.aws",
            "\(homeDirectory)/.config/gcloud",
            "\(homeDirectory)/.gitconfig",
            "\(homeDirectory)/Documents",
            "\(homeDirectory)/Desktop",
            "\(homeDirectory)/Downloads",
            "\(homeDirectory)/Pictures",
            "\(homeDirectory)/Movies",
            "\(homeDirectory)/Music",
            "\(homeDirectory)/Library/Mobile Documents",
            "\(homeDirectory)/Library/Mail",
            "\(homeDirectory)/Library/Photos",
            "\(homeDirectory)/Library/Keychains",
            "\(homeDirectory)/Library/Developer/CoreDevice",
            "\(homeDirectory)/Library/Developer/CoreDevice/DeviceFS",
            "/Library/Developer/CoreSimulator/Volumes",
            "/System",
            "/Users/Shared",
            "/Applications"
        ]
    }

    /// Explicitly allowed prefixes where deletion (Trash or subdirectories) is permitted.
    public var allowedRootPrefixes: [String] {
        [
            "\(homeDirectory)/Library/Developer/Xcode/DerivedData",
            "\(homeDirectory)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(homeDirectory)/Library/Logs/CoreSimulator",
            "\(homeDirectory)/Library/Caches/com.apple.dt.Xcode",
            "\(homeDirectory)/Library/Caches/org.swift.swiftpm",
            "\(homeDirectory)/Library/Caches/CocoaPods",
            "\(homeDirectory)/Library/Caches/Homebrew",
            "\(homeDirectory)/Library/Caches/Codex",
            "\(homeDirectory)/Library/Caches/Google",
            "\(homeDirectory)/Library/Caches/pip",
            "\(homeDirectory)/Library/Caches/Yarn",
            "\(homeDirectory)/Library/Caches/pnpm",
            "\(homeDirectory)/Library/Caches/ms-playwright",
            "\(homeDirectory)/.gradle/caches",
            "\(homeDirectory)/.gradle/daemon",
            "\(homeDirectory)/.npm/_cacache",
            "\(homeDirectory)/.npm/_npx",
            "\(homeDirectory)/.npm/_logs",
            "\(homeDirectory)/.cache/codex-runtimes",
            "\(homeDirectory)/.android/avd",
            "\(homeDirectory)/.android/cache",
            "\(homeDirectory)/Library/Application Support/Claude/Cache",
            "\(homeDirectory)/Library/Application Support/Claude/Code Cache",
            "\(homeDirectory)/Library/Application Support/Claude/GPUCache",
            "\(homeDirectory)/Library/Application Support/Claude/simulator-builds",
            "\(homeDirectory)/Library/Application Support/Claude/vm_bundles",
            "\(homeDirectory)/Library/Application Support/Codex/Cache",
            "\(homeDirectory)/Library/Application Support/Codex/Code Cache",
            "\(homeDirectory)/Library/Application Support/Codex/GPUCache",
            "\(homeDirectory)/Library/Application Support/com.google.AIEdgeForesight/models",
            "\(homeDirectory)/Library/Application Support/com.google.AIEdgeForesight/model_cache"
        ]
    }

    /// Forbidden path components anywhere in the path
    public let forbiddenComponents: Set<String> = [
        ".git",
        ".env",
        ".env.local",
        ".env.production",
        ".ssh",
        ".gnupg",
        ".aws",
        ".gitconfig",
        "Keychains",
        "GoogleService-Info.plist",
        "google-services.json",
        "firebase-adminsdk.json",
        "application_default_credentials.json",
        "Docker.raw"
    ]

    public func isForbiddenComponentName(_ comp: String) -> Bool {
        if forbiddenComponents.contains(comp) {
            return true
        }
        let lower = comp.lowercased()
        if comp.hasPrefix(".env.") ||
           (lower.contains("firebase") && lower.contains("credential")) ||
           (lower.contains("firebase") && lower.hasSuffix(".json")) {
            return true
        }
        return false
    }

    /// Expands tilde if using custom homeDirectory and returns standardized lexical path
    public func expandAndNormalize(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SafetyError.emptyOrInvalidPath
        }

        // Reject raw parent traversal components before normalization
        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if rawComponents.contains("..") {
            throw SafetyError.containsParentTraversal(rawPath)
        }

        var expanded = trimmed
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + String(expanded.dropFirst(1))
        }

        guard expanded.hasPrefix("/") else {
            throw SafetyError.emptyOrInvalidPath
        }

        let url = URL(fileURLWithPath: expanded)
        var standardized = url.standardizedFileURL.path
        if standardized.hasSuffix("/") && standardized.count > 1 {
            standardized = String(standardized.dropLast())
        }

        if standardized == "/" ||
           standardized == homeDirectory ||
           standardized == "\(homeDirectory)/Library" ||
           standardized == "\(homeDirectory)/Library/Caches" ||
           standardized == "\(homeDirectory)/Library/Application Support" {
            throw SafetyError.forbiddenProtectedPath(standardized)
        }

        return standardized
    }

    /// Validates that a path is 100% safe to delete (or trash) according to strict allow-list and block-list rules.
    public func validateForDeletion(_ rawPath: String, checkSymlinksOnDisk: Bool = true) throws -> String {
        let normalized = try expandAndNormalize(rawPath)

        // 1. Check virtual / mounted filesystem paths
        if normalized.hasPrefix("\(homeDirectory)/Library/Developer/CoreDevice") ||
           normalized.hasPrefix("/Library/Developer/CoreSimulator/Volumes") {
            throw SafetyError.virtualOrMountedFilesystem(normalized)
        }

        // 2. Check forbidden components anywhere in path
        let components = normalized.split(separator: "/").map(String.init)
        for comp in components {
            if isForbiddenComponentName(comp) {
                throw SafetyError.forbiddenFileOrComponent(normalized)
            }
        }

        // 3. Check forbidden prefixes
        for forbidden in forbiddenPrefixes {
            if normalized == forbidden || normalized.hasPrefix(forbidden + "/") {
                throw SafetyError.forbiddenProtectedPath(normalized)
            }
        }

        // 4. Explicitly block manual deletion of CoreSimulator/Devices folders (must use xcrun simctl)
        if normalized == "\(homeDirectory)/Library/Developer/CoreSimulator/Devices" ||
           normalized.hasPrefix("\(homeDirectory)/Library/Developer/CoreSimulator/Devices/") {
            throw SafetyError.notInExplicitAllowList(normalized)
        }

        // 5. Explicitly block manual deletion of Claude/Codex root or session files
        let claudeRoot = "\(homeDirectory)/Library/Application Support/Claude"
        let codexRoot = "\(homeDirectory)/Library/Application Support/Codex"
        if normalized == claudeRoot || normalized == codexRoot {
            throw SafetyError.forbiddenProtectedPath(normalized)
        }

        // 6. Check explicit allow-list
        let isAllowed = allowedRootPrefixes.contains { allowed in
            normalized == allowed || normalized.hasPrefix(allowed + "/")
        }
        guard isAllowed else {
            throw SafetyError.notInExplicitAllowList(normalized)
        }

        // 7. If file exists on disk and symlink resolution is enabled, verify resolved realpath is ALSO allowed
        if checkSymlinksOnDisk && FileManager.default.fileExists(atPath: normalized) {
            let url = URL(fileURLWithPath: normalized)
            let resolved = url.resolvingSymlinksInPath().path
            if resolved != normalized {
                let resolvedAllowed = allowedRootPrefixes.contains { allowed in
                    let resolvedAllowedPrefix = URL(fileURLWithPath: allowed).resolvingSymlinksInPath().path
                    return resolved == resolvedAllowedPrefix || resolved.hasPrefix(resolvedAllowedPrefix + "/")
                }
                if !resolvedAllowed {
                    throw SafetyError.symlinkTraversalRejected("\(normalized) -> \(resolved)")
                }
            }
        }

        return normalized
    }

    /// Inspects a directory subtree (including hidden files) to verify it does not contain any forbidden components (e.g. .git, .env, credentials) or symlinks escaping the allow-list.
    public func validateSubtreeForDeletion(_ validatedPath: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: validatedPath, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        let rootURL = URL(fileURLWithPath: validatedPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let childURL as URL in enumerator {
            let name = childURL.lastPathComponent
            if isForbiddenComponentName(name) {
                throw SafetyError.forbiddenFileOrComponent(childURL.path)
            }
            if let vals = try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
                let resolved = childURL.resolvingSymlinksInPath().path
                let resolvedAllowed = allowedRootPrefixes.contains { allowed in
                    let resolvedAllowedPrefix = URL(fileURLWithPath: allowed).resolvingSymlinksInPath().path
                    return resolved == resolvedAllowedPrefix || resolved.hasPrefix(resolvedAllowedPrefix + "/")
                }
                if !resolvedAllowed {
                    throw SafetyError.symlinkTraversalRejected("\(childURL.path) -> \(resolved)")
                }
            }
        }
    }

    public func isSafeToDelete(_ rawPath: String, checkSymlinksOnDisk: Bool = true) -> Bool {
        do {
            _ = try validateForDeletion(rawPath, checkSymlinksOnDisk: checkSymlinksOnDisk)
            return true
        } catch {
            return false
        }
    }
}
