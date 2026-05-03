import Foundation

extension PreviewHarnessClientState {
  static func seededAgentTuisBySessionID(
    fixtures: PreviewHarnessClient.Fixtures,
    environment: HarnessMonitorEnvironment
  ) -> [String: [AgentTuiSnapshot]] {
    guard let overrideStatus = previewAgentTuiRefreshStatus(environment: environment) else {
      return fixtures.agentTuisBySessionID
    }
    return fixtures.agentTuisBySessionID.mapValues { snapshots in
      snapshots.map { snapshot in
        guard snapshot.status.isActive else {
          return snapshot
        }
        return AgentTuiSnapshot(
          tuiId: snapshot.tuiId,
          sessionId: snapshot.sessionId,
          agentId: snapshot.agentId,
          runtime: snapshot.runtime,
          status: overrideStatus,
          argv: snapshot.argv,
          projectDir: snapshot.projectDir,
          size: snapshot.size,
          screen: snapshot.screen,
          transcriptPath: snapshot.transcriptPath,
          exitCode: overrideStatus.isActive ? nil : (snapshot.exitCode ?? 0),
          signal: snapshot.signal,
          error: overrideStatus == .failed ? (snapshot.error ?? "Preview failure") : nil,
          createdAt: snapshot.createdAt,
          updatedAt: Self.mutationTimestamp
        )
      }
    }
  }

  static func previewAgentTuiRefreshStatus(
    environment: HarnessMonitorEnvironment
  ) -> AgentTuiStatus? {
    guard
      let rawValue = environment.values[agentTuiRefreshStatusEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawValue.isEmpty
    else {
      return nil
    }
    return AgentTuiStatus(rawValue: rawValue)
  }

  static func seededAcpAgentsBySessionID(
    fixtures: PreviewHarnessClient.Fixtures,
    environment: HarnessMonitorEnvironment
  ) -> [String: [AcpAgentSnapshot]] {
    guard seedsPendingAcp(in: environment) else {
      return [:]
    }
    guard
      let detail = fixtures.detail ?? fixtures.detailsBySessionID.values.first,
      !detail.session.sessionId.isEmpty
    else {
      return [:]
    }
    return [
      detail.session.sessionId: [
        seededAcpAgentSnapshot(
          sessionID: detail.session.sessionId,
          projectDir: detail.session.projectDir ?? "/Users/example/Projects/harness"
        )
      ]
    ]
  }

  static func seededAcpAgentSnapshot(
    sessionID: String,
    projectDir: String
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: "preview-managed-agent-1",
      sessionId: sessionID,
      agentId: "worker-codex",
      displayName: "worker-codex",
      status: .active,
      pid: 41_001,
      pgid: 41_001,
      projectDir: projectDir,
      pendingPermissions: 2,
      permissionQueueDepth: 0,
      pendingPermissionBatches: [
        AcpPermissionBatch(
          batchId: "preview-acp-permission-1",
          acpId: "preview-managed-agent-1",
          sessionId: sessionID,
          requests: [
            AcpPermissionItem(
              requestId: "preview-request-write",
              sessionId: sessionID,
              toolCall: .object([
                "kind": .string("fs.write_text_file"),
                "path": .string("Sources/App.swift"),
              ]),
              options: []
            ),
            AcpPermissionItem(
              requestId: "preview-request-terminal",
              sessionId: sessionID,
              toolCall: .object([
                "kind": .string("terminal.create"),
                "command": .string("swift test"),
              ]),
              options: []
            ),
          ],
          createdAt: Self.mutationTimestamp
        )
      ],
      terminalCount: 0,
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
  }

  static func seedsPendingAcp(in environment: HarnessMonitorEnvironment) -> Bool {
    environment.values["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] == "1"
      || environment.values["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"] == "1"
  }
}
