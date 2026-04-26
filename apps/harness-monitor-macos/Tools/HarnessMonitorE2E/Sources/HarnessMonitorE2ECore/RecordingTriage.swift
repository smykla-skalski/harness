import CoreGraphics
import Foundation
import ImageIO

/// Detection routines for the swarm e2e recording-triage pipeline.
///
/// Each routine takes structured input (timestamps, hierarchy text, image URLs)
/// and emits a Codable report so the shell wrappers under
/// `scripts/e2e/recording-triage/` can serialise findings to JSON without
/// re-implementing the math in shell.
public enum RecordingTriage {
  public static let hitchThresholdSeconds: Double = 0.050
  public static let freezeThresholdSeconds: Double = 2.0
  public static let stallThresholdSeconds: Double = 5.0
  public static let blackLuminanceThreshold: Double = 5.0
  public static let blackUniqueColorThreshold: Int = 10
  public static let layoutDriftPointThreshold: CGFloat = 2.0
  public static let perceptualHashGroundTruthDistanceThreshold: Int = 14
}

// MARK: - Frame gaps

extension RecordingTriage {
  public enum FrameGapKind: String, Codable, Sendable {
    case hitch
    case freeze
    case stall
  }

  public struct FrameGap: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let durationSeconds: Double
    public let kind: FrameGapKind

    public init(startSeconds: Double, endSeconds: Double, kind: FrameGapKind) {
      self.startSeconds = startSeconds
      self.endSeconds = endSeconds
      self.durationSeconds = endSeconds - startSeconds
      self.kind = kind
    }
  }

  public struct FrameGapReport: Codable, Equatable, Sendable {
    public let totalFrames: Int
    public let durationSeconds: Double
    public let hitches: [FrameGap]
    public let freezes: [FrameGap]
    public let stalls: [FrameGap]
  }

  /// Classify per-frame timestamps from ffprobe into hitches, freezes, and stalls.
  /// `idleSegments` describes wall-clock ranges where the act-driver log was
  /// silent (no UI activity); gaps inside these are downgraded to stalls if
  /// over the stall threshold but never up-promoted to freezes.
  public static func analyzeFrameGaps(
    timestamps: [Double],
    idleSegments: [ClosedRange<Double>] = []
  ) -> FrameGapReport {
    guard timestamps.count >= 2 else {
      let duration = timestamps.last ?? 0
      return FrameGapReport(
        totalFrames: timestamps.count,
        durationSeconds: duration,
        hitches: [],
        freezes: [],
        stalls: []
      )
    }

    var hitches: [FrameGap] = []
    var freezes: [FrameGap] = []
    var stalls: [FrameGap] = []

    for index in 1..<timestamps.count {
      let start = timestamps[index - 1]
      let end = timestamps[index]
      let delta = end - start
      guard delta > hitchThresholdSeconds else { continue }

      let isInsideIdle = idleSegments.contains { $0.contains(start) }

      if delta > stallThresholdSeconds, isInsideIdle {
        stalls.append(FrameGap(startSeconds: start, endSeconds: end, kind: .stall))
      } else if delta > freezeThresholdSeconds {
        freezes.append(FrameGap(startSeconds: start, endSeconds: end, kind: .freeze))
      } else {
        hitches.append(FrameGap(startSeconds: start, endSeconds: end, kind: .hitch))
      }
    }

    return FrameGapReport(
      totalFrames: timestamps.count,
      durationSeconds: timestamps.last ?? 0,
      hitches: hitches,
      freezes: freezes,
      stalls: stalls
    )
  }

  /// Parse ffprobe's `-show_frames -of compact=p=0` output into a list of
  /// frame timestamps in seconds. Modern ffprobe (>= 5.0) emits `pts_time=`;
  /// older builds use `pkt_pts_time=`. Both spellings count as one timestamp
  /// per frame, but never both — once a frame yields a timestamp we move on
  /// so legacy builds emitting both fields don't double-count.
  public static func parseFrameTimestamps(fromFFprobe output: String) -> [Double] {
    var timestamps: [Double] = []
    for rawLine in output.split(separator: "\n") {
      let line = String(rawLine)
      var captured: Double?
      for token in line.split(separator: "|") {
        let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        guard key == "pts_time" || key == "pkt_pts_time" else { continue }
        if let value = Double(parts[1]) {
          captured = value
          break
        }
      }
      if let captured {
        timestamps.append(captured)
      }
    }
    return timestamps
  }
}

// MARK: - Dead head / tail

extension RecordingTriage {
  public struct DeadHeadTailReport: Codable, Equatable, Sendable {
    public let leadingSeconds: Double
    public let trailingSeconds: Double
    public let isLeadingDead: Bool
    public let isTrailingDead: Bool
    public let threshold: Double

    public init(
      leadingSeconds: Double,
      trailingSeconds: Double,
      threshold: Double
    ) {
      self.leadingSeconds = leadingSeconds
      self.trailingSeconds = trailingSeconds
      self.threshold = threshold
      self.isLeadingDead = leadingSeconds > threshold
      self.isTrailingDead = trailingSeconds > threshold
    }
  }

  /// Compare the recording's first/last frame timestamps against the
  /// daemon-log's app-launch / terminate markers. Inputs are seconds since
  /// arbitrary epoch — only the deltas matter.
  public static func analyzeDeadHeadTail(
    recordingStartEpoch: Double,
    recordingEndEpoch: Double,
    appLaunchEpoch: Double,
    appTerminateEpoch: Double,
    threshold: Double = 5.0
  ) -> DeadHeadTailReport {
    DeadHeadTailReport(
      leadingSeconds: max(0, appLaunchEpoch - recordingStartEpoch),
      trailingSeconds: max(0, recordingEndEpoch - appTerminateEpoch),
      threshold: threshold
    )
  }
}

