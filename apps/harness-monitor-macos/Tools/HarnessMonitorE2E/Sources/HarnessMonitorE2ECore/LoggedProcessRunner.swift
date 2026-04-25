import Foundation

struct LoggedProcessRunner {
    struct Result {
        let exitStatus: Int32
        let terminationReason: String?
    }

    private let environment: [String: String]
    private let pollInterval: TimeInterval
    private let stdoutHandle: FileHandle

    init(
        environment: [String: String],
        pollInterval: TimeInterval = 0.2,
        stdoutHandle: FileHandle = .standardOutput
    ) {
        self.environment = environment
        self.pollInterval = pollInterval
        self.stdoutHandle = stdoutHandle
    }

    func run(
        executable: URL,
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        logURL: URL,
        terminationTrigger: (() -> String?)? = nil
    ) throws -> Result {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(extraEnvironment) { _, new in new }

        let pipe = Pipe()
        let relay = LoggedProcessRelay(
            readHandle: pipe.fileHandleForReading,
            logHandle: logHandle,
            stdoutHandle: stdoutHandle
        )
        defer { relay.stop() }

        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        var terminationReason: String?
        while process.isRunning {
            if terminationReason == nil, let reason = terminationTrigger?() {
                terminationReason = reason
                ProcessCleanup.terminateTree(rootPID: process.processIdentifier)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        process.waitUntilExit()
        Thread.sleep(forTimeInterval: pollInterval)
        return Result(
            exitStatus: process.terminationStatus,
            terminationReason: terminationReason
        )
    }
}

private final class LoggedProcessRelay: @unchecked Sendable {
    private let readHandle: FileHandle
    private let logHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let lock = NSLock()

    init(readHandle: FileHandle, logHandle: FileHandle, stdoutHandle: FileHandle) {
        self.readHandle = readHandle
        self.logHandle = logHandle
        self.stdoutHandle = stdoutHandle
        readHandle.readabilityHandler = { [weak self] handle in
            self?.drain(handle)
        }
    }

    func stop() {
        readHandle.readabilityHandler = nil
        try? readHandle.close()
    }

    private func drain(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        lock.lock()
        defer { lock.unlock() }
        stdoutHandle.write(data)
        try? logHandle.write(contentsOf: data)
    }
}
