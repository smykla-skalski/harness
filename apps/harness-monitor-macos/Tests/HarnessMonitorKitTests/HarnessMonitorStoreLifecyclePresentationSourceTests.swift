import XCTest

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecyclePresentationTests {
  func testSelectedSessionDetailHeadersUseLifecyclePresentationStatusLabel() throws {
    let agentDetailSource = try previewableSourceFile(
      at: "Views/Agents/AgentDetailSection.swift"
    )
    let sessionAgentDetailSource = try previewableSourceFile(
      at: "Views/Sessions/SessionAgentDetailSection.swift"
    )

    XCTAssertTrue(agentDetailSource.contains("status: lifecyclePresentation.visualStatus"))
    XCTAssertTrue(agentDetailSource.contains("statusLabel: lifecyclePresentation.label"))
    XCTAssertFalse(agentDetailSource.contains("status: agent.status"))

    XCTAssertTrue(
      sessionAgentDetailSource.contains("status: lifecyclePresentation.visualStatus")
    )
    XCTAssertTrue(
      sessionAgentDetailSource.contains("statusLabel: lifecyclePresentation.label")
    )
    XCTAssertFalse(sessionAgentDetailSource.contains("status: agent.status"))
  }

  func testSessionWindowCachedSurfacesPassSnapshotAvailabilityIntoLifecyclePresentation() throws {
    let routeContent = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowRouteContent.swift"
    )
    let sidebarSource = try previewableSourceFile(
      at: "Views/Sessions/SessionSidebar+Sections.swift"
    )
    let sessionAgentComputed = try previewableSourceFile(
      at: "Views/Sessions/SessionAgentDetailSection+Computed.swift"
    )
    let columnsSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    XCTAssertTrue(routeContent.contains("acpSnapshots: snapshot.acpAgents"))
    XCTAssertTrue(routeContent.contains("runtimePresentation: runtimePresentation"))
    XCTAssertTrue(sidebarSource.contains("acpSnapshots: snapshot.acpAgents"))
    XCTAssertTrue(sidebarSource.contains("runtimePresentation: runtimePresentation"))
    XCTAssertTrue(sessionAgentComputed.contains("runtimePresentation: runtimePresentation"))
    XCTAssertTrue(columnsSource.contains("acpSnapshots: snapshot.acpAgents"))
  }

  func testDisconnectedAndCachedAgentsDoNotShowReadyActivity() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let disconnectedAgent = makeAgent(
      agentID: "worker-disconnected",
      name: "Disconnected Worker",
      runtime: "codex",
      status: .disconnected
    )
    let cachedAgent = makeAgent(
      agentID: "worker-active",
      name: "Active Worker",
      runtime: "codex"
    )

    let disconnectedPresentation = store.agentActivityPresentation(
      for: disconnectedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [disconnectedAgent],
      queuedTasks: [],
      tuiStatus: nil
    )
    let cachedPresentation = store.agentActivityPresentation(
      for: cachedAgent,
      sessionID: "sess-live",
      sessionRegistrations: [cachedAgent],
      queuedTasks: [],
      tuiStatus: nil
    )

    XCTAssertEqual(disconnectedPresentation.label, "Disconnected")
    XCTAssertEqual(cachedPresentation.label, "Snapshot")
  }

  func makeAgent(
    agentID: String,
    name: String,
    runtime: String,
    status: AgentStatus = .active,
    managedAgent: ManagedAgentRef? = nil
  ) -> AgentRegistration {
    let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
    return AgentRegistration(
      agentId: agentID,
      name: name,
      runtime: runtime,
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-15T17:00:00Z",
      updatedAt: "2026-04-15T17:30:00Z",
      status: status,
      agentSessionId: "\(agentID)-session",
      managedAgent: managedAgent,
      lastActivityAt: "2026-04-15T17:30:00Z",
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
  }

  func previewableSourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL =
      appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
