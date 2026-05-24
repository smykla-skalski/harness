import Darwin
import Foundation

/// Thin wrapper around `Foundation.Process` for one-shot subprocess invocations.
public enum ProcessRunner {
    public struct Result {
        public var exitStatus: Int32
        public var stdout: Data
        public var stderr: Data
        public var timedOut: Bool
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
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval? = nil,
        terminationGraceSeconds: TimeInterval = 5
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
        let stdoutCapture = PipeCapture(pipe: stdoutPipe)
        let stderrCapture = PipeCapture(pipe: stderrPipe)
        stdoutCapture.start()
        stderrCapture.start()

        try process.run()

        let timedOut = waitForExit(
            process,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds
        )
        let stdoutData = stdoutCapture.finish()
        let stderrData = stderrCapture.finish()

        return Result(
            exitStatus: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            timedOut: timedOut
        )
    }

    /// Variant that throws when the process exits non-zero.
    @discardableResult
    public static func runChecked(
        _ command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval? = nil,
        terminationGraceSeconds: TimeInterval = 5
    ) throws -> Result {
        let result = try run(
            command, arguments: arguments,
            environmentOverrides: environmentOverrides, workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds, terminationGraceSeconds: terminationGraceSeconds
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

    private static func waitForExit(
        _ process: Process,
        timeoutSeconds: TimeInterval?,
        terminationGraceSeconds: TimeInterval
    ) -> Bool {
        guard let timeoutSeconds else {
            process.waitUntilExit()
            return false
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }

        process.terminate()
        let graceDeadline = Date().addingTimeInterval(terminationGraceSeconds)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }

    private final class PipeCapture: @unchecked Sendable {
        private let pipe: Pipe
        private let lock = NSLock()
        private var captured = Data()

        init(pipe: Pipe) {
            self.pipe = pipe
        }

        func start() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.append(data)
            }
        }

        func finish() -> Data {
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = nil
            drainAvailableData(from: handle.fileDescriptor)
            return snapshot()
        }

        private func append(_ data: Data) {
            lock.lock()
            captured.append(data)
            lock.unlock()
        }

        private func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }

        private func drainAvailableData(from fileDescriptor: Int32) {
            let flags = fcntl(fileDescriptor, F_GETFL)
            guard flags >= 0 else { return }
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(fileDescriptor, F_SETFL, flags) }

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let readCount = read(fileDescriptor, &buffer, buffer.count)
                if readCount > 0 {
                    append(Data(buffer.prefix(readCount)))
                    continue
                }
                if readCount == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
        }
    }
}
