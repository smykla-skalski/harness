import HarnessMonitorKit
import HarnessMonitorUIPreviewable

enum HarnessMonitorMCPWindowCommandDescriptors {
  static let all = [
    HarnessMonitorMCPWindowCommandDescriptor(
      identifier: HarnessMonitorAccessibility.windowMenuMainItem,
      label: WindowMenuCommands.mainTitle,
      hint: "Open the dashboard window",
      windowID: HarnessMonitorWindowID.dashboard
    )
  ]
}
