import Foundation

// Maps the generated daemon wire types in
// Models/Generated/AgentTuiWireTypes.generated.swift to the rich app models in
// HarnessMonitorAgentTuiModels.swift. The wire types own the snake_case decode
// (explicit CodingKeys, plain PolicyWireCoding.decoder); the app models keep
// their Int dimensions, computed identity helpers, and screen-rendering methods.
//
// These terminal snapshots reach Swift only nested inside a ManagedAgentSnapshot
// (the adjacently-tagged managed-agents enum), so the production decode reroute
// lands with that cluster. This mapping plus the wire-contract test exercise the
// types and the mapping ahead of that wiring.

extension AgentTuiStatus {
  init(wire: AgentTuiStatusWire) {
    // Both enums are String-backed with identical raw values; the fallback never
    // triggers (the wire enum is closed to the same cases) but keeps this total.
    self = AgentTuiStatus(rawValue: wire.rawValue) ?? .stopped
  }
}

extension AgentTuiSize {
  init(wire: AgentTuiSizeWire) {
    self.init(rows: Int(wire.rows), cols: Int(wire.cols))
  }
}

extension AgentTuiScreenSnapshot {
  init(wire: TerminalScreenSnapshotWire) {
    let rows = Int(wire.rows)
    let cols = Int(wire.cols)
    let cursorRow = Int(wire.cursorRow)
    let cursorCol = Int(wire.cursorCol)
    self.init(rows: rows, cols: cols, cursorRow: cursorRow, cursorCol: cursorCol, text: wire.text)
  }
}

extension AgentTuiSnapshot {
  init(wire: AgentTuiSnapshotWire) {
    let status = AgentTuiStatus(wire: wire.status)
    let size = AgentTuiSize(wire: wire.size)
    let screen = AgentTuiScreenSnapshot(wire: wire.screen)
    self.init(
      tuiId: wire.tuiId,
      sessionId: wire.sessionId,
      agentId: wire.agentId,
      runtime: wire.runtime,
      status: status,
      argv: wire.argv,
      projectDir: wire.projectDir,
      size: size,
      screen: screen,
      transcriptPath: wire.transcriptPath,
      exitCode: wire.exitCode,
      signal: wire.signal,
      error: wire.error,
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt
    )
  }
}

extension AgentTuiStartRequestWire {
  init(_ request: AgentTuiStartRequest) {
    // The app model has no fallbackRole field; the daemon defaults it.
    let rows = UInt16(clamping: request.rows)
    let cols = UInt16(clamping: request.cols)
    self.init(
      runtime: request.runtime,
      role: request.role,
      fallbackRole: nil,
      capabilities: request.capabilities,
      name: request.name,
      prompt: request.prompt,
      projectDir: request.projectDir,
      argv: request.argv,
      rows: rows,
      cols: cols,
      persona: request.persona,
      taskId: request.taskID,
      boardItemId: request.boardItemID,
      workflowExecutionId: request.workflowExecutionID,
      model: request.model,
      effort: request.effort,
      allowCustomModel: request.allowCustomModel
    )
  }
}

extension AgentTuiResizeRequestWire {
  init(_ request: AgentTuiResizeRequest) {
    self.init(rows: UInt16(clamping: request.rows), cols: UInt16(clamping: request.cols))
  }
}

extension AgentTuiInputRequestWire {
  // input/sequence carry the decoder-agnostic hand AgentTuiInput/AgentTuiInputSequence directly;
  // a valid request always sets exactly one (the hand inits enforce it), so the wire mirrors it.
  init(_ request: AgentTuiInputRequest) {
    self.init(input: request.input, sequence: request.sequence)
  }
}
