import XCTest
@testable import DevCleaner

final class SafetyValidatorTests: XCTestCase {
    private let fakeHome = "/Users/ernesto"
    private var validator: SafetyValidator!

    override func setUp() {
        super.setUp()
        validator = SafetyValidator(homeDirectory: fakeHome)
    }

    func testProtectedDirectoriesAreNeverCleanable() {
        let forbiddenPaths = [
            "~/Developer",
            "~/Developer/MyProject",
            "~/Developer/CleanerApp",
            "~/Developer/DevCleaner",
            "/Users/ernesto/Developer",
            "/Users/ernesto/Developer/App/build",
            "~/.ssh",
            "~/.ssh/id_ed25519",
            "~/.gitconfig",
            "~/Documents",
            "~/Documents/Important.pdf",
            "~/Desktop",
            "~/Desktop/Work",
            "~/Library/Mobile Documents",
            "~/Library/Mobile Documents/com~apple~CloudDocs",
            "~/Library/Keychains",
            "~/Library/Mail",
            "~/Library/Photos",
            "/",
            "/Users/ernesto",
            "~",
            "~/Library",
            "~/Library/Caches",
            "~/Library/Application Support"
        ]

        for path in forbiddenPaths {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Path should be strictly rejected: \(path)"
            )
            XCTAssertThrowsError(try validator.validateForDeletion(path, checkSymlinksOnDisk: false))
        }
    }

    func testProtectedFileComponentsAreNeverCleanableEvenInsideCache() {
        let forbiddenFiles = [
            "~/Library/Developer/Xcode/DerivedData/MyProject/.git",
            "~/Library/Developer/Xcode/DerivedData/MyProject/.git/config",
            "~/Library/Developer/Xcode/DerivedData/MyProject/.env",
            "~/Library/Developer/Xcode/DerivedData/MyProject/.env.local",
            "~/Library/Developer/Xcode/DerivedData/MyProject/.env.production",
            "~/Library/Developer/Xcode/DerivedData/MyProject/GoogleService-Info.plist",
            "~/Library/Developer/Xcode/DerivedData/MyProject/google-services.json",
            "~/Library/Developer/Xcode/DerivedData/MyProject/firebase-adminsdk.json",
            "~/Library/Developer/Xcode/DerivedData/MyProject/firebase-credentials.json",
            "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        ]

        for path in forbiddenFiles {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Component should be strictly rejected: \(path)"
            )
        }
    }

    func testVirtualAndSystemMountedFilesystemsAreBlocked() {
        let virtualPaths = [
            "~/Library/Developer/CoreDevice",
            "~/Library/Developer/CoreDevice/DeviceFS",
            "~/Library/Developer/CoreDevice/DeviceFS/some-device",
            "/Library/Developer/CoreSimulator/Volumes",
            "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133",
            "~/Library/Developer/CoreSimulator/Devices",
            "~/Library/Developer/CoreSimulator/Devices/83050079-F7C5-4F34-AD3A-E6CBF1130330"
        ]

        for path in virtualPaths {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Virtual/system/simctl path must be blocked from manual file deletion: \(path)"
            )
        }
    }

    func testClaudeAndCodexSessionsAreProtected() {
        let sessionPaths = [
            "~/Library/Application Support/Claude",
            "~/Library/Application Support/Claude/config.json",
            "~/Library/Application Support/Claude/side-session-notes",
            "~/Library/Application Support/Claude/Local Storage",
            "~/Library/Application Support/Codex",
            "~/Library/Application Support/Codex/artifact-sessions",
            "~/Library/Application Support/Codex/Cookies",
            "~/Library/Application Support/com.google.AIEdgeForesight/database.sqlite"
        ]

        for path in sessionPaths {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Session/config path must be rejected: \(path)"
            )
        }
    }

    func testParentDirectoryTraversalIsRejected() {
        let traversalAttempts = [
            "~/Library/Developer/Xcode/DerivedData/../../../Documents",
            "~/Library/Caches/Homebrew/../../Application Support/Claude/config.json",
            "/Users/ernesto/.gradle/caches/../../Developer/DevCleaner",
            "../Developer",
            "~/.npm/_cacache/.."
        ]

        for attempt in traversalAttempts {
            XCTAssertThrowsError(try validator.validateForDeletion(attempt, checkSymlinksOnDisk: false)) { error in
                XCTAssertEqual(error as? SafetyError, SafetyError.containsParentTraversal(attempt))
            }
        }
    }

    func testSymlinkEscapingAllowListIsRejected() throws {
        // Create a temporary directory inside an allowed location or test symlink resolution using a temp validator
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DevCleanerSymlinkTest-\(UUID().uuidString)")
        let allowedDir = tempRoot.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        let forbiddenDir = tempRoot.appendingPathComponent("Developer/SecretProject", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forbiddenDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let symlinkURL = allowedDir.appendingPathComponent("malicious-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: forbiddenDir)

        let tempValidator = SafetyValidator(homeDirectory: tempRoot.path)
        XCTAssertThrowsError(try tempValidator.validateForDeletion(symlinkURL.path, checkSymlinksOnDisk: true)) { error in
            guard case SafetyError.symlinkTraversalRejected = error else {
                XCTFail("Expected symlinkTraversalRejected, got \(error)")
                return
            }
        }
    }

    func testExplicitAllowListedPathsArePermitted() throws {
        let allowedPaths = [
            "~/Library/Developer/Xcode/DerivedData",
            "~/Library/Developer/Xcode/DerivedData/SomeProject-abc",
            "~/.gradle/caches",
            "~/.gradle/caches/modules-2",
            "~/.npm/_cacache",
            "~/.npm/_npx",
            "~/.cache/codex-runtimes",
            "~/Library/Caches/Homebrew",
            "~/Library/Caches/CocoaPods",
            "~/Library/Caches/org.swift.swiftpm",
            "~/Library/Application Support/Claude/Cache",
            "~/Library/Application Support/Claude/Code Cache",
            "~/Library/Application Support/Claude/simulator-builds",
            "~/Library/Application Support/Claude/vm_bundles",
            "~/Library/Application Support/com.google.AIEdgeForesight/models",
            "~/Library/Application Support/com.google.AIEdgeForesight/model_cache"
        ]

        for path in allowedPaths {
            let normalized = try validator.validateForDeletion(path, checkSymlinksOnDisk: false)
            XCTAssertTrue(normalized.hasPrefix("/Users/ernesto/"))
        }
    }

    func testFirebaseDependencyMetadataInCachesIsPermitted() throws {
        let validPackageMetadataPaths = [
            "~/.npm/_npx/8843fba6d2859245/node_modules/firebase-tools/schema/firebase-config.json",
            "~/.npm/_npx/8843fba6d2859245/firebase-config.json",
            "~/.gradle/caches/9.3.1/transforms/07298d8900aeb663b234fa79a0c1cdfa/transformed/com.google.firebase.encoders.json",
            "~/.gradle/caches/com.google.firebase.encoders.json"
        ]

        for path in validPackageMetadataPaths {
            XCTAssertTrue(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Package metadata inside allow-listed cache must be allowed: \(path)"
            )
            let normalized = try validator.validateForDeletion(path, checkSymlinksOnDisk: false)
            XCTAssertTrue(normalized.hasPrefix("/Users/ernesto/"))
        }
    }

    func testKnownSensitiveCredentialFilesAreStrictlyBlocked() {
        let sensitiveCredentialPaths = [
            "~/.npm/_npx/8843fba6d2859245/GoogleService-Info.plist",
            "~/.gradle/caches/google-services.json",
            "~/.npm/_npx/firebase-adminsdk-abc123.json",
            "~/.npm/_npx/application_default_credentials.json",
            "~/.gradle/caches/service-account.json",
            "~/.gradle/caches/service_account.json",
            "~/.npm/_cacache/credentials.json",
            "~/.npm/_cacache/credentials_prod.json",
            "~/.gradle/caches/client_secret_123.json",
            "~/.gradle/caches/client_secret.json",
            "~/.npm/_npx/.env"
        ]

        for path in sensitiveCredentialPaths {
            XCTAssertFalse(
                validator.isSafeToDelete(path, checkSymlinksOnDisk: false),
                "Sensitive credential file must be blocked: \(path)"
            )
            XCTAssertThrowsError(try validator.validateForDeletion(path, checkSymlinksOnDisk: false))
        }
    }
}
