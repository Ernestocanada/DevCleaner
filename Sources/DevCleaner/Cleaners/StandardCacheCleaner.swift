import Foundation

public struct NpmCapabilities: Equatable, Sendable {
    public let npmBinaryPath: String?
    public let version: String?
    public let effectiveCacheRoot: String
    public let supportsCacheVerify: Bool
    public let supportsCacheClean: Bool
    public let supportsSelectiveNpxRemoval: Bool

    public init(
        npmBinaryPath: String?,
        version: String? = nil,
        effectiveCacheRoot: String,
        supportsCacheVerify: Bool = true,
        supportsCacheClean: Bool = true,
        supportsSelectiveNpxRemoval: Bool = false
    ) {
        self.npmBinaryPath = npmBinaryPath
        self.version = version
        self.effectiveCacheRoot = effectiveCacheRoot
        self.supportsCacheVerify = supportsCacheVerify
        self.supportsCacheClean = supportsCacheClean
        self.supportsSelectiveNpxRemoval = supportsSelectiveNpxRemoval
    }
}

public struct NpmLiveUseState: Equatable, Sendable {
    public let isDeterminedSafely: Bool
    public let activeGlobalNpmProcesses: [String]
    public let activeNpxEnvironmentKeys: Set<String>
    public let activeProcessesByNpxKey: [String: [String]]

    public init(
        isDeterminedSafely: Bool = true,
        activeGlobalNpmProcesses: [String] = [],
        activeNpxEnvironmentKeys: Set<String> = [],
        activeProcessesByNpxKey: [String: [String]] = [:]
    ) {
        self.isDeterminedSafely = isDeterminedSafely
        self.activeGlobalNpmProcesses = activeGlobalNpmProcesses
        self.activeNpxEnvironmentKeys = activeNpxEnvironmentKeys
        self.activeProcessesByNpxKey = activeProcessesByNpxKey
    }

    public static let idle = NpmLiveUseState(
        isDeterminedSafely: true,
        activeGlobalNpmProcesses: [],
        activeNpxEnvironmentKeys: [],
        activeProcessesByNpxKey: [:]
    )

    public var hasAnyGlobalOrNpxUse: Bool {
        !isDeterminedSafely || !activeGlobalNpmProcesses.isEmpty || !activeNpxEnvironmentKeys.isEmpty
    }

    public func isNpxKeyActive(_ key: String) -> Bool {
        !isDeterminedSafely || !activeGlobalNpmProcesses.isEmpty || activeNpxEnvironmentKeys.contains(key)
    }

    public func processes(forKey key: String) -> [String] {
        var result = Set(activeGlobalNpmProcesses)
        if let specific = activeProcessesByNpxKey[key] {
            result.formUnion(specific)
        }
        if !isDeterminedSafely && result.isEmpty {
            result.insert("undetermined process state")
        }
        if result.isEmpty && activeNpxEnvironmentKeys.contains(key) {
            result.insert("npx (\(key))")
        }
        return Array(result).sorted()
    }

    public var allActiveProcessDescriptions: [String] {
        var result = Set(activeGlobalNpmProcesses)
        for (_, procs) in activeProcessesByNpxKey {
            result.formUnion(procs)
        }
        for key in activeNpxEnvironmentKeys where activeProcessesByNpxKey[key]?.isEmpty ?? true {
            result.insert("npx (\(key))")
        }
        if !isDeterminedSafely && result.isEmpty {
            result.insert("undetermined process state")
        }
        return Array(result).sorted()
    }

    public var activeNpxSummary: String {
        let keys = activeNpxEnvironmentKeys.sorted()
        let procs = allActiveProcessDescriptions
        if !keys.isEmpty && !procs.isEmpty {
            return "keys: \(keys.joined(separator: ", ")); processes: \(procs.joined(separator: ", "))"
        }
        if !keys.isEmpty {
            return "keys: \(keys.joined(separator: ", "))"
        }
        if !procs.isEmpty {
            return procs.joined(separator: ", ")
        }
        return "undetermined live process state"
    }

    public func primaryProcessLabel(forKeys keys: [String] = []) -> String {
        for key in keys {
            let procs = processes(forKey: key)
            if !procs.isEmpty {
                return procs.joined(separator: ", ")
            }
        }
        let all = allActiveProcessDescriptions
        return all.isEmpty ? "npm / npx" : all.joined(separator: ", ")
    }
}

public enum NpmCacheInspector {
    public static func resolveNpmBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Validates and canonicalizes an effective npm cache root directory, ensuring credentials, global packages,
    /// and project `node_modules` are strictly outside the rule.
    public static func validateAndCanonicalizeCacheRoot(
        _ rawCacheRoot: String,
        homeDirectory: String
    ) throws -> String {
        let trimmed = rawCacheRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SafetyError.emptyOrInvalidPath
        }
        let rawParts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if rawParts.contains("..") {
            throw SafetyError.containsParentTraversal(rawCacheRoot)
        }

        let cleanHome = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory

        var expanded = trimmed
        if expanded == "~" {
            expanded = cleanHome
        } else if expanded.hasPrefix("~/") {
            expanded = cleanHome + String(expanded.dropFirst(1))
        }
        guard expanded.hasPrefix("/") else {
            throw SafetyError.emptyOrInvalidPath
        }

        let url = URL(fileURLWithPath: expanded)
        var standardized = url.standardizedFileURL.path
        if standardized.hasSuffix("/") && standardized.count > 1 {
            standardized = String(standardized.dropLast())
        }