// MARK: - Perceptual hash (dHash)

extension RecordingTriage {
  public struct PerceptualHash: Codable, Equatable, Sendable, Hashable {
    public let bits: UInt64

    public init(bits: UInt64) { self.bits = bits }

    public func distance(to other: Self) -> Int {
      (bits ^ other.bits).nonzeroBitCount
    }
  }

  public enum PerceptualHashError: Error, CustomStringConvertible {
    case sourceCreationFailed(URL)
    case imageDecodeFailed(URL)
    case bitmapContextFailed

    public var description: String {
      switch self {
      case .sourceCreationFailed(let url): "CGImageSourceCreateWithURL failed: \(url.path)"
      case .imageDecodeFailed(let url): "CGImageSourceCreateImageAtIndex failed: \(url.path)"
      case .bitmapContextFailed: "Failed to allocate CGContext for dHash"
      }
    }
  }

  /// Difference hash (dHash). Resize to 9x8 grayscale and emit 64 bits, one
  /// per `pixel(x, y) > pixel(x+1, y)` comparison. Hamming distance between
  /// two hashes equals the count of differing bits.
  public static func perceptualHash(of image: CGImage) throws -> PerceptualHash {
    let width = 9
    let height = 8
    var bytes = [UInt8](repeating: 0, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      throw PerceptualHashError.bitmapContextFailed
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var bits: UInt64 = 0
    for row in 0..<height {
      for column in 0..<8 {
        let left = bytes[row * width + column]
        let right = bytes[row * width + column + 1]
        if left > right {
          bits |= 1 << (row * 8 + column)
        }
      }
    }
    return PerceptualHash(bits: bits)
  }

  public static func perceptualHash(ofImageAt url: URL) throws -> PerceptualHash {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw PerceptualHashError.sourceCreationFailed(url)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw PerceptualHashError.imageDecodeFailed(url)
    }
    return try perceptualHash(of: image)
  }

  public struct PerceptualHashFinding: Codable, Equatable, Sendable {
    public let candidate: String
    public let groundTruth: String
    public let distance: Int
    public let exceedsThreshold: Bool
  }

  public static func compareKeyframes(
    candidates: [(name: String, url: URL)],
    groundTruths: [(name: String, url: URL)],
    threshold: Int = perceptualHashGroundTruthDistanceThreshold
  ) throws -> [PerceptualHashFinding] {
    let groundTruthIndex = Dictionary(uniqueKeysWithValues: groundTruths.map { ($0.name, $0.url) })
    var findings: [PerceptualHashFinding] = []
    for candidate in candidates {
      guard let groundTruthURL = groundTruthIndex[candidate.name] else { continue }
      let candidateHash = try perceptualHash(ofImageAt: candidate.url)
      let groundTruthHash = try perceptualHash(ofImageAt: groundTruthURL)
      let distance = candidateHash.distance(to: groundTruthHash)
      findings.append(
        PerceptualHashFinding(
          candidate: candidate.url.path,
          groundTruth: groundTruthURL.path,
          distance: distance,
          exceedsThreshold: distance > threshold
        ))
    }
    return findings
  }
}

// MARK: - Layout drift

extension RecordingTriage {
  public struct LayoutBoundingBox: Codable, Equatable, Sendable {
    public let identifier: String
    public let frame: CGRect
  }

  public struct LayoutDrift: Codable, Equatable, Sendable {
    public let identifier: String
    public let beforeFrame: CGRect
    public let afterFrame: CGRect
    public let dx: CGFloat
    public let dy: CGFloat
  }

  /// Parse `XCUIElement.debugDescription` style hierarchy text. Recognises
  /// both forms emitted by XCUITest: the legacy `identifier='X' frame: {{x,
  /// y}, {w, h}}` shape and the runtime `{{x, y}, {w, h}}, identifier: 'X'`
  /// shape. Lines without both an identifier and a frame are skipped.
  public static func parseLayoutBoundingBoxes(from text: String) -> [LayoutBoundingBox] {
    let identifierPattern = #"identifier(?:\s*[:=])\s*['\"]?([A-Za-z0-9._\-]+)['\"]?"#
    let framePattern =
      #"\{\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\},\s*\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\}\}"#
    guard
      let identifierRegex = try? NSRegularExpression(pattern: identifierPattern, options: []),
      let frameRegex = try? NSRegularExpression(pattern: framePattern, options: [])
    else {
      return []
    }
    var boxes: [LayoutBoundingBox] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let nsLine = line as NSString
      let lineRange = NSRange(location: 0, length: nsLine.length)
      guard
        let identifierMatch = identifierRegex.firstMatch(in: line, options: [], range: lineRange),
        identifierMatch.numberOfRanges >= 2,
        let frameMatch = frameRegex.firstMatch(in: line, options: [], range: lineRange),
        frameMatch.numberOfRanges >= 5
      else {
        continue
      }
      let identifier = nsLine.substring(with: identifierMatch.range(at: 1))
      guard
        let originX = Double(nsLine.substring(with: frameMatch.range(at: 1))),
        let originY = Double(nsLine.substring(with: frameMatch.range(at: 2))),
        let width = Double(nsLine.substring(with: frameMatch.range(at: 3))),
        let height = Double(nsLine.substring(with: frameMatch.range(at: 4)))
      else {
        continue
      }
      boxes.append(
        LayoutBoundingBox(
          identifier: identifier,
          frame: CGRect(x: originX, y: originY, width: width, height: height)
        ))
    }
    return boxes
  }

  public static func detectLayoutDrift(
    before: [LayoutBoundingBox],
    after: [LayoutBoundingBox],
    threshold: CGFloat = layoutDriftPointThreshold
  ) -> [LayoutDrift] {
    let afterIndex = Dictionary(grouping: after, by: { $0.identifier })
    var drifts: [LayoutDrift] = []
    for box in before {
      guard let candidates = afterIndex[box.identifier], let next = candidates.first else {
        continue
      }
      let dx = next.frame.origin.x - box.frame.origin.x
      let dy = next.frame.origin.y - box.frame.origin.y
      if abs(dx) > threshold || abs(dy) > threshold {
        drifts.append(
          LayoutDrift(
            identifier: box.identifier,
            beforeFrame: box.frame,
            afterFrame: next.frame,
            dx: dx,
            dy: dy
          ))
      }
    }
    return drifts
  }
}

