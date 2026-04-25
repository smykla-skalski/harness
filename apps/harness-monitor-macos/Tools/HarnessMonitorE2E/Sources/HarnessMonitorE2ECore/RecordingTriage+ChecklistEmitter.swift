import Foundation

// MARK: - Checklist emitter inputs and output

extension RecordingTriage {
  /// Aggregated detector outputs for the recording-checklist emitter. Each
  /// optional field maps to one JSON file under `_artifacts/runs/<slug>/recording-triage/`;
  /// missing fields downgrade the corresponding rows to `needs-verification`.
  public struct ChecklistInputs: Sendable {
    public var actTiming: ActTimingReport?
    public var actIdentifiers: ActIdentifiersInputs
    public var frameGaps: FrameGapReport?
    public var deadHeadTail: DeadHeadTailReport?
    public var thrash: ThrashReport?
    public var blackFrames: [BlackFrameReport]
    public var layoutDriftPairs: [LayoutDriftPair]
    public var compareKeyframes: [PerceptualHashFinding]
    public var launchArgs: LaunchArgsReport?
    public var assertRecording: AssertRecordingReport?
    public var autoKeyframes: AutoKeyframesReport?

    public init(
      actTiming: ActTimingReport? = nil,
      actIdentifiers: ActIdentifiersInputs = ActIdentifiersInputs(),
      frameGaps: FrameGapReport? = nil,
      deadHeadTail: DeadHeadTailReport? = nil,
      thrash: ThrashReport? = nil,
      blackFrames: [BlackFrameReport] = [],
      layoutDriftPairs: [LayoutDriftPair] = [],
      compareKeyframes: [PerceptualHashFinding] = [],
      launchArgs: LaunchArgsReport? = nil,
      assertRecording: AssertRecordingReport? = nil,
      autoKeyframes: AutoKeyframesReport? = nil
    ) {
      self.actTiming = actTiming
      self.actIdentifiers = actIdentifiers
      self.frameGaps = frameGaps
      self.deadHeadTail = deadHeadTail
      self.thrash = thrash
      self.blackFrames = blackFrames
      self.layoutDriftPairs = layoutDriftPairs
      self.compareKeyframes = compareKeyframes
      self.launchArgs = launchArgs
      self.assertRecording = assertRecording
      self.autoKeyframes = autoKeyframes
    }
  }

  public struct ActIdentifiersInputs: Sendable, Equatable {
    public var perAct: [PerActFindings]
    public var wholeRun: [ChecklistFinding]

    public init(perAct: [PerActFindings] = [], wholeRun: [ChecklistFinding] = []) {
      self.perAct = perAct
      self.wholeRun = wholeRun
    }
  }

  public struct PerActFindings: Codable, Sendable, Equatable {
    public let act: String
    public let findings: [ChecklistFinding]

    public init(act: String, findings: [ChecklistFinding]) {
      self.act = act
      self.findings = findings
    }
  }

  public struct LayoutDriftPair: Codable, Sendable, Equatable {
    public let before: String
    public let after: String
    public let drifts: [LayoutDrift]

    public init(before: String, after: String, drifts: [LayoutDrift]) {
      self.before = before
      self.after = after
      self.drifts = drifts
    }
  }

  public struct LaunchArgsReport: Codable, Sendable, Equatable {
    public let allConfigured: Bool

    public init(allConfigured: Bool) {
      self.allConfigured = allConfigured
    }
  }

  public struct AssertRecordingReport: Codable, Sendable, Equatable {
    public let status: String
    public let sizeBytes: Int?
    public let durationSeconds: Double?
    public let reason: String?

    public init(
      status: String,
      sizeBytes: Int?,
      durationSeconds: Double?,
      reason: String?
    ) {
      self.status = status
      self.sizeBytes = sizeBytes
      self.durationSeconds = durationSeconds
      self.reason = reason
    }
  }

  public struct AutoKeyframesAct: Codable, Sendable, Equatable {
    public let name: String
    public let seconds: Double

    public init(name: String, seconds: Double) {
      self.name = name
      self.seconds = seconds
    }
  }

  public struct AutoKeyframesReport: Codable, Sendable, Equatable {
    public let acts: [AutoKeyframesAct]

    public init(acts: [AutoKeyframesAct]) {
      self.acts = acts
    }
  }

  public struct ChecklistRow: Codable, Sendable, Equatable {
    public let id: String
    public let section: String
    public let verdict: ChecklistFinding.Verdict
    public let proof: String?
    public let reason: String

