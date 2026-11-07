import Foundation

public enum SafetyError: LocalizedError, Equatable {
    case emptyOrInvalidPath
    case containsParentTraversal(String)
    case symlinkTraversalRejected(String)
    case forbiddenProtectedPath(String)
    case forbiddenFileOrComponent(String)
    case notInExplicitAllowList(String)
    case virtualOrMountedFilesystem(String)
    case unverifiedProjectArtifact(String)
    case unverifiedWorktree(String)
    case modifiedSinceScan(String)

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
        case .unverifiedProjectArtifact(let p):
            return "SAFETY BLOCK: Project path does not match an explicitly verified regenerable artifact rule: \(p)"
        case .unverifiedWorktree(let p):
            return "SAFETY BLOCK: Directory is not a verified Git worktree with valid Git metadata: \(p)"
        case .modifiedSinceScan(let p):
            return "SAFETY BLOCK: Path was modified after the scan completed; re-scan before cleaning: \(p)"
        }
    }
}

public enum VerifiedProjectArtifactKind: String, Sendable, Equatable {
    case nextBuild = "Next.js Build (.next)"
    case expoCache = "Expo Cache (.expo)"
    case turboCache = "Turborepo Cache (.turbo)"
    case metroCache = "Metro Bundler Cache"
    case parcelOrLinterCache = "Bundler / Linter Cache"
    case swiftPMBuild = "SwiftPM Build (.build)"
    case gradleProjectCache = "Gradle Project Cache (.gradle)"
    case gradleBuildOutput = "Android / Gradle Build Output"
    case xcodeDerivedData = "Local Xcode DerivedData"
    case xcodeSymrootBuild = "Local Xcode Build Intermediates (SYMROOT)"
    case localPackageManagerCache = "Local Package Manager Cache"
    case xcresultBundle = "Xcode Test Result Bundle (.xcresult)"
    case tarballCache = "Local Tarball Cache"
    case nodeModules = "Node.js Dependencies (node_modules)"
    case cocoaPods = "CocoaPods Dependencies (Pods)"

    public var defaultRiskLevel: RiskLevel {
        switch self {
        case .nextBuild, .expoCache, .turboCache, .metroCache, .parcelOrLinterCache,
             .swiftPMBuild, .gradleProjectCache, .gradleBuildOutput,
             .xcodeDerivedData, .xcodeSymrootBuild, .localPackageManagerCache:
            return .safe
        case .xcresultBundle, .tarballCache, .nodeModules, .cocoaPods:
            return .review
        }
    }
}