        if FileManager.default.fileExists(atPath: standardized) {
            let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                throw SafetyError.symlinkTraversalRejected(standardized)
            }
        }

        let components = standardized.split(separator: "/").map(String.init)
        let forbiddenComponents: Set<String> = [
            "node_modules", ".git", ".ssh", ".gnupg", ".aws", ".npmrc", "Keychains"
        ]
        for comp in components where forbiddenComponents.contains(comp) {
            throw SafetyError.forbiddenFileOrComponent(standardized)
        }

        let forbiddenExactOrPrefixes: [String] = [
            "\(cleanHome)/Developer",
            "\(cleanHome)/Documents",
            "\(cleanHome)/Desktop",
            "\(cleanHome)/Downloads",
            "\(cleanHome)/.ssh",
            "\(cleanHome)/.gnupg",
            "\(cleanHome)/.aws",
            "\(cleanHome)/.config/gcloud",
            "\(cleanHome)/.nvm",
            "/System",
            "/Applications",
            "/Library",
            "/opt/homebrew/lib",
            "/usr/local/lib"
        ]
        for forbidden in forbiddenExactOrPrefixes {
            if standardized == forbidden || standardized.hasPrefix(forbidden + "/") {
                throw SafetyError.forbiddenProtectedPath(standardized)
            }
        }

        let forbiddenExactRoots: Set<String> = [
            "/",
            "/Users",
            "/private",
            "/var",
            "/tmp",
            "/private/tmp",
            cleanHome,
            "\(cleanHome)/Library",
            "\(cleanHome)/Library/Caches",
            "\(cleanHome)/Library/Application Support",
            "\(cleanHome)/.cache"
        ]
        if forbiddenExactRoots.contains(standardized) {
            throw SafetyError.forbiddenProtectedPath(standardized)
        }

        return standardized
    }

    public static func parseNpmrcCachePath(npmrcContents: String) -> String? {
        for rawLine in npmrcContents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("cache=") || line.hasPrefix("cache ") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
    }

    public static func discoverCapabilities(
        homeDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        npmBinaryResolver: () -> String? = { resolveNpmBinary() },
        shellRunner: @Sendable (String, [String]) async -> ShellResult = { exe, args in
            await ShellRunner.shared.run(exe, arguments: args)
        }
    ) async -> NpmCapabilities {
        let cleanHome = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory
        let defaultCacheRoot = "\(cleanHome)/.npm"
        let npmBin = npmBinaryResolver()

        var rawCandidateRoot: String? = nil
        if let envCache = environment["NPM_CONFIG_CACHE"] ?? environment["npm_config_cache"],
           !envCache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawCandidateRoot = envCache
        } else {
            let npmrcPath = "\(cleanHome)/.npmrc"
            if let npmrcText = try? String(contentsOfFile: npmrcPath, encoding: .utf8),
               let parsed = parseNpmrcCachePath(npmrcContents: npmrcText) {
                rawCandidateRoot = parsed
            }
        }

        var versionString: String? = nil
        var supportsSelectiveNpx = false

        if let npmBin {
            if rawCandidateRoot == nil {
                let configRes = await shellRunner(npmBin, ["config", "get", "cache", "--loglevel=silent"])
                if configRes.isSuccess {
                    let out = configRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !out.isEmpty && out != "undefined" && out != "null" {
                        rawCandidateRoot = out
                    }
                }
            }
            let helpRes = await shellRunner(npmBin, ["cache", "--help"])
            if helpRes.isSuccess {
                let helpOut = helpRes.stdout.lowercased()
                if helpOut.contains("npm cache npx") {
                    supportsSelectiveNpx = true
                }
            }
            let verRes = await shellRunner(npmBin, ["--version"])
            if verRes.isSuccess {
                let v = verRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    versionString = v
                }
            }
        }

        let validatedRoot: String = {
            if let candidate = rawCandidateRoot,
               let valid = try? validateAndCanonicalizeCacheRoot(candidate, homeDirectory: cleanHome) {
                return valid
            }
            return (try? validateAndCanonicalizeCacheRoot(defaultCacheRoot, homeDirectory: cleanHome)) ?? defaultCacheRoot
        }()

        return NpmCapabilities(
            npmBinaryPath: npmBin,
            version: versionString,
            effectiveCacheRoot: validatedRoot,
            supportsCacheVerify: npmBin != nil,
            supportsCacheClean: npmBin != nil,
            supportsSelectiveNpxRemoval: supportsSelectiveNpx
        )
    }

    /// Inspects live npm/npx use across process command lines, descendant processes, executable paths,
    /// current working directories, and open files/cache paths.
    public static func inspectLiveUse(
        cacheRoot: String,
        snapshot: ActiveProcessSnapshot = .empty,
        shellRunner: (@Sendable (String, [String]) async -> ShellResult)? = nil,
        includeSystemQueries: Bool = true
    ) async -> NpmLiveUseState {
        let stdCacheRoot = URL(fileURLWithPath: cacheRoot).standardizedFileURL.path
        let resolvedCacheRoot = URL(fileURLWithPath: stdCacheRoot).resolvingSymlinksInPath().path
        let cacheRoots = Array(Set([stdCacheRoot, resolvedCacheRoot]))

        var globalProcs = Set<String>()
        var activeKeys = Set<String>()
        var procsByKey: [String: Set<String>] = [:]

        func recordKey(_ key: String, processLabel: String) {
            guard !key.isEmpty && key != "." && key != ".." else { return }
            activeKeys.insert(key)
            procsByKey[key, default: []].insert(processLabel)
        }

        func extractNpxKeys(from text: String) -> [String] {
            var found: [String] = []
            let prefixes = cacheRoots.map { "\($0)/_npx/" } + ["/.npm/_npx/"]
            for prefix in prefixes {
                var searchRange = text.startIndex..<text.endIndex
                while let match = text.range(of: prefix, range: searchRange) {
                    let after = text[match.upperBound...]
                    let key = after.prefix { $0 != "/" && !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                    if !key.isEmpty {
                        found.append(String(key))
                    }
                    searchRange = match.upperBound..<text.endIndex
                }
            }
            return Array(Set(found))
        }

        func friendlyLabel(fromLine line: String) -> String {
            let lower = line.lowercased()
            if lower.contains("firebase") { return "firebase (npx)" }
            if lower.contains("desktop-commander") { return "desktop-commander (npx)" }
            if lower.contains("playwright") { return "playwright (npx)" }
            if lower.contains("mcp") { return "MCP server (npx)" }
            if lower.contains("npx") { return "npx" }
            if lower.contains("npm") { return "npm" }
            let firstToken = line.split(separator: " ").first.map(String.init) ?? "node"
            return URL(fileURLWithPath: firstToken).lastPathComponent
        }

        func inspectCommandLine(_ line: String) {
            let keys = extractNpxKeys(from: line)
            let label = friendlyLabel(fromLine: line)
            for k in keys {
                recordKey(k, processLabel: label)
            }

            let lower = line.lowercased()
            let hasDirectNpmOrNpx = lower.contains("/npm ") || lower.hasSuffix("/npm") ||
                lower.contains("npm-cli.js") || lower.contains("/npx ") || lower.hasSuffix("/npx") ||
                lower.contains("npx-cli.js") || lower.hasPrefix("npm ") || lower.hasPrefix("npx ")
            let referencesCacheRoot = cacheRoots.contains { root in
                line.contains("\(root)/_cacache") || line.contains("\(root)/_logs") || line == root
            }
            if hasDirectNpmOrNpx || referencesCacheRoot {
                globalProcs.insert(label)
            }
        }

        for line in snapshot.activeLines {
            inspectCommandLine(line)
        }

        if includeSystemQueries, let runner = shellRunner {
            let psRes = await runner("/bin/ps", ["-axo", "pid=,ppid=,comm=,args="])
            guard psRes.isSuccess else {
                return NpmLiveUseState(
                    isDeterminedSafely: false,
                    activeGlobalNpmProcesses: ["undetermined process state"],
                    activeNpxEnvironmentKeys: activeKeys,
                    activeProcessesByNpxKey: procsByKey.mapValues { Array($0).sorted() }
                )
            }

            struct ProcRow {
                let pid: Int32
                let ppid: Int32
                let comm: String
                let args: String
            }

            var rowsByPID: [Int32: ProcRow] = [:]
            var childrenByPPID: [Int32: [Int32]] = [:]
            var seedPIDs = Set<Int32>()
            var seedKeyByPID: [Int32: Set<String>] = [:]

            for rawLine in psRes.stdout.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let tokens = trimmed.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard tokens.count >= 3,
                      let pid = Int32(tokens[0]),
                      let ppid = Int32(tokens[1]) else { continue }
                let comm = String(tokens[2])
                let args = tokens.count >= 4 ? String(tokens[3]) : comm
                let combined = "\(comm) \(args)"
                let row = ProcRow(pid: pid, ppid: ppid, comm: comm, args: combined)
                rowsByPID[pid] = row
                childrenByPPID[ppid, default: []].append(pid)

                inspectCommandLine(combined)
                let keys = extractNpxKeys(from: combined)
                if !keys.isEmpty {
                    seedPIDs.insert(pid)
                    seedKeyByPID[pid, default: []].formUnion(keys)
                }
                let lower = combined.lowercased()
                if lower.contains("/npm ") || lower.contains("npm-cli.js") ||
                   lower.contains("/npx ") || lower.contains("npx-cli.js") ||
                   cacheRoots.contains(where: { combined.contains($0) }) {
                    seedPIDs.insert(pid)
                }
            }

            // Traverse descendant processes of any npm/npx/_npx seed process
            var queue = Array(seedPIDs)
            var visited = seedPIDs
            while !queue.isEmpty {
                let current = queue.removeFirst()
                let inheritedKeys = seedKeyByPID[current] ?? []
                for childPID in childrenByPPID[current] ?? [] {
                    if !inheritedKeys.isEmpty {
                        seedKeyByPID[childPID, default: []].formUnion(inheritedKeys)
                    }
                    if !visited.contains(childPID) {
                        visited.insert(childPID)
                        queue.append(childPID)
                    }
                }
            }

            for pid in visited {
                guard let row = rowsByPID[pid] else { continue }
                let label = friendlyLabel(fromLine: row.args)
                let keys = seedKeyByPID[pid] ?? []
                if !keys.isEmpty {
                    for k in keys {
                        recordKey(k, processLabel: label)
                    }
                } else {
                    globalProcs.insert(label)
                }
            }

            // Inspect open files and current working directories (`cwd`) via lsof if cacheRoot exists on disk
            if FileManager.default.fileExists(atPath: stdCacheRoot) && FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") {
                let lsofRes = await runner("/usr/sbin/lsof", ["-Fpcn", "--", stdCacheRoot])
                if lsofRes.exitCode == 0 || !lsofRes.stdout.isEmpty {
                    var currentCmd = "process"
                    for rawLine in lsofRes.stdout.components(separatedBy: .newlines) {
                        guard rawLine.count > 1 else { continue }
                        let prefix = rawLine.first!
                        let value = String(rawLine.dropFirst())
                        if prefix == "c" {
                            currentCmd = value
                        } else if prefix == "n" {
                            let keys = extractNpxKeys(from: value)
                            if !keys.isEmpty {
                                for k in keys {
                                    recordKey(k, processLabel: currentCmd)
                                }
                            } else if cacheRoots.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) {
                                globalProcs.insert(currentCmd)
                            }
                        }
                    }
                }
            }
        }

        return NpmLiveUseState(
            isDeterminedSafely: true,
            activeGlobalNpmProcesses: Array(globalProcs).sorted(),
            activeNpxEnvironmentKeys: activeKeys,
            activeProcessesByNpxKey: procsByKey.mapValues { Array($0).sorted() }
        )
    }
}

public struct StandardCacheCleaner: CleanerProvider {
    public let category: CleanerCategory
    private let home: String
    private let executor: CleanupExecutor
    private let planner: CleanupPlanner
    private let npmCapabilitiesOverride: NpmCapabilities?
    private let npmLiveUseOverride: NpmLiveUseState?
    private let shellRunner: @Sendable (String, [String]) async -> ShellResult

    public init(
        category: CleanerCategory,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        executor: CleanupExecutor? = nil,
        npmCapabilitiesOverride: NpmCapabilities? = nil,
        npmLiveUseOverride: NpmLiveUseState? = nil,
        shellRunner: (@Sendable (String, [String]) async -> ShellResult)? = nil
    ) {
        self.category = category
        self.home = homeDirectory
        let validator = SafetyValidator(homeDirectory: homeDirectory)
        self.executor = executor ?? CleanupExecutor(validator: validator)
        self.planner = CleanupPlanner(validator: validator)
        self.npmCapabilitiesOverride = npmCapabilitiesOverride
        self.npmLiveUseOverride = npmLiveUseOverride
        self.shellRunner = shellRunner ?? { exe, args in
            await ShellRunner.shared.run(exe, arguments: args)
        }
    }

