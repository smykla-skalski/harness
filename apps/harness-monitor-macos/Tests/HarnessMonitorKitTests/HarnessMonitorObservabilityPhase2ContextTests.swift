import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 2 context propagation")
struct HarnessMonitorObservabilityPhase2ContextTests {
  @Test("Session selection keeps the interaction span active for client reads")
  func sessionSelectionKeepsInteractionSpanActiveForClientReads() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId

    await store.selectSession(sessionID)
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.exportedSpans.contains {
        $0.serviceName == "harness-monitor" && $0.name == "user.interaction.select_session"
      }
    }

    let selectionSpan = try #require(
      collector.traceCollector.exportedSpans.last {
        $0.serviceName == "harness-monitor" && $0.name == "user.interaction.select_session"
      }
    )
    let traceparent = try #require(
      client.lastRecordedTraceContext(for: "sessionDetail")?["traceparent"]
    )

    #expect(traceID(fromTraceparent: traceparent) == selectionSpan.traceID)
  }

  @Test("Session selection propagates session and project baggage for client reads")
  func sessionSelectionPropagatesBaggageForClientReads() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    let projectID = PreviewFixtures.summary.projectId

    await store.selectSession(sessionID)
    HarnessMonitorTelemetry.shared.shutdown()

    let baggage = try #require(
      client.lastRecordedTraceContext(for: "sessionDetail")?["baggage"]
    )

    #expect(baggage.contains("session.id=\(sessionID)"))
    #expect(baggage.contains("project.id=\(projectID)"))
  }

  @Test("Session mutation keeps the action span active for client writes")
  func sessionMutationKeepsActionSpanActiveForClientWrites() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId

    await store.selectSession(sessionID)
    _ = await store.createTask(
      title: "Trace propagation task",
      context: nil,
      severity: .medium
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.exportedSpans.contains {
        $0.serviceName == "harness-monitor" && $0.name == "user.action.create_task"
      }
    }

    let actionSpan = try #require(
      collector.traceCollector.exportedSpans.last {
        $0.serviceName == "harness-monitor" && $0.name == "user.action.create_task"
      }
    )
    let traceparent = try #require(
      client.lastRecordedTraceContext(for: "createTask")?["traceparent"]
    )

    #expect(traceID(fromTraceparent: traceparent) == actionSpan.traceID)
  }
}

private func traceID(fromTraceparent traceparent: String) -> String? {
  let components = traceparent.split(separator: "-", omittingEmptySubsequences: false)
  guard components.count == 4 else {
    return nil
  }
  return String(components[1])
}