// MARK: - Accessibility identifiers

extension RecordingTriage {
  public struct AccessibilityIdentifier: Codable, Equatable, Sendable {
    public let identifier: String
    public let label: String?
    public let frame: CGRect
    public let isSelected: Bool

    public init(identifier: String, label: String?, frame: CGRect, isSelected: Bool) {
      self.identifier = identifier
      self.label = label
      self.frame = frame
      self.isSelected = isSelected
    }
  }

  /// Walk an XCUITest debug-description-style hierarchy dump and yield one
  /// record per line that carries both an `identifier: '...'` clause and a
  /// `{{x, y}, {w, h}}` frame. Captures the optional `label: '...'` payload
  /// and the `Selected` modifier so downstream surface assertions can drive
  /// per-act verdicts without re-walking the file.
  public static func parseAccessibilityIdentifiers(from text: String) -> [AccessibilityIdentifier] {
    var records: [AccessibilityIdentifier] = []
    guard
      let frameRegex = try? NSRegularExpression(
        pattern:
          #"\{\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\},\s*\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\}\}"#,
        options: []
      ),
      let identifierRegex = try? NSRegularExpression(
        pattern: #"identifier:\s*'([^']*)'"#,
        options: []
      ),
      let labelRegex = try? NSRegularExpression(
        pattern: #"label:\s*'([^']*)'"#,
        options: []
      ),
      let selectedRegex = try? NSRegularExpression(
        pattern: #"(?:^|,\s)Selected(?:,|$)"#,
        options: []
      ),
      let valueSelectedRegex = try? NSRegularExpression(
        pattern: #"value:\s*'?selected'?(?:,|$|\s)"#,
        options: []
      )
    else {
      return records
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let lineString = String(line)
      let nsLine = lineString as NSString
      let fullRange = NSRange(location: 0, length: nsLine.length)
      guard
        let frameMatch = frameRegex.firstMatch(in: lineString, options: [], range: fullRange),
        frameMatch.numberOfRanges == 5,
        let identifierMatch = identifierRegex.firstMatch(
          in: lineString, options: [], range: fullRange),
        identifierMatch.numberOfRanges == 2,
        let originX = Double(nsLine.substring(with: frameMatch.range(at: 1))),
        let originY = Double(nsLine.substring(with: frameMatch.range(at: 2))),
        let width = Double(nsLine.substring(with: frameMatch.range(at: 3))),
        let height = Double(nsLine.substring(with: frameMatch.range(at: 4)))
      else {
        continue
      }
      let identifier = nsLine.substring(with: identifierMatch.range(at: 1))
      let label =
        labelRegex
        .firstMatch(in: lineString, options: [], range: fullRange)
        .flatMap { match -> String? in
          guard match.numberOfRanges == 2 else { return nil }
          return nsLine.substring(with: match.range(at: 1))
        }
      let isSelected =
        selectedRegex.firstMatch(in: lineString, options: [], range: fullRange) != nil
        || valueSelectedRegex.firstMatch(in: lineString, options: [], range: fullRange) != nil
      records.append(
        AccessibilityIdentifier(
          identifier: identifier,
          label: label,
          frame: CGRect(x: originX, y: originY, width: width, height: height),
          isSelected: isSelected
        ))
    }
    return records
  }
}

// MARK: - Act surface assertions

