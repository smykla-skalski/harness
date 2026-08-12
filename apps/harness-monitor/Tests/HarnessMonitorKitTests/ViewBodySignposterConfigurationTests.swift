import Testing

@testable import HarnessMonitorKit

@Suite("View body signposter configuration")
struct ViewBodySignposterConfigurationTests {
  @Test("Automatic profiling parses launch configuration")
  func automaticProfilingParsesLaunchConfiguration() {
    #expect(
      ViewBodySignposter.isAutomaticProfilingEnabled(
        environment: ["HARNESS_MONITOR_PROFILE_VIEW_BODIES": "1"]
      )
    )
    #expect(
      ViewBodySignposter.isAutomaticProfilingEnabled(
        environment: ["HARNESS_MONITOR_PERF_SCENARIO": "task-board-scroll"]
      )
    )
    #expect(
      !ViewBodySignposter.isAutomaticProfilingEnabled(
        environment: ["HARNESS_MONITOR_PERF_SCENARIO": "  "]
      )
    )
    #expect(!ViewBodySignposter.isAutomaticProfilingEnabled(environment: [:]))
  }

  @Test("Update logging selection parses once-compatible values")
  func updateLoggingSelectionParsesValues() {
    let selected = [
      "HARNESS_MONITOR_LOG_VIEW_UPDATES": "DashboardWindowView, DashboardSidebar"
    ]
    #expect(ViewBodySignposter.shouldLogChanges(for: "DashboardWindowView", environment: selected))
    #expect(ViewBodySignposter.shouldLogChanges(for: "DashboardSidebar", environment: selected))
    #expect(
      !ViewBodySignposter.shouldLogChanges(
        for: "ToolbarAccessoryView",
        environment: selected
      )
    )
    #expect(
      ViewBodySignposter.shouldLogChanges(
        for: "ToolbarAccessoryView",
        environment: ["HARNESS_MONITOR_LOG_VIEW_UPDATES": "all"]
      )
    )
  }
}
