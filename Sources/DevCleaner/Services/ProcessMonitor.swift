import Foundation
import AppKit

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var isSuccess: Bool { exitCode == 0 }
}

public final class ShellRunner: Sendable {
    public static let shared = ShellRunner()

    public init() {}

    public func run(_ executable: String, arguments: [String] = [], timeoutSeconds: TimeInterval = 30) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                if let existingPath = env["PATH"] {
                    env["PATH"] = "\(extraPaths):\(existingPath)"
                } else {
                    env["PATH"] = extraPaths
                }
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ShellResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
            }
        }
    }
}

public struct ActiveProcessSnapshot: Sendable {
    public let activeLines: [String]
    public let runningAppNames: Set<String>

    public init(activeLines: [String], runningAppNames: Set<String>) {
        self.activeLines = activeLines
        self.runningAppNames = runningAppNames
    }

    public func matchingProcesses(for category: CleanerCategory) -> [String] {
        var matched = Set<String>()

        func checkApp(_ name: String) -> Bool {
            runningAppNames.contains { $0.localizedCaseInsensitiveContains(name) }
        }

        func checkCommand(_ token: String) -> Bool {
            activeLines.contains { line in
                line.localizedCaseInsensitiveContains(token)
            }
        }

        switch category {
        case .xcode:
            if checkApp("Xcode") || checkCommand("Xcode.app/Contents/MacOS/Xcode") || checkCommand("xcodebuild") {
                matched.insert("Xcode")
            }
        case .iosSimulators:
            if checkApp("Simulator") || checkCommand("Simulator.app") {
                matched.insert("Simulator")
            }
        case .android:
            if checkCommand("qemu-system-aarch64") || checkCommand("qemu-system-x86_64") {
                matched.insert("qemu-system")
            }
            if checkCommand("Android/sdk/emulator/emulator") || checkApp("Android Studio") {
                matched.insert("Android Emulator / Studio")
            }
        case .gradle:
            if checkCommand("GradleDaemon") || checkCommand("org.gradle.launcher") {
                matched.insert("Gradle Daemon")
            }
        case .nodeNpm:
            if checkCommand("/npm ") || checkCommand("npm-cli.js") {
                matched.insert("npm")
            }
        case .cocoapodsSwiftPM:
            if checkCommand("/pod ") || checkCommand("swift-package") || checkCommand("xcodebuild") {
                matched.insert("CocoaPods / SwiftPM build")
            }
        case .homebrew:
            if checkCommand("/brew ") {
                matched.insert("Homebrew")
            }
        case .docker:
            if checkApp("Docker") || checkCommand("com.docker.backend") || checkCommand("Docker Desktop") {
                matched.insert("Docker Desktop")
            }
        case .claude:
            if checkApp("Claude") || checkCommand("Claude.app") || checkCommand("Claude iOS Sim") {
                matched.insert("Claude")
            }
        case .codex:
            if checkApp("Codex") || checkCommand("Codex.app") || checkCommand("com.openai.codex") {
                matched.insert("Codex")
            }
        case .googleAI:
            if checkCommand("AIEdgeForesight") {
                matched.insert("AIEdgeForesight")
            }
        case .generalCaches:
            break
        }

        return Array(matched).sorted()
    }
}

public final class ProcessMonitor: Sendable {
    public static let shared = ProcessMonitor()

    public init() {}

    public func captureSnapshot() async -> ActiveProcessSnapshot {
        let appNames = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        }
        let psResult = await ShellRunner.shared.run("/bin/ps", arguments: ["-axo", "comm=,args="])
        let lines = psResult.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ActiveProcessSnapshot(activeLines: lines, runningAppNames: appNames)
    }
}