extension RecordingTriage {
  public struct ChecklistFinding: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
      case found
      case notFound = "not-found"
      case needsVerification = "needs-verification"
    }
    public let id: String
    public let verdict: Verdict
    public let message: String

    public init(id: String, verdict: Verdict, message: String) {
      self.id = id
      self.verdict = verdict
      self.message = message
    }
  }

  /// Assert that the per-act XCUITest hierarchy plus the marker payload
  /// produced the surface listed in `references/act-marker-matrix.md`. Each
  /// matrix row maps to one or two `ChecklistFinding`s with stable IDs so
  /// the emitter can promote them straight into `recording-triage/checklist.md`.
  public static func assertActSurface(
    act: String,
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    switch act {
    case "act1": return assertAct1(payload: payload, identifiers: identifiers)
    case "act2": return assertAct2(payload: payload, identifiers: identifiers)
    case "act3": return assertAct3(payload: payload, identifiers: identifiers)
    case "act4": return assertAct4(payload: payload, identifiers: identifiers)
    case "act5": return assertAct5(payload: payload, identifiers: identifiers)
    case "act6": return assertAct6(payload: payload, identifiers: identifiers)
    case "act7": return assertAct7(payload: payload, identifiers: identifiers)
    case "act8": return assertAct8(payload: payload, identifiers: identifiers)
    case "act9": return assertAct9(payload: payload, identifiers: identifiers)
    case "act10": return assertAct10(payload: payload, identifiers: identifiers)
    case "act11": return assertAct11(payload: payload, identifiers: identifiers)
    case "act12": return assertAct12(payload: payload, identifiers: identifiers)
    case "act13": return assertAct13(payload: payload, identifiers: identifiers)
    case "act14": return assertAct14(payload: payload, identifiers: identifiers)
    case "act15": return assertAct15(payload: payload, identifiers: identifiers)
    case "act16": return assertAct16(payload: payload, identifiers: identifiers)
    default:
      return [
        ChecklistFinding(
          id: "swarm.\(act).unknown",
          verdict: .needsVerification,
          message: "no surface assertions defined for \(act)"
        )
      ]
    }
  }

  private static func assertAct1(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    var findings: [ChecklistFinding] = []
    let cockpit = identifiers.first { $0.identifier == "harness.toolbar.chrome.state" }
    if let cockpit, (cockpit.label ?? "").contains("windowTitle=Cockpit") {
      findings.append(
        ChecklistFinding(
          id: "swarm.act1.cockpit",
          verdict: .found,
          message: "windowTitle=Cockpit visible in toolbar chrome state"
        ))
    } else {
      findings.append(
        ChecklistFinding(
          id: "swarm.act1.cockpit",
          verdict: .notFound,
          message: "harness.toolbar.chrome.state missing windowTitle=Cockpit"
        ))
    }
    guard let session = payload["session_id"], !session.isEmpty else {
      findings.append(
        ChecklistFinding(
          id: "swarm.act1.sidebarRow",
          verdict: .needsVerification,
          message: "act1 marker missing session_id payload"
        ))
      return findings
    }
    let sidebarID = "harness.sidebar.session.\(session)"
    if identifiers.contains(where: { $0.identifier == sidebarID && $0.isSelected }) {
      findings.append(
        ChecklistFinding(
          id: "swarm.act1.sidebarRow",
          verdict: .found,
          message: "selected sidebar row matches \(session)"
        ))
    } else {
      findings.append(
        ChecklistFinding(
          id: "swarm.act1.sidebarRow",
          verdict: .notFound,
          message: "expected selected sidebar row \(sidebarID)"
        ))
    }
    return findings
  }

  private static let act2RoleKeys = [
    "worker_codex_id", "worker_claude_id",
    "reviewer_claude_id", "reviewer_codex_id",
    "observer_id", "improver_id",
  ]

  private static func assertAct2(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    var findings: [ChecklistFinding] = []
    let label = identifiers.first { $0.identifier == "harness.session.agents.state" }?.label ?? ""
    let expectedIDs = act2RoleKeys.compactMap { payload[$0] }.filter { !$0.isEmpty }
    let missing = expectedIDs.filter { !label.contains($0) }
    if missing.isEmpty, !expectedIDs.isEmpty {
      findings.append(
        ChecklistFinding(
          id: "swarm.act2.roles",
          verdict: .found,
          message: "agents.state contains every required role ID"
        ))
    } else {
      findings.append(
        ChecklistFinding(
          id: "swarm.act2.roles",
          verdict: .notFound,
          message: "agents.state missing IDs: \(missing.joined(separator: ","))"
        ))
    }
    findings.append(
      ChecklistFinding(
        id: "swarm.act2.duplicateRejected",
        verdict: .needsVerification,
        message: "duplicate-claim rejection is a transient toast; confirm in recording"
      ))
    return findings
  }

  private static let act3TaskKeys = [
    "task_review_id", "task_autospawn_id", "task_arbitration_id",
    "task_refusal_id", "task_signal_id",
  ]

  private static func assertAct3(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    let label = identifiers.first { $0.identifier == "harness.session.tasks.state" }?.label ?? ""
    let expectedIDs = act3TaskKeys.compactMap { payload[$0] }.filter { !$0.isEmpty }
    let missing = expectedIDs.filter { !label.contains($0) }
    if missing.isEmpty, !expectedIDs.isEmpty {
      return [
        ChecklistFinding(
          id: "swarm.act3.tasks",
          verdict: .found,
          message: "tasks.state contains every act3 task ID"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act3.tasks",
        verdict: .notFound,
        message: "tasks.state missing IDs: \(missing.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct4(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    let label = identifiers.first { $0.identifier == "harness.session.tasks.state" }?.label ?? ""
    let expected = ["task_review_id", "task_autospawn_id"].compactMap { payload[$0] }
    let missing = expected.filter { !label.contains($0) }
    if missing.isEmpty, !expected.isEmpty {
      return [
        ChecklistFinding(
          id: "swarm.act4.tasks",
          verdict: .found,
          message: "tasks.state still contains review and autospawn"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act4.tasks",
        verdict: .notFound,
        message: "tasks.state missing IDs: \(missing.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct5(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let code = payload["heuristic_code"], !code.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act5.heuristic",
          verdict: .needsVerification,
          message: "act5 marker missing heuristic_code"
        )
      ]
    }
    let cardID = "heuristicIssueCard.\(code)"
    if identifiers.contains(where: { $0.identifier == cardID }) {
      return [
        ChecklistFinding(
          id: "swarm.act5.heuristic",
          verdict: .found,
          message: "\(cardID) visible"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act5.heuristic",
        verdict: .notFound,
        message: "expected \(cardID)"
      )
    ]
  }

  private static func assertAct6(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let improverID = payload["improver_id"], !improverID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act6.improver",
          verdict: .needsVerification,
          message: "act6 marker missing improver_id"
        )
      ]
    }
    let label = identifiers.first { $0.identifier == "harness.session.agents.state" }?.label ?? ""
    if label.contains(improverID) {
      return [
        ChecklistFinding(
          id: "swarm.act6.improver",
          verdict: .found,
          message: "agents.state contains improver_id \(improverID)"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act6.improver",
        verdict: .notFound,
        message: "agents.state missing improver_id \(improverID)"
      )
    ]
  }

  private static func assertAct7(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let vibeID = payload["vibe_worker_id"], !vibeID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act7.vibeRoster",
          verdict: .needsVerification,
          message: "vibe runtime missing; rejoin not exercised"
        )
      ]
    }
    let label = identifiers.first { $0.identifier == "harness.session.agents.state" }?.label ?? ""
    if label.contains(vibeID) {
      return [
        ChecklistFinding(
          id: "swarm.act7.vibeRoster",
          verdict: .found,
          message: "agents.state contains vibe_worker_id \(vibeID)"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act7.vibeRoster",
        verdict: .notFound,
        message: "agents.state missing vibe_worker_id \(vibeID)"
      )
    ]
  }

  private static func assertAct8(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let taskID = payload["task_review_id"], !taskID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act8.awaitingReview",
          verdict: .needsVerification,
          message: "act8 marker missing task_review_id"
        )
      ]
    }
    let badgeID = SwarmAccessibilityID.awaitingReviewBadge(taskID)
    if identifiers.contains(where: { $0.identifier == badgeID }) {
      return [
        ChecklistFinding(
          id: "swarm.act8.awaitingReview",
          verdict: .found,
          message: "\(badgeID) visible"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act8.awaitingReview",
        verdict: .notFound,
        message: "expected \(badgeID)"
      )
    ]
  }

  private static func assertAct9(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let taskID = payload["task_review_id"], !taskID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act9.reviewerClaim",
          verdict: .needsVerification,
          message: "act9 marker missing task_review_id"
        )
      ]
    }
    let runtime = payload["reviewer_runtime"] ?? "claude"
    let candidates = [
      SwarmAccessibilityID.reviewerClaimBadge(taskID, runtime: runtime),
      SwarmAccessibilityID.reviewerQuorumIndicator(taskID),
    ]
    if identifiers.contains(where: { candidates.contains($0.identifier) }) {
      return [
        ChecklistFinding(
          id: "swarm.act9.reviewerClaim",
          verdict: .found,
          message: "reviewer claim or quorum surface present"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act9.reviewerClaim",
        verdict: .notFound,
        message: "expected one of \(candidates.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct10(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let taskID = payload["task_autospawn_id"], !taskID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act10.awaitingReview",
          verdict: .needsVerification,
          message: "act10 marker missing task_autospawn_id"
        )
      ]
    }
    let badgeID = SwarmAccessibilityID.awaitingReviewBadge(taskID)
    if identifiers.contains(where: { $0.identifier == badgeID }) {
      return [
        ChecklistFinding(
          id: "swarm.act10.awaitingReview",
          verdict: .found,
          message: "\(badgeID) visible"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act10.awaitingReview",
        verdict: .notFound,
        message: "expected \(badgeID)"
      )
    ]
  }

  private static func assertAct11(
    payload _: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    if identifiers.contains(where: { $0.identifier == "harness.toast.worker-refusal" }) {
      return [
        ChecklistFinding(
          id: "swarm.act11.refusal",
          verdict: .found,
          message: "harness.toast.worker-refusal visible"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act11.refusal",
        verdict: .needsVerification,
        message: "no refusal toast in hierarchy; transient toasts may have dismissed"
      )
    ]
  }

  private static func assertAct12(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let taskID = payload["task_arbitration_id"], !taskID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act12.roundOne",
          verdict: .needsVerification,
          message: "act12 marker missing task_arbitration_id"
        )
      ]
    }
    let pointID = payload["point_id"] ?? "p1"
    let candidates = [
      SwarmAccessibilityID.partialAgreementChip(pointID),
      SwarmAccessibilityID.reviewPointChip(pointID),
      SwarmAccessibilityID.roundCounter(taskID),
    ]
    if identifiers.contains(where: { candidates.contains($0.identifier) }) {
      return [
        ChecklistFinding(
          id: "swarm.act12.roundOne",
          verdict: .found,
          message: "round-one surface present"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act12.roundOne",
        verdict: .notFound,
        message: "expected one of \(candidates.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct13(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let taskID = payload["task_arbitration_id"], !taskID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act13.arbitration",
          verdict: .needsVerification,
          message: "act13 marker missing task_arbitration_id"
        )
      ]
    }
    let candidates = [
      SwarmAccessibilityID.arbitrationBanner(taskID),
      SwarmAccessibilityID.roundCounter(taskID),
    ]
    if identifiers.contains(where: { candidates.contains($0.identifier) }) {
      return [
        ChecklistFinding(
          id: "swarm.act13.arbitration",
          verdict: .found,
          message: "arbitration surface present"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act13.arbitration",
        verdict: .notFound,
        message: "expected one of \(candidates.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct14(
    payload _: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    if identifiers.contains(where: { $0.identifier == "harness.toast.signal-collision" }) {
      return [
        ChecklistFinding(
          id: "swarm.act14.signalCollision",
          verdict: .found,
          message: "harness.toast.signal-collision visible"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act14.signalCollision",
        verdict: .needsVerification,
        message: "no collision toast in hierarchy; transient toasts may have dismissed"
      )
    ]
  }

  private static func assertAct15(
    payload _: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    let candidates = [
      "observeScanButton",
      "observeDoctorButton",
      "harness.session.action.observe",
    ]
    if identifiers.contains(where: { candidates.contains($0.identifier) }) {
      return [
        ChecklistFinding(
          id: "swarm.act15.observeAction",
          verdict: .found,
          message: "observe action surface present"
        )
      ]
    }
    return [
      ChecklistFinding(
        id: "swarm.act15.observeAction",
        verdict: .notFound,
        message: "expected one of \(candidates.joined(separator: ","))"
      )
    ]
  }

  private static func assertAct16(
    payload: [String: String],
    identifiers: [AccessibilityIdentifier]
  ) -> [ChecklistFinding] {
    guard let sessionID = payload["session_id"], !sessionID.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act16.sessionEnded",
          verdict: .notFound,
          message: "act16 payload missing session_id; cannot inspect sidebar row"
        )
      ]
    }
    let rowIdentifier = "harness.sidebar.session.\(sessionID)"
    let rows = identifiers.filter { $0.identifier == rowIdentifier }
    guard !rows.isEmpty else {
      return [
        ChecklistFinding(
          id: "swarm.act16.sessionEnded",
          verdict: .notFound,
          message: "sidebar row \(rowIdentifier) not present in hierarchy"
        )
      ]
    }
    let endedTokens = ["ended", "closed"]
    let matched = rows.first { row in
      let label = row.label?.lowercased() ?? ""
      return endedTokens.contains(where: { label.contains($0) })
    }
    if let matched, let label = matched.label {
      return [
        ChecklistFinding(
          id: "swarm.act16.sessionEnded",
          verdict: .found,
          message: "sidebar row \(rowIdentifier) label includes ended status: \(label)"
        )
      ]
    }
    let combinedLabels = rows.compactMap(\.label).joined(separator: " | ")
    return [
      ChecklistFinding(
        id: "swarm.act16.sessionEnded",
        verdict: .notFound,
        message: "sidebar row \(rowIdentifier) label has no ended/closed token: \(combinedLabels)"
      )
    ]
  }
}