    private struct TargetSpec {
        let id: String
        let name: String
        let relativePath: String
        let risk: RiskLevel
        let explanation: String
        let consequence: String
        let regeneration: String
        let cleanContentsOnly: Bool
        let supportsAgeFilter: Bool
        let appProcessNames: [String]
        let commandTokens: [String]
        let requiresRedownload: Bool

        init(
            id: String,
            name: String,
            relativePath: String,
            risk: RiskLevel,
            explanation: String,
            consequence: String,
            regeneration: String,
            cleanContentsOnly: Bool,
            supportsAgeFilter: Bool,
            appProcessNames: [String] = [],
            commandTokens: [String] = [],
            requiresRedownload: Bool = false
        ) {
            self.id = id
            self.name = name
            self.relativePath = relativePath
            self.risk = risk
            self.explanation = explanation
            self.consequence = consequence
            self.regeneration = regeneration
            self.cleanContentsOnly = cleanContentsOnly
            self.supportsAgeFilter = supportsAgeFilter
            self.appProcessNames = appProcessNames
            self.commandTokens = commandTokens
            self.requiresRedownload = requiresRedownload
        }
    }

    private var specs: [TargetSpec] {
        switch category {
        case .xcode:
            return [
                TargetSpec(
                    id: "xcode-derived-data",
                    name: "Xcode DerivedData",
                    relativePath: "Library/Developer/Xcode/DerivedData",
                    risk: .safe,
                    explanation: "Intermediate build products, module caches, and project indexes generated by Xcode.",
                    consequence: "Moves eligible build folders to macOS Trash. Never touches project source files or Archives.",
                    regeneration: "Automatically regenerated by Xcode on the next project build.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "xcode-documentation-cache",
                    name: "Xcode Documentation Cache",
                    relativePath: "Library/Developer/Xcode/DocumentationCache",
                    risk: .safe,
                    explanation: "Prebuilt developer documentation indexes and symbol caches inside ~/Library/Developer/Xcode/DocumentationCache.",
                    consequence: "Moves eligible Xcode documentation cache indexes to macOS Trash.",
                    regeneration: "Automatically rebuilt by Xcode when browsing developer documentation.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "xcode-caches",
                    name: "Xcode Application Cache",
                    relativePath: "Library/Caches/com.apple.dt.Xcode",
                    risk: .safe,
                    explanation: "Temporary Xcode UI, symbol, and documentation lookup caches.",
                    consequence: "Moves eligible temporary Xcode cache files to macOS Trash.",
                    regeneration: "Automatically recreated when Xcode runs.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "coresimulator-logs",
                    name: "CoreSimulator Logs",
                    relativePath: "Library/Logs/CoreSimulator",
                    risk: .safe,
                    explanation: "Diagnostic and system log files produced by iOS Simulator runs.",
                    consequence: "Moves eligible historical simulator log files to macOS Trash.",
                    regeneration: "Recreated automatically as simulators run.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "xcode-logs",
                    name: "Xcode Build & Diagnostic Logs",
                    relativePath: "Library/Logs/Xcode",
                    risk: .safe,
                    explanation: "Diagnostic logs produced by Xcode and simulator previews in ~/Library/Logs/Xcode.",
                    consequence: "Moves eligible Xcode log files to macOS Trash.",
                    regeneration: "Recreated automatically by Xcode.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "xcode-ios-device-support",
                    name: "Xcode iOS DeviceSupport Symbols",
                    relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
                    risk: .review,
                    explanation: "Extracted debug symbols from connected physical iOS devices.",
                    consequence: "Moves cached device symbol folders to macOS Trash.",
                    regeneration: "Re-extracted from physical iOS device when connected for debugging.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                ),
                TargetSpec(
                    id: "xcode-watchos-device-support",
                    name: "Xcode watchOS DeviceSupport Symbols",
                    relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
                    risk: .review,
                    explanation: "Extracted debug symbols from connected physical Apple Watch devices.",
                    consequence: "Moves cached watchOS device symbol folders to macOS Trash.",
                    regeneration: "Re-extracted when debugging a physical Apple Watch.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                )
            ]
        case .nodeNpm:
            return [
                TargetSpec(
                    id: "pnpm-cache",
                    name: "pnpm Store & Metadata Cache",
                    relativePath: "Library/Caches/pnpm",
                    risk: .safe,
                    explanation: "Content-addressable package store and dlx/metadata cache in ~/Library/Caches/pnpm.",
                    consequence: "Moves eligible cached pnpm store packages to macOS Trash. Existing project node_modules remain intact.",
                    regeneration: "Re-downloaded on demand when running pnpm install.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "node-gyp-cache",
                    name: "node-gyp Node Headers Cache",
                    relativePath: "Library/Caches/node-gyp",
                    risk: .safe,
                    explanation: "Downloaded Node.js C++ header tarballs used by node-gyp to compile native addons in ~/Library/Caches/node-gyp.",
                    consequence: "Moves cached Node header files to macOS Trash.",
                    regeneration: "Automatically re-downloaded when building native Node.js modules.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "typescript-cache",
                    name: "TypeScript Language Server Cache",
                    relativePath: "Library/Caches/typescript",
                    risk: .safe,
                    explanation: "Automatic type acquisition (ATA) typings cache in ~/Library/Caches/typescript.",
                    consequence: "Moves cached @types packages to macOS Trash.",
                    regeneration: "Automatically re-fetched by TypeScript language server.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "yarn-cache",
                    name: "Yarn Package Cache",
                    relativePath: "Library/Caches/Yarn",
                    risk: .safe,
                    explanation: "Global package tarball cache for Yarn in ~/Library/Caches/Yarn.",
                    consequence: "Moves cached Yarn package archives to macOS Trash.",
                    regeneration: "Re-downloaded when running yarn install.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "node-corepack-cache",
                    name: "Node Corepack Cache (~/.cache/node)",
                    relativePath: ".cache/node",
                    risk: .safe,
                    explanation: "Corepack downloaded package manager archives (pnpm/yarn) in ~/.cache/node.",
                    consequence: "Moves cached Corepack tarballs to macOS Trash.",
                    regeneration: "Automatically re-downloaded by Corepack when needed.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "pkg-node-binaries-cache",
                    name: "Vercel pkg Node Base Binaries (~/.cache/pkg)",
                    relativePath: ".cache/pkg",
                    risk: .review,
                    explanation: "Precompiled Node.js base binaries cached by `pkg` in ~/.cache/pkg.",
                    consequence: "Moves cached pkg base binaries to macOS Trash.",
                    regeneration: "Base binaries will need to be downloaded again when packaging Node CLI executables.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                )
            ]
        case .gradle:
            return [
                TargetSpec(
                    id: "gradle-caches",
                    name: "Gradle Build & Artifact Caches",
                    relativePath: ".gradle/caches",
                    risk: .safe,
                    explanation: "Downloaded Maven/Gradle dependencies, transforms, and build caches across Android/JVM builds.",
                    consequence: "Moves eligible global Gradle cache entries to macOS Trash. Project source code and local build scripts are never touched.",
                    regeneration: "Dependencies will be re-downloaded and rebuilt on your next Gradle sync/build.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "gradle-daemon",
                    name: "Gradle Daemon Logs",
                    relativePath: ".gradle/daemon",
                    risk: .safe,
                    explanation: "Historical logs and state registries for Gradle background daemons.",
                    consequence: "Moves eligible daemon log files to macOS Trash.",
                    regeneration: "Recreated automatically when Gradle starts a daemon.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                )
            ]
        case .cocoapodsSwiftPM:
            return [
                TargetSpec(
                    id: "cocoapods-cache",
                    name: "CocoaPods Spec & Pod Cache",
                    relativePath: "Library/Caches/CocoaPods",
                    risk: .safe,
                    explanation: "Cached pod tarballs and git clones managed by CocoaPods.",
                    consequence: "Moves eligible cached pod downloads to macOS Trash. Existing Pods/ folders inside your projects are untouched.",
                    regeneration: "Re-downloaded automatically when running pod install / pod update.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "swiftpm-cache",
                    name: "Swift Package Manager Cache",
                    relativePath: "Library/Caches/org.swift.swiftpm",
                    risk: .safe,
                    explanation: "Cloned git repositories and manifests cached by SwiftPM.",
                    consequence: "Moves eligible global SwiftPM repository cache entries to macOS Trash.",
                    regeneration: "Re-fetched automatically when resolving Swift packages.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                )
            ]
        case .homebrew:
            return [
                TargetSpec(
                    id: "homebrew-cache",
                    name: "Homebrew Download Cache",
                    relativePath: "Library/Caches/Homebrew",
                    risk: .safe,
                    explanation: "Downloaded bottles, installers, and source archives from brew install/upgrade.",
                    consequence: "Moves eligible cached installers/bottles to macOS Trash. Installed Homebrew formulas and casks remain intact.",
                    regeneration: "Only re-downloaded if you reinstall a package from scratch.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                )
            ]
        case .generalCaches:
            return [
                TargetSpec(
                    id: "dotslash-cache",
                    name: "DotSlash Executable Cache (~/Library/Caches/dotslash)",
                    relativePath: "Library/Caches/dotslash",
                    risk: .safe,
                    explanation: "Extracted platform-specific CLI binaries managed by DotSlash in ~/Library/Caches/dotslash.",
                    consequence: "Moves cached DotSlash tool binaries to macOS Trash.",
                    regeneration: "Automatically re-fetched and extracted by DotSlash on next CLI invocation.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "antigravity-cache",
                    name: "Antigravity Cache (~/Library/Caches/com.google.antigravity)",
                    relativePath: "Library/Caches/com.google.antigravity",
                    risk: .safe,
                    explanation: "Temporary HTTP, ShipIt, and GPU caches for Google Antigravity in ~/Library/Caches/com.google.antigravity.",
                    consequence: "Moves eligible temporary cache files to macOS Trash without affecting workspaces or settings.",
                    regeneration: "Automatically regenerated by Antigravity.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true,
                    appProcessNames: ["Antigravity"],
                    commandTokens: ["Antigravity.app"]
                ),
                TargetSpec(
                    id: "gemini-macos-cache",
                    name: "Google Gemini macOS Cache (~/Library/Caches/com.google.GeminiMacOS)",
                    relativePath: "Library/Caches/com.google.GeminiMacOS",
                    risk: .safe,
                    explanation: "Temporary URLCache, WebKit, and HTTP caches in ~/Library/Caches/com.google.GeminiMacOS.",
                    consequence: "Moves eligible temporary Gemini cache files to macOS Trash.",
                    regeneration: "Automatically regenerated when Gemini runs.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true,
                    appProcessNames: ["Gemini"],
                    commandTokens: ["GeminiMacOS"]
                ),
                TargetSpec(
                    id: "antigravity-updater-cache",
                    name: "Antigravity Updater Cache (~/Library/Caches/antigravity-updater)",
                    relativePath: "Library/Caches/antigravity-updater",
                    risk: .safe,
                    explanation: "Downloaded update packages and staging binaries in ~/Library/Caches/antigravity-updater.",
                    consequence: "Moves staged updater packages to macOS Trash.",
                    regeneration: "Only re-downloaded when a new application update is available.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "notion-updater-cache",
                    name: "Notion Updater Cache (~/Library/Caches/notion-updater)",
                    relativePath: "Library/Caches/notion-updater",
                    risk: .safe,
                    explanation: "Downloaded Notion app update packages in ~/Library/Caches/notion-updater.",
                    consequence: "Moves staged Notion updater archives to macOS Trash.",
                    regeneration: "Only re-downloaded when Notion updates.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "react-native-cache",
                    name: "React Native Download Cache (~/Library/Caches/ReactNative)",
                    relativePath: "Library/Caches/ReactNative",
                    risk: .safe,
                    explanation: "Downloaded prebuilt Hermes/React Native framework tarballs in ~/Library/Caches/ReactNative.",
                    consequence: "Moves cached React Native tarballs to macOS Trash.",
                    regeneration: "Automatically re-downloaded during React Native / CocoaPods builds.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "openai-chat-cache",
                    name: "OpenAI ChatGPT Cache (~/Library/Caches/com.openai.chat)",
                    relativePath: "Library/Caches/com.openai.chat",
                    risk: .safe,
                    explanation: "Temporary URL and asset caches for the ChatGPT macOS app in ~/Library/Caches/com.openai.chat.",
                    consequence: "Moves eligible temporary cache files to macOS Trash. Does not affect account or chat history.",
                    regeneration: "Automatically regenerated when ChatGPT runs.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true,
                    appProcessNames: ["ChatGPT"],
                    commandTokens: ["ChatGPT.app", "com.openai.chat"]
                ),
                TargetSpec(
                    id: "pip-cache",
                    name: "Python pip Wheel Cache",
                    relativePath: "Library/Caches/pip",
                    risk: .safe,
                    explanation: "Cached HTTP responses and built wheels from Python pip installs.",
                    consequence: "Moves eligible cached Python package downloads to macOS Trash. Virtualenvs are untouched.",
                    regeneration: "Re-downloaded when installing Python packages.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "mesa-shader-cache",
                    name: "Mesa Shader Cache (~/.cache/mesa_shader_cache)",
                    relativePath: ".cache/mesa_shader_cache",
                    risk: .safe,
                    explanation: "Compiled OpenGL/Vulkan shader cache in ~/.cache/mesa_shader_cache.",
                    consequence: "Moves cached shader binaries to macOS Trash.",
                    regeneration: "Automatically recompiled on demand.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: true
                ),
                TargetSpec(
                    id: "puppeteer-cache",
                    name: "Puppeteer Cached Browsers (~/.cache/puppeteer)",
                    relativePath: ".cache/puppeteer",
                    risk: .review,
                    explanation: "Chrome and Chrome Headless Shell browser binaries downloaded by Puppeteer in ~/.cache/puppeteer.",
                    consequence: "Browser binaries will need to be downloaded again.",
                    regeneration: "Browser binaries will need to be downloaded again.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                ),
                TargetSpec(
                    id: "playwright-cache",
                    name: "Playwright Browser Binaries (~/Library/Caches/ms-playwright)",
                    relativePath: "Library/Caches/ms-playwright",
                    risk: .review,
                    explanation: "Headless browser binaries downloaded by Playwright.",
                    consequence: "Browser binaries will need to be downloaded again. Moves downloaded test browser binaries to macOS Trash.",
                    regeneration: "Requires running 'npx playwright install' if needed again.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                ),
                TargetSpec(
                    id: "playwright-go-cache",
                    name: "Playwright Go Driver & Browsers (~/Library/Caches/ms-playwright-go)",
                    relativePath: "Library/Caches/ms-playwright-go",
                    risk: .review,
                    explanation: "Playwright Go driver node runtime and browser binaries in ~/Library/Caches/ms-playwright-go.",
                    consequence: "Browser binaries will need to be downloaded again. Moves cached Playwright Go runtime to macOS Trash.",
                    regeneration: "Re-downloaded when running Playwright Go tests.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                ),
                TargetSpec(
                    id: "firebase-emulators-cache",
                    name: "Firebase Emulator Suite JAR Cache (~/.cache/firebase/emulators)",
                    relativePath: ".cache/firebase/emulators",
                    risk: .review,
                    explanation: "Downloaded Cloud Firestore, Storage, and UI emulator JAR/ZIP archives in ~/.cache/firebase/emulators. Firebase credentials and service accounts are strictly protected.",
                    consequence: "Moves cached Firebase emulator JARs to macOS Trash. Never touches Firebase credentials.",
                    regeneration: "Emulator JARs will need to be downloaded again on next `firebase emulators:start`.",
                    cleanContentsOnly: true,
                    supportsAgeFilter: false,
                    requiresRedownload: true
                )
            ]
        default:
            return []
        }
    }

    public func scan(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        let categoryProcs = snapshot.matchingProcesses(for: category)
        var items: [CleanableItem] = []

        if category == .nodeNpm {
            let npmItems = await scanNpmCacheAndNpx(snapshot: snapshot, ageFilter: ageFilter)
            items.append(contentsOf: npmItems)
        }

        for spec in specs {
            let fullPath = "\(home)/\(spec.relativePath)"
            guard FileManager.default.fileExists(atPath: fullPath) else { continue }

            let specProcs: [String]
            if !spec.appProcessNames.isEmpty || !spec.commandTokens.isEmpty {
                specProcs = snapshot.matchingProcesses(forAppNames: spec.appProcessNames, commandTokens: spec.commandTokens)
            } else {
                specProcs = categoryProcs
            }
            let isRunning = !specProcs.isEmpty

            let totalUsage = DiskScanner.shared.measurePath(fullPath, minAgeDays: nil)
            guard totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 else { continue }

            let minDays = (spec.supportsAgeFilter && ageFilter != .all) ? ageFilter.rawValue : nil
            let plan = planner.planDirectoryContents(
                directoryPath: fullPath,
                baseRisk: spec.risk,
                ageFilter: ageFilter,
                supportsAgeFilter: spec.supportsAgeFilter,
                isRunningDependency: false
            )

            let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
            let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })

            let action: CleanupActionType = spec.cleanContentsOnly
                ? .moveToTrashContents(directoryPath: fullPath, minAgeDays: minDays)
                : .moveToTrash(path: fullPath)

            // Emit the main item if it has eligible or too-recent children
            if !plan.eligibleEntries.isEmpty || !plan.tooRecentEntries.isEmpty {
                var detailExplanation = spec.explanation
                if spec.id == "puppeteer-cache" {
                    let browsers = Self.describePuppeteerBrowsers(at: fullPath)
                    if !browsers.isEmpty {
                        detailExplanation += " Installed browsers: \(browsers.joined(separator: ", "))."
                    }
                }
                if spec.supportsAgeFilter && ageFilter != .all && !plan.tooRecentEntries.isEmpty {
                    detailExplanation += " (\(Formatters.bytes(plan.eligibleBytes)) eligible older than \(ageFilter.rawValue)d; \(Formatters.bytes(plan.tooRecentBytes)) preserved as modified recently.)"
                }

                items.append(
                    CleanableItem(
                        id: spec.id,
                        name: spec.name,
                        category: category,
                        path: fullPath,
                        logicalSize: nonProtectedLogical,
                        physicalSize: nonProtectedPhysical,
                        reclaimableSize: isRunning ? 0 : plan.eligibleBytes,
                        lastModified: plan.latestModified ?? totalUsage.lastModified,
                        riskLevel: spec.risk,
                        explanation: detailExplanation,
                        deletionConsequence: spec.consequence,
                        regenerationImpact: spec.regeneration,
                        isRunningDependency: isRunning,
                        runningProcessNames: specProcs,
                        actionType: action,
                        supportsAgeFilter: spec.supportsAgeFilter,
                        plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries),
                        requiresRedownload: spec.requiresRedownload
                    )
                )
            }

            // Emit isolated REVIEW items for any child entries skipped due to protected-looking files (.env, credentials, etc.)
            for protectedEntry in plan.protectedOrReviewEntries {
                let reasonText = protectedEntry.reason ?? "Contains protected-looking environment file. Automatic SAFE cleanup skipped this cache entry."
                items.append(
                    CleanableItem(
                        id: "\(spec.id)-review-\(protectedEntry.name)",
                        name: "\(spec.name) — \(protectedEntry.name) (Skipped for Review)",
                        category: category,
                        path: protectedEntry.path,
                        logicalSize: protectedEntry.logicalBytes,
                        physicalSize: protectedEntry.physicalBytes,
                        reclaimableSize: 0,
                        lastModified: protectedEntry.lastModified,
                        riskLevel: .review,
                        explanation: reasonText,
                        deletionConsequence: "Skipped by automatic SAFE cleanup. Preserved on disk.",
                        regenerationImpact: "Inspect manually in Finder if you want to review this cache entry.",
                        isRunningDependency: isRunning,
                        runningProcessNames: specProcs,
                        actionType: .readOnlyInfo(reason: reasonText),
                        supportsAgeFilter: false,
                        plan: CleanupPlan(entries: [protectedEntry])
                    )
                )
            }
        }

        if category == .generalCaches {
            items.append(contentsOf: scanGoogleCaches(snapshot: snapshot, ageFilter: ageFilter))
            items.append(contentsOf: scanOpenAIAtlasCaches(snapshot: snapshot, ageFilter: ageFilter))

            // Check ~/.cache/firebase for any non-emulator files (e.g. credentials, runtime state) and protect them
            let firebaseRoot = "\(home)/.cache/firebase"
            if FileManager.default.fileExists(atPath: firebaseRoot) {
                let emulatorsPath = URL(fileURLWithPath: "\(firebaseRoot)/emulators").standardizedFileURL.path
                let nonEmulatorsUsage = DiskScanner.shared.measurePath(firebaseRoot, excludedSubpaths: [emulatorsPath])
                if nonEmulatorsUsage.physicalSize > 0 {
                    items.append(
                        CleanableItem(
                            id: "firebase-non-emulator-protected",
                            name: "Firebase Configuration & Credentials (~/.cache/firebase)",
                            category: .generalCaches,
                            path: firebaseRoot,
                            logicalSize: nonEmulatorsUsage.logicalSize,
                            physicalSize: nonEmulatorsUsage.physicalSize,
                            reclaimableSize: 0,
                            lastModified: nonEmulatorsUsage.lastModified,
                            riskLevel: .neverDelete,
                            explanation: "Non-emulator files inside ~/.cache/firebase (protected against credential or session loss).",
                            deletionConsequence: "Protected: Never deleted.",
                            regenerationImpact: "Preserves any Firebase CLI state or credentials.",
                            isRunningDependency: false,
                            runningProcessNames: [],
                            actionType: .readOnlyInfo(reason: "Firebase credentials and configuration are protected."),
                            affectsSessionsOrConfig: true
                        )
                    )
                }
            }
        }

        if category == .xcode {
            // Xcode Archives & UserData (NEVER DELETE)
            for protectedXcode in [
                (id: "xcode-archives-keep", name: "Xcode Archives (~/Library/Developer/Xcode/Archives)", subpath: "Library/Developer/Xcode/Archives", desc: "Signed release archives (.xcarchive) and dSYMs. Never deleted automatically."),
                (id: "xcode-userdata-keep", name: "Xcode UserData & Keybindings (~/Library/Developer/Xcode/UserData)", subpath: "Library/Developer/Xcode/UserData", desc: "Custom Xcode code snippets, themes, keybindings, and provisioning profiles.")
            ] {
                let p = "\(home)/\(protectedXcode.subpath)"
                if FileManager.default.fileExists(atPath: p) {
                    let u = DiskScanner.shared.measurePath(p)
                    if u.physicalSize > 0 {
                        items.append(
                            CleanableItem(
                                id: protectedXcode.id,
                                name: protectedXcode.name,
                                category: .xcode,
                                path: p,
                                logicalSize: u.logicalSize,
                                physicalSize: u.physicalSize,
                                reclaimableSize: 0,
                                lastModified: u.lastModified,
                                riskLevel: .neverDelete,
                                explanation: protectedXcode.desc,
                                deletionConsequence: "Protected: Never deleted automatically.",
                                regenerationImpact: "Contains user release archives or Xcode configuration.",
                                isRunningDependency: false,
                                runningProcessNames: [],
                                actionType: .readOnlyInfo(reason: protectedXcode.desc),
                                affectsSessionsOrConfig: true
                            )
                        )
                    }
                }
            }

            let coreDevicePath = "\(home)/Library/Developer/CoreDevice/DeviceFS"
            if FileManager.default.fileExists(atPath: coreDevicePath) {
                items.append(
                    CleanableItem(
                        id: "xcode-coredevice-virtual-fs",
                        name: "CoreDevice Virtual Filesystem (DeviceFS)",
                        category: .xcode,
                        path: coreDevicePath,
                        logicalSize: 0,
                        physicalSize: 0,
                        reclaimableSize: 0,
                        lastModified: nil,
                        riskLevel: .neverDelete,
                        explanation: "Virtual filesystem exposed by Apple CoreDevice for connected physical iOS devices. May appear as ~40 GB in naive tools, but uses 0 bytes of local SSD space.",
                        deletionConsequence: "Protected: DevCleaner never deletes or counts this virtual mount as reclaimable space.",
                        regenerationImpact: "System-managed virtual mount.",
                        isRunningDependency: false,
                        runningProcessNames: [],
                        actionType: .readOnlyInfo(reason: "Virtual filesystem exposed by Apple CoreDevice.")
                    )
                )
            }
        }

        return items
    }

    private func scanNpmCacheAndNpx(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) async -> [CleanableItem] {
        let capabilities: NpmCapabilities
        if let override = npmCapabilitiesOverride {
            let validRoot = (try? NpmCacheInspector.validateAndCanonicalizeCacheRoot(override.effectiveCacheRoot, homeDirectory: home))
                ?? "\(home)/.npm"
            capabilities = NpmCapabilities(
                npmBinaryPath: override.npmBinaryPath,
                version: override.version,
                effectiveCacheRoot: validRoot,
                supportsCacheVerify: override.supportsCacheVerify,
                supportsCacheClean: override.supportsCacheClean,
                supportsSelectiveNpxRemoval: override.supportsSelectiveNpxRemoval
            )
        } else {
            capabilities = await NpmCacheInspector.discoverCapabilities(
                homeDirectory: home,
                shellRunner: shellRunner
            )
        }

        let cacheRoot = capabilities.effectiveCacheRoot
        let liveUse: NpmLiveUseState
        if let overrideLive = npmLiveUseOverride {
            // Merge snapshot evidence with override
            let snapUse = await NpmCacheInspector.inspectLiveUse(
                cacheRoot: cacheRoot,
                snapshot: snapshot,
                shellRunner: nil,
                includeSystemQueries: false
            )
            var mergedProcs = Set(overrideLive.activeGlobalNpmProcesses).union(snapUse.activeGlobalNpmProcesses)
            let mergedKeys = overrideLive.activeNpxEnvironmentKeys.union(snapUse.activeNpxEnvironmentKeys)
            var mergedByKey = overrideLive.activeProcessesByNpxKey
            for (k, v) in snapUse.activeProcessesByNpxKey {
                mergedByKey[k] = Array(Set(mergedByKey[k] ?? []).union(v)).sorted()
            }
            if !overrideLive.isDeterminedSafely && mergedProcs.isEmpty {
                mergedProcs.insert("undetermined process state")
            }
            liveUse = NpmLiveUseState(
                isDeterminedSafely: overrideLive.isDeterminedSafely && snapUse.isDeterminedSafely,
                activeGlobalNpmProcesses: Array(mergedProcs).sorted(),
                activeNpxEnvironmentKeys: mergedKeys,
                activeProcessesByNpxKey: mergedByKey
            )
        } else {
            liveUse = await NpmCacheInspector.inspectLiveUse(
                cacheRoot: cacheRoot,
                snapshot: snapshot,
                shellRunner: shellRunner,
                includeSystemQueries: npmCapabilitiesOverride == nil
            )
        }

        let cacachePath = "\(cacheRoot)/_cacache"
        let npxPath = "\(cacheRoot)/_npx"
        let logsPath = "\(cacheRoot)/_logs"

        let scopedValidator = SafetyValidator(
            homeDirectory: home,
            additionalAllowedPrefixes: [cacachePath, npxPath, logsPath]
        )
        let scopedPlanner = CleanupPlanner(validator: scopedValidator)
        var items: [CleanableItem] = []

        // 1. npm Download Cache (_cacache)
        if FileManager.default.fileExists(atPath: cacachePath) {
            let totalUsage = DiskScanner.shared.measurePath(cacachePath, minAgeDays: nil)
            if totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 {
                let plan = scopedPlanner.planDirectoryContents(
                    directoryPath: cacachePath,
                    baseRisk: .review,
                    ageFilter: ageFilter,
                    supportsAgeFilter: true,
                    isRunningDependency: false
                )
                let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
                let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })
                let isBlocked = liveUse.hasAnyGlobalOrNpxUse
                let activeProcs = liveUse.allActiveProcessDescriptions

                if !plan.eligibleEntries.isEmpty || !plan.tooRecentEntries.isEmpty {
                    let action: CleanupActionType
                    let consequenceText: String
                    if capabilities.supportsCacheClean, capabilities.npmBinaryPath != nil, plan.protectedOrReviewEntries.isEmpty {
                        action = .npmCacheCommand(cacheRoot: cacheRoot, subcommand: ["cache", "clean", "--force"])
                        consequenceText = "Runs official 'npm cache clean --force --cache \(cacheRoot)' after re-verifying no npm/npx processes or open files are active. Requires explicit user selection."
                    } else {
                        let minDays = ageFilter != .all ? ageFilter.rawValue : nil
                        action = .moveToTrashContents(directoryPath: cacachePath, minAgeDays: minDays)
                        consequenceText = "Moves eligible cached package tarballs in \(cacachePath) to macOS Trash. Requires explicit user selection."
                    }

                    let statusDetail = isBlocked
                        ? " • Status: Active / Protected from cleanup (\(liveUse.activeNpxSummary))"
                        : ""

                    items.append(
                        CleanableItem(
                            id: "npm-cacache",
                            name: "npm Download Cache (_cacache)",
                            category: .nodeNpm,
                            path: cacachePath,
                            logicalSize: nonProtectedLogical,
                            physicalSize: nonProtectedPhysical,
                            reclaimableSize: isBlocked ? 0 : plan.eligibleBytes,
                            lastModified: plan.latestModified ?? totalUsage.lastModified,
                            riskLevel: .review,
                            explanation: "Occupied: \(Formatters.bytes(nonProtectedPhysical)) • Needs Review: \(Formatters.bytes(isBlocked ? 0 : plan.eligibleBytes))\(statusDetail). Content-addressable tarball cache in \(cacachePath). Explicit full cache cleaning requires clear user intent. Credentials (.npmrc), global packages, and project node_modules are outside this rule.",
                            deletionConsequence: consequenceText,
                            regenerationImpact: "Packages are re-downloaded on demand when running npm install.",
                            isRunningDependency: isBlocked,
                            runningProcessNames: activeProcs,
                            actionType: action,
                            supportsAgeFilter: true,
                            plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                        )
                    )

                    if capabilities.supportsCacheVerify && capabilities.npmBinaryPath != nil {
                        items.append(
                            CleanableItem(
                                id: "npm-cache-verify",
                                name: "npm Cache Verify & Garbage Collect (npm cache verify)",
                                category: .nodeNpm,
                                path: cacachePath,
                                logicalSize: 0,
                                physicalSize: 0,
                                reclaimableSize: 0,
                                lastModified: totalUsage.lastModified,
                                riskLevel: .review,
                                explanation: "Maintenance command ('npm cache verify --cache \(cacheRoot)'): verifies cache index integrity and garbage-collects unreferenced content blobs. Exact reclaim is unknown before execution (full download-cache upper bound: \(Formatters.bytes(nonProtectedPhysical))).",
                                deletionConsequence: "Runs official 'npm cache verify --cache \(cacheRoot)'. Never deletes active npx tools, credentials, or project node_modules.",
                                regenerationImpact: "Preserves valid referenced cache blobs and compacts index metadata.",
                                isRunningDependency: isBlocked,
                                runningProcessNames: activeProcs,
                                actionType: .npmCacheCommand(cacheRoot: cacheRoot, subcommand: ["cache", "verify"]),
                                supportsAgeFilter: false
                            )
                        )
                    }
                }

                for protectedEntry in plan.protectedOrReviewEntries {
                    let reasonText = protectedEntry.reason ?? "Contains protected-looking environment or credential file. Skipped for review."
                    items.append(
                        CleanableItem(
                            id: "npm-cacache-review-\(protectedEntry.name)",
                            name: "npm Download Cache (_cacache) — \(protectedEntry.name) (Skipped for Review)",
                            category: .nodeNpm,
                            path: protectedEntry.path,
                            logicalSize: protectedEntry.logicalBytes,
                            physicalSize: protectedEntry.physicalBytes,
                            reclaimableSize: 0,
                            lastModified: protectedEntry.lastModified,
                            riskLevel: .review,
                            explanation: reasonText,
                            deletionConsequence: "Skipped automatically. Preserved on disk.",
                            regenerationImpact: "Inspect manually in Finder if you want to review this cache entry.",
                            isRunningDependency: isBlocked,
                            runningProcessNames: activeProcs,
                            actionType: .readOnlyInfo(reason: reasonText),
                            supportsAgeFilter: false,
                            plan: CleanupPlan(entries: [protectedEntry])
                        )
                    )
                }
            }
        }

        // 2. npm _npx Temporary Packages (_npx)
        if FileManager.default.fileExists(atPath: npxPath) {
            let totalUsage = DiskScanner.shared.measurePath(npxPath, minAgeDays: nil)
            if totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 {
                let plan = scopedPlanner.planDirectoryContents(
                    directoryPath: npxPath,
                    baseRisk: .review,
                    ageFilter: ageFilter,
                    supportsAgeFilter: true,
                    isRunningDependency: false
                )
                let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
                let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })

                if !capabilities.supportsSelectiveNpxRemoval {
                    // Installed npm does NOT provide a documented selective npx-cache removal command => inventory-only
                    let isActive = liveUse.hasAnyGlobalOrNpxUse
                    let activeProcs = liveUse.allActiveProcessDescriptions
                    let statusHeadline = isActive
                        ? "Status: Active / Protected from cleanup"
                        : "Status: Inventory only (selective npx removal unsupported by installed npm)"
                    let activeDetail = isActive
                        ? " Active live use detected (\(liveUse.activeNpxSummary))."
                        : ""

                    if nonProtectedPhysical > 0 || nonProtectedLogical > 0 {
                        items.append(
                            CleanableItem(
                                id: "npm-npx",
                                name: "npm _npx Temporary Packages",
                                category: .nodeNpm,
                                path: npxPath,
                                logicalSize: nonProtectedLogical,
                                physicalSize: nonProtectedPhysical,
                                reclaimableSize: 0,
                                lastModified: plan.latestModified ?? totalUsage.lastModified,
                                riskLevel: .review,
                                explanation: "Occupied: \(Formatters.bytes(nonProtectedPhysical)) • SAFE Reclaimable: 0 B • \(statusHeadline).\(activeDetail) Installed npm\(capabilities.version.map { " (\($0))" } ?? "") does not provide a supported selective npx-cache removal command; DevCleaner keeps _npx inventory-only rather than manually deleting cache environments.",
                                deletionConsequence: "Inventory only (0 B reclaimable). DevCleaner does not blindly filesystem-delete _npx environments.",
                                regenerationImpact: "Preserves active npx tools (such as MCP servers and CLI utilities).",
                                isRunningDependency: isActive,
                                runningProcessNames: activeProcs,
                                actionType: .readOnlyInfo(reason: "\(statusHeadline). Installed npm does not support selective npx-cache removal."),
                                supportsAgeFilter: false,
                                plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                            )
                        )
                    }
                } else {
                    // Installed npm supports selective npx removal (`npm cache npx rm <key>`)
                    let activeEntries = plan.eligibleEntries.filter { liveUse.isNpxKeyActive($0.name) }
                    let inactiveEntries = plan.eligibleEntries.filter { !liveUse.isNpxKeyActive($0.name) }

                    for activeEntry in activeEntries {
                        let keyProcs = liveUse.processes(forKey: activeEntry.name)
                        items.append(
                            CleanableItem(
                                id: "npm-npx-active-\(activeEntry.name)",
                                name: "npm _npx Active Environment — \(activeEntry.name)",
                                category: .nodeNpm,
                                path: activeEntry.path,
                                logicalSize: activeEntry.logicalBytes,
                                physicalSize: activeEntry.physicalBytes,
                                reclaimableSize: 0,
                                lastModified: activeEntry.lastModified,
                                riskLevel: .review,
                                explanation: "Occupied: \(Formatters.bytes(activeEntry.physicalBytes)) • SAFE Reclaimable: 0 B • Status: Active / Protected from cleanup. Currently in use by \(keyProcs.joined(separator: ", ")).",
                                deletionConsequence: "Blocked: Active npx environment cannot be cleaned while in use.",
                                regenerationImpact: "Serving active CLI / MCP tool process.",
                                isRunningDependency: true,
                                runningProcessNames: keyProcs,
                                actionType: .readOnlyInfo(reason: "Status: Active / Protected from cleanup"),
                                supportsAgeFilter: false,
                                plan: CleanupPlan(entries: [activeEntry])
                            )
                        )
                    }

                    if !inactiveEntries.isEmpty && liveUse.isDeterminedSafely && liveUse.activeGlobalNpmProcesses.isEmpty {
                        let inactivePhysical = inactiveEntries.reduce(Int64(0)) { $0 + $1.physicalBytes }
                        let inactiveLogical = inactiveEntries.reduce(Int64(0)) { $0 + $1.logicalBytes }
                        let inactiveKeys = inactiveEntries.map { $0.name }
                        items.append(
                            CleanableItem(
                                id: "npm-npx",
                                name: "npm _npx Temporary Packages",
                                category: .nodeNpm,
                                path: npxPath,
                                logicalSize: inactiveLogical,
                                physicalSize: inactivePhysical,
                                reclaimableSize: inactivePhysical,
                                lastModified: inactiveEntries.compactMap { $0.lastModified }.max() ?? totalUsage.lastModified,
                                riskLevel: .review,
                                explanation: "Occupied (inactive): \(Formatters.bytes(inactivePhysical)) across \(inactiveKeys.count) verified inactive npx environment(s) (\(inactiveKeys.joined(separator: ", "))). Uses supported selective removal ('npm cache npx rm').",
                                deletionConsequence: "Removes selected inactive npx cache keys (\(inactiveKeys.joined(separator: ", "))) via official 'npm cache npx rm' after re-checking live processes and open files.",
                                regenerationImpact: "Re-downloaded automatically the next time you run npx <pkg>.",
                                isRunningDependency: false,
                                runningProcessNames: [],
                                actionType: .npmNpxRemoveKeys(cacheRoot: cacheRoot, keys: inactiveKeys),
                                supportsAgeFilter: true,
                                plan: CleanupPlan(entries: inactiveEntries + plan.tooRecentEntries)
                            )
                        )
                    } else if activeEntries.isEmpty && (!liveUse.isDeterminedSafely || !liveUse.activeGlobalNpmProcesses.isEmpty) {
                        let procs = liveUse.allActiveProcessDescriptions
                        items.append(
                            CleanableItem(
                                id: "npm-npx",
                                name: "npm _npx Temporary Packages",
                                category: .nodeNpm,
                                path: npxPath,
                                logicalSize: nonProtectedLogical,
                                physicalSize: nonProtectedPhysical,
                                reclaimableSize: 0,
                                lastModified: plan.latestModified ?? totalUsage.lastModified,
                                riskLevel: .review,
                                explanation: "Occupied: \(Formatters.bytes(nonProtectedPhysical)) • SAFE Reclaimable: 0 B • Status: Active / Protected from cleanup (\(liveUse.activeNpxSummary)).",
                                deletionConsequence: "Blocked while npm/npx processes are active.",
                                regenerationImpact: "Re-downloaded automatically the next time you run npx <pkg>.",
                                isRunningDependency: true,
                                runningProcessNames: procs,
                                actionType: .npmNpxRemoveKeys(cacheRoot: cacheRoot, keys: plan.eligibleEntries.map { $0.name }),
                                supportsAgeFilter: true,
                                plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                            )
                        )
                    }
                }

                for protectedEntry in plan.protectedOrReviewEntries {
                    let reasonText = protectedEntry.reason ?? "Contains protected-looking environment file. Automatic SAFE cleanup skipped this cache entry."
                    items.append(
                        CleanableItem(
                            id: "npm-npx-review-\(protectedEntry.name)",
                            name: "npm _npx Temporary Packages — \(protectedEntry.name) (Skipped for Review)",
                            category: .nodeNpm,
                            path: protectedEntry.path,
                            logicalSize: protectedEntry.logicalBytes,
                            physicalSize: protectedEntry.physicalBytes,
                            reclaimableSize: 0,
                            lastModified: protectedEntry.lastModified,
                            riskLevel: .review,
                            explanation: reasonText,
                            deletionConsequence: "Skipped by automatic SAFE cleanup. Preserved on disk.",
                            regenerationImpact: "Inspect manually in Finder if you want to review this cache entry.",
                            isRunningDependency: liveUse.isNpxKeyActive(protectedEntry.name),
                            runningProcessNames: liveUse.processes(forKey: protectedEntry.name),
                            actionType: .readOnlyInfo(reason: reasonText),
                            supportsAgeFilter: false,
                            plan: CleanupPlan(entries: [protectedEntry])
                        )
                    )
                }
            }
        }

        // 3. npm Debug Logs (_logs)
        if FileManager.default.fileExists(atPath: logsPath) {
            let totalUsage = DiskScanner.shared.measurePath(logsPath, minAgeDays: nil)
            if totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 {
                let minDays = ageFilter != .all ? ageFilter.rawValue : nil
                let plan = scopedPlanner.planDirectoryContents(
                    directoryPath: logsPath,
                    baseRisk: .safe,
                    ageFilter: ageFilter,
                    supportsAgeFilter: true,
                    isRunningDependency: false
                )
                let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
                let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })
                let isLogsRunning = !liveUse.isDeterminedSafely || !liveUse.activeGlobalNpmProcesses.isEmpty
                if !plan.eligibleEntries.isEmpty || !plan.tooRecentEntries.isEmpty {
                    items.append(
                        CleanableItem(
                            id: "npm-logs",
                            name: "npm Debug Logs",
                            category: .nodeNpm,
                            path: logsPath,
                            logicalSize: nonProtectedLogical,
                            physicalSize: nonProtectedPhysical,
                            reclaimableSize: isLogsRunning ? 0 : plan.eligibleBytes,
                            lastModified: plan.latestModified ?? totalUsage.lastModified,
                            riskLevel: .safe,
                            explanation: "Debug log files from past npm commands in \(logsPath).",
                            deletionConsequence: "Moves eligible npm debug logs to macOS Trash.",
                            regenerationImpact: "Generated only when npm encounters errors or verbose logging.",
                            isRunningDependency: isLogsRunning,
                            runningProcessNames: liveUse.activeGlobalNpmProcesses,
                            actionType: .moveToTrashContents(directoryPath: logsPath, minAgeDays: minDays),
                            supportsAgeFilter: true,
                            plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                        )
                    )
                }
            }
        }

        return items
    }

