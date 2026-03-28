import Foundation

extension MonitorStore {
  func connect(using client: any MonitorClientProtocol) async {
    self.client = client
    connectionState = .online
    await refresh(using: client, preserveSelection: true)
    startGlobalStream(using: client)
  }

  func refresh(
    using client: any MonitorClientProtocol,
    preserveSelection: Bool
  ) async {
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      async let healthResponse = client.health()
      async let projectResponse = client.projects()
      async let sessionResponse = client.sessions()

      health = try await healthResponse
      projects = try await projectResponse
      sessions = try await sessionResponse
      daemonStatus = try? await daemonController.daemonStatus()

      if preserveSelection, let selectedSessionID {
        await loadSession(using: client, sessionID: selectedSessionID)
      }
    } catch {
      connectionState = .offline(error.localizedDescription)
      lastError = error.localizedDescription
    }
  }

  func loadSession(
    using client: any MonitorClientProtocol,
    sessionID: String
  ) async {
    do {
      async let detail = client.sessionDetail(id: sessionID)
      async let timeline = client.timeline(sessionID: sessionID)
      selectedSession = try await detail
      self.timeline = try await timeline
    } catch {
      lastError = error.localizedDescription
    }
  }

  func startGlobalStream(using client: any MonitorClientProtocol) {
    globalStreamTask?.cancel()
    globalStreamTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        for try await event in client.globalStream() {
          if event.event == "ready" {
            continue
          }
          await refresh(using: client, preserveSelection: true)
        }
      } catch {
        await MainActor.run {
          self.lastError = error.localizedDescription
        }
      }
    }
  }

  func startSessionStream(using client: any MonitorClientProtocol, sessionID: String) {
    sessionStreamTask?.cancel()
    sessionStreamTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        for try await event in client.sessionStream(sessionID: sessionID) {
          if event.event == "ready" {
            continue
          }
          await loadSession(using: client, sessionID: sessionID)
        }
      } catch {
        await MainActor.run {
          self.lastError = error.localizedDescription
        }
      }
    }
  }
}

extension MonitorStore {
  public func createTask(
    title: String,
    context: String?,
    severity: TaskSeverity,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.createTask(
          sessionID: sessionID,
          request: TaskCreateRequest(
            actor: actor,
            title: title,
            context: context,
            severity: severity
          )
        )
      }
    )
  }

  public func assignTask(
    taskID: String,
    agentID: String,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.assignTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskAssignRequest(actor: actor, agentId: agentID)
        )
      }
    )
  }

  public func updateTaskStatus(
    taskID: String,
    status: TaskStatus,
    note: String? = nil,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.updateTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskUpdateRequest(actor: actor, status: status, note: note)
        )
      }
    )
  }

  public func checkpointTask(
    taskID: String,
    summary: String,
    progress: Int,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.checkpointTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskCheckpointRequest(
            actor: actor,
            summary: summary,
            progress: progress
          )
        )
      }
    )
  }

  public func changeRole(
    agentID: String,
    role: SessionRole,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.changeRole(
          sessionID: sessionID,
          agentID: agentID,
          request: RoleChangeRequest(actor: actor, role: role)
        )
      }
    )
  }

  public func transferLeader(
    newLeaderID: String,
    reason: String? = nil,
    actor: String = "monitor-app"
  ) async {
    guard let client, let sessionID = selectedSessionID else {
      return
    }

    await mutateSelectedSession(
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.transferLeader(
          sessionID: sessionID,
          request: LeaderTransferRequest(
            actor: actor,
            newLeaderId: newLeaderID,
            reason: reason
          )
        )
      }
    )
  }

  private func mutateSelectedSession(
    using client: any MonitorClientProtocol,
    sessionID: String,
    mutation: () async throws -> SessionDetail
  ) async {
    isBusy = true
    defer { isBusy = false }

    do {
      selectedSession = try await mutation()
      timeline = try await client.timeline(sessionID: sessionID)
      await refresh(using: client, preserveSelection: true)
    } catch {
      lastError = error.localizedDescription
    }
  }
}
