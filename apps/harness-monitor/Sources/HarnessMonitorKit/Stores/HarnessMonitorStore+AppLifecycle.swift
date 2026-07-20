import Foundation

extension HarnessMonitorStore {
  public func suspendLiveConnectionForAppInactivity() async {
    guard hasLiveConnectionActivity else {
      return
    }
    guard isAppLifecycleSuspended == false else {
      return
    }
    guard appInactivitySuspendTask == nil else {
      return
    }

    guard appInactivitySuspendDelay > .zero else {
      await performAppInactivitySuspend()
      return
    }

    let delay = appInactivitySuspendDelay
    appInactivitySuspendTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else {
        return
      }
      self.appInactivitySuspendTask = nil
      await self.performAppInactivitySuspend()
    }
  }

  public func resumeLiveConnectionAfterAppActivation() async {
    cancelPendingAppInactivitySuspend()
    guard isAppLifecycleSuspended else {
      return
    }

    isAppLifecycleSuspended = false
    guard isBootstrapping == false else {
      return
    }
    guard isReconnecting == false else {
      reconnectRequestedDuringReconnect = true
      return
    }

    await reconnect()
  }

  public func prepareForTermination() async {
    connection.isPreparingForTermination = true
    await flushSessionWindowsOpenAtQuit()
    toast.dismissAll()
    cancelPendingAppInactivitySuspend()
    stopRemoteDaemonReconnect()
    stopAllStreams()
    stopManifestWatcher()
    cancelChromeDataAvailabilityGateTask()
    #if HARNESS_FEATURE_OTEL
      stopResourceMetricsSampling()
    #endif
    isAppLifecycleSuspended = false

    if let client {
      self.client = nil
      await client.shutdown()
    }
    await shutdownMobileRelayBackgroundClient()

    // Run the deferred managed-launch-agent refresh once the live
    // connection has been torn down so the next launch picks up a
    // freshly-bundled daemon helper without bouncing the daemon while
    // the user was still working.
    _ = await daemonController.performDeferredManagedLaunchAgentRefreshIfNeeded()
  }
}
