import Foundation

extension PreviewHarnessClientState {
  func agentTuis(sessionID: String) -> [AgentTuiSnapshot] {
    agentTuisBySessionID[sessionID] ?? []
  }

  func agentTui(tuiID: String) -> AgentTuiSnapshot? {
    agentTuisBySessionID.values
      .flatMap(\.self)
      .first { tui in
        tui.tuiId == tuiID
      }
  }

  func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) -> AgentTuiSnapshot {
    nextAgentTuiSequence += 1
    let runtimeTitle =
      AgentTuiRuntime(rawValue: request.runtime)?.title ?? request.runtime.capitalized
    let introText =
      if let prompt = request.prompt, !prompt.isEmpty {
        "\(runtimeTitle.lowercased())> \(prompt)"
      } else {
        "\(runtimeTitle.lowercased())> ready"
      }

    let snapshot = AgentTuiSnapshot(
      tuiId: "preview-agent-tui-\(nextAgentTuiSequence)",
      sessionId: sessionID,
      agentId: "preview-agent-\(nextAgentTuiSequence)",
      runtime: request.runtime,
      status: .running,
      argv: request.argv.isEmpty ? [request.runtime] : request.argv,
      projectDir: request.projectDir ?? fallbackDetail?.session.projectDir
        ?? "/Users/example/Projects/harness",
      size: AgentTuiSize(rows: request.rows, cols: request.cols),
      screen: AgentTuiScreenSnapshot(
        rows: request.rows,
        cols: request.cols,
        cursorRow: 1,
        cursorCol: min(max(introText.count + 1, 1), request.cols),
        text: introText
      ),
      transcriptPath:
        "/Users/example/Projects/harness/transcripts/preview-agent-tui-\(nextAgentTuiSequence).log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

    var sessionTuis = agentTuisBySessionID[sessionID] ?? []
    sessionTuis.insert(snapshot, at: 0)
    agentTuisBySessionID[sessionID] = sessionTuis
    return snapshot
  }

  func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      let updatedText = request.replayedInputs.reduce(snapshot.screen.text) { screenText, input in
        switch input {
        case .text(let text), .paste(let text):
          [screenText, text].filter { !$0.isEmpty }.joined(separator: "\n")
        case .key(let key):
          [screenText, "[\(key.title)]"].filter { !$0.isEmpty }.joined(separator: "\n")
        case .control(let key):
          [screenText, "[Ctrl-\(String(key).uppercased())]"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case .rawBytesBase64:
          [screenText, "[raw bytes]"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
      }

      return snapshot.replacing(
        screen: snapshot.screen.replacing(
          rows: snapshot.screen.rows,
          cols: snapshot.screen.cols,
          text: updatedText
        )
      )
    }
  }

  func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        size: AgentTuiSize(rows: request.rows, cols: request.cols),
        screen: snapshot.screen.replacing(
          rows: request.rows,
          cols: request.cols,
          text: snapshot.screen.text
        )
      )
    }
  }

  func stopAgentTui(tuiID: String) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        status: .stopped,
        exitCode: 0,
        signal: nil
      )
    }
  }

  func managedAgent(agentID: String) -> ManagedAgentSnapshot? {
    agentTuisBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.terminal)
      .first { $0.agentId == agentID }
      ?? codexRunsBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.codex)
      .first { $0.agentId == agentID }
      ?? acpAgentsBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.acp)
      .first { $0.agentId == agentID }
  }

  private func mutateAgentTui(
    tuiID: String,
    mutation: (AgentTuiSnapshot) -> AgentTuiSnapshot
  ) -> AgentTuiSnapshot? {
    for (sessionID, snapshots) in agentTuisBySessionID {
      guard let index = snapshots.firstIndex(where: { $0.tuiId == tuiID }) else {
        continue
      }

      var updatedSnapshots = snapshots
      updatedSnapshots[index] = mutation(snapshots[index])
      agentTuisBySessionID[sessionID] = updatedSnapshots
      return updatedSnapshots[index]
    }

    return nil
  }
}
