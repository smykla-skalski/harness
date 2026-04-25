import CoreGraphics
import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

final class ChecklistEmitterTests: XCTestCase {
  // MARK: - Coverage and ordering

  func testEmitsCanonicalChecklistRowIDs() {
    let inputs = RecordingTriage.ChecklistInputs()
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let ids = report.rows.map(\.id)
    let expected = Self.canonicalIDs
    XCTAssertEqual(ids, expected, "checklist row order must match the canonical spec")
  }

  func testEmptyInputsYieldNeedsVerificationForTier2Rows() {
    let report = RecordingTriage.emitChecklist(inputs: .init())
    let ttff = report.rows.first { $0.id == "lifecycle.ttff" }
    XCTAssertEqual(ttff?.verdict, .needsVerification)
    let dashboard = report.rows.first { $0.id == "lifecycle.dashboard" }
    XCTAssertEqual(dashboard?.verdict, .needsVerification)
    let head = report.rows.first { $0.id == "artifact.head" }
    XCTAssertEqual(head?.verdict, .needsVerification)
    let size = report.rows.first { $0.id == "artifact.size" }
    XCTAssertEqual(size?.verdict, .needsVerification)
    let suiteHandoff = report.rows.first { $0.id == "suite.handoff" }
    XCTAssertEqual(suiteHandoff?.verdict, .needsVerification)
  }

  func testTier4RowsAlwaysNeedsVerification() {
    let report = RecordingTriage.emitChecklist(inputs: .init())
    let manualIDs: [String] = [
      "lifecycle.warmstart",
      "firstframe.states", "firstframe.enablement", "firstframe.glass",
      "transition.animated", "transition.duration", "transition.terminates",
      "transition.hittest", "transition.toast", "transition.sheet",
      "idle.stable", "idle.rerender", "idle.cpu",
      "perf.toolbarStutter",
      "a11y.truncation", "a11y.contrast", "a11y.tapTarget",
      "a11y.fontScaling", "a11y.density",
      "interaction.click", "interaction.hover", "interaction.drag", "interaction.shortcut",
      "artifact.segments",
      "suite.relaunchGap", "suite.delayedAssert", "suite.repeatedWait",
    ]
    for id in manualIDs {
      let row = report.rows.first { $0.id == id }
      XCTAssertEqual(row?.verdict, .needsVerification, "\(id) must default to needs-verification")
      XCTAssertFalse(row?.reason.isEmpty ?? true, "\(id) reason must be non-empty")
    }
  }

  // MARK: - Lifecycle thresholds

