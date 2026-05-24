import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("HarnessMonitorStore lifecycle suspend boundary")
struct HarnessMonitorStoreLifecycleSuspendTests {
  @Test(
    "suspendLiveConnectionForAppInactivity does NOT trigger deferred managed launch-agent refresh"
  )
  func suspendForAppInactivityDoesNotTriggerDeferredManagedLaunchAgentRefresh() async {
    // Regression guard for the focus-loss reconnect-storm fix shipped in
    // 2e1cbda18 (`fix(monitor): stop daemon refresh on focus loss`). The
    // bug: `performAppInactivitySuspend` invoked
    // `performDeferredManagedLaunchAgentRefreshIfNeeded`, which
    // unregistered/registered the launch agent every time the app lost
    // focus during a dev rebuild and produced a WS reconnect storm in
    // any sibling Monitor observer. Refresh now lives exclusively in
    // `prepareForTermination`. Any future change that re-introduces a
    // refresh call from the focus-loss path must trip this assertion.
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      deferredManagedLaunchAgentRefreshResult: true
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.appInactivitySuspendDelay = .zero
    await store.startDaemon()

    await store.suspendLiveConnectionForAppInactivity()

    let calls = await daemon.recordedDeferredManagedLaunchAgentRefreshCallCount()
    #expect(
      calls == 0,
      "Focus loss must not trigger a launch-agent refresh; got \(calls) call(s)"
    )
  }

  @Test("prepareForTermination triggers the deferred managed launch-agent refresh")
  func prepareForTerminationTriggersDeferredManagedLaunchAgentRefresh() async {
    // Companion to the suspend-boundary assertion: refresh moved to
    // the explicit termination path (Cmd-Q / lifecycle terminate), so
    // the dev's freshly-built daemon helper still gets exercised on
    // app quit. If termination ever stops invoking the deferred
    // refresh path, the helper-binary swap workflow regresses
    // silently — guard it from the same test pair.
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      deferredManagedLaunchAgentRefreshResult: true
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.startDaemon()

    await store.prepareForTermination()

    let calls = await daemon.recordedDeferredManagedLaunchAgentRefreshCallCount()
    #expect(
      calls >= 1,
      "Termination must invoke the deferred launch-agent refresh; got \(calls) call(s)"
    )
  }
}
