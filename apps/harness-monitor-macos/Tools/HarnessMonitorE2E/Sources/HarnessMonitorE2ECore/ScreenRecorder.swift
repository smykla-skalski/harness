import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 15.0, *)
public enum ScreenRecorder {
  public enum Failure: Error, CustomStringConvertible, Equatable {
    case monitorWindowNotFound
    case monitorDisplayNotFound
    case monitorWindowStartTimedOut(TimeInterval)
    case ambiguousMonitorWindows(Int)
    case recordingStartTimedOut
    case recordingMaxDurationExceeded(TimeInterval)
    case recordingFailed(String)
    case recordingBootstrapStalled(stage: String, seconds: TimeInterval)

    public var description: String {
      switch self {
      case .monitorWindowNotFound:
        return "Could not resolve a shareable Harness Monitor main window for recording"
      case .monitorDisplayNotFound:
        return "Could not resolve a shareable display containing the Harness Monitor window"
      case .monitorWindowStartTimedOut(let seconds):
        return
          "Timed out waiting \(Int(seconds)) seconds for a shareable Harness Monitor main window"
      case .ambiguousMonitorWindows(let count):
        return
          "Resolved \(count) shareable Harness Monitor main windows; recording requires exactly one"
      case .recordingStartTimedOut:
        return "Timed out waiting for native screen recording to start"
      case .recordingMaxDurationExceeded(let seconds):
        return "Native screen recording exceeded the maximum duration of \(Int(seconds)) seconds"
      case .recordingFailed(let detail):
        return "Native screen recording failed: \(detail)"
      case .recordingBootstrapStalled(let stage, let seconds):
        return
          "ScreenCaptureKit bootstrap stalled at stage=\(stage) after \(Int(seconds))s; replayd may need a kickstart"
      }
    }
  }

  public static func run(
    outputURL: URL,
    logURL: URL,
    manifestURL: URL,
    controlDirectoryURL: URL? = nil,
    maxDurationSeconds: TimeInterval? = nil
  ) throws {
    let runner = Runner(
      outputURL: outputURL,
      logURL: logURL,
      manifestURL: manifestURL,
      controlDirectoryURL: controlDirectoryURL,
      maxDurationSeconds: maxDurationSeconds
    )
    try runner.run()
  }
}

@available(macOS 15.0, *)
private final class Runner: NSObject, SCRecordingOutputDelegate {
  private static let windowResolutionTimeout: TimeInterval = 15
  private static let windowResolutionPollInterval: TimeInterval = 0.2
  // Hard upper bound for each ScreenCaptureKit bootstrap step. After the
  // recorder warms up CoreGraphics the real bootstrap completes in well
  // under a second, so a tight 5s budget surfaces any genuine SCK stall
  // fast without false-firing on a slow first-launch.
  private static let bootstrapStepTimeout: TimeInterval = 5

  private enum StopReason {
    case requested
    case interrupted
    case maxDurationExceeded(TimeInterval)
  }

  private let outputURL: URL
  private let logURL: URL
  private let manifestURL: URL
  private let controlDirectoryURL: URL?
  private let maxDurationSeconds: TimeInterval?
  private let startSemaphore = DispatchSemaphore(value: 0)
  private let stopSemaphore = DispatchSemaphore(value: 0)
  private let stateLock = NSLock()
  private var state = RunnerState()
  private var signalSources: [DispatchSourceSignal] = []
  private var stream: SCStream?
  private var recordingOutput: SCRecordingOutput?

  init(
    outputURL: URL,
    logURL: URL,
    manifestURL: URL,
    controlDirectoryURL: URL?,
    maxDurationSeconds: TimeInterval?
  ) {
    self.outputURL = outputURL
    self.logURL = logURL
    self.manifestURL = manifestURL
    self.controlDirectoryURL = controlDirectoryURL
    self.maxDurationSeconds = maxDurationSeconds
  }

