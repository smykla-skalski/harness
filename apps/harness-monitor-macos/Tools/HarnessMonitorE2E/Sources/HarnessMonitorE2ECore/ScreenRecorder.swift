import AVFoundation
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 15.0, *)
public enum ScreenRecorder {
    public enum Failure: Error, CustomStringConvertible {
        case noDisplays
        case recordingStartTimedOut
        case recordingFailed(String)

        public var description: String {
            switch self {
            case .noDisplays:
                return "No shareable displays were available for screen recording"
            case .recordingStartTimedOut:
                return "Timed out waiting for native screen recording to start"
            case .recordingFailed(let detail):
                return "Native screen recording failed: \(detail)"
            }
        }
    }

    public static func run(
        outputURL: URL,
        logURL: URL,
        manifestURL: URL,
        controlDirectoryURL: URL? = nil
    ) throws {
        let runner = Runner(
            outputURL: outputURL,
            logURL: logURL,
            manifestURL: manifestURL,
            controlDirectoryURL: controlDirectoryURL
        )
        try runner.run()
    }
}

@available(macOS 15.0, *)
private final class Runner: NSObject, SCRecordingOutputDelegate {
    private let outputURL: URL
    private let logURL: URL
    private let manifestURL: URL
    private let controlDirectoryURL: URL?
    private let startSemaphore = DispatchSemaphore(value: 0)
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var state = RunnerState()
    private var signalSources: [DispatchSourceSignal] = []
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    init(outputURL: URL, logURL: URL, manifestURL: URL, controlDirectoryURL: URL?) {
        self.outputURL = outputURL
        self.logURL = logURL
        self.manifestURL = manifestURL
        self.controlDirectoryURL = controlDirectoryURL
    }

    func run() throws {
        try prepareFilesystem()
        installSignalHandlers()

        let display = try resolveDisplay()
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = display.width
        streamConfiguration.height = display.height
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        self.stream = stream
        self.recordingOutput = recordingOutput

        if !waitForStartRequestIfNeeded() {
            try appendLog("recording-cancelled-before-start")
            return
        }

        try stream.addRecordingOutput(recordingOutput)
        try runAsync { try await stream.startCapture() }

        let startStatus = startSemaphore.wait(timeout: .now() + 5)
        if let failure = consumeFailure() {
            throw failure
        }
        guard startStatus == .success else {
            throw ScreenRecorder.Failure.recordingStartTimedOut
        }

        let manifest = ScreenRecordingManifest(
            processID: getpid(),
            outputPath: outputURL.path,
            logPath: logURL.path
        )
        try manifest.write(to: manifestURL)
        try appendLog("recording-ready output=\(outputURL.path)")

        waitForStopSignal()

        if let failure = consumeFailure() {
            throw failure
        }

        try? stream.removeRecordingOutput(recordingOutput)
        try runAsync { try await stream.stopCapture() }
        if let failure = consumeFailure() {
            throw failure
        }
        try appendLog("recording-finished output=\(outputURL.path)")
    }

    func recordingOutputDidStartRecording(_: SCRecordingOutput) {
        try? appendLog("recording-started")
        try? writeStartAcknowledgementIfNeeded()
        startSemaphore.signal()
    }

    func recordingOutputDidFinishRecording(_: SCRecordingOutput) {
        try? appendLog("recording-output-finished")
    }

    func recordingOutput(_: SCRecordingOutput, didFailWithError error: any Error) {
        storeFailure(ScreenRecorder.Failure.recordingFailed(error.localizedDescription))
        startSemaphore.signal()
        stopSemaphore.signal()
    }

    private func prepareFilesystem() throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let controlDirectoryURL {
            try FileManager.default.createDirectory(
                at: controlDirectoryURL,
                withIntermediateDirectories: true
            )
            for marker in [
                controlDirectoryURL.appendingPathComponent("start.request"),
                controlDirectoryURL.appendingPathComponent("start.ready"),
                controlDirectoryURL.appendingPathComponent("stop.request"),
            ] {
                try? FileManager.default.removeItem(at: marker)
            }
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    private func resolveDisplay() throws -> SCDisplay {
        let content = try runAsync { try await SCShareableContent.current }
        guard let display = content.displays.first else {
            throw ScreenRecorder.Failure.noDisplays
        }
        try appendLog("using-display id=\(display.displayID) size=\(display.width)x\(display.height)")
        return display
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in
                try? self?.appendLog("received-signal \(signalNumber)")
                self?.stopSemaphore.signal()
            }
            source.resume()
            return source
        }
    }

    private func appendLog(_ message: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }

    private func storeFailure(_ failure: ScreenRecorder.Failure) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if state.failure == nil {
            state.failure = failure
        }
    }

    private func consumeFailure() -> ScreenRecorder.Failure? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.failure
    }

    private func waitForStartRequestIfNeeded() -> Bool {
        guard let controlDirectoryURL else {
            return true
        }

        let requestURL = controlDirectoryURL.appendingPathComponent("start.request")
        while true {
            if FileManager.default.fileExists(atPath: requestURL.path) {
                return true
            }
            if stopSemaphore.wait(timeout: .now() + 0.2) == .success {
                return false
            }
        }
    }

    private func writeStartAcknowledgementIfNeeded() throws {
        guard let controlDirectoryURL else {
            return
        }

        let ackURL = controlDirectoryURL.appendingPathComponent("start.ready")
        try Data().write(to: ackURL, options: .atomic)
    }

    private func waitForStopSignal() {
        guard let controlDirectoryURL else {
            stopSemaphore.wait()
            return
        }

        let stopRequestURL = controlDirectoryURL.appendingPathComponent("stop.request")
        while true {
            if FileManager.default.fileExists(atPath: stopRequestURL.path) {
                return
            }
            if stopSemaphore.wait(timeout: .now() + 0.2) == .success {
                return
            }
        }
    }

    private func runAsync<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = TaskResultBox<T>()
        Task {
            do {
                resultBox.result = .success(try await operation())
            } catch {
                resultBox.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try resultBox.unwrap()
    }
}

@available(macOS 15.0, *)
private struct RunnerState {
    var failure: ScreenRecorder.Failure?
}

@available(macOS 15.0, *)
private final class TaskResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?

    func unwrap() throws -> T {
        guard let result else {
            throw ScreenRecorder.Failure.recordingFailed("async bridge returned no result")
        }
        return try result.get()
    }
}