    private func scanOpenAIAtlasCaches(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) -> [CleanableItem] {
        let atlasRoot = "\(home)/Library/Caches/com.openai.atlas"
        let fm = FileManager.default
        guard fm.fileExists(atPath: atlasRoot) else { return [] }

        let atlasProcs = snapshot.matchingProcesses(
            forAppNames: ["Atlas", "OpenAI Atlas"],
            commandTokens: ["com.openai.atlas"]
        )
        let isRunning = !atlasProcs.isEmpty
        let minDays = ageFilter != .all ? ageFilter.rawValue : nil

        var verifiedRelSubpaths: [String] = [
            "Cache",
            "Code Cache",
            "GPUCache",
            "fsCachedData",
            "com.onevcat.Kingfisher.ImageCache",
            "browser-data/Cache",
            "browser-data/Code Cache",
            "browser-data/GPUCache"
        ]

        let hostRoot = "\(atlasRoot)/browser-data/host"
        if let hostDirs = try? fm.contentsOfDirectory(atPath: hostRoot) {
            for host in hostDirs.sorted() where !host.hasPrefix(".") && host != ".." {
                for sub in ["Cache", "Code Cache", "GPUCache"] {
                    verifiedRelSubpaths.append("browser-data/host/\(host)/\(sub)")
                }
            }
        }

        var items: [CleanableItem] = []
        var excludedSubpaths = Set<String>()

        for relSub in verifiedRelSubpaths {
            let subPath = "\(atlasRoot)/\(relSub)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            excludedSubpaths.insert(URL(fileURLWithPath: subPath).standardizedFileURL.path)

            let totalUsage = DiskScanner.shared.measurePath(subPath, minAgeDays: nil)
            guard totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 else { continue }

            let plan = planner.planDirectoryContents(
                directoryPath: subPath,
                baseRisk: .safe,
                ageFilter: ageFilter,
                supportsAgeFilter: true,
                isRunningDependency: false
            )
            let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
            let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })
            let slug = Self.slugifySubpath(relSub)

