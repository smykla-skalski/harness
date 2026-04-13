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
      recordRequestSuccess()
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func refresh() async {
    guard let client else {
      await bootstrap()
      return
    }
    await refresh(using: client, preserveSelection: true)
  }

  public func configureUITestBehavior(
    successFeedbackDismissDelay: Duration,
    failureFeedbackDismissDelay: Duration
  ) {
    toast.successDismissDelay = successFeedbackDismissDelay
    toast.failureDismissDelay = failureFeedbackDismissDelay
  }
}
