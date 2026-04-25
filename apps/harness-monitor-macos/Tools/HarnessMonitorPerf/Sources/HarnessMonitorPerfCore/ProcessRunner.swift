import Foundation

/// Thin wrapper around `Foundation.Process` for one-shot subprocess invocations.
public enum ProcessRunner {
    public struct Result {
        public var exitStatus: Int32
        public var stdout: Data
        public var stderr: Data
        public var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        public var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let arguments: [String]
        public let exitStatus: Int32
        public let stderr: String
        public var description: String {
            "\(command) \(arguments.joined(separator: " ")) exited \(exitStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// Runs `command` with `arguments`, returning stdout/stderr/exit. Optionally appends env
    /// overrides on top of the inherited environment.
    @discardableResult
    public static func run(
        _ command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { env[key] = value }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitStatus: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData
        )
    }

    /// Variant that throws when the process exits non-zero.
    @discardableResult
    public static func runChecked(
        _ command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil
    ) throws -> Result {
        let result = try run(
            command, arguments: arguments,
            environmentOverrides: environmentOverrides, workingDirectory: workingDirectory
        )
        guard result.exitStatus == 0 else {
            throw Failure(
                command: command,
                arguments: arguments,
                exitStatus: result.exitStatus,
                stderr: result.stderrString
            )
        }
        return result
    }
}