            if !plan.eligibleEntries.isEmpty || !plan.tooRecentEntries.isEmpty {
                items.append(
                    CleanableItem(
                        id: "openai-atlas-cache-\(slug)",
                        name: "OpenAI Atlas Verified Cache (com.openai.atlas/\(relSub))",
                        category: .generalCaches,
                        path: subPath,
                        logicalSize: nonProtectedLogical,
                        physicalSize: nonProtectedPhysical,
                        reclaimableSize: isRunning ? 0 : plan.eligibleBytes,
                        lastModified: plan.latestModified ?? totalUsage.lastModified,
                        riskLevel: .safe,
                        explanation: "Explicitly verified regenerable cache directory inside ~/Library/Caches/com.openai.atlas/\(relSub). Non-cache sibling folders (such as Sparkle updater or E5RT bundles) are untouched.",
                        deletionConsequence: "Moves eligible temporary cache files in com.openai.atlas/\(relSub) to macOS Trash.",
                        regenerationImpact: "Automatically regenerated when OpenAI Atlas runs.",
                        isRunningDependency: isRunning,
                        runningProcessNames: atlasProcs,
                        actionType: .moveToTrashContents(directoryPath: subPath, minAgeDays: minDays),
                        supportsAgeFilter: true,
                        plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                    )
                )
            }