    public init(
      id: String,
      section: String,
      verdict: ChecklistFinding.Verdict,
      proof: String?,
      reason: String
    ) {
      self.id = id
      self.section = section
      self.verdict = verdict
      self.proof = proof
      self.reason = reason
    }
  }

  public struct ChecklistReport: Codable, Sendable, Equatable {
    public let rows: [ChecklistRow]

    public init(rows: [ChecklistRow]) {
      self.rows = rows
    }

    public func renderMarkdown() -> String {
      ChecklistMarkdown.render(rows: rows)
    }
  }
}

// MARK: - Section labels

extension RecordingTriage {
  fileprivate enum Section: String {
    case lifecycle = "A. Process and lifecycle"
    case firstFrame = "B. First-frame state"
    case transition = "C. Transitions between acts"
    case idle = "D. Idle behavior"
    case perf = "E. Animation and performance"
    case a11y = "F. Readability and accessibility"
    case interaction = "G. Interaction fidelity"
    case swarm = "H. Swarm-specific UI"
    case artifact = "I. Recording artifact integrity"
    case suite = "Suite-speed prompts"
  }

  fileprivate enum Threshold {
    static let ttffBudgetSeconds: Double = 2.0
    static let ttffProblemSeconds: Double = 4.0
    static let dashboardBudgetSeconds: Double = 1.0
    static let dashboardProblemSeconds: Double = 2.0
    static let perSegmentHitchLimit: Int = 2
    static let layoutThrashChangesPerWindow: Int = 3
    static let suiteHandoffBudgetSeconds: Double = 1.0
  }

  fileprivate enum Proof {
    static let actTiming = "recording-triage/act-timing.json"
    static let actIdentifiers = "recording-triage/act-identifiers.json"
    static let frameGaps = "recording-triage/frame-gaps.json"
    static let deadHeadTail = "recording-triage/dead-head-tail.json"
    static let thrash = "recording-triage/thrash.json"
    static let blackFrames = "recording-triage/black-frames.json"
    static let layoutDrift = "recording-triage/layout-drift.json"
    static let launchArgs = "recording-triage/launch-args.json"
    static let assertRecording = "recording-triage/assert-recording.json"
  }
}

// MARK: - Public emitter entry point

extension RecordingTriage {
  /// Build the recording checklist by combining detector outputs into one
  /// row per item from `references/recording-checklist.md`. Tier-1 and
  /// Tier-2 rows are mechanical; Tier-4 rows always emit
  /// `needs-verification` with a one-line rationale so the agent still
  /// re-watches them but never silently skips them.
  public static func emitChecklist(inputs: ChecklistInputs) -> ChecklistReport {
    var rows: [ChecklistRow] = []
    rows.append(contentsOf: lifecycleRows(inputs: inputs))
    rows.append(contentsOf: firstFrameRows(inputs: inputs))
    rows.append(contentsOf: transitionRows())
    rows.append(contentsOf: idleRows(inputs: inputs))
    rows.append(contentsOf: perfRows(inputs: inputs))
    rows.append(contentsOf: a11yRows())
    rows.append(contentsOf: interactionRows())
    rows.append(contentsOf: swarmRows(inputs: inputs))
    rows.append(contentsOf: artifactRows(inputs: inputs))
    rows.append(contentsOf: suiteSpeedRows(inputs: inputs))
    return ChecklistReport(rows: rows)
  }
}

// MARK: - Lifecycle (Section A)

