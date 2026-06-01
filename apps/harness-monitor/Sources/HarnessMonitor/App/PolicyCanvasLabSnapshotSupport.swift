import Foundation
import HarnessMonitorKit

struct PolicyCanvasLabSeed {
  let document: TaskBoardPolicyPipelineDocument
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let allowsEmptyLiveSnapshot: Bool
}

enum PolicyCanvasLabSnapshotSupport {
  static func initialSeed(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) -> PolicyCanvasLabSeed {
    if let document, hasVisibleGraph(document) {
      return PolicyCanvasLabSeed(
        document: document,
        simulation: simulation,
        audit: audit,
        allowsEmptyLiveSnapshot: true
      )
    }

    let previewDocument = PreviewFixtures.policyCanvasPipelineDocument()
    return PolicyCanvasLabSeed(
      document: previewDocument,
      simulation: nil,
      audit: PreviewFixtures.policyCanvasAudit(for: previewDocument),
      allowsEmptyLiveSnapshot: false
    )
  }

  static func shouldAdoptLiveSnapshot(
    document: TaskBoardPolicyPipelineDocument?,
    allowsEmptyLiveSnapshot: Bool
  ) -> Bool {
    guard let document else {
      return false
    }
    return allowsEmptyLiveSnapshot || hasVisibleGraph(document)
  }

  static func document(
    _ document: TaskBoardPolicyPipelineDocument?,
    includesGroups: Bool
  ) -> TaskBoardPolicyPipelineDocument? {
    guard var document else {
      return nil
    }
    guard !includesGroups else {
      return document
    }

    document.groups = []
    document.nodes = document.nodes.map { node in
      var ungroupedNode = node
      ungroupedNode.groupId = nil
      return ungroupedNode
    }
    return document
  }

  static func hasVisibleGraph(_ document: TaskBoardPolicyPipelineDocument) -> Bool {
    !document.nodes.isEmpty
  }

  /// Names the env vars the `monitor:policy-lab:capture` task uses to hand the lab
  /// a specific pipeline-document JSON (snake_case, the daemon's `policy_pipeline_get`
  /// shape) to render directly instead of a sample or the live daemon snapshot. Base64
  /// content is preferred because it survives the app sandbox with no file-read
  /// permission; the path variant stays for local development outside the sandbox.
  /// When a fixture is set it overrides the picker so an agent can screenshot any
  /// policy without rebuilding to change the default sample.
  static let fixtureBase64EnvKey = "HARNESS_MONITOR_POLICY_CANVAS_LAB_FIXTURE_B64"
  static let fixturePathEnvKey = "HARNESS_MONITOR_POLICY_CANVAS_LAB_FIXTURE"

  static func fixtureEnvIsSet(_ environment: [String: String]) -> Bool {
    !(environment[fixtureBase64EnvKey] ?? "").isEmpty
      || !(environment[fixturePathEnvKey] ?? "").isEmpty
  }

  /// Renders a fixture document when either fixture env var is set. Used to exercise
  /// the layout engine against a specific saved policy without a live daemon.
  static func fixtureDocument() -> TaskBoardPolicyPipelineDocument? {
    let environment = ProcessInfo.processInfo.environment
    let data: Data?
    if let encoded = environment[fixtureBase64EnvKey], !encoded.isEmpty {
      data = Data(base64Encoded: encoded)
    } else if let path = environment[fixturePathEnvKey], !path.isEmpty {
      data = FileManager.default.contents(atPath: path)
    } else {
      return nil
    }
    guard let data else {
      writeFixtureDecodeLog("FAIL no fixture data (bad base64 or unreadable path)")
      return nil
    }
    let snake = JSONDecoder()
    snake.keyDecodingStrategy = .convertFromSnakeCase
    do {
      let document = try snake.decode(TaskBoardPolicyPipelineDocument.self, from: data)
      writeFixtureDecodeLog("OK convertFromSnakeCase nodes=\(document.nodes.count)")
      return document
    } catch {
      if let document = try? JSONDecoder().decode(
        TaskBoardPolicyPipelineDocument.self,
        from: data
      ) {
        writeFixtureDecodeLog("OK plain nodes=\(document.nodes.count)")
        return document
      }
      writeFixtureDecodeLog("FAIL convertFromSnakeCase: \(error)")
      return nil
    }
  }

  /// Writes the fixture decode outcome into the sandbox home so the capture task can
  /// read it back from the app's container without needing any extra entitlement.
  private static func writeFixtureDecodeLog(_ message: String) {
    let logPath = (NSHomeDirectory() as NSString)
      .appendingPathComponent("policy-canvas-lab-decode.log")
    try? message.write(toFile: logPath, atomically: true, encoding: .utf8)
  }
}