  func run() throws {
    try prepareFilesystem()
    try warmUpCoreGraphics()
    installSignalHandlers()

    let captureTarget: CaptureTarget
    do {
      guard
        let resolvedTarget = try ScreenRecorderStartGate.awaitStartThenResolve(
          waitForStartRequest: waitForStartRequestIfNeeded,
          resolveCapture: resolveWindowIfAvailable,
          timeout: Self.windowResolutionTimeout,
          pollInterval: Self.windowResolutionPollInterval
        )
      else {
        try appendLog("recording-cancelled-before-start")
        return
      }
      captureTarget = resolvedTarget
    } catch let failure as ScreenRecorder.Failure {
      if case .monitorWindowStartTimedOut(let seconds) = failure {
        try? appendLog(
          "recording-window-timeout seconds=\(Int(seconds)) summary=\(lastWindowProbeSummary())"
        )
      }
      throw failure
    }

    let recordingConfiguration = SCRecordingOutputConfiguration()
    recordingConfiguration.outputURL = outputURL
    recordingConfiguration.outputFileType = .mov
    recordingConfiguration.videoCodecType = .h264

    try appendLog("recording-create-filter-begin")
    let captureWindow = captureTarget.window
    let filter = try boundedFilterCreate(window: captureWindow)
    try appendLog("recording-create-filter-returned")

    let streamConfiguration = SCStreamConfiguration()
    streamConfiguration.showsCursor = true
    streamConfiguration.capturesAudio = false
    streamConfiguration.ignoreShadowsSingleWindow = true

    let pixelScale = filter.pointPixelScale
    let contentSize = filter.contentRect.size
    streamConfiguration.width = max(1, Int(ceil(contentSize.width * CGFloat(pixelScale))))
    streamConfiguration.height = max(1, Int(ceil(contentSize.height * CGFloat(pixelScale))))
    try appendLog("recording-create-stream-begin")
    let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
    try appendLog("recording-create-stream-returned")
    try appendLog("recording-create-output-begin")
    let recordingOutput = SCRecordingOutput(
      configuration: recordingConfiguration,
      delegate: self
    )
    try appendLog("recording-create-output-returned")
    self.stream = stream
    self.recordingOutput = recordingOutput

    try appendLog("recording-add-output")
    try stream.addRecordingOutput(recordingOutput)
    try appendLog("recording-start-capture-begin")
    try boundedStartCapture(stream: stream)
    try appendLog("recording-start-capture-returned")

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

    let stopReason = waitForStopSignal(recordingStartedAt: Date())

    if let failure = consumeFailure() {
      throw failure
    }

    try? stream.removeRecordingOutput(recordingOutput)
    try runAsync { try await stream.stopCapture() }
    if let failure = consumeFailure() {
      throw failure
    }
    try appendLog("recording-finished output=\(outputURL.path)")
    if case .maxDurationExceeded(let seconds) = stopReason {
      throw ScreenRecorder.Failure.recordingMaxDurationExceeded(seconds)
    }
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

  /// Establish a connection to the WindowServer before any
  /// ScreenCaptureKit call. The recorder runs as a plain CLI helper that
  /// never instantiates `NSApplication`, so the first CG entry point inside
  /// `SCContentFilter(desktopIndependentWindow:)` traps with
  /// `Assertion failed: (did_initialize), function CGS_REQUIRE_INIT,
  /// file CGInitialization.c, line 44.` and aborts the process before
  /// any further log line lands on disk. Touching `NSApplication.shared`
  /// performs the WindowServer handshake; calling `CGMainDisplayID()`
  /// guarantees CG is fully primed for the subsequent SCK calls.
  private func warmUpCoreGraphics() throws {
    _ = NSApplication.shared
    let mainDisplay = CGMainDisplayID()
    try appendLog("recording-cg-warmup main_display=\(mainDisplay)")
  }

  private struct CaptureTarget {
    let display: SCDisplay
    let window: SCWindow
  }

  private func resolveWindowIfAvailable() throws -> CaptureTarget? {
    let content = try runAsync { try await SCShareableContent.current }
    let candidates = content.windows.map { window in
      ScreenRecorderWindowCandidate(
        windowID: window.windowID,
        title: window.title ?? "",
        bundleIdentifier: window.owningApplication?.bundleIdentifier,
        isOnScreen: window.isOnScreen
      )
    }
    let harnessWindowSummary =
      candidates
      .filter { ($0.bundleIdentifier ?? "").contains("io.harnessmonitor") }
      .map { candidate in
        let title = candidate.title.isEmpty ? "<empty>" : candidate.title
        return
          "id=\(candidate.windowID),bundle=\(candidate.bundleIdentifier ?? "?"),title=\(title),onScreen=\(candidate.isOnScreen)"
      }
      .joined(separator: " | ")
    updateWindowProbeSummary(
      harnessWindowSummary.isEmpty ? "no-harness-windows" : harnessWindowSummary
    )
    guard
      let selectedWindow = try ScreenRecorderWindowSelector.captureWindowIfAvailable(
        from: candidates)
    else {
      return nil
    }
    guard
      let captureWindow = content.windows.first(where: { $0.windowID == selectedWindow.windowID })
    else {
      throw ScreenRecorder.Failure.monitorWindowNotFound
    }
    let displayCandidates = content.displays.map { display in
      ScreenRecorderDisplayCandidate(displayID: display.displayID, frame: display.frame)
    }
    let frameWidth = Int(ceil(captureWindow.frame.width))
    let frameHeight = Int(ceil(captureWindow.frame.height))
    let originX = Int(captureWindow.frame.origin.x)
    let originY = Int(captureWindow.frame.origin.y)
    try appendLog(
      "selecting-window id=\(selectedWindow.windowID) bundle_id=\(selectedWindow.bundleIdentifier ?? "?") title=\(selectedWindow.title) frame=\(frameWidth)x\(frameHeight)+\(originX)+\(originY)"
    )
    let readiness = ScreenRecorderWindowReadiness.evaluate(
      windowFrame: captureWindow.frame,
      displays: displayCandidates
    )
    let selectedDisplayCandidate: ScreenRecorderDisplayCandidate
    switch readiness {
    case .notReady(let reason):
      try? appendLog(
        "window-not-ready id=\(selectedWindow.windowID) reason=\(reason) frame=\(frameWidth)x\(frameHeight)+\(originX)+\(originY)"
      )
      return nil
    case .ready(let candidate):
      selectedDisplayCandidate = candidate
    }
    guard
      let captureDisplay = content.displays.first(where: {
        $0.displayID == selectedDisplayCandidate.displayID
      })
    else {
      throw ScreenRecorder.Failure.monitorDisplayNotFound
    }
    try appendLog(
      "using-window id=\(selectedWindow.windowID) title=\(selectedWindow.title) bundle_id=\(selectedWindow.bundleIdentifier ?? "?") display_id=\(selectedDisplayCandidate.displayID) size=\(frameWidth)x\(frameHeight)"
    )
    return CaptureTarget(display: captureDisplay, window: captureWindow)
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

  private func updateWindowProbeSummary(_ summary: String) {
    stateLock.lock()
    let changed = state.lastWindowProbeSummary != summary
    state.lastWindowProbeSummary = summary
    stateLock.unlock()
    guard changed else {
      return
    }
    try? appendLog("recording-window-probe \(summary)")
  }

  private func lastWindowProbeSummary() -> String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return state.lastWindowProbeSummary
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

  private func waitForStopSignal(recordingStartedAt: Date) -> StopReason {
    let durationBudget = RecordingDurationBudget(
      maxDuration: maxDurationSeconds,
      pollInterval: 0.2
    )
    let stopRequestURL = controlDirectoryURL?.appendingPathComponent("stop.request")
    while true {
      if let stopRequestURL, FileManager.default.fileExists(atPath: stopRequestURL.path) {
        return .requested
      }
      guard
        let waitInterval = durationBudget.nextWaitInterval(
          startedAt: recordingStartedAt,
          now: Date()
        )
      else {
        let limit = maxDurationSeconds ?? 0
        try? appendLog("recording-auto-stop reason=max-duration seconds=\(Int(limit))")
        return .maxDurationExceeded(limit)
      }
      if stopSemaphore.wait(timeout: .now() + waitInterval) == .success {
        return .interrupted
      }
    }
  }

  private func boundedFilterCreate(window: SCWindow) throws -> SCContentFilter {
    let result: BoundedAsyncResult<SCContentFilter> = try runAsyncBounded(
      timeout: Self.bootstrapStepTimeout
    ) {
      SCContentFilter(desktopIndependentWindow: window)
    }
    switch result {
    case .completed(let filter):
      return filter
    case .timedOut:
      try? appendLog(
        "recording-stream-stalled stage=filter-init seconds=\(Int(Self.bootstrapStepTimeout))"
      )
      throw ScreenRecorder.Failure.recordingBootstrapStalled(
        stage: "filter-init", seconds: Self.bootstrapStepTimeout
      )
    }
  }

  private func boundedStartCapture(stream: SCStream) throws {
    let result: BoundedAsyncResult<Void> = try runAsyncBounded(
      timeout: Self.bootstrapStepTimeout
    ) {
      try await stream.startCapture()
    }
    switch result {
    case .completed:
      return
    case .timedOut:
      try? appendLog(
        "recording-stream-stalled stage=start-capture seconds=\(Int(Self.bootstrapStepTimeout))"
      )
      throw ScreenRecorder.Failure.recordingBootstrapStalled(
        stage: "start-capture", seconds: Self.bootstrapStepTimeout
      )
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
  var lastWindowProbeSummary = "uninitialized"
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