extension RecordingTriage {
  fileprivate static func lifecycleRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      lifecycleTtffRow(inputs.actTiming),
      lifecycleDashboardRow(inputs.actTiming),
      manualRow(
        id: "lifecycle.manifest",
        section: .lifecycle,
        reason: "manifest pickup latency requires per-launch instrumentation; verify in recording"
      ),
      manualRow(
        id: "lifecycle.warmstart",
        section: .lifecycle,
        reason: "warm vs cold relaunch comparison is single-launch-blind; verify in recording"
      ),
      lifecycleTerminateRow(inputs.deadHeadTail),
      lifecyclePersistenceRow(inputs.launchArgs),
    ]
  }

  fileprivate static func lifecycleTtffRow(_ timing: ActTimingReport?) -> ChecklistRow {
    guard let timing else {
      return needsVerificationRow(
        id: "lifecycle.ttff",
        section: .lifecycle,
        proof: Proof.actTiming,
        reason: "act-timing.json missing; cannot prove ttff"
      )
    }
    let ttff = timing.ttffSeconds
    let formatted = String(format: "%.2f", ttff)
    if ttff <= Threshold.ttffBudgetSeconds {
      return ChecklistRow(
        id: "lifecycle.ttff",
        section: Section.lifecycle.rawValue,
        verdict: .notFound,
        proof: Proof.actTiming,
        reason: "ttff=\(formatted)s within \(Threshold.ttffBudgetSeconds)s budget"
      )
    }
    if ttff >= Threshold.ttffProblemSeconds {
      return ChecklistRow(
        id: "lifecycle.ttff",
        section: Section.lifecycle.rawValue,
        verdict: .found,
        proof: Proof.actTiming,
        reason: "ttff=\(formatted)s exceeds \(Threshold.ttffProblemSeconds)s problem threshold"
      )
    }
    return ChecklistRow(
      id: "lifecycle.ttff",
      section: Section.lifecycle.rawValue,
      verdict: .needsVerification,
      proof: Proof.actTiming,
      reason: "ttff=\(formatted)s in grey zone; re-watch first-frame area"
    )
  }

  fileprivate static func lifecycleDashboardRow(_ timing: ActTimingReport?) -> ChecklistRow {
    guard let dashboard = timing?.dashboardLatencySeconds else {
      return needsVerificationRow(
        id: "lifecycle.dashboard",
        section: .lifecycle,
        proof: Proof.actTiming,
        reason: "dashboardLatency missing; cannot prove dashboard latency"
      )
    }
    let formatted = String(format: "%.2f", dashboard)
    if dashboard <= Threshold.dashboardBudgetSeconds {
      return ChecklistRow(
        id: "lifecycle.dashboard",
        section: Section.lifecycle.rawValue,
        verdict: .notFound,
        proof: Proof.actTiming,
        reason: "dashboardLatency=\(formatted)s within \(Threshold.dashboardBudgetSeconds)s budget"
      )
    }
    if dashboard >= Threshold.dashboardProblemSeconds {
      return ChecklistRow(
        id: "lifecycle.dashboard",
        section: Section.lifecycle.rawValue,
        verdict: .found,
        proof: Proof.actTiming,
        reason:
          "dashboardLatency=\(formatted)s exceeds \(Threshold.dashboardProblemSeconds)s threshold"
      )
    }
    return ChecklistRow(
      id: "lifecycle.dashboard",
      section: Section.lifecycle.rawValue,
      verdict: .needsVerification,
      proof: Proof.actTiming,
      reason: "dashboardLatency=\(formatted)s in grey zone; re-watch dashboard population"
    )
  }

  fileprivate static func lifecycleTerminateRow(_ deadHeadTail: DeadHeadTailReport?) -> ChecklistRow
  {
    guard let deadHeadTail else {
      return needsVerificationRow(
        id: "lifecycle.terminate",
        section: .lifecycle,
        proof: Proof.deadHeadTail,
        reason: "dead-head-tail missing; cannot prove orderly terminate"
      )
    }
    let trailing = String(format: "%.2f", deadHeadTail.trailingSeconds)
    if deadHeadTail.isTrailingDead {
      return ChecklistRow(
        id: "lifecycle.terminate",
        section: Section.lifecycle.rawValue,
        verdict: .found,
        proof: Proof.deadHeadTail,
        reason: "trailingSeconds=\(trailing)s past app terminate exceeds threshold"
      )
    }
    return ChecklistRow(
      id: "lifecycle.terminate",
      section: Section.lifecycle.rawValue,
      verdict: .notFound,
      proof: Proof.deadHeadTail,
      reason: "trailingSeconds=\(trailing)s within threshold"
    )
  }

  fileprivate static func lifecyclePersistenceRow(_ launchArgs: LaunchArgsReport?) -> ChecklistRow {
    guard let launchArgs else {
      return needsVerificationRow(
        id: "lifecycle.persistence",
        section: .lifecycle,
        proof: Proof.launchArgs,
        reason: "launch-args.json missing; cannot prove persistence flag"
      )
    }
    if launchArgs.allConfigured {
      return ChecklistRow(
        id: "lifecycle.persistence",
        section: Section.lifecycle.rawValue,
        verdict: .notFound,
        proof: Proof.launchArgs,
        reason: "every UI-test source passes -ApplePersistenceIgnoreState YES"
      )
    }
    return ChecklistRow(
      id: "lifecycle.persistence",
      section: Section.lifecycle.rawValue,
      verdict: .found,
      proof: Proof.launchArgs,
      reason: "at least one UI-test source missing -ApplePersistenceIgnoreState YES"
    )
  }
}

