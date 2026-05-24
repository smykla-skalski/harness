import Foundation
import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorAuditExporterTests: XCTestCase {
  func test_exportEventsWritesStableCanonicalJSONL() async throws {
    let fixture = try makeFixture(outputName: "events.jsonl")
    defer { fixture.restore() }

    try insertEvent(
      .init(
        id: "event-newer",
        tickID: "tick-newer",
        kind: "ruleEvaluated",
        ruleID: "beta",
        severity: .critical,
        payloadJSON: #"{"z":2,"a":1}"#,
        createdAt: .fixed
      ),
      into: fixture.container
    )
    try insertEvent(
      .init(
        id: "event-older",
        tickID: "tick-older",
        kind: "actionExecuted",
        ruleID: "alpha",
        severity: .info,
        payloadJSON: #"{"b":2,"a":1}"#,
        createdAt: .fixed.addingTimeInterval(-60)
      ),
      into: fixture.container
    )

    try await SupervisorAuditExporter.exportEvents(
      toURL: fixture.outputURL,
      modelContainer: fixture.container
    )

    let lines = try readLines(at: fixture.outputURL)
    XCTAssertEqual(lines.count, 2)
    guard lines.count == 2 else { return }
    XCTAssertTrue(lines[0].contains(#""id":"event-older""#))
    XCTAssertTrue(lines[1].contains(#""id":"event-newer""#))
    assertKeyOrder(
      lines[0],
      keys: ["createdAt", "id", "kind", "payloadJSON", "ruleID", "severityRaw", "tickID"]
    )
    assertKeyOrder(
      lines[1],
      keys: ["createdAt", "id", "kind", "payloadJSON", "ruleID", "severityRaw", "tickID"]
    )
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)))
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)))
  }

  func test_exportEventsAppliesFilter() async throws {
    let fixture = try makeFixture(outputName: "filtered-events.jsonl")
    defer { fixture.restore() }

    try insertEvent(
      .init(
        id: "event-stale",
        tickID: "tick-stale",
        kind: "quarantine",
        ruleID: "stuck-agent",
        severity: .needsUser,
        payloadJSON: #"{"note":"stale"}"#,
        createdAt: .fixed
      ),
      into: fixture.container
    )
    try insertEvent(
      .init(
        id: "event-fresh",
        tickID: "tick-fresh",
        kind: "ruleEvaluated",
        ruleID: "idle-session",
        severity: .info,
        payloadJSON: #"{"note":"fresh"}"#,
        createdAt: .fixed.addingTimeInterval(-60)
      ),
      into: fixture.container
    )

    try await SupervisorAuditExporter.exportEvents(
      toURL: fixture.outputURL,
      filter: "stale",
      modelContainer: fixture.container
    )

    let lines = try readLines(at: fixture.outputURL)
    XCTAssertEqual(lines.count, 1)
    guard lines.count == 1 else { return }
    XCTAssertTrue(lines[0].contains(#""id":"event-stale""#))
  }

  func test_exportDecisionsWritesStableCanonicalJSONL() async throws {
    let fixture = try makeFixture(outputName: "decisions.jsonl")
    defer { fixture.restore() }

    try insertDecision(
      .init(
        id: "decision-newer",
        severity: .critical,
        ruleID: "observer-issue",
        sessionID: "session-2",
        agentID: "agent-2",
        taskID: "task-2",
        summary: "newer summary",
        contextJSON: #"{"z":2,"a":1}"#,
        suggestedActionsJSON: #"["nudge"]"#,
        createdAt: .fixed
      ),
      into: fixture.container
    )
    try insertDecision(
      .init(
        id: "decision-older",
        severity: .needsUser,
        ruleID: "stuck-agent",
        sessionID: "session-1",
        agentID: "agent-1",
        taskID: "task-1",
        summary: "older summary",
        contextJSON: #"{"b":2,"a":1}"#,
        suggestedActionsJSON: #"["resolve"]"#,
        createdAt: .fixed.addingTimeInterval(-60)
      ),
      into: fixture.container
    )

    try await SupervisorAuditExporter.exportDecisions(
      toURL: fixture.outputURL,
      modelContainer: fixture.container
    )

    let lines = try readLines(at: fixture.outputURL)
    XCTAssertEqual(lines.count, 2)
    guard lines.count == 2 else { return }
    XCTAssertTrue(lines[0].contains(#""id":"decision-older""#))
    XCTAssertTrue(lines[1].contains(#""id":"decision-newer""#))
    assertKeyOrder(
      lines[0],
      keys: [
        "agentID",
        "contextJSON",
        "createdAt",
        "id",
        "resolutionJSON",
        "ruleID",
        "sessionID",
        "severityRaw",
        "snoozedUntil",
        "statusRaw",
        "suggestedActionsJSON",
        "summary",
        "taskID",
      ]
    )
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)))
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)))
  }

  private func makeFixture(outputName: String) throws -> AuditExportFixture {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let oldXDGDataHome = getenv("XDG_DATA_HOME").map { String(cString: $0) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
    setenv("XDG_DATA_HOME", root.path, 1)

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: fileManager.homeDirectoryForCurrentUser
    )
    let container = try HarnessMonitorModelContainer.live(using: environment)
    let outputURL = root.appendingPathComponent("exports", isDirectory: true)
      .appendingPathComponent(outputName)

    return AuditExportFixture(
      container: container,
      environment: environment,
      outputURL: outputURL,
      restore: {
        if let oldXDGDataHome {
          setenv("XDG_DATA_HOME", oldXDGDataHome, 1)
        } else {
          unsetenv("XDG_DATA_HOME")
        }
        try? fileManager.removeItem(at: root)
      }
    )
  }

  private func insertEvent(_ seed: EventSeed, into container: ModelContainer) throws {
    let context = ModelContext(container)
    let event = SupervisorEvent(
      id: seed.id,
      tickID: seed.tickID,
      kind: seed.kind,
      ruleID: seed.ruleID,
      severity: seed.severity,
      payloadJSON: seed.payloadJSON
    )
    event.createdAt = seed.createdAt
    context.insert(event)
    try context.save()
  }

  private func insertDecision(_ seed: DecisionSeed, into container: ModelContainer) throws {
    let context = ModelContext(container)
    let decision = Decision(
      id: seed.id,
      severity: seed.severity,
      ruleID: seed.ruleID,
      sessionID: seed.sessionID,
      agentID: seed.agentID,
      taskID: seed.taskID,
      summary: seed.summary,
      contextJSON: seed.contextJSON,
      suggestedActionsJSON: seed.suggestedActionsJSON
    )
    decision.createdAt = seed.createdAt
    context.insert(decision)
    try context.save()
  }

  private func readLines(at url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    guard let contents = String(bytes: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return contents.split(whereSeparator: \.isNewline).map(String.init)
  }

  private func assertKeyOrder(
    _ line: String,
    keys: [String],
    file: StaticString = #filePath,
    line lineNumber: UInt = #line
  ) {
    var searchStart = line.startIndex
    for key in keys {
      guard let range = line.range(of: #""\#(key)""#, range: searchStart..<line.endIndex) else {
        XCTFail("missing key \(key)", file: file, line: lineNumber)
        return
      }
      searchStart = range.upperBound
    }
  }
}

private struct AuditExportFixture {
  let container: ModelContainer
  let environment: HarnessMonitorEnvironment
  let outputURL: URL
  let restore: () -> Void
}

private struct EventSeed {
  let id: String
  let tickID: String
  let kind: String
  let ruleID: String?
  let severity: DecisionSeverity?
  let payloadJSON: String
  let createdAt: Date
}

private struct DecisionSeed {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let summary: String
  let contextJSON: String
  let suggestedActionsJSON: String
  let createdAt: Date
}
