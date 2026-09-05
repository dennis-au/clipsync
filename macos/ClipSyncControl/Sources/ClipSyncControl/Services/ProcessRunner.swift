import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case failedToStart
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            "The Docker command could not start."
        case .timedOut:
            "The Docker command timed out."
        }
    }
}

enum ProcessRunner {
    static func run(executable: URL, arguments: [String], currentDirectory: URL, environment: [String: String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                let completion = DispatchSemaphore(value: 0)
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                process.environment = environment
                process.standardOutput = output
                process.standardError = errors
                process.terminationHandler = { _ in completion.signal() }

                do {
                    try process.run()
                    guard completion.wait(timeout: .now() + timeout) == .success else {
                        process.terminate()
                        _ = completion.wait(timeout: .now() + 5)
                        continuation.resume(throwing: ProcessRunnerError.timedOut)
                        return
                    }
                    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(exitCode: process.terminationStatus, standardOutput: stdout, standardError: stderr))
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.failedToStart)
                }
            }
        }
    }
}
