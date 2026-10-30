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
            "\(homeDirectory)/Library/Android/sdk/.temp",
            "\(homeDirectory)/Library/Application Support/Claude/Cache",
            "\(homeDirectory)/Library/Application Support/Claude/Code Cache",
            "\(homeDirectory)/Library/Application Support/Claude/GPUCache",
            "\(homeDirectory)/Library/Application Support/Claude/DawnWebGPUCache",
            "\(homeDirectory)/Library/Application Support/Claude/DawnGraphiteCache",
            "\(homeDirectory)/Library/Application Support/Claude/ShaderCache",
            "\(homeDirectory)/Library/Application Support/Claude/claude-code",
            "\(homeDirectory)/Library/Application Support/Claude/simulator-builds",
            "\(homeDirectory)/Library/Application Support/Claude/vm_bundles",
            "\(homeDirectory)/Library/Application Support/Codex/Cache",
            "\(homeDirectory)/Library/Application Support/Codex/Code Cache",
            "\(homeDirectory)/Library/Application Support/Codex/GPUCache",
            "\(homeDirectory)/Library/Application Support/Codex/DawnWebGPUCache",
            "\(homeDirectory)/Library/Application Support/Codex/DawnGraphiteCache",
            "\(homeDirectory)/Library/Application Support/Codex/ShaderCache",
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
        "service-account.json",
        "service_account.json",
        "credentials.json",
        "client_secret.json",
        "Docker.raw",
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
        ".csr"
    ]

    public func isForbiddenComponentName(_ comp: String) -> Bool {
        if forbiddenComponents.contains(comp) {
            return true
        }
        let lower = comp.lowercased()
        if lower == "googleservice-info.plist" || lower == "google-services.json" {
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
                let resolvedAllowed = resolvedAllowedPrefixes.contains { resolvedAllowedPrefix in
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

    public func isSafeToDelete(_ rawPath: String, checkSymlinksOnDisk: Bool = true) -> Bool {
        do {
            _ = try validateForDeletion(rawPath, checkSymlinksOnDisk: checkSymlinksOnDisk)
            return true
        } catch {
            return false
        }
    }
}