// MARK: - First-frame, transition, idle, perf, a11y, interaction (Sections B-G)

extension RecordingTriage {
  fileprivate static func firstFrameRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      manualRow(
        id: "firstframe.states",
        section: .firstFrame,
        reason: "loading/empty/populated visual distinction is human judgment"
      ),
      manualRow(
        id: "firstframe.enablement",
        section: .firstFrame,
        reason: "control-enablement vs sequencing is human judgment"
      ),
      firstFrameSelectionRow(inputs.actIdentifiers),
      manualRow(
        id: "firstframe.glass",
        section: .firstFrame,
        reason: "Liquid Glass invariants are pixel inspection; verify in recording"
      ),
    ]
  }

  fileprivate static func firstFrameSelectionRow(_ ids: ActIdentifiersInputs) -> ChecklistRow {
    let act1 = ids.perAct.first { $0.act == "act1" }
    let sidebar = act1?.findings.first { $0.id == "swarm.act1.sidebarRow" }
    guard let sidebar else {
      return needsVerificationRow(
        id: "firstframe.selection",
        section: .firstFrame,
        proof: Proof.actIdentifiers,
        reason: "act1 sidebar finding missing"
      )
    }
    return ChecklistRow(
      id: "firstframe.selection",
      section: Section.firstFrame.rawValue,
      verdict: sidebar.verdict,
      proof: Proof.actIdentifiers,
      reason: sidebar.message
    )
  }

  fileprivate static func transitionRows() -> [ChecklistRow] {
    let manualReasons: [(String, String)] = [
      ("transition.animated", "snap detection requires frame-by-frame motion analysis"),
      ("transition.duration", "transition duration timing is per-event timeline data"),
      ("transition.terminates", "transition completion requires per-event timeline data"),
      ("transition.hittest", "hit-testability during transitions is human judgment"),
      ("transition.toast", "toast overlap detection requires frame-pair sampling"),
      ("transition.sheet", "sheet present/dismiss timing requires per-event timeline data"),
    ]
    return manualReasons.map {
      manualRow(id: $0.0, section: .transition, reason: $0.1)
    }
  }

  fileprivate static func idleRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      manualRow(
        id: "idle.stable",
        section: .idle,
        reason: "pixel-stable idle inspection is human judgment"
      ),
      idleChromeRow(inputs.thrash),
      manualRow(
        id: "idle.rerender",
        section: .idle,
        reason: "view-rerender attribution is signpost-level; verify in recording"
      ),
      manualRow(
        id: "idle.cpu",
        section: .idle,
        reason: "idle jank is signpost-level; verify in recording"
      ),
    ]
  }

  fileprivate static func idleChromeRow(_ thrash: ThrashReport?) -> ChecklistRow {
    guard let thrash else {
      return needsVerificationRow(
        id: "idle.chrome",
        section: .idle,
        proof: Proof.thrash,
        reason: "thrash.json missing; cannot prove chrome stability"
      )
    }
    if thrash.windows.isEmpty {
      return ChecklistRow(
        id: "idle.chrome",
        section: Section.idle.rawValue,
        verdict: .notFound,
        proof: Proof.thrash,
        reason: "no thrash windows detected"
      )
    }
    return ChecklistRow(
      id: "idle.chrome",
      section: Section.idle.rawValue,
      verdict: .found,
      proof: Proof.thrash,
      reason: "thrashWindows=\(thrash.windows.count) detected on chrome"
    )
  }

  fileprivate static func perfRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      perfHitchRow(inputs.frameGaps),
      perfStallRow(inputs.frameGaps),
      perfLayoutThrashRow(inputs.layoutDriftPairs),
      manualRow(
        id: "perf.toolbarStutter",
        section: .perf,
        reason: "toolbar size oscillation requires FocusedValue timeline; verify in recording"
      ),
    ]
  }

  fileprivate static func perfHitchRow(_ gaps: FrameGapReport?) -> ChecklistRow {
    guard let gaps else {
      return needsVerificationRow(
        id: "perf.hitch",
        section: .perf,
        proof: Proof.frameGaps,
        reason: "frame-gaps.json missing; cannot prove hitch budget"
      )
    }
    let count = gaps.hitches.count
    if count > Threshold.perSegmentHitchLimit {
      return ChecklistRow(
        id: "perf.hitch",
        section: Section.perf.rawValue,
        verdict: .found,
        proof: Proof.frameGaps,
        reason: "hitches=\(count) exceeds budget of \(Threshold.perSegmentHitchLimit)"
      )
    }
    return ChecklistRow(
      id: "perf.hitch",
      section: Section.perf.rawValue,
      verdict: .notFound,
      proof: Proof.frameGaps,
      reason: "hitches=\(count) within budget"
    )
  }

  fileprivate static func perfStallRow(_ gaps: FrameGapReport?) -> ChecklistRow {
    guard let gaps else {
      return needsVerificationRow(
        id: "perf.stall",
        section: .perf,
        proof: Proof.frameGaps,
        reason: "frame-gaps.json missing; cannot prove stall absence"
      )
    }
    if gaps.stalls.isEmpty {
      return ChecklistRow(
        id: "perf.stall",
        section: Section.perf.rawValue,
        verdict: .notFound,
        proof: Proof.frameGaps,
        reason: "no stalls detected"
      )
    }
    return ChecklistRow(
      id: "perf.stall",
      section: Section.perf.rawValue,
      verdict: .found,
      proof: Proof.frameGaps,
      reason: "stalls=\(gaps.stalls.count) over \(Threshold.perSegmentHitchLimit)s threshold"
    )
  }

  fileprivate static func perfLayoutThrashRow(_ pairs: [LayoutDriftPair]) -> ChecklistRow {
    if pairs.isEmpty {
      return needsVerificationRow(
        id: "perf.layoutThrash",
        section: .perf,
        proof: Proof.layoutDrift,
        reason: "layout-drift.json missing; cannot prove layout stability"
      )
    }
    let total = pairs.reduce(0) { $0 + $1.drifts.count }
    if total > Threshold.layoutThrashChangesPerWindow {
      return ChecklistRow(
        id: "perf.layoutThrash",
        section: Section.perf.rawValue,
        verdict: .found,
        proof: Proof.layoutDrift,
        reason: "layoutDrifts=\(total) across \(pairs.count) act pairs exceeds budget"
      )
    }
    return ChecklistRow(
      id: "perf.layoutThrash",
      section: Section.perf.rawValue,
      verdict: .notFound,
      proof: Proof.layoutDrift,
      reason: "layoutDrifts=\(total) within budget"
    )
  }

  fileprivate static func a11yRows() -> [ChecklistRow] {
    let manualReasons: [(String, String)] = [
      ("a11y.truncation", "truncation detection requires text-fits-bounds inspection"),
      ("a11y.contrast", "WCAG contrast sampling is pixel-level"),
      ("a11y.tapTarget", "primary-action classification is human judgment"),
      ("a11y.fontScaling", "Cmd+/- scaling propagation requires interaction trace"),
      ("a11y.density", "region density spike detection requires layout analysis"),
    ]
    return manualReasons.map {
      manualRow(id: $0.0, section: .a11y, reason: $0.1)
    }
  }

  fileprivate static func interactionRows() -> [ChecklistRow] {
    let manualReasons: [(String, String)] = [
      ("interaction.click", "click-to-feedback latency requires event timeline"),
      ("interaction.hover", "hover affordance latency requires event timeline"),
      ("interaction.drag", "drag preview timing requires event timeline"),
      ("interaction.shortcut", "shortcut feedback timing requires event timeline"),
    ]
    return manualReasons.map {
      manualRow(id: $0.0, section: .interaction, reason: $0.1)
    }
  }
}

