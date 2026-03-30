import Testing

@testable import HarnessKit

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
}