// MARK: - Whole-run invariants

extension RecordingTriage {
  public struct ActHierarchy: Codable, Equatable, Sendable {
    public let act: String
    public let identifiers: [AccessibilityIdentifier]

    public init(act: String, identifiers: [AccessibilityIdentifier]) {
      self.act = act
      self.identifiers = identifiers
    }
  }

  /// Walk every per-act hierarchy and emit the cross-act findings called
  /// out under `## Whole-run invariants` in
  /// `references/act-marker-matrix.md`. Mechanical checks (badge progression
  /// for `task_review`, daemon-health proxy via the connection badge) emit
  /// `found` / `not-found`; the rest are deferred to human verification so
  /// the agent still re-watches the recording for them.
  public static func assertWholeRunInvariants(
    perActHierarchies: [ActHierarchy],
    taskReviewID: String?
  ) -> [ChecklistFinding] {
    var findings: [ChecklistFinding] = []
    findings.append(
      taskReviewProgressionFinding(
        perActHierarchies: perActHierarchies,
        taskReviewID: taskReviewID
      ))
    findings.append(daemonHealthFinding(perActHierarchies: perActHierarchies))
    findings.append(
      ChecklistFinding(
        id: "swarm.invariant.toastQueueAppendOnly",
        verdict: .needsVerification,
        message: "compare act11 and act14 toast frames in the recording"
      ))
    findings.append(
      ChecklistFinding(
        id: "swarm.invariant.taskDetailPaneMatches",
        verdict: .needsVerification,
        message: "agentsTaskCard.value parsing not yet wired; verify in recording"
      ))
    findings.append(
      ChecklistFinding(
        id: "swarm.invariant.heuristicCodesPersist",
        verdict: .needsVerification,
        message: "five act5 heuristic codes; only one carried in marker payload"
      ))
    return findings
  }

