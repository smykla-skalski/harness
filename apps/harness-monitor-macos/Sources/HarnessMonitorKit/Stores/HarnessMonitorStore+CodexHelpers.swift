extension HarnessMonitorStore {
  func preferredCodexRun(from runs: [CodexRunSnapshot]) -> CodexRunSnapshot? {
    if let selectedRunID = selectedCodexRun?.runId {
      if let selectedRun = runs.first(where: { $0.runId == selectedRunID }) {
        return selectedRun
      }
    }
    return runs.first { $0.status.isActive } ?? runs.first
  }

  func upsertingCodexRun(
    _ run: CodexRunSnapshot,
    into runs: [CodexRunSnapshot]
  ) -> [CodexRunSnapshot] {
    var updatedRuns = runs.filter { $0.runId != run.runId }
    updatedRuns.insert(run, at: 0)
    return updatedRuns
  }

  func measureCodexRunStart(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> MeasuredOperation<CodexRunSnapshot> {
    try await Self.measureOperation {
      try await client.startCodexRun(
        sessionID: sessionID,
        request: request
      )
    }
  }

  func codexStartActionActor(for actor: String) -> String {
    guard actor == "harness-app" else {
      return actor
    }
    return resolvedActionActor() ?? "harness-app"
  }
}