// MARK: - Swarm rows (Section H)

extension RecordingTriage {
  fileprivate static let swarmRowMappings: [(spec: String, detectors: [String])] = [
    ("swarm.act1.session", ["swarm.act1.cockpit", "swarm.act1.sidebarRow"]),
    ("swarm.act2.roles", ["swarm.act2.roles", "swarm.act2.duplicateRejected"]),
    ("swarm.act3.tasks", ["swarm.act3.tasks"]),
    ("swarm.act4.selection", ["swarm.act4.tasks"]),
    ("swarm.act5.heuristics", ["swarm.act5.heuristic"]),
    ("swarm.act6.improver", ["swarm.act6.improver"]),
    ("swarm.act7.roster", ["swarm.act7.vibeRoster"]),
    ("swarm.act8.awaitingReview", ["swarm.act8.awaitingReview"]),
    ("swarm.act9.reviewers", ["swarm.act9.reviewerClaim"]),
    ("swarm.act10.autospawn", ["swarm.act10.awaitingReview"]),
    ("swarm.act11.workerRefusal", ["swarm.act11.refusal"]),
    ("swarm.act12.round1", ["swarm.act12.roundOne"]),
    ("swarm.act13.round3", ["swarm.act13.arbitration"]),
    ("swarm.act14.signalCollision", ["swarm.act14.signalCollision"]),
    ("swarm.act15.observe", ["swarm.act15.observeAction"]),
    ("swarm.act16.end", ["swarm.act16.sessionEnded"]),
  ]