  private static func taskReviewProgressionFinding(
    perActHierarchies: [ActHierarchy],
    taskReviewID: String?
  ) -> ChecklistFinding {
    guard let taskID = taskReviewID, !taskID.isEmpty else {
      return ChecklistFinding(
        id: "swarm.invariant.taskReviewProgression",
        verdict: .needsVerification,
        message: "task_review_id missing; cannot prove badge progression mechanically"
      )
    }
    let awaitingID = SwarmAccessibilityID.awaitingReviewBadge(taskID)
    // Real UI does not render a per-task `inReviewBadge.<id>`. Use the
    // reviewer-claim badge family or the quorum indicator as the in-review
    // proxy: either signals at least one reviewer has attached, which is the
    // exact transition we are trying to prove (AwaitingReview -> InReview).
    let claimedTaskPrefix =
      "\(SwarmAccessibilityID.reviewerClaimBadgePrefix)\(SwarmAccessibilityID.slug(taskID))."
    let quorumID = SwarmAccessibilityID.reviewerQuorumIndicator(taskID)
    var awaitingActIndex: Int?
    var inReviewActIndex: Int?
    for (index, hierarchy) in perActHierarchies.enumerated() {
      if awaitingActIndex == nil,
        hierarchy.identifiers.contains(where: { $0.identifier == awaitingID })
      {
        awaitingActIndex = index
      }
      let claimed = hierarchy.identifiers.contains { identifier in
        identifier.identifier == quorumID
          || identifier.identifier.hasPrefix(claimedTaskPrefix)
      }
      if claimed {
        inReviewActIndex = index
      }
    }
    if let awaiting = awaitingActIndex,
      let inReview = inReviewActIndex,
      inReview >= awaiting
    {
      return ChecklistFinding(
        id: "swarm.invariant.taskReviewProgression",
        verdict: .found,
        message: "task_review progressed AwaitingReview -> InReview"
      )
    }
    let missing: [String] = {
      var pieces: [String] = []
      if awaitingActIndex == nil { pieces.append(awaitingID) }
      if inReviewActIndex == nil {
        pieces.append("\(claimedTaskPrefix)<runtime> or \(quorumID)")
      }
      return pieces
    }()
    return ChecklistFinding(
      id: "swarm.invariant.taskReviewProgression",
      verdict: .notFound,
      message: "missing badges: \(missing.joined(separator: ","))"
    )
  }

