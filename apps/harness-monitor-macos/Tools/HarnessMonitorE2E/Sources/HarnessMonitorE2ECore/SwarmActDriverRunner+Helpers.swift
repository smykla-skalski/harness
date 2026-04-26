import Darwin
import Foundation

extension SwarmActDriverRunner {
  struct DriveTaskRequest {
    let taskID: String
    let status: String
    let assignedTo: String?
    let reviewClaimReviewers: [[String: Any]]
    let leaderID: String
    let reviewerClaudeID: String
    let reviewerCodexID: String
  }

  func runtimeAvailable(_ name: String) -> Bool {
    probeReport.runtimes[name]?.available == true
  }

  func appendOptionalSkip(_ runtime: String) throws {
    let process = Process()
    process.executableURL = appendGapScript
    process.arguments = [
      "--id", "SKIP-\(runtime)",
      "--status", "Closed",
      "--severity", "low",
      "--subsystem", "runtime-probe",
      "--current", "optional runtime \(runtime) unavailable in this environment",
      "--desired", "optional runtime absence is documented and non-blocking",
      "--closed-by", "runtime probe",
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(status: process.terminationStatus, message: "append-gap failed for \(runtime)")
    }
  }

  func joinAgent(role: String, runtime: String, name: String, persona: String) throws -> String {
    let output = try runHarness([
      "session", "join", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--role", role,
      "--runtime", runtime,
      "--name", name,
      "--persona", persona,
    ])
    guard let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
      throw Failure(status: 1, message: "failed to decode joined agent state for \(name)")
    }
    if let agentsByID = json["agents"] as? [String: Any] {
      for (agentID, rawAgent) in agentsByID {
        guard let agent = rawAgent as? [String: Any], (agent["name"] as? String) == name else {
          continue
        }
        if let explicitID = agent["agent_id"] as? String, !explicitID.isEmpty {
          return explicitID
        }
        return agentID
      }
    }
    if let agents = json["agents"] as? [[String: Any]],
      let agentID = agents.reversed().first(where: { ($0["name"] as? String) == name })?["agent_id"]
        as? String
    {
      return agentID
    }
    throw Failure(status: 1, message: "failed to resolve joined agent \(name)")
  }

  func createTask(title: String, severity: String, leaderID: String) throws -> String {
    let output = try runHarness([
      "session", "task", "create", inputs.sessionID,
      "--project-dir", inputs.projectDir.path,
      "--title", title,
      "--severity", severity,
      "--actor", leaderID,
    ])
    guard
      let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
      let taskID = json["task_id"] as? String
    else {
      throw Failure(status: 1, message: "failed to create task \(title)")
    }
    return taskID
  }

  func assignAndStart(taskID: String, agentID: String, leaderID: String) throws {
    try runHarness([
      "session", "task", "assign", inputs.sessionID, taskID, agentID,
      "--project-dir", inputs.projectDir.path,
      "--actor", leaderID,
    ])
    try runHarness([
      "session", "task", "update", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--status", "in_progress",
      "--actor", agentID,
    ])
  }

  func submitRequestChangesRound(
    taskID: String,
    workerID: String,
    reviewerA: String,
    reviewerB: String,
    note: String
  ) throws {
    let points =
      #"[{"point_id":"p1","text":"A","state":"open"},{"point_id":"p2","text":"B","state":"open"},{"point_id":"p3","text":"C","state":"open"}]"#
    try runHarness([
      "session", "task", "submit-for-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerID,
      "--summary", "ready for review",
    ])
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerA,
    ])
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerB,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerA,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerB,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "respond-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerID,
      "--agreed", "p1",
      "--disputed", "p2,p3",
      "--note", note,
    ])
  }

  func continueReviewRound(
    taskID: String,
    workerID: String,
    reviewerA: String,
    reviewerB: String,
    note: String
  ) throws {
    let points =
      #"[{"point_id":"p1","text":"A","state":"open"},{"point_id":"p2","text":"B","state":"open"},{"point_id":"p3","text":"C","state":"open"}]"#
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerA,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerB,
      "--verdict", "request_changes",
      "--summary", "changes requested",
      "--points", points,
    ])
    try runHarness([
      "session", "task", "respond-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", workerID,
      "--agreed", "p1",
      "--disputed", "p2,p3",
      "--note", note,
    ])
  }

  func actReady(_ act: String, values: [String: String]) throws {
    let marker = inputs.syncDir.appendingPathComponent("\(act).ready")
    try FileManager.default.createDirectory(
      at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    var body = "act=\(act)\n"
    for key in values.keys.sorted() {
      guard let value = values[key] else { continue }
      body.append("\(key)=\(value)\n")
    }
    try Data(body.utf8).write(to: marker, options: .atomic)
    logProgress("step=ready act=\(act) marker=\(marker.path)")
  }

  func actAck(_ act: String, timeout: TimeInterval? = nil) throws {
    let marker = inputs.syncDir.appendingPathComponent("\(act).ack")
    let stopMarker = inputs.syncDir
      .deletingLastPathComponent()
      .appendingPathComponent("recording-control/stop.request")
    let resolvedTimeout =
      timeout
      ?? inputs.stepTimeoutOverrides[act]
      ?? SwarmStepTimeouts.timeout(for: act)
    logProgress("step=await-ack act=\(act) timeout=\(resolvedTimeout)s")
    let outcome: SwarmAckWait.Outcome
    do {
      outcome = try SwarmAckWait.waitForAck(
        ackExists: { FileManager.default.fileExists(atPath: marker.path) },
        stopRequested: { FileManager.default.fileExists(atPath: stopMarker.path) },
        timeout: resolvedTimeout
      )
    } catch SwarmAckWait.Failure.timedOut {
      logProgress("step=ack-timeout act=\(act) timeout=\(resolvedTimeout)s")
      throw Failure(
        status: 1,
        message: "\(act).ack timed out after \(Int(resolvedTimeout))s waiting at \(marker.path)"
      )
    }
    switch outcome {
    case .acknowledged:
      logProgress("step=ack act=\(act)")
    case .stopped:
      throw Failure(status: 1, message: "UI test ended before \(act).ack")
    }
  }

  func logProgress(_ message: String) {
    let timestamp = Self.progressTimestamp(date: Date())
    let line = "[swarm-act-driver] \(timestamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
    if let progressHandle {
      try? progressHandle.write(contentsOf: data)
    }
  }

  static func progressTimestamp(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }

  func driveAllTasksToDone(leaderID: String) throws {
    let reviewers = try cleanupReviewerPair()
    let beforeState = try fetchSessionState()
    guard let tasks = beforeState["tasks"] as? [String: Any] else {
      throw Failure(status: 1, message: "session status JSON missing 'tasks' map")
    }
    for taskID in tasks.keys.sorted() {
      guard let task = tasks[taskID] as? [String: Any],
        let status = task["status"] as? String
      else { continue }
      let assignedTo = task["assigned_to"] as? String
      if !taskBlocksSessionEnd(status: status, assignedTo: assignedTo) { continue }
      let claimReviewers: [[String: Any]] =
        ((task["review_claim"] as? [String: Any])?["reviewers"] as? [[String: Any]]) ?? []
      logProgress("step=cleanup-task task=\(taskID) status=\(status)")
      try driveTaskToDone(
        DriveTaskRequest(
          taskID: taskID,
          status: status,
          assignedTo: assignedTo,
          reviewClaimReviewers: claimReviewers,
          leaderID: leaderID,
          reviewerClaudeID: reviewers.claude,
          reviewerCodexID: reviewers.codex
        )
      )
    }
    try assertNoBlockingTasksRemain()
  }

  func assertNoBlockingTasksRemain() throws {
    let after = try fetchSessionState()
    guard let afterTasks = after["tasks"] as? [String: Any] else {
      throw Failure(status: 1, message: "post-cleanup session status missing 'tasks'")
    }
    var stuck: [String] = []
    for (taskID, raw) in afterTasks {
      guard let task = raw as? [String: Any],
        let status = task["status"] as? String
      else { continue }
      let assignedTo = task["assigned_to"] as? String
      if taskBlocksSessionEnd(status: status, assignedTo: assignedTo) {
        stuck.append("\(taskID)(\(status))")
      }
    }
    if !stuck.isEmpty {
      stuck.sort()
      throw Failure(
        status: 1,
        message: "cleanup left blocking tasks: \(stuck.joined(separator: ", "))"
      )
    }
  }

  func taskBlocksSessionEnd(status: String, assignedTo: String?) -> Bool {
    switch status {
    case "in_progress", "awaiting_review", "in_review", "blocked":
      return true
    case "open":
      return assignedTo != nil
    default:
      return false
    }
  }

  func cleanupReviewerPair() throws -> (claude: String, codex: String) {
    let state = try fetchSessionState()
    let agents = (state["agents"] as? [String: Any]) ?? [:]
    var claudeReviewer: String?
    var codexReviewer: String?
    for (agentKey, raw) in agents {
      guard let agent = raw as? [String: Any],
        (agent["role"] as? String) == "reviewer",
        let runtime = agent["runtime"] as? String,
        isAliveAgentStatus(agent["status"] as? String)
      else { continue }
      let resolvedID = (agent["agent_id"] as? String) ?? agentKey
      if runtime == "claude", claudeReviewer == nil {
        claudeReviewer = resolvedID
      } else if runtime == "codex", codexReviewer == nil {
        codexReviewer = resolvedID
      }
    }
    let claude: String
    if let existing = claudeReviewer {
      claude = existing
    } else {
      claude = try joinAgent(
        role: "reviewer", runtime: "claude",
        name: "Swarm Cleanup Reviewer Claude", persona: "code-reviewer")
    }
    let codex: String
    if let existing = codexReviewer {
      codex = existing
    } else {
      codex = try joinAgent(
        role: "reviewer", runtime: "codex",
        name: "Swarm Cleanup Reviewer Codex", persona: "code-reviewer")
    }
    logProgress("step=cleanup-reviewers claude=\(claude) codex=\(codex)")
    return (claude, codex)
  }

  func isAliveAgentStatus(_ status: String?) -> Bool {
    switch status {
    case "active", "idle", "awaiting_review":
      return true
    default:
      return false
    }
  }

  func fetchSessionState() throws -> [String: Any] {
    let output = try runHarness([
      "session", "status", inputs.sessionID,
      "--json",
      "--project-dir", inputs.projectDir.path,
    ])
    guard let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
      throw Failure(status: 1, message: "failed to decode session status JSON")
    }
    return json
  }

  func driveTaskToDone(_ request: DriveTaskRequest) throws {
    switch request.status {
    case "open":
      guard let assignee = request.assignedTo else { return }
      try runHarness([
        "session", "task", "update", inputs.sessionID, request.taskID,
        "--project-dir", inputs.projectDir.path,
        "--status", "in_progress",
        "--actor", assignee,
      ])
      try submitForReviewCleanup(taskID: request.taskID, actor: assignee)
      try claimReviewPair(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
      try approveQuorum(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
    case "in_progress":
      guard let assignee = request.assignedTo else {
        throw Failure(
          status: 1,
          message:
            "task '\(request.taskID)' is in_progress without an assignee; cleanup cannot submit for review"
        )
      }
      try submitForReviewCleanup(taskID: request.taskID, actor: assignee)
      try claimReviewPair(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
      try approveQuorum(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
    case "awaiting_review":
      try claimReviewPair(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
      try approveQuorum(
        taskID: request.taskID,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID)
    case "in_review":
      let actors = try resolveInReviewActors(
        taskID: request.taskID,
        claimReviewers: request.reviewClaimReviewers,
        reviewerClaudeID: request.reviewerClaudeID,
        reviewerCodexID: request.reviewerCodexID
      )
      try approveQuorum(
        taskID: request.taskID, reviewerClaudeID: actors.claude, reviewerCodexID: actors.codex)
    case "blocked":
      try runHarness([
        "session", "task", "arbitrate", inputs.sessionID, request.taskID,
        "--project-dir", inputs.projectDir.path,
        "--actor", request.leaderID,
        "--verdict", "approve",
        "--summary", "cleanup",
      ])
    default:
      return
    }
  }

  func submitForReviewCleanup(taskID: String, actor: String) throws {
    try runHarness([
      "session", "task", "submit-for-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", actor,
      "--summary", "cleanup",
    ])
  }

  func claimReviewPair(
    taskID: String, reviewerClaudeID: String, reviewerCodexID: String
  ) throws {
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerClaudeID,
    ])
    _ = runHarnessMayFail([
      "session", "task", "claim-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerCodexID,
    ])
  }

  func approveQuorum(
    taskID: String, reviewerClaudeID: String, reviewerCodexID: String
  ) throws {
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerClaudeID,
      "--verdict", "approve",
      "--summary", "cleanup",
    ])
    try runHarness([
      "session", "task", "submit-review", inputs.sessionID, taskID,
      "--project-dir", inputs.projectDir.path,
      "--actor", reviewerCodexID,
      "--verdict", "approve",
      "--summary", "cleanup",
    ])
  }

  func resolveInReviewActors(
    taskID: String,
    claimReviewers: [[String: Any]],
    reviewerClaudeID: String,
    reviewerCodexID: String
  ) throws -> (claude: String, codex: String) {
    var claude: String?
    var codex: String?
    for entry in claimReviewers {
      guard let runtime = entry["reviewer_runtime"] as? String,
        let agentID = entry["reviewer_agent_id"] as? String
      else { continue }
      if runtime == "claude", claude == nil {
        claude = agentID
      } else if runtime == "codex", codex == nil {
        codex = agentID
      }
    }
    if claude == nil {
      _ = runHarnessMayFail([
        "session", "task", "claim-review", inputs.sessionID, taskID,
        "--project-dir", inputs.projectDir.path,
        "--actor", reviewerClaudeID,
      ])
      claude = reviewerClaudeID
    }
    if codex == nil {
      _ = runHarnessMayFail([
        "session", "task", "claim-review", inputs.sessionID, taskID,
        "--project-dir", inputs.projectDir.path,
        "--actor", reviewerCodexID,
      ])
      codex = reviewerCodexID
    }
    guard let resolvedClaude = claude, let resolvedCodex = codex else {
      throw Failure(
        status: 1,
        message: "task '\(taskID)' is in_review but the cleanup claim cannot be completed"
      )
    }
    return (resolvedClaude, resolvedCodex)
  }

  @discardableResult
  func runHarness(_ arguments: [String]) throws -> HarnessClient.Output {
    let result = client.run(arguments)
    guard result.exitStatus == 0 else {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? "<binary>"
      throw Failure(
        status: result.exitStatus,
        message: "harness \(arguments.joined(separator: " ")) failed: \(stderr)")
    }
    return result
  }

  func runHarnessMayFail(_ arguments: [String]) -> HarnessClient.Output {
    client.run(arguments)
  }
}