  fileprivate static let invariantRowMappings: [(spec: String, detector: String)] = [
    ("swarm.invariant.transitions", "swarm.invariant.taskReviewProgression"),
    ("swarm.invariant.daemonHealth", "swarm.invariant.daemonHealth"),
  ]

  fileprivate static func swarmRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    let perActIndex = Dictionary(
      uniqueKeysWithValues: inputs.actIdentifiers.perAct.map { ($0.act, $0) }
    )
    var rows: [ChecklistRow] = []
    for mapping in swarmRowMappings {
      let actName = swarmActName(for: mapping.spec)
      let findings: [ChecklistFinding] =
        perActIndex[actName].map { perAct in
          perAct.findings.filter { mapping.detectors.contains($0.id) }
        } ?? []
      rows.append(swarmRow(specID: mapping.spec, findings: findings))
    }
    let wholeRunIndex = Dictionary(
      uniqueKeysWithValues: inputs.actIdentifiers.wholeRun.map { ($0.id, $0) }
    )
    for mapping in invariantRowMappings {
      if let finding = wholeRunIndex[mapping.detector] {
        rows.append(
          ChecklistRow(
            id: mapping.spec,
            section: Section.swarm.rawValue,
            verdict: finding.verdict,
            proof: Proof.actIdentifiers,
            reason: finding.message
          ))
      } else {
        rows.append(
          needsVerificationRow(
            id: mapping.spec,
            section: .swarm,
            proof: Proof.actIdentifiers,
            reason: "wholeRun finding \(mapping.detector) not produced"
          ))
      }
    }
    return rows
  }

  fileprivate static func swarmActName(for specID: String) -> String {
    let parts = specID.split(separator: ".")
    guard parts.count >= 2 else { return "" }
    return String(parts[1])
  }

  fileprivate static func swarmRow(
    specID: String,
    findings: [ChecklistFinding]
  ) -> ChecklistRow {
    if findings.isEmpty {
      return needsVerificationRow(
        id: specID,
        section: .swarm,
        proof: Proof.actIdentifiers,
        reason: "no detector findings for \(specID)"
      )
    }
    let verdict = combinedVerdict(findings.map(\.verdict))
    let reason = findings.map { "\($0.id): \($0.message)" }.joined(separator: "; ")
    return ChecklistRow(
      id: specID,
      section: Section.swarm.rawValue,
      verdict: verdict,
      proof: Proof.actIdentifiers,
      reason: reason
    )
  }

  fileprivate static func combinedVerdict(_ verdicts: [ChecklistFinding.Verdict])
    -> ChecklistFinding
    .Verdict
  {
    if verdicts.contains(.notFound) { return .notFound }
    if verdicts.allSatisfy({ $0 == .found }) { return .found }
    if verdicts.contains(.found) { return .found }
    return .needsVerification
  }
}

// MARK: - Artifact rows (Section I)