  func testLifecycleTtffWithinBudget() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 1.5, dashboardLatencySeconds: nil, acts: [])
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let ttff = report.rows.first { $0.id == "lifecycle.ttff" }
    XCTAssertEqual(ttff?.verdict, .notFound)
    XCTAssertTrue(ttff?.reason.contains("1.50") == true)
  }

  func testLifecycleTtffOverProblemThreshold() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 4.5, dashboardLatencySeconds: nil, acts: [])
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let ttff = report.rows.first { $0.id == "lifecycle.ttff" }
    XCTAssertEqual(ttff?.verdict, .found)
  }

  func testLifecycleTtffGreyZone() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 3.0, dashboardLatencySeconds: nil, acts: [])
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let ttff = report.rows.first { $0.id == "lifecycle.ttff" }
    XCTAssertEqual(ttff?.verdict, .needsVerification)
  }

  func testLifecycleDashboardWithinBudget() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 1.0, dashboardLatencySeconds: 0.5, acts: [])
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let dashboard = report.rows.first { $0.id == "lifecycle.dashboard" }
    XCTAssertEqual(dashboard?.verdict, .notFound)
  }

  func testLifecycleDashboardOverProblemThreshold() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 1.0, dashboardLatencySeconds: 2.5, acts: [])
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let dashboard = report.rows.first { $0.id == "lifecycle.dashboard" }
    XCTAssertEqual(dashboard?.verdict, .found)
  }

  func testLifecyclePersistenceFlagPresent() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.launchArgs = .init(allConfigured: true)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let persistence = report.rows.first { $0.id == "lifecycle.persistence" }
    XCTAssertEqual(persistence?.verdict, .notFound)
  }

  func testLifecyclePersistenceFlagMissing() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.launchArgs = .init(allConfigured: false)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let persistence = report.rows.first { $0.id == "lifecycle.persistence" }
    XCTAssertEqual(persistence?.verdict, .found)
  }

  func testLifecycleTerminateUsesDeadTail() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.deadHeadTail = .init(leadingSeconds: 1, trailingSeconds: 0.5, threshold: 5)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let terminate = report.rows.first { $0.id == "lifecycle.terminate" }
    XCTAssertEqual(terminate?.verdict, .notFound)
  }

  func testLifecycleTerminateOverThreshold() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.deadHeadTail = .init(leadingSeconds: 1, trailingSeconds: 12, threshold: 5)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let terminate = report.rows.first { $0.id == "lifecycle.terminate" }
    XCTAssertEqual(terminate?.verdict, .found)
  }

  // MARK: - Performance thresholds

  func testPerfHitchUnderBudget() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.frameGaps = .init(
      totalFrames: 100,
      durationSeconds: 10,
      hitches: [.init(startSeconds: 1, endSeconds: 1.06, kind: .hitch)],
      freezes: [],
      stalls: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let hitch = report.rows.first { $0.id == "perf.hitch" }
    XCTAssertEqual(hitch?.verdict, .notFound)
  }

  func testPerfHitchOverBudget() {
    let hitches: [RecordingTriage.FrameGap] = (0..<3).map {
      .init(startSeconds: Double($0), endSeconds: Double($0) + 0.06, kind: .hitch)
    }
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.frameGaps = .init(
      totalFrames: 100,
      durationSeconds: 10,
      hitches: hitches,
      freezes: [],
      stalls: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let hitch = report.rows.first { $0.id == "perf.hitch" }
    XCTAssertEqual(hitch?.verdict, .found)
  }

  func testPerfStallDetected() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.frameGaps = .init(
      totalFrames: 50,
      durationSeconds: 5,
      hitches: [],
      freezes: [],
      stalls: [.init(startSeconds: 1, endSeconds: 7, kind: .stall)]
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let stall = report.rows.first { $0.id == "perf.stall" }
    XCTAssertEqual(stall?.verdict, .found)
  }

  func testPerfLayoutThrash() {
    var inputs = RecordingTriage.ChecklistInputs()
    let drifts = (0..<5).map { index in
      RecordingTriage.LayoutDrift(
        identifier: "id\(index)",
        beforeFrame: .init(x: 0, y: 0, width: 10, height: 10),
        afterFrame: .init(x: 0, y: Double(index + 1) * 5, width: 10, height: 10),
        dx: 0,
        dy: CGFloat(index + 1) * 5
      )
    }
    inputs.layoutDriftPairs = [.init(before: "swarm-act1", after: "swarm-act2", drifts: drifts)]
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let thrash = report.rows.first { $0.id == "perf.layoutThrash" }
    XCTAssertEqual(thrash?.verdict, .found)
  }

  func testPerfLayoutThrashEmpty() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.layoutDriftPairs = [.init(before: "swarm-act1", after: "swarm-act2", drifts: [])]
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let thrash = report.rows.first { $0.id == "perf.layoutThrash" }
    XCTAssertEqual(thrash?.verdict, .notFound)
  }

  // MARK: - Idle and artifact

  func testIdleChromeWithThrash() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.thrash = .init(
      windowSeconds: 0.5,
      changeThreshold: 3,
      windows: [.init(startSeconds: 1, endSeconds: 1.5, perceptualChanges: 5)]
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let idle = report.rows.first { $0.id == "idle.chrome" }
    XCTAssertEqual(idle?.verdict, .found)
  }

  func testArtifactFreezesDetected() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.frameGaps = .init(
      totalFrames: 100,
      durationSeconds: 10,
      hitches: [],
      freezes: [.init(startSeconds: 2, endSeconds: 5, kind: .freeze)],
      stalls: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let freezes = report.rows.first { $0.id == "artifact.freezes" }
    XCTAssertEqual(freezes?.verdict, .found)
  }

  func testArtifactBlanksDetected() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.blackFrames = [
      .init(path: "f.png", meanLuminance: 1, uniqueColorCount: 4, isSuspect: true)
    ]
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let blanks = report.rows.first { $0.id == "artifact.blanks" }
    XCTAssertEqual(blanks?.verdict, .found)
  }

  func testArtifactBlanksClean() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.blackFrames = [
      .init(path: "f1.png", meanLuminance: 200, uniqueColorCount: 1024, isSuspect: false)
    ]
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let blanks = report.rows.first { $0.id == "artifact.blanks" }
    XCTAssertEqual(blanks?.verdict, .notFound)
  }

  func testArtifactSizeOk() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.assertRecording = .init(
      status: "ok", sizeBytes: 100_000_000, durationSeconds: 60, reason: nil)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let size = report.rows.first { $0.id == "artifact.size" }
    XCTAssertEqual(size?.verdict, .notFound)
  }

  func testArtifactSizeFailed() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.assertRecording = .init(
      status: "failed", sizeBytes: 100, durationSeconds: nil, reason: "too small")
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let size = report.rows.first { $0.id == "artifact.size" }
    XCTAssertEqual(size?.verdict, .found)
  }

  // MARK: - Suite speed

  func testArtifactHeadFromDeadHeadTail() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.deadHeadTail = .init(leadingSeconds: 8, trailingSeconds: 1, threshold: 5)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let head = report.rows.first { $0.id == "artifact.head" }
    let suiteHead = report.rows.first { $0.id == "suite.deadHead" }
    XCTAssertEqual(head?.verdict, .found)
    XCTAssertEqual(suiteHead?.verdict, .found)
  }

  func testSuiteHandoffOverGap() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(
      ttffSeconds: 1,
      dashboardLatencySeconds: 0.5,
      acts: [
        .init(
          act: "act1", readySeconds: 0, ackSeconds: 0.1, durationSeconds: 0.1, gapToNextSeconds: 3.0
        ),
        .init(
          act: "act2", readySeconds: 3.1, ackSeconds: nil, durationSeconds: nil,
          gapToNextSeconds: nil),
      ]
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let handoff = report.rows.first { $0.id == "suite.handoff" }
    XCTAssertEqual(handoff?.verdict, .found)
  }

  func testSuiteHandoffSnappy() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(
      ttffSeconds: 1,
      dashboardLatencySeconds: 0.5,
      acts: [
        .init(
          act: "act1", readySeconds: 0, ackSeconds: 0.001, durationSeconds: 0.001,
          gapToNextSeconds: 0.001),
        .init(
          act: "act2", readySeconds: 0.002, ackSeconds: nil, durationSeconds: nil,
          gapToNextSeconds: nil),
      ]
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let handoff = report.rows.first { $0.id == "suite.handoff" }
    XCTAssertEqual(handoff?.verdict, .notFound)
  }

  // MARK: - Swarm pass-through

  func testSwarmAct1PassThroughFromDetectorFindings() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actIdentifiers = .init(
      perAct: [
        .init(
          act: "act1",
          findings: [
            .init(id: "swarm.act1.cockpit", verdict: .found, message: "ok"),
            .init(id: "swarm.act1.sidebarRow", verdict: .found, message: "ok"),
          ]
        )
      ],
      wholeRun: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let session = report.rows.first { $0.id == "swarm.act1.session" }
    XCTAssertEqual(session?.verdict, .found)
  }

  func testSwarmAct1FailsWhenAnyDetectorNotFound() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actIdentifiers = .init(
      perAct: [
        .init(
          act: "act1",
          findings: [
            .init(id: "swarm.act1.cockpit", verdict: .found, message: "ok"),
            .init(id: "swarm.act1.sidebarRow", verdict: .notFound, message: "missing"),
          ]
        )
      ],
      wholeRun: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let session = report.rows.first { $0.id == "swarm.act1.session" }
    XCTAssertEqual(session?.verdict, .notFound)
  }

  func testSwarmInvariantPassThrough() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actIdentifiers = .init(
      perAct: [],
      wholeRun: [
        .init(id: "swarm.invariant.daemonHealth", verdict: .notFound, message: "not on WS in act8")
      ]
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let invariant = report.rows.first { $0.id == "swarm.invariant.daemonHealth" }
    XCTAssertEqual(invariant?.verdict, .notFound)
  }

  func testSwarmFirstFrameSelectionFromAct1() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actIdentifiers = .init(
      perAct: [
        .init(
          act: "act1",
          findings: [
            .init(id: "swarm.act1.sidebarRow", verdict: .found, message: "selected"),
            .init(id: "swarm.act1.cockpit", verdict: .found, message: "ok"),
          ]
        )
      ],
      wholeRun: []
    )
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let firstFrame = report.rows.first { $0.id == "firstframe.selection" }
    XCTAssertEqual(firstFrame?.verdict, .found)
  }

  // MARK: - Markdown rendering

  func testMarkdownContainsCanonicalSections() {
    let report = RecordingTriage.emitChecklist(inputs: .init())
    let markdown = report.renderMarkdown()
    XCTAssertTrue(markdown.contains("## A. Process and lifecycle"))
    XCTAssertTrue(markdown.contains("## I. Recording artifact integrity"))
    XCTAssertTrue(markdown.contains("## Suite-speed prompts"))
    XCTAssertTrue(markdown.contains("`lifecycle.ttff`"))
    XCTAssertTrue(markdown.contains("`needs-verification`"))
  }

  func testMarkdownGoldenForKnownInputs() {
    var inputs = RecordingTriage.ChecklistInputs()
    inputs.actTiming = .init(ttffSeconds: 1.5, dashboardLatencySeconds: 0.5, acts: [])
    inputs.launchArgs = .init(allConfigured: true)
    inputs.deadHeadTail = .init(leadingSeconds: 1, trailingSeconds: 1, threshold: 5)
    let report = RecordingTriage.emitChecklist(inputs: inputs)
    let markdown = report.renderMarkdown()
    XCTAssertTrue(markdown.contains("`lifecycle.ttff`: `not-found`"))
    XCTAssertTrue(markdown.contains("`lifecycle.dashboard`: `not-found`"))
    XCTAssertTrue(markdown.contains("`lifecycle.persistence`: `not-found`"))
    XCTAssertTrue(markdown.contains("`artifact.head`: `not-found`"))
    XCTAssertTrue(markdown.contains("proof:"))
  }

  // MARK: - Canonical row order spec

  static let canonicalIDs: [String] = [
    "lifecycle.ttff",
    "lifecycle.dashboard",
    "lifecycle.manifest",
    "lifecycle.warmstart",
    "lifecycle.terminate",
    "lifecycle.persistence",
    "firstframe.states",
    "firstframe.enablement",
    "firstframe.selection",
    "firstframe.glass",
    "transition.animated",
    "transition.duration",
    "transition.terminates",
    "transition.hittest",
    "transition.toast",
    "transition.sheet",
    "idle.stable",
    "idle.chrome",
    "idle.rerender",
    "idle.cpu",
    "perf.hitch",
    "perf.stall",
    "perf.layoutThrash",
    "perf.toolbarStutter",
    "a11y.truncation",
    "a11y.contrast",
    "a11y.tapTarget",
    "a11y.fontScaling",
    "a11y.density",
    "interaction.click",
    "interaction.hover",
    "interaction.drag",
    "interaction.shortcut",
    "swarm.act1.session",
    "swarm.act2.roles",
    "swarm.act3.tasks",
    "swarm.act4.selection",
    "swarm.act5.heuristics",
    "swarm.act6.improver",
    "swarm.act7.roster",
    "swarm.act8.awaitingReview",
    "swarm.act9.reviewers",
    "swarm.act10.autospawn",
    "swarm.act11.workerRefusal",
    "swarm.act12.round1",
    "swarm.act13.round3",
    "swarm.act14.signalCollision",
    "swarm.act15.observe",
    "swarm.act16.end",
    "swarm.invariant.transitions",
    "swarm.invariant.daemonHealth",
    "artifact.head",
    "artifact.tail",
    "artifact.freezes",
    "artifact.blanks",
    "artifact.size",
    "artifact.segments",
    "suite.deadHead",
    "suite.deadTail",
    "suite.relaunchGap",
    "suite.handoff",
    "suite.delayedAssert",
    "suite.repeatedWait",
  ]
}