public struct SafetyValidator: Sendable {
    public let homeDirectory: String
    public let additionalAllowedPrefixes: [String]

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        additionalAllowedPrefixes: [String] = []
    ) {
        if homeDirectory.hasSuffix("/") && homeDirectory.count > 1 {
            self.homeDirectory = String(homeDirectory.dropLast())
        } else {
            self.homeDirectory = homeDirectory
        }
        self.additionalAllowedPrefixes = additionalAllowedPrefixes.map { raw in
            var s = URL(fileURLWithPath: raw).standardizedFileURL.path
            if s.hasSuffix("/") && s.count > 1 {
                s = String(s.dropLast())
            }
            return s
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
            "\(homeDirectory)/Library/Developer/Xcode/Archives",
            "\(homeDirectory)/Library/Developer/Xcode/UserData",
            "\(homeDirectory)/Library/Android/sdk/ndk",
            "\(homeDirectory)/Library/Android/sdk/system-images",
            "\(homeDirectory)/Library/Android/sdk/platforms",
            "\(homeDirectory)/Library/Android/sdk/build-tools",
            "\(homeDirectory)/Library/Android/sdk/emulator",
            "\(homeDirectory)/.android/avd",
            "\(homeDirectory)/Library/Containers/com.docker.docker",
            "\(homeDirectory)/Library/Application Support/Claude/local-agent-mode-sessions",
            "\(homeDirectory)/Library/Application Support/Claude/claude-code-sessions",
            "\(homeDirectory)/Library/Application Support/Claude/claude-code-vm",
            "\(homeDirectory)/Library/Application Support/Claude/vm_bundles",
            "\(homeDirectory)/Library/Application Support/Codex/artifact-sessions",
            "\(homeDirectory)/Library/Application Support/Codex/Default",
            "\(homeDirectory)/Library/Application Support/Code/User",
            "\(homeDirectory)/Library/Application Support/Code/Backups",
            "\(homeDirectory)/Library/Application Support/Antigravity/User",
            "\(homeDirectory)/Library/Application Support/Antigravity/Backups",
            "\(homeDirectory)/Library/Application Support/Cursor/User",
            "\(homeDirectory)/Library/Application Support/Cursor/Backups",
            "\(homeDirectory)/Library/Application Support/Notion/Partitions",
            "\(homeDirectory)/Library/Application Support/Google/Chrome",
            "\(homeDirectory)/Library/Application Support/Google/DriveFS",
            "\(homeDirectory)/Library/Application Support/OutSystems",
            "/Library/Developer/CoreSimulator/Volumes",
            "/System",
            "/Users/Shared",
            "/Applications"
        ]
    }

    /// Explicitly allowed prefixes where deletion (Trash or subdirectories) is permitted.
    public var allowedRootPrefixes: [String] {
        var prefixes: [String] = [
            "\(homeDirectory)/Library/Developer/Xcode/DerivedData",
            "\(homeDirectory)/Library/Developer/Xcode/DocumentationCache",
            "\(homeDirectory)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(homeDirectory)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(homeDirectory)/Library/Logs/CoreSimulator",
            "\(homeDirectory)/Library/Logs/Claude",
            "\(homeDirectory)/Library/Logs/com.openai.codex",
            "\(homeDirectory)/Library/Logs/Xcode",
            "\(homeDirectory)/Library/Logs/Antigravity",
            "\(homeDirectory)/Library/Logs/GitHubCopilot",
            "\(homeDirectory)/Library/Caches/com.apple.dt.Xcode",
            "\(homeDirectory)/Library/Caches/org.swift.swiftpm",
            "\(homeDirectory)/Library/Caches/CocoaPods",
            "\(homeDirectory)/Library/Caches/Homebrew",
            "\(homeDirectory)/Library/Caches/Codex",
            "\(homeDirectory)/Library/Caches/Google/Cache",
            "\(homeDirectory)/Library/Caches/Google/Code Cache",
            "\(homeDirectory)/Library/Caches/Google/GPUCache",
            "\(homeDirectory)/Library/Caches/pip",
            "\(homeDirectory)/Library/Caches/Yarn",
            "\(homeDirectory)/Library/Caches/pnpm",
            "\(homeDirectory)/Library/Caches/ms-playwright",
            "\(homeDirectory)/Library/Caches/ms-playwright-go",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/Cache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/Code Cache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/GPUCache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/fsCachedData",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/com.onevcat.Kingfisher.ImageCache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/browser-data/Cache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/browser-data/Code Cache",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/browser-data/GPUCache",
            "\(homeDirectory)/Library/Caches/dotslash",
            "\(homeDirectory)/Library/Caches/com.google.antigravity",
            "\(homeDirectory)/Library/Caches/com.google.GeminiMacOS",
            "\(homeDirectory)/Library/Caches/antigravity-updater",
            "\(homeDirectory)/Library/Caches/notion-updater",
            "\(homeDirectory)/Library/Caches/ReactNative",
            "\(homeDirectory)/Library/Caches/node-gyp",
            "\(homeDirectory)/Library/Caches/com.openai.chat",
            "\(homeDirectory)/Library/Caches/typescript",
            "\(homeDirectory)/Library/Caches/statsig-cache",
            "\(homeDirectory)/.gradle/caches",
            "\(homeDirectory)/.gradle/daemon",
            "\(homeDirectory)/.npm/_cacache",
            "\(homeDirectory)/.npm/_npx",
            "\(homeDirectory)/.npm/_logs",
            "\(homeDirectory)/.cache/codex-runtimes",
            "\(homeDirectory)/.cache/puppeteer",
            "\(homeDirectory)/.cache/firebase/emulators",
            "\(homeDirectory)/.cache/node",
            "\(homeDirectory)/.cache/node/corepack",
            "\(homeDirectory)/.cache/pkg",
            "\(homeDirectory)/.cache/mesa_shader_cache",
            "\(homeDirectory)/.android/cache",
            "\(homeDirectory)/Library/Android/sdk/.temp",
            "\(homeDirectory)/Library/Application Support/Claude/Cache",
            "\(homeDirectory)/Library/Application Support/Claude/Code Cache",
            "\(homeDirectory)/Library/Application Support/Claude/GPUCache",
            "\(homeDirectory)/Library/Application Support/Claude/DawnWebGPUCache",
            "\(homeDirectory)/Library/Application Support/Claude/DawnGraphiteCache",
            "\(homeDirectory)/Library/Application Support/Claude/GraphiteDawnCache",
            "\(homeDirectory)/Library/Application Support/Claude/GPUPersistentCache",
            "\(homeDirectory)/Library/Application Support/Claude/ShaderCache",
            "\(homeDirectory)/Library/Application Support/Claude/Crashpad",
            "\(homeDirectory)/Library/Application Support/Claude/claude-code",
            "\(homeDirectory)/Library/Application Support/Claude/simulator-builds",
            "\(homeDirectory)/Library/Application Support/Codex/Cache",
            "\(homeDirectory)/Library/Application Support/Codex/Code Cache",
            "\(homeDirectory)/Library/Application Support/Codex/GPUCache",
            "\(homeDirectory)/Library/Application Support/Codex/DawnWebGPUCache",
            "\(homeDirectory)/Library/Application Support/Codex/DawnGraphiteCache",
            "\(homeDirectory)/Library/Application Support/Codex/GraphiteDawnCache",
            "\(homeDirectory)/Library/Application Support/Codex/GrShaderCache",
            "\(homeDirectory)/Library/Application Support/Codex/GPUPersistentCache",
            "\(homeDirectory)/Library/Application Support/Codex/ShaderCache",
            "\(homeDirectory)/Library/Application Support/Codex/Crashpad",
            "\(homeDirectory)/Library/Application Support/com.google.AIEdgeForesight/models",
            "\(homeDirectory)/Library/Application Support/com.google.AIEdgeForesight/model_cache",
            "\(homeDirectory)/Library/Application Support/Google/GoogleUpdater/crx_cache"
        ]

        let electronSubcaches = [
            "Cache",
            "Code Cache",
            "GPUCache",
            "DawnWebGPUCache",
            "DawnGraphiteCache",
            "GraphiteDawnCache",
            "GPUPersistentCache",
            "ShaderCache",
            "CachedData",
            "CachedExtensionVSIXs",
            "logs",
            "Crashpad"
        ]
        for app in ["Code", "Antigravity", "Cursor"] {
            for sub in electronSubcaches {
                prefixes.append("\(homeDirectory)/Library/Application Support/\(app)/\(sub)")
            }
        }
        for sub in ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "ShaderCache", "Crashpad"] {
            prefixes.append("\(homeDirectory)/Library/Application Support/Notion/\(sub)")
        }
        prefixes.append(contentsOf: additionalAllowedPrefixes)

        return prefixes
    }

    /// Forbidden path components anywhere in the path
    public let forbiddenComponents: Set<String> = [
        ".git",
        ".env",
        ".env.local",
        ".env.production",
        ".npmrc",
        ".ssh",
        ".gnupg",
        ".aws",
        ".gitconfig",
        "Keychains",
        "GoogleService-Info.plist",
        "google-services.json",
        "firebase-adminsdk.json",
        "application_default_credentials.json",
        "service-account.json",
        "service_account.json",
        "credentials.json",
        "client_secret.json",
        "Docker.raw",
        "rootfs.img",
        "sessiondata.img",
        "claudevm.bundle",
        "ca.pem",
        "server.pem",
        "privkey.pem",
        "fullchain.pem",
        "id_rsa",
        "id_ed25519"
    ]

    private let sensitiveJSONTokens: [String] = [
        "service-account",
        "service_account",
        "adminsdk",
        "credential",
        "client_secret",
        "private_key",
        "private-key"
    ]

    private let forbiddenExtensions: [String] = [
        ".p12",
        ".pfx",
        ".jks",
        ".keystore",
        ".mobileprovision",
        ".mobileconfig",
        ".csr",
        ".xcarchive",
        ".ipa"
    ]

    public func isForbiddenComponentName(_ comp: String) -> Bool {
        if forbiddenComponents.contains(comp) {
            return true
        }
        let lower = comp.lowercased()
        if lower == "googleservice-info.plist" || lower == "google-services.json" {
            return true
        }
        if lower == "release.apk" || lower.hasSuffix("-release.apk") || lower.hasSuffix("_release.apk") {
            return true
        }
        if comp.hasPrefix(".env.") {
            return true
        }
        for ext in forbiddenExtensions {
            if lower.hasSuffix(ext) {
                return true
            }
        }
        if lower.hasSuffix(".json") {
            // Exclude .NET runtime metadata files (e.g. git-credential-manager.runtimeconfig.json / .deps.json)
            if lower.hasSuffix(".runtimeconfig.json") || lower.hasSuffix(".deps.json") {
                return false
            }
            for token in sensitiveJSONTokens {
                if lower.contains(token) {
                    return true
                }
            }
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

        let protectedRoots: Set<String> = [
            "/",
            homeDirectory,
            "\(homeDirectory)/Library",
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/Application Support",
            "\(homeDirectory)/Library/Developer",
            "\(homeDirectory)/Library/Containers",
            "\(homeDirectory)/Library/Logs",
            "\(homeDirectory)/.cache",
            "\(homeDirectory)/.npm",
            "\(homeDirectory)/.gradle",
            "\(homeDirectory)/.android",
            "\(homeDirectory)/Library/Android",
            "\(homeDirectory)/Library/Android/sdk"
        ]
        if protectedRoots.contains(standardized) {
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

        // 5. Explicitly block manual deletion of whole Application Support app roots and broad cache containers
        let protectedAppSupportRoots: Set<String> = [
            "\(homeDirectory)/Library/Application Support/Claude",
            "\(homeDirectory)/Library/Application Support/Codex",
            "\(homeDirectory)/Library/Application Support/Code",
            "\(homeDirectory)/Library/Application Support/Antigravity",
            "\(homeDirectory)/Library/Application Support/Cursor",
            "\(homeDirectory)/Library/Application Support/Notion",
            "\(homeDirectory)/Library/Application Support/Google",
            "\(homeDirectory)/Library/Application Support/OutSystems",
            "\(homeDirectory)/Library/Caches/com.openai.atlas",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/browser-data",
            "\(homeDirectory)/Library/Caches/com.openai.atlas/browser-data/host",
            "\(homeDirectory)/Library/Caches/Google",
            "\(homeDirectory)/Library/Caches/Google/Chrome",
            "\(homeDirectory)/.cache/firebase"
        ]
        if protectedAppSupportRoots.contains(normalized) {
            throw SafetyError.forbiddenProtectedPath(normalized)
        }

        // 6. Check explicit allow-list, verified dynamic subcaches (Atlas/Google), or verified .litertlm model file in ~/Library/Caches
        let isLitertlmInCaches: Bool = {
            let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
            return parent == "\(homeDirectory)/Library/Caches" && normalized.lowercased().hasSuffix(".litertlm")
        }()
        let isAllowed = isLitertlmInCaches
            || isAllowedVerifiedSubcachePath(normalized)
            || allowedRootPrefixes.contains { allowed in
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
                let resolvedAllowed = isAllowedVerifiedSubcachePath(resolved) || allowedRootPrefixes.contains { allowed in
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

    /// Matches verified regenerable dynamic subcaches inside com.openai.atlas/browser-data/host/* and Google/Chrome/*
    public func isAllowedVerifiedSubcachePath(_ normalizedPath: String) -> Bool {
        let resolvedHome = URL(fileURLWithPath: homeDirectory).resolvingSymlinksInPath().path
        let homeCandidates = Set([homeDirectory, resolvedHome])

        let allowedAtlasHostSubcaches: Set<String> = ["Cache", "Code Cache", "GPUCache"]
        let allowedGoogleChromeSubcaches: Set<String> = ["Cache", "Code Cache", "GPUCache", "image_cache"]

        for baseHome in homeCandidates {
            let atlasHostPrefix = "\(baseHome)/Library/Caches/com.openai.atlas/browser-data/host/"
            if normalizedPath.hasPrefix(atlasHostPrefix) {
                let remainder = String(normalizedPath.dropFirst(atlasHostPrefix.count))
                let parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let hostSegment = parts[0]
                    let subcacheSegment = parts[1]
                    if !hostSegment.isEmpty && hostSegment != "." && hostSegment != ".." &&
                        allowedAtlasHostSubcaches.contains(subcacheSegment) &&
                        !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                        return true
                    }
                }
            }

            let googleChromePrefix = "\(baseHome)/Library/Caches/Google/Chrome/"
            if normalizedPath.hasPrefix(googleChromePrefix) {
                let remainder = String(normalizedPath.dropFirst(googleChromePrefix.count))
                let parts = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let profileSegment = parts[0]
                    let subcacheSegment = parts[1]
                    if !profileSegment.isEmpty && profileSegment != "." && profileSegment != ".." &&
                        allowedGoogleChromeSubcaches.contains(subcacheSegment) &&
                        !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    public func validateNotModifiedSinceScan(_ validatedPath: String, expectedModifiedAt: Date?) throws {
        guard let expectedModifiedAt, FileManager.default.fileExists(atPath: validatedPath) else {
            return
        }
        let url = URL(fileURLWithPath: validatedPath)
        if let modVals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let currentMod = modVals.contentModificationDate,
           currentMod.timeIntervalSince(expectedModifiedAt) > 2.0 {
            throw SafetyError.modifiedSinceScan(validatedPath)
        }
    }

    private func isPermittedDerivedArtifactComponent(name: String, fullPath: String) -> Bool {
        let lower = name.lowercased()
        // Allow SwiftPM package checkout .git directories inside DerivedData/SourcePackages/checkouts/ or .build/checkouts/
        if name == ".git" {
            if fullPath.contains("/SourcePackages/checkouts/") || fullPath.contains("/.build/checkouts/") {
                return true
            }
            return false
        }
        // Allow bundled or dependency-test GoogleService-Info.plist / google-services.json / embedded.mobileprovision inside compiled build outputs or package checkouts
        if lower == "embedded.mobileprovision" {
            return fullPath.contains("/Build/Products/") || fullPath.contains("/Build/Intermediates.noindex/")
        }
        if lower == "googleservice-info.plist" || lower == "google-services.json" {
            if fullPath.contains("/SourcePackages/checkouts/") ||
               fullPath.contains("/Build/Products/") ||
               fullPath.contains("/Build/Intermediates.noindex/") ||
               fullPath.contains("/intermediates/") ||
               fullPath.contains("/generated/") ||
               fullPath.contains("/node_modules/") ||
               fullPath.contains("/Pods/") {
                return true
            }
            return false
        }
        return false
    }

    /// Inspects a directory subtree (including hidden files) to verify it does not contain any forbidden components (e.g. .git, .env, credentials) or symlinks escaping the allow-list.
    public func validateSubtreeForDeletion(_ validatedPath: String, additionalAllowedRoots: [String] = []) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: validatedPath, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        let effectiveAllowedRoots = allowedRootPrefixes + additionalAllowedRoots
        let resolvedAllowedPrefixes = effectiveAllowedRoots.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
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
            let childPath = childURL.path
            if isForbiddenComponentName(name) {
                if isPermittedDerivedArtifactComponent(name: name, fullPath: childPath) {
                    if name == ".git" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                throw SafetyError.forbiddenFileOrComponent(childPath)
            }
            if let vals = try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
                let resolved = childURL.resolvingSymlinksInPath().path
                let resolvedAllowed = isAllowedVerifiedSubcachePath(resolved) || resolvedAllowedPrefixes.contains { resolvedAllowedPrefix in
                    resolved == resolvedAllowedPrefix || resolved.hasPrefix(resolvedAllowedPrefix + "/")
                }
                if !resolvedAllowed {
                    let isBrokenTempBuildSymlink = !FileManager.default.fileExists(atPath: resolved) &&
                        (resolved.hasPrefix("/private/var/folders/") || resolved.hasPrefix("/var/folders/"))
                    if !isBrokenTempBuildSymlink {
                        throw SafetyError.symlinkTraversalRejected("\(childPath) -> \(resolved)")
                    }
                }
            }
        }
    }

    /// Verifies on disk whether a directory inside a developer project matches an explicit, regenerable artifact rule.
    public static func verifyCleanableProjectArtifact(
        at rawPath: String,
        projectRoot rawProjectRoot: String
    ) -> VerifiedProjectArtifactKind? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let rootURL = URL(fileURLWithPath: rawProjectRoot).standardizedFileURL
        let path = url.path
        let rootPath = rootURL.path

        guard path.hasPrefix(rootPath + "/"), path != rootPath else {
            return nil
        }

        // Reject top-level symlinks
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            return nil
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Never allow anything inside a .git directory
        let relativeComponents = String(path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        if relativeComponents.contains(".git") {
            return nil
        }

        let name = url.lastPathComponent
        let parentURL = url.deletingLastPathComponent()
        let parentPath = parentURL.path

        func parentHasAny(_ filenames: [String]) -> Bool {
            filenames.contains { fm.fileExists(atPath: parentURL.appendingPathComponent($0).path) }
        }

        func directoryHasAny(_ filenames: [String]) -> Bool {
            filenames.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        }

        func topLevelEntries() -> [String] {
            (try? fm.contentsOfDirectory(atPath: path)) ?? []
        }

        // 1. Next.js (.next)
        if name == ".next" && parentHasAny(["package.json", "next.config.js", "next.config.mjs", "next.config.ts"]) {
            return .nextBuild
        }

        // 2. Expo (.expo)
        if name == ".expo" && parentHasAny(["package.json", "app.json", "app.config.js", "app.config.ts"]) {
            return .expoCache
        }

        // 3. Turborepo (.turbo)
        if name == ".turbo" && parentHasAny(["package.json", "turbo.json"]) {
            return .turboCache
        }

        // 4. Metro (.metro / .metro-cache)
        if (name == ".metro" || name == ".metro-cache") &&
            parentHasAny(["package.json", "metro.config.js", "metro.config.cjs"]) {
            return .metroCache
        }

        // 5. Parcel / ESLint cache
        if (name == ".parcel-cache" || name == ".eslintcache") && parentHasAny(["package.json"]) {
            return .parcelOrLinterCache
        }

        // 6. SwiftPM (.build)
        if name == ".build" && (parentHasAny(["Package.swift"]) || directoryHasAny(["workspace-state.json", "checkouts", "repositories", "debug", "release"])) {
            // Ensure no source files or Xcode project at top level
            let entries = topLevelEntries()
            let hasProtected = entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".swift") }
            if !hasProtected {
                return .swiftPMBuild
            }
        }

        // 7. Gradle project cache (.gradle)
        if name == ".gradle" && parentHasAny(["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]) {
            return .gradleProjectCache
        }

        // 8. Android / Gradle build directory (build with sibling build.gradle and Gradle markers)
        if name == "build" && parentHasAny(["build.gradle", "build.gradle.kts"]) &&
            directoryHasAny(["intermediates", "generated", "outputs", "tmp", "kotlin"]) {
            return .gradleBuildOutput
        }

        // 9. Xcode .xcresult bundle
        if name.hasSuffix(".xcresult") && directoryHasAny(["Info.plist"]) && directoryHasAny(["Data"]) {
            return .xcresultBundle
        }

        // 10. Node dependencies (node_modules)
        if name == "node_modules" && parentHasAny(["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb"]) {
            return .nodeModules
        }

        // 11. CocoaPods dependencies (Pods)
        if name == "Pods" && (parentHasAny(["Podfile", "Podfile.lock"]) || directoryHasAny(["Manifest.lock", "Target Support Files"])) {
            return .cocoaPods
        }

        // 12. Local .cache package manager subdirectories (.cache/npm, .cache/pnpm, .cache/corepack, .cache/yarn, .cache/metro)
        if parentURL.lastPathComponent == ".cache" {
            if name == "npm" && directoryHasAny(["_cacache", "_logs", "_npx"]) {
                return .localPackageManagerCache
            }
            if name == "pnpm" && directoryHasAny(["store", "cache", "metadata", "dlx"]) {
                return .localPackageManagerCache
            }
            if name == "corepack" && directoryHasAny(["v1", "lastKnownGood.json"]) {
                return .localPackageManagerCache
            }
            if name == "yarn" && directoryHasAny(["v6", ".roadrunner.json"]) {
                return .localPackageManagerCache
            }
            if name == "metro" || name == "metro-cache" {
                return .metroCache
            }
            if name == "tarballs" {
                let entries = topLevelEntries().filter { $0 != ".DS_Store" }
                if !entries.isEmpty && entries.allSatisfy({ $0.hasSuffix(".tgz") || $0.hasSuffix(".tar.gz") }) {
                    return .tarballCache
                }
            }
        }

        // 13. Verified Local Xcode DerivedData directory (info.plist + Build / ModuleCache.noindex / CompilationCache.noindex / SDKStatCaches.noindex)
        let entries = topLevelEntries()
        let hasDerivedPlist = entries.contains { $0.caseInsensitiveCompare("info.plist") == .orderedSame }
        let hasDerivedMarker = directoryHasAny([
            "Build",
            "ModuleCache.noindex",
            "CompilationCache.noindex",
            "SDKStatCaches.noindex",
            "Index.noindex"
        ])
        let hasSourceMarkers = entries.contains {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".swift") ||
            $0 == "package.json" || $0 == "src" || $0 == ".git"
        }
        if hasDerivedPlist && hasDerivedMarker && !hasSourceMarkers && parentPath != rootPath {
            return .xcodeDerivedData
        }

        // 14. Verified Local Xcode SYMROOT / OBJROOT build directory (XCBuildData + build intermediates, no sources)
        let hasXCBuildData = directoryHasAny(["XCBuildData"])
        let hasSymrootSiblings = directoryHasAny([
            "Pods.build",
            "ExplicitPrecompiledModules",
            "EagerLinkingTBDs",
            "Debug-iphonesimulator",
            "Release-iphonesimulator",
            "Debug-iphoneos",
            "Release-iphoneos"
        ]) || entries.contains(where: { $0.hasSuffix(".build") })
        if hasXCBuildData && hasSymrootSiblings && !hasSourceMarkers {
            return .xcodeSymrootBuild
        }

        return nil
    }

    /// Validates a verified project artifact immediately before moving to Trash.
    public func validateVerifiedProjectArtifactForDeletion(
        _ rawPath: String,
        projectRoot rawProjectRoot: String,
        expectedModifiedAt: Date? = nil,
        checkSymlinksOnDisk: Bool = true
    ) throws -> String {
        let normalizedPath = try expandAndNormalize(rawPath)
        let normalizedRoot = try expandAndNormalize(rawProjectRoot)

        guard normalizedPath.hasPrefix(normalizedRoot + "/"), normalizedPath != normalizedRoot else {
            throw SafetyError.forbiddenProtectedPath(normalizedPath)
        }

        // Never allow projectRoot to be a system or sensitive credential root
        let sensitiveRoots = [
            "\(homeDirectory)/.ssh",
            "\(homeDirectory)/.gnupg",
            "\(homeDirectory)/.aws",
            "\(homeDirectory)/Documents",
            "\(homeDirectory)/Desktop",
            "\(homeDirectory)/Downloads",
            "\(homeDirectory)/Library",
            "/System",
            "/Applications",
            "/Library"
        ]
        for sRoot in sensitiveRoots {
            if normalizedRoot == sRoot || normalizedRoot.hasPrefix(sRoot + "/") ||
               normalizedPath == sRoot || normalizedPath.hasPrefix(sRoot + "/") {
                throw SafetyError.forbiddenProtectedPath(normalizedPath)
            }
        }

        // Check forbidden components in the relative path from projectRoot
        let relativePath = String(normalizedPath.dropFirst(normalizedRoot.count + 1))
        for comp in relativePath.split(separator: "/").map(String.init) {
            if isForbiddenComponentName(comp) {
                throw SafetyError.forbiddenFileOrComponent(normalizedPath)
            }
        }

        if checkSymlinksOnDisk && FileManager.default.fileExists(atPath: normalizedPath) {
            let url = URL(fileURLWithPath: normalizedPath)
            if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
                throw SafetyError.symlinkTraversalRejected(normalizedPath)
            }
            let resolvedPath = url.resolvingSymlinksInPath().path
            let resolvedRoot = URL(fileURLWithPath: normalizedRoot).resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(resolvedRoot + "/") && resolvedPath != resolvedRoot else {
                throw SafetyError.symlinkTraversalRejected("\(normalizedPath) -> \(resolvedPath)")
            }

            if let expectedModifiedAt {
                if let modVals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let currentMod = modVals.contentModificationDate,
                   currentMod.timeIntervalSince(expectedModifiedAt) > 2.0 {
                    throw SafetyError.modifiedSinceScan(normalizedPath)
                }
            }
        }

        guard Self.verifyCleanableProjectArtifact(at: normalizedPath, projectRoot: normalizedRoot) != nil else {
            throw SafetyError.unverifiedProjectArtifact(normalizedPath)
        }

        if checkSymlinksOnDisk && FileManager.default.fileExists(atPath: normalizedPath) {
            try validateSubtreeForDeletion(normalizedPath, additionalAllowedRoots: [normalizedRoot])
        }

        return normalizedPath
    }

    // MARK: - AI Worktree Verification & Artifact Safety Validation

    public struct VerifiedWorktreeArtifactMatch: Sendable, Equatable {
        public let artifactType: WorktreeArtifactType
        public let classification: RiskLevel
        public let reason: String
        public let reproducibilitySource: String?

        public init(
            artifactType: WorktreeArtifactType,
            classification: RiskLevel,
            reason: String,
            reproducibilitySource: String? = nil
        ) {
            self.artifactType = artifactType
            self.classification = classification
            self.reason = reason
            self.reproducibilitySource = reproducibilitySource
        }
    }

    /// Verifies using Git metadata on disk that `rawWorktreePath` is an actual Git worktree (not an arbitrary directory or main repo).
    public static func verifyWorktreeGitMetadata(
        at rawWorktreePath: String,
        isRegisteredLinkedWorktree: Bool = false
    ) -> (isVerified: Bool, sourceRepoPath: String?, gitDirPath: String?) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: rawWorktreePath).standardizedFileURL
        let path = url.path

        // Reject if worktree root itself is a symbolic link
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            return (false, nil, nil)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return (false, nil, nil)
        }

        let dotGitURL = url.appendingPathComponent(".git")
        var dotGitIsDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGitURL.path, isDirectory: &dotGitIsDir) else {
            return (false, nil, nil)
        }

        if !dotGitIsDir.boolValue {
            // Standard Git worktree: `.git` is a regular file containing `gitdir: <path>`
            guard let rawContent = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
                return (false, nil, nil)
            }
            let lines = rawContent.components(separatedBy: .newlines)
            guard let gitdirLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:") }) else {
                return (false, nil, nil)
            }
            let targetRaw = gitdirLine
                .trimmingCharacters(in: .whitespaces)
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetRaw.isEmpty else {
                return (false, nil, nil)
            }

            let resolvedGitDirURL: URL
            if targetRaw.hasPrefix("/") {
                resolvedGitDirURL = URL(fileURLWithPath: targetRaw).standardizedFileURL
            } else {
                resolvedGitDirURL = URL(fileURLWithPath: targetRaw, relativeTo: url).standardizedFileURL
            }
            let resolvedGitDirPath = resolvedGitDirURL.path

            // Derive source repository path from `/.git/worktrees/<name>` or `commondir`
            var sourceRepoPath: String? = nil
            if let range = resolvedGitDirPath.range(of: "/.git/worktrees/") {
                sourceRepoPath = String(resolvedGitDirPath[..<range.lowerBound])
            } else {
                let commonDirFile = resolvedGitDirURL.appendingPathComponent("commondir")
                if let commonRaw = try? String(contentsOf: commonDirFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !commonRaw.isEmpty {
                    let commonURL = commonRaw.hasPrefix("/")
                        ? URL(fileURLWithPath: commonRaw).standardizedFileURL
                        : URL(fileURLWithPath: commonRaw, relativeTo: resolvedGitDirURL).standardizedFileURL
                    if commonURL.lastPathComponent == ".git" {
                        sourceRepoPath = commonURL.deletingLastPathComponent().path
                    } else {
                        sourceRepoPath = commonURL.path
                    }
                }
            }

            let hasValidGitDirMetadata = fm.fileExists(atPath: resolvedGitDirURL.appendingPathComponent("HEAD").path)
                || fm.fileExists(atPath: resolvedGitDirURL.appendingPathComponent("commondir").path)
                || resolvedGitDirPath.contains("/.git/worktrees/")
                || isRegisteredLinkedWorktree

            guard hasValidGitDirMetadata else {
                return (false, nil, nil)
            }
            return (true, sourceRepoPath, resolvedGitDirPath)
        } else {
            // `.git` is a directory: only valid as an AI worktree if located inside `.claude/worktrees/` or `.codex/worktrees/` or explicitly registered
            let isInAIWorktreeContainer = path.contains("/.claude/worktrees/") || path.contains("/.codex/worktrees/")
            guard isInAIWorktreeContainer || isRegisteredLinkedWorktree else {
                return (false, nil, nil)
            }
            let headURL = dotGitURL.appendingPathComponent("HEAD")
            guard let headContent = try? String(contentsOf: headURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  headContent.hasPrefix("ref: ") || headContent.count >= 7 else {
                return (false, nil, nil)
            }
            var sourceRepoPath: String? = nil
            if let range = path.range(of: "/.claude/worktrees/") {
                sourceRepoPath = String(path[..<range.lowerBound])
            }
            return (true, sourceRepoPath, dotGitURL.path)
        }
    }

    public func isProtectedWorktreeComponent(
        _ comp: String,
        fullPath: String = "",
        isInsideDependencyDir: Bool = false
    ) -> Bool {
        if isForbiddenComponentName(comp) {
            if isPermittedDerivedArtifactComponent(name: comp, fullPath: fullPath) {
                return false
            }
            return true
        }

        let lower = comp.lowercased()

        // Never delete any .env* file
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") {
            return true
        }

        // Credentials & auth tokens
        let protectedFiles: Set<String> = [
            ".npmrc",
            ".pypirc",
            ".netrc",
            "secrets.json",
            "secret.json",
            "auth.json",
            "local.settings.json"
        ]
        if protectedFiles.contains(lower) {
            return true
        }

        // Certificates, provisioning & private keys
        let certExtensions = [
            ".pem", ".crt", ".p12", ".pfx", ".jks", ".keystore",
            ".mobileprovision", ".provisionprofile", ".mobileconfig", ".csr", ".signing"
        ]
        for ext in certExtensions {
            if lower.hasSuffix(ext) {
                return true
            }
        }

        // Never automatically classify archives, distribution packages, signed apps, or dSYMs as SAFE inside worktree build directories
        if !isInsideDependencyDir {
            let distributionAndSymbolExtensions = [
                ".xcarchive", ".ipa", ".dsym", ".aab", ".pkg", ".dmg"
            ]
            for ext in distributionAndSymbolExtensions {
                if lower.hasSuffix(ext) {
                    return true
                }
            }
            if lower == "_codesignature" || lower == "coderesources" {
                return true
            }
            let distributionEvidenceFiles: Set<String> = [
                "distributionsummary.plist",
                "exportoptions.plist",
                "packaging.log",
                "appstoreinfo.plist"
            ]
            if distributionEvidenceFiles.contains(lower) {
                return true
            }
        }

        // Databases & local emulator exports
        let dbExtensions = [".sqlite", ".sqlite3", ".db", ".db-shm", ".db-wal", ".realm"]
        for ext in dbExtensions {
            if lower.hasSuffix(ext) {
                // Allow internal build/package index databases inside verified Xcode build intermediates, package manager stores, or third-party node_modules/Pods packages
                if isInsideDependencyDir ||
                   fullPath.contains("/XCBuildData/") ||
                   fullPath.contains("/Index.noindex/") ||
                   fullPath.contains("/CompilationCache.noindex/") ||
                   fullPath.contains("/.cache/pnpm/") ||
                   fullPath.contains("/.cache/npm/") ||
                   fullPath.contains("/.cache/yarn/") {
                    return false
                }
                return true
            }
        }
        if lower.hasPrefix("firebase-export") || lower.hasPrefix("firestore-export") {
            return true
        }

        // Migrations, uploads, user-generated data, and QA evidence outside third-party node_modules/Pods packages
        if !isInsideDependencyDir {
            let protectedDirNames: Set<String> = [
                "migrations",
                "migration",
                "uploads",
                "user_uploads",
                "user-data",
                "userdata",
                "local-data",
                "qa-evidence",
                "evidence"
            ]
            if protectedDirNames.contains(lower) || lower.contains("evidence") {
                return true
            }
        }

        return false
    }

    /// Validates that `validatedPath` inside `validatedWorktreeRoot` contains no protected files (.env*, databases, certs, credentials, migrations, uploads, QA evidence) and no symlinks escaping `validatedWorktreeRoot`.
    public func validateWorktreeSubtreeForDeletion(
        _ validatedPath: String,
        worktreeRoot validatedWorktreeRoot: String
    ) throws {
        let fm = FileManager.default
        let resolvedWorktreeRoot = URL(fileURLWithPath: validatedWorktreeRoot).resolvingSymlinksInPath().standardizedFileURL.path
        let lexicalWorktreeRoot = URL(fileURLWithPath: validatedWorktreeRoot).standardizedFileURL.path

        let itemURL = URL(fileURLWithPath: validatedPath)
        if let vals = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            throw SafetyError.symlinkTraversalRejected(validatedPath)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: validatedPath, isDirectory: &isDir) else {
            return
        }

        let isDepDir = validatedPath.hasSuffix("/node_modules") || validatedPath.contains("/node_modules/") ||
            validatedPath.hasSuffix("/Pods") || validatedPath.contains("/Pods/")

        if !isDir.boolValue {
            let name = itemURL.lastPathComponent
            if isProtectedWorktreeComponent(name, fullPath: validatedPath, isInsideDependencyDir: false) {
                throw SafetyError.forbiddenFileOrComponent(validatedPath)
            }
            return
        }

        guard let enumerator = fm.enumerator(
            at: itemURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let childURL as URL in enumerator {
            let name = childURL.lastPathComponent
            let childPath = childURL.path

            if isProtectedWorktreeComponent(name, fullPath: childPath, isInsideDependencyDir: isDepDir) {
                if name == ".git" && isPermittedDerivedArtifactComponent(name: name, fullPath: childPath) {
                    enumerator.skipDescendants()
                    continue
                }
                throw SafetyError.forbiddenFileOrComponent(childPath)
            }

            if let vals = try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
                // 1. Check lexical symlink destination relative to parent directory (catches broken symlinks escaping via ../)
                if let rawDest = try? fm.destinationOfSymbolicLink(atPath: childPath) {
                    if rawDest.split(separator: "/").contains("..") {
                        let lexicalTarget = URL(fileURLWithPath: rawDest, relativeTo: childURL.deletingLastPathComponent()).standardizedFileURL.path
                        let insideLexical = lexicalTarget == lexicalWorktreeRoot || lexicalTarget.hasPrefix(lexicalWorktreeRoot + "/")
                        let insideResolved = lexicalTarget == resolvedWorktreeRoot || lexicalTarget.hasPrefix(resolvedWorktreeRoot + "/")
                        if !insideLexical && !insideResolved {
                            throw SafetyError.symlinkTraversalRejected("\(childPath) -> \(rawDest)")
                        }
                    } else if rawDest.hasPrefix("/") {
                        let stdTarget = URL(fileURLWithPath: rawDest).standardizedFileURL.path
                        let insideLexical = stdTarget == lexicalWorktreeRoot || stdTarget.hasPrefix(lexicalWorktreeRoot + "/")
                        let insideResolved = stdTarget == resolvedWorktreeRoot || stdTarget.hasPrefix(resolvedWorktreeRoot + "/")
                        if !insideLexical && !insideResolved {
                            throw SafetyError.symlinkTraversalRejected("\(childPath) -> \(rawDest)")
                        }
                    }
                }

                // 2. Check resolved realpath on disk
                let resolvedChild = childURL.resolvingSymlinksInPath().standardizedFileURL.path
                let insideResolved = resolvedChild == resolvedWorktreeRoot || resolvedChild.hasPrefix(resolvedWorktreeRoot + "/")
                let insideLexical = resolvedChild == lexicalWorktreeRoot || resolvedChild.hasPrefix(lexicalWorktreeRoot + "/")
                if !insideResolved && !insideLexical {
                    throw SafetyError.symlinkTraversalRejected("\(childPath) -> \(resolvedChild)")
                }
            }
        }
    }

    /// Inspects an artifact inside a worktree and classifies it as SAFE or REVIEW with a specific project-aware reason.
    public func inspectWorktreeArtifactSafety(
        at rawPath: String,
        worktreeRoot rawWorktreeRoot: String
    ) -> VerifiedWorktreeArtifactMatch? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let rootURL = URL(fileURLWithPath: rawWorktreeRoot).standardizedFileURL
        let path = url.path
        let rootPath = rootURL.path

        guard path.hasPrefix(rootPath + "/"), path != rootPath else {
            return nil
        }

        let relativePath = String(path.dropFirst(rootPath.count + 1))
        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        if relativeComponents.contains(".git") {
            return nil
        }

        let name = url.lastPathComponent
        let parentURL = url.deletingLastPathComponent()

        // Check if top-level candidate is itself a symlink
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            let inferredType = Self.inferWorktreeArtifactType(name: name, relativePath: relativePath) ?? .cache
            return VerifiedWorktreeArtifactMatch(
                artifactType: inferredType,
                classification: .review,
                reason: "Artifact is a symbolic link; skipped to prevent symlink escape outside worktree"
            )
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return nil
        }

        // Check if any component in relativePath is protected
        for comp in relativeComponents {
            let isDep = comp == "node_modules" || comp == "Pods"
            if isProtectedWorktreeComponent(comp, fullPath: path, isInsideDependencyDir: isDep) {
                return nil
            }
        }

        func findFileInParentOrRoot(_ filenames: [String]) -> String? {
            for candidate in filenames {
                if fm.fileExists(atPath: parentURL.appendingPathComponent(candidate).path) {
                    return candidate
                }
            }
            if parentURL.path != rootPath {
                for candidate in filenames {
                    if fm.fileExists(atPath: rootURL.appendingPathComponent(candidate).path) {
                        return candidate
                    }
                }
            }
            return nil
        }

        func directoryHasAny(_ filenames: [String]) -> Bool {
            filenames.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        }

        func topLevelEntries() -> [String] {
            (try? fm.contentsOfDirectory(atPath: path)) ?? []
        }

        func packageJSONHasBuildScript(at dirURL: URL) -> Bool {
            let pkgURL = dirURL.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: pkgURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = json["scripts"] as? [String: Any] else {
                return false
            }
            return scripts.keys.contains { key in
                let k = key.lowercased()
                return k == "build" || k.hasPrefix("build:") || k == "compile" || k == "bundle"
            }
        }

        func isNativeAppleProjectDirectory(_ dirURL: URL) -> Bool {
            let dirName = dirURL.lastPathComponent.lowercased()
            if dirName == "ios" || dirName == "macos" {
                return true
            }
            let siblings = (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []
            return siblings.contains {
                $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Podfile" || $0 == "Podfile.lock"
            }
        }

        func hasRecognizableXcodeBuildStructure(at buildDirURL: URL, topEntries: [String]) -> Bool {
            if let verified = Self.verifyCleanableProjectArtifact(at: buildDirURL.path, projectRoot: rootPath),
               verified == .xcodeDerivedData || verified == .xcodeSymrootBuild || verified == .swiftPMBuild {
                return true
            }
            let hasXCBuildData = fm.fileExists(atPath: buildDirURL.appendingPathComponent("XCBuildData").path) ||
                fm.fileExists(atPath: buildDirURL.appendingPathComponent("Build/Intermediates.noindex/XCBuildData").path)
            let hasIntermediates = fm.fileExists(atPath: buildDirURL.appendingPathComponent("Intermediates.noindex").path) ||
                fm.fileExists(atPath: buildDirURL.appendingPathComponent("Build/Intermediates.noindex").path) ||
                topEntries.contains { $0.hasSuffix(".build") }
            let hasBuildProducts = fm.fileExists(atPath: buildDirURL.appendingPathComponent("Build/Products").path) ||
                fm.fileExists(atPath: buildDirURL.appendingPathComponent("Products").path) ||
                topEntries.contains {
                    $0.hasPrefix("Debug-") || $0.hasPrefix("Release-") ||
                    $0 == "ExplicitPrecompiledModules" || $0 == "EagerLinkingTBDs"
                }
            let hasDerivedMarkers = fm.fileExists(atPath: buildDirURL.appendingPathComponent("ModuleCache.noindex").path) ||
                fm.fileExists(atPath: buildDirURL.appendingPathComponent("Index.noindex").path)

            return (hasXCBuildData && (hasIntermediates || hasBuildProducts)) ||
                (hasIntermediates && hasBuildProducts) ||
                (hasBuildProducts && hasDerivedMarkers)
        }

        func hasRecognizableJSBuildOutput(at buildDirURL: URL, topEntries: [String]) -> Bool {
            let knownOutputExts = [".js", ".mjs", ".cjs", ".d.ts", ".d.mts", ".d.cts", ".map", ".css", ".html"]
            let knownOutputSubdirs: Set<String> = [
                "assets", "chunks", "static", "esm", "cjs", "types", "server", "client", "public", "browser"
            ]
            let knownOutputFiles: Set<String> = [
                "index.html", "asset-manifest.json", "manifest.json", "stats.json", "routes-manifest.json"
            ]
            for entry in topEntries {
                let lower = entry.lowercased()
                if knownOutputFiles.contains(lower) || knownOutputSubdirs.contains(lower) {
                    return true
                }
                if knownOutputExts.contains(where: { lower.hasSuffix($0) }) {
                    return true
                }
                let subURL = buildDirURL.appendingPathComponent(entry)
                if let subEntries = try? fm.contentsOfDirectory(atPath: subURL.path) {
                    if subEntries.contains(where: { sub in
                        let subLower = sub.lowercased()
                        return knownOutputExts.contains(where: { subLower.hasSuffix($0) }) || knownOutputSubdirs.contains(subLower)
                    }) {
                        return true
                    }
                }
            }
            return false
        }

        // First determine base artifact type & project-aware reproducibility
        var match: VerifiedWorktreeArtifactMatch? = nil

        if !isDir.boolValue {
            // Regular file: only generated TypeScript incremental metadata (*.tsbuildinfo / .tsbuildinfo)
            if name.hasSuffix(".tsbuildinfo") || name == ".tsbuildinfo" {
                if let tsConfig = findFileInParentOrRoot(["tsconfig.json", "tsconfig.build.json", "tsconfig.app.json", "package.json"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .typescriptMetadata,
                        classification: .safe,
                        reason: "Git-ignored TypeScript incremental build metadata; reproducible from \(tsConfig)",
                        reproducibilitySource: tsConfig
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .typescriptMetadata,
                        classification: .review,
                        reason: "TypeScript .tsbuildinfo file without matching tsconfig.json"
                    )
                }
            } else {
                return nil
            }
        } else {
            // Directory candidates
            let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]

            if name == "node_modules" {
                let hasPkgJSON = findFileInParentOrRoot(["package.json"]) != nil
                if let lockfile = findFileInParentOrRoot(lockfiles), hasPkgJSON {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nodeModules,
                        classification: .safe,
                        reason: "Git-ignored dependency directory; reproducible from \(lockfile)",
                        reproducibilitySource: lockfile
                    )
                } else if hasPkgJSON {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nodeModules,
                        classification: .review,
                        reason: "Dependency directory has package.json but no lockfile (package-lock.json, pnpm-lock.yaml, or yarn.lock)",
                        reproducibilitySource: "package.json"
                    )
                } else if let lockfile = findFileInParentOrRoot(lockfiles) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nodeModules,
                        classification: .safe,
                        reason: "Git-ignored dependency directory; reproducible from \(lockfile)",
                        reproducibilitySource: lockfile
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nodeModules,
                        classification: .review,
                        reason: "node_modules directory without package.json or lockfile in worktree"
                    )
                }
            } else if name == ".next" {
                if let cfg = findFileInParentOrRoot(["next.config.ts", "next.config.mjs", "next.config.js", "next.config.cjs", "package.json"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nextBuild,
                        classification: .safe,
                        reason: "Git-ignored Next.js build output; reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .nextBuild,
                        classification: .review,
                        reason: "Next.js .next directory without next.config or package.json"
                    )
                }
            } else if name == ".turbo" {
                if let cfg = findFileInParentOrRoot(["turbo.json", "package.json"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .turboCache,
                        classification: .safe,
                        reason: "Git-ignored Turborepo cache; reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .turboCache,
                        classification: .review,
                        reason: "Turborepo .turbo directory without turbo.json or package.json"
                    )
                }
            } else if [".expo", ".nuxt", ".svelte-kit", ".astro", ".vite", ".parcel-cache", ".eslintcache", ".metro", ".metro-cache", ".angular", ".docusaurus"].contains(name) {
                if let cfg = findFileInParentOrRoot([
                    "app.json", "app.config.js", "app.config.ts", "nuxt.config.ts", "svelte.config.js",
                    "astro.config.mjs", "vite.config.ts", "vite.config.js", "metro.config.js", "angular.json", "package.json"
                ]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .frameworkCache,
                        classification: .safe,
                        reason: "Git-ignored framework build cache (\(name)); reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .frameworkCache,
                        classification: .review,
                        reason: "Framework cache (\(name)) without verified project configuration"
                    )
                }
            } else if name.hasSuffix(".tsbuildinfo") || name == ".tsbuildinfo" {
                if let cfg = findFileInParentOrRoot(["tsconfig.json", "tsconfig.build.json", "package.json"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .typescriptMetadata,
                        classification: .safe,
                        reason: "Git-ignored TypeScript build metadata; reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .typescriptMetadata,
                        classification: .review,
                        reason: "TypeScript build metadata without tsconfig.json"
                    )
                }
            } else if name == "Pods" {
                if let lock = findFileInParentOrRoot(["Podfile.lock"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cocoaPods,
                        classification: .safe,
                        reason: "Git-ignored CocoaPods dependency directory; reproducible from \(lock)",
                        reproducibilitySource: lock
                    )
                } else if findFileInParentOrRoot(["Podfile"]) != nil || directoryHasAny(["Manifest.lock", "Target Support Files"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cocoaPods,
                        classification: .review,
                        reason: "CocoaPods Pods directory without Podfile.lock; classified as REVIEW"
                    )
                }
            } else if name == ".build" {
                let entries = topLevelEntries()
                let hasProtected = entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".swift") }
                if !hasProtected && (findFileInParentOrRoot(["Package.swift"]) != nil || directoryHasAny(["workspace-state.json", "checkouts", "debug", "release"])) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .swiftPMBuild,
                        classification: .safe,
                        reason: "Git-ignored Swift Package Manager build artifacts; reproducible from Package.swift",
                        reproducibilitySource: "Package.swift"
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .swiftPMBuild,
                        classification: .review,
                        reason: "Unverified .build directory; requires manual review"
                    )
                }
            } else if name == ".gradle" {
                if let cfg = findFileInParentOrRoot(["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"]) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .gradleCache,
                        classification: .safe,
                        reason: "Git-ignored Gradle project cache; reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .gradleCache,
                        classification: .review,
                        reason: "Gradle .gradle directory without Gradle build script"
                    )
                }
            } else if relativePath == ".cache/firebase/emulators" || relativePath == ".firebase/emulators" ||
                        (name == "emulators" && (parentURL.lastPathComponent == "firebase" || parentURL.lastPathComponent == ".firebase")) {
                let entries = topLevelEntries()
                let hasEmulatorBinaries = entries.contains {
                    let l = $0.lowercased()
                    return l.hasSuffix(".jar") || l.hasSuffix(".zip") || l.contains("emulator") || l.hasPrefix("ui-")
                }
                let cfg = findFileInParentOrRoot(["firebase.json", ".firebaserc", "package.json"])
                if hasEmulatorBinaries || cfg != nil {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .firebaseEmulatorCache,
                        classification: .safe,
                        reason: "Git-ignored downloadable Firebase emulator cache; reproducible from \(cfg ?? "Firebase CLI")",
                        reproducibilitySource: cfg ?? "firebase-tools"
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .firebaseEmulatorCache,
                        classification: .review,
                        reason: "Firebase emulators directory without verified downloadable emulator binaries"
                    )
                }
            } else if name == "dist" || name == "build" {
                let artType: WorktreeArtifactType = (name == "dist") ? .distOutput : .buildOutput
                let entries = topLevelEntries().filter { $0 != ".DS_Store" }
                let hasSourceDir = entries.contains {
                    $0 == "src" || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "package.json" || $0 == ".git"
                }

                if hasSourceDir || entries.isEmpty {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: artType,
                        classification: .review,
                        reason: "Directory '\(relativePath)' could not be verified as purely generated build output; classified as REVIEW"
                    )
                } else if name == "build" && hasRecognizableXcodeBuildStructure(at: url, topEntries: entries) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: artType,
                        classification: .safe,
                        reason: "Git-ignored Xcode build intermediates (\(relativePath)); reproducible from Xcode project",
                        reproducibilitySource: "Xcode project"
                    )
                } else if isNativeAppleProjectDirectory(parentURL) {
                    // iOS / macOS native directory (e.g., apps/mobile/ios/build): NEVER inherit JS/TS tsconfig.json!
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: artType,
                        classification: .review,
                        reason: "iOS/macOS directory '\(relativePath)' lacks recognizable Xcode build intermediates (XCBuildData, Intermediates.noindex, or Build/Products); classified as REVIEW"
                    )
                } else if let verifiedKind = Self.verifyCleanableProjectArtifact(at: path, projectRoot: rootPath),
                          verifiedKind.defaultRiskLevel == .safe {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: artType,
                        classification: .safe,
                        reason: "Git-ignored \(verifiedKind.rawValue); reproducible from project build configuration",
                        reproducibilitySource: verifiedKind.rawValue
                    )
                } else {
                    // JS/TS dist/build: require explicit build/compile/bundle script in immediate parentURL/package.json
                    // PLUS bundler/compiler config PLUS recognizable generated JS/TS/web output structure.
                    let hasLocalPackageJSON = fm.fileExists(atPath: parentURL.appendingPathComponent("package.json").path)
                    let hasLocalBuildScript = hasLocalPackageJSON && packageJSONHasBuildScript(at: parentURL)
                    let bundlerConfigs = [
                        "vite.config.ts", "vite.config.js", "vite.config.mjs",
                        "webpack.config.js", "webpack.config.ts", "rollup.config.js", "tsup.config.ts",
                        "angular.json", "nest-cli.json", "astro.config.mjs", "svelte.config.js",
                        "next.config.js", "next.config.mjs", "next.config.ts",
                        "tsconfig.build.json", "tsconfig.json"
                    ]
                    let localConfig = bundlerConfigs.first { fm.fileExists(atPath: parentURL.appendingPathComponent($0).path) }
                        ?? (hasLocalPackageJSON ? bundlerConfigs.first { fm.fileExists(atPath: rootURL.appendingPathComponent($0).path) } : nil)
                    let hasOutputStructure = hasRecognizableJSBuildOutput(at: url, topEntries: entries)

                    if hasLocalBuildScript, let cfg = localConfig, hasOutputStructure {
                        match = VerifiedWorktreeArtifactMatch(
                            artifactType: artType,
                            classification: .safe,
                            reason: "Git-ignored \(name) build output; reproducible from package.json build script and \(cfg)",
                            reproducibilitySource: "package.json + \(cfg)"
                        )
                    } else if !hasLocalBuildScript {
                        match = VerifiedWorktreeArtifactMatch(
                            artifactType: artType,
                            classification: .review,
                            reason: "Directory '\(relativePath)' lacks an explicit build/compile/bundle script in local package.json; classified as REVIEW"
                        )
                    } else if localConfig == nil {
                        match = VerifiedWorktreeArtifactMatch(
                            artifactType: artType,
                            classification: .review,
                            reason: "Directory '\(relativePath)' lacks a verified bundler or compiler configuration; classified as REVIEW"
                        )
                    } else {
                        match = VerifiedWorktreeArtifactMatch(
                            artifactType: artType,
                            classification: .review,
                            reason: "Directory '\(relativePath)' does not match a known JS/TS generated-output structure; classified as REVIEW"
                        )
                    }
                }
            } else if parentURL.lastPathComponent == ".cache" || relativePath.hasPrefix(".cache/") {
                let safeCacheSubnames: Set<String> = [
                    "npm", "pnpm", "yarn", "corepack", "metro", "metro-cache",
                    "webpack", "babel-loader", "eslint", "jest", "vitest",
                    "tsbuildinfo", "turbo", "vite", "parcel", "next"
                ]
                if safeCacheSubnames.contains(name) {
                    let cfg = findFileInParentOrRoot(["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "package.json"]) ?? "project configuration"
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cache,
                        classification: .safe,
                        reason: "Git-ignored tool cache (\(relativePath)); reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else if let verifiedKind = Self.verifyCleanableProjectArtifact(at: path, projectRoot: rootPath) {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cache,
                        classification: verifiedKind.defaultRiskLevel,
                        reason: verifiedKind.defaultRiskLevel == .safe
                            ? "Git-ignored \(verifiedKind.rawValue) (\(relativePath)); reproducible from project configuration"
                            : "\(verifiedKind.rawValue) (\(relativePath)) requires manual review before removal",
                        reproducibilitySource: verifiedKind.rawValue
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cache,
                        classification: .review,
                        reason: "Unverified cache subdirectory (\(relativePath)); classified as REVIEW"
                    )
                }
            } else if name == ".cache" {
                let entries = topLevelEntries().filter { $0 != ".DS_Store" }
                let safeCacheSubnames: Set<String> = [
                    "npm", "pnpm", "yarn", "corepack", "metro", "metro-cache",
                    "webpack", "babel-loader", "eslint", "jest", "vitest",
                    "tsbuildinfo", "turbo", "vite", "parcel", "next"
                ]
                if !entries.isEmpty && entries.allSatisfy({ safeCacheSubnames.contains($0) }) {
                    let cfg = findFileInParentOrRoot(["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "package.json"]) ?? "project configuration"
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cache,
                        classification: .safe,
                        reason: "Git-ignored developer cache (.cache); reproducible from \(cfg)",
                        reproducibilitySource: cfg
                    )
                } else {
                    match = VerifiedWorktreeArtifactMatch(
                        artifactType: .cache,
                        classification: .review,
                        reason: "Cache directory (.cache) contains unverified or custom subdirectories; classified as REVIEW"
                    )
                }
            }
        }

        guard let resolvedMatch = match else {
            return nil
        }

        // Perform full subtree safety & symlink containment validation before allowing SAFE
        do {
            try validateWorktreeSubtreeForDeletion(path, worktreeRoot: rootPath)
        } catch let error as SafetyError {
            let reason: String
            switch error {
            case .symlinkTraversalRejected:
                reason = "Contains symbolic link pointing outside worktree; classified as REVIEW for safety"
            case .forbiddenFileOrComponent(let blockedPath):
                let blockedName = URL(fileURLWithPath: blockedPath).lastPathComponent
                reason = "Contains protected file or directory (\(blockedName)); classified as REVIEW"
            default:
                reason = "Contains protected or unverified content; classified as REVIEW"
            }
            return VerifiedWorktreeArtifactMatch(
                artifactType: resolvedMatch.artifactType,
                classification: .review,
                reason: reason,
                reproducibilitySource: resolvedMatch.reproducibilitySource
            )
        } catch {
            return VerifiedWorktreeArtifactMatch(
                artifactType: resolvedMatch.artifactType,
                classification: .review,
                reason: "Safety verification failed; classified as REVIEW",
                reproducibilitySource: resolvedMatch.reproducibilitySource
            )
        }

        return resolvedMatch
    }

    private static func inferWorktreeArtifactType(name: String, relativePath: String) -> WorktreeArtifactType? {
        if name == "node_modules" { return .nodeModules }
        if name == ".next" { return .nextBuild }
        if name == ".turbo" { return .turboCache }
        if name == "dist" { return .distOutput }
        if name == "build" { return .buildOutput }
        if name == "Pods" { return .cocoaPods }
        if name == ".build" { return .swiftPMBuild }
        if name == ".gradle" { return .gradleCache }
        if name.hasSuffix(".tsbuildinfo") || name == ".tsbuildinfo" { return .typescriptMetadata }
        if relativePath.contains("firebase/emulators") || relativePath.contains(".firebase/emulators") { return .firebaseEmulatorCache }
        if name == ".cache" || relativePath.hasPrefix(".cache/") { return .cache }
        if [".expo", ".nuxt", ".svelte-kit", ".astro", ".vite", ".parcel-cache", ".eslintcache", ".metro", ".metro-cache", ".angular", ".docusaurus"].contains(name) {
            return .frameworkCache
        }
        return nil
    }

    /// Validates a verified worktree artifact immediately before moving to Trash.
    public func validateVerifiedWorktreeArtifactForDeletion(
        _ rawPath: String,
        worktreeRoot rawWorktreeRoot: String,
        sourceRepoRoot rawSourceRepoRoot: String? = nil,
        expectedModifiedAt: Date? = nil,
        checkSymlinksOnDisk: Bool = true
    ) throws -> String {
        let normalizedPath = try expandAndNormalize(rawPath)
        let normalizedWorktreeRoot = try expandAndNormalize(rawWorktreeRoot)

        // Never delete the worktree root itself or anything outside the worktree root
        guard normalizedPath.hasPrefix(normalizedWorktreeRoot + "/"), normalizedPath != normalizedWorktreeRoot else {
            throw SafetyError.forbiddenProtectedPath(normalizedPath)
        }

        let sensitiveRoots = [
            "\(homeDirectory)/.ssh",
            "\(homeDirectory)/.gnupg",
            "\(homeDirectory)/.aws",
            "\(homeDirectory)/Documents",
            "\(homeDirectory)/Desktop",
            "\(homeDirectory)/Downloads",
            "\(homeDirectory)/Library",
            "/System",
            "/Applications",
            "/Library"
        ]
        for sRoot in sensitiveRoots {
            if normalizedWorktreeRoot == sRoot || normalizedWorktreeRoot.hasPrefix(sRoot + "/") ||
               normalizedPath == sRoot || normalizedPath.hasPrefix(sRoot + "/") {
                throw SafetyError.forbiddenProtectedPath(normalizedPath)
            }
        }

        // Verify that worktreeRoot is a genuine Git worktree
        let wtVerification = Self.verifyWorktreeGitMetadata(at: normalizedWorktreeRoot)
        guard wtVerification.isVerified else {
            throw SafetyError.unverifiedWorktree(normalizedWorktreeRoot)
        }

        let relativePath = String(normalizedPath.dropFirst(normalizedWorktreeRoot.count + 1))
        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        for comp in relativeComponents {
            let isDep = comp == "node_modules" || comp == "Pods"
            if isProtectedWorktreeComponent(comp, fullPath: normalizedPath, isInsideDependencyDir: isDep) {
                throw SafetyError.forbiddenFileOrComponent(normalizedPath)
            }
        }

        if checkSymlinksOnDisk && FileManager.default.fileExists(atPath: normalizedPath) {
            let url = URL(fileURLWithPath: normalizedPath)
            if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
                throw SafetyError.symlinkTraversalRejected(normalizedPath)
            }
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedWorktreeRoot = URL(fileURLWithPath: normalizedWorktreeRoot).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(resolvedWorktreeRoot + "/") && resolvedPath != resolvedWorktreeRoot else {
                throw SafetyError.symlinkTraversalRejected("\(normalizedPath) -> \(resolvedPath)")
            }

            if let expectedModifiedAt {
                if let modVals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let currentMod = modVals.contentModificationDate,
                   currentMod.timeIntervalSince(expectedModifiedAt) > 2.0 {
                    throw SafetyError.modifiedSinceScan(normalizedPath)
                }
            }
        }

        if checkSymlinksOnDisk && FileManager.default.fileExists(atPath: normalizedPath) {
            try validateWorktreeSubtreeForDeletion(normalizedPath, worktreeRoot: normalizedWorktreeRoot)
        }

        guard let match = inspectWorktreeArtifactSafety(at: normalizedPath, worktreeRoot: normalizedWorktreeRoot),
              match.classification == .safe else {
            throw SafetyError.unverifiedProjectArtifact(normalizedPath)
        }

        return normalizedPath
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
