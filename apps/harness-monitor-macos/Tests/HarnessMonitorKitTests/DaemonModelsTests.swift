import Testing

@testable import HarnessMonitorKit

@Suite("Daemon models")
struct DaemonModelsTests {
  @Test("Launch agent lifecycle caption includes stable status parts")
  func launchAgentLifecycleCaptionIncludesStableStatusParts() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harness.daemon",
      state: "running",
      pid: 4_242,
      lastExitStatus: 0
    )

    let caption = status.lifecycleCaption
    #expect(caption.contains("gui/501/io.harness.daemon"))
    #expect(caption.contains("pid 4242"))
    #expect(caption.contains("exit 0"))
  }

  @Test("Launch agent lifecycle title reflects running state with pid")
  func lifecycleTitleRunning() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      pid: 4_242
    )
    #expect(status.lifecycleTitle == "Running")
  }

  @Test("Launch agent lifecycle title reflects loaded state without pid")
  func lifecycleTitleLoaded() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      state: "waiting"
    )
    #expect(status.lifecycleTitle == "Waiting")
  }

  @Test("Launch agent lifecycle title reflects loaded state without state string")
  func lifecycleTitleLoadedNoState() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Loaded")
  }

  @Test("Launch agent lifecycle title reflects installed but not loaded")
  func lifecycleTitleInstalled() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: false,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Installed")
  }

  @Test("Launch agent lifecycle title reflects manual state")
  func lifecycleTitleManual() {
    let status = LaunchAgentStatus(
      installed: false,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Manual")
  }

  @Test("Launch agent lifecycle caption shows status error when present")
  func lifecycleCaptionShowsStatusError() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      statusError: "Could not find service"
    )
    #expect(status.lifecycleCaption == "Could not find service")
  }

  @Test("Launch agent lifecycle caption shows label when service target is empty")
  func lifecycleCaptionFallsBackToLabel() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      state: "waiting"
    )
    #expect(status.lifecycleCaption.contains("io.harness.daemon"))
    #expect(status.lifecycleCaption.contains("waiting"))
  }
}