extension RecordingTriage {
  fileprivate static func artifactRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      artifactHeadRow(inputs.deadHeadTail),
      artifactTailRow(inputs.deadHeadTail),
      artifactFreezesRow(inputs.frameGaps),
      artifactBlanksRow(inputs.blackFrames),
      artifactSizeRow(inputs.assertRecording),
      manualRow(
        id: "artifact.segments",
        section: .artifact,
        reason: "multi-launch segment validation requires per-launch recording manifest"
      ),
    ]
  }

  fileprivate static func artifactHeadRow(_ deadHeadTail: DeadHeadTailReport?) -> ChecklistRow {
    artifactBoundaryRow(
      id: "artifact.head",
      section: .artifact,
      kind: "leading",
      isDead: deadHeadTail?.isLeadingDead,
      seconds: deadHeadTail?.leadingSeconds
    )
  }

  fileprivate static func artifactTailRow(_ deadHeadTail: DeadHeadTailReport?) -> ChecklistRow {
    artifactBoundaryRow(
      id: "artifact.tail",
      section: .artifact,
      kind: "trailing",
      isDead: deadHeadTail?.isTrailingDead,
      seconds: deadHeadTail?.trailingSeconds
    )
  }

  fileprivate static func artifactBoundaryRow(
    id: String,
    section: Section,
    kind: String,
    isDead: Bool?,
    seconds: Double?
  ) -> ChecklistRow {
    guard let isDead, let seconds else {
      return needsVerificationRow(
        id: id,
        section: section,
        proof: Proof.deadHeadTail,
        reason: "dead-head-tail missing; cannot prove \(kind) bound"
      )
    }
    let formatted = String(format: "%.2f", seconds)
    if isDead {
      return ChecklistRow(
        id: id,
        section: section.rawValue,
        verdict: .found,
        proof: Proof.deadHeadTail,
        reason: "\(kind)Seconds=\(formatted) over threshold"
      )
    }
    return ChecklistRow(
      id: id,
      section: section.rawValue,
      verdict: .notFound,
      proof: Proof.deadHeadTail,
      reason: "\(kind)Seconds=\(formatted) within threshold"
    )
  }

  fileprivate static func artifactFreezesRow(_ gaps: FrameGapReport?) -> ChecklistRow {
    guard let gaps else {
      return needsVerificationRow(
        id: "artifact.freezes",
        section: .artifact,
        proof: Proof.frameGaps,
        reason: "frame-gaps.json missing; cannot prove freeze absence"
      )
    }
    if gaps.freezes.isEmpty {
      return ChecklistRow(
        id: "artifact.freezes",
        section: Section.artifact.rawValue,
        verdict: .notFound,
        proof: Proof.frameGaps,
        reason: "no freezes detected"
      )
    }
    return ChecklistRow(
      id: "artifact.freezes",
      section: Section.artifact.rawValue,
      verdict: .found,
      proof: Proof.frameGaps,
      reason: "freezes=\(gaps.freezes.count) detected"
    )
  }

  fileprivate static func artifactBlanksRow(_ frames: [BlackFrameReport]) -> ChecklistRow {
    if frames.isEmpty {
      return needsVerificationRow(
        id: "artifact.blanks",
        section: .artifact,
        proof: Proof.blackFrames,
        reason: "black-frames.json missing; cannot prove blank absence"
      )
    }
    let suspect = frames.filter(\.isSuspect)
    if suspect.isEmpty {
      return ChecklistRow(
        id: "artifact.blanks",
        section: Section.artifact.rawValue,
        verdict: .notFound,
        proof: Proof.blackFrames,
        reason: "no suspect blank frames among \(frames.count) samples"
      )
    }
    return ChecklistRow(
      id: "artifact.blanks",
      section: Section.artifact.rawValue,
      verdict: .found,
      proof: Proof.blackFrames,
      reason: "suspectBlanks=\(suspect.count) of \(frames.count) samples"
    )
  }

  fileprivate static func artifactSizeRow(_ recording: AssertRecordingReport?) -> ChecklistRow {
    guard let recording else {
      return needsVerificationRow(
        id: "artifact.size",
        section: .artifact,
        proof: Proof.assertRecording,
        reason: "assert-recording.json missing; cannot prove file size"
      )
    }
    if recording.status == "ok" {
      let bytes = recording.sizeBytes ?? 0
      return ChecklistRow(
        id: "artifact.size",
        section: Section.artifact.rawValue,
        verdict: .notFound,
        proof: Proof.assertRecording,
        reason: "sizeBytes=\(bytes) within band"
      )
    }
    let why = recording.reason ?? "status=\(recording.status)"
    return ChecklistRow(
      id: "artifact.size",
      section: Section.artifact.rawValue,
      verdict: .found,
      proof: Proof.assertRecording,
      reason: why
    )
  }
}

// MARK: - Suite-speed rows