  private static func daemonHealthFinding(perActHierarchies: [ActHierarchy]) -> ChecklistFinding {
    guard !perActHierarchies.isEmpty else {
      return ChecklistFinding(
        id: "swarm.invariant.daemonHealth",
        verdict: .needsVerification,
        message: "no per-act hierarchies supplied"
      )
    }
    var offendingActs: [String] = []
    for hierarchy in perActHierarchies {
      let badge = hierarchy.identifiers.first {
        $0.identifier == "harness.toolbar.connection-badge"
      }
      let label = badge?.label ?? ""
      let healthy = label.contains("Connection: WS")
      if !healthy {
        offendingActs.append(hierarchy.act)
      }
    }
    if offendingActs.isEmpty {
      return ChecklistFinding(
        id: "swarm.invariant.daemonHealth",
        verdict: .found,
        message: "connection-badge stays on WS across every act"
      )
    }
    return ChecklistFinding(
      id: "swarm.invariant.daemonHealth",
      verdict: .notFound,
      message: "connection-badge not on WS in: \(offendingActs.joined(separator: ","))"
    )
  }
}

// MARK: - Black / blank frames

extension RecordingTriage {
  public struct BlackFrameReport: Codable, Equatable, Sendable {
    public let path: String
    public let meanLuminance: Double
    public let uniqueColorCount: Int
    public let isSuspect: Bool
  }

  public enum BlackFrameError: Error, CustomStringConvertible {
    case sourceCreationFailed(URL)
    case imageDecodeFailed(URL)
    case bitmapContextFailed

    public var description: String {
      switch self {
      case .sourceCreationFailed(let url): "CGImageSourceCreateWithURL failed: \(url.path)"
      case .imageDecodeFailed(let url): "CGImageSourceCreateImageAtIndex failed: \(url.path)"
      case .bitmapContextFailed: "Failed to allocate CGContext for black-frame analyser"
      }
    }
  }

  public static func analyseBlackFrame(at url: URL) throws -> BlackFrameReport {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw BlackFrameError.sourceCreationFailed(url)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw BlackFrameError.imageDecodeFailed(url)
    }
    // Downsample to 32x32 RGBA so unique-color counting and luminance
    // averaging stay cheap regardless of source resolution.
    let width = 32
    let height = 32
    let pixelCount = width * height
    var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      throw BlackFrameError.bitmapContextFailed
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var luminanceSum: Double = 0
    var seenColors = Set<UInt32>()
    for index in 0..<pixelCount {
      let offset = index * 4
      let red = Double(bytes[offset])
      let green = Double(bytes[offset + 1])
      let blue = Double(bytes[offset + 2])
      // Rec. 601 luma; matches what most video pipelines treat as
      // "perceived brightness" for thumbnails.
      luminanceSum += 0.299 * red + 0.587 * green + 0.114 * blue
      let packed =
        (UInt32(bytes[offset]) << 16)
        | (UInt32(bytes[offset + 1]) << 8)
        | UInt32(bytes[offset + 2])
      seenColors.insert(packed)
    }
    let meanLuminance = luminanceSum / Double(pixelCount)
    let uniqueColors = seenColors.count
    let suspect =
      meanLuminance < blackLuminanceThreshold
      || uniqueColors < blackUniqueColorThreshold
    return BlackFrameReport(
      path: url.path,
      meanLuminance: meanLuminance,
      uniqueColorCount: uniqueColors,
      isSuspect: suspect
    )
  }
}

// MARK: - Act markers

extension RecordingTriage {
  public enum ActMarkerKind: String, Codable, Sendable {
    case ready
    case ack
  }

  public struct ActMarker: Codable, Equatable, Sendable {
    public let act: String
    public let kind: ActMarkerKind
    public let payload: [String: String]
    public let mtime: Date
  }

  public enum ActMarkerError: Error, CustomStringConvertible {
    case unknownSuffix(URL)
    case missingFile(URL)
    case missingMTime(URL)

    public var description: String {
      switch self {
      case .unknownSuffix(let url):
        "expected .ready or .ack suffix: \(url.lastPathComponent)"
      case .missingFile(let url):
        "marker file missing: \(url.path)"
      case .missingMTime(let url):
        "marker has no modificationDate: \(url.path)"
      }
    }
  }

