import ArgumentParser
import Foundation
import HarnessMonitorE2ECore

/// Parent subcommand surface for the recording-triage detection routines.
/// Each sub-subcommand reads its inputs from disk or flags, runs the matching
/// detector in HarnessMonitorE2ECore, and prints a JSON document on stdout so
/// shell wrappers can drop the result straight into the per-run
/// `recording-triage/` directory.
struct RecordingTriageCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recording-triage",
    abstract: "Mechanical detectors that walk a swarm-full-flow recording.",
    subcommands: [
      FrameGapsCommand.self,
      DeadHeadTailCommand.self,
      CompareFramesCommand.self,
      LayoutDriftCommand.self,
      BlackFramesCommand.self,
      ThrashCommand.self,
      ActTimingCommand.self,
      ActIdentifiersCommand.self,
      EmitChecklistCommand.self,
    ]
  )
}

private let prettyEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  return encoder
}()

private func emit<T: Encodable>(_ value: T) throws {
  let data = try prettyEncoder.encode(value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

private func parseIdleSegments(_ raw: [String]) throws -> [ClosedRange<Double>] {
  try raw.map { entry in
    let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      let start = Double(parts[0]),
      let end = Double(parts[1]),
      start <= end
    else {
      throw ValidationError("--idle-segment expected start:end seconds; got '\(entry)'")
    }
    return start...end
  }
}

private func parseNamePathPair(_ entry: String) throws -> (name: String, url: URL) {
  guard let separator = entry.firstIndex(of: "=") else {
    throw ValidationError("expected NAME=PATH; got '\(entry)'")
  }
  let name = String(entry[..<separator])
  let path = String(entry[entry.index(after: separator)...])
  guard !name.isEmpty, !path.isEmpty else {
    throw ValidationError("expected NAME=PATH with non-empty halves; got '\(entry)'")
  }
  return (name: name, url: URL(fileURLWithPath: path))
}

// MARK: - frame-gaps

struct FrameGapsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "frame-gaps",
    abstract: "Classify ffprobe frame timestamps into hitches/freezes/stalls."
  )

  @Option(name: .long, help: "Path to ffprobe output (-show_frames -of compact=p=0).")
  var ffprobeOutput: String

  @Option(
    name: .long,
    parsing: .singleValue,
    help:
      "Repeatable idle range in seconds (start:end); gaps inside become stalls when over the stall threshold."
  )
  var idleSegment: [String] = []

  func run() throws {
    let raw = try String(contentsOf: URL(fileURLWithPath: ffprobeOutput), encoding: .utf8)
    let timestamps = RecordingTriage.parseFrameTimestamps(fromFFprobe: raw)
    let segments = try parseIdleSegments(idleSegment)
    let report = RecordingTriage.analyzeFrameGaps(timestamps: timestamps, idleSegments: segments)
    try emit(report)
  }
}

// MARK: - dead-head-tail

struct DeadHeadTailCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dead-head-tail",
    abstract: "Compare recording bounds against app-lifecycle markers."
  )

  @Option(name: .long, help: "Recording start epoch in seconds.") var recordingStart: Double
  @Option(name: .long, help: "Recording end epoch in seconds.") var recordingEnd: Double
  @Option(name: .long, help: "App launch epoch in seconds.") var appLaunch: Double
  @Option(name: .long, help: "App terminate epoch in seconds.") var appTerminate: Double
  @Option(name: .long, help: "Threshold in seconds (default 5).") var threshold: Double = 5.0

  func run() throws {
    let report = RecordingTriage.analyzeDeadHeadTail(
      recordingStartEpoch: recordingStart,
      recordingEndEpoch: recordingEnd,
      appLaunchEpoch: appLaunch,
      appTerminateEpoch: appTerminate,
      threshold: threshold
    )
    try emit(report)
  }
}

// MARK: - compare-frames

struct CompareFramesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "compare-frames",
    abstract: "Compare candidate keyframes against ground-truth UI snapshots via perceptual hash."
  )

  @Option(
    parsing: .singleValue,
    help: "Repeatable NAME=PATH for an extracted keyframe."
  )
  var candidate: [String]

  @Option(
    parsing: .singleValue,
    help: "Repeatable NAME=PATH for a ground-truth UI snapshot."
  )
  var groundTruth: [String]

  @Option(
    name: .long,
    help: "Hamming distance above which to flag the pair (default 14)."
  )
  var threshold: Int = RecordingTriage.perceptualHashGroundTruthDistanceThreshold

  func run() throws {
    let candidates = try candidate.map { try parseNamePathPair($0) }
    let groundTruths = try groundTruth.map { try parseNamePathPair($0) }
    let findings = try RecordingTriage.compareKeyframes(
      candidates: candidates,
      groundTruths: groundTruths,
      threshold: threshold
    )
    try emit(findings)
  }
}

// MARK: - layout-drift