            for protectedEntry in plan.protectedOrReviewEntries {
                let reasonText = protectedEntry.reason ?? "Contains protected-looking file. Automatic SAFE cleanup skipped this cache entry."
                items.append(
                    CleanableItem(
                        id: "openai-atlas-cache-\(slug)-review-\(protectedEntry.name)",
                        name: "OpenAI Atlas (\(relSub)) — \(protectedEntry.name) (Skipped for Review)",
                        category: .generalCaches,
                        path: protectedEntry.path,
                        logicalSize: protectedEntry.logicalBytes,
                        physicalSize: protectedEntry.physicalBytes,
                        reclaimableSize: 0,
                        lastModified: protectedEntry.lastModified,
                        riskLevel: .review,
                        explanation: reasonText,
                        deletionConsequence: "Skipped by automatic SAFE cleanup. Preserved on disk.",
                        regenerationImpact: "Inspect manually in Finder if you want to review this entry.",
                        isRunningDependency: isRunning,
                        runningProcessNames: atlasProcs,
                        actionType: .readOnlyInfo(reason: reasonText),
                        supportsAgeFilter: false,
                        plan: CleanupPlan(entries: [protectedEntry])
                    )
                )
            }
        }

        let unverifiedUsage = DiskScanner.shared.measurePath(atlasRoot, excludedSubpaths: excludedSubpaths)
        if unverifiedUsage.physicalSize > 0 || unverifiedUsage.logicalSize > 0 {
            items.append(
                CleanableItem(
                    id: "openai-atlas-unverified-review",
                    name: "OpenAI Atlas Unverified / Updater & Bundle Data (Review / Preserved)",
                    category: .generalCaches,
                    path: atlasRoot,
                    logicalSize: unverifiedUsage.logicalSize,
                    physicalSize: unverifiedUsage.physicalSize,
                    reclaimableSize: 0,
                    lastModified: unverifiedUsage.lastModified,
                    riskLevel: .review,
                    explanation: "Unverified or persistent data inside ~/Library/Caches/com.openai.atlas (such as org.sparkle-project.Sparkle, com.apple.e5rt.e5bundlecache, io.sentry, or non-cache host state). Excluded from Recommended Clean.",
                    deletionConsequence: "Preserved: Broad parent root ~/Library/Caches/com.openai.atlas is never deleted automatically.",
                    regenerationImpact: "Preserves Sparkle updater state, CoreML/E5RT compiled bundles, and unverified data.",
                    isRunningDependency: isRunning,
                    runningProcessNames: atlasProcs,
                    actionType: .readOnlyInfo(reason: "Only explicitly verified regenerable subpaths inside ~/Library/Caches/com.openai.atlas are cleanable.")
                )
            )
        }

        return items
    }

    private func scanGoogleCaches(snapshot: ActiveProcessSnapshot, ageFilter: AgeFilter) -> [CleanableItem] {
        let googleRoot = "\(home)/Library/Caches/Google"
        let fm = FileManager.default
        guard fm.fileExists(atPath: googleRoot) else { return [] }

        let googleProcs = snapshot.matchingProcesses(
            forAppNames: ["Google Chrome"],
            commandTokens: ["Google Chrome.app"]
        )
        let isRunning = !googleProcs.isEmpty
        let minDays = ageFilter != .all ? ageFilter.rawValue : nil

        var verifiedRelSubpaths: [String] = [
            "Cache",
            "Code Cache",
            "GPUCache"
        ]

        let chromeRoot = "\(googleRoot)/Chrome"
        if let profileDirs = try? fm.contentsOfDirectory(atPath: chromeRoot) {
            for profile in profileDirs.sorted() where !profile.hasPrefix(".") && profile != ".." {
                for sub in ["Cache", "Code Cache", "GPUCache", "image_cache"] {
                    verifiedRelSubpaths.append("Chrome/\(profile)/\(sub)")
                }
            }
        }

        var items: [CleanableItem] = []
        var excludedSubpaths = Set<String>()

        for relSub in verifiedRelSubpaths {
            let subPath = "\(googleRoot)/\(relSub)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            excludedSubpaths.insert(URL(fileURLWithPath: subPath).standardizedFileURL.path)

            let totalUsage = DiskScanner.shared.measurePath(subPath, minAgeDays: nil)
            guard totalUsage.physicalSize > 0 || totalUsage.logicalSize > 0 else { continue }

            let plan = planner.planDirectoryContents(
                directoryPath: subPath,
                baseRisk: .safe,
                ageFilter: ageFilter,
                supportsAgeFilter: true,
                isRunningDependency: false
            )
            let nonProtectedPhysical = max(0, totalUsage.physicalSize - plan.protectedOrReviewBytes)
            let nonProtectedLogical = max(0, totalUsage.logicalSize - plan.protectedOrReviewEntries.reduce(0) { $0 + $1.logicalBytes })
            let slug = Self.slugifySubpath(relSub)

            if !plan.eligibleEntries.isEmpty || !plan.tooRecentEntries.isEmpty {
                items.append(
                    CleanableItem(
                        id: "google-caches-\(slug)",
                        name: "Google Verified Cache (Google/\(relSub))",
                        category: .generalCaches,
                        path: subPath,
                        logicalSize: nonProtectedLogical,
                        physicalSize: nonProtectedPhysical,
                        reclaimableSize: isRunning ? 0 : plan.eligibleBytes,
                        lastModified: plan.latestModified ?? totalUsage.lastModified,
                        riskLevel: .safe,
                        explanation: "Explicitly verified regenerable cache directory inside ~/Library/Caches/Google/\(relSub).",
                        deletionConsequence: "Moves eligible cached files in Google/\(relSub) to macOS Trash while preserving unverified sibling folders.",
                        regenerationImpact: "Automatically regenerated by Google applications.",
                        isRunningDependency: isRunning,
                        runningProcessNames: googleProcs,
                        actionType: .moveToTrashContents(directoryPath: subPath, minAgeDays: minDays),
                        supportsAgeFilter: true,
                        plan: CleanupPlan(entries: plan.eligibleEntries + plan.tooRecentEntries)
                    )
                )
            }

            for protectedEntry in plan.protectedOrReviewEntries {
                let reasonText = protectedEntry.reason ?? "Contains protected-looking file. Automatic SAFE cleanup skipped this cache entry."
                items.append(
                    CleanableItem(
                        id: "google-caches-\(slug)-review-\(protectedEntry.name)",
                        name: "Google (\(relSub)) — \(protectedEntry.name) (Skipped for Review)",
                        category: .generalCaches,
                        path: protectedEntry.path,
                        logicalSize: protectedEntry.logicalBytes,
                        physicalSize: protectedEntry.physicalBytes,
                        reclaimableSize: 0,
                        lastModified: protectedEntry.lastModified,
                        riskLevel: .review,
                        explanation: reasonText,
                        deletionConsequence: "Skipped by automatic SAFE cleanup. Preserved on disk.",
                        regenerationImpact: "Inspect manually in Finder if you want to review this entry.",
                        isRunningDependency: isRunning,
                        runningProcessNames: googleProcs,
                        actionType: .readOnlyInfo(reason: reasonText),
                        supportsAgeFilter: false,
                        plan: CleanupPlan(entries: [protectedEntry])
                    )
                )
            }
        }

        let unverifiedUsage = DiskScanner.shared.measurePath(googleRoot, excludedSubpaths: excludedSubpaths)
        if unverifiedUsage.physicalSize > 0 || unverifiedUsage.logicalSize > 0 {
            items.append(
                CleanableItem(
                    id: "google-caches-unverified-review",
                    name: "Google Caches Unverified Data (~/Library/Caches/Google — Review / Preserved)",
                    category: .generalCaches,
                    path: googleRoot,
                    logicalSize: unverifiedUsage.logicalSize,
                    physicalSize: unverifiedUsage.physicalSize,
                    reclaimableSize: 0,
                    lastModified: unverifiedUsage.lastModified,
                    riskLevel: .review,
                    explanation: "Unverified subdirectories or files inside ~/Library/Caches/Google. Excluded from Recommended Clean until explicitly verified as regenerable.",
                    deletionConsequence: "Preserved: Broad parent root ~/Library/Caches/Google is never deleted automatically.",
                    regenerationImpact: "Preserves any unverified Google tool data.",
                    isRunningDependency: isRunning,
                    runningProcessNames: googleProcs,
                    actionType: .readOnlyInfo(reason: "Only explicitly verified regenerable subpaths inside ~/Library/Caches/Google are cleanable.")
                )
            )
        }

        return items
    }

    private static func slugifySubpath(_ relSub: String) -> String {
        let lower = relSub.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func describePuppeteerBrowsers(at puppeteerPath: String) -> [String] {
        let rootURL = URL(fileURLWithPath: puppeteerPath, isDirectory: true)
        guard let browserKinds = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [String] = []
        for kindURL in browserKinds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? kindURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let kindName = kindURL.lastPathComponent
            if let versions = try? FileManager.default.contentsOfDirectory(
                at: kindURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                let vNames = versions.compactMap { vURL -> String? in
                    let vDir = (try? vURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return vDir ? "\(kindName)/\(vURL.lastPathComponent)" : nil
                }.sorted()
                results.append(contentsOf: vNames)
            }
        }
        return results
    }

    public func clean(_ item: CleanableItem, ageFilter: AgeFilter) async throws -> CleanupResult {
        try await executor.execute(item, ageFilter: ageFilter)
    }
}