  /// Parse an `<act>.ready` or `<act>.ack` marker file written atomically by
  /// `SwarmFullFlowOrchestrator.actReady` / `actAck`. The act name is taken
  /// from the filename, the kind from the extension, the payload from the
  /// `key=value` lines (one per line; blank lines and `#`-prefixed comments
  /// skipped; the literal `ack` token used by ack files contributes nothing
  /// to the payload), and the wall-clock anchor from the file's mtime.
  public static func parseActMarker(at url: URL) throws -> ActMarker {
    let kind: ActMarkerKind
    switch url.pathExtension {
    case "ready": kind = .ready
    case "ack": kind = .ack
    default: throw ActMarkerError.unknownSuffix(url)
    }
    let act = url.deletingPathExtension().lastPathComponent
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ActMarkerError.missingFile(url)
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let mtime = attrs[.modificationDate] as? Date else {
      throw ActMarkerError.missingMTime(url)
    }
    let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var payload: [String: String] = [:]
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line == "ack" { continue }
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      if key.isEmpty || key == "act" { continue }
      payload[key] = value
    }
    return ActMarker(act: act, kind: kind, payload: payload, mtime: mtime)
  }
}

// MARK: - Act timing

extension RecordingTriage {
  public struct ActWindow: Codable, Equatable, Sendable {
    public let act: String
    public let readySeconds: Double?
    public let ackSeconds: Double?
    public let durationSeconds: Double?
    public let gapToNextSeconds: Double?
  }

  public struct ActTimingReport: Codable, Equatable, Sendable {
    public let ttffSeconds: Double
    public let dashboardLatencySeconds: Double?
    public let acts: [ActWindow]
  }

  /// Convert marker mtimes into recording-relative offsets so the checklist
  /// emitter can drive `lifecycle.ttff`, `lifecycle.dashboard`, and the
  /// suite-speed handoff verdicts without re-reading the filesystem.
  /// Per-act ack/duration/handoff fields stay nil when their input marker
  /// is missing so callers can distinguish "not yet acked" from "0 seconds".
  public static func analyzeActTiming(
    markers: [ActMarker],
    recordingStart: Date,
    appLaunch: Date
  ) -> ActTimingReport {
    let recordingEpoch = recordingStart.timeIntervalSince1970
    let ttff = max(0, recordingEpoch - appLaunch.timeIntervalSince1970)

    var readyByAct: [String: Date] = [:]
    var ackByAct: [String: Date] = [:]
    var actNames: [String] = []
    for marker in markers {
      switch marker.kind {
      case .ready:
        if readyByAct[marker.act] == nil {
          readyByAct[marker.act] = marker.mtime
          actNames.append(marker.act)
        }
      case .ack:
        ackByAct[marker.act] = marker.mtime
      }
    }

    let orderedActs = actNames.sorted { lhs, rhs in
      let lhsMtime = readyByAct[lhs] ?? .distantFuture
      let rhsMtime = readyByAct[rhs] ?? .distantFuture
      return lhsMtime < rhsMtime
    }

    var windows: [ActWindow] = []
    for (index, act) in orderedActs.enumerated() {
      let ready = readyByAct[act].map { $0.timeIntervalSince1970 - recordingEpoch }
      let ack = ackByAct[act].map { $0.timeIntervalSince1970 - recordingEpoch }
      let duration: Double? = {
        guard let ready, let ack else { return nil }
        return ack - ready
      }()
      let gap: Double? = {
        guard index + 1 < orderedActs.count, let ack else { return nil }
        let next = orderedActs[index + 1]
        guard let nextReady = readyByAct[next].map({ $0.timeIntervalSince1970 - recordingEpoch })
        else { return nil }
        return nextReady - ack
      }()
      windows.append(
        ActWindow(
          act: act,
          readySeconds: ready,
          ackSeconds: ack,
          durationSeconds: duration,
          gapToNextSeconds: gap
        ))
    }

    let dashboard = readyByAct["act1"].map { $0.timeIntervalSince1970 - recordingEpoch }
    return ActTimingReport(
      ttffSeconds: ttff,
      dashboardLatencySeconds: dashboard,
      acts: windows
    )
  }
}

// MARK: - Animation thrash

extension RecordingTriage {
  public struct ThrashWindow: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let perceptualChanges: Int
  }

  public struct ThrashReport: Codable, Equatable, Sendable {
    public let windowSeconds: Double
    public let changeThreshold: Int
    public let windows: [ThrashWindow]
  }

  /// Sampled perceptual-hash distances per frame keyed by wall-clock seconds
  /// since the first frame. Detects regions of the recording where the same
  /// 500 ms window contains more than `changeThreshold` significant
  /// perceptual changes (a proxy for flicker / animation thrash).
  public static func detectAnimationThrash(
    sampledHashes: [(seconds: Double, hash: PerceptualHash)],
    windowSeconds: Double = 0.5,
    distanceThreshold: Int = 8,
    changeThreshold: Int = 3
  ) -> ThrashReport {
    guard sampledHashes.count >= 2 else {
      return ThrashReport(
        windowSeconds: windowSeconds,
        changeThreshold: changeThreshold,
        windows: []
      )
    }

    var changes: [Double] = []
    for index in 1..<sampledHashes.count {
      let previous = sampledHashes[index - 1]
      let current = sampledHashes[index]
      if previous.hash.distance(to: current.hash) > distanceThreshold {
        changes.append(current.seconds)
      }
    }

    var windows: [ThrashWindow] = []
    var pointer = 0
    for change in changes {
      let windowStart = change
      let windowEnd = change + windowSeconds
      var count = 0
      while pointer < changes.count, changes[pointer] < windowStart {
        pointer += 1
      }
      for laterChange in changes[pointer...] {
        guard laterChange < windowEnd else {
          break
        }
        count += 1
      }
      if count > changeThreshold {
        windows.append(
          ThrashWindow(
            startSeconds: windowStart,
            endSeconds: windowEnd,
            perceptualChanges: count
          ))
      }
    }
    return ThrashReport(
      windowSeconds: windowSeconds,
      changeThreshold: changeThreshold,
      windows: windows
    )
  }
}