struct LayoutDriftCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "layout-drift",
    abstract: "Compare two XCUITest hierarchy dumps and report bbox drift."
  )

  @Option(name: .long, help: "Path to the earlier hierarchy dump (.txt).")
  var before: String
  @Option(name: .long, help: "Path to the later hierarchy dump (.txt).")
  var after: String
  @Option(name: .long, help: "Minimum dx/dy in points to flag drift (default 2).")
  var threshold = Double(RecordingTriage.layoutDriftPointThreshold)

  func run() throws {
    let beforeText = try String(contentsOf: URL(fileURLWithPath: before), encoding: .utf8)
    let afterText = try String(contentsOf: URL(fileURLWithPath: after), encoding: .utf8)
    let beforeBoxes = RecordingTriage.parseLayoutBoundingBoxes(from: beforeText)
    let afterBoxes = RecordingTriage.parseLayoutBoundingBoxes(from: afterText)
    let drifts = RecordingTriage.detectLayoutDrift(
      before: beforeBoxes,
      after: afterBoxes,
      threshold: CGFloat(threshold)
    )
    try emit(drifts)
  }
}

// MARK: - black-frames

struct BlackFramesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "black-frames",
    abstract: "Sample mean luminance + unique-colour count for each frame PNG."
  )

  @Argument(help: "One or more PNG/JPEG paths.")
  var paths: [String] = []

  func run() throws {
    guard !paths.isEmpty else {
      throw ValidationError("black-frames requires at least one frame path")
    }
    var reports: [RecordingTriage.BlackFrameReport] = []
    for path in paths {
      let report = try RecordingTriage.analyseBlackFrame(at: URL(fileURLWithPath: path))
      reports.append(report)
    }
    try emit(reports)
  }
}

// MARK: - thrash

struct ThrashCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "thrash",
    abstract: "Detect animation thrash windows from sampled keyframe perceptual hashes."
  )

  @Option(
    parsing: .singleValue,
    help: "Repeatable SECONDS=PATH for a sampled keyframe."
  )
  var sample: [String] = []

  @Option(name: .long, help: "Sliding window size in seconds (default 0.5).")
  var window: Double = 0.5

  @Option(name: .long, help: "Hash distance threshold for a 'change' (default 8).")
  var distanceThreshold: Int = 8

  @Option(name: .long, help: "Change count above which to flag a window (default 3).")
  var changeThreshold: Int = 3

  func run() throws {
    guard !sample.isEmpty else {
      throw ValidationError("thrash requires at least one --sample SECONDS=PATH")
    }
    var sampledHashes: [(seconds: Double, hash: RecordingTriage.PerceptualHash)] = []
    for entry in sample {
      let pair = try parseNamePathPair(entry)
      guard let seconds = Double(pair.name) else {
        throw ValidationError("--sample seconds half must be Double; got '\(pair.name)'")
      }
      let hash = try RecordingTriage.perceptualHash(ofImageAt: pair.url)
      sampledHashes.append((seconds: seconds, hash: hash))
    }
    sampledHashes.sort { $0.seconds < $1.seconds }
    let report = RecordingTriage.detectAnimationThrash(
      sampledHashes: sampledHashes,
      windowSeconds: window,
      distanceThreshold: distanceThreshold,
      changeThreshold: changeThreshold
    )
    try emit(report)
  }
}

// MARK: - act-timing

struct ActTimingCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "act-timing",
    abstract: "Convert sync-dir act marker mtimes into recording-relative offsets."
  )

  @Option(name: .long, help: "Directory containing actN.ready / actN.ack marker files.")
  var markerDir: String

  @Option(name: .long, help: "Recording start epoch in seconds.")
  var recordingStart: Double

  @Option(name: .long, help: "App launch epoch in seconds.")
  var appLaunch: Double

  func run() throws {
    let directory = URL(fileURLWithPath: markerDir, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw ValidationError("--marker-dir does not exist: \(directory.path)")
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    var markers: [RecordingTriage.ActMarker] = []
    for url in entries {
      let suffix = url.pathExtension
      guard suffix == "ready" || suffix == "ack" else { continue }
      markers.append(try RecordingTriage.parseActMarker(at: url))
    }
    let report = RecordingTriage.analyzeActTiming(
      markers: markers,
      recordingStart: Date(timeIntervalSince1970: recordingStart),
      appLaunch: Date(timeIntervalSince1970: appLaunch)
    )
    try emit(report)
  }
}

// MARK: - act-identifiers

struct ActIdentifiersCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "act-identifiers",
    abstract: "Walk per-act XCUITest hierarchies + markers; assert surface findings."
  )

  @Option(name: .long, help: "Directory containing actN.ready marker files.")
  var markerDir: String

  @Option(name: .long, help: "Directory containing swarm-actN.txt hierarchy dumps.")
  var uiSnapshotsDir: String

  @Option(name: .long, help: "Optional task_review_id; otherwise auto-derived from markers.")
  var taskReviewID: String?

  func run() throws {
    let markers = URL(fileURLWithPath: markerDir, isDirectory: true)
    let snapshots = URL(fileURLWithPath: uiSnapshotsDir, isDirectory: true)
    guard FileManager.default.fileExists(atPath: markers.path) else {
      throw ValidationError("--marker-dir does not exist: \(markers.path)")
    }
    guard FileManager.default.fileExists(atPath: snapshots.path) else {
      throw ValidationError("--ui-snapshots-dir does not exist: \(snapshots.path)")
    }
    let report = try RecordingTriage.walkRecordingActs(
      markerDir: markers,
      uiSnapshotsDir: snapshots,
      taskReviewID: taskReviewID
    )
    try emit(report)
  }
}

