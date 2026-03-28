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
      async let diagnosticsResponse = client.diagnostics()
      async let projectResponse = client.projects()
      async let sessionResponse = client.sessions()

      health = try await healthResponse
      diagnostics = try await diagnosticsResponse
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
