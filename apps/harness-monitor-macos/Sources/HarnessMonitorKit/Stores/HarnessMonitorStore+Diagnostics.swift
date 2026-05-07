import Foundation

extension HarnessMonitorStore {
  public func refreshDiagnostics() async {
    isDiagnosticsRefreshInFlight = true
    defer { isDiagnosticsRefreshInFlight = false }

    guard let client else {
      await refreshDaemonStatus()
      diagnostics = nil
      return
    }

    do {
      let measuredDiagnostics = try await Self.measureOperation {
        try await client.diagnostics()
      }
      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      daemonStatus = DaemonStatusReport(diagnosticsReport: measuredDiagnostics.value)
      clearTransientHostBridgeIssues()
      recordRequestSuccess()
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  @discardableResult
  public func refresh() async -> Bool {
    guard let client else {
      await bootstrap()
      return connectionState == .online
    }
    await refresh(using: client, preserveSelection: true)
    return connectionState == .online
  }

  public func manualRefresh() async {
    guard !isRefreshing, !isBootstrapping else {
      return
    }

    let bootstrapsConnection = client == nil
    if bootstrapsConnection {
      isRefreshing = true
    }
    defer {
      if bootstrapsConnection {
        isRefreshing = false
      }
    }

    guard await refresh() else {
      return
    }
    manualRefreshSuccessToken &+= 1
  }

  public func configureUITestBehavior(
    successFeedbackDismissDelay: Duration,
    failureFeedbackDismissDelay: Duration
  ) {
    toast.successDismissDelay = successFeedbackDismissDelay
    toast.failureDismissDelay = failureFeedbackDismissDelay
  }
}