// MARK: - emit-checklist

struct EmitChecklistCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "emit-checklist",
    abstract: "Aggregate detector JSONs in <run>/recording-triage/ into checklist.md."
  )

  @Option(name: .customLong("run"), help: "Triage run dir; reads recording-triage/*.json from it.")
  var runDirPath: String

  func run() throws {
    let runDir = URL(fileURLWithPath: runDirPath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: runDir.path) else {
      throw ValidationError("--run does not exist: \(runDir.path)")
    }
    let triageDir = runDir.appendingPathComponent("recording-triage", isDirectory: true)
    let inputs = ChecklistInputLoader.load(triageDir: triageDir)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let markdown = report.renderMarkdown()
    FileHandle.standardOutput.write(Data(markdown.utf8))
  }
}

// MARK: - checklist-input loader

private enum ChecklistInputLoader {
  static func load(triageDir: URL) -> RecordingTriage.ChecklistInputs {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = decodeIfPresent(
      triageDir.appendingPathComponent("act-timing.json"),
      as: RecordingTriage.ActTimingReport.self
    )
    if let surface = decodeIfPresent(
      triageDir.appendingPathComponent("act-identifiers.json"),
      as: RecordingTriage.ActSurfaceReport.self
    ) {
      inputs.actIdentifiers = .init(
        perAct: surface.perAct.map {
          RecordingTriage.PerActFindings(act: $0.act, findings: $0.findings)
        },
        wholeRun: surface.wholeRun
      )
    }
    inputs.frameGaps = decodeIfPresent(
      triageDir.appendingPathComponent("frame-gaps.json"),
      as: RecordingTriage.FrameGapReport.self
    )
    inputs.deadHeadTail = loadDeadHeadTail(
      triageDir.appendingPathComponent("dead-head-tail.json")
    )
    inputs.thrash = decodeIfPresent(
      triageDir.appendingPathComponent("thrash.json"),
      as: RecordingTriage.ThrashReport.self
    )
    inputs.blackFrames =
      decodeIfPresent(
        triageDir.appendingPathComponent("black-frames.json"),
        as: [RecordingTriage.BlackFrameReport].self
      ) ?? []
    if let bundle = decodeIfPresent(
      triageDir.appendingPathComponent("layout-drift.json"),
      as: LayoutDriftBundle.self
    ) {
      inputs.layoutDriftPairs = bundle.pairs.map {
        RecordingTriage.LayoutDriftPair(before: $0.before, after: $0.after, drifts: $0.drifts)
      }
    }
    inputs.compareKeyframes =
      decodeIfPresent(
        triageDir.appendingPathComponent("compare-keyframes.json"),
        as: [RecordingTriage.PerceptualHashFinding].self
      ) ?? []
    inputs.launchArgs = decodeIfPresent(
      triageDir.appendingPathComponent("launch-args.json"),
      as: LaunchArgsFile.self
    ).map { .init(allConfigured: $0.allConfigured) }
    inputs.assertRecording = loadAssertRecording(
      triageDir.appendingPathComponent("assert-recording.json")
    )
    if let auto = decodeIfPresent(
      triageDir.appendingPathComponent("auto-keyframes.json"),
      as: AutoKeyframesFile.self
    ) {
      inputs.autoKeyframes = .init(
        acts: auto.acts.map { .init(name: $0.name, seconds: $0.seconds) }
      )
    }
    return inputs
  }

  private static func decodeIfPresent<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func loadDeadHeadTail(_ url: URL) -> RecordingTriage.DeadHeadTailReport? {
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let status = object["status"] as? String, status == "skipped" || status == "failed" {
      return nil
    }
    return try? JSONDecoder().decode(RecordingTriage.DeadHeadTailReport.self, from: data)
  }

  private static func loadAssertRecording(_ url: URL) -> RecordingTriage.AssertRecordingReport? {
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let status = (object["status"] as? String) ?? "unknown"
    let sizeBytes = object["size_bytes"] as? Int
    let durationSeconds = object["duration_seconds"] as? Double
    let reason = object["reason"] as? String
    return .init(
      status: status,
      sizeBytes: sizeBytes,
      durationSeconds: durationSeconds,
      reason: reason
    )
  }

  private struct LayoutDriftBundle: Decodable {
    let pairs: [Pair]

    struct Pair: Decodable {
      let before: String
      let after: String
      let drifts: [RecordingTriage.LayoutDrift]
    }
  }

  private struct LaunchArgsFile: Decodable {
    let allConfigured: Bool
  }

  private struct AutoKeyframesFile: Decodable {
    let acts: [Act]

    struct Act: Decodable {
      let name: String
      let seconds: Double
    }
  }
}