extension RecordingTriage {
  fileprivate static func suiteSpeedRows(inputs: ChecklistInputs) -> [ChecklistRow] {
    [
      suiteDeadHeadRow(inputs.deadHeadTail),
      suiteDeadTailRow(inputs.deadHeadTail),
      manualRow(
        id: "suite.relaunchGap",
        section: .suite,
        reason: "consecutive-launch idle requires multi-launch detector"
      ),
      suiteHandoffRow(inputs.actTiming),
      manualRow(
        id: "suite.delayedAssert",
        section: .suite,
        reason: "assertion-wait-time inspection requires xctest event log"
      ),
      manualRow(
        id: "suite.repeatedWait",
        section: .suite,
        reason: "wait collapsing requires xctest event log"
      ),
    ]
  }

  fileprivate static func suiteDeadHeadRow(_ deadHeadTail: DeadHeadTailReport?) -> ChecklistRow {
    artifactBoundaryRow(
      id: "suite.deadHead",
      section: .suite,
      kind: "leading",
      isDead: deadHeadTail?.isLeadingDead,
      seconds: deadHeadTail?.leadingSeconds
    )
  }

  fileprivate static func suiteDeadTailRow(_ deadHeadTail: DeadHeadTailReport?) -> ChecklistRow {
    artifactBoundaryRow(
      id: "suite.deadTail",
      section: .suite,
      kind: "trailing",
      isDead: deadHeadTail?.isTrailingDead,
      seconds: deadHeadTail?.trailingSeconds
    )
  }

  fileprivate static func suiteHandoffRow(_ timing: ActTimingReport?) -> ChecklistRow {
    guard let timing, !timing.acts.isEmpty else {
      return needsVerificationRow(
        id: "suite.handoff",
        section: .suite,
        proof: Proof.actTiming,
        reason: "act-timing.json missing or empty; cannot prove handoff speed"
      )
    }
    let gaps = timing.acts.compactMap(\.gapToNextSeconds)
    if gaps.isEmpty {
      return needsVerificationRow(
        id: "suite.handoff",
        section: .suite,
        proof: Proof.actTiming,
        reason: "no inter-act gaps recorded"
      )
    }
    let maxGap = gaps.max() ?? 0
    let formatted = String(format: "%.3f", maxGap)
    if maxGap > Threshold.suiteHandoffBudgetSeconds {
      return ChecklistRow(
        id: "suite.handoff",
        section: Section.suite.rawValue,
        verdict: .found,
        proof: Proof.actTiming,
        reason: "maxGap=\(formatted)s exceeds \(Threshold.suiteHandoffBudgetSeconds)s budget"
      )
    }
    return ChecklistRow(
      id: "suite.handoff",
      section: Section.suite.rawValue,
      verdict: .notFound,
      proof: Proof.actTiming,
      reason: "maxGap=\(formatted)s within budget"
    )
  }
}

// MARK: - Helpers

extension RecordingTriage {
  fileprivate static func manualRow(
    id: String,
    section: Section,
    reason: String
  ) -> ChecklistRow {
    ChecklistRow(
      id: id,
      section: section.rawValue,
      verdict: .needsVerification,
      proof: nil,
      reason: reason
    )
  }

  fileprivate static func needsVerificationRow(
    id: String,
    section: Section,
    proof: String?,
    reason: String
  ) -> ChecklistRow {
    ChecklistRow(
      id: id,
      section: section.rawValue,
      verdict: .needsVerification,
      proof: proof,
      reason: reason
    )
  }

}

// MARK: - Markdown rendering

private enum ChecklistMarkdown {
  static func render(rows: [RecordingTriage.ChecklistRow]) -> String {
    var output = "# Recording checklist\n\n"
    output += "_Auto-generated by `harness-monitor-e2e recording-triage emit-checklist`._\n\n"
    let grouped = Dictionary(grouping: rows, by: \.section)
    let sectionsInOrder = orderedSections(rows: rows)
    for section in sectionsInOrder {
      output += "## \(section)\n\n"
      let sectionRows = grouped[section] ?? []
      for row in sectionRows {
        output += renderRow(row) + "\n"
      }
      output += "\n"
    }
    return output
  }

  private static func orderedSections(rows: [RecordingTriage.ChecklistRow]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for row in rows where seen.insert(row.section).inserted {
      ordered.append(row.section)
    }
    return ordered
  }

  private static func renderRow(_ row: RecordingTriage.ChecklistRow) -> String {
    var line = "- `\(row.id)`: `\(row.verdict.rawValue)` — \(row.reason)"
    if let proof = row.proof {
      line += " (proof: [\(proof)](\(proof)))"
    }
    return line
  }
}
